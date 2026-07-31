//! Linux 安装介质导入器（M3 基线，v0.2 内容寻址 bootloader）。
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
//!
//! v0.2 bootloader 内容寻址：UEFI GRUB 二进制不再使用固定路径
//! `efi/grubaa64.efi`，改为 `efi/<sha256[:16]>-grubaa64.efi`。不同发行版
//! （如 Rocky vs Ubuntu）的 GRUB 内容不同时，各自获得独立路径，不再冲突；
//! 同内容的 ISO 导入自动复用已发布文件。这消除了 M4.9 的
//! BootloaderContentConstraint 和 copyFileIfMissing 逻辑。

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
    /// 原始 ISO basename，仅用于默认逻辑命名；文件访问始终使用 filename。
    original_filename: []const u8,
    name: ?[]const u8 = null,
    /// 可选限定符，只能追加到 ISO 派生/覆盖的基础名之后，不能替换基础身份。
    qualifier: ?[]const u8 = null,
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
/// - 零个、一个或多个 repository（通过 HTTP /artifacts/repositories/ 提供）
/// - install source（关联 ISO/kernel/initrd/repo 的 catalog 对象）
///
/// 多 variant ISO（如 Rocky 10.2 DVD 的 AppStream+BaseOS）产生多个 repository，
/// 每个对应一个 variant 子目录。单 variant ISO 产生一个 repository（向后兼容：
/// repository 名等于 source_name）。无 repository 的 ISO（如缺少 repodata 的
/// 仅安装器介质）产生空 slice。
///
/// 所有权约定：Result 中所有 `[]const u8` 字段（source_name、各 asset 的
/// name/path/sha256、install_source 的各引用字段、各 repository 的 base_url 等）
/// 均由 `importMedia` 的 `allocator` 分配，所有权随 Result 返回转移给调用方。
/// 调用方在 catalog 发布完成后负责释放这些字符串。`importMedia` 内部不得
/// 对转移给 Result 的字符串执行 `defer free`，否则会导致 use-after-free
/// （见 `bootloader_rel` BUG 历史注释）。
///
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
    /// 零个、一个或多个 RepositoryConfig。多 variant ISO（如 Rocky DVD 的
    /// AppStream+BaseOS）每个 variant 对应一个 repository。单 variant ISO
    /// 向后兼容：repository 名等于 source_name。空 slice 表示仅安装器介质
    /// （无可消费的包仓库元数据）。
    ///
    /// 所有 repository 的文件都存储在同一个 source_name 目录下
    /// （`repository_root/source_name/`），通过 base_url 中的 variant 子路径区分。
    /// HTTP 服务器按 install source 名路由文件请求，不依赖 repository 名。
    repositories: []model.RepositoryConfig,
    install_source: model.InstallSourceConfig,
};

