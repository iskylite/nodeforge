//! M4.7 部署初始化与离线重置原语。
//!
//! CLI 负责提示/确认；本模块负责路径受限的文件系统副作用。所有生成的路径
//! 来自运行时 `Paths`，配置在发布前校验，遗留 config/catalog 在 manifest 对外
//! 可见前先备份。

const std = @import("std");
const paths_mod = @import("paths.zig");
const model = @import("model.zig");
const config_load = @import("config/load.zig");
const config_store = @import("config/store.zig");
const catalog_store = @import("catalog/store.zig");
const validate = @import("config/validate.zig");
const deployment_control = @import("state/deployment_control.zig");
const model_transaction = @import("state/model_transaction.zig");
const atomicWrite = @import("state/dhcp_store.zig").atomicWrite;

/// `nodeforge setup` 收集的网络配置输入。
///
/// 这些字段在交互式提示中收集，生成初始 `config.json`。
pub const Network = struct {
    /// PXE 服务网卡名称（如 `enp1s0`）。DHCP 服务绑定该网卡收发广播。
    bind_interface: []const u8 = "eth0",
    /// PXE 服务网对外 IPv4 地址。用于生成 HTTP/TFTP URL 和 DHCP next-server。
    server_ip: []const u8 = "192.168.50.1",
    /// HTTP/管理共用监听端口。默认 18080，避免与常见 Web 服务 8080 冲突；
    /// `nodeforge setup --http-port <n>` 可覆盖。
    http_port: u16 = 18080,
    /// PXE 管理网 CIDR 子网。
    subnet: []const u8 = "192.168.50.0/24",
    /// 动态地址池起始 IP。
    pool_start: []const u8 = "192.168.50.100",
    /// 动态地址池结束 IP。
    pool_end: []const u8 = "192.168.50.200",
};

/// 根据网络配置和运行时路径生成初始 `AppConfig`。
///
/// 生成的配置始终使用当前最新 schema 版本。
///
/// schema 版本只是开发过程中的变动记录，不应影响主流程：CLI 始终按照最新
/// schema 执行，每次 schema 版本变动时代码同步更新版本号。`setup` 生成的
/// config 和 catalog 始终与当前代码版本一致，不需要手动迁移。
///
/// asset_root/repository_root 指向运行时路径中的目录。
pub fn generatedConfig(p: *const paths_mod.Paths, network: Network) model.AppConfig {
    return .{
        .schema_version = 4,
        .server = .{ .bind_interface = network.bind_interface, .server_ip = network.server_ip, .http_port = network.http_port },
        .http = .{ .asset_root = p.iso_dir, .repository_root = p.repos_dir },
        .tftp = .{ .asset_root = p.boot_dir },
        .dhcp = .{ .subnet = network.subnet, .pool_start = network.pool_start, .pool_end = network.pool_end },
    };
}

/// 创建安装根下的全部子目录并设置安全权限。
///
/// 目录权限策略：
/// - `750`：安装根、bin、systemd、logs、assets 及其子目录（iso/boot/repos/initrd/rootfs/bundles）。
/// - `700`：config、catalog、state、keys、provisioned、run、work、import、model-transactions。
///
/// 错误时部分目录可能已创建，但 `setup` 的幂等性保证重试可完成。
pub fn repairDirectories(io: std.Io, allocator: std.mem.Allocator, p: *const paths_mod.Paths) !void {
    const cwd = std.Io.Dir.cwd();
    inline for (.{ p.bin_dir, p.systemd_dir, p.config_dir, p.catalog_dir, p.state_dir, p.logs_dir, p.iso_dir, p.boot_dir, p.repos_dir, p.keys_dir, p.initrd_dir, p.rootfs_dir, p.bundles_dir, p.provisioned_dir, p.run_dir, p.work_dir, p.import_dir, p.model_transactions_dir }) |directory|
        try cwd.createDirPath(io, directory);
    inline for (.{ p.install_root, p.bin_dir, p.systemd_dir, p.logs_dir, p.assets_dir, p.iso_dir, p.boot_dir, p.repos_dir, p.initrd_dir, p.rootfs_dir, p.bundles_dir }) |directory|
        try chmod(io, allocator, "750", directory);
    inline for (.{ p.config_dir, p.catalog_dir, p.state_dir, p.keys_dir, p.provisioned_dir, p.run_dir, p.work_dir, p.import_dir, p.model_transactions_dir }) |directory|
        try chmod(io, allocator, "700", directory);
}

