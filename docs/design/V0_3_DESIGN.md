# NodeForge v0.3 设计：install-post canonical 扩展与 adapter capability matrix

状态：设计冻结，实现未开始。本文定义 v0.3 范围，与
[`V0_2_DESIGN.md`](V0_2_DESIGN.md) §2 版本表一致。
v0.3 在 v0.2.3 完成（[`V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md`](V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md) §10
完成标准）后启动。跨版本顺序见
[`V0_2_1_PLUS_ROADMAP.md`](V0_2_1_PLUS_ROADMAP.md)，实现细节与状态机见
[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md)，共用 CLI 契约见 [`V0_2_CLI.md`](V0_2_CLI.md) §0，
程序边界见 [`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md) §7。

BIOS x86 PXELINUX 已从本版本剥离，独立设计见
[`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)。

## 0. 设计动机与代码基线

v0.2.3 完成后，install-post phase 在代码中只支持三种受限动作
（`repository`、`standard_packages`、`managed_file`），而 rootfs-build/first-boot
已经使用四类 canonical action（`managed_file`/`archive`/`script`/`package`）。
install-post 的能力缺口是当前最大的实现差异：

| 维度 | rootfs-build / first-boot（v0.2 已实现） | install-post（当前代码） |
|---|---|---|
| 支持动作 | `managed_file`/`archive`/`script`/`package` | `repository`/`standard_packages`/`managed_file` |
| 执行契约 | 八步固定顺序 + 隔离执行 | 声明顺序，无隔离 |
| callback credential | per-session scoped token | 简单 bearer token，无 generation 绑定 |
| journal/status | `(boot_session_id, step_id)` journal | 无结构化 journal |
| 错误恢复 | retryable step 自动重试 + failure budget | 无自动重试 |

v0.3 关闭这组差异：把 install-post 从受限形态升级为完整 canonical phase，
与 rootfs-build/first-boot 统一执行模型，并补齐 callback credential 和
adapter capability matrix。

**不引入 catalog schema 变更**：`firmware.mode` 随 BIOS 一起延后
（见 [`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)）；
install-post 的四类 action 在 `ProvisionAction` enum 中已存在
（`src/model.zig`），只是 runner/validator 尚未接受。
因此 v0.3 **保持 catalog schema v5**，BootConfig v3 和 AgentPlan v1 不变。

## 1. 进入条件

v0.3 必须基于 v0.2.1/v0.2.2/v0.2.3 完成：

- v0.2.3 catalog schema v5（Profile identity/provenance）冻结，
  canonical BootSession 状态机、DHCP/TFTP/HTTP 协议栈与 effective
  compiler/readiness/validator 三项核心闭环已落地并通过验收。
- v0.2 schema v4 已存在的受限 `install-post` 兼容 runner 回归通过；
  `rootfs-build|first-boot` 四类 action 与八步执行契约已统一，
  v0.3 在此基础上扩展 install-post。
- v0.2.2 的持久状态升级兼容、durable operation、CLI 收口与固定回归矩阵全部通过。
- v0.1 install 侧 PXE/adapter/effective 在 v0.2 期间保持回归通过。

任何一项未完成时，v0.3 只能做隔离 spike，不能合入主产品路径。

## 2. 范围

v0.3 聚焦 **install-post canonical 扩展与发行版版本矩阵**：

| 项 | v0.3 范围 | 说明 |
|---|---|---|
| install-post 四类 canonical action | 是 | 扩展 `renderInstallPost` 接受 `managed_file`/`archive`/`script`/`package` |
| 旧受限 action 退出 | 是 | `repository`/`standard_packages` 按迁移表退出，不新增同义 action |
| install-post callback credential | 是 | per-generation credential capsule，hash-only 恢复 |
| install-post journal/status | 是 | `(node_id, install_generation, bundle_revision, plan_digest, step_id)` 标识 |
| 发行版版本矩阵 | 是 | Rocky/RHEL 系与 Ubuntu LTS 的显式 adapter capability matrix |
| 错误分类与长期运行回归 | 是 | bootloader/版本差异/错误分类 |

v0.3 **不**包含：BIOS PXELINUX（独立延后，见
[`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)）；多 NIC/VLAN/bonding、
大规模容量压测（-> v0.4）；install 侧 first-boot agent（-> v0.4）；
reconciliation/远程控制（永久非目标）。

