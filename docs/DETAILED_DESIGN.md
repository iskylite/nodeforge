# NodeForge 分阶段详细设计与实现计划

本文基于 `DESIGN.md` 的收敛版概要设计，作为后续代码实现的执行蓝图。它把 NodeForge 第一阶段拆成可落地的实现阶段，明确每个阶段要写哪些模块、形成哪些数据结构、暴露哪些接口和 CLI、需要哪些测试，以及达到什么标准才能进入下一阶段。

本文不替代概要设计。概要设计回答“做什么、边界是什么、核心取舍是什么”；本文回答“按什么顺序实现、每一步交付什么代码、如何验证”。

## 1. 实施总原则

### 1.1 实现策略

- 先完成单机单进程闭环，再扩展高级能力。
- 先把配置、状态、事件、CLI、端口自检和单 HTTP listener 骨架打稳，再实现网络协议服务。
- DHCP/TFTP 协议层保持通用和可测试，PXE 策略放在 policy/resolver 层。
- HTTP 承载大文件、配置、answer file 和事件上报，TFTP 只承载启动小文件。
- 自动安装和无盘启动作为两条一等公民链路并行建模，但实现顺序先安装后无盘。
- 所有破坏性安装动作必须来自显式认领的 node + install profile。MVP 以 MAC 作为主要节点身份，DHCP client id 和 SN 作为辅助信息。
- 未知节点默认进入等待/观察态；安全 discovery 或 safe/ephemeral diskless 必须显式配置，未知节点自动安装属于非法配置。
- diskless 的 kernel、小 initrd、rootfs 必须以 boot bundle 方式校验一致性。
- CLI 默认输出面向人；只有需要 human/JSON 两种结果的命令声明 `--output json`。命令解析和帮助信息优先使用成熟开源库，不长期维护手写 parser。M0 中站点配置走 `config.json` 和重启加载，catalog 只读；M1+ 才由 `nodeforged` 写入导入/构建/发布产生的 asset、repository、install source、rootfs、initrd、boot bundle，并加入运行期高频、批量和观测 CLI/API。
- 网络协议明确只支持 IPv4；配置、监听地址、DHCP option 和 initrd 网络逻辑均不接受 IPv6。
- 密码直接以明文字符串配置和存储，包括系统用户密码（`users.password`）和 IPMI 凭据（`oob.ipmi.password`）；MVP 不引入 SecretRef、外部 secret store、临时密码状态或轮换流程。发行版 adapter 在渲染 answer file 时按安装器要求临时生成 hash，配置事实源仍只保留明文。

### 1.2 阶段划分

| 阶段 | 名称 | 前置 | 核心结果 |
| --- | --- | --- | --- |
| M0 | 项目骨架、单 HTTP listener 和管理接口 | 无 | `nodeforged` / `nodeforge` 可启动，配置和端口可自检 |
| M1 | TFTP 闭环 | M0 | 标准 TFTP client 可下载 x86_64/aarch64 启动文件 |
| M1.5 | CLI 输出统一架构 | M0、M1 | human 输出统一分组/表格/详情格式，JSON 保持稳定机器接口 |
| M2 | DHCP + PXE 闭环 | M0、M1 | 节点获得 lease 和正确 bootfile，并进入 bootloader |
| M2.5 | 结构化日志与事件系统改进 | M0、M2 | 服务日志线程安全、结构化；事件 v2 带字段；CLI 事件查询 |
| M3 | HTTP 资产、ISO 仓库和事件接口 | M0、资产模型 | 节点可获取配置/answer/rootfs/ISO repo，并上报事件 |
| M4 | PXE 无人值守安装与基础后处理 | M1-M3 | Rocky Linux 9.7 aarch64、Ubuntu Server 22.04 LTS 安装和 `install_post` 跑通 |
| M5 | 内存无盘启动与基础后处理 | M1-M3、基础 runner | 小 initrd 进入 `squashfs_overlay`，`rootfs_build`/`diskless_boot` 跑通 |
| M6 | 支持矩阵增强 | M4、M5 | x86_64 生产验证、RHEL 系差异、Ubuntu 后续 LTS、BIOS PXELINUX |
| M7 | 补充包和后处理增强 | M4、M5 | 完善 tar.bz2、自定义脚本、CLI plan/status 和跨链路回归 |

### 1.3 完成标准

每个阶段必须满足：

- 代码能构建。
- 该阶段新增模块有单元测试。
- 关键链路有集成测试或可复现实验脚本。
- CLI 输出符合统一格式；顶层、资源级和动作级 `-h/--help` 可用。
- 配置 schema 和示例同步更新。
- 失败路径能给出结构化错误。
- 公共 API、协议实现、破坏性操作和非显然逻辑的注释符合 2.3。

### 1.4 阅读顺序与阶段依赖

- M0-M7（含 M1.5）是可验收的产品阶段，按章节顺序阅读和交付。
- M1 先实现正式 TFTP 只读服务，并用标准 TFTP client 验证 RRQ/OACK、重传和路径安全。
- M1.5 在 M2 前收敛 CLI 展示层；它不改变 daemon API、配置或协议语义，但 M2+ 新命令必须复用其 formatter。
- M2 再实现 DHCP 地址、架构识别和 bootfile 决策，最后与 M1 联调完整 PXE 入口。
- M2.5 在 M2 后、M3 前改进日志和事件系统：将 `observe/log.zig` 迁移到 `std.log.scoped`，
  引入 Event v2 结构化字段，补全 TFTP/HTTP 日志，并新增 CLI 事件查询命令。它不改变
  daemon API 或协议语义，但为 M3+ 的 HTTP 事件接口和运行态审计提供基础。
- M4/M5 交付基础 provisioning runner；M7 只增强 archive、script、firstboot 和诊断，不是安装或无盘链路的前置阻塞。

## 2. 代码结构总览

代码结构按"少模块、清边界、按需拆文件"设计。MVP 不需要一开始把所有未来目录铺开；先保证主链路短、依赖方向清楚，再在文件变大或职责变多时拆分。

## 3. M0：项目骨架、单 HTTP listener 和管理接口

M0 目标是建立项目基础架构，实现可启动的守护进程和管理接口；官方 CLI 固定从本机访问。

### 3.1 已完成的代码模块

- `src/main.zig`: 应用入口和主要流程控制
- `src/app.zig`: 应用核心逻辑和生命周期管理  
- `src/nodeforged.zig`: 守护进程实现
- `src/root.zig`: 根模块和公共导出
- `src/paths.zig`: 路径管理和默认位置
- `src/preflight.zig`: 预检逻辑和端口验证
- `src/version.zig`: 版本信息
- `src/model.zig`: 核心数据模型定义，包含完整的文档注释
- `src/config/load.zig`: 配置加载功能
- `src/config/validate.zig`: 配置校验，包含详细的错误处理和文档
- `src/config/store.zig`: 配置存储管理
- `src/catalog.zig`: 配置与 catalog 的只读查询函数，校验器和 CLI 共用
- `src/catalog/store.zig`: 目录管理和资产跟踪，支持导入/导出操作
- `src/http/server.zig`: 基于 Zap/facil.io 的唯一 HTTP listener 与管理路由
- `src/http/client.zig`: HTTP 客户端用于状态探测
- `src/http/management.zig`: `nodeforge` CLI 本机管理地址约定
- `src/state/runtime.zig`: 运行状态管理
- `src/state/events.zig`: 事件记录和追踪
- `src/observe/error.zig`: 错误处理和响应格式化
- `src/observe/log.zig`: 服务日志门面，支持 info/debug 等级

### 3.2 代码质量

核心领域模型、对外入口和错误/日志协议均已添加文档注释；重点包括：

- `model.zig` 中的结构体如 `Catalog`、`RepositoryConfig`、`AssetConfig`、`InstallSourceConfig`、`BootBundleConfig`、`ProfileConfig`、`NodeConfig`、`PolicyConfig` 等
- `catalog/store.zig` 模块级注释说明默认路径、文件大小限制和函数职责
- `config/validate.zig` 详细说明校验顺序和限制
- `http/server.zig` 函数文档包括 `serve`、`route`、`validationError`、`json` 等
- `http/client.zig` 的 `Status` 结构和 `probeAt` 函数
- `state/runtime.zig` 和 `state/events.zig` 的运行态模型
- `observe/error.zig` 的错误信封结构和响应格式
- `observe/log.zig` 的日志等级和输出约定

### 3.3 关键实现

- **Zap/facil.io 接入**: HTTP 报文解析、连接生命周期和 worker 调度不再由 NodeForge 手写；`http/server.zig` 只保留 M0 路由和统一 JSON 错误。
- **端口预检**: 先连接本机端口识别活跃 listener，再以 `SO_REUSEADDR` bind，兼顾端口独占与 systemd 快速重启。
- **catalog 完整性**: 已填写的 asset `sha256` 必须是 64 位十六进制字符串。

当前 M0 目录：

```text
src/
  main.zig
  nodeforged.zig
  root.zig
  paths.zig
  app.zig
  catalog.zig
  model.zig
  config/
    load.zig
    validate.zig
    store.zig
  http/
    client.zig
    server.zig
    management.zig
  catalog/
    store.zig
  state/
    runtime.zig
    events.zig
  observe/
    error.zig
    log.zig
  preflight.zig
  version.zig
```

DHCP、TFTP、boot resolver、profile renderer、asset store、rootfs/initrd 等目录按阶段落地时再新增，不在 M0 代码里预铺空壳。

文件增长后的拆分规则：

| 触发条件 | 拆分方式 |
| --- | --- |
| `model.zig` 过大 | 拆为 `model/node.zig`、`model/profile.zig`、`model/asset.zig`，但对外仍由 `model.zig` re-export |
| DHCP/TFTP packet 逻辑复杂 | 增加 `options.zig`、`lease.zig`、`transfer.zig`，协议层仍不依赖业务配置 |
| HTTP 路由变多 | 从 `routes.zig` 拆出 `static.zig`、`api.zig`、`range.zig` |
| bootloader 增加 BIOS | 增加 `boot/pxelinux.zig`，MVP 只保留 GRUB |
| rootfs/initrd 工具链落地 | 增加 `rootfs/`、`initrd/` 子目录，MVP 可先放在 `assets/validate.zig` 和脚本约定里 |

模块依赖方向：

```text
main/app
  -> config/state/assets/profile/boot
  -> dhcp/tftp/http
  -> observe

dhcp/tftp/http
  -> config read-only snapshot
  -> catalog read-only snapshot
  -> state update API
  -> events writer

cli
  -> 127.0.0.1 HTTP management client
  -> output formatter
```

核心代码原则：

- `model.zig` 是 config、catalog 和 runtime 类型事实源；不要在 CLI、HTTP handler、renderer 里重复定义影子结构。
- M0 的 `config/validate.zig` 同时校验启动配置和 catalog 引用关系；后续 catalog 规则变重时再拆出 `catalog/validate.zig`。
- `boot/resolver.zig` 是唯一 PXE 决策入口；DHCP 只问 resolver 要 lease/bootfile，不自己理解 profile 细节。
- DHCP/TFTP packet 编解码保持纯函数风格，方便 fixture 和 fuzz。
- HTTP handler 只做路由、鉴权、参数解析和调用业务函数，不直接拼配置。
- profile adapter 只负责把规范化模型渲染成 autoinstall/kickstart，不反向修改配置。
- state/events 只能追加或通过 state manager 更新，避免多个模块直接写 runtime 文件。
- 扩展优先通过 enum/union/config 字段和 validator 扩展，不为了未来能力提前引入 trait/plugin 抽象。

### 3.1 复杂度预算

为了避免代码设计过早复杂化，MVP 执行以下约束：

| 项目 | MVP 约束 | 允许扩展时机 |
| --- | --- | --- |
| 数据模型 | `AppConfig` 表达启动/策略配置，`Catalog` 表达导入/构建/发布得到的管理目录，`RuntimeState` 表达运行态 | 配置迁移或 Web API 需要稳定 schema 时再拆 schema 包 |
| 存储 | M0 使用 `/opt/nodeforge/config/config.json` + `/opt/nodeforge/catalog/catalog.json`；站点配置修改后重启生效。M1+ 才支持 DHCP discovery 策略和 catalog 变更的运行期在线切换 | 并发写入、查询性能或多实例需求出现后再考虑数据库 |
| 管理接口 | 复用唯一 HTTP listener；路由接受所有可达连接；CLI 固定访问 `127.0.0.1:<http.port>`，只管理同机服务；不单设 `management_port` | M0 不提供安全的远程管理客户端 |
| 发行版 adapter | `ubuntu.zig`、`kickstart.zig` 两个文件 | 版本差异明显增多后再拆能力表文件 |
| 带外管理 | 只保存 IPMI 信息，不实现控制动作 | 明确要做电源控制/启动设备控制时再加执行模块 |
| 补充包和后处理 | M4/M5 实现强类型步骤和最小 runner；M7 补齐高级步骤与诊断 | 明确需要常驻任务后再考虑 agent |
| 插件系统 | 不做 | 第三方扩展成为明确目标后再设计 |

拆模块的判断标准：

- 单文件超过约 500 行，且存在两个以上稳定职责。
- 同一文件的测试 fixture 已经明显分成不同协议或业务域。
- 新功能需要独立生命周期，例如 rootfs 构建任务、initrd 构建任务。
- 不因为“未来可能会有”而提前拆目录。

### 2.2 核心调用路径

MVP 的目标业务路径如下；其中 M0 当前只实现 CLI 本地文件操作和 HTTP 管理路由，DHCP/TFTP/
HTTP 数据路径按后续阶段交付：

```text
M1+ CLI / 127.0.0.1 management HTTP
  -> runtime change / batch import / config validate / catalog operation
  -> nodeforged 校验并写入 config/catalog/runtime
  -> state/event

DHCP request
  -> dhcp.packet parse
  -> boot.resolver resolve(config, catalog, runtime, client_identity)
  -> dhcp.server offer/ack
  -> state/event

HTTP/TFTP request
  -> route/path parse
  -> asset/catalog/config lookup
  -> stream file or render config
  -> state/event
```

关键约束：

- `boot.resolver` 返回明确的 `BootDecision`，例如 `wait`、`deny`、`discovery`、`install`、`diskless`，并携带 bootfile、profile、原因。
- DHCP、TFTP、HTTP 数据路由不直接修改启动配置或 catalog。M0 的 `config import` 是 CLI 直接执行的离线原子写入，完成后需重启服务加载；M0 catalog 仅支持读取、导出和校验。M1+ 的运行期高频变更与 catalog 导入/构建/发布才通过 CLI 请求本机 `nodeforged` 执行，并由 daemon 写入。
- 业务函数接收已经校验过的 `AppConfig` 和 `Catalog` 快照，避免服务处理过程中读取半更新配置或目录。
- 所有对外错误转换为统一 `NodeForgeError`，CLI 和 API 只负责格式化。

### 2.3 注释与代码文档要求

注释要详细说明设计意图和约束，但不逐行复述语法。以下要求属于代码评审和阶段验收条件：

- 每个模块使用 `//!` 说明职责、输入输出、依赖关系和明确不负责的事项。
- 所有公开类型、语义不直观的 enum/union 和公开函数使用 `///`；说明参数、返回值、错误、所有权/生命周期、线程安全和副作用。
- DHCP/TFTP/HTTP 协议代码标明对应 RFC、option/opcode、字节布局、网络字节序、长度上限、重试和状态转换。
- `boot.resolver`、配置合并和校验逻辑说明优先级与安全不变量，尤其是 node/profile 显式绑定、未知节点禁止安装和 override 边界。
- 擦盘、分区、格式化、安装 bootloader、执行自定义脚本等代码，在函数注释中明确前置条件、不可逆影响和失败后的状态。
- allocator、buffer、指针、文件句柄、锁和异步任务说明由谁创建、持有和释放；跨线程共享状态说明同步方式。
- 发行版 adapter 和模板映射注明适用版本、目标字段和版本差异来源。
- 常量必须命名；端口、超时、大小和协议数值注明单位与标准来源，不留无解释的 magic number。
- `TODO`/`FIXME` 必须包含原因、预期处理阶段或 issue；禁止只有“以后优化”之类的空注释。
- 修改行为时同步修改注释和测试；禁止保留注释掉的旧代码，禁止写与代码语义重复且容易失真的行级旁白。

```zig
//! Read-only TFTP service for PXE boot assets.
//! Implements RFC 1350 RRQ and RFC 2347 option negotiation.

/// Resolves a client without mutating configuration.
/// Unknown clients may wait, discover, or enter safe diskless; they never install.
/// Returned paths borrow memory from validated config/catalog snapshots.
fn resolveBoot(
    config: *const AppConfig,
    catalog: *const Catalog,
    runtime: *const RuntimeState,
    client: ClientIdentity,
) NodeForgeError!BootDecision
```

## 4. 核心数据模型

本章描述 M1-M7 的目标模型，不等同于 M0 已实现 schema。M0 当前的 `src/model.zig` 已包含
`server`、`http`、`logging`、`distros`、`profiles`、`nodes`、`policy` 及 catalog 的
asset/repository/install source/boot bundle 基础引用，但采用直接 `install_source`/
`boot_bundle` 字段，尚未包含本章后续示例中的 DHCP、TFTP、hooks、rootfs 或网络 override 等字段。
M0 的可执行校验边界以第 5 节为准。

### 4.1 配置模型

MVP 不把所有对象都塞进单一手写配置文件，而是分为三类事实源：

| 类型 | 文件 | 主要内容 | 修改入口 |
| --- | --- | --- | --- |
| 启动/策略配置 | `/opt/nodeforge/config/config.json` | M0 为 server/http/logging、发行版矩阵、profile/node/policy 的基础配置；M1+ 扩展 dhcp/tftp、hooks、网络 override、provisioning bundle | M0 手工编辑 + `config validate` 或离线 `config import`，重启生效；M1+ 增加 `config apply` 和 DHCP discovery 在线切换 |
| 管理 catalog | `/opt/nodeforge/catalog/catalog.json` | asset、repository、install source、rootfs、initrd、boot bundle | M0 只读校验/导出；M1+ CLI/API 请求 `nodeforged` import/build/package/publish 并写入 |
| 运行态 | `/opt/nodeforge/state/runtime.json`、`/opt/nodeforge/logs/events.jsonl` | lease、unknown client、session、node status、事件 | 服务运行时更新 |

MVP 不读取 YAML 配置文件；如果后续需要 YAML，只作为 `config import/export` 或 catalog 清单导入导出的人机格式，导入后仍转换为 JSON 事实源。catalog 是 `nodeforged` 的内部持久化文件，CLI 不直接写。配置和 catalog 明显变大后再评估拆分或引入数据库。

