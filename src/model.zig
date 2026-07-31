//! # NodeForge 强类型事实模型
//!
//! 本模块定义 NodeForge 全系统共享的配置与目录事实源。所有协议层（DHCP/TFTP/HTTP）、
//! CLI、安装渲染器和状态机都直接消费这些强类型结构体，禁止各自解析弱类型 JSON。
//!
//! ## 两层事实源
//!
//! - [`AppConfig`]：启动配置 `<install-root>/config/config.json`，包含服务网、端口、
//!   DHCP 地址池和容量策略等站点级参数。只保存启动/策略输入，不保存 catalog 实体。
//! - [`Catalog`]：管理目录 `<install-root>/catalog/`，由 `nodeforged` 独占写入。
//!   包含 distro、profile、node、repository、asset、install_source 等 daemon-owned 实体。
//!
//! ## v0.1 所有权边界
//!
//! v0.1（M4.13）将物理设备选择器从 Profile 迁移到 Node 直接属性（`node.storage`），
//! Profile 只保留共享部署策略（wipe/partition/bootloader）。平台能力（distro/version/arch）
//! 由 install_source 资源派生，Profile 不再独立声明。

/// NodeForge 启动配置事实源 `<install-root>/config/config.json` 的根对象。
///
/// 该文件由 `nodeforge setup --reconfigure` 写入，daemon 启动时只读加载。
/// distros/profiles/nodes/provisioning_bundles 由 Catalog 独占持久化，
/// 此处只保留投影字段以缩小协议模块的破坏面。
pub const AppConfig = struct {
    /// 配置文件 schema 版本。永久默认 4（最新）；setup 始终生成 v4，不存在版本迁移。
    schema_version: u32 = 4,
    /// 单进程服务配置：实例名称、PXE 网卡、服务网 IP 和 HTTP 端口。
    server: ServerConfig,
    /// HTTP 大文件和发行版仓库目录配置。
    http: HttpConfig = .{},
    /// TFTP 只读启动资产根目录；监听端口固定为 UDP 69，不进入配置。
    tftp: TftpConfig = .{},
    /// PXE 管理网 DHCPv4 策略；监听端口固定为 UDP 67，不进入配置。
    dhcp: DhcpConfig = .{},
    /// M4.8 共享状态表的运行时有效容量覆盖。省略时按节点数/CPU 核数自动派生。
    capacity: CapacityConfig = .{},
    /// 服务日志等级；daemon `--debug` 可在本次启动临时覆盖为 debug。
    logging: LoggingConfig = .{},
    /// 业务事件审计流（events.jsonl）的轮转策略。
    events: EventsConfig = .{},
    /// Catalog 实体投影字段；config.json 不持久化这些字段，
    /// 运行时通过 [`projectCatalog`] 从 Catalog 投影到这里，以缩小协议模块的破坏面。
    distros: []const DistroConfig = &.{},
    /// 节点可绑定的安装策略模板。投影自 `Catalog.profiles`。
    profiles: []const ProfileConfig = &.{},
    /// 已录入节点。投影自 `Catalog.nodes`。
    nodes: []const NodeConfig = &.{},
    /// 可复用的后处理步骤集合。投影自 `Catalog.provisioning_bundles`。
    provisioning_bundles: []const ProvisioningBundle = &.{},
};

/// NodeForge 管理目录事实源 `<install-root>/catalog/` 的根对象。
///
/// 该文件只由 `nodeforged` 通过 catalog store 原子事务写入，CLI 不直接编辑。
/// 磁盘布局为 manifest + 8 个 entity 文件，内存模型由本结构体表达。
pub const Catalog = struct {
    /// 内存 catalog schema 版本。永久默认 5（最新）；setup 始终生成 v5，不存在版本迁移。
    /// 磁盘布局另由 manifest schema 约束。
    schema_version: u32 = 5,
    /// manifest 的单调 catalog revision；每次原子事务提交递增。legacy 单文件输入为 0。
    revision: u64 = 0,
    /// ISO 导入后自动形成的发行版能力索引。非操作员手动创建的策略对象。
    distros: []const DistroConfig = &.{},
    /// 可复用的安装策略模板。Profile 描述多节点共享的部署期望，不含物理设备选择器。
    profiles: []const ProfileConfig = &.{},
    /// 已录入节点。Node 描述单台机器的身份、直接配置和物理绑定。
    nodes: []const NodeConfig = &.{},
    /// 可复用的后处理步骤集合。通过 profile.install.post_install.bundle 引用。
    provisioning_bundles: []const ProvisioningBundle = &.{},
    /// 可由 dnf/apt 直接使用的软件仓库。ISO 导入自动生成本地仓库。
    repositories: []const RepositoryConfig = &.{},
    /// 已纳管的 ISO、内核、initrd、bootloader 和 GPG key 等文件资产。
    assets: []const AssetConfig = &.{},
    /// 自动安装入口，关联 ISO、安装内核、initrd 和仓库，供 profile 引用。
    install_sources: []const InstallSourceConfig = &.{},
    /// 无盘启动所需的同版本 kernel、initrd 和 rootfs 组合（v0.2 范围）。
    boot_bundles: []const BootBundleConfig = &.{},
    /// Daemon-owned singleton，控制未知 DHCP 客户端的处理策略。
    /// v0.1 默认 `record`：分配诊断 lease、记录观察事实，不下发 PXE bootfile。
    discovery_policy: DiscoveryPolicy = .{},
    /// 持久化的未知 DHCP 客户端观察记录。与临时 DHCP lease 分开存储和过期清理。
    unknown_client_observations: []const UnknownClientObservation = &.{},
};

/// 未知 DHCP 客户端的站点级处理动作。
///
/// v0.1 删除了 `install` 和 `diskless` 动作——未知节点永远不允许自动安装。
/// `discovery` 作为 Profile mode 也已删除。
pub const UnknownAction = enum {
    /// 分配诊断 DHCP lease、记录观察事实，但不下发 PXE bootfile。
    record,
    /// 不分配 lease、不记录观察，直接忽略未知客户端。
    deny,
};

/// 未知 DHCP 客户端的发现策略。Daemon-owned singleton。
///
/// 替代旧 schema 中的 `PolicyConfig`。v0.1 不再支持未知节点自动安装或无盘启动。
pub const DiscoveryPolicy = struct {
    /// 未知客户端的默认处理动作。v0.1 默认 `record`。
    unknown_action: UnknownAction = .record,
    /// 观察记录的保留天数。超期记录由后台清理删除。
    observation_retention_days: u32 = 30,
    /// 策略 revision，用于乐观并发控制。
    revision: u64 = 1,
};

/// 观察记录的认领审计。当操作员将未知客户端认领为 Node 时记录。
pub const ObservationClaim = struct {
    /// 认领创建或绑定的 Node ID。
    node_id: []const u8,
    /// 认领操作的 Unix 时间戳（秒）。
    claimed_at_unix: i64,
};

/// 持久化的未知 DHCP 客户端观察记录。
///
/// 当未录入节点发起 DHCP 请求时，daemon 按 `discovery_policy` 记录观察事实。
/// 操作员可通过 CLI 查看观察列表并执行原子认领（`node claim`），将其转换为 Node。
pub const UnknownClientObservation = struct {
    /// 客户端网卡 MAC 地址（冒号分隔）。观察记录的主键。
    mac: []const u8,
    /// DHCP option 61 client identifier；可辅助身份匹配，不作为主键。
    dhcp_client_id: ?[]const u8 = null,
    /// 从 RFC 4578 PXE 架构选项推导的处理器架构。
    observed_architecture: ?Arch = null,
    /// DHCP option 60 vendor class identifier。
    vendor_class: ?[]const u8 = null,
    /// 首次观察到该客户端的 Unix 时间戳（秒）。
    first_seen_unix: i64,
    /// 最近一次观察到该客户端的 Unix 时间戳（秒）。
    last_seen_unix: i64,
    /// 最近一次分配的 DHCP 地址（点分 IPv4）。
    last_ip: ?[]const u8 = null,
    /// 累计 DHCP 请求计数。
    request_count: u64 = 1,
    /// 观察 revision，用于乐观并发控制（认领时防竞争）。
    revision: u64 = 1,
    /// 认领审计；null 表示尚未被认领。
    claim: ?ObservationClaim = null,
};