## 3. 从 v0.1/v0.2 继承的强制契约

- v0.1 所有权模型、`/dev/...` 磁盘契约、`software.*` 双集合、`kernel_args.add/remove`、
  明文 password/默认用户不变式。
- v0.1 UEFI install 全部能力（单盘/LVM/RAID/RAID-LVM、repository/software capability、
  effective compiler）原样保留。
- v0.2 canonical phase 集合（`install-post|rootfs-build|first-boot`，无 `runtime`）、
  四类 action、八步执行契约、credential/session/lower 边界、finalizer、事件脱敏与
  幂等键不变。
- v0.2 diskless Node override 契约不变。
- v0.2 统一 `node list`/`node status` kind 感知投影。
- `show key == --help-full key == parser key == API operation path`；CLI 不得要求
  Shell 内嵌 JSON。

## 4. install-post canonical 扩展

### 4.1 当前实现状态

`src/provision/runner.zig` 的 `renderInstallPost` 当前只处理三种动作：

- `repository`：添加 dnf/apt 仓库（`dnf config-manager --add-repo` 或
  `echo > sources.list.d/`）
- `standard_packages`：安装包列表（`dnf -y install` 或
  `DEBIAN_FRONTEND=noninteractive apt-get -y install`）
- `managed_file`：写入受管文件（`printf %b` 或 `curl + sha256sum -c`）

对 `archive`/`script`/`package` 三类 canonical action，`renderInstallPost` 返回
`error.InvalidStep`。这意味着 install-post 无法使用 rootfs-build/first-boot 已经
支持的完整 provision 能力。

`src/profile/adapter/kickstart.zig` 和 `src/profile/adapter/ubuntu.zig` 在 `%post`
（Kickstart）或 `late-commands`（Autoinstall）中调用 `renderInstallPost` 嵌入安装后
步骤。事件上报通过 `%post` 末尾的 `curl` 命令携带 bearer token 和 session id。

### 4.2 目标模型

v0.3 将 install-post 扩展为与 rootfs-build/first-boot 一致的完整 canonical phase：

**四类 canonical action**（统一，跨三个 phase）：

| action | install-post 执行上下文 | 说明 |
|---|---|---|
| `managed_file` | 安装目标根 `/` | 与现有实现一致；inline content 或 asset download + digest |
| `archive` | 安装目标根 `/` | 按完整 archive 规则判定（见 §4.6） |
| `script` | 安装目标根 `/` | 受管脚本 asset，在安装目标根执行 |
| `package` | 安装目标根 `/` | 只引用 pinned effective software/capability，经本地 repository 解析校验、幂等 |

**八步执行契约**（固定顺序，与 rootfs-build/first-boot 一致）：

```text
文件更新(managed_file) -> package -> archive -> script
```

action 可修改安装目标根的 users/SSH/hosts/系统文件；credential/session 越权在
plan/validate 阶段拒绝，不能用 `--force` 绕过；finalizer 末尾重新断言 effective
顺序与离线策略。

**旧 action 退出**：

| 旧 action | 替代 | 迁移边界 |
|---|---|---|
| `repository` | `package` action 引用 pinned effective repository | 旧 bundle 中的 `repository` step 在 v0.3 validator 报错 `install_post.legacy_action_deprecated` |
| `standard_packages` | `package` action 引用 pinned effective software | 同上 |

不新增同义 action。迁移是操作员手动修改 bundle 定义，不提供自动迁移脚本。

**Profile 引用**：`install.post_install.bundle`（与 diskless 的
`diskless.provision.bundle` 对应，已在 `src/model.zig` `PostInstallConfig` 中存在）。

### 4.3 install-post 作为 deployment 完成闸

