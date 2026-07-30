# NodeForge v0.2 发布后收口清单

状态：范围裁决完成；真实差异已纳入 v0.2.3  
建立日期：2026-07-30  
适用基线：v0.2.2 / `dd95376`

本文只回答两个问题：

1. v0.2.2 发布后还有哪些真实实现差异需要关闭；
2. 哪些项目已明确移出 v0.2，不得再作为 v0.2.2 未完成项统计。

历史设计和验证记录可以继续提到已经发生的 QEMU、x86_64 或实验方案，但不能据此
重新扩大当前完成闸。范围冲突时，v0.2.2 以
[`V0_2_2_OPERABILITY.md`](V0_2_2_OPERABILITY.md) §8 为准。

本文第 2 节是“明确暂不做/不纳入当前完成闸”项目的**唯一权威索引**。其他现行设计
只引用这里的稳定 ID，不复制或重新解释裁决。历史记录出现同名项目时，以本表状态为准。

真实差异的权威目标设计现为
[`V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md`](V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md)；
本文不再单独扩展实现范围。

## 1. 已完成，不再列入残留

- rootfs 与 initrd 均使用 durable operation 和 daemon worker；
- `operation list/show/follow/wait`、默认 follow 与 builder `--detach`；
- kind-aware 服务端原子 `node retry`；
- `node boot preview` 严格只读；
- `boot-prepare` 已从公开 CLI 移除，仅保留内部 management transition；
- `node postprocess show`；
- 正式 `docs/cli/REFERENCE.md` 与 CLI help 契约测试；
- 当前环境 aarch64 VMware 中 Rocky/Ubuntu install 与 diskless 产品链。

源码中未绑定命令树的旧同步 initrd handler 属死代码清理，不代表产品路径仍同步执行。

## 2. 明确暂不做/不纳入当前完成闸（权威索引）

状态分类：

- `ENV-DEFERRED`：产品支持不变，但当前环境无法完成目标 E2E；解除条件由验证边界文档管理；
- `OPTIONAL-EVIDENCE`：可以执行，但不属于每个版本候选的强制证据；
- `REJECTED-PATH`：已裁决不采用的实现路径，不得作为待办重新提出；
- `SCHEDULED`：不属于 v0.2，已进入明确后续版本；
- `UPSTREAM-BLOCKED`：等待外部运行时条件解除后才允许重新评估；
- `UNSCHEDULED`：当前无产品需求和版本承诺，必须先重新设计、排期才能实施；
- `PERMANENT-NONGOAL`：违反产品边界，永久不进入路线图。

| ID | 项目 | 状态 | 裁决与唯一去向 |
|---|---|---|---|
| `V02-D01` | x86_64 VMware UEFI E2E 与 Rocky/Ubuntu 矩阵 | `ENV-DEFERRED` | 不属于 v0.2.2/v0.2.3 完成闸；解除条件见 [`LOCAL_VALIDATION_DEFERRED.md`](LOCAL_VALIDATION_DEFERRED.md) `ENV-X86-VMWARE` |
| `V02-D02` | 每个候选重复跑 QEMU | `OPTIONAL-EVIDENCE` | VMware 已证明同一产品链时不要求；仅作诊断、故障注入或补充证据 |
| `V02-D03` | Ubuntu 方案 B（rootfs 内 mkinitramfs） | `REJECTED-PATH` | 不是生产路径，不实施；实验记录仅供追溯，不进入路线图 |
| `V02-D04` | BIOS/PXELINUX | `SCHEDULED` | 不属于 v0.2；进入 v0.3 |
| `V02-D05` | 多 NIC/topology、大规模容量/SLO | `SCHEDULED` | 不属于 v0.2；进入 v0.4 |
| `V02-D06` | `ram_rootfs` | `SCHEDULED` | 不属于 v0.2；进入 v0.5 |
| `V02-D07` | Zig 0.16 显式 connect deadline | `UPSTREAM-BLOCKED` | 当前 runtime 会 panic，不能安全启用；上游解除后专项处理 |
| `V02-D08` | 声明式 CommandSpec 自动生成全部文档 | `UNSCHEDULED` | 体验/维护性优化；仅为后续 CLI P2 候选，无版本承诺 |
| `V02-D09` | operation progress event | `UNSCHEDULED` | 当前状态、日志和终态已满足发布；仅为后续可观测性候选 |
| `V02-D10` | 全域统一 `checks[]` schema | `UNSCHEDULED` | 现有契约已冻结可用；仅在后续 DTO 升级时重新评估 |
| `V02-D11` | operation cancel | `UNSCHEDULED` | 当前没有取消语义承诺；需求出现后先设计状态机和清理契约 |
| `V02-D12` | Profile history / `--from-revision` | `UNSCHEDULED` | 当前无产品需求；需求出现后重新设计 |
| `V02-D13` | reconciliation、远程任务/通用命令、长期 enrollment | `PERMANENT-NONGOAL` | 违反一次性确定执行器和短期交付凭据边界，不实施 |
| `V02-D14` | IPv6、NFS root、iPXE | `UNSCHEDULED` | v0.2.x 无需求、设计或版本承诺；不得按残留项补做 |