/// 将 daemon-owned catalog 实体投影到协议代码读取的 AppConfig 视图。
///
/// 旧代码通过 `config.distros`/`config.profiles` 等字段访问实体数据。
/// 这些实体只存在于 Catalog，此函数将它们投影到 AppConfig 的
/// 对应字段，避免修改所有协议模块的读取入口。
///
/// 返回值只借用两侧内存，不得越过 config/catalog snapshot 生命周期。
pub fn projectCatalog(config: AppConfig, catalog: *const Catalog) AppConfig {
    var projected = config;
    projected.distros = catalog.distros;
    projected.profiles = catalog.profiles;
    projected.nodes = catalog.nodes;
    projected.provisioning_bundles = catalog.provisioning_bundles;
    return projected;
}

/// 单进程服务配置。定义 PXE 服务网卡、广告地址和 HTTP 监听端口。
pub const ServerConfig = struct {
    /// 用于日志和状态输出的实例名称。不影响网络行为。
    name: []const u8 = "nodeforge",
    /// PXE 服务网卡名称。DHCPv4 Linux 服务要求该字段非空，并以它限制广播收发。
    /// 示例中的 `enp1s0` 只是占位值，部署前必须替换为承载 `server_ip` 的实际网卡。
    bind_interface: ?[]const u8 = null,
    /// PXE 服务网对外 IPv4 地址；用于生成 HTTP/TFTP URL、DHCP next-server 等广告地址。
    /// HTTP listener 仍绑定 `0.0.0.0`，不把该字段作为 bind 地址。
    server_ip: []const u8,
    /// 唯一 HTTP 监听端口；同时承载 PXE 数据路由和管理路由。CLI 固定使用 loopback 访问。
    /// 默认 18080，避免与常见 Web 服务（8080）冲突。配置文件可显式覆盖。
    http_port: u16 = 18080,
    /// 注入所有目标节点 authorized_keys 的管理公钥。第一个 key 是 bootstrap key，
    /// 其余 key 用于操作员或审计员访问；私钥绝不进入配置。
    ssh_authorized_public_keys: []const []const u8 = &.{},
};

/// HTTP 大文件和发行版仓库目录配置。
pub const HttpConfig = struct {
    /// rootfs、ISO 和普通 HTTP 资产根目录。
    /// M4.7 取消编译期安装根：setup 必须写出运行时解析后的绝对路径。
    asset_root: []const u8 = "",
    /// 通过 `/artifacts/repositories/` 只读发布的仓库根目录。
    repository_root: []const u8 = "",
    /// M4.2 F4 / M4.8: 最大并发 HTTP 连接数。0 = 不限制。
    /// **当前为 advisory、未强制**：facil.io/zap 不暴露应用级连接上限，真正的并发墙在
    /// OS 层（`ulimit -n`/`LimitNOFILE`，每下载 ~2 fd）。M6 压测后接上强制并设生产默认值。
    /// 运维在 M6 前应直接提 `LimitNOFILE ≥ 8192` 而非依赖此字段。
    max_connections: u16 = 0,
};

/// TFTP 启动小文件配置。
///
/// 端口是 PXE 协议约定，固定在服务实现中（UDP 69）；此处只允许声明只读根目录，
/// 防止把每项传输参数扩散为难以维护的 CLI 参数。
pub const TftpConfig = struct {
    /// bootloader、GRUB 配置、kernel 和 initrd 的只读根目录。
    asset_root: []const u8 = "",
    /// M4.2 F4: OACK 中通告的最大 TFTP windowsize（RFC 7440）。
    /// 0 禁用 windowsize 协商（RFC 1350 停止等待模式）。
    /// 接受 1-65535 的值；客户端可以请求更小的值。
    windowsize: u16 = 4,
    /// 服务端提供并作为上限的最大 TFTP 块大小（RFC 2348 blksize option）。
    /// 默认 1468 是以太网 MTU 最优值：1500 − 20 (IP) − 8 (UDP) − 4 (TFTP)，
    /// 使每个 DATA 包恰好填满一个以太网帧而不触发 IP 分片。它只作为客户端
    /// 明确请求 blksize 时的服务端上限；OACK 不增加未请求的 option，也不把
    /// 客户端请求值放大。jumbo-frame 链路可调高，受限链路调低。
    /// 必须在 RFC 2348 允许的 8..65464 范围内。
    max_blksize: u16 = 1468,
    /// M4.8: 全局并发 TFTP 传输上限（非 per-client；PXE 客户端顺序取文件，
    /// per-client > 1 无意义，全局才是正确的批量部署节流）。
    /// 省略时启动按 `max(128, 2×cpu_cores)` 自动派生；显式给出则按配置。
    /// 每个 RRQ 启动一个独立线程，拥有自己的 TID socket；1 保留串行行为。
    max_concurrent_transfers: ?u16 = null,
};

/// M2 authoritative DHCPv4 的最小站点级地址池。
///
/// 端口不会进入配置——DHCP 监听固定为 UDP 67，TFTP 固定为 UDP 69。
/// 所有字段都是站点级策略，不按节点覆盖。
pub const DhcpConfig = struct {
    /// PXE 管理网 CIDR 子网（如 `192.168.50.0/24`）。
    subnet: []const u8 = "192.168.50.0/24",
    /// 动态地址池起始 IP（点分 IPv4）。
    pool_start: []const u8 = "192.168.50.100",
    /// 动态地址池结束 IP（点分 IPv4）。
    pool_end: []const u8 = "192.168.50.200",
    /// 默认网关（DHCP option 3）；null 时不通告 gateway。
    router: ?[]const u8 = null,
    /// DNS 服务器列表（DHCP option 6）。
    dns: []const []const u8 = &.{},
    /// DHCP lease 有效期（秒）。
    lease_seconds: u32 = 1800,
    /// OFFER 的有效期（秒）；客户端在此时限内需用 REQUEST 确认。
    offer_seconds: u32 = 60,
    /// 被拒绝地址的隔离时间（秒）；隔离期满前该地址不可重新分配。
    abandon_seconds: u32 = 3600,
    /// 在 OFFER 前等待 ICMP Echo Reply 的超时时间（毫秒）。0 为非法值。
    /// daemon 需要 CAP_NET_RAW 能力；探测不可用时扣留 OFFER 而非将候选地址视为可用。
    /// M4.8: 默认 500->100，避免突发批量部署下空闲 IP 串行 ping 成为分数量级瓶颈。
    ping_timeout_ms: u16 = 100,
    /// M4.8: lease 并发容量显式覆盖。省略时按 `usable_hosts(subnet)` 派生；
    /// 给出则取 `max(派生, 此值)`。实际生效 = `min(派生, DhcpState.max_leases)`。
    max_leases: ?u32 = null,
};

/// 受管节点共享投影（status/inventory/deployment）的容量策略。
///
/// 这些是编译期安全天花板内的运行时覆盖，防止无限制分配导致内存耗尽。
pub const CapacityConfig = struct {
    /// 省略时按 config.nodes 数量派生；显式值只可放大派生值。
    /// 运行时仍受 2048 条编译期安全天花板约束。
    managed_entries: ?u32 = null,
    /// 单个 install boot session 可固定的完整 InstallPlan JSON 最大字节数。
    ///
    /// InstallPlan 保留 repository software_index.capabilities 的完整动态 slice，
    /// 因而大体量 DVD ISO 的计划可超过旧的 1 MiB 固定限制。null 表示不施加
    /// NodeForge 人为上限，由动态 slice、allocator 和系统可用内存自然约束。
    /// 非 null 值限制的是 JSON 快照字节数，不是 ISO 文件大小。
    install_plan_max_bytes: ?u64 = null,
};

/// 服务日志配置。业务事件仍写入独立的 `events.jsonl` 审计流。
pub const LoggingConfig = struct {
    /// 日常输出 info；debug 额外输出连接和协议诊断。
    level: LogLevel = .info,
    /// 可选文件路径与轮转策略；`--log-output auto` 配置它时选择双写。
    file: ?FileLogConfig = null,
};

/// 可配置的服务日志等级。映射到 `std.log.Level`。
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    /// 转换为 `std.log.Level`，供 `std.log` 机制使用。
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
    /// 日志文件绝对路径。
    path: []const u8,
    /// 单个日志文件最大大小（MB），超限后触发轮转。
    max_size_mb: u16 = 50,
    /// 保留的历史日志文件数量。
    keep: u8 = 3,
};

/// 追加型 Event v2 JSONL 审计流的轮转策略。
///
/// `events.jsonl` 记录所有业务事件（DHCP/TFTP/安装器回调等），
/// 与服务日志（stderr/journal）分离。
pub const EventsConfig = struct {
    /// 单个审计文件最大大小（MB），超限后触发轮转。
    max_size_mb: u16 = 100,
    /// 保留的历史审计文件数量。
    keep: u8 = 5,
};

