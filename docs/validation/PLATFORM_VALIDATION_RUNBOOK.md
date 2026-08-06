# NodeForge 通用平台验证运行手册

状态：现行通用发布闸流程。大版本或重大功能落地后，按本文从 **fresh 空环境** 完整执行。

版本专属增量（例如 v0.4 topology / first-boot / discovery / 容量 harness，以及 v0.4.1
staging session / tree-kernel import）见对应
`V0_x_*_VALIDATION*.md` 或 `V0_x_FULL_VALIDATION_RUNBOOK.md`；本文是**跨版本公共底座**，
不替代版本专属闸，也不记录某次实跑结果（结果写入 `docs/validation/` 下带日期的记录）。

---

## 0. 目的与使用方式

### 0.1 要证明什么

仅通过 **公开 CLI + README 文档化流程**，在真实双机环境中完成：

1. 交叉编译与 fresh 部署；
2. ISO 导入、install / diskless Profile 与 rootfs 构建；
3. 计算节点 install 与 diskless 全链路；
4. provision-bundle / install-post canonical 能力；
5. 可运营面（operation、readiness、session、events、status、恢复）；
6. 负向契约（旧 action 拒绝、archive fail-closed、token 不泄漏等）；
7. 仓库定义的自动化测试。

任一**必测**项缺少真实证据 → 总结论 **FAIL**。

### 0.2 硬约束

| 规则 | 说明 |
|---|---|
| 公开 CLI only | 业务变更只用 `nodeforge` / `setup`；禁止直接改 catalog 文件、journal、deployment state 或数据库式绕过 |
| 不复用旧部署 | 禁止导入旧 config/catalog/state；禁止把旧 rootfs/ISO 副本当成本轮产物 |
| README 对齐 | 命令以 README 与 `nodeforge --help-full` 为准；发现 CLI / 实现 / 文档不一致必须先修后重测 |
| 修复即重跑 | 修完后重新编译、彻底清场，从阶段 1 完整重测，不得局部“补跑成功”顶替全量 |
| 本地交叉编译 | 四二进制在**开发机本地**交叉编译后通过 `scp` 同步到管理节点；**禁止在管理节点（r97n0）上安装 Zig 工具链或直接编译**；管理节点仅接收成品二进制 |
| 管理面本机 | `nodeforge` 管理命令只在管理节点 loopback 执行 |
| 计算节点角色 | 计算节点不安装构建工具、不本地生成 squashfs、不上传 rootfs |

### 0.3 与既有文档关系

| 文档 | 角色 |
|---|---|
| 本文 | 通用全量验证流程（可重复执行的任务书） |
| [README.md](../../README.md) | 操作员入口、命令示例、安装布局 |
| [cli/REFERENCE.md](../cli/REFERENCE.md) | 公开命令树与 exit code |
| [V0_3_VALIDATION.md](../archive/validation/V0_3_VALIDATION.md) | 某次 v0.3 实跑证据（历史归档） |
| [V0_4_FULL_VALIDATION_RUNBOOK.md](V0_4_FULL_VALIDATION_RUNBOOK.md) | v0.4 增量发布闸 |
| 设计总纲 | 定义行为契约；冲突时：现行版本设计 > 代码 > 验证记录 |

### 0.4 何时必须完整执行

- 主版本或次版本发布前（如 v0.3 → v0.4）；
- 安装/ diskless / setup / catalog schema / install-post 任一公共路径变更；
- CLI 主工作流、exit code 或 durable operation 语义变更；
- 交叉编译目标、安装根布局或 systemd unit 变更。

允许做**子集回归**的情况（须在报告中标注 NOT RUN 的必测项仍导致发布 FAIL）：

- 仅文档/注释；
- 仅单测覆盖的纯函数修复且未触达 provision/boot 路径；
- 明确的版本专属增量，且公共底座最近一次全量 PASS 仍有效、commit 可追溯。

---

## 1. 证据与判定规则

### 1.1 每阶段必留证据

| 字段 | 要求 |
|---|---|
| 候选 commit | `git rev-parse --short=12 HEAD` |
| 构建时间 / 版本 | `nodeforge --version`（含 product version、build time、git） |
| 二进制身份 | 四程序 `file` + `sha256` + 目标架构 |
| 命令与退出码 | 关键 CLI 的完整命令、stdout JSON 摘要、exit code |
| 时间 | UTC |
| 服务日志 | 管理节点 `journalctl -u nodeforged` 或 install-root logs 中的相关片段 |
| 目标证据 | 计算节点 console / SSH 输出（os-release、kernel、mount、hosts、repo、failed units） |
| 状态摘要 | deployment generation、plan digest、drift、session 状态、journal 步骤 |

### 1.2 判定

- **PASS**：该项有本轮生成的真实证据，且符合契约。
- **FAIL**：执行失败、证据与契约不符、或用了非公开路径“修好”。
- **NOT RUN**：未执行。对必测项等同 FAIL（总结论）。
- **N/A**：当前环境客观上不具备（须说明；不得用 N/A 掩盖可执行项）。

### 1.3 禁止事项

- 为得到 PASS 手工编辑 state / 伪造 event / 跳过 deep validation；
- 把上一轮 artifact 冒充本轮生成；
- 仅凭 VM “Running” 或 systemd `active` 判定成功（管理面须 `nodeforge status` 健康）；
- 在 VMware UI 中修改 NodeForge 业务配置（电源与固件操作除外）。

---

## 2. 环境参数（先填再跑）

下列变量在报告与脚本中统一使用；**示例值为历史实验室环境，其他站点必须替换**。

