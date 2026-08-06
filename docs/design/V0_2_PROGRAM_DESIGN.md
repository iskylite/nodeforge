# NodeForge v0.2 程序边界设计

状态：v0.2 程序分册，核心实现已落地并持续按验证结果收口。总纲以 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) 为准；本文只定义
四个可执行产物的职责、生命周期、信任边界和凭据所有权。CLI 见 [`V0_2_CLI.md`](V0_2_CLI.md)，
diskless 时序见 [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md)，状态机/协议栈见
[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md)。

本文不维护完整命令参考或逐协议状态转移；功能列表用于确定代码归属，不能替代实现分册。

## 0. 构建溯源约定

- `build.zig` 文件级常量 `nodeforge_version` 是二进制产品版本的构建事实源；发布时必须同步更新
  `build.zig.zon` 的包版本，避免产物版本与包元数据分叉。
- CLI 与 daemon 共用编译期注入的 version、Git commit、dirty 状态和 build time。
- build time 由 `std.Io.Clock.real` 读取 Unix timestamp，再由 `std.time.epoch` 格式化为 RFC 3339 UTC，
  固定格式为 `YYYY-MM-DDTHH:MM:SSZ`；构建过程不依赖宿主 shell 或 `date`。
- 可复现构建通过 `-Dbuild-time=<固定值>` 显式注入时间。运行时代码若需要本地时间，统一通过 libc
  `localtime_r`/`strftime`；结构化 API 与事件时间保持 UTC 语义。
- **调试阶段务必固定 `build-time`**：`build_time` 经 `build_options` 注入编译图，参与 Zig 内容寻址
  缓存的全局哈希。若每次构建都读取实时时钟，时间戳的秒级变化会导致全部下游产物缓存失效，`.zig-cache`
  持续膨胀且每次全量重编（实测 14 天可累积至数十 GB）。调试期间推荐始终使用固定时间戳：
  `zig build -Dbuild-time=2026-07-29T00:00:00Z`。正式发布构建可省略该选项以记录真实构建时间。
  若 `.zig-cache` 已膨胀，可安全删除（`.gitignore` 已忽略该目录）。

## 1. 四产物、三运行角色总览

| 产物 | 角色 | 运行阶段 | 身份/凭据 | v0.2 是否实现 |
|---|---|---|---|---|
| `nodeforge` | 管理 CLI：本地只读校验与经管理 API 的资源操作 | 管理端按需运行 | daemon `admin_key`；不持有 boot/session token | 是 |
| `nodeforged` | 单进程守护进程：DHCP/TFTP/HTTP 协议栈 + 本机管理 API + 服务端 rootfs 构建/发布 | 服务端常驻 | daemon 管理 API 自身鉴权 | 是（v0.1 已有 daemon，v0.2 扩 diskless，v0.4 固定 server-only rootfs） |
| `nodeforge-initrd` | dracut 引导程序：拉最小 BootConfig、下载/校验/挂载 ready rootfs、交接 AgentPlan locator、switch_root | initrd（switch_root 前） | DHCP peer/session binding + `event:append` token；rootfs 下载无 token | 是 |
| `nodeforge-agent` | 单次启动执行框架：从服务端拉 immutable AgentPlan/payload，pre-init 应用全部 Node override 并 exec 真正 init；systemd 后执行 first-boot | 切根后 pre-init + 运行期 | boot-session capability 只读 AgentPlan，`event:append` token 推进状态；payload 无 token | 是（仅 diskless） |

四个产物共享核心模块（`src/root.zig` 为 `nodeforge` 模块），避免行为分叉；当前 `build.zig` 产出
`nodeforge`、`nodeforged`、`nodeforge-initrd` 与 `nodeforge-agent`，四个可执行文件复用同一 core module。

### 1.1 setup 与宿主环境边界

默认安装根 `/opt/nodeforge` 的初始化和 reconfigure 会原子生成 `/etc/profile.d/nodeforge.sh`，固定权限
`0644 root:root`，幂等地把 `/opt/nodeforge/bin` 加入登录 shell 的 `PATH`。脚本不覆盖已有 PATH，也不会重复插入；
当前会话可显式 source，新登录会话自动生效。自定义安装根用于测试或并行实例，禁止写宿主全局 profile.d。