/// 首期支持的处理器架构；生产优先 x86_64，开发验证优先 aarch64。
///
/// 枚举标签与 RFC 4578 PXE 架构类型对应：
/// - `x86_64` -> PXE 架构类型 7（x86_64 UEFI）
/// - `aarch64` -> PXE 架构类型 11（aarch64 UEFI）
pub const Arch = enum { x86_64, aarch64 };

/// 发行版家族决定安装器和标准包管理器。
///
/// 这是安装机制的唯一事实源：RHEL 系使用 Kickstart + dnf，
/// Ubuntu 系使用 Autoinstall + apt。不可通过配置覆盖。
pub const DistroFamily = enum { rhel, ubuntu };

/// 标准自动安装适配器。由 [`installAdapterForFamily`] 从 family 派生。
pub const InstallAdapter = enum { kickstart, autoinstall };

/// Profile 的部署类型。schema v4 支持 `install | diskless`。
/// 设计文档中的 `ProfileKind` 等价于此枚举（代码沿用 `BootKind`）。
pub const BootKind = enum {
    install,
    /// 内存无盘启动；当前固定为 squashfs lower + tmpfs overlay upper。
    diskless,
};

/// 设计文档使用的 `ProfileKind` 即代码 [`BootKind`]。
pub const ProfileKind = BootKind;

/// v0.2.3: Profile 创建/克隆来源审计信息。
pub const ProfileProvenance = struct {
    /// 创建来源：直接创建或克隆。
    origin: ProfileProvenanceOrigin = .create,
    /// 创建/克隆时的 install source 名称。
    install_source_name: []const u8 = "",
    /// 创建/克隆时的 catalog revision 快照。
    install_source_revision: u64 = 0,
    /// origin=clone 时非 null，记录 source Profile 信息。
    cloned_from: ?ClonedFrom = null,
};

/// v0.2.3: Profile 创建来源枚举。
pub const ProfileProvenanceOrigin = enum {
    create,
    clone,
};

/// v0.2.3: 克隆来源记录。
pub const ClonedFrom = struct {
    /// source Profile 名称。
    profile_name: []const u8,
    /// source Profile 的 revision 快照。
    profile_revision: u64 = 0,
    /// 克隆时的 catalog revision。
    catalog_revision: u64 = 0,
    /// 克隆时间（daemon UTC Unix seconds）。
    cloned_at: i64 = 0,
};

/// v0.2.3: Profile 绑定的 SSH identity 引用。private key 不进入 catalog，
/// 只保存 reference/revision/fingerprint。
pub const ProfileSshIdentityRef = struct {
    /// 32 字符小写十六进制，与 identity store 主键一致。
    id: []const u8 = "",
    /// identity revision，--new-ssh-keys 递增。
    revision: u64 = 1,
    /// SHA-256 base64 指纹（SSH 标准指纹格式）。
    client_public_fingerprint: []const u8 = "",
    /// SHA-256 base64 指纹。
    host_public_fingerprint: []const u8 = "",
};

/// 基础源及额外标准包使用的包管理器。由 [`packageManagerForFamily`] 从 family 派生。
pub const PackageManager = enum { dnf, apt };

/// family 是安装机制的唯一事实源；这些能力不是操作员输入。
///
/// RHEL family → Kickstart 适配器，Ubuntu family → Autoinstall 适配器。
pub fn installAdapterForFamily(family: DistroFamily) InstallAdapter {
    return switch (family) {
        .rhel => .kickstart,
        .ubuntu => .autoinstall,
    };
}

/// family 是仓库类型的唯一事实源；ISO 导入据此生成 dnf/apt repository。
///
/// RHEL family → dnf，Ubuntu family → apt。
pub fn packageManagerForFamily(family: DistroFamily) PackageManager {
    return switch (family) {
        .rhel => .dnf,
        .ubuntu => .apt,
    };
}

/// 资产类型枚举。用于阻止把 ISO、内核和 initrd 错接到其他位置。
///
/// 每种类型有特定的校验规则和发布路径约束。
pub const AssetKind = enum {
    /// 完整 ISO 镜像。导入后通过 loop mount 发布安装媒体树。
    iso,
    /// PXE bootloader（如 GRUB EFI 二进制 `grubaa64.efi`）。
    bootloader,
    /// 安装器内核（vmlinuz）。由 ISO 提取或独立导入。
    kernel,
    /// 运行时内核（v0.2 范围）。由本地内核包 + modules closure 派生，与 installer kernel 区分。
    runtime_kernel,
    /// 安装器 initrd（initrd.img）。由 ISO 提取或独立导入。
    installer_initrd,
    /// NodeForge 定制小 initrd（v0.2 无盘启动用）。由 dracut 模块构建。
    nodeforge_initrd,
    /// 无盘 rootfs（v0.2 范围）。squashfs 压缩文件系统镜像。
    rootfs,
    /// GPG 公钥资产。仅当 `repository.gpg_check = true` 时引用。
    gpg_key,
    /// 受管文件资产。由 provision `managed_file` 动作通过 HTTP 分发。
    managed_file,
    /// 归档资产（v0.2 范围）。tar/cpio 等受管归档，由 `archive` 动作解压到目标。
    archive,
    /// 脚本资产（v0.2 范围）。受管可执行脚本，由 `script` 动作在受控上下文中执行。
    script,
};

/// ISO 导入后自动形成的发行版能力索引。
///
/// 它不是要求操作员先创建的策略对象；同一产品的新版本/架构由导入事务增量补齐。
/// 例如导入 Rocky 9.7 aarch64 ISO 后自动添加 rocky/9.7/aarch64 能力条目。
pub const DistroConfig = struct {
    /// 稳定短名称，例如 rocky、alma、rhel、fedora 或 ubuntu。
    name: []const u8,
    /// RHEL 系和 Ubuntu 使用不同安装及仓库适配器。
    family: DistroFamily,
    /// 当前项目实际允许使用的版本列表。
    versions: []const DistroVersionConfig = &.{},
};

/// 发行版版本与架构能力矩阵。
///
/// adapter/package manager 由 family 唯一派生，保留在持久模型中用于
/// 自描述导出和旧 schema 兼容。
pub const DistroVersionConfig = struct {
    /// 上游版本字符串，保留 9.7、22.04 这类原始表达。
    version: []const u8,
    /// 此版本已经验证或计划支持的架构。
    archs: []const Arch = &.{},
    /// 自动安装配置格式（Kickstart/Autoinstall）。
    install_adapter: InstallAdapter,
    /// 标准包安装工具（dnf/apt）。
    package_manager: PackageManager,
};

/// 由标准 ISO 或显式外部地址产生的 dnf/apt 仓库。
///
/// ISO 导入自动在本地 HTTP 发布路径生成同名仓库；
/// 外部 mirror 通过显式配置添加。
pub const RepositoryConfig = struct {
    /// 稳定短名称，用于 profile 和 install source 引用。
    name: []const u8,
    /// 所属发行版名称，必须能在 `Catalog.distros` 中找到。
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
    /// 从 repomd.xml/Packages 解析的软件能力索引。catalog 发布前生成。
    /// revision_digest 变化时表示仓库内容已更新，引用该仓库的 install plan 需要重新计算。
    software_index: SoftwareIndex = .{},
};

/// 软件能力类型。区分 RHEL comps 和 Ubuntu task 体系。
pub const SoftwareKind = enum {
    /// RHEL comps environment（`@^minimal-environment`）。
    environment,
    /// RHEL comps group（`@core`）。
    group,
    /// Ubuntu task（`ubuntu-desktop`）。
    task,
    /// Ubuntu metapackage（`ubuntu-server`）。
    metapackage,
    /// 普通软件包（`vim`）。
    package,
};

/// 单个软件能力条目。由 repository software index 提取。
pub const SoftwareCapability = struct {
    /// 能力唯一标识（包名、group 名或 task 名）。
    id: []const u8,
    /// 人类可读名称。
    name: []const u8,
    /// 能力类型。
    kind: SoftwareKind,
    /// 可选描述文本。
    description: ?[]const u8 = null,
};

