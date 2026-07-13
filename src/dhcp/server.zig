//! M2 authoritative DHCPv4 监听器。
//! 协议引擎与主循环分离，使报文 fixture 和非特权 UDP 测试 socket 共享同一处理逻辑。
//!
//! 职责：
//! - 绑定 UDP 67 端口接收 DHCP 请求
//! - 解析报文并调用 `resolver.resolve` 确定 PXE 决策
//! - 通过 `process` 生成 OFFER/ACK/NAK 响应
//! - 在 OFFER 前执行 ICMP 探测防止地址碰撞
//! - 管理 boot session 生命周期（创建、更新、过期）
//! - 追加 DHCP 审计事件到 events.jsonl
const std = @import("std");
const builtin = @import("builtin");
const model = @import("../model.zig");
const packet = @import("packet.zig");
const probe = @import("probe.zig");
const resolver = @import("../boot/resolver.zig");
const runtime_state = @import("../state/runtime.zig");
const boot_session = @import("../state/boot_session.zig");
const events = @import("../state/events.zig");
const deployment_control = @import("../state/deployment_control.zig");
const observe_log = @import("../observe/log.zig");
const paths = @import("../paths.zig");
const log = std.log.scoped(.dhcp);
pub const port = packet.server_port;
/// Linux 只将 `255.255.255.255:67` 的 DHCP 广播投递到 wildcard socket，
/// 而非绑定到 `server.server_ip` 的 socket。在 Linux 上绑定 wildcard 并将
/// socket 限制到已配置的 PXE NIC，防止多接口主机意外响应管理 LAN 上
/// 收到的请求。
///
/// 其他平台保留 advertised-address bind 用于本地开发；
/// 生产 DHCP 目前仅在 Linux 上验证和支持。
pub fn bind(io: std.Io, server_ip: []const u8, bind_interface: ?[]const u8) !std.Io.net.Socket {
    const address_text = if (builtin.os.tag == .linux) "0.0.0.0" else server_ip;
    const address = try std.Io.net.IpAddress.parseIp4(address_text, port);
    var socket = try address.bind(io, .{ .mode = .dgram, .protocol = .udp, .allow_broadcast = true });
    errdefer socket.close(io);

    if (builtin.os.tag == .linux) {
        const name = bind_interface orelse return error.DhcpBindInterfaceRequired;
        // SO_BINDTODEVICE 要求 IFNAMSIZ 大小、NUL 结尾的缓冲区。
        // 传入完整缓冲区同时拒绝被静默截断的网卡名。
        var device: [16]u8 = [_]u8{0} ** 16;
        if (name.len >= device.len) return error.DhcpBindInterfaceTooLong;
        @memcpy(device[0..name.len], name);
        try std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.BINDTODEVICE, &device);
    }
    return socket;
}
/// DHCP 服务的持久化依赖集合。这些引用在 `serveSocket` 的整个生命周期内必须有效。
pub const Persistence = struct {
    /// 用于事件渲染和临时缓冲区的内存分配器。
    allocator: std.mem.Allocator,
    /// events.jsonl 文件路径。
    events_path: []const u8,
    /// 事件写入器（含轮转和 daemon instance id 注入）。
    writer: *events.Writer,
    /// boot session 存储，用于创建和更新 PXE 启动关联。
    sessions: *boot_session.Store,
    deployments: ?*deployment_control.Store = null,
    /// Stable digest of the daemon's validated config snapshot. Pending
    /// destructive generations are only bootable against this exact revision.
    config_revision: u64 = 0,
};

