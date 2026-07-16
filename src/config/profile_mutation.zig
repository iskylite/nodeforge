//! M4.6 profile 内核参数的窄范围在线修改。
//!
//! M4.7 之前 profile 仍保存在单体 config.json 中；本模块只开放
//! `kernel_args`，不提前引入通用 profile CRUD。调用方必须先拒绝引用该
//! profile 的活动 boot session，随后本函数执行 load -> copy ->
//! canonicalize -> validate -> atomic save。这样非法参数和写盘失败都不会
//! 改变当前配置。

const std = @import("std");
const model = @import("../model.zig");
const config_load = @import("load.zig");
const config_store = @import("store.zig");
const config_validate = @import("validate.zig");

/// 设置或清除一个 profile 的 canonical `kernel_args`。`null` 表示清除；
/// 非 null 值会折叠首尾及连续 ASCII 空格，空结果同样归一化为 null。
pub fn setKernelArgs(
    io: std.Io,
    allocator: std.mem.Allocator,
    config_path: []const u8,
    profile_name: []const u8,
    kernel_args: ?[]const u8,
) !void {
    var parsed = try config_load.load(io, allocator, config_path);
    defer parsed.deinit();

    const profiles = try allocator.alloc(model.ProfileConfig, parsed.value.profiles.len);
    defer allocator.free(profiles);
    @memcpy(profiles, parsed.value.profiles);

    var found = false;
    for (profiles) |*profile| {
        if (!std.mem.eql(u8, profile.name, profile_name)) continue;
        profile.kernel_args = kernel_args;
        found = true;
        break;
    }
    if (!found) return error.ProfileNotFound;

    var candidate = parsed.value;
    candidate.profiles = profiles;
    config_load.canonicalizeKernelArgs(&candidate);
    try config_validate.validateConfig(&candidate);
    try config_store.save(io, allocator, config_path, &candidate);
}

test "profile kernel args mutation canonicalizes and validates before save boundary" {
    var args = [_]u8{ ' ', ' ', 'i', 'o', 'm', 'm', 'u', '=', 'p', 't', ' ', ' ', ' ', 'i', 's', 'o', 'l', 'c', 'p', 'u', 's', '=', '0', ',', '2', ' ', ' ' };
    var profiles = [_]model.ProfileConfig{.{
        .name = "diskless",
        .mode = .diskless,
        .distro = "rocky",
        .version = "9.7",
        .arch = .aarch64,
        .boot_bundle = "rocky-diskless",
        .kernel_args = &args,
    }};
    var config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.50.1" },
        .profiles = &profiles,
    };
    config_load.canonicalizeKernelArgs(&config);
    try std.testing.expectEqualStrings("iommu=pt isolcpus=0,2", profiles[0].kernel_args.?);
    try std.testing.expect(config_validate.validKernelArgs(profiles[0].kernel_args.?, .diskless, .rhel));
}
