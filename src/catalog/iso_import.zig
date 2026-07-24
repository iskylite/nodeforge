//! Linux 安装介质导入器（M3 基线，M4.9 fresh bootloader 自举）。
//!
//! 导入器有意使用内核的只读 loop mount 而非 ISO 解析器或第三方提取工具。
//! 它从不暴露 mount：所有发布的文件在 catalog 快照被原子替换之前都已复制到
//! NodeForge 管控的目录中。
//!
//! 现行完整责任链：
//! `CLI fstat -> 原子暂存拷贝 -> daemon 受限 open/hash ->
//! 只读 loop mount -> family/layout 校验 + tuple 探测/可选覆盖 ->
//! bootloader/kernel/initrd/repo 暂存 -> checksums -> catalog 候选校验 +
//! 原子替换 -> 暂存清理`
//!
//! catalog 是对 HTTP/TFTP 可见性的唯一提交点；任何未发布文件都不能经 resolver 访问。
//! 导入不会实现后台 job：CLI 等待本地 daemon 的有界 worker 结果。

const std = @import("std");
const model = @import("../model.zig");
const paths = @import("../paths.zig");
const assets = @import("../assets/validate.zig");
const observe_log = @import("../observe/log.zig");
const dhcp_store = @import("../state/dhcp_store.zig");
const software_index = @import("software_index.zig");

/// 导入请求。filename 是 CLI 已暂存到 import_dir 的不透明文件名。
/// distro/version/arch 是可选覆盖。family 始终由经过结构校验的 ISO 布局决定；
/// 已知产品从媒体标签映射，未知产品只有提供 `distro` 时才继续。
pub const Request = struct {
    filename: []const u8,
    name: ?[]const u8 = null,
    /// 可选的产品覆盖。family 始终由 ISO 布局决定；提供的值直接采用，
    /// 不与媒体元数据比对，用于已知布局但标签未知或元数据不完整的介质。
    distro: ?[]const u8 = null,
    version: ?[]const u8 = null,
    arch: ?model.Arch = null,
};

/// 导入结果。包含所有需要发布到 catalog 的对象：
/// - ISO asset（通过 HTTP /artifacts/images/ 下载）
/// - 可选的 UEFI GRUB bootloader asset（通过 TFTP 提供）
/// - installer kernel/initrd assets（通过 TFTP 提供）
/// - 可选的 repository（通过 HTTP /artifacts/repositories/ 提供）
/// - install source（关联 ISO/kernel/initrd/repo 的 catalog 对象）
/// 调用方负责将这些对象原子发布到 catalog 快照。
pub const Result = struct {
    source_name: []const u8,
    /// family 由 ISO 的 Anaconda/.treeinfo 或 Subiquity/casper 布局确定。
    family: model.DistroFamily,
    /// M4.2 F3：面向操作员的可选 install source 标签。
    source_label: ?[]const u8 = null,
    iso_asset: model.AssetConfig,
    bootloader_asset: ?model.AssetConfig = null,
    /// catalog 发布失败时，仅删除本次导入创建的共享 bootloader。
    bootloader_created: bool = false,
    kernel_asset: model.AssetConfig,
    initrd_asset: model.AssetConfig,
    repository: ?model.RepositoryConfig,
    install_source: model.InstallSourceConfig,
};

