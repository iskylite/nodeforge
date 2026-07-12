//! 在广告 DHCPv4 地址前使用的最小化 ICMP Echo 探测器。
//!
//! DHCP server 调用本模块时已选定候选地址，但在探测通过前不得发送 OFFER。
//! 收到匹配的 Echo Reply 表示另一台主机已占用该地址。Raw socket 或 I/O
//! 失败不等同于探测通过：调用方必须扣留 OFFER 并取消该待定分配，
//! 而非冒地址碰撞的风险。
const std = @import("std");

pub const Result = enum {
    /// The full configured wait elapsed without a matching Echo Reply.
    clear,
    /// An Echo Reply matched this request's NodeForge identifier and sequence.
    occupied,
    /// A raw socket could not be opened, sent, or read. CAP_NET_RAW is required.
    unavailable,
};

/// 发送一个 ICMPv4 Echo Request，总等待时间不超过 `timeout_ms`。
/// 序列号从候选 IPv4 地址派生；与固定标识符一起，防止无关 ICMP 流量
/// 被误判为该地址已被占用的证据。
pub fn ping(io: std.Io, ip: u32, timeout_ms: u16) Result {
    const source = std.Io.net.IpAddress.parseIp4("0.0.0.0", 0) catch return .unavailable;
    var socket = source.bind(io, .{ .mode = .raw, .protocol = .icmp }) catch return .unavailable;
    defer socket.close(io);

    const target = ipAddress(ip);
    const identifier: u16 = 0x4e46; // "NF"
    const sequence: u16 = @truncate(ip);
    var request = [_]u8{ 8, 0, 0, 0, 0x4e, 0x46, @truncate(sequence >> 8), @truncate(sequence) };
    const sum = checksum(&request);
    request[2] = @truncate(sum >> 8);
    request[3] = @truncate(sum);
    socket.send(io, &target, &request) catch return .unavailable;

    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms },
        .clock = .awake,
    });
    while (true) {
        var received: [256]u8 = undefined;
        const incoming = socket.receiveTimeout(io, &received, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => return .clear,
            else => return .unavailable,
        };
        // Linux raw sockets also receive the outgoing Echo Request. Keeping a
        // single absolute deadline prevents that packet, or other ICMP noise,
        // from either concealing the Echo Reply or extending the configured
        // probe window indefinitely.
        if (isReply(incoming.data, identifier, sequence)) return .occupied;
    }
}

fn isReply(bytes: []const u8, identifier: u16, sequence: u16) bool {
    // Raw IPv4 sockets include the IP header. Its IHL is measured in words.
    if (bytes.len < 28) return false;
    const header_len: usize = @as(usize, bytes[0] & 0x0f) * 4;
    if (header_len < 20 or bytes.len < header_len + 8) return false;
    const icmp = bytes[header_len..];
    return icmp[0] == 0 and icmp[1] == 0 and
        std.mem.readInt(u16, icmp[4..6], .big) == identifier and
        std.mem.readInt(u16, icmp[6..8], .big) == sequence;
}

fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) sum += std.mem.readInt(u16, bytes[i..][0..2], .big);
    if (i < bytes.len) sum += @as(u16, bytes[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

fn ipAddress(ip: u32) std.Io.net.IpAddress {
    var text: [16]u8 = undefined;
    const rendered = std.fmt.bufPrint(&text, "{d}.{d}.{d}.{d}", .{ (ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255 }) catch unreachable;
    return std.Io.net.IpAddress.parseIp4(rendered, 0) catch unreachable;
}

test "ICMP checksum matches RFC 1071 example" {
    try std.testing.expectEqual(@as(u16, 0x220d), checksum(&.{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 }));
}

test "recognizes matching ICMP echo reply after IPv4 header" {
    var reply = [_]u8{0} ** 28;
    reply[0] = 0x45; // IPv4, IHL = 5 words
    reply[20] = 0; // Echo Reply
    reply[21] = 0;
    std.mem.writeInt(u16, reply[24..26], 0x4e46, .big);
    std.mem.writeInt(u16, reply[26..28], 0x1234, .big);
    try std.testing.expect(isReply(&reply, 0x4e46, 0x1234));
    try std.testing.expect(!isReply(&reply, 0x4e46, 0x1235));
}
