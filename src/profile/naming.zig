//! Profile 与 diskless BootBundle 的规范名称。
//!
//! 名称只从 ISO 导入生成的 InstallSource 逻辑名派生，禁止再从
//! distro/version 等不完整 tuple 拼接。这样介质类型、完整补丁版本和架构
//! 都不会在后续资源名称中丢失。

const std = @import("std");
const model = @import("../model.zig");

pub const install_suffix = "-install";
pub const diskless_suffix = "-diskless";
pub const diskless_bundle_suffix = "-diskless-bundle";

/// 根据完整 InstallSource、可选限定符和 kind 生成唯一 Profile 名。
///
/// 语法：`<install-source>[-<qualifier>]-<install|diskless>`。
pub fn profileName(allocator: std.mem.Allocator, install_source: []const u8, qualifier: ?[]const u8, kind: model.ProfileKind) ![]u8 {
    const suffix = switch (kind) {
        .install => install_suffix,
        .diskless => diskless_suffix,
    };
    return if (qualifier) |value|
        std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ install_source, value, suffix })
    else
        std.fmt.allocPrint(allocator, "{s}{s}", .{ install_source, suffix });
}

/// 判断 Profile 名是否保留完整 source 基名并符合其 kind 后缀规则。
pub fn profileIsCanonical(name: []const u8, install_source: []const u8, kind: model.ProfileKind) bool {
    return switch (kind) {
        .install => hasKindBase(name, install_source, install_suffix),
        .diskless => hasDisklessBase(name, install_source),
    };
}

/// 判断 BootBundle 名是否由指定 InstallSource 的完整名称派生。
pub fn bootBundleIsCanonical(name: []const u8, install_source: []const u8) bool {
    return hasKindBase(name, install_source, diskless_bundle_suffix);
}

/// 根据完整 InstallSource 和可选限定符生成 diskless BootBundle 名。
///
/// 语法：`<install-source>[-<qualifier>]-diskless-bundle`。
pub fn bootBundleName(allocator: std.mem.Allocator, install_source: []const u8, qualifier: ?[]const u8) ![]u8 {
    return if (qualifier) |value|
        std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ install_source, value, diskless_bundle_suffix })
    else
        std.fmt.allocPrint(allocator, "{s}{s}", .{ install_source, diskless_bundle_suffix });
}

/// 分配 `<完整-install-source>-diskless`。
pub fn disklessName(allocator: std.mem.Allocator, install_source: []const u8) ![]u8 {
    return profileName(allocator, install_source, null, .diskless);
}

fn hasDisklessBase(name: []const u8, install_source: []const u8) bool {
    return hasKindBase(name, install_source, diskless_suffix);
}

fn hasKindBase(name: []const u8, install_source: []const u8, suffix: []const u8) bool {
    if (!std.mem.endsWith(u8, name, suffix)) return false;
    return hasSourceBase(name[0 .. name.len - suffix.len], install_source);
}

/// 完整 source 可以直接作为名称，也可以在其后追加用途/内核等限定符；
/// 关键不变量是完整 source 必须位于最前面，不能被缩写或重新拼接。
fn hasSourceBase(name: []const u8, install_source: []const u8) bool {
    return std.mem.eql(u8, name, install_source) or
        (name.len > install_source.len + 1 and
            std.mem.startsWith(u8, name, install_source) and
            name[install_source.len] == '-');
}

test "规范名称保留 ISO install source 的完整身份" {
    const source = "ubuntu-22.04.5-live-server-arm64";
    const install_name = try profileName(std.testing.allocator, source, "compute", .install);
    defer std.testing.allocator.free(install_name);
    try std.testing.expectEqualStrings("ubuntu-22.04.5-live-server-arm64-compute-install", install_name);
    const diskless_name = try profileName(std.testing.allocator, source, "compute", .diskless);
    defer std.testing.allocator.free(diskless_name);
    try std.testing.expectEqualStrings("ubuntu-22.04.5-live-server-arm64-compute-diskless", diskless_name);
    const bundle_name = try bootBundleName(std.testing.allocator, source, "compute");
    defer std.testing.allocator.free(bundle_name);
    try std.testing.expectEqualStrings("ubuntu-22.04.5-live-server-arm64-compute-diskless-bundle", bundle_name);

    try std.testing.expect(profileIsCanonical("ubuntu-22.04.5-live-server-arm64-install", source, .install));
    try std.testing.expect(profileIsCanonical("ubuntu-22.04.5-live-server-arm64-compute-install", source, .install));
    try std.testing.expect(!profileIsCanonical(source, source, .install));
    try std.testing.expect(profileIsCanonical("ubuntu-22.04.5-live-server-arm64-diskless", source, .diskless));
    try std.testing.expect(profileIsCanonical("ubuntu-22.04.5-live-server-arm64-compute-diskless", source, .diskless));
    try std.testing.expect(bootBundleIsCanonical("ubuntu-22.04.5-live-server-arm64-diskless-bundle", source));
    try std.testing.expect(bootBundleIsCanonical("ubuntu-22.04.5-live-server-arm64-compute-diskless-bundle", source));
    try std.testing.expect(!profileIsCanonical("ubuntu-22.04-diskless", source, .diskless));
    try std.testing.expect(!bootBundleIsCanonical("ubuntu-22.04.5-live-server-arm64-diskless", source));
    try std.testing.expect(!bootBundleIsCanonical("ubuntu-22.04-diskless-bundle", source));
}
