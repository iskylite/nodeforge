# M4.4：HTTP API URL 契约收口与路由平面分离

> 历史设计说明：本文保留 M4.4 对 M4.3 `config set` 的兼容要求；M4.9 已删除该命令和 management
> config PATCH。现行路由契约见 `DETAILED_DESIGN.md` §9.18。

- 日期：2026-07-15
- 状态：设计完成，待实现
- 前置：M4.3
- 插入位置：`docs/DETAILED_DESIGN.md` §9.13，必须在 M5 前交付
- 目标：在 M4.3 的 ConfigRuntime、聚合管理 API 和可恢复 BootSession 基线上，统一 HTTP URL 命名、认证、缓存和迁移契约，消除重复入口和基于匹配顺序的路由歧义

## 1. 结论摘要

当前 URL 的主要问题属实：`/boot/config/:node_id` 与 `/api/v1/nodes/:id/config` 重复，`/boot` 同时承担 API
和静态文件，rootfs 未绑定 node，管理端点混用资源名与裸动词，且旧路径缺少一致的版本/生命周期说明。

M4.4 采用三个路由平面：

| 平面 | 前缀 | 认证 | 版本策略 |
| --- | --- | --- | --- |
| 节点交付 API | `/api/v1/nodes/:id/**` | bootstrap/capability，按端点明确 | 当前开发期 canonical 前缀；变更直接更新设计与实现 |
| 本机管理 API | `/api/v1/management/**` | direct peer 必须为 `127.0.0.1` | 与节点 API 使用同一当前契约 |
| 静态制品 | `/artifacts/**` | catalog allowlist 或端点声明 | 字节身份由 logical name + SHA-256/manifest 版本化，不伪装成 JSON API |

`/healthz` 保持无版本、无认证的进程健康探针。M4.4 不引入第二 listener、远程管理、TLS、Web UI、OpenAPI
代码生成或新的 installer 能力。

NodeForge 当前仍处于内部开发阶段，`/api/v1` 只是当前代码组织前缀，不构成历史兼容承诺。M4.4 直接把代码、CLI、
生成器、fixture 和文档切换到本文最新契约：不保留旧 URL、redirect、alias、旧 session 路由或兼容 deadline。
本文的方法、状态码、错误 envelope、并发和幂等规则是 **M4.4 当前实现规范与验收基线**，不是对未来开发冻结；后续
设计若调整，可在发布稳定版本前同步修改本文、代码和全部 fixture，不需要为了内部历史增加 `/api/v2`。

两项分析建议不直接采用：

1. NoCloud 会按固定叶子名请求 `user-data`、`meta-data`、`vendor-data`，Kickstart 也由 boot 参数直接引用 URL；
   因此不用 `Accept` 在同一个 `/answer` 上切换四种语义，而使用显式、可预测的 install-config 子资源。
2. URL 名称不能构成敏感信息保护。含 capability/hash 的响应使用节点绑定认证、`Cache-Control: no-store`、
   禁止 header/body 日志和模板化 access path；不通过把路径命名成 `secret` 获得虚假安全感。

## 2. 当前代码事实

`src/http/server.zig::route()` 目前使用有序 `startsWith/eql` 分派：

- `/boot/config/:id` 和 `/api/v1/nodes/:id/config` 调用同一个 `bootConfig()`；
- `/boot/config/**` 必须排在通用 `/boot/*` 静态匹配之前；
- `/rootfs/:name` 使用 `authenticateCapabilityAny`，随后再间接检查 profile；
- `/answer`、`/answer/user-data` 等用后缀决定完全不同的内容类型；
- management 的 `reload/import/retry/unknown` 直接编码在 path 中；
- M4.3 将新增 nodes/profile/catalog/config mutation 路由，若不先固定命名，M5–M7 会继续复制现状。

问题的核心不是“是否百分之百 REST”，而是同一类型操作能否预测、认证是否由路由模板唯一决定、旧客户端如何
迁移，以及一个新 route 是否可能被更早的前缀规则误接管。