- `install-post` 是 deployment 完成闸：所有 step/finalizer 成功后才允许
  `install.completed`；失败不回写已经终止的 BootSession，但会终止当前 install
  generation。
- v0.3 不提供远程 step retry；重新执行必须由新的 install generation 完整重装，
  不能在已安装目标上远程补跑。
- install-post journal/status 以 `(node_id, install_generation, bundle_revision,
  plan_digest, step_id)` 标识，不能复用 diskless `boot_session_id` 假装安装器执行
  属于 BootSession。

### 4.4 install-post callback credential

install renderer 复用该 generation 的 append-only callback credential 上报
step/finalizer 状态。

**当前状态**：`src/profile/adapter/kickstart.zig` 和 `ubuntu.zig` 的 `%post`/`late-commands`
中直接嵌入 bearer token + session id 的 `curl` 命令。token 与 BootSession 绑定，
不与 install generation 绑定。

**v0.3 变更**：

- raw token 在 generation 创建时生成，通过随 installer initrd 加载的
  per-generation credential capsule 交付到
  `/run/nodeforge/credentials/install-callback.token`（0400）。
- token 不进入 kernel cmdline、catalog、公开渲染模板或日志；服务端只保存不可逆 hash。
- credential 绑定 `node_id/install_generation/plan_digest/audience/method/path/expiry`，
  并按单调 `event_seq` 去重。
- 它不能读取 catalog、触发 retry 或升级为 management credential。
- generation 终态/超时后立即撤销。
- daemon restart 后用持久 hash 继续验证，不能为同一 generation 静默生成第二个
  并行有效 token。
- `node_id + install_generation` 只是关联键，不能单独作为认证证明。

**capsule 恢复边界**：

raw capsule token 只驻内存：restart-resume 只保证 installer 已完整取得 token 后的
callback 阶段。capsule 尚未开始或传输中重启且 installer 未取得完整 token 时，本
generation attempt 标 `generation.recovery_incomplete`，不得由 hash 重建 token；
下一次安装启动创建新 generation。持久化 capsule delivery started/completed 只用于
审计和错误分类。

### 4.5 执行上下文差异

install-post 由安装器在安装期执行，**无 agent**：

| 维度 | install-post（v0.3） | rootfs-build（v0.2） | first-boot（v0.2） |
|---|---|---|---|
| 执行者 | 安装器（Kickstart `%post` / Autoinstall `late-commands`） | 服务端 rootfs builder | nodeforge-agent（切根后） |
| 目标上下文 | 安装中目标系统磁盘（已分区/格式化），`/` 为安装目标根 | staging 目录（chroot） | overlay upper / 内存根 |
| 持久化 | 写磁盘（install 永久） | 烤入只读 lower | 写 overlay upper / 内存根 |
| 触发 | 安装器渲染时嵌入 bundle 引用，安装期执行 | `profile rootfs build` | 切根后 systemd unit |
| 失败语义 | retryable step 只在同一 installer execution 内按声明自动重试；耗尽后令 deployment 进入 `install.failed` | builder 失败 | agent 失败 |

- 复用 v0.1 已有最小 install-post provision bundle（managed-file asset 驱动），
  **不改变其 Assets owner**。
- v0.3 将既有 phase 扩展为完整四类 action；旧 `repository`/`standard_packages`
  按迁移表退出。

### 4.6 archive action 详细设计

#### 4.6.1 为什么需要详细设计

archive 是唯一一个"同一个 action 有两种完全不同的执行语义"的 action。其他三类
（`managed_file`/`script`/`package`）的执行路径是确定的：managed_file 总是写文件、
script 总是跑脚本、package 总是装包。但 archive 需要在运行时**读取 tar 内容后才能
决定是"直接解压"还是"解压后执行脚本"**。

这个判定规则已在 v0.2 设计中冻结（[`V0_2_DESIGN.md`](V0_2_DESIGN.md) §5.4），
rootfs-build 和 first-boot 已按此规则实现。v0.3 的 install-post 必须遵循完全相同的
规则，不能为 install-post 新建第二套判定逻辑。

#### 4.6.2 判定规则

archive action 读取 tar 归档后，按以下规则判定执行模式：

