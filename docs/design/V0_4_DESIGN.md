# NodeForge v0.4 统一设计

状态：设计冻结，按当前代码与本文件继续收口验证。

v0.4 在 v0.3 的 install、diskless 与 install-post 基线上增加能力：目标网络 topology、install first-boot、SN+IP draft Node discovery、容量与恢复闸，以及**可选 rootfs staging 保留与基于保留树再打包**（运维特需，不改变「rootfs 仅服务端生成」边界）。本版本采用 fresh replacement，不迁移旧部署状态。容量目标按部署波次、传输并发和实现安全天花板分层定义，不把某个压力测试点写成产品最高上限。

> **v0.4.1（已实现，不改写 v0.4 闸）**：保留树上规范会话（`profile rootfs staging enter` / `exec`、cgroup 挂载与限额、树内核导入等）。见 [`V0_4_1_DESIGN.md`](V0_4_1_DESIGN.md)。  
> **v0.4.2（设计中，不阻断 v0.4 / v0.4.1）**：rootfs **OS 层** `os_layer.mode=minimal|full`、full 命名 qualifier、交互软件配方、`software.include_optional`。见 [`V0_4_2_DESIGN.md`](V0_4_2_DESIGN.md)。  
> **v0.4.3（设计中）**：diskless 上 **`nodeforge-agent inspect`**（只读本机，不连 daemon）。见 [`V0_4_3_DESIGN.md`](V0_4_3_DESIGN.md)。  
> **v0.4.4（设计中）**：**nodeforge 指定节点备料并 register**；节点上 **agent 只做本机 rootfs/stage 构建**。见 [`V0_4_4_DESIGN.md`](V0_4_4_DESIGN.md)。  
> **v0.4.5（骨架）**：克隆打包与本地盘恢复（细节待定）。见 [`V0_4_5_DESIGN.md`](V0_4_5_DESIGN.md)。

## 1. 强制架构边界

### 1.1 rootfs 只有一个生产位置

rootfs 只能由 `nodeforged` 所在管理节点生成。唯一正式入口是：

```text
nodeforge profile rootfs build <profile>
POST /api/v1/management/profiles/:name/rootfs/build
```

管理 API 创建 durable `rootfs_build` operation，后台 worker 在服务端完成以下步骤：

1. 从固定 revision 的 install source、受管 repository、Profile software、provisioning bundle 与 SSH identity 编译 `rootfs_input_digest`；
2. 在服务端**临时** staging 目录构建发行版 OS layer；
3. 执行 `rootfs_build` phase；
4. 注入 `nodeforge-agent`、first-boot unit 与固定身份材料；
5. 生成 squashfs，计算 SHA-512，解包深验；
6. 原子发布到服务端内容寻址 rootfs 目录并登记 ready artifact；
7. （可选）在请求 `keep_staging` 时，将解包树提升为规范保留路径并登记索引（见 §1.1.1）。

Profile 名、物理 Node、URL、时间戳和 operation id 不进入内容摘要。任何输入 revision、payload digest、软件闭包或身份 revision 改变都必须改变 `rootfs_input_digest`。

默认构建结束后删除临时解包目录；**不**默认保留可 chroot 的原始树。

### 1.1.1 可选 staging 保留与 from-staging 再打包

实验室/特需场景允许操作员在管理节点上 chroot 进解包树做一次性调整，再重新打包发布。这仍是**服务端**路径，不引入节点侧 rootfs 构建，也不提供预制 squashfs import。

| 能力 | CLI | API | 行为 |
|---|---|---|---|
| 保留解包树 | `profile rootfs build … --keep-staging` | `POST …/rootfs/build` body `keep_staging: true` | 成功后将树提升到 `<install-root>/work/rootfs-staging/<rootfs_input_digest>/`，并写入 `state/rootfs-stagings.json` |
| 基于保留树再打包 | `profile rootfs build … --from-staging` | body `from_staging: true` | 跳过 OS 层与 rootfs-build 步骤，仅对保留树 `mksquashfs` + 深验；允许**替换**同一 digest 下已有 ready 制品（手改后 content_sha512 可变） |
| 查询 | `profile rootfs staging list` / `show <profile>`；`status` 附带 staging 字段 | `GET /api/v1/management/rootfs/stagings`；`GET …/profiles/:name/rootfs/staging`；`GET …/rootfs` | 返回 path、kept_at、ready（磁盘树是否仍可用）等 |
| 清理 | `profile rootfs staging remove <profile>` | `DELETE …/profiles/:name/rootfs/staging` | 删索引并删磁盘树 |

约束：

