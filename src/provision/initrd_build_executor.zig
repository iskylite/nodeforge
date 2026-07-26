//! # v0.2 NodeForge initrd 构建器
//!
//! 构建 diskless PXE boot 使用的 nodeforge initramfs。流程：
//! 1. `dracut` 构建最小 initramfs（network + base 模块，squashfs/overlay 文件系统）
//! 2. 解包 initramfs（zcat | cpio）
//! 3. 注入 `nodeforge-initrd` 二进制到 `/usr/sbin/`
//! 4. 创建 `/init` 脚本（exec nodeforge-initrd）
//! 5. 创建 `/capsule` 目录（boot-prepare 注入 token 文件）
//! 6. 重包 initramfs（find | cpio | gzip）
//!
//! 构建属环境相关执行边界（仅 Linux/root 构建主机可用，与 rootfs_os_builder 一致），
//! 本模块不在单元测试覆盖内。
const std = @import("std");
const paths = @import("../paths.zig");

/// 构建 nodeforge initramfs。
///
/// `kernel_release` 是内核 uname release（如 `5.14.0-611.5.1.el9_7.aarch64`），
/// 从 install source 的 boot bundle 获取或由 CLI `--kver` 显式传入。
/// `nodeforge_initrd_binary` 是 daemon install root 下的 `nodeforge-initrd` 二进制路径。
/// `output_path` 是最终 initramfs 输出路径（受管 initrd_dir 下）。
///
/// 构建步骤全部使用外部命令（dracut/cpio/gzip），与 rootfs_os_builder 一致。
pub fn build(
    io: std.Io,
    allocator: std.mem.Allocator,
    kernel_release: []const u8,
    nodeforge_initrd_binary: []const u8,
    output_path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const work_dir = try std.fmt.allocPrint(a, "{s}/initrd-build-{s}", .{ paths.require().work_dir, kernel_release });
    std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, work_dir);
    defer std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};

    // 1. dracut 构建最小 initramfs
    const base_img = try std.fmt.allocPrint(a, "{s}/initrd-base.img", .{work_dir});
    runCmd(io, allocator, &.{
        "dracut", "--no-hostonly",
        "--kver", kernel_release,
        "--modules", "network base",
        "--filesystems", "squashfs overlay",
        base_img,
    }) catch |err| {
        std.log.scoped(.initrd_build).err("dracut failed: {t}", .{err});
        return error.DracutFailed;
    };

    // 2. 解包 initramfs
    const initrd_root = try std.fmt.allocPrint(a, "{s}/root", .{work_dir});
    try std.Io.Dir.cwd().createDirPath(io, initrd_root);
    // zcat base.img | cpio -idmv — 使用 shell 管道
    const unpack_cmd = try std.fmt.allocPrint(a, "zcat {s} | (cd {s} && cpio -idmv 2>/dev/null)", .{ base_img, initrd_root });
    runShell(io, allocator, unpack_cmd) catch |err| {
        std.log.scoped(.initrd_build).err("unpack initramfs failed: {t}", .{err});
        return error.UnpackFailed;
    };

    // 3. 注入 nodeforge-initrd 二进制
    const initrd_bin_dest = try std.fmt.allocPrint(a, "{s}/usr/sbin", .{initrd_root});
    std.Io.Dir.cwd().createDirPath(io, initrd_bin_dest) catch {};
    const initrd_bin_path = try std.fmt.allocPrint(a, "{s}/nodeforge-initrd", .{initrd_bin_dest});
    std.Io.Dir.copyFileAbsolute(nodeforge_initrd_binary, initrd_bin_path, io, .{ .replace = true, .make_path = true }) catch |err| {
        std.log.scoped(.initrd_build).err("inject nodeforge-initrd failed: {t}", .{err});
        return error.InjectFailed;
    };
    // 设置可执行权限
    runCmd(io, allocator, &.{ "chmod", "0755", initrd_bin_path }) catch {};

    // 4. 创建 /init 脚本
    const init_script = try std.fmt.allocPrint(a, "{s}/init", .{initrd_root});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = init_script, .data = "#!/bin/sh\nexec /usr/sbin/nodeforge-initrd\n" }) catch |err| {
        std.log.scoped(.initrd_build).err("create /init failed: {t}", .{err});
        return error.InitScriptFailed;
    };
    runCmd(io, allocator, &.{ "chmod", "+x", init_script }) catch {};

    // 5. 创建 /capsule 目录（boot-prepare 注入 token 文件）
    const capsule_dir = try std.fmt.allocPrint(a, "{s}/capsule", .{initrd_root});
    std.Io.Dir.cwd().createDirPath(io, capsule_dir) catch {};

    // 6. 重包 initramfs
    const repack_cmd = try std.fmt.allocPrint(a, "(cd {s} && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > {s})", .{ initrd_root, output_path });
    runShell(io, allocator, repack_cmd) catch |err| {
        std.log.scoped(.initrd_build).err("repack initramfs failed: {t}", .{err});
        return error.RepackFailed;
    };

    std.log.scoped(.initrd_build).info("initrd built at {s}", .{output_path});
}

fn runCmd(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(65536),
        .stderr_limit = .limited(65536),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const failed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        std.log.scoped(.initrd_build).err("command failed: {s}", .{argv[0]});
        return error.CommandFailed;
    }
}

fn runShell(io: std.Io, allocator: std.mem.Allocator, cmd: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", cmd },
        .stdout_limit = .limited(65536),
        .stderr_limit = .limited(65536),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const failed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        std.log.scoped(.initrd_build).err("shell command failed: {s}", .{cmd});
        return error.CommandFailed;
    }
}
