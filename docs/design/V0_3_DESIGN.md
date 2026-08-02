# NodeForge v0.3 设计：install-post canonical 扩展

状态：已实现，并于 2026-08-02 完成 fresh 双机发布闸。本文定义 v0.3 范围，与
[`V0_2_DESIGN.md`](V0_2_DESIGN.md) §2 版本表一致。
v0.3 在 v0.2.3 完成（[`V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md`](V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md) §10
完成标准）后启动。跨版本顺序见
[`V0_2_1_PLUS_ROADMAP.md`](V0_2_1_PLUS_ROADMAP.md)，实现细节与状态机见
[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md)，共用 CLI 契约见 [`V0_2_CLI.md`](V0_2_CLI.md) §0，
程序边界见 [`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md) §7。

BIOS x86 PXELINUX 已从本版本剥离，独立设计见
[`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)。

## 发布结论

**结论：v0.3 install-post canonical 能力在当前 aarch64 双机环境中 PASS，可以按本文
边界发布。**

该结论由三类证据共同支撑：Zig/CLI/HTTP/setup 自动化；Rocky 9.7 install-post
generation 3 真实 PXE E2E；Rocky 9.7、Rocky 10.2、Ubuntu 的两项 install 与三项
diskless VMware 矩阵。完整命令、摘要、journal 和 Compute Use 操作边界见
[`../validation/V0_3_VALIDATION.md`](../validation/V0_3_VALIDATION.md)。

发布结论只覆盖本文范围，不代表 BIOS PXELINUX、多 NIC/VLAN/bonding、规模容量或其他
未执行平台已经验证。旧 `repository`/`standard_packages` 被拒绝是预期产品结论，
不是待补兼容项。

## 前置裁决：冲突、实施前提与明确禁止

本节优先级高于本文其他章节以及历史审计中与其冲突的表述。

### 冲突裁决

1. **不迁移旧语义**：v0.3 只按最新 canonical 设计实施，不兼容 v0.2.x
   install-post 的 `repository`/`standard_packages` action，不提供读取兼容、自动转换、
   手工迁移工具或双写期。测试 catalog/bundle 按 v0.3 设计重新创建。
2. **schema 版本只表达持久化 shape**：install-post action 仍使用 catalog v5 已有的
   `ProvisionAction` shape，因此 catalog schema 保持 v5。同一 schema 号不承诺不同
   NodeForge 产品版本之间继续接受已经退出的旧语义。
3. **callback 复用现有启动凭据**：install-post 不新建 per-generation raw token、
   credential capsule 或 claim 协议。安装器复用当前 BootSession callback credential；
   服务端在 `installer.started` 后把该 session 固定到当前 install generation。认证归
   BootSession，journal/status/completion 归 install generation，两者不得混为一个状态主键。
4. **archive 先检查、后解压**：运行期先以 `tar -tf` 读取顶层条目，判定是否存在
   `install.sh`/`./install.sh`，再选择执行或直接解压。不得为了判定模式先解压 archive。
5. **统一术语**：`managed_file -> package -> archive -> script` 称为“四类 action
   固定顺序”；“八步执行契约”只指 pin/validate、materialize、四类 action、finalizer、
   publish 的执行生命周期，不再把 CRUD/plan/apply/status 称为另一套八步。

### 实施前提

- 使用受信管理域内由操作员导入的本地 Asset；v0.3 不把 archive/callback 设计成面向
  多租户或不可信公网的通用上传、任务执行平台。
- BootSession callback credential 已能完成现有 installer 事件认证，并能在 daemon
  restart 后按现有规则继续验证；若现有 session 无法恢复，本次安装确定失败并由新
  generation 重装，不为 v0.3 另建 token 恢复协议。
- `installer.started` 是 session 固定到 armed install generation 的唯一时点；固定后
  Node、generation、plan digest 不得改绑。
- archive Asset 在导入时完成 tar 可读性、绝对路径和 `..` 路径组件检查并固定 SHA-256；
  runner 只执行已发布且 digest 匹配的 Asset。

### 明确禁止

- 禁止 legacy action 的兼容读取、隐式转换、运行时 fallback 或迁移命令。
- 禁止新增 generation credential capsule、一次性 claim endpoint、raw token 注入
  installer initrd、capsule delivery started/completed 状态和对应 recovery 分支。
- 禁止仅凭请求 body 中的 `node_id`/`generation` 推进状态；必须由已认证 BootSession
  和服务端固定关联得到 Node/generation。
