# NodeForge 无盘系统最终方案（v0.2 收敛）

状态：设计收敛基线。本文是 v0.2 diskless 主流程的事实源，与
[`V0_2_DESIGN.md`](V0_2_DESIGN.md) 一致；实现细节见
[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md)，程序边界见
[`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md)，CLI 见
[`V0_2_CLI.md`](V0_2_CLI.md)，从零构建/启动操作闭环见
[`V0_2_DISKLESS_WORKFLOW.md`](V0_2_DISKLESS_WORKFLOW.md)。v0.5 的可切换 rootfs 形态见
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

- **lower**：squashfs 单文件镜像，由服务端 rootfs builder 构建，按 `rootfs_input_digest` 缓存、
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
v0.2 用 UEFI GRUB + 标准 PXE DHCP/TFTP 已足够；PXELINUX/BIOS 属 v0.3。

## 4. 共享 rootfs 构建模型

取消 variant / 暴露的 base rootfs 两层概念，收敛为**单一共享 rootfs**：

```text
rootfs = OS 层 + rootfs-build phase 业务内容 + Profile target-system 骨架
       + first-boot fixed-revision manifest/payload（只预置，不在 build 期执行）
```

- **OS 层**：从 boot bundle 固定 revision 的 install source/repository capability 用发行版原生 rootfs 工具构建
  （RHEL/Rocky 默认 `dnf --installroot`；Ubuntu 默认 debootstrap + local apt；lorax/livecd 仅在 adapter
  明确声明时使用），在与目标
  distro/version/arch/`kernel_release` 一致的环境中运行。builder 消费与 Profile 查询相同
  的 environment/group/task/package selection，按 local-only 移除公网 mirror/metalink/
  GeoIP/vendor NTP，只引用本地 repository。OS 层可按 software capability revision 内部
  缓存复用，但对设计透明、不作为独立 Resource。
- **rootfs-build phase**：在 OS 层之上向只读 lower 追加业务内容（managed-file、archive、
  受控 script、经本地 repo 解析的 package）。由服务端 rootfs builder 执行（无节点 agent），
  builder 提供 chroot/staging 上下文使步骤以 `/` 为目标写入 lower。
- **first-boot payload**：builder 把固定 revision/digest 的 first-boot manifest、managed file/archive/script asset 和 package
  closure 预置到 `/usr/lib/nodeforge/firstboot/<bundle-digest>/`，但不执行。agent 切根后只读本地 payload，
  不用 event token 拉步骤/包，不依赖 repository revision 在启动途中保持不变。package action 必须离线安装
  预解析闭包；缺依赖在 build 阶段失败。
- **rootfs input digest**：OS/source/repository revisions + rootfs-build inputs + first-boot fixed payload +
  build-safe Profile/effective system/software + builder ABI 共同决定；rootfs 按该 digest 缓存、跨 Node 共享。

**构建环境保真**：纯 userspace 动作只需 chroot；触及硬件/内核的动作（装驱动、dkms、重生成
initramfs、装载内核模块）须 bind-mount `/dev`/`/proc`/`/sys` 并使用与目标 distro/version/arch/
`kernel_release` 一致的内核（内核与 OS 一致时加载完整内核态）。更高保真的远程/节点上构建
延后 v0.4。详见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §4.4。

## 5. BootConfig 与启动时序

BootConfig 是 **per-boot、per-Node 的短时 DTO**，由服务端按 session 的 immutable DisklessEffectivePlan snapshot 在
boot 时生成，initrd 经 node-bound capability 拉取。它只携带动态/按节点参数，**不烤入 rootfs
lower**，故 lower 可共享、per-Node 差异只落 overlay upper。

启动时序（`switch_root` 前由 initrd 完成）：

1. DHCP/TFTP 引导 boot bundle（kernel + 共享 NodeForge initrd）和 per-session credential capsule；GRUB 将
   极小 capsule 作为第二个 initrd cpio 追加加载。kernel cmdline 只携带无密钥的
   `nodeforge.config_url`、node/session identity 与 `kernel_args`。
2. initrd 起后从 `config_url` 拉 BootConfig（一次性 config token），校验 DTO、计划 snapshot、时钟窗口和
   feature，再取得只读 artifact token 与只写 event token。
3. initrd 先完成 rootfs HEAD/Range 下载、整文件校验，再建立 lower/upper/work/merged；之后把
   target-system 投影写入 merged root（NM/Netplan 网络、hostname、`/etc/shadow` `$6$` hash、
   authorized_keys、machine-id、SSH host key）。禁止在未校验镜像上执行或写投影。
4. initrd 做 pre-switch 验证，原子写交接目录，撤销并清零 config/artifact token；只把短时、只写的
   event token 以 0400 文件交给切根后的 agent。
5. `switch_root` 后 NM/Netplan 接管同一地址，agent 开机顺序执行 `first-boot` 后处理；完成后删除
   event token。token 过期或事件回传失败不影响本地后处理结果。

BootConfig 除 `$6$` password hash 与 public authorized key 外不含长期 secret。传输能力拆成三种不可互换的
scope：`config:read`（一次性）、`artifact:read`（rootfs/manifest/bundle GET/HEAD/Range）和
`event:append`（限定本 session 的事件 POST）。三者都绑定 node、session、audience、method/path、计划
digest 与绝对过期时间，不能访问其他 Node、不能列目录、不能写 catalog，也不能升级为 management
credential。`/run/nodeforge/boot.json` 只保存 plan/config digest 与非 secret 摘要，mode 0600；短时
`event:append` token 单独保存于 `/run/nodeforge/credentials/event.token`，mode 0400，不能进入 boot.json、
日志或进程 argv。initrd 在 `switch_root` 前清零 config/artifact token，agent 结束后清零 event token。
BootConfig DTO 自身 `schema_version` v2（与 catalog schema v3/v4 分属不同命名空间），
使用 `kind` 判别字段（与 `ProfileKind` 一致），废弃 legacy `mode="diskless"`。

`required_features` 至少枚举稳定 token：`target-system-v1`、`static-network-v1`、
`sha512-crypt-v1`、`bootstrap-admin-key-v1`、`target-accounts-v1`；initrd 在 boot bundle manifest
中声明支持的 feature 子集，缺失或冲突在 `switch_root` 前以稳定 error code 拒绝，不得回退降级。

### 5.1 BootConfig v2 最小契约

BootConfig 是签名/认证通道内的 canonical JSON；字段排序不参与 digest，digest 对 RFC 8785 风格的 canonical
JSON 计算 SHA-256。未知顶层字段默认拒绝，只有 `extensions` 容器允许前向扩展。

| 字段 | 约束 |
|---|---|
| `schema_version` / `kind` | 固定 `2` / `diskless` |
| `node_id` / `boot_session_id` | 必须与 cmdline、token claim 和服务端活动 session 全部相等 |
| `plan_digest` / `config_digest` | 64 位小写 hex；plan 与 session snapshot 相等，config 是去除 token 后 DTO 的 digest |
| `issued_at` / `not_before` / `expires_at` | 服务端 UTC 秒；允许最大 120 秒时钟偏差，窗口最长 2 小时 |
| `rootfs` | 固定 digest 算法 `sha512`、hex digest、字节 `size`、`etag`、manifest digest、URL |
| `overlay` | v0.2 固定 `tmpfs_percent`、`minimum_free_bytes`；不存在 mode 字段 |
| `network` | 启动 NIC MAC、PXE 地址、目标 renderer、DHCP 或静态 IPv4 投影 |
| `target_system` | hostname、账号 hash/public keys、locale/timezone/keyboard 的最终投影 |
| `required_features` | 排序去重的稳定 token；必须是 initrd manifest features 的子集 |
| `artifacts` / `events` | 不透明 URL + 分域 token；URL host 必须是配置的 `server_ip` 字面地址 |

kernel cmdline 只允许携带无密钥的 `nodeforge.config_url`、`nodeforge.node_id`、`nodeforge.session` 和已编译的
`kernel_args`，不得携带 password hash、任何 token 或整份 JSON。config token 位于 per-session
`credential.cpio` 的 initramfs 私有路径 `/nodeforge-credentials/config.token`（0400）；GRUB 用多个 `initrd` 参数/条目把它
追加到共享 initrd。capsule 路径含不可猜 session id，TFTP/HTTP resolver 还须校验发起 IP 对应的活动 DHCP
session；capsule 单次下载、短 TTL、日志全量脱敏。它只改善静态泄露面，不提供链路机密性，隔离 VLAN/ACL 仍是硬要求。

### 5.2 initrd 确定性流水线

initrd 每一步写本地有界 journal，成功后 `fsync` 再推进；重入只允许在同一 session、同一 plan/config
digest 内从安全检查点继续。具体顺序固定如下：

1. **early mount**：先从 initramfs 私有路径读取并 unlink capsule token，再挂载 `/proc`、`/sys`、`/dev`、
   `/run` 并解析 cmdline；重复 key、未知 `nodeforge.*` key、token owner/mode/session 不匹配或格式错误立即失败。
2. **network-up**：只激活 DHCP 已使用的启动 NIC；校验其永久 MAC 等于 BootConfig。v0.2 不切 NIC、
   VLAN 或地址，不做 DNS。
3. **config**：带 config token GET 一次，限制响应头 32 KiB、body 1 MiB、重定向 0 次；校验身份、时间、
   canonical digest、feature 和 URL allowlist。
4. **memory gate**：读取 `/proc/meminfo`，确保 `rootfs.size + tmpfs_upper_budget + initrd_reserve +
   safety_margin <= MemAvailable`。v0.2 的 squashfs 文件同样下载进 tmpfs，因此不能宣称“不需要预算”。
5. **download**：目标为 `/run/nodeforge/image/rootfs.part`；先 HEAD 固定 ETag/size，再按连续 Range 下载。
   每次响应必须为 206、`Content-Range` 起点准确、ETag 不变；200 仅允许首次完整 GET。最大 4 MiB chunk，
   指数退避带抖动，总次数和总时长有界。
6. **verify**：文件大小精确匹配后，对完整文件计算 SHA-512；不信任分块 hash。首次 mismatch 删除 partial
   后完整重下，第二次 mismatch 终止并 quarantine 计数。
7. **mount**：只读 loop 挂载 squashfs 到 `lower`；tmpfs 挂载到独立 `upper-tmpfs`，创建同一文件系统内的
   `upper`/`work`，以 `nodev,nosuid` 挂载 overlay 到 `merged`。lower 必须 `ro,nodev`。
8. **project**：所有 per-Node 文件先写临时文件、校验 owner/mode/语法，再 rename；生成新的随机
   machine-id 和 SSH host key。失败时销毁 merged/upper，不污染共享 lower。
9. **pre-switch**：确认 `/sbin/init` 可执行、renderer/unit/agent 存在、DNS/route/账号文件可解析、
   `/run` move-mount 可持续；写 boot.json、event token 和 journal，均禁止跟随 symlink。
10. **handoff**：POST `switching_root`，撤销/清零 config/artifact token，move-mount `/dev`、`/proc`、
    `/sys`、`/run`，以 merged 为新根执行 `switch_root ... /sbin/init`。exec 返回即视为失败。

禁止直接把下载流 pipe 给 mount、在 digest 校验前解析 squashfs、接受 HTTP redirect/content-encoding、跨 ETag
拼接 partial，或失败后回退本地磁盘/NFS/旧 rootfs。

#### 5.2.1 pre-switch 与 `/run` handoff 到底是什么

`pre-switch` 是“最后一次还能安全留在 initrd 里报错”的提交闸。它检查 merged root 的 `/sbin/init`、动态库、
renderer 配置、agent/unit、rootfs/kernel modules ABI、挂载选项、目标 `/run` 目录和凭据 owner/mode；任何一项失败
都不执行 switch_root。它不是 first-boot，也不修改共享 lower。

`/run handoff` 是把 initrd 阶段的 `/run` tmpfs **move-mount** 到 `merged/run`，再切根；不是把文件复制进
rootfs upper。交接前 mount propagation 设为 private，目录布局固定：

```text
/run/nodeforge/boot.json                 0600 root:root，非 secret session 摘要
/run/nodeforge/journal.json              0600 root:root，initrd 检查点
/run/nodeforge/credentials/event.token   0400 root:root，短时 append-only token
/run/nodeforge/image/rootfs              rootfs 下载文件，由 loop mount 持有
```

这样新系统看到的是同一个 tmpfs/loop backing，loop lower 不因旧 initrd root 被回收而失效，agent 也能取得同一
session 的 handoff 事实。`nodeforge-handoff.service` 在 agent 前验证目录不是 symlink、owner/mode/digest/session
正确；agent 完成后删除 event token，systemd 后续正常管理继承的 `/run`。若 move-mount 或验证失败，状态为
`diskless.failed`，不能用复制 token 到 `/etc`、重建 session 或匿名上报绕过。

### 5.3 网络接管与“无缝”定义

v0.2 的接管不是重新配网，而是保持启动 NIC、MAC、IPv4 地址、prefix、gateway 和 MTU 不变：

- DHCP 模式：initrd 保留 lease 文件与 lease 元数据到 `/run/nodeforge/network/`，target renderer 以同一
  MAC 启动；允许 DHCP renew，但 renew 前不得主动 flush 地址。服务端 reservation 必须等于 PXE 地址。
- 静态模式：BootConfig 地址必须等于 PXE reservation；initrd 先写 renderer 配置但不 apply，切根后 renderer
  adopt 同一地址。地址冲突探测失败在下载前终止。
- agent 启动 unit 必须 `After=network-online.target nodeforge-handoff.service`，但网络超时只影响远端事件，
  不阻止本地 first-boot。renderer 接管后连续 ping 服务端不是成功判据；成功判据是地址/route 未出现空窗、
  默认路由未漂移，且服务端 event 可 best-effort 到达。

### 5.4 服务重启与断点续传

v0.2 明确支持 daemon 重启后恢复**投递**，不恢复内存中的旧 socket：BootSession、计划快照、capability
claim 的不可逆 hash、过期时间、rootfs snapshot ref 和最后确认 phase 必须原子持久化。原始 token 永不落盘。

- initrd 重试时用现有 token + session id 重新认证；服务端从 token hash 找到未过期 session，仅在 plan/rootfs
  digest 相同且 session 未终止时恢复。无法验证就返回 401/410，initrd 进入稳定失败，不创建影子 session。
- Range 恢复由客户端 partial 长度与服务端 immutable ETag 决定；服务端不保存 offset。`If-Range` 不匹配返回
  200 时，客户端必须先截断 partial 再完整接收，绝不能 append。
- v0.2 不回收已经发布的 rootfs object；rename 发布镜像与 manifest 后才能 ready。daemon 重启发现未发布的
  staging `.part` 可作为失败构建残留清理，但这不是已发布 rootfs GC。
- session 过期由 wall clock 判定，退避/无进展 timeout 用 monotonic clock；重启后 monotonic 基准重建，不得因
  wall-clock 回拨延长 token。

#### 5.4.1 delivery snapshot ref 到底是什么

它是 BootSession 中固定的不可变引用：`desired plan digest + boot bundle revisions + rootfs content digest +
BootConfig schema`。作用是保证一次启动从 DHCP 到 switch_root 始终使用同一套内容；Profile 修改、新 rootfs 构建或
daemon 重启都不能让在途 session 中途换版本。它不是 GC 引用计数，也不需要释放后触发删除。v0.2 已发布 rootfs
只增不删；容量通过 `nodeforge status --component rootfs-cache` 告警，回收策略留给有真实容量数据的后续版本。

### 5.5 状态、失败归责与超时

服务端状态只能由可验证证据推进：DHCP/TFTP 由服务端协议栈产生；`diskless.initrd_started` 以后只接受 event token
签名的单调事件。`diskless.running` 表示 PID 1 已启动、网络接管已尝试且 agent unit 已进入执行，不等价于
first-boot 全部成功。

| 阶段 | 无进展超时 | 失败责任域 |
|---|---:|---|
| DHCP offer/ack | 60 s | `network.dhcp.*` |
| TFTP bundle | 10 min | `transport.tftp.*` |
| BootConfig | 2 min | `config.*` / `auth.*` |
| rootfs download | 30 min，且 5 min 无字节推进 | `artifact.*` / `transport.http.*` |
| verify/mount/project | 各 10 min | `integrity.*` / `mount.*` / `projection.*` |
| switch_root/running | 5 min | `handoff.*` |

稳定 reason 必须是枚举（例如 `artifact.etag_changed`、`integrity.rootfs_mismatch`、
`network.identity_mismatch`、`projection.invalid_network`、`handoff.exec_returned`），人类摘要另存且最多
512 bytes。仅 Node/配置/镜像确定性错误和重复完整 hash mismatch 消耗 failure budget；服务端重启、瞬时网络
超时等 retryable 基础设施错误记录 attempt，但在重试耗尽前不 quarantine。相同 node + plan digest 的失败计数；
desired digest 变化会关闭旧计数并开始新 bucket，保留旧审计。

## 6. 切根后 first-boot 后处理

切根后由 node-bound agent（`nodeforge-agent`，见 [`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md)）
开机顺序执行 `first-boot` 后处理：

