# NodeForge v0.2 Diskless 从零构建与 PXE 启动流程

状态：v0.2 操作与实现流程基线。本文从空 catalog 开始，定义本地安装源导入、rootfs 构建、PXE
发布、节点启动、first-boot、失败恢复和停用的完整闭环。字段所有权见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md)，
initrd 细节见 [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md)，命令参考见 [`V0_2_CLI.md`](V0_2_CLI.md)。

## 1. 先消除构建环

boot bundle 不能持有 rootfs 引用。否则会形成无法启动的环：Profile 引用 boot bundle -> effective plan
决定 rootfs -> boot bundle 又要求 rootfs 已存在。v0.2 的对象关系固定为：

```text
InstallSource(local ISO/repositories/software index)
        + Kernel asset
        + NodeForge initrd asset
        -> BootBundle（启动环境，不含 rootfs）

BootBundle + Diskless Profile + Node effective build inputs
        -> rootfs_input_digest
        -> RootfsArtifact(squashfs, derived/cache-only)

fixed plan + BootBundle revisions + RootfsArtifact digest
        -> DeliveryManifest（per BootSession）
```

`BootBundle` 是持久 catalog Resource，至少固定 `install_source`、kernel、nodeforge-initrd、arch、
kernel release 和 feature manifest。`RootfsArtifact` 是 builder 派生缓存，不允许人工改内容或由 Profile
直接引用。`DeliveryManifest` 是 session 快照，不写回 desired catalog。

digest 分三层，禁止互相代替：

| digest | 输入 | 用途 |
|---|---|---|
| `desired_plan_digest` | Profile/Node/resource revisions 的 canonical effective plan，不含 rootfs 输出 | drift、CAS、session desired snapshot |
| `rootfs_input_digest` | 可共享 build 输入；明确排除 node identity/network/secrets | builder cache key |
| `delivery_digest` | desired plan + boot bundle revisions + rootfs content SHA-512 + BootConfig schema | 一次启动的不可变交付身份 |

## 2. 阶段 0：服务端准备

前置条件：v0.1 setup 完成，DHCP/TFTP/HTTP 绑定隔离 PXE 网络，时间可靠，asset/repository/catalog/runtime
目录位于本地持久文件系统。执行：

```text
nodeforge preflight --scope diskless-builder
nodeforge status --component dhcp,tftp,http,builder
nodeforge config validate
nodeforge catalog validate
```

`preflight` 必须检查：服务地址是 IPv4 字面地址；PXE interface/address 匹配；TFTP/HTTP 可读；builder
工具、`mksquashfs`、目标发行版包管理器、dracut 与 kernel release 能力可用；磁盘 staging 空间、daemon
文件描述符和内存容量足够；local-only 网络策略可执行。跨架构构建默认拒绝，只有 builder manifest 声明
binfmt/qemu-user 且全部 rootfs-build step 为 cross-safe 时才允许。

## 3. 阶段 1：导入本地 OS 源

```text
nodeforge assets import /srv/iso/Rocky-9.7-x86_64-dvd.iso
nodeforge assets install-source list
nodeforge assets install-source show rocky-9.7-x86_64
nodeforge assets repository validate rocky-9.7-baseos
nodeforge assets install-source software list rocky-9.7-x86_64 --kind environment
nodeforge assets runtime-kernel prepare --source rocky-9.7-x86_64 --release <release> --wait
nodeforge assets runtime-kernel validate <kernel-asset>
```

ISO 导入事务必须产生/验证 ISO asset、media tree、install source、本地 repositories、installer kernel 和
software capability index。diskless runtime kernel 由 `runtime-kernel prepare` 从本地 kernel package 提取，并固定完全匹配的
modules/package closure；不能假设安装器 kernel 可作为最终系统 kernel。diskless builder 不使用公网 mirror、metalink
或运行时 distro update。导入成功不代表
diskless ready；它只建立可重复构建的本地输入。

## 4. 阶段 2：定义 build-time 与 first-boot 定制

`rootfs-build` 用于所有共享节点都应具有、且必须在发布前完成的内容；`first-boot` 只用于需要目标运行环境
或节点上下文的 bounded action。核心系统配置不属于 first-boot。

