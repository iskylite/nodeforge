# M8：部署链路健壮性、密钥可维护性与传输性能加固

- 日期：2026-07-14
- 状态：已批准（待实现）
- 依赖：M0-M4.1 基线；与 M5/M6/M7 正交，可独立交付
- 插入位置：`docs/DETAILED_DESIGN.md` 新增 §13 M8，原 §13-§18 顺移为 §14-§19

## 1. 背景与问题陈述

M4/M4.1 交付了 kickstart/autoinstall 渲染、受控 post-install provisioning 和安装生命周期事件上报，
但在实机验证中暴露六组缺陷，外加 CLI 命令体系结构性问题。本里程碑在不改变 M4.1 TargetSystemConfig 归一
模型的前提下，修复部署链路的健壮性、可维护性和传输性能。

### 1.1 缺陷清单

| # | 缺陷 | 根因（file:line 证据） | 影响 |
|---|------|------------------------|------|
| F1 | post-install 命令异常容忍语义不一致 | Kickstart `%post --erroronfail`（`kickstart.zig:149`）+ 裸命令无 `set -e` + 尾部 curl `\|\| true` → 中途失败被静默吞掉；Ubuntu `late-commands` 用 `&&` 串成单条（`ubuntu.zig:179`）→ 一点失败即中止安装。两者语义相反且不可配置。`provision/runner.zig:52-89` 生成的命令无任何错误包裹。 | Kickstart 静默吞错、Ubuntu 过度中止；失败无诊断 |
| F2 | 部署错误信息未传回 nodeforged | `/api/v1/nodes/:id/logs` 端点与 `LogSummary` schema（`contracts.zig:28`）已完整实现但**无任何模板调用它**；失败仅发空 `{stage:"failed"}`；`%onerror`/`error-commands` 只 POST stage 不带 stderr。 | nodeforged 只知"失败"不知"为何" |
| F3 | 无法对已匹配节点禁用 PXE 部署 | `NodeConfig`（`model.zig:515-530`）无 deploy 标志；唯一抑制是 arch 不匹配 / unknown wait / install-not-armed gate（`resolver.zig:51-81`）。 | 即使 MAC/IP/profile 匹配也无法显式标记"不部署" |
| F4 | ISO 导入仅认 Rocky+Ubuntu，不支持 RHEL 系变体与国产化 OS | `.treeinfo` family 前缀硬编码 `Rocky`（`iso_import.zig:271`）；`--distro`/`--version`/`--arch` 是断言（mismatch 即 fail）非覆盖（`iso_import.zig:243-247`）。 | CentOS/RHEL/Alma/Fedora/openEuler/Kylin 等无法导入；覆盖语义缺失 |
| F5 | TFTP 性能差 | 未实现 RFC 7440 windowsize（每块 ACK 往返，`server.zig:445-464`）；单线程串行处理让并发客户端排队（`server.zig:59-121`）；无性能配置项（`TftpConfig` 仅有 `asset_root`，`model.zig:78-81`）。 | PXE 初始阶段 TFTP 传输慢 |
| F6 | 免密公钥不可更新，注入的公钥可能 ≠ 操作员私钥 | 公钥仅启动时解析一次（`app.zig:81`）；不覆盖已生成对（`admin_key.zig:24-29`）；解析优先级是 config 单值 → /root/.ssh → 已生成 → 生成。 | 若初始自动生成 key 后操作员设置了 /root/.ssh，daemon 仍持有旧 key |
| F7 | CLI 命令体系结构不合理 | 13 个扁平顶层命令；`runtime` 实为 DHCP 运行态却独立于 `dhcp`；`trace` 读取 events 数据却不在 `events` 下；`install-source` 与 `asset` 同属 boot media 却分离；`node` 仅有 `list`。 | 每加新特性就加新子命令，无分组逻辑 |

## 2. 设计目标

1. **不阻断安装**：post-install 业务步骤失败不导致安装异常，生命周期回调始终容忍。
2. **错误可观测**：安装阶段任何系统（kickstart/autoinstall）的部署错误信息能传回 nodeforged。
3. **节点可控**：即使 MAC/IP/profile 匹配，也能显式标记某节点"不部署/PXE 无盘"。
4. **主流 OS 可导入**：支持 RHEL 系（含国产化）+ Ubuntu + Debian，`--distro` 等参数可覆盖自动解析。
5. **TFTP 快**：实现 windowsize + 并发 + 配置项，消除结构性的慢。
6. **免密可维护**：公钥可配置多个、可 CLI 导入、可重载、可诊断。
7. **CLI 有序**：按领域分组重构命令树，新特性归入合理分组而非新增顶层命令。