/// 导入一个已支持布局的 Anaconda/RHEL-family 或 Ubuntu Server ISO。
///
/// 完整流程：
/// 1. 校验 filename 安全性（无路径分隔符、无 `..`、无 null 字节）
/// 2. 在受管 import_dir 内计算 ISO SHA-256（验证文件是普通非符号链接文件）
/// 3. 创建临时工作目录（mount point + staged repo）；`work_tag` 非空时目录
///    命名为 `work/iso-import-<work_tag>`（v0.2.3 §7.4 由调用方传入 operation
///    id，使 daemon 重启后的孤儿清理可按前缀识别），否则使用随机 tag
/// 4. 只读 loop mount ISO（先尝试 iso9660，失败再尝试 udf）
/// 5. 从媒体布局确定 family，并从元数据检测 distro/version/arch；未知产品标签可由请求覆盖
/// 6. 将 mount 内容复制到 staged repo
/// 7. 卸载 ISO
/// 8. 将 bootloader/kernel/initrd/ISO/repo 复制到各自的受管目标目录
///    （共享 bootloader 已存在时复用，其余对象 NoClobber 防止覆盖）
/// 9. 计算所有已发布文件的 SHA-256
/// 10. 构造 catalog 对象（assets/install_source/repository）
///
/// 所有权：Result 中所有 `[]const u8` 字段由 `allocator` 分配，所有权随
/// Result 返回转移给调用方。函数内仅对 **不** 转移给 Result 的中间字符串
/// （如 input、mount_point、staged_repo、各 destination 路径、version_slug
/// 等）执行 `defer free`。转移给 Result 的字符串（source_name、iso_rel、
/// kernel_rel、initrd_rel、bootloader_rel、distro_name、distro_version、
/// media_tree_url 及各 allocPrint 生成的 name/sha256 字段）不得 defer free。
///
/// 调用方负责 catalog 发布和 Result 字符串释放。
/// 临时工作目录在函数返回时通过 defer 清理（deleteTree）。
pub fn importMedia(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, request: Request, work_tag: ?[]const u8) !Result {
    if (!safeFilename(request.filename)) return error.UnsafeImportFilename;
    if (!safeFilename(request.original_filename) or !std.mem.endsWith(u8, request.original_filename, ".iso")) return error.UnsafeImportFilename;

    // `sha256File` 在受管根下以 NOFOLLOW+RESOLVE_BENEATH 方式打开文件，
    // 验证暂存输入是普通非符号链接文件。同时计算 SHA-256 用于 catalog 发布。
    var input_hash: [64]u8 = undefined;
    try assets.sha256File(io, paths.require().import_dir, request.filename, &input_hash);
    const input = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ paths.require().import_dir, request.filename });
    defer allocator.free(input);

    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const tag = if (work_tag) |tag_value| tag_value else hex[0..];
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

    const detected = detectMedia(io, allocator, mount_point, request) catch |err| {
        observe_log.err("ISO import media detection failed: {t}", .{err});
        return err;
    };
    const media = detected.layout;
    try copyTree(io, allocator, mount_point, staged_repo);
    try unmountIso(io, allocator, mount_point);
    mounted = false;

    const source_name = try canonicalSourceName(allocator, request.original_filename, request.name, request.qualifier);
    // 从 ISO 实际携带的 kernel/initrd 配对中检测 kernel release。仓库包名只作为
    // 最后的弱证据；无法唯一确定时宁可保留 null，也不把仓库中的另一个内核误认为
    // 安装器正在启动的内核。
    const kernel_release = detectKernelRelease(io, allocator, staged_repo, detected);
    const kernel_filename = if (kernel_release) |kr| blk: {
        break :blk try std.fmt.allocPrint(allocator, "vmlinuz-{s}", .{kr});
    } else "vmlinuz";
    const iso_rel = try std.fmt.allocPrint(allocator, "{s}.iso", .{source_name});
    const kernel_rel = try std.fmt.allocPrint(allocator, "install/{s}/{s}", .{ source_name, kernel_filename });
    const initrd_rel = try std.fmt.allocPrint(allocator, "install/{s}/initrd.img", .{source_name});
    const bootloader_media_rel = findBootloaderMediaPath(io, allocator, staged_repo, detected.arch);
    // bootloader 路径在计算 SHA-256 后确定（内容寻址），见下方 bootloader_rel 赋值。
    const iso_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.asset_root, iso_rel });
    defer allocator.free(iso_destination);
    // bootloader_destination 在下方计算 SHA-256 后确定（内容寻址路径）。
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
    // bootloader_destination 的清理 defer 在下方定义后添加。

    const mounted_kernel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, media.kernel_path });
    defer allocator.free(mounted_kernel);
    const mounted_initrd = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, media.initrd_path });
    defer allocator.free(mounted_initrd);
    const mounted_bootloader = if (bootloader_media_rel) |path|
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, path })
    else
        null;
    defer if (mounted_bootloader) |path| allocator.free(path);
    // 计算 bootloader SHA-256 以确定内容寻址路径。
    // 不同发行版（如 Rocky vs Ubuntu）可能携带不同版本的 GRUB 二进制；
    // 使用内容寻址路径（efi/<sha256前缀>-grubaa64.efi）确保同内容复用、
    // 不同内容共存，避免 BootloaderContentConflict。
    var bootloader_hash: [64]u8 = undefined;
    const bootloader_rel: []const u8 = if (bootloader_media_rel) |media_path| blk: {
        const mounted_bootloader_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, media_path });
        defer allocator.free(mounted_bootloader_path);
        // sha256Path 输出 [32]u8 原始字节，需转为 [64]u8 十六进制字符串。
        var raw_hash: [32]u8 = undefined;
        try sha256Path(io, mounted_bootloader_path, &raw_hash);
        const hex_chars = "0123456789abcdef";
        for (&raw_hash, 0..) |byte, i| {
            bootloader_hash[i * 2] = hex_chars[byte >> 4];
            bootloader_hash[i * 2 + 1] = hex_chars[byte & 0xf];
        }
        break :blk try contentAddressedBootloaderPath(allocator, source_name, detected.arch, &bootloader_hash);
    } else "";
    // bootloader_rel 的所有权转移给 Result.bootloader_asset.path（见下方
    // Result 构造），由调用方负责释放。此处不得 defer free。
    //
    // BUG 历史：此处曾有 `defer if (bootloader_rel.len > 0) allocator.free(bootloader_rel);`。
    // 该 defer 在函数返回时执行，但 bootloader_rel 已被赋给 Result.bootloader_asset.path，
    // 所有权已转移给调用方。defer free 释放了这块内存后，调用方拿到的 path 指针
    // 指向已释放区域。Zig Debug allocator 用 0xAA 填充已释放内存，导致 catalog 中
    // bootloader 资产的 path 变为 33 字节的 0xAA 乱码（而非 `efi/<hash>-grubaa64.efi`）。
    // DHCP server 的 `catalogBootfile` 将该乱码作为 TFTP bootfile 下发给 PXE 客户端，
    // PXE 客户端 TFTP 请求一个不存在的文件名，传输失败后回退到本地 disk 启动。
    // 根因：`iso_rel`、`kernel_rel`、`initrd_rel` 均无 defer free（所有权转移给
    // Result），但 `bootloader_rel` 错误地多了 defer free。修复：删除该 defer。
    //
    // 对比：`bootloader_destination`（第 198 行）的 defer free 是正确的——
    // 它是中间路径，不转移给 Result，仅用于 copyFileNoClobber。

    // 重新计算 bootloader_destination（依赖 bootloader_rel）
    const bootloader_destination = if (bootloader_media_rel != null)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tftp.asset_root, bootloader_rel })
    else
        null;
    defer if (bootloader_destination) |path| allocator.free(path);
    defer if (!retain_outputs and bootloader_created)
        std.Io.Dir.cwd().deleteFile(io, bootloader_destination.?) catch {};

    try copyFileNoClobber(io, allocator, input, iso_destination, &iso_created);
    if (mounted_bootloader) |source|
        try copyFileNoClobber(io, allocator, source, bootloader_destination.?, &bootloader_created);
    try copyFileNoClobber(io, allocator, mounted_kernel, kernel_destination, &kernel_created);
    try copyFileNoClobber(io, allocator, mounted_initrd, initrd_destination, &initrd_created);
    // 媒体树始终发布；是否同时暴露为 package repository 由 metadata 完整性决定。
    try copyTreeNoClobber(io, allocator, staged_repo, repo_destination, &repository_created);

    var iso_hash: [64]u8 = undefined;
    var kernel_hash: [64]u8 = undefined;
    var initrd_hash: [64]u8 = undefined;
    try assets.sha256File(io, config.http.asset_root, iso_rel, &iso_hash);
    // bootloader_hash 已在上方计算（从 staged 文件），此处从已发布文件重新校验。
    if (bootloader_media_rel != null)
        try assets.sha256File(io, config.tftp.asset_root, bootloader_rel, &bootloader_hash);
    try assets.sha256File(io, config.tftp.asset_root, kernel_rel, &kernel_hash);
    try assets.sha256File(io, config.tftp.asset_root, initrd_rel, &initrd_hash);

    const distro_name = try allocator.dupe(u8, detected.distro);
    const distro_version = try allocator.dupe(u8, detected.version);
    const media_tree_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}/artifacts/repositories/{s}", .{ config.server.server_ip, config.server.http_port, source_name });

    // 为每个 variant 构建独立的 software index 和 RepositoryConfig。
    //
    // 命名规则（logical ID 不允许大写字母，见 config/validate.zig::validLogicalId）：
    // - 单 variant ISO：repository 名 = source_name（向后兼容）
    // - 多 variant ISO：repository 名 = source_name-<variant_path_lowered>
    //   例如 source_name=rocky-10.2-aarch64-dvd1, base=AppStream -> rocky-10.2-aarch64-dvd1-appstream
    //
    // base_url 保持原始大小写以匹配磁盘上的 ISO 目录结构：
    //   http://<ip>:<port>/artifacts/repositories/<source_name>/<Variant>
    //
    // 所有 variant 的文件共享同一个 source_name 目录（ISO 媒体树是整体复制的），
    // HTTP 服务器通过 install source 名路由，不依赖 repository 名中的 variant 后缀。
    const repo_configs: []model.RepositoryConfig = if (media.repository_paths) |repo_paths| blk: {
        const configs = try allocator.alloc(model.RepositoryConfig, repo_paths.len);
        for (repo_paths, 0..) |base, i| {
            const index_root = if (base.len == 0)
                try allocator.dupe(u8, repo_destination)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_destination, base });
            defer allocator.free(index_root);
            const sw_index = try software_index.build(io, allocator, index_root, model.packageManagerForFamily(detected.family));
            // 单 repository 时名 = source_name（向后兼容）；多 repository 时名 = source_name-<base_lowered>
            // base 路径可能含大写（如 AppStream、BaseOS），但 logical ID 不允许大写，
            // 因此转为小写用于命名。base_url 保持原始大小写以匹配磁盘路径。
            const repo_name = if (repo_paths.len == 1)
                try allocator.dupe(u8, source_name)
            else if (base.len == 0)
                try std.fmt.allocPrint(allocator, "{s}-root", .{source_name})
            else blk_lowered: {
                const lowered = try allocator.alloc(u8, base.len);
                for (base, 0..) |c, j| lowered[j] = std.ascii.toLower(c);
                defer allocator.free(lowered);
                break :blk_lowered try std.fmt.allocPrint(allocator, "{s}-{s}", .{ source_name, lowered });
            };
            const repo_url = if (base.len == 0)
                try allocator.dupe(u8, media_tree_url)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ media_tree_url, base });
            configs[i] = .{
                .name = repo_name,
                .distro = try allocator.dupe(u8, distro_name),
                .version = try allocator.dupe(u8, distro_version),
                .arch = detected.arch,
                .manager = model.packageManagerForFamily(detected.family),
                .base_url = repo_url,
                .software_index = sw_index,
            };
        }
        break :blk configs;
    } else &.{};

    const repository_names: []const []const u8 = if (media.repository_paths != null) blk: {
        const names = try allocator.alloc([]const u8, repo_configs.len);
        for (repo_configs, 0..) |repo, i| names[i] = repo.name;
        break :blk names;
    } else &.{};
    const result: Result = .{
        .source_name = source_name,
        .family = detected.family,
        .source_label = detected.source_label,
        .iso_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-image", .{source_name}), .kind = .iso, .path = iso_rel, .distro = distro_name, .version = distro_version, .arch = detected.arch, .sha256 = try allocator.dupe(u8, &iso_hash) },
        .bootloader_asset = if (bootloader_media_rel != null) .{
            .name = try contentAddressedBootloaderName(allocator, source_name, detected.arch, &bootloader_hash),
            .kind = .bootloader,
            .path = bootloader_rel,
            .distro = distro_name,
            .version = distro_version,
            .arch = detected.arch,
            .sha256 = try allocator.dupe(u8, &bootloader_hash),
        } else null,
        .bootloader_created = bootloader_created,
        // kernel 资产名称使用 -kernel（而非 -installer-kernel），因为 kind=kernel 的
        // 资产既用于 install PXE boot 也用于 diskless PXE boot。boot bundle 的 kernel
        // 字段引用此资产。命名应反映通用性，不暗示仅限 installer 使用。
        .kernel_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-kernel", .{source_name}), .kind = .kernel, .path = kernel_rel, .distro = distro_name, .version = distro_version, .arch = detected.arch, .kernel_release = if (kernel_release) |kr| try allocator.dupe(u8, kr) else null, .sha256 = try allocator.dupe(u8, &kernel_hash) },
        .initrd_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-installer-initrd", .{source_name}), .kind = .installer_initrd, .path = initrd_rel, .distro = distro_name, .version = distro_version, .arch = detected.arch, .sha256 = try allocator.dupe(u8, &initrd_hash) },
        .repositories = repo_configs,
        .install_source = .{ .name = source_name, .source_label = detected.source_label, .distro = distro_name, .version = distro_version, .arch = detected.arch, .source_asset = try std.fmt.allocPrint(allocator, "{s}-image", .{source_name}), .installer_kernel = try std.fmt.allocPrint(allocator, "{s}-kernel", .{source_name}), .installer_initrd = try std.fmt.allocPrint(allocator, "{s}-installer-initrd", .{source_name}), .media_tree_url = media_tree_url, .repositories = repository_names, .casper_layers = detected.casper_layers },
    };
    retain_outputs = true;
    return result;
}

/// 从 ISO basename（或受控基础名覆盖）生成标准 InstallSource 名。
/// qualifier 永远只能追加，不能替换 ISO 基础身份。
fn canonicalSourceName(allocator: std.mem.Allocator, original_filename: []const u8, name_override: ?[]const u8, qualifier: ?[]const u8) ![]u8 {
    const source_base = if (name_override) |name|
        try allocator.dupe(u8, name)
    else blk: {
        const stem = original_filename[0 .. original_filename.len - ".iso".len];
        break :blk try logicalComponent(allocator, stem);
    };
    defer allocator.free(source_base);
    return if (qualifier) |value|
        std.fmt.allocPrint(allocator, "{s}-{s}", .{ source_base, value })
    else
        allocator.dupe(u8, source_base);
}

test "ISO qualifier 只能追加到标准 InstallSource 基础名" {
    const derived = try canonicalSourceName(std.testing.allocator, "Rocky-9.7-aarch64-minimal.iso", null, "site-a");
    defer std.testing.allocator.free(derived);
    try std.testing.expectEqualStrings("rocky-9.7-aarch64-minimal-site-a", derived);

    const overridden = try canonicalSourceName(std.testing.allocator, "unknown.iso", "kylin-v10-sp3-aarch64", "gpu");
    defer std.testing.allocator.free(overridden);
    try std.testing.expectEqualStrings("kylin-v10-sp3-aarch64-gpu", overridden);
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

/// v0.2.3 §7.4：daemon 启动时清理 `work/iso-import-*` 孤儿 staging 目录。
/// 正常路径的工作树由 `importMedia` 的 defer 清理（成功与失败都会删除）；
/// 只有 daemon 崩溃会遗留目录。目录按 operation id 命名（§7.4），因此可以
/// 按前缀安全识别并整树删除。先收集名称再删除，避免迭代期间变更目录。
pub fn cleanupOrphanStaging(io: std.Io, allocator: std.mem.Allocator) void {
    var dir = std.Io.Dir.cwd().openDir(io, paths.require().work_dir, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "iso-import-")) continue;
        const owned = allocator.dupe(u8, entry.name) catch continue;
        names.append(allocator, owned) catch {
            allocator.free(owned);
            continue;
        };
    }
    for (names.items) |name| {
        observe_log.warn("iso import: removing orphan staging {s}", .{name});
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ paths.require().work_dir, name }) catch continue;
        removeTreeBestEffort(io, allocator, path);
        allocator.free(path);
    }
}

