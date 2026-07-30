# NodeForge v0.2.3 设计：Profile Identity 与恢复语义收口

状态：设计冻结，待实现  
前置：v0.2.2 `dd95376`  
schema：catalog v4 → v5；BootConfig 保持 v3；AgentPlan 保持 v1

v0.2.3 是 v0.2 系列最后一个收口版本，不增加部署形态。它只关闭 v0.2.2 发布后
确认的四组真实差异：Profile identity/provenance/clone、capability restart 语义、
ISO import 后台 operation、CLI exit mapping。

明确暂不做项统一引用
[`V0_2_POST_RELEASE_BACKLOG.md`](V0_2_POST_RELEASE_BACKLOG.md) §2 的稳定 ID；该表是
唯一范围裁决源，不得重新加入本版本完成闸。

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

后续版本（v0.3 catalog v6、v0.4 v7、v0.5 v8）同样遵循此原则。schema 版本号
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
- `V02-D04`—`V02-D06`：BIOS/PXELINUX、多 NIC/topology/容量 SLO、`ram_rootfs`；
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

**存储路径**：`<install-root>/state/identities.json`（由 `src/paths.zig` 新增
`identity_store_path` 字段，与 `diskless_secret_path`、`operations_path` 同级）。

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
  `dhcp_store.atomicWrite`（临时文件 + fsync + rename），与现有 state 文件原子写
  策略一致。

**安全要求**：

- 文件 0600、目录 0700（通过 `chmod` 子进程设置，与 `diskless_secret` 一致）；
- private key 不进入日志、Event、operation result、manifest 或公开 API；
- catalog 只保存 reference/revision/fingerprint（`ProfileSshIdentityRef`）；
- identity 文件损坏、缺失、复合键重复、fingerprint 不匹配或 private/public key
  不成对时 fail closed（加载时重新派生 public key 和 fingerprint 校验；daemon
  拒绝启动，与 `loadOrCreateSecret` 对 `InvalidDisklessSecret` 的处理一致）；
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
4. 将 journal 标记 `committed` 后删除。

daemon 启动时必须在接受管理请求前恢复未完成 journal：

- catalog 已引用目标复合键：确认 identity 存在且 fingerprint 匹配，然后完成提交；
- catalog 未引用目标复合键：从 identity store 删除该事务新增 revision 并回滚；
- catalog 已引用但 identity 缺失或不匹配：fail closed，禁止自动生成替代密钥。

"identity-first"允许崩溃窗口中短暂存在不可见 orphan，但启动恢复后不得残留。

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

**当前代码事实**：`diskless_delivery` checkpoint 已是 schema v2；v2 将生命周期时间字段
从 schema v1 的 `created_at`/`started_at` 重命名为 canonical 任务列名
`armed_at`/`install_at`（代码注释："schema 2 renamed lifecycle timestamps
to their canonical task-column names"）。diskless Session
没有独立 `terminal_reason`，终态由已经持久化的 canonical `phase` 表达：
`diskless_running`、`failed`、`expired` 均满足 `phase.isTerminal()`。

真实缺口不是“终态未持久化”，而是 `restorePersisted` 当前对 terminal phase
仍调用 `reconstructAndVerifyRaw`。v0.2.3 不升级 checkpoint schema，改为：

1. schema v1/v2 继续按当前兼容路径读取；
2. restore 得到 terminal phase 时保留 session 长期状态投影，但不重构四类 raw token；
3. terminal session 的四个 slot 在内存中保持不可认证，任何 capability 请求均拒绝；
4. 非 terminal 且未过期 session 才执行确定性重构和 hash 验证。

若未来需要记录比 canonical phase 更细的终止原因，应另行升级 schema v3；v0.2.3
不得复用已经占用的 schema v2。

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
- hash 篡改、claim 篡改、session id 篡改 → fail closed；
- path/content/scope/node/replay 不匹配 → `ProofMismatch`；
- terminal/cancel/expiry 后 restart → session 不恢复 capability；
- 外部无效 token 洪泛不改变目标 session（`verify` 返回 `invalid`，不消耗
  session 状态）。

其中合法长度 hash 的内容不匹配按 §6.2 进入该 session 的
`recovery_incomplete`；导致 claim/JSON 不可解析或越界的篡改使 daemon 拒绝启动。

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
- 默认 CLI follow（`operation follow`），`--detach` 立即返回 operation id；
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
- 同 idempotency key 的重复请求复用已有 operation（`beginRequest` 已实现）；
- 不提供通用 cancel（`V02-D11`）。

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

当前代码（`src/main.zig`）已使用 exit code 0/1/2/5/6：

| 现有 exit code | 使用场景 | 对应冻结类别 |
|---:|---|---|
| 0 | 命令成功 | ✅ 一致 |
| 1 | `reportMutationFailure`、daemon 返回错误、JSON 解析失败 | ✅ 一致 |
| 2 | CLI 参数错误、`validLogicalId` 失败、无效 flag 值 | ✅ 一致 |
| 5 | `operation follow` 终态为 failed | ✅ 一致 |
| 6 | daemon 不可达、operation follow 超时 | ✅ 一致 |