/// 导入一个已支持布局的 Anaconda/RHEL-family 或 Ubuntu Server ISO。
///
/// 完整流程：
/// 1. 校验 filename 安全性（无路径分隔符、无 `..`、无 null 字节）
/// 2. 在受管 import_dir 内计算 ISO SHA-256（验证文件是普通非符号链接文件）
/// 3. 创建随机 tag 的临时工作目录（mount point + staged repo）
/// 4. 只读 loop mount ISO（先尝试 iso9660，失败再尝试 udf）
/// 5. 从媒体布局确定 family，并从元数据检测 distro/version/arch；未知产品标签可由请求覆盖
/// 6. 将 mount 内容复制到 staged repo
/// 7. 卸载 ISO
/// 8. 将 bootloader/kernel/initrd/ISO/repo 复制到各自的受管目标目录
///    （共享 bootloader 已存在时复用，其余对象 NoClobber 防止覆盖）
/// 9. 计算所有已发布文件的 SHA-256
/// 10. 构造 catalog 对象（assets/install_source/repository）
///
/// 调用方拥有返回字符串的 allocator 生命周期，并负责 catalog 发布。
/// 临时工作目录在函数返回时通过 defer 清理（deleteTree）。
pub fn importMedia(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, request: Request) !Result {
    if (!safeFilename(request.filename)) return error.UnsafeImportFilename;

    // `sha256File` 在受管根下以 NOFOLLOW+RESOLVE_BENEATH 方式打开文件，
    // 验证暂存输入是普通非符号链接文件。同时计算 SHA-256 用于 catalog 发布。
    var input_hash: [64]u8 = undefined;
    try assets.sha256File(io, paths.require().import_dir, request.filename, &input_hash);
    const input = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ paths.require().import_dir, request.filename });
    defer allocator.free(input);

    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    const work = try std.fmt.allocPrint(allocator, "{s}/iso-import-{s}", .{ paths.require().work_dir, tag[0..] });
    defer allocator.free(work);
    const mount_point = try std.fmt.allocPrint(allocator, "{s}/mnt", .{work});
    defer allocator.free(mount_point);
    const staged_repo = try std.fmt.allocPrint(allocator, "{s}/repo", .{work});
    defer allocator.free(staged_repo);
    try std.Io.Dir.cwd().createDirPath(io, mount_point);
    try std.Io.Dir.cwd().createDirPath(io, staged_repo);
    // DVD 目录树以 `cp -a` 暂存时保留只读目录权限。
    // 优先使用原生删除，但回退到与其他位置相同的受限 `rm` 命令，
    // 确保成功的导入不会仅因复制的目录为只读而保留数 GB 的工作树。
    defer removeTreeBestEffort(io, allocator, work);

    // ISO9660 是首选文件系统。某些介质是 UDF-only（部分新版 Ubuntu），
    // 因此失败后重试一次 UDF。两次尝试都是私有的、只读的，
    // 永远不执行介质内容（只读取文件系统元数据和文件数据）。
    mountIso(io, allocator, input, mount_point, "iso9660") catch try mountIso(io, allocator, input, mount_point, "udf");
    var mounted = true;
    defer if (mounted) unmountIso(io, allocator, mount_point) catch |err|
        observe_log.warn("iso import: cleanup unmount failed for {s}: {t}", .{ mount_point, err });

    const detected = try detectMedia(io, allocator, mount_point, request);
    const media = detected.layout;
    try copyTree(io, allocator, mount_point, staged_repo);
    try unmountIso(io, allocator, mount_point);
    mounted = false;

    const source_name = if (request.name) |name|
        try allocator.dupe(u8, name)
    else blk: {
        const version_slug = try logicalComponent(allocator, detected.version);
        defer allocator.free(version_slug);
        break :blk try std.fmt.allocPrint(allocator, "{s}-{s}-{s}-iso", .{ detected.distro, version_slug, @tagName(detected.arch) });
    };
    const iso_rel = try allocator.dupe(u8, request.filename);
    const kernel_rel = try std.fmt.allocPrint(allocator, "install/{s}/vmlinuz", .{source_name});
    const initrd_rel = try std.fmt.allocPrint(allocator, "install/{s}/initrd.img", .{source_name});
    const bootloader_rel = canonicalBootloaderPath(detected.arch);
    const bootloader_media_rel = findBootloaderMediaPath(io, staged_repo, detected.arch);
    const iso_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.asset_root, iso_rel });
    defer allocator.free(iso_destination);
    const bootloader_destination = if (bootloader_media_rel != null)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tftp.asset_root, bootloader_rel })
    else
        null;
    defer if (bootloader_destination) |path| allocator.free(path);
    const kernel_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tftp.asset_root, kernel_rel });
    defer allocator.free(kernel_destination);
    const initrd_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tftp.asset_root, initrd_rel });
    defer allocator.free(initrd_destination);
    const repo_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.repository_root, source_name });
    defer allocator.free(repo_destination);

    // 发布是由调用方执行的独立原子 catalog 操作。
    // 如果下方的任何拷贝或校验和步骤在 Result 交给调用方之前失败，
    // 不要在公共 asset root 中遗留文件。
    //（catalog 发布失败由 cleanupPublishedOutputs 清理。）
    var retain_outputs = false;
    // 清理必须感知所有权。被拒绝的重复导入可能发现已存在有效且已发布的
    // kernel/repository（具有确定性 source name）。回滚此候选时绝不能
    // 删除先前存在的 generation，只删除本次调用在 no-clobber 检查通过后
    // 创建（或开始创建）的路径。
    var iso_created = false;
    var bootloader_created = false;
    var kernel_created = false;
    var initrd_created = false;
    var repository_created = false;
    defer if (!retain_outputs) removeCreatedOutputPaths(io, allocator, iso_destination, kernel_destination, initrd_destination, repo_destination, iso_created, kernel_created, initrd_created, repository_created);
    defer if (!retain_outputs and bootloader_created)
        std.Io.Dir.cwd().deleteFile(io, bootloader_destination.?) catch {};

    const mounted_kernel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, media.kernel_path });
    defer allocator.free(mounted_kernel);
    const mounted_initrd = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, media.initrd_path });
    defer allocator.free(mounted_initrd);
    const mounted_bootloader = if (bootloader_media_rel) |path|
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, path })
    else
        null;
    defer if (mounted_bootloader) |path| allocator.free(path);
    try copyFileNoClobber(io, allocator, input, iso_destination, &iso_created);
    if (mounted_bootloader) |source|
        try copyFileIfMissing(io, allocator, source, bootloader_destination.?, &bootloader_created);
    try copyFileNoClobber(io, allocator, mounted_kernel, kernel_destination, &kernel_created);
    try copyFileNoClobber(io, allocator, mounted_initrd, initrd_destination, &initrd_created);
    // 媒体树始终发布；是否同时暴露为 package repository 由 metadata 完整性决定。
    try copyTreeNoClobber(io, allocator, staged_repo, repo_destination, &repository_created);

    var iso_hash: [64]u8 = undefined;
    var bootloader_hash: [64]u8 = undefined;
    var kernel_hash: [64]u8 = undefined;
    var initrd_hash: [64]u8 = undefined;
    try assets.sha256File(io, config.http.asset_root, iso_rel, &iso_hash);
    if (bootloader_media_rel != null)
        try assets.sha256File(io, config.tftp.asset_root, bootloader_rel, &bootloader_hash);
    try assets.sha256File(io, config.tftp.asset_root, kernel_rel, &kernel_hash);
    try assets.sha256File(io, config.tftp.asset_root, initrd_rel, &initrd_hash);

    const repository_index: model.SoftwareIndex = if (media.repository_base) |base| blk: {
        const index_root = if (base.len == 0)
            try allocator.dupe(u8, repo_destination)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_destination, base });
        defer allocator.free(index_root);
        break :blk try software_index.build(io, allocator, index_root, model.packageManagerForFamily(detected.family));
    } else .{};

    const repository_names = if (media.repository_base != null) blk: {
        const names = try allocator.alloc([]const u8, 1);
        names[0] = source_name;
        break :blk names;
    } else &.{};
    const distro_name = try allocator.dupe(u8, detected.distro);
    const distro_version = try allocator.dupe(u8, detected.version);
    const media_tree_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/artifacts/repositories/{s}", .{ config.server.server_ip, config.server.http_port, source_name });
    const result: Result = .{
        .source_name = source_name,
        .family = detected.family,
        .source_label = detected.source_label,
        .iso_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-image", .{source_name}), .kind = .iso, .path = iso_rel, .distro = distro_name, .version = distro_version, .arch = detected.arch, .sha256 = try allocator.dupe(u8, &iso_hash) },
        .bootloader_asset = if (bootloader_media_rel != null) .{
            .name = canonicalBootloaderName(detected.arch),
            .kind = .bootloader,
            .path = bootloader_rel,
            .sha256 = try allocator.dupe(u8, &bootloader_hash),
        } else null,
        .bootloader_created = bootloader_created,
        .kernel_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-installer-kernel", .{source_name}), .kind = .kernel, .path = kernel_rel, .distro = distro_name, .version = distro_version, .arch = detected.arch, .sha256 = try allocator.dupe(u8, &kernel_hash) },
        .initrd_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-installer-initrd", .{source_name}), .kind = .installer_initrd, .path = initrd_rel, .distro = distro_name, .version = distro_version, .arch = detected.arch, .sha256 = try allocator.dupe(u8, &initrd_hash) },
        .repository = if (media.repository_base) |base| .{ .name = source_name, .distro = distro_name, .version = distro_version, .arch = detected.arch, .manager = model.packageManagerForFamily(detected.family), .base_url = if (base.len == 0) try allocator.dupe(u8, media_tree_url) else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ media_tree_url, base }), .software_index = repository_index } else null,
        .install_source = .{ .name = source_name, .source_label = detected.source_label, .distro = distro_name, .version = distro_version, .arch = detected.arch, .source_asset = try std.fmt.allocPrint(allocator, "{s}-image", .{source_name}), .installer_kernel = try std.fmt.allocPrint(allocator, "{s}-installer-kernel", .{source_name}), .installer_initrd = try std.fmt.allocPrint(allocator, "{s}-installer-initrd", .{source_name}), .media_tree_url = media_tree_url, .repositories = repository_names },
    };
    retain_outputs = true;
    return result;
}

