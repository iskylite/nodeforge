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

`ProfileConfig` 增加：

```text
revision: u64
created_at: i64
updated_at: i64
provenance:
  origin: create | clone | migrated
  install_source_name: string
  install_source_revision: u64
  cloned_from:
    profile_name: string
    profile_revision: u64
    catalog_revision: u64
    cloned_at: i64
  | null
ssh_identity:
  id: string
  revision: u64
  client_public_fingerprint: string
  host_public_fingerprint: string
```

时间使用 daemon UTC Unix seconds。Profile mutation 每次成功只递增该 Profile
revision，并更新 `updated_at`；不因无关 catalog mutation 改变。

### 3.2 SSH identity owner

private key 不进入 catalog。daemon-owned identity store 保存：

```text
schema_version: 1
identities[]:
  id
  revision
  created_at
  client_private_key
  client_public_key
  host_private_key
  host_public_key
  client_public_fingerprint
  host_public_fingerprint
```

要求：

- 文件 0600、目录 0700；
- private key 不进入日志、Event、operation result、manifest 或公开 API；
- catalog 只保存 reference/revision/fingerprint；
- identity 文件损坏、缺失、fingerprint 不匹配时 fail closed；
- identity 写入临时文件并 fsync/rename 后，catalog 才能引用；
- catalog publish 失败时回收尚未被引用的新 identity；
- 已被 artifact 或 Profile 引用的 identity 不自动删除。

### 3.3 Rootfs identity

`rootfs_input_digest` 增加：

```text
ssh_identity.id
ssh_identity.revision
client_public_fingerprint
host_public_fingerprint
```

rootfs build 只读取固定 identity并写入 staging，不再调用 ssh-keygen 生成普通构建
identity。相同 Profile revision、identity revision与其他输入必须得到相同 input digest。

`--new-ssh-keys` 先创建 identity revision，再发布 Profile revision，最后提交 rootfs
operation。失败边界必须在响应中区分：

- identity/Profile 未发布；
- Profile 已发布但 build 未提交；
- build operation 已提交。

## 4. Migration 与 rollback

### 4.1 v4 → v5

旧 Profile 没有稳定 identity。迁移必须：

1. 对每个 Profile 生成一个新 identity；
2. `origin=migrated`；
3. `created_at=updated_at=migration_time`；
4. `revision=1`；
5. install source name从原 Profile确定，不能猜测缺失 source；
6. identity 全部成功写入后才发布 catalog v5；
7. 任一 Profile 失败则 catalog 仍保持 v4，清理本次未引用 identity。

旧 rootfs artifact仍可供既有 immutable session 使用，但不视为 v5 Profile当前缓存；
首次 v5 rootfs build产生包含 identity fingerprint 的新 digest。

### 4.2 rollback

transaction finalize 前可以删除本次新 identity并恢复 catalog v4。finalize 后 v5
不可无损降级到 v4，因为 provenance和稳定 identity会丢失；只允许从迁移备份恢复，
不得静默丢字段保存成 v4。

fixture 必须覆盖：

- 多 Profile成功迁移；
- 中途 identity写失败；
- catalog publish失败；
- source缺失；
- identity文件损坏；
- load v4 → migrate → mutate → save v5 → reload。

## 5. Profile create 与 clone

### 5.1 Create

`profile create` 在 daemon事务中：

1. 验证 install source与目标名；
2. 创建 identity；
3. 创建 provenance；
4. 校验候选 catalog；
5. 原子发布 identity + catalog。

不能创建“有 Profile、无 identity”的半成品。

### 5.2 Clone

正式接口：

```text
profile clone SOURCE TARGET [KEY=VALUE...]
  [--new-ssh-keys]
  [--build]
  [--detach]
```

语义：

- 深拷贝 desired configuration；
- 不复制 runtime、session、operation、artifact current pointer；
- 默认复用 source identity；
- `--new-ssh-keys` 创建独立 identity；
- property patch 与 clone 在同一 catalog事务校验；
- provenance记录 source Profile revision和 catalog revision；
- `--detach` 只有与 `--build` 同用时有效；
- clone事务先完成，随后提交 build operation；
- build提交失败不能回滚已成功 clone，响应必须返回
  `profile_created=true`、`build_submitted=false` 和稳定 error code。

