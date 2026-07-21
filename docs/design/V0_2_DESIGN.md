# NodeForge v0.2 设计范围

状态：设计冻结，实现未开始。本文只定义 v0.2 边界和进入条件；在 v0.1 完成前，不把这里的类型、命令或脚手架
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
- `local-only` rootfs/initrd 离线策略、目标静态地址与 MAC reservation 一致性和 BootConfig secret 边界。
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

明文 password 是 desired 配置事实，不是节点交付格式。DisklessEffectivePlan 在受控编译阶段使用 v0.1
PasswordHasher 派生发行版兼容的 `$6$` hash；BootConfig 只携带 root/普通用户 hash 和 public authorized key，
绝不携带明文 password、SSH private key 或 bootstrap private key。hash、完整 `target_system`、capability 和请求/响应
body 均视为敏感数据：不得进入 access log、Event、错误信封或 CLI 普通输出，结构化诊断最多报告 changed/fingerprint
和非 secret 摘要。

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

Diskless bootstrap 固定使用 DHCPv4 和单个启动 NIC。目标系统若使用静态 IPv4，地址必须等于该 MAC 的
`node.ip` reservation，匹配 MAC、prefix、gateway、DNS 和 renderer capability 必须在 effective/readiness 阶段
共同校验。initrd 下载期间不切换地址，只向 overlay 写持久网络配置，由 `switch_root` 后的 NetworkManager/Netplan
接管同一地址；不一致必须在切根前以稳定 reason 失败，不能回退到未声明 DHCP 目标配置。PXE 阶段纯静态、多 NIC、
VLAN、bonding 或下载后切换地址/子网不属于 M5，只有 M6 新增显式 initrd feature、schema 和验收后才可支持。

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

Rootfs/initrd 构建的工具链和驱动放置属于 M5 的显式实现边界，而非未说明的 builder 自由度：

- NodeForge initrd 使用与目标发行版、版本、架构和 kernel release 匹配的 `dracut` 环境构建；MVP 不手工拼 cpio。
  build manifest 固定 builder image/environment digest、dracut 版本、命令、module/firmware 清单和输出 digest。
- 获取 BootConfig/rootfs、校验并挂载 lower/upper、完成 `switch_root` 前必需的 NIC、firmware、HTTP、SHA-256、
  squashfs、tmpfs 和 overlay 能力必须放入 initrd；缺一项即 bundle not ready。
- 只在切根后使用的 GPU、RDMA、监控、额外存储或业务驱动放入 rootfs，并与同一 kernel release 的 modules manifest
  联合校验。任何驱动若被启动路径提前需要，就必须提升为 initrd required feature，不能靠运行时偶然加载。

### 4.3 交付与运行态

- 新增 node-bound boot-config DTO、rootfs GET/HEAD/Range、ETag/If-Range 和 capability auth。
- initrd 消费的字段来自 pinned effective plan；digest、required features 和 URL 不能由 HTTP handler 临时拼默认值。
- rootfs download、verify、overlay、switch_root、quarantine、retry 和事件使用独立 runtime state，不写回 Profile。
- boot bundle kernel release、arch、rootfs/initrd digest 和 feature compatibility由 validator/readiness 同时校验。
- `local-only` variant 必须移除/禁用公网 mirror、metalink、GeoIP 和 vendor NTP 默认值，启动时禁止隐式
  update/upgrade/package install；time sync 关闭或只使用显式服务器。initrd 的 BootConfig、rootfs 和 event URL
  必须使用 NodeForge `server_ip` 字面地址，M5 不做 DNS fallback，也不访问其他地址。出口 ACL 是纵深防御，
  不能替代 rootfs 静态检查、隔离网抓包和运行时 fail-closed。

DisklessEffectivePlan 至少固定：Profile/Node/resource revision、arch、boot bundle、kernel/initrd/rootfs variant
digest、network、target system、effective software、kernel arguments、overlay mode/limit、required initrd features
和全部 node-bound URL。BootSession 保存该计划的 digest 和 immutable capability identity；服务重启只能按相同
digest 恢复，不能重新编译后继续旧 session。

Boot-config 只返回 initrd 实际需要的 DTO：session/capability、network、rootfs URL/digest/size、Range recovery、
overlay、target-system projection、event URL 和过期时间。除 `$6$` password hash 和 public authorized key 外不含任何
长期 secret；`/run/nodeforge/boot.json` 只保存 plan/config digest 与非 secret 摘要，mode 0600，且不保存 password hash
或 token。token 绑定 node、session、HTTP method/path 与短有效期；不能访问其他 Node rootfs，也不能升级为
management credential。initrd 在 `switch_root` 前清零 token。完整或重复 hash mismatch、feature mismatch、
过期 token、越权 Range、switch_root 失败都进入稳定 error code、`diskless.failed` 和 quarantine。

跨 DHCP/TFTP/HTTP/initrd 的 canonical BootSession 状态机固定为：

```text
dhcp_discover -> dhcp_offer -> dhcp_ack -> tftp_rrq -> tftp_complete
  -> boot_config_fetched -> initrd_started -> rootfs_downloading
  -> rootfs_verified -> rootfs_mounted -> switching_root -> diskless_running
```

