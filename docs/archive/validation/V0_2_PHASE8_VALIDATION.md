# v0.2 Phase 8 r97n0 QEMU 验证

> 历史归档：本页和 `docs/archive/validation-fixtures/v0_2_qemu_full.sh` 只证明冻结的 v0.2 三 token capsule 协议，
> 不属于 v0.4 发布验证。脚本会拒绝 v0.4 二进制；v0.4 必须使用
> [`V0_4_FULL_VALIDATION_RUNBOOK.md`](V0_4_FULL_VALIDATION_RUNBOOK.md)。

日期：2026-07-23（2026-07-24 复验：同步已提交源码并改用本地交叉编译+同步工作流）  
主机：`r97n0`（aarch64，Rocky Linux 9.7）  
验证脚本：`docs/archive/validation-fixtures/v0_2_qemu_full.sh`

## 构建与验证工作流

验证用二进制在开发机本地交叉编译后同步到 r97n0，**不在 r97n0 上编译**，确保 r97n0
始终运行与本地仓库一致的已提交构建（杜绝验证机源码漂移）：

- 本地（macOS arm64）：`zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe`
- 同步到 r97n0：`rsync -az --delete zig-out/bin/ root@r97n0:/root/NodeForge/zig-out/bin/`
- 历史夹具 `docs/archive/validation-fixtures/v0_2_qemu_full.sh` 与当前
  `tests/v0_2_rootfs_build.sh` 不再 `zig build`，改为校验
  `zig-out/bin/{nodeforge,nodeforged,nodeforge-agent,nodeforge-initrd}` 已存在（缺失即 fail
  并提示本地交叉编译+同步）。

## 已验证

- 本机 `zig build test --summary all` 为 345/345（11/11 build steps succeeded）。
- r97n0 上从保留的 Rocky Linux 9.7 基线派生 1,203,974,144 byte squashfs，
  注入当前 `nodeforge-agent`；从保留的 initramfs fixture 注入当前
  `nodeforge-initrd`，不修改基线 fixture。
- QEMU aarch64（3 GiB）从真实 nodeforged 获取 BootConfig；rootfs 先经严格 HEAD
  校验，再以不超过 4 MiB 的连续 Range 分块下载，每块校验 206、Content-Range、
  Content-Length 与 immutable ETag，最终校验 SHA-512。
- 完成 squashfs lower、tmpfs upper/work、overlay、`switch_root` 和 Rocky Linux
  9.7 systemd 启动，串口出现 `nf-v02-full login:`。
- 生命周期按 CAS 顺序推进到 `diskless.running`（event_seq=6）；AgentPlan 拉取后
  `/agent-consumed` 撤销 agent capability，running 后撤销 event capability。
- `nodeforge-firstboot.service` 成功执行，hostname 为 `nf-v02-full`。
- 验证夹具创建真实 managed-file asset，并经 Profile first-boot bundle 生成非空
  AgentPlan payload closure；guest 下载 24-byte payload，校验 size/SHA-256 后本地写入
  `/etc/issue.d/nodeforge-proof.issue`，串口登录提示出现 `NODEFORGE_PAYLOAD_PROOF`。
- 验证夹具在同一 session/plan 内第二次调用 agent；journal 中步骤状态为
  `succeeded`，第二次执行记录 `skipped (journal succeeded)`，证明已成功副作用不会重放。
- 同一 bundle 另含必然失败的 retryable managed-file；按 Profile
  `max_attempts=3/backoff_seconds=1` 尝试三次后 journal 标记 `failed`，但 guest
  仍进入 login 且 lifecycle 保持 `diskless.running`，证明 postprocess degraded
  不会倒退启动状态。
- 在 guest 启动前交叉使用 config/rootfs capability 均返回 401；boot-prepare 后
  重启 nodeforged，原 session/config capability 仍能恢复并返回相同 BootConfig；
  running 后四类 capability 全部返回 401。