/// 在同一 UDP worker 中处理 DHCP 和 session 生命周期。
///
/// DISCOVER/REQUEST 才会创建或刷新 session；RELEASE/DECLINE 仅撤销其 lease-IP
/// 关联。这样不会把客户端的释放包误解为新的启动尝试，并让之后的 TFTP 只能按
/// 已 ACK 的唯一 IP 找到 session。
pub fn serveSocket(io: std.Io, owned: std.Io.net.Socket, config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, persistence: ?*const Persistence, stop: ?*const std.atomic.Value(bool)) !void {
    var socket = owned;
    defer socket.close(io);
    try serveSocketOn(io, &socket, config, runtime, persistence, stop);
}
pub fn serveSocketOn(io: std.Io, socket: *std.Io.net.Socket, config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, persistence: ?*const Persistence, stop: ?*const std.atomic.Value(bool)) !void {
    while (true) {
        if (if (stop) |flag| flag.load(.acquire) else false) return;
        var bytes: [1500]u8 = undefined;
        const incoming = socket.receiveTimeout(io, &bytes, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }) catch |err| {
            if (err == error.Timeout) {
                expireSessions(io, persistence);
                continue;
            }
            return err;
        };
        const request = packet.parse(incoming.data) catch |err| {
            log.debug("dropped malformed packet: {t}", .{err});
            continue;
        };
        expireSessions(io, persistence);
        var session_link: ?boot_session.Link = null;
        const request_kind = request.message_type orelse .inform;
        if (request_kind == .discover) prepareAlwaysGeneration(io, persistence, config, &request);
        if (request_kind == .discover or request_kind == .request) session_link = acquireSession(io, persistence, config, &request);
        audit(io, persistence, config, requestEvent(request_kind), request_kind, request_kind, request.mac(), 0, request.xid, request.architecture, if (session_link) |*link| link else null);
        if (request_kind == .release or request_kind == .decline) {
            if (persistence) |p| p.sessions.clearLease(request.mac(), request.xid, boot_session.monotonicNow(), now());
        }
        const reply = offerAfterProbe(io, config, runtime, &request, persistence, if (session_link) |*link| link else null) orelse {
            continue;
        };
        var output: [1500]u8 = undefined;
        const encoded = packet.encodeReply(&output, &request, reply) catch |err| {
            observe_log.err("dhcp: response encoding failed: {t}", .{err});
            continue;
        };
        const target = replyTarget(config, &request, &incoming.from) catch |err| {
            observe_log.err("dhcp: response routing failed: {t}", .{err});
            continue;
        };
        try socket.send(io, &target, encoded);
        if (session_link) |link| {
            const phase: boot_session.Phase = switch (reply.kind) {
                .offer => .dhcp_offer,
                .ack => .dhcp_ack,
                else => .dhcp_discover,
            };
            // OFFER 只是短期预留，不能使广告地址成为引导证据：
            // 只有成功的 REQUEST/ACK 才创建 M3 HTTP 认证可依赖的 lease-to-peer 关联。
            if (persistence) |p| switch (reply.kind) {
                .offer => p.sessions.updateDhcp(link, phase, 0, boot_session.monotonicNow(), now()),
                .ack => p.sessions.updateDhcp(link, phase, reply.yiaddr, boot_session.monotonicNow(), now()),
                else => {},
            };
        }
        audit(io, persistence, config, switch (reply.kind) {
            .offer => "dhcp.offer",
            .ack => "dhcp.ack",
            .nak => "dhcp.nak",
            else => "dhcp.request",
        }, request_kind, reply.kind, request.mac(), reply.yiaddr, request.xid, request.architecture, if (session_link) |*link| link else null);
        logReply(config, &request, reply, session_link);
    }
}