/// 媒体布局描述。描述 installer kernel/initrd 在挂载的 ISO 中的相对路径，
/// 以及 repository 的 variant 路径列表。
const MediaLayout = struct {
    kernel_path: []const u8,
    initrd_path: []const u8,
    /// `null` 表示仅安装器介质（无可消费的包仓库元数据）；非空 slice 中每个
    /// 元素是一个 variant 的 repository 子目录相对路径（空字符串表示
    /// repository 在 ISO 根目录）。
    ///
    /// 多 variant RHEL-family ISO（如 Rocky 10.2 DVD）在 `.treeinfo` 的
    /// `[general]` 段声明 `variants = AppStream,BaseOS`，每个 variant 在
    /// `[variant-<name>]` 段有独立的 `repository` 键。此 slice 收集所有
    /// 存在 `repodata/repomd.xml` 的 variant 路径，用于在 `importMedia` 中
    /// 为每个 variant 构建独立的 `SoftwareIndex` 和 `RepositoryConfig`。
    ///
    /// 单 variant ISO 回退到 `[general]` 段的 `repository` 值或文件系统扫描
    /// 结果，slice 长度为 1，保持向后兼容。
    repository_paths: ?[][]const u8,
};

/// 检测到的媒体信息。包含从 ISO 元数据提取的 distro/version/arch 和媒体布局。
const DetectedMedia = struct {
    family: model.DistroFamily,
    distro: []const u8,
    version: []const u8,
    arch: model.Arch,
    source_label: ?[]const u8 = null,
    layout: MediaLayout,
    /// Ubuntu casper OS 层 layer 清单（base→top 有序）；非 Ubuntu family 始终为空。
    casper_layers: []const model.CasperLayer = &.{},
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
/// 2. 读取 `.treeinfo` 并提取所有 variant 的 repository 路径（多 variant 支持）
/// 3. 验证每个 repository 路径安全性和 repomd.xml 存在
/// 4. 将已知 family 标签映射为产品 id；未知标签仅在 `--distro` 覆盖时接受
/// 5. 解析 arch 为 model.Arch 枚举；family 固定为 rhel
///
/// 多 variant ISO 的 `.treeinfo` 结构示例（Rocky 10.2 DVD）：
/// ```ini
/// [general]
/// variants = AppStream,BaseOS
/// repository = AppStream
///
/// [variant-AppStream]
/// repository = AppStream
///
/// [variant-BaseOS]
/// repository = BaseOS
/// ```
/// `detectRhelRepositoryPaths` 遍历 variants 列表，从每个 `[variant-<name>]`
/// 段提取 repository 路径并验证 `repodata/repomd.xml` 存在。
fn detectRhelMedia(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8, requested: Request) !DetectedMedia {
    _ = try assets.verifyRegularFile(io, mount_point, ".treeinfo");
    _ = try assets.verifyRegularFile(io, mount_point, "images/pxeboot/vmlinuz");
    _ = try assets.verifyRegularFile(io, mount_point, "images/pxeboot/initrd.img");
    const treeinfo_path = try std.fmt.allocPrint(allocator, "{s}/.treeinfo", .{mount_point});
    defer allocator.free(treeinfo_path);
    const treeinfo = try std.Io.Dir.cwd().readFileAlloc(io, treeinfo_path, allocator, .limited(256 * 1024));
    defer allocator.free(treeinfo);
    const repository_paths = try detectRhelRepositoryPaths(io, allocator, mount_point, treeinfo);
    defer if (repository_paths) |repo_paths| {
        for (repo_paths) |path| allocator.free(path);
        allocator.free(repo_paths);
    };
    const product_label = valueFor(treeinfo, "family");
    const distro = requested.distro orelse
        (if (product_label) |label| distroForRhelFamily(label) else null) orelse
        return error.MediaTupleMismatch;
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
        .layout = .{ .kernel_path = "images/pxeboot/vmlinuz", .initrd_path = "images/pxeboot/initrd.img", .repository_paths = if (repository_paths) |repo_paths| try dupePaths(allocator, repo_paths) else null },
    };
}

/// 从 `.treeinfo` 解析所有 variant 的 repository 路径。
///
/// 多 variant ISO（如 Rocky 10.2 DVD）在 `[general]` 段声明 `variants = AppStream,BaseOS`，
/// 每个 variant 在 `[variant-<name>]` 段有自己的 `repository` 键。此函数收集所有
/// 存在 `repodata/repomd.xml` 的 variant 路径。
///
/// 单 variant 或无 `variants` 键的 ISO 回退到 `[general]` 段的 `repository` 值
/// （当前行为），保持向后兼容。
fn detectRhelRepositoryPaths(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8, treeinfo: []const u8) !?[][]const u8 {
    // 1. 尝试从 [general] 段解析 variants 列表
    if (valueFor(treeinfo, "variants")) |variants_text| {
        var collected: std.ArrayList([]const u8) = .empty;
        defer {
            for (collected.items) |path| allocator.free(path);
            collected.deinit(allocator);
        }
        var iter = std.mem.splitScalar(u8, variants_text, ',');
        while (iter.next()) |raw_name| {
            const variant = std.mem.trim(u8, raw_name, " \t\r");
            if (variant.len == 0) continue;
            // 在 [variant-<name>] 段查找 repository 键
            const section = try std.fmt.allocPrint(allocator, "variant-{s}", .{variant});
            defer allocator.free(section);
            const repo_path = valueForInSection(treeinfo, section, "repository") orelse continue;
            if (repo_path.len != 0) try assets.validateRelativePath(repo_path);
            // 验证 repomd.xml 存在
            const repomd_path = if (repo_path.len == 0)
                try allocator.dupe(u8, "repodata/repomd.xml")
            else
                try std.fmt.allocPrint(allocator, "{s}/repodata/repomd.xml", .{repo_path});
            defer allocator.free(repomd_path);
            _ = assets.verifyRegularFile(io, mount_point, repomd_path) catch continue;
            try collected.append(allocator, try allocator.dupe(u8, repo_path));
        }
        if (collected.items.len > 0) {
            const result = try allocator.alloc([]const u8, collected.items.len);
            for (collected.items, 0..) |path, i| result[i] = try allocator.dupe(u8, path);
            return result;
        }
    }
    // 2. 回退：[general] 段的 repository 值（单 repository）
    if (valueFor(treeinfo, "repository")) |configured| {
        if (configured.len != 0) try assets.validateRelativePath(configured);
        const repomd_path = if (configured.len == 0)
            try allocator.dupe(u8, "repodata/repomd.xml")
        else
            try std.fmt.allocPrint(allocator, "{s}/repodata/repomd.xml", .{configured});
        defer allocator.free(repomd_path);
        _ = assets.verifyRegularFile(io, mount_point, repomd_path) catch return null;
        const result = try allocator.alloc([]const u8, 1);
        result[0] = try allocator.dupe(u8, configured);
        return result;
    }
    // 3. 无 repository 键时扫描文件系统查找 repodata
    if (try findRhelRepositoryBase(io, allocator, mount_point)) |base| {
        const result = try allocator.alloc([]const u8, 1);
        result[0] = base;
        return result;
    }
    return null;
}

/// 在 INI 文件的指定 section 内查找 key = value。
fn valueForInSection(text: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_section = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            in_section = std.mem.eql(u8, trimmed[1 .. trimmed.len - 1], section);
            continue;
        }
        if (!in_section) continue;
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..equal], " \t\r"), key)) continue;
        return std.mem.trim(u8, line[equal + 1 ..], " \t\r");
    }
    return null;
}

fn dupePaths(allocator: std.mem.Allocator, src_paths: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, src_paths.len);
    for (src_paths, 0..) |path, i| result[i] = try allocator.dupe(u8, path);
    return result;
}

fn findRhelRepositoryBase(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8) !?[]const u8 {
    var root = try std.Io.Dir.openDirAbsolute(io, mount_point, .{ .iterate = true, .access_sub_paths = true });
    defer root.close(io);
    return findRepomdInDir(io, allocator, &root, "");
}

fn findRepomdInDir(io: std.Io, allocator: std.mem.Allocator, root: *std.Io.Dir, relative: []const u8) !?[]const u8 {
    const scan_rel = if (relative.len == 0) "." else relative;
    var directory = root.openDir(io, scan_rel, .{ .iterate = true, .follow_symlinks = false }) catch return null;
    defer directory.close(io);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory and entry.kind != .unknown) continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        const child_rel = if (relative.len == 0) try allocator.dupe(u8, entry.name) else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative, entry.name });
        errdefer allocator.free(child_rel);
        if (std.mem.eql(u8, entry.name, "repodata")) {
            const repomd = try std.fmt.allocPrint(allocator, "{s}/repomd.xml", .{child_rel});
            defer allocator.free(repomd);
            if (root.openFile(io, repomd, .{ .mode = .read_only, .follow_symlinks = false, .resolve_beneath = true })) |file| {
                file.close(io);
                allocator.free(child_rel);
                return if (relative.len == 0) try allocator.dupe(u8, "") else try allocator.dupe(u8, relative);
            } else |_| {}
        }
        if (try findRepomdInDir(io, allocator, root, child_rel)) |found| {
            allocator.free(child_rel);
            return found;
        }
        allocator.free(child_rel);
    }
    return null;
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
/// 3. 保留介质发布版本（如 `22.04.5`）；APT Release 校验使用其 LTS series
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
    // 使用 ubuntu-server-minimal.squashfs 等非固定文件名，因此在 assets import
    // 挂载期间一次性发现完整的有序 layer 清单（base→top），供 build 阶段的
    // casper overlay 构建使用；build 阶段 ISO 已卸载，无法重新扫描。
    const casper_layers = discoverCasperLayers(io, allocator, mount_point) catch |err| {
        observe_log.err("Ubuntu casper layer discovery failed: {t}", .{err});
        return err;
    };
    observe_log.info("Ubuntu casper default layer chain selected ({d} layer(s))", .{casper_layers.len});
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
    const has_repository = try ubuntuRepositoryComplete(io, allocator, mount_point, ubuntuSeries(version), arch);
    return .{
        .family = .ubuntu,
        .distro = distro,
        .version = try allocator.dupe(u8, version),
        .arch = arch,
        // 空 slice 表示 ISO 根目录是完整 apt repository；null 表示仅发布
        // installer media tree，不把不完整内容伪装成包仓库。
        .layout = .{ .kernel_path = "casper/vmlinuz", .initrd_path = "casper/initrd", .repository_paths = if (has_repository) blk: {
            const r = try allocator.alloc([]const u8, 1);
            r[0] = try allocator.dupe(u8, "");
            break :blk r;
        } else null },
        .casper_layers = casper_layers,
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
        .{ .prefix = "ScaleOS", .distro = "scaleos" },
    };
    for (mappings) |mapping| if (std.mem.startsWith(u8, family, mapping.prefix)) return mapping.distro;
    return null;
}

