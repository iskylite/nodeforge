# NodeForge v0.2-v0.5 CLI 流程查漏补缺审计

状态：2026-07-22 设计审计。本文记录对 `docs/design/` 下 v0.2-v0.5 全部设计文档的系统性 CLI 流程
审查，对照现有 v0.1 实现（`src/main.zig`、`src/model.zig`、`build.zig`、`tests/cli.sh`），识别缺口、
不一致和遗漏细节，并记录本轮修复的每一处变更。本文是审计证据，不定义产品行为；v0.2 总纲入口为
`docs/design/V0_2_DESIGN.md`，CLI 细节由 `docs/design/V0_2_CLI.md` 负责。

本文是历史快照；下文的 `firmware.mode`/BIOS、v0.4 static bootstrap、BootConfig v4、跨版本
active session 和 DTO 迁移条目仅作当时的审计记录，不再定义当前范围或协议。当前 v0.4 行为以
[`V0_4_DESIGN.md`](../design/V0_4_DESIGN.md) 为准，版本号和顺序以
[`V0_2_1_PLUS_ROADMAP.md`](../design/V0_2_1_PLUS_ROADMAP.md) 为准。标题和下文的“v0.5”是已撤销的历史标签；
当前对应内容只作为 [`ram_rootfs` 独立保留设计](../design/RAM_ROOTFS_DEFERRED.md)，不代表后续产品版本。

## 1. 审查范围

| 文档 | 角色 | 行数 |
|---|---|---|
| `V0_2_CLI.md` | v0.2 完整 CLI 接口 | 562 |
| `V0_2_DESIGN.md` | v0.2 设计范围与契约 | 959 |
| `V0_2_DISKLESS_WORKFLOW.md` | 从零构建/启动操作闭环 | 321 |
| `V0_2_IMPL_DETAILS.md` | 状态机/协议栈/effective compiler | 398 |
| `V0_2_PROGRAM_DESIGN.md` | 三程序边界 | 209 |
| `DISKLESS_FINAL.md` | diskless 收敛基线 | 395 |
| `V0_3_DESIGN.md` | BIOS PXELINUX install | 167 |
| `V0_4_DESIGN.md` | 历史版延后增强项（本审计快照） | 240（审计时） |
| `RAM_ROOTFS_DEFERRED.md` | 可切换 rootfs 形态；本审计当时称 v0.5 | 主题化保留稿 |
| `V0_2_V0_5_DESIGN_REVIEW.md` | 已有设计评审 | 106 |

对照代码：`src/main.zig`（CLI 入口）、`src/model.zig`（`BootKind`/`AssetKind`/`ProvisionAction`/
`BootBundleConfig`）、`build.zig`（构建产物）、`tests/cli.sh`（CLI 契约测试）。

## 2. 代码事实基线（v0.1 现状）

| 设计要求 | v0.1 代码现状 | 差距 |
|---|---|---|
| `BootKind = install\|diskless` | `model.zig:329` 只有 `install` | 需 v0.2 扩展 |
| `AssetKind` 含 `runtime_kernel`/`archive`/`script` | 只有 `iso/bootloader/kernel/installer_initrd/nodeforge_initrd/rootfs/gpg_key/managed_file` | 缺 `runtime_kernel`/`archive`/`script` |
| `BootBundleConfig` 不含 rootfs ref | `model.zig:539` 有 `rootfs: []const u8` | 构建环，需 v0.2 删除 |
| `ProvisionAction` = 四类 action | 只有 `repository/standard_packages/managed_file` | 旧 action 需迁移，缺 `archive/script/package` |
| `ProvisionPhase` = canonical 三 phase | 只有 `install_post` | 缺 `rootfs-build/first-boot`，命名需规范化 |
| `build.zig` 产出 initrd/agent | 只产出 `nodeforged`/`nodeforge` | 缺 `nodeforge-initrd`/`nodeforge-agent` |
| CLI 有 `managed-file import` | 有（`main.zig:414`） | 缺 `archive/script import` |
| CLI 有 `provision-bundle item remove` | 有（`main.zig:741`） | V0_2_CLI.md 遗漏未列 |
| CLI 有 `provision-bundle list` | 代码有 list handler | V0_2_CLI.md 遗漏未列 |
| CLI 有 `profile list` | 代码有 list | V0_2_CLI.md 遗漏未列 |
| exit code 1 | `tests/cli.sh` 使用 exit 1 | V0_2_CLI.md §0 遗漏 exit 1 |

