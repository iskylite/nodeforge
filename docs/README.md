# NodeForge 文档导航

本文是 `docs/` 的统一入口。判断当前范围、接口和完成状态时，先看版本设计；`archive/` 只用于追溯历史决策，不能作为当前实现或版本边界的事实源。

## 现行设计

- [v0.1 设计与修复计划](design/V0_1_DESIGN.md)：M0-M4 及进入 v0.2 前必须完成的修复，当前权威设计。
- [v0.2 设计范围](design/V0_2_DESIGN.md)：尚未实现的 M5-M7 及其进入条件。

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
