# M5-M7 设计与实现对齐审计

> M5-M7 归入 `docs/design/V0_2_DESIGN.md`，必须等待 `docs/design/V0_1_DESIGN.md` 的 schema v3 与全部进入条件验收完成。
> 本文只记录当前代码证据和实现缺口；契约冲突时以版本设计为准，不能用历史 `docs/archive/M0_M7_LEGACY_DETAILED_DESIGN.md`
> 中的预留类型、命令或旧 phase 名证明能力已经存在。

审计更新：2026-07-21。审计基线是 M4.13 所有权代码落地后的当前 HEAD：Profile 和 BootKind 仅支持 install，
Node direct storage、Profile policy/Node override、effective compiler 和 schema v3 已进入代码。v0.1 是否完成仍由
`docs/design/V0_1_DESIGN.md` 的自动化、迁移和双发行版验收决定；本审计不替它提前宣告完成。

审计范围：M5（无盘启动）、M6（支持矩阵/PXELINUX）和 M7（补充包与后处理），对照
`docs/design/V0_2_DESIGN.md`、`docs/archive/M0_M7_LEGACY_DETAILED_DESIGN.md`、`docs/archive/M0_M7_LEGACY_OVERVIEW_DESIGN.md` 以及当前 `src/`、`tests/`。

## 结论

M5-M7 当前均未实现。仓库保留少量 catalog tuple、asset kind、状态/event 枚举和 M4 provision runner，
但没有可创建的 diskless Profile、diskless boot target、initrd/rootfs consumer、BIOS bootloader 或 M7 agent/run
闭环。任何 CLI 示例、枚举或通用 asset import 都只是设计输入或前置结构，不能作为里程碑完成证据。

上一版审计写于 M4.13 前，所称 `ProfileMode.diskless` 已完全删除，`boot/target.zig:resolveDiskless` 不存在，
`http/server.zig:bootConfig` 也没有 diskless payload 分支。该证据链已作废，后续审计必须从当前 HEAD 重新取证。

## 证据矩阵

| 里程碑 | 当前实际存在 | 关键缺失 | 当前结论 |
|---|---|---|---|
| M5 | `AssetKind.nodeforge_initrd/rootfs`、基础 `BootBundleConfig` tuple、diskless phase/event 枚举；通用 asset import 可接受预留 kind | schema v4 tagged Profile、DisklessEffectivePlan、variant builder、dracut/overlay、typed BootConfig、node-bound Range route、完整状态机/status/retry、QEMU smoke | 只有无 consumer 的数据预留；M5 未开始实现 |
| M6 | DHCP arch 识别、UEFI x86_64/aarch64 GRUB 路径和基础 fixture | schema v5 confirmed `firmware.mode`、BIOS PXELINUX、后续发行版 capability matrix、生产容量/恢复/长期运行验收 | UEFI 基础不等于 M6；M6 未实现 |
| M7 | `provision/runner.zig` 的 M4 `install_post` repository/`standard_packages`/managed-file runner | schema v6 tagged action/phase、Assets item CRUD、archive/script、保护域/finalizer、first-boot/runtime agent 认证、plan/status/retry/reconciliation | M4 runner 与目标 owner 冲突；M7 未实现 |

## 当前代码事实

1. `src/model.zig` 的 `ProfileConfig` 仍是 install shape，`BootKind = enum { install }`；`legacy_diskless_profiles`
   只用于 schema v2 到 v3 迁移阻塞，不是可运行 Profile。
2. `BootBundleConfig` 只保存 distro/version/arch/kernel release 和三个 asset 名称；尚无 revision、joint digest、
   feature manifest、builder provenance、readiness 或 node-bound variant。
3. `src/boot/target.zig:resolve` 无条件调用 `resolveInstall`。文件注释仍提 diskless scaffold，但没有
   `resolveDiskless` 函数或分支，应视为过时注释而非实现。
4. `src/http/server.zig:bootConfig` 只处理 install BootKind；`src/http/routes.zig` 没有
   `/api/v1/nodes/:id/artifacts/rootfs/:name`。因此不存在 diskless DTO、rootfs capability/Range consumer 或
   offline/static-network enforcement point。
5. `src/state/boot_session.zig`、`node_status.zig` 和 `event_types.zig` 有 diskless 枚举，但仓库没有 initrd producer
   或 rootfs delivery E2E。枚举单测不能证明跨 DHCP/TFTP/HTTP/initrd 的 transition、失败和 quarantine 行为。
6. `src/main.zig` 只有通用 asset import 的预留 kind，没有 v0.2 规定的 rootfs/initrd/boot-bundle/diskless
   resource-action tree，也没有相应 PropertySpec/CollectionSpec/ItemSpec。
7. M7 当前枚举和 runner 只有下划线 phase 与 `standard_packages` 自由数组；没有 canonical phase 迁移、
   八步执行器、TargetSystem 保护域、agent enrollment/capability 或 reconciliation 运行态。

## 合入门槛

M5 开始实现前必须同时具备 schema v4 migration、pinned DisklessEffectivePlan、node-specific variant、可复现
dracut/rootfs build manifest、joint readiness、typed BootConfig 与 node-bound rootfs route。安全验收必须覆盖：
BootConfig 只下发 `$6$` hash/public key且全链路脱敏；`local-only` 无公网 mirror/NTP/隐式更新；静态地址严格等于
MAC reservation；token 不进入 URL/boot.json/log；跨 Node、过期、错绑和 Range 负向请求 fail closed。

M5 的状态验收必须从 `dhcp_discover` 覆盖至 `diskless_running`，保留早期 PXE/TFTP 诊断状态，验证任意非终态
到 `failed`、服务端 `expired`、幂等重传、非法跳跃/回退以及与 session phase 分离的 Node quarantine gate。
至少一条受支持架构完成真实 dracut + QEMU diskless smoke，其他架构按 `docs/design/V0_2_DESIGN.md` 的矩阵验收。

M6 必须以 schema v5 增加 confirmed firmware、PXELINUX fixture/目标机验证和显式 initrd 网络 capability；M5 未支持的
纯静态 PXE、多 NIC、VLAN、bonding 或跨子网切换不能仅凭脚本存在即宣称支持。

M7 必须以 schema v6 在同一 Assets owner 上实现 canonical phase、旧名唯一迁移、八步顺序、typed action、
保护域/finalizer、状态 writer 和错误 retryability。first-boot/runtime 必须使用一次性 enrollment 或已建立节点凭据
换取短期 capability；服务端只保存 verifier，diskless credential 不跨启动持久化。DHCP、PXE bootstrap proof 和
installer token 都不得充当 agent 身份，现有 delivery capability 最多保护独立 enrollment secret 的一次领取。
package action 只引用 pinned effective software/capability，不得保留 `standard_packages` 或自由 packages 数组。

任何阶段完成标记都必须同步更新本审计、版本设计、详细设计的替代说明、代码注释、CLI help、fixture 和
实机/模拟验收记录；预留 enum、空 handler、通用导入能力和设计命令一律不算实现证据。
