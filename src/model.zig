//! M0 阶段的强类型事实模型。
//! `AppConfig` 保存启动/策略配置，`Catalog` 保存由 nodeforged 导入和发布的管理目录。

const paths = @import("paths.zig");

/// NodeForge 启动配置事实源 `/opt/nodeforge/config/config.json` 的根对象。
pub const AppConfig = struct {
    /// 配置格式版本；M0 仅接受版本 1。
    schema_version: u32 = 1,
    /// 服务网广告地址、可选网卡和 HTTP/管理共用端口。
    server: ServerConfig,
    /// HTTP 资产与仓库根目录。
    http: HttpConfig = .{},
    /// 服务日志等级；daemon `--debug` 可在本次启动临时覆盖为 debug。
    logging: LoggingConfig = .{},
    /// 受支持的发行版及版本矩阵。
    distros: []const DistroConfig = &.{},
    /// 节点可绑定的安装、无盘或发现策略。
    profiles: []const ProfileConfig = &.{},
    /// 已录入节点；未知节点行为由 policy 单独控制。
    nodes: []const NodeConfig = &.{},
    /// 未知节点的全局默认行为。
    policy: PolicyConfig = .{},
};

/// NodeForge 管理目录事实源 `/opt/nodeforge/catalog/catalog.json` 的根对象。
/// 该文件只由 `nodeforged` 写入，CLI 不直接编辑。
pub const Catalog = struct {
    /// 配置格式版本；M0 仅接受版本 1。
    schema_version: u32 = 1,
    /// 可由 dnf/apt 直接使用的软件仓库。
    repositories: []const RepositoryConfig = &.{},
    /// 已纳管的 ISO、内核和 initrd 等文件。
    assets: []const AssetConfig = &.{},
    /// 自动安装入口，负责关联 ISO、安装内核、initrd 和仓库。
    install_sources: []const InstallSourceConfig = &.{},
    /// 无盘启动所需的同版本 kernel、initrd 和 rootfs 组合。
    boot_bundles: []const BootBundleConfig = &.{},
};

/// 单进程服务配置。
pub const ServerConfig = struct {
    /// 用于日志和状态输出的实例名称。
    name: []const u8 = "nodeforge",
    /// PXE 服务网卡名称。M0 可为空；M1/M2 接入 TFTP/DHCP 后用于约束三类服务在同一网卡/网段。
    bind_interface: ?[]const u8 = null,
    /// PXE 服务网对外 IPv4 地址；用于生成 HTTP/TFTP URL、DHCP next-server 等广告地址。
    /// HTTP M0 仍绑定 0.0.0.0，不把该字段作为 bind 地址。
    server_ip: []const u8,
    /// 唯一 HTTP 监听端口；同时承载 PXE 数据路由和管理路由。CLI 固定使用 loopback 访问。
    http_port: u16 = 8080,
};

/// HTTP 大文件和发行版仓库目录配置。
pub const HttpConfig = struct {
    /// rootfs、ISO 和普通 HTTP 资产根目录。
    asset_root: []const u8 = paths.assets_dir,
    /// 通过 `/repos/` 只读发布的仓库根目录。
    repository_root: []const u8 = paths.repos_dir,
};

/// 服务日志配置。业务事件仍写入独立的 events.jsonl。
pub const LoggingConfig = struct {
    /// 日常输出 info；debug 额外输出连接和协议诊断。
    level: LogLevel = .info,
};

/// 可配置的服务日志等级。
pub const LogLevel = enum { info, debug };

/// 首期支持的处理器架构；生产优先 x86_64，开发验证优先 aarch64。
pub const Arch = enum { x86_64, aarch64 };

/// 发行版家族决定安装器和标准包管理器。
pub const DistroFamily = enum { rhel, ubuntu };

/// 标准自动安装适配器。
pub const InstallAdapter = enum { kickstart, autoinstall };

/// 基础源及额外标准包使用的包管理器。
pub const PackageManager = enum { dnf, apt };

