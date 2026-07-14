//! M0 阶段的强类型事实模型。
//! `AppConfig` 保存启动/策略配置，`Catalog` 保存由 nodeforged 导入和发布的管理目录。

const paths = @import("paths.zig");

/// NodeForge 启动配置事实源 `paths.config_path` 的根对象。
pub const AppConfig = struct {
    /// 配置格式版本；M0 仅接受版本 1。
    schema_version: u32 = 1,
    /// 服务网广告地址、可选网卡和 HTTP/管理共用端口。
    server: ServerConfig,
    /// HTTP 资产与仓库根目录。
    http: HttpConfig = .{},
    /// TFTP 只读启动资产根目录；监听端口固定为 UDP 69。
    tftp: TftpConfig = .{},
    /// PXE 管理网 DHCPv4 策略；监听端口固定为 UDP 67。
    dhcp: DhcpConfig = .{},
    /// 服务日志等级；daemon `--debug` 可在本次启动临时覆盖为 debug。
    logging: LoggingConfig = .{},
    /// 业务事件审计流的轮转策略。
    events: EventsConfig = .{},
    /// 受支持的发行版及版本矩阵。
    distros: []const DistroConfig = &.{},
    /// 节点可绑定的安装、无盘或发现策略。
    profiles: []const ProfileConfig = &.{},
    /// 已录入节点；未知节点行为由 policy 单独控制。
    nodes: []const NodeConfig = &.{},
    /// 可复用的基础后处理步骤；M4 只执行 install_post 的 repository、
    /// standard_packages 和 managed_file 三种动作。
    provisioning_bundles: []const ProvisioningBundle = &.{},
    /// 未知节点的全局默认行为。
    policy: PolicyConfig = .{},
};

/// NodeForge 管理目录事实源 `paths.catalog_path` 的根对象。
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
    /// PXE 服务网卡名称。当前 DHCPv4 Linux 服务要求该字段非空，并以它限制广播收发；示例中的
    /// `enp1s0` 只是占位值，部署前必须替换为承载 `server_ip` 的实际网卡。
    bind_interface: ?[]const u8 = null,
    /// PXE 服务网对外 IPv4 地址；用于生成 HTTP/TFTP URL、DHCP next-server 等广告地址。
    /// HTTP M0 仍绑定 0.0.0.0，不把该字段作为 bind 地址。
    server_ip: []const u8,
    /// 唯一 HTTP 监听端口；同时承载 PXE 数据路由和管理路由。CLI 固定使用 loopback 访问。
    http_port: u16 = 8080,
    /// NodeForge 管理端在目标机上使用的 bootstrap SSH 公钥；私钥绝不进入配置。
    ssh_authorized_public_key: ?[]const u8 = null,
    /// M4.2 F5: 额外的 SSH 公钥列表，注入到所有目标节点的 authorized_keys。
    /// 这些密钥不用于 nodeforged 自身的 SSH 访问（那由 ssh_authorized_public_key 负责），
    /// 而是用于操作员/审计员的额外访问。CLI key-* 命令管理 assets/keys 中的密钥文件。
    ssh_authorized_public_keys: []const []const u8 = &.{},
};

/// HTTP 大文件和发行版仓库目录配置。
pub const HttpConfig = struct {
    /// rootfs、ISO 和普通 HTTP 资产根目录。
    asset_root: []const u8 = paths.iso_dir,
    /// 通过 `/repos/` 只读发布的仓库根目录。
    repository_root: []const u8 = paths.repos_dir,
    /// M4.2 F4: 最大并发 HTTP 连接数。0 = 不限制。
    /// M6 将在压力测试后设置生产默认值。
    max_connections: u16 = 0,
};

