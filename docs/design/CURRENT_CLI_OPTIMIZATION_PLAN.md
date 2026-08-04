# NodeForge 当前 CLI 全面优化与收敛方案

| 元数据 | 值 |
|---|---|
| 文档 ID | `CLI-PLAN-2026-07-28-01` |
| 状态 | `proposed` |
| 创建时间 | `2026-07-28` |
| 最后更新 | `2026-07-28` |
| 适用范围 | 当前 CLI、management API、相关状态模型、代码注释、测试与 CLI 设计文档 |
| 基线 | 2026-07-28 工作区中的当前实现与 `docs/design/` 现行设计 |
| 关系 | `consolidates` 2026-07-28 CLI 实现/设计差异复审结论 |
| 取代 | 暂无；实施前不自动取代既有版本设计契约 |
| 后继文档 | 暂无 |

状态含义：

- `proposed`：目标方案，尚未整体实现；
- `accepted`：已确认作为实施基线；
- `implementing`：正在分阶段落地；
- `implemented`：完成代码、测试、注释和文档同步；
- `superseded`：已由 `后继文档` 指向的新方案取代；
- `withdrawn`：不再实施，但保留决策记录。

关系词固定使用：

- `supersedes`：完整取代旧方案；
- `amends`：只修改旧方案的明确章节，其余继续有效；
- `complements`：补充独立范围，不改变旧方案；
- `consolidates`：汇总此前审计或讨论，但不自动改变其历史内容。

本文以当前代码、实际运行时状态机、已经完成的验证和操作员目标为共同输入，定义
NodeForge CLI 下一阶段的整体收敛方向。它不是只针对 `profile clone` 或
`node boot preview` 的增量设计，而是同时覆盖：

- 正常工作流、精细配置、诊断恢复和内部命令的分层；
- 同步交互、后台 operation 和进度反馈；
- 设计文档与实现事实的裁决方法；
- mutation owner、CAS、digest guard 和 `--force`；
- Profile clone、provenance、SSH identity 和组合构建；
- boot preview、readiness、show、trace 与内部 boot-prepare 的边界；
- install/diskless 共用 `node retry` 的目标语义；
- exit code、错误信封、输出、帮助和命令发现；
- 代码注释、测试、验证和现有设计文档的同步迁移。

本文是目标方案，不把“代码里已有字段”误写成“完整用户能力已经交付”。每项实现状态
必须通过代码、测试和验证记录确认。

---

## 1. 目标与裁决原则

### 1.1 产品目标

CLI 的首要目标是让操作员用少量目标级命令完成正常流程：

```text
setup
-> import OS
-> create/clone profile
-> build rootfs
-> add/configure node
-> readiness
-> boot preview
-> deploy
-> show/retry
```

daemon 负责原子事务、并发控制、运行时状态机和复杂的资源关系。CLI 不要求普通用户
手工编排 session、revision、digest 或 operation。

同时保留细粒度命令，用于高级配置、自动化、故障分析和恢复，但不把这些命令混入
正常工作流。

### 1.2 三类事实共同裁决

任何 CLI 命令是否保留、补齐、合并或删除，必须同时检查：

1. **业务事实**：资源 owner、状态机、安全边界和副作用是什么。
2. **实现事实**：当前 handler/API/store 是否真的完成，是否有测试和实测。
3. **产品事实**：操作员是否需要直接表达这个动作，还是只需要表达更高层目标。

现有设计文档是重要输入，但不是当前实现的单方面裁判。反过来，代码中存在 enum、
注释或空 handler，也不代表该能力已经成为正式产品接口。

### 1.3 当前文档角色调整

建议形成以下结构：

```text
docs/cli/REFERENCE.md        当前正式 CLI 接口
docs/cli/WORKFLOWS.md        正常操作流程
docs/cli/TROUBLESHOOTING.md  诊断、恢复和高级命令
docs/design/*.md             目标架构、版本设计和决策记录
docs/audits/*.md             某次代码/设计对照的审计证据
```

在上述文件落地前，本文作为整体迁移基线。现有 `V0_2_CLI.md` 不应继续被解释为
“不考虑当前代码变化的绝对事实源”；它应逐步收敛为版本设计记录，当前正式接口由
新的 `docs/cli/REFERENCE.md` 描述。

---

## 2. CLI 分层与目标命令树

### 2.1 一级：正常工作流

根帮助和资源帮助优先展示：