```bash
# ── 角色 ──────────────────────────────────────────────
export NF_MGMT_HOST=r97n0          # 管理节点 hostname（SSH）
export NF_MGMT_SSH=root@r97n0
export NF_COMPUTE_HOST=r97n1       # 计算节点逻辑 id / hosts 名
export NF_COMPUTE_MAC=00:50:56:2A:23:DB
export NF_ARCH=aarch64             # 目标架构：aarch64 | x86_64
export NF_TARGET_TRIPLE=aarch64-linux-gnu

# ── 网络（管理节点 PXE 侧）────────────────────────────
export NF_BIND_IFACE=enp26s0
export NF_SERVER_IP=192.168.27.128
export NF_SUBNET=192.168.27.0/24
export NF_POOL_START=192.168.27.220
export NF_POOL_END=192.168.27.240
# 计算节点 reservation IP 禁止手写：必须从管理节点 hosts 读取
# export NF_COMPUTE_IP=  # 运行时由 getent 填入

# ── 安装与制品 ────────────────────────────────────────
export NF_INSTALL_ROOT=/opt/nodeforge
export NF_BUNDLE_DIR=/tmp/nodeforge-bundle
export NF_CLI=$NF_INSTALL_ROOT/bin/nodeforge
export NF_ISO_DIR=/root               # 原始 ISO 必须在 install-root 之外

# ── 介质（按实验室实际文件名）────────────────────────
export NF_ISO_ROCKY97=Rocky-9.7-aarch64-minimal.iso
export NF_ISO_ROCKY102=Rocky-10.2-aarch64-dvd1.iso
export NF_ISO_UBUNTU=ubuntu-22.04.5-live-server-arm64.iso
export NF_ISO_UBUNTU_2604=ubuntu-26.04-desktop-arm64.iso
export NF_ISO_UBUNTU_2604_LOCAL=/Users/iskylite/Downloads/ISO/ubuntu-26.04-desktop-arm64.iso

# ── 目标磁盘（install 用）────────────────────────────
export NF_BOOT_DISK=/dev/nvme0n1

# ── VMware（可选；Computer Use / vmrun）──────────────
# export NF_VMX=...
# export NF_VMRUN=...
```

**DHCP 池必须避开**：管理节点 IP、网关、计算节点 reservation、其他基础设施地址。

**角色固定**：

- `NF_MGMT_HOST`：运行 `nodeforged`，提供 DHCP/TFTP/HTTP，生成全部 rootfs；
- `NF_COMPUTE_HOST`：仅作为 PXE 客户端与目标机，验证 install / diskless。

---

## 3. 验证范围总览（能力矩阵）

### 3.1 必测（公共发布闸）

| 域 | 覆盖点 |
|---|---|
| 构建 | 四二进制交叉编译、架构、版本、SHA-256 |
| Fresh 部署 | 精确清场、setup 非交互、systemd、status/config/catalog validate |
| 介质 | Rocky 9.x、Rocky 10.x、Ubuntu 22.04 与 Ubuntu 26.04 ISO 导入；distro/version/arch/repo/kernel/initrd |
| Install | 至少 Rocky 9.x install 完整 generation；Ubuntu install 至少一项 |
| Diskless | 三套可管理 Profile：initrd → boot-bundle → rootfs plan/build/status=ready；至少一套必须走 v0.4.1 stage。Ubuntu desktop 介质若缺少 SSH/server rootfs 基线，记录为 import-only，不得伪造 ready |
| v0.4.1 stage | `--keep-staging`、staging enter/exec/kernels、并发锁/cgroup/超时、`--from-staging` 与 kernel import；stage 产物必须完成真实 diskless PXE 启动 |
| 实机矩阵 | Rocky install、Rocky diskless×发行版、Ubuntu diskless（见阶段 7） |
| 节点控制面 | hosts 读 IP、node add/show、readiness、boot preview、deploy、retry |
| 目标契约 | hosts 注入、受管 repo、bootstrap SSH、kernel 匹配、diskless overlay 根 |
| install-post | 四类 action + finalizer 顺序、journal、completion gate、drift clean |
| Archive | `assets archive build/import`；不可读/绝对路径/`..` fail-closed |
| 负向 | 旧 `repository`/`standard_packages` 拒绝；无兼容/迁移/fallback |
| 恢复 | daemon 真实重启后 status 与 completed journal 保持；committing WAL 由单测覆盖 |
| 自动化 | `zig build test`；目标环境 `test-v0.3-install-post-e2e` 或等价脚本 |

### 3.2 强烈建议（已落地接口，大更新应覆盖）

| 域 | 覆盖点 |
|---|---|
| Profile | create / show（Stored+Effective）/ set / clone（含 provenance、ssh identity） |
| Operation | list / show / follow；ISO import 与 rootfs build 均为 durable operation |
| Session | diskless session list/show；cancel 后不可继续交付 |
| Events | events list / types；install-post 与 diskless 关键类型可查 |
| Runtime | dhcp-leases、tftp-counters（存在且非空/可解析即可） |
| Provision asset | managed-file / script / archive import；provision-bundle CRUD + item |
| Software | install-source software list；profile/node software show |
| Keys | key-list / key-show（bootstrap 指纹可观测） |
| Security | 普通 CLI/JSON 输出无 raw capability token；管理 API 非 loopback 拒绝（若可测） |
| Storage | 默认 single + 显式 `storage.boot_disk`；多盘环境再扩 LVM/RAID 矩阵 |
| Exit code | 输入错误=2、operation failed=5、daemon 不可达=6 等抽样 |

### 3.3 版本专属 / 延期（不在本文强制）

| 项 | 去向 |
|---|---|
| 多 NIC / VLAN / bond topology 渲染 | v0.4 runbook |
| Install first-boot plan（与 install-post 分离） | v0.4 runbook |
| SN+IP discovery / claim | v0.4 runbook |
| 256/512/1024 逻辑容量 harness | v0.4 runbook |
| 真实 256 节点生产吞吐 | 延期清单 `ENV-V04-PRODUCTION-SCALE` |
| BIOS PXELINUX、DHCP-less static PXE、IPv6 | 延期 / 非目标 |

### 3.4 已落地公开 CLI 速查（验证时不得“发明”入口）

```text
nodeforge [-v] [--install-root PATH] COMMAND

status
setup
config validate|export
catalog validate|export|show
operation list|show|follow|wait

assets import|list|show|validate
assets install-source list|show|software
assets repository list|show|render|software
assets initrd build
assets boot-bundle create|list|show
assets managed-file list|show|import|remove
assets archive build|import
assets script import
assets provision-bundle ...
assets key-import|key-list|key-reload|key-show

profile create|clone|remove|list|show|set|unset
profile rootfs plan|build|status
profile software|capabilities|...
profile add-values|...|item|...

node add|remove|list|show|set|unset
node deploy|retry|render|trace
node boot preview
node readiness --stage build|boot
node postprocess show
node session list|show|cancel
node software|capabilities|...
node topology validate          # v0.4+；旧闸可 N/A
node claim | node discovery ... # v0.4+；旧闸可 N/A

discovery list|show|policy
events list|follow|types
runtime dhcp-leases|dhcp-unknown|tftp-counters|tftp-sessions
```

