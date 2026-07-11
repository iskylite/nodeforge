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
- `server.bind_interface` 可选，用于表达 HTTP/DHCP/TFTP 共同归属的服务网卡。M0 只校验字段格式；M1/M2 接入 TFTP/DHCP 后必须校验该网卡存在，并拥有或可到达 `server.server_ip` 所在网段。
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
- 静态 config/catalog 校验检查 `server.server_ip` 为 IPv4、`server.bind_interface`（如填写）非空、`http.port` 非零；M0 不校验网卡是否存在。
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

- 默认日志后端使用 stderr；systemd 管理时进入 journal，不默认写 `/opt/nodeforge/logs/nodeforged.log`。
- 日常 `info` 日志包含成功监听地址、每个 HTTP 请求的 method/path/status，以及配置、校验或预检失败的错误摘要。
- `config.json` 的 `logging.level` 只接受 `info`（默认）和 `debug`。`nodeforged -d/--debug` 仅覆盖本次进程启动，优先于配置；它不写回配置文件。M0 当前的 debug 请求日志为 method/path；连接建立/关闭、DHCP/TFTP 报文摘要和更细协议诊断随对应服务阶段补齐，ReleaseSafe 也可使用。
- `nodeforge` 的每个 M0 叶子命令支持 `-d/--debug`。默认只输出一行 `error: <类别>: <简短原因>: <路径>`；debug 模式在下一行追加内部错误标签，便于定位但不泄漏请求体、token 或密码。
- M1+ 节点事件、安装阶段、无盘阶段等业务事件进入 `events.jsonl`，不与服务进程日志混为一个文件；M0 仅提供其基础类型和追加工具。

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

### 7.1 目标

在 PXE 管理网段内提供 authoritative DHCP：

- 未知节点获得临时 lease，并默认等待管理员认领。
- 已登记节点获得静态 IP 或稳定 lease。
- DHCP 返回 `next-server` 和 bootfile。
- 租约和事件进入运行态。

### 6.2 代码任务

| 模块 | 任务 |
| --- | --- |
| `dhcp/packet.zig` | BOOTP/DHCP 报文和 option 解析/编码 |
| `dhcp/server.zig` | UDP 67 loop、lease 分配、续租、释放、过期和错误处理 |
| `boot/resolver.zig` | 节点身份到 node/profile/bootfile 的唯一决策入口 |
| `state/runtime.zig` | 运行态 lease 写入 |

### 6.3 DHCP 行为

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
- **`giaddr` 处理（RFC 2131 标准行为）**：当收到的 DHCP 报文 `giaddr` 非零时，表示报文经由外部 relay agent（路由器 IP Helper 或 `dhcrelay`）转发。服务器基于 `giaddr` 或 option 82 中的 RFC 3527 Link Selection 子选项定位目标 subnet，而非使用接收接口的 subnet。回复报文按 RFC 2131 Section 4.1 发送到 `giaddr:67`（relay agent 的 UDP 67 端口），而非广播或直接发给客户端。这是任何 RFC 2131 合规 DHCP 服务器的基本行为，不是独立功能特性。NodeForge 自身不实现 relay agent。参考 ISC DHCP `locate_network()`（`server/dhcp.c`）和 `bootp()`（`server/bootp.c`）的实现。
- **服务器端地址冲突检测（Ping Probe）**：在发送 DHCPOFFER 前，对候选 IP 发送 ICMP Echo Request。在配置的超时内（默认 500ms）未收到 Echo Reply 才正式分配；收到回复则调用 `abandon_lease()` 标记该 IP 为 abandoned 状态（保持 `abandon_lease_time`，默认 1 小时），并尝试分配下一个候选 IP。参考 ISC DHCP `do_ping_check()`/`lease_pinged()`/`abandon_lease()` 实现。
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

### 6.4 DHCP 决策

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
  -> 写 lease/state/event
  -> 返回 OFFER/ACK
