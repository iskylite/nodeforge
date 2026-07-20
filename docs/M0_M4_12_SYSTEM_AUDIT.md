# M0-M4.12 系统实现审计

> 本文是当前代码证据快照，不是现行目标模型。M4.12 的 storage fallback 虽有自动化证据，
> 但所有权结论已被 `V0_1_DESIGN.md` 的 M4.13 修复计划取代；v0.1 尚未完成。

审计日期：2026-07-20。范围是当前 `main` 分支中 M0 至 M4.12 的代码、自动化测试、CLI 契约和 PXE 启动链。本文把证据分为：

- **自动化**：代码和 `zig build test --summary all` / shell 套件可重复验证。
- **实机**：仓库中的 Rocky/Ubuntu 验证记录明确报告目标机或 VMware PXE 行为。
- **设计/脚手架**：模型、枚举、注释或 resolver 分支存在，但缺少可执行消费者和验收链。

本轮代码变更后的自动化基线为 `Build Summary: 12/12 steps succeeded; 254/254 tests passed`。TFTP 测试中的 retransmit warning 是故障注入输出，不是构建失败。M4.12 没有新增实机记录，因此其硬件状态仍是“继承既有安装链基线，未单独验证”。

## 里程碑证据矩阵

| 阶段 | 代码证据 | 自动化证据 | 实机/结论 |
| --- | --- | --- | --- |
| M0 | `src/app.zig`、`src/http/server.zig`、`src/config/validate.zig`、`src/main.zig` | HTTP、配置、启动预检和 CLI shell | Rocky 9.7 记录；已实现 |
| M1 | `src/tftp/server.zig`、`src/boot/grub.zig` | RRQ/OACK、重传、路径安全 | Rocky 9.7 TFTP/GRUB 记录；已实现 |
| M1.5 | `src/cli/output.zig`、`src/cli/table.zig`、`src/cli/views.zig` | 人类表格、无 ANSI、JSON 输出测试 | 自动化已实现；无独立硬件语义 |
| M2 | `src/dhcp/server.zig`、`src/boot/resolver.zig` | DHCP packet/lease/PXE shell | Rocky 9.7 DHCP/PXE 记录；已实现 |
| M2.5/M2.5.1 | `src/observe/*`、`src/state/events.zig`、`src/state/boot_session*` | Event v2、session 关联、查询 | Rocky 9.7 server-side 记录；installer/initrd 消费者属于后续阶段 |
| M3/M3.5/M3.6 | `src/http/routes.zig`、`src/http/server.zig`、`src/catalog/iso_import.zig`、虚拟 `grub.cfg` | 认证、Range、ISO 幂等、canonical URL、虚拟 GRUB | Rocky/Ubuntu 记录覆盖已实现数据面；已实现 |
| M4 | `src/profile/adapter/kickstart.zig`、`src/profile/adapter/ubuntu.zig`、`src/profile/render.zig` | answer、事件 hook、双 adapter 测试 | Rocky 9.7 与 Ubuntu 22.04 安装记录；已实现 |
| M4.1 | `src/profile/install.zig`、`src/state/deployment_control.zig`、`src/state/plan_digest.zig` | 默认系统、一次性 generation、retry/drift、密钥和 storage 测试 | Rocky/Ubuntu 生命周期记录；已实现 |
| M4.2 | `src/dhcp`、`src/tftp`、`src/config/node_mutation.zig`、key CLI | deploy gate、TFTP 参数、节点 mutation shell | 既有实机记录；已实现 |
| M4.3 | `src/state/model_runtime.zig`、`src/catalog/store.zig`、`src/http/client.zig` | catalog transaction、session resume、ISO/import、node/profile view | Rocky/Ubuntu 记录；已实现 |
| M4.4 | `src/http/routes.zig`、`src/http/server.zig` | 三平面 URL、405/Allow、旧路径拒绝 | 既有 HTTP/PXE 记录；已实现 |
| M4.5 | `src/http/contracts.zig`、分页/ETag/Operation client | 结构化信封、幂等、分页、bounded reader | Rocky 管理 API 记录；已实现 |
| M4.6 | `profile.kernel_args`、adapter 和 `boot/target.zig` | 安全参数校验与三条渲染链测试 | 既有 Ubuntu/Rocky 记录；已实现 |
| M4.7 | `src/paths.zig`、`src/config/store.zig`、`src/catalog/store.zig`、`src/setup.zig` | schema 2、manifest/entity transaction、setup/reset shell | systemd/fresh reconfigure 记录；已实现 |
| M4.8 | capacity/runtime/TFTP/DHCP 派生逻辑 | 2048 ceiling、u16、动态派生和持久化测试 | 尚无生产规模压测；代码已实现，容量验收仍需实测 |
| M4.9 | deployment provenance、joint revision、fresh bootloader | digest migration、gate、resume、rollback 测试 | Ubuntu/VMware 与 systemd 故障记录；已实现 |
| M4.10 | `setup --reconfigure`、ISO import/profile create、node mutation | fresh reset、work 清理、错误透传 shell | Ubuntu/VMware fresh flow 记录；已实现 |
| M4.11 | `nodeforge status`、`src/cli/views.zig`、owner/action 视图 | readiness、help、状态 JSON 和 key allowlist shell | 既有运行面记录；已实现 |
| M4.12 | `NodeStorageOverrideConfig`、`effectiveInstall`、API/CLI/digest/validate/renderer | 本轮新增覆盖、回退、digest、render、JSON envelope 测试；254/254 | 本轮无新增实机记录；代码/自动化已实现，硬件待补 |