参数与默认值以 `--help-full` 为唯一事实源。

---

## 4. 阶段 0：预检与安全确认

### 4.1 本机源码预检

在仓库根目录：

```bash
zig version
git rev-parse --short=12 HEAD
git status --short
zig fmt --check src build.zig
# 完整自动化可放在最后阶段；此处至少确认能启动构建
```

### 4.2 确认目标主机（破坏性操作前必须）

```bash
# 若新增介质只在工作站，先传入管理节点的原始介质目录；不得传入 install-root，
# 也不得把上轮已导入的副本当成本轮产物。
scp "$NF_ISO_UBUNTU_2604_LOCAL" "$NF_MGMT_SSH:$NF_ISO_DIR/$NF_ISO_UBUNTU_2604"

ssh "$NF_MGMT_SSH" '
  set -euo pipefail
  hostname
  uname -m
  test "$(hostname)" = "'"$NF_MGMT_HOST"'"
  test "$(uname -m)" = "'"$NF_ARCH"'"
  ip -br addr show "'"$NF_BIND_IFACE"'"
  getent hosts "'"$NF_COMPUTE_HOST"'" || true
  systemctl is-active sshd
  systemctl is-active NetworkManager || systemctl is-active NetworkManager.service || true
  ls -la "'"$NF_ISO_DIR"'"/*.iso 2>/dev/null | head
'
```

**STOP 条件**：hostname / 架构 / 网卡 / ISO 路径任一不符 → 不得清场。

### 4.3 原始 ISO 不在 install-root 内

确认 ISO 在 `$NF_ISO_DIR`（默认 `/root`），不在 `/opt/nodeforge` 下。清场会删除 install-root 内全部副本。

---

## 5. 阶段 1：停止并彻底清场

> **破坏性**：停止 NodeForge，删除 install-root 内配置、catalog、assets、state、logs。
> 不得影响 `sshd`、NetworkManager 与其它系统服务。路径必须字面精确，禁止未展开变量。

```bash
ssh "$NF_MGMT_SSH" '
  set -euo pipefail
  test "$(hostname)" = "'"$NF_MGMT_HOST"'"

  systemctl stop nodeforged.service 2>/dev/null || true
  systemctl disable nodeforged.service 2>/dev/null || true
  pkill -x nodeforged 2>/dev/null || true

  rm -f /etc/systemd/system/nodeforged.service
  rm -f /etc/profile.d/nodeforge.sh
  rm -rf --one-file-system /opt/nodeforge
  systemctl daemon-reload

  test ! -e /opt/nodeforge
  systemctl is-active sshd
  # 确认未误删系统关键路径
  test -d /etc && test -d /usr && test -d /var
'
```

可选：若仅做“保留 catalog 的 reset”演练，使用公开入口（**全量发布闸仍要求上述彻底清场**）：

```text
# daemon 必须已停止
nodeforge setup --reset-state --yes
nodeforge setup --reset-all --yes
nodeforge setup --reset-all --purge-data --yes
nodeforge setup --reset-all --purge-all --reconfigure --yes
```

语义见 [cli/REFERENCE.md](../cli/REFERENCE.md) 的 setup 表：`--reset-all` **不等于** fresh replacement。

**PASS**：`/opt/nodeforge` 不存在；sshd 仍 active；无残留 nodeforged 监听 67/69/18080。

---

## 6. 阶段 2：本地交叉编译、核验、同步部署二进制

> **硬约束**：以下所有构建命令在**开发机本地**（macOS / Linux 工作站）执行，
> 通过交叉编译产出目标架构二进制后用 `scp` 上传。**禁止 SSH 到管理节点执行
> `zig build` 或在管理节点安装 Zig 工具链。** 管理节点（r97n0）只负责运行
> 成品二进制，不参与编译过程。

### 6.1 本地交叉编译

```bash
# ── 在开发机本地执行（NOT on r97n0）──
# 调试可固定 build-time 避免缓存膨胀；发布记录真实时间可省略 -Dbuild-time
zig build -Dtarget="$NF_TARGET_TRIPLE" -Doptimize=ReleaseSafe

for program in nodeforge nodeforged nodeforge-initrd nodeforge-agent; do
  test -x "zig-out/bin/$program"
  file "zig-out/bin/$program"
  shasum -a 256 "zig-out/bin/$program"
done

# 管理客户端版本可读（在本地验证，不涉及远端）
./zig-out/bin/nodeforge --version
```

**注意**：`nodeforge-initrd` 是 initramfs PID 1，**禁止**把直接执行
`nodeforge-initrd --version` 当作普通版本检查（会进入 bootstrap）。它与
`nodeforge-agent` 通过同构建、ELF 架构、摘要、注入与 diskless 实机共同核验。
v0.4.3 起 agent **强制子命令**：initrd 须 `exec … pre-init`，firstboot unit 须 `… first-boot`；**initrd 与 agent 同构建同发版**，禁止旧 initrd + 新 agent 混搭（见 [`../design/V0_4_3_DESIGN.md`](../design/V0_4_3_DESIGN.md) §3.3）。

Make 等价：`make linux-arm64` / `make linux-amd64` / `make dist-linux-arm64`。

### 6.2 同步到管理节点（scp 上传，非远端编译）

```bash
# ── 仍在开发机本地执行；将成品二进制 scp 到管理节点 ──
ssh "$NF_MGMT_SSH" "rm -rf $NF_BUNDLE_DIR && mkdir -p $NF_BUNDLE_DIR"
scp zig-out/bin/{nodeforge,nodeforged,nodeforge-initrd,nodeforge-agent} \
  "$NF_MGMT_SSH:$NF_BUNDLE_DIR/"
# 仅验证远端收到的二进制可执行与版本（不涉及编译）
ssh "$NF_MGMT_SSH" "$NF_BUNDLE_DIR/nodeforge --version"
```

### 6.3 再次清场（防部署间隙污染）

重复阶段 1 的精确删除，再进入 setup。

