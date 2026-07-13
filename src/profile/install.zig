//! Adapter-independent M4.1 install-plan normalization.
const std = @import("std");
const model = @import("../model.zig");

/// Resolve the one-period M4 compatibility fields without allowing ambiguous
/// merges.  Renderers only receive the returned shared system model.
pub fn effectiveSystem(profile: *const model.ProfileConfig) !model.TargetSystemConfig {
    var system = profile.system;
    const legacy = profile.install orelse return system;
    if (system.users.len != 0 and legacy.users.len != 0) return error.LegacySystemUsersConflict;
    if (system.packages.len != 0 and legacy.packages.len != 0) return error.LegacySystemPackagesConflict;
    if (system.users.len == 0) system.users = legacy.users;
    if (system.packages.len == 0) system.packages = legacy.packages;
    return system;
}

pub fn planDigest(allocator: std.mem.Allocator, node: *const model.NodeConfig, profile: *const model.ProfileConfig, source: *const model.InstallSourceConfig) !u64 {
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try std.json.Stringify.value(.{ .node = node.*, .profile = profile.*, .source = source.* }, .{}, &json.writer);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json.written(), &digest, .{});
    const value = std.mem.readInt(u64, digest[0..8], .big);
    return if (value == 0) 1 else value;
}
