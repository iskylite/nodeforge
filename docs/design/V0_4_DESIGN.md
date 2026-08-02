# NodeForge v0.4 统一设计

状态：设计冻结，实现未开始。

本文是 v0.4 的唯一权威设计，完整取代此前 v0.4 草案。v0.4 只支持 UEFI GRUB + DHCPv4 PXE，
不增加其他 firmware/bootloader 路径或绕过 DHCP 的 firmware static PXE，不兼容或迁移 v0.3 及更早的
catalog、runtime state、BootSession 或 delivery snapshot。升级到 v0.4 必须 fresh `setup` 并重建
catalog、boot bundle、rootfs artifact 与运行状态。本文中的 schema/DTO 都是计划接口；除明确标注的
BootConfig v3 和现有 PXE 链路外，v0.4 新增能力目前尚无实现。

v0.4 实现完成后的全量双机发布验证必须按
[`V0_4_FULL_VALIDATION_RUNBOOK.md`](../validation/V0_4_FULL_VALIDATION_RUNBOOK.md) 从空环境执行；该运行手册定义证据和
PASS/FAIL 闸，不替代本文的产品契约。

v0.3 及更早版本设计是已落地冻结基线，本文只继承其已验收契约，不回写历史文档。冻结文档中面向“后续版本”的
旧展望若与本文冲突，仅由本文裁决 v0.4 行为；历史版本当时的实现与验收结论保持不变。所有不属于 v0.4 确定实施范围的
方案统一登记在 [`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md)，本文只保留必要的排除边界和链接，不定义其
字段、CLI、协议、版本号或完成标准；保留设计也不能反向改变本文。

## 0. 核心决策

v0.4 固定以下决策，后续章节不得给出相反行为：

1. **PXE bootstrap 不改协议**：仍由 DHCPv4 识别 `node.mac`、分配动态地址或
   `pxe.ip_reservation` 保留地址、下发 UEFI GRUB bootfile。initrd 继续从 GRUB cmdline 取得
   已确认的 lease 地址/MAC/prefix/gateway 并直接复用，不再运行第二次 DHCP 即可下载 rootfs。
2. **不新增 no-DHCP static bootstrap**：当前已经落地的“稳定 bootstrap 地址”就是 DHCP reservation；v0.4 不增加
   第二条启动链。相关考量只在
   [`STATIC_PXE_BOOTSTRAP_DEFERRED.md`](STATIC_PXE_BOOTSTRAP_DEFERRED.md) 保存，本文不定义其字段或协议。
3. **firmware/bootloader 范围固定**：v0.4 的 schema、CLI、resolver、测试和完成闸只实现 UEFI GRUB 路径；BIOS/PXELINUX
   只见 [`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)。
4. **全部直接替换，不迁移**：AppConfig v5、catalog v6 和 v0.4 state schema 只接受 fresh
   v0.4 数据；不加载、不转换、不保留 v0.3 active session 或旧 delivery snapshot。
5. **BootConfig 保持 v3**：v0.4 不改变 initrd 下载 rootfs、内存预算、AgentPlan locator、
   event/facts URL 的最小 DTO，因此没有 BootConfig v4。现有文档中的 “BC v4” 是未实现草案，
   在本设计中删除。
6. **AgentPlan 升为 v2**：目标网络从单 NIC 结构改为完整 topology，且 agent 需要 bootstrap
   lease snapshot 执行有界网络切换，因此 AgentPlan shape 发生变化。v0.4 agent 只接受 v2，
   不兼容 AgentPlan v1。
7. **目标 topology 与 PXE transport 分离**：`node.mac`/`pxe.ip_reservation` 决定 PXE；
   `network.interfaces/bonds/vlans/routes` 决定安装后的目标系统或 diskless 最终 rootfs 网络。
   target topology 不改变 firmware、DHCP、GRUB、TFTP 或 rootfs HTTP 下载方式。
8. **agent 仍不是远程任务平台**：所有 agent 行为都由本次开机前固定的 immutable plan 驱动；
   不接收运行期任务，不做 reconciliation，不持有长期 enrollment credential。
9. **凭据恢复沿用已落地原语**：所有新增 capability 都用 daemon master secret、`deployment_id`、audience 和
   resource identity 做域分离确定性派生；持久文件只保存 hash/claim/counter，不保存 raw token。daemon restart 只能
   重构同一个 raw token并与 hash 比对，绝不签发并行 token；master secret 缺失或不匹配才进入
   `*.recovery_incomplete`。

### 0.1 当前实现事实

以下是本设计的代码基线，不把文档草案当作已实现功能：

| 事实 | 当前实现 |
|---|---|
| DTO 版本 | [`diskless_dto.zig`](../../src/http/diskless_dto.zig) 明确固定 BootConfig v3、AgentPlan v1；仓库中没有 BootConfig v4 或 AgentPlan v2 实现 |
| PXE cmdline | [`target.zig`](../../src/boot/target.zig) 对 install/diskless 固定生成 `ip=dhcp`，diskless 另携带 `nodeforge.ip/prefix/gateway/mac` |
| reservation | [`server.zig`](../../src/dhcp/server.zig) 把 `pxe.ip_reservation` 作为 DHCP 保留地址处理 |
| initrd 网络 | [`initrd.zig`](../../src/initrd.zig) 优先复用 firmware/vendor initramfs 已配置的地址，否则按 cmdline lease facts 对匹配 MAC 的接口执行 IPv4 ioctl |
| 当前 discovery | [`model.zig`](../../src/model.zig) 的 unknown observation 以 MAC 为身份，只能 `discovery list/show` 后人工 `node claim ... discovery.mac=<mac> arch=<arch>` |
| 当前 SN 采集 | [`initrd.zig`](../../src/initrd.zig) 已读取 DMI `product_serial/product_uuid/vendor/model` 并上传 facts，但只有已知 MAC 建立普通 diskless session 后才能到达该代码 |
| 待删除耦合 | [`effective.zig`](../../src/profile/effective.zig) 目前会在 target mode 为 DHCP 且存在 reservation 时隐式改成 static；v0.4 必须删除该行为 |

因此，“static bootstrap 已落地”的准确含义是“DHCP reservation + initrd 复用已确认 lease”已经落地，
不是“firmware 不使用 DHCP 的静态 PXE”已经落地。后者不进入 v0.4，独立保留稿见
[`STATIC_PXE_BOOTSTRAP_DEFERRED.md`](STATIC_PXE_BOOTSTRAP_DEFERRED.md)。

## 1. 目标与范围

v0.4 包含五项产品能力：

| 能力 | v0.4 结果 |
|---|---|
| 多 NIC/VLAN/bonding | install 与 diskless 共用一个 Node-owned target topology；diskless 在 rootfs/payload 全部校验后有界切换 |
| 容量与长期运行 | 产品侧限流可强制，发布提供版本化 workload、SLO、原始指标和失败注入证据 |
| PXE rootfs builder node | eligible Node 在下一次 UEFI DHCP PXE 中进入一次性 builder boot，产物回传服务端统一 cache |
| install first-boot | 安装器把固定 plan/payload/agent 写入目标盘，首次本地 systemd 启动执行一次，不依赖自定义 initrd |
| SN-assisted discovery | 先创建只有 SN + 预留 IP 的 draft Node，短时 discovery initrd 上报 SN 后自动回填 PXE MAC/arch；仍保持 deploy=false |

进入 v0.4 前必须满足：

- v0.3 install-post canonical runner、generation callback 和 journal 已实现并验收；
- Rocky/RHEL 与 Ubuntu 的 UEFI install/diskless 回归通过；
- 四个产品二进制边界稳定。

fresh v0.4 setup、boot bundle/rootfs rebuild 和旧 layout 拒载不是进入条件，而是实现切片 1 的首个合入闸；
在它们完成前，其他 v0.4 slice 只能使用隔离 fixture，不能写入现有 v0.3 install root。

