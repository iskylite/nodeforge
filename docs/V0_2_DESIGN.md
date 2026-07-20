# NodeForge v0.2 设计范围

状态：未开始。本文只定义 v0.2 边界和进入条件；在 v0.1 完成前，不把这里的类型、命令或脚手架
描述为已实现能力。

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

### M5：内存无盘启动

- 将 v0.1 的 install Profile 扩展为 `ProfileKind = install | diskless` tagged union；不增加 discovery Profile。
- boot bundle 的 kernel、NodeForge initrd、rootfs 与 kernel release 联合校验。
- node-bound、capability-authenticated rootfs HTTP GET/HEAD/Range。
- 小 initrd 联网、配置获取、digest 校验、下载恢复、overlay 和 switch_root。
- `squashfs_overlay` 主路径以及受约束的 `ram_rootfs`。
- diskless readiness、status、failure quarantine、retry 和事件闭环。
- target-system、software 和 kernel arguments 直接复用 v0.1 effective compiler。

Diskless 不消费安装磁盘选择器，但必须复用同一个 Profile/Node override 模型，不能建立第二套
users/packages/network 默认值。

### M6：支持矩阵增强

- BIOS x86 PXELINUX。
- Rocky/RHEL 系和 Ubuntu 后续 LTS 的显式 adapter capability matrix。
- bootloader、发行版版本差异、错误分类和长期运行回归。
- 生产规模容量、失败恢复和压力验收。

IPv6 是项目永久非目标，不进入 M6 或后续 schema。BIOS 与更多发行版版本彼此独立，不能捆绑实现。

### M7：补充包和后处理增强

- archive、受控 script、first-boot 和 runtime provision action。
- bundle CRUD、plan、status、retry、日志脱敏和幂等。
- install、rootfs build 和 diskless 三条链路共用的强类型步骤。
- 已部署节点 reconciliation 的明确边界。

M7 扩展 v0.1 已有的最小 install-post provision bundle，不改变其 Assets owner。它复用 v0.1 软件
capability/selection，不再引入 `standard_packages` 作为第四个包配置事实源。

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

M5 使用 schema v4，不能让 schema v3 parser 长期接受 nullable v0.2 半成品。M6 若新增 `firmware.mode` 等
持久 shape 使用 schema v5，M7 扩展 provision action/phase 使用 schema v6；不能在已经发布的 schema 号下静默
改变 shape。每次迁移都需 plan/digest/apply/rollback、活动 session 保护和 manifest transaction。v0.1 install
Profile 在 v4 映射到 `ProfileKind.install`；只有完整 boot bundle 引用和 readiness 能通过时才允许创建 diskless Profile。

### 3.1 schema v3 到 v4 的唯一转换

| v0.1 schema v3 事实 | v0.2 schema v4 处理 | 禁止的替代实现 |
|---|---|---|
| install Profile + `install_source` | 包入 `ProfileKind.install`，共享 policy path 原样保留 | 同时保留旧 nullable source 和新 kind |
| 无 diskless Profile | 新增 `ProfileKind.diskless` + 必填 `boot_bundle` | 在 v3 预留 nullable `boot_bundle` 或 mode |
| Node direct identity/network/storage | 原样继承；diskless effective 对 storage 标记 not-applicable | 建立 diskless 私有 network/storage 默认值 |
| Node policy overrides | 共享 `system.*`、`software.*`、`kernel_args`；install-only key 对 diskless fail closed | 为 diskless 复制 users/packages/kernel args |
| install source/repository software revision | rootfs build 和 diskless plan 固定引用同一 capability identity | rootfs 内包集合与 show/effective selection 各自漂移 |
| discovery policy/observation + claim | 原样继承 daemon-owned singleton、观察资源和审计 | 恢复 discovery Profile、startup unknown policy 或 unknown auto-diskless |
| schema v3 effective/digest | v4 compiler扩展 tagged branch，并保持一个 canonical digest 输入 | renderer/initrd/HTTP handler 各自补默认值 |

v4 migration 只改变 Profile 的外层 discriminated shape；不能借机移动 v3 已冻结 owner。转换计划必须逐个列出
Profile、引用它的 Node、旧/新 effective digest 和 active session 阻塞原因。rollback 恢复完整 v3 manifest；
不能生成 v3 无法表示的 diskless Profile 后再回滚到部分 nullable 数据。

