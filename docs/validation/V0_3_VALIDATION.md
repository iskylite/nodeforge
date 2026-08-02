# NodeForge v0.3 验证记录

验证日期：2026-08-02

目标环境：`r97n0`（Rocky 9.8 aarch64 管理节点）与 VMware Fusion UEFI aarch64
虚拟机 `r97n1`

## 结论

**最终结论：PASS。**

本轮从清空 r97n0 的 NodeForge 服务、配置和数据开始，按 README 重新交叉编译、部署、
fresh setup、导入三份 ISO、构建三套 diskless Profile、登记 r97n1，并完成两项 install、
三项 diskless、v0.3 install-post E2E、负向 CLI 和完整自动化。所有业务变更只使用公开
CLI；没有直接修改数据库、Catalog 文件或内部 journal 来制造成功状态。

v0.3 发布边界据此明确为：

- install-post 只接受 `managed_file`、`package`、`archive`、`script` 四类 canonical
  action，固定顺序后执行 `@finalizer`；
- callback 必须由有效 BootSession credential 认证并绑定 install generation、bundle
  revision、plan digest、step 与 attempt；
- `install.completed` 在所有 action 和 finalizer 成功前必须拒绝；
- 成功提交经过持久 `committing` WAL，daemon 重启时先恢复 deployment，再发布 journal
  completed；
- `repository` 与 `standard_packages` 已退出，不兼容、不迁移、不 fallback；
- archive 导入对不可读 tar、绝对路径和 `..` 路径 fail closed；
- v0.3 没有破坏既有 Rocky/Ubuntu diskless 流程。

早期实现只有 action 渲染而没有 step callback 与 finalizer completion gate，不能作为
v0.3 完成证据。本记录对应的是修正后的实现和 fresh 环境复测结果。

## 构建与 fresh 部署

构建命令：

```text
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe
```

构建身份：

- Zig：`0.16.0`
- NodeForge：`0.3.0`
- archive 隐藏入口复测 commit：`36005a3e2136`（工作树包含本次入口名调整）
- archive 隐藏入口复测 build time：`2026-08-02T08:57:10Z`
- 目标：Linux aarch64 GNU、ReleaseSafe

四个产物均为 Linux aarch64 ELF：

| 产物 | SHA-256 |
|---|---|
| `nodeforge` | `090cb882d025d901abefa541d0b66f9c498edbbbfacd3e2eceda3605ee912de9` |
| `nodeforged` | `dd3e3a4aef089c2957b61f6ee5378af07ee3d92d49bd0ddb3def3123fa5bc52e` |
| `nodeforge-initrd` | `478520c6316d4e7d5ebf54802f797797bf8ea5f7fc5c2d2d11fbb1c72ce1cfba` |
| `nodeforge-agent` | `193625b12dbb311141c77fc4386c7324a8261da73932aee745768c2e57b1e7cd` |

r97n0 清场只删除 `/opt/nodeforge`、`nodeforged.service` 和
`/etc/profile.d/nodeforge.sh`；原始 ISO 位于 `/root`，系统 SSH、NetworkManager 和其他
基础服务未受影响。随后仅使用 README 的两次 `nodeforge setup` 完成初始化。fresh
`status`、`config validate` 和 `catalog validate` 均通过。

## ISO 与 diskless 构建

三份 ISO 均通过 `nodeforge assets import` 导入：

| Install Source | 平台 | Kernel | Repository |
|---|---|---|---|
| `rocky-9.7-aarch64-minimal` | Rocky 9.7 aarch64 | `5.14.0-611.5.1.el9_7.aarch64` | Minimal |
| `rocky-10.2-aarch64-dvd1` | Rocky 10.2 aarch64 | `6.12.0-211.16.1.el10_2.0.1.aarch64` | BaseOS、AppStream |
| `ubuntu-22.04.5-live-server-arm64` | Ubuntu 22.04.5 aarch64 | `5.15.0-119-generic` | APT ISO root、casper layers |

initrd、boot bundle、diskless Profile 和 rootfs 均由 CLI 创建：

| Profile | Rootfs input digest | 压缩大小 | 展开大小 | 结果 |
|---|---|---:|---:|---|
| Rocky 9.7 diskless | `a745bc82bbc3f457c2f1f43206c73b5e648bfe64da2153d1107cf1617fa2beb7` | 143,962,112 | 585,396,136 | ready |
| Rocky 10.2 diskless | `c316f861e5ac106b512c7c46e3af7034d8d06a78ca48c8dac8378568ca069c67` | 120,627,200 | 387,076,368 | ready |
| Ubuntu diskless | `55649ab6e6de0afe7e15c1f32001022213ff394e4c064136dd2d2577b06581bb` | 992,223,232 | 2,281,842,561 | ready |

## r97n1 与 Compute Use 实机矩阵

r97n1 的 `192.168.27.210` 严格读取自 r97n0 `/etc/hosts`；MAC
`00:50:56:2A:23:DB` 与 VMX 一致。NodeForge 的 Profile、deploy、retry、readiness 和
boot preview 全部通过 CLI；VMware Fusion 中选择 r97n1、Start Up 和 Shut Down 由
Computer Use 执行，每次操作后重新读取 accessibility state 确认界面结果。

| 场景 | 结果 | 核心证据 |
|---|---|---|
| Rocky 9.7 install | PASS | generation 1，terminal=successful=1，drift clean |
| Ubuntu install | PASS | generation 2，terminal=successful=2，drift clean |
| Rocky 9.7 diskless | PASS | Rocky 9.7、匹配 kernel、overlay 根、本地 Minimal repo |
| Rocky 10.2 diskless | PASS | Rocky 10.2、匹配 kernel、overlay 根、本地 BaseOS/AppStream |
| Ubuntu diskless | PASS | Ubuntu 22.04.5、匹配 kernel、overlay 根、本地 APT repo |