```text
nodeforge setup
nodeforge status

nodeforge assets import
nodeforge assets list
nodeforge assets show

nodeforge profile create
nodeforge profile clone
nodeforge profile list
nodeforge profile show
nodeforge profile set
nodeforge profile rootfs build
nodeforge profile rootfs status

nodeforge node add
nodeforge node list
nodeforge node show
nodeforge node set
nodeforge node readiness
nodeforge node boot preview
nodeforge node deploy
nodeforge node retry
```

这些命令应足以完成正常部署，不要求用户先查询 operation id、session id 或 catalog
revision。

### 2.2 二级：高级配置

正式公开，但主要通过资源级 `--help-full` 发现：

```text
profile unset
profile add-values|remove-values|replace-values|clear-values
profile item ...
profile software ...
profile capabilities show
profile rootfs plan|build

node unset
node add-values|remove-values|replace-values|clear-values
node item ...
node software ...
node capabilities show

assets managed-file ...
assets archive ...
assets script ...
assets provision-bundle ...
assets boot-bundle ...
assets install-source ...
assets repository ...
assets key-...
```

### 2.3 三级：诊断与恢复

```text
node session list|show|cancel
node trace
events list|follow|types
runtime dhcp-leases|dhcp-unknown
runtime tftp-sessions|tftp-counters
discovery list|show|policy
operation list|show|follow
```

这些能力必须存在，但不能迫使普通流程手工使用。

### 2.4 四级：内部运行时动作

真实 session 创建、credential 签发和底层 operation transition 不属于正常人工 CLI：

```text
internal boot-prepare
internal operation transition
internal migration/debug endpoints
```

如测试必须暴露手工入口，应使用隐藏的诊断命令和显式确认，例如：

```text
node session prepare <node> --diagnostic --yes
```

---

## 3. 同步体验、Operation 与进度

### 3.1 默认同步跟随

普通用户不应传 `--wait`。长任务默认提交后跟随到完成：

```text
nodeforge profile rootfs build rocky-diskless
```

输出真实阶段：

```text
✓ compiled build projection
✓ resolved repositories
✓ built OS layer
✓ applied rootfs-build steps
✓ installed Profile SSH identity
✓ created squashfs
✓ published artifact
```

短 mutation，如 `node set`、`profile set`、`deploy`、`session cancel`，保持直接同步，
不创建 operation。

### 3.2 daemon 内部长任务仍使用 durable operation

“CLI 默认同步”不等于“HTTP handler 内同步执行全部重任务”。rootfs build、ISO import、
initrd build 等长任务应由 daemon operation 执行，原因包括：

- CLI 断线不取消实际工作；
- 可以恢复观察；
- 可以提供真实进度；
- daemon 重启后能标记 interrupted；
- 相同幂等请求可复用或 join；
- 避免长任务阻塞管理 HTTP handler。

CLI 默认跟随 operation，因此对用户仍表现为一个同步命令。

### 3.3 后台执行

统一使用：

```text
--detach
```

而不是要求默认调用先返回 operation id，再手工 `wait`。

```text
nodeforge profile rootfs build rocky-diskless --detach
```

返回：

```json
{
  "operation_id": "...",
  "operation_url": "...",
  "state": "queued"
}
```

`--timeout` 只限制 CLI 跟随时间，不取消 daemon operation。超时输出 operation id 和恢复
命令。

### 3.4 Operation 命令

推荐：

```text
operation list
operation show <id>
operation follow <id> [--timeout N]
```

现有 `operation wait` 可作为兼容 alias，但新文档统一使用 `follow`。

Operation 状态由服务端类型定义，CLI 不重复手写字符串判断。终态至少包括服务端实际
支持的 `succeeded|failed`；只有服务端真正实现 cancel 后才加入 `cancelled`。文档不得
提前声明代码中不存在的状态。

### 3.5 进度输出

- human：进度写 stderr，最终摘要写 stdout；
- json：stdout 只输出一个最终文档，进度写 stderr；
- jsonl：可把 progress/final 各写一行 stdout；
- 非 TTY 不输出 spinner 或 cursor control；
- 进度来自 daemon operation event/revision，不从 CLI 定时器猜测。

---

## 4. Mutation Owner、并发控制、CAS 与 `--force`

### 4.1 daemon 是 mutation owner

Node/Profile/Assets/catalog mutation 必须由 daemon 在同一事务边界内完成。CLI 不应：

- 自行读取 catalog 后分配下一 revision；
- 先复制正式 artifact，再请求 daemon 登记；
- 通过独立 `--catalog` 写入口绕开 daemon；
- 用多个 CLI/API mutation 拼接一个业务动作。

