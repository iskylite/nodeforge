# M8：部署链路健壮性、密钥可维护性与传输性能加固

- 日期：2026-07-14
- 状态：设计修订中（待实现）
- 依赖：M0-M4.1 基线；与 M5/M6/M7 正交，可独立交付
- 插入位置：`docs/DETAILED_DESIGN.md` §13 M8

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

## 2. 设计目标

1. **错误可观测**：安装阶段任何系统（kickstart/autoinstall）的部署错误信息能传回 nodeforged。
2. **节点可控**：即使 MAC/IP/profile 匹配，也能显式标记某节点"不部署"。
3. **主流 OS 可导入**：支持 RHEL 系（含国产化）+ Ubuntu + Debian，`--distro` 等参数可覆盖自动解析。
4. **TFTP 快**：实现 windowsize + 并发 + 配置项，消除结构性的慢。
5. **免密可维护**：公钥可配置多个、可 CLI 导入、可重载、可诊断。
6. **CLI 有序**：校准命令树至文档定义的 resource-action 模型，扁平化层级，新特性归入合理分组。

## 3. 非目标

- **不改动 post-install 命令的异常容忍语义**（kickstart `%post --erroronfail`、ubuntu `late-commands` `&&` 串接保持现状）。
- 不实现 diskless initrd 的事件上报（M5 范畴）。
- 不实现 installed 节点首启动/运行时 agent（M7 范畴）。
- 不为每个国产化发行版建独立 adapter 能力表；全部归一复用 kickstart。
- 不改动 HTTP 传输路径（已用 sendfile + Range + 120s 超时，性能良好）。
- 不改动 DHCP 端口（69）/ HTTP 端口绑定策略（保持 M2 设计）。

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

`NodeConfig`（`model.zig:515-530`）新增字段：

```zig
deploy: bool = true,
// true:  正常参与 PXE 部署/无盘（默认，向后兼容）
// false: 即使 MAC/IP/profile 匹配，也不下发 PXE bootfile；仍发诊断 DHCP lease
```

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

> Ubuntu Autoinstall 原生支持 HTTP webhook（`autoinstall.reporting` 的 `http` callback）；
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

#### 5.3.3 Ubuntu Autoinstall（Subiquity，原生 reporting + 降级 curl）

`renderUserDataM41` 新增 `reporting:` 块，声明 Subiquity 原生 HTTP callback：

```yaml
reporting:
  nodeforge:
    type: http
    endpoint: http://{server_ip}:{http_port}/api/v1/nodes/{node_id}/subiquity-report
    headers:
      Authorization: "Bearer {token}"
      X-NodeForge-Session: "{session}"
```

Subiquity `type: http` reporting 向 endpoint POST JSON 事件（含 `event`/`level`/`message`），
无需 OAuth credentials。NodeForge capability bearer token 通过 `headers` 注入。

新增 `subiquityReport` handler（`server.zig`）+ 路由 `POST /api/v1/nodes/:id/subiquity-report`：
将 Subiquity JSON 事件映射到 `install.*` 阶段（复用 `mapStage` `server.zig:811-824`）：

| Subiquity event | nodeforge stage | event_type |
|-----------------|-----------------|------------|
| `STARTED` | `started` | `install.started` |
| `PARTITIONING` | `partitioning` | `install.partitioning` |
| `PACKAGES` | `packages` | `install.packages` |
| `BOOTLOADER` | `bootloader` | `install.bootloader` |
| `DONE` | `completed` | `install.completed` |
| `ERROR` | `failed` | `install.failed` |

Capability 鉴权复用现有 `authenticateCapability`（`boot_session.zig:370`）。

`early-commands`/`late-commands`/`error-commands` 的手写 curl 保留为降级路径（reporting 不可用时兜底，
均带 `|| true`）。`error-commands` 增强：捕获 curtin env vars（`ERROR_CMD`/`ERROR_STATUS`/`ERROR_TRACEBACK`）
curl `/logs`，reason `install.subiquity_error`。

### 5.4 新增端点汇总

