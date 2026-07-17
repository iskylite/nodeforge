# M4.2：部署链路健壮性、密钥可维护性与传输性能加固

- 日期：2026-07-14
- 状态：设计修订中（待实现）
- 依赖：M4.1 基线；是 M4/M4.1 安装链路的直接延续，在 M5 之前交付
- 插入位置：`docs/DETAILED_DESIGN.md` §9.11 M4.2

> **历史规格，后续修订（2026-07-15）**：M4.3 实机复核否定或完成收口了本稿的以下过渡契约：
> (1) RHEL-family 介质不能统一归一为 `distro=rocky`，必须保留真实 distro；
> (2) node CRUD 不能靠 CLI 直写配置并重启 daemon；
> (3) daemon 重启不应必然使正在安装的 BootSession/capability 失效。
> 此外 repository 不再是识别 ISO 的前置条件，重复导入改为 SHA-256 幂等语义，TFTP option 协商按 RFC 收口。
> 本稿的 node per-field flags 被 typed `k=v`/`unset` 取代；deprecated alias 的一个版本兼容窗口在 M4.3 结束；
> `node list/show` 改为聚合 desired/profile/status/deployment/inventory。资源目录迁移本身已经由 M4.2 实现，
> M4.3 只做边界测试和现行文档清理，不重新开发第二套迁移。
> M4.3 还将 install-source 的只读 `catalog show` 和带 plan digest 的 `catalog migrate --dry-run/--apply`
> 提前作为旧数据修复入口，并提前只读 `profile list/show` 以发现当前 PXE 策略；M6 仍负责 profile/repository
> 写操作和完整 config diff/apply。2026-07-17 的后续修订取消独立 distro CRUD：family 来自媒体布局，
> 已知产品标签自动映射，未知但布局有效的产品允许 tuple 覆盖，ISO 导入事务自动维护 distro 索引。M4.3 必须修改
> 现有实现与测试，并重新完成 Rocky/Ubuntu 全安装和 Ubuntu restart-resume，不能只更新设计文档。
> M4.4 随后统一本文出现的历史 `/boot/config`、`/answer`、`/repos`、`/subiquity-report` 和 management 动词路径；
> 本稿仅保留当时实现语义，现行 URL 以 M4.4 专项设计为准。
> 新契约见 `2026-07-15-m4_3-model-runtime-observability-design.md`；与本稿冲突时以 M4.3 为准。

> **后续修订（2026-07-17，F4 TFTP 传输与并发模型纠正）**：`e14b15f` 将 `awaitAck` 超时
> 3s->5s、`max_retries` 3->5 的「加耐心」方向被证明治标不治本--对 139 MB initrd，
> GRUB 收齐文件后转去加载（解压/EFI 分配）、不再回最终 ACK（dnsmasq 源码注释
> "some clients never send it" 即指此），无论服务端等多久都收不到末尾 ACK，最终仍判
> 失败并误发 ERROR 包。本修订改为治本：
> (1) **末尾块 ACK 乐观完成**：等 ACK 的块若是最后一块（payload < blksize），重传
> `final_block_retries=2` 次（1+2+4 ≈ 7s）仍零 ACK，记录 `delivery unconfirmed` 后乐观完成；
> 这是资源释放策略，不是 RFC 1350 对交付成功的保证。非末尾块超时仍判失败。
> (2) **指数退避重传**：`default_timeout` 5s->1s（与 tftpd-hpa 默认一致），每次重传
> timeout 翻倍封顶 255；非末尾块 `max_retries=5`（对齐 `TRIES=6`，累计 ~63s）。
> 客户端 RFC 2349 `timeout` option 仍按协商值。
> (3) tftpd-hpa 常见部署为每请求进程，timeout `exit(0)` 只清理该请求；NodeForge 是共享
> session/event/全局并发槽的长驻多线程 daemon，不能照搬无差别退出。末尾块用更小预算
> 是为尽快释放全局 worker，非末尾块必须显式失败。
> (4) OACK/ACK0 使用与非末尾 DATA 相同的同 TID 重传循环；传输 TID 建立后的失败只关闭
> 原 worker，不从新临时端口发送 ERROR。
> 实现见 `src/tftp/server.zig` `RetryAction`/`retryAction`/`retryLimit`/`backoffSeconds`
> 及 `transfer`/`transferFromMemory` 重传循环；纯逻辑有单元测试覆盖。详见 §7.7。

## 1. 背景与问题陈述

M4/M4.1 交付了 kickstart/autoinstall 渲染、受控 post-install provisioning 和安装生命周期事件上报。
本里程碑在不改变 M4.1 TargetSystemConfig 归一模型的前提下，修复部署链路的可维护性和传输性能。

post-install 命令的异常容忍语义（kickstart `%post --erroronfail` 与 ubuntu `late-commands` `&&` 串接）
**保持现状不动**，不在本里程碑范围内。

### 1.1 缺陷清单

| # | 缺陷 | 根因（file:line 证据） | 影响 |
|---|------|------------------------|------|
| F1 | 部署错误信息未传回 nodeforged | `/api/v1/nodes/:id/logs` 端点与 `LogSummary` schema（`contracts.zig:28`）已完整实现但**无任何模板调用它**（`server.zig:708` 仅路由注册）；失败仅发空 `{stage:"failed"}`，`reason`/`message` 字段从未被填充；`%onerror`/`error-commands` 只 POST stage 不带 stderr。 | nodeforged 只知"失败"不知"为何" |
| F2 | 无法对已匹配节点禁用 PXE 部署 | `NodeConfig`（`model.zig:515-530`）无 deploy 标志；唯一抑制是 arch 不匹配 / unknown wait / install-not-armed gate（`resolver.zig:51-81`）。虽有 generation 机制但无"永不部署此节点"开关。 | 即使 MAC/IP/profile 匹配也无法显式标记"不部署" |
| F3 | ISO 导入仅认 Rocky+Ubuntu，不支持 RHEL 系变体与国产化 OS | `.treeinfo` family 前缀硬编码 `Rocky`（`iso_import.zig:271`）；`--distro`/`--version`/`--arch` 是断言（mismatch 即 fail）非覆盖（`iso_import.zig:243-247`）。 | CentOS/RHEL/Alma/Fedora/openEuler/Kylin 等无法导入；覆盖语义缺失 |
| F4 | TFTP 性能差 | 未实现 RFC 7440 windowsize（每块 ACK 往返，`server.zig:445-464`）；单线程串行处理让并发客户端排队（`server.zig:59-121`）；无性能配置项（`TftpConfig` 仅有 `asset_root`，`model.zig:78-81`）。 | PXE 初始阶段 TFTP 传输慢 |
| F5 | 免密公钥不可更新，注入的公钥可能 ≠ 操作员私钥 | 公钥仅启动时解析一次（`app.zig:81`）；不覆盖已生成对（`admin_key.zig:24-29`）；解析优先级是 config 单值 -> /root/.ssh -> 已生成 -> 生成。 | 若初始自动生成 key 后操作员设置了 /root/.ssh，daemon 仍持有旧 key |
| F6 | CLI 命令体系结构不合理 | 13 个扁平顶层命令；`runtime` 实为 DHCP 运行态却独立于 `dhcp`；`trace` 读取 events 数据却不在 `events` 下；`install-source` 与 `asset` 同属 boot media 却分离；`node` 仅有 `list`。与文档既有 CLI 设计逻辑（`nodeforge <resource> [subresource] <action>`）存在偏差，需重新校准。 | 每加新特性就加新子命令，无分组逻辑 |
| F9 | boot-gate 事件泛滥 | `offerAfterProbe`（`dhcp/server.zig:177-210`）在**每个 DHCP 包**处理中检查 `install_not_armed`/`deploy_disabled` 并无条件写事件。一次 PXE 启动周期产生 4-8+ 个 DHCP 包（PXE 固件 DISCOVER→OFFER→REQUEST→ACK + OS 启动 DISCOVER→OFFER→REQUEST→ACK + 续约 REQUEST），`Writer.appendWithFields`（`events.zig:69-108`）无去重或限速。 | 未武装/禁用节点在数秒内产生数十条重复 `boot.install_not_armed`/`boot.deploy_disabled` 事件，污染 events.jsonl |

## 2. 设计目标

1. **错误可观测**：安装阶段任何系统（kickstart/autoinstall）的部署错误信息能传回 nodeforged。
2. **节点可控**：即使 MAC/IP/profile 匹配，也能显式标记某节点"不部署"。
3. **主流 OS 可导入**：支持 RHEL 系（含国产化）+ Ubuntu + Debian，`--distro` 等参数可覆盖自动解析。
4. **TFTP 快**：实现 windowsize + 并发 + 配置项，消除结构性的慢。
5. **免密可维护**：公钥可配置多个、可 CLI 导入、可重载、可诊断。
6. **CLI 有序**：校准命令树至文档定义的 resource-action 模型，扁平化层级，新特性归入合理分组。
7. **事件不泛滥**：boot-gate 事件（`boot.install_not_armed`/`boot.deploy_disabled`）仅在节点状态转换时写入，不在重复 DHCP 交互中产生冗余记录。

