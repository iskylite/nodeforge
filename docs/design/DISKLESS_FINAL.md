# NodeForge 无盘系统最终方案（v0.2 收敛）

状态：v0.2 架构分册，设计收敛。总纲与版本边界以 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) 为准；本文只负责
squashfs overlay、共享 rootfs、BootConfig 以及启动、恢复和安全时序的规范性架构。实现细节见
[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md)，程序边界见
[`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md)，CLI 见
[`V0_2_CLI.md`](V0_2_CLI.md)，从零构建/启动操作闭环见
[`V0_2_DISKLESS_WORKFLOW.md`](V0_2_DISKLESS_WORKFLOW.md)。

本文不维护完整 CLI 语法、代码模块任务或操作教程；其中的命令和模块名只用于解释架构。

## 1. 设计目标与排除项

v0.2 的 diskless 只交付一条主流程：**节点经 PXE 引导 → 拉取共享 rootfs →
内存 overlay 切根 → agent pre-init 应用 Node node-apply 并 exec 真正 init → systemd agent unit 执行 effective
first-boot 后处理**。目标是让
diskless 主流程完备可用，不追求 VMware 无法验证或非主流程的增强。

明确排除（详见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §7）：

- NFS root（任何形态）、iPXE 菜单/脚本。
- 多 NIC/VLAN/bonding、下载后切换目标地址/子网 → v0.4；PXE 继续使用 DHCPv4，稳定地址由
  `pxe.ip_reservation` 提供，不新增绕过 DHCP 的静态启动链。
- rootfs 固定由 nodeforged 服务端生成；diskless Node 只消费 ready artifact。
- 持久化 overlay、跨重启 rootfs partial → 永久非目标，具体语义见下文。
- reconciliation/远程控制、可续期 enrollment credential → 永久非目标；per-boot 短时 capability token 保留。

## 2. 选型结论：squashfs_overlay

经开源情报对比（见 §3），v0.2 固定 **`squashfs_overlay`** 为唯一 rootfs 形态：

```text
squashfs_overlay = squashfs 只读 lower + tmpfs overlay upper
```

- **lower**：squashfs 单文件镜像，由服务端 rootfs builder 构建，按 `rootfs_input_digest` 缓存、
  跨 Node 共享，经 HTTP GET/HEAD/Range 下载、sha512 校验、loop 挂载为只读。
- **upper**：tmpfs 写入层，per-boot 易失。initrd 只建立/挂载 upper，不写 target-system；`switch_root` 后
  `nodeforge-agent pre-init` 在真正 init 前写入完整 Node override，first-boot 业务输出随后继续写 upper。

选择理由：

1. 只读层保持压缩 squashfs，不必把整个 rootfs 解压进内存，内存占用可控，VMware 与实机均可验证。
2. 共享 lower + per-Node 差异落 upper 的模型天然契合 AgentPlan “动态参数不烤入 lower”
   的不变式（见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §4.3）。
3. 读写覆盖语义成熟（overlayfs），无需自研联合挂载。

## 3. 开源情报对比

| 方案 | 内存占用 | 共享性 | 复杂度 | v0.2 结论 |
|---|---|---|---|---|
| **squashfs + overlay tmpfs**（本文） | 中（压缩 lower + 写时 upper） | lower 跨 Node 共享 | 低，overlayfs 原生 | **采纳** |
| NFS root | 低（rootfs 留服务端） | 服务端单点、依赖网络常驻 | 低但违背离线/local-only | 排除 |
| iPXE 菜单/脚本引导 | 不提供 rootfs 形态 | — | 引入第二引导栈 | 排除 |

NFS root 被 local-only 不变式（公网 mirror/metalink 必须移除）与“切根后独立运行”目标共同
否决；rootfs 必须能下载到本地内存后离线切根。iPXE 引入额外引导栈与 firmware 兼容负担，
v0.2 用 UEFI GRUB + 标准 PXE DHCP/TFTP 已足够。

## 4. 共享 rootfs 构建模型

每个 diskless Profile 收敛为**单一共享 rootfs**：

```text
rootfs = OS 层 + rootfs-build phase 业务内容 + Profile target-system 骨架
       + first-boot fixed-revision manifest/payload（只预置，不在 build 期执行）
```

- **OS 层**：从 boot bundle 固定 revision 的 install source/repository capability 用发行版原生 rootfs 工具构建
  （RHEL/Rocky 默认 `dnf --installroot`；Ubuntu 默认 debootstrap + local apt；lorax/livecd 仅在 adapter
  明确声明时使用），在与目标
  distro/version/arch/`kernel_release` 一致的环境中运行。builder 消费与 Profile 查询相同
  的 environment/group/task/package selection，按 local-only 移除公网 mirror/metalink/
  GeoIP/vendor NTP，只引用 daemon 本机 `repos_dir` 的受管 `file://` repository。该
  构建期地址不写入目标 rootfs；目标系统仍使用 AgentPlan 固定的受管 HTTP URL。OS 层可按 software capability revision 内部
  缓存复用，但对设计透明、不作为独立 Resource。

  多 variant ISO（如 Rocky 10.2 DVD 的 AppStream + BaseOS）的 install source 引用多个
  repository，`buildRepositoryClosure` 自动合并所有 variant 的本机 `file://` URL，dnf 在
  `--installroot` 时同时消费 AppStream 和 BaseOS 的包元数据。
- **rootfs-build phase**：在 OS 层之上向只读 lower 追加业务内容（managed-file、archive、
  受控 script、经本地 repo 解析的 package）。由服务端 rootfs builder 执行（无节点 agent），
  builder 提供 chroot/staging 上下文使步骤以 `/` 为目标写入 lower。
- **first-boot payload**：builder 把 Profile 固定 revision/digest 的 first-boot manifest、managed file/archive/script asset 和 package
  closure 预置到 `/usr/lib/nodeforge/firstboot/<bundle-digest>/`，但不执行。agent 切根后只读本地 payload，
  不用 event token 拉步骤/包，不依赖 repository revision 在启动途中保持不变。package action 必须离线安装
  预解析闭包；缺依赖在 build 阶段失败。Node 可用 `overrides.diskless.provision.bundle` 完整替换自身 first-boot；
  该 first-boot-only payload 不进公共 rootfs，由 agent pre-init 切根后从服务端按 immutable AgentPlan 下载、校验到 `/run`。
- **rootfs input digest**：OS/source/repository revisions + rootfs-build inputs + first-boot fixed payload +
  Profile system/software/target-system + builder ABI 共同决定；明确排除全部 Node 输入。它是 canonical 输入的
  确定性指纹，不是加密，也不是成品 squashfs 的内容校验和。

**构建流水线（6 阶段）**。rootfs builder 按固定顺序执行，每阶段输出可审计日志：

1. **Stage 1 — OS 层**：发行版原生 install-root 工具（RHEL/Rocky `dnf --installroot`，Ubuntu debootstrap）从受管
   repository 构建 chroot-able 基线，安装 systemd/udev/网络 renderer/包管理器/SSH/nodeforge-agent/modules/firmware。
2. **Stage 2 — Payload 物化**：将 rootfs-build phase 的 content_asset（managed-file/archive）物化到 chroot 内
   payload 目录，为后续 step 执行准备输入。
3. **Stage 3 — rootfs-build 步骤**：按 managed-file → package → archive → script 固定顺序执行 rootfs-build items，
   把业务内容追加到只读 lower。同时预置 first-boot manifest/assets/package closure（不执行）。
4. **Stage 4 — Target-system 骨架**：写入 Profile 级 target-system 基线（账号、hosts、sshd policy、locale/timezone/
   keyboard），清除 machine-id/DHCP lease/缓存/临时文件/builder resolv.conf/随机种子。
5. **Stage 5 — SSH 信任基线**：自动生成 ed25519 client keypair + sshd host key，合并 Profile `root_authorized_keys`
   与自动生成的 client public key 到 `authorized_keys`，写入 `sshd_config.d/00-nodeforge.conf` 启用公钥认证。
   密钥烤入只读 lower，同 Profile 节点共享同一信任域。
6. **Stage 6 — squashfs 压缩 + SHA-512 + 原子发布**：`mksquashfs`（zstd 压缩）输出内容寻址 `.part` 文件，
   流式 SHA-512 校验，原子 rename 发布 ready manifest。

**构建环境保真**：纯 userspace 动作只需 chroot；触及硬件/内核的动作（装驱动、dkms、重生成
initramfs、装载内核模块）须 bind-mount `/dev`/`/proc`/`/sys` 并使用与目标 distro/version/arch/
`kernel_release` 一致的内核（内核与 OS 一致时加载完整内核态）。所有构建均保留在 nodeforged
服务端。详见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §4.4。

跨重启本地状态与 Profile SSH 基线的语义分别如下；它们不影响服务端持久保存 catalog、rootfs 成品和审计记录：

- **持久化 overlay**：upper/work 使用 tmpfs；节点重启后，本次运行对 `/etc`、`/var` 等根文件系统的修改全部丢失。
  要长期保留的配置必须进入 Profile/rootfs build/AgentPlan，业务数据必须使用另行管理的外部存储。
- **跨重启 rootfs partial**：`rootfs.part` 只允许在同一 BootSession、同一次 initrd 运行中通过 HTTP Range 断点续传。
  节点重启后内存中的 partial 不存在，新 session 从头下载；这不影响 daemon 重启后继续服务同一尚存活 session。
- **Profile 共享 SSH keys**：Profile create/clone 的 rootfs-build preparation 生成并固定用于节点主动登录的
  SSH client 公钥/私钥，以及 sshd 完成服务端握手必需的 host keys，并全部写入共享 rootfs。client public key 作为
  mandatory 域内 key 写入共享 rootfs 的 `authorized_keys`；Profile 配置的管理/其他节点公钥由 node-apply 以
  Node effective 计划合并写入节点 `authorized_keys`，使同 Profile 节点相互免密且重启后保持一致。这是
  Profile 信任域的显式产品语义。host fingerprint 是共享 host public key 的 SHA256 摘要；同 Profile 节点
  fingerprint 相同，这是信任整个 Profile 域的预期行为，不承担 Node 唯一身份。rootfs 同时写
  `/etc/ssh/ssh_known_hosts`，将 localhost/127.0.0.1 与 `*` 通配绑定到该共享 host public key，域内首次连接
  也无需人工确认。自动生成的 client public key 是 mandatory 域内 key，标准 Node `authorized_keys.remove`
  只作用于 effective 计划中的操作员公钥；Node hosts override 以 effective hosts 和同一 host public key 重算
  该节点 `ssh_known_hosts`。若 Profile hosts 覆盖 100 个节点且没有显式后处理破坏 SSH 文件，这 100 个节点彼此均免密，
  并看到同一个 Profile host fingerprint。

  > **实现现状（v0.2.3 已更新）**：rootfs builder 的 Stage 5 SSH 信任基线已改为从 identity store 按
  > `(ssh_identity.id, revision)` 复合键读取（`rootfs_os_builder.installIdentityKeys`，dnf 与 casper/apt
  > 两分支一致），写入 client/host ed25519 keypair、`/root/.ssh/authorized_keys`（含 mandatory client
  > public key）、`/etc/ssh/ssh_known_hosts`（`localhost,127.0.0.1,*` 绑定共享 host public key）与
  > `sshd_config.d/50-nodeforge-default.conf` drop-in（`PubkeyAuthentication`、`PermitRootLogin
  > prohibit-password`）。构建期不再调用 `ssh-keygen`；identity 缺失/引用为空返回 `IdentityNotFound`
  > fail closed。将 Profile `system.hosts` 声明的全部 address/names/aliases 显式绑定到
  > `ssh_known_hosts`、以及 Node hosts override 以 effective hosts 重算节点 `ssh_known_hosts`
  > 为后续完善点（当前以 `*` 通配覆盖）。
- **Profile 共享 password hash**：明文 password 仍按 v0.1 desired 契约配置，但 diskless Profile credential revision
  只生成一次带 CSPRNG salt 的 `$6$` hash 并安全持久化；普通重建复用同一 hash，避免同输入 rootfs 因 per-session salt
  失去可复现性。显式改密码才发布新 Profile revision/input digest；install Profile 的 v0.1 行为不变。
- **重建时换全部 SSH keys（v0.2.3 已实现）**：`profile rootfs build --new-ssh-keys` 在 identity store 中创建
  新 identity revision（同 `id`、`revision + 1`，旧 revision 保持不可变），发布递增 `ssh_identity.revision`
  的 Profile revision，再以新投影构建新 rootfs（`authorized_keys`/`ssh_known_hosts` 随新 keypair 重算）；
  自动化需锁定已预览输入时再加 `--if-input-digest <current>`。失败边界区分
  `identity.create_failed`/`catalog.publish_failed`/`rootfs.build_submit_failed`（见
  [`V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md`](V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md) §3.3）。旧
  artifact/active session 不变；新旧 rootfs 混跑时双向免密不保证，host fingerprint 也会变化。

## 5. BootConfig 与启动时序

BootConfig 是给 initrd 的 **per-boot、per-Node 最小 DTO**，由服务端按 session 的 immutable
DisklessEffectivePlan snapshot 在 boot 时生成，initrd 经 node-bound capability 拉取。当前 v3 只携带
rootfs/overlay、AgentPlan locator、event/facts URL、expiry 和必要的 session identity，不携带
users/SSH/hosts/software 等完整 Node 配置。PXE lease/MAC/prefix/gateway 来自 GRUB cmdline 与 BootSession，
不在 BootConfig v3 内重复编码；consumer feature 由 boot bundle manifest/readiness 校验，不是 v3 字段。

AgentPlan 是给最终 rootfs agent 的 **唯一执行配置**。服务端按同一 snapshot 把 Profile + Node effective 结果编译为
唯一 `node_apply_projection`，包含 hostname、网络、machine-id、password hash、users、authorized_keys add/remove、
hosts/known_hosts、sshd、本地化/NTP/security、software/service exact transaction 和可选 Node first-boot descriptor。
agent 不在节点侧重新 merge Profile/Node，也不读取“最新”catalog。Profile 完整基线已在 rootfs；AgentPlan 只交付
Node effective 差量，不重复交付 Profile SSH private keys。

### initrd DHCP 客户端边界

`nodeforged` 的内置 DHCP 实现是监听 UDP/67、分配租约并生成 PXE 响应的 server，不能作为启动节点上
监听 UDP/68、执行 DISCOVER/OFFER/REQUEST/ACK 并配置本地地址/路由的 client 复用。NodeForge overlay
还会以自己的 `/init` 接管 PID 1，因此不能假定 vendor dracut/NetworkManager 的正常 hook 已经执行。

initrd 网络初始化按以下顺序收敛：先用 `SIOCGIFADDR` 查找已经持有 PXE reservation IP
的接口；若内核/vendor initramfs 尚未配置该地址，再按 DHCP/TFTP identity 携带的 PXE MAC
匹配 sysfs；两者都失败才进入 vendor `udhcpc`/`dhclient` 兼容路径。禁止选择第一个非 lo
接口或假设 `eth0`。地址、netmask 与 gateway 设置失败均 fail closed。

MAC 必须在第一次 BootConfig HTTP 请求前可得，因此当前作为无密钥 cmdline bootstrap fact；
不能只放入需要网络才能取得的 BootConfig。它不是单独凭据：服务端以 DHCP lease、
boot session、Node/MAC/IP binding 共同完成引导认证。capsule 只保留切网后仍需使用的
event credential，不再承载 config/rootfs/agent 读取 token。

完整启动时序（其中 1-4 由 initrd 在 `switch_root` 前完成）：

1. DHCP/TFTP 引导 boot bundle（kernel + 共享 NodeForge initrd）和 per-session credential capsule；GRUB 将
   极小 capsule 作为第二个 initrd cpio 追加加载。kernel cmdline 只携带无密钥的
   `nodeforge.config_url`、node identity、PXE IP/prefix/gateway/MAC 与 `kernel_args`。
2. initrd 起后以活动 DHCP peer/session binding 从 `config_url` 拉 BootConfig，校验 DTO、
   计划 snapshot、时钟窗口和 feature。BootConfig 返回的短时 boot-session capability
   只交给 agent 读取 AgentPlan；rootfs/payload 不使用该 token。
3. initrd 先完成 rootfs HEAD/Range 下载、整文件校验，再建立 lower/upper/work/merged；它只把 AgentPlan
   URL/digest 等 locator 写入单一 `/var/lib/nodeforge/boot.json`，不下载/解析 plan 或 Node first-boot payload，
   也不写 merged root 的 target-system；lower 保持只读。
4. initrd 做 pre-switch 验证，原子写交接目录；把短时 boot-session capability 和
   `event:append` token 分别以 0400 文件交给切根后的 agent，rootfs 下载全程不生成或传播 token。
5. initrd 以 `nodeforge-agent pre-init` 为切根入口；agent 使用继承的 bootstrap 网络从服务端拉取并校验
   immutable AgentPlan 及全部 Node 专属 payload，写入 `/run` 后清零 boot-session capability；然后在最终 root 中应用全部
   Node override，成功后原进程
   `exec /sbin/init`，NM/Netplan/sshd 等只看到最终状态。systemd 启动后 agent 的 first-boot unit 再执行 effective
   bundle；完成后删除 event token。token 过期或事件回传失败不影响本地执行结果。

AgentPlan 可包含 Node override 派生的 password hash、authorized_keys 和 hosts 差量，但不包含明文密码或 Profile
共享 SSH private keys；所有 secret 字段与 token 一样禁止进入日志/事件/`boot.json`。v0.4 只保留两类必要凭据：
随机、仅驻内存的 boot-session capability 用于读取固定 AgentPlan；派生 `event:append` credential 用于推进本
session 状态。BootConfig、rootfs 与 payload 由 DHCP peer/session/digest binding 认证，固定大对象不携带 token。
两类凭据都不能访问其他 Node、不能列目录、不能写 catalog，也不能升级为 management credential。
`/var/lib/nodeforge/boot.json` 只保存 plan/config digest 与非 secret 摘要，mode 0600；短时 capability/event token
分别保存于 0400 credential 文件，不能进入 boot.json、日志或进程 argv。agent 在预取并校验 AgentPlan 后、修改
目标系统前清零 capability，first-boot 结束后清零 event token。
BootConfig DTO 自身 `schema_version` v3（与 catalog schema v5 分属不同命名空间）；
v3 增加 `facts_url`，initrd 以 event/telemetry capability 上报 `MemTotal` + DMI 硬件事实
（`product_serial`/`product_uuid`/`sys_vendor`/`product_name`），
使用 `kind` 判别字段（与 `ProfileKind` 一致），废弃 legacy `mode="diskless"`。
v0.2.3 起 facts 上报从仅 memory_bytes 扩展为完整 Facts，使纯 diskless 节点也有 SN/UUID 等信息。

`required_features` 按 consumer 分成 `initrd`/`agent` 两个排序去重集合。initrd 至少需要
`node-identity-handoff-v1`/`agent-plan-handoff-v1`；Node first-boot override 非空时 agent 另需
`node-firstboot-payload-v1`。agent 至少需要覆盖完整
TargetSystem/software transaction 的 `node-apply-v1`，静态目标网络时另需 `static-network-v1`。initrd manifest 与 rootfs 内
agent manifest 分别声明支持集合；任一缺失或冲突都在 `switch_root` 前拒绝，不得让 initrd 实现 agent feature 或回退降级。

### 5.1 BootConfig v3 最小契约

BootConfig 是签名/认证通道内的 canonical JSON；字段排序不参与 digest，digest 对 RFC 8785 风格的 canonical
JSON 计算 SHA-256。未知顶层字段默认拒绝，只有 `extensions` 容器允许前向扩展。

| 字段 | 约束 |
|---|---|
| `schema_version` / `kind` | 固定 `3` / `diskless` |
| `node_id` / `boot_session_id` | 必须与 cmdline、token claim 和服务端活动 session 全部相等 |
| `plan_digest` / `config_digest` | 64 位小写 hex；plan 与 session snapshot 相等；config 对省略 `config_digest` 自身且把 capability token 规范化为空值后的 canonical DTO 计算，避免自引用且不把 secret 纳入日志可见标识 |
| `issued_at` / `not_before` / `expires_at` | 服务端 UTC 秒；允许最大 120 秒时钟偏差，窗口最长 2 小时 |
| `rootfs` | 固定 digest 算法 `sha512`、hex digest、字节 `size`、`etag`、manifest digest、URL |
| `overlay` | v0.2 固定 `tmpfs_percent`、`minimum_free_bytes`；不存在 mode 字段 |
| `bootstrap_network` | 仅启动 NIC MAC、PXE 地址/lease 与 server endpoint；目标 renderer/topology 在 AgentPlan |
| `agent_plan` | URL、digest、size、expiry 与 feature 摘要；完整内容由 agent 切根后按 boot-session capability 获取，不由 initrd 解析 |
| `facts_url` | 固定到本 node 的 facts POST；只接受本 session event/telemetry capability；上报 memory_bytes + DMI（serial/uuid/vendor/model），不推进 lifecycle event_seq |
| `required_features` | `{initrd:[...],agent:[...]}`；分别是 initrd manifest 与 rootfs agent manifest features 的子集 |
| `artifacts` / `events` | rootfs/AgentPlan/event URL；rootfs/payload 固定大对象只用 peer/session/digest binding，不携带 token；BootConfig 内的短时 capability 只供 AgentPlan 控制面读取并落入 0400 handoff，event token 只由 capsule/0400 文件交付；URL host 必须是配置的 `server_ip` 字面地址 |

AgentPlan 的 canonical schema 单独包含 `node_apply_projection`：Node effective 相对 Profile 的全部运行根差量、
effective first-boot descriptor、pinned payload closure 与 `required_features.agent`。BootConfig 只绑定其 digest/size，
不能复制其中字段形成第二个配置 owner。

### 5.1.1 AgentPlan v1 最小契约

| 字段 | 约束 |
|---|---|
| `schema_version` / `kind` | 固定 `1` / `diskless-agent-plan` |
| `node_id` / `boot_session_id` | 必须与 boot.json、handoff、agent token claim 全部相等 |
| `desired_plan_digest` / `agent_plan_digest` | desired digest 等于 session snapshot；AgentPlan 对省略自身 digest 后的 canonical JSON 计算 SHA-256 |
| `issued_at` / `expires_at` | 只允许本 session pre-init 窗口；过期 fail closed，不换取新 plan |
| `node_apply_projection` | 唯一运行根差量；typed 字段，不允许 unknown action、自由 URL 或节点侧重新 merge |
| `first_boot` | effective source=`profile-rootfs|node-payload`、bundle revision/digest、执行摘要 |
| `payloads` | 内容寻址 URL/digest/size/mode/path allowlist；必须是 plan 的完整闭包，禁止 `latest` |
| `required_features` | 只含 agent consumer feature；必须是 rootfs agent manifest 子集 |

AgentPlan 响应不携带 raw token；boot-session capability 只在独立 0400 文件和
Authorization header 中出现。agent 必须先下载并验证固定 AgentPlan；payload 走
peer/session/digest 数据面下载到 session-owned `.part`，逐一验证并原子发布到 `/run`，
再清 capability、进入 apply stage。

kernel cmdline 只允许携带无密钥的 `nodeforge.config_url`、`nodeforge.node_id`、`nodeforge.session` 和已编译的
`kernel_args`，不得携带 password hash、任何 token 或整份 JSON。per-session
`credential.cpio` 的 initramfs 私有目录只含 delivery session id 与 `event.token`；
boot-session capability 由 peer-authenticated BootConfig 签发后写入 0400 handoff。
GRUB 用多个 `initrd` 参数/条目把 capsule 追加到共享 initrd。capsule 路径含不可猜 session id，
TFTP/HTTP resolver 还须校验发起 IP 对应的活动 DHCP
session；capsule 单次下载、短 TTL、日志全量脱敏。它只改善静态泄露面，不提供链路机密性，隔离 VLAN/ACL 仍是硬要求。

### 5.2 initrd 确定性流水线

initrd 每一步写本地有界 journal，成功后 `fsync` 再推进；重入只允许在同一 session、同一 plan/config
digest 内从安全检查点继续。具体顺序固定如下：

1. **early mount**：先从 initramfs 私有路径读取并 unlink delivery session/event credential，再挂载 `/proc`、`/sys`、`/dev`、
   `/run` 并解析 cmdline；重复 key、未知 `nodeforge.*` key、token owner/mode/session 不匹配或格式错误立即失败。
2. **network-up**：只激活 DHCP 已使用的启动 NIC；校验其永久 MAC 等于 BootConfig。v0.2 不切 NIC、
   VLAN 或地址，不做 DNS。
3. **config**：以活动 DHCP peer/boot session 获取固定 BootConfig；响应中断可在短窗口重取相同 bytes，限制响应头
   32 KiB、body 1 MiB、重定向 0 次；校验身份、时间、canonical digest、feature 和 URL allowlist，随后上报
   `diskless.initrd_started`。BootConfig 内 capability 只为后续 AgentPlan 控制面读取签发。
4. **memory gate**：读取 `/proc/meminfo`，直接以 `MemAvailable` 作为 `available_budget`，不能再扣当前 kernel/initrd。
   令 `node_payload_size` 为 Node first-boot override payload 的精确传输字节数（无 override 时为 0），
   `upper_limit=floor(available_budget*tmpfs_percent/100)`；检查 `minimum_free_bytes <= upper_limit` 且
   `rootfs.size + node_payload_size + upper_limit + safety_margin <= available_budget`。v0.2 的 squashfs 文件和可选 Node
   payload 都下载进 tmpfs，因此不能宣称
   “不需要预算”；所有计算使用 checked `u64`。
5. **download**：目标为 `/run/nodeforge/image/rootfs.part`；先 HEAD 固定 ETag/size，再按连续 Range 下载。
   每次响应必须为 206、`Content-Range` 起点准确、ETag 不变；200 仅允许首次完整 GET。最大 4 MiB chunk，
   指数退避带抖动，总次数和总时长有界。
6. **verify**：文件大小精确匹配后，对完整文件计算 SHA-512；不信任分块 hash。首次 mismatch 删除 partial
   后完整重下，第二次 mismatch 终止并 quarantine 计数。
7. **mount**：只读 loop 挂载 squashfs 到 `lower`；tmpfs 挂载到独立 `upper-tmpfs`，创建同一文件系统内的
   `upper`/`work`，以 `nodev,nosuid` 挂载 overlay 到 `merged`。lower 必须 `ro,nodev`。
8. **handoff-agent**：校验 AgentPlan locator envelope 与 rootfs agent feature manifest，写
   单一 `/var/lib/nodeforge/boot.json`；不下载/解析 AgentPlan 或 Node payload，不写 target-system。
   boot-session capability/event token 只写独立 0400 credential 文件，不进入 JSON。
9. **pre-switch**：确认 `/sbin/init` 与 `/usr/lib/nodeforge/nodeforge-agent` 可执行、modules ABI、挂载和 `/run`
   move-mount 可持续；写 boot.json、capability/event token 和 journal，均禁止跟随 symlink。target-system/DNS/账号/renderer 的
   最终验证属于 agent pre-init，不得在 initrd 复制一套 parser。
10. **handoff**：POST `switching_root`，确认 rootfs 已完成 digest 校验且未传播 token，move-mount `/dev`、`/proc`、
    `/sys`、`/run`，以 merged 为新根执行
    `switch_root ... /usr/lib/nodeforge/nodeforge-agent pre-init`。pre-init 成功后再 exec `/sbin/init`；任一 exec 返回均视为失败。

禁止直接把下载流 pipe 给 mount、在 digest 校验前解析 squashfs、接受 HTTP redirect/content-encoding、跨 ETag
拼接 partial，或失败后回退本地磁盘/NFS/旧 rootfs。

#### 5.2.1 pre-switch 与 `/run` handoff 到底是什么

`pre-switch` 是“最后一次还能安全留在 initrd 里报错”的提交闸。它检查 merged root 的 `/sbin/init`、agent pre-init
入口/动态库、rootfs/kernel modules ABI、挂载选项、目标 `/run` 目录和凭据 owner/mode；任何一项失败都不执行
switch_root。renderer/账号/SSH 等最终语义由 agent pre-init 校验，initrd 不复制其 parser。它不是 first-boot，也不修改共享 lower。

`/var/lib` handoff：initrd 把 session handoff 与 payload 直接写到 merged 根的 `/var/lib/nodeforge/`（overlay upper）；systemd 不会像 `/run` 那样重建 tmpfs 覆盖 `/var/lib`，故切根前后同一文件，pre-init 与 first-boot 均可读。目录布局固定：

```text
/var/lib/nodeforge/boot.json             0600 root:root，session handoff（node/session + AgentPlan locator；不含 token）
/var/lib/nodeforge/credentials/agent.token  0400 root:root，pre-init 读取后立即 unlink
/var/lib/nodeforge/credentials/event.token  0400 root:root，first-boot 最终事件后 unlink
/var/lib/nodeforge/payload/              root:root，agent pre-init 预取、校验后的 content-addressed payload
```

> **实现现状**：当前实现把 handoff 与 payload 直接写在 merged 根的 `/var/lib/nodeforge/`（overlay upper）。
> systemd 不会像 `/run` 那样重建 tmpfs 覆盖 `/var/lib`，故切根前后同一文件，pre-init 与 first-boot 均可读。
> `agent_token`/`event_token` 已从 `boot.json` 分离到 0400 credential 文件；agent token 在
> pre-init 读取时 unlink，并在服务端 `agent-consumed` 后撤销，event token 在 running/failed 后撤销。
> first-boot 已实现与 session/plan digest 绑定的原子 journal、成功步骤跳过、timeout
> 及 retryable attempt/backoff；initrd `/run` move-mount 与逐阶段 journal 仍为后续演进目标，
> 当前未实现；initrd 阶段的 rootfs 下载等仍用 initramfs `/run`（切根前释放，不涉及）。
> **Phase 8（first-boot 八步重放）**：pre-init 拉取并校验 AgentPlan 后，把整份 plan 覆盖写回
> `boot.json`（AgentPlan v1 现内联 `steps`，固定顺序 managed_file -> package -> archive ->
> script）。first-boot unit 读 `boot.json` 内联步骤一次性重放，无远程控制、无 reconciliation；
> 失败只记 `/var/lib/nodeforge/firstboot.log`，不阻断启动。步骤内容支持内联 `content` 与
> content-addressed payload blob（步骤引用 `payload/{name}/{revision}`，由 pre-init 下载并
> 校验 size/SHA-256 后写入 `/var/lib/nodeforge/payload`，first-boot 以 `cp` 消费，不内联字节）；
> 该 payload 下发已在 QEMU 全量验证中端到端验证（`NODEFORGE_PAYLOAD_PROOF`）。

这样新系统看到的是同一个 tmpfs/loop backing，loop lower 不因旧 initrd root 被回收而失效，agent 也能取得同一
session 的 handoff 事实。agent pre-init 自身在应用任何差量前验证目录不是 symlink、owner/mode/digest/session
正确；真正 init 启动后的 `nodeforge-handoff.service` 只复核并记录已完成的 handoff，不可能反过来成为 pre-init 的前置服务。
first-boot 完成后删除 event token，systemd 后续正常管理继承的 `/run`。若 move-mount 或验证失败，状态为
`diskless.failed`，不能用复制 token 到 `/etc`、重建 session 或匿名上报绕过。

### 5.3 网络接管与“无缝”定义

v0.2 的接管不是重新配网，而是保持启动 NIC、MAC、IPv4 地址、prefix、gateway 和 MTU 不变：

- DHCP 模式：initrd 保留 lease 文件与 lease 元数据到 `/run/nodeforge/network/`，target renderer 以同一
  MAC 启动；允许 DHCP renew，但 renew 前不得主动 flush 地址。服务端 reservation 必须等于 PXE 地址。
- 静态模式：BootConfig 的 bootstrap 地址必须等于 PXE reservation，AgentPlan 的目标静态地址必须等于同一地址；
  agent pre-init 校验后写 renderer 配置但不 apply，真正 init 后 renderer
  adopt 同一地址。地址冲突探测失败在下载前终止。
- first-boot agent unit 必须 `After=network-online.target nodeforge-handoff.service`。package action 可访问且只能访问
  AgentPlan 固定的仓库：默认是当前 InstallSource 由 nodeforged 发布的 HTTP Yum/APT 源，并合并 CLI 明确增加的
  仓库；DNF/APT 必须禁用未进入该集合的系统其他源。受管源不可达时该 step
  按 first-boot 失败策略记录/重试；远端事件仍为 best-effort。renderer 接管后连续 ping 服务端不是成功判据；成功判据是地址/route 未出现空窗、
  默认路由未漂移，且服务端 event 可 best-effort 到达。

### 5.4 服务重启与断点续传

v0.4 支持 daemon 重启后基于持久 authority 重新 join **投递**，不恢复内存中的旧 socket：BootSession、
计划快照、event credential claim 的不可逆 hash、过期时间、rootfs snapshot ref 和最后确认 phase 必须原子持久化。
随机 boot-session capability 只驻内存，原始 token 永不落盘。

- BootConfig/rootfs/payload 重试继续使用 DHCP peer/session/digest binding；服务端仅在 plan/rootfs digest
  相同且 session 未终止时恢复。AgentPlan capability 丢失后必须经持久 authority fail-closed join 重新签发，
  不能从持久数据反推旧随机 token，也不创建影子 session。
- capsule 交付中断只影响 delivery session id/event credential；持久化 delivery started/completed 审计位
  不能用于伪造 raw credential。无法证明完整交付时旧 session 标 `session.recovery_incomplete`，下一次 boot
  创建新 session；rootfs 大对象恢复本身不依赖 capsule read token。
- Range 恢复由客户端 partial 长度与服务端 immutable ETag 决定；服务端不保存 offset。`If-Range` 不匹配返回
  200 时，客户端必须先截断 partial 再完整接收，绝不能 append。
- v0.2 不回收已经发布的 rootfs object；rename 发布镜像与 manifest 后才能 ready。daemon 重启发现未发布的
  staging `.part` 可作为失败构建残留清理，但这不是已发布 rootfs GC。
- session 过期由 wall clock 判定，退避/无进展 timeout 用 monotonic clock；重启后 monotonic 基准重建，不得因
  wall-clock 回拨延长 token。

#### 5.4.1 delivery snapshot ref 到底是什么

它是 BootSession 中固定的不可变引用：`desired plan digest + boot bundle revisions + rootfs content digest +
AgentPlan digest/size + optional Node first-boot payload digest/size + BootConfig schema`。作用是保证一次启动从 DHCP
到 agent pre-init 完成输入预取始终使用同一套内容；Profile 修改、新 rootfs 构建或
daemon 重启都不能让在途 session 中途换版本。它不是 GC 引用计数，也不需要释放后触发删除。v0.2 已发布 rootfs
只增不删；容量通过 `nodeforge status --component rootfs-cache` 告警，回收策略留给有真实容量数据的后续版本。

### 5.5 状态、失败归责与超时

服务端状态只能由可验证证据推进：DHCP/TFTP 由服务端协议栈产生；`diskless.initrd_started` 以后只接受 event token
签名的单调事件。`diskless.running` 表示 pre-init node-apply 成功、真正 PID 1 已启动、网络接管已尝试且
first-boot agent unit 已进入执行，不等价于
first-boot 全部成功。

| 阶段 | 无进展超时 | 失败责任域 |
|---|---:|---|
| DHCP offer/ack | 60 s | `network.dhcp.*` |
| TFTP bundle | 10 min | `transport.tftp.*` |
| BootConfig | 2 min | `config.*` / `auth.*` |
| rootfs download | 30 min，且 5 min 无字节推进 | `artifact.*` / `transport.http.*` |
| verify/mount/handoff-agent | 各 10 min | `integrity.*` / `mount.*` / `handoff.*` |
| agent plan/payload fetch | 30 min，且 5 min 无字节推进 | `agent_config.*` / `agent_artifact.*` |
| agent pre-init node-apply | 30 min，且 5 min 无 step 推进 | `projection.*` / `package.*` / `target_system.*` |
| exec init/running | 5 min | `handoff.*` / `init.*` |

稳定 reason 必须是枚举（例如 `artifact.etag_changed`、`integrity.rootfs_mismatch`、
`network.identity_mismatch`、`projection.invalid_network`、`handoff.exec_returned`），人类摘要另存且最多
512 bytes。仅 Node/配置/镜像确定性错误和重复完整 hash mismatch 消耗 failure budget；服务端重启、瞬时网络
超时等 retryable 基础设施错误记录 attempt，但在重试耗尽前不 quarantine。相同 node + plan digest 的失败计数；
desired digest 变化会关闭旧计数并开始新 bucket，保留旧审计。

## 6. Agent pre-init Node apply 与 first-boot 后处理

initrd 切根到 node-bound agent（`nodeforge-agent pre-init`，见 [`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md)）。
agent 框架先以继承的 bootstrap 网络从服务端拉取 session 固定的 AgentPlan 和全部 Node payload，校验后写入 `/run`
并清零 boot-session capability；随后在真正 init 前使用完整 rootfs 环境应用全部 Node effective override，成功后 exec `/sbin/init`；systemd 启动后
同一 binary 的 unit 再顺序执行 effective `first-boot`。后者默认承载 Profile 固定 bundle，
`overrides.diskless.provision.bundle` 存在时完整替换为 agent pre-init 已预取校验的 Node first-boot-only payload：

initrd 不包含 TargetSystem projector，不理解 password/users/SSH/hosts/software。pre-init agent 固定先执行 exact software
transaction，再执行 TargetSystem finalizer 和完整 validation；它作为短生命周期 PID 1 不 daemonize，成功必须以原进程
exec 真正 init。这样既复用 agent/installer runner，又保证 systemd、renderer、sshd 和业务服务从未看到未覆写的 Profile baseline。

first-boot 是**可选的运行根后处理阶段**，配置力度与 install postprocess 一致。Profile 共享基线
先进 rootfs，Node effective 差量由 agent pre-init 写 upper；随后 first-boot 可通过
managed-file/package/archive/script 继续修改账号、SSH、hosts
或其他系统文件。所有输入在 plan/session 中固定，agent 不远程拉取可变步骤。禁止公网更新、远程任务、
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

生命周期与后处理严格分离：pre-init node-apply 属 boot attempt，失败时真正 init 不启动并进入 `diskless.failed`/
quarantine；成功 exec init 后才可进入 `diskless.running`。只有 first-boot 结果作为
`postprocess=not-configured|running|succeeded|degraded` 附属摘要，step failed 不倒退 running，也不会产生第二个状态。

## 7. local-only 不变式

v0.1 删除 `system.connectivity.mode`（曾取值 `local-only`），因 `local-only` 是唯一行为、无选择
意义。v0.2 承袭为不变式：

- rootfs/initrd 恒 `local-only`：移除/禁用公网 mirror、metalink、GeoIP、vendor NTP，只引用本地
  repository；不新增 `local-only` PropertySpec，不存在 online 变体。
- v0.2 的 HTTP bearer 只在隔离 `local-only` 网络内提供认证，不提供链路机密性；跨不可信网络的
  TLS/mTLS 与远程管理仍是非目标，部署必须以隔离 VLAN/ACL 防止旁路窃听。

## 8. 验收不变式

- v0.2 不存在 NFS root、iPXE 或可切换 rootfs mode 字段及其 help/enum。
- 同一 Profile revision 解析出唯一 `rootfs_input_digest`；适用的 Node override 不改 rootfs，只改
  `desired_plan_digest`；完整差量经 typed AgentPlan 交给 agent pre-init 写 overlay upper，Node first-boot override payload
  经 agent pre-init 预取校验后由 first-boot 从 `/run` 执行。
- initrd 只负责 transport/verify/mount/handoff locator，不取得 AgentPlan，不包含 users/SSH/software projector，也不写 target-system。
- `switch_root` 进入 agent pre-init；全部 Node override 成功后 exec 真正 init，再由 systemd unit 执行 first-boot。
- 首次 hash mismatch 必须删 partial 后完整重试；重复完整 mismatch、feature mismatch、过期 token、越权
  Range、switch_root 失败都进入稳定
  error code、`diskless.failed` 和 quarantine。