## 3. 非目标

- 不实现 diskless initrd 的事件上报（M5 范畴）。
- 不实现 installed 节点首启动/运行时 agent（M7 范畴）。
- 不为每个国产化发行版建独立 adapter 能力表；全部归一复用 kickstart。
- 不改动 HTTP 传输路径（已用 sendfile + Range + 120s 超时，性能良好）。
- 不改动 DHCP 端口（69）/ HTTP 端口绑定策略（保持 M2 设计）。

## 4. F1：post-install 命令异常容忍

### 4.1 两段式执行模型

把 post-install 分为**生命周期段**和 **provisioning 段**，两者错误语义分离：

- **生命周期段**（`installer_started`/`started`/`post`/`completed`/`failed` 的 curl 回调）：始终 `\|\| true`，
  绝不阻断安装。这部分已在 M4.1 正确实现，保持不变。
- **provisioning 段**（`provision/runner.zig` 生成的 `repository`/`standard_packages`/`managed_file` 步骤）：
  每条命令失败时捕获退出码与 stderr 摘要，通过 `/api/v1/nodes/:id/logs` 上报，**然后继续执行后续步骤**，
  最终仍走 `completed`。默认 `continue`（不中止），关键步骤可声明 `abort`。

### 4.2 step 级容错字段

`ProvisionStep`（`model.zig:486-501`）新增可选字段：

```zig
on_failure: OnFailure = .continue_,
```

```zig
pub const OnFailure = enum { continue_, abort };
// continue_: 步骤失败时上报 reason+summary，继续后续步骤
// abort:     步骤失败时上报并中止 provisioning 段，仍走 failed/completed 生命周期
```

### 4.3 Kickstart 渲染变更

- `%post` 去掉 `--erroronfail`（`kickstart.zig:149`）→ provisioning 段失败不触发 Anaconda `%onerror`。
  理由：`--erroronfail` 的语义是"post 脚本非零退出即视为安装失败"，但 provisioning 步骤的失败不应回滚
  已完成的 OS 安装。
- provisioning 段每条命令包裹为：
  ```bash
  nodeforge_report_step_failure() {
    local step_n=$1 rc=$2 summary=$3
    curl -fsS -H 'Authorization: Bearer {token}' -H 'X-NodeForge-Session: {session}' \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -d "v=1&boot_session_id={session}&reason=install.post_step_failed&summary=step:${step_n} rc:${rc} ${summary}" \
      {log_url} || true
  }
  # ... 每步：
  <command> 2>/tmp/nodeforge-step-<N>.err || {
    nodeforge_report_step_failure <N> "$?" "$(head -c 2048 /tmp/nodeforge-step-<N>.err | tr '\n' ' ')"
  }
  ```
  `nodeforge_report_step_failure` 函数定义在 `%post` 开头（provisioning 段之前），由 renderer 注入。
  `log_url` 由 `answerFixture`（`server.zig:573`）构造为 `http://{server_ip}:{http_port}/api/v1/nodes/{node_id}/logs`，
  与 `event_url`（`server.zig:581`）并行注入到 answer 模板。
- `on_failure=abort` 的步骤失败后 `exit 1` 退出 provisioning 段（但不触发 `%onerror`，因为已去掉
  `--erroronfail`；后续 `completed` curl 仍执行）。

### 4.4 Ubuntu Autoinstall 渲染变更

- bundle 步骤不再用 `&&` 串成单条 list item（`ubuntu.zig:179`）→ 改为每条独立 list item：
  ```yaml
  late-commands:
    - curtin in-target --target=/target -- sh -c '<command> 2>/tmp/nf-step-<N>.err || <report>'
    - curtin in-target --target=/target -- sh -c '<command> ...'
  ```
  单条失败不影响后续条目（Subiquity 对 `late-commands` 的每个 list item 独立执行，一条失败不阻止后续）。
- `on_failure=abort` 的步骤用 `&& false` 终止后续，但 `error-commands` 仍只发 `failed` stage。

### 4.5 端点复用