## 3. 非目标

- **不改动 post-install 命令的异常容忍语义**（kickstart `%post --erroronfail`、ubuntu `late-commands` `&&` 串接保持现状）。
- 不实现 diskless initrd 的事件上报（M5 范畴）。
- 不实现 installed 节点首启动/运行时 agent（M7 范畴）。
- 不为每个国产化发行版建独立 adapter 能力表；全部归一复用 kickstart。M6 按 `source_label` 区分变体但不改变归一 distro。
- 不改动 HTTP 传输路径（已用 sendfile + Range + 120s 超时，性能良好）。
- 不改动 DHCP 端口（69）/ HTTP 端口绑定策略（保持 M2 设计）。
- 不新增 M5/M6/M7 的 resource 组命令（`rootfs`/`initrd`/`boot-bundle`/`diskless`/`boot`/`provision`），
  只校准 M0-M4.1 已有的 13 个扁平命令；后续里程碑新增命令须遵循同一 resource-action canonical form。
- 不固化 HTTP `max_connections` / TFTP 性能参数的生产上限（M6 压测后固化），M4.2 只引入配置项和默认值。
- 不实现 `deploy=false` 节点的已装 authorized_keys 原地更新（需重装或手动更新；M7 reconciliation 范畴）。

## 3.1 M4.2 吸收的 M4/M4.1 遗留问题

以下 M4/M4.1 遗留问题在 M4.2 中一并修复（不作为 M4.1 尾巴单独处理）：

| 遗留项 | 来源 | M4.2 修复 |
|--------|------|-----------|
| `--distro`/`--version`/`--arch` 是断言而非覆盖 | M3 §8.4/§8.7/§8.13 | F3 改为覆盖语义 |
| ISO 导入仅认 Rocky+Ubuntu | M3 §8.4 | F3 扩展 family 白名单 + Debian |
| `/logs` 端点已实现但无模板调用 | M4 §9.6/M4.1 §9.10.9 | F1 接通 `log_url` + `%onerror`/`error-commands` |
| `failed` stage 缺稳定 reason 和 summary | M4 §9.6 (`DD:3055`) | F1 填充 `install.anaconda_error`/`install.subiquity_error` |
| bootstrap admin key 仅启动时解析一次、不可更新 | M4.1 §9.10.6.2 | F5 多值数组 + state 目录扫描 + CLI reload |
| `NodeConfig` 无"永不部署"开关 | M4.1 §9.10.11 generation 仅覆盖 install | F2 `deploy` 硬外层开关 |
| CLI 13 个扁平命令与 canonical form 偏差 | M1.5 §6.5 / M4 §9.7 | F6 校准为 8 顶层资源模型 |
| node 仅有 `list`，无 add/set/remove | M4 §9.7 / DESIGN.md:1675,1952 | F6 新增 node CRUD + 管理 API |
| `install status`/`install logs` 未实现 | M4 §9.7 | F6 合并到 `node show` |
| 安装目录 14 个子目录散乱、与 CLI 资源不对应 | M0 paths.zig | F6 安装目录资源化布局 |
| VAL:552 "Ubuntu error 与 Rocky %onerror 在真实失败路径上报合法 failed stage" 未验证 | M4.1 验收 | F1 验收标准 #1/#2 覆盖 |

M4.1 其他遗留验收项（locale/timezone/keyboard、password crypt 交叉验证、APT fallback、local-only 外联回归、
package availability preflight、deployment-control.json 损坏 fail-closed 等）不在 M4.2 范围内，仍是 M4.1 的收口责任。

## 3.2 M4.2 对后续里程碑的影响声明

M5/M6/M7 继承 M4.2 的以下变更，不得假设旧行为：

| M4.2 变更 | 影响 | 受影响里程碑 |
|-----------|------|-------------|
| F2 `deploy` 开关 | `deploy=false` 对 diskless/PXELINUX 同样生效；`node retry`/`diskless-retry` 无法绕过；config diff 归类 runtime-applicable | M5 (diskless)、M6 (PXELINUX §11.4)、M6 (config diff §11.6)、M7 (reconciliation §12.9) |
| F1 reason 码 | `install.anaconda_error`/`install.subiquity_error` 进入 §11.5 错误分类表；M7 auto-retry allowlist 消费其 retryability | M6 (§11.5)、M7 (§12.9) |
| F3 family/产品标签 + `source_label` | 后续修订改为媒体布局定 family、真实 distro 入索引；`source_label` 仅展示，M6 能力表按 family/distro/version 处理 | M6 (§11.2/§11.3) |
| F4 TftpConfig 字段 | M6 压测固化使用 M4.2 已引入的字段名 | M6 (§11.3) |
| F4 `node.http_accel` | M5 diskless 模式的 kernel/initrd 同样适用 HTTP 加速；仅对 GRUB UEFI 生效，M6 BIOS PXELINUX 固定使用 `pxelinux.0`（TFTP only），`http_accel` 无效 | M5 (§10.4)、M6 (§11.4) |
| F5 多公钥 | M5 BootConfig `root_authorized_keys` 可含多个 bootstrap key；M7 finalizer 须断言多 key 归属 | M5 (§10.6)、M7 (§12.3) |
| F6 CLI 8 资源模型 | 后续命令须遵循 resource-action 模型；M4.3 已提前 profile 只读顶层，M5 构建产物归入 `assets`，M6 增加 profile 写 action，M7 provision 独立顶层 | M4.3 (§9.12)、M5 (§10.7)、M6 (§11.4)、M7 (§12.8) |
| F6 node 原子变更 + reload | 此处 node reload 模型已被 M4.3 runtime 事务替代；M6 profile/repo CRUD 复用新事务，distro 仅由 ISO 导入派生 | M6 (§11.6) |
| F6 安装目录资源化 | M5 构建产物路径（rootfs/initrd/boot-bundle）须使用新布局 `assets/rootfs/`/`assets/initrd/`/`assets/bundles/`；M7 provisioned 归 `state/provisioned/` | M5 (§10.2)、M7 (§12.2) |
| F1 `log_url` 注入 | BootConfig 共同字段增加 `log_url`；M5 initrd 如需失败摘要可复用 `/logs` | M5 (§10.4) |
| F9 boot-gate 去重 | M5 diskless boot-gate 事件（如 `boot.diskless_not_armed`）须复用同一 `BootGateSuppressor` 模式 | M5 (§10.5) |

## 4. F2 分析：节点级"不部署"开关与现有 generation 机制的关系

### 4.1 现有机制分析

NodeForge 已有 **deployment_control generation 机制**（`src/state/deployment_control.zig`），它是一个
per-node、generation-numbered 的状态机，与 observed node status 分离。其设计契约明确（`deployment_control.zig:3-4`）：
"deliberately tracks destructive install intent separately from observed node status. A profile binding alone
never authorizes a repeat PXE install."

**Generation 生命周期**：

1. **daemon 启动**：`app.zig:77-79` 对每个 install-mode 节点调用 `ensureInitial`（`deployment_control.zig:99-110`），
   仅当 `armed_generation == null and consumed_generation == null` 时 arm generation 1（`requested_by=.initial`）。
2. **PXE 首次引导**：`resolveWithDeployment`（`resolver.zig:74-81`）检查 `isArmedForRevision` -> armed 则给 bootfile。
3. **安装启动**：installer POST `stage="started"` -> `consume`（`deployment_control.zig:131-145`）将 armed 移到 consumed，
   清空 armed。此后再次 PXE 引导因 `isArmedForRevision=false` -> `install_not_armed=true` -> 无 bootfile。
4. **安装结束**：`completed`/`failed` -> `markTerminal`（`deployment_control.zig:220-237`）设 terminal=consumed。
   **`markTerminal` 永不复 arm 下一个 generation**（测试 `deployment_control.zig:444-452` 确认）。
5. **后续 PXE 引导**：armed=null -> `install_not_armed=true` -> 无 bootfile，但仍发诊断 DHCP lease。

**结论：默认 `reinstall_policy=.explicit`（`model.zig:270`）下，首次部署成功后节点确实不会再次进入部署。**
`reinstall_policy=.always`（`model.zig:273`）会在 terminal 后的下次 DHCP DISCOVER 时 auto-rearm
（`dhcp/server.zig:136-172`，`canAutoRearm` `deployment_control.zig:210-216`）。

**已有 CLI**：`nodeforge install retry <node_id>`（`main.zig:215`，handler `main.zig:914`）可手动 re-arm
（`server.zig:987`，`requested_by=.operator`）。这是 **re-enable / re-deploy** 方向。

### 4.2 缺失的手动调整方案

generation 机制覆盖了"re-enable"方向，但 **disable 方向缺失**：