```zig
const AppConfig = struct {
    server: ServerConfig,
    dhcp: DhcpConfig,
    tftp: TftpConfig,
    http: HttpConfig,
    logging: LoggingConfig,
    events: EventsConfig,
    nodes: []NodeConfig,
    distros: []DistroConfig,
    profiles: []ProfileConfig,
    provisioning_bundles: []ProvisioningBundle,
    policy: PolicyConfig,
};

const Catalog = struct {
    assets: []AssetConfig,
    repositories: []RepositoryConfig,
    install_sources: []InstallSourceConfig,
    rootfs: []RootfsConfig,
    boot_bundles: []BootBundleConfig,
};
```

`nodes` 暂时保留在 `AppConfig`，因为它表达管理员确认后的节点身份、IP/profile 绑定和部署意图；它可以通过 `node import/add/update` 由 `nodeforged` 写回配置。asset、repository、install source、rootfs、boot bundle 这类由扫描、导入、构建、发布得到的对象放入 `Catalog`。

关键字段：

```zig
const NodeConfig = struct {
    id: []const u8,
    mac: ?MacAddress,
    client_id: ?[]const u8,
    serial_number: ?[]const u8,
    ip: ?Ipv4Address,
    arch: Arch,
    profile: []const u8,
    hostname: ?[]const u8,
    role: ?[]const u8,
    tags: [][]const u8,
    vars: JsonObject,
    overrides: NodeOverrideConfig,
    oob: ?OutOfBandConfig,
};

const NodeOverrideConfig = struct {
    network: ?NodeNetworkOverride,
    install_vars: JsonObject,
    diskless: ?NodeDisklessOverride,
};

const NodeNetworkOverride = struct {
    mode: NetworkMode,
    interface: ?[]const u8,
    address: ?Ipv4Address,
    prefix_len: ?u8,
    netmask: ?Ipv4Address,
    gateway: ?Ipv4Address,
    dns: []Ipv4Address,
    search_domains: [][]const u8,
};

const NetworkMode = enum {
    inherit,
    dhcp,
    static,
};

const NodeDisklessOverride = struct {
    overlay_tmpfs_size: ?SizeExpr,
    debug: bool,
};

const OutOfBandConfig = struct {
    ipmi: ?IpmiConfig,
};

const IpmiConfig = struct {
    address: ?Ipv4Address,
    netmask: ?Ipv4Address,
    gateway: ?Ipv4Address,
    username: ?[]const u8,
    password: ?[]const u8,
};

const DistroConfig = struct {
    name: []const u8,
    family: DistroFamily,
    versions: []DistroVersionConfig,
};

const DistroVersionConfig = struct {
    version: []const u8,
    archs: []Arch,
    install_adapter: InstallAdapter,
    package_manager: PackageManager,
};

const RepositoryConfig = struct {
    name: []const u8,
    distro: []const u8,
    version: []const u8,
    arch: Arch,
    manager: PackageManager,
    base_url: []const u8,
    suites: [][]const u8,
    components: [][]const u8,
    repo_ids: [][]const u8,
    gpg_check: bool,
    gpg_key: ?AssetRef,
    roles: []RepositoryRole,
};

const InstallSourceConfig = struct {
    name: []const u8,
    distro: []const u8,
    version: []const u8,
    arch: Arch,
    kind: InstallSourceKind,
    source: AssetOrRepositoryRef,
    installer_kernel: AssetRef,
    installer_initrd: AssetRef,
    repositories: []RepositoryRef,
};

const ProfileConfig = struct {
    name: []const u8,
    mode: ProfileMode,
    distro: []const u8,
    version: []const u8,
    arch: Arch,
    boot: BootConfig,
    boot_source: BootSourceRef,
    cmdline_template: []const u8,
    safety: ProfileSafetyConfig,
    install: ?InstallConfig,
    diskless: ?DisklessConfig,
};

const BootSourceRef = union(enum) {
    install_source: []const u8,
    boot_bundle: []const u8,
};

const ProfileSafetyConfig = struct {
    safe_for_unknown: bool,
    destructive: bool,
    persistent_writes: bool,
};

const DhcpConfig = struct {
    mode: DhcpMode,
    subnet: Cidr,
    range: IpRange,
    router: ?Ipv4Address,
    dns: []Ipv4Address,
    lease_seconds: u32,
    discovery: DiscoveryConfig,
};

const DiscoveryConfig = struct {
    enabled: bool,
    default_action: DiscoveryAction,
    default_profile: ?[]const u8,
    allow_unknown_diskless: bool,
    auto_claim: bool,
};

const DiscoveryAction = enum {
    wait,
    discovery,
    diskless,
    deny,
};
```

约束：

- profile 是部署能力边界，node override 只表达单节点差异。
- profile 通过 `boot_source` 引用 `install_source` 或 `boot_bundle`；实现中不要让 profile 长期直接保存裸 kernel/initrd 路径。
- asset 是物理文件清单；distro、repository、install_source、rootfs、boot_bundle 是语义关系对象。
- `client_id` 对应 DHCP option 61，不是 NodeForge 业务 ID；MVP 身份匹配以 MAC 为主，`client_id` 可辅助，`serial_number` 只作为资产信息。
- `tags` 只用于查询、分组、批量操作和策略筛选，不应直接触发安装或无盘行为。
- `vars` 是模板输入；`overrides` 是 NodeForge 认识并校验的覆盖项。二者都不能绕过 profile 安全边界。
- `overrides.network` 是安装后系统内或无盘系统内的网络覆盖，不等同于 PXE 阶段 DHCP 保留地址 `node.ip`。DNS、gateway、search domain 都是可选字段。
- `NodeNetworkOverride.dns` 和 `search_domains` 用空列表表示未配置；静态网络只强制 address + prefix/netmask。
- `oob` 是可选带外管理信息，当前只预留 IPMI；MVP 可以先只保存和展示 BMC 地址/掩码/网关、IPMI 用户名和密码。
- IPMI 用户名和密码直接作为可选明文字段保存，不做 SecretRef、加密封装或轮换状态。
- IP 可以是静态保留或临时 lease，但不能单独作为部署身份，也不能单独触发安装。
- `install_vars` 只能填充 install profile 模板中声明的变量；擦盘、分区、bootloader、安装源仍由 install profile 决定。
- `diskless.overlay_tmpfs_size` 覆盖值必须通过 profile/global 上限校验。
- unknown diskless profile 必须满足 `safety.safe_for_unknown = true`、`safety.destructive = false`、`safety.persistent_writes = false`。
- `DiscoveryAction` 不包含 `install`；配置解析层遇到未知节点安装动作必须报错。

### 3.2 基础数据关系

实现时必须把物理文件和语义关系分开：

| 对象 | 实现职责 |
| --- | --- |
| `AssetConfig` | 保存物理文件路径、类型、大小、SHA256、来源和可选 kernel_release |
| `DistroConfig` | 保存发行版族、版本、架构、安装 adapter 和包管理器 |
| `RepositoryConfig` | 保存 apt/yum/dnf 源、mirror、GPG key、suite/component/repo id 和用途 |
| `InstallSourceConfig` | 绑定 ISO/安装树/image 与 installer kernel/initrd、repo 列表 |
| `RootfsConfig` | 记录 rootfs 构建输入、repo 列表、kernel_release 和发布物 |
| `BootBundleConfig` | 绑定 diskless kernel、小 initrd、rootfs、repo，并校验一致性 |
| `ProfileConfig` | 引用 install source 或 boot bundle，再叠加安装/无盘策略 |

基础关系约束：

- `distro + version + arch` 是 repo、install source、rootfs、boot bundle、profile 的共同主键维度。
- Ubuntu repository 使用 apt 字段；Rocky/RHEL/Alma/Fedora 使用 dnf/yum 兼容字段。实现可以统一结构，但校验必须按 distro family 解释。
- 标准 ISO 是 install source 的首选输入。导入时解包到 NodeForge 管理的版本目录，提取 installer kernel/initrd，并通过 `/repos/<install-source>/` 只读发布。
- Rocky/RHEL 系 DVD ISO 具有有效 `.treeinfo` 和 `repodata` 时，自动创建基础 yum/dnf repository 并挂到 install source。
- Ubuntu Server ISO 始终可作为 installer media 发布；只有检测到可用 `dists/`、`pool/` 和 apt 元数据时才自动创建 apt repository。ISO 包不完整时必须显式配置外部 mirror，不能把“不完整介质”伪装成完整 apt 源。
- `gpg_check` 默认 `false`，不要求 GPG key；只有用户明确启用时才校验 key，并向 yum/dnf/apt 输出签名检查配置。
- install profile 的 `boot_source.install_source` 指向 `InstallSourceConfig`，renderer 再从 install source 找 installer kernel/initrd 和 repo。
- diskless profile 的 `boot_source.boot_bundle` 指向 `BootBundleConfig`，boot resolver 再展开 kernel、小 initrd、rootfs 和 repo。
- `kernel_release` 使用 `uname -r`、`/lib/modules/<kernel_release>` 或 kernel 包元数据解析结果。asset store 中文件可以命名为 `vmlinuz`，但 manifest 必须保存真实 release。
- 不依赖运行时直接读取构建机原始 `/boot` 路径；导入后以 asset manifest 的 path、SHA256、kernel_release 为准。

### 3.3 install 配置

```zig
const InstallConfig = struct {
    installer: InstallKind,
    answer_template: AssetRef,
    storage: StorageConfig,
    bootloader: BootloaderInstallConfig,
    packages: PackageSelection,
    network: ?InstallNetworkConfig,
    users: []UserConfig,
    files: []FileOverlay,
    hooks: HookSet,
};

const StorageConfig = struct {
    wipe: bool,
    boot_disk: DiskSelector,
    install_disks: []DiskSelector,
    boot_mode: BootMode,
    partition_table: PartitionTable,
    partitions: []PartitionConfig,
};

const BootloaderInstallConfig = struct {
    install: bool,
    target: BootloaderTarget,
    set_firmware_boot_order: bool,
};

const UserConfig = struct {
    name: []const u8,
    groups: [][]const u8,
    sudo: bool,
    shell: ?[]const u8,
    password: ?[]const u8,
    ssh_authorized_keys: [][]const u8,
    lock_password: bool,
};
```

约束：

- `bootloader.install` 对自动安装 profile 默认必须为 `true`。
- `bootloader.target` 默认指向 `storage.boot_disk`。
- UEFI 安装必须存在 `/boot/efi` ESP 分区。
- BIOS + GPT 安装必须存在 BIOS boot 分区。
- 修改固件启动顺序不是 MVP 必达能力，`set_firmware_boot_order` 默认 `false`。
- `users.password` 直接保存明文，例如 `111111` 或 `asdf1234`。adapter 在渲染 answer file 时按目标安装器要求临时生成 hash，配置事实源仍只保留明文。
- `InstallConfig.packages` 表示发行版标准安装阶段的基础包选择；provisioning step 的 `standard_packages` action 表示安装后或 rootfs 构建时的补充包，二者不得重复渲染。

### 3.4 diskless 配置

```zig
const DisklessConfig = struct {
    rootfs_mode: RootfsMode,
    overlay: OverlayConfig,
};

const OverlayConfig = struct {
    tmpfs_size: SizeExpr,
    tmpfs_mode: FileMode,
    high_write_paths: [][]const u8,
};
```

约束：

- `overlay.tmpfs_size` 必须可解析，支持 `50%`、`8g`、`4096m`。
- MVP 不定义持久化 overlay 配置。
- profile 的 `boot_source.boot_bundle` 必须校验 `distro`、`version`、`arch`、`kernel_release` 一致。

### 3.5 补充包与后处理配置

M4/M5/M7 共用同一最小模型：

```zig
const ProvisioningBundle = struct {
    name: []const u8,
    version: []const u8,
    distro: []const u8,
    distro_version: []const u8,
    arch: Arch,
    steps: []ProvisionStep,
};

const ProvisionStep = struct {
    name: []const u8,
    phase: ProvisionPhase,
    enabled: bool,
    required: bool,
    action: ProvisionAction,
};

const ProvisionAction = union(enum) {
    repository: RepositoryRef,
    standard_packages: []const []const u8,
    archive: ArchivePackage,
    managed_file: ManagedFile,
    script: ProvisionScript,
};

const ArchivePackage = struct {
    asset: AssetRef,
    sha256: Sha256,
    extract_to: []const u8,
    install_script: ?[]const u8,
};

const ManagedFile = struct {
    source: AssetRef,
    destination: []const u8,
    mode: FileMode,
    owner: []const u8,
    group: []const u8,
};

const ProvisionScript = struct {
    asset: AssetRef,
    timeout_seconds: u32,
    summary: []const u8,
    affects: [][]const u8,
};
```

约束：

- 每个 step 包含名称、阶段、开关、失败策略和一种强类型 action。
- `steps` 数组顺序就是同一阶段执行顺序；跨阶段按固定阶段顺序执行。
- M4/M5 先实现 repository、standard-packages、managed-file；M7 再启用 archive、script 和 firstboot。
- 不做模块注册表、动态插件、依赖 DAG 或任意 JSON 参数。
- bundle 发布后不可原地修改；内容变化产生新版本。

### 3.6 运行态模型

```zig
const RuntimeState = struct {
    leases: []DhcpLease,
    unknown_clients: []UnknownClient,
    node_facts: []NodeFacts,
    node_status: []NodeStatus,
    tftp_sessions: []TftpSession,
};

const NodeFacts = struct {
    node_id: ?[]const u8,
    unknown_client_id: ?[]const u8,
    observed_at: Timestamp,
    source: FactsSource,
    serial_number: ?[]const u8,
    bmc_address: ?Ipv4Address,
    bmc_netmask: ?Ipv4Address,
    bmc_gateway: ?Ipv4Address,
    ipmi_username: ?[]const u8,
    ipmi_password: ?[]const u8,
};

const NodeStatus = struct {
    node_id: []const u8,
    mode: ProfileMode,
    profile: []const u8,
    stage: NodeStage,
    last_event_at: Timestamp,
    last_error: ?NodeError,
    summary: NodeSummary,
};
```

运行态写入规则：

- 运行态由 `state` 模块统一修改。
- `runtime.json` 可周期性保存或关键事件后保存。
- `events.jsonl` 只追加，不作为当前状态事实源。
- discovery/initrd 上报的 `NodeFacts` 默认只是观察数据；只包含 SN、BMC 地址/掩码/网关、IPMI 用户名和密码。管理员确认后可回填到 `node.serial_number` 或 `node.oob.ipmi`。

## 5. M0 验收标准与验证结果

M0 代码按单 HTTP listener、config/catalog/runtime 分层和 `zli v5.1.2` CLI 实现。macOS 构建和单元测试通过，Rocky 9.7 aarch64 完成实机验证。

### 4.1 目标

建立可运行骨架：

- `nodeforged` 可启动、加载配置，并由唯一 HTTP listener 提供 `/healthz` 和管理接口；M3 再在同一 listener 接入 PXE 数据路由。
- `nodeforge` CLI 固定通过 `127.0.0.1:<http.port>` 连接管理接口。
- 启动配置和 catalog 可校验、导出；启动配置可由 CLI 离线导入并原子写回，catalog 写入留待 M1+。
- 日志、错误、输出格式和 CLI 帮助信息成型。
- 通过 `nodeforged --check` 可在启动前检查 IPv4 监听地址和端口占用；正常启动仍由实际 `listen()` 处理最终 bind 结果。目录权限、资产可读性、TFTP/DHCP 检查随对应阶段补齐。

### 4.2 代码任务

| 模块 | 任务 |
| --- | --- |
| `main.zig` | `nodeforge` CLI 入口、zli 声明式命令树和 human/json 输出格式 |
| `nodeforged.zig` | 守护进程入口，自动加载默认 config/catalog，处理 `--check`/`--check-config` |
| `app.zig` | 初始化 allocator、config、catalog、state、统一 HTTP、日志 |
| `model.zig` | 定义核心结构，包括 config、catalog、runtime、node、profile、asset、repository、install source、rootfs、boot bundle 关系 |
| `paths.zig` | 统一定义默认安装根和派生路径，避免业务模块散落 `/opt/nodeforge` 硬编码 |
| `config/load.zig` | 从默认路径 `/opt/nodeforge/config/config.json` 加载启动配置，允许参数覆盖 |
| `catalog/store.zig` | `nodeforged` 内部使用，从默认路径 `/opt/nodeforge/catalog/catalog.json` 加载、校验、原子保存管理目录，允许参数覆盖 |
| `config/validate.zig` | 实现基础校验和关系一致性校验 |
| `config/store.zig` | 原子写回启动配置 JSON |
| `http/server.zig` | 单 HTTP listener 生命周期、路由分发和 JSON 错误 |
| `http/management.zig` | `nodeforge` CLI 固定访问 `127.0.0.1` 的客户端约定 |
| `observe/error.zig` | 统一错误类型和用户提示 |

### 4.3 统一 HTTP 与管理接口

MVP 不实现第二套 RPC，也不再拆成 management listener 与 PXE listener。一个 HTTP server 实现复用路由、JSON 错误、状态和生命周期，只启动一个 IPv4 listener：

- HTTP listener 固定绑定 `0.0.0.0:http.port`。M0 只提供 `/healthz` 和管理 API；M3 将在同一 listener 提供 boot config、answer、repo/rootfs 下载和节点事件。`server.server_ip` 表示 PXE 服务网对外地址，用于生成裸机可访问 URL、DHCP next-server、TFTP/HTTP 广告地址；它不作为 M0 HTTP bind 地址。
- `server.bind_interface` 是 DHCPv4 Linux 服务的必填 PXE 网卡字段，用于约束 DHCP 广播收发；示例的 `enp1s0` 只是占位值，部署前必须替换为承载 `server.server_ip` 的实际接口。静态校验拒绝空值；实际 bind 继续验证接口存在且可用。
- `nodeforge` CLI 管理客户端固定连接 `127.0.0.1:http.port`，不提供远程管理地址配置项。
- MVP 不配置独立 `management_port`。管理路由和 PXE HTTP 数据路由共用 `server.http_port`，默认 `8080`；端口冲突时修改 `config.json` 并重启。
- 管理路由与未来 PXE 数据路由逻辑分区；服务端不做 peer 来源检查，所有能到达该 listener 的 IPv4 客户端都可调用管理路由。
- `nodeforge` CLI 固定连接 `127.0.0.1`，不提供远程 endpoint，只支持管理同机 `nodeforged`。MVP 不提供管理鉴权和 TLS；将 HTTP 路由作为正式远程管理接口前，必须另行设计 TLS、鉴权和审计。

M0 的完整路由表（路径和方法必须精确匹配）如下：