/// 发现并按 base→top 顺序返回 `casper/` 目录下的 squashfs layer 清单。
///
/// Ubuntu Server 22.04+ 使用点号分隔的文件名表达 layer 的 parent 关系，例如
/// `ubuntu-server-minimal.squashfs`（base）→
/// `ubuntu-server-minimal.ubuntu-server.squashfs`（server）→
/// `ubuntu-server-minimal.ubuntu-server.installer.squashfs`（installer/top）。
/// 去掉最后一个点号分隔段即为 parent 的文件名。要求：
///
/// - 每个非 base layer 的 parent 必须存在于同一目录（否则
///   `error.MissingCasperLayer`，fail-closed，不猜测缺失层）；
/// - 必须能唯一确定一条从 base 到 top 的链——即恰好一个 layer 不是任何其他
///   layer 的 parent（唯一的 "leaf"/顶层）。零个或多个这样的 leaf 都是
///   `error.AmbiguousCasperLayers`；
/// - 链必须覆盖 `casper/` 目录下发现的全部 `.squashfs` 文件，否则视为
///   存在游离于链外的文件，同样 `error.AmbiguousCasperLayers`。
///
/// 该函数只在 `assets import` 挂载 ISO 期间调用一次；build 阶段 ISO 已卸载，
/// 只能读取此处记录的清单，无法重新扫描。
fn discoverCasperLayers(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8) ![]const model.CasperLayer {
    var root = try std.Io.Dir.openDirAbsolute(io, mount_point, .{ .access_sub_paths = true });
    defer root.close(io);
    var casper = root.openDir(io, "casper", .{ .iterate = true, .follow_symlinks = false }) catch return error.FileNotFound;
    defer casper.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var iterator = casper.iterate();
    while (try iterator.next(io)) |entry| {
        // ISO9660/UDF 目录项常被底层报告为 `unknown`，不能像
        // ext4 一样只接受 `.file`。后面会用 NOFOLLOW 重新打开并以
        // `stat.kind == .file` 做权威校验，因此这里允许 unknown 是安全的。
        if (entry.kind != .file and entry.kind != .unknown) continue;
        if (!std.mem.endsWith(u8, entry.name, ".squashfs")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name[0 .. entry.name.len - ".squashfs".len]));
    }
    if (names.items.len == 0) return error.FileNotFound;

    // Ubuntu 官方介质可同时携带 default/generic/generic-hwe 等多个
    // 合法变体。这时不能按“全目录唯一 leaf”猜测，必须以
    // casper/install-sources.yaml 中 default source 的 path 作为顶层。
    // 自定义介质没有该 manifest 时才回退到唯一 leaf 规则。
    const manifest_top = try defaultCasperSourcePath(io, allocator, mount_point);
    defer if (manifest_top) |path| allocator.free(path);

    // parent[i] = 名字在 names.items 中的索引，或 null（该层是 base）。
    const parent_idx = try allocator.alloc(?usize, names.items.len);
    defer allocator.free(parent_idx);
    const is_parent_of_someone = try allocator.alloc(bool, names.items.len);
    defer allocator.free(is_parent_of_someone);
    @memset(is_parent_of_someone, false);

    for (names.items, 0..) |name, i| {
        const last_dot = std.mem.lastIndexOfScalar(u8, name, '.');
        if (last_dot == null) {
            parent_idx[i] = null;
            continue;
        }
        const parent_name = name[0..last_dot.?];
        var found: ?usize = null;
        for (names.items, 0..) |other, j| {
            if (i == j) continue;
            if (std.mem.eql(u8, other, parent_name)) {
                found = j;
                break;
            }
        }
        if (found == null) return error.MissingCasperLayer;
        parent_idx[i] = found;
        is_parent_of_someone[found.?] = true;
    }

    var top: ?usize = null;
    if (manifest_top) |path| {
        if (!std.mem.startsWith(u8, path, "casper/") or !std.mem.endsWith(u8, path, ".squashfs"))
            return error.InvalidCasperManifest;
        const selected = path["casper/".len .. path.len - ".squashfs".len];
        for (names.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, selected)) {
                top = i;
                break;
            }
        }
        if (top == null) return error.MissingCasperLayer;
    } else {
        for (is_parent_of_someone, 0..) |is_parent, i| {
            if (is_parent) continue;
            if (top != null) return error.AmbiguousCasperLayers;
            top = i;
        }
    }
    if (top == null) return error.AmbiguousCasperLayers;

    var chain: std.ArrayList(usize) = .empty;
    defer chain.deinit(allocator);
    var cursor: ?usize = top;
    while (cursor) |idx| {
        try chain.append(allocator, idx);
        cursor = parent_idx[idx];
    }
    // manifest 已明确选定变体时，目录中允许存在其他未选变体；
    // 无 manifest 的回退路径仍要求链覆盖全部文件。
    if (manifest_top == null and chain.items.len != names.items.len) return error.AmbiguousCasperLayers;

    const layers = try allocator.alloc(model.CasperLayer, chain.items.len);
    var out_i: usize = chain.items.len;
    for (chain.items) |idx| {
        out_i -= 1;
        const filename = try std.fmt.allocPrint(allocator, "{s}.squashfs", .{names.items[idx]});
        defer allocator.free(filename);
        const rel_path = try std.fmt.allocPrint(allocator, "casper/{s}", .{filename});
        errdefer allocator.free(rel_path);
        const abs_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mount_point, rel_path });
        defer allocator.free(abs_path);
        var file = try std.Io.Dir.cwd().openFile(io, abs_path, .{ .follow_symlinks = false });
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.NotRegularFile;
        var raw_hash: [32]u8 = undefined;
        try sha256Path(io, abs_path, &raw_hash);
        var hex_hash: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (&raw_hash, 0..) |byte, i| {
            hex_hash[i * 2] = hex_chars[byte >> 4];
            hex_hash[i * 2 + 1] = hex_chars[byte & 0xf];
        }
        layers[out_i] = .{
            .path = rel_path,
            .size = stat.size,
            .sha256 = try allocator.dupe(u8, &hex_hash),
        };
    }
    return layers;
}

/// 读取 `casper/install-sources.yaml` 中唯一的 `default: true` source，
/// 返回规范化后的 `casper/<path>`。这不是通用 YAML 解析器：只接受
/// Subiquity 该 manifest 中顶层 list item 的 `default`/`path` 标量字段，
/// 重复 default、缺 path 或带路径分隔符的值均 fail-closed。
fn defaultCasperSourcePath(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8) !?[]const u8 {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/casper/install-sources.yaml", .{mount_point});
    defer allocator.free(manifest_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var selected: ?[]const u8 = null;
    errdefer if (selected) |value| allocator.free(value);
    var item_default = false;
    var item_path: ?[]const u8 = null;
    defer if (item_path) |value| allocator.free(value);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, raw_line, "- ")) {
            if (item_default) {
                const value = item_path orelse return error.InvalidCasperManifest;
                if (selected != null) return error.AmbiguousCasperLayers;
                selected = try allocator.dupe(u8, value);
            }
            if (item_path) |value| allocator.free(value);
            item_path = null;
            item_default = false;
        }
        const field = if (std.mem.startsWith(u8, trimmed, "- ")) trimmed[2..] else trimmed;
        if (std.mem.eql(u8, field, "default: true")) item_default = true;
        if (std.mem.startsWith(u8, field, "path:")) {
            const value = std.mem.trim(u8, field["path:".len..], " \t'\"");
            if (value.len == 0 or std.mem.indexOfScalar(u8, value, '/') != null or std.mem.indexOfScalar(u8, value, '\\') != null)
                return error.InvalidCasperManifest;
            if (item_path) |old| allocator.free(old);
            item_path = try allocator.dupe(u8, value);
        }
    }
    if (item_default) {
        const value = item_path orelse return error.InvalidCasperManifest;
        if (selected != null) return error.AmbiguousCasperLayers;
        selected = try allocator.dupe(u8, value);
    }
    const value = selected orelse return error.InvalidCasperManifest;
    defer allocator.free(value);
    selected = null; // ownership is handled by the defer above, not errdefer
    // install-sources.yaml 的 default path 描述最终 server fsimage；
    // live-server 介质还会在同根下提供一个不带 generic/HWE
    // 后缀的 installer layer，其中包含 sshd 等 diskless 启动基线。
    // 优先选它作为 top；并列 generic/generic-hwe 变体仍不猜。
    if (std.mem.endsWith(u8, value, ".squashfs")) {
        const stem = value[0 .. value.len - ".squashfs".len];
        const installer_rel = try std.fmt.allocPrint(allocator, "casper/{s}.installer.squashfs", .{stem});
        errdefer allocator.free(installer_rel);
        if (assets.verifyRegularFile(io, mount_point, installer_rel)) |_| {
            return installer_rel;
        } else |_| {
            allocator.free(installer_rel);
        }
    }
    return try std.fmt.allocPrint(allocator, "casper/{s}", .{value});
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
/// 保留完整介质版本，使多个 point release 可以作为独立 source/profile 共存。
/// 架构从字符串中的 `arm64` 或 `amd64` 关键字检测。
fn parseUbuntuDiskInfo(info: []const u8) ?UbuntuTuple {
    if (!std.mem.containsAtLeast(u8, info, 1, "Ubuntu-Server")) return null;
    const start = std.mem.indexOf(u8, info, "Ubuntu-Server") orelse return null;
    var tokens = std.mem.tokenizeAny(u8, info[start + "Ubuntu-Server".len ..], " \t\r\n");
    const release = tokens.next() orelse return null;
    _ = std.mem.indexOfScalar(u8, release, '.') orelse return null;
    const version = release;
    if (version.len == 0 or !std.ascii.isDigit(version[0])) return null;
    const arch: model.Arch = if (std.mem.containsAtLeast(u8, info, 1, " arm64")) .aarch64 else if (std.mem.containsAtLeast(u8, info, 1, " amd64")) .x86_64 else return null;
    return .{ .version = version, .arch = arch };
}