## 4. M5 具体继承与变更

### 4.1 Profile 与 effective plan

M5 把 v0.1 单一 install Profile 扩展成 tagged union。持久 JSON 的 discriminant 本身就是对象，不使用
`kind="..."` 加多个 nullable sibling：

```json
{"kind":{"install":{"install_source":"rocky-9"}},"install":{...},"system":{...},"software":{...}}
{"kind":{"diskless":{"boot_bundle":"rocky-9-diskless"}},"system":{...},"software":{...}}
```

`kind.install.install_source` 与 `kind.diskless.boot_bundle` 是只在 create/change-kind transaction 中写入的
identity path，不参加普通 `profile set`，也不允许 Node override。v3 的 `install_source` 在 v4 migration 中
唯一映射到 `kind.install.install_source`。两种 kind 共享
`system.*`、`software.*`、`kernel_args` 和相同 Node override namespace；install-only 的 `install.*` 对 diskless
返回 `property.not_applicable`。Diskless effective compiler 忽略 Node `storage.boot_disk/additional_disks`，
但不删除这些 Node direct facts，
因为同一 Node 日后可以重新绑定 install Profile。

M5 新增的最小 Profile policy 面为：

| Profile path | 类型/默认 | Node override | 约束 |
|---|---|---|---|
| `diskless.overlay.mode` | `squashfs_overlay|ram_rootfs`，默认 `squashfs_overlay` | `overrides.diskless.overlay.mode` | ram_rootfs 需要完整 rootfs 进入内存 |
| `diskless.overlay.tmpfs_percent` | 10-80 的整数，默认 50 | `overrides.diskless.overlay.tmpfs_percent` | 只适用于 squashfs_overlay |
| `diskless.failure.max_attempts` | 1-10，默认 1 | `overrides.diskless.failure.max_attempts` | 达到预算后 quarantine |
| `diskless.failure.backoff_seconds` | 0-3600，默认 0 | `overrides.diskless.failure.backoff_seconds` | 不负责 BMC 重启 |

这些字段只适用于 diskless kind；install Profile mutation 返回 `property.not_applicable`。内存容量来自 inventory，
只参与 readiness，不写回 Profile 默认值。`ram_rootfs` 必须验证 rootfs uncompressed size 与目标可用内存预算；
inventory 缺失时 not ready，不能假设机器内存足够。

Rootfs build 必须固定 software capability revision，并消费与 Profile 查询相同的 environment/group/task/package
selection；metapackage 仍作为可查询 capability kind，通过 `software.packages.include` 选择，不新增独立 selection。
M5 固定采用 node-specific rootfs variant：rootfs builder 以 base rootfs digest、完整 effective software、
target-system policy 和 builder version 生成 variant digest并缓存；相同输入复用，任一输入变化产生新 variant。
Node 只有在 variant ready 后才可 diskless boot。M5 不依赖尚未实现的 M7 first-boot 安装包，也不允许先启动
base rootfs 后把缺失 package 留给运行期补齐。M7 可增加显式 reconciliation，但不能改变历史 session 的 pinned variant。

Base rootfs 是可复用 Resource；variant 是由 effective plan 派生的 node-bound artifact，不是新的 catalog Resource。
variant cache key 必须包含 Node identity、base digest、effective system/software digest 和 builder version，即使两个
Node 当前配置相同也不能共享含密码 hash、authorized key 或 hostname 的最终 artifact。通用 Assets list/export
不暴露 variant；只有绑定 Node/session 的 capability route 可读取。无 Profile/Node/session 引用且超过 retention 的
variant 可由有审计的 GC 清理，Runtime 只记录 build/status/consumer，不反向写入 desired 配置。

### 4.2 Assets 资源树

v0.2 延伸 v0.1 的 Assets tree，不新增顶级 `rootfs`、`initrd` 或 `boot-bundle` 命令：

```text
nodeforge assets rootfs list|show|import|validate
nodeforge assets nodeforge-initrd list|show|build|validate
nodeforge assets boot-bundle list|show|create|set|remove|validate
nodeforge profile capabilities show <profile>
nodeforge node capabilities show <node>
```