| 方法 | 路由 | 鉴权 | 用途 |
|------|------|------|------|
| POST | `/api/v1/nodes/:id/subiquity-report` | capability | 接收 Subiquity 原生 reporting HTTP callback |

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
  Ubuntu/Debian: detected via .disk/info
  Hint: specify --distro <rocky|ubuntu|debian> --version <X> --arch <Y> to override
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

`TftpConfig`（`model.zig:78-81`）扩展：

```zig
pub const TftpConfig = struct {
    asset_root: []const u8,
    max_blksize: u16 = 1468,        // 8-65464，默认 1468（以太网 MTU 友好）
    windowsize: u16 = 16,           // 1-65535，默认 16
    timeout_seconds: u8 = 3,        // 1-255
    max_concurrent_transfers: u8 = 8, // 1-64
};
```

`HttpConfig` 新增 `max_connections: u16 = 0`（0=不限；M6 压测后固化，M8 仅记录不强制）。

### 7.4 客户端不协商时的优化

客户端不发送 blksize option 时，OACK 主动建议 1468（部分客户端接受服务器建议值）。
不发送 windowsize 时，按 RFC 7440 默认 windowsize=1（保持兼容）。

### 7.5 校验

- `windowsize` 协商后，DATA 块序号回绕处理（block number 是 u16，超过 65535 回绕到 0）。
- `max_concurrent_transfers` 达到上限时，新 RRQ 返回 TFTP 错误 + message "server busy, retry later"，
  客户端退避重试。

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
3. `state/bootstrap-ssh/` 下所有 `*.pub` 文件 -> 全部读取注入；
4. `/root/.ssh/id_rsa.pub`、`/root/.ssh/id_ed25519.pub`（可读）-> 读取注入；
5. 已持久化 generated key -> 读取注入；
6. 全部不可用 -> 生成新 Ed25519 pair 并持久化。

**所有来源的公钥都注入**（去重，按 `(algorithm, key blob)`），允许多 key 免密。

### 8.2 state/bootstrap-ssh 目录作为公钥仓库

`state/bootstrap-ssh/` 现在可以存放多个 `*.pub` 文件（不再只是单个 `id_ed25519.pub`）。
配置中 `ssh_authorized_public_keys` 只接受相对 `state/bootstrap-ssh/` 下的文件名（如 `id_ed25519.pub`、
`ops-key.pub`），daemon 在 `state/bootstrap-ssh/` 下解析。**不接受绝对路径或目录穿越**。

### 8.3 诊断需求

操作员需要能快速定位"注入的公钥 ≠ ssh 用的私钥"问题：查看当前生效的每个公钥的来源类别、fingerprint、path。

## 9. F6：CLI 命令体系校准

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
6. **最多 3 个命令词**：canonical form 隐含上限为 resource + [subresource] + action（`DESIGN.md:1617`）。
7. **少量融合入口**：`status`/`check` 等高频快捷入口允许，但帮助中说明等价关系（`DESIGN.md:1620-1628`）。

### 9.2 当前命令树的问题

当前 13 个扁平顶层命令（`main.zig:266-280`）与上述设计逻辑的偏差：

| 偏差 | 说明 |
|------|------|
| `runtime` 独立于 `dhcp` | DHCP 运行态（leases/unknown）应是 `dhcp` 的子命令，`runtime` 是 CLI-only 概念，config 模型中不存在 |
| `trace` 独立于 `events`/`node` | `trace` 读取 events JSONL 且接收 `node_id`，应归入 `node`（按节点查询） |
| `install-source` + `asset` 分离 | 两者同属 boot media/资产注册，应归入同一 resource |
| `install` group 混杂 | description 说 "preview" 但含 `retry`（mutation）；`render`/`retry` 都按 node 操作 |
| `node` 仅有 `list` | 缺 `show`，节点详情散落到 `trace`/`install render` |
| 每加新特性加新顶层 | `admin-key` 若独立加则成为第 14 个扁平命令 |

