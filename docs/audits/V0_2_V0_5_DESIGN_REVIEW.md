# NodeForge v0.2-v0.5 设计评审（基于 v0.1 M0-M4.13 实现）

状态：2026-07-22 设计审计基线。本文回答“现有代码能复用什么、后续版本还缺什么、按什么顺序实现”。
本文是历史快照；下文旧版 v0.3/BIOS 范围只用于追溯。当前路线已将 BIOS PXELINUX
剥离为 v0.5 后的独立延后项，范围与 schema 编号以
[`V0_2_1_PLUS_ROADMAP.md`](../design/V0_2_1_PLUS_ROADMAP.md) 为准。
权威行为以各版本总纲及其职责分册为准：v0.2 入口是 [`V0_2_DESIGN.md`](../design/V0_2_DESIGN.md)，
diskless 架构细节由 [`DISKLESS_FINAL.md`](../design/DISKLESS_FINAL.md) 负责。
当前实现状态与后续版本编号以
[`CURRENT_IMPLEMENTATION_ALIGNMENT_REVIEW.md`](CURRENT_IMPLEMENTATION_ALIGNMENT_REVIEW.md) 和
[`V0_2_1_PLUS_ROADMAP.md`](../design/V0_2_1_PLUS_ROADMAP.md) 为准；下表中的 BootConfig
版本号已按当前 v0.2.0 使用 v3 的事实重排。

## 1. 代码事实基线

v0.1 已提供可直接复用的骨架，而不是 v0.2 的完整实现：

| 已实现能力 | 代码事实 | v0.2 复用方式 |
|---|---|---|
| 强类型 catalog/config schema v3 | `model.zig`、`catalog/schema_v3*`、`config/schema_v3_dto.zig` | 新增严格 v4 parser/migration，不放宽 v3 |
| effective compiler / plan digest | `profile/effective.zig`、`state/plan_digest.zig` | 增 diskless tagged branch，保持唯一编译入口 |
| DHCP/TFTP/HTTP 内置协议栈 | `dhcp/`、`tftp/`、`http/` | 加 rootfs ready gate、scoped routes、状态 producer |
| BootSession 关联、capability auth | `state/boot_session*.zig`、`http/auth.zig` | 改为 canonical reducer；补 diskless 持久恢复与分域 token |
| deployment/status/event 投影 | `state/deployment_control.zig`、`node_status.zig`、`events.zig` | 分离传输 phase 与 first-boot deployment 状态 |
| typed CLI/资源 mutation | `cli/`、`config/*mutation.zig`、`http/management.zig` | 为 v4 Profile/bundle/rootfs 注册完整 spec，不写专用旁路 parser |
| install adapters 与 target-system | `profile/adapter/{kickstart,ubuntu}.zig`、`profile/render.zig` | 抽出共享 target projection renderer，initrd 消费同一结果 |

以下只是预留，不能算 v0.2 进度：`BootKind` 当前只有 install；BootSession 中 diskless phase/event enum 没有
initrd producer；`AssetKind.rootfs/nodeforge_initrd` 与 `BootBundleConfig` 没有 builder、manifest、readiness 和 E2E；
`boot_session_store.zig` 明确不恢复 diskless；`build.zig` 没有 initrd/agent 产物。

## 2. 设计问题与本轮结论