纯本地读取/恢复命令可保留显式文件路径；正式 mutation 从 config 解析活动 daemon 和
受管路径。

content asset import 应改为 daemon-owned staged publication：

1. CLI 提交受控 source 或上传到受管 staging；
2. daemon 分配 revision；
3. daemon 校验并写 `.part`；
4. daemon 原子发布文件和 catalog；
5. 失败时由 daemon 回收 staging。

### 4.2 普通 CLI 隐藏 CAS

当前 client 已自动读取 catalog revision 并使用 `If-Match`。该机制应保留在 CLI/API
内部，普通用户不需要通用 `--if-revision`。

并发冲突时：

- 不静默覆盖；
- 不使用 `--force` 绕过；
- human 输出说明对象已变化并建议重新执行；
- JSON 返回稳定 error code；
- 自动化可重新读取后决定是否重试。

### 4.3 收缩显式 guard

保留具有明确成本和审核价值的：

```text
profile rootfs build <profile> --if-input-digest <digest>
```

它保证昂贵构建仍使用刚刚审核过的 build projection。

暂不公开通用：

- `--if-revision`
- `--if-plan-digest`
- `--if-failure-revision`

这些能力只有出现明确自动化需求时再从 API 提升到 CLI。`profile clone` 第一版也不虚构
历史选择能力；详见 §7。

### 4.4 `--force` 的唯一含义

`--force` 只表示：

> 为完成目标动作，允许终止、取代或越过当前活动运行状态。

它可以用于：

- supersede 活动 install generation；
- cancel/supersede 活动 diskless session；
- 在明确警告后继续目标 mutation。

它不得：

- 忽略 revision conflict；
- 忽略 digest drift；
- 绕过 schema validation；
- 绕过 readiness；
- 覆盖同名 immutable artifact；
- 把所有错误转成继续执行。

force 结果必须报告实际副作用：

```json
{
  "forced": true,
  "terminated_sessions": ["..."],
  "superseded_generation": 4
}
```

---

## 5. 输出、错误与 Exit Code

### 5.1 统一错误映射

建立单一映射层：

```text
HTTP/API error -> stable CLI error.code -> exit class
```

handler 不再散落 `setExitCode(ctx, 1)`。

建议分类：

| Exit | 含义 |
|---|---|
| 0 | 成功或幂等 no-op |
| 1 | 本地 I/O、序列化、损坏状态或内部错误 |
| 2 | 输入错误、字段不适用、需要确认 |
| 3 | revision/digest 并发冲突 |
| 4 | not-ready、quarantined、运行状态阻止 |
| 5 | 已接受 operation 最终失败 |
| 6 | daemon 不可达、服务不可用或跟随超时 |

not-found 与 daemon unavailable 必须分开，不再合并为同一个错误。

### 5.2 错误提供下一步

目标级错误应返回 `next_commands`：

```json
{
  "ok": false,
  "error": {
    "code": "node.active_session",
    "message": "...",
    "next_commands": [
      "nodeforge node show c001",
      "nodeforge node retry c001 --force"
    ]
  }
}
```

### 5.3 敏感输出

任何 human/json/jsonl/log/event 都不得包含：

- 明文密码；
- password hash；
- SSH private key；
- capability token；
- 带 token 的 URL；
- 未裁剪的脚本敏感输出。

只显示 `<configured>`, `<redacted>`, fingerprint 或受管 identity id。

---

## 6. Show、Readiness、Capabilities 与 Status 的边界

### 6.1 命令职责

| 命令 | 回答的问题 |
|---|---|
| `status` | daemon 和服务平面是否正常 |
| `profile show` | Profile 存储事实、来源、effective 摘要和引用是什么 |
| `node show` | Node 存储事实、effective 摘要和当前运行态是什么 |
| `node readiness` | 是否满足 build/boot 门禁，为什么 |
| `node boot preview` | 如果现在启动，会选择什么 |
| `capabilities show` | adapter/feature 能消费什么，缺少什么 |
| `node trace` | 过去一次 session 的时间线是什么 |

不新增与 `show` 大量重复的通用 `profile effective` 或 `node effective`。需要更详细输出时，
优先使用 `--section`/`--help-full` 和结构化 JSON。

### 6.2 统一检查结构

status/readiness/capabilities 共用：

```json
{
  "checks": [{
    "id": "...",
    "scope": "service|profile|node",
    "required": true,
    "status": "pass|warn|fail|unknown",
    "reason": "...",
    "next_commands": []
  }]
}
```

