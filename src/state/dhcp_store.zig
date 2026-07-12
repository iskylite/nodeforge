//! Durable projection of DHCP leases (M3.1).
//!
//! `leases.json` is the sole durable fact source for DHCP lease state.  The
//! checkpoint worker is the only writer; the DHCP hot path only bumps
//! `lease_generation`.  A corrupt snapshot is rejected by the loader rather
//! than silently reused.  Legacy `runtime.json` files (which combined leases
//! and node statuses) are accepted as migration input only.

const std = @import("std");
const runtime = @import("runtime.zig");
const node_status = @import("node_status.zig");

/// M3.1 `leases.json` schema.  Contains only DHCP leases and a display timestamp.
pub const LeasesFile = struct {
    schema_version: u32 = 3,
    saved_at: i64,
    leases: []const runtime.DhcpLease,
};

/// Legacy `runtime.json` schema (schema 1/2) accepted only for migration.
/// Contains both leases and statuses; the loader extracts leases and ignores
/// the status portion (handled independently by `status_store.zig`).
pub const LegacyRuntimeFile = struct {
    schema_version: u32 = 2,
    saved_at: i64 = 0,
    leases: []const runtime.DhcpLease = &.{},
    statuses: []const node_status.Status = &.{},
};

/// Atomically saves the DHCP lease snapshot to `leases.json`.
/// The caller must have already obtained a consistent snapshot under the
/// DhcpState mutex (via `snapshotWithGeneration`).
pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, leases: *const [runtime.DhcpState.max_leases]runtime.DhcpLease, now: i64) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(LeasesFile{ .saved_at = now, .leases = leases }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try atomicWrite(io, path, output.written());
}

/// Loads `leases.json` and restores non-expired leases into `state`.
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

/// Migrates leases from a legacy `runtime.json` file.  Only the lease portion
/// is extracted; the status portion is handled by `status_store.zig`.
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

/// Shared single-file durability protocol: write temp, fsync temp, rename,
/// fsync parent directory.
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

/// Persists the directory entry created by `rename`, completing the atomic
/// replacement protocol on filesystems that require an explicit directory
/// sync after file data has reached disk.
fn syncParentDirectory(io: std.Io, path: []const u8) !void {
    const parent_path = std.fs.path.dirname(path) orelse return;
    var parent = try std.Io.Dir.openFileAbsolute(io, parent_path, .{ .allow_directory = true });
    defer parent.close(io);
    try parent.sync(io);
}