## 3. 发现的缺口与修复

### 3.1 V0_2_CLI.md §0 共用约定

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 1 | exit code 缺 1，且本地错误/daemon unavailable 边界不清 | P1 | 1 固定为本地执行错误，6 固定为 daemon unavailable/timeout |
| 2 | `--wait` 语义未定义 | P1 | 补阻塞/超时；human/json 进度走 stderr，jsonl 可逐行；stdout 保持可解析 |
| 3 | operation 缺统一查询，id 格式被过早冻结 | P1 | id 改为不可解析的 128-bit+ opaque value；补 `operation show/wait` |
| 4 | CAS flag 名不统一，普通 mutation 与 v0.1 自动 If-Match 的关系不清 | P2 | 普通调用原子使用最新 snapshot；所有 `--if-*` 仅作为自动化可选防漂移 guard，显式冲突后不得重试 |
| 5 | daemon 依赖未说明 | P2 | 列出哪些命令需要 daemon 在线、哪些是纯本地文件操作 |

flag 专项盘点后的保留/收敛决定：

| flag/模式 | 决定 | 理由 |
|---|---|---|
| `--wait [--timeout]` | 保留一个统一语义 | 只决定是否等待已经提交的同一 operation；不改变业务输入，timeout 不取消服务端任务 |
| 四个 `--if-*` | 保留为可选高级 guard，移出正常示例 | guard 对象不同，硬合并成通用 token 反而更难读；普通用户无需复制 digest/revision |
| `--from-revision` | 保留 | 选择 clone 的历史 source revision，不是并发 guard |
| `--new-ssh-identity` / `--regenerate-ssh-keys` | 合并为 `--new-ssh-keys` | clone/build 统一重新生成 Profile SSH client keypair + sshd host keys，并重算 authorized_keys/ssh_known_hosts |
| rootfs `--force` | 删除，改 `--verify-reproducibility` | 原行为不覆盖对象，仅重建比较；`force` 会误导为绕过检查或覆盖 |
| `--build` on clone | 保留 | 明确表示 clone 成功后组合提交 rootfs build；`--wait` 只有同时带 `--build` 才合法 |
| filter/view flags | 保留 | `--kind/state/section/stage/session/node` 都只选择输出范围或验证阶段，没有重复 mutation 语义 |

### 3.2 V0_2_CLI.md §1 阶段 0

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 6 | `preflight` 命令形式与 `V0_2_DISKLESS_WORKFLOW.md` 不一致（子命令 vs `--scope`） | P1 | 只保留 canonical `preflight diskless-builder`，不维护双 parser key |
| 7 | `preflight` human 输出格式未定义 | P2 | 补分组对齐表示例 |

### 3.3 V0_2_CLI.md §3 阶段 2

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 8 | `archive import`/`script import` flag 未文档化 | P2 | 补 asset import flag 约束表 |
| 9 | `provision-bundle list` 遗漏 | P2 | 补到命令树 |
| 10 | `provision-bundle item remove` 遗漏 | P2 | 补到命令树 |
| 11 | per-action 必填/禁止字段矩阵缺失 | P1 | 补四类 action 字段矩阵 |