- 禁止用 BootSession id 作为 install-post journal 主键，或把 install generation
  状态回写成 diskless BootSession journal。
- 禁止 archive 为判断 `install.sh` 而预解压，禁止子目录 `install.sh` 自动执行，
  禁止为 archive 恢复 `destination` 字段。

## 0. 设计动机与代码基线

v0.2.3 完成时，install-post phase 在代码中只支持三种受限动作
（`repository`、`standard_packages`、`managed_file`），而 rootfs-build/first-boot
已经使用四类 canonical action（`managed_file`/`archive`/`script`/`package`）。
install-post 的能力缺口是当前最大的实现差异：

| 维度 | rootfs-build / first-boot（v0.2 已实现） | install-post（v0.3 前基线） |
|---|---|---|
| 支持动作 | `managed_file`/`archive`/`script`/`package` | `repository`/`standard_packages`/`managed_file` |
| 执行契约 | 八步固定顺序 + 隔离执行 | 声明顺序，无隔离 |
| callback credential | per-session scoped token | 复用 BootSession bearer token，尚未固定到 install generation |
| journal/status | `(boot_session_id, step_id)` journal | 无结构化 journal |
| 错误恢复 | retryable step 自动重试 + failure budget | 无自动重试 |

v0.3 关闭这组差异：把 install-post 从受限形态升级为完整 canonical phase，
与 rootfs-build/first-boot 统一执行模型，并补齐 callback generation 绑定。

**不引入 catalog schema 变更**：`firmware.mode` 随 BIOS 一起延后
（见 [`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)）；
install-post 的四类 action 在 `ProvisionAction` enum 中已存在
（`src/model.zig`），只是 runner/validator 尚未接受。
因此 v0.3 **保持 catalog schema v5**，BootConfig v3 和 AgentPlan v1 不变。

## 1. 进入条件

v0.3 必须基于 v0.2.1/v0.2.2/v0.2.3 完成：

- v0.2.3 catalog schema v5（Profile identity/provenance）冻结，
  canonical BootSession 状态机、DHCP/TFTP/HTTP 协议栈与 effective
  compiler/readiness/validator 三项核心闭环已落地并通过验收。
- v0.2 schema v4 已存在的受限 `install-post` 兼容 runner 回归通过；
  `rootfs-build|first-boot` 四类 action 与八步执行契约已统一，
  v0.3 在此基础上扩展 install-post。
- v0.2.2 的持久状态升级兼容、durable operation、CLI 收口与固定回归矩阵全部通过。
- v0.1 install 侧 PXE/adapter/effective 在 v0.2 期间保持回归通过。

任何一项未完成时，v0.3 只能做隔离 spike，不能合入主产品路径。

## 2. 范围

v0.3 聚焦 **install-post canonical 扩展**：

| 项 | v0.3 范围 | 说明 |
|---|---|---|
| install-post 四类 canonical action | 是 | 扩展 `renderInstallPost` 接受 `managed_file`/`archive`/`script`/`package` |
| 旧受限 action 退出 | 是 | `repository`/`standard_packages` 直接退出，不迁移、不兼容、不新增同义 action |
| install-post callback credential | 是 | 复用 BootSession credential，固定到 install generation；不新增 token/capsule |
| install-post journal/status | 是 | `(node_id, install_generation, bundle_revision, plan_digest, step_id, attempt)` 标识 |
| 错误分类与长期运行回归 | 是 | bootloader/版本差异/错误分类 |

v0.3 **不**包含：BIOS PXELINUX（独立延后，见
[`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)）；多 NIC/VLAN/bonding、
大规模容量压测（-> v0.4）；install 侧 first-boot agent（-> v0.4）；
reconciliation/远程控制（永久非目标）。

## 3. 从 v0.1/v0.2 继承的强制契约

- v0.1 所有权模型、`/dev/...` 磁盘契约、`software.*` 双集合、`kernel_args.add/remove`、
  明文 password/默认用户不变式。
- v0.1 UEFI install 全部能力（单盘/LVM/RAID/RAID-LVM、repository/software capability、
  effective compiler）原样保留。
- v0.2 canonical phase 集合（`install-post|rootfs-build|first-boot`，无 `runtime`）、
  四类 action、八步执行契约、credential/session/lower 边界、finalizer、事件脱敏与
  幂等键不变。