fn prepareAlwaysGeneration(io: std.Io, persistence: ?*const Persistence, config: *const model.AppConfig, request: *const packet.Packet) void {
    const p = persistence orelse return;
    const deployments = p.deployments orelse return;
    const decision = resolver.resolve(config, request.mac(), request.architecture);
    const node_id = decision.node_id orelse return;
    if (decision.mode != .install or p.sessions.hasActiveNode(node_id, boot_session.monotonicNow())) return;
    const profile_name = decision.profile orelse return;
    var always = false;
    for (config.profiles) |profile| if (std.mem.eql(u8, profile.name, profile_name)) {
        always = profile.safety.reinstall_policy == .always;
        break;
    };
    if (!always or !deployments.canAutoRearm(node_id)) return;
    const requested_at = now();
    const rearm = deployments.rearm(node_id, p.config_revision, requested_at, .policy_always) catch |err| {
        observe_log.err("dhcp: automatic install generation unavailable: {t}", .{err});
        return;
    };
    if (!rearm.changed) return;
    deployment_control.save(io, p.allocator, paths.deployment_control_path, deployments) catch |err| {
        deployments.rollbackRearm(node_id, rearm);
        observe_log.err("dhcp: automatic install generation persistence failed: {t}", .{err});
        return;
    };
    var generation_text: [24]u8 = undefined;
    var revision_text: [24]u8 = undefined;
    var requested_at_text: [24]u8 = undefined;
    const fields = [_]events.Field{
        .{ .key = "node_id", .value = node_id },
        .{ .key = "generation", .value = std.fmt.bufPrint(&generation_text, "{d}", .{rearm.generation}) catch "0" },
        .{ .key = "config_revision", .value = std.fmt.bufPrint(&revision_text, "{d}", .{p.config_revision}) catch "0" },
        .{ .key = "requested_at", .value = std.fmt.bufPrint(&requested_at_text, "{d}", .{requested_at}) catch "0" },
        .{ .key = "requested_by", .value = "policy_always" },
    };
    p.writer.appendWithFields(io, p.allocator, p.events_path, "install.retry.requested", "always policy armed a new terminal-following generation", &fields) catch |err|
        observe_log.err("dhcp: automatic install generation event failed: {t}", .{err});
}

/// 确保 OFFER 在离开进程前是无冲突的。原始 ICMP 探测失败时不产生
/// DHCP 回复；将其视为探测通过将允许在缺少 CAP_NET_RAW 的主机上发生
/// lease 碰撞。
fn offerAfterProbe(io: std.Io, config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, request: *const packet.Packet, persistence: ?*const Persistence, session_link: ?*const boot_session.Link) ?packet.Reply {
    var attempts: usize = 0;
    while (attempts < runtime_state.DhcpState.max_leases) : (attempts += 1) {
        const revision = if (persistence) |p| p.config_revision else 0;
        const decision = resolver.resolveWithDeployment(config, if (persistence) |p| p.deployments else null, revision, request.mac(), request.architecture);
        if (decision.install_not_armed) emitInstallNotArmed(io, persistence, decision.node_id.?);
        const reply = processWithDeployment(config, runtime, request, if (persistence) |p| p.deployments else null, revision) orelse return null;
        if (reply.kind != .offer) return reply;
        // 已注册节点的显式保留地址对其 MAC 是独占的。
        // 不要因为旧客户端网络栈在固件重新获取 DHCP 时仍回答 ICMP 而让
        // 正在启动的保留节点失败。
        if (decision.reserved_ip != null) return reply;
        // 正在续约自身活动 lease 的客户端会（正确地）回答该地址的 ICMP 探测。
        // 将此回复视为冲突会在 Anaconda 上线时放弃安装器的活动 lease。
        if (runtime.dhcp.ownsActiveLease(request.mac(), reply.yiaddr, now())) return reply;
        switch (probe.ping(io, reply.yiaddr, config.dhcp.ping_timeout_ms)) {
            .clear => return reply,
            .occupied => {
                _ = runtime.dhcp.decline(request.mac(), now(), config.dhcp.abandon_seconds);
                audit(io, persistence, config, "dhcp.abandoned", request.message_type orelse .inform, .decline, request.mac(), reply.yiaddr, request.xid, request.architecture, session_link);
            },
            .unavailable => {
                observe_log.err("dhcp: ping probe unavailable; refusing offer", .{});
                // `process` 在此处之前已创建了短期 OFFER。
                // 当探测本身不可信时不保留地址，同时保留任何无关的活动 lease。
                _ = runtime.dhcp.cancelOffer(request.mac(), reply.yiaddr);
                return null;
            },
        }
    }
    observe_log.err("dhcp: no unchecked candidate remained after ping probes", .{});
    return null;
}