不同命令选择不同 check 集合，但不发明三种互不兼容的输出协议。

---

## 7. Profile Clone、Provenance 与 SSH Identity

### 7.1 正式命令

```text
profile clone SOURCE TARGET [KEY=VALUE...]
  [--new-ssh-keys]
  [--build]
  [--detach]
```

示例：

```text
nodeforge profile clone rocky-base rocky-compute \
  system.localization.timezone=Asia/Shanghai \
  diskless.overlay.tmpfs_percent=70 \
  --build
```

属性修改使用与 `node add/set` 一致的 `KEY=VALUE...`，不再同时设计重复
`--set KEY=VALUE` 入口。

### 7.2 原子 clone

daemon 在一个 catalog transaction 中：

1. 锁定 current snapshot；
2. 查找 source；
3. 验证 target 不存在；
4. 深拷贝完整 desired Profile；
5. 应用全部 property patch；
6. 验证 kind applicability 和全部引用；
7. 选择复用或新建 SSH identity；
8. 写 provenance；
9. 原子发布 target。

任一 patch、引用或 key generation 失败，target 不得存在。

clone 后 target 独立，不在运行时继承 source。`cloned_from` 仅审计，不进入 effective
compiler。

### 7.3 复制与不复制

复制：

- kind/install_source/boot_bundle/bundle；
- system/software/install/diskless；
- kernel_args；
- SSH identity reference，除非 `--new-ssh-keys`。

不复制：

- Node 绑定；
- active session；
- operation；
- readiness/runtime 状态；
- rootfs artifact ownership 状态。

内容寻址层允许 target 的相同 `rootfs_input_digest` 命中已有 artifact。

### 7.4 Revision 与历史选择

当前代码没有可读取的 Profile 历史快照，因此第一版不提供假历史：

```text
--from-revision
```

clone 原子复制执行时 current source snapshot。若将来需要观察后防漂移，可增加
`--if-source-revision`；只有真正保存历史 Profile 内容后，才实现 `--from-revision`。

### 7.5 Provenance 模型

Profile 增加至少：

```zig
revision: u64,
created_at: i64,
updated_at: i64,
provenance: {
    origin: create | clone,
    install_source_name: []const u8,
    install_source_revision: u64,
    install_source_digest: []const u8,
    cloned_from: ?{
        profile_name: []const u8,
        profile_revision: u64,
        catalog_revision: u64,
        cloned_at: i64,
    },
}
```

每次 Profile mutation 增加 revision/update time，但不改变 immutable clone origin。
`profile show` 展示上述事实和只读 lineage。

### 7.6 SSH Identity 先行修复

> 状态（v0.2.3）：本节的先行修复已全部落地——daemon-owned identity store、create 固定
> identity、clone 默认复用/`--new-ssh-keys` 轮换、rootfs build 只消费固定 identity
> （构建期不再 `ssh-keygen`）、identity revision/fingerprint 进入 rootfs input digest、
> API/CLI 不输出私钥。下文保留原问题陈述。

v0.2.2 收口时，代码在每次 rootfs build staging 中重新运行 `ssh-keygen`，而 Profile 没有
持久 SSH identity，与设计中的 clone key 复用、`--new-ssh-keys` 和可复现 rootfs 冲突。

实现 clone 前必须：

1. 建立 daemon-owned Profile SSH identity store；
2. create/clone preparation 生成并固定 identity；
3. catalog 只保存 identity id/revision/fingerprint；
4. 私钥存入 `0700` 目录、文件 `0600`；
5. rootfs build 只消费固定 identity，不临时生成；
6. identity revision/fingerprint 进入 rootfs input digest；
7. API/CLI 永不输出私钥。

默认 clone 复用 source identity；`--new-ssh-keys` 创建独立 identity。

### 7.7 `--build`

`--build` 在 clone 成功后提交 target rootfs build。默认跟随，`--detach` 后台。

> 状态（v0.2.3）：已实现——`managementProfileClone` 在 clone 发布后提交 build
> operation；成功响应体含 operation id（客户端据此跟随/`--detach`），build 提交失败
> 返回 `rootfs.build_submit_failed`（HTTP 503、exit 5），JSON 结果
> `profile_created=true, build_submitted=false`。

clone transaction 与实际长构建不做一个不可恢复的大事务，但响应必须分别报告：

```json
{
  "profile": {"created": true, "name": "...", "revision": 1},
  "build": {"submitted": true, "operation_id": "..."}
}
```

如果 Profile 创建成功而 build submission 失败，必须明确返回已创建 Profile 和下一步命令，
不能让用户误以为 clone 回滚。