不新增端点。复用已实现但未被调用的 `POST /api/v1/nodes/:id/logs`（`server.zig:708`，`nodeLog` handler）。
该端点已验证 `LogSummary{v, boot_session_id, reason, summary}` schema（`contracts.zig:28-33`），body 上限 4 KiB。
新增稳定 reason 值 `install.post_step_failed`，加入 `event_types.zig` 注册表和 M6 §11.5 错误分类表的 retryability。

## 5. F2：安装阶段错误全覆盖传回

### 5.1 Kickstart（Anaconda，无原生 HTTP webhook）

Anaconda 没有同等的 HTTP webhook 机制，NodeForge 继续用 `%pre`/`%onerror`/`%post` 主动 curl：

- `%pre`：`installer_started` + `started`（保持）。
- `%post`：provisioning 段每步失败时 curl `/logs`（§4.3）；完成后 curl `post` + `completed`。
- `%onerror`：增强为捕获 Anaconda 上下文后 curl `/logs`：
  ```bash
  %onerror
  ERRLOG=/tmp/anaconda-tb-*/anaconda-tb 2>/dev/null
  SUMMARY="anaconda error: $(head -c 2048 $ERRLOG 2>/dev/null | tr '\n' ' ')"
  curl -fsS -H 'Authorization: Bearer {token}' -H 'X-NodeForge-Session: {session}' \
    -d "v=1&boot_session_id={session}&reason=install.anaconda_error&summary=$SUMMARY" \
    {log_url} || true
  curl -fsS ... "stage":"failed" {event_url} || true
  %end
  ```
  新增 reason `install.anaconda_error`。

### 5.2 Ubuntu Autoinstall（Subiquity，原生 HTTP webhook）

Subiquity 原生支持 `autoinstall.reporting` 的 `http` callback，可向指定 URL POST 安装进度 JSON
（包含 `event`/`level`/`message` 等字段，覆盖 `partitioning`/`packages`/`bootloader` 等阶段）。
NodeForge 利用此原生机制补充手写 curl 无法覆盖的阶段：

- `renderUserDataM41` 新增 `reporting:` 块：
  ```yaml
  reporting:
    nodeforge:
      type: http
      endpoint: http://{server_ip}:{http_port}/api/v1/nodes/{node_id}/subiquity-report
  ```
  Subiquity `type: http` reporting 向 endpoint POST JSON 事件（包含 `event`/`level`/`message`），
  无需 OAuth credentials。NodeForge 的 capability bearer token 通过 Subiquity 的 `headers` 选项注入：
  ```yaml
  reporting:
    nodeforge:
      type: http
      endpoint: http://{server_ip}:{http_port}/api/v1/nodes/{node_id}/subiquity-report
      headers:
        Authorization: "Bearer {token}"
        X-NodeForge-Session: "{session}"
  ```
  Endpoint 指向新路由 `POST /api/v1/nodes/:id/subiquity-report`。
- 新增 `subiquityReport` handler（`server.zig`）：将 Subiquity 的 JSON 事件映射到 `install.*` 阶段
  （如 `Event.STARTED` → `install.started`、`Event.PARTITIONING` → `install.partitioning`、
  `Event.PACKAGES` → `install.packages`、`Event.DONE` → `install.completed`、`Event.ERROR` → `install.failed`），
  复用 `mapStage` 逻辑。Capability 鉴权（bearer token）复用现有机制。
- `early-commands`/`late-commands`/`error-commands` 的手写 curl 保留（作为 reporting 不可用时的降级路径，
  均带 `|| true`）。
- error-commands 增强：捕获 curtin env vars（`ERROR_CMD`/`ERROR_STATUS`/`ERROR_TRACEBACK`）填入 `/logs` 的 summary。
  新增 reason `install.subiquity_error`。

### 5.3 设计差异注记

> Ubuntu Autoinstall 原生支持 HTTP webhook；Kickstart/Anaconda 没有同等的 HTTP webhook，需要用 `%pre`、
> `%onerror`、`%post` 主动调用 HTTP API。这是两个安装器架构的固有差异，NodeForge 不强行统一：
> Subiquity 用原生 reporting + 降级 curl；Anaconda 纯用 curl。两路径都汇入 `/events` + `/logs` 端点，
> 事件类型和 reason 注册表统一。

### 5.4 新增端点汇总

