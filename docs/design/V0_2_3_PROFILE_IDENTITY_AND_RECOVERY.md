# NodeForge v0.2.3 设计：Profile Identity 与恢复语义收口

状态：设计冻结；Batch 1–5 已实现；aarch64 VMware Rocky/Ubuntu diskless
定向回归均已通过（见 §10）
前置：v0.2.2 `dd95376`  
schema：catalog v4 → v5；BootConfig 保持 v3；AgentPlan 保持 v1

v0.2.3 是 v0.2 系列最后一个收口版本，不增加部署形态。它只关闭 v0.2.2 发布后
确认的四组真实差异：Profile identity/provenance/clone、capability restart 语义、
ISO import 后台 operation、CLI exit mapping。

当时明确暂不做项的稳定 ID 见归档
[`V0_2_POST_RELEASE_BACKLOG.md`](../archive/design/V0_2_POST_RELEASE_BACKLOG.md) §2；跨版本当前状态以
[`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md) 为唯一范围裁决源。

## 0. 基本常识

**catalog schema 版本变更采用直接替换，不实现迁移。**

这与 v0.2.0–v0.2.2 的一贯做法一致（`src/model.zig` 注释明确"不存在版本
迁移"）。具体含义：

- `model.zig` 的 **`Catalog.schema_version`** 默认值从 4 改为 5
  （`AppConfig.schema_version` 是 config.json schema，保持 4 不变）；
- `src/catalog/store.zig` 的 `manifest.catalog_schema_version != 4` 改为 `!= 5`；
- `src/config/validate.zig` 中**仅 catalog 校验**（`catalog.schema_version != 4`，
  两处）改为 `!= 5`；**config 校验**（`config.schema_version != 4`）保持不变；
- `src/setup.zig` 生成 v5 catalog（`Catalog.schema_version = 5`，
  `AppConfig.schema_version` 仍为 4）；
- 旧 v4 catalog 不被加载（`UnsupportedSchemaVersion`），操作员需重新 `setup`；
- 不新增迁移模块、不提供 `catalog migrate` 命令；
- 不需要 migration journal、backup 目录或 downgrade blockers。

后续版本（v0.3 保持 catalog v5、v0.4 v6）同样遵循此原则。schema 版本号
是代码级硬替换，不是数据级迁移。

## 1. 目标

1. Profile SSH identity 在 create 时生成并持久化，普通 rebuild 不再随机换 key；
2. Profile create/clone 有可查询 provenance、revision 和时间；
3. clone 默认复用信任域，可显式创建新 identity，并可组合提交 build；
4. capability 在 daemon restart 后只重构原 token，不生成第二 token；
5. ISO import 与 rootfs/initrd 一样由 daemon 后台 operation 执行；
6. CLI error code 与 exit class 有唯一映射入口；
7. 删除旧同步 initrd handler和与当前事实冲突的注释。

## 2. 非目标

v0.2.3 不实现：

- `V02-D01`—`V02-D03`：x86_64 VMware E2E、强制 QEMU 矩阵、Ubuntu
  rootfs 内 mkinitramfs 方案 B；
- `V02-D05`：多 NIC/topology/容量 SLO；
- `V02-D07`—`V02-D10`：Zig connect deadline、CommandSpec 自动生成、
  operation progress event、统一 `checks[]`；
- `V02-D11`—`V02-D12`：operation cancel、Profile history / `--from-revision`；
- `V02-D13`—`V02-D14`：reconciliation/远程任务/长期 enrollment，以及 IPv6、
  NFS root、iPXE。

这些项目不允许作为 v0.2.3 发布阻断项。

## 3. Catalog v5

### 3.1 Profile metadata

`ProfileConfig`（`src/model.zig`）增加以下字段。所有新增字段在 v4 Profile 中
不存在；v5 catalog 中的 Profile 必须由 create/clone 事务完整填充，由 Zig
struct 默认值保证内存安全（见 §0）。

```text
revision: u64                // Profile 级单调递增 revision，初始值 1
created_at: i64              // daemon UTC Unix seconds
updated_at: i64              // daemon UTC Unix seconds
provenance: ProfileProvenance
ssh_identity: ProfileSshIdentityRef
```

```text
ProfileProvenance = struct {
    origin: enum { create, clone },
    install_source_name: []const u8,
    install_source_revision: u64,      // 创建/克隆时 catalog revision 快照
    cloned_from: ?ClonedFrom = null,   // origin=clone 时必填
}

ClonedFrom = struct {
    profile_name: []const u8,
    profile_revision: u64,             // source Profile 的 revision 快照
    catalog_revision: u64,             // 克隆时的 catalog revision
    cloned_at: i64,                    // daemon UTC Unix seconds
}

ProfileSshIdentityRef = struct {
    id: []const u8,                    // 32 字符小写十六进制，与 identity store 主键一致
    revision: u64,                     // identity revision，--new-ssh-keys 递增
    client_public_fingerprint: []const u8,  // SHA-256 base64（SSH 标准指纹格式）
    host_public_fingerprint: []const u8,    // SHA-256 base64
}
```

**字段语义**：

- `revision`：Profile 级独立单调计数器，**不等于** catalog `revision`。每次
  Profile mutation（set/unset/clone patch/`--new-ssh-keys`）成功后递增 1，并更新
  `updated_at`。不因无关 catalog mutation（如 Node 变更、其他 Profile 变更）改变。
- `created_at`：Profile 首次创建的时间戳，创建后不可变。
- `install_source_name`：直接取自 `ProfileConfig.install_source` 字段值。
- `install_source_revision`：创建/克隆时的 catalog `revision` 快照，用于审计追溯。
- `cloned_from`：仅 `origin=clone` 时非 null。`profile_revision` 是 source Profile
  的 `revision` 快照（不是 target 的），`catalog_revision` 是克隆事务提交后的
  catalog revision。

时间使用 daemon UTC Unix seconds，由 `unixNow()` 生成（与现有 events、operations
一致）。`ProfileConfig` 的持久化序列化由 `src/catalog/store.zig` 直接对
`model.Catalog`（含 `[]const ProfileConfig`）做 `std.json.Stringify` /
`std.json.parseFromSlice` 完成——新增字段加到 `model.ProfileConfig` 后自动参与
磁盘读写，不需要单独修改 catalog 序列化路径。API 响应渲染另由
`src/catalog/dto.zig` 的 `Profile` struct 负责（`renderProfiles`），新增字段
必须同步加到该 DTO 及其 `fromProfile` 映射，否则 API 响应不包含新字段。
Zig `std.json.parseFromSlice` 默认 `.ignore_unknown_fields = true`，旧版 CLI
二进制解析新 catalog JSON 时忽略未知字段，不会报错。

### 3.2 SSH identity store

private key 不进入 catalog。daemon-owned identity store 独立持久化。

**内存形态**：`identity_store.Store` 是 `max_identities(256)` 项定长数组，每项含
4×4096B 密钥缓冲（约 4.4MB）。daemon 启动时由 `app.zig` **堆分配**（与
`runtime`/`statuses` 一致），不得放回主线程栈——macOS 主线程 8MB 栈上同时容纳
sessions/deployments/identities 三个定长 Store 会越界 SIGSEGV（`setEffective`/
`load` 阶段已实测复现并修复）。

**存储路径**：`<install-root>/state/identities.json`（`src/paths.zig` 的
`identity_store_path`，与 `diskless_secret_path`、`operations_path` 同级）。
**密钥生成/校验暂存目录**：`<install-root>/state/identity-staging`（0700，
`identity_staging_dir`）；私钥只在暂存目录出现，绝不进入 `/tmp` 或工作目录。

**文件格式**：

```text
schema_version: 1
identities[]: [
    {
        id: string                    // 32 字符小写十六进制（128-bit 安全随机）
        revision: u64                 // 单调递增，初始值 1
        created_at: i64               // daemon UTC Unix seconds
        client_private_key: string    // OpenSSH private-key 格式 ed25519 私钥
        client_public_key: string     // OpenSSH 格式公钥
        host_private_key: string      // OpenSSH private-key 格式 ed25519 私钥
        host_public_key: string       // OpenSSH 格式公钥
        client_public_fingerprint: string  // SHA-256 base64 指纹
        host_public_fingerprint: string    // SHA-256 base64 指纹
    }
]
```

identity store 的逻辑主键是 **`(id, revision)` 复合键**，不是单独的 `id`。
同一个 `id` 可以保存多个不可变 revision；同一复合键不得重复。identity 记录创建后
不可原地修改。所有读取必须同时匹配 catalog reference 中的 `id` 和 `revision`，
只按 `id` 查找属于实现错误。

**密钥类型**：ed25519（与现有 `rootfs_os_builder.zig` `generateSshKeys` 一致，
  通过 `ssh-keygen -t ed25519 -N "" -C "nodeforge-{client|host}"` 生成）。

**指纹算法**：SSH 标准 SHA-256 base64 指纹（`ssh-keygen -lf <keyfile>` 输出格式，
  即 `SHA256:<base64-encoded-sha256-of-public-key-blob>`）。catalog 和 identity
  store 中均保存完整 `SHA256:...` 前缀字符串。

**`id` 格式**：128-bit 安全随机值的小写十六进制编码（32 字符），使用
  `io.randomSecure` 生成，与 `boot_session.generateId` 和
  `diskless_delivery.generateId` 格式一致。

**并发控制**：identity store 使用 `std.atomic.Mutex` 保护所有读写（与
  `operations.Store` 模式一致；`diskless_delivery.Store` 当前无自有 mutex，
  由 handler 层 `config_mutation_mutex` 外部串行化）。持久化使用
  `identity_store.atomicWriteSecret`（临时文件**创建时即 0600**、写入、fsync、
  rename、fsync 父目录）：与 `dhcp_store.atomicWrite` 不同，私钥字节不会以默认
  umask（通常 0644）短暂暴露在磁盘上；父目录 fsync 复用
  `dhcp_store.syncParentDirectory`。

**安全要求**：

- 文件 0600、目录 0700（通过 `chmod` 子进程设置，与 `diskless_secret` 一致）；
- private key 不进入日志、Event、operation result、manifest 或公开 API；
- catalog 只保存 reference/revision/fingerprint（`ProfileSshIdentityRef`）；
- identity 文件损坏、缺失、复合键重复、`revision == 0`、fingerprint 不匹配或
  private/public key 不成对时 fail closed（`Store.load` 已实现：公钥指纹用纯
  Zig 重算比对（`server/admin_key.zig` `fingerprint`，与 `ssh-keygen -lf` 一致），
  private/public 用 `ssh-keygen -y` 派生比对，私钥写入暂存目录 0600 校验后立即
  删除；daemon 拒绝启动，与 `loadOrCreateSecret` 对 `InvalidDisklessSecret` 的
  处理一致）；
- identity 写入临时文件并 fsync/rename 后，catalog 才能引用；
- catalog publish 失败时回收尚未被引用的新 identity；
- 已被 artifact 或 Profile 引用的 identity 不自动删除；
- identity store 的通用 GC（清理历史无引用 revision）不进入 v0.2.3 完成闸；
  但当前事务失败和启动恢复必须清理该事务尚未被 catalog 引用的
  identity revision，这属于事务恢复而不是 GC。

**与现有 `diskless-secret` 的区别**：`state/diskless-secret` 存储 capability token
派生用的 32-byte master secret（HMAC-SHA256），与 SSH identity store 完全独立。
两者不可合并：capability secret 是对称密钥，SSH identity 是非对称密钥对。

### 3.3 Rootfs identity

**实现状态（2026-07-31）**：以下字段已加入 `ProfileBuildProjection`
（`src/profile/diskless.zig`），`compile` 与 `rootfsInputDigest` 两个构造点
同步填入，保证 digest 一致性；identity 变更（`--new-ssh-keys`）会产出新的
`rootfs_input_digest`，不会命中旧缓存：

`ProfileBuildProjection`（`src/profile/diskless.zig`）增加 Profile/identity 字段：

```text
ProfileBuildProjection 增加字段：
    profile_revision: u64
    ssh_identity_id: []const u8
    ssh_identity_revision: u64
    client_public_fingerprint: []const u8
    host_public_fingerprint: []const u8
```

`digestOf` 函数对 `ProfileBuildProjection` 做 JSON 序列化后 SHA-256，新增字段
自动参与摘要计算（Zig `std.json.Stringify` 序列化整个 struct）。因此相同
Profile revision + identity revision + 其他输入必然得到相同 `rootfs_input_digest`。

**注意**：`ProfileBuildProjection` 在 `src/profile/diskless.zig` 中有两个构造点
（`compile` 函数和 `rootfsInputDigest` 函数），两处均需添加新字段，否则
`rootfsInputDigest` 独立计算的 digest 与 `compile` 产出的不一致。

**rootfs build 执行变更**：

现有 `rootfs_os_builder.zig` 的 `generateSshKeys` 在 staging 中调用 `ssh-keygen`
生成新密钥。v0.2.3 改为：

1. 从 identity store 按 `(ssh_identity.id, ssh_identity.revision)` 复合键读取记录；
2. 将 `client_private_key`、`client_public_key` 写入 staging
   `/root/.ssh/id_ed25519{,.pub}`；
3. 将 `host_private_key`、`host_public_key` 写入 staging
   `/etc/ssh/ssh_host_ed25519_key{,.pub}`；
4. 从 identity store 的 public key 生成 `authorized_keys` 和 `ssh_known_hosts`
   （与现有 `generateSshKeys` 步骤 3/4 逻辑一致，但密钥来源从 ssh-keygen 改为
   identity store 读取）；
5. 文件权限保持不变（私钥 0600、公钥 0644、.ssh 目录 0700）。

不再在 build 期间调用 `ssh-keygen` 生成普通构建 identity。

**实现状态（2026-07-31）**：`installIdentityKeys` 已实现于
`src/provision/rootfs_os_builder.zig`（`buildOsLayer` 的 `buildDnf` 与
`buildCasperOverlay` 两分支均注入 `identities` + `profile`）：按
`(ssh_identity.id, revision)` 复合键从 store 读取 client/host keypair 写入
staging，`authorized_keys`/`ssh_known_hosts` 保留 ssh-keygen `.pub` 文件的
尾随换行语义（与旧 `generateSshKeys` 字节级一致），未命中返回
`IdentityNotFound` fail closed，构建期不再调用 `ssh-keygen`。`performRootfsBuild`
的旧 Stage 5 `ssh-keygen` 路径已删除，仅保留阶段日志。
`--new-ssh-keys` 操作序列已接入 `managementRootfsBuild`（`createRevision` →
`rotateSshIdentity` → `commit` → `applyCatalogFromDisk`），失败边界按上表返回
`identity.create_failed`/`catalog.publish_failed`/`rootfs.build_submit_failed`。

**`--new-ssh-keys` 操作序列**（`profile rootfs build --new-ssh-keys`）：

1. 在 identity store 中创建新 identity revision（同 `id`，`revision + 1`，旧
   revision 保持不可变，供共享该 revision 的 clone 或旧 artifact 使用）；
2. 发布 Profile revision（`ssh_identity.revision` 递增，`updated_at` 更新）；
3. 提交 rootfs build operation（使用新 identity revision 的
   `ProfileBuildProjection`）。

**失败边界**：每步失败必须在 HTTP 响应中区分，返回稳定 error code：

| 失败阶段 | error code | 含义 |
|---|---|---|
| identity 创建失败 | `identity.create_failed` | identity/Profile 均未发布 |
| Profile 发布失败 | `catalog.publish_failed` | identity 已写入但 catalog 未发布；事务恢复立即回收该 revision |
| journal 收尾失败 | `identity.commit_failed` | Profile 与 identity 均已发布；保留 journal，启动恢复只做提交收尾 |
| build operation 提交失败 | `rootfs.build_submit_failed` | Profile 已发布（含新 identity revision），但 build 未提交 |

`--new-ssh-keys` 失败后 Profile revision 已递增但 rootfs 尚未重建。旧 rootfs
artifact 仍可消费（digest 不匹配，走重建路径）。这等价于"先改 Profile 再 build"
的普通序列，不是半成品状态。

### 3.4 Profile `revision` 与 catalog `revision`

两者完全独立：

- catalog `revision`（`Catalog.revision`）：manifest 级单调计数器，每次任意
  catalog 事务（Node/Profile/Asset 变更）提交时递增。
- Profile `revision`（`ProfileConfig.revision`）：Profile 级单调计数器，仅当
  该 Profile 自身 mutation 成功时递增。

`rootfs_input_digest` 包含 Profile `revision` 和 identity `revision`，但不包含
catalog `revision`。因此其他 Profile 或 Node 的变更不会导致本 Profile rootfs
缓存失效。

## 4. Schema 替换与事务恢复

### 4.1 直接替换（不迁移）

catalog schema 从 v4 到 v5 采用直接替换，不实现迁移。完整规则见 §0。

**旧 rootfs artifact 边界**：旧 v4 rootfs artifact 仍可供既有 immutable session
使用（active session 不重编译），但不视为 v5 Profile 当前缓存。首次 v5 rootfs
build 产生包含 identity fingerprint 的新 `rootfs_input_digest`，与旧 digest
不同。`rootfs_artifact_store` 按 digest 查找，自然不会命中旧 artifact。

### 4.2 identity + catalog 两阶段发布与崩溃恢复

identity store 与 catalog 是两个文件，单次 rename 不能让它们整体原子。create、
clone `--new-ssh-keys` 和 rootfs build `--new-ssh-keys` 操作需要同时发布
identity store 和 catalog。本文所称"原子发布"统一指以下可恢复两阶段协议，
不得实现成无 journal 的两次独立写入：

1. 在 `state/identity-transactions/<transaction_id>.json` 原子写入 `prepared`
   journal，记录旧 catalog revision、待增加的 `(id, revision)` 和目标 Profile；
2. 原子发布包含新 immutable revision 的 `identities.json`；
3. 原子发布引用该复合键的 catalog；
4. 删除 journal 作为 committed 标记，并 fsync 父目录；删除或 fsync 失败必须
   显式返回 `identity.commit_failed`，不得吞掉错误。

daemon 启动时必须在接受管理请求前恢复未完成 journal：

- catalog 已引用目标复合键：确认 identity 存在且 fingerprint 匹配，然后完成提交；
- catalog 未引用目标复合键：从 identity store 删除该事务新增 revision 并回滚；
- catalog 已引用但 identity 缺失或不匹配：fail closed，禁止自动生成替代密钥。

"identity-first"允许崩溃窗口中短暂存在不可见 orphan，但启动恢复后不得残留。

**实现状态（2026-07-31）**：§4.2 协议文本不变；journal 基建已实现于
`src/state/identity_store.zig`：`prepare`/`commit`/`rollback`（含幂等回滚）与
`recoverPendingTransactions`（catalog 已引用且指纹匹配 → 收尾提交；未引用 →
幂等回滚；已引用但缺失/不匹配 → `IdentityRecoveryFailed` fail closed）。
`create`/`createRevision` 支持 `IdentityTx` 可选参数：prepared journal 在新
记录持久化前写入，符合"journal 先于 identity 发布"的顺序。`daemon 启动序列`
已完成：`app.zig` 在 serve 前加载 identity store（fail closed）、mkdir
`identity-staging`/`identity-transactions` 0700、并调用
`recoverPendingTransactions`（失败拒启）。Batch 3 的
create/clone/`--new-ssh-keys` 生产者接线（调用 `create(…, &tx)` → catalog
save → `commit`/`rollback`）已完成：`managementProfileCreate`、
`managementProfileClone`（`--new-ssh-keys`）与 `managementRootfsBuild`
（`--new-ssh-keys` 轮换）均在 handler 内 `create`/`createRevision`(…, `&tx`) →
发布 catalog → 解除 rollback → `commit`。只有 catalog 尚未持久化时才允许
`errdefer` 幂等 rollback；catalog 已持久化后即使 journal 删除失败也必须保留
identity 与 journal，交给启动恢复按 catalog 引用收尾，禁止删除已被引用的
identity。`commit`/恢复删除 journal 后均 fsync 父目录。

identity 消费端不持有解锁后的 Store 内部槽位指针：`Store.copy` 在 mutex 内把
完整 `IdentityRecord` 复制到调用方缓冲，避免并发 rollback 的 swap-remove 使
rootfs build 或恢复校验观察到被移动/清零的记录。

### 4.3 fixture 要求

fixture 必须覆盖：

- identity 文件损坏（手动篡改 identity store）→ daemon 拒绝启动；
- 两阶段发布在 prepared 后、identity publish 后、catalog publish 后分别崩溃，
  restart 均按 §4.2 得到确定结果。

## 5. Profile create 与 clone

### 5.1 Create

`profile create` 在 daemon 事务中（`managementProfileCreate` handler，
`src/http/server.zig`）：

1. 验证 install source 存在（catalog 中查找）与目标名合法；
2. 创建 identity（`ssh-keygen -t ed25519`，写入 identity store）；
3. 创建 provenance（`origin = .create`，`install_source_name` 来自参数，
   `install_source_revision` = 当前 catalog revision）；
4. 设置 `revision = 1`，`created_at = updated_at = unixNow()`；
5. 校验候选 catalog（`config_validate.validate`）；
6. 按 §4.2 两阶段协议发布 identity store + catalog。

不能创建"有 Profile、无 identity"的半成品。identity 写入失败则 Profile 不创建。

**API 响应变更**：现有 `ProfileCreateRequest` 不变（不需要客户端传 identity
信息）。响应 JSON 增加 `revision`、`provenance` 和 `ssh_identity` 字段。

**实现状态（2026-07-31）**：`managementProfileCreate` 已按上述序列接线
（`create(…, &tx)` → `addInstallProfile` → 解除 rollback → `commit` →
`applyCatalogFromDisk`；仅 catalog 落盘前失败才幂等 rollback），错误码按 §3.3 表返回
`identity.create_failed`/`identity.capacity`/`identity.staging_unset`；
`addInstallProfile` 增加 `ssh_identity` 参数并初始化 `revision = 1` + 时间戳 +
provenance，响应含 `revision`、`provenance`、`ssh_identity`。

### 5.2 Clone

**CLI 接口**（`src/main.zig` `profileCloneHandler`）：

现有 `profile clone <source> <target>` 命令已注册。v0.2.3 扩展为：

```text
profile clone SOURCE TARGET [KEY=VALUE...]
  [--new-ssh-keys]
  [--build]
  [--detach]
```

新增 flags：
- `--new-ssh-keys`：创建独立 identity（不复用 source）；
- `--build`：clone 完成后提交 rootfs build operation（仅 diskless Profile 有意义）；
- `--detach`：与 `--build` 同用时立即返回 operation id，不 follow。单独使用
  无效（返回 exit code 2）。

**property patch 语义**：`[KEY=VALUE...]` 是可选的 `key=value` 对，与
  `profile set` 命令使用相同的解析路径（`cli_properties` 模块）。patch 与 clone
  在同一 catalog 事务中校验和提交。可 patch 的字段范围与 `profile set` 相同；
  不允许 patch `provenance`、`revision`、`ssh_identity`（这些由 clone 事务
  自动设置）。

**API 端点**：`POST /api/v1/management/profiles/<source>/clone`，请求体：

```json
{
    "target": "<target-name>",
    "new_ssh_keys": false,
    "build": false,
    "detach": false,
    "properties": {"key": "value", ...}
}
```

**clone 语义**：

- 深拷贝 desired configuration（`system`、`software`、`install`、`kernel_args`、
  `diskless`、`boot_bundle`、`bundle`）；
- 不复制 runtime、session、operation、artifact current pointer；
- 默认复用 source identity（`ssh_identity.id` 相同，`revision` 相同）；
- `--new-ssh-keys` 创建独立 identity（新 `id`，`revision = 1`）；
- property patch 与 clone 在同一 catalog 事务校验；
- provenance 记录 source Profile `revision` 和 clone 时 catalog `revision`：
  - `origin = .clone`；
  - `install_source_name`：从 source Profile 的 `install_source` 复制；
  - `install_source_revision`：clone 时 catalog revision；
  - `cloned_from.profile_name`：source Profile name；
  - `cloned_from.profile_revision`：source Profile 的 `revision`；
  - `cloned_from.catalog_revision`：clone 事务提交后的 catalog revision；
  - `cloned_from.cloned_at`：`unixNow()`；
- `revision = 1`，`created_at = updated_at = unixNow()`；
- `--detach` 只有与 `--build` 同用时有效；单独 `--detach` 返回 exit code 2；
- clone 事务先完成（catalog 发布），随后提交 build operation；
- build 提交失败不能回滚已成功 clone，响应必须返回
  `profile_created=true`、`build_submitted=false` 和稳定 error code
  （`rootfs.build_submit_failed`）。

**install vs diskless clone**：

| 项 | install Profile | diskless Profile |
|---|---|---|
| `--build` | 无效（返回 exit code 2） | 提交 rootfs build operation |
| identity 复用 | 可复用（但 install Profile 不烤入 rootfs） | 可复用（烤入 rootfs lower） |
| `--new-ssh-keys` | 创建新 identity，但不触发 build | 创建新 identity，可配合 `--build` |

install Profile 的 SSH identity 仅用于 catalog 审计和未来 install-side agent
（v0.4）；v0.2.3 中 install Profile 的 identity 不影响 install 行为。

**target name 校验**：与 `profile create` 相同，使用
  `config_validate.validLogicalId`。

**实现状态（2026-07-31）**：`profile clone` 已支持 `--new-ssh-keys`：
`cloneProfile` 增加 `ssh_identity_override` 参数（null 复用 source 引用，
非 null 替换为新引用），`managementProfileClone` 先 `create(…, &tx)` 再克隆、
失败回滚；target 深拷贝 desired 配置，`revision = 1` + 时间戳 + provenance
（`cloned_from` 记录 source revision 与 clone 时 catalog revision）。
`--build`/`--detach` 与 `[KEY=VALUE...]` property patch 已落地：

- CLI：`profileCloneHandler` 用 `cli_properties` 解析 patch（范围与
  `profile set` 相同；集合键与不可 patch 键在连接 daemon 前以 exit 2 拒绝；
  `--detach` 单独使用 exit 2）；`--build` 仅 diskless source 有效；
- API：`ProfileCloneRequest` 携带 `build`/`detach`/`properties`（对象）；
  daemon 在 clone 事务内应用 patch（`cloneProfile` 复用
  `scalar_mutation.applyProfile`，任一校验失败整体回滚）；
- build 提交：clone 发布后 `beginQueuedRequest`→`saveOperations`→
  `rootfs_worker.submit`；缓存命中返回 `state=already_present`（不建
  operation）；提交失败返回 `rootfs.build_submit_failed` +
  `profile_created=true, build_submitted=false`（exit 5，不回滚 clone）；
- 客户端：`profileClone` 在 `--build` 且非 detach 时以响应体 `operation.id`
  为路由轮询到终态（4 小时上限；`operation` 缺省即 already_present 缓存命中，
  不建轮询），终态失败按 operation error code 映射 exit 5。

### 5.3 clone 链深度

provenance 只记录直接 source（`cloned_from`），不递归追溯。多次 clone
（A → B → C）后，C 的 `cloned_from.profile_name = "B"`，不记录 A。这是有意
设计：完整 clone 链可通过 catalog revision 历史审计（`V02-D12` Profile history
未排期，不进入 v0.2.3），但运行时不需要递归 provenance。

### 5.4 Profile revision 的统一 mutation 入口

Profile revision 不能只在 create/clone 接线。新增统一
`mutateProfileMetadata(candidate, profile_name, now)` helper，在候选 catalog
校验通过、持久化提交前执行：

- `revision = revision + 1`（溢出时事务失败）；
- `updated_at = now`；
- `created_at`、`provenance` 保持不变，除非操作本身是 create/clone；
- identity rotation 同时更新 `ssh_identity` reference。

以下所有现有入口必须通过该 helper，禁止 handler 各自递增：

- scalar `profile set` / `profile unset`；
- collection add/remove/replace；
- item add/set/remove；
- boot bundle、bundle、system/software/install/diskless/kernel args 的 mutation；
- clone property patch（target 初始 revision 仍为 1，不执行额外递增）；
- `--new-ssh-keys`。

create 和 clone 创建 target 时直接初始化为 revision 1。失败或 no-op mutation 不递增。
Batch 2 增加扫描/契约测试：对所有公开 Profile mutation 命令逐一断言“成功恰好 +1，
失败/no-op +0”，避免新增入口绕过 helper。

**实现状态（2026-07-31）**：`mutateProfileMetadata` 已实现于
`src/config/profile_mutation.zig`（溢出返回 `ProfileRevisionOverflow`，profile
不存在返回 `ProfileNotFound`，均不递增），并已接入：

- scalar `profile set`/`unset`（`scalar_mutation.profileBatch`）；
- collection values（`value_mutation.profile`）；
- item add/set/remove/replace（`item_mutation.profile`/`profileUserValues`/
  `replaceProfile`）；
- kernel args（`profile_mutation.setKernelArgs`）。

create（`addInstallProfile`）与 clone（`cloneProfile`）直接初始化 target
`revision = 1` + 时间戳 + provenance（create/clone 语义，不经过 helper）。
已全部落地：daemon 侧 `managementProfileCreate`/`managementProfileClone`/
`managementRootfsBuild --new-ssh-keys` 均通过 helper 或 §5.1/§5.2 语义接线；
CLI 级扫描契约测试位于 `src/config/revision_scan.zig`，对每个公开 Profile
mutation 入口断言"成功恰好 +1、失败/no-op +0"（含 scalar set/unset、collection
values、item add/replace、user values、kernel args、identity rotation 与 clone
target revision=1 / source 不递增），避免新增入口绕过 helper。

## 6. Capability restart 语义

### 6.1 裁决

v0.2.3 正式采用"确定性重构原 token"。

当前代码（`src/state/diskless_delivery.zig`）已经实现了确定性派生：
- `deriveToken(secret, session_id, kind, destination)`：HMAC-SHA256，
  domain separator `"nodeforge-diskless-capability-v1\x00"` + session_id +
  scope tag，输出 64 字符十六进制；
- `reconstructAndVerifyRaw(secret, session, kind)`：重启后用相同输入重构
  raw token，与持久化 hash 比对验证。

v0.2.3 不改变派生算法，只冻结语义并修正文档/注释。

### 6.2 冻结规则

- raw token 永不持久化（内存和 checkpoint 只存 `cred.hashOf(raw, secret)`）；
- daemon 使用持久 master secret（`state/diskless-secret`，32-byte）+ session_id
  + scope 确定性派生；
- 持久 hash（`cred.hashOf`，HMAC-SHA256）用于验证重构结果；
- restart 前后得到同一个 token，不签发第二 token；
- scope、node、path、content digest、event sequence 和 expiry 保持原 claim；
- terminal/cancel/expiry 持久撤销全部 scope，重启后不得恢复；
- master secret 变化或 hash 不匹配时 session 进入 `recovery_incomplete`；
- checkpoint 损坏时 fail closed（daemon 拒绝启动，与
  `InvalidDisklessSecret` 处理一致）；
- 未认证请求不得推进 session 或消耗 victim failure budget。

因此，"仅因 token 尚未完整交付就一律 `recovery_incomplete`"不再是现行规则。
`recovery_incomplete` 专用于无法安全重构同一 capability 的情况。

实现上给内存 `Session` 增加非持久字段 `recovery_incomplete: bool = false`。
restore 对每个非 terminal session 分别重构四个 scope：任一重构 token 与其合法
长度 hash 不匹配时，不恢复任何 scope、清零已重构 raw bytes并设置该标志；其他
session 继续加载。JSON 结构错误、字段越界、非法 scope/claim 或无法解析的 checkpoint
仍视为 store 损坏并拒绝 daemon 启动。这样“密钥不匹配导致单 session 安全失效”和
“持久文件结构损坏导致全局 fail closed”具有确定边界。

### 6.3 terminal 撤销恢复

**历史事实与收口变更**：`diskless_delivery` checkpoint 原为 schema v2；v2 将生命周期时间字段
从 schema v1 的 `created_at`/`started_at` 重命名为 canonical 任务列名
`armed_at`/`install_at`（代码注释："schema 2 renamed lifecycle timestamps
to their canonical task-column names"）。diskless Session
没有独立 `terminal_reason`，终态由已经持久化的 canonical `phase` 表达：
`diskless_running`、`failed`、`expired` 均满足 `phase.isTerminal()`。

终态恢复缺口与 claim 完整性缺口一并收口：v0.2.3 将 writer 升为 schema v3，改为：

1. checkpoint schema 直接替换为 v3；reader 只接受 v3，v1/v2 一律
   `InvalidDisklessDeliveryStore` 拒载，不迁移、不降级；
2. restore 得到 terminal phase 时保留 session 长期状态投影，但不重构四类 raw token；
3. terminal session 的四个 slot 在内存中保持不可认证，任何 capability 请求均拒绝；
4. 非 terminal 且未过期 session 才执行确定性重构和 hash 验证。
5. schema v3 的每个 slot 强制携带 claim MAC，缺失/非法/不匹配均 fail closed。

schema v3 只增加 claim 完整性字段，不新增 terminal reason；若未来需要记录比
canonical phase 更细的终止原因，应再升级 schema，不得复用 v3。

安装（install）session 使用 `boot_session.Store`，其 capability 是安全随机
token（`generateCapability`），不是确定性派生的。install session 的 terminal
状态当前由 `boot_session_store` 的 checkpoint 处理（`record.phase` 和
`record.capability` 已持久化）。v0.2.3 不改变 install session 的 restart 语义：
install session 在 daemon restart 后**从 checkpoint 直接恢复**（`boot_session_store.load`
只恢复 install 模式 session，要求 `deployment_generation != 0` 且与 deployment-control
的 `currentGeneration()` + `requested_plan_digest` 交叉校验通过；若
`install_plan_json` 非空则额外校验其 SHA-256 与持久 `install_plan_digest` 匹配），
其 capability 不走 §6.1–6.2 的确定性重构路径。diskless 模式 session 不恢复
（`boot_session_store.load` 跳过 `record.mode != .install`）。

### 6.4 `recovery_incomplete` 退出条件

session 进入 `recovery_incomplete` 后：
- 该 session 的全部 scope 不可用（HTTP 请求返回 `capability.recovery_incomplete`）；
- 不可自动恢复（需新 boot session 重新走 bootstrap 认证）；
- session 按 TTL 自然过期后槽位回收。

`recovery_incomplete` 不改变持久化 canonical phase（它是运行时恢复状态，不是
审计终态）。session 过期或被 supersede 后按现有状态机进入 terminal phase。

### 6.5 负测覆盖

- config/rootfs/agent/event 四 scope restart 后 token 一致性；
- 交付前（`issued=false`）、Range 传输中（`issued=true`，content 不完整）、
  完整交付后 restart；
- master secret 变化 → `recovery_incomplete`；
- 合法长度 token hash 内容不匹配 → 该 session `recovery_incomplete`；
- claim 或 session id 单独篡改 → claim MAC 不匹配、fail closed；
- hash/claim/JSON 长度或结构非法 → fail closed；
- path/content/scope/node/replay 不匹配 → `ProofMismatch`；
- terminal/cancel/expiry 后 restart → session 不恢复 capability；
- 外部无效 token 洪泛不改变目标 session（`verify` 返回 `invalid`，不消耗
  session 状态）。

checkpoint schema v3 为每个 slot 强制持久化 `claim_mac`：使用 diskless master secret 对
session id、node、plan/rootfs digest、slot kind、scope、content digest、event
sequence、token hash、issued 与 expiry 的长度前缀 canonical 编码做 HMAC-SHA256。
恢复顺序先重构 token：合法长度 token hash 不匹配按 §6.2 进入该 session 的
`recovery_incomplete`；token 可重构时再验证 claim MAC，任何 claim/session 字段
变化均返回 `InvalidDisklessDeliveryStore`。v3 缺少 MAC、MAC 长度非法或 MAC
不匹配均直接拒载；v1/v2 也直接拒载，不能通过修改 schema 或删除字段进入兼容
路径。terminal
session 不恢复 capability，也不依赖 claim 授权，仍按 §6.3 只保留长期状态投影。

**实现状态（2026-07-31）**：已新增两条 §6.3 语义冻结负测
（`src/state/diskless_delivery.zig`）：
- terminal session 的 slot hash 内容被篡改（长度仍为 64）→ load 成功、投影
  保留、四 scope verify 全部 `invalid_token`；
- terminal session 的 slot hash 长度非法 → `InvalidDisklessDeliveryStore`、
  daemon 拒启。
- non-terminal session 的 scope claim 被改且 token hash 未变 → claim MAC 校验
  失败、`InvalidDisklessDeliveryStore`、daemon 拒启。
- schema v3 任一 slot 的 claim MAC 缺失 → `InvalidDisklessDeliveryStore`；v1/v2
  checkpoint → 直接替换拒载，不执行迁移。

## 7. ISO import durable worker

### 7.1 当前实现

`src/http/server.zig` 的 ISO import handler（`managementAssetImport`）当前：

1. 创建 durable operation 记录（`operations.Store.begin`）；
2. 使用 `iso_import_mutex`（单并发互斥）；
3. `std.Thread.spawn` 启动 worker 线程执行 `runIsoImport`；
4. `worker.join()` 同步等待结果；
5. 在同一线程内完成 catalog 发布和 operation 终态写入。

从调用方（HTTP handler）视角，ISO import 是同步的：HTTP 请求在 worker.join()
期间阻塞，直到 import 完成或失败。

### 7.2 目标模型

ISO import 改为 daemon-owned 后台 operation，与当前已经完成的 rootfs/initrd
builder 一致：

```text
HTTP validate/snapshot
  -> persist queued operation
  -> return operation id to caller (HTTP 202)
  -> bounded daemon worker picks up queued operation
  -> running
  -> validate/publish
  -> succeeded | failed
```

**关键变更**：

- handler 不 `spawn` 后 `join`；持久化 queued operation 后立即返回；
- 默认 CLI follow（`operation follow`）；`--detach` 立即返回 operation id
  （仅 initrd/rootfs build 提供，ISO import CLI 保持默认 follow，见 §7.6）；
- CLI timeout 不取消 operation（operation 由 daemon 持有，与 CLI 进程解耦）；
- daemon restart 将 queued/running 确定转为 `operation.interrupted`
  （`operations.Store.load` 已实现此逻辑：running → failed +
  `operation.interrupted`）；
- staging/.part 由 operation id 独占（路径包含 operation id，与 rootfs
  `.part-<operation_id>` 模式一致）；
- digest、repository index、catalog 校验全部成功后原子发布；
- 失败、restart 和 catalog 冲突不留下公开幽灵 artifact
  （`cleanupPublishedOutputs` 在 worker 失败路径调用）；
- 同 idempotency key 复用原 operation，不重复导入（`beginRequest` 已实现）。

### 7.3 worker 模型

当前 daemon 启动时已经分别 spawn `RootfsBuildWorker` 和 `InitrdBuildWorker`；
对应 handler 已提交 queued operation 后返回，CLI 已支持默认 follow 和
`--detach`。v0.2.3 不重写这两条已完成产品路径，也不把三个 worker 合并成一个
全局串行 worker。

新增独立 `IsoImportWorker`，复用现有 worker 的生命周期和 operation 状态转换模式：

- daemon 启动时 spawn 一个 ISO worker，停止时 join；
- ISO handler 完成输入校验、request digest 和 queued operation 持久化后 submit；
- worker 内保持 ISO 单并发，替代 handler 级 `iso_import_mutex`；
- rootfs、initrd、ISO 三类任务可以彼此并行，各自队列有固定容量；
- catalog/state 发布仍通过现有 model gate、catalog lock 和 operation-store mutex
  串行化，不因 worker 并行绕过；
- daemon restart 对 queued/running operation 统一持久化为 interrupted，不自动重跑。

本批次只允许抽取无行为变化的共用 helper；不得借 ISO 后台化改变 rootfs/initrd
队列容量、并发语义、HTTP/CLI 契约或 artifact digest。

### 7.4 staging 清理

- staging 目录：`<install-root>/work/iso-import-<operation_id>/`；
- worker 成功后删除 staging（defer `removeTreeBestEffort`，与现有逻辑一致）；
- worker 失败后删除 staging + 调用 `cleanupPublishedOutputs`（与现有逻辑一致）；
- daemon restart 后发现 orphan staging（operation 已 interrupted）：启动时扫描
  `work/` 目录，删除所有 `iso-import-*` 子目录。

### 7.5 并发限制

- 同一时刻最多一个 ISO import operation（`iso_import_mutex` 语义保留，但从
  handler 级移到 worker 级）；
- 同 idempotency key 的重复请求复用已有 operation（`beginQueuedRequest`
  已实现）；
- 不提供通用 cancel（`V02-D11`）。

### 7.6 实现核对（v0.2.3 收口）

- `IsoImportWorker`（`src/http/server.zig`）：队列容量 1，daemon 启动时 spawn、
  停止时 join，替代 handler 级 `iso_import_mutex`（该全局互斥已删除）；
- handler `importInstallSource` 改为 `beginQueuedRequest` → submit → 202；
  submit 失败（队列已满）保持 409 `install_source.busy` 语义，并把刚创建的
  queued operation 落为 `install_source.busy` 失败态（§8.3 映射 exit 3）；
- `runIsoImportWorker`/`performIsoImport` 在 worker 线程内完成
  `importMedia` → repository index blob → `publishInstallSource`；
  发布失败调用 `cleanupPublishedOutputs`，importMedia 内部 defer 清理 staging；
- staging 按 §7.4 命名 `work/iso-import-<operation_id>`
  （`importMedia` 新增 `work_tag` 参数，由 worker 传入 operation id）；
  启动时 `iso_import.cleanupOrphanStaging` 扫描 `work/` 删除 `iso-import-*`
  孤儿目录（先收集名称再删除，避免迭代期间变更目录）；
- restart→interrupted 由 `operations.load` 既有逻辑保证（queued/running →
  failed + `operation.interrupted`），不自动重跑；
- CLI 侧 `importInstallSource` 保持默认 follow 语义不变，轮询预算与 rootfs
  build 对齐（4 小时）；未引入 `--detach`（不在 Batch 4 范围，避免改变
  CLI 契约）。worker 队列容量/HTTP/CLI 契约均未改变。

## 8. CLI exit mapping

### 8.1 冻结 exit class

| code | 类别 | 说明 |
|---:|---|---|
| 0 | 成功 | 命令成功完成 |
| 1 | 本地数据、协议或未知产品错误 | daemon 返回的业务错误、JSON 解析失败、未知内部错误 |
| 2 | CLI 输入错误 | 参数缺失、格式错误、无效选项值 |
| 3 | revision/idempotency 并发冲突 | `If-Match` 不匹配、idempotency key 冲突 |
| 4 | readiness 或前置条件不满足 | Profile 不是 diskless、install source 不存在、rootfs digest drift |
| 5 | durable operation 失败 | operation 终态 failed/interrupted，或复合命令在前序 mutation 已提交后无法提交后续 operation |
| 6 | daemon 不可达或等待超时 | 连接拒绝、HTTP timeout、operation follow 超时 |

### 8.2 当前状态

已实现（v0.2.3 收口）。当前代码（`src/main.zig`）已使用全部冻结 exit class
0/1/2/3/4/5/6：

| 现有 exit code | 使用场景 | 对应冻结类别 |
|---:|---|---|
| 0 | 命令成功 | ✅ 一致 |
| 1 | daemon 返回未知业务错误、JSON 解析失败、本地数据/协议错误 | ✅ 一致 |
| 2 | CLI 参数错误、`validLogicalId` 失败、无效 flag 值 | ✅ 一致 |
| 3 | revision/idempotency 冲突（`catalog.revision_conflict`、`install_source.busy` 等，§8.3 表） | ✅ 已实现 |
| 4 | readiness/前置条件（`profile.not_diskless`、`rootfs.digest_drift`、404 等，§8.3 表） | ✅ 已实现 |
| 5 | `operation follow` 终态为 failed | ✅ 一致 |
| 6 | daemon 不可达、operation follow 超时 | ✅ 一致 |

连接失败（`Mutation.reachable=false`）在 `reportMutationFailure` 中统一归为
exit 6，不再落入默认 exit 1。`itemValuesHandler` 与 `reportMutationFailure`
共用同一映射函数，避免同一 error.code 映射到不同 exit class。

### 8.3 API error.code → exit class 映射

已实现：唯一映射函数 `mapErrorToExitCode(http_status, error_code) -> u8`
位于 `src/main.zig`（`reportMutationFailure` 旁），替代了硬编码 exit code 1；
`src/http/client.zig` 的 `Mutation` 结构新增 `http_status`/`error_code` 字段，
`managementMutation` 从统一错误信封提取稳定 `error.code` 并随响应返回。

**HTTP status 映射**：

| HTTP status | exit code | 说明 |
|---:|---:|---|
| 200/201 | 0 | 成功 |
| 400 | 2 或 4 | 输入格式错误 → 2；前置条件不满足 → 4（按 error.code 区分） |
| 404 | 4 | 资源不存在（install source、profile 等） |
| 409 | 3 或 4 | revision 冲突 → 3；digest drift → 4 |
| 422 | 4 | 校验失败（readiness 前置条件） |
| 428 | 3 | 缺少 If-Match 头（`http.precondition_required`） |
| 500/502/503 | 1 | daemon 内部错误 |
| 连接失败/超时 | 6 | daemon 不可达 |

**error.code → exit class 映射**（部分关键 code）：

| error.code | exit code | 说明 |
|---|---:|---|
| `profile.invalid` | 2 | CLI 输入错误 |
| `profile.already_exists` | 3 | 并发冲突 |
| `profile.in_use` | 4 | 前置条件不满足 |
| `profile.not_diskless` | 4 | 前置条件不满足 |
| `profile.boot_bundle_required` | 2 | CLI 输入错误 |
| `profile.install_source_not_found` | 4 | 前置条件不满足 |
| `profile.clone_invalid` | 2 | CLI 输入错误 |
| `rootfs.invalid` | 2 | CLI 输入错误 |
| `rootfs.digest_drift` | 4 | 前置条件不满足 |
| `rootfs.build_failed` | 5 | operation 终态失败 |
| `rootfs.build_submit_failed` | 5 | clone 已提交后的后续 operation 提交失败（复合部分成功） |
| `rootfs.queue_unavailable` | 1 | 独立 build 请求尚未提交任何 mutation/operation |
| `identity.create_failed` | 1 | daemon 内部错误 |
| `catalog.publish_failed` | 1 | daemon 内部错误 |
| `install_source.busy` | 3 | 并发冲突 |
| `install_source.name_conflict` | 3 | 并发冲突 |
| `catalog.revision_conflict` | 3 | revision 冲突 |
| `http.precondition_required` | 3 | 缺少 If-Match 头（HTTP 428） |
| `operation.interrupted` | 5 | daemon restart 导致 operation 失败 |

handler 不得自行把同一 error.code 映射到不同 exit class。

落地核对：`mapErrorToExitCode` 纯函数单测（`zig build test`）覆盖上表每个
exit class 至少一个 case；连接失败 → 6 由 `reportMutationFailure` 的
`reachable=false` 分支保证。exit 3/4 的端到端契约由 daemon 在线的
`tests/http.sh` 体系覆盖（macOS 主机跳过，Linux 回归执行）。

### 8.4 复合错误处理

clone + build 组合操作的 exit code：

| 场景 | exit code | JSON result |
|---|---:|---|
| clone 成功 + build 成功 | 0 | `profile_created=true, build_submitted=true` |
| clone 成功 + build 提交失败 | 5 | `profile_created=true, build_submitted=false, error.code=rootfs.build_submit_failed` |
| clone 失败 | 1/2/3/4 | `profile_created=false, build_submitted=false`（按 clone 错误类型映射） |

compound 错误时 JSON stdout 保持单一文档（`{"ok":false,"error":{...},
"result":{"profile_created":true,"build_submitted":false}}`），诊断写 stderr。

exit 5 对 `rootfs.build_submit_failed` 的例外只适用于 clone 已成功提交的复合命令，
用于表达“整体目标未完成但已有持久部分成功”。独立 rootfs build 在 operation
建立前提交失败使用 `rootfs.queue_unavailable` 和 exit 1，不能冒充 operation 终态失败。

### 8.5 JSON 错误文档 schema

JSON 错误 stdout 保持单一文档：

```json
{
    "ok": false,
    "error": {
        "code": "stable.error.code",
        "message": "human-readable diagnostic"
    }
}
```

诊断（debug trace、cause chain）写 stderr，不进入 JSON。`--debug` 时 stderr
额外包含 HTTP status、response body 摘要和 cause error name。

## 9. 实施批次

### Batch 1：Recovery

- 冻结确定性重构语义（§6）；
- checkpoint schema 直接替换为 v3（reader 拒绝 v1/v2），terminal phase
  restore 时不重构 capability；
- 修订 `reconstructAndVerifyRaw` 注释（删除"capsule 交付前/中重启必须
  recovery_incomplete"的旧注释）；
- 补四 scope restart 与篡改负测。

**涉及文件**：`src/state/diskless_delivery.zig`、相关测试文件。

### Batch 2：Catalog v5 与 identity store

- `src/model.zig` **`Catalog.schema_version`** 默认值改为 5
  （`AppConfig.schema_version` 保持 4）；
- `src/catalog/store.zig` manifest 校验从 `!= 4` 改为 `!= 5`；
- `src/config/validate.zig` 中 catalog schema 校验（两处）从 `!= 4` 改为 `!= 5`，
  config schema 校验保持 `!= 4`；
- `src/setup.zig` `Catalog.schema_version` 从 4 改为 5
  （直接替换，不新增迁移模块）；
- 新增 identity store 模块（`src/state/identity_store.zig`）；
- `(id, revision)` 复合主键、两阶段 journal 与启动恢复；
- `src/model.zig` `ProfileConfig` 增加新字段；
- `src/catalog/dto.zig` `Profile` DTO 增加新字段及 `fromProfile` 映射；
- `src/paths.zig` 增加 `identity_store_path`；
- rootfs digest 接入 identity（`src/profile/diskless.zig`
  `ProfileBuildProjection` 增加 Profile revision 和 identity 字段）；
- 所有 Profile mutation 接入 §5.4 统一 revision helper，并增加入口覆盖测试。

### Batch 3：Create/clone（已实现）

- `managementProfileCreate` 增加 identity 事务（`src/http/server.zig`）；
- `managementProfileClone` 端点新增/扩展（`src/http/server.zig`）；
- `src/config/profile_mutation.zig` 增加 clone 逻辑；
- `src/main.zig` `profileCloneHandler` 增加 `--new-ssh-keys`/`--build`/`--detach`；
- `src/http/client.zig` `profileClone` 增加 new flags；
- clone provenance/patch/new keys；
- build/detach 组合结果。

落地核对：`--build`/`--detach` 与 property patch 已随 §5.2 完成；
`profile clone --help` 展示全部 flags 与 `[KEY=VALUE...]`；`tests/cli.sh`
覆盖 `--detach` 单独使用 exit 2、不可 patch 键 exit 2、集合键 exit 2；
`revision_scan` 覆盖 clone+patch 原子性与非法 patch 回滚。

### Batch 4：ISO worker（已实现）

- 新增独立 `IsoImportWorker`（daemon 启动时 spawn、停止时 join）；
- ISO import handler 改为 queued → 立即返回；
- restart→interrupted、partial cleanup 和 detach/follow；
- staging orphan 清理（daemon 启动时扫描 `work/`）；
- 对现有 rootfs/initrd worker 只做无行为变化回归，不重构其线程和队列模型。

### Batch 5：CLI 与清理（已实现）

- exit mapping 函数（`src/main.zig` `mapErrorToExitCode`）；
- mutation 失败路径的硬编码 exit 1 替换为映射函数调用
  （`reportMutationFailure` 与 `itemValuesHandler`；本地数据/JSON 解析/协议
  错误按 §8.1 保持 exit 1，不属于映射范围）；
- exit code 3/4 契约测试：`mapErrorToExitCode` 纯函数单测下沉
  `zig build test`（每个 exit class 至少一个 case），端到端由 daemon 在线
  `tests/http.sh` 覆盖；
- 删除旧同步 initrd handler（`src/main.zig` 中未绑定命令树的
  `initrdBuildHandler` 函数及其调用的 `initrd_build_executor.build`；
  `initrd_build_executor.buildFromInstaller` 仍被 daemon worker 使用，不删除）；
- 更新 `docs/cli/REFERENCE.md`、help 和注释；
- 文档一致性扫描（所有设计分册引用 v0.2.3 和 schema v5）。

## 10. 完成标准

v0.2.3 只有同时满足以下条件才完成：

- ✅ catalog schema 版本直接替换为 v5，旧 v4 catalog 不被加载（`UnsupportedSchemaVersion`）；
- ✅ identity store 原子写、权限和 fail-closed 测试通过；
- ✅ identity/catalog 两阶段发布的三处 crash recovery fixture 通过（§4.3）；
- ✅ Profile 普通 rebuild 不改变 SSH fingerprint 或 input digest；
- ✅ 所有公开 Profile mutation 成功恰好递增一次 Profile revision，失败/no-op 不递增；
- ✅ clone 默认复用 identity，新 key clone 得到不同 fingerprint；
- ✅ clone patch 与 provenance 原子，build 部分成功语义可诊断
  （`profile_created`/`build_submitted` 字段正确；patch 原子性与非法 patch
  回滚由 `revision_scan` clone 用例覆盖，`profile_created`/`build_submitted`
  由 `managementProfileClone` 复合响应实现，端到端由 daemon 在线
  `tests/http.sh` 覆盖）；
- ✅ capability 四 scope 在 restart 后只恢复原 token（token 一致性测试通过）；
- ✅ terminal canonical phase 在 restart 后保留且不恢复 capability（checkpoint
  v3 测试通过；v1/v2 直接替换拒载测试通过）；
- ✅ secret/hash/claim 异常进入 `recovery_incomplete` 或 fail closed；
- ✅ ISO/rootfs/initrd handler 不等待长任务，restart/partial/idempotency 确定
  （ISO 已由 `IsoImportWorker` 后台化；restart→interrupted 由
  `operations.load` 保证，idempotency 由 `beginQueuedRequest` 保证）；
- ✅ exit code 0–6 契约测试通过（每个 exit class 至少一个 case，
  `mapErrorToExitCode` 纯函数单测；端到端由 daemon 在线 `tests/http.sh` 覆盖）；
- ✅ 旧同步 initrd 产品路径与死代码删除；
- ✅ `node deploy <id>`（无第二参数）默认发送 `deploy=true`，显式 `false` 不受影响
  （契约测试通过）；
- ✅ `node trace --session X --latest` 返回 exit code 2（契约测试通过）；
- ✅ `V0_2_CLI.md` "唯一启用入口"不变量描述已更新；
- ✅ `zig build test` 全量通过（441/441，含 journal 删除失败传播、identity
  copy/rollback 稳定性、checkpoint v3 MAC 必填、v1/v2 直接替换拒载、identity /
  catalog revision overflow 以及 identity store 多记录持久化回归
  用例：还原 `persistLocked` 悬垂切片缺陷时该用例失败、修复后通过）；
- ✅ aarch64 VMware Rocky diskless 定向回归已通过（2026-07-31，r97n1 +
  r97n0 生产 daemon，最终 v0.2.3 ReleaseSafe 四产物）：
  - `profile create` 生成 identity → rootfs build 把 identity store 的
    client/host keypair 烤入 squashfs（解包比对公钥一致）；
  - PXE 启动后 session `f7718edd…` 到达 `diskless.running`，agent-consumed
    已提交，config/rootfs/agent/event 四 capability 全部撤销；
  - 从 r97n0 以 bootstrap key SSH 登录 `root@192.168.27.210` 成功，
    `systemctl is-system-running` = running，根为 overlay，节点
    `/root/.ssh/id_ed25519{,.pub}` 与 identity store 一致；
  - 执行前提：用最终二进制**以新资产名**重建 initrd/bundle（旧同名 initrd
    由旧 daemon 构建、携带旧 agent，`assets initrd build` 的
    already_present 检查只比 name/source/kernel，不校验 overlay 内容）。
- ✅ aarch64 VMware Ubuntu diskless 定向回归已通过（2026-07-31，同 Rocky
  环境与最终二进制）：新名重建 `ubuntu-22.04.5-nodeforge-initrd-v023` +
  v023 bundle + 新建 v0.2.3 ubuntu profile（casper/apt 路径，验证
  `installIdentityKeys` 的 casper 分支——解包 squashfs 比对 client 公钥与
  identity store 一致）；rootfs build 在 daemon 后台完成后，r97n1 重指与
  PXE：session `66c6f11e…` 到达 `diskless.running`，agent-consumed 200，
  四 capability 撤销；SSH 登录 `root@192.168.27.210` 成功，内核
  `5.15.0-119-generic`，`systemctl is-system-running` = running，根为
  overlay，节点 `/root/.ssh/id_ed25519{,.pub}` 与 identity store 一致。
  legacy ubuntu profile 因空 `ssh_identity` 不能重建 rootfs
  （`IdentityNotFound` fail closed，backlog §3.1 item 8 未实现、不在完成
  闸内）——回归使用新建的 v0.2.3 profile 规避。
- `V02-D01`—`V02-D14` 均不参与完成判定。

完成后 v0.2 不再保留实现 backlog，v0.3 保持 catalog v5。

## 11. 跨文档引用

本设计变更影响以下文档，实现 PR 必须同步更新：

| 文档 | 变更点 |
|---|---|
| [`V0_2_1_PLUS_ROADMAP.md`](../archive/design/V0_2_1_PLUS_ROADMAP.md) | v0.2.3 状态从"待实现"改为"已实现" |
| [`V0_2_POST_RELEASE_BACKLOG.md`](../archive/design/V0_2_POST_RELEASE_BACKLOG.md) | §3 真实差异标记为已关闭 |
| [`V0_2_DESIGN.md`](V0_2_DESIGN.md) | §4.4 SSH keys 描述更新为 identity store |
| [`V0_2_CLI.md`](V0_2_CLI.md) | §8 L517 "唯一启用入口"不变量更新；deploy/readiness 示例保留显式 true |
| [`V0_2_DISKLESS_WORKFLOW.md`](V0_2_DISKLESS_WORKFLOW.md) | deploy 示例保留显式 true 写法 |
| [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) | "重建时换全部 SSH keys"标记为已实现 |
| [`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md) | schema 版本引用更新 |
| [`docs/cli/REFERENCE.md`](../cli/REFERENCE.md) | `profile clone` 新增 flags、exit code 表；`node deploy` 缺省 true 语义说明 |
| [`CURRENT_CLI_OPTIMIZATION_PLAN.md`](CURRENT_CLI_OPTIMIZATION_PLAN.md) | P0/P1 完成状态更新 |
| [`V0_3_DESIGN.md`](V0_3_DESIGN.md) | 前置条件从 v0.2.2 改为 v0.2.3 |

