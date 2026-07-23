# NodeForge v0.2 Phase 1 验证记录（schema v4 基础与迁移）

> 验证日期：2026-07-23（Asia/Shanghai）。
> 验证机：`root@r97n0`，Rocky Linux 9.7 aarch64，`192.168.27.128`（`enp26s0`）。
> 本地构建机：macOS，Zig 0.16.0；交叉/本机构建均通过。

## 1. 范围

v0.2 Phase 1 = schema v4 模型基础与 v3→v4 迁移入口，对应 `V0_2_DESIGN.md` §3.1 / §6 与
`V0_2_V0_5_DESIGN_REVIEW.md` §5 的“未修复实现差距”中可独立落地的数据模型与迁移子集：

- `BootKind` 扩 `install | diskless`，新增 `ProfileKind` 别名（设计名 = 代码 `BootKind`）。
- `AssetKind` 增 `runtime_kernel`、`archive`、`script`。
- `ProvisionPhase` 增 `rootfs_build`、`first_boot`；`ProvisionAction` 增 `archive`、`script`、`package`。
- `BootBundleConfig` 增 `runtime_kernel` 引用；`ProfileConfig` 增 `kind` 与 `boot_bundle`。
- 全部 `BootKind`/`AssetKind`/`ProvisionAction` 穷举 switch 补 `diskless`/新 kind fail-closed 分支；
  `boot/resolver.zig profileMode` 改为反映 `profile.kind`（install 行为不变）。
- 新增 `src/catalog/schema_v4.zig`：`build`（v3→v4 plan，含 blockers/digest）、`candidates`
  （materialize，stamp schema_version=4 并把 Profile 显式 wrap 为 `ProfileKind.install`）、
  `downgradeBlockers`（v4→v3 representability，v0.2-only 特性返回 `migration.non_representable`）。
- 新增 operator 可用入口 `nodeforge catalog schema-v4 plan`（client + route + server handler + CLI）。
  apply/rollback 与 v4 store/DTO 待 Phase 1b（forward-migrated install-only catalog 可由 v3 DTO 表达）。

明确不在 Phase 1：diskless effective compiler、BootSession canonical 状态机、rootfs builder、
initrd/agent、rootfs/AgentPlan HTTP 路由与 scoped token、CLI 其余命令树、provision-bundle 八步。
这些属后续 Phase 2+。

## 2. 本地门槛

- `zig build` 通过（macOS Debug native）。
- `zig build test --summary all`：11/11 steps succeeded；289/289 tests passed
  （v0.1 基线 285 + 新增 4 个 schema_v4 契约测试）。

## 3. r97n0 验证

同步工作树至 `root@r97n0:/root/NodeForge/`（排除 `.zig-cache`/`zig-out`/`dist`/`.git`）后：

- `zig version` = 0.16.0；`zig build` 通过。
- `zig build test --summary all`：**11/11 steps succeeded；289/289 tests passed**
  （含 4 个 schema_v4 契约测试、`tests/cli.sh`、`tests/http.sh`、`tests/setup.sh`）。
  注：`tests/http.sh` 需 UDP 67/69 空闲，验证前临时停止 `nodeforged` 占用，验证后已恢复。

### 3.1 schema-v4 plan 端到端（新 daemon，空 catalog）

fresh setup（`--bind-interface lo --http-port 18099`）后用新二进制起 daemon：

```json
{"ok":true,"result":{"plan_digest":"fa67ee0b...","applicable":true,
 "plan":{"target_schema":4,...,"affected_profiles":[],"affected_nodes":[],"blockers":[]}}}
```

### 3.2 schema-v4 plan 端到端（生产 catalog，真实 Profile）

临时用新二进制承载 `/opt/nodeforge` 生产 config/catalog：

```json
{"ok":true,"result":{"plan_digest":"4520088b...","applicable":true,
 "plan":{"target_schema":4,"catalog_revision":73,
 "affected_profiles":["rocky-9.7-aarch64-iso","ubuntu-22.04.5-aarch64-iso"],
 "affected_nodes":["r97n1"],"blockers":[]}}}
```

