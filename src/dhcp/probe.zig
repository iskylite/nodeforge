//! 在广告 DHCPv4 地址前使用的最小化 ICMP Echo 探测器。
//!
//! DHCP server 调用本模块时已选定候选地址，但在探测通过前不得发送 OFFER。
//! 收到匹配的 Echo Reply 表示另一台主机已占用该地址。Raw socket 或 I/O
//! 失败不等同于探测通过：调用方必须扣留 OFFER 并取消该待定分配，
//! 而非冒地址碰撞的风险。
//!
//! 安全说明：
//! - daemon 需要 CAP_NET_RAW 能力才能创建 raw socket
//! - ICMP identifier 使用 0x4e46（"NF"），sequence 从候选 IP 派生，
//!   防止无关 ICMP 流量被误判为地址占用
//! - 使用单个绝对超时截止时间，防止 Linux raw socket 收到自身发出的
//!   Echo Request 后无限延长探测窗口

const std = @import("std");

/// ICMP 探测结果。
pub const Result = enum {
    /// 在配置的等待时间内未收到匹配的 Echo Reply；地址可安全分配。
    clear,
    /// 收到匹配的 Echo Reply，说明该地址已被其他主机占用。
    occupied,
    /// 无法打开 raw socket、发送或接收 ICMP 报文。
    /// 这通常表示缺少 CAP_NET_RAW 能力；调用方应扣留 OFFER 而非冒险分配。
    unavailable,
};

/// 发送一个 ICMPv4 Echo Request，总等待时间不超过 `timeout_ms`。
///
/// 序列号从候选 IPv4 地址派生；与固定标识符（0x4e46 = "NF"）一起，
/// 防止无关 ICMP 流量被误判为该地址已被占用的证据。
///
/// Linux raw socket 会同时收到自身发出的 Echo Request，因此使用单个
/// 绝对超时截止时间来确保探测窗口不会被延长。
pub fn ping(io: std.Io, ip: u32, timeout_ms: u16) Result {
    const source = std.Io.net.IpAddress.parseIp4("0.0.0.0", 0) catch return .unavailable;
    var socket = source.bind(io, .{ .mode = .raw, .protocol = .icmp }) catch return .unavailable;
    defer socket.close(io);

    const target = ipAddress(ip);
    // ICMP identifier：固定为 0x4e46（ASCII "NF"），用于区分 NodeForge 探测
    const identifier: u16 = 0x4e46;
    // sequence 从候选 IP 派生，使不同地址的探测不可互换
    const sequence: u16 = @truncate(ip);
    // ICMP Echo Request：type=8, code=0, checksum=0（后续计算）,
    // identifier + sequence（标识符与序列号）
    var request = [_]u8{ 8, 0, 0, 0, 0x4e, 0x46, @truncate(sequence >> 8), @truncate(sequence) };
    const sum = checksum(&request);
    request[2] = @truncate(sum >> 8);
    request[3] = @truncate(sum);
    socket.send(io, &target, &request) catch return .unavailable;

    // 使用绝对截止时间而非每次重置超时，防止收到自身 Echo Request后
    // 无限延长探测窗口
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
        // Linux raw socket 会收到自身发出的 Echo Request。使用单个绝对截止时间
        // 防止该包或其他 ICMP 噪声隐藏真正的 Echo Reply 或无限延长探测窗口。
        if (isReply(incoming.data, identifier, sequence)) return .occupied;
    }
}

/// 检查接收到的 ICMP 报文是否为匹配的 Echo Reply。
///
/// 匹配条件：
/// - ICMP type = 0（Echo Reply）
/// - ICMP code = 0（码值为 0）
/// - identifier 和 sequence 与发送时一致
///
/// Raw IPv4 socket 收到的数据包含 IP 头部，需要先跳过 IP 头部。
/// IP 头部长度由 IHL 字段（第一个字节的低 4 位）决定，以 4 字节为单位。
fn isReply(bytes: []const u8, identifier: u16, sequence: u16) bool {
    // Raw IPv4 socket 收到的数据包含 IP 头部。IHL 以字（4 字节）为单位。
    if (bytes.len < 28) return false;
    const header_len: usize = @as(usize, bytes[0] & 0x0f) * 4;
    if (header_len < 20 or bytes.len < header_len + 8) return false;
    const icmp = bytes[header_len..];
    return icmp[0] == 0 and icmp[1] == 0 and
        std.mem.readInt(u16, icmp[4..6], .big) == identifier and
        std.mem.readInt(u16, icmp[6..8], .big) == sequence;
}

/// 计算 ICMP 校验和（RFC 1071）。
/// 16 位反码求和，结果取反。
fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) sum += std.mem.readInt(u16, bytes[i..][0..2], .big);
    if (i < bytes.len) sum += @as(u16, bytes[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

/// 将 32 位大端序 IPv4 地址转换为 IpAddress。
fn ipAddress(ip: u32) std.Io.net.IpAddress {
    var text: [16]u8 = undefined;
    const rendered = std.fmt.bufPrint(&text, "{d}.{d}.{d}.{d}", .{ (ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255 }) catch unreachable;
    return std.Io.net.IpAddress.parseIp4(rendered, 0) catch unreachable;
}

// 测试：ICMP 校验和与 RFC 1071 示例一致。
test "ICMP checksum matches RFC 1071 example" {
    try std.testing.expectEqual(@as(u16, 0x220d), checksum(&.{ 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 }));
}

// 测试：验证能正确识别匹配的 ICMP Echo Reply（跳过 IP 头部后）。
test "recognizes matching ICMP echo reply after IPv4 header" {
    var reply = [_]u8{0} ** 28;
    reply[0] = 0x45; // IPv4, IHL = 5 words（20 字节头）
    reply[20] = 0; // Echo Reply（回显应答）
    reply[21] = 0;
    std.mem.writeInt(u16, reply[24..26], 0x4e46, .big);
    std.mem.writeInt(u16, reply[26..28], 0x1234, .big);
    try std.testing.expect(isReply(&reply, 0x4e46, 0x1234));
    try std.testing.expect(!isReply(&reply, 0x4e46, 0x1235));
}
