# M5–M7 设计与实现对齐审计

> M5-M7 现归入 `V0_2_DESIGN.md`，必须等待 `V0_1_DESIGN.md` 的 M4.13 修复和 schema v3
> 验收完成。v0.2 强制继承 PropertySpec/CollectionSpec/ItemSpec、统一输出、软件 selection 和全资源禁止
> Shell 内嵌 JSON 的契约。本文保留 2026-07-20 时点的代码缺口证据。

审计更新：2026-07-20。M4.12 的 effective storage fallback 已实现并有自动化证据，但其 Profile boot disk 和
`install_disks` 所有权不会进入 v0.1 schema。v0.1 目标改为 Node direct `storage.boot_disk/additional_disks`、
Profile storage mode/policy 与 Node 完整 override，并在进入 v0.2 前完成原生多盘双 adapter 验收；这不改变
M5 未完成结论。v0.2 已进一步冻结按里程碑迁移：M5 schema v4 tagged Profile 和 node-bound rootfs variant、
M6 schema v5 confirmed `firmware.mode`、M7 schema v6 provision action/phase；不得在同一 schema 号下静默改 shape。

审计范围：M5（无盘启动）、M6（支持矩阵/PXELINUX）和 M7（补充包与后处理），对照
`docs/DETAILED_DESIGN.md`、`docs/DESIGN.md`、`README.md` 以及当前 `src/`、`tests/`。

## 结论

M5–M7 当前是设计目标和部分 M4/M3 预留模型，不是已经完成的里程碑。M4.12 已把所有已实现安装消费者收敛到 effective storage，但 M4.13 还需把它改为 Node direct 主盘/附加盘与可复写的原生 storage policy；diskless 消费者仍不存在。此前文档中将 M0–M7
统一写成“可验收产品阶段”，以及把 M5/M7 写成已交付基础 runner，均超出了当前代码证据；本次已改为
明确的“设计冻结/实现待完成”状态，避免把预留类型和 resolver 单测误报为端到端能力。

## 证据矩阵

| 里程碑 | 已存在的代码 | 缺失的设计承诺 | 当前结论 |
|---|---|---|---|
| M5 | `ProfileMode.diskless`、`BootBundleConfig`、rootfs/nodeforge-initrd asset kind、`boot/target.zig` 的 diskless target 解析、M4 事件 stage 映射；M4.12 effective storage 抽象 | schema v4 tagged Profile、manifest/build、node-bound variant、dracut/overlay、typed BootConfig、capability Range route、status/retry、QEMU smoke | 只有模型和 PXE target scaffold；M5 未完成 |
| M6 | DHCP 架构识别、UEFI x86_64/aarch64 GRUB 路径和基础 fixture | schema v5 `firmware.mode`、BIOS PXELINUX、后续发行版能力矩阵、生产压测/重试能力 | M6 未完成；UEFI 双架构基础不等于 M6 |
| M7 | `provision/runner.zig` 的 M4 `install_post` 三种动作：repository、standard_packages、managed_file | v0.1 owner 迁移、schema v6 tagged action/phase、archive/script/first-boot/runtime、CRUD/plan/status/retry、审计和三链路回归 | M7 未完成；runner 不是 M7 交付 |

## 关键不一致

1. M5 设计要求 `boot-config` 为 diskless 返回 rootfs、required features 和 capability；当前
   `src/http/server.zig` 的 diskless 分支为空对象，不能驱动设计中的 initrd 流程。
2. M5 设计要求 `/api/v1/nodes/:id/artifacts/rootfs/:name`、Range/ETag/认证下载和 initrd 事件闭环；当前
   `src/http/routes.zig` 没有 rootfs artifact 路由，且仓库没有 `initrd/`、`rootfs/`、`assets/bundle.zig`
   或 dracut module 实现。
3. M5 设计列出的 `rootfs`、`initrd`、`boot-bundle`、`diskless` CLI 尚未注册在 `buildCli`；文档示例不能
   当作当前可执行命令。
4. 当前没有按 Node identity + effective digest 隔离的 rootfs variant builder/cache；通用 rootfs asset 不能代替
   含用户、密码 hash、SSH key 和 hostname 的 node-bound artifact。
5. M6 的 BIOS PXELINUX 只有注释和未来分支说明；当前 boot resolver 仍返回 UEFI GRUB bootloader，也没有
   Node confirmed `firmware.mode` 或 observed mismatch gate。
6. M7 的 `ProvisionAction` 和 `ProvisionPhase` 枚举只包含 M4 三种动作和 `install_post`；repository/package
   仍与 Assets/software owner 冲突，不能用当前 runner 的单元测试声称 M7 完成。

## 后续合入门槛

M5 开始实现前必须先补齐 schema v4 migration、diskless BootConfig/认证 DTO、node-bound variant/rootfs route、
manifest/能力校验、dracut 构建产物和至少一条可复现 QEMU smoke；M6 必须用 schema v5 增加 confirmed firmware、
PXELINUX fixture 与目标机验证；M7 必须用 schema v6 扩展 v0.1 同一 Assets bundle 的强类型 ItemSpec、
item CRUD/atomic file replacement、状态 writer 和错误 retryability；
M5 rootfs/bundle list 和 M7 steps 不得引入 argv JSON、`standard_packages` 或第二套 users/network defaults。任何阶段完成标记都必须同时
更新本审计、详细设计、代码注释、CLI help、fixture 和实机/模拟验收记录。