版本实施顺序固定为 v0.2.1 → v0.2.2 → v0.2.3 → v0.3 → v0.4。

## 12. CLI 位置参数与默认值优化

### 12.1 背景

全 CLI 命令树扫描确认：`node deploy <node_id> <true|false>` 是唯一的布尔位置
参数。其余所有布尔语义均通过 flag（`--force`、`--detach`、`--yes` 等）表达，
默认值在 flag 声明层设定。zli 框架的 `PositionalArg` struct 只有
`name/description/required/variadic` 四个字段，不支持 `default_value`——
位置参数的默认值只能在 handler 层用 `ctx.getArg("name") orelse "default"` 实现。

### 12.2 P0：`node deploy` 默认启用

**现状**：`node deploy <node_id> <true|false>`，`enabled` 为 `required = true`
位置参数。handler（`src/main.zig` L4807-L4811）手动校验 `"true"`/`"false"` 字符串。

**变更**：

1. `enabled` 位置参数改为 `required = false`（L377）；
2. usage 从 `<node_id> <true|false>` 改为 `<node_id> [true|false]`（L375）；
3. description 从 `"Deployment gate value: true or false"` 改为
   `"Deployment gate value: true or false (default: true)"`（L377）；
4. handler 改为 `const enabled = ctx.getArg("enabled") orelse "true"`（L4807）；
5. `"true"`/`"false"` 校验逻辑保留不变（显式 `false` 仍正常工作）。

