# NodeForge 文档导航

本文是 `docs/` 的统一入口。先用“当前实现审计”判断代码已经做到哪里，再用版本设计
判断目标行为；`archive/` 只用于追溯历史决策，不能作为当前事实源。

## 现行设计总纲

v0.3 及以前的版本设计均已随实现和验证结果冻结：这些文件只作为已落地契约与历史证据读取，不再回写；
新增或修正设计从 v0.4 文档及独立保留设计承接，不能借更新导航或后续方案反向改变冻结基线。

- [CLI HTTP 诊断与响应缓冲设计](design/CLI_HTTP_DIAGNOSTICS_AND_BUFFERING.md)：定义 management 响应容量、`--debug` 诊断、安全预览和后续开发约束。
- [当前 CLI 全面优化与收敛方案](design/CURRENT_CLI_OPTIMIZATION_PLAN.md)：以当前代码和运行时事实为基线，统一正常工作流、同步/后台任务、CAS/force、clone、boot preview、retry、命令分层以及代码/注释/文档迁移。
- [v0.2.2 CLI Reference](cli/REFERENCE.md)：当前正式公开命令树与工作流边界。
- [日志与安装计划摘要约定](design/LOGGING_AND_INSTALL_PLAN_DIGEST.md)：定义 HTTP 错误日志、request_id、setup 日志等级覆盖，以及 install plan digest 不一致的诊断和安全边界。
- [v0.1 冻结设计与修复计划](design/V0_1_DESIGN.md)：M0-M4 及进入 v0.2 前完成的修复，已落地冻结。
- [v0.2 总纲](design/V0_2_DESIGN.md)：diskless 版本边界、跨域不变式、分册导航、实现切片与完成标准。所有 v0.2 工作先从这里进入。
- [v0.2.1 Ubuntu diskless](design/V0_2_1_UBUNTU_DISKLESS.md)：casper layer
  productization 与正式 rootfs builder 已完成，设计和验证结果冻结。
- [v0.2.2 可运营性与矩阵](design/V0_2_2_OPERABILITY.md)：持久化升级、
  durable rootfs build operation、CLI 收敛、readiness 和固定发布矩阵。
- [v0.2.3 Profile identity 与恢复收口](design/V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md)：
  catalog v5、稳定 SSH identity/provenance、完整 clone、recovery 与 ISO operation。
- [v0.3 设计：install-post canonical 扩展](design/V0_3_DESIGN.md)：install-post 四类 canonical action、callback generation 绑定与 journal/finalizer；保持 catalog schema v5。
- [v0.3 验证记录](validation/V0_3_VALIDATION.md)：fresh 双机部署、Compute Use VMware 五项矩阵、generation 3 install-post、重启恢复与负路径证据，最终结论 PASS。
- [v0.4 统一设计](design/V0_4_DESIGN.md)：UEFI DHCP PXE 与 target topology 分层、install/diskless 多 NIC/VLAN/bonding 渲染、256/512/1024 逻辑节点容量档位、nodeforged 服务端 rootfs 生成、install first-boot、SN+IP draft Node 自动 discovery，以及无迁移的 fresh replacement 边界。
- [v0.4 全量 fresh 验证运行手册](validation/V0_4_FULL_VALIDATION_RUNBOOK.md)：在 `r97n0/r97n1` 从空环境执行单节点真实功能发布闸，并用 workload harness 覆盖 256 实现容量基线、512 标准合成扩展、1024 合成压力、恢复和重复波次资源边界；真实生产规模验证按延期清单管理。
- [统一延期、保留与非目标清单](design/DEFERRED_DESIGN_INDEX.md)：唯一登记环境/生产规模验证延期、未排期或独立设计、上游阻塞、可选证据、拒绝路径和永久非目标；其他文档只保存细节或历史快照。

当前版本为 v0.4；所有延期和非目标的当前状态以统一清单为准。专项保留设计只从该清单进入，不在主导航重复列出。实现状态以代码和
[`V0_4_FULL_VALIDATION_RUNBOOK.md`](validation/V0_4_FULL_VALIDATION_RUNBOOK.md) 的证据为准。

## v0.2 分册

按问题进入对应分册，不需要顺序通读全部文件：

| 要回答的问题 | 分册 |
|---|---|
| 系统采用什么 diskless 架构，启动与恢复如何工作？ | [架构：无盘最终方案](design/DISKLESS_FINAL.md) |
| 三个程序分别负责什么，凭据归谁？ | [程序边界](design/V0_2_PROGRAM_DESIGN.md) |
| 状态机、协议栈、readiness、rootfs 构建和迁移如何实现？ | [实现细节](design/V0_2_IMPL_DETAILS.md) |
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
- [`archive/design/`](archive/design/README.md)：已完成的跨版本 roadmap 与 v0.2 发布后范围裁决。
- [`archive/audits/`](archive/audits/README.md)：旧实现基线、v0.2-v0.5 草案和 M5-M7 历史审计。
- [`archive/milestone-specs/`](archive/milestone-specs/)：M4.x 阶段专项设计记录。

## 其他资料

- [`assets/`](assets/)：文档使用的图片等静态资源。

文档发生冲突时，先按版本总纲的职责矩阵定位领域分册；设计定义目标行为，
当前代码与最新基线审计定义“已经实现到哪里”，validation 只证明其记录的候选和环境。
历史审计/归档不作为当前实现清单。
