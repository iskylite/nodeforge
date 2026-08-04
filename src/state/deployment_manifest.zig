//! v0.4 fresh deployment identity and commit marker.
//!
//! The manifest is intentionally small and independent from catalog/state
//! loaders.  It is the first file checked by daemon bootstrap, so a v0.3
//! directory cannot be partially interpreted as a v0.4 deployment.

const std = @import("std");
const atomic = @import("dhcp_store.zig").atomicWrite;

pub const schema_version: u32 = 1;
pub const product_major_minor = "0.4";
pub const Manifest = struct {
    schema_version: u32 = schema_version,
    deployment_id: []const u8,
    product_major_minor: []const u8 = product_major_minor,
    app_config_schema: u32 = 5,
    catalog_schema: u32 = 6,
    state_schema_set_sha256: []const u8,
    created_at: i64,
};

pub fn generateId(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    try io.randomSecure(&raw);
    const id = try allocator.alloc(u8, 32);
    _ = std.fmt.bufPrint(id, "{x}", .{raw}) catch unreachable;
    return id;
}

pub fn validate(manifest: Manifest) !void {
    if (manifest.schema_version != schema_version or !std.mem.eql(u8, manifest.product_major_minor, product_major_minor) or
        manifest.app_config_schema != 5 or manifest.catalog_schema != 6 or manifest.deployment_id.len != 32 or
        manifest.state_schema_set_sha256.len != 64) return error.DeploymentLayoutIncompatible;
    for (manifest.deployment_id) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.DeploymentLayoutIncompatible;
    for (manifest.state_schema_set_sha256) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return error.DeploymentLayoutIncompatible;
}

pub fn write(io: std.Io, allocator: std.mem.Allocator, path: []const u8, manifest: Manifest) !void {
    try validate(manifest);
    const bytes = try std.json.Stringify.valueAlloc(allocator, manifest, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    try atomic(io, path, bytes);
}

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Manifest) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false });
    validate(parsed.value) catch |err| {
        parsed.deinit();
        return err;
    };
    return parsed;
}

pub fn validateMarker(io: std.Io, allocator: std.mem.Allocator, path: []const u8, deployment_id: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256));
    defer allocator.free(bytes);
    const expected = try renderMarker(allocator, deployment_id);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, bytes, expected)) return error.DeploymentLayoutIncompatible;
}

pub fn renderMarker(allocator: std.mem.Allocator, deployment_id: []const u8) ![]u8 {
    if (deployment_id.len != 32) return error.DeploymentLayoutIncompatible;
    return std.fmt.allocPrint(allocator, "nodeforge-root-v2 {s}\n", .{deployment_id});
}

test "v0.4 deployment manifest rejects old product and marker has identity" {
    const manifest: Manifest = .{ .deployment_id = "0123456789abcdef0123456789abcdef", .state_schema_set_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", .created_at = 1 };
    try validate(manifest);
    const marker = try renderMarker(std.testing.allocator, manifest.deployment_id);
    defer std.testing.allocator.free(marker);
    try std.testing.expectEqualStrings("nodeforge-root-v2 0123456789abcdef0123456789abcdef\n", marker);
    try std.testing.expectError(error.DeploymentLayoutIncompatible, validate(.{ .deployment_id = "0123456789abcdef0123456789abcdef", .state_schema_set_sha256 = "x", .created_at = 1 }));
}