| 方法 | 路由 | 鉴权 | 用途 |
|------|------|------|------|
| POST | `/api/v1/nodes/:id/subiquity-report` | capability | 接收 Subiquity 原生 reporting HTTP callback |

`/logs` 和 `/events` 端点已存在，仅接通调用方。

## 6. F3：节点级"不部署"开关

### 6.1 模型变更

`NodeConfig`（`model.zig:515-530`）新增字段：

```zig
deploy: bool = true,
// true:  正常参与 PXE 部署/无盘（默认，向后兼容）
// false: 即使 MAC/IP/profile 匹配，也不下发 PXE bootfile；仍发诊断 DHCP lease
```

### 6.2 resolver 变更

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

返回 `bootfile=null` 但 `known=true` + 保留 IP → DHCP 仍发 lease（诊断可达），TFTP 不下发任何文件。
适用于 install / diskless / discovery 全模式。

### 6.3 事件

新增 `boot.deploy_disabled` 事件类型（`event_types.zig`），在 DHCP offer 时记录被禁用节点。

### 6.4 校验

`validateNodes`（`validate.zig:361-378`）无需结构变更（默认 bool 永真）。仅文档说明 `deploy=false` 时
该节点不参与任何 PXE 引导，但仍占用保留 IP 且出现在 `node list` 中。

## 7. F4：ISO 导入支持主流 OS + 覆盖语义

### 7.1 RHEL 系 family 归一

`detectRockyMedia`（`iso_import.zig:258-281`）的 `family` 前缀检查从硬编码 `Rocky` 扩展为白名单：

```
Rocky | CentOS | CentOS Linux | CentOS Stream | RedHatEnterpriseServer |
RedHatEnterpriseLinux | AlmaLinux | Fedora | OracleLinux | ScientificLinux |
CloudLinux | EuroLinux |
# 国产化 RHEL 系
openEuler | Kylin | Kylin Linux Advanced Server | TencentOS | TencentOS-Server |
AnolisOS | UnionTech OS Server | UOS Server | npserver | TurboLinux
```

全部归一到 distro `rocky`（复用 kickstart adapter），catalog 新增 `source_label` 字段记录原始 family
供溯源。归一逻辑封装为 `normalizeRhelFamily(family) ?[]const u8`，返回归一名或 null。

### 7.2 Ubuntu / Debian 检测

- Ubuntu：沿用 `.disk/info` 解析（`iso_import.zig:308-335`），格式 `Ubuntu-Server 22.04.5 LTS "..." arm64 (...)`。
- Debian（新增）：检测 `.disk/info` 含 `Debian` 或 `.treeinfo` 存在时解析。version 取 major.minor。
  Debian 归一到 distro `ubuntu`（复用 autoinstall adapter，Debian 亦支持 cloud-init NoCloud）还是独立？
  **决定**：Debian 归一 `ubuntu`（autoinstall adapter），`source_label` 记 `Debian`。

### 7.3 `--distro`/`--version`/`--arch` 改为覆盖语义

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

### 7.4 友好错误

未识别 ISO 且未指定 `--distro` 时，返回结构化错误提示：

```
error: install-source: could not auto-detect distro from media metadata.
  Detected .treeinfo family: <value> (not in supported list)
  Supported families: Rocky, CentOS, RHEL, AlmaLinux, Fedora, openEuler, Kylin, ...
  Ubuntu/Debian: detected via .disk/info
  Hint: specify --distro <rocky|ubuntu|debian> --version <X> --arch <Y> to override
```

## 8. F5：TFTP 性能优化

### 8.1 windowsize (RFC 7440)

`negotiate`（`server.zig:445-464`）识别 `windowsize` option 并回 OACK。DATA 发送循环改为：
发 `windowsize` 个块后才等一个 ACK（而非每块等 ACK）。单 ACK 确认连续 `windowsize` 块。

### 8.2 per-client 并发

dispatcher（`server.zig:59-121`）收到 RRQ 后 spawn 独立线程处理该 transfer，主循环立即回接下一个 RRQ。
前提保证（均已满足）：
- catalog 只读快照（TFTP 路径只读 catalog）
- per-transfer TID socket 已隔离（`server.zig:353-354`）
- 无共享可写状态（transfer 计数器用 atomic）

并发上限由配置项 `max_concurrent_transfers` 控制，超过时新 RRQ 排队等待。

### 8.3 配置项

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

### 8.4 客户端不协商时的优化