```text
nodeforge assets managed-file import ./motd --destination /etc/motd --name motd-v1
nodeforge assets archive import ./vendor-agent.tar.bz2 --name vendor-agent-v1
nodeforge assets script import ./register-local-service.sh --name register-service-v1
nodeforge assets provision-bundle create compute-diskless-v1

nodeforge assets provision-bundle item add compute-diskless-v1 --phase rootfs-build \
  id=base-tools action=package packages=tmux,nmap idempotency_key=base-tools timeout_s=600 retryable=true
nodeforge assets provision-bundle item add compute-diskless-v1 --phase rootfs-build \
  id=motd action=managed-file content_asset=motd-v1 destination=/etc/motd mode=0644 owner=root group=root \
  idempotency_key=motd timeout_s=30 retryable=false
nodeforge assets provision-bundle item add compute-diskless-v1 --phase first-boot \
  id=vendor-agent action=archive archive_asset=vendor-agent-v1 idempotency_key=vendor-agent timeout_s=300 retryable=true
nodeforge assets provision-bundle plan compute-diskless-v1 --phase rootfs-build
nodeforge assets provision-bundle plan compute-diskless-v1 --phase first-boot
```

以下内容必须由 effective target-system + initrd projection 处理，不能依赖 first-boot：hostname、目标网络、
账号/password hash、authorized_keys、machine-id、SSH host key、locale/timezone/keyboard。否则 first-boot
失败会留下身份或网络不完整的节点。

first-boot 适合：需要真实 kernel `/sys` 的本地驱动 finalization、启动后才能生成的节点缓存、受控服务注册、
仅能在运行根中执行的 vendor installer。它不是远程命令、持续配置管理、联网更新或失败修复兜底。

## 5. 阶段 3：构建 NodeForge initrd 与 BootBundle

```text
nodeforge assets nodeforge-initrd config show
nodeforge assets nodeforge-initrd config set http_client=curl overlay=true squashfs=true
nodeforge assets nodeforge-initrd modules-values add <nic-module> loop squashfs overlay
nodeforge assets nodeforge-initrd firmware-values add <required-firmware-asset>
nodeforge assets nodeforge-initrd build --source rocky-9.7-x86_64 --kernel <kernel-asset> --wait
nodeforge assets nodeforge-initrd validate <initrd-asset>

nodeforge assets boot-bundle create rocky-9.7-diskless-x86_64 \
  install_source=rocky-9.7-x86_64 kernel=<kernel-asset> initrd=<initrd-asset>
nodeforge assets boot-bundle validate rocky-9.7-diskless-x86_64
nodeforge assets boot-bundle show rocky-9.7-diskless-x86_64
```

initrd manifest 必须证明包含启动 NIC driver/firmware、DHCP、HTTP、SHA-512、loop、squashfs、tmpfs、overlay、
目标 network renderer handoff 和 `nodeforge-initrd`。BootBundle 校验 kernel release、rootfs 将使用的 modules ABI、
arch/source/repository revision 和 required feature 子集；它此时不要求 rootfs 已存在。

## 6. 阶段 4：创建 Profile 与 Node（保持禁用）

```text
nodeforge profile create compute-diskless --kind diskless \
  diskless.boot_bundle=rocky-9.7-diskless-x86_64 diskless.provision.bundle=compute-diskless-v1
nodeforge profile set compute-diskless diskless.overlay.tmpfs_percent=40 \
  diskless.failure.max_attempts=3 diskless.failure.backoff_seconds=30
nodeforge profile add-values compute-diskless software.packages.include chrony

nodeforge node add c001 mac=52:54:00:12:34:56 arch=x86_64 profile=compute-diskless deploy=false
nodeforge node set c001 pxe.ip_reservation=192.168.50.101 hostname=c001.example.test
nodeforge node set c001 network.mode=static network.interface=eth0 \
  network.address=192.168.50.101 network.prefix_len=24 network.gateway=192.168.50.1
nodeforge node add-values c001 network.dns 192.168.50.2
```

