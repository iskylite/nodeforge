# NodeForge v0.4 统一设计

状态：设计冻结，按当前代码与本文件继续收口验证。

v0.4 在 v0.3 的 install、diskless 与 install-post 基线上增加四项能力：目标网络 topology、install first-boot、SN+IP draft Node discovery、容量与恢复闸。本版本采用 fresh replacement，不迁移旧部署状态。

## 1. 强制架构边界

### 1.1 rootfs 只有一个生产位置

rootfs 只能由 `nodeforged` 所在管理节点生成。唯一正式入口是：

```text
nodeforge profile rootfs build <profile>
POST /api/v1/management/profiles/:name/rootfs/build
```

管理 API 创建 durable `rootfs_build` operation，后台 worker 在服务端完成以下步骤：

1. 从固定 revision 的 install source、受管 repository、Profile software、provisioning bundle 与 SSH identity 编译 `rootfs_input_digest`；
2. 在服务端 staging 目录构建发行版 OS layer；
3. 执行 `rootfs_build` phase；
4. 注入 `nodeforge-agent`、first-boot unit 与固定身份材料；
5. 生成 squashfs，计算 SHA-512，解包深验；
6. 原子发布到服务端内容寻址 rootfs 目录并登记 ready artifact。

Profile 名、物理 Node、URL、时间戳和 operation id 不进入内容摘要。任何输入 revision、payload digest、软件闭包或身份 revision 改变都必须改变 `rootfs_input_digest`。

### 1.2 diskless Node 只消费 ready artifact

diskless 启动前，当前 Profile 的 `rootfs_input_digest` 必须已有 ready artifact。否则 readiness 和 boot-prepare 均 fail closed，不能临时生成，也不能下发一个让节点自行生成的计划。

diskless initrd 的职责仅限于：

- 获取并校验 BootConfig；
- 下载固定 SHA-512/size 的 ready squashfs；
- 建立只读 squashfs lower 与临时 writable overlay；
- 下载并校验 AgentPlan/payload；
- `switch_root` 后由 agent 收敛运行时状态。

diskless initrd 和目标 Node 禁止执行 DNF、APT、RPM transaction，禁止运行 `mksquashfs`，禁止生成或上传 rootfs。Node/Profile 模型不提供构建位置、构建资格、构建 ABI 或构建能力类别。

### 1.3 r97n0/r97n1 的验证角色

- `r97n0`：运行 `nodeforged` 的管理节点，负责服务端 rootfs 生成、DHCP/TFTP/HTTP 与状态持久化。
- `r97n1`：被部署和 diskless 启动的计算节点，只验证 ready artifact 的交付与运行。

角色在整个验证周期内保持不变。

## 2. token 与认证职责

token 的职责是辨别请求主体，并保护敏感控制或写操作；它不是给所有 HTTP 请求统一附加的通行证。

### 2.1 需要 token 的操作

- 获取或提交 install/first-boot 的 generation-bound 控制状态；
- 提交会推进状态机的 event、handoff、claim 等写操作；
- 读取包含 secret 的小型控制面资源；
- 在 DHCP peer-IP 不再可靠时证明仍是同一会话主体。

随机 boot-session capability 只存在内存，不持久化 raw token。daemon 重启后必须基于持久 authority 做 fail-closed join，并重新签发随机 capability。

跨重启确有需要的 event credential 由 daemon secret 确定性派生，绑定 deployment、resource、generation、audience、counter 和 expiry；只保存 hash/claim，不在 catalog、state、日志或命令行输出 raw token。

### 2.2 不需要 token 的数据面

- 已按 SHA/revision 固定的公开 boot artifact；
- 服务端本机 rootfs worker 访问的 `file://` 受管 repository；
- 已由活动 DHCP lease、boot session、Node binding 与 artifact digest 共同约束的大对象读取。

DNF/APT repository 请求不得注入 Bearer、session header、`http_headers` 或派生 token。服务端 rootfs worker直接使用本机受管 repository 路径，不经过节点认证链路。

## 3. schema 与 fresh replacement

v0.4 使用：

| 对象 | 版本 |
|---|---:|
| AppConfig | 5 |
| catalog | 6 |
| BootConfig | 3 |
| AgentPlan | 2 |
| InstallFirstBootPlan | 1 |
| NodeDiscoveryState | 1 |

v0.4 不读取或迁移旧版本运行状态。setup 通过 root marker 与 schema version 明确 fresh replacement 边界；重建前必须备份，未显式 purge 不删除 catalog、assets、work、logs 与 backups。

固定 DTO 上限：BootConfig 64 KiB、AgentPlan 256 KiB、InstallFirstBootPlan 256 KiB、管理写请求 64 KiB。JSON 默认拒绝未知字段；兼容读取必须在具体 schema 中显式声明。

## 4. topology

Node 的 PXE bootstrap 身份和目标系统 topology 分层：

- DHCP/TFTP 使用 immutable bootstrap MAC、lease 与启动 architecture；
- target topology 描述 interfaces、bonds、VLANs、routes、DNS 与 search domains；
- bootstrap MAC 必须唯一落到一个物理 interface；
- deployable topology 必须有唯一可达管理面的默认路由；
- interface/bond/VLAN 名称、成员关系、MTU、地址和 route 必须严格校验；
- topology digest 进入 Node plan digest，漂移必须生成新 install generation 或新 diskless delivery。