**安全语义裁决**：

`node deploy <id>` 缺省 `true` 意味着一条不完整命令直接打开部署闸门。这与
项目一贯的"破坏性操作需显式声明"姿态（`--force` 默认 false、`--yes` 默认 false）
存在张力。接受默认 `true` 的理由：

- `deploy` 动词本身的语义就是"启用部署"，不是中性查询；
- `node deploy` 底层是 `node set deploy=<v>` 的语法糖（handler 直接走
  `scalarMutations` key=`deploy`），糖就该更甜；
- 真正的安全闸是 boot readiness 强闸（`node readiness --stage boot`）而非
  这个布尔值；deploy=false 只阻止新 PXE，不终止运行中的 session。

此 trade-off 被显式 ack，不作为纯 UX 改动静默通过。

**文档不变量同步**：

`docs/design/V0_2_CLI.md` L517 明确写有 "`node deploy true` 是唯一启用入口"。
变更后 `node deploy <id>`（无第二参数）成为第二个启用入口，以下文档必须同步：

| 文档 | 位置 | 变更 |
|---|---|---|
| `V0_2_CLI.md` | L517 | "唯一启用入口"改为"启用入口（缺省 true）" |
| `V0_2_CLI.md` | L127 | 示例 `node deploy <id> false` 保持不变（显式 false 仍有效） |
| `V0_2_CLI.md` | L131、L509、L510、L577、L586、L597 | 示例可保留显式 `true`/`false` 写法（向后兼容），不强制改 |
| `V0_2_DISKLESS_WORKFLOW.md` | L253、L259、L345 | 同上，保留显式写法 |
| `CURRENT_CLI_OPTIMIZATION_PLAN.md` | L674、L1039、L1051 | 同上 |
| `README.md` | L308、L388、L410 | 同上 |
| `docs/cli/REFERENCE.md` | §Node 与生命周期 | 补一句“`node deploy <id>` 缺省等价于 `node deploy <id> true`” |