- 无 CLI/API/config 字段可标记"此节点永不部署，但保留 MAC/IP 预留用于诊断"。
- generation gate 仅作用于 `mode==.install`（`resolver.zig:76`），**不覆盖 diskless/discovery 模式**。
- `ensureInitial` 在 daemon 启动时无条件 arm gen 1（`app.zig:77-79`）-> **无法阻止首次部署**。
- `reinstall_policy` 是 per-profile（`ProfileSafetyConfig`，`model.zig:262-271`），**无 per-node override**
  （`NodeConfig.overrides` 仅含 network，`model.zig:359`）-> 一个 profile 的多个节点无法差异化。
- `install retry` 或 `always` 策略可随时重新 arm 一个操作员想保持不部署的节点。

### 4.3 `deploy` 开关的定位（与 generation gate 的关系）

`deploy: bool = true` 与 generation gate **互补，不冗余**：

| 维度 | generation gate | `deploy` 开关 |
|------|----------------|---------------|
| 语义 | "这次特定破坏性部署是否被授权" | "此节点是否参与任何 PXE 引导" |
| 作用域 | 仅 install 模式 | install/diskless/discovery 全模式 |
| 生命周期 | armed->consumed->terminal，运行时可变 | config 声明的静态意图，配置周期内稳定 |
| 首次部署 | 无法阻止（ensureInitial 无条件 arm） | `deploy=false` 直接阻止 |
| 受 retry 影响 | `install retry` 重新打开 gate | 不受 retry/always 影响 |
| per-node | 是（per-node generation entry） | 是（per-node config 字段） |

两者组合：`deploy=false` 是硬外层开关（"永不 PXE 此节点"）；generation gate 是内层 per-deploy 授权。

### 4.4 模型变更

`deploy` 是节点的属性，不是独立命令。`NodeConfig`（`model.zig:515-530`）新增字段：

```zig
deploy: bool = true,
// true:  正常参与 PXE 部署/无盘（默认，向后兼容）
// false: 即使 MAC/IP/profile 匹配，也不下发 PXE bootfile；仍发诊断 DHCP lease
```

通过 `node set <id> --deploy false` 管理（CLI 接口见 §9 F6），与 `--ip`/`--mac`/`--profile` 同级。
CLI 通过 `config_store.save` 原子写回 `config.json`，随后调用本机
`POST /api/v1/management/config/reload`。daemon 校验新配置后有序退出，由 systemd 重启加载；
CLI 只有在 reload 请求成功后才报告 mutation 成功（见 §9.6）。

### 4.5 resolver 变更

`resolve()`（`resolver.zig:51-70`）MAC 命中后、mode 判定前加守卫：

```zig
if (!node.deploy) return .{
    .bootfile = null,
    .known = true,
    .node_id = node.id,
    .reserved_ip = node.ip,
    .profile = node.profile,
    .mode = null,
    .install_not_armed = false,
};
```

返回 `mode=null` 使 `resolveWithDeployment` 的 `decision.mode == .install` 检查（`resolver.zig:76`）为 false，
generation gate 被完全绕过。适用于 install / diskless / discovery 全模式。

### 4.6 事件

新增 `boot.deploy_disabled` 事件类型（`event_types.zig`），在 DHCP offer 时记录被禁用节点。

### 4.7 校验

`validateNodes`（`validate.zig:361-378`）无需结构变更（默认 bool 永真）。文档说明 `deploy=false` 时
该节点不参与任何 PXE 引导，但仍占用保留 IP 且出现在 `node list` 中。

## 5. F1：部署错误信息传回 nodeforged（安装阶段全覆盖）

### 5.1 现状分析

**服务端基础设施已就绪**：
- `POST /api/v1/nodes/:id/events`（`server.zig:193`，`nodeEvent` `server.zig:657-706`）：接收 `NodeEvent{v, boot_session_id, stage, reason?, message?}`，
  JSON body 由 Zap/facil.io 解析为 form params（`request.zig:589-591` 支持 `application/json`），验证后持久化到
  `events.jsonl` + `node-status.json`，并在 `started`/`completed`/`failed` 时做 generation bookkeeping。
- `POST /api/v1/nodes/:id/logs`（`server.zig:194`，`nodeLog` `server.zig:708-731`）：接收
  `LogSummary{v, boot_session_id, reason, summary}`，验证后写 `install.failed` 事件 + node-status `.failed`。
  body 上限 4 KiB（`contracts.zig:10`），summary 上限 2048 字节（`contracts.zig:13`）。

**客户端调用缺失**：
- 所有模板 curl 仅 POST `{"v":1,"boot_session_id":"...","stage":"..."}`，**`reason`/`message` 从未被填充**
  （`kickstart.zig:145,164`；`ubuntu.zig:136,137,185,189,191`）。
- **`/logs` 端点无任何模板调用**（grep `kickstart.zig`/`ubuntu.zig`/`runner.zig` 无 `/logs` 或 `log_url` 引用）。
- `answerFixture`（`server.zig:573-650`）仅构造 `event_url`（`server.zig:581`），未构造 `log_url`。
- 失败时 nodeforged 只收到空 `stage="failed"`，event message 回退为硬编码 "node stage update"（`server.zig:695`）。

**Capability TTL**：delivery TTL = 2 小时滑动窗口（`boot_session.zig:20`），每次文件下载刷新
（`touchDelivery` `boot_session.zig:435-445`）。terminal 事件立即释放 capability（`finishDelivery` `boot_session.zig:466-474`），
之后节点无法再上报。安装期间上报窗口充足。

### 5.2 两个安装器的架构差异

> Ubuntu Autoinstall 通过 curtin `webhook` reporter 支持原生 HTTP POST 事件上报；
> Kickstart/Anaconda 没有同等的 HTTP webhook，需要用 `%pre`、`%onerror`、`%post` 主动调用 HTTP API。
> 这是两个安装器架构的固有差异，NodeForge 不强行统一。

### 5.3 修复方案

#### 5.3.1 接通 `/logs` 端点

`answerFixture`（`server.zig:573`）新增 `log_url` 构造，与 `event_url`（`server.zig:581`）并行：

```
log_url = "http://{server_ip}:{http_port}/api/v1/nodes/{node_id}/logs"
```

`log_url` 注入到 kickstart/ubuntu answer 模板，与 `event_url`、`token`、`session` 同级。

#### 5.3.2 Kickstart（Anaconda，无原生 webhook，纯 curl）

`%onerror` 增强为捕获 Anaconda traceback 后 curl `/logs`：

```bash
%onerror
ERRLOG=$(ls /tmp/anaconda-tb-*/anaconda-tb 2>/dev/null | head -1)
SUMMARY="anaconda error"
if [ -n "$ERRLOG" ]; then
  SUMMARY="anaconda error: $(head -c 2048 "$ERRLOG" 2>/dev/null | tr '\n' ' ')"
fi
curl -fsS -H 'Authorization: Bearer {token}' -H 'X-NodeForge-Session: {session}' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "v=1&boot_session_id={session}&reason=install.anaconda_error&summary=$SUMMARY" \
  {log_url} || true
curl -fsS -H 'Authorization: Bearer {token}' -H 'X-NodeForge-Session: {session}' \
  -H 'Content-Type: application/json' \
  -d '{{"v":1,"boot_session_id":"{session}","stage":"failed"}}' {event_url} || true
%end
```

`%pre`（`installer_started` + `started`）和 `%post`（`post` + `completed`）的 curl 保持不变。

新增 reason `install.anaconda_error`。

#### 5.3.3 Ubuntu Autoinstall（Subiquity，curtin webhook reporting + 降级 curl）

`renderUserDataM41` 新增 `reporting:` 块，声明 curtin `webhook` reporter：

```yaml
reporting:
  nodeforge:
    type: webhook
    endpoint: http://{server_ip}:{http_port}/api/v1/nodes/{node_id}/subiquity-report
    level: INFO
```

> **M4.2 修复**：curtin 的 HTTP-POST reporter 类型名为 `webhook`（不是 `http`），在 Ubuntu 22.04 和
> 24.04 中均可用（handler 注册表完全相同：`log`/`print`/`webhook`/`journald`）。历史代码误用
> `type: http` 导致 `KeyError: 'http'` 崩溃。`webhook` handler 不支持 `headers` 字段（会 `TypeError`），
> 认证通过源 IP 校验（`/subiquity-report` 端点检查请求来源 IP 匹配节点 DHCP lease）。

webhook reporter POST 的 JSON 事件格式（`ReportingEvent.as_dict`）：
```json
{"name":"<stage>","description":"<msg>","event_type":"start|finish|result",
 "origin":"curtin","timestamp":1234567890.0,"level":"INFO"}
```
`finish` 事件额外含 `"result":"SUCCESS|WARN|FAIL"`。

