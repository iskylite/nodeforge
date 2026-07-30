# NodeForge 当前实现与设计对齐审查

状态：当前实现事实审计
审查基线：`e1af4e0`（2026-07-29）
产品版本：`0.2.0`
配置/Catalog schema：v4-only

本文回答“代码已经实现到哪里、哪些设计表述已经过期、后续版本应从哪里继续”。
它不替代各版本目标设计；实现状态发生变化时必须更新本文或建立新的带基线审计。

## 1. 审查范围与方法

本轮逐域检查：

- `build.zig`、四个程序入口和安装路径；
- config/catalog schema、事实模型、typed property/collection registry；
- DHCP/TFTP/HTTP 路由和 install/diskless boot target；
- rootfs/initrd builder、BootConfig v3、AgentPlan v1、node-apply、first-boot；
- delivery/deployment/session/inventory/operation 持久化；
- 当前 CLI command tree、shell contract tests、HTTP tests 和实机/QEMU 记录；
- `docs/design/`、`docs/audits/`、`docs/validation/` 与 README 导航。

验证基线：

```text
zig build test --summary all
结果：11/11 steps succeeded；373/373 tests passed
```

环境型 QEMU/VMware 脚本未在本轮重复执行；其完成事实只采用现有 validation
记录，不把脚本存在或 native test 通过等同于硬件闭环。

## 2. 当前实现事实

### 2.1 版本、程序与 schema

| 维度 | 当前代码事实 |
|---|---|
| 产品版本 | `build.zig` 唯一值 `0.2.0` |
| 程序 | `nodeforge`、`nodeforged`、`nodeforge-initrd`、`nodeforge-agent` 四个产物 |
| config/catalog | 只接受和写出 schema v4；没有 v1/v2/v3 在线 parser/migrator |
| Catalog 布局 | manifest layout schema v1 + catalog schema v4，8 类 entity 文件 |
| 节点交付 DTO | BootConfig v3、AgentPlan v1 |
| install/diskless | UEFI install 与 UEFI diskless 共存；BIOS/PXELINUX 尚未实现 |

“schema v3 已完成”只能描述 v0.1 历史里程碑，不能描述当前文件格式；“两个二进制”
也不再是构建事实。

### 2.2 v0.2 diskless 已实现

代码已经具备：

- schema v4 `ProfileKind=install|diskless`、boot bundle 与内容寻址 rootfs；
- ISO vendor initrd 原样前缀 + NodeForge gzip/newc overlay；
- TFTP 内部 boot-prepare/capsule，公开 CLI 不返回 raw capability；
- config/rootfs/agent/event 四域 token；
- BootConfig v3、AgentPlan v1、node-bound GET/HEAD/Range；
- rootfs SHA-512、ETag/If-Range、分块恢复、内存闸；
- squashfs lower + tmpfs overlay upper + switch_root；
- agent pre-init node-apply、first-boot journal/timeout/retry/backoff；
- first-boot content-addressed payload path/digest/size 固定与预取校验；
- diskless session list/show/cancel、build/boot readiness、operation show/wait；
- Rocky/RHEL `dnf --installroot` OS-layer builder；
- aarch64 Rocky QEMU 与 VMware UEFI PXE 闭环证据。

因此 README 中“content-addressed first-boot payload 尚未完成”的说法已过期。
v0.2.0 的 Rocky/aarch64 主链可标为完成；v0.2 系列继续开发不等于 v0.2.0
主链仍处于脚手架状态。

### 2.3 v0.2.1（2026-07-30 更新：生产 CLI builder 已接通）

> 以下 5 点是本审计原始发现，历史保留；2026-07-30 起已全部解决，见本节末尾更新。

Ubuntu 方向已有可行性证据和共用运行时，但生产 CLI builder 仍缺：

1. `rootfs_os_builder` 的 apt 分支直接返回 `AptOsLayerUnsupported`；
2. 没有从 `InstallSource.source_asset` 发现、排序、校验并物化 casper layer closure；
3. rootfs-build `package` 的 apt staging 模型尚未实现；当前在 command render 前以
   `AptRootfsBuildUnsupported` fail-closed，绝不落到宿主 apt；
