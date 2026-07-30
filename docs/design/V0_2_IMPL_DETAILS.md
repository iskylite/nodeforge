# NodeForge v0.2 实现细节

状态：v0.2 实现分册，核心闭环已实现并持续按验证结果收口。总纲以 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) 为准；本文细化
diskless 主流程的三项核心闭环实现，优先级
**1 -> 2 -> 3**：BootSession 状态机 -> server DHCP/TFTP/HTTP 协议栈 -> effective compiler/
readiness/validator。与 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) 一致；程序边界见
[`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md)，CLI 见 [`V0_2_CLI.md`](V0_2_CLI.md)。

本文负责内部状态、协议和校验契约，不维护操作教程或完整 CLI 语法；示例命令只用于连接实现反馈闭环。

## 0. 核心闭环控制流

三项优先级按控制流闭环串接，方向 **3 -> 2 -> 1 -> 3**：

```text
(3) effective compiler/readiness/validator
  -- 产出 immutable DisklessEffectivePlan snapshot + plan digest + readiness 闸 -->
(2) DHCP/TFTP/HTTP 协议栈
  -- 驱动 canonical BootSession 状态迁移、发协议事件 -->
(1) BootSession 状态机
  -- 状态迁移映射回校验源（digest/feature/quarantine）-->
(3) 反馈闭环（readiness + validator 双检点、pin 完整性不变式）
```

- **校验源映射**：协议事件 -> 状态迁移 -> 校验源（plan digest、feature 子集、token 越权、quarantine
  预算）三层必须可追溯到同一 effective plan snapshot。
- **双检点**：readiness（发布前，Profile/Node/capability/rootfs 就绪）+ validator（每次状态推进，
  digest/feature/quarantine 不变式）。
- **snapshot 完整性不变式**：一次 boot attempt 全程只消费同一个 DisklessEffectivePlan snapshot digest，
  中途 Profile/Node 变更不静默影响在途 session。
- **反馈闭环**：failed/expired 终态、quarantine 计数、rootfs ready 闸回流到 readiness/validator，
  阻止下一轮 session 在不满足不变式时启动。

## 1. BootSession 状态机（优先级 1）

### 1.1 canonical 状态迁移

```text
boot.dhcp_discover -> boot.dhcp_offer -> boot.dhcp_ack -> boot.tftp_rrq -> boot.tftp_complete
  -> boot.config_fetched -> diskless.initrd_started -> diskless.rootfs_downloading
  -> diskless.rootfs_verified -> diskless.rootfs_mounted -> diskless.switching_root
  -> diskless.agent_configuring -> diskless.running
```

- `<kind>.failed` 可从任一非终态进入，`boot.expired` 只能由服务端超时进入；两者均为本次 session 终态。
- 重复同阶段上报幂等；跳跃、回退、错绑 node/session 一律拒绝。
- 历史 `pxe_seen`/`bootfile_sent`/`diskless_config_fetched` 是 `dhcp_discover`/携带 bootfile 的
  `dhcp_ack`/`boot_config_fetched` 的展示别名，不是额外持久状态。v0.2 API/Event/持久化只用
  canonical 名。

迁移必须由唯一 producer 与可验证证据触发：DHCP/TFTP 阶段由服务端协议栈按 MAC/XID/session-bound
path 产生；`boot_config_fetched` 由首次成功授权并固定 immutable BootConfig bytes/config digest 产生；其后阶段只接受 `event:append`
token 上报，并携带 plan/config digest。`rootfs_verified` 必须证明完整 size + SHA-512，
`diskless.agent_configuring` 必须由切根后的 agent pre-init 在验证 handoff 后、发起 AgentPlan GET 前上报；其内部细分
`agent.plan.fetch`/`agent.payload.prefetch`/`node_apply.*` 事件但不增加更多 lifecycle state。`diskless.running` 必须由
真正 init 后的 agent unit 携带 PID 1 boot id、handoff 与 AgentPlan digest 上报。Zig 内部 enum
使用 snake_case 时必须经唯一映射表序列化成上述带 namespace 的字符串。

状态 reducer 使用 compare-and-swap：请求带 `expected_phase` 和单调 `event_seq`。相同 seq + 相同 payload
幂等成功；相同 seq 不同 payload、跳跃或回退返回 409 并写安全事件。所有 handler（包括服务端内部协议
producer）只能调用 reducer，禁止直接写 `session.phase`。

### 1.2 install 与 diskless 分离

当前 `src/state/boot_session.zig` 的 `Phase` 枚举把 install 侧阶段（`installer_started`/
`installing`/`installed`/`provisioning`/`completed`）与 diskless 侧阶段混排。v0.2 实施：

- canonical BootSession 只覆盖 DHCP/TFTP/boot_config 共享前缀 + diskless 尾部。
- install Profile 的 BootSession 在 `boot_config_fetched` 完成交付后**终止**；installer 进度
  （`installer_started`/`installing`/`installed`/`provisioning`/`completed`）移出 BootSession，
  仅在 `node_status` 部署投影保留。
- BootSession（传输态）与 deployment 投影（node_status）职责分离。

### 1.3 node_status 投影与 node list 统一状态

每个 Node 在任一时刻只有一个 desired `ProfileKind`，也只能有一个 current session。状态模型必须是
discriminated union，而不是 install/diskless 两套 nullable 字段叠加：

```text
NodeCurrentState =
  { kind=install,  session, plan_digest, state=boot.* | install.* }
| { kind=diskless, session, plan_digest, state=boot.* | diskless.* }
```

- `boot.*` 是两种 kind 共用的传输前缀；进入分支后只允许当前 kind 的状态。
- install 只能进入 `install.installer_started ... install.completed|install.failed`。
- diskless 只能进入 `diskless.initrd_started ... diskless.running|diskless.failed`。
- 同一 node 不允许两个活动 session，即使 kind 不同；无旧 session 时创建必须 CAS `active_session=null`；
  supersede 时必须 CAS `active_session=<observed-old-id>`，在同一事务中终止旧 session、撤销 token 并安装新 id。
- Profile kind 只能在 `deploy=false` 且无活动 session 时切换。切换会终止/归档旧 current projection，旧记录
  只在 history/trace 中按其 session snapshot kind 显示，绝不能拼到新 desired state。
- session 创建时固定 `kind + profile revision + plan digest` snapshot；中途 Profile 改名、换绑或迁移都不改变该 session。
- XID 不是新 boot 的充分证据。同 XID 重传幂等复用同一 session；旧 session 仍在 DHCP/TFTP 前缀、snapshot
  plan 未变且请求落在有界 correlation window 内时，新 XID 只作为该 session 的 transaction alias，不能撤销 token。
  只有旧 session 已进入 `boot.config_fetched` 或其后阶段后再次出现新的 DHCP 启动证据、correlation window 已过期，
  或管理员/协议栈持有其他可验证的新 boot evidence 时，才能在一个锁/事务内 CAS observed old id：先标
  `superseded`、撤销旧 token，再创建新 session。任何时刻不能短暂存在两个 active session；旧 HTTP fd 的 object
  snapshot ref/打开的 fd 可继续完成旧响应，不代表旧 session 仍 current。

`node_status` 必须沿用带 namespace 的 canonical 名，例如 `diskless.running`，不得另建无 kind 的
`running` 别名。早期 PXE/TFTP 状态也使用 `boot.dhcp_discover` 等完整名，不折叠为模糊的
`ready/booting/downloading`。

`node list`/`node status` kind 感知投影统一 schema（设计名 `ProfileKind` = 代码 `BootKind`
`model.zig:329`，v0.2 扩 `install|diskless`）：

| 列 | 说明 |
|---|---|
| `ID` | Node id |
| `KIND` | `install` 或 `diskless`（来自 effective Profile kind） |
| `PROFILE` | 绑定 Profile |
| `STATE` | 唯一 current lifecycle state；按 kind 为 `boot.*`、`install.*` 或 `diskless.*` |
| `SESSION` | 当前 session id；无活动/最近 session 为 `-` |
| `QUARANTINE` | boot gate 状态（`ok`/`quarantined`） |
| `SEEN` | 按 kind 泛化的最近活动时间戳 |

first-boot step 结果不是第二个 Node 状态机。diskless 成功完成 agent pre-init、exec 真正 init 后 Node state 为 `diskless.running`；
`postprocess` 只是该状态的附属摘要（`not-configured|running|succeeded|degraded`）。step 失败可令
`postprocess=degraded`，但不能同时把 Node 标成 `diskless.failed`，也不能产生 install 状态。
`diskless.running` 后 lifecycle reducer 已终态；event token 只可追加 `postprocess.*` 子流，不能再改变
current lifecycle。

### 1.4 quarantine 与 retry

- Quarantine 是 **Node 级 boot gate**，不是 BootSession phase。一次 attempt 进入 `failed` 后按 session snapshot 的
  `max_attempts`/`backoff_seconds` 计数；达到预算才进入 quarantine，并拒绝新 session。
- `diskless.running` 是启动成功终态；agent pre-init `node-apply` 失败发生在真正 init 前，进入 `diskless.failed`/
  quarantine 计数；真正 init 后的 first-boot 失败只令 `postprocess=degraded`，不回写或倒退 BootSession。
- `nodeforge node diskless retry <node>` 只清除终态 failure quarantine；不创建 install generation、
  不修改 Profile、不远程重启。存在活动 session、`deploy=false`、Profile 非 diskless 或 desired digest
  已变化时 fail closed。

failure ledger 主键为 `(node_id, plan_digest)`，记录 attempt/retryable count、last reason、
`next_allowed_at`、`quarantined_at` 与 revision。仅确定性节点/配置/镜像错误或瞬时错误重试耗尽才增加
attempt；外部 401/403 探测不消耗预算。retry 以 If-Match 原子清 gate；desired digest 改变创建新 bucket，
旧 bucket 保留审计。

### 1.5 持久化与崩溃恢复

v0.1 `boot_session.Store` 以进程内 registry 为主，且 `boot_session_store` 明确只恢复 install；v0.2 必须
新增 diskless delivery record：session/node/profile/kind、phase/event_seq、desired/config/rootfs/AgentPlan/payload digest、cache
pin、config/rootfs/agent/event token claim 的 HMAC/hash（不存原 token）、scope/expiry/path allowlist、capsule delivery started/completed 审计位、failure bucket、
created/last-progress wall time。
未过期 session 仅在 delivery snapshot 完整时恢复；快照缺失、digest 漂移或 claim 无法验证时终止为
`session.recovery_incomplete`，禁止重新编译计划续跑。

raw token/capsule 只驻内存且不落盘，因此恢复保证从**客户端已完整取得 token**后才成立。daemon 在 capsule 尚未开始
交付时重启，旧 session 标 `session.recovery_incomplete`，下一次 boot 创建新 session/token；capsule 传输中重启时，
客户端若已取得完整 token可继续，否则也必须由下一次 boot 重建 session。`capsule_delivery_started/completed` 仅用于审计
和错误分类，不能据此重建或伪造 raw token，也不能为旧 session 静默生成第二个并行有效 token。

## 2. server DHCP/TFTP/HTTP 协议栈（优先级 2）

### 2.1 DHCP

- 按 canonical BootSession 驱动：未知客户端按 v0.1 discovery policy（`record|deny`）；已认领/绑定
  Profile 的 diskless Node 发放诊断 lease 并下发 boot bundle bootfile（GRUB UEFI）。
- **rootfs ready 闸**：`dhcp_discover` -> `dhcp_offer` 前校验该 Node snapshot 指定的 rootfs 已 ready
  （digest 存在、builder succeeded）；未 ready 时不发 diskless bootfile（fail closed，可返回诊断 lease
  或 deny，按策略）。
- kernel cmdline 只携带无密钥 config URL、node/session 与 `kernel_args`；一次性 config token 通过
  per-session credential capsule（GRUB 追加的第二 initrd cpio）交付。

### 2.2 TFTP

- 交付 boot bundle（kernel + 共享 NodeForge initrd）与 per-session credential capsule；所有必需对象完成才推进
  `boot.tftp_complete`。capsule RRQ 必须绑定活动 DHCP session/IP，单次短 TTL。
- 越权/损坏/中断进 `failed`，记稳定 reason。

### 2.3 HTTP

- **BootConfig 路由**：`config_url` 经 single-purpose、bounded-replay 的 `config:read` token 鉴权。首次授权 GET
  原子固定 session snapshot 对应的 immutable bytes/config digest；在收到携带相同 config digest 的
  `diskless.initrd_started` 前，短窗口内允许重复 GET 相同 bytes。该确认事件或 expiry 到达后原子撤销 token；重复 GET
  不重复推进 phase，也不能生成不同 bytes。
- **rootfs 路由**：node-bound GET/HEAD/Range，按 content SHA-512 交付共享 lower；支持 Range 恢复、
  ETag、sha512 校验。
- **AgentPlan 路由**：`GET /api/v1/nodes/:node/boot-sessions/:session/agent-plan/:digest`，只接受 `agent:read`
  token；返回 session snapshot 已固定的 canonical bytes。相同 token 只能访问 plan 明列的内容寻址 payload path，
  不提供 list/latest/catalog/effective 查询，禁止重定向；AgentPlan 与全部 payload 取完校验后客户端立即清零 token。
- **event 路由**：只接受 `event:append` token；initrd phase 与 agent `provision.step.*` 共用有界 envelope，
  绑定 node/session/plan/event_seq。
- 已验证 claim 的 scope/path/node 越权或跨 Node rootfs 访问一律拒绝，并可令该 claim 所属 session 进入 `failed`；
  未知或无效 token 不得关联、修改或消耗任何 session 的 failure budget。

禁止 redirect、目录 listing 和 content-encoding；rootfs ETag 为 immutable SHA-512。只接受单一 bytes Range；
多 Range、suffix Range、越界返回 416。`If-Range` 不匹配返回 200 时客户端必须截断 partial。未知/无效 token 返回 401
并只写不关联 victim session 的 security audit；已验证 claim 但 scope/path/node 不符返回 403，并按该 claim 的 session
稳定归责；已验证但过期或 session 终止返回 410；rootfs 未 ready 返回 409。格式合法但不支持或越界的 Range 返回 416，
单次客户端格式错误默认不终止 session，重复达到有界 abuse threshold 后才按已验证 claim 失败。错误 body 不泄露其他
node 资源存在性，401/未关联探测绝不推进 phase、attempt 或 quarantine。

## 3. effective compiler / readiness / validator（优先级 3）

### 3.1 effective compiler

```text
DisklessEffectivePlan = compile(resource capabilities, diskless profile policy,
                                node direct facts, node overrides)
```

- 与 v0.1 install 复用同一 compiler、同一 plan digest；diskless 分支只消费 immutable
  DisklessEffectivePlan，不建立第二套 users/packages/network 默认值。
- target-system、software、kernel arguments 直接复用 v0.1 effective compiler；software 的
  repositories/environment/groups/tasks/packages include/exclude 不得缩减为 package-only 子集。
- diskless 不消费安装磁盘选择器，但复用同一 Profile/Node override 模型。
- compiler 输出 `profile_build_projection`、`node_boot_projection` 与唯一 `node_apply_projection`：第一项是共享 rootfs
  输入；第二项只含必须在 kernel/rootfs 之前生效的 kernel arguments、transport/overlay/session 参数；第三项包含全部
  target-system/software/service 与 first-boot descriptor。只有第一项进入 `rootfs_input_digest`，后两项进入
  `desired_plan_digest`。server compiler 将全部运行根差量规范化进 immutable AgentPlan；给 initrd 的 BootConfig 只引用
  plan URL/digest/size/expiry。`nodeforge-agent --pre-init` 切根后以 bootstrap 网络从服务端取得 expected digest 的 plan/
  payload，校验并清零 `agent:read` token 后，在真正 init 前执行。Node 的
  `overrides.diskless.provision.bundle` 也编译进 node-apply projection：只允许 first-boot item，记录 bundle/payload/
  package closure digest，并完整替换该 Node 从 Profile 继承的 first-boot；Profile rootfs-build projection 永不读取此 override。

### 3.2 readiness（只读准入检查）

readiness 不是 Node 当前状态、health check、build 或 deploy 动作，而是进入下一阶段前的**无副作用验收闸**。
它只编译当前 desired snapshot、执行检查并给出下一步；不得创建 session、触发 builder、修改 deploy 或缓存结果
冒充最新结论。每次调用都基于当前 revision/digest 重新计算。

- `--stage build` 回答“输入是否完整到可以构建 rootfs”：检查 kind、source/repository/runtime-kernel/initrd、
  builder arch/tool capability、bundle/action、credential/session/lower 边界、local-only 和 input digest；不要求 rootfs 已存在。
- `--stage boot` 回答“现在是否允许为该 Node 发 PXE bootfile”：在 build checks 上增加 rootfs ready/deep
  validation、content digest/modules ABI、BootConfig renderer/features、MAC/IP、quarantine、active session 和
  已知内存预算；Node software override 还要验证全部 capability id、pinned repository revision/GPG policy、exact
  add/remove package closure、protected package 集、agent capability 与 local-only 可达性；Node bundle override 还要验证
  first-boot-only、immutable payload closure、artifact size/digest、`node-firstboot-payload-v1` feature、`agent:read`
  path allowlist 与 bootstrap 网络下的可达性。
  任何 required check 失败都不发 bootfile。

统一输出至少包含：

```json
{
  "stage": "boot",
  "ready": false,
  "plan_digest": "...",
  "checks": [
    {"id":"rootfs.ready","status":"failed","reason":"rootfs.not_built",
     "next_command":"nodeforge profile rootfs build rocky-diskless --wait"}
  ],
  "warnings": []
}
```

`failed` 阻塞下一阶段；`warning` 不阻塞但必须显式展示，例如新节点内存 inventory 未知，最终由 initrd 实测。
旧 initrd 缺 required feature、rootfs 未构建、kernel ABI mismatch 都是 failed，不能降级成 warning。

v0.2 `squashfs_overlay` 的内存预算统一使用 `available_budget`：服务端 readiness 在可信 inventory 存在时以
`inventory.memory_bytes - kernel_initrd_bytes`（checked subtraction）计算；initrd 直接使用当时的 `MemAvailable`，
不能再次扣 kernel/initrd。令 `upper_limit=floor(available_budget*tmpfs_percent/100)`，必须同时满足
`minimum_free_bytes <= upper_limit` 与
`compressed_size + uncompressed_size + node_firstboot_payload_size + upper_limit + safety_margin <= available_budget`；无 Node bundle override 时
`node_firstboot_payload_size=0`。面向 inventory
总内存的保守下界为
`kernel_initrd_bytes + exact_min_available(compressed_size+uncompressed_size+node_firstboot_payload_size+safety_margin,tmpfs_percent,minimum_free_bytes)`，所有加乘、减法和边界求解
均用 `u64` checked arithmetic；inventory 未知时输出该 `required_min_memory_bytes` 和 `memory=unknown`，由 initrd 硬闸。
Node payload 虽由 agent 切根后下载，仍落在同一 `/run` tmpfs，因此 initrd 必须根据 BootConfig 中受 digest 保护的 size
摘要预留这部分峰值，agent 下载时再次核对实际 size。

### 3.3 validator（每次状态推进检点）

- snapshot 完整性：一次 attempt 全程只消费同一 snapshot digest；中途 Profile/Node 变更不静默影响在途 session。
- digest/feature mismatch、过期 token、越权访问 -> `failed` + quarantine 计数。
- 所有 validator、plan digest、PXE resolver、adapter、retry/drift、show API 必须消费同一 effective plan，
  禁止各自实现 fallback。

### 3.4 反馈闭环

failed/expired 终态、quarantine 计数、rootfs ready 闸回流到 readiness/validator，阻止下一轮 session 在
不满足不变式时启动。`node diskless retry` 清 quarantine 后，readiness 重新校验 snapshot digest 是否仍
有效（desired digest 已变化则 fail closed）。

## 4. rootfs builder

- OS 层：RHEL/Rocky 默认 `dnf --installroot`，Ubuntu 默认 debootstrap + local apt；lorax/livecd 只可作为
  adapter 显式实现；按 local-only 移除公网 mirror/metalink/GeoIP/vendor NTP。
- rootfs-build phase：四类受约束 action（managed-file/archive/script/package）向只读 lower 追加；
  builder 提供 chroot/staging 上下文（按需 bind-mount `/dev`/`/proc`/`/sys` + 匹配内核）。
- rootfs 从 Profile build projection 生成；同一 Profile revision 的 `rootfs_input_digest` 唯一，物理对象可按 digest
  跨 Profile/Node 去重。Node 不参与 input digest；OS 层可按 software capability revision 内部缓存复用。
- diskless Profile password 的 `$6$` hash 按 credential revision 生成一次并持久复用，不使用 install 的 per-session salt；
  password 未变化的普通重建与可复现性验证必须得到相同 shadow bytes，修改 password 才发布新 credential/Profile revision。
- build manifest 记录 builder image/environment digest、工具版本与命令、module/firmware 清单、
  generated locales/timezones/keyboards、完整共享账号/SSH 基线（含 password hash、Profile client/host public
  fingerprints、authorized_keys 与 ssh_known_hosts，不记录私钥内容）、capability revision、
  Profile system/software digest 与输出 squashfs digest/size/uncompressed size。

builder 状态为 `queued -> building -> validating -> ready | failed`，以 `rootfs_input_digest`
去重并持构建 lease。staging 完成完整性/local-only 检查后，先原子发布对象再发布 ready manifest；崩溃遗留
`.part` 不可被 readiness 看见。input digest 覆盖 Profile system/software/target-system（包含 password hash、
Profile SSH client/host keys revision 与公共 authorized_keys/ssh_known_hosts）、source/repository/asset revision、rootfs-build items/assets、
builder ABI、kernel compatibility 与 squashfs 参数；明确排除全部 Node 输入和 machine-id。sandbox 无外网，
Profile SSH private keys 只能从 Profile 绑定的 keys 读取并写入 staging，不得输出到 manifest/日志，并限制
CPU/内存/pid/输出/时间。

`profile rootfs build --new-ssh-keys` 是一个组合操作：若调用方提供 `--if-input-digest`，先校验 Profile 未漂移；
随后由服务端 CSPRNG 生成新的 Profile client keypair/sshd host keys，原子持久化 keys 与 Profile revision，重算 canonical build
projection 后排队构建。operation 必须持久记录 old/new
Profile revision、old/new input digest 和 rotation 已完成标志，使 build 失败后的普通重试不会再次轮换；任何 API、
manifest、event 或日志都不得包含 private key bytes。

## 5. schema 迁移

- catalog `schema_version`：v4（v0.2 唯一标准，同时新增 tagged kind
  `ProfileKind = install|diskless` 与 `rootfs-build|first-boot` tagged action/phase）。v0.1 的 v3 已废弃，不存在版本迁移 CLI 命令。
- BootConfig DTO `schema_version` v3（独立命名空间；v3 增加 capability-authenticated
  `facts_url`，由 initrd 上报 `MemTotal`）。facts 不是启动进度确认：服务端持久化
  inventory 供后续 readiness 预检，当前启动仍必须以本机 `/proc/meminfo` 的
  `MemAvailable` 执行硬闸；facts 上报失败只记录 warning，不能把成功 POST 误判为容量通过。
- AgentPlan DTO `schema_version` v1（独立命名空间）；v0.4 target topology 升 v2，v0.5 保持 v2。
- v0.2.3 Profile identity/provenance 使用 catalog schema v5；v0.3
  `firmware.mode`/`install-post` schema v6；v0.4 schema v7；v0.5 rootfs 形态 schema v8，见
  [`V0_5_DESIGN.md`](V0_5_DESIGN.md)。
- v0.2.2 不提供 `catalog migrate` CLI 命令；schema v4 是其唯一标准。后续版本
  （v0.2.3-v0.5）新增 schema 变更时，rollback 只指 migration transaction finalize 前，按 durable migration journal
  恢复 pre-migration snapshot；它不承诺任意已写入新特性后的版本 downgrade。
- schema downgrade 必须先做 representability preflight。任一资源包含目标旧 schema 无法表达的 kind/field/item 时返回
  `migration.non_representable`，JSON 至少列出 `resource_type/resource_id/path/reason/target_schema`；不得通过 nullable、
  默认值替换、丢字段或丢 collection identity/order 强行降级。
- active/recoverable session、install generation 和 builder attempt 始终消费创建时 immutable delivery snapshot；catalog
  migration apply/rollback/downgrade 不重编译、不改写或撤销这些 snapshot。迁移只能在持久引用仍可保留时 finalize。
- 各版本迁移验收必须覆盖：正向 apply、finalize 前 journal rollback、可表示 downgrade、不可表示 downgrade 和活动
  snapshot 跨迁移继续完成。旧 initrd 未声明 feature 时仅阻止新 readiness/delivery，不静默忽略，也不杀死旧 active snapshot。

## 6. event 脱敏

- token、Authorization、URL query、完整 journal、debug shell 输出不得进服务日志或 Event。
- 脚本 stdout/stderr 仅留最后 2048 bytes 转义摘要；敏感输出按 action 声明规则裁剪。
- 事件 fields 有界、固定含 `source`（`builder`/`runner`）、`node_id`（运行期）、`phase`、`step`、
  `run_id`、action、稳定 reason。

## 7. 制品保留（v0.2 不做 rootfs GC）

- 已发布 rootfs object/manifest 只增不删，不提供 delete/GC CLI，不实现引用计数或 mark/sweep。
- 当前唯一物理布局为
  `assets/diskless/rootfs/<profile>/<rootfs_input_digest前16位>/<profile>.squashfs`；
  完整 input digest、SHA-512、压缩/展开大小仍保存在 `rootfs-artifacts.json`。
  摘要前缀只用于人工分组，不参与不可变校验。
- initrd 唯一物理布局为
  `assets/diskless/initrd/<profile-or-asset-name>/<kernel-release>/initrd.img`；
  source/distro/version/arch provenance 由 catalog 保存。当前为开发版本，不探测、
  迁移或兼容读取 `assets/boot/diskless`、`assets/rootfs` 等旧布局。
- builder 可清理自己未发布的 staging `.part`；这不涉及 ready object。
- `nodeforge status --component rootfs-cache` 报告 bytes/object count/剩余空间和阈值告警；空间不足时新 build
  fail closed，不删除旧对象自救。
- UnknownClientObservation 与 BootSession 元数据仍按各自既有 TTL/审计规则处理，不等同 rootfs GC。

## 8. provision-bundle 八步执行契约

canonical `Phase` 枚举覆盖两条流：`install-post`（v0.3）/`rootfs-build`（v0.2）/`first-boot`（v0.2），
**无 `runtime` phase**。八步顺序固定，任一步失败不得发布 succeeded：

1. bundle CRUD / ordered item mutation。
2. `plan` 预览（无副作用，安装包/改文件/脚本）。
3. `apply` 需目标 revision。
4. item schema 校验（tagged action 字段，parser 拒绝不适用字段）。
5. atomic file replacement / archive 解压规则（[`V0_2_DESIGN.md`](V0_2_DESIGN.md) §5.4）。
6. 执行（按 phase 执行者：rootfs-build=builder，first-boot=agent，install-post=installer）。
7. `status` / `retry`（retry 只重跑明确 retryable 失败 step）。
8. 事件 `provision.step.started/succeeded/warned/failed` + 幂等键 + 日志脱敏。

固定执行顺序：文件更新 -> package -> archive -> script。`repository`/`standard_packages` 旧 action
按迁移表退出，不新增同义 action。

## 9. node list 统一状态 schema（草案）

```text
ID   KIND      PROFILE      STATE                       SESSION    POSTPROCESS  QUARANTINE   SEEN
n01  diskless  diskless-r1  diskless.running            9a2c...    succeeded    ok           2026-07-22T10:00Z
n02  install   rocky-9      install.packages             c017...    -            ok           2026-07-22T10:01Z
n03  diskless  diskless-r1  diskless.failed              4bd1...    -            quarantined  2026-07-22T09:58Z
```

diskless/install 共用一个 tagged lifecycle 投影；install 终态为 `install.completed`，diskless 终态为
`diskless.running`。`POSTPROCESS` 仅对 diskless running 有意义，不是并行状态机。JSON 输出中的
`current` 也必须是 tagged object；禁止同时出现 `install_state` 与 `diskless_state`。

## 10. 验收矩阵（fail-closed 断言）

| 断言 | 预期 |
|---|---|
| rootfs 未 ready 时 DHCP 不发 diskless bootfile | fail closed（诊断 lease 或 deny） |
| Profile kind 非 diskless 时 `node diskless retry` | fail closed |
| desired digest 已变化时 retry | fail closed |
| BootSession 跳跃/回退/错绑 | 拒绝 |
| 同 XID 重传、新 XID 同窗口重传、config 后新 boot 并发 | 前两者复用同 session；只有可验证新 boot 原子 supersede |
| BootConfig 响应中断后重取 | 同 token/同 digest 返回相同 bytes，不重复推进 phase；initrd_started 后撤销 |
| daemon 在 capsule 交付前/中重启 | raw token 未完整送达则 recovery_incomplete；已完整取得 token 才可续跑 |
| 无效 token / 有效 claim 越权 / malformed Range | 不关联 session / 归责 claim session / 416 有界计数，不能远程推进 victim |
| 越权 Range / 跨 Node rootfs 访问 | 拒绝 + failed |
| facts 成功但实际 `MemAvailable` 不足 | initrd 输出完整预算与 deficit，终止于 `memory.capacity_gate` |
| facts 上传失败但本地容量足够 | console warning；本地容量闸继续执行，不因 inventory 写入失败中止 |
| API 建连/空闲，rootfs 或 payload 慢速持续传输 | 建连暂用内核 TCP 有界超时（Zig 0.16 connect deadline 会 panic，见 `V02-D07`）；API 空闲 30 秒；制品空闲 120 秒；持续有进展不受总时长限制 |
| initrd/agent 任一关键步骤失败 | console 必须包含稳定 stage 和 error；initrd 还包含 node/session |
| lifecycle 已到 `diskless.running`，但控制台停在最后一行启动日志 | 分别检查 systemd/SSH/getty；Ubuntu 删除 casper 的 `/lib/systemd/system/getty@tty1.service -> /dev/null` 和 Subiquity drop-in，恢复 tty1；冷启动必须自然出现 login prompt |
| 过期 token / feature mismatch / hash mismatch | failed + quarantine 计数 |
| initrd 或 rootfs agent 缺各自 required feature | readiness 失败，不发 bootfile；initrd 不代行 agent feature |
| shared override registry set 与“v0.1 install 去除 `overrides.install.*` 再加 v0.2 shared additions”不相等 | contract test 失败；禁止以 diskless 小 allowlist 发布 |
| 任一已注册 diskless shared Node override 没有 agent pre-init consumer 或 prerequisite | compile/readiness 失败，不能接受后忽略 |
| Node software repository 使用 URL/未 pin capability，或 remove 命中 protected closure | mutation/compile/readiness 失败，不生成降级 projection |
| Node first-boot override 含 rootfs-build item | mutation/compile 失败；不按 Node 构建 rootfs，也不静默跳过该 item |
| AgentPlan digest/size/claim/path 不符或拉取失败 | agent pre-init 失败；真正 init 不启动，不使用本地旧 plan fallback |
| Node first-boot payload digest/size 不符或 agent 缺 feature | agent pre-init 失败；真正 init 不启动，不执行 Profile payload 作为 fallback |
| 传输 token 被用于管理 API | 拒绝（不同凭据类型） |
| agent pre-init node-apply 失败 | 真正 init 不启动；`diskless.failed` + quarantine 计数，不回退 Profile payload |
| agent first-boot 失败 | 节点仍为 `diskless.running`，该 step failed，`postprocess=degraded` |
| 事件回传失败 | 本地兜底，不阻塞后处理 |
| rootfs-build step 失败 | 阻止 rootfs ready，不发 succeeded |
| canonical phase 含 `runtime` | 不存在（永久非目标） |
| daemon 在 config/download/event 阶段重启 | 客户端已持 raw token 时以持久 record/hash 恢复相同 snapshot，不重新编译 |
| 新 PXE session 遇到旧 step success | 不跨启动跳过；新 session 全量执行 |
| 首次完整 hash mismatch | 删除 partial、从 0 完整重试，不立即 quarantine |
| ETag 变化 / If-Range 返回 200 | 截断 partial，禁止 append 跨版本内容 |
| squashfs 下载 + upper 内存不足 | readiness 尽量提前拒绝，initrd 实测再次 fail closed |
