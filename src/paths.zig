//! NodeForge 运行时安装路径自举。
//!
//! M4.7 起业务代码不再从编译期字符串拼出 `/opt/nodeforge/**`。进程必须先从
//! 显式 `--install-root` 或真实可执行文件位置证明安装根有效，再发布一次只读
//! `Paths`。marker、成对二进制或 `bin/` 布局不成立时一律 fail closed。

const std = @import("std");

/// 默认安装根路径。标准部署使用此路径，自定义安装根通过 `--install-root` 覆盖。
pub const default_install_root = "/opt/nodeforge";

/// 根目录标记文件名。`setup` 在安装根创建此文件，`Paths.resolve` 验证其存在。
/// 防止误将任意目录当作 NodeForge 安装根。
pub const root_marker_name = ".nodeforge-root";

/// 一个进程内不可变的完整路径投影。全部字符串由调用 `resolve`/`discover` 时的
/// allocator 持有，通常使用进程 arena；测试可显式 `deinit`。
pub const Paths = struct {
    /// 安装根目录的 canonical 绝对路径（已解析 symlink）。
    install_root: []const u8,
    /// 根目录标记文件完整路径（`<root>/.nodeforge-root`）。
    marker_path: []const u8,
    /// v0.4 DeploymentManifest v1；daemon 在加载任何 state 前校验它。
    deployment_manifest_path: []const u8,
    /// fresh replacement 正在 purge/发布时的 fail-closed 标记。
    deployment_replacement_incomplete_path: []const u8,
    /// 二进制目录（`<root>/bin`），存放 `nodeforge` 和 `nodeforged`。
    bin_dir: []const u8,
    /// CLI 二进制完整路径（`<root>/bin/nodeforge`）。
    nodeforge_path: []const u8,
    /// daemon 二进制完整路径（`<root>/bin/nodeforged`）。
    nodeforged_path: []const u8,
    /// systemd unit 文件目录（`<root>/systemd`）。
    systemd_dir: []const u8,
    /// 配置文件目录（`<root>/config`），存放 `config.json`。
    config_dir: []const u8,
    /// Catalog 目录（`<root>/catalog`），存放 manifest 和 entity 文件。
    catalog_dir: []const u8,
    /// 运行态目录（`<root>/state`），存放 lease/status/session 等持久状态。
    state_dir: []const u8,
    /// 日志目录（`<root>/logs`），存放服务日志和事件审计流。
    logs_dir: []const u8,
    /// 资产根目录（`<root>/assets`），存放 ISO/boot/repos/keys 等子目录。
    assets_dir: []const u8,
    /// ISO 镜像目录（`<root>/assets/iso`）。
    iso_dir: []const u8,
    /// TFTP 启动文件目录（`<root>/assets/boot`），存放 GRUB/kernel/initrd。
    boot_dir: []const u8,
    /// 仓库目录（`<root>/assets/repos`），通过 HTTP 只读发布。
    repos_dir: []const u8,
    /// Repository 软件能力索引内容寻址目录。完整 index 按 SHA-256 只保存一次，
    /// InstallPlan 只持有引用，避免同 profile 多节点重复快照。
    repository_indexes_dir: []const u8,
    /// SSH 密钥目录（`<root>/assets/keys`），存放 bootstrap 和操作员密钥。
    keys_dir: []const u8,
    /// Bootstrap SSH 私钥路径（`<root>/assets/keys/id_ed25519`）。
    /// 仅 daemon 可读，用于安装后首次访问目标节点。
    bootstrap_private_key_path: []const u8,
    /// Bootstrap SSH 公钥路径（`<root>/assets/keys/id_ed25519.pub`）。
    /// 注入到所有目标节点的 authorized_keys。
    bootstrap_public_key_path: []const u8,
    /// 私钥临时写入路径，用于原子替换（写完后 rename 到正式路径）。
    bootstrap_private_key_temp_path: []const u8,
    /// 公钥临时写入路径，用于原子替换。
    bootstrap_public_key_temp_path: []const u8,
    /// Diskless initrd 唯一受管根（`<root>/assets/diskless/initrd`）。
    /// 开发版本不扫描或迁移旧 `assets/boot/diskless`。
    initrd_dir: []const u8,
    /// Diskless rootfs 唯一受管根（`<root>/assets/diskless/rootfs`）。
    /// 开发版本不扫描或迁移旧 `assets/rootfs`。
    rootfs_dir: []const u8,
    /// boot bundle 目录（`<root>/assets/bundles`），v0.2 无盘启动用。
    bundles_dir: []const u8,
    /// 后处理结果目录（`<root>/state/provisioned`），存放 provision 产物。
    provisioned_dir: []const u8,
    /// 运行时 PID/socket 目录（`<root>/run`）。
    run_dir: []const u8,
    /// 临时工作目录（`<root>/work`），ISO 导入暂存和中断工作树。
    /// `--purge-all` 会删除此目录。
    work_dir: []const u8,
    /// ISO 导入暂存子目录（`<root>/work/import`）。
    import_dir: []const u8,
    /// v0.4 可选保留的 rootfs 构建解包树根（`<root>/work/rootfs-staging/<digest>/`）。
    /// 仅 `profile rootfs build --keep-staging` 时写入；供 chroot 特需与 `--from-staging` 再打包。
    rootfs_staging_dir: []const u8,
    /// 启动配置文件路径（`<root>/config/config.json`）。
    config_path: []const u8,
    /// DHCP lease 持久化文件路径（`<root>/state/leases.json`）。
    leases_path: []const u8,
    /// 节点状态持久化文件路径（`<root>/state/node-status.json`）。
    node_status_path: []const u8,
    /// 部署控制文件路径（`<root>/state/deployment-control.json`）。
    /// 记录 install generation/consumed/config revision。
    deployment_control_path: []const u8,
    /// Boot session 持久化文件路径（`<root>/state/boot-sessions.json`）。
    /// 记录活动安装会话的 immutable plan 和 checkpoint。
    boot_sessions_path: []const u8,
    /// 节点 inventory 文件路径（`<root>/state/node-inventory.json`）。
    /// 记录安装器上报的硬件事实（serial/UUID/vendor/model）。
    node_inventory_path: []const u8,
    /// v0.4 per-node SN discovery lifecycle state.
    node_discovery_path: []const u8,
    /// 操作记录文件路径（`<root>/state/operations.json`）。
    /// 记录管理 API 的持久操作（幂等 key + 状态轮询）。
    operations_path: []const u8,
    /// nodeforged 已发布 ready rootfs 索引路径（`<root>/state/rootfs-artifacts.json`）。
    /// 记录已构建 diskless rootfs 的内容寻址制品（digest/sha512/size）。
    rootfs_artifacts_path: []const u8,
    /// v0.4 rootfs 保留树索引（`<root>/state/rootfs-stagings.json`）。
    /// 记录 digest→绝对路径/kept_at 等元数据，与 squashfs 制品索引分离。
    rootfs_stagings_path: []const u8,
    /// Diskless delivery session checkpoint。只保存 capability hash/claim，
    /// 不保存可直接使用的 raw token。
    diskless_delivery_path: []const u8,
    /// Daemon 主密钥（0600，32-byte hex）：只用于 diskless event、first-boot
    /// 和 discovery 等 durable token 的确定性派生。随机 boot-session capability
    /// 不依赖此密钥。文件名保留 `state/diskless-secret`，但 v0.4 fresh layout
    /// 不读取或迁移旧 deployment state。
    daemon_secret_path: []const u8,
    /// v0.2.3: SSH identity store 文件路径（`<root>/state/identities.json`）。
    /// 存储 Profile SSH 密钥对，private key 不进入 catalog。
    identity_store_path: []const u8,
    /// v0.3: install-post journal 文件路径（`<root>/state/install-post-journal.json`）。
    /// 记录 install-post 步骤执行状态、attempt 计数和 run 状态机。
    install_post_journal_path: []const u8,
    install_first_boot_path: []const u8,
    /// v0.2.3: SSH identity 密钥生成/校验暂存目录（`<root>/state/identity-staging`，
    /// 0700）。私钥只在暂存目录中出现，绝不进入 `/tmp` 或工作目录。
    identity_staging_dir: []const u8,
    /// v0.2.3: SSH identity 两阶段事务 journal 目录（`<root>/state/identity-transactions`，
    /// 0700）。create/clone `--new-ssh-keys` 的 prepared journal 存放于此，
    /// daemon 启动时在 serve 前按 §4.2 恢复。
    identity_transactions_dir: []const u8,
    /// 模型事务目录（`<root>/state/model-transactions`）。
    /// 存放 catalog mutation 等大事务的 before/after 快照。
    model_transactions_dir: []const u8,
    /// 事件审计流文件路径（`<root>/logs/events.jsonl`）。追加型 JSONL。
    events_path: []const u8,
    /// 服务日志文件路径（`<root>/logs/nodeforged.log`）。追加型文本日志。
    service_log_path: []const u8,
    /// systemd unit 文件路径（`<root>/systemd/nodeforged.service`）。
    service_path: []const u8,

    /// 从现存根目录解析路径并验证 marker 与成对二进制。
    ///
    /// `realPathFileAlloc` 同时消除 `..` 和 symlink；解析结果必须与调用方文本路径
    /// 不同也无妨，但后续所有写入只使用 canonical root。
    ///
    /// # 错误
    /// - `InstallRootNotAbsolute`：根路径不是绝对路径。
    /// - `InvalidInstallRoot`：根路径包含 `..` 组件。
    /// - `InstallRootSymlink`：根路径本身是 symlink。
    /// - `FileNotFound`：根目录或 marker 文件不存在。
    /// - `InvalidExecutableLayout`：marker 存在但成对二进制缺失。
    pub fn resolve(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !Paths {
        if (!std.fs.path.isAbsolute(root)) return error.InstallRootNotAbsolute;
        if (hasDotDot(root)) return error.InvalidInstallRoot;
        const input_stat = try std.Io.Dir.cwd().statFile(io, root, .{ .follow_symlinks = false });
        if (input_stat.kind == .sym_link) return error.InstallRootSymlink;
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);
        defer allocator.free(canonical);
        var result = try derive(allocator, canonical);
        errdefer result.deinit(allocator);
        try result.validateLayout(io);
        return result;
    }

    /// 从操作系统提供的真实 executable 位置发现根，不信任 argv[0] 或 PATH。
    ///
    /// `realPathFileAlloc` 会继续解析软链后的真实位置。
    /// 只有标准根会作为兜底候选，且同样必须通过完整布局校验。
    /// 用于 daemon 启动时自动定位安装根（无需 `--install-root`）。
    pub fn discover(io: std.Io, allocator: std.mem.Allocator) !Paths {
        const reported = std.process.executablePathAlloc(io, allocator) catch |cause| {
            return resolve(io, allocator, default_install_root) catch return cause;
        };
        defer allocator.free(reported);
        const executable = std.Io.Dir.cwd().realPathFileAlloc(io, reported, allocator) catch |cause| {
            return resolve(io, allocator, default_install_root) catch return cause;
        };
        defer allocator.free(executable);
        const bin = std.fs.path.dirname(executable) orelse return error.InvalidExecutableLayout;
        if (!std.mem.eql(u8, std.fs.path.basename(bin), "bin")) {
            return resolve(io, allocator, default_install_root) catch return error.InvalidExecutableLayout;
        }
        const root = std.fs.path.dirname(bin) orelse return error.InvalidExecutableLayout;
        return resolve(io, allocator, root) catch |cause| {
            if (std.mem.eql(u8, root, default_install_root)) return cause;
            return resolve(io, allocator, default_install_root) catch return cause;
        };
    }

    /// setup 在创建 marker 前需要一个只派生、不声称部署有效的候选路径。
    ///
    /// 该入口仍要求绝对、canonical、已存在且为目录；它不写盘。
    /// 用于 `setup --install-root <new-root>` 场景，此时 marker 尚未创建。
    pub fn candidate(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !Paths {
        if (!std.fs.path.isAbsolute(root)) return error.InstallRootNotAbsolute;
        if (hasDotDot(root)) return error.InvalidInstallRoot;
        if (std.Io.Dir.cwd().statFile(io, root, .{ .follow_symlinks = false })) |stat| {
            if (stat.kind == .sym_link) return error.InstallRootSymlink;
        } else |err| if (err != error.FileNotFound) return err;
        const canonical: [:0]u8 = std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator) catch |err| switch (err) {
            error.FileNotFound => blk: {
                const parent = std.fs.path.dirname(root) orelse return error.InvalidInstallRoot;
                const base = std.fs.path.basename(root);
                if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return error.InvalidInstallRoot;
                const canonical_parent = try std.Io.Dir.cwd().realPathFileAlloc(io, parent, allocator);
                defer allocator.free(canonical_parent);
                const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ canonical_parent, base });
                defer allocator.free(joined);
                break :blk try allocator.dupeZ(u8, joined);
            },
            else => return err,
        };
        defer allocator.free(canonical);
        return derive(allocator, canonical);
    }

    /// 释放所有路径字符串内存。测试使用；生产进程使用 arena allocator，不调用此函数。
    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        inline for (std.meta.fields(Paths)) |field| allocator.free(@field(self, field.name));
        self.* = undefined;
    }

    /// 验证安装根布局：marker 文件可读、成对二进制存在且为常规文件。
    /// 任何一项不满足都返回错误，确保进程不会在残缺安装根上启动特权服务。
    fn validateLayout(self: *const Paths, io: std.Io) !void {
        const cwd = std.Io.Dir.cwd();
        var marker = try cwd.openFile(io, self.marker_path, .{ .mode = .read_only });
        marker.close(io);
        inline for (.{ self.nodeforge_path, self.nodeforged_path }) |binary_path| {
            var binary = try cwd.openFile(io, binary_path, .{ .mode = .read_only });
            defer binary.close(io);
            const stat = try binary.stat(io);
            if (stat.kind != .file) return error.InvalidExecutableLayout;
        }
    }
};

