# NodeForge v0.4 设计：延后增强项

状态：设计草案，实现未开始。本文定义 v0.4 范围，与 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §2 版本表一致。
v0.4 在 v0.3 完成后启动，收纳 VMware 难以验证或非主流程的增强项。**reconciliation/远程控制为永久非目标**
（全版本，见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §7），v0.4 不实现任何远程主动控制。

## 1. 进入条件

v0.4 必须基于 v0.3 完成：

- v0.3 schema v5（`firmware.mode`）、BIOS PXELINUX、发行版版本矩阵与 `install-post` phase 已落地并通过验收。
- v0.2/v0.3 diskless 与 install 主流程在 UEFI/BIOS 双模式下回归通过。
- 三程序（`nodeforged`/`nodeforge-initrd`/`nodeforge-agent`）边界稳定。

## 2. 范围

| 项 | v0.4 范围 | 说明 |
|---|---|---|
| 多 NIC/VLAN/bonding | 是 | PXE 阶段纯静态、下载后切换地址/子网；需显式 initrd feature/schema/验收 |
| 大规模容量压测 | 是 | 高并发、失败恢复、长期运行 |
| 远程/节点上 rootfs 构建 | 是 | agent 驱动，更高保真（真机 /dev/proc/sys + 匹配内核） |
| install 侧 first-boot agent | 是 | 确定性 first-boot，与 diskless 同一执行模型（无 reconciliation） |
| reconciliation/远程控制 | **永久非目标** | 全版本不实现 |

v0.4 **不**包含：可切换 rootfs 形态（-> v0.5）；NFS root/iPXE/IPv6（永久非目标）；跨不可信网络 TLS/mTLS（永久非目标）。

## 3. 从前序版本继承的强制契约

- v0.1-v0.3 所有权、`/dev/...` 磁盘契约、`software.*`、`kernel_args`、明文 password 不变式。
- canonical phase 集合（`install-post|rootfs-build|first-boot`，无 `runtime`）、四类 action、八步执行契约、
  TargetSystem 保护域/finalizer、事件脱敏、幂等键不变。
- 统一 `node list`/`node status` kind 感知投影；BootSession 与 deployment 投影职责分离。
- agent 永远是开机确定性顺序执行器：不接受远程任务下发、不做 drift 重跑、不做通用远程命令
  （reconciliation/远程控制为永久非目标）。
- `show key == --help-full key == parser key == API operation path`；CLI 不得要求 Shell 内嵌 JSON。

## 4. 网络增强（多 NIC/VLAN/bonding）

- v0.2/v0.3 的 diskless/install 网络由 initrd 写 NM/Netplan 配置到 overlay upper，`switch_root` 后接管同一地址；
  v0.4 扩展为多 NIC、VLAN、bonding 与下载后切换地址/子网。
- 需显式 initrd feature（如 `multi-nic-v1`/`vlan-v1`/`bonding-v1`）与 schema 扩展；`required_features` 缺失或冲突
  在 `switch_root` 前以稳定 error code 拒绝，不静默降级（同 v0.2 feature 契约）。
- PXE 阶段纯静态、多 NIC、VLAN、bonding 不能由 initrd 猜测或静默接受；未声明 capability 时 readiness 失败。
- VMware 难以有效验证的部分须在真机或更接近实机的环境验收，不混入主流程完成标准。

## 5. 容量与压测

- 大规模并发 PXE 引导、rootfs 下载、失败恢复与长期运行回归。
- v0.2 已验证 diskless 最小功能并发；v0.4 扩展到生产级容量与恢复矩阵。
- 容量压测不改主流程协议栈/状态机语义，只验证边界与稳定性。

## 6. 远程/节点上 rootfs 构建（agent 驱动）

