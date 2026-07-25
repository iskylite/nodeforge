# v0.2.1 保留项：异架构/实机 diskless 验证矩阵

状态：**保留（reserved）**——v0.2 当前环境不具备执行条件，整体推迟到 v0.2.1。v0.2.1 与 v0.2 范围分离：下列项**不计入 v0.2 完成标准**，v0.2 以已验证的 aarch64 闭环为准；本文件仅作为 v0.2 之后的后续单独闭环入口，当前**暂不验证**。
本文件是 v0.2.1 的唯一入口，记录从 v0.2 推迟的验证项、环境约束、已满足项与闭环路径。
不涉及生产代码或 schema 契约变更；v0.2 实现已冻结，此处仅为验证缺口。

日期：2026-07-24

## 1. 来源与要求

设计总纲 `docs/design/V0_2_DESIGN.md` §9.1（M5 完成标准，第 826–827 行）要求：

> `squashfs_overlay`（v0.2 唯一 rootfs 形态）通过 UEFI x86_64/aarch64 QEMU smoke +
> VMware 虚拟机部署（compute_use）实机代理验证；至少一架构完成断网恢复、switch_root、
> running event 和 retry 闭环，覆盖真机 NIC/firmware/内存差异。

其中“至少一架构完成…闭环”已在 v0.2 由 aarch64 满足（见 §4）。下列两项为尚未执行的
异架构/实机验证，推迟到 v0.2.1。

## 2. 保留项（v0.2.1）

### 2.1 UEFI x86_64 QEMU smoke
- 目标：在 UEFI（OVMF）x86_64 QEMU 中启动 nodeforge initrd + squashfs_overlay rootfs，
  验证跨架构 boot 链路：UEFI 固件、x86_64 内核、跨编译 initrd、squashfs lower/tmpfs upper/overlay/`switch_root`。
- 验收：guest 到达 `switch_root` 后的运行态（initrd 阶段证据或 first-boot 早期证据），
  覆盖真机 firmware（OVMF）/内存差异。x86_64 不要求完整闭环（已由 aarch64 满足 §9.1“至少一架构”）。

### 2.2 VMware（compute_use）实机 diskless 部署验证
- 目标：经 VMware 虚拟机 + compute_use 实机代理，对 diskless 主流程做真机 PXE/DHCP/TFTP/boot-config
  端到端回归，覆盖真机 NIC/firmware，证明 QEMU 之外的真实虚拟化栈行为一致。
- 验收：至少一条 compute_use 驱动的 diskless 启动闭环
  （BootSession → rootfs 传输 → `switch_root` → `diskless.running` event）。

## 3. 当前环境约束（为何 v0.2 不具备）

- **r97n0（验证主机，aarch64 Rocky 9.7）**：`/usr/libexec/qemu-kvm` 仅支持 `virt`/aarch64 机器
  （`-machine help` 无 `pc`/`q35`）；仓库（baseos/appstream/extras/epel）无 `qemu-system-x86_64`，
  亦无 `edk2-ovmf`/OVMF（仅有 `edk2-arm`、`edk2-riscv64`）。无法运行 x86_64 QEMU。
- **macOS 宿主（arm64）**：未安装 QEMU；`nodeforged` 为 Linux-only，不能在宿主直接运行，
  故 x86_64 QEMU 须与 nodeforged 分主机。
- **compute_use**：当前 agent 上下文无 Computer Use/视觉驱动的 VMware 操作能力，
  无法在 macOS 上经 VMware Fusion 自动驱动 diskless PXE 闭环。

## 4. 已在 v0.2 满足（非保留项）

- **aarch64 UEFI QEMU 完整闭环**（`tests/v0_2_qemu_full.sh`，r97n0）：
  断网恢复、squashfs lower/tmpfs upper/overlay、`switch_root`、Rocky 9.7 systemd 启动、
  lifecycle→`diskless.running`、first-boot payload/journal/degraded、capability 越域/撤销、
  daemon 重启恢复、内存不足 fail-closed。满足 §9.1“至少一架构完成闭环”。
- **rootfs-build `--installroot`**（`tests/v0_2_rootfs_build.sh`，r97n0，2026-07-24）：
  package action 以 `dnf --installroot` 在 host 上下文从本地 `file://` 受管源安装
  （不 chroot、不 bind-mount /dev/proc/sys、不回连 daemon），`tree` RPM 烤入 lower 校验；
  managed_file/archive/script 三类步骤烤入校验；二次构建命中缓存 `already_present`。
- **Ubuntu 22.04 aarch64 diskless smoke**（`tests/v0_2_ubuntu_qemu_smoke.sh`，r97n0，2026-07-25）：复用 ISO casper squashfs 作为 diskless lower，验证 diskless 启动主循环 + first-boot 在 Ubuntu 用户态下正确（`switch_root` -> `nodeApply` -> `diskless.running`，first-boot 0 失败）。详见 `V0_2_PHASE8_VALIDATION.md`。注意：Ubuntu OS 层 rootfs-build（apt/debootstrap）在 v0.2 仍不支持（`AptOsLayerUnsupported`），属 v0.2.1 功能项，非本验证矩阵保留项。
- **传输故障负测**（`tests/v0_2_transfer_fault.sh`，r97n0）：clean / ETag 漂移 / 内容损坏 / 断流
  四场景均 fail-closed。
- **单元测试**：本机 `zig build test` = 345/345 通过（11/11 build steps succeeded）。

## 5. v0.2.1 闭环路径

满足 §2.1 与 §2.2 各一条，可任选实现路径：

- **路径 A（x86_64 QEMU smoke）**：在具备 `qemu-system-x86_64`+OVMF 的主机上，
  以 `dnf --installroot --forcearch=x86_64` 从本地 x86_64 ISO 构建 x86_64 rootfs，
  `zig build -Dtarget=x86_64-linux` 跨编译 initrd/agent，OVMF UEFI 启动 smoke。
  可行拆分：r97n0 跑 nodeforged 服务 x86_64 catalog（只发文件，host 架构无关），
  macOS `brew install qemu` 跑 UEFI guest 经 LAN 回连 r97n0。
  本地可用的 x86_64 ISO：`/Users/iskylite/Downloads/ISO/Rocky-9.7-x86_64-dvd.iso`。
- **路径 B（compute_use/VMware）**：在 VMware Fusion + Computer Use 可用的环境，
  驱动 UEFI VM 经 nodeforged 的 PXE/DHCP/TFTP 完成 diskless 启动闭环（覆盖真机 NIC/firmware）。

完成后将证据回填本文件并在 `V0_2_PHASE8_VALIDATION.md` 勾选对应条目。