历史概要中的 `pxe_seen`、`bootfile_sent`、`diskless_config_fetched` 分别是
`dhcp_discover`、携带 bootfile 的 `dhcp_ack`、`boot_config_fetched` 的展示别名，不是额外持久状态；v0.2 API、Event
和持久化只使用 canonical 名。`failed` 可从任一非终态进入，`expired` 只能由服务端超时进入；两者都是本次
session 的终态。`node_status` 可以投影上述状态，但不得用 `ready/booting/downloading` 等粗粒度枚举替代而丢失
早期诊断证据。重复同阶段上报幂等，跳跃、回退、错绑 node/session 一律拒绝。

Quarantine 是 Node 级 boot gate，不是 BootSession phase。一次 attempt 进入 `failed` 后按 pinned
`max_attempts/backoff_seconds` 计数；达到预算才进入 quarantine，并拒绝新 session。`diskless_running` 是启动成功
终态；切根后的 agent/reconciliation 失败属于 M7 runtime run，不回写或倒退已完成 BootSession。

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

旧详细设计名称只按下表迁移，schema v6、CLI、API、状态和事件不得继续写旧拼法：

| 历史名称 | v0.2 canonical phase | 迁移语义 |
|---|---|---|
| `install_post` | `install-post` | 原位无损迁移 |
| `rootfs_build` | `rootfs-build` | 原位无损迁移 |
| `firstboot` | `first-boot` | 原位无损迁移 |
| `diskless_boot` | `runtime` | 迁移后仍受 node/session/runtime capability 约束 |

每个 phase 的执行顺序固定为八步，跳过不适用步骤但不得重排：1）挂载/确认 target root；2）pin effective、bundle、
asset revision 并验证 action/phase/保护域；3）物化已发布的本地 repository 和输入 asset；4）执行只引用 pinned
effective software/capability 的 package action；5）校验并展开 archive；6）原子写 managed file；7）按声明顺序
执行受控 script；8）运行 TargetSystem finalizer 后原子发布 status/audit。任一步失败都不得发布 succeeded 状态。

TargetSystem 保护域包括 passwd/shadow/group/sudoers、sshd、各账号 authorized_keys、Netplan/NetworkManager、
resolver、locale/timezone/keyboard、software manifest、firewall 和 SELinux 配置/unit。managed-file、archive 和 script
声明影响域；触及保护域的 action 在 plan/validate 阶段直接拒绝，不能用 `--force` 绕过。finalizer 在每个 phase
末尾重新断言 effective owner、bootstrap/profile public key 合并和离线策略。

`first-boot`/`runtime` agent 不能把 DHCP lease、peer IP、PXE bootstrap proof、installer token 或已终态
BootSession capability 当作长期身份。首个 agent 连接只能用绑定 node 的一次性 enrollment 换取节点凭据；后续由
已建立节点凭据换取绑定 node、run、method/path、短有效期的 capability。凭据和 token 不进入 argv、URL、Event、
stdout/stderr 或 bundle status；enrollment 重放、node 错绑、session 终态和凭据吊销均 fail closed。没有可信
enrollment/agent channel 时 reconciliation 保持 pending，不得把普通 DHCP 可达性当作认证成功。

Enrollment 是独立 runtime resource：操作员显式 arm 或 pinned provision plan 创建 node/plan-bound、单次使用、短期
有效的随机 secret，服务端只持久化 verifier、node、plan digest、expiry 和 consumed/revoked 状态。节点只能在当前
install/diskless delivery capability 仍有效时从独立 no-store endpoint 领取该 secret，写入 mode 0600 的临时文件；
它不进入 BootConfig/answer body、kernel cmdline 或 rootfs variant。agent 以 enrollment secret 原子兑换 node
credential 后立即删除临时文件，重复兑换返回稳定冲突。installer/session capability 只保护“领取”动作，不直接
认证后续 agent 请求。

已安装节点将 node credential 以 mode 0600 持久化，服务端只保存 verifier；无持久 overlay 的 diskless 节点不得把
credential 写入共享 lower 或 boot.json，每次启动通过新的 active session 领取 enrollment，并只获得本次运行期
credential。credential 吊销、desired plan 改变或 node 重新认领使后续 capability 签发失败。v0.2 的 HTTP bearer
只在隔离 `local-only` 网络内提供认证，不提供链路机密性；跨不可信网络的 TLS/mTLS 与远程管理仍是非目标，部署
必须以隔离 VLAN/ACL 防止旁路窃听。

## 6. 对当前 v0.2 脚手架的代码影响