/// 全局路径单例。进程内只初始化一次，之后只读访问。
var global: ?Paths = null;

/// 发布全局路径只能发生一次，防止命令解析后再切换写入边界。
///
/// 返回 `AlreadyInitialized` 表示路径已发布，不允许二次初始化。
pub fn init(value: Paths) error{AlreadyInitialized}!void {
    if (global != null) return error.AlreadyInitialized;
    global = value;
}

/// 业务代码不得在缺少自举时偷偷回落到 `/opt/nodeforge`。
pub fn current() error{PathsNotInitialized}!*const Paths {
    return if (global) |*value| value else error.PathsNotInitialized;
}

/// 已经完成入口自举的业务代码使用该入口。若调用顺序被破坏会立即终止，
/// 而不是把空路径或默认路径继续传进特权文件操作；可恢复的初始化流程和测试
/// 使用 `current()` 获取显式错误。
pub fn require() *const Paths {
    return current() catch @panic("NodeForge paths used before bootstrap");
}

/// 在构造任何 CLI 默认值之前扫描唯一的 bootstrap flag 并发布路径。
///
/// 这里只识别 `--install-root VALUE`/`--install-root=VALUE`；其余语法仍由
/// zli 负责，因此预扫描不会改变业务参数的校验或所有权。
///
/// `setup` 子命令使用 `candidate`（允许 marker 不存在），其他子命令使用 `resolve`（要求 marker 存在）。
pub fn bootstrap(io: std.Io, allocator: std.mem.Allocator, args: std.process.Args) !void {
    var iterator = args.iterate();
    _ = iterator.next();
    var explicit: ?[]const u8 = null;
    var setup = false;
    while (iterator.next()) |arg| {
        if (std.mem.eql(u8, arg, "setup")) setup = true;
        if (std.mem.eql(u8, arg, "--install-root")) {
            explicit = iterator.next() orelse return error.MissingInstallRootValue;
        } else if (std.mem.startsWith(u8, arg, "--install-root=")) {
            explicit = arg["--install-root=".len..];
            if (explicit.?.len == 0) return error.MissingInstallRootValue;
        }
    }
    // `setup` 无显式 --install-root 时优先尝试 discover（从可执行文件位置发现
    // 已安装根）。若 discover 失败（如新解压的发布包不在 bin/ 布局中），回落
    // 到 candidate(default_install_root) 让 setup 进入交互式安装流程。
    if (setup and explicit == null) {
        const value = Paths.discover(io, allocator) catch
            try Paths.candidate(io, allocator, default_install_root);
        try init(value);
        return;
    }
    const value = if (explicit) |root|
        if (setup) try Paths.candidate(io, allocator, root) else try Paths.resolve(io, allocator, root)
    else
        try Paths.discover(io, allocator);
    try init(value);
}

