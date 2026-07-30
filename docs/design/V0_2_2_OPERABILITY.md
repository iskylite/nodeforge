# NodeForge v0.2.2 设计：可运营性与矩阵收口

状态：设计冻结，持久化兼容 / durable rootfs operation / memory readiness 已实现
前置：v0.2.1 Ubuntu diskless 完成
schema：config/catalog 继续 v4；BootConfig v3（memory facts URL）；AgentPlan v1

v0.2.2 不增加新的部署形态。它把 v0.2.0/v0.2.1 已有能力收敛为可升级、
可诊断、可恢复、可自动化验证的稳定产品底座。

## 1. 范围

| 领域 | v0.2.2 范围 |
|---|---|
| state compatibility | 所有持久 state file 显式 schema、升级 fixture、字段 rename 兼容 |
| builder | initrd/rootfs durable asynchronous operation，不占 management handler |
| CLI | primary/advanced/internal 分层、preview、统一 retry、正式 reference |
| readiness | 可信 memory inventory、制品 deep validation、统一预算公式 |
| recovery | session/capsule/operation restart、expiry、partial artifact 处理 |
| matrix | 当前可用 VMware 环境中的 distro/lifecycle/fault 固定发布矩阵 |
| capacity | v0.2 规模内的有界并发与资源预算；大规模生产压测仍属 v0.4 |

不包含 BIOS/PXELINUX（v0.3）、多 NIC/topology（v0.4）、ram_rootfs（v0.5）。

## 2. 持久化兼容

每个文件独立维护 schema，不与 catalog v4 绑定：

- diskless-delivery：为 `created_at/started_at -> armed_at/install_at` 提升 schema；
- deployment-control：为相同 rename 提升 schema；
- operation、inventory、status、boot-session 保持各自版本并建立跨版本 fixture。

统一规则：

1. writer 只写最新 shape；
2. reader 只接受明确列出的旧版本；
3. 旧字段逐项转换，不用 unknown-field/default 吞掉；
4. fixture 覆盖 load old -> mutate -> save latest -> reload；
5. 无法恢复 capability raw secret 时进入稳定 `recovery_incomplete`，不得伪造新 secret；
6. 损坏文件 fail closed，并给出文件、schema、字段和恢复建议。

## 3. Durable builder operation

### 3.1 执行模型

`profile rootfs build` 与 `assets initrd build` 提交 operation。通用 operation 状态保持：

```text
queued -> running -> succeeded | failed
```

- HTTP handler 只验证请求、固定 input snapshot、创建 operation 并入队；
- 有界 worker 执行外部命令，stdout/stderr 按上限落 operation log；
- validating/publishing 等细粒度阶段放在 kind-specific progress，不扩张通用状态枚举；
- staging 与 `.part` 由 operation id 拥有；
- size/digest/deep validation 全部成功后原子发布；
- 当前已实现的 rootfs worker 在 daemon restart 后把 queued/running 确定性恢复为
  `operation.interrupted`；相同 idempotency key 可创建后继重试，半成品绝不标 ready。
  若未来引入真正 resume，必须先增加 kind-specific journal，不得从 staging 猜测成功。

> 2026-07-30 备注：v0.2.1 为 rootfs-build 的 package 步骤（dnf 与 apt 均适用）新增了
> `src/provision/namespaced_chroot_executor.zig`，用一次性 `unshare --mount --pid --fork`
> 子进程 + chroot 执行包管理器命令，退出后校验挂载点已清理。这是一个通用的"外部命令 +
> 确定性清理校验"执行原语，v0.2.2 的 initrd durable operation 化在设计 worker 的
> 执行/清理/失败语义时应参考其模式（尤其是"清理后必须显式校验，不能静默假设成功"这一点）。
> 但 `namespaced_chroot_executor` 本身不是 operation 化——它仍在现有 `rootfs_build`
> operation kind 内同步运行，不构成 v0.2.2 完成标准的一部分。

### 3.2 CLI

交互式默认等待同一 operation；`--detach` 立即返回 opaque id。`operation show/wait`
保留，增加 list。v0.2.2 不开放通用 cancel；若未来 worker 能证明安全终止与清理，
必须另行升级 operation schema/CLI，不能先暴露空 handler。

普通调用不要求手工复制 revision/digest。`--if-input-digest`、`--if-revision`
仅作为自动化 anti-drift guard。

## 4. CLI 收敛

以 `CURRENT_CLI_OPTIMIZATION_PLAN.md` 为目标，v0.2.2 至少落地：

