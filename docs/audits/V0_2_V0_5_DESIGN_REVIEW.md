# NodeForge v0.2-v0.5 设计评审（基于 v0.1 M0-M4.13 实现）

状态：2026-07-22 设计审计基线。本文回答“现有代码能复用什么、后续版本还缺什么、按什么顺序实现”。
权威行为仍以各版本 design 文档为准，diskless 以 [`DISKLESS_FINAL.md`](../design/DISKLESS_FINAL.md) 为准。

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
| P0 | switch_root 前清唯一 token，但 agent 仍需拉步骤/回传 | config/artifact/event 三 scope；步骤烤入 fixed rootfs payload，agent 仅继承短时 append-only event token |
| P0 | 当前预留 `BootBundleConfig.rootfs` 造成 Profile/effective/rootfs 构建环 | v4 bundle 固定 source+prepared kernel+initrd revisions；DeliveryManifest 绑定派生 rootfs |
| P0 | v0.1 `AssetKind.kernel` 是 installer kernel，未必有最终 rootfs 的匹配 modules ABI | v4 新增 runtime-kernel prepare/resource，pin 本地 kernel package 与 modules closure |
| P0 | “每次启动执行”却用不含 session 的幂等键跨启动跳过 | 幂等键加入 boot session，只在当次 `/run` journal 去重 |
| P0 | 只说 Range/daemon restart-resume，没有恢复事实源 | 持久 delivery record + token hash + immutable snapshot；原 token 不落盘；If-Range 规则明确 |
| P1 | squashfs 被误认为无需内存预算 | v0.2 lower 下载到 tmpfs，必须预算 compressed image + upper + initrd reserve |
| P1 | 网络“接管同一地址”缺少 adopt/lease 规则 | 固定启动 NIC/MAC/address/route，DHCP lease handoff；renderer 不先 flush 地址 |
| P1 | 状态可由模糊客户端事件任意推进 | CAS reducer + event_seq + 唯一 producer/证据表 |
| P1 | rootfs ready 可能看见半成品 | staging -> validate -> object rename -> manifest ready；v0.2 已发布 object 只增不删 |
| P2 | `diskless.running` 与 first-boot success 混淆 | running 只表示切根/PID1/agent 已启动；step 结果仅作 postprocess 附属摘要 |

## 3. 版本依赖与边界

| 版本 | schema | 必须交付 | 不得偷跑 |
|---|---:|---|---|
| v0.2 | 4 | UEFI diskless、builder、initrd、diskless agent、rootfs-build/first-boot、恢复/失败闭环 | BIOS、多 NIC、rootfs mode |
| v0.3 | 5 | BIOS PXELINUX install、`firmware.mode`、install-post、明确 distro capability matrix | install agent、多 NIC |
| v0.4 | 6 | 多 NIC/VLAN/bonding、容量目标、builder placement、install first-boot agent | 可切 rootfs 形态 |
| v0.5 | 7 | `squashfs_overlay|ram_rootfs` 物化选择与双重内存预算 | NFS/iPXE/persistent overlay |

v0.3 的 BIOS 与发行版扩展应拆成两个可独立验收的 feature slice；共同点只有版本发布，不应让新增发行版阻塞
PXELINUX，也不应让 BIOS 绕过 adapter matrix。v0.4 的网络拓扑、容量、远程 builder 和 install agent 是四个风险域，
schema 可同版但实现/验收必须独立。v0.5 只改变 rootfs materializer；BootConfig、auth、状态机与 agent 不应分叉。

## 4. v0.2 推荐实施顺序

1. **V2.0 schema/contract**：v3 -> v4 plan/apply/rollback；Profile tagged kind；bundle tagged action/phase；
   golden CLI/API/parser negative tests。
2. **V2.1 effective/readiness**：DisklessEffectivePlan、digest exclusion/inclusion tests、boot bundle/feature/memory gate。
3. **V2.2 builder**：sandbox、local-only、manifest、atomic publish、容量告警、并发与 crash recovery。
4. **V2.3 session/auth**：canonical reducer、delivery record、scoped token、failure ledger/quarantine/retry。
5. **V2.4 protocol delivery**：DHCP rootfs gate、TFTP identity、BootConfig v2、rootfs HTTP Range/ETag/error contract。
6. **V2.5 initrd**：dracut module、10 步 pipeline、network handoff、projection、switch_root、console diagnostics。
7. **V2.6 agent**：rootfs 内 fixed-revision steps、per-session journal、bounded actions、append-only events、本地结果。
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
