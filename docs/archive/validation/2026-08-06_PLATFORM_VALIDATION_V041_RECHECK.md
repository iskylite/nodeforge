# NodeForge v0.4.1 Platform Validation Recheck — 2026-08-06

## 结论

本轮按公共平台 runbook 从 fresh `/opt/nodeforge` 重新部署，并纳入 v0.4.1 staging 与 Ubuntu 26.04 desktop ISO。

结论：**v0.4.1 staging/diskless 闸 PASS。目标 diskless 启动、SSH 及节点侧契约均已取得证据；公共 runbook 中未在本轮复跑的 install 矩阵项目仍不宣称通过。**

## 证据

- v0.4.1 contract gate：PASS。
- v0.4.1 staging unit tests：40/40 PASS。
- aarch64 ReleaseSafe 构建：PASS。
- fresh setup 后 `nodeforged`：active；management API、catalog、DHCP、TFTP：PASS。
- 四份 ISO 导入：PASS。
  - `rocky-9.7-aarch64-minimal`
  - `rocky-10.2-aarch64-dvd1`
  - `ubuntu-22.04.5-live-server-arm64`
  - `ubuntu-26.04-desktop-arm64`
- Ubuntu 26.04 catalog：`distro=ubuntu`, `version=26.04`, `arch=aarch64`，casper layer 为 `casper/minimal.squashfs`。
- stage tree：保留成功；`staging kernels` 发现 release
  `6.12.0-211.16.1.el10_2.0.1.aarch64`，并发现 `vmlinuz`、modules、initramfs。
- `staging exec -- uname -r`：PASS；timeout case：exit 124。
- `--from-staging --kernel-release keep`：PASS，rootfs state=ready，digest
  `2297b0868dc8e3f01cf42c2130b8ed3a3d28cbebfe410b3d6c5ed7475e961866`。
- HTTP harness：PASS（停止管理 daemon 后以隔离 fixture daemon 独立运行，exit 0；同时
  修正了 profile identity、loopback reservation、字段格式、section/list 断言）。
- 完整 `zig build test`：568/568 Zig 单测 PASS；其内嵌 HTTP 子步骤受现有
  `nodeforged` 占用 DHCP/TFTP 端口影响而报 `AddressInUse`。同一 HTTP harness 在停止
  服务并隔离运行时已独立 PASS，因此该失败属于测试编排环境冲突，不是业务断言失败。
- `node add` / boot readiness / deploy：PASS；control-plane node status：`diskless.running`。
- VMware Fusion 重启 `r97n1` 后控制台显示：

  ```text
  Rocky Linux 10.2 (Red Quartz)
  Kernel 6.12.0-211.16.1.el10_2.0.1.aarch64 on aarch64
  r97n1 login:
  ```

这证明本轮基于 staging 新构建的 rootfs 已真实 PXE/diskless 启动到登录提示。

- 目标侧 SSH 取证：PASS。
  - `NAME="Rocky Linux"`, `VERSION_ID="10.2"`
  - `uname -r`: `6.12.0-211.16.1.el10_2.0.1.aarch64`
  - `/` filesystem: `overlay`
  - `/etc/hosts` 包含 `192.168.26.128 r97n0` 与 `192.168.27.210 r97n1`
  - `/etc/yum.repos.d/nodeforge.repo` 存在
  - `systemctl --failed`: `0 loaded units listed`

- 其余 diskless rootfs：Rocky 9.7 与 Ubuntu 22.04 均 state=ready。
- Ubuntu 26.04 desktop install-source 导入：PASS；其 casper/minimal.squashfs 不含
  /sbin/init 与 usr/sbin/sshd，因此当前 diskless builder 返回
  rootfs.CasperOverlayIncomplete，按 runbook 记录为 desktop import-only。
- `parseUbuntuDiskInfo`：实现与测试均按 `.disk/info` 的 `Ubuntu` 前缀识别，兼容
  `Ubuntu-Server` 与 `Ubuntu <version>`；嵌入正文的 `Ubuntu` 及 `UbuntuX` 均拒绝。

## 后续补跑结果

- Rocky 9.7 install + install-post canonical E2E：PASS。
  - generation：2；install 完成耗时 266 秒。
  - HTTP managed-file、两个 archive、script artifact：均 HTTP 200；ETag 为 SHA-256。
  - install-post journal：`e2e-motd-v1`、`e2e-pkg-v1`、`e2e-arc-a-v1`、
    `e2e-arc-b-v1`、`e2e-script-v1`、`@finalizer` 全部 succeeded，均一次尝试。
  - 目标侧 marker、`tree` package、archive Mode A/B 语义及 script 执行顺序：PASS。
- install-post 后重新冷启动 staging 产物：PASS。
  - VMware `r97n1` 实际重新上电，出现新的 TFTP/PXE 过程；旧 session 未作为本次启动证据。
  - `node trace`：`diskless.initrd_started` → `rootfs_downloading` →
    `rootfs_verified` → `rootfs_mounted` → `switching_root` →
    `agent_configuring` → `diskless.running`。
  - 目标侧：`NAME=Rocky Linux`, `VERSION_ID=10.2`；kernel
    `6.12.0-211.16.1.el10_2.0.1.aarch64`；`/` 为 `overlay`；hosts 含
    `r97n0`/`r97n1`；`/etc/yum.repos.d/nodeforge.repo` 存在；failed units 为 0。