/// 从 canonical root 派生所有子路径。每条路径由 allocator 独立持有。
fn derive(allocator: std.mem.Allocator, root: []const u8) !Paths {
    return .{
        .install_root = try allocator.dupe(u8, root),
        .marker_path = try join(allocator, root, root_marker_name),
        .deployment_manifest_path = try join(allocator, root, "deployment.json"),
        .deployment_replacement_incomplete_path = try join(allocator, root, ".nodeforge-replacement-incomplete"),
        .bin_dir = try join(allocator, root, "bin"),
        .nodeforge_path = try join(allocator, root, "bin/nodeforge"),
        .nodeforged_path = try join(allocator, root, "bin/nodeforged"),
        .systemd_dir = try join(allocator, root, "systemd"),
        .config_dir = try join(allocator, root, "config"),
        .catalog_dir = try join(allocator, root, "catalog"),
        .state_dir = try join(allocator, root, "state"),
        .logs_dir = try join(allocator, root, "logs"),
        .assets_dir = try join(allocator, root, "assets"),
        .iso_dir = try join(allocator, root, "assets/iso"),
        .boot_dir = try join(allocator, root, "assets/boot"),
        .repos_dir = try join(allocator, root, "assets/repos"),
        .repository_indexes_dir = try join(allocator, root, "assets/repository-indexes"),
        .keys_dir = try join(allocator, root, "assets/keys"),
        .bootstrap_private_key_path = try join(allocator, root, "assets/keys/id_ed25519"),
        .bootstrap_public_key_path = try join(allocator, root, "assets/keys/id_ed25519.pub"),
        .bootstrap_private_key_temp_path = try join(allocator, root, "assets/keys/id_ed25519.tmp"),
        .bootstrap_public_key_temp_path = try join(allocator, root, "assets/keys/id_ed25519.tmp.pub"),
        .initrd_dir = try join(allocator, root, "assets/diskless/initrd"),
        .rootfs_dir = try join(allocator, root, "assets/diskless/rootfs"),
        .bundles_dir = try join(allocator, root, "assets/bundles"),
        .provisioned_dir = try join(allocator, root, "state/provisioned"),
        .run_dir = try join(allocator, root, "run"),
        .work_dir = try join(allocator, root, "work"),
        .import_dir = try join(allocator, root, "work/import"),
        .rootfs_staging_dir = try join(allocator, root, "work/rootfs-staging"),
        .config_path = try join(allocator, root, "config/config.json"),
        .leases_path = try join(allocator, root, "state/leases.json"),
        .node_status_path = try join(allocator, root, "state/node-status.json"),
        .deployment_control_path = try join(allocator, root, "state/deployment-control.json"),
        .boot_sessions_path = try join(allocator, root, "state/boot-sessions.json"),
        .node_inventory_path = try join(allocator, root, "state/node-inventory.json"),
        .node_discovery_path = try join(allocator, root, "state/node-discovery.json"),
        .operations_path = try join(allocator, root, "state/operations.json"),
        .rootfs_artifacts_path = try join(allocator, root, "state/rootfs-artifacts.json"),
        .rootfs_stagings_path = try join(allocator, root, "state/rootfs-stagings.json"),
        .diskless_delivery_path = try join(allocator, root, "state/diskless-delivery.json"),
        .daemon_secret_path = try join(allocator, root, "state/diskless-secret"),
        .identity_store_path = try join(allocator, root, "state/identities.json"),
        .install_post_journal_path = try join(allocator, root, "state/install-post-journal.json"),
        .install_first_boot_path = try join(allocator, root, "state/install-first-boot.json"),
        .identity_staging_dir = try join(allocator, root, "state/identity-staging"),
        .identity_transactions_dir = try join(allocator, root, "state/identity-transactions"),
        .model_transactions_dir = try join(allocator, root, "state/model-transactions"),
        .events_path = try join(allocator, root, "logs/events.jsonl"),
        .service_log_path = try join(allocator, root, "logs/nodeforged.log"),
        .service_path = try join(allocator, root, "systemd/nodeforged.service"),
    };
}

