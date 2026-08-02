# NodeForge 文档导航

本文是 `docs/` 的统一入口。先用“当前实现审计”判断代码已经做到哪里，再用版本设计
判断目标行为；`archive/` 只用于追溯历史决策，不能作为当前事实源。

## 现行设计总纲

v0.3 及以前的版本设计均已随实现和验证结果冻结：这些文件只作为已落地契约与历史证据读取，不再回写；
新增或修正设计从 v0.4 文档及独立保留设计承接，不能借更新导航或后续方案反向改变冻结基线。

- [当前实现与设计对齐审查](audits/CURRENT_IMPLEMENTATION_ALIGNMENT_REVIEW.md)：基于
  `a29ca69` / v0.3.1 的实现状态、P0/P1 发现、文档漂移和发布顺序。
- [v0.2.1+ 实施路线图](design/V0_2_1_PLUS_ROADMAP.md)：v0.2.1-v0.4 的依赖、
  schema/DTO 演进、跨版本不变式和完成闸。
- [CLI HTTP 诊断与响应缓冲设计](design/CLI_HTTP_DIAGNOSTICS_AND_BUFFERING.md)：定义 management 响应容量、`--debug` 诊断、安全预览和后续开发约束。
- [当前 CLI 全面优化与收敛方案](design/CURRENT_CLI_OPTIMIZATION_PLAN.md)：以当前代码和运行时事实为基线，统一正常工作流、同步/后台任务、CAS/force、clone、boot preview、retry、命令分层以及代码/注释/文档迁移。
- [v0.2.2 CLI Reference](cli/REFERENCE.md)：当前正式公开命令树与工作流边界。
- [日志与安装计划摘要约定](design/LOGGING_AND_INSTALL_PLAN_DIGEST.md)：定义 HTTP 错误日志、request_id、setup 日志等级覆盖，以及 install plan digest 不一致的诊断和安全边界。
- [v0.1 冻结设计与修复计划](design/V0_1_DESIGN.md)：M0-M4 及进入 v0.2 前完成的修复，已落地冻结。
- [v0.2 总纲](design/V0_2_DESIGN.md)：diskless 版本边界、跨域不变式、分册导航、实现切片与完成标准。所有 v0.2 工作先从这里进入。
- [v0.2.1 Ubuntu diskless](design/V0_2_1_UBUNTU_DISKLESS.md)：casper layer
  productization 与正式 rootfs builder 已完成，设计和验证结果冻结。
- [v0.2.2 可运营性与矩阵](design/V0_2_2_OPERABILITY.md)：持久化升级、
  durable builder operation、CLI 收敛、readiness 和固定发布矩阵。
- [v0.2.3 Profile identity 与恢复收口](design/V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md)：
  catalog v5、稳定 SSH identity/provenance、完整 clone、recovery 与 ISO operation。
- [当前环境不可验证项](design/LOCAL_VALIDATION_DEFERRED.md)：集中记录不进入当前
  版本完成闸的目标环境验证，包含 x86_64 VMware；QEMU 只作可选补充证据。
- [v0.2 发布后收口清单](design/V0_2_POST_RELEASE_BACKLOG.md)：区分真实实现差异、
  已完成项和明确暂不做项；第 2 节稳定 ID 是非阻断范围的唯一权威索引。
- [v0.3 设计：install-post canonical 扩展](design/V0_3_DESIGN.md)：install-post 四类 canonical action、callback generation 绑定与 journal/finalizer；保持 catalog schema v5。
- [v0.3 验证记录](validation/V0_3_VALIDATION.md)：fresh 双机部署、Compute Use VMware 五项矩阵、generation 3 install-post、重启恢复与负路径证据，最终结论 PASS。
- [v0.4 统一设计](design/V0_4_DESIGN.md)：UEFI DHCP PXE 与 target topology 分层、多 NIC/VLAN/bonding、容量闸、PXE rootfs builder、install first-boot、SN+IP draft Node 自动 discovery，以及无迁移的 fresh replacement 边界。
- [v0.4 全量 fresh 验证运行手册](validation/V0_4_FULL_VALIDATION_RUNBOOK.md)：v0.4 完成后在 `r97n0/r97n1` 从空环境执行的发布闸，覆盖 v0.3 回归、topology、builder、first-boot、discovery、容量和 24 小时 soak。
- [独立保留设计索引](design/DEFERRED_DESIGN_INDEX.md)：集中登记所有不属于 v0.4 的保留设计及永久非目标，禁止在版本文档内预占未来字段或编号。
- [DHCP-less static PXE bootstrap 保留设计](design/STATIC_PXE_BOOTSTRAP_DEFERRED.md)：保存 source/L2 binding、首次会话创建和防冒认考量；不进入 v0.4。
- [BIOS PXELINUX 保留设计](design/BIOS_PXELINUX_DEFERRED.md)：独立、未排期且不绑定产品/schema 版本；不进入 v0.4。
- [`ram_rootfs` 保留设计](design/RAM_ROOTFS_DEFERRED.md)：独立保存内存展开方案，不绑定产品版本；未来从当时基线重新分配 schema/DTO，不反向改变 v0.4。

