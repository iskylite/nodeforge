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
const config_runtime = @import("../state/config_runtime.zig");
const model_runtime = @import("../state/model_runtime.zig");
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
    /// daemon 已校验配置快照的稳定摘要。待执行的破坏性 generation
    /// 只能在此精确 revision 上启动。
    config_revision: u64 = 0,
    configs: ?*config_runtime.ConfigRuntime = null,
    /// config+catalog 一致快照边界。`persistenceRevision` 在其 gate 下取一致
    /// 快照重算 desired（config+catalog）model revision，与部署武装使用的
    /// revision 对齐；仅 config 的 revision 会使已武装节点被误判为 not armed。
    models: ?*model_runtime.ModelRuntime = null,
};

fn persistenceRevision(value: *const Persistence) u64 {
    // 部署 generation 武装在 desired（config+catalog）model revision 上
    // （`deployment_control.revisionForModel` 与 HTTP `desiredRevision` 一致）。
    // DHCP 的武装判定必须用同一把 desired revision：若退化为仅 config 的
    // `configs.currentRevision()`（revisionForConfig），已武装节点会被恒判为
    // install_not_armed，OFFER 不带 PXE bootfile，PXE 客户端不发 REQUEST，
    // 最终无法获取 DHCP 分配的 IP。在 model gate 下取一致的 config+catalog
    // 快照重算当前 desired revision，使武装后的 config/catalog 变更也能正确
    // 使旧 generation 失效。
    if (value.models) |models| {
        const pair = models.acquire();
        defer pair.release();
        const revision = deployment_control.revisionForModel(value.allocator, pair.config.value(), pair.catalog.value()) catch return value.config_revision;
        return revision.desiredRevision();
    }
    return if (value.configs) |configs| configs.currentRevision() else value.config_revision;
}

