# NodeForge v0.2 设计范围

状态：设计冻结，实现未开始。本文只定义 v0.2 边界和进入条件；在 v0.1 完成前，不把这里的类型、命令或脚手架
描述为已实现能力。完整 CLI 接口见 `V0_2_CLI.md`，实现细节见 `V0_2_IMPL_DETAILS.md`，diskless 收敛见
`DISKLESS_FINAL.md`，程序边界见 `V0_2_PROGRAM_DESIGN.md`。

## 1. 进入条件

v0.2 必须基于 `V0_1_DESIGN.md` 冻结后的 schema v3 和 effective plan，至少满足：

- M0-M4 与 M4.13 全部自动化和双发行版 PXE 回归通过。
- Node/Profile/Resource/Override/Effective/Runtime 所有权不再存在兼容 fallback。
- typed PropertySpec/CollectionSpec/ItemSpec、exact-key CLI/API 和软件 capability index 已经落地。
- Node direct `storage.boot_disk/additional_disks`、默认 `/dev/sda`、单主 ESP 和全部 v0.1 native
  single/LVM/RAID/RAID-LVM mode 已完成双 adapter 渲染与可复现安装验证。
- schema v3 迁移工具经过 plan/apply/rollback 验收。
- 所有普通 CLI handler 已使用统一 OutputDocument，所有资源 mutation 均不要求 Shell 内嵌 JSON。

任何一项未完成时，M5 只能做隔离 spike，不能合入主产品路径或标记里程碑完成。

## 2. v0.2 范围

v0.2 聚焦 diskless 主流程。原 M5-M7 拆分到三个版本，避免把 VMware 难以验证或非 diskless 主流程的内容混入 v0.2：

| 版本 | 范围 | 对应里程碑 |
|---|---|---|
| v0.2 | diskless only | M5 内存无盘启动 + M7 diskless 后处理（`rootfs-build`/`first-boot`） |
| v0.3 | PXELINUX/BIOS install | M6 BIOS PXELINUX、发行版版本矩阵、`firmware.mode` schema v5 + M7 `install-post`，见 `V0_3_DESIGN.md` |
| v0.4 | 延后增强项 | 多 NIC/VLAN/bonding、大规模容量压测、远程/节点上 rootfs 构建（agent 驱动）；install 侧 first-boot agent 与 diskless 同一确定性执行（无 reconciliation，见 §7），见 `V0_4_DESIGN.md` |
| v0.5 | rootfs 形态 | 可切换 rootfs 形态（`ram_rootfs` 全内存模式、`diskless.overlay.mode` 字段），见 `V0_5_DESIGN.md` |

下文 M5-M7 仍按里程碑组织，每节标注其目标版本；未标 v0.2 的内容不计入 v0.2 完成。

### M5：内存无盘启动（v0.2）

- 将 v0.1 的 install Profile 扩展为 `ProfileKind = install | diskless` tagged union（设计名 `ProfileKind` = 代码 `BootKind` `model.zig:329`，v0.2 扩 `install|diskless`）；不增加 discovery Profile。
- boot bundle 的 install source、kernel、NodeForge initrd 与 kernel release 联合校验；派生 rootfs 在
  boot readiness/DeliveryManifest 阶段与 kernel modules ABI 联合校验。
- node-bound、capability-authenticated rootfs HTTP GET/HEAD/Range。
- 小 initrd 联网、配置获取、digest 校验、下载恢复、overlay 和 switch_root。
- v0.2 固定 `squashfs_overlay`（squashfs lower + tmpfs overlay upper）为唯一 rootfs 形态；可切换 rootfs 形态（`ram_rootfs` 等）作为 v0.5 单独项，不在 v0.2。
- `local-only` rootfs/initrd 离线策略、目标静态地址与 MAC reservation 一致性和 BootConfig secret 边界。
- diskless readiness、status、failure quarantine、retry 和事件闭环。
- target-system、software 和 kernel arguments 直接复用 v0.1 effective compiler。

Diskless 不消费安装磁盘选择器，但必须复用同一个 Profile/Node override 模型，不能建立第二套
users/packages/network 默认值。

### M6：支持矩阵增强（BIOS/发行版 -> v0.3；多 NIC/容量 -> v0.4）

- BIOS x86 PXELINUX。
- Rocky/RHEL 系和 Ubuntu 后续 LTS 的显式 adapter capability matrix。
- bootloader、发行版版本差异、错误分类和长期运行回归。
- 最小功能并发、失败恢复验证（大规模容量压测延后 v0.4）。

IPv6 是项目永久非目标，不进入 M6 或后续 schema。BIOS 与更多发行版版本彼此独立，不能捆绑实现。

M6 整体属 v0.3（BIOS PXELINUX、发行版版本矩阵、`firmware.mode` schema v5），不属 v0.2 diskless 主流程；
diskless 最小功能并发已在 M5（v0.2）验证。其中 PXE 阶段纯静态、多 NIC、VLAN、bonding 或下载后切换地址/子网，
以及大规模容量压测，在 VMware 难以有效验证且不属主流程，**延后到 v0.4**（需显式 initrd feature、schema 和验收）。

### M7：补充包和后处理增强（rootfs-build/first-boot -> v0.2；install-post -> v0.3；install-agent -> v0.4；reconciliation 永久非目标）

- archive、受控 script、first-boot provision action。
- bundle CRUD、plan、status、retry、日志脱敏和幂等。
- install、rootfs build 和 diskless 三条链路共用的强类型步骤。
- 已部署节点后处理边界（reconciliation/远程控制为永久非目标，见 §7）。

M7 扩展 v0.1 已有的最小 install-post provision bundle，不改变其 Assets owner。它复用 v0.1 软件
capability/selection，不再引入 `standard_packages` 作为第四个包配置事实源。 v0.2 实现 `rootfs-build`（build 期，
服务端 builder）与 `first-boot`（diskless 切根后 agent 开机顺序执行一次性后处理）phase；`install-post` 随 v0.3
（PXELINUX install）落地，install 侧 agent 延后 v0.4（reconciliation 为永久非目标，见 §7）。

## 3. 从 v0.1 继承的强制契约

v0.2 不是在 M5-M7 命令旁保留旧 M4 语义的并行产品。以下契约原样继承：

- Resource 回答“有什么可用”，Profile 选择共享策略，Node 保存机器 direct facts 和 policy override，
  Effective 是唯一编译结果，Runtime/Observed 不反向成为 desired 默认值。
- `show key == --help-full key == parser key == API operation path`；新增 mutable key 必须先注册 PropertySpec。
- scalar collection 注册 CollectionSpec，structured collection 注册 ItemSpec 和稳定 identity；CLI mutation
  继续使用 `list-values/add-values/remove-values/replace-values/clear-values`、直接 `item CRUD` 和可选的
  `replace-items --from-file`；ordered override 首次 item mutation 复用 v0.1 的原子物化语义。
- 所有 leaf command 继续统一支持紧凑 `-h/--help` 和详细 `--help-full`；完整 canonical key、item schema、
  约束和示例从同一 PropertySpec/CollectionSpec/ItemSpec/CommandSpec 生成，不能维护另一套帮助文本。
- 任何 v0.2 CLI 都不得要求 Shell 内嵌 JSON。HTTP transport 和 JSON/YAML 文件输入仍可表达结构化对象，
  但 CLI 必须从 typed flags、`FIELD=VALUE` 或 `--from-file` 构造请求。
- 普通命令继续走 `CommandResult/ViewModel -> OutputDocument -> human/json/jsonl`；rootfs/initrd 导出等
  artifact stdout 命令继续作为明确白名单，不注册含义冲突的 `--output`。
- capability、resource revision、Profile selection、Node delta 和 effective plan 必须共同进入 plan digest；
  renderer/initrd/runner 不得自行实现 fallback。
- 软件 delta 原样继承 v0.1 的完整路径：`packages.include.add/remove` 与
  `packages.exclude.add/remove` 分别修改两个 Profile 集合；不得在 v4 合并成含义不明的 `packages.add/remove`。
- 其他 override path 同样不改名：NTP/SSH key 使用各自 `add/remove`，users/partitions 使用 nullable ordered
  replacement，`kernel_args` 使用 `overrides.kernel_args.add/remove` 并按参数名合并。Diskless 不能建立第二套 delta。
- 原样继承 v0.1 的默认普通用户 `nodeforge/asdf1234`、默认 root 密码 `asdf1234` 及其明文
  Profile/Node override 契约；不新增第二套默认用户/密码、默认包列表、target network 或 kernel arguments。

明文 password 是 desired 配置事实，不是节点交付格式。DisklessEffectivePlan 在受控编译阶段使用 v0.1
PasswordHasher 派生发行版兼容的 `$6$` hash；BootConfig 只携带 root/普通用户 hash 和 public authorized key，
绝不携带明文 password、SSH private key 或 bootstrap private key。hash、完整 `target_system`、capability 和请求/响应
body 均视为敏感数据：不得进入 access log、Event、错误信封或 CLI 普通输出，结构化诊断最多报告 changed/fingerprint
和非 secret 摘要。