/// 仓库软件能力索引。随 repository 一起持久化。
pub const SoftwareIndex = struct {
    /// 索引内容的 SHA-256 摘要。内容变化时摘要变化，触发 plan digest 重新计算。
    revision_digest: ?[]const u8 = null,
    /// 该仓库提供的全部能力条目列表。
    capabilities: []const SoftwareCapability = &.{},
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
    /// 内核相关资产可记录完整的 Linux UTS release（目标内核 `uname -r`），
    /// 便于验证 kernel/rootfs/modules ABI 一致。此值保持发行版原貌：RHEL
    /// 通常包含 `.x86_64`/`.aarch64`，Ubuntu 通常不包含包架构后缀。
    kernel_release: ?[]const u8 = null,
    /// 导入阶段计算的 SHA-256 摘要；M0 允许为空，后续发布资产时必须存在。
    sha256: ?[]const u8 = null,
    /// 资产 revision，用于乐观并发控制。
    revision: u64 = 1,
    /// 文件大小（字节）；导入阶段计算。
    size: ?u64 = null,
    /// MIME 媒体类型（如 `application/x-iso9660-image`）；HTTP 响应 Content-Type 使用。
    media_type: ?[]const u8 = null,
};

/// PXE 自动安装入口使用的完整关联，不让 profile 直接拼散乱文件名。
///
/// 一个 install source 绑定 ISO、安装内核、initrd 和仓库引用，
/// profile 通过 `install_source` 字段引用此对象。
pub const InstallSourceConfig = struct {
    /// ISO basename 派生（或受控覆盖）的完整基础名，可追加导入限定符；
    /// Profile 必须以它为前缀并显式携带 install/diskless 角色后缀。
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
    /// 受管安装媒体树 URL；它不代表可由包管理器消费的 repository。
    /// Anaconda 通过 `url --url=` 消费，Subiquity 通过 `apt.primary.uri` 消费。
    media_tree_url: ?[]const u8 = null,
    /// 关联仓库名称列表；每个名称必须能在 catalog.repositories 中找到。
    repositories: []const []const u8 = &.{},
    /// Ubuntu casper OS 层 layer 清单（base→top 有序），供 rootfs-build 的
    /// casper squashfs overlay 构建使用；仅 `distro_family == .ubuntu` 时非空。
    /// 追加字段，默认空 slice，catalog schema v4 无需迁移即可兼容旧文件。
    casper_layers: []const CasperLayer = &.{},
};

/// casper/ 目录下单个 squashfs layer 的身份信息（路径相对 casper/、大小、
/// SHA-256），在 `assets import` 挂载 ISO 时一次性发现并记录；build 阶段
/// ISO 已卸载，daemon 只能读取已发布的资产，不能重新扫描。
pub const CasperLayer = struct {
    /// casper/ 下的相对路径，如 "ubuntu-server-minimal.squashfs"。
    path: []const u8,
    size: u64,
    sha256: []const u8,
};

/// 无盘启动的不可拆分版本组合（v0.2 范围）。
///
/// kernel 与 initrd 必须来自同一发行版版本和架构，kernel_release 必须一致。
/// rootfs 是由 Profile build projection 派生的内容寻址制品，不能放进 bundle，
/// 否则会形成「创建 Profile 需要 bundle、构建 rootfs 又需要 Profile」的环。
pub const BootBundleConfig = struct {
    /// 规范名称以完整 InstallSource 开头并以 `-diskless-bundle` 结尾；
    /// 中间可有用途/内核限定符，与 diskless Profile 名明确区分。
    name: []const u8,
    /// 所属发行版名称。
    distro: []const u8,
    /// 所属发行版版本。
    version: []const u8,
    /// 目标架构。
    arch: Arch,
    /// 内核 release 字符串，kernel/initrd 必须一致。
    kernel_release: []const u8,
    /// 内核资产名称；必须指向 kind 为 `kernel` 的资产。
    kernel: []const u8,
    /// 运行时内核资产名称（v0.2）。必须指向 kind 为 `runtime_kernel` 的资产；
    /// 与目标 rootfs 的 modules ABI 一致。v4 起由 bundle 固定，不再把派生 rootfs 塞入 bundle。
    runtime_kernel: ?[]const u8 = null,
    /// NodeForge 小 initrd 资产名称；必须指向 kind 为 `nodeforge_initrd` 的资产。
    initrd: []const u8,
};

/// profile 的安全元数据，供未知节点策略做静态判断。
///
/// 这些是 profile 级安全声明，不是一次安装的 arm 状态。
/// install profile 必须满足 `destructive=true` + `persistent_writes=true`。
pub const ProfileSafetyConfig = struct {
    /// 是否允许未知节点使用此 profile；safe/ephemeral profile 必须为 true。
    safe_for_unknown: bool = false,
    /// 是否授权该 profile 包含擦盘、格式化等不可逆操作。
    /// install profile 必须为 true。
    destructive: bool = false,
    /// 是否写入持久状态；safe/ephemeral profile 必须为 false。
    persistent_writes: bool = false,
    /// 安装 profile 默认只允许显式 rearm 后执行一次，避免 PXE-first 固件重复擦盘。
    /// `always` 允许每次 PXE 都重装；仅用于安全测试环境。
    reinstall_policy: ReinstallPolicy = .explicit,
};

/// 重装策略枚举。
pub const ReinstallPolicy = enum {
    /// 只允许显式 rearm 后执行一次安装。install profile 的默认值。
    explicit,
    /// 每次 PXE 都触发重装。仅用于安全测试环境。
    always,
};

/// schema v4 的 install/diskless 共用 Profile 配置。
///
/// Profile 是可复用、可版本化的部署期望模板。它描述多台节点共享的安装策略，
/// 不含物理设备选择器（`boot_disk` 等已迁移到 [`NodeConfig.storage`]）。
///
/// 平台能力（distro/version/arch）由 `install_source` 资源派生，Profile 不再独立声明。
pub const ProfileConfig = struct {
    /// 稳定短名称，用于 node 引用。
    name: []const u8,
    /// 引用的 install source 资源名称。平台能力（distro/version/arch）由此派生。
    /// install 与 diskless Profile 都从 InstallSource 创建/派生，共用同一 source。
    install_source: []const u8,
    /// Profile 部署类型（schema v4+ tagged kind）。v3 迁移后 install Profile 为 `.install`。
    kind: ProfileKind = .install,
    /// v0.2.3: Profile 级单调递增 revision，初始值 1。每次 Profile mutation 成功后递增 1。
    /// 不等于 catalog revision；不因无关 catalog mutation 改变。
    revision: u64 = 1,
    /// v0.2.3: Profile 首次创建的 daemon UTC Unix seconds，创建后不可变。
    created_at: i64 = 0,
    /// v0.2.3: 最近一次 mutation 的 daemon UTC Unix seconds。
    updated_at: i64 = 0,
    /// v0.2.3: Profile 创建/克隆来源审计信息。
    provenance: ProfileProvenance = .{},
    /// v0.2.3: Profile 绑定的 SSH identity 引用（指向 identity store）。
    ssh_identity: ProfileSshIdentityRef = .{},
    /// diskless Profile 引用的 boot bundle 名称；仅 `kind == .diskless` 时必填。
    /// install Profile 忽略此字段。
    boot_bundle: ?[]const u8 = null,
    /// diskless Profile 引用的构建 bundle（`rootfs_build` + `first_boot` 阶段步骤）。
    /// builder 把 `rootfs_build` 步骤烤入只读 lower，把 `first_boot` 步骤作为固定
    /// payload 预置但不执行；install Profile 忽略此字段。
    bundle: ?[]const u8 = null,
    /// v0.2 diskless 启动预算与失败策略；install Profile 忽略。
    diskless: DisklessConfig = .{},
    /// M4.1 的跨发行版目标系统事实。安装和后续无盘链路都消费此字段。
    /// 包含 locale/timezone/keyboard、SSH、用户、安全和包配置。
    system: TargetSystemConfig = .{},
    /// Schema v3 软件选择基线。Repository 能力仍由资源拥有，Profile 只做选择。
    /// 包含 repository 引用、environment/group/task/package 选择列表。
    software: SoftwareSelection = .{},
    /// install mode 的安装器输入策略。保留与 M3 catalog fixture 的兼容性。
    /// M4 renderer 对缺省值采用安全的最小安装配置。
    install: ProfileInstallConfig = .{},
    /// M4.6：追加到 PXE kernel cmdline，并由安装器持久化到目标系统 GRUB。
    /// 加载时会折叠空格；安全校验拒绝保留参数名和 shell/配置注入字符。
    /// kernel_args 是 profile 级声明，node override 按 add/remove delta 覆盖。
    kernel_args: ?[]const u8 = null,
};

/// 本地化配置。跨 install/diskless 的目标系统通用事实。
pub const LocalizationConfig = struct {
    /// 系统语言环境（如 `en_US.UTF-8`）。
    locale: []const u8 = "en_US.UTF-8",
    /// 系统时区（如 `UTC`、`Asia/Shanghai`）。
    timezone: []const u8 = "UTC",
    /// 键盘布局（如 `us`）。
    keyboard: []const u8 = "us",
};