当前版本实施顺序固定到 v0.4；三份主题化保留设计均未排期，reconciliation/远程控制为永久非目标。

## v0.2 分册

按问题进入对应分册，不需要顺序通读全部文件：

| 要回答的问题 | 分册 |
|---|---|
| 系统采用什么 diskless 架构，启动与恢复如何工作？ | [架构：无盘最终方案](design/DISKLESS_FINAL.md) |
| 三个程序分别负责什么，凭据归谁？ | [程序边界](design/V0_2_PROGRAM_DESIGN.md) |
| 状态机、协议栈、readiness、builder 和迁移如何实现？ | [实现细节](design/V0_2_IMPL_DETAILS.md) |
| CLI 命令、flag、CAS、输出和 exit code 是什么？ | [CLI 接口](design/V0_2_CLI.md) |
| 操作员如何从空 catalog 走完构建、启用和恢复？ | [端到端流程](design/V0_2_DISKLESS_WORKFLOW.md) |
| 为什么选择 squashfs overlay 而不是 NFS/iSCSI/iPXE？ | [开源方案对比](design/DISKLESS_OSS_COMPARISON.md) |

总纲定义版本范围和完成标准；各分册只在自己的领域内具有细节权威。操作流程中的命令以 CLI 分册为准，
审计和开源对比均不定义产品行为。具体冲突裁决规则见 [v0.2 总纲 §0](design/V0_2_DESIGN.md#0-文档结构与阅读路径)。

## 审计与验证

- [`audits/`](audits/)：代码事实、设计对齐和缺口审计。
- [`validation/`](validation/)：自动化、虚拟机、实机验证记录和待执行发布运行手册。主要入口：
  - [v0.4 全量 fresh 验证运行手册](validation/V0_4_FULL_VALIDATION_RUNBOOK.md)：待实现完成后执行的双机发布验证任务书；任一必要项未验证即 FAIL。
  - [Phase 8 r97n0 QEMU 全量验证](validation/V0_2_PHASE8_VALIDATION.md)：aarch64 完整闭环（switch_root/running/retry/内存闸）、rootfs-build `--installroot`、传输故障负测。
  - [v0.2.1 Ubuntu diskless 设计](design/V0_2_1_UBUNTU_DISKLESS.md)：Ubuntu casper squashfs 叠加方案，支持 Rocky/RHEL 宿主构建 Ubuntu 无盘系统。
  - [v0.2/v0.2.1/v0.2.2 审计与实测](validation/V0_2_0_2_2_AUDIT_AND_VALIDATION.md)：CLI、r97n0 QEMU 与 Computer Use/VMware 实机闭环。
  - [Phase 1](validation/V0_2_PHASE1_VALIDATION.md)/[Phase 6](validation/V0_2_PHASE6_VALIDATION.md)：diskless 早期与 initramfs 构建验证。

## 历史归档

- [M0-M7 历史合并概要设计](archive/M0_M7_LEGACY_OVERVIEW_DESIGN.md)：早期全景和决策记录。
- [M0-M7 历史分阶段详细设计](archive/M0_M7_LEGACY_DETAILED_DESIGN.md)：旧里程碑任务、接口、验收记录以及已被 v0.2 取代的 M5-M7 草案。
- [`archive/milestone-specs/`](archive/milestone-specs/)：M4.x 阶段专项设计记录。

## 其他资料

- [`assets/`](assets/)：文档使用的图片等静态资源。

文档发生冲突时，先按版本总纲的职责矩阵定位领域分册；设计定义目标行为，
当前代码与最新基线审计定义“已经实现到哪里”，validation 只证明其记录的候选和环境。
历史审计/归档不作为当前实现清单。
