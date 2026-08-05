# NodeForge v0.2.1+ 实施路线图（归档）

状态：历史归档；v0.4 当前目标与完成闸以 `docs/design/V0_4_DESIGN.md` 为准
基线：产品 v0.3.1 / config schema v4 + catalog schema v5 / BootConfig v3 / AgentPlan v1
更新日期：2026-08-05

本文只定义版本依赖、实施顺序、schema/DTO 演进和完成闸。每个版本的领域细节仍由
对应设计文档负责；当前实现状态以
[`CURRENT_IMPLEMENTATION_ALIGNMENT_REVIEW.md`](../audits/2026-08-02_V0_3_1_IMPLEMENTATION_ALIGNMENT_REVIEW.md)
为准。

## 1. 路线总览

| 版本 | 主目标 | schema/DTO | 当前状态 |
|---|---|---|---|
| v0.2.0 | Rocky/RHEL UEFI diskless + first-boot | catalog v4 / BC v3 / AP v1 | 已实现；安全审计通过（2026-07-29） |
| v0.2.1 | Ubuntu casper diskless 产品化 | 保持 catalog v4 / BC v3 / AP v1 | 已完成；fresh CLI 与 Rocky 9.7/10.2、Ubuntu aarch64 VMware 冷启动回归通过 |
| v0.2.2 | 可运营性、持久化兼容、CLI 收敛、固定矩阵 | 保持 catalog v4 / BC v3 / AP v1；内部 persistence 独立升级 | 已完成并通过当前 aarch64 VMware 发布矩阵 |
| v0.2.3 | Profile identity/provenance、recovery、ISO operation、exit mapping 收口 | catalog v5 / BC v3 / AP v1 | 已完成（含 aarch64 VMware 定向回归，2026-07-31） |
| v0.3 | install-post canonical 扩展、callback generation 绑定与 journal | 保持 catalog v5 / BC v3 / AP v1 | 已完成；aarch64 UEFI install-post 与 diskless 发布回归通过（2026-08-01） |
| v0.4 | 多 NIC/topology、容量、服务端 rootfs、install first-boot、SN+IP draft Node discovery | AppConfig v5 / catalog v6 / BC v3 / AP v2 / InstallFirstBootPlan v1 / NodeDiscoveryState v1 | 设计冻结，实现进行中 |

BC = BootConfig，AP = AgentPlan。catalog、节点 DTO、install callback、operation 和
各 state file 是独立 schema namespace，绝不能因为版本号相同而共用升级判断。

## 2. 强制实施顺序

### Gate 0：先修持久化兼容（已完成）

在 v0.2.1 合入任何功能前，先修复 `armed_at/install_at` 字段改名未提升 state-file
schema 的问题。diskless delivery schema 2、deployment-control schema 4 与 inventory
schema 2 均已有旧 checkpoint→保存→重载 fixture。

### Gate 1：v0.2.1 Ubuntu 产品化（已完成）

只完成 Ubuntu casper 目标，不混入 CLI 大改或 schema v5：

- 同源 ISO 的 casper layer closure；**已实现**（`iso_import.zig` `discoverCasperLayers`）
- vendor initrd 前缀保真；**已实现**（沿用既有通用 vendor-overlay 路径）
- Ubuntu rootfs-build 四动作，尤其 apt package 隔离执行；**已实现**（统一
  `namespaced_chroot_executor`，dnf 与 apt 共用同一 namespace+chroot 原语）
- `profile rootfs build` 到 PXE running 的产品 CLI 闭环；**已在 VMware
  aarch64 UEFI 冷启动通过**
- Rocky/Ubuntu 同候选回归；**Rocky 9.7、Rocky 10.2 与 Ubuntu 22.04.5 已通过**

### Gate 2：v0.2.2 可运营性收口

在更改 catalog schema 前完成：