/// 连接模式枚举。v0.1 只支持 `local-only`，表示隔离 PXE 网段无外部连接。
pub const ConnectivityMode = enum { @"local-only" };

/// 连接策略配置。
pub const ConnectivityPolicy = struct {
    /// 连接模式。v0.1 固定为 `local-only`。
    mode: ConnectivityMode = .@"local-only",
    /// 是否启用 NTP 时间同步。false 时禁用 chrony/cloud-init NTP 模块。
    time_sync: bool = false,
    /// NTP 服务器列表。仅当 `time_sync = true` 时使用。
    ntp_servers: []const []const u8 = &.{},
};

/// root 登录策略枚举。
pub const RootLoginPolicy = enum {
    /// 禁止 root 登录。
    no,
    /// 仅允许密钥登录，禁止密码登录。
    @"prohibit-password",
    /// 允许 root 登录（默认值）。
    yes,
};

/// SSH 服务配置。控制目标系统的 SSH 守护进程行为。
pub const SshConfig = struct {
    /// 是否启用 SSH 服务。false 时不安装或不禁用 openssh-server。
    enabled: bool = true,
    /// 是否允许密码认证。
    password_authentication: bool = true,
    /// root 登录策略。
    root_login: RootLoginPolicy = .yes,
    /// root 密码（明文）。配置中的密码字段刻意为明文事实；
    /// 适配器仅在内存中推导 `$6$` SHA-512 crypt 哈希，不回写配置。
    root_password: ?[]const u8 = "asdf1234",
    /// root 的额外 SSH 公钥列表。渲染器将其写入 authorized_keys。
    root_authorized_keys: []const []const u8 = &.{},
};

/// 防火墙策略枚举。
pub const FirewallPolicy = enum {
    /// 禁用防火墙（默认值）。MVP 简化安装环境。
    disabled,
    /// 启用防火墙。
    enabled,
};

/// SELinux 模式枚举。
pub const SelinuxMode = enum {
    /// 禁用 SELinux（默认值）。MVP 简化安装环境。
    disabled,
    /// 宽容模式。记录违规但不阻止。
    permissive,
    /// 强制模式。阻止违规操作。
    enforcing,
};

/// 目标系统安全配置。
pub const TargetSecurityConfig = struct {
    /// 防火墙策略。MVP 默认禁用。
    firewall: FirewallPolicy = .disabled,
    /// SELinux 模式。MVP 默认禁用。
    selinux: SelinuxMode = .disabled,
    /// AppArmor 模式。MVP 默认禁用。
    apparmor: AppArmorMode = .disabled,
};

/// AppArmor 模式枚举。
pub const AppArmorMode = enum {
    /// 禁用 AppArmor。
    disabled,
    /// 抱怨模式。记录违规但不阻止。
    complain,
    /// 强制模式。阻止违规操作。
    enforce,
};

/// 目标系统用户配置。
///
/// 渲染器将每个用户写入 Kickstart `user` 指令或 Autoinstall `identity`/`users` 段。
pub const TargetUserConfig = struct {
    /// 用户名。
    name: []const u8,
    /// 可选 UID。null 时由安装器自动分配。
    uid: ?u32 = null,
    /// 可选登录 shell。null 时使用安装器默认（通常 `/bin/bash`）。
    shell: ?[]const u8 = null,
    /// 是否锁定密码登录。true 时只允许密钥登录。
    locked: bool = false,
    /// 密码（明文）。null 时锁定密码登录。
    /// 配置中的密码字段刻意为明文事实；适配器仅在内存中推导 `$6$` 哈希。
    password: ?[]const u8 = null,
    /// 是否加入 sudo（wheel/sudo 组）。
    sudo: bool = false,
    /// 附加用户组列表。
    groups: []const []const u8 = &.{},
    /// 该用户的 SSH 公钥列表。渲染器将其写入 authorized_keys。
    ssh_authorized_keys: []const []const u8 = &.{},
};

/// M4.2 默认目标账号。配置显式写入 `system.users: []` 时仍可选择 root-only。
///
/// 默认创建用户 `nodeforge`，密码 `asdf1234`，具有 sudo 权限。
pub const default_target_users = [_]TargetUserConfig{.{
    .name = "nodeforge",
    .password = "asdf1234",
    .sudo = true,
}};

/// 判断 users 切片是否指向编译期默认用户数组（即未显式配置）。
///
/// 通过指针比较判断，不比较内容——如果操作员恰好配置了与默认值相同的用户，
/// 仍然视为显式配置。
pub fn targetUsersAreImplicitDefault(users: []const TargetUserConfig) bool {
    return users.ptr == default_target_users[0..].ptr;
}

/// 目标系统通用事实，刻意独立于安装器语法。
///
/// 这些字段跨 install/diskless 两条链路共享。Kickstart 和 Autoinstall
/// 适配器各自将此结构体映射为安装器特定语法。
pub const TargetSystemConfig = struct {
    /// 本地化配置：locale、timezone、keyboard。
    localization: LocalizationConfig = .{},
    /// 连接策略：NTP 时间同步等。
    connectivity: ConnectivityPolicy = .{},
    /// SSH 服务配置。
    ssh: SshConfig = .{},
    /// 安全配置：防火墙、SELinux、AppArmor。
    security: TargetSecurityConfig = .{},
    /// 目标系统用户列表。默认为 [`default_target_users`]（nodeforge 账号）。
    users: []const TargetUserConfig = &default_target_users,
    /// 额外安装的包名列表（独立于 software selection 的补充）。
    packages: []const []const u8 = &.{},
    /// 是否默认采用 profile 创建时导入的宿主机 /etc/hosts。
    import_host_hosts: bool = true,
    /// 目标系统 /etc/hosts 的显式内容。null 时由渲染器生成最小 hosts；
    /// profile create 默认填入宿主机 /etc/hosts，可通过 CLI 覆盖或关闭导入。
    hosts_content: ?[]const u8 = null,
};

/// 目标系统网络模式枚举。
pub const NetworkMode = enum {
    /// DHCP 自动获取地址。PXE 引导阶段始终使用 DHCP。
    dhcp,
    /// 静态 IP 配置。安装器将静态配置写入目标系统 Netplan/NetworkManager。
    static,
};

/// 目标系统网络配置。
///
/// 这是 Node 直接属性（schema v3），不属于 Profile override。
/// PXE 引导阶段始终保持 DHCP；`mode = static` 时安装器将静态配置写入目标系统。
pub const TargetNetworkConfig = struct {
    /// 网络模式。DHCP 或静态。
    mode: NetworkMode = .dhcp,
    /// 网卡接口名称。null 时安装器按 MAC 匹配。
    interface: ?[]const u8 = null,
    /// 网卡 MAC 地址匹配。Anaconda `--device=` 和 Netplan `match.macaddress` 使用。
    match_mac: ?[]const u8 = null,
    /// 静态 IPv4 地址（点分格式）。仅 `mode = static` 时必须提供。
    address: ?[]const u8 = null,
    /// IPv4 前缀长度（1-32）。仅 `mode = static` 时必须提供。
    prefix_len: ?u8 = null,
    /// 默认网关（点分 IPv4）。
    gateway: ?[]const u8 = null,
    /// DNS 服务器列表（点分 IPv4）。
    dns: []const []const u8 = &.{},
    /// DNS 搜索域名列表。
    search_domains: []const []const u8 = &.{},
    /// 静态路由列表。
    routes: []const RouteConfig = &.{},
};

/// 静态路由配置。
pub const RouteConfig = struct {
    /// 路由标识，用于 CLI mutation 和去重。
    id: []const u8,
    /// 目标网络（CIDR 格式，如 `10.0.0.0/24`）。
    destination: []const u8,
    /// 网关地址（点分 IPv4）。
    gateway: []const u8,
    /// 可选路由 metric（优先级）。null 时使用系统默认。
    metric: ?u32 = null,
};

/// Node override 配置。
///
/// Node override 只表达共享 Profile 策略在单个节点上的例外。
/// 所有 Profile 策略字段均可 override。Node 直接属性（磁盘路径、hostname、IP）
/// 不通过 override 合并，而是直接写入 Node 字段。
pub const NodeOverrideConfig = struct {
    /// 安装器输入策略 override（storage/bootloader/apt/completion/updates/proxy/post_install）。
    install: InstallOverrideConfig = .{},
    /// 目标系统策略 override（localization/connectivity/ssh/security/users）。
    system: SystemOverrideConfig = .{},
    /// 软件选择 override（repositories/groups/tasks/packages delta）。
    software: SoftwareOverrideConfig = .{},
    /// kernel arguments delta（按参数名 add/remove）。
    kernel_args: StringSetDelta = .{},
    /// diskless 运行期 override（first-boot bundle 替换等）。仅 diskless Node 生效。
    diskless: DisklessOverrideConfig = .{},
};