/// 在 catalog 候选校验或原子发布失败后移除未发布的输出。这些路径由
/// 本模块创建的 Result 派生，绝非来自 HTTP 请求；清理是尽力而为的，
/// 不能掩盖原始导入失败。
pub fn cleanupPublishedOutputs(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, result: *const Result) void {
    const iso = std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.asset_root, result.iso_asset.path }) catch return;
    defer allocator.free(iso);
    const kernel = std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tftp.asset_root, result.kernel_asset.path }) catch return;
    defer allocator.free(kernel);
    const initrd = std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tftp.asset_root, result.initrd_asset.path }) catch return;
    defer allocator.free(initrd);
    const repository = std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.repository_root, result.source_name }) catch return;
    defer allocator.free(repository);
    removeOutputPaths(io, allocator, iso, kernel, initrd, repository, true);
    if (result.bootloader_created) if (result.bootloader_asset) |bootloader| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tftp.asset_root, bootloader.path }) catch return;
        defer allocator.free(path);
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
    };
}

fn removeOutputPaths(io: std.Io, allocator: std.mem.Allocator, iso: []const u8, kernel: []const u8, initrd: []const u8, repository: []const u8, has_repository: bool) void {
    std.Io.Dir.cwd().deleteFile(io, iso) catch {};
    std.Io.Dir.cwd().deleteFile(io, kernel) catch {};
    std.Io.Dir.cwd().deleteFile(io, initrd) catch {};
    if (has_repository) removeTreeBestEffort(io, allocator, repository);
}

fn removeCreatedOutputPaths(io: std.Io, allocator: std.mem.Allocator, iso: []const u8, kernel: []const u8, initrd: []const u8, repository: []const u8, iso_created: bool, kernel_created: bool, initrd_created: bool, repository_created: bool) void {
    if (iso_created) std.Io.Dir.cwd().deleteFile(io, iso) catch {};
    if (kernel_created) std.Io.Dir.cwd().deleteFile(io, kernel) catch {};
    if (initrd_created) std.Io.Dir.cwd().deleteFile(io, initrd) catch {};
    if (repository_created) removeTreeBestEffort(io, allocator, repository);
}

fn removeTreeBestEffort(io: std.Io, allocator: std.mem.Allocator, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch run(io, allocator, &.{ "rm", "-rf", "--", path }) catch {};
}

/// 媒体布局描述。描述 installer kernel/initrd 在挂载的 ISO 中的相对路径，
/// 以及 repository 的基础路径（null 表示仅安装器介质，空字符串表示 repo 根）。
const MediaLayout = struct {
    kernel_path: []const u8,
    initrd_path: []const u8,
    /// `null` 表示仅安装器介质（无 repository）；空字符串表示 repository 根。
    repository_base: ?[]const u8,
};

/// 检测到的媒体信息。包含从 ISO 元数据提取的 distro/version/arch 和媒体布局。
const DetectedMedia = struct {
    family: model.DistroFamily,
    distro: []const u8,
    version: []const u8,
    arch: model.Arch,
    source_label: ?[]const u8 = null,
    layout: MediaLayout,
};

