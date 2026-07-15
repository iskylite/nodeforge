//! M3.5 boot target 解析层。
//!
//! 从 TFTP boot 身份（已 ACK 的 BootSession）和当前 config/catalog 快照展开
//! kernel 路径、initrd 路径和 kernel 命令行。本模块不读取 session/catalog 的
//! 锁——调用方在调用前获取安全副本，锁内只读取/复制元数据。
//!
//! 渲染规则：
//! - install：profile.install_source → InstallSourceConfig → installer kernel/initrd
//!   assets，并读取已发布 repository URL。M3 不追加 inst.ks=（M4 完成后追加）。
//! - diskless：profile.boot_bundle → kernel/initrd assets。cmdline 包含
//!   nodeforge.config=http://…/api/v1/nodes/<id>/config。
//! - discovery：不提供 kernel/initrd，返回 null。
//!
//! M3.6 安全要点：
//! - 所有路径在返回前经过安全校验：拒绝空白、控制字符、反斜杠及未受管路径。
//! - Ubuntu install 使用 casper 的 `url=` 参数而非 Anaconda 的 `inst.repo`，
//!   因为 Ubuntu live-server 由 casper 下载并 loop mount ISO。
//! - 返回的路径是相对于 TFTP root 的 GRUB 路径（以 `/` 开头），
//!   由调用方在锁定 catalog 快照时补充前导 `/`。

const std = @import("std");
const model = @import("../model.zig");
const lookup = @import("../catalog.zig");
const grub = @import("grub.zig");
const boot_session = @import("../state/boot_session.zig");

/// 从 boot_session 模块再导出 TFTP boot 身份类型，确保 TFTP handler 和
/// boot target resolver 共享同一个类型定义，避免出现影子类型。
pub const TftpBootIdentity = boot_session.TftpBootIdentity;

/// 解析后的 boot target，供 GRUB renderer 使用。
///
/// `kernel_path` 和 `initrd_path` 是相对于 TFTP root 的路径（不以 `/` 开头），
/// 调用方（通常是 TFTP 虚拟配置传输函数）负责在 GRUB 语法中补充前导 `/`。
/// `cmdline` 是完整的 kernel 命令行，由调用方提供的缓冲区拼接而成。
pub const BootTarget = struct {
    kernel_path: []const u8,
    initrd_path: []const u8,
    cmdline: []const u8,
    arch: model.Arch,
};

/// 从 TFTP boot 身份和 config/catalog 展开 boot target。
///
/// install mode：从 install source 取 installer kernel/initrd asset 路径，
/// cmdline 按发行版 installer family 生成：
/// - RHEL 系（Rocky/CentOS）使用 `inst.repo=<repository_url>`，由 Anaconda
///   从 DNF repository 下载安装树。M4 会追加 `inst.ks=<answer_url>`。
/// - Ubuntu live-server/casper 使用 `boot=casper url=<iso_url>`，由 casper
///   initrd 下载 ISO 并 loop mount 为 live 文件系统。M4 会追加
///   `autoinstall ds=nocloud-net;...`。
///
/// diskless mode：从 boot bundle 取 kernel/initrd asset 路径，
/// cmdline 包含 `ip=dhcp nodeforge.config=<config_url>`，节点 initrd 通过
/// 该 URL 拉取 BootConfig 文档并随后下载 rootfs。
///
/// discovery mode：返回 null（不提供 kernel/initrd），节点只做网络诊断。
///
/// 所有路径在返回前经过安全校验：拒绝空白、控制字符、反斜杠及未受管路径。
/// 返回的路径是相对于 TFTP root 的 GRUB 路径（以 `/` 开头）。
///
/// `cmdline_buf` 和 `path_buf` 由调用方提供，用于拼接 cmdline 和转换路径格式。
pub fn resolve(
    identity: TftpBootIdentity,
    config: *const model.AppConfig,
    catalog: *const model.Catalog,
    server_ip: []const u8,
    http_port: u16,
    cmdline_buf: []u8,
) ?BootTarget {
    if (identity.mode == .install) return resolveInstall(identity, config, catalog, server_ip, http_port, cmdline_buf);
    if (identity.mode == .diskless) return resolveDiskless(identity, config, catalog, server_ip, http_port, cmdline_buf);
    return null;
}

