# NodeForge 无盘系统最终方案（v0.2 收敛）

状态：设计收敛基线。本文是 v0.2 diskless 主流程的事实源，与
[`V0_2_DESIGN.md`](V0_2_DESIGN.md) 一致；实现细节见
[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md)，程序边界见
[`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md)，CLI 见
[`V0_2_CLI.md`](V0_2_CLI.md)。v0.5 的可切换 rootfs 形态见
[`V0_5_DESIGN.md`](V0_5_DESIGN.md)。

## 1. 设计目标与排除项

v0.2 的 diskless 只交付一条主流程：**节点经 PXE 引导 → 拉取共享 rootfs →
内存 overlay 切根 → 切根后 agent 顺序执行一次性 first-boot 后处理**。目标是让
diskless 主流程完备可用，不追求 VMware 无法验证或非主流程的增强。

明确排除（详见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §7）：

- NFS root（任何形态）、iPXE 菜单/脚本。
- 可切换 rootfs 形态（`ram_rootfs` 全内存、`diskless.overlay.mode` 字段）→ v0.5。
- 多 NIC/VLAN/bonding、PXE 阶段纯静态、下载后切换地址/子网 → v0.4。
- 远程/节点上构建 rootfs（agent 驱动）→ v0.4。
- 持久化 overlay、跨重启 rootfs partial、稳定无盘 SSH host identity → 非目标。
- reconciliation/远程控制、enrollment/credential → 永久非目标。

## 2. 选型结论：squashfs_overlay

经开源情报对比（见 §3），v0.2 固定 **`squashfs_overlay`** 为唯一 rootfs 形态：

```text
squashfs_overlay = squashfs 只读 lower + tmpfs overlay upper
```

- **lower**：squashfs 单文件镜像，由服务端 rootfs builder 构建，按 effective digest 缓存、
  跨 Node 共享，经 HTTP GET/HEAD/Range 下载、sha512 校验、loop 挂载为只读。
- **upper**：tmpfs 写入层，per-boot 易失。initrd 在 `switch_root` 前写入 target-system 投影
  与 first-boot 业务输出；切根后 agent 继续写 overlay upper。

选择理由：

1. 内存占用低于全内存 `ram_rootfs`（只读层是压缩 squashfs，不必把整个 rootfs 解压进
   内存），VMware 与实机均可验证。
2. 共享 lower + per-Node 差异落 upper 的模型天然契合 BootConfig “动态参数不烤入 lower”
   的不变式（见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §4.3）。
3. 读写覆盖语义成熟（overlayfs），无需自研联合挂载。

## 3. 开源情报对比

| 方案 | 内存占用 | 共享性 | 复杂度 | v0.2 结论 |
|---|---|---|---|---|
| **squashfs + overlay tmpfs**（本文） | 中（压缩 lower + 写时 upper） | lower 跨 Node 共享 | 低，overlayfs 原生 | **采纳** |
| `ram_rootfs` 全内存 rootfs | 高（整 rootfs 解压进内存，需预算校验） | 不可共享 lower | 中 | v0.5 单独项 |
| NFS root | 低（rootfs 留服务端） | 服务端单点、依赖网络常驻 | 低但违背离线/local-only | 排除 |
| iPXE 菜单/脚本引导 | 不提供 rootfs 形态 | — | 引入第二引导栈 | 排除 |

NFS root 被 local-only 不变式（公网 mirror/metalink 必须移除）与“切根后独立运行”目标共同
否决；rootfs 必须能下载到本地内存后离线切根。iPXE 引入额外引导栈与 BIOS/UEFI 兼容负担，
v0.2 用 GRUB + 标准 PXELINUX DHCP/TFTP 已足够。

## 4. 共享 rootfs 构建模型

取消 variant / 暴露的 base rootfs 两层概念，收敛为**单一共享 rootfs**：

```text
rootfs = OS 层 + rootfs-build phase 业务内容 + Profile target-system 骨架
```

- **OS 层**：从 pinned install source/repository capability 用发行版原生工具构建
  （RHEL 系 lorax/livecd-creator/mkksiso；Ubuntu debootstrap/live-build），在与目标
  distro/version/arch/`kernel_release` 一致的环境中运行。builder 消费与 Profile 查询相同
  的 environment/group/task/package selection，按 local-only 移除公网 mirror/metalink/
  GeoIP/vendor NTP，只引用本地 repository。OS 层可按 software capability revision 内部
  缓存复用，但对设计透明、不作为独立 Resource。
- **rootfs-build phase**：在 OS 层之上向只读 lower 追加业务内容（managed-file、archive、
  受控 script、经本地 repo 解析的 package）。由服务端 rootfs builder 执行（无节点 agent），
  builder 提供 chroot/staging 上下文使步骤以 `/` 为目标写入 lower。
- **effective digest**：OS 层 + rootfs-build phase + Profile 骨架 + effective system/software
  + builder version 共同决定 rootfs 的 effective digest；rootfs 按 digest 缓存、跨 Node 共享。

**构建环境保真**：纯 userspace 动作只需 chroot；触及硬件/内核的动作（装驱动、dkms、重生成
initramfs、装载内核模块）须 bind-mount `/dev`/`/proc`/`/sys` 并使用与目标 distro/version/arch/
`kernel_release` 一致的内核（内核与 OS 一致时加载完整内核态）。更高保真的远程/节点上构建
延后 v0.4。详见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §4.4。

## 5. BootConfig 与启动时序

BootConfig 是 **per-boot、per-Node 的短时 DTO**，由服务端按 pinned DisklessEffectivePlan 在
boot 时生成，initrd 经 node-bound capability 拉取。它只携带动态/按节点参数，**不烤入 rootfs
lower**，故 lower 可共享、per-Node 差异只落 overlay upper。

启动时序（`switch_root` 前由 initrd 完成）：

1. DHCP/TFTP 引导 boot bundle（kernel + NodeForge initrd），kernel cmdline 携带
   `nodeforge.config_url` 与 `kernel_args`。
2. initrd 起后从 `config_url` 拉 BootConfig（per-Node capability、短有效期 token）。
3. initrd 把 target-system 投影写 overlay upper（NM/Netplan 网络、hostname、
   `/etc/shadow` `$6$` hash、authorized_keys、machine-id、SSH host key），并下载/校验/
   挂载 rootfs lower。
4. `switch_root` 后 NM/Netplan 接管网络，agent 开机顺序执行 `first-boot` 后处理。

BootConfig 除 `$6$` password hash 与 public authorized key 外不含长期 secret；token 绑定
node、session、HTTP method/path 与短有效期，仅授权该 Node 的 GET/HEAD/Range config/rootfs 与
event POST，不能访问其他 Node rootfs、不能升级为 management credential。`/run/nodeforge/
boot.json` 只保存 plan/config digest 与非 secret 摘要，mode 0600。initrd 在 `switch_root` 前
清零 token。BootConfig DTO 自身 `schema_version` v2（与 catalog schema v3/v4 分属不同命名空间），
使用 `kind` 判别字段（与 `ProfileKind` 一致），废弃 legacy `mode="diskless"`。

`required_features` 至少枚举稳定 token：`target-system-v1`、`static-network-v1`、
`sha512-crypt-v1`、`bootstrap-admin-key-v1`、`target-accounts-v1`；initrd 在 boot bundle manifest
中声明支持的 feature 子集，缺失或冲突在 `switch_root` 前以稳定 error code 拒绝，不得回退降级。

## 6. 切根后 first-boot 后处理

切根后由 node-bound agent（`nodeforge-agent`，见 [`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md)）
开机顺序执行 `first-boot` 后处理：

