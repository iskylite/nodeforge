//! M3 Linux 安装介质导入器。
//!
//! 导入器有意使用内核的只读 loop mount 而非 ISO 解析器或第三方提取工具。
//! 它从不暴露 mount：所有发布的文件在 catalog 快照被原子替换之前都已复制到
//! NodeForge 管控的目录中。
//!
//! M3.6 完整责任链：
//! `CLI fstat → atomic staging copy → daemon constrained open/hash →
//! readonly loop mount → distro detection/optional assertion →
//! kernel/initrd/repo staging → checksums → catalog candidate validation +
//! atomic replacement → stage cleanup`
//!
//! catalog 是对 HTTP/TFTP 可见性的唯一提交点；任何未发布文件都不能经 resolver 访问。
//! 导入不会实现后台 job：CLI 等待本地 daemon 的有界 worker 结果。

const std = @import("std");
const model = @import("../model.zig");
const paths = @import("../paths.zig");
const assets = @import("../assets/validate.zig");

/// 导入请求。filename 是 CLI 已暂存到 import_dir 的不透明文件名。
/// distro/version/arch 是可选的操作员断言：导入器从可信媒体元数据检测三元组，
/// 如果提供的断言值与检测结果不一致，导入被拒绝（error.MediaTupleMismatch）。
pub const Request = struct {
    filename: []const u8,
    /// 可选的操作员断言。导入器从可信媒体元数据检测三元组，
    /// 并拒绝与提供值不一致的断言。
    distro: ?[]const u8 = null,
    version: ?[]const u8 = null,
    arch: ?model.Arch = null,
};

/// 导入结果。包含所有需要发布到 catalog 的对象：
/// - ISO asset（通过 HTTP /images/ 下载）
/// - installer kernel/initrd assets（通过 TFTP 提供）
/// - 可选的 repository（通过 HTTP /repos/ 提供）
/// - install source（关联 ISO/kernel/initrd/repo 的 catalog 对象）
/// 调用方负责将这些对象原子发布到 catalog 快照。
pub const Result = struct {
    source_name: []const u8,
    iso_asset: model.AssetConfig,
    kernel_asset: model.AssetConfig,
    initrd_asset: model.AssetConfig,
    repository: ?model.RepositoryConfig,
    install_source: model.InstallSourceConfig,
};

