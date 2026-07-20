# NodeForge v0.1 设计与修复计划

状态：修复中。M0-M4.12 已有代码和验证记录，但 M4.12 的 Node/Profile fallback
所有权结论已被否决。v0.1 只有在本文的所有权、可配置性和迁移验收全部完成后才算完成。

本文是 v0.1 的权威设计入口，范围包括 M0-M4 及其所有子里程碑，以及在进入 v0.2
前必须完成的模型修复。历史实现细节和实机记录继续保留在 `DETAILED_DESIGN.md` 和各专项文档中；
发生冲突时，以本文定义的目标模型为准。

## 1. 版本边界

v0.1 交付一个可独立使用的 IPv4 PXE 无人值守安装产品：

- 单进程内置 DHCPv4、TFTP、HTTP 和本机管理 API。
- UEFI x86_64/aarch64 PXE 引导。
- Rocky/RHEL 系 Kickstart 和 Ubuntu 22.04+ Autoinstall。
- 安装源、仓库、kernel、initrd、bootloader 等 catalog 资源管理。
- Node/Profile 配置、渲染、部署 generation、事件和运行状态。
- 完整的安装属性查询、配置、节点覆盖和有效计划预览。
- Kickstart/Anaconda 与 Autoinstall/Curtin 原生的单盘、LVM、软件 RAID 和 RAID 上 LVM 安装。
- RHEL 软件环境/组/包和 Ubuntu task/metapackage/包的索引、查询与选择。
- 未知 DHCP 客户端的持久化发现记录、查询和原子 Node 认领流程。

v0.1 不包含 diskless rootfs 启动、BIOS PXELINUX 和高级 post-provision runner；这些属于
`V0_2_DESIGN.md`。IPv6 和 by-id/serial/WWN 等稳定磁盘选择器是永久非目标，模型、CLI、DHCP
和 adapter 不预留半实现字段。

## 2. 里程碑状态

| 范围 | 状态 | v0.1 结论 |
|---|---|---|
| M0-M4.11 | 已有代码、自动化和相应验证记录 | 保留，按回归测试防止退化 |
| M4.12 | 已实现 storage fallback/override | 仅作为历史实现；所有权方案被本文取代 |
| M4.13.1 | 模型与所有权修复 | 待实现 |
| M4.13.2 | typed property/collection/item registry、CLI/API/输出统一 | 待实现 |
| M4.13.3 | 软件能力索引、查询、Profile selection 和 Node delta | 待实现 |
| M4.13.4 | schema v3 迁移、双 adapter 回归和实机验收 | 待实现 |

M4.13 是 v0.1 的修复里程碑，不增加新的产品版本范围。M4.13.1-M4.13.4 可以按依赖顺序提交，
但不能以其中任一项单独完成为理由启动 v0.2。

## 3. 所有权模型

### 3.1 Resource

Resource 描述可复用且可校验的部署能力，不描述某台机器的期望状态。包括：

- repository 和与 revision/digest 绑定的软件索引；
- install source、ISO、kernel、installer initrd、bootloader；
- managed-file content asset，以及 v0.1 最小 install-post provision bundle；其 step 只允许 `managed-file`，
  Profile 通过 `install.post_install.bundle` 引用；
- 后续版本使用的 rootfs、NodeForge initrd 和 boot bundle。

Resource 负责回答“有什么可用”，Profile 只引用资源和选择能力，不复制 resource 已经拥有的
`distro/version/arch`。资源内容变化必须形成新 revision 或 digest，不能在相同身份下静默漂移。

### 3.2 Profile

Profile 是可复用、可版本化的部署期望模板。它描述多台节点共享的安装和目标系统策略。
修改 Profile 会改变所有引用它的 Node 的 desired effective plan，除非相应字段有显式 Node override。

Profile 可以持有：

- install source 引用；v0.1 的 Profile 只表示 install 模板，v0.2 才扩展 diskless Profile；
- 与物理设备无关的 wipe、partition、filesystem、bootloader 策略；
- locale、timezone、keyboard 和 NTP；
- SSH、用户和安全策略；
- 软件 repository/environment/group/task/package 基线；metapackage 作为 Ubuntu 可查询能力，按 package 名选择；
- kernel argument 基线；
- apt/install completion/reinstall/post-install 等共享策略。

Profile 不得持有：

- `boot_disk` 或任何物理设备选择器；
- Node 的 MAC、hostname、IP、NIC 和硬件 inventory；
- 已由 install source/boot bundle 拥有的 distro/version/arch；
- 可由 Profile kind 和 effective actions 推导的 destructive/persistent safety booleans；
- effective、readiness、session、status 等派生或运行态字段。

`discovery` 不是 Profile mode。v0.1 的 Profile 必须携带 install source；v0.2 增加 diskless 后使用
`ProfileKind = install | diskless` tagged union，并由各分支分别携带 install source 或 boot bundle，
避免依靠多个 nullable 字段表达非法状态。

### 3.3 Node

Node 描述一台机器的身份、直接配置和物理绑定。以下字段是 Node 直接属性，不属于 override：

- `id`、`mac`、`arch`，以及认领后可空转非空的 `profile`；
- `pxe.ip_reservation`、`hostname` 和 `network.*` IPv4 target network；
- `deploy`、实验验证属性 `http_accel`；
- `storage.boot_disk` 和 `storage.additional_disks`。

探测到的 firmware、NIC、disk inventory 属于 Observed/Runtime，只读展示，不自动成为 Node desired 默认值。
未来确需管理员确认的硬件配置时，必须按字段准入规则新增独立 confirmed property。

`profile = null` 只允许出现在已持久化但尚未认领/绑定的 Node，且此时 `deploy` 必须为 `false`。
绑定 install Profile 后才允许 arm/install。`http_accel` 保留是因为现有 TFTP/GRUB 链已经消费该能力；它是
Node direct、默认 `false` 的实验验证属性，只适用于 UEFI GRUB。show/help/set/API/digest 必须完整支持该 key，
启用时 readiness/show 明确标记 experimental 和已知 EFI 连续内存风险；对不适用的启动链返回
`property.not_applicable`，不能静默接受。

Node 的默认启动盘路径是 `/dev/sda`。该默认值来自 Node schema，而不是 Profile：

```text
node.storage.boot_disk = "/dev/sda"
node.storage.additional_disks = []
```

两个字段都只接受 Linux `/dev/...` 设备路径，不支持 by-id、serial、WWN 或其他 selector。
`storage.boot_disk` 是唯一主启动盘和单主 ESP 所在盘；`storage.additional_disks` 是参与所选 RAID/LVM
拓扑的其他成员盘。v0.1 不保留旧 `install_disks`：它既与 `boot_disk` 重复，又没有说明哪个成员是主启动盘，
当前代码中的多值也未被 adapter 消费。目标模型使用 `boot_disk + additional_disks` 得到有明确顺序和职责的
有效成员集合，规范化写回必须保留这两个实际 Node key，不能生成 Profile 磁盘 fallback。

### 3.4 Node override

Node override 只表达共享 Profile 策略在单个节点上的例外。所有 Profile 策略均可 override，
不采用“初期只开放少数字段”的分阶段方案。

Profile 的 `name` 和 install source 不是策略字段，不允许 Node override；v0.2 的 kind 同样不允许 override。
节点需要不同 kind 或 source 时应绑定另一个 Profile。该限制避免一个 Node override 实际构造出未命名的新 Profile。

必须支持的 override 范围：

- `install.storage.mode/wipe/partition_table/partitions`；
- `install.bootloader.*`；
- `system.localization.locale/timezone/keyboard`；
- `system.connectivity.time_sync/ntp_servers`；
- `system.ssh.*`、`system.users`、`system.security.*`；
- `software.repositories/environment/groups/tasks/packages`；
- `kernel_args`；
- `install.apt/completion/update/proxy/reinstall/post_install`；
- 其他已经进入 Profile 的可配置安装策略。

覆盖操作按数据类型固定语义：

| 类型 | override 语义 |
|---|---|
| scalar/enum/nullable scalar | `null` 继承；非 null 完整替换 |
| 结构对象 | 逐字段 nullable patch，未出现字段继承 |
| 有顺序和整体约束的列表，如 partitions/users | `null` 继承；数组完整替换；`[]` 明确表示空 |
| 集合，如 repositories/groups/tasks/packages/NTP/key | `add` 和 `remove` delta；同一值不能同时出现 |
| kernel arguments | 按参数名 add/replace/remove，不使用不可解析的整段字符串拼接 |

Node 直接属性不能放入 `overrides`。特别是磁盘路径、hostname、DHCP 保留地址和 target NIC 不通过
Profile 合并得到。

### 3.5 Effective 与 Runtime

Effective plan 是只读编译结果：

```text
effective = compile(resource capabilities, profile policy, node direct facts, node overrides)
```

所有 validator、plan digest、PXE resolver、Kickstart/Autoinstall adapter、retry/drift 和 show API
必须消费同一个 effective plan，禁止各自实现 fallback。

Runtime 只保存 lease、boot session、generation、部署状态、inventory 和事件等观测事实。
Runtime 不反向成为声明配置默认值。

### 3.6 Discovery workflow

Discovery 是未知 DHCP 客户端的站点级观察和认领流程，不属于 Profile，也不是 Node 的生命周期 mode。
当前代码虽然存在 `ProfileMode.discovery` 和 unknown policy，但只完成了部分链路：

- DHCP 能按未知 MAC 发放 lease 并记录 `known=false`。
- CLI 能用 `runtime dhcp-unknown` 查询当前未认领活动 lease。
- resolver 的 discovery action 会下发 GRUB bootfile，但 boot target 对 discovery 返回 null，没有可执行的
  discovery kernel/initrd、inventory payload 或完整状态闭环。
- 没有持久化 UnknownClientObservation 资源，也没有原子 claim 命令；目前只能手工 `node add/set`。

因此 v0.1 不把现有 discovery mode 标记为已支持。目标流程是：

```text
unknown DHCP request
  -> site policy: record | deny
  -> UnknownClientObservation
  -> CLI list/show
  -> atomic claim into unassigned Node (profile=null, deploy=false)
  -> configure Node direct fields + bind install Profile
  -> explicit deploy=true / install arm
```