### 3.4 V0_2_CLI.md §5 阶段 4

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 12 | `profile list [--kind]` 遗漏 | P2 | 补到命令树 |
| 13 | `profile create` 向后兼容未说明 | P1 | 补默认 `--kind install` |
| 14 | `profile effective` section 未定义 | P2 | 补 `--section build\|boot\|all` |
| 15 | `profile remove` 是否存在未说明 | P1 | 明确为 v0.2 非目标；未来须经 tombstone/retention 设计，不提前冻结全版本 |
| 15a | diskless Profile 克隆/派生构建缺失 | P1 | 补 `profile clone SOURCE TARGET [--set] [--new-ssh-keys] [--build] [--wait]`；target 创建后独立 |
| 15b | `profile show` 无法追溯来源 | P1 | 固定输出 InstallSource revision/imported time、created/updated time、直接 clone source/revision/time 与只读 clone chain |

### 3.5 V0_2_CLI.md §6 阶段 5

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 16 | `node effective` vs `node show` 区分缺失 | P1 | 补二者职责区分 |
| 17 | `node remove` 是否存在未说明 | P1 | 明确为 v0.2 非目标；未来须经 tombstone/retention 设计 |

### 3.6 V0_2_CLI.md §7 阶段 6

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 18 | `rootfs plan` 输出的 digest 字段名/位置未明确 | P0 | 补 JSON 关键字段与 digest 取值路径 |
| 19 | `node effective --section build` vs `rootfs plan` 关系未说明 | P1 | 补超集关系说明 |
| 19a | rootfs 重建时无法直接轮换共享 SSH keys | P1 | 补 `profile rootfs build --new-ssh-keys [--wait] [--if-input-digest DIGEST]`，生成新 Profile revision/input digest 后直接构建 |
| 19b | 日常流程强制复制 digest/revision，flag 语义重复 | P1 | `--if-*` 统一降为自动化可选防漂移 guard；普通调用原子使用最新 snapshot；`--wait` 只控制是否等待同一 operation |
| 19c | rootfs `--force` 名称暗示覆盖，实际仅验证可复现性 | P1 | 改为 `--verify-reproducibility`，明确不覆盖旧 artifact，并与 `--new-ssh-keys` 互斥 |

### 3.7 V0_2_CLI.md §8 阶段 7

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 20 | `--if-plan-digest` 取哪个 digest、从哪获取未说明 | P0 | 补 digest 来源（`rootfs plan`/`effective`） |
| 21 | `boot preview` 输出格式未定义 | P2 | 补 human/JSON 输出格式 |

### 3.8 V0_2_CLI.md §9 阶段 8

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 22 | `node status` 输出格式未定义 | P2 | 补 human/JSON 输出说明 |
| 23 | `runtime dhcp-leases`/`tftp-sessions` 输出格式未定义 | P2 | 补列定义 |
| 24 | `events list` 缺 `--until`/`--limit`，时间边界未说明 | P2 | 补全 filter set，并按现有 event reader 固定 `since/until` 为闭区间 |
| 25 | `events types` 遗漏 | P2 | 补到命令树 |

### 3.9 V0_2_CLI.md §10-11 阶段 9-10

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 26 | `postprocess show` 不带 `--session` 默认行为未说明 | P2 | 优先当前 active session；无 active 才查最近终态 session |
| 27 | `--include-output` 语义未说明 | P2 | 补输出内容与裁剪规则 |
| 28 | `status --component rootfs-cache` 输出格式未定义 | P2 | 补 human 输出表 |
| 29 | `status --component quarantine` 输出未说明 | P2 | 补输出说明 |

### 3.10 V0_2_CLI.md 新增 §13

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 30 | 三个 digest 在 CLI 各阶段的使用无集中说明 | P0 | 新增 digest 流转表 + 从零启用流程示例 |