/// TFTP 启动小文件配置。
///
/// 端口是 PXE 协议约定，固定在服务实现中；此处只允许声明只读根目录，
/// 防止把每项传输参数扩散为难以维护的 CLI 参数。
pub const TftpConfig = struct {
    /// bootloader、GRUB 配置、kernel 和 initrd 的只读根目录。
    asset_root: []const u8 = paths.boot_dir,
    /// M4.2 F4: OACK 中通告的最大 TFTP windowsize（RFC 7440）。
    /// 0 禁用 windowsize 协商（RFC 1350 停止等待模式）。
    /// 接受 1-65535 的值；客户端可以请求更小的值。
    windowsize: u16 = 4,
    /// 服务端提供并作为上限的最大 TFTP 块大小（RFC 2348 blksize option）。
    /// 默认 1468 是以太网 MTU 最优值：1500 − 20 (IP) − 8 (UDP) − 4 (TFTP)，
    /// 使每个 DATA 包恰好填满一个以太网帧而不触发 IP 分片（约为 RFC 1350
    /// 默认 512 字节的 3 倍）。两种用法：(1) §7.4 当客户端省略 blksize 时在
    /// OACK 中主动建议此值；(2) 将客户端请求的 blksize 向下限制到此值
    ///（RFC 2348 允许返回更小的值）。jumbo-frame 链路可调高，受限链路调低。
    /// 必须 ≥ 8。
    max_blksize: u16 = 1468,
    /// M4.2 F4: 每个客户端的最大并发 TFTP 传输数。
    /// 每个 RRQ 启动一个独立线程，拥有自己的 TID socket。
    /// 0 或 1 保留原始串行行为。
    max_concurrent_transfers: u8 = 4,
};

/// M2 authoritative DHCPv4 的最小站点级地址池。端口不会进入配置。
pub const DhcpConfig = struct {
    subnet: []const u8 = "192.168.50.0/24",
    pool_start: []const u8 = "192.168.50.100",
    pool_end: []const u8 = "192.168.50.200",
    router: ?[]const u8 = null,
    dns: []const []const u8 = &.{},
    lease_seconds: u32 = 1800,
    /// OFFER 的有效期（秒）；客户端在此时限内需用 REQUEST 确认。
    offer_seconds: u32 = 60,
    /// 被拒绝地址的隔离时间（秒）；隔离期满前该地址不可重新分配。
    abandon_seconds: u32 = 3600,
    /// 在 OFFER 前等待 ICMP Echo Reply 的超时时间（毫秒）。0 为非法值。
    /// daemon 需要 CAP_NET_RAW 能力；探测不可用时扣留 OFFER 而非将候选地址视为可用。
    ping_timeout_ms: u16 = 500,
};

/// 服务日志配置。业务事件仍写入独立的 events.jsonl。
pub const LoggingConfig = struct {
    /// 日常输出 info；debug 额外输出连接和协议诊断。
    level: LogLevel = .info,
    /// 可选文件路径与轮转策略；`--log-output auto` 配置它时选择双写。
    file: ?FileLogConfig = null,
};

/// 可配置的服务日志等级。
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn toStdLevel(self: LogLevel) @import("std").log.Level {
        return switch (self) {
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .err => .err,
        };
    }
};

/// 追加写入的服务日志文件策略。
pub const FileLogConfig = struct {
    path: []const u8,
    max_size_mb: u16 = 50,
    keep: u8 = 3,
};

/// 追加型 Event v2 JSONL 审计流的轮转策略。
pub const EventsConfig = struct {
    max_size_mb: u16 = 100,
    keep: u8 = 5,
};

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
    /// M4.2 F3: 可选的操作员友好标签，用于 CLI 显示和日志关联。
    /// null 时回退到 name。
    source_label: ?[]const u8 = null,
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
    /// 安装 profile 默认只允许显式 rearm 后执行一次，避免 PXE-first 固件重复擦盘。
    reinstall_policy: ReinstallPolicy = .explicit,
};

pub const ReinstallPolicy = enum { explicit, always };

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
    /// M4.1 的跨发行版目标系统事实。安装和后续无盘链路都消费此字段。
    system: TargetSystemConfig = .{},
    /// install mode 的安装器输入。保留 optional 以兼容 M3 catalog/boot
    /// fixture；M4 renderer 对缺省值采用安全的最小安装配置。
    install: ?InstallConfig = null,
};

pub const LocalizationConfig = struct {
    locale: []const u8 = "en_US.UTF-8",
    timezone: []const u8 = "UTC",
    keyboard: []const u8 = "us",
};

pub const ConnectivityMode = enum { @"local-only" };
pub const ConnectivityPolicy = struct {
    mode: ConnectivityMode = .@"local-only",
    time_sync: bool = false,
    ntp_servers: []const []const u8 = &.{},
};