- v0.2 的 rootfs 由服务端 builder 本地构建（chroot/staging，按需 bind-mount `/dev`/`/proc`/`/sys` + 匹配内核）。
- v0.4 允许在节点上经 agent 驱动构建 rootfs，获得更高保真（真机硬件/内核态），满足驱动/dkms/initramfs 重生成等
  依赖真实环境的动作（[`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §4 构建保真）。
- 节点构建仍消费同一 pinned DisklessEffectivePlan 与 effective digest；构建产物回服务端缓存或就地使用，按
  effective digest 共享语义不变。
- 节点 agent 构建是**确定性**的（按 pinned bundle revision 执行），不是远程任务下发平台；构建触发由
  session/readiness 驱动，不引入 reconciliation。
- 远程/节点构建的 capability、feature 与 schema 需显式声明并验收。

## 7. install 侧 first-boot agent

- v0.3 的 `install-post` 由安装器执行（无 agent）；v0.4 增加 install 侧 `first-boot` agent，与 diskless 同一确定性
  执行模型：开机顺序执行、固定顺序（文件更新 -> package -> archive -> script）、一次性、确定性 + 幂等。
- **无 reconciliation**：agent 不检测 drift 后远程重跑收敛；drift 仅报告（v0.1 既有）不自动修复。
- **无 enrollment/credential**：身份由 `nodeforge.node_id` cmdline 携带（同 diskless），initrd 写
  `/run/nodeforge/boot.json`，agent 读取；状态/异常经 `event_url` best-effort 回传，失败本地兜底。
- install 侧 agent 与 diskless agent 共用同一程序（`nodeforge-agent`）与执行契约，差异只在目标上下文
  （install 写磁盘 vs diskless 写 overlay upper）。

## 8. CLI（v0.4）

> 完整 CLI 约定见 [`V0_2_CLI.md`](V0_2_CLI.md) §0；v0.4 命令随其设计落地。

```text
nodeforge node set <node> network.bond=<name> network.bond.members=eth0,eth1 network.bond.mode=802.3ad
nodeforge node set <node> network.vlan=<id> ...
nodeforge node rootfs build <node> --on-node            # 节点上 agent 驱动构建（v0.4）
nodeforge node postinstall show <node> --phase first-boot  # install 侧 first-boot 结果（v0.4）
```

- 多 NIC/VLAN/bonding、节点构建的 CLI 需配套显式 initrd feature 与 schema，未声明时 readiness 失败。
- reconciliation/远程控制无对应 CLI（永久非目标）；v0.2/v0.3 不提供这些命令的 help/handler。

## 9. 明确非目标（v0.4 增量）

- reconciliation/远程控制：服务端不检测已部署节点 drift 后远程主动触发 agent 重跑收敛，agent 永远是开机
  确定性顺序执行（diskless/install 通用）；drift 仅报告不自动修复。**永久非目标**（继承 v0.2 §7）。
- enrollment/credential 机制：agent 身份由 `nodeforge.node_id` cmdline 携带，全版本不引入。**永久非目标**。
- 跨不可信网络 TLS/mTLS、远程管理。**永久非目标**；v0.4 的 HTTP bearer 仍只在隔离 `local-only` 网络内提供认证。
- 可切换 rootfs 形态（`ram_rootfs`/`diskless.overlay.mode`）-> v0.5。
- NFS root/iPXE/IPv6/by-id/serial/WWN -> 永久非目标（继承）。

## 10. 完成标准

- 多 NIC/VLAN/bonding 经显式 initrd feature 与 schema 落地，`switch_root` 前校验，缺失/冲突 fail closed。
- 大规模容量压测覆盖高并发引导/rootfs 下载/失败恢复/长期运行，不改主流程语义。
- 节点上 rootfs 构建经 agent 驱动、消费同一 effective digest，构建保真满足驱动/dkms 类动作。
- install 侧 first-boot agent 与 diskless 同一确定性执行模型，无 reconciliation、无 enrollment。
- 传输 token 与 management credential 边界不变；reconciliation/远程控制/TLS 均不存在对应实现。
- 本审计与版本设计、配套文档同步更新；预留 enum/空 handler 不算实现证据。
