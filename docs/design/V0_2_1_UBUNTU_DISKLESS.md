# v0.2.1 设计：Ubuntu Casper Squashfs Diskless

状态：**设计草案**。本文是 v0.2.1 的唯一设计入口，负责版本边界、方案选型、风险分析和实现范围。
总纲与跨版本不变式以 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) 为准；本文不重复 v0.2 已冻结的架构、
程序边界和 CLI 契约，只定义 v0.2.1 新增的 Ubuntu diskless 能力及其与 v0.2 的差异。

日期：2026-07-25

## 0. 版本定位

| 版本 | 范围 | 状态 |
|---|---|---|
| v0.2 | Rocky/RHEL diskless（`dnf --installroot` OS 层 + squashfs overlay） | 设计冻结，已验证 |
| **v0.2.1** | **Ubuntu diskless（casper squashfs 叠加方案 + 跨发行版宿主支持）** | **本文** |
| v0.2.2 | 异架构/实机 diskless 验证矩阵（原 v0.2.1 保留项） | 保留 |
| v0.3 | PXELINUX/BIOS install | 设计阶段 |

v0.2.1 是 v0.2 的**增量补充**，不修改 v0.2 的 schema、catalog、BootSession 或 rootfs overlay 架构。
它只新增 Ubuntu 作为 diskless 目标发行版的能力，并使该能力在 Rocky/RHEL 宿主机上可用。

## 1. 问题陈述

v0.2 的 diskless 已验证 Rocky 9.7 aarch64 闭环（`dnf --installroot` → squashfs → QEMU smoke），
但 Ubuntu diskless 存在以下 gap：

1. **OS 层构建不支持**：`rootfs_os_builder.zig` 对 apt 返回 `AptOsLayerUnsupported`；
   `first_boot.zig` apt 分支未实现 `installroot` 跨根安装。
2. **跨发行版宿主限制**：`apt-get`/`dpkg`/`debootstrap` 在 Rocky/RHEL 宿主机上不可用，
   无法在 Rocky 宿主机上用原生 apt 工具链构建 Ubuntu rootfs。
3. **Ubuntu ISO 资源未利用**：Ubuntu live-server ISO 的 casper squashfs 已包含完整的
   可引导 rootfs（含 openssh-server、systemd、/sbin/init），但 v0.2 未提供利用路径。

## 2. 方案选型：Casper Squashfs 叠加

### 2.1 核心思路

利用 Ubuntu live-server ISO 的 casper 分层 squashfs 作为 diskless rootfs lower 层，
替代从零用 apt/debootstrap 构建 OS 层。这与 casper 的原生 overlay 行为等价：
casper initrd 在原生 Ubuntu live boot 中就是将多层 squashfs 作为 overlay lowerdir 叠加。

### 2.2 Casper 分层 squashfs 结构

Ubuntu live-server ISO 使用 Canonical 官方的分层 squashfs 设计（casper manpage `layerfs-path=` 参数，
从 20.04 起在所有 LTS 中稳定记录）：

| 层 | 文件名 | 内容 |
|---|---|---|
| base | `casper/ubuntu-server-minimal.squashfs` | systemd/bash/apt（**无 sshd、无 /sbin/init**） |
| server | `casper/ubuntu-server-minimal.ubuntu-server.squashfs` | apt-utils/cloud-init 等 server 包 |
| installer | `casper/ubuntu-server-minimal.ubuntu-server.installer.squashfs` | **openssh-server + /sbin/init symlink + Subiquity** |

casper 通过解析 dotted 文件名递归推导所有父层，将三层 squashfs 作为 overlay lowerdir 叠加。
三层组合才提供完整的可引导 rootfs。

### 2.3 NodeForge 复现方式

#### 2.3.1 rootfs 构建

NodeForge 用 `nodeforge-initrd` 实现等价的 squashfs 叠加：

```text
1. unsquashfs -d <staging> <iso>/casper/ubuntu-server-minimal.squashfs
2. unsquashfs -d <staging> -f <iso>/casper/...ubuntu-server.squashfs  || true
3. unsquashfs -d <staging> -f <iso>/casper/...installer.squashfs     || true
4. 注入 nodeforge-agent + firstboot.service
5. mksquashfs <staging> <rootfs.squashfs> -noappend -comp zstd
```

`|| true` 处理叠加层的设备节点冲突（如 `lxd-installer` char device）——这是非致命错误，
文件内容正确写入。

#### 2.3.2 initrd 构建：复用 casper initrd（关键设计修正）

**重要**：Ubuntu casper squashfs **不包含内核模块**——`/lib/modules/` 为空目录。
内核模块（2222 个 `.ko`）仅存在于 ISO 的 `/casper/initrd` 中。
这是 Canonical 的设计：casper initrd 负责引导期模块加载，rootfs 只负责用户态。

因此，initrd **不能**从 rootfs 构建（rootfs 无 `/lib/modules/`），也**不应**用宿主机
dracut 构建（vermagic 不匹配 Ubuntu 内核）。正确做法是**直接复用 casper initrd**：

```text
1. zstd -d <iso>/casper/initrd -o initrd.cpio     # 解压（casper initrd 是 zstd 格式）
2. mkdir initrd-root && cd initrd-root
3. cat ../initrd.cpio | cpio -idmv                   # 提取 cpio 镜像
4. install -m 0755 nodeforge-initrd ./usr/sbin/     # 注入二进制
4a. 从 rootfs 复制 curl 及其依赖库到 initrd            # casper initrd 缺少 curl
4b. 设置 LD_LIBRARY_PATH 或运行 ldconfig             # 确保 curl 能找到 libcurl
5. cat > ./init << 'EOF'                              # 替换 /init 脚本
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_LIBRARY_PATH=/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:/lib64
[ -d /dev ] || mkdir -m 0755 /dev
[ -d /sys ] || mkdir /sys
[ -d /proc ] || mkdir /proc
[ -d /tmp ] || mkdir /tmp
for m in loop squashfs overlay virtio virtio_pci virtio_net; do modprobe "$m" 2>/dev/null; done
# ... 网络配置 ...
exec /usr/sbin/nodeforge-initrd
EOF
6. find . | cpio -o -H newc | gzip -9 > initrd.img    # 重新打包（gzip 格式）
```

**关键注意事项**（实测发现，见 §8.4）：
- casper initrd **缺少 `curl`**：nodeforge-initrd 调用 `curl` 拉取 BootConfig，
  但 casper initrd 只有 `wget`。必须从 Ubuntu rootfs 复制 curl 及其依赖库。