/// The boot gate is intentionally visible in the audit trail. No boot session
/// exists for a held node, so this is a server-side event rather than an
/// installer DTO and carries no credential or answer data.
fn emitInstallNotArmed(io: std.Io, persistence: ?*const Persistence, node_id: []const u8) void {
    const p = persistence orelse return;
    const fields = [_]events.Field{.{ .key = "node_id", .value = node_id }};
    p.writer.appendWithFields(io, p.allocator, p.events_path, "boot.install_not_armed", "install profile held: no matching armed generation", &fields) catch |err|
        observe_log.err("dhcp: install-not-armed event append failed: {t}", .{err});
}
/// DHCP 协议引擎：解析请求并生成 OFFER/ACK/NAK 响应。
///
/// 处理流程：
/// 1. RELEASE/DECLINE：释放或隔离 lease，不返回响应
/// 2. DISCOVER/REQUEST：选择地址（静态保留或动态池分配）
/// 3. REQUEST 的 server_identifier 校验：忽略发给其他服务端的请求
/// 4. 地址选择成功后生成 OFFER（DISCOVER）或 ACK（REQUEST）
///
/// 此函数不执行 ICMP 探测；探测由 `offerAfterProbe` 在返回 OFFER 前执行。
pub fn process(config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, request: *const packet.Packet) ?packet.Reply {
    return processWithDeployment(config, runtime, request, null, 0);
}