**`local-only` 不变式**。`local-only` 是 v0.1 删除 `profile.system.connectivity.mode` 后固化的产品不变式，不是
v0.2 新增的 rootfs/Profile PropertySpec。v0.1 因其只有 `local-only` 一个取值、无选择意义而删除该字段（schema v3
迁移第 8 步），故 M5 全部 rootfs/initrd 恒为 `local-only`，不存在 online/远程 mirror 变体，也不提供可设置的
`local-only` 开关。§4.3 与 §9.1 的 `local-only` 检查是对该不变式的强制（移除公网 mirror/metalink/GeoIP/vendor NTP、
禁止隐式 update、initrd URL 用 `server_ip` 字面地址），不是读取某个持久化字段；§5.2 的“隔离 `local-only` 网络”是
HTTP bearer 认证的运维部署假设（隔离 VLAN/ACL），同样不是配置项。其影响贯穿 M5/M7：rootfs 构建只引用本地
repository（无公网 mirror/metalink/GeoIP/vendor NTP），标准包经本地 repo 安装、非标准 tar 包须为预发布本地 asset
且 runtime 禁止隐式下载，initrd 全部 URL 用 `server_ip` 字面地址，HTTP bearer 仅在隔离网络内提供认证、不提供链路
机密性（须以 VLAN/ACL 防旁路窃听）。

v0.2 使用唯一的 catalog schema v4，同时包含 M5 diskless tagged Profile 与本版本交付的 M7
`rootfs-build|first-boot` action/phase；不能把 v0.2 必需 shape 延后到未来 schema v6，也不能让 schema v3 parser
长期接受 nullable 半成品。v0.3 的 `firmware.mode` 与 `install-post` 使用 schema v5；v0.4 使用 schema v6；
v0.5 rootfs 形态使用 schema v7。不能在已经发布的 schema 号下静默改变 shape。每次迁移都需
plan/digest/apply/rollback、活动 session 保护和 manifest transaction。v0.1 install
Profile 在 v4 映射到 `ProfileKind.install`；diskless Profile 必须引用完整 boot bundle（source + kernel +
nodeforge-initrd，明确不含 rootfs）。build readiness 通过后才允许构建派生 rootfs，boot readiness 通过后才允许
`deploy=true`。
v4-v7 复用 v0.1 已落地的 schema-v3 发布事务机制：plan/digest、journal、apply/rollback 与 daemon 启动崩溃恢复沿用
同一套 `.schema-v3` 风格事务目录与活动 session snapshot，不为每个版本另起迁移原语。`catalog/schema_v3.zig` 现拒绝
`schema_version > 3`，后续各版本新增对应 parser 校验分支并把 config 与 catalog 的 `schema_version` 同步提升；
旧 parser 不得接受半成品 nullable v0.2 shape。

### 3.1 schema v3 到 v4 的唯一转换

| v0.1 schema v3 事实 | v0.2 schema v4 处理 | 禁止的替代实现 |
|---|---|---|
| install Profile + `install_source` | 包入 `ProfileKind.install`，共享 policy path 原样保留 | 同时保留旧 nullable source 和新 kind |
| 无 diskless Profile | 新增 `ProfileKind.diskless` + 必填 `boot_bundle`（source+kernel+initrd） | 在 v3 预留 nullable bundle、把派生 rootfs 塞入 bundle或 mode |
| Node direct identity/network/storage | 原样继承；diskless effective 对 storage 标记 not-applicable | 建立 diskless 私有 network/storage 默认值 |
| Node policy overrides | 共享 `system.*`、`software.*`、`kernel_args`；install-only key 对 diskless fail closed | 为 diskless 复制 users/packages/kernel args |
| install source/repository software revision | rootfs build 和 diskless plan 固定引用同一 capability identity | rootfs 内包集合与 show/effective selection 各自漂移 |
| `AssetKind.kernel` 仅表示 installer kernel | 新增 `runtime_kernel`，由本地 kernel package + modules closure prepare | 默认把 installer kernel 当运行 kernel |
| discovery policy/observation + claim | 原样继承 daemon-owned singleton、观察资源和审计 | 恢复 discovery Profile、startup unknown policy 或 unknown auto-diskless |
| schema v3 provision bundle | v4 一次迁移为 tagged action + canonical phase；v0.2 只允许 `rootfs-build|first-boot` | 依赖未来 schema 才能启动 v0.2 |
| schema v3 effective/digest | v4 compiler 扩展 tagged branch，并保持一个 canonical digest 输入 | renderer/initrd/HTTP handler 各自补默认值 |

v4 migration 只改变 Profile 的外层 discriminated shape；不能借机移动 v3 已冻结 owner。转换计划必须逐个列出
Profile、引用它的 Node、旧/新 effective digest 和 active session 阻塞原因。rollback 恢复完整 v3 manifest；
不能生成 v3 无法表示的 diskless Profile 后再回滚到部分 nullable 数据。

## 4. M5 具体继承与变更

### 4.1 Profile 与 effective plan / rootfs 共享模型

M5 把 v0.1 单一 install Profile 扩展成 tagged union（`ProfileKind = install | diskless`）。diskless effective
compiler 复用 v0.1 effective compiler，增 `kind=diskless` tagged branch；diskless 不消费安装磁盘选择器，但复用
同一 Profile/Node override 模型，不建第二套 users/packages/network 默认值。

Node 只持有一个 Profile ref，因此任一 desired revision 只能解析出一个 kind。runtime current state 同样是
`install|diskless` tagged union：同一 Node 最多一个 active session，不保存可同时非空的 install/diskless 状态。
换绑到另一 kind 只允许 `deploy=false` 且无 active/recoverable session；旧 kind 只保留在带 session/digest 的历史审计。

**单一共享 rootfs**。M5 固定采用单一共享 rootfs：rootfs builder 从 effective plan 生成 rootfs（OS 层经
发行版 install-root 工具烤入 effective software/system + `rootfs-build` phase 业务内容 + Profile 级 target-system 骨架），
按 `rootfs_input_digest` 缓存。cache key 覆盖 build-safe effective system/software（含 Node 软件 override）、
`rootfs-build` phase、first-boot manifest/payload/package closure、Profile 级 target-system 骨架和 builder ABI，
**不含 Node identity/network/secrets**：两个 Node
effective 配置相同即共享同一 rootfs，相同输入复用、任一输入变化产生新 rootfs。Node 只有在 rootfs ready 后才可
diskless boot。M5 不依赖尚未实现的 M7 first-boot 安装包，也不允许先启动半成品 rootfs 后把缺失 package 留给运行期
补齐。reconciliation 为永久非目标（见 §7），但不能改变历史 session snapshot 指定的 rootfs。

rootfs 是由 effective plan 派生、按 `rootfs_input_digest` 跨 Node 共享的缓存制品，不是可手工编辑的 catalog Resource、
也不绑定单个 Node。OS 层（effective software/system 镜像）可由 builder 内部按 software digest 缓存复用（业务内容
变更不重建 OS 层），但对设计透明、不作为独立 Resource 暴露。per-Node 数据（hostname、`$6$` 密码 hash、authorized
key、machine-id、SSH host key、节点静态网络）不烤入 rootfs，而由 BootConfig 在 boot 时写入 overlay upper（见 §4.3、
§4.4 边界表），故 rootfs lower 不含节点专属机密、可跨 Node 共享。Node 软件 override 改变 effective software、会
产生不同 rootfs；Node 的机密/网络 override 只影响 overlay、不分裂 rootfs。rootfs 经 `assets rootfs list|show`
（按 digest 只读列出）或 `node rootfs status <node>`（节点解析）查询，由显式
`node rootfs build <node> --if-input-digest ...` 构建；readiness 不暗中触发有副作用的构建。下载经绑定自身的
capability route（per-Node 鉴权，内容按 digest 共享/缓存）。
v0.2 已发布 rootfs 只增不删，不设计 delete/GC 或引用计数；Runtime 只记录 build/status/consumer，不反向写入
desired 配置。容量由 status 告警，空间不足时新 build fail closed，回收策略不进入 v0.2。

**无盘属性适用性**。v0.1 已梳理的全部属性在 diskless Profile/Node 上的适用性如下；`not-applicable` 表示
install-only 字段对 diskless 返回 `property.not_applicable` 且使 not ready，除非该字段本就为空：

