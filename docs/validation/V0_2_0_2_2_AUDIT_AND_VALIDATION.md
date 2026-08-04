# v0.2 / v0.2.1 / v0.2.2 设计审计与验证

日期：2026-07-26

## 结论

v0.2 的 Rocky Linux aarch64 diskless 主流程已形成可操作的 CLI 闭环，并在
r97n0 QEMU 与 VMware Fusion `r97n1` 真实 UEFI PXE 两层验证通过。原实现中的
创建环、initrd 存储错位、人工 token/capsule、bootloader 地址漂移、CLI 缺口和
安装 bundle 不完整均已修复。

本轮完成的关键闭环：

- `setup` 默认 schema v4，并安装 CLI/daemon；bundle 若提供
  `nodeforge-initrd`/`nodeforge-agent`，两者必须成对安装。
- `assets initrd build --from-install-source` 保留 ISO vendor initrd 及其
  patch/firmware/ko，仅追加 NodeForge overlay；overlay 自动补入安装器 initrd
  可能缺少的 `dhclient` fallback、`switch_root` 及其动态依赖，并同时注入 `udhcpc`/`dhclient`
  最小 hook；运行时先复用已有地址，再优先使用 vendor `udhcpc`。无 source 时才调用通用
  dracut fallback。输出原子发布到专用 initrd store 并注册 catalog。
- boot bundle 只绑定 kernel/initrd，不再绑定 Profile 派生 rootfs。
- PXE 请求虚拟 per-MAC GRUB 时，服务端内部创建 delivery session；GRUB 追加
  内存态 per-boot cpio capsule。普通 `node boot-prepare` 不返回 raw token。
- 内容寻址 bootloader 由 DHCP/catalog 解析，不依赖 root 外绝对 symlink。
- `node readiness --stage build|boot`、`operation show|wait`、
  `node session list|show|cancel` 已接线。
- `profile set ... diskless.boot_bundle=<bundle>` 已接线，可用 CLI 原子切换
  不可变 boot bundle。
- rootfs OS-layer 基线包含 systemd、shadow-utils、网络与 SSH；构建器固定注入
  当前 `nodeforge-agent` 和已 enable 的 first-boot unit。`builder_revision`
  进入 rootfs cache key，构建逻辑升级不会误命中旧制品。

## CLI 全流程

已从隔离空实例验证：

```text
setup
→ assets import
→ assets initrd build（或 register 已校验制品）
→ assets boot-bundle create
→ profile create/set
→ profile rootfs build/status
→ node add/set
→ node readiness --stage boot
→ PXE 自动 session/capsule
→ node session list/show/cancel
→ operation show/wait
```

普通 CLI `boot-prepare` 响应仅含 session ID、状态、config URL 与 digest；四类
raw capability 只在 TFTP 同进程内部 loopback 请求中返回，且不会写入磁盘或
stdout。session 到达 `diskless.running` 后四类 capability 全部撤销。

`kernel_args` 中的 `console` 是保留参数，CLI 拒绝覆盖是正确行为；aarch64
可观察性由 resolver 的基线 `console=ttyAMA0 console=tty0` 保证，不应放宽
collection 校验。

## 自动验证

- native：`zig build test --summary all`，354/354 tests，11/11 steps。
- aarch64：ReleaseSafe 交叉构建 13/13 steps。
- r97n0 QEMU：Rocky 9.7 完整启动通过，rootfs 261,332,992 bytes；覆盖
  boot readiness、公开 prepare 不泄漏 token、session cancel、daemon 重启恢复、
  capability scope/replay 拒绝、HTTP Range、SHA-512、squashfs/overlay、
  switch_root、systemd、first-boot managed-file/package/archive/script、
  失败重试与 journal 幂等。
- r97n0 384 MiB：在 rootfs 传输前以 `MinimumFreeBudgetUnsatisfied`
  fail closed，并上报 `diskless.failed`。
- 独立 vendor initrd CLI：从 `rocky-9.7-aarch64-iso` 构建，原 ISO initrd
  134 MiB 内容作为不可变前缀保留，追加 initrd/agent、DHCP 与 switch-root
  companion；无 boot-root symlink 时仍由 TFTP 专用 store 交付。
- rootfs CLI：从本地受管 Rocky repository 构建 bootable OS layer；修复了
  dnf 输出 64 KiB 截断、RPM file-capability 所需 `CAP_SETFCAP`、agent/unit
  未注入及 builder 版本未进入 cache key 四个真实全流程缺口。

## VMware ARM 实机

环境：VMware Fusion `r97n1`，aarch64 UEFI，e1000e，vmnet2，
MAC `00:50:56:2A:23:DB`；通过 Computer Use 直接操作 Fusion。