/// 解析 install 模式的 boot target。
///
/// 责任链：profile → install_source → installer kernel/initrd assets → cmdline。
/// 如果任一环节查找失败（profile 不存在、source 未引用、asset 未发布或 kind
/// 不匹配），返回 null，由 TFTP handler 转化为 access_violation 错误。
///
/// cmdline 生成按发行版分支：
/// - Ubuntu：使用 casper 的 `url=` 参数指向已发布的 ISO HTTP URL，
///   附加 `root=/dev/ram0 ramdisk_size=1500000 ip=dhcp`。M4 追加
///   `autoinstall ds=nocloud-net;s=<answer_url>/` 传入 autoinstall 数据。
///   `ramdisk_size=1500000`（约 1.5 GB）确保 ramdisk 足够容纳 casper 提取的
///   squashfs。不再使用 `cloud-config-url=/dev/null`——该 M3 临时参数会与
///   NoCloud-Net 冲突（详见下方内联注释）。
/// - RHEL 系（Rocky 等）：使用 `ip=dhcp rd.neednet=1 inst.repo=<repo_url>`，
///   Anaconda 从 DNF repository 下载安装树。M4 追加 `inst.ks=`。
fn resolveInstall(
    identity: TftpBootIdentity,
    config: *const model.AppConfig,
    catalog: *const model.Catalog,
    server_ip: []const u8,
    http_port: u16,
    cmdline_buf: []u8,
) ?BootTarget {
    // install 模式不直接使用 boot_session_id/mac/lease_ip 构造 cmdline，
    // 它们已由 DHCP/TFTP 链路验证，这里只用于查找 profile。
    _ = identity.mac;
    _ = identity.lease_ip;
    // 按 profile 名称查找启动配置中的 profile 定义。
    const profile = lookup.findProfile(config, identity.profile) orelse return null;
    // install profile 必须引用一个 install source。
    const source_name = profile.install_source orelse return null;
    // 在 catalog 中查找已发布的 install source（由 ISO 导入流程创建）。
    const source = lookup.findInstallSource(catalog, source_name) orelse return null;

    // 查找 installer kernel 和 initrd 的 catalog asset 条目。
    const kernel_asset = lookup.findAsset(catalog, source.installer_kernel) orelse return null;
    const initrd_asset = lookup.findAsset(catalog, source.installer_initrd) orelse return null;

    // 验证 asset kind 与期望一致：kernel 必须是 .kernel，initrd 必须是 .installer_initrd。
    // 这防止 catalog 中类型错误（例如把 rootfs 当 kernel）的 asset 被启动。
    if (kernel_asset.kind != .kernel or initrd_asset.kind != .installer_initrd) return null;

    // 将 catalog asset path 转为 GRUB 路径并做安全校验。
    const kernel_path = toGrubPath(kernel_asset.path) orelse return null;
    const initrd_path = toGrubPath(initrd_asset.path) orelse return null;

    // 按发行版选择 cmdline 参数。
    // Ubuntu 和 RHEL 系使用完全不同的 installer 机制：
    // - Ubuntu live-server 由 casper（initramfs 中的脚本）通过 HTTP 下载 ISO，
    //   loop mount 后进入 Subiquity 安装器。
    // - RHEL 系由 Anaconda 直接从 DNF repository 下载安装树（RPM 包）。
    const distro = lookup.findDistro(config, source.distro) orelse return null;
    const cmdline = if (distro.family == .ubuntu) blk: {
        // Ubuntu 的 live-server 安装器基于 casper。`inst.repo` 是 Anaconda 专用
        // 参数，在此被忽略；casper 需要已发布的 ISO URL 来下载并 loop mount ISO。
        // 额外的 live-server 参数匹配 Canonical 的 netboot 指引：
        // - boot=casper：显式选择 casper live 启动路径，避免没有本地 CD-ROM
        //   时 initramfs 回退到 `/dev/sr0` 探测
        // - root=/dev/ram0：使用 ramdisk 作为初始根文件系统
        // - ramdisk_size=1500000：分配约 1.5 GB ramdisk 空间给 casper squashfs
        // - ip=dhcp：通过 DHCP 获取网络配置
        //
        // M4 通过 NoCloud-Net 数据源（`ds=nocloud-net;s=<answer_url>/`）传入
        // autoinstall user-data/meta-data。live-server 22.04 的 casper 启动
        // 路径还必须显式禁用其默认 cloud-config URL；否则 cloud-init 可能
        // 退回 DataSourceNone，完全不探测指定的 NoCloud-Net URL（实机可见
        // 语言选择交互界面）。这不是第二个 answer source：/dev/null 仅阻止
        // 默认 URL，NoCloud-Net 仍是唯一的 M4 answer source。
        const source_asset = lookup.findAsset(catalog, source.source_asset) orelse return null;
        if (source_asset.kind != .iso) return null;
        break :blk std.fmt.bufPrint(
            cmdline_buf,
            "boot=casper root=/dev/ram0 ramdisk_size=1500000 ip=dhcp url=http://{s}:{d}/images/{s}.iso cloud-config-url=/dev/null autoinstall ds=nocloud-net\\;s=http://{s}:{d}/api/v1/nodes/{s}/answer/",
            .{ config.server.server_ip, config.server.http_port, source.source_asset, server_ip, http_port, identity.node_id },
        ) catch return null;
    } else blk: {
        // RHEL 系（Rocky/CentOS）安装 cmdline。
        // - ip=dhcp：通过 DHCP 获取网络配置
        // - rd.neednet=1：强制 dracut 在 initramfs 阶段初始化网络
        // - inst.repo=<url>：Anaconda 从此 DNF repository URL 下载安装树
        // M4 会追加 `inst.ks=<answer_url>` 以实现无人值守 Kickstart 安装。
        // `repository.base_url` is the DNF package root (for example
        // `/repos/<source>/Minimal`).  Anaconda's `inst.repo` instead needs
        // the media tree root so it can read `.treeinfo`, `images/install.img`
        // and follow the treeinfo repository pointer itself.
        var install_root_buf: [256]u8 = undefined;
        const install_root = std.fmt.bufPrint(&install_root_buf, "http://{s}:{d}/repos/{s}", .{ server_ip, http_port, source.name }) catch return null;
        break :blk std.fmt.bufPrint(cmdline_buf, "ip=dhcp rd.neednet=1 inst.repo={s} inst.ks=http://{s}:{d}/api/v1/nodes/{s}/answer", .{ install_root, server_ip, http_port, identity.node_id }) catch return null;
    };

    return .{
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .cmdline = cmdline,
        .arch = profile.arch,
    };
}