## 3. 节点交付 API

### 3.1 Canonical 路由

| 方法 | Canonical URL | 认证 | 响应/用途 |
| --- | --- | --- | --- |
| GET | `/api/v1/nodes/:id/boot-config` | bootstrap 或本 node capability | BootConfig JSON |
| GET | `/api/v1/nodes/:id/install-config/kickstart` | bootstrap 或本 node capability | Kickstart 文本 |
| GET | `/api/v1/nodes/:id/install-config/nocloud/user-data` | bootstrap 或本 node capability | NoCloud user-data |
| GET | `/api/v1/nodes/:id/install-config/nocloud/meta-data` | bootstrap 或本 node capability | NoCloud meta-data |
| GET | `/api/v1/nodes/:id/install-config/nocloud/vendor-data` | bootstrap 或本 node capability | NoCloud vendor-data |
| POST | `/api/v1/nodes/:id/events` | 本 node capability | NodeForge 主动阶段事件 |
| POST | `/api/v1/nodes/:id/logs` | 本 node capability | 有界失败日志摘要 |
| POST | `/api/v1/nodes/:id/installer-hooks/subiquity` | direct peer + 活动 session/lease bootstrap proof | Subiquity/Curtin webhook |
| POST | `/api/v1/nodes/:id/facts` | 本 node capability | M4.3 inventory facts |
| GET/HEAD | `/api/v1/nodes/:id/artifacts/rootfs/:name` | 本 node capability + profile/source 绑定 | M5 rootfs 下载 |

`boot-config` 返回按 profile adapter 明确生成的 install-config URL，不再返回含糊的单一 `answer_url`。结构为：

```json
{
  "install_config": {
    "kind": "kickstart",
    "url": "http://server/api/v1/nodes/r97n1/install-config/kickstart"
  }
}
```

Ubuntu 使用 `kind=no-cloud`，并返回 `seed_url` 指向 `/install-config/nocloud/`；NoCloud 自行追加三个固定叶子名。
不支持当前 profile 的 leaf 返回 `404 install_config.not_available`，不能对 Ubuntu 节点返回 Kickstart 或反之。

### 3.2 响应安全策略

`boot-config` 和全部 install-config 响应可能包含 capability、password hash 或 SSH key，必须统一设置：

```text
Cache-Control: no-store, private
Pragma: no-cache
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
```

- capability 只允许在受认证响应 body/answer 中传递，不放 query string、path、redirect target 或 access log；
- access log 只记录 route template、node_id、status、bytes、duration，不记录 Authorization/header/body；
- method 不匹配返回 405 + `Allow`，认证缺失/错误分别返回稳定 401/403；
- node id 必须同时匹配 path、capability/session 和 resolved profile，不能使用 `authenticateCapabilityAny`；
- 不对认证请求返回 301/302/307/308，避免 installer/firmware 丢失 Authorization 或改变方法。

### 3.3 Subiquity webhook

`installer-hooks/subiquity` 的命名明确它是 installer 受限 webhook，不是假装与 bearer `/events` 相同。认证继续继承
M4.3：只使用 direct peer + path node + 活动 lease/session 的专用 bootstrap proof，不因存在无关 Authorization
header 切换通用 capability 分支。URL 差异是认证契约的可见提示，但不是降低认证强度的理由。

## 4. 静态制品路由

| 旧 URL | Canonical URL | 认证 |
| --- | --- | --- |
| `/boot/*` | `/artifacts/boot/*` | public + catalog allowlist |
| `/images/:name` | `/artifacts/images/:name` | public + catalog allowlist |
| `/repos/:name/*` | `/artifacts/repositories/:name/*` | public + catalog allowlist |
| `/rootfs/:name` | `/api/v1/nodes/:id/artifacts/rootfs/:name` | node capability + profile/source binding |