1. **保留树不是交付物**：diskless 节点只下载 ready squashfs；initrd 不得 chroot 到管理节点保留树。
2. **`rootfs_input_digest` 语义不变**：仍只反映 Profile build projection。手改保留树再 `--from-staging` 不会改 digest，但会更新该 digest 对应的 CAS 文件与 `content_sha512`（`replace`）。正式可复现定制仍应写入 Profile `rootfs-build` 步骤。
3. **`from_staging` 与 `new_ssh_keys` 互斥**（轮换 identity 会改变投影 digest，与「从旧树重打包」语义冲突）。
4. **缺树 fail closed**：`from_staging` 时无可用保留树返回 `rootfs.staging_not_found`。
5. **空间与生命周期**：保留树可能 GB 级；由操作员显式 `staging remove` 清理；`--purge-all` 删除 `work/` 时一并清除。
6. **缓存短路**：普通 build 在 ready 命中时不重建；`keep_staging` 在「制品已有且保留树已有」时可短路，仅缺树时再跑 full build 以产出树；`from_staging` 不走 ready 短路。

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

目标网络 topology 是 Node direct owner，并明确分成两层：

- bootstrap 层只供 DHCP/TFTP/PXE 使用，包含 immutable bootstrap MAC、lease 与启动 architecture；
- target 层描述 interfaces、bonds、VLANs、routes、DNS 与 search domains；
- bootstrap MAC 必须唯一落到一个物理 interface；
- deployable topology 必须有唯一可达管理面的默认路由；
- interface/bond/VLAN 名称、成员关系、MTU、地址和 route 必须严格校验；
- topology digest 进入 Node plan digest，漂移必须生成新 install generation 或新 diskless delivery；配置变化不能修改在途 generation/delivery。

canonical topology 必须在两条交付路径中完整落盘，不能只校验、进入 digest 和 AgentPlan 后在渲染阶段静默丢弃结构化字段：

- install 由 kickstart/Ubuntu adapter 渲染全部 interfaces、bonds、VLANs、routes、DNS；需要安装后命令的格式由 adapter 的 `%post` 等受控阶段完成；
- diskless 由 `node-apply renderNetwork` 写入 overlay；多 interface、bond、VLAN 与按 `route.interface_id` 绑定的 route 必须与 install 使用相同字段语义；
- netplan 优先使用原生 `ethernets`/`bonds`/`vlans`，ifcfg/keyfile 使用 NetworkManager 对应语法；无结构化 topology 时保留现有单 NIC 兼容路径。

NodeForge 使用 ISO 自带 installer kernel；标准 ISO 安装中 installer kernel 与目标 kernel 一致，`switch_root` 也只切换 rootfs 而不切换内核。模型不提供 `runtime_kernel` 或由 first-boot 完成内核/驱动切换的机制。目标网络是否实际连通属于交换机、集群网络与运维验证，不作为 install first-boot 的部署成功闸，也不得用 DHCP 当前地址替代设计目标。

## 5. install first-boot

必须区分三个执行时刻，不能把它们统称为同一个 first-boot：

- **install first-boot（v0.4）**：安装写盘完成、从本地盘启动后执行 generation-bound `InstallFirstBootPlan` 和 canonical steps；
- **diskless node-apply（v0.2）**：PXE RAM 启动并 `switch_root` 后、真正 init 前执行，`renderNetwork` 在此阶段把 target topology 写入 overlay；这不是 diskless first-boot；
- **diskless systemd first-boot（v0.2）**：真正 init/systemd 启动后执行 diskless canonical postprocess。

三者的计划类型、凭据、存储、事件和失败投影不同，不得共用状态机或互相推导成功。

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

## 7. capacity、deadline 与扩展档位

“并发部署”定义为一个 nodeforged 实例同时维护的、尚未进入终态的 install 与 diskless 节点总数，即部署波次；它不等于同时打开的 TFTP transfer 数或 HTTP connection 数。除非单独声明，install 与 diskless 共用该总量，而不是各自再获得一份额度。

v0.4 的容量口径固定为：

| 档位 | 规模 | 契约 |
|---|---:|---|
| 实现容量基线 | 256 逻辑节点部署波次 | install、diskless、128+128 mixed 均以 workload harness 进入发布闸 |
| 标准合成扩展 | 512 逻辑节点部署波次 | install、diskless、256+256 mixed 的配置覆盖测试进入发布闸 |
| 合成压力验证点 | 1024 逻辑节点部署波次 | workload harness 记录退化和资源曲线，不是产品最高上限 |
| v0.4 实现安全天花板 | 2048 active/managed entries | 当前固定状态表的编译期边界；运行时覆盖超过此值必须在启动前拒绝 |