/// 从挂载的 ISO 检测 family/distro/version/arch 和媒体布局。
///
/// 检测顺序：先尝试 Anaconda `.treeinfo`（结构化元数据更强），
/// 没有 `.treeinfo` 时回退到 Ubuntu live-server 的 `.disk/info`/casper 布局。
/// CLI tuple 是元数据覆盖，不能覆盖由已验证媒体布局确定的 family。
fn detectMedia(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8, requested: Request) !DetectedMedia {
    // Anaconda 的 `.treeinfo` 是明确的结构化元数据，比文件名有更强的识别保证。
    // 只有不存在 `.treeinfo` 时才回退到 Ubuntu live-server 标记文件。
    var detected: DetectedMedia = undefined;
    if (detectRhelMedia(io, allocator, mount_point, requested)) |rhel| {
        detected = rhel;
    } else |err| switch (err) {
        error.FileNotFound => {
            detected = try detectUbuntuMedia(io, allocator, mount_point, requested);
        },
        else => return err,
    }
    return detected;
}

/// 从 Anaconda/RHEL-family ISO 的 `.treeinfo` 检测媒体信息。
///
/// `.treeinfo` 是 INI 格式文件，包含 arch/family/version/repository 等字段。
/// 检测步骤：
/// 1. 验证 `.treeinfo`、`images/pxeboot/vmlinuz`、`images/pxeboot/initrd.img` 存在
/// 2. 读取 `.treeinfo` 并提取 repository/version/arch
/// 3. 验证 repository 路径安全性和 repomd.xml 存在
/// 4. 将已知 family 标签映射为产品 id；未知标签仅在 `--distro` 覆盖时接受
/// 5. 解析 arch 为 model.Arch 枚举；family 固定为 rhel
fn detectRhelMedia(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8, requested: Request) !DetectedMedia {
    _ = try assets.verifyRegularFile(io, mount_point, ".treeinfo");
    _ = try assets.verifyRegularFile(io, mount_point, "images/pxeboot/vmlinuz");
    _ = try assets.verifyRegularFile(io, mount_point, "images/pxeboot/initrd.img");
    const treeinfo_path = try std.fmt.allocPrint(allocator, "{s}/.treeinfo", .{mount_point});
    defer allocator.free(treeinfo_path);
    const treeinfo = try std.Io.Dir.cwd().readFileAlloc(io, treeinfo_path, allocator, .limited(256 * 1024));
    defer allocator.free(treeinfo);
    // Kylin V10 和其他一些受支持的 RHEL 系媒体将 repodata 发布在
    // ISO 根目录，并省略可选的 repository 键。
    const repository_path = valueFor(treeinfo, "repository") orelse "";
    if (repository_path.len != 0) try assets.validateRelativePath(repository_path);
    const repomd_path = if (repository_path.len == 0)
        try allocator.dupe(u8, "repodata/repomd.xml")
    else
        try std.fmt.allocPrint(allocator, "{s}/repodata/repomd.xml", .{repository_path});
    defer allocator.free(repomd_path);
    const product_label = valueFor(treeinfo, "family");
    const distro = requested.distro orelse
        (if (product_label) |label| distroForRhelFamily(label) else null) orelse
        return error.MediaTupleMismatch;
    const has_repository = blk: {
        _ = assets.verifyRegularFile(io, mount_point, repomd_path) catch break :blk false;
        break :blk true;
    };
    const version = requested.version orelse valueFor(treeinfo, "version") orelse return error.MediaTupleMismatch;
    const arch = requested.arch orelse blk: {
        const arch_text = valueFor(treeinfo, "arch") orelse return error.MediaTupleMismatch;
        break :blk std.meta.stringToEnum(model.Arch, arch_text) orelse return error.UnsupportedImportArchitecture;
    };
    return .{
        .family = .rhel,
        .distro = distro,
        .version = try allocator.dupe(u8, version),
        .arch = arch,
        .source_label = if (product_label) |label| try allocator.dupe(u8, label) else null,
        .layout = .{ .kernel_path = "images/pxeboot/vmlinuz", .initrd_path = "images/pxeboot/initrd.img", .repository_base = if (has_repository) try allocator.dupe(u8, repository_path) else null },
    };
}