- 库文件复制必须用 `cp -L`（解引用符号链接）：`libcurl.so.4` 是指向 `libcurl.so.4.7.0`
  的符号链接，`cp -a` 只复制链接而非实际文件。
- casper initrd **没有 `ldconfig`**：无法重建 `ld.so.cache`，需在 `/init` 中设置
  `LD_LIBRARY_PATH` 或从 rootfs 复制 `ldconfig`。
- `/init` 脚本**不能预挂载 proc/sys/dev**：nodeforge-initrd 的 `mustRun("mount", ...)`
  在已挂载时返回 `EBUSY`，导致 `SubprocessFailed` panic。`/init` 只创建挂载点目录，
  由 nodeforge-initrd 自己执行 mount。
- 打包格式用 **gzip** 而非 zstd：`gzip -9` 兼容性更好，QEMU 内核可直接解压。

casper initrd 已包含引导所需的一切：
- 2222 个 `.ko`（vermagic `5.15.0-119-generic`，与 `/casper/vmlinuz` 完全匹配）
- `wget`、`busybox`、`ip`、`modprobe`、`switch_root`、`mount` 等用户态工具

**这彻底消除了 R2（initrd 模块不匹配）风险**——initrd 和 kernel 都来自同一个 ISO。

#### 2.3.3 能否从 rootfs 构建 initrd？

**可以**——已通过 QEMU 验证（见 §9 对比分析）。但需要额外步骤且存在多个问题：

1. `chroot rootfs apt install linux-image-generic`（填充 `/lib/modules/<KREL>/`）
2. `chroot rootfs mkinitramfs -o initrd.img <KREL>`
3. 从 rootfs 提取 `vmlinuz-<KREL>`
4. **必须后清理**：从 rootfs 删除 `/lib/modules/`、`/lib/firmware/`、`/boot/*`
   （否则 rootfs 从 948MB 膨胀到 1.3GB，触发 InsufficientMemory）
5. 重新 `mksquashfs` 打包 rootfs

**实测发现的 3 个关键问题**（详见 §9.3）：
- **内核版本漂移**：apt 安装 5.15.0-186-generic，而非 ISO 的 5.15.0-119-generic
- **rootfs 膨胀 1.6GB**：需后清理 `/lib/firmware/`（1.1GB）+ `/lib/modules/`（470MB）+ `/boot/`（101MB）
- **mkinitramfs 缺少 modprobe**：casper initrd 有，mkinitramfs 没有，需额外注入

**v0.2.1 采用 casper initrd 复用方案**（方案 A），理由见 §9.5 结论。
从 rootfs 构建 initrd 的路径保留为未来优化选项（方案 B）。

### 2.4 为什么不用 debootstrap/apt

| 方面 | casper squashfs 叠加 | debootstrap + apt |
|---|---|---|
| 宿主机要求 | 仅需 `squashfs-tools`（任何 Linux） | 必须是 Ubuntu/Debian 宿主机 |
| apt 跨根安装 | 不需要 | 需实现 apt `installroot` 等价机制（当前缺失） |
| rootfs 保真度 | ISO 官方构建，与安装后系统一致 | 需手工配置，易遗漏包 |
| rootfs-build phase | 在叠加后的 rootfs 上追加业务内容 | 同左 |
| 已验证 | ✅ QEMU smoke 通过 | ❌ `AptOsLayerUnsupported` |

debootstrap/apt 方案保留为未来选项（v0.3+ 可考虑），但 v0.2.1 明确采用 casper squashfs 叠加。

## 3. 跨发行版宿主支持

### 3.1 设计目标

在 Rocky/RHEL 宿主机上完整构建和部署 Ubuntu diskless 节点，不要求宿主机是 Ubuntu。

### 3.2 宿主机工具链要求

| 工具 | 用途 | Rocky/RHEL 可用性 |
|---|---|---|
| `squashfs-tools`（unsquashfs/mksquashfs） | 解压/打包 squashfs | ✅ EPEL 提供 |
| `cpio` | 打包 initramfs cpio 镜像 | ✅ 系统自带 |
| `zstd` | 解压/压缩 casper initrd | ✅ 系统自带 |
| `python3` | catalog 注入 | ✅ 系统自带 |
| `mount` + `losetup` | 挂载 ISO | ✅ 系统自带 |
| `zig` 0.16+ | 编译二进制 | ✅ 静态安装 |
| `qemu-kvm` | 验证启动 | ✅ 系统自带 |

**无需 `apt-get`/`dpkg`/`debootstrap`/`dracut`。** 已在 r97n0（Rocky 9.8）上实测验证全部可用。

注意：`dracut` **不再是 Ubuntu diskless initrd 构建的必需工具**。dracut 仅在 Rocky diskless
（v0.2）路径中使用。Ubuntu diskless 直接复用 ISO 自带的 casper initrd（§2.3.2）。

### 3.3 产物构建链

全部产物在 Rocky/RHEL 宿主机上制作：

```text
1. Zig 二进制（nodeforged/nodeforge/nodeforge-initrd/nodeforge-agent）
   ← zig build（静态链接，架构原生编译或交叉编译）

2. rootfs.squashfs
   ← mount ISO → unsquashfs 3 层 → 注入 agent/service → mksquashfs
   ← 仅需 squashfs-tools + mount
   ← 注意：rootfs 的 /lib/modules/ 为空，内核模块不在 rootfs 中

3. initramfs.img（含 nodeforge-initrd + 5.15.0-119-generic .ko）
   ← zstd 解压 ISO 的 /casper/initrd → cpio 提取 → 注入 nodeforge-initrd → 替换 /init → cpio+zstd 重新打包
   ← 仅需 zstd + cpio
   ← .ko vermagic 与 /casper/vmlinuz 完全匹配（同源 ISO）

4. 内核（vmlinuz）
   ← 从 Ubuntu ISO /casper/vmlinuz 提取（gzip 压缩的 EFI signed kernel）
   ← QEMU -kernel 可直接加载
```

**关键差异 vs Rocky diskless（v0.2）**：
- Rocky diskless：initrd 由宿主机 dracut 生成（复制宿主机 `/lib/modules/` 的 .ko）
- Ubuntu diskless：initrd 从 ISO 的 casper initrd 提取（复制 Ubuntu `/lib/modules/` 的 .ko）
- 两者都确保 initrd .ko 与 boot kernel 的 vermagic 一致，但来源不同

## 4. 内核依赖全景分析

### 4.1 整个 diskless 流程的内核依赖图

NodeForge diskless 流程分为 5 个阶段，各阶段对内核的依赖如下：

