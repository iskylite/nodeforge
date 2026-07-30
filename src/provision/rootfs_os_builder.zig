//! # v0.2/v0.2.1 rootfs OS 层构建器
//!
//! `V0_2_DESIGN.md` §5.2 / `DISKLESS_FINAL.md` §4 / `V0_2_1_UBUNTU_DISKLESS.md` §2.3.1。
//! rootfs 的 OS 层由发行版原生工具从 install source 受管 repository 构建到只读
//! lower：RHEL/Rocky 走 `dnf install`（v0.2.1 起统一经
//! `namespaced_chroot_executor` 在独立 namespace 内执行；空 staging 的 bootstrap
//! 仍由 host dnf 使用 `--installroot`，后续 package 步骤才进入 chroot）；Ubuntu
//! 走同源 ISO 的 casper squashfs 三层
//! overlay（`buildCasperOverlay`），不隐式回退宿主 apt/debootstrap。
//!
//! OS 层实际构建属环境相关执行边界（仅 Linux/root 构建主机可用，与 initrd/
//! first_boot/rootfs_build_executor 一致），本模块不在单元测试覆盖内。叠加
//! `rootfs_build_executor` 的 rootfs-build phase 步骤后产出最终 rootfs。
const std = @import("std");
const model = @import("../model.zig");
const dto = @import("../http/diskless_dto.zig");
const namespaced_chroot_executor = @import("namespaced_chroot_executor.zig");

/// 在 staging 目录内用发行版原生工具构建 OS 层。`repository_urls` 为
/// nodeforged 本机受管源的 `file://` URL。构建发生在 management handler 内，
/// 禁止回连同一 HTTP listener；目标系统获得的仓库仍由 AgentPlan/安装计划绑定
/// 为 nodeforged 的 HTTP URL。`version` 为 install source 版本（如 "9.7"）；
/// dnf 取主版本作 `--releasever`。
///
/// `casper_layers` 与 `casper_layer_paths`（已发布 casper squashfs 文件的绝对
/// 路径，与 `casper_layers` 一一对应、base→top 有序）只在 `package_manager ==
/// .apt` 时有意义；dnf 分支忽略。
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
    casper_layer_paths: []const []const u8,
) !void {
    switch (package_manager) {
        // dnf 从零 bootstrap 必须有受管仓库；casper OS 层直接来自已导入的
        // squashfs，即使定制 ISO 没有完整 APT metadata 也应允许构建。
        .dnf => {
            if (repository_urls.len == 0) return error.NoManagedRepository;
            try buildDnf(io, allocator, staging, version, repository_urls);
        },
        .apt => try buildCasperOverlay(io, allocator, staging, casper_layer_paths),
    }
}