pub const RootLoginPolicy = enum { no, @"prohibit-password", yes };
pub const SshConfig = struct {
    enabled: bool = true,
    password_authentication: bool = true,
    root_login: RootLoginPolicy = .yes,
    /// 配置中的密码字段刻意为明文事实；适配器仅在内存中推导 `$6$` 哈希。
    root_password: ?[]const u8 = "asdf1234",
    root_authorized_keys: []const []const u8 = &.{},
};

pub const FirewallPolicy = enum { disabled, enabled };
pub const SelinuxMode = enum { disabled, permissive, enforcing };
pub const TargetSecurityConfig = struct {
    firewall: FirewallPolicy = .disabled,
    selinux: SelinuxMode = .disabled,
};

pub const TargetUserConfig = struct {
    name: []const u8,
    password: ?[]const u8 = null,
    sudo: bool = false,
    ssh_authorized_keys: []const []const u8 = &.{},
};

/// M4.2 默认目标账号。配置显式写入 `system.users: []` 时仍可选择 root-only。
pub const default_target_users = [_]TargetUserConfig{.{
    .name = "nodeforge",
    .password = "asdf1234",
    .sudo = true,
}};

pub fn targetUsersAreImplicitDefault(users: []const TargetUserConfig) bool {
    return users.ptr == default_target_users[0..].ptr;
}

/// 目标系统通用事实，刻意独立于安装器语法。
pub const TargetSystemConfig = struct {
    localization: LocalizationConfig = .{},
    connectivity: ConnectivityPolicy = .{},
    ssh: SshConfig = .{},
    security: TargetSecurityConfig = .{},
    users: []const TargetUserConfig = &default_target_users,
    packages: []const []const u8 = &.{},
};

pub const NetworkMode = enum { dhcp, static };
pub const TargetNetworkConfig = struct {
    mode: NetworkMode = .dhcp,
    interface: ?[]const u8 = null,
    match_mac: ?[]const u8 = null,
    address: ?[]const u8 = null,
    prefix_len: ?u8 = null,
    gateway: ?[]const u8 = null,
    dns: []const []const u8 = &.{},
    search_domains: []const []const u8 = &.{},
};

pub const NodeOverrideConfig = struct { network: ?TargetNetworkConfig = null };

/// 安装器输入配置，由 profile 引用以渲染 Kickstart/Autoinstall answer 文件。
/// 所有字段在配置校验阶段已验证安全性；渲染器直接使用这些值生成安装脚本。
pub const InstallConfig = struct {
    /// 存储布局配置；M4 渲染器根据 boot_mode 和 partition_table 生成分区指令。
    storage: StorageConfig = .{},
    /// 引导加载器安装配置；控制是否在目标磁盘上安装 GRUB。
    bootloader: BootloaderInstallConfig = .{},
    /// Ubuntu APT 安装策略。默认允许使用 live ISO/squashfs 离线安装；
    /// 严格验收本地 HTTP mirror 时应显式设为 `abort`。
    apt: AptInstallConfig = .{},
    /// 额外安装的包名列表；渲染器将其写入 `%packages`（Kickstart）或 `packages`（Autoinstall）段。
    packages: []const []const u8 = &.{},
    /// 创建的用户列表；Kickstart 渲染为 `user` 指令，Autoinstall 渲染为 `identity` 段。
    users: []const UserConfig = &.{},
    /// SSH 公钥列表；渲染器将其写入安装后配置的 authorized_keys。
    ssh_authorized_keys: []const []const u8 = &.{},
    /// 可选的后处理 bundle 名称；引用 `AppConfig.provisioning_bundles` 中的条目。
    /// 渲染器将 bundle 中的步骤展开为安装后 shell 命令（`%post` 或 `late-commands`）。
    bundle: ?[]const u8 = null,
};

/// Subiquity 在所有候选 APT mirror 均不可用时的处理策略。
///
/// 枚举标签刻意与 autoinstall schema 和 JSON 配置中的连字符值完全一致，
/// 因此 `config import/export` 不需要额外字符串映射。
pub const AptFallback = enum {
    /// 立即终止安装；用于要求 HTTP APT mirror 必须可用的严格验收。
    abort,
    /// 回退到 live ISO 的 squashfs/离线介质。现有 profile 的兼容默认值。
    @"offline-install",
    /// mirror 不可用仍继续；Subiquity 官方不推荐，通常会在后续包阶段失败。
    @"continue-anyway",
};

