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

    // dnf --installroot 安装的 rocky-release 等包会带入指向公网 mirror 的默认
    // .repo 文件。local-only 不变式要求 rootfs 只保留 nodeforge 管控的源。
    // 删除全部 .repo，再写入 nodeforge 管控源配置。
    try cleanupDefaultRepos(io, allocator, staging, repository_urls);
    // 写入基础 sshd 配置：允许 root 密钥登录、禁用密码认证。
    try writeDefaultSshdConfig(io, allocator, staging);
    // 生成 Profile 级共享 SSH client keypair + sshd host keys，并配置自身免密。
    // 同 Profile 节点共享这些 keys，因而可相互免密且 host fingerprint 一致。
    try generateSshKeys(io, allocator, staging);
    // 确保 systemd 默认启动目标为 multi-user.target。
    try ensureDefaultTarget(io, allocator, staging);
}

/// 清除 dnf --installroot 带入的默认 .repo 文件，写入 nodeforge 管控源。
/// local-only 不变式：rootfs 只保留 nodeforge 发布的本地受管源，不保留
/// 任何指向公网 mirror 的默认仓库配置。
fn cleanupDefaultRepos(io: std.Io, allocator: std.mem.Allocator, staging: []const u8, repository_urls: []const []const u8) !void {
    const repos_dir = try std.fmt.allocPrint(allocator, "{s}/etc/yum.repos.d", .{staging});
    defer allocator.free(repos_dir);
    // 创建目录（可能已存在）。
    std.Io.Dir.cwd().createDirPath(io, repos_dir) catch {};
    // 删除目录下所有 .repo 文件（rocky-release 等包带入的默认配置）。
    var dir = std.Io.Dir.cwd().openDir(io, repos_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".repo")) continue;
        dir.deleteFile(io, entry.name) catch {};
    }
    // 写入 nodeforge 管控源配置。
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    for (repository_urls, 0..) |url, index| {
        try content.writer.print("[nodeforge-{d}]\nname=NodeForge managed repo {d}\nbaseurl={s}\nenabled=1\ngpgcheck=0\n\n", .{ index, index, url });
    }
    const repo_file = try std.fmt.allocPrint(allocator, "{s}/nodeforge.repo", .{repos_dir});
    defer allocator.free(repo_file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = repo_file, .data = content.written() });
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
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false }) catch return false;
    file.close(io);
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