| 属性（v0.1 canonical） | diskless 适用性 | 说明 |
|---|---|---|
| Node `mac`/`arch`/`profile`/`pxe.ip_reservation`/`hostname`/`deploy` | 可用 | `deploy` 闸 diskless PXE；`pxe.ip_reservation` 为 DHCP 预留 |
| Node `http_accel` | 可用（UEFI） | 仅 GRUB 取 kernel/initrd；BIOS not-applicable；不治理 initrd rootfs 下载（见 §5.1）|
| Node `network.*` | 可用 | 目标系统网络，见下文网络标准 |
| Node `storage.boot_disk`/`additional_disks` | 持久但不消费 | diskless effective 标记 not-applicable；保留以便日后绑 install Profile |
| Profile `system.*`（localization/ssh/users/security） | 可用 | 骨架入 rootfs build，per-boot 差异入 overlay（见 §4.4）|
| Profile `system.connectivity.time_sync`/`ntp_servers` | 可用（受限） | local-only 不变式：NTP 只用显式服务器，无 vendor NTP |
| Profile `software.*` | 可用（build 期） | rootfs 构建消费固定 revision 的 effective software；runtime package action 只装受限补充包/组/环境（本地 repo），不重装 base software.* 选择 |
| Profile `kernel_args` | 可用 | PXE cmdline 追加，initrd 透传 |
| Profile `diskless.overlay.tmpfs_percent` | 可用（diskless-only） | 控制 tmpfs upper 预算 |
| Profile `diskless.failure.max_attempts`/`backoff_seconds` | 可用（diskless-only） | 达预算 quarantine；不负责 BMC 重启 |
| Profile `diskless.provision.bundle` | 可用（diskless-only） | 引用 provision-bundle（rootfs-build/first-boot phase），与 install 的 `install.post_install.bundle` 对应 |
| Profile `install.*`（source/storage/bootloader/apt/completion/updates/proxy/reinstall/post_install.bundle） | not-applicable | install-only（`install.apt.fallback` 是安装器 apt 行为、非仓库源），对 diskless 返回 `property.not_applicable` |

**无盘以太网配置标准**。`pxe.ip_reservation`（旧 `node.ip` 已由 v0.1 重命名），且匹配 MAC、prefix、gateway、DNS 和
renderer capability 必须在 effective/readiness 阶段共同校验。initrd 下载期间不切换地址，只向 overlay 写持久网络配置，
由 `switch_root` 后的 NetworkManager/Netplan 接管同一地址；不一致必须在切根前以稳定 reason 失败，不能回退到未声明
DHCP 目标配置。PXE 阶段纯静态、多 NIC、VLAN、bonding 或下载后切换地址/子网不属于 M5，亦不在 M6 范围，延后到 v0.4。
renderer 由 adapter capability 选择：RHEL 系写 NetworkManager connection、Ubuntu 写 Netplan，均以
`match.macaddress`/`connection.mac-address` 绑定 `node.mac` 对应的启动 NIC；`network.mode=dhcp` 时目标系统在
`switch_root` 后对同一 NIC 重新 DHCP（沿用该 MAC 的 `pxe.ip_reservation`），不写静态配置；`network.mode=static` 时
写静态配置且 `network.address` 须等于 `pxe.ip_reservation`，initrd 与目标系统不切换地址。

M5 新增的最小 Profile policy 面：

| Profile path | 类型/默认 | Node override | 约束 |
|---|---|---|---|
| `diskless.overlay.tmpfs_percent` | 10-80 的整数，默认 50 | `overrides.diskless.overlay.tmpfs_percent` | v0.2 固定 `squashfs_overlay`，控制 tmpfs overlay upper 预算 |
| `diskless.failure.max_attempts` | 1-10，默认 1 | `overrides.diskless.failure.max_attempts` | 达到预算后 quarantine |
| `diskless.failure.backoff_seconds` | 0-3600，默认 0 | `overrides.diskless.failure.backoff_seconds` | 不负责 BMC 重启 |

### 4.2 Assets 资源树

v0.2 延伸 v0.1 的 Assets tree，不新增顶级 `rootfs`、`initrd` 或 `boot-bundle` 命令：

```text
nodeforge assets rootfs list|show|validate
nodeforge assets runtime-kernel prepare|list|show|validate
nodeforge assets nodeforge-initrd config show|set|modules-values|firmware-values|build|show|list|validate
nodeforge assets boot-bundle create|set|list|show|validate
nodeforge profile capabilities show <profile>
nodeforge node capabilities show <node>
```

rootfs manifest 的 files/features、initrd modules/features 和 boot-bundle compatibility constraints 若为 scalar
collection，使用 values 命令；manifest entries 或 build steps 若为 structured collection，使用 item CRUD/
`replace-items --from-file`。Assets detail 的 stored/capabilities/runtime sections 继续遵守 v0.1 输出和 exact-key 规则。

资源最小 manifest 契约。boot bundle 不引用 rootfs，避免 Profile/effective build input 与 rootfs 输出之间的
循环依赖；一次启动由 DeliveryManifest 绑定 rootfs content digest：

| Resource | 必填持久事实 | 只读派生事实 |
|---|---|---|
| rootfs | format、arch、content digest/size、uncompressed size、builder version、software capability revision、effective system/software digest、features | validation/readiness、rootfs consumers |
| runtime-kernel | source/package revision、arch、kernel release、content digest、modules/package closure digest | initrd/rootfs modules ABI compatibility |
| nodeforge-initrd | arch、kernel release、content digest/size、builder version、modules/features | validation/readiness、supported overlay/network features |
| boot-bundle | install-source ref、runtime-kernel ref、nodeforge-initrd ref、arch、kernel release、required features | joint boot digest、build compatibility/readiness、consumer count |

Resource name 不是内容身份；内容或 builder 输入变化必须发布新 revision/digest。Boot bundle 在 transaction 中
pin source/kernel/initrd revision 并派生 joint boot digest。rootfs 是 `rootfs_input_digest` 对应的只读派生缓存；
DeliveryManifest 固定 boot bundle revisions + rootfs SHA-512，不能把交付输出反写 Profile。

Rootfs/initrd 构建的工具链和驱动放置属于 M5 的显式实现边界，而非未说明的 builder 自由度：

- NodeForge initrd 使用与目标发行版、版本、架构和 kernel release 匹配的 `dracut` 环境构建；MVP 不手工拼 cpio。
  build manifest 固定 builder image/environment digest、dracut 版本、命令、module/firmware 清单和输出 digest。
- 获取 BootConfig/rootfs、校验并挂载 lower/upper、完成 `switch_root` 前必需的 NIC、firmware、HTTP、SHA-256、
  squashfs、tmpfs 和 overlay 能力必须放入 initrd；缺一项即 bundle not ready。
- 只在切根后使用的 GPU、RDMA、监控、额外存储或业务驱动放入 rootfs，并与同一 kernel release 的 modules manifest
  联合校验。任何驱动若被启动路径提前需要，就必须提升为 initrd required feature，不能靠运行时偶然加载。

### 4.3 交付与运行态

- 新增 node-bound boot-config DTO、rootfs GET/HEAD/Range、ETag/If-Range 和 capability auth。
- initrd 消费的字段来自 session effective plan snapshot；digest、required features 和 URL 不能由 HTTP handler 临时拼默认值。
- rootfs download、verify、overlay、switch_root、quarantine、retry 和事件使用独立 runtime state，不写回 Profile。
- boot bundle 的 source/kernel/initrd revision、kernel release、arch 与 feature compatibility 由 build readiness
  校验；派生 rootfs SHA-512/modules ABI 在 boot readiness 与 DeliveryManifest 阶段加入联合校验。
- `local-only` 不变式下必须移除/禁用公网 mirror、metalink、GeoIP 和 vendor NTP 默认值，启动时禁止隐式
  update/upgrade/package install；time sync 关闭或只使用显式服务器。initrd 的 BootConfig、rootfs 和 event URL
  必须使用 NodeForge `server_ip` 字面地址，M5 不做 DNS fallback，也不访问其他地址。出口 ACL 是纵深防御，
  不能替代 rootfs 静态检查、隔离网抓包和运行时 fail-closed。

DisklessEffectivePlan 至少固定：Profile/Node/resource revision、arch、boot bundle、kernel/initrd revision、
network、target system、effective software、kernel arguments、overlay 配置（v0.2 固定 squashfs_overlay +
tmpfs_percent）、required initrd features 和全部 node-bound URL。BootSession 保存该计划的 digest 和 immutable
capability identity；rootfs output digest 不进入会导致构建环的 desired plan，而是在 session DeliveryManifest
中与 plan 一起固定为 delivery snapshot。服务重启只能按相同 delivery digest 恢复，不能重新编译后继续旧 session。

Boot-config 只返回 initrd 实际需要的 DTO：session/scoped capabilities、network、rootfs URL/digest/size、Range recovery、
overlay、target-system projection、event URL 和过期时间。除 `$6$` password hash 和 public authorized key 外不含任何
长期 secret；`/run/nodeforge/boot.json` 只保存 plan/config digest 与非 secret 摘要，mode 0600，且不保存 password hash
或 token。能力拆成一次性 `config:read`、只读 `artifact:read` 和只写 `event:append`，分别绑定
node、session、audience、HTTP method/path、plan digest 与短有效期；不能访问其他 Node rootfs，也不能升级为
management credential（management credential 指 daemon 管理 API 的服务端管理员鉴权，与 boot 传输 token 是不同凭据
类型、不同鉴权路径：传输 token 仅授权该 Node 的 GET/HEAD/Range config/rootfs 与 event POST，无 catalog 写、无管理
API 调用能力，防止 per-boot 传输 token 被滥用为服务端管理权限）。此 token 与已永久移除的 enrollment/credential 无关：
enrollment 是运行期节点认证 secret，已永久移除；此处 token 仅是 boot 期 initrd 拉取 BootConfig/rootfs 的传输鉴权。
initrd 在 `switch_root` 前清零 config/artifact token；短时 `event:append` token 以独立 0400 文件跨 `/run`
交给 agent，完成后删除，永不写入 boot.json。首次 hash mismatch 删除 partial 后完整重试；重复完整 mismatch、
feature mismatch、过期 token、越权 Range、switch_root 失败进入稳定 error code、`diskless.failed` 和 quarantine。