fn ubuntuSeries(version: []const u8) []const u8 {
    // Ubuntu point release 是 catalog 身份的一部分；Release 文件中的 Version
    // 通常只声明 LTS series（例如资源 22.04.5 对应 metadata 22.04）。
    const first_dot = std.mem.indexOfScalar(u8, version, '.') orelse return version;
    const rest = version[first_dot + 1 ..];
    const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse return version;
    return version[0 .. first_dot + 1 + second_dot];
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

/// v0.2 bootloader 内容寻址设计说明
/// =================================
/// M4.9 设计中 bootloader 使用固定路径 `efi/grubaa64.efi`，当不同发行版
/// （如 Rocky 和 Ubuntu）的 GRUB 二进制内容不同时，第二个 ISO 导入触发
/// `BootloaderContentConflict`，导致操作员无法在同一 NodeForge 实例中
/// 同时管理多个发行版。
///
/// v0.2 改为内容寻址路径 `efi/<sha256[:16]>-grubaa64.efi`：
/// - **同内容复用**：相同 GRUB 二进制得到相同路径，`copyFileNoClobber` 自动跳过
/// - **不同内容共存**：不同 GRUB 二进制得到不同路径，互不干扰
/// - **DHCP option 67**：boot resolver 从 catalog bootloader_asset.path 读取
///   正确的内容寻址路径，在 per-node DHCP 响应中下发
/// - **清理安全**：每个 bootloader 有唯一路径，导入回滚只删除本次创建的文件
///
/// 该设计消除了 `copyFileIfMissing`/`sha256Path` 的内容比较需求和
/// `BootloaderContentConflict` 错误。`sha256Path` 仍用于计算内容寻址哈希。
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

/// 生成内容寻址的 bootloader TFTP 路径：`efi/<source>/<sha256[:16]>-grubaa64.efi`。
/// 使用 SHA-256 前 16 个十六进制字符（8 字节）作为区分前缀，足以避免
/// 实际碰撞。同内容 ISO 导入得到相同路径（复用），不同内容得到不同路径。
fn contentAddressedBootloaderPath(allocator: std.mem.Allocator, source_name: []const u8, arch: model.Arch, hash: *const [64]u8) ![]const u8 {
    const prefix = hash[0..16]; // 8 字节 = 16 hex chars
    const filename = switch (arch) {
        .aarch64 => "grubaa64.efi",
        .x86_64 => "grubx64.efi",
    };
    return std.fmt.allocPrint(allocator, "efi/{s}/{s}-{s}", .{ source_name, prefix, filename });
}

/// 生成 source-scoped bootloader catalog 名称：
/// `<source>-grub-uefi-<arch>-<sha256[:16]>`。名称与 `efi/<source>/...` 路径使用
/// 相同 ownership scope，避免两个 source 携带相同 GRUB 时出现全局名称冲突。
fn contentAddressedBootloaderName(allocator: std.mem.Allocator, source_name: []const u8, arch: model.Arch, hash: *const [64]u8) ![]const u8 {
    const prefix = hash[0..16];
    return std.fmt.allocPrint(allocator, "{s}-grub-uefi-{s}-{s}", .{ source_name, @tagName(arch), prefix });
}

/// 返回 bootloader 文件名（不含路径），用于 TFTP path 构造。
fn bootloaderFilename(arch: model.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "grubaa64.efi",
        .x86_64 => "grubx64.efi",
    };
}

/// RHEL-family 与 Ubuntu Server ISO 通常都把 GRUB 放在 EFI/BOOT。
/// ISO9660 使用全大写路径；UDF（部分新版 Ubuntu）保留原始小写路径。
/// 四种大小写组合全部覆盖，确保两种文件系统都能命中。
fn findBootloaderMediaPath(io: std.Io, allocator: std.mem.Allocator, root: []const u8, arch: model.Arch) ?[]const u8 {
    const aarch64 = [_][]const u8{ "EFI/BOOT/grubaa64.efi", "EFI/BOOT/GRUBAA64.EFI", "efi/boot/grubaa64.efi", "efi/boot/GRUBAA64.EFI" };
    const x86_64 = [_][]const u8{ "EFI/BOOT/grubx64.efi", "EFI/BOOT/GRUBX64.EFI", "efi/boot/grubx64.efi", "efi/boot/GRUBX64.EFI" };
    const candidates: []const []const u8 = switch (arch) {
        .aarch64 => &aarch64,
        .x86_64 => &x86_64,
    };
    for (candidates) |path| {
        _ = assets.verifyRegularFile(io, root, path) catch continue;
        const absolute = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, path }) catch continue;
        defer allocator.free(absolute);
        const image = std.Io.Dir.cwd().readFileAlloc(io, absolute, allocator, .limited(8 * 1024 * 1024)) catch continue;
        defer allocator.free(image);
        // Ubuntu live-server 的 ISO GRUB 内嵌 `(memdisk)/grub.cfg`，其内容
        // 专用于搜索本地 ISO，不会向 TFTP 请求 NodeForge 的 per-MAC
        // config，直接作为 option 67 会落到裸 `grub>`。这类介质
        // bootloader 必须拒绝，让 DHCP 复用 catalog 中同架构的
        // NodeForge-compatible 共享 GRUB（例如 Rocky 导入的网络 GRUB）。
        if (std.mem.indexOf(u8, image, "normal (memdisk)/grub.cfg") != null) continue;
        return path;
    }
    return null;
}

test "content-addressed UEFI bootloader paths use SHA-256 prefix" {
    const hash = "abcdef0123456789" ** 4; // 64 hex chars
    const path_aarch64 = try contentAddressedBootloaderPath(std.testing.allocator, "rocky-9.7", .aarch64, hash);
    defer std.testing.allocator.free(path_aarch64);
    try std.testing.expectEqualStrings("efi/rocky-9.7/abcdef0123456789-grubaa64.efi", path_aarch64);

    const path_x86_64 = try contentAddressedBootloaderPath(std.testing.allocator, "rocky-9.7", .x86_64, hash);
    defer std.testing.allocator.free(path_x86_64);
    try std.testing.expectEqualStrings("efi/rocky-9.7/abcdef0123456789-grubx64.efi", path_x86_64);

    const name_aarch64 = try contentAddressedBootloaderName(std.testing.allocator, "rocky-9.7", .aarch64, hash);
    defer std.testing.allocator.free(name_aarch64);
    try std.testing.expectEqualStrings("rocky-9.7-grub-uefi-aarch64-abcdef0123456789", name_aarch64);
}

test "same bootloader content remains uniquely attributable to each source" {
    const hash = "abcdef0123456789" ** 4;
    const first = try contentAddressedBootloaderName(std.testing.allocator, "rocky-9.7-minimal", .aarch64, hash);
    defer std.testing.allocator.free(first);
    const second = try contentAddressedBootloaderName(std.testing.allocator, "rocky-9.7-dvd", .aarch64, hash);
    defer std.testing.allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "content-addressed paths differ for different content" {
    const hash1 = "1111111111111111" ** 4;
    const hash2 = "2222222222222222" ** 4;
    const path1 = try contentAddressedBootloaderPath(std.testing.allocator, "rocky-9.7", .aarch64, hash1);
    defer std.testing.allocator.free(path1);
    const path2 = try contentAddressedBootloaderPath(std.testing.allocator, "rocky-9.7", .aarch64, hash2);
    defer std.testing.allocator.free(path2);
    try std.testing.expect(!std.mem.eql(u8, path1, path2));
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
/// `kernel_release` 的值是完整的 Linux UTS release（即目标内核 `uname -r`），
/// 不是 NodeForge 归一化后的版本号。发行版决定 ABI 字符串的组成：例如 RHEL
/// 通常把 `.x86_64`/`.aarch64` 包含在 release 中，而 Ubuntu 通常以
/// `-generic` 等 flavor 结尾。这里既不删除架构，也不人为追加架构。
///
/// kernel release 检测链：
/// 1. 实际 vmlinuz：gzip FNAME、x86 Linux boot protocol kernel_version，或
///    未压缩 Image/EFI stub 中的标准 `Linux version <release>` banner；
/// 2. 配套 initrd：通过发行版原生的 lsinitrd/lsinitramfs 查找 lib/modules/<release>；
/// 3. 仓库包名：仅当 production 候选唯一时采用。
///
/// 前两层只依赖 Linux 文件格式/模块 ABI，不依赖发行版名称或版本，因此后续同 family
/// 发行版升级通常不需要增加产品特例。包名规则被隔离在最后的兼容层。
///
/// 第 3 层故意不再“选择最高版本”。安装 ISO 可以同时携带 GA/HWE、普通/debug/RT
/// 等多个内核，仓库版本大小不能证明 images/pxeboot/vmlinuz 或 casper/vmlinuz
/// 实际对应哪一个。
fn detectKernelRelease(io: std.Io, allocator: std.mem.Allocator, staged_repo: []const u8, detected: DetectedMedia) ?[]const u8 {
    const vmlinuz_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, detected.layout.kernel_path }) catch null;
    if (vmlinuz_path) |path| {
        defer allocator.free(path);
        if (detectKernelReleaseFromVmlinuz(io, allocator, path)) |kr| return kr;
    }

    const initrd_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, detected.layout.initrd_path }) catch null;
    if (initrd_path) |path| {
        defer allocator.free(path);
        if (detectKernelReleaseFromInitrd(io, allocator, path)) |kr| return kr;
    }

    switch (detected.family) {
        .rhel => return detectKernelReleaseRhel(io, allocator, staged_repo, detected),
        .ubuntu => return detectKernelReleaseUbuntu(io, allocator, staged_repo, detected),
    }
}

