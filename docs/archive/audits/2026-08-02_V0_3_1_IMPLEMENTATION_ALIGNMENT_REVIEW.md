# NodeForge v0.3.1 实现与设计对齐审查（归档）

状态：历史归档；基线为 v0.3.1，不代表当前 v0.4 实现状态
审查基线：`a29ca69`（2026-08-02）
产品版本：`0.3.1`
配置 schema：v4（config.json，`AppConfig.schema_version`）
Catalog schema：v5（`Catalog.schema_version`，v0.2.3 从 v4 直接替换升级）

本文回答“代码已经实现到哪里、哪些设计表述已经过期、后续版本应从哪里继续”。
它不替代各版本目标设计；实现状态发生变化时必须更新本文或建立新的带基线审计。

## 1. 审查范围与方法

本轮逐域检查：

- `build.zig`、四个程序入口和安装路径；
- config/catalog schema、事实模型、typed property/collection registry；
- DHCP/TFTP/HTTP 路由和 install/diskless boot target；
- rootfs/initrd builder、BootConfig v3、AgentPlan v1、node-apply、first-boot；
- delivery/deployment/session/inventory/operation 持久化；
- identity store、Profile metadata/provenance、clone、capability restart 语义；
- ISO import durable worker、CLI exit mapping 与死代码清理；
- v0.3 install-post canonical runner、generation-bound callback、journal/finalizer 与 v0.3.1 CLI；
- 当前 CLI command tree、shell contract tests、HTTP tests 和实机/QEMU 记录；
- `docs/design/`、`docs/archive/audits/`、`docs/validation/`（及历史 `docs/archive/validation/`）与 README 导航。

验证基线：

```text
zig build test --summary all
结果：460/460 tests passed
```

环境型 QEMU/VMware 脚本未在本轮重复执行；aarch64 VMware Rocky/Ubuntu diskless
定向回归已通过（2026-07-31，见
[`V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md`](../../design/V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md) §10）。
x86_64 VMware 与重复 QEMU 不在当前完成闸，按
[`DEFERRED_DESIGN_INDEX.md`](../../design/DEFERRED_DESIGN_INDEX.md) 管理。

## 2. 当前实现事实

### 2.1 版本、程序与 schema

| 维度 | 当前代码事实 |
|---|---|
| 产品版本 | `build.zig` 当前值 `0.3.1`；v0.3.1 增加 long node listing，不改变 config/catalog/DTO schema |
| 程序 | `nodeforge`、`nodeforged`、`nodeforge-initrd`、`nodeforge-agent` 四个产物 |
| config schema | `AppConfig.schema_version = 4`（v0.2.3 不变） |
| catalog schema | `Catalog.schema_version = 5`（v0.2.3 从 v4 直接替换升级，不迁移） |
| Catalog 布局 | manifest layout schema v1 + catalog schema v5，8 类 entity 文件 |
| 节点交付 DTO | BootConfig v3、AgentPlan v1（v0.3.1 不升级） |
| install/diskless | UEFI install 与 UEFI diskless 共存 |

“schema v3 已完成”只能描述 v0.1 历史里程碑，不能描述当前文件格式；“两个二进制”
也不再是构建事实。catalog schema 变更一律直接替换（不迁移，见
[`V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md`](../../design/V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md) §0）。

### 2.2 v0.2 diskless 已实现（v0.2.0 基线）

代码已经具备：

- schema v4 `ProfileKind=install|diskless`、boot bundle 与内容寻址 rootfs；
- ISO vendor initrd 原样前缀 + NodeForge gzip/newc overlay；
- TFTP 内部 boot-prepare/capsule，公开 CLI 不返回 raw capability；
- v0.4 已删除 config/rootfs/agent 四域 token：BootConfig/rootfs/payload 使用 DHCP
  peer/session/digest binding，仅 AgentPlan 小型控制面读取使用短时 boot-session
  capability，状态推进保留 event credential；
- BootConfig v3、AgentPlan v1、node-bound GET/HEAD/Range；
- rootfs SHA-512、ETag/If-Range、分块恢复、内存闸；
- squashfs lower + tmpfs overlay upper + switch_root；
- agent pre-init node-apply、first-boot journal/timeout/retry/backoff；
- first-boot content-addressed payload path/digest/size 固定与预取校验；
- diskless session list/show/cancel、build/boot readiness、operation show/wait；
- Rocky/RHEL `dnf --installroot` OS-layer builder；
- aarch64 Rocky QEMU 与 VMware UEFI PXE 闭环证据。

### 2.3 v0.2.1 Ubuntu casper 产品化（已完成）