```text
读取 tar 顶层条目列表
├── 顶层存在 ./install.sh  →  模式 A：解压到临时目录 + 执行 ./install.sh
└── 顶层不存在 ./install.sh  →  模式 B：直接解压到目标根 /
```

**模式 A：解压 + 执行（`./install.sh` 存在）**

1. 把 tar 解压到一个临时目录（如 `/tmp/.nodeforge-archive-<step_id>`）；
2. 以该临时目录为工作目录执行 `./install.sh`；
3. `install.sh` 退出码 0 视为成功，非 0 视为失败；
4. 执行完成后删除临时目录。

适用场景：应用安装包，归档内自带安装脚本（如解压后需要跑 `configure`、
`systemctl enable`、`useradd` 等操作）。

**模式 B：直接解压（`./install.sh` 不存在）**

1. 把 tar 直接解压到目标根 `/`（install-post 上下文中是安装目标磁盘根）；
2. tar 退出码 0 视为成功，非 0 视为失败。

适用场景：静态文件部署，如把一组配置文件、网页、二进制按目录结构直接铺到目标系统。

#### 4.6.3 代码现状对比

当前 rootfs-build/first-boot 的 archive 实现（`src/provision/first_boot.zig`
`renderStep` `.archive` 分支）**只实现了模式 B**（直接解压）：

```zig
// first_boot.zig 第 274-298 行
.archive => {
    const dest = step.destination orelse "/";
    // ... 渲染为：
    // tar -xf <archive> -C <dest>
    // 没有 install.sh 检测逻辑
},
```

- `dest` 默认为 `/`，不检测 `./install.sh`，总是直接解压到 `dest`；
- 没有"解压到临时目录 + 执行"的分支。

这意味着 v0.2 的 rootfs-build/first-boot **尚未实现模式 A**。v0.3 在为 install-post
引入 archive 时，需要同时补齐 rootfs-build/first-boot 的模式 A 实现，使三个 phase
的 archive 行为完全一致。

#### 4.6.4 install-post 的 archive 渲染目标

install-post 由安装器执行（Kickstart `%post` / Autoinstall `late-commands`），
`renderInstallPost` 需要渲染出一段 shell 命令，这段命令在安装目标根执行时完成
上述判定和执行：

**模式 A 渲染**（`./install.sh` 存在）：

```bash
# 解压到临时目录
TMPDIR=$(mktemp -d /tmp/.nodeforge-arc-XXXXXX)
tar -xf <archive_source> -C "$TMPDIR"
# 执行 install.sh
( cd "$TMPDIR" && ./install.sh )
RC=$?
# 清理
rm -rf "$TMPDIR"
exit $RC
```

**模式 B 渲染**（`./install.sh` 不存在）：

```bash
tar -xf <archive_source> -C /
```

由于 shell 渲染期（`renderInstallPost`）无法读取 tar 内容，判定必须在运行时
（安装器执行 `%post` 时）完成。因此实际渲染的是一段**运行时自判定脚本**：

```bash
TMPDIR=$(mktemp -d /tmp/.nodeforge-arc-XXXXXX)
tar -xf <archive_source> -C "$TMPDIR"
if [ -f "$TMPDIR/install.sh" ]; then
  ( cd "$TMPDIR" && ./install.sh )
  RC=$?
else
  # 没有 install.sh，把内容移到目标根
  tar -cf - -C "$TMPDIR" . | tar -xf - -C /
  RC=$?
fi
rm -rf "$TMPDIR"
exit $RC
```

#### 4.6.5 archive 来源

archive 内容有两个来源，与 `managed_file` 一致：

| 来源 | 字段 | 说明 |
|---|---|---|
| catalog asset | `content_asset` + `content_url` + `content_sha256` | 从 HTTP 下载已校验 tar 归档 |
| inline content | `content` | 步骤内联 tar 字节，编码为 `printf %b` 八进制转义 |

install-post 上下文中：

- **catalog asset 方式**：渲染为 `curl -fsS --output <tmpfile> <url> && sha256sum -c -`
  下载校验后再判定解压。与现有 `managed_file` 的 asset download 路径一致。