客户端不发送 blksize option 时，OACK 主动建议 1468（部分客户端接受服务器建议值）。
不发送 windowsize 时，按 RFC 7440 默认 windowsize=1（保持兼容）。

### 8.5 校验

- `windowsize` 协商后，DATA 块序号回绕处理（block number 是 u16，超过 65535 回绕到 0）。
- `max_concurrent_transfers` 达到上限时，新 RRQ 返回 TFTP 错误 `errno=0`（未定义错误码）+ message
  "server busy, retry later"，客户端退避重试。

## 9. F6：免密公钥配置化 + CLI 导入

### 9.1 多公钥配置

`ServerConfig`（`model.zig:51-64`）新增字段：

```zig
ssh_authorized_public_keys: []const []const u8 = &.{},
// 多个公钥，全部注入 authorized_keys（去重）。空数组时回退到现有单值逻辑。
```

解析优先级更新（`admin_key.zig:19-29`）：

1. `ssh_authorized_public_keys` 数组（非空）→ 全部采用，不读其他来源；
2. `ssh_authorized_public_key` 单值（非空）→ 采用（向后兼容）；
3. `state/bootstrap-ssh/` 下所有 `*.pub` 文件 → 全部读取注入；
4. `/root/.ssh/id_rsa.pub`、`/root/.ssh/id_ed25519.pub`（可读）→ 读取注入；
5. 已持久化 generated key → 读取注入；
6. 全部不可用 → 生成新 Ed25519 pair 并持久化。

**所有来源的公钥都注入**（去重，按 `(algorithm, key blob)`），允许多 key 免密。

### 9.2 state/bootstrap-ssh 目录作为公钥仓库

`state/bootstrap-ssh/` 现在可以存放多个 `*.pub` 文件（不再只是单个 `id_ed25519.pub`）。
配置中 `ssh_authorized_public_keys` 只接受相对 `state/bootstrap-ssh/` 下的文件名（如 `id_ed25519.pub`、
`ops-key.pub`），daemon 在 `state/bootstrap-ssh/` 下解析。**不接受绝对路径或目录穿越**。

### 9.3 CLI 导入

新增 `nodeforge admin-key import`（CLI 重构后为 `nodeforge admin-key import`，见 §10）：

```
nodeforge admin-key import <path> [--rename <name>]
```

- `<path>`：外部公钥文件路径（绝对或相对）。
- `--rename <name>`：指定在 `state/bootstrap-ssh/` 下的文件名（如 `ops-key.pub`）。
  省略时用源文件 basename。
- 将公钥复制到 `state/bootstrap-ssh/<name>`，权限 0644，owner daemon 用户。
- 校验：OpenSSH 单行 public-key 格式、算法和 base64 blob。
- 支持目录：`<path>` 是目录时批量导入目录下所有 `*.pub`。

### 9.4 重载与生效

- `nodeforge admin-key reload`：重新解析公钥来源，刷新 `ServerContext` 缓存的 key 列表。
  不重启 daemon，但后续 `/answer` 渲染立即使用新 key 列表（renderer 每次渲染读 context，不持久旧值）。
- 已安装节点的 `authorized_keys` 不会自动更新 → 需重装或手动更新。CLI 输出明确提示：
  "Keys reloaded. Already-installed nodes require reinstall or manual authorized_keys update."

### 9.5 诊断

```
nodeforge admin-key show
```

输出当前生效的每个公钥：来源类别（config-array / config-single / state-dir / root-ssh / generated）、
fingerprint（SHA256）、path、algorithm。帮助快速定位"注入的公钥 ≠ 你 ssh 用的私钥"。

```
nodeforge admin-key list
```

列出 `state/bootstrap-ssh/` 下所有公钥文件（fingerprint + algorithm + path）。

## 10. F7：CLI 命令体系重构

### 10.1 设计原则

1. **按领域分组**：同类操作归入同一分组，而非每个新特性加新顶层命令。
2. **动词一致**：`list`/`show`/`import`/`validate`/`export` 等动词在各分组内复用。
3. **资源即分组**：config、catalog、media、node、dhcp、tftp、events、admin-key 各为一组。
4. **向后兼容**：旧命令路径在过渡期保留 deprecated alias（zli 支持 `deprecated`/`replaced_by`），
  一个版本周期后移除。
5. **离线/在线区分在 help**：每个命令 description 标注 (offline) 或 (online)。