静态制品不放到 `/api/v1`：API version 表达协议/representation 兼容性，制品字节由 catalog logical name、SHA-256、
ETag 和 immutable publish 规则表达版本。所有静态路径仍执行 normalize、symlink/path traversal 拒绝和 catalog
allowlist；支持 GET/HEAD、Range、ETag/If-None-Match。发布对象内容变化必须换 logical name，不能原地覆盖。

`/artifacts/boot/config/**` 不存在，路由注册测试必须证明静态前缀不可能接管节点 API。

## 5. 本机管理 API

M4.4 不追求教条式 REST；耗时验证、迁移计划和 install generation 是可审计动作，建模为“创建动作资源”，而不是
把裸动词随意附在对象后。Canonical 表面如下：

| 方法 | Canonical URL | 说明/来源里程碑 |
| --- | --- | --- |
| GET | `/api/v1/management/status` | server/config/runtime 摘要 |
| GET | `/api/v1/management/config` | revision、valid、restart-required 摘要，不返回 secrets |
| PATCH | `/api/v1/management/config` | M4.3 allowlist typed mutation + `If-Match` |
| POST | `/api/v1/management/config/validations` | 创建一次候选配置验证结果 |
| GET/POST | `/api/v1/management/nodes` | M4.3 聚合 list / add |
| GET/PATCH/DELETE | `/api/v1/management/nodes/:id` | M4.3 show / typed set-unset / remove |
| POST | `/api/v1/management/nodes/:id/install-generations` | 显式 rearm 下一 generation |
| GET | `/api/v1/management/profiles` | M4.3 profile list |
| GET | `/api/v1/management/profiles/:name` | M4.3 profile show |
| GET | `/api/v1/management/install-sources/:name` | M4.3 catalog show |
| POST | `/api/v1/management/catalog/migration-plans` | M4.3 catalog migrate dry-run |
| POST | `/api/v1/management/catalog/migrations` | M4.3 按 plan digest apply |
| POST | `/api/v1/management/assets` | 导入/发布 asset |
| POST | `/api/v1/management/install-sources` | 从 ISO 导入 install source |
| GET | `/api/v1/management/operations/:id` | 查询长任务状态/结果；operation 过期后返回 404 |
| GET | `/api/v1/management/runtime` | 运行态摘要 |
| GET | `/api/v1/management/runtime/tftp` | TFTP counters/status |
| GET | `/api/v1/management/runtime/tftp/sessions` | TFTP sessions |
| GET | `/api/v1/management/runtime/dhcp/leases` | lease；`scope=all|unclaimed` |

M4.3 已取消 reload 式 node CRUD，因此 `/management/config/reload` 直接删除，不迁移为新 URL。M6 的
profile/repository 写 API、distro 派生索引只读视图和完整 config diff/apply 必须沿用上述 collection、revision
和 action-resource 规则；不增加 distro 写 API。

所有 management path 在 route match 之前继续执行 direct peer `127.0.0.1` 校验；不能因 path 重构信任
`X-Forwarded-For` 或开放远程 endpoint。

### 5.1 v1 通用 representation 契约

所有 JSON 请求使用 `Content-Type: application/json`，JSON 响应使用 `application/json; charset=utf-8`。空 DELETE
响应使用 204 且无 body。成功响应不得套随意变化的 `data` 层；collection 固定为：

```json
{
  "items": [],
  "next_cursor": null,
  "view_revision": {
    "config": "...",
    "catalog": "..."
  }
}
```

`items` 和 `next_cursor` 是 normative；`view_revision` 在聚合 config/catalog 资源中必需，runtime-only collection
可使用对应 store revision。collection 支持 `limit`（默认 50，范围 1..200）和 opaque `cursor`；未知 query 参数
返回 `400 request.unknown_parameter`，不能被静默忽略。单对象 GET 返回对象本身。可 mutation 的 config/node 资源用
`ETag: "model-<config-revision>"` 暴露 desired-model 并发基线；聚合在 body 中的 runtime/inventory 变化由
`view_revision` 表达，management 响应为 `Cache-Control: no-store`，不得把该 ETag 用作聚合 body 的长期缓存键。

