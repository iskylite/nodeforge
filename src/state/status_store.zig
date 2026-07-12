//! Durable projection of node status (M3.1).
//!
//! `node-status.json` is the sole durable fact source for the HTTP node-status
//! projection.  It uses its own I/O lock, independent from the DHCP checkpoint
//! lock, so HTTP status transitions never contend with DHCP lease persistence.
//! A corrupt snapshot is rejected by the loader.  Legacy `runtime.json` files
//! are accepted as migration input only for the status portion.

const std = @import("std");
const node_status = @import("node_status.zig");
const runtime = @import("runtime.zig");
const dhcp_store = @import("dhcp_store.zig");

/// M3.1 `node-status.json` schema.
pub const StatusFile = struct {
    schema_version: u32 = 3,
    saved_at: i64,
    statuses: []const node_status.Status,
};

/// I/O mutex for `node-status.json`.  This is deliberately separate from the
/// DHCP checkpoint lock so HTTP status saves never block or be blocked by
/// DHCP lease persistence.
io_mutex: std.atomic.Mutex = .unlocked,

/// 原子保存节点状态快照到 `node-status.json`。
/// 调用方必须已在 node_status.Store mutex 下获取一致快照（通过 `snapshot`）。
pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, statuses: *const [node_status.max_statuses]node_status.Status, now: i64) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(StatusFile{ .saved_at = now, .statuses = statuses }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try dhcp_store.atomicWrite(io, path, output.written());
}

/// 加载 `node-status.json` 并以非活动状态恢复投影。
/// daemon 重启永远不会恢复 capability 或使旧 boot session 变为活动；
/// 历史投影仅为 `node status` 查询而保留。
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *node_status.Store) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(StatusFile, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value.schema_version != 3 or parsed.value.statuses.len > node_status.max_statuses) return error.InvalidStatusState;
    var snapshot = [_]node_status.Status{.{}} ** node_status.max_statuses;
    for (parsed.value.statuses, 0..) |status, i| snapshot[i] = status;
    store.restoreInactive(&snapshot);
}

/// 从旧版 `runtime.json` 文件迁移节点状态。只提取 status 部分；
/// lease 部分由 `dhcp_store.zig` 处理。
pub fn migrateLegacy(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *node_status.Store) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(dhcp_store.LegacyRuntimeFile, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if ((parsed.value.schema_version != 1 and parsed.value.schema_version != 2) or parsed.value.statuses.len > node_status.max_statuses) return error.InvalidRuntimeState;
    var snapshot = [_]node_status.Status{.{}} ** node_status.max_statuses;
    for (parsed.value.statuses, 0..) |status, i| snapshot[i] = status;
    store.restoreInactive(&snapshot);
}