- durable rootfs build operation；
- no-side-effect preview 与统一 retry；
- inventory memory/readiness；
- session/persistence recovery；
- 当前可用 aarch64 VMware UEFI 上完成 Rocky + Ubuntu 固定矩阵；x86_64 VMware
  归入当前环境不可验证清单，QEMU 只作可选补充证据。

这一步把 v0.2 系列变成可长期维护的稳定底座。v0.3 不得绕过 v0.2.2，
否则后续版本会建立在同步 builder、漂移 CLI 和不完整 restart 语义上。

### Gate 3：v0.2.3 Profile identity 与恢复收口（已完成）

状态：已完成（代码与单测全绿，aarch64 VMware 定向回归已通过，见 v0.2.3 完成标准）。

在后续版本扩展 install-post 或 catalog shape 前完成：

- catalog v5 Profile metadata 与 daemon-owned SSH identity；
- v4→v5 直接替换（不迁移）和旧 artifact 边界；
- clone patch、`--new-ssh-keys`、`--build/--detach`；
- capability 确定性重构原 token 与安全负测；
- ISO 真后台 operation；
- CLI exit mapping。

非目标与完成闸见
[`V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md`](../../design/V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md)。

### Gate 4：v0.3 install-post canonical 扩展

状态：已完成（代码、状态机/恢复测试、aarch64 UEFI install-post 与 diskless 实机闸均通过）。

在 catalog topology 扩展之前完成：

- install-post 四类 canonical action 扩展与旧 action 退出；
- 复用 BootSession callback credential，并在 `installer.started` 后固定到 install generation；
- install-post journal/status；
- aarch64 UEFI install 回归。

非目标与完成闸见
[`V0_3_DESIGN.md`](../../design/V0_3_DESIGN.md)。

### Gate 5：v0.4 schema 直接替换

每版只引入自己需要的持久 shape：

- v0.3 / 保持 catalog v5：install-post canonical 扩展、callback generation 绑定与 journal；
- v0.4 / AppConfig v5 + catalog v6：强制容量上限、target topology、服务端 rootfs、Node hardware serial binding；BootConfig 保持 v3，AgentPlan 升 v2；

v0.4 边界采用直接替换（见 v0.2.3 设计 §0）：旧 config/catalog/state/session/artifact
不被加载、转换或延续，操作员必须 fresh `setup` 并重建输入与制品。

## 3. 跨版本不变式

所有后续版本继续满足：

1. Resource/Profile/Node/Effective/Runtime owner 不分叉；
2. install 与 diskless 共享 target-system/software/kernel_args 语义；
3. rootfs cache 只由 canonical build input digest 标识，不含物理 Node identity；
4. raw capability 不进 catalog、cmdline、日志或公开 CLI；
5. agent 是有界、确定性、开机顺序执行器，不是远程任务平台；
6. reconciliation、长期 enrollment、远程多租户、IPv6、NFS root/iPXE、
   by-id/serial/WWN 永久非目标；
7. 预留 enum、注释或 smoke 脚本不构成实现完成证据；
8. 每个完成声明必须同时有 handler/API、持久化、负向测试和目标环境 E2E。

## 4. 版本完成闸

### v0.2.1

代码状态：casper layer 发现、`buildCasperOverlay`、统一 `namespaced_chroot_executor`
（dnf 与 apt 共用同一 namespace+chroot 隔离原语）、CLI 风险提示（§5.1/§5.2）均已实现，
`zig build test` 通过。完成闸如下：

- Ubuntu source 通过普通 CLI 构建 rootfs/initrd/boot bundle；
- builder 不访问公网、不借用宿主发行版 userspace；
- kernel/initrd/modules 同源，vendor initrd prefix digest 不变；
- apt rootfs-build package 不操作宿主根；
- VMware Ubuntu aarch64 UEFI PXE 完整链；**已通过，并复验 tty1/SSH/systemd**
- 同一候选版本的 Rocky 回归不退化；**Rocky 9.7/10.2 已通过**