/// 按 base→top 顺序物化 casper squashfs layer，构成 Ubuntu OS 层。
/// 每层先解到独立临时目录，再把 squashfs 中的 `0:0` 字符设备按
/// overlay whiteout 语义应用为“删除下层同名路径”，最后合并普通内容。
/// 不能对同一 staging 直接连续 `unsquashfs -f`：Ubuntu 官方 layer
/// 使用字符设备表达 whiteout，下层已有同名目录时 unsquashfs 会
/// 返回非零。任一层解包或合并失败均整体失败，不吞错误码。
/// 完成后校验最小可 chroot 基线文件存在，并复用 dnf 分支的 sshd 配置/
/// default target helper（不调用 `generateSshKeys`：Stage 5 已经统一处理）。
fn buildCasperOverlay(
    io: std.Io,
    allocator: std.mem.Allocator,
    staging: []const u8,
    casper_layer_paths: []const []const u8,
) !void {
    if (casper_layer_paths.len == 0) return error.MissingCasperLayers;
    try std.Io.Dir.cwd().createDirPath(io, staging);
    for (casper_layer_paths, 0..) |layer_path, index| {
        const layer_dir = try std.fmt.allocPrint(allocator, "{s}.casper-layer-{d}", .{ staging, index });
        defer allocator.free(layer_dir);
        std.Io.Dir.cwd().deleteTree(io, layer_dir) catch {};
        defer std.Io.Dir.cwd().deleteTree(io, layer_dir) catch {};

        // 不加 `|| true`：任一层解包失败即整体失败。
        try runChecked(io, allocator, &.{ "unsquashfs", "-d", layer_dir, layer_path });
        try runChecked(io, allocator, &.{
            "sh",
            "-c",
            \\set -eu
            \\layer=$1
            \\target=$2
            \\find "$layer" -xdev -type c -exec sh -c '
            \\  layer=$1; target=$2; shift 2
            \\  for path do
            \\    test "$(stat -c %t:%T "$path")" = 0:0 || continue
            \\    relative=${path#"$layer"/}
            \\    rm -rf -- "$target/$relative"
            \\    rm -f -- "$path"
            \\  done
            \\' sh "$layer" "$target" {} +
            \\cp -a "$layer/." "$target/"
            ,
            "nodeforge-casper-merge",
            layer_dir,
            staging,
        });
        std.Io.Dir.cwd().deleteTree(io, layer_dir) catch {};
    }

    for ([_][]const u8{
        "sbin/init",
        "usr/lib/systemd/systemd",
        "usr/bin/apt",
        "usr/sbin/sshd",
    }) |rel| {
        const abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staging, rel });
        defer allocator.free(abs);
        if (!fileExists(io, abs)) {
            std.log.scoped(.rootfs_build).err("casper overlay missing expected baseline file: {s}", .{abs});
            return error.CasperOverlayIncomplete;
        }
    }

    // casper 安装器层的默认 target 可能指向安装器专用逻辑；覆盖为
    // multi-user.target，与 dnf OS 层一致。sshd 配置同样是纯 staging 文件
    // 操作，不依赖 apt；不调用 `generateSshKeys`（Stage 5 统一生成，避免重复）。
    try writeDefaultSshdConfig(io, allocator, staging);
    try ensureDefaultTarget(io, allocator, staging);
}

fn buildDnf(
    io: std.Io,
    allocator: std.mem.Allocator,
    staging: []const u8,
    version: []const u8,
    repository_urls: []const []const u8,
) !void {
    _ = version;
    try std.Io.Dir.cwd().createDirPath(io, staging);
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
    // 空 staging 尚无 dnf/rpm，bootstrap 必须由 host dnf + --installroot 完成；
    // 与旧实现的区别是该 host-context 被限制在独立 mount/PID namespace 中，并
    // 显式为 staging bind-mount /dev、/proc、/sys。OS 层完成后的 package 步骤
    // 才统一进入 chroot。
    namespaced_chroot_executor.execute(io, allocator, staging, .dnf, &baseline, repository_urls, true, .installroot, 0) catch |err| {
        std.log.scoped(.rootfs_build).err("os-layer dnf namespaced install failed: {t}", .{err});
        return error.OsLayerBuildFailed;
    };

    // 构建期与运行期都只使用 nodeforged 发布的 HTTP repository。这里清除
    // dnf 带入的 vendor 公网源；节点启动时由 immutable AgentPlan 重写同一组
    // 受管 HTTP 源，避免构建机路径泄漏到目标系统。
    try cleanupDefaultRepos(io, allocator, staging);
    // 写入基础 sshd 配置：允许 root 密钥登录、禁用密码认证。
    try writeDefaultSshdConfig(io, allocator, staging);
    // 生成 Profile 级共享 SSH client keypair + sshd host keys，并配置自身免密。
    // 同 Profile 节点共享这些 keys，因而可相互免密且 host fingerprint 一致。
    try generateSshKeys(io, allocator, staging);
    // 确保 systemd 默认启动目标为 multi-user.target。
    try ensureDefaultTarget(io, allocator, staging);
}

