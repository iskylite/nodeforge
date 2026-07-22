# NodeForge v0.3 设计：PXELINUX/BIOS install

状态：设计冻结，实现未开始。本文定义 v0.3 范围，与 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §2 版本表一致。
v0.3 在 v0.2 diskless 主流程完成后启动。实现细节与状态机见
[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md)，CLI 见 [`V0_2_CLI.md`](V0_2_CLI.md) §9，
程序边界见 [`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md) §7。

## 1. 进入条件

v0.3 必须基于 v0.2 diskless 主流程完成：

- v0.2 schema v4（`ProfileKind = install|diskless`）冻结，canonical BootSession 状态机、
  DHCP/TFTP/HTTP 协议栈与 effective compiler/readiness/validator 三项核心闭环已落地并通过验收。
- `install-post|rootfs-build|first-boot` canonical phase、四类 action（managed-file/archive/script/package）
  与八步执行契约已统一（v0.2 实现 `rootfs-build`/`first-boot`）。
- v0.1 install 侧 PXE/adapter/effective 在 v0.2 期间保持回归通过。

任何一项未完成时，v0.3 只能做隔离 spike，不能合入主产品路径。

## 2. 范围

v0.3 聚焦 **BIOS PXELINUX install 与发行版版本矩阵**，对应 M6（BIOS/发行版）与 M7 `install-post`：

| 项 | v0.3 范围 | 说明 |
|---|---|---|
| BIOS x86 PXELINUX | 是 | `firmware.mode=bios` Node direct 属性，schema v5 |
| 发行版版本矩阵 | 是 | Rocky/RHEL 系与 Ubuntu 后续 LTS 的显式 adapter capability matrix |
| bootloader/版本差异/错误分类 | 是 | 长期运行回归 |
| 最小功能并发/失败恢复 | 是 | 大规模容量压测延后 v0.4 |
| `install-post` phase | 是 | 安装器（Kickstart `%post`/Autoinstall `late-commands`）执行，无 agent |

v0.3 **不**包含：多 NIC/VLAN/bonding、PXE 阶段纯静态、下载后切换地址/子网、大规模容量压测（-> v0.4）；
install 侧 first-boot agent（-> v0.4）；reconciliation/远程控制（永久非目标）。

## 3. 从 v0.1/v0.2 继承的强制契约

- v0.1 所有权模型、`/dev/...` 磁盘契约、`software.*` 双集合、`kernel_args.add/remove`、明文 password/默认用户不变式。
- v0.1 UEFI install 全部能力（单盘/LVM/RAID/RAID-LVM、repository/software capability、effective compiler）原样保留。
- v0.2 canonical phase 集合（`install-post|rootfs-build|first-boot`，无 `runtime`）、四类 action、八步执行契约、
  TargetSystem 保护域/finalizer、事件脱敏与幂等键不变。
- v0.2 统一 `node list`/`node status` kind 感知投影（`KIND` 列、canonical BootSession phase）；install 侧
  installer 进度移出 BootSession，仅在 `node_status` 部署投影保留。
- `show key == --help-full key == parser key == API operation path`；CLI 不得要求 Shell 内嵌 JSON。

## 4. firmware.mode 与 BIOS 引导

### 4.1 firmware.mode

- 新增 Node direct `firmware.mode=uefi|bios`（schema v5）；**不**放入 Profile 或 `overrides`。
- schema v4 到 v5 既有 Node migration 默认物化 `uefi`；新认领 Node 必须由管理员确认 desired `firmware.mode`。
- DHCP observed firmware 只用于 mismatch/readiness 检查，不自动改写 desired property。
- partition policy 仍用 v0.1 逻辑磁盘角色，由 effective compiler 结合 firmware 生成 ESP/biosboot 要求。
- `node.http_accel` 继续只适用于 UEFI GRUB；BIOS PXELINUX capability 必须报告 `property.not_applicable`，
  不能接受后静默忽略，也不能为 BIOS 新增另一个同义传输开关。
- `http_accel` 治理 GRUB 在 PXE 阶段用 HTTP 取 kernel/initrd 的传输路径（install 与 diskless 共用，仅 UEFI）；
  它不治理 initrd 自身用 node-bound capability route 发起的 rootfs GET/HEAD/Range 下载（始终走受认证 HTTP 路由）。

### 4.2 BIOS PXELINUX boot target

- BIOS x86 经 PXELINUX 引导；UEFI 继续用 GRUB。
- `boot/target.zig` 新增 BIOS 分支消费 pinned install effective plan；与 v0.2 diskless 分支并列，不互相 fallback。
- BIOS 与更多发行版版本彼此独立，不能捆绑实现。

## 5. install-post phase（安装器执行）

`install-post` 由安装器在安装期执行，**无 agent**，属 install：

| 维度 | install-post（v0.3） |
|---|---|
| 执行者 | 安装器（Kickstart `%post` / Autoinstall `late-commands`），无 nodeforge-agent |
| 目标上下文 | 安装中目标系统磁盘（已分区/格式化），`/` 为安装目标根 |
| 持久化 | 写磁盘（install 永久） |
| 触发 | 安装器渲染时嵌入 bundle 引用，安装期执行 |
| 失败语义 | step failed 可 retry；不回写或倒退已完成 BootSession/installer 进度 |

- 复用 v0.1 已有最小 install-post provision bundle（managed-file asset 驱动），**不改变其 Assets owner**。
- v0.3 扩展为完整四类 action（managed-file/archive/script/package）与 `install-post` phase；旧 `repository`/
  `standard_packages` 按 v0.2 §5.2 迁移表退出，不新增同义 action。
- package action 只引用 pinned effective software/capability，经本地 repository 解析校验、幂等。
- archive 规则与 v0.2 一致：顶层 `./install.sh` 则解压到临时目录执行；否则解压到 `/`。
- 八步执行契约固定顺序：文件更新 -> package -> archive -> script；TargetSystem 保护域 action 在 plan/validate
  阶段拒绝，不能用 `--force` 绕过；finalizer 末尾重新断言 effective owner 与离线策略。
- Profile 引用：`install.post_install.bundle`（与 diskless 的 `diskless.provision.bundle` 对应）。

## 6. 发行版版本矩阵

- Rocky/RHEL 系与 Ubuntu 后续 LTS 的显式 adapter capability matrix：声明每个 (distro, version, arch) 支持的
  storage mode、software kind（environment/group/task/metapackage/package）、bootloader 与 firmware。
- bootloader、发行版版本差异、错误分类与长期运行回归。
- 对当前 adapter 不适用的 kind 返回 `software.kind_not_applicable` 并列出 `supported_kinds`，不能返回易误判的空列表。
- adapter 不能在配置路径不存在或不适用时猜测，也不能实现运行时 fallback。

## 7. CLI（v0.3）

> 完整 CLI 约定见 [`V0_2_CLI.md`](V0_2_CLI.md) §0；本节给 v0.3 新增。

```text
nodeforge node set <node> firmware.mode=bios              # schema v5
nodeforge profile set <profile> install.post_install.bundle=<bundle>
nodeforge assets provision-bundle item add <bundle> --phase install-post \
  action=managed-file content_asset=<id> destination=/etc/motd mode=0644 owner=root group=root
nodeforge assets provision-bundle item add <bundle> --phase install-post \
  action=package packages=tmux,nmap group=core idempotency_key=pkgs timeout_s=600 retryable=true
nodeforge node postinstall show <node> --phase install-post
```

- `firmware.mode` 是 Node direct 字段，不经 `overrides`；不适用 BIOS 的属性返回 `property.not_applicable`。
- v0.3 不提供多 NIC/VLAN/bonding、容量压测、install 侧 agent 的 CLI（属 v0.4/永久非目标）。

## 8. 明确非目标（v0.3 增量）

- 多 NIC/VLAN/bonding、PXE 阶段纯静态、下载后切换地址/子网 -> v0.4（需显式 initrd feature/schema/验收）。
- 大规模容量压测 -> v0.4。
- install 侧 first-boot agent -> v0.4（确定性，无 reconciliation）。
- reconciliation/远程控制 -> 永久非目标（全版本）。
- IPv6、by-id/serial/WWN -> 永久非目标（继承 v0.1）。
- v0.3 不提供 v0.4/v0.5 命令的 help/handler；预留 enum 不算实现。

## 9. 完成标准

- schema v5 migration/rollback 将全部 v4 Node 显式物化 `firmware.mode=uefi`，活动 session 保护和 digest 预览通过。
- `firmware.mode` migration、claim/config、DHCP observed mismatch、readiness 和 digest 覆盖完整。
- BIOS x86 PXELINUX 引导、安装、登录、事件、retry/drift 与 daemon restart-resume 回归通过。
- 显式 adapter capability matrix 覆盖目标 Rocky/RHEL 与 Ubuntu LTS；不适用 kind 返回 `property.not_applicable`。
- `install-post` phase 在同一 Assets owner 上实现四类 action、八步契约、保护域/finalizer、plan/status/retry，与
  `rootfs-build`/`first-boot` 语义一致；`standard_packages` 已退出。
- `node list`/`node status` 对 install BIOS/UEFI 与 diskless 统一投影，installer 进度仅在 `node_status` 保留。
- 本审计与版本设计、配套文档同步更新；预留 enum/空 handler 不算实现证据。