## 6. Capability restart 语义

v0.2.3 正式采用“确定性重构原 token”：

- raw token永不持久化；
- daemon使用持久 master secret + session id + scope确定性派生；
- 持久 hash用于验证重构结果；
- restart前后得到同一个 token，不签发第二 token；
- scope、node、path、content digest、event sequence和 expiry保持原 claim；
- terminal/cancel/expiry持久撤销全部 scope，重启后不得恢复；
- master secret变化或 hash不匹配时 session进入 `recovery_incomplete`；
- checkpoint损坏时 fail closed；
- 未认证请求不得推进 session或消耗 victim failure budget。

因此，“仅因 token 尚未完整交付就一律 recovery_incomplete”不再是现行规则。
`recovery_incomplete` 专用于无法安全重构同一 capability 的情况。

负测覆盖：

- config/rootfs/agent/event四 scope restart；
- 交付前、Range传输中、完整交付后 restart；
- master secret变化；
- hash、claim、session id篡改；
- path/content/scope/node/replay不匹配；
- terminal/cancel/expiry后 restart；
- 外部无效 token洪泛不改变目标 session。

## 7. ISO import durable worker

当前 operation记录保留，执行模型改为：

```text
HTTP validate/snapshot
  -> persist queued operation
  -> bounded daemon worker
  -> running
  -> validate/publish
  -> succeeded | failed
```

要求：

- handler不 spawn 后 join；
- 默认 CLI follow，`--detach`立即返回 operation id；
- CLI timeout不取消 operation；
- daemon restart将 queued/running确定转为 `operation.interrupted`；
- staging/.part由 operation id独占；
- digest、repository index、catalog校验全部成功后原子发布；
- 失败、restart和catalog冲突不留下公开幽灵 artifact；
- 同 idempotency key复用原 operation，不重复导入。

v0.2.3仍不提供通用 cancel。

## 8. CLI exit mapping

冻结 exit class：

| code | 类别 |
|---:|---|
| 0 | 成功 |
| 1 | 本地数据、协议或未知产品错误 |
| 2 | CLI输入错误 |
| 3 | revision/idempotency并发冲突 |
| 4 | readiness或前置条件不满足 |
| 5 | durable operation终态失败 |
| 6 | daemon不可达或等待超时 |

建立唯一映射函数读取 HTTP status和稳定 API `error.code`。handler不得自行把同一
error.code映射到不同 exit class。JSON错误stdout保持单一文档，诊断写stderr。

## 9. 实施批次

### Batch 1：Recovery

- 冻结确定性重构语义；
- 修订冲突文档/注释；
- 补四 scope restart与篡改负测。

### Batch 2：Catalog v5 与 identity store

- schema、store、权限、原子写；
- v4 migration/rollback fixture；
- rootfs digest接入 identity。

### Batch 3：Create/clone

- create identity事务；
- clone provenance/patch/new keys；
- build/detach组合结果。

### Batch 4：ISO worker

- 后台队列；
- restart/partial/idempotency；
- default follow/detach。

### Batch 5：CLI 与清理

- exit mapping；
- 删除旧同步 initrd handler；
- 更新 reference/help/注释；
- 文档一致性扫描。

## 10. 完成标准

v0.2.3 只有同时满足以下条件才完成：

- catalog v4→v5完整 migration/rollback fixture通过；
- Profile普通 rebuild不改变SSH fingerprint或input digest；
- clone默认复用identity，新key clone得到不同fingerprint；
- clone patch与provenance原子，build部分成功语义可诊断；
- capability四scope在restart后只恢复原token；
- secret/hash/claim异常进入`recovery_incomplete`；
- ISO handler不等待长任务，restart/partial/idempotency确定；
- exit code 0–6契约测试通过；
- 旧同步 initrd 产品路径与死代码删除；
- `zig build test`全量通过；
- 当前aarch64 VMware完成Rocky/Ubuntu diskless定向回归；
- `V02-D01`—`V02-D14` 均不参与完成判定。

完成后v0.2不再保留实现backlog，v0.3从catalog v6开始。