注：`V0_2_DESIGN.md` 中的 `deploy=true` 引用（L653、L1634）属于属性值语义或
`node set` 路径，不受本变更影响，无需同步。

显式 `node deploy <id> true` 写法在所有文档中保留有效，不批量替换为缺省形式。
只有不变量描述句（"唯一启用入口"）必须修正。

**契约测试**：

- 正例：`node deploy r97n1`（无第二参数）→ daemon 收到 `deploy=true`；
- 负例：`node deploy r97n1 false` → daemon 收到 `deploy=false`（显式值不被
  `orelse` 吞掉）；
- 非法值：`node deploy r97n1 yes` → exit code 2（现有校验保留）。

测试落点：正例/负例需要 daemon 在线，入 `tests/cli.sh`；非法值 exit 2
不依赖 daemon，下沉为 `zig build test` 语义用例。

### 12.3 P2：`node unset` 描述修正

**现状**：`keys` 位置参数 description 为 `"Optional property names to clear"`，
`required = true, variadic = true`（L351）。

**问题**："Optional" 指的是被清除的属性在 schema 中是 optional 的，不是参数本身
optional。描述文字对用户有误导性。

**变更**：description 改为 `"One or more optional property keys to clear"`。
`required` 保持 `true`（`unset` 不带 key 语义上无意义）。仅修正描述歧义，
不改变行为。

