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

/// Atomically saves the node-status snapshot to `node-status.json`.
/// The caller must have already obtained a consistent snapshot under the
/// node_status.Store mutex (via `snapshot`).
pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, statuses: *const [node_status.max_statuses]node_status.Status, now: i64) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(StatusFile{ .saved_at = now, .statuses = statuses }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try dhcp_store.atomicWrite(io, path, output.written());
}

/// Loads `node-status.json` and restores the projection as inactive.
/// A daemon restart never revives a capability or makes an old boot session
/// active; the historical projection is retained for `node status` queries.
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

/// Migrates node statuses from a legacy `runtime.json` file.  Only the status
/// portion is extracted; the lease portion is handled by `dhcp_store.zig`.
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