新增 `subiquityReport` handler（`server.zig`）+ 路由 `POST /api/v1/nodes/:id/subiquity-report`：
将 webhook JSON 事件映射到 `install.*` 阶段（复用 `mapStage`）。鉴权通过源 IP 校验（非 bearer token，
因 webhook 不支持自定义 header）。

`early-commands`/`late-commands`/`error-commands` 的手写 curl 保留为降级路径（reporting 不可用时兜底，
均带 `|| true`）。`error-commands` 增强：捕获 curtin env vars（`ERROR_CMD`/`ERROR_STATUS`/`ERROR_TRACEBACK`）
curl `/logs`，reason `install.subiquity_error`。

##### Ubuntu hostname 始终渲染（M4.2 修复）

原代码中 `identity.hostname` 仅在 `system.users` 非空时渲染。无 users 时 `identity:` 块被跳过，
hostname 从未设置，导致安装后主机名为 `localhost`。修复：始终在 `autoinstall.user-data` 中渲染
`hostname:` 与 `preserve_hostname: false`，并保留文档顶层 hostname 供安装环境使用。目标 hostname
不再依赖 identity 是否存在。

##### 默认普通管理用户（M4.2）

省略 `system.users` 时默认创建 `nodeforge`，密码 `asdf1234`，并授予 sudo/wheel 权限；Ubuntu 与
Kickstart adapter 必须从共享 `TargetSystemConfig` 生成相同账号事实。显式配置 `system.users: []`
仍表示 root-only。旧版 `install.users` 非空时可覆盖隐式默认值；若新旧字段都显式非空且不一致，继续拒绝歧义配置。

### 5.4 新增端点汇总

| 方法 | 路由 | 鉴权 | 用途 |
|------|------|------|------|
| POST | `/api/v1/nodes/:id/subiquity-report` | 源 IP 校验（匹配 DHCP lease） | 接收 curtin webhook reporter 的 HTTP POST 事件 |

`/logs` 和 `/events` 端点已存在，仅接通调用方（注入 `log_url` + 填充 `reason`/`summary`）。

### 5.5 新增 reason 值

| reason | 触发场景 | retryability |
|--------|----------|--------------|
| `install.anaconda_error` | Kickstart `%onerror` 捕获 Anaconda traceback | operator |
| `install.subiquity_error` | Ubuntu `error-commands` 捕获 curtin 错误 | operator |

加入 `event_types.zig` 注册表和 M6 §11.5 错误分类表。

## 6. F3：ISO 导入支持主流 OS + 覆盖语义

### 6.1 RHEL 系 family 归一

`detectRockyMedia`（`iso_import.zig:258-281`）的 `family` 前缀检查从硬编码 `Rocky` 扩展为白名单：

```
Rocky | CentOS | CentOS Linux | CentOS Stream | RedHatEnterpriseServer |
RedHatEnterpriseLinux | AlmaLinux | Fedora | OracleLinux | ScientificLinux |
CloudLinux | EuroLinux |
# 国产化 RHEL 系
openEuler | Kylin | Kylin Linux Advanced Server | TencentOS | TencentOS-Server |
AnolisOS | UnionTech OS Server | UOS Server | npserver | TurboLinux |
Sugon OS | BigCloud-Enterprise-Linux
```

全部归一到 distro `rocky`（复用 kickstart adapter），catalog 新增 `source_label` 字段记录原始 family
供溯源。归一逻辑封装为 `normalizeRhelFamily(family) ?[]const u8`，返回归一名或 null。

### 6.2 Ubuntu / Debian 检测

- Ubuntu：沿用 `.disk/info` 解析（`iso_import.zig:308-335`），格式 `Ubuntu-Server 22.04.5 LTS "..." arm64 (...)`。
- Debian（新增）：检测 `.disk/info` 含 `Debian` 或 `.treeinfo` 存在时解析。version 取 major.minor。
  Debian 归一到 distro `ubuntu`（复用 autoinstall adapter，Debian 亦支持 cloud-init NoCloud），`source_label` 记 `Debian`。

### 6.3 `--distro`/`--version`/`--arch` 改为覆盖语义

`verifyRequestedTuple`（`iso_import.zig:243-247`）改为 `applyRequestedTuple`：

- 指定 `--distro`（非空）时：**跳过自动检测**，直接采用指定 distro。仍校验文件存在性（kernel/initrd/iso
  路径必须存在），仍校验 catalog 支持矩阵。
- 指定 `--version`（非空）时：覆盖检测到的 version。
- 指定 `--arch`（非空）时：覆盖检测到的 arch。
- 全部未指定时：走自动检测（现有逻辑）。
- 部分指定时：自动检测 + 覆盖指定项。

CLI help 文案更新（`main.zig:294-298`）：
- `--distro`: "Override auto-detected distro; e.g. rocky, ubuntu, debian. Empty = auto-detect"
- `--version`: "Override auto-detected version; e.g. 9.7, 22.04. Empty = auto-detect"
- `--arch`: "Override auto-detected arch; e.g. x86_64, aarch64. Empty = auto-detect"

### 6.4 友好错误

未识别 ISO 且未指定 `--distro` 时，返回结构化错误提示：

```
error: install-source: could not auto-detect distro from media metadata.
  Detected .treeinfo family: <value> (not in supported list)
  Supported families: Rocky, CentOS, RHEL, AlmaLinux, Fedora, openEuler, Kylin, ...
  Ubuntu Server: detected via .disk/info + casper layout
  Hint: specify --distro <canonical-id> [--version <X> --arch <Y>] for a valid but unknown product label
```

## 7. F4：TFTP 性能优化

### 7.1 windowsize (RFC 7440)

`negotiate`（`server.zig:445-464`）识别 `windowsize` option 并回 OACK。DATA 发送循环改为：
发 `windowsize` 个块后才等一个 ACK（而非每块等 ACK）。单 ACK 确认连续 `windowsize` 块。

### 7.2 per-client 并发

dispatcher（`server.zig:59-121`）收到 RRQ 后 spawn 独立线程处理该 transfer，主循环立即回接下一个 RRQ。
前提保证（均已满足）：
- catalog 只读快照（TFTP 路径只读 catalog）
- per-transfer TID socket 已隔离（`server.zig:353-354`）
- 无共享可写状态（transfer 计数器用 atomic）

并发上限由配置项 `max_concurrent_transfers` 控制，超过时新 RRQ 返回 TFTP 错误让客户端退避重试。

### 7.3 配置项

`TftpConfig`（`model.zig:85-96`）扩展：

```zig
pub const TftpConfig = struct {
    asset_root: []const u8,
    windowsize: u16 = 4,             // 1-65535，默认 4
    max_concurrent_transfers: u8 = 4, // 0/1=串行，2-64=有界并发
};
```

`NodeConfig`（`model.zig:528-560`）新增节点级 HTTP 加速属性：

```zig
pub const NodeConfig = struct {
    // ... existing fields ...
    deploy: bool = true,
    /// M4.2 F4: HTTP 加速下载 kernel/initrd（默认开启）
    http_accel: bool = true,
};
```

`HttpConfig` 新增 `max_connections: u16 = 0`（0=不限；M6 压测后固化，M4.2 仅记录不强制）。

### 7.3.1 HTTP 加速（`node.http_accel`，实验性）

> **实验性功能**：默认禁用（`false`）。实测发现即使 kernel 走 TFTP，GRUB 为
> initrd 建立 TCP 连接时仍可能触发 EFI 内存碎片化，导致后续 kernel 加载失败
> （`out of memory`）。仅在确认目标 GRUB 构建和 EFI 固件内存充裕时才可尝试启用。

**问题根因**：GRUB 的 TFTP 客户端不支持 RFC 7440 windowsize。即使服务端配置
`windowsize=4`，GRUB 的 RRQ 包不含 windowsize option，服务端回退到
`windowsize=1`（stop-and-wait）。每个 DATA 块（1468 字节）需等一个 ACK 往返，
吞吐被 RTT 限制为约 2 MB/s。106 MB initrd 下载需 52 秒。

**解决方案**：节点级 `http_accel` 属性（**默认 `false`**，实验性）。启用时 `transferVirtualConfig`
将 GRUB 配置中的 initrd 路径渲染为 `(http,server:port)/boot/<path>`
设备记法。kernel 始终走 TFTP（GRUB EFI 内存限制，见下方安全小节）。
禁用时 kernel/initrd 均走 TFTP。
HTTP 服务器在 `/boot/<path>` 路由从 `tftp.asset_root` 提供文件。

**实现文件**：
- `src/model.zig`：`NodeConfig.http_accel` 字段
- `src/tftp/server.zig`：`transferVirtualConfig` 根据 `node.http_accel` 分支渲染
- `src/http/server.zig`：`bootFileRoute` + `bootFile` 处理 `GET /boot/<path>`
- `src/catalog.zig`：`findAssetByPath` 按路径查找 catalog asset
- `src/config/node_mutation.zig`：`AddParams`/`SetParams` 新增 `http_accel`
- `src/main.zig`：`node add`/`node set` 新增 `--http-accel` flag