### 3.11 跨版本不一致

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 31 | v0.3 §7 用 `postinstall`，v0.2 用 `postprocess` | P0 | v0.3 统一为 `postprocess`，补命名理由 |
| 32 | v0.4 §8 用 `postinstall` | P0 | v0.4 统一为 `postprocess` |
| 33 | v0.5 引入 `node rootfs show`，且 rootfs 所有者误放在 Node | P1 | 统一复用 `profile rootfs status`；Node status 只解析绑定 Profile |
| 34 | v0.3 `firmware.mode` 在 `node list`/`show` 输出未说明 | P2 | 补 `FIRMWARE` 列与 `node show` 输出 |
| 35 | v0.3 BIOS readiness 检查项未列出 | P2 | 补 PXELINUX/bootloader/http_accel 检查 |
| 36 | v0.4 网络 CLI 缺 schema/验证/readiness 细节 | P1 | 补 feature/schema/field 约束 |
| 37 | v0.4 曾考虑的远端构建与禁止远程任务、共享 cache 冲突 | P0 | 删除远端构建入口；rootfs 只由 nodeforged 服务端 operation 生成 |
| 38 | v0.4 容量压测无 CLI 说明 | P2 | 说明复用现有观测命令，不新增专用命令 |
| 39 | v0.5 迁移 CLI/步骤未说明 | P2 | 补 schema v6->v7 迁移行为 |
| 40 | v0.5 `ram_rootfs` 对 `rootfs plan`/`boot preview` 输出影响未说明 | P2 | 补输出差异说明 |

### 3.12 第二轮跨版本契约复审

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 41 | 任意 Node 修改被写成同时改变两个 digest | P0 | 按 build-safe/per-Node projection/output 三类输入建立漂移矩阵 |
| 42 | v0.5 compressed/uncompressed 语义冲突 | P0 | 固定共用 squashfs 传输 artifact，保留两种 materialization |
| 43 | BootConfig `config_digest` 包含自身 | P0 | digest 输入省略自身并规范化 capability token |
| 44 | delivery digest 到 DHCP ACK 才生成过晚 | P0 | 在允许 bootfile 前随 session/delivery snapshot 原子生成 |
| 45 | session create CAS=null 与 supersede 冲突 | P1 | supersede CAS observed old id，并在同一事务撤销旧 token/安装新 id |
| 46 | managed-file `group` 同时可选和禁止 | P1 | 从禁止字段删除，补禁止 `selection` |
| 47 | v0.3 BIOS 对 diskless 的适用性不明 | P1 | v0.3 仅 install BIOS；diskless BIOS readiness fail closed |
| 48 | install-post status/retry 错套 boot session | P0 | 使用 install generation；只在 installer execution 内自动 retry |
| 49 | v0.4 多 NIC 用平铺 scalar，不能表达多对象 | P0 | 改为 interfaces/vlans/bonds/routes ItemSpec + 引用图验证 |
| 50 | v0.4 bootstrap/target 网络切换无字段与迁移 | P1 | 补 bootstrap_interface_id、BootConfig v4、v5->v6 逐字段迁移 |
| 51 | rootfs 生产边界若不唯一会产生不可验证分叉 | P0 | 唯一生产者固定为 nodeforged，产物深验后原子发布服务端 cache |
| 52 | install first-boot 普通重启的一次性证据缺失 | P0 | generation-bound 磁盘 handoff/journal + 短时 token 交换 |
| 53 | 容量“生产级”没有可验证目标 | P1 | 强制版本化 workload、资源预算、p95/p99 SLO 与原始指标 |
| 54 | v0.5 mode 无法由当前 BootConfig 表达 | P0 | v0.4 bootstrap transport 升 BootConfig v4、target topology 升 AgentPlan v2，v0.5 materialization 升 BootConfig v5 |
| 55 | mode 是否分裂 rootfs cache 未定义 | P0 | mode 进 desired/delivery，不进 rootfs input；复用同一 squashfs |
| 56 | ram_rootfs 下 tmpfs_percent 被静默忽略 | P1 | 定义为 expanded writable root 的最大 MemAvailable 比例 |
| 57 | v0.2 profile/node remove 被过度提升为永久非目标 | P1 | 降为 v0.2 非目标，后续版本保留 tombstone 设计空间 |