/// 资产类型用于阻止把 ISO、内核和 initrd 错接到其他位置。
pub const AssetKind = enum { iso, bootloader, kernel, installer_initrd, nodeforge_initrd, rootfs, gpg_key };

/// profile 的启动目的。
pub const ProfileMode = enum { discovery, install, diskless };

/// 未知节点没有显式绑定时的处理方式；永远不允许默认为 install。
pub const DiscoveryAction = enum { wait, discovery, diskless, deny };

/// 一个发行版名称下可以声明多个受支持版本。
pub const DistroConfig = struct {
    /// 稳定短名称，例如 rocky、alma、rhel、fedora 或 ubuntu。
    name: []const u8,
    /// RHEL 系和 Ubuntu 使用不同安装及仓库适配器。
    family: DistroFamily,
    /// 当前项目实际允许使用的版本。
    versions: []const DistroVersionConfig = &.{},
};

/// 发行版版本与架构能力矩阵。
pub const DistroVersionConfig = struct {
    /// 上游版本字符串，保留 9.7、22.04 这类原始表达。
    version: []const u8,
    /// 此版本已经验证或计划支持的架构。
    archs: []const Arch = &.{},
    /// 自动安装配置格式。
    install_adapter: InstallAdapter,
    /// 标准包安装工具。
    package_manager: PackageManager,
};

/// 由标准 ISO 或显式外部地址产生的 dnf/apt 仓库。
pub const RepositoryConfig = struct {
    /// 稳定短名称，用于 profile 和 install source 引用。
    name: []const u8,
    /// 所属发行版名称，必须能在 `AppConfig.distros` 中找到。
    distro: []const u8,
    /// 所属发行版版本，必须与 distro 的 versions 矩阵匹配。
    version: []const u8,
    /// 仓库目标架构。
    arch: Arch,
    /// 包管理器必须与 distro family 对应：rhel→dnf，ubuntu→apt。
    manager: PackageManager,
    /// 仓库基础 URL，可指向本地 HTTP 发布路径或外部 mirror。
    base_url: []const u8,
    /// MVP 默认关闭 GPG 校验，只有显式开启时才要求 key 资产。
    gpg_check: bool = false,
    /// GPG key 资产名称；仅当 `gpg_check = true` 时必须存在且 kind 为 `gpg_key`。
    gpg_key: ?[]const u8 = null,
};

/// 文件资产清单。路径由 HTTP/TFTP 根目录解释，不允许直接映射任意 URL。
pub const AssetConfig = struct {
    /// 稳定短名称，用于 install source、boot bundle 和 repository 引用。
    name: []const u8,
    /// 资产类型，用于阻止把 ISO、内核和 initrd 错接到其他位置。
    kind: AssetKind,
    /// 相对于 HTTP/TFTP asset root 的路径，不允许直接映射任意 URL。
    path: []const u8,
    /// 可选发行版名称；一旦填写则 version 和 arch 也必须同时填写。
    distro: ?[]const u8 = null,
    /// 可选发行版版本；与 distro 配合使用。
    version: ?[]const u8 = null,
    /// 可选目标架构；与 distro/version 配合使用。
    arch: ?Arch = null,
    /// 内核相关资产可记录 uname release，便于验证 kernel/rootfs 一致。
    kernel_release: ?[]const u8 = null,
    /// 导入阶段计算；M0 允许为空，后续发布资产时必须存在。
    sha256: ?[]const u8 = null,
};

/// PXE 自动安装入口使用的完整关联，不让 profile 直接拼散乱文件名。
pub const InstallSourceConfig = struct {
    /// 稳定短名称，用于 install profile 的 `boot_source` 引用。
    name: []const u8,
    /// 所属发行版名称。
    distro: []const u8,
    /// 所属发行版版本。
    version: []const u8,
    /// 目标架构。
    arch: Arch,
    /// ISO 资产名称；必须指向 catalog 中 kind 为 `iso` 的资产。
    source_asset: []const u8,
    /// 安装器内核资产名称；必须指向 kind 为 `kernel` 的资产。
    installer_kernel: []const u8,
    /// 安装器 initrd 资产名称；必须指向 kind 为 `installer_initrd` 的资产。
    installer_initrd: []const u8,
    /// 关联仓库名称列表；每个名称必须能在 catalog.repositories 中找到。
    repositories: []const []const u8 = &.{},
};