fn processWithDeployment(config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, request: *const packet.Packet, deployments: ?*deployment_control.Store, revision: u64) ?packet.Reply {
    const typ = request.message_type orelse return null;
    const server_ip = parseIp(config.server.server_ip) orelse return null;
    const net = network(config.dhcp.subnet) orelse return null;
    const relay_link = request.link_selection orelse request.giaddr;
    if (relay_link != 0 and !inNetwork(relay_link, config.dhcp.subnet, net.prefix)) return null;
    const mask = prefixMask(net.prefix);
    const client = request.mac();
    const decision = resolver.resolveWithDeployment(config, deployments, revision, client, request.architecture);
    switch (typ) {
        .release => {
            _ = runtime.dhcp.release(client);
            return null;
        },
        .decline => {
            _ = runtime.dhcp.decline(client, now(), config.dhcp.abandon_seconds);
            return null;
        },
        .discover, .request => {},
        else => return null,
    }
    const requested = request.requested_ip orelse if (request.ciaddr != 0) request.ciaddr else 0;
    const static_ip = if (decision.reserved_ip) |ip| parseIp(ip) else null;
    const selected = static_ip orelse chooseLease(config, runtime, client, requested, decision.known, typ);
    if (selected == 0) return if (typ == .request) base(.nak, 0, server_ip, mask, config, null) else null;
    if (typ == .request and request.server_identifier != null and request.server_identifier.? != server_ip) return null;
    if (typ == .discover and static_ip != null and runtime.dhcp.offer(client, selected, true, now(), config.dhcp.offer_seconds) == 0) return null;
    if (typ == .request and !runtime.dhcp.acknowledge(client, selected, decision.known or static_ip != null, static_ip != null, now(), config.dhcp.lease_seconds)) return base(.nak, 0, server_ip, mask, config, null);
    return base(if (typ == .discover) .offer else .ack, selected, server_ip, mask, config, decision.bootfile);
}
/// 从配置构建 DHCP Reply 基础结构，包含子网掩码、网关、DNS 和租约时长。
fn base(kind: packet.MessageType, yiaddr: u32, server_ip: u32, mask: u32, config: *const model.AppConfig, bootfile: ?[]const u8) packet.Reply {
    var dns: [8]u32 = undefined;
    var count: usize = 0;
    for (config.dhcp.dns) |value| {
        if (count == dns.len) break;
        dns[count] = parseIp(value) orelse continue;
        count += 1;
    }
    return .{ .kind = kind, .yiaddr = yiaddr, .server_ip = server_ip, .subnet_mask = mask, .router = if (config.dhcp.router) |router| parseIp(router) else null, .dns = dns[0..count], .lease_seconds = config.dhcp.lease_seconds, .bootfile = bootfile };
}
/// 从地址池中选择一个可用地址。
///
/// 选择策略：
/// 1. REQUEST 优先使用客户端请求的地址（续约场景）
/// 2. DISCOVER 尝试客户端请求的地址（如果可用且未被其他节点保留）
/// 3. 从池起始到结束顺序扫描，返回第一个可用地址
///
/// 返回 0 表示地址池耗尽或所有候选地址都被其他节点保留。
fn chooseLease(config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, mac: []const u8, requested: u32, known: bool, typ: packet.MessageType) u32 {
    const first = parseIp(config.dhcp.pool_start) orelse return 0;
    const last = parseIp(config.dhcp.pool_end) orelse return 0;
    if (typ == .request and requested != 0) return requested;
    if (requested != 0 and poolContains(config, requested) and !reservedForOther(config, requested, mac)) return runtime.dhcp.offer(mac, requested, known, now(), config.dhcp.offer_seconds);
    var ip = first;
    while (ip <= last) : (ip += 1) {
        if (reservedForOther(config, ip, mac)) continue;
        const allocated = runtime.dhcp.offer(mac, ip, known, now(), config.dhcp.offer_seconds);
        if (allocated != 0) return allocated;
    }
    return 0;
}
/// 返回当前 Unix 时间戳（秒）。用于 lease 过期计算。
fn now() i64 {
    var ts: std.posix.timespec = undefined;
    return if (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts)) == .SUCCESS) @intCast(ts.sec) else 0;
}
/// 追加 DHCP 审计事件。
///
/// `session_link` 是本包处理时取得的关联结果：成功时写 boot_session_id，无法
/// 安全关联时写 session_link_state。此处不得仅凭 `ip`、MAC 或 node 配置重新
/// 查找 session，否则会掩盖容量耗尽和地址歧义。
fn audit(io: std.Io, persistence: ?*const Persistence, config: *const model.AppConfig, event_type: []const u8, request_kind: packet.MessageType, reply_kind: packet.MessageType, mac: []const u8, ip: u32, xid: u32, architecture: packet.Architecture, session_link: ?*const boot_session.Link) void {
    const p = persistence orelse return;
    var ip_text: [16]u8 = undefined;
    const rendered_ip = std.fmt.bufPrint(&ip_text, "{d}.{d}.{d}.{d}", .{ (ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255 }) catch return;
    var xid_text: [12]u8 = undefined;
    const rendered_xid = std.fmt.bufPrint(&xid_text, "0x{x:0>8}", .{xid}) catch return;
    var mac_text: [17]u8 = undefined;
    if (mac.len != 6) return;
    const rendered_mac = std.fmt.bufPrint(&mac_text, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] }) catch return;
    const decision = resolver.resolve(config, mac, architecture);
    var fields: [8]events.Field = .{
        .{ .key = "mac", .value = rendered_mac },
        .{ .key = "ip", .value = rendered_ip },
        .{ .key = "xid", .value = rendered_xid },
        .{ .key = "kind", .value = @tagName(request_kind) },
        .{ .key = "arch", .value = @tagName(architecture) },
        .{ .key = "", .value = "" },
        .{ .key = "", .value = "" },
        .{ .key = "", .value = "" },
    };
    var count: usize = 5;
    if (decision.node_id) |node_id| {
        fields[count] = .{ .key = "node_id", .value = node_id };
        count += 1;
    }
    if (session_link) |link| {
        if (link.id()) |id| {
            fields[count] = .{ .key = "boot_session_id", .value = id };
            count += 1;
        } else if (link.state()) |state| {
            fields[count] = .{ .key = "session_link_state", .value = state };
            count += 1;
        }
    }
    var message: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&message, "{t} -> {t} yiaddr={s}", .{ request_kind, reply_kind, rendered_ip }) catch return;
    p.writer.appendWithFields(io, p.allocator, p.events_path, event_type, text, fields[0..count]) catch |err| observe_log.err("dhcp: event append failed: {t}", .{err});
}