/// 导入一个 Rocky/RHEL 或 Ubuntu DVD ISO。
///
/// 完整流程：
/// 1. 校验 filename 安全性（无路径分隔符、无 `..`、无 null 字节）
/// 2. 在受管 import_dir 内计算 ISO SHA-256（验证文件是普通非符号链接文件）
/// 3. 创建随机 tag 的临时工作目录（mount point + staged repo）
/// 4. 只读 loop mount ISO（先尝试 iso9660，失败再尝试 udf）
/// 5. 从媒体元数据检测 distro/version/arch（Rocky .treeinfo 或 Ubuntu .disk/info）
/// 6. 将 mount 内容复制到 staged repo
/// 7. 卸载 ISO
/// 8. 将 kernel/initrd/ISO/repo 复制到各自的受管目标目录（NoClobber 防止覆盖）
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
    try assets.sha256File(io, paths.import_dir, request.filename, &input_hash);
    const input = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ paths.import_dir, request.filename });
    defer allocator.free(input);

    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    const work = try std.fmt.allocPrint(allocator, "{s}/iso-import-{s}", .{ paths.work_dir, tag[0..] });
    defer allocator.free(work);
    const mount_point = try std.fmt.allocPrint(allocator, "{s}/mnt", .{work});
    defer allocator.free(mount_point);
    const staged_repo = try std.fmt.allocPrint(allocator, "{s}/repo", .{work});
    defer allocator.free(staged_repo);
    try std.Io.Dir.cwd().createDirPath(io, mount_point);
    try std.Io.Dir.cwd().createDirPath(io, staged_repo);
    defer std.Io.Dir.cwd().deleteTree(io, work) catch {};

    // ISO9660 是首选文件系统。某些介质是 UDF-only（部分新版 Ubuntu），
    // 因此失败后重试一次 UDF。两次尝试都是私有的、只读的，
    // 永远不执行介质内容（只读取文件系统元数据和文件数据）。
    mountIso(io, allocator, input, mount_point, "iso9660") catch try mountIso(io, allocator, input, mount_point, "udf");
    var mounted = true;
    defer if (mounted) unmountIso(io, allocator, mount_point) catch {};

    const detected = try detectMedia(io, allocator, mount_point, request);
    const media = detected.layout;
    try copyTree(io, allocator, mount_point, staged_repo);
    try unmountIso(io, allocator, mount_point);
    mounted = false;

    const source_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}-iso", .{ detected.distro, detected.version, @tagName(detected.arch) });
    const iso_rel = try std.fmt.allocPrint(allocator, "iso/{s}", .{request.filename});
    const kernel_rel = try std.fmt.allocPrint(allocator, "install/{s}/vmlinuz", .{source_name});
    const initrd_rel = try std.fmt.allocPrint(allocator, "install/{s}/initrd.img", .{source_name});
    const iso_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.asset_root, iso_rel });
    defer allocator.free(iso_destination);
    const kernel_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tftp.asset_root, kernel_rel });
    defer allocator.free(kernel_destination);
    const initrd_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tftp.asset_root, initrd_rel });
    defer allocator.free(initrd_destination);
    const repo_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.repository_root, source_name });
    defer allocator.free(repo_destination);

    const mounted_kernel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, media.kernel_path });
    defer allocator.free(mounted_kernel);
    const mounted_initrd = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, media.initrd_path });
    defer allocator.free(mounted_initrd);
    try copyFileNoClobber(io, allocator, input, iso_destination);
    try copyFileNoClobber(io, allocator, mounted_kernel, kernel_destination);
    try copyFileNoClobber(io, allocator, mounted_initrd, initrd_destination);
    if (media.repository_base != null) try copyTreeNoClobber(io, allocator, staged_repo, repo_destination);

    var iso_hash: [64]u8 = undefined;
    var kernel_hash: [64]u8 = undefined;
    var initrd_hash: [64]u8 = undefined;
    try assets.sha256File(io, config.http.asset_root, iso_rel, &iso_hash);
    try assets.sha256File(io, config.tftp.asset_root, kernel_rel, &kernel_hash);
    try assets.sha256File(io, config.tftp.asset_root, initrd_rel, &initrd_hash);

    const repository_names = if (media.repository_base != null) blk: {
        const names = try allocator.alloc([]const u8, 1);
        names[0] = source_name;
        break :blk names;
    } else &.{};
    const distro_name = try allocator.dupe(u8, detected.distro);
    const distro_version = try allocator.dupe(u8, detected.version);
    return .{
        .source_name = source_name,
        .iso_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-image", .{source_name}), .kind = .iso, .path = iso_rel, .distro = distro_name, .version = distro_version, .arch = detected.arch, .sha256 = try allocator.dupe(u8, &iso_hash) },
        .kernel_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-installer-kernel", .{source_name}), .kind = .kernel, .path = kernel_rel, .distro = distro_name, .version = distro_version, .arch = detected.arch, .sha256 = try allocator.dupe(u8, &kernel_hash) },
        .initrd_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-installer-initrd", .{source_name}), .kind = .installer_initrd, .path = initrd_rel, .distro = distro_name, .version = distro_version, .arch = detected.arch, .sha256 = try allocator.dupe(u8, &initrd_hash) },
        .repository = if (media.repository_base) |base| .{ .name = source_name, .distro = distro_name, .version = distro_version, .arch = detected.arch, .manager = if (std.mem.eql(u8, detected.distro, "rocky")) .dnf else .apt, .base_url = if (base.len == 0) try std.fmt.allocPrint(allocator, "http://{s}:{d}/repos/{s}", .{ config.server.server_ip, config.server.http_port, source_name }) else try std.fmt.allocPrint(allocator, "http://{s}:{d}/repos/{s}/{s}", .{ config.server.server_ip, config.server.http_port, source_name, base }) } else null,
        .install_source = .{ .name = source_name, .distro = distro_name, .version = distro_version, .arch = detected.arch, .source_asset = try std.fmt.allocPrint(allocator, "{s}-image", .{source_name}), .installer_kernel = try std.fmt.allocPrint(allocator, "{s}-installer-kernel", .{source_name}), .installer_initrd = try std.fmt.allocPrint(allocator, "{s}-installer-initrd", .{source_name}), .repositories = repository_names },
    };
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
    distro: []const u8,
    version: []const u8,
    arch: model.Arch,
    layout: MediaLayout,
};