---

## 8. Boot Preview 与内部 Boot Prepare

### 8.1 正式只读命令

```text
node boot preview NODE
  [--section summary|boot|apply|all]
  [-o human|json|jsonl]
```

支持 install 和 diskless，不只服务于一种 Profile kind。

### 8.2 Preview 能做什么

- 读取 current config/catalog；
- 编译 effective plan；
- 计算 rootfs/desired plan digest；
- 解析 BootBundle 和选中的 boot assets；
- 检查 rootfs cache；
- 编译 Node boot projection 和 apply projection；
- 执行 readiness checks；
- 展示“如果现在 PXE，会选择什么”。

### 8.3 Preview 绝对不能做什么

- 创建 BootSession；
- 调用 delivery store `begin`；
- 生成 session id；
- 签发 token；
- pin AgentPlan；
- 创建 payload lease；
- 修改 deploy/quarantine；
- 触发 rootfs build；
- 修改任何 store/revision。

### 8.4 独立 Preview DTO

真实 BootConfig 需要 session id、authority、expiry 和 session-bound locator。preview 没有
session，不能伪造 BootConfig。

定义独立 `BootPreview` DTO，至少包含：

```text
node/profile/kind
catalog_revision/profile_revision
rootfs_input_digest
desired_plan_digest
selected boot assets
boot projection
node apply summary
artifact/cache state
readiness checks
would_boot
```

URL 只显示 route template，不显示看似可直接访问但没有 authority 的 URL。

### 8.5 与 boot-prepare 的边界

当前实际代码中，TFTP 在真实请求路径自动调用 boot-prepare；boot-prepare 会创建并持久化
diskless session、pin AgentPlan、签发 credential。因此它是内部有副作用的运行时
transition，不是预览命令。

正常工作流改为：

```text
node readiness <node>
node boot preview <node>
node deploy <node> true
```

真实 PXE/TFTP 到达后，daemon 内部调用 boot-prepare。公开工作流和普通 `node --help`
移除 `node boot-prepare`。

### 8.6 Preview 输出

默认 human summary：

```text
Boot Preview: c001

Decision
  would_boot             yes
  deploy                 true
  profile                rocky-9.7-aarch64-minimal-diskless
  kind                   diskless

Artifacts
  boot_bundle            rocky-9.7-aarch64-minimal-diskless
  kernel                 rocky-9.7-kernel@1
  initrd                 rocky-9.7-initrd@2
  rootfs                 ready
  rootfs_input_digest    ...
  desired_plan_digest    ...

Readiness
  required checks        12/12 passed
  warnings               1
```

`apply` 只显示运行根配置摘要；密码、hash、private key 和 token 一律不输出。

---

## 9. 统一 `node retry`

### 9.1 目标语义

保留简洁主命令：

```text
node retry <node>
node retry <node> --force
```

含义：

> 让这个 Node 再次尝试完成其当前 Profile 所要求的部署。

daemon 根据 kind 和当前状态原子决策：

| 状态 | 默认行为 |
|---|---|
| install，上一 generation 已终态 | rearm，并按需要启用 deploy |
| install，有活动 session | 拒绝；`--force` supersede 后 rearm |
| diskless，无活动 session | 清理可恢复 failure gate 并允许下一次启动 |
| diskless，failed/quarantined | 按策略恢复并允许下一次启动 |
| diskless，有活动 session | 拒绝；`--force` cancel/supersede 后允许下一次启动 |
| 当前健康且无需 retry | 幂等 no-op 或 `nothing_to_retry` |

### 9.2 服务端原子 endpoint

当前 install retry 由 CLI 先 `deploy=true`，再 rearm generation，存在部分成功风险。改为：

```text
POST /api/v1/management/nodes/:id/retry
{"force": false}
```

服务端在同一事务里完成状态读取、session 处理、deploy gate 和 retry/generation 更新。

细粒度 `node session cancel`、`node trace` 和 events 继续保留用于诊断，但不成为正常 retry
前置步骤。

---

## 10. Asset 与命令入口收敛

### 10.1 类型化入口

保留：

```text
assets import <iso>
assets managed-file import
assets archive import
assets script import
assets initrd build
assets boot-bundle create
profile rootfs build
```

逐步淘汰与类型化入口重复的通用 `assets register --type ...`，避免一个资源有两套身份和
参数顺序。

### 10.2 Profile 派生 artifact 归 Profile

rootfs 的产品 owner 是 Profile：

```text
profile rootfs plan|build|status
```