交付给 initrd 的 BootConfig DTO 使用与 `ProfileKind` 一致的 `kind` 判别字段，废弃 legacy `mode="diskless"` 写法；
install 与 diskless 共用同一判别字段，install 交付内容（config/event URL、capability）不变，仅把判别字段对齐为
`kind`。diskless BootConfig 的 `schema_version` 提升到 v2（BootConfig DTO 自身版本，与 catalog `schema_version`
v3/v4 分属不同命名空间）并携带上文的 DTO 字段；旧 initrd 未声明对应 feature 时，引用含 target-system/静态网络
override 的 Profile 必须在发布 readiness 阶段失败，不允许旧客户端静默忽略。`required_features` 至少枚举稳定 token：
`target-system-v1`、`static-network-v1`、`sha512-crypt-v1`、`bootstrap-admin-key-v1`、`target-accounts-v1`；initrd
在 boot bundle manifest 中声明支持的 feature 子集，缺失或冲突在 `switch_root` 前以稳定 error code 拒绝，不得回退降级。

**BootConfig 定义与 boot 写入流程**。BootConfig 是 per-boot、per-Node 的短时 DTO，由服务端按 session
DisklessEffectivePlan snapshot
在 boot 时生成、initrd 经 node-bound capability 拉取；它只携带动态/按节点参数（session/capability token、network
投影、rootfs URL/digest/size + Range recovery、overlay 配置、target-system 投影、event URL、过期时间），不烤入
rootfs lower，故 rootfs lower 可共享、per-Node 差异只落 overlay upper。写入流程：① DHCP/TFTP 引导 boot bundle
（kernel + 共享 NodeForge initrd）和 per-session credential capsule；kernel cmdline 只携带无密钥的 config URL、
node/session 与 `kernel_args`，config token 由 GRUB 作为第二 initrd cpio 追加；② initrd 从 capsule 读取 token
后拉 BootConfig；③ initrd 把 target-system 投影写 overlay upper
（NM/Netplan 网络、hostname、`/etc/shadow` `$6$` hash、authorized_keys、machine-id、SSH host key），并下载/校验/挂载
rootfs lower；④ `switch_root` 后 NM/Netplan 接管网络，agent 开机顺序执行 `first-boot` 后处理。BootConfig 除 `$6$`
hash 与 public authorized key 外不含长期 secret，token 与 `/run/nodeforge/boot.json` 边界见本节上文。

**boot-time 职责划分与共享参数来源**。共享参数不全部 build-time 打包：静态/公共内容（包、locale 数据、openssh 二进制、
用户骨架）在 rootfs build 烤入只读 lower；动态/按节点/按启动参数（server 端点、capability token、target-system 投影含
network/SSH/users/keys）经 BootConfig 交付；kernel cmdline 携带无密钥 config URL 与 `kernel_args`，一次性
config token 位于 per-session credential capsule。initrd 取 BootConfig 后写入 overlay upper，不切换地址。
boot-time 的 target-system 应用（含网络配置）由
**initrd**（非 agent）完成：initrd 从 BootConfig 的 network/target-system 投影写 NetworkManager/Netplan 静态或 DHCP
配置到 overlay upper，`switch_root` 后 NM/Netplan 接管同一地址；agent 只在切根后开机顺序执行 `first-boot` 后处理
（一次性，无远程控制、无 reconciliation），不负责 boot-time 网络。

跨 DHCP/TFTP/HTTP/initrd 的 canonical BootSession 状态机固定为：

```text
boot.dhcp_discover -> boot.dhcp_offer -> boot.dhcp_ack -> boot.tftp_rrq -> boot.tftp_complete
  -> boot.config_fetched -> diskless.initrd_started -> diskless.rootfs_downloading
  -> diskless.rootfs_verified -> diskless.rootfs_mounted -> diskless.switching_root -> diskless.running
```

历史概要中的 `pxe_seen`、`bootfile_sent`、`diskless_config_fetched` 分别是 `dhcp_discover`、携带 bootfile 的
`dhcp_ack`、`boot_config_fetched` 的展示别名，不是额外持久状态；v0.2 API、Event 和持久化只使用 canonical 名。
`failed` 可从任一非终态进入，`expired` 只能由服务端超时进入；两者都是本次 session 的终态。`node_status` 可以投影
上述状态，但不得用 `ready/booting/downloading` 等粗粒度枚举替代而丢失早期诊断证据。重复同阶段上报幂等，跳跃、
回退、错绑 node/session 一律拒绝。

canonical BootSession 只覆盖 DHCP/TFTP/boot_config 共享前缀和 diskless 尾部；install Profile 的 BootSession 在
`boot_config_fetched` 完成交付后终止，installer 进度（`installer_started`/`installing`/`installed`/`provisioning`/
`completed` 等）属于 `node_status` 部署投影，不进入 BootSession canonical phase。当前 `src/state/boot_session.zig`
的 `Phase` 枚举把 install 侧阶段与 diskless 阶段混排，v0.2 实施时须把 install 交付后的进度移出 BootSession，仅在
`node_status` 投影保留，使 BootSession 与部署投影职责分离。`node_status` 对外必须使用带 namespace 的 canonical 名：
diskless 终态为 `diskless.running`，不得新增无 kind 的 `running` 或并列 install/diskless 字段；早期 PXE/TFTP
诊断状态也保留为 `boot.*`。内部 Zig enum 可使用 snake_case，但只允许一个显式映射表。diskless/install 状态机
统一与 `node list`/`node status` kind
感知投影（`KIND` 列、时间戳按 kind 泛化、`BootKind` 扩 `install|diskless`）的细化见 `V0_2_IMPL_DETAILS.md` §1。

Quarantine 是 Node 级 boot gate，不是 BootSession phase。一次 attempt 进入 `failed` 后按 session snapshot 的
`max_attempts/backoff_seconds` 计数；达到预算才进入 quarantine，并拒绝新 session。`diskless.running` 是启动成功
终态；切根后的 agent `first-boot` 后处理失败属于 M7 运行期，不回写或倒退已完成 BootSession。

`nodeforge node diskless retry <node>` 只清除终态 failure quarantine；不创建 install generation、不修改 Profile、
不远程重启。存在活动 session、`deploy=false`、Profile 非 diskless 或 desired digest 已变化时 fail closed。

### 4.4 无盘构建方案

M5 rootfs 构建为单一共享 rootfs：rootfs builder 从 effective plan 生成 rootfs = OS 层（effective software/system 经
发行版原生 install-root 工具烤入只读 lower）+ `rootfs-build` phase 业务内容（managed-file/archive/script/package 追加到 lower）
+ Profile 级 target-system 骨架。rootfs 按 `rootfs_input_digest` 缓存、跨 Node 共享；OS 层可由 builder 内部按 software
digest 缓存复用（业务内容变更不重建 OS 层），但对设计透明、不作为独立 Resource。rootfs-build 与 first-boot 共用
§5.4 统一 action 与 §5.2 八步执行契约，差异只在执行者与目标上下文（见 §5.4）。

**rootfs 构建（OS 层）**。OS 层从 boot bundle 固定 revision 的 install source/repository capability 用发行版原生
rootfs 工具生成：RHEL/Rocky 默认使用目标版本 `dnf --installroot`，Ubuntu 默认使用 debootstrap + local apt；
lorax/livecd/mkksiso 只有 adapter 明确声明为等价实现时才允许使用，不能默认用安装 ISO 制作工具代替 rootfs builder。
构建在与目标 distro/version/arch/
kernel_release 一致的环境中运行。builder 固定 software capability revision，消费与 Profile 查询相同的
environment/group/task/package selection（metapackage 仍按 `software.packages.include` 选择），并按 local-only 不变式
移除/禁用公网 mirror、metalink、GeoIP 和 vendor NTP，只引用本地 repository。OS 层可按 software capability revision
内部缓存复用；build manifest 记录 builder image/environment digest、构建工具版本与命令、module/firmware 清单、
generated locales、available timezones/keyboards、user 账号骨架（passwd/group/home/shell/sudo membership，不含密码/key）、
capability revision、effective system/software digest 和输出 squashfs digest/size/uncompressed size。