- v0.2 diskless Node override 契约不变。
- v0.2 统一 `node list`/`node status` kind 感知投影。
- `show key == --help-full key == parser key == API operation path`；CLI 不得要求
  Shell 内嵌 JSON。

## 4. install-post canonical 扩展

### 4.1 当前实现状态

`src/provision/runner.zig` 的 `renderInstallPost` 当前只处理三种动作：

- `repository`：添加 dnf/apt 仓库（`dnf config-manager --add-repo` 或
  `echo > sources.list.d/`）
- `standard_packages`：安装包列表（`dnf -y install` 或
  `DEBIAN_FRONTEND=noninteractive apt-get -y install`）
- `managed_file`：写入受管文件（`printf %b` 或 `curl + sha256sum -c`）

对 `archive`/`script`/`package` 三类 canonical action，`renderInstallPost` 返回
`error.InvalidStep`。这意味着 install-post 无法使用 rootfs-build/first-boot 已经
支持的完整 provision 能力。

`src/profile/adapter/kickstart.zig` 和 `src/profile/adapter/ubuntu.zig` 在 `%post`
（Kickstart）或 `late-commands`（Autoinstall）中调用 `renderInstallPost` 嵌入安装后
步骤。事件上报通过 `%post` 末尾的 `curl` 命令携带 bearer token 和 session id。

### 4.2 目标模型

v0.3 将 install-post 扩展为与 rootfs-build/first-boot 一致的完整 canonical phase：

**四类 canonical action**（统一，跨三个 phase）：

| action | install-post 执行上下文 | 说明 |
|---|---|---|
| `managed_file` | 安装目标根 `/` | 与现有实现一致；inline content 或 asset download + digest |
| `archive` | 安装目标根 `/` | 按完整 archive 规则判定（见 §4.6） |
| `script` | 安装目标根 `/` | 受管脚本 asset，在安装目标根执行 |
| `package` | 安装目标根 `/` | 只引用 pinned effective software/capability，经本地 repository 解析校验、幂等 |

**四类 action 固定执行顺序**（与 rootfs-build/first-boot 一致）：

```text
文件更新(managed_file) -> package -> archive -> script
```

**八步执行生命周期**（跳过无对应 action 的步骤，但不得重排）：

1. pin 并校验 target root、effective、bundle revision、plan digest 与凭据/session 边界；
2. 物化并校验已发布的本地 repository 和输入 Asset；
3. 原子执行 `managed_file`；
4. 执行 `package`；
5. 校验并执行 `archive`；
6. 按 bundle 声明顺序执行 `script`；
7. 运行 TargetSystem finalizer；
8. 原子发布 journal/status/audit，并在全部成功后推进 `install.completed`。

action 可修改安装目标根的 users/SSH/hosts/系统文件；credential/session 越权在
plan/validate 阶段拒绝，不能用 `--force` 绕过；finalizer 末尾重新断言 effective
顺序与离线策略。

**旧 action 直接退出**：

| 旧 action | 最新设计中的表达 | v0.3 行为 |
|---|---|---|
| `repository` | `package` action 引用 pinned effective repository | parser/validator 拒绝 `provision.action_unsupported` |
| `standard_packages` | `package` action 引用 pinned effective software | parser/validator 拒绝 `provision.action_unsupported` |

不新增同义 action，不兼容读取，不提供迁移脚本或迁移提示；v0.3 bundle 按最新设计
重新创建。

**Profile 引用**：`install.post_install.bundle`（与 diskless 的
`diskless.provision.bundle` 对应，已在 `src/model.zig` `PostInstallConfig` 中存在）。

### 4.3 install-post 作为 deployment 完成闸

- `install-post` 是 deployment 完成闸：所有 step/finalizer 成功后才允许
  `install.completed`；失败不回写已经终止的 BootSession，但会终止当前 install
  generation。
- v0.3 不提供远程 step retry；重新执行必须由新的 install generation 完整重装，
  不能在已安装目标上远程补跑。
- install-post journal/status 以 `(node_id, install_generation, bundle_revision,
  plan_digest, step_id, attempt)` 标识，不能复用 diskless `boot_session_id` 假装安装器执行
  属于 BootSession。

#### 4.3.1 InstallPostRun 状态机

每个 `(node_id, install_generation)` 只能有一个 `InstallPostRun`，创建后固定
`bundle_revision` 和 `plan_digest`：