**PASS**：四 ELF 架构匹配 `$NF_ARCH`；版本字符串与候选 commit/构建选项一致；摘要已记录；
管理节点无 Zig 工具链残留、无 `zig-out/` 或 `zig-cache/` 目录（确认未在远端编译）。

---

## 7. 阶段 3：仅通过 setup 完成全新初始化

```bash
ssh "$NF_MGMT_SSH" '
  set -euo pipefail
  cd '"$NF_BUNDLE_DIR"'

  ./nodeforge setup --install-root '"$NF_INSTALL_ROOT"' --non-interactive --yes \
    --bind-interface '"$NF_BIND_IFACE"' --server-ip '"$NF_SERVER_IP"' \
    --subnet '"$NF_SUBNET"' \
    --pool-start '"$NF_POOL_START"' --pool-end '"$NF_POOL_END"'

  ./nodeforge setup --install-root '"$NF_INSTALL_ROOT"' --generate-systemd --install \
    --non-interactive --yes

  systemctl start nodeforged

  # systemd active ≠ 管理面 ready
  for i in $(seq 1 60); do
    '"$NF_CLI"' status --output json | jq -e ".ok and .result.ok" && break
    sleep 1
  done

  '"$NF_CLI"' status --output json
  '"$NF_CLI"' config validate --output json
  '"$NF_CLI"' catalog validate --output json
'
```

### 7.1 布局与 schema 抽查

```bash
ssh "$NF_MGMT_SSH" '
  set -euo pipefail
  test -x '"$NF_INSTALL_ROOT"'/bin/nodeforge
  test -x '"$NF_INSTALL_ROOT"'/bin/nodeforged
  test -x '"$NF_INSTALL_ROOT"'/bin/nodeforge-initrd
  test -x '"$NF_INSTALL_ROOT"'/bin/nodeforge-agent
  test -f '"$NF_INSTALL_ROOT"'/config/config.json
  test -d '"$NF_INSTALL_ROOT"'/catalog
  test -d '"$NF_INSTALL_ROOT"'/assets
  test -d '"$NF_INSTALL_ROOT"'/state
  # schema / deployment 标记随产品版本变化；以 setup 生成与 validate 通过为准
  jq "{schema_version, server, dhcp}" '"$NF_INSTALL_ROOT"'/config/config.json
'
```

当前主线（以代码为准）：AppConfig schema v5、Catalog schema v6、DeploymentManifest v1、
`nodeforge-root-v2 <deployment_id>`。验证报告须记录本轮实际 schema，不得抄旧记录。

### 7.2 daemon 冷启动回归

```bash
ssh "$NF_MGMT_SSH" '
  systemctl restart nodeforged
  for i in $(seq 1 60); do
    '"$NF_CLI"' status --output json | jq -e ".ok and .result.ok" && exit 0
    sleep 1
  done
  exit 1
'
```

**PASS**：status / config validate / catalog validate 全绿；四二进制在 install-root；
重启后管理面恢复健康；无旧 schema 加载错误。

---

## 8. 阶段 4：CLI 导入 ISO 与介质完整性

```bash
ssh "$NF_MGMT_SSH" '
  set -euo pipefail
  '"$NF_CLI"' assets import '"$NF_ISO_DIR"'/'"$NF_ISO_ROCKY97"'
  '"$NF_CLI"' assets import '"$NF_ISO_DIR"'/'"$NF_ISO_ROCKY102"'
  '"$NF_CLI"' assets import '"$NF_ISO_DIR"'/'"$NF_ISO_UBUNTU"'

  '"$NF_CLI"' assets install-source list --output json
  '"$NF_CLI"' operation list --output json | head -c 4000

  for source in \
    rocky-9.7-aarch64-minimal \
    rocky-10.2-aarch64-dvd1 \
    ubuntu-22.04.5-live-server-arm64 \
    ubuntu-26.04-desktop-arm64
  do
    echo "==== $source ===="
    '"$NF_CLI"' assets install-source show "$source" --output json
    '"$NF_CLI"' assets install-source software list "$source" --output json | head -c 2000 || true
  done

  '"$NF_CLI"' catalog validate --output json
  '"$NF_CLI"' assets list --output json | head -c 4000
'
```

### 8.1 每条 Install Source 必查字段

| 检查 | 期望（示例，以实际导入为准） |
|---|---|
| distro / version / arch | rocky/9.7、rocky/10.2、ubuntu/22.04.x + `$NF_ARCH` |
| kernel / initrd | 已登记 asset，路径存在 |
| repository | Rocky Minimal 或 BaseOS/AppStream；Ubuntu APT + casper layers |
| software index | 可 list environment/group（Rocky）或等价能力 |
| catalog | validate 通过；revision 递增 |

ISO 导入为 **durable operation**：CLI 默认跟随终态；超时不取消 daemon 任务。

**PASS**：三份介质全部 succeeded；show 字段完整；catalog validate 通过。

---

## 9. 阶段 5：Diskless 构建链（仅 CLI）

对每个 install-source 执行：`initrd build` → `boot-bundle create` → `profile create --kind diskless` →
`rootfs plan` → `rootfs build --if-input-digest` → `rootfs status`。

### 9.0 v0.4.1 stage 增量（公共闸内必跑）

至少选择一套可启动 Profile（推荐 Rocky 10.2；Ubuntu desktop 布局若缺少
/sbin/init 或 usr/sbin/sshd 等 server rootfs 基线，则按 import-only 处理），
并在同一轮 fresh deployment 中执行：

`staging kernels` 以 `/boot/vmlinuz-*` 为主候选，并按 release 检查
`/lib/modules` 或 `/usr/lib/modules`；只有 modules 目录时不得伪造候选，但允许
Rocky/RHEL 10 的 `<modules>/<release>/vmlinuz` 作为 `/boot` 缺失时的回退。
`auto` 与显式 kernel release 必须同时具备 vmlinuz 和匹配 modules。

```bash
$CLI profile rootfs build <profile> --keep-staging --output json
$CLI profile rootfs staging list
$CLI profile rootfs staging show <profile>
$CLI profile rootfs staging kernels <profile>
$CLI profile rootfs staging exec <profile> -- uname -r
$CLI profile rootfs staging exec <profile> --timeout 2 -- sleep 10  # exit 124
$CLI profile rootfs build <profile> --from-staging --kernel-release auto --output json
$CLI profile rootfs status <profile> --output json
```