| 级别 | 原问题 | 收敛结论 |
|---|---|---|
| P0 | v0.2 依赖未来 M7 schema v6 才能表达自己的 first-boot/rootfs-build | v0.2 schema v4 一次包含 Profile kind 与两 phase；v0.3=v5、v0.4=v6、v0.5=v7 |
| P0 | agent 应是服务端配置执行框架，但旧模型由 initrd 下载 projection/payload，agent 退化为本地脚本 runner | 拆最小 BootConfig 与 immutable AgentPlan；initrd 只拉 rootfs 并交接 plan locator，agent pre-init 以 session-bound `agent:read` 拉取并校验 plan/全部 payload，清除读 token 后执行；first-boot 不联网 |
| P0 | 当前预留 `BootBundleConfig.rootfs` 造成 Profile/effective/rootfs 构建环 | v4 bundle 固定 source+prepared kernel+initrd revisions；DeliveryManifest 绑定派生 rootfs |
| P0 | v0.1 `AssetKind.kernel` 是 installer kernel，未必有最终 rootfs 的匹配 modules ABI | v4 新增 runtime-kernel prepare/resource，pin 本地 kernel package 与 modules closure |
| P0 | “每次启动执行”却用不含 session 的幂等键跨启动跳过 | 幂等键加入 boot session，只在当次 `/run` journal 去重 |
| P0 | 只说 Range/daemon restart-resume，没有恢复事实源 | 持久 delivery record + token hash + immutable snapshot；原 token 不落盘；If-Range 规则明确 |
| P1 | squashfs 被误认为无需内存预算 | v0.2 lower 下载到 tmpfs，必须预算 compressed image + upper + initrd reserve |
| P1 | 网络“接管同一地址”缺少 adopt/lease 规则 | 固定启动 NIC/MAC/address/route，DHCP lease handoff；renderer 不先 flush 地址 |
| P1 | 状态可由模糊客户端事件任意推进 | CAS reducer + event_seq + 唯一 producer/证据表 |
| P1 | rootfs ready 可能看见半成品 | staging -> validate -> object rename -> manifest ready；v0.2 已发布 object 只增不删 |
| P2 | `diskless.running` 与 first-boot success 混淆 | running 只表示切根/PID1/agent 已启动；step 结果仅作 postprocess 附属摘要 |
| P0 | 任意 Node 变更被误写成同时改变 desired/rootfs input digest | 按 build-safe 与 per-Node projection 分类；identity/network/secret/overlay 不分裂 rootfs cache |
| P0 | v0.5 同时允许 squashfs 传输又令 compressed=uncompressed | 固定两种 mode 共用同一 squashfs cache artifact；mode 只改变 materialization |
| P1 | 异步 operation 只有资源局部查询且 id 格式过早冻结 | 增统一 opaque `operation show/wait`；资源 status 只作上下文投影 |
| P1 | v0.3 install-post retry/status 套用 diskless session 语义 | 以 install generation 标识；仅 installer execution 内自动 retry，耗尽后 install.failed |
| P1 | v0.3 callback credential 只有 claim，raw token 交付路径不明 | 使用 per-generation credential capsule 以 0400 文件交付；服务端只持 hash，禁止 cmdline/catalog/log 泄漏 |
| P1 | v0.4 节点构建与“无远程任务下发”矛盾 | 收敛为临时 PXE rootfs 构建 operation；不远程重启、不向运行中 agent 下发任务，产物只回服务端 cache |
| P0 | v0.4 选择物理 builder 后才可能确定 capability class，导致 build CAS 不稳定 | compiler 在 plan 前唯一导出 class/ABI 并纳入 input digest；物理 Node 只匹配 immutable operation snapshot |
| P1 | v0.5 initrd 无法从不变的 BootConfig 得知 mode | v0.4 bootstrap transport 升 BootConfig v4、target topology 升 AgentPlan v2；v0.5 materialization 升 BootConfig v5 并要求 feature token |
| P0 | v0.5 ram_rootfs 峰值漏算压缩副本且重复扣 initrd 已计入的 kernel 内存 | 规范化 available budget；峰值同时计 compressed/uncompressed，冻结 checked required-min 公式 |
| P0 | 新 DHCP XID、BootConfig 重取与外部鉴权失败缺少准确 correlation/归责边界 | XID 可登记 transaction alias；BootConfig bounded replay；无 verified claim 的失败不得污染 victim session |
| P0 | hash-only capsule 在 daemon restart 后被笼统宣称可恢复 | raw token 只驻内存；交付前/中未完整取得即 `recovery_incomplete`，客户端已取得后才可凭 hash 恢复 |
| P0 | v0.4 bond/VLAN 不能承载 L3，static PXE 又没有 session bootstrap 路径 | 三类 link 共用 tagged IPv4；static 首次 config 请求以 source/L2 binding 和 CAS 创建 BootSession/capsule |
| P0 | v0.4 网络切换、builder upload 与 install token exchange 缺少中断事务 | authenticated topology cutover；builder `.part` lease/recovery；first-boot `exchanging` 后 event ack 才 spent |
| P0 | schema rollback 被当作任意 downgrade，可能丢 v5-v7-only state | finalize 前 journal rollback；finalize 后 representability preflight，不可表达返回 `migration.non_representable` |
| P0 | v0.5 删除压缩临时制品与升级前 active v4 session 未形成验收契约 | handoff 前删除 `.part` 并检查引用；旧 immutable v4 session 跨升级继续到终态 |
| P0 | Node software override 不进共享 rootfs，若无固定执行契约会分叉交付路径 | 全部 target-system/software/service/security 差量编译为 immutable node-apply，由最终 rootfs 的 agent pre-init 按 pinned local repository/exact add-remove closure 重放；initrd 只 handoff，clone Profile 仅作公共重差异的效率优化 |
| P0 | initrd 写静态差量会复制 TargetSystem/renderer/package 语义，形成第二套配置引擎 | nodeforged 编译唯一 AgentPlan；initrd 只 transport/verify/mount/handoff locator；`switch_root` 进入 agent pre-init，从服务端取 plan 后应用全部 Node override 并由原进程 exec 真正 init |
| P0 | diskless Profile password 若沿用 install per-session salt，同一 input 会产生不同 shadow/rootfs | password credential revision 生成并持久复用 `$6$` hash；仅显式改密码才换 revision/digest |
| P1 | Node key/hosts override 可无意破坏 Profile 域 SSH 互信 | 自动 client public key 设为 mandatory；effective hosts 改变时用共享 host key 重算该节点 known_hosts |
| P1 | 操作流程仍保留旧 asset import 与 `item add --phase` 双语法 | 统一到 CLI 事实源：`import NAME --from-file` 与唯一 `steps` collection 的 `phase=...` ItemSpec |
| P1 | v0.5 把迁移后的 squashfs mode 写成“不声明”，且未固定 owner | v0.5 两种 mode 都显式取值；mode 是 Profile-only policy，不提供 Node override |
| P1 | v0.4 builder placement 被纳入 Node desired digest，导致无内容变化的 deployment drift | placement 仅进 Profile revision/operation policy；class/ABI 进 rootfs input，物理 Node 只进 operation snapshot |
| P0 | 声称 diskless 复用完整 Node override，但细表禁 repository 且缺 per-Node postprocess bundle | software 全 collection 解析为 pinned node-apply closure；新增 `overrides.diskless.provision.bundle`，first-boot-only payload 由 agent pre-init 按 session AgentPlan 预取校验，first-boot 本地执行 |