- **inline content 方式**：渲染为 `printf '%b' '<bytes>' > <tmpfile>` 后再判定解压。
  与现有 `managed_file` 的 inline content 路径一致。

rootfs-build/first-boot 还支持第三种来源 `payload_path`（agent pre-init 已下载校验
的本地路径），但 install-post **不使用 payload_path**——install-post 由安装器执行，
没有 agent pre-init 阶段预下载 payload。asset 下载在安装器 `%post` 运行时通过 HTTP
完成。

#### 4.6.6 安全约束（build/运行期通用，继承 v0.2 §5.4）

- archive 顶层仅允许单一 `./install.sh` 特例；不允许多个脚本、子目录中的脚本或
  其他可执行文件自动执行。
- tar 条目拒绝绝对路径（如 `/etc/passwd`）、`..` 路径组件、device 文件、FIFO 和
  越界 symlink（指向目标根之外的路径）。
- `install.sh` 以 `sh` 执行，退出码 0 且幂等；禁止隐式下载未声明内容。
- manifest 只声明 SHA-256（由 asset 提供），不设 `script|extract` 策略、`target_root`、
  `install --root` 参数或 `NODEFORGE_TARGET_ROOT` 环境变量。
- archive 没有 `destination` 字段——目标根由执行上下文决定（install-post 为安装
  目标根 `/`，rootfs-build 为 staging `/`，first-boot 为 overlay upper `/`）。
  v0.2 CLI `item add` 的 archive action 字段矩阵中 `destination` 为禁止字段
  （[`V0_2_CLI.md`](V0_2_CLI.md) §3）。
- 步骤作者始终以 `/` 为目标，builder/agent/installer 提供挂载或 chroot 上下文把
  写入落到对应 lower / overlay upper / 目标磁盘。

#### 4.6.7 三个 phase 的 archive 行为一致性矩阵

| 维度 | install-post（v0.3 新增） | rootfs-build（v0.2 已有模式 B，需补模式 A） | first-boot（v0.2 已有模式 B，需补模式 A） |
|---|---|---|---|
| 模式 A（`./install.sh` 存在） | 解压到临时目录 + 执行 | 同左 | 同左 |
| 模式 B（`./install.sh` 不存在） | 解压到目标根 `/` | 解压到 staging `/` | 解压到 overlay upper `/` |
| 来源：catalog asset | `curl + sha256sum -c` | payload_path（已物化） | payload_path（pre-init 已下载） |
| 来源：inline content | `printf %b` | `printf %b` | `printf %b` |
| 来源：payload_path | **不适用**（无 agent pre-init） | chroot 内 payload 路径 | `/var/lib/nodeforge/payload/` |
| `destination` 字段 | 禁止 | 禁止 | 禁止 |
| 安全约束 | §4.6.6 | 同左 | 同左 |

v0.3 实施时需要：

1. 在 `renderInstallPost` 中新增 `.archive` 分支，渲染运行时自判定脚本；
2. 在 `first_boot.zig` 的 `renderStep` `.archive` 分支中补齐模式 A 逻辑；
3. rootfs-build 复用 `first_boot.renderStep`，自动获得模式 A；
4. 三个 phase 的安全约束统一由 validator 在 plan/validate 阶段强制。

## 5. 发行版版本矩阵

### 5.1 当前实现状态

`src/profile/capabilities.zig` 已有一个静态 adapter capability registry，
按 domain 列出 Kickstart/Autoinstall 的 `native`/`translated`/`not_applicable`/
`unsupported` 状态。`src/catalog/software_index.zig` 索引
`environment`/`group`/`task`/`metapackage`/`package` 五种 software kind。

但缺少**显式的 `(distro, version, arch)` capability matrix**——即声明每个
发行版版本支持哪些 storage mode、software kind、bootloader 与 firmware。

### 5.2 目标模型

- Rocky/RHEL 系与 Ubuntu 后续 LTS 的显式 adapter capability matrix：声明每个
  `(distro, version, arch)` 支持的 storage mode、software kind
  （environment/group/task/metapackage/package）、bootloader 与 firmware。