### 9.3 校准后的命令树（扁平化，遵循 resource-action 模型）

校准原则：**resource 即顶层，action 紧随其后，不引入 subresource 中间层**（保持最多 2 个命令词）。
例外仅限逻辑上确实是子资源的（如 `dhcp leases` vs `dhcp unknown` 是两种不同运行态）。

```
nodeforge [-v|--version] <command> [options]

① Daemon & health
  status                         Show daemon lifecycle status (online)
  check                          Run health checks, set exit code (online)

② Configuration & catalog
  config   <validate|export|import>
  catalog  <validate|export>

③ Install media & boot assets
  media import <iso-path> [--distro] [--version] [--arch]   Import ISO, publish install source (online)
  media list                     List install sources + assets (offline)
  media show <name>              Show one install source / asset detail (offline)
  media validate                 Verify media asset files and SHA-256 (offline)
  media key import <path> [--rename NAME]   Import bootstrap public key (offline)
  media key reload               Reload bootstrap keys without restart (online)
  media key show                 Show effective keys + source + fingerprint (mixed)
  media key list                 List state/bootstrap-ssh/*.pub files (offline)

④ Nodes & install lifecycle
  node list                      List registered nodes (offline)
  node show <id>                 Show node detail + status + deployment (mixed)
  node render <id>               Render unattended install answer (offline)
  node retry <id>                Rearm next PXE install generation (online)
  node trace <id>                Reconstruct boot-session timeline (offline)

⑤ PXE service inspection
  dhcp show                      Show DHCP subnet and pool config (offline)
  dhcp leases                    List active DHCP leases (online)
  dhcp unknown                   List unclaimed DHCP clients (online)
  tftp show                       Show TFTP transfer counters (online)
  tftp sessions                   Show recent TFTP transfer sessions (online)

⑥ Audit
  events <list|follow|types>
```

### 9.4 设计决策说明

**admin-key 归入 `media` 还是独立？**

`media key` 而非独立 `admin-key`，理由：
- bootstrap key 是"用于登录已部署节点的管理凭据"，与 install media（部署源）紧密相关。
- key 的存储路径 `state/bootstrap-ssh/` 与 install/source 在同一 state 目录树下。
- 避免新增第 14 个顶层命令，符合"按领域分组而非按特性加命令"原则。
- `media key <action>` 仍是 resource-action 二词结构（`media` = resource, `key` = 子资源限定,
  `import`/`reload`/`show`/`list` = action），符合 canonical form 的 `[subresource]` 槽位。

**`media list` 合并 install source + asset？**

当前 `install-source` 和 `asset` 各有 list/show/validate。校准后：
- `media list`：列出 install sources（含 source_label、distro、version、arch、状态）+ 关联 assets。
- `media show <name>`：展示一个 install source 的完整详情（含关联的 iso/kernel/initrd/repo assets）。
- `media validate`：校验所有 media asset 文件存在性 + SHA-256。
- 单独 asset 的 import（非 ISO 路径的 bootloader/kernel 注册）保留为 `media asset import`，
  但属于低频操作，不单独列顶层；通过 `media import --type <kind>` 统一入口（`--type` 已存在于现有
  `asset import`，`main.zig:325`）。

**`dhcp leases` / `dhcp unknown` / `tftp sessions` 为何不用 `list` 动词？**

这些是单资源的运行态查询，只有一个 action（列出），加 `list` 会变成 `dhcp leases list`（3 词）。
省略 `list` 后 `dhcp leases` / `dhcp unknown` / `tftp sessions` 仍是 resource-action 二词结构
（`dhcp` = resource, `leases`/`unknown` = action/sub-resource合一），更扁平。
`events list` 保留 `list` 因为 `events` 有 `list`/`follow`/`types` 多个 action 需区分。

### 9.5 迁移映射