**新增 exit code**：
- **3**（revision/idempotency 冲突）：当前 `revisionConflict` 返回 HTTP 409，
  CLI 映射为 exit code 1。v0.2.3 改为 exit code 3。
- **4**（readiness/前置条件）：当前 `profile.not_diskless`、`rootfs.digest_drift`
  等返回 HTTP 400/409，CLI 映射为 exit code 1。v0.2.3 改为 exit code 4。

### 8.3 API error.code → exit class 映射

建立唯一映射函数 `mapErrorToExitCode(http_status, error_code) -> u8`（在
`src/main.zig` 中实现，替代 `reportMutationFailure` 的硬编码 exit code 1）。

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
- 保持 checkpoint schema v2，terminal phase restore 时不重构 capability；
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

### Batch 3：Create/clone

- `managementProfileCreate` 增加 identity 事务（`src/http/server.zig`）；
- `managementProfileClone` 端点新增/扩展（`src/http/server.zig`）；
- `src/config/profile_mutation.zig` 增加 clone 逻辑；
- `src/main.zig` `profileCloneHandler` 增加 `--new-ssh-keys`/`--build`/`--detach`；
- `src/http/client.zig` `profileClone` 增加 new flags；
- clone provenance/patch/new keys；
- build/detach 组合结果。

### Batch 4：ISO worker

- 新增独立 `IsoImportWorker`（daemon 启动时 spawn、停止时 join）；
- ISO import handler 改为 queued → 立即返回；
- restart→interrupted、partial cleanup 和 detach/follow；
- staging orphan 清理（daemon 启动时扫描 `work/`）；
- 对现有 rootfs/initrd worker 只做无行为变化回归，不重构其线程和队列模型。

### Batch 5：CLI 与清理

- exit mapping 函数（`src/main.zig` `mapErrorToExitCode`）；
- 替换所有 `setExitCode(ctx, 1)` 硬编码为映射函数调用；
- exit code 3/4 契约测试；
- 删除旧同步 initrd handler（`src/main.zig` 中未绑定命令树的
  `initrdBuildHandler` 函数及其调用的 `initrd_build_executor.build`；
  `initrd_build_executor.buildFromInstaller` 仍被 daemon worker 使用，不删除）；
- 更新 `docs/cli/REFERENCE.md`、help 和注释；
- 文档一致性扫描（所有设计分册引用 v0.2.3 和 schema v5）。

## 10. 完成标准

v0.2.3 只有同时满足以下条件才完成：

- catalog schema 版本直接替换为 v5，旧 v4 catalog 不被加载（`UnsupportedSchemaVersion`）；
- identity store 原子写、权限和 fail-closed 测试通过；
- identity/catalog 两阶段发布的三处 crash recovery fixture 通过（§4.3）；
- Profile 普通 rebuild 不改变 SSH fingerprint 或 input digest；
- 所有公开 Profile mutation 成功恰好递增一次 Profile revision，失败/no-op 不递增；
- clone 默认复用 identity，新 key clone 得到不同 fingerprint；
- clone patch 与 provenance 原子，build 部分成功语义可诊断
  （`profile_created`/`build_submitted` 字段正确）；
- capability 四 scope 在 restart 后只恢复原 token（token 一致性测试通过）；
- terminal canonical phase 在 restart 后保留且不恢复 capability（checkpoint v1/v2
  兼容测试通过）；
- secret/hash/claim 异常进入 `recovery_incomplete` 或 fail closed；
- ISO/rootfs/initrd handler 不等待长任务，restart/partial/idempotency 确定；
- exit code 0–6 契约测试通过（每个 exit class 至少一个 case）；
- 旧同步 initrd 产品路径与死代码删除；
- `zig build test` 全量通过；
- 当前 aarch64 VMware 完成 Rocky/Ubuntu diskless 定向回归；
- `V02-D01`—`V02-D14` 均不参与完成判定。

完成后 v0.2 不再保留实现 backlog，v0.3 从 catalog v6 开始。

## 11. 跨文档引用

本设计变更影响以下文档，实现 PR 必须同步更新：

| 文档 | 变更点 |
|---|---|
| [`V0_2_1_PLUS_ROADMAP.md`](V0_2_1_PLUS_ROADMAP.md) | v0.2.3 状态从"待实现"改为"已实现" |
| [`V0_2_POST_RELEASE_BACKLOG.md`](V0_2_POST_RELEASE_BACKLOG.md) | §3 真实差异标记为已关闭 |
| [`V0_2_DESIGN.md`](V0_2_DESIGN.md) | §4.4 SSH keys 描述更新为 identity store |
| [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) | "重建时换全部 SSH keys"标记为已实现 |
| [`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md) | schema 版本引用更新 |
| [`docs/cli/REFERENCE.md`](../cli/REFERENCE.md) | `profile clone` 新增 flags、exit code 表 |
| [`CURRENT_CLI_OPTIMIZATION_PLAN.md`](CURRENT_CLI_OPTIMIZATION_PLAN.md) | P0/P1 完成状态更新 |
| [`V0_3_DESIGN.md`](V0_3_DESIGN.md) | 前置条件从 v0.2.2 改为 v0.2.3 |

版本实施顺序固定为 v0.2.1 → v0.2.2 → v0.2.3 → v0.3 → v0.4 → v0.5。