- bootloader、发行版版本差异、错误分类与长期运行回归。
- 对当前 adapter 不适用的 kind 返回 `software.kind_not_applicable` 并列出
  `supported_kinds`，不能返回易误判的空列表。
- adapter 不能在配置路径不存在或不适用时猜测，也不能实现运行时 fallback。

### 5.3 capability matrix 结构

```text
AdapterCapabilityMatrix = struct {
    entries: []const AdapterCapabilityEntry,
}

AdapterCapabilityEntry = struct {
    distro: []const u8,          // "rocky", "ubuntu", "rhel", ...
    version: []const u8,         // "9.7", "22.04", ...
    arch: Arch,                  // x86_64, aarch64
    adapter: InstallAdapter,     // kickstart, autoinstall
    storage_modes: []const StorageMode,     // 支持的存储拓扑
    software_kinds: []const SoftwareKind,   // 支持的 software kind
    bootloader: []const BootloaderSupport,  // 支持的 bootloader
    firmware: []const FirmwareMode,         // 支持的固件模式（当前仅 uefi）
}
```

当前 `firmware` 只含 `uefi`；`bios` 在 BIOS PXELINUX 独立工作项落地后补充
（见 [`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)）。

## 6. CLI（v0.3）

> 完整 CLI 约定见 [`V0_2_CLI.md`](V0_2_CLI.md) §0；本节给 v0.3 新增。

```text
nodeforge profile set <profile> install.post_install.bundle=<bundle>
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=install-post action=managed-file content_asset=<asset> destination=/etc/motd \
  mode=0644 owner=root group=root idempotency_key=<key> timeout_s=30 retryable=false
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=install-post action=package packages=tmux,nmap \
  idempotency_key=pkgs timeout_s=600 retryable=true
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=install-post action=archive content_asset=<app-archive> destination=/opt/app
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=install-post action=script content_asset=<setup-script> timeout_s=120
nodeforge node postprocess show <node> --phase install-post [--generation <id>]
nodeforge assets adapter-matrix list
nodeforge assets adapter-matrix show <distro> <version> <arch>
```

- `profile set ... install.post_install.bundle` 与 provision-bundle owner 沿用 v0.2
  现有入口；v0.3 新增的是 canonical action 接受范围、generation status/callback 和
  adapter matrix 命令。
- `postprocess` 统一命名（同 v0.2）：install 侧的 install-post phase 也用
  `node postprocess show` 查询，不用 `postinstall`，避免与 diskless 命名分叉。
  省略 `--generation` 时查询最近一个 install generation；无历史时返回空结果 exit 0。
  `--session` 只适用于 diskless first-boot，不能和 `--generation` 混用。
- `adapter-matrix` 是只读查询命令，列出/显示显式 capability matrix。
- `install-post` phase token 在 schema v4/parser 中已经存在，且兼容 runner 支持
  `repository`、`standard-packages` 与 `managed-file` 子集；v0.3 才接受
  `archive`/`script`/`package` 等 canonical 新形态，同时给旧形态明确迁移与拒绝边界。
- v0.3 不提供多 NIC/VLAN/bonding、容量压测、install 侧 agent 的 CLI
  （属 v0.4/永久非目标）。

## 7. 明确非目标（v0.3 增量）

- BIOS/PXELINUX -> 独立延后文档
  [`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)，不绑定产品版本号，最早在 v0.5 后实施。
- 多 NIC/VLAN/bonding、PXE 阶段纯静态、下载后切换地址/子网 -> v0.4
  （需显式 initrd/agent consumer feature、schema 和验收）。
- 大规模容量压测 -> v0.4。
- install 侧 first-boot agent -> v0.4（确定性，无 reconciliation）。
- reconciliation/远程控制 -> 永久非目标（全版本）。
- IPv6、by-id/serial/WWN -> 永久非目标（继承 v0.1）。
- v0.3 不提供 v0.4/v0.5 命令的 help/handler；预留 enum 不算实现。

