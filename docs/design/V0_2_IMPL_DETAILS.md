# NodeForge v0.2 实现细节

状态：设计冻结，实现未开始。本文细化 v0.2 diskless 主流程的三项核心闭环实现，优先级
**1 -> 2 -> 3**：BootSession 状态机 -> server DHCP/TFTP/HTTP 协议栈 -> effective compiler/
readiness/validator。与 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) 一致；程序边界见
[`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md)，CLI 见 [`V0_2_CLI.md`](V0_2_CLI.md)。

## 0. 核心闭环控制流

三项优先级按控制流闭环串接，方向 **3 -> 2 -> 1 -> 3**：

```text
(3) effective compiler/readiness/validator
  -- 产出 pinned DisklessEffectivePlan + plan digest + readiness 闸 -->
(2) DHCP/TFTP/HTTP 协议栈
  -- 驱动 canonical BootSession 状态迁移、发协议事件 -->
(1) BootSession 状态机
  -- 状态迁移映射回校验源（digest/feature/quarantine）-->
(3) 反馈闭环（readiness + validator 双检点、pin 完整性不变式）
```

- **校验源映射**：协议事件 -> 状态迁移 -> 校验源（plan digest、feature 子集、token 越权、quarantine
  预算）三层必须可追溯到同一 pinned effective plan。
- **双检点**：readiness（发布前，Profile/Node/capability/rootfs 就绪）+ validator（每次状态推进，
  digest/feature/quarantine 不变式）。
- **pin 完整性不变式**：一次 boot attempt 全程只消费同一个 pinned DisklessEffectivePlan digest，
  中途 Profile/Node 变更不静默影响在途 session。
- **反馈闭环**：failed/expired 终态、quarantine 计数、rootfs ready 闸回流到 readiness/validator，
  阻止下一轮 session 在不满足不变式时启动。

## 1. BootSession 状态机（优先级 1）

### 1.1 canonical 状态迁移

```text
dhcp_discover -> dhcp_offer -> dhcp_ack -> tftp_rrq -> tftp_complete
  -> boot_config_fetched -> initrd_started -> rootfs_downloading
  -> rootfs_verified -> rootfs_mounted -> switching_root -> diskless_running
```

- `failed` 可从任一非终态进入，`expired` 只能由服务端超时进入；两者均为本次 session 终态。
- 重复同阶段上报幂等；跳跃、回退、错绑 node/session 一律拒绝。
- 历史 `pxe_seen`/`bootfile_sent`/`diskless_config_fetched` 是 `dhcp_discover`/携带 bootfile 的
  `dhcp_ack`/`boot_config_fetched` 的展示别名，不是额外持久状态。v0.2 API/Event/持久化只用
  canonical 名。

### 1.2 install 与 diskless 分离

当前 `src/state/boot_session.zig` 的 `Phase` 枚举把 install 侧阶段（`installer_started`/
`installing`/`installed`/`provisioning`/`completed`）与 diskless 侧阶段混排。v0.2 实施：

- canonical BootSession 只覆盖 DHCP/TFTP/boot_config 共享前缀 + diskless 尾部。
- install Profile 的 BootSession 在 `boot_config_fetched` 完成交付后**终止**；installer 进度
  （`installer_started`/`installing`/`installed`/`provisioning`/`completed`）移出 BootSession，
  仅在 `node_status` 部署投影保留。
- BootSession（传输态）与 deployment 投影（node_status）职责分离。

### 1.3 node_status 投影与 node list 统一状态

`node_status` 投影必须沿用 canonical 名：diskless 终态投影为 `diskless_running`，不得新增独立
`running` 别名；早期 PXE/TFTP 诊断状态在投影中保留，不可折叠为 `ready/booting/downloading` 等粗粒度
枚举而丢失早期诊断证据。

`node list`/`node status` kind 感知投影统一 schema（设计名 `ProfileKind` = 代码 `BootKind`
`model.zig:329`，v0.2 扩 `install|diskless`）：

| 列 | 说明 |
|---|---|
| `ID` | Node id |
| `KIND` | `install` 或 `diskless`（来自 effective Profile kind） |
| `PROFILE` | 绑定 Profile |
| `BOOT_SESSION` | canonical BootSession phase（未启动为 `-`） |
| `DEPLOYMENT` | node_status 部署投影（install 侧 installer 进度 / diskless 侧 first-boot 投影） |
| `QUARANTINE` | boot gate 状态（`ok`/`quarantined`） |
| `SEEN` | 按 kind 泛化的最近活动时间戳 |

### 1.4 quarantine 与 retry

- Quarantine 是 **Node 级 boot gate**，不是 BootSession phase。一次 attempt 进入 `failed` 后按 pinned
  `max_attempts`/`backoff_seconds` 计数；达到预算才进入 quarantine，并拒绝新 session。
- `diskless_running` 是启动成功终态；切根后 agent `first-boot` 后处理失败属 M7 运行期，不回写或倒退
  已完成 BootSession。
- `nodeforge node diskless retry <node>` 只清除终态 failure quarantine；不创建 install generation、
  不修改 Profile、不远程重启。存在活动 session、`deploy=false`、Profile 非 diskless 或 desired digest
  已变化时 fail closed。

## 2. server DHCP/TFTP/HTTP 协议栈（优先级 2）

### 2.1 DHCP

- 按 canonical BootSession 驱动：未知客户端按 v0.1 discovery policy（`record|deny`）；已认领/绑定
  Profile 的 diskless Node 发放诊断 lease 并下发 boot bundle bootfile（GRUB UEFI）。
- **rootfs ready 闸**：`dhcp_discover` -> `dhcp_offer` 前校验该 Node 的 pinned rootfs 已 ready
  （digest 存在、builder succeeded）；未 ready 时不发 diskless bootfile（fail closed，可返回诊断 lease
  或 deny，按策略）。
- kernel cmdline 携带 `nodeforge.config_url` 与 `kernel_args`。

### 2.2 TFTP

- 交付 boot bundle（kernel + NodeForge initrd）。TFTP 完成推进到 `tftp_complete`。
- 越权/损坏/中断进 `failed`，记稳定 reason。

### 2.3 HTTP

- **BootConfig 路由**：`config_url` 经 node-bound capability token 鉴权，按 pinned
  DisklessEffectivePlan 生成 per-boot DTO；token 绑定 node/session/method/path 与短有效期。
- **rootfs 路由**：node-bound GET/HEAD/Range，按 effective digest 共享 lower；支持 Range 恢复、
  ETag、sha512 校验。
- **event 路由**：agent `provision.step.*` best-effort POST，绑定 node/session。
- 越权 Range、过期 token、跨 Node rootfs 访问一律拒绝，进 `failed`。

## 3. effective compiler / readiness / validator（优先级 3）

### 3.1 effective compiler

```text
DisklessEffectivePlan = compile(resource capabilities, diskless profile policy,
                                node direct facts, node overrides)
```

- 与 v0.1 install 复用同一 compiler、同一 plan digest；diskless 分支只消费 pinned
  DisklessEffectivePlan，不建立第二套 users/packages/network 默认值。
- target-system、software、kernel arguments 直接复用 v0.1 effective compiler。
- diskless 不消费安装磁盘选择器，但复用同一 Profile/Node override 模型。

### 3.2 readiness（发布前检点）

发布 diskless readiness 前，Profile/Node/capability/rootfs 必须全部就绪：

- Profile `kind=diskless`，boot bundle 的 kernel/initrd/rootfs 与 kernel release 联合校验通过。
- rootfs lower 已 builder succeeded（digest 存在）。
- `required_features` 与 initrd boot bundle manifest 声明的 feature 子集一致。
- 旧 initrd 未声明对应 feature 时，引用含 target-system/静态网络 override 的 Profile 必须在发布
  readiness 阶段失败。

### 3.3 validator（每次状态推进检点）

- pin 完整性：一次 attempt 全程只消费同一 pinned digest；中途 Profile/Node 变更不静默影响在途 session。
- digest/feature mismatch、过期 token、越权访问 -> `failed` + quarantine 计数。
- 所有 validator、plan digest、PXE resolver、adapter、retry/drift、show API 必须消费同一 effective plan，
  禁止各自实现 fallback。

### 3.4 反馈闭环

failed/expired 终态、quarantine 计数、rootfs ready 闸回流到 readiness/validator，阻止下一轮 session 在
不满足不变式时启动。`node diskless retry` 清 quarantine 后，readiness 重新校验 pinned digest 是否仍
有效（desired digest 已变化则 fail closed）。

## 4. rootfs builder

- OS 层：RHEL 系 lorax/livecd-creator/mkksiso；Ubuntu debootstrap/live-build；按 local-only 移除公网
  mirror/metalink/GeoIP/vendor NTP。
- rootfs-build phase：四类受约束 action（managed-file/archive/script/package）向只读 lower 追加；
  builder 提供 chroot/staging 上下文（按需 bind-mount `/dev`/`/proc`/`/sys` + 匹配内核）。
- rootfs 按 effective digest 缓存、跨 Node 共享；OS 层可按 software capability revision 内部缓存复用
  （对设计透明、不作为独立 Resource）。
- build manifest 记录 builder image/environment digest、工具版本与命令、module/firmware 清单、
  generated locales/timezones/keyboards、user 骨架（不含密码/key）、capability revision、effective
  system/software digest 与输出 squashfs digest/size/uncompressed size。

## 5. schema 迁移

- catalog `schema_version`：v3（v0.1 冻结）/ v4（v0.2 新增 tagged kind `ProfileKind = install|diskless`）。
- BootConfig DTO `schema_version` v2（独立命名空间）。
- v0.3 `firmware.mode` schema v5；v0.5 rootfs 形态字段见 [`V0_5_DESIGN.md`](V0_5_DESIGN.md)。
- 迁移支持 plan/apply/rollback；旧 initrd 未声明 feature 时 readiness 失败，不静默忽略。

## 6. event 脱敏

- token、Authorization、URL query、完整 journal、debug shell 输出不得进服务日志或 Event。
- 脚本 stdout/stderr 仅留最后 2048 bytes 转义摘要；敏感输出按 action 声明规则裁剪。
- 事件 fields 有界、固定含 `source`（`builder`/`runner`）、`node_id`（运行期）、`phase`、`step`、
  `run_id`、action、稳定 reason。

## 7. GC

- rootfs 按 effective digest 引用计数缓存；无引用的旧 digest 可回收，回收不切断在途 session（pin 不变式）。
- UnknownClientObservation 按 retention 过期；已 claimed audit 不受普通 retention 清理影响。
- BootSession 终态 session 按 TTL 清理，审计保留。

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
ID   KIND      PROFILE      BOOT_SESSION        DEPLOYMENT          QUARANTINE   SEEN
n01  diskless  diskless-r1  diskless_running    first-boot:ok       ok           2026-07-22T10:00Z
n02  install   rocky-9      boot_config_fetched installing          ok           2026-07-22T10:01Z
n03  diskless  diskless-r1  failed               -                   quarantined  2026-07-22T09:58Z
```

diskless/install 状态机统一；install 终态投影为 `completed`，diskless 终态投影为 `diskless_running`；
两者均不在 BootSession 中混排 installer 进度。

## 10. 验收矩阵（fail-closed 断言）

| 断言 | 预期 |
|---|---|
| rootfs 未 ready 时 DHCP 不发 diskless bootfile | fail closed（诊断 lease 或 deny） |
| Profile kind 非 diskless 时 `node diskless retry` | fail closed |
| desired digest 已变化时 retry | fail closed |
| BootSession 跳跃/回退/错绑 | 拒绝 |
| 越权 Range / 跨 Node rootfs 访问 | 拒绝 + failed |
| 过期 token / feature mismatch / hash mismatch | failed + quarantine 计数 |
| 旧 initrd 缺 target-system feature | readiness 失败，不发 bootfile |
| 传输 token 被用于管理 API | 拒绝（不同凭据类型） |
| agent first-boot 失败 | 节点仍启动、该 step failed，不回写 BootSession |
| 事件回传失败 | 本地兜底，不阻塞后处理 |
| rootfs-build step 失败 | 阻止 rootfs ready，不发 succeeded |
| canonical phase 含 `runtime` | 不存在（永久非目标） |