```text
pending
  └─ installer.started + session/generation/plan 固定成功 → running
       ├─ 任一步重试耗尽或 finalizer 失败              → failed
       ├─ session 不可恢复/超时                          → recovery_incomplete
       └─ 全部 step succeeded + finalizer succeeded      → completed
```

`completed|failed|recovery_incomplete` 为终态，不允许倒退或相互转换。重新安装必须创建新
install generation 和新的 `InstallPostRun`；禁止复用旧 run、清空失败记录后续跑或远程
补跑。`pending` 尚未收到经过认证的 `installer.started` 时不得创建 step journal。

#### 4.3.2 step/attempt 状态

每个 canonical step 的状态为：

```text
pending → running → succeeded
                 └→ failed_retryable → running（attempt + 1）
                 └→ failed_terminal
```

- 非 retryable step 只允许 `attempt=1`；失败直接 `failed_terminal`。
- retryable step 从 `attempt=1` 开始，只能递增 1，不接受跳号；最大次数来自固定 plan。
- 同一 attempt 的完全相同事件幂等成功；重复 `started`/`succeeded` 不重复写审计副作用。
- 已 `succeeded` 的 step 不得回到 running/failed；较旧 attempt 不推进状态。
- 当前 step 未成功前，不接受固定 action 顺序中的后续 step；同一 action 内按 bundle
  声明顺序执行，不允许并发或越序。
- 任一步进入 `failed_terminal` 后，run 原子进入 `failed`，后续 step/finalizer 事件不推进。

#### 4.3.3 finalizer 与完成原子性

finalizer 是 run 级步骤，不使用普通 bundle `step_id`，固定标识为 `@finalizer`。只有
全部 canonical step succeeded 后才能开始。服务端处理 finalizer success 时，必须在同一
持久化事务/CAS 中完成：

1. 验证 run 仍为 `running` 且 generation/plan 未变化；
2. 写入 finalizer succeeded journal；
3. 把 `InstallPostRun` 置为 `completed`；
4. 把 install generation 置为 `install.completed`；
5. 在同一完成记录中保存生成 audit/event 所需的稳定事实。

不得出现 run completed 但 generation 未完成，或 generation completed 但 finalizer journal
未持久化的可观察状态。事务提交前 daemon 崩溃视为未提交，重复 callback 按同一幂等键
安全重放；提交后重复 callback 返回当前 completed 结果。外部 Event 在提交后由完成记录
幂等派生，不参与状态原子性，也不能反向推进 generation。

#### 4.3.4 callback 状态推进结果

callback 使用统一结果，不让 adapter 根据 HTTP 文本猜测：

| 场景 | HTTP | reason | 是否推进 |
|---|---:|---|---|
| 首次合法事件 | 200 | `postprocess.event_applied` | 是 |
| 完全相同的重复事件 | 200 | `postprocess.event_duplicate` | 否，幂等成功 |
| attempt 小于当前值 | 200 | `postprocess.event_stale` | 否 |
| attempt 跳号/step 越序/状态倒退 | 409 | `postprocess.transition_invalid` | 否 |
| generation/plan 不匹配 | 409 | `postprocess.run_mismatch` | 否 |
| run 已终态且事件不等同于已提交事实 | 409 | `postprocess.run_terminal` | 否 |
| credential 无效或 session 未固定 | 401/403 | `postprocess.unauthorized` | 否 |
| 持久化失败 | 503 | `postprocess.persist_failed` | 否，installer 可重试同一事件 |

认证失败不得创建、修改或消耗任何 run/step attempt；错误响应不得回显 bearer token。

### 4.4 install-post callback credential 与 generation 绑定

install renderer 复用本次 PXE BootSession 已有的 callback credential 上报
step/finalizer 状态；v0.3 不签发第二种 raw token。

**当前状态**：`src/profile/adapter/kickstart.zig` 和 `ubuntu.zig` 的 `%post`/`late-commands`
中直接嵌入 bearer token + session id 的 `curl` 命令。token 已与 BootSession 绑定，
缺口只是服务端尚未把经过认证的 session 固定关联到 install generation journal。

**v0.3 变更**：

1. `installer.started` 使用现有 BootSession credential 认证；服务端校验 session 的
   Node、mode 和当前 armed generation 后，原子固定
   `(boot_session_id, node_id, install_generation, plan_digest)`。
2. 后续 callback 继续使用同一 credential。服务端从固定关联取得 Node/generation，
   不信任请求 body 自报的身份字段。
