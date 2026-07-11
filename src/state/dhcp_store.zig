//! Durable projection of DHCP leases.  Every mutation is saved atomically;
//! a corrupt snapshot is rejected by the loader rather than silently reused.
const std = @import("std");
const runtime = @import("runtime.zig");

pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, state: *runtime.DhcpState, now: i64) !void {
    var leases: [runtime.DhcpState.max_leases]runtime.DhcpLease = undefined;
    state.snapshot(&leases);
    var output: std.Io.Writer.Allocating = .init(allocator); defer output.deinit();
    try std.json.Stringify.value(runtime.DhcpRuntimeFile{ .saved_at = now, .leases = &leases }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path}); defer allocator.free(temp);
    const dir = std.Io.Dir.cwd();
    errdefer dir.deleteFile(io, temp) catch {};
    { var file = try dir.createFile(io, temp, .{ .truncate = true }); defer file.close(io); try file.writeStreamingAll(io, output.written()); try file.sync(io); }
    try std.Io.Dir.rename(dir, temp, dir, path, io);
}

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, state: *runtime.DhcpState, now: i64) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)); defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(runtime.DhcpRuntimeFile, allocator, bytes, .{ .allocate = .alloc_always }); defer parsed.deinit();
    if (parsed.value.schema_version != 1 or parsed.value.leases.len > runtime.DhcpState.max_leases) return error.InvalidRuntimeState;
    var snapshot = [_]runtime.DhcpLease{.{}} ** runtime.DhcpState.max_leases;
    for (parsed.value.leases, 0..) |lease, i| {
        if (lease.used() and lease.expires_at > now) snapshot[i] = lease;
    }
    state.restore(&snapshot);
}