4. smoke 脚本使用手工产物链，不能证明 `profile rootfs build` 的 Ubuntu 分支；
5. 尚无由同一发布候选执行的 Rocky + Ubuntu 固定回归矩阵。

vendor casper initrd 复用、原生 HTTP、node-apply Netplan/NM 选择和 Ubuntu smoke
都是前置能力，不应被误写为 Ubuntu 产品路径已经完成。

**2026-07-30 更新**：上述 1-3 已实现并通过 `zig build test`（393/393）：
`rootfs_os_builder.buildCasperOverlay` 替换了 `AptOsLayerUnsupported`；
`iso_import.discoverCasperLayers` 在 `assets import` 时发现并序化 casper layer
清单（fail-closed 处理歧义/缺失 parent）；rootfs-build `package` 步骤（dnf 与
apt 均适用）统一经新增的 `namespaced_chroot_executor.zig` 在独立
mount/PID namespace + chroot 内执行，替换了 `AptRootfsBuildUnsupported`。
环境执行状态已更新：2026-07-30 在 r97n0 root 环境完成真实 Ubuntu ISO 导入和
casper rootfs 构建，并在 VMware `r97n1` 连续两次到达 `diskless.running`。
第 4、5 点中的 `tests/v0_2_1_ubuntu_casper_smoke.sh` 独立 QEMU 路径和
Rocky+Ubuntu 同候选回归矩阵仍待在目标环境补跑，不应被当作已验证。

### 2.4 当前 CLI 与目标 CLI 的边界

当前正式命令已经包含：

- node list/show/add/set/unset/remove/claim/render/retry/deploy/trace；
- diskless boot-prepare/readiness/session；
- profile create/remove/list/show/set/unset/rootfs plan|build|register|status；
- asset/register/import、initrd build、boot-bundle、provision-bundle；
- operation show/wait、runtime、events、discovery、status/setup。

`CURRENT_CLI_OPTIMIZATION_PLAN.md` 中的以下能力仍是 proposed，而不是现行接口：

- `profile clone`；
- `profile effective` / `node effective`；
- 无副作用 `node boot preview`；
- install/diskless 统一、服务端原子的 `node retry`；
- `node postprocess show`；
- rootfs/initrd 默认后台 operation、`--detach`；
- 从 command spec 自动生成正式 CLI reference。

`node boot-prepare` 当前既是可见 CLI，又是 TFTP 运行时内部 transition。生产 runbook
不应要求操作员手工调用；v0.2.2 应在 preview/统一 retry 落地后把它降为 advanced/internal。

## 3. 代码审查发现

### 已处理 P0：持久化字段改名未升级 schema

`e1af4e0` 把：

- diskless delivery 的 `created_at/started_at` 改为 `armed_at/install_at`；
- deployment-control 的 `requested_at/started_at` 改为 `armed_at/install_at`。

但 diskless persistence 仍写 schema 1，deployment-control 仍写 schema 3：

- 旧 diskless checkpoint 缺少新的必填 `armed_at`，升级后可能直接加载失败；
- 旧 deployment-control 的新字段有默认值，升级后会静默把时间投影为 0。

这违反“schema 内字段 shape 不变”和 restart-resume 契约。本轮已完成：

1. diskless delivery schema 1→2、deployment-control schema 3→4；
2. 显式解析旧字段并映射，冲突 alias fail-closed；
3. 加入“旧 checkpoint -> 新二进制 -> 保存 -> 再加载”fixture；
4. inventory schema 1→2 同样显式迁移，旧记录的 memory 为 unknown。

### 已处理 P1：AgentPlan 的 first_boot_bundle 元数据引用错误 owner

boot-prepare 已从 `profile.bundle`/Node override 解析 effective first-boot steps，
但最终 DTO 写入的是 `profile.boot_bundle`。前者是 provisioning bundle，后者是
kernel/initrd boot bundle。

现已写入 effective provisioning bundle name，并覆盖 Profile 默认与 Node override 测试。

### 已处理安全边界、功能完成（v0.2.1）：Ubuntu rootfs-build package

rootfs-build executor 对所有 package action 都传 `installroot=staging`，但
`first_boot.renderStep()` 的 apt 分支不消费该参数。若仅接通 casper OS layer 而不修此处，
Ubuntu `rootfs-build package` 会操作构建宿主而非目标 staging。