3. journal 以 `(node_id, install_generation, plan_digest, step_id, attempt)` 幂等；
   完全相同的重复事件返回成功，旧 attempt 或会令成功状态倒退的事件不推进状态。
4. credential 仅允许 installer event/postprocess callback，不能读取 catalog、触发远程
   retry 或升级为 management credential；generation 终态或 session 超时后失效。
5. daemon restart 复用现有 BootSession credential 恢复规则。现有 session 无法恢复时，
   当前 generation 确定失败，下一次安装创建新 generation；不增加 capsule 特殊恢复。

请求中的 `node_id + install_generation` 只可用于一致性核对，不能单独作为认证证明。

### 4.5 执行上下文差异

install-post 由安装器在安装期执行，**无 agent**：

| 维度 | install-post（v0.3） | rootfs-build（v0.2） | first-boot（v0.2） |
|---|---|---|---|
| 执行者 | 安装器（Kickstart `%post` / Autoinstall `late-commands`） | 服务端 rootfs builder | nodeforge-agent（切根后） |
| 目标上下文 | 安装中目标系统磁盘（已分区/格式化），`/` 为安装目标根 | staging 目录（chroot） | overlay upper / 内存根 |
| 持久化 | 写磁盘（install 永久） | 烤入只读 lower | 写 overlay upper / 内存根 |
| 触发 | 安装器渲染时嵌入 bundle 引用，安装期执行 | `profile rootfs build` | 切根后 systemd unit |
| 失败语义 | retryable step 只在同一 installer execution 内按声明自动重试；耗尽后令 deployment 进入 `install.failed` | builder 失败 | agent 失败 |

- 复用 v0.1 已有最小 install-post provision bundle（managed-file asset 驱动），
  **不改变其 Assets owner**。
- v0.3 将既有 phase 扩展为完整四类 action；旧 `repository`/`standard_packages`
  直接退出，不迁移、不兼容。

### 4.6 archive action 详细设计

#### 4.6.1 为什么需要详细设计

archive 是唯一一个"同一个 action 有两种完全不同的执行语义"的 action。其他三类
（`managed_file`/`script`/`package`）的执行路径是确定的：managed_file 总是写文件、
script 总是跑脚本、package 总是装包。但 archive 需要在运行时**读取 tar 内容后才能
决定是"直接解压"还是"解压后执行脚本"**。

这个判定规则已在 v0.2 设计中冻结（[`V0_2_DESIGN.md`](V0_2_DESIGN.md) §5.4），
但 rootfs-build 和 first-boot 当前只实现模式 B。v0.3 必须补齐共享判定逻辑，不能为
install-post 新建第二套规则。

#### 4.6.2 判定规则

archive action 先用 `tar -tf` 读取条目列表，不解压；规范化可选的单个 `./` 前缀后，
按以下规则判定执行模式：

```text
读取 tar 顶层条目列表
├── 顶层存在 install.sh 或 ./install.sh  →  模式 A：解压到临时目录 + 执行 sh ./install.sh
└── 顶层不存在 ./install.sh  →  模式 B：直接解压到目标根 /
```

`app/install.sh`、`scripts/install.sh` 等子目录脚本不触发模式 A；不得通过路径规范化把
含 `..` 的条目提升为顶层 `install.sh`。

**模式 A：解压 + 执行（`./install.sh` 存在）**

1. 把 tar 解压到一个临时目录（如 `/tmp/.nodeforge-archive-<step_id>`）；
2. 以该临时目录为工作目录执行 `sh ./install.sh`，不依赖 executable bit；
3. `install.sh` 退出码 0 视为成功，非 0 视为失败；
4. 执行完成后删除临时目录。

适用场景：应用安装包，归档内自带安装脚本（如解压后需要跑 `configure`、
`systemctl enable`、`useradd` 等操作）。

**模式 B：直接解压（`./install.sh` 不存在）**

1. 把 tar 直接解压到目标根 `/`（install-post 上下文中是安装目标磁盘根）；
2. tar 退出码 0 视为成功，非 0 视为失败。

适用场景：静态文件部署，如把一组配置文件、网页、二进制按目录结构直接铺到目标系统。

#### 4.6.3 代码现状对比

当前 rootfs-build/first-boot 的 archive 实现（`src/provision/first_boot.zig`
`renderStep` `.archive` 分支）**只实现了模式 B**（直接解压）：

