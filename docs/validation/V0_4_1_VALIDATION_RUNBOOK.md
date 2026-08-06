# NodeForge v0.4.1 staging session 验证任务书

状态：发布闸。任一必需项缺少真实证据即 FAIL。

**环境延期（不在本 runbook 必需项）：** 换核后 diskless **节点侧** vermagic / Lustre-class 实机闭环 → [`DEFERRED_DESIGN_INDEX.md`](../design/DEFERRED_DESIGN_INDEX.md) `ENV-V041-KERNEL-VERMAGIC`（`V041-D09`）。本 runbook 只收管理面/契约与会话路径证据。

## 1. 固定环境与角色

- `r97n0`：管理节点，已安装 NodeForge v0.4.1 候选构建，运行 `nodeforged`，提供 DHCP/TFTP/HTTP。
- root 权限：staging enter/exec/kernels 命令需要 euid==0。
- 至少一个已 `--keep-staging` 构建的 diskless profile（有保留树可供会话操作）。

## 2. 证据规则

每一阶段记录：候选 commit、构建时间、二进制 SHA-256、命令、退出码、UTC 时间、`nodeforged` service 日志、staging-session 前缀日志行。

失败后保留现场。禁止手工编辑 state 或跳过检查。

## 3. 本地预检

在源码目录执行：

```sh
zig fmt --check src build.zig
zig build test --summary all
zig build test-v0.4.1-staging-unit --summary all
zig build test-v0.4.1-staging
zig build test-v0.4-contract
```

全部 PASS 方可进入下一阶段。记录 commit、构建时间、二进制 SHA-256。

## 4. 契约闸（零环境依赖）

```sh
zig build test-v0.4.1-staging
```

断言清单：
- staging enter/exec/kernels 子命令存在于 `--help-full`
- `--kernel-release` flag 注册于 `profile rootfs build`
- `--memory-max` / `--pids-max` cgroup 限额 flag 注册
- 二进制不含 `pivot_root` / Docker / Podman / 顶层 `nodeforge rootfs`
- staging_session + staging_kernel_import Zig 单元测试通过

## 5. staging enter 交互会话（闸 1）

前置：已有一个 `--keep-staging` 构建的 profile（如 `rocky-9.7-x86_64-dvd-diskless`）。

```sh
# 5.1 确认保留树存在
nodeforge profile rootfs staging list
nodeforge profile rootfs staging show <profile>

# 5.2 进入交互会话
nodeforge profile rootfs staging enter <profile>
# 在会话内执行：
#   uname -a
#   ls /lib/modules/
#   cat /etc/os-release
#   exit

# 5.3 退出后确认无残留
# - 锁文件已释放：ls run/rootfs-staging/<digest>.lock 应不存在
# - mount 无残留：mount | grep <staging_path> 应为空
# - cgroup 无残留：ls /sys/fs/cgroup/nodeforge-staging/ 应为空
```

证据：会话内命令输出、退出码 0、锁/mount/cgroup 清理确认。

## 6. staging exec 非交互执行 + 超时（闸 5）

```sh
# 6.1 基本执行 + 退出码
nodeforge profile rootfs staging exec <profile> -- uname -r
echo "exit=$?"

# 6.2 超时测试（2 秒超时，执行 sleep 10）
nodeforge profile rootfs staging exec <profile> --timeout 2 -- sleep 10
echo "exit=$?"  # 预期 124（timeout 发送 TERM）
```

证据：`uname -r` 输出正确、exit=0；`sleep 10` 超时后 exit=124。

## 7. 并发锁拒绝（闸 6）

```sh
# 7.1 终端 A：进入会话（阻塞）
nodeforge profile rootfs staging enter <profile>

# 7.2 终端 B：尝试 from-staging 构建（应被拒绝）
nodeforge profile rootfs build <profile> --from-staging
# 预期：409 rootfs.staging_locked

# 7.3 终端 B：尝试第二个 enter（应被拒绝）
nodeforge profile rootfs staging enter <profile>
# 预期：error: staging tree is locked by another session

# 7.4 终端 A：exit
# 终端 B 重试 from-staging 应成功
```