rootfs manifest 的 files/features、initrd modules/features 和 boot-bundle compatibility constraints 若为 scalar
collection，使用 values 命令；manifest entries 或 build steps 若为 structured collection，使用 item CRUD/
`replace-items --from-file`。`assets boot-bundle create` 使用 typed ref flags 或 canonical `KEY=VALUE`，不接受
内嵌 JSON object。Assets detail 的 stored/capabilities/runtime sections 继续遵守 v0.1 输出和 exact-key 规则。

资源最小 manifest 契约：

| Resource | 必填持久事实 | 只读派生事实 |
|---|---|---|
| rootfs | format、arch、content digest/size、uncompressed size、builder version、software capability revision、effective system/software digest、features | validation/readiness、variant consumers |
| nodeforge-initrd | arch、kernel release、content digest/size、builder version、modules/features | validation/readiness、supported overlay/network features |
| boot-bundle | kernel ref、initrd ref、rootfs/base-variant ref、arch、kernel release、required features | joint digest、compatibility/readiness、consumer count |

Resource name 不是内容身份；内容或 builder 输入变化必须发布新 revision/digest。Boot bundle 不复制 kernel/initrd/rootfs
的 digest 为可独立修改字段，而是在 transaction 中 pin 各资源 revision 并派生 joint digest。

### 4.3 交付与运行态

- 新增 node-bound boot-config DTO、rootfs GET/HEAD/Range、ETag/If-Range 和 capability auth。
- initrd 消费的字段来自 pinned effective plan；digest、required features 和 URL 不能由 HTTP handler 临时拼默认值。
- rootfs download、verify、overlay、switch_root、quarantine、retry 和事件使用独立 runtime state，不写回 Profile。
- boot bundle kernel release、arch、rootfs/initrd digest 和 feature compatibility由 validator/readiness 同时校验。

DisklessEffectivePlan 至少固定：Profile/Node/resource revision、arch、boot bundle、kernel/initrd/rootfs variant
digest、network、target system、effective software、kernel arguments、overlay mode/limit、required initrd features
和全部 node-bound URL。BootSession 保存该计划的 digest 和 immutable capability identity；服务重启只能按相同
digest 恢复，不能重新编译后继续旧 session。

Boot-config 只返回 initrd 实际需要的 DTO：session/capability、network、rootfs URL/digest/size、Range recovery、
overlay、target-system projection、event URL 和过期时间。token 绑定 node、session、HTTP method/path 与短有效期；
不能访问其他 Node rootfs，也不能升级为 management credential。完整或重复 hash mismatch、feature mismatch、
过期 token、越权 Range、switch_root 失败都进入稳定 error code、`diskless.failed` 和 quarantine。

状态机固定为：

```text
ready -> booting -> downloading -> verifying -> mounting -> switching_root -> running
                                  \-> failed/quarantined
```

`nodeforge node diskless retry <node>` 只清除终态 failure quarantine；不创建 install generation、不修改 Profile、
不远程重启。存在活动 session、`deploy=false`、Profile 非 diskless 或 desired digest 已变化时 fail closed。

## 5. M6/M7 对新契约的影响

### 5.1 M6

BIOS 支持增加的是 Node confirmed firmware property和 bootloader adapter，不是 Profile 的物理磁盘 owner。
M6 增加 Node direct `firmware.mode=uefi|bios`；schema v4 到 v5 的既有 Node migration 默认为 `uefi`，新认领 Node 必须由管理员
确认。DHCP observed firmware 只用于 mismatch/readiness 检查，不自动改写 desired property。该字段不能放入
Profile 或 `overrides`。
partition policy 仍使用 v0.1 的逻辑磁盘角色，由 effective compiler结合 firmware生成 ESP/biosboot 要求。
v0.1 保留的 `node.http_accel` 继续只适用于 UEFI GRUB；BIOS PXELINUX capability 必须报告
`property.not_applicable`，不能接受后静默忽略，也不能为 BIOS 新增另一个同义传输开关。

