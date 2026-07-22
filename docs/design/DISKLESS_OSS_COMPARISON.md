# NodeForge 无盘方案开源情报对比

状态：非规范性参考资料。本文调研主流开源 diskless/stateless 方案，对照 NodeForge v0.2 约束给出选型依据，
是 [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §3 的完整版。最终方案见 [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md)，
版本边界见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md)。

本文只解释“为什么这样选”，不定义产品行为；出现差异时以总纲和对应设计分册为准。

## 1. 调研范围与 NodeForge 约束

NodeForge v0.2 的 diskless 必须满足以下硬约束（均来自 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §7 与
[`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §7）：

- **local-only**：rootfs/initrd 恒离线，移除公网 mirror/metalink/GeoIP/vendor NTP，只引用本地 repository。
- **IPv4-only**：DHCPv4/TFTP/HTTP，IPv6 是永久非目标。
- **单进程内置协议栈**：DHCPv4/TFTP/HTTP 由 `nodeforged` 内置，不引入第二引导栈。
- **per-Node 差异不烤入共享 rootfs**：差异经 BootConfig 落 overlay upper。
- **切根后独立运行**：rootfs 下载到本地内存后离线切根，不依赖网络常驻。
- **VMware 可验证**：主流程须在 VMware 可复现。

## 2. 开源无盘方案分类

| 类别 | 代表项目 | rootfs 来源 | 是否离线切根 | 引入第二引导栈 |
|---|---|---|---|---|
| NFS root | LTSP、DRBL、Edubuntu | NFS 共享目录 | 否（网络常驻） | 否 |
| 块设备 diskless | iSCSI/AoE/NBD + xCAT/warewulf | iSCSI/AoE/NBD 块 | 否（网络块常驻） | 取决于实现 |
| iPXE 脚本引导 | iPXE chain/script | HTTP/NFS/iSCSI | 取决于脚本 | 是（iPXE 引导栈） |
| HTTP-delivered 镜像 | Warewulf stateless、xCAT stateless、Fedora livemedia | HTTP 下载镜像到内存 | 是 | 否（dracut/标准 initrd） |
| 容器/镜像 stateless | CoreOS/Flatcar ignition | PXE + ignition | 是 | 否 |
| 原生 dracut diskless | dracut network module + squashfs/overlay | HTTP 下载到内存 | 是 | 否 |

## 3. 逐项对比

### 3.1 NFS root（LTSP/DRBL）

- **机制**：kernel `root=/dev/nfs` + `nfsroot=`，rootfs 留在 NFS 服务端，节点挂载网络根。
- **优点**：内存占用极低，多节点共享单一份。
- **否决理由**：违背 local-only（依赖网络常驻，网络抖动即整机不可用）；NFS 服务端单点；与“切根后独立运行”
  目标冲突。NodeForge rootfs 必须能下载到本地内存后离线切根。
- **结论**：排除（任何形态）。

### 3.2 iSCSI/AoE/NBD 块设备 diskless

- **机制**：网络块设备作为根盘，节点像本地盘一样读写。
- **否决理由**：仍是网络常驻根，违背离线切根；引入 iSCSI initiator/AoE/NBD 客户端与额外服务端栈；
  stateless 写语义需额外持久化设计（NodeForge v0.2 明确不提供持久化 overlay）。
- **结论**：排除。

### 3.3 iPXE 脚本/链式引导

- **机制**：iPXE 作为网络引导固件，执行脚本拉取 kernel/initrd 或 chainload。
- **优点**：脚本化引导流程灵活，支持 HTTP/NFS/iSCSI 多源。
- **否决理由**：引入第二引导栈（iPXE），增加 BIOS/UEFI 兼容与维护负担；v0.2 用 GRUB + 标准 PXELINUX
  DHCP/TFTP 已足够；iPXE 菜单/脚本属永久非目标（[`V0_2_DESIGN.md`](V0_2_DESIGN.md) §7）。
- **结论**：排除。

### 3.4 HTTP-delivered 镜像到内存（Warewulf/xFedora livemedia）

- **机制**：标准 PXE 引导 kernel + initrd，initrd 经 HTTP 下载 rootfs 镜像到内存，loop 挂载或解压切根。
- **优点**：离线切根、local-only 兼容、单进程协议栈（DHCP/TFTP/HTTP）、per-Node 差异可经 cmdline/配置
  覆盖。Fedora/RHEL 的 lorax/livecd-creator 与 Ubuntu 的 debootstrap/live-build 提供成熟镜像构建工具。
- **子方案对比**：
  - **squashfs + overlay tmpfs**：lower 为压缩 squashfs（loop 只读），upper 为 tmpfs。内存占用中、
    lower 跨 Node 共享、overlayfs 原生。**NodeForge v0.2 采纳**。
  - **ram_rootfs（全内存）**：整 rootfs 解压进内存。内存占用高、需预算校验、不可共享 lower。**v0.5 单独项**
    （[`V0_5_DESIGN.md`](V0_5_DESIGN.md)）。
- **结论**：squashfs_overlay 为 v0.2 唯一形态。

### 3.5 容器/镜像 stateless（CoreOS ignition）

- **机制**：PXE 引导最小 OS 镜像，ignition 配置在 initrd 阶段注入。
- **参考价值**：ignition 的“配置不烤入镜像、boot 时注入”理念与 NodeForge BootConfig 一致
  （per-boot/per-Node DTO 经 initrd 拉取并交接，由最终 rootfs 的 agent pre-init 将差异落 overlay upper）。但 CoreOS 是不可变专用 OS，NodeForge 需要
  通用发行版（Rocky/Ubuntu）rootfs，故只借鉴理念、不采用其 OS 与 ignition 格式。
- **结论**：理念借鉴，不采用。

### 3.6 构建工具

| 发行版系 | 工具 | NodeForge 用途 |
|---|---|---|
| RHEL/Rocky | lorax/livecd-creator/mkksiso | 构建 OS 层 squashfs lower |
| Ubuntu/Debian | debootstrap/live-build | 构建 OS 层 squashfs lower |

builder 消费与 Profile 查询相同的 environment/group/task/package selection，按 local-only 移除公网源
（[`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §4）。

## 4. 约束匹配矩阵

| 约束 | NFS root | iSCSI/AoE | iPXE | squashfs_overlay(本文) | ram_rootfs(v0.5) |
|---|---|---|---|---|---|
| local-only 离线切根 | ✗ | ✗ | 部分 | ✓ | ✓ |
| IPv4 单进程协议栈 | ✓ | ✗(额外栈) | ✗(第二引导栈) | ✓ | ✓ |
| per-Node 差异落 overlay | N/A | 需额外设计 | 脚本 | ✓ | ✓ |
| 共享 rootfs lower | ✓(NFS 单份) | 部分 | 取决 | ✓ | ✗(各节点解压) |
| VMware 可验证 | ✓ | 难 | 难 | ✓ | ✓(需大内存) |
| 内存占用 | 极低 | 低 | 低 | 中 | 高 |
| 持久化 overlay 需求 | N/A | 需 | N/A | 不提供(非目标) | 不提供(非目标) |

## 5. 选型结论

v0.2 固定 **squashfs_overlay + 标准 dracut initrd + HTTP 下载 + BootConfig per-Node 注入**：

1. 满足全部硬约束（local-only、IPv4 单进程、离线切根、共享 lower + per-Node upper）。
2. rootfs 经 HTTP GET/HEAD/Range 下载、sha512 校验、loop 挂载，复用 `nodeforged` 内置 HTTP。
3. per-Node 差异经 BootConfig（per-boot、per-Node 短时 DTO）落 overlay upper，rootfs lower 按 effective
   digest 跨 Node 共享。
4. 借鉴 CoreOS ignition “配置 boot 时注入”理念，但用通用发行版 rootfs + NodeForge BootConfig 实现。
5. 内存占用适中、VMware 可验证；`ram_rootfs` 全内存模式作为 v0.5 可选项
   （[`V0_5_DESIGN.md`](V0_5_DESIGN.md)），与 squashfs_overlay 共享 BootConfig/initrd/agent/协议栈，仅
   rootfs 物化不同。

## 6. 对 NodeForge 设计的影响

- **不引入** NFS server、iSCSI target、iPXE 二进制或第二引导栈。
- **复用** `nodeforged` 内置 DHCP/TFTP/HTTP；rootfs 路由为 node-bound GET/HEAD/Range。
- **构建** OS 层用发行版原生工具（lorax/debootstrap），rootfs-build phase 在其上追加业务内容。
- **initrd** 用 dracut 注入 `nodeforge-initrd` 引导程序（[`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md)）。
- **形态切换** 延后 v0.5（`diskless.overlay.mode`），v0.2 不提供 mode 字段（单值无选择意义）。