引用规则：

1. 现行设计提及表中项目时必须带 ID，例如“`V02-D03`，不实施”；
2. 不得用 TODO、缺口、残留、待补验证描述 `REJECTED-PATH`、`PERMANENT-NONGOAL`
   或 `OPTIONAL-EVIDENCE`；
3. `ENV-DEFERRED` 只有满足对应解除条件并建立专项验证记录后才变更状态；
4. `SCHEDULED` 只由目标版本设计定义完成闸，不得反向阻塞 v0.2.x；
5. `UNSCHEDULED` 和 `UPSTREAM-BLOCKED` 必须经过新的设计裁决才能进入版本计划。

这些项目不能再出现在“v0.2.2/v0.2.3 必须补完”或发布阻断清单中。

## 3. 仍需关闭的真实 v0.2 设计差异

### 3.1 Profile identity、provenance 与 clone

当前 rootfs build 在 staging 中生成 SSH client/host keys；Profile 没有持久 identity
revision/fingerprint，也没有 create/clone provenance。当前 clone 只原子复制 desired
configuration。

目标收口：

1. daemon-owned Profile SSH identity store；
2. create 时生成固定 identity；
3. clone 默认复用 identity，`--new-ssh-keys` 创建新 identity；
4. identity revision/fingerprint 纳入 rootfs input digest；
5. Profile 保存 origin、source、created/updated、cloned-from provenance；
6. clone 支持同事务 property patch；
7. `--build [--detach]` 明确采用“clone 已提交、build 提交结果单独返回”的组合语义；
8. 旧 Profile 首次使用时进行确定性、可审计的 identity 初始化。

这是当前唯一成组的 v0.2 数据模型缺口。实现会改变 catalog/state shape，
catalog schema 采用直接替换（不迁移，见 v0.2.3 设计 §0），
必须先冻结 identity 事务恢复，再修改 CLI。

### 3.2 Recovery 语义裁决

现行文档要求“capability 未完整交付前重启进入 `recovery_incomplete`”；当前实现使用
持久 master secret + session/scope 确定性重构同一个 raw token，并以持久 hash 复核。
两者不能同时作为权威语义。

必须先选择并记录其中之一：

- 保留确定性重构：证明不会产生第二 token、不会扩大 scope，并修正文档与负测；
- 保留 `recovery_incomplete`：增加交付完成 checkpoint，重启时禁止为未完成交付重构。

裁决前不得仅修改注释掩盖差异。

### 3.3 ISO import 后台执行边界

ISO import 已创建 durable operation、支持幂等和终态持久化，但 handler 当前启动线程后
同步 join。它不是 rootfs/initrd builder 完成闸的一部分，但若继续承诺“三类长任务统一”，
需要改为 daemon-owned 后台队列，并补 restart→interrupted、partial cleanup 和 detach/follow。

### 3.4 CLI 错误映射收敛

CLI 已使用 0/1/2/5/6 等退出类，但映射仍分散。该项不影响已验证业务链，作为兼容性
收口处理：

1. 建立 API error/status → stable exit class 的唯一函数；
2. 保持现有公开 error.code；
3. 用契约测试覆盖 invalid input、conflict、not-ready、operation failed、unreachable；
4. 不借此重写全部 handler 或改变成功输出。

## 4. 实施顺序

必须按以下顺序，不能并行修改持久 shape：

1. recovery 语义裁决与测试基线；
2. Profile identity/provenance schema、migration、fixture；
3. create/clone/rootfs identity 接线；
4. clone patch、`--new-ssh-keys`、`--build/--detach`；
5. ISO import 真后台 operation；
6. CLI exit mapping 收敛；
7. 删除旧同步 initrd handler与过期注释；
8. 全量自动化和当前 aarch64 VMware 定向回归。

## 5. 完成判定

上述真实差异关闭后，v0.2 不再保留实现 backlog。第 2 节项目只有在其所属版本或外部
条件满足时才重新进入计划，不能反向修改 v0.2.2 的完成结论。