/// 解析 diskless 模式的 boot target。
///
/// 责任链：profile → boot_bundle → kernel/initrd assets → cmdline。
/// cmdline 包含 `ip=dhcp nodeforge.config=<config_url>`，节点 initrd 通过
/// 该 URL 拉取 BootConfig 文档（含 rootfs 下载地址和 capability token）。
/// kernel 必须是 .kernel，initrd 必须是 .nodeforge_initrd（NodeForge 自建的小 initrd）。
fn resolveDiskless(
    identity: TftpBootIdentity,
    config: *const model.AppConfig,
    catalog: *const model.Catalog,
    server_ip: []const u8,
    http_port: u16,
    cmdline_buf: []u8,
) ?BootTarget {
    const profile = lookup.findProfile(config, identity.profile) orelse return null;
    const bundle_name = profile.boot_bundle orelse return null;
    const bundle = lookup.findBootBundle(catalog, bundle_name) orelse return null;

    const kernel_asset = lookup.findAsset(catalog, bundle.kernel) orelse return null;
    const initrd_asset = lookup.findAsset(catalog, bundle.initrd) orelse return null;

    // diskless 模式使用 NodeForge 自建的 initrd（.nodeforge_initrd），
    // 而非发行版自带的 installer initrd（.installer_initrd）。
    if (kernel_asset.kind != .kernel or initrd_asset.kind != .nodeforge_initrd) return null;

    const kernel_path = toGrubPath(kernel_asset.path) orelse return null;
    const initrd_path = toGrubPath(initrd_asset.path) orelse return null;

    // cmdline 包含 nodeforge.config URL，节点 initrd 通过该 URL 拉取 BootConfig。
    // BootConfig 包含 rootfs 下载地址、capability token 和事件上报 URL。
    const cmdline = std.fmt.bufPrint(cmdline_buf, "ip=dhcp nodeforge.config=http://{s}:{d}/api/v1/nodes/{s}/config", .{
        server_ip,
        http_port,
        identity.node_id,
    }) catch return null;

    return .{
        .kernel_path = kernel_path,
        .initrd_path = initrd_path,
        .cmdline = cmdline,
        .arch = profile.arch,
    };
}