/// 使用 `std.fmt.allocPrint` 拼接 `root/suffix` 路径。
fn join(allocator: std.mem.Allocator, root: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, suffix });
}

/// 检查路径中是否包含 `..` 组件，防止路径逃逸。
fn hasDotDot(value: []const u8) bool {
    var parts = std.mem.splitScalar(u8, value, std.fs.path.sep);
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return true;
    return false;
}

fn createTestLayout(io: std.Io, root: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, root);
    const bin = try std.fmt.allocPrint(std.testing.allocator, "{s}/bin", .{root});
    defer std.testing.allocator.free(bin);
    try cwd.createDirPath(io, bin);
    inline for (.{ root_marker_name, "bin/nodeforge", "bin/nodeforged" }) |suffix| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root, suffix });
        defer std.testing.allocator.free(path);
        var file = try cwd.createFile(io, path, .{ .truncate = true });
        file.close(io);
    }
}

test "runtime paths resolve a custom marked install root" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    try createTestLayout(std.testing.io, root);

    var value = try Paths.resolve(std.testing.io, std.testing.allocator, root);
    defer value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(root, value.install_root);
    try std.testing.expectEqualStrings("config/config.json", value.config_path[root.len + 1 ..]);
}

test "runtime paths fail closed without marker or paired binaries" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    try std.testing.expectError(error.FileNotFound, Paths.resolve(std.testing.io, std.testing.allocator, root));
}

test "runtime paths reject relative roots and duplicate init" {
    try std.testing.expectError(error.InstallRootNotAbsolute, Paths.resolve(std.testing.io, std.testing.allocator, "../nodeforge"));
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temp.dir.realPath(std.testing.io, &root_buffer);
    const first = try Paths.candidate(std.testing.io, std.heap.page_allocator, root_buffer[0..root_len]);
    try init(first);
    try std.testing.expectError(error.AlreadyInitialized, init(first));
}

test "runtime paths reject dot-dot and a symlink root" {
    try std.testing.expectError(error.InvalidInstallRoot, Paths.candidate(std.testing.io, std.testing.allocator, "/tmp/../tmp/nodeforge"));
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDir(std.testing.io, "real", .default_dir);
    try temp.dir.symLink(std.testing.io, "real", "link", .{});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temp.dir.realPath(std.testing.io, &buffer);
    const link = try std.fmt.allocPrint(std.testing.allocator, "{s}/link", .{buffer[0..root_len]});
    defer std.testing.allocator.free(link);
    try std.testing.expectError(error.InstallRootSymlink, Paths.candidate(std.testing.io, std.testing.allocator, link));
}