**rootfs-build phase**。provision bundle 的 `rootfs-build` phase 步骤在 OS 层之上向只读 lower 追加业务内容：managed-file、
archive、受控 script 和经本地 repo 解析的 package action（受限 `packages`/`group`/`environment`/`selection`，如更新
`/etc/hosts`、写入 motd、预装补充包）。该 phase 由服务端 rootfs builder 执行（无节点 agent），builder 提供
chroot/staging 上下文使步骤以 `/` 为目标写入 lower，步骤作者不感知暂存目录。OS/source/repository revisions +
rootfs-build inputs + first-boot fixed payload + build-safe effective system/software + builder ABI 共同决定
`rootfs_input_digest`；构建输出另以 content SHA-512 标识。

**first-boot payload 预置**。builder 解析 first-boot package closure，并把 manifest、RPM/DEB、managed-file、
archive、script 以内容寻址形式写入 `/usr/lib/nodeforge/firstboot/<bundle-digest>/`，但不在 build 期执行。
agent 切根后只消费该只读本地 payload，不使用 event token 读取 bundle/repository。任何缺包、asset digest
不匹配或 payload 超预算都在 build 阶段失败，不能留到节点启动时在线补齐。

**构建环境保真**。rootfs-build phase 执行 package/script 时按动作所需提供构建环境：纯 userspace 动作（写文件、装普通包、
配置）只需 chroot；触及硬件/内核的动作（装驱动、dkms、重生成 initramfs、装载内核模块）须 bind-mount `/dev`/`/proc`/
`/sys` 并使用与目标 distro/version/arch/`kernel_release` 一致的内核，否则驱动/dkms 类安装不适用；内核与 OS 一致时需
加载完整内核态以满足模块构建。v0.2 本地 server builder 按此保真执行；更高保真的远程/节点上构建（经节点 agent 在真实
硬件与内核态构建 rootfs）需 agent、加载完整内核态/设备/proc，复杂且牵扯 agent，作为 v0.4 后续设计，v0.2 不实现。

**rootfs 缓存与共享**。rootfs 按 `rootfs_input_digest` 标识、跨 Node 共享：per-Node 机密与配置（hostname、`$6$` hash、
authorized key、machine-id、SSH host key、节点静态网络）不烤入 rootfs，而由 BootConfig 在 boot 时写 overlay upper
（见 §4.3/§4.4 边界表），故 rootfs 不绑定单个 Node、可跨 Node 共享。节点经绑定自身的 capability route 下载（per-Node
鉴权），只由 `node rootfs build <node> --if-input-digest ...` 显式触发；readiness 只读、不暗中构建。
`node rootfs status <node>` / `assets rootfs list|show` 查询（见 §4.1/§4.2）。

**构建期与启动期边界**（只读 lower vs per-boot overlay upper）：

| 内容 | rootfs build（公共 lower） | diskless boot（节点 upper） |
|---|---|---|
| locale 数据包、tzdata、keyboard 数据 | 安装并生成支持矩阵 | 只选择已存在 locale/timezone/keyboard |
| openssh-server 二进制/unit | 从本地 repo 安装 | 写认证策略、authorized_keys，生成 host key |
| `software.*` 包 | 从本地 repo 安装并记 manifest | runtime 只引用 snapshot 中的 effective software，不通用安装 |
| `system.users` 账号骨架 | 创建 passwd/group/home/shell/sudo，不写密码/key | 写每账号 `$6$` hash 和 authorized_keys |
| 外部 repository | 删除/禁用/替换为本地源 | 不新增源 |
| hostname | 通用占位 | 写节点 hostname |
| 网络 | 保留 DHCP bootstrap 能力和 NM/Netplan | 写目标静态/DHCP 持久配置 |
| machine-id、SSH host key | 清理，不在共享 lower 留唯一身份 | 每次启动在 upper 生成 |
| root/用户 key | 不放节点专属或 bootstrap private key | 从受认证 BootConfig 写 bootstrap public key + 账号 profile key |

boot readiness 时把 Profile 的 target-system 与 rootfs manifest 对照：自定义 locale/timezone/keyboard、用户或包不存在、
SSH enabled 但无 sshd、静态网络缺 renderer/tool 时拒绝启用 PXE，不等切根后失败。

## 5. M6/M7 对新契约的影响

### 5.1 M6

BIOS 支持增加的是 Node confirmed firmware property和 bootloader adapter，不是 Profile 的物理磁盘 owner。
M6 增加 Node direct `firmware.mode=uefi|bios`；schema v4 到 v5 的既有 Node migration 默认为 `uefi`，新认领 Node
必须由管理员确认。DHCP observed firmware 只用于 mismatch/readiness 检查，不自动改写 desired property。该字段不能放入
Profile 或 `overrides`。partition policy 仍使用 v0.1 的逻辑磁盘角色，由 effective compiler 结合 firmware 生成
ESP/biosboot 要求。v0.1 保留的 `node.http_accel` 继续只适用于 UEFI GRUB；BIOS PXELINUX capability 必须报告
`property.not_applicable`，不能接受后静默忽略，也不能为 BIOS 新增另一个同义传输开关。

`http_accel` 治理的是 GRUB 在 PXE 阶段用 HTTP 取 kernel/initrd 的传输路径（install 与 diskless 共用，仅 UEFI）；它不
治理 initrd 自身用 node-bound capability route 发起的 rootfs GET/HEAD/Range 下载--后者始终走受认证 HTTP 路由，与
`http_accel` 开关无关，也不因 BIOS 而新增同义传输开关。

### 5.2 M7 phase 与八步执行契约

phase 固定为 `install-post|rootfs-build|first-boot`（canonical 集合；schema v4 实现 `rootfs-build`/`first-boot`，
`install-post` 随 v0.3）。`first-boot` 为 diskless 切根后 agent 开机顺序执行的一次性后处理，无 `runtime` 周期 phase、
无远程控制。每个 action 显式声明允许 phase、输入 asset、幂等 key、timeout、retryability 和敏感输出规则；同一 step 的
`(boot session, bundle revision, desired plan digest, node, phase, idempotency key)` 唯一标识本次开机的一次执行。
新 PXE session 必须重新执行全部 first-boot steps，不得用服务端历史成功记录跨启动跳过。`plan` 无副作用，`apply` 需要
目标 revision，`retry` 只重跑明确 retryable 的失败 step。M7 不成为通用远程命令或配置管理平台。

旧详细设计名称只按下表迁移，schema v4+、CLI、API、状态和事件不得继续写旧拼法：

| 历史名称 | v0.2 canonical phase | 迁移语义 |
|---|---|---|
| `install_post` | `install-post` | 原位无损迁移 |
| `rootfs_build` | `rootfs-build` | 原位无损迁移 |
| `firstboot` | `first-boot` | 原位无损迁移 |
| `diskless_boot` | `first-boot` | 迁移后为 diskless 切根后 agent 开机顺序执行 |

每个 phase 的执行顺序固定为八步，跳过不适用步骤但不得重排：1）挂载/确认 target root；2）pin effective、bundle、
asset revision 并验证 action/phase/保护域；3）物化已发布的本地 repository 和输入 asset；4）原子写 managed file（文件更新）；
5）执行只引用 snapshot 中 effective software/capability 的 package action；6）校验并展开 archive；7）按声明顺序
执行受控 script；8）运行 TargetSystem finalizer 后原子发布 status/audit。任一步失败都不得发布 succeeded 状态。
顺序固定为 文件更新 -> package -> archive -> script。

TargetSystem 保护域包括 passwd/shadow/group/sudoers、sshd、各账号 authorized_keys、Netplan/NetworkManager、
resolver、locale/timezone/keyboard、software manifest、firewall 和 SELinux 配置/unit。managed-file、archive 和 script
声明影响域；触及保护域的 action 在 plan/validate 阶段直接拒绝，不能用 `--force` 绕过。finalizer 在每个 phase
末尾重新断言 effective owner、bootstrap/profile public key 合并和离线策略。

`first-boot` agent 的节点身份由 cmdline node/session、BootConfig 与 token claim 三方相等后确定，initrd 写入
`/run/nodeforge/boot.json`（mode 0600，非 secret 摘要）。agent 切根后开机顺序执行后处理，状态/异常/审计经
event_url best-effort 回传服务端（带 node_id），回传失败不阻塞执行、仅本地留存日志/console/boot.json。
v0.2 diskless 不引入 enrollment/credential/reconciliation/远程控制（reconciliation/远程控制为永久非目标，见 §5.3、§7）。

v0.2 diskless 不引入 enrollment 机制：agent 身份来自已验证的 session handoff（见 §5.2 上文、§5.3），
状态/异常 best-effort 回传，回传失败本地兜底（日志/console/boot.json）。enrollment/credential/远程控制/reconciliation
为永久非目标（见 §7）；install 侧 agent（确定性 first-boot，无 reconciliation）延后 v0.4。v0.2 的 HTTP bearer 只在隔离
`local-only` 网络内提供认证，不提供链路机密性；跨不可信网络的 TLS/mTLS 与远程管理仍是非目标，部署必须以隔离
VLAN/ACL 防止旁路窃听。