- `profile clone`（无运行时继承）；
- `node boot preview`：编译目标、路径、feature、memory budget，但不创建 session/token；
- kind-aware `node retry`：服务端原子决定 deploy/rearm/cancel/supersede；
- `node postprocess show`；
- `boot-prepare` 降为 advanced/internal transition；
- 正式 `docs/cli/REFERENCE.md`，并以实际 command tree/help 契约测试防止漂移。

完整声明式 CommandSpec 与自动文档生成按 `V02-D08` 列为未排期 CLI P2 候选，
不进入 v0.2.2 产品完成闸。v0.2 发布后的真实差异与明确移出项统一见
[`V0_2_POST_RELEASE_BACKLOG.md`](V0_2_POST_RELEASE_BACKLOG.md)。

preview 与 prepare 必须使用不同 handler/type。preview 不能写 state、创建 operation、
消耗 generation 或签发 credential。

`profile show` / `node show` 已按 Stored / Overrides / Effective / Runtime 展示事实，
因此不再增加重复的 `profile effective` / `node effective` 命令。需要启动决策投影时使用
职责独立、严格只读的 `node boot preview`。

## 5. Readiness 与 inventory

inventory 增加至少：

```text
memory_bytes
reported_at
source_session
source_generation
facts_digest
```

- memory 只接受已认证 node facts；旧/stale session 不可覆盖；
- freshness policy 进入 readiness 输出，过期视 unknown；
- readiness 以 `inventory.memory_bytes - kernel_bytes - initrd_bytes` 为 server
  available budget，checked subtraction；
- initrd 直接使用 `MemAvailable`，不重复扣 kernel/initrd；
- compressed/uncompressed/payload/minimum_free/safety_margin 公式由共享 fixture 验证；
- unknown 不伪装 pass：CLI 显示 warning + required minimum，最终仍由 initrd 硬闸。

当前实现冻结 freshness 为 30 天：过期事实保留审计但 readiness 输出 `memory=stale`；
schema 1 inventory 显式迁移到 schema 2 且 memory 为 unknown。diskless initrd 通过
BootConfig v3 `facts_url` 上报 MemTotal，安装器 facts 同样携带该字段。

制品 readiness 每次校验 catalog identity、regular file、size、digest、kernel release
和 consumer feature；可缓存结果，但 cache key 必须覆盖 inode/mtime/size 或内容 digest，
不能只信历史 “ready” 字符串。

## 6. Recovery 与安全

- session/capsule 创建、AgentPlan pin、四 token issue 必须是可回滚事务；
- raw token 只驻内存；完整交付前 restart 进入 recovery_incomplete；
- 已交付 token 可用持久 hash 验证，不能同时生成第二个有效 token；
- capability 的 invalid/scope/path/content/replay 失败不泄露细节给客户端；
- 外部未认证探测不得推进受害 session 或消耗其 failure budget；
- terminal/cancel/expiry 立即撤销全部 scope；
- operation/session retention 有明确数量/时间上限。

## 7. 当前环境发布矩阵

最低必测矩阵：

| 维度 | 必测 |
|---|---|
| arch | 当前 VMware 可运行的 aarch64；x86_64 交叉编译与自动化检查 |
| distro | Rocky/RHEL family、Ubuntu 22.04 LTS |
| environment | VMware UEFI |
| network | DHCP DORA、Range 中断恢复、daemon restart |
| memory | 等号边界、低于阈值、unknown inventory |
| lifecycle | running、first-boot failure/retry/journal、cancel/expiry |
| security | token scope/replay/path/digest、公开 CLI 不泄漏 raw token |
| upgrade | v0.2.0/v0.2.1 state fixture 升级到 v0.2.2 |

每次发布记录候选 commit、四产物 digest、测试脚本版本、虚拟机配置、事件链和
失败注入结果。单独手工 smoke 不能替代矩阵。

x86_64 VMware（`V02-D01` / `ENV-X86-VMWARE`）当前无法在本地环境执行，不进入
v0.2.2 完成闸；QEMU（`V02-D02`）为可选诊断和故障注入工具，VMware 产品链已经
通过时不要求重复执行。不可验证项和解除条件统一见
[`LOCAL_VALIDATION_DEFERRED.md`](LOCAL_VALIDATION_DEFERRED.md)。

## 8. 完成标准

- P0 state schema rename 兼容问题关闭；
- 两类 builder 均为 durable operation，handler 不同步跑长任务；
- preview 无副作用、retry 单事务、CLI reference 与实际 tree 一致；
- memory inventory/readiness 与 initrd 公式 fixture 一致；
- restart、partial、expiry、token recovery 负向测试通过；
- 当前环境必验矩阵由同一发布候选完成；
- v0.3 进入条件所需的稳定 schema v4/BC v3/AP v1 基线冻结。