最终证据：

- DHCP DORA 分配 `192.168.27.100`，GRUB 显示并选择
  `r97n1 → rocky-9.7-diskless`。
- TFTP 交付内容寻址 GRUB、13,232,984-byte kernel、142,020,142-byte
  vendor-derived initrd 与 1,068-byte
  自动 capsule。
- initrd 加载 e1000e、自定义 DHCP hook，取得 BootConfig，Range 下载并校验
  189,464,576-byte rootfs。
- session `167633494167c3337084dc8dabe1b8a5` 到达
  `diskless.running`；config/rootfs/agent/event capability 全部为 false。
- Rocky Linux 9.8 userspace（Rocky 9.7 ISO kernel
  `5.14.0-611.5.1.el9_7.aarch64`）到达登录提示；Computer Use 使用
  `nodeforge` 登录。
- `/proc/mounts` 显示 `/` 为 overlay，lower `/lower`、upper `/rw/upper`、
  work `/rw/work`；`systemctl is-system-running` 返回 `running`；
  `nodeforge-firstboot.service` 返回 `active`；`/proc/cmdline` 固定到
  r97n1 的 boot-config URL 与 `nodeforge.node=r97n1`。
- 从 r97n0 实际 SSH 登录 `nodeforge@192.168.27.100`，密码认证成功；
  `SSH_CONNECTION` 为 `192.168.27.1 ... 192.168.27.100 22`，sshd 在
  IPv4/IPv6 `:22` 监听且为 `active`。NetworkManager 为 `active`，
  `enp2s0=192.168.27.100/24`；该 Profile 为 local-only，因此路由表仅含
  `192.168.27.0/24` 直连路由，不配置默认网关。
- 验证后关闭 VM；r97n0 原生产二进制、catalog 和登记 initrd 已恢复，
  `nodeforged` 为 active 且健康。

## 2026-07-27 r97n0 增量部署验证

本轮在 macOS/Zig 0.16.0 使用 `aarch64-linux-gnu ReleaseSafe` 交叉编译四个产物。部署前先停止
`nodeforged`，确认生产进程退出且 UDP 67/69 不再由 NodeForge 占用；上传到独立暂存目录并核对 ELF
架构与 SHA-256 后，备份旧二进制，再以同目录 rename 替换 `/opt/nodeforge/bin/`。随后执行
`nodeforged --check-config`、`nodeforged --check`、systemd start 和 `/healthz`，全部通过。
最终远端 SHA-256 为：`nodeforge=227fb68b93f16edf2055b18321fac0418856b9e61a81cd433bd2919efab44308`、
`nodeforged=c439405bb4918d42092e7b19ca0c3744c26e29c6ad1405939fdaf94487a30fcf`、
`nodeforge-agent=03abfbb1e70240ecbe9005bafd0ea9a45064d56c653aab400afd5f30a4e21c76`、
`nodeforge-initrd=b8b68276a02e0cb08d360de681185779df720fcb118db9e0b051022abb35961e`。

实机验证不是只检查 help：通过生产 management API 创建绑定 `rocky-9.7-diskless`、但
`deploy=false` 的临时节点，同时提交 `pxe.ip_reservation`、静态 `network.address/prefix_len/gateway`、
`network.interface_name`、`network.match_mac` 和 Node timezone override。`node show` 按
`Stored / Overrides / Effective / Runtime` 分区，点路径形成缩进层级并正确对齐；`profile show` 的
Stored/Effective/Capabilities/Assets/Runtime 同样正常。验证后删除临时节点，catalog 仅保留原 `r97n1`；
服务保持 active，healthz 成功，journal 无 warning。

部署验证发现并修复了两处仅靠编译未暴露的创建契约漂移：

1. `deploy=false/profile=null` 时 CLI 曾省略必需 nullable `profile`，服务端 strict DTO 解码失败；现显式发送 null。
2. CLI 已接受创建时 overrides，但 HTTP `NodeAddRequest` 和 catalog `AddParams` 未贯通，且直接序列化
   `NodeConfig` 会泄漏 strict DTO 不接受的 legacy 字段；现使用 canonical create payload，并让 overrides
   从 CLI 经 HTTP 原子落入 catalog。对应回归测试已加入 native test suite。

本轮部署的 `nodeforge-initrd` 二进制已确认包含“已有地址 → udhcpc → dhclient fallback”选择逻辑；但未重新
构建并 PXE 启动生产 initrd asset，因此本节不把字符串/构建验证表述为新的 diskless 启动闭环证据。既有
Rocky/VMware 启动证据仍来自上一节，下一次重建 boot bundle 时应执行一次真实 PXE 回归。

## v0.2.1 / v0.2.2 边界