### 5.3 运行期后处理与 agent

三个 phase 的执行者不同：`install-post` 由安装器（Kickstart `%post`/Autoinstall `late-commands`）在安装期执行，无
agent、属 install（v0.3）；`rootfs-build` 由服务端 rootfs builder 执行，无节点 agent（v0.2，见 §4.4/§5.4）；`first-boot`
由 node-bound agent 在 diskless 切根后开机顺序执行（一次性，无 `runtime` 周期、无远程控制）。v0.2 的 agent **仅服务
diskless**（diskless 无安装器，`first-boot` 是其后处理主路径）；rootfs-build 不需 agent（builder 本地受信），`install-post`
随 v0.3（PXELINUX install）落地，install 侧 agent 延后到 v0.4（reconciliation 为永久非目标，见 §7）。本节 agent 设计
以 diskless 后处理为唯一 v0.2 目标。

**agent 身份与生命周期**。agent 无 enrollment：节点身份由 cmdline node/session、BootConfig 和 token claim
三方相等后固定为 session snapshot，initrd 写入 `/run/nodeforge/boot.json`（mode 0600，非 secret 摘要），agent 切根后读取
并开机顺序执行 `first-boot` 后处理。agent 是确定性顺序执行器（开机即跑 rootfs 烤入的 bundle first-boot steps，固定顺序
文件更新 -> package -> archive -> script，一次性），不接受远程任务下发、不做 reconciliation、不做通用远程命令或配置
管理平台。状态/异常/审计经 event_url best-effort 回传（带 node_id），失败本地兜底，不阻塞执行。

**first-boot 执行与重试语义**。diskless overlay upper 为 tmpfs（per-boot 易失）、系统无状态，故 first-boot **每次开机
都执行**（“一次性”指每次开机执行一次、非 `runtime` 周期，非“跨重启只跑一次”）。幂等键包含 boot session，
只用本次启动 `/run` journal 使崩溃/当次 retry 的已成功 step no-op；服务端历史仅供审计，不能让新 session 跳步。
retryable 失败 step 按 step 声明 retry 策略在当次开机内重试，耗尽则 step 标 failed（节点仍启动、该 step 失败，
经 `node postprocess show` 查询）。重新触发完整 first-boot = 重启节点重新 PXE 引导；`node diskless retry` 清
boot-level quarantine 以允许重新 PXE，
不改 Profile、不远程重启。无独立 first-boot retry CLI（重启即重跑，确定性+幂等保证安全）。

**步骤契约**。每个 step 接收执行上下文 `node_id, profile, distro, distro_version, arch, phase, target_root, workspace,
payload_root, event_url`，统一返回 `{changed, status, summary, outputs, warnings}`；first-boot 的 `payload_root` 来自
rootfs 内 content-addressed 预置目录，不在切根后解析远程 repository。`plan` 预览（安装包/改文件/脚本）
无副作用，`apply` 需目标 revision，`retry` 只重跑明确 retryable 的失败 step。runner 在每 step 前后产生
`provision.step.started`/`succeeded`/`warned`/`failed`，fields 固定含 `source=runner`、`node_id`、`phase`、`step`、`run_id`、
action、稳定 reason；脚本 stdout/stderr 仅留最后 2048 bytes 转义摘要，token/未声明输出不得进服务日志或 Event。失败只留本地
失败信息（日志/console/boot.json），不因事件上报失败中断或回滚已完成切根/后处理；事件 fields 有界且脱敏，不含下载 URL
query、Authorization、完整 journal 或 debug shell 输出。

**reconciliation**（永久非目标）。全版本不实现 reconciliation/远程控制：agent 开机顺序执行确定性 first-boot，无 drift 重跑、
无远程任务下发。reconciliation 与远程控制不再仅延后 v0.4，而是升级为永久非目标（见 §7）；install 侧 agent（确定性
first-boot）延后 v0.4，但同样无 reconciliation。

### 5.4 统一导入动作与执行 CLI（build/运行期共用）

v0.2 的数据导入统一为四类受约束 action；`rootfs-build`（服务端 builder）与 `first-boot`（节点 agent）共用同一 action、
ItemSpec 字段与 §5.2 八步执行契约，差异只在执行者、目标上下文与持久化（见下表）。不引入自由 `packages`/
`standard_packages` 数组，也不按扩展名把普通文件自动提升为 action。

| action | 用途 | 输入 asset | 关键 ItemSpec 字段 |
|---|---|---|---|
| `managed-file` | 导入单个文件（如 `/etc/hosts.d/nodeforge`、motd） | `managed_file` | `destination`、`content_asset`、`mode`、`owner`、`group` |
| `archive` | 导入目录树或自定义软件包（`tar.bz2`） | `archive` | `archive_asset` |
| `script` | 执行受审计自定义脚本 | `script` | `script_asset`、`interpreter`、`timeout_s` |
| `package` | 安装补充标准包/组/环境（RPM/DEB） | 引用 selection 或本地 repo | `selection`、`packages`、`group`、`environment`（至少一项，经本地 repo 解析校验） |

四类 action 均声明 `phase`、`idempotency_key`、`timeout_s`、`retryable` 与影响域；`item add/set` 用 `FIELD=VALUE` 精确字段，
parser 拒绝该 action 不适用的字段。`repository`/`standard_packages` 旧 action 按 §5.2 迁移表退出，不新增同义 action。

**archive 规则**（build/运行期通用）：读取 tar，若顶层存在 `./install.sh` 则解压到临时目录并以该目录为工作目录执行
`./install.sh`（退出码 0 且幂等，禁止隐式下载未声明内容）；否则直接把 payload 解压到 `/`。步骤作者始终以 `/` 为目标，
builder/agent 提供挂载或 chroot 上下文把写入落到对应 lower 或 overlay upper；manifest 只声明 SHA256（由 asset 提供），
不设 `script|extract` 策略、`target_root`、`install --root` 参数或 `NODEFORGE_TARGET_ROOT` 环境变量。

**provision-bundle item 编写**（复用 v0.1 §7.1 structured collection `item add/set/move`、`replace-items`、`--before/--after`、
`--unset`）。字段示例见 `V0_2_CLI.md` §6。`managed-file` 的 `destination` 为 `/` 下绝对路径（rootfs-build 落 lower、first-boot
落 overlay upper）；`archive` 无 `destination`，按 archive 规则解压到 `/` 或在临时目录执行 `install.sh`；`script` 由
`script_asset` 提供受审计可执行内容；`package` 的 `packages`/`group`/`environment`/`selection` 至少一项，均经本地
repository 解析校验、幂等。

**build 期与运行期差异**（同一 action、同一字段、不同执行者）：

| 维度 | `rootfs-build`（build 期） | `first-boot`（运行期） |
|---|---|---|
| 执行者 | 服务端 rootfs builder，无节点 agent、无 enrollment | node-bound agent，无 enrollment（身份由 `nodeforge.node_id` cmdline/boot.json 携带） |
| 目标上下文 | builder 提供 chroot（按需 bind-mount `/dev`/`/proc`/`/sys` 与匹配内核，见 §4.4），步骤以 `/` 写入只读 lower | agent 在已切根系统写 overlay upper，`/` 为运行系统 |
| 持久化 | 烤入 rootfs digest，跨启动只读不变 | diskless 写临时 overlay（per-boot），install 写磁盘 |
| 脚本约束 | build chroot（按需 /dev/proc/sys + 匹配内核）内执行，须 build-safe、幂等；驱动/dkms 须声明影响域 | 运行系统执行，受 bounded action 与 finalizer 约束 |
| 触发 | 显式 `node rootfs build --if-input-digest`；readiness 只读 | agent 切根后执行 rootfs 内 fixed bundle payload |
| 失败语义 | 阻止 rootfs ready，不发 succeeded，不入节点 session | step failed 可 retry；不回写或倒退已完成 BootSession |

**日志、进度与结果回传**（统一 step I/O，按执行者分流）：统一 step 返回 `{changed, status, summary, outputs, warnings}`；
八步顺序固定（§5.2），任一步失败不得发布 succeeded。事件 `provision.step.started/succeeded/warned/failed`，fields 固定含
`source`（`builder` 或 `runner`）、`phase`、`step`、`run_id`、action、稳定 reason；运行期事件额外含 `node_id`，rootfs-build
事件额外含 `rootfs`。`rootfs-build`：事件 `source=builder`，记入 build manifest/audit（未上节点，不回传节点）；进度经
rootfs digest 预览与构建日志暴露，失败阻止 rootfs ready。`first-boot`：事件 `source=runner` 经 `event_url` 回传；脚本
stdout/stderr 仅留最后 2048 bytes 转义摘要；断网只保留本地失败信息，不中断已切根；`plan` 预览无副作用，`apply` 需目标
revision，`retry` 只重跑明确 retryable 的失败 step。脱敏：token、Authorization、URL query、未声明输出不得进服务日志或 Event；
敏感输出按 action 声明规则裁剪。