### 10.2 新命令树

```
nodeforge [-v|--version] <command> [options]

① Daemon & health
  status                         Show daemon lifecycle status (online)
  check                          Run health checks, set exit code (online)

② Configuration & catalog
  config   <validate|export|import>     (offline / mixed)
  catalog  <validate|export>            (offline)

③ Install media & boot assets
  media <sub>
    import <iso-path>            Import one ISO, publish install source (online)
                                 [--distro] [--version] [--arch]  (override auto-detect)
    source <list|show <name>>    Install source registry (offline)
    asset  <import|list|show <name>|validate>

④ Nodes & install lifecycle
  node <sub>
    list                         List registered nodes (offline)
    show <id>                    Show one node detail + status + deployment (mixed)
    render <id>                  Render unattended install answer (offline)
    retry  <id>                  Rearm next PXE install generation (online)
    trace  <id>                  Reconstruct boot-session timeline (offline)

⑤ PXE service inspection
  dhcp <sub>
    show                         Show DHCP subnet and pool config (offline)
    leases list                  List active DHCP leases (online)
    unknown list                 List unclaimed DHCP clients (online)
  tftp <sub>
    show                         Show TFTP transfer counters (online)
    sessions list                Show recent TFTP transfer sessions (online)

⑥ Audit
  events <list|follow|types>     (offline)

⑦ Admin keys
  admin-key <sub>
    import <path> [--rename NAME]  Import public key to state/bootstrap-ssh/ (offline)
    reload                         Reload bootstrap keys without restart (online)
    show                           Show effective keys + source + fingerprint (mixed)
    list                           List state/bootstrap-ssh/*.pub files (offline)
```

### 10.3 迁移映射

| 旧命令 | 新命令 | 说明 |
|--------|--------|------|
| `install-source import` | `media import` | 合并 |
| `asset import/list/show/validate` | `media asset import/list/show/validate` | 移入 media |
| `install render` | `node render` | 移入 node |
| `install retry` | `node retry` | 移入 node |
| `trace` | `node trace` | 移入 node |
| `runtime leases list` | `dhcp leases list` | runtime → dhcp |
| `runtime unknown list` | `dhcp unknown list` | runtime → dhcp |
| `dhcp show` | `dhcp show` | 不变 |
| `tftp show` | `tftp show` | 不变 |
| `tftp session list` | `tftp sessions list` | session → sessions（动词一致） |
| `node list` | `node list` | 不变 |
| `config/catalog/events` | 不变 | |
| `status/check` | 不变 | |
| — | `node show` | 新增 |
| — | `media source list/show` | 新增 |
| — | `admin-key import/reload/show/list` | 新增 |

### 10.4 向后兼容

旧路径在 M8 发布后保留 deprecated alias 一个版本周期（zli `deprecated=true` + `replaced_by="..."`）。
执行旧命令时输出 deprecation warning 到 stderr，指向新命令。`tests/cli.sh` 新增旧命令仍可执行但输出
warning 的断言。

### 10.5 buildCli 拆分

`buildCli`（`main.zig:60-282`，当前 220 行单函数）拆分为按领域分组的注册函数：
- `registerDaemonCommands(root, opts)`
- `registerConfigCommands(root, opts)`
- `registerMediaCommands(root, opts)`
- `registerNodeCommands(root, opts)`
- `registerPxeCommands(root, opts)` (dhcp + tftp)
- `registerAuditCommands(root, opts)`
- `registerAdminKeyCommands(root, opts)`

每个函数注册一个分组及其子命令，`buildCli` 仅做组装。

## 11. 测试策略

### 11.1 单元测试

| 领域 | 测试 |
|------|------|
| F1 | runner 渲染的命令含 `\|\| report` 包裹；`on_failure=abort` 步骤失败后停止后续；kickstart 无 `--erroronfail` |
| F2 | subiquity-report handler 正确映射事件；`/logs` 接收 reason+summary 并持久化 |
| F3 | `deploy=false` 节点 resolve 返回 bootfile=null, known=true；仍发 lease |
| F4 | 各 family 前缀归一 rocky；Debian 检测；`--distro` 覆盖跳过检测；未识别 ISO 友好错误 |
| F5 | windowsize 协商 OACK；块序号回绕；并发上限排队 |
| F6 | 多公钥去重；state/bootstrap-ssh 目录扫描；CLI import 复制+校验；reload 刷新 context |
| F7 | 新旧命令路径均可用；旧命令输出 deprecation warning；help 输出分组 |

