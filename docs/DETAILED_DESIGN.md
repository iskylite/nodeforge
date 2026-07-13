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
- NodeForge config 中所有语义为 password 的字段都直接接受并存储明文；当前包括系统用户
  `users.password`、root `ssh.root_password` 和 IPMI `oob.ipmi.password`，未来新增的 repository、proxy、
  HTTP basic-auth 等 password 字段默认继承。JSON、`config import`、`config export` 原样保留明文，不引入
  SecretRef、外部 secret store、加密封装、临时密码状态或轮换流程。adapter 仅在目标格式要求时临时派生
  hash，不得把 hash 回写配置。token、session capability、SSH private key 和派生 password hash 不适用本规则。

### 1.2 阶段划分

| 阶段 | 名称 | 前置 | 核心结果 |
| --- | --- | --- | --- |
| M0 | 项目骨架、单 HTTP listener 和管理接口 | 无 | `nodeforged` / `nodeforge` 可启动，配置和端口可自检 |
| M1 | TFTP 闭环 | M0 | 标准 TFTP client 可下载 x86_64/aarch64 启动文件 |
| M1.5 | CLI 输出统一架构 | M0、M1 | human 输出统一分组/表格/详情格式，JSON 保持稳定机器接口 |
| M2 | DHCP + PXE 闭环 | M0、M1 | 节点获得 lease 和正确 bootfile，并进入 bootloader |
| M2.5 | 结构化日志与事件系统改进 | M0、M2 | 服务日志线程安全、结构化；事件 v2 带字段；CLI 事件查询 |
| M2.5.1 | 节点部署端到端关联契约 | M2.5 | 一次启动拥有稳定 `boot_session_id`，DHCP/TFTP/HTTP/installer/initrd/runner 可按 node 与 session 追踪 |
| M3 | HTTP 资产、ISO 仓库和事件接口 | M0、资产模型、M2.5.1 | 节点可获取配置/answer/rootfs/ISO repo，并按已绑定 session 上报事件 |
| M4 | PXE 无人值守安装与基础后处理 | M1-M3 | Rocky Linux 9.7 aarch64、Ubuntu Server 22.04 LTS 安装和 `install_post` 跑通 |
| M4.1 | 公共目标系统配置、安装生命周期与 M4 answer 纠错 | M4 | 公共系统字段、一次性 install generation/retry/drift、`$6$`/bootstrap key、storage/schema/event 及 M1-M3 横切回归在双 adapter 验收 |
| M5 | 内存无盘启动与基础后处理 | M1-M3、M4.1 公共系统配置、基础 runner | 小 initrd 进入 `squashfs_overlay`，`rootfs_build`/`diskless_boot` 跑通 |
| M6 | 支持矩阵增强 | M4.1、M5 | x86_64 生产验证、RHEL 系差异、Ubuntu 后续 LTS、BIOS PXELINUX |
| M7 | 补充包和后处理增强 | M4.1、M5 | 完善 tar.bz2、自定义脚本、CLI plan/status 和跨链路回归 |
| M8 | 部署链路健壮性、密钥可维护性与传输性能加固 | M4.1 | 部署错误传回 nodeforged、节点级不部署开关、ISO 导入主流 OS+覆盖语义、TFTP windowsize/并发/配置项、免密公钥配置化+CLI 导入、CLI 命令体系校准 |

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

- M0-M8（含 M1.5、M2.5、M2.5.1 和 M4.1）是可验收的产品阶段，按章节依赖阅读和交付。
- M1 先实现正式 TFTP 只读服务，并用标准 TFTP client 验证 RRQ/OACK、重传和路径安全。
- M1.5 在 M2 前收敛 CLI 展示层；它不改变 daemon API、配置或协议语义，但 M2+ 新命令必须复用其 formatter。
- M2 再实现 DHCP 地址、架构识别和 bootfile 决策，最后与 M1 联调完整 PXE 入口。
- M2.5 在 M2 后、M3 前改进日志和事件系统：将 `observe/log.zig` 迁移到 `std.log.scoped`，
  引入 Event v2 结构化字段，补全 TFTP/HTTP 日志，并新增 CLI 事件查询命令。它不改变
  daemon API 或协议语义，但为 M3+ 的 HTTP 事件接口和运行态审计提供基础。
- M4 先跑通安装主链路，M4.1 再收敛目标系统 locale/timezone、离线、SSH/root、包和静态网络配置；
  M5 复用 M4.1 的公共系统配置类型，但无盘包必须在 rootfs build 阶段落盘。M4/M5 交付基础
  provisioning runner；M7 只增强 archive、script、firstboot 和诊断，不是安装或无盘链路的前置阻塞。

## 2. 代码结构总览

代码结构按"少模块、清边界、按需拆文件"设计。MVP 不需要一开始把所有未来目录铺开；先保证主链路短、依赖方向清楚，再在文件变大或职责变多时拆分。

### 2.1 复杂度预算

为了避免代码设计过早复杂化，MVP 执行以下约束：

| 项目 | MVP 约束 | 允许扩展时机 |
| --- | --- | --- |
| 数据模型 | `AppConfig` 表达启动/策略配置，`Catalog` 表达导入/构建/发布得到的管理目录，`RuntimeState` 表达运行态 | 配置迁移或 Web API 需要稳定 schema 时再拆 schema 包 |
| 存储 | M0 使用 `/opt/nodeforge/config/config.json` + `/opt/nodeforge/catalog/catalog.json`；站点配置修改后重启生效。M1+ 才支持 DHCP discovery 策略和 catalog 变更的运行期在线切换 | 并发写入、查询性能或多实例需求出现后再考虑数据库 |
| 管理接口 | 复用唯一 HTTP listener；M3.6 起管理路由仅接受 `127.0.0.1` direct peer；CLI 固定访问该地址，只管理同机服务；不单设 `management_port` | M0 不提供远程管理客户端 |
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

MVP 的目标业务路径如下。M0 历史上只交付 CLI 本地文件操作和 HTTP 管理路由；当前 M1-M3 的
DHCP/TFTP/HTTP 数据路径已有实现与验证，M4 已有实机记录，M4.1 代码与 fixture 已实现并仍在系统级
验收，M5+ 按后续章节交付：

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

## 4. 核心数据模型

本章描述 M1-M7（含 M4.1）的目标模型，不等同于任一历史阶段的实际 schema。第 5 节记录 M0
验收边界；当前代码已实现 M4.1 的 TargetSystemConfig、目标网络和安全默认值，但系统级验收尚未全部
完成。判断能力是否可用必须同时查看代码、fixture 和验证记录，不能仅凭本章出现字段下结论。

### 4.1 配置模型

MVP 不把所有对象都塞进单一手写配置文件，而是分为三类事实源：

| 类型 | 文件 | 主要内容 | 修改入口 |
| --- | --- | --- | --- |
| 启动/策略配置 | `/opt/nodeforge/config/config.json` | M0 为 server/http/logging、发行版矩阵、profile/node/policy 的基础配置；M1+ 扩展 dhcp/tftp、hooks、网络 override、provisioning bundle | M0 手工编辑 + `config validate` 或离线 `config import`，重启生效；M1+ 增加 `config apply` 和 DHCP discovery 在线切换 |
| 管理 catalog | `/opt/nodeforge/catalog/catalog.json` | asset、repository、install source、rootfs、initrd、boot bundle | M0 只读校验/导出；M1+ CLI/API 请求 `nodeforged` import/build/package/publish 并写入 |
| 运行态 | M2/M3.0 使用或兼容读取 `/opt/nodeforge/state/runtime.json`；M3.1 起为 `/opt/nodeforge/state/leases.json`、`/opt/nodeforge/state/node-status.json` 与 `/opt/nodeforge/logs/events.jsonl`；M4.1 增加 `/opt/nodeforge/state/deployment-control.json` | lease、观察 status、install generation/applied revision、事件；活动 session/TFTP 传输仅在内存 | 服务运行时更新 |

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
    match_mac: ?MacAddress,
    address: ?Ipv4Address,
    prefix_len: ?u8,
    netmask: ?Ipv4Address,
    gateway: ?Ipv4Address,
    dns: []Ipv4Address,
    search_domains: [][]const u8,
};

const NetworkMode = enum {
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
    system: TargetSystemConfig,
    install: ?InstallConfig,
    diskless: ?DisklessConfig,
};

const ReinstallPolicy = enum { explicit, always };

const ProfileSafetyConfig = struct {
    safe_for_unknown: bool = false,
    destructive: bool = false,
    persistent_writes: bool = false,
    // 仅 install profile 使用；默认一次性安装，防止固件持续 PXE 时重复擦盘。
    reinstall_policy: ReinstallPolicy = .explicit,
};