## 3. 版本依赖与边界

| 版本 | schema | 必须交付 | 不得偷跑 |
|---|---:|---|---|
| v0.2 | 4 | UEFI diskless、builder、initrd、diskless agent、rootfs-build/node-apply/first-boot、恢复/失败闭环 | BIOS、多 NIC、rootfs mode |
| v0.3 | 5 | BIOS PXELINUX install、`firmware.mode`、install-post、明确 distro capability matrix | install agent、多 NIC |
| v0.4 | 6 | ItemSpec 网络 topology、BootConfig v4 + AgentPlan v2、量化容量目标、临时 PXE rootfs 构建节点、install first-boot generation | 可切 rootfs 形态 |
| v0.5 | 7 | `squashfs_overlay|ram_rootfs`、BootConfig v5、共享 artifact 与双模式内存预算 | NFS/iPXE/persistent overlay |

v0.3 的 BIOS 与发行版扩展应拆成两个可独立验收的 feature slice；共同点只有版本发布，不应让新增发行版阻塞
PXELINUX，也不应让 BIOS 绕过 adapter matrix。v0.4 的网络拓扑、容量、临时 PXE rootfs 构建节点和 install agent 是四个风险域，
schema 可同版但实现/验收必须独立。v0.5 只改变 rootfs materializer；BootConfig 必须显式升版承载 mode，auth、状态机与
agent 不分叉。

## 4. v0.2 推荐实施顺序

1. **V2.0 schema/contract**：v3 -> v4 plan/apply/rollback；Profile tagged kind；bundle tagged action/phase；
   golden CLI/API/parser negative tests。
2. **V2.1 effective/readiness**：DisklessEffectivePlan、digest exclusion/inclusion tests、boot bundle/feature/memory gate。
3. **V2.2 builder**：sandbox、local-only、manifest、atomic publish、容量告警、并发与 crash recovery。
4. **V2.3 session/auth**：canonical reducer、delivery record、scoped token、failure ledger/quarantine/retry。
5. **V2.4 protocol delivery**：DHCP rootfs gate、TFTP identity、BootConfig v3、rootfs HTTP Range/ETag/error contract。
6. **V2.5 initrd**：dracut module、10 步 transport/verify/mount/handoff pipeline、switch_root、console diagnostics；不含 target-system projector。
7. **V2.6 agent**：pre-init Node apply + exec init、rootfs 内 fixed-revision first-boot steps、per-session journal、bounded actions、append-only events、本地结果。
8. **V2.7 system validation**：QEMU UEFI x86_64/aarch64、VMware/实机、断流/损坏/重启/内存/越权/容量 matrix；
   完整 v0.1 install regression。

每个 slice 都必须有代码、自动化、故障注入和更新后的验证记录；enum、CLI help、fixture 或 happy-path 单测不能单独
作为完成证据。

## 5. 尚需在实现前固定的量化参数

这些参数已有语义，但默认值应由原型压测后冻结为 config/default，不应散落硬编码：HTTP chunk/max connection、
rootfs max size、tmpfs percent/minimum free bytes、initrd reserve/safety margin、各阶段 timeout、token TTL、session/audit
retention、builder CPU/memory/pid limits、event body/output truncation、failure backoff/jitter。冻结时必须同时更新 typed
PropertySpec、validator、CLI help、示例配置和边界测试。

## 6. 发布门槛

v0.2 只有在以下证据同时存在时才可宣布完成：schema v4 round-trip/rollback；v0.1 install 全回归；两架构 QEMU；
至少一个 VMware/实机闭环；daemon 在 config/rootfs/事件阶段重启；Range 中断与 ETag 漂移；两次完整 hash mismatch；
内存不足；网络 handoff 无地址空窗；token scope/过期/跨 node；builder 崩溃与存储空间不足；first-boot 当次 retry 与新 session
全量重跑；日志、Event、boot.json、CLI 输出全链路 secret 扫描。
