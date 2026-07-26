# NodeForge 文档导航

本文是 `docs/` 的统一入口。判断当前范围、接口和完成状态时，先看版本设计；`archive/` 只用于追溯历史决策，不能作为当前实现或版本边界的事实源。

## 现行设计总纲

- [v0.1 设计与修复计划](design/V0_1_DESIGN.md)：M0-M4 及进入 v0.2 前必须完成的修复，当前权威设计。
- [v0.2 总纲](design/V0_2_DESIGN.md)：diskless 版本边界、跨域不变式、分册导航、实现切片与完成标准。所有 v0.2 工作先从这里进入。
- [v0.3 设计：PXELINUX/BIOS install](design/V0_3_DESIGN.md)：`firmware.mode` schema v5、BIOS PXELINUX、发行版版本矩阵与 `install-post` phase。
- [v0.4 设计：延后增强项](design/V0_4_DESIGN.md)：多 NIC/VLAN/bonding、容量压测、临时 PXE rootfs 构建节点与 install 侧 first-boot agent（无 reconciliation）。
- [v0.5 设计：可切换 rootfs 形态](design/V0_5_DESIGN.md)：`ram_rootfs` 全内存模式与 `diskless.overlay.mode` 字段。

v0.3（PXELINUX/BIOS install）与 v0.4（延后增强项）的设计在 v0.2 启动后展开；reconciliation/远程控制为永久非目标。

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

- [`audits/V0_2_V0_5_DESIGN_REVIEW.md`](audits/V0_2_V0_5_DESIGN_REVIEW.md)：基于 v0.1 M0-M4.13
  代码事实的 v0.2-v0.5 差距、版本依赖与推荐实施顺序。
- [`audits/V0_2_V0_5_CLI_GAP_AUDIT.md`](audits/V0_2_V0_5_CLI_GAP_AUDIT.md)：v0.2-v0.5 CLI、认证、恢复和迁移契约的查漏补缺记录。

- [`audits/`](audits/)：代码事实、设计对齐和缺口审计。
- [`validation/`](validation/)：自动化、虚拟机和实机验证记录。v0.2 关键记录：
  - [Phase 8 r97n0 QEMU 全量验证](validation/V0_2_PHASE8_VALIDATION.md)：aarch64 完整闭环（switch_root/running/retry/内存闸）、rootfs-build `--installroot`、传输故障负测。
  - [v0.2.1 Ubuntu diskless 设计](design/V0_2_1_UBUNTU_DISKLESS.md)：Ubuntu casper squashfs 叠加方案，支持 Rocky/RHEL 宿主构建 Ubuntu 无盘系统。
- [v0.2.2 保留项](validation/V0_2_2_RESERVED.md)：x86_64 UEFI smoke 与 VMware（compute_use）实机矩阵，当前环境暂不验证。
  - [Phase 1](validation/V0_2_PHASE1_VALIDATION.md)/[Phase 6](validation/V0_2_PHASE6_VALIDATION.md)：diskless 早期与 initramfs 构建验证。

## 历史归档

- [M0-M7 历史合并概要设计](archive/M0_M7_LEGACY_OVERVIEW_DESIGN.md)：早期全景和决策记录。
- [M0-M7 历史分阶段详细设计](archive/M0_M7_LEGACY_DETAILED_DESIGN.md)：旧里程碑任务、接口、验收记录以及已被 v0.2 取代的 M5-M7 草案。
- [`archive/milestone-specs/`](archive/milestone-specs/)：M4.x 阶段专项设计记录。

## 其他资料

- [`assets/`](assets/)：文档使用的图片等静态资源。

文档发生冲突时，先按版本总纲的职责矩阵定位领域分册；设计与实现状态不一致时，设计定义目标行为，当前代码、
审计和验证记录定义“已经实现到哪里”。历史归档不作为当前事实源。