/// Ubuntu autoinstall 的 APT 策略子配置。
/// 独立命名空间便于后续加入 mirror probe、suite 或更新策略，避免继续向
/// 通用 `InstallConfig` 平铺 Ubuntu 专属字段。
pub const AptInstallConfig = struct {
    fallback: AptFallback = .@"offline-install",
};

/// 磁盘存储布局配置。M4 渲染器根据此配置生成 Kickstart `part` 指令或
/// Autoinstall `storage` 段。当 `partitions` 为空时使用安全默认值。
pub const StorageConfig = struct {
    /// 是否在分区前擦除磁盘所有分区表。MVP 默认为 true，确保安装环境干净。
    wipe: bool = true,
    /// 主启动磁盘设备路径；Kickstart 的 `clearpart --drives` 和 `bootloader --boot-drive` 使用此值。
    /// 值格式为 Linux 设备路径（如 `/dev/sda`），渲染时去掉 `/dev/` 前缀。
    boot_disk: []const u8 = "/dev/sda",
    /// 参与安装的磁盘列表；MVP 只使用 `boot_disk`，此字段为未来多磁盘安装预留。
    install_disks: []const []const u8 = &.{"/dev/sda"},
    /// 固件启动模式；决定是否创建 ESP 分区（UEFI）或 biosboot 分区（BIOS）。
    boot_mode: BootMode = .uefi,
    /// 分区表类型；GPT 是 UEFI 的默认要求，MBR 用于旧式 BIOS。
    partition_table: PartitionTable = .gpt,
    /// 显式分区列表；为空时渲染器使用安全默认布局（ESP + swap + root）。
    partitions: []const PartitionConfig = &.{},
};

/// 固件启动模式。UEFI 是现代服务器的默认模式；BIOS 用于旧式硬件。
/// 此值影响分区类型选择和引导加载器安装方式。
pub const BootMode = enum { uefi, bios };

/// 分区表类型。GPT 是 UEFI 的标准要求；MBR 用于旧式 BIOS 系统。
pub const PartitionTable = enum { gpt, mbr };

/// 分区用途类型。渲染器根据此值选择默认的文件系统和挂载点。
pub const PartitionKind = enum {
    /// EFI System Partition，UEFI 启动必需，FAT32 格式。
    esp,
    /// BIOS Boot Partition，GPT + BIOS 启动时 GRUB 需要的嵌入分区。
    biosboot,
    /// 交换分区。
    swap,
    /// 根分区。
    root,
    /// /boot 分区，部分发行版需要独立分区。
    boot,
    /// 通用分区，由调用方指定挂载点和文件系统。
    plain,
};

/// 单个分区的配置。`mount` 和 `filesystem` 为 null 时由渲染器按 `kind` 推导默认值。
pub const PartitionConfig = struct {
    /// 挂载点路径；null 时按 kind 推导（swap→"swap"，esp→"/boot/efi"等）。
    mount: ?[]const u8 = null,
    /// 分区大小（MiB）；0 表示使用剩余空间（仅 root 分区适用）。
    size_mib: u32 = 0,
    /// 文件系统类型；null 时按 kind 推导（esp→"efi"，swap→"swap"，其他→"xfs"）。
    /// Kickstart 使用此值作为 `--fstype` 参数。
    filesystem: ?[]const u8 = null,
    /// 分区用途；决定渲染器的默认行为。
    kind: PartitionKind = .plain,
};

/// 引导加载器安装配置。控制是否在目标磁盘上安装 GRUB 及其配置方式。
pub const BootloaderInstallConfig = struct {
    /// 是否安装引导加载器；false 时跳过 `bootloader` 指令，适用于已有引导管理的环境。
    install: bool = true,
    /// 安装目标；默认引用 `storage.boot_disk`，渲染器将其解析为实际设备路径。
    target: []const u8 = "storage.boot_disk",
    /// 是否在安装后设置固件启动顺序；MVP 默认 false，由操作员手动确认。
    set_firmware_boot_order: bool = false,
};

/// M4 兼容拼写；M4.1 将其规范化为 `profile.system.users`。
pub const UserConfig = TargetUserConfig;

/// 后处理执行阶段。M4 只实现 `install_post`（安装后）；
/// 后续阶段（如 `first_boot`、`runtime`）在 M7 补充。
pub const ProvisionPhase = enum { install_post };