独立 QEMU launcher 和 x86_64 VMware 不再作为版本阻断闸，按统一延期清单
[`DEFERRED_DESIGN_INDEX.md`](../../design/DEFERRED_DESIGN_INDEX.md) 管理。现有
`tests/v0_2_1_ubuntu_casper_smoke.sh` 保留为实验室回归入口；它当前要求
x86_64 launcher，不能冒充本轮 aarch64 产品验证证据。

### v0.2.2

- 所有 state-file 升级 fixture 通过；
- rootfs/initrd build 不占用 management handler，restart/timeout 可恢复或确定失败；
- preview 无副作用，retry 为服务端单事务；
- readiness 可使用可信 memory inventory，unknown 仍由 initrd 硬闸；
- current CLI reference 从 command spec/实际 tree 生成；
- 当前环境必验矩阵与 workload 证据纳入发布清单；QEMU 为可选补充。

### v0.2.3

- catalog v5 Profile identity/provenance schema 直接替换（不迁移）；
- rebuild identity稳定，clone默认复用或显式换key；
- restart只重构原capability，异常进入`recovery_incomplete`；
- ISO import由daemon后台operation执行；
- exit code 0–6契约稳定；
- 当前aarch64 VMware定向回归；x86_64 VMware和重复QEMU不阻断。

### v0.3

- install-post 四类 canonical action、八步契约、credential/session 边界/finalizer、plan/status；
- `standard_packages`/`repository` 已退出；
- install-post callback 复用 BootSession credential；session/generation/plan 固定、重复事件幂等、旧 attempt、错误 plan、跨 Node、终态后事件与 daemon restart 负测通过；
- aarch64 UEFI install 与 diskless 回归不退化；
- catalog schema 保持 v5（无 schema 变更）；

### v0.4

- AppConfig v5/catalog v6 直接替换；旧 config/catalog/state/session/artifact 全部拒载，不迁移、不共存；
- BootConfig 保持 v3；全部 fresh v0.4 diskless delivery 只使用 AgentPlan v2；
- UEFI GRUB + DHCPv4 bootstrap 保持现状，支持动态 lease 或 `pxe.ip_reservation`，不新增 no-DHCP static PXE；
- target topology 与 PXE bootstrap 分离；install adapter 与 diskless `node-apply renderNetwork` 均完整渲染 interfaces/bonds/VLANs/routes/DNS，网络实际连通性不作为 first-boot 成功闸；
- nodeforged 服务端 rootfs operation、artifact 发布与恢复；
- install first-boot 一次性交换与磁盘 journal；它与 diskless node-apply、diskless systemd first-boot 的计划、凭据、存储和事件相互独立；
- 256 逻辑节点 install/diskless/mixed 波次为实现容量基线，512 为标准合成扩展，1024 为合成压力验证点而非最高上限；运行时覆盖受当前 2048 实现安全天花板约束，真实 256/512 节点生产规模验证按统一清单 `ENV-V04-PRODUCTION-SCALE` 延后；
- diskless/install first-boot 的 active authority 与复用既有状态域的 per-Node terminal summary 分离，不新增 durable domain；终态释放、非终态 reaper、同一 diskless domain 内的 AgentPlan/增量 checkpoint、HTTP/TFTP/FD 边界和 install-post retention 均通过重复波次资源测试；
- SN+IP draft Node + per-Node 短时 discovery + 现有 initrd discovery mode 上报 SN + MAC/arch 原子回填；匹配后仍不自动部署。

## 5. 变更管理

版本实现 PR 必须同时更新：

- 本路线图的状态表；
- 对应版本设计的“实现状态/完成证据”；
- 当前实现审计或新的基线审计；
- CLI reference/workflow；
- state/DTO schema fixture；
- README 文档导航。

只改代码不改状态，或只改设计不标 implemented/planned，均视为未完成。