站点策略是 daemon-owned catalog singleton，不属于 startup config、Profile 或 Runtime，canonical path 为
`discovery.policy.unknown_action`（`record|deny`，默认 `record`）和
`discovery.policy.observation_retention_days`（正整数，默认 30）。`record` 分配诊断 lease、记录观察事实，
但不下发 PXE bootfile；`deny` 不分配 lease且仍可按限频规则记录拒绝审计事件。观察记录至少包含 MAC、
DHCP client id、observed architecture、vendor class、first_seen、last_seen、last_ip、request_count、revision 和
claim 状态，并与活动 lease 分开持久化、分页和过期清理。已 claimed 的 audit 不受普通 retention 清理影响。

建议 CLI：

```text
nodeforge discovery list
nodeforge discovery show <mac>
nodeforge discovery policy show
nodeforge discovery policy set unknown_action=record observation_retention_days=30
nodeforge node claim <node-id> discovery.mac=<mac> --observation-revision <revision> arch=<arch>
nodeforge node set <node-id> mac=<new-mac> profile=<profile>
```

`node claim` 必须使用 observation revision 防止并发认领，创建或更新 Node 后保留 claimed audit，默认
`profile=null, deploy=false`，不因认领动作直接触发安装。随后可用普通 `node show/set` 查询和调整 MAC、
hostname、arch、Profile 及其他 Node direct 字段；只有绑定 Profile 并显式启用 deploy 后才能安装。
observed architecture 只能作为 CLI 建议值，最终写入 Node 的 `arch` 是管理员确认的 desired 配置。

### 3.7 字段准入规则

“代码中出现过”不等于“可作为持久化属性”。每个新增或保留字段必须同时具备：唯一 owner、canonical path、
明确的默认/nullable 语义、PropertySpec/CollectionSpec/ItemSpec、CLI/API 查询与 mutation、validator、所有适用
adapter 的消费或 fail-closed capability、effective/digest 覆盖、schema migration 和契约/渲染测试。缺少任一项，
只能作为 derived/runtime 输出或实现内部状态，不能进入公开 schema。单值枚举、固定常量、可由其他字段派生的
布尔值和“未来预留”字段一律不持久化。

## 4. 字段归属矩阵

| 领域 | Resource | Profile | Node direct | Node override | Derived/Runtime |
|---|---:|---:|---:|---:|---:|
| distro/version/arch capability | 是 | 引用后派生 | Node arch 是 | 否 | effective platform |
| install source/repository metadata | 是 | 引用/选择 | 否 | repository delta | available software |
| boot/additional physical disks | 否 | 禁止 | 是 | 禁止 | resolved member devices |
| storage mode/wipe/partition/layout/filesystem | 否 | 是 | 否 | 是 | rendered storage plan |
| bootloader policy | bootloader asset | 是 | firmware fact | 是 | bootloader actions |
| hostname/IPv4/NIC | 否 | 否 | 是 | 禁止 | rendered network plan |
| locale/timezone/keyboard/NTP | 否 | 是 | 否 | 是 | effective system |
| SSH/users/security | 否 | 是 | 否 | 是 | effective system |
| software baseline | indexed capability | 是 | 否 | add/remove | effective software |
| kernel arguments | kernel capability | 是 | 否 | add/remove/replace | effective cmdline |
| readiness/digest/session/status | 否 | 否 | 否 | 否 | 是，只读 |

Discovery observation 不进入本表的 Profile/override 合并；它属于 Runtime/Observed，认领时才转换为
Node desired fields。

### 4.1 v0.1 完整可配置面

v0.1 的“关键属性可查询和配置”不是只增加几个示例 key。M4.13 必须以以下 canonical namespace
完成 schema、PropertySpec/CollectionSpec、CLI、API、effective compiler 和双 adapter 消费者。表中的
“集合”均遵守第 7.2 节，禁止在 Shell 中内嵌 JSON。

| Owner | Canonical path | 类型/说明 | Node override |
|---|---|---|---|
| Site | `discovery.policy.unknown_action` | daemon-owned singleton enum，`record|deny`，默认 `record` | 不适用 |
| Site | `discovery.policy.observation_retention_days` | 正整数，默认 30；只清理未认领 observation | 不适用 |
| Node | `mac`、`arch`、`profile`、`pxe.ip_reservation`、`hostname`、`deploy`、`http_accel` | identity/direct scalar；profile 仅在 deploy=false 时可 unset；http_accel 是默认 false 的 UEFI 实验能力 | 不适用 |
| Node | `network.mode/interface_name/address/prefix_len/gateway` | IPv4 direct scalar/object；MAC 匹配唯一使用 `node.mac` | 禁止放入 override |
| Node | `network.dns`、`network.search_domains` | direct scalar collection | 禁止放入 override |
| Node | `network.routes` | 以 route id 为 identity 的 IPv4 structured collection | 禁止放入 override |
| Node | `storage.boot_disk` | direct device path，默认 `/dev/sda`；主启动盘和单主 ESP 所在盘 | 禁止放入 override |
| Node | `storage.additional_disks` | direct scalar collection，默认 `[]`；RAID/LVM 其他成员盘 | 禁止放入 override |
| Profile | `install_source` | install-source resource ref；Profile 创建/修改时联合校验 | 否，换 Profile |
| Profile | `install.storage.mode` | `single|lvm|raid0|raid1|raid5|raid6|raid10|raid0-lvm|raid1-lvm|raid5-lvm|raid6-lvm|raid10-lvm`，默认 `single` | 是 |
| Profile | `install.storage.wipe/partition_table` | 安装存储策略；分区表默认 `gpt` | 是 |
| Profile | `install.storage.partitions` | 以 partition id 为 identity 的 ordered structured collection | 是，整组替换 |
| Profile | `install.bootloader.install` | bootloader 策略；目标固定解析为 Node boot disk，不持久化 target 常量 | 是 |
| Profile | `system.localization.locale/timezone/keyboard` | 目标系统标量 | 是 |
| Profile | `system.connectivity.time_sync`、`system.connectivity.ntp_servers` | 标量 + scalar collection | 是；NTP 用 delta |
| Profile | `system.ssh.enabled/password_authentication/root_login/root_password` | SSH 标量策略；密码按明文配置 | 是 |
| Profile | `system.ssh.root_authorized_keys` | SSH key scalar collection | 是，用 delta |
| Profile | `system.users` | 以 user name 为 identity 的 structured collection | 是，整组替换 |
| Profile | `system.security.firewall/selinux/apparmor` | adapter-aware security policy | 是 |
| Profile | `software.repositories/environment/groups/tasks` | capability selection | 是；environment 完整替换，其余用 delta |
| Profile | `software.packages.include/exclude` | package-name scalar collection | 是，用 delta |
| Profile | `kernel_args` | 以参数名唯一的 `NAME[=VALUE]` collection | 是，按参数名 delta |
| Profile | `install.apt.fallback` | Ubuntu adapter policy | 是 |
| Profile | `install.completion.action` | `reboot|poweroff|halt` | 是 |
| Profile | `install.updates.mode` | `none|security|all`，按 adapter 翻译 | 是 |
| Profile | `install.proxy.url/no_proxy` | 安装期 proxy 标量 + collection | 是 |
| Profile | `install.reinstall_policy` | `explicit|always` | 是 |
| Profile | `install.post_install.bundle` | provisioning bundle reference | 是 |

v0.1 的 provision bundle 是 Assets/resource，不是 Profile 内嵌 steps。其 canonical CLI 为：

```text
nodeforge assets provision-bundle list|show|create|remove
nodeforge assets provision-bundle item list|show|add|set|remove|move <bundle> steps ...
nodeforge assets provision-bundle replace-items <bundle> steps --from-file <yaml|json> --input <yaml|json>
nodeforge assets managed-file list|show|import|remove
nodeforge assets managed-file import <name> --from-file <path>
```

本版 ItemSpec 只允许 `name`、`action=managed-file`、`destination`、`content_asset`、`mode`、`owner` 和 `group`；
内容必须引用 immutable managed-file asset revision，不能把文件正文或脚本塞进 argv。该 asset 保存原始 bytes、
content digest、size 和 media type，不带 executable/script 语义；M7 script action 只能引用独立的受审计 script asset，
不能借 managed-file 绕过。旧 `repository` step 迁入 Assets repository +
Profile `software.repositories`，旧 `standard_packages` step 迁入 `software.packages.include`；无法无歧义迁移时
schema v3 plan 阻塞。M7 在同一 resource/ItemSpec 上增加 action 和 phase，不创建第二种 bundle owner。

#### 4.1.1 Node override canonical namespace

Profile policy 的 Node override 一律在同路径前加 `overrides.`，只有 delta collection 再增加操作后缀。完整规则如下：

| Profile path/shape | Node override path | 语义 |
|---|---|---|
| `install.storage.mode/wipe/partition_table` | `overrides.install.storage.*` | nullable scalar，unset 恢复继承 |
| `install.storage.partitions` | `overrides.install.storage.partitions` | nullable ordered replacement；首次 item mutation 原子物化当前 effective 列表 |
| `install.bootloader.*` | `overrides.install.bootloader.*` | 逐字段 nullable patch |
| `system.localization.*` | `overrides.system.localization.*` | nullable scalar |
| `system.connectivity.time_sync` | `overrides.system.connectivity.time_sync` | nullable scalar |
| `system.connectivity.ntp_servers` | `overrides.system.connectivity.ntp_servers.add/remove` | set delta |
| `system.ssh.*` scalar | `overrides.system.ssh.*` | nullable scalar |
| `system.ssh.root_authorized_keys` | `overrides.system.ssh.root_authorized_keys.add/remove` | set delta |
| `system.users` | `overrides.system.users` | nullable ordered replacement；首次 item mutation 原子物化 |
| `system.security.*` | `overrides.system.security.*` | nullable scalar |
| `software.repositories/groups/tasks` | `overrides.software.<collection>.add/remove` | capability-id set delta |
| `software.environment` | `overrides.software.environment` | nullable scalar replacement |
| `software.packages.include/exclude` | `overrides.software.packages.<include|exclude>.add/remove` | 两个独立 set delta |
| `kernel_args` | `overrides.kernel_args.add/remove` | add 中 `NAME[=VALUE]` 按 NAME 新增或替换；remove 中只接受 NAME |
| `install.apt/completion/updates/proxy/reinstall_policy/post_install` | 对应 `overrides.install.*` | scalar/object/list 按本表既定类型规则 |

不得增加 `node.<path>`、`profile.<path>`、`override_*` 等传输别名。Node direct `network.*`、`storage.*`、
identity 和 Profile `install_source` 不出现在此表，也不能通过 `overrides.*` 修改。

#### 4.1.2 原生多盘和分区模型