错误统一为：

```json
{
  "error": {
    "code": "config.revision_conflict",
    "message": "human-readable summary",
    "details": {},
    "request_id": "01..."
  }
}
```

`code`、`message`、`request_id` 必需，`details` 可选且不得含 secret。稳定状态映射为：400 语法/未知参数，401 缺少
认证，403 proof/peer 不匹配，404 资源或不适用 leaf 不存在，405 方法不匹配并带 `Allow`，409 revision/name/
active-session/plan 冲突，413 body 过大，415 media type 不支持，422 内容可解析但语义校验失败，428 缺少必需
`If-Match`，429 资源限制，500 非预期错误。不得把同一稳定 error code 在不同 handler 映射成不同 HTTP status。

config/node PATCH 和 DELETE 必须携带上一 GET 返回的 `If-Match`；缺少为 428，过期为
`409 config.revision_conflict`。成功 mutation 返回新的 `ETag` 和 model revision。请求是全有或全无；unknown field、
wrong type 或 restart-required 不能部分落盘。

### 5.2 创建与长任务语义

| 请求 | 成功 | 响应契约 |
| --- | --- | --- |
| `POST /nodes` | 201 | Node DTO + `Location: /api/v1/management/nodes/:id`；ID 已存在且内容相同幂等返回 200，不同内容 409 |
| `PATCH /nodes/:id`、`PATCH /config` | 200 | 更新后的 DTO/摘要 + 新 ETag |
| `DELETE /nodes/:id` | 204 | 无 body；活动 session 冲突为 409 |
| `POST /nodes/:id/install-generations` | 201 | generation DTO + Location；同 Idempotency-Key 不重复 rearm |
| `POST /config/validations` | 201 | immutable validation result，不修改事实源 |
| `POST /catalog/migration-plans` | 201 | immutable plan、config/catalog revision 和 plan digest |
| `POST /catalog/migrations` | 202 | operation DTO + Location；body 必须带 plan digest |
| `POST /assets`、`POST /install-sources` | 202 | operation DTO + Location；完成结果包含 reused/name/SHA 或稳定错误 |

长任务 operation 的 normative 字段为 `id`、`kind`、`state=queued|running|succeeded|failed`、`created_at`、
`updated_at`、`progress`（JSON number，0..100）、`result`、`error`；非 terminal 时 result/error 都为 null，terminal
后二选一。operation 本身不赋予额外权限，查询仍
受 loopback guard。install-generation、catalog migration、asset/import 等会产生副作用的 action/长任务必须携带
`Idempotency-Key`（1..128 个可打印 ASCII，CLI 必须生成），缺失返回 `400 request.idempotency_key_required`；纯
validation/migration-plan 可以省略。同 key + 同 canonical request digest 返回原资源，不同 digest 返回
`409 request.idempotency_conflict`。ISO 内容级幂等仍以 M4.3
SHA/logical id 状态机为最终判定，Idempotency-Key 只防 HTTP 重试重复排队。

operation 和 key 映射继承 M4.3 的 `state/operations.json` 持久化契约：terminal 至少保留 24 小时且有容量上限，
重启不能忘记已完成副作用；running import 被中断时返回稳定 failed result，migration 则以 model journal 恢复结果
重建 operation。M4.4 复用当前 URL/DTO，不另建 memory-only operation registry。

Node、Profile、InstallSource、Generation、Validation、MigrationPlan 和 Operation DTO 的字段来源及 secret 脱敏继承
M4.3；M4.4 必须为它们生成 golden JSON fixtures，作为当前实现的精确回归基线。开发期调整字段时必须在同一变更中
更新专项设计、详细设计、CLI client 和 fixture，不能只改服务端；当前不为内部历史保留双版本 DTO。

### 5.3 最小稳定 DTO 与请求体

以下是 M4.4 验收时必须进入 golden fixture 的最小字段；`?` 表示 JSON null 可用，但字段本身仍必须出现。时间统一为
RFC 3339 UTC，revision/digest 为不透明字符串，枚举值必须在 schema/测试中列全：