/// diskless Node 运行期 override。只承载切根后由 agent pre-init 重放的差异，
/// 不复制 Profile 已烤入 rootfs lower 的共享基线。
pub const DisklessOverrideConfig = struct {
    /// first-boot provision override。Node 可完整替换自身从 Profile 继承的 first-boot。
    provision: DisklessProvisionOverride = .{},
    /// per-Node tmpfs upper 百分比 override；null 继承 Profile。
    overlay_tmpfs_percent: ?u8 = null,
};

pub const DisklessConfig = struct {
    overlay: DisklessOverlayConfig = .{},
    failure: DisklessFailureConfig = .{},
};

pub const DisklessOverlayConfig = struct {
    /// MemAvailable 中预留给 overlay upper 的比例，校验范围 10-80。
    tmpfs_percent: u8 = 50,
    /// upper 至少可增长到的字节数。
    minimum_free_bytes: u64 = 256 * 1024 * 1024,
    /// 下载/挂载之外保留给内核与用户态峰值的安全余量。
    safety_margin_bytes: u64 = 128 * 1024 * 1024,
};

pub const DisklessFailureConfig = struct {
    max_attempts: u8 = 3,
    backoff_seconds: u32 = 30,
};

/// diskless Node first-boot provision override。
pub const DisklessProvisionOverride = struct {
    /// Node first-boot bundle 名称；引用 `Catalog.provisioning_bundles`。
    /// 设置后完整替换 Profile 的 first_boot 步骤，且只允许 `first_boot` 阶段 item；
    /// 不影响 rootfs lower（Profile rootfs-build projection 永不读取此 override）。
    bundle: ?[]const u8 = null,
};

/// 字符串集合 delta。用于列表型字段的 add/remove 语义。
///
/// override 操作中：`add` 列表的值追加到 Profile 基线；
/// `remove` 列表的值从结果中剔除。同一值不能同时出现在 add 和 remove 中。
pub const StringSetDelta = struct {
    /// 需要追加到基线的值列表。
    add: []const []const u8 = &.{},
    /// 需要从基线中剔除的值列表。
    remove: []const []const u8 = &.{},
};

/// Nullable storage override。每个字段 null 表示继承 Profile 基线。
///
/// 与 [`StoragePolicyConfig`] 对应，但所有字段都是 nullable，
/// 用于 Node override 的逐字段 patch 语义。
pub const NullableStorageOverride = struct {
    /// 存储拓扑模式（single/LVM/RAID）。null 继承 Profile。
    mode: ?StorageMode = null,
    /// 是否擦盘。null 继承 Profile。
    wipe: ?bool = null,
    /// 分区表类型（GPT/MBR）。null 继承 Profile。
    partition_table: ?PartitionTable = null,
    /// 显式分区列表。null 继承 Profile；`[]` 明确表示空（使用默认布局）。
    partitions: ?[]const PartitionConfig = null,
};

/// Bootloader override。用于 Node 级 bootloader 安装策略例外。
pub const BootloaderOverride = struct {
    /// 是否安装引导加载器。null 继承 Profile。
    install: ?bool = null,
};

/// 安装器输入策略 override。
///
/// 每个字段 null 表示继承 Profile 基线。结构体字段使用 nullable patch 语义：
/// 未出现的字段继承，非 null 字段完整替换。
pub const InstallOverrideConfig = struct {
    /// 存储布局策略 override。
    storage: NullableStorageOverride = .{},
    /// 引导加载器策略 override。
    bootloader: BootloaderOverride = .{},
    /// Ubuntu APT fallback 策略 override。
    apt_fallback: ?AptFallback = null,
    /// Ubuntu APT 源保留策略 override（null 继承 Profile）。
    apt_preserve_sources_list: ?bool = null,
    /// 重装策略 override。
    reinstall_policy: ?ReinstallPolicy = null,
    /// 安装完成动作 override（reboot/poweroff/halt）。
    completion_action: ?CompletionAction = null,
    /// 更新模式 override（none/security/all）。
    updates_mode: ?UpdateMode = null,
    /// HTTP/HTTPS 代理 URL override。
    proxy_url: ?[]const u8 = null,
    /// 代理 no_proxy 域名列表 delta。
    proxy_no_proxy: StringSetDelta = .{},
    /// 后处理 bundle 名称 override。
    post_install_bundle: ?[]const u8 = null,
};

/// 本地化策略 override。逐字段 nullable patch。
pub const LocalizationOverride = struct {
    /// 系统语言环境。null 继承 Profile。
    locale: ?[]const u8 = null,
    /// 系统时区。null 继承 Profile。
    timezone: ?[]const u8 = null,
    /// 键盘布局。null 继承 Profile。
    keyboard: ?[]const u8 = null,
};

/// 连接策略 override。逐字段 nullable patch。
pub const ConnectivityOverride = struct {
    /// 是否启用 NTP 时间同步。null 继承 Profile。
    time_sync: ?bool = null,
    /// NTP 服务器列表 delta（add/remove）。
    ntp_servers: StringSetDelta = .{},
};

/// SSH 策略 override。逐字段 nullable patch。
pub const SshOverride = struct {
    /// 是否启用 SSH 服务。null 继承 Profile。
    enabled: ?bool = null,
    /// 是否允许密码认证。null 继承 Profile。
    password_authentication: ?bool = null,
    /// root 登录策略。null 继承 Profile。
    root_login: ?RootLoginPolicy = null,
    /// root 密码。null 继承 Profile。
    root_password: ?[]const u8 = null,
    /// root SSH 公钥列表 delta（add/remove）。
    root_authorized_keys: StringSetDelta = .{},
};

/// 安全策略 override。逐字段 nullable patch。
pub const SecurityOverride = struct {
    /// 防火墙策略。null 继承 Profile。
    firewall: ?FirewallPolicy = null,
    /// SELinux 模式。null 继承 Profile。
    selinux: ?SelinuxMode = null,
    /// AppArmor 模式。null 继承 Profile。
    apparmor: ?AppArmorMode = null,
};

/// 目标系统策略 override 聚合。
pub const SystemOverrideConfig = struct {
    /// 本地化策略 override。
    localization: LocalizationOverride = .{},
    /// 连接策略 override。
    connectivity: ConnectivityOverride = .{},
    /// SSH 策略 override。
    ssh: SshOverride = .{},
    /// 安全策略 override。
    security: SecurityOverride = .{},
    /// 用户列表。null 继承 Profile；数组完整替换（不是 delta）。
    users: ?[]const TargetUserConfig = null,
};

/// Profile 软件选择基线。
///
/// Repository 能力由资源拥有（`RepositoryConfig.software_index`），
/// Profile 只做选择。Node override 通过 [`SoftwareOverrideConfig`] 表达 delta。
pub const SoftwareSelection = struct {
    /// 引用的仓库名称列表。每个名称必须能在 catalog.repositories 中找到。
    repositories: []const []const u8 = &.{},
    /// RHEL comps environment（如 `minimal-environment`）。
    environment: ?[]const u8 = null,
    /// RHEL comps group 列表（如 `core`、`development`）。
    groups: []const []const u8 = &.{},
    /// Ubuntu task 列表（如 `ubuntu-desktop`）。
    tasks: []const []const u8 = &.{},
    /// 包选择（include/exclude 列表）。
    packages: PackageSelection = .{},
};

/// 包选择配置。
pub const PackageSelection = struct {
    /// 需要安装的包名列表。
    include: []const []const u8 = &.{},
    /// 需要排除的包名列表（Kickstart `--exclude`）。
    exclude: []const []const u8 = &.{},
};

/// 软件选择 override。使用 add/remove delta 语义。
pub const SoftwareOverrideConfig = struct {
    /// 仓库引用 delta（add/remove）。
    repositories: StringSetDelta = .{},
    /// RHEL environment。null 继承 Profile。
    environment: ?[]const u8 = null,
    /// RHEL group 列表 delta（add/remove）。
    groups: StringSetDelta = .{},
    /// Ubuntu task 列表 delta（add/remove）。
    tasks: StringSetDelta = .{},
    /// 包 include 列表 delta（add/remove）。
    packages_include: StringSetDelta = .{},
    /// 包 exclude 列表 delta（add/remove）。
    packages_exclude: StringSetDelta = .{},
};