```zig
// first_boot.zig 第 274-298 行
.archive => {
    const dest = step.destination orelse "/";
    // ... 渲染为：
    // tar -xf <archive> -C <dest>
    // 没有 install.sh 检测逻辑
},
```

- `dest` 默认为 `/`，不检测 `./install.sh`，总是直接解压到 `dest`；
- 没有"解压到临时目录 + 执行"的分支。

这意味着 v0.2 的 rootfs-build/first-boot **尚未实现模式 A**。v0.3 在为 install-post
引入 archive 时，需要同时补齐 rootfs-build/first-boot 的模式 A 实现，使三个 phase
的 archive 行为完全一致。

#### 4.6.4 install-post 的 archive 渲染目标

install-post 由安装器执行（Kickstart `%post` / Autoinstall `late-commands`），
`renderInstallPost` 需要渲染出一段 shell 命令，这段命令在安装目标根执行时完成
上述判定和执行：

**模式 A 渲染**（`./install.sh` 存在）：

```bash
# 解压到临时目录
TMPDIR=$(mktemp -d /tmp/.nodeforge-arc-XXXXXX)
tar -xf <archive_source> -C "$TMPDIR"
# 执行 install.sh
( cd "$TMPDIR" && sh ./install.sh )
RC=$?
# 清理
rm -rf "$TMPDIR"
exit $RC
```

**模式 B 渲染**（`./install.sh` 不存在）：

```bash
tar -xf <archive_source> -C /
```

由于 shell 渲染期（`renderInstallPost`）无法读取 tar 内容，判定必须在安装器执行
`%post` 时完成。实际脚本必须先列表判定，再执行对应模式：

```bash
ARCHIVE=<archive_source>
ENTRIES=$(tar -tf "$ARCHIVE") || exit 1
if printf '%s\n' "$ENTRIES" | sed 's#^\./##' | grep -Fxq 'install.sh'; then
  TMPDIR=$(mktemp -d /tmp/.nodeforge-arc-XXXXXX) || exit 1
  trap 'rm -rf "$TMPDIR"' EXIT
  tar -xf "$ARCHIVE" -C "$TMPDIR" || exit 1
  ( cd "$TMPDIR" && sh ./install.sh )
else
  tar -xf "$ARCHIVE" -C /
fi
```

实现可以不用 `sed|grep`，但必须保持相同语义：只去掉一个可选的 `./` 前缀、只接受
精确顶层 `install.sh`，并且判定前不解压。模式 B 直接解压原 archive，禁止先解压后
使用 `tar | tar` 二次搬运。

#### 4.6.5 archive 来源

archive 只允许引用已发布的受管 Asset；表中同时明确禁止的 inline 形态：

| 来源 | 字段 | 说明 |
|---|---|---|
| catalog asset | `archive_asset`（plan 物化 `content_url` + `content_sha256`） | 从 HTTP 下载已校验 tar 归档 |
| inline content | 不适用 | archive 必须先导入为受管 Asset，不在 bundle 内嵌 tar 字节 |

install-post 上下文中：

- **catalog asset 方式**：渲染为 `curl -fsS --output <tmpfile> <url> && sha256sum -c -`
  下载校验后再判定解压。与现有 `managed_file` 的 asset download 路径一致。
- **inline content**：禁止；避免把二进制 tar 编入安装模板，所有 archive 统一走
  `archive_asset`。

rootfs-build/first-boot 还支持第三种来源 `payload_path`（agent pre-init 已下载校验
的本地路径），但 install-post **不使用 payload_path**——install-post 由安装器执行，
没有 agent pre-init 阶段预下载 payload。asset 下载在安装器 `%post` 运行时通过 HTTP
完成。

#### 4.6.6 受信 Asset 约束（build/运行期通用，继承 v0.2 §5.4）

- archive 是受信管理域内由操作员导入的受管 Asset，不按不可信多租户上传物处理。
- Asset import 必须验证 tar 可读取，拒绝绝对路径和 `..` 路径组件，并保存 SHA-256；
  runner 下载后必须核对同一 digest。
- archive 顶层只识别精确 `install.sh`/`./install.sh`；子目录脚本和其他可执行文件不
  自动执行。
- `install.sh` 以 `sh` 执行，退出码 0 且由操作者保证幂等；禁止隐式下载未声明内容。
- manifest 只声明 SHA-256（由 asset 提供），不设 `script|extract` 策略、`target_root`、
  `install --root` 参数或 `NODEFORGE_TARGET_ROOT` 环境变量。