/// 拷贝同 bundle 的 CLI/daemon 对，以及可选但必须成对出现的 diskless
/// initrd/agent 构建器。调用方在全部拷贝成功后才创建 marker，故中断的安装
/// 无法通过正常 bootstrap 校验。
pub fn installBundle(io: std.Io, allocator: std.mem.Allocator, p: *const paths_mod.Paths) !void {
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const source_dir = std.fs.path.dirname(executable) orelse return error.InvalidBundleLayout;
    const cli_source = try std.fmt.allocPrint(allocator, "{s}/nodeforge", .{source_dir});
    defer allocator.free(cli_source);
    const daemon_source = try std.fmt.allocPrint(allocator, "{s}/nodeforged", .{source_dir});
    defer allocator.free(daemon_source);
    const initrd_source = try std.fmt.allocPrint(allocator, "{s}/nodeforge-initrd", .{source_dir});
    defer allocator.free(initrd_source);
    const agent_source = try std.fmt.allocPrint(allocator, "{s}/nodeforge-agent", .{source_dir});
    defer allocator.free(agent_source);
    if (!regularFile(io, cli_source) or !regularFile(io, daemon_source)) return error.IncompleteInstallBundle;
    const has_initrd = regularFile(io, initrd_source);
    const has_agent = regularFile(io, agent_source);
    if (has_initrd != has_agent) return error.IncompleteInstallBundle;
    try verifyCompanion(io, allocator, daemon_source);
    try repairDirectories(io, allocator, p);
    if (!samePath(io, allocator, cli_source, p.nodeforge_path)) try std.Io.Dir.copyFileAbsolute(cli_source, p.nodeforge_path, io, .{ .replace = true, .make_path = true });
    if (!samePath(io, allocator, daemon_source, p.nodeforged_path)) try std.Io.Dir.copyFileAbsolute(daemon_source, p.nodeforged_path, io, .{ .replace = true, .make_path = true });
    if (has_initrd) {
        const initrd_destination = try std.fmt.allocPrint(allocator, "{s}/nodeforge-initrd", .{p.bin_dir});
        defer allocator.free(initrd_destination);
        const agent_destination = try std.fmt.allocPrint(allocator, "{s}/nodeforge-agent", .{p.bin_dir});
        defer allocator.free(agent_destination);
        if (!samePath(io, allocator, initrd_source, initrd_destination)) try std.Io.Dir.copyFileAbsolute(initrd_source, initrd_destination, io, .{ .replace = true, .make_path = true });
        if (!samePath(io, allocator, agent_source, agent_destination)) try std.Io.Dir.copyFileAbsolute(agent_source, agent_destination, io, .{ .replace = true, .make_path = true });
    }
    try atomicWrite(io, p.marker_path, "nodeforge-root-v1\n");
}

/// 执行首次安装初始化：校验配置、安装二进制对、写入 config/catalog/systemd unit。
///
/// 如果提供了 `imported_config`，使用该配置而非 `generatedConfig` 的输出。
/// 空 catalog（无 distro 索引）是合法的首次安装状态——首个 ISO 导入会创建能力记录。
pub fn initialize(io: std.Io, allocator: std.mem.Allocator, p: *const paths_mod.Paths, network: Network, imported_config: ?*const model.AppConfig) !void {
    const config = if (imported_config) |candidate| candidate.* else generatedConfig(p, network);
    // 空 distro 索引是正常的首次安装状态；首个通过媒体布局校验的 ISO
    // 会与 install source 一起原子创建对应 family/version/arch 能力记录。
    // v0.2 默认 schema v4：diskless profile 的 tagged union kind 需要 v4。
    // 从 setup 初始化即使用 v4，避免后续手动迁移。
    const catalog: model.Catalog = .{ .schema_version = 4 };
    try validate.validate(&config, &catalog);
    try installBundle(io, allocator, p);
    try config_store.save(io, allocator, p.config_path, &config);
    try catalog_store.save(io, allocator, p.catalog_dir, &catalog);
    const unit = try renderSystemd(allocator, p);
    defer allocator.free(unit);
    try atomicWrite(io, p.service_path, unit);
}