另开会话保持 `staging enter` 占锁时，第二个 enter 与并发 `--from-staging` 必须
fail-closed；退出后确认 lock、mount、cgroup 无残留。使用 `--memory-max`、`--pids-max`
和 `--no-cgroup` 留下 `/proc/self/cgroup` 证据。记录 kernel import、catalog asset、
boot-bundle 与 digest；最终必须把这个 `--from-staging` 产物用于阶段 7 的真实 PXE
diskless 启动，不能用管理面 `state=ready` 替代节点侧证据。

```bash
ssh "$NF_MGMT_SSH" '
  set -euo pipefail
  CLI='"$NF_CLI"'

  # --- Rocky 9.7 ---
  $CLI assets initrd build rocky-9.7-nodeforge-initrd \
    --from-install-source rocky-9.7-aarch64-minimal \
    --kernel-release 5.14.0-611.5.1.el9_7.aarch64
  $CLI assets boot-bundle create rocky-9.7-aarch64-minimal \
    --kernel rocky-9.7-aarch64-minimal-kernel \
    --initrd rocky-9.7-nodeforge-initrd \
    --distro rocky --version 9.7 --arch aarch64 \
    --kernel-release 5.14.0-611.5.1.el9_7.aarch64
  $CLI profile create rocky-9.7-aarch64-minimal --kind diskless

  # --- Rocky 10.2 ---
  $CLI assets initrd build rocky-10.2-nodeforge-initrd \
    --from-install-source rocky-10.2-aarch64-dvd1 \
    --kernel-release 6.12.0-211.16.1.el10_2.0.1.aarch64
  $CLI assets boot-bundle create rocky-10.2-aarch64-dvd1 \
    --kernel rocky-10.2-aarch64-dvd1-kernel \
    --initrd rocky-10.2-nodeforge-initrd \
    --distro rocky --version 10.2 --arch aarch64 \
    --kernel-release 6.12.0-211.16.1.el10_2.0.1.aarch64
  $CLI profile create rocky-10.2-aarch64-dvd1 --kind diskless

  # --- Ubuntu ---
  $CLI assets initrd build ubuntu-22.04.5-nodeforge-initrd \
    --from-install-source ubuntu-22.04.5-live-server-arm64 \
    --kernel-release 5.15.0-119-generic
  $CLI assets boot-bundle create ubuntu-22.04.5-live-server-arm64 \
    --kernel ubuntu-22.04.5-live-server-arm64-kernel \
    --initrd ubuntu-22.04.5-nodeforge-initrd \
    --distro ubuntu --version 22.04.5 --arch aarch64 \
    --kernel-release 5.15.0-119-generic
  $CLI profile create ubuntu-22.04.5-live-server-arm64 --kind diskless
'
```

kernel-release / source 名称以本轮 `install-source show` 为准，上表为历史实验室样例。

### 9.1 Rootfs plan / build / status

```bash
build_rootfs() {
  local profile="$1"
  ssh "$NF_MGMT_SSH" "
    set -euo pipefail
    plan=\$($NF_CLI profile rootfs plan $profile --output json)
    echo \"\$plan\" | jq .
    digest=\$(printf '%s' \"\$plan\" | jq -r .result.rootfs_input_digest)
    test -n \"\$digest\" && test \"\$digest\" != null
    $NF_CLI profile rootfs build $profile --if-input-digest \$digest --output json
    $NF_CLI profile rootfs status $profile --output json | jq .
    $NF_CLI profile rootfs status $profile --output json | jq -e '.result.state == \"ready\"'
  "
}

build_rootfs rocky-9.7-aarch64-minimal-diskless
build_rootfs rocky-10.2-aarch64-dvd1-diskless
build_rootfs ubuntu-22.04.5-live-server-arm64-diskless
```

### 9.2 每个 ready artifact 必查

| 字段 | 要求 |
|---|---|
| state | `ready` |
| rootfs_input_digest | 与 plan 一致 |
| kernel release | 与 boot-bundle / ISO 一致 |
| SHA-512 / size | 存在且路径可读 |
| 构建位置 | 仅在管理节点；计算节点无 dnf/apt/mksquashfs 构建痕迹 |
| cache | 相同 input 再 plan 应为 cache hit（可选但建议） |

### 9.3 建议附加：Profile clone / identity

```bash
ssh "$NF_MGMT_SSH" '
  '"$NF_CLI"' profile show rocky-9.7-aarch64-minimal-diskless --output json | jq .
  # clone 不继承 runtime/session/operation；默认可复用 SSH identity
  '"$NF_CLI"' profile clone rocky-9.7-aarch64-minimal-diskless rocky-9.7-clone-test --output json
  '"$NF_CLI"' profile show rocky-9.7-clone-test --output json | jq ".result | {provenance, ssh_identity, revision}"
  '"$NF_CLI"' profile remove rocky-9.7-clone-test --yes 2>/dev/null || \
    '"$NF_CLI"' profile remove rocky-9.7-clone-test || true
'
```

**PASS**：三套 diskless `state=ready`；initrd/boot-bundle 已登记；可选 clone 证明 identity/provenance。

---

## 10. 阶段 6：登记计算节点并校验控制面

### 10.1 IP 必须来自管理节点 hosts

```bash
ssh "$NF_MGMT_SSH" '
  set -euo pipefail
  node_ip=$(getent hosts '"$NF_COMPUTE_HOST"' | awk "NR==1 { print \$1 }")
  test -n "$node_ip"
  echo "COMPUTE_IP=$node_ip"

  '"$NF_CLI"' node add '"$NF_COMPUTE_HOST"' \
    mac='"$NF_COMPUTE_MAC"' arch='"$NF_ARCH"' \
    profile=rocky-10.2-aarch64-dvd1-diskless \
    pxe.ip_reservation="$node_ip" deploy=false

  '"$NF_CLI"' node show '"$NF_COMPUTE_HOST"' --output json
  '"$NF_CLI"' node software show '"$NF_COMPUTE_HOST"' --output json
  '"$NF_CLI"' node readiness '"$NF_COMPUTE_HOST"' --stage boot --output json
  '"$NF_CLI"' node boot preview '"$NF_COMPUTE_HOST"' --output json
'
```

**禁止**：从工作站 DNS、旧 deployment、聊天记录或手写常量推断节点 IP。

