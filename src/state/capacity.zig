//! M4.8 启动时容量与并发的动态派生。
//!
//! 替代硬编码的 256 上限与 TFTP 固定并发默认值。所有派生均取
//! `max(按来源计算, config 显式覆盖)`，绝不因派生缩小运维意图。
//! 详见 docs/archive/M0_M7_LEGACY_DETAILED_DESIGN.md §9.17 与
//! docs/archive/milestone-specs/2026-07-17-concurrency-capacity-scaling-design.md。

const std = @import("std");

/// 持久 daemon 中共享热路径状态表的编译期安全天花板。
/// 固定上限避免协议 worker 在锁内分配，并提供可预测的内存占用；
/// `effective` 是允许的已用条目数，而不是数组前缀长度。
pub const store_ceiling: usize = 2048;

/// 解析点分十进制 IPv4 为 u32；非法返回 null。
fn parseIpv4U32(s: []const u8) ?u32 {
    var parts: [4]u32 = .{ 0, 0, 0, 0 };
    var idx: usize = 0;
    var iter = std.mem.splitScalar(u8, s, '.');
    while (iter.next()) |seg| {
        if (idx >= 4) return null;
        if (seg.len == 0 or seg.len > 3) return null;
        var v: u32 = 0;
        for (seg) |ch| {
            if (ch < '0' or ch > '9') return null;
            v = v * 10 + (ch - '0');
        }
        if (v > 255) return null;
        parts[idx] = v;
        idx += 1;
    }
    if (idx != 4) return null;
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
}

/// 解析 CIDR 子网前缀，返回可用主机数（2^(32-prefix)-2）。
/// 与 `src/dhcp/server.zig` 的 `network()` 一致，仅接受 prefix <= 30；
/// /31、/32 或非法 CIDR 返回 0（不作为 lease 容量来源）。
pub fn usableHosts(cidr: []const u8) usize {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return 0;
    if (parseIpv4U32(cidr[0..slash]) == null) return 0;
    const prefix = std.fmt.parseInt(u6, cidr[slash + 1 ..], 10) catch return 0;
    if (prefix > 30) return 0;
    const host_bits: u6 = 32 - prefix;
    return (@as(usize, 1) << host_bits) - 2;
}

/// 并发容量（leases + sessions）：max(usable_hosts(subnet), config 覆盖)，下限 1。
pub fn leaseCapacity(subnet: []const u8, config_override: ?u32) usize {
    const derived = usableHosts(subnet);
    const cap = if (config_override) |o| @max(derived, @as(usize, o)) else derived;
    return @max(cap, 1);
}

/// 受管容量（status/inventory/deployment）：max(受管节点数, config 覆盖)，下限 1。
pub fn managedCapacity(node_count: usize, config_override: ?u32) usize {
    const cap = if (config_override) |o| @max(node_count, @as(usize, o)) else node_count;
    return @max(cap, 1);
}

/// TFTP 并发：config 覆盖优先，否则 max(128, 2×核)，封顶 u16。
pub fn tftpConcurrency(cpu_count: usize, config_override: ?u16) u16 {
    if (config_override) |o| return o;
    const doubled: usize = cpu_count *| 2;
    const v: usize = @max(128, doubled);
    return @intCast(@min(v, 65535));
}

test "usableHosts parses CIDR prefix" {
    try std.testing.expectEqual(@as(usize, 254), usableHosts("192.168.27.0/24"));
    try std.testing.expectEqual(@as(usize, 1022), usableHosts("192.168.0.0/22"));
    try std.testing.expectEqual(@as(usize, 65534), usableHosts("10.0.0.0/16"));
    try std.testing.expectEqual(@as(usize, 0), usableHosts("192.168.27.0/31"));
    try std.testing.expectEqual(@as(usize, 0), usableHosts("not-a-cidr"));
    try std.testing.expectEqual(@as(usize, 0), usableHosts("192.168.27.0"));
}

test "leaseCapacity takes max of subnet-derived and config override" {
    // /22 -> 1022，覆盖更小则取派生
    try std.testing.expectEqual(@as(usize, 1022), leaseCapacity("192.168.0.0/22", 256));
    // 覆盖更大则取覆盖
    try std.testing.expectEqual(@as(usize, 2048), leaseCapacity("192.168.0.0/22", 2048));
    // 无覆盖取派生
    try std.testing.expectEqual(@as(usize, 254), leaseCapacity("192.168.27.0/24", null));
    // 非法子网 + 覆盖取覆盖
    try std.testing.expectEqual(@as(usize, 512), leaseCapacity("bad", 512));
    // 全空下限 1
    try std.testing.expectEqual(@as(usize, 1), leaseCapacity("bad", null));
}

test "managedCapacity takes max of node count and override" {
    try std.testing.expectEqual(@as(usize, 1024), managedCapacity(1024, null));
    try std.testing.expectEqual(@as(usize, 2048), managedCapacity(100, 2048));
    try std.testing.expectEqual(@as(usize, 100), managedCapacity(100, 50));
    try std.testing.expectEqual(@as(usize, 1), managedCapacity(0, null));
}

test "tftpConcurrency auto-derives max(128, 2x cores) when no override" {
    try std.testing.expectEqual(@as(u16, 128), tftpConcurrency(8, null)); // 2x8=16 < 128
    try std.testing.expectEqual(@as(u16, 128), tftpConcurrency(64, null)); // 2x64=128
    try std.testing.expectEqual(@as(u16, 192), tftpConcurrency(96, null)); // 2x96=192
    try std.testing.expectEqual(@as(u16, 256), tftpConcurrency(128, null)); // 2x128=256
    // 超大核数封顶 u16
    try std.testing.expectEqual(@as(u16, 65535), tftpConcurrency(40000, null));
    // 覆盖优先
    try std.testing.expectEqual(@as(u16, 4), tftpConcurrency(96, 4));
    try std.testing.expectEqual(@as(u16, 255), tftpConcurrency(8, 255));
}
