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
  可能缺少的 `dhclient`、`switch_root` 及其动态依赖。无 source 时才调用通用
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
→ profile rootfs build/status（或 register）
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

## v0.2.1 / v0.2.2 边界

v0.2.1 仍需完成 Ubuntu 产品保真：apt/debootstrap OS-layer builder、
Ubuntu initrd/kernel feature closure、双发行版固定回归。当前 Ubuntu
casper smoke 已有，但不能等同于完整 Ubuntu rootfs builder。

v0.2.2 聚焦可运营性与矩阵扩展：

- readiness 重算全部制品 digest，并接入真实 inventory memory；
- boot preview、细粒度 diskless retry/status/quarantine CLI；
- async initrd/rootfs build operation（当前 initrd build 为同步命令）；
- session store 并发串行化和内部 capsule 通道进一步收窄；
- x86_64 UEFI、断网/恢复、更多 VMware/QEMU 固定矩阵。

设计稿中仍属计划态的命令必须标注“计划中”，不得出现在生产 runbook 中冒充
已实现能力。