`rootfs_os_builder.buildCasperOverlay` 替换了原 `AptOsLayerUnsupported`；
`iso_import.discoverCasperLayers` 在 `assets import` 时发现并序化 casper layer
清单（fail-closed 处理歧义/缺失 parent）；rootfs-build `package` 步骤（dnf 与 apt
均适用）统一经 `namespaced_chroot_executor.zig` 在独立 mount/PID namespace + chroot
内执行，替换了原 `AptRootfsBuildUnsupported`。2026-07-30 在 r97n0 root 环境完成真实
Ubuntu ISO 导入和 casper rootfs 构建，并在 VMware `r97n1` 连续两次到达 `diskless.running`。
fresh CLI 与 Rocky 9.7/10.2、Ubuntu 22.04.5 aarch64 VMware 冷启动回归已通过。

独立 QEMU launcher（`tests/v0_2_1_ubuntu_casper_smoke.sh`）和 x86_64 VMware 不作为
版本阻断闸，统一按 [`DEFERRED_DESIGN_INDEX.md`](../../design/DEFERRED_DESIGN_INDEX.md)
管理；现有 smoke 脚本保留为实验室回归入口。

### 2.4 v0.2.2 可运营性（已完成）

v0.2.2 把 v0.2 系列变成可长期维护的稳定底座，已落地：

- **durable build operation**：rootfs 与 initrd 均使用 daemon worker（8 槽有界队列），
  handler 持久创建 queued operation 后返回，CLI 默认 follow、支持 `--detach`；
  daemon restart 后 queued/running 确定性恢复为 `operation.interrupted`；
- **持久化升级兼容**：diskless delivery schema 1→2、deployment-control schema 3→4、
  inventory schema 1→2 均有显式字段映射与“旧 checkpoint→保存→再加载”fixture，
  冲突 alias fail-closed；
- **no-side-effect preview 与统一 retry**：`node boot preview` 严格只读；
  kind-aware 服务端原子 `node retry`；
- **inventory memory/readiness**：inventory schema 2 保存 `memory_bytes`，
  freshness 固定 30 天，过期为 `memory=stale`，unknown 仍由 initrd `MemAvailable` 硬闸；
- **session/persistence recovery**：boot session store 与 diskless delivery store
  的 restart-resume 边界已冻结；
- **CLI 收敛**：`boot-prepare` 已从公开 CLI 移除（仅保留内部 management transition）；
  `node postprocess show` 已公开；正式 `docs/cli/REFERENCE.md` 与 CLI help 契约测试已建立；
- 当前可用 aarch64 VMware UEFI 发布矩阵已通过。

### 2.5 v0.2.3 Profile identity 与恢复收口（已完成）

v0.2.3 是 v0.2 系列最后一个收口版本，不增加部署形态。已落地（Batch 1–5）：

- **catalog v5**：`Catalog.schema_version` 4→5 直接替换，旧 v4 catalog 不被加载
  （`UnsupportedSchemaVersion`）；`AppConfig.schema_version` 保持 4；config/catalog
  校验路径已分离；
- **identity store**（`src/state/identity_store.zig`）：daemon-owned SSH identity，
  `(id, revision)` 复合键，ed25519 密钥对；0600 文件/0700 目录，`atomicWriteSecret`
  创建即 0600；两阶段 journal（`prepare`/`commit`/`rollback`）与启动恢复
  （`recoverPendingTransactions`，fail closed）；损坏/缺失/复合键重复/fingerprint 不匹配
  或密钥不成对时 daemon 拒启；
- **Profile metadata**：`ProfileConfig` 增加 `revision`/`created_at`/`updated_at`/
  `provenance`/`ssh_identity`；`mutateProfileMetadata` 统一 revision helper
  （`src/config/profile_mutation.zig`），所有公开 Profile mutation 成功恰好 +1、
  失败/no-op +0，由 `src/config/revision_scan.zig` 契约测试覆盖；
- **create/clone**：`managementProfileCreate`/`managementProfileClone` 接线 identity 事务；
  clone 支持 `--new-ssh-keys`/`--build`/`--detach` 与同事务 property patch；
  `--build` 提交失败不回滚已成功 clone（`profile_created`/`build_submitted` 可诊断）；
- **rootfs identity**：`installIdentityKeys`（`src/provision/rootfs_os_builder.zig`）
  按复合键从 store 读取 client/host keypair 烤入 staging（dnf 与 casper 两分支），
  构建期不再调用 `ssh-keygen`；`ProfileBuildProjection` 增加 Profile/identity 字段，
  identity 变更产出新 `rootfs_input_digest`；`--new-ssh-keys` 轮换
  （`rotateSshIdentity`）；
- **capability restart 语义冻结**：确定性重构原 token（HMAC-SHA256 派生，
  restart 前后同一 token，不签发第二 token）；diskless delivery checkpoint schema v3
  （每个 slot 强制 `claim_mac`，v1/v2 直接替换拒载）；terminal session 保留长期状态投影
  但不恢复 capability；master secret 变化或 hash 不匹配进入 `recovery_incomplete`；