Node 初始必须 `deploy=false`，防止 rootfs 未 ready 时不断产生失败尝试。Profile kind 是创建时 discriminant；
Node 不得 override kind。Node 从 install Profile 切换到 diskless 或反向切换，只允许：`deploy=false`、无 active
session、无待恢复 session；切换后旧 current status 归档，不能与新 kind 合并。

## 7. 阶段 5：编译 build plan

readiness 是只读准入检查，不是“准备动作”：不构建、不改配置、不启用 PXE、不创建 BootSession。
`stage=build` 检查能否开始构建；后面的 `stage=boot` 检查能否开始给节点发 bootfile。失败结果必须给出
check id、稳定 reason 和下一条建议命令。

```text
nodeforge node effective c001 --section build
nodeforge node rootfs plan c001 --output json
nodeforge node readiness c001 --stage build
```

`--stage build` 不要求 rootfs 已存在，只检查所有输入是否足以构建，并输出 `desired_plan_digest`、
`rootfs_input_digest`、cache hit、估算大小、builder capability、输入 revisions 和排除的 per-node projection。
此处必须发现：install-only storage 字段、缺 source/repository capability、跨架构不安全 step、受保护路径写入、
公网 repository、kernel/modules ABI 不匹配和 bundle revision 漂移。

`node effective` 不得把 password hash/token 完整打印到 human 输出；JSON 的 secret-bearing 字段默认 redacted，
只有本机受权的专用 projection preview 能显示 hash，且永不显示 token。

## 8. 阶段 6：从零构建 rootfs

```text
nodeforge node rootfs build c001 --if-input-digest <rootfs_input_digest> --wait
nodeforge node rootfs status c001
nodeforge assets rootfs show <rootfs_input_digest>
nodeforge assets rootfs validate <rootfs_input_digest> --deep
```

builder 的固定过程：

1. 对 input digest 获取 build lease；相同输入并发请求 join 同一个 build。
2. 创建私有 staging/mount namespace，固定 install source/repository/asset revisions，关闭公网出口。
3. RHEL/Rocky 用目标版本 `dnf --installroot` 构建基础 root；Ubuntu 用 fixed-revision debootstrap/apt 本地源。
   lorax/livecd 工具只可作为经 adapter 声明的实现，不能默认拿安装 ISO 制作工具代替 rootfs builder。
4. 安装 baseline：systemd/udev、目标 network renderer、iproute、包管理器、SSH（若 policy 启用）、
   nodeforge-agent、与启动 kernel 完全匹配的 `/lib/modules/<release>` 和 firmware。
5. 应用 effective software 与 `rootfs-build` items，顺序为 managed-file -> package -> archive -> script；同时把
   first-boot manifest、assets 和完整 package closure 预置到内容寻址目录，但不执行 first-boot。
6. 执行 target-system build-safe 骨架；清除 machine-id、SSH host private keys、DHCP lease、普通包缓存、临时文件、
   builder resolv.conf、随机种子和任何 node/token/password hash。
7. 检查 `/sbin/init`、agent unit、renderer、shared libraries、modules dependency、UID/GID 冲突、local-only URL、
   world-writable/suid policy 和未声明文件。
8. 用固定排序、时间戳/owner 和 compression 参数运行 `mksquashfs`，得到可复现 squashfs。
9. 计算完整 SHA-512、size/uncompressed estimate，生成 manifest/SBOM/file inventory；unsquashfs 再读验证。
10. 原子发布 object 后再发布 ready manifest，释放 lease；失败只保留有界脱敏日志，staging 进入可审计清理。

`--force` 不覆盖旧 digest，也不改变 cache identity；它只在相同输入下重新执行并比较输出。若输出 digest 不同，
标记 `builder.non_reproducible` 且不得自动替换 ready artifact。

## 9. 阶段 7：boot readiness 与启用 PXE

```text
nodeforge node readiness c001 --stage boot
nodeforge node boot preview c001
nodeforge node set c001 deploy=true --if-plan-digest <desired_plan_digest>
nodeforge node status c001
```