| 阶段 | 是否依赖内核 | 依赖内容 | 说明 |
|---|---|---|---|
| **① OS 层构建（casper squashfs 叠加）** | ❌ 不依赖 | — | `unsquashfs`/`mksquashfs` 是纯用户态工具，不接触内核 |
| **② rootfs-build phase** | ⚠️ 条件依赖 | DKMS/kernel-modules/initramfs 重生成类包 | 纯 userspace 包不依赖；内核相关包需要匹配的 kernel-headers 和构建内核 |
| **③ initrd 阶段（nodeforge-initrd 运行）** | ✅ **依赖** | `.ko` 模块必须与 boot kernel 版本匹配 | `.ko` 来自 casper initrd（与 `/casper/vmlinuz` 同源 ISO），vermagic 完全匹配 |
| **④ switch_root** | ❌ 不依赖 | — | 纯 `execve` 系统调用，任何内核都支持 |
| **⑤ 切根后运行期** | ❌ 不依赖 | — | systemd/bash/sshd 等 userspace 不依赖特定内核版本 |

**结论**：initrd 阶段的 .ko 模块与 boot kernel 同源（casper initrd + casper vmlinuz 来自同一 ISO），
不存在 vermagic 不匹配风险。唯一残留的内核依赖是 rootfs-build phase 的内核相关包（R1）。

### 4.2 风险 R1：rootfs-build 阶段内核相关包（中）

**描述**：rootfs-build phase 的 `package` action 如果安装内核相关包（DKMS 驱动、
`kernel-modules`、initramfs 重生成），需要匹配的 `kernel-headers`/`kernel-devel` 和构建内核。
在非 Ubuntu 宿主机上，这些包的内核版本与目标 Ubuntu 内核不匹配。

**影响范围**：
- DKMS 类包（如 `*-dkms`、`nvidia-driver`、`zfs-dkms`）：编译失败——DKMS 需要为目标内核编译 .ko。
- `kernel-devel`/`kernel-headers` 依赖的包：找不到匹配版本。
- initramfs 重生成类步骤：rootfs 的 `/lib/modules/` 为空（casper squashfs 不含内核模块），
  `mkinitramfs`/`update-initramfs` 在 chroot 中会因找不到模块而失败。需先安装 `linux-image-generic`。

**不影响**：
- 纯 userspace 包（openssh-server、curl、vim 等）——不依赖内核。
- managed-file/archive/script 步骤——只写文件。
- casper squashfs 叠加产出的 OS 层本身——已由 Canonical 在匹配内核下构建。

**处理方式：风险提示，不锁死**

v0.2.1 **不限制** rootfs-build phase 只能安装 userspace 包。而是：
1. **CLI 风险提示**：当检测到 Ubuntu diskless profile 在非 Ubuntu 宿主机上构建 rootfs，
   且 rootfs-build phase 包含内核相关包名模式（`*-dkms`、`kernel-*`、`kmod`、`dkms`）时，
   输出明确警告（见 §5），但不阻断执行。
2. **由用户决定**：用户可以自行承担风险继续执行，或在 Ubuntu 宿主机上构建以消除风险。
3. **Ubuntu 宿主机消除风险**：如果宿主机是 Ubuntu（与目标版本一致），
   则 kernel-headers/内核版本完全匹配，DKMS 等内核相关包可正常编译。
   这是推荐的生产环境配置。
4. **未来路径**：内核相关包构建也可通过 v0.4 的临时 PXE rootfs 构建节点
   （在真实 Ubuntu 内核态下构建）解决。

### 4.3 风险 R2：initrd 内核模块来源与匹配（已消除）

> **本风险已通过设计修正消除。** 原方案使用宿主机 dracut 构建 initrd，
> 导致 .ko vermagic 与 Ubuntu kernel 不匹配。修正后直接复用 Ubuntu ISO 的
casper initrd，.ko 与 kernel 同源，vermagic 完全匹配。

**原风险描述（已作废）**：使用 Rocky 宿主机 dracut 构建 initrd，
会从 Rocky 的 `/lib/modules/5.14.0-611.el9/` 复制 .ko，vermagic 与 Ubuntu 5.15.0-119-generic
不匹配，modprobe 会拒绝加载 squashfs/overlay/loop 模块。

**修正后的正确方案**（§2.3.2）：

| boot kernel | initrd 来源 | .ko vermagic | modprobe 结果 | 状态 |
|---|---|---|---|---|
| Ubuntu 5.15.0-119-generic | **casper initrd（ISO 同源）** | 5.15.0-119-generic | ✅ 完全匹配 | **推荐** |
| Rocky 5.14.0-611 | Rocky dracut（5.14.0-611 .ko） | 5.14.0-611.el9 | ✅ 匹配 | 仅适用 Rocky diskless |

**验证证据**（r97n0 实测）：
```text
# Ubuntu casper initrd 内容
file /mnt/casper/initrd
  → Zstandard compressed data (v0.8+), Dictionary ID: None

# 解压后 .ko 统计
find . -name '*.ko*' | wc -l
  → 2222 个 .ko 文件

# 内核版本
ls ./usr/lib/modules/
  → 5.15.0-119-generic

# 关键模块
find . -name 'squashfs.ko*' -o -name 'overlay.ko*'
  → ./usr/lib/modules/5.15.0-119-generic/kernel/fs/overlayfs/overlay.ko

# 用户态工具
wget ✓  busybox ✓  ip ✓  modprobe ✓  switch_root ✓  mount ✓
```

**残留注意点**：
- casper initrd 的 `/init` 脚本是 casper 专用的 live-boot 逻辑，必须替换为
  nodeforge-initrd 的引导流程（§2.3.2 步骤 5）。
- casper initrd 体积较大（349MB 解压后），最终打包的 initrd.img 应保持 zstd 压缩。

### 4.4 风险 R3：casper initrd 用户态工具来源差异（低）

**描述**：casper initrd 中的 userspace 工具（busybox、wget、ip、modprobe、switch_root）
来自 Ubuntu 的 initramfs-tools 构建链，与 rootfs 中的同源。这些工具只在 initrd 阶段运行
（switch_root 之前），之后由 Ubuntu rootfs 用户态接管。

**影响**：
- 工具行为与 rootfs 一致（同源 Ubuntu），无跨发行版差异。
- `nodeforge-initrd` 和 `nodeforge-agent` 静态链接，不依赖任何 glibc。
- casper initrd 的 `/init` 脚本需替换为 nodeforge-initrd wrapper（§2.3.2）。

**结论**：低风险，仅需替换 `/init` 脚本。