/// 安装器输入配置（schema v2 兼容模型）。
///
/// 由 profile 引用以渲染 Kickstart/Autoinstall answer 文件。
/// 所有字段在配置校验阶段已验证安全性；渲染器直接使用这些值生成安装脚本。
///
/// 注意：schema v3 后物理设备选择器（`boot_disk`/`members`）从 Node 直接属性编译，
/// Profile 只保留 [`ProfileInstallConfig`] 策略字段。
pub const InstallConfig = struct {
    /// 存储布局配置；渲染器根据 mode 和 partition_table 生成分区指令。
    /// 物理设备路径从 Node 直接属性编译。
    storage: StorageConfig = .{},
    /// 引导加载器安装配置；控制是否在目标磁盘上安装 GRUB。
    bootloader: BootloaderInstallConfig = .{},
    /// Ubuntu APT 安装策略。默认允许使用 live ISO/squashfs 离线安装；
    /// 严格验收本地 HTTP mirror 时应显式设为 `abort`。
    apt: AptInstallConfig = .{},
    /// 重装策略。默认 `explicit`，只允许显式 rearm 后执行一次安装。
    reinstall_policy: ReinstallPolicy = .explicit,
    /// 安装完成动作配置。
    completion: CompletionConfig = .{},
    /// 更新策略配置。
    updates: UpdateConfig = .{},
    /// HTTP/HTTPS 代理配置。
    proxy: ProxyConfig = .{},
    /// 后处理 bundle 配置。
    post_install: PostInstallConfig = .{},
};

/// v0.1 Profile 持久化安装策略。物理设备从 Node 编译。
///
/// 与 [`InstallConfig`] 的区别：此结构体不含物理设备选择器（`boot_disk`/`members`），
/// 只保留共享策略字段。effective plan 编译时合并 Node 直接属性和此策略。
pub const ProfileInstallConfig = struct {
    /// 存储策略（拓扑模式、擦盘、分区表、分区列表）。
    storage: StoragePolicyConfig = .{},
    /// 引导加载器安装策略。
    bootloader: BootloaderInstallConfig = .{},
    /// Ubuntu APT 安装策略。
    apt: AptInstallConfig = .{},
    /// 重装策略。
    reinstall_policy: ReinstallPolicy = .explicit,
    /// 安装完成动作。
    completion: CompletionConfig = .{},
    /// 更新策略。
    updates: UpdateConfig = .{},
    /// HTTP/HTTPS 代理配置。
    proxy: ProxyConfig = .{},
    /// 后处理 bundle 配置。
    post_install: PostInstallConfig = .{},
};

/// 安装完成动作枚举。
pub const CompletionAction = enum {
    /// 安装完成后重启（默认值）。
    reboot,
    /// 安装完成后关机。
    poweroff,
    /// 安装完成后停机（不重启不关机）。
    halt,
};

/// 安装完成动作配置。
pub const CompletionConfig = struct {
    /// 安装完成后的系统动作。
    action: CompletionAction = .reboot,
};

/// 更新模式枚举。
pub const UpdateMode = enum {
    /// 不执行任何更新（默认值）。
    none,
    /// 只安装安全更新。
    security,
    /// 安装所有可用更新。
    all,
};

/// 更新策略配置。
pub const UpdateConfig = struct {
    /// 更新模式。
    mode: UpdateMode = .none,
};

/// HTTP/HTTPS 代理配置。
pub const ProxyConfig = struct {
    /// 代理 URL（如 `http://proxy.example.com:3128`）。null 不使用代理。
    url: ?[]const u8 = null,
    /// 不走代理的域名/IP 列表。
    no_proxy: []const []const u8 = &.{},
};

/// 后处理 bundle 配置。
pub const PostInstallConfig = struct {
    /// 引用 `Catalog.provisioning_bundles` 中的 bundle 名称。
    bundle: ?[]const u8 = null,
};

/// Subiquity 在所有候选 APT mirror 均不可用时的处理策略。
///
/// 枚举标签刻意与 autoinstall schema 和 JSON 配置中的连字符值完全一致，
/// 因此 setup 配置导入和 `config export` 不需要额外字符串映射。
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
    /// APT mirror 不可用时的 fallback 策略。
    fallback: AptFallback = .@"offline-install",
    /// 是否保留安装器/ISO 写入的原有 APT 源，而不是删除后只保留 NodeForge
    /// 受管源。默认 false：autoinstall late-command、diskless node-apply 和
    /// rootfs-build package 步骤都会删除原有源，只生成 nodeforge.list
    /// （local-only 受管源契约）。设为 true 时保留原有源，NodeForge 受管源
    /// 作为附加源写入——受管镜像缺少包、需要借助原始源补齐时使用。
    preserve_sources_list: bool = false,
};

/// 磁盘存储布局配置（effective plan 编译结果）。
///
/// M4 渲染器根据此配置生成 Kickstart `part`/`raid` 指令或
/// Autoinstall `storage` 段。当 `partitions` 为空时使用安全默认值。
///
/// 物理设备路径（`boot_disk`/`members`）从 Node 直接属性编译，
/// 不来自 Profile 策略。
pub const StorageConfig = struct {
    /// 是否在分区前清除目标盘既有分区/签名。它是 install.storage 的具体
    /// 渲染策略，只有 profile 已通过 destructive/persistent 安全校验且
    /// generation 已显式武装时才可能执行。
    wipe: bool = true,
    /// 存储拓扑模式（单盘/LVM/RAID）。决定渲染器生成何种存储指令。
    mode: StorageMode = .single,
    /// 主启动磁盘设备路径；Kickstart 的 `clearpart --drives` 和 `bootloader --boot-drive` 使用此值。
    /// 值格式为 Linux 设备路径（如 `/dev/sda`），渲染时去掉 `/dev/` 前缀。
    /// 从 [`NodeConfig.storage.boot_disk`] 编译。
    boot_disk: []const u8 = "/dev/sda",
    /// Effective 有序成员设备列表。从 [`NodeConfig.storage`] 编译。
    /// single 模式只含 boot_disk；RAID 模式含所有参与阵列的磁盘。
    members: []const []const u8 = &.{"/dev/sda"},
    /// 分区表类型；GPT 是 UEFI 的默认要求，MBR 用于旧式 BIOS。
    partition_table: PartitionTable = .gpt,
    /// 显式分区列表；为空时渲染器使用安全默认布局（ESP + /boot + root）。
    partitions: []const PartitionConfig = &.{},
};

/// Profile 持久化存储策略。不含物理设备选择器。
///
/// 与 [`StorageConfig`] 的区别：无 `boot_disk`/`members` 字段。
/// effective plan 编译时从 Node 直接属性补入。
pub const StoragePolicyConfig = struct {
    /// 是否擦盘。
    wipe: bool = true,
    /// 存储拓扑模式。
    mode: StorageMode = .single,
    /// 分区表类型。
    partition_table: PartitionTable = .gpt,
    /// 显式分区列表。
    partitions: []const PartitionConfig = &.{},
};

/// 存储拓扑模式枚举。
///
/// 决定渲染器生成单盘分区、LVM 卷组还是 RAID 阵列指令。
/// `raid*-lvm` 模式先创建 RAID 阵列，再在其上创建 LVM 卷组。
pub const StorageMode = enum {
    /// 单盘直分区。默认模式。
    single,
    /// LVM 逻辑卷管理。
    lvm,
    /// RAID 0 条带。
    raid0,
    /// RAID 1 镜像。
    raid1,
    /// RAID 5 条带+奇偶校验。
    raid5,
    /// RAID 6 双奇偶校验。
    raid6,
    /// RAID 10 镜像+条带。
    raid10,
    /// RAID 0 上建 LVM。
    @"raid0-lvm",
    /// RAID 1 上建 LVM。
    @"raid1-lvm",
    /// RAID 5 上建 LVM。
    @"raid5-lvm",
    /// RAID 6 上建 LVM。
    @"raid6-lvm",
    /// RAID 10 上建 LVM。
    @"raid10-lvm",
};