boot readiness 是强闸，必须同时满足：rootfs ready/deep validation；kernel/initrd/modules/features 联合兼容；
BootConfig 可渲染；MAC/arch/IP/renderer 一致；有可信内存 inventory 时服务端预检预算；无 quarantine；无 active session；
desired plan 未漂移。`deploy=true` 必须带 plan digest 做 CAS；设置成功只允许未来 PXE，不主动重启节点。

全新 Node 常常没有可信内存 inventory。此时 boot readiness 返回 `memory=unknown` 和 `required_min_bytes` warning，
允许启用，但 initrd 必须读取实际 `MemAvailable` 做硬闸；不得把 unknown 当作“预算已通过”。

若操作员修改 Profile/Node/bundle/source revision，desired plan 改变：新 DHCP bootfile 立即被 readiness gate 阻止，
旧 active session 按自己的 delivery snapshot 完成；新 rootfs build/validation 完成后才能重新启用。

## 10. 阶段 8：节点 PXE 无盘启动

```text
NIC PXE DHCPDISCOVER
 -> nodeforged 校验唯一 Node/MAC、kind=diskless、deploy、readiness、quarantine
 -> DHCPOFFER/DHCPACK + GRUB UEFI bootfile
 -> TFTP/HTTP 取得 GRUB config、kernel、共享 NodeForge initrd 和 per-session credential.cpio
 -> GRUB 追加两个 initrd；kernel cmdline 只有 node/session/config URL，无 token
 -> initrd 从 capsule 读取一次性 config token
 -> 一次性获取并校验 BootConfig
 -> HEAD/Range 下载 rootfs.part，完整 SHA-512 校验
 -> loop(ro) lower + tmpfs upper/work + overlay merged
 -> 写 per-node target-system projection
 -> pre-switch 检查，move-mount /run，清 config/artifact token
 -> switch_root，systemd/renderer 接管同一 NIC/address
 -> agent 上报 diskless.running，从 rootfs 本地 fixed payload 执行可选 first-boot，删除 event token
```

服务端只允许一个 `(node_id, active_session)`。DHCP 重传复用同 session；同 MAC 的新 boot XID 必须原子
supersede 旧 session、撤销旧 token 后再创建新 session，不能并存。状态始终是一个 tagged value：共享 `boot.*` 后只进入 `diskless.*`，不可能出现
`install.*`。first-boot 失败使 `postprocess=degraded`，Node 仍是 `diskless.running`。

## 11. 阶段 9：观测、失败恢复与停用

```text
nodeforge node list --kind diskless
nodeforge node status c001
nodeforge node trace c001 --session <id>
nodeforge node postprocess show c001 --session <id>
nodeforge events list --node c001 --session <id>

nodeforge node set c001 deploy=false                                      # 停用新的 PXE
nodeforge node diskless retry c001 --if-failure-revision <revision>       # 仅 deploy=true 时清 quarantine
nodeforge status --component rootfs-cache
```

- `deploy=false` 只阻止新 PXE，不杀死已经切根或正在下载的 fixed delivery session。
- retry 只清 failure/quarantine gate，不重启、不改 Profile、不创建 install generation。
- daemon 重启后用 delivery record + token hash + snapshot refs 恢复同一交付；不能重新编译 desired plan 续跑。
- v0.2 已发布 rootfs 只增不删；status 做容量告警，空间不足时阻止新 build，不自动回收。

## 12. 最小故障注入矩阵

发布前至少覆盖：ISO/repository 缺包；builder 无空间/崩溃/重复构建不一致；kernel/modules ABI mismatch；initrd
缺 NIC firmware/feature；rootfs 内泄露 machine-id/key/token；内存不足；DHCP 重传与并发 XID；TFTP 中断；BootConfig
过期/重放/跨 node；Range 200/206/416、ETag 变化、两次完整 hash mismatch；daemon 在 config/download/event
阶段重启；网络 renderer flush 地址；`/run` 未交接；switch_root exec 返回；first-boot action timeout；事件断网；
缓存空间不足；Profile 从 diskless 切 install 时存在 active/recoverable session。每项必须断言稳定 reason、唯一 current state、
secret 不泄露和 v0.1 install 回归不退化。