物理内容寻址视图如需要，可在 assets 下只读查询，但不能引入第二套 mutation owner。

### 10.3 Provision Bundle

保持 `steps` 为唯一 structured collection，phase/action 是 item 字段。正常流程不要求手工
操作 item，但高级 CLI 必须支持 list/show/add/set/remove/move/replace/clear 和 plan。

---

## 11. 版本能力与当前实现

### 11.1 不以版本号隐藏已经完成的能力

v0.3 规划的能力如果已完整实现并通过测试，应进入当前 CLI reference，不必为了保持旧
v0.2 文档纯度而隐藏。

但必须区分：

```text
implemented
experimental
internal
planned
```

代码有 enum/schema 不等于完整用户能力已经实现；必须检查 handler、API、状态存储、输出、
失败恢复和 E2E。

### 11.2 版本文档记录计划与实际交付

版本设计保留：

- 最初规划版本；
- 实际完成版本；
- 提前实现原因；
- 是否成为当前正式 CLI；
- 仍缺的验收项。

当前 CLI reference 按能力是否正式可用组织，不按 v0.2/v0.3 分裂帮助树。

---

## 12. 帮助、命令发现与规范生成

### 12.1 声明式 CommandSpec

逐步从同一声明生成：

- zli command tree；
- `--help`；
- `--help-full`；
- CLI reference；
- command tree snapshot tests。

CommandSpec 至少包含：

```text
path
summary
visibility = primary|advanced|diagnostic|internal
stability = implemented|experimental
arguments/flags
daemon dependency
side effects
output schema
exit/error mapping
```

### 12.2 Help 分层

- 根 help：只展示主流程资源和动作；
- 资源 help：展示常用动作；
- `--help-full`：展示全部高级命令、PropertySpec、CollectionSpec、ItemSpec；
- internal 命令不出现在普通 help；
- reserved/no-op flag 在真正实现前不进入 parser。

---

## 13. 代码注释同步规则

### 13.1 当前已发现的重点

实现过程中至少修订：

1. `ProfileConfig` 仍称“v0.1 install profile”，但已同时承载 install/diskless。
2. rootfs build 注释声称 `--new-ssh-keys` 可用，而当前 CLI 尚无该 flag，且 keys 在
   build staging 临时生成。
3. HTTP client/boot target 注释把 boot-prepare 描述为普通 CLI 动作，应明确它是
   TFTP 运行时内部 session transition。
4. operation 文档声明的状态必须与 `state/operations.zig` 实际枚举一致。
5. 设计中已完成/未完成标记必须随实现落地更新，不能把未来计划写成当前事实。

### 13.2 注释只描述当前不变式

代码注释描述：

- 当前 owner；
- 当前副作用；
- 当前原子边界；
- 当前安全边界；
- 当前恢复语义。

未来计划放设计文档或显式 TODO，不混入当前行为注释。

---

## 14. 文档迁移清单

后续实现应逐项同步：

| 文件 | 变更 |
|---|---|
| `docs/README.md` | 增加当前 CLI reference/workflow/本方案入口，修正文档裁决描述 |
| `design/V0_2_CLI.md` | 默认跟随 + `--detach`；clone；boot preview；隐藏 boot-prepare；收缩 CAS |
| `design/V0_2_DESIGN.md` | Profile provenance/SSH identity；clone；preview DTO；retry 原子语义 |
| `design/V0_2_DISKLESS_WORKFLOW.md` | 主流程改为 readiness -> preview -> deploy；移除人工 boot-prepare |
| `design/DISKLESS_FINAL.md` | boot-prepare 标记内部 transition；Preview 不生成 authority |
| `design/V0_3_DESIGN.md` | 标记已提前完成与仍缺能力，不再仅按版本隔离 CLI |
| `design/V0_4_DESIGN.md` | 保持新增能力映射到当前分层 CLI |
| `audits/V0_2_V0_5_CLI_GAP_AUDIT.md` | 标记为历史审计；记录被本方案取代的 `--wait`/通用 CAS 决策 |
| `docs/cli/REFERENCE.md` | 从实际 command tree 建立当前正式接口 |
| `docs/cli/WORKFLOWS.md` | 只使用 primary 命令描述正常流程 |
| `docs/cli/TROUBLESHOOTING.md` | session/events/runtime/discovery/operation 诊断流程 |

更新设计文档时不得覆盖已有未提交修改；应逐段合并并保留仍成立的安全和状态机契约。

---

## 15. 测试与验收

### 15.1 命令契约

