//! 适配器无关的 M4.1 安装计划规范化。
const std = @import("std");
const model = @import("../model.zig");

/// 解析单周期 M4 兼容字段，不允许歧义合并。
/// 渲染器只接收返回的共享 system 模型。
pub fn effectiveSystem(profile: *const model.ProfileConfig) !model.TargetSystemConfig {
    var system = profile.system;
    const legacy = profile.install orelse return system;
    const implicit_default_users = model.targetUsersAreImplicitDefault(system.users);
    if (system.users.len != 0 and legacy.users.len != 0 and !implicit_default_users) return error.LegacySystemUsersConflict;
    if (system.packages.len != 0 and legacy.packages.len != 0) return error.LegacySystemPackagesConflict;
    if ((system.users.len == 0 or implicit_default_users) and legacy.users.len != 0) system.users = legacy.users;
    if (system.packages.len == 0) system.packages = legacy.packages;
    return system;
}

test "M4.2 implicit users default and legacy compatibility" {
    const base: model.ProfileConfig = .{ .name = "rocky", .mode = .install, .distro = "rocky", .version = "9.7", .arch = .x86_64 };
    const default_system = try effectiveSystem(&base);
    try std.testing.expectEqual(@as(usize, 1), default_system.users.len);
    try std.testing.expectEqualStrings("nodeforge", default_system.users[0].name);

    var legacy = base;
    legacy.install = .{ .users = &.{.{ .name = "legacy" }} };
    const legacy_system = try effectiveSystem(&legacy);
    try std.testing.expectEqualStrings("legacy", legacy_system.users[0].name);

    var conflict = legacy;
    conflict.system.users = &.{.{ .name = "new" }};
    try std.testing.expectError(error.LegacySystemUsersConflict, effectiveSystem(&conflict));
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

test "M4.6 kernel args participate in immutable install plan digest" {
    const node: model.NodeConfig = .{ .id = "node-01", .mac = "00:11:22:33:44:55", .arch = .aarch64, .profile = "rocky" };
    const source: model.InstallSourceConfig = .{ .name = "rocky", .distro = "rocky", .version = "9.7", .arch = .aarch64, .source_asset = "iso", .installer_kernel = "kernel", .installer_initrd = "initrd" };
    var profile: model.ProfileConfig = .{ .name = "rocky", .mode = .install, .distro = "rocky", .version = "9.7", .arch = .aarch64, .install_source = "rocky", .install = .{} };
    const without = try planDigest(std.testing.allocator, &node, &profile, &source);
    profile.kernel_args = "iommu=pt";
    const with = try planDigest(std.testing.allocator, &node, &profile, &source);
    try std.testing.expect(without != with);
}