证明 `schema_v4.build` 把两个 install Profile 无损 wrap 为 `ProfileKind.install`，0 blocker。
human 输出正常渲染 `Schema v4 migration plan`。

## 4. 回归

- `nodeforge catalog schema-v3 plan` 在新 daemon 与生产 catalog 上仍返回 `applicable:true` 与正确 plan_digest。
- v0.1 install Profile 的 PXE/storage/software/override 与 schema v3 migration 回归不退化（289/289）。
- 验证后将 `nodeforged` 恢复为 `active`。

## 5. 后续（Phase 1b / Phase 2）

- Phase 1b：catalog store + DTO 接受 `schema_version=4`，复用迁移事务实现 `schema-v4 apply/rollback`。
- Phase 2：diskless effective compiler（`profile_build` / `node_boot` / `node_apply` 三投影、rootfs input digest、build-safe 分类）。

## 6. Phase 2-5 进展与 rootfs 构造验证（2026-07-23 续）

在 Phase 1 基础上继续分阶段实现 diskless 服务端逻辑核心，全部经 `zig build test` 覆盖：

- **Phase 2 diskless effective compiler**（`src/profile/diskless.zig`）：`profile_build` /
  `node_boot` / `node_apply` 三投影 + `rootfs_input_digest`（Profile-only，跨 Node 共享）/
  `desired_plan_digest`（Node-specific）。契约测试证明：两 Node 同 Profile 同 rootfs digest；
  Node override（hostname/network/software）只改 desired、不改 rootfs；Profile 软件基线改
  rootfs。r97n0 验证 292/292。
- **Phase 3 canonical 状态机 reducer**（`src/state/diskless_session.zig`）：canonical
  `boot.*` / `diskless.*` phase + 唯一映射 + CAS-style 推进；拒绝跳跃/回退/终态后推进；
  重复同阶段幂等；`failed` 任一非终态可达、`expired` 仅服务端超时。7 个 §10 fail-closed 测试。
- **Phase 4 scoped credential + DTO**（`src/state/diskless_credential.zig`、
  `src/http/diskless_dto.zig`）：分域 hash-only token（config/rootfs/agent/event，scope/node/
  path/content/expiry/event_seq 绑定）+ BootConfig v2 / AgentPlan v1 DTO（render + canonical
  digest）。覆盖无效 token 不归责、越权/跨 Node/路径越界/过期/event_seq 拒绝。
- **Phase 5 rootfs builder core**（`src/provision/rootfs_build.zig`）：Artifact 记录、
  `staging->validated->ready` 状态机（已发布只增不删）、DeliveryManifest（固定 boot bundle
  revisions + rootfs SHA-512）、local-only 静态检查（拒公网 mirror/metalink/GeoIP/vendor）。
- r97n0 全量回归：**11/11 steps，310/310 tests passed**。

### 6.1 rootfs OS 层构造在 r97n0 实测通过

在 r97n0（Rocky 9.7 aarch64）用本地 ISO 仓库实测完整 rootfs 构造链路：

```bash
dnf --installroot=$T/root --releasever=9 --nogpgcheck \
    --repofrompath=rocky-minimal,file:///opt/nodeforge/assets/repos/rocky-9.7-aarch64-iso/Minimal \
    install -y filesystem coreutils bash
mksquashfs $T/root rootfs.squashfs -noappend -comp xz
```

结果：`dnf --installroot` 成功安装基础包（filesystem/coreutils/bash）到 staging root；
`mksquashfs` 产出 **19 MB 有效 SQUASHFS 4.0（xz）**，`unsquashfs -stat` 校验通过。
证明 v0.2 rootfs builder 的 OS 层执行边界在目标平台可工作。

## 7. 剩余（向可启动 diskless 端到端推进）

- Phase 6：`nodeforge-initrd` / `nodeforge-agent` 二进制（拉取 BootConfig/rootfs、
  overlay 挂载、`switch_root`、agent pre-init node-apply）——实际启动路径，需 QEMU/VMware
  迭代验证。