- 使用新 session 将 QEMU 内存降为 1536 MiB，initrd 在 rootfs 传输前报
  `InsufficientMemory` 并追加 `diskless.failed`，证明 checked memory gate fail-closed。
- agent pre-init 持久化的 `/var/lib/nodeforge/boot.json` 包含 pinned
  first-boot step；文件中不再包含 `agent_token`/`event_token` 等 token 字段。

## 暴露的未完成项

managed-file 的非空 payload、journal/degraded、capability 错域/撤销、daemon 重启恢复
和内存不足均已验证。archive/script 资产导入 CLI 与 `provision-bundle item add
action=archive|script|package` 已实现。

`profile rootfs build` CLI/管理端点已接线并在 r97n0 端到端验证（2026-07-23）：
- `POST /api/v1/management/profiles/<name>/rootfs/build`（`src/http/server.zig` `managementRootfsBuild`）
  从 Profile build projection 构建内容寻址 rootfs：OS 层经发行版原生 install-root 工具
  （`dnf --installroot`，`src/provision/rootfs_os_builder.zig`）从 install source 受管 repository
  构建 chroot 基线 -> 叠加 rootfs-build phase 步骤（`rootfs_build_executor`，复用 first_boot 渲染）
  -> `mksquashfs` -> 按 `rootfs_input_digest` 内容寻址发布（SHA-512 流式 + 幂等）。
- OS 层构建使用 `file://` 指向构建主机本地 `repos_dir`（设计 file:// at build time），避免构建期
  dnf 回连本 daemon 造成自死锁；rootfs-build package action 同样以 `dnf --installroot` 在 host
  上下文从本地 `file://` 受管源安装到 staging（`rootfs_build_executor` package 步骤标记 `chroot=false`，
  `renderStep` 嵌入 `--installroot=<staging>`），不进入 chroot、不 bind-mount `/dev/proc/sys`、不回连
  daemon；managed_file/archive/script 仍 chroot 执行。避免单 worker 自死锁，且无 bind-mount 清理风险。
- r97n0 验证：对真实 Rocky 9.7 Minimal 受管源构建 109,146,112 byte squashfs，managed_file/archive/script
  三类 rootfs-build 步骤经 chroot 烘入 lower 后在产物内逐项校验
  （`NODEFORGE_BUILD_PROOF/ARCHIVE/SCRIPT`）；二次构建命中缓存返回 `already_present`（不重构建）。
  package action（`--installroot` + `tree`）于 2026-07-24 在 r97n0 端到端验证通过（`tests/v0_2_rootfs_build.sh`）：以 `dnf --installroot` 从本地 `file://` 源安装 `tree` 到 staging，产物内 `/usr/bin/tree` 可执行校验通过；二次构建命中缓存返回 `already_present`。
- `tests/v0_2_rootfs_build.sh` 为可复现夹具（catalog 注入 + 仓库 symlink + 验证）。

QEMU 全量验证重跑通过（`docs/archive/validation-fixtures/v0_2_qemu_full.sh`，2026-07-23）：修复夹具中仓库 `base_url` 丢失
`/Minimal` 子路径与缺失仓库文件两项问题（first-boot package action 因此可刷新元数据），并使
first-boot agent 追加写 `firstboot.log`（diskless 下位于 volatile tmpfs，每次启动为空），保留验证
二次执行的首次运行证据。rootfs-build package action `--installroot` 端到端已于 2026-07-24 验证通过（见上）；
x86_64 UEFI smoke 与 VMware（compute_use）实机矩阵因当前环境不具备（r97n0 仅有 aarch64 QEMU、无
OVMF/qemu-system-x86_64；当前上下文无 compute_use 能力），整体推迟到 v0.2.2，见
`docs/archive/validation/V0_2_0_2_2_AUDIT_AND_VALIDATION.md`（传输断流/ETag 漂移/内容损坏已由
`tests/v0_2_transfer_fault.sh` 验证）。

## 传输故障注入负测

