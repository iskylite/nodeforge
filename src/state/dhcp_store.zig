//! DHCP lease 的持久化投影（M3.1）。
//!
//! `leases.json` 是 DHCP lease 状态的唯一持久化事实源。checkpoint worker
//! 是唯一写入者；DHCP 热路径只递增 `lease_generation`。损坏的快照被加载器
//! 拒绝而非静默复用。旧版 `runtime.json` 文件（合并了 lease 和节点状态）
//! 仅作为迁移输入接受。

const std = @import("std");
const runtime = @import("runtime.zig");

/// M3.1 `leases.json` schema。只包含 DHCP lease 和显示时间戳。
pub const LeasesFile = struct {
    /// schema 版本；M3.1 使用版本 3。
    schema_version: u32 = 3,
    /// 保存时的 Unix 时间戳。
    saved_at: i64,
    /// DHCP lease 列表。
    leases: []const runtime.DhcpLease,
};

/// 原子保存 DHCP lease 快照到 `leases.json`。
/// 调用方必须已在 DhcpState mutex 下获取一致快照（通过 `snapshotWithGeneration`）。
pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, leases: *const [runtime.DhcpState.max_leases]runtime.DhcpLease, now: i64, mono_now: i64) !void {
    var compact: [runtime.DhcpState.max_leases]runtime.DhcpLease = undefined;
    var count: usize = 0;
    for (leases) |lease| {
        if (!lease.used()) continue;
        compact[count] = lease;
        // runtime 以 MONOTONIC 维护 expires_at；持久化为 Unix 绝对时间戳，
        // 使重启后即使单调时钟归零仍能与墙钟比较恢复未过期 lease。
        compact[count].expires_at = now + (lease.expires_at - mono_now);
        count += 1;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(LeasesFile{ .saved_at = now, .leases = compact[0..count] }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try atomicWrite(io, path, output.written());
}

/// 加载 `leases.json` 并将未过期的 lease 恢复到 `state` 中。
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, state: *runtime.DhcpState, now: i64, mono_now: i64) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(LeasesFile, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value.schema_version != 3 or parsed.value.leases.len > runtime.DhcpState.max_leases) return error.InvalidLeasesState;
    var snapshot = [_]runtime.DhcpLease{.{}} ** runtime.DhcpState.max_leases;
    for (parsed.value.leases, 0..) |lease, i| {
        // 持久化的 expires_at 是 Unix 绝对时间戳；与当前墙钟比较判断未过期，
        // 再换算回 MONOTONIC 基准供运行期 reapLocked 使用。
        if (lease.used() and lease.expires_at > now) {
            snapshot[i] = lease;
            snapshot[i].expires_at = mono_now + (lease.expires_at - now);
        }
    }
    state.restore(&snapshot);
}

test "save/load round-trip converts lease expiry between monotonic and realtime" {
    // A3-M3：runtime 以 MONOTONIC 维护 expires_at，持久化为 Unix 绝对时间戳，
    // 重启后单调时钟归零仍能正确恢复未过期 lease。
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/leases.json", .{root_buf[0..root_len]});
    defer std.testing.allocator.free(path);

    var state: runtime.DhcpState = .{};
    const mac = [_]u8{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    // 活动 lease：mono 基准 1000，100s 后过期 -> expires_at=1100。
    _ = state.offer(&mac, 0xc0a81b0a, true, 1000, 100);
    _ = state.acknowledge(&mac, 0xc0a81b0a, true, false, 1000, 100);
    var leases: [runtime.DhcpState.max_leases]runtime.DhcpLease = undefined;
    _ = state.snapshotWithGeneration(&leases);
    // save：realtime=2000，mono=1000。持久化 expires_at = 2000 + (1100-1000) = 2100。
    try save(std.testing.io, std.testing.allocator, path, &leases, 2000, 1000);

    // load：realtime 推进到 2050（lease 仍有效，2100>2050），mono 重置为 5。
    // 恢复 expires_at = 5 + (2100-2050) = 75（mono 基准）。
    var restored: runtime.DhcpState = .{};
    try load(std.testing.io, std.testing.allocator, path, &restored, 2050, 5);
    // lease 在 mono=5 时仍有效；推进到 mono=75 时过期。
    try std.testing.expect(restored.ownsActiveLease(&mac, 0xc0a81b0a, 5));
    try std.testing.expect(!restored.ownsActiveLease(&mac, 0xc0a81b0a, 75));

    // 已过期 lease 不应被恢复：save 时 mono=1000 但 load 时 realtime=2200（>2100）。
    try save(std.testing.io, std.testing.allocator, path, &leases, 2100, 1000);
    var restored_expired: runtime.DhcpState = .{};
    try load(std.testing.io, std.testing.allocator, path, &restored_expired, 2200, 5);
    try std.testing.expect(!restored_expired.ownsActiveLease(&mac, 0xc0a81b0a, 5));
}

/// 共享的单文件持久化协议：写入临时文件、fsync 临时文件、rename、
/// fsync 父目录。
pub fn atomicWrite(io: std.Io, path: []const u8, content: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    const temp = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp", .{path});
    defer std.heap.page_allocator.free(temp);
    errdefer dir.deleteFile(io, temp) catch {};
    {
        var file = try dir.createFile(io, temp, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, content);
        try file.sync(io);
    }
    try std.Io.Dir.rename(dir, temp, dir, path, io);
    try syncParentDirectory(io, path);
}

/// 持久化 `rename` 创建的目录项，完成原子替换协议。
/// 某些文件系统在文件数据到达磁盘后需要显式同步目录才能使 rename 生效。
fn syncParentDirectory(io: std.Io, path: []const u8) !void {
    const parent_path = std.fs.path.dirname(path) orelse return;
    var parent = if (std.fs.path.isAbsolute(parent_path))
        try std.Io.Dir.openFileAbsolute(io, parent_path, .{ .allow_directory = true })
    else
        try std.Io.Dir.cwd().openFile(io, parent_path, .{ .allow_directory = true });
    defer parent.close(io);
    try parent.sync(io);
}