- archive 没有 `destination` 字段——目标根由执行上下文决定（install-post 为安装
  目标根 `/`，rootfs-build 为 staging `/`，first-boot 为 overlay upper `/`）。
  v0.2 CLI `item add` 的 archive action 字段矩阵中 `destination` 为禁止字段
  （[`V0_2_CLI.md`](V0_2_CLI.md) §3）。
- 步骤作者始终以 `/` 为目标，builder/agent/installer 提供挂载或 chroot 上下文把
  写入落到对应 lower / overlay upper / 目标磁盘。

#### 4.6.7 三个 phase 的 archive 行为一致性矩阵

| 维度 | install-post（v0.3 新增） | rootfs-build（v0.2 已有模式 B，需补模式 A） | first-boot（v0.2 已有模式 B，需补模式 A） |
|---|---|---|---|
| 模式 A（`./install.sh` 存在） | 解压到临时目录 + 执行 | 同左 | 同左 |
| 模式 B（`./install.sh` 不存在） | 解压到目标根 `/` | 解压到 staging `/` | 解压到 overlay upper `/` |
| 来源：catalog asset | `curl + sha256sum -c` | payload_path（已物化） | payload_path（pre-init 已下载） |
| 来源：inline content | 禁止 | 禁止 | 禁止 |
| 来源：payload_path | **不适用**（无 agent pre-init） | chroot 内 payload 路径 | `/var/lib/nodeforge/payload/` |
| `destination` 字段 | 禁止 | 禁止 | 禁止 |
| 受信 Asset 约束 | §4.6.6 | 同左 | 同左 |

v0.3 实施时需要：

1. 在 `renderInstallPost` 中新增 `.archive` 分支，渲染运行时自判定脚本；
2. 在 `first_boot.zig` 的 `renderStep` `.archive` 分支中补齐模式 A 逻辑；
3. rootfs-build 复用 `first_boot.renderStep`，自动获得模式 A；
4. 三个 phase 共用“digest 校验 -> `tar -tf` 判定 -> 模式 A/B”逻辑；Asset import
   统一完成 tar 可读性和基本路径检查。

## 5. CLI（v0.3）

> 完整 CLI 约定见 [`V0_2_CLI.md`](V0_2_CLI.md) §0；本节给 v0.3 新增。

```text
nodeforge profile set <profile> install.post_install.bundle=<bundle>
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=install-post action=managed-file content_asset=<asset> destination=/etc/motd \
  mode=0644 owner=root group=root idempotency_key=<key> timeout_s=30 retryable=false
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=install-post action=package packages=tmux,nmap \
  idempotency_key=pkgs timeout_s=600 retryable=true
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=install-post action=archive archive_asset=<app-archive> \
  idempotency_key=app-archive timeout_s=120 retryable=false
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=install-post action=script script_asset=<setup-script> interpreter=sh \
  idempotency_key=setup timeout_s=120 retryable=false
nodeforge node postprocess show <node> --phase install-post [--generation <id>]
```

- `profile set ... install.post_install.bundle` 与 provision-bundle owner 沿用 v0.2
  现有入口；v0.3 新增的是 canonical action 接受范围和 generation status/callback。
- `postprocess` 统一命名（同 v0.2）：install 侧的 install-post phase 也用
  `node postprocess show` 查询，不用 `postinstall`，避免与 diskless 命名分叉。
  省略 `--generation` 时查询最近一个 install generation；无历史时返回空结果 exit 0。
  `--session` 只适用于 diskless first-boot，不能和 `--generation` 混用。
- `install-post` phase token 在 schema v4/parser 中已经存在，且兼容 runner 支持
  `repository`、`standard-packages` 与 `managed-file` 子集；v0.3 只接受四类 canonical
  action，旧形态直接拒绝且不提供迁移/兼容路径。
- v0.3 不提供多 NIC/VLAN/bonding、容量压测、install 侧 agent 的 CLI
  （属 v0.4/永久非目标）。

## 6. 明确非目标（v0.3 增量）