更多发行版版本只扩展 adapter capability registry。新 adapter 必须逐项声明 v0.1/v0.2 PropertySpec 为
`native|translated|not-applicable|unsupported`，并通过同一软件 capability index；不能复制一套 distro-specific
CLI key。BIOS、发行版扩展和容量压测不会改变 IPv4-only 或 `/dev/...` 磁盘路径契约。

### 5.2 M7

Provision bundle 继续使用 v0.1 的 Assets/resource 和 Profile reference；M7 只扩展 ItemSpec、phase 和运行态。CLI：

```text
nodeforge assets provision-bundle list|show|create|remove
nodeforge assets provision-bundle item add <bundle> steps name=configure-agent action=managed-file ...
nodeforge assets provision-bundle item set <bundle> steps configure-agent FIELD=VALUE...
nodeforge assets provision-bundle item move <bundle> steps configure-agent --after repositories
nodeforge assets provision-bundle replace-items <bundle> steps --from-file steps.yaml --input yaml
```

steps 是有序 structured collection，以 step name 为 identity，所有替换原子发布。archive、managed-file、受控
script、first-boot 和 runtime action 各自有 tagged ItemSpec；不适用字段必须被 parser拒绝。script 内容从文件或
受管 asset 引用读取，不允许 argv 内嵌脚本/JSON。包安装 action 引用 effective software selection 或 capability id，
不得重新引入 `packages`/`standard_packages` 自由数组。

M7 script 使用独立 `assets script` 类型，持有 digest、interpreter allowlist、最大运行时间和审计 metadata；
不能引用 v0.1 `assets managed-file` 作为可执行内容。archive 同样是显式 asset kind，不根据扩展名把普通文件
自动提升为 action。

phase 固定为 `install-post|rootfs-build|first-boot|runtime`。每个 action 显式声明允许 phase、输入 asset、幂等 key、
timeout、retryability 和敏感输出规则；同一 step 的 `(bundle revision, effective digest, node, phase, idempotency key)`
唯一标识一次执行。`plan` 无副作用，`apply` 需要目标 revision，`retry` 只重跑明确 retryable 的失败 step。
自动 reconciliation 默认关闭，只能由显式 policy 和 bounded action 开启；M7 不成为通用远程命令或配置管理平台。

## 6. 对当前 v0.2 脚手架的代码影响

| 当前代码 | 结论 | v0.2 变更 |
|---|---|---|
| `model.ProfileMode.diskless` 与 nullable `boot_bundle` | 只是预留，且 shape 与目标 tagged union 不同 | schema v4 时基于冻结的 v3 Profile 扩展，不保留多个 nullable source |
| `AssetKind.nodeforge_initrd/rootfs`、`BootBundleConfig` | 只有资源名称和 tuple，未形成 build/manifest/readiness | 增 digest/feature manifest、validator、Assets CLI/API 和 transaction |
| `boot/target.zig:resolveDiskless` | 能拼 kernel/initrd/rootfs cmdline，但上游 DTO/认证/consumer 缺失 | 改为只消费 pinned DisklessEffectivePlan，并补负向验证 |
| `http/server.zig` diskless boot-config 空对象 | 不能驱动 initrd | 增强类型 DTO、node-bound rootfs route、Range/ETag/auth |
| `provision/runner.zig` M4 install_post | repository/`standard_packages` owner 冲突，且没有 M7 phase/status/retry | v0.1 先迁为 managed-file bundle；M7 在同一 ItemSpec/resource 上扩展 tagged action、phase 和运行态 |
| `main.zig` 无 M5-M7 resource tree | 预留 model 不等于 CLI 可用 | 复用 command modules、spec help 和 OutputDocument，不回到直接 writer |
| 当前 diskless/event unit tests | 只验证分支或枚举 | 增 QEMU UEFI smoke、损坏/中断恢复、auth、digest drift 和 lifecycle E2E |

## 7. 明确非目标

- DHCPv6、IPv6 target network 或 IPv6 PXE；这是项目永久非目标。
- by-id、serial、WWN 或其他稳定磁盘 selector；这是项目永久非目标，磁盘配置继续使用 v0.1 的 `/dev/...` 路径契约。
- 数据库、远程多租户管理平面或通用配置管理平台。
- Kubernetes/Slurm/Ansible 类集群编排。
- 未经强类型约束和审计的任意远程命令执行。

## 8. 文档与实现规则

