# NodeForge v0.4 设计：延后增强项

状态：设计冻结，实现未开始。本文定义 v0.4 范围，与 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §2 版本表及
[`V0_2_1_PLUS_ROADMAP.md`](V0_2_1_PLUS_ROADMAP.md) 的版本门禁一致。
v0.4 在 v0.3 完成后启动，收纳 VMware 难以验证或非主流程的增强项。**reconciliation/远程控制为永久非目标**
（全版本，见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §7），v0.4 不实现任何远程主动控制。

## 1. 进入条件

v0.4 必须基于 v0.2.2 operability 与 v0.3 完成：

- v0.3 install-post canonical 扩展、发行版版本矩阵与 callback credential 已落地并通过验收。
- v0.2/v0.3 diskless 与 install 主流程在 UEFI 模式下回归通过。
- 四个产品二进制（CLI `nodeforge` + `nodeforged`/`nodeforge-initrd`/`nodeforge-agent`
  三个运行角色）边界稳定。

BIOS PXELINUX 不构成 v0.4 前置条件；它作为独立延后工作项管理，见
[`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)。

## 2. 范围

v0.4 的持久 shape 统一使用 catalog schema v6；v0.3 保持的 schema v5 到 v6 的迁移必须显式物化网络拓扑
与 builder placement 默认值。不能在 v5 下静默增加多 NIC/VLAN/bonding 或 builder placement 字段。

| 项 | v0.4 范围 | 说明 |
|---|---|---|
| 多 NIC/VLAN/bonding | 是 | PXE bootstrap 可为 DHCP 或预配置静态地址，下载后由 agent pre-init 事务切换目标地址/子网；需显式 consumer feature/schema/验收 |
| 大规模容量压测 | 是 | 高并发、失败恢复、长期运行 |
| 临时 PXE rootfs 构建节点 | 是 | 操作员触发节点下次 PXE 进入有界 builder boot；不远程重启或向运行中 agent 下发任务 |
| install 侧 first-boot agent | 是 | 确定性 first-boot，与 diskless 同一执行模型（无 reconciliation） |
| reconciliation/远程控制 | **永久非目标** | 全版本不实现 |

v0.4 **不**包含：可切换 rootfs 形态（-> v0.5）；NFS root/iPXE/IPv6（永久非目标）；跨不可信网络 TLS/mTLS（永久非目标）。

## 3. 从前序版本继承的强制契约

- v0.1-v0.3 所有权、`/dev/...` 磁盘契约、`software.*`、`kernel_args`、明文 password 不变式。
- canonical phase 集合（`install-post|rootfs-build|first-boot`，无 `runtime`）、四类 action、八步执行契约、
  credential/session/lower 边界、finalizer、事件脱敏、幂等键不变。
- diskless Node projection 与 agent pre-init `node-apply` 契约不变；Node override 只改 desired plan，不改共享
  `rootfs_input_digest`。
- 统一 `node list`/`node status` kind 感知投影；BootSession 与 deployment 投影职责分离。
- agent 永远是开机确定性顺序执行器：不接受远程任务下发、不做 drift 重跑、不做通用远程命令
  （reconciliation/远程控制为永久非目标）。
- `show key == --help-full key == parser key == API operation path`；CLI 不得要求 Shell 内嵌 JSON。

## 4. 网络增强（多 NIC/VLAN/bonding）

- v0.2/v0.3 的 diskless 目标网络由 agent pre-init 在最终 rootfs 写 NM/Netplan 配置，真正 init 启动后接管同一地址；
  install 目标网络仍由安装器写目标盘。v0.4 扩展为多 NIC、VLAN、bonding 与下载后切换地址/子网。
- 需显式 consumer feature 与 schema 扩展：PXE bootstrap/transport feature 属 initrd，
  `multi-nic-v1`/`vlan-v1`/`bonding-v1` 等 target topology feature 属 rootfs agent。`required_features` 按
  `{initrd:[...],agent:[...]}` 分域；任一缺失或冲突在 readiness 或 handoff 前以稳定 error code 拒绝，不静默降级。
- PXE bootstrap、多 NIC、VLAN、bonding 不能由 initrd 或 agent 猜测或静默接受；未声明对应 consumer capability 时 readiness 失败。
- VMware 难以有效验证的部分须在真机或更接近实机的环境验收，不混入主流程完成标准。
- schema v6 使用四个 Node direct structured collection，均由 CollectionSpec/ItemSpec 驱动：
  `network.interfaces[]`（identity=`id`，含 `mac/mtu`）、`network.bonds[]`（identity=`id`，含
  `mode/members/mtu`）、`network.vlans[]`（identity=`id`，含 `parent_id/vlan_id/mtu`）和
  `network.routes[]`（identity=`id`，含 `destination/gateway/metric/interface_id`）。interface、bond、VLAN 都是
  L3-capable link，统一以 optional tagged `ipv4` 表达 `mode=none|dhcp|static`、`address` 与 `prefix_len`；只有
  `mode=static` 时 address/prefix 必填，其他 mode 禁止携带。renderer 不属于 topology，由 distro adapter capability
  唯一选择（继承 v0.2 adapter 契约），不能由 Node 任意指定。
- v0.1 已有的 `network.dns`/`network.search_domains` scalar collection 原 owner 不变。引用必须形成无环图；route 的
  `interface_id` 只能引用启用 L3 的 interface/bond/VLAN，同一物理 interface 不能同时被多个 bond 消费，bond member
  禁止同时持有 L3，VLAN id 范围 1-4094。VLAN 可以建立在 bond 上；同一有效 L3 scope 内的静态地址不得冲突。
- `network.bootstrap.mode=dhcp|static` 与 `network.bootstrap_interface_id` 明确选择 PXE/config/rootfs 下载模式和物理
  接口。static 时另需 `network.bootstrap.ipv4.address/prefix_len`（以及跨子网所需 gateway）；该 bootstrap 地址是
  transport-only 配置，与目标 topology 的 `ipv4` 分离，不能因为值相同而合并 owner 或生命周期。
- DHCP bootstrap 继续复用 v0.2 的 DHCP correlation/session 协议。static bootstrap 的 firmware 预配置 server IP
  literal 与 node-specific opaque bootstrap path；首次 GRUB/PXELINUX config RRQ/GET 必须校验 source IP 精确对应该
  Node 的 bootstrap address/reservation，并通过 L2/MAC observation 或 duplicate-IP gate 后，才在一个事务中创建
  BootSession、immutable delivery snapshot 和 credential capsule，返回含 per-session capsule path 的固定 boot config。
  同一首次请求重传幂等，并发创建用 CAS 只允许一个 winner；source mismatch、冒认或地址冲突 fail closed。
  opaque URI/node identity 不能单独构成认证，static bootstrap 仍依赖 `local-only` VLAN/ACL、source binding、rate limit
  与后续 scoped capsule。`node boot preview` 只显示 static bootstrap URI template/校验结果，不输出 raw token。
- 目标 topology 只在 rootfs 下载、校验、挂载、AgentPlan handoff，以及 agent 对 plan/全部 payload 的预取校验完成后，
  由 agent pre-init 在最终 rootfs 按 AgentPlan 事务切换：先 stage renderer/topology，并保留 bootstrap link/address；再用最终 rootfs 的网络工具
  activate 目标 link/route；然后向固定 server endpoint 发 authenticated request，验证实际 route、source address 与
  egress interface；成功才 commit，失败则 rollback 目标 topology、保留 bootstrap 并终止 boot。ping 不能作为唯一成功证据。
  agent 必须在任何 topology 切换前清除 `agent:read` token；成功后 exec 真正 init，distro renderer adopt 已提交 topology，确认 adopt 后才删除 bootstrap address；adopt 失败
  继续保留 bootstrap 并报告失败，不能留下半切换网络。initrd 不包含第二套 NM/Netplan/topology renderer。
- BootConfig v4 仍是给 initrd 的最小 DTO，只在 v3 的 `bootstrap_network` 上增加 `bootstrap_interface_id` 与静态
  bootstrap transport 字段；完整 `interfaces/vlans/bonds/routes` target topology 进入 AgentPlan v2，并要求对应 agent
  feature token。**全部 v0.4 新 delivery 统一使用 BootConfig v4 + AgentPlan v2**：单 NIC target 也编码为单元素
  topology，不保留双 renderer。旧 active session 继续消费自己的 immutable BootConfig v3/AgentPlan v1 snapshot 到终态；
  新 v0.4 session 的 boot bundle/initrd 不支持 BootConfig v4，或 rootfs agent 不支持 AgentPlan v2 时 readiness 失败。
  v0.4 不改变 rootfs materialization 字段，仍固定 squashfs_overlay。
- v5 → v6 采用直接替换（不迁移，见 v0.2.3 设计 §0）；旧 v5 catalog 不被
  加载，操作员需重新 `setup`。新 Profile 的 `network.interfaces` 和
  `network.routes` 按 v6 schema 定义。active/recoverable BootConfig v3/v4 与
  AgentPlan v1/v2 snapshot 均继续按创建时内容到终态。

## 5. 容量与压测

- 大规模并发 PXE 引导、rootfs 下载、失败恢复与长期运行回归。
- v0.2 已验证 diskless 最小功能并发；v0.4 扩展到生产级容量与恢复矩阵。
- 容量压测不改主流程协议栈/状态机语义，只验证边界与稳定性。
- 每次发布必须提交版本化 workload manifest，至少声明 Node 数、并发 session/download、rootfs 大小、Range 中断率、
  event rate、运行时长、服务端 CPU/内存/FD/磁盘预算和 p95/p99 SLO。没有 manifest、原始指标和失败注入结果，
  “生产级”或“长期运行”不能作为完成证据。
- workload 参数属于测试工具输入，不写入 catalog；生产并发上限/速率限制属于 daemon config typed PropertySpec，
  二者不得混为一套可变产品状态。v0.4 不要求在产品 CLI 中内置压测发生器。

## 6. 临时 PXE rootfs 构建节点

- v0.2 的 rootfs 由服务端 builder 本地构建（chroot/staging，按需 bind-mount `/dev`/`/proc`/`/sys` + 匹配内核）。
- v0.4 允许节点在下一次 PXE 中进入专用 builder mode 构建 rootfs，获得更高保真（真机硬件/内核态），满足驱动/dkms/initramfs 重生成等
  依赖真实环境的动作（[`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §4 构建保真）。
- builder 节点仍消费同一 pinned Profile build projection 与 `rootfs_input_digest`，不消费目标 Node override。
  成功产物必须上传并原子发布到服务端
  rootfs cache；v0.4 不允许“仅就地使用”，否则 delivery snapshot、Range 恢复和跨 Node cache 语义会分叉。
- `builder.placement=server|node` 是 schema v6 的 Profile build policy，默认 `server`；Profile 只表达 placement
  策略，不持有物理 Node id。可作为 builder 的 Node 以 Node direct `builder.eligible=true` 显式加入本地 builder pool，
  且必须 `deploy=false`、无 active/recoverable session、capability 匹配。
- CLI 创建的是有界 `rootfs-build` operation，并为 builder Node 原子 arm 一次性 builder delivery；它不远程重启、
  不向已经运行的 agent 下发任务。操作员或外部电源系统随后让该 Node PXE 启动，daemon 只在匹配 operation/plan 的
  下一次启动中交付固定 builder bundle。超时撤销 arm/token，Node 回到 `deploy=false`。
- arm 持久化为 operation-owned `BuilderBootAttempt`，至少固定 operation id、builder node id、rootfs input digest、
  capability class、builder ABI、expiry 和 state。它不改变 Node 绑定 Profile 或 lifecycle kind，但与 install/diskless
  BootSession、deployment 和其他 builder attempt 互斥，占用该 Node 唯一 boot slot。resolver 只有在 `deploy=false`、
  attempt 为 armed 且 observed MAC/arch/capability 全部匹配时才发 builder bootfile；否则 fail closed。
- `BuilderBootAttempt` 内部状态固定为
  `queued -> armed -> booting -> building -> uploading -> validating -> ready | failed | expired | cancelled`；对外仍投影为
  v0.2 operation 的 canonical 状态，不扩张通用 CLI operation enum。v0.4 没有通用 cancel CLI，`cancelled` 仅保留给
  服务端关闭/管理员恢复策略；任何终态转换都必须原子撤销 boot slot 与 token。
- builder agent 只能执行该 snapshot 的四类 rootfs-build action 并上传声明产物，使用 per-operation capability token；
  token 由与 builder initrd 一起加载的 per-operation credential capsule 交付，服务端只持不可逆 hash。claim 绑定
  operation/builder Node/input digest/允许的 artifact upload path+method/expiry，完成或超时即撤销，不能访问 catalog
  或其他 artifact。无通用 argv/script/task API。
- `builder.placement` 只进入 Profile revision 与 build operation policy，不进入 Node `desired_plan_digest` 或
  `rootfs_input_digest`；切换执行位置不会制造 deployment drift/cache miss。实际 `capability_class + builder_abi`
  属构建输入并进入 `rootfs_input_digest`。物理 builder
  node identity 只进入 operation snapshot，不进入 cache key；同 capability class/ABI 的 eligible Node 可互换。
- effective compiler 必须在 `rootfs plan` 阶段由 target arch/kernel、action 所需硬件/内核能力和版本化 builder adapter
  确定唯一、规范化的 `required_builder_capability_class` 与 `builder_abi`，再计算 `rootfs_input_digest`；不能到
  `--builder-node` 选择时才改变 digest。无法唯一归类时 plan fail closed。所选 Node 必须精确声明匹配 class/ABI，
  任何可能影响输出的硬件事实都必须进入 capability class，不能只靠物理 node id 隐式承载。
- 相同 `rootfs_input_digest` 已有 ready artifact 时直接 cache hit（digest 已含 capability class/ABI）；`--verify-reproducibility` 规则与
  v0.2 一致。server/node builder 同输入产生不同 content digest 必须报 `builder.non_reproducible`，不得静默分叉缓存。
- daemon restart 从持久 attempt、operation journal 与 upload lease 恢复；`booting/building/uploading` 各阶段均检查
  expiry。上传只写 operation-owned `.part` 并持有有界 lease，完整 size/digest/deep validation 成功后才原子发布；partial
  upload 永不成为 ready artifact。failed/expired/cancelled 清理 staging 与 lease，不能复用旧 raw token。
- builder capsule 遵守 hash-only 恢复边界：raw token 只驻 daemon 内存。capsule 交付前/中 daemon restart 且 builder
  未完整取得 token 时，该 attempt 以 `builder.recovery_incomplete` 失败并由新 operation/attempt 重试；token 已完整交付
  后可凭客户端持有值继续 hash 验证恢复。delivery started/completed 审计不能重建 secret。
- 物理 builder 必然能看到它正在构建的最终 rootfs 内容。只有显式 `builder.eligible=true` 且满足本地信任策略的 Node
  才能进入 pool；Profile password hash、client/host private keys 等敏感 build input 只随该 operation 的认证 capsule/
  snapshot 在 tmpfs 中交付，绑定 operation/node/input digest/expiry，禁止进入 catalog、cmdline、日志或上传旁路，
  ready/failed/expired 后必须清零。不能把只允许 artifact upload 的 token 当成读取任意 Profile secret 的通用 API。

## 7. install 侧 first-boot agent

- v0.3 的 `install-post` 由安装器执行（无 agent）；v0.4 增加 install 侧 `first-boot` agent，与 diskless 同一确定性
  执行模型：开机顺序执行、固定顺序（文件更新 -> package -> archive -> script）、一次性、确定性 + 幂等。
  diskless 仍在 first-boot 前执行 v0.2 的 Node `node-apply`；install Node effective override 已由安装器写入持久目标盘，
  因而 install first-boot 不重复执行 diskless node-apply。
- install 仍只使用 `install.post_install.bundle` 及 v0.1 已有的 `overrides.install.post_install.bundle`；schema v6
  允许 effective bundle 同时含 `install-post` 与 `first-boot` item，不新增 `install.first_boot.bundle` 或第二个 owner。
  renderer 按 Profile + Node override 得到的 effective bundle，把 first-boot 固定 payload 写入目标磁盘。
- **无 reconciliation**：agent 不检测 drift 后远程重跑收敛；drift 仅报告（v0.1 既有）不自动修复。
- **无长期 enrollment credential**：`nodeforge.node_id`/generation 只提供关联身份，不单独构成认证；短时、
  generation-bound bootstrap/event token 只服务本次 first-boot，不能续期为运行期身份。initrd 写
  `/var/lib/nodeforge/boot.json`，agent 读取；状态/异常经 `event_url` best-effort 回传，失败本地兜底。
- install 侧 agent 与 diskless agent 共用同一程序（`nodeforge-agent`）与执行契约，差异只在目标上下文
  （install 写磁盘 vs diskless 写 overlay upper）。
- install 的 first-boot handoff 必须在安装完成前写入目标磁盘：bootloader entry 固定无密钥 node/generation identity，
  `/var/lib/nodeforge/first-boot.json` 保存 plan/bundle digest 与非 secret 摘要。nodeforged 在 install generation 建立时
  生成至少 256 bit 的一次性 bootstrap token，仅持不可逆 hash；raw token 经该 generation 已认证的 installer handoff
  交给安装器，并以 0400 写入 `/var/lib/nodeforge/credentials/first-boot.token`。它不得进入 catalog、kernel cmdline、
  日志、通用镜像或 golden image。
- 第一次本地启动时 initrd 提交 bootstrap token，服务端校验 `node_id/install_generation/plan_digest/expiry` 后令 claim
  进入 `exchanging`，换发短时 append-only event token，但此时不永久标记 spent。若响应中断，客户端在有界窗口内重试
  exchange；服务端必须在同一事务撤销上一 event claim 并换发新 token，任意时刻最多一个有效 event token，旧 token
  立即拒绝。initrd 使用最新 event token 首次成功 POST/ack 后，bootstrap claim 才原子标记 spent；超过 retry budget 或
  expiry 则 generation 失败。跨 Node、旧 generation 和 digest 漂移全部拒绝。initrd 确认 spent 后删除 bootstrap token，
  agent 完成/超时后删除 event token。daemon 只持 token hash 与状态，原始 token 不落服务端磁盘。
- install first-boot 以 `(node_id, install_generation, bundle_revision, plan_digest)` 为一次性边界；成功 journal 写入
  目标磁盘，普通重启不重跑。新 install generation 才重新执行。凭据交换只服务这个有界阶段，不是可续期 enrollment。

## 8. CLI（v0.4）

> 完整 CLI 约定见 [`V0_2_CLI.md`](V0_2_CLI.md) §0；v0.4 命令随其设计落地。

```text
nodeforge node item add <node> network.interfaces id=eth0 mac=<mac> ipv4.mode=none
nodeforge node item add <node> network.bonds id=bond0 mode=802.3ad
nodeforge node item add-values <node> network.bonds bond0 members eth0 eth1
nodeforge node item add <node> network.vlans id=vlan100 parent_id=bond0 vlan_id=100 ipv4.mode=static ipv4.address=<ip> ipv4.prefix_len=24
nodeforge node item add <node> network.routes id=default destination=0.0.0.0/0 gateway=<gw> interface_id=vlan100
nodeforge node set <node> network.bootstrap.mode=static network.bootstrap_interface_id=eth0 network.bootstrap.ipv4.address=<ip> network.bootstrap.ipv4.prefix_len=24
nodeforge profile set <profile> builder.placement=node
nodeforge node set <builder-node> builder.eligible=true
nodeforge profile rootfs build <profile> --builder-node <builder-node> [--wait] [--if-input-digest <digest>] [--if-revision <profile-revision>]
nodeforge node postprocess show <node> --phase first-boot [--generation <id>]
```

- 多 NIC/VLAN/bonding、节点构建需配套显式 consumer feature：target topology 的 `multi-nic-v1`/`vlan-v1`/
  `bonding-v1` 属 agent，PXE builder transport 的 `builder-node-v1` 属 initrd，并随 schema v6 扩展；未声明时
  readiness 失败（`property.not_applicable` 或 `feature.missing`）。
  topology 为 Node direct structured collection，不经 `overrides`；mode 必须为 adapter 声明支持的值。
- builder placement 由 Profile policy 决定，不使用一次性 `--on-node` 绕过 effective plan。当 placement=node 时
  `--builder-node` 从 eligible pool 中选择本次 operation 的物理执行者；该选择进入 operation snapshot，不写回 Profile。
  `rootfs plan` 必须显示 placement、eligible capability class/ABI；build 输出显示所选 builder node 和是否等待 PXE。
  `--if-input-digest` 只防构建内容漂移；自动化若还要锁定 placement 等 operation policy，再使用通用可选
  `--if-revision`。普通调用仍原子使用执行时最新 Profile revision，不要求手工复制任何 guard。
- `postprocess` 统一命名（同 v0.2）：install 侧 first-boot 结果也用 `node postprocess show`，不用 `postinstall`。
- 容量压测不新增产品 CLI，复用 `node list`/`status`/`events` 观测；外部 test harness 消费 workload manifest。
  daemon 服务上限通过 config PropertySpec 设置，不能写入 catalog desired state。
- reconciliation/远程控制无对应 CLI（永久非目标）；v0.2/v0.3 不提供这些命令的 help/handler。

## 9. 明确非目标（v0.4 增量）

- reconciliation/远程控制：服务端不检测已部署节点 drift 后远程主动触发 agent 重跑收敛，agent 永远是开机
  确定性顺序执行（diskless/install 通用）；drift 仅报告不自动修复。**永久非目标**（继承 v0.2 §7）。
- 可续期 enrollment/长期 agent credential 机制：全版本不引入。boot/install generation 的短时 scoped token
  属传输与事件认证，不构成 enrollment。
- 跨不可信网络 TLS/mTLS、远程管理。**永久非目标**；v0.4 的 HTTP bearer 仍只在隔离 `local-only` 网络内提供认证。
- 可切换 rootfs 形态（`ram_rootfs`/`diskless.overlay.mode`）-> v0.5。
- NFS root/iPXE/IPv6/by-id/serial/WWN -> 永久非目标（继承）。

## 10. 完成标准

- 多 NIC/VLAN/bonding 经显式 agent feature 与 schema 落地，readiness/handoff 前校验；agent pre-init 的 topology
  transaction 在真正 init 前完成，缺失/冲突 fail closed。
- v5 → v6 直接替换（不迁移）；active/recoverable v2/v3
  snapshot 跨版本替换继续到终态。
- DHCP/static bootstrap 都能创建唯一 BootSession；static 路径覆盖冒认、source-IP mismatch、duplicate IP、首次请求重传
  与并发 CAS，preview 不泄漏 token；authenticated route proof 失败时保留 bootstrap 网络。
- 大规模容量压测有版本化 workload、资源预算、SLO、原始指标与失败恢复证据，不改主流程语义。
- 临时构建节点通过单次 PXE operation、消费同一 input digest、只回传服务端 cache；无远程重启/通用任务入口，
  BuilderBootAttempt 与其他 boot slot 互斥、credential capsule 越权/过期/重放、server/node reproducibility 与
  operation 超时撤销通过测试；plan 在选择物理 Node 前稳定导出唯一 capability class/ABI，placement 不造成无意义
  cache miss，错误 class/ABI 的 eligible Node 在 arm 前被拒绝。restart/各阶段 expiry、`.part` lease、partial upload
  不发布、capsule 交付前/中 `recovery_incomplete` 和 token 已交付后的 hash 验证恢复均有测试。
- install 侧 first-boot agent 与 diskless 共用 runner，但以 install generation 和磁盘 journal 保证一次性；持久 handoff、
  bootstrap token exchanging/spent 事务、响应中断重试、旧 event token 撤销、任意时刻单一有效 token、普通重启不重跑
  与新 generation 重跑均通过测试；golden image
  不含 token，node/generation-only 伪造事件被拒绝，无可续期 enrollment。
- 传输 token 与 management credential 边界不变；reconciliation/远程控制/TLS 均不存在对应实现。
- 本审计与版本设计、配套文档同步更新；预留 enum/空 handler 不算实现证据。