五项都验证了 hosts、受管 repo、bootstrap key SSH 和 failed units；未发现 diskless
回归。

## install-post E2E

执行：

```text
bash tests/v0_3_install_post_e2e.sh
```

结果：PASS。隐藏入口调整后的 fresh bundle 为 `v03-installpost-20260802165745`，
Rocky 9.7 install generation 4 从 PXE 到 `install.completed` 用时 287 秒。

最终 deployment：

- `current_generation=4`
- `terminal_generation=4`
- `successful_generation=4`
- requested/applied/desired plan digest：
  `4e1ecad1da83cba135c710721c8c783d1b9f782902a128adbb827ae93469f835`
- `drift_state=clean`

Journal：

| Step | 状态 | Attempts |
|---|---|---:|
| `e2e-motd-v1` | succeeded | 1 |
| `e2e-pkg-v1` | succeeded | 1 |
| `e2e-arc-a-v1` | succeeded | 1 |
| `e2e-arc-b-v1` | succeeded | 1 |
| `e2e-script-v1` | succeeded | 1 |
| `@finalizer` | succeeded | 1 |

目标机证据：

- `/etc/motd` 含 `NODEFORGE_INSTALLPOST_MOTD`；
- `tree` 包已安装；
- archive Mode A 的 `.nf.install.sh` 已执行，普通顶层 `install.sh` 仅解压且未执行；
- archive Mode B 已直接展开到 `/`；
- script marker 已生成；
- 四个 immutable artifact URL 都返回 HTTP 200；
- managed-file ETag 为
  `697c5a3b8825fd5ae0025d11d623b5f262fceac6a2baedf805296b2222539c8a`。

Event 顺序为五组 `post_step_started/post_step_succeeded`，随后
`post_finalizer_started/post_finalizer_succeeded`，最后才是 `install.completed`。

## 负向、恢复与自动化证据

CLI 实测：

- 不可读 tar、绝对路径 tar、含 `..` 的 tar：均返回 `archive.invalid`；
- `repository` action：返回 `InvalidStepAction`；
- `standard_packages` action：返回 `InvalidStepAction`。

`zig build test` 结果为 PASS，覆盖：

- callback 认证、BootSession/install generation 绑定；
- generation 使用不同 bundle revision、plan digest 或 session 重绑时拒绝；
- attempt 0、跳号、非 retryable 重试、terminal regression 拒绝；
- canonical action 固定顺序和 early finalizer 拒绝；
- finalizer 前 `install.completed` completion gate；
- `pending → running → committing → completed`；
- interrupted committing 先恢复 deployment 后发布 completed，重复恢复幂等；
- archive Mode A/B 和路径 fail-closed；
- 旧 action 无兼容、迁移或 fallback。

真实执行 `systemctl restart nodeforged` 后，需等待 daemon 完成 preflight，而不能只凭
systemd active 判定 ready。管理面恢复健康后，generation 4 completed journal 完整保留，
deployment 仍为 terminal=successful=4、digest 一致、drift clean。

## 发布判定

本轮所有必要项目都有实机或自动化证据，未出现必须修复后重跑的 CLI/README/实现偏差。
因此 NodeForge v0.3 在该 aarch64 双机环境中的发布闸结论为 **PASS**。

该结论不外推到未执行的硬件、架构或网络拓扑；未来若新增平台矩阵，仍须按 README 的
fresh 流程独立验证。

## 2026-08-02 canonical archive build 增量验证

新增公开命令：

```text
nodeforge assets archive build <output.tar> [--install-script <path>] \
  [--base-dir <dir>] [--files-from <list>] [paths...]
```

在 r97n0（aarch64、GNU tar 1.34）交叉构建产物上执行真实打包和解压，结果：

| 检查项 | 结果 | 证据 |
|---|---|---|
| 隐藏入口映射 | PASS | tar 顶层仅一个 `.nf.install.sh` |
| 多位置参数 + files list | PASS | JSON `payload_paths=3` |
| hardlink | PASS | 解压后 original/hardlink inode 同为 `167953805` |
| symlink | PASS | target 仍为 `original` |
| mode/mtime | PASS | mode `0640`；mtime `1612325106` 不变 |
| 源 atime 不扰动 | PASS | 打包前后均为 `1577934245` |
| xattr | PASS | `user.nodeforge=canonical` 解压后存在 |
| 保留入口冲突 | PASS | payload 含顶层 `.nf.install.sh` 时拒绝 |
| parent path | PASS | `../escape` 在调用 tar 前拒绝 |
| ctime 语义 | PASS | JSON 明确 `ctime_preserved=false`，文档明确不可还原 |
| 无安装脚本 Mode B | PASS | `mode=B`、`entrypoint=null`，普通 `install.sh` 仅作为数据条目 |

随后扩展 `--compression none|gzip|xz` 并在同一 r97n0 环境增量验证：三种产物分别被
`file` 识别为 POSIX tar、gzip 和 XZ；同一条
`tar --same-owner --same-permissions --acls --xattrs -xf` 均成功解压，隐藏入口、硬链接
inode 和 symlink target 保持一致。`--compression gzip` 搭配 `.tar` 后缀被 CLI 拒绝。
Rocky rootfs bootstrap 已显式加入 `gzip`、`xz`；Ubuntu casper rootfs 发布前显式验证
`tar`、`gzip`、`xz` 可执行文件存在。

`zig build test` 用时约 61 秒并通过。此增量验证证明标准构建命令及共享 archive
解压元数据选项符合设计；它不替代上文已经执行的五项 VMware 系统矩阵。
