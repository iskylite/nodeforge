# NodeForge 文档导航

本文是 `docs/` 的统一入口。日常只读本节列出的现行文档；`archive/` 仅供追溯，
**不是**当前行为事实源。

冲突优先级：**现行版本设计 > 当前代码 > 现行验证 runbook > 统一延期清单 > 冻结分册 > 历史归档**。

---

## 1. 现行入口（先读这些）

| 要做什么 | 文档 |
|---|---|
| 安装、编译、操作示例 | 仓库根 [README.md](../README.md) |
| 公开命令树与 exit code | [cli/REFERENCE.md](cli/REFERENCE.md)（参数以 `--help-full` 为准） |
| 当前版本设计（v0.4） | [design/V0_4_DESIGN.md](design/V0_4_DESIGN.md) |
| 下一增量设计（v0.4.1，设计中） | [design/V0_4_1_DESIGN.md](design/V0_4_1_DESIGN.md) — `profile rootfs staging` enter/exec、cgroup 挂载与限额、树内核导入（无 pivot_root / 无顶层 rootfs） |
| 延期 / 非目标唯一状态表 | [design/DEFERRED_DESIGN_INDEX.md](design/DEFERRED_DESIGN_INDEX.md) |
| 大更新公共发布闸 | [validation/PLATFORM_VALIDATION_RUNBOOK.md](validation/PLATFORM_VALIDATION_RUNBOOK.md) |
| v0.4 增量发布闸 | [validation/V0_4_FULL_VALIDATION_RUNBOOK.md](validation/V0_4_FULL_VALIDATION_RUNBOOK.md) |

当前产品版本为 **v0.4**。实现是否完成以代码与上述 runbook 的证据为准，不以历史验证记录为准。

### 运维与诊断（仍有效）

- [日志与安装计划摘要](design/LOGGING_AND_INSTALL_PLAN_DIGEST.md)
- [CLI HTTP 诊断与响应缓冲](design/CLI_HTTP_DIAGNOSTICS_AND_BUFFERING.md)

### 独立保留设计（未排期；状态以延期清单为准）

- [BIOS PXELINUX](design/BIOS_PXELINUX_DEFERRED.md)
- [DHCP-less static PXE](design/STATIC_PXE_BOOTSTRAP_DEFERRED.md)
- [`ram_rootfs`](design/RAM_ROOTFS_DEFERRED.md)

---

## 2. 冻结设计契约（只读，不回写）

v0.3 及更早设计已随实现冻结，仍描述**已落地行为**，但不再作为修改入口。
需要查 diskless / install-post 细节时从这里进入：

| 版本 | 入口 |
|---|---|
| v0.3 install-post | [V0_3_DESIGN.md](design/V0_3_DESIGN.md) |
| v0.2 diskless 总纲 | [V0_2_DESIGN.md](design/V0_2_DESIGN.md) |
| v0.2.1 Ubuntu diskless | [V0_2_1_UBUNTU_DISKLESS.md](design/V0_2_1_UBUNTU_DISKLESS.md) |
| v0.2.2 可运营性 | [V0_2_2_OPERABILITY.md](design/V0_2_2_OPERABILITY.md) |
| v0.2.3 identity / recovery | [V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md](design/V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md) |
| v0.1 所有权基线 | [V0_1_DESIGN.md](design/V0_1_DESIGN.md) |

### v0.2 分册（按问题查阅）

| 问题 | 分册 |
|---|---|
| diskless 架构与启动时序 | [DISKLESS_FINAL.md](design/DISKLESS_FINAL.md) |
| 四程序职责与凭据 | [V0_2_PROGRAM_DESIGN.md](design/V0_2_PROGRAM_DESIGN.md) |
| 状态机 / 协议 / readiness | [V0_2_IMPL_DETAILS.md](design/V0_2_IMPL_DETAILS.md) |
| 历史 CLI 契约全文 | [V0_2_CLI.md](design/V0_2_CLI.md)（现行命令树以 [cli/REFERENCE.md](cli/REFERENCE.md) 为准） |
| 从零操作闭环 | [V0_2_DISKLESS_WORKFLOW.md](design/V0_2_DISKLESS_WORKFLOW.md) |

---

## 3. 现行验证目录

`validation/` **只保留可执行的发布闸任务书**：

- [PLATFORM_VALIDATION_RUNBOOK.md](validation/PLATFORM_VALIDATION_RUNBOOK.md) — 跨版本公共底座
- [V0_4_FULL_VALIDATION_RUNBOOK.md](validation/V0_4_FULL_VALIDATION_RUNBOOK.md) — v0.4 增量

历次实跑记录、分阶段证据、单发行版流水已迁至
[`archive/validation/`](archive/validation/README.md)。新跑结果请新建带日期文件
（例如 `archive/validation/2026-08-05_PLATFORM.md`），不要改写 runbook。

---

## 4. 历史归档

[`archive/`](archive/) 下内容**不定义当前产品行为**。需要考古时再打开：

| 路径 | 内容 |
|---|---|
| [archive/validation/](archive/validation/README.md) | 历史验证记录（含 v0.3 PASS 证据、Phase、M4.x 实跑） |
| [archive/audits/](archive/audits/README.md) | 历史实现/安全/对齐审计 |
| [archive/design/](archive/design/README.md) | 过期路线图、CLI 优化草案、OSS 对比等 |
| [archive/milestone-specs/](archive/milestone-specs/) | M4.x 阶段专项设计 |
| [M0–M7 概要](archive/M0_M7_LEGACY_OVERVIEW_DESIGN.md) / [详细](archive/M0_M7_LEGACY_DETAILED_DESIGN.md) | 超长早期设计（勿作现行事实源） |
| [archive/validation-fixtures/](archive/validation-fixtures/) | 旧 QEMU 夹具（不适用于 v0.4 二进制） |

---

## 5. 其他

- [`assets/`](assets/)：文档配图等静态资源。