/// 从 Ubuntu live-server ISO 的 `.disk/info` 检测媒体信息。
///
/// M3.6 介质完整性：除 `.disk/info`、`casper/vmlinuz` 与 `casper/initrd` 外，
/// 导入还必须存在至少一个 `casper/*.squashfs` 文件。这避免发布一个能下载
/// kernel 却无法进入 live installer 的 ISO（缺少 squashfs，casper 无法挂载
/// live 文件系统）。Ubuntu Server 22.04+ 不再使用固定文件名
/// `filesystem.squashfs`，而是使用 `ubuntu-server-minimal.squashfs` 等多个
/// squashfs 文件，因此检查目录中是否存在任意 `.squashfs` 后缀文件。
///
/// `.disk/info` 是人可读字符串，例如：
/// `Ubuntu-Server 22.04.5 LTS "Jammy Jellyfish" - Release arm64 (20230810)`
/// 解析步骤：
/// 1. 验证必需文件存在（含 casper squashfs）
/// 2. 读取 `.disk/info` 并解析 distro/version/arch
/// 3. 版本截取到 major.minor（如 `22.04`），去除 patch 组件
/// 4. 始终发布 ISO 媒体树；仅在 APT metadata 完整时创建 repository
///
/// Ubuntu live-server ISO 通常包含 dists/ 和 pool/ 目录，但某些定制或
/// minimal ISO 可能缺少完整的 APT metadata。此时媒体树仍供 casper 和
/// Subiquity offline-install 使用，但不能登记成可消费的 apt repository。
fn detectUbuntuMedia(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8, requested: Request) !DetectedMedia {
    _ = try assets.verifyRegularFile(io, mount_point, ".disk/info");
    _ = try assets.verifyRegularFile(io, mount_point, "casper/vmlinuz");
    _ = try assets.verifyRegularFile(io, mount_point, "casper/initrd");
    // M3.6 介质完整性：没有 casper filesystem 的 live-server kernel/initrd
    // 无法在 ISO 被下载并挂载后进入 Subiquity 安装器。Ubuntu Server 22.04+
    // 使用 ubuntu-server-minimal.squashfs 等非固定文件名，因此扫描目录
    // 确认至少存在一个 .squashfs 文件。
    if (!try casperHasSquashfs(io, mount_point)) return error.FileNotFound;
    const info_path = try std.fmt.allocPrint(allocator, "{s}/.disk/info", .{mount_point});
    defer allocator.free(info_path);
    const info = try std.Io.Dir.cwd().readFileAlloc(io, info_path, allocator, .limited(64 * 1024));
    defer allocator.free(info);
    const detected_tuple = parseUbuntuDiskInfo(info);
    const distro = requested.distro orelse if (detected_tuple != null) "ubuntu" else return error.MediaTupleMismatch;
    const version = requested.version orelse if (detected_tuple) |tuple| tuple.version else return error.MediaTupleMismatch;
    const arch = requested.arch orelse if (detected_tuple) |tuple| tuple.arch else return error.MediaTupleMismatch;
    // 只有完整的 dists/pool/Release 才能发布 apt repository；媒体树本身
    // 无论如何都会通过 install source 发布。
    const has_repository = try ubuntuRepositoryComplete(io, allocator, mount_point, version, arch);
    return .{
        .family = .ubuntu,
        .distro = distro,
        .version = try allocator.dupe(u8, version),
        .arch = arch,
        // 空字符串表示 ISO 根目录是完整 apt repository；null 表示仅发布
        // installer media tree，不把不完整内容伪装成包仓库。
        .layout = .{ .kernel_path = "casper/vmlinuz", .initrd_path = "casper/initrd", .repository_base = if (has_repository) "" else null },
    };
}

fn distroForRhelFamily(family: []const u8) ?[]const u8 {
    const mappings = [_]struct { prefix: []const u8, distro: []const u8 }{
        .{ .prefix = "Rocky", .distro = "rocky" },
        .{ .prefix = "CentOS", .distro = "centos" },
        .{ .prefix = "AlmaLinux", .distro = "alma" },
        .{ .prefix = "Red Hat Enterprise Linux", .distro = "rhel" },
        .{ .prefix = "RedHatEnterpriseLinux", .distro = "rhel" },
        .{ .prefix = "RedHatEnterpriseServer", .distro = "rhel" },
        .{ .prefix = "Fedora", .distro = "fedora" },
        .{ .prefix = "Oracle Linux", .distro = "oraclelinux" },
        .{ .prefix = "OracleLinux", .distro = "oraclelinux" },
        .{ .prefix = "Scientific Linux", .distro = "scientificlinux" },
        .{ .prefix = "ScientificLinux", .distro = "scientificlinux" },
        .{ .prefix = "CloudLinux", .distro = "cloudlinux" },
        .{ .prefix = "EuroLinux", .distro = "eurolinux" },
        .{ .prefix = "Kylin Linux Advanced Server", .distro = "kylin" },
        .{ .prefix = "Kylin", .distro = "kylin" },
        .{ .prefix = "openEuler", .distro = "openeuler" },
        .{ .prefix = "TencentOS", .distro = "tencentos" },
        .{ .prefix = "AnolisOS", .distro = "anolis" },
        .{ .prefix = "UnionTech", .distro = "uos" },
        .{ .prefix = "UOS", .distro = "uos" },
        .{ .prefix = "Sugon OS", .distro = "sugon" },
        .{ .prefix = "BigCloud-Enterprise-Linux", .distro = "bclinux" },
        .{ .prefix = "TurboLinux", .distro = "turbolinux" },
        .{ .prefix = "npserver", .distro = "npserver" },
    };
    for (mappings) |mapping| if (std.mem.startsWith(u8, family, mapping.prefix)) return mapping.distro;
    return null;
}

/// 检查 `casper/` 目录中是否存在至少一个 `.squashfs` 文件。
///
/// Ubuntu Server 22.04+ 不再使用固定文件名 `filesystem.squashfs`，
/// 而是使用 `ubuntu-server-minimal.squashfs` 等多个命名 squashfs 文件。
/// 此函数扫描 `casper/` 目录确认存在任意 `.squashfs` 后缀的常规文件。
fn casperHasSquashfs(io: std.Io, mount_point: []const u8) !bool {
    var root = try std.Io.Dir.openDirAbsolute(io, mount_point, .{ .access_sub_paths = true });
    defer root.close(io);
    var casper = root.openDir(io, "casper", .{ .iterate = true, .follow_symlinks = false }) catch return false;
    defer casper.close(io);
    var iterator = casper.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".squashfs")) return true;
    }
    return false;
}