## PXE 安装链

安装模式的实际调用顺序如下，括号内是当前代码证据：

1. DHCP 根据 RFC 4578 架构和 MAC 解析节点，并执行 generation gate（`src/dhcp/server.zig` -> `src/boot/resolver.zig:resolveWithDeployment`）。
2. ACK 后创建/复用 BootSession；TFTP 服务读取同一身份（`src/tftp/server.zig`、`src/state/boot_session*`）。
3. TFTP 对虚拟 `grub.cfg` 调用 `src/boot/target.zig:resolve`，再由 `src/boot/grub.zig:render` 生成 UEFI 条目；kernel/initrd 来自 catalog asset。
4. RHEL 使用 `inst.ks`，Ubuntu 使用 NoCloud-Net canonical install-config URL；路由注册和认证位于 `src/http/routes.zig` / `src/http/server.zig`。
5. answer handler 根据 profile、node 和 pinned session 生成 Kickstart/Autoinstall；安装存储统一通过 `profile.install.effectiveInstall` 合并 node override。
6. installer hook 调用节点事件/日志接口，server 更新 `node_status` 并写入 Event v2；deployment digest、generation 和 session 共同决定终态与 retry。

该链条说明 M4 的 PXE 安装已形成可执行闭环，但不等于 diskless 已形成闭环。事件 enum、`diskless` profile mode 和 boot bundle 类型只能证明公共模型预留存在。

## CLI 边界与输出契约

| 命令面 | 唯一 owner | 允许的事实/动作 |
| --- | --- | --- |
| `setup`、`config validate/export` | 离线 startup config | 目录自举、schema 校验、候选配置导出；不在线修改 daemon catalog |
| `node`、`profile`、`assets` | `nodeforged` catalog/resource API | 通过本机 management API 读写 daemon-owned 实体；要求 ETag/If-Match |
| `status`、`runtime`、`events` | runtime/observation | 只读运行态、租约、TFTP、事件和 readiness |
| `node render`、`config export`、`catalog export` | artifact/export | 输出答案或规范化 JSON；不是人类/JSON 视图切换命令 |

展示规则：human 输出经过 `cli/views.zig`/`cli/table.zig`；机器输出使用 `cli/output.zig` 的 `{ok:true,result:{...}}` 或 `{ok:false,error:{code,message}}`；列表 JSON 聚合全部 cursor 页面并将 `next_cursor` 置为 `null`，翻页期间 view revision 变化则失败重试。`node render` 只产生 answer artifact，因此不再注册无效的 `--output`。

