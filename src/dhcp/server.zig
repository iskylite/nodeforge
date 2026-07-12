//! M2 authoritative DHCPv4 listener.  The protocol engine is separated from
//! this loop so packet fixtures and an unprivileged UDP test socket share it.
const std = @import("std");
const builtin = @import("builtin");
const model = @import("../model.zig");
const packet = @import("packet.zig");
const probe = @import("probe.zig");
const resolver = @import("../boot/resolver.zig");
const runtime_state = @import("../state/runtime.zig");
const boot_session = @import("../state/boot_session.zig");
const events = @import("../state/events.zig");
const observe_log = @import("../observe/log.zig");
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
        // SO_BINDTODEVICE expects an IFNAMSIZ-sized, NUL-terminated buffer.
        // Passing the full buffer also rejects silently truncated NIC names.
        var device: [16]u8 = [_]u8{0} ** 16;
        if (name.len >= device.len) return error.DhcpBindInterfaceTooLong;
        @memcpy(device[0..name.len], name);
        try std.posix.setsockopt(socket.handle, std.posix.SOL.SOCKET, std.posix.SO.BINDTODEVICE, &device);
    }
    return socket;
}
pub const Persistence = struct {
    allocator: std.mem.Allocator,
    events_path: []const u8,
    writer: *events.Writer,
    sessions: *boot_session.Store,
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
            // An OFFER is only a short-lived reservation.  It must not make
            // the advertised address a bootstrap proof: only a successful
            // REQUEST/ACK creates a lease-to-peer association that M3 HTTP
            // authentication may rely on.
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

/// 确保 OFFER 在离开进程前是无冲突的。原始 ICMP 探测失败时不产生
/// DHCP 回复；将其视为探测通过将允许在缺少 CAP_NET_RAW 的主机上发生
/// lease 碰撞。
fn offerAfterProbe(io: std.Io, config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, request: *const packet.Packet, persistence: ?*const Persistence, session_link: ?*const boot_session.Link) ?packet.Reply {
    var attempts: usize = 0;
    while (attempts < runtime_state.DhcpState.max_leases) : (attempts += 1) {
        const reply = process(config, runtime, request) orelse return null;
        if (reply.kind != .offer) return reply;
        // A registered node's explicit reservation is exclusive to its MAC.
        // Do not make a booting reserved node fail just because an old guest
        // network stack still answers ICMP while firmware is reacquiring DHCP.
        if (resolver.resolve(config, request.mac(), request.architecture).reserved_ip != null) return reply;
        // A client renewing its own active lease will (correctly) answer an
        // ICMP probe for that address.  Treating that reply as a conflict
        // abandons the installer's live lease just as Anaconda comes online.
        if (runtime.dhcp.ownsActiveLease(request.mac(), reply.yiaddr, now())) return reply;
        switch (probe.ping(io, reply.yiaddr, config.dhcp.ping_timeout_ms)) {
            .clear => return reply,
            .occupied => {
                _ = runtime.dhcp.decline(request.mac(), now(), config.dhcp.abandon_seconds);
                audit(io, persistence, config, "dhcp.abandoned", request.message_type orelse .inform, .decline, request.mac(), reply.yiaddr, request.xid, request.architecture, session_link);
            },
            .unavailable => {
                observe_log.err("dhcp: ping probe unavailable; refusing offer", .{});
                // `process` creates a short-lived OFFER before this point.
                // Do not reserve an address when the probe itself was not
                // trustworthy, while preserving any unrelated active lease.
                _ = runtime.dhcp.cancelOffer(request.mac(), reply.yiaddr);
                return null;
            },
        }
    }
    observe_log.err("dhcp: no unchecked candidate remained after ping probes", .{});
    return null;
}
pub fn process(config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, request: *const packet.Packet) ?packet.Reply {
    const typ = request.message_type orelse return null;
    const server_ip = parseIp(config.server.server_ip) orelse return null;
    const net = network(config.dhcp.subnet) orelse return null;
    const relay_link = request.link_selection orelse request.giaddr;
    if (relay_link != 0 and !inNetwork(relay_link, config.dhcp.subnet, net.prefix)) return null;
    const mask = prefixMask(net.prefix);
    const client = request.mac();
    const decision = resolver.resolve(config, client, request.architecture);
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
fn acquireSession(io: std.Io, persistence: ?*const Persistence, config: *const model.AppConfig, request: *const packet.Packet) boot_session.Link {
    const p = persistence orelse return .capacity_exhausted;
    const decision = resolver.resolve(config, request.mac(), request.architecture);
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
fn formatIp(buffer: *[16]u8, ip: u32) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{ (ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255 });
}
fn poolContains(config: *const model.AppConfig, ip: u32) bool {
    const first = parseIp(config.dhcp.pool_start) orelse return false;
    const last = parseIp(config.dhcp.pool_end) orelse return false;
    return ip >= first and ip <= last;
}
fn reservedForOther(config: *const model.AppConfig, ip: u32, mac: []const u8) bool {
    for (config.nodes) |node| {
        const reserved = if (node.ip) |value| parseIp(value) else null;
        if (reserved != null and reserved.? == ip and !resolver.sameMac(node.mac, mac)) return true;
    }
    return false;
}
const Net = struct { prefix: u6 };
fn network(cidr: []const u8) ?Net {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return null;
    _ = parseIp(cidr[0..slash]) orelse return null;
    const prefix = std.fmt.parseInt(u6, cidr[slash + 1 ..], 10) catch return null;
    return if (prefix <= 30) .{ .prefix = prefix } else null;
}
fn inNetwork(ip: u32, cidr: []const u8, prefix: u6) bool {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return false;
    const subnet = parseIp(cidr[0..slash]) orelse return false;
    return (ip & prefixMask(prefix)) == (subnet & prefixMask(prefix));
}
fn prefixMask(prefix: u6) u32 {
    return if (prefix == 0) 0 else @as(u32, 0xffffffff) << @as(u5, @intCast(32 - prefix));
}
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
/// RFC 2131 section 4.1 response routing: relayed requests return to giaddr:67;
/// clients without ciaddr receive a broadcast reply, which is required for a
/// real DHCP client before it has configured the offered address.
fn replyTarget(config: *const model.AppConfig, request: *const packet.Packet, received_from: *const std.Io.net.IpAddress) !std.Io.net.IpAddress {
    if (request.giaddr != 0) return ipAddress(request.giaddr, port);
    if (request.ciaddr != 0 and (request.flags & 0x8000) == 0) return ipAddress(request.ciaddr, packet.client_port);
    const net = network(config.dhcp.subnet) orelse return error.InvalidSubnet;
    const subnet = parseIp(config.dhcp.subnet[0..std.mem.indexOfScalar(u8, config.dhcp.subnet, '/').?]) orelse return error.InvalidSubnet;
    const broadcast = (subnet & prefixMask(net.prefix)) | ~prefixMask(net.prefix);
    _ = received_from;
    return ipAddress(broadcast, packet.client_port);
}
fn ipAddress(value: u32, value_port: u16) !std.Io.net.IpAddress {
    var text: [16]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&text, "{d}.{d}.{d}.{d}", .{ (value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255 });
    return std.Io.net.IpAddress.parseIp4(rendered, value_port);
}
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