**安全**：`/boot/` 路由复用 catalog 白名单 + `validateRelativePath` 双重校验，
无需认证（GRUB 无法携带 bearer token）。catalog asset SHA-256 作为 ETag，
支持 `If-Range` 条件请求和 Range 续传。**GRUB HTTP Range 兼容**：GRUB 下载完整文件后
发送 `Range: bytes=<size>-` 做完整性验证；服务端返回 206 + 0 字节而非 416，
避免 GRUB 中止启动。`offset > size` 仍返回 416。**GRUB EFI 内存限制**：
GRUB 的 ARM64 Linux loader 在 `grub_file_open()` 获取文件大小后立即调用
`grub_efi_allocate_pages()` 分配内核缓冲区。GRUB 的 TCP/HTTP 模块自身占用大量
EFI 连续内存页，导致剩余连续内存不足以分配 13 MB 内核缓冲区，报出
`can not alloc kernel buffer` 或 `out of memory` 并关闭 TCP 连接（tcpdump 可见 GRUB 在仅收到 ~43 KB
后发 FIN+RST）。即使 kernel 走 TFTP，GRUB 为 initrd 建立 TCP 连接时仍可能
触发 EFI 内存碎片化，导致后续 kernel 加载失败（实测 `out of memory`）。
因此 `http_accel` 默认禁用，仅作为实验性功能保留。

**前置条件**：GRUB 二进制需含 `http` 模块（`strings grubaa64.efi | grep net/http`）。
大多数发行版 GRUB UEFI 构建默认包含。

**M6 继承**：`http_accel` 仅对 GRUB UEFI 链路生效。BIOS PXELINUX 固定使用
`pxelinux.0`（只支持 TFTP），`http_accel` 对 BIOS 节点无效，kernel/initrd
始终通过 TFTP 传输。详见 DESIGN.md §5.2.1。

### 7.4 客户端省略 blksize 时的主动建议

客户端发送了至少一个已识别 option（证明支持 RFC 2347 option extension）但省略 `blksize` 时，服务端
在 OACK 中主动建议 `blksize=1468`（Ethernet MTU 最优值，将 RFC 1350 默认 512 字节/块升级，吞吐约 3 倍）。
不覆盖客户端显式发送的 `blksize`，不返回大于客户端请求值的 `blksize`（RFC 2348），不对零 option 客户端
发送 OACK。`windowsize` 不主动建议：未请求时保持 stop-and-wait，避免破坏不支持 RFC 7440 的客户端。
大文件优化优先使用节点级 HTTP 加速，或使用确实支持 RFC 7440 的 TFTP 客户端。

### 7.5 校验

- `windowsize` 协商后，DATA 块序号回绕处理（block number 是 u16，超过 65535 回绕到 0）。
- `max_concurrent_transfers` 达到上限时，新 RRQ 返回 TFTP 错误 + message "server busy, retry later"，
  客户端退避重试。

### 7.6 `awaitAck` 健壮等待循环

**问题**：原 `awaitAck` 在收到任何非预期包（错误 TID、重复 ACK、格式错误包）时立即返回
`UnexpectedAck`，导致整个传输失败。GRUB 在 OACK 协商期间偶尔发送重复 ACK 或延迟包，
触发此竞态条件。虽然 GRUB 会重试 RRQ 并成功完成传输，但第一次失败可能使 GRUB 的
UEFI 网络栈进入不一致状态，最终导致 "could not seed network packet" 错误。

**修复**：将 `awaitAck` 改为在超时窗口内循环等待，忽略非预期包并继续等待预期 ACK。
行为规则（与 tftpd-hpa / dnsmasq 一致）：

- 来自错误 TID 的包：按 RFC 1350 发送 ERROR(code=5) 并继续等待
- 格式错误的包：忽略并继续等待
- 重复 ACK（错误块号）：忽略并继续等待
- 客户端 ERROR 包：记录日志并终止传输（返回 `error.UnexpectedAck`）
- 超时：返回 `error.Timeout`（调用方决定是否重传）

超时窗口使用 `boot_session.monotonicNow()` 跟踪截止时间，每次收到非预期包后
重新计算剩余时间并继续等待，确保总等待时间不超过原始 `timeout` 值。

### 7.7 末尾块 ACK 乐观完成与指数退避重传（2026-07-17 并发模型修订）

§7.6 描述 `awaitAck` 的**单包**健壮性，超时仍返回 `error.Timeout`。本节规定**调用方**
（`transfer`/`transferFromMemory` 的重传循环）对 `error.Timeout` 的处理，纠正 `e14b15f`
「末尾块 ACK 丢失即失败 + 发 ERROR 包」的误判。

- **末尾块乐观完成**：当前等 ACK 的块若是最后一块（`last_read < settings.block_size`），
  重传 `final_block_retries=2` 次仍零 ACK，日志记录 `delivery unconfirmed` 后返回已发送字节数，
  不发 TFTP ERROR。DATA 是否送达无法从 ACK 缺失中判定，因此不得写成 RFC 保证的成功。
- **非末尾块失败**：中途块 ACK 超时表示数据确实不完整，重传 `max_retries=5` 次后返回
  `error.Timeout`（对齐 dnsmasq「中途超时为错误、末尾超时为成功」；区别于 tftpd-hpa
  对两种情况都 `exit(0)` 的无差别语义）。
- **指数退避**：`default_timeout` 1s 基线，每次重传 timeout 翻倍封顶 255（`backoffSeconds`）。
  末尾块累计 ~7s（1+2+4），非末尾块 ~63s（1+2+4+8+16+32，对齐 `TRIES=6`）。客户端
  RFC 2349 `timeout` option 仍按协商值放大基线。
- **并发模型边界**：tftpd-hpa 的 timeout handler 在常见 fork/inetd 模型中退出单个请求进程；
  NodeForge 的 detached worker 共享全局 `max_concurrent_transfers` 槽、session 和事件状态。
  因此中途超时必须返回失败并释放共享状态，末尾短预算只是有界资源策略，不能复制 `exit(0)` 语义。
- **OACK 与 TID**：OACK 等 ACK0 时同样执行 `max_retries=5` 指数退避并复用 transfer TID。
  一旦 OACK/DATA 已发送，失败不得另绑临时端口发 ERROR；只有 transfer socket 建立前的初始 RRQ
  校验错误可从新 TID 返回 ERROR。

纯决策逻辑（`RetryAction`/`retryAction`/`retryLimit`/`backoffSeconds`）与 socket 解耦，
有单元测试覆盖；`transfer`/`transferFromMemory` 接线复用同一决策。

## 8. F5：免密公钥配置化

### 8.1 多公钥配置

`ServerConfig`（`model.zig:51-64`）新增字段：

```zig
ssh_authorized_public_keys: []const []const u8 = &.{},
// 多个公钥，全部注入 authorized_keys（去重）。空数组时回退到现有单值逻辑。
```

解析优先级更新（`admin_key.zig:19-29`）：

1. `ssh_authorized_public_keys` 数组（非空）-> 全部采用，不读其他来源；
2. `ssh_authorized_public_key` 单值（非空）-> 采用（向后兼容）；
3. `assets/keys/` 下所有 `*.pub` 文件 -> 全部读取注入；
4. `/root/.ssh/id_rsa.pub`、`/root/.ssh/id_ed25519.pub`（可读）-> 读取注入；
5. 已持久化 generated key -> 读取注入；
6. 全部不可用 -> 生成新 Ed25519 pair 并持久化。

**所有来源的公钥都注入**（去重，按 `(algorithm, key blob)`），允许多 key 免密。

### 8.2 assets/keys 目录作为公钥仓库

`assets/keys/` 现在可以存放多个 `*.pub` 文件（不再只是单个 `id_ed25519.pub`）。
配置中 `ssh_authorized_public_keys` 只接受相对 `assets/keys/` 下的文件名（如 `id_ed25519.pub`、
`ops-key.pub`），daemon 在 `assets/keys/` 下解析。**不接受绝对路径或目录穿越**。

### 8.3 诊断需求

操作员需要能快速定位"注入的公钥 ≠ ssh 用的私钥"问题：查看当前生效的每个公钥的来源类别、fingerprint、path。

## 8.5 F9：boot-gate 事件去重

### 8.5.1 问题根因

`offerAfterProbe`（`dhcp/server.zig:177-210`）在处理每个 DHCP DISCOVER/REQUEST 包时都会调用
`resolveWithDeployment` 检查 `install_not_armed` 和 `deploy_disabled` 标志。当标志为 true 时，
`emitInstallNotArmed`/`emitDeployDisabled` 直接调用 `Writer.appendWithFields` 写入 events.jsonl。

DHCP 协议的特性决定了**一次节点启动周期必然产生多个 DHCP 包**：