/// 从挂载的 ISO 检测 distro/version/arch 和媒体布局。
///
/// 检测顺序：先尝试 Rocky .treeinfo（结构化元数据更强），
/// 非 Rocky ISO 则回退到 Ubuntu live-server 标记文件 .disk/info。
/// 如果操作员提供了断言值，检测结果必须与之匹配，否则拒绝导入。
fn detectMedia(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8, requested: Request) !DetectedMedia {
    // Rocky 的 `.treeinfo` 是明确的结构化元数据，比文件名有更强的认证保证。
    // 先尝试它；非 Rocky ISO 会回退到 Ubuntu live-server 标记文件。
    if (detectRockyMedia(io, allocator, mount_point)) |rocky| {
        try verifyRequestedTuple(requested, rocky.distro, rocky.version, rocky.arch);
        return rocky;
    } else |err| switch (err) {
        error.FileNotFound, error.MediaMetadataMissing, error.MediaTupleMismatch => {},
        else => return err,
    }
    const ubuntu = try detectUbuntuMedia(io, allocator, mount_point);
    try verifyRequestedTuple(requested, ubuntu.distro, ubuntu.version, ubuntu.arch);
    return ubuntu;
}

/// 验证操作员提供的可选断言与检测结果是否一致。
/// 任一断言值与检测结果不一致时返回 error.MediaTupleMismatch。
/// 这防止“操作员以为是 Ubuntu 但实际放入了 Rocky ISO”之类的错误。
fn verifyRequestedTuple(requested: Request, distro: []const u8, version: []const u8, arch: model.Arch) !void {
    if (requested.distro) |value| if (!std.mem.eql(u8, value, distro)) return error.MediaTupleMismatch;
    if (requested.version) |value| if (!std.mem.eql(u8, value, version)) return error.MediaTupleMismatch;
    if (requested.arch) |value| if (value != arch) return error.MediaTupleMismatch;
}