- command tree snapshot；
- 文档正式命令必须存在；
- internal 命令不得出现在 normal help/workflow；
- 过滤废弃语法：普通 `--wait`、公开 workflow 中的 boot-prepare、假
  `--from-revision`；
- human/json/jsonl golden tests；
- exit/error 映射测试。

### 15.2 Clone

- install/diskless clone；
- target exists/source missing；
- 多 patch 原子应用；
- patch 失败无 target；
- source/target 后续修改互不影响；
- provenance/revision/time；
- 默认共享 SSH identity；
- `--new-ssh-keys` 使用不同 fingerprint；
- private key 不泄漏；
- 相同 projection cache hit；
- 新 identity 改变 rootfs digest；
- `--build` 默认跟随；
- `--build --detach` 返回 operation；
- clone 成功但 build submission 失败的明确结果。

### 15.3 Boot Preview

- install/diskless；
- unassigned/missing artifact/deploy=false/quarantine/active session；
- incompatible arch/firmware；
- Node override 只改变应改变的 digest；
- preview 前后 catalog/session/credential/operation/artifact store 完全不变；
- 不生成 token/session；
- preview 与真实 prepare 的公共 projection 字段一致；
- 敏感字段不出现在所有输出模式。

### 15.4 Retry

- install terminal/active/force；
- diskless terminal/quarantine/active/force；
- daemon 原子失败回滚；
- 不出现 deploy 已打开但 generation 未 rearm 的部分成功；
- no-op 幂等。

### 15.5 Operation 与进度

- 默认 follow；
- detach；
- CLI 中断后恢复；
- timeout 不取消；
- daemon restart -> interrupted；
- idempotency reuse/join；
- JSON stdout 纯净；
- 非 TTY 无 spinner。

### 15.6 Asset owner

- 并发同名 import；
- revision 分配唯一；
- daemon publication 失败无正式文件；
- catalog publish 失败无幽灵 artifact；
- CLI 不通过备用 catalog mutation 绕过 owner。

---

## 16. 实施顺序

本节保留最初的依赖排序，但实施状态以
[`V0_2_POST_RELEASE_BACKLOG.md`](V0_2_POST_RELEASE_BACKLOG.md) 为准。已完成项不得
因下列原始列表仍存在而重新计为残留；P2 也不构成 v0.2.2 发布阻断。

### P0：修正关键数据与原子边界

1. Profile provenance/revision/time。（v0.2.3 已完成：`mutateProfileMetadata` + `revision_scan`）
2. Profile SSH identity 持久化，移除 build-time 随机 identity。（v0.2.3 已完成：
   daemon-owned identity store + `installIdentityKeys`，构建期不再 `ssh-keygen`）
3. rootfs digest 纳入 identity revision/fingerprint。（v0.2.3 已完成：
   `ProfileBuildProjection` 纳入 `ssh_identity` 引用与 fingerprint）
4. daemon 原子 `profile clone`。（v0.2.3 已完成：clone property patch 与 provenance
   同事务；identity/provenance 已补齐）
5. daemon 原子、按 kind 分发的 `node retry`。（已完成）
6. content asset daemon-owned publication。（已完成）

### P0：完成主流程

1. `profile clone` CLI。（v0.2.3 已完成：含 `[KEY=VALUE...]` properties 与
   `--new-ssh-keys`/`--build`/`--detach` flags）
2. clone `--new-ssh-keys`。（v0.2.3 已完成）
3. clone `--build [--detach]`。（v0.2.3 已完成：build 提交失败复合错误信封，
   成功响应体带 operation id 供跟随/detach）
4. 抽取严格只读 boot projection/preview compiler。（已完成）
5. `node boot preview` install/diskless。（已完成）
6. 从普通 help/workflow 移除 boot-prepare。（已完成）

### P1：长任务与输出

1. rootfs/initrd/ISO import 使用 durable operation。（v0.2.3 已完成：ISO 由
   `IsoImportWorker` 真后台执行，三类 worker 并行、restart→interrupted、原子发布）
2. 默认 follow、可选 detach。（v0.2.3 已完成：ISO 随后台化收口）
3. operation progress event。（`V02-D09`，未排期可观测性候选）
4. 统一错误/exit mapping。（v0.2.3 已完成：exit 0–6 契约与 `mapErrorToExitCode` 纯函数）
5. 共用 checks schema。（`V02-D10`，仅在后续 DTO 升级时重新评估）

### P1：CLI 与文档重基线