### 5.5 按版本 CLI 参考

> 完整 CLI 接口（命令树/flag/FIELD=VALUE/示例）见 `V0_2_CLI.md`；本节按版本给出概览。

全部版本复用 v0.1 资源-动作树（`nodeforge <resource> <action>`）、三组 collection 操作、Assets 子资源与
`--from-file/--input`、`-o/--output`、`-c/--config`、`--debug`。catalog 写仍经 daemon owner，不增加
可绕过事务的 catalog path 写入口。新命令必须先进入 typed
PropertySpec/CollectionSpec/ItemSpec 再给 handler；预留 enum/空 handler 不算实现。

**v0.2（diskless）**：`profile create --kind diskless`、`profile set diskless.provision.bundle/overlay.*/failure.*`、
`node add/set`、`assets managed-file|archive|script import`、`assets provision-bundle create/item add/set/move/replace-items`、
`assets nodeforge-initrd config/build`、`node rootfs plan/build/status`、`node diskless retry`、`node postprocess show`、
`node trace`、`runtime dhcp-leases|tftp-sessions`、`events list|follow|types`、`nodeforge status`。

**v0.3（PXELINUX/BIOS install）**：`node set firmware.mode=bios`（schema v5）、`profile set install.post_install.bundle`、
`install-post` phase item。

**v0.4（延后增强项）**：多 NIC/VLAN/bonding、大规模容量压测与 install 侧 agent 的 CLI 随其设计落地；
reconciliation/远程控制为永久非目标，无对应 CLI（见 §7）。v0.2/v0.3 不提供这些命令的 help/handler，预留 enum 不算实现。

## 6. 对当前 v0.2 脚手架的代码影响

| 当前代码 | 结论 | v0.2 变更 |
|---|---|---|
| `model.ProfileConfig`、`BootKind` | v3 Profile 和 BootKind 都只有 install；`ProfileMode` 已不存在，legacy diskless 只保留为迁移 blocker | schema v4 基于冻结 v3 新增 tagged kind（设计名 `ProfileKind` = 代码 `BootKind` `model.zig:329`，v0.2 扩 `install|diskless`）；不恢复旧 mode/nullable source |
| `AssetKind.kernel/nodeforge_initrd/rootfs`、`BootBundleConfig` | `kernel` 当前语义是 installer kernel；`BootBundleConfig.rootfs` 会造成 Profile -> plan -> rootfs -> bundle 构建环 | v4 新增 `runtime_kernel` kind；bundle 删除 rootfs ref，固定 source+runtime kernel+initrd revisions；DeliveryManifest 绑定派生输出 |
| `boot/target.zig:resolve` | 当前无 `resolveDiskless`，`resolve` 只调用 `resolveInstall`；文件中的 diskless 注释是过时说明 | 新增只消费 session DisklessEffectivePlan snapshot 的明确分支并补负向验证 |
| `http/server.zig:bootConfig`、`http/routes.zig` | BootKind 仅 install，handler 无 diskless payload 分支，route table 无 node-bound rootfs artifact 路由 | 增强类型 DTO、node-bound rootfs route、Range/ETag/auth |
| `provision/runner.zig` M4 install_post | repository/`standard_packages` owner 冲突，且没有 M7 phase/status/retry | v0.1 先迁为 managed-file bundle；M7 在同一 ItemSpec/resource 上扩展 tagged action、phase 和运行态 |
| `AssetKind`/`ProvisionAction`（仅 `managed_file` 等） | 缺 `archive`/`script` asset kind 与 `archive`/`script`/`package` action，无统一 build/runtime 执行差异 | 增 §5.4 四类 action 的 tagged ItemSpec、`archive`/`script` asset kind 与 import CLI |
| `main.zig` 通用 asset import | 可接受预留 kind，但无 rootfs/initrd/boot-bundle/diskless resource-action tree | 复用 command modules、spec help 和 OutputDocument，不回到直接 writer |
| `boot_session.Phase`/`node_status.Phase` 中混排的 install/diskless enum | 只有预留标签，`node_status.running` 无 kind，可能形成两个投影或错误拼接 | 建 `NodeCurrentState` tagged union + 唯一 reducer/映射；每 Node 单 active session，历史仅 trace；补冲突/换 kind E2E |

## 7. 明确非目标

- DHCPv6、IPv6 target network 或 IPv6 PXE；这是项目永久非目标。
- by-id、serial、WWN 或其他稳定磁盘 selector；这是项目永久非目标，磁盘配置继续使用 v0.1 的 `/dev/...` 路径契约。
- 数据库、远程多租户管理平面或通用配置管理平台。
- Kubernetes/Slurm/Ansible 类集群编排。
- 未经强类型约束和审计的任意远程命令执行。
- reconciliation/远程控制：服务端不检测已部署节点 drift 后远程主动触发 agent 重跑收敛，agent 永远是开机确定性顺序执行
  （diskless/install 通用）；drift 仅报告（v0.1 既有）不自动修复。这是项目永久非目标。
- v0.2 不提供持久化 overlay、跨重启 rootfs partial 或稳定无盘 SSH host identity；这些需要独立 secret/backend、生命周期和恢复设计，
  不能把共享 host private key 或节点本地残留当作实现。
- v0.2 不支持 PXE 阶段纯静态、多 NIC、VLAN、bonding 或下载后切换地址/子网；该项延后到 v0.4，需显式 capability 扩展，
  不得由 initrd 猜测或静默接受。
- 在线/远程 mirror rootfs 模式或可切换的 `local-only` 开关；v0.1 删除 `connectivity.mode` 正因 `local-only` 是唯一行为，M5
  rootfs/initrd 恒 `local-only`，不存在 online 变体，也不新增 `local-only` PropertySpec。
- 可切换的 rootfs 形态（`ram_rootfs` 等全内存模式、`diskless.overlay.mode` 字段）作为 v0.5 单独项；v0.2 固定 `squashfs_overlay`，
  不提供 mode 字段（同上单值无选择意义逻辑）。
- NFS root（任何形态）、iPXE 菜单/脚本、远程或节点上构建 rootfs（agent 驱动）。
- enrollment/credential 机制（运行期节点认证 secret）；agent 身份由 `nodeforge.node_id` cmdline 携带，全版本不引入。
- 跨不可信网络 TLS/mTLS、远程管理。

## 8. 文档与实现规则

- v0.2 的 schema 只能扩展 v0.1 owner，不得复制字段到新的资源对象。
- 新的 CLI/API key 必须先进入 typed PropertySpec/CollectionSpec/ItemSpec。
- 所有 persisted/effective/runtime 输出继续遵守 v0.1 JSON 分层。
- 新的 list/item mutation、help、show 和 API operation path 必须通过 v0.1 同一组 registry contract/golden tests。
- 每个里程碑必须同时具备代码、自动化、可复现系统验证和更新后的审计记录。
- 预留 enum、空 handler、设计命令和 resolver 分支均不算实现证据。

历史 M5-M7 详细设想仍可在
[`archive/M0_M7_LEGACY_DETAILED_DESIGN.md`](../archive/M0_M7_LEGACY_DETAILED_DESIGN.md) 对照阅读；与本文或 v0.1 契约冲突时，
必须先更新设计再实现，不能依赖旧章节中的隐式 fallback。

## 9. v0.2 完成标准

各版本按其里程碑具备代码、自动化、可复现系统验证和迁移证据后完成；某一里程碑不能借用另一个里程碑的设计或脚手架作为
完成证据。v0.2 只含 M5（diskless）与 M7 diskless 后处理（`rootfs-build`/`first-boot`）；M6 与 M7 `install-post` 属 v0.3、
install 侧 agent 属 v0.4（reconciliation/远程控制为永久非目标，见 §7），其完成标准一并记录以保持连续性，但不计入 v0.2 完成。

### 9.1 M5（v0.2）

- schema v4 plan/apply/rollback 将每个 v3 Profile 无损映射为 `kind.install`，旧 parser 不接受 nullable v4 半成品。
- diskless Profile、rootfs、nodeforge-initrd 和 boot-bundle 的 PropertySpec/CollectionSpec/ItemSpec、Assets CLI/API、
  exact-key show/help 和 transaction 全部通过 contract test。
- rootfs 由完整 `rootfs_input_digest` 可复现构建/缓存；Profile 或 Node software delta 与实际文件系统内容一致。
- node-bound boot-config 和 rootfs GET/HEAD/Range 通过跨 Node 越权、token 过期、If-Range、断点续传、错误 digest、
  feature mismatch、重复失败 quarantine 和 daemon restart-resume 负向测试。
- BootConfig fixture 证明只含 `$6$` hash/public key，boot.json、access log、Event、错误和 CLI 输出均不含明文、hash、
  private key 或 token；initrd 切根前清零 capability。
- `local-only` rootfs 静态检查和隔离网抓包证明无公网 mirror/metalink/GeoIP/vendor NTP/update，全部 initrd URL 使用
  server IP；静态目标地址不等于 MAC reservation、MAC 不匹配和 renderer 缺失均在切根前失败。