| 当前代码 | 结论 | v0.2 变更 |
|---|---|---|
| `model.ProfileConfig`、`BootKind` | v3 Profile 和 BootKind 都只有 install；`ProfileMode` 已不存在，legacy diskless 只保留为迁移 blocker | schema v4 基于冻结 v3 新增 tagged kind；不恢复旧 mode/nullable source |
| `AssetKind.nodeforge_initrd/rootfs`、`BootBundleConfig` | 仅有通用 asset kind 和基础 tuple；没有 Profile consumer、build manifest、revision/readiness | 增 digest/feature manifest、validator、Assets CLI/API 和 transaction |
| `boot/target.zig:resolve` | 当前无 `resolveDiskless`，`resolve` 只调用 `resolveInstall`；文件中的 diskless 注释是过时说明 | 新增只消费 pinned DisklessEffectivePlan 的明确分支并补负向验证 |
| `http/server.zig:bootConfig`、`http/routes.zig` | BootKind 仅 install，handler 无 diskless payload 分支，route table 无 node-bound rootfs artifact 路由 | 增强类型 DTO、node-bound rootfs route、Range/ETag/auth |
| `provision/runner.zig` M4 install_post | repository/`standard_packages` owner 冲突，且没有 M7 phase/status/retry | v0.1 先迁为 managed-file bundle；M7 在同一 ItemSpec/resource 上扩展 tagged action、phase 和运行态 |
| `main.zig` 通用 asset import | 可接受预留 kind，但无 rootfs/initrd/boot-bundle/diskless resource-action tree | 复用 command modules、spec help 和 OutputDocument，不回到直接 writer |
| `state` 中预留的 diskless phase/event enum | 只有枚举和投影路径，没有 initrd producer、rootfs consumer 或完整 E2E | 按 §4.3 canonical 状态机接入并增 QEMU、损坏/中断、auth、digest drift E2E |

## 7. 明确非目标

- DHCPv6、IPv6 target network 或 IPv6 PXE；这是项目永久非目标。
- by-id、serial、WWN 或其他稳定磁盘 selector；这是项目永久非目标，磁盘配置继续使用 v0.1 的 `/dev/...` 路径契约。
- 数据库、远程多租户管理平面或通用配置管理平台。
- Kubernetes/Slurm/Ansible 类集群编排。
- 未经强类型约束和审计的任意远程命令执行。
- v0.2 不提供持久化 overlay、跨重启 rootfs partial 或稳定无盘 SSH host identity；这些需要独立 secret/backend、
  生命周期和恢复设计，不能把共享 host private key 或节点本地残留当作实现。
- M5 不支持 PXE 阶段纯静态、多 NIC、VLAN、bonding 或下载后切换地址/子网；M6 只能通过显式 capability 扩展，
  不得由 initrd 猜测或静默接受。

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

v0.2 只有在 M5-M7 均具备代码、自动化、可复现系统验证和迁移证据后完成；某一里程碑不能借用另一个
里程碑的设计或脚手架作为完成证据。

### 9.1 M5

- schema v4 plan/apply/rollback 将每个 v3 Profile 无损映射为 `kind.install`，旧 parser 不接受 nullable v4 半成品。
- diskless Profile、rootfs、nodeforge-initrd 和 boot-bundle 的 PropertySpec/CollectionSpec/ItemSpec、Assets CLI/API、
  exact-key show/help 和 transaction 全部通过 contract test。
- rootfs variant 由完整 effective digest 可复现构建/缓存；Profile 或 Node software delta 与实际文件系统内容一致。
- node-bound boot-config 和 rootfs GET/HEAD/Range 通过跨 Node 越权、token 过期、If-Range、断点续传、错误 digest、
  feature mismatch、重复失败 quarantine 和 daemon restart-resume 负向测试。
- BootConfig fixture 证明只含 `$6$` hash/public key，boot.json、access log、Event、错误和 CLI 输出均不含明文、hash、
  private key 或 token；initrd 切根前清零 capability。
- `local-only` rootfs 静态检查和隔离网抓包证明无公网 mirror/metalink/GeoIP/vendor NTP/update，全部 initrd URL 使用
  server IP；静态目标地址不等于 MAC reservation、MAC 不匹配和 renderer 缺失均在切根前失败。
- BootSession 覆盖 DHCP/TFTP/boot-config/initrd 全链路、失败/过期分支、重复/跳跃/回退/错绑拒绝及 quarantine gate，
  `node_status` 不丢失早期诊断状态。
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
- schema/CLI/API/event 对四个 canonical phase 的旧名迁移唯一且八步顺序稳定；保护域 action 在 plan 阶段被拒绝，
  每个 phase 的 finalizer 失败均阻止 succeeded 发布。
- first-boot/runtime 的 enrollment、node credential、短期 capability、吊销和重放/错绑负向测试通过；DHCP、PXE 或
  installer token 不能认证 agent，缺少可信 channel 时 reconciliation 保持 pending。测试同时证明服务端只保存
  verifier、installed credential 权限为 0600、diskless credential 不跨启动持久化，enrollment 不进入
  BootConfig/answer/log/Event，重复兑换和 plan drift 均 fail closed。
- reconciliation 默认关闭；开启后只处理声明允许、幂等且有预算的 action，并通过 drift、重复执行、部分失败、
  retry 和节点离线测试。
- Kickstart、Autoinstall、rootfs build 和 diskless variant 对同一 bundle revision 的 plan/status/audit 语义一致。