### 3.13 第三轮实现契约与认证复审

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 58 | Assets import 草案改变 v0.1 冻结 owner/参数顺序 | P0 | 恢复 `<asset> --from-file <path>`；destination/mode/owner/group/interpreter/phase 只属于 bundle step |
| 59 | provision bundle 被拆成 phase 命令 flag，破坏 canonical collection | P0 | 固定唯一 `steps` collection，`phase` 为 step 必填 tagged 字段 |
| 60 | `profile effective --section boot` 越权伪造 Node 网络、内存和 readiness | P0 | Profile 只输出可证明 requirements；resolved boot projection 归 `node effective` |
| 61 | `postprocess show` 默认最近终态会掩盖运行中的 first-boot | P1 | 改为 active-first，无 active 才回退最近终态 |
| 62 | v0.3 install-post callback 仅凭 node/generation 关联，缺少认证和重放边界 | P0 | 增 generation-bound、hash-only、append-only credential，绑定 plan/path/method/expiry 与单调 event_seq |
| 63 | v0.4 topology 缺 route identity，v5->v6 迁移可能丢 route/DNS/search domain | P0 | 增 `network.routes[]`、稳定 id/order/interface_id，并冻结无损迁移 |
| 64 | v0.4 若仅复杂网络升级 schema，单 NIC delivery 会继续产生双协议 | P0 | 全部 v0.4 新 delivery 统一使用 BootConfig v4 + AgentPlan v2；单 NIC target 也使用单元素 topology，既有 v3/v1 session 消费原 snapshot |
| 65 | rootfs 生产位置不唯一会扩大 boot-slot、token 和 cache-key 边界 | P0 | 固定 nodeforged 服务端生产，删除节点侧状态和上传链路 |
| 66 | install first-boot bootstrap 只描述 handoff，缺一次性认证交换 | P0 | 增至少 256-bit bootstrap token、hash-only 存储、0400 落盘、原子 spent 后换 event token 及负向测试 |
| 67 | ram_rootfs 内存公式、feature 适用性和展开保真未形成可验收契约 | P0 | 冻结双预算公式与 u64 checked arithmetic；按 mode 要求 feature，并验证 unsquashfs metadata 保真 |
| 68 | install callback credential 有 claim 但无 raw token 安全交付路径 | P1 | 增 per-generation credential capsule、0400 文件、泄漏禁令与 restart hash 验证 |
| 69 | 物理 Node 属性进入 input digest 会导致共享 cache 不稳定 | P0 | 物理 Node 完全不参与 rootfs 构建投影 |
| 70 | ram_rootfs 峰值漏算压缩副本且在 initrd `MemAvailable` 上重复扣 kernel/initrd | P0 | 规范化 available budget，峰值计 compressed+uncompressed，并给出 checked required-min 公式 |