const BootSourceRef = union(enum) {
    install_source: []const u8,
    boot_bundle: []const u8,
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
- `NodeNetworkOverride.dns` 和 `search_domains` 用空列表表示未配置；M4.1 静态网络强制 address + prefix，
  且 address 必须等于该节点的 DHCP reservation；netmask 只作为旧配置兼容输入，归一化后统一使用 prefix。
- `oob` 是可选带外管理信息，当前只预留 IPMI；MVP 可以先只保存和展示 BMC 地址/掩码/网关、IPMI 用户名和密码。
- IPMI 用户名和密码直接作为可选明文字段保存，不做 SecretRef、加密封装或轮换状态。
- IP 可以是静态保留或临时 lease，但不能单独作为部署身份，也不能单独触发安装。
- `install_vars` 只能填充 install profile 模板中声明的变量；擦盘、分区、bootloader、安装源仍由 install profile 决定。
- `diskless.overlay_tmpfs_size` 覆盖值必须通过 profile/global 上限校验。
- unknown diskless profile 必须满足 `safety.safe_for_unknown = true`、`safety.destructive = false`、`safety.persistent_writes = false`。
- `DiscoveryAction` 不包含 `install`；配置解析层遇到未知节点安装动作必须报错。

### 4.2 基础数据关系

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
- Ubuntu Server ISO 始终可作为 installer media 发布，且导入时始终将 ISO 内容复制到 `/repos/<source>/` 并创建 `RepositoryConfig` 条目——即使 ISO 不含完整 APT metadata（`dists/pool/Release`）。这使得 `autoinstall.apt.mirror-selection.primary` 始终有一个本地 URL 可用，阻止 Subiquity 回退到 `archive.ubuntu.com`。mirror 不完整时的行为由 profile 的 `install.apt.fallback` 决定：默认 `offline-install` 使用 squashfs；严格 HTTP APT 验收使用 `abort`。
- `gpg_check` 默认 `false`，不要求 GPG key；只有用户明确启用时才校验 key，并向 yum/dnf/apt 输出签名检查配置。
- install profile 的 `boot_source.install_source` 指向 `InstallSourceConfig`，renderer 再从 install source 找 installer kernel/initrd 和 repo。
- diskless profile 的 `boot_source.boot_bundle` 指向 `BootBundleConfig`，boot resolver 再展开 kernel、小 initrd、rootfs 和 repo。
- `kernel_release` 使用 `uname -r`、`/lib/modules/<kernel_release>` 或 kernel 包元数据解析结果。asset store 中文件可以命名为 `vmlinuz`，但 manifest 必须保存真实 release。
- 不依赖运行时直接读取构建机原始 `/boot` 路径；导入后以 asset manifest 的 path、SHA256、kernel_release 为准。

### 4.3 install 配置

```zig
const InstallConfig = struct {
    installer: InstallKind,
    answer_template: AssetRef,
    storage: StorageConfig,
    bootloader: BootloaderInstallConfig,
    apt: AptInstallConfig,
    packages: PackageSelection,
    users: []UserConfig,
    files: []FileOverlay,
    hooks: HookSet,
};

const AptFallback = enum {
    abort,
    @"offline-install",
    @"continue-anyway",
};

const AptInstallConfig = struct {
    fallback: AptFallback = .@"offline-install",
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

locale/timezone/connectivity/SSH 等跨 install/diskless 的目标系统配置位于
`ProfileConfig.system`；节点专属 DHCP/静态 IPv4 位于 `NodeConfig.overrides.network`。`InstallConfig`
不再维护第二份网络事实，避免 profile 共享时复用同一个静态地址。完整模型与默认值见 §9.10。

约束：

- `bootloader.install` 对自动安装 profile 默认必须为 `true`。
- `bootloader.target` 默认指向 `storage.boot_disk`。
- UEFI 安装必须存在 `/boot/efi` ESP 分区。
- BIOS + GPT 安装必须存在 BIOS boot 分区。
- 修改固件启动顺序不是 MVP 必达能力，`set_firmware_boot_order` 默认 `false`。
- `users.password` 直接保存明文，例如 `111111` 或 `asdf1234`。adapter 在渲染 answer file 时按目标安装器要求临时生成 hash，配置事实源仍只保留明文。
- `InstallConfig.packages` 表示发行版标准安装阶段的基础包选择；provisioning step 的 `standard_packages` action 表示安装后或 rootfs 构建时的补充包，二者不得重复渲染。
- `InstallConfig.apt.fallback` 直接对应 Subiquity `autoinstall.apt.fallback`。默认
  `offline-install` 保持旧配置和 ISO 离线安装兼容；要求本地 HTTP APT 必须成功时使用 `abort`；
  `continue-anyway` 仅保留 schema 完整性，不推荐生产使用。

### 4.4 diskless 配置

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

### 4.5 补充包与后处理配置

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

### 4.6 运行态模型

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

- 运行态由 `state` 模块统一修改；M3.1 前的 `runtime.json` 是兼容快照，M3.1 仅在迁移读取它。
- M3.1 将 DHCP lease 与 `node_status` 拆为独立文件、锁和保存生命周期；二者不承诺跨文件事务。
- `leases.json` 由 DHCP checkpoint worker 周期性保存；`node-status.json` 由 HTTP 的关键状态转移同步保存。
- `events.jsonl` 只追加，不作为当前状态事实源。
- discovery/initrd 上报的 `NodeFacts` 默认只是观察数据；只包含 SN、BMC 地址/掩码/网关、IPMI 用户名和密码。管理员确认后可回填到 `node.serial_number` 或 `node.oob.ipmi`。

## 5. M0 验收标准与验证结果

M0 代码按单 HTTP listener、config/catalog/runtime 分层和 `zli v5.1.2` CLI 实现。macOS 构建和单元测试通过，Rocky 9.7 aarch64 完成实机验证。

### 5.1 目标

建立可运行骨架：

- `nodeforged` 可启动、加载配置，并由唯一 HTTP listener 提供 `/healthz` 和管理接口；M3 再在同一 listener 接入 PXE 数据路由。
- `nodeforge` CLI 固定通过 `127.0.0.1:<http.port>` 连接管理接口。
- 启动配置和 catalog 可校验、导出；启动配置可由 CLI 离线导入并原子写回，catalog 写入留待 M1+。
- 日志、错误、输出格式和 CLI 帮助信息成型。
- 通过 `nodeforged --check` 可在启动前检查 IPv4 监听地址和端口占用；正常启动仍由实际 `listen()` 处理最终 bind 结果。目录权限、资产可读性、TFTP/DHCP 检查随对应阶段补齐。

### 5.2 代码任务

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

### 5.3 统一 HTTP 与管理接口

MVP 不实现第二套 RPC，也不再拆成 management listener 与 PXE listener。一个 HTTP server 实现复用路由、JSON 错误、状态和生命周期，只启动一个 IPv4 listener：

- HTTP listener 固定绑定 `0.0.0.0:http.port`。M0 只提供 `/healthz` 和管理 API；M3 将在同一 listener 提供 boot config、answer、repo/rootfs 下载和节点事件。`server.server_ip` 表示 PXE 服务网对外地址，用于生成裸机可访问 URL、DHCP next-server、TFTP/HTTP 广告地址；它不作为 M0 HTTP bind 地址。
- `server.bind_interface` 是 DHCPv4 Linux 服务的必填 PXE 网卡字段，用于约束 DHCP 广播收发；示例的 `enp1s0` 只是占位值，部署前必须替换为承载 `server.server_ip` 的实际接口。静态校验拒绝空值；实际 bind 继续验证接口存在且可用。
- `nodeforge` CLI 管理客户端固定连接 `127.0.0.1:http.port`，不提供远程管理地址配置项。
- MVP 不配置独立 `management_port`。管理路由和 PXE HTTP 数据路由共用 `server.http_port`，默认 `8080`；端口冲突时修改 `config.json` 并重启。
- 管理路由与未来 PXE 数据路由逻辑分区；M3.6 在 route 入口仅允许 direct peer `127.0.0.1` 调用 `/api/v1/management/`，不信任 `X-Forwarded-For`。
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

### 5.4 CLI 命令

CLI 解析、帮助信息、参数类型和默认值使用 vendored `zli v5.1.2`。该 release 的 `minimum_zig_version` 为 `0.16.0`，与本项目一致。根命令、资源命令、动作命令、命令局部 flags 和位置参数组成唯一命令树；zli 从这棵树执行解析、校验和分级帮助，不再保留独立的 `dispatchHelp` 或手写 Usage/Options/Commands 清单。NodeForge 在 `vendor/zli/NODEFORGE_PATCHES.md` 记录少量上游兼容修补，并用 `tests/cli.sh` 固定命令局部参数不会泄漏到无关子命令。zli 只负责 CLI 语法和帮助，不承载复杂业务配置模型。

zli 提供 spinner，但 M0 不启用。只有后续耗时交互命令同时处于 TTY、human 输出且存在明显等待时才可启动；`--output json`、重定向、管道和 systemd 场景禁止输出动画或终端控制序列。

帮助和版本属于 CLI 通用控制能力，只提供 `-h/--help` 与 `-v/--version` 参数，不定义 `help`、`version` 同名子命令。`-v/--version` 只属于顶层 `nodeforge`；`-h/--help` 由每一级命令提供。`--config`、`--catalog`、`--output` 不作为全局参数，只挂在实际读取它们的叶子命令上，必须写在该命令之后。子命令集合只保留 status、check、config、catalog 等业务入口，避免同一操作存在两套写法。

M0 短参数固定为：`nodeforge` 根命令 `-v`，叶子命令按需使用 `-c`（config）、`-C`（catalog）、`-o`（output）、`-d`（debug）；`-h` 由 zli 自动提供。`nodeforged` 为无子命令入口，使用 `-v/-c/-C/-d/-k/-K`（version/config/catalog/debug/check/check-config），并提供 `--log-output auto|terminal|file|both` 与 `--log-file <absolute-path>`。帮助页不内嵌长命令示例，但每个枚举、关联或格式不直观的参数必须在 description 中给出一个字段级 `e.g.` 值，并说明其关联参数。

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

### 5.5 配置与 catalog 校验

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

### 5.6 启动自检、服务检查与 systemd

M0 将无副作用的 preflight 暴露为 `nodeforged --check`；正常启动不会以一次预检替代实际 bind：

- `--check-config` 只校验配置和 catalog。
- `--check` 在上述校验后，对唯一 HTTP 端口执行 connect-then-bind 预检，但不长期启动；活跃 listener 立即失败，刚释放的 socket 可借助 `SO_REUSEADDR` 快速重启。
- 正常启动直接调用 Zap `listen()`；预检与实际启动间存在短暂竞态，bind 失败仍由启动路径返回。
- UDP 69、UDP 67 和资产可读性检查分别随 M1、M2、M3 服务实现加入，避免未实现服务产生虚假的通过状态。

M0 的 `nodeforge check` 在服务运行后通过 `127.0.0.1:<http.port>` 验证 process、HTTP、management route 和配置 API。
TFTP 探针、DHCP resolver、repository 和 state 检查在对应阶段实现后逐项加入。

提供 `packaging/systemd/nodeforged.service`：

- `ExecStart=/opt/nodeforge/bin/nodeforged --log-output file`
- `ExecStartPre=/opt/nodeforge/bin/nodeforged --check --log-output file`
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

- 直接执行 `nodeforged` 默认输出到 stderr。systemd unit 显式传入 `--log-output file`，默认写入 `/opt/nodeforge/logs/nodeforged.log`；目录必须由安装过程创建并对服务用户可写。需要 journal 的部署使用 `--log-output both` 覆盖 unit，或通过 systemd drop-in 替换 `ExecStart`。
- 日常 `info` 日志包含成功监听地址、每个 HTTP 请求的 method/path/status，以及配置、校验或预检失败的错误摘要。
- `config.json` 的 `logging.level` 只接受 `info`（默认）和 `debug`。`nodeforged -d/--debug` 仅覆盖本次进程启动，优先于配置；它不写回配置文件。M0 当前的 debug 请求日志为 method/path；连接建立/关闭、DHCP/TFTP 报文摘要和更细协议诊断随对应服务阶段补齐，ReleaseSafe 也可使用。
- `nodeforge` 的每个 M0 叶子命令支持 `-d/--debug`。默认只输出一行 `error: <类别>: <简短原因>: <路径>`；debug 模式在下一行追加内部错误标签，便于定位但不泄漏请求体、token 或密码。
- M1+ 节点事件、安装阶段、无盘阶段等业务事件进入 `events.jsonl`，不与服务进程日志混为一个文件；M0 仅提供其基础类型和追加工具。

M2.5 回归 M0 的 `--check-config`、`--check`、`status`、HTTP integration 与 systemd 快速重启用例，
验证新后端不会改变已有 stdout/stderr CLI 错误、HTTP error envelope、端口预检或启动失败退出码。

### 5.7 测试

- 配置 JSON 成功加载。
- 缺失必填字段返回结构化错误。
- 原子写回不会损坏旧文件。
- CLI `--output json` 输出可解析 JSON。
- 顶层、资源级和动作级 `-h/--help` 可显示用途、参数和默认值；长示例只放在 README、设计文档和运维手册，避免帮助页冗长。
- 模拟端口占用时 preflight 明确失败。
- 管理路由仅接受 loopback direct peer；CLI 固定连接 `127.0.0.1:<http.port>`，只管理同机服务。
- `logging.level=debug` 和 daemon `-d` 能输出服务 debug 日志；CLI `-d` 能在简短错误后显示底层原因。
- `tests/http.sh` 覆盖全部 M0 HTTP 路由、统一 404、重复 listener 拒绝及 daemon `-d`。

### 5.8 阶段验收

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
- [x] M3.6 管理路由只接受 `127.0.0.1` direct peer，CLI 固定连接该地址且不提供远程 endpoint。
- [x] 通过 `tests/cli.sh` 端到端 CLI contract tests 覆盖自动帮助、命令局部 flags 和解析错误退出码。
- [x] 通过 `tests/http.sh` 和 Rocky 9.7 aarch64 实机验证覆盖 HTTP 路由、端口预检和 systemd 快速重启。

### 5.9 Rocky 9.7 aarch64 实机验证记录

2026-07-11 在 `r97n0`（`192.168.26.128`，Rocky Linux 9.7 aarch64）部署当前 Zap/facil.io
二进制后，完成以下验证：

- `nodeforged --check-config`、空闲端口上的 `nodeforged --check`、`nodeforge config validate` 均成功。
- systemd 正常启动，并连续快速重启两次；`ExecStartPre` 的 `--check` 与实际服务启动均成功。
- VM 本机和 VM 外部访问 `/healthz`、`/api/v1/management/server/status` 均返回 200；`nodeforge status`、`nodeforge check` 通过本机管理地址成功。
- 服务运行时，第二个 `nodeforged --check` 与第二个 daemon 都因 HTTP listener 已占用而失败。
- `nodeforged -d` 和 `logging.level = "debug"` 均输出 M0 的 HTTP method/path debug 日志。

本段只记录 2026-07-11 当时的 M0 验收；随后完成的 TFTP、DHCP 等系统级验证见
[`ROCKY_9_7_VALIDATION.md`](ROCKY_9_7_VALIDATION.md)。

## 6. M1：PXE TFTP 闭环

**完成状态（2026-07-11）：已实现并在 Rocky Linux 9.7 aarch64 的 `root@r97n0`
完成系统级验证。** 验证命令、SHA-256、OACK/重传和安全负向用例记录于
[`ROCKY_9_7_VALIDATION.md`](ROCKY_9_7_VALIDATION.md#m1-tftp-待验证)。

### 6.1 目标

实现标准 TFTP 读路径，确保节点能拉取 PXE 启动资产。

### 6.2 代码任务

| 模块 | 任务 |
| --- | --- |
| `tftp/packet.zig` | RRQ/DATA/ACK/ERROR/OACK 编解码 |
| `tftp/server.zig` | UDP 69 dispatcher、option 协商、路径 normalize、session 状态机、虚拟 GRUB 配置拦截 |
| `assets/store.zig` | asset manifest 读写，bootloader/kernel/initrd/ISO/rootfs 等资产导入 |
| `assets/validate.zig` | asset 类型、路径、SHA256 校验 |
| `boot/grub.zig` | UEFI GRUB 配置渲染（`linux`/`initrd` 指令，架构无关） |
| `boot/target.zig` | 从 TFTP boot 身份 + config/catalog 展开 kernel/initrd/cmdline |
| `state/runtime.zig` | TFTP session 运行态 |

### 6.3 TFTP 行为

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

协议边界补丁（纳入 M4.1 前置回归，但归属仍为 M1）：

- `blksize`、`timeout`、`tsize` 的格式或范围非法时返回 option negotiation/illegal operation 错误，不能
  静默截断；RRQ 中 `tsize` 只接受 RFC 2349 允许的查询形式。
- 未识别 option 按 RFC 2347 忽略，已识别且接受的 option 才进入 OACK；OACK 后必须先收到 ACK block 0。
- 客户端从当前 transfer TID 发送 ERROR 时立即终止该传输并记为 failed；未知 TID 的 DATA/ACK/ERROR 不得
  影响其他传输。超时达到重传上限后释放 socket/fd 和运行态槽位。
- `RuntimeState.TftpState.max_sessions=32` 是 CLI 最近会话历史环的容量，不是 32 个活动传输的并发拒绝阈值，
  不得据此返回“server busy”。当前 M1 dispatcher 串行传输的吞吐限制由 M6 压测后再决定是否引入有界 worker。

### 6.4 bootloader 配置生成

GRUB 配置由 `boot/grub.zig` 渲染，`boot/target.zig` 负责从 TFTP boot 身份和
catalog/config 快照展开 kernel/initrd 路径和 cmdline：

```text
set timeout=5
menuentry 'NodeForge - {{node_id}}:{{lease_ip}} - {{profile}}' {
  linux {{kernel_path}} {{cmdline}}
  initrd {{initrd_path}}
}
```

`lease_ip` 为 DHCP 分配的 IPv4 点分十进制形式（如 `192.168.27.210`），
由 `TftpBootIdentity.lease_ip` 在 TFTP handler 中传入渲染器。

**架构指令选择**：ARM64 `grubaa64.efi` 和 x86_64 `grubx64.efi` 均使用标准 `linux`/
`initrd` 指令。不使用 `linuxefi`/`initrdefi`——前者只在特定发行版的 GRUB 构建中
可用，不能作为默认假设。

**虚拟 GRUB 配置发布（M3.5）**：`grub.cfg` 不落盘、不进入 catalog，而是在 TFTP
RRQ 时即时渲染。GRUB 按 PXE 标准查找规则请求配置文件名，TFTP handler 在 catalog
manifest gate 之前拦截这些请求：

1. `efi/grub.cfg-01-<MAC>` — 以客户端 MAC 地址查找（连字符分隔，小写）。
2. `efi/grub.cfg-<IP>` — 以客户端 IPv4 的大写十六进制形式查找（如 `C0A81BC8`）。
3. `efi/grub.cfg` — fallback。

拦截后通过 `boot_session.resolveTftpBoot` 从 Peer IP 检索已 ACK 的 boot session，
获取 `TftpBootIdentity`（node_id, profile, mode, mac, lease_ip），再由
`boot/target.resolve` 展开为 `BootTarget`（kernel_path, initrd_path, cmdline, arch），
最终调用 `grub.render` 生成配置文本并从内存传输。

未认领节点、无活动 session、会话不唯一或 discovery mode 不渲染任何 kernel/initrd
条目。它们不是磁盘文件缺失：M3.6 返回 TFTP ERROR code 2（access violation）及不含
身份资料的 `boot configuration requires an active DHCP lease` 或
`boot configuration unavailable for this node`，而不是 ERROR code 1 / `file not found`。
真正不存在、未纳管的静态文件仍返回 ERROR code 1。配置文本不含 `boot_session_id` 或
capability token。

MVP 同时支持 UEFI x86_64 和 UEFI aarch64 GRUB，分别使用 `grubx64.efi`、
`grubaa64.efi`。BIOS PXELINUX 在 M6 完整化。

### 6.5 CLI 命令

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

### 6.6 测试

- RRQ 成功返回 DATA block。
- 文件不存在返回 ERROR。
- 路径穿越被拒绝。
- option 协商正确。
- block 重传正确。
- 标准 TFTP client 可分别下载 `grubx64.efi`、`grubaa64.efi`。
- 使用系统 `tftp`/`atftp` 客户端验证 RRQ/OACK、重传、路径和状态管理，不依赖 DHCP。

### 6.7 阶段验收

- [x] x86_64/aarch64 PXE 客户端可通过 TFTP 拉取对应 GRUB EFI 文件。
- [ ] GRUB 可拉取配置、kernel、initrd。  <!-- M3.5: grub.cfg 虚拟发布已实现，kernel/initrd 需 M3.5 实机闭环验证 -->
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
- ACK/OFFER 的 option 51/58/59 必须来自同一个 `lease_seconds`：lease time 为配置值，T1 renewal 默认
  `floor(lease_seconds/2)`，T2 rebinding 默认 `floor(lease_seconds*7/8)`，并满足 `0 < T1 < T2 < lease`。
  本项是 M2 DHCP 协议补丁，也是 M4.1 长时间安装验收前置条件；不为 install profile 临时发明另一套 lease。
- **Linux DHCP 广播接收边界**：客户端在获得地址前向 `255.255.255.255:67` 广播。Linux 不会把这类
  datagram 投递给只绑定 `server.server_ip` 的 socket，因此 DHCP listener 必须绑定 wildcard
  UDP/67；同时必须以 `SO_BINDTODEVICE(server.bind_interface)` 限定接收/发送接口，避免多网卡主机
  在管理网段回答请求。TFTP 仍只绑定 `server.server_ip:69`，因为 DHCP 已明确将该地址作为
  `next-server` 广告给客户端。
- **ACK 归属约束**：动态地址（未知节点和没有静态保留地址的已登记节点）必须先存在同一 MAC 的未过期
  OFFER，才会转换为 ACK；任意 REQUEST 不能取得池内地址。唯一例外是已登记节点声明的静态保留地址，
  它可在服务重启后没有内存 OFFER 的情况下确认其配置 IP。
- **M2 生命周期边界（M2 阶段记录，M2.5 已解决；M3.1 补充持久化协调）**：M2 的 DHCP/TFTP worker 为 detached
  长循环，进程退出会关闭 socket 终止 worker，尚无 graceful shutdown 协调器。M2.5 已引入 `stop_workers`
  原子标志和 worker join；M3.1 将增加 DHCP checkpoint worker 的 final flush 和 join。有序停机顺序见 §8.1.3。
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
- renewal time（option 58，默认 lease 的 1/2）
- rebinding time（option 59，默认 lease 的 7/8）
- server identifier

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

边界与运行期策略补丁：

- pool 无可用候选时不伪造 NAK；DISCOVER 无法 OFFER 时保持无回复并记录 `dhcp.no_available_lease`，REQUEST
  请求了非法/冲突地址时才按 RFC 语义 NAK。Ping Probe 对单一候选只执行一次有界 deadline；冲突后继续下一个
  候选，候选全部 occupied/abandoned 后记录稳定 reason，probe 自身 unavailable 则取消本次 OFFER。
- DHCPINFORM 不分配 lease，只在能够唯一确定 subnet/server policy 时返回不含 lease/bootfile 的配置 ACK；
  M4.1 前未实现则显式返回 unsupported/no reply，不能误走 REQUEST 分配路径。
- node 身份仍以已登记 MAC 为主；option 61 只作为同一 MAC 的辅助一致性证据。client-id 与 MAC 指向不同节点时
  拒绝自动选择 profile，并记录 `dhcp.identity_conflict`，不能用 option 61 静默覆盖 MAC 绑定。
- 运行期切换 unknown discovery policy 只影响后续 boot 决策；已经 ACK 的临时 lease 保留到 RELEASE/过期，
  不立即回收，避免把仍在使用的地址分配给其他节点。策略改为 deny 时可停止下发 bootfile，但不得撤销地址。

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

服务日志是面向本机运维人员的诊断输出，时间戳使用 daemon 主机本地时区，并始终携带 RFC 3339
数字偏移（例如 `2026-07-13T11:17:05+08:00`），避免与 `date`、systemd 等本机工具对照时产生固定
时差。`events.jsonl` 是跨节点查询的结构化审计契约，其 `ts` 继续使用 UTC `Z`，不得随主机时区变化。

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
| terminal | `--log-output terminal`，或未配置文件 sink 时的 `auto` | 直接输出到 stderr |
| file | `--log-output file` | 仅写入文件；默认路径为 `/opt/nodeforge/logs/nodeforged.log` |
| both | `--log-output both`，或配置文件 sink 时的 `auto` | 同时写 stderr 和文件；systemd 会采集 stderr 到 journal |

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

- `--log-output auto` 是交互式默认值：配置 `logging.file` 时选择 `both`，否则选择 `terminal`，保持已有配置兼容。
- `--log-output file` 或 `both` 使用 `--log-file` 的绝对路径；未指定时优先使用 `logging.file.path`，再回退到 `/opt/nodeforge/logs/nodeforged.log`。轮转大小和保留数量取 `logging.file`，未配置时为 50 MiB 和 3 个历史文件。
- 文件 sink 失败时当前记录回退到 stderr，并节流报告后端降级；不得启动独立的 journald/syslog client。
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
    boot_config_fetched,
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
            .boot_config_fetched => .{ .name = "boot.config.fetched", .description = "authenticated boot config issued" },
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

### 7.5.12 M2.5.1：节点部署端到端关联与可追踪性契约

> **状态：M2.5.1 server-side 已实施并在 Rocky 9.7 aarch64 验证。** 本节不把日志文本当成状态机，
> 也不要求未实现的 M3–M7 伪造事件；后续阶段必须继续遵守这里固定的关联身份、状态投影和查询语义。

#### 7.5.12.1 问题与目标

M2.5 已经能分别观察 DHCP、TFTP 和 HTTP 请求，但单独的 MAC、IP、XID、客户端 IP 或文件名都不能
稳定回答“这台节点这一次启动最终在哪一步失败”：DHCP XID 只在一个事务内有效，IP 可复用，TFTP 没有
节点身份，installer/initrd 又发生在后续 HTTP 链路。M2.5.1 定义一个由服务端创建的、跨协议贯穿的
`boot_session_id`，让运维人员能从 `node_id` 或 session 得到按时间排序的完整因果链。

设计目标：

- 同一节点的每次网络启动都有不同、不可猜测且不可复用的 session；重启、重新 PXE 或并发启动绝不合并。
- 已认领节点可按 `node_id + boot_session_id` 追踪 DHCP、TFTP、HTTP、安装、无盘和 runner 阶段；未知节点
  只保留 MAC/IP/session 的受限观察记录，不能借此获得安装权限。
- `node_status` 是当前投影，Event v2 是不可变审计；查询从事件重建时间线，不从服务日志猜测阶段。
- session id 仅是关联标识，**不是**认证 token、授权凭据或可用于读取节点配置的 capability。

#### 7.5.12.2 统一身份与生命周期

`boot_session_id` 是服务端生成的 128-bit 随机值，编码为固定 32 个小写十六进制字符；不得使用 MAC、
IP、XID、时间戳、递增计数或可预测 hash 派生。Event v2 新增的保留字段为 `boot_session_id` 与
`daemon_instance_id`；两者长度均为 32，且只允许 `[0-9a-f]`。前者与既有 `node_id`、`mac`、`ip`、
`xid` 并列，不取代其中任何一个字段；后者只标识产生事件的 daemon 进程实例，绝不参与节点关联或认证。
`session_link_state` 是仅服务端写入的受控诊断字段：正常唯一关联时省略该字段并携带
`boot_session_id`；无法安全关联时只能取 `capacity_exhausted`、`no_active_lease_match` 或
`ambiguous_lease_match`，不得由 HTTP DTO、installer、initrd 或 runner 提交。

```text
DHCP DISCOVER (MAC, XID)
  -> server creates/resumes BootSession
  -> DHCP / TFTP events carry boot_session_id
  -> M3 authenticated boot-config response embeds boot_session_id
  -> installer or initrd echoes it in a restricted event DTO
  -> server validates node_id/session binding, updates node_status, appends Event v2
  -> terminal event closes session; audit history remains queryable
```

`BootSession` 是运行态对象，至少包含：

| 字段 | 语义 |
| --- | --- |
| `id` | `boot_session_id`；不可变主键 |
| `node_id` | 已认领节点的稳定 ID；未知节点为 null |
| `mac` | 创建 session 时的客户端 MAC；不可变 |
| `lease_ip` | 当前或最后一次 DHCP 地址；可随 ACK/RELEASE 更新 |
| `dhcp_xid` | 创建 session 的 XID；只作诊断，不作关联主键 |
| `profile` / `mode` | 服务端 resolver 决定的 profile 与目标模式快照 |
| `created_at` / `last_seen_at` | 服务端 UTC 时间 |
| `phase` | 当前规范化阶段；见下表 |
| `terminal_reason` | 完成、失败、过期或被新 session 取代的稳定原因 |

DHCP DISCOVER 为同一 MAC 创建新 session，唯一例外是该 MAC 已有未终止、且仍处于 DHCP early phase 的
session：在短暂重传窗口内按 MAC + XID 复用，避免同一个 DHCP 重传生成多条链。收到不同 XID 的新的
DISCOVER、session 进入 terminal 状态、或超过 early-phase TTL 后，必须新建 session。地址租约过期不删除
历史 session，只将其标记为 `expired`；保留和轮转仍由 events 文件策略决定。

`BootSession` 注册表是**仅进程内、固定上限**的活动关联索引，不写入 `runtime.json`，也不在 daemon
重启后恢复。这个选择是刻意的：重启已经中断 DHCP/TFTP 服务，恢复旧 session 会让 MAC、IP 或 XID 的
后续巧合命中被误当成同一次启动。每个进程启动生成新的 `daemon_instance_id`（同样为服务端随机 128-bit
小写十六进制值）；EventWriter 在所有服务端 Event 上附加该保留字段，调用方不得提交或覆盖它。优雅停止时，
服务必须在 `service.stopped` 前将仍活动的 session 以 `daemon_shutdown` 终止并追加审计事件；崩溃后无法
补写时，下一次 `service.started` 的新 `daemon_instance_id` 是 `trace` 必须显示的 `daemon_restart_gap`，而
不是“部署成功”或“session 已恢复”的证据。

活动 session 上限与 DHCP lease 上限一致，初始固定为 256；注册表以 mutex 保护，并按 session id、
MAC+XID 和 lease IP 建立有界索引。过期或终态条目可立即从活动索引回收，历史查询始终扫描 Event v2，
不依赖该索引保留旧对象。达到上限时，DHCP 必须继续按 resolver 正常应答，不得因观测容量导致 PXE 不可用；
该请求写入不含 `boot_session_id` 的 DHCP Event，并固定携带
`session_link_state = "capacity_exhausted"`，同时做限频 warn。`trace` 对此显示明确 `gap`，不得临时生成
无法由 TFTP 或后续 HTTP 验证的假 session。

TTL 和重传窗口只能使用服务端单调时钟判断，防止 NTP 校时或客户端时间影响关联；写入 Event 的
`created_at`、`last_seen_at` 与 `ts` 使用服务端 UTC，仅用于显示和排序。同一 MAC+XID 的 DHCP 重传及
同 phase 的重复节点上报是幂等刷新，不是非法状态迁移；随机 id 若极低概率碰撞，服务端必须重试生成，绝不
覆盖现有 session。

#### 7.5.12.3 协议关联规则

| 边界 | 服务端如何关联 | 必带 Event 字段 | 禁止的推断 |
| --- | --- | --- | --- |
| DHCP | MAC + XID 命中/创建 BootSession | 正常时为 `boot_session_id`、`mac`、`xid`、`ip`、`node_id`（已知时）；容量降级时为 `session_link_state` | 不能仅按 IP 认定节点 |
| TFTP | 仅以客户端 IP 查找未终止、且 lease IP 匹配的 session；零或多条匹配时不猜测 | 唯一匹配时为 `boot_session_id`、`client_ip`、`filename`、`bytes_sent`；否则为对应的 `session_link_state` | 不能从文件名、TID 或最近 DHCP 事件强行绑定 |
| M3 HTTP boot config/answer/rootfs | 已认证 URL node id 与 active session 的 `node_id` 必须一致；服务端把 id 写入响应 | `node_id`、`boot_session_id`、`path`、`client_ip` | `boot_session_id` 不能替代节点认证 |
| installer/initrd 上报 | DTO 的 session 必须等于服务端已签发且绑定该 node 的 active session | `node_id`、`boot_session_id`、`source`、`stage` | 客户端不得指定其他 node、source、服务端事件类型或时间 |
| runner/firstboot | 从受验证的 node config/运行上下文继承 session；无 session 时创建显式 `run_id` 关联但不得伪称 boot session | `node_id`、`boot_session_id`（适用时）、`run_id`、`phase`、`step` | 不能用相同 message 合并两次执行 |

TFTP 无法进行节点认证，因此它的关联仅是诊断级 best effort；只有 DHCP lease 与活动 session 唯一匹配时才
写 `boot_session_id`。零个匹配写 `session_link_state = "no_active_lease_match"`，多个匹配写
`session_link_state = "ambiguous_lease_match"`；该状态在同一传输的 RRQ、完成、超时和失败事件中保持一致。
这避免 NAT、IP 复用或并发 PXE 时把错误 bootloader 传输归到另一台节点。

#### 7.5.12.4 阶段状态机与状态投影

M2.5.1 统一阶段名，事件类型仍表达具体动作。合法的单 session 主路径如下；`failed` 可从任一非终态
进入，`expired` 可从非终态由服务端超时进入：

```text
dhcp_discover -> dhcp_offer -> dhcp_ack -> tftp_rrq -> boot_config_fetched
  -> installer_started -> installing -> installed -> provisioning -> completed
  OR
  -> initrd_started -> rootfs_downloading -> rootfs_verified -> rootfs_mounted
     -> switching_root -> diskless_running
```

| 规范化 phase | 产生者 | 对应事件 |
| --- | --- | --- |
| `dhcp_discover` / `dhcp_offer` / `dhcp_ack` | M2 DHCP | `dhcp.*` |
| `tftp_rrq` / `tftp_complete` | M1 TFTP | `tftp.rrq` / `tftp.transfer.complete` |
| `boot_config_fetched` | M3 | 已认证 boot config HTTP 请求 |
| `installer_started` / `installing` / `installed` | M4 installer | `install.*` |
| `initrd_started` 至 `diskless_running` | M5 initrd | `diskless.*` |
| `provisioning` / `completed` | M4–M7 runner | `provision.step.*` |
| `failed` / `expired` | 服务端或节点 | `*.failed`、稳定 `reason` 或 server expiry event |

`node_status` 最少增加 `boot_session_id`、`phase`、`last_event_at`、`last_error`、`last_reason`。更新顺序固定：
验证身份与 session binding -> 校验 phase transition -> 原子更新 `node_status`/BootSession -> append Event v2。
writer 失败不回滚状态；返回 5xx 并允许节点按 at-least-once 重试。重复上报同一阶段是幂等状态更新，但仍可
保留重复审计事件；只有显式 event id 的持久化去重才可改变该语义，超出 M2.5.1。

#### 7.5.12.5 查询、日志与故障定位

M2.5.1 扩展本机只读查询，而不建立远程日志 API：

```text
nodeforge events list --node node-01 --session <boot_session_id>
nodeforge trace node-01 [--session <boot_session_id>] [--latest]
nodeforge node status node-01
```

`trace` 默认选择该 node 最新的非过期 session；读取先保持轮转文件从旧到新及文件内 append 顺序，服务端 `ts`
用于显示和时间过滤，不作为重排同一审计流的唯一依据。输出显示 phase、event type、
安全摘要、reason、session 和缺失边界。它必须明确标注 `unlinked`（由 `no_active_lease_match` 或
`ambiguous_lease_match` 产生）和 `gap`（例如 installer 未上报、事件文件轮转或损坏），不得把缺失事件
渲染为成功。除 session 事件外，trace 必须读取相关时间窗内的全局 `service.started`/`service.stopped` 事件：
若一个未终止 session 的最后事件之后出现新的 `daemon_instance_id` 的 `service.started`，插入
`daemon_restart_gap`；Event v2 的 UTC 时间精度为秒，因此同一秒内实例 ID 变化也必须视为该边界，
不能因显示时间相等而丢失 gap。已经以 `daemon_shutdown` 终止的 session 不产生该 gap。

BootSession/bootstrap/delivery TTL 一律使用单调时钟；UTC 只用于人类时间。若同一 daemon 的新 Event `ts`
早于上一条，writer/trace 记录 `service.clock_unreliable`/`clock_regression` gap 并继续服务，不能按编译时间猜测
RTC，也不能把回拨后的事件重排到已确认因果之前。跨 daemon 且主机时间不可信时只能按文件顺序与
`daemon_instance_id` 展示边界，不宣称存在可靠的全局时间顺序。

`gap.kind` 固定为 `capacity_exhausted`、`session_unlinked`、`session_ambiguous`、`daemon_restart_gap`、
`clock_regression`、`missing_phase`、`event_retention_gap` 或 `event_corrupt`，不得通过自由文本扩展。`--output json` 输出稳定的
`{node_id, boot_session_id, status, events, gaps}` 对象；每项 `gap` 都包含稳定 `kind`、服务端时间范围与
安全诊断摘要。human view 给出当前 phase、失败点与下一步建议，并区分“已观察到”“唯一安全关联”“未关联”和
“无法判断”四种证据等级。

服务日志只补充 `node_id=<...>`、`session=<...>`、`mac=<...>`、`xid=<...>` 等有限诊断键；它不是 trace
的事实源。日志、Event.message 和 fields 一律不得记录认证 token、cookie、完整 answer file、HTTP body、
完整 installer/initrd journal 或脚本 stdout/stderr。

#### 7.5.12.6 接口与安全边界

- M3 boot config、answer 和节点事件 DTO 必须由同一个认证结果决定 `node_id`；客户端提供的 node id、
  session、source 和 event type 都是待验证输入，不能直接写入 Event。
- `boot_session_id` 出现在 boot config/answer 中仅用于关联；泄露它不会授予 HTTP 读取、事件写入或 profile
  选择权限。认证材料与 session id 分离。
- 服务器只接受当前或可重试窗口内、绑定同一 node 的 session。未知、过期、已被新启动取代或 node 不匹配的
  session 返回 409，且记录服务 warn；不得产生 domain Event 或覆盖 `node_status`。
- 安装器和 initrd 失败上报仅允许稳定 `reason`、受限 stage 和最多 2048 bytes 的净化摘要；原始日志仍在节点本地。
- 发生 session binding 冲突时宁可形成 `unlinked` 诊断事件，也不得把事件归属到错误节点。

#### 7.5.12.7 实施拆分与验收

M2.5.1 先实现 server-side `BootSession` runtime、`daemon_instance_id`、DHCP 创建/更新、优雅停止的
session 终止、TFTP 唯一关联和 `events --session`；M3 实现经认证的 boot config 签发、节点 DTO binding
与 `node_status`；M4/M5/M7 分别接入 installer、initrd 与 runner 的阶段事件。各阶段不得另行定义 session
格式或旁路 writer。

验收至少包括：DHCP 重传复用、同 MAC 新 XID 新建 session、IP 复用不误关联、并发 PXE 的 TFTP ambiguous
标记、活动注册表满时 DHCP 仍成功且 trace 显示 `capacity_exhausted`、优雅停止写入每个活动 session 的
`daemon_shutdown`、崩溃后的新实例显示 `daemon_restart_gap`、过期/错绑 session 409、installer 与 initrd
的合法/非法 DTO、状态幂等重试、`trace` 跨轮转时间顺序、失败摘要脱敏以及从 `nodeforge trace` 定位到失败
phase 的端到端 fixture。

## 8. M3：HTTP 配置、资产、ISO 仓库和事件接口

### 8.1 目标与阶段边界

HTTP 成为 TFTP 之后的主要数据通道：

- 提供 boot config。
- 提供 answer file。
- 提供大文件下载和 Range。
- 接收事件和日志摘要。

M3 交付的是受控 HTTP 数据面、ISO 到 catalog 的原子发布路径，以及节点状态上报入口；它不提前交付
M4 的 Kickstart/Autoinstall 语义，也不提前交付 M5 的 dracut module。`profile/render.zig` 在 M3 只负责
受限模板变量、内容类型和认证上下文注入；发行版 adapter、存储布局、用户、软件包和 firstboot 逻辑仍由
M4 负责。这样 M3 可以用受控 fixture 验证 answer 路由，M4 才把它替换为真实安装器输出。

M3 还必须完成 M2.5.1 定义的三项服务端责任：认证后的 boot config 签发、`node_status` 状态投影，以及
`boot.config.fetched` 事件。它不把服务日志当作状态来源，也不创建新的 Event JSONL writer。

#### 8.1.1 认证结果与 session 生命周期

所有节点侧请求先归一化为服务端唯一的 `AuthenticatedNodeSession`：

```text
{ node_id, boot_session_id, profile, mode, peer_ipv4, daemon_instance_id }
```

它只能由下列两种证明产生，随后由 handler 使用该结果，而不是重新信任 URL、body 或 header 中的 node id：

1. **bootstrap proof**：请求 URL 中的 `node_id` 与已认领节点一致，直接 TCP peer IPv4 等于活动
   `BootSession.lease_ip`，且 session 的 `node_id` 相同。只接受直连 peer；绝不信任
   `X-Forwarded-For`、DHCP 以外的“最近 IP”或 TFTP 文件名。未知节点、无 lease 匹配或 node 不匹配不获得
   boot config/answer。
2. **capability proof**：bootstrap 成功后，daemon 为该活动 session 生成 256-bit 随机
   `node_access_token`，仅保存在进程内 `BootSession`，并只在已认证的 boot config/answer 输出中注入。
   客户端以 `Authorization: Bearer <token>` 和 `X-NodeForge-Session: <boot_session_id>` 提交；两者必须
   同时匹配活动 session。`boot_session_id` 只是关联键，单独永远不能授权。

token 不持久化、不得出现在 URL path/query、kernel cmdline、HTTP access log、服务日志、Event fields、错误
响应或 `/run/nodeforge/boot.json`。它只可作为 M4/M5 生成脚本或 initrd 内存中的 HTTP header 值；daemon
重启、session supersede/expire/terminate 后立即失效。pre-bootstrap 保持 M2.5.1 的 15 分钟 TTL；一次成功的
boot config/answer 或受认证的 event/rootfs 请求进入 delivery 状态并将 TTL 延长为最近成功请求起 2 小时。
M4/M5 的合法阶段事件会续期；过期或旧 daemon 的 session 一律返回 `409 session_inactive`。

#### 8.1.2 `node_status` 投影

M3 新增每节点一个受 mutex 保护、单 writer 持久化的 `NodeStatus`：

```text
{ node_id, boot_session_id, daemon_instance_id, phase, last_event_at,
  last_error, last_reason, session_active }
```

它在校验 `AuthenticatedNodeSession` 和 phase transition 后更新，并按 M3.1 的独立持久化契约写入
`state/node-status.json`。status 持久化或 EventWriter 失败均不回滚已保存的投影，HTTP 返回 5xx 以允许
at-least-once 重试。daemon 重启时，历史投影保留供 `node status` 查看，但所有 `session_active` 置为 false；
旧 session 不会被重新打开，trace 继续用 `daemon_restart_gap` 表达该断点。

`boot.config.fetched` 是 M3 新增的 server-origin EventType。有效 bootstrap 不因缺少 TFTP 诊断事件而被
拒绝：它从当前 DHCP/TFTP phase 转入 `boot_config_fetched`，而 `trace` 负责将缺失的 TFTP phase 显式显示为
gap，而不是把可用性错误伪装成认证错误。

#### 8.1.3 M3.1 持久化边界与 checkpoint

M3.1 是对 M2/M2.5/M3.0 单一 `runtime.json` 持久化模型的**补充方案**，不是对这些阶段已交付行为的
追溯性完成声明。本节仅替换 M3.1 及后续版本的 runtime 持久化边界；此前章节中关于 `runtime.json` 的
描述仍适用于 legacy 文件的读取与迁移。DHCP、HTTP 与 TFTP 仍共享进程内的
`BootSession` 关联和唯一的 Event v2 writer，但不共享 runtime 快照文件或其 I/O 锁：

| 域 | 持久化事实源 | 写入策略 | 重启语义 |
| --- | --- | --- | --- |
| DHCP lease | `state/leases.json` | 专属 checkpoint worker；有未保存变更时至多每秒一次 | 丢弃已过期 lease 后恢复 |
| HTTP `node_status` | `state/node-status.json` | HTTP 状态转移后同步、原子保存 | 保留历史投影，并将 `session_active` 置为 false |
| TFTP transfer | 无 snapshot；`events.jsonl` 为审计 | 不保存 TID、block、打开文件或传输计数 | 不恢复中断传输 |
| `BootSession` | 无 snapshot；`events.jsonl` 为审计 | 仅进程内 mutex 保护 | 不恢复 session 或 capability |

TFTP 必须继续通过已 ACK lease-IP 与 `BootSession` 关联，但该关联在 daemon 重启后失效；不得为了持久化
计数或传输列表而恢复旧 TFTP session，也不得把 TFTP 纳入 DHCP 或 HTTP 的 checkpoint 锁。

DHCP 热路径完成任何实际 lease 变更（包括分配、ACK、RELEASE、DECLINE、取消 OFFER、过期回收及恢复）后只递增
单调 `lease_generation`，不得等待 JSON 序列化、文件写入、`fsync`、rename 或目录同步。checkpoint worker 是
`leases.json` 的唯一写者：它比较已保存 generation，在
`DhcpState` 的 mutex 内复制一致快照，并在锁外完成序列化和原子落盘。保存成功才推进已保存 generation；
保存期间产生的新变更必须保留为待保存状态，保存失败不得清除它。checkpoint 的节流使用单调时钟；文件的
`saved_at` 使用 UTC，仅作显示和排序。不得把 `receiveTimeout` 的空闲窗口作为唯一触发条件，因为持续
200 pps 流量可永远不出现 200ms 空闲窗口。

checkpoint worker 必须拥有 lease 文件写入的完整生命周期。停机时 coordinator 在 DHCP worker 停止后向它发送
“flush-and-stop”命令；该 worker 自己完成 final flush 并退出，coordinator 随后 join。任何其它线程在 worker
存活期间不得写 `leases.json`，不得以通用 stop 标志使其直接退出而跳过 final flush。若最终保存失败，只能记录
err 并保留未保存 generation，不得伪造成功或无限阻塞有序停机。

HTTP handler 在成功校验并更新 `node_status` 后，必须先同步保存 `node-status.json`，再追加 domain Event。
该文件使用仅属于 status 的写入锁，不得争用 DHCP checkpoint 锁。`status.persist_failed` 是 M3.1 新增的稳定
HTTP 错误码，status 保存失败时 handler 返回 503 且不追加该次 domain Event；内存中的投影可由客户端重试再次保存。
EventWriter
失败时沿用 at-least-once 语义：已保存的 status 不回滚，响应返回 5xx。重复请求必须保持 status transition
幂等，并可重试尚未写出的 Event。

两个 snapshot 文件均采用相同的单文件耐久协议：写入唯一临时文件、`fsync` 临时文件、同目录 rename、再
`fsync` 父目录。崩溃或断电后遗留临时文件是允许且预期的，启动时只能在受限 state 目录中识别和清理它们；
不得承诺 SIGKILL/断电后绝无 `.tmp` 残留。每个文件独立校验 schema、容量和内容边界，坏文件仅拒绝本域
恢复并记录 err，不得污染另一个域。

启动时优先加载新文件。某个新文件不存在时，才从旧 `runtime.json` 独立迁移该域的数据；例如
`leases.json` 已存在但 `node-status.json` 缺失时，仍必须迁移 legacy status。迁移后保留旧文件作只读备份，
不以删除旧文件作为启动成功条件。

有序停机必须先停止并 drain HTTP，再停止 DHCP/TFTP；随后要求 DHCP checkpoint worker 完成 final flush 并
退出。协议 worker 已退出后终止活动 `BootSession`、将所有 status 标记 inactive、最终保存
`node-status.json`，最后才追加 `service.stopped`。这不扩展到 SIGKILL 或进程崩溃；后者由下次启动的
`daemon_restart_gap` 表达。

### 8.2 代码任务

| 模块 | 任务 |
| --- | --- |
| `http/server.zig` | HTTP server 生命周期 |
| `http/routes.zig` | 路由表 |
| `http/static.zig` | 静态资产发送 |
| `http/range.zig` | Range / Content-Length / ETag |
| `http/auth.zig` | bootstrap/capability proof，产出 `AuthenticatedNodeSession`；不得写 Event |
| `http/contracts.zig` | BootConfig、NodeEvent、LogSummary 的有界 DTO 解析和稳定错误码 |
| `http/api.zig` | JSON API handler |
| `profile/render.zig` | 模板渲染入口 |
| `http/node_events.zig` | 节点事件/日志摘要 DTO 校验、认证结果绑定和 EventType 映射；不直接操作文件 |
| `state/node_status.zig` | `node_status` 状态机与内存投影 |
| `state/dhcp_store.zig` | `leases.json` 的 schema、原子保存/加载、legacy `runtime.json` lease 迁移 |
| `state/status_store.zig` | `node-status.json` 的 schema、原子保存/加载、legacy `runtime.json` status 迁移 |
| `state/boot_session.zig` | 活动 node/session 查询、capability 生命周期和 phase 推进；不持久化 token |
| `state/catalog_runtime.zig` | 多对象 candidate 校验、catalog 原子发布和已发布资源查询 |
| `catalog/iso_import.zig` | ISO staging、元数据检查、解包与 publication plan；不直接暴露 HTTP 路由 |
| `state/events.zig` | 复用 M2.5 唯一 JSONL writer，不新增第二个 append 路径 |

### 8.3 路由

| 路由 | 方法 | 访问条件 | 输出 |
| --- | --- | --- | --- |
| `/healthz` | GET | public | 健康状态 |
| `/boot/config/:node_id` | GET | bootstrap 或 capability proof | BootConfig v1 JSON |
| `/api/v1/nodes/:id/config` | GET | bootstrap 或 capability proof | 节点配置 JSON |
| `/api/v1/nodes/:id/answer` | GET | bootstrap 或 capability proof | 受限模板渲染文本 |
| `/api/v1/nodes/:id/events` | POST | capability proof | 受限节点阶段事件上报 |
| `/api/v1/nodes/:id/logs` | POST | capability proof | 有界失败日志摘要上报 |
| `/rootfs/:name` | GET | capability proof 且 asset 属于 session profile | rootfs 文件 |
| `/images/:name` | GET | public、catalog allowlist | ISO/image |
| `/repos/:name/*` | GET | public、catalog allowlist | repo 文件 |
| `/api/v1/management/runtime` | GET | 本机管理入口 | 本机 CLI 使用的运行态摘要 |

`/images` 与 `/repos` 只读公开是为了不把 capability 放入安装器 repo URL；它们只能解析当前 catalog 发布的
对象，不能按磁盘路径访问。节点配置、answer、rootfs、events 与 logs 均不因为 URL 中出现 node id 就获得
访问权。认证或绑定失败统一使用稳定语义：语法/未知字段为 400，缺 proof 为 401，proof 与 node/profile/asset
不符为 403，未知 allowlist 对象为 404，session 失效或非法 phase 为 409，body 过大为 413，Range 无效为 416。

#### 8.3.1 静态资源命名空间与 Range

`AssetConfig.path` 不再被解释为任意服务器路径。M3 的 resolver 按对象类型选择唯一根目录：bootloader、kernel
和两类 initrd 继续相对 `tftp.asset_root`；rootfs 与 ISO/image 相对 `http.asset_root`；repo tree 只能相对
`http.repository_root/<install-source>/`。`/rootfs/:name` 只接受 kind=`rootfs`，`/images/:name` 只接受
kind=`iso`（将来新增 image kind 前不得扩大），`/repos/:name/*` 的 `name` 必须是 catalog 中已发布的 install
source/repository。每一段 path 均拒绝空段、`.`、`..`、反斜杠、NUL 和解码后变化的分隔符；打开文件后必须
再次 `fstat`，不得跟随根目录外的 symlink。

所有 M3 大文件响应必须流式读取，不得整体读入内存；成功响应带 `Content-Length`、`Accept-Ranges: bytes` 和
以受管 SHA256 派生的强 ETag。只支持单一 `bytes=` Range（含 suffix）；合法范围返回 206 与
`Content-Range`，无效/多段范围返回 416 和 `Content-Range: bytes */<size>`。`If-Range` 与当前 ETag 相等时
才续传，否则返回完整 200。静态访问日志只记录路由模板、catalog object name、状态、字节数和耗时，不记录
repo tail、query、Authorization 或 capability。非 debug 至少记录每个 HTTP 下载请求的对象、Range、请求字节数
和 client；debug 额外记录精确的 Range chunk queue progress。当前 Zap/facil.io `sendfile` 是异步内核发送，服务端
只能诚实记录“已排队”的 chunk，不能把它伪装成对端已接收；客户端若续传会以新的 Range 请求形成下一条可观测进度。
TFTP 则在每个 ACK 后于 debug 输出约 10% 间隔的已确认字节进度，普通 info 保留 RRQ 和最终结果。

catalog 对象存在但运行期文件已丢失、变成非普通文件或逃逸受管根时，HTTP 返回 404
`http.asset_not_found`/受限 500，TFTP 返回标准 file-not-found/access-violation，并写对象名、catalog revision
和稳定 reason；不得把宿主绝对路径写入节点响应。正常每次 GET 不重新计算整文件 SHA256，而是在 publish/import
时校验并用 immutable catalog digest 生成 ETag；`asset validate --deep` 和发布前检查负责重新 hash。打开后的
size/type 与 snapshot manifest 不符时拒绝传输并标记 asset degraded，不能继续发送可能已被替换的内容。

### 8.4 ISO 自动仓库

`nodeforge install-source import <iso-path>` 接受管理员选择的任意本地常规文件。CLI 将其原子复制到
`/opt/nodeforge/work/import/<random>-<basename>` 后只传递该 basename；daemon 不接受任意绝对路径、symlink
或 URL。这样本机管理 API 即使被误暴露，也不会以服务用户权限读取任意宿主机文件，同时管理员不再需要先把 ISO
手工放入固定目录。M3 使用 Linux
内核的只读 loop mount：ISO 不需要额外提取工具，但 daemon 必须具有 `CAP_SYS_ADMIN`，并且
`nodeforged --check` 必须检查 `mount`/`umount`、私有挂载根和该 capability。导入只挂载 ISO9660/UDF，使用
`ro,nosuid,nodev,noexec,loop`；不执行 ISO 内任何文件，也不把挂载树直接暴露给 HTTP/TFTP。
随 M3.4 更新的 systemd unit 必须把 `CAP_SYS_ADMIN` 同时加入 `AmbientCapabilities` 与
`CapabilityBoundingSet`；不具备该 capability 的容器或 sandbox 不是可导入 ISO 的 NodeForge 部署目标，
而应在预检中返回稳定错误。

导入在独立且 daemon-wide 串行的 import worker 中执行，HTTP callback 不同步计算大 ISO 的 hash 或解包。为了保持
CLI 的同步成功/失败语义，发起请求的一个 HTTP worker 等待该 worker；Zap 保留第二个 HTTP worker 处理 health、下载和
节点 callback。并发导入返回 `409 install_source.busy`，不排队、不创建后台 job；DHCP/TFTP 收包线程始终不等待。
流程固定如下：

1. CLI 打开并 `fstat` 任意用户输入 ISO，确认它是普通文件后原子 stage；daemon 再以受限 root 打开 staged ISO、
   校验普通文件和 SHA256。Rocky 从 `.treeinfo`、Ubuntu 从 `.disk/info` 检测 distro/version/arch；三个 CLI flag
   是可选断言，存在时必须与检测 tuple 一致。
2. 在 `/opt/nodeforge/work/iso-import-<random>/mnt` 创建权限收紧的随机私有挂载点，以
   `mount -t iso9660 -o ro,nosuid,nodev,noexec,loop` 挂载该 ISO；只有 ISO9660 挂载失败且明确检测到
   UDF 文件系统时才以同一组选项重试 `-t udf`。遍历挂载树时拒绝不安全路径、
   不复制设备/FIFO/socket，且不得跟随根目录外的 symlink；将需要发布的仓库树复制至 sibling staging 目录，
   提取 installer kernel/initrd，并计算所有即将发布资产的 SHA256。无论后续成功、失败、SIGTERM 或 worker
   收到的 SIGINT，defer/finally 都必须先 `umount` 再删除挂载点；SIGKILL 或进程崩溃后的残留由下次启动的
   受限 cleanup 扫描处理。卸载失败使导入失败并留下受限诊断目录，绝不发布 catalog。
3. Rocky/RHEL 系必须校验 `.treeinfo` 和 `repodata/repomd.xml`；Ubuntu 必须校验 installer media，并单独检查
   `dists/`、`pool/` 与 apt 元数据是否完整。
4. 构建 publication plan：ISO/installer kernel/initrd asset、一个 `InstallSourceConfig`，以及 Ubuntu
   始终创建、RHEL 系仅在元数据完整时创建的 `RepositoryConfig`。所有名字先检查冲突，绝不覆盖已发布对象。
5. 将完成的目录移动到受管 roots（repo tree 到 `/opt/nodeforge/repos/<install-source>/`，TFTP 小启动文件到
   对应 `tftp.asset_root` 路径）。这些文件在 catalog 发布前不被 HTTP/TFTP resolver 暴露。
6. 以一个 candidate 完整校验 catalog、原子写入 catalog 文件并替换内存 snapshot；只有这一步成功后资源才
   对外可见。任一前置步骤失败不得发布 catalog；清理失败只留下不可访问的 work orphan，并记录服务 err。

导入可靠性补丁（M3 归属，列入 M4.1 验收前置）：

- staging 开始前根据输入 ISO、媒体树统计/保守上界、最终 ISO/repo/kernel/initrd 副本和安全余量计算
  `required_bytes`，并分别检查 staging filesystem 与最终各 asset root。不能使用“ISO size + 10%”固定公式，
  因为当前流程会同时保留输入、staged repo 和发布副本，且不同 root 可能属于不同 filesystem。
- 每个 `work/iso-import-*` 写 owner manifest（daemon instance、PID、start time、phase），并受 daemon singleton/
  import lock 管理。启动清理只处理合法命名、owner 已死亡且不在当前 mount table 的 orphan；若仍有 NodeForge
  私有只读 mount，则先安全卸载。不能仅凭 mtime 或“早于本次启动 60 秒”删除目录。
- ENOSPC、复制中断、mount/umount 失败和 catalog commit 失败都按同一 publication 边界回滚未发布目标；跨
  filesystem 已移动但尚未进入 catalog 的文件进入 orphan reconciliation，不得由 resolver 访问。

跨根目录的文件 rename 不能提供文件系统级单事务，因此“对节点原子”以 catalog publication 为边界：路由永远
先查当前 snapshot，再打开文件。ISO 中通过元数据校验的仓库是默认基础源，用户可以追加 mirror/额外源。GPG
检查默认关闭，仅在 repository 明确 `gpg_check = true` 时启用。Ubuntu ISO 导入时始终将
ISO 内容复制到 `/repos/<source>/` 并创建 `RepositoryConfig` 条目，即使 ISO 不含完整
APT metadata。默认 `install.apt.fallback=offline-install` 时，隔离 PXE 网段中
`apt-get update` 失败后 Subiquity 切换到离线安装；配置为 `abort` 时则立即失败，
用于验证本地 HTTP mirror 的完整性。操作员仍可通过显式配置外部
`repository.base_url` 来提供完整 APT 源。

### 8.5 boot config

所有 boot config 使用 `schema_version = 1`，由 `AuthenticatedNodeSession` 与已验证的 profile/catalog snapshot
构造。响应中共同字段为 `node_id`、`boot_session_id`、`profile`、`mode`、`config_url`、`event_url` 和 `access`；
不能从请求 body 复制这些字段。`access` 仅在此受认证响应中包含 session id 与 capability token，客户端必须把
它转为 header，不能拼回 URL。

diskless boot config 示例：

```json
{
  "schema_version": 1,
  "node_id": "node-02",
  "boot_session_id": "0123456789abcdef0123456789abcdef",
  "mode": "diskless",
  "profile": "rocky-9.7-aarch64-diskless",
  "config_url": "http://192.168.50.1:8080/api/v1/nodes/node-02/config",
  "rootfs_url": "http://192.168.50.1:8080/rootfs/rocky-9.7-aarch64-<kernel-release>.squashfs",
  "rootfs_sha256": "...",
  "rootfs_mode": "squashfs_overlay",
  "overlay": {
    "tmpfs_size": "50%",
    "tmpfs_mode": "0755"
  },
  "event_url": "http://192.168.50.1:8080/api/v1/nodes/node-02/events",
  "access": {
    "session_header": "X-NodeForge-Session",
    "session_id": "0123456789abcdef0123456789abcdef",
    "authorization_header": "Authorization",
    "bearer_token": "<opaque 256-bit token>"
  }
}
```

install mode 的同一对象改为包含 `answer_url`、已发布的 `repository_urls` 与 installer source 元数据；不在
BootConfig 内嵌 answer file、repo 元数据或完整模板。`/api/v1/nodes/:id/answer` 使用 bootstrap proof 兼容
`inst.ks=` 和 NoCloud-Net 这类不能附加 header 的安装器 URL；renderer 仅在输出内容中提供
`nodeforge_boot_session_id`、`nodeforge_access_token`、`nodeforge_event_url` 三个只读变量，供 M4 的
hook/late-command 使用 header 上报。answer 内容、token 和渲染变量不得进入日志、Event 或错误响应。

M3 内置一个纯文本 bootstrap answer fixture，只含上述三个只读变量，明确不是可安装的
Kickstart/Autoinstall；它让 transport、peer proof 与 capability 交付可独立验收。M4 的 distro adapter
才决定 Kickstart/Autoinstall 字段与语义，并替换该 fixture。M3 不执行 shell、表达式、文件 include 或任意
用户模板路径。每次成功签发 boot config 先更新 phase/status，再写 `boot.config.fetched` Event；EventWriter
失败返回 5xx，但不回滚已经更新的状态。

### 8.6 节点事件与日志摘要接收

M3 不接受客户端提交完整 Event JSON，也不让客户端指定 `ts`、`node_id`、`source`、`type` 或任意 fields。
`POST /events` 的唯一 DTO 为：

```json
{
  "v": 1,
  "boot_session_id": "0123456789abcdef0123456789abcdef",
  "stage": "rootfs_verified",
  "reason": "optional.stable_reason",
  "message": "optional safe summary"
}
```

`v` 必须为 1；`boot_session_id` 同时必须与 capability proof 匹配；`stage` 只能是服务端按 profile mode
允许的闭枚举。install 允许 `installer_started`、`config_fetched`、`started`、`partitioning`、`packages`、
`bootloader`、`post`、`rebooting`、`completed`、`failed`，并映射为 `install.*`；diskless 允许
`initrd_started`、`rootfs_download_started`、`rootfs_verified`、`rootfs_mounted`、`switch_root`、`running`、
`failed`，并映射为 `diskless.*`。handler 从认证结果固定 `source=installer|initrd`、`node_id`、session 和
服务端时间，再按固定表选择 EventType；节点不能伪造 `dhcp.*`、`tftp.*`、`http.request`、`service.*` 或其他
server-origin 类型。`reason` 是至多 128 bytes 的稳定 machine code，`message` 至多 1024 bytes 且必须为单行
安全摘要；未知 key 一律 400。

`/logs` 的 DTO 仅为 `{ "v": 1, "boot_session_id": "...", "reason": "...", "summary": "..." }`。body
最大 4 KiB，服务端将 summary 截断到 2048 bytes，并依认证 mode 映射为 `install.failed`、`diskless.failed`
或未来已注册的 `provision.step.failed`；禁止上传完整 installer log、shell stdout/stderr、token、cookie 或
任意文件。原始日志由节点本地保存，NodeForge 只保留安全的可查询摘要。body 超限、非法 stage/reason、未知
field 或认证失败返回明确 4xx/409，且不会写 domain Event。

写入顺序固定为：验证 capability、URL node 与活动 session -> 校验 mode/stage transition -> 原子更新
`node_status`/BootSession -> 同步保存 `node-status.json` -> 追加 domain Event -> 返回响应。status 保存失败时返回
`503 status.persist_failed`，不追加该次 domain Event；内存投影不回滚，调用方重试会再次尝试保存。EventWriter
失败时状态更新和已保存投影不回滚，响应返回 5xx 并记录服务 err，调用方可以重试；M3 的上报语义是
at-least-once，重复 domain event 可出现，但 `node_status` transition 必须幂等。跨请求事件去重需要持久化
event id，超出 M3，不得以猜测 message 相同来去重。同一次 POST 无论成功或失败都各自产生一条服务侧
`http.request`，但它不替代 domain Event。

### 8.7 CLI 命令

```bash
nodeforge runtime status
nodeforge events list --node node-01
nodeforge events follow --type install.failed
nodeforge node status node-01
nodeforge install-source import /srv/iso/Rocky-9.7-aarch64-dvd.iso
nodeforge install-source import /srv/iso/ubuntu-22.04.5-live-server-arm64.iso --distro ubuntu --version 22.04 --arch aarch64
nodeforge repository show rocky-9.7-aarch64-iso
```

`install-source import` 接受任意可读本地 ISO 路径（绝对或相对当前目录）。CLI 先验证它是普通文件，原子复制到
`/opt/nodeforge/work/import/<random>-<basename>`，仅把这个受管 basename 交给本机 daemon；导入请求结束后删除临时
copy，绝不移动或删除原始 ISO。这样既不把任意主机路径授权给常驻 daemon，又不把管理员的工作流限制在固定目录。

`--distro`、`--version`、`--arch` 均改为可选的**断言**：Rocky 从 `.treeinfo`，Ubuntu 从 `.disk/info`
和 ISO 架构元数据检测 tuple；任一显式值与检测结果不一致即拒绝。Rocky `arch` 采用 `aarch64`/`x86_64`，Ubuntu
媒体的 `arm64`/`amd64` 在导入器中规范化到相同模型值；Ubuntu `22.04.5` 规范化为 profile/catalog 使用的 `22.04`。
这三个 flag 不再是重复、容易填错的必填元数据。

`asset import --path` 仍刻意是相对于 `tftp.asset_root` 的 catalog 注册路径，而不是“导入任意文件”的 CLI；它不会复制
数据且 daemon 需要在固定 root 内计算 digest。`config import <path>` 本来就接受任意源 JSON 路径。因此 M3.6 审计后，
只有 `install-source import` 存在把用户输入误当作固定 staging basename 的问题。

`nodeforge install render` 归 M4，因为只有该阶段拥有发行版 adapter；M3 只提供它所依赖的 `/answer` transport、模板
安全边界和认证上下文。

### 8.8 并发与 HTTP 实现选择

- HTTP 服务器基于 Zap/facil.io 固定提交实现。Zap 负责 HTTP 报文解析、连接生命周期、并发调度和 fd-backed sendfile；M3 已接入受管静态资产和 Range 路由，在向发送路径交付已验证 descriptor 前自行解析单 Range/`If-Range`、设置 SHA256 ETag，并拒绝多段/无效 Range。这样不依赖 facil.io 的文件时间/长度 ETag 或其 `If-Range` 行为。NodeForge 维护业务路由、管理 API 和统一错误信封，不维护 HTTP 报文解析或连接循环。已评估的备选方案 `http.zig`（karlseguin）在 Zig 0.16 上尚未充分测试且不承诺完整 HTTP/1.1 合规，不作为依赖。
- acceptor 与固定大小 worker pool 分离；大文件使用 `pread`/send loop 流式发送，不整体读入内存。
- DHCP/TFTP 使用各自 UDP event loop；ISO hash、只读挂载/复制和 publication plan 提交到一个受限 import worker，
  不阻塞收包；同步等待 import 的管理 handler 最多占用一个 HTTP worker，第二个 worker 仍服务 HTTP 数据面。静态下载
  持有已打开 fd，不在整个传输期间占 catalog mutex。
- 配置使用不可变 snapshot + 原子替换；catalog 仅在 candidate 通过完整校验和原子落盘后替换。M3.1 的
  `leases.json` 与 `node-status.json` 按恢复域分别保存：DHCP checkpoint worker 最多每秒一次且不阻塞收包，
  HTTP status 转移同步保存且不争 DHCP I/O 锁；有序 shutdown 分别补写最终快照。Event v2 则通过 M2.5 的唯一
  mutex 逐条追加和轮转，不再引入独立队列或第二个文件后端。
- MVP 验收基线：并发 100 个 HTTP Range 下载、100 个 TFTP session 和每秒 200 个 DHCP 报文时无崩溃、无状态串扰；具体吞吐在目标 ARM VM 和 x86_64 机器记录，不先承诺生产数字。

请求在 catalog snapshot 下解析并打开 fd 后立即释放 snapshot 锁；进行中的传输持有已打开 fd 和解析时的
object revision/ETag，新 publication 只影响后续请求。已发布对象使用不可变版本路径且 import NoClobber，
不允许在原路径覆盖。HTTP `max_connections`、per-client 限流和 TFTP 有界 worker 属于 M6 生产压测后的容量
策略；M3/M4.1 先保证固定 worker、fd/连接/请求体上限和过载时明确 429/503，不先加入未经验证的可调参数。

### 8.9 测试

- `/healthz` 返回 OK。
- bootstrap proof 只接受 active lease 的直连 peer，node/IP/session 错配、daemon 重启、过期/superseded session
  均返回 409 且不更新 `node_status`；capability 缺失、错误、泄露到 query 或跨 node 使用均被拒绝。
- rootfs 的未认证/跨 profile 请求返回 401/403；images/repos 只可读取 catalog allowlist，目录穿越、symlink、
  不存在 asset 和未发布 staging 文件均不可读。
- Range 下载返回 206；覆盖 suffix Range、`If-Range` 命中/不命中、无效/多段 Range 的 416、连接中断后的
  `Range` 续传、ETag 与 Content-Length。
- BootConfig v1 fixture 验证 node/profile/session/rootfs/repo 字段；answer 渲染返回文本且 token/answer body
  不进入 HTTP event、服务日志或错误响应。
- POST 合法节点 event DTO 后更新 runtime 并写入受限 Event v2；伪造 server type、node_id、source、
  超长 body/summary、非法 stage/reason 或未知 field 都返回 4xx 且不写文件。
- POST 日志摘要只保留有界失败摘要，不能把完整 installer/initrd log 写入 JSONL 或服务日志。
- runtime summary 与事件同步；EventWriter 写入失败时状态不回滚、请求返回 5xx 且可幂等重试；daemon restart
  后保留的 status 不接受旧 session。
- 持续 200 DHCP pps、期间不出现 200ms 空闲窗口时，正常完成的 lease checkpoint 最多每秒一次；注入慢或失败的
  `fsync` 不得阻塞 DHCP 收包，也不得错误推进已保存 generation。单次 `fsync` 长于 checkpoint 间隔时不承诺
  实际每秒完成一次保存，但必须保持单写者、顺序保存和可重试性。
- HTTP status 保存与 DHCP checkpoint 互不等待；status 保存失败返回 `503 status.persist_failed` 且不追加
  domain Event。覆盖两个新文件的独立恢复、legacy `runtime.json` 的部分迁移、父目录同步和有序停机最终状态。
- 使用 Rocky 与 Ubuntu ISO fixture 验证无 `CAP_SYS_ADMIN`、`mount`/`umount` 缺失、挂载失败、卸载失败、损坏 ISO、
  tuple/metadata 不匹配、repo 元数据完整/缺失、candidate 发布失败和名字冲突均不改变 catalog；成功导入后 repo
  与 installer assets 同时可解析。另以独立 mount namespace 验证导入完成后没有残留 loop device 或挂载点。

#### 测试前清理约定

在目标机执行 `zig build test` 或手动集成测试之前，必须清理上一次运行残留的日志、事件和
状态文件，否则会导致断言误判：

- 停止正在运行的 daemon（`systemctl stop nodeforged`），释放 UDP/67、UDP/69 和 HTTP 端口。
- 删除 `/opt/nodeforge/logs/` 下的 `nodeforged.log`、`events.jsonl` 及轮转文件——残留事件
  会导致 `events list` 空列表断言失败，残留日志会导致 `grep` 匹配到非本次运行的行。
- 删除 `/opt/nodeforge/state/` 下的 `leases.json`、`node-status.json`、`runtime.json`（legacy）
  和 `*.tmp`——残留状态会影响 legacy 迁移和崩溃恢复测试的起始条件。
- 如需干净 catalog 回归，额外删除 `/opt/nodeforge/catalog/catalog.json` 和
  `/opt/nodeforge/work/iso-import-*` 工作目录。
- `tests/http.sh` 和 `tests/cli.sh` 已各自使用独立临时目录（`$tmp`）和 `--events-path` 隔离，
  但手动验证仍需遵守上述清理步骤。`build.zig` 已强制 `http_tests` 和 `cli_tests` 串行执行
  以避免端口冲突。

### 8.10 阶段验收

- 已认领节点能从活动 session 获取 BootConfig/answer；session、token、URL node 或 peer IP 任一不匹配均不能读写。
- 合法节点事件能按 Event v2 写入 `events.jsonl` 并更新持久 `node_status`，非法 body 或旧 session 不会污染审计文件。
- rootfs/ISO/repo 大文件下载支持 `Content-Length`、ETag、单 Range 和 `If-Range`，全程受 catalog 路径沙箱限制。
- ISO 导入后无需手工建基础 repo 即可通过 HTTP 安装；导入失败不会发布半个 catalog 或可访问的半成品。
- 在 `r97n0` 完成真实 Rocky 9.7 aarch64 ISO 导入、Range/续传、节点 config/answer 和 capability 上报验证，并记录
  100 HTTP Range、100 TFTP、200 DHCP 报文/秒并发基线。
- `runtime.json` 拆分为 `leases.json` + `node-status.json`，独立 I/O 锁、legacy 迁移和崩溃恢复通过验证；
  `zig build test` 全量回归通过。

### 8.11 实施顺序与文档同步

M3 按以下批次实施，前一批的 contract test 必须通过后才能进入下一批；不得以能返回 200 的临时路由跳过
认证、catalog 或 Event 约束：

1. **M3.0 contract fixture**：固定 BootConfig v1、`AuthenticatedNodeSession`、capability header、NodeEvent/
   LogSummary DTO、错误码、`boot.config.fetched` registry 与 `node_status` phase table；先为合法/非法 JSON 和
   session 组合建立 fixture。
2. **M3.1 state/auth（补充方案）**：扩展 `BootSession`、实现 capability 生命周期及独立持久化边界：DHCP generation
   checkpoint 到 `leases.json`、checkpoint worker 的 flush-and-stop/join、HTTP 同步保存 `node-status.json`、
   `503 status.persist_failed` contract fixture、legacy `runtime.json` 的独立迁移和有序 shutdown final flush；将
   HTTP context 接入 session/status store，验证 lease/node/peer、token、过期、supersede、daemon restart、持续
   200 pps 与慢/失败持久化。
3. **M3.2 static/Range**：完成 catalog resolver、路径沙箱、fd 流式读取、ETag/Range/If-Range；先完成风险表中的
   独立 Range spike，再接入唯一 HTTP listener。
4. **M3.3 node API**：实现 boot config、config、answer、events、logs 和 runtime summary，所有 domain event 都走
   M2.5 Writer；此批只交付受控 answer fixture，不实现 M4/M5 adapter。
5. **M3.4 ISO publication**：实现 staging/import worker、受控只读 loop mount、Rocky/Ubuntu 元数据分支和 catalog
   多对象原子 publication，再开放 `install-source import`/`repository show`。
6. **M3.5 integration**：合并 HTTP、ISO、DHCP/TFTP 并发测试；在 `r97n0` 用真实 ISO 与已认领 node 验证所有
   M3 验收项，并把实际命令、hash、并发结果与未覆盖的限制同步到验证记录。

任何批次改变路由、DTO、认证材料、EventType、catalog 字段或 M4/M5 消费内容时，先更新本节、§7.5.12、
`DESIGN.md` 的 HTTP 边界和相应 fixture；实现与文档不得分别演进。

### 8.12 M3.5 TFTP 虚拟 GRUB 配置补全

M3.5 实机验证发现 PXE 链路在 GRUB 获取配置处中断：TFTP 只能提供 catalog 静态资产，
无法按节点身份动态生成 `grub.cfg`，导致 GRUB 拿不到 kernel/initrd 路径。同时发现
`grub.zig` 硬编码 `linuxefi`/`initrdefi` 指令，ARM64 `grubaa64.efi` 不含这两个模块
导致指令不可用。本节记录补全方案。

#### 8.12.1 问题根因

1. **`grub.cfg` 从未被 TFTP 提供**：`grub.zig` 的渲染器存在但无调用方。TFTP handler
   的 `transfer` 函数只检查 catalog manifest 白名单，虚拟配置请求被当作不存在的文件拒绝。
2. **ARM64 GRUB 指令不兼容**：`linuxefi`/`initrdefi` 是 RHEL 补丁 GRUB 的扩展指令，
   ARM64 上游 GRUB 只支持 `linux`/`initrd`。x86_64 上游 GRUB 同样默认支持 `linux`/
   `initrd`，`linuxefi`/`initrdefi` 可用性取决于发行版构建。
3. **TFTP 缺少身份解析**：TFTP handler 只有 `associateTftp`（用于 session 关联审计），
   无法从 Peer IP 获取 node_id/profile/mode 来渲染个性化配置。

#### 8.12.2 补全实现

| 模块 | 变更 |
| --- | --- |
| `boot/grub.zig` | `linuxefi`/`initrdefi` 改为 `linux`/`initrd`；`timeout` 保持 5（PXE 菜单可见，便于调试） |
| `boot/target.zig` | **新增**。从 `TftpBootIdentity` + `AppConfig` + `Catalog` 展开 `BootTarget`（kernel_path, initrd_path, cmdline, arch） |
| `state/boot_session.zig` | 新增 `TftpBootIdentity` 结构体和 `resolveTftpBoot` 方法（只读，返回值副本，锁内不 I/O） |
| `tftp/server.zig` | 新增 `isVirtualGrubConfig` 文件名匹配 + `transferVirtualConfig` 内存渲染传输；在 `transfer` 调用前拦截 |

#### 8.12.3 虚拟配置拦截流程

```
TFTP RRQ 到达
  │
  ├─ isVirtualGrubConfig(filename)?  ──否──→  transfer (catalog manifest gate)
  │
  是
  │
  ├─ resolveTftpBoot(peer_ip)  ──null──→  ERROR code 2 (active DHCP lease required)
  │
  ├─ boot_target.resolve(identity, config, catalog)  ──null──→  ERROR code 2 (boot target unavailable)
  │
  ├─ grub.render(target) → config_buf[2048]
  │
  └─ transferFromMemory(config_buf)  →  OACK/DATA/ACK
```

#### 8.12.4 安全约束

- 虚拟配置只在 Peer IP 有唯一已 ACK lease 时渲染；零个或多个匹配均以 TFTP ERROR code 2 拒绝。
- `discovery` mode 返回 null（不渲染 kernel/initrd），未认领节点拿不到配置，并以 ERROR code 2 表达策略拒绝。
- 配置文本不含 `boot_session_id` 或 capability token；这些只通过 HTTP 认证通道下发。
- `cmdline` 不携带 `inst.ks=`（M4 Kickstart 渲染后追加）或 NoCloud URL（M4 Ubuntu 后追加）。
- RHEL-family M3 install cmdline 为 `ip=dhcp rd.neednet=1 inst.repo=<repository_url>`；Ubuntu live-server
  为 `root=/dev/ram0 ramdisk_size=1500000 ip=dhcp url=<published ISO URL>`。
  `inst.repo` 不传给 Ubuntu；M4 追加 `autoinstall ds=nocloud-net;...`。
  M3 曾使用 `cloud-config-url=/dev/null` 阻止 cloud-init 拉取配置，M4 移除该参数，避免与 NoCloud-Net 同时声明输入——
  它与 NoCloud-Net 冲突：NoCloud-Net 首次失败时 cloud-init 回退到 CmdLine 读取空配置，
  导致 Subiquity 永远等不到 autoinstall 数据（"waiting for cloud-init"）。
- M3 diskless cmdline 只包含 `ip=dhcp nodeforge.config=<config_url>`。
- 文件名匹配严格限定长度和字符集：MAC 形式固定 33 字符，IP 形式固定 8 位十六进制。

#### 8.12.5 验收状态

| 验收项 | 状态 | 说明 |
| --- | --- | --- |
| `grub.zig` 使用 `linux`/`initrd` 指令 | ✅ 已实现 | 单元测试验证两种架构均不含 `linuxefi` |
| `boot/target.zig` 解析 install/diskless target | ✅ 已实现 | 单元测试覆盖 install/diskless/discovery 三种 mode |
| `boot_session.resolveTftpBoot` 只读身份解析 | ✅ 已实现 | 单元测试覆盖正常/ambiguous/无 node_id 场景 |
| TFTP 虚拟 `grub.cfg` 拦截与内存传输 | ✅ 已实现 | 单元测试覆盖文件名匹配规则 |
| GRUB 可拉取配置 | ✅ 已实机验证 | 2026-07-12 在 r97n0/VMware PXE 完成，见验证记录 |
| GRUB 可拉取 kernel/initrd | ✅ 已实机验证 | 2026-07-12 完成 DHCP→TFTP→GRUB→kernel/initrd→installer 链路 |

### 8.13 M3.6: GRUB policy、ISO import 与下载可观测性修正

M3.6 收敛 M3.5 代码审计发现的六项契约问题：动态 GRUB 错误语义、ISO 生命周期、任意 ISO 路径、tuple
自动检测、下载进度和 Ubuntu casper 参数。它不改变 catalog 的受管根目录或 daemon-only publication 边界。

| 问题 | M3.6 决策与实现 |
| --- | --- |
| 无 DHCP session 请求虚拟 `grub.cfg` | 这是 authorization/policy rejection，不是文件缺失；严格匹配的虚拟名字返回 TFTP ERROR code 2（access violation），无关静态路径才继续返回 code 1。MAC/IP 名称同时校验格式及大小写，允许 GRUB 常见的单个前导 `/`。 |
| ISO CLI 强制 `/opt/nodeforge/work/import/` basename | CLI 现在接受任意本地普通 ISO 路径，临时 stage 到受管目录后向 daemon 仅传 opaque basename，完成后清除临时 copy。既改善 UX，又不把任意 host path 交给常驻特权服务。 |
| 重复输入 distro/version/arch | 三个 flag 改为可选一致性断言；Rocky 以 `.treeinfo`，Ubuntu 以 `.disk/info` 和 ISO metadata 检测并规范化 tuple。 |
| Ubuntu install cmdline | `inst.repo` 只供 Anaconda/RHEL；Ubuntu live-server 由 casper 下载 ISO，使用 `root=/dev/ram0 ramdisk_size=1500000 ip=dhcp url=http://<server>:<port>/images/<iso-asset>`。不加入旧式 `boot=casper netboot=url`：Canonical 当前 UEFI netboot 文档（涵盖 20.04+）以 `url=` 作为 live ISO 定位参数；M4 再附加 autoinstall NoCloud 参数。M3 的 `cloud-config-url=/dev/null` 已移除，以免和 NoCloud-Net 同时声明输入；它不是“waiting for cloud-init”的充分证据，必须结合 NoCloud 请求和 cloud-init 日志区分网络、answer YAML 与 datasource 问题。 |
| HTTP/TFTP 下载日志 | HTTP 的每个请求和 Range 在 info 记录对象、范围、字节数、client；debug 记录已排队的 Range chunk。TFTP info 记录 RRQ/完成/失败，debug 在 ACK 后按 10% 记录确认进度；重传仍为 warn。 |
| 管理 API 的权限边界 | `/api/v1/management/` 能写 catalog、触发 loop mount，故虽与 PXE HTTP 共用 listener，仍只接受 direct peer `127.0.0.1`；远端请求 403，不能通过 `X-Forwarded-For` 伪造。CLI 也没有远程 endpoint。 |
| profile/source/bundle 关联 | config 校验现在要求 install profile 与 `InstallSourceConfig`、diskless profile 与 `BootBundleConfig` 的 distro/version/arch 三元组完全相同；install profile 还必须显式标记 `destructive=true` 与 `persistent_writes=true`。这拒绝“Ubuntu profile 引 Rocky source”或未声明持久写入的配置。 |
| DHCP 架构一致性 | 已登记节点的 RFC 4578 PXE 架构必须与 node/profile arch 相同；不一致仍可完成 DHCP 诊断 lease，但不下发 GRUB bootfile，防止跨架构 loader 再加载错误内核。 |
| Ubuntu live 介质完整性 | 除 `.disk/info`、`casper/vmlinuz` 与 `casper/initrd` 外，导入还必须存在 `casper/filesystem.squashfs`，避免发布一个能下载 kernel 却无法进入 live installer 的 ISO。 |
| loop mount 隔离 | systemd unit 启用 `PrivateMounts=true`；结合 `CAP_SYS_ADMIN`、只读挂载和 worker cleanup，ISO mount 不进入 host mount namespace。 |

ISO 导入从用户路径到发布的完整责任链是：`CLI fstat → atomic staging copy → daemon constrained open/hash → readonly loop mount → distro detection/optional assertion → kernel/initrd/repo staging → checksums → catalog candidate validation + atomic replacement → stage cleanup`。catalog 是对 HTTP/TFTP 可见性的唯一提交点；任何未发布文件都不能经 resolver 访问。导入不会实现后台 job：CLI 等待本地 daemon 的有界 worker 结果。

#### 8.13.1 Rocky 9.7 / Ubuntu 22.04 的 M3.6 实际启用顺序

1. 在 PXE 服务机安装 NodeForge，并让 `server.server_ip` 已配置在 `bind_interface` 上；systemd unit 以
   `CAP_NET_BIND_SERVICE`、`CAP_NET_RAW`、`CAP_SYS_ADMIN` 与 `PrivateMounts=true` 启动。先运行
   `nodeforged --check`，它会检查 HTTP/DHCP/TFTP bind、mount/umount 和 capability。
2. 先使用**不引用 install source** 的基础 config 启动 daemon（例如只有 distro matrix、DHCP 和
   `policy.default_action=wait`）。这是必要顺序：config/catalog 在 daemon 启动时整体校验，尚不存在的 source
   不能被 profile 提前引用。
3. 通过本机 CLI 导入媒体：

   ```bash
   nodeforge install-source import /srv/iso/Rocky-9.7-aarch64-dvd.iso
   nodeforge install-source import /srv/iso/ubuntu-22.04.5-live-server-arm64.iso
   ```

   Rocky 自动发现 `.treeinfo` 的 `rocky/9.7/aarch64`、提取 `images/pxeboot/*` 并发布 DNF repo；Ubuntu 自动发现
   `ubuntu/22.04/aarch64`、提取 `casper/*`、校验 squashfs，并发布 ISO URL；Ubuntu 无论 APT metadata
   是否完整都发布 `/repos/<source>/` 并创建 `RepositoryConfig`，完整性决定 apt 可用性和 fallback 结果，
   不决定 catalog 是否存在该 repository。
4. 停止 daemon，使用 `config import` 写入与已发布 source 三元组完全一致的 install profiles 和 nodes，然后执行
   `config validate -c <config> -C <catalog>` 并重启 daemon。此时管理 API 仍只能从服务机本机访问，PXE 节点只访问
   TFTP、`/images` 和 `/repos`。
5. 已登记 ARM64 节点以 RFC 4578 aarch64 发起 DHCP：收到 `grubaa64.efi`、唯一 ACK session，再由 GRUB 拉取虚拟
   `efi/grub.cfg-*`、installer kernel/initrd。Rocky cmdline 使用 `inst.repo=<published DNF URL>`；Ubuntu cmdline
   使用 `url=<published ISO URL>`。架构、profile/source tuple、租约或策略任一不满足时，链路在对应边界停止且给出
   明确日志/协议错误。
6. 该阶段的终点是**进入 installer**。M3.6 尚未渲染 Rocky Kickstart 或 Ubuntu autoinstall NoCloud；因此不能把
   当前状态称作“无人值守安装完成”。它们由 M4 增加，届时分别追加 `inst.ks=` 与
   `autoinstall ds=nocloud-net;s=...`。

Ubuntu 参数判断以 Canonical 的 [UEFI PXE netboot 指引](https://documentation.ubuntu.com/server/how-to/installation/netboot-the-server-installer-via-uefi-pxe-on-arm-aarch64-arm64-and-x86-64-amd64/index.html) 和更新的 [amd64 netboot 指引](https://documentation.ubuntu.com/server/how-to/installation/how-to-netboot-the-server-installer-on-amd64/) 为准；两者都描述 initrd 从 `url=` 下载并挂载 live ISO。该结论是文档核验后的实现选择，不以 ISO 文件名或过时博客示例猜测。

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
- `InstallConfig.apt.fallback`
- packages/users/files/hooks
- node hostname/profile vars；M4 仅沿用 PXE DHCP 结果，不承诺安装后静态网络
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

M4 的设计意图是：提供 `users.password = "asdf1234"` 时，Ubuntu adapter 在内存中生成安装器接受的
password hash，配置文件和 NodeForge 数据模型仍直接保存明文。但当前实现实际生成裸 SHA-256 hex，
不符合 `passwd(1)` crypt 格式；该项不能视为 M4 已完成，统一由 M4.1 改为 SHA-512 crypt `$6$`。同理，
Kickstart 当前 answer 携带明文且缺 rootpw，M4.1 改为 runtime `$6$` + `--iscrypted`，不改变 config 明文事实源。

本节的 locale/timezone、普通用户和 SSH 行为只代表 M4 跑通安装主链路时的临时基线，不是最终目标系统
配置面。默认 root 登录、`asdf1234`、防火墙/SELinux、local-only 和目标静态网络由 M4.1 统一定义并覆盖
两种 adapter；M4 不得被引用为这些能力已经完成的依据。

实现策略：

- 使用 Ubuntu Installer/Subiquity 的 `autoinstall`，不实现 preseed。
- NodeForge HTTP 输出 cloud-init NoCloud-Net 数据源：`user-data` 和 `meta-data`。
- PXE cmdline 追加 `autoinstall ds=nocloud-net;s={{answer_base_url}}/`。
- `user-data` 顶层包含 `autoinstall.version = 1`。
- autoinstall 字段名和枚举值严格遵循 Subiquity 官方 `autoinstall-schema.json`
  （`canonical/subiquity` 仓库根目录）。曾在隔离 PXE 验证中引发故障的字段
  详见 §9.3.1。
- cloud-config 顶层键（`ntp`、`package_update`、`package_upgrade`）是 cloud-init
  自身模块读取的配置，不在 `autoinstall:` 段内。它们与 Subiquity autoinstall
  schema 无关，但同样是隔离网段防超时策略的必要组成部分。
- 版本能力表和首个 fixture 先覆盖 22.04 LTS；后续 LTS 在 M6 按实际发布版本增加。

#### 9.3.1 Ubuntu PXE 验证中的根因与防护

2026-07-12 ~ 2026-07-13 的 VMware Fusion aarch64 实机验证暴露了六个相互独立的问题；它们必须作为
Ubuntu PXE 回归用例保留，不能仅以“能下载 kernel/initrd”判定通过。第 1-3 项是 NoCloud/GRUB
层面的问题，第 4-5 项是 Subiquity autoinstall schema 层面的问题（字段名或枚举值不合法），
第 6 项是 cloud-init 顶层键与 autoinstall 段的层级区分问题：

1. **GRUB 与 NoCloud 分号**：`ds=nocloud-net;s=<url>` 中未转义的 `;` 会被 GRUB 当作
   配置命令分隔符。内核只能得到不含 URL 的 datasource 参数，cloud-init 不会读取 answer。
   生成的 GRUB 文本必须使用 `ds=nocloud-net\\;s=<url>`；反斜杠仅由 GRUB 消耗，内核仍收到
   NoCloud 规定的分号。
2. **Autoinstall YAML 标量**：`late-commands` 含 shell 引号、JSON 的 `Content-Type: ...` 及
   冒号时，不能作为 YAML plain scalar 输出。解析失败后 cloud-init 虽成功下载 `user-data`，
   Subiquity 仍会退回语言选择页。每条命令必须通过 YAML 单引号标量转义后输出，并以 YAML
   parser 验证渲染结果。
3. **NoCloud vendor-data**：NoCloud 会读取 `meta-data`、`user-data` 和 `vendor-data`。后者即使
   为空也必须返回 HTTP 200；404 会触发 cloud-init 重试，增加约十秒无效等待。
4. **离线 APT**：Ubuntu 的 `packages` 在 `late-commands` 前由 Subiquity/curtin 安装。若 answer
   未设置 `autoinstall.apt.mirror-selection.primary`，安装器会默认访问 `archive.ubuntu.com`。PXE 隔离网段通常没有
   NAT/DNS，表现为 `Mirror/cmd-apt-config` 后长期无新输出。NodeForge 的修复策略：
   - **Ubuntu ISO 导入时始终发布 repo 内容**：即使 ISO 不含完整 APT metadata（`dists/pool/Release`），
     也始终将 ISO 内容复制到 `/repos/<source>/` 并创建 `RepositoryConfig` 条目。这使得
     `apt.mirror-selection.primary` 始终有一个本地 URL 可用。
   - **user-data 中始终渲染 `apt` 段**：只在 `mirror-selection.primary` 中列出 NodeForge
     发布的 `/repos/<source>/` URL，关闭 geoip，并从 profile 的 `install.apt.fallback` 渲染失败策略。
     Jammy ARM64 不能使用
     legacy `arches: [default]`，否则 Subiquity 会忽略本地候选并访问 `ports.ubuntu.com`。
     live-server ISO 只包含 `jammy` suite，不含 `jammy-updates`/`jammy-security`/`jammy-backports`；
     Subiquity 默认配置所有 suite，`apt-get update` 可能因 404 返回非零。默认
     `fallback: offline-install` 会切换到 squashfs；严格 HTTP APT 验收 profile 必须配置
     `fallback: abort`，让 mirror 不可用成为明确失败，不能用安装完成掩盖仓库问题。
   - **Fallback URL**：当 repository 条目不存在时（手动配置场景），`answerFixture` 和
     CLI 预览会构造 `http://<server>:<port>/repos/<source_name>/` 作为 fallback URL。
   - 操作员可通过显式配置外部 `repository.base_url` 来提供完整 APT 源。
   - **配置入口**：事实源使用 `profile.install.apt.fallback`，合法 JSON 值为 `abort`、
     `offline-install`、`continue-anyway`。MVP 不新增在线 `profile update` 管理命令；操作员修改
     配置文件后执行 `nodeforge config import <path>`、`nodeforge config validate`，再重启
     `nodeforged`。`config export` 必须保留连字符枚举值。
5. **cloud-init / Subiquity 网络超时**：即使 APT 源已修复，cloud-init 和 Subiquity 仍有多处
   隐含的外网访问，在隔离网段表现为 `waiting for cloud-init`。NodeForge 在 user-data 中添加以下防护
   （字段名经 Subiquity 官方 `autoinstall-schema.json` 确认）：
   - **`autoinstall.refresh-installer: { update: false }`**：阻止 Subiquity 从 `snapstore.io` 刷新安装器 snap。
     注意字段名是 `refresh-installer`，不是 `refresh`——后者不在 schema 中，会被 Subiquity 静默忽略。
   - **`autoinstall.timezone: UTC`** + **`autoinstall.locale: en_US.UTF-8`**：显式指定时区和语言，
     阻止 Subiquity 通过 geoIP 检测时区（需 HTTP 请求到 `ubuntu.com`）。
   - **`ntp: { enabled: false }`**（cloud-config 顶层键）：禁用 cloud-init NTP 模块，阻止 NTP 同步超时。
   - **`package_update: false`** + **`package_upgrade: false`**（cloud-config 顶层键）：禁用 cloud-init
     的 `apt-get update` 和 `apt-get upgrade` 步骤，避免安装阶段额外的网络操作。
6. **cloud-config 顶层键 vs autoinstall 段**：user-data 是一份 cloud-config 文档，
   `autoinstall:` 是其中的一个 YAML key。Subiquity 只读 `autoinstall:` 段内的字段；
   cloud-init 自身模块（NTP、package_update 等）读的是 cloud-config 顶层键。
   将 `ntp`、`package_update`、`package_upgrade` 写在 `autoinstall:` 段内不会生效——
   Subiquity 会忽略它们，cloud-init 也看不到它们。渲染器必须严格区分两者缩进层级：
   autoinstall 段内 2 空格缩进，cloud-config 顶层键 0 空格缩进。

### 9.3.2 autoinstall schema 准确性参考

以下字段在实现过程中曾因名称错误或不在 schema 中而引发线上故障，修复时已逐项对照
Subiquity 官方 `autoinstall-schema.json`（`canonical/subiquity` 仓库根目录）确认：

| 字段 | 正确名称 | 常见误写 | schema 定义 | 故障现象 |
| --- | --- | --- | --- | --- |
| 安装器刷新 | `refresh-installer` | `refresh` | `{ update: boolean, channel: string }` | 隔离网段长时间等待 snap 刷新超时 |
| APT 失败行为 | `apt.fallback: <profile value>` | 非法枚举或遗漏策略语义 | 枚举: `abort` \| `continue-anyway` \| `offline-install` | `abort` 严格失败；`offline-install` 回退 squashfs；`continue-anyway` 不推荐 |
| Suite 控制 | 不存在 | `apt.disable_suites` | curtin 内部字段，不在 autoinstall schema 中 | Subiquity 静默忽略，所有默认 suite 仍被配置 |
| 组件控制 | `apt.disable_components` | — | 枚举数组: `universe` \| `multiverse` \| `restricted` \| `contrib` \| `non-free` | 控制组件而非 suite |
| 更新策略 | `updates` | — | 枚举: `security` \| `all`；不设置时默认 `security` | 隔离网段仍会尝试安全更新 |

`apt` 段完整合法字段清单（经 `autoinstall-schema.json` 确认）：
`preserve_sources_list`、`primary`（legacy 数组）、`mirror-selection`（含 `primary` 数组）、
`geoip`、`sources`、`disable_components`、`preferences`、`fallback`。

GRUB 菜单标题不是认证或策略来源，只是操作员可见的部署提示；格式为
`NodeForge - <node_id>:<lease_ip> - <profile>`，同时显示 NodeForge 标识、
节点 ID、DHCP 分配的 IP 地址与 profile 名称，便于在 PXE 控制台发现误选 profile
或定位网络配置异常。

版本支持：

| 层级 | 版本 | 实现要求 |
| --- | --- | --- |
| MVP 必测 | Ubuntu Server 22.04 LTS aarch64、x86_64 | aarch64 开发 smoke test 与 x86_64 生产 smoke test 必须通过 |
| 后续目标 | Ubuntu Server 22.04 之后的 LTS | 按版本增加 schema、installer 参数和 fixture，不预先假定字段完全兼容 |
| 非目标 | Ubuntu Server 20.04 LTS 及更早版本 | 不实现 d-i/preseed，也不做存量兼容 |

#### 9.3.3 M3 answer 与上报约束

M4 kernel cmdline 只携带 node-specific answer/config URL，绝不携带 `boot_session_id` 或 capability token。
`/answer` 以 M3 bootstrap proof 兼容 `inst.ks=` 与 NoCloud-Net；M4 renderer 可在受认证的 answer 内容中注入
`nodeforge_boot_session_id`、`nodeforge_access_token` 与 `nodeforge_event_url`，但不得将它们写到服务日志、
Event、安装器 debug 输出或 URL。Kickstart `%post`、Ubuntu late-command/firstboot 通过
`Authorization: Bearer` 和 `X-NodeForge-Session` header 上报阶段；body 只使用 §8.6 的 DTO。

M4 不自行更新 `node_status`、选择 EventType 或解释 session 生命周期。它把 source-specific stage 交给 M3
映射；session 已失效时收到 409，安装器保留本地安全摘要并继续本地可恢复路径，不得以旧 session 重试写入。

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

实际映射由 M3 `http/node_events.zig` 根据认证 profile 和 §8.6 stage allowlist 执行；M4 只能提交
`installer_started`、`config_fetched`、`started`、`partitioning`、`packages`、`bootloader`、`post`、
`rebooting`、`completed` 或 `failed`，不能提交 `type`、`source`、`node_id` 或自由 fields。

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

### 9.10 M4.1：公共目标系统配置与自动安装完善

M4.1 是 M4 的收敛和纠错子阶段，不增加新的安装器，也不改变 DHCP/TFTP/HTTP 引导协议。它一方面把 M4
验证中仍为硬编码或未落地的目标系统配置变成强类型事实：locale、timezone、keyboard、离线连接策略、
OpenSSH、root 登录、普通用户/password/sudo/逐账号 SSH key、防火墙、SELinux、额外包以及安装后网络；
另一方面接收 M0-M4 审计发现、
但尚未实现的 answer 正确性补丁。Ubuntu autoinstall 与 Rocky Kickstart 必须消费同一语义模型；adapter
只负责格式映射，不得各自发明默认值。M4.1 验收前不得把“安装器已经进入”视为无人值守部署成功。

字段依据使用 Canonical 的 [Autoinstall configuration reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)
和随 install source 固定的 `autoinstall-schema.json`，不能只看 latest；Kickstart 语义使用 Red Hat 的
[RHEL 9 Kickstart commands reference](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/automatically_installing_rhel/kickstart-commands-and-options-reference_rhel-installer)。
Canonical 当前 reference 明确 password 必须是 `passwd` 接受的 encrypted string、late/error commands 在
installer environment 运行；而 `identity.groups` 是 26.04 新能力，因此 Jammy fixture 必须按介质实际版本判定。

#### 9.10.1 当前实现差距与阶段边界

进入 M4.1 时的代码事实如下，文档不得把右侧缺口描述为已支持：

| 能力 | Ubuntu M4 现状 | Rocky M4 现状 | M4.1 交付 |
| --- | --- | --- | --- |
| locale | 固定 `en_US.UTF-8` | 固定 `en_US.UTF-8` | profile 可配置，省略时保持原默认 |
| timezone | 固定 `UTC` | 固定 `UTC` | profile 可配置 IANA timezone |
| keyboard | 未建模 | 固定 `us` | profile 可配置，默认 `us` |
| 外网抑制 | refresh/geoip/NTP/update 已部分关闭 | 仅使用本地 `url`，目标系统时钟源未收敛 | 形成 `local-only` 明确契约和双 adapter 映射 |
| OpenSSH | `install-server: true`、`allow-pw: true` | 依赖最小环境隐含内容 | 两边显式安装、启用并渲染统一认证策略 |
| root 登录 | 未配置 | 未配置 | 默认启用 root 密码 SSH，默认密码 `asdf1234`，允许覆盖 |
| SSH key | `InstallConfig` 有字段但 renderer 未消费 | 同左 | 用户 key 和 root key 都有确定目标 |
| 密码目标格式 | 错误渲染为裸 SHA-256 hex | `user --password` 直接携带明文且缺少必需 `rootpw` | config 始终明文；answer 统一派生 SHA-512 crypt `$6$`，Kickstart 使用 `--iscrypted` |
| Ubuntu identity | `users=[]` 时仍输出缺 username/password 的残缺 mapping | 不适用 | 有用户时输出完整 identity；无用户时仅在绑定版本支持时使用 `user-data` root-only，否则部署前拒绝 |
| 用户 sudo/keys | `sudo` 与兼容 `ssh_authorized_keys` 未消费 | `wheel` 已渲染，但没有 `sshkey` | sudo/group 与逐账号 authorized_keys 双 adapter 生效 |
| NodeForge 管理公钥 | 无服务器 bootstrap admin key 来源 | 同左 | 显式公钥优先，否则读取 root 公钥，最后原子生成持久 Ed25519；始终与 profile key 合并 |
| 主机防火墙 | 未配置 | 未配置 | Ubuntu UFW、Rocky firewalld 默认关闭 |
| SELinux | 不适用（Ubuntu 使用 AppArmor） | 未配置 | Rocky 默认 `disabled`；`sestatus` 应显示 disabled |
| 额外包 | legacy `install.packages` 已渲染 | `%packages` 已渲染 | 归一化为 `system.packages`，增加去重、本地可用性预检和缺包失败语义 |
| answer 结构 | 空 packages 形成非 list，未做 YAML/schema 验证 | 未做目标版本语法验证 | 空列表显式为 `[]`；Ubuntu parser/schema、Rocky ksvalidator/Anaconda fixture 必过 |
| storage/bootloader | 强制 `layout: direct`，忽略显式 partitions/boot disk | `bootloader.install=true` 却输出 `--location=none` | 两边按同一 storage/bootloader plan 渲染，禁止静默忽略或反向语义 |
| installer 事件 | late event 错误放进 target chroot | 仅 post 事件 | installer 环境直接上报 started/post/failed；目标系统命令才使用 in-target |
| 目标系统网络 | 继承 installer DHCP | 固定 `--bootproto=dhcp` | 节点级 DHCP/静态 IPv4，按 PXE MAC 匹配接口 |

M4.1 只配置安装器运行期间及安装后目标系统的网络。PXE bootstrap 仍使用 DHCP：GRUB、kernel、initrd、
ISO、answer 与本地 repo 获取路径不改成静态 kernel cmdline。`node.ip` 是 DHCP 保留地址；新增的
`node.overrides.network` 是目标系统持久网络配置，两者是不同事实，但 M4.1 的静态模式要求地址相同，
以避免安装器中途换 IP 导致本地 HTTP 下载和事件上报断开。

#### 9.10.2 公共配置模型

公共目标系统策略放在 profile，节点专属网络放在 node override。建议模型如下；字段均为新增且有默认值，
因此 `schema_version = 1` 的旧配置仍能读取，省略后输出必须与 M4 当前默认行为兼容。

```zig
const ProfileConfig = struct {
    // existing fields ...
    system: TargetSystemConfig = .{},
    install: ?InstallConfig = null,
};

const ServerConfig = struct {
    // existing fields ...
    // NodeForge 管理端的 bootstrap SSH 公钥。这里只允许 public key；null 时由
    // ServerAdminKeyProvider 按固定优先级读取或生成，private key 不进入 config。
    ssh_authorized_public_key: ?[]const u8 = null,
};

const TargetSystemConfig = struct {
    localization: LocalizationConfig = .{},
    connectivity: ConnectivityPolicy = .{},
    ssh: SshConfig = .{},
    security: TargetSecurityConfig = .{},
    users: []const TargetUserConfig = &.{},
    packages: []const []const u8 = &.{},
};

const LocalizationConfig = struct {
    locale: []const u8 = "en_US.UTF-8",
    timezone: []const u8 = "UTC",
    keyboard: []const u8 = "us",
};

const ConnectivityMode = enum {
    @"local-only",
};

const ConnectivityPolicy = struct {
    mode: ConnectivityMode = .@"local-only",
    time_sync: bool = false,
    ntp_servers: []const []const u8 = &.{},
};

const RootLoginPolicy = enum {
    no,
    @"prohibit-password",
    yes,
};

const SshConfig = struct {
    enabled: bool = true,
    password_authentication: bool = true,
    root_login: RootLoginPolicy = .yes,
    root_password: ?[]const u8 = "asdf1234",
    root_authorized_keys: []const []const u8 = &.{},
};

const FirewallPolicy = enum { disabled, enabled };
const SelinuxMode = enum { disabled, permissive, enforcing };

const TargetSecurityConfig = struct {
    firewall: FirewallPolicy = .disabled,
    selinux: SelinuxMode = .disabled,
};

const TargetUserConfig = struct {
    name: []const u8,
    password: ?[]const u8 = null,
    sudo: bool = false,
    ssh_authorized_keys: []const []const u8 = &.{},
};

const NodeOverrideConfig = struct {
    network: ?TargetNetworkConfig = null,
};

const TargetNetworkConfig = struct {
    mode: NetworkMode = .dhcp,
    interface: ?[]const u8 = null,
    match_mac: ?[]const u8 = null,
    address: ?[]const u8 = null,
    prefix_len: ?u8 = null,
    gateway: ?[]const u8 = null,
    dns: []const []const u8 = &.{},
    search_domains: []const []const u8 = &.{},
};

const NetworkMode = enum { dhcp, static };
```

JSON 示例：

```json
{
  "name": "ubuntu-22.04-install",
  "mode": "install",
  "system": {
    "localization": {
      "locale": "en_US.UTF-8",
      "timezone": "Asia/Shanghai",
      "keyboard": "us"
    },
    "connectivity": {
      "mode": "local-only",
      "time_sync": false,
      "ntp_servers": []
    },
    "ssh": {
      "enabled": true,
      "password_authentication": true,
      "root_login": "yes",
      "root_password": "asdf1234",
      "root_authorized_keys": ["ssh-ed25519 AAAA... admin@example"]
    },
    "security": {
      "firewall": "disabled",
      "selinux": "disabled"
    },
    "users": [
      {
        "name": "ubuntu-server",
        "password": "explicit-password",
        "sudo": true,
        "ssh_authorized_keys": ["ssh-ed25519 AAAA... admin@example"]
      }
    ],
    "packages": ["curl", "vim"]
  },
  "install": {
    "apt": { "fallback": "offline-install" }
  }
}
```

节点静态网络示例：

```json
{
  "id": "pxe27-uefi",
  "mac": "00:50:56:aa:bb:cc",
  "ip": "192.168.27.27",
  "hostname": "pxe27-uefi",
  "profile": "ubuntu-22.04-install",
  "overrides": {
    "network": {
      "mode": "static",
      "match_mac": "00:50:56:aa:bb:cc",
      "address": "192.168.27.27",
      "prefix_len": 24,
      "gateway": "192.168.27.128",
      "dns": ["192.168.27.128"],
      "search_domains": ["nodeforge.local"]
    }
  }
}
```

`install.users`、`install.packages` 和 `install.ssh_authorized_keys` 作为当前实现中的兼容字段保留一个配置周期；
新配置分别使用 `system.users`、`system.packages` 和 `system.users[].ssh_authorized_keys`。只出现 legacy 字段时，
M4.1 loader 将其归一化到 TargetSystemConfig；新旧 users/packages 同时非空时返回迁移冲突，不能合并出不透明
顺序。legacy SSH key 只映射到第一个非 root 用户并与该用户 key 去重，不能隐式复制给 root。完成一个配置周期
后删除 legacy 字段，M5 从第一版开始只消费 normalized `system.users/packages`。
系统用户密码和 `ssh.root_password` 延续全局 password 明文事实源约定；该约定不是只针对这两个字段：
任何当前或未来 NodeForge config password 字段都在配置导入、导出和存储时保留原始明文，不引入 SecretRef、
加密数据库或轮换流程。renderer 只在安装器要求 hash 的位置临时转换为目标系统可接受的 password hash，
且不得回写配置。服务日志、Event、status/plan 默认输出不记录密码；`config export`/配置文件作为事实源则
按原样显示明文。

附件提出的“password 字段检测 `$6$`/`$5$`/`$y$` 等前缀并透传”不纳入 M4.1，因为它与 NodeForge
“所有 password 配置字段都是明文事实源”的全局契约冲突，也会让同一字段同时承担明文和派生值两种类型。
M4.1 的 password 字段即使文本以 `$6$` 开头，也按普通明文处理并重新派生目标 hash。未来确有导入现成
hash 的需求时，必须另设显式 `password_hash` 类型、迁移和 adapter 能力校验，不能靠字符串前缀猜测。

#### 9.10.3 默认值与安全语义

| 配置 | 默认值 | 语义 |
| --- | --- | --- |
| `localization.locale` | `en_US.UTF-8` | 与 M4 兼容；允许自定义，但必须由安装介质提供 locale 数据 |
| `localization.timezone` | `UTC` | 不进行 GeoIP 推断；允许 `Asia/Shanghai` 等 IANA 名称 |
| `localization.keyboard` | `us` | 安装器与目标系统共同使用 |
| `connectivity.mode` | `local-only` | renderer 只生成 NodeForge 本地源和显式本地端点，不生成厂商公网默认值 |
| `connectivity.time_sync` | `false` | 安装期间和目标系统均不启用默认公网 NTP |
| `ssh.enabled` | `true` | 两个 adapter 显式安装并启用 OpenSSH server |
| `ssh.password_authentication` | `true` | 保持已有普通安装用户的密码登录兼容性 |
| `ssh.root_login` | `yes` | 默认允许 root 通过 SSH 登录 |
| `ssh.root_password` | `asdf1234` | root 默认密码；允许 profile 显式修改或设为 `null` |
| `system.users` | `[]` | 不隐式创建 `ubuntu-server` 等普通用户；默认管理入口为 root |
| `system.packages` | `[]` | 不增加用户声明的额外包；OpenSSH 等系统必需包仍由 resolved plan 标记 |
| `server.ssh_authorized_public_key` | `null` | 省略时按固定来源探测/生成 NodeForge bootstrap admin key；最终公钥始终注入 |
| `security.firewall` | `disabled` | Ubuntu 禁用 UFW，Rocky 禁用 firewalld |
| `security.selinux` | `disabled` | Rocky 禁用 SELinux；Ubuntu 标记为不适用，不改变 AppArmor |
| `network.mode` | `dhcp` | 目标系统默认保留 DHCP；PXE bootstrap 始终 DHCP |
| `safety.reinstall_policy` | `explicit` | install generation 默认只消费一次；再次重装需要显式 retry/rearm |

默认组合为 `enabled=true`、`password_authentication=true`、`root_login=yes`、
`root_password=asdf1234`，所以部署完成后 root 密码 SSH 应直接可用。用户可以修改 root password，也可以将
`root_login` 改为 `prohibit-password`/`no`，或将 `root_password` 设为 `null`。root 密码登录实际成立必须同时
满足 password authentication、非空 root password 和 `root_login=yes`。`enabled=false` 时不得渲染 sshd
配置或启动服务，也不得因为事件上报内部使用 curl 而重新启用 SSH。

“关闭 `sestatus`”不是有效系统配置：`sestatus` 是查询命令。M4.1 将需求解释为 SELinux 默认 disabled；
Rocky 安装后执行 `sestatus` 应显示 `SELinux status: disabled`。Ubuntu 默认不使用 SELinux，`selinux` 字段在
Ubuntu adapter 中为 not-applicable，不能据此关闭 AppArmor。`firewall=disabled` 则按发行版关闭 Rocky
firewalld 或 Ubuntu UFW；服务不存在时视为已经关闭，不为了关闭它额外安装软件包。

M4.1 不提供一个名为 `geoip` 的可配置开关。Ubuntu 始终渲染 `apt.geoip: false`，locale/timezone 始终来自
配置；Rocky 不调用 GeoIP。这样可以避免用户为了修改时区而意外恢复公网探测。

#### 9.10.4 `local-only` 离线契约

`local-only` 表示“NodeForge 生成的安装配置不包含未声明的公网访问”，不是主机防火墙。若要从网络层保证
绝对不能访问互联网，部署网仍需由路由器、防火墙或无默认出口 VLAN 强制隔离。M4.1 renderer 必须做到：

| 来源 | Ubuntu autoinstall | Rocky Kickstart |
| --- | --- | --- |
| 安装器自身更新 | `refresh-installer.update: false` | 不配置在线 stage2/update 源 |
| GeoIP | `apt.geoip: false`，显式 locale/timezone | 不使用 GeoIP |
| 基础包源 | 仅 `/repos/<source>/` 和 ISO squashfs | 仅 NodeForge `inst.repo`/`url`/`repo` |
| 软件更新 | `package_update: false`、`package_upgrade: false` | 不增加 updates/BaseOS/AppStream mirrorlist/metalink |
| NTP | cloud-init NTP 关闭；目标系统默认时间同步服务禁用 | Kickstart 禁止默认 NTP；目标 chronyd 默认禁用或只写显式本地 server |
| SSH | 只安装/配置本机服务 | 只安装/配置本机服务 |
| 事件上报 | 只访问 NodeForge server IP | 只访问 NodeForge server IP |

所有 NodeForge 生成的 URL 使用 `server.server_ip` 字面 IPv4，不依赖公网 DNS。显式配置的 DNS、gateway 或
未来本地 NTP 只表示目标网络参数；renderer 不据此生成公网域名。M4.1 中 `time_sync = true` 时必须提供至少
一个 `ntp_servers`，禁止回退到发行版 vendor pool；为空时配置校验失败。是否为“本地”由站点路由边界保证，
NodeForge 不能仅凭域名或 RFC1918 地址可靠判断。

#### 9.10.5 网络配置与转换规则

静态配置是节点属性，不应放入可被多个节点共享的 profile。规则如下：

1. `overrides.network` 省略或 `mode = dhcp` 时，Ubuntu 生成 DHCP Netplan，Rocky 生成
   `network --bootproto=dhcp`；两者都显式写 hostname。
2. `mode = static` 必须提供 `address` 和 `prefix_len`，prefix 取值 1-32；gateway、DNS 和 search domain
   可为空，允许无默认路由的纯隔离网。
3. M4.1 要求 `node.ip == network.address`。该地址由 DHCP 先保留给同一 MAC，安装器切换到持久静态配置时
   地址不变，避免 ISO/repo/answer 下载中断。
4. `match_mac` 省略时使用 `node.mac`。指定值必须等于 node 的 PXE MAC；多 NIC 任意选择留到 M6，M4.1
   不允许用未登记 MAC 绕过节点身份。
5. `interface` 是可选的目标接口名称；为空时 Ubuntu 按 MAC match，Rocky 按 MAC/device 绑定。不能默认写死
   `ens160`、`enp1s0` 等受固件和驱动影响的名字。
6. 静态地址必须位于 `dhcp.subnet`，不能与其他 node 保留地址重复，也不能落入动态池，除非 DHCP allocator
   已将其作为当前 node 的静态 reservation 排除。
7. NodeForge server IP 必须可由该地址按直连子网或 gateway 到达；单子网 M4.1 至少验证同网段可达性，
   更复杂路由留到 M6。

Ubuntu adapter 渲染 autoinstall `network` 的 Netplan v2，使用 `match.macaddress`、addresses、默认 route 和
nameservers；Rocky adapter 渲染 Kickstart `network` 的 `--device`、`--bootproto=static`、IP/prefix、gateway、
nameserver 与 hostname。最终文件分别由 installer 写入目标 Netplan 和 NetworkManager 配置，不依赖
`late-commands`/`%post` 再猜网卡名称。

#### 9.10.6 SSH、用户和 root 映射

##### 9.10.6.1 明文密码到 SHA-512 crypt

配置事实源始终保存明文，answer file 不直接复用该明文。M4.1 增加统一 `PasswordHasher`，对普通用户和
root password 在内存中派生标准 SHA-512 crypt 字符串：`$6$<salt>$<digest>`。禁止继续使用裸 SHA-256
hex，也禁止根据 password 文本前缀判断“已经哈希”。Ubuntu 的 `identity.password`/cloud-init `passwd`
使用派生值；Rocky 的 `rootpw` 与 `user --password` 同样使用派生值并显式附加 `--iscrypted`，避免 answer
在 HTTP 响应和 installer 内存之外继续携带明文。配置 import/export 仍只看见原始明文。

实现契约而非具体库绑定如下：

- salt 使用 CSPRNG 产生 16 个 crypt 字符集字符 `[A-Za-z0-9./]`；默认采用 SHA-crypt 5000 rounds，输出不写
  `rounds=`，未来算法升级必须显式版本化，不能改变同一阶段的语义。
- 生产实现必须等价于 `crypt(3)` SHA-512；若调用系统库，使用线程安全的 `crypt_r`/等价接口并处理
  libxcrypt 可用性；若采用纯 Zig 实现，必须逐项实现 SHA-crypt 的自定义 base64 排列，不能使用普通 Base64。
- 密码派生结果只存在于一次 boot session 的 answer/BootConfig 生成上下文。对同一
  `(daemon_instance_id, boot_session_id, config revision, account)` 的重试复用同一派生结果，避免每次 GET
  因随机 salt 生成不同 answer；session 结束即清理，不写回 config/catalog/runtime/event。
- 单元测试注入固定 salt，覆盖 Drepper/libxcrypt 已知向量；Linux 集成测试使用 `openssl passwd -6`、
  `mkpasswd --method=sha-512` 或系统 `crypt` 交叉验证。日志和断言只能记录账号及 hash 算法，不记录明文。

##### 9.10.6.2 NodeForge bootstrap admin key

这里的 key 是“NodeForge 管理端登录目标节点使用的客户端 key”，不是目标节点 sshd host key。公钥来源按
固定顺序解析一次，不能在每次 `/answer` 请求时重新生成：

1. `server.ssh_authorized_public_key` 显式配置；
2. 可读且合法的 `/root/.ssh/id_rsa.pub`；
3. 可读且合法的 `/root/.ssh/id_ed25519.pub`；
4. 加载 NodeForge 已持久化的 generated Ed25519 key pair；不存在时生成并原子持久化。

生成路径固定为 `/opt/nodeforge/state/bootstrap-ssh/id_ed25519` 与 `.pub`，目录 `0700`、private key `0600`、
public key `0644`，owner 为 daemon 用户。创建使用受约束 open、临时文件、fsync、rename，拒绝 symlink、
非普通文件、损坏或不匹配的 key pair；成功只记录 SHA256 fingerprint。daemon 非 root 时 `/root/.ssh` 不可读
属于正常降级，转入持久 generated key。存在 install/diskless profile 且显式公钥、可读 key、已持久 key 与
生成路径全部不可用时，preflight/answer 必须以 `ServerAdminKeyUnavailable` 失败，不能静默省略“始终注入”。

“默认免密”只表示持有对应 private key 的管理端可以登录：读取 `/root/.ssh/*.pub` 或 generated key 时，
NodeForge 服务机本身持有匹配 private key；显式配置一个外部 public key 时，private key 由操作员自行持有，
NodeForge 不要求也不保存它。CLI `server show`/`install plan` 只显示来源类别、fingerprint、是否 generated 和
public key path，不显示 private key 内容。

公钥解析只接受支持矩阵中的 OpenSSH 单行 public-key 格式，校验算法和 base64 blob；去重依据是解码后的
`(algorithm, key blob)`，忽略 comment 差异。private key 永不进入 config、catalog、BootConfig、answer、
rootfs、日志或 event。此规则与“password 可明文”无关，不能借该规则放宽 private key 处理。

注入采用始终合并：

- root 最终 keys = bootstrap admin public key + `profile.system.ssh.root_authorized_keys`；
- 每个普通用户最终 keys = bootstrap admin public key + `users[].ssh_authorized_keys`；
- 兼容字段 `install.ssh_authorized_keys` 仅追加到第一个普通用户，一个配置周期后删除；
- 不把某普通用户的 profile key 隐式复制给 root，也不把 root profile key复制给普通用户；所有集合按 key
  blob 去重。`ssh.enabled=false` 可停止/禁用 sshd，但不改变配置归属；重新启用后仍应用同一合并结果。

Ubuntu `autoinstall.ssh.authorized-keys` 只作用于 identity 用户，因此普通 identity 用户使用该字段；root 和
其他用户 keys 通过受约束的 `autoinstall.user-data` 或目标文件 plan 落地。Rocky 对 root 和每个普通用户分别
渲染 `sshkey --username=<account> "<key>"`。ServerAdminKeyProvider 输出进入 adapter 无关 normalized plan，
adapter 不读取 `/root/.ssh` 或 state 文件。

##### 9.10.6.3 Ubuntu identity 与用户映射

Ubuntu 不得输出残缺 `identity`：

- normalized `system.users` 非空时，第一个普通用户完整映射为 identity 的 hostname、username 和 `$6$` password。
  `identity.groups` 是 Subiquity 26.04 新能力，Ubuntu 22.04 fixture 不得直接使用 latest schema 的
  `groups.append`；MVP 按绑定 installer capability 通过 `autoinstall.user-data.users` 或受控 target account
  finalizer 落地 `sudo=true/false`。该用户 password 为 null 时只允许 key 登录，使用有效锁定 hash。
- normalized `system.users` 为空时绝不输出残缺 identity。只有该 install source 固定的 Subiquity capability 已实测支持
  “`user-data` 存在时 identity 可省略”，才省略整个 mapping 并用 `autoinstall.user-data` 完成 root-only；
  否则在 PXE 前返回 `InstallIdentityUnavailable`。不得隐式创造 `ubuntu-server` 或其他未知账号。
- 多个普通用户由 `autoinstall.user-data.users` 或 adapter-independent account plan 落地；不能只消费首个用户
  并静默丢弃其余用户。每个账号的 password/sudo/keys 必须保持归属。
- `password_authentication` 是 sshd 全局策略，不因某一个账号 password 为 null 就自动关闭其他账号或 root
  的密码登录；单账号 null 通过锁定该账号表达。只有 profile 全局配置为 false 时才渲染 `allow-pw: false`。

##### 9.10.6.4 Adapter 最终映射

Ubuntu：

- `ssh.enabled = true` 映射为 `autoinstall.ssh.install-server: true`，并确保 `openssh-server` 被安装。
- `password_authentication` 映射为 `ssh.allow-pw`；每个用户 key 必须进入对应用户的
  `authorized_keys`，不能全部塞给 identity 用户后丢失归属。
- `root_login`、root password/key 和确定性的 sshd 策略通过目标系统文件
  `/etc/ssh/sshd_config.d/60-nodeforge.conf` 与 root account 配置落地；写文件使用受约束 renderer/runner，
  不拼接未转义自由 shell。
- 默认 root password `asdf1234` 从明文事实源转换为 Ubuntu shadow/installer 接受的 crypt hash；安装完成后
  必须实际验证 `ssh root@<node>` 的密码认证，而不能只检查 sshd_config 文本。
- `security.firewall=disabled` 时，不安装 UFW；若介质/目标系统已有 UFW，则执行等价的 disable 并确保开机
  不自动启用。Ubuntu 不处理 SELinux 字段，也不因此关闭 AppArmor。

Rocky：

- `%packages` 显式包含 `openssh-server`，并渲染 `services --enabled=sshd`。
- 普通用户使用 `user`，用户 key 使用 `sshkey --username=<name>`；root key 明确使用 root 目标。
- root password 使用 Kickstart `rootpw --iscrypted` 的 `$6$` 形式；普通用户 password 同样使用
  `--iscrypted`；`sshd_config.d/60-nodeforge.conf` 使用与 Ubuntu 相同的
  `PermitRootLogin`/`PasswordAuthentication` 语义。
- `security.firewall=disabled` 映射为禁用并 mask firewalld；`security.selinux=disabled` 映射为 Kickstart
  `selinux --disabled` 和目标 `/etc/selinux/config`。安装后分别以 `systemctl is-enabled firewalld` 和
  `sestatus` 验证，而不是把命令名称当配置项。

两边至少要求一个可用的管理入口：普通用户密码、普通用户 key、root key 或 root 密码登录四者必须有一个
成立，否则配置校验返回 `InstallAccessUnavailable`。默认 root + `asdf1234` 已满足该约束。Ubuntu identity
需要非 root 用户时，其用户名和密码仍必须来自 profile，不能由 adapter 隐式创造未知账号。`install render`
作为配置预览可以明确显示密码事实已配置；服务日志/Event 不记录密码。

#### 9.10.7 额外包

`system.packages` 表示目标系统必须具备的额外包。自动安装由安装器原生 package 阶段安装；无盘系统由 M5
rootfs build 安装。legacy `install.packages` 只在 M4.1 loader 中归一化，不再作为 renderer 的事实源。
M4.1 增加以下规则：

- 去重并保持第一次出现的声明顺序；adapter 自动需要的 `openssh-server`、`curl` 等内部包也进入同一计划，
  但 `install render/plan` 必须标注其来源为 `system-required`，不能静默增加。
- `local-only` 下只允许从当前 install source 及其已发布本地 repositories 解析；不得因缺包增加
  `archive.ubuntu.com`、mirrorlist、metalink 或 CDN fallback。
- 能从 catalog repository metadata 判断缺失时，在开始 PXE 前返回 `InstallPackageUnavailable`；无法建立
  完整索引的 ISO/offline squashfs 必须在 plan 中标注 `availability=installer-media`，并由 smoke test 验证。
- required package 安装失败必须使安装失败；M4.1 不引入 `ignoremissing` 或 optional package。可选包留给
  后续 provisioning bundle 扩展。
- `system.packages` 与 bundle 的 `standard_packages` 不能重复；plan 检测到重复时配置校验失败，而不是安装两次。
- Ubuntu 即使没有额外包也必须渲染 `packages: []` 或省略该字段，不能输出 YAML null。`local-only` 下还要
  验证 Subiquity 默认 `updates: security` 不会恢复公网 pocket：最终 apt sources 只能指向 NodeForge 本地
  repository，缺少对应 suite 时按 profile fallback/required-package 语义明确失败。

#### 9.10.8 校验、渲染和代码任务

值级校验先于 adapter 渲染：locale 允许 `C`、`C.UTF-8` 和由 ASCII 字母/数字、`_`、`.`、`-`、`@`
组成的 glibc locale 名，并必须能由目标介质/rootfs capability 满足；timezone 允许 `UTC` 或安全的 IANA
相对路径，拒绝绝对路径、空段、`.`、`..` 和控制字符；keyboard/interface/search domain/package name 均限制
为单行有界标识符。SSH public key 必须是单行、长度受限并具有允许的 key type 与非空 base64 body；换行、
private-key header 和 shell/YAML 控制内容一律拒绝。密码不做字符集裁剪，但只能进入专用 hash/转义路径。

answer 结构契约：

- install profile 必须显式具有 `profile.install`，不得由 answer route 用空 `InstallConfig{}` 代替；在 PXE 前
  校验至少一个合法登录入口、adapter 所需 root/identity 规则、storage 和 bootloader。普通用户名必须唯一、
  符合目标系统账号规则且不能用 `root` 绕过 `profile.system.ssh`；package/key/script 均在 renderer 前完成
  单行、长度和注入字符校验。
- Ubuntu 显式渲染 `interactive-sections: []` 和 `shutdown: reboot`，确保完全自动并把默认行为固化为 fixture；
  `early-commands` 在 installer 环境直接上报 `started`，`late-commands` 直接上报 `post`/`rebooting`，
  `error-commands` 直接上报 `failed`。只有操作目标 `/target` 的 bundle/文件命令使用
  `curtin in-target --target=/target`；事件 curl 不得放进 target chroot。事件失败使用有界 `|| true`，不因
  NodeForge 暂时不可达把已经成功的 OS 安装判为失败。
- Rocky 对应使用受目标版本支持的 `%pre`、`%post`、`%onerror`/等价事件入口，且只提交 M3 allowlist 中的
  stage。M4.1 同步校验 stage→EventType→node_status 映射，不能只改 answer 而让服务端返回 409。
- Ubuntu storage 不再无条件硬编码 `direct`：没有显式 partitions 时可使用 `layout: direct`，但必须按
  `boot_disk` 的稳定 path/serial match 限定目标盘；有显式 partitions 时渲染 action-based `storage.config`。
  Rocky 使用同一 normalized plan，`bootloader.install=true` 不得输出 `--location=none`，boot drive 使用
  Anaconda 接受的无 `/dev/` 标识，并必须包含 Rocky 9 所需的 `rootpw`。
- renderer 输出先通过 YAML parser，再按该 profile 绑定的 Subiquity 版本 schema 校验；不能只做字符串包含
  断言。Kickstart 通过目标 Rocky 9 `ksvalidator` 或 Anaconda dry-run fixture。schema/版本能力表固定进测试
  资产，升级 Ubuntu LTS 或 installer snap 时由 M6 新增 fixture，不能悄悄沿用 latest。
- `/answer` 成功响应设置 `Cache-Control: no-store`，只能使用当前已认证 session 的 normalized plan、
  session-scoped password hashes 和 daemon 启动时确定的 bootstrap public key snapshot；失败不得返回半份 YAML。

生命周期与变更校验：

- install profile 默认 `reinstall_policy=explicit`；`always` 只允许 `destructive=true` 且
  `persistent_writes=true`，plan 必须显示高风险。不得用 node vars/overrides 绕过 install generation。
- `install retry` 校验 node/profile/mode、当前 session inactive、没有 pending generation 和 config revision；
  pending retry 重复请求返回已有 generation。offline `config validate` 不读取 runtime，也不输出伪造的 drift。
- `config diff/apply` 对 installed/completed 节点比较 desired/applied digest，区分“需重装”与“M7 可
  reconcile”；只 warning，不自动 arm、重启或擦盘。
- `lease_seconds` 必须能导出合法 T1/T2；bootstrap proof 必须同时满足有效 lease，capability proof 只依赖活动
  BootSession/token。preview answer 的 hash scope 必须可见，preview salt 不得进入真实 session。

M0-M4 历史能力在 M4.1 的补丁归属：

| 历史阶段 | 已有基础 | M4.1 必补且不得回改历史协议的内容 |
| --- | --- | --- |
| M0 config/store | JSON load/validate/import/export、默认路径 | 新 server public-key 字段向后兼容 round-trip；generated private key 只进 state，不进入 config/catalog |
| M2.5 logging/event | 统一日志与 Event v2 | password、派生 hash、private key 永不入日志/Event；public key 只记录 fingerprint |
| M2.5.1 session | boot session 与 capability | `$6$` 结果按 session/config revision 稳定复用，session 结束清理 |
| M3 answer transport | session 认证、answer 路由、stage allowlist、`Cache-Control: no-store` | 保持 no-store；完整渲染/校验后再响应、bootstrap key snapshot、started/post/failed stage 联调 |
| M4 adapters | Ubuntu/Kickstart 基本 renderer | crypt、identity、sudo/keys、rootpw、storage/bootloader、packages list、schema 校验及 installer-context event 修正 |

新增或扩展的代码职责：

| 模块 | M4.1 任务 |
| --- | --- |
| `model.zig` | 增加 TargetSystem、Localization、Connectivity、SSH、users、packages、NodeNetworkOverride 强类型字段和默认值 |
| `server/admin_key.zig` | 读取显式/root public key，校验/去重，原子生成并持久化 Ed25519 bootstrap admin key |
| `profile/password_hash.zig` | 线程安全 SHA-512 crypt provider、随机 salt、固定向量与 session-scoped 派生接口 |
| `config/load.zig` / `store.zig` | 旧配置默认值、legacy install users/packages/key 归一化、连字符枚举和新增字段 round-trip |
| `config/validate.zig` | locale/timezone/SSH 可达性、静态 IPv4、reservation、包重复及离线约束 |
| `profile/install.zig` | 合并 profile system + node override，生成 adapter 无关的 normalized install plan |
| `profile/adapter/ubuntu.zig` | locale/timezone/keyboard、Netplan、SSH/root/key、离线策略与额外包映射 |
| `profile/adapter/kickstart.zig` | lang/timezone/keyboard、network、services/rootpw/sshkey、本地 repo 与包映射 |
| `profile/render.zig` | YAML/Kickstart/shell 安全转义；敏感字段统一脱敏显示 |
| `http/server.zig` | answer 前构造 normalized plan、合并 bootstrap/profile keys、复用 session hash、完整成功后 no-store 响应 |
| `main.zig` | `install render`/plan 输出 resolved defaults、包来源和网络摘要，不输出 secret |
| `state/deployment_control.zig` | 持久化 install generation/consumed/config revision；retry rearm 幂等且不倒退 node_status |
| `boot/resolver.zig` | install profile 只有 armed generation 才返回 installer；已消费默认 wait/local-disk handoff |
| `config diff/apply` / profile show | 比较 desired/applied digest，分类 drift；M4.1 可先完成 warning contract，在线 reconciliation 留 M7 |

校验错误使用稳定分类：`InvalidLocale`、`InvalidTimezone`、`InvalidKeyboard`、`InvalidRootLoginPolicy`、
`InstallAccessUnavailable`、`InvalidTargetNetwork`、`StaticAddressMismatch`、`InstallServerUnreachable`、
`InstallPackageUnavailable`、`InstallIdentityUnavailable`、`ServerAdminKeyUnavailable`、`PasswordHashFailed`、`AnswerSchemaInvalid`、
`InstallStorageUnsupported`、`InvalidReinstallPolicy`、`InstallSessionActive`、`InstallRevisionChanged`、
`DeploymentControlPersistFailed` 和 `ExternalEndpointForbidden`。adapter 不应等到渲染一半后才返回普通
`InvalidConfig`。

#### 9.10.9 M4.1 测试与验收

单元和 fixture：

- 省略 `system`/`overrides.network` 时，两个 adapter 均得到 locale `en_US.UTF-8`、timezone `UTC`、
  keyboard `us`、SSH/password authentication enabled、root login `yes`、root password `asdf1234`、
  firewall disabled、Rocky SELinux disabled 和目标 DHCP。
- 自定义 `zh_CN.UTF-8`、`Asia/Shanghai`、keyboard、普通用户/sudo/逐账号 SSH key、root 策略和额外包能稳定
  round-trip 并进入正确 adapter 字段；legacy install users/packages/key 只在 loader 归一化一次。
- Ubuntu YAML 通过 parser/schema fixture；Rocky Kickstart 通过 `ksvalidator` 或目标版本 Anaconda fixture。
- 静态 IP 缺 address/prefix、与 `node.ip` 不同、MAC 不同、地址重复、落入未保留动态池或 server 不可达均失败。
- 默认 root/`asdf1234`、自定义 root password、root key、普通用户 password/key 组合覆盖可登录和不可登录
  校验；服务日志/Event 不含密码、private key 或 capability token。
- 所有普通用户/root password 均从明文生成 `$6$`；固定 salt 向量与 libxcrypt/OpenSSL 交叉一致，同 session
  重试 answer 字节稳定，不同 session 使用不同 salt。以 `$6$` 开头的 config password 仍按明文重新派生，
  不存在前缀透传。
- Ubuntu `users=[]` fixture 永不含残缺 identity：绑定版本支持 user-data-only 时验证 root-only 可登录，
  不支持时部署前返回 `InstallIdentityUnavailable`。有一个/多个用户时覆盖完整 identity、版本适配的 sudo
  映射和逐账号 keys；22.04 fixture 不得使用 26.04 才新增的 `identity.groups`。空 package 输出是 list，不是 null。
- bootstrap admin key fixture 覆盖显式配置、`id_rsa.pub`、`id_ed25519.pub`、持久 generated key、非 root
  降级、损坏/symlink 拒绝、重启 fingerprint 稳定和按 blob 去重；每个 root/普通用户均包含 server key 与
  自己的 profile key，账号之间不串 key。
- Ubuntu storage fixture 覆盖 direct+目标盘 match 与显式 action config；Rocky fixture 必含
  `rootpw --iscrypted`、正确 bootloader location/drive，不能出现 `bootloader --location=none`。
- Ubuntu answer 必须通过 YAML parser 和固定版本 Subiquity schema；`interactive-sections: []`、
  `shutdown: reboot`、`packages: []`、installer-context early/late/error event 均有结构断言。Rocky answer 通过
  Rocky 9 ksvalidator/Anaconda fixture。
- Rocky fixture 必须包含 firewalld disabled/masked 与 `selinux --disabled`；Ubuntu fixture 必须关闭 UFW 且不
  错误修改 AppArmor。明文密码 config import/export round-trip 不得被替换成 hash。
- local-only fixture 中不得出现 `archive.ubuntu.com`、`ports.ubuntu.com`、`snapstore.io`、vendor NTP pool、
  DNF mirrorlist/metalink 或其他未声明公网 URL。
- install generation fixture 覆盖首次 armed、`install.started` 才 consumed、completed/failed 后无 pending 时再次
  PXE 进入 wait、显式 retry rearm、重复 retry 幂等、活动 session 409 和高风险 `reinstall_policy=always`。
- 修改 network/users/packages/password/storage 后 desired/applied drift 分类正确但不自动 arm；offline validate
  不读取 runtime。preview hash 与实际 hash 可不同，normalized plan digest 相同；同一活动 session answer 字节稳定。
- DHCP T1/T2、lease 过期后 bootstrap 拒绝但既有 capability 在 TTL 内有效、daemon 重启 token 失效，以及
  TFTP option/TID、UTC 回拨 trace gap、asset 丢失、ISO ENOSPC/orphan cleanup 全部作为横切回归门槛。

实机/QEMU 验收：

1. Ubuntu Server 22.04 LTS 和 Rocky Linux 9.7 至少各完成一次默认 DHCP 安装，重启后普通管理用户可通过
   OpenSSH 登录，locale/timezone 与配置一致。
2. 至少一条 Ubuntu 或 Rocky 链路使用节点静态 IPv4；PXE 阶段仍 DHCP，安装器和重启后的目标系统地址保持
   `node.ip`，NodeForge 本地 repo 与事件上报不中断。
3. root 默认使用 `asdf1234` 可通过 SSH 登录；修改 profile 密码后旧密码失效、新密码可用；切换
   `prohibit-password`/`no` 后行为与配置一致。
4. 不配置任何 profile key 时，bootstrap public key 对应的 private key（服务机 root/generated key，或操作员
   持有的显式配置 key）可免密登录 root 和已声明普通用户；增加 profile key 后两类 key 同时存在且去重。
   daemon 重启后 generated key fingerprint 不变。
5. 从本地 repository 安装一个非基础额外包并在目标系统验证；配置不存在包时在部署前或 package 阶段明确失败。
6. 在无 NAT 的隔离网执行，并以 DHCP/DNS/HTTP/NTP 抓包或出口防火墙计数确认 NodeForge 生成配置没有公网请求。
7. Rocky 安装后 firewalld 为 disabled/masked，`sestatus` 显示 disabled；Ubuntu UFW 为 inactive/disabled。
8. 两个 adapter 的 started/post/failed 事件均由 installer 环境成功提交，失败安装能留下稳定 reason；Ubuntu
   显式 storage 与 Rocky bootloader/rootpw 在目标盘实测，不能只通过 schema/ksvalidator。
9. 安装成功后保持固件 PXE first，节点下一次重启不得再次进入 installer；执行一次 `install retry` 并重启后
   才创建新 generation。NodeForge 不具有 BMC 时，CLI 明确显示“已 rearm，等待节点下一次 PXE”。

M4.1 完成后才能把“自动安装支持自定义语言/时区、静态目标网络、默认 OpenSSH、可控 root 登录和离线额外包”
列为已实现能力；默认 root 密码、firewall 和 SELinux 也必须通过目标系统实测，不能只验证 answer 文本。

#### 9.10.10 自动安装与无盘的共享边界

M4.1 定义的是目标系统公共事实，不是 Ubuntu/Rocky 安装器的私有参数。M5 及以后必须直接消费同一份
normalized `TargetSystemConfig`，不得复制字段、另设默认值或把共享字段重新塞回 `InstallConfig`。

| 配置域 | 权威事实源 | M4.1 自动安装 | M5 无盘系统 |
| --- | --- | --- | --- |
| locale/timezone/keyboard | `system.localization` | answer + target finalizer | rootfs capability + overlay 文件 |
| local-only/time sync/NTP | `system.connectivity` | installer/目标系统禁公网默认值 | rootfs 清理 + overlay 服务策略 |
| SSH/root/password/管理公钥 | `system.ssh` + server bootstrap public key | answer + target finalizer | rootfs 提供 sshd，BootConfig/overlay 注入 hash、key 和策略 |
| 普通用户/password/sudo/逐账号 key | `system.users` | identity/user-data 或 Kickstart users | rootfs build 创建账号骨架，BootConfig/overlay 注入 hash 与 keys |
| 目标系统额外包 | `system.packages` | installer 原生 package 阶段 | rootfs build 阶段；启动时禁止 apt/dnf |
| 目标持久网络 | `node.overrides.network` | Netplan/Kickstart/NetworkManager | overlay 中生成 Netplan/NetworkManager |
| firewall/SELinux | `system.security` | answer + target finalizer | rootfs build + overlay；RHEL cmdline 同步 `selinux=0` |

自动安装专属配置只有 `install.apt.fallback`、install source、storage/partitions、bootloader、answer schema/
renderer、installer hook/event 和安装完成后的磁盘重启流程。无盘专属配置只有 boot bundle/rootfs/initrd、
overlay/tmpfs、rootfs 下载校验、switch_root 和每实例 SSH host key。hostname 虽来自 node 而非
`TargetSystemConfig`，但两条链路都必须写入目标系统。

共享字段由 `profile/system.zig` 归一化一次，再分别生成 install plan 和 diskless plan。adapter、answer route、
boot resolver 和 initrd 均不得自行补默认值。任何共享字段变更都必须同时更新 M4.1 adapter fixture、M5
rootfs/BootConfig/overlay fixture、M6 capability matrix 和 M7 protected-domain/finalizer 回归。

#### 9.10.11 一次性安装意图、retry 与重复 PXE

当前 `install retry` 只有命令名，没有安全语义；同时 boot resolver 只看 node→install profile 绑定，会使已安装
节点在固件仍优先 PXE 时再次进入破坏性安装。M4.1 必须增加“期望安装意图”与“观察到的 node_status”分离：

```text
NodeDeploymentControl {
  node_id,
  install_generation,
  consumed_generation,
  requested_at,
  requested_by,
  config_revision
}
```

- install profile 首次绑定且没有 control 记录时视为 generation 1 已 armed；只有当前
  `install_generation > consumed_generation` 才可由 boot resolver 下发 installer target。
- generation 在收到已认证 `install.started`、即进入可能擦盘的阶段时标记 consumed；仅 DHCP/TFTP/answer
  获取失败不会消耗意图。`node_status` 继续是不可倒退的观察投影，retry 绝不把 completed/failed 历史改写为
  `dhcp_discover`。
- `nodeforge install retry <node>` 只允许 install profile 且当前无活动 install session。它在没有 pending
  generation 时递增并持久化 generation，写一次 `install.retry.requested`；重复调用看到 pending generation
  时返回同一个 generation，因而具有操作幂等性。命令不重启/BMC 唤醒节点，也不伪称安装已经开始。
- 默认 `reinstall_policy=explicit`：已 consumed 且没有新 generation 的节点再次 PXE 时进入受控 wait/
  local-disk handoff，不下发 installer kernel/initrd，并记录 `boot.install_not_armed`。若平台尚无可靠 local-disk
  handoff，宁可停在 wait，也不能再次擦盘。
- 可选 `ProfileSafetyConfig.reinstall_policy=always` 只允许显式 destructive install profile，并在 validate/plan
  中给出高风险提示；它只在上一 attempt 已终态且观察到新的物理 boot attempt 时创建 generation，DHCP
  renewal/retransmit 或同一 BootSession 的重复 RRQ 不得创建。不得增加可长期遗忘的
  `node.overrides.force_reinstall=true`，临时重装统一使用 retry/rearm 操作。
- 活动 session 期间 retry 返回 409 `install.session_active`；M4.1 不提供
  `nodeforge install retry <node> --force`，也不赋予任何 install 命令“强制终止正在运行安装器”的语义。
  终止/BMC 控制与有预算自动重试留给 M7。
- deployment-control 先原子持久化 generation，再追加 `install.retry.requested`；持久化失败时命令失败且不能
  只写 event/只改内存。boot resolver 使用持久 snapshot，daemon 重启后 pending/consumed 语义保持不变。
- M4.1 在 EventType 注册表显式增加 `install.retry.requested`、`boot.install_not_armed` 和
  `install.configuration_drifted`；它们由服务端/管理操作产生，installer DTO 不得伪造。

无盘 profile 的正常语义本来就是每次开机进入 rootfs，不复用破坏性 install generation。`diskless retry` 若在
M5 提供，只负责解除失败隔离/重新允许下一次无盘启动，不能在 M4.1 预先实现或声称会远程重启节点。

#### 9.10.12 已部署节点的配置漂移与生效方式

每次安装计划记录 `config_revision`、normalized target-system digest、install source/storage digest，并在
`install.completed` 后保存为该节点的 `applied_revision`。之后修改配置只改变 desired state，不直接修改已经
安装到磁盘的系统：

- `node.overrides.network`、`system.users`、password/sudo/key、`system.packages`、locale/timezone/keyboard、
  SSH/firewall/SELinux 的修改，在下次显式 reinstall 或 M7 reconciliation/firstboot 前不会自动生效。
- install source、storage、partition 或 bootloader 变化只能通过新的 install generation 重装，M7 不得把它们
  伪装成在线同步。
- 离线 `config validate` 只验证新快照自身，不能声称知道“字段发生了变化”；`config diff/apply`、`node update`
  和 `profile show --resolved` 在能读取 applied revision 时输出 drift warning、受影响节点和建议动作。
- 配置变化不得自动 arm install generation，尤其网络/password 变化不能触发意外擦盘。操作员显式执行
  `install retry` 后，generation 固定引用当时的 config revision；开始 PXE 前 revision 已变化则要求重新确认，
  不能悄悄使用另一份 destructive plan。

M4.1 只承诺“识别并展示 drift + 可通过显式重装应用”。不重装的目标系统 reconciliation、失败回滚和逐字段
支持矩阵归 M7；无盘节点则在 M5 每次启动重新解析 desired state，但 rootfs build-time users/packages 变化仍
要求新 rootfs/boot bundle。

#### 9.10.13 DHCP lease、BootSession 与安装 token 边界

DHCP lease 和 BootSession delivery TTL 是两种生命周期，不能相互冒充：

- M2 按 §7.3 下发 option 58/59，客户端正常续租；不以未经验证的“installer 一定不续租”为前提，也不为
  install profile硬编码 3600 秒 lease。
- 无 header 的 bootstrap proof 只在 node、peer IP、当前 BootSession 和仍有效/未被重分配的 DHCP lease 唯一
  一致时成立。lease 过期后不能仅因 peer 仍使用原 IP 就继续 bootstrap，否则 IP 重用会越权。
- answer/boot config 首次 bootstrap 成功后签发 capability；随后 event/rootfs 等请求使用 token，在 delivery
  TTL 内独立于 DHCP lease 是否续租。每次成功的合法请求按单调时钟续期，过期/superseded 返回
  `409 session_inactive`。
- capability 只在当前 daemon 内存中存在；daemon 重启后不能恢复。M4.1 late/error commands 只使用当前
  installer session 的 header token。重启造成的上报缺口由 trace 明确显示，不伪造 completed。
- 本地盘 firstboot 的普通 DHCP 不能自动等价为可信 PXE/installer session。M7 若需要跨重启上报，必须设计
  单独的一次性 enrollment/attestation，而不是依赖“新 lease 自动拿 token”。

#### 9.10.14 answer 预览与实际渲染的一致性

`install render` 与实际 `/answer` 的一致性按语义和 session 两层定义：

- 活动 boot session 下的 render/answer 复用同一 `(daemon_instance_id, boot_session_id, config_revision,
  account)` 派生结果，因此同一 session 重试必须字节稳定。
- 没有活动 session 的 `install render` 是 preview：使用注入的 preview-only 临时 salt，并在 human/stderr 元数据
  明确 `password_hash_scope=preview`；不得使用全项目固定测试 salt，也不得把提示文字混入 YAML/Kickstart body。
- preview 与未来真实 answer 的 `$6$` 字符串不保证相等，但必须使用同一算法、相同 normalized plan，且 parser/
  schema/ksvalidator 结果一致。CLI 同时输出非 secret `config_revision`/plan digest，便于确认其余内容漂移。
- fixture 可注入固定 hasher 以获得 golden output；生产 preview 和 session renderer 不使用 fixture salt。

#### 9.10.15 M0–M4 横切补丁的归属与 M4.1 门槛

下列问题确实会影响 M4.1 闭环，但实现责任写回原有子系统，避免把协议和存储逻辑塞进发行版 adapter：

| 问题 | 主归属 | M4.1 交付关系 |
| --- | --- | --- |
| TFTP option/TID/ERROR/超时边界 | M1 §6.3 | M4.1 回归必须通过，不新增 adapter 逻辑 |
| DHCP T1/T2、pool/probe/identity/discovery 切换 | M2 §7.3–7.4 | 长时间安装前置补丁 |
| TTL 单调时钟、UTC 回拨与 trace 顺序 | M2.5.1 §7.5.12.5 | trace 不得因时钟回拨伪造时序 |
| node-status 容量 | M3.1 | 保持 `max_statuses=256`；满时拒绝新投影并记录 capacity event，不覆盖旧节点 |
| runtime asset 丢失/变化 | M3 §8.3.1 | answer/repo/ISO 请求得到稳定错误，不发送错误文件 |
| ISO 空间预检、orphan/mount 清理 | M3 §8.4 | 重复 Ubuntu/Rocky 导入和失败恢复列入验收 |
| catalog snapshot 与进行中传输 | M3 §8.8 | 旧 fd/revision 完成，新 snapshot 只影响新请求 |

M4.1 完成定义因此包含两部分：§9.10 的 target-system/answer/lifecycle 实现，以及上表历史补丁的回归通过。
它不把 HTTP 限流、长期容量规划、自动重试、diskless 下载器或 firstboot reconciliation 提前实现。

#### 9.10.16 M4.1 收口复核与强制修复项

2026-07-13 在 Ubuntu 22.04 与 Rocky 9.7 正向实机安装完成后，再次按异常恢复、显式覆盖和审计语义复核
实现。正向安装成功不替代以下负向与边界验收；这些问题仍属于 M4.1，修复前不得仅因双 adapter 实机通过
而把 M4.1 标记为完整完成：

- `deployment-control.json` 除不存在外的读取、schema 或内容错误必须 fail closed。daemon 不得忽略损坏状态
  并重新为 install 节点创建 generation 1，否则已安装节点可能重新获得破坏性安装授权。
- pending generation 绑定的 config revision 变化后，PXE 必须继续拒绝旧计划；操作员再次执行
  `install retry` 时必须显式确认当前 revision，并原子替换 pending generation，不能返回旧 generation 后永久卡住。
- `reinstall_policy=always` 仍须经过 generation。它只能在上一 attempt 已终态且新的 DHCP DISCOVER 创建新
  BootSession 时自动 rearm；REQUEST/renewal、同 XID 重传、活动 installer session 和重复 RRQ 均不得绕过。
- `install retry` 的幂等请求只在真正创建或替换 generation 时写 `install.retry.requested`；事件记录实际
  generation、config revision、请求时间和本机操作来源。deployment control 同步持久化 requested_at/by。
- `local-only` profile 引用的 repository URL 必须是当前 NodeForge `server.server_ip:http_port` 下的受管
  `/repos/` 路径；声明外部 HTTP(S) mirror 时返回 `ExternalEndpointForbidden`，不能把 catalog URL 原样写入 answer。
- `time_sync=true` 必须把全部显式 `ntp_servers` 写入 Ubuntu 与 Rocky 目标配置，并关闭 vendor fallback；
  `time_sync=false` 才完全禁用对应服务。`interface` 与 `search_domains` 必须被双 adapter 消费或在 validate 阶段
  明确拒绝，不能接受后静默忽略。
- desired/applied drift 必须至少通过管理 status 与 `install.configuration_drifted` 可见；它只 warning，不自动
  rearm。事件注册表、deployment state 和 CLI/API 输出必须使用同一 revision 事实。
- preview 使用每次命令独立的 preview salt scope，并输出 `password_hash_scope=preview`、config revision 与
  normalized plan digest；不得继续使用全项目固定占位 session 派生 hash。
- bootstrap public key 按 `(algorithm, decoded key blob)` 去重；generated key pair 使用临时文件、权限收紧、
  fsync/rename 或等价原子流程，并验证 public/private pair。只存在损坏或不匹配的持久 key 时必须失败。
- package availability 在 catalog metadata 可判定时部署前失败；不可判定时 plan 明确
  `availability=installer-media`。Ubuntu answer 进入固定版本 YAML/schema 回归，Rocky answer 进入目标版本
  ksvalidator/Anaconda 回归，不能只保留字符串包含断言。

## 10. M5：内存无盘启动与基础后处理

### 10.1 目标

实现 NodeForge 小 initrd + HTTP rootfs 的无盘启动闭环，并复用 M4.1 的 TargetSystemConfig，将 locale、
timezone、keyboard、离线策略、SSH/root、普通用户、额外包与节点网络以“公共 rootfs + 节点 overlay”方式
落地。M5 不在启动时创建通用账号或安装包，账号骨架和软件依赖必须在 rootfs build 阶段解决。

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
| `profile/system.zig` | 复用 M4.1 已归一化的 TargetSystemConfig，生成 rootfs capability 需求和无盘 overlay 计划 |

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
  -> GET boot config (bootstrap proof)
  -> keep session/token only in memory
  -> POST diskless.initrd_started (capability proof)
  -> inspect partial rootfs and download with HTTP Range
  -> verify sha256
  -> mount squashfs lower
  -> mount tmpfs upper with configured size
  -> mount overlay merged
  -> apply target system config to overlay (locale/timezone/network/SSH/firewall/SELinux)
  -> write /run/nodeforge/boot.json
  -> switch_root merged /sbin/init
```

rootfs 下载支持断点续传：

- 临时文件使用 `<sha256>.part`，同时保存期望 URL、size、ETag 和已下载字节数。
- 同一次 initrd 启动中发生网络中断并恢复后，以 `Range: bytes=<offset>-` 和 `If-Range: <etag>` 继续；服务返回 `206` 才追加。纯内存无盘节点重启后 partial 会丢失，因此不承诺跨重启续传。
- 服务返回 `200`、ETag 改变、长度不符或局部文件超过目标大小时，从零覆盖下载。
- 完成后必须校验完整 SHA256，再原子改名；hash 不匹配删除或隔离 partial，绝不挂载。
- tmpfs 容量校验必须同时考虑 rootfs partial 文件和 overlay 上层，容量不足时在下载前明确失败。
- 每个 rootfs 请求都携带 BootConfig 给出的 `Authorization: Bearer` 与 `X-NodeForge-Session` header；不得把
  token 放入 rootfs URL、`/proc/cmdline`、partial metadata、下载日志或持久 rootfs。发生 401/403/409 时停止
  下载并保留本地安全错误，不尝试降级为未认证下载。

下载超时、重试与完整性失败使用固定首版策略：

- TCP connect 10 秒、单次无进展 30 秒、单次请求 10 分钟；整个 rootfs attempt 最长 30 分钟。超时使用单调
  时钟，收到有效 body 字节才算进展，event 上报不能刷新下载 deadline。
- DNS 不进入 MVP；BootConfig/rootfs URL 必须是 NodeForge server IP。网络超时、连接重置和 500/502/503/504
  最多重试 5 次，退避 1/2/4/8/16 秒并加入有界 jitter；429 仅按不超过 30 秒的 `Retry-After` 重试。
- 400/401/403/404/409 为配置、授权或 session 终态，不自动重试；416 只允许清除不一致 partial/metadata 后从
  0 重试一次。服务器返回 200 代替期望 206、ETag 改变或 Content-Range 不连续时同样安全重置，不能追加。
- 完整 SHA256 不匹配时删除当前 partial，写 `diskless.rootfs_hash_mismatch`，并从 0 重新下载至多一次；第二次
  仍不匹配立即进入 `diskless.failed`。不得继续挂载、不得把坏文件保留为下次 Range 基础。
- ISO 下载属于 M3 的 `/images`/installer 链路，不混入 M5 initrd retry 策略；安装器自身超时只能通过 M3
  Range/日志和 M4 error event 观察，NodeForge 不替发行版 installer 实现下载循环。

小 initrd 只上报注册的 `diskless.*` 状态：启动、rootfs 下载开始、校验完成、挂载完成、切根开始、
运行成功或失败。每次请求由 M3 的 node event DTO 限制为 stage、reason、rootfs 名称/校验摘要等小字段；
失败摘要不得包含下载 URL query、Authorization、完整 dracut journal 或 debug shell 输出。`node_status` 与
event 的更新顺序遵循 §8.6，断网时 initrd 只保留本地失败信息，不因为事件上报失败而中断已完成的切根。

`/run/nodeforge/boot.json` 只保存 node/profile/rootfs/event URL 等非 secret 元数据，权限为 0600，且不保存
capability token；initrd 在成功 `switch_root` 前清零内存中的 token。M5 不绕过 M3 的认证、状态机或
EventWriter，也不因为 session 失效重建一个伪造的 boot session。

### 10.5 overlay 规则

- `overlay.tmpfs_size` 必须传给 tmpfs `size=`。
- `/var/log`、`/tmp` 等高写入路径先作为配置位，不强制 MVP 单独挂载。
- 持久化 overlay 不进入 MVP。
- rootfs 公共修改使用 `rootfs_build`；节点差异使用 `diskless_boot` 写入 overlay upper。两者复用 M4 的 provisioning runner。

### 10.6 无盘目标系统配置

M5 复用 §9.10 的 `TargetSystemConfig` 和 `NodeOverrideConfig.network`，但落地时机与自动安装不同：自动安装
由 installer 写目标磁盘；无盘节点共享只读 squashfs，所以通用依赖在 rootfs build 阶段写入，profile/node
差异在每次启动的 overlay upper 中写入。initrd 不理解 locale 包、用户创建或软件仓库，只执行服务端已经
归一化并经过 boot bundle 能力校验的有限计划。

#### 10.6.1 构建期与启动期边界

| 内容 | rootfs build（公共 lower） | diskless boot（节点 upper） |
| --- | --- | --- |
| locale 数据包、tzdata、keyboard 数据 | 安装并生成支持矩阵 | 只选择已存在 locale/timezone/keyboard |
| OpenSSH server 二进制/unit | 从本地 repo 安装 | 写认证策略、authorized_keys，生成 host key |
| `system.packages` | 从本地 repo 安装并记录 manifest | 校验 manifest 后禁止调用 apt/dnf 安装 |
| `system.users` 账号骨架 | 创建 passwd/group/home/shell 和 sudo/wheel membership，不写 profile 密码/key | 写每账号 password hash 和 authorized_keys |
| 外部 repository | 删除、禁用或替换为 NodeForge 本地源 | 不新增源 |
| hostname | 保留通用占位 | 写节点 hostname |
| 网络 | 保留 DHCP bootstrap 能力和 NM/Netplan | 写目标 DHCP/静态持久配置 |
| machine-id、SSH host key | 清理，不在共享 lower 保留唯一身份 | 每次启动在 upper 生成 |
| root/用户 key | 不放节点专属 key 或 NodeForge bootstrap private key | 从受认证 BootConfig 写入 bootstrap public key + 对应账号 profile keys |

`RootfsBuildConfig` 必须记录 `packages`、`generated_locales`、`available_timezones`、`available_keyboards`、
`available_users`、账号 sudo/wheel membership 和系统 capability，例如 `openssh-server`、`netplan` 或
`NetworkManager`。发布 boot bundle 时把 profile 的 TargetSystemConfig 与 rootfs manifest 对照：自定义
locale/timezone/keyboard、用户或包不存在，SSH enabled 但无 sshd，静态网络缺对应 renderer/tool 时拒绝
publish，不能等节点切根后才失败。

`system.packages` 是共享目标系统事实，但在无盘链路只作为 rootfs build 输入和发布校验需求，不授权 initrd
安装。若两个 diskless profile 需要不同包集合或账号骨架，应发布两个不同版本的 rootfs/boot bundle；不得在
每次启动时联网安装/创建通用账号，也不得修改共享 lower rootfs。

#### 10.6.2 BootConfig 扩展

diskless BootConfig v1 增加经过归一化的 `target_system` 和 `required_features`。这是向后兼容的 JSON 字段
扩展，但 boot bundle manifest 必须声明 initrd 支持 `target-system-v1`；旧 initrd 未声明该 feature 时，
引用含 system override 的 profile 必须校验失败，避免旧客户端静默忽略配置。

```json
{
  "schema_version": 1,
  "mode": "diskless",
  "required_features": ["target-system-v1", "static-network-v1", "sha512-crypt-v1", "bootstrap-admin-key-v1", "target-accounts-v1"],
  "target_system": {
    "localization": {
      "locale": "en_US.UTF-8",
      "timezone": "Asia/Shanghai",
      "keyboard": "us"
    },
    "connectivity": {
      "mode": "local-only",
      "time_sync": false,
      "ntp_servers": []
    },
    "network": {
      "mode": "static",
      "match_mac": "00:50:56:aa:bb:cc",
      "address": "192.168.27.27",
      "prefix_len": 24,
      "gateway": "192.168.27.128",
      "dns": ["192.168.27.128"],
      "search_domains": ["nodeforge.local"]
    },
    "ssh": {
      "enabled": true,
      "password_authentication": true,
      "root_login": "yes",
      "root_password_hash": "<distro-compatible hash of asdf1234>",
      "root_authorized_keys": ["ssh-ed25519 AAAA... admin@example"]
    },
    "users": [
      {
        "name": "ubuntu-server",
        "password_hash": "<distro-compatible hash>",
        "sudo": true,
        "ssh_authorized_keys": ["ssh-ed25519 AAAA... admin@example"]
      }
    ],
    "packages": ["curl", "vim"],
    "security": {
      "firewall": "disabled",
      "selinux": "disabled"
    }
  }
}
```

BootConfig 只能包含 M4.1 PasswordHasher 已经派生的 `$6$` password hash，不得包含 profile 中的明文 root 或
普通用户 password。`users` 只能引用 rootfs manifest 已声明的账号，`packages` 只用于断言已构建能力，initrd
不得据此调用包管理器。root/普通用户 authorized keys 已包含 ServerAdminKeyProvider 的 bootstrap public key 与各自
profile keys，并按 key blob 去重；NodeForge bootstrap private key 永远不下发。公共 key 可以下发，其他
private key 永远不进入配置模型。`target_system`、token 和 answer body 不得写入 access log 或 Event；
事件只记录 locale/timezone/network mode/SSH enabled 等非 secret 摘要。`/run/nodeforge/boot.json` 继续不保存
token 和密码 hash，只保存已应用配置的 digest 与非 secret 摘要。

#### 10.6.3 locale、timezone 和离线策略

initrd 将已验证值写入 merged rootfs：Ubuntu 使用 `/etc/default/locale`、`/etc/default/keyboard`、
`/etc/timezone` 和 `/etc/localtime`；RHEL 系使用 `/etc/locale.conf`、`/etc/vconsole.conf` 和
`/etc/localtime`。timezone 通过
指向 rootfs 已有 `/usr/share/zoneinfo/<timezone>` 的链接设置，不从网络下载 tzdata。locale 未在 rootfs manifest
声明时启动前由服务端拒绝 BootConfig，而不是在 initrd 中运行 `locale-gen` 猜测依赖。

`local-only` 在无盘链路中要求：rootfs 不保留发行版公网 mirror/metalink/vendor NTP 默认值；启动时不执行
update/upgrade/package install；time sync 关闭或只使用显式 servers；NodeForge initrd 只访问 BootConfig、rootfs
和 event 的 server IP。与 M4.1 一样，这是一项生成配置契约，不替代部署网出口 ACL。

#### 10.6.4 无盘静态网络

initrd 为获取 BootConfig/rootfs 始终先使用 DHCP。M5 的目标静态地址沿用 M4.1 约束：必须等于该 MAC 的
`node.ip` reservation。initrd 下载完成后不主动 down/up 网卡，也不把连接切换到另一个地址；它只在 overlay
中生成 Ubuntu Netplan 或 RHEL NetworkManager keyfile。`switch_root` 后目标网络服务接管相同地址，因此不会
打断已有 NodeForge 路径。

按 MAC 匹配失败、地址与 DHCP lease 不一致或生成文件校验失败时，initrd 在切根前进入
`diskless.failed`，不能回退到不可预测的 DHCP 目标系统。未来需要 PXE 阶段纯静态、VLAN、bonding、多个 NIC
或下载后切换不同子网时，作为 M6 initrd 网络能力单独设计。

#### 10.6.5 无盘 SSH 身份

共享 rootfs 绝不能内置同一组 SSH host private keys。rootfs build 删除 `/etc/ssh/ssh_host_*`；initrd 或
firstboot unit 在 overlay 中执行 `ssh-keygen -A`，确保每次实例至少具有独立 key。MVP 没有持久 overlay 或
secret backend，因此重启后 host key 会变化，CLI/status 必须展示该限制和当前 fingerprint，不能把共享 host
key 当作“稳定体验”的捷径。持久 host identity 留到后续 secret/persistent-overlay 设计。

目标节点 sshd host key、NodeForge bootstrap admin client key 和 profile authorized key 是三个独立概念：
M5 只能把后两者的 public key 写入账号 `authorized_keys`；不得把 NodeForge generated private key 当作目标
host key，也不得把目标节点临时生成的 host private key 回传或复制到其他节点。

root password hash、root key、`PermitRootLogin`、`PasswordAuthentication` 和 sshd enablement 复用 M4.1
语义，默认 root/`asdf1234` 在无盘目标系统同样可登录。若 SSH enabled 但
rootfs manifest 缺少 sshd，或所有登录入口均不可用，boot bundle/profile 校验失败。每个 `system.users`
账号必须由 rootfs build 创建 passwd/group/home/shell 和 sudo/wheel membership；overlay 再逐账号写入派生
password hash 与 bootstrap+profile authorized keys。账号不存在、重复、membership 不符或 home 不可写时在
发布/启动前失败，initrd 不运行通用 useradd/usermod 脚本。

防火墙默认在 rootfs build 阶段禁用对应 unit，并在 overlay 保持 profile 选择。RHEL 系无盘 profile 默认
SELinux disabled 时，boot resolver 必须追加 `selinux=0`，同时 overlay 写入 `/etc/selinux/config`；内核已经
启动后只改配置文件不能关闭本次启动的 SELinux。Ubuntu 不追加该参数，也不关闭 AppArmor。

#### 10.6.6 M5 配置测试与验收补充

- rootfs manifest 缺 locale、timezone、keyboard、`system.packages`、`system.users` 账号骨架、OpenSSH 或网络工具时，boot bundle publish 明确失败。
- BootConfig 不含明文密码/private key，required feature 与 initrd manifest 不匹配时 profile 校验失败。
- overlay fixture 验证 Ubuntu/Rocky 的 locale、timezone、keyboard、hostname、DHCP/静态网络、sshd drop-in、
  每账号 shadow hash/authorized_keys 和 sudo/wheel 归属。
- 抓包确认无盘启动只访问 NodeForge server 和显式本地 NTP，不访问发行版 mirror、GeoIP、vendor NTP 或更新服务。
- 静态目标地址与 DHCP reservation 相同，切根前后 rootfs/event 请求不中断；不同地址配置被拒绝。
- SSH server 默认启用，root 默认以 `asdf1234` 支持密码登录；共享 lower 不含 host private key，各节点运行
  实例 fingerprint 不同。
- bootstrap admin public key 与 root/普通用户各自 profile keys 在 overlay 中始终合并并去重；BootConfig 和
  rootfs 不含 bootstrap private key，daemon 重启后 generated bootstrap fingerprint 稳定。
- firewalld/UFW 默认关闭；RHEL 系 cmdline 含 `selinux=0` 且切根后 `sestatus` 显示 disabled。
- `system.packages` 在 rootfs build 后可用，`system.users` 均可按各自密码/key 登录且 sudo 归属正确；启动
  overlay 不调用 apt/dnf/useradd/usermod，离线重启仍能进入 `diskless_running`。

### 10.7 CLI 命令

```bash
nodeforge rootfs package rocky-9.7-aarch64 --format squashfs --version 20260706
nodeforge rootfs validate rocky-9.7-aarch64-<kernel-release>-diskless-20260706.squashfs
nodeforge initrd validate diskless/rocky/9.7/aarch64/<kernel-release>/initrd-nodeforge.img
nodeforge boot-bundle publish rocky-9.7-aarch64-<kernel-release>-diskless-20260706 --kernel rocky-9.7-aarch64-kernel --initrd rocky-9.7-aarch64-nodeforge-initrd --rootfs rocky-9.7-aarch64-rootfs-20260706 --repo rocky-9.7-aarch64-dvd
nodeforge diskless overlay update rocky-9.7-aarch64-diskless --tmpfs-size 50%
nodeforge diskless status node-02
nodeforge diskless retry node-02
```

`diskless retry` 只对 `diskless.failed`/服务端 failure quarantine 生效：清除该节点的失败隔离并允许下一次 PXE
再次进入同一 diskless profile，重复调用幂等。它不回退历史 node_status、不创建 install generation、不远程
重启节点；节点当前仍有活动 diskless session 时返回 409。下载器在同一次 initrd 内的有界网络重试不需要 CLI
retry，只有 attempt 已终态失败后才需要操作员重新 arm。

### 10.8 测试

- boot bundle 一致性校验。
- rootfs 缺少 `/sbin/init` 报错。
- rootfs `/lib/modules` 与 kernel_release 不匹配报错。
- overlay tmpfs size 解析。
- initrd 上报 diskless 事件、断网时事件失败不阻断切根、失败摘要长度限制。
- QEMU UEFI diskless smoke test。
- TargetSystemConfig（含 users/packages）/rootfs capability/BootConfig required_features 和 overlay 文件 fixture。

### 10.9 阶段验收

- 节点能 PXE 进入小 initrd。
- 小 initrd 能拉取 boot config。
- rootfs 下载和 SHA256 校验通过。
- `squashfs_overlay` 挂载成功并 `switch_root`。
- `nodeforge node status` 显示 `diskless_running`。
- profile locale/timezone/keyboard、普通用户/sudo/逐账号 key、离线 SSH 策略和节点 DHCP/静态网络在 merged rootfs 生效。
- 无盘启动阶段不创建账号、不安装包、不访问未声明公网端点；rootfs 的 `system.users/packages` 由 build manifest 可追溯。

## 11. M6：支持矩阵增强

### 11.1 目标

完善 MVP 周边兼容性和诊断能力。

### 11.2 M4.1 基线继承

M6 只扩展架构、发行版版本和 bootloader，不得为新 adapter 建立第二套目标系统默认值。新增的 x86_64、
Ubuntu 后续 LTS、RHEL 系变体和 BIOS PXELINUX 路径均必须复用 M4.1 的归一化 TargetSystemConfig，并满足：

- 字段省略时仍默认 `en_US.UTF-8`、OpenSSH enabled、password authentication enabled、root login `yes`、
  root password `asdf1234`、主机防火墙 disabled；RHEL 系 SELinux 默认 disabled。
- `connectivity=local-only` 时不得生成公共 mirror、DNS、NTP、geoip 或脚本下载端点；新增 adapter 必须有
  网络抓包或等价的无外联验收。
- PXE/initrd bootstrap 继续使用 DHCP；目标静态 IPv4 仍要求 `address == node.ip`，多 NIC、VLAN、bonding
  如在 M6 增加，必须显式建模，不能恢复含糊的 `inherit`。
- BIOS PXELINUX 只改变 bootloader 和配置查找方式，不改变目标系统的账号、SSH、防火墙、SELinux、包或
  网络策略。
- 新 adapter 必须直接消费 normalized `system.users` 和 `system.packages`：自动安装映射到发行版安装器，
  无盘映射到 rootfs build/capability 与 overlay；不得新建 adapter 私有 users/packages 字段。
- 新 adapter 必须复用 SHA-512 crypt `$6$`、password 明文事实源、bootstrap admin public key 始终合并和
  逐账号 key 归属；不得恢复明文 answer、裸 SHA 摘要、预哈希前缀猜测或复制 private key。
- Subiquity 26.04+ 的 `identity.groups`、earlier user creation 等新能力只在对应版本 capability 中启用；
  Ubuntu 22.04/24.04 fixture 不得因为 latest reference 已更新就接受未随该 install source 交付的字段。
- 每个新 adapter/version fixture 必须覆盖默认配置和至少一组显式覆盖；不满足 M4.1 公共验收的版本不能
  标记为支持。

### 11.3 任务

- Rocky Linux 9.x 优先的 RHEL 系 kickstart 版本能力表。
- x86_64 生产验证记录和 aarch64 真机/QEMU PXE 验证记录。
- BIOS x86 + PXELINUX 链路。
- 安装错误分类。
- ISO/repo/rootfs 资产更完整校验。
- HTTP/TFTP 连接、fd、worker 与 per-client 限流的目标机压测；根据结果固化上限和 429/503 行为。
- `events.jsonl` 轮转总量、node-status/lease 上限、work orphan、catalog/assets 长期占用和磁盘告警基线。
- preview/active-session answer 的 normalized plan digest 对比和跨版本 renderer 漂移诊断。
- Proxy DHCP spike。
- Secure Boot 风险评估。

### 11.4 BIOS PXELINUX

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

### 11.5 错误分类

错误类型：

- `dhcp.no_available_lease`
- `tftp.asset_not_found`
- `http.asset_not_found`
- `http.asset_hash_mismatch`
- `catalog.insufficient_space`
- `install.answer_render_failed`
- `install.storage_invalid`
- `install.bootloader_failed`
- `diskless.rootfs_hash_mismatch`
- `diskless.switch_root_failed`

这些 error code 既是 CLI/状态显示的稳定分类，也是 `install.failed`、`diskless.failed` 等 v2 event 的
`reason` field 值；不要把自由文本错误或 Zig error tag 当作跨版本事件字段。

错误分类同时给出 retry 建议，但建议不直接执行破坏性动作：

| reason | 默认 retryability | 操作 |
| --- | --- | --- |
| `dhcp.no_available_lease` | transient | 等 lease 回收/修复 pool；客户端 DHCP 可自行退避 |
| `tftp.asset_not_found` | blocked | 修复并重新 validate/publish asset 后再 PXE |
| `http.asset_not_found` | blocked | 修复 catalog/file 一致性后重新发布；不在请求路径自动重建 |
| `http.asset_hash_mismatch` | blocked | quarantine 资产，重新导入；禁止继续发送 |
| `catalog.insufficient_space` | operator | 清理/扩容对应 filesystem 后重新 import，不删除已发布对象 |
| `install.answer_render_failed` | config | 修复 profile/schema；不得自动重装 |
| `install.storage_invalid` | config/destructive | 人工确认目标盘后显式 `install retry` |
| `install.bootloader_failed` | operator | 检查固件/目标盘；显式 retry，不默认自动擦盘 |
| `diskless.rootfs_hash_mismatch` | bounded-transient | M5 同 attempt 从 0 重试一次；重复失败后修复 bundle |
| `diskless.switch_root_failed` | blocked | 修复 initrd/rootfs capability 后再次 diskless retry |

CLI/status 输出 `retryability`、`suggested_action` 和 attempt/generation，但 Event.reason 仍只保存稳定 reason。
M6 不因某 reason 自动执行 install retry；M7 的自动策略仍受 §12.9 预算和破坏性边界限制。

### 11.6 配置管理与长期运行收敛

把此前路线图中未落地的 `config diff/apply` 收敛到 M6 运维增强，而不新增无编号阶段：

- `config diff` 对两个完整快照做纯只读、secret-aware 的结构 diff，并按 restart-required、runtime-applicable、
  redeploy-required、M7-reconcile 四类展示影响；password 只显示 changed，不打印旧值/新值。
- `config apply` 先构造 candidate、完整校验和引用检查，再原子写盘/替换内存 snapshot 并写
  `config.updated`。server bind/subnet/root path 等结构字段只落盘并返回 restart-required；DHCP discovery policy
  和已明确支持的 catalog/runtime policy 才在线切换。
- apply 不自动 arm install generation、不清除 failure、不重启节点。对 completed 节点调用 §9.10.12 的
  desired/applied drift 分类；需要重装的变更由操作员另行执行 `install retry`。
- 多节点并发渲染只读取 immutable config/catalog snapshot；每个 request 的 node/session/hasher/plan 独立，
  status store 使用节点粒度或短时 mutex，慢速下载/renderer 不持有全局写锁。压测覆盖 apply 与 100 个下载/
  多节点 answer 并发，证明旧请求完成于旧 revision、新请求只见新 revision。
- 生产容量验收记录 events 保留上界、状态/lease 固定容量耗尽行为、work orphan 清理、asset filesystem
  low-watermark 和导入空间预检；容量不足返回稳定错误，不删除已发布/活动对象。

## 12. M7：补充包和后处理增强

### 12.1 目标

M4/M5 已交付 repository、standard-packages、managed-file 和统一 runner。本阶段补齐 archive、script、firstboot、CLI plan/status 和三条链路的完整回归。这里的“配置可视化”是指 CLI 按阶段、步骤和执行结果清晰组织输出，不引入 Web UI 或通用低代码配置系统。

M7 不获得绕过 M4.1/M5 目标系统策略的权限。`profile.system` 与 `node.overrides.network` 是 locale、
timezone、keyboard、连接策略、SSH/root、普通用户/password/sudo/key、目标系统额外包、防火墙、SELinux
和目标网络的权威事实源；bundle 只能补充业务内容。

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

保护规则：

- `managed_file`、archive 内文件、`install.sh` 和自定义 script 不得静默覆盖由 TargetSystemConfig 管理的
  passwd/shadow/group/sudoers、sshd、各账号 `authorized_keys`、netplan/NetworkManager、resolver、
  locale/timezone/keyboard、package manifest、firewall 或 SELinux 文件与 unit。
- action 必须声明影响域；触及上述保护域的 bundle 在 M7 校验阶段直接拒绝。未来若确需覆盖，应增加显式、
  可审计的 policy override action，不能借助通用 script 绕过。
- runner 在 `install_post`、`rootfs_build`、`diskless_boot` 和适用的 `firstboot` 步骤之后执行目标系统
  finalizer，重新断言 M4.1 默认值/显式覆盖、用户/sudo/package 归属、bootstrap/profile public key 合并和
  逐账号 key 归属并产出摘要；finalizer 失败则该阶段失败。
- local-only 下 archive、script 和包只能引用已发布的本地 catalog/repository；运行期隐式下载一律失败。
- 后续新增字段省略时继承 M4.1/M5 默认值，不得以兼容旧 bundle 为由恢复公网或弱化 root/SSH 策略。

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
8. 执行 TargetSystem finalizer，校验并固化 profile 的账号、SSH、网络、连接和安全策略。

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

### 12.9 已部署节点 reconciliation 与自动重试边界

M7 承接 §9.10.12 中“desired 已变化但目标系统尚未同步”的节点，但不能假设 firstboot 脚本能凭普通 DHCP
自动获得管理权限：

- 每个节点保存 applied target-system digest 和逐域状态。`provision plan --node` 将 drift 分为可在线同步、
  下次受认证 firstboot/agent 同步、必须重装和人工处理；没有可信 agent/enrollment channel 时保持 pending，
  不能声称已应用。
- root/普通用户 password hash、authorized_keys、sudo membership、sshd policy、locale/timezone/keyboard、
  firewall/SELinux 配置和增加 package 可进入受保护的 TargetSystem reconciler。删除用户/包、修改默认路由/
  SSH 管理入口属于高风险变更，默认只 plan；网络变更必须有连通性预检、原子文件和有界回滚。
- storage/partition/bootloader/install source 以及无盘 rootfs build-time users/packages 不在线 reconcile：前者
  需要新 install generation，后者需要新 rootfs/boot bundle。generic script 仍不能覆盖 protected domain。
- firstboot/agent 使用单独的一次性 enrollment 或已建立节点凭据换取短期 capability；不能把任意新 DHCP lease
  当认证，也不能复用已因 daemon/节点重启失效的 installer token。

自动重试分三层：

1. 单次 HTTP/step 的网络暂态错误按各阶段已有有界次数和退避重试，不创建新 boot/install attempt。
2. diskless failed 可按 profile 明确预算自动 rearm，例如 `max_attempts`、backoff 和 quarantine；策略不负责 BMC
   重启，达到预算后必须等待 `diskless retry`。
3. destructive install 在 `install.started` 后绝不默认自动重新 arm。只有显式启用的站点策略、可重试 reason
   allowlist、最大 attempt、冷却时间和审计全部满足时才能自动创建新 generation；storage/identity/config 错误
   永远要求人工修复。M7 的 `nodeforge provision ... --force` 只重跑已发布且声明幂等的 provisioning step，
   不等价于强制重装，也不是 §9.10.11 中被明确禁止的 `install retry --force`。两个命令域的 `--force` 不共享
   语义、状态机或授权，后续实现不得把 provisioning flag 透传给 install generation/installer 控制路径。

验收覆盖 retry budget、daemon 重启后的计数持久性、并发操作幂等、quarantine、网络回滚、用户/包删除默认拒绝，
以及任何自动策略都不能绕过 `reinstall_policy=explicit` 和 install generation 审计。

## 13. M8：部署链路健壮性、密钥可维护性与传输性能加固

### 13.1 目标

M4/M4.1 交付了 kickstart/autoinstall 渲染、受控 post-install provisioning 和安装生命周期事件上报。
本里程碑在不改变 M4.1 TargetSystemConfig 归一模型的前提下，修复部署链路的可维护性和传输性能。
post-install 命令的异常容忍语义保持现状不动，不在本里程碑范围内。详细设计见
`docs/superpowers/specs/2026-07-14-m8-provisioning-robustness-design.md`。

缺陷清单：

| # | 缺陷 | 根因 |
|---|------|------|
| F1 | 部署错误信息未传回 nodeforged | `/logs` 端点已实现但无模板调用；`reason`/`message` 从未被填充；失败仅发空 `{stage:"failed"}` |
| F2 | 无法对已匹配节点禁用 PXE 部署 | `NodeConfig` 无 deploy 标志；generation 机制仅覆盖 install 模式且无法阻止首次部署 |
| F3 | ISO 导入仅认 Rocky+Ubuntu | family 前缀硬编码 `Rocky`；不支持 RHEL 系变体与国产化 OS；`--distro` 是断言非覆盖 |
| F4 | TFTP 性能差 | 未实现 RFC 7440 windowsize；单线程串行；无性能配置项 |
| F5 | 免密公钥不可更新 | 公钥仅启动时解析一次、不覆盖已生成对 |
| F6 | CLI 命令体系结构不合理 | 13 个扁平顶层命令与文档定义的 resource-action 模型存在偏差 |

### 13.2 F2：节点级"不部署"开关

现有 generation 机制（`deployment_control.zig`）在默认 `reinstall_policy=.explicit` 下，首次部署成功后
确实不会再次进入部署（armed=null -> `install_not_armed` -> 无 bootfile）。已有 CLI `install retry` 覆盖
re-enable 方向。但 **disable 方向缺失**：无法标记"此节点永不部署但保留 MAC/IP 预留用于诊断"。
generation gate 仅作用于 install 模式，无法阻止首次部署（`ensureInitial` 无条件 arm gen 1），
无法覆盖 diskless/discovery 模式，且无 per-node policy override。

`NodeConfig` 新增 `deploy: bool = true`。`resolve()` MAC 命中后、mode 判定前加守卫：`deploy=false` 时返回
`bootfile=null, known=true, mode=null`，仍发诊断 DHCP lease 但不下发 PXE。`mode=null` 使 generation gate
被完全绕过。适用于 install/diskless/discovery 全模式。`deploy` 是硬外层开关，与 generation gate 互补不冗余。
新增事件 `boot.deploy_disabled`。

### 13.3 F1：安装阶段错误全覆盖传回

> Ubuntu Autoinstall 原生支持 HTTP webhook（`autoinstall.reporting` 的 `http` callback）；
> Kickstart/Anaconda 没有同等的 HTTP webhook，需要用 `%pre`、`%onerror`、`%post` 主动调用 HTTP API。

`/logs` 和 `/events` 端点已完整实现但 `/logs` 从未被模板调用，`reason`/`message` 从未被填充。
`answerFixture` 新增 `log_url` 构造（与 `event_url` 并行注入模板）。

- **Kickstart**：`%onerror` 增强为捕获 Anaconda traceback（`/tmp/anaconda-tb-*/anaconda-tb`）后 curl `/logs`，
  reason `install.anaconda_error`。`%pre`/`%post` 的 stage curl 保持不变。
- **Ubuntu**：`renderUserDataM41` 新增 `reporting:` 块声明 Subiquity 原生 `type: http` callback，指向新路由
  `POST /api/v1/nodes/:id/subiquity-report`（bearer token 通过 `headers` 注入）。`subiquityReport` handler 将
  Subiquity JSON 事件映射到 `install.*` 阶段（复用 `mapStage`）。`early/late/error-commands` 手写 curl 保留为
  降级路径。`error-commands` 增强：捕获 curtin env vars 填入 `/logs`，reason `install.subiquity_error`。

### 13.4 F3：ISO 导入支持主流 OS + 覆盖语义

RHEL 系 `.treeinfo` `family` 前缀白名单扩展为
`Rocky|CentOS|CentOS Stream|RedHatEnterpriseServer|RedHatEnterpriseLinux|AlmaLinux|Fedora|OracleLinux|ScientificLinux|CloudLinux|EuroLinux`，
加国产化 `openEuler|Kylin|Kylin Linux Advanced Server|TencentOS|TencentOS-Server|AnolisOS|UnionTech OS Server|UOS Server|npserver|TurboLinux|Sugon OS|BigCloud-Enterprise-Linux`，
全部归一到 distro `rocky`（复用 kickstart adapter），catalog 新增 `source_label` 记原始 family。
Ubuntu 沿用 `.disk/info`；Debian 新增检测，归一 `ubuntu`。

`--distro`/`--version`/`--arch` 语义从断言改为覆盖：指定时跳过自动检测直接采用（仍校验文件存在性和
支持矩阵）。未识别 ISO 且未指定 `--distro` 时返回友好错误提示 supported families 与 hint。

### 13.5 F4：TFTP 性能优化

- **windowsize (RFC 7440)**：`negotiate` 识别 `windowsize` option 回 OACK；DATA 循环改为发 `windowsize` 块
  后才等一个 ACK。处理 block number 回绕。
- **per-client 并发**：dispatcher 收到 RRQ 后 spawn 独立线程处理，主循环立即回接。上限
  `max_concurrent_transfers`，超限时返回错误让客户端退避。
- **配置项**：`TftpConfig` 新增 `max_blksize`（默认 1468）、`windowsize`（默认 16）、`timeout_seconds`
  （默认 3）、`max_concurrent_transfers`（默认 8）。客户端不协商时 OACK 主动建议 1468。
- HTTP 不改（已 sendfile + Range + 120s 超时）；`HttpConfig` 仅新增 `max_connections: u16 = 0`（M6 压测后固化）。

### 13.6 F5：免密公钥配置化

`ServerConfig` 新增 `ssh_authorized_public_keys: []const []const u8 = &.{}`（多公钥数组，全部注入去重）。
解析优先级：① config 数组 -> ② config 单值（向后兼容）-> ③ `state/bootstrap-ssh/*.pub` 目录扫描 ->
④ `/root/.ssh/*.pub` -> ⑤ 已生成 key -> ⑥ 生成新 pair。`state/bootstrap-ssh/` 现可存放多个 `*.pub` 文件；
配置中只接受相对 `state/bootstrap-ssh/` 的文件名。

CLI 接口见 §13.7 F6（`media key` 子命令，与 CLI 校准统一设计）。已装节点 authorized_keys 需重装或手动更新，
CLI 明确提示。

### 13.7 F6：CLI 命令体系校准

当前 13 个扁平顶层命令与文档定义的 CLI canonical form（`nodeforge <resource> [subresource] <action>`，
`DESIGN.md:1612-1628`）存在偏差：`runtime` 独立于 `dhcp`、`trace` 独立于 `node`/`events`、
`install-source` 与 `asset` 分离、`install` group 混杂 preview 和 mutation。

校准原则：**resource 即顶层，action 紧随其后，不引入 subresource 中间层**（保持最多 2 个命令词），
例外仅限逻辑上确实是子资源的（如 `media key`）。校准后命令树：

```
nodeforge [-v] <command> [options]

① status / check                                    (daemon health)
② config   <validate|export|import>                  (config files)
② catalog  <validate|export>                         (catalog files)
③ media import <iso-path> [--distro] [--version] [--arch]  (ISO import, online)
   media list / show <name> / validate               (install source + assets, offline)
   media key import <path> [--rename NAME]           (bootstrap public key, offline)
   media key reload / show / list                     (key management, mixed/online)
④ node list / show <id> / render <id> / retry <id> / trace <id>  (nodes & lifecycle)
⑤ dhcp show / leases / unknown                       (absorbs runtime)
   tftp show / sessions                              (sessions not session list)
⑥ events <list|follow|types>                         (audit)
```

`media key` 而非独立 `admin-key` 顶层：bootstrap key 与 install media 紧密相关（同 state 目录树、
用于登录已部署节点），避免新增第 14 个顶层命令。`media key <action>` 是 resource-subresource-action
三词结构（`media`=resource, `key`=subresource 限定, `import`/`reload`/`show`/`list`=action），
符合 canonical form 的 `[subresource]` 槽位。

`dhcp leases`/`dhcp unknown`/`tftp sessions` 省略 `list` 动词：单资源运行态查询只有一个 action，
加 `list` 会变 3 词。`events list` 保留 `list` 因 `events` 有多个 action 需区分。

迁移映射：`install-source import` -> `media import`；`asset *` -> `media *`（import 统一为 `media import --type`）；
`install render/retry` -> `node render/retry`；`trace` -> `node trace`；`runtime leases/unknown list` -> `dhcp leases/unknown`；
`tftp session list` -> `tftp sessions`。新增 `node show`、`media key *`。旧路径保留 deprecated alias（zli
`deprecated`+`replaced_by`）一个版本周期，执行时输出 warning。`buildCli` 拆分为按领域的 `register*Commands` 函数。

### 13.8 验收标准

1. Kickstart `%onerror` 触发时 -> `/logs` 收到 `install.anaconda_error` + summary（含 Anaconda traceback 截断）。
2. Ubuntu `reporting` 块 -> Subiquity 进度事件到达，`install.partitioning`/`packages` 等阶段可见。
3. `deploy=false` 节点 -> DHCP lease 存在但无 PXE bootfile，事件 `boot.deploy_disabled`；generation gate 被绕过。
4. openEuler/Kylin/CentOS/RHEL/Sugon OS ISO -> 导入成功，catalog distro=rocky，source_label 记原始 family。
5. `--distro rocky --version 9.7 --arch aarch64` -> 跳过自动检测。
6. TFTP windowsize=16 -> QEMU PXE 吞吐显著优于 windowsize=1。
7. `media key import` + `media key reload` -> `node render` 含新公钥；`media key show` 显示来源与 fingerprint。
8. `nodeforge node list/show/render/retry/trace` 可用；旧 `install render` 输出 warning 且仍执行。
9. `nodeforge dhcp leases` / `dhcp unknown` / `tftp sessions` 可用（旧 `runtime leases list` 输出 warning）。
10. 新 reason 值在 `event_types.zig` 注册、在 §11.5 错误分类表有 retryability 条目。
11. CLI 命令树符合 resource-action 模型：最多 2 个命令词（`media key import` 是唯一 3 词例外）。

### 13.9 M4.1 基线继承

M8 不获得绕过 M4.1 TargetSystemConfig 的权限。`profile.system` 仍是 SSH/root/users/password/locale/
防火墙/SELinux 的权威事实源。bootstrap admin key 合并去重规则（§9.10.6.2）不变，只是来源从单值扩展为
多值数组 + state 目录扫描。kickstart/autoinstall 渲染仍消费 normalized plan，adapter 不读 `/root/.ssh`
或 state 文件。post-install 命令的异常容忍语义保持现状，不在 M8 范围内。

## 14. 测试矩阵

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

## 15. 配置和事件兼容策略

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
- 新增 password 字段必须只表达普通明文字符串，import/export round-trip 保持原值；不得把 SecretRef、
  预哈希值或外部 secret backend 设为必填，也不得按 `$...` 前缀切换字段类型。若协议输出必须使用 hash，
  应定义派生/传输字段并保持 config 明文不变。
- 删除字段必须经过 migration。
- v1 daemon 生成的 `ts` 固定使用 `unix:<UTC seconds>`；v2 事件使用 ISO 8601 UTC（如
  `2026-07-11T08:30:00Z`）。两种格式在同一文件中共存，CLI 必须同时兼容。
- CLI `--output json` 字段保持稳定。
- 人类可读输出可优化，但不能丢失关键状态。

## 16. 开发顺序和里程碑

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
10.5. 实现 TargetSystemConfig、节点静态网络、双 adapter locale/timezone/keyboard/离线/SSH/root/users/packages
      映射和验收，
      完成 M4.1。
11. 实现 dracut module、boot bundle/rootfs/initrd capability 校验、TargetSystem BootConfig 和断点续传。
12. 跑通 diskless squashfs overlay、目标系统 overlay 与 `rootfs_build`/`diskless_boot`，完成 M5，再实施 M6/M7 增强。
13. 修复部署错误传回 nodeforged（F1）、节点级不部署开关（F2）、ISO 导入主流 OS+覆盖语义（F3）、TFTP windowsize/并发/配置项（F4）、免密公钥配置化（F5）、CLI 命令体系校准（F6），完成 M8。详见 §13。post-install 异常容忍语义保持现状不动。

## 17. MVP 最终交付清单

二进制：

- `nodeforged`
- `nodeforge`

配置：

- `/opt/nodeforge/config/config.json`

管理目录：

- `/opt/nodeforge/catalog/catalog.json`

运行态：

- `/opt/nodeforge/state/leases.json`（M3 DHCP lease snapshot）
- `/opt/nodeforge/state/node-status.json`（M3 node-status snapshot）
- `/opt/nodeforge/state/deployment-control.json`（M4.1 install generation、consumed generation 与 applied revision）
- `/opt/nodeforge/state/runtime.json`（M2/早期 M3 兼容迁移输入，不再写入）
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
- M4.1 默认配置在 Ubuntu/Rocky 安装后可登录：OpenSSH enabled、root 密码登录 enabled、默认密码
  `asdf1234`；显式修改密码或关闭 root/password authentication 后结果严格跟随 profile。
- M4.1 自定义 locale/timezone/keyboard、普通用户/password/sudo/逐账号 key、额外本地包和目标 DHCP/静态
  IPv4 生效；静态地址等于该节点
  DHCP reservation，重启后仍由 Netplan/NetworkManager 持久化。
- local-only 部署抓包无公共 mirror、GeoIP、NTP、installer refresh、update/upgrade 或脚本下载请求；
  Ubuntu UFW、Rocky firewalld 默认关闭，Rocky `sestatus` 显示 disabled。
- macOS 宿主机 + Rocky Linux 9.7 ARM VM 可作为开发验证环境。
- diskless `squashfs_overlay` 启动。
- M5 无盘镜像继承 M4.1 的 locale/timezone/keyboard、SSH/root、普通用户/password/sudo/key、packages、
  防火墙、SELinux 和网络默认值；账号骨架与额外包仅在 rootfs build 落地，启动阶段不执行 useradd/apt/dnf。
- `nodeforge node status` 展示安装/无盘阶段。
- `nodeforge events list/follow/types` 展示历史、实时事件流和注册表。
- `nodeforge config validate` 校验配置。
- `nodeforge check` 验证服务可用性。
- `nodeforge provision bundle plan` 和 `provision status` 展示后处理计划与结果。

## 18. 风险和前置 spike

| 风险 | 建议 spike |
| --- | --- |
| Zig HTTP server 大文件 Range 实现细节 | M3 前做 1 个静态文件 Range demo |
| M3 节点 session/capability 与安装器 URL 兼容 | M3 前用 active DHCP lease 模拟 bootstrap，验证 token 只走 header、旧 session 返回 409 |
| ISO loop mount 权限与清理 | M3.4 前在 Rocky 9.7 aarch64 以 `CAP_SYS_ADMIN` 验证只读 `iso9660/udf` 挂载、异常路径卸载及无残留 mount/loop device |
| TFTP option/GRUB 行为差异 | M1 使用标准 client 和 QEMU 拉取 GRUB 配置/kernel/initrd |
| DHCP option 兼容性 | M2 前收集 UEFI x86_64/aarch64 DHCP fixtures |
| Ubuntu autoinstall schema 差异 | M4 固定 Ubuntu Server 22.04 LTS 为 MVP 必测；后续 LTS 逐版本增加 fixture |
| Ubuntu root SSH 与 cloud-init 覆盖顺序 | M4.1 用默认/显式覆盖 fixture 验证 identity、root lock、password hash 和 sshd 最终状态，并完成真实 root SSH 登录 |
| M4.1 目标静态网络切换 | 先保持 PXE DHCP，强制目标地址等于 `node.ip` reservation；验证安装中 HTTP 不断链及重启后 Netplan/NetworkManager 状态 |
| local-only 无外联 | 对 Ubuntu/Rocky answer 做公网端点静态扫描，并在隔离 PXE VLAN 抓包；M5-M7 同样纳入回归 |
| Rocky firewalld/SELinux 最终状态 | 同时验证 Kickstart 指令、目标配置、服务 enable/mask 状态和安装后 `sestatus`；无盘链路额外检查 `selinux=0` |
| Rocky/aarch64 开发验证 | M4 先在当前 macOS + Rocky Linux 9.7 ARM VM 完成 smoke；M6 补充 x86_64 生产记录 |
| dracut module 差异 | M5 前在 Rocky 9.7 aarch64 完成 `95nodeforge` build/boot spike |
| rootfs kernel module 匹配 | M5 前做 boot bundle validate prototype |
| 固件启动顺序 | 明确 MVP 不保证修改 BootOrder，避免阻塞自动安装 |

## 19. 开发期间文档同步要求

每个阶段完成时更新：

- `DESIGN.md`：仅当范围或关键决策变化时更新。
- `DETAILED_DESIGN.md`：阶段任务、接口、字段变化时更新。
- 示例配置：字段变化必须同步。
- 测试 fixture：协议或模板变化必须同步。

M3 的路由、DTO、认证、Range、资产 publication 或 EventType 任一变化，还必须同步检查：`DESIGN.md` 的 HTTP
安全边界、本文件第 8 节、M2.5.1 session/trace 契约、M4/M5 的 answer/initrd 消费方式、CLI help/fixture 与
Rocky 9.7 验证记录。未经这些同步，不得把接口变化标记为 M3 完成。

M4.1 的 TargetSystemConfig、默认值或 adapter 映射任一变化，还必须同步检查：概要设计的关键决策、M4
双 adapter fixture、M5 BootConfig/rootfs overlay、M6 新版本能力表、M7 protected-domain/finalizer、
`config.example.json`、README 当前阶段说明和 Rocky 验证待办。后续阶段不得复制字段或另设默认值；只有
代码、示例、测试和目标机验收全部同步后，才能把 M4.1 或其继承能力标记为完成。

M4.1 install generation/retry/drift 或横切门槛变化还必须同步检查：`deployment-control.json` schema 与原子
持久化、boot resolver 的 wait/local-disk 行为、M2 option 58/59、M2.5.1 trace 顺序、M3 asset/orphan 失败恢复、
M5 diskless retry、M6 retryability/config apply 和 M7 reconciliation/自动预算。不得把 observed node_status
倒退当作 retry，也不得通过 node override 或 generic script 绕过 generation/protected-domain。

M8 的错误上报（`/logs` 接通、`/subiquity-report`）、节点 deploy 开关、ISO 导入覆盖语义、TFTP 性能配置、
bootstrap key 多值化或 CLI 校准任一变化，还必须同步检查：§13 M8 验收标准、§9.10.6.2 bootstrap admin key
合并去重规则、§11.5 错误分类表 retryability、`event_types.zig` 注册表、`config.example.json` TFTP 新配置项、
`tests/cli.sh` 新命令树与 deprecated alias 断言、`buildCli` 拆分后的 `register*Commands` 函数。bootstrap key
来源从单值扩展为多值数组 + state 目录扫描，但合并去重规则（§9.10.6.2）不变；CLI 校准后旧路径必须保留
deprecated alias 一个版本周期。post-install 命令异常容忍语义不在 M8 范围内，保持现状。

不允许出现：

- CLI 命令和文档示例不一致。
- 配置字段在 profile 示例、校验逻辑、renderer 中含义不同。
- 安装和无盘 initrd 概念混用。
- DHCP/TFTP 端口变成配置项。
- diskless cmdline 重新塞回复杂 rootfs 参数。