| 旧命令 | 新命令 | 说明 |
|--------|--------|------|
| `install-source import` | `media import` | 合并 |
| `asset import` | `media import --type <kind>` | 统一入口 |
| `asset list` | `media list` | 合并 |
| `asset show <name>` | `media show <name>` | 合并 |
| `asset validate` | `media validate` | 合并 |
| `install render` | `node render` | 移入 node |
| `install retry` | `node retry` | 移入 node |
| `trace` | `node trace` | 移入 node |
| `runtime leases list` | `dhcp leases` | runtime->dhcp, 去掉 list |
| `runtime unknown list` | `dhcp unknown` | runtime->dhcp, 去掉 list |
| `dhcp show` | `dhcp show` | 不变 |
| `tftp show` | `tftp show` | 不变 |
| `tftp session list` | `tftp sessions` | 去掉 list, session->sessions |
| `node list` | `node list` | 不变 |
| `config/catalog/events` | 不变 | |
| `status/check` | 不变 | |
| - | `node show` | 新增 |
| - | `media key import/reload/show/list` | 新增（F5） |

### 9.6 向后兼容

旧路径在 M8 发布后保留 deprecated alias 一个版本周期（zli `deprecated=true` + `replaced_by="..."`，
`zli.zig:168-169`）。执行旧命令时输出 deprecation warning 到 stderr，指向新命令。
`tests/cli.sh` 新增旧命令仍可执行但输出 warning 的断言。

### 9.7 buildCli 拆分

`buildCli`（`main.zig:60-282`，当前 220 行单函数）拆分为按领域的注册函数：
- `registerDaemonCommands(root, opts)`
- `registerConfigCommands(root, opts)` (config + catalog)
- `registerMediaCommands(root, opts)` (media + media key)
- `registerNodeCommands(root, opts)`
- `registerPxeCommands(root, opts)` (dhcp + tftp)
- `registerAuditCommands(root, opts)` (events)

每个函数注册一个分组及其子命令，`buildCli` 仅做组装。

## 10. 测试策略

### 10.1 单元测试

| 领域 | 测试 |
|------|------|
| F1 | `/logs` 接收 reason+summary 并持久化；subiquity-report handler 正确映射事件；kickstart `%onerror` 含 traceback |
| F2 | `deploy=false` 节点 resolve 返回 bootfile=null, known=true, mode=null；仍发 lease；generation gate 被绕过 |
| F3 | 各 family 前缀归一 rocky（含 Sugon OS/BigCloud-Enterprise-Linux）；Debian 检测；`--distro` 覆盖跳过检测；未识别 ISO 友好错误 |
| F4 | windowsize 协商 OACK；块序号回绕；并发上限排队 |
| F5 | 多公钥去重；state/bootstrap-ssh 目录扫描；CLI import 复制+校验；reload 刷新 context |
| F6 | 新旧命令路径均可用；旧命令输出 deprecation warning；help 输出符合 resource-action 结构；`media key` 在 `media --help` 下显示 |

### 10.2 集成测试

- Kickstart `%onerror` 注入失败 -> 验证 `/logs` 收到 `install.anaconda_error` + summary。
- Ubuntu `reporting` 块 -> Subiquity 发送 HTTP 事件 -> nodeforged 收到 `install.partitioning` 等阶段。
- `deploy=false` 节点 PXE 引导 -> 验证无 bootfile 但 DHCP lease 存在，事件 `boot.deploy_disabled`。
- 导入 openEuler/Kylin/Sugon OS ISO -> 验证归一 rocky + kickstart 渲染正常。
- TFTP windowsize=16 vs windowsize=1 -> 验证吞吐提升（QEMU PXE）。
- `media key import` -> `media key reload` -> `node render` -> 验证 answer 含新公钥。

## 11. 文件变更清单