## 2026-07-30 Ubuntu v0.2.1 VMware 产品闭环

构建端为 r97n0（Rocky Linux 9.8 aarch64，root），输入为真实
`ubuntu-22.04.5-live-server-arm64.iso`。产品 CLI 完成 ISO import、casper layer
发现、vendor initrd 派生、diskless Profile 与 rootfs build；最终 rootfs 为
992,210,944 bytes。构建过程暴露并修复了 casper 绝对符号链接存在性误判和
whiteout/逐层合并问题。

VMware Fusion `r97n1`（aarch64 UEFI、MAC `00:50:56:2A:23:DB`）由 Computer
Use 冷启动验证。首轮 session `ea35af44e17056a9dc5844179ab25cc2`、复验 session
`f21d257aa538c12e5b914a504ac740e4` 均依次上报
`initrd_started → rootfs_downloading → rootfs_verified → rootfs_mounted →
switching_root → agent_configuring → running`。复验中 initrd 为 106,875,713
bytes，rootfs Range 下载和校验约 10 秒完成；未出现新的产品故障。

同时修正 smoke 夹具：旧 `tests/v0_2_1_ubuntu_casper_smoke.sh` 的 QEMU 段只等待
事件、从未启动 guest。现强制提供 `NODEFORGE_QEMU_LAUNCHER`，校验其返回存活
QEMU PID，并在 guest 提前退出时打印 console 后失败。独立 QEMU 产品 CLI
闭环和同候选 Rocky 重建仍保留为待执行项，不以本次 VMware 结果替代。

本段为早期验证记录；其后 v0.2.1 已完成 casper OS-layer builder、
namespaced chroot apt 执行、Ubuntu initrd/kernel 同源闭包和 Rocky/Ubuntu
同候选 VMware 回归。最终完成证据见后文 fresh CLI 三发行版复验及 Ubuntu
控制台“假卡住”复验。独立 QEMU 与双架构固定矩阵归入 v0.2.2。

v0.2.2 聚焦可运营性与矩阵扩展：

- readiness 重算全部制品 digest，并接入真实 inventory memory；
- boot preview、细粒度 diskless retry/status/quarantine CLI；
- async initrd/rootfs build operation（当前 initrd build 为同步命令）；
- session store 并发串行化和内部 capsule 通道进一步收窄；
- x86_64 UEFI、断网/恢复、更多 VMware/QEMU 固定矩阵。

设计稿中仍属计划态的命令必须标注“计划中”，不得出现在生产 runbook 中冒充
已实现能力。

## 2026-07-30 fresh CLI 三发行版复验

在 r97n0 停止并移除既有 nodeforged unit、`/opt/nodeforge` 配置/catalog/assets
后，使用四个新交叉编译的 aarch64 ReleaseSafe 二进制，严格按 README 的
`setup → assets import → assets initrd build → boot-bundle create → profile
create → profile rootfs build → node add/set/readiness/deploy` CLI 流程从零重建。
未导入旧配置或迁移旧制品；仅保留 `/root` 下三张原始 ISO 作为新输入。

最终导入和构建 Rocky 9.7 minimal、Rocky 10.2 DVD、Ubuntu 22.04.5 live-server
三套有效 install source/profile/bundle/rootfs。rootfs 使用
`assets/diskless/rootfs/<profile>/<digest-prefix>/<profile>.squashfs`，initrd
使用 `assets/diskless/initrd/<name>/<uname-r>/initrd.img`。r97n1 的
`192.168.27.210` 来自 r97n0 `/etc/hosts`，节点以
`pxe.ip_reservation` 登记；profile 导入的 hosts、受管仓库与 SSH 有效配置均符合
CLI 投影。

Computer Use 控制 VMware Fusion 逐一冷启动 Rocky 10.2、Rocky 9.7 和 Ubuntu。
三者都上报连续的 event_seq 0–6 并进入 `diskless.running`，每轮
nodeforged 均为 active、`NRestarts=0`。Ubuntu 最终实机检查为：

- `5.15.0-119-generic`，根文件系统为 overlay；
- `/etc/hosts` 含 r97n0/r97n1，SSH active；
- APT 只剩 `/etc/apt/sources.list.d/nodeforge.list`，指向 NodeForge 受管 ISO 仓库；
- `snapd.*`、`multipathd.*`、`casper-md5check.service` 全部 masked/inactive，
  `NRestarts=0`，`systemctl --failed` 为空。

本轮还发现 Zig 0.16 POSIX Threaded Io 对 connect deadline 会直接 panic，并可由
TFTP loopback boot-prepare 路径杀死 nodeforged。当前显式使用 30 秒 API、120 秒
制品 socket 空闲超时且不限制持续有进展的总下载时长；connect 暂由内核 TCP 有界
超时承担，待 Zig/runtime 安全支持 deadline 后再落实显式 10 秒建连上限。

