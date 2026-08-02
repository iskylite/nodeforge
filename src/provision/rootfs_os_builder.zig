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
const identity_store = @import("../state/identity_store.zig");

/// 缺失会导致普通 rootfs 无法启动或无法由 Agent 收敛的核心包；该集合严格失败。
const dnf_core_packages = [_][]const u8{
    "bash",    "coreutils",      "dnf",            "systemd",   "shadow-utils", "util-linux",
    "iproute", "NetworkManager", "openssh-server", "procps-ng",
};

/// archive 并非每个 Profile 都会使用。builder 默认尝试提供这些工具，但缺失只
/// 降低可选 action 能力，不得阻断普通 rootfs。
const archive_tool_packages = [_][]const u8{ "tar", "gzip", "xz" };
const archive_tool_files = [_][]const u8{ "usr/bin/tar", "usr/bin/gzip", "usr/bin/xz" };

/// Ubuntu casper OS 层的真正发布闸，只包含普通 rootfs 自身必需的文件。
/// archive 工具不得放入本集合，否则未使用 archive 的 Profile 也会被错误阻断。
const casper_required_files = [_][]const u8{
    "sbin/init",
    "usr/lib/systemd/systemd",
    "usr/bin/apt",
    "usr/sbin/sshd",
};

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
/// v1：安装最小可 chroot 基线，并尽力补充 tar/gzip/xz archive 工具；后者缺失
/// 只产生 warning，只有实际引用相应 archive 的 action 才会失败。
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
    identities: *identity_store.Store,
    profile: *const model.ProfileConfig,
) !void {
    switch (package_manager) {
        // dnf 从零 bootstrap 必须有受管仓库；casper OS 层直接来自已导入的
        // squashfs，即使定制 ISO 没有完整 APT metadata 也应允许构建。
        .dnf => {
            if (repository_urls.len == 0) return error.NoManagedRepository;
            try buildDnf(io, allocator, staging, version, repository_urls, identities, profile);
        },
        .apt => try buildCasperOverlay(io, allocator, staging, casper_layer_paths, identities, profile),
    }
}

/// 按 base→top 顺序物化 casper squashfs layer，构成 Ubuntu OS 层。
/// 每层先解到独立临时目录，再把 squashfs 中的 `0:0` 字符设备按
/// overlay whiteout 语义应用为“删除下层同名路径”，最后合并普通内容。
/// 不能对同一 staging 直接连续 `unsquashfs -f`：Ubuntu 官方 layer
/// 使用字符设备表达 whiteout，下层已有同名目录时 unsquashfs 会
/// 返回非零。任一层解包或合并失败均整体失败，不吞错误码。
/// 完成后校验最小可 chroot 基线文件存在，并复用 dnf 分支的 sshd 配置/
/// default target helper 与 `installIdentityKeys`（v0.2.3 起两分支一致从
/// identity store 安装共享 SSH 资产，构建期不再 `ssh-keygen`）。
fn buildCasperOverlay(
    io: std.Io,
    allocator: std.mem.Allocator,
    staging: []const u8,
    casper_layer_paths: []const []const u8,
    identities: *identity_store.Store,
    profile: *const model.ProfileConfig,
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

    for (casper_required_files) |rel| {
        const abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staging, rel });
        defer allocator.free(abs);
        if (!fileExists(io, abs)) {
            std.log.scoped(.rootfs_build).err("casper overlay missing expected baseline file: {s}", .{abs});
            return error.CasperOverlayIncomplete;
        }
    }
    // casper layer 通常包含这些工具，但 archive 是可选能力。缺失时保留一个
    // 可定位 warning；不能因为当前 Profile 根本没有 archive action 而拒绝 rootfs。
    for (archive_tool_files) |rel| {
        const abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staging, rel });
        defer allocator.free(abs);
        if (!fileExists(io, abs))
            std.log.scoped(.rootfs_build).warn("casper overlay lacks optional archive tool: {s}; compressed archive actions may fail", .{abs});
    }

    // casper 安装器层的默认 target 可能指向安装器专用逻辑；覆盖为
    // multi-user.target，与 dnf OS 层一致。sshd 配置同样是纯 staging 文件
    // 操作，不依赖 apt。v0.2.3 起 SSH 资产与 dnf 分支一致从 identity store
    // 安装（installIdentityKeys，构建期不再 ssh-keygen）。
    try writeDefaultSshdConfig(io, allocator, staging);
    try installIdentityKeys(io, allocator, staging, identities, profile);
    try ensureDefaultTarget(io, allocator, staging);
}