**2026-07-30 更新**：已实现统一隔离执行模型，不再是"拒绝 apt package"的临时
fail-closed。`namespaced_chroot_executor.zig` 用一次性 `unshare --mount --pid
--fork` 子进程 + chroot 执行 dnf/apt 包安装（不再区分"dnf host-context / apt
不支持"），只读绑定受管 repository，并用 `policy-rc.d` 阻止包安装启动服务；退出后
校验挂载点已清理，未清理则整体失败而非静默放过。`rootfs_build_executor.
BuildCommand.isolation` 枚举区分 `.chroot`（managed_file/archive/script）与
`.namespaced_package`（package），手工构造的非法 isolation 声明仍被
`UnsafeHostBuildCommand` 拒绝。

### 已处理 P1：同步 management handler 与构建 operation 语义不一致

rootfs build 现由 handler 持久创建 queued operation 并提交 8 槽有界 worker；worker
推进 running/terminal，CLI 按 Location 轮询到终态。重复 idempotency key 复用在途
operation，operation 文件写入串行化。daemon restart 后 queued/running 确定性恢复为
`operation.interrupted`，相同输入可创建后继重试；不从残留 staging 猜测成功。

initrd builder 尚未使用该 worker，仍是 v0.2.2 剩余项。

### 已处理 P1：readiness 没有可信内存 inventory

inventory schema 2 已保存 `memory_bytes`；Kickstart/Autoinstall facts 与 diskless
initrd 都使用 session capability 上报，旧 generation/session 不可覆盖。freshness 固定
30 天，过期为 `memory=stale` 而非 pass。BootConfig v3 新增 `facts_url`，服务端以
`memory_bytes-kernel-initrd` 作为 budget，并与 initrd 共用 checked arithmetic/
边界 fixture；unknown/stale 最终仍由 initrd `MemAvailable` 硬闸。

### P2：注释和设计状态漂移

已修订的典型问题：

- `ProfileConfig` 不再称为 v0.1 install-only；
- diskless DTO 不再把已实现 payload 说成未来增强；
- legacy install boot-config 的 diskless 分支说明为防御性不可达；
- rootfs builder 不再把未实现 Ubuntu 路径写成 debootstrap 现状；
- rootfs-build executor 明确 `--installroot` 当前只对 dnf 成立；
- `ProvisionPhase/Action` 注释区分 schema 能表达与各 runner 真正支持。

## 4. 文档对齐结论

| 文档 | 本轮处理 |
|---|---|
| `README.md` | 修正四产物、schema v4、v0.2.0 状态、失效链接和不存在示例 |
| `docs/README.md` | 新增当前审计、v0.2.1+ roadmap、v0.2.2 入口 |
| `V0_2_DESIGN.md` | 增加实现基线；把“当前脚手架影响表”改为实现状态表 |
| `V0_2_1_UBUNTU_DISKLESS.md` | 冻结目标方案、标记实现未完成、补生产切片和验收闸 |
| `V0_2_2_OPERABILITY.md` | 新增持久化兼容、异步 builder、CLI 收敛和矩阵设计 |
| `V0_3_DESIGN.md` | 澄清 install-post phase 已存在，v0.3 扩展 action/回调闭环 |
| `V0_4_DESIGN.md` | 明确依赖 v0.2.2/v0.3 与当前单 NIC route 迁移来源 |
| `V0_5_DESIGN.md` | 明确版本依赖和 schema/DTO namespace 序列 |

历史审计中的“v0.2 尚未实现项”保留用于追溯，不再作为当前实现清单。

## 5. 发布顺序建议

```text
v0.2.0 Rocky diskless 基线（当前）
  -> v0.2.1 Ubuntu casper productization
  -> v0.2.2 operability + CLI convergence + fixed matrix
  -> v0.3 BIOS install + install-post canonical extension
  -> v0.4 topology/capacity/PXE builder/install first-boot
  -> v0.5 ram_rootfs materialization
```

详细依赖、schema/DTO 表和每版完成闸见
[`V0_2_1_PLUS_ROADMAP.md`](../design/V0_2_1_PLUS_ROADMAP.md)。
