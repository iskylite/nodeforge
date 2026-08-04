//! # Diskless 制品目录布局
//!
//! Rootfs objects are shared across logical Profiles by their complete build
//! input digest. Profile names remain diagnostic metadata only.
//! 新制品统一采用：
//!
//! - initrd: `<profile-or-asset-name>/<kernel-release>/initrd.img`
//! - rootfs: `sha256/<first-two-hex>/<full-digest>.squashfs`
//!
//! `rootfs_input_digest` 的完整 64 hex 同时出现在路径和索引中。这里不负责旧布局
//! 探测或迁移：开发版本只生成和读取当前布局，避免启动时隐式移动大型制品。
const std = @import("std");

pub fn initrdRelative(
    allocator: std.mem.Allocator,
    profile: []const u8,
    kernel_release: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/initrd.img", .{ profile, kernel_release });
}

pub fn rootfsRelative(
    allocator: std.mem.Allocator,
    profile: []const u8,
    digest: []const u8,
) ![]u8 {
    _ = profile;
    if (digest.len != 64) return error.InvalidRootfsDigest;
    for (digest) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidRootfsDigest;
    return std.fmt.allocPrint(allocator, "sha256/{s}/{s}.squashfs", .{ digest[0..2], digest });
}

test "diskless rootfs artifact paths are profile-independent CAS locators" {
    const initrd = try initrdRelative(std.testing.allocator, "ubuntu-22.04.5-live-server-arm64-diskless", "5.15.0-119-generic");
    defer std.testing.allocator.free(initrd);
    try std.testing.expectEqualStrings("ubuntu-22.04.5-live-server-arm64-diskless/5.15.0-119-generic/initrd.img", initrd);

    const rootfs = try rootfsRelative(std.testing.allocator, "ubuntu-22.04.5-live-server-arm64-diskless", "885851647a8b493d1542d2e7ecf8a5c1030351f283fb1ce0192231e7dbabb372");
    defer std.testing.allocator.free(rootfs);
    try std.testing.expectEqualStrings("sha256/88/885851647a8b493d1542d2e7ecf8a5c1030351f283fb1ce0192231e7dbabb372.squashfs", rootfs);
    const cloned = try rootfsRelative(std.testing.allocator, "renamed-clone", "885851647a8b493d1542d2e7ecf8a5c1030351f283fb1ce0192231e7dbabb372");
    defer std.testing.allocator.free(cloned);
    try std.testing.expectEqualStrings(rootfs, cloned);
}