`tests/v0_2_transfer_fault.sh` 用故障注入 HTTP/1.0 服务器复现 initrd rootfs 传输契约
（严格 HEAD + 分块 Range + `If-Range` + 逐块元数据校验 + 最终 SHA-512，对应
`src/initrd.zig` `downloadRootfs` 与 `src/initrd/download.zig` `parseHead`/`validateRange`），
在 r97n0 验证以下 fail-closed 行为（2026-07-24）：

- 干净基线：HEAD 200/Content-Length/ETag/Accept-Ranges、每块 206/Content-Range/ETag/Content-Length
  全部通过，最终 SHA-512 一致。
- ETag 漂移：服务器在 HEAD 与 Range 间更换内容/ETag，校验在 HEAD（ETag 不匹配）或
  Range（`If-Range` 触发 200 而非 206）处失败，整次下载被拒绝。
- 内容损坏：响应头合法但末块字节被翻转，逐块校验通过，最终 SHA-512 不匹配而被拒绝。
- 断流：服务器在分块中途关闭连接，curl 报 `transfer closed with N bytes remaining`，
  下载被拒绝。

该校验逻辑精确复刻 `download.zig`；Zig 单测覆盖 `parseHead`/`validateRange` 的确切代码。

## Ubuntu 22.04 aarch64 diskless QEMU smoke（2026-07-25）

验证脚本：`tests/v0_2_ubuntu_qemu_smoke.sh`（r97n0）。在已发布 Ubuntu 安装源的 catalog
（`nodeforge assets import /root/ubuntu-22.04.5-live-server-arm64.iso`）上，复用 ISO casper
`ubuntu-server-minimal.squashfs` 作为 diskless lower rootfs，验证 diskless 启动主循环与
first-boot 在 Ubuntu 用户态下的正确性。

### 暴露并修复的跨发行版可移植性缺陷

v0.2 的 diskless node-apply 渲染器（`src/provision/node_apply.zig`）最初按 Rocky
（dnf / `wheel` 组）假设编写。Ubuntu 验证暴露两处缺陷，导致 agent pre-init 的 `nodeApply`
在 `set -eu` 脚本中失败、`diskless.failed`、PID 1 退出 1 触发 kernel panic：

1. **sshd/ssh 单元启用未 best-effort**：`renderSsh` 的 enable 分支
   `systemctl enable sshd 2>/dev/null || systemctl enable ssh` 缺少 `|| true`（disable 分支有）。
   Ubuntu 最小 casper rootfs 未预装 openssh-server，两个单元均不存在，`||` 末条命令失败，
   `set -e` 中断 node-apply。
2. **sudo 硬编码 wheel 组**：`renderUsers` 对 sudo 用户无条件 `usermod -a -G wheel`。
   Ubuntu 无 `wheel` 组（用 `sudo` 组），`usermod` 返回 `group 'wheel' does not exist`，
   中断 node-apply。diskful 的 kickstart/ubuntu adapter 已按发行版区分（wheel/sudo），
   但 diskless 渲染器作为“只消费服务端 typed projection 的 dumb consumer”不应感知发行版。

修复（`src/provision/node_apply.zig`、`src/agent.zig`）：

- `renderSsh`/`renderNtp` 的 enable 分支补 `|| true`，与各自 disable 分支对称：单元未安装
  （由 software transaction / first-boot 后续安装，或在最小 rootfs 中缺失）时不中断 node-apply。
  正式部署的 sshd 存在性仍由 readiness 阶段校验（设计：SSH enabled 但无 sshd 时拒绝启用 PXE）。
- `renderUsers` 的 sudo 改用 portable `/etc/sudoers.d/nodeforge-<user>`（0440，
  `<user> ALL=(ALL) ALL`）drop-in 授予，替代硬编码 wheel/sudo 组成员。drop-in 不依赖
  发行版默认 `%wheel`/`%sudo` sudoers 条目，跨发行版一致生效；显式 `user.groups` 成员保持不变。