/// 将 catalog asset path 转为 GRUB 路径（以 `/` 开头的相对路径）。
///
/// 安全校验：拒绝空白、控制字符（< 0x20 和 0x7f）、反斜杠。
/// 这些字符在 GRUB 配置中有特殊含义或可能导致路径注入。
/// 注意：此函数不添加前导 `/`，因为调用方在 catalog 锁内拼接 GRUB 配置时
/// 会自行补充前导 `/`（参见 tftp/server.zig 中的 transferVirtualConfig）。
fn toGrubPath(asset_path: []const u8) ?[]const u8 {
    if (asset_path.len == 0) return null;
    for (asset_path) |c| {
        if (c < 0x20 or c == 0x7f or c == '\\') return null;
    }
    // GRUB 路径使用 `/` 作为分隔符；catalog 路径已经使用 `/`。
    // 如果路径以 `/` 开头则原样返回，否则由调用方补充前导 `/`。
    if (asset_path[0] == '/') return asset_path;
    return asset_path;
}

// 以下为单元测试，覆盖 install/diskless/discovery 三种模式及路径安全校验。
// 测试使用的 config/catalog 数据结构与生产环境完全一致，只是使用编译期
// 静态切片而非运行时加载的 JSON。

test "resolve install target returns kernel/initrd/repo cmdline" {
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.27.128", .http_port = 18080 },
        .distros = &.{.{ .name = "rocky", .family = .rhel, .versions = &.{.{ .version = "9.7", .archs = &.{.aarch64}, .install_adapter = .kickstart, .package_manager = .dnf }} }},
        .profiles = &.{.{
            .name = "rocky-install",
            .mode = .install,
            .distro = "rocky",
            .version = "9.7",
            .arch = .aarch64,
            .install_source = "rocky-9.7-iso",
        }},
    };
    const catalog: model.Catalog = .{
        .assets = &.{
            .{ .name = "rocky-kernel", .kind = .kernel, .path = "install/rocky/vmlinuz" },
            .{ .name = "rocky-initrd", .kind = .installer_initrd, .path = "install/rocky/initrd.img" },
        },
        .install_sources = &.{.{
            .name = "rocky-9.7-iso",
            .distro = "rocky",
            .version = "9.7",
            .arch = .aarch64,
            .source_asset = "rocky-iso",
            .installer_kernel = "rocky-kernel",
            .installer_initrd = "rocky-initrd",
            .repositories = &.{"rocky-9.7-repo"},
        }},
        .repositories = &.{.{
            .name = "rocky-9.7-repo",
            .distro = "rocky",
            .version = "9.7",
            .arch = .aarch64,
            .manager = .dnf,
            .base_url = "http://192.168.27.128:18080/repos/rocky-9.7-iso",
        }},
    };
    const identity: TftpBootIdentity = .{
        .boot_session_id = "0123456789abcdef0123456789abcdef".*,
        .node_id = "node-01",
        .profile = "rocky-install",
        .mode = .install,
        .mac = .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xef },
        .lease_ip = 0xc0a81bc8,
    };
    var cmdline_buf: [512]u8 = undefined;
    const target = resolve(identity, &config, &catalog, "192.168.27.128", 18080, &cmdline_buf).?;
    try std.testing.expectEqualStrings("install/rocky/vmlinuz", target.kernel_path);
    try std.testing.expectEqualStrings("install/rocky/initrd.img", target.initrd_path);
    try std.testing.expect(std.mem.indexOf(u8, target.cmdline, "ip=dhcp") != null);
    try std.testing.expect(std.mem.indexOf(u8, target.cmdline, "inst.repo=http://192.168.27.128:18080/repos/rocky-9.7-iso") != null);
    // M4 appends the authenticated node-specific Kickstart endpoint.
    try std.testing.expect(std.mem.indexOf(u8, target.cmdline, "inst.ks=http://") != null);
}