## 8. 实施批次

### Batch 1：install-post runner 扩展

**涉及文件**：`src/provision/runner.zig`、`src/provision/first_boot.zig`、
`src/config/validate.zig`、相关测试。

- 扩展 `renderInstallPost` 接受 `archive`/`script`/`package` 三类 canonical action；
- 八步执行契约排序（文件更新 -> package -> archive -> script）；
- `package` action 只引用 pinned effective software/capability，经本地 repository
  解析校验、幂等；
- `archive` 规则与 v0.2 §5.4 一致：运行时自判定 `./install.sh` 存在则解压到临时
  目录执行（模式 A），否则直接解压到目标根（模式 B），详见 §4.6；
- **补齐** `first_boot.zig` `renderStep` `.archive` 分支的模式 A 逻辑，使
  rootfs-build/first-boot 与 install-post 行为一致；
- 旧 `repository`/`standard_packages` 在 validator 报错
  `install_post.legacy_action_deprecated`；
- aarch64 UEFI install 回归不退化。

### Batch 2：install-post callback credential

**涉及文件**：`src/profile/adapter/kickstart.zig`、`src/profile/adapter/ubuntu.zig`、
`src/state/`（新增 generation credential 模块）、`src/http/server.zig`。

- per-generation credential capsule（0400，`/run/nodeforge/credentials/install-callback.token`）；
- hash-only 恢复边界；
- `node_id/install_generation/plan_digest/audience/method/path/expiry` 绑定；
- 单调 `event_seq` 去重；
- generation 终态/超时撤销；
- daemon restart hash 验证恢复；
- capsule 交付前/中 `recovery_incomplete` 负测。

### Batch 3：install-post journal/status

**涉及文件**：`src/state/`（新增 install-post journal 模块）、`src/http/server.zig`、
`src/main.zig`。

- `(node_id, install_generation, bundle_revision, plan_digest, step_id)` 标识；
- step/finalizer 状态上报与持久化；
- `node postprocess show --phase install-post [--generation <id>]` 查询；
- 同次安装自动 step retry；耗尽后阻止 `install.completed`；
- 不存在远程 step retry。

### Batch 4：adapter capability matrix

**涉及文件**：`src/profile/capabilities.zig`、`src/profile/adapter/`、`src/catalog/`、
`src/main.zig`。

- 显式 `(distro, version, arch)` capability matrix；
- `software.kind_not_applicable` + `supported_kinds` 返回；
- `assets adapter-matrix list/show` CLI；
- adapter 不猜测、不运行时 fallback。

### Batch 5：CLI + 文档 + 全量回归

- 文档：更新路线图状态、当前实现审计、CLI reference、`V0_2_CLI.md`、本设计实现状态；
- schema fixture、state/DTO fixture；
- aarch64 UEFI install/diskless 全量回归。

## 9. 完成标准

- install-post phase 在同一 Assets owner 上实现四类 action、八步契约、
  credential/session 边界/finalizer、plan/status、同次安装自动 step retry；
  耗尽后阻止 `install.completed`，且不存在远程 step retry。
  `standard_packages`/`repository` 已退出（validator 拒绝 + 迁移提示）。
- install-post callback credential 的 capsule 权限/泄漏检查、generation/plan 绑定、
  重放、过期、跨 Node 越权与 daemon restart-resume 负向测试通过；测试必须区分
  capsule 交付前/中 `recovery_incomplete` 与 token 已交付后的 hash 验证恢复；
  未经认证的 node/generation 事件不能推进 deployment。
- 显式 adapter capability matrix 覆盖目标 Rocky/RHEL 与 Ubuntu LTS；不适用 kind
  返回 `software.kind_not_applicable` + `supported_kinds`。
- `node list`/`node status` 对 install 与 diskless 统一投影，
  installer 进度仅在 `node_status` 保留。
- aarch64 UEFI install 与 diskless 回归不退化。
- catalog schema 保持 v5（无 schema 变更）。
- 本审计与版本设计、配套文档同步更新；预留 enum/空 handler 不算实现证据。
