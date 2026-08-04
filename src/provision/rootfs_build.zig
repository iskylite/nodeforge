//! # v0.2 rootfs 构建器核心
//!
//! `V0_2_DESIGN.md` §4.1/§4.4 与 `DISKLESS_FINAL.md` §4 的共享 rootfs 构建管线。
//! rootfs 是由 Profile build projection 派生、按 `rootfs_input_digest` 缓存的只读
//! 制品：`staging -> validate -> object rename -> ready`，已发布 object 只增不删
//! （v0.2 不做 rootfs GC，见 `V0_2_IMPL_DETAILS.md` §7）。
//!
//! 本模块承载制品记录、构建状态机、DeliveryManifest 与 local-only 静态检查；
//! OS 层实际构建（`dnf --installroot` / debootstrap + squashfs）属环境相关执行边界。
const std = @import("std");
const model = @import("../model.zig");

/// 构建状态机。已发布 rootfs 只增不删。
pub const BuildState = enum {
    /// 正在 staging 目录构建，尚未校验。
    staging,
    /// 校验通过，等待原子 rename 到发布路径。
    validated,
    /// 已原子发布为只读 object，可被 diskless 消费。
    ready,
    /// 构建失败，staging 已丢弃。
    failed,
};

/// v0.2 唯一 rootfs 形态。
pub const RootfsFormat = enum { @"squashfs-overlay" };

/// rootfs 制品记录（manifest 持久事实 + 只读派生事实）。
pub const Artifact = struct {
    /// rootfs_input_digest（Profile build projection 的 canonical 摘要）。
    rootfs_input_digest: []const u8,
    format: RootfsFormat = .@"squashfs-overlay",
    arch: model.Arch,
    /// 压缩 squashfs 内容 SHA-512（immutable ETag）。
    content_sha512: []const u8,
    compressed_size: u64,
    uncompressed_size: u64,
    builder_version: []const u8,
    /// Profile build projection digest（rootfs_input_digest 的可读伴随）。
    profile_build_digest: []const u8,
    /// software capability revision（OS 层缓存复用依据）。
    software_capability_revision: []const u8 = "",
    features: []const []const u8 = &.{},
    state: BuildState = .staging,
};

/// 一次启动绑定的交付清单：固定 boot bundle revisions + rootfs SHA-512。
/// boot bundle 不引用 rootfs，避免 Profile/effective build input 与 rootfs 输出的环。
pub const DeliveryManifest = struct {
    boot_bundle: []const u8,
    runtime_kernel_revision: u64,
    initrd_revision: u64,
    kernel_release: []const u8,
    /// 该次启动交付的 rootfs 内容 SHA-512。
    rootfs_sha512: []const u8,
    rootfs_compressed_size: u64,
};

/// local-only 静态检查发现的违规。
pub const LocalOnlyViolation = struct {
    repository: []const u8,
    base_url: []const u8,
    reason: []const u8,
};

/// 已知公网 mirror/metalink/GeoIP/vendor 关键词。命中即违反 local-only 不变式。
const forbidden_url_markers = [_][]const u8{
    "mirrorlist", "metalink",       "geoip",        "mirror.", "mirrors.",  "centos.org", "fedora.org",
    "ubuntu.com", "archive.ubuntu", "ports.ubuntu", "rhui",    "amazonaws", "cloudfront",
};

/// 校验单个 repository base_url 是否符合 local-only（无公网 mirror/metalink/GeoIP/vendor）。
pub fn localOnlyViolation(repo: *const model.RepositoryConfig) ?LocalOnlyViolation {
    const url = repo.base_url;
    for (forbidden_url_markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(url, marker) != null) {
            return .{ .repository = repo.name, .base_url = url, .reason = "public mirror/metalink/geoIP/vendor reference violates local-only" };
        }
    }
    return null;
}

/// 校验 catalog 中 diskless Profile 引用的全部 repository 是否 local-only。
pub fn localOnlyViolations(allocator: std.mem.Allocator, catalog: *const model.Catalog, profile: *const model.ProfileConfig) ![]const LocalOnlyViolation {
    var violations: std.ArrayList(LocalOnlyViolation) = .empty;
    defer violations.deinit(allocator);
    for (profile.software.repositories) |name| {
        const repo = findRepository(catalog, name) orelse continue;
        if (localOnlyViolation(repo)) |v| try violations.append(allocator, v);
    }
    return violations.toOwnedSlice(allocator);
}

/// 构建状态推进校验（§10 fail-closed）：只允许 staging->validated->ready 或
/// 任意 ->failed；跳跃/回退/终态后推进拒绝。返回合法后的状态。
pub const AdvanceError = error{ AlreadyTerminal, InvalidTransition };
pub fn advanceState(current: BuildState, target: BuildState) AdvanceError!BuildState {
    if (current == .ready or current == .failed) return error.AlreadyTerminal;
    return switch (target) {
        .failed => .failed,
        .validated => if (current == .staging) .validated else error.InvalidTransition,
        .ready => if (current == .validated) .ready else error.InvalidTransition,
        .staging => error.InvalidTransition,
    };
}

fn findRepository(catalog: *const model.Catalog, name: []const u8) ?*const model.RepositoryConfig {
    for (catalog.repositories) |*r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

test "local-only check rejects public mirrors and accepts local urls" {
    var local_repo: model.RepositoryConfig = .{ .name = "local", .distro = "rocky", .version = "9", .arch = .aarch64, .manager = .dnf, .base_url = "http://192.168.27.128/repos/rocky-9" };
    var mirror_repo: model.RepositoryConfig = .{ .name = "pub", .distro = "rocky", .version = "9", .arch = .aarch64, .manager = .dnf, .base_url = "http://mirror.example.com/rocky/9" };
    var metalink_repo: model.RepositoryConfig = .{ .name = "ml", .distro = "rocky", .version = "9", .arch = .aarch64, .manager = .dnf, .base_url = "https://mirrors.rockylinux.org/metalink?arch=aarch64" };
    try std.testing.expect(localOnlyViolation(&local_repo) == null);
    try std.testing.expect(localOnlyViolation(&mirror_repo) != null);
    try std.testing.expect(localOnlyViolation(&metalink_repo) != null);
    _ = &local_repo;
    _ = &mirror_repo;
    _ = &metalink_repo;
}

test "build state machine rejects jumps and terminal advance" {
    try std.testing.expectEqual(BuildState.validated, try advanceState(.staging, .validated));
    try std.testing.expectEqual(BuildState.ready, try advanceState(.validated, .ready));
    try std.testing.expectError(error.InvalidTransition, advanceState(.staging, .ready));
    try std.testing.expectError(error.AlreadyTerminal, advanceState(.ready, .validated));
    try std.testing.expectEqual(BuildState.failed, try advanceState(.staging, .failed));
    try std.testing.expectEqual(BuildState.failed, try advanceState(.validated, .failed));
}

test "delivery manifest binds boot bundle revisions and rootfs sha512" {
    const manifest: DeliveryManifest = .{
        .boot_bundle = "bb",
        .runtime_kernel_revision = 3,
        .initrd_revision = 5,
        .kernel_release = "5.14.0",
        .rootfs_sha512 = "abc",
        .rootfs_compressed_size = 1024,
    };
    try std.testing.expectEqualStrings("bb", manifest.boot_bundle);
    try std.testing.expectEqual(@as(u64, 3), manifest.runtime_kernel_revision);
    try std.testing.expectEqualStrings("abc", manifest.rootfs_sha512);
}