/// 后处理动作类型。M4 只实现这三种受约束动作；
/// 任意脚本执行在 M7 作为 `script` 动作补充。
pub const ProvisionAction = enum {
    /// 添加软件仓库（dnf config-manager 或 apt sources.list）。
    repository,
    /// 安装标准软件包（dnf install 或 apt-get install）。
    standard_packages,
    /// 写入受管文件（使用 heredoc 创建指定路径的文件）。
    managed_file,
};

/// 单个后处理步骤。渲染器按 `action` 类型生成对应的 shell 命令。
/// 每种 action 只使用与之相关的字段，其余字段应保持 null/空。
pub const ProvisionStep = struct {
    /// 步骤名称；用于日志和审计，不进入生成的 shell 脚本。
    name: []const u8,
    /// 执行阶段；M4 只支持 `install_post`。
    phase: ProvisionPhase = .install_post,
    /// 动作类型；决定使用哪些字段以及生成何种 shell 命令。
    action: ProvisionAction,
    /// `repository` 动作使用的仓库 URL 或 repo 文件内容；dnf 和 apt 的处理方式不同。
    repository: ?[]const u8 = null,
    /// `standard_packages` 动作要安装的包名列表；为空时渲染器返回错误。
    packages: []const []const u8 = &.{},
    /// `managed_file` 动作的文件内容；使用 heredoc 写入目标路径。
    content: ?[]const u8 = null,
    /// `managed_file` 动作的目标路径；必须是绝对路径且不含 `..`，防止路径逃逸。
    destination: ?[]const u8 = null,
};

/// 可复用的后处理步骤集合。通过 profile.install.bundle 引用。
/// 同一 bundle 可被多个 profile 共享，减少配置重复。
pub const ProvisioningBundle = struct {
    /// bundle 名称；profile.install.bundle 引用此值。
    name: []const u8,
    /// bundle 版本；用于未来兼容性检查，M4 不强制校验。
    version: []const u8 = "1",
    /// 有序步骤列表；渲染器按声明顺序生成 shell 命令。
    steps: []const ProvisionStep = &.{},
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
    /// 节点特定的目标配置。PXE 引导阶段始终保持 DHCP。
    overrides: NodeOverrideConfig = .{},
    /// M4.2 F2: 节点是否参与 PXE 部署。`false` 时即使 MAC/IP/profile 匹配，
    /// resolve() 也不下发 PXE bootfile，仍发诊断 DHCP lease。适用于 install/diskless/discovery 全模式。
    /// 通过 `node set <id> --deploy false` 管理。与 generation gate 互补不冗余。
    deploy: bool = true,
    /// M4.2 F4: 节点是否使用 HTTP 加速下载 initrd。
    /// **默认 `false`**。`true` 时 GRUB 配置中的 initrd 路径渲染为
    /// `(http,server:port)/boot/<path>`，通过 TCP HTTP 下载，利用 TCP 窗口
    /// 达到接近线速的吞吐。kernel 始终走 TFTP（GRUB EFI 内存限制，见下方）。
    /// `false` 时 kernel/initrd 均通过 TFTP 下载。
    ///
    /// **实验性功能**：`http_accel=true` 在实测中发现 GRUB 的 TCP/HTTP 模块
    /// 会占用大量 EFI 连续内存页（发送/接收缓冲、TCP 控制块等），导致剩余
    /// 连续内存不足以分配 kernel 缓冲区（`grub_efi_allocate_pages()` 失败），
    /// 报出 `can not alloc kernel buffer` 或 `out of memory`。即使 kernel 走
    /// TFTP，GRUB 为 initrd 建立 TCP 连接时仍可能触发 EFI 内存碎片化，
    /// 导致后续 kernel 加载失败。因此默认禁用，仅在确认目标 GRUB 构建和
    /// EFI 固件内存充裕时才可尝试启用。
    ///
    /// GRUB 的 TFTP 客户端不支持 RFC 7440 windowsize，大文件（100+ MB initrd）
    /// 在 TFTP 模式下受 RTT 限制仅约 2 MB/s。
    /// 仅对 GRUB UEFI 链路生效；M6 BIOS PXELINUX 固定使用 `pxelinux.0`
    /// （只支持 TFTP），此字段对 BIOS 节点无效。
    /// 通过 `node set <id> --http-accel true` 启用。
    http_accel: bool = false,
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