因此“512 以上可配置覆盖”在 v0.4 中准确表示为可覆盖到 2048；1024 只是其中一个验证点。若以后要求超过 2048，必须调整构建时天花板或把相应固定数组改为有界动态/分片存储，不能宣称无上限覆盖。

当前 VMware Fusion 只有 r97n0/r97n1 双机环境，不能证明 256/512 台真实 PXE 节点的 DHCP/TFTP 风暴、并发安装、rootfs 下载吞吐或端到端完成时间。v0.4 发布只要求单节点真实 install/diskless 功能闭环与上述逻辑节点 workload；256/512 真实生产规模验证按统一清单的 [`ENV-V04-PRODUCTION-SCALE`](DEFERRED_DESIGN_INDEX.md) 延后。在取得规模环境证据前，文档和发布说明只能称“实现容量基线/合成扩展验证”，不能称为已验证的生产规模保证。

各 domain 独立限额、独立释放，超限一律在创建副作用前 fail closed：

| Domain | 默认/派生目标 | v0.4 天花板与要求 |
|---|---:|---|
| DHCP lease / boot session | 按 subnet、受管节点和显式覆盖派生 | 2048；256 场景至少使用容纳 256 lease 的 `/23` 地址池，512 场景至少使用 `/22`，1024 场景至少使用 `/21` |
| status / inventory / deployment control | 按受管节点数派生 | 2048 |
| diskless active delivery | `diskless_delivery_max_sessions` 默认 512，可配置 | 2048；终态立即释放 active slot，超时非终态由 reaper 清理 |
| install active first-boot | effective 为 `max(512, managed capacity)` | 2048；acknowledged terminal 不得继续占 active slot，复用既有 managed capacity 覆盖而不新增公共 schema 层级 |
| terminal per-node summary | 投影到既有 node status / deployment control，按受管节点数派生 | 2048；保存每个 Node 最新终态供 node-list 投影，不能使用 256 条环形记录作为权威状态或新增 durable domain |
| TFTP active transfer | 默认 `max(128, 2×CPU)`，可配置 | 只限制同时传输小文件的数量；客户端重试/错峰可服务更大的部署波次 |
| HTTP accepted connections | 默认 1024，可配置 | 接入 listener 的真实 `max_clients`，并同步设置进程 FD limit；不是节点容量 |
| durable operation / worker queue / discovery | 各自固定上限 | 不因部署波次机械扩成 per-node operation |

256 实现容量基线不能通过“数组恰好容纳 256 条”实现：active store 必须为重试、波次交叠和释放延迟留出余量。install first-boot 和 diskless delivery 均把 active authority 与 terminal summary 分开；终态事实可保留，但不得继续消耗 active admission。

diskless delivery 不能只把 64 个内嵌大对象的数组机械扩成 512/2048。现有 Session 内嵌 16 KiB AgentPlan buffer，而本设计的 AgentPlan DTO 上限是 256 KiB；实现不能靠继续放大 in-session buffer 解决二者差异，必须满足：

- active store 位于 heap 或采用其他有界存储，不在请求栈上创建完整 Session 大数组；列表/查询只复制轻量 view 或摘要；
- immutable AgentPlan 在既有 diskless delivery domain 内按 digest 只写一次并由 session 引用，不能在每次 snapshot/checkpoint 中按最大容量整体复制；
- 单个 lifecycle event 不得同步重写所有 active AgentPlan；在同一 durable domain 内采用 per-session checkpoint、追加 journal 后有界 compact，或等价的增量持久化，不为此增加新的 durable domain；
- checkpoint 读取上限按格式的合法最大值设计，并有 256/512/1024 恢复测试；
- `DisklessSessionCapacity` 显式映射为 `capacity.exhausted` 和 HTTP 503。

install first-boot active store 同样需要 effective capacity、终态释放和过期 reaper。install-post journal 必须有终态 retention/compact 规则，不能让重复部署波次导致内存、JSON 文件与每次保存成本无界增长。

单 listener 无法在 accept 时识别管理路由，因而不提供无法兑现的 `management_reserved_connections`。管理面继续由 direct loopback 认证；若未来需要独立连接保留，必须拆分 listener/socket 或引入可证明的请求层 admission。