first-boot 是**可选的运行根初始化阶段**，不是 diskless 启动所必需的补丁阶段。共享且可在构建环境确定的
内容必须放 `rootfs-build`；hostname、网络、账号、authorized_keys、machine-id、SSH host key 等核心
target-system 必须由 initrd 在切根前投影。只有依赖真实运行内核、`/sys`、systemd 或节点上下文的受控动作
才放 first-boot，例如 vendor agent finalization、节点缓存生成或本地服务注册。所有输入在 rootfs build 时
按 digest 预置，agent 不远程拉取可变步骤。禁止公网更新、远程任务、
持续 reconciliation，以及“rootfs 缺什么开机再装什么”的半成品模式。

- **一次性**：每次开机执行一次（overlay upper 为 tmpfs、per-boot 易失），非“跨重启只跑一次”，
  也非 `runtime` 周期。
- **固定顺序**：文件更新 -> package -> archive -> script（八步执行契约见
  [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §5.2）。
- **确定性 + 幂等**：幂等键 `(boot session, bundle revision, desired plan digest, node, phase,
  idempotency key)` 只在本次启动的 `/run` journal 内去重；新的 PXE 启动拥有新 session，仍会执行全部
  first-boot step。retryable 失败 step 在当次开机内按 step 声明重试，耗尽标 failed
  （节点仍启动、该 step 失败）。
- **状态/异常回传**：经 `event_url` best-effort 回传（带 `node_id`），失败本地兜底
  （日志/console/boot.json），不阻塞执行、不回退已完成切根。
- **无远程控制/无 reconciliation**：agent 不接受远程任务下发、不做 drift 重跑。重新触发完整
  first-boot = 重启节点重新 PXE 引导；`node diskless retry` 清 boot-level quarantine 以允许
  重新 PXE，不改 Profile、不远程重启。

生命周期与后处理严格分离：`diskless.running` 是 Node 唯一 current state；first-boot 结果只作为
`postprocess=not-configured|running|succeeded|degraded` 附属摘要。step failed 不回退 lifecycle，也不会产生
第二个 install/diskless 状态。若 Profile 没有 first-boot item，agent 只验证 handoff、上报 running 并结束。

## 7. local-only 不变式

v0.1 删除 `system.connectivity.mode`（曾取值 `local-only`），因 `local-only` 是唯一行为、无选择
意义。v0.2 承袭为不变式：

- rootfs/initrd 恒 `local-only`：移除/禁用公网 mirror、metalink、GeoIP、vendor NTP，只引用本地
  repository；不新增 `local-only` PropertySpec，不存在 online 变体。
- v0.2 的 HTTP bearer 只在隔离 `local-only` 网络内提供认证，不提供链路机密性；跨不可信网络的
  TLS/mTLS 与远程管理仍是非目标，部署必须以隔离 VLAN/ACL 防止旁路窃听。

## 8. 验收不变式

- v0.2 不存在 NFS root、iPXE、`diskless.overlay.mode` 字段、`ram_rootfs` 路径或其 help/enum。
- rootfs lower 按 `rootfs_input_digest` 跨 Node 共享；per-Node 差异只经 BootConfig 落 overlay upper。
- `switch_root` 前 initrd 完成 target-system 投影写入（网络由 NM/Netplan 接管同一地址）。
- 切根后 agent 开机顺序执行 first-boot，固定顺序、一次性、确定性+幂等，无远程控制/reconciliation。
- 首次 hash mismatch 必须删 partial 后完整重试；重复完整 mismatch、feature mismatch、过期 token、越权
  Range、switch_root 失败都进入稳定
  error code、`diskless.failed` 和 quarantine。