/// 分区表类型。GPT 是 UEFI 的标准要求；MBR 用于旧式 BIOS 系统。
pub const PartitionTable = enum {
    /// GUID Partition Table。UEFI 启动的默认要求。
    gpt,
    /// Master Boot Record。旧式 BIOS 系统使用。
    mbr,
};

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
    /// Schema v3 稳定 item 标识。迁移时从语义角色（esp/boot/root/swap）派生。
    /// CLI mutation 通过 id 定位分区进行增删改查。
    id: ?[]const u8 = null,
    /// 挂载点路径；null 时按 kind 推导（swap→"swap"，esp→"/boot/efi"等）。
    mount: ?[]const u8 = null,
    /// 分区大小（MiB）；0 且 `grow = false` 时使用默认大小。
    size_mib: u32 = 0,
    /// 消耗剩余逻辑容量。最多一个分区可 grow。通常用于 root 分区。
    grow: bool = false,
    /// 文件系统类型；null 时按 kind 推导（esp→"efi"，swap→"swap"，其他→"ext4"/"xfs"）。
    /// Kickstart 使用此值作为 `--fstype` 参数。
    filesystem: ?[]const u8 = null,
    /// 分区用途；决定渲染器的默认行为。
    kind: PartitionKind = .plain,
};

/// 引导加载器安装配置。控制是否在目标磁盘上安装 GRUB 及其配置方式。
pub const BootloaderInstallConfig = struct {
    /// 是否安装引导加载器；false 时跳过 `bootloader` 指令，适用于已有引导管理的环境。
    install: bool = true,
};

/// 后处理执行阶段。schema v4 同时保存 install-post、rootfs-build 和
/// first-boot；三者的执行者与允许动作由 validator/runner 分别约束。
pub const ProvisionPhase = enum {
    /// 安装后阶段。在 `%post`（Kickstart）或 `late-commands`（Autoinstall）中执行。
    install_post,
    /// rootfs 构建阶段（v0.2）。在服务端 rootfs builder 内向只读 lower 追加业务内容。
    rootfs_build,
    /// 首次启动阶段（v0.2）。切根后由 agent 在真正 init 之后执行，一次性、无远程控制。
    first_boot,
};

/// 后处理动作类型。`repository`/`standard_packages` 只服务既有受限
/// install-post 兼容路径；diskless rootfs-build/first-boot 使用
/// managed_file/archive/script/package 四类 canonical action。
pub const ProvisionAction = enum {
    /// 写入受管文件（使用 heredoc 创建指定路径的文件）。
    managed_file,
    /// 解压受管归档资产（v0.2）。`archive` 动作，仅 rootfs-build/first-boot 可用。
    archive,
    /// 执行受管脚本资产（v0.2）。`script` 动作，来源必须是 catalog 受管 asset。
    script,
    /// 安装预解析并固定的包闭包（v0.2）。只允许访问 AgentPlan 指定的 nodeforged
    /// 受管 HTTP Yum/APT 源；缺依赖在 build/readiness 阶段失败。
    package,
    /// 添加软件仓库（dnf config-manager 或 apt sources.list）。
    repository,
    /// 安装标准软件包（dnf install 或 apt-get install）。
    standard_packages,
};

/// 单个后处理步骤。渲染器按 `action` 类型生成对应的 shell 命令。
/// 每种 action 只使用与之相关的字段，其余字段应保持 null/空。
pub const ProvisionStep = struct {
    /// 步骤名称；用于日志和审计，不进入生成的 shell 脚本。
    name: []const u8,
    /// 同一 session/plan 内的稳定幂等键；first-boot journal 以此跳过已成功步骤。
    idempotency_key: []const u8 = "",
    /// 单次执行超时秒数。
    timeout_s: u32 = 300,
    /// 基础设施失败是否可在本次启动内按 failure policy 重试。
    retryable: bool = false,
    /// 执行阶段；validator 会按 phase 限制允许的 action/字段矩阵。
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
    /// `managed_file` 动作的文件内容资产引用。与 `content` 二选一；
    /// 引用 catalog 中 kind 为 `managed_file` 的资产，通过 HTTP 下载。
    content_asset: ?[]const u8 = null,
    /// `managed_file` 写入文件的权限模式（八进制）。默认 `0644`。
    mode: u16 = 0o644,
    /// `managed_file` 写入文件的属主。默认 `root`。
    owner: []const u8 = "root",
    /// `managed_file` 写入文件的属组。默认 `root`。
    group: []const u8 = "root",
    /// Runtime-only immutable delivery projection；catalog schema v4 不持久化。
    /// 由 daemon 在下发 answer file 时填充，指向 HTTP 可下载的内容 URL。
    content_url: ?[]const u8 = null,
    /// content_url 对应内容的 SHA-256 摘要。安装器下载后校验完整性。
    content_sha256: ?[]const u8 = null,
};

/// 可复用的后处理步骤集合。通过 profile.install.post_install.bundle 引用。
/// 同一 bundle 可被多个 profile 共享，减少配置重复。
pub const ProvisioningBundle = struct {
    /// bundle 名称；profile.install.post_install.bundle 引用此值。
    name: []const u8,
    /// bundle 版本；用于未来兼容性检查，M4 不强制校验。
    version: []const u8 = "1",
    /// bundle revision，用于乐观并发控制。
    revision: u64 = 1,
    /// 有序步骤列表；渲染器按声明顺序生成 shell 命令。
    steps: []const ProvisionStep = &.{},
};

/// Node 配置模型。
///
/// Node 描述一台机器的身份、直接配置和物理绑定。以下字段是 Node 直接属性，
/// 不属于 override：
/// - `id`/`mac`/`arch`/`profile`：节点身份和 PXE 匹配。
/// - `pxe`/`hostname`/`network`：PXE 保留和目标网络。
/// - `storage`：物理设备选择器（v0.1 所有权修复后从 Profile 迁入）。
/// - `deploy`/`http_accel`：部署开关和传输优化。
pub const NodeConfig = struct {
    /// NodeForge 内部节点名，例如 `node-01`；用于 CLI 和 API。
    /// 必须是 canonical logical-id（小写 ASCII，path-safe）。
    id: []const u8,
    /// 网卡 MAC 地址（冒号分隔）；MVP 最主要的 PXE 身份匹配字段。
    mac: []const u8,
    /// 节点架构。必须与所绑定 install source 的 arch 一致。
    /// 从 DHCP RFC 4578 PXE 架构选项验证一致性。
    arch: Arch,
    /// 所绑定 profile 名称，必须能在 `Catalog.profiles` 中找到。
    /// null 表示未绑定（未认领的发现节点）。
    profile: ?[]const u8 = null,
    /// Schema v3 canonical PXE lease 保留配置。
    pxe: PxeConfig = .{},
    /// 节点主机名；用于渲染安装配置中的 hostname。
    /// CLI `node add` 未显式指定时默认使用 `node.id`；
    /// API 直接创建时 null 表示由渲染层回退到 `node.id`。
    hostname: ?[]const u8 = null,
    /// 节点 override 配置。表达共享 Profile 策略在单个节点上的例外。
    /// 不含物理设备选择器——那些是 Node 直接属性。
    overrides: NodeOverrideConfig = .{},
    /// 物理设备所有权。Schema v3 直接 Node 属性。
    /// `boot_disk` 默认 `/dev/sda`；`additional_disks` 为空表示单盘安装。
    storage: NodeStorageConfig = .{},
    /// 目标系统网络。Schema v3 直接 Node 属性。
    /// PXE 引导阶段始终保持 DHCP；`mode = static` 时安装器写入持久静态配置。
    network: TargetNetworkConfig = .{},
    /// M4.2 F2: 节点是否参与 PXE 部署。`false` 时即使 MAC/IP/profile 匹配，
    /// resolve() 也不下发 PXE bootfile，仍发诊断 DHCP lease。适用于 install/diskless/discovery 全模式。
    /// 通过 `node set <id> deploy=false` 管理。与 generation gate 互补不冗余。
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
    /// 通过 `node set <id> http_accel=true` 启用。
    http_accel: bool = false,
};

/// PXE lease 保留配置。Schema v3 canonical 保留地址。
pub const PxeConfig = struct {
    /// DHCP 静态保留地址（IPv4 点分格式）。null 时从地址池动态分配。
    ip_reservation: ?[]const u8 = null,
};

/// Node 物理设备存储配置。Schema v3 直接 Node 属性。
///
/// v0.1 所有权修复后，物理设备选择器从 Profile 迁入 Node。
/// Profile 只保留与物理设备无关的 wipe/partition/bootloader 策略。
pub const NodeStorageConfig = struct {
    /// 主启动磁盘设备路径。默认 `/dev/sda`。
    /// 只接受 Linux `/dev/...` 设备路径，不支持 by-id/serial/WWN 等稳定选择器。
    boot_disk: []const u8 = "/dev/sda",
    /// 额外参与安装的磁盘设备路径列表。空表示单盘安装。
    /// RAID/LVM 模式时，`boot_disk` + `additional_disks` 共同组成成员设备。
    additional_disks: []const []const u8 = &.{},
};