/// 从 DISCOVER/REQUEST 获取 session，并将被新 XID 替换的旧 session 立即审计。
///
/// session 分配失败不会中断 DHCP；返回 `capacity_exhausted` 让事件消费者看见
/// 关联缺口，而非错误地把本次请求接到另一条活动记录上。
fn acquireSession(io: std.Io, persistence: ?*const Persistence, config: *const model.AppConfig, request: *const packet.Packet) ?boot_session.Link {
    const p = persistence orelse return .capacity_exhausted;
    // A held destructive profile must still receive its diagnostic DHCP
    // lease, but it must not acquire a capability-bearing boot session.  Such
    // a session would make the safe `install retry` operation return 409 even
    // though no installer was ever served.
    const decision = resolver.resolveWithDeployment(config, p.deployments, p.config_revision, request.mac(), request.architecture);
    if (decision.install_not_armed) return null;
    const result = p.sessions.acquireDhcp(io, .{
        .mac = request.mac(),
        .xid = request.xid,
        .node_id = decision.node_id,
        .profile = decision.profile,
        .mode = decision.mode,
    }, boot_session.monotonicNow(), now()) catch |err| {
        observe_log.warn("dhcp: boot session allocation unavailable: {t}", .{err});
        return .capacity_exhausted;
    };
    if (result.retired) |session| emitSessionTermination(io, p, session);
    return result.link;
}

/// 在空闲 receive timeout 和请求处理后清理过期 session，避免低流量环境中
/// session 只能等到下一次 DHCP 包才终止。
fn expireSessions(io: std.Io, persistence: ?*const Persistence) void {
    const p = persistence orelse return;
    var expired: [boot_session.max_sessions]boot_session.Session = undefined;
    const count = p.sessions.expire(boot_session.monotonicNow(), now(), &expired);
    for (expired[0..count]) |session| emitSessionTermination(io, p, session);
}

/// 用已复制的终态 session 记录唯一的 `boot.session.terminated` 事件。
///
/// 调用时 session 已从 Store 移除，因此事件写入失败不会使终态 session 重新变活。
pub fn emitSessionTermination(io: std.Io, persistence: *const Persistence, session: boot_session.Session) void {
    var mac: [17]u8 = undefined;
    var ip: [16]u8 = undefined;
    const mac_text = std.fmt.bufPrint(&mac, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ session.mac[0], session.mac[1], session.mac[2], session.mac[3], session.mac[4], session.mac[5] }) catch return;
    const ip_text = formatIp(&ip, session.lease_ip) catch "0.0.0.0";
    var fields: [7]events.Field = .{
        .{ .key = "boot_session_id", .value = session.idSlice() },
        .{ .key = "mac", .value = mac_text },
        .{ .key = "ip", .value = ip_text },
        .{ .key = "phase", .value = @tagName(session.phase) },
        .{ .key = "reason", .value = @tagName(session.terminal_reason orelse .failed) },
        .{ .key = "", .value = "" },
        .{ .key = "", .value = "" },
    };
    var count: usize = 5;
    if (session.node_id) |node_id| {
        fields[count] = .{ .key = "node_id", .value = node_id };
        count += 1;
    }
    if (session.profile) |profile| {
        fields[count] = .{ .key = "profile", .value = profile };
        count += 1;
    }
    persistence.writer.appendWithFields(io, persistence.allocator, persistence.events_path, "boot.session.terminated", "boot session terminated", fields[0..count]) catch |err|
        observe_log.err("dhcp: boot session termination event failed: {t}", .{err});
}