### 3.14 第四轮协议恢复、迁移与后续版本可执行性复审

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 71 | 将每个新 DHCP XID 都视为新 boot 会让合法重传反复 supersede session | P0 | 增 XID correlation window 与 transaction alias；只有 config 后新 DHCP、超时或其他 boot evidence 才原子 supersede |
| 72 | BootConfig token 的“一次 GET”无法容忍 HTTP 重传，且重复 GET 可能重复推进 phase | P0 | 改为 single-purpose bounded-replay；首个 digest 固定 immutable bytes，相同 digest 的 initrd-start ack 后撤销 |
| 73 | hash-only token 在 capsule 交付前/中 daemon restart 后不可恢复 raw secret | P0 | 明确 raw token 只驻内存；客户端未完整取得时终止为 `recovery_incomplete`，已取得后才支持 hash 验证恢复 |
| 74 | 无效外部 token/Range 探测可能被错误归责给受害 session 并触发 quarantine | P0 | 401 未关联审计、403 verified claim 归责、410 终止 claim、416 达 abuse threshold 后才归责 |
| 75 | v0.2 readiness/initrd 内存公式重复扣 kernel/initrd，字段名也不统一 | P0 | readiness 用 inventory 减 kernel/initrd，initrd 直接用 MemAvailable；统一 `required_min_memory_bytes` 与 checked u64 |
| 76 | migration rollback 与 finalize 后 downgrade 混为一谈，缺不可表示状态错误契约 | P0 | 统一 transaction journal rollback、representability preflight、`migration.non_representable` 与 active snapshot 不重编译 |
| 77 | v0.4 只有物理 interface 能承载 L3，bond/VLAN topology 无法表达真实目标网络 | P0 | 三类 link 统一 tagged IPv4；renderer 归 adapter；补 member L3、地址冲突、route 与 VLAN-on-bond 约束 |
| 78 | DHCP-less static PXE 没有 BootSession/capsule 创建入口，opaque URI 被误当身份 | P0 | 增 bootstrap mode、独立静态地址、source/L2 binding、首次 config 请求 CAS 创建会话与 scoped capsule |
| 79 | bootstrap 到 target topology 只写“可达”，缺事务切换和回滚证据 | P0 | 固定 stage/activate/authenticated proof/commit/adopt 流程；失败保留 bootstrap，禁止只用 ping 判定 |
| 80 | 节点侧构建 lifecycle 会引入 restart/expiry/upload staging 恢复域 | P0 | 删除该恢复域；中断的 rootfs operation 只在 nodeforged 服务端重提 |
| 81 | install first-boot exchange 在响应中断前先 spent，会永久丢失 event token | P0 | 增 `exchanging` 与有界换发；原子撤销旧 event claim，首次 event ack 后才 spent |
| 82 | ram_rootfs 解压后未要求删除压缩 `.part`，steady-state 内存声明可能失真 | P0 | handoff 前删除压缩制品并证明无 loop/fd 引用，失败不得进入 steady-state budget |
| 83 | v0.5 readiness 拒绝 v3 的措辞会误杀升级前 active/recoverable session | P0 | 只拒绝新 v0.5 delivery；旧 v3 immutable snapshot 跨升级继续到终态 |

### 3.15 第五轮 Profile/Node/SSH 与可复现性复审

| # | 缺口 | 严重度 | 修复 |
|---|---|---|---|
| 84 | workflow 的 asset import 与 bundle item add 仍使用已废弃双语法 | P0 | 统一为 `import NAME --from-file PATH`；item 只经 `steps` collection 的 `phase=...` 字段表达 |
| 85 | Node software override 不进入 rootfs，若切根后补包缺少固定输入和执行契约会形成不可控分叉 | P0 | software 全 collection 编译为 immutable `node_apply_projection`；agent 按 pinned local repository revision/exact add-remove package closure 重放；clone Profile 仅作公共重差异的效率优化 |
| 86 | diskless password hash 若沿用 install per-session salt会破坏 rootfs input 可复现性 | P0 | 每个 Profile credential revision 生成一次并持久复用 `$6$` hash；install v0.1 逻辑不变 |
| 87 | Node authorized key remove/hosts override 可意外破坏 Profile 域互信 | P1 | 自动 client public key 为 mandatory；effective hosts 改变时以共享 host public key 重算 known_hosts |
| 88 | v0.2 时序先写 upper 再挂 lower，agent 身份只写 node_id | P0 | 固定 download/verify/mount -> projection -> payload handoff 顺序；身份由 cmdline/snapshot/token claim 共同证明 |
| 89 | 构建工具 revision 已进入 input digest，但 cache key 又重复拼 revision | P1 | ready artifact/build lease 统一只以 `rootfs_input_digest` 标识 |
| 90 | v0.5 squashfs mode 在 schema v7 内仍写“不声明”，且 owner 未固定 | P1 | 两种 mode 在 v0.5 都显式取值；固定为 diskless Profile-only policy |
| 91 | 构建执行策略进入 desired digest，且 input guard 无法锁定 operation policy | P1 | 删除可选执行位置；`--if-input-digest` 只锁服务端构建内容 |
| 92 | diskless 声称复用 install Node override，但 repository 被写成 not-applicable，且没有 Node 级 first-boot bundle 等价路径 | P0 | software 全 collection 进入 pinned node-apply；新增 `overrides.diskless.provision.bundle`，限定 first-boot-only，payload 由 agent pre-init 按 session-pinned AgentPlan 预取校验 |
| 93 | initrd 若写 users/SSH/hosts/network 等 Node override，会复制 TargetSystem projector；同时保留 `target_system_delta`/`node_apply_projection` 又形成双执行模型 | P0 | 合并为唯一 `node_apply_projection`；initrd 只 transport/verify/mount/handoff，切根到 agent pre-init 应用全部运行根差量并 exec 真正 init；kernel args 仍由 boot projection 在内核前生效 |
| 94 | initrd 下载完整 projection/Node payload 会让 agent 退化为本地 runner，不符合“从服务端获取配置再执行”的框架定位 | P0 | BootConfig 缩为 boot/rootfs + AgentPlan locator；agent pre-init 用 session-bound `agent:read` 拉取并校验 immutable plan/全部 payload，清除读 token 后执行；禁止 latest/catalog/轮询/远程命令，first-boot 不联网 |