存储 CLI 不暴露 md/PV/VG/LV action graph。用户只选择拓扑模式、Node 物理成员盘和逻辑分区；effective
compiler 生成内部 md/PV/VG/LV 名称，并且只能生成 Kickstart/Anaconda 与 Autoinstall/Curtin 的原生动作，
不得通过 `%pre/%post`、`late-commands` 或任意脚本补做存储配置。

| mode | 有效成员数 | 原生拓扑 |
|---|---:|---|
| `single` | 恰好 1 | ESP、`/boot` 和普通分区直接位于 `storage.boot_disk` |
| `lvm` | 恰好 1 | ESP、`/boot` 为物理分区，其余空间作为 PV/VG/LV |
| `raid0`、`raid1` | 至少 2 | 单主 ESP、`/boot` RAID1，其余逻辑卷分别建立所选级别 md array |
| `raid5` | 至少 3 | 单主 ESP、`/boot` RAID1，其余逻辑卷分别建立 RAID5 md array |
| `raid6` | 至少 4 | 单主 ESP、`/boot` RAID1，其余逻辑卷分别建立 RAID6 md array |
| `raid10` | 至少 4 且为偶数 | 单主 ESP、`/boot` RAID1，其余逻辑卷分别建立 RAID10 md array |
| `raidN-lvm` | 对应 RAIDN 的成员约束 | 单主 ESP、`/boot` RAID1、一个 RAIDN md array 作为 PV/VG，普通分区作为 LV |

有效成员固定为 `storage.boot_disk + storage.additional_disks`。`single/lvm` 遇到非空附加盘必须失败，
RAID 模式成员不足、重复、包含分区路径或 RAID10 成员数为奇数也必须失败，不能忽略多余磁盘或降低 RAID 级别。

`install.storage.partitions` 未持久化时使用自动布局；持久化后表示自定义布局。自动布局固定为：

| id | mount | filesystem | size |
|---|---|---|---:|
| `esp` | `/boot/efi` | `vfat` | 1024 MiB |
| `boot` | `/boot` | `ext4` | 2048 MiB |
| `root` | `/` | `ext4` | 剩余全部空间 |

这里的根挂载点是 `/`，不是 root 用户目录 `/root`。普通文件系统默认 `ext4`；ESP 因 UEFI 规范固定为
FAT32/`vfat`，swap 固定为 `swap`。默认不创建 swap，只有显式 CLI/file 配置时才创建。

partition item schema 固定包含 `id`、可空 `mount`、`filesystem`、可空 `size_mib` 和 `grow`：普通文件系统
省略 `filesystem` 时为 `ext4`；`size_mib` 表示请求的可用逻辑容量；`size_mib` 与 `grow=true` 互斥；整个布局
最多一个 grow item。自定义布局仍必须包含唯一 `/boot/efi`、`/boot` 和 `/`；`/boot/efi` 固定 `vfat`，
`/boot` 固定 `ext4`。swap 使用 `filesystem=swap` 且不设置 mount，其他 mount 必须是唯一绝对路径。

RAID 模式只有 `storage.boot_disk` 创建 ESP；`/boot` 始终使用所有成员组成的 RAID1。根和数据分区使用
`install.storage.mode` 指定的 RAID 级别。该单主 ESP 方案不承诺主启动盘完全损坏后固件能自动从其他盘启动，
因为复制 ESP 和 NVRAM boot entry 需要额外脚本或平台专用动作，明确不在原生公共子集内。

adapter 映射固定为：Kickstart 使用 `part -> raid -> volgroup -> logvol`；Autoinstall 使用 Curtin
`disk -> partition -> raid -> lvm_volgroup -> lvm_partition -> format -> mount`。两边必须对全部 12 个 mode
建立渲染 golden、失败关闭和至少可复现虚拟硬件安装测试。

实现和验收以安装器原生文档为依据：

- [RHEL 9 Kickstart commands and options reference](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/automatically_installing_rhel/kickstart-commands-and-options-reference_rhel-installer)
  的 `part/raid/volgroup/logvol`；Kickstart 虽还接受 RAID4，但 Curtin 公共子集没有 RAID4，因此产品不暴露它。