| DTO | normative 字段 |
| --- | --- |
| `NodeSummary` | `id, mac, ip?, arch, profile, hostname?, deploy, status, deployed_at?, serial_number?, plan_drift` |
| `NodeDetail` | `node, profile, effective_system, deployment, runtime, inventory, view_revision`；六个分组始终存在 |
| `ProfileSummary` | `name, mode, distro, version, arch, install_source?, node_count, valid` |
| `ProfileDetail` | `profile, capability, install_source?, repositories, assets, effective_system, safety, node_ids, validation, view_revision` |
| `InstallSourceDetail` | `name, display_name?, family, distro, version, arch, media_kind, media_tree_url?, repositories, assets, sha256, profile_refs, view_revision` |
| `Deployment` | `generation, revision, plan_digest?, plan_drift, requested_at?, started_at?, finished_at?, deployed_at?` |
| `Runtime` | `phase, session_active, boot_session_id?, last_event_at?, last_error?, last_reason?` |
| `Inventory` | `serial_number?, product_uuid?, vendor?, model?, reported_at?, source?, deployment_generation?, boot_session_id?` |
| `Generation` | `node_id, generation, armed_at, reason?, state` |
| `ValidationResult` | `id, valid, errors, warnings, config_revision, catalog_revision, created_at` |
| `MigrationPlan` | `id, plan_digest, applicable, ambiguities, config_revision, catalog_revision, profile_patches, file_actions, created_at` |

`effective_system` 中 password/private key/capability 永不出现；secret 字段只用
`{ "configured": true|false, "source": "...", "fingerprint": "..."? }` 投影。`node`、`profile` 分组包含对应
config model 的全部非 secret 字段，因此新增 config 字段时 v1 可增加 optional 输出，但不能把已输出字段移除或改义。

node mutation 使用统一 typed patch，不把 CLI `k=v` 文本直接传入 HTTP：

```json
{
  "set": {
    "hostname": "r97n1",
    "deploy": false,
    "overrides.network.mode": "static"
  },
  "unset": ["serial_number"]
}
```

`POST /nodes` 使用 `{ "id": "r97n1", "set": { ... } }`；`PATCH /nodes/:id` 和 `/config` 使用上面的
`set/unset`。path 使用 schema canonical field path，value 是目标类型 JSON，不接受字符串化 bool/IP 之外的 CLI 语法；
同一 path 同时出现在 set/unset、父子 path 同时修改或未知 path 返回 400，整个请求无副作用。

其他 action body 固定为：

```text
POST install-generations: { reason?: string }
POST config/validations:   { candidate?: object, patch?: TypedPatch }  # 二选一
POST migration-plans:      { source_names?: [string] }                 # 省略表示全部旧对象
POST catalog/migrations:   { plan_digest: string }
POST assets:               { path: string, name?: LogicalId, kind: string }
POST install-sources:      { filename: string, sha256: string, name?: LogicalId, distro?: string, version?: string, arch?: string }
```

`path`/`filename` 只允许 daemon 本机可读路径（`filename` 是 CLI 已 stage 到 import_dir 的不透明 basename），并继续执行受管 staging、symlink 和文件类型检查；它们不得回显到普通
operation/result 或服务日志。body 未声明字段返回 `400 request.unknown_field`。最大 JSON body、string、array 长度由
RouteSpec/DTO schema 显式给出并在读完整 body 前执行总大小限制。

## 6. 开发期一次性替换

### 6.1 替换清单