### 4.4 风险 R4：casper squashfs 层完整性依赖（中）

**描述**：casper squashfs 叠加方案依赖 Ubuntu ISO 的 casper 分层结构。如果未来 Ubuntu ISO
改变分层命名或结构，叠加脚本需要同步更新。

**影响**：
- Canonical 从 20.04 起在所有 LTS 中保持 `layerfs-path=` 和 dotted 命名规范（casper manpage 稳定记录）。
- 但非 LTS（如 25.10、26.04）可能引入新层或改变命名。

**缓解措施**：
1. ISO import 阶段检测 casper squashfs 层结构，记录到 catalog。
2. 如果检测到的层结构与预期不符，`nodeforge assets import` 输出告警。
3. 叠加脚本以配置化方式声明层列表，而非硬编码文件名。

### 4.5 风险 R5：apt rootfs-build package action 未实现（中）

**描述**：`first_boot.zig` 的 apt 分支未实现 `installroot` 跨根安装（dnf 分支已实现）。
v0.2.1 的 casper squashfs 方案绕过了 OS 层构建，但 rootfs-build phase 的 package action
仍需在 chroot 上下文中执行 apt install。

**影响**：
- rootfs-build phase 的 `package` action 在 chroot 到 Ubuntu rootfs 内执行 apt install，
  需要 rootfs 内有完整的 apt 工具链（casper squashfs 已包含）。
- chroot 执行不依赖宿主机有 apt，但需要 `/dev`/`/proc`/`/sys` bind-mount（apt 需要 /dev/null 等）。

**缓解措施**：
1. rootfs-build phase 的 apt package action 在 chroot 上下文执行（非 `--installroot`）。
2. builder 提供 chroot 环境 + bind-mount `/dev`/`/proc`/`/sys`。
3. 使用 rootfs 内的 apt（来自 casper squashfs），从 nodeforged 受管本地 APT 源安装。
4. 这与 dnf 的 `--installroot`（host 上下文，不 chroot）路径不同，需单独实现和测试。

## 5. CLI 提示

### 5.1 Ubuntu diskless profile 在非 Ubuntu 宿主机上构建 rootfs

当 `nodeforge profile rootfs build <ubuntu-profile>` 在非 Ubuntu 宿主机上执行时，
输出明确警告：

```text
⚠ WARNING: Building Ubuntu diskless rootfs on non-Ubuntu host (Rocky Linux 9.8).

  The casper squashfs overlay approach is used: the OS layer is extracted
  from the Ubuntu ISO's pre-built casper squashfs layers, not built from
  scratch with apt/debootstrap.

  initrd source: The initrd is extracted from the Ubuntu ISO's casper
  initrd (/casper/initrd), which contains 2222 .ko modules with vermagic
  matching the Ubuntu kernel (/casper/vmlinuz). The host's dracut is
  NOT used for Ubuntu diskless initrd.

  Kernel dependency risk (rootfs-build phase only):
  - Packages requiring kernel headers/modules (e.g. *-dkms, kernel-*,
    kmod) may fail because the host kernel (5.14.0-611.el9) does not
    match the target Ubuntu kernel (5.15.0-119-generic).
  - Pure userspace packages (openssh-server, curl, etc.) are not affected.
  - To eliminate this risk, build on an Ubuntu host with matching kernel.
```

### 5.2 initrd 来源不一致检测

当 boot bundle 的 kernel asset 来自 Ubuntu ISO 但 initrd asset **不是**从 casper initrd
提取（例如误用了宿主机 dracut 构建的 initrd），`nodeforge profile create` /
`nodeforge node boot-prepare` 输出风险提示：

```text
⚠ RISK: Boot kernel (ubuntu-5.15.0-119-generic) is paired with a non-casper
  initrd. The initrd's .ko modules may have mismatched vermagic and will
  fail to load on the Ubuntu kernel.

  For Ubuntu diskless, the initrd MUST be extracted from the Ubuntu ISO's
  /casper/initrd (which contains matching 5.15.0-119-generic .ko modules).
  Using the host's dracut initrd is NOT supported for Ubuntu diskless.

  Run: nodeforge assets import <ubuntu-iso>  (to extract casper initrd)
```

## 6. 实现范围

### 6.1 代码变更

| 模块 | 变更 | 说明 |
|---|---|---|
| `src/catalog/iso_import.zig` | 新增 casper squashfs 层 + casper initrd 检测 | ISO import 时识别 casper 分层结构和 `/casper/initrd`，记录到 catalog |
| `src/provision/rootfs_os_builder.zig` | 新增 `buildCasperOverlay` 分支 | apt 分支调用 casper squashfs 叠加（而非返回 `AptOsLayerUnsupported`） |
| `src/provision/initrd_builder.zig` | 新增 `buildCasperInitrd` 分支 | 从 ISO `/casper/initrd` 提取 → 注入 nodeforge-initrd → 替换 /init → 重新打包 |
| `src/provision/first_boot.zig` | apt package action 在 chroot 上下文执行 | 使用 rootfs 内的 apt，从受管 APT 源安装 |
| `src/provision/rootfs_build_executor.zig` | apt 分支 chroot 执行 + bind-mount | 与 dnf 的 `--installroot` 路径不同 |
| `src/cli/` | 新增风险提示 | Ubuntu diskless 在非 Ubuntu 宿主机上的构建提示 + initrd 来源不一致检测 |
| `tests/v0_2_1_ubuntu_casper_smoke.sh` | 新增正式 smoke test | 从 `v0_2_ubuntu_qemu_smoke.sh` 演进，使用 Ubuntu kernel + casper initrd |

### 6.2 不变更项

- v0.2 的 schema v4、catalog、BootSession、rootfs overlay 架构不变。
- v0.2 的 Rocky diskless 路径（`dnf --installroot`）不变。
- v0.2 的 nodeforge-initrd/agent 二进制不变（已是发行版无关）。
- v0.2 的 install 路径不受影响。

### 6.3 完成标准

1. `nodeforge assets import <ubuntu-iso>` 正确识别 casper 分层结构 + casper initrd 并记录到 catalog。
2. `nodeforge profile rootfs build <ubuntu-diskless-profile>` 在 Rocky/RHEL 宿主机上
   成功构建 Ubuntu rootfs（casper squashfs 叠加 + rootfs-build phase）。