/// 无盘启动的不可拆分版本组合。
pub const BootBundleConfig = struct {
    /// 稳定短名称，用于 diskless profile 的 `boot_source` 引用。
    name: []const u8,
    /// 所属发行版名称。
    distro: []const u8,
    /// 所属发行版版本。
    version: []const u8,
    /// 目标架构。
    arch: Arch,
    /// 内核 release 字符串，kernel/initrd/rootfs 三者必须一致。
    kernel_release: []const u8,
    /// 内核资产名称；必须指向 kind 为 `kernel` 的资产。
    kernel: []const u8,
    /// NodeForge 小 initrd 资产名称；必须指向 kind 为 `nodeforge_initrd` 的资产。
    initrd: []const u8,
    /// rootfs 资产名称；必须指向 kind 为 `rootfs` 的资产。
    rootfs: []const u8,
};

/// profile 的安全元数据供未知节点策略做静态判断。
pub const ProfileSafetyConfig = struct {
    /// 是否允许未知节点使用此 profile；safe/ephemeral profile 必须为 true。
    safe_for_unknown: bool = false,
    /// 是否包含擦盘、格式化等不可逆操作；install profile 必须为 true。
    destructive: bool = false,
    /// 是否写入持久状态；safe/ephemeral profile 必须为 false。
    persistent_writes: bool = false,
};

/// 节点启动策略。install source 与 boot bundle 按 mode 二选一。
pub const ProfileConfig = struct {
    /// 稳定短名称，用于 node 引用。
    name: []const u8,
    /// 启动目的：discovery、install 或 diskless。
    mode: ProfileMode,
    /// 发行版名称，必须能在 `AppConfig.distros` 中找到。
    distro: []const u8,
    /// 发行版版本，必须与 distro 的 versions 矩阵匹配。
    version: []const u8,
    /// 目标架构。
    arch: Arch,
    /// install mode 时引用的 install source 名称；discovery/diskless 必须为 null。
    install_source: ?[]const u8 = null,
    /// diskless mode 时引用的 boot bundle 名称；discovery/install 必须为 null。
    boot_bundle: ?[]const u8 = null,
    /// 安全元数据，供未知节点策略做静态判断。
    safety: ProfileSafetyConfig = .{},
};

/// M0 节点最小身份模型；后续网络覆盖和 IPMI 信息在保持此身份不变的前提下扩展。
pub const NodeConfig = struct {
    /// NodeForge 内部节点名，例如 `node-01`；用于 CLI 和 API。
    id: []const u8,
    /// 网卡 MAC 地址（冒号分隔）；MVP 最主要的 PXE 身份匹配字段。
    mac: []const u8,
    /// 节点架构，必须与所绑定 profile 的 arch 一致。
    arch: Arch,
    /// 所绑定 profile 名称，必须能在 `AppConfig.profiles` 中找到。
    profile: []const u8,
    /// DHCP 静态保留地址（IPv4 点分格式）；为空时从地址池动态分配。
    ip: ?[]const u8 = null,
    /// 节点主机名；用于渲染安装配置中的 hostname。
    hostname: ?[]const u8 = null,
};

/// 未录入节点的默认策略。
pub const PolicyConfig = struct {
    /// 未录入节点的默认处置方式；缺省值为 `wait`，永远不允许 `install`。
    default_action: DiscoveryAction = .wait,
    /// discovery/diskless action 引用的 profile 名称；wait/deny 时必须为 null。
    default_profile: ?[]const u8 = null,
    /// 是否显式允许未知节点进入 diskless；为 false 时 diskless action 非法。
    allow_unknown_diskless: bool = false,
};