/// 服务日志与 audit 字段保持相同的关联语义，方便 journal 排障时交叉核对。
fn logReply(config: *const model.AppConfig, request: *const packet.Packet, reply: packet.Reply, session_link: ?boot_session.Link) void {
    var reply_ip: [16]u8 = undefined;
    var mac_text: [17]u8 = undefined;
    const readable_ip = formatIp(&reply_ip, reply.yiaddr) catch "0.0.0.0";
    const mac = request.mac();
    const readable_mac = std.fmt.bufPrint(&mac_text, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] }) catch "unknown";
    const decision = resolver.resolve(config, mac, request.architecture);
    if (session_link) |*link| {
        if (link.id()) |session| {
            observe_log.info("dhcp: {t} -> {t} yiaddr={s} node_id={s} session={s} mac={s} xid=0x{x:0>8}", .{
                request.message_type orelse .inform,
                reply.kind,
                readable_ip,
                decision.node_id orelse "-",
                session,
                readable_mac,
                request.xid,
            });
            return;
        }
        observe_log.warn("dhcp: {t} -> {t} yiaddr={s} mac={s} xid=0x{x:0>8} session_link_state={s}", .{
            request.message_type orelse .inform,
            reply.kind,
            readable_ip,
            readable_mac,
            request.xid,
            link.state() orelse "unknown",
        });
        return;
    }
    observe_log.info("dhcp: {t} -> {t} yiaddr={s} mac={s} xid=0x{x:0>8}", .{
        request.message_type orelse .inform,
        reply.kind,
        readable_ip,
        readable_mac,
        request.xid,
    });
}
/// 将 32 位大端序 IPv4 地址格式化为点分十进制字符串。
fn formatIp(buffer: *[16]u8, ip: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{ (ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255 });
}
/// 检查 IP 是否在配置的 DHCP 地址池范围内。
fn poolContains(config: *const model.AppConfig, ip: u32) bool {
    const first = parseIp(config.dhcp.pool_start) orelse return false;
    const last = parseIp(config.dhcp.pool_end) orelse return false;
    return ip >= first and ip <= last;
}
/// 检查地址是否被其他节点静态保留。动态分配时跳过其他节点的保留地址。
fn reservedForOther(config: *const model.AppConfig, ip: u32, mac: []const u8) bool {
    for (config.nodes) |node| {
        const reserved = if (node.ip) |value| parseIp(value) else null;
        if (reserved != null and reserved.? == ip and !resolver.sameMac(node.mac, mac)) return true;
    }
    return false;
}
/// CIDR 网络的解析结果。prefix 是子网前缀长度（0-30）。
const Net = struct { prefix: u6 };
/// 解析 CIDR 表示法（如 "192.168.50.0/24"），返回网络前缀长度。
fn network(cidr: []const u8) ?Net {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return null;
    _ = parseIp(cidr[0..slash]) orelse return null;
    const prefix = std.fmt.parseInt(u6, cidr[slash + 1 ..], 10) catch return null;
    return if (prefix <= 30) .{ .prefix = prefix } else null;
}
/// 检查 IP 是否属于指定 CIDR 网络。
fn inNetwork(ip: u32, cidr: []const u8, prefix: u6) bool {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return false;
    const subnet = parseIp(cidr[0..slash]) orelse return false;
    return (ip & prefixMask(prefix)) == (subnet & prefixMask(prefix));
}
/// 根据前缀长度生成子网掩码（大端序 32 位）。
fn prefixMask(prefix: u6) u32 {
    return if (prefix == 0) 0 else @as(u32, 0xffffffff) << @as(u5, @intCast(32 - prefix));
}
/// 将点分十进制 IPv4 字符串解析为 32 位大端序整数。
fn parseIp(text: []const u8) ?u32 {
    var it = std.mem.splitScalar(u8, text, '.');
    var value: u32 = 0;
    var n: usize = 0;
    while (it.next()) |part| {
        const octet = std.fmt.parseInt(u8, part, 10) catch return null;
        value = (value << 8) | octet;
        n += 1;
    }
    return if (n == 4) value else null;
}
/// RFC 2131 section 4.1 响应路由：
/// - 中继转发的请求回复到 giaddr:67
/// - 有 ciaddr 且未设置 broadcast 标志的请求回复到 ciaddr:68
/// - 其他情况回复到子网广播地址:68
/// 这是真实 DHCP 客户端在配置广告地址前所必需的。
fn replyTarget(config: *const model.AppConfig, request: *const packet.Packet, received_from: *const std.Io.net.IpAddress) !std.Io.net.IpAddress {
    if (request.giaddr != 0) return ipAddress(request.giaddr, port);
    if (request.ciaddr != 0 and (request.flags & 0x8000) == 0) return ipAddress(request.ciaddr, packet.client_port);
    const net = network(config.dhcp.subnet) orelse return error.InvalidSubnet;
    const subnet = parseIp(config.dhcp.subnet[0..std.mem.indexOfScalar(u8, config.dhcp.subnet, '/').?]) orelse return error.InvalidSubnet;
    const broadcast = (subnet & prefixMask(net.prefix)) | ~prefixMask(net.prefix);
    _ = received_from;
    return ipAddress(broadcast, packet.client_port);
}
/// 将 32 位大端序 IPv4 地址和端口转换为 IpAddress。
fn ipAddress(value: u32, value_port: u16) !std.Io.net.IpAddress {
    var text: [16]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&text, "{d}.{d}.{d}.{d}", .{ (value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255 });
    return std.Io.net.IpAddress.parseIp4(rendered, value_port);
}
/// 将 DHCP 消息类型映射为事件类型字符串。
fn requestEvent(kind: packet.MessageType) []const u8 {
    return switch (kind) {
        .discover => "dhcp.discover",
        .request => "dhcp.request",
        .release => "dhcp.release",
        .decline => "dhcp.decline",
        else => "dhcp.request",
    };
}
test "aarch64 discover returns catalog bootfile" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.50.1" }, .policy = .{ .default_action = .discovery } };
    var runtime: runtime_state.RuntimeState = .{};
    const mac = [_]u8{ 1, 2, 3, 4, 5, 6 };
    const reply = process(&config, &runtime, &.{ .op = 1, .xid = 1, .flags = 0, .ciaddr = 0, .yiaddr = 0, .siaddr = 0, .giaddr = 0, .chaddr = mac ++ [_]u8{0} ** 10, .hlen = 6, .message_type = .discover, .architecture = .aarch64 }).?;
    try std.testing.expectEqualStrings("efi/grubaa64.efi", reply.bootfile.?);
}