```

### 6.5 CLI 命令

```bash
nodeforge dhcp show
nodeforge dhcp network update --mode authoritative --subnet 192.168.50.0/24 --router 192.168.50.1
nodeforge dhcp pool update --range 192.168.50.100-192.168.50.200 --lease 30m
nodeforge dhcp discovery enable --action wait --profile discovery-pxe
nodeforge dhcp discovery update --action diskless --profile rocky-9.7-aarch64-diskless --allow-unknown-diskless
nodeforge dhcp discovery update --action wait --disallow-unknown-diskless
nodeforge runtime leases list
nodeforge runtime unknown list
nodeforge node list
nodeforge node add node-01 --identity mac:52:54:00:12:34:01 --ip 192.168.50.101 --profile rocky-9.7-aarch64-install
nodeforge node update node-01 --tag rack:r1 --tag gpu --var cluster_id=lab-a --override network.mode=static --override network.address=192.168.50.101 --override network.prefix_len=24 --override diskless.overlay.tmpfs_size=50%
nodeforge node oob update node-01 --ipmi-address 192.168.10.51 --ipmi-netmask 255.255.255.0 --ipmi-gateway 192.168.10.1 --ipmi-username admin --ipmi-password 111111
```

### 6.6 测试

单元测试：

- DHCP packet decode/encode。
- option 60/82/93/97 解析。
- `giaddr` 非零时的 subnet 定位和回复路由。
- 租约池分配、续租、释放、DECLINE。
- 静态 IP 冲突检测。
- 服务器端 ICMP Ping Probe 冲突检测和 lease abandon 流程。

集成测试：

- 用 fixture 验证 UEFI x86_64/aarch64 DISCOVER。
- 使用虚拟网络或测试 UDP client 完成 DISCOVER/REQUEST。
- 未知节点身份默认进入等待认领；显式配置后可进入非破坏性 discovery 或 safe/ephemeral diskless。

### 6.7 阶段验收

- 未知节点能获得临时 IP。
- 未知节点默认不执行安装或无盘启动。
- 已登记节点能获得指定 IP。
- DHCP 按 option 93 返回启动文件：UEFI x86_64 使用 `grubx64.efi`，UEFI aarch64 使用 `grubaa64.efi`。
- `events.jsonl` 出现 `dhcp.discover`、`dhcp.offer`、`dhcp.ack`。

## 8. M3：HTTP 配置、资产、ISO 仓库和事件接口

### 8.1 目标

HTTP 成为 TFTP 之后的主要数据通道：

- 提供 boot config。
- 提供 answer file。
- 提供大文件下载和 Range。
- 接收事件和日志摘要。

### 7.2 代码任务

| 模块 | 任务 |
| --- | --- |
| `http/server.zig` | HTTP server 生命周期 |
| `http/routes.zig` | 路由表 |
| `http/static.zig` | 静态资产发送 |
| `http/range.zig` | Range / Content-Length / ETag |
| `http/api.zig` | JSON API handler |
| `profile/render.zig` | 模板渲染入口 |
| `state/events.zig` | JSONL append writer |

### 7.3 路由

| 路由 | 方法 | 输出 |
| --- | --- | --- |
| `/healthz` | GET | 健康状态 |
| `/boot/config/:node_id` | GET | boot config JSON |
| `/api/v1/nodes/:id/config` | GET | 节点配置 JSON |
| `/api/v1/nodes/:id/answer` | GET | autoinstall/kickstart |
| `/api/v1/nodes/:id/events` | POST | 事件写入 |
| `/api/v1/nodes/:id/logs` | POST | 日志摘要 |
| `/rootfs/:name` | GET | rootfs 文件 |
| `/images/:name` | GET | ISO/image |
| `/repos/:name/*` | GET | repo 文件 |
| `/api/v1/management/runtime` | GET | 本机 CLI 使用的运行态摘要 |

### 7.4 ISO 自动仓库

`nodeforge install-source import <iso>` 执行以下流程：

1. 校验 ISO 类型、SHA256、发行版、版本和架构。
2. 解包到临时目录，提取 installer kernel/initrd，校验成功后 rename 到版本化目录。
3. 在 `/opt/nodeforge/repos/<install-source>/` 发布完整 ISO 内容。
4. Rocky/RHEL 系校验 `.treeinfo`、`repodata/repomd.xml`；Ubuntu 校验 installer media，并单独判断是否具备 apt repository 元数据。
5. 元数据完整时自动创建 `RepositoryConfig`，`base_url` 指向 `/repos/<install-source>/` 并关联 install source；不完整时只创建 install source。
6. renderer 使用已关联 repository 输出 Kickstart `url/repo` 或 Ubuntu apt 配置；缺少必要外部 mirror 时在 profile validate 阶段报错。

ISO 中通过元数据校验的仓库是默认基础源，用户可以追加 mirror/额外源。GPG 检查默认关闭，仅在 repository 明确 `gpg_check = true` 时启用。

### 7.5 boot config

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

### 7.6 事件写入

事件格式：

```json
{
  "ts": "2026-07-06T10:00:05Z",
  "node": "node-01",
  "type": "boot.initrd_started",
  "stage": "initrd_started",
  "message": "initrd started"
}
```

事件写入要求：

- 单行 JSON。
- append only。
- 写入失败返回明确错误。
- 同步更新 `node_status`。

### 7.7 CLI 命令

```bash
nodeforge runtime status
nodeforge runtime events tail --node node-01
nodeforge node status node-01
nodeforge install render node-01
nodeforge install-source import Rocky-9.7-aarch64-dvd.iso --distro rocky --version 9.7 --arch aarch64
nodeforge repository show rocky-9.7-aarch64-iso
```

### 7.8 并发与 HTTP 实现选择

- HTTP 服务器基于 Zap/facil.io 固定提交实现。Zap 负责 HTTP 报文解析、连接生命周期和并发调度，并提供静态文件/Range 所需的库能力；M0 尚未注册静态资产或 Range 路由，M3 再将其接入。NodeForge 当前只维护业务路由、管理 API 和统一错误信封，不维护 HTTP 报文解析或连接循环。已评估的备选方案 `http.zig`（karlseguin）在 Zig 0.16 上尚未充分测试且不承诺完整 HTTP/1.1 合规，不作为依赖。
- acceptor 与固定大小 worker pool 分离；大文件使用 `pread`/send loop 流式发送，不整体读入内存。
- DHCP/TFTP 使用各自 UDP event loop；耗时 hash/文件任务提交到 worker pool，不阻塞收包。
- 配置使用不可变 snapshot + 原子替换；runtime/state 由单 writer 串行落盘，事件追加有独立队列。
- MVP 验收基线：并发 100 个 HTTP Range 下载、100 个 TFTP session 和每秒 200 个 DHCP 报文时无崩溃、无状态串扰；具体吞吐在目标 ARM VM 和 x86_64 机器记录，不先承诺生产数字。

### 7.9 测试

- `/healthz` 返回 OK。
- Range 下载返回 206。
- `If-Range`、无效 Range、连接中断后续传测试。
- answer 渲染返回文本。
- POST event 写入 JSONL。
- runtime summary 与事件同步。

### 7.10 阶段验收

- installer/initrd 能通过 HTTP 拿到配置。
- 事件能写入 `events.jsonl`。
- 大文件下载支持 `Content-Length` 和 Range。
- ISO 导入后无需手工建基础 repo 即可通过 HTTP 安装。

## 9. M4：PXE 无人值守自动安装与基础后处理

### 9.1 目标

首先在当前 Rocky Linux 9.7 aarch64 开发环境跑通 Kickstart，再跑通 Ubuntu Server 22.04 LTS autoinstall；x86_64 是首个生产验收架构，两种架构从初始模型、资产命名和 fixture 层同时支持。

### 8.2 代码任务

| 模块 | 任务 |
| --- | --- |
| `profile/install.zig` | InstallConfig 校验和归一化 |
| `profile/adapter/ubuntu.zig` | autoinstall user-data/meta-data 渲染 |
| `profile/adapter/kickstart.zig` | kickstart ks.cfg 渲染 |
| `profile/render.zig` | 通用模板变量 |
| `boot/cmdline.zig` | install cmdline 渲染 |
| `state/node_status.zig` | install 阶段状态 |
| `provision/runner.zig` | 执行 repository、standard-packages、managed-file 三种基础步骤 |

### 8.3 Ubuntu autoinstall 渲染

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

### 8.4 Kickstart 渲染

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

### 8.5 启动盘配置

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

### 8.6 安装阶段状态

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

### 8.7 CLI 命令

```bash
nodeforge install render node-01
nodeforge install status node-01
nodeforge install logs node-01
nodeforge install retry node-01
```

### 8.8 测试

- Ubuntu autoinstall 渲染 fixture。
- Kickstart 渲染 fixture。
- storage 校验 fixture。
- 未显式认领的节点禁止使用 install profile。
- QEMU UEFI PXE autoinstall smoke test。

### 8.9 阶段验收

- Rocky Linux 9.7 aarch64 和 Ubuntu Server 22.04 LTS 能从 PXE 自动安装到本地磁盘。
- 安装目标盘、ESP、root、swap、bootloader 配置生效。
- 安装事件能更新 `node status`。
- `install render` 可预览 answer file。
- `bundle plan --node` 与安装器实际执行的 `install_post` 顺序一致。

## 10. M5：内存无盘启动与基础后处理

### 10.1 目标

实现 NodeForge 小 initrd + HTTP rootfs 的无盘启动闭环。

### 9.2 代码任务

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

### 9.3 boot bundle manifest

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

### 9.4 小 initrd 行为

流程：

```text
parse /proc/cmdline
  -> read nodeforge.config_url
  -> dhcp network already available or bring up network
  -> GET boot config
  -> POST initrd_started
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

### 9.5 overlay 规则

- `overlay.tmpfs_size` 必须传给 tmpfs `size=`。
- `/var/log`、`/tmp` 等高写入路径先作为配置位，不强制 MVP 单独挂载。
- 持久化 overlay 不进入 MVP。
- rootfs 公共修改使用 `rootfs_build`；节点差异使用 `diskless_boot` 写入 overlay upper。两者复用 M4 的 provisioning runner。

### 9.6 CLI 命令

```bash
nodeforge rootfs package rocky-9.7-aarch64 --format squashfs --version 20260706
nodeforge rootfs validate rocky-9.7-aarch64-<kernel-release>-diskless-20260706.squashfs
nodeforge initrd validate diskless/rocky/9.7/aarch64/<kernel-release>/initrd-nodeforge.img
nodeforge boot-bundle publish rocky-9.7-aarch64-<kernel-release>-diskless-20260706 --kernel rocky-9.7-aarch64-kernel --initrd rocky-9.7-aarch64-nodeforge-initrd --rootfs rocky-9.7-aarch64-rootfs-20260706 --repo rocky-9.7-aarch64-dvd
nodeforge diskless overlay update rocky-9.7-aarch64-diskless --tmpfs-size 50%
nodeforge diskless status node-02
```

### 9.7 测试

- boot bundle 一致性校验。
- rootfs 缺少 `/sbin/init` 报错。
- rootfs `/lib/modules` 与 kernel_release 不匹配报错。
- overlay tmpfs size 解析。
- QEMU UEFI diskless smoke test。

### 9.8 阶段验收

- 节点能 PXE 进入小 initrd。
- 小 initrd 能拉取 boot config。
- rootfs 下载和 SHA256 校验通过。
- `squashfs_overlay` 挂载成功并 `switch_root`。
- `nodeforge node status` 显示 `diskless_running`。

## 11. M6：支持矩阵增强

### 11.1 目标

完善 MVP 周边兼容性和诊断能力。

### 10.2 任务

- Rocky Linux 9.x 优先的 RHEL 系 kickstart 版本能力表。
- x86_64 生产验证记录和 aarch64 真机/QEMU PXE 验证记录。
- BIOS x86 + PXELINUX 链路。
- 安装错误分类。
- ISO/repo/rootfs 资产更完整校验。
- Proxy DHCP spike。
- Secure Boot 风险评估。

### 10.3 BIOS PXELINUX

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

### 10.4 错误分类

错误类型：

- `dhcp.no_available_lease`
- `tftp.asset_not_found`
- `http.asset_hash_mismatch`
- `install.answer_render_failed`
- `install.storage_invalid`
- `install.bootloader_failed`
- `diskless.rootfs_hash_mismatch`
- `diskless.switch_root_failed`

## 12. M7：补充包和后处理增强

### 12.1 目标

M4/M5 已交付 repository、standard-packages、managed-file 和统一 runner。本阶段补齐 archive、script、firstboot、CLI plan/status 和三条链路的完整回归。这里的“配置可视化”是指 CLI 按阶段、步骤和执行结果清晰组织输出，不引入 Web UI 或通用低代码配置系统。

### 11.2 增强范围

本阶段不新增第二套模型，继续使用 3.5：

- 启用 archive 和 script action。
- 增加 firstboot 执行入口。
- 补齐 bundle `show/plan`、运行状态和错误摘要。
- 对 Kickstart、autoinstall、rootfs build 和 diskless overlay 做同一 bundle 的回归。

### 11.3 标准化步骤契约

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

### 11.4 包类型和交付规则

只支持两类补充包：

- 标准包：RPM/DEB 不作为孤立文件逐个安装。它们必须进入额外 yum/dnf/apt repository，通过标准包名和包管理器安装；repository 由 HTTP `/repos/` 提供。
- 非标准包：只支持 `tar.bz2`，manifest 必须包含 SHA256、解压目录和可选 `install.sh`。不在 MVP 增加 wheel、容器镜像或任意压缩格式的专用模型。

`install.sh` 约定：以 bundle 解压目录为工作目录，参数固定为 `install --root <target-root>`，退出码 0 成功；必须可重复执行，禁止隐式下载未声明内容。

### 11.5 统一后处理阶段

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

### 11.6 CLI 配置展示与预览

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

### 11.7 安全与幂等

- 每个 bundle/version/phase 记录执行状态和日志；同版本默认不重复执行，可用显式 `--force` 重跑。
- script 使用固定环境变量、工作目录、超时和输出上限；required script 失败终止该阶段，optional script 只告警。
- 文件更新采用临时文件 + rename，原文件可按 bundle 策略备份；禁止未声明的整目录覆盖。
- 自动安装中的后处理继承 node + install profile 显式绑定；未知节点的 safe diskless 禁止执行 archive install script 和自定义 script。
- bundle 变更生成新版本，不原地修改已发布内容；节点状态记录实际使用版本。

### 11.8 CLI 与验收

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

验收必须覆盖强类型步骤校验、确定性顺序、清晰的分组输出、plan 无副作用、RPM/DEB 额外源安装、tar.bz2 安装、hosts/时间同步配置更新、自定义脚本成功与回滚提示，以及 kickstart、autoinstall、diskless overlay 三条链路。

## 13. 测试矩阵

| 层级 | 内容 |
| --- | --- |
| 单元测试 | packet encode/decode、配置校验、模板渲染、路径 normalize、size expr 解析 |
| fixture 测试 | DHCP 报文、TFTP 请求、answer 渲染、boot bundle manifest |
| 集成测试 | DHCP client、TFTP client、HTTP client |
| QEMU 测试 | UEFI PXE、Ubuntu autoinstall、diskless squashfs overlay |
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

### 13.2 事件版本

事件增加 `v` 字段：

```json
{"v":1,"ts":"2026-07-06T10:00:00Z","node":"node-01","type":"dhcp.discover"}
```

### 13.3 兼容原则

- 新增字段必须有默认值。
- 删除字段必须经过 migration。
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
- `nodeforge runtime events tail` 展示事件流。
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