/// 清除 dnf --installroot 带入的默认 .repo 文件。构建与运行都使用受管 HTTP
/// URL，但目标 rootfs 不继承构建工具生成的临时 repo 文件。
fn cleanupDefaultRepos(io: std.Io, allocator: std.mem.Allocator, staging: []const u8) !void {
    const repos_dir = try std.fmt.allocPrint(allocator, "{s}/etc/yum.repos.d", .{staging});
    defer allocator.free(repos_dir);
    try std.Io.Dir.cwd().createDirPath(io, repos_dir);
    // 删除目录下所有 .repo 文件（rocky-release 等包带入的默认配置）。
    var dir = try std.Io.Dir.cwd().openDir(io, repos_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".repo")) continue;
        try dir.deleteFile(io, entry.name);
    }
}

/// 写入基础 sshd 配置 drop-in，使 sshd 在 node-apply 之前也有可用配置。
/// PermitRootLogin prohibit-password + PasswordAuthentication no。
fn writeDefaultSshdConfig(io: std.Io, allocator: std.mem.Allocator, staging: []const u8) !void {
    const dropin_dir = try std.fmt.allocPrint(allocator, "{s}/etc/ssh/sshd_config.d", .{staging});
    defer allocator.free(dropin_dir);
    std.Io.Dir.cwd().createDirPath(io, dropin_dir) catch {};
    const dropin_path = try std.fmt.allocPrint(allocator, "{s}/50-nodeforge-default.conf", .{dropin_dir});
    defer allocator.free(dropin_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dropin_path, .data =
        \\PermitRootLogin prohibit-password
        \\PasswordAuthentication no
        \\PubkeyAuthentication yes
        \\
    });
}