/// 在同一 UDP worker 中处理 DHCP 和 session 生命周期。
///
/// DISCOVER/REQUEST 才会创建或刷新 session；RELEASE/DECLINE 仅撤销其 lease-IP
/// 关联。这样不会把客户端的释放包误解为新的启动尝试，并让之后的 TFTP 只能按
/// 已 ACK 的唯一 IP 找到 session。
pub fn serveSocket(io: std.Io, owned: std.Io.net.Socket, configs: *config_runtime.ConfigRuntime, runtime: *runtime_state.RuntimeState, persistence: ?*const Persistence, stop: ?*const std.atomic.Value(bool)) !void {
    var socket = owned;
    defer socket.close(io);
    try serveSocketOn(io, &socket, configs, runtime, persistence, stop);
}
pub fn serveSocketOn(io: std.Io, socket: *std.Io.net.Socket, configs: *config_runtime.ConfigRuntime, runtime: *runtime_state.RuntimeState, persistence: ?*const Persistence, stop: ?*const std.atomic.Value(bool)) !void {
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
        const config_snapshot = configs.acquire();
        defer config_snapshot.release();
        const config = config_snapshot.value();
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
    const revision = persistenceRevision(p);
    const rearm = deployments.rearm(node_id, revision, requested_at, .policy_always) catch |err| {
        observe_log.err("dhcp: automatic install generation unavailable: {t}", .{err});
        return;
    };
    if (!rearm.changed) return;
    deployment_control.save(io, p.allocator, paths.require().deployment_control_path, deployments) catch |err| {
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
        .{ .key = "config_revision", .value = std.fmt.bufPrint(&revision_text, "{d}", .{revision}) catch "0" },
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
        const revision = if (persistence) |p| persistenceRevision(p) else 0;
        const decision = resolver.resolveWithDeployment(config, if (persistence) |p| p.deployments else null, revision, request.mac(), request.architecture);
        // M4.2 F9: boot-gate 事件状态转换去重。
        //
        // DHCP 客户端一次启动周期产生 4-8+ 个包（PXE 固件 DISCOVER→OFFER→
        // REQUEST→ACK + OS DISCOVER→OFFER→REQUEST→ACK + 续约 REQUEST），
        // 每个包都会经过此处的 boot-gate 检查。若每次都写事件，一个未武装
        // 节点在数秒内就会产生 8-10+ 条重复的 boot.install_not_armed 事件。
        //
        // BootGateSuppressor 维护 per-node 三态状态机（normal/not_armed/
        // deploy_disabled），仅在状态转换时返回 true，避免 events.jsonl 泛滥。
        // 详见 src/state/runtime.zig BootGateSuppressor 文档注释。
        if (decision.node_id) |node_id| {
            if (runtime.dhcp.gate_suppressor.shouldEmit(node_id, decision.install_not_armed, decision.deploy_disabled)) {
                if (decision.install_not_armed) emitInstallNotArmed(io, persistence, node_id, if (persistence) |p| p.deployments else null, revision);
                if (decision.deploy_disabled) emitDeployDisabled(io, persistence, node_id);
            }
        }
        const reply = processWithDeployment(config, runtime, request, if (persistence) |p| p.deployments else null, revision) orelse return null;
        if (reply.kind != .offer) return reply;
        // 已注册节点的显式保留地址对其 MAC 是独占的。
        // 不要因为旧客户端网络栈在固件重新获取 DHCP 时仍回答 ICMP 而让
        // 正在启动的保留节点失败。
        if (decision.reserved_ip != null) return reply;
        // 正在续约自身活动 lease 的客户端会（正确地）回答该地址的 ICMP 探测。
        // 将此回复视为冲突会在 Anaconda 上线时放弃安装器的活动 lease。
        if (runtime.dhcp.ownsActiveLease(request.mac(), reply.yiaddr, boot_session.monotonicNow())) return reply;
        switch (probe.ping(io, reply.yiaddr, config.dhcp.ping_timeout_ms)) {
            .clear => return reply,
            .occupied => {
                _ = runtime.dhcp.decline(request.mac(), boot_session.monotonicNow(), config.dhcp.abandon_seconds);
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

/// 为因无匹配已武装 generation 而被暂停的节点发出 `boot.install_not_armed` 事件
/// 和 warn 级服务日志。
///
/// 这是服务端诊断事件：被暂停的节点不存在 boot session，
/// 因此不携带任何凭据或 answer 数据。该事件有意在审计记录中可见，
/// 以便操作员了解 PXE 被拒绝的原因。
///
/// M4.3-06：事件增加 `armed_generation`、`terminal_generation`、
/// `requested_revision`、`desired_revision` 和 `next_action` 字段，
/// 同时输出 warn 级服务日志，使操作员无需查询事件流即可发现暂停原因。
///
/// M4.2 F9：调用由 `offerAfterProbe` 中的 `BootGateSuppressor.shouldEmit`
/// 控制，防止重复 DHCP 包导致事件泛滥。
fn emitInstallNotArmed(io: std.Io, persistence: ?*const Persistence, node_id: []const u8, deployments: ?*deployment_control.Store, desired_revision: u64) void {
    const p = persistence orelse return;
    // 读取 deployment control 的只读投影。节点未在 deployment store 中登记时
    // 使用全零默认值，使日志输出稳定且安全——不暴露 store 内部状态。
    const empty_view = deployment_control.View{
        .next_generation = 0,
        .armed_generation = null,
        .consumed_generation = null,
        .terminal_generation = null,
        .requested_revision = 0,
        .applied_revision = 0,
        .requested_at = 0,
        .started_at = 0,
        .finished_at = 0,
        .deployed_generation = 0,
        .deployed_at = 0,
        .requested_by = .initial,
    };
    const view = if (deployments) |d| d.view(node_id) orelse empty_view else empty_view;
    var armed_gen_buf: [24]u8 = undefined;
    var terminal_gen_buf: [24]u8 = undefined;
    var req_rev_buf: [24]u8 = undefined;
    var desired_rev_buf: [24]u8 = undefined;
    // M4.3-06 §8.2：armed_generation/terminal_generation 为 null 时显示 0，
    // 使操作员能区分“从未 arm”与“已 arm 但已 terminal”两种状态。
    const armed_gen_text = std.fmt.bufPrint(&armed_gen_buf, "{d}", .{view.armed_generation orelse 0}) catch "0";
    const terminal_gen_text = std.fmt.bufPrint(&terminal_gen_buf, "{d}", .{view.terminal_generation orelse 0}) catch "0";
    // requested_revision 是已武装 generation 锁定的 config revision；
    // desired_revision 是当前请求使用的 revision。两者不等说明
    // 配置在 arm 后发生了变更，需要重新 arm 才能匹配新计划。
    const req_rev_text = std.fmt.bufPrint(&req_rev_buf, "{d}", .{view.requested_revision}) catch "0";
    const desired_rev_text = std.fmt.bufPrint(&desired_rev_buf, "{d}", .{desired_revision}) catch "0";
    const next_action = "nodeforge node retry <node_id>";
    const fields = [_]events.Field{
        .{ .key = "node_id", .value = node_id },
        .{ .key = "armed_generation", .value = armed_gen_text },
        .{ .key = "terminal_generation", .value = terminal_gen_text },
        .{ .key = "requested_revision", .value = req_rev_text },
        .{ .key = "desired_revision", .value = desired_rev_text },
        .{ .key = "next_action", .value = next_action },
    };
    observe_log.warn("dhcp: PXE withheld for {s}: install_not_armed (armed_generation={s}, terminal_generation={s}, requested_revision={s}, desired_revision={s})", .{ node_id, armed_gen_text, terminal_gen_text, req_rev_text, desired_rev_text });
    p.writer.appendWithFields(io, p.allocator, p.events_path, "boot.install_not_armed", "install profile held: no matching armed generation", &fields) catch |err|
        observe_log.err("dhcp: install-not-armed event append failed: {t}", .{err});
}

/// M4.2 F2：当已知节点配置为 `deploy=false` 且收到 DHCP offer 时发出
/// `boot.deploy_disabled` 事件。lease 仍会发放用于诊断，但不发送 PXE bootfile。
///
/// M4.2 F9：调用由 `offerAfterProbe` 中的 `BootGateSuppressor.shouldEmit`
/// 控制，防止重复 DHCP 包导致事件泛滥。
/// 若无抑制器，`deploy=false` 节点在每个启动周期会产生 8-10+ 条事件
///（每个 DHCP 包一条）。
fn emitDeployDisabled(io: std.Io, persistence: ?*const Persistence, node_id: []const u8) void {
    const p = persistence orelse return;
    const fields = [_]events.Field{.{ .key = "node_id", .value = node_id }};
    p.writer.appendWithFields(io, p.allocator, p.events_path, "boot.deploy_disabled", "PXE denied: node deploy=false", &fields) catch |err|
        observe_log.err("dhcp: deploy-disabled event append failed: {t}", .{err});
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
            _ = runtime.dhcp.decline(client, boot_session.monotonicNow(), config.dhcp.abandon_seconds);
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
    if (typ == .discover and static_ip != null and runtime.dhcp.offer(client, selected, true, boot_session.monotonicNow(), config.dhcp.offer_seconds) == 0) return null;
    if (typ == .request and !runtime.dhcp.acknowledge(client, selected, decision.known or static_ip != null, static_ip != null, boot_session.monotonicNow(), config.dhcp.lease_seconds)) return base(.nak, 0, server_ip, mask, config, null);
    return base(if (typ == .discover) .offer else .ack, selected, server_ip, mask, config, decision.bootfile);
}
/// 从配置构建 DHCP Reply 基础结构，包含子网掩码、网关、DNS 和租约时长。
///
/// BUG 历史：此函数曾将局部 `var dns: [8]u32` 数组切片 `dns[0..count]`
/// 赋给 `Reply.dns: []const u32` 后返回。`base()` 栈帧释放后 `Reply.dns`
/// 成为悬挂指针，`encodeReply` 读到的 `len`/`ptr` 是栈垃圾，导致 OFFER/ACK
/// 中 option 6（DNS）随机丢失。实测抓包确认 OFFER 只有 Message/Subnet-Mask/
/// Lease-Time/Server-ID，无 DNS。option 3（Router）是 `?u32` 值类型不受影响，
/// 但若配置未设 `dhcp.router` 也会缺失。修复：`Reply.dns` 改为 `[8]u32` 固定
/// 数组 + `dns_len` 计数，`base()` 按值拷贝返回，消除悬挂指针。
fn base(kind: packet.MessageType, yiaddr: u32, server_ip: u32, mask: u32, config: *const model.AppConfig, bootfile: ?[]const u8) packet.Reply {
    var dns: [8]u32 = [_]u32{0} ** 8;
    var dns_len: u4 = 0;
    for (config.dhcp.dns) |value| {
        if (dns_len == dns.len) break;
        dns[dns_len] = parseIp(value) orelse continue;
        dns_len += 1;
    }
    return .{ .kind = kind, .yiaddr = yiaddr, .server_ip = server_ip, .subnet_mask = mask, .router = if (config.dhcp.router) |router| parseIp(router) else null, .dns = dns, .dns_len = dns_len, .lease_seconds = config.dhcp.lease_seconds, .bootfile = bootfile };
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
    if (requested != 0 and poolContains(config, requested) and !reservedForOther(config, requested, mac)) return runtime.dhcp.offer(mac, requested, known, boot_session.monotonicNow(), config.dhcp.offer_seconds);
    var ip = first;
    while (ip <= last) : (ip += 1) {
        if (reservedForOther(config, ip, mac)) continue;
        const allocated = runtime.dhcp.offer(mac, ip, known, boot_session.monotonicNow(), config.dhcp.offer_seconds);
        if (allocated != 0) return allocated;
    }
    return 0;
}
/// 返回当前 Unix 时间戳（秒）。用于审计事件、session/lease 检查点的墙钟
/// 时间。lease 过期判断改用 `boot_session.monotonicNow()`（MONOTONIC），避免
/// 系统时钟回拨导致活动 lease 不过期或 abandoned 隔离期异常延长。
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
    // 被暂停的破坏性 profile 仍需获得诊断 DHCP lease，
    // 但不能获取携带 capability 的 boot session。这样的 session
    // 会使安全的 `install retry` 操作返回 409，即使从未服务过安装器。
    const decision = resolver.resolveWithDeployment(config, p.deployments, persistenceRevision(p), request.mac(), request.architecture);
    if (decision.install_not_armed) return null;
    const result = p.sessions.acquireDhcp(io, .{
        .mac = request.mac(),
        .xid = request.xid,
        .node_id = decision.node_id,
        .profile = decision.profile,
        .mode = decision.mode,
        .model_revision = persistenceRevision(p),
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
    if (session.nodeId()) |node_id| {
        fields[count] = .{ .key = "node_id", .value = node_id };
        count += 1;
    }
    if (session.profileName()) |profile| {
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

test "DHCP decline via process quarantines the lease as abandoned" {
    // A4-M4：端到端验证 DECLINE 经 process() 进入 decline 分支，把活动 lease
    // 标记为 abandoned 并设置隔离期，而不是静默丢弃或重新分配。
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.50.1" },
        .dhcp = .{ .pool_start = "192.168.50.100", .pool_end = "192.168.50.110", .abandon_seconds = 300 },
    };
    var runtime: runtime_state.RuntimeState = .{};
    const mac = [_]u8{ 2, 0, 0, 0, 0, 7 };
    const chaddr = mac ++ [_]u8{0} ** 10;
    const base_pkt: packet.Packet = .{ .op = 1, .xid = 1, .flags = 0, .ciaddr = 0, .yiaddr = 0, .siaddr = 0, .giaddr = 0, .chaddr = chaddr, .hlen = 6, .architecture = .aarch64 };

    var discover = base_pkt;
    discover.message_type = .discover;
    const offer = process(&config, &runtime, &discover).?;

    var request = base_pkt;
    request.message_type = .request;
    request.requested_ip = offer.yiaddr;
    _ = process(&config, &runtime, &request).?;

    var decline = base_pkt;
    decline.message_type = .decline;
    try std.testing.expect(process(&config, &runtime, &decline) == null);

    var leases: [runtime_state.DhcpState.max_leases]runtime_state.DhcpLease = undefined;
    runtime.dhcp.snapshot(&leases);
    var found = false;
    for (leases) |lease| {
        if (lease.matches(&mac) and lease.ip == offer.yiaddr) {
            try std.testing.expectEqual(runtime_state.LeasePhase.abandoned, lease.phase);
            found = true;
        }
    }
    try std.testing.expect(found);
}