### 10.2 node show 必查

| 项 | 期望 |
|---|---|
| mac / arch | 与 VM / 参数一致 |
| profile | 当前绑定 |
| pxe.ip_reservation | 等于 hosts 解析值 |
| deploy | false（直至明确打开） |
| system.import_host_hosts | true（默认） |
| 受管 repo / SSH policy | Effective 中可见 |
| storage | install 前再设 boot_disk |

### 10.3 只读预览不产生副作用

```bash
ssh "$NF_MGMT_SSH" '
  before=$('"$NF_CLI"' node session list --output json 2>/dev/null || true)
  '"$NF_CLI"' node boot preview '"$NF_COMPUTE_HOST"' --output json
  # preview 不得创建 session / token / operation
'
```

**PASS**：节点登记成功；readiness 对 ready diskless profile 无阻断 issue；preview 只读。

---

## 11. 阶段 7：实机生命周期矩阵

VMware / 固件侧只做电源与启动介质选择；**Profile、deploy、retry、readiness 一律 CLI**。

### 11.1 推荐冷启动顺序

| # | 场景 | 绑定 Profile | 武装方式 |
|---|---|---|---|
| 1 | Rocky 9.7 install | `*-minimal-install` | `node set` + `storage.boot_disk` + `node retry --force` |
| 2 | Ubuntu install（建议） | `*-install` | 同上 |
| 3 | Rocky 9.7 diskless | `*-minimal-diskless` | `node set` + readiness + `deploy true` |
| 4 | Rocky 10.2 diskless | `*-dvd1-diskless` | 同上 |
| 5 | Ubuntu diskless | `*-diskless` | 同上 |

历史 v0.3 矩阵可省略 Ubuntu install，但 **Rocky install + 三套 diskless** 为公共必测。

### 11.2 Install 武装示例

```bash
ssh "$NF_MGMT_SSH" '
  set -euo pipefail
  '"$NF_CLI"' node set '"$NF_COMPUTE_HOST"' \
    profile=rocky-9.7-aarch64-minimal-install \
    storage.boot_disk='"$NF_BOOT_DISK"' --force
  '"$NF_CLI"' node retry '"$NF_COMPUTE_HOST"' --force
  '"$NF_CLI"' node boot preview '"$NF_COMPUTE_HOST"' --output json
  '"$NF_CLI"' node render '"$NF_COMPUTE_HOST"' --output json | head -c 2000
'
# 随后 PXE 冷启动计算节点；等待安装完成
```

Install **PASS 条件**：

```text
terminal_generation == successful_generation == current_generation
requested/applied/desired plan digest 一致
drift_state == clean
```

并经管理节点跳板 SSH 检查：

```bash
# node_ip 仍来自 hosts
ssh "$NF_MGMT_SSH" \
  "ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@\$node_ip \
   'cat /etc/os-release; uname -r; grep -E r97n0\|r97n1 /etc/hosts; \
    ls /etc/yum.repos.d 2>/dev/null; ls /etc/apt/sources.list.d 2>/dev/null; \
    systemctl --failed --no-pager'"
```

### 11.3 Diskless 武装示例

```bash
ssh "$NF_MGMT_SSH" '
  set -euo pipefail
  '"$NF_CLI"' node set '"$NF_COMPUTE_HOST"' \
    profile=rocky-10.2-aarch64-dvd1-diskless --force
  '"$NF_CLI"' node readiness '"$NF_COMPUTE_HOST"' --stage boot --output json
  '"$NF_CLI"' node deploy '"$NF_COMPUTE_HOST"' true
  '"$NF_CLI"' node boot preview '"$NF_COMPUTE_HOST"' --output json
'
# PXE 冷启动；session 到达 running 后验证
```

Diskless **PASS 条件**：

| 检查 | 期望 |
|---|---|
| readiness | 无 fail-closed issue |
| `/etc/os-release` | 匹配 Profile 发行版 |
| `uname -r` | 匹配 boot-bundle kernel-release |
| `findmnt -n -o FSTYPE /` | `overlay` |
| hosts | 含管理/计算节点名（import_host_hosts） |
| repo | 仅 NodeForge 受管源（local-only 契约） |
| SSH | 管理节点 bootstrap key BatchMode 登录 |
| failed units | 无与 NodeForge 相关的循环失败（casper/snap 等已 mask） |
| session | `node session list/show` 可观测；capability 终态撤销 |
| 构建侧 | 启动路径无目标机 dnf/apt/mksquashfs |

```bash
ssh "$NF_MGMT_SSH" '
  '"$NF_CLI"' node session list --output json
  '"$NF_CLI"' node trace '"$NF_COMPUTE_HOST"' --latest --output json | head -c 4000
  '"$NF_CLI"' events list --node '"$NF_COMPUTE_HOST"' --limit 50 --output json | head -c 4000
'
```

### 11.4 矩阵记录表（报告必填）

| 场景 | 结果 | generation/session | os-release | kernel | overlay | hosts/repo/SSH | 证据路径 |
|---|---|---|---|---|---|---|---|
| Rocky 9.7 install | | | | | n/a | | |
| Ubuntu install | | | | | n/a | | |
| Rocky 9.7 diskless | | | | | | | |
| Rocky 10.2 diskless（stage source） | | | | | | | |
| Ubuntu 22.04 diskless | | | | | | | |
| Ubuntu 26.04 diskless（stage source，至少此项真实 PXE） | | | | | | | |

---

## 12. 阶段 8：install-post canonical（v0.3 底座）

### 12.1 推荐：仓库 E2E 脚本

在已具备 Rocky install 介质、计算节点与 VMware/电源控制的环境：

```bash
# 环境变量见 tests/v0_3_install_post_e2e.sh 头部
export NODEFORGE_REMOTE="$NF_MGMT_SSH"
export NODEFORGE_NODE="$NF_COMPUTE_HOST"
# NODEFORGE_NODE_IP 若设置，仍须与 hosts 一致
bash tests/v0_3_install_post_e2e.sh
# 或
zig build test-v0.3-install-post-e2e
```

### 12.2 手动等价检查清单

1. **全新 bundle**（禁止复用旧 bundle 名/revision 冒充）：
   - `assets managed-file import`
   - `assets archive build`（Mode A：`--install-script` → `.nf.install.sh`；Mode B：无入口）
   - `assets archive import` / `assets script import`
   - `assets provision-bundle create` + item：四类 action