| 阶段 | 包类型 | 数量 |
|------|--------|------|
| PXE 固件引导 | DISCOVER → OFFER → REQUEST → ACK | 4 |
| OS 内核/initrd 加载后重新获取 DHCP | DISCOVER → OFFER → REQUEST → ACK | 4 |
| lease 续约（T1 = lease_time/2） | REQUEST → ACK | 2/周期 |

因此一个未武装的安装节点在**数秒内**会产生 8-10+ 条 `boot.install_not_armed` 事件。
`Writer.appendWithFields`（`events.zig:69-108`）只做字段校验、轮转和原子追加，
**没有任何去重或限速逻辑**。

同理 `boot.deploy_disabled`（F2 引入）在 `deploy=false` 节点上也有完全相同的泛滥问题。

### 8.5.2 设计选型

| 方案 | 优点 | 缺点 | 选择 |
|------|------|------|------|
| 时间窗口限速（N 秒内最多 1 条） | 实现简单 | 窗口外的重复仍会写入；不同节点互相干扰 | ✗ |
| per-node + per-event-type 计数 | 精确 | 需维护两个维度状态 | ✗ |
| **per-node 状态转换去重** | 精确，语义清晰，无时间窗口 | daemon 重启后重新触发一次 | **✓** |

选择**状态转换去重**：只在节点的 boot-gate 状态**发生变化**时才写事件。
状态不变时抑制，回到 normal 时静默清除（不写"恢复"事件）。

### 8.5.3 状态机

每个被跟踪的节点维护一个三态状态机：

```
                 install retry / deploy=true
    ┌──────────────────────────────────────────┐
    ▼                                          │
 ┌────────┐  not_armed   ┌──────────┐          │
 │ normal │ ──────────►  │ not_armed│          │
 └────────┘              └──────────┘          │
    │  deploy_disabled         │                │
    │  ┌───────────────────────┘                │
    ▼  ▼                                        │
 ┌────────────────┐                             │
 │ deploy_disabled│                             │
 └────────────────┘                             │
    │                                           │
    └───────────────────────────────────────────┘
                 install retry / deploy=true
```

| 状态转换 | 写事件？ | 说明 |
|----------|---------|------|
| `normal → not_armed` | **是** | 首次检测到未武装 |
| `not_armed → not_armed` | 否 | DHCP 重传/续约，状态未变 |
| `not_armed → normal` | 否 | 节点被重新武装，静默清除 |
| `normal → deploy_disabled` | **是** | 首次检测到 deploy=false |
| `deploy_disabled → deploy_disabled` | 否 | DHCP 重传/续约，状态未变 |
| `deploy_disabled → normal` | 否 | deploy 恢复 true，静默清除 |
| `not_armed → deploy_disabled` | **是** | 状态类型变化 |
| `deploy_disabled → not_armed` | **是** | 状态类型变化 |

### 8.5.4 实现

#### `BootGateSuppressor`（`src/state/runtime.zig`）

固定大小数组（64 槽位），per-node 跟踪 `last_state`。集成在 `DhcpState.gate_suppressor` 中，
随 `RuntimeState` 生命周期存在。状态仅在内存中，不持久化——daemon 重启后会重新触发一次事件，
这是可接受的（重启本身需要操作员关注）。

```zig
pub const BootGateSuppressor = struct {
    pub const max_tracked = 64;
    const State = enum { normal, not_armed, deploy_disabled };
    // ...
    pub fn shouldEmit(self: *BootGateSuppressor, node_id: []const u8,
        not_armed: bool, deploy_disabled: bool) bool;
};
```

#### `offerAfterProbe` 集成（`src/dhcp/server.zig`）

```zig
const decision = resolver.resolveWithDeployment(...);
if (decision.node_id) |node_id| {
    if (runtime.dhcp.gate_suppressor.shouldEmit(
        node_id, decision.install_not_armed, decision.deploy_disabled
    )) {
        if (decision.install_not_armed) emitInstallNotArmed(io, persistence, node_id);
        if (decision.deploy_disabled) emitDeployDisabled(io, persistence, node_id);
    }
}
```

#### 槽位回收

64 个槽位在实践中有余量（一个 PXE 子网的活跃节点数通常 < 64）。槽位耗尽时复用第一个槽位
（LRU 风格），最久未活跃的节点的状态会被重置为 `normal`，下一次该节点发 DHCP 包时会重新
触发一次事件——这是安全的降级行为。

### 8.5.5 不影响审计完整性

去重只影响 `boot.install_not_armed` 和 `boot.deploy_disabled` 两类**服务器侧诊断事件**。
DHCP 审计事件（`dhcp.discover`/`dhcp.offer`/`dhcp.ack` 等）不受影响，每个 DHCP 包仍会产生
完整的审计记录。操作员仍可以从 DHCP 审计事件看到节点的每次 DHCP 交互，只是不会被重复的
boot-gate 诊断事件淹没。

## 9. F6：CLI 8 顶层资源模型

### 9.1 既有 CLI 设计逻辑回顾

文档（`DESIGN.md:1612-1628` §11.3 命令格式规范）定义了 CLI 的 canonical form：

```
nodeforge <resource> [subresource] <action> [object] [options]
```

核心原则：
1. **resource-action 层级**：根命令 -> 资源命令 -> 动作命令（三层，`DESIGN.md:1578`），`-h/--help` 在每层可用。
2. **命令树是唯一事实源**（`DESIGN.md:1577`）：声明一次，解析和分级帮助从同一份声明生成。
3. **动词在后**：`<resource> <action>`，action 跟在 resource 之后。
4. **动词一致**：同类资源用同一组动作名，不混用 delete/remove、check/validate、get/show（`DESIGN.md:1608`）。
5. **避免重复入口**：不定义 `help`/`version` 子命令（`DETAILED_DESIGN.md:795`）。
6. **少量融合入口**：`status`/`check` 等高频快捷入口允许，但帮助中说明等价关系（`DESIGN.md:1620-1628`）。

### 9.2 当前命令树的问题

当前 13 个扁平顶层命令混合了三种东西：
- **资源**：config、catalog、node、asset
- **子系统**：tftp、dhcp、runtime
- **操作**：install、trace

操作员无法从命令名推断"我要管理什么资源"。

| 偏差 | 说明 |
|------|------|
| `runtime` 独立于 `dhcp` | DHCP 运行态（leases/unknown）应归入运行态资源，不是独立顶层 |
| `trace` 独立 | `trace` 接收 `node_id`，是节点操作，应归入 `node` |
| `install-source` + `asset` 分离 | 两者同属资产管理，应归入同一资源 |
| `install` group 混杂 | description 说 "preview" 但含 `retry`（mutation）；`render`/`retry` 都按 node 操作 |
| `node` 仅有 `list` | 缺 `add`/`set`/`remove`/`show`，节点属性无法 runtime 调整 |
| `deploy` 无 CLI | deploy 是节点属性但无 `node set --deploy` 接口 |
| 每加新特性加新顶层 | `admin-key` 若独立加则成为第 14 个扁平命令 |

### 9.3 8 顶层资源模型

校准为 **8 个顶层资源**，每个资源有明确的语义和 action 清单：

```
nodeforge <resource> <action> [object] [options]

融合入口:
  status                          服务状态
  check                           健康检查

8 顶层资源:
  node       节点资源（身份、属性、部署生命周期）
  assets     资产资源（ISO/kernel/initrd/rootfs/SSH key 导入和管理）
  config     配置资源（启动配置校验/导入/diff/apply）
  catalog    目录资源（catalog.json 只读查看/校验/导出）
  runtime    运行态资源（DHCP leases/TFTP sessions/服务运行状态）
  events     审计资源（事件历史查询/跟踪/类型）
  profile    策略资源（本稿原留 M6；M4.3 提前只读 list/show）
  provision  供应资源（provisioning bundle/step/run 管理，M7）
```

**设计原则**：
1. 每个顶层是一个**资源**，不是子系统或操作。`tftp`/`dhcp` 不再是顶层（运行态查看归 `runtime`，配置归
   `config`）；`install`/`trace` 不再是顶层（归入 `node` 的 action）。
2. action 名**语意化**：`add`/`set`/`remove`/`list`/`show` 是 CRUD；`import`/`validate`/`render`/`retry`
   是资源特有操作。单资源运行态查询只有一个 action 时省略 `list`（如 `runtime dhcp-leases`）。
3. `deploy` 是 `node set` 的一个 flag（`node set <id> --deploy false`），不是独立命令。
4. 构建产物（rootfs/initrd/boot-bundle）归入 `assets`（它们是导入/构建的资产），不独立顶层。
5. 后续里程碑新增命令必须遵循同一 resource-action canonical form。

### 9.4 各资源 action 清单与里程碑归属