| 方法 | 路径 | 成功响应 |
| --- | --- | --- |
| `GET` | `/healthz` | `200 {"ok":true,"service":"nodeforge"}` |
| `GET` | `/api/v1/management/config/status` | `200 {"ok":true,"result":{"config":"valid"}}` |
| `POST` | `/api/v1/management/config/validate` | `200 {"ok":true,"result":{}}` |
| `GET` | `/api/v1/management/server/status` | `200 {"ok":true,"result":{"service":"running"}}` |

`config/validate` 不读取请求体；它只重新校验 daemon 已加载的 config/catalog 快照。未知路径或方法统一返回 `404` JSON 错误信封；校验失败返回 `400`，`code` 固定为 `config.invalid`，`message` 是校验错误标签，`hint` 固定提示使用 CLI 校验。

成功响应示例：

```json
{
  "ok": true,
  "result": {}
}
```

错误：

```json
{
  "ok": false,
  "error": {
    "code": "config.invalid",
    "message": "MissingAsset",
    "hint": "run nodeforge config validate and correct the referenced object"
  }
}
```

### 4.4 CLI 命令

CLI 解析、帮助信息、参数类型和默认值使用 vendored `zli v5.1.2`。该 release 的 `minimum_zig_version` 为 `0.16.0`，与本项目一致。根命令、资源命令、动作命令、命令局部 flags 和位置参数组成唯一命令树；zli 从这棵树执行解析、校验和分级帮助，不再保留独立的 `dispatchHelp` 或手写 Usage/Options/Commands 清单。NodeForge 在 `vendor/zli/NODEFORGE_PATCHES.md` 记录少量上游兼容修补，并用 `tests/cli.sh` 固定命令局部参数不会泄漏到无关子命令。zli 只负责 CLI 语法和帮助，不承载复杂业务配置模型。

zli 提供 spinner，但 M0 不启用。只有后续耗时交互命令同时处于 TTY、human 输出且存在明显等待时才可启动；`--output json`、重定向、管道和 systemd 场景禁止输出动画或终端控制序列。

帮助和版本属于 CLI 通用控制能力，只提供 `-h/--help` 与 `-v/--version` 参数，不定义 `help`、`version` 同名子命令。`-v/--version` 只属于顶层 `nodeforge`；`-h/--help` 由每一级命令提供。`--config`、`--catalog`、`--output` 不作为全局参数，只挂在实际读取它们的叶子命令上，必须写在该命令之后。子命令集合只保留 status、check、config、catalog 等业务入口，避免同一操作存在两套写法。

M0 短参数固定为：`nodeforge` 根命令 `-v`，叶子命令按需使用 `-c`（config）、`-C`（catalog）、`-o`（output）、`-d`（debug）；`-h` 由 zli 自动提供。`nodeforged` 为无子命令入口，使用 `-v/-c/-C/-d/-k/-K`（version/config/catalog/debug/check/check-config）。帮助页不内嵌长命令示例，但每个枚举、关联或格式不直观的参数必须在 description 中给出一个字段级 `e.g.` 值，并说明其关联参数。

CLI 与配置文件分工：

- M0 站点启动配置通过 `config.json` 表达；`config import` 仅校验 source config 自身后离线原子写入，结构性修改后重启生效。跨文件引用关系由 `config validate`、`catalog validate` 和 daemon 启动校验负责。M0 catalog 只读，不提供导入、构建或在线更新命令。
- M1+ 的 DHCP discovery 策略、asset、repository、install source、rootfs、initrd、boot bundle 和批量对象通过 CLI/API 请求 `nodeforged` 执行，daemon 负责写入 catalog 或运行态。
- M0 CLI 只提供状态查看、健康检查、config/catalog 校验、JSON 导出和离线配置导入；事件、日志和资产管理随对应阶段加入。
- 复杂人工策略对象创建和大范围修改优先接受文件、清单或 patch 输入，不为每个字段设计长参数。
- M1+ 可评估融合式高频入口，例如 `nodeforge apply <file>`；必须在帮助信息中说明覆盖范围，不能与已有命令产生重复入口。

所有命令层级必须支持帮助信息：

```bash
nodeforge --help
nodeforge status --help
nodeforge check --help
nodeforge config --help
nodeforge config validate --help
```

M0 实现：

```bash
nodeforge status
nodeforge check
nodeforge config validate
nodeforge config export
nodeforge config import <path>
nodeforge catalog validate
nodeforge catalog export
```

所有本地文件加载失败默认输出简短格式，例如 `error: config: file not found: ./config.json`；
在叶子命令后追加 `-d/--debug` 才输出底层错误标签。服务端常驻日志由
`config.logging.level`（`info` 或 `debug`）控制，`nodeforged -d` 可只覆盖本次启动。

`status` 面向人工查看，输出进程、HTTP、管理路由和配置 API 的详细状态；`check`
面向自动化健康检查，成功时只输出简短通过信息并依赖退出码表达结果。

`install-source import` 需要实际解析 ISO、发布 HTTP 仓库、提取安装内核/initrd，并由 `nodeforged` 写入 catalog，因此归入 M3；M0 只定义 config/catalog 模型边界、writer 边界和最小校验。

### 4.5 配置与 catalog 校验

M0 至少校验：

- JSON 格式和必填字段。
- 静态 config/catalog 校验检查 `server.server_ip` 为 IPv4、`server.bind_interface` 非空、`http.port` 非零；实际启动时由 socket 绑定验证网卡存在与权限。
- `nodeforged --check` 额外检查唯一 HTTP listener 的 `0.0.0.0:http.port` 是否可用；正常启动仍以 Zap `listen()` 的实际结果为准。
- HTTP listener 与预检允许 `SO_REUSEADDR`，保证 systemd 快速重启不会被刚释放的 socket 窗口误伤；预检先连接本机端口以识别活跃 listener，避免 macOS 上两个启用该选项的 wildcard socket 共存。活跃实例仍保持端口独占。
- node id、MAC、IP、arch 和 profile 引用。
- distro/version/arch 支持矩阵格式。
- profile mode 枚举。
- profile `safety` 元数据必须与 mode 一致；M0 尚无 hooks 字段或 hook 校验。
- profile 的直接引用字段必须符合 mode：install 只填写 `install_source` 并引用 catalog 中的 install source，diskless 只填写 `boot_bundle` 并引用 catalog 中的 boot bundle，discovery 两者均为空。
- `policy.default_action` 只能是 `wait`、`discovery`、`diskless`、`deny`，缺省值为 `wait`。
- 未知节点默认 diskless 必须同时满足 `allow_unknown_diskless = true` 和目标 profile 的 `safety` 字段满足 safe/ephemeral 条件。
- 未知节点默认 install 是非法配置。
- 端口规则：DHCP/TFTP 端口不可配置。
- M0 已有的 `server.server_ip` 和 `node.ip` 只接受 IPv4；M1+ 新增的 CIDR、DNS、gateway 和监听地址同样只接受 IPv4。
- catalog JSON 格式、对象 ID、引用关系和 SHA256 字段格式。
- catalog 中已有 repository 时，manager 必须匹配 distro family；仅当 `gpg_check = true` 时要求 GPG key asset 存在。
- catalog 中已有 install source 时，必须能解析到必填的 ISO source asset、installer kernel/initrd asset；每个已声明 repository 都必须存在。
- catalog 中已有 boot bundle 时，kernel、initrd、rootfs 的 distro/version/arch/kernel_release 必须一致；M0 的 `BootBundleConfig` 尚不包含 repository 字段。

### 4.6 启动自检、服务检查与 systemd

M0 将无副作用的 preflight 暴露为 `nodeforged --check`；正常启动不会以一次预检替代实际 bind：

- `--check-config` 只校验配置和 catalog。
- `--check` 在上述校验后，对唯一 HTTP 端口执行 connect-then-bind 预检，但不长期启动；活跃 listener 立即失败，刚释放的 socket 可借助 `SO_REUSEADDR` 快速重启。
- 正常启动直接调用 Zap `listen()`；预检与实际启动间存在短暂竞态，bind 失败仍由启动路径返回。
- UDP 69、UDP 67 和资产可读性检查分别随 M1、M2、M3 服务实现加入，避免未实现服务产生虚假的通过状态。

M0 的 `nodeforge check` 在服务运行后通过 `127.0.0.1:<http.port>` 验证 process、HTTP、management route 和配置 API。
TFTP 探针、DHCP resolver、repository 和 state 检查在对应阶段实现后逐项加入。

提供 `packaging/systemd/nodeforged.service`：

- `ExecStart=/opt/nodeforge/bin/nodeforged`
- `ExecStartPre=/opt/nodeforge/bin/nodeforged --check`
- `Restart=on-failure`、`RestartSec=2s`
- M0 HTTP 默认使用 8080，不申请 DHCP/TFTP 阶段才需要的 Linux capability。
- systemd unit 本体放在 `/opt/nodeforge/systemd/nodeforged.service`；`/etc/systemd/system/nodeforged.service` 只是软链接。二进制主体安装在 `/opt/nodeforge/bin/`；`/usr/bin/nodeforge` 和 `/usr/bin/nodeforged` 也只是软链接。
- 不在 NodeForge CLI 中重复封装 `systemctl`。
- M0 需要在 Rocky 9.7 aarch64 上执行 systemd 启动、快速重启、CLI 管理接口和外部 HTTP 管理路由验证；PXE HTTP 数据路由验证属于 M3。

`nodeforged` 正常安装时自动发现 `/opt/nodeforge/config/config.json` 和 `/opt/nodeforge/catalog/catalog.json`。`--config`、`--catalog` 仅作为开发测试、迁移验证和临时排障覆盖参数，不写入默认 systemd unit，避免把部署命令变成长参数清单。

本机构建和 Rocky aarch64 交叉构建都通过根目录 `Makefile` 调用同一份 `build.zig`：
`make build`、`make test`、`make release`、`make arm64`、`make arm64-debug`。`make arm64` 固定
使用 `aarch64-linux-gnu` 与 `ReleaseSafe`，可用 `ARM64_TARGET=<zig-target>` 覆盖；交叉构建会
替换 `zig-out/bin/` 中的本机产物，继续本机调试前执行 `make build`。

M0 日志策略：

以下条目描述 M0 已交付时的行为；M2.5 会在不改变 M0 管理 API 和 CLI 错误契约的前提下替换其共享
日志后端，并把 `LoggingConfig` 的可选字段和 `EventsConfig` 作为向后兼容的默认配置加载。

- 默认日志后端使用 stderr；systemd 管理时进入 journal，不默认写 `/opt/nodeforge/logs/nodeforged.log`。
- 日常 `info` 日志包含成功监听地址、每个 HTTP 请求的 method/path/status，以及配置、校验或预检失败的错误摘要。
- `config.json` 的 `logging.level` 只接受 `info`（默认）和 `debug`。`nodeforged -d/--debug` 仅覆盖本次进程启动，优先于配置；它不写回配置文件。M0 当前的 debug 请求日志为 method/path；连接建立/关闭、DHCP/TFTP 报文摘要和更细协议诊断随对应服务阶段补齐，ReleaseSafe 也可使用。
- `nodeforge` 的每个 M0 叶子命令支持 `-d/--debug`。默认只输出一行 `error: <类别>: <简短原因>: <路径>`；debug 模式在下一行追加内部错误标签，便于定位但不泄漏请求体、token 或密码。
- M1+ 节点事件、安装阶段、无盘阶段等业务事件进入 `events.jsonl`，不与服务进程日志混为一个文件；M0 仅提供其基础类型和追加工具。

M2.5 回归 M0 的 `--check-config`、`--check`、`status`、HTTP integration 与 systemd 快速重启用例，
验证新后端不会改变已有 stdout/stderr CLI 错误、HTTP error envelope、端口预检或启动失败退出码。

### 4.7 测试

- 配置 JSON 成功加载。
- 缺失必填字段返回结构化错误。
- 原子写回不会损坏旧文件。
- CLI `--output json` 输出可解析 JSON。
- 顶层、资源级和动作级 `-h/--help` 可显示用途、参数和默认值；长示例只放在 README、设计文档和运维手册，避免帮助页冗长。
- 模拟端口占用时 preflight 明确失败。
- 管理路由接受所有可达连接；CLI 固定连接 `127.0.0.1:<http.port>`，只管理同机服务。
- `logging.level=debug` 和 daemon `-d` 能输出服务 debug 日志；CLI `-d` 能在简短错误后显示底层原因。
- `tests/http.sh` 覆盖全部 M0 HTTP 路由、统一 404、重复 listener 拒绝及 daemon `-d`。

### 4.8 阶段验收

- 启动 `nodeforged --check-config` 能校验配置。
- `nodeforge status` 能显示服务状态。
- `nodeforge config validate` 能输出清晰错误。
- `nodeforge check` 能区分进程存活与 M0 已实现的 HTTP/管理 API 可用性。

M0 验收结果：

- [x] `nodeforged --check-config` 校验有效配置。
- [x] `nodeforged --check` 检查 M0 的唯一 HTTP 独占端口。
- [x] `nodeforge status/check` 固定访问 `127.0.0.1:<http.port>` 管理 API，并检查唯一 HTTP listener。
- [x] 配置、catalog 加载、关系校验、格式化导出和原子导入通过。
- [x] M0 命令默认输出面向人，显式 `--output json` 输出可解析 JSON。
- [x] CLI 固定接入 `zli v5.1.2`，顶层、资源级和动作级帮助均由命令树自动生成。
- [x] systemd service 文件与 Rocky 9.7 aarch64 二进制部署、启动和快速重启验证通过。
- [x] Rocky 9.7 aarch64 远程环境构建、部署和验证通过。
- [x] Zap/facil.io 唯一 listener、结构化 HTTP 404、端口独占和快速重启通过集成测试及 Rocky 实机验证。
- [x] 核心领域模型、对外入口和错误/日志协议已具备文档注释。
- [x] 管理配置校验、配置状态和服务状态 API 可用。
- [x] 管理路由接受所有可达连接，CLI 固定连接 `127.0.0.1` 且不提供远程 endpoint。
- [x] 通过 `tests/cli.sh` 端到端 CLI contract tests 覆盖自动帮助、命令局部 flags 和解析错误退出码。
- [x] 通过 `tests/http.sh` 和 Rocky 9.7 aarch64 实机验证覆盖 HTTP 路由、端口预检和 systemd 快速重启。

### 4.9 Rocky 9.7 aarch64 实机验证记录

2026-07-11 在 `r97n0`（`192.168.26.128`，Rocky Linux 9.7 aarch64）部署当前 Zap/facil.io
二进制后，完成以下验证：

- `nodeforged --check-config`、空闲端口上的 `nodeforged --check`、`nodeforge config validate` 均成功。
- systemd 正常启动，并连续快速重启两次；`ExecStartPre` 的 `--check` 与实际服务启动均成功。
- VM 本机和 VM 外部访问 `/healthz`、`/api/v1/management/server/status` 均返回 200；`nodeforge status`、`nodeforge check` 通过本机管理地址成功。
- 服务运行时，第二个 `nodeforged --check` 与第二个 daemon 都因 HTTP listener 已占用而失败。
- `nodeforged -d` 和 `logging.level = "debug"` 均输出 M0 的 HTTP method/path debug 日志。

M1+ 的 TFTP、DHCP 等尚未实现的系统级验证不在本节标记为完成，见
[`ROCKY_9_7_VALIDATION.md`](ROCKY_9_7_VALIDATION.md)。

## 6. M1：PXE TFTP 闭环