容量限制覆盖 boot session、diskless delivery、durable operation、first-boot journal、discovery observation、HTTP response 和 worker queue。容量错误必须稳定、可观测并说明可重试条件。

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
| diskless active delivery | `diskless-delivery.json` 所属既有 domain 内的 per-session checkpoint 或有界增量 journal；AgentPlan 按 digest 只写一次并引用 |
| diskless/install terminal summary | 复用既有 `node-status.json` / `deployment-control.json` 投影，不新增 durable domain |
| rootfs operation | `operations.json` |
| ready rootfs artifact | `rootfs-artifacts.json` + 内容寻址文件 |
| optional rootfs staging tree | `rootfs-stagings.json` + `work/rootfs-staging/<digest>/`（非交付物，仅管理节点特需） |
| install first-boot | `install-first-boot.json` |
| discovery | `node-discovery.json` |

快照写入采用临时文件、fsync、atomic rename 和 parent directory sync；同一 domain 内的增量 journal 必须有校验、截断恢复和有界 compact。这些内部布局调整不增加 AppConfig/catalog/DTO schema 或新的 durable domain。恢复必须按 immutable id/digest/generation 做 join；缺失、终态冲突、过期、digest 漂移或 checkpoint 超前一律 fail closed。恢复后的 terminal authority 不能复活为 active，但投影到既有状态域的最新 terminal summary 必须继续可查询。

rootfs operation 在 daemon 中断后标记 `operation.interrupted`，不会转移到计算节点继续。操作员重新提交相同 immutable input 后，由 nodeforged 服务端重新执行或命中 ready cache。

## 9. HTTP 与 CLI

management API 只接受 direct loopback peer，不信任代理 header。Node API 只接受明确的 bootstrap/capability 认证。大对象支持固定 ETag、size 与严格单 Range；禁止 redirect 到未绑定来源。

HTTP listener 必须实际接入可配置 `max_connections`/`max_clients`，默认 1024，并在生成的 systemd unit 中设置与配置及运行开销匹配的 `LimitNOFILE`。HTTP 连接数、TFTP transfer 数和部署波次分别观测与限流，不能相互替代。合成 workload 证明 admission、错误语义和资源有界，不证明大规模 rootfs/ISO 下载性能；真实吞吐还依赖磁盘、网卡、交换机和主机资源，统一由延期的生产规模验证给出证据。

正式 rootfs 命令：

```text
nodeforge profile rootfs plan <profile>
nodeforge profile rootfs build <profile> [--if-input-digest <hex>] [--new-ssh-keys] [--keep-staging] [--from-staging] [--detach]
nodeforge profile rootfs status <profile>
nodeforge profile rootfs staging list
nodeforge profile rootfs staging show <profile>
nodeforge profile rootfs staging remove <profile>
```

对应 management API：

```text
POST /api/v1/management/profiles/:name/rootfs/build   # body 可含 keep_staging / from_staging
GET  /api/v1/management/profiles/:name/rootfs
GET  /api/v1/management/profiles/:name/rootfs/staging
DELETE /api/v1/management/profiles/:name/rootfs/staging
GET  /api/v1/management/rootfs/stagings
```

不存在预制 squashfs 的 register/import API。`--from-staging` 只消费本机**由 keep-staging 留下**的解包树，不是外部 rootfs 导入。测试也必须通过 nodeforged build operation 得到 ready artifact，不能维护第二条生产路径或直接伪造 production state。

## 10. 完成标准

v0.4 只有在以下条件全部满足时才可发布：

1. 全部 Zig 单元/集成测试与 v0.4 contract gate 通过；
2. 源码和产物不含远程 rootfs 生成模式、节点构建资格、相关路由或 CLI；
3. Rocky 与 Ubuntu rootfs 均在 nodeforged 服务端真实生成并深验；
4. r97n1 只下载 ready squashfs，initrd/agent 日志中没有 package-manager 或 squashfs 生成行为；
5. topology、first-boot、discovery、容量、恢复和 v0.3 回归有真实证据；
6. raw token 不进入 repository 请求、catalog、持久 state、日志或命令行；
7. 关键资源边界与重复波次测试通过：workload harness 连续 3 轮 256 mixed 同 Node 逻辑波次结束并完成 retention/compact 后，allocator leak check、session、queue、journal、terminal summary、FD、线程、checkpoint、plan 目录和 state 文件保持确定性有界；512 合成扩展通过，1024 合成压力档位给出资源曲线。测试仍采集当前/峰值 RSS，但测试进程受共享 allocator 与 OS 高水位页面影响，其跨轮回落稳态按统一延期清单的 `ENV-V04-RSS-STEADY` 在独立 `nodeforged` 进程验证，不单独阻断 v0.4，也不能替代其他资源边界。真实 256/512 节点生产规模验证仍按 `ENV-V04-PRODUCTION-SCALE` 延期。

具体证据采集顺序见 [`V0_4_FULL_VALIDATION_RUNBOOK.md`](../validation/V0_4_FULL_VALIDATION_RUNBOOK.md)。