### 12.4 P3：`node trace --latest` 与 `--session` 冲突处理

**现状**：

- `--latest` 是 `Bool, default false`（L403），description 为
  `"Select the latest retained session (default when --session is omitted)"`；
- handler（L5207）`_ = ctx.flag("latest", bool)` 完全丢弃 flag 值——
  `--latest` 纯契约占位，无任何运行时效果；
- `--session` 优先于 `--latest`：L5221 逻辑是 `if requested_session.len != 0`
  则用 `--session`，否则回退到最新 session。同时给出 `--session X --latest`
  时静默以 `--session` 为准，无任何校验或提示。

**变更**：

1. `--session` 和 `--latest` 同时给出时返回 exit code 2，error code
   `trace.conflicting_flags`，message `"--session and --latest are mutually exclusive"`。
   在 handler 开头、`requested_session` 校验之后添加：

   ```text
   if (requested_session.len != 0 and ctx.flag("latest", bool)) {
       try writeCommandError(ctx, "trace.conflicting_flags",
           "--session and --latest are mutually exclusive", 2);
       return;
   }
   ```

   （与 handler 全库惯用的 `try writeCommandError(...); return;` 风格一致。）

2. `--latest` 的 description 改为
   `"Select the latest retained session (default behavior; mutually exclusive with --session)"`。