**完成状态（2026-07-11）：已实现并在 Rocky Linux 9.7 aarch64 的 `root@r97n0`
完成系统级验证。** 验证命令、SHA-256、OACK/重传和安全负向用例记录于
[`ROCKY_9_7_VALIDATION.md`](ROCKY_9_7_VALIDATION.md#m1-tftp-待验证)。

### 6.1 目标

实现标准 TFTP 读路径，确保节点能拉取 PXE 启动资产。

### 5.2 代码任务

| 模块 | 任务 |
| --- | --- |
| `tftp/packet.zig` | RRQ/DATA/ACK/ERROR/OACK 编解码 |
| `tftp/server.zig` | UDP 69 dispatcher、option 协商、路径 normalize、session 状态机 |
| `assets/store.zig` | asset manifest 读写，bootloader/kernel/initrd/ISO/rootfs 等资产导入 |
| `assets/validate.zig` | asset 类型、路径、SHA256 校验 |
| `state/runtime.zig` | TFTP session 运行态 |

### 5.3 TFTP 行为

支持：

- `RRQ`
- `DATA`
- `ACK`
- `ERROR`
- `OACK`
- `octet`
- `blksize`
- `timeout`
- `tsize`

策略：

- MVP 不实现 `WRQ`，收到写请求直接返回标准 ERROR。
- 文件必须位于 TFTP asset root 内。
- 文件必须存在于 asset manifest 或 boot resolver 允许列表。
- 禁止 `..`、绝对路径、符号链接逃逸。

### 5.4 bootloader 配置生成

GRUB 配置由 `boot/grub.zig` 生成：

```text
set timeout=5
menuentry 'NodeForge {{node_id}}' {
  linuxefi {{kernel_path}} {{cmdline}}
  initrdefi {{initrd_path}}
}
```

MVP 同时支持 UEFI x86_64 和 UEFI aarch64 GRUB，分别使用 `grubx64.efi`、`grubaa64.efi`。BIOS PXELINUX 在 M6 完整化。

### 5.5 CLI 命令

```bash
nodeforge tftp show
nodeforge tftp session list
nodeforge asset import --type bootloader --name grub-uefi-aarch64 --path grubaa64.efi --arch aarch64
nodeforge asset import --type kernel --name rocky-9.7-aarch64-kernel --path vmlinuz-<kernel-release> --distro rocky --version 9.7 --arch aarch64 --kernel-release <kernel-release>
nodeforge asset import --type initrd --name rocky-9.7-aarch64-nodeforge-initrd --path initrd-nodeforge.img --distro rocky --version 9.7 --arch aarch64 --kernel-release <kernel-release>
nodeforge asset list
nodeforge asset show rocky-9.7-aarch64-kernel
nodeforge asset validate
```

### 5.6 测试

- RRQ 成功返回 DATA block。
- 文件不存在返回 ERROR。
- 路径穿越被拒绝。
- option 协商正确。
- block 重传正确。
- 标准 TFTP client 可分别下载 `grubx64.efi`、`grubaa64.efi`。
- 使用系统 `tftp`/`atftp` 客户端验证 RRQ/OACK、重传、路径和状态管理，不依赖 DHCP。

### 5.7 阶段验收

- [x] x86_64/aarch64 PXE 客户端可通过 TFTP 拉取对应 GRUB EFI 文件。
- [x] GRUB 可拉取配置、kernel、initrd。
- [x] TFTP session 能在 CLI 中看到。
- [x] 标准 TFTP 客户端可下载 `grubaa64.efi`、`grubx64.efi`，SHA-256 与 catalog manifest 一致。
- [x] 不存在的文件返回标准 ERROR code 1（file not found）。
- [x] 路径穿越（`../etc/passwd`）被拒绝，返回 ERROR code 1。
- [x] WRQ 被拒绝，返回 ERROR code 2（access violation）。
- [x] TFTP 会话计数器正确记录 started/completed/failed。
- [x] TFTP 会话列表正确显示文件名和阶段。
- [x] 资产导入通过 daemon HTTP API 原子写入 catalog，SHA-256 自动计算。
- [x] 重复资产名、缺失文件和不安全路径被 daemon 拒绝。
- [x] `nodeforge asset validate` 校验所有资产的文件可读性和 SHA-256。
- [x] `nodeforged --check` 预检包含 UDP 69 TFTP 端口可用性。
- [x] systemd 快速重启正常，TFTP 与 HTTP listener 并行启动。

## 6.5 M1.5：CLI 输出统一架构

**完成状态（2026-07-11）：已实现并在 Rocky Linux 9.7 aarch64 的 `root@r97n0`
完成验证。** `asset list/show`、`tftp show/session list` 与 `status` 已迁移到统一 view/table
层；JSON 输出、退出码及 daemon API 保持兼容。验证记录见
[`ROCKY_9_7_VALIDATION.md`](ROCKY_9_7_VALIDATION.md#m15-cli-输出验证)。

### 6.5.1 目标与边界

M1 的 `asset list`、`tftp session list` 等命令已经证明，直接在 handler 中使用
`writer.print("{s}\t...`)` 会随字段长度产生不稳定的对齐。M1.5 建立唯一的 CLI 展示层，
让默认 human 输出像运维工具而不是调试日志；它是 M2+ DHCP、node、bundle 和 runtime 命令的
共同前置，不改变任何管理 API、catalog/config 事实源、退出码或 TFTP/DHCP 协议行为。

以下内容**不**属于 formatter：服务端 journal 日志、`events.jsonl`、HTTP JSON error envelope、
`config export`/`catalog export` 的原始 JSON，以及 `--output json`。这些输出保留既有
机器消费语义，不能为了好看而重排或加 ANSI 控制字符。

M2.5 新增的 `nodeforge events list/follow/types` 是该规则的边界案例：磁盘上的 JSONL 仍不经过
formatter；只有 CLI 解析后的 EventRow human view 使用 `cli/table.zig` 或单行 renderer，JSON 模式保持
v1/v2 事件的机器契约。

### 6.5.2 模块与依赖

新增目录仅归属 `nodeforge` CLI 二进制，不进入 daemon/core 领域模型：

```text
src/cli/
  output.zig    # OutputMode、TTY/颜色策略、成功/错误/详情入口
  table.zig     # 列定义、两遍宽度计算、截断和渲染
  views.zig     # AssetRow、TftpSessionRow、StatusView 等展示模型
```

依赖方向固定为：`main.zig handler -> cli/views -> cli/output/table -> std.Io.Writer`。
`cli/*` 可以读取已经获得的 domain 值，但不得加载文件、调用 HTTP、修改 catalog/config 或定义
另一套业务类型。handler 负责查询和构造 typed view；formatter 只决定布局。禁止通过反射或
字段名猜测列：列标题、顺序、对齐和隐藏规则是每种 view 的显式契约。

### 6.5.3 输出模型与接口

每个有 human/JSON 双输出的命令先构造同一事实模型；JSON 从该模型直接序列化，human 再通过
`render()` 渲染为表格或通过 `detailField()` 渲染为详情键值块。不得为展示重新读取 catalog，也不得让 JSON 经过表格渲染。

```zig
const Mode = enum { human, json };
const Alignment = enum { left, right };

const Column = struct {
    key: []const u8,       // stable view key; not necessarily the JSON field name
    title: []const u8,
    alignment: Alignment = .left,
    min_width: usize = 0,
    max_width: ?usize = null,
    // priority: u8 = 0,   // M2+: larger value is truncated first on narrow terminals
};

// render(writer, columns, rows, empty_message, options) is the table API;
// M1.5 does not use a Table wrapper struct.
// writeEscaped(writer, value) escapes control chars for detail/section views.
```

`views.zig` 至少定义 `AssetRow { name, kind, path }`、
`TftpSessionRow { id, phase, filename }` 和 `StatusView`。详情页使用键值块，而非一列表格；
同一命令的成功摘要由 `output.zig` 输出稳定的 `OK ...` 文本。错误仍沿用
`error: <category>: <brief reason>` 和 `-d/--debug` 的两层约定，不由 table 包吞掉。

### 6.5.4 Human 渲染规则

- 表格总是输出稳定的全大写表头；空列表输出明确的领域消息，例如 `No assets registered.`，不输出空表头。
- 表头之后必须输出与列宽一致的 `-` 分隔线；分隔线和列间两个空格由 table renderer 统一生成，
  handler 禁止自行插入 tab、空格或 ASCII 表格边框。
- formatter 先收集所有 cell 的可显示宽度，再统一输出；文本左对齐，ID、计数和大小右对齐。
- 宽度按 Unicode display width 而非字节数计算；ANSI SGR 序列不计入宽度。M1.5 不支持不确定宽度的控制序列。
- 检测到 TTY 时可使用颜色强调 `OK`/`WARN`/`ERROR`/`PENDING`，但颜色绝不表达唯一语义；非 TTY、
  `--output json` 和 `--no-color` 必须无 ANSI 字节。
- 若表格超过终端可用宽度，按 `max_width` 截断低价值 cell 并以 `…` 表示；名称、ID 和状态列不得静默截断。
  终端宽度不可获得时采用无颜色、无截断的安全布局。按列 `priority` 优先级截断为 M2+ 计划。
- 值中的换行、制表符和控制字符必须转义为可见文本，避免一个 catalog 字段破坏整张表。
- 不使用 `\t` 作为列布局机制；列间使用 formatter 计算出的空格。

`nodeforge asset list` 的目标输出为：

```text
NAME                    KIND        PATH
grub-uefi-aarch64       bootloader  efi/grubaa64.efi
grub-uefi-x86_64        bootloader  efi/grubx64.efi
test-kernel             kernel      boot/vmlinuz-test
grub-uefi-aarch64-v2    bootloader  efi/grubaa64-v2.efi
```

`asset show`、`status` 等详情型命令统一使用分组键值块：

```text
Asset
  Name       grub-uefi-aarch64
  Kind       bootloader
  Path       efi/grubaa64.efi
  SHA-256    <digest>
```

### 6.5.5 CLI 参数与迁移

`--output human|json` 继续是各叶子命令的局部参数，默认 `human`；M1.5 不添加 CSV、YAML 或
自动探测机器模式。`--color`/`--no-color` 作为首个通用展示 flag 已挂载，但 M1.5 暂不输出 ANSI
颜色；该 flag 为 M2+ TTY 颜色支持预留入口，不改变 JSON、help、export 或 daemon 日志。

迁移按以下顺序进行：

1. 实现 `cli/output.zig`、`cli/table.zig` 和单元测试，不修改命令语义。
2. 迁移 `asset list/show`、`tftp show`、`tftp session list`；删除这些 handler 中的 tab 和手写对齐。
3. 迁移 `status`/`check`，保持其既有退出码和 `OK` 成功摘要。
4. M2 及以后新增 list/show/status/plan 命令只能构造 view 并调用统一 renderer；code review 禁止 handler 直接拼多列 human 输出。

M1.5 完成后，**所有 `nodeforge` 命令的 human 业务输出**必须经过 `cli/output.zig` 或
`cli/views.zig`：列表使用 table、详情使用分组键值块、成功/失败摘要使用统一块。仅有以下明确例外：

- zli 自动生成的 `--help`/usage 和顶层 version；
- `config export`、`catalog export` 的原始 JSON；
- `--output json` 的机器结果；
- 一行 CLI 错误和 `-d` debug 原因（它们遵循独立、稳定的错误契约）；
- daemon journal、HTTP error envelope、events JSONL（均非 `nodeforge` human view）。

因此新增命令的 review 项目是“是否构造了 typed view 并调用 formatter”，而不是“是否手工排好了空格”。

### 6.5.6 测试与验收

- table 单元测试覆盖空表、单行/多行、可变列宽、右对齐数值、Unicode 宽字符、控制字符转义、
  窄终端截断和 `--no-color`。控制字符和无效 UTF-8 的 display width 统一为 4（`\xNN`）；
  `writeEscaped` 为详情/状态块提供与 `writeCell` 一致的转义。
- CLI 契约测试覆盖 `asset list`、`asset show`、`tftp session list` 和 `status` 的 human 快照；
  快照在非 TTY 下运行，确保没有 ANSI 字节。
- 每个迁移命令的 `--output json` 必须可解析，字段、退出码和事实值与迁移前一致；human 版允许优化布局，
  但不得删除关键状态。
- 检查同一数据在长短字段下列首对齐，且空列表、错误和 debug 输出不被表格 renderer 改写。

## 7. M2：DHCP + PXE 闭环

**完成状态（2026-07-11）：M2 DHCPv4 与 UEFI PXE/TFTP 闭环完成。** 已实现 DHCP
生命周期、option 53/50/54/60/61/82/93/97、relay 回包路由、静态保留地址排除、运行态持久化、
未知节点观察、PXE bootfile 决策和 ICMP Ping Probe。`r97n0` 的
`192.168.27.0/24` 已完成 DISCOVER/OFFER/REQUEST/ACK、RELEASE、冲突隔离和管理 CLI/API
验证。独立 VMware ARM UEFI 客户端已实际消费 DHCP option 67 的 `efi/grubaa64.efi`，经 TFTP
进入 GRUB 2.06；详情见 [`ROCKY_9_7_VALIDATION.md`](ROCKY_9_7_VALIDATION.md#m2-dhcp-验证)。

### 7.1 目标

在 PXE 管理网段内提供 authoritative DHCP：

- 未知节点获得临时 lease，并默认等待管理员认领。
- 已登记节点获得静态 IP 或稳定 lease。
- DHCP 返回 `next-server` 和 bootfile。
- 租约和事件进入运行态。

### 7.2 代码任务

| 模块 | 任务 |
| --- | --- |
| `dhcp/packet.zig` | BOOTP/DHCP 报文和 option 解析/编码 |
| `dhcp/server.zig` | UDP 67 loop、lease 分配、续租、释放、过期和错误处理 |
| `boot/resolver.zig` | 节点身份到 node/profile/bootfile 的唯一决策入口 |
| `state/runtime.zig` | 运行态 lease 写入 |

### 7.3 DHCP 行为

必须处理：

- `DISCOVER` -> `OFFER`
- `REQUEST` -> `ACK` / `NAK`
- `RELEASE`
- `DECLINE`

必须识别：

- option 53 message type
- option 50 requested IP
- option 54 server identifier
- option 60 vendor class
- option 61 client identifier
- option 82 relay agent information（含 RFC 3527 Link Selection 子选项）
- option 93 client system architecture
- option 97 client UUID

协议对齐要求：

- 基础报文遵循 RFC 2131/2132；PXE 架构识别遵循 RFC 4578，优先使用 option 93，不从 vendor class 字符串猜架构。
- option 60 仅用于识别 `PXEClient`、HTTPClient 等标准 vendor class；MVP 不定义私有 option 43 子选项。
- option 61 是客户端标识辅助信息，不替代 MAC 与显式 node 绑定。
- **Linux DHCP 广播接收边界**：客户端在获得地址前向 `255.255.255.255:67` 广播。Linux 不会把这类
  datagram 投递给只绑定 `server.server_ip` 的 socket，因此 DHCP listener 必须绑定 wildcard
  UDP/67；同时必须以 `SO_BINDTODEVICE(server.bind_interface)` 限定接收/发送接口，避免多网卡主机
  在管理网段回答请求。TFTP 仍只绑定 `server.server_ip:69`，因为 DHCP 已明确将该地址作为
  `next-server` 广告给客户端。
- **ACK 归属约束**：动态地址（未知节点和没有静态保留地址的已登记节点）必须先存在同一 MAC 的未过期
  OFFER，才会转换为 ACK；任意 REQUEST 不能取得池内地址。唯一例外是已登记节点声明的静态保留地址，
  它可在服务重启后没有内存 OFFER 的情况下确认其配置 IP。
- **M2 生命周期边界**：DHCP/TFTP worker 当前为 detached 长循环；进程退出会关闭 socket 终止 worker，
  尚无配置热重载或独立 graceful shutdown 协调器。引入运行期重载或独立停服能力前必须添加取消信号、
  worker join 与 listener drain，这属于后续生命周期管理工作。
- **`giaddr` 处理（RFC 2131 标准行为）**：当收到的 DHCP 报文 `giaddr` 非零时，表示报文经由外部 relay agent（路由器 IP Helper 或 `dhcrelay`）转发。服务器基于 `giaddr` 或 option 82 中的 RFC 3527 Link Selection 子选项定位目标 subnet，而非使用接收接口的 subnet。回复报文按 RFC 2131 Section 4.1 发送到 `giaddr:67`（relay agent 的 UDP 67 端口），而非广播或直接发给客户端。这是任何 RFC 2131 合规 DHCP 服务器的基本行为，不是独立功能特性。NodeForge 自身不实现 relay agent。参考 ISC DHCP `locate_network()`（`server/dhcp.c`）和 `bootp()`（`server/bootp.c`）的实现。
- **服务器端地址冲突检测（Ping Probe）**：在发送 DHCPOFFER 前，对候选 IP 发送 ICMP Echo Request。在配置的超时内（默认 500ms）未收到与该请求匹配的 Echo Reply 才发送 OFFER；Linux raw socket 收到自身发出的 Echo Request 或其他无关 ICMP 报文时，必须继续等待同一个绝对 deadline，不能提前判定地址空闲。收到匹配回复则调用 `abandon_lease()` 标记该 IP 为 abandoned 状态（保持 `abandon_lease_time`，默认 1 小时），并尝试下一个候选 IP。raw socket 打开、发送或接收失败时必须取消该 pending OFFER 并不回复，绝不能把 `unavailable` 当成 `clear`。Linux 服务单元需要 `CAP_NET_RAW` 和 `CAP_NET_BIND_SERVICE`。参考 ISC DHCP `do_ping_check()`/`lease_pinged()`/`abandon_lease()` 实现。
- 未识别 option 必须安全跳过并保留报文边界；编码顺序稳定，必须正确写 end option 255。
- `vendor/dhcp/` 保存去标识化的真实 DHCPv4 fixture、来源说明和期望解析结果。基于 ISC DHCP 源码重构实现，不直接链接 C 代码。
- 只实现 DHCPv4；不监听 UDP 546/547，不解析 DHCPv6，也不输出 IPv6 地址。

返回基础 option：

- subnet mask
- router
- DNS
- lease time
- server identifier
- renewal/rebinding time 可后续补充

返回 PXE 字段：

- `next-server`
- `bootfile`

### 7.4 DHCP 决策

```text
收到 DHCP 请求
  -> 解析 MAC/client id/arch
  -> 查找 node
  -> 已绑定 node:
       选择 node.profile
       合并 profile 默认值和 node override
       使用静态 IP 或现有 lease
       选择 bootfile
  -> 未绑定 node:
       分配临时 lease
       记录 unknown_client
       读取 dhcp.discovery.default_action
       wait:
         不执行安装/无盘，必要时返回只读等待或诊断 bootfile
       discovery:
         返回非破坏性 discovery profile
       diskless:
         仅当 allow_unknown_diskless=true 且 profile safety 满足 safe/ephemeral 时返回 diskless bootfile
       deny:
         不返回 PXE bootfile 或按策略拒绝
  -> DISCOVER 的候选地址执行 Ping Probe
       clear: 写 OFFER/state/event 并回复
       occupied: abandon 当前地址，选择下一个候选
       unavailable: 取消 pending OFFER，只记录诊断，不回复
  -> REQUEST/RELEASE/DECLINE 写 lease/state/event
  -> 返回 ACK/NAK 或无回复
```

### 7.5 CLI 命令

```bash
nodeforge dhcp show
nodeforge runtime leases list
nodeforge runtime unknown list
nodeforge node list
```

这四个命令是当前 M2 的只读运维面：`dhcp show` 从启动配置读取站点地址池，
`runtime leases/unknown list` 从 daemon 运行态读取租约，`node list` 从已加载配置读取 MAC、
保留地址和 profile。它们同时支持 `--output json`。

`dhcp network/pool/discovery update`、`node add/update` 和 `node oob update` 需要 daemon 原子
配置写入、重载策略以及 tags/vars/OOB 的事实模型；当前 schema 没有这些字段，因此它们不是已实现
命令，也不得在文档或 help 中宣称可用。管理员目前通过 `config validate`、`config import` 和重启
daemon 变更 DHCP/node 声明；在线变更属于后续配置管理阶段。

### 7.6 测试

单元测试：

- DHCP packet decode/encode。
- option 60/61/82/93/97 解析，含 RFC 3527 Link Selection。
- `giaddr` 非零时的 subnet 定位和回复路由。
- 租约池分配、ACK、释放、DECLINE、过期回收和持久化恢复。
- 静态 IP 冲突检测。
- 服务器端 ICMP Ping Probe：raw socket 自回显忽略、共享 deadline、冲突 abandon、替代地址 ACK，
  以及 probe 不可用时 pending OFFER 回滚。

集成测试：

- 用 fixture 验证 UEFI x86_64/aarch64 DISCOVER。
- 使用虚拟网络或测试 UDP client 完成 DISCOVER/REQUEST。
- 未知节点身份默认进入等待认领；显式配置后可进入非破坏性 discovery 或 safe/ephemeral diskless。

### 7.7 阶段验收

- 未知节点能获得临时 IP。
- 未知节点默认不执行安装或无盘启动。
- 已登记节点能获得指定 IP。
- DHCP 按 option 93 返回启动文件：UEFI x86_64 使用 `grubx64.efi`，UEFI aarch64 使用 `grubaa64.efi`。
- M2 已完成验收时，`events.jsonl` 出现 v1 的 `dhcp.discover`、`dhcp.offer`、`dhcp.ack`；M2.5 迁移后
  同一验收改为验证对应 v2 事件及 `mac`、`ip`、`xid`、`kind` 字段，历史 v1 fixture 保留为兼容测试。
- `r97n0` 受控验证另确认 `dhcp.abandoned` 与 `dhcp.release`；见 Rocky 验证记录。
- 独立 VMware ARM UEFI 客户端在 `192.168.27.0/24` 实际消费 option 67 的
  `efi/grubaa64.efi`、完成 TFTP bootloader 传输并进入 GRUB 2.06；该实机记录见 Rocky 验证文档。

## 7.5 M2.5：结构化日志与事件系统改进

> **完成状态（2026-07-11）：已实现并在 Rocky Linux 9.7 aarch64 的 `root@r97n0` 完成验证。**
> Event v2 writer、注册表、日志后端、DHCP/TFTP/HTTP 接线和 `nodeforge events` 本机查询均已落地；
> 验证记录见 [`ROCKY_9_7_VALIDATION.md`](ROCKY_9_7_VALIDATION.md#m25-结构化日志与事件验证)。

### 7.5.0 跨阶段重构范围与实施门槛

M2.5 是对 M0–M2 共同基础设施的**横切重构**，不是仅向 DHCP 增加几个日志调用。它不改变
DHCP/TFTP/HTTP 的线协议、配置/catalog 事实源或 M0 管理路由语义，但会替换这些阶段共享的日志、
事件、应用生命周期和 CLI 读取边界。后续 M3–M7 必须建立在该契约上，不得各自创建新的 event writer、
JSONL 格式或节点日志文件。

| 阶段 | 必须调整的既有边界 | M2.5 完成后的责任 |
| --- | --- | --- |
| M0 / 公共骨架 | `model.zig`、配置校验、`paths.zig`、三个 root module、`app.zig` 生命周期 | 配置并初始化日志后端和唯一 EventWriter；在启动所有 worker 前完成初始化，在可控退出时 flush/close 并写 `service.stopped` |
| M1 / TFTP | `tftp/server.zig`、session 状态和 M1 集成测试 | 使用 `.tftp` scope 和共享 writer；RRQ、成功、超时/重传、失败与路径拒绝遵守 v2 字段和等级契约 |
| M1.5 / CLI | `cli/views.zig`、`cli/output.zig`、CLI contract tests | 原始 JSONL 不经过 formatter；`nodeforge events` 把解析后的 EventRow 作为新的 typed view，human 输出复用 formatter |
| M2 / DHCP | `dhcp/server.zig` 的 `audit()`、持久化错误路径和 M2 fixture | 删除 v1 message 拼接；共享 writer 写 v2，保留协议响应语义；M2 已完成验收中的 v1 文件样例作为升级兼容 fixture |
| M3 / HTTP | access log、节点事件/日志摘要接收、静态资产路由 | HTTP access 只产生 `http.request`；节点上报经受限 DTO 验证后映射到注册事件，不能把客户端 JSON 原样追加到 JSONL |
| M4 / M5 | installer hook、firstboot、小 initrd、`node_status` | 安装和无盘阶段从注册表选择事件类型；先更新运行态，再尝试追加事件；失败摘要受同一长度与脱敏限制 |
| M6 / M7 | 错误分类、provision runner、script/archive 输出 | 错误 code 映射为 err/warn 与稳定事件；脚本 stdout/stderr 只保留有界摘要，不能绕过事件/服务日志边界 |

共享依赖方向固定如下：

```text
protocol / runner
  -> std.log.scoped(service diagnostics)
  -> Observability.emit(EventType, message, fields)
       -> state/events.Writer (唯一 JSONL writer)

CLI events reader
  -> rotated events.jsonl files (只读、兼容 v1/v2)
```

`Observability` 由 `app.zig` 创建并把 writer 指针传给 DHCP、TFTP、HTTP 和后续 runner；协议模块不得
自行打开日志文件、创建第二个 mutex 或依赖 CLI 包。日志/事件写入失败只记录诊断和计数，**不得**改变
已经确定的 DHCP reply、TFTP ERROR、HTTP response 或运行态状态转移，避免可观测性故障反向造成 PXE
服务不可用。

M0 当前 worker 可 detach 的实现不能满足“关闭时 drain/写 stopped event”的新契约。M2.5 的前置改造是
引入最小 shutdown coordinator：收到退出请求后停止接收新工作、关闭 listener/socket、等待已启动 worker
退出、flush 日志和事件 writer，最后释放后端。`service.started` 只能在 HTTP、TFTP、DHCP 均成功就绪后
写入；初始化失败或不可控进程终止不伪造 `service.stopped`。这项生命周期改造先于任何协议日志迁移。

### 7.5.1 背景与问题

M0–M2 阶段建立了基础日志（`observe/log.zig`）和事件写入器（`state/events.zig`），但随着
DHCP/TFTP/HTTP 三个协议 worker 并发运行，暴露出以下不足：

**服务日志（`observe/log.zig`）：**

| 问题 | 说明 |
| --- | --- |
| 使用 `std.debug.print` | 虽然 Zig 0.16 会串行化 stderr，但没有统一的 scope、时间戳、运行期过滤或可组合后端；无法保证 stderr 与文件 sink 作为同一条记录写入 |
| 无时间戳 | 日志行不含时间，无法关联事件和排查时序 |
| 无模块/作用域标识 | 所有日志混在一起，无法区分来源（dhcp/http/tftp/app） |
| 只有 info/debug 两级 | 缺少 warn 级别；error 级别不与 `std.log` 体系对齐 |
| 无文件后端 | 仅输出到 stderr，systemd 下依赖 journal；无法独立轮转文件日志 |
| 无轮转 | 事件文件 `events.jsonl` 无限增长，无大小限制和自动截断 |

**事件日志（`state/events.zig`）：**

| 问题 | 说明 |
| --- | --- |
| 事件缺少结构化字段 | DHCP 事件把 `mac`、`ip`、`kind` 拼接进 `message` 字符串，无法被消费者程序化过滤 |
| 时间戳格式非标准 | 使用 `unix:<UTC seconds>` 字符串，不是 ISO 8601，外部工具解析不便 |
| HTTP 请求无事件 | HTTP 请求仅记 info 日志，不写事件，无法审计请求历史 |
| TFTP 完全无日志/事件 | TFTP 传输成功和失败均无任何记录 |
| 无查询接口 | `events.jsonl` 只能手动 `tail -f` / `grep`，无法按类型、节点、时间范围过滤 |

**HTTP 请求日志：**

| 问题 | 说明 |
| --- | --- |
| 缺少客户端 IP | 当前仅记录 method/path/status，无法定位请求来源 |
| 缺少响应大小和耗时 | 无法评估传输性能和诊断慢请求 |
| Zap 内置 `http_write_log` 未启用 | facil.io 有完整的 access log 实现，但被禁用 |

### 7.5.2 设计目标

1. **线程安全**：多 worker 并发日志与事件不交错；正常运行中，后端接受的记录不被静默丢弃。
2. **结构化**：服务日志带时间戳、级别、作用域；事件日志带结构化 key-value 字段。
3. **可配置**：日志级别、输出后端（stderr/file/journal）、文件轮转大小可配置。
4. **可查询**：提供 CLI 命令查询和过滤事件，支持 human 和 JSON 两种输出。
5. **不引入外部依赖**：自研实现，基于 Zig 标准库 `std.log`、`std.Io`、`std.fs` 和 `std.json`；不引入 `zlog`、Zap/facil.io 日志或其他日志库。
6. **边界清晰**：服务日志用于进程诊断；`events.jsonl` 用于可查询的业务审计。两者可以描述同一次操作，但不得互相作为事实源或恢复来源。

本阶段不增加 daemon HTTP 管理 API。`nodeforge events` 是本机只读文件消费者，直接读取
`/opt/nodeforge/logs/events.jsonl` 及其轮转文件；它不写入事件文件、不绕过 daemon 修改任何运行态。
安装包必须让执行 `nodeforge` 的受信任运维用户对日志目录具有只读权限。

### 7.5.3 服务日志改进

#### 7.5.3.1 基于 `std.log.scoped` 的日志门面

将 `observe/log.zig` 从 `std.debug.print` 迁移到 `std.log.scoped`：

```zig
const std = @import("std");

pub const log = std.log.scoped(.nodeforge);

pub fn info(comptime format: []const u8, args: anytype) void {
    log.info(format, args);
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    log.warn(format, args);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    log.err(format, args);
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    log.debug(format, args);
}
```

`std.log.scoped` 只负责把编译期 scope 和 level 传给后端。Zig 0.16 的默认后端会安全地串行
stderr，但默认格式不含时间戳，也不提供文件轮转；NodeForge 必须安装自定义 `std.options.logFn`，
统一渲染时间戳、scope 和两个 sink。

各协议 worker 使用独立 scope：

| 模块 | scope |
| --- | --- |
| `dhcp/server.zig` | `std.log.scoped(.dhcp)` |
| `http/server.zig` | `std.log.scoped(.http)` |
| `tftp/server.zig` | `std.log.scoped(.tftp)` |
| `app.zig` / `nodeforged.zig` | `std.log.scoped(.nodeforge)` |

`observe/log.zig` 作为通用门面保留 `.nodeforge` scope，供非协议模块使用。

#### 7.5.3.2 日志级别

从 `info`/`debug` 两级扩展为标准四级：

```zig
pub const LogLevel = enum { debug, info, warn, err };
```

- **debug**：协议包解析细节、连接建立/关闭、候选 IP 选择过程。
- **info**：正常服务事件（DHCP DISCOVER→OFFER、HTTP 请求摘要、TFTP 传输完成）。
- **warn**：可恢复异常（地址冲突探测失败后重试、TFTP 超时重传、配置降级）。
- **err**：不可恢复错误（响应编码失败、文件写入失败、运行态持久化失败）。

`std.log.Level` 的严重度顺序是 `err`、`warn`、`info`、`debug`。配置模型可保持对用户友好的
`LogLevel` 枚举，但必须显式映射到 `std.log.Level`，不得依赖两个枚举的声明顺序。

每个会链接 NodeForge 日志调用的 root module（`nodeforged.zig`、`main.zig` 和核心 test root）均设置：

```zig
pub const std_options: std.Options = .{
    // 保留 debug 调用，之后才能由运行期阈值决定是否输出。
    .log_level = .debug,
    .logFn = log_backend.logFn,
};
```

编译期阈值固定为 `.debug`；`log_backend` 使用原子 `u8` 保存映射后的运行期阈值，并以
`@intFromEnum(level) <= @intFromEnum(runtime_threshold)` 判断是否输出。这样 `logging.level` 与
daemon `--debug` 可在启动完成前设置，且不会让 debug 调用在 release 构建中被裁掉。M2.5 不提供
在线修改日志级别的 API；“运行期”仅指同一二进制在启动参数和已加载配置之间选择阈值。

#### 7.5.3.3 日志后端与轮转

| 后端 | 触发条件 | 说明 |
| --- | --- | --- |
| stderr | 默认 | 前台运行或 `--foreground` 时直接输出到 stderr |
| systemd journal | `systemd` unit 启动 | stderr 自动被 journald 捕获，无需额外代码 |
| 文件 | 配置 `logging.file` | 写入指定路径，支持按大小轮转 |

文件日志轮转策略：

```json
{
  "logging": {
    "level": "info",
    "file": {
      "path": "/opt/nodeforge/logs/nodeforged.log",
      "max_size_mb": 50,
      "keep": 3
    }
  },
  "events": {
    "max_size_mb": 100,
    "keep": 5
  }
}
```

- `file` 是 stderr 的**附加** sink；配置后每条服务日志同时写 stderr 和文件。journal 仍通过
  stderr 采集，不需要也不得启动独立的 journald/syslog client。
- 在同一 sink mutex 内，以“当前文件大小 + 已渲染行长度”判断是否轮转；因此除单条超限记录外，
  活动文件不会超过阈值。单条超限记录写入空的新文件，并在消息末尾加 `truncated=true`。
- 轮转顺序为删除最旧 `.keep`、从大到小移动 `.N`、将活动文件 rename 为 `.1`、创建新活动文件。
  所有 rename 都在同一目录内执行；写入器只在成功创建新文件后继续写入。
- `keep` 的有效范围是 `1..20`，`max_size_mb` 必须大于零。文件路径必须为绝对路径，父目录必须在
  daemon 启动前存在且可写；文件以服务用户可读写、其他用户不可读的权限创建。
- `file` 未配置或为 `null` 时，不启用文件 sink，仅输出 stderr。文件打开、轮转或写入失败时，
  服务继续向 stderr 输出，并以节流的固定错误行报告后端降级；不得通过同一失效后端递归记录错误。

自定义 `logFn` 实现（覆盖 `std.log` 默认行为）：

```zig
// src/observe/log_backend.zig
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // 1. std.options.log_level 固定为 .debug；这里只做原子运行期过滤。
    if (!enabled(level)) return;

    // 2. 渲染日志行：<ISO8601> <LEVEL> [<scope>] <message>\n
    var buf: [max_line_bytes]u8 = undefined;
    const line = renderLogLineBounded(&buf, level, scope, format, args);

    // 3. 同一 mutex 覆盖 stderr、文件大小检查、轮转和整行写入。
    sink_mutex.lockUncancelable(io);
    defer sink_mutex.unlock(io);
    writeStderr(line);
    if (file_backend) |*backend| backend.writeOrReportDegraded(line);
}
```

`max_line_bytes` 固定为 8 KiB，包含时间戳、metadata 和换行。格式化超过上限时后端保留合法的一行，
在可用尾部追加 `… [truncated]`；不得 panic、分多行写入或分配无上限内存。日志调用中的动态字符串仍由
调用方限制，特别是不得把 HTTP body、token、密码、cookie、Authorization 或节点上传原始日志传入格式化参数。

服务日志是诊断输出而非逐条持久化审计：M2.5 在每条写入后 flush，但不对每条调用 `fsync`；断电时最后
少量已接受记录可能丢失。需要可靠查询的业务动作必须同时尝试写入事件文件，并在事件写入失败时记录 err。

#### 7.5.3.4 配置模型变更

`LoggingConfig` 扩展：

```zig
pub const LoggingConfig = struct {
    /// 服务日志等级。
    level: LogLevel = .info,
    /// 文件日志后端配置；为 null 时仅输出到 stderr。
    file: ?FileLogConfig = null,
};

pub const FileLogConfig = struct {
    /// 日志文件路径。
    path: []const u8,
    /// 单文件最大大小（MB），达到后触发轮转。
    max_size_mb: u16 = 50,
    /// 保留的历史轮转文件数量。
    keep: u8 = 3,
};

/// 用户配置的阈值；toStdLevel() 显式映射到 std.log.Level。
pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,

    pub fn toStdLevel(self: LogLevel) std.log.Level {
        return switch (self) {
            .debug => .debug,
            .info => .info,
            .warn => .warn,
            .err => .err,
        };
    }
};

pub const EventsConfig = struct {
    /// 活动 events.jsonl 的最大大小；达到前按下一行长度预检查。
    max_size_mb: u16 = 100,
    /// 保留的历史 events.jsonl.N 数量。
    keep: u8 = 5,
};
```

`AppConfig` 新增 `events: EventsConfig = .{}`。校验器拒绝 `max_size_mb == 0` 和不在 `1..20`
范围内的 `keep`；日志与事件轮转参数均在 daemon 启动时固定，配置热更新属于后续阶段。

### 7.5.4 事件日志改进

#### 7.5.4.1 Event v2 结构化字段

引入 `v: 2` 事件格式，增加 `fields` 数组承载结构化字段。事件格式是对外稳定的本地读取契约：
新增字段只能以默认值扩展，既有字段不得改名或改变语义。

```zig
pub const Event = struct {
    /// 事件信封版本。
    v: u8 = 2,
    /// ISO 8601 UTC 时间戳，例如 `2026-07-11T08:30:00Z`。
    ts: []const u8,
    /// 事件类型。
    @"type": []const u8,
    /// 人类可读摘要。
    message: []const u8,
    /// 结构化字段列表；v2 新增。
    fields: []const Field = &.{},
};

pub const Field = struct {
    key: []const u8,
    value: []const u8,
};
```

v2 事件 JSONL 示例：

```json
{"v":2,"ts":"2026-07-11T08:30:00Z","type":"dhcp.ack","message":"DISCOVER -> ACK yiaddr=192.168.27.10","fields":[{"key":"mac","value":"52:54:00:aa:bb:cc"},{"key":"ip","value":"192.168.27.10"},{"key":"xid","value":"0x1234abcd"},{"key":"kind","value":"discover"}]}
```

#### 7.5.4.2 预定义字段约定

| 字段 key | 说明 | 出现的事件类型 |
| --- | --- | --- |
| `mac` | 客户端 MAC 地址 | `dhcp.*`、`tftp.*` |
| `ip` | 分配/请求的 IP 地址 | `dhcp.*` |
| `xid` | DHCP 事务 ID | `dhcp.*` |
| `kind` | DHCP message type | `dhcp.*` |
| `node_id` | 节点标识 | `dhcp.*`、`http.*`、`tftp.*` |
| `source` | 产生者：`server`、`initrd`、`installer`、`agent` 或 `runner` | 所有由 M3+ 节点/runner 上报的事件 |
| `stage` | 安装或无盘启动阶段 | `install.*`、`diskless.*` |
| `reason` | 稳定错误 code 或有限摘要 | `*.failed`、`*.error` |
| `method` | HTTP 方法 | `http.request` |
| `path` | HTTP 路径 | `http.request` |
| `status` | HTTP 状态码 | `http.request` |
| `client_ip` | HTTP 客户端 IP | `http.request` |
| `duration_us` | 请求耗时（微秒） | `http.request` |
| `bytes_sent` | 传输字节数 | `http.request`、`tftp.transfer` |
| `filename` | 传输的文件名 | `tftp.transfer` |
| `arch` | 客户端架构 | `dhcp.*` |
| `phase` | provisioning 阶段 | `provision.*` |
| `step` | provisioning step 名称 | `provision.*` |
| `run_id` | provisioning 执行标识 | `provision.*` |

字段值为字符串类型；数值在渲染时转为字符串。这避免了 JSON 类型混合导致的解析复杂度，
同时保持 JSONL 行的扁平性和可 grep 性。

字段约束：每个事件最多 32 个 field，key 最长 64 bytes、value 最长 1024 bytes、message 最长
2048 bytes，整行不得超过 8 KiB。key 必须匹配 `[a-z][a-z0-9_]*` 且在同一事件内唯一；不认识的
key 可以保留以支持后续阶段，但不得覆盖表中已定义 key 的含义。JSON encoder 负责转义控制字符，
调用方不得自行拼接 JSON。路径字段只记录路由模板或经过净化的相对资产路径，不记录 query string。

`ts` 固定使用 UTC RFC 3339 秒精度格式 `YYYY-MM-DDTHH:MM:SSZ`。写入器无法取得实时时钟或无法
格式化时间时返回错误并由调用方记录服务 err，绝不伪造 `unix:0` 或本地时区时间。

#### 7.5.4.3 事件写入器改进

`state/events.zig` 的 `Writer` 保持单一 mutex 串行写入模型，增加 `fields` 支持。mutex 覆盖整行
渲染后的大小检查、轮转和追加操作，不能只保护 `write()`；这样同一进程中的 DHCP、TFTP 和 HTTP
worker 不会相互覆盖文件尾部。

```zig
pub fn appendWithFields(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    event_type: []const u8,
    message: []const u8,
    fields: []const Field,
) !void {
    // 1. 验证 event_type、message 和 fields 的长度、key 格式与唯一性
    // 2. 生成 RFC 3339 UTC 时间戳并构建 Event v2
    // 3. 一次性渲染为不超过 8 KiB 的 JSON 行
    // 4. 持有 Writer mutex，按“size + line.len”轮转后以 append 模式写入整行
}
```

底层文件以 append 模式打开，单个 JSON 行只执行一次完整写入；同进程互斥不替代跨进程锁，因此
`nodeforged` 是 events 文件唯一 writer，禁止运维脚本和 CLI 直接追加。事件写入同样不逐条 `fsync`，
其保证是“函数成功返回时数据已交给本地文件系统”；进程崩溃或断电可以留下最后一条不完整记录。
读取器必须忽略活动文件的**最后一条**无效 JSON 行并在 human 模式给出 warning；历史轮转文件中出现
无效行则跳过该行并计数，不能让一次损坏阻断后续有效事件。

DHCP `audit()` 函数改为传递结构化字段而非拼接字符串：

```zig
// 改进前（v1）：
fn audit(..., mac: []const u8, ip: u32) void {
    const text = bufPrint("kind={t} mac={x} ip={x}", .{kind, mac, ip});
    writer.append(..., .{ .ts = stamp, .type = event_type, .message = text });
}

// 改进后（v2）：
fn audit(..., mac: []const u8, ip: u32, xid: u32) void {
    const fields = [_]Field{
        .{ .key = "mac", .value = mac },
        .{ .key = "ip", .value = formatIp(ip) },
        .{ .key = "xid", .value = formatXid(xid) },
        .{ .key = "kind", .value = @tagName(kind) },
    };
    writer.appendWithFields(..., event_type, message, &fields);
}
```

#### 7.5.4.4 事件类型注册表

建立事件类型注册表，确保事件类型的稳定性和可发现性。注册表是含 `name`、`description` 和
`default_level` 的静态表；`EventType.definition()` 覆盖所有枚举值，禁止遗漏映射。
服务端写事件通过 `EventType`，CLI `events types` 从同一张表渲染，避免字符串散落在协议模块。

```zig
// src/state/event_types.zig
pub const EventType = enum {
    service_started,
    service_stopped,
    config_loaded,
    config_updated,
    dhcp_discover,
    dhcp_offer,
    dhcp_request,
    dhcp_ack,
    dhcp_nak,
    dhcp_release,
    dhcp_decline,
    dhcp_abandoned,
    tftp_rrq,
    tftp_transfer_complete,
    tftp_transfer_error,
    http_request,
    install_installer_started,
    install_config_fetched,
    install_started,
    install_partitioning,
    install_packages,
    install_bootloader,
    install_post,
    install_rebooting,
    install_completed,
    install_failed,
    diskless_initrd_started,
    diskless_rootfs_download_started,
    diskless_rootfs_verified,
    diskless_rootfs_mounted,
    diskless_switch_root,
    diskless_running,
    diskless_failed,
    provision_step_started,
    provision_step_succeeded,
    provision_step_warned,
    provision_step_failed,

    pub fn definition(self: EventType) EventDefinition {
        return switch (self) {
            .service_started => .{ .name = "service.started", .description = "all listeners ready" },
            .service_stopped => .{ .name = "service.stopped", .description = "orderly shutdown complete" },
            .config_loaded => .{ .name = "config.loaded", .description = "validated configuration loaded" },
            .config_updated => .{ .name = "config.updated", .description = "configuration atomically updated" },
            .dhcp_discover => .{ .name = "dhcp.discover", .description = "DHCP DISCOVER received" },
            .dhcp_offer => .{ .name = "dhcp.offer", .description = "DHCP OFFER sent" },
            .dhcp_request => .{ .name = "dhcp.request", .description = "DHCP REQUEST received" },
            .dhcp_ack => .{ .name = "dhcp.ack", .description = "DHCP ACK sent" },
            .dhcp_nak => .{ .name = "dhcp.nak", .description = "DHCP NAK sent" },
            .dhcp_release => .{ .name = "dhcp.release", .description = "lease released" },
            .dhcp_decline => .{ .name = "dhcp.decline", .description = "address declined" },
            .dhcp_abandoned => .{ .name = "dhcp.abandoned", .description = "probe found conflict" },
            .tftp_rrq => .{ .name = "tftp.rrq", .description = "TFTP read requested" },
            .tftp_transfer_complete => .{ .name = "tftp.transfer.complete", .description = "TFTP transfer completed" },
            .tftp_transfer_error => .{ .name = "tftp.transfer.error", .description = "TFTP transfer failed" },
            .http_request => .{ .name = "http.request", .description = "HTTP request completed" },
            .install_installer_started => .{ .name = "install.installer_started", .description = "installer started" },
            .install_config_fetched => .{ .name = "install.config_fetched", .description = "install config fetched" },
            .install_started => .{ .name = "install.started", .description = "installation started" },
            .install_partitioning => .{ .name = "install.partitioning", .description = "partitioning in progress" },
            .install_packages => .{ .name = "install.packages", .description = "package installation in progress" },
            .install_bootloader => .{ .name = "install.bootloader", .description = "bootloader installation in progress" },
            .install_post => .{ .name = "install.post", .description = "post-install phase in progress" },
            .install_rebooting => .{ .name = "install.rebooting", .description = "installer rebooting" },
            .install_completed => .{ .name = "install.completed", .description = "installation completed" },
            .install_failed => .{ .name = "install.failed", .description = "installation failed", .default_level = .err },
            .diskless_initrd_started => .{ .name = "diskless.initrd_started", .description = "diskless initrd started" },
            .diskless_rootfs_download_started => .{ .name = "diskless.rootfs_download_started", .description = "rootfs download started" },
            .diskless_rootfs_verified => .{ .name = "diskless.rootfs_verified", .description = "rootfs verified" },
            .diskless_rootfs_mounted => .{ .name = "diskless.rootfs_mounted", .description = "rootfs mounted" },
            .diskless_switch_root => .{ .name = "diskless.switch_root", .description = "switch_root started" },
            .diskless_running => .{ .name = "diskless.running", .description = "diskless system running" },
            .diskless_failed => .{ .name = "diskless.failed", .description = "diskless boot failed", .default_level = .err },
            .provision_step_started => .{ .name = "provision.step.started", .description = "provisioning step started" },
            .provision_step_succeeded => .{ .name = "provision.step.succeeded", .description = "provisioning step succeeded" },
            .provision_step_warned => .{ .name = "provision.step.warned", .description = "optional provisioning step warned", .default_level = .warn },
            .provision_step_failed => .{ .name = "provision.step.failed", .description = "required provisioning step failed", .default_level = .err },
        };
    }
};

pub const EventDefinition = struct {
    name: []const u8,
    description: []const u8,
    default_level: LogLevel = .info,
};
```

#### 7.5.4.5 事件文件轮转、读取与保留

`events.jsonl` 增加基于大小的轮转：

- 配置项 `events.max_size_mb`（默认 100 MB）与 `events.keep`（默认 5）。日志文件相同的阈值、
  同目录 rename、从大到小移动和写入失败降级规则同样适用。
- `events list` 默认从最旧保留文件到活动文件扫描，因而在不使用索引的前提下仍能得到时间顺序结果。
  `--limit` 默认 100、最大 1000；实现使用有界结果缓存，不能因日志总量无限占用内存。
- v1 的 `unix:<seconds>` 与 v2 的 RFC 3339 时间都先解析为 UTC epoch 再进行 `--since`/`--until`
  比较，不能按原始字符串排序。CLI 参数接受 RFC 3339 UTC；为排障兼容 v1，也接受 `unix:<seconds>`。
- `events follow` 从调用时活动文件的末尾开始；轮转后保持已打开的旧文件读到 EOF，再按文件身份检测
  并打开新的活动文件，语义等价 `tail -F`，不重复已输出行。它只跟踪新事件，不回放历史文件。

### 7.5.5 HTTP 请求日志增强

#### 7.5.5.1 请求级日志

在 `http/server.zig` 的响应完成后，记录结构化请求日志：

```zig
// 记录到服务日志（std.log）
http_log.info("{s} {s} -> {d} ({d} bytes, {d}us, client={s})", .{
    method, path, status, bytes_sent, duration_us, client_ip,
});

// 同时写入事件
events.appendWithFields(..., "http.request", message, &.{
    .{ .key = "method", .value = method },
    .{ .key = "path", .value = path },
    .{ .key = "status", .value = formatStatus(status) },
    .{ .key = "client_ip", .value = client_ip },
    .{ .key = "bytes_sent", .value = formatBytes(bytes_sent) },
    .{ .key = "duration_us", .value = formatDuration(duration_us) },
});
```

客户端 IP 只取 Zap socket 的 `remote_ip`；当前 listener 没有可信反向代理边界，绝不信任客户端可
伪造的 `X-Forwarded-For`。以后若引入反向代理，必须单独配置可信 proxy CIDR，才可解析该 header。
耗时使用单调时钟的开始/结束差值计算，再转换为微秒，不能用可能被 NTP 校正的 wall clock。

`path` 只记录已匹配的路由模板（如 `/api/v1/management/assets/import`），或经过规范化并确认位于
资产根目录内的相对文件名；不记录 query string、Authorization、Cookie、请求体和原始节点日志。
`/healthz` 可记录 debug 服务日志，但不写业务事件，避免探针淹没审计文件。

#### 7.5.5.2 不启用 Zap 内置 access log

经分析，facil.io 的 `http_write_log` 是 C 级别实现，输出格式固定且难以与 Zig 的 `std.log`
体系统一。M2.5 不启用 Zap 内置 access log，而是在 Zig 层自行实现请求日志，保证格式一致性和
结构化字段控制。

### 7.5.6 TFTP 日志补全

`tftp/server.zig` 当前完全没有日志输出。M2.5 补全以下日志点：

| 日志点 | 级别 | 内容 |
| --- | --- | --- |
| RRQ 收到 | info | 客户端 IP、规范化后的请求文件名、blksize |
| 传输完成 | info | 文件名、传输字节数、耗时 |
| 传输超时/重传 | warn | 文件名、重传次数 |
| 传输失败 | err | 文件名、错误原因 |
| 非法路径 | warn | 客户端 IP、经长度限制的请求路径摘要、拒绝原因 |

同时，TFTP 传输完成和失败写入事件：

```json
{"v":2,"ts":"...","type":"tftp.transfer.complete","message":"sent grubaa64.efi (348160 bytes)","fields":[{"key":"filename","value":"efi/grubaa64.efi"},{"key":"bytes_sent","value":"348160"},{"key":"client_ip","value":"192.168.27.10"},{"key":"duration_us","value":"125000"}]}
```

### 7.5.7 CLI 事件查询命令

新增 `nodeforge events` 命令组，提供事件查询和过滤能力：

```
nodeforge events list [--type <type>] [--node <node_id>] [--since <ts>] [--until <ts>] [--limit <n>]
nodeforge events follow [--type <type>]
nodeforge events types
```

这些命令只读 `paths.events_path` 及同目录轮转文件，不能使用 `--config` 或远程 endpoint 改写日志
位置。文件不存在时 `events list` 输出空列表并成功返回；`events follow` 输出简短错误并返回非零。
目录或文件权限不足也是明确错误，不回退为读取任意用户提供的路径。

| 命令 | 说明 |
| --- | --- |
| `events list` | 查询历史事件，支持按类型、节点、时间范围过滤 |
| `events follow` | 实时跟踪事件流（`tail -f` 语义） |
| `events types` | 列出所有已注册事件类型及说明 |

`--type` 是注册表中的精确事件名；未知名称是参数错误。`--node` 在 v2 中匹配 `node_id` field，在
v1 中只匹配已有顶层 `node` 字段，不能从 message 猜测。`--since` 和 `--until` 是包含边界；
`--limit` 取最新匹配的 N 条。解析或过滤失败的单行按事件读取规则处理，CLI 最终在 stderr 报告跳过数，
而 JSON stdout 始终只含有效 JSON 数组。

**Human 输出**（表格格式，复用 M1.5 formatter）：

```
TIME                  TYPE                    NODE       MESSAGE                         FIELDS
2026-07-11T08:30:00Z  dhcp.ack                r97n0      DISCOVER -> ACK yiaddr=...      mac=52:54:00:aa:bb:cc ip=192.168.27.10 xid=0x1234abcd
2026-07-11T08:30:05Z  tftp.transfer.complete  r97n0      sent grubaa64.efi (348160 bytes) filename=efi/grubaa64.efi bytes=348160
```

**JSON 输出**（`--output json`）：

```json
[
  {"v":2,"ts":"2026-07-11T08:30:00Z","type":"dhcp.ack","message":"...","fields":[...]}
]
```

`events follow` 的 human 模式输出每行一条事件，不使用表格（因为终端宽度和滚动场景）；JSON 模式
输出 JSONL，而非 JSON array，便于流式消费：

```
2026-07-11T08:30:00Z  dhcp.ack   mac=52:54:00:aa:bb:cc ip=192.168.27.10  DISCOVER -> ACK
2026-07-11T08:30:05Z  tftp.transfer.complete  filename=efi/grubaa64.efi  sent grubaa64.efi (348160 bytes)
```

### 7.5.8 代码任务

| 模块 | 任务 |
| --- | --- |
| `observe/log.zig` | 迁移到 `std.log.scoped`；扩展为四级日志；保留运行期级别控制 |
| `observe/log_backend.zig` | `std.options.logFn` 后端；8 KiB 有界渲染；原子阈值、stderr + 文件双 sink、轮转和降级报告 |
| `state/events.zig` | Event v2 字段校验；RFC 3339 UTC；单 writer append、尾部损坏容忍和事件轮转 |
| `state/event_types.zig` | 完整事件类型注册表（name/description/default_level），供 writer 与 CLI 共用 |
| `dhcp/server.zig` | `audit()` 改为传递结构化字段；日志增加 xid/arch 上下文 |
| `http/server.zig` | 请求日志增加 client_ip/duration/bytes；写入 http.request 事件 |
| `tftp/server.zig` | 补全 RRQ/传输/失败日志和事件 |
| `cli/events.zig` | 本地只读 `events list/follow/types`；轮转感知 follow、v1/v2 时间归一化和 human/JSON 输出 |
| `model.zig` | `LoggingConfig` 扩展 file 后端和四级 level；新增 `EventsConfig`、范围校验与显式 level 映射 |
| `paths.zig` | 新增 `service_log_path` 常量 |
| `nodeforged.zig`、`main.zig`、`root.zig` | 在每个 root module 安装 `std_options.logFn` 和 `.debug` 编译期阈值 |

### 7.5.9 事件兼容策略

- v1 事件（`v: 1`，`ts: "unix:..."`）和 v2 事件（`v: 2`，`ts: RFC 3339 UTC`，`fields: [...]`）
  在同一 `events.jsonl` 文件中共存。
- CLI `events list` 同时兼容 v1 和 v2 事件：v1 事件的 fields 列显示为空，只使用其已有顶层字段，
  不从 message 解析。
- daemon 升级到 M2.5 后只写入 v2 事件，不做历史 v1 事件的迁移。
- `events.jsonl` 轮转时不区分版本，按文件大小统一轮转。
- v1 的 message 不被重新解析为 fields；只使用其已有顶层字段和时间，避免把不稳定的人类文本误当成
  机器契约。
- v2 的未知 field 和未知事件类型在读取时保留并显示；写入端只允许注册表事件类型，防止拼写漂移。

### 7.5.10 测试与验收

| 测试项 | 方法 |
| --- | --- |
| root module 接线 | daemon、CLI 和 core test root 都编译为 `std_options.log_level = .debug` 且实际调用同一 `logFn` |
| 日志线程安全 | 多线程交错写入长短消息，验证每行完整、stderr/file 内容一致且无半行 |
| 日志级别过滤 | 验证四个阈值的包含关系，尤其是 info 排除 debug、`--debug` 恢复 debug 而无需重编译 |
| 有界渲染与脱敏 | 输入超长字符串、换行和敏感字段，验证单行最多 8 KiB、合法转义且 token/password/body 从不出现 |
| 文件轮转与降级 | 验证临界大小、单条超限、`.1`/`.N` 保留、`keep` 边界、rename/重开失败时 stderr 连续可用 |
| Event v2 字段 | 构造 DHCP ACK，验证 RFC 3339、mac/ip/xid/kind、重复/非法 key 和超限值均按契约处理 |
| 事件轮转与恢复 | 并发 writer 验证无覆盖；模拟末尾半行和历史坏行，验证有效事件仍可读且有 skipped 计数 |
| CLI events list | 生成跨轮转的混合 v1/v2 文件，验证时间归一化、过滤、最新 limit、human 表格和 JSON 数组 |
| CLI events follow | 在 follow 中触发写入与轮转，验证旧 inode 读尽后重开新文件且不丢行/不重复；JSON 输出为 JSONL |
| TFTP 日志补全 | 执行成功、重传、非法路径和失败传输，验证等级、字段和事件类型 |
| HTTP 请求日志 | 验证 socket client IP、单调耗时、bytes、路由模板；伪造 X-Forwarded-For、query/token/body 均不进入记录 |

### 7.5.11 不做的事

- **不启用 Zap/facil.io 内置日志**：C 级别 `fio_log_*` 和 `http_write_log` 格式固定、
  难以结构化，与 Zig `std.log` 体系不兼容。
- **不实现远程日志收集**：MVP 不支持 syslog/UDP 日志转发，日志仅本地文件和 stderr/journal。
- **不引入日志库**：不接入 `zlog` 等第三方库。结构化服务日志、双 sink 和轮转仅使用 Zig 标准库实现，
  避免其异步丢弃策略、额外生命周期和版本兼容性成为 daemon 基础路径的一部分。
- **不实现日志搜索索引**：事件查询基于顺序扫描 `events.jsonl`，不构建倒排索引；
  对于 MVP 规模（单网段几十台节点）足够。
- **不做 v1 历史事件迁移**：旧 `events.jsonl` 中的 v1 事件保持原样，CLI 兼容读取。

## 8. M3：HTTP 配置、资产、ISO 仓库和事件接口

### 8.1 目标

HTTP 成为 TFTP 之后的主要数据通道：

- 提供 boot config。
- 提供 answer file。
- 提供大文件下载和 Range。
- 接收事件和日志摘要。

### 8.2 代码任务

| 模块 | 任务 |
| --- | --- |
| `http/server.zig` | HTTP server 生命周期 |
| `http/routes.zig` | 路由表 |
| `http/static.zig` | 静态资产发送 |
| `http/range.zig` | Range / Content-Length / ETag |
| `http/api.zig` | JSON API handler |
| `profile/render.zig` | 模板渲染入口 |
| `http/node_events.zig` | 节点事件/日志摘要 DTO 校验、认证结果绑定和 EventType 映射；不直接操作文件 |
| `state/events.zig` | 复用 M2.5 唯一 JSONL writer，不新增第二个 append 路径 |

### 8.3 路由

| 路由 | 方法 | 输出 |
| --- | --- | --- |
| `/healthz` | GET | 健康状态 |
| `/boot/config/:node_id` | GET | boot config JSON |
| `/api/v1/nodes/:id/config` | GET | 节点配置 JSON |
| `/api/v1/nodes/:id/answer` | GET | autoinstall/kickstart |
| `/api/v1/nodes/:id/events` | POST | 受限节点阶段事件上报 |
| `/api/v1/nodes/:id/logs` | POST | 有界失败日志摘要上报 |
| `/rootfs/:name` | GET | rootfs 文件 |
| `/images/:name` | GET | ISO/image |
| `/repos/:name/*` | GET | repo 文件 |
| `/api/v1/management/runtime` | GET | 本机 CLI 使用的运行态摘要 |

### 8.4 ISO 自动仓库

`nodeforge install-source import <iso>` 执行以下流程：

1. 校验 ISO 类型、SHA256、发行版、版本和架构。
2. 解包到临时目录，提取 installer kernel/initrd，校验成功后 rename 到版本化目录。
3. 在 `/opt/nodeforge/repos/<install-source>/` 发布完整 ISO 内容。
4. Rocky/RHEL 系校验 `.treeinfo`、`repodata/repomd.xml`；Ubuntu 校验 installer media，并单独判断是否具备 apt repository 元数据。
5. 元数据完整时自动创建 `RepositoryConfig`，`base_url` 指向 `/repos/<install-source>/` 并关联 install source；不完整时只创建 install source。
6. renderer 使用已关联 repository 输出 Kickstart `url/repo` 或 Ubuntu apt 配置；缺少必要外部 mirror 时在 profile validate 阶段报错。

ISO 中通过元数据校验的仓库是默认基础源，用户可以追加 mirror/额外源。GPG 检查默认关闭，仅在 repository 明确 `gpg_check = true` 时启用。

### 8.5 boot config

diskless boot config 示例：

```json
{
  "node_id": "node-02",
  "mode": "diskless",
  "profile": "rocky-9.7-aarch64-diskless",
  "rootfs_url": "http://192.168.50.1:8080/rootfs/rocky-9.7-aarch64-<kernel-release>.squashfs",
  "rootfs_sha256": "...",
  "rootfs_mode": "squashfs_overlay",
  "overlay": {
    "tmpfs_size": "50%",
    "tmpfs_mode": "0755"
  },
  "event_url": "http://192.168.50.1:8080/api/v1/nodes/node-02/events"
}
```

### 8.6 节点事件与日志摘要接收

M3 不接受客户端提交完整 Event JSON，也不让客户端指定 `ts`、`node_id`、`source` 或任意字段。
请求 DTO 只包含已注册的 node-origin event type、有限 stage/reason、简短 message 与允许字段；HTTP
handler 根据已认证的 URL node id 和服务端时间构建 v2 Event，固定增加 `node_id` 与 `source` field。
节点请求不能伪造 `dhcp.*`、`tftp.*`、`http.request`、`service.*` 或其他 server-origin 类型。

`/logs` 仅用于失败诊断摘要：body 最大 4 KiB、摘要截断到 2048 bytes，并映射为对应的
`install.failed`、`diskless.failed` 或 `provision.step.failed` event；禁止上传完整 installer log、
shell stdout/stderr、token、cookie 或任意文件。原始日志由节点本地保存，NodeForge 只保留安全的
可查询摘要。HTTP body 超限、非法 event type、未知 field 或认证失败返回明确 4xx，且不会写事件。

写入顺序固定为：验证请求与 node 身份 -> 更新 `node_status` -> 追加 domain Event -> 返回响应。
EventWriter 失败时状态更新不回滚，响应返回 5xx 并记录服务 err，调用方可以重试；M3 的上报语义是
at-least-once，重复 domain event 可出现，但 node_status transition 必须幂等。跨请求事件去重需要持久化
event id，超出 M3，不得以猜测 message 相同来去重。同一次 POST 无论成功或失败都各自产生一条服务侧
`http.request`，但它不替代 domain Event。

### 8.7 CLI 命令

```bash
nodeforge runtime status
nodeforge events list --node node-01
nodeforge events follow --type install.failed
nodeforge node status node-01
nodeforge install render node-01
nodeforge install-source import Rocky-9.7-aarch64-dvd.iso --distro rocky --version 9.7 --arch aarch64
nodeforge repository show rocky-9.7-aarch64-iso
```

### 8.8 并发与 HTTP 实现选择

- HTTP 服务器基于 Zap/facil.io 固定提交实现。Zap 负责 HTTP 报文解析、连接生命周期和并发调度，并提供静态文件/Range 所需的库能力；M0 尚未注册静态资产或 Range 路由，M3 再将其接入。NodeForge 当前只维护业务路由、管理 API 和统一错误信封，不维护 HTTP 报文解析或连接循环。已评估的备选方案 `http.zig`（karlseguin）在 Zig 0.16 上尚未充分测试且不承诺完整 HTTP/1.1 合规，不作为依赖。
- acceptor 与固定大小 worker pool 分离；大文件使用 `pread`/send loop 流式发送，不整体读入内存。
- DHCP/TFTP 使用各自 UDP event loop；耗时 hash/文件任务提交到 worker pool，不阻塞收包。
- 配置使用不可变 snapshot + 原子替换；runtime/state 由单 writer 串行落盘，事件通过 M2.5 的唯一
  mutex 保护 writer 追加和轮转，不再引入独立队列或第二个文件后端。
- MVP 验收基线：并发 100 个 HTTP Range 下载、100 个 TFTP session 和每秒 200 个 DHCP 报文时无崩溃、无状态串扰；具体吞吐在目标 ARM VM 和 x86_64 机器记录，不先承诺生产数字。

### 8.9 测试

- `/healthz` 返回 OK。
- Range 下载返回 206。
- `If-Range`、无效 Range、连接中断后续传测试。
- answer 渲染返回文本。
- POST 合法节点 event DTO 后更新 runtime 并写入受限 Event v2；伪造 server type、node_id、source、
  超长 body/summary 或未知 field 都返回 4xx 且不写文件。
- POST 日志摘要只保留有界失败摘要，不能把完整 installer/initrd log 写入 JSONL 或服务日志。
- runtime summary 与事件同步；EventWriter 写入失败时状态不回滚、请求返回 5xx 且可幂等重试。

### 8.10 阶段验收

- installer/initrd 能通过 HTTP 拿到配置。
- 合法节点事件能按 Event v2 写入 `events.jsonl`，非法节点 body 不会污染审计文件。
- 大文件下载支持 `Content-Length` 和 Range。
- ISO 导入后无需手工建基础 repo 即可通过 HTTP 安装。

## 9. M4：PXE 无人值守自动安装与基础后处理

### 9.1 目标

首先在当前 Rocky Linux 9.7 aarch64 开发环境跑通 Kickstart，再跑通 Ubuntu Server 22.04 LTS autoinstall；x86_64 是首个生产验收架构，两种架构从初始模型、资产命名和 fixture 层同时支持。

### 9.2 代码任务

| 模块 | 任务 |
| --- | --- |
| `profile/install.zig` | InstallConfig 校验和归一化 |
| `profile/adapter/ubuntu.zig` | autoinstall user-data/meta-data 渲染 |
| `profile/adapter/kickstart.zig` | kickstart ks.cfg 渲染 |
| `profile/render.zig` | 通用模板变量 |
| `boot/cmdline.zig` | install cmdline 渲染 |
| `state/node_status.zig` | install 阶段状态 |
| `provision/runner.zig` | 执行 repository、standard-packages、managed-file 三种基础步骤 |

### 9.3 Ubuntu autoinstall 渲染

输入：

- `InstallConfig.storage`
- `InstallConfig.bootloader`
- packages/users/files/hooks
- node hostname/IP/profile vars
- `users.password` 明文密码

输出：

- `user-data`
- `meta-data`

必须映射：

- storage -> `storage.config`
- packages -> `packages`
- user/ssh -> `identity` / `ssh`
- hooks -> `late-commands`
- event upload -> late command 或 firstboot script
- provisioning bundle -> `late-commands` 调用统一 runner 的 `install_post` 阶段

如果提供 `users.password = "asdf1234"`，Ubuntu adapter 在内存中生成安装器接受的 password hash；配置文件和 NodeForge 数据模型仍直接保存明文。

实现策略：

- 使用 Ubuntu Installer/Subiquity 的 `autoinstall`，不实现 preseed。
- NodeForge HTTP 输出 cloud-init NoCloud-Net 数据源：`user-data` 和 `meta-data`。
- PXE cmdline 追加 `autoinstall ds=nocloud-net;s={{answer_base_url}}/`。
- `user-data` 顶层包含 `autoinstall.version = 1`。
- 版本能力表和首个 fixture 先覆盖 22.04 LTS；后续 LTS 在 M6 按实际发布版本增加。

版本支持：

| 层级 | 版本 | 实现要求 |
| --- | --- | --- |
| MVP 必测 | Ubuntu Server 22.04 LTS aarch64、x86_64 | aarch64 开发 smoke test 与 x86_64 生产 smoke test 必须通过 |
| 后续目标 | Ubuntu Server 22.04 之后的 LTS | 按版本增加 schema、installer 参数和 fixture，不预先假定字段完全兼容 |
| 非目标 | Ubuntu Server 20.04 LTS 及更早版本 | 不实现 d-i/preseed，也不做存量兼容 |

### 9.4 Kickstart 渲染

输出 `ks.cfg`，至少包含：

- `url` 或 `repo`
- `clearpart`
- `part` / `logvol`
- bootloader
- network
- user/sshkey
- `%packages`
- `%post`

`%post` 只负责挂载执行上下文并调用统一 provisioning runner，不在 Kickstart renderer 中重复实现软件包、文件和脚本逻辑。

MVP 首先要求 Rocky Linux 9.7 aarch64 完整安装跑通；随后验证 Rocky Linux 9.x x86_64。RHEL、Alma、Fedora 复用 Rocky 优先模型，差异放入 M6。

Kickstart 分区至少支持 `ext4`、`xfs`、`swap`、EFI System Partition 和 BIOS boot partition；默认 root 文件系统可由 profile 选择，Rocky 默认可用 xfs，但不得限制为 xfs。

### 9.5 启动盘配置

实现字段：

```json
{
  "storage": {
    "wipe": true,
    "boot_disk": "/dev/sda",
    "install_disks": ["/dev/sda"],
    "boot_mode": "uefi",
    "partition_table": "gpt",
    "partitions": []
  },
  "bootloader": {
    "install": true,
    "target": "storage.boot_disk",
    "set_firmware_boot_order": false
  }
}
```

校验：

- UEFI 必须有 `/boot/efi` ESP。
- BIOS + GPT 必须有 BIOS boot 分区。
- `bootloader.install = true` 时 target 必须可解析。
- `set_firmware_boot_order = true` 在 MVP 返回“不支持”或警告。已在 Rocky 9.7 aarch64 VMware EFI 虚拟机验证 `efibootmgr` 修改 BootOrder 的持久性和可靠性，但不同厂商固件存在兼容性差异，MVP 保持默认 `false` 避免阻塞安装。

### 9.6 安装阶段状态

阶段：

```text
pxe_seen
bootfile_sent
installer_started
install_config_fetched
install_started
install_partitioning
install_packages
install_bootloader
install_post
install_rebooting
installed
failed
```

每次阶段上报都映射为 M2.5 注册表中的 `install.*` event，并带 `source=installer`、`node_id`、
`stage`。`failed` 还必须带稳定 `reason`（例如 M6 错误分类）和不超过 2048 bytes 的安全摘要；
`node_status.last_event_at` 与 `last_error` 从已验证的上报更新，不能从服务日志文本反推。`install logs`
命令展示这些事件摘要，不读取或声称保存 installer 的完整原始日志。

### 9.7 CLI 命令

```bash
nodeforge install render node-01
nodeforge install status node-01
nodeforge install logs node-01
nodeforge install retry node-01
```

### 9.8 测试

- Ubuntu autoinstall 渲染 fixture。
- Kickstart 渲染 fixture。
- storage 校验 fixture。
- 未显式认领的节点禁止使用 install profile。
- installer hook 的合法/非法 Event v2 DTO、阶段到 node_status 映射和失败摘要脱敏。
- QEMU UEFI PXE autoinstall smoke test。

### 9.9 阶段验收

- Rocky Linux 9.7 aarch64 和 Ubuntu Server 22.04 LTS 能从 PXE 自动安装到本地磁盘。
- 安装目标盘、ESP、root、swap、bootloader 配置生效。
- 安装事件能更新 `node status`。
- `install render` 可预览 answer file。
- `bundle plan --node` 与安装器实际执行的 `install_post` 顺序一致。

## 10. M5：内存无盘启动与基础后处理

### 10.1 目标

实现 NodeForge 小 initrd + HTTP rootfs 的无盘启动闭环。

### 10.2 代码任务

| 模块 | 任务 |
| --- | --- |
| `profile/diskless.zig` | DisklessConfig 校验 |
| `assets/bundle.zig` | boot bundle manifest 校验 |
| `rootfs/validate.zig` | rootfs 发布物校验 |
| `initrd/validate.zig` | 小 initrd 能力校验 |
| `http/routes.zig` | boot config/rootfs 路由完善 |
| `state/node_status.zig` | diskless 阶段状态 |
| `provision/runner.zig` | 在 rootfs 工作目录或 overlay upper 中执行基础步骤 |

小 initrd 明确使用目标发行版的 `dracut` 定制构建，不手工拼 cpio，也不把 Zig 静态二进制作为 MVP 前置条件。`initrd/dracut/95nodeforge/` 提供标准 dracut module：

- `module-setup.sh` 声明依赖并安装 hook、网络工具、HTTP 下载工具、SHA256、overlay/squashfs 所需模块。
- `nodeforge-init.sh` 只执行 cmdline 解析、IPv4 联网、boot config 获取、rootfs 续传/校验、overlay 挂载和 `switch_root`。
- 构建必须在与 rootfs 同发行版、同版本、同架构、同 `kernel_release` 的环境中运行；Rocky 9.7 aarch64 是第一条验证链路。
- `nodeforge initrd build` 是 dracut 的稳定封装，记录 dracut 版本、命令、module 清单和输出 SHA256。

### 10.3 boot bundle manifest

必须记录：

- name
- distro
- version
- arch
- kernel_release
- kernel asset/path/sha256
- NodeForge 小 initrd asset/path/sha256
- rootfs asset/path/sha256/size
- repository refs
- build time
- build spec

### 10.4 小 initrd 行为

流程：

```text
parse /proc/cmdline
  -> read nodeforge.config_url
  -> dhcp network already available or bring up network
  -> GET boot config
  -> POST diskless.initrd_started
  -> inspect partial rootfs and download with HTTP Range
  -> verify sha256
  -> mount squashfs lower
  -> mount tmpfs upper with configured size
  -> mount overlay merged
  -> write /run/nodeforge/boot.json
  -> switch_root merged /sbin/init
```

rootfs 下载支持断点续传：

- 临时文件使用 `<sha256>.part`，同时保存期望 URL、size、ETag 和已下载字节数。
- 同一次 initrd 启动中发生网络中断并恢复后，以 `Range: bytes=<offset>-` 和 `If-Range: <etag>` 继续；服务返回 `206` 才追加。纯内存无盘节点重启后 partial 会丢失，因此不承诺跨重启续传。
- 服务返回 `200`、ETag 改变、长度不符或局部文件超过目标大小时，从零覆盖下载。
- 完成后必须校验完整 SHA256，再原子改名；hash 不匹配删除或隔离 partial，绝不挂载。
- tmpfs 容量校验必须同时考虑 rootfs partial 文件和 overlay 上层，容量不足时在下载前明确失败。

小 initrd 只上报注册的 `diskless.*` 状态：启动、rootfs 下载开始、校验完成、挂载完成、切根开始、
运行成功或失败。每次请求由 M3 的 node event DTO 限制为 stage、reason、rootfs 名称/校验摘要等小字段；
失败摘要不得包含下载 URL query、Authorization、完整 dracut journal 或 debug shell 输出。`node_status` 与
event 的更新顺序遵循 §8.6，断网时 initrd 只保留本地失败信息，不因为事件上报失败而中断已完成的切根。

### 10.5 overlay 规则

- `overlay.tmpfs_size` 必须传给 tmpfs `size=`。
- `/var/log`、`/tmp` 等高写入路径先作为配置位，不强制 MVP 单独挂载。
- 持久化 overlay 不进入 MVP。
- rootfs 公共修改使用 `rootfs_build`；节点差异使用 `diskless_boot` 写入 overlay upper。两者复用 M4 的 provisioning runner。

### 10.6 CLI 命令

```bash
nodeforge rootfs package rocky-9.7-aarch64 --format squashfs --version 20260706
nodeforge rootfs validate rocky-9.7-aarch64-<kernel-release>-diskless-20260706.squashfs
nodeforge initrd validate diskless/rocky/9.7/aarch64/<kernel-release>/initrd-nodeforge.img
nodeforge boot-bundle publish rocky-9.7-aarch64-<kernel-release>-diskless-20260706 --kernel rocky-9.7-aarch64-kernel --initrd rocky-9.7-aarch64-nodeforge-initrd --rootfs rocky-9.7-aarch64-rootfs-20260706 --repo rocky-9.7-aarch64-dvd
nodeforge diskless overlay update rocky-9.7-aarch64-diskless --tmpfs-size 50%
nodeforge diskless status node-02
```

### 10.7 测试

- boot bundle 一致性校验。
- rootfs 缺少 `/sbin/init` 报错。
- rootfs `/lib/modules` 与 kernel_release 不匹配报错。
- overlay tmpfs size 解析。
- initrd 上报 diskless 事件、断网时事件失败不阻断切根、失败摘要长度限制。
- QEMU UEFI diskless smoke test。

### 10.8 阶段验收

- 节点能 PXE 进入小 initrd。
- 小 initrd 能拉取 boot config。
- rootfs 下载和 SHA256 校验通过。
- `squashfs_overlay` 挂载成功并 `switch_root`。
- `nodeforge node status` 显示 `diskless_running`。

## 11. M6：支持矩阵增强

### 11.1 目标

完善 MVP 周边兼容性和诊断能力。

### 11.2 任务

- Rocky Linux 9.x 优先的 RHEL 系 kickstart 版本能力表。
- x86_64 生产验证记录和 aarch64 真机/QEMU PXE 验证记录。
- BIOS x86 + PXELINUX 链路。
- 安装错误分类。
- ISO/repo/rootfs 资产更完整校验。
- Proxy DHCP spike。
- Secure Boot 风险评估。

### 11.3 BIOS PXELINUX

PXELINUX 只用于 BIOS x86。DHCP 返回 `pxelinux.0` 后，PXELINUX 从 TFTP 根目录下的 `pxelinux.cfg/` 查找配置。NodeForge 不使用 PXELINUX 私有 DHCP option 指定配置文件，遵循默认查找规则：

1. 先按硬件类型和 MAC 查找，例如以太网 `52:54:00:12:34:01` 对应 `01-52-54-00-12-34-01`。
2. 再按客户端 IPv4 的大写十六进制形式查找，例如 `192.168.50.101 -> C0A83265`。
3. 找不到时逐位缩短为 `C0A8326`、`C0A832` 等，最后查找小写 `pxelinux.cfg/default`。

生成策略：

- `boot/pxelinux.zig` 是唯一 renderer，不在 DHCP/TFTP handler 中拼配置文本。
- 已绑定 BIOS 节点以 MAC 为主要身份，生成 `pxelinux.cfg/01-<mac>`；具有保留 IP 时同时生成完整 8 位十六进制文件作为兼容入口，两者内容相同。
- 节点配置由 `boot.resolver` 展开 node + profile，直接指向对应 installer kernel/initrd 或 diskless kernel/initrd。
- `pxelinux.cfg/default` 只处理未匹配节点，严格服从 unknown policy；默认 `wait` 时不包含自动安装、擦盘或自动启动条目。
- 为避免缩短 IP 前缀意外匹配其他节点，NodeForge 不生成前缀配置文件，只生成 MAC、完整 8 位 IP 和 `default`。
- 所有路径相对 `pxelinux.0` 所在 TFTP root，生成前检查路径长度、资产存在性和目录穿越。
- 配置写入临时文件，校验后 rename；node/profile/policy 变更时重新生成受影响文件。

已绑定 install 节点示例：

```text
DEFAULT nodeforge
PROMPT 0
TIMEOUT 30
ONTIMEOUT nodeforge

LABEL nodeforge
  KERNEL install/rocky/9.7/x86_64/vmlinuz
  APPEND initrd=install/rocky/9.7/x86_64/initrd.img inst.ks=http://192.168.50.1:8080/api/v1/nodes/node-01/answer inst.repo=http://192.168.50.1:8080/repos/rocky-9.7-x86_64-dvd/
```

默认 `wait` 示例：

```text
PROMPT 1
TIMEOUT 0
DISPLAY pxelinux.cfg/wait.txt
```

如果管理员显式配置 safe discovery/diskless，`default` 可以增加相应条目；仍不得包含 install profile。

实现和测试：

- 新增 `boot/pxelinux.zig`、MAC 文件名和 IP 十六进制文件名转换测试。
- fixture 覆盖 BIOS arch option、MAC 命中、完整 IP 命中、逐级 fallback 和 `default`。
- 使用标准 TFTP client 验证配置可取，再用 QEMU BIOS PXE 验证 kernel/initrd 与 cmdline。
- `nodeforge boot render <node> --format pxelinux` 可预览节点配置；`nodeforge boot default render --format pxelinux` 可预览安全兜底配置。

### 11.4 错误分类

错误类型：

- `dhcp.no_available_lease`
- `tftp.asset_not_found`
- `http.asset_hash_mismatch`
- `install.answer_render_failed`
- `install.storage_invalid`
- `install.bootloader_failed`
- `diskless.rootfs_hash_mismatch`
- `diskless.switch_root_failed`

这些 error code 既是 CLI/状态显示的稳定分类，也是 `install.failed`、`diskless.failed` 等 v2 event 的
`reason` field 值；不要把自由文本错误或 Zig error tag 当作跨版本事件字段。

## 12. M7：补充包和后处理增强

### 12.1 目标

M4/M5 已交付 repository、standard-packages、managed-file 和统一 runner。本阶段补齐 archive、script、firstboot、CLI plan/status 和三条链路的完整回归。这里的“配置可视化”是指 CLI 按阶段、步骤和执行结果清晰组织输出，不引入 Web UI 或通用低代码配置系统。

### 12.2 增强范围

本阶段不新增第二套模型，继续使用 3.5：

- 启用 archive 和 script action。
- 增加 firstboot 执行入口。
- 补齐 bundle `show/plan`、运行状态和错误摘要。
- 对 Kickstart、autoinstall、rootfs build 和 diskless overlay 做同一 bundle 的回归。

### 12.3 标准化步骤契约

所有步骤统一接收执行上下文：

```text
node_id, profile, distro, distro_version, arch, phase,
target_root, workspace, repository_base_url, event_url
```

统一返回：

```json
{
  "changed": true,
  "status": "succeeded",
  "summary": "chrony installed",
  "outputs": {},
  "warnings": []
}
```

规则：

- 每种 action 使用 Zig 明确结构体和配置校验，不使用 JSON Schema 动态生成字段。
- 所有步骤支持 `validate`；`plan` 预览将安装的包、修改的文件和执行的脚本，但不产生副作用。
- 步骤执行必须幂等；重复执行应返回 `changed = false`。无法保证幂等的 script 必须明确标记并禁止用于自动重试。
- 输出、事件和错误使用统一结构，不允许脚本自行定义不可解析的状态格式。
- `script` 是最后的逃生口，不作为常规配置步骤；必须提供 summary 和影响范围，供命令输出展示。

runner 在调用每个 step 前后分别产生 `provision.step.started` 与 `succeeded`/`warned`/`failed`，fields
固定包含 `source=runner`、`node_id`（适用时）、`phase`、`step`、`run_id`、action 和稳定 reason。脚本
stdout/stderr 仅保留最后 2048 bytes 的转义摘要；秘密环境变量、命令行中的 token 和未声明输出均不得进入
服务日志、Event.message 或 Event.fields。

### 12.4 包类型和交付规则

只支持两类补充包：

- 标准包：RPM/DEB 不作为孤立文件逐个安装。它们必须进入额外 yum/dnf/apt repository，通过标准包名和包管理器安装；repository 由 HTTP `/repos/` 提供。
- 非标准包：只支持 `tar.bz2`，manifest 必须包含 SHA256、解压目录和可选 `install.sh`。不在 MVP 增加 wheel、容器镜像或任意压缩格式的专用模型。

`install.sh` 约定：以 bundle 解压目录为工作目录，参数固定为 `install --root <target-root>`，退出码 0 成功；必须可重复执行，禁止隐式下载未声明内容。

### 12.5 统一后处理阶段

阶段固定为：

```text
rootfs_build
install_post
firstboot
diskless_boot
```

执行顺序固定：

1. 挂载/确认目标 root。
2. 配置基础 ISO repository 和额外 repository。
3. 使用 yum/dnf/apt 安装 `standard_packages`。
4. 下载并校验 `tar.bz2`，解压并执行其安装脚本。
5. 原子写入 `files`，用于 `/etc/hosts`、chrony/systemd-timesyncd、resolver 和业务配置。
6. 按声明顺序执行自定义 scripts/patch。
7. 写入 `/opt/nodeforge/provisioned/<bundle>-<version>.json` 并上报结果。

同一个 bundle 可用于：

- Kickstart `%post` 或 Ubuntu `late-commands`：在目标 root 内执行 `install_post`。
- rootfs build：打包 squashfs 前执行 `rootfs_build`。
- diskless：通用内容尽量在 rootfs build 完成；节点专属配置在 overlay 上执行 `diskless_boot`，不修改只读 lower rootfs。
- firstboot：需要 systemd、网络或目标硬件后才能完成的操作。

### 12.6 CLI 配置展示与预览

“可视化”完全通过命令输出实现：

- `bundle list` 使用表格展示名称、版本、发行版、架构、步骤数和发布时间。
- `bundle show` 先显示概要，再按 phase 分组，按数组顺序列出 step、action、required、enabled 和关键参数。
- `bundle plan --node` 展示目标节点、安装方式、目标 root、最终执行顺序、软件包、文件目标、archive 和脚本摘要，并突出警告或不兼容项。
- `provision status` 按 phase 和 step 展示 `PENDING/RUNNING/OK/WARN/FAILED/SKIPPED`、是否变更、耗时及摘要。
- 默认输出面向人阅读；`--output json` 输出相同事实的结构化形式，不为展示另建一套数据模型。

示例：

```text
Bundle  base-site@1    Rocky 9.7 aarch64    VALID

PHASE         #  STEP              ACTION             REQUIRED  SUMMARY
install_post  1  site-repository   repository         yes       site-extra
install_post  2  base-packages     standard-packages  yes       chrony, vim
install_post  3  hosts             managed-file       yes       -> /etc/hosts
firstboot     1  vendor-agent      archive            yes       /opt/vendor-agent
firstboot     2  site-patch        script             no        patch site config
```

Kickstart、autoinstall 和 diskless 对同一 bundle 使用相同的 `show/plan/status` 格式，只在概要中标明实际执行入口。

### 12.7 安全与幂等

- 每个 bundle/version/phase 记录执行状态和日志；同版本默认不重复执行，可用显式 `--force` 重跑。
- script 使用固定环境变量、工作目录、超时和输出上限；required script 失败终止该阶段，optional script 只告警。
- 文件更新采用临时文件 + rename，原文件可按 bundle 策略备份；禁止未声明的整目录覆盖。
- 自动安装中的后处理继承 node + install profile 显式绑定；未知节点的 safe diskless 禁止执行 archive install script 和自定义 script。
- bundle 变更生成新版本，不原地修改已发布内容；节点状态记录实际使用版本。

### 12.8 CLI 与验收

```bash
nodeforge provision bundle list
nodeforge provision bundle show base-site
nodeforge provision bundle create base-site --distro rocky --distro-version 9.7 --arch aarch64
nodeforge provision step add base-site --name site-repository --phase install_post --action repository --repository site-extra
nodeforge provision step add base-site --name base-packages --phase install_post --action standard-packages --package chrony
nodeforge provision step add base-site --name vendor-agent --phase firstboot --action archive --asset vendor-agent.tar.bz2 --extract-to /opt/vendor-agent
nodeforge provision step add base-site --name hosts --phase install_post --action managed-file --source hosts --destination /etc/hosts
nodeforge provision step add base-site --name site-patch --phase install_post --action script --asset patch.sh --required
nodeforge provision bundle validate base-site
nodeforge provision bundle publish base-site --version 1
nodeforge provision bundle plan base-site --node node-01
nodeforge provision run show <run-id>
nodeforge provision status node-01
```

CLI 的 `bundle list/show/plan` 和 `status` 默认使用分组表格，`--output json` 返回同一模型。

验收必须覆盖强类型步骤校验、确定性顺序、清晰的分组输出、plan 无副作用、RPM/DEB 额外源安装、tar.bz2 安装、hosts/时间同步配置更新、自定义脚本成功与回滚提示、每个 step 的注册 Event v2 与 stdout/stderr 有界脱敏摘要，以及 kickstart、autoinstall、diskless overlay 三条链路。

## 13. 测试矩阵

| 层级 | 内容 |
| --- | --- |
| 单元测试 | packet encode/decode、配置校验、模板渲染、路径 normalize、size expr 解析 |
| fixture 测试 | DHCP 报文、TFTP 请求、answer 渲染、boot bundle manifest |
| 集成测试 | DHCP client、TFTP client、HTTP client |
| QEMU 测试 | UEFI PXE、Ubuntu autoinstall、diskless squashfs overlay |
| 可观测性契约 | root module logFn 接线、M0 生命周期关闭、日志/事件轮转、v1/v2 reader、节点 DTO、脱敏和事件注册表 |
| 回归测试 | 关键事件、错误分类、CLI 输出 |

测试目录：

```text
tests/
  fixtures/
    dhcp/
    tftp/
    profiles/
    assets/
  integration/
  qemu/
```

## 14. 配置和事件兼容策略

### 14.1 配置版本

配置文件包含：

```json
{
  "schema_version": 1
}
```

MVP 只支持当前版本。后续升级时增加 migration。

### 14.2 事件版本

事件增加 `v` 字段：

```json
{"v":1,"ts":"unix:1783332000","node":"node-01","type":"dhcp.discover"}
```

M2.5 引入 Event v2 格式，增加 `fields` 结构化字段和 RFC 3339 UTC 时间戳：

```json
{"v":2,"ts":"2026-07-11T08:30:00Z","type":"dhcp.ack","message":"DISCOVER -> ACK yiaddr=192.168.27.10","fields":[{"key":"mac","value":"52:54:00:aa:bb:cc"},{"key":"ip","value":"192.168.27.10"}]}
```

v1 和 v2 事件在同一 `events.jsonl` 中共存，CLI 兼容读取。详见 §7.5。

### 14.3 兼容原则

- 新增字段必须有默认值。
- 删除字段必须经过 migration。
- v1 daemon 生成的 `ts` 固定使用 `unix:<UTC seconds>`；v2 事件使用 ISO 8601 UTC（如
  `2026-07-11T08:30:00Z`）。两种格式在同一文件中共存，CLI 必须同时兼容。
- CLI `--output json` 字段保持稳定。
- 人类可读输出可优化，但不能丢失关键状态。

## 15. 开发顺序和里程碑

建议实际开发顺序：

1. 搭建 repo、build.zig、基础 test harness。
2. 实现 config model/load/validate/store。
3. 固定接入 `zli v5.1.2`，实现单 HTTP listener、management route、本机 CLI 客户端、声明式命令树、formatter、端口/权限 preflight，并以自动帮助和 CLI contract tests 防止语法/文档漂移。
4. 实现 runtime state 和 events writer。
5. 实现 TFTP packet/path/session/transfer/server 和 GRUB config，用标准 TFTP client 验证，完成 M1。
6. 实现 DHCPv4 packet/options/lease/policy/server、boot resolver 和 vendor fixture，与 TFTP 联调后完成 M2。
6.5. 先完成 M0 生命周期 coordinator、配置/路径/root module 日志接线，再将 `observe/log.zig` 迁移到
    `std.log.scoped`，迁移 M1 TFTP 与 M2 DHCP 的 v1 事件，建立 Event v2 注册表、轮转 reader 和 CLI
    查询；最后补全 HTTP access 日志，完成 M2.5。
7. 实现 HTTP static/Range/API、ISO 导入和自动 repository，完成 M3。
8. 实现 provisioning bundle、基础 runner 和 `show/plan/status` 输出。
9. 实现 Rocky kickstart adapter，跑通 Rocky Linux 9.7 aarch64 安装与 `install_post`。
10. 实现 Ubuntu adapter，跑通 Ubuntu Server 22.04 LTS 安装与 `install_post`，完成 M4。
11. 实现 dracut module、boot bundle/rootfs/initrd 校验和断点续传。
12. 跑通 diskless squashfs overlay 与 `rootfs_build`/`diskless_boot`，完成 M5，再实施 M6/M7 增强。

## 16. MVP 最终交付清单

二进制：

- `nodeforged`
- `nodeforge`

配置：

- `/opt/nodeforge/config/config.json`

管理目录：

- `/opt/nodeforge/catalog/catalog.json`

运行态：

- `/opt/nodeforge/state/runtime.json`
- `/opt/nodeforge/logs/events.jsonl`

资产目录：

- `/opt/nodeforge/tftp`
- `/opt/nodeforge/assets`
- `/opt/nodeforge/repos`

这些路径由代码中的统一默认路径模块派生；文档、示例配置和 systemd unit 必须与该定义保持一致。M0 默认安装根是 `/opt/nodeforge`，正常服务启动不再显式传 `--config`/`--catalog`，只在测试或临时排障时覆盖。

必须可演示：

- 未知 UEFI x86_64/aarch64 节点 DHCP wait/discovery 决策。
- CLI 显式开启和关闭未知节点 safe/ephemeral diskless 策略。
- profile 或 boot bundle show 能展开 distro、repository、install source、kernel、initrd、rootfs 的关系。
- 已登记节点 PXE 启动。
- Rocky Linux 9.7 aarch64 kickstart 到本地启动盘。
- Ubuntu Server 22.04 LTS autoinstall 到本地启动盘。
- macOS 宿主机 + Rocky Linux 9.7 ARM VM 可作为开发验证环境。
- diskless `squashfs_overlay` 启动。
- `nodeforge node status` 展示安装/无盘阶段。
- `nodeforge events list/follow/types` 展示历史、实时事件流和注册表。
- `nodeforge config validate` 校验配置。
- `nodeforge check` 验证服务可用性。
- `nodeforge provision bundle plan` 和 `provision status` 展示后处理计划与结果。

## 17. 风险和前置 spike

| 风险 | 建议 spike |
| --- | --- |
| Zig HTTP server 大文件 Range 实现细节 | M3 前做 1 个静态文件 Range demo |
| TFTP option/GRUB 行为差异 | M1 使用标准 client 和 QEMU 拉取 GRUB 配置/kernel/initrd |
| DHCP option 兼容性 | M2 前收集 UEFI x86_64/aarch64 DHCP fixtures |
| Ubuntu autoinstall schema 差异 | M4 固定 Ubuntu Server 22.04 LTS 为 MVP 必测；后续 LTS 逐版本增加 fixture |
| Rocky/aarch64 开发验证 | 当前开发宿主机是 macOS，验证环境为 Rocky Linux 9.7 ARM VM；生产初期仍优先 x86_64 | M4 先完成 aarch64 smoke，M6 补充 x86_64 生产记录 |
| dracut module 差异 | M5 前在 Rocky 9.7 aarch64 完成 `95nodeforge` build/boot spike |
| rootfs kernel module 匹配 | M5 前做 boot bundle validate prototype |
| 固件启动顺序 | 明确 MVP 不保证修改 BootOrder，避免阻塞自动安装 |

## 18. 开发期间文档同步要求

每个阶段完成时更新：

- `DESIGN.md`：仅当范围或关键决策变化时更新。
- `DETAILED_DESIGN.md`：阶段任务、接口、字段变化时更新。
- 示例配置：字段变化必须同步。
- 测试 fixture：协议或模板变化必须同步。

不允许出现：

- CLI 命令和文档示例不一致。
- 配置字段在 profile 示例、校验逻辑、renderer 中含义不同。
- 安装和无盘 initrd 概念混用。
- DHCP/TFTP 端口变成配置项。
- diskless cmdline 重新塞回复杂 rootfs 参数。