安装器只负责把 canonical topology 写入目标系统；first-boot 验证并完成需要目标内核/驱动的切换。失败不得回写成成功，也不得用 DHCP 当前地址替代设计目标。

## 5. install first-boot

install generation 成功写盘后，若 provisioning bundle 含 `first_boot` step，则 deployment 进入 first-boot pending，而不是直接完成。

InstallFirstBootPlan 固定绑定：deployment id、Node、generation、plan digest、步骤、payload digest/size、expiry。安装器通过 generation-bound handoff 把一次性 capsule 写入目标系统；首次从本地盘启动后，`nodeforge-agent` 获取计划并执行 canonical step。

状态推进使用 event sequence、expected state、event id 与 canonical body digest 做 CAS。重复相同请求幂等成功；同 event id/body 漂移、过期、错误 generation 或越权主体必须拒绝。

所有 step 成功后才把 deployment generation 标记为完成。重启时从 durable journal 恢复；已完成 step 不重复执行，失败 step 按显式 retry policy 处理。

## 6. SN+IP draft Node discovery

未知 MAC 可在 discovery policy 允许时获得受限 discovery 启动，不获得 install/diskless profile 交付。probe 上报序列号、MAC、观测 IP、architecture、固件与 NIC facts；服务端生成 draft Node observation。

claim 必须由 loopback management API 发起，并同时满足：

- observation 未过期；
- serial、MAC、IP 与 architecture 一致且无冲突；
- 目标 Node id 尚未占用；
- operator 提供明确 Profile/hostname 等必要字段；
- catalog revision CAS 成功。

claim 后才创建正式 Node。discovery token 不能升级为 install/diskless capability，draft observation 也不能绕过 deploy/generation gate。

## 7. capacity 与 deadline

容量限制覆盖 boot session、diskless delivery、durable operation、first-boot journal、discovery observation、HTTP response 和 worker queue。达到上限时应在创建副作用前拒绝，并返回稳定错误与可重试条件。

deadline 分为：

- boot-session/delivery TTL；
- operation 排队与执行 deadline；
- first-boot handoff/plan/event expiry；
- discovery observation/claim expiry；
- 单个 HTTP 请求 idle timeout。

运行期 lease 使用 monotonic time；持久记录保存 UTC 锚点，恢复时校验 wall-clock 未倒退并换算剩余预算。配置变化只影响新对象，不能延长在途对象。

## 8. 持久化与恢复

每个 durable domain 都有唯一事实源：

| Domain | 事实源 |
|---|---|
| install generation | `deployment-control.json` |
| boot session checkpoint | `boot-sessions.json` |
| diskless delivery | `diskless-delivery.json` |
| rootfs operation | `operations.json` |
| ready rootfs artifact | `rootfs-artifacts.json` + 内容寻址文件 |
| install first-boot | `install-first-boot.json` |
| discovery | `node-discovery.json` |

写入采用临时文件、fsync、atomic rename 和 parent directory sync。恢复必须按 immutable id/digest/generation 做 join；缺失、终态冲突、过期、digest 漂移或 checkpoint 超前一律 fail closed。

rootfs operation 在 daemon 中断后标记 `operation.interrupted`，不会转移到计算节点继续。操作员重新提交相同 immutable input 后，由 nodeforged 服务端重新执行或命中 ready cache。

## 9. HTTP 与 CLI

management API 只接受 direct loopback peer，不信任代理 header。Node API 只接受明确的 bootstrap/capability 认证。大对象支持固定 ETag、size 与严格单 Range；禁止 redirect 到未绑定来源。

正式 rootfs 命令：

```text
nodeforge profile rootfs plan <profile>
nodeforge profile rootfs build <profile> [--if-input-digest <hex>] [--new-ssh-keys] [--detach]
nodeforge profile rootfs status <profile>
```

不存在预制 squashfs 的 register/import API。测试也必须通过 nodeforged build operation
得到 ready artifact，不能维护第二条生产路径或直接伪造 production state。

## 10. 完成标准

v0.4 只有在以下条件全部满足时才可发布：

1. 全部 Zig 单元/集成测试与 v0.4 contract gate 通过；
2. 源码和产物不含远程 rootfs 生成模式、节点构建资格、相关路由或 CLI；
3. Rocky 与 Ubuntu rootfs 均在 nodeforged 服务端真实生成并深验；
4. r97n1 只下载 ready squashfs，initrd/agent 日志中没有 package-manager 或 squashfs 生成行为；
5. topology、first-boot、discovery、容量、恢复和 v0.3 回归有真实证据；
6. raw token 不进入 repository 请求、catalog、持久 state、日志或命令行；
7. 24 小时 soak 无状态泄漏、重复副作用或未界定增长。

具体证据采集顺序见 [`V0_4_FULL_VALIDATION_RUNBOOK.md`](../validation/V0_4_FULL_VALIDATION_RUNBOOK.md)。