仍有一项明确的 CLI 架构债务：`src/main.zig` 当前为 2862 行，并有 201 个直接
`ctx.writer.print/writeAll/writeByte` 调用。旧 status/assets/runtime/events handler 尚未全部迁移到公共
success/error serializer，部分 `--output json` 的本地加载/daemon-unavailable 失败仍可能输出 human `error:`。
此外，当前 property allowlist 和逗号分隔 list parser 不能满足 `V0_1_DESIGN.md` 定义的全资源
PropertySpec/CollectionSpec/ItemSpec、`list-values`、framework `--help-full` 与禁止 Shell 内嵌 JSON 契约。
本轮没有对这些互相耦合的 handler 做机械搬移；
M4.13 应按 `cli/commands/node.zig`、`profile.zig`、`assets.zig`、`runtime.zig`、`events.zig` 拆分，让命令模块
只依赖共享 context、typed views 和统一 OutputDocument。该债务是 v0.1 完成门槛，M5 前必须收敛。

## 属性归属矩阵

| 类别 | 事实 | 写入入口 | 备注 |
| --- | --- | --- | --- |
| node identity | `id`、`mac`、`arch`、`profile` | `node add/set` | 节点身份和绑定关系 |
| node direct properties | `ip`、`hostname`、`deploy`、`http_accel` | `node set/unset` | 节点级网络/参与策略 |
| node override | `overrides.network`、`overrides.storage.boot_disk/install_disks` | `node set/unset` | 单节点差异；空 override 自动折叠为 `null` |
| profile defaults/policy | `install.storage`、`kernel_args`、`system`、`safety`、`reinstall_policy` | `profile set` 仅开放窄字段 | storage 是共享 fallback，不是单节点硬件事实 |
| derived/read-only | effective storage/system、deployment intent、digest、status、inventory、view revision | daemon projection / `show` | 不得伪装成 `set` key |

effective storage 的合并顺序固定为 `node override > profile default > schema default`。所有校验、Kickstart/Autoinstall、HTTP detail、CLI show、plan digest 和 retry gate 必须使用同一 effective plan；profile 默认变化只影响没有对应 override 的节点。

上表只描述 M4.12 当前实现，不代表 v0.1 目标。M4.13 已确认：`ip` 改名为 `pxe.ip_reservation`；network 与
`storage.boot_disk/additional_disks` 改为 Node direct；删除重复 `match_mac` 和语义不清、未被 adapter 消费的
`install_disks`；Profile mode/wipe/partition/bootloader policy 支持 Node 完整 override，并由双 adapter 原生生成
single/LVM/RAID/RAID-LVM 拓扑。Profile 物理
boot disk、平台三元组、safety 派生布尔值、legacy packages/users/keys、常量 bootloader target、永远被拒绝的
firmware-order 字段均删除。`http_accel` 因已有实际消费者而保留为默认 false 的 UEFI 实验验证属性，并要求
show/help/set/API/digest 完整覆盖。默认普通用户 `nodeforge/asdf1234` 和 root `asdf1234` 是确认保留的产品默认值，
但必须补齐 canonical CLI 和 Node override；包配置仍迁移到唯一 `software.*` owner。

## M5 缺口与进入门槛

当前已存在的 M5 相关脚手架：`ProfileMode.diskless`、`BootBundleConfig`、`AssetKind.rootfs/nodeforge_initrd`、`boot/target.zig:resolveDiskless` 和事件阶段枚举。缺失的可执行模块如下：

```text
diskless BootConfig DTO + capability/auth
        -> node-bound rootfs GET/HEAD + Range/If-Range/ETag
        -> rootfs/initrd manifest and kernel-release validators
        -> catalog transaction + rootfs/initrd/boot-bundle CLI
        -> dracut 95nodeforge initrd consumer
        -> overlay executor + target-system projection
        -> diskless status/failure quarantine/retry
        -> QEMU UEFI smoke + corruption/resume negatives
```

具体断点：`src/http/server.zig:bootConfig` 的 diskless 分支为空；`src/http/routes.zig` 没有 node-bound rootfs route；仓库没有 `rootfs/validate.zig`、`initrd/validate.zig`、`initrd/dracut/95nodeforge/` 或 overlay executor；`src/main.zig:buildCli` 没有 rootfs/initrd/boot-bundle/diskless 命令；没有 diskless failure lifecycle 或 QEMU smoke。M5 只有在上述依赖共同落地、认证 DTO 与 initrd consumer 互相校验、并通过可复现 smoke 后，才可标记完成。

M6 的 BIOS PXELINUX、后续发行版矩阵和生产压测不能提前借用 M4 UEFI 双架构测试；M7 的 archive/script/firstboot 也不能用 M4 `install_post` 三种动作代替。