```
═══ node（节点资源）═══
  list                  列出所有已注册节点                        [M4.2 迁移]
  show <id>             查看节点声明属性                           [M4.2 新增]
  add <id>              添加节点（--mac --arch --profile --ip...） [M4.2 新增]
  set <id>              修改节点属性（--deploy --ip --mac...）     [M4.2 新增]
  remove <id>           移除节点                                   [M4.2 新增]
  render <id>           预览渲染后的安装 answer                    [M4 迁移]
  retry <id>            重新 arm 下一次 PXE 安装 generation        [M4 迁移]
  trace <id>            重构 boot-session 时间线                    [M2.5 迁移]
  # M5 新增:
  diskless-status <id>  查看无盘启动状态                           [M5]
  diskless-retry <id>   重新允许下一次无盘启动                      [M5]
  diskless-overlay <id> 更新无盘 overlay 配置                      [M5]

═══ assets（资产资源）═══
  import <path>         导入 ISO/资产 [--type] [--distro]...        [M3 迁移]
  list                  列出所有资产                                [M1 迁移]
  show <name>           查看资产详情                                [M1 迁移]
  validate              校验资产文件和 SHA-256                     [M1 迁移]
  # SSH key 管理（F5）:
  key-import <path>     导入 bootstrap 公钥                         [M4.2 新增]
  key-reload            校验并有序重启加载 bootstrap 公钥           [M4.2 新增]
  key-show              显示生效公钥来源+fingerprint               [M4.2 新增]
  key-list              列出 assets/keys/*.pub                     [M4.2 新增]
  # M5 新增:
  rootfs-package        构建 rootfs squashfs                         [M5]
  rootfs-validate       校验 rootfs                                  [M5]
  initrd-build          构建小 initrd                                [M5]
  initrd-validate       校验 initrd                                  [M5]
  boot-bundle-publish   发布 diskless kernel+initrd+rootfs 组合     [M5]

═══ config（配置资源）═══
  validate              校验配置和 catalog 引用关系                 [M0 已有]
  export                导出规范化配置 JSON                         [M0 已有]
  import <path>         离线导入配置（全量替换）                    [M0 已有]
  # M6 新增:
  diff                  对比两个配置快照，分类展示影响              [M6]
  apply                 在线应用配置变更                            [M6]

═══ catalog（目录资源；M4.3 前仅只读）═══
  validate              校验 catalog 对象和 config 引用关系         [M0 已有]
  export                导出 catalog JSON                          [M0 已有]
  # M4.2 当时规划（M4.3 已覆盖）:
  show <name>           展开 install-source/repo/asset 关系链       [改由 M4.3]
  migrate --dry-run/--apply --plan-digest                           [M4.3]

═══ runtime（运行态资源）═══
  status                服务运行态概要                              [M4.2 新增]
  dhcp-leases           列出活动 DHCP 租约                          [M2 迁移]
  dhcp-unknown          列出未认领 DHCP 客户端                      [M2 迁移]
  tftp-counters         查看 TFTP 传输计数器                         [M1 迁移]
  tftp-sessions         查看 TFTP 传输会话                           [M1 迁移]

═══ events（审计资源）═══
  list                  查询事件历史                                [M2.5 已有]
  follow                实时跟踪新事件                              [M2.5 已有]
  types                 列出注册的事件类型                          [M2.5 已有]

═══ profile（策略资源；M4.3 覆盖）═══
  list/show                                                       [改由 M4.3]
  add/update/remove/validate                                      [M6]

═══ provision（供应资源，M7）═══
  bundle-list/show/create/validate/publish/plan                    [M7]
  step-add/remove                                                  [M7]
  run-show/status                                                  [M7]
```

### 9.5 迁移映射

| 旧命令 | 新命令 | 资源 |
|--------|--------|------|
| `install-source import` | `assets import` | assets |
| `asset import/list/show/validate` | `assets import/list/show/validate` | assets |
| `install render/retry` | `node render/retry` | node |
| `trace` | `node trace` | node |
| `runtime leases list` | `runtime dhcp-leases` | runtime |
| `runtime unknown list` | `runtime dhcp-unknown` | runtime |
| `dhcp show` | `config`（只读静态）/ `runtime`（运行态） | config/runtime |
| `tftp show` | `runtime tftp-counters` | runtime |
| `tftp session list` | `runtime tftp-sessions` | runtime |
| `node list` | `node list` | node |
| `config/catalog/events` | 不变 | 各自资源 |
| `status/check` | 不变 | 融合入口 |
| - | `node add/set/remove/show` | 新增（M4.2） |
| - | `assets key-import/reload/show/list` | 新增（F5） |

旧路径保留 deprecated alias 一个版本周期（zli `deprecated=true` + `replaced_by`），执行时输出 warning。
`buildCli` 拆分为按资源的 `register*Commands` 函数。

### 9.6 节点资源变更与 reload

`node add/set/remove` 是本机管理员命令：CLI 执行 load-modify-validate-save，复用 `config_store.save` 的
tmp+fsync+rename 原子写回，再调用 localhost-only 的 `POST /api/v1/management/config/reload`。daemon 在接受
reload 前重新解析并校验磁盘配置，响应成功后执行完整有序 shutdown，由 systemd `Restart=always` 拉起新实例。

该方案有约 2 秒的可配置重启窗口，但避免在运行中替换被 DHCP/TFTP/HTTP 多线程借用的 config slice。
若写盘成功而 reload 请求失败，CLI 返回非零并明确提示配置已保存、需手工重启，不能谎报“即时生效”。
`deploy` 仍通过 `node set <id> --deploy false` 管理，与 `--ip`/`--mac`/`--profile` 同级。

`profile`/`repository` 等 config 资源的 CRUD 管理 API 不在 M4.2 范围（留 M6）。distro 由后续 ISO 导入
事务自动维护，不提供独立 CRUD。

### 9.7 安装目录资源化布局

`/opt/nodeforge` 当前 14 个子目录按子系统散放，操作员无法从目录名推断对应的 CLI 资源。
M4.2 校准为资源化布局：

```
/opt/nodeforge/
├── bin/                         # 二进制软链接
├── systemd/                     # systemd unit
├── config/                      # 【config 资源】config.json
├── catalog/                     # 【catalog 资源】catalog.json
├── assets/                      # 【assets 资源】所有大文件资产统一根
│   ├── iso/                     #   ISO（原 assets/）
│   ├── boot/                    #   kernel/initrd/grub（原 tftp/）
│   ├── repos/                   #   APT/DNF 仓库树（原 /repos/）
│   ├── rootfs/                  #   M5 rootfs（原 /rootfs/）
│   ├── initrd/                  #   M5 initrd（原 /initrd/）
│   ├── bundles/                 #   M5 boot-bundle（原 /bundles/）
│   └── keys/                    #   M4.2 SSH 公钥（原 state/bootstrap-ssh/）
├── state/                       # 【runtime 资源】运行态快照
│   ├── leases.json
│   ├── node-status.json
│   ├── deployment-control.json
│   └── provisioned/             #   M7 结果（原 /provisioned/）
├── logs/                        # nodeforged.log + events.jsonl
├── work/                        # 临时工作目录
└── run/                         # PID 等
```

路径变更：`tftp/` -> `assets/boot/`，`repos/` -> `assets/repos/`，`state/bootstrap-ssh/` -> `assets/keys/`，
`provisioned/` -> `state/provisioned/`，`initrd/` -> `assets/initrd/`，`rootfs/` -> `assets/rootfs/`，
`bundles/` -> `assets/bundles/`，`assets/`（原有 ISO） -> `assets/iso/`。`paths.zig` 是唯一安装根事实源；
`packaging/install-layout.sh` 迁移目录、改写 config/catalog 并移除旧路径。

### 9.8 后续里程碑 CLI 声明

> **M4.3 覆盖**：下列内容是 M4.2 当时的规划。现行边界已把 install-source 的只读 `catalog show` 和旧 catalog
> 的 digest-protected migrate plan/apply 和只读 profile list/show 提前到 M4.3；M6 仍保留 profile 写操作、
> repository CRUD、distro 派生索引诊断、支持矩阵
> 和 config diff/apply，其余 M5/M7 命令归属不变。

M4.2 只校准 M0-M4.1 已有的命令并新增 node CRUD 和 assets key 管理。后续里程碑新增命令必须遵循同一
resource-action canonical form：
- **M5** 新增 `assets rootfs-package`/`initrd-build`/`boot-bundle-publish` 和 `node diskless-status`/`diskless-retry`/
  `diskless-overlay`。`diskless-retry` 受 `deploy=false` 限制（§4.5）。
- **M6** 在 M4.3 `profile list/show` 上新增 `profile add/update/remove/validate`、`config diff/apply`、
  profile/repository 写 CRUD 和 distro 派生索引诊断、
  `node render --format pxelinux`（BIOS PXELINUX 预览）。
- **M7** 新增 `provision bundle-list/show/create/validate/publish/plan`、`provision step-add/remove`、
  `provision run-show/status`。

## 10. 测试策略