| 旧路径 | 处理 |
| --- | --- |
| `/boot/config/:id` | 删除；新 bootloader 配置只使用 `/api/v1/nodes/:id/boot-config` |
| `/api/v1/nodes/:id/config` | 删除；只实现 `/boot-config` |
| `/api/v1/nodes/:id/answer[/...]` | 删除；只实现显式 `/install-config/kickstart` 或 `/install-config/nocloud/...` |
| `/api/v1/nodes/:id/subiquity-report` | 删除；只实现 `/installer-hooks/subiquity` |
| `/boot|images|repos/**` | 删除；只实现 `/artifacts/boot|images|repositories/**` |
| `/rootfs/:name` | 改为 node-bound rootfs URL；M5 尚未交付，不保留 alias |
| `/management/server/status`、`config/status` | 删除；只实现 `/management/status` 和 `/management/config` |
| `/management/config/validate` | 删除；只实现创建 `/management/config/validations` |
| `/management/config/reload` | 删除 |
| `/management/nodes/:id/status` | 删除；只实现 M4.3 聚合 `/management/nodes/:id` |
| `/management/nodes/:id/install/retry` | 删除；只实现创建 `/install-generations` |
| `/management/tftp/**`、`dhcp/**` | 删除；只实现 `/management/runtime/**` 与 lease query |
| `/management/assets/import`、`install-sources/import` | 删除；只实现 POST 对应 collection |

### 6.2 切换规则

- 一次提交中同步修改 RouteSpec、GRUB/BootConfig/Kickstart/NoCloud 生成器、CLI client、preview、示例和全部 fixture；
- 旧 route 不注册，因此从第一版 M4.4 二进制启动起直接返回 404；不实现 redirect、deprecated warning、alias 或
  route migration state；
- M4.4 是开发里程碑切换，不支持把 M4.3 正在进行的安装跨版本续接。部署 M4.4 前必须停止发起新安装、确认没有
  active delivery session，并删除开发环境的旧 `boot-sessions.json`；
- M4.4 因 owned plan 中的 URL 集合变化而提升 `boot-sessions.json.schema_version`；loader 只实现当前 schema，不包含
  M4.3 session 迁移/识别分支。残留不兼容文件以
  `state.schema_incompatible` 拒绝启动，提示开发者备份后显式清理；服务端不尝试恢复旧 callback，也不自动 rearm
  install generation；
- M4.4 新建 session 只包含最新 canonical URL 的 owned plan。M4.4 之后的同版本 daemon restart 仍按 M4.3 的
  capability-hash/plan 机制恢复，这与跨 M4.3→M4.4 兼容无关；
- 不新增任何旧路由版本字段、兼容截止时间或路由迁移状态文件。若代码、配置、fixture 或现行 M4.4/M5–M7
  章节仍引用旧 URL，构建/验收直接失败；M3–M4.3 历史章节只保留当时事实并明确由 M4.4 覆盖。

## 7. 路由注册与实现约束

用集中 `RouteSpec` 表替换当前顺序敏感的手写前缀分派。每项至少声明：method、path template、plane、auth policy、
cache policy、log class、handler。启动/测试时检查：

- 同 method 的模板不能重叠或被静态 wildcard 吞掉；
- 每条 node route 必须声明 node-bound auth 或显式 bootstrap exception；
- management route 必须继承 loopback guard；
- sensitive response 只能选择 no-store policy；
- repository 成功流量继承 M4.3 debug log class；
- route template 是日志/event 字段，原始含 query path 不进入日志；
- path segment 统一 percent-decode 一次、拒绝 encoded slash/NUL/dot segment 和超长 id/name。

建议拆分 `registerNodeDeliveryRoutes`、`registerManagementRoutes`、`registerArtifactRoutes`，但唯一 registry 负责冲突
检测和 404/405。不得通过调整 `if startsWith` 顺序修复冲突。

## 8. 对相邻里程碑的影响

| 里程碑 | 处理 |
| --- | --- |
| M4.3 | profile list/show 和新增 nodes/catalog/config/install-source/operation API 直接采用 §5 canonical 路径；BootSession 保留 owned plan/model revision，但 M4.4 切换要求先清空 M4.3 session state |
| M5 | rootfs 从首次交付起只实现 node-bound canonical URL；boot/rootfs bundle 生成器只输出 `/artifacts` 和 node API |
| M6 | NoCloud 新版本仍使用显式 leaf；PXELINUX 只输出 canonical artifact/install-config URL；profile/repository CRUD 与 distro 派生索引只读视图继承管理 collection 规则 |
| M7 | agent/finalizer 不复用 installer endpoint 或 capability；provision API 使用独立 management collections |