3. rootfs-build phase 的 package action 在 chroot 上下文从受管 APT 源安装 userspace 包成功。
4. initrd 构建：从 ISO `/casper/initrd` 提取 → 注入 `nodeforge-initrd` → 替换 `/init` → 重新打包成功。
5. QEMU smoke 验证：**Ubuntu kernel** (`/casper/vmlinuz`) + **casper initrd**（注入 nodeforge-initrd）
   + Ubuntu rootfs（squashfs 叠加）→ switch_root → systemd → first-boot → `diskless.running`。
6. CLI 风险提示在适用场景下正确输出（非 Ubuntu 宿主机构建 rootfs-build、initrd 来源不一致）。
7. 内核相关包的风险在文档和 CLI 中明确声明（风险提示，不锁死）。
8. `zig build test` 全量通过。

### 6.4 不纳入 v0.2.1 的项

- Ubuntu 宿主机上的完整构建验证（消除所有内核不匹配风险）→ v0.2.2 验证矩阵。
- apt `--installroot` 跨根安装（替代 casper squashfs 方案）→ 未来版本评估。
- 从 rootfs 构建 initrd（chroot + apt install linux-image + mkinitramfs）→ 已验证可行但复杂度高（见 §9），保留为未来优化选项。
- 真正 QEMU PXE 网络启动验证（DHCP → TFTP → kernel+initrd）→ v0.2.2 验证矩阵。
- 临时 PXE rootfs 构建节点（在真实 Ubuntu 内核态构建）→ v0.4。

## 7. 版本规划变更

原 v0.2.1（异架构/实机验证矩阵保留项）重编号为 **v0.2.2**，
新的 **v0.2.1** 专用于 Ubuntu casper squashfs diskless 方案的设计和落地实现。

| 版本 | 原编号 | 新编号 | 范围 |
|---|---|---|---|
| v0.2 | v0.2 | v0.2 | Rocky/RHEL diskless（不变） |
| — | v0.2.1 | **v0.2.2** | 异架构/实机验证矩阵保留项 |
| — | — | **v0.2.1** | Ubuntu casper squashfs diskless（本文） |

## 8. 验证证据

### 8.1 v0.2 前置验证（已完成）

以下验证已在 v0.2 阶段完成，作为 v0.2.1 设计的事实基础：

| 验证项 | 结果 | 证据 |
|---|---|---|
| casper squashfs 3 层叠加在 Rocky 9.8 上 | ✅ | `/sbin/init` symlink + `/usr/sbin/sshd` ELF aarch64 |
| Rocky 上 mksquashfs 重新打包 | ✅ | 947MB squashfs |
| Zig 4 二进制在 Rocky 上编译 | ✅ | 全部静态链接 ELF aarch64 |
| casper manpage `layerfs-path=` 官方文档 | ✅ | 20.04/22.04/24.04 三个 LTS 均记录 |
| livecd-rootfs 构建脚本 `lb binary_layered` | ✅ | Launchpad Git 官方源码 |

### 8.2 v0.2.1 关键验证（r97n0 实测）

以下验证在 v0.2.1 设计阶段完成，确认 casper initrd 复用方案的可行性：

| 验证项 | 结果 | 证据 |
|---|---|---|
| casper initrd 格式检测 | ✅ | `file` → Zstandard compressed data (v0.8+) |
| casper initrd 解压 + 提取 | ✅ | zstd -d → cpio -idmv，349MB cpio，683174 blocks |
| casper initrd .ko 数量 | ✅ | 2222 个 `.ko` 文件 |
| casper initrd 内核版本 | ✅ | `./usr/lib/modules/5.15.0-119-generic/` |
| casper initrd 关键模块 | ✅ | `overlay.ko` 等 fs 模块存在 |
| casper initrd 用户态工具 | ✅ | wget ✓ busybox ✓ ip ✓ modprobe ✓ switch_root ✓ mount ✓ |
| casper initrd `/init` 脚本 | ✅ | `#!/bin/sh`，casper live-boot 逻辑（需替换） |
| casper rootfs `/lib/modules/` | ✅ 空目录 | squashfs 不含内核模块（Canonical 设计） |
| casper rootfs `mkinitramfs` | ✅ 已安装 | `/usr/sbin/mkinitramfs` + `/usr/sbin/update-initramfs` 存在 |
| Ubuntu ISO `/casper/vmlinuz` | ✅ | gzip compressed, `vmlinuz-5.15.0-119-generic.efi.signed` |

### 8.3 casper initrd 复用方案：QEMU 完整验证（已通过）

验证脚本：`tests/v0_2_1_casper_initrd_smoke.sh`
验证环境：r97n0 Rocky 9.8 aarch64
验证日期：2026-07-25

**验证产物链**：

| 产物 | 来源 | 版本 |
|---|---|---|
| kernel | Ubuntu ISO `/casper/vmlinuz` → 重命名为 `vmlinuz-5.15.0-119-generic` | 5.15.0-119-generic |
| initrd | Ubuntu ISO `/casper/initrd` → zstd 解压 → cpio 提取 → 注入 curl + nodeforge-initrd → 替换 /init → cpio+gzip 重新打包 | .ko vermagic 5.15.0-119-generic（同源） |
| rootfs | casper squashfs 3 层叠加 → 注入 agent/service → mksquashfs | Ubuntu 22.04 用户态 |

**验证结果**：

```text
PASS: validation done
PASS: diskless.running
PASS: ubuntu boot evidence
```

**完整 lifecycle 事件链**（events.jsonl）：
```
diskless.initrd_started → diskless.rootfs_downloading → diskless.rootfs_verified
→ diskless.rootfs_mounted → diskless.switching_root → diskless.agent_configuring
→ diskless.running
```

**关键 console 证据**：
```
[    3.283689] Run /init as init process
=== casper-initrd wrapper: eth0 up ===
... (nodeforge-initrd 运行) ...
[  OK  ] Started D-Bus System Message Bus.
         Starting NodeForge diskless first-boot provisioning...
[first-boot] done: 0 failure(s)
NODEFORGE_UBUNTU_CASPER_VALIDATION_DONE
[  OK  ] Finished NodeForge diskless first-boot provisioning.
```

**验证中发现并修复的 5 个问题**：