- **一次性**：每次开机执行一次（overlay upper 为 tmpfs、per-boot 易失），非“跨重启只跑一次”，
  也非 `runtime` 周期。
- **固定顺序**：文件更新 -> package -> archive -> script（八步执行契约见
  [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §5.2）。
- **确定性 + 幂等**：幂等键 `(bundle revision, effective digest, node, phase, idempotency key)`
  使已成功 step 重跑时 no-op；retryable 失败 step 在当次开机内按 step 声明重试，耗尽标 failed
  （节点仍启动、该 step 失败）。
- **状态/异常回传**：经 `event_url` best-effort 回传（带 `node_id`），失败本地兜底
  （日志/console/boot.json），不阻塞执行、不回退已完成切根。
- **无远程控制/无 reconciliation**：agent 不接受远程任务下发、不做 drift 重跑。重新触发完整
  first-boot = 重启节点重新 PXE 引导；`node diskless retry` 清 boot-level quarantine 以允许
  重新 PXE，不改 Profile、不远程重启。

## 7. local-only 不变式

v0.1 删除 `system.connectivity.mode`（曾取值 `local-only`），因 `local-only` 是唯一行为、无选择
意义。v0.2 承袭为不变式：

- rootfs/initrd 恒 `local-only`：移除/禁用公网 mirror、metalink、GeoIP、vendor NTP，只引用本地
  repository；不新增 `local-only` PropertySpec，不存在 online 变体。
- v0.2 的 HTTP bearer 只在隔离 `local-only` 网络内提供认证，不提供链路机密性；跨不可信网络的
  TLS/mTLS 与远程管理仍是非目标，部署必须以隔离 VLAN/ACL 防止旁路窃听。

## 8. 验收不变式

- v0.2 不存在 NFS root、iPXE、`diskless.overlay.mode` 字段、`ram_rootfs` 路径或其 help/enum。
- rootfs lower 按 effective digest 跨 Node 共享；per-Node 差异只经 BootConfig 落 overlay upper。
- `switch_root` 前 initrd 完成 target-system 投影写入（网络由 NM/Netplan 接管同一地址）。
- 切根后 agent 开机顺序执行 first-boot，固定顺序、一次性、确定性+幂等，无远程控制/reconciliation。
- 完整或重复 hash mismatch、feature mismatch、过期 token、越权 Range、switch_root 失败都进入稳定
  error code、`diskless.failed` 和 quarantine。