### 10.1 单元测试

| 领域 | 测试 |
|------|------|
| F1 | `/logs` 接收 reason+summary 并持久化；subiquity-report handler 正确映射事件；kickstart `%onerror` 含 traceback |
| F2 | `deploy=false` 节点 resolve 返回 bootfile=null, known=true, mode=null；仍发 lease；generation gate 被绕过 |
| F3 | 各 family 前缀归一 rocky（含 Sugon OS/BigCloud-Enterprise-Linux）；Debian 检测；`--distro` 覆盖跳过检测；未识别 ISO 友好错误 |
| F4 | windowsize 协商 OACK；块序号回绕；并发上限排队 |
| F5 | 多公钥去重；assets/keys 目录扫描；CLI import 复制+校验；reload 刷新 context |
| F6 | 8 资源命令路径均可用；旧命令输出 deprecation warning；node add/set/remove 原子写回 config.json；`assets key-*` 可用 |
| F9 | `BootGateSuppressor` 状态转换去重：首次 not_armed 写事件，后续抑制；状态恢复后再次 not_armed 重新写事件；多节点独立追踪；`deploy_disabled` 与 `not_armed` 独立追踪 |

### 10.2 集成测试

- Kickstart `%onerror` 注入失败 -> 验证 `/logs` 收到 `install.anaconda_error` + summary。
- Ubuntu `reporting` 块 -> Subiquity 发送 HTTP 事件 -> nodeforged 收到 `install.partitioning` 等阶段。
- `deploy=false` 节点 PXE 引导 -> 验证无 bootfile 但 DHCP lease 存在，事件 `boot.deploy_disabled`。
- 导入 openEuler/Kylin/Sugon OS ISO -> 验证归一 rocky + kickstart 渲染正常。
- TFTP windowsize=4 vs windowsize=1 -> 验证吞吐提升（QEMU PXE，但 GRUB 不协商 windowsize）。
- `node.http_accel=true` -> GRUB 配置含 `(http,host:port)/boot/<path>` URL；
  `GET /boot/<path>` 返回 200 + ETag；`node set --http-accel false` -> 回退 TFTP。
- `Range: bytes=<size>-` -> 206 + 0 字节（GRUB 完整性验证兼容）；`bytes=<size+1>-` -> 416。
- 106 MB initrd via HTTP < 5s vs via TFTP ~52s。
- `assets key-import` -> `assets key-reload` -> `node render` -> 验证 answer 含新公钥。
- `node add` -> `node set --deploy false` -> `node show` -> `node remove` -> 验证 config.json 原子写回、reload 请求和重启后生效。

## 11. 文件变更清单

| 文件 | 变更 |
|------|------|
| `src/model.zig` | `NodeConfig.deploy`、`NodeConfig.http_accel`、`TftpConfig` 扩展、`HttpConfig.max_connections`、`ServerConfig.ssh_authorized_public_keys`、`InstallSourceConfig.source_label` |
| `src/boot/resolver.zig` | `resolve()` 加 `deploy` 守卫（mode 判定前） |
| `src/catalog/iso_import.zig` | RHEL family 白名单归一（含 Sugon OS/BigCloud-Enterprise-Linux）、Debian 检测、`applyRequestedTuple` 覆盖语义、友好错误 |
| `src/tftp/server.zig` | windowsize 协商、per-client 并发、配置项消费、`transferVirtualConfig` 读取 `node.http_accel` 分支渲染 HTTP URL |
| `src/tftp/packet.zig` | windowsize option 常量 |
| `src/server/admin_key.zig` | 多来源解析、state 目录扫描 |
| `src/profile/adapter/kickstart.zig` | `%onerror` 增强（traceback 捕获 + curl /logs） |
| `src/profile/adapter/ubuntu.zig` | `reporting:` 块、`error-commands` 增强（curtin env 捕获 + curl /logs） |
| `src/http/server.zig` | 新增 `/subiquity-report` 路由；新增 `/boot/<path>` HTTP 加速路由（`bootFileRoute`+`bootFile`）；`answerFixture` 新增 `log_url`；新增受限 config reload 路由 |
| `src/http/client.zig` | 新增 node add/set/remove + node status 客户端函数 |
| `src/http/contracts.zig` | 新增 reason 常量 + node mutation DTO |
| `src/config/store.zig` | 新增增量写回函数（node add/set/remove 原子修改 config.json） |
| `src/state/event_types.zig` | `install.anaconda_error`、`install.subiquity_error`、`boot.deploy_disabled` |
| `src/state/runtime.zig` | `BootGateSuppressor` 结构（per-node 状态转换去重）、`DhcpState.gate_suppressor` 字段 |
| `src/main.zig` | CLI 8 资源模型（buildCli 拆分 + 新命令树 + deprecated alias + node CRUD + assets key-* + `--http-accel` flag） |
| `src/catalog.zig` | 新增 `findAssetByPath()` 按路径查找 catalog asset（供 `/boot/` 路由 ETag 查找） |
| `src/config/node_mutation.zig` | `AddParams`/`SetParams` 新增 `http_accel` 字段 |
| `src/boot/grub.zig` | 新增 HTTP URL 格式渲染测试 |
| `src/dhcp/server.zig` | `offerAfterProbe` 集成 `BootGateSuppressor` 去重守卫 |
| `src/paths.zig` | 安装目录资源化路径变更（tftp->assets/boot, repos->assets/repos, bootstrap-ssh->assets/keys 等） |
| `src/app.zig` | bootstrap_key 改为 key 列表；reload 支持 |
| `src/config/validate.zig` | 新字段校验 |
| `config.example.json` | TFTP 新配置项 + 资源化路径默认值 |
| `tests/cli.sh` | 8 资源命令树 + deprecated alias + node CRUD 断言 |
| `tests/fixtures/` | openEuler/Kylin/Sugon OS/Debian ISO 检测 fixture |

## 12. 验收标准

1. Kickstart `%onerror` 触发时 -> `/logs` 收到 `install.anaconda_error` + summary（含 Anaconda traceback 截断）。
2. Ubuntu `reporting` 块 -> Subiquity 进度事件到达 nodeforged，`install.partitioning`/`packages` 等阶段可见。
3. `node set <id> --deploy false` -> 节点 DHCP lease 存在但无 PXE bootfile，事件 `boot.deploy_disabled`；
   generation gate 被绕过。`node set <id> --deploy true` 恢复。
4. openEuler/Kylin/CentOS/RHEL/Sugon OS ISO -> `assets import` 成功，catalog distro=rocky，source_label 记原始 family。
5. `assets import --distro rocky --version 9.7 --arch aarch64` -> 跳过自动检测。
6. TFTP windowsize=16 -> QEMU PXE 传输吞吐显著优于 windowsize=1（基准对比）。
7. `assets key-import /root/.ssh/id_ed25519.pub` -> `assets/keys/` 存在；`assets key-reload` ->
   `node render` 输出含新公钥；`assets key-show` 显示来源与 fingerprint。
8. `node add node-01 --mac 02:aa:bb:cc:dd:ef --arch aarch64 --profile rocky-install` -> config.json 原子写回，
   reload 完成后 `node list` 可见；`node set node-01 --ip 192.168.50.101 --deploy false` -> 重启后生效；
   `node show node-01` 显示声明属性；`node remove node-01` -> 移除。
9. `nodeforge node list/show/render/retry/trace` 可用；旧 `install render` 输出 deprecation warning 且仍执行。
10. `nodeforge runtime dhcp-leases` / `dhcp-unknown` / `tftp-counters` / `tftp-sessions` 可用
    （旧 `runtime leases list`/`tftp session list` 输出 warning）。
11. 所有新 reason 值在 `event_types.zig` 注册、在 M6 §11.5 错误分类表有 retryability 条目。
12. CLI 命令树符合 8 顶层资源模型：每个顶层是资源，action 语意化。
13. 安装目录资源化：`assets/boot/`、`assets/repos/`、`assets/keys/` 等新路径存在且 config 默认值指向新路径。
14. 未武装节点连续发 8+ 个 DHCP 包 -> events.jsonl 中只有 **1 条** `boot.install_not_armed` 事件（状态转换去重生效）；
    重新武装后再次未武装 -> 第 2 条事件。`boot.deploy_disabled` 同理。

## 13. M4.1 基线继承

M4.2 不获得绕过 M4.1 TargetSystemConfig 的权限。`profile.system` 仍是 SSH/root/users/password/locale/
防火墙/SELinux 的权威事实源。bootstrap admin key 合并去重规则（§9.10.6.2）不变，只是来源从单值扩展为
多值数组 + state 目录扫描。kickstart/autoinstall 渲染仍消费 normalized plan，adapter 不读 `/root/.ssh`
或 state 文件。

post-install 命令的异常容忍语义（kickstart `%post --erroronfail`、ubuntu `late-commands` `&&` 串接）
保持现状，不在 M4.2 范围内。