3. 删除 handler 中的 `_ = ctx.flag("latest", bool);` discard 行：冲突校验成为
   该 flag 的唯一消费点，discard 行变为死代码（§10 完成标准含死代码删除）。
   `--latest` 单独使用时行为不变（已经是缺省行为）。

**不删除 `--latest` flag** 的理由：它作为显式 CLI 契约别名保留，允许脚本
和自动化流程显式声明意图。删除会破坏现有脚本兼容性。

### 12.5 不改动项

以下经分析确认不需要改动：

| 项 | 现状 | 裁决 |
|---|---|---|
| `--force`（7 处：node set/unset/deploy/retry、values、items） | flag, default false | 安全语义正确，破坏性操作需显式声明 |
| `values replace-values` / `clear-values` 的 `values` | required = false | 已正确（replace 可只用 `--from-file`，clear 不需要值） |
| `item set` 的 `fields` | required = false, variadic | 已正确（可只用 `--unset`） |
| `profile clone --new-ssh-keys`/`--build`/`--detach` (v0.2.3) | flag, default false | 设计合理，见 §5.2 |
| `setup --yes`/`--reconfigure`/`--reset-all` 等 | flag, default false | 安全语义正确 |
| `--detach`（rootfs build、initrd build） | flag, default false | 默认 follow 符合交互习惯 |