- v0.2 的 schema 只能扩展 v0.1 owner，不得复制字段到新的资源对象。
- 新的 CLI/API key 必须先进入 typed PropertySpec/CollectionSpec/ItemSpec。
- 所有 persisted/effective/runtime 输出继续遵守 v0.1 JSON 分层。
- 新的 list/item mutation、help、show 和 API operation path 必须通过 v0.1 同一组 registry contract/golden tests。
- 每个里程碑必须同时具备代码、自动化、可复现系统验证和更新后的审计记录。
- 预留 enum、空 handler、设计命令和 resolver 分支均不算实现证据。

历史 M5-M7 详细设想仍可在 `DETAILED_DESIGN.md` 对照阅读；与本文或 v0.1 契约冲突时，
必须先更新设计再实现，不能依赖旧章节中的隐式 fallback。

## 9. v0.2 完成标准

v0.2 只有在 M5-M7 均具备代码、自动化、可复现系统验证和迁移证据后完成；某一里程碑不能借用另一个
里程碑的设计或脚手架作为完成证据。

### 9.1 M5

- schema v4 plan/apply/rollback 将每个 v3 Profile 无损映射为 `kind.install`，旧 parser 不接受 nullable v4 半成品。
- diskless Profile、rootfs、nodeforge-initrd 和 boot-bundle 的 PropertySpec/CollectionSpec/ItemSpec、Assets CLI/API、
  exact-key show/help 和 transaction 全部通过 contract test。
- rootfs variant 由完整 effective digest 可复现构建/缓存；Profile 或 Node software delta 与实际文件系统内容一致。
- node-bound boot-config 和 rootfs GET/HEAD/Range 通过跨 Node 越权、token 过期、If-Range、断点续传、错误 digest、
  feature mismatch、重复失败 quarantine 和 daemon restart-resume 负向测试。
- `squashfs_overlay` 与 `ram_rootfs` 分别通过 UEFI x86_64/aarch64 中适用架构的 QEMU smoke；至少一个支持架构
  完成断网恢复、switch_root、running event 和 retry 闭环，其他支持矩阵不得仅用单元测试代替。
- install Profile 的既有 PXE、全部 v0.1 storage/software/override 和 schema v3 migration 回归不退化。

### 9.2 M6

- schema v5 migration/rollback 将全部 v4 Node 显式物化 `firmware.mode=uefi`，活动 session 保护和 digest 预览通过。
- `firmware.mode` migration、claim/config、DHCP observed mismatch、readiness 和 digest 覆盖完整。
- BIOS x86 PXELINUX DHCP/TFTP/config、kernel/initrd/cmdline、install generation gate 和 diskless 适用性通过 QEMU
  smoke；`http_accel` 对 BIOS fail closed。
- 每个新增发行版版本逐项发布 adapter capability matrix，并通过 install answer、software index、默认值、
  unsupported/not-applicable 负向测试及至少一条可复现安装验证。
- 2048 Node 安全天花板、配置的 512/1024 规模、Range/TFTP/DHCP 并发、状态持久化、失败恢复和长期运行压测
  有可重复报告；容量测试不能用扩大硬编码数组代替。

### 9.3 M7

- schema v6 migration/rollback 将 v3-v5 managed-file bundle 无损映射到 `install-post` phase；同一 Assets owner
  扩展后的 tagged ItemSpec 拒绝 action/phase 非法字段组合。
- bundle CRUD、ordered item mutation、atomic file replacement、plan/apply/status/retry、If-Match 和幂等键通过并发及
  crash-recovery 测试；plan 无副作用。
- install-post、rootfs-build、first-boot、runtime 各 phase 只执行明确允许的 bounded action；script 来自受管 asset，
  日志/stdout/stderr 有界且脱敏，不存在 argv script/JSON 或任意未审计远程命令入口。
- package action 只引用 pinned effective software/capability，不存在 `standard_packages` 或自由 packages 数组。
- reconciliation 默认关闭；开启后只处理声明允许、幂等且有预算的 action，并通过 drift、重复执行、部分失败、
  retry 和节点离线测试。
- Kickstart、Autoinstall、rootfs build 和 diskless variant 对同一 bundle revision 的 plan/status/audit 语义一致。