2. **绑定** install Profile / Node，`node retry --force` 新 generation
3. **固定顺序**：
   ```text
   managed_file → package → archive → script → @finalizer
   ```
4. **Callback 契约**（由自动化/单测 + 实机 journal 共同证明）：
   - BootSession credential 认证
   - 绑定 install generation / bundle revision / plan digest / step / attempt
   - attempt 0、跳号、非 retryable 重试、terminal regression 拒绝
5. **Completion gate**：任一 action 或 `@finalizer` 未成功前，`install.completed` 必须被拒绝
6. **终态 deployment**：
   ```text
   successful_generation == terminal_generation == current_generation
   plan digest 一致，drift_state=clean
   ```
7. **目标内容**：motd/包/archive 展开/script marker 与 HTTP 200 artifact
8. **Journal**：
   ```bash
   nodeforge node postprocess show <node> --phase install-post --output json
   nodeforge events list --node <node> --limit 100 --output json
   ```

### 12.3 Archive 专项

```bash
# 正向：标准构建
nodeforge assets archive build /tmp/nf-arc.tar \
  --install-script ./install.sh --base-dir ./payload etc usr
nodeforge assets archive build /tmp/nf-arc.tar.gz --compression gzip ...
nodeforge assets archive build /tmp/nf-arc.tar.xz --compression xz ...

# 负向：必须 archive.invalid / 等价拒绝（无 fallback）
# - 不可读 tar
# - 含绝对路径条目
# - 含 ".." 路径组件
# - payload 自带顶层 .nf.install.sh 与 --install-script 冲突
```

### 12.4 旧 action 拒绝（无兼容）

向 bundle 添加 `repository` 或 `standard_packages` → `InvalidStepAction` /
`provision.action_unsupported`（以实际 error.code 为准）。**不得**存在读取兼容、
自动迁移或运行时 fallback。

### 12.5 committing 恢复

- 单测 / `zig build test` 覆盖：`pending → running → committing → completed` 与中断恢复；
- 实机：`systemctl restart nodeforged` 后轮询 status，再查 postprocess journal 仍完整、deployment 仍 clean。

### 12.6 无 diskless 回归

install-post 全流程结束后，再跑一轮任意已 ready 的 diskless Profile 冷启动（可缩短为 Rocky 10.2 一项），
确认 session running + overlay + SSH 仍 PASS。

**PASS**：E2E 脚本或手动清单全部满足；负向三项 archive + 旧 action 拒绝；重启后 journal 可读；
且至少一个由 `--from-staging` 生成的 rootfs 已真实 diskless 启动并满足 overlay、kernel、hosts、repo、SSH 与 session 契约。

---

## 13. 阶段 9：可运营面、安全与负测

### 13.1 运行面与观测

```bash
ssh "$NF_MGMT_SSH" '
  set -euo pipefail
  '"$NF_CLI"' status --output json | jq .
  '"$NF_CLI"' runtime dhcp-leases --output json | head -c 2000
  '"$NF_CLI"' runtime tftp-counters --output json | head -c 2000
  '"$NF_CLI"' events types --output json | head -c 2000
  '"$NF_CLI"' operation list --output json | head -c 3000
  '"$NF_CLI"' assets key-list --output json 2>/dev/null || true
  '"$NF_CLI"' assets key-show --output json 2>/dev/null || true
'
```

### 13.2 Deploy gate 与 retry

| 场景 | 期望 |
|---|---|
| `deploy false` 时 install 未武装 | 不发破坏性 bootfile（destructive gate） |
| `node retry --force` | 新 generation / rearm |
| diskless `deploy true` | preview 选择 diskless boot |
| `node deploy false` | 关闭闸门 |

### 13.3 Session cancel（diskless）

在 diskless 启动过程中（或 running 后）执行 `node session cancel`，确认后续交付拒绝或
session 进入终态，且不泄漏 raw token。

### 13.4 Token / 日志脱敏

在 catalog/state/logs **以外**的普通 CLI JSON 输出中扫描：

- 无完整 raw capability / bearer secret；
- repository 相关日志无 Authorization / session header。

### 13.5 管理 API 边界

- 管理路由仅 loopback；从非本机访问应失败（环境允许时测）。
- `nodeforge` 始终在管理节点执行。

### 13.6 Exit code 抽样

| 操作 | 期望 exit |
|---|---|
| 缺少必填参数 | 2 |
| daemon 停止后 `status` | 6（或等价不可达） |
| 错误 profile 名 build | 4 类前置失败 |

**PASS**：观测命令可用；gate/retry 行为符合设计；无 token 泄漏；负向契约保持。

---

## 14. 阶段 10：完整自动化测试

在**开发机**（单元/契约）与**目标管理环境**（E2E）分别执行：

```bash
# 开发机 / CI 等价
zig build test --summary all

# 版本专属本地闸（若存在）
zig build test-v0.4-contract   # v0.4+；旧发布可 N/A

# 目标环境 install-post E2E（真实 PXE，默认不挂在 zig build test）
zig build test-v0.3-install-post-e2e
# 或 bash tests/v0_3_install_post_e2e.sh
```

install-post 的 package action 必须选择该 install source 的**本地软件索引中存在**的包，
不能跨发行版固定使用某个包名。脚本默认 Rocky 使用 `tree`、Ubuntu 使用基础包 `bash`，
也可通过 `NODEFORGE_E2E_PACKAGE=<package>` 显式指定；目标侧必须用 rpm/dpkg 数据库验证。

Ubuntu desktop ISO 可用于介质导入和 installer 能力评估，但其 casper squashfs 只有在
形成完整 layer 链，且最终树具备 init、SSH、网络组件、匹配 kernel modules 和完整本地
APT 包闭包时，才可发布为可管理 diskless rootfs。否则保持 import-only；不得只补一个
`openssh-server` 包就绕过 server rootfs 基线检查。

`zig build test` 当前聚合：

| 组件 | 内容 |
|---|---|
| unit | 核心 Zig tests |
| tests/cli.sh | CLI 契约与 help |
| tests/http.sh | HTTP 集成（Darwin 可能跳过特权 UDP） |
| tests/setup.sh | 安装布局 / setup |

补充脚本（按需，不替代双机矩阵）：