`setup` 只发布环境脚本和 `/opt/nodeforge/systemd/nodeforged.service` 事实文件；systemd 的 daemon-reload、enable、
restart 仍是显式运维动作，避免 reconfigure 在无确认时改变服务生命周期。

### 1.2 启动阶段与写入边界

| 阶段 | 切根关系 | 从服务端取得 | 允许配置/写入 | 明确不做 |
|---|---|---|---|---|
| Profile `rootfs-build` | 节点启动前 | pinned InstallSource/Profile/build bundle | 构建公共 lower：包、用户/密码基线、Profile SSH keys/authorized_keys、hosts、NTP/localization/security/service baseline | 不读取任何 Node override |
| server compile | 节点启动前 | 读取 pinned Profile/Node/resource snapshot | 生成 BootConfig、AgentPlan、digest；只给敏感控制面读取签发 capability | 不操作节点 rootfs |
| firmware/GRUB | kernel 之前 | boot config/capsule | 选择 kernel/initrd、追加 `kernel_args`、传递无密钥 node/session/config URL | 不配置目标系统 |
| `nodeforge-initrd` | `switch_root` 前 | 最小 BootConfig、共享 rootfs | 维持 bootstrap NIC/address，下载/校验 rootfs，建立 lower/upper，写 AgentPlan locator/token handoff | 不取得 AgentPlan，不写 `/etc`、用户、SSH、hosts、软件或目标网络 |
| agent `pre-init` 子命令 | `switch_root` 后、`/sbin/init` 前 | immutable AgentPlan 与全部 Node payload | 预取校验后清 capability；写最终 rootfs 的 network/hostname/machine-id/users/password/SSH/hosts/NTP/localization/security/software/services | 不读取 latest catalog，不接远程临时命令，不 daemonize；v0.4.3 起强制子命令 argv |
| agent `--first-boot` | 真正 init/systemd 后 | 不再获取配置；只读 pre-init/rootfs 本地 payload | 按固定 action 顺序执行后处理并上报结果 | 不重复 merge/apply Node baseline，不做 reconciliation |

这里“initrd 写 handoff”与“更新 rootfs 配置”是两类动作：前者只写 `/var/lib/nodeforge/*` 的 locator、摘要和短时凭据，
后者只允许 agent 在最终 rootfs 中执行。

## 2. nodeforged（守护进程）

v0.1 已实现单进程内置 DHCPv4/TFTP/HTTP 与本机管理 API。v0.2 在其上扩展：

### 2.1 功能列表

- DHCP/TFTP/HTTP 协议栈：按 canonical BootSession 状态机驱动引导
  （[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md) §2）。
- BootConfig 生成与投递：按 immutable DisklessEffectivePlan snapshot 在 boot 时生成 per-boot、per-Node 的
  最小短时 BootConfig DTO，经 DHCP peer 引导认证拉取；它只包含 boot/rootfs/overlay/bootstrap network、
  AgentPlan locator/digest/size 与 consumer feature 摘要，不包含完整 Node 配置。
- AgentPlan 生成与投递：服务端以同一 session snapshot 将 Profile + Node effective 结果编译成唯一 immutable
  `node_apply_projection`，通过精确绑定 node/session/digest/path 的 boot-session capability 提供给切根后的 agent；
  agent 不在节点侧重新 merge Profile/Node，也不读取可变 catalog。
- node-bound rootfs HTTP GET/HEAD/Range：按 `rootfs_input_digest` 缓存、content SHA-512
  交付，由活动 DHCP peer、session、TTL 与 artifact binding 约束，不携带 token。