fn ubuntuRepositoryComplete(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8, version: []const u8, arch: model.Arch) !bool {
    assets.verifyDirectory(io, mount_point, "dists") catch return false;
    assets.verifyDirectory(io, mount_point, "pool") catch return false;
    var root = try std.Io.Dir.openDirAbsolute(io, mount_point, .{ .access_sub_paths = true });
    defer root.close(io);
    var dists = try root.openDir(io, "dists", .{ .iterate = true, .follow_symlinks = false });
    defer dists.close(io);
    var iterator = dists.iterate();
    while (try iterator.next(io)) |entry| {
        // ISO9660 目录迭代允许报告 `unknown` 类型；
        // 下方受限的 `Release` 打开操作才是权威校验。
        const release_relative = try std.fmt.allocPrint(allocator, "dists/{s}/Release", .{entry.name});
        defer allocator.free(release_relative);
        _ = assets.verifyRegularFile(io, mount_point, release_relative) catch continue;
        const release_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mount_point, release_relative });
        defer allocator.free(release_path);
        const release = try std.Io.Dir.cwd().readFileAlloc(io, release_path, allocator, .limited(256 * 1024));
        defer allocator.free(release);
        if (releaseHeaderEquals(release, "Version", version) and releaseHeaderHasToken(release, "Architectures", ubuntuArch(arch))) return true;
    }
    return false;
}

const UbuntuTuple = struct { version: []const u8, arch: model.Arch };

/// `.disk/info` 在 live-server 介质上是一个人可读字符串，例如：
/// `Ubuntu-Server 22.04.5 LTS ... arm64 (...)`
/// 支持的 profile tuple 使用 major.minor（`22.04`），因此有意截取 patch 组件。
/// 架构从字符串中的 `arm64` 或 `amd64` 关键字检测。
fn parseUbuntuDiskInfo(info: []const u8) ?UbuntuTuple {
    if (!std.mem.containsAtLeast(u8, info, 1, "Ubuntu-Server")) return null;
    const start = std.mem.indexOf(u8, info, "Ubuntu-Server") orelse return null;
    var tokens = std.mem.tokenizeAny(u8, info[start + "Ubuntu-Server".len ..], " \t\r\n");
    const release = tokens.next() orelse return null;
    const first_dot = std.mem.indexOfScalar(u8, release, '.') orelse return null;
    const second_dot = if (std.mem.indexOfScalar(u8, release[first_dot + 1 ..], '.')) |offset| first_dot + 1 + offset else release.len;
    const version = release[0..second_dot];
    if (version.len == 0 or !std.ascii.isDigit(version[0])) return null;
    const arch: model.Arch = if (std.mem.containsAtLeast(u8, info, 1, " arm64")) .aarch64 else if (std.mem.containsAtLeast(u8, info, 1, " amd64")) .x86_64 else return null;
    return .{ .version = version, .arch = arch };
}

fn ubuntuArch(arch: model.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "arm64",
        .x86_64 => "amd64",
    };
}

fn containsValue(text: []const u8, key: []const u8, expected: []const u8) bool {
    const value = valueFor(text, key) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn valueFor(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..equal], " \t\r"), key)) continue;
        return std.mem.trim(u8, line[equal + 1 ..], " \t\r");
    }
    return null;
}

/// 把媒体版本转换为可用于自动 logical id 的稳定小写分量。
/// catalog 中仍保留 ISO 元数据的原始版本文本；这里只规范化自动名称。
fn logicalComponent(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0) return error.MediaTupleMismatch;
    const output = try allocator.alloc(u8, value.len);
    errdefer allocator.free(output);
    var written: usize = 0;
    var separator = false;
    for (value) |byte| {
        const lowered = std.ascii.toLower(byte);
        if (std.ascii.isAlphanumeric(lowered) or lowered == '.' or lowered == '_' or lowered == '-') {
            if (separator and written != 0 and output[written - 1] != '-') {
                output[written] = '-';
                written += 1;
            }
            separator = false;
            output[written] = lowered;
            written += 1;
        } else {
            separator = true;
        }
    }
    while (written != 0 and (output[written - 1] == '-' or output[written - 1] == '.' or output[written - 1] == '_')) written -= 1;
    if (written == 0) return error.MediaTupleMismatch;
    return output[0..written];
}

/// `.treeinfo` 使用 `key = value` 格式，而 Debian/Ubuntu Release 元数据使用
/// `Key: value` 格式。保持两个解析器独立，避免一个宽松的 ISO 文本匹配
/// 意外将 Rocky 风格的行当作已认证的 APT 元数据。
fn releaseHeader(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t\r"), key)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t\r");
    }
    return null;
}