/// 从 vmlinuz 二进制文件的 gzip 头部提取 kernel release。
///
/// gzip 格式 (RFC 1952) 头部第 4 字节是 flags，FLG_FNAME (bit 3) 表示
/// 紧跟一个以 null 结尾的原始文件名。例如：
///   vmlinuz-5.15.0-119-generic.efi.signed\0
///   vmlinuz-5.14.0-611.5.1.el9_7.aarch64\0
///
/// 提取文件名中的版本部分（去掉 vmlinuz- 前缀和 .efi.signed/.signed 后缀）。
/// 如果 vmlinuz 不是 gzip 压缩或头部无法解析，返回 null。
fn detectKernelReleaseFromVmlinuz(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .follow_symlinks = false }) catch return null;
    defer file.close(io);
    var prefix: [4096]u8 = undefined;
    const n = file.readPositionalAll(io, &prefix, 0) catch return null;
    const bytes = prefix[0..n];
    if (kernelReleaseFromGzipHeader(bytes)) |release| return allocator.dupe(u8, release) catch null;
    if (kernelReleaseFromX86BootHeader(bytes)) |release| return allocator.dupe(u8, release) catch null;
    if (detectLinuxVersionBanner(io, allocator, file)) |release| return release;
    return null;
}

/// RFC 1952 gzip FNAME 是可选字段，并且位于可选 FEXTRA 之后。不能固定从 offset 10
/// 开始读取，否则带 extra field 的合法 gzip 会被误解析。
fn kernelReleaseFromGzipHeader(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 10 or bytes[0] != 0x1f or bytes[1] != 0x8b or bytes[2] != 0x08) return null;
    const flags = bytes[3];
    if ((flags & 0xe0) != 0 or (flags & 0x08) == 0) return null;
    var offset: usize = 10;
    if ((flags & 0x04) != 0) {
        if (offset + 2 > bytes.len) return null;
        const extra_len: usize = @as(usize, bytes[offset]) | (@as(usize, bytes[offset + 1]) << 8);
        offset += 2;
        if (extra_len > bytes.len - offset) return null;
        offset += extra_len;
    }
    const name_end_rel = std.mem.indexOfScalar(u8, bytes[offset..], 0) orelse return null;
    const raw_name = bytes[offset .. offset + name_end_rel];
    return kernelReleaseFromImageName(raw_name);
}

/// x86/x86_64 bzImage 在 Linux boot protocol setup header 中公开 kernel_version。
/// 指针是相对 0x200 的 little-endian u16，适用于 CentOS 7 以及 RHEL/Rocky 8+ 的
/// images/pxeboot/vmlinuz，不依赖其 RPM 是否叫 kernel 或 kernel-core。
fn kernelReleaseFromX86BootHeader(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 0x210 or !std.mem.eql(u8, bytes[0x202..0x206], "HdrS")) return null;
    const protocol = @as(u16, bytes[0x206]) | (@as(u16, bytes[0x207]) << 8);
    if (protocol < 0x0200) return null;
    const relative = @as(usize, bytes[0x20e]) | (@as(usize, bytes[0x20f]) << 8);
    const offset = 0x200 + relative;
    if (offset >= bytes.len) return null;
    const end_rel = std.mem.indexOfScalar(u8, bytes[offset..], 0) orelse return null;
    return parseUnameRelease(bytes[offset .. offset + end_rel]);
}

fn kernelReleaseFromImageName(raw_name: []const u8) ?[]const u8 {
    // 去掉 "vmlinuz-" 前缀。
    const after_prefix = if (std.mem.startsWith(u8, raw_name, "vmlinuz-"))
        raw_name["vmlinuz-".len..]
    else
        raw_name;
    // 去掉已知的后缀：.efi.signed, .signed, .gz
    var end = after_prefix.len;
    inline for ([_][]const u8{ ".efi.signed", ".signed", ".gz" }) |suffix| {
        if (std.mem.endsWith(u8, after_prefix[0..end], suffix)) {
            end -= suffix.len;
        }
    }
    return parseUnameRelease(after_prefix[0..end]);
}

/// 解析并校验一个完整的 `uname -r` 候选。此函数只剥离 banner/空白等传输包装，
/// 不改变 release 本身的组成，也不执行跨发行版“规范化”。
fn parseUnameRelease(value: []const u8) ?[]const u8 {
    var release = std.mem.trim(u8, value, " \t\r\n");
    if (std.mem.startsWith(u8, release, "Linux version "))
        release = release["Linux version ".len..];
    const whitespace = std.mem.indexOfAny(u8, release, " \t\r\n");
    if (whitespace) |end| release = release[0..end];
    if (release.len == 0 or !std.ascii.isDigit(release[0])) return null;
    for (release) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, ".-_+~", byte) == null) return null;
    }
    return release;
}

/// Linux 构建系统会把 `Linux version <uname-r>` banner 编入未压缩的内核映像。
/// 这覆盖 raw arm64 Image、部分 EFI stub 和未来采用相同标准 banner 的内核格式，
/// 不需要知道发行版或包名。分块扫描有固定内存上限，并保留跨块 marker 的 overlap。
fn detectLinuxVersionBanner(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) ?[]const u8 {
    const marker = "Linux version ";
    var buffer: [64 * 1024 + marker.len - 1]u8 = undefined;
    var carried: usize = 0;
    var offset: u64 = 0;
    while (true) {
        const read = file.readPositionalAll(io, buffer[carried..], offset) catch return null;
        const available = carried + read;
        if (kernelReleaseFromLinuxVersionBanner(buffer[0..available])) |release|
            return allocator.dupe(u8, release) catch null;
        if (read == 0) return null;
        offset += read;
        carried = @min(marker.len - 1, available);
        std.mem.copyForwards(u8, buffer[0..carried], buffer[available - carried .. available]);
    }
}

fn kernelReleaseFromLinuxVersionBanner(bytes: []const u8) ?[]const u8 {
    const marker = "Linux version ";
    const marker_at = std.mem.indexOf(u8, bytes, marker) orelse return null;
    const value_start = marker_at + marker.len;
    if (value_start >= bytes.len) return null;
    const tail = bytes[value_start..];
    const end = std.mem.indexOfAny(u8, tail, " \t\r\n\x00") orelse tail.len;
    return parseUnameRelease(tail[0..end]);
}

/// 使用宿主发行版提供的只读列举工具解析 initrd。两个命令都只接收 argv，
/// 不经过 shell，也不会执行 initrd 内容。输出中的 modules 目录是启动时实际配套
/// 的 ABI；只有恰好一个 release 时才接受，避免多 archive/多模块树时猜测。
fn detectKernelReleaseFromInitrd(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const tools = [_][]const u8{ "lsinitrd", "lsinitramfs" };
    for (tools) |tool| {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ tool, path },
            .stdout_limit = .limited(32 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) continue,
            else => continue,
        }
        if (uniqueModuleReleaseFromListing(result.stdout)) |release|
            return allocator.dupe(u8, release) catch null;
    }
    return null;
}

fn uniqueModuleReleaseFromListing(listing: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.tokenizeAny(u8, listing, "\r\n");
    while (lines.next()) |line| {
        const marker = "lib/modules/";
        const marker_at = std.mem.indexOf(u8, line, marker) orelse continue;
        const start = marker_at + marker.len;
        if (start >= line.len) continue;
        const tail = line[start..];
        const end = std.mem.indexOfAny(u8, tail, "/ \t") orelse tail.len;
        const release = parseUnameRelease(tail[0..end]) orelse continue;
        if (found) |existing| {
            if (!std.mem.eql(u8, existing, release)) return null;
        } else {
            found = release;
        }
    }
    return found;
}

