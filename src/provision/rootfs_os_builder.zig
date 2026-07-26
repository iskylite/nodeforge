//! # v0.2 rootfs OS 层构建器
//!
//! `V0_2_DESIGN.md` §5.2 / `DISKLESS_FINAL.md` §4。rootfs 的 OS 层由发行版原生
//! install-root 工具从 install source 受管 repository 构建到只读 lower：
//! RHEL/Rocky 用 `dnf --installroot`，Ubuntu 设计上用 `debootstrap`。OS 层只引用
//! 本地 nodeforged 受管源，不接触外部 mirror（与 first-boot package action 的
//! pinned 源约束一致）。
//!
//! OS 层实际构建属环境相关执行边界（仅 Linux/root 构建主机可用，与 initrd/
//! first_boot/rootfs_build_executor 一致），本模块不在单元测试覆盖内。叠加
//! `rootfs_build_executor` 的 rootfs-build phase 步骤后产出最终 rootfs。
const std = @import("std");
const model = @import("../model.zig");

/// 在 staging 目录内用发行版原生 install-root 工具构建 OS 层。
/// `repository_urls` 为 nodeforged 受管源 URL（IP-based，构建主机可达）。
/// `version` 为 install source 版本（如 "9.7"）；dnf 取主版本作 `--releasever`。
///
/// v1：安装最小可 chroot 基线（bash/coreutils/tar + 包管理器），足以叠加
/// rootfs-build phase 的 managed_file/archive/script/package 步骤；Profile
/// software/system 全量烤入留作后续保真项（见 `docs/validation`）。
pub fn buildOsLayer(
    io: std.Io,
    allocator: std.mem.Allocator,
    staging: []const u8,
    package_manager: model.PackageManager,
    version: []const u8,
    repository_urls: []const []const u8,
) !void {
    if (repository_urls.len == 0) return error.NoManagedRepository;
    switch (package_manager) {
        .dnf => try buildDnf(io, allocator, staging, version, repository_urls),
        // Ubuntu OS 层使用 debootstrap；v1 仅在 dnf/RHEL 链路验证，apt 留作后续保真项。
        .apt => return error.AptOsLayerUnsupported,
    }
}

fn buildDnf(
    io: std.Io,
    allocator: std.mem.Allocator,
    staging: []const u8,
    version: []const u8,
    repository_urls: []const []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, "dnf");
    try argv.append(a, try std.fmt.allocPrint(a, "--installroot={s}", .{staging}));
    try argv.append(a, try std.fmt.allocPrint(a, "--releasever={s}", .{majorVersion(version)}));
    try argv.append(a, "--setopt=install_weak_deps=False");
    for (repository_urls, 0..) |url, index| {
        try argv.append(a, try std.fmt.allocPrint(a, "--repofrompath=nodeforge-{d},{s}", .{ index, url }));
        try argv.append(a, try std.fmt.allocPrint(a, "--enablerepo=nodeforge-{d}", .{index}));
    }
    try argv.append(a, "install");
    try argv.append(a, "-y");
    try argv.append(a, "--nogpgcheck");
    // 可启动且可由 nodeforge-agent 收敛的基线。不能只满足 chroot：node-apply
    // 固定使用 usermod/systemctl，切根后的系统还需要 init、网络与 SSH 服务。
    const baseline = [_][]const u8{
        "bash",
        "coreutils",
        "tar",
        "dnf",
        "systemd",
        "shadow-utils",
        "util-linux",
        "iproute",
        "NetworkManager",
        "openssh-server",
        "procps-ng",
    };
    for (baseline) |pkg| try argv.append(a, pkg);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        // A real bootable baseline pulls substantially more packages than the
        // old chroot-only baseline; dnf progress can exceed 64 KiB.
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const failed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        std.log.scoped(.rootfs_build).err("os-layer dnf installroot failed (exit): {s}", .{result.stderr});
        return error.OsLayerBuildFailed;
    }
}

/// 取版本主版本号作为 dnf `--releasever`：`9.7` -> `9`，`22.04` -> `22`。
fn majorVersion(version: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse return version;
    return version[0..dot];
}