fn releaseHeaderEquals(text: []const u8, key: []const u8, expected: []const u8) bool {
    const value = releaseHeader(text, key) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn releaseHeaderHasToken(text: []const u8, key: []const u8, expected: []const u8) bool {
    const value = releaseHeader(text, key) orelse return false;
    var tokens = std.mem.tokenizeAny(u8, value, " \t");
    while (tokens.next()) |token| if (std.mem.eql(u8, token, expected)) return true;
    return false;
}

/// 以只读方式 loop mount ISO。mount 选项 `ro,nosuid,nodev,noexec,loop` 确保：
/// - ro：只读，防止修改原始 ISO
/// - nosuid/nodev/noexec：安全加固，防止 ISO 中的 setuid/device/executable
/// - loop：使用 loop 设备挂载镜像文件
fn mountIso(io: std.Io, allocator: std.mem.Allocator, input: []const u8, mount_point: []const u8, fs_type: []const u8) !void {
    try run(io, allocator, &.{ "mount", "-t", fs_type, "-o", "ro,nosuid,nodev,noexec,loop", input, mount_point });
}
fn unmountIso(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8) !void {
    try run(io, allocator, &.{ "umount", mount_point });
}
fn copyTree(io: std.Io, allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    try runAt(io, allocator, &.{ "cp", "-a", "--no-dereference", ".", destination }, .{ .path = source });
}
fn copyTreeNoClobber(io: std.Io, allocator: std.mem.Allocator, source: []const u8, destination: []const u8, created: *bool) !void {
    const status = try std.Io.Dir.cwd().createDirPathStatus(io, destination, .default_dir);
    if (status == .existed) return error.ImportDestinationExists;
    created.* = true;
    try runAt(io, allocator, &.{ "cp", "-a", "--no-dereference", "--no-clobber", ".", destination }, .{ .path = source });
}
fn copyFileNoClobber(io: std.Io, allocator: std.mem.Allocator, source: []const u8, destination: []const u8, created: *bool) !void {
    const parent = std.fs.path.dirname(destination) orelse return error.InvalidImportDestination;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    // 避免使用 `cp --no-clobber`：已存在的目标会看起来像成功，
    // 可能导致部分导入看起来可发布。先手动检查文件是否存在。
    if (std.Io.Dir.cwd().openFile(io, destination, .{})) |file| {
        var opened = file;
        opened.close(io);
        return error.ImportDestinationExists;
    } else |err| if (err != error.FileNotFound) return err;
    created.* = true;
    try run(io, allocator, &.{ "cp", "--no-dereference", "--no-clobber", source, destination });
}

/// M4.9 fresh-deployment 修复：UEFI bootloader 是每个架构共享的 canonical
/// TFTP 对象。后续导入同架构 ISO 时只复用内容完全相同的已发布文件；
/// 同一路径内容不同说明新介质试图替换正在使用的共享启动链，必须 fail
/// closed，不能静默沿用旧文件或覆盖它。
fn copyFileIfMissing(io: std.Io, allocator: std.mem.Allocator, source: []const u8, destination: []const u8, created: *bool) !void {
    const parent = std.fs.path.dirname(destination) orelse return error.InvalidImportDestination;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    if (std.Io.Dir.cwd().openFile(io, destination, .{})) |file| {
        var opened = file;
        opened.close(io);
        var source_digest: [32]u8 = undefined;
        var destination_digest: [32]u8 = undefined;
        try sha256Path(io, source, &source_digest);
        try sha256Path(io, destination, &destination_digest);
        if (!std.crypto.timing_safe.eql([32]u8, source_digest, destination_digest))
            return error.BootloaderContentConflict;
        return;
    } else |err| if (err != error.FileNotFound) return err;
    created.* = true;
    try run(io, allocator, &.{ "cp", "--no-dereference", "--no-clobber", source, destination });
}

/// 对 importer 已约束出的普通文件路径计算原始 SHA-256。source 来自只读
/// mount 的已验证 EFI 路径，destination 位于受管 TFTP root；调用方不得将
/// 未验证的 HTTP/CLI 路径传入本函数。
fn sha256Path(io: std.Io, path: []const u8, out: *[32]u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.NotRegularFile;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try file.readPositionalAll(io, &buffer, offset);
        if (count == 0) break;
        hash.update(buffer[0..count]);
        offset += count;
        if (count < buffer.len) break;
    }
    hash.final(out);
}

fn canonicalBootloaderPath(arch: model.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "efi/grubaa64.efi",
        .x86_64 => "efi/grubx64.efi",
    };
}

fn canonicalBootloaderName(arch: model.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "grub-uefi-aarch64",
        .x86_64 => "grub-uefi-x86-64",
    };
}

/// RHEL-family 与 Ubuntu Server ISO 通常都把 GRUB 放在 EFI/BOOT。
/// 同时接受 ISO9660 上可能出现的全大写文件名。
fn findBootloaderMediaPath(io: std.Io, root: []const u8, arch: model.Arch) ?[]const u8 {
    const aarch64 = [_][]const u8{ "EFI/BOOT/grubaa64.efi", "EFI/BOOT/GRUBAA64.EFI" };
    const x86_64 = [_][]const u8{ "EFI/BOOT/grubx64.efi", "EFI/BOOT/GRUBX64.EFI" };
    const candidates: []const []const u8 = switch (arch) {
        .aarch64 => &aarch64,
        .x86_64 => &x86_64,
    };
    for (candidates) |path| {
        _ = assets.verifyRegularFile(io, root, path) catch continue;
        return path;
    }
    return null;
}

test "canonical UEFI bootloader paths match DHCP option 67" {
    try std.testing.expectEqualStrings("efi/grubaa64.efi", canonicalBootloaderPath(.aarch64));
    try std.testing.expectEqualStrings("efi/grubx64.efi", canonicalBootloaderPath(.x86_64));
    try std.testing.expectEqualStrings("grub-uefi-aarch64", canonicalBootloaderName(.aarch64));
}

test "shared UEFI bootloader reuse requires identical content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/source.efi", .{root});
    defer std.testing.allocator.free(source);
    const destination = try std.fmt.allocPrint(std.testing.allocator, "{s}/efi/grubaa64.efi", .{root});
    defer std.testing.allocator.free(destination);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, std.fs.path.dirname(destination).?);
    try dhcp_store.atomicWrite(std.testing.io, source, "same bootloader");
    try dhcp_store.atomicWrite(std.testing.io, destination, "same bootloader");
    var created = false;
    try copyFileIfMissing(std.testing.io, std.testing.allocator, source, destination, &created);
    try std.testing.expect(!created);
    try dhcp_store.atomicWrite(std.testing.io, source, "different bootloader");
    try std.testing.expectError(error.BootloaderContentConflict, copyFileIfMissing(std.testing.io, std.testing.allocator, source, destination, &created));
}