| # | 问题 | 根因 | 修复 |
|---|---|---|---|
| 1 | casper initrd 缺少 `curl` | casper initrd 只含 `wget`，但 nodeforge-initrd 调用 `curl` | 从 Ubuntu rootfs 复制 curl 及其 25 个依赖库 |
| 2 | `cp -a` 复制的是符号链接而非实际文件 | `libcurl.so.4` 是指向 `libcurl.so.4.7.0` 的符号链接 | 改用 `cp -L` 解引用 |
| 3 | casper initrd 没有 `ldconfig` | 无法重建 `ld.so.cache`，curl 找不到 libcurl | 在 `/init` 中设置 `LD_LIBRARY_PATH` |
| 4 | `/init` 预挂载 proc/sys/dev 导致 panic | nodeforge-initrd 的 `mustRun("mount")` 在已挂载时返回 `EBUSY` | 不预挂载，由 nodeforge-initrd 自己 mount |
| 5 | `vmlinuz` 必须按实际内核版本重命名 | PXE/TFTP 标准命名要求 | `cp vmlinuz vmlinuz-5.15.0-119-generic` |

**initrd 体积**：103MB（gzip 压缩后）

### 8.5 对比 Rocky diskless 方案和代码

检查了 `src/initrd.zig` 中的 nodeforge-initrd 代码，Rocky diskless **不存在类似问题**：

| 方面 | Rocky (v0.2) | Ubuntu (v0.2.1) | 原因 |
|---|---|---|---|
| curl 可用性 | ✅ dracut 默认包含 | ❌→✅ 需注入 | dracut 默认安装 curl，casper 不安装 |
| ldconfig | ✅ dracut 有 | ❌ 需 LD_LIBRARY_PATH | dracut 包含 ldconfig，casper 不包含 |
| /init 预挂载 | 无问题 | 无问题（修正后） | Rocky 的 dracut /init 不预挂载，Ubuntu 修正后也不预挂载 |
| vermagic 匹配 | ✅ 同宿主机 | ✅ 同 ISO | Rocky: kernel+initrd 同宿主机；Ubuntu: kernel+initrd 同 ISO |
| switch_root | ✅ `/usr/sbin/switch_root` | ✅ `/usr/bin/switch_root` | 两者都有 |
| DHCP client | `dhclient` fallback | casper 常见 `udhcpc`/`dhclient` | NodeForge 先复用已有地址，再优先 `udhcpc`、回退 `dhclient` |

**最新边界**：`nodeforge-initrd` 不再假设单一 dracut 工具闭包。HTTP 已由 Zig 原生客户端实现；网络先复用
已有全局 IPv4，再优先使用 vendor initrd 的 BusyBox `udhcpc`，最后回退到构建 overlay 注入的 `dhclient`。
因此 Ubuntu casper 是否自带 curl 不再影响启动，是否自带 dhclient 也不再是唯一客户端判据。
差异在 initrd 构建步骤中处理（注入 curl），不需要修改 `initrd.zig` 本身。

## 9. 两种 initrd 构建方案对比分析

### 9.1 概述

针对 Ubuntu diskless 的 initrd 构建，验证了两种方案：

| 方面 | 方案 A：复用 casper initrd | 方案 B：从 rootfs mkinitramfs |
|---|---|---|
| initrd 来源 | ISO `/casper/initrd`（解压→注入→重打包） | `chroot rootfs mkinitramfs` |
| kernel 来源 | ISO `/casper/vmlinuz` | rootfs `/boot/vmlinuz-<KREL>`（apt 安装） |
| 内核版本 | 5.15.0-119-generic（ISO 固定） | 取决于 apt 源（见 §9.3.1） |
| 宿主机要求 | 仅需 `zstd` + `cpio` | 需 `chroot` + `apt` + `mkinitramfs` |
| 网络依赖 | 无 | 需要 apt 源可达（受管源或公网源，见 §9.3.1） |
| 构建复杂度 | 低（4 步） | 高（8 步 + 后清理） |

### 9.2 QEMU 验证结果

两种方案均在 r97n0（Rocky 9.8 aarch64）上通过 QEMU smoke 验证：

| 验证项 | 方案 A（casper 复用） | 方案 B（mkinitramfs） |
|---|---|---|
| QEMU 启动 | ✅ PASS | ✅ PASS |
| diskless.running | ✅ PASS | ✅ PASS |
| ubuntu boot evidence | ✅ PASS | ✅ PASS |
| 验证脚本 | `v0_2_1_casper_initrd_smoke.sh` | `v0_2_1_mkinitramfs_smoke_v2.sh` |

### 9.3 方案 B（mkinitramfs）验证中发现的问题

#### 9.3.1 内核版本漂移（关键）

**问题根因**：验证脚本中 `chroot rootfs apt install linux-image-generic` 直接使用了 rootfs 自带的
`/etc/apt/sources.list`，它指向 Ubuntu 官方源 `ports.ubuntu.com`，而非 NodeForge 管理的受管源。
apt 从公网源获取的是**最新**内核版本，而非 ISO 中的版本：

| 来源 | 内核版本 | apt 源 |
|---|---|---|
| ISO `/casper/vmlinuz` | 5.15.0-119-generic | N/A |
| 公网源（验证脚本实际使用） | 5.15.0-186-generic | `ports.ubuntu.com/ubuntu-ports jammy` |
| NodeForge 受管源（应使用） | 应为 ISO 发布版本 | `/artifacts/repositories/<source>/` |

**NodeForge 的受管源机制**：ISO 导入时，daemon 从 ISO 中提取 APT metadata（`dists/`、`pool/`），
通过 `/artifacts/repositories/**` 发布只读受管 APT 源。`first_boot.zig` 中已实现 pinned 源机制：
```bash
# NodeForge first-boot package action 的 apt 源绑定方式
apt-get -o Dir::Etc::sourcelist=/tmp/nodeforge.sources.list \
       -o Dir::Etc::sourceparts=- update  # sourceparts=- 禁用所有其他源
apt-get -y -o Dir::Etc::sourcelist=/tmp/nodeforge.sources.list \
         -o Dir::Etc::sourceparts=- install <packages>
```

**正确的方案 B 应使用 nodeforged 受管源**：

构建 rootfs 时（`profile rootfs build`），OS 层构建器应使用 nodeforged 发布的受管 APT 源
（`/artifacts/repositories/<source>/`），而非 rootfs 自带的公网源。rootfs-build phase 的
package action 已通过 `first_boot.zig` 的 pinned 源机制实现：
```bash
# 创建临时 sources.list，只包含 nodeforged 受管源
printf 'deb [trusted=yes] http://<server>:<port>/artifacts/repositories/<source>/ ./\n' \
  > /tmp/nodeforge.sources.list
# 禁用所有其他源（sourceparts=-），只从受管源安装
apt-get -o Dir::Etc::sourcelist=/tmp/nodeforge.sources.list \
       -o Dir::Etc::sourceparts=- update
apt-get -y -o Dir::Etc::sourcelist=/tmp/nodeforge.sources.list \
         -o Dir::Etc::sourceparts=- install linux-image-generic
```