/// 原地升级 schema 1。若后续步骤失败则备份与 marker 保留；因 manifest 提交
/// 经 digest 校验，重跑幂等。
pub fn migrateLegacy(io: std.Io, allocator: std.mem.Allocator, p: *const paths_mod.Paths) !bool {
    var parsed = try config_load.load(io, allocator, p.config_path);
    defer parsed.deinit();
    const marker = try std.fmt.allocPrint(allocator, "{s}/m4.7-migration.json", .{p.state_dir});
    defer allocator.free(marker);
    // Schema 3 and 4 already use the split catalog layout. `setup
    // --reconfigure` must be idempotent for a freshly initialized current
    // deployment; only schema 1/2 participate in the legacy M4.7 recovery
    // transaction below.
    if (parsed.value.schema_version == 3 or parsed.value.schema_version == 4) return false;
    if (parsed.value.schema_version == 2) {
        // 发布 config.json 后崩溃可能留下合法 manifest 与遗留 catalog.json 并存。
        // migration marker 是该混合布局属于一个已知事务的证明；完成其清理，而不是
        // 让普通 catalog 加载器猜测哪一代为权威。
        if (!regularFile(io, marker)) return false;
        const backup = try std.fmt.allocPrint(allocator, "{s}.m4.7.bak", .{p.legacy_catalog_path});
        defer allocator.free(backup);
        const had_legacy = regularFile(io, p.legacy_catalog_path);
        if (had_legacy) {
            if (!regularFile(io, backup)) try std.Io.Dir.copyFileAbsolute(p.legacy_catalog_path, backup, io, .{ .replace = false, .make_path = true });
            try std.Io.Dir.cwd().deleteFile(io, p.legacy_catalog_path);
        }
        var current_catalog = catalog_store.load(io, allocator, p.catalog_dir) catch |err| {
            if (had_legacy) std.Io.Dir.copyFileAbsolute(backup, p.legacy_catalog_path, io, .{ .replace = true, .make_path = true }) catch {};
            return err;
        };
        defer current_catalog.deinit();
        const effective = model.projectCatalog(parsed.value, &current_catalog.value);
        try validate.validate(&effective, &current_catalog.value);
        try std.Io.Dir.cwd().deleteFile(io, marker);
        return true;
    }
    if (parsed.value.schema_version != 1) return error.UnsupportedSchemaVersion;
    var legacy_catalog: ?std.json.Parsed(model.Catalog) = catalog_store.loadLegacy(io, allocator, p.legacy_catalog_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (legacy_catalog) |*loaded| loaded.deinit();
    var catalog = if (legacy_catalog) |*loaded| loaded.value else model.Catalog{};
    catalog.schema_version = 2;
    catalog.distros = parsed.value.distros;
    catalog.profiles = parsed.value.profiles;
    catalog.nodes = parsed.value.nodes;
    catalog.provisioning_bundles = parsed.value.provisioning_bundles;
    var startup = parsed.value;
    startup.schema_version = 2;
    const projected = model.projectCatalog(startup, &catalog);
    try validate.validate(&projected, &catalog);
    try repairDirectories(io, allocator, p);
    const config_backup = try std.fmt.allocPrint(allocator, "{s}.m4.7.bak", .{p.config_path});
    defer allocator.free(config_backup);
    if (!regularFile(io, config_backup)) try std.Io.Dir.copyFileAbsolute(p.config_path, config_backup, io, .{ .replace = false, .make_path = true });
    const revision = try deployment_control.revisionForModel(allocator, &projected, &catalog);
    const marker_bytes = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"state\":\"prepared\",\"request_digest\":\"{s}\"}}\n", .{revision.desired_digest});
    defer allocator.free(marker_bytes);
    try atomicWrite(io, marker, marker_bytes);
    try catalog_store.save(io, allocator, p.catalog_dir, &catalog);
    try config_store.save(io, allocator, p.config_path, &startup);
    if (regularFile(io, p.legacy_catalog_path)) {
        const backup = try std.fmt.allocPrint(allocator, "{s}.m4.7.bak", .{p.legacy_catalog_path});
        defer allocator.free(backup);
        if (!regularFile(io, backup)) try std.Io.Dir.copyFileAbsolute(p.legacy_catalog_path, backup, io, .{ .replace = false, .make_path = true });
        try std.Io.Dir.cwd().deleteFile(io, p.legacy_catalog_path);
    }
    try std.Io.Dir.cwd().deleteFile(io, marker);
    return true;
}

