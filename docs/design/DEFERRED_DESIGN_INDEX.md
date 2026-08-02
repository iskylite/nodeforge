# NodeForge 独立保留设计索引

状态：当前权威索引。这里登记已经形成设计考量、但未进入任何已排期产品版本的能力。

版本设计只描述该版本确定实施和验收的内容。保留设计不占产品版本号，不预占 AppConfig、catalog、state、
BootConfig、AgentPlan 或其他 DTO/schema 编号，也不构成实现计划、兼容承诺或完成闸。重新立项时必须以当时已经落地的
产品基线重新评审 owner、schema、协议、安全、迁移策略和目标环境验证；若与后来的已实现版本冲突，以已实现版本为准。

## 1. 已登记的独立保留设计

| 主题 | 文档 | 当前状态 | 重新立项的必要条件 |
|---|---|---|---|
| DHCP-less static PXE bootstrap | [`STATIC_PXE_BOOTSTRAP_DEFERRED.md`](STATIC_PXE_BOOTSTRAP_DEFERRED.md) | 未排期；不属于 v0.4 | 固定可信网络边界、会话首次创建与防冒认协议，并取得可重复的目标环境 E2E |
| BIOS PXELINUX install | [`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md) | 未排期；不属于 v0.4 | 获得可重复使用的 x86_64 BIOS 验证环境，重新分配 schema/CLI |
| `ram_rootfs` materialization | [`RAM_ROOTFS_DEFERRED.md`](RAM_ROOTFS_DEFERRED.md) | 未排期；不属于 v0.4 | 峰值内存、metadata 保真、内存压力和长稳 E2E 条件成熟 |

三项彼此独立。实现其中一项不自动带入另外两项；例如 BIOS 不等于 static PXE，`ram_rootfs` 也不改变 firmware、
bootloader 或 PXE bootstrap 协议。

## 2. 永久非目标不是“保留设计”

以下边界已经由已落地设计冻结，不进入保留队列：IPv6、iPXE、NFS root、reconciliation、远程控制、可续期长期
enrollment credential、跨不可信网络的服务形态、持久化 overlay，以及 by-id/serial/WWN 稳定磁盘 selector。
后续文档不得把它们写成“下一版”“候选”或预留 schema；若产品方向确需改变，必须先建立显式架构决策并说明对冻结契约的
影响，不能借某个版本实现顺带开放。

## 3. 版本文档引用规则

- 版本设计可以用一行非目标声明和链接阻止 scope creep，但不得复制保留方案的字段、CLI、协议或未来编号。
- 保留设计可以引用当前版本的已实现/已冻结基线，但不得反向修改该版本完成标准。
- 历史审计中出现的旧版本号只代表当时快照；当前导航和实现计划只使用主题化保留设计名称。
- 预留 enum、空 handler、注释、CLI help 或未被 consumer 使用的字段都不算实现。
