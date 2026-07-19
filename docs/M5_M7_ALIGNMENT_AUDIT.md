# M5–M7 设计与实现对齐审计

审计范围：M5（无盘启动）、M6（支持矩阵/PXELINUX）和 M7（补充包与后处理），对照
`docs/DETAILED_DESIGN.md`、`docs/DESIGN.md`、`README.md` 以及当前 `src/`、`tests/`。

## 结论

M5–M7 当前是设计目标和部分 M4/M3 预留模型，不是已经完成的里程碑。此前文档中将 M0–M7
统一写成“可验收产品阶段”，以及把 M5/M7 写成已交付基础 runner，均超出了当前代码证据；本次已改为
明确的“设计冻结/实现待完成”状态，避免把预留类型和 resolver 单测误报为端到端能力。

## 证据矩阵

| 里程碑 | 已存在的代码 | 缺失的设计承诺 | 当前结论 |
|---|---|---|---|
| M5 | `ProfileMode.diskless`、`BootBundleConfig`、rootfs/nodeforge-initrd asset kind、`boot/target.zig` 的 diskless target 解析、M4 事件 stage 映射 | dracut module、initrd 构建/校验、rootfs 构建/校验、overlay 执行器、diskless BootConfig payload、rootfs Range 下载路由、diskless CLI/status/retry、QEMU smoke | 只有模型和 PXE target scaffold；M5 未完成 |
| M6 | DHCP 架构识别、UEFI x86_64/aarch64 GRUB 路径和基础 fixture | BIOS PXELINUX、后续发行版能力矩阵、M5 后续 LTS、生产压测/重试能力 | M6 未完成；UEFI 双架构基础不等于 M6 |
| M7 | `provision/runner.zig` 的 M4 `install_post` 三种动作：repository、standard_packages、managed_file | archive、script、firstboot、bundle CRUD/plan/status、执行状态持久化、stdout/stderr 脱敏、三链路回归 | M7 未完成；runner 不是 M7 交付 |

## 关键不一致

1. M5 设计要求 `boot-config` 为 diskless 返回 rootfs、required features 和 capability；当前
   `src/http/server.zig` 的 diskless 分支为空对象，不能驱动设计中的 initrd 流程。
2. M5 设计要求 `/api/v1/nodes/:id/artifacts/rootfs/:name`、Range/ETag/认证下载和 initrd 事件闭环；当前
   `src/http/routes.zig` 没有 rootfs artifact 路由，且仓库没有 `initrd/`、`rootfs/`、`assets/bundle.zig`
   或 dracut module 实现。
3. M5 设计列出的 `rootfs`、`initrd`、`boot-bundle`、`diskless` CLI 尚未注册在 `buildCli`；文档示例不能
   当作当前可执行命令。
4. M6 的 BIOS PXELINUX 只有注释和未来分支说明；当前 boot resolver 仍返回 UEFI GRUB bootloader。
5. M7 的 `ProvisionAction` 和 `ProvisionPhase` 枚举只包含 M4 三种动作和 `install_post`，与 M7 archive/script/
   firstboot 设计有意不同，不能用当前 runner 的单元测试声称 M7 完成。

## 后续合入门槛

M5 开始实现前必须先补齐 diskless BootConfig/认证 DTO、rootfs artifact 路由、manifest/能力校验、dracut
构建产物和至少一条可复现 QEMU smoke；M6 必须在 M5 smoke 通过后增加 PXELINUX fixture 与目标机验证；M7
必须先冻结强类型步骤 schema、状态 writer 和错误 retryability，再扩展动作。任何阶段完成标记都必须同时
更新本审计、详细设计、代码注释、CLI help、fixture 和实机/模拟验收记录。