- Ubuntu 22.04 live-server diskless 实机：PASS。
  - 使用当前 catalog 的 profile `ubuntu-22.04.5-live-server-arm64-diskless`，
    readiness 无阻断 issue，rootfs digest 为
    `48e59cdc5f2d93d98e438f70885d4a166eb8e1b98f389c0d08956ad097a85725`。
  - VMware 重新 PXE 后 trace 到 `diskless.running`；目标侧为
    `NAME=Ubuntu`, `VERSION_ID=22.04`，kernel `5.15.0-119-generic`，`/` 为
    `overlay`，hosts 含 `r97n0`/`r97n1`，受管 repo 存在，failed units 为 0。
- Rocky 9.7 diskless 实机：PASS。
  - 使用 profile `rocky-9.7-aarch64-minimal-diskless`，readiness 无阻断 issue，
    rootfs digest 为 `8a3b7c81d2e0e0aaeb521aad07e2104829c11a4e8ef9dba98f3770fb8f85e5a7`。
  - VMware 重新 PXE 后 trace 到 `diskless.running`；目标侧为 Rocky Linux 9.7，
    kernel `5.14.0-611.5.1.el9_7.aarch64`，`/` 为 `overlay`，hosts/repo 正确，
    failed units 为 0。
- Ubuntu 22.04 install + install-post E2E：FAIL（generation 3；结论已细化）。
  - PXE kernel/initrd、2.06 GB ISO 下载、Subiquity 启动及 installer hook 均已通过，
    基础安装链已经进入 install-post；不是 Ubuntu PXE 或 Subiquity 启动失败。
  - 持久化 journal 显示 `e2e-motd-v1` 一次成功，随后 `e2e-pkg-v1` 三次失败并进入
    `failed_terminal`。该 E2E 固定请求 Rocky 介质可用的 `tree`，但本轮 Ubuntu 22.04
    live-server 本地软件索引不包含 `tree`；local-only apt 无法满足该包，最终 generation
    被标记为 failed。
  - 这属于跨发行版 E2E 测试包选择错误，已改为按 profile 选择本地可用包（Ubuntu 默认
    `bash`，可显式覆盖），并使用 dpkg/rpm 数据库验证。由于按要求暂不部署，本轮没有产生
    修复后的新 generation，故历史 generation 3 仍保持 FAIL，不追认 PASS。
  - 同时把 Subiquity webhook 的有界 body 上限从 4 KiB 调整为 64 KiB，并在落事件流前
    截断 description；现场出现的 413 不再丢弃正常 curtin 诊断，同时仍保持资源上限。
  - 失败后已将 `r97n1` 恢复为 Rocky 10.2 staging diskless，并重新取得
    `diskless.running`、目标侧 kernel/overlay/repo/failed-units 证据。

## 仍未完成项（按 runbook 必须保留为 NOT RUN）

- Ubuntu install 实机矩阵：NOT RUN。
- install-post 负向 archive 三项、旧 action 拒绝、daemon 重启恢复专项：NOT RUN。

因此本报告证明了 Rocky install/install-post、v0.4.1 staging/diskless 增量闸与四份
介质导入闸；不能把尚未执行的 Ubuntu install、全矩阵和负向专项总结为 PASS。

## 注意事项

1. 本轮通过 `--kernel-release keep` 完成 staging repack。`auto` 在 boot bundle 已使用同一 kernel release 时按设计排除当前 release，因此返回 `rootfs.NoKernelsFound`；这不是 staging tree 缺少 kernel。
2. fresh rootfs 会生成新的 SSH host key；验证时使用一次性临时 known-hosts，并通过本轮节点配置注入验证用 SSH 访问凭据，未修改工作站持久 SSH 配置。

## 修复内容

- Ubuntu `.disk/info` 只接受 `Ubuntu` 前缀，并支持 `Ubuntu-Server` 与 `Ubuntu <version>` 两种格式。
- Rocky/RHEL rootfs 安装 `kernel-core`、`kernel-modules`。
- staging kernel scanner 支持 `/usr/lib/modules/<release>/vmlinuz`（以及 `/lib` 兼容布局）。
- usage errors 的 `InvalidItemUsage` 返回 exit code 2。

## 本轮继续补跑（2026-08-06）

- Archive fail-closed 负向：PASS（管理节点公开 CLI）。不可读输入、绝对路径、`..` 路径组件，以及顶层 `.nf.install.sh` 与 `--install-script` 冲突四项均被拒绝，未生成可用 archive。
- daemon 重启恢复：PASS（管理节点真实 `systemctl restart nodeforged`）。重启后服务为 active，`nodeforge status` 的 management/catalog/DHCP/TFTP/API checks 全部为 true；既有 diskless session 仍可由 `node trace` 读取，并明确记录 `daemon_restart_gap`，没有丢失 session 事实。
- 运维 exit-code 抽样：缺少必填参数返回 2；错误 profile build 返回实际前置失败码 1（不将其放宽为 PASS）。普通 `status --output json` token scan：CLEAN。
- 重启后的控制面仍显示 `r97n1` 为 `diskless.running`；此前已取得的 staging kernel、overlay、SSH、repo、failed-units 目标侧证据保持有效。