M4.4 不改变 M4.3 的 authentication proof、generation、distro/family、catalog logical name 或 ModelRuntime 事务语义；
它直接替换 URL/router/DTO 表面，并要求切换后重新创建使用最新 URL 的 BootSession。

## 9. 文件变更范围

| 文件/模块 | 主要变更 |
| --- | --- |
| `src/http/routes.zig`（新） | RouteSpec registry、模板匹配、405/Allow、plane/auth/cache/log policy |
| `src/http/server.zig` | handler 接入 registry；删除顺序敏感分派和旧 canonical 路径 |
| `src/http/client.zig` | management canonical URL；revision/plan/install-generation 请求 |
| `src/http/auth.zig` | node-bound rootfs、Subiquity exception policy；无旧 route 认证分支 |
| `src/state/boot_session.zig` | 提升 schema version，只实现 M4.4 canonical owned plan；不包含 M4.3 session loader/migrator |
| `src/http/dto.zig`（新） | v1 error/collection/operation envelope、ETag/idempotency 和 golden fixtures |
| `src/boot/grub.zig`、`src/boot/target.zig` | canonical boot-config/artifact/install-config URL |
| `src/profile/adapter/*.zig` | Kickstart/NoCloud event/log/hook URL |
| `src/main.zig` | preview 和 CLI management paths |
| `tests/http.sh`、route fixtures | 完整路由矩阵、auth/cache/log、旧 URL 全量 404 和 no-redirect 回归 |

## 10. 验收标准

1. 只有 canonical 路由进入方法/认证/handler 对照测试，未登记方法返回 405，未知 path 返回 404。
2. `/boot/config/:id` 删除，`/boot` 不再混合 API；registry 冲突测试证明静态 wildcard 不能接管节点 API。
3. Rocky boot config 只引用 kickstart leaf；Ubuntu seed 只引用 NoCloud 目录，错误 adapter leaf 返回稳定 404。
4. boot/install-config 响应包含 no-store/nosniff/referrer policy，日志中无 token、Authorization、password hash 或 body。
5. rootfs 必须同时匹配 path node、capability node 和 profile/source；跨节点 token 返回 403。
6. `/artifacts/**` 继续通过 catalog allowlist、normalize、symlink/traversal、Range/HEAD/ETag 回归。
7. management CLI 全部使用 canonical 路径，远端和伪造 X-Forwarded-For 仍返回 403；旧 management URL 返回 404。
8. profile list/show、node CRUD/show、catalog show/migrate、config set、install retry 在直接替换后行为与 M4.3 一致。
9. M4.4 切换前必须清空 M4.3 active session/checkpoint；残留旧 schema 以 `state.schema_incompatible` 拒绝启动且不
   rearm。M4.4 新 session 只生成 canonical URL，并能在 M4.4 同版本 daemon restart 后继续回调。
10. 所有生成器、示例、fixture 和 M5–M7 现行设计不再引用旧 URL；不存在依赖 redirect 的安装链路。
11. `zig build test`、HTTP/CLI integration、Rocky 9.7 和 Ubuntu 22.04 完整 PXE 回归通过；Ubuntu restart-resume
    只验证 M4.4 canonical hook URL，不运行旧 URL 兼容用例。
12. 代码、RouteSpec、生成器、CLI、示例、fixture 和现行 M5–M7 文档对旧 URL及兼容路由元数据均为零引用。
13. management v1 golden fixtures 固化 collection/error/operation/核心 DTO；201/202/204、Location、ETag/If-Match、
    cursor/limit、Idempotency-Key 和稳定 error/status 映射均有契约测试；operation/key 跨 restart 不丢失。开发期
    修改当前契约时，设计、server、CLI 和 golden fixture 必须在同一变更中更新。