证据：并发拒绝的 HTTP 响应或 CLI 错误输出、锁释放后重试成功。

## 8. staging kernels 扫描（闸 7 前半）

```sh
nodeforge profile rootfs staging kernels <profile>
```

证据：输出列出树内 kernel release(s)、vmlinuz/modules 存在标记。

## 9. --kernel-release 选择与导入（闸 7/8）

```sh
# 9.1 auto 模式（树内恰好一个 kernel 时）
nodeforge profile rootfs build <profile> --from-staging --kernel-release auto
# 预期：build 成功 + kernel import 日志（旧 release -> 新 release）

# 9.2 显式 release
nodeforge profile rootfs build <profile> --from-staging --kernel-release <release>
# 预期：build 成功 + kernel import 日志

# 9.3 keep 模式（不导入，与 v0.4 兼容）
nodeforge profile rootfs build <profile> --from-staging --kernel-release keep
# 预期：build 成功，无 kernel import 日志

# 9.4 验证 catalog 更新
nodeforge assets list --kind kernel | grep staging-kernel
nodeforge assets boot-bundle show <bundle> | grep <release>
```

证据：每种模式的 build 日志、catalog asset 和 boot bundle 更新确认（**管理面**）。

> **不在本闸：** 节点 PXE 启动后模块 vermagic / Lustre-class 加载闭环 → 环境延期 `ENV-V041-KERNEL-VERMAGIC`（`V041-D09`），见统一延期清单；不得以缺失该项判 v0.4.1 发布 FAIL。

## 10. cgroup 限额生效（闸 3 后半）

```sh
# cgroup v2 确认
stat -fc %T /sys/fs/cgroup/  # 应输出 cgroup2fs

# 限额执行
nodeforge profile rootfs staging exec <profile> \
  --memory-max 512M --pids-max 100 -- cat /proc/self/cgroup
# 验证进程在 nodeforge-staging cgroup 子树内

# 无限额 + --no-cgroup
nodeforge profile rootfs staging exec <profile> --no-cgroup -- true
```

证据：`/proc/self/cgroup` 显示 `nodeforge-staging` 路径；`--no-cgroup` 不挂载 cgroup。

## 11. 负向断言（闸 11/12/13）

```sh
# pivot_root 不存在
strings $(which nodeforged) | grep pivot_root  # 应为空

# Docker/Podman 不存在
strings $(which nodeforged) $(which nodeforge) | grep -iE 'docker|podman'  # 应为空

# 顶层 nodeforge rootfs 不存在
nodeforge rootfs 2>&1 | grep -i error  # 应报错
```

证据：所有负向断言通过（无命中）。

## 12. 完成标准矩阵

| 闸 | 描述 | 证据类型 | PASS/FAIL |
|---|---|---|---|
| 1 | enter 交互/退出无残留 | console + mount/cgroup 清理 | |
| 3 | cgroup 限额生效 + v1 fail-closed | /proc/self/cgroup + v1 拒绝 | |
| 5 | exec 退出码 + 超时 | exit code 0/124 | |
| 6 | 并发锁拒绝 | 409 + 第二 enter 拒绝 | |
| 7 | kernels 扫描 + kernel-release 导入（管理面） | CLI 输出 + catalog / boot_bundle 更新 | |
| 8 | keep 一致性 | 无 import 日志 + 兼容 | |
| 9 | 未换核不静默改启动面；换核管理面可观测 | keep 路径 + import 摘要 | |
| 11 | 无 pivot_root | strings 断言 | |
| 12 | 无 Docker/Podman | strings 断言 | |
| 13 | 无顶层 rootfs 命令 | CLI 错误 | |
| — | 节点 vermagic / Lustre-class 实机 E2E | **延期** `ENV-V041-KERNEL-VERMAGIC` | N/A（不阻断） |
