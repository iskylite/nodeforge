# NodeForge 统一延期、保留与非目标清单

状态：当前唯一权威登记表
更新日期：2026-08-05

本文统一回答“现在不做或当前不能验证的事项在哪里、为什么不进入发布闸、什么条件下可以重新进入”。版本设计只描述该版本确定实施和可执行验收的内容；所有环境延期、规模延期、未排期设计、上游阻塞、可选证据、拒绝路径和永久非目标都只在本表维护状态。

专项文档可以保存方案细节，历史 backlog 可以保存原始 ID 和裁决过程，但不得另建当前状态表。发生冲突时以本文为准。

## 1. 状态分类

| 状态 | 含义 | 是否阻断当前版本 | 重新进入条件 |
|---|---|---:|---|
| `ENV-DEFERRED` | 产品目标或实现能力保留，但当前没有可信目标环境 | 否 | 获得环境并建立独立验证记录 |
| `UPSTREAM-BLOCKED` | 被运行时、依赖或平台缺陷阻塞 | 否 | 上游条件解除后重新设计和验证 |
| `UNSCHEDULED` | 有候选价值，但没有产品需求、版本和完成闸 | 否 | 明确需求、owner、设计和排期 |
| `INDEPENDENT-DESIGN` | 已有专项设计，但不属于任何已排期版本 | 否 | 从届时产品基线重新评审并排期 |
| `OPTIONAL-EVIDENCE` | 可用于诊断或补充，但不是每个候选的强制证据 | 否 | 仅在对应故障或专项验证中执行 |
| `REJECTED-PATH` | 已明确不采用的实现路径 | 不适用 | 只有新的架构决策才能推翻 |
| `PERMANENT-NONGOAL` | 与产品架构边界冲突 | 不适用 | 必须先修改顶层架构决策 |

延期不是“默认进入下一版”。除 `ENV-DEFERRED` 只等待验证环境外，其余实现类事项重新进入路线图前都必须重新确认需求，不能预占 AppConfig、catalog、state、BootConfig、AgentPlan 或其他 DTO/schema 编号。

## 2. 环境与规模验证延期

| ID | 项目 | 当前限制 | 当前版本保留证据 | 解除条件 |
|---|---|---|---|---|
| `ENV-X86-VMWARE` / `V02-D01` | x86_64 VMware UEFI install/diskless 与 Rocky/Ubuntu 矩阵 | 当前 Apple Silicon + VMware Fusion 不能运行 x86_64 guest | x86_64 交叉编译、协议/架构 fixture、catalog/adapter/build 测试和静态审计 | 在 x86_64 VMware/物理机完成真实 PXE 产品链，Rocky/RHEL family 与 Ubuntu 至少各一次 E2E |
| `ENV-V04-PRODUCTION-SCALE` | 256/512 台真实节点并发 install/diskless/mixed 的生产吞吐与完成时间 | 当前只有 r97n0/r97n1 双机，无法生成真实 firmware、DHCP/TFTP 风暴、并发 installer/rootfs 下载和交换机负载 | r97n1 单节点真实闭环；workload harness 的 256/512/1024 逻辑 session、admission、reaper、checkpoint、HTTP/TFTP 和资源回收 | 在记录 CPU/RAM/NVMe/NIC/交换机/地址池的规模环境中完成 256 与 512 台真实节点 install、diskless、mixed 矩阵并形成独立报告 |
| `ENV-TARGET-HARDWARE` | 依赖目标专用硬件的后续能力 | 本地无对应硬件或虚拟设备 | 模型、DTO、负向测试 | 在具备对应设备的环境建立专项验证记录 |

这些项目不阻断当前版本。合成测试不能冒充目标环境 E2E；取得证据前，README、release note 和验证结论不得宣称相应生产环境已经验证。

v0.4 当前边界是：r97n1 各完成至少一次真实 install 与 diskless 功能闭环；同一候选的 workload harness 完成 256 实现容量基线、512 标准合成扩展和 1024 合成压力验证。真实 256/512 节点规模验证仍保持 `ENV-V04-PRODUCTION-SCALE`。

## 3. 未排期、独立设计与上游阻塞