### 12.6 实施归属

本节全部变更归入 Batch 5（CLI 与清理），不独立成批；已实现：

- ✅ P0（deploy 默认 true）：handler（`src/main.zig` `nodeDeployHandler` 缺省
  true）+ flag 声明（`[true|false] (default: true)`）+ `tests/cli.sh` 契约测试；
- ✅ P2（unset 描述）：1 行 description（`node unset`）；
- ✅ P3（trace 冲突校验）：handler（`trace.conflicting_flags` exit 2）+
  description + `tests/cli.sh` 契约测试。

契约测试落点：需要 daemon 在线的端到端用例入 `tests/cli.sh`；纯 CLI 层
校验（exit 2 路径）下沉为 `zig build test` 语义用例。

实施核对：P0/P2/P3 均在 `tests/cli.sh` L521-540 有契约断言；`node deploy`
帮助文本含 `(default: true)`；`--session`+`--latest` 冲突以 exit 2 拒绝。

### 12.7 完成标准补充

在 §10 完成标准中追加：

- ✅ `node deploy <id>`（无第二参数）默认发送 `deploy=true`，契约测试通过；
- ✅ `node deploy <id> false` 显式 false 不受影响，契约测试通过；
- ✅ `node trace --session X --latest` 返回 exit code 2，契约测试通过；
- ✅ `V0_2_CLI.md` L517 不变量描述已更新；`docs/cli/REFERENCE.md` 已补缺省
  语义说明与 exit code 表。