- BIOS/PXELINUX -> 独立延后文档
  [`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)，不绑定产品版本号，最早在 v0.5 后实施。
- 多 NIC/VLAN/bonding、PXE 阶段纯静态、下载后切换地址/子网 -> v0.4
  （需显式 initrd/agent consumer feature、schema 和验收）。
- 大规模容量压测 -> v0.4。
- install 侧 first-boot agent -> v0.4（确定性，无 reconciliation）。
- reconciliation/远程控制 -> 永久非目标（全版本）。
- IPv6、by-id/serial/WWN -> 永久非目标（继承 v0.1）。
- v0.3 不提供 v0.4/v0.5 命令的 help/handler；预留 enum 不算实现。

## 7. 实施批次

### Batch 1：install-post runner 扩展

**涉及文件**：`src/provision/runner.zig`、`src/provision/first_boot.zig`、
`src/config/validate.zig`、相关测试。

- 扩展 `renderInstallPost` 接受 `archive`/`script`/`package` 三类 canonical action；
- 八步执行生命周期与四类 action 固定顺序；
- `package` action 只引用 pinned effective software/capability，经本地 repository
  解析校验、幂等；
- `archive` 规则与 v0.2 §5.4 一致：运行时自判定 `./install.sh` 存在则解压到临时
  目录执行（模式 A），否则直接解压到目标根（模式 B），详见 §4.6；
- **补齐** `first_boot.zig` `renderStep` `.archive` 分支的模式 A 逻辑，使
  rootfs-build/first-boot 与 install-post 行为一致；
- 旧 `repository`/`standard_packages` 在 parser/validator 报错
  `provision.action_unsupported`，不提供迁移分支；
- aarch64 UEFI install 回归不退化。

### Batch 2：install-post callback 与 journal

**涉及文件**：`src/profile/adapter/kickstart.zig`、`src/profile/adapter/ubuntu.zig`、
`src/state/`（新增 install-post journal）、`src/http/server.zig`、`src/main.zig`。

- 复用现有 BootSession callback credential，不新增 token/capsule/claim endpoint；
- `installer.started` 原子固定 session 到 Node/generation/plan；
- `(node_id, install_generation, bundle_revision, plan_digest, step_id, attempt)` 标识；
- 实现 `pending -> running -> committing -> completed` 成功状态机、
  `failed|recovery_incomplete` 失败分支和 step attempt 状态机；
- 相同事件幂等，attempt 跳号、step 越序、旧 attempt、成功状态倒退和 terminal
  generation 后事件按 §4.3.4 返回稳定结果；
- step/finalizer 状态上报与持久化；
- finalizer 成功先持久化 `committing` WAL，再提交 deployment generation，最后发布
  journal completed；daemon 启动时按同一顺序恢复中断事务；
- `node postprocess show --phase install-post [--generation <id>]` 查询；
- 同次安装自动 step retry；耗尽后阻止 `install.completed`；
- 不存在远程 step retry；daemon restart 只复用现有 session 恢复能力。

### Batch 3：CLI + 文档 + 全量回归

- 文档：更新路线图状态、当前实现审计、CLI reference、`V0_2_CLI.md`、本设计实现状态；
- schema fixture、state/DTO fixture；
- aarch64 UEFI install/diskless 全量回归。

## 8. 完成标准

- install-post phase 在同一 Assets owner 上实现四类 action、八步契约、
  credential/session 边界/finalizer、plan/status、同次安装自动 step retry；
  耗尽后阻止 `install.completed`，且不存在远程 step retry。
  `standard_packages`/`repository` 已退出（parser/validator 直接拒绝，无迁移提示）。
- install-post callback 复用 BootSession credential；session/generation/plan 固定、重复
  callback 幂等、attempt 跳号、step 越序、旧 attempt、状态倒退、跨 Node、错误 plan、
  终态后 callback、finalizer 原子提交失败注入与 daemon restart 负向测试通过；未经认证
  或仅自报 node/generation 的事件不能推进 deployment。
- `node list`/`node status` 对 install 与 diskless 统一投影，
  installer 进度仅在 `node_status` 保留。
- aarch64 UEFI install 与 diskless 回归不退化。
- catalog schema 保持 v5（无 schema 变更）。
- 本审计与版本设计、配套文档同步更新；预留 enum/空 handler 不算实现证据。

以上完成标准已由 2026-08-02 fresh 验证全部满足，最终判定为 **PASS**。后续修改若触及
callback 认证、generation 绑定、runner 顺序、archive 校验、WAL 恢复或既有 diskless
路径，必须重新执行 `zig build test` 和真实 `test-v0.3-install-post-e2e` 发布闸。