- **ISO import durable worker**（`IsoImportWorker`）：队列容量 1，daemon 启动时 spawn、
  停止时 join，替代 handler 级 `iso_import_mutex`；handler 改为 `beginQueuedRequest`→
  submit→202；restart→interrupted 由 `operations.load` 保证；
  `cleanupOrphanStaging` 启动时扫描 `work/` 删除 `iso-import-*` 孤儿目录；
- **CLI exit mapping**：`mapErrorToExitCode`（`src/main.zig`）0–6 契约稳定映射，
  纯函数单测覆盖每个 exit class，端到端由 `tests/http.sh` 覆盖；
- **CLI 位置参数优化**：`node deploy <id>` 缺省 `true`；`node trace --session X --latest`
  返回 exit 2（`trace.conflicting_flags`）；
- **死代码清理**：删除 `src/main.zig` 未绑定命令树的 `initrdBuildHandler` 及
  `initrd_build_executor.build`（`buildFromInstaller` 保留，daemon worker 在用）；
- aarch64 VMware Rocky/Ubuntu diskless 定向回归均已通过（2026-07-31）。

### 2.6 v0.3/v0.3.1（已完成）

v0.3 已把 install-post 扩展到 `managed_file|package|archive|script` 四类 canonical action，复用现有
BootSession callback credential并在 `installer.started` 后固定 install generation；install-post journal、step attempt、
finalizer WAL/恢复与 `node postprocess show --phase install-post --generation` 已落地。fresh 双机 install/diskless 发布闸
通过，证据见 [`V0_3_VALIDATION.md`](../validation/V0_3_VALIDATION.md)。v0.3.1 只补 long node listing；AppConfig v4、
catalog v5、BootConfig v3、AgentPlan v1 保持不变。v0.3 及更早版本设计按已落地冻结基线管理。

### 2.7 当前 CLI 与目标 CLI 的边界

v0.2.2/v0.2.3 已把 [`CURRENT_CLI_OPTIMIZATION_PLAN.md`](../design/CURRENT_CLI_OPTIMIZATION_PLAN.md)
中的主要 proposed 项落地为现行接口：

- ✅ `profile clone`（含 `--new-ssh-keys`/`--build`/`--detach` 与 property patch）；
- ✅ 无副作用 `node boot preview`；
- ✅ install/diskless 统一、服务端原子的 `node retry`；
- ✅ `node postprocess show`；
- ✅ rootfs/initrd 默认后台 operation、`--detach`；
- ✅ `node deploy <id>` 缺省 `true`。

当前正式命令包含：

- node list/show/add/set/unset/remove/claim/render/retry/deploy/trace/readiness/
  session/boot preview/postprocess；
- diskless boot-prepare/readiness/session（boot-prepare 已降为内部 transition）；
- profile create/clone/remove/list/show/set/unset/rootfs plan|build|status；
- asset/register/import、initrd build、boot-bundle、provision-bundle；
- operation show/wait/list/follow、runtime、events、discovery、status/setup。

从 command spec 自动生成全部正式 CLI reference 仍为 `UNSCHEDULED`（`V02-D08`），
不属于当前完成闸。

## 3. 代码审查发现

以下发现已在 v0.2.1–v0.2.3 期间处理：

### 已处理 P0：持久化字段改名未升级 schema

`e1af4e0` 把 diskless delivery 的 `created_at/started_at` 改为 `armed_at/install_at`、
deployment-control 的 `requested_at/started_at` 改为 `armed_at/install_at`，但持久化
仍写旧 schema。已修复：diskless delivery schema 1→2、deployment-control schema 3→4、
inventory schema 1→2，显式解析旧字段并映射，冲突 alias fail-closed，加入
“旧 checkpoint → 新二进制 → 保存 → 再加载”fixture。

### 已处理 P1：AgentPlan 的 first_boot_bundle 元数据引用错误 owner

boot-prepare 已从 `profile.bundle`/Node override 解析 effective first-boot steps，
但 DTO 原写入 `profile.boot_bundle`。已写入 effective provisioning bundle name，
并覆盖 Profile 默认与 Node override 测试。

### 已处理安全边界（v0.2.1）：Ubuntu rootfs-build package

`namespaced_chroot_executor.zig` 用一次性 `unshare --mount --pid --fork` 子进程 +
chroot 执行 dnf/apt 包安装，只读绑定受管 repository，`policy-rc.d` 阻止服务启动；
退出后校验挂载点已清理，未清理则整体失败。`BuildCommand.isolation` 区分
`.chroot`（managed_file/archive/script）与 `.namespaced_package`（package），
手工构造的非法 isolation 声明仍被 `UnsafeHostBuildCommand` 拒绝。