fn buildDnf(
    io: std.Io,
    allocator: std.mem.Allocator,
    staging: []const u8,
    version: []const u8,
    repository_urls: []const []const u8,
    identities: *identity_store.Store,
    profile: *const model.ProfileConfig,
) !void {
    _ = version;
    try std.Io.Dir.cwd().createDirPath(io, staging);
    // 可启动且可由 nodeforge-agent 收敛的基线。不能只满足 chroot：node-apply
    // 固定使用 usermod/systemctl，切根后的系统还需要 init、网络与 SSH 服务。
    // 空 staging 尚无 dnf/rpm，bootstrap 必须由 host dnf + --installroot 完成；
    // 与旧实现的区别是该 host-context 被限制在独立 mount/PID namespace 中，并
    // 显式为 staging bind-mount /dev、/proc、/sys。OS 层完成后的 package 步骤
    // 才统一进入 chroot。
    namespaced_chroot_executor.execute(io, allocator, staging, .dnf, &dnf_core_packages, repository_urls, true, .installroot, 0, false) catch |err| {
        std.log.scoped(.rootfs_build).err("os-layer dnf namespaced install failed: {t}", .{err});
        return error.OsLayerBuildFailed;
    };
    // 默认尽力补齐 tar/gzip/xz。仓库裁剪或定制发行版缺少它们时只告警；普通
    // rootfs 仍可发布，真正使用 archive 时由统一 `tar -xf` action/journal 报错。
    namespaced_chroot_executor.execute(io, allocator, staging, .dnf, &archive_tool_packages, repository_urls, true, .installroot, 0, false) catch |err| {
        std.log.scoped(.rootfs_build).warn("optional archive tools were not fully installed: {t}; archive actions may fail", .{err});
    };

    // 构建期与运行期都只使用 nodeforged 发布的 HTTP repository。这里清除
    // dnf 带入的 vendor 公网源；节点启动时由 immutable AgentPlan 重写同一组
    // 受管 HTTP 源，避免构建机路径泄漏到目标系统。
    try cleanupDefaultRepos(io, allocator, staging);
    // 写入基础 sshd 配置：允许 root 密钥登录、禁用密码认证。
    try writeDefaultSshdConfig(io, allocator, staging);
    // v0.2.3 §3.3: 从 identity store 按 (ssh_identity.id, revision) 复合键读取
    // Profile 级共享 SSH keys 并写入 staging（不再在构建期 ssh-keygen）。
    // 同 Profile 节点共享这些 keys，因而可相互免密且 host fingerprint 一致。
    try installIdentityKeys(io, allocator, staging, identities, profile);
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

/// v0.2.3 §3.3: 从 identity store 按 `(ssh_identity.id, revision)` 复合键读取
/// Profile 级共享 SSH keys 并写入 staging，替代构建期 `ssh-keygen`。
///
/// 写入内容：
/// - sshd host keys（ed25519）：`/etc/ssh/ssh_host_ed25519_key{,.pub}`
/// - root client keypair（ed25519）：`/root/.ssh/id_ed25519{,.pub}`
/// - `/root/.ssh/authorized_keys`：包含 client public key
/// - `/etc/ssh/ssh_known_hosts`：包含 host public key（localhost + 127.0.0.1）
/// - 权限保持私钥 0600、公钥/authorized_keys/known_hosts 0644、`.ssh` 0700。
///
/// 未命中（identity 缺失或引用为空）→ `IdentityNotFound` fail closed：绝不在
/// build 期静默生成与 catalog 引用不一致的替代密钥。
fn installIdentityKeys(io: std.Io, allocator: std.mem.Allocator, staging: []const u8, identities: *identity_store.Store, profile: *const model.ProfileConfig) !void {
    var identity: identity_store.IdentityRecord = undefined;
    if (!identities.copy(profile.ssh_identity.id, profile.ssh_identity.revision, &identity)) return error.IdentityNotFound;

    // ── 1. host keys：写入 sshd host keypair ───────────────────────────
    const ssh_dir = try std.fmt.allocPrint(allocator, "{s}/etc/ssh", .{staging});
    defer allocator.free(ssh_dir);
    std.Io.Dir.cwd().createDirPath(io, ssh_dir) catch {};
    const host_key = try std.fmt.allocPrint(allocator, "{s}/ssh_host_ed25519_key", .{ssh_dir});
    defer allocator.free(host_key);
    const host_pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{host_key});
    defer allocator.free(host_pub_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = host_key, .data = identity.hostPrivateKey() });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = host_pub_path, .data = identity.hostPublicKey() });

    // ── 2. root client keypair ─────────────────────────────────────────
    const root_ssh = try std.fmt.allocPrint(allocator, "{s}/root/.ssh", .{staging});
    defer allocator.free(root_ssh);
    std.Io.Dir.cwd().createDirPath(io, root_ssh) catch {};
    const client_key = try std.fmt.allocPrint(allocator, "{s}/id_ed25519", .{root_ssh});
    defer allocator.free(client_key);
    const client_pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{client_key});
    defer allocator.free(client_pub_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = client_key, .data = identity.clientPrivateKey() });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = client_pub_path, .data = identity.clientPublicKey() });

    // ── 3. authorized_keys 包含自身的 client public key ───────────────
    // 使 root 可免密 SSH 到自身和同 Profile 的其他节点（共享同一 rootfs 与
    // client keypair）。
    const authorized_keys_path = try std.fmt.allocPrint(allocator, "{s}/authorized_keys", .{root_ssh});
    defer allocator.free(authorized_keys_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = authorized_keys_path, .data = identity.clientPublicKey() });
    // 权限：私钥 0600，公钥/authorized_keys 0644，.ssh 目录 0700。
    try runChecked(io, allocator, &.{ "chmod", "0600", client_key });
    try runChecked(io, allocator, &.{ "chmod", "0644", client_pub_path });
    try runChecked(io, allocator, &.{ "chmod", "0644", authorized_keys_path });
    try runChecked(io, allocator, &.{ "chmod", "0700", root_ssh });

    // ── 4. ssh_known_hosts 包含 host public key ────────────────────────
    // 绑定 localhost / 127.0.0.1 / * 通配符，使同 Profile 节点首次连接也无需
    // 人工确认 host key。
    const known_hosts_path = try std.fmt.allocPrint(allocator, "{s}/ssh_known_hosts", .{ssh_dir});
    defer allocator.free(known_hosts_path);
    var kh: std.Io.Writer.Allocating = .init(allocator);
    defer kh.deinit();
    try kh.writer.print("localhost,127.0.0.1,* {s}", .{identity.hostPublicKey()});
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

test "rootfs builder treats gzip and xz as optional archive capabilities" {
    inline for (.{ "tar", "gzip", "xz" }) |required| {
        var found = false;
        for (archive_tool_packages) |package| found = found or std.mem.eql(u8, package, required);
        try std.testing.expect(found);
        const executable = "usr/bin/" ++ required;
        found = false;
        for (archive_tool_files) |path| found = found or std.mem.eql(u8, path, executable);
        try std.testing.expect(found);
        for (casper_required_files) |path| try std.testing.expect(!std.mem.eql(u8, path, executable));
    }
}