/// 重置运行态文件到干净状态，但保留 config/catalog。
///
/// 备份 leases/node-status/deployment-control/boot-sessions/inventory/operations
/// 到 `<install-root>/backups/state-<timestamp>/`，删除原文件。
/// 同时清空 `provisioned/` 目录。未完成的 model transaction journal 会先恢复再删除。
///
/// 返回备份目录路径，由调用方展示给操作员。
pub fn resetState(io: std.Io, allocator: std.mem.Allocator, p: *const paths_mod.Paths) ![]u8 {
    // Reset 可归档已完成证据，但绝不删除未决的 catalog/model journal。两个
    // coordinator 都必须到达已证实的 generation。
    if (exists(io, p.catalog_dir)) {
        var catalog = catalog_store.load(io, allocator, p.catalog_dir) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (catalog) |*loaded| loaded.deinit();
    }
    _ = try model_transaction.recoverAll(io, allocator, p.model_transactions_dir);
    const stamp = std.Io.Clock.real.now(io).toSeconds();
    const backup = try std.fmt.allocPrint(allocator, "{s}/backups/state-{d}", .{ p.install_root, stamp });
    errdefer allocator.free(backup);
    try std.Io.Dir.cwd().createDirPath(io, backup);
    var manifest: std.Io.Writer.Allocating = .init(allocator);
    defer manifest.deinit();
    try manifest.writer.writeAll("{\"schema_version\":1,\"files\":[");
    var first = true;
    for ([_][]const u8{ p.leases_path, p.node_status_path, p.deployment_control_path, p.boot_sessions_path, p.node_inventory_path, p.operations_path, p.rootfs_artifacts_path }) |state_path| {
        if (!regularFile(io, state_path)) continue;
        const destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ backup, std.fs.path.basename(state_path) });
        defer allocator.free(destination);
        try std.Io.Dir.copyFileAbsolute(state_path, destination, io, .{ .replace = false, .make_path = true });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, destination, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        var digest: [64]u8 = undefined;
        sha256(bytes, &digest);
        if (!first) try manifest.writer.writeByte(',');
        first = false;
        // digest 是 [64]u8 十六进制 ASCII 字节；必须以切片（[]const u8）序列化，
        // 否则 `&digest`（*[64]u8）会被 JSON 序列化为整数数组而非字符串。
        try manifest.writer.print("{{\"file\":{f},\"sha256\":{f}}}", .{ std.json.fmt(std.fs.path.basename(state_path), .{}), std.json.fmt(digest[0..], .{}) });
        try std.Io.Dir.cwd().deleteFile(io, state_path);
    }
    try manifest.writer.writeAll("]}\n");
    const backup_manifest = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{backup});
    defer allocator.free(backup_manifest);
    try atomicWrite(io, backup_manifest, manifest.written());
    if (exists(io, p.provisioned_dir)) try std.Io.Dir.cwd().deleteTree(io, p.provisioned_dir);
    try std.Io.Dir.cwd().createDirPath(io, p.provisioned_dir);
    return backup;
}