fn runAt(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = cwd, .stdout_limit = .limited(8 * 1024), .stderr_limit = .limited(8 * 1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return else return error.ImportCommandFailed,
        else => return error.ImportCommandFailed,
    }
}
fn run(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    return runAt(io, allocator, argv, .inherit);
}
/// 安全文件名校验：拒绝空字符串、包含路径分隔符（`/` 或 `\`）、
/// 包含 null 字节、或等于 `.`/`..` 的值。这防止路径穿越攻击。
fn safeFilename(value: []const u8) bool {
    return value.len > 0 and
        std.mem.indexOfAny(u8, value, "/\\") == null and
        std.mem.indexOfScalar(u8, value, 0) == null and
        !std.mem.eql(u8, value, ".") and
        !std.mem.eql(u8, value, "..");
}

test "import metadata parser accepts Rocky Minimal repository layout" {
    const treeinfo =
        \\arch = aarch64
        \\family = Rocky Linux Minimal
        \\repository = Minimal
        \\version = 9.7
    ;
    try std.testing.expectEqualStrings("rocky", distroForRhelFamily(valueFor(treeinfo, "family").?).?);
    try std.testing.expect(containsValue(treeinfo, "version", "9.7"));
    try std.testing.expectEqualStrings("Minimal", valueFor(treeinfo, "repository").?);
    try std.testing.expect(safeFilename("Rocky-9.7-aarch64-minimal.iso"));
    try std.testing.expect(!safeFilename("../escape.iso"));
    try std.testing.expect(!safeFilename("nested/escape.iso"));
}

test "safeFilename rejects every path-traversal variant" {
    // 合法文件名：非空、无路径分隔符、无 null 字节、不等于 `.`/`..`。
    try std.testing.expect(safeFilename("Rocky-9.7-aarch64-minimal.iso"));
    try std.testing.expect(safeFilename("a"));
    // 空、`.`、`..` 是 ISO 导入路径穿越的常见向量。
    try std.testing.expect(!safeFilename(""));
    try std.testing.expect(!safeFilename("."));
    try std.testing.expect(!safeFilename(".."));
    // 路径分隔符（POSIX 与 Windows）必须拒绝，防止 basename 逃逸。
    try std.testing.expect(!safeFilename("../escape.iso"));
    try std.testing.expect(!safeFilename("nested/escape.iso"));
    try std.testing.expect(!safeFilename("windows\\escape.iso"));
    // null 字节会破坏下游 `{s}/{s}` 字符串拼接假设。
    try std.testing.expect(!safeFilename("null\x00byte.iso"));
    try std.testing.expect(!safeFilename("\x00"));
}

test "Kylin media family is normalized while preserving its source label" {
    const treeinfo =
        \\arch = aarch64
        \\family = Kylin Linux Advanced Server
        \\version = V10
    ;
    try std.testing.expectEqualStrings("kylin", distroForRhelFamily(valueFor(treeinfo, "family").?).?);
    try std.testing.expect(valueFor(treeinfo, "repository") == null);
}

test "known RHEL-family products map automatically and unknown products require override" {
    const cases = [_]struct { label: []const u8, distro: []const u8 }{
        .{ .label = "Rocky Linux", .distro = "rocky" },
        .{ .label = "CentOS Stream", .distro = "centos" },
        .{ .label = "AlmaLinux", .distro = "alma" },
        .{ .label = "Red Hat Enterprise Linux", .distro = "rhel" },
        .{ .label = "RedHatEnterpriseServer", .distro = "rhel" },
        .{ .label = "Fedora Server", .distro = "fedora" },
        .{ .label = "Oracle Linux Server", .distro = "oraclelinux" },
        .{ .label = "ScientificLinux", .distro = "scientificlinux" },
        .{ .label = "CloudLinux", .distro = "cloudlinux" },
        .{ .label = "EuroLinux", .distro = "eurolinux" },
        .{ .label = "Kylin Linux Advanced Server", .distro = "kylin" },
        .{ .label = "openEuler", .distro = "openeuler" },
        .{ .label = "TencentOS Server", .distro = "tencentos" },
        .{ .label = "AnolisOS", .distro = "anolis" },
        .{ .label = "UnionTech OS Server", .distro = "uos" },
        .{ .label = "Sugon OS", .distro = "sugon" },
        .{ .label = "BigCloud-Enterprise-Linux", .distro = "bclinux" },
        .{ .label = "TurboLinux", .distro = "turbolinux" },
        .{ .label = "npserver", .distro = "npserver" },
    };
    for (cases) |item| try std.testing.expectEqualStrings(item.distro, distroForRhelFamily(item.label).?);
    try std.testing.expect(distroForRhelFamily("Example Enterprise Linux") == null);
}

test "automatic media name canonicalizes vendor version text" {
    const value = try logicalComponent(std.testing.allocator, "V10 SP3");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("v10-sp3", value);
}

test "Ubuntu media metadata uses ISO architecture spelling" {
    try std.testing.expectEqualStrings("arm64", ubuntuArch(.aarch64));
    try std.testing.expectEqualStrings("amd64", ubuntuArch(.x86_64));
    const release =
        \\Origin: Ubuntu
        \\Version: 22.04
        \\Architectures: arm64
    ;
    try std.testing.expect(releaseHeaderEquals(release, "Version", "22.04"));
    try std.testing.expect(releaseHeaderHasToken(release, "Architectures", "arm64"));
}

test "Ubuntu disk metadata detects the profile tuple without CLI flags" {
    const tuple = parseUbuntuDiskInfo("Ubuntu-Server 22.04.5 LTS \"Jammy Jellyfish\" - Release arm64 (20230810)").?;
    try std.testing.expectEqualStrings("22.04", tuple.version);
    try std.testing.expectEqual(model.Arch.aarch64, tuple.arch);
}
