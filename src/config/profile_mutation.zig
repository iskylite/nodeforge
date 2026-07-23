//! PXE profile 的受约束 catalog mutation。
//!
//! 本模块只提供已进入现行 CLI/HTTP 契约的窄写入口：
//! - 从已有 install source 创建安全默认 install profile；
//! - 规范化修改 `kernel_args`；
//! 每次写入都先投影完整 config+catalog 模型并校验，再由 catalog store
//! 原子发布；这里不实现 M6 规划中的通用 profile CRUD。
const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const config_load = @import("load.zig");
const validate = @import("validate.zig");

/// 从已有 install source 创建安全默认 install profile。
///
/// 新 profile 使用与 ISO import 自动创建相同的默认安全基线（destructive=true,
/// persistent_writes=true, reinstall_policy=explicit）。CLI 不接收任意 safety/storage JSON，
/// 避免形成绕过模型校验的第二套创建语义。
pub fn addInstallProfile(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, name: []const u8, install_source: []const u8, kind: model.ProfileKind, boot_bundle: ?[]const u8) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    for (parsed.value.profiles) |profile| if (std.mem.eql(u8, profile.name, name)) return error.ProfileAlreadyExists;
    var source: ?model.InstallSourceConfig = null;
    for (parsed.value.install_sources) |candidate| if (std.mem.eql(u8, candidate.name, install_source)) {
        source = candidate;
        break;
    };
    const selected = source orelse return error.InstallSourceNotFound;
    if (kind == .diskless) {
        if (parsed.value.schema_version < 4) return error.DisklessRequiresSchemaV4;
        if (boot_bundle == null) return error.DisklessBootBundleRequired;
    }
    const profiles = try allocator.alloc(model.ProfileConfig, parsed.value.profiles.len + 1);
    defer allocator.free(profiles);
    @memcpy(profiles[0..parsed.value.profiles.len], parsed.value.profiles);
    // 与 ISO import 自动创建的默认 profile 使用同一安全基线。CLI 不接收
    // 任意 safety/storage JSON，避免形成绕过模型校验的第二套创建语义。
    profiles[parsed.value.profiles.len] = .{
        .name = name,
        .install_source = selected.name,
        .kind = kind,
        .boot_bundle = boot_bundle,
    };
    var candidate = parsed.value;
    candidate.profiles = profiles;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

/// 修改已有 profile 的 kernel_args 字段。
///
/// 执行 load-find-canonicalize-validate-save 事务。
/// canonicalize 在写入前折叠空格并消除空字符串为 null。
pub fn setKernelArgs(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, profile_name: []const u8, kernel_args: ?[]const u8) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const profiles = try allocator.dupe(model.ProfileConfig, parsed.value.profiles);
    defer allocator.free(profiles);
    var found = false;
    for (profiles) |*profile| if (std.mem.eql(u8, profile.name, profile_name)) {
        profile.kernel_args = kernel_args;
        found = true;
        break;
    };
    if (!found) return error.ProfileNotFound;
    var candidate = parsed.value;
    candidate.profiles = profiles;
    var projected = model.projectCatalog(config.*, &candidate);
    config_load.canonicalizeKernelArgs(&projected);
    candidate.profiles = projected.profiles;
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

test "profile kernel args mutation canonicalizes projected catalog data" {
    var args = [_]u8{ ' ', 'i', 'o', 'm', 'm', 'u', '=', 'p', 't', ' ', ' ', 'i', 's', 'o', 'l', 'c', 'p', 'u', 's', '=', '0', ',', '2', ' ' };
    var profiles = [_]model.ProfileConfig{.{ .name = "install", .install_source = "source", .kernel_args = &args }};
    var catalog: model.Catalog = .{ .profiles = &profiles };
    var projected = model.projectCatalog(.{ .server = .{ .server_ip = "192.0.2.1" } }, &catalog);
    config_load.canonicalizeKernelArgs(&projected);
    try std.testing.expectEqualStrings("iommu=pt isolcpus=0,2", profiles[0].kernel_args.?);
}