### Ubuntu 控制台“假卡住”复验与修复

上述 `diskless.running` 后继续观察 VMware，发现控制台停在
`Reached target Cloud-init target` 附近，没有登录提示。独立检查确认这不是启动
阻塞：

- SSH 可登录，PID 1 为 `/sbin/init`，`systemctl is-system-running` 返回 `running`；
- SSH 监听 IPv4/IPv6 22 端口，NodeForge session
  `99b3fdef00a9d108484cedc5cbacf4c7` 已完整到达 event_seq 6；
- `getty@tty1.service` 却为 masked/inactive，vendor mask 位于
  `/lib/systemd/system/getty@tty1.service -> /dev/null`；
- `getty@.service.d/autologin.conf` 和
  `serial-getty@.service.d/subiquity-serial.conf` 仍把 getty 指向 Ubuntu
  installer/Subiquity 行为。

根因是 casper live-server rootfs 的 installer 控制台配置被原样带入 diskless
运行根。它不会阻止 systemd、网络或 SSH，所以单看 `diskless.running` 会产生
假阳性。

修复在 Ubuntu node-apply pre-init 阶段完成：

1. 删除 `/lib` vendor 目录中的 tty1 `/dev/null` mask；
2. 删除 casper autologin 和 Subiquity serial-getty drop-in；
3. 从标准 `getty@.service` 模板恢复 tty1 wants；
4. 仅当 `/dev/ttyAMA0` 是真实字符设备时创建 ARM serial-getty wants，避免
   VMware 没有该设备时出现 dependency failure。

修复候选通过新 initrd、boot bundle、profile 和 rootfs 全部由产品 CLI 重建。
首次启动 session `59dcfdf7d521b8cb07873f1c39ab9a44` 到达
`diskless.running`，并确认 tty1 getty active。为排除人工向 tty1 写诊断文本的
干扰，又执行一次 VMware 冷启动；最终 session
`d92436ac457a0d8034492fcb6f57d7bc` event_seq 0–6 连续、nodeforged
`NRestarts=0`，控制台自然显示：

```text
Ubuntu 22.04.5 LTS r97n1 tty1

r97n1 login:
```

因此最终验收结论是：Ubuntu diskless 的受管生命周期、systemd/SSH 运行态和
VMware tty1 交互控制台三项均通过。后续回归不得只以 lifecycle running 替代
控制台可用性检查。

## 2026-07-30 v0.2.2 fresh CLI 发布候选复验

候选 `2086355aaaba`（工作树包含本轮 v0.2.2 改动）在 r97n0 从空数据执行 setup，
所有产品配置与制品均由公开 CLI 创建。四个 aarch64 ReleaseSafe 产物摘要为：

```text
nodeforge         92a447066bf39a63c6ca2abc167841c49230aae9c6d8a59edb3ae26a58077206
nodeforged        02d057b75eaa6ef45c151f42d7f4c16c8216e22c0c13ff70b7931bcc4c0eed03
nodeforge-initrd  0414194a4632dadd9fef15a483f125c82110fd2316dc613bd6ceb316e8e5ec02
nodeforge-agent   37cbd665eb36237c43a1a477c4bea9d259a1a51762cd3eedfa2201d11b07cda9
```

Rocky 9.7 Minimal、Rocky 10.2 DVD 与 Ubuntu 22.04.5 ISO import operation 均
成功；三套 initrd build 与三套 rootfs build operation 均为 `succeeded`。六个
install/diskless Profile 均通过 catalog 校验。

VMware Fusion aarch64 r97n1 的复验结果：

- Ubuntu 22.04.5 install generation 2 完成；
- Rocky 9.7 install generation 3 完成，applied/desired plan digest 一致；
- Rocky 9.7 diskless session `63da1b2cd8b1406d48123b927c357924` 到达
  `diskless_running`；
- Ubuntu diskless session `2a402a4d7322ca66bbae83d264a96e73` event_seq 0–6
  连续并到达 `diskless_running`；
- 两套 diskless 的 readiness/boot preview 均通过，preview 未创建 session；
- Ubuntu diskless first-boot postprocess 为 `succeeded`，trace 无 gap；
- guest hostname、`/etc/hosts`、NodeForge-only repository 与 root SSH
  authentication 均符合 effective plan。

本地 `zig build test --summary all` 为 397/397 通过，CLI、HTTP 与 setup shell
契约步骤全部成功。x86_64 VMware 仍按
`docs/design/LOCAL_VALIDATION_DEFERRED.md` 不进入本地完成闸。