/// 生成 Profile 级共享 SSH keys 并配置自身免密。
///
/// 按 V0_2_DESIGN.md §4.4，每个 diskless Profile 的 rootfs build 自动生成并固定
/// Profile 级 SSH client keypair 和 sshd host keys。同 Profile 节点共享这些 keys，
/// 因而可相互免密且 host fingerprint 一致。
///
/// 生成内容：
/// - sshd host keys（ed25519）：`/etc/ssh/ssh_host_ed25519_key{,.pub}`
/// - root client keypair（ed25519）：`/root/.ssh/id_ed25519{,.pub}`
/// - `/root/.ssh/authorized_keys`：包含 client public key
/// - `/etc/ssh/ssh_known_hosts`：包含 host public key（localhost + 127.0.0.1）
fn generateSshKeys(io: std.Io, allocator: std.mem.Allocator, staging: []const u8) !void {
    // ── 1. 生成 sshd host keys ──────────────────────────────────────────
    const ssh_dir = try std.fmt.allocPrint(allocator, "{s}/etc/ssh", .{staging});
    defer allocator.free(ssh_dir);
    std.Io.Dir.cwd().createDirPath(io, ssh_dir) catch {};
    const host_key = try std.fmt.allocPrint(allocator, "{s}/ssh_host_ed25519_key", .{ssh_dir});
    defer allocator.free(host_key);
    // ssh-keygen -t ed25519 -f <path> -N "" -C "nodeforge-host" 生成无密码 host key。
    // 幂等：已存在时 ssh-keygen 返回错误，但我们忽略它。
    if (!fileExists(io, host_key)) {
        try runChecked(io, allocator, &.{
            "ssh-keygen", "-t", "ed25519", "-f", host_key, "-N", "", "-C", "nodeforge-host",
        });
    }

    // ── 2. 生成 root client keypair ────────────────────────────────────
    const root_ssh = try std.fmt.allocPrint(allocator, "{s}/root/.ssh", .{staging});
    defer allocator.free(root_ssh);
    std.Io.Dir.cwd().createDirPath(io, root_ssh) catch {};
    const client_key = try std.fmt.allocPrint(allocator, "{s}/id_ed25519", .{root_ssh});
    defer allocator.free(client_key);
    if (!fileExists(io, client_key)) {
        try runChecked(io, allocator, &.{
            "ssh-keygen", "-t", "ed25519", "-f", client_key, "-N", "", "-C", "nodeforge-client",
        });
    }

    // ── 3. 读取 client public key 并写入 authorized_keys ───────────────
    const client_pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{client_key});
    defer allocator.free(client_pub_path);
    const client_pub = try std.Io.Dir.cwd().readFileAlloc(io, client_pub_path, allocator, .limited(8192));
    defer allocator.free(client_pub);
    // authorized_keys 包含自身的 client public key，使 root 可免密 SSH 到自身
    // 和同 Profile 的其他节点（它们共享同一 rootfs 和 client keypair）。
    const authorized_keys_path = try std.fmt.allocPrint(allocator, "{s}/authorized_keys", .{root_ssh});
    defer allocator.free(authorized_keys_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = authorized_keys_path, .data = client_pub });
    // 设置权限：私钥 0600，公钥和 authorized_keys 0644，.ssh 目录 0700。
    try runChecked(io, allocator, &.{ "chmod", "0600", client_key });
    try runChecked(io, allocator, &.{ "chmod", "0644", client_pub_path });
    try runChecked(io, allocator, &.{ "chmod", "0644", authorized_keys_path });
    try runChecked(io, allocator, &.{ "chmod", "0700", root_ssh });

    // ── 4. 读取 host public key 并写入 ssh_known_hosts ─────────────────
    const host_pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{host_key});
    defer allocator.free(host_pub_path);
    const host_pub = try std.Io.Dir.cwd().readFileAlloc(io, host_pub_path, allocator, .limited(8192));
    defer allocator.free(host_pub);
    // ssh_known_hosts 包含 host public key，绑定到 localhost / 127.0.0.1 / * 通配符，
    // 使同 Profile 节点首次连接也无需人工确认 host key。
    // host_pub 格式为 "ssh-ed25519 AAAA... nodeforge-host\n"，直接在前面加 host 列表。
    const known_hosts_path = try std.fmt.allocPrint(allocator, "{s}/ssh_known_hosts", .{ssh_dir});
    defer allocator.free(known_hosts_path);
    var kh: std.Io.Writer.Allocating = .init(allocator);
    defer kh.deinit();
    // 通配符 * 使同 Profile 任意节点 IP/hostname 都能匹配，实现域内互信。
    try kh.writer.print("localhost,127.0.0.1,* {s}", .{host_pub});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = known_hosts_path, .data = kh.written() });
    try runChecked(io, allocator, &.{ "chmod", "0644", known_hosts_path });
}

/// 检查文件是否存在（非符号链接）。
fn fileExists(io: std.Io, path: []const u8) bool {
    // casper 中 `/sbin/init` 通常是指向 `/lib/systemd/systemd` 的绝对
    // symlink。`openFile(... follow_symlinks=false)` 会把“链接存在”误判为
    // 不存在；这里需要 lstat 语义，只验证 staging 内该入口存在。
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// 确保 systemd 默认启动目标为 multi-user.target。
fn ensureDefaultTarget(io: std.Io, allocator: std.mem.Allocator, staging: []const u8) !void {
    const link_path = try std.fmt.allocPrint(allocator, "{s}/etc/systemd/system/default.target", .{staging});
    defer allocator.free(link_path);
    const parent = std.fs.path.dirname(link_path) orelse return;
    std.Io.Dir.cwd().createDirPath(io, parent) catch {};
    // 删除已有链接（幂等）。
    std.Io.Dir.cwd().deleteFile(io, link_path) catch {};
    try runChecked(io, allocator, &.{ "ln", "-sfn", "/usr/lib/systemd/system/multi-user.target", link_path });
}

fn runChecked(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(131072), .stderr_limit = .limited(131072) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

/// 取版本主版本号作为 dnf `--releasever`：`9.7` -> `9`，`22.04` -> `22`。
fn majorVersion(version: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse return version;
    return version[0..dot];
}
