//! # v0.2 NodeForge initrd 构建器
//!
//! 构建 diskless PXE boot 使用的 nodeforge initramfs。首选流程以 ISO 的 vendor
//! installer initrd 为不可变基底，追加一个 gzip/newc NodeForge overlay，因而
//! 保留发行版 initrd 的专用 patch、固件和 kernel modules。没有 install source
//! 基底时才由 `dracut` 构建通用 fallback。随后：
//! 3. 注入 `nodeforge-initrd` 二进制到 `/usr/sbin/`
//! 4. 注入与 initrd 同一构建版本的 `nodeforge-agent`
//! 5. 创建 `/init` 脚本（exec nodeforge-initrd）
//! 6. 创建空 `/capsule` 目录（真实 credential 由 TFTP 多-initrd 内存交付）
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
    return buildInternal(io, allocator, kernel_release, nodeforge_initrd_binary, null, output_path);
}

/// 从 ISO/install source 的 installer initrd 派生。`base_initrd` 内容原样作为
/// 第一个 initramfs member，NodeForge 文件仅作为第二个 gzip/newc member
/// 追加；不解包重打 vendor member，避免丢失发行版 patch/ko/firmware。
pub fn buildFromInstaller(
    io: std.Io,
    allocator: std.mem.Allocator,
    kernel_release: []const u8,
    nodeforge_initrd_binary: []const u8,
    base_initrd: []const u8,
    output_path: []const u8,
) !void {
    return buildInternal(io, allocator, kernel_release, nodeforge_initrd_binary, base_initrd, output_path);
}

fn buildInternal(
    io: std.Io,
    allocator: std.mem.Allocator,
    kernel_release: []const u8,
    nodeforge_initrd_binary: []const u8,
    base_initrd: ?[]const u8,
    output_path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const work_dir = try std.fmt.allocPrint(a, "{s}/initrd-build-{s}", .{ paths.require().work_dir, kernel_release });
    std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, work_dir);
    defer std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};

    // Vendor-derived mode builds a small overlay only. The fallback unpacks a
    // freshly generated dracut image so the published output remains a single
    // conventional gzip member.
    const initrd_root = try std.fmt.allocPrint(a, "{s}/root", .{work_dir});
    try std.Io.Dir.cwd().createDirPath(io, initrd_root);
    if (base_initrd == null) {
        const base_img = try std.fmt.allocPrint(a, "{s}/initrd-base.img", .{work_dir});
        runCmd(io, allocator, &.{
            "dracut", "--no-hostonly",
            "--kver", kernel_release,
            "--modules", "network base",
            "--filesystems", "squashfs overlay",
            // Generic fallback covers common bare-metal emulation and virtio.
            // vmxnet3 is VMware-specific and is intentionally not universal.
            "--add-drivers", "loop virtio_net e1000e",
            "--install", "/usr/sbin/switch_root",
            base_img,
        }) catch |err| {
            std.log.scoped(.initrd_build).err("dracut failed: {t}", .{err});
            return error.DracutFailed;
        };
        const unpack_cmd = try std.fmt.allocPrint(a, "zcat {s} | (cd {s} && cpio -idmv 2>/dev/null)", .{ base_img, initrd_root });
        runShell(io, allocator, unpack_cmd) catch |err| {
            std.log.scoped(.initrd_build).err("unpack initramfs failed: {t}", .{err});
            return error.UnpackFailed;
        };
    } else {
        // Installer initrds commonly use NetworkManager and do not contain the
        // standalone dhclient binary used by NodeForge's PID-1 network setup;
        // installer images may also omit switch_root. Add only those userspace
        // companions (plus dynamic dependencies); all kernel modules and
        // firmware still come untouched from the ISO initrd. The build host
        // must match the target distro/architecture.
        runCmd(io, allocator, &.{
            "/usr/lib/dracut/dracut-install",
            "-D", initrd_root,
            "-l", "-a",
            "/usr/sbin/dhclient",
            "/usr/sbin/switch_root",
        }) catch |err| {
            std.log.scoped(.initrd_build).err("inject initrd userspace companions failed: {t}", .{err});
            return error.InjectFailed;
        };
    }

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
    const bin_parent = std.fs.path.dirname(nodeforge_initrd_binary) orelse return error.InjectFailed;
    const agent_source = try std.fmt.allocPrint(a, "{s}/nodeforge-agent", .{bin_parent});
    const agent_dest = try std.fmt.allocPrint(a, "{s}/nodeforge-agent", .{initrd_bin_dest});
    std.Io.Dir.copyFileAbsolute(agent_source, agent_dest, io, .{ .replace = true, .make_path = true }) catch |err| {
        std.log.scoped(.initrd_build).err("inject nodeforge-agent failed: {t}", .{err});
        return error.InjectFailed;
    };
    try runCmd(io, allocator, &.{ "chmod", "0755", agent_dest });

    // 4. 注入不依赖 NetworkManager/systemd 的最小 DHCP hook。
    const dhclient_script = try std.fmt.allocPrint(a, "{s}/usr/sbin/nodeforge-dhclient-script", .{initrd_root});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dhclient_script, .data =
        \\#!/bin/sh
        \\case "${reason:-}" in
        \\ PREINIT) /sbin/ip link set "$interface" up ;;
        \\ BOUND|RENEW|REBIND|REBOOT)
        \\  /sbin/ip addr flush dev "$interface"
        \\  /sbin/ip addr add "$new_ip_address/$new_subnet_mask" dev "$interface"
        \\  for router in ${new_routers:-}; do /sbin/ip route replace default via "$router" dev "$interface"; break; done
        \\  ;;
        \\esac
        \\exit 0
        \\
    });
    try runCmd(io, allocator, &.{ "chmod", "0755", dhclient_script });

    // 5. 创建 /init 脚本
    const init_script = try std.fmt.allocPrint(a, "{s}/init", .{initrd_root});
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = init_script, .data = "#!/bin/sh\nexec /usr/sbin/nodeforge-initrd\n" }) catch |err| {
        std.log.scoped(.initrd_build).err("create /init failed: {t}", .{err});
        return error.InitScriptFailed;
    };
    runCmd(io, allocator, &.{ "chmod", "+x", init_script }) catch {};

    // 6. 创建 /capsule 目录（boot-prepare 注入 token 文件）
    const capsule_dir = try std.fmt.allocPrint(a, "{s}/capsule", .{initrd_root});
    std.Io.Dir.cwd().createDirPath(io, capsule_dir) catch {};

    // 7. 发布。Vendor member 保持逐字节不变，NodeForge overlay 追加在后；
    // fallback 则重包成单一 gzip member。
    if (base_initrd) |base| try std.Io.Dir.copyFileAbsolute(base, output_path, io, .{ .replace = false, .make_path = true });
    const redirect = if (base_initrd == null) ">" else ">>";
    const repack_cmd = try std.fmt.allocPrint(a, "(cd {s} && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 {s} {s})", .{ initrd_root, redirect, output_path });
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