/// 渲染 systemd unit 文件内容。
///
/// 生成的 unit 以 root 运行，显式收窄 bounding set 为
/// `CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_ADMIN CAP_SYS_CHROOT`。
/// `CAP_SYS_CHROOT` 是 v0.2 rootfs build 所需：`dnf --installroot` 在事务
/// 测试阶段调用 `chroot(2)`，缺少该 capability 会报 `Operation not permitted`。
/// `CAP_SETFCAP` 允许 RPM 安装带 file capabilities 的基础包（例如 iputils）；
/// 缺少它会在 unpack 阶段以 Transaction failed 结束。
/// `PrivateMounts` 不使用：rootfs build 需要在 daemon 的 mount namespace
/// 中创建 loop/tmpfs/overlay 挂载，PrivateMounts 会隔离 mount namespace
/// 导致 rootfs build 后的挂载清理复杂化。
/// `ExecStartPre` 执行 `--check` 预检，失败时 systemd 不会启动主进程。
pub fn renderSystemd(allocator: std.mem.Allocator, p: *const paths_mod.Paths) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\[Unit]
        \\Description=NodeForge provisioning daemon
        \\After=network-online.target
        \\Wants=network-online.target
        \\
        \\[Service]
        \\Type=simple
        \\WorkingDirectory={s}
        \\ExecStartPre={s} --check --log-output file
        \\ExecStart={s} --log-output file
        \\Restart=on-failure
        \\RestartSec=2s
        \\# NoNewPrivileges disabled: v0.2 rootfs build runs `dnf --installroot` which
        \\# executes RPM scriptlets inside a chroot; these scriptlets need to create
        \\# setuid/setgid binaries and manage file ownership, which NoNewPrivileges
        \\# blocks. The expanded capability set below provides the necessary ambient
        \\# capabilities instead.
        \\CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_ADMIN CAP_SYS_CHROOT CAP_MKNOD CAP_CHOWN CAP_FOWNER CAP_SETUID CAP_SETGID CAP_SETFCAP CAP_DAC_OVERRIDE
        \\AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_ADMIN CAP_SYS_CHROOT CAP_MKNOD CAP_CHOWN CAP_FOWNER CAP_SETUID CAP_SETGID CAP_SETFCAP CAP_DAC_OVERRIDE
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{ p.install_root, p.nodeforged_path, p.nodeforged_path });
}

/// 检查路径是否为常规文件（非目录/symlink/socket）。
fn regularFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .file;
}
/// 检查路径是否存在（任何类型）。
fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}
/// 比较两个路径的 canonical 绝对路径是否相同。
/// 用于避免不必要的文件复制（原地安装场景）。
fn samePath(io: std.Io, allocator: std.mem.Allocator, left: []const u8, right: []const u8) bool {
    const a = std.Io.Dir.cwd().realPathFileAlloc(io, left, allocator) catch return false;
    defer allocator.free(a);
    const b = std.Io.Dir.cwd().realPathFileAlloc(io, right, allocator) catch return false;
    defer allocator.free(b);
    return std.mem.eql(u8, a, b);
}

/// 验证 daemon 二进制与当前 CLI 属于同一构建批次。
///
/// 执行 `daemon --version` 并比较版本字符串。版本不匹配时返回
/// `BundleProvenanceMismatch`，防止混合不同版本的二进制对。
fn verifyCompanion(io: std.Io, allocator: std.mem.Allocator, daemon: []const u8) !void {
    const version = @import("version.zig");
    const result = std.process.run(allocator, io, .{ .argv = &.{ daemon, "--version" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch return error.BundleProvenanceMismatch;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.BundleProvenanceMismatch,
        else => return error.BundleProvenanceMismatch,
    }
    const expected = try std.fmt.allocPrint(allocator, "nodeforged {s} (commit {s}, built {s}, {s})", .{ version.version, version.shortCommit(), version.build_time, if (version.git_dirty) "dirty" else "clean" });
    defer allocator.free(expected);
    if (!std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), expected)) return error.BundleProvenanceMismatch;
}

/// 计算字节的 SHA-256 摘要并以十六进制字符串输出到 64 字节缓冲区。
fn sha256(bytes: []const u8, output: *[64]u8) void {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    _ = std.fmt.bufPrint(output, "{x}", .{raw}) catch unreachable;
}

/// 使用外部 `chmod` 命令设置目录权限。
fn chmod(io: std.Io, allocator: std.mem.Allocator, mode: []const u8, path: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "chmod", mode, path }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ChmodFailed,
        else => return error.ChmodFailed,
    }
}

test "generated config and systemd use custom runtime root" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try temp.dir.realPath(std.testing.io, &buffer);
    var p = try paths_mod.Paths.candidate(std.testing.io, std.testing.allocator, buffer[0..n]);
    defer p.deinit(std.testing.allocator);
    const config = generatedConfig(&p, .{});
    try std.testing.expectEqualStrings(p.iso_dir, config.http.asset_root);
    // setup 生成的配置必须显式声明 http_port=18080，而非隐式依赖 model 默认值。
    try std.testing.expectEqual(@as(u16, 18080), config.server.http_port);
    const unit = try renderSystemd(std.testing.allocator, &p);
    defer std.testing.allocator.free(unit);
    try std.testing.expect(std.mem.indexOf(u8, unit, p.nodeforged_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "--config") == null);
}
