# NodeForge v0.3 设计：PXELINUX/BIOS install

状态：设计冻结，实现未开始。本文定义 v0.3 范围，与 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §2 版本表一致。
v0.3 在 v0.2.3 完成（[`V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md`](V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md) §10
完成标准）后启动。跨版本顺序见
[`V0_2_1_PLUS_ROADMAP.md`](V0_2_1_PLUS_ROADMAP.md)，实现细节与状态机见
[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md)，共用 CLI 契约见 [`V0_2_CLI.md`](V0_2_CLI.md) §0，
程序边界见 [`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md) §7。

## 1. 进入条件

v0.3 必须基于 v0.2.1/v0.2.2/v0.2.3 完成：

- v0.2.3 catalog schema v5（`ProfileKind = install|diskless`、Profile identity/provenance）冻结，canonical BootSession 状态机、
  DHCP/TFTP/HTTP 协议栈与 effective compiler/readiness/validator 三项核心闭环已落地并通过验收。
- v0.2 schema v4 已存在的受限 `install-post` 兼容 runner 回归通过；`rootfs-build|first-boot`
  四类 action 与八步执行契约已统一，v0.3 在此基础上扩展 install-post。
- v0.2.2 的持久状态升级兼容、durable operation、CLI 收口与固定回归矩阵全部通过。
- v0.1 install 侧 PXE/adapter/effective 在 v0.2 期间保持回归通过。

任何一项未完成时，v0.3 只能做隔离 spike，不能合入主产品路径。

## 2. 范围

v0.3 聚焦 **BIOS PXELINUX install 与发行版版本矩阵**，对应 M6（BIOS/发行版）与 M7 `install-post`：

| 项 | v0.3 范围 | 说明 |
|---|---|---|
| BIOS x86 PXELINUX | 是 | `firmware.mode=bios` Node direct 属性，schema v6 |
| 发行版版本矩阵 | 是 | Rocky/RHEL 系与 Ubuntu 后续 LTS 的显式 adapter capability matrix |
| bootloader/版本差异/错误分类 | 是 | 长期运行回归 |
| 最小功能并发/失败恢复 | 是 | 大规模容量压测延后 v0.4 |
| `install-post` canonical 扩展 | 是 | phase/受限兼容 runner 已存在；v0.3 补四类 action、callback/journal 与完成闸 |

v0.3 **不**包含：多 NIC/VLAN/bonding、PXE 阶段纯静态、下载后切换地址/子网、大规模容量压测（-> v0.4）；
install 侧 first-boot agent（-> v0.4）；reconciliation/远程控制（永久非目标）。

## 3. 从 v0.1/v0.2 继承的强制契约

- v0.1 所有权模型、`/dev/...` 磁盘契约、`software.*` 双集合、`kernel_args.add/remove`、明文 password/默认用户不变式。
- v0.1 UEFI install 全部能力（单盘/LVM/RAID/RAID-LVM、repository/software capability、effective compiler）原样保留。
- v0.2 canonical phase 集合（`install-post|rootfs-build|first-boot`，无 `runtime`）、四类 action、八步执行契约、
  credential/session/lower 边界、finalizer、事件脱敏与幂等键不变。
- v0.2 diskless Node override 契约不变：initrd 只完成传输、挂载和不可变 handoff；最终 rootfs 内的 agent pre-init
  在真正 init 前统一应用静态配置与 software/service/security `node-apply`，随后 exec init；Node first-boot override payload
  由 agent pre-init 按 session-pinned AgentPlan 预取，全部 Node 差量都不分裂共享 rootfs。
- v0.2 统一 `node list`/`node status` kind 感知投影（`KIND` 列、canonical BootSession phase）；install 侧
  installer 进度移出 BootSession，仅在 `node_status` 部署投影保留。
- `show key == --help-full key == parser key == API operation path`；CLI 不得要求 Shell 内嵌 JSON。

## 4. firmware.mode 与 BIOS 引导

### 4.1 firmware.mode

- 新增 Node direct `firmware.mode=uefi|bios`（schema v6）；**不**放入 Profile 或 `overrides`。
- schema v5 到 v6 采用直接替换（不迁移，见 v0.2.3 设计 §0）；旧 v5 catalog
  不被加载，操作员需重新 `setup`，新认领 Node 必须由管理员确认 desired `firmware.mode`。
- DHCP observed firmware 只用于 mismatch/readiness 检查，不自动改写 desired property。
- partition policy 仍用 v0.1 逻辑磁盘角色，由 effective compiler 结合 firmware 生成 ESP/biosboot 要求。
- `node.http_accel` 继续只适用于 UEFI GRUB；BIOS PXELINUX capability 必须报告 `property.not_applicable`，
  不能接受后静默忽略，也不能为 BIOS 新增另一个同义传输开关。
- `http_accel` 治理 GRUB 在 PXE 阶段用 HTTP 取 kernel/initrd 的传输路径（install 与 diskless 共用，仅 UEFI）；
  它不治理 initrd 自身用 node-bound capability route 发起的 rootfs GET/HEAD/Range 下载（始终走受认证 HTTP 路由）。

### 4.2 BIOS PXELINUX boot target

- BIOS x86 经 PXELINUX 引导；UEFI 继续用 GRUB。
- `boot/target.zig` 新增 BIOS 分支消费 pinned install effective plan；与 v0.2 diskless 分支并列，不互相 fallback。
- v0.3 的 BIOS 范围只覆盖 `kind=install`。`kind=diskless + firmware.mode=bios` 在 readiness 返回
  `property.not_applicable`；diskless BIOS 未经独立版本设计与验收不得借 PXELINUX 分支顺带开放。
- BIOS 与更多发行版版本彼此独立，不能捆绑实现。

## 5. install-post phase（安装器执行）

`install-post` 由安装器在安装期执行，**无 agent**，属 install：

| 维度 | install-post（v0.3） |
|---|---|
| 执行者 | 安装器（Kickstart `%post` / Autoinstall `late-commands`），无 nodeforge-agent |
| 目标上下文 | 安装中目标系统磁盘（已分区/格式化），`/` 为安装目标根 |
| 持久化 | 写磁盘（install 永久） |
| 触发 | 安装器渲染时嵌入 bundle 引用，安装期执行 |
| 失败语义 | retryable step 只在同一 installer execution 内按声明自动重试；耗尽后令 deployment 进入 `install.failed` |

- 复用 v0.1 已有最小 install-post provision bundle（managed-file asset 驱动），**不改变其 Assets owner**。
- v0.3 将既有 phase 扩展为完整四类 action（managed-file/archive/script/package）；旧 `repository`/
  `standard_packages` 按 v0.2 §5.2 迁移表退出，不新增同义 action。
- package action 只引用 pinned effective software/capability，经本地 repository 解析校验、幂等。
- archive 规则与 v0.2 一致：顶层 `./install.sh` 则解压到临时目录执行；否则解压到 `/`。
- 八步执行契约固定顺序：文件更新 -> package -> archive -> script；action 可修改安装目标根的
  users/SSH/hosts/系统文件，credential/session 越权在 plan/validate 阶段拒绝，不能用 `--force`
  绕过；finalizer 末尾重新断言 effective 顺序与离线策略。
- Profile 引用：`install.post_install.bundle`（与 diskless 的 `diskless.provision.bundle` 对应）。
- `install-post` 是 deployment 完成闸：所有 step/finalizer 成功后才允许 `install.completed`；失败不回写已经终止的
  BootSession，但会终止当前 install generation。v0.3 不提供远程 step retry；重新执行必须由新的 install generation
  完整重装，不能在已安装目标上远程补跑。
- install-post journal/status 以 `(node_id, install_generation, bundle_revision, plan_digest, step_id)` 标识，不能复用
  diskless `boot_session_id` 假装安装器执行属于 BootSession。
- install renderer 复用该 generation 的 append-only callback credential 上报 step/finalizer 状态。raw token 在 generation
  创建时生成，通过随 installer initrd 加载的 per-generation credential capsule 交付到
  `/run/nodeforge/credentials/install-callback.token`（0400），不得进入 kernel cmdline、catalog、公开渲染模板或日志；
  服务端只保存不可逆 hash。credential 绑定 `node_id/install_generation/plan_digest/audience/method/path/expiry`，并按
  单调 `event_seq` 去重；它不能读取 catalog、触发 retry 或升级为 management credential。generation 终态/超时后立即
  撤销；daemon restart 后用持久 hash 继续验证，不能为同一 generation 静默生成第二个并行有效 token。
  `node_id + install_generation` 只是关联键，不能单独作为认证证明。
  raw capsule token 只驻内存：restart-resume 只保证 installer 已完整取得 token 后的 callback 阶段。capsule 尚未开始或
  传输中重启且 installer 未取得完整 token时，本 generation attempt 标 `generation.recovery_incomplete`，不得由 hash
  重建 token；下一次安装启动创建新 generation。持久化 capsule delivery started/completed 只用于审计和错误分类。

## 6. 发行版版本矩阵

- Rocky/RHEL 系与 Ubuntu 后续 LTS 的显式 adapter capability matrix：声明每个 (distro, version, arch) 支持的
  storage mode、software kind（environment/group/task/metapackage/package）、bootloader 与 firmware。
- bootloader、发行版版本差异、错误分类与长期运行回归。
- 对当前 adapter 不适用的 kind 返回 `software.kind_not_applicable` 并列出 `supported_kinds`，不能返回易误判的空列表。
- adapter 不能在配置路径不存在或不适用时猜测，也不能实现运行时 fallback。

## 7. CLI（v0.3）

> 完整 CLI 约定见 [`V0_2_CLI.md`](V0_2_CLI.md) §0；本节给 v0.3 新增。

```text
nodeforge node set <node> firmware.mode=bios              # schema v6
nodeforge profile set <profile> install.post_install.bundle=<bundle>
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=install-post action=managed-file content_asset=<asset> destination=/etc/motd \
  mode=0644 owner=root group=root idempotency_key=<key> timeout_s=30 retryable=false
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=install-post action=package packages=tmux,nmap \
  idempotency_key=pkgs timeout_s=600 retryable=true
nodeforge node postprocess show <node> --phase install-post [--generation <id>]
```

- `profile set ... install.post_install.bundle` 与 provision-bundle owner 沿用 v0.2 现有入口；
  v0.3 新增的是 canonical action 接受范围、generation status/callback 和 BIOS 属性。
- `firmware.mode` 是 Node direct 字段，不经 `overrides`；不适用 BIOS 的属性返回 `property.not_applicable`。
- `postprocess` 统一命名（同 v0.2）：install 侧的 install-post phase 也用 `node postprocess show` 查询，
  不用 `postinstall`，避免与 diskless 命名分叉。省略 `--generation` 时查询最近一个 install generation；无历史时
  返回空结果 exit 0。`--session` 只适用于 diskless first-boot，不能和 `--generation` 混用。
- `node list`/`node show` 增加 `FIRMWARE` 列（`uefi`/`bios`）；`node show` 输出 `firmware.mode` direct 字段。
- BIOS readiness 在 `node readiness --stage boot` 中增加 PXELINUX capability 检查、BIOS bootloader 资产存在性、
  `http_accel` 对 BIOS fail-closed 校验；diskless BIOS 直接 not-applicable。不通过时返回逐项 reason + `next_command`。
- `install-post` phase token 在 schema v4/parser 中已经存在，且兼容 runner 支持 repository、
  standard-packages 与 managed-file 子集；v0.3 才接受 archive/script/package 等 canonical 新形态，
  同时给旧形态明确迁移与拒绝边界。
- v0.3 不提供多 NIC/VLAN/bonding、容量压测、install 侧 agent 的 CLI（属 v0.4/永久非目标）。

## 8. 明确非目标（v0.3 增量）

- 多 NIC/VLAN/bonding、PXE 阶段纯静态、下载后切换地址/子网 -> v0.4（需显式 initrd/agent consumer feature、schema 和验收）。
- 大规模容量压测 -> v0.4。
- install 侧 first-boot agent -> v0.4（确定性，无 reconciliation）。
- reconciliation/远程控制 -> 永久非目标（全版本）。
- IPv6、by-id/serial/WWN -> 永久非目标（继承 v0.1）。
- v0.3 不提供 v0.4/v0.5 命令的 help/handler；预留 enum 不算实现。

## 9. 完成标准

- schema v6 直接替换（不迁移），旧 v5 catalog 不被加载；活动 snapshot
  保护和 digest 预览通过。
- `firmware.mode` claim/config、DHCP observed mismatch、readiness 和 digest 覆盖完整。
- BIOS x86 PXELINUX 引导、安装、登录、事件、install generation 重试/drift 与 daemon restart-resume 回归通过；
  diskless BIOS readiness 负向测试稳定拒绝。
- 显式 adapter capability matrix 覆盖目标 Rocky/RHEL 与 Ubuntu LTS；不适用 kind 返回 `property.not_applicable`。
- `install-post` phase 在同一 Assets owner 上实现四类 action、八步契约、credential/session 边界/finalizer、plan/status、同次安装
  自动 step retry；耗尽后阻止 `install.completed`，且不存在远程 step retry。`standard_packages` 已退出。
- install-post callback credential 的 capsule 权限/泄漏检查、generation/plan 绑定、重放、过期、跨 Node 越权与 daemon
  restart-resume 负向测试通过；测试必须区分 capsule 交付前/中 `recovery_incomplete` 与 token 已交付后的 hash 验证恢复；
  未经认证的 node/generation 事件不能推进 deployment。
- `node list`/`node status` 对 install BIOS/UEFI 与 diskless 统一投影，installer 进度仅在 `node_status` 保留。
- 本审计与版本设计、配套文档同步更新；预留 enum/空 handler 不算实现证据。