### 11.2 集成测试

- Kickstart provisioning 段故意注入失败命令 → 验证安装仍完成（`completed`）、`/logs` 收到 reason。
- Ubuntu `reporting` 块 → Subiquity 发送 HTTP 事件 → nodeforged 收到 `install.partitioning` 等阶段。
- `deploy=false` 节点 PXE 引导 → 验证无 bootfile 但 DHCP lease 存在。
- 导入 openEuler/Kylin ISO → 验证归一 rocky + kickstart 渲染正常。
- TFTP windowsize=16 vs windowsize=1 → 验证吞吐提升（QEMU PXE）。
- admin-key import → reload → install render → 验证 answer 含新公钥。

## 12. 文件变更清单

| 文件 | 变更 |
|------|------|
| `src/model.zig` | `NodeConfig.deploy`、`TftpConfig` 扩展、`HttpConfig.max_connections`、`ServerConfig.ssh_authorized_public_keys`、`ProvisionStep.on_failure`、`Catalog.source_label` |
| `src/boot/resolver.zig` | `resolve()` 加 `deploy` 守卫 |
| `src/catalog/iso_import.zig` | RHEL family 白名单归一、Debian 检测、`applyRequestedTuple` 覆盖语义、友好错误 |
| `src/tftp/server.zig` | windowsize 协商、per-client 并发、配置项消费 |
| `src/tftp/packet.zig` | windowsize option 常量 |
| `src/server/admin_key.zig` | 多来源解析、state 目录扫描、CLI import 逻辑 |
| `src/profile/adapter/kickstart.zig` | 去 `--erroronfail`、provisioning 段 `\|\| report` 包裹、`%onerror` 增强 |
| `src/profile/adapter/ubuntu.zig` | late-commands 拆分独立 list item、`reporting` 块、error-commands 增强 |
| `src/provision/runner.zig` | 每步包裹 report 函数调用 |
| `src/http/server.zig` | 新增 `/subiquity-report` 路由 + handler；`/logs` 端点接通 |
| `src/http/contracts.zig` | 新增 reason 常量 |
| `src/state/event_types.zig` | `install.post_step_failed`、`install.anaconda_error`、`install.subiquity_error`、`boot.deploy_disabled` |
| `src/main.zig` | CLI 重构（buildCli 拆分 + 新命令树 + deprecated alias） |
| `src/app.zig` | bootstrap_key 改为 key 列表；reload 支持 |
| `src/config/validate.zig` | 新字段校验 |
| `config.example.json` | TFTP 新配置项示例 |
| `tests/cli.sh` | 新命令树 + deprecated alias 断言 |
| `tests/fixtures/` | openEuler/Kylin/Debian ISO 检测 fixture |

## 13. 验收标准

1. Kickstart provisioning 段任一步骤失败 → 安装仍完成 `completed`，`/logs` 收到 `install.post_step_failed`。
2. Ubuntu `reporting` 块 → Subiquity 进度事件到达 nodeforged，`install.partitioning`/`packages` 等阶段可见。
3. `deploy=false` 节点 → DHCP lease 存在但无 PXE bootfile，事件 `boot.deploy_disabled`。
4. openEuler/Kylin/CentOS/RHEL ISO → 导入成功，catalog distro=rocky，source_label 记原始 family。
5. `--distro rocky --version 9.7 --arch aarch64` → 跳过自动检测，直接采用。
6. TFTP windowsize=16 → QEMU PXE 传输吞吐显著优于 windowsize=1（基准对比）。
7. `admin-key import /root/.ssh/id_ed25519.pub --rename ops.pub` → `state/bootstrap-ssh/ops.pub` 存在；
   `admin-key reload` → `install render` 输出含 ops.pub 公钥。
8. `nodeforge node list/show/render/retry/trace` 均可用；旧命令 `install render` 输出 deprecation warning
   且仍执行；`nodeforge admin-key show` 显示生效公钥来源与 fingerprint。
9. `nodeforge dhcp leases list` / `nodeforge dhcp unknown list` 可用（旧 `runtime leases list` 输出 warning）。
10. 所有新 reason 值在 `event_types.zig` 注册、在 M6 §11.5 错误分类表有 retryability 条目。