/// 从 RHEL family 仓库扫描 production kernel RPM 包名，提取 kernel release。
///
/// CentOS/RHEL 7 使用 `kernel-<version>.<arch>.rpm`；RHEL/Rocky 8+ 使用
/// `kernel-core-<version>.<arch>.rpm`。前缀后必须紧跟数字，因此 debug/rt 等
/// variant 不会被当成 production kernel。这里只删除 RPM 容器后缀 `.rpm`，
/// 有意保留 `.x86_64`/`.aarch64`，因为它们属于 RHEL 的 `uname -r`。
///
/// 扫描所有 `.treeinfo` 中声明的 variant Packages 子目录（`<variant>/Packages/k/`），
/// 单 variant 时回退到 `Packages/k/` 或 `Minimal/Packages/k/`。找不到时返回 null。
fn detectKernelReleaseRhel(io: std.Io, allocator: std.mem.Allocator, staged_repo: []const u8, detected: DetectedMedia) ?[]const u8 {
    // CentOS/RHEL 7 使用 monolithic kernel 包，RHEL/Rocky 8+ 使用 kernel-core。
    // 包名只是最后 fallback；只在 production 候选唯一时返回。
    var candidates: std.ArrayList([]const u8) = .empty;
    defer {
        for (candidates.items) |item| allocator.free(item);
        candidates.deinit(allocator);
    }

    var search_dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (search_dirs.items) |path| allocator.free(path);
        search_dirs.deinit(allocator);
    }

    if (detected.layout.repository_paths) |repo_paths| {
        for (repo_paths) |variant| {
            if (variant.len == 0) {
                const dirs = [_][]const u8{ "Packages/k", "Packages" };
                for (dirs) |sub| search_dirs.append(allocator, std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, sub }) catch continue) catch continue;
            } else {
                const dirs = [_][]const u8{ "Packages/k", "Packages" };
                for (dirs) |sub| search_dirs.append(allocator, std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ staged_repo, variant, sub }) catch continue) catch continue;
            }
        }
    } else {
        const dirs = [_][]const u8{ "Packages/k", "Packages" };
        for (dirs) |sub| search_dirs.append(allocator, std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, sub }) catch continue) catch continue;
    }

    for (search_dirs.items) |search_dir| {
        var dir = std.Io.Dir.cwd().openDir(io, search_dir, .{ .iterate = true, .follow_symlinks = false }) catch continue;
        defer dir.close(io);
        var iterator = dir.iterate();
        while (iterator.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const name = entry.name;
            const version_part = rhelKernelReleaseFromPackageName(name, detected.arch) orelse continue;
            // 去重：跳过已存在的相同版本。
            var already_exists = false;
            for (candidates.items) |existing| {
                if (std.mem.eql(u8, existing, version_part)) {
                    already_exists = true;
                    break;
                }
            }
            if (already_exists) continue;
            candidates.append(allocator, allocator.dupe(u8, version_part) catch continue) catch continue;
        }
    }
    return selectUniqueCandidate(allocator, candidates.items);
}

fn rhelKernelReleaseFromPackageName(name: []const u8, arch: model.Arch) ?[]const u8 {
    const package_prefix: []const u8 = if (std.mem.startsWith(u8, name, "kernel-core-"))
        "kernel-core-"
    else if (std.mem.startsWith(u8, name, "kernel-"))
        "kernel-"
    else
        return null;
    const after_prefix = name[package_prefix.len..];
    if (after_prefix.len == 0 or !std.ascii.isDigit(after_prefix[0])) return null;
    const arch_suffix = switch (arch) {
        .aarch64 => ".aarch64.rpm",
        .x86_64 => ".x86_64.rpm",
    };
    if (!std.mem.endsWith(u8, name, arch_suffix)) return null;
    // 只移除 RPM 容器扩展名。arch_suffix 在上面仅用于校验目标架构，不从结果
    // 中裁掉：RHEL 的 `.aarch64`/`.x86_64` 属于 uname -r 和 modules ABI。
    return name[package_prefix.len .. name.len - ".rpm".len];
}

/// 从 Ubuntu family 仓库的 pool 目录扫描 linux-image .deb 包名，提取 kernel release。
///
/// Ubuntu .deb 文件名格式为 `linux-image-<version>-generic_<full_version>_<arch>.deb`，例如：
///   linux-image-5.15.0-119-generic_5.15.0-119.129_arm64.deb -> 5.15.0-119-generic
///   linux-image-6.8.0-40-generic_6.8.0-40.40~22.04.3_arm64.deb -> 6.8.0-40-generic
/// `_arm64.deb`/`_amd64.deb` 是 Debian 包架构字段，不属于 Ubuntu 的 `uname -r`，
/// 因此从第一个下划线前的 binary package name 提取 release。
///
/// 扫描 pool/main/l/linux/ 和 pool/main/l/linux-signed/ 目录。
/// linux-signed 目录包含带签名的内核镜像包，通常优先于此包。
/// 找不到时返回 null。
fn detectKernelReleaseUbuntu(io: std.Io, allocator: std.mem.Allocator, staged_repo: []const u8, detected: DetectedMedia) ?[]const u8 {
    const arch_suffix = switch (detected.arch) {
        .aarch64 => "_arm64.deb",
        .x86_64 => "_amd64.deb",
    };
    // Ubuntu ISO 可能同时包含 GA 内核和 HWE 内核。
    // 例如 Ubuntu 22.04.5 同时包含：
    //   linux-image-5.15.0-119-generic (GA)
    //   linux-image-6.8.0-40-generic (HWE)
    // 包名不能决定 casper/vmlinuz 选择 GA 还是 HWE；仅唯一候选可作为 fallback。
    var candidates: std.ArrayList([]const u8) = .empty;
    defer {
        for (candidates.items) |item| allocator.free(item);
        candidates.deinit(allocator);
    }

    // 扫描 pool/main/l/ 下所有可能的内核目录。
    // 使用通配方式：先列出 pool/main/l/ 目录，再在每个子目录中搜索。
    const pool_l = std.fmt.allocPrint(allocator, "{s}/pool/main/l", .{staged_repo}) catch return null;
    defer allocator.free(pool_l);
    var l_dir = std.Io.Dir.cwd().openDir(io, pool_l, .{ .iterate = true, .follow_symlinks = false }) catch return null;
    defer l_dir.close(io);
    var l_iter = l_dir.iterate();
    while (l_iter.next(io) catch null) |l_entry| {
        if (l_entry.kind != .directory and l_entry.kind != .unknown) continue;
        if (!std.mem.startsWith(u8, l_entry.name, "linux")) continue;
        const search_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pool_l, l_entry.name }) catch continue;
        defer allocator.free(search_dir);
        var dir = std.Io.Dir.cwd().openDir(io, search_dir, .{ .iterate = true, .follow_symlinks = false }) catch continue;
        defer dir.close(io);
        var iterator = dir.iterate();
        while (iterator.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const name = entry.name;
            const version_part = ubuntuKernelReleaseFromPackageName(name, arch_suffix) orelse continue;
            // 去重。
            var already_exists = false;
            for (candidates.items) |existing| {
                if (std.mem.eql(u8, existing, version_part)) {
                    already_exists = true;
                    break;
                }
            }
            if (already_exists) continue;
            candidates.append(allocator, allocator.dupe(u8, version_part) catch continue) catch continue;
        }
    }
    return selectUniqueCandidate(allocator, candidates.items);
}

fn ubuntuKernelReleaseFromPackageName(name: []const u8, arch_suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "linux-image-")) return null;
    const after_prefix = name["linux-image-".len..];
    if (after_prefix.len == 0 or !std.ascii.isDigit(after_prefix[0])) return null;
    if (!std.mem.endsWith(u8, name, arch_suffix)) return null;
    const middle = name["linux-image-".len .. name.len - arch_suffix.len];
    // Debian binary package 文件名为 <package-name>_<version>_<arch>.deb。
    // uname -r 来自版本化 package-name（linux-image-<release>），而不是末尾
    // 的包架构字段，因此 release 截止到第一个下划线。
    const underscore = std.mem.indexOfScalar(u8, middle, '_') orelse return null;
    const version_part = middle[0..underscore];
    if (version_part.len == 0) return null;
    return version_part;
}

fn selectUniqueCandidate(allocator: std.mem.Allocator, candidates: []const []const u8) ?[]const u8 {
    if (candidates.len != 1) return null;
    return allocator.dupe(u8, candidates[0]) catch null;
}

fn safeFilename(value: []const u8) bool {
    return value.len > 0 and
        std.mem.indexOfAny(u8, value, "/\\") == null and
        std.mem.indexOfScalar(u8, value, 0) == null and
        !std.mem.eql(u8, value, ".") and
        !std.mem.eql(u8, value, "..");
}

test "kernel release parser handles gzip FEXTRA before FNAME" {
    const bytes = [_]u8{
        0x1f, 0x8b, 0x08, 0x0c, 0,   0, 0, 0, 0, 3, // gzip + FEXTRA + FNAME
        3,    0,    'x',  'y',  'z',
    } ++ "vmlinuz-5.15.0-119-generic.efi.signed\x00".*;
    try std.testing.expectEqualStrings("5.15.0-119-generic", kernelReleaseFromGzipHeader(&bytes).?);
}

test "kernel release parser reads x86 Linux boot protocol header" {
    var bytes = [_]u8{0} ** 4096;
    @memcpy(bytes[0x202..0x206], "HdrS");
    bytes[0x206] = 0x0f;
    bytes[0x207] = 0x02;
    const relative: u16 = 0x100;
    bytes[0x20e] = @truncate(relative);
    bytes[0x20f] = @truncate(relative >> 8);
    @memcpy(bytes[0x300 .. 0x300 + "3.10.0-1160.118.1.el7.x86_64".len + 1], "3.10.0-1160.118.1.el7.x86_64\x00");
    try std.testing.expectEqualStrings("3.10.0-1160.118.1.el7.x86_64", kernelReleaseFromX86BootHeader(&bytes).?);
}

test "kernel release parser reads the architecture-neutral Linux version banner" {
    const image = "\x7fELF random bytes Linux version 6.12.0-211.16.1.el10_2.0.1.aarch64 (mock@builder) more";
    try std.testing.expectEqualStrings(
        "6.12.0-211.16.1.el10_2.0.1.aarch64",
        kernelReleaseFromLinuxVersionBanner(image).?,
    );
}