## 13. 实施状态附录（2026-07-31 同步）

本表把“未提交代码修复实施方案”的批次项映射到文件/函数与状态，作为注释与
设计文档一致性的单一事实源。Batch 1–5 全部落地；§10 完成标准（含 aarch64
VMware Rocky/Ubuntu diskless 定向回归）已于 2026-07-31 全部通过。

| 方案项 | 落点 | 状态 |
|---|---|---|
| A1 并发原语 | `src/state/identity_store.zig` `Store.mutex` + `lock` | 完成（HEAD 已含，本包复核） |
| A2 迭代语法 + get 不变量文档 | 同文件 `get()` | 完成 |
| A3 fillSlot 就地构造 / 持久化顺序 / 稳定 ref | 同文件 `fillSlot`/`create`/`createRevision` | 完成 |
| A4 staging 迁出 /tmp + 无条件清理 + 泄漏修复 | `paths.identity_staging_dir` + `create`/`createRevision` | 完成 |
| A5 atomicWriteSecret（创建即 0600） | 同文件 `atomicWriteSecret`（复用 `dhcp_store.syncParentDirectory`） | 完成 |
| A6 load 事务性（staged 数组一次性提交） | 同文件 `load()` | 完成 |
| A7 长度截断改显式报错 | 同文件 `fillSlot`（`error.KeyTooLarge`） | 完成 |
| A8 私钥堆 buffer 清零 | 同文件 `zeroAndFree` | 完成 |
| A9 强制语义分析 + 契约测试 | 同文件 `refAllDecls` + round-trip/复合键/损坏负测 | 完成 |
| B1 putDiskless 合并语义 | `src/state/node_inventory.zig` `putDiskless` | 完成 |
| B2 server 调用切换 + 注释 | `src/http/server.zig` `disklessFacts` | 完成 |
| B3 postFacts 正规 JSON + sanitizeDmi | `src/initrd.zig` | 完成 |
| B4 facts 三场景单测 | `node_inventory.zig` 测试区 | 完成 |
| C catalog v4 拒载错误码 | `src/catalog/store.zig` `loadDirectory`（`UnsupportedSchemaVersion`）+ `src/nodeforged.zig` daemon 启动分支（指引 re-run setup） | 完成 |
| D toProfile 补齐 | `src/catalog/dto.zig` `toProfile`（`kind`/`boot_bundle`/`bundle`/`diskless` + `revision`/`created_at`/`updated_at`/`provenance`/`ssh_identity` 与 `fromProfile` 对称） | 完成 |
| E #15 语义冻结负测 | `src/state/diskless_delivery.zig` 两条 | 完成 |
| #10 load 完整性校验 | `restoreRecord`（复合键去重、`revision>=1`、纯 Zig 指纹重算、`ssh-keygen -y` 配对） | 完成 |
| #6 ProfileBuildProjection | `src/profile/diskless.zig` 两个构造点 | 完成 |
| #9 mutateProfileMetadata | `src/config/profile_mutation.zig` + scalar/value/item/setKernelArgs | 完成（CLI 级扫描契约测试见 `src/config/revision_scan.zig`） |
| #18 daemon 接线（load fail-closed + mkdir 0700 + RouteContext） | `src/app.zig` + `src/http/server.zig` `serve`/`RouteContext` | 完成（`recoverPendingTransactions` 属 #8） |
| #8 两阶段 journal | `paths.identity_transactions_dir` + `src/state/identity_store.zig` `prepare`/`commit`/`rollback`/`recoverPendingTransactions` + `app.zig` 启动恢复（fail closed） | 完成（Batch 3 生产者接线：`create(…, &tx)` → catalog save → `commit`/`rollback`） |
| #7 rootfs builder `installIdentityKeys` | `src/provision/rootfs_os_builder.zig` `buildOsLayer`/`buildDnf` 注入 `identities`+`profile`，按复合键从 store 读取写入 staging | 完成（未命中 `IdentityNotFound` fail closed，构建期不再 ssh-keygen） |
| #23 §4.3 crash fixture | `src/state/identity_store.zig` 测试区：prepared/identity publish/catalog publish 三处崩溃恢复 fixture | 完成 |
| Batch 3 create 接线 | `src/http/server.zig` `managementProfileCreate`（`create(…,&tx)` → `addInstallProfile` → `commit` → `applyCatalogFromDisk`，errdefer 幂等 rollback）+ `addInstallProfile` 增加 `ssh_identity` 参数 | 完成 |
| Batch 3 clone 接线 | `managementProfileClone` + `cloneProfile` `ssh_identity_override`/property patch + `src/main.zig`/`src/http/client.zig` `--new-ssh-keys`/`--build`/`--detach` | 完成（见 §5.2） |
| §3.3 `--new-ssh-keys` 轮换 | `profile_mutation.rotateSshIdentity` + `managementRootfsBuild` + `RootfsBuildRequest.new_ssh_keys` + CLI/客户端 | 完成 |
| §5.4 CLI 级扫描契约测试 | `src/config/revision_scan.zig`（全部公开入口成功 +1 / 失败 +0，clone target=1 且 source 不变） | 完成 |
| Batch 5 exit mapping | `src/main.zig` `mapErrorToExitCode`（§8.3 表：error.code 精确映射优先、HTTP status 回退）+ `reportMutationFailure`/`itemValuesHandler` 接入（连接失败→6）+ `Mutation.http_status/error_code`（`src/http/client.zig` `managementMutation` 从错误信封提取稳定 code） | 完成（纯函数单测覆盖 0–6 全 class；`formatErrorReason` 改为返回 reason+code 双切片，code 复制进 reason_buf NUL 分隔避免悬垂） |
| Batch 5 死代码删除 | 删除 `src/main.zig` `initrdBuildHandler`（未绑定命令树）及 `src/provision/initrd_build_executor.zig` `build`（无引用包装）；`buildFromInstaller` 保留（daemon worker 在用） | 完成（`rg initrdBuildHandler` 无残留引用） |
| Batch 4 ISO durable worker | `src/http/server.zig` `IsoImportWorker`（队列容量 1，spawn/join 接线）+ `importInstallSource` 改 `beginQueuedRequest`→submit→202 + `runIsoImportWorker`/`performIsoImport`；`iso_import_mutex` 全局删除；staging 按 operation id 命名 | 完成（409 `install_source.busy` 语义保留；失败路径 `cleanupPublishedOutputs` 不变；worker 队列单测下沉） |
| §7.4 staging orphan 清理 | `src/catalog/iso_import.zig` `cleanupOrphanStaging`（启动扫描 `work/` 删除 `iso-import-*`）+ `importMedia` 新增 `work_tag` 参数 | 完成（serve() 启动、spawn worker 前调用） |
| §8.2 退出码契约测试 | `mapErrorToExitCode` 单测（`zig build test`）+ 端到端 `tests/http.sh`（macOS 跳过） | 完成（434/434 全绿） |
| §12 P0/P2/P3 契约测试 | `tests/cli.sh` L521-540（deploy 缺省 true、unset 描述、trace 冲突 exit 2） | 完成 |
| §10 完成标准核对 | §10 清单逐项标注 ✅/⏳ | 完成（仅剩 VMware 定向回归 ⏳） |