test "dynamic allocation skips another node's static reservation" {
    const nodes = [_]model.NodeConfig{.{ .id = "reserved", .mac = "02:00:00:00:00:01", .arch = .x86_64, .profile = "unused", .ip = "192.168.50.100" }};
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.50.1" },
        .dhcp = .{ .pool_start = "192.168.50.100", .pool_end = "192.168.50.101" },
        .nodes = &nodes,
    };
    var runtime: runtime_state.RuntimeState = .{};
    const mac = [_]u8{ 2, 0, 0, 0, 0, 2 };
    try std.testing.expectEqual(@as(u32, 0xc0a83265), chooseLease(&config, &runtime, &mac, 0, false, .discover));
}

test "relay link selection must identify the configured subnet" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.50.1" } };
    var runtime: runtime_state.RuntimeState = .{};
    const mac = [_]u8{ 2, 0, 0, 0, 0, 3 };
    const request: packet.Packet = .{
        .op = 1,
        .xid = 1,
        .flags = 0,
        .ciaddr = 0,
        .yiaddr = 0,
        .siaddr = 0,
        .giaddr = 0xc0a80101,
        .chaddr = mac ++ [_]u8{0} ** 10,
        .hlen = 6,
        .message_type = .discover,
        .link_selection = 0xc0a83201,
    };
    try std.testing.expect(process(&config, &runtime, &request) != null);

    var wrong_link = request;
    wrong_link.link_selection = 0xc0a83301;
    try std.testing.expect(process(&config, &runtime, &wrong_link) == null);
}

test "relay replies are routed to giaddr port 67" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.50.1" } };
    const request: packet.Packet = .{
        .op = 1,
        .xid = 1,
        .flags = 0,
        .ciaddr = 0,
        .yiaddr = 0,
        .siaddr = 0,
        .giaddr = 0xc0a832fe,
        .chaddr = [_]u8{0} ** 16,
        .hlen = 6,
    };
    const source = try std.Io.net.IpAddress.parseIp4("192.168.50.254", packet.server_port);
    const target = try replyTarget(&config, &request, &source);
    const expected = try std.Io.net.IpAddress.parseIp4("192.168.50.254", packet.server_port);
    try std.testing.expect(target.eql(&expected));
}

test "DHCP request events retain the received message type" {
    try std.testing.expectEqualStrings("dhcp.discover", requestEvent(.discover));
    try std.testing.expectEqualStrings("dhcp.request", requestEvent(.request));
    try std.testing.expectEqualStrings("dhcp.release", requestEvent(.release));
    try std.testing.expectEqualStrings("dhcp.decline", requestEvent(.decline));
}