非 v0.4 能力不在本文展开：DHCP-less static PXE、BIOS/PXELINUX 和 `ram_rootfs` 分别进入独立保留稿；永久非目标不进入
保留队列。完整状态与链接以 [`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md) 为准。

## 2. 版本和直接替换规则

v0.4 使用以下独立 schema namespace：

| 数据 | v0.3 | v0.4 | 规则 |
|---|---:|---:|---|
| AppConfig | 4 | 5 | v5 增加强制容量上限；不加载 v4 |
| Catalog | 5 | 6 | v6 增加 target topology、builder policy/capability、Node hardware serial binding；不加载 v5 |
| BootConfig | 3 | 3 | shape 不变；只由 fresh v0.4 session 生成 |
| AgentPlan | 1 | 2 | v2 使用 topology 和 bootstrap lease snapshot；只接受 v2 |
| BuilderPlan | 不存在 | 1 | builder operation 专用 immutable plan |
| InstallFirstBootPlan | 不存在 | 1 | install 首次启动专用磁盘 plan |
| BootSession state | 4 | 5 | 固定 AgentPlan v2、topology transition 与 first-boot handoff identity |
| diskless delivery state | 3 | 4 | 固定 AP2 digest、network transition/adopt 终态 |
| operation state | 3 | 4 | 增加 builder operation 投影，不加载 v3 |
| status state | 5 | 6 | 增加 topology/builder/install-first-boot 状态投影 |
| rootfs artifact state | 1 | 2 | 增加 builder ABI/class/provenance 与 deep-validation 结果 |
| BuilderAttempt / BuilderUpload state | 不存在 | 1 / 1 | 分离 boot slot 与上传 lease/offset |
| InstallFirstBoot server journal | 不存在 | 1 | generation-bound handoff/exchange/terminal 状态 |
| Discovery observation state | catalog observation v1 | runtime v2 | observation 移出 desired catalog，按 PXE MAC 保存原始 DHCP/initrd 事实 |
| NodeDiscoveryState | 不存在 | 1 | 每个 SN+IP draft Node 的短时自动匹配状态 |
| 其他 state envelope | DHCP 3、identity 1、inventory 2、deployment 4、runtime 2、install-post 1 | 依次 4 / 2 / 3 / 5 / 3 / 2 | 增加 fresh deployment binding，即使领域字段未变也拒绝旧文件 |

fresh `setup` 生成不可变随机 `deployment_id` 和 DeploymentManifest v1。AppConfig、catalog、每个 state
envelope 和 artifact index 都必须携带同一 `deployment_id`；daemon 先校验 manifest，再加载任何数据。缺失或不匹配
一律 `deployment.layout_incompatible`，不能把旧文件复制进新目录继续运行。ISO/asset 原始 bytes 可以重新导入，但必须
重新登记到 fresh index；旧 index、rootfs manifest 和 token hash 不复用。

磁盘提交协议固定如下：

- `<install-root>/deployment.json` 为 DeploymentManifest v1，至少包含
  `schema_version=1`、32 位小写 hex `deployment_id`、`product_major_minor="0.4"`、
  `app_config_schema=5`、`catalog_schema=6`、`state_schema_set_sha256`、`created_at`；未知字段和重复 key 拒绝；
- `<install-root>/.nodeforge-root` 升为 `nodeforge-root-v2 <deployment_id>\n`，它是 fresh setup 的最终提交标记；
  marker、manifest、AppConfig 和 catalog 四处 id 必须完全一致；
- setup 先在同一 filesystem 的 staging 目录写 config、空 catalog、master secret 和 manifest，逐文件
  `fsync`，再 fsync staging directory；发布时先 rename 数据，最后 atomic replace root marker 并 fsync install root；
- purge 已开始但 marker 尚未提交时写 `<install-root>/.nodeforge-replacement-incomplete`。正常 daemon 看到该文件或缺少
  v2 marker 必须拒启；修复原因后只允许重跑同一个 fresh setup，成功提交后删除 incomplete marker；
- daemon 加载顺序固定为 root marker → DeploymentManifest → AppConfig → catalog manifest/entities → master secret →
  state envelopes → artifact indexes。任一步失败都不能启动 DHCP/TFTP/HTTP 写服务，也不能部分恢复成旧 deployment；
- 同一个 v0.4 deployment 内的 `--reset-state`/不带 purge 的 `--reset-all` 保持原 `deployment_id`；只有
  fresh initialization 或 `--reset-all --purge-all` 生成新 id。备份不再是可加载输入，复制回原路径仍因 id/schema 被拒。

升级流程只有一种：

1. 停止旧 daemon；
2. 操作员自行归档旧 install root（仅作审计，不作为 v0.4 输入）；
3. 使用空 install root 执行 v0.4 `setup`，或显式
   `setup --reset-all --purge-all --reconfigure --yes`；
4. 重新导入 ISO/asset，重新创建 Profile/Node/bundle；
5. 重新构建 initrd、boot bundle 和 rootfs；
6. 通过 v0.4 readiness 后重新启用 Node。

v0.4 不提供 v5→v6 converter、旧 state loader、旧 session continuation、旧 AgentPlan reader 或
旧 artifact 自动登记。任何“兼容读取后再保存”的实现都违反本设计。

### 2.1 继承且不得改写的契约

v0.4 虽然 fresh replacement，产品行为仍继承已经验收的语义，而不是重新发明第二套 owner 或 runner：

- PropertySpec/CollectionSpec/ItemSpec registry 是字段、CLI、help、parser、API 和 effective compiler 的唯一来源；
- Profile 持有可共享 system/software/build policy，Node direct 持有 identity、target topology 和 per-Node override；
- install 与 diskless 共用 target-system、software、`kernel_args` 和 provision action 语义；
- canonical phase 仍只有 `install-post|rootfs-build|first-boot`，action 仍只有
  `managed_file|package|archive|script`，执行顺序、timeout、retry、finalizer 和 event 脱敏沿用既有契约；
- 每个 Node 同一时刻只有一个 boot slot；install、diskless 和 builder attempt 相互排斥；
- session/operation 使用创建时固定的 immutable snapshot，不在执行途中读取最新 catalog；
- raw token/密码/private key 不进入 catalog、kernel cmdline、日志、preview 或通用 artifact；持久 state 只保存
  token hash/claim，raw token 只在 master-secret 确定性重构后的有界内存、0400 文件或 tmpfs capsule 中出现；
- capability 派生统一使用 `HKDF/HMAC(master_secret, deployment_id || audience || resource_id || generation || counter)`
  的域分离输入；每个 endpoint 比对持久 hash、完整 claim、method/path/body digest、expiry 和 replay counter，不能由各领域
  自选随机 token/restart 语义；
- install/diskless delivery 继续 local-only、IPv4-only；`/dev/...` 目标磁盘契约和不支持稳定磁盘 selector 的边界不变；
- digest 分层保持：build input 决定 `rootfs_input_digest`，Node effective 决定 `desired_plan_digest`，
  boot/session/runtime locator 决定 delivery snapshot，artifact bytes 由 content SHA-512 校验。四者不得互相代替。

### 2.2 严格编码、默认值和限制

所有 v0.4 持久对象、DTO、plan digest 和 HTTP JSON 使用同一 strict decoder/canonical encoder：

- UTF-8、JSON object；拒绝未知字段、重复 key、NaN/浮点数、数字字符串和 enum 大小写 alias；schema 版本必须存在且精确；
- 可选字段“省略”和 `null` 只在类型明确允许时等价；有默认值的字段在进入 validator/digest 前物化为显式规范值，禁止
  renderer 各自套发行版默认；
- object key 按字段定义顺序编码；`interfaces/bonds/vlans/routes` 按 canonical `id` 升序，bond `members` 按 id
  升序并拒绝重复；DNS 与 search domain 保留用户声明顺序（它们有优先级语义）但拒绝重复；
- digest 输入不含 JSON whitespace、时间戳、operation/session id、物理 builder Node id或运行时 URL；同一语义经 CLI、API、
  保存再加载必须产生完全相同 bytes/digest；
- v0.4 硬上限：每 Node 最多 64 physical interface、16 bond、64 VLAN、256 route、16 DNS、16 search domain，
  每 bond 最多 32 member；BootConfig v3 ≤ 64 KiB、AgentPlan v2 ≤ 256 KiB、BuilderPlan v1 ≤ 1 MiB、
  InstallFirstBootPlan v1 ≤ 256 KiB。超限在创建 authority 前以稳定 `*.too_large` 拒绝；不能截断或分页一个 immutable plan。

## 3. 所有权和摘要

| 事实 | owner | 是否影响 PXE | 是否进入 `rootfs_input_digest` | 是否进入 Node `desired_plan_digest` |
|---|---|---:|---:|---:|
| `node.mac` / `node.arch` | Node direct | 是 | 否 | 是 |
| `hardware.serial_number` | Node direct；discovery matching key | 否；DHCP 不提供 SN | 否 | 否；进入 identity revision/audit，不改变目标系统 bytes |
| `pxe.ip_reservation` | Node direct | 是，作为 DHCP reservation | 否 | 否 |
| target network topology | Node direct | 否 | 否 | 是 |
| Profile system/software/rootfs-build | Profile | 否 | 是 | 是 |
| `builder.placement` | Profile build policy | 否 | 否 | 否；只进入 Profile revision/operation snapshot |
| required builder capability class/ABI/environment digest | effective build compiler | builder PXE readiness | 是 | 否 |
| physical builder Node id | Builder operation snapshot | builder PXE | 否 | 否 |
| rootfs content digest | Runtime artifact | diskless delivery | rootfs input 的输出，不反向进入输入 | delivery snapshot |

`rootfs_input_digest` 是“什么输入应该得到什么 rootfs”的 cache key：

```text
rootfs_input_digest = SHA-256(canonical {
  install source + immutable source layers,
  target arch + kernel release,
  Profile system/software/rootfs-build closure,
  pinned asset/repository/SSH identity revisions,
  builder ABI + required builder capability class + builder environment manifest digest
})
```

它的作用是让相同构建输入只发布一个共享 rootfs。100 个绑定同一 Profile 的 Node 复用同一个
artifact；换 package、kernel、asset、SSH identity 或 builder ABI 才产生新 key。`builder-node-a`
和 `builder-node-b` 若声明相同 capability class/ABI，物理 Node id 不进入 key，否则同一内容会被
无意义地构建成多个 cache 分支。

`builder.placement=server|node` 只选择在哪里执行同一个构建计划，也不改变内容。若 server builder
和 node builder 对同一个 `rootfs_input_digest` 产生不同 content SHA-512，后提交者以
`builder.non_reproducible` 失败，现有 ready artifact 不被覆盖。

### 3.1 cache miss 后的 rootfs 生命周期

key 变化表示“当前 Profile build projection 需要一个新的 rootfs artifact”，但不等于必须 clone Profile。
v0.4 固定两种操作方式：

**同名 Profile 原地升级**：

1. `profile set/unset/add-values/item ...` 原子发布新的 Profile revision；
2. `profile rootfs plan <profile>` 计算新 `rootfs_input_digest`；
3. cache miss 时，`profile rootfs build <profile> --if-input-digest <digest> --if-revision <revision>`
   创建有界 build operation；
4. operation 固定当时的完整 build projection，构建 `.part`、校验并发布新 content-addressed artifact；
5. artifact ready 前，绑定该 Profile 当前 revision 的 Node 在 build readiness 阶段失败，DHCP 可给诊断 lease但不下发
   diskless bootfile；已有 active session 继续使用自己已经固定的旧 artifact；
6. artifact ready 后，新 session 自动引用新 digest。旧 artifact 保留为不可变审计/在途输入，v0.4 不做 rootfs GC。

这里的“旧 artifact/active session”仅指同一个 fresh v0.4 deployment 内较早的 Profile revision，不是保留 v0.3
数据或跨产品版本兼容；v0.3→v0.4 仍全部拒载。

Profile 在 plan 与 build 之间再次变化时，`--if-revision` 或 `--if-input-digest` 必须以
`rootfs.digest_drift` 拒绝；已完成但不再被当前 Profile 引用的 artifact 仍保持合法，不自动覆盖或删除。

**并行版本/灰度升级**：

需要同时保留旧配置和新配置、先做 canary 或逐批切换 Node 时，才使用
`profile clone <source> <target> [KEY=VALUE...] --build`。clone 创建新的逻辑 Profile 和独立 revision；新旧 Profile
各自解析 digest，Node 由显式 rebind 决定何时切换。clone 是发布策略，不是 cache key 变化的技术前提。

因此三者关系固定为：Profile revision 描述 desired configuration，`rootfs_input_digest` 标识构建输入，content
SHA-512 校验实际 artifact bytes；不能拿 clone 名称代替 digest，也不能用 content hash 反向推导配置。

### 3.2 摘要输入和 CAS 规则

三个摘要分别由独立 typed projection 计算，禁止对整个 Catalog/AppConfig 做“方便的全对象 hash”：

| 摘要 | 必含 | 明确排除 | 用途 |
|---|---|---|---|
| `rootfs_input_digest` | §3 构建闭包、builder environment/class/ABI | Profile name/revision、placement、物理 Node、URL、时间戳 | cache key 与可复现性比较 |
| `desired_plan_digest` | Node id/MAC/arch、Profile/effective target system、software、topology、kernel args、provision projection revision | PXE reservation、SN、session/operation、runtime URL、artifact content hash | desired drift、AgentPlan/InstallFirstBootPlan 绑定 |
| `delivery_digest` | desired digest、boot bundle/content revisions、rootfs content SHA-512、DTO bytes digest、session/generation identity | 当前 Catalog revision、未被 snapshot 引用的新 artifact | 本次 boot/install 的 immutable 投递身份 |

`hardware.serial_number` 只用于建立/审计物理身份。修改 SN 必须使 `node_identity_revision` +1、取消 pending discovery 并写
审计事件，但不会改变已经配置好的目标系统或 rootfs，因此不进入 desired digest。若操作员同时修改 MAC/arch/topology，
这些真正影响计划的字段仍会自然产生新 desired digest。

canonical 编码对每个变长字段使用类型 tag + 大端长度前缀，整数使用固定宽度大端表示，不能直接拼接裸字符串。
每次 build/session/generation 创建同时固定 owner revision 与预期摘要；CAS 检查发生在创建 operation/session/token/staging
之前。revision 或摘要任一变化均零副作用拒绝；authority 创建后只消费 snapshot，当前 Catalog 后续变化仅影响新流程。

## 4. PXE bootstrap：沿用已实现链路

v0.4 的正常 install、diskless 和 builder boot 都共用同一启动链：

```text
UEFI firmware
  -> DHCPDISCOVER/REQUEST（MAC + arch）
  -> nodeforged 按 node.mac 匹配并分配 lease
     - 有 pxe.ip_reservation：返回保留地址
     - 无 reservation：返回池内动态地址
  -> DHCP option 67 下发对应架构 GRUB EFI
  -> GRUB 拉取固定 config + kernel/initrd + credential capsule
  -> cmdline 携带 nodeforge.mac/ip/prefix/gateway/config_url
  -> nodeforge-initrd 按已确认 lease 直接配置 PXE NIC
  -> HTTP 拉取 BootConfig v3、rootfs 和 AgentPlan locator
```

PXE 只读取：

- `node.mac`：唯一 bootstrap NIC 身份；
- `node.arch`：选择 x86_64/aarch64 UEFI GRUB 和 kernel；
- `pxe.ip_reservation`：可选 DHCP 保留地址；
- `node.profile`/`deploy`/install generation 或 builder attempt：决定是否下发 bootfile；
- boot bundle、server IP/port、DHCP subnet/router。

PXE 不读取 target topology 的 bond、VLAN、route、DNS 或目标静态地址。v0.4 同时删除旧 effective
compiler 中“`network.mode=dhcp` 且存在 `pxe.ip_reservation` 时自动改成目标 static”的行为：
reservation 只属于 bootstrap，目标网络必须由 topology 显式声明。

### 4.1 `pxe.ip_reservation`

`pxe.ip_reservation` 是“NodeForge DHCP server 给指定 Node MAC 永久保留的 PXE 管理网 IPv4”，仍通过标准
DHCP DORA 过程发放，不是 firmware static IP，也不是目标操作系统的静态地址：

- 配置时必须位于 `dhcp.subnet`，不能是 network/broadcast/server/router 地址；
- 全部 Node 中唯一；若落在动态 pool 内，allocator 必须把它从普通候选地址中排除；
- OFFER 前仍执行地址冲突探测；检测到占用则拒绝 bootfile，不自动换成动态地址；
- Node 未配置 reservation 时，从动态 pool 获取普通 lease；
- 修改 reservation 只改变后续 PXE lease，不改 target topology、不触发 rootfs rebuild；
- 删除 Node 或取消 reservation 后，只有在旧 lease 到期/释放且冲突探测通过后，地址才能重新进入 pool。

它适合需要固定 ACL、抓包、日志关联或跨 PXE 重启保持管理地址的节点；不需要稳定管理地址时应省略。

## 5. Catalog v6 target network topology

### 5.1 数据结构

Node 使用一个 `network` 对象：

```text
network.interfaces[]
network.bonds[]
network.vlans[]
network.routes[]
network.dns[]
network.search_domains[]
```

四个 structured collection 都由 `CollectionSpec/ItemSpec` 驱动，CLI、help、parser、mutation API
和 show 输出使用同一 registry。

`network.interfaces[]`：

| 字段 | 规则 |
|---|---|
| `id` | 必填；目标 OS link name，Linux interface name，1-15 字符；不是 pre-init 当前 kernel name |
| `mac` | 必填；物理 NIC 永久 MAC，整个 Catalog 全局唯一；runtime 始终按永久 MAC 找当前 link |
| `mtu` | 可选，576-9216；省略时规范化为 1500 |
| `ipv4` | 必填 tagged object，见下文 |

`network.bonds[]`：

| 字段 | 规则 |
|---|---|
| `id` | 必填；目标 bond link name |
| `mode` | `active-backup|802.3ad` |
| `members[]` | 至少两个，只能引用 physical interface id |
| `mac_source_id` | 必填；引用一个 member，以该永久 MAC 作为 bond 的确定性逻辑 MAC |
| `miimon_ms` | 默认 100；范围 50-1000，所有模式必填归一值 |
| `up_delay_ms/down_delay_ms` | 默认 0；必须是 `miimon_ms` 的整数倍；renderer 分别映射到 kernel `updelay/downdelay` |
| `primary_id` | active-backup 必填且必须为 member；802.3ad 禁止 |
| `primary_reselect` | active-backup：`always|better|failure`，默认 `failure` |
| `lacp_rate` | 802.3ad：`slow|fast`，默认 `fast`；active-backup 禁止 |
| `xmit_hash_policy` | 802.3ad：`layer2|layer2+3|layer3+4`，默认 `layer2+3` |
| `min_links` | 802.3ad：1..members 数，默认 1；active-backup 禁止 |
| `mtu` | 可选；省略时规范化为全部 member resolved MTU 的最小值，且不能大于任一 member MTU |
| `ipv4` | 必填 tagged object |

BOND 只开放上表选项，不允许透传任意 NetworkManager/Netplan/sysfs option。这样 Rocky/RHEL 与 Ubuntu
renderer 能产生等价配置，AgentPlan digest 也不会被自由字符串绕开。`mac_source_id` 只决定目标 bond 的逻辑 MAC，
不改变 physical interface 的 permanent MAC，也不参与 PXE MAC 匹配。bootstrap NIC 是 member 时，deployable validator
强制 `mac_source_id` 指向该 NIC；否则把已确认 DHCP lease 迁到 bond 会改变 IP/MAC 绑定并在 DAI/source-guard 环境中产生
不可验证行为。bootstrap NIC 不属于 bond 时，`mac_source_id` 可选择任一 member。

外部交换机契约不是 NodeForge 要远程配置交换机，而是操作员必须预先满足的端口条件：

| host bond mode | 交换机前置条件 |
|---|---|
| `active-backup` | 两个及以上 member 端口必须进入相同 L2 broadcast domain，具有完全一致的 access VLAN 或 native/tagged VLAN 集合和兼容 MTU；端口保持普通独立端口，不配置 static port-channel/LACP。若跨两台交换机，交换机必须提供同一逻辑二层域并允许同一 MAC 在端口间迁移 |
| `802.3ad` | 全部 member 必须预先加入同一个 LACP LAG；跨机箱只能使用交换机已配置的 stack/MLAG/MC-LAG，不能把两个无关交换机端口当成一个 LAG；native/tagged VLAN、MTU、速率/双工能力必须兼容，LAG 至少有 `min_links` 个成员完成 collecting/distributing |

NodeForge 不能仅从节点侧静态证明交换机配置，`node readiness` 只能输出上述 external prerequisites；运行时再以
member carrier、bond active slave 或 LACP aggregator/collecting/distributing 状态作为本地硬闸，并以 authenticated
network proof 验证实际 server 可达性。若 PXE VLAN 启用了 DHCP snooping、DAI、IP source guard 或 port security，
bootstrap NIC 进入 bond 时 `mac_source_id` 已由 deployable validator 强制选择该 NIC；交换机仍必须允许同一 lease
IP/MAC 从 physical bootstrap port 迁移到目标 bond/active member。gratuitous ARP 不能绕过交换机安全绑定，runtime
proof 必须 fail closed。

#### 5.1.1 BOND 中文注释与帮助文本硬要求

BOND 涉及节点配置、交换机前置条件、PXE 地址迁移和失败回滚，不能只靠字段名表达。实现 PR 必须在以下位置提供
**详细中文注释**，说明“为什么这样做、失败会怎样”，不能只把代码翻译成中文：

| 位置 | 必须说明的中文内容 | 固定注释主题标识 |
|---|---|---|
| PropertySpec/ItemSpec registry | 字段用途、单位、默认值、适用 mode、互斥字段、引用对象、是否影响 digest | `BOND-字段契约` |
| structural/deployable validator | 为什么 member L3 必须为 none、为什么字段不能跨 mode 混用、为什么 MTU/delay/min_links 如此约束 | `BOND-校验原因` |
| NetworkManager renderer | bond keyfile、slave connection、MAC、LACP/primary 参数如何由 canonical 字段生成；哪些选项刻意不支持 | `BOND-NetworkManager映射` |
| Netplan renderer | bond parameters、interfaces、VLAN parent、地址/route 如何映射；与 NetworkManager 结果如何保持语义一致 | `BOND-Netplan映射` |
| pre-init transition | bootstrap anchor、MAC/IP/route 为什么按该顺序迁移，哪一步开始可能失联，超时值和 proof 边界 | `BOND-切换顺序` |
| rollback | 逆序删除 L3/VLAN/bond、恢复 master/MTU/MAC/IP/route 的顺序，以及 rollback 自身失败后的隔离行为 | `BOND-回滚边界` |
| runtime adopt | 为什么真正 init 后要再次检查、检查 active slave/aggregator/min_links 的方法、何时清理 bootstrap 地址 | `BOND-init接管` |
| CLI help/full-help | 每个参数的中文用途、默认值、mode 限制、交换机配置要求、完整示例和常见错误 | `BOND-CLI帮助` |

示例注释必须达到以下信息量；实现可以按模块拆分，但不得删除语义：

```zig
// BOND-切换顺序：PXE 地址当前仍在 bootstrap 物理口。该物理口加入 bond 后不能继续承载 L3，
// 因此先让其他成员形成 carrier/aggregator，再把 bootstrap 地址和 server host route 迁移到 bond。
// 如果等待超时，必须在删除物理口地址前退出；如果已经删除，则立即按快照恢复并发送 gratuitous ARP。

// BOND-回滚边界：这里只回滚本次 session 创建或修改的对象，不删除启动前已经存在的管理配置。
// 逆序是 target route/address -> VLAN -> slave relationship -> bond -> physical master/MTU/MAC/address/route。
```

`--help-full` 的 BOND 段落必须使用中文主动提示：active-backup 交换机端口不能配置 LACP；802.3ad 必须预建同一
LACP LAG；跨交换机需要 stack/MLAG/MC-LAG；DHCP snooping/DAI/IP source guard/port security 可能阻断
bootstrap IP/MAC 迁移。普通 `--help` 至少显示参数用途和合法 token，并指向 `--help-full` 的交换机前置条件。

中文注释是代码评审和完成闸的一部分，但不能代替 typed validator、稳定错误码和测试。生成的 NetworkManager keyfile
或 Netplan YAML 不强制注入中文注释，避免不同 renderer 对注释保存行为不一致；中文说明的权威位置是源码、CLI help
和本文。

`network.vlans[]`：

| 字段 | 规则 |
|---|---|
| `id` | 必填；目标 VLAN link name |
| `parent_id` | 必填；引用 physical interface 或 bond，不允许 VLAN-on-VLAN |
| `vlan_id` | 1-4094 |
| `mtu` | 可选；省略时等于 parent resolved MTU，且不能大于 parent MTU |
| `ipv4` | 必填 tagged object |

三类 L3-capable link 共用：

```text
ipv4.mode = none | dhcp | static
ipv4.address       # 仅 static 必填
ipv4.prefix_len    # 仅 static 必填，1-32
ipv4.default_route # 仅 dhcp 可用，默认 true
```

`network.routes[]`：

| 字段 | 规则 |
|---|---|
| `id` | 必填，Node 内唯一 |
| `destination` | 必填 IPv4 CIDR；默认路由写 `0.0.0.0/0` |
| `gateway` | 必填 IPv4 地址 |
| `metric` | 可选 u32 |
| `interface_id` | 必填；引用 `ipv4.mode != none` 的 interface/bond/VLAN |

`network.dns` 和 `network.search_domains` 保持 Node direct scalar collection。DNS 是目标系统全局
resolver 配置，不参与 PXE DHCP option 6 的生成。target DHCP 下，显式非空 `network.dns/search_domains` 覆盖对应 DHCP
结果；空集合表示接受 target DHCP 返回的 DNS/search。该规则必须由两个 renderer 和 pre-init/adopt checker 等价实现，
不能一个发行版 merge、另一个 replace。

接口命名分两层：pre-init 通过 permanent MAC 发现 `current_name`，target `id` 是最终名称。rename 前先校验目标名称未被
其他 link 占用；多接口换名形成环时使用 session-owned 临时名 `nf<index>` 分两阶段完成。rename、master、MTU 和 L3
变化都进入 rollback 快照；不得假定 firmware 名称恰好等于 target `id`。

规范词法固定为：link/route id 区分大小写但只接受 `[A-Za-z][A-Za-z0-9_.-]{0,14}`，拒绝 `lo`、`all`、`default`
和 session 临时前缀 `nf[0-9]`；MAC 保存为小写冒号分隔 6 bytes，IPv4/CIDR 保存为无前导零的 dotted decimal，search
domain 保存为去尾点的小写 ASCII DNS name。parser 可以接受大小写 MAC/等价 IPv4 文本，但在唯一性检查、show、保存和
digest 前必须规范化；两个输入规范化后冲突即拒绝，不能保留不同拼写。

### 5.2 拓扑不变量

同一个 validator 提供 `structural` 和 `deployable` 两个严格度，不维护两套字段逻辑：每次 catalog mutation 都执行
structural；`deploy=true` 的 Node mutation、`node readiness` 和创建 session 前执行 deployable。待 discovery 的
`profile=null,deploy=false` Node 可以暂时没有 topology，便于逐步录入；但只要创建某个 item，该 item 的类型、引用和
模式专属字段必须立即结构合法。`node deploy true` 必须在同一事务先通过全部下列 deployable 规则，失败不打开 gate。

deployable 规则：

1. interface/bond/VLAN 的 `id` 在整个 Node 内全局唯一；route id 单独唯一；
2. interface permanent MAC 在整个 Catalog 全局唯一，且必须恰有一个 interface 的 MAC 等于 `node.mac`；该 interface
   是 bootstrap NIC 在 target topology 中的对应 link；
3. 每个 physical interface 最多属于一个 bond；bond member 的 `ipv4.mode` 必须为 `none`；members、
   `mac_source_id`、`primary_id` 引用必须存在且无重复；
4. VLAN parent 只能是 interface 或 bond；引用必须存在；
5. 至少一个 L3-capable link 使用 `ipv4.mode=dhcp|static`，且最多一个 link 使用 DHCP；
6. 最多一个目标默认路由来源：一个 `dhcp/default_route=true` 或一个显式 `0.0.0.0/0` route；
7. static 必须同时给 address/prefix，none/dhcp 禁止携带 address/prefix；
8. 同一 Node 的 static address 不得重复，且不能是对应 subnet 的 network/broadcast address；
9. static route gateway 必须可从 `interface_id` 的 static subnet 直接到达；DHCP link 上的 gateway
   在 lease 获得后由 renderer/runtime 校验；
10. 省略 MTU 必须先按 §5.1 物化 resolved 值；MTU 满足 child ≤ parent/member，bond member 必须能被设置为 bond MTU；
11. 所选 distro adapter 必须支持 topology 使用的 bond mode、VLAN 和 renderer，否则 readiness
    以 `network.adapter_unsupported` 拒绝；
12. active-backup/802.3ad 的模式专属字段不能混用；delay 必须是 miimon 的倍数，802.3ad `min_links`
    不能大于 member 数；
13. bootstrap NIC 属于 bond 时，该 bond 的 `mac_source_id` 必须引用 bootstrap NIC；
14. static target 在移除临时 bootstrap route 后，必须能由 connected subnet 或显式 route 唯一解析到
    `server_ip`；DHCP target 无法静态证明时 readiness 标为 runtime-required，network proof/adopt 为硬闸；
15. IPv6 字段、任意 renderer 名称、自由脚本、任意 bond option 或未注册 link type 一律拒绝。

### 5.3 哪些网络事实影响哪个阶段

| 事实 | Firmware/DHCP/GRUB | initrd 下载 rootfs | install 目标配置 | diskless 最终网络 |
|---|---:|---:|---:|---:|
| `node.mac` | 是 | 是，定位 bootstrap NIC | 用于匹配 topology 中同 MAC interface | 用于 bootstrap→target 对应 |
| `pxe.ip_reservation` | 是 | 是，作为已确认 lease | 否 | 只作为切换前 bootstrap snapshot |
| interface MAC/name/MTU | 否 | 否 | 是 | 是 |
| bond/VLAN | 否 | 否 | 是 | 是 |
| target DHCP/static address | 否 | 否 | 是 | 是 |
| target routes/DNS/search | 否 | 否 | 是 | 是 |

## 6. Install 与 diskless 的网络执行

### 6.1 install

install renderer 直接把同一个 target topology 转换为安装器支持的目标盘配置：

- Rocky/RHEL：Kickstart/NetworkManager 表达 physical interface、bond、VLAN、address、route 和 DNS；
- Ubuntu：Autoinstall/Netplan 表达同一 topology；
- adapter 不支持的 bond mode 或字段在 readiness 阶段失败，不允许丢字段或退化成单 NIC。

安装链必须把“installer transport network”和“目标盘持久网络”分开：installer 进程始终保留 PXE DHCP bootstrap，完成
repository/payload/agent/plan 下载、install-post callback 和 `handoff.completed`；target topology 只由 adapter 写入目标根，
不允许安装器为了生成目标配置提前拆 bootstrap bond/地址。Rocky/RHEL adapter 使用安装器 transport 配置取源，并在目标根
发布 canonical NetworkManager keyfile；Ubuntu adapter 保持 ephemeral installer Netplan，再由 curtin late stage 原子发布
`/target/etc/netplan`。若某发行版 adapter 无法做到 staged target write，readiness 返回
`network.adapter_unsupported`，不能退化为安装中直接 cutover。

第一次本地启动才由目标系统 NetworkManager/Netplan 应用 topology；install first-boot 等待
`network-online.target` 并先执行与 §6.3 adopt 同等级的 topology/server reachability check，但不再次创建或改写网络。
失败报告 `network.adopt_failed` 并阻止 first-boot actions。static topology 的 server route 在 readiness 静态证明，DHCP
topology 在首次本地启动实测；两发行版都必须覆盖“installer 全程保持 bootstrap、重启后 target 生效”的 E2E。

### 6.2 diskless AgentPlan v2

BootConfig 继续使用当前 v3 shape；其 `agent_plan.digest/size` 仍校验 AgentPlan 的完整 canonical JSON bytes，
不是 `desired_plan_digest`。AgentPlan v2 wire shape 固定为：

```text
schema_version = 2
deployment_id / node_id / session_id
desired_plan_digest / delivery_digest / rootfs_input_digest
bootstrap_network {
  interface_mac, address, prefix_len, gateway?, dhcp_server_id,
  lease_expires_at, server_ip, server_port
}
target_network {
  interfaces[], bonds[], vlans[], routes[], dns[], search_domains[]
}
node_apply_projection_without_network
first_boot {
  bundle?, bundle_revision?, steps[], package_manager?, repository_urls[],
  max_attempts, backoff_seconds, payloads[] {path,size,sha256,mode}
}
required_agent_features[]
event_url / expires_at
```

`bootstrap_network` 来自本次已认证 DHCP BootSession，不来自可变 catalog；`target_network` 来自本次
immutable desired plan。v2 从 `node_apply_projection` 删除 v1 的单 NIC `network` 字段，`target_network` 是唯一网络 owner，
禁止同时编码两份网络配置。AgentPlan v2 不携带 token；`agent:read` 与 `event:append` 仍在独立 0400 credential 文件中。
所有 URL 必须是本次 session 的 node-bound 本地 HTTP 路由，parser 拒绝非 `http`、非配置的 `server_ip:port`、userinfo、
fragment、重定向和不在 allowlist 的 path。

agent feature 至少包含：

- `agent-plan-v2`；
- `network-topology-v1`；
- 使用 bond 时 `bonding-v1`；
- 使用 VLAN 时 `vlan-v1`；
- first-boot 有 payload 时 `node-firstboot-payload-v1`。

boot bundle manifest 分别声明 initrd 和 agent feature。fresh v0.4 boot bundle 缺任何 feature 时 readiness
失败；不存在 v1 fallback。

AgentPlan v2 parser 必须校验：顶层/嵌套未知字段、重复 payload path、path traversal、payload size/digest、全部 topology
引用和 feature closure；`deployment_id/node/session/digest` 与 BootSession checkpoint 精确匹配。先校验 locator size 与
SHA-256，再 parse typed JSON；任何失败发生在 payload 获取和网络 mutation 之前。

### 6.3 diskless 有界切网事务

这里有三个不同阶段：

- **transition**：`nodeforge-agent` 的 pre-init 在真正 init 尚未启动时，使用内核网络接口创建 bond/VLAN/目标 L3，
  同时维持或迁移 bootstrap anchor；
- **network proof**：切换后先证明本机路由选择和到 NodeForge server 的真实双向连接都使用预期 source/link；
- **init adopt**：`exec` 真正 init 后，由 NetworkManager/Netplan 根据已发布的持久配置重新枚举并接管现有 link。
  adopt 只确认“持久网络管理器接管后的最终状态仍符合 AgentPlan”，不是再执行一次目标切换。

必须单独有 adopt 阶段，因为 pre-init 通过 netlink/iproute 创建成功，只能证明当前内核瞬时状态；真正 init 启动后，
NetworkManager/Netplan 可能重建 connection、重新请求 DHCP、改变 route metric、拆除未被配置文件承认的 bond/VLAN，
或者把地址重新放回 physical slave。如果在 proof 后立即清理 bootstrap 或运行 first-boot，就可能在真正用户空间网络
接管时失联。

initrd 必须先完成 rootfs 下载、SHA-512 校验、挂载和 AgentPlan locator handoff。agent pre-init 随后：

1. 拉取并严格解析 AgentPlan v2；
2. 拉取全部 payload 到 session-owned `.part`，校验 size/digest 后原子发布；
3. 校验 bootstrap MAC/IP 与本机当前 link/address 相符；
4. 清除 `agent:read` token；
5. 选择目标 rootfs 的唯一 network adapter，按 permanent MAC 解析当前 link 名称并渲染到 session staging；
6. 保存 link master、carrier、address、route、MTU 和 bond/VLAN 状态快照；把“当前承载 bootstrap
   address + server host route 的 link”记为 bootstrap anchor；
7. 若 bootstrap NIC 不属于 bond，保持该 physical anchor 不变，再创建目标 bond/VLAN/L3；
8. 若 bootstrap NIC 将成为 bond member，不允许继续把地址留在 slave 上：先创建 bond、应用确定性 MAC/MTU/options，
   attach 非 bootstrap members。若这些 members 已使 active-backup 有 carrier 或 802.3ad 满足 `min_links`，先把
   bootstrap address/server host route 移到 bond，再清 physical 地址并 enslave bootstrap NIC；否则在全部远端输入
   已预取后执行有界本地 cutover：清 physical 地址/route、enslave bootstrap NIC、等待 bond carrier/aggregator，
   成功后把 bootstrap address/route 加到 bond。等待超时立即 unenslave 并恢复 physical snapshot。若目标 L3 在
   VLAN 上，bootstrap address 可临时保留在未标记的 bond base，renderer adopt 后再清理。每次 anchor/MAC 迁移后
   发送有界 gratuitous ARP 并刷新本机 neighbor state；rollback 恢复 physical anchor 后同样发送；
9. 配置 target address/route。target 使用 DHCP 时启动独立 target DHCP transaction（每次 response timeout 5 秒，
   总 deadline 30 秒，带 0-500 ms deterministic jitter），但 bootstrap anchor 在 target lease 成功前保持；该临时 client
   只用于 pre-init proof，真正 init 的 NetworkManager/Netplan 重新 DORA 并由 adopt 校验。target 为 static 时直接配置；
10. 本地执行 `ip route get <server_ip>`，记录实际 egress link/source；
11. 使用 `event:append` token POST `/api/v1/nodes/:id/network-proof`，body 固定包含
   `schema_version=1,session_id,event_seq,stage=pre_init,desired_plan_digest,egress_link,source_ip,route_gateway?,
   topology_state_sha256`；服务端校验 session、expected phase、plan digest、event sequence、body digest和 TCP peer source
   与声明 source 一致，成功返回 204；
12. proof 成功后原子发布 renderer 文件并 exec 真正 init。renderer 发布失败或 `exec init` 返回失败时，仍处于
    pre-init 可逆边界，必须按依赖逆序删除 target L3/VLAN、unenslave bootstrap NIC、删除 bond、恢复 physical
    bootstrap address/route/MTU/master 快照，报告 `network.transition_failed`；只有回滚验证和 bootstrap proof
    都成功后才终止本次 boot。若无法恢复则升级为 `network.rollback_failed`/quarantine，不得继续 init 或 first-boot；
13. 真正 init 启动 `nodeforge-agent --network-adopt` oneshot。它等待对应 renderer 的 online/settled 状态，重新读取
    physical master、bond mode/active slave 或 LACP aggregator、VLAN parent/id、地址、route 和 DNS，并再次执行
    server network proof（同一 endpoint，`stage=adopt`，新的 event sequence）；全部与 pinned AgentPlan 相符才算 adopted。
    确认后删除只服务 bootstrap 的旧 address/route；
    失败则保留 bootstrap、禁止 first-boot 并报告 `network.adopt_failed`；
14. adopt 成功后才允许 first-boot unit 执行。

proof 前失败执行完整内核快照回滚；真正 init 已启动后的 adopt 失败不声称能把 NetworkManager/Netplan 回滚到
pre-init 瞬时状态，而是保留仍可用的 bootstrap anchor、阻止后续配置并暴露诊断。所有 v0.4 diskless 根是易失 root，断电重启会
重新从 DHCP bootstrap 开始；在同一次启动中的任意失败必须保留可诊断的 bootstrap 网络。

若 target topology 显式包含与 bootstrap 相同的 address/prefix，则该地址是目标地址，不删除；只清理临时
server host route。若目标地址不同，则 adopt 成功后删除旧 lease 地址。bootstrap NIC 成为 bond member 时，
“保留 bootstrap”指保留其地址与 server 可达性并迁移 bootstrap anchor，不是把 L3 地址非法留在 slave 上。
相同 address/prefix 不能在两个 link 上短暂重复：target link 等于 anchor 时把现有地址标记为 adopted；target link 不同时
使用 `ip address replace`/netlink move 语义在 journaled cutover 中迁移。target DHCP 恰好返回 bootstrap 地址时也走同一
迁移分支，不能同时启动两个拥有同地址的 client state。

### 6.4 状态、CAS 与可观测性

v0.4 diskless canonical phase 在既有 v0.3 状态语义上只增加网络阶段：

```text
diskless.boot_config_fetched -> diskless.rootfs_downloading -> diskless.rootfs_verified -> diskless.rootfs_mounted
  -> diskless.agent_plan_fetched -> diskless.network_preparing -> diskless.network_transitioning
  -> diskless.network_proved -> diskless.switching_root -> diskless.network_adopting -> diskless.running
  -> diskless.failed | diskless.expired | diskless.cancelled | diskless.recovery_incomplete
```

- `network_preparing` 前禁止任何 link mutation；`network_transitioning` entry 必须已有完整 rollback journal；
- pre-init proof 只允许 `network_transitioning -> network_proved`，adopt proof 只允许
  `network_adopting -> running`；body、token、event sequence 和 expected phase 是一个原子 CAS；
- `diskless.running` 仍只表示真正 init 已启动且 target network adopted，不代表 first-boot actions 成功；first-boot 结果继续
  投影到独立 postprocess journal，保持已落地语义；
- `network-proof` body 上限 16 KiB，不接收自由日志。详细 link/route/bond 状态作为按 digest 固定、脱敏后的 session event
  写入本地/服务端 journal；`node session show` 展示 phase、anchor、source/link、rollback/adopt 结果和 stable error；
- retry 只能创建新 BootSession/AgentPlan v2；terminal session、旧 event token 或旧 event sequence 不能重新进入网络阶段。

## 7. PXE rootfs builder node

### 7.1 目的

默认 server builder 在 daemon 主机的 staging/chroot 中构建 rootfs。部分 rootfs-build action（DKMS、
驱动探测、目标 kernel initramfs 重生成或硬件相关 closure）需要更接近目标机器的 kernel/hardware 环境。
node builder 允许一台显式可信 Node 在下一次 PXE 中进入一次性构建环境，但最终 artifact 仍上传并发布到
nodeforged 的统一 rootfs cache；它不是目标 Node 的本地私有镜像。

node builder 不能用“待构建的 target rootfs”作为自己的启动根，否则 cache miss 会形成循环依赖。v0.4 增加独立
`BuilderEnvironmentManifest v1`：由 server builder 从已导入、固定 revision 的本地 install source 构建并发布一个最小
builder runtime squashfs，包含 `nodeforge-agent --builder`、目标架构 libc/shell、包管理器、squashfs/归档/hash 工具和
plan 声明的构建工具链。它与普通 Profile rootfs 分开登记、不能作为 diskless target rootfs 使用。

manifest 至少固定 runtime content SHA-512/size、kernel/modules ABI、agent digest、builder ABI、tool/package closure、
source/repository revisions、capability classes 和 `builder_environment_digest`。node builder 的 UEFI GRUB 使用现有发布
kernel/initrd；initrd 以 `mode=builder` 拉取 BuilderPlan、下载并校验这个 runtime 后 switch_root 到 builder agent。
builder runtime 缺失或 feature/ABI 不匹配时 `profile rootfs plan/build` 在 attempt 创建前失败，不允许先让 Node PXE 再发现。

### 7.2 schema 和选择

Profile：

```text
builder.placement = server | node   # 默认 server
```

Node direct：

```text
builder.eligible = true | false     # 默认 false
builder.abi = nodeforge-builder-v1
builder.capability_classes[]
```

effective compiler 在 `profile rootfs plan` 阶段根据 target arch、distro、kernel、rootfs-build action 和
版本化 builder adapter 推导唯一 `required_builder_capability_class`，并解析唯一
`builder_environment_digest`。无法唯一推导或环境未 ready 时 plan 失败，不允许到选择物理 Node 时再改变 digest。

eligible Node 必须满足：

- `deploy=false`；
- `builder.eligible=true`；
- arch、builder ABI 和 capability class 精确匹配；
- 无 active/recoverable install、diskless 或 builder boot slot；
- 属于操作员认可的本地可信网络和物理信任域。

`--builder-node` 可显式选择；省略时 daemon 按 Node id 字典序选择第一个匹配且空闲的 eligible Node，选择结果
只写 operation snapshot，不回写 Profile。

### 7.3 operation 和 PXE 优先级

`profile rootfs build` 先计算 digest并查询 cache：已有 ready artifact 直接返回 cache hit；否则以
`(deployment_id,rootfs_input_digest,builder_environment_digest)` 为唯一 in-flight key 原子创建 canonical
`rootfs_build` operation。相同 key 的重复请求复用同一 operation；若重复请求指定不同 `--builder-node`，返回
`builder.selection_conflict`，不创建第二个 build。

placement=node 时同时创建 operation-owned `BuilderBootAttempt`：

```text
queued -> armed -> booting -> building -> uploading -> validating
       -> ready | failed | expired | cancelled
```

外部 operation 映射固定为：

| BuilderBootAttempt | operation state |
|---|---|
| queued | queued |
| armed/booting/building/uploading/validating | running |
| ready | succeeded |
| failed/expired/cancelled | failed，保留稳定 error code |

DHCP resolver 对已注册 Node 的决策顺序：

1. 存在匹配且未过期的 armed BuilderBootAttempt：即使 `deploy=false` 也下发 builder UEFI bootfile；
2. 无 builder attempt 且 `deploy=true`：进入普通 install/diskless gate；
3. 其他情况只给诊断 lease，不下发 bootfile。

builder 仍使用 DHCPv4、GRUB、credential capsule；不增加其他 bootloader、远程重启或运行中任务下发。操作员或外部
电源系统负责让 Node 进入下一次 PXE。

### 7.4 BuilderPlan v1 和凭据

BuilderPlan v1 固定：operation id、builder node id、input digest、build projection digest、target arch/kernel、
builder ABI/capability class、BuilderEnvironmentManifest locator/digest、四类 canonical rootfs-build steps、
pinned input closure、预期 artifact format、upload URL、event URL、expiry。BuilderPlan 本身不内联 raw secret，
每个 asset/repository/runtime/payload locator 都带 size + content digest 且必须位于 plan allowlist。

credential capsule 包含四个不可互换的 operation-bound token：

- `builder-plan:read`：只读该 BuilderPlan；
- `builder-input:read`：只读 plan 明列的 asset/repository/secret capsule；
- `builder-upload:write`：只允许写该 operation 的 upload path；
- `builder-event:append`：只追加该 operation 状态事件。

所有 claim 绑定 deployment、operation、Node、input digest、builder environment digest、method/path、audience 和 expiry；
token 按 §0 决策 9 确定性派生，持久层仅存 hash/claim。restart 后只重构相同 token，claim/counter 不匹配即失败。
Profile password hash、SSH private key 等构建所需 secret 只在独立 tmpfs secret capsule 中出现，不进入 plan、
cmdline、catalog、日志或上传内容。物理 builder 必然能看到最终 rootfs，因此 `eligible=true` 是显式信任授权，
不是安全隔离。

builder HTTP surface 固定为：

| method/path | audience | 成功 | 关键约束 |
|---|---|---:|---|
| `GET /api/v1/builder-attempts/:id/plan` | `builder-plan:read` | 200 | canonical BuilderPlan bytes，ETag=SHA-256，禁止 redirect |
| `GET /api/v1/builder-attempts/:id/inputs/:sha256` | `builder-input:read` | 200/206 | 只读 plan allowlist，严格 size/ETag/Range |
| `HEAD /api/v1/builder-attempts/:id/upload` | `builder-upload:write` | 200 | 返回持久 offset/expiry，不创建 gap |
| `PATCH /api/v1/builder-attempts/:id/upload` | `builder-upload:write` | 204 | 连续 Content-Range，request body ≤ 16 MiB |
| `POST /api/v1/builder-attempts/:id/finalize` | `builder-upload:write` | 202 | body ≤ 16 KiB，CAS 后进入 validating，不同步阻塞 deep validation |
| `POST /api/v1/builder-attempts/:id/events` | `builder-event:append` | 204 | schema v1/event_seq/expected_state/body digest 幂等 CAS |

所有错误使用统一 JSON envelope；401/403 不泄露 attempt 是否存在，404 只用于通过 claim 后资源确实缺失，409 表示
state/offset/CAS 冲突，410 表示 expired/spent，429/503 带 Retry-After。

### 7.5 上传、发布和恢复

builder 在 tmpfs/staging 中完成 OS layer、四类 rootfs-build action、agent/unit 注入和 squashfs 生成，计算
size/SHA-512 后上传：

1. `HEAD upload_url` 取得当前 operation-owned `.part` offset；
2. `PATCH upload_url` 使用严格连续 `Content-Range` 追加，禁止越界、乱序或跨 operation；
3. 完成后 POST finalize，声明 size/SHA-512/input digest；
4. server 校验完整 size/hash、squashfs 可读性、必需文件/agent manifest、builder ABI 和 input digest；
5. 与同 input 的现有 content digest 比较；不一致报 `builder.non_reproducible`；
6. 全部通过后 fsync + atomic rename 到统一 rootfs object path，再登记 ready artifact；
7. `.part`、lease 或 deep validation 任一失败都不得发布。

attempt、operation journal、upload lease 和已接收 offset 持久化。固定 deadline 为：armed 等待 PXE 30 分钟、booting
15 分钟、build operation 总计 4 小时、单次 upload request idle 2 分钟、相邻 upload request idle 10 分钟；全部使用
monotonic clock，持久化时转换为绝对 UTC expiry，restart 后按剩余时间恢复，不重新获得完整预算。daemon restart 后：

- capsule 未完整交付：daemon 由 master secret 重构并重放同一 canonical capsule；master secret/hash/claim 不匹配才终止为
  `builder.recovery_incomplete`；
- builder 已持有 token：继续以同一 raw token 对持久 hash/claim 验证，按 offset 恢复上传；
- operation expiry：撤销全部 token/boot slot，删除 `.part`，终止为 `builder.expired`；
- ready/failed/expired/cancelled 均原子释放 Node 唯一 boot slot。

### 7.6 发布事务和 provenance

server 对 finalize 使用 operation-owned transaction journal，顺序固定为：校验 request CAS → close upload lease →
fsync `.part` → SHA-512/size/squashfs deep validate → 写候选 manifest并 fsync → content-addressed object rename → fsync object
directory → artifact index compare-and-swap → fsync index → 标记 operation ready。object rename 前失败可安全删除 candidate；
rename 后、index commit 结果不确定时进入 quarantine 并由启动一致性审计判定，不能根据“文件存在”猜测 ready。

provenance 至少保存 input/build-environment/plan/content 四类 digest、builder Node id/identity revision、capability class、
agent/adapter version、started/completed time、step attempt 摘要和 deep-validation 版本。物理 Node id 只用于审计，不进入
cache key。builder runtime、input或工具链任何 revision 变化都会得到新的 input digest；不能在相同 key 下覆盖 provenance。

## 8. Install first-boot

### 8.1 执行位置

install first-boot 不使用 `nodeforge-initrd`。安装后的第一次本地启动使用发行版正常 initrd 和 systemd；
`nodeforge-agent --install-first-boot` 由安装器预先写入目标盘的 oneshot unit 启动。这消除了“标准安装系统中
谁来运行 NodeForge initrd”的歧义。

install 继续只引用 `install.post_install.bundle` 和 Node override。一个 effective bundle 可以同时包含
`install-post` 与 `first-boot` step：

- `install-post` 在安装器环境执行；
- `first-boot` 只被编译进 InstallFirstBootPlan，不在安装器中执行。

### 8.2 安装器 handoff

install generation 创建时，nodeforged 编译 immutable InstallFirstBootPlan v1：

```text
schema_version = 1
deployment_id / node_id / install_generation / desired_plan_digest / delivery_digest
bundle_revision / first_boot_plan_digest
steps[] / package_manager / pinned repository URLs
payloads[] {path,size,sha256,mode}
agent {url,size,sha256}
event_url / exchange_url / expires_at
```

没有 effective `first-boot` step 时不生成 plan/token/unit，generation 投影为 `first_boot=not_required`，沿用已落地的
install-post 完成语义。存在至少一个 step 时 first-boot 是 generation 的 required completion gate：installer 可以完成
目标盘安装和 handoff，但 NodeForge `ready` 只有收到该 plan 的 `first_boot.succeeded` 终态后才打开；failed/stale 不能伪装 ready。

安装器使用现有 BootSession credential 完成以下动作：

1. 下载并校验 `nodeforge-agent` 到 generation-owned staging；
2. 下载并校验 plan/payload 到
   `/var/lib/nodeforge/install-firstboot/<generation>.staging/`（0700，同一 filesystem）；
3. 从 generation-bound capsule endpoint 取得一次性 first-boot bootstrap token，直接以 0400 写入
   `/var/lib/nodeforge/credentials/first-boot.token`；answer file 只包含 endpoint，不包含 raw token；
4. 写入 `nodeforge-install-firstboot.service`，固定
   `After=network-online.target`、`Wants=network-online.target`、`ConditionPathExists=<generation>/pending`；
5. 写入非 secret node/generation/plan identity；不修改 bootloader kernel cmdline；
6. 逐文件 fsync，fsync staging directory，rename 为 `<generation>/`，fsync parent，最后 atomic write `pending`；随后才提交
   `handoff.completed`。agent 二进制以相同 digest 原子发布到 `/usr/sbin/nodeforge-agent`；
7. golden image、通用 rootfs artifact、catalog 和日志中不得出现 token。

capsule endpoint 只接受该 install generation 的现有 BootSession credential；在同一 installer credential、
generation 和短时 delivery window 内有界重放相同 bytes，直到安装器提交 `handoff.completed`，完成后立即关闭。
first-boot bootstrap token 按 §0 决策 9 从 master secret + deployment/node/generation/plan 派生，checkpoint 只存 hash/claim；
daemon restart 重放同一 capsule bytes，不生成第二 token。master secret/hash/claim 不匹配才以
`first_boot.recovery_incomplete` 失败。`handoff.completed` 后 token claim 的 24 小时 TTL 开始计时；超时未 exchange 必须
创建新 install generation。安装器日志不得启用会输出响应 body 或 Authorization header 的 debug/xtrace。

first-boot HTTP surface 固定为：

| method/path | caller credential | 成功 |
|---|---|---:|
| `GET /api/v1/nodes/:id/install-generations/:gen/first-boot/plan` | 当前 installer BootSession | 200 canonical plan |
| `GET /api/v1/nodes/:id/install-generations/:gen/first-boot/payloads/:sha256` | 当前 installer BootSession | 200 immutable bytes |
| `GET /api/v1/nodes/:id/install-generations/:gen/first-boot/capsule` | 当前 installer BootSession | 200 deterministic capsule |
| `POST /api/v1/nodes/:id/install-generations/:gen/first-boot/handoff` | 当前 installer BootSession | 204 CAS `handoff.completed` |
| `POST /api/v1/nodes/:id/install-generations/:gen/first-boot/exchange` | first-boot bootstrap token | 200 event token |
| `POST /api/v1/nodes/:id/install-generations/:gen/first-boot/events` | generation `event:append` | 204 event CAS |

plan/capsule GET 有界重放相同 bytes；payload 支持严格 Range。handoff/exchange/event body 各 ≤ 16 KiB，不接受 redirect，
所有 URL 只使用配置的 local `server_ip:port`。installer credential 在 handoff 后不能再读取 capsule；bootstrap token 在
started ACK 后 spent；event token只能访问最后一个 events endpoint。

### 8.3 首次启动交换和一次性执行

首次 systemd 启动时 agent：

1. 严格校验磁盘 plan、payload、node/generation/digest；
2. 把 first-boot bootstrap token 读入锁定内存；在新的 event token 安全写盘前保留原 0400 文件，避免 exchange 响应后
   进程崩溃造成两个 token 都丢失；
3. POST exchange，服务端校验 node/generation/plan/expiry 后进入 `exchanging` 并返回短时
   `event:append` token；
4. 响应中断时可在固定 5 分钟窗口内最多重试 3 次；每次成功 exchange 都原子撤销上一 event token，
   任意时刻最多一个有效 token。event token 由 master secret + generation + 持久 exchange counter 确定性派生，
   TTL 为 24 小时，只能追加该 generation 的 first-boot 事件；exchange 不标记 bootstrap claim spent；
5. agent 把 event token atomic write + fsync 到 generation credential path（0400），再 unlink bootstrap token并清零内存。
   agent 使用 event token 成功 POST `first_boot.started` 后，服务端才原子标记 bootstrap claim spent。
   该事件必须带固定 `event_id`/idempotency key：服务端已提交但客户端未收到响应时，使用同一 token 和 event id
   重试必须返回同一已提交事实并保持幂等；不同 event id、不同 generation 或终态后不等同事件一律按
   `first_boot.replay` 拒绝。只有收到成功确认后 agent 才进入后续 step；不能通过重复 exchange 绕过 started ack；
6. 按 managed_file → package → archive → script 固定顺序执行，每步使用 timeout/retry/idempotency key；
7. journal 以 `(node_id, install_generation, bundle_revision, first_boot_plan_digest)` 为边界原子落盘；
8. 全部完成后先 fsync `completed_pending_ack` 和 terminal event body/event id，再发送 succeeded；服务端 ACK 后原子写
   `completed_acknowledged`、删除 event token并 fsync credential directory；
9. 任一步重试预算耗尽同样先写 `failed_pending_ack`，发送 failed 并在 ACK 后写 `failed_acknowledged`、清 token；
   两种 terminal marker 都禁止普通重启再次执行 action；
10. 只有新的 install generation 才生成新 plan/token并重新执行。

`nodeforge-install-firstboot-report.service` 只在 `*_pending_ack` 存在时重送已经固定的 terminal event，不执行 action；使用
同一 event token/event id，收到幂等 ACK 后清理 token。event token 过期仍未 ACK 时写
`first_boot.terminal_delivery_expired`，本地 action 结果保持，但服务端 generation 保持 stale/not-ready，必须由新 install
generation 重新建立可证明闭环；不得把 generation token升级为长期 enrollment。

若进程发现 bootstrap 和 event token 都缺失、journal 又没有 acknowledged terminal，不能猜测成功或重新下载 token；它写
`first_boot.recovery_incomplete` terminal failure。任一 raw token 文件无法 unlink/权限收紧/清零时按 Q 处理，不得 ready。

服务端不可通过 node id/generation 推送任务，也不可续期为长期 credential。事件上报失败时本地 journal 仍是
执行事实，`node postprocess show --phase first-boot --generation` 显示 last known server state并提示可能 stale。

diskless first-boot 继续使用同一 runner，但其一次性边界是 diskless session/plan，运行根是易失 overlay；install
first-boot 不执行 diskless node-apply，也不重新配置网络。

### 8.4 server/local 状态映射

server journal 固定：

```text
not_required
pending_handoff -> handoff_complete -> exchanging -> started -> running
  -> succeeded | failed | expired | recovery_incomplete
```

local journal 固定：

```text
pending -> started -> step_running -> completed_pending_ack -> completed_acknowledged
                          \-> failed_pending_ack -> failed_acknowledged
                          \-> recovery_incomplete
```

server 每次 transition 校验 `(deployment_id,node_id,generation,first_boot_plan_digest,event_seq,event_id,expected_state)`；
local 每次 step transition 校验 step id/order/attempt/idempotency key。server restart 从 hash/claim/counter 恢复，node restart
从 generation directory 恢复；两侧都不得通过“文件存在”或“已收到某个后续事件”跳过中间持久化状态。

## 9. 容量、限流和发布 workload

AppConfig v5 不重复创建已有 owner：HTTP/TFTP 继续使用各自配置，其余共享资源进入 `capacity`。
fresh v0.4 默认值和语义固定为：

| 字段 | 默认值 | 计数对象与 admission point |
|---|---:|---|
| `http.max_connections` | 256 | 已 accept、尚未关闭的全部 HTTP TCP connection；v0.4 将旧 advisory 字段改成真正 hard limit，0 不再表示 unlimited |
| `http.management_reserved_connections` | 8 | 只保留给 loopback management API；node/artifact plane 最多使用 `max_connections-reserved` |
| `tftp.max_concurrent_transfers` | 128 | 已接受但未终态的 RRQ transfer；沿用现有 enforced owner，不新增 `capacity.max_tftp_transfers` |
| `capacity.max_active_boot_sessions` | 64 | install+diskless 非终态 BootSession；在 DHCP 决定下发 bootfile 前占 slot |
| `capacity.max_rootfs_downloads` | 64 | 正在发送 response body 的 rootfs GET/Range；HEAD 不占长期 download slot |
| `capacity.max_builder_uploads` | 4 | 正在处理 builder PATCH body/finalize 的 upload lease |
| `capacity.max_event_requests_per_second` | 200 | 非关键 lifecycle/event/facts telemetry token bucket refill rate |
| `capacity.event_burst` | 400 | telemetry 桶最大瞬时容量；每个 credential 另有 20 requests/s、burst 40 公平性桶 |
| `capacity.max_control_requests_per_second` | 128 | network-proof、token exchange、handoff/finalize 等已接纳流程的关键控制请求；与 telemetry 分桶 |
| `capacity.control_burst` | 256 | control 桶最大瞬时容量；每 credential 10 requests/s、burst 20，按 active authority 公平轮转 |
| `capacity.max_nonterminal_operations` | 128 | queued/running 的 import/build/builder operation；创建 operation 前占 slot |
| `capacity.max_discovery_probe_sessions` | 16 | active discovery initrd probe；与普通 BootSession 分开计数，但仍占 HTTP/TFTP 子资源 |

config validator 必须满足：所有值非零，management reserve < HTTP total，rootfs downloads + builder uploads +
management reserve ≤ HTTP total，active BootSession ≤ session store ceiling，且 active BootSession + discovery probe
上限不大于可用 DHCP lease 容量。
systemd `LimitNOFILE` readiness 下限为
`max(8192, 4 × http.max_connections + 2 × tftp.max_concurrent_transfers + 256)`；
不足时 daemon 启动失败，而不是带着不可兑现的配置运行。

HTTP hard limit 必须在 listener accept/connection lifecycle 层实现，不能用 handler 内“当前请求数”冒充连接数；keep-alive、
请求解析前慢连接和 client disconnect 都必须计数。若现有 Zap/facil.io wrapper 无法提供 accept/close hook，v0.4 必须在
vendor adapter 中补 hook或替换 listener integration，未做到不得声称 `http.max_connections` 已强制。management reserve
按 accept 时可信 peer address 判断：loopback 可使用全部连接预算，非 loopback 最多使用
`max_connections-management_reserved_connections`；reserve 是管理面保底而非管理面上限。

control 与 telemetry 必须分桶，避免 event/facts 洪峰耗尽 network proof、first-boot exchange 或 finalize，迫使已接纳流程
自我回滚。control 达上限仍按 429 有界重试，不能跳过 proof；公平桶保证一个异常 credential 不能占满全部 control budget。

达到上限时行为固定：

| 资源 | 拒绝行为 |
|---|---|
| HTTP connection/node-plane reserve | 尽可能返回 503 `capacity.http_connections_exceeded` + `Retry-After: 2`；无法解析请求前关闭连接也必须计数/打点 |
| rootfs download | 在发送任何 body 前返回 503 `capacity.rootfs_downloads_exceeded` + `Retry-After`；客户端按原 Range offset 重试 |
| TFTP transfer | 返回 TFTP ERROR `server busy, retry later`，不创建 transfer thread |
| BootSession | 保留诊断 DHCP lease但不下发 bootfile，记录 `capacity.boot_sessions_exceeded`；下一次 DHCP transaction 可重试 |
| builder upload | 503 `capacity.builder_uploads_exceeded`；已持久化 upload offset/lease 不丢失 |
| event/facts telemetry | 429 `rate_limit.exceeded` + `Retry-After: 1`；不推进 event sequence、不写半条 journal |
| proof/exchange/handoff/finalize control | 429 `rate_limit.control_exceeded` + `Retry-After: 1`；保留 authority/CAS，不降级成功，客户端在各阶段 deadline 内重试 |
| operation | 429 `capacity.operations_exceeded`；不创建 operation、attempt、token 或 staging 目录 |
| discovery probe | 只记录 passive DHCP observation，不下发 discovery bootfile |

所有 slot 必须通过 defer/finalizer 在成功、错误、client disconnect、timeout、cancel 和 daemon shutdown 路径释放。
restart 后计数恢复按资源事实区分：BootSession、nonterminal operation、active discovery probe 等 authority 从持久 state
重建；HTTP connection、TFTP transfer、rootfs response body 和当前 PATCH/finalize 等进程内 live I/O 归零，持久 upload lease/
offset 保留但不占 live upload slot，直到新 request 再次 admission。不能把全部计数一律归零，也不能把无 socket 的 lease
误算成活跃传输。`status` 和 metrics 至少输出
`current/limit/rejected_total`，并按资源区分。测试 workload 参数不是产品 desired state，不写入 catalog。

v0.4 最低发布基准使用版本化 manifest，参考主机为 8 CPU、16 GiB RAM、NVMe、1 GbE：

| 维度 | 最低 workload |
|---|---:|
| registered Nodes | 256 |
| 同时活跃 BootSession | 64 |
| 同时 rootfs HTTP download | 32 |
| rootfs 大小 | 2 GiB |
| Range 中断并恢复比例 | 10% |
| event 输入 | 100 requests/s，持续 30 分钟 |
| builder upload | 2 个并发、每个 2 GiB |
| discovery | 256 个 SN+IP draft Node，8 个并发 active probe，含 25% unmatched/conflict 注入 |
| soak | 24 小时，周期性 boot/download/cancel/failure injection |

管理 API（不含大文件传输本身）在上述 workload 下要求 p95 ≤ 200 ms、p99 ≤ 500 ms；BootConfig/AgentPlan
获取 p95 ≤ 300 ms、p99 ≤ 1 s；不允许错误 session 关联、损坏 artifact、重复发布或 token 越权。24 小时后
RSS/FD/临时文件必须回到稳定窗口，静止 10 分钟后的增长不超过 warm-up 基线 5%。

每次发布必须保存 manifest、硬件/OS/commit、原始 latency/CPU/RSS/FD/disk 指标、失败注入记录和结果摘要。
没有原始证据不得声明“生产级”或“长期稳定”。

## 10. Discovery：预建 Node 后按 SN 自动补齐 PXE 身份

### 10.1 用户流程与设计裁决

v0.4 的 discovery 只实现下面这一条闭环：

```text
预建 draft Node（Node id + SN + 预留 IP）
    -> 启动这个 Node 的 discovery
    -> 未知机器 PXE 进入最小 discovery initrd
    -> initrd 上报 product serial
    -> 服务端按 SN 唯一匹配 pending Node
    -> 原子回填 PXE MAC + arch
    -> Node 仍为 deploy=false，由操作员继续绑定 Profile 并显式部署
```

扫码枪只负责把 SN 输入 `node add` 或 `node set`，NodeForge 不增加扫描批次或资产认领领域对象。当前 passive
DHCP observation 保留，用于查看未知 MAC；active discovery 只是为已预建的 draft Node 补齐 firmware 在 DHCP
阶段不会提供的 SN/MAC 关联。

### 10.2 draft Node 数据约束

Catalog v6 的 Node 新增 `hardware.serial_number`，并允许以下受限 draft shape：

```text
id                        required
hardware.serial_number    required, site-wide unique after canonicalization
pxe.ip_reservation        required IPv4
mac                       null until discovery matched
arch                      null until discovery matched
profile                   null
deploy                    false
```

只有同时满足 `profile=null`、`deploy=false` 且存在有效 `hardware.serial_number` 的 Node 才允许
`mac/arch=null`。这种 Node 不能进入普通 install/diskless resolver、不能创建 BootSession，也不能绕过 readiness。
`pxe.ip_reservation` 在 MAC 未知时只保存 desired address，DHCP allocator 不使用它；匹配回填 MAC 后，机器下一次
PXE 才获得该 reservation。首次 discovery 启动必须使用 discovery pool 的临时动态 lease，因为 DHCP 请求中还没有
可用于查找这个 reservation 的 SN。

SN 规范化只做首尾 whitespace/NUL 清理、控制字符拒绝和 ASCII 大写；保留标点、内部空格与前导零。
空值、全 0/全 F、`To Be Filled By O.E.M.`、`Default string` 等 placeholder 拒绝。canonical SN 在全部
draft/matched Node 中唯一，因而服务端匹配结果只能是零或一个 Node。

### 10.3 每个 Node 的 discovery 状态

daemon 为每个启动 discovery 的 Node 保存一个短期 `NodeDiscoveryState v1`：

```text
node_id / node_revision
expected_serial_sha256 / serial_display
created_at / expires_at
state = pending | matched | failed | expired | cancelled
matched_probe_session_id?
observed_mac? / observed_arch?
last_error?
```

`node discovery start <node>` 是唯一 arm 操作：默认 30 分钟，可同时有多个 pending Node。

- start 要求站点 `unknown_action=record`；`deny` 策略下明确拒绝启动，而不是显示 pending 却永远不发 discovery bootfile；
- pending Node 数量只是 catalog/runtime metadata，不占 active probe slot；未知 MAC 真正取得 discovery bootfile 时才占
  `capacity.max_discovery_probe_sessions`；
- 重复 start 在状态仍 pending 时幂等；terminal 状态必须显式再次 start 才开始新的等待周期；
- Node 的 SN、reservation 或 revision 在等待期间变化会取消旧状态，避免把旧观察写入新 desired state。

收到 SN 前服务端无法知道未知 MAC 对应哪个 Node，所以 Node 状态不包含 `probing`。`probing` 和当前 session 只显示在
按 MAC 保存的 observation 中；SN 唯一匹配成功后，session id 才记录为目标 Node 的
`matched_probe_session_id`。

原始发现信息继续按 PXE MAC 保存为 `DiscoveryObservation`，在现有 DHCP 字段上增加
`product_serial/observed_arch/evidence/matched_node_id/state/reason/last_seen`。它只是诊断记录，不是待 claim 资产；
正常成功结果的权威归属是 Node 本身。

### 10.4 自动匹配与回填事务

resolver 优先级固定为：

1. 已注册 MAC：按现有 builder/普通 deploy gate 处理；
2. unknown 且 `unknown_action=deny`：拒绝；
3. unknown、至少一个 Node discovery pending 且 discovery capacity 可用：下发现有 initrd 的 discovery mode；
4. 其他 unknown：保持现有 passive record，只给诊断 lease且不发 bootfile。

第 3 步 admission 原子创建按 PXE MAC/arch/临时 lease 绑定的 `DiscoveryProbeSession v1`，只保存 session id、
expiry、状态、token hash/claim 和事实摘要；它不是 Node BootSession。GRUB 加载与普通 diskless 相同的已发布 kernel/initrd，
另加载一个 0400 小型 capability capsule；cmdline 不携带 raw token。由于 DHCP 请求不含 SN，start 某个 Node 后无法在
发 bootfile 前判断未知 MAC 是否就是它：无关机器可能进入 discovery mode，但 SN 零匹配时只产生 unmatched observation，
绝不会修改任何 Node。

v0.4 不新增第二个 initrd 产品或 rootfs 形态，而是让现有发布的 kernel + `nodeforge-initrd` 镜像增加受限
`discovery` 启动模式。该模式只配置临时 DHCP lease，复用现有 DMI 采集代码读取
`/sys/class/dmi/id/product_serial`，连同 PXE MAC 和 DHCP option 93 解析出的 arch 上报短期 session-bound endpoint，
然后清除 token 并关机。它不拉取普通 BootConfig、AgentPlan、rootfs 或 provision payload，不执行
`switch_root`，不挂载/写入 block device，也不提供 shell、SSH 或远程任务入口。

服务端校验 token/session/MAC/arch/source lease/body 后，按 canonical product serial 查询 pending Node：

- **唯一匹配**：在一个 catalog + discovery state 事务中校验 Node revision，写入 `Node.mac` 和 `Node.arch`，
  observation 标记 `matched`，Node discovery 标记 `matched`；
- **零匹配**：不修改任何 Node，observation 标记 `unmatched`；
- **MAC 已属于其他 Node、SN 与既有绑定冲突、revision 变化或字段非法**：不修改任何 Node，记录稳定失败原因。

上报接口固定为 `POST /api/v1/discovery/probes/:session_id/facts`，body schema v1 上限 16 KiB，只接受
`product_serial,product_uuid?,vendor?,model?,pxe_mac,observed_arch,lease_ip,facts_sha256`；token audience 为
`discovery-facts:append`，claim 绑定 deployment/session/MAC/arch/lease/method/path/body digest/expiry。相同 facts digest
幂等返回同一结果，body 漂移或第二个 terminal report 返回 `discovery.probe_replay`。

MAC/arch 回填不是“先改 catalog、再尽力写状态”的两个写操作。daemon 必须在
`state/model-transactions/discovery-<session>.json` 准备 catalog v6 snapshot、NodeDiscoveryState 和
DiscoveryObservation 三个 after-image及其 before digest，fsync journal 后按 transaction coordinator 发布；restart 必须完成
或回滚整个事务。任何中断都只能得到“Node 未变 + probe 可重试”或“三处全部 matched”，不能出现 Node 已有 MAC 但状态仍
pending/unmatched。

成功回填后 Node 仍然 `profile=null, deploy=false`。SN 只是匹配线索，不是认证凭据；系统绝不因为 discovery 成功
自动绑定 Profile、打开 deploy gate、安装系统或进入 diskless。操作员完成配置并显式 `node deploy true` 后，下一次
PXE 才进入普通路径并使用预留 IP。

### 10.5 查询、创建和后续赋值 CLI

最短操作路径：

```text
nodeforge node add node-001 hardware.serial_number=ABC123 pxe.ip_reservation=192.168.10.51
nodeforge node discovery start node-001 --expires-in 30m

nodeforge node list
nodeforge node show node-001
nodeforge discovery list
nodeforge discovery show <pxe-mac>

nodeforge node set node-001 profile=<profile>
nodeforge node deploy node-001 true
```

这个 v0.4 `node add` shape 在缺省 `profile/mac/arch` 时自动固定 `profile=null, deploy=false`；不要求用户再写
第三个硬件字段或显式 `deploy=false`。

`node list` 是日常资产视图，v0.4 至少显示
`ID / SN / MAC / ARCH / PXE_IP / DISCOVERY / PROFILE / DEPLOY`；尚未匹配的 MAC/ARCH 显示 `-`，
`DISCOVERY` 显示 `inactive|pending|matched|failed|expired`。可用
`--discovery-state <state>` 过滤。

`node show <id>` 是单节点权威详情。v0.4 必须支持 `profile=null` 的 draft Node，不得沿用当前
`node.profile_unassigned` 直接失败；此时 Effective 分区显示 `unavailable: profile_unassigned`，其余分区正常显示：

- Desired：SN、预留 IP、Profile、deploy；
- Learned identity：PXE MAC、arch、最近 hardware facts；
- Discovery runtime：state、expiry、matched probe session、matched time 或稳定失败原因。

`discovery list` 只用于排障原始观察，显示
`PXE_MAC / SN / ARCH / TEMP_IP / EVIDENCE / MATCHED_NODE / STATE / REASON / LAST_SEEN`；
`discovery show <pxe-mac>` 查看该 MAC 的 DHCP 与 initrd 上报细节。v0.4 删除旧的
`node claim <id> discovery.mac=... arch=...` 发现认领入口；SN 唯一匹配事务本身就是“赋值 Node”。
未匹配时操作员修正 draft Node 的 SN 后重新
`node discovery start <node>`，不提供绕过 SN 校验的普通人工 bind 命令。

辅助命令固定为：

```text
nodeforge node discovery status <node>
nodeforge node discovery cancel <node>
```

### 10.6 retention、安全与验收

- pending 到自身 expiry；terminal Node discovery state 保留最近一次摘要，新的 start 覆盖前先写审计事件；
- passive/unmatched/failed observation 按现有 discovery retention 清理；已匹配原始记录可压缩，Node learned identity
  和审计事件保留权威结果；
- token 绑定 session/MAC/arch/lease/method/path/audience/expiry，raw token 不进 cmdline、catalog 或日志；
- probe token 按 §0 决策 9 确定性派生；daemon restart 重放同一个 capsule，只有 master secret/hash/claim 不匹配才标
  `discovery.recovery_incomplete`，不能为同一 probe 签发第二 token；
- 同一 MAC DHCP 重传、同一 facts digest 重放幂等；跨 MAC/session、过期、body 漂移全部拒绝；
- 同一个发布 initrd 的 discovery mode 有内容/路径审计和 block-device 零写入测试；
- 至少覆盖：单 Node 自动匹配、多 pending Node 按 SN 匹配、SN 不匹配、placeholder、重复 SN 建 Node 被拒、
  MAC 已占用、expiry/cancel/restart、capacity 拒绝、Node revision race；
- E2E 必须证明：
  `add(SN+IP) -> start -> 临时 lease/probe -> 自动回填 MAC/arch -> node list/show 可见 -> 下一次 PXE 使用 reservation`；
- 成功匹配后仍必须证明 `deploy=false`，未知机器和错误 SN 不能获得普通 install/diskless delivery。

## 11. CLI

### 11.1 topology

BOND 不新增一套旁路命令，继续使用 registry 驱动的 `node item` grammar；这样 CLI、API、validator、show 和
AgentPlan 使用同一 canonical 字段。v0.4 必须补齐以下操作：

```text
nodeforge node item list <node> network.bonds
nodeforge node item show <node> network.bonds <bond-id>
nodeforge node item add <node> network.bonds FIELD=VALUE...
nodeforge node item set <node> network.bonds <bond-id> FIELD=VALUE...
nodeforge node item replace-values <node> network.bonds <bond-id> members <interface-id>...
nodeforge node item remove <node> network.bonds <bond-id>
nodeforge node replace-items <node> network.bonds --from-file <json> --if-revision <revision>
```

所有 mutation 支持 `--if-revision <node-revision>` CAS；revision 不匹配时返回冲突且零修改。`id` 和 `mode` 创建后不可由
`item set` 修改：切换 active-backup/802.3ad 必须用 `replace-items --from-file` 在一个 catalog transaction 中提交完整
bond collection，防止旧 mode 的 `primary_id` 与新 mode 的 LACP 字段形成半合法对象。被 VLAN/route 引用的 bond
不能 remove；先在同一 `replace-items` transaction 中改引用，或明确拆分为 deploy=false 下的多个结构合法步骤。

BOND 创建参数规划如下；命令行形式均为 `KEY=VALUE`，`members` 是可重复参数：

| CLI 参数 | 必填/默认 | 适用 mode | 中文 help 必须说明 |
|---|---|---|---|
| `id=<name>` | 必填 | 全部 | 目标 bond 名称，Linux link name，Node 内所有 interface/bond/VLAN 全局唯一 |
| `mode=active-backup\|802.3ad` | 必填 | 全部 | 主备或 LACP 聚合；创建后不可局部修改 |
| `members=<interface-id>` | 至少重复 2 次 | 全部 | 引用已存在 physical interface；每个 member 的 `ipv4.mode` 必须为 none，且不能属于其他 bond |
| `mac_source_id=<interface-id>` | 必填 | 全部 | 以哪个 member 的永久 MAC 作为 bond 逻辑 MAC；建议选 PXE bootstrap NIC，不改变 PXE MAC 身份 |
| `miimon_ms=<50..1000>` | 默认 100 | 全部 | 链路监测周期，单位毫秒 |
| `up_delay_ms=<n>` | 默认 0 | 全部 | carrier 恢复后等待多久才启用，必须是 miimon 的整数倍；映射 kernel updelay |
| `down_delay_ms=<n>` | 默认 0 | 全部 | carrier 丢失后等待多久才判定失败，必须是 miimon 的整数倍 |
| `mtu=<576..9216>` | 省略则 adapter 默认 | 全部 | bond MTU，不得大于任一 member 可配置 MTU |
| `primary_id=<interface-id>` | 必填 | active-backup | 首选主口，必须属于 members；802.3ad 禁止 |
| `primary_reselect=always\|better\|failure` | 默认 failure | active-backup | 主口恢复后何时抢回；failure 表示仅当前 active 失败时切回 |
| `lacp_rate=slow\|fast` | 默认 fast | 802.3ad | 主机请求的 LACPDU 周期；不能代替交换机 LAG 配置 |
| `xmit_hash_policy=layer2\|layer2+3\|layer3+4` | 默认 layer2+3 | 802.3ad | 出方向流量散列策略；改变单流路径分布，不提供单流带宽叠加保证 |
| `min_links=<1..member-count>` | 默认 1 | 802.3ad | 至少多少成员 collecting/distributing 才允许 network proof |
| `ipv4.mode=none\|dhcp\|static` | 必填 | 全部 | bond 是否直接承载 L3；VLAN-on-bond 时通常设 none |
| `ipv4.address=<IPv4>` | static 必填 | 全部 | 目标静态地址，不是 PXE reservation |
| `ipv4.prefix_len=<1..32>` | static 必填 | 全部 | 静态地址前缀长度 |
| `ipv4.default_route=true\|false` | DHCP 默认 true | 全部 | 是否接受该 DHCP link 作为目标默认路由；static 默认路由使用 network.routes |

参数解析必须拒绝未知 key、同一 scalar 重复、mode 专属参数混用、members 少于两个、`mac_source_id/primary_id`
不在 members、delay 非 miimon 整数倍、min_links 越界以及 bond/member 同时配置 L3。错误输出必须打印 bond id、字段、
收到值、合法范围和修复建议；不得只返回 `invalid argument`。

```text
# 1. 先登记物理口；作为 bond member 时不在物理口配置目标 L3。
nodeforge node item add <node> network.interfaces id=eth0 mac=<mac> ipv4.mode=none
nodeforge node item add <node> network.interfaces id=eth1 mac=<mac> ipv4.mode=none

# 2. 802.3ad：交换机侧必须已把 eth0/eth1 对应端口加入同一 LACP LAG。
# bond0 只作为 VLAN parent，因此 ipv4.mode=none。
nodeforge node item add <node> network.bonds id=bond0 mode=802.3ad members=eth0 members=eth1 \
  mac_source_id=eth0 miimon_ms=100 lacp_rate=fast xmit_hash_policy=layer2+3 min_links=1 ipv4.mode=none

# 3. 目标 L3 放在 VLAN 100；交换机 LAG 必须允许 tagged VLAN 100。
nodeforge node item add <node> network.vlans id=vlan100 parent_id=bond0 vlan_id=100 \
  ipv4.mode=static ipv4.address=192.168.100.10 ipv4.prefix_len=24
nodeforge node item add <node> network.routes id=default destination=0.0.0.0/0 \
  gateway=192.168.100.1 interface_id=vlan100
nodeforge node replace-values <node> network.dns 192.168.100.53
```

active-backup 的等价 bond 创建示例：

```text
# active-backup：交换机端口保持普通独立端口，处于相同 L2/VLAN，不配置 LACP。
# eth0 是 PXE bootstrap NIC，同时作为 preferred primary 和 bond MAC 来源。
nodeforge node item add <node> network.bonds id=bond0 mode=active-backup members=eth0 members=eth1 mac_source_id=eth0 \
  primary_id=eth0 primary_reselect=failure miimon_ms=100 up_delay_ms=200 down_delay_ms=200 \
  ipv4.mode=dhcp ipv4.default_route=true
```

既有 bond 的安全修改示例：

```text
# 只修改 active-backup 专属标量；revision 用于防止覆盖其他操作员的并发修改。
nodeforge node item set <node> network.bonds bond0 primary_reselect=better \
  --if-revision <node-revision>

# 成员列表必须整组替换，不提供 add-one/remove-one 造成瞬时单成员 bond 的语法。
nodeforge node item replace-values <node> network.bonds bond0 members eth0 eth2 \
  --if-revision <node-revision>

# 删除前必须确认没有 VLAN/route 引用；有引用时命令零修改并给出引用 id。
nodeforge node item remove <node> network.bonds bond0 --if-revision <node-revision>
```

从 active-backup 切到 802.3ad 不是纯软件参数修改，操作顺序固定为：先 `node deploy false` 阻止新 boot，完成交换机
LACP LAG/VLAN/MTU 配置，再把完整新 collection 写入纯 JSON 文件一次替换，随后执行 readiness/preview，最后才重新
`node deploy true`。不能先打开 802.3ad deploy gate 再等待交换机配置。

```json
[
  {
    "id": "bond0",
    "mode": "802.3ad",
    "members": ["eth0", "eth1"],
    "mac_source_id": "eth0",
    "miimon_ms": 100,
    "up_delay_ms": 0,
    "down_delay_ms": 0,
    "lacp_rate": "fast",
    "xmit_hash_policy": "layer2+3",
    "min_links": 1,
    "ipv4": {"mode": "dhcp", "default_route": true}
  }
]
```

```text
# JSON 不允许注释；交换机前置条件由 --help-full、readiness warning 和变更单记录。
nodeforge node replace-items <node> network.bonds --from-file bonds.json \
  --if-revision <node-revision>
nodeforge node readiness <node>
nodeforge node boot preview <node>
nodeforge node deploy <node> true
```

v0.4 registry 对 `item add` 的 item-scoped required collection 支持重复 `field=value`，上例两个 `members=` 与
bond item 在同一 catalog transaction 创建，validator 只观察最终对象。不能先创建 members 为空的无效 bond 再补值；
既有 bond 的成员变更使用 `node item replace-values <node> network.bonds bond0 members ... --if-revision <revision>`
原子替换。修改后必须执行 `node readiness` 和 `node boot preview`；外部交换机条件无法静态证明时，两者主动打印中文
WARNING，但运行时 carrier/aggregator/network proof 仍是硬闸。

不存在 `network.bootstrap.*` 命令。PXE 稳定地址继续使用：

```text
nodeforge node set <node> pxe.ip_reservation=192.168.50.101
```

### 11.2 builder

```text
nodeforge profile set <profile> builder.placement=node
nodeforge node set <builder-node> deploy=false builder.eligible=true builder.abi=nodeforge-builder-v1
nodeforge node replace-values <builder-node> builder.capability_classes <class> [...]
nodeforge profile rootfs plan <profile>
nodeforge profile rootfs build <profile> [--builder-node <node>] [--detach] \
  [--if-input-digest <digest>] [--if-revision <profile-revision>]
nodeforge operation show <operation>
nodeforge operation follow <operation>
```

`rootfs plan` 必须显示 placement、required capability class/ABI、input digest、cache hit 状态和匹配 eligible
Node；build 输出显示实际 builder Node 和 “waiting for next PXE”。

### 11.3 first-boot 和观测

```text
nodeforge node postprocess show <node> --phase first-boot [--generation <id>]
nodeforge node readiness <node>
nodeforge node boot preview <node>
nodeforge status
nodeforge events
```

preview 只显示 DHCP/UEFI bootstrap、topology、feature、builder attempt 或 first-boot 摘要，不创建 session、
operation、token 或 capsule，也不输出 raw secret。

### 11.4 `setup` help 契约

`nodeforge setup --help-full` 必须直接解释保留/删除范围，不能只写“reset startup config and runtime state”：

| flag | help 必须表达的行为 |
|---|---|
| `--reset-state` | daemon 停止后备份并清空 runtime state；保留 startup config、catalog、assets、work、logs、既有 backup 和当前 deployment id |
| `--reset-all` | 包含 reset-state，另备份并重新生成 startup config；默认仍保留 catalog/assets/work/logs/backups 和当前 deployment id，因此不等于 fresh replacement |
| `--purge-data` | 仅与 reset-all 同用；删除 catalog 和 assets，保留 work/logs/backups |
| `--purge-all` | 仅与 reset-all 同用；删除 catalog、assets、work、logs、backup 和 migration history，生成新 deployment id/v2 marker；不可恢复，是跨 schema fresh replacement 的唯一原地入口 |
| `--reconfigure` | 可在 reset-all 后运行；校验 fresh config/空 catalog并重新发布 systemd unit，不调用 `systemctl start/restart` |
| `--yes` | destructive operation 的显式确认；non-interactive 时必填 |
| `--dry-run` | 输出将备份、保留、删除、重建的绝对路径，是否生成新 deployment id，以及 daemon-stopped 前置检查；零写入 |

help 必须给出两条完整示例：

```text
# 仅清 runtime，保留配置和数据
nodeforge setup --reset-state --yes

# v0.4 fresh replacement：旧数据和备份全部删除，生成新 deployment id
nodeforge setup --reset-all --purge-all --reconfigure --yes
```

参数冲突也必须出现在 help 而非只在运行时报错：`purge-data|purge-all` requires `reset-all`；两者互斥；只有
`reset-all + reconfigure` 可以组合两个主 operation；daemon 可达时所有 reset/purge fail closed。

跨版本 fresh replacement 有一个严格受限的 bootstrap exception：v0.4 CLI 仅在
`setup --reset-all --purge-all [--reconfigure]`/对应 `--dry-run` 中可以识别 legacy `nodeforge-root-v1` marker，以证明待删
目录确实是 NodeForge install root；它不得加载或 parse legacy AppConfig/catalog/state，也不得把 v5 parser 加回正常代码。
purge preflight 只做 canonical realpath、marker、成对二进制、daemon stopped、权限/空间和固定 allowlist 检查，随后按路径
删除旧数据并创建全新 v2 layout。其他命令、`reset-state`、不带 purge 的 `reset-all` 和 daemon 对 v1 marker 一律
`deployment.layout_incompatible`。这样 fresh purge 可执行，同时不形成任何旧 schema 兼容读取路径。

## 12. 失败分级、主动告警与回滚总策略

v0.4 不允许用一条笼统的“失败即退出”处理所有错误，也不允许为了主流程表面成功把关键失败降级成日志。
每个 handler/state transition 必须在设计和代码中标注以下固定等级之一：

| 等级 | 语义 | 对当前主流程的影响 | 处理 |
|---|---|---|---|
| W：warning | 无法静态证明的外部条件、非权威观测或可延后清理失败 | 主流程可继续，exit 0 | 立即主动打印 warning，写 structured warning/event/metric；不能只写 debug log |
| R：reject | 新请求在任何 authority/持久副作用创建前不满足参数、CAS、readiness 或容量条件 | 拒绝本次请求；既有 session/artifact/Node 不受影响 | 返回稳定错误码和修复建议；可重试项带 Retry-After |
| F：fail-current | 当前 session/operation/generation 在不可见候选阶段失败，尚未发布权威结果 | 当前流程失败；既有 ready 结果保持 | candidate 终止/隔离，释放 slot/token，不需要回滚既有结果 |
| B：rollback | 已修改当前 boot 的临时网络或 staging 状态，但仍在可逆边界内 | 当前流程失败 | 按预写快照逆序补偿；rollback 成功后退出，禁止继续 first-boot/publish |
| Q：quarantine | 已越过不可逆边界，或 rollback 自身失败，不能安全声称恢复 | 当前流程终止并需人工处理/新 generation/重启 | 保留诊断和仍可用管理通道，标记 terminal/quarantined，不自动破坏性重试 |
| D：daemon-fatal | deployment/config/state 无法形成可信全局基线 | 所有新主流程停止 | daemon 启动失败或进入只读诊断；不能带病提供 PXE/写 API |

### 12.1 什么可以 warning，什么绝不能 warning

只有满足“失败不会改变 desired、不会降低鉴权/完整性、不会让系统误报成功、后续仍有权威事实源”四个条件时才能使用 W：

- BOND 交换机前置条件无法由 NodeForge 静态证明：`readiness/boot preview` 中文 WARNING；运行时 carrier、aggregator 和
  network proof 仍必须通过；
- 非关键 inventory/facts、metrics 或终态事件暂时无法送达：本地 journal/state 是权威，输出
  `telemetry.delivery_deferred` 并重试；server 视图明确标记 stale；
- 不含 secret、未被引用且不影响容量安全的 terminal 临时文件清理失败：记录 cleanup debt、路径、重试时间和
  `cleanup.deferred`，后台有界重试；
- discovery SN 未匹配：只形成 unmatched observation并在 `discovery list` 主动显示，不修改任何 Node，也不影响已注册
  Node 的普通 PXE。

以下失败绝不能降级为 warning：schema/身份/CAS 冲突、token/claim、digest/size、rootfs/payload、目标 renderer、
network proof、BOND carrier/aggregator、rollback、secret 删除、artifact publish、first-boot required step 和任何会打开
`deploy/ready/succeeded` gate 的条件。

主动输出契约固定为：

- human CLI：warning 写 stderr，格式 `WARNING [stable.code] 中文摘要；影响；下一步`，成功结果仍写 stdout；
- `--json`：顶层必须有 `warnings[] {code,message_zh,impact,next_action,resource_id}`，不得只把 warning 拼进字符串；
- operation/session：warning 进入有序 event/journal，`show/status` 显示未确认 warning 数；
- daemon：warning/error 同时有结构化 log 和 counter；相同 resource/code 可限频，但首次和状态变化必须打印；
- warning 不改变 exit code；R/F/B/Q/D 使用既有 2–6 exit class，CLI 必须打印 resource、阶段、是否已回滚以及可否重试。

### 12.2 全域失败处理矩阵

| 领域/阶段 | 典型失败 | 等级 | 对既有主流程的影响 | 固定处理 |
|---|---|---|---|---|
| daemon startup | deployment id/schema 不匹配、全局 state 损坏、容量配置不可兑现 | D | 所有新请求停止 | 启动失败；只打印诊断和 fresh setup 指引，不部分加载 |
| setup preflight | daemon 未停、参数冲突、路径越界、权限/空间不足 | R | 当前 deployment 不变 | 删除前完成全部可检查项，零写入退出 |
| setup purge 已开始 | 删除后生成 config/manifest/unit 失败 | Q | 旧 deployment 已不可恢复 | 写 `.nodeforge-replacement-incomplete`；不得伪造 rollback，修复原因后重跑同一 fresh setup |
| catalog/topology mutation | 字段、引用、mode、MTU、route、CAS 非法 | R | Node revision 零变化 | 单 transaction validator 拒绝，输出字段级中文修复建议 |
| BOND 外部交换机条件 | 静态阶段无法确认 LAG/VLAN/security binding | W | readiness 可继续到 runtime gate | readiness/preview 主动警告；运行时失败按 diskless preflight 或 transition 所在行处理，不得跳过硬闸 |
| install render/readiness | adapter 不支持、目标 topology 无法渲染、feature 缺失 | R | 不创建 install generation | generation/session/answer file 创建前完成编译，失败零 authority、零目标盘写入 |
| diskless fetch/preflight | plan/token/digest/payload/bootstrap mismatch | F | 当前 boot 失败；网络尚未切换 | 清 token/partial，保留 bootstrap，终止 boot |
| diskless transition/proof | bond/VLAN/DHCP/static/route/proof、renderer 发布或 `exec init` 失败 | B | 当前 boot 失败 | pre-init 仍可逆时按快照逆序 rollback；恢复 bootstrap 并再次 proof 后报告 `network.transition_failed`，无法恢复则升级 Q/`network.rollback_failed` |
| diskless rollback | master/MTU/MAC/IP/route 任一步无法恢复 | Q | 当前 boot 不可信 | 报 `network.rollback_failed`，保留可用链路与完整快照，禁止 init/first-boot，进入 quarantine |
| init adopt | NetworkManager/Netplan 接管后 topology 或第二次 proof 不符 | Q | OS 已进入真正 init，但配置主流程停止 | 保留 bootstrap anchor，禁止 first-boot，报 `network.adopt_failed`；重启从 fresh PXE 重试 |
| builder admission | builder environment 未 ready、无 eligible Node、boot slot/CAS/capacity 冲突 | R | 已有 ready artifact 不变 | 不创建 attempt/token/staging；可重试时给条件和 Retry-After |
| builder build/upload/validate | step、Range、size/hash、squashfs deep validation失败 | F | 当前 operation 失败；旧 ready artifact 继续服务 | candidate 不发布，清 token/slot；有界保留诊断后清 `.part` |
| builder reproducibility | 同 input digest 得到不同 content digest | Q | 旧 artifact 继续服务，新 candidate 禁用 | 隔离两份 provenance，报 `builder.non_reproducible`，禁止自动覆盖 |
| artifact publish before index | staging fsync、object rename 前失败 | F | candidate 不可见；旧 artifact 不变 | 不产生 ready index，清理或保留诊断 candidate |
| artifact publish uncertainty | object rename 后 index transaction 结果不确定 | Q | 不能判断新对象是否权威，旧 artifact 仍不得覆盖 | 禁止服务新 digest，隔离 object/index并启动一致性审计 |
| install first-boot handoff | agent/plan/payload/token 未完整写盘 | F | 本次 install generation 失败 | 安装器不得报告 NodeForge handoff success；创建新 generation 重试 |
| install first-boot exchange/required step | token exchange 或 action 重试耗尽 | Q | 已安装 OS 保留，但 NodeForge 配置未完成 | 写 terminal failed marker，普通重启不重跑；禁止 ready，需新 install generation |
| first-boot terminal event | 本地 terminal journal 已 fsync，但成功事件暂时未送达 | W | 本地完成事实不回滚 | 主动提示 server state stale，有界重送；不能重复执行 action |
| capacity admission | HTTP/TFTP/session/download/upload/event/operation/probe 达上限 | R | 已接纳工作不取消 | 在创建新 authority 前拒绝，带 Retry-After/counter；释放后可重试 |
| pre-transition retry exhausted | rootfs Range、payload/event fetch 连续被限流/中断且超过预算 | F | 仅当前 boot/operation 失败，网络未修改 | 清 partial/token，保留 bootstrap并终止当前流程 |
| network proof retry exhausted | 已修改目标网络后 proof 连续被限流/中断且超过预算 | B | 当前 boot 失败 | 按网络快照 rollback；proof endpoint 不能因容量不足被降级跳过 |
| discovery unmatched | probe 上报合法 SN，但没有 pending Node | W | 普通 PXE 和全部 Node 不受影响 | observation 标 unmatched并主动显示，不修改 Node |
| discovery probe failure | SN/MAC 冲突、expiry、revision race、capsule recovery incomplete | F | 仅当前 probe session 失败 | 零 Node mutation，session 终止并释放 slot；目标 draft Node 保持原状态或记录失败原因 |
| ordinary cleanup/metrics | 非 secret terminal cleanup 或 metrics sink 暂时失败 | W | 权威结果不变 | 记录 debt并有界重试；超过磁盘/FD 安全阈值后，新 admission 统一按 R 拒绝直到恢复 |
| auth/claim validation | claim/replay/binding 异常 | F | 当前请求/session 不可信但尚未成功 | 拒绝并撤销相关 token/session，禁止继续或成功 |
| raw secret cleanup | 已读取/使用的 raw token 无法 unlink/清零 | Q | secret 生命周期无法证明结束 | 禁止成功终态，隔离当前 session/generation并主动打印安全错误 |

### 12.3 rollback 实现契约

所有标为 B 的流程必须满足：

1. **先快照后修改**：在第一条 netlink/filesystem mutation 前持久化或在 session journal 中 fsync 可恢复快照；
2. **只补偿本次变化**：记录 created/changed/pre-existing，禁止 rollback 删除启动前已有对象；
3. **严格逆序**：target route/address → VLAN → slave relationship → bond → target-to-current rename → physical master/MTU/MAC/address/route；
4. **幂等**：每个 compensation 重复执行结果相同；daemon/agent restart 能从最后完成 step 继续 rollback；
5. **有界超时**：每步 timeout 和总 rollback deadline 固定，超时升级 Q，不能无限卡住 boot slot；
6. **验证恢复**：rollback 后重新检查 bootstrap link/address/route，并执行 server proof；只执行命令不算恢复成功；
7. **清晰终态**：成功写 `rolled_back=true` 和失败原因为 F/B；失败写 `rollback_failed_at`、残留对象和人工建议；
8. **不自动破坏性重试**：Q 状态不得自动再次切网、覆盖 artifact 或重跑 first-boot；需要重启、新 generation 或显式 retry。

Catalog mutation 使用内存 copy + 全量 structural validator + atomic replace，不暴露半对象；artifact 使用 staging + fsync +
atomic rename/index transaction，旧 ready artifact 在新对象完整发布前永不删除。这两类失败依靠不可见候选和原子发布，
通常属于 R/F，不伪装成运行时 rollback。

## 13. 稳定诊断码

至少冻结以下 v0.4 error code：

| code | 含义 |
|---|---|
| `deployment.layout_incompatible` | deployment manifest/schema/id 缺失或与 fresh v0.4 layout 不匹配 |
| `dto.too_large` | BootConfig/AgentPlan/BuilderPlan/InstallFirstBootPlan 超过 §2.2 固定上限 |
| `network.topology_invalid` | topology 引用、L3、default route、地址或 MTU 规则失败 |
| `network.bond_mode_change_requires_replace` | 已有 bond 的 mode 不允许局部 set，必须整集合原子替换 |
| `network.bond_carrier_unavailable` | active-backup 没有可用 active slave/carrier |
| `network.bond_lacp_not_ready` | 802.3ad aggregator/collecting/distributing 未达到 min_links |
| `network.adapter_unsupported` | 目标 distro/agent 不支持请求 topology |
| `network.bootstrap_mismatch` | AgentPlan bootstrap snapshot 与本机 PXE link/address 不符 |
| `network.transition_failed` | target activate/proof 失败并已回滚 |
| `network.rollback_failed` | target network rollback 未能恢复 bootstrap 快照，当前 boot 已隔离 |
| `network.adopt_failed` | 真正 init 未采用已提交 topology |
| `network.external_prerequisite_unverified` | 无法静态证明交换机 LAG/VLAN/security binding；warning，运行时仍有硬闸 |
| `feature.missing` | boot bundle/initrd/agent 缺必需 feature |
| `builder.no_eligible_node` | 没有 capability/ABI 匹配且空闲的 Node |
| `builder.environment_not_ready` | BuilderEnvironmentManifest/runtime 缺失、未 ready 或 ABI/feature 不匹配 |
| `builder.selection_conflict` | 相同 build key 已有 in-flight operation，但重复请求指定不同物理 builder Node |
| `builder.boot_slot_conflict` | Node 已被 install/diskless/builder 占用 |
| `builder.expired` | attempt 或 token 过期 |
| `builder.recovery_incomplete` | master secret、持久 token hash/claim 或 operation snapshot 不一致，无法重构同一 capability |
| `builder.upload_invalid` | upload offset/size/hash/deep validation 失败 |
| `builder.non_reproducible` | 同 input digest 产生不同 content digest |
| `first_boot.binding_mismatch` | node/generation/bundle/plan 不匹配 |
| `first_boot.exchange_expired` | 一次性 exchange 超时或重试耗尽 |
| `first_boot.recovery_incomplete` | master secret、持久 token hash/claim/counter 或 generation/local handoff snapshot 不一致，无法重构并证明同一 capability |
| `first_boot.replay` | spent bootstrap token、旧 event token或终态 generation 重放 |
| `first_boot.step_failed` | required first-boot action 重试耗尽，已写 terminal failed marker |
| `first_boot.terminal_delivery_expired` | 本地终态已固定但 generation event token 过期未获 server ACK，server 保持 stale/not-ready |
| `capacity.http_connections_exceeded` | HTTP 总连接或 node-plane 配额已满 |
| `capacity.rootfs_downloads_exceeded` | rootfs GET/Range 并发已满 |
| `capacity.boot_sessions_exceeded` | active install/diskless BootSession 已满 |
| `capacity.builder_uploads_exceeded` | builder upload 并发已满 |
| `capacity.operations_exceeded` | nonterminal operation 已满 |
| `capacity.discovery_probes_exceeded` | active discovery probe session 已满 |
| `rate_limit.exceeded` | 请求速率超过站点策略 |
| `rate_limit.control_exceeded` | 已接纳流程的 control bucket 已满；保持 authority 并在 deadline 内重试 |
| `discovery.serial_conflict` | canonical serial 重复、已绑定或不合法 |
| `discovery.node_not_pending` | 目标 Node 没有有效 pending discovery state |
| `discovery.probe_binding_mismatch` | probe session/MAC/arch/lease/plan 不匹配 |
| `discovery.node_revision_conflict` | 等待期间 Node desired identity 已变化，禁止回填旧观察 |
| `discovery.recovery_incomplete` | master secret、持久 token hash/claim 或 probe snapshot 不一致，无法重构同一 capability |
| `discovery.probe_replay` | 同一 probe terminal facts 的 body digest 漂移或非幂等重放 |
| `telemetry.delivery_deferred` | 非权威 telemetry/event 暂未送达，权威本地 journal 保留且视图标 stale |
| `cleanup.deferred` | 非 secret、未引用 terminal 临时对象清理延后，已登记 cleanup debt |
| `setup.replacement_incomplete` | fresh purge 已开始但 v2 root marker 尚未提交，只允许修复后重跑 setup |

## 14. 实现切片

v0.4 按依赖顺序实现，不允许各领域先复制协议/恢复代码、最后再补公共契约：

1. **共同底座**：AppConfig v5、catalog v6、DeploymentManifest/v2 marker、strict JSON/canonical digest、
   deployment-bound capability 派生、W/R/F/B/Q/D、transaction journal、fresh setup 和全部旧 layout 拒载测试；
2. **AgentPlan v2/topology compiler**：install renderer、diskless renderer、feature/readiness、单 NIC 和
   bond/VLAN/route 负测、BOND 中文注释主题和 registry 生成中文 help；
3. **diskless transition**：bootstrap snapshot、activate/proof/rollback、network-adopt service、Rocky/Ubuntu E2E；
4. **builder environment**：独立 BuilderEnvironmentManifest/runtime 构建、发布、feature/ABI readiness 和启动闭包；
5. **builder operation**：cache key、capability compiler、attempt/boot-slot、BuilderPlan/capsule、upload/finalize/recovery；
6. **install first-boot**：安装器原子 handoff、agent/unit/reporter、exchange/local+server journal、generation E2E；
7. **discovery**：draft Node nullable MAC/arch、per-Node discovery state、现有 initrd discovery mode、SN 唯一匹配与
   MAC/arch 原子回填；
8. **capacity/release**：listener connection gate、control/telemetry 公平限流、metrics、workload harness、24 小时 soak；
9. **CLI/help**：BOND 参数/模式切换/CAS/中文交换机提示、setup exact deletion help、node discovery
   start/status/cancel、node/discovery 查询列与生成 CLI reference；
10. **文档发布**：workflow、current implementation audit、validation 和 README 同步。

共同失败/凭据/transaction 原语在 slice 1 落地，后续每个 slice 随领域 transition 同时补齐，不允许把 failure policy 延到
功能完成后。每个切片必须先有 typed model/DTO、state schema、API/handler、稳定错误码和负向测试；只增加 enum、help、
空 handler 或注释不算完成。

实现所有权固定如下，避免相同 shape 散落在 CLI/HTTP/agent 三处：

| 领域 | 唯一 owner/建议模块 | 禁止 |
|---|---|---|
| AppConfig/catalog/topology types | `src/model.zig` + typed registry/item spec | handler 私有 JSON struct、renderer 自定义字段 |
| v0.4 strict disk DTO | `src/catalog/dto.zig`、`src/config/load.zig`、共享 strict JSON helper | permissive unknown-field parse、v5/v6 双读 |
| deployment layout | 新 `src/state/deployment_manifest.zig` + `src/setup.zig`/`src/paths.zig` | daemon 各 store 自行猜 deployment id |
| capability 派生/claim | 扩展现有 diskless credential 原语为共享 domain-separated helper | builder/discovery/first-boot 各自随机 token算法 |
| AgentPlan/BuilderPlan/InstallFirstBootPlan | `src/http/*_dto.zig` 的 typed struct + canonical encoder | 手拼 JSON、同名 digest 不同算法 |
| topology compile/render | `src/profile/effective.zig` 产 canonical topology；Rocky/Ubuntu adapter 只映射 | adapter 补默认、静默丢字段 |
| pre-init transition/rollback/adopt | 从 `src/agent.zig` 拆分可单测 network transaction 模块 | shell 拼接自由命令、无 journal mutation |
| builder/discovery/first-boot state | 各自独立 state store，统一 transaction/capability helper | 借 BootSession enum 冒充领域 journal |
| HTTP contract | `src/http/contracts.zig`/`routes.zig` 定 method/path/body limit/auth；handler 只消费 typed request | route 和 CLI 各自定义 error/limit |
| CLI/help | command spec + registry 生成，`docs/cli/REFERENCE.md` 随实现生成 | 先写旁路 parser 或文档命令、后补 spec |

每个新 state store至少提供：fresh empty、round-trip、错误 schema/deployment id、truncated/corrupt、CAS replay、atomic-write
failure、restart remaining-TTL 和 terminal retention fixture。跨 store 事务另覆盖每一个 rename/fsync 边界的 crash point。

## 15. 完成标准

v0.4 只有同时满足以下条件才可发布：

- fresh AppConfig v5/catalog v6 setup 成功，DeploymentManifest/v2 marker/id 四方一致，incomplete marker 拒启；旧
  config/catalog/state/AgentPlan 明确拒载，不存在迁移或双读路径；
- strict decoder、规范默认值、collection ordering、长度前缀 canonical encoding、三类 digest inclusion/exclusion 与
  §2.2 plan/topology hard limit 通过 round-trip、duplicate/unknown/overflow/ordering fixture；
- 正常 PXE 仍只使用 UEFI GRUB + DHCPv4，动态 lease 和 `pxe.ip_reservation` 都回归通过；不存在
  `network.bootstrap.*` 或其他 firmware/bootloader 代码/CLI；
- topology registry、CLI、API、validator、install renderer、AgentPlan v2 和 diskless renderer 使用同一字段；
- PXE bootstrap 与 target topology owner 分离，reservation 不再隐式改写目标 DHCP/static；
- Rocky/RHEL 与 Ubuntu 的单 NIC、双 NIC、active-backup bond、802.3ad bond、VLAN-on-bond、static route、
  DHCP target 和全部引用/冲突负测通过；
- BOND registry、validator、NetworkManager/Netplan renderer、pre-init transition、rollback、init adopt 和 CLI help
  均包含 §5.1.1 要求的详细中文注释；源码审计能找到全部固定主题标识，注释与行为测试一致；
- BOND CLI 覆盖 list/show/add/set/replace-values/remove/replace-items、全部公共和 mode 专属参数、CAS、mode 原子替换、
  中文 help/full-help、active-backup/802.3ad/VLAN-on-bond 示例及交换机前置条件主动 WARNING；
- diskless transition 的 payload 预取、permanent-MAC link rename、token 清除、bootstrap snapshot、target DHCP、
  pre-init/adopt proof、rollback 和旧地址清理都有 phase/CAS 测试与目标环境 E2E；
- server builder 现有路径不退化；独立 BuilderEnvironmentManifest/runtime 消除 cache-miss 启动循环，node builder 的
  boot-slot、capability/ABI/environment digest、cache hit、upload Range、restart、expiry、secret、partial upload、
  publish transaction和 reproducibility 通过测试；
- install first-boot agent 由标准 systemd 启动；agent/plan/payload/token handoff、exchange 重试、单一 event token、
  terminal pending-ack reporter、普通重启不重跑、新 generation 重跑、empty plan not-required 和 golden image 无 token通过测试；
- builder/discovery/first-boot capability 都复用 deployment-bound 确定性派生；restart 只重构同一 token，master/hash/claim
  错配 fail closed，持久文件/日志/cmdline/preview 无 raw token；
- 发布 workload、SLO、24 小时 soak、原始指标和失败注入证据完整；
- capacity 每个 admission point、listener 级 connection gate、control/telemetry 分桶、公平性、拒绝码、Retry-After、
  persistent authority 与 live I/O counter recovery、management reserve 均有饱和/释放测试；
- §12 W/R/F/B/Q/D 每个等级至少有一个自动化 fixture；所有 warning 验证 stderr/JSON warnings/event/counter，所有
  rollback 验证逆序补偿、重复执行、restart continuation、恢复后 proof 和 rollback_failed quarantine；
- builder、artifact publish、install first-boot、capacity、discovery、setup purge 的失败注入均证明不会误改既有
  ready artifact/Node desired/已接纳 session，也不会把 F/B/Q 降级成 warning 或成功；
- setup help/full-help/dry-run 准确列出 reset/purge 的保留删除集合，fresh replacement 示例可直接执行；
- SN+IP draft Node、per-Node 短时 discovery、现有 initrd 的受限 discovery mode、product serial 唯一匹配、三对象
  transaction 原子回填、restart/capsule 重放、node list/show 可见、下一次 reservation 生效和 deploy=false 硬闸通过测试；
- reconciliation、远程任务、长期 enrollment、TLS、IPv6、iPXE、NFS root 均没有对应
  v0.4 handler/help/协议分支。
