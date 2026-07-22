# NodeForge v0.2 程序边界设计

状态：设计冻结，实现未开始。本文定义 v0.2 三个编译产物的职责、功能列表与实现要点，
与 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) 一致。CLI 见 [`V0_2_CLI.md`](V0_2_CLI.md)，
diskless 时序见 [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md)，状态机/协议栈见
[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md)。

## 1. 三程序总览

| 产物 | 角色 | 运行阶段 | 身份/凭据 | v0.2 是否实现 |
|---|---|---|---|---|
| `nodeforged` | 单进程守护进程：DHCP/TFTP/HTTP 协议栈 + 本机管理 API + 服务端 rootfs builder | 服务端常驻 | daemon 管理 API 自身鉴权 | 是（v0.1 已有 daemon，v0.2 扩 diskless/builder） |
| `nodeforge-initrd` | dracut 引导程序：拉 BootConfig、下载/校验/挂载 rootfs、写 target-system 投影、switch_root | initrd（switch_root 前） | node-bound capability token（仅 boot 传输） | 是 |
| `nodeforge-agent` | 切根后确定性顺序执行器：开机跑 first-boot 后处理 | 切根后运行期 | `nodeforge.node_id` cmdline/boot.json，无 enrollment | 是（仅 diskless） |

三者共享核心模块（`src/root.zig` 为 `nodeforge` 模块），避免行为分叉；当前 `build.zig` 仅产出
`nodeforged` 与 `nodeforge`（管理 CLI），v0.2 新增 `nodeforge-initrd` 与 `nodeforge-agent` 两个
executable，复用同一 core module。

## 2. nodeforged（守护进程）

v0.1 已实现单进程内置 DHCPv4/TFTP/HTTP 与本机管理 API。v0.2 在其上扩展：

### 2.1 功能列表

- DHCP/TFTP/HTTP 协议栈：按 canonical BootSession 状态机驱动引导
  （[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md) §2）。
- BootConfig 生成与投递：按 pinned DisklessEffectivePlan 在 boot 时生成 per-boot、per-Node 的
  短时 BootConfig DTO，经 node-bound capability token 拉取。
- node-bound rootfs HTTP GET/HEAD/Range：按 effective digest 共享 rootfs，token 绑定
  node/session/method/path 与短有效期。