- [Curtin storage configuration](https://curtin.readthedocs.io/en/latest/topics/storage.html) 的
  `disk/partition/raid/lvm_volgroup/lvm_partition/format/mount` action。
- [Curtin lvmoverraid fixture](https://github.com/canonical/curtin/blob/main/examples/tests/lvmoverraid.yaml) 和
  [Subiquity Autoinstall storage reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)。

测试必须检查生成结果只含上述原生 storage action；出现 `%pre/%post`、`late-commands` 或自定义 storage script
即视为未满足本契约。

完整配置和查询入口必须同时覆盖 Profile 基线、Node policy override 与 Node physical disks：

```text
# Profile 自动布局基线
nodeforge profile set rocky-9 install.storage.mode=raid5-lvm install.storage.wipe=true install.storage.partition_table=gpt
nodeforge profile set rocky-9 install.bootloader.install=true
nodeforge profile unset rocky-9 install.storage.partitions

# 单节点物理盘与不同拓扑
nodeforge node set node-01 storage.boot_disk=/dev/sda overrides.install.storage.mode=raid1-lvm
nodeforge node add-values node-01 storage.additional_disks /dev/sdb
nodeforge node list-values node-01 storage.additional_disks

# 同时查询 persisted baseline/direct/override 和编译结果
nodeforge profile show rocky-9
nodeforge node show node-01
nodeforge profile item list rocky-9 install.storage.partitions
nodeforge node item list node-01 effective.install.storage.partitions
```

`profile show` 中未持久化的 `install.storage.partitions` 显示 `<automatic>` 并标记 source=default；该原 key
仍可直接用于 `item`/`unset`。`effective.install.storage.partitions` 是根据 Profile、Node override、成员盘和 mode
聚合后的只读 item collection，允许使用新 key 是因为它不是可人工持久化的单一事实。

`system.users` 的 item schema 至少包含 `name`、`uid`、`groups`、`shell`、`locked`、`password` 和
`ssh_authorized_keys`。密码是允许通过 CLI 直接设置和持久化的明文配置，Profile 与 Node override 使用同一
canonical key；adapter 在渲染时按目标格式生成 hash。没有显式配置 `system.users` 时，effective 默认普通用户为
`nodeforge`，密码为 `asdf1234`；没有显式配置 `system.ssh.root_password` 时，effective 默认 root 密码为
`asdf1234`。显式空 `system.users=[]` 表示不创建普通用户。`show`/JSON 按原 key 返回持久值或标注
`source=default` 的有效默认值，不另造 `password_configured` mutation key；事件和普通日志不得主动记录密码。

上表是最低完整面，不是 adapter 可以静默忽略的愿望清单。某发行版确实不适用的字段返回
`property.not_applicable`，尚未实现的字段返回 `property.unsupported` 并使 Profile/Node not ready；不能接受
mutation 后在 renderer 中丢弃。Repository 的 GPG、priority、enabled metadata 由 Assets resource 持有，
Profile 的 `software.repositories` 只做引用和选择，避免复制仓库定义。

### 4.2 不进入 v0.1 schema 的当前字段

| 当前字段 | 处理 | 原因 |
|---|---|---|
| `profile.mode` | 删除 | v0.1 只有 install；v0.2 才用 tagged kind 增加 diskless |
| `profile.distro/version/arch` | 删除 | 由 `install_source` capability 唯一派生 |
| `profile.boot_bundle` | 删除 | v0.2-only |
| `profile.safety.safe_for_unknown` | 删除 | discovery 不属于 Profile |
| `profile.safety.destructive/persistent_writes` | 删除 | 由 effective actions 派生 |
| `profile.system.connectivity.mode` | 删除 | 当前只有 `local-only` 一个值，没有选择意义 |
| `profile.system.packages` | 删除 | 迁入唯一 `software.*` owner |
| `profile.install.packages/users/ssh_authorized_keys` | 删除 | 分别与 `software.*`、`system.users`、`system.ssh.*` 重复 |
| `profile.install.storage.boot_disk/install_disks` | 删除 | 物理磁盘只属于 Node；目标改为 `node.storage.boot_disk/additional_disks` |
| `profile.install.storage.boot_mode` | 删除 | v0.1 UEFI-only；M6 firmware 是 Node direct/observed capability |
| `profile.install.bootloader.target` | 删除 | 只允许固定值，不是属性；由 Node boot disk 派生 |
| `profile.install.bootloader.set_firmware_boot_order` | 删除 | 当前 `true` 永远被拒绝且无 adapter 消费 |
| `node.network.match_mac` | 删除 | 与 `node.mac` 重复且校验要求相等 |
| `node.overrides.network` | 迁移 | 目标网络改为 Node direct `network.*` |
| `node.overrides.storage` / `NodeStorageOverrideConfig` | 删除 | 物理磁盘改为 Node direct；策略 override 迁入 `node.overrides.install.storage.*` |
| `software.metapackages` selection | 不新增 | metapackage 只保留 capability kind，通过 packages include 选择 |

`profile.safety.reinstall_policy` 的语义保留并迁到 `profile.install.reinstall_policy`；`install.bundle` 迁到
`install.post_install.bundle`。`node.ip` 不是目标系统静态地址，迁到 `pxe.ip_reservation`。这些是 rename/relocate，
迁移后旧 key 必须被 schema v3 拒绝，不能长期保留 alias。

## 5. 磁盘路径与成员契约

- `node.storage.boot_disk` 是直接 Node 字段，默认 `/dev/sda`。
- `node.storage.additional_disks` 是直接 scalar collection，默认空；不定义 `node.storage.install_disks`。
- validator 只接受规范、互不重复的绝对 `/dev/...` 整盘路径，拒绝空值、分区路径和主盘重复出现在附加盘。
- Profile 不得保存任何 `/dev/...`；Node 通过 direct fields 选择物理盘，通过 `overrides.install.storage.*`
  复写 Profile 的 mode、wipe、partition table、logical partitions 和 bootloader policy。
- Kickstart 将所有成员转换为 Anaconda 指令需要的设备名；Autoinstall 将所有成员写入 curtin action config。
- adapter 不能在配置路径不存在或不适用时猜测其他磁盘，也不能实现运行时 fallback。
- by-id、serial、WWN 和其他稳定 selector 明确不支持，不进入 schema、CLI、help 或兼容预留。

## 6. 软件能力、包组与选择

### 6.1 能力索引所有权

Repository/install source 负责可用软件能力，Profile 负责选择基线，Node override 负责单节点 delta。
不能再并存 `profile.system.packages`、`profile.install.packages` 和 bundle `standard_packages` 三个等价入口。

索引按 repository revision/digest 和 arch 生成：

- RHEL：解析 `repomd.xml`、primary metadata 和 comps environment/group。
- Ubuntu：解析 `Packages*`、Task metadata，并标记 metapackage。

RHEL group/environment 与 Ubuntu task/metapackage 是不同 capability kind，不做虚假统一：

```text
SoftwareKind = environment | group | task | metapackage | package
```

### 6.2 Profile selection 与 Node delta

```text
profile.software.repositories
profile.software.environment
profile.software.groups
profile.software.tasks
profile.software.packages.include
profile.software.packages.exclude

node.overrides.software.repositories.add/remove
node.overrides.software.groups.add/remove
node.overrides.software.tasks.add/remove
node.overrides.software.packages.include.add/remove
node.overrides.software.packages.exclude.add/remove
```

Ubuntu metapackage 仍可通过 capability 查询得到，但安装操作与普通 package 相同，使用
`software.packages.include` 选择；不持久化第二个 `software.metapackages` 列表。

编译 effective software 时必须验证：能力存在、架构匹配、repository 可达、add/remove 不冲突、
environment 唯一以及 exclude 的优先级。Kickstart 输出 `%packages` 的 environment/group/package/exclusion；
Autoinstall 将 task/metapackage/package 编译成目标版本可执行的 apt/curtin 操作。

### 6.3 查询与修改 CLI

软件 CLI 分为“按 Profile 查询/修改”和“按 Assets 来源诊断”两部分。正常工作流必须以 Profile 为入口，
因为 Profile 已经确定 install source、repository 集合和 arch；install source/repository 属于 Assets catalog，
不再增加顶级 `repository` 或 `install-source` 命令。

Profile 主入口：

```text
nodeforge profile software available <profile> --kind environment
nodeforge profile software show <profile>
nodeforge node software show <node>
```

Assets 来源诊断：

```text
nodeforge assets install-source list
nodeforge assets install-source show <source>
nodeforge assets install-source software list <source> --kind package --search <text>

nodeforge assets repository list
nodeforge assets repository show <repo>
nodeforge assets repository software list <repo> --kind group --search <text>
nodeforge assets repository software show <repo> --kind group <id>
```

当前 `assets import <iso>` 已经发布 install source、关联 repository 和默认 Profile，management API 也已有
install-source list/show；v0.1 要补的是上述明确的 Assets CLI 资源树及软件索引视图。repository software
命令只用于检查某个底层仓库的原始能力，日常选包不要求用户知道 repository 名称。

- Kickstart/RHEL 支持查询 `environment|group|package`。
- Autoinstall/Ubuntu 支持查询 `task|metapackage|package`。
- 对当前 adapter 不适用的 kind，例如 Ubuntu 查询 environment，返回
  `software.kind_not_applicable` 并列出 `supported_kinds`，不能返回一个容易误判的空列表。
- `available` 展示 Profile 当前 source/repository/arch 下可选择内容；`software show` 展示已经选择的
  persisted key 和 effective software，不混入整个仓库目录。

Profile scalar 修改：

```text
# environment 是单值：set 修改，unset 恢复 adapter 默认
nodeforge profile set <profile> software.environment=<id>
nodeforge profile unset <profile> software.environment

```

集合属性不使用 shell 内嵌 JSON。统一提供四个原子操作，key 与 `show` 完全一致：

```text
# 增加一个或多个值
nodeforge profile add-values <profile> software.groups core development-tools

# 删除一个或多个值
nodeforge profile remove-values <profile> software.groups development-tools

# 完整替换
nodeforge profile replace-values <profile> software.groups core development-tools

# 清空为显式空集合
nodeforge profile clear-values <profile> software.groups

# 大列表：UTF-8 文本每行一个值，忽略空行和以 # 开头的注释
nodeforge profile replace-values <profile> software.packages.include --from-file packages.txt
```

`profile set` 遇到 list/set 类型 key 必须返回 `property.list_operation_required`，并给出对应
`add-values/remove-values/replace-values/clear-values` 命令，不能要求用户手写 JSON 或逗号转义。

`profile replace-values --help-full` 必须明确显示：

```text
Usage
  nodeforge profile replace-values <profile> <KEY> <VALUE>...
  nodeforge profile replace-values <profile> <KEY> --from-file <path>

List properties
KEY                           ITEM TYPE       OPERATIONS
software.groups               capability-id  add, remove, replace, clear
software.tasks                capability-id  add, remove, replace, clear
software.packages.include     package-name   add, remove, replace, clear
software.packages.exclude     package-name   add, remove, replace, clear

Behavior
  Replacement is atomic. Values are validated before any change is published.
  Duplicates are rejected. Use clear-values for an explicit empty collection.
  Use -- before values beginning with '-'.

Examples
  nodeforge profile replace-values rocky-9 software.groups core development-tools
  nodeforge profile replace-values rocky-9 software.packages.include --from-file packages.txt
```

四个集合命令共享同一 PropertySpec 和 help formatter；不能各自维护不同的 key、类型或示例。

Node override 增删改查：

```text
# 在 Profile 基线上增加包
nodeforge node add-values <node> overrides.software.packages.include.add <name>

# 从 Profile 基线中移除包
nodeforge node add-values <node> overrides.software.packages.include.remove <name>

# 删除本地 delta，恢复继承
nodeforge node remove-values <node> overrides.software.packages.include.add <name>
nodeforge node remove-values <node> overrides.software.packages.include.remove <name>

# 查询 selection + effective 合并结果
nodeforge node software show <node>
```

`overrides.software.packages.exclude.add/remove` 以相同方式对 Profile 的 exclude 集合做 delta。四个集合先分别应用
delta，再执行冲突校验；同一包不能同时出现在 effective include 和 exclude 中。这里的 `remove` 表示从对应的
Profile 集合中移除，不表示把包加入另一个集合，因此不能压缩回含义不明的 `packages.add/remove`。

查询必须分页并返回 capability id、kind、name、arch、source repository 和 revision。Profile 上下文查询
自动解析 install source、repository 和 arch，不要求用户自行拼接关系。所有 mutation 必须校验目标 capability
存在于同一 revision；index 更新造成选择失效时，Profile/Node readiness 明确报告 missing capability。

`profile software show rocky-9` 示例：

```text
Profile software rocky-9

Selected properties
KEY                         VALUE                         MUTABLE
software.environment        minimal-environment           yes
software.groups             [core, development-tools]     yes
software.packages.include   [vim-enhanced]                yes
software.packages.exclude   [firewalld]                   yes

Effective software (read-only)
KEY                            VALUE
effective.software.environment minimal-environment
effective.software.groups      [core, development-tools]
effective.software.packages    [vim-enhanced]

Capability source (read-only)
KEY                                  VALUE
capabilities.software.repositories   [rocky-9-baseos, rocky-9-appstream]
capabilities.software.revision       sha256:...
capabilities.software.supported_kinds [environment, group, package]

Commands
List available: nodeforge profile software available rocky-9 --kind all
Set scalar:     nodeforge profile set rocky-9 KEY=VALUE
Add list item:  nodeforge profile add-values rocky-9 KEY VALUE...
Remove item:    nodeforge profile remove-values rocky-9 KEY VALUE...
Replace list:   nodeforge profile replace-values rocky-9 KEY VALUE...
Clear list:     nodeforge profile clear-values rocky-9 KEY
Property help:  nodeforge profile set --help
Detailed help:  nodeforge profile set --help-full
```

这里 Selected properties 的 key 与 mutation key 完全相同；`effective.*` 和 `capabilities.*` 明确只读，
可用目录不会与已经选择的配置混在同一张表中。

### 6.4 Adapter 输出规则

- Kickstart 的 environment、group、package include/exclude 必须全部进入同一个 `%packages` 段；
  不再硬编码 `@^minimal-environment`。未配置 environment 时使用发行版 adapter 声明的显式默认值，并在
  `effective.software.environment` 中可见。
- Autoinstall 的 package 和 task，以及通过 `software.packages.include` 选择的 metapackage，必须先由 Ubuntu repository index 验证，再编译为该
  Subiquity/curtin 版本支持的 package 或 in-target apt 操作。不能把 RHEL group id 原样传给 Ubuntu。
- adapter 输出必须记录所消费的 repository revision 和完整 software selection digest，进入 install plan
  和部署事件，保证查询结果、渲染答案和实际安装来自同一份能力索引。

RHEL 示例：

```text
software.environment = minimal-environment
software.groups = [core, development-tools]
software.packages.include = [vim-enhanced]
software.packages.exclude = [firewalld]
```

编译为：

```text
%packages
@^minimal-environment
@core
@development-tools
vim-enhanced
-firewalld
%end
```

Ubuntu 没有 comps environment/group。示例选择 `software.tasks=<task-id>`，并在
`software.packages.include` 中选择 `ubuntu-server` metapackage 和 `curl` package 时，adapter 先用固定
repository revision 解析 task，再将 metapackage/package 写入
Autoinstall `packages`，必要时为 task 生成受控的 in-target apt 操作。Ubuntu `packages.exclude` 只从
显式选择结果中移除包，不保证依赖求解器永不安装它；强制禁止包应使用独立的 apt pin/deny policy。

## 7. Property、CLI、API 和输出契约

### 7.1 Typed PropertySpec

建立编译期 typed `PropertySpec` 注册表；collection/item 在第 7.2 节扩展为 CollectionSpec/ItemSpec。
三者共同作为以下功能的唯一事实源：

- 持久化路径和 owner；
- scalar/object/reference 类型，以及 collection/delta 的关联 spec；
- mutable、read-only、secret/redacted、overrideable；
- 适用 Profile kind/adapter；
- parser、validator、help、CLI mutation 和 contract test。

禁止继续维护独立的字符串 allowlist。新增模型字段但未注册 PropertySpec 时，构建或 contract test 必须失败。

目标形态示例：

```zig
const property_specs = [_]PropertySpec{
    .{
        .path = "storage.boot_disk",
        .owner = .node,
        .value_type = .device_path,
        .mutation = .set,
        .overrideable = false,
    },
    .{
        .path = "install.storage.wipe",
        .owner = .profile,
        .value_type = .boolean,
        .mutation = .set_unset,
        .overrideable = true,
        .override_path = "overrides.install.storage.wipe",
    },
    .{
        .path = "effective.install.storage.wipe",
        .owner = .derived,
        .value_type = .boolean,
        .mutation = .read_only,
        .overrideable = false,
    },
};
```

第一项只能修改 Node direct path；第二项生成 Profile mutation 和对应 Node override mutation；第三项只能
展示。parser、help 和 view 不允许再各自发明 `boot_disk`、`Boot disk`、`effective_wipe` 等另一套名字。

### 7.2 全资源集合与结构化条目 mutation

“禁止 Shell 内嵌 JSON”是整个 CLI 的产品契约，不只适用于 Profile software。它覆盖 Profile、Node、
site/startup config、Assets 子资源、discovery claim 输入以及 v0.2 新增资源。JSON 仍是 HTTP 传输和机器输出
格式；禁止的是要求用户在命令行参数中手写、引用或转义 JSON 数组/对象。

资源落点必须保持 owner 层级：Profile/Node 使用各自的通用 mutation；install source 的 repository 关联使用
`assets install-source add-values <source> repositories <repo>...`；repository/rootfs/initrd 等能力 index 是 Assets
只读派生数据，不能从 Profile 反向修改；startup config 若开放 DNS/全局 SSH keys 等集合 mutation，必须由
`setup/config` owner 提供 values/file 输入；discovery claim 只接受 typed Node direct fields。v0.2 的 boot bundle、
manifest 和 provision steps 继续套用同一规则，不能因为换了资源树就恢复 JSON argv。

PropertySpec 描述 scalar，CollectionSpec/ItemSpec 描述 collection，三者共同生成 parser、validator、help、
API operation、show metadata 和 contract tests：

```zig
const CollectionSpec = struct {
    path: []const u8,
    owner: Owner,
    item_type: ItemType,
    identity_field: ?[]const u8,
    ordered: bool,
    minimum_items: usize,
    duplicate_policy: DuplicatePolicy,
    override_mode: OverrideMode, // none | replace | delta
    operations: CollectionOperations,
};
```

CLI 按数据形态固定为三组操作：

| 形态 | CLI | 适用示例 |
|---|---|---|
| scalar/enum/nullable scalar | `set`、允许时 `unset` | hostname、locale、wipe、environment |
| scalar collection | `list-values`、`add-values`、`remove-values`、`replace-values`、允许时 `clear-values`/`unset` | disks、packages、groups、NTP、DNS、SSH keys、repositories、kernel args |
| structured collection | `item list/show/add/set/remove/move`、`replace-items --from-file`、允许时 `clear-items`/`unset` | users、partitions、routes、provision steps |

所有命令都位于实际 owner 下。例如 Node 软件 delta、直接磁盘属性和网络列表使用：

```text
nodeforge node add-values node-01 overrides.software.packages.include.add vim-enhanced
nodeforge node remove-values node-01 overrides.software.packages.include.add vim-enhanced
nodeforge profile add-values rocky-9 kernel_args console=ttyS0 iommu=pt
nodeforge node add-values node-01 overrides.kernel_args.add console=ttyAMA0
nodeforge node add-values node-01 overrides.kernel_args.remove iommu
nodeforge node set node-01 storage.boot_disk=/dev/nvme0n1
nodeforge node add-values node-01 storage.additional_disks /dev/nvme1n1 /dev/nvme2n1
nodeforge node list-values node-01 storage.additional_disks
nodeforge node add-values node-01 network.dns 192.168.50.2 192.168.50.3
```

Profile 的普通集合、结构化用户和分区使用同一语法：

```text
nodeforge profile add-values rocky-9 system.connectivity.ntp_servers ntp1.example.test
nodeforge profile item add rocky-9 system.users name=ops uid=1100 shell=/bin/bash locked=true
nodeforge profile item set rocky-9 system.users ops shell=/bin/zsh password=new-password
nodeforge profile item remove rocky-9 system.users ops
nodeforge profile set rocky-9 system.ssh.root_password=new-root-password
nodeforge node set node-01 overrides.system.ssh.root_password=node-root-password
nodeforge profile replace-items rocky-9 install.storage.partitions --from-file partitions.yaml --input yaml
```

文件替换是批量入口，不是分区配置的唯一入口。自动布局中的 `esp`、`boot`、`root` 是可查询的默认虚拟 item；
Profile 第一次对它们执行 `item set/add/remove` 时，服务端在同一个 If-Match transaction 中物化默认布局并应用修改。
Node 第一次修改 `overrides.install.storage.partitions` 时，同样原子物化当前 Profile effective partitions 为完整
replacement，再应用 item operation；CLI 成功输出必须提示该 Node 已冻结为 replacement，后续 Profile 分区变化
不会影响它。`node unset <id> overrides.install.storage.partitions` 恢复继承，`profile unset <name>
install.storage.partitions` 恢复自动布局。

分区必须支持直接 CLI 增删改查：

```text
nodeforge profile item list rocky-9 install.storage.partitions
nodeforge profile item show rocky-9 install.storage.partitions root
nodeforge profile item set rocky-9 install.storage.partitions root grow=false size_mib=51200
nodeforge profile item set rocky-9 install.storage.partitions root grow=true --unset size_mib
nodeforge profile item add rocky-9 install.storage.partitions id=var mount=/var filesystem=ext4 size_mib=20480
nodeforge profile item add rocky-9 install.storage.partitions id=swap filesystem=swap size_mib=8192
nodeforge profile item move rocky-9 install.storage.partitions swap --before root
nodeforge profile item remove rocky-9 install.storage.partitions swap

nodeforge node set node-01 overrides.install.storage.mode=raid1-lvm
nodeforge node item set node-01 overrides.install.storage.partitions root grow=false size_mib=102400
nodeforge node item add node-01 overrides.install.storage.partitions id=data mount=/data filesystem=ext4 grow=true
nodeforge node item list node-01 overrides.install.storage.partitions
nodeforge node item list node-01 effective.install.storage.partitions
nodeforge node unset node-01 overrides.install.storage.mode overrides.install.storage.partitions
```

`item add/set` 的 `FIELD=VALUE` 使用 ItemSpec 中的精确 scalar 字段名；`item set ... --unset FIELD...` 与字段
赋值在同一事务执行，用于 `size_mib`/`grow` 这类互斥字段，不能要求用户制造一个暂时非法的中间状态。
嵌套 scalar collection 继续使用
item-scoped values 操作，例如：

```text
nodeforge profile item add-values rocky-9 system.users ops groups wheel adm
nodeforge profile item replace-values rocky-9 system.users ops ssh_authorized_keys --from-file ops.keys
```

API operation 使用 collection path + item id + field path，help 和 `item show` 同样显示 `groups`/
`ssh_authorized_keys`，用户不传数组、逗号串或 JSON。
ordered collection 的 `item move` 使用 `--before <id>`/`--after <id>`，不得依赖易漂移的数组下标。
因此 users、partitions、routes 和 provision steps 必须有稳定 item identity；当前没有 partition id 的 schema
必须在 v3 修复。

`--from-file` 的规则固定：

- scalar collection 是 UTF-8 每行一个值，忽略空行和以 `#` 开头的行；也允许 `--from-file -` 从 stdin 读。
- structured collection 使用显式 `--input yaml|json`；默认 YAML，JSON 文件可用但不能以内嵌 Shell 参数传入。
- 文件先完整解析、规范化和校验，再以一个 If-Match transaction 原子发布；不能逐行产生中间状态。
- `system.ssh.root_password` 和 `system.users[].password` 按产品约定允许用普通 `KEY=VALUE`/`FIELD=VALUE`
  明文 CLI 参数设置，也允许 stdin/file；help 必须提示 shell history 可见，事件和日志不得主动复制密码值。

并非每个 collection 都允许全部操作，允许集合来自 CollectionSpec：

- Profile baseline 的空 set 是显式空；`clear-values` 保留空集合。
- Node delta 的 `clear-values` 表示清除此本地 delta 并规范化为 absent/`<inherit>`。
- ordered structured override（users/partitions）仍持久化为完整 replacement；第一次直接 item mutation 必须在服务端
  以当前 effective list 为输入原子物化和修改，并在输出中明确提示继承已冻结。`replace-items --from-file` 保留为
  显式批量原子替换，但不能成为唯一创建入口。
- Node 的 `overrides.*` 不能操作 Profile identity/source；Node direct collection 也不能伪装成 override。

不适用的操作返回 `property.operation_not_allowed` 并列出该 key 的 allowed operations；对 list key 执行
`set KEY=[...]` 返回 `property.collection_operation_required`。CLI help 为 scalar collections 生成
`List properties`，为 structured collections 生成 `Item collections` 和 item field schema，不能只给一个
“传 JSON”示例。

HTTP API 使用相同 canonical path 和原子 operation model，但 value/values/item 自然使用 JSON transport：

```json
{
  "operations": [
    { "op": "add_values", "path": "overrides.software.packages.include.add", "values": ["vim-enhanced"] },
    { "op": "set", "path": "storage.boot_disk", "value": "/dev/nvme0n1" },
    { "op": "upsert_item", "path": "system.users", "item_id": "ops", "value": {"locked": true} }
  ]
}
```

这不违反 Shell 禁止内嵌 JSON；CLI 根据 spec 构造该 DTO。一个请求中的 operations 必须共同校验、共同提交，
任一失败则全部失败。

### 7.3 精确 key

存储和 mutation 输出使用代码中的完整 canonical path：

```text
storage.boot_disk
install.storage.wipe
system.localization.locale
overrides.install.storage.wipe
overrides.software.packages.include.add
```

禁止使用 `Boot disk`、`Profile default` 等看似可写但不能直接传给 CLI 的别名代替 key。
Human view 可以增加 label/说明列，但必须同时显示 canonical path；JSON 不做 key 翻译。

硬性双向约束：

- `show` 中标记 mutable 的每个 key，必须能原样复制给对应
  `set/unset/add-values/remove-values/replace-values/clear-values` 或 `item/replace-items/clear-items` 命令。
- mutation parser 接受的每个 key，必须出现在对应资源的 `show` 和命令 `--help-full` 中；普通 `--help`
  必须明确指向详细帮助入口。
- 未设置的可写 key 仍需在 `show` 中出现，值显示 `<unset>` 或 `<inherit>`，保证用户能够发现。
- derived/runtime key 只能出现在明确的 read-only section，mutation parser 必须拒绝。

同一组 key 的 CLI 示例：

```text
nodeforge node set node-01 storage.boot_disk=/dev/nvme0n1
nodeforge profile set rocky install.storage.wipe=true
nodeforge node set node-01 overrides.install.storage.wipe=false
nodeforge node unset node-01 overrides.install.storage.wipe
```

普通 `node/profile set --help` 可以只列出 direct/override 属性组，但 `node/profile set --help-full` 必须原样
列出全部 canonical key、类型、默认值和 operation，包括 `storage.boot_disk`、
`overrides.install.storage.wipe` 和 `install.storage.wipe`。不存在仅供 help/show 使用的缩写 key。

API mutation 使用相同 path，而不是再定义一个 DTO 别名：

```json
{
  "operations": [
    { "op": "set", "path": "storage.boot_disk", "value": "/dev/nvme0n1" },
    { "op": "set", "path": "overrides.install.storage.wipe", "value": false }
  ]
}
```

Human `node show` 必须把事实、派生值和帮助信息分段，示例：

```text
Node node-01

Stored properties
KEY                     VALUE              MUTABLE
id                      node-01            no
mac                     02:00:00:00:00:11  yes
profile                 rocky-9            yes
pxe.ip_reservation      192.168.50.101     yes
http_accel              false              yes (experimental)
storage.boot_disk       /dev/nvme0n1       yes
storage.additional_disks [/dev/nvme1n1]    yes

Override properties
KEY                                 VALUE      MUTABLE
overrides.install.storage.wipe      false      yes
overrides.install.storage.mode      raid1-lvm  yes
overrides.system.localization.locale <inherit> yes

Effective properties (read-only)
KEY                                  VALUE       SOURCE
effective.install.storage.wipe       false       node override
effective.install.storage.mode       raid1-lvm   node override
effective.system.localization.locale en_US.UTF-8 profile

Runtime (read-only)
KEY                         VALUE
runtime.deployment.status   pending
readiness.install           ready

Commands
Set stored/override value: nodeforge node set node-01 KEY=VALUE
Clear override:            nodeforge node unset node-01 KEY
Property help:             nodeforge node set --help
Detailed property help:    nodeforge node set --help-full
```

属性表只承载 key/value/source/mutability；命令提示位于独立 `Commands` 段，不能伪装成属性行。
默认 human `show` 不展开长示例，只提供命令模板和 help 入口，保持输出简洁。

普通 `node set --help` 保持紧凑，但必须完整列出真实 arguments/options：

```text
Usage
  nodeforge node set <node-id> KEY=VALUE...

Options
  -o, --output <human|json>
  -c, --config <path>
  -h, --help
      --help-full

Property groups
  Direct:       identity, network, storage
  Overrides:    install, system, software, kernel arguments

Run with --help-full for canonical keys, types, defaults, constraints and examples.
```

`--help-full` 是由 CLI framework 为所有 leaf command 统一注册的长参数，不提供短参数。它在普通帮助基础上增加：

- PropertySpec 生成的完整 canonical key/type/default/operations/override path；
- CollectionSpec/ItemSpec 生成的集合 operation、item field、required/default 和联合约束；
- CommandSpec 和各 spec 生成的可直接执行示例及相关查询命令；
- 明文密码、破坏性 wipe、Node replacement 物化等必要风险提示。

例如 `nodeforge node set --help-full` 必须包含 `storage.boot_disk`、`storage.additional_disks`、
`overrides.install.storage.mode` 和全部其他可写 key；`nodeforge node item set --help-full` 必须包含
`overrides.install.storage.partitions` 的 item schema、`--unset FIELD` 原子语义及直接分区示例。

普通 `--help` 和 `--help-full` 都必须在解析必填 positional、加载 config 或连接 daemon 之前短路并返回 0；
帮助只描述静态命令/Spec，不混入某个资源的当前值、effective 值或 runtime。TTY 下完整帮助过长时可以使用 pager，
pipe/non-TTY 不分页、不加颜色。不要再增加 `--examples`、`--help-properties`、`help` 子命令或每个 command
自行命名的帮助参数；简单 leaf command 的 `--help-full` 只增加详细说明和示例，不输出空 Property 表。

只有以下数据可以使用不对应持久化字段的新 key：

- 多个事实聚合后的 `effective.*`；
- `capabilities.*`；
- `runtime.*`、`readiness.*` 和其他不可人工修改的属性。

它们必须明确标记 `read-only` 和 owner。需要脱敏的 secret 仍使用原始 key；按本项目约定，
`system.ssh.root_password` 和 `system.users[].password` 是可明文查询/配置的普通受控属性，不使用派生 alias。

### 7.4 JSON 分层

```text
result.node          exact persisted NodeConfig
result.profile       exact persisted ProfileConfig
result.effective     derived compiled plan
result.capabilities  derived resource availability
result.runtime       observed state
```

对应 JSON 示例：

```json
{
  "result": {
    "node": {
      "storage": { "boot_disk": "/dev/nvme0n1" },
      "overrides": { "install": { "storage": { "wipe": false } } }
    },
    "profile": {
      "install": { "storage": { "wipe": true } }
    },
    "effective": {
      "install": { "storage": { "wipe": false } }
    }
  }
}
```

这里 `node.storage.boot_disk`、`profile.install.storage.wipe` 和 Node override 都是可写持久化事实；
`effective.install.storage.wipe=false` 是合并结果，只读。Human show 应显示相同 path、owner 和 action。

CLI/API 不得把 persisted 和 effective 字段平铺到同一对象。scalar collection 使用
`list-values/add-values/remove-values/replace-values/clear-values`，structured collection 使用 item CRUD/
`replace-items/clear-items`；JSON 数组/对象只存在于 API/JSON 输出和 `--from-file` 解析后的请求体，
不要求用户在 shell 中手写。

### 7.5 Adapter capability registry

PropertySpec 说明“字段是否可写”，adapter capability registry 说明“指定发行版/版本如何消费字段”。
二者必须联合校验，禁止出现 CLI 接受配置但 renderer 静默忽略的情况。

| 配置领域 | Profile 基线 | Node override | Kickstart | Autoinstall |
|---|---:|---:|---|---|
| `install.storage.mode` + Node physical disks | 是 | 是 | native `part/raid/volgroup/logvol` | native curtin RAID/LVM actions |
| `install.storage.wipe/partition_table/partitions` | 是 | 是 | `clearpart/part` | curtin storage config |
| `install.bootloader.*` | 是 | 是 | `bootloader` | curtin/late-command GRUB policy |
| `system.localization.*` | 是 | 是 | `lang/timezone/keyboard` | autoinstall locale/keyboard/timezone |
| `system.connectivity.time_sync/ntp_servers` | 是 | 是 | native 或受控 `%post` | cloud-init/autoinstall NTP |
| `system.ssh.*` | 是 | 是 | native + `%post` | autoinstall SSH + user-data |
| `system.users` | 是 | 整组替换 | `user/rootpw` | identity + user-data users |
| `system.security.*` | 是 | 是 | firewall/SELinux | ufw/AppArmor 对应策略或明确 unsupported |
| `software.*` | 是 | add/remove | `%packages` | packages/task/metapackage install |
| `kernel_args` | 是 | add/remove/replace | PXE + `bootloader --append` | PXE + target GRUB drop-in |
| `install.apt.*` | Ubuntu Profile | 是 | not-applicable | autoinstall apt |
| completion/update/proxy policy | 是 | 是 | native/`%post` | autoinstall/curtin |
| post-install bundle reference | 是 | 是 | `%post` | late-commands |

每个表项按 distro/version/arch 标记 `native`、`translated`、`not-applicable` 或 `unsupported`，并可通过：

```text
nodeforge profile capabilities show <profile>
nodeforge node capabilities show <node>
```

查询。`unsupported` 字段在 mutation 或 effective compile 阶段报错；`not-applicable` 仅允许确实属于另一
安装器命名空间的字段。v0.1 必须同时补齐 completion、update、proxy、用户 UID/groups/shell/lock、
repository enablement/priority/GPG policy 等已经确认的关键安装属性，不能只增加包组后结束配置面收口。

### 7.6 展示契约验收

- PropertySpec 自动生成 parser、human help property table 和 show metadata，不允许手工维护第二份 key 列表。
- 对每个 mutable PropertySpec/CollectionSpec/ItemSpec 执行
  `show key == --help-full key == parser key == API operation path` contract test。
- `show` golden test 固定 Stored/Overrides/Effective/Runtime/Commands 的顺序、标题和空值表达。
- `--help` golden test 固定 Usage/Arguments/Options/Property groups 的紧凑顺序；`--help-full` golden test 固定
  Properties/Collections/Constraints/Examples 的详细顺序；两者都禁止混入当前资源状态。
- `--output json` 只包含 persisted/effective/capabilities/runtime 数据，不包含 Commands、Examples 或 human label。
- 需要脱敏的 secret 字段保留 canonical key 并按 spec 脱敏；root/user 明文密码字段按产品约定显示原值，
  help 明确提示管理 API、配置文件和 CLI 输出的访问权限要求。

### 7.7 统一输出与格式化

当前 `cli/output.zig`、`cli/views.zig`、`cli/table.zig` 已提供 human/json 和基础表格，但仍有大量 command
handler 直接调用 writer，尚未形成统一输出契约。v0.1 必须收敛为：

```text
command handler
  -> typed CommandResult / ViewModel
  -> OutputDocument
  -> HumanRenderer | JsonSerializer | JsonlSerializer
```

普通 handler 禁止直接拼 human 表格、JSON、成功或错误文本。允许绕过 OutputDocument 的只有明确的 artifact
命令，例如 `node render`、`config export`，因为其 stdout 本身就是 Kickstart/YAML/JSON 制品；artifact 命令
不得注册容易混淆的 `--output`。

所有格式化 leaf command 通过同一个 `OutputOptions` 注册器获得一致选项：

```text
-o, --output human|json|jsonl
--sections stored,overrides,effective,runtime,commands
--fields <canonical-key,...>
--columns <column-key,...>
--width <columns>
--wide
--no-header
--color auto|always|never
```

约束如下：

- `human` 是默认值；show 使用分区，list 使用表格。
- `json` 使用稳定 `{ok,result}` / `{ok:false,error}` envelope，不受终端宽度影响，不截断值。
- `jsonl` 只用于 list/follow/stream；不适用时返回 `output.mode_not_supported`。
- `--sections` 和 `--fields` 使用 canonical section/key，适用于 show 的 human/json 选择。
- `--columns` 和 `--no-header` 只用于 human list；JSON 始终使用字段名。
- `--width` 覆盖自动终端宽度；`--wide` 禁止截断并允许换行，二者互斥。
- 非 TTY 自动禁用 ANSI 和 pager；JSON/JSONL 永远无颜色、无表头、无帮助文本。
- stdout 只输出结果数据；诊断/debug 写 stderr；同一错误在 human/json 下共享 code/message/exit code。

HumanRenderer 使用共享 `SectionSpec`、`ColumnSpec` 和 `ValueFormatter`：

- ColumnSpec 固定列 key、标题、最小/最大宽度、对齐、换行/截断和低宽度隐藏优先级。
- 宽度计算使用终端显示宽度而非 UTF-8 字节数；长路径、长 package 名和 Unicode 不得破坏后续列对齐。
- bool、enum、timestamp、duration、bytes、nullable、inherit 和 redacted 使用统一 formatter。
- `<unset>`、`<inherit>`、`<redacted>`、`-` 的语义全局一致，不能由各 command 自定义。
- PropertySpec 驱动属性行；ViewSpec/ColumnSpec 驱动 list/status，避免同一字段在不同命令中标题、顺序、格式不同。

输出验收必须覆盖：

- 80/120/160 列 TTY golden，以及 pipe/non-TTY golden。
- 超长 key/value/path、空值、Unicode、无 ANSI 和行列对齐。
- human/json/jsonl 成功与失败 envelope、exit code 和 stdout/stderr 分离。
- `--sections/--fields/--columns` 的合法、未知、重复和不适用组合。
- 除 artifact/交互确认白名单外，lint/测试禁止 command handler 直接写 stdout。

## 8. IPv4-only 网络边界

- DHCP 只实现 DHCPv4；不保留 DHCPv6 配置或命令。
- Node target network 只接受 IPv4 address、prefix、gateway、DNS 和 route。
- validator 对 IPv6 literal/prefix 返回明确的 unsupported 错误。
- adapter 只生成 Kickstart/Netplan IPv4 配置。
- v0.2 不以“后续可能支持”为理由增加 IPv6 schema 字段。

## 9. Schema v3 迁移

迁移必须是可预览、可审计、可恢复的 catalog transaction：

1. 将 `ProfileMode.discovery`、startup `policy.default_profile` 和 `allow_unknown_diskless` 从目标 schema 删除；
   旧 unknown action 统一迁入 catalog singleton `discovery.policy.unknown_action=record`，绑定 discovery Profile 的
   Node 设为 `profile=null, deploy=false` 并要求操作员重新绑定 install Profile。
2. 对每个 install Node 计算旧 M4.12 effective storage。
3. 将旧 effective `boot_disk` 转为 Node `storage.boot_disk`；`/dev/sda` 可由 schema 默认表达，非默认值和
   显式旧 override 必须物化。旧 `install_disks` 等于单一 boot disk 时迁为 `additional_disks=[]`；真实多盘值
   先规范化为“去除 boot disk 后的候选 additional disks”，但由于旧 adapter 从未消费多值且旧 schema 没有 RAID
   mode，migration plan 必须列为 operator-decision blocker，只有操作员显式选择 mode 后才允许 apply，不能默认
   当成 RAID、静默截断或继续保留旧 key。
4. 删除 Profile 中的物理磁盘字段和 Node 的 storage physical override。
5. 保留 Profile 的 layout/wipe/partition/bootloader policy，并将 Node policy override 迁移到新路径。
6. v0.1 将 distro/version/arch 的 owner 收敛到 install source；迁移前验证 install Profile 的旧三元组与引用
   source 一致。旧 diskless Profile 不进入 v3，migration plan 将其及引用 Node 列为 operator-decision blocker。
7. 将 legacy install packages/users/SSH keys 合并到唯一的 system/software model；冲突时拒绝自动迁移。
   保留产品默认 `nodeforge/asdf1234` 和 root `asdf1234`，并规范化为 schema default 而不是在每个 Profile
   复制持久值；已有显式明文密码原值迁移。
8. 删除单值 `connectivity.mode`、derived safety booleans、重复 `match_mac`、固定 bootloader target、永远拒绝的
   firmware order 和 v0.1 boot mode；`reinstall_policy` 按新路径迁移。Provision bundle 的 repository/package
   step 分别迁入 Assets repository/software selection，只保留可转换为 v0.1 `managed-file` ItemSpec 的步骤。
9. 保留 Node `http_accel` 原值，补全 experimental/UEFI applicability metadata；默认仍为 false。
10. 为 partitions 等结构化 collection 生成稳定 item id；无法无歧义生成时列为 blocker。
11. 将整段 `kernel_args` 解析为按参数名唯一的 collection；重复名或无法规范化时列为 blocker。
12. 生成受影响 Node、before/after、desired digest 和 plan digest；操作员确认 digest 后 apply。
13. 活动 BootSession 使用 pinned old plan 完成或显式终止，不能在会话中途切换 schema。
14. schema v3 发布后拒绝旧 Profile disk 字段和全部 legacy duplicate 字段，不能永久保留兼容 fallback。

迁移失败必须回滚 manifest/entity transaction，不自动 rearm，也不改变 applied generation。

## 10. 当前代码逐模块冲突审计

本表是 2026-07-20 对当前代码的逐模块检查结果。它区分“可复用基础”和“必须修改”，不能因为某个 enum、
handler 或测试存在就认为目标契约已经实现。

| 模块/代码证据 | 当前行为 | 与目标设计的冲突 | M4.13 动作 |
|---|---|---|---|
| `src/model.zig:5-56` | AppConfig/Catalog schema 2，catalog 同时持有 v0.2 预留资源 | 不是 schema v3；预留类型容易被误报为实现 | 升级实体 schema；保留资源类型但按版本 capability gate |
| `src/model.zig:227-230` | `ProfileMode=discovery|install|diskless`，unknown policy 可引用 Profile | discovery owner 错误，v0.1/v0.2 边界混合 | 删除 discovery Profile；引入 site observation policy；v0.2 再加 tagged diskless |
| `src/model.zig:357-381` | Profile 复制 distro/version/arch，source/bundle nullable | 重复 Resource capability，允许非法组合 | v0.1 Profile 只持必填 install-source ref；平台由 source 派生，tagged kind 留到 v0.2 |
| `src/model.zig:384-440` | system 有目标默认用户/root 明文密码，同时保留 packages | 默认凭据符合产品约定，但缺完整 CLI/override；packages 是重复事实源 | 保留 schema defaults `nodeforge/asdf1234` 和 root `asdf1234`；补完整 user/password spec；packages 迁到 software |
| `src/model.zig:442-464,622-660` | target network 和物理 storage 位于 `node.overrides`；另有实验 `http_accel` direct field | network/physical disks 应为 Node direct；`match_mac` 重复；`install_disks` 未被 adapter 消费 | 移到 `NodeConfig.network/storage`；以 `boot_disk/additional_disks` 替换 install_disks；保留并完整注册 http_accel；boot disk 默认 `/dev/sda` |
| `src/model.zig:468-524` | install 再持 packages/users/SSH keys；storage 持物理 disk/未消费多盘/boot mode；partition 无 id | 三套重复入口；Profile 持硬件；多盘无明确拓扑；v0.1 UEFI-only 却暴露 BIOS 策略；结构化 collection 无稳定 identity | 删除 legacy/physical/boot-mode fields；增加 native storage mode 和逻辑 partition id；使用 CollectionSpec/ItemSpec |
| `src/model.zig:550-570` | `size_mib=0` 注释为剩余空间但 validator 拒绝；bootloader target 是固定字符串；firmware order=true 永远拒绝 | schema 自相矛盾，后两项不是有效属性 | 使用 `grow`；删除 target/set_firmware_boot_order，bootloader 固定解析 Node boot disk |
| `src/model.zig:576-618` | provision step 混合 repository、`standard_packages` 和 managed_file | 前两者与 Assets/software owner 重复，Item 没有 tagged schema/asset 内容引用 | v0.1 迁移前两者并冻结 managed-file ItemSpec；M7 在同一 resource 上扩展 action/phase |
| `src/config/load.zig:40-65` | 原地规范化整段 kernel args 字符串 | 无法支持按名称 delta/精确 item mutation | 改为 typed kernel-argument collection parser/migration |
| `src/config/validate.zig:96-179` | 只接受 schema 1/2；校验顺序基于 raw model | 无 schema v3、PropertySpec completeness 或 compiled plan validation | v3 shape + registry coverage + effective plan validation |
| `src/config/validate.zig:465-498` | 校验三个 Profile mode 与复制的平台三元组 | owner/boundary 与目标相反 | v0.1 只验证必填 install-source ref；discovery observation 独立校验，tagged branch 留到 v0.2 |
| `src/config/validate.zig:500-550` | package 只做语法检查；partition/bootloader 能力有限 | 不验证 repository revision/capability；adapter 可能忽略已接受字段 | capability index validation；按 adapter registry fail closed |
| `src/config/validate.zig:558-598` | Node 只合并 storage，network 被当 override | 完整 policy override 未编译；direct/override 混淆 | 所有 consumer 统一调用 effective compiler；network 直接校验 |
| `src/config/node_mutation.zig:12-90` | typed params 只覆盖少数平铺 key，storage 写入 override | key 不 canonical，缺少所有 collection/item/override mutation | spec-driven operation executor + If-Match transaction |
| `src/config/profile_mutation.zig:15-90` | 只支持 create、kernel_args、Profile boot disk | 正是被否决的 boot disk owner，且写入口极窄 | 删除 setBootDisk；实现完整 Profile operation executor |
| `src/catalog/iso_import.zig`、`src/state/catalog_runtime.zig` | import 原子发布 source/repository/default Profile，但不生成软件 index | 自动 Profile 仍写旧 tuple/defaults，软件能力无法查询 | import transaction 同步生成 capability revision 和 schema v3 安全 Profile |
| `src/catalog/store.zig` | manifest-last、entity digest 和 crash recovery 已实现 | schema version 固定为 2，尚无 capability-index entity | 保留 transaction；增加 v3 entity/index 与向后拒绝边界 |
| `src/profile/install.zig:7-30` | 合并 legacy system，storage 使用 Node override > Profile | 重复事实源和被否决 fallback；没有完整 effective plan | 替换为唯一 compiler，输出来源 metadata/readiness/digest input |
| `src/state/plan_digest.zig:20-85` | hash raw Node + 只替换 storage 的 Profile；包含 discovery/diskless branches | digest 不代表全部 Node override 后计划，边界跨版本 | hash canonical effective plan + resource revision；删除 v0.1 discovery branch |
| `src/state/boot_session*.zig`、`deployment_control.zig` | session 固定旧 ProfileMode 和 plan digest | schema 切换时旧 enum/plan不能被新 compiler误读 | 旧 session pinned 完成/终止；新 session只保存 kind + canonical plan identity |
| `src/profile/adapter/kickstart.zig:27-173` | M4.1 路径消费部分 system，但 `%packages` 硬编码 minimal environment | software/environment/group 缺失，部分策略依赖受控 `%post` | 只接收 compiled KickstartPlan；完整 `%packages` 与 policy mapping |
| `src/profile/adapter/ubuntu.zig:46-250` | M4.1 路径只有 flat packages；部分配置用 late-command 翻译 | task/metapackage 缺失，security/update/completion 能力不完整 | 只接收 compiled AutoinstallPlan；固定 revision 解析 task/metapackage |
| 两个 adapter 的 legacy `renderAnswer/renderUserData` | 仍固定 locale/timezone/SSH，Ubuntu legacy 使用 `storage.layout: direct` | 接受的 Profile 字段可能被静默忽略 | schema v3 后删除 legacy renderer，不保留第二条 fallback 路径 |
| `src/boot/resolver.zig:53-89` | unknown discovery action 会返回 GRUB bootfile | v0.1 record policy不应引导未知机器 | unknown record 只发诊断 lease并持久化 observation，不发 bootfile |
| `src/boot/target.zig:65-91,398` | discovery target 返回 null；diskless target有预留解析 | discovery 并未闭环；diskless 只是 scaffold | 删除 discovery target；diskless 留到 v0.2 并受 readiness gate |
| `src/dhcp/server.zig`、`src/state/dhcp_store.zig` | lease 记录 `known`，只保留活动 lease 视图 | 缺 UnknownClientObservation、revision、claim audit/retention | 新增独立持久 store、分页 API、原子 claim 和清理策略 |
| `src/http/routes.zig:37-63` | node/profile/assets/install-source 基础路由；无 repository/software/discovery | API 面不足，PATCH DTO 是 endpoint-specific alias | 增 operations、discovery、repository/software capability routes |
| `src/http/client.zig` | client 按 endpoint 手工构造 kernel/disk/node JSON body | CLI/API contract 重复且 collection operation无法复用 | typed operation client、统一 error/details/ETag handling |
| `src/http/server.zig:1938-2170` | Profile PATCH 只认 kernel_args/boot_disk；Node PATCH 使用短 key | API path 与 persisted path 不一致且无法表达 collection item | 统一 canonical operation DTO，PropertySpec/CollectionSpec 驱动 |
| `src/http/server.zig:2196-2583` | show 手写拼接 raw/effective/runtime，profile/node JSON shape不同 | persisted/effective 混排，key/secret/source metadata 不稳定 | typed ViewModel/OutputDocument；统一分层和 redaction |
| `src/main.zig:69-410` | 命令树缺 software/discovery/Assets repository 子资源 | 用户无法完成查询、选择、认领闭环 | 注册完整命令树，普通 handler 不直接输出 |
| `src/main.zig:1732-2077` | Profile 两个短 key；Node 暴露未消费的逗号拼接 install disks | show/help/parser key不一致；无效字段和集合 UX 都是 ad-hoc string | 用 `storage.additional_disks` values commands 替换 install_disks；registry parser + 全局 scalar/collection/item commands + framework `--help-full` |
| `src/cli/properties.zig:1-46` | enum/string allowlist | 不是 typed registry，也不能表达 owner/type/operation/adapter | 替换 PropertySpec + CollectionSpec + ItemSpec |
| `src/cli/output.zig`、`views.zig`、`table.zig` | 有 envelope/table 基础，但 View 直接写 writer，table option 很少 | 不是统一 document pipeline；固定行容量和命令间格式差异 | 引入 OutputDocument/Options；保留安全宽度算法作为 renderer 基础 |
| `src/main.zig` 直接 writer 调用 | 当前仍有 201 个 `ctx.writer.print/writeAll/writeByte` 调用 | JSON/human/error/stdout 规则无法统一保证 | artifact/确认提示白名单外全部迁移，并用 lint 阻止回归 |
| `src/catalog/store.zig`、`src/catalog/migration.zig`、`src/setup.zig` | catalog schema 2/layout 1；现有 migration 只处理 catalog URL/tuple | 不具备 ownership v3 plan/apply/rollback | 新增独立 schema v3 migration，不复用旧 migration 含义 |
| `src/root.zig`、`src/app.zig`、`src/nodeforged.zig` | 直接组装当前 model/runtime/handler | 新 registry、observation store和 index 需要明确生命周期/依赖注入 | 在 composition root 单例化 compiler/registry/store，消费者只借用接口 |
| `tests/cli.sh`、`tests/http.sh` | 固定验证 Profile boot disk fallback、discovery Profile 和短 key | 测试把旧错误设计钉死；没有 collection/item/output contract | 先改 contract tests，再加 registry/golden/migration/双 adapter E2E |

可直接复用的基础包括 catalog manifest-last transaction、ETag/If-Match、分页 revision、node session pinning、
deployment generation、IPv4 parser、table 的 UTF-8 显示宽度和 JSON success/error envelope。它们不需要推翻，
但必须改为消费 schema v3 DTO/effective plan。

## 11. 实施顺序

### M4.13.1 所有权和 effective compiler

- 重构 Profile/Node/override/resource 类型。
- 删除 Profile discovery mode和 startup unknown policy；增加 catalog discovery-policy singleton、
  UnknownClientObservation、retention/claimed audit 和原子 Node claim。
- 引入 Node direct `storage.boot_disk/additional_disks`、`/dev/sda` 默认值、固定 mode 枚举和原生 storage compiler。
- 建立唯一 effective plan compiler 和 readiness validator。
- 清除 adapter、digest、HTTP handler 中的局部 fallback。

### M4.13.2 属性契约

- typed PropertySpec、CollectionSpec 和 ItemSpec，包含 registry completeness test。
- 完整 Profile set/unset/list-values/add-values/remove-values/replace-values/clear-values。
- 完整 Node direct/policy override mutation 和 structured item CRUD/atomic replace-items；分区必须支持直接 item
  操作、首次原子物化和可选文件批量替换。
- 全部 CLI resource 禁止 Shell 内嵌 JSON；large/structured input 使用统一 `--from-file`。
- exact-key human/JSON views、紧凑 `--help`、framework `--help-full` 和 API DTO。
- typed OutputDocument、统一 OutputOptions/renderer/serializer，并迁移普通 handler 的直接 writer 输出。

### M4.13.3 软件能力

- repository index transaction 和 revision identity。
- RHEL comps、Ubuntu task/metapackage/package 查询。
- `assets install-source/repository` list/show/software 诊断命令和 Profile-first available/show 命令。
- Profile software selection、Node delta、adapter 输出和可用性校验。
- 将旧 provision repository/package step 迁入 Assets/software owner，补齐最小 managed-file bundle ItemSpec、
  Assets CRUD 和 Profile reference validation。

### M4.13.4 迁移和验收

- schema v3 plan/apply/rollback。
- 全量自动化回归。
- Rocky 与 Ubuntu 的默认 `/dev/sda`、显式其他 `/dev/...` 路径，以及 single/LVM/全部 RAID/RAID-LVM
  mode 的原生渲染、失败关闭和可复现虚拟硬件验证；不得借助存储脚本。
- 更新 config example、README、审计和运维文档。

## 12. v0.1 完成标准

以下条件必须全部满足：

- Profile schema 中不存在物理磁盘，Node/Profile schema 中均不存在旧 `install_disks`；Node 使用
  `storage.boot_disk/additional_disks`，adapter 原生消费全部有效成员。
- Profile schema 中不存在 discovery mode；未知客户端可以记录、分页查询、认领和审计。
- discovery policy 是 daemon-owned catalog singleton，`record|deny`、retention、revision、If-Match 和 claim revision
  均有 CLI/API/持久化测试；startup config 不再保存 unknown Profile/diskless policy。
- Node 未显式设置磁盘时使用 `/dev/sda` schema 默认值。
- 默认和显式 `/dev/...` 路径、成员数约束、单主 ESP、默认 ext4/no-swap，以及全部 12 个 mode 在双 adapter
  中通过渲染、安装和失败关闭测试。
- 本文列出的全部 Profile 策略可被 Node override，且 clear override 后恢复继承。
- Node network/storage direct collection 和 Profile/Node policy collection 均可通过 `list-values` 查询并增删、
  替换或按 spec 清除；structured collection 支持稳定 identity 的直接 item CRUD、首次原子物化和可选文件替换。
- 任意 CLI resource 都不要求 Shell 内嵌 JSON；list key 传给 scalar `set` 会返回带可执行替代命令的 typed error。
- 所有有效配置消费者使用同一 effective plan 和 digest。
- repository/install-source/Profile context 可以 list/show/search：Kickstart 的 environment/group/package 和
  Autoinstall 的 task/metapackage/package；Profile selection 与 Node delta 支持完整增删改查。
- Kickstart 不再硬编码唯一 package environment；Autoinstall 不再只支持无来源的平铺 package list。
- 每个 mutable key 满足 `show key == --help-full key == parser key == API path`；普通 `--help`、完整帮助和 show
  分区通过 golden/contract test。
- v0.1 provision bundle 只有 immutable managed-file asset 驱动的 managed-file ItemSpec；旧 repository/package step 已迁移，
  Assets item CRUD、原子 file replacement、Profile reference 和双 adapter install-post 渲染通过测试。
- 未显式配置时 effective 用户为 `nodeforge/asdf1234`、effective root 密码为 `asdf1234`；两者可通过
  canonical CLI/Profile/Node override 明文查询和修改，事件与普通日志不主动记录密码值。
- 除 artifact/交互白名单外所有 CLI handler 走统一 OutputDocument；human/json/jsonl、列宽、字段过滤、
  stdout/stderr 和错误 envelope 通过统一 golden/contract tests。
- IPv6 输入被一致拒绝且文档不承诺 IPv6。
- schema v3 migration 支持 plan、digest、apply、rollback 和活动会话保护。
- Rocky/Ubuntu 完整 PXE 安装、登录、事件、retry/drift 和 daemon restart-resume 全部回归。

完成并冻结上述契约后，才允许按 `V0_2_DESIGN.md` 启动 M5。
