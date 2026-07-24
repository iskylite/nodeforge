# v0.2 Phase 8 r97n0 QEMU 验证

日期：2026-07-23（2026-07-24 复验：同步已提交源码并改用本地交叉编译+同步工作流）  
主机：`r97n0`（aarch64，Rocky Linux 9.7）  
验证脚本：`tests/v0_2_qemu_full.sh`

## 构建与验证工作流

验证用二进制在开发机本地交叉编译后同步到 r97n0，**不在 r97n0 上编译**，确保 r97n0
始终运行与本地仓库一致的已提交构建（杜绝验证机源码漂移）：

- 本地（macOS arm64）：`zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe`
- 同步到 r97n0：`rsync -az --delete zig-out/bin/ root@r97n0:/root/NodeForge/zig-out/bin/`
- `tests/v0_2_qemu_full.sh`、`tests/v0_2_rootfs_build.sh` 不再 `zig build`，改为校验
  `zig-out/bin/{nodeforge,nodeforged,nodeforge-agent,nodeforge-initrd}` 已存在（缺失即 fail
  并提示本地交叉编译+同步）。

## 已验证

- 本机 `zig build test --summary all` 为 344/344（11/11 build steps succeeded）。
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
  -> `mksquashfs` -> 按 `rootfs_input_digest` 内容寻址登记（同 register 的 SHA-512 流式 + 幂等）。
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

QEMU 全量验证重跑通过（`tests/v0_2_qemu_full.sh`，2026-07-23）：修复夹具中仓库 `base_url` 丢失
`/Minimal` 子路径与缺失仓库文件两项问题（first-boot package action 因此可刷新元数据），并使
first-boot agent 追加写 `firstboot.log`（diskless 下位于 volatile tmpfs，每次启动为空），保留验证
二次执行的首次运行证据。rootfs-build package action `--installroot` 端到端已于 2026-07-24 验证通过（见上）；
x86_64 UEFI smoke 与 VMware（compute_use）实机矩阵因当前环境不具备（r97n0 仅有 aarch64 QEMU、无
OVMF/qemu-system-x86_64；当前上下文无 compute_use 能力），整体推迟到 v0.2.1，见
`docs/validation/V0_2_1_RESERVED.md`（传输断流/ETag 漂移/内容损坏已由
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

## 后续验收


1. boot-prepare 将 package manager、固定 package closure、nodeforged repository URL/revision 固定到 AgentPlan。
2. first-boot executor 对 asset 仅消费 `/var/lib/nodeforge/payload`；RPM/DEB 仅访问 AgentPlan 固定的
   nodeforged Yum/APT HTTP 源，并显式禁用其他源。
3. rootfs-build package action：以 `dnf --installroot` 从本地 `file://` 受管源安装到 staging（不回连 daemon、
   不 bind-mount `/dev/proc/sys`），与 OS 层一致的本地源保真。
4. 传输断流/ETag 漂移/内容损坏已验证（见上）；越权、过期、重启恢复和内存不足已在 QEMU 全量验证覆盖；
   剩余 x86_64 UEFI smoke 与 VMware（compute_use）实机矩阵，已推迟到 v0.2.1（见 `docs/validation/V0_2_1_RESERVED.md`）。

本次使用的 catalog 注入、initramfs 重打包和 QEMU 启动脚本均是验证夹具，不是
nodeforged 或 diskless guest 的运行时依赖。
