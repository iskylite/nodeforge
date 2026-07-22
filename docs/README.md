# NodeForge 文档导航

本文是 `docs/` 的统一入口。判断当前范围、接口和完成状态时，先看版本设计；`archive/` 只用于追溯历史决策，不能作为当前实现或版本边界的事实源。

## 现行设计

- [v0.1 设计与修复计划](design/V0_1_DESIGN.md)：M0-M4 及进入 v0.2 前必须完成的修复，当前权威设计。
- [v0.2 设计范围](design/V0_2_DESIGN.md)：diskless 主流程版本边界与进入条件，v0.2 权威设计入口。
- [v0.2 无盘最终方案](design/DISKLESS_FINAL.md)：squashfs_overlay 收敛选型、共享 rootfs、BootConfig 与启动时序。
- [v0.2 无盘方案开源情报对比](design/DISKLESS_OSS_COMPARISON.md)：NFS/iSCSI/iPXE/squashfs/ram 对比与 local-only 选型依据。
- [v0.2 程序边界](design/V0_2_PROGRAM_DESIGN.md)：`nodeforged` / `nodeforge-initrd` / `nodeforge-agent` 三程序职责与凭据边界。
- [v0.2 实现细节](design/V0_2_IMPL_DETAILS.md)：BootSession 状态机、DHCP/TFTP/HTTP 协议栈、effective compiler/readiness/validator 三项核心闭环。
- [v0.2 CLI 接口](design/V0_2_CLI.md)：diskless 八阶段完整命令树与 flag。
- [v0.3 设计：PXELINUX/BIOS install](design/V0_3_DESIGN.md)：`firmware.mode` schema v5、BIOS PXELINUX、发行版版本矩阵与 `install-post` phase。
- [v0.4 设计：延后增强项](design/V0_4_DESIGN.md)：多 NIC/VLAN/bonding、容量压测、节点上 rootfs 构建与 install 侧 first-boot agent（无 reconciliation）。
- [v0.5 设计：可切换 rootfs 形态](design/V0_5_DESIGN.md)：`ram_rootfs` 全内存模式与 `diskless.overlay.mode` 字段。

v0.3（PXELINUX/BIOS install）与 v0.4（延后增强项）的设计在 v0.2 启动后展开；reconciliation/远程控制为永久非目标。

## 审计与验证

- [`audits/`](audits/)：代码事实、设计对齐和缺口审计。
- [`validation/`](validation/)：自动化、虚拟机和实机验证记录。

## 历史归档

- [M0-M7 历史合并概要设计](archive/M0_M7_LEGACY_OVERVIEW_DESIGN.md)：早期全景和决策记录。
- [M0-M7 历史分阶段详细设计](archive/M0_M7_LEGACY_DETAILED_DESIGN.md)：旧里程碑任务、接口、验收记录以及已被 v0.2 取代的 M5-M7 草案。
- [`archive/milestone-specs/`](archive/milestone-specs/)：M4.x 阶段专项设计记录。

## 其他资料

- [`assets/`](assets/)：文档使用的图片等静态资源。

文档发生冲突时，优先级依次为：现行版本设计、当前代码与审计证据、验证记录、历史归档。
