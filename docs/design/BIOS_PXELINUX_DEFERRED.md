# NodeForge BIOS PXELINUX 保留设计

状态：独立保留设计，实现未排期。不绑定产品版本号或既定 schema 号。
前置条件：获得可重复使用的 x86_64 BIOS 物理机或 VMware x86_64 guest 验证环境。
关联文档：[`LOCAL_VALIDATION_DEFERRED.md`](LOCAL_VALIDATION_DEFERRED.md) `ENV-X86-VMWARE`。
统一索引：[`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md)。

本文从 v0.3 设计中剥离，收录所有 BIOS x86 PXELINUX install 相关的设计决策。
BIOS 不再绑定 v0.3 或任何产品版本号；只有在其验证环境约束（`ENV-X86-VMWARE`）
解除并重新完成 schema/CLI/验收评审后，才作为独立工作项进入实施计划。在此之前，当前产品版本设计、完成闸和
实施顺序均不包含 BIOS。

## 1. 为什么独立

BIOS PXELINUX 是 x86_64 专属功能，当前实验室环境为 Apple Silicon + VMware Fusion，
无法创建或运行 x86_64 guest（`ENV-X86-VMWARE`）。将其绑定到某个版本会制造
"版本已完成代码但无法完成验证"的矛盾状态。因此：

- BIOS 从版本路线图中剥离，不再阻塞任何版本的完成；
- BIOS 相关的 schema 变更（`firmware.mode`）一并延后，具体 catalog 版本在未来实施时分配；
- 不插入 v0.4 schema 演进，不复用 catalog v6；未来以当时产品基线直接替换到新的唯一 schema；
- BIOS 的设计决策保留在此文档中，供环境就绪后直接参考。

## 2. 范围

| 项 | 说明 |
|---|---|
| BIOS x86 PXELINUX install | `firmware.mode=bios` Node direct 属性，schema 直接替换 |
| BIOS bootloader | `pxelinux.0` + PXELINUX config，与 UEFI GRUB 并列 |
| BIOS partition | effective compiler 结合 firmware 生成 ESP/biosboot 要求 |
| diskless BIOS | 明确拒绝（readiness 返回 `property.not_applicable`） |
| `http_accel` 对 BIOS | fail-closed（PXELINUX 只支持 TFTP） |

BIOS **不**包含：多 NIC/VLAN/bonding（v0.4 范围）、reconciliation/远程控制
（永久非目标）。

## 3. firmware.mode

- 新增 Node direct `firmware.mode=uefi|bios`；**不**放入 Profile 或 `overrides`。
- catalog schema 从未来实施时的产品基线直接替换到新分配版本（不迁移，见 v0.2.3 设计 §0）；旧 catalog 不被加载，
  操作员需重新 `setup`，新认领 Node 必须由管理员确认 desired `firmware.mode`。
- DHCP observed firmware 只用于 mismatch/readiness 检查，不自动改写 desired property。
- partition policy 仍用 v0.1 逻辑磁盘角色，由 effective compiler 结合 firmware 生成
  ESP/biosboot 要求。
- `node.http_accel` 继续只适用于 UEFI GRUB；BIOS PXELINUX capability 必须报告
  `property.not_applicable`，不能接受后静默忽略，也不能为 BIOS 新增另一个同义传输开关。
- `http_accel` 治理 GRUB 在 PXE 阶段用 HTTP 取 kernel/initrd 的传输路径（install 与
  diskless 共用，仅 UEFI）；它不治理 initrd 自身用 node-bound capability route 发起的
  rootfs GET/HEAD/Range 下载（始终走受认证 HTTP 路由）。

## 4. BIOS PXELINUX boot target

- BIOS x86 经 PXELINUX 引导；UEFI 继续用 GRUB。
- `boot/target.zig` 新增 BIOS 分支消费 pinned install effective plan；与 v0.2 diskless
  分支并列，不互相 fallback。
- BIOS 范围只覆盖 `kind=install`。`kind=diskless + firmware.mode=bios` 在 readiness
  返回 `property.not_applicable`；diskless BIOS 未经独立版本设计与验收不得借
  PXELINUX 分支顺带开放。
- BIOS 与更多发行版版本彼此独立，不能捆绑实现。

当前代码状态（`src/boot/resolver.zig` `bootfile()`、`src/boot/grub.zig`、
`src/boot/target.zig`）：只有 UEFI GRUB 路径，无 BIOS 分支。注释中的
"BIOS PXELINUX 支持在 M6 补齐"为历史占位，不构成实现证据。

## 5. CLI

```text
nodeforge node set <node> firmware.mode=bios
nodeforge node list          # 增加 FIRMWARE 列（uefi/bios）
nodeforge node show <node>   # 输出 firmware.mode direct 字段
```

- `firmware.mode` 是 Node direct 字段，不经 `overrides`；不适用 BIOS 的属性返回
  `property.not_applicable`。
- BIOS readiness 在 `node readiness --stage boot` 中增加 PXELINUX capability 检查、
  BIOS bootloader 资产存在性、`http_accel` 对 BIOS fail-closed 校验；diskless BIOS
  直接 not-applicable。

## 6. 完成标准

- schema 直接替换（不迁移），旧 catalog 不被加载；活动 snapshot 保护和 digest 预览通过。
- `firmware.mode` claim/config、DHCP observed mismatch、readiness 和 digest 覆盖完整。
- BIOS x86 PXELINUX 引导、安装、登录、事件、install generation 重试/drift 与 daemon
  restart-resume 回归通过；diskless BIOS readiness 负向测试稳定拒绝。
- UEFI install/diskless 与既有矩阵回归不退化。
- 预留 enum/空 handler 不算实现证据。

## 7. 环境前置

BIOS PXELINUX 的 E2E 验证需要 x86_64 BIOS 环境。当前 `ENV-X86-VMWARE` 约束未解除。
在获得合适环境前，只能做隔离 spike（交叉编译、协议 fixture、静态审计），不能合入
主产品路径，也不能宣称已完成目标环境验证。