- BootSession 覆盖 DHCP/TFTP/boot-config/initrd 全链路、失败/过期分支、重复/跳跃/回退/错绑拒绝及 quarantine gate，
  `node_status` 不丢失早期诊断状态。
- Node current state 是 `kind` tagged union；同一 Node 不可同时存在 install/diskless current projection 或两个
  active session。跨 kind 换绑仅在 `deploy=false` 且无 active/recoverable session 时允许，历史只进 trace。
- `squashfs_overlay`（v0.2 唯一 rootfs 形态）通过 UEFI x86_64/aarch64 QEMU smoke + VMware 虚拟机部署（compute_use）
  实机代理验证；至少一架构完成断网恢复、switch_root、running event 和 retry 闭环，覆盖真机 NIC/firmware/内存差异。
  大镜像内存预算场景（squashfs compressed size + tmpfs upper + initrd reserve）在可信 inventory 存在时须
  readiness 校验通过；无 inventory 时 readiness 明示 unknown/required minimum，并由 initrd 实测硬闸。可切换 rootfs 形态
  （`ram_rootfs` 等）属 v0.5，不纳入 v0.2 验收。
- install Profile 的既有 PXE、全部 v0.1 storage/software/override 和 schema v3 migration 回归不退化。

### 9.2 M6（v0.3）

- schema v5 migration/rollback 将全部 v4 Node 显式物化 `firmware.mode=uefi`，活动 session 保护和 digest 预览通过。
- `firmware.mode` migration、claim/config、DHCP observed mismatch、readiness 和 digest 覆盖完整。
- BIOS x86 PXELINUX DHCP/TFTP/config、kernel/initrd/cmdline、install generation gate 和 diskless 适用性通过 QEMU
  smoke；`http_accel` 对 BIOS fail closed。
- 每个新增发行版版本逐项发布 adapter capability matrix，并通过 install answer、software index、默认值、
  unsupported/not-applicable 负向测试及至少一条可复现安装验证。

### 9.3 M7（rootfs-build/first-boot -> v0.2；install-post -> v0.3；install-agent -> v0.4；reconciliation 永久非目标）

- schema v4 migration/rollback 将 v3 managed-file bundle 无损映射到 canonical tagged action/phase；v0.3 schema v5
  仅增加 `install-post` 适用性，不另建 bundle owner；同一 Assets owner 扩展后的
  tagged ItemSpec 拒绝 action/phase 非法字段组合。
- bundle CRUD、ordered item mutation、atomic file replacement、plan/apply/status/retry、If-Match 和幂等键通过并发及
  crash-recovery 测试；plan 无副作用。
- `install-post`、`rootfs-build`、`first-boot` 各 phase 只执行明确允许的 bounded action；script 来自受管 asset，
  日志/stdout/stderr 有界且脱敏，不存在 argv script/JSON 或任意未审计远程命令入口。
- package action 只引用 snapshot 中的 effective software/capability，不存在 `standard_packages` 或自由 packages 数组。
- schema/CLI/API/event 对 canonical phase 的旧名迁移唯一且八步顺序稳定；保护域 action 在 plan 阶段被拒绝，每个 phase
  的 finalizer 失败均阻止 succeeded 发布。
- first-boot 节点身份（`nodeforge.node_id` cmdline/boot.json）与 best-effort 事件回传（带 node_id）通过测试；回传失败
  本地兜底不阻塞后处理；无 enrollment/credential（reconciliation/远程控制为永久非目标，见 §7），验收确认 agent 无远程
  任务入口、无 drift 重跑，first-boot 一次性顺序执行。
- Kickstart、Autoinstall、rootfs build 和 diskless 对同一 bundle revision 的 plan/status/audit 语义一致。

## 10. 变更记录（设计收敛轨迹）

**第一轮（属性适用性 / 无盘构建 / 运行期 agent / local-only / 网络）**：补全无盘属性适用性矩阵；补 base rootfs 构建工具链
（lorax/debootstrap、pin capability、local-only）、`rootfs-build` phase、构建期/启动期边界表；补 step I/O、两类包（标准经本地
repo / 非标准 tar.bz2+install.sh）、保护域、事件回传；固化为不变式并补贯穿影响；补 renderer 按 adapter 选择、MAC 绑定。

**第二轮（BootConfig / 后处理与 agent / 网络 / local-only）**：补 BootConfig 定义与 boot 写入流程、per-Node 投影、共享参数来源、
boot-time 职责划分（initrd 写网络 vs agent 跑 first-boot）。

**第三至十一轮（variant 收敛 / CLI / rootfs 查询 / BootConfig 澄清）**：variant（节点下载/引导的 rootfs）按 effective digest 跨 Node
共享；最终取消 variant 与暴露的 base rootfs 两层概念，收敛为单一共享 rootfs（OS 层为 builder 内部按 software digest 缓存、不暴露为
独立 Resource）；补 rootfs 查询/构建 CLI；补 BootConfig per-boot per-Node 短时 DTO 流程。

**第十二轮（状态机统一 / reconciliation 升级永久非目标 / management-credential 边界澄清 / 实现细节细化）**：单一 canonical `Phase`
枚举覆盖两条流、所有者分离（BootSession 传输态 + deployment 投影）；reconciliation/远程控制升级永久非目标；management-credential
边界澄清（传输 token vs daemon 管理 API 凭据隔离，与已移除 enrollment 无关）；新增 `V0_2_IMPL_DETAILS.md`（状态机/协议栈/effective compiler）。

**第十三轮（实现细节优先级 4-8 / node list 状态 schema 草案 / enrollment 残留清理）**：`V0_2_IMPL_DETAILS.md` 补 rootfs builder / schema
迁移 / event 脱敏 / 当时的 GC 草案 / bundle 八步；GC 草案已在第二十轮从 v0.2 删除；`node list` 统一状态 schema。

**第十四轮（diskless 核心闭环对齐 1↔2↔3）**：3->2->1->3 控制流闭环、协议事件->状态迁移->校验源映射、双检点（readiness+validator）、
pin 完整性不变式、反馈闭环；§2.1 DHCP DISCOVER 补 rootfs ready 闸。

**第十五轮（闭环验收矩阵 + CLI 工具流完善审计）**：`V0_2_IMPL_DETAILS.md` §10 验收矩阵（fail-closed 断言）；补 `diskless.provision.bundle`
字段、first-boot 每次开机执行语义。

**第十六轮（旧 CLI 草案）**：当时新增 8 阶段命令树和 `node postinstall show`；该命名与隐式 build 流程已由
第十八/十九轮的 11 阶段 `rootfs plan/build/status`、`postprocess show` 与两级 readiness 取代。

**第十七轮（review：`runtime` phase 残留清理 + 命名澄清）**：canonical phase = `install-post|rootfs-build|first-boot`（无 `runtime`），清理 11
处把 `runtime` 当 phase 的残留（版本表/§5.4/CLI 示例/§9/`DISKLESS_FINAL`），执行时序“runtime”统一为“运行期”；§10 历史按惯例保留。补
`ProfileKind`=`BootKind`、BootConfig `schema_version` v2 命名空间澄清。全部改动未触碰代码、未改变 v0.1 冻结 owner 或 v0.2 进入条件。

**第十八轮（完整 diskless 流程与构建环修复）**：新增 `V0_2_DISKLESS_WORKFLOW.md`；拆分 desired plan、
rootfs input、delivery digest；BootBundle 去除 rootfs ref，新增 runtime-kernel；readiness 拆 build/boot 两级；
明确 dnf --installroot/debootstrap、first-boot payload 预置、原子 rootfs 发布和从零 CLI 流程。

**第十九轮（状态互斥与 handoff/security）**：Node current state 收敛为 install|diskless tagged union、单 active
session 和唯一 `STATE`；first-boot 仅作 postprocess 摘要；补 pre-switch `/run` move-mount、delivery snapshot、
per-session credential capsule，禁止 token 进入 kernel cmdline。

**第二十轮（移除 v0.2 rootfs GC / readiness 与 CLI 提示）**：已发布 rootfs 改为只增不删、容量告警和新
build fail-closed；删除 GC CLI/引用计数/mark-sweep。将必要的在途一致性概念改名为 delivery snapshot；补
build/boot readiness 定义及跨 kind 换绑的 blockers/next commands。

核心契约对齐结论：v0.2 与 v0.1 在所有权、override 命名空间、`/dev/...` 磁盘契约、IPv4-only、`software.*` 双集合、
`kernel_args.add/remove`、`ProfileKind=install|diskless`、schema 版本号（v3/v4/v5/v6/v7）上无遗留冲突。除 `local-only` 系
v0.1 删除字段后的孤立遗留（已固化为不变式）外，v0.2 未发现因 v0.1 变动而失效或需废弃的条款。全部改动未改变 v0.1 冻结 owner 或
v0.2 进入条件，且未触碰任何代码。
