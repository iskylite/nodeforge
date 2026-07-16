//! DHCP lease 的持久化投影（M3.1）。
//!
//! `leases.json` 是 DHCP lease 状态的唯一持久化事实源。checkpoint worker
//! 是唯一写入者；DHCP 热路径只递增 `lease_generation`。损坏的快照被加载器
//! 拒绝而非静默复用。旧版 `runtime.json` 文件（合并了 lease 和节点状态）
//! 仅作为迁移输入接受。

const std = @import("std");
const runtime = @import("runtime.zig");
const node_status = @import("node_status.zig");

/// M3.1 `leases.json` schema。只包含 DHCP lease 和显示时间戳。
pub const LeasesFile = struct {
    /// schema 版本；M3.1 使用版本 3。
    schema_version: u32 = 3,
    /// 保存时的 Unix 时间戳。
    saved_at: i64,
    /// DHCP lease 列表。
    leases: []const runtime.DhcpLease,
};

/// 旧版 `runtime.json` schema（schema 1/2），仅用于迁移时接受。
/// 同时包含 lease 和 status；加载器只提取 lease 并忽略 status 部分
///（status 由 `status_store.zig` 独立处理）。
pub const LegacyRuntimeFile = struct {
    schema_version: u32 = 2,
    saved_at: i64 = 0,
    leases: []const runtime.DhcpLease = &.{},
    statuses: []const node_status.Status = &.{},
};

/// 原子保存 DHCP lease 快照到 `leases.json`。
/// 调用方必须已在 DhcpState mutex 下获取一致快照（通过 `snapshotWithGeneration`）。
pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, leases: *const [runtime.DhcpState.max_leases]runtime.DhcpLease, now: i64) !void {
    var compact: [runtime.DhcpState.max_leases]runtime.DhcpLease = undefined;
    var count: usize = 0;
    for (leases) |lease| {
        if (!lease.used()) continue;
        compact[count] = lease;
        count += 1;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(LeasesFile{ .saved_at = now, .leases = compact[0..count] }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try atomicWrite(io, path, output.written());
}

/// 加载 `leases.json` 并将未过期的 lease 恢复到 `state` 中。
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, state: *runtime.DhcpState, now: i64) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(LeasesFile, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value.schema_version != 3 or parsed.value.leases.len > runtime.DhcpState.max_leases) return error.InvalidLeasesState;
    var snapshot = [_]runtime.DhcpLease{.{}} ** runtime.DhcpState.max_leases;
    for (parsed.value.leases, 0..) |lease, i| {
        if (lease.used() and lease.expires_at > now) snapshot[i] = lease;
    }
    state.restore(&snapshot);
}

/// 从旧版 `runtime.json` 文件迁移 lease。只提取 lease 部分；
/// status 部分由 `status_store.zig` 处理。
pub fn migrateLegacy(io: std.Io, allocator: std.mem.Allocator, path: []const u8, state: *runtime.DhcpState, now: i64) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(LegacyRuntimeFile, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if ((parsed.value.schema_version != 1 and parsed.value.schema_version != 2) or parsed.value.leases.len > runtime.DhcpState.max_leases) return error.InvalidRuntimeState;
    var snapshot = [_]runtime.DhcpLease{.{}} ** runtime.DhcpState.max_leases;
    for (parsed.value.leases, 0..) |lease, i| {
        if (lease.used() and lease.expires_at > now) snapshot[i] = lease;
    }
    state.restore(&snapshot);
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