- 服务端 rootfs builder：构建 squashfs lower（OS 层 + rootfs-build phase），按 digest 缓存
  （[`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §4）。
- effective compiler / readiness / validator：与 v0.1 同一编译结果（diskless 分支消费 immutable
  DisklessEffectivePlan）。
- 管理本机 API：复用 v0.1 management API 与 `admin_key` 鉴权。
- Profile 删除：`DELETE /api/v1/management/profiles/:name` 必须携带 catalog `If-Match`；daemon 在 model gate
  内检查 Node 引用，零引用才原子发布新 catalog generation，有引用返回 `profile.in_use`。

### 2.2 实现要点

- builder 在与目标 distro/version/arch/`kernel_release` 一致的环境运行；按动作所需提供 chroot
  或 bind-mount `/dev`/`/proc`/`/sys` + 匹配内核（构建保真见 [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §4）。
- builder 不上节点、无节点 agent；rootfs-build 事件 `source=builder` 记入 build manifest/audit。
- management credential（daemon 管理 API 鉴权）与 boot 传输 token 是不同凭据类型、不同鉴权路径，
  不得互通（见 §5）。

## 3. nodeforge-initrd（dracut 引导程序）

### 3.1 为什么需要独立程序入口

initrd 阶段（`switch_root` 前）需要联网拉取最小 BootConfig、下载/校验 rootfs、建立 overlay 并安全交接 AgentPlan locator，
这些是通用 dracut 不具备的 NodeForge 逻辑。v0.2 通过 `assets
nodeforge-initrd config/build` 在构建 dracut 时自动注入 `nodeforge-initrd` 作为引导模块，由其在
initrd 内完成上述职责；它不链接 TargetSystem/effective runner，不解释 users/SSH/software 字段。

### 3.2 功能列表

1. 从 kernel cmdline 读取无密钥的 config URL、node/session，并从 GRUB 追加加载的 per-session credential
   capsule 读取 delivery session/event credential；token 不进入 `/proc/cmdline`。
2. 经活动 DHCP peer/boot session binding 从 `config_url` 拉取 BootConfig；rootfs 大对象同样使用
   peer/session/digest binding，不创建 `artifact:read` token。
3. 校验 BootConfig：`required_features.initrd` 是 initrd manifest 子集、`required_features.agent` 是已挂载 rootfs
   agent manifest 子集，并校验 `schema_version` v3 与 digest；缺失或冲突以稳定 error code 拒绝，不回退降级，
   也不让 initrd 代行 agent feature。
4. 做内存预算闸，下载到 `.part`，严格校验 ETag/Content-Range/size，完整 SHA-512 成功后才挂载
   rootfs lower（HTTP GET/HEAD/Range 恢复）。
5. 建立 squashfs 只读 lower + tmpfs overlay upper。
6. 只校验 AgentPlan locator envelope（URL host/path、expected digest/size、expiry、required agent feature 摘要），
   不下载或解析完整 plan；检查已挂载 rootfs 的 agent manifest 能满足 feature 摘要。
7. 原子写单一 `/var/lib/nodeforge/boot.json` handoff（仅含 node/session、URL、
   digest 和非 secret 元数据），将独立 boot-session capability 与 `event:append` token 写入
   0400 credential 文件。不得再增加内容重复的 `agent-handoff.json`。
8. pre-switch 检查通过后确认 rootfs 已完整验签且下载未传播 token，move-mount `/run`，保留 capability/event token，
   以 merged root 执行 `switch_root ... /usr/lib/nodeforge/nodeforge-agent pre-init`。

### 3.3 实现要点

- **不负责** AgentPlan/payload 获取和 target-system/Node override：不下载完整 Node 配置，不写 NM/Netplan、用户、SSH、
  hosts 或 security 配置，也不运行 package manager；
  全部由最终 rootfs 内的 agent pre-init 处理。
- **不切换地址**：initrd 保持 bootstrap NIC/address；agent pre-init 写目标 renderer 配置，真正 init 启动后
  NM/Netplan 接管同一地址。
- 失败（hash mismatch、feature mismatch、过期 token、越权 Range、switch_root 失败）进入稳定
  error code、`diskless.failed` 和 quarantine，不静默降级。
- 静态编译为独立 executable，dracut module 声明依赖（网络、overlayfs、squashfs loop）。

## 4. nodeforge-agent（切根后执行器）

### 4.1 角色与边界

agent **仅服务 diskless**，是消费服务端 immutable AgentPlan 的一次性执行框架；同一 executable 有两个固定入口：

1. `pre-init` 子命令：作为 `switch_root` 后、真正 `/sbin/init` 前的短生命周期 PID 1，使用继承的 bootstrap 网络从服务端
   拉取并校验 session 固定的 AgentPlan/payload，应用全部 Node override，成功后 `exec /sbin/init`，不 fork 常驻、不返回。
2. `--first-boot`：由 systemd unit 调用，执行 effective first-boot steps（默认 rootfs Profile payload，Node bundle
   override 时为 agent pre-init 已校验的 `/run` payload）。

两者都是确定性一次性执行器，不接受远程任务下发、不做 reconciliation、不做通用远程命令或配置管理平台。

### 4.2 功能列表

1. pre-init 读取 `/var/lib/nodeforge/boot.json`，校验 node/session/plan identity、
   handoff owner/mode、expected digest 与 boot-session capability claim；凭据只从独立 0400
   credential 文件读取并在读后 unlink，不得内联进 boot.json。
2. 使用继承的 bootstrap 网络从精确 URL 拉取 immutable AgentPlan；只接受 expected digest 的 canonical bytes，禁止
   catalog list/get、latest、重定向到未声明 host 或服务端临时下发命令。
3. 按 AgentPlan 的 immutable closure 预取 Node first-boot override payload 及其 assets/package payload；全部 size/digest/
   feature 校验成功后清零 boot-session capability。任何目标网络切换必须发生在预取完成之后。
4. 按固定顺序执行：pinned repository/package add-remove transaction ->
   TargetSystem finalizer（network/hostname/machine-id/users/password/SSH/hosts/NTP/localization/security/service enablement）->
   pre-init validation。禁止自由 URL、隐式 update、公网 fallback 或移除 protected kernel/initrd/agent/sshd closure。
5. pre-init 成功后原进程 `exec /sbin/init`；失败先 best-effort 上报稳定 reason，再按失败策略在 console 留证并终止，
   不能启动未完成 override 的系统，也不能回退 Profile baseline。
6. first-boot 按 AgentPlan 指定的唯一来源读取 payload：无 Node override 时读取 rootfs 中固定 revision/digest 的
   Profile payload；有 override 时读取 pre-init 已下载到 `/var/lib/nodeforge/node-firstboot/<payload-digest>/` 的 payload。
   first-boot 阶段没有读 token，不能再访问服务端配置/artifact API。
7. first-boot 固定顺序执行：文件更新 -> package -> archive -> script（八步执行契约见
   [`V0_2_DESIGN.md`](V0_2_DESIGN.md) §5.2）。
8. 幂等：`(boot session, bundle revision, desired plan digest, node, phase, idempotency key)` 使同次启动
   崩溃恢复/重试时已成功 step no-op；新 PXE session 重新执行全部步骤。
9. pre-init node-apply 失败使 boot attempt 进入 `diskless.failed`；first-boot retryable step 耗尽只令
   `postprocess=degraded`，节点仍为 `diskless.running`。
10. 每 step 前后产生 `provision.step.started/succeeded/warned/failed`，经 `event_url` best-effort
   回传（带 `node_id`）。
11. 事件失败本地兜底（日志/console/boot.json），不改变本地 apply 结果。

### 4.3 实现要点

- **无 enrollment**：身份来自 cmdline、BootConfig、token claim 三方相等的 session snapshot。event token 是 per-boot、
  append-only、短时传输能力，不是可续期的运行期 enrollment credential。
- **无远程控制**：reconciliation/远程控制为永久非目标；agent 开机确定性顺序执行，无 drift 重跑、
  无远程任务下发。
- **框架而非脚本入口**：core 固定实现 identity/claim 校验、AgentPlan fetch、canonical digest、payload prefetch、journal、
  timeout/retry、事件和 final validation；distro adapter/runner 只注册 typed software transaction、TargetSystem finalizer 与
  bounded first-boot action handler。AgentPlan 不能携带未注册 action 或任意远程命令，script 只能引用已固定 digest 的受管 asset。
- **精确服务端接口**：agent 只可 GET session snapshot 中的
  `/api/v1/nodes/{node}/boot-sessions/{session}/agent-plan/{digest}` 及该 plan 明列的内容寻址 payload path；禁止 list、
  `latest`、catalog/effective API 和 HTTP redirect。
- **pre-init 不是常驻 init system**：不 daemonize、不 fork 后返回；使用 initrd 已 move-mount 的 `/dev`/`proc`/`sys`/`run`
  和继承网络，所有 child 都必须有界 wait/reap，成功以原进程 `execve(/sbin/init)`。service enable/disable 只离线写 unit
  enablement/mask，不能在 systemd 启动前调用其 D-Bus。
- **无独立 first-boot retry CLI**：重启即重跑（确定性+幂等保证安全）；`node diskless retry` 仅清
  boot-level quarantine 以允许重新 PXE。
- 脚本 stdout/stderr 仅留最后 2048 bytes 转义摘要；token/未声明输出不得进服务日志或 Event。
- 一次性语义：每次开机执行一次（overlay upper 为 tmpfs、per-boot 易失），非“跨重启只跑一次”，
  也非 `runtime` 周期。

## 5. credential 边界澄清

“credential”在 v0.2 指两类互不相同的凭据，**不含**已永久移除的 enrollment：

| 凭据 | 类型 | 鉴权路径 | 权限 | 生命周期 |
|---|---|---|---|---|
| DHCP peer/session binding | 无 raw token 的引导身份 | initrd 拉 BootConfig/rootfs；agent 拉 payload | 固定 node、活动 session、lease IP、artifact/path digest 与 TTL 的读取 | session 终止或过期失效 |
| boot-session capability | 随机、仅驻内存的短时只读能力 | agent pre-init 拉固定 AgentPlan | 固定 node/session/plan digest，无 catalog/latest 权限 | AgentPlan 预取校验后、修改目标系统前清零 |
| event token | per-boot 只写能力 | initrd/agent 上报本 session 事件 | 固定 event path 的 POST，无读权限 | agent 完成或过期后删除 |
| management credential | daemon 管理 API 鉴权 | 服务端管理员 | catalog 写、管理 API 全权限 | daemon 常驻 admin_key |

- boot-session capability 与 event token 不能互换、不能访问其他 Node/session 或未声明 path、不能升级为
  management credential。rootfs/payload 不因缺 token 失败，而必须同时满足 peer/session/digest binding。
- BootConfig 重放只容忍同一活动 session 的响应中断，不能重新渲染 DTO、延长 expiry 或重复推进
  BootSession phase。raw capsule event credential 不落入 catalog/log；daemon restart 必须基于持久 authority
  fail-closed join，不能反推旧随机 capability。
- **enrollment**（运行期节点认证 secret）已永久移除，与上述 token 无关：token 仅是 boot 期 initrd/agent 的
  有界传输鉴权，agent 身份由 node/session、BootConfig snapshot 与 token claim 三方相等共同证明。

## 6. 三运行角色协作时序

```text
nodeforged 生成 BootConfig（per immutable DisklessEffectivePlan snapshot）
  -> DHCP/TFTP 引导 boot bundle（kernel + shared nodeforge-initrd + per-session credential capsule）
  -> nodeforge-initrd: 拉最小 BootConfig、下载/校验/挂载 rootfs、交接 AgentPlan locator
     （不下载 AgentPlan；rootfs 下载不创建或传播 token）
  -> switch_root ... nodeforge-agent pre-init
  -> agent: 以 capability 拉取 AgentPlan、以 peer/session/digest 数据面拉 payload，校验后清零 capability
  -> agent: 应用全部 Node override，exec /sbin/init
  -> systemd: nodeforge-agent --first-boot 执行 effective bundle、best-effort 回传事件
```

install Profile 的 BootSession 在 `boot_config_fetched` 完成交付后终止，无 nodeforge-agent
（install 侧 agent 延后 v0.4，且同样无 reconciliation）。nodeforge-agent 在 v0.2 仅 diskless 有。

## 7. v0.3/v0.4 的程序边界

- v0.3（install-post canonical 扩展）：增加 `install-post` phase 四类 canonical action，由安装器（Kickstart `%post`/
Autoinstall `late-commands`）执行，无 nodeforge-agent；保持 catalog schema v5。
- v0.4（统一增强项）：install 侧 first-boot agent（install generation + 磁盘 journal，一次性）；rootfs 继续由
  nodeforged 服务端 operation 生成（不远程重启、不向运行中 agent 下发任务）；多 NIC/VLAN/bonding 令 AgentPlan
  升 v2、BootConfig 保持 v3；增加强制容量闸与 SN+IP draft Node discovery。reconciliation/通用远程控制仍为永久非目标。