test "resolve diskless target returns config url cmdline" {
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.27.128", .http_port = 18080 },
        .distros = &.{.{ .name = "ubuntu", .family = .ubuntu, .versions = &.{.{ .version = "22.04", .archs = &.{.aarch64}, .install_adapter = .autoinstall, .package_manager = .apt }} }},
        .profiles = &.{.{
            .name = "ubuntu-diskless",
            .mode = .diskless,
            .distro = "ubuntu",
            .version = "22.04",
            .arch = .aarch64,
            .boot_bundle = "ubuntu-bundle",
        }},
    };
    const catalog: model.Catalog = .{
        .assets = &.{
            .{ .name = "ub-kernel", .kind = .kernel, .path = "boot/vmlinuz" },
            .{ .name = "ub-initrd", .kind = .nodeforge_initrd, .path = "boot/initrd.img" },
        },
        .boot_bundles = &.{.{
            .name = "ubuntu-bundle",
            .distro = "ubuntu",
            .version = "22.04",
            .arch = .aarch64,
            .kernel_release = "5.15.0",
            .kernel = "ub-kernel",
            .initrd = "ub-initrd",
            .rootfs = "ub-rootfs",
        }},
    };
    const identity: TftpBootIdentity = .{
        .boot_session_id = "0123456789abcdef0123456789abcdef".*,
        .node_id = "node-02",
        .profile = "ubuntu-diskless",
        .mode = .diskless,
        .mac = .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xf0 },
        .lease_ip = 0xc0a81bc9,
    };
    var cmdline_buf: [512]u8 = undefined;
    const target = resolve(identity, &config, &catalog, "192.168.27.128", 18080, &cmdline_buf).?;
    try std.testing.expectEqualStrings("boot/vmlinuz", target.kernel_path);
    try std.testing.expectEqualStrings("boot/initrd.img", target.initrd_path);
    try std.testing.expect(std.mem.indexOf(u8, target.cmdline, "nodeforge.config=http://192.168.27.128:18080/api/v1/nodes/node-02/config") != null);
}