1. 建立 `docs/cli/REFERENCE.md`。（已完成）
2. 建立 primary workflow 和 troubleshooting。
3. 给现有命令标记 visibility/stability。
4. 更新全部设计分册和代码注释。（v0.2.3 已按 §11 跨文档引用同步；后续版本继续）
5. command tree/help 契约与文档一致性测试。（已完成当前公开主流程）

### P2：进一步体验优化

1. 声明式 CommandSpec 和文档生成。（`V02-D08`，未排期且不阻塞 v0.2.2/v0.2.3）
2. 更完整 operation list/follow 过滤。
3. boot preview section/filter 优化。
4. 若确有需求，再设计 Profile history 与 `--from-revision`（`V02-D12`）。

---

## 17. 最终正常流程

创建新 Profile：

```text
nodeforge assets import rocky-9.7.iso
nodeforge profile create rocky-9.7 --qualifier compute --kind diskless
nodeforge profile rootfs build rocky-compute
nodeforge node add c001 mac=... arch=aarch64 profile=rocky-compute deploy=false
nodeforge node readiness c001
nodeforge node boot preview c001
nodeforge node deploy c001 true
```

从已有 Profile 派生：

```text
nodeforge profile clone rocky-base rocky-compute \
  diskless.overlay.tmpfs_percent=70 \
  --build
nodeforge node set c001 profile=rocky-compute
nodeforge node readiness c001
nodeforge node boot preview c001
nodeforge node deploy c001 true
```

恢复：

```text
nodeforge node show c001
nodeforge node retry c001
```

需要强制取代活动状态时：

```text
nodeforge node retry c001 --force
```

只有诊断时才进入：

```text
nodeforge node session list
nodeforge node trace c001
nodeforge events list --node c001
nodeforge operation show <id>
```

---

## 18. 总结

NodeForge CLI 的收敛原则是：

> 默认用一个目标级命令完成正常流程；daemon 管理原子事务、并发、operation 和运行时
> 状态机；细粒度 CLI 用于高级配置、诊断和恢复；设计文档、代码注释、测试与当前实现
> 必须共同维护同一事实。

`profile clone` 与 `node boot preview` 是该主流程的一部分；`boot-prepare`、session credential、
revision CAS 和 operation transition 则主要是内部机制，不应成为普通用户必须理解的步骤。

---

## 19. 后续方案与变更管理

### 19.1 新方案必须声明关系

后续 CLI 优化方案必须在顶部使用相同元数据表，并明确填写：

```text
文档 ID
状态
创建时间
最后更新
适用范围
基线
关系
取代
后继文档
```

不能只凭文件修改时间判断新旧关系，也不能因为文件名含 `CURRENT` 就默认取代其他文档。

示例：

```text
关系：amends CLI-PLAN-2026-07-28-01 §3、§9
取代：无
```

表示只修改同步/operation 与 retry，本文其他章节继续有效。

```text
关系：supersedes CLI-PLAN-2026-07-28-01
取代：CLI-PLAN-2026-07-28-01
```

表示新方案完整取代本文。届时必须把本文状态改为 `superseded`，并填写后继文档 ID 和链接。

### 19.2 冲突裁决顺序

发生冲突时按以下顺序判断：

1. 检查文档状态；`superseded/withdrawn` 不作为当前目标。
2. 检查 `supersedes/amends/complements` 显式关系。
3. 检查适用范围；独立范围可以同时有效。
4. 检查被 amend 的具体章节；未列出的旧章节继续有效。
5. 检查实际实现和验证状态；设计目标与已实现事实必须分别报告。
6. 若仍无法裁决，新增决策记录，不按日期或文件名静默覆盖。

日期只用于审计排序。较新的文档如果没有声明取代关系，不自动覆盖较旧文档。

### 19.3 文件命名

本文保留稳定文档 ID；后续新方案建议使用带日期和主题的文件名：

```text
YYYY-MM-DD_<TOPIC>_PLAN.md
```

例如：

```text
2026-08-10_CLI_OPERATION_PROGRESS_PLAN.md
```

若本文以后被完整取代，可在保留历史文件的同时，让 `docs/README.md` 的“当前 CLI 方案”
入口指向新的 accepted/implementing 文档。

### 19.4 变更记录

| 日期 | 变更 | 关系/原因 |
|---|---|---|
| 2026-07-28 | 创建全面 CLI 收敛方案 | 汇总当前实现对照、用户异议和 clone/boot preview 决策 |
| 2026-07-28 | 增加文档 ID、生命周期、关系词与后续方案裁决规则 | 防止未来仅凭日期或文件名判断覆盖关系 |
