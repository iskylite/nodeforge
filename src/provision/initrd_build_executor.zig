//! # v0.2 NodeForge initrd 构建器
//!
//! 构建 diskless PXE boot 使用的 nodeforge initramfs。首选流程以 ISO 的 vendor
//! installer initrd 为不可变基底，追加一个 gzip/newc NodeForge overlay，因而
//! 保留发行版 initrd 的专用 patch、固件和 kernel modules。没有 install source
//! 基底时才由 `dracut` 构建通用 fallback。随后：
//! 3. 注入 `nodeforge-initrd` 二进制到 `/usr/sbin/`
//! 4. 注入与 initrd 同一构建版本的 `nodeforge-agent`
//! 5. 将 `nodeforge-initrd` 直接安装为 `/init`，避免 PID 1 启动依赖 `/bin/sh`
//! 6. 创建空 `/capsule` 目录（真实 credential 由 TFTP 多-initrd 内存交付）
//! 7. 重包 NodeForge overlay（find | cpio | gzip）；vendor initrd 字节保持前缀不变
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
    std.log.scoped(.initrd_build).info("initrd build: stage 1/7 - preparing work directory (kver={s})", .{kernel_release});
    std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, work_dir);
    defer std.Io.Dir.cwd().deleteTree(io, work_dir) catch {};

    // Vendor-derived mode builds a small overlay only. The fallback unpacks a
    // freshly generated dracut image so the published output remains a single
    // conventional gzip member.
    const initrd_root = try std.fmt.allocPrint(a, "{s}/root", .{work_dir});
    try std.Io.Dir.cwd().createDirPath(io, initrd_root);
    if (base_initrd == null) {
        std.log.scoped(.initrd_build).info("initrd build: stage 2/7 - dracut fallback (no vendor initrd)", .{});
        const base_img = try std.fmt.allocPrint(a, "{s}/initrd-base.img", .{work_dir});
        runCmd(io, allocator, &.{
            "dracut",        "--no-hostonly",
            "--kver",        kernel_release,
            "--modules",     "network base",
            "--filesystems", "squashfs overlay",
            // Generic fallback covers common bare-metal emulation and virtio.
            // vmxnet3 is VMware-specific and is intentionally not universal.
            "--add-drivers", "loop virtio_net e1000e",
            "--install",     "/usr/sbin/switch_root",
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
        // Vendor initrd 与 boot kernel 来自同一 ISO，已经形成完整的 kernel/module
        // 和 userspace ABI closure。这里绝不能用宿主机 dracut-install 补充
        // dhclient/switch_root：它会递归复制宿主 libc/loader，追加 member 随后
        // 覆盖 vendor 同名文件，形成例如 Rocky 10 /bin/sh + Rocky 9 libc 的混配。
        //
        // NodeForge overlay 只包含自身二进制、纯文本 hook、/init 和 capsule；
        // 启动期网络与 switch-root 必须由 nodeforge-initrd 自身或 vendor closure
        // 中已有的工具完成，不能隐式借用构建宿主 userspace。
        std.log.scoped(.initrd_build).info("initrd build: stage 2/7 - vendor initrd overlay mode", .{});
    }

    // 3. 注入 nodeforge-initrd 二进制
    std.log.scoped(.initrd_build).info("initrd build: stage 3/7 - injecting nodeforge-initrd + agent binaries", .{});
    const initrd_bin_dest = try std.fmt.allocPrint(a, "{s}/usr/sbin", .{initrd_root});
    try std.Io.Dir.cwd().createDirPath(io, initrd_bin_dest);
    const initrd_bin_path = try std.fmt.allocPrint(a, "{s}/nodeforge-initrd", .{initrd_bin_dest});
    std.Io.Dir.copyFileAbsolute(nodeforge_initrd_binary, initrd_bin_path, io, .{ .replace = true, .make_path = true }) catch |err| {
        std.log.scoped(.initrd_build).err("inject nodeforge-initrd failed: {t}", .{err});
        return error.InjectFailed;
    };
    // 设置可执行权限
    try runCmd(io, allocator, &.{ "chmod", "0755", initrd_bin_path });
    const bin_parent = std.fs.path.dirname(nodeforge_initrd_binary) orelse return error.InjectFailed;
    const agent_source = try std.fmt.allocPrint(a, "{s}/nodeforge-agent", .{bin_parent});
    const agent_dest = try std.fmt.allocPrint(a, "{s}/nodeforge-agent", .{initrd_bin_dest});
    std.Io.Dir.copyFileAbsolute(agent_source, agent_dest, io, .{ .replace = true, .make_path = true }) catch |err| {
        std.log.scoped(.initrd_build).err("inject nodeforge-agent failed: {t}", .{err});
        return error.InjectFailed;
    };
    try runCmd(io, allocator, &.{ "chmod", "0755", agent_dest });

    // 4. 注入不依赖 NetworkManager/systemd 的最小 DHCP hooks。运行时优先使用
    // vendor initrd 已有的 BusyBox udhcpc；dhclient 是跨发行版确定性 fallback。
    std.log.scoped(.initrd_build).info("initrd build: stage 4/7 - creating DHCP client hooks", .{});
    const dhclient_script = try std.fmt.allocPrint(a, "{s}/usr/sbin/nodeforge-dhclient-script", .{initrd_root});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dhclient_script, .data =
        \\#!/bin/sh
        \\mask_prefix() {
        \\ old_ifs=$IFS; IFS=.; set -- $1; IFS=$old_ifs; prefix=0
        \\ for octet in "$@"; do
        \\  case "$octet" in 255) bits=8;; 254) bits=7;; 252) bits=6;; 248) bits=5;; 240) bits=4;; 224) bits=3;; 192) bits=2;; 128) bits=1;; 0) bits=0;; *) return 1;; esac
        \\  prefix=$((prefix + bits))
        \\ done
        \\ echo "$prefix"
        \\}
        \\case "${reason:-}" in
        \\ PREINIT) /sbin/ip link set "$interface" up ;;
        \\ BOUND|RENEW|REBIND|REBOOT)
        \\  prefix=$(mask_prefix "$new_subnet_mask") || exit 1
        \\  /sbin/ip addr flush dev "$interface"
        \\  /sbin/ip addr add "$new_ip_address/$prefix" dev "$interface" || exit 1
        \\  for router in ${new_routers:-}; do /sbin/ip route replace default via "$router" dev "$interface" || exit 1; break; done
        \\  ;;
        \\esac
        \\exit 0
        \\
    });
    try runCmd(io, allocator, &.{ "chmod", "0755", dhclient_script });
    const udhcpc_script = try std.fmt.allocPrint(a, "{s}/usr/sbin/nodeforge-udhcpc-script", .{initrd_root});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = udhcpc_script, .data =
        \\#!/bin/sh
        \\mask_prefix() {
        \\ old_ifs=$IFS; IFS=.; set -- $1; IFS=$old_ifs; prefix=0
        \\ for octet in "$@"; do
        \\  case "$octet" in 255) bits=8;; 254) bits=7;; 252) bits=6;; 248) bits=5;; 240) bits=4;; 224) bits=3;; 192) bits=2;; 128) bits=1;; 0) bits=0;; *) return 1;; esac
        \\  prefix=$((prefix + bits))
        \\ done
        \\ echo "$prefix"
        \\}
        \\case "${1:-${reason:-}}" in
        \\ deconfig) /sbin/ip addr flush dev "$interface" ;;
        \\ bound|renew)
        \\  prefix=$(mask_prefix "${subnet:-255.255.255.0}") || exit 1
        \\  /sbin/ip addr flush dev "$interface"
        \\  /sbin/ip addr add "$ip/$prefix" dev "$interface" || exit 1
        \\  for gateway in ${router:-}; do /sbin/ip route replace default via "$gateway" dev "$interface" || exit 1; break; done
        \\  ;;
        \\esac
        \\exit 0
        \\
    });
    try runCmd(io, allocator, &.{ "chmod", "0755", udhcpc_script });

    // 5. nodeforge-initrd 本身直接作为 PID 1。不能使用 `#!/bin/sh` wrapper：
    // kernel 执行脚本时会先动态加载 vendor `/bin/sh`，使 NodeForge 代码运行前
    // 就暴露于 initramfs 中 shell/libc 混配问题。main() 入口会立即设置完整 PATH。
    std.log.scoped(.initrd_build).info("initrd build: stage 5/7 - installing nodeforge-initrd as /init PID 1", .{});
    const init_path = try std.fmt.allocPrint(a, "{s}/init", .{initrd_root});
    std.Io.Dir.copyFileAbsolute(nodeforge_initrd_binary, init_path, io, .{ .replace = true, .make_path = true }) catch |err| {
        std.log.scoped(.initrd_build).err("install nodeforge-initrd as /init failed: {t}", .{err});
        return error.InitScriptFailed;
    };
    try runCmd(io, allocator, &.{ "chmod", "0755", init_path });

    // 6. 创建 /capsule 目录（boot-prepare 注入 token 文件）
    std.log.scoped(.initrd_build).info("initrd build: stage 6/7 - creating /capsule directory", .{});
    const capsule_dir = try std.fmt.allocPrint(a, "{s}/capsule", .{initrd_root});
    try std.Io.Dir.cwd().createDirPath(io, capsule_dir);

    // 7. 发布。Vendor member 保持逐字节不变，NodeForge overlay 追加在后；
    // fallback 则重包成单一 gzip member。
    std.log.scoped(.initrd_build).info("initrd build: stage 7/7 - repacking initramfs (mode={s})", .{if (base_initrd != null) "vendor-overlay" else "dracut-fallback"});
    if (base_initrd) |base| try std.Io.Dir.copyFileAbsolute(base, output_path, io, .{ .replace = false, .make_path = true });
    const redirect = if (base_initrd == null) ">" else ">>";
    const repack_cmd = try std.fmt.allocPrint(a, "(cd {s} && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 {s} {s})", .{ initrd_root, redirect, output_path });
    runShell(io, allocator, repack_cmd) catch |err| {
        std.log.scoped(.initrd_build).err("initrd build: stage 7 FAILED - repack ({t})", .{err});
        return error.RepackFailed;
    };

    std.log.scoped(.initrd_build).info("initrd build: DONE - output={s}", .{output_path});
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