Ubuntu 22.04.5 live-server ISO 包含 `jammy` suite（不含 `jammy-updates`/`jammy-security`），
使用受管源时 `linux-image-generic` 的版本会被固定在 ISO 发布时的版本，不会漂移。

验证脚本（`v0_2_1_mkinitramfs_smoke_v2.sh`）中未使用此机制，直接使用了 rootfs 自带的公网源
（`ports.ubuntu.com`），这是验证脚本的缺陷。正式实现方案 B 时必须使用 nodeforged 受管源。

**注意**：即使使用受管源解决版本漂移，方案 B 的其他问题（§9.3.2 rootfs 膨胀、§9.3.3 modprobe 缺失）
依然存在，不影响方案 A 作为 v0.2.1 默认方案的结论。

#### 9.3.2 rootfs 体积膨胀导致 InsufficientMemory（关键）

`apt install linux-image-generic` 向 rootfs 注入了大量文件：

| 目录 | 体积 | 说明 |
|---|---|---|
| `/lib/modules/5.15.0-186-generic/` | 470 MB | 内核模块 |
| `/lib/firmware/` | 1.1 GB | 固件文件 |
| `/boot/vmlinuz-*` + `initrd.img-*` | 101 MB | 内核镜像 + initrd |
| **合计额外** | **~1.6 GB** | |

未清理时 rootfs.squashfs 从 948 MB 膨胀到 1.3 GB，导致 nodeforge-initrd 的
memory gate 检查失败（`error: InsufficientMemory`）。

**修复**：构建完 initrd 后，必须从 rootfs 中清理：
```bash
rm -rf rootfs/lib/modules/*      # 内核模块已在 initrd 中
rm -rf rootfs/lib/firmware/*     # 固件已在 initrd 中
rm -f rootfs/boot/vmlinuz-*      # 内核已提取
rm -f rootfs/boot/initrd.img-*   # 原始 initrd
```
清理后 rootfs.squashfs 降至 677 MB（比 casper 方案的 948 MB 还小，因为 casper
squashfs 本身包含一些额外文件）。

#### 9.3.3 mkinitramfs 缺少关键工具

mkinitramfs 生成的 initrd 与 casper initrd 的工具对比：

| 工具 | casper initrd | mkinitramfs | nodeforge-initrd 需要？ |
|---|---|---|---|
| curl | ❌ 需注入 | ❌ 需注入 | ✅ 是 |
| modprobe | ✅ 有 | ❌ 需注入 | ✅ 是（/init 脚本使用） |
| ip | ✅ 有 | ✅ 有 | ✅ 是 |
| DHCP client | `dhclient` fallback | `udhcpc` 或 `dhclient` | ✅ 至少一条路径；builder 保证 fallback |
| switch_root | ✅ 有 | ✅ 有 | ✅ 是 |
| mount | ✅ 有 | ✅ 有 | ✅ 是 |
| busybox | ✅ 有 | ✅ 有 | ✅ 是 |
| wget | ✅ 有 | ✅ 有 | ❌ 否 |
| ldconfig | ❌ | ❌ | ❌ |

**两种方案都需要注入 curl**，但 mkinitramfs 方案**还需要额外注入 modprobe**。

#### 9.3.4 mkinitramfs 格式为 zstd

mkinitramfs 默认输出 zstd 压缩的 cpio 镜像（与 casper initrd 格式一致）。
但重打包时使用 gzip 更安全（内核兼容性更好）。

### 9.4 综合对比

| 维度 | 方案 A（casper 复用） | 方案 B（mkinitramfs） |
|---|---|---|
| **构建步骤数** | 4 步 | 8 步 + 后清理 |
| **网络依赖** | 无 | 需要 apt 源 |
| **构建耗时** | ~30s | ~5min（apt update + install） |
| **内核版本一致性** | ✅ 与 ISO 完全一致 | ⚠️ 取决于 apt 源：公网源会漂移，受管源可固定（见 §9.3.1） |
| **rootfs 体积影响** | 无（rootfs 不变） | 需额外清理 1.6GB |
| **工具注入** | 仅 curl | curl + modprobe |
| **InsufficientMemory 风险** | 无 | 有（需清理后才能避免） |
| **离线构建** | ✅ 支持 | ❌ 不支持（需联网 apt） |
| **跨发行版宿主机** | ✅ 仅需 zstd/cpio | ⚠️ 需要 chroot + apt |
| **QEMU 验证** | ✅ 通过 | ✅ 通过（清理后） |
| **rootfs.squashfs** | 948 MB | 677 MB（清理后） |
| **initrd 体积** | 103 MB | 107 MB |

### 9.5 结论

**v0.2.1 采用方案 A（复用 casper initrd）**，理由：

1. **更简单**：4 步 vs 8 步 + 后清理
2. **无网络依赖**：完全离线可构建
3. **内核版本一致性**：kernel + initrd + .ko 全部来自同一 ISO
4. **无 rootfs 膨胀风险**：不需要 apt install，不需要清理
5. **更广泛的宿主机兼容性**：仅需 zstd + cpio

方案 B（mkinitramfs）在以下场景有价值：
- 需要使用比 ISO 更新的内核版本（安全补丁等）
- ISO 不可用但 rootfs 可用（如从已有 diskless 节点复制）
- 未来 v0.3+ 如果转向 debootstrap 方案

**方案 B 的额外复杂度（apt 依赖 + 后清理 + 版本漂移风险）使其不适合作为 v0.2.1 的默认方案。**

### 9.6 验证脚本

| 脚本 | 方案 | 状态 |
|---|---|---|
| `tests/v0_2_1_casper_initrd_smoke.sh` | 方案 A | ✅ 通过 |
| `tests/v0_2_1_mkinitramfs_smoke.sh` | 方案 B（v1，无清理） | ❌ InsufficientMemory |
| `tests/v0_2_1_mkinitramfs_smoke_v2.sh` | 方案 B（v2，带清理，公网源） | ✅ 通过 |
| `tests/v0_2_1_mkinitramfs_qemu_v3.sh` | 方案 B（v3，仅 QEMU） | ✅ 通过 |

> **注意**：方案 B 验证脚本使用了公网 apt 源而非 nodeforged 受管源，导致内核版本漂移
> （见 §9.3.1）。正式实现时必须使用 nodeforged 受管源。

### 9.7 HTTP 通信实现（v0.2 原生客户端）

#### 9.7.1 HTTP 在 nodeforge-initrd 中的用途

