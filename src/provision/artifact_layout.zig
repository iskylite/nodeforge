//! # Diskless 制品目录布局
//!
//! 人工排障首先按 Profile 找产物，摘要只负责不可变身份，不应成为顶层文件名。
//! 新制品统一采用：
//!
//! - initrd: `<profile-or-asset-name>/<kernel-release>/initrd.img`
//! - rootfs: `<profile>/<digest-prefix>/<profile>.squashfs`
//!
//! `rootfs_input_digest` 的完整 64 hex 仍保存在 `rootfs-artifacts.json` 并参与
//! 一致性校验；目录使用 16 hex 前缀兼顾可读性与冲突隔离。这里不负责旧布局
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
    // 前缀只用于让同一 Profile 的多次不可变构建在目录上可区分；真正身份仍是
    // state 中的完整 digest，任何读取/登记都不能把 16 位前缀当作校验摘要。
    if (digest.len != 64) return error.InvalidRootfsDigest;
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}.squashfs", .{ profile, digest[0..16], profile });
}

test "diskless artifact paths preserve operator-visible profile provenance" {
    const initrd = try initrdRelative(std.testing.allocator, "ubuntu-22.04.5-live-server-arm64-diskless", "5.15.0-119-generic");
    defer std.testing.allocator.free(initrd);
    try std.testing.expectEqualStrings("ubuntu-22.04.5-live-server-arm64-diskless/5.15.0-119-generic/initrd.img", initrd);

    const rootfs = try rootfsRelative(std.testing.allocator, "ubuntu-22.04.5-live-server-arm64-diskless", "885851647a8b493d1542d2e7ecf8a5c1030351f283fb1ce0192231e7dbabb372");
    defer std.testing.allocator.free(rootfs);
    try std.testing.expectEqualStrings("ubuntu-22.04.5-live-server-arm64-diskless/885851647a8b493d/ubuntu-22.04.5-live-server-arm64-diskless.squashfs", rootfs);
}