### 已处理 P1：同步 management handler 与构建 operation 语义不一致

rootfs/initrd build 现由 handler 持久创建 queued operation 并提交有界 worker；
worker 推进 running/terminal，CLI 按 Location 轮询到终态。重复 idempotency key
复用在途 operation，operation 文件写入串行化。daemon restart 后 queued/running
确定性恢复为 `operation.interrupted`，不从残留 staging 猜测成功。

### 已处理 P1：readiness 没有可信内存 inventory

inventory schema 2 已保存 `memory_bytes`；Kickstart/Autoinstall facts 与 diskless
initrd 都使用 session capability 上报，旧 generation/session 不可覆盖。freshness
固定 30 天，过期为 `memory=stale`。BootConfig v3 新增 `facts_url`，服务端以
`memory_bytes-kernel-initrd` 作为 budget，unknown/stale 最终仍由 initrd `MemAvailable`
硬闸。

### 已处理 P2：注释和设计状态漂移

已修订的典型问题：

- `ProfileConfig` 不再称为 v0.1 install-only；
- diskless DTO 不再把已实现 payload 说成未来增强；
- legacy install boot-config 的 diskless 分支说明为防御性不可达；
- rootfs builder 不再把未实现 Ubuntu 路径写成 debootstrap 现状；
- rootfs-build executor 明确 `--installroot` 当前只对 dnf 成立；
- `ProvisionPhase/Action` 注释区分 schema 能表达与各 runner 真正支持；
- `reconstructAndVerifyRaw` 注释已删除“capsule 交付前/中重启必须 recovery_incomplete”
  的旧表述，改为确定性重构语义（v0.2.3 §6）。

## 4. 已知遗留（不在 v0.2.3 完成闸内）

- **legacy profile identity 初始化**（[`V0_2_POST_RELEASE_BACKLOG.md`](../design/V0_2_POST_RELEASE_BACKLOG.md)
  §3.1 item 8）：旧 Profile（空 `ssh_identity`）首次使用时尚未实现确定性、可审计的
  identity 初始化；实测影响为 legacy profile 无法重建 rootfs（`IdentityNotFound`
  fail closed）。回归以新建 v0.2.3 profile 规避。该项不反向打开已经完成的 v0.2.3/v0.3 设计；
  v0.4 通过 fresh replacement 和重新创建 Profile 消除旧 Profile 输入，不增加 legacy 初始化兼容路径。

## 5. 文档对齐结论

| 文档 | 当前状态 |
|---|---|
| `README.md` | 已更新至四产物、schema v4/v5、当前 v0.3.1、v0.4 规划与 diskless 流程 |
| `docs/README.md` | 已含当前审计、v0.2.1+ roadmap、v0.3 冻结基线、v0.4 与独立保留设计入口 |
| `V0_2_DESIGN.md` | diskless 版本边界、跨域不变式、实现状态表 |
| `V0_2_1_UBUNTU_DISKLESS.md` | casper layer productization，已完成 |
| `V0_2_2_OPERABILITY.md` | 持久化兼容、异步 builder、CLI 收敛、矩阵，已完成 |
| `V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md` | identity/recovery/ISO worker/exit mapping，已完成 |
| `V0_2_1_PLUS_ROADMAP.md` | v0.2.0–v0.2.3 已完成；v0.3 已完成；v0.4 设计冻结、实现未开始 |
| `V0_3_DESIGN.md` | install-post canonical 扩展，已完成 |
| `V0_4_DESIGN.md` | 多 NIC/topology/容量/服务端 rootfs/install first-boot，设计冻结 |
| `DEFERRED_DESIGN_INDEX.md` | static PXE、BIOS/PXELINUX、`ram_rootfs` 均为不编号、未排期的独立保留设计，不进入 v0.4 |

历史审计中的“v0.2 尚未实现项”保留用于追溯，不再作为当前实现清单。

## 6. 发布顺序建议

```text
v0.2.0 Rocky diskless 基线
  -> v0.2.1 Ubuntu casper productization（已完成）
  -> v0.2.2 operability + CLI convergence + fixed matrix（已完成）
  -> v0.2.3 Profile identity/recovery/ISO worker/exit mapping（已完成）
  -> v0.3/v0.3.1 install-post canonical extension + CLI（已完成，当前基线）
  -> v0.4 topology/capacity/服务端 rootfs/install first-boot（设计冻结，实现进行中）
```

详细依赖、schema/DTO 表和每版完成闸见
[`V0_2_1_PLUS_ROADMAP.md`](../design/V0_2_1_PLUS_ROADMAP.md)。
后续实施从已完成的 v0.3.1 基线进入 v0.4；
reconciliation/远程控制为永久非目标。