- `src/agent.zig` `runChecked` 在子进程失败时把退出码与 stderr 打到控制台：agent 作为
  PID 1 此前静默 panic、无任何诊断，难以定位 node-apply 脚本究竟哪条命令失败。

### 验证结果（r97n0，2026-07-25）

- 本地交叉编译 `zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe`，同步
  `zig-out/bin/` 到 r97n0（**不在 r97n0 上编译**）。
- `nodeforge assets import`：catalog 正确填充 distro=ubuntu / version=22.04 / arch=aarch64、
  casper `vmlinuz`+`initrd`、apt 仓库与全量软件索引、grub bootloader、默认 profile；
  `ubuntuRepositoryComplete` 为 true。
- smoke 从 ISO casper `ubuntu-server-minimal.squashfs` 派生 diskless lower rootfs
  （补 `/sbin/init` -> systemd 符号链接、注入 agent + firstboot unit + validation drop-in），
  注入 boot_bundle/profile/node 到已有 Ubuntu catalog，QEMU aarch64（3 GiB）启动。
- 生命周期：initrd -> `switch_root` -> `agent_configuring` -> 拉取 AgentPlan（2569 B）->
  `agent-consumed` -> `nodeApply` 成功（不再 `diskless.failed`）-> `exec /sbin/init` ->
  Ubuntu 22.04 systemd 启动 -> firstboot unit 执行 -> `diskless.running`。
- first-boot `[first-boot] done: 0 failure(s)`；串口出现 `NODEFORGE_UBUNTU_VALIDATION_DONE`。
- smoke 三项断言全 PASS：`validation done` / `diskless.running` / `ubuntu boot evidence`。
- 本机 `zig build test` = 345/345 通过（新增 `sudo granted via portable sudoers drop-in;
  service enable best-effort` 用例）。

### 范围与限制

- 该 smoke 复用 ISO 的 casper squashfs 作为 diskless lower rootfs，**不是** nodeforge 构建的
  Ubuntu rootfs。Ubuntu OS 层 rootfs-build（apt/debootstrap，
  `src/provision/rootfs_os_builder.zig` `AptOsLayerUnsupported`）在 v0.2 不支持，整体推迟到
后续矩阵。因此该 smoke 验证的是 diskless 启动主循环 + first-boot
在 Ubuntu 用户态下的正确性，非 nodeforge-built Ubuntu rootfs。
- x86_64 UEFI smoke 同样推迟到 v0.2.2（r97n0 仅有 aarch64 QEMU，无 OVMF/qemu-system-x86_64）。
- catalog 注入、initramfs 重打包、QEMU 启动脚本均为验证夹具，非 nodeforged / diskless guest
  运行时依赖。

## 后续验收


1. boot-prepare 将 package manager、固定 package closure、nodeforged repository URL/revision 固定到 AgentPlan。
2. first-boot executor 对 asset 仅消费 `/var/lib/nodeforge/payload`；RPM/DEB 仅访问 AgentPlan 固定的
   nodeforged Yum/APT HTTP 源，并显式禁用其他源。
3. rootfs-build package action：以 `dnf --installroot` 从本地 `file://` 受管源安装到 staging（不回连 daemon、
   不 bind-mount `/dev/proc/sys`），与 OS 层一致的本地源保真。
4. 传输断流/ETag 漂移/内容损坏已验证（见上）；越权、过期、重启恢复和内存不足已在 QEMU 全量验证覆盖；
   VMware aarch64 实机矩阵已通过 Computer Use 完成；x86_64 UEFI 继续作为矩阵扩展项。
Ubuntu casper squashfs diskless 方案的设计和落地实现属 v0.2.1（见 `docs/design/V0_2_1_UBUNTU_DISKLESS.md`）。

本次使用的 catalog 注入、initramfs 重打包和 QEMU 启动脚本均是验证夹具，不是
nodeforged 或 diskless guest 的运行时依赖。
