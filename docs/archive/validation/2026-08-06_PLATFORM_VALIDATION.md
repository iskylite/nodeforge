# NodeForge 平台验证记录 — 2026-08-06

## 结论

最终结论：**FAIL（保留现场）**。

本轮完成了 fresh 部署、三份受支持 ISO 导入、三套 rootfs、v0.4.1 staging 管理面闸，
以及一套由 `--from-staging --kernel-release keep` 生成 rootfs 的真实 PXE diskless
启动。未满足全量 PASS 的原因是：Ubuntu 26.04 desktop 媒体被当前媒体探测器拒绝；
`--kernel-release auto` 在 Rocky 10.2 stage 树上因树内没有 kernel 被拒绝；目标 VM
控制面已到 `diskless.running`，但 SSH/目标侧完整契约未取得；仓库聚合测试中的
`tests/cli.sh` 失败。

## 环境与版本

- 管理节点：`r97n0`, `aarch64`, `192.168.27.128`, `enp26s0`
- 计算节点：VMware Fusion `r97n1`, `aarch64`, DHCP reservation `192.168.27.210`,
  MAC `00:50:56:2A:23:DB`
- 候选版本：`nodeforge 0.4.1`, built `2026-08-06T07:19:28Z`
- 源码工作区当时 HEAD：`240cb685ffe6`（远端源码无 git 命令，二进制 commit 显示 unknown）
- 远端 Zig：`0.16.0`

四个 aarch64 二进制（远端 fresh build）：

| 程序 | SHA-256 |
|---|---|
| nodeforge | `891d532612edfcfca5c1930812f1f92efb072b69f773ef7dc452e4f12ebdb095` |
| nodeforged | `171caee79821fc82c49edda9bc5c9562ac74def63316ad8c92e2cfa7d1331c9a` |
| nodeforge-initrd | `c52e2031c1de2cd4e323a2daa1963a4cf668ffe9e682060917faa02e83e90f3d` |
| nodeforge-agent | `6f0e0d7d12fbedcc7052c3c0130648f1b17571a0e336086b40e9bebc962a1a52` |

## 阶段结果

| 阶段/项目 | 结果 | 证据摘要 |
|---|---|---|
| fresh 清场 + setup | PASS | `/opt/nodeforge` 重建；status/config/catalog 全部 `ok=true` |
| Rocky 9.7 ISO | PASS | operation succeeded；install source `rocky-9.7-aarch64-minimal` |
| Rocky 10.2 ISO | PASS | operation succeeded；install source `rocky-10.2-aarch64-dvd1` |
| Ubuntu 22.04 ISO | PASS | operation succeeded；install source `ubuntu-22.04.5-live-server-arm64` |
| Ubuntu 26.04 desktop ISO | FAIL | durable operation `8f990cf445b2a322e15b525c987ef0b1`，error `install_source.MediaTupleMismatch` |
| Rocky 9.7 rootfs | PASS | `state=ready`, digest `f402a1b2…`, kernel `5.14.0-611.5.1.el9_7.aarch64` |
| Ubuntu 22.04 rootfs | PASS | `state=ready`, digest `fa9f4961…`, kernel `5.15.0-119-generic` |
| Rocky 10.2 stage rootfs | PASS（管理面） | `--keep-staging` 后 `--from-staging --kernel-release keep`，`state=ready`, digest `8068ed59…` |
| staging enter/exec/timeout | PASS | `uname -r` exit 0；`sleep 10 --timeout 2` exit 124；lock/mount 清理日志存在 |
| staging kernels/auto | FAIL | `staging kernels` 返回空；`--kernel-release auto` 返回 `rootfs.NoKernelsFound` |
| 真实 stage diskless PXE | PASS（控制面） | VMware console 显示 NodeForge boot；trace 依次到 `diskless.running`；session phase `diskless_running` |
| 目标 SSH/overlay/hosts/repo/failed units | NOT RUN / FAIL | `192.168.27.210` 在 150 秒内未接受 SSH，未取得节点侧完整证据 |
| v0.4.1 staging contract gate | PASS | staging commands、kernel flag、cgroup flags、负向 binary assertions、unit tests 全 PASS |
| `zig build test-v0.4.1-staging-unit` | PASS | 40/40 tests |
| `zig build test-v0.4.1-staging` | PASS | contract gate PASS |
| `zig build test --summary all` | FAIL | 567/567 Zig tests pass，但 `tests/cli.sh` 失败导致聚合失败 |

## 关键真实证据

目标 `r97n1` 的 `node trace --latest`：

```text
diskless.initrd_started
diskless.rootfs_downloading
diskless.rootfs_verified
diskless.rootfs_mounted
diskless.switching_root
diskless.agent_configuring
diskless.running
```

该 session 使用：

```text
profile=rocky-10.2-aarch64-dvd1-diskless
rootfs_input_digest=8068ed590de27deea9f663b7b13eabade86a651a55561a54decb898c619350c0
rootfs=sha256/80/8068ed590de27deea9f663b7b13eabade86a651a55561a54decb898c619350c0.squashfs
kernel_release=6.12.0-211.16.1.el10_2.0.1.aarch64
```

runtime counters：DHCP active lease `192.168.27.210`；TFTP `started=11,
completed=6, failed=5`。管理日志记录 rootfs range download、verification、switch-root
和 agent-plan 请求。

## 发现与后续动作

1. `MediaTupleMismatch` 说明当前 Ubuntu adapter/media detector 不接受该 26.04
   desktop ISO 的 media tuple；需要先补充明确的 26.04 desktop 识别/adapter 契约，
   再重新从 fresh 阶段完整重跑。
2. Rocky 10.2 stage tree 的 `staging kernels` 为空，`auto` 正确 fail-closed；需要
   修复 stage kernel 导入/扫描，或明确由产品支持的 kernel asset 注入流程，再重跑
   `auto` 与真实 PXE。
3. 目标侧 SSH 未建立，需继续检查 VM console/network/agent SSH 配置；在拿到
   `/etc/os-release`、`findmnt /`、hosts、repo、SSH 和 failed-units 证据前，不得将
   本轮总结为 PASS。
4. `tests/cli.sh` 的初始失败根因已定位：archive compression/suffix mismatch 的
   CLI 错误输出为 `internal: InvalidItemUsage`，实际 exit code 为 **1**，而测试契约
   期待输入错误 exit code **2**（`tests/cli.sh:178-181`）。已在 `src/main.zig`
   将 `InvalidItemUsage` 纳入 usage-error 映射；修复后的聚合测试又暴露出独立的
   `config.example.json` validation failure，因此 CLI 绿证据仍未取得，修复后依
   runbook 从 fresh 阶段 1 全量重跑。
5. 将远端旧的 `config.example.json`（schema 4）同步为当前 schema 5 后，配置错误
   消失；聚合测试下一步暴露真实 daemon 占用端口/HTTP harness 隔离问题。停止真实
   daemon 后，`tests/http.sh` 仍未完成绿证据，需单独复现其失败断点，再从 fresh
   阶段重跑。