/// 从 Rocky/RHEL ISO 的 `.treeinfo` 检测媒体信息。
///
/// `.treeinfo` 是 INI 格式文件，包含 arch/family/version/repository 等字段。
/// 检测步骤：
/// 1. 验证 `.treeinfo`、`images/pxeboot/vmlinuz`、`images/pxeboot/initrd.img` 存在
/// 2. 读取 `.treeinfo` 并提取 repository/version/arch
/// 3. 验证 repository 路径安全性和 repomd.xml 存在
/// 4. 验证 family 前缀为 "Rocky"
/// 5. 解析 arch 为 model.Arch 枚举
fn detectRockyMedia(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8) !DetectedMedia {
    _ = try assets.verifyRegularFile(io, mount_point, ".treeinfo");
    _ = try assets.verifyRegularFile(io, mount_point, "images/pxeboot/vmlinuz");
    _ = try assets.verifyRegularFile(io, mount_point, "images/pxeboot/initrd.img");
    const treeinfo_path = try std.fmt.allocPrint(allocator, "{s}/.treeinfo", .{mount_point});
    defer allocator.free(treeinfo_path);
    const treeinfo = try std.Io.Dir.cwd().readFileAlloc(io, treeinfo_path, allocator, .limited(256 * 1024));
    defer allocator.free(treeinfo);
    const repository_path = valueFor(treeinfo, "repository") orelse return error.MediaMetadataMissing;
    try assets.validateRelativePath(repository_path);
    const repomd_path = try std.fmt.allocPrint(allocator, "{s}/repodata/repomd.xml", .{repository_path});
    defer allocator.free(repomd_path);
    _ = try assets.verifyRegularFile(io, mount_point, repomd_path);
    if (!containsPrefixValue(treeinfo, "family", "Rocky")) return error.MediaTupleMismatch;
    const version = valueFor(treeinfo, "version") orelse return error.MediaMetadataMissing;
    const arch_text = valueFor(treeinfo, "arch") orelse return error.MediaMetadataMissing;
    const arch = std.meta.stringToEnum(model.Arch, arch_text) orelse return error.UnsupportedImportArchitecture;
    return .{
        .distro = "rocky",
        .version = try allocator.dupe(u8, version),
        .arch = arch,
        .layout = .{ .kernel_path = "images/pxeboot/vmlinuz", .initrd_path = "images/pxeboot/initrd.img", .repository_base = try allocator.dupe(u8, repository_path) },
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
/// 4. 检查是否存在完整 APT repository（dists/pool/Release）
fn detectUbuntuMedia(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8) !DetectedMedia {
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
    const tuple = parseUbuntuDiskInfo(info) orelse return error.MediaTupleMismatch;
    const has_repository = try ubuntuRepositoryComplete(io, allocator, mount_point, tuple.version, tuple.arch);
    return .{
        .distro = "ubuntu",
        .version = try allocator.dupe(u8, tuple.version),
        .arch = tuple.arch,
        .layout = .{ .kernel_path = "casper/vmlinuz", .initrd_path = "casper/initrd", .repository_base = if (has_repository) "" else null },
    };
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
        // ISO9660 directory iteration is permitted to report `unknown` kind;
        // the confined `Release` open below is the authoritative check.
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

fn containsPrefixValue(text: []const u8, key: []const u8, expected_prefix: []const u8) bool {
    const value = valueFor(text, key) orelse return false;
    return std.mem.startsWith(u8, value, expected_prefix);
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
fn copyTreeNoClobber(io: std.Io, allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    const status = try std.Io.Dir.cwd().createDirPathStatus(io, destination, .default_dir);
    if (status == .existed) return error.ImportDestinationExists;
    try runAt(io, allocator, &.{ "cp", "-a", "--no-dereference", "--no-clobber", ".", destination }, .{ .path = source });
}
fn copyFileNoClobber(io: std.Io, allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    const parent = std.fs.path.dirname(destination) orelse return error.InvalidImportDestination;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    // 避免使用 `cp --no-clobber`：已存在的目标会看起来像成功，
    // 可能导致部分导入看起来可发布。先手动检查文件是否存在。
    if (std.Io.Dir.cwd().openFile(io, destination, .{})) |file| {
        var opened = file;
        opened.close(io);
        return error.ImportDestinationExists;
    } else |err| if (err != error.FileNotFound) return err;
    try run(io, allocator, &.{ "cp", "--no-dereference", "--no-clobber", source, destination });
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
    try std.testing.expect(containsPrefixValue(treeinfo, "family", "Rocky"));
    try std.testing.expect(containsValue(treeinfo, "version", "9.7"));
    try std.testing.expectEqualStrings("Minimal", valueFor(treeinfo, "repository").?);
    try std.testing.expect(safeFilename("Rocky-9.7-aarch64-minimal.iso"));
    try std.testing.expect(!safeFilename("../escape.iso"));
    try std.testing.expect(!safeFilename("nested/escape.iso"));
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
    try verifyRequestedTuple(.{ .filename = "fixture.iso" }, "ubuntu", tuple.version, tuple.arch);
    try std.testing.expectError(error.MediaTupleMismatch, verifyRequestedTuple(.{ .filename = "fixture.iso", .distro = "rocky" }, "ubuntu", tuple.version, tuple.arch));
}