## 4. 修复文件清单

| 文档 | 修改内容 |
|---|---|
| `V0_2_CLI.md` | §0 补 exit/--wait/opaque operation/daemon 依赖/CAS；§1 canonical preflight；§3 action 矩阵；§5-11 补命令与输出；§13 补 digest 流转和漂移分类 |
| `V0_2_DESIGN.md` | §5.5 补命令；§7 将 remove 限定为 v0.2 非目标；§9.3 拆 phase-specific retry；补 SSH/profile password/Node override 不变式与设计轨迹 |
| `V0_2_DISKLESS_WORKFLOW.md` | preflight、asset import、`steps` ItemSpec 命令统一；补 Profile baseline、Node node-apply 与 SSH 域语义 |
| `V0_3_DESIGN.md` | §7 `postinstall` -> `postprocess`；补 FIRMWARE 列/BIOS readiness/install-post 字段矩阵与 generation-bound callback credential |
| `V0_4_DESIGN.md` | 历史版曾规划可承载 L3 的四 collection topology、static bootstrap session、事务网络切换、BootConfig v4 + AgentPlan v2 和 install token exchange；当前行为以统一 v0.4 设计为准 |
| `RAM_ROOTFS_DEFERRED.md` | 历史审计曾固定的共享 squashfs artifact、digest/cache/双公式内存预算与临时制品删除；当前 DTO/schema 编号不再预占 |

## 5. 未修复的已知实现差距（设计已覆盖，代码待实现）

以下差距在设计中已完整定义，但 v0.1 代码尚未实现，属 v0.2 实现工作而非设计缺口：

- `BootKind` 扩 `install|diskless`（`model.zig:329`）
- `AssetKind` 增 `runtime_kernel`/`archive`/`script`
- `BootBundleConfig` 删 `rootfs` ref，增 `runtime_kernel` ref
- `Profile` 补共同 `install_source`、Profile SSH client/host keys revision、`system.hosts` 和 clone 审计 provenance
- `ProvisionAction` 迁移为 `managed-file|archive|script|package`，删 `repository`/`standard_packages`
- `ProvisionPhase` 扩 `rootfs-build|first-boot`，canonical 命名
- `build.zig` 增 `nodeforge-initrd`/`nodeforge-agent` 产物
- 全部 v0.2 新增 CLI 命令的 handler/PropertySpec/ItemSpec 注册
- diskless effective compiler 补 `profile_build_projection`/仅含 kernel/transport 的 `node_boot_projection`/唯一运行根 `node_apply_projection`；Node override 不改 rootfs digest，全部 target-system/software/service/security 与可选 Node first-boot descriptor 由 agent pre-init 按 session snapshot 重放
- schema v3 -> v4 migration（tagged Profile kind + tagged action/phase）
- canonical BootSession 状态机 reducer、delivery record 持久化
- node-bound rootfs/AgentPlan/payload HTTP route、最小 BootConfig DTO v3、AgentPlan DTO v1、分域 scoped token