- 服务端 rootfs builder：构建 squashfs lower（OS 层 + rootfs-build phase），按 digest 缓存
  （[`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §4）。
- effective compiler / readiness / validator：与 v0.1 同一编译结果（diskless 分支消费 pinned
  DisklessEffectivePlan）。
- 管理本机 API：复用 v0.1 management API 与 `admin_key` 鉴权。

### 2.2 实现要点

- builder 在与目标 distro/version/arch/`kernel_release` 一致的环境运行；按动作所需提供 chroot
  或 bind-mount `/dev`/`/proc`/`/sys` + 匹配内核（构建保真见 [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §4）。
- builder 不上节点、无节点 agent；rootfs-build 事件 `source=builder` 记入 build manifest/audit。
- management credential（daemon 管理 API 鉴权）与 boot 传输 token 是不同凭据类型、不同鉴权路径，
  不得互通（见 §5）。

## 3. nodeforge-initrd（dracut 引导程序）

### 3.1 为什么需要独立程序入口

initrd 阶段（`switch_root` 前）需要联网拉取 BootConfig、下载/校验 rootfs、写 overlay upper 并
完成 target-system 投影，这些是通用 dracut 不具备的 NodeForge 逻辑。v0.2 通过 `assets
nodeforge-initrd config/build` 在构建 dracut 时自动注入 `nodeforge-initrd` 作为引导模块，由其在
initrd 内完成上述职责。

### 3.2 功能列表

1. 从 kernel cmdline 读取 `nodeforge.config_url` 与 `nodeforge.node_id`（或 MAC/
   `pxe.ip_reservation`）。
2. 经 node-bound capability token 从 `config_url` 拉取 BootConfig（短有效期 token）。
3. 校验 BootConfig：feature 子集、`required_features`、`schema_version` v2、digest；缺失或冲突
   以稳定 error code 拒绝，不回退降级。
4. 下载/校验（sha512）/挂载 rootfs lower（HTTP GET/HEAD/Range 恢复）。
5. 建立 squashfs 只读 lower + tmpfs overlay upper。
6. 把 target-system 投影写 overlay upper：NM/Netplan 网络配置、hostname、`/etc/shadow` `$6$`
   hash、authorized_keys、machine-id、SSH host key。
7. 写 `/run/nodeforge/boot.json`（mode 0600，plan/config digest 与非 secret 摘要）。
8. `switch_root` 前清零 capability token。

### 3.3 实现要点

- **不负责** boot-time 网络“接管”：只写 NM/Netplan 配置到 overlay upper，`switch_root` 后由
  NM/Netplan 接管同一地址（initrd 不切换地址）。
- **不负责** first-boot 后处理：切根后由 `nodeforge-agent` 执行。
- 失败（hash mismatch、feature mismatch、过期 token、越权 Range、switch_root 失败）进入稳定
  error code、`diskless.failed` 和 quarantine，不静默降级。
- 静态编译为独立 executable，dracut module 声明依赖（网络、overlayfs、squashfs loop）。

## 4. nodeforge-agent（切根后执行器）

### 4.1 角色与边界

agent **仅服务 diskless**（diskless 无安装器，first-boot 是其后处理主路径）。它是确定性顺序
执行器：开机即跑 rootfs 烤入的 bundle first-boot steps，固定顺序、一次性，不接受远程任务下发、
不做 reconciliation、不做通用远程命令或配置管理平台。

### 4.2 功能列表

1. 切根后读取 `/run/nodeforge/boot.json` 取 `node_id`。
2. 按 pinned bundle revision 拉取 first-boot steps。
3. 固定顺序执行：文件更新 -> package -> archive -> script（八步执行契约见
   [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §5.2）。
4. 幂等：`(bundle revision, effective digest, node, phase, idempotency key)` 使已成功 step
   重跑时 no-op。
5. retryable 失败 step 在当次开机内按 step 声明重试，耗尽标 failed（节点仍启动、该 step 失败）。
6. 每 step 前后产生 `provision.step.started/succeeded/warned/failed`，经 `event_url` best-effort
   回传（带 `node_id`）。
7. 失败本地兜底（日志/console/boot.json），不阻塞执行、不回退已完成切根/后处理。

### 4.3 实现要点

- **无 enrollment/credential**：身份由 `nodeforge.node_id` cmdline 携带，initrd 写 boot.json，
  agent 读取。不引入运行期节点认证 secret。
- **无远程控制**：reconciliation/远程控制为永久非目标；agent 开机确定性顺序执行，无 drift 重跑、
  无远程任务下发。
- **无独立 first-boot retry CLI**：重启即重跑（确定性+幂等保证安全）；`node diskless retry` 仅清
  boot-level quarantine 以允许重新 PXE。
- 脚本 stdout/stderr 仅留最后 2048 bytes 转义摘要；token/未声明输出不得进服务日志或 Event。
- 一次性语义：每次开机执行一次（overlay upper 为 tmpfs、per-boot 易失），非“跨重启只跑一次”，
  也非 `runtime` 周期。

## 5. credential 边界澄清

“credential”在 v0.2 指两类互不相同的凭据，**不含**已永久移除的 enrollment：

| 凭据 | 类型 | 鉴权路径 | 权限 | 生命周期 |
|---|---|---|---|---|
| boot 传输 token | per-boot 传输鉴权 | initrd 拉 BootConfig/rootfs | 仅该 Node 的 GET/HEAD/Range config/rootfs + event POST | 短有效期，switch_root 前清零 |
| management credential | daemon 管理 API 鉴权 | 服务端管理员 | catalog 写、管理 API 全权限 | daemon 常驻 admin_key |

- 传输 token 不能访问其他 Node rootfs、不能升级为 management credential（防 per-boot token 被滥用
  为服务端管理权限）。
- **enrollment**（运行期节点认证 secret）已永久移除，与上述 token 无关：token 仅是 boot 期 initrd
  拉取 BootConfig/rootfs 的传输鉴权，agent 身份由 `nodeforge.node_id` cmdline 携带。

## 6. 三者协作时序

```text
nodeforged 生成 BootConfig（per pinned DisklessEffectivePlan）
  -> DHCP/TFTP 引导 boot bundle（kernel + nodeforge-initrd）
  -> nodeforge-initrd: 拉 BootConfig、下载/校验/挂载 rootfs、写 overlay upper、switch_root
     （switch_root 前清零 token）
  -> nodeforge-agent: 读 boot.json(node_id)、固定顺序执行 first-boot、best-effort 回传事件
```

install Profile 的 BootSession 在 `boot_config_fetched` 完成交付后终止，无 nodeforge-agent
（install 侧 agent 延后 v0.4，且同样无 reconciliation）。nodeforge-agent 在 v0.2 仅 diskless 有。

## 7. v0.3/v0.4/v0.5 的程序边界

- v0.3（PXELINUX/BIOS install）：增加 `install-post` phase，由安装器（Kickstart `%post`/
  Autoinstall `late-commands`）执行，无 nodeforge-agent；`firmware.mode` schema v5。
- v0.4（延后增强项）：install 侧 first-boot agent（确定性，无 reconciliation）；远程/节点上构建
  rootfs（agent 驱动）；多 NIC/VLAN/bonding 与容量压测。reconciliation/远程控制仍为永久非目标。
- v0.5：可切换 rootfs 形态（`ram_rootfs`、`diskless.overlay.mode` 字段），见
  [`V0_5_DESIGN.md`](V0_5_DESIGN.md)。