test "initrd listing accepts one module ABI and rejects ambiguity" {
    const rocky =
        \\drwxr-xr-x  usr/lib/modules/5.14.0-503.14.1.el9_5.x86_64/
        \\-rw-r--r--  usr/lib/modules/5.14.0-503.14.1.el9_5.x86_64/modules.alias
    ;
    try std.testing.expectEqualStrings("5.14.0-503.14.1.el9_5.x86_64", uniqueModuleReleaseFromListing(rocky).?);

    const ambiguous =
        \\lib/modules/5.15.0-119-generic/kernel/foo.ko
        \\lib/modules/6.8.0-40-generic/kernel/bar.ko
    ;
    try std.testing.expect(uniqueModuleReleaseFromListing(ambiguous) == null);
}

test "repository fallback requires a unique production kernel" {
    const one = [_][]const u8{"4.18.0-553.el8_10.x86_64"};
    const many = [_][]const u8{
        "5.15.0-119-generic",
        "6.8.0-40-generic",
    };
    const selected = selectUniqueCandidate(std.testing.allocator, &one).?;
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings(one[0], selected);
    try std.testing.expect(selectUniqueCandidate(std.testing.allocator, &many) == null);
}

test "RHEL package fallback covers CentOS 7 and Rocky 8 through 10 variants" {
    try std.testing.expectEqualStrings(
        "3.10.0-1160.118.1.el7.x86_64",
        rhelKernelReleaseFromPackageName("kernel-3.10.0-1160.118.1.el7.x86_64.rpm", .x86_64).?,
    );
    try std.testing.expectEqualStrings(
        "4.18.0-553.40.1.el8_10.aarch64",
        rhelKernelReleaseFromPackageName("kernel-core-4.18.0-553.40.1.el8_10.aarch64.rpm", .aarch64).?,
    );
    try std.testing.expectEqualStrings(
        "6.12.0-211.16.1.el10_2.0.1.x86_64",
        rhelKernelReleaseFromPackageName("kernel-core-6.12.0-211.16.1.el10_2.0.1.x86_64.rpm", .x86_64).?,
    );
    try std.testing.expect(rhelKernelReleaseFromPackageName("kernel-debug-3.10.0-1160.el7.x86_64.rpm", .x86_64) == null);
    try std.testing.expect(rhelKernelReleaseFromPackageName("kernel-core-debug-5.14.0-503.el9.x86_64.rpm", .x86_64) == null);
    try std.testing.expect(rhelKernelReleaseFromPackageName("kernel-rt-core-5.14.0-503.el9.x86_64.rpm", .x86_64) == null);
}

test "Ubuntu package fallback accepts versioned images and rejects meta packages" {
    try std.testing.expectEqualStrings(
        "5.15.0-119-generic",
        ubuntuKernelReleaseFromPackageName("linux-image-5.15.0-119-generic_5.15.0-119.129_arm64.deb", "_arm64.deb").?,
    );
    try std.testing.expectEqualStrings(
        "6.8.0-40-generic",
        ubuntuKernelReleaseFromPackageName("linux-image-6.8.0-40-generic_6.8.0-40.40~22.04.3_amd64.deb", "_amd64.deb").?,
    );
    try std.testing.expect(ubuntuKernelReleaseFromPackageName("linux-image-generic_6.8.0.40.40_amd64.deb", "_amd64.deb") == null);
    try std.testing.expect(ubuntuKernelReleaseFromPackageName("linux-image-6.8.0-40-generic_foo_arm64.deb", "_amd64.deb") == null);
}

test "kernel evidence preserves the distro uname-r ABI exactly" {
    const rhel_release = "5.14.0-611.5.1.el9_7.aarch64";
    const rhel_image = kernelReleaseFromImageName("vmlinuz-" ++ rhel_release).?;
    const rhel_modules = uniqueModuleReleaseFromListing("usr/lib/modules/" ++ rhel_release ++ "/modules.alias").?;
    const rhel_package = rhelKernelReleaseFromPackageName("kernel-core-" ++ rhel_release ++ ".rpm", .aarch64).?;
    try std.testing.expectEqualStrings(rhel_release, rhel_image);
    try std.testing.expectEqualStrings(rhel_image, rhel_modules);
    try std.testing.expectEqualStrings(rhel_modules, rhel_package);

    const ubuntu_release = "5.15.0-119-generic";
    const ubuntu_image = kernelReleaseFromImageName("vmlinuz-" ++ ubuntu_release ++ ".efi.signed").?;
    const ubuntu_modules = uniqueModuleReleaseFromListing("lib/modules/" ++ ubuntu_release ++ "/kernel/fs/overlayfs/overlay.ko").?;
    const ubuntu_package = ubuntuKernelReleaseFromPackageName(
        "linux-image-" ++ ubuntu_release ++ "_5.15.0-119.129_arm64.deb",
        "_arm64.deb",
    ).?;
    try std.testing.expectEqualStrings(ubuntu_release, ubuntu_image);
    try std.testing.expectEqualStrings(ubuntu_image, ubuntu_modules);
    try std.testing.expectEqualStrings(ubuntu_modules, ubuntu_package);
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

test "ISO basename canonicalizes into a universal default source name" {
    const value = try logicalComponent(std.testing.allocator, "Kylin-Server-V10-SP3-2403-Release-20240426-ARM64");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("kylin-server-v10-sp3-2403-release-20240426-arm64", value);
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
    try std.testing.expectEqualStrings("22.04.5", tuple.version);
    try std.testing.expectEqualStrings("22.04", ubuntuSeries(tuple.version));
    try std.testing.expectEqual(model.Arch.aarch64, tuple.arch);
}

fn writeCasperLayer(temp: *std.testing.TmpDir, casper_dir: []const u8, name: []const u8, content: []const u8) !void {
    const rel = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ casper_dir, name });
    defer std.testing.allocator.free(rel);
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = rel, .data = content });
}

test "discoverCasperLayers orders base to top and computes digests" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "casper");
    try writeCasperLayer(&temp, "casper", "ubuntu-server-minimal.squashfs", "base");
    try writeCasperLayer(&temp, "casper", "ubuntu-server-minimal.ubuntu-server.squashfs", "server");
    try writeCasperLayer(&temp, "casper", "ubuntu-server-minimal.ubuntu-server.installer.squashfs", "installer");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try temp.dir.realPath(std.testing.io, &root_buf);
    const mount_point = root_buf[0..n];

    const layers = try discoverCasperLayers(std.testing.io, std.testing.allocator, mount_point);
    defer {
        for (layers) |layer| {
            std.testing.allocator.free(layer.path);
            std.testing.allocator.free(layer.sha256);
        }
        std.testing.allocator.free(layers);
    }

    try std.testing.expectEqual(@as(usize, 3), layers.len);
    try std.testing.expectEqualStrings("casper/ubuntu-server-minimal.squashfs", layers[0].path);
    try std.testing.expectEqualStrings("casper/ubuntu-server-minimal.ubuntu-server.squashfs", layers[1].path);
    try std.testing.expectEqualStrings("casper/ubuntu-server-minimal.ubuntu-server.installer.squashfs", layers[2].path);
    try std.testing.expectEqual(@as(u64, "base".len), layers[0].size);
}

test "discoverCasperLayers follows install-sources default and ignores sibling variants" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "casper");
    try writeCasperLayer(&temp, "casper", "ubuntu-server-minimal.squashfs", "base");
    try writeCasperLayer(&temp, "casper", "ubuntu-server-minimal.ubuntu-server.squashfs", "server");
    try writeCasperLayer(&temp, "casper", "ubuntu-server-minimal.ubuntu-server.installer.squashfs", "installer");
    try writeCasperLayer(&temp, "casper", "ubuntu-server-minimal.ubuntu-server.installer.generic.squashfs", "generic");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "casper/install-sources.yaml", .data =
        \\- id: ubuntu-server-minimal
        \\  path: ubuntu-server-minimal.squashfs
        \\- default: true
        \\  id: ubuntu-server
        \\  path: ubuntu-server-minimal.ubuntu-server.squashfs
    });

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try temp.dir.realPath(std.testing.io, &root_buf);
    const layers = try discoverCasperLayers(std.testing.io, std.testing.allocator, root_buf[0..n]);
    defer {
        for (layers) |layer| {
            std.testing.allocator.free(layer.path);
            std.testing.allocator.free(layer.sha256);
        }
        std.testing.allocator.free(layers);
    }
    try std.testing.expectEqual(@as(usize, 3), layers.len);
    try std.testing.expectEqualStrings("casper/ubuntu-server-minimal.squashfs", layers[0].path);
    try std.testing.expectEqualStrings("casper/ubuntu-server-minimal.ubuntu-server.squashfs", layers[1].path);
    try std.testing.expectEqualStrings("casper/ubuntu-server-minimal.ubuntu-server.installer.squashfs", layers[2].path);
}

test "discoverCasperLayers fails closed on missing parent" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "casper");
    try writeCasperLayer(&temp, "casper", "ubuntu-server-minimal.ubuntu-server.squashfs", "server");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try temp.dir.realPath(std.testing.io, &root_buf);
    const mount_point = root_buf[0..n];

    try std.testing.expectError(error.MissingCasperLayer, discoverCasperLayers(std.testing.io, std.testing.allocator, mount_point));
}

test "discoverCasperLayers fails closed on ambiguous layer set" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(std.testing.io, "casper");
    try writeCasperLayer(&temp, "casper", "ubuntu-server-minimal.squashfs", "base");
    try writeCasperLayer(&temp, "casper", "ubuntu-server-minimal.ubuntu-server.squashfs", "server");
    try writeCasperLayer(&temp, "casper", "ubuntu-server-minimal.other.squashfs", "other");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try temp.dir.realPath(std.testing.io, &root_buf);
    const mount_point = root_buf[0..n];

    try std.testing.expectError(error.AmbiguousCasperLayers, discoverCasperLayers(std.testing.io, std.testing.allocator, mount_point));
}