| 文件 | 变更 |
|------|------|
| `src/model.zig` | `NodeConfig.deploy`、`TftpConfig` 扩展、`HttpConfig.max_connections`、`ServerConfig.ssh_authorized_public_keys`、`Catalog.source_label` |
| `src/boot/resolver.zig` | `resolve()` 加 `deploy` 守卫（mode 判定前） |
| `src/catalog/iso_import.zig` | RHEL family 白名单归一（含 Sugon OS/BigCloud-Enterprise-Linux）、Debian 检测、`applyRequestedTuple` 覆盖语义、友好错误 |
| `src/tftp/server.zig` | windowsize 协商、per-client 并发、配置项消费 |
| `src/tftp/packet.zig` | windowsize option 常量 |
| `src/server/admin_key.zig` | 多来源解析、state 目录扫描 |
| `src/profile/adapter/kickstart.zig` | `%onerror` 增强（traceback 捕获 + curl /logs） |
| `src/profile/adapter/ubuntu.zig` | `reporting:` 块、`error-commands` 增强（curtin env 捕获 + curl /logs） |
| `src/http/server.zig` | 新增 `/subiquity-report` 路由 + handler；`answerFixture` 新增 `log_url` 构造 |
| `src/http/contracts.zig` | 新增 reason 常量 |
| `src/state/event_types.zig` | `install.anaconda_error`、`install.subiquity_error`、`boot.deploy_disabled` |
| `src/main.zig` | CLI 校准（buildCli 拆分 + 新命令树 + deprecated alias + `media key` 子命令） |
| `src/app.zig` | bootstrap_key 改为 key 列表；reload 支持 |
| `src/config/validate.zig` | 新字段校验 |
| `config.example.json` | TFTP 新配置项示例 |
| `tests/cli.sh` | 新命令树 + deprecated alias 断言 |
| `tests/fixtures/` | openEuler/Kylin/Sugon OS/Debian ISO 检测 fixture |

## 12. 验收标准

1. Kickstart `%onerror` 触发时 -> `/logs` 收到 `install.anaconda_error` + summary（含 Anaconda traceback 截断）。
2. Ubuntu `reporting` 块 -> Subiquity 进度事件到达 nodeforged，`install.partitioning`/`packages` 等阶段可见。
3. `deploy=false` 节点 -> DHCP lease 存在但无 PXE bootfile，事件 `boot.deploy_disabled`；
   generation gate 被绕过（即使 armed 也不给 bootfile）。
4. openEuler/Kylin/CentOS/RHEL/Sugon OS ISO -> 导入成功，catalog distro=rocky，source_label 记原始 family。
5. `--distro rocky --version 9.7 --arch aarch64` -> 跳过自动检测，直接采用。
6. TFTP windowsize=16 -> QEMU PXE 传输吞吐显著优于 windowsize=1（基准对比）。
7. `media key import /root/.ssh/id_ed25519.pub --rename ops.pub` -> `state/bootstrap-ssh/ops.pub` 存在；
   `media key reload` -> `node render` 输出含 ops.pub 公钥；`media key show` 显示来源与 fingerprint。
8. `nodeforge node list/show/render/retry/trace` 均可用；旧命令 `install render` 输出 deprecation warning
   且仍执行；`nodeforge media key show` 显示生效公钥来源与 fingerprint。
9. `nodeforge dhcp leases` / `nodeforge dhcp unknown` / `nodeforge tftp sessions` 可用
   （旧 `runtime leases list` 输出 warning）。
10. 所有新 reason 值在 `event_types.zig` 注册、在 M6 §11.5 错误分类表有 retryability 条目。
11. CLI 命令树符合 resource-action 模型：每个顶层命令是 resource，子命令是 action，
    最多 2 个命令词（`media key import` 是唯一的 3 词例外，因为 `key` 是 subresource 限定）。

## 13. M4.1 基线继承

M8 不获得绕过 M4.1 TargetSystemConfig 的权限。`profile.system` 仍是 SSH/root/users/password/locale/
防火墙/SELinux 的权威事实源。bootstrap admin key 合并去重规则（§9.10.6.2）不变，只是来源从单值扩展为
多值数组 + state 目录扫描。kickstart/autoinstall 渲染仍消费 normalized plan，adapter 不读 `/root/.ssh`
或 state 文件。

post-install 命令的异常容忍语义（kickstart `%post --erroronfail`、ubuntu `late-commands` `&&` 串接）
保持现状，不在 M8 范围内。