- Phase 7：CLI 命令树（diskless profile、rootfs plan/build/status、postprocess）。
- Phase 1b：schema-v4 apply/rollback 持久化（v4 store/DTO）。
- Phase 8：provision-bundle 八步执行契约 + event 脱敏。
- Phase 9：UEFI QEMU smoke + VMware 虚拟机（compute_use）实机 diskless 启动回归。

## 8. Phase 1b：schema-v4 apply/rollback 持久化（2026-07-23）

在 Phase 1 plan 基础上实现 schema-v4 apply/rollback，使 catalog 实际可存储 diskless
模型。catalog store/DTO/validator 全面接受 `schema_version=4`，apply/rollback 复用
`schema_v3_transaction` 的 2PC 事务机制（仅内容为 schema 4 的 catalog/config）。

### 8.1 实现

- **catalog store（`src/catalog/store.zig`）**：v4 catalog 用直接 model 序列化（与 v2
  一致），保留 v3 strict DTO 会丢弃的 diskless 字段（`kind=diskless`、`boot_bundle`、
  `rootfs_build`/`first_boot` 步骤、`runtime_kernel`/`archive`/`script` 资产）。manifest
  接受 `catalog_schema_version=4`、10 实体集；load 走 `model.Catalog` 直解析。
- **config DTO/ store/ load（`src/config/schema_v3_dto.zig` 等）**：config 形状 v3/v4
  一致，仅 `schema_version` 戳不同；`parse` 接受 3 或 4 并保留实际版本。
- **validator（`src/config/validate.zig`）**：`schema_version` 上限 `>3` -> `>4`（三处）；
  provision step 校验改为 phase-aware：`install_post` 仅 managed_file（v3+v4 一致），
  `rootfs_build`/`first_boot`（仅 v4）允许 `managed_file`/`archive`/`script`/`package`。
- **server/client/CLI**：新增 `schema-v4/migrations` + `schema-v4/rollbacks` 路由、
  `schemaV4MigrationApply/Rollback` 处理器、`schemaV4ApplyJson/RollbackJson` 客户端、
  `nodeforge catalog schema-v4 apply|rollback <plan-digest>` CLI。

### 8.2 单测（314/314，新增 4）

- `v4 catalog round-trips diskless profile, boot bundle and rootfs_build step`
  （catalog/store.zig）：diskless 字段经 save/load 不丢失。
- `schema-v4 migration commits diskless-ready catalog and rolls back to v3`
  （schema_v3_transaction.zig）：v4 经 2PC commit 持久化、rollback 恢复 v3。
- `v4 forward-migrated config and catalog pass validateModel`（validate.zig）：
  schema_version=4 不被 `UnsupportedSchemaVersion` 拒（回归 e2e 暴露的漏改）。
- `v4 startup config round-trips preserving schema_version`（config/schema_v3_dto.zig）。

### 8.3 r97n0 端到端（fresh setup，loopback daemon）

`/root/nf-v4-apply-test.sh`：fresh setup（schema 3 空 catalog）-> daemon ->

```
=== setup: config=3 catalog=3
=== plan: digest=a90598... applicable=true
=== apply: {"schema_version":4,"catalog_revision":2}
=== after apply: config=4 catalog=4 entities=10
=== re-plan on v4: applicable=true        # 证明 v4 catalog 经 daemon store 加载
=== rollback: {"rolled_back":true}
=== after rollback: config=3 catalog=3
=== PHASE 1b E2E PASS ===
```

证明 `nodeforge catalog schema-v4 plan/apply/rollback` 全链路（CLI -> 客户端 ->
server handler -> `schema_v3_transaction` commit/rollback -> catalog/config store
schema 4 持久化与加载）工作；apply 后 config.json `schema_version=4`、manifest
`catalog_schema_version=4` 且 10 实体；rollback 恢复 schema 3。生产 `nodeforged`
验证前后保持 `active`。

> e2e 暴露并修复了一个真实缺陷：`validate.zig` 三处 `schema_version > 3` 上限漏改
> （首版补丁仅应用了 phase-aware 重构，未应用上限修改），导致 apply 候选被
> `UnsupportedSchemaVersion` 拒。已补 `validateModel` v4 回归单测覆盖。