v0.2 交付中，`nodeforge-initrd` 已经使用**原生 Zig HTTP 客户端**（`src/initrd/http.zig`），
不再依赖外部 `curl` 子进程。该客户端在 4 处发起 HTTP 请求：

| 调用点 | 函数 | 用途 | HTTP 方法 |
|---|---|---|---|
| 行 66 | `http.getWithRetry()` | 拉取 BootConfig v2 JSON（含 rootfs URL/SHA-512/agent_plan），3 次重试 | GET |
| 行 294 | `http.headWithRetry()` | HEAD 请求校验 rootfs 元数据（Content-Length/ETag/Accept-Ranges），3 次重试 | HEAD |
| 行 315 | `rangeOnce()` | 分块 Range 下载 rootfs.squashfs（4MiB/块，断点续传） | GET + Range |
| 行 245 | `http.post()` | 上报 lifecycle 事件（diskless.initrd_started 等），best-effort | POST |

原生 HTTP 客户端支持：
- **GET/HEAD/POST/Range**：覆盖 nodeforge-initrd 的所有 HTTP 需求。
- **重试机制**：GET/HEAD 支持有界重试（指数退避，1s/2s/4s/...），POST 为 best-effort。
- **进度输出**：所有请求向 stderr (console) 输出类似 curl 的进度信息，在 PXE 启动中
  可看到 `[nodeforge-initrd] GET ... → 200 (1234 bytes)` 等日志。
- **断点续传**：Range 下载支持 `.part` 文件恢复，配合 5 次重试机制实现可靠传输。
- **错误处理更精确**：直接返回 TCP/HTTP 错误类型，而非通用的 `SubprocessFailed`。

#### 9.7.2 v0.2 实现总结

`src/initrd/http.zig` 原生 HTTP 客户端已完全替代了 curl，实现细节如下：

| 功能 | 实现 | 说明 |
|---|---|---|
| TCP 连接 | `std.Io.net.IpAddress.parseIp4` + `connect` | 仅支持 IPv4 地址（PXE 提供的 IP） |
| GET 请求 | 构造 `GET {path} HTTP/1.1` + 发送 + 读取 body | body 可读取到内存或写入文件 |
| HEAD 请求 | 构造 `HEAD {path} HTTP/1.1` + 发送 + 读取 headers | 返回原始响应头文本 |
| Range 请求 | 构造 `Range: bytes=N-M` + `If-Range: ETag` + 发送 + 读取 | 响应体写入临时文件 |
| POST 请求 | 构造 `POST {path} HTTP/1.1` + body + 发送 + 读取状态码 | best-effort，丢弃响应体 |
| 响应头解析 | 逐行读取状态行 + 头部，解析 Content-Length/ETag | 返回 heap 分配的原始头文本 |
| 响应体读取 | 按 Content-Length 精确读取字节 | 支持大文件（4MiB Range 块） |
| 重试 | `getWithRetry`/`headWithRetry` 包裹，指数退避 | max_retries 可配置 |
| 日志 | `std.c.write(2, ...)` 向 stderr 输出 | PXE 串口控制台可见 |
| 断点续传 | `.part` 文件检查 + offset 恢复 | 原逻辑保持不变 |

**代码行数**：~380 行 Zig 代码，包含完整的 HTTP/1.1 客户端、URL 解析器、重试逻辑和单元测试。

**收益**：
1. **消除 curl 外部依赖**：不再需要在 initrd 中注入 curl + 25 个依赖库 + LD_LIBRARY_PATH。
2. **统一 HTTP 栈**：与 `src/http/client.zig`（CLI 管理通信）使用相同的 TCP 连接和 HTTP 请求模式。
3. **更好的错误诊断**：curl 调用时只能得到 exit code，原生客户端可精确报告连接超时/拒绝/RESET 等。
4. **精简 initrd 体积**：Rocky diskless initrd 不再包含 curl 及其依赖；Ubuntu casper initrd
   也不需要注入 curl + 25 个依赖库（v0.2.1 方案 A 已验证原样复用 casper initrd 即可，
   不注入任何内容）。

**兼容性**：
- v0.2 Rocky diskless：dracut 不再依赖 curl（原已包含，现变为可选）。
- v0.2.1 Ubuntu diskless：casper initrd 本身不含 curl，但也不再需要注入。



#### 9.7.3（已过时）为什么用文件拷贝而非 chroot apt install curl？

**注**：v0.2 已实现原生 HTTP 客户端，不再依赖 curl。本节保留为历史记录，说明
方案 A 原本需要拷贝 curl 的原因。

**先澄清：方案 A 确实需要拷贝 curl——这不是可选的。**

casper initrd **不包含 curl**（只有 `wget`），而 `nodeforge-initrd` 运行时必须调用 curl
（见 §9.7.1）。因此方案 A 的 initrd 构建步骤中，**从 rootfs 拷贝 curl 到 initrd 是必需的**。

这里说的是"拷贝 vs apt install"的选择，而非"是否需要 curl"：

| 方式 | 说明 |
|---|---|
| **拷贝文件（方案 A 原采用）** | 从 rootfs 的 `/usr/bin/curl` 和 `/lib/*/libcurl*.so` 拷贝到 initrd |
| **chroot apt install** | 在 initrd-root 中执行 apt install curl（但 initrd-root 没有 apt/dpkg） |

选择拷贝文件的原因：

1. **curl 已在 rootfs 中**：Ubuntu casper squashfs 已包含 curl（`/usr/bin/curl`）
   及其全部依赖库。无需安装，只需拷贝到 initrd。
2. **initrd-root 没有 apt/dpkg**：casper initrd 是最小引导环境，不包含 apt、dpkg
   等包管理工具。无法在 initrd-root 中执行 `apt install`。
3. **不需要网络**：文件拷贝是纯本地操作，不需要 apt 源可达，不需要 nodeforged 运行。
4. **更简单**：`cp -L` + `ldd` 解析依赖比设置 pinned apt 源 + update + install 简单得多。
5. **`chroot rootfs apt install curl` 也是可行方案**：在 rootfs（而非 initrd-root）中
   用 nodeforged 受管源执行 apt install curl 也是可以的，但 curl 已经存在于 rootfs 中，
   apt install 只会确认它已安装（`0 newly installed`），不会改变任何文件。
   因此这一步完全多余——直接拷贝即可。

**总结**：v0.2.2（原生 HTTP）之后，方案 A **不再需要** 拷贝 curl。方案 B（mkinitramfs）
构建的 initrd 也不需要注入 curl，因为 `nodeforge-initrd` 使用原生 HTTP 客户端，不再依赖任何外部工具。