| 脚本 | 用途 |
|---|---|
| `tests/v0_2_rootfs_build.sh` | rootfs 构建 |
| `tests/v0_2_transfer_fault.sh` | 传输故障 |
| `tests/v0_2_1_ubuntu_casper_smoke.sh` | Ubuntu casper |
| `tests/real-pxe-matrix.sh` | 存储拓扑矩阵（多盘环境） |

**PASS**：`zig build test` 全绿；目标环境 install-post E2E 全绿。

---

## 15. 扩展矩阵（环境允许时）

### 15.1 存储拓扑

默认 single + `storage.boot_disk` 为公共必测。多盘实验室可跑
`tests/real-pxe-matrix.sh` 覆盖 lvm / raid* / raid*-lvm（历史 v0.1 曾 12 模式全过）。

### 15.2 Profile / Node 属性面

```bash
# hosts 策略
nodeforge profile set <p> system.import_host_hosts=false
nodeforge profile set <p> $'system.hosts_content=...'

# kernel_args（console 等保留参数拒绝覆盖是正确行为）
nodeforge profile set <p> 'kernel_args=iommu=pt'

# software
nodeforge profile set <p> software.environment=minimal-environment
nodeforge profile add-values <p> software.groups development
```

### 15.3 日志等级

```bash
nodeforge setup --reconfigure --log-level info --yes
# 开发 fresh 默认 debug；正式站点可调 info
```

### 15.4 版本增量入口

完成公共底座 PASS 后，若候选版本 ≥ v0.4，**继续**执行
[V0_4_FULL_VALIDATION_RUNBOOK.md](V0_4_FULL_VALIDATION_RUNBOOK.md)，不得用本文 PASS
宣称 v0.4 专属项已验证。

---

## 16. 发现不一致时的处置

1. **定位**：复现命令、实际输出、README/`--help-full`、设计文档、代码路径；
2. **修复**：改实现或文档（保持“文档与 CLI 可独立完成”）；
3. **重编**：阶段 2；
4. **清场**：阶段 1；
5. **从阶段 1 完整重测**，不得只重跑失败点并宣称全量 PASS；
6. 在报告“发现与修复”节列出：问题、根因、修复 commit、是否触发全量重跑。

---

## 17. 报告模板

每次大更新验证结束，在 `docs/archive/validation/` 新增带日期记录（例如
`2026-08-05_PLATFORM_VALIDATION.md`），**不要**覆盖本文或其它 runbook。建议结构：

```markdown
# NodeForge 平台验证记录 — YYYY-MM-DD

## 结论
最终结论：PASS | FAIL

## 环境与版本
- 管理/计算节点、架构、网段、DHCP 池
- Zig 版本、NodeForge 版本、commit、build time、优化级别、target
- 四二进制 SHA-256

## 执行命令摘要
（阶段 1–10 关键命令与退出码）

## 构建产物
| 程序 | file | sha256 |

## 测试矩阵
| 项 | 结果 | 证据 |
| 清场与 setup | | |
| ISO ×4（含 Ubuntu 26.04） | | |
| diskless rootfs ×3（含至少一项 stage；desktop ISO 可 import-only） | | |
| Rocky install | | |
| Ubuntu install | | |
| Rocky 9 diskless | | |
| Rocky 10 diskless | | |
| Ubuntu diskless | | |
| install-post E2E | | |
| archive 负向 | | |
| 旧 action 拒绝 | | |
| daemon 重启恢复 | | |
| zig build test | | |
| （版本专属…） | | |

## Journal / 日志证据
- deployment generation / digests / drift
- install-post steps 与 attempts
- 关键 event 顺序

## 发现与修复
| 问题 | 修复 | 是否全量重跑 |

## 最终判定
任一必测 FAIL/NOT RUN → FAIL。
```

---

## 18. 快速检查清单（执行时勾选）

- [ ] 0 主机与 ISO 确认，无误操作风险
- [ ] 1 彻底清场，系统服务未受损
- [ ] 2 四二进制**本地交叉编译** + scp 同步 + 摘要（管理节点无 Zig 残留）
- [ ] 3 fresh setup + status/config/catalog + 重启
- [ ] 4 四 ISO 导入与 show/software/catalog（含 Ubuntu 26.04）
- [ ] 5 四 diskless rootfs ready，至少一项 `--from-staging`
- [ ] 5a v0.4.1 staging enter/exec/kernels/lock/cgroup/kernel import
- [ ] 6 节点 IP 来自 hosts；readiness/preview
- [ ] 7 实机 install + diskless 矩阵
- [ ] 8 install-post 顺序/journal/gate/负向/重启
- [ ] 9 可运营面与 token 脱敏
- [ ] 10 `zig build test` + install-post E2E
- [ ] 报告落盘；总结论仅在全绿时为 PASS

---

## 附录 A：与用户既有九步流程的映射

| 原步骤 | 本文阶段 | 优化点 |
|---|---|---|
| 1 清场 | 1 + 部署后再清 | 增加预检、变量化、setup reset 语义说明 |
| 2 交叉编译 | 2 | 明确 initrd 不可 `--version`、摘要与 Make 入口；**本地交叉编译后 scp 同步，禁止远端编译** |
| 3 部署与 setup | 2–3 | schema/布局抽查、ready 轮询、冷启动 |
| 4 导入 ISO | 4 | software index、operation、catalog 校验 |
| 5 diskless profile | 5 | plan digest 门禁、clone/identity、cache |
| 6 导入 r97n1 | 6 | preview 无副作用、控制面字段表 |
| 7 加载 profile 矩阵 | 7 | 统一 PASS 表、session/trace/events |
| 8 install-post | 8 | archive build、bundle、负向、无回归 |
| 9 自动化 | 10 + 9 | 拆出可运营/安全；脚本索引 |

新增公共覆盖：Profile clone、operation/session/events/runtime、provision asset 面、
exit code 抽样、不一致时全量重测纪律、版本增量分流。

## 附录 B：主路径一句话

```text
确认主机 → 清场 → 本地交叉编译+scp 同步部署 → setup → import ISO
→ initrd/boot-bundle/diskless rootfs → node add(IP from hosts)
→ install/diskless 矩阵 → install-post E2E → 负向与重启
→ zig build test → 写报告 → PASS/FAIL
```