| ID/主题 | 状态 | 详细文档 | 当前裁决 | 重新进入条件 |
|---|---|---|---|---|
| DHCP-less static PXE bootstrap | `INDEPENDENT-DESIGN` | [`STATIC_PXE_BOOTSTRAP_DEFERRED.md`](STATIC_PXE_BOOTSTRAP_DEFERRED.md) | 未排期，不属于 v0.4 | 固定可信网络边界、首次会话与防冒认协议，并取得目标环境 E2E |
| BIOS PXELINUX install | `INDEPENDENT-DESIGN` | [`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md) | 未排期，不属于 v0.4 | 获得可复用 x86_64 BIOS 环境，重新分配 schema/CLI |
| `ram_rootfs` materialization | `INDEPENDENT-DESIGN` | [`RAM_ROOTFS_DEFERRED.md`](RAM_ROOTFS_DEFERRED.md) | 未排期，不属于 v0.4 | 重新评审峰值内存、metadata 保真、内存压力和目标环境证据 |
| `V02-D07` Zig 显式 connect deadline | `UPSTREAM-BLOCKED` | [`V0_2_POST_RELEASE_BACKLOG.md`](../archive/design/V0_2_POST_RELEASE_BACKLOG.md) | Zig 0.16 runtime 路径会 panic，当前不能安全启用 | 上游行为修复后专项设计和故障注入 |
| `V02-D08` 声明式 CommandSpec 自动生成全部文档 | `UNSCHEDULED` | [`CURRENT_CLI_OPTIMIZATION_PLAN.md`](CURRENT_CLI_OPTIMIZATION_PLAN.md) | 维护性候选，无版本承诺 | 确认生成源、手写文档边界和迁移计划 |
| `V02-D09` operation progress event | `UNSCHEDULED` | [`CURRENT_CLI_OPTIMIZATION_PLAN.md`](CURRENT_CLI_OPTIMIZATION_PLAN.md) | 当前状态、日志和终态已满足发布 | 出现明确进度消费方后设计事件兼容契约 |
| `V02-D10` 全域统一 `checks[]` schema | `UNSCHEDULED` | [`V0_2_POST_RELEASE_BACKLOG.md`](../archive/design/V0_2_POST_RELEASE_BACKLOG.md) | 现有契约已冻结可用 | 后续 DTO 确需升级时统一评估 |
| `V02-D11` operation cancel | `UNSCHEDULED` | [`V0_2_POST_RELEASE_BACKLOG.md`](../archive/design/V0_2_POST_RELEASE_BACKLOG.md) | 当前无取消语义承诺 | 先设计状态机、部分产物清理和恢复契约 |
| `V02-D12` Profile history / `--from-revision` | `UNSCHEDULED` | [`V0_2_POST_RELEASE_BACKLOG.md`](../archive/design/V0_2_POST_RELEASE_BACKLOG.md) | 当前无产品需求 | 明确历史保留、GC、查询和 clone 语义 |
| rootfs cache GC | `UNSCHEDULED` | [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) | 当前只增不删并提供容量观测 | 获得真实容量数据后设计引用、并发删除与恢复规则 |
| identity revision GC | `UNSCHEDULED` | [`V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md`](V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md) | 当前保留历史无引用 revision，不进入既有版本完成闸 | 与 Profile history/retention 一起设计引用证明、并发删除和崩溃恢复 |

三项独立保留设计彼此不绑定：BIOS 不等于 static PXE，`ram_rootfs` 也不改变 firmware、bootloader 或 bootstrap 协议。

## 4. 可选证据、拒绝路径与永久非目标

| ID/主题 | 状态 | 裁决 |
|---|---|---|
| `V02-D02` 每个候选重复跑 QEMU | `OPTIONAL-EVIDENCE` | VMware 已证明同一产品链时不要求；仅用于诊断、故障注入或补充证据 |
| `V02-D03` Ubuntu rootfs 内 `mkinitramfs` 方案 B | `REJECTED-PATH` | 不是生产路径；历史实验仅供追溯 |
| `V02-D13` reconciliation、远程任务/通用命令、长期 enrollment | `PERMANENT-NONGOAL` | 违反一次性确定执行器和短期交付凭据边界 |
| `V02-D14` IPv6、NFS root、iPXE | `PERMANENT-NONGOAL` | 已由现行顶层设计冻结为永久非目标；旧 backlog 的 `UNSCHEDULED` 状态被本文取代 |
| 跨不可信网络的服务形态、持久化 overlay、by-id/serial/WWN 磁盘 selector | `PERMANENT-NONGOAL` | 不进入保留队列，也不预留 schema |

`V02-D05` 多 NIC/topology/容量已进入 v0.4，不再属于延期项；其未完成实现和合成验证由 [`V0_4_DESIGN.md`](V0_4_DESIGN.md) 与发布 runbook 管理，只有真实生产规模证据仍按 `ENV-V04-PRODUCTION-SCALE` 延期。

## 5. 引用与状态变更规则

1. README、路线图和版本设计只链接本文中的 ID/主题，不复制另一份状态表。
2. 专项设计只保存设计细节，并在页首链接本文；不得自行宣布排期、完成或解除延期。
3. 历史 backlog、审计和验证记录保留当时快照，但当前状态由本文覆盖。
4. `ENV-DEFERRED` 只有在独立验证记录包含候选版本、环境、步骤、结果和证据路径后才能解除。
5. `UNSCHEDULED`、`INDEPENDENT-DESIGN`、`UPSTREAM-BLOCKED` 进入版本前必须先更新本文，再更新目标版本设计和完成闸。
6. 预留 enum、空 handler、注释、CLI help、测试夹具或未被 consumer 使用的字段都不构成实现或验证完成。