// M3.6 关键测试：验证 Ubuntu install 使用 `url=`（casper ISO 下载）而非
// `inst.repo=`（Anaconda DNF repository）。这两个参数属于不同的安装器
// 机制，混用会导致 Ubuntu 安装器无法找到安装介质。
test "resolve Ubuntu install target uses the ISO URL, never inst.repo" {
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.27.128", .http_port = 18080 },
        .distros = &.{.{ .name = "ubuntu", .family = .ubuntu, .versions = &.{.{ .version = "22.04", .archs = &.{.aarch64}, .install_adapter = .autoinstall, .package_manager = .apt }} }},
        .profiles = &.{.{ .name = "ubuntu-install", .mode = .install, .distro = "ubuntu", .version = "22.04", .arch = .aarch64, .install_source = "ubuntu-22.04-aarch64-iso" }},
    };
    const catalog: model.Catalog = .{
        .assets = &.{
            .{ .name = "ubuntu-iso", .kind = .iso, .path = "iso/ubuntu-22.04.5-live-server-arm64.iso" },
            .{ .name = "ubuntu-kernel", .kind = .kernel, .path = "install/ubuntu/vmlinuz" },
            .{ .name = "ubuntu-initrd", .kind = .installer_initrd, .path = "install/ubuntu/initrd" },
        },
        .install_sources = &.{.{ .name = "ubuntu-22.04-aarch64-iso", .distro = "ubuntu", .version = "22.04", .arch = .aarch64, .source_asset = "ubuntu-iso", .installer_kernel = "ubuntu-kernel", .installer_initrd = "ubuntu-initrd" }},
    };
    const identity: TftpBootIdentity = .{ .boot_session_id = "0123456789abcdef0123456789abcdef".*, .node_id = "node-ubuntu", .profile = "ubuntu-install", .mode = .install, .mac = .{ 2, 170, 187, 204, 221, 1 }, .lease_ip = 0xc0a81bc8 };
    var cmdline_buf: [512]u8 = undefined;
    const target = resolve(identity, &config, &catalog, "192.168.27.128", 18080, &cmdline_buf).?;
    // 必须包含 url= 参数指向已发布的 ISO HTTP URL。
    try std.testing.expect(std.mem.indexOf(u8, target.cmdline, "url=http://192.168.27.128:18080/images/ubuntu-iso.iso") != null);
    // Ubuntu live initramfs must explicitly select casper; otherwise it can
    // fall back to scanning a missing local CD-ROM device.
    try std.testing.expect(std.mem.indexOf(u8, target.cmdline, "boot=casper") != null);
    try std.testing.expect(std.mem.indexOf(u8, target.cmdline, "ds=nocloud-net\\;s=http://192.168.27.128:18080/api/v1/nodes/node-ubuntu/answer/") != null);
    try std.testing.expect(std.mem.indexOf(u8, target.cmdline, "cloud-config-url=/dev/null") != null);
    // 绝不能包含 inst.repo=，那是 Anaconda/RHEL 专用参数。
    try std.testing.expect(std.mem.indexOf(u8, target.cmdline, "inst.repo=") == null);
}

test "resolve discovery returns null" {
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.27.128" },
        .profiles = &.{.{
            .name = "discovery",
            .mode = .discovery,
            .distro = "rocky",
            .version = "9.7",
            .arch = .aarch64,
        }},
    };
    const catalog: model.Catalog = .{};
    const identity: TftpBootIdentity = .{
        .boot_session_id = "0123456789abcdef0123456789abcdef".*,
        .node_id = "node-03",
        .profile = "discovery",
        .mode = .discovery,
        .mac = .{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xf1 },
        .lease_ip = 0xc0a81bca,
    };
    var cmdline_buf: [512]u8 = undefined;
    // discovery 模式不提供 kernel/initrd，返回 null。
    try std.testing.expect(resolve(identity, &config, &catalog, "192.168.27.128", 18080, &cmdline_buf) == null);
}

// 路径安全校验测试：拒绝包含反斜杠的路径，防止 Windows 风格路径注入。
test "rejects path with backslash" {
    try std.testing.expect(toGrubPath("install\\rocky\\vmlinuz") == null);
}

// 路径安全校验测试：拒绝空路径。
test "rejects empty path" {
    try std.testing.expect(toGrubPath("") == null);
}
