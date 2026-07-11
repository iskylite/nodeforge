//! M2 authoritative DHCPv4 listener.  The protocol engine is separated from
//! this loop so packet fixtures and an unprivileged UDP test socket share it.
const std = @import("std");
const builtin = @import("builtin");
const model = @import("../model.zig");
const packet = @import("packet.zig");
const probe = @import("probe.zig");
const resolver = @import("../boot/resolver.zig");
const runtime_state = @import("../state/runtime.zig");
const dhcp_store = @import("../state/dhcp_store.zig");
const events = @import("../state/events.zig");
const observe_log = @import("../observe/log.zig");
pub const port = packet.server_port;
/// Linux delivers `255.255.255.255:67` DHCP broadcasts only to a wildcard
/// socket, not to one bound solely to `server.server_ip`.  Bind wildcard on
/// Linux and restrict the socket to the configured PXE NIC so a multihomed
/// host cannot accidentally answer requests received on its management LAN.
///
/// Other platforms retain the advertised-address bind for local development;
/// production DHCP is currently validated and supported on Linux only.
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
pub const Persistence = struct { allocator: std.mem.Allocator, runtime_path: []const u8, events_path: []const u8, writer: *events.Writer };
pub fn serveSocket(io: std.Io, owned: std.Io.net.Socket, config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, persistence: ?*const Persistence) !void {
    var socket = owned;
    defer socket.close(io);
    try serveSocketOn(io, &socket, config, runtime, persistence);
}
pub fn serveSocketOn(io: std.Io, socket: *std.Io.net.Socket, config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, persistence: ?*const Persistence) !void {
    while (true) {
        var bytes: [1500]u8 = undefined;
        const incoming = try socket.receive(io, &bytes);
        const request = packet.parse(incoming.data) catch |err| {
            observe_log.debug("dhcp: dropped malformed packet: {t}", .{err});
            continue;
        };
        audit(io, persistence, requestEvent(request.message_type orelse .inform), request.message_type orelse .inform, request.mac(), 0);
        const reply = offerAfterProbe(io, config, runtime, &request, persistence) orelse {
            persist(io, persistence, runtime);
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
        audit(io, persistence, switch (reply.kind) {
            .offer => "dhcp.offer",
            .ack => "dhcp.ack",
            .nak => "dhcp.nak",
            else => "dhcp.reply",
        }, reply.kind, request.mac(), reply.yiaddr);
        persist(io, persistence, runtime);
        observe_log.info("dhcp: {t} -> {t} yiaddr={x}", .{ request.message_type orelse .inform, reply.kind, reply.yiaddr });
    }
}

/// Ensure an offer is conflict-free before it can leave the process. A failed
/// raw ICMP probe produces no DHCP reply; treating it as a clear probe would
/// allow a lease collision on hosts lacking CAP_NET_RAW.
fn offerAfterProbe(io: std.Io, config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, request: *const packet.Packet, persistence: ?*const Persistence) ?packet.Reply {
    var attempts: usize = 0;
    while (attempts < runtime_state.DhcpState.max_leases) : (attempts += 1) {
        const reply = process(config, runtime, request) orelse return null;
        if (reply.kind != .offer) return reply;
        switch (probe.ping(io, reply.yiaddr, config.dhcp.ping_timeout_ms)) {
            .clear => return reply,
            .occupied => {
                _ = runtime.dhcp.decline(request.mac(), now(), config.dhcp.abandon_seconds);
                audit(io, persistence, "dhcp.abandoned", .decline, request.mac(), reply.yiaddr);
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
fn persist(io: std.Io, persistence: ?*const Persistence, runtime: *runtime_state.RuntimeState) void {
    const p = persistence orelse return;
    dhcp_store.save(io, p.allocator, p.runtime_path, &runtime.dhcp, now()) catch |err| observe_log.err("dhcp: runtime persistence failed: {t}", .{err});
}
fn audit(io: std.Io, persistence: ?*const Persistence, event_type: []const u8, kind: packet.MessageType, mac: []const u8, ip: u32) void {
    const p = persistence orelse return;
    var msg: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&msg, "kind={t} mac={x} ip={x}", .{ kind, mac, ip }) catch return;
    var ts: [32]u8 = undefined;
    const stamp = std.fmt.bufPrint(&ts, "{s}{d}", .{ events.unix_timestamp_prefix, now() }) catch return;
    p.writer.append(io, p.allocator, p.events_path, .{ .ts = stamp, .type = event_type, .message = text }) catch |err| observe_log.err("dhcp: event append failed: {t}", .{err});
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