## 6. 遗留关注项（实现时需确认）

| # | 关注项 | 说明 |
|---|---|---|
| 1 | 显式 `--if-revision` 尚未实现 | v0.1 客户端会预取 catalog revision 并发送 If-Match；v0.2 需新增可选显式 flag，并确保冲突后不静默重读重试 |
| 2 | operation retention/分页 | show/wait 已固定；list/cancel/retention 留待获得真实运维数据后设计 |
| 3 | v0.4 容量阈值 | 结构已固定，具体数值必须由目标硬件基准 workload 冻结 |
| 4 | `node effective --section` vs `profile effective --section` | selector 名一致但证明边界不同：Profile 只给 requirements，Node 才给 resolved projection；可共用序列化结构，不能共用越权求值路径 |

已核实而不再列为关注项：v0.1 `events list --limit` 默认值已是 100；`since/until` 在 help、过滤器注释和
`matches()` 实现中均为包含边界。v0.2 保持这两个兼容契约。

## 7. 结论

审查覆盖 v0.2-v0.5 的 CLI、owner、认证、恢复与跨版本迁移契约，共记录 94 处缺口/不一致，均已在权威设计文档中处理。
修复未触碰任何代码、未改变 v0.1 冻结 owner 或 v0.2 进入条件。核心改进：

1. **digest 流转可操作性**：正常流程由服务端原子采用最新 snapshot，不再要求复制 digest；自动化仍可从 §13
   观察命令取得 `--if-plan-digest`/`--if-input-digest` 作为严格防漂移 guard。
2. **跨版本命名统一**：`postprocess` 统一全版本，消除 v0.3/v0.4 的 `postinstall` 矛盾。
3. **命令完整性**：补全遗漏的 `profile list`、`provision-bundle list/item remove`、`events types`、
   per-action 字段矩阵。
4. **输出可读性**：为 `preflight`/`boot preview`/`node status`/`runtime`/`status --component`/
   `rootfs plan` 补 human/JSON 输出格式。
5. **版本边界可验证**：本审计快照记录的 v0.3 install generation、历史 v0.4 BootConfig v4 草案，以及
   当时标为 v0.5 的 BootConfig/cache 草案；该标签和编号均已撤销，当前版本边界以各权威设计文档为准。
6. **保留演进空间**：remove 只作为 v0.2 非目标；未来必须经 tombstone/retention 设计。
7. **认证与构建边界闭环**：install callback 与 first-boot bootstrap 使用有界、hash-only、不可升级的一次性能力；
   rootfs 由 nodeforged 服务端生成，物理 Node identity 不进入共享 cache key。
8. **跨版本 DTO 可追溯**：本审计快照曾记录 v0.4 使用 BootConfig v4 承载 bootstrap transport、AgentPlan v2 承载四
   collection target topology；当前 v0.4 统一设计改为保持 BootConfig v3、仅升级 AgentPlan v2。后续 materialization
   只在不编号的 `ram_rootfs` 保留稿讨论，重新立项时才分配 DTO；active session 策略也以当时已实现基线重新裁决。
9. **恢复边界可证明**：XID alias、bounded replay、hash-only capsule 中断和鉴权失败归责均有确定状态/错误语义，
   外部探测不能推进或隔离受害 session。
10. **迁移不丢语义**：每版区分 finalize 前 journal rollback 与 finalize 后可表示 downgrade；不可表示状态结构化拒绝，
    active/recoverable delivery snapshot 不随 catalog migration 重编译。
