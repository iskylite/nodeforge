# NodeForge v0.2 设计范围

状态：开发中（实现进行中）。本文是 v0.2 的**唯一总纲入口**，负责版本边界、跨分册不变式、实现切片和完成标准。
具体架构、程序、实现、CLI 和操作细节由下列分册各自负责，本文不重复维护其完整细节。

## 实现修订记录

以下修订基于 v0.2 开发验证中的实际发现，直接修改设计而非创建独立验证文档：

### R1. setup 永远写当前最新 schema

**问题**：`generatedConfig` 和 `initialize` 生成 schema v3 配置和 catalog，导致 diskless profile 创建前必须手动执行
`catalog schema-v4 plan/apply` 迁移。

**修订**：schema 版本只是持久化格式的迁移历史，不是操作员选择项。CLI 始终按照
当前最新 schema 执行，每次 shape 变动时代码同步更新版本号。`setup.zig` 的
`generatedConfig()`、`initialize()` 和 `setup --reconfigure` 始终生成当前最新
schema，不需要也不允许 runbook 指示用户手动选择 schema。
`catalog schema-v4 plan/apply/rollback` CLI 命令已从命令树移除；schema-v3 迁移保留用于从 v0.1 升级已有数据。

### R2. resolveDiskless — diskless PXE boot target

**问题**：`boot/target.zig` 的 `resolve()` 只调用 `resolveInstall()`，diskless profile 的 PXE boot 无法生成 GRUB 配置。

**修订**：`resolve()` 按 profile kind 分发：install → `resolveInstall()`，diskless → `resolveDiskless()`。
`resolveDiskless()` 从 boot bundle 取 kernel（kind=kernel）和 initrd（kind=nodeforge_initrd）路径，
生成 cmdline：`nodeforge.config_url=http://<server>:<port>/api/v1/nodes/<node>/boot-config `
`nodeforge.node=<node_id>` `console=ttyAMA0`。

**设计决策**：`nodeforge.session` 和 capability token 不放入 GRUB cmdline。TFTP
渲染虚拟 per-MAC GRUB 配置时通过同进程内部管理请求原子创建 delivery session，
并把 session/token 写入只存在内存中的 per-boot cpio capsule；initrd 从
`/capsule/session` 与 token 文件读取（见 R3）。

### R3. initrd capsule session fallback

**问题**：`initrd.zig` 只从 kernel cmdline 读取 `nodeforge.session`。PXE boot 模式下 GRUB cmdline 不含 session
（TFTP 层无法获知 diskless session ID），initrd 会因 `MissingSession` 而 panic。

**修订**：`initrd.zig` 增加 `capsule_session_path = "/capsule/session"` 常量。当
cmdline 中无 `nodeforge.session` 时，initrd 从自动追加的 per-boot capsule 读取。
TFTP 的虚拟 capsule 路径绑定 node/session，传输后不落盘；普通 CLI prepare 响应
不包含 raw token。两种 session 来源统一由 allocator 持有，避免 cmdline buffer
双重 free。

### R4. setup capabilities — rootfs build 兼容

**问题**：`renderSystemd()` 生成的 systemd unit 使用 `NoNewPrivileges=true` 和 `PrivateMounts=true`，
导致 daemon 内 `dnf --installroot`（profile rootfs build）失败：
- `chroot(2)` 需要 `CAP_SYS_CHROOT`（原 bounding set 缺少）
- RPM scriptlets 创建 setuid 二进制需要特权（`NoNewPrivileges` 阻止）
- mount namespace 隔离导致 rootfs build 后挂载清理复杂化

**修订**：
- 移除 `PrivateMounts=true`
- 禁用 `NoNewPrivileges`（注释说明根因）
- 扩展 capability set：`CAP_SYS_CHROOT CAP_MKNOD CAP_CHOWN CAP_FOWNER CAP_SETUID CAP_SETGID CAP_DAC_OVERRIDE`

### R5. initrd 构建

**实现**：`src/provision/initrd_build_executor.zig` 模块通过 `dracut` 构建最小 initramfs
（network + base 模块，squashfs/overlay 文件系统），注入 `nodeforge-initrd` 二进制到
`/usr/sbin/`，创建 `/init` 脚本和 `/capsule` 目录，重包为 gzip cpio initramfs。
与 `rootfs_os_builder` 一致，使用外部命令（dracut/cpio/gzip），属环境相关执行边界。
`nodeforge assets initrd build` 已接线为同步 CLI：输出先写 `.part`，成功后原子
rename 到专用 initrd store 并注册 catalog；异步 durable operation 属 v0.2.2。

### R6. ISO 导入自动注册 diskless 可复用资产

**修订**：`iso_import.zig` 导入 ISO 时注册的 kernel 资产从 `<source>-installer-kernel` 改名为
`<source>-kernel`。该资产 kind=kernel，既用于 install PXE boot 也用于 diskless boot bundle 的
kernel 字段。命名去掉了 `-installer-` 前缀，明确表示 kernel 通用复用，不需要为 diskless
单独注册 kernel 资产。

**仍需单独构建的资产**：
- `nodeforge_initrd`（kind=nodeforge_initrd）：需要 `nodeforge-initrd` 二进制 + dracut 构建（见 R5）
- `rootfs`（kind=rootfs）：需要 `dnf --installroot` + mksquashfs 构建（`profile rootfs build`）

### R7. node hostname 默认使用 node_id

**修订**：`nodeAddHandler`（`main.zig`）在创建节点时，hostname 未显式指定则默认使用 `node.id`。
`model.zig` `NodeConfig.hostname` 注释同步更新：CLI 默认 node_id，API 直接创建时 null 由渲染层回退。

### R8. ISO 导入 bootloader 路径 use-after-free 修复

**问题**：`iso_import.zig` 的 `importMedia` 函数中，`bootloader_rel`（内容寻址 bootloader TFTP 路径，
如 `efi/176c1c1da6fac219-grubaa64.efi`）在被赋给 `Result.bootloader_asset.path` 后，仍有一行
`defer if (bootloader_rel.len > 0) allocator.free(bootloader_rel);`。该 defer 在函数返回时释放了
这块内存，但所有权已转移给 Result 调用方，导致 use-after-free。

Zig Debug allocator 用 `0xAA` 填充已释放内存，catalog 中 bootloader 资产的 `path` 字段变为
33 字节的 `0xAA` 乱码。DHCP server 的 `catalogBootfile` 从 catalog 读取该乱码作为 TFTP bootfile
下发给 PXE 客户端，PXE 客户端 TFTP 请求一个不存在的文件名，传输失败后回退到本地 disk 启动。
表现为：已注册节点 PXE 启动时 DHCP 正常分配 IP 但 TFTP 传输失败，节点最终从本地磁盘启动
而非进入 diskless/install 模式。

**根因**：`iso_rel`、`kernel_rel`、`initrd_rel` 三个同类字符串均无 defer free（所有权转移给
Result），但 `bootloader_rel` 错误地多了 defer free。对比 `bootloader_destination`（中间路径，
不转移给 Result）的 defer free 是正确的。

**修订**：删除 `bootloader_rel` 的 `defer free`。同步在 `Result` struct 和 `importMedia` 函数
文档注释中明确所有权约定：Result 中所有 `[]const u8` 字段由 `allocator` 分配，所有权随 Result
返回转移给调用方；函数内仅对不转移给 Result 的中间字符串执行 `defer free`。

**影响范围**：仅 Debug 构建受影响（Release 构建下 allocator 不填充已释放内存，但 use-after-free
仍然存在，只是表现为随机字节而非确定的 `0xAA`）。已导入的 catalog 数据需手动修复 bootloader
资产的 `path` 字段。

### R9. diskless agent 启动时机、日志留存与 rc.local 权限

**问题**：
1. `nodeforge-firstboot.service` 的 systemd unit 缺少 `Before=rc-local.service`，无法保证
   agent first-boot 在 rc.local 之前完成。如果 rc.local 中的脚本依赖 agent 写入的配置
   （如网络、hostname），可能因时序不确定而失败。
2. agent first-boot 的 `StandardOutput`/`StandardError` 未配置文件输出，日志只写入 systemd
   journal，在无盘系统（volatile tmpfs upper）中 journal 可能丢失，导致事后无法分析。
3. Rocky/RHEL 系默认 `/etc/rc.d/rc.local` 无执行权限（0644），rc-local.service 不会执行
   其中的指令。install/diskless 后处理写入的 rc.local 内容因此被静默跳过。

**修订**：
1. `nodeforge-firstboot.service` unit 增加 `Before=rc-local.service`，确保 agent 在 rc.local
   之前完成 first-boot 步骤。
2. unit 增加 `StandardOutput=journal+file:/var/lib/nodeforge/firstboot.log` 和
   `StandardError=journal+file:/var/lib/nodeforge/firstboot.log`，使日志同时写入 journal
   和持久文件。日志位置：`/var/lib/nodeforge/firstboot.log`。
3. rootfs build 在 staging 中默认创建 `/etc/rc.d/rc.local`（如不存在）并 `chmod 0755`，
   确保节点启动后 rc-local.service 能正确执行 rc.local 内容。

**影响范围**：`src/http/server.zig`（rootfs build + systemd unit 模板）。

### R10. profile show 资产路径展示与 show 指令输出格式统一

**问题**：
1. `profile show` 只显示资产数量（`assets: 3`），不显示具体路径。操作员无法直接从
   profile show 看到 kernel/initrd/rootfs 等受管文件路径，需要额外执行 `assets list` 或
   查看 catalog JSON。
2. `profile rootfs build`、`profile rootfs plan`、`profile rootfs status`、
   `profile rootfs register` 四个子命令的 human 输出使用原始文本（`profile: xxx\nstate: xxx`），
   与 `node show`、`profile show` 使用的 detail document 格式（带 section 对齐）不一致。

**修订**：
1. `profile show` 新增 "Assets" section，列出每个资产的 `name [kind] -> path (sha256:prefix)`。
2. `profile rootfs build/plan/status/register` 统一改为 detail document 格式，使用
   `cli_document.Section` + `cli_document.Field` 结构化输出，与 `node show`、`profile show`
   对齐。
3. rootfs build CLI handler 在 stderr 输出构建进度（"Requesting rootfs build..."），
   initrd build CLI handler 同样在 stderr 输出分阶段进度。
4. daemon 端 rootfs build 添加 `std.log.scoped(.rootfs_build)` 分阶段进度日志
   （stage 1/5 ~ 5/5 + DONE/FAILED），initrd build executor 同样添加 7 阶段进度日志。
   日志可通过 `journalctl -u nodeforged` 或 daemon 日志文件查看。
5. 所有 detail document 的 human renderer 按 section 分区；点路径展开为父级标题与叶子字段，字段值按终端可见宽度
   对齐，多行值的续行与首行 value 列对齐。JSON/JSONL 字段路径与筛选语义不变。

**影响范围**：`src/main.zig`（profile show / rootfs build / rootfs plan / rootfs status /
rootfs register / initrd build handler）、`src/http/server.zig`（rootfs build 进度日志）、
`src/provision/initrd_build_executor.zig`（initrd build 进度日志）。

### R11. initrd 日志留存到无盘系统

**问题**：nodeforge-initrd 作为 PID 1 在 dracut initramfs 中运行，日志只输出到 console
（串口）。switch_root 后 initramfs 被丢弃，initrd 阶段的启动日志（网络配置、rootfs 下载、
overlay 挂载、handoff 写入等）在切根后无法查看，事后排障困难。

**修订**：
1. initrd `log()` 函数增加全局文件 fd `initrd_log_fd`，在 `/run`（tmpfs）挂载后打开
   `/run/initrd.log`。每次 `log()` 调用同时写入 stderr（console）和文件。
2. switch_root 前，将 `/run/initrd.log` 复制到 overlay upper 的
   `/var/lib/nodeforge/initrd.log`，同时执行 `dmesg` 捕获内核日志到
   `/var/lib/nodeforge/initrd-dmesg.log`。
3. 切根后日志位置：
   - initrd 阶段：`/var/lib/nodeforge/initrd.log` + `/var/lib/nodeforge/initrd-dmesg.log`
   - pre-init 阶段：console（串口），无持久化
   - first-boot 阶段：`/var/lib/nodeforge/firstboot.log` + systemd journal

**影响范围**：`src/initrd.zig`（log 函数 + main switch_root 前日志复制）、`src/agent.zig`
（文档注释更新日志位置说明）。

### R12. diskless 终态未同步终止 boot_session.Store 的 DHCP session

**问题**：diskless 节点 PXE 启动并成功进入 `diskless_running` 后，执行 `node set` 修改
节点属性时返回 409 `property.active_session`，错误信息为 "property mutation is blocked by
an active boot session"。

**根因**：v0.2 有两套独立的 session 存储，职责不同但都绑定到同一个 node_id：

1. `boot_session.Store`（M2/M3，`src/state/boot_session.zig`）：DHCP/TFTP 阶段的协议关联
   注册表。DHCP DISCOVER 时由 `dhcp/server.zig:acquireSession` 创建，用于 DHCP/TFTP/
   boot_config 阶段的节点身份关联和 capability 认证。`hasActive()` 全局检查用于阻止活动
   session 期间的属性修改（`server.zig` 标量/集合/item mutation handler）。

2. `diskless_delivery.Store`（v0.2，`src/state/diskless_delivery.zig`）：diskless 交付
   session，由 `managementBootPrepare`（`node boot-prepare`）创建，跟踪完整的 diskless
   生命周期（`boot_config_fetched` → `rootfs_downloading` → ... → `diskless_running`）。
   `node session cancel` 操作的是这个 store。

两套 store 的 session ID 不同（DHCP session 使用 128-bit 随机 ID，diskless delivery session
使用独立的 128-bit 随机 ID），但都绑定到同一个 node_id。diskless 节点 PXE 启动时，DHCP
会在 `boot_session.Store` 中创建 session（`resolver.resolveWithDeployment` 的
`install_not_armed` gate 只对 `.install` 模式生效，diskless 模式不阻止 session 创建）。

`disklessEvent` handler（`server.zig`）在处理 diskless 生命周期事件时，只操作
`diskless_delivery.Store`（`advanceEvent` + `revoke`），**未同步终止** `boot_session.Store`
中的 DHCP session。当 diskless 生命周期到达终态（`diskless_running` 或 `failed`）后，
`diskless_delivery.Store` 正确到达终态，但 `boot_session.Store` 中的 session 仍保持 active，
直到 2 小时 delivery TTL 自然过期。期间 `hasActive()` 返回 true，导致所有节点（不仅仅是
该 diskless 节点）的 `node set`/`node unset` 等属性修改操作被 409 拒绝。

对比 install 模式：install terminal event（`completed`/`failed`）由 `nodeEvent`/
`nodeLog`/`subiquityReport` handler 处理，这些 handler 通过
`context.sessions.finishDelivery(session_id, reason, ...)` 正确终止了
`boot_session.Store` session。diskless 路径遗漏了这一步。

**修订**：

1. `boot_session.Store` 新增 `finishNodeDelivery(node_id, reason, mono_now, utc_now)` 方法。
   与 `supersedeNode` 类似按 node_id 终止所有活动 session，但允许调用方指定语义准确的
   终态原因（`completed`/`failed`），而非固定使用 `superseded`。

2. `disklessEvent` handler 在 `result == .applied` 且 target 为终态（`diskless_running`
   或 `failed`）时，调用 `finishNodeDelivery` 终止 `boot_session.Store` 中的 DHCP session，
   并通过 `checkpointSessions` 同步持久化。终态原因：`diskless_running` → `.completed`，
   `failed` → `.failed`。

3. `boot_session_store.load()` 已有 `if (record.mode != .install) continue` 保护，
   diskless session 不会从 checkpoint 恢复。但保持 checkpoint 一致性仍是必要的，
   避免当前 daemon 实例中 session 残留。

**影响范围**：`src/state/boot_session.zig`（新增 `finishNodeDelivery` 方法）、
`src/http/server.zig`（`disklessEvent` handler 终态同步）。

### R13. 属性变更强制模式（--force）支持 install 和 diskless session

**问题**：v0.1 的全局 `hasActive()` 检查在存在任何活动 boot session 时阻塞所有节点的属性变更
（`node set`/`node unset` 等），返回 409 `property.active_session`。这在以下场景下过于保守：

1. diskless 节点正在启动过程中（尚未到达 `diskless_running` 终态），操作员需要修改该节点属性。
2. install 节点正在安装过程中，操作员需要修改该节点属性。
3. 其他节点有活动 session，但操作员需要修改一个无活动 session 的节点属性。

R12 修复了 diskless 终态未同步终止 `boot_session.Store` 的问题，但无法覆盖所有场景（例如节点
卡在非终态阶段、操作员需要紧急修改属性等）。

**修订**：

1. **新增 `--force` CLI 标志**：所有 node 属性变更命令新增 `--force` 布尔标志，包括
   `node set`、`node unset`、`node add-values`/`remove-values`/`replace-values`/`clear-values`、
   `node item add`/`set`/`remove`/`move`、`node item add-values`/`remove-values`/`replace-values`/
   `clear-values`、`node replace-items`/`clear-items`。Profile 属性变更命令同样支持。

2. **新增 `forceTerminateNodeSessions` 服务端辅助函数**（`server.zig`）：
   - 调用 `boot_session.Store.supersedeNode(node_id, ...)` 终止目标节点的 install PXE session
     或 diskless DHCP session，并通过 `checkpointSessions` 持久化。
   - 调用 `diskless_delivery.Store.findByNode(node_id)` 查找活动 diskless 交付 session；
     若存在，调用 `diskless_store.cancel(io, session_id)` 撤销全部 capability 并从 checkpoint 移除。
   - 持久化失败时返回 false，调用方返回 503 `session.persist_failed`。

3. **修改 5 个 mutation handler**（`managementScalarMutation`、`managementValuesMutation`、
   `managementItemMutation`、`managementItemValuesMutation`、`managementItemReplacement`）：
   - 解析 `?force=true` 查询参数（`parseForceFlag`）
   - `force=true` 且 owner 为 `node`：调用 `forceTerminateNodeSessions` 终止目标节点 session，
     然后跳过全局 `hasActive()` 检查
   - `force=true` 且 owner 为 `profile`：仅跳过全局 `hasActive()` 检查
   - `force=false`：保持原有行为
   - 错误信息更新为包含 "use --force to override" 提示

4. **客户端函数签名变更**：`scalarMutations`、`valuesMutation`、`itemMutation`、
   `itemValuesMutation`、`itemReplacement` 新增 `force: bool` 参数，`force=true` 时在 URL
   附加 `?force=true` 查询参数。

**安全保证**：
- install plan 在 PXE bootstrap 时已固定为不可变快照（`captureInstallPlan`），终止 session
  不影响正在运行的 installer。
- diskless AgentPlan 在 boot-config 首次签发时已固定（`pinAgentPlan`），终止 delivery session
  不影响已获取 rootfs 和 agent plan 的 diskless 节点。
- Profile 变更只影响下一次 session（install plan / diskless AgentPlan 均为不可变快照），
  不影响正在运行的 session。

**与 `node retry --force` 的关系**：`node retry --force`（v0.1 已有）使用相同的 `supersedeNode`
机制，但仅用于 install 模式的重新 arm，不涉及 diskless delivery session。`node set --force` 等
是新增功能，扩展到所有属性变更操作并支持 diskless session 终止。

**影响范围**：`src/http/server.zig`（`parseForceFlag`、`forceTerminateNodeSessions`、5 个
mutation handler）、`src/http/client.zig`（5 个 mutation client 函数新增 `force` 参数）、
`src/main.zig`（CLI 命令定义新增 `--force` 标志、handler 函数传递 `force` 参数）。

### R14. 多 ISO 展示契约、repository 渲染与 vendor initrd 冷插拔

**问题**：
1. Ubuntu point release 被截断为 LTS series，`22.04.5` 与其他 `22.04.x` 介质无法保持独立身份。
2. repository 虽已导入，但 CLI 不能生成可直接使用的 `.repo`/`sources.list`；Profile DTO 也未展示
   `kind` 和 `boot_bundle`。
3. 自定义 diskless PID 1 替换 installer initrd 的 systemd 后，没有执行原生 udev coldplug。
   ISO 内虽然存在匹配的网卡模块，内核却未按 modalias 自动加载，DHCP 报
   `No broadcast interfaces found`。
4. `node retry` 只 rearm generation，在 `deploy=false` 时仍无法进入 PXE resolver。

**修订**：
1. Ubuntu catalog 版本保留完整 point release；APT `Release: Version` 完整性检查单独使用
   `major.minor` series。资源名、source、profile 和 repository 因而可以按完整版本共存。
2. 新增 `assets repository render`：DNF 从 catalog 生成 `.repo`，APT 从实际
   `dists/*/Release` 提取 Codename/Suite 与 Components 生成 `sources.list`。Profile list/show
   和 Node detail 同时公开 `kind`、`boot_bundle`。
3. vendor-overlay 构建保持 installer initrd 为逐字节不变前缀，只追加 NodeForge userspace。
   NodeForge PID 1 挂载 `/proc`、`/sys`、`/dev`、`/run` 后，启动 ISO 自带
   `systemd-udevd`，依次执行 subsystem/device trigger 和 bounded settle。驱动由 ISO udev 规则
   与内核 modalias 自动选择；禁止写死、额外注入或主动加载特定网卡模块。
4. DHCP 客户端使用显式 PATH 和绝对路径；dhclient/udhcpc hook 将 dotted netmask 严格转换为
   CIDR，并对地址、默认路由写入失败执行 fail closed。
5. `node retry` 先设置 `deploy=true`，再 rearm generation；human 布尔字段统一为
   `true`/`false`。`node show` 将 Runtime 放在首区并展示 profile kind/BootBundle。

**重建不变式**：BootBundle 或 initrd revision 改变后，Profile 的 `rootfs_input_digest` 必须变化；
操作员必须重新执行 `profile rootfs plan` 与带精确 `--if-input-digest` 的 `profile rootfs build`。
旧 rootfs 不得被新 BootBundle 静默复用。

**验收边界**：静态验收必须证明最终 initrd 以 vendor initrd 为相同字节前缀，overlay 不包含人为
添加的网卡模块，并包含 udev coldplug、DHCP client 与 hooks。该验收不能替代真实硬件 PXE 启动。

## 0. 文档结构与阅读路径

### 0.1 总分职责

| 层级 | 文档 | 唯一职责 | 不负责 |
|---|---|---|---|
| 总纲 | 本文 `V0_2_DESIGN.md` | 版本范围、继承契约、跨域不变式、实现切片、完成标准 | 完整命令参数、逐状态转移、操作教程 |
| 架构分册 | [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) | squashfs overlay、共享 rootfs、BootConfig、启动/恢复/安全时序 | CLI 语法、代码模块任务 |
| 程序分册 | [`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md) | `nodeforged`、`nodeforge-initrd`、`nodeforge-agent` 的职责和凭据边界 | 命令参考、逐协议状态机 |
| 实现分册 | [`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md) | 状态机、协议栈、compiler/readiness/validator、builder、迁移 | 操作员教程、方案选型论证 |
| 接口分册 | [`V0_2_CLI.md`](V0_2_CLI.md) | CLI 命令树、参数、CAS、输出和 exit code | 内部模块如何实现 |
| 流程分册 | [`V0_2_DISKLESS_WORKFLOW.md`](V0_2_DISKLESS_WORKFLOW.md) | 从空 catalog 到启用、观测和恢复的端到端操作顺序 | 穷举字段和内部状态转移 |
| 参考资料 | [`DISKLESS_OSS_COMPARISON.md`](DISKLESS_OSS_COMPARISON.md) | 选型依据和开源方案对比 | 规范性产品行为 |

审计文件位于 `docs/audits/`，只记录代码事实、发现和设计修订证据，不定义产品行为。

### 0.2 推荐阅读

- 评审版本范围：本文 -> 架构分册 -> 完成标准。
- 开始实现：本文 -> 程序分册 -> 实现分册 -> 接口分册。
- 使用或验收 CLI：流程分册 -> 接口分册 -> 本文 §9。
- 追溯选型：架构分册 -> 参考资料；无需先读实现分册。

### 0.3 冲突裁决

跨版本范围和完成标准冲突时以本文为准；同一领域的细节冲突时，以职责表中对应分册为准。例如 CLI flag 以
`V0_2_CLI.md` 为准，BootSession 转移以 `V0_2_IMPL_DETAILS.md` 为准，BootConfig/启动时序以
`DISKLESS_FINAL.md` 为准。流程分册中的命令是串联示例，不能覆盖接口分册；参考资料和审计不能覆盖任何设计文档。
发现跨分册冲突时必须同时修正引用方，不能通过再新增一份“最终版”文档解决。

## 1. 进入条件

v0.2 必须基于 `V0_1_DESIGN.md` 的 effective plan，至少满足：

- M0-M4 与 M4.13 全部自动化和双发行版 PXE 回归通过。
- Node/Profile/Resource/Override/Effective/Runtime 所有权不再存在兼容 fallback。
- typed PropertySpec/CollectionSpec/ItemSpec、exact-key CLI/API 和软件 capability index 已经落地。
- Node direct `storage.boot_disk/additional_disks`、默认 `/dev/sda`、单主 ESP 和全部 v0.1 native
  single/LVM/RAID/RAID-LVM mode 已完成双 adapter 渲染与可复现安装验证。
- 历史 schema 数据可迁移到当前最新 schema；CLI、setup、runbook 与全部新写入
  永远只使用当前最新 schema，不要求操作员选择或手动升级到某个版本号。
- 所有普通 CLI handler 已使用统一 OutputDocument，所有资源 mutation 均不要求 Shell 内嵌 JSON。

任何一项未完成时，M5 只能做隔离 spike，不能合入主产品路径或标记里程碑完成。

## 2. v0.2 范围

v0.2 聚焦 diskless 主流程。VMware 是当前可执行的必验环境，不再作为保留项：

| 版本 | 范围 | 对应里程碑 |
|---|---|---|
| v0.2 | diskless only | M5 内存无盘启动 + M7 diskless 后处理（`rootfs-build`/`first-boot`） |
| v0.2.1 | Ubuntu diskless | Ubuntu casper squashfs 叠加方案，支持 Rocky/RHEL 宿主构建 Ubuntu 无盘系统，见 [`V0_2_1_UBUNTU_DISKLESS.md`](V0_2_1_UBUNTU_DISKLESS.md) |
| v0.2.2 | 验证矩阵和可运营性 | Computer Use/VMware 实机闭环纳入每轮验收；继续扩展 x86_64 UEFI、故障恢复与并发矩阵 |
| v0.3 | PXELINUX/BIOS install | M6 BIOS PXELINUX、发行版版本矩阵、`firmware.mode` schema v5 + M7 `install-post`，见 `V0_3_DESIGN.md` |
| v0.4 | 延后增强项 | 多 NIC/VLAN/bonding、大规模容量压测、临时 PXE rootfs 构建节点；install 侧 first-boot agent 与 diskless 同一确定性执行（无 reconciliation，见 §7），见 `V0_4_DESIGN.md` |
| v0.5 | rootfs 形态 | 可切换 rootfs 形态（`ram_rootfs` 全内存模式、`diskless.overlay.mode` 字段），见 `V0_5_DESIGN.md` |

下文 M5-M7 仍按里程碑组织，每节标注其目标版本；未标 v0.2 的内容不计入 v0.2 完成。

### M5：内存无盘启动（v0.2）

- 将 v0.1 的 install Profile 扩展为 `ProfileKind = install | diskless` tagged union（设计名 `ProfileKind` = 代码 `BootKind` `model.zig:329`，v0.2 扩 `install|diskless`）；不增加 discovery Profile。
- boot bundle 的 install source、kernel、NodeForge initrd 与 kernel release 联合校验；派生 rootfs 在
  boot readiness/DeliveryManifest 阶段与 kernel modules ABI 联合校验。
- node-bound、capability-authenticated rootfs HTTP GET/HEAD/Range。
- 小 initrd 联网、配置获取、digest 校验、下载恢复、overlay 和 switch_root。
- v0.2 固定 `squashfs_overlay`（squashfs lower + tmpfs overlay upper）为唯一 rootfs 形态；可切换 rootfs 形态（`ram_rootfs` 等）作为 v0.5 单独项，不在 v0.2。
- `local-only` rootfs/initrd 离线策略、目标静态地址与 MAC reservation 一致性和 BootConfig secret 边界。
- diskless readiness、status、failure quarantine、retry 和事件闭环。
- target-system、software 和 kernel arguments 直接复用 v0.1 effective compiler。

Diskless 不消费安装磁盘选择器，但必须复用同一个 Profile/Node owner、PropertySpec 与 override merge 框架，不能建立第二套
users/packages/network 默认值。凡是描述“最终运行系统”的 system/software/kernel/network override，diskless 与 install
使用同一 effective 语义；只有 partition/bootloader/reinstall/completion 等依赖安装生命周期或持久磁盘的字段不适用。

### M6：支持矩阵增强（BIOS/发行版 -> v0.3；多 NIC/容量 -> v0.4）

- BIOS x86 PXELINUX。
- Rocky/RHEL 系和 Ubuntu 后续 LTS 的显式 adapter capability matrix。
- bootloader、发行版版本差异、错误分类和长期运行回归。
- 最小功能并发、失败恢复验证（大规模容量压测延后 v0.4）。

IPv6 是项目永久非目标，不进入 M6 或后续 schema。BIOS 与更多发行版版本彼此独立，不能捆绑实现。

M6 整体属 v0.3（BIOS PXELINUX、发行版版本矩阵、`firmware.mode` schema v5），不属 v0.2 diskless 主流程；
diskless 最小功能并发已在 M5（v0.2）验证。其中 PXE 阶段纯静态、多 NIC、VLAN、bonding 或下载后切换地址/子网，
以及大规模容量压测，在 VMware 难以有效验证且不属主流程，**延后到 v0.4**（需显式 consumer feature、schema 和验收）。

### M7：补充包和后处理增强（rootfs-build/first-boot -> v0.2；install-post -> v0.3；install-agent -> v0.4；reconciliation 永久非目标）

- archive、受控 script、first-boot provision action。
- bundle CRUD、plan、status、retry、日志脱敏和幂等。
- install、rootfs build 和 diskless 三条链路共用的强类型步骤。
- 已部署节点后处理边界（reconciliation/远程控制为永久非目标，见 §7）。

M7 扩展 v0.1 已有的最小 install-post provision bundle，不改变其 Assets owner。它复用 v0.1 软件
capability/selection，不再引入 `standard_packages` 作为第四个包配置事实源。 v0.2 实现 `rootfs-build`（build 期，
服务端 builder）与 `first-boot`（diskless 切根后 agent 开机顺序执行一次性后处理）phase；`install-post` 随 v0.3
（PXELINUX install）落地，install 侧 agent 延后 v0.4（reconciliation 为永久非目标，见 §7）。

## 3. 从 v0.1 继承的强制契约

v0.2 不是在 M5-M7 命令旁保留旧 M4 语义的并行产品。以下契约原样继承：

- Resource 回答“有什么可用”，InstallSource 是 install/diskless Profile 的共同 OS 来源，Profile 选择共享基线，
  Node 保存机器 direct facts 和 policy override，
  Effective 是唯一编译结果，Runtime/Observed 不反向成为 desired 默认值。
- `show key == --help-full key == parser key == API operation path`；新增 mutable key 必须先注册 PropertySpec。
- scalar collection 注册 CollectionSpec，structured collection 注册 ItemSpec 和稳定 identity；CLI mutation
  继续使用 `list-values/add-values/remove-values/replace-values/clear-values`、直接 `item CRUD` 和可选的
  `replace-items --from-file`；ordered override 首次 item mutation 复用 v0.1 的原子物化语义。
- 所有 leaf command 继续统一支持紧凑 `-h/--help` 和详细 `--help-full`；完整 canonical key、item schema、
  约束和示例从同一 PropertySpec/CollectionSpec/ItemSpec/CommandSpec 生成，不能维护另一套帮助文本。
- 任何 v0.2 CLI 都不得要求 Shell 内嵌 JSON。HTTP transport 和 JSON/YAML 文件输入仍可表达结构化对象，
  但 CLI 必须从 typed flags、`FIELD=VALUE` 或 `--from-file` 构造请求。
- 普通命令继续走 `CommandResult/ViewModel -> OutputDocument -> human/json/jsonl`；rootfs/initrd 导出等
  artifact stdout 命令继续作为明确白名单，不注册含义冲突的 `--output`。
- capability、resource revision、Profile selection、Node delta 和 effective plan 必须共同进入 plan digest；
  renderer/initrd/runner 不得自行实现 fallback。
- 软件 delta 的 canonical path 原样继承 v0.1：`packages.include.add/remove` 与
  `packages.exclude.add/remove` 分别修改两个 Profile 集合；不得在 v4 合并成含义不明的 `packages.add/remove`。
  Profile 与 Node 在 install/diskless 下都继续沿用 v0.1 merge 行为；diskless 只是把 Node software delta 延后到
  切根后的 agent `node-apply`，不把它烤入公共 rootfs。
- 其他 override path 同样不改名：NTP/SSH key 使用各自 `add/remove`，users/partitions 使用 nullable ordered
  replacement，`kernel_args` 使用 `overrides.kernel_args.add/remove` 并按参数名合并。Diskless 不能建立第二套 delta。
- 原样继承 v0.1 的默认普通用户 `nodeforge/asdf1234`、默认 root 密码 `asdf1234` 及其明文
  Profile/Node override 契约；不新增第二套默认用户/密码、默认包列表、target network 或 kernel arguments。

明文 password 是 desired 配置事实，不是节点交付格式。Profile 基线密码由 rootfs builder 使用 v0.1
PasswordHasher 派生发行版兼容的 `$6$` hash 并写入共享 rootfs；但 diskless 不能直接沿用 install 的 per-session salt。
每个 Profile password credential revision 在创建/修改事务中用 CSPRNG salt 生成一次 hash 并安全持久化，普通 plan/build/
`--verify-reproducibility` 始终复用该 hash；只有显式修改密码才产生新 credential/Profile revision 和新 input digest。
Install Profile 继续保持 v0.1 的既有免密与 password 渲染逻辑。Node password/authorized_keys/hosts 等 override
由 DisklessEffectivePlan 编译为 node-bound AgentPlan/target-system projection；最小 BootConfig 不携带账号配置，AgentPlan
只携带该节点必需的 hash/公钥/文件差量，
不携带明文 password 或 Profile 共享 SSH private keys。hash、完整 `target_system`、capability 和请求/响应
body 均视为敏感数据：不得进入 access log、Event、错误信封或 CLI 普通输出，结构化诊断最多报告 changed/fingerprint
和非 secret 摘要。

**`local-only` 不变式**。`local-only` 是 v0.1 删除 `profile.system.connectivity.mode` 后固化的产品不变式，不是
v0.2 新增的 rootfs/Profile PropertySpec。v0.1 因其只有 `local-only` 一个取值、无选择意义而删除该字段（schema v3
迁移第 8 步），故 M5 全部 rootfs/initrd 恒为 `local-only`，不存在 online/远程 mirror 变体，也不提供可设置的
`local-only` 开关。§4.3 与 §9.1 的 `local-only` 检查是对该不变式的强制（移除公网 mirror/metalink/GeoIP/vendor NTP、
禁止隐式 update、initrd URL 用 `server_ip` 字面地址），不是读取某个持久化字段；§5.2 的“隔离 `local-only` 网络”是
HTTP bearer 认证的运维部署假设（隔离 VLAN/ACL），同样不是配置项。其影响贯穿 M5/M7：rootfs 构建只引用本地
repository（无公网 mirror/metalink/GeoIP/vendor NTP），标准包经本地 repo 安装、非标准 tar 包须为预发布本地 asset
且 runtime 禁止隐式下载，initrd 全部 URL 用 `server_ip` 字面地址，HTTP bearer 仅在隔离网络内提供认证、不提供链路
机密性（须以 VLAN/ACL 防旁路窃听）。

产品在任一时刻只使用代码声明的当前最新 catalog schema。文中的 v3/v4/v5 等
仅标识历史持久化 shape 与迁移测试，不构成 CLI 选项或并行运行模式。不能在
已经发布的 schema 号下静默改变 shape；每次迁移都需
plan/digest/apply/rollback、活动 session 保护和 manifest transaction。v0.1 install
Profile 在 v4 映射到 `ProfileKind.install`；install/diskless Profile 都必须引用唯一 InstallSource，diskless Profile
另引用与该 source 一致的完整 boot bundle（source + kernel + nodeforge-initrd，明确不含 rootfs）。build readiness
通过后才允许构建派生 rootfs，boot readiness 通过后才允许
`deploy=true`。
v4-v7 复用 v0.1 已落地的 schema-v3 发布事务机制：plan/digest、journal、apply/rollback 与 daemon 启动崩溃恢复沿用
同一套 `.schema-v3` 风格事务目录与活动 session snapshot，不为每个版本另起迁移原语。`catalog/schema_v3.zig` 现拒绝
`schema_version > 3`，后续各版本新增对应 parser 校验分支并把 config 与 catalog 的 `schema_version` 同步提升；
旧 parser 不得接受半成品 nullable v0.2 shape。

这里的 rollback 只表示 migration transaction finalize 前从 durable journal 恢复 pre-migration snapshot，不等于允许
任意版本 downgrade。已写入目标旧 schema 无法表达的新 kind/field/item 后，downgrade preflight 必须返回
`migration.non_representable` 并列出 resource/path/reason；不得丢字段、改成 nullable 或丢 collection identity/order。
active/recoverable session 始终消费创建时 immutable snapshot，不随 catalog apply/rollback/downgrade 重编译。统一细节见
[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md) §5，v0.3-v0.5 迁移均复用该契约。

### 3.1 schema v3 到 v4 的唯一转换

| v0.1 schema v3 事实 | v0.2 schema v4 处理 | 禁止的替代实现 |
|---|---|---|
| install Profile + `install_source` | 包入 `ProfileKind.install`，共享 policy path 原样保留 | 同时保留旧 nullable source 和新 kind |
| 无 diskless Profile | 新增 `ProfileKind.diskless` + 必填 `install_source` + `boot_bundle`（两者 source 一致） | 在 v3 预留 nullable bundle、把派生 rootfs 塞入 bundle或 mode |
| Node direct identity/network/storage | 原样继承；diskless effective 对 storage 标记 not-applicable | 建立 diskless 私有 network/storage 默认值 |
| Node policy overrides | 原样共享 v0.1 `system.*`、`software.*`、`kernel_args` 合并语义；全部 target-system 差量由最终 rootfs 内的 agent pre-init 写运行根 | 为 diskless 复制 users/packages/kernel args、让 initrd 实现第二套 projector 或按 Node 重建 rootfs |
| install source/repository software revision | rootfs build 和 diskless plan 固定引用同一 capability identity | rootfs 内包集合与 show/effective selection 各自漂移 |
| `AssetKind.kernel` 仅表示 installer kernel | 新增 `runtime_kernel`，由本地 kernel package + modules closure prepare | 默认把 installer kernel 当运行 kernel |
| discovery policy/observation + claim | 原样继承 daemon-owned singleton、观察资源和审计 | 恢复 discovery Profile、startup unknown policy 或 unknown auto-diskless |
| schema v3 provision bundle | v4 一次迁移为 tagged action + canonical phase；v0.2 只允许 `rootfs-build|first-boot` | 依赖未来 schema 才能启动 v0.2 |
| schema v3 effective/digest | v4 compiler 扩展 tagged branch，并保持一个 canonical digest 输入 | renderer/initrd/HTTP handler 各自补默认值 |

v4 migration 只改变 Profile 的外层 discriminated shape；不能借机移动 v3 已冻结 owner。转换计划必须逐个列出
Profile、引用它的 Node、旧/新 effective digest 和 active session 阻塞原因。事务 finalize 前 rollback 恢复完整 v3
manifest；一旦 catalog 已写入 diskless Profile，降回 v3 必须以 `migration.non_representable` 拒绝，不能生成部分 nullable 数据。

## 4. M5 具体继承与变更

### 4.1 Profile 与 effective plan / rootfs 共享模型

M5 把 v0.1 单一 install Profile 扩展成 tagged union（`ProfileKind = install | diskless`）。ISO 导入先产生
InstallSource，install Profile 和 diskless Profile 都从 InstallSource 创建/派生；两者共用 v0.1 的 Profile + Node override
effective compiler 与适用 override 语义。差别只在落地时点：install 由 Kickstart/Autoinstall 把 effective plan
写入磁盘；diskless 先由 Profile revision 生成唯一共享 rootfs lower，再把 Node effective override 写入
per-boot overlay upper。不得为 Node 生成另一份 rootfs。

Node 只持有一个 Profile ref，因此任一 desired revision 只能解析出一个 kind。runtime current state 同样是
`install|diskless` tagged union：同一 Node 最多一个 active session，不保存可同时非空的 install/diskless 状态。
换绑到另一 kind 只允许 `deploy=false` 且无 active/recoverable session；旧 kind 只保留在带 session/digest 的历史审计。

**Profile revision 对应一个共享 rootfs**。rootfs builder 只从 Profile build projection 生成 rootfs（OS 层经
发行版 install-root 工具烤入 Profile software/system + `rootfs-build` phase 业务内容 + target-system），
按 `rootfs_input_digest` 缓存。cache key 覆盖 Profile 固定的 system/software、`rootfs-build` phase、Profile first-boot
manifest/payload/package closure、source/kernel/repository revisions、构建参数和 builder ABI，**不含任何 Node 输入**。
同一 Profile revision 的所有 Node 必须解析到同一个 `rootfs_input_digest`；不同 Profile 若 canonical build projection
完全相同，可以在内容寻址存储层去重，但产品语义仍是 Profile 拥有构建结果。Node 只有在该 Profile rootfs ready 后才可
diskless boot。v0.2 同版交付 M7 的 `rootfs-build`/`first-boot`，其固定 manifest、asset 与 package closure 必须在
rootfs ready 前完整预置；不允许先启动半成品 rootfs 后把缺失 package 留给运行期补齐。reconciliation 为永久非目标
（见 §7），但不能改变历史 session snapshot 指定的 rootfs。

rootfs 是由 Profile build projection 派生、按 `rootfs_input_digest` 存储的只读缓存制品，不是可手工编辑的 catalog
Resource。账号、固定 UID/GID/group/sudo、password hash、公共 `/etc/hosts`、sshd policy、SSH client 公钥/私钥和
`authorized_keys` 都是 Profile 共享基线，在 build 时写入 rootfs。每个 diskless Profile 在首次 rootfs build 前
由 Profile create/clone 的 rootfs-build preparation 自动生成并固定 Profile 级 SSH client keypair 和 sshd host keys；client public key 与配置的管理/其他节点公钥
合并到对应账号 `authorized_keys`，client private key 按 0600 写入账号 `.ssh`。同 Profile 节点因而共享该
SSH 信任基线并可相互免密。自动生成的 Profile client public key 是域内互信的 mandatory key，不属于
`authorized_keys.remove` 可删除的管理员 key；Node 可以追加 key，或删除其他可删除的继承 key。Node password、
`authorized_keys`、公共 hosts 等 override 不修改 rootfs lower，由 agent pre-init 从 AgentPlan 写入 overlay upper，并按
Node effective hosts 重新生成该节点的 `ssh_known_hosts`。hostname、网络、machine-id 与 session credential 同样属于
Node boot projection。sshd 仍必须使用 `/etc/ssh/ssh_host_*_key` 完成 SSH 握手，但在“信任整个 Profile 域”的模型下，
这些文件也是 Profile 公共基线：同 Profile 节点共享 host key 和 host fingerprint，不把 fingerprint 当作 Node 唯一身份。
rootfs 同时写入由 Profile `system.hosts` 中全部 address/names/aliases 与共享 host public key 生成的
`/etc/ssh/ssh_known_hosts`，使同域节点首次连接也无需人工确认。只要 Profile `system.hosts` 覆盖全部节点
address/name/alias、SSH policy 保持启用且后处理没有显式改写这些文件，任意规模的同 Profile 节点都使用同一 client key
完成双向免密，并使用同一 Profile host fingerprint 完成服务端校验。rootfs 经 `profile rootfs plan|status`
（Profile 归属）或 `assets rootfs list|show`（按 digest 查看物理对象）查询，由显式
`profile rootfs build <profile>` 构建；自动化可选 `--if-input-digest` 防漂移，readiness 不暗中触发有副作用的构建。下载经绑定自身的
capability route（per-Node 鉴权，内容按 digest 共享/缓存）。
需要在重建时换掉全部共享 SSH keys，可执行 `profile rootfs build <profile> --new-ssh-keys`；自动化需要锁定先前
plan 时再追加 `--if-input-digest <current>`。服务端重新生成 client keypair + sshd host keys，重算
`authorized_keys`/`ssh_known_hosts`，发布新 Profile revision/new input digest，再直接构建新 rootfs；该操作不覆盖旧
artifact 或 active session，也不输出私钥。轮换导致新旧 rootfs 混跑期间无法保证双向免密且 host fingerprint 改变，
CLI 必须显式警告。
v0.2 已发布 rootfs 只增不删，不设计 delete/GC 或引用计数；Runtime 只记录 build/status/consumer，不反向写入
desired 配置。容量由 status 告警，空间不足时新 build fail closed，回收策略不进入 v0.2。

**Profile 克隆/派生构建**。`profile clone <source> <target>` 从指定 source revision 拷贝完整配置，
新 Profile 创建后是独立、唯一、可直接修改的事实，不在运行时继承 source，不形成多层关系或
额外 rootfs 类型。diskless clone 默认复用 source 的 Profile SSH client keypair/sshd host keys，便于新旧 Profile 节点继续相互免密；
`--new-ssh-keys` 在 clone 事务中显式生成全新共享 keys。`--set KEY=VALUE` 在同一创建事务中修改新 Profile，`--build`
紧接着对新 diskless Profile 执行 plan/build。builder 可在内部复用 source rootfs 的已校验层作为构建优化，
但最终仍发布一个独立、完整、由 target Profile 输入唯一决定的 squashfs。`cloned_from`
只是 audit provenance，不参与 effective 继承。

每个 Profile 必须持久保存 `created_at/updated_at`、直接引用的 InstallSource name/revision/digest，以及
`provenance.origin=create|clone`。clone 额外保存 source Profile name/revision 和 `cloned_at`；CLI 可沿这些不可变直接引用
派生只读 clone chain，但 chain 不进入 effective compiler。`profile show` 同时展示 InstallSource imported time、上述时间与
lineage，保证能回答“这个 Profile 基于哪个 OS 源、从哪个 Profile 的哪个版本何时复制而来”。

**无盘属性适用性**。v0.1 已梳理的全部属性在 diskless Profile/Node 上的适用性如下；`not-applicable` 表示
该字段对 diskless 返回 `property.not_applicable` 且使 not ready，除非该字段本就为空：

| 属性（v0.1 canonical） | diskless 适用性 | 说明 |
|---|---|---|
| Node `mac`/`arch`/`profile`/`pxe.ip_reservation`/`hostname`/`deploy` | 可用 | `deploy` 闸 diskless PXE；`pxe.ip_reservation` 为 DHCP 预留 |
| Node `http_accel` | 可用（UEFI） | 仅 GRUB 取 kernel/initrd；BIOS not-applicable；不治理 initrd rootfs 下载（见 §5.1）|
| Node `network.*` | 可用 | 目标系统网络，见下文网络标准 |
| Node `storage.boot_disk`/`additional_disks` | 持久但不消费 | diskless effective 标记 not-applicable；保留以便日后绑 install Profile |
| Node `overrides.software.*` | 全部可用（node-apply） | repositories/environment/groups/tasks/packages include/exclude 原样复用 v0.1 merge；解析为 pinned local repository/package closure 后重放，不改变公共 rootfs |
| Profile `system.*`（localization/ssh/users/security） | 可用 | 完整共享基线进入 rootfs；Node override 按 v0.1 effective 语义写 overlay upper |
| Profile `system.hosts` | 可用 | v0.2 structured collection（`id/address/names`）；Profile 进 rootfs，Node `overrides.system.hosts` 写 upper |
| Profile `system.connectivity.time_sync`/`ntp_servers` | 可用（受限） | local-only 不变式：NTP 只用显式服务器，无 vendor NTP |
| Profile `software.*` | 可用（build 期） | Profile effective software 构建公共 baseline；Node effective 的 repositories/environment/groups/tasks/packages 全量 delta 相对 manifest 解析为受保护的 add/remove closure，由 node-apply 从本地 pinned repo 应用 |
| Profile `kernel_args` | 可用 | PXE cmdline 追加，initrd 透传 |
| Profile `diskless.overlay.tmpfs_percent` | 可用（diskless-only） | 控制 tmpfs upper 预算 |
| Profile `diskless.failure.max_attempts`/`backoff_seconds` | 可用（diskless-only） | 达预算 quarantine；不负责 BMC 重启 |
| Profile `diskless.provision.bundle` | 可用（diskless-only） | 引用 provision-bundle（rootfs-build/first-boot phase）；Node 可用 `overrides.diskless.provision.bundle` 替换自身 first-boot，见下文 |
| Profile `install.*`（source/storage/bootloader/apt/completion/updates/proxy/reinstall/post_install.bundle） | not-applicable | install-only（`install.apt.fallback` 是安装器 apt 行为、非仓库源），对 diskless 返回 `property.not_applicable` |

**diskless Node override 规则**。diskless 对所有跨 kind 的 target-system policy 原样复用 v0.1 override namespace、
类型、merge 优先级和 effective compiler：Profile 是公用基础，Node override 是该节点最终结果。localization、
time sync/NTP、password、users、`authorized_keys.add/remove`、sshd、security、公共 hosts、software 的全部
repositories/environment/groups/tasks/packages include/exclude，以及 kernel args 都参与 Node effective plan；它们只改变 `desired_plan_digest`，不改变
`rootfs_input_digest`。服务端把完整 Node effective 差量编译为 immutable AgentPlan/`node_apply_projection`，随
session snapshot 固定；给 initrd 的最小 BootConfig 只包含 AgentPlan locator/digest/size/expiry，不包含高层配置。
`switch_root` 直接进入 rootfs 内的 `nodeforge-agent --pre-init`：agent 使用继承的 bootstrap 网络从服务端拉取并校验
AgentPlan 与全部 Node payload，清零短时 `agent:read` token 后，使用完整运行根的库和工具先执行 pinned software transaction，再运行 TargetSystem
finalizer，把 password/users/SSH/hosts/network/NTP/localization/security/machine-id 等最终结果写入 overlay upper，最后
`exec /sbin/init`。systemd、renderer、sshd 和业务服务因此只会看到覆写后的最终状态。所有 Node override 每次 PXE 启动重放，
因此 tmpfs upper 重启丢失也不会要求人工重配。
这里没有第二套 initrd projector：同一个 agent/TargetSystem runner 承担 install 等价的最终系统配置；pre-init 只是它在
真正 PID 1 前的执行入口。显式 first-boot managed-file/script 在 systemd 启动后继续按固定 plan 执行，力度与 install 后处理一致。

跨 kind 的能力对照如下；“一致”指同一 canonical path、同一 merge 后得到相同最终系统语义，执行时机与持久介质可以不同：

| Node override | install 落地 | diskless 落地 |
|---|---|---|
| `overrides.system.localization.*` | installer 写目标盘 | agent pre-init 写 upper |
| `overrides.system.connectivity.time_sync` / `ntp_servers.add/remove` | installer 写配置并启用服务 | agent pre-init 写配置和 enable/mask 状态 |
| `overrides.system.ssh.*` / authorized keys delta | installer 写目标盘 | agent pre-init 在 sshd/systemd 启动前写 upper；mandatory Profile client key 保护不变 |
| `overrides.system.users` | installer 创建最终账号 | agent pre-init 原子物化 passwd/group/shadow/home/sudo 到 upper |
| `overrides.system.security.*` | adapter 渲染安装配置 | compiler 固定 boot-required kernel args；agent pre-init 写 policy/enablement 并在 exec systemd 前 finalizer 验证 |
| `overrides.software.repositories/environment/groups/tasks/packages.*` | installer 解析并安装 effective closure | agent pre-init 从 pinned local repository revision 应用 exact add/remove closure，再运行 target-system finalizer |
| `overrides.kernel_args.add/remove` | installer PXE + 目标 bootloader | 当前 PXE kernel cmdline；每次启动重放，无持久 bootloader |
| postprocess bundle reference | `overrides.install.post_install.bundle` 由 installer 执行 | `overrides.diskless.provision.bundle` 替换该 Node 的 first-boot，由 agent 执行 |

纯安装机械字段 `overrides.install.storage.*`、bootloader、apt installer policy、completion、updates、proxy、
reinstall policy 没有“最终运行系统”的 diskless 对象，因此仅这些字段 not-applicable；这不减少共享 target-system
配置面。任一已注册为 diskless 可用的 override 都必须在 adapter/build manifest 中有可验证 agent pre-init consumer 与 prerequisite，
不能出现 CLI 接受但 agent 忽略，或因 Profile baseline 未携带必要工具而运行时才发现不可执行。
software exclude/remove 事务必须保护当前 kernel/modules、PID 1、network renderer、package manager、nodeforge-agent、
sshd（SSH enabled 时）及其必需依赖；若 effective delta 会移除 protected closure，readiness 以稳定 reason 拒绝，
不能静默保留而伪装 override 已生效。
为保证 Node 可以从 Profile 的 disabled 值覆写为 enabled，builder 必须按 adapter 的
`diskless_override_capabilities` 把 sshd、NTP、firewall、发行版适用的 SELinux/AppArmor policy/tool 与 package manager
支持闭包烤入公共 rootfs，只把 Profile 选择的默认 service state 写为 baseline；这些 prerequisite revision 进入
`rootfs_input_digest`/manifest。不能因 Profile 当前关闭某功能就裁掉其已声明可 Node override 的执行能力。

**无盘以太网配置标准**。`pxe.ip_reservation`（旧 `node.ip` 已由 v0.1 重命名），且匹配 MAC、prefix、gateway、DNS 和
renderer capability 必须在 effective/readiness 阶段共同校验。initrd 下载期间不切换地址，也不写 renderer 配置；
`switch_root` 后由 agent pre-init 在最终 rootfs 写入持久网络配置，再由 NetworkManager/Netplan 接管同一地址；不一致必须在切根前的
server/initrd 检点或真正 init 前的 agent 检点以稳定 reason 失败，不能回退到未声明
DHCP 目标配置。PXE 阶段纯静态、多 NIC、VLAN、bonding 或下载后切换地址/子网不属于 M5，亦不在 M6 范围，延后到 v0.4。
renderer 由 adapter capability 选择：RHEL 系写 NetworkManager connection、Ubuntu 写 Netplan，均以
`match.macaddress`/`connection.mac-address` 绑定 `node.mac` 对应的启动 NIC；`network.mode=dhcp` 时目标系统在
`switch_root` 后对同一 NIC 重新 DHCP（沿用该 MAC 的 `pxe.ip_reservation`），不写静态配置；`network.mode=static` 时
写静态配置且 `network.address` 须等于 `pxe.ip_reservation`，initrd 与目标系统不切换地址。

M5 新增的最小 Profile policy 面：

| Profile path | 类型/默认 | Node override | 约束 |
|---|---|---|---|
| `diskless.overlay.tmpfs_percent` | 10-80 的整数，默认 50 | `overrides.diskless.overlay.tmpfs_percent` | v0.2 固定 `squashfs_overlay`，控制 tmpfs overlay upper 预算 |
| `diskless.failure.max_attempts` | 1-10，默认 1 | `overrides.diskless.failure.max_attempts` | 达到预算后 quarantine |
| `diskless.failure.backoff_seconds` | 0-3600，默认 0 | `overrides.diskless.failure.backoff_seconds` | 不负责 BMC 重启 |
| `diskless.provision.bundle` | nullable provision-bundle ref | `overrides.diskless.provision.bundle` | Node override 完整替换该 Node 的 first-boot；引用 bundle 只允许 first-boot item，不得含 rootfs-build |

`system.hosts` 是 v0.2 对 target-system 的正常扩展，不是通用文件 patch。Profile 与 Node 共用同一
ItemSpec；Node 第一次对 `overrides.system.hosts` 执行 item add/set/remove 时，复用 v0.1 `system.users`
的 ordered replacement 语义，先原子物化当前 Profile hosts 再修改；unset 后恢复继承。

### 4.2 Assets 资源树

v0.2 延伸 v0.1 的 Assets tree，不新增顶级 `rootfs`、`initrd` 或 `boot-bundle` 命令：

```text
nodeforge assets rootfs list|show|validate
nodeforge assets runtime-kernel prepare|list|show|validate
nodeforge assets initrd build <name> --from-install-source <source> --kernel-release <release>
nodeforge assets boot-bundle create|set|list|show|validate
nodeforge profile capabilities show <profile>
nodeforge node capabilities show <node>
```

rootfs manifest 的 files/features、initrd modules/features 和 boot-bundle compatibility constraints 若为 scalar
collection，使用 values 命令；manifest entries 或 build steps 若为 structured collection，使用 item CRUD/
`replace-items --from-file`。Assets detail 的 stored/capabilities/runtime sections 继续遵守 v0.1 输出和 exact-key 规则。

资源最小 manifest 契约。boot bundle 不引用 rootfs，避免 Profile/effective build input 与 rootfs 输出之间的
循环依赖；一次启动由 DeliveryManifest 绑定 rootfs content digest：

| Resource | 必填持久事实 | 只读派生事实 |
|---|---|---|
| rootfs | format、arch、content digest/size、uncompressed size、builder version、software capability revision、Profile build digest、features | validation/readiness、rootfs consumers |
| runtime-kernel | source/package revision、arch、kernel release、content digest、modules/package closure digest | initrd/rootfs modules ABI compatibility |
| nodeforge-initrd | arch、kernel release、content digest/size、builder version、modules/features | validation/readiness、supported overlay/network features |
| boot-bundle | install-source ref、runtime-kernel ref、nodeforge-initrd ref、arch、kernel release、required features | joint boot digest、build compatibility/readiness、consumer count |

Resource name 不是内容身份；内容或 builder 输入变化必须发布新 revision/digest。Boot bundle 在 transaction 中
pin source/kernel/initrd revision 并派生 joint boot digest。rootfs 是 `rootfs_input_digest` 对应的只读派生缓存；
DeliveryManifest 固定 boot bundle revisions + rootfs SHA-512，不能把交付输出反写 Profile。

### 4.3 ISO、Profile 与 diskless 制品关系

ISO import 一次原子生成：

- ISO asset；
- 内容寻址 UEFI bootloader（媒体存在时）；
- vendor installer kernel（通用 `kernel` asset）；
- vendor installer initrd（仅安装器使用的 `installer_initrd` asset）；
- repository/media tree；
- InstallSource；
- 一个引用该 InstallSource 的默认 install Profile。

ISO import 不生成 rootfs、NodeForge initrd、boot bundle 或 diskless Profile：

- `assets initrd build --from-install-source` 以 InstallSource 的 vendor initrd 为
  字节级不变基底，追加 NodeForge init/agent/DHCP overlay，发布新的不可变
  `nodeforge_initrd` asset；
- `assets boot-bundle create` 固定同一 tuple/kernel release 的 kernel 与
  NodeForge initrd；多个 bundle/发行版/版本/架构可同时存在；
- `profile create --kind diskless --boot-bundle` 创建 diskless Profile，并仍
  引用 InstallSource 以取得 repository/software capability；
- `profile rootfs build` 从 diskless Profile build projection 构建共享、
  内容寻址 rootfs。rootfs 不属于 boot bundle，启动时由 DeliveryManifest
  将选定 bundle revision 与 rootfs digest 固定为同一 session snapshot。

```text
ISO
 └─ InstallSource ── default install Profile
     ├─ vendor kernel ───────────────┐
     ├─ vendor installer initrd      │
     │    └─ initrd build overlay ── NodeForge initrd
     └─ repositories                 │
                                      └─ BootBundle
InstallSource + BootBundle ── diskless Profile ── rootfs build ── rootfs
Node + diskless Profile ── DeliveryManifest(bundle revision + rootfs digest)
```

Rootfs/initrd 构建的工具链和驱动放置属于 M5 的显式实现边界，而非未说明的 builder 自由度：

- NodeForge initrd 首选保留 ISO vendor installer initrd 的完整第一个 member，
  仅追加 NodeForge gzip/newc overlay；因此发行版专用 patch、firmware 和 `.ko`
  不会因 server host 的 dracut 环境而丢失。没有 InstallSource 时才允许通用
  dracut fallback。
- fallback 的通用 NIC 闭包为 `virtio_net`、`e1000e`；`vmxnet3` 只服务使用
  VMware paravirtual vmxnet3 NIC 的目标，不是物理机或当前 e1000e VMware VM
  的必需项。vendor initrd 已携带时保留，不主动删除。
- 获取 BootConfig/rootfs、校验并挂载 lower/upper、完成 `switch_root` 前必需的 NIC、firmware、HTTP、SHA-256、
  squashfs、tmpfs 和 overlay 能力必须放入 initrd；缺一项即 bundle not ready。
- 只在切根后使用的 GPU、RDMA、监控、额外存储或业务驱动放入 rootfs，并与同一 kernel release 的 modules manifest
  联合校验。任何驱动若被启动路径提前需要，就必须提升为 initrd required feature，不能靠运行时偶然加载。

### 4.3 交付与运行态

- 新增 node-bound boot-config DTO、rootfs GET/HEAD/Range、ETag/If-Range 和 capability auth。
- initrd 消费的字段来自 session effective plan snapshot；digest、required features 和 URL 不能由 HTTP handler 临时拼默认值。
- rootfs download、verify、overlay、switch_root、quarantine、retry 和事件使用独立 runtime state，不写回 Profile。
- boot bundle 的 source/kernel/initrd revision、kernel release、arch 与 feature compatibility 由 build readiness
  校验；派生 rootfs SHA-512/modules ABI 在 boot readiness 与 DeliveryManifest 阶段加入联合校验。
- `local-only` 不变式下必须移除/禁用公网 mirror、metalink、GeoIP 和 vendor NTP 默认值，启动时禁止隐式
  update/upgrade/package install；time sync 关闭或只使用显式服务器。initrd 的 BootConfig、rootfs 和 event URL
  必须使用 NodeForge `server_ip` 字面地址，M5 不做 DNS fallback，也不访问其他地址。出口 ACL 是纵深防御，
  不能替代 rootfs 静态检查、隔离网抓包和运行时 fail-closed。

DisklessEffectivePlan 至少固定：Profile build projection/rootfs input digest、Node/resource revision、arch、boot bundle、
kernel/initrd revision、network、Node identity projection、kernel arguments、overlay 配置（v0.2 固定 squashfs_overlay +
tmpfs_percent）、按 initrd/agent 分域的 required features 和全部 node-bound URL。BootSession 保存该计划的 digest 和 immutable
capability identity；rootfs output digest 不进入会导致构建环的 desired plan，而是在 session DeliveryManifest
中与 plan 一起固定为 delivery snapshot。服务重启只能按相同 delivery digest 恢复，不能重新编译后继续旧 session。

Boot-config 只返回 initrd 实际需要的最小 DTO：session/scoped capabilities、bootstrap network、rootfs URL/digest/size、
Range recovery、overlay、AgentPlan URL/digest/size/expiry、consumer feature 摘要和 event URL；不包含 hostname、users、
password hash、SSH、hosts、software 等 Node 运行根配置。完整差量只存在于 agent 拉取的 AgentPlan，其中不含明文密码
或 Profile 共享 SSH private keys；
`/var/lib/nodeforge/boot.json` 只保存 plan/config digest 与非 secret 摘要，mode 0600，且不保存 secret
或 token。能力拆成 single-purpose、bounded-replay 的 `config:read`、initrd 只读 rootfs 的 `artifact:read`、agent
只读固定 plan/payload closure 的 `agent:read` 和只写 `event:append`，分别绑定
node、session、audience、HTTP method/path、plan digest 与短有效期；不能访问其他 Node rootfs，也不能升级为
management credential（management credential 指 daemon 管理 API 的服务端管理员鉴权，与 boot 传输 token 是不同凭据
类型、不同鉴权路径：传输 token 仅授权该 Node/session 的精确 config/rootfs/AgentPlan/payload GET/HEAD/Range 与 event POST，无 catalog 写、无管理
API 调用能力，防止 per-boot 传输 token 被滥用为服务端管理权限）。此 token 与已永久移除的可续期 enrollment
credential 无关：enrollment 是运行期节点认证 secret，已永久移除；此处 token 仅是本次 boot 中 initrd/agent
拉取不可变输入的传输鉴权。
`config:read` 首次授权时固定 immutable bytes/config digest；在 initrd 以相同 digest 上报 `diskless.initrd_started` 前，
只允许短窗口重取相同 bytes，确认或过期后撤销。未知/无效 token 只产生不关联 session 的安全审计；只有验证成功的 claim
发生 scope/path/node 越权时才可归责其所属 session，不能让外部 401/403 探测推进 victim session 或 quarantine。
initrd 在 `switch_root` 前清零 config/rootfs-artifact token；短时 `agent:read` 与 `event:append` token 以独立 0400
文件跨 `/run` 交给 agent。agent 预取并校验全部输入后、修改目标系统前清零 agent token，first-boot 完成后删除 event
token，二者永不写入 boot.json。首次 hash mismatch 删除 partial 后完整重试；重复完整 mismatch、
feature mismatch、过期 token、越权 Range、switch_root 失败进入稳定 error code、`diskless.failed` 和 quarantine。

交付给 initrd 的 BootConfig DTO 使用与 `ProfileKind` 一致的 `kind` 判别字段，废弃 legacy `mode="diskless"` 写法；
install 与 diskless 共用同一判别字段，install 交付内容（config/event URL、capability）不变，仅把判别字段对齐为
`kind`。diskless BootConfig 的 `schema_version` 提升到 v2（BootConfig DTO 自身版本，与 catalog `schema_version`
v3/v4 分属不同命名空间）并携带上文的 DTO 字段。`required_features` 按 consumer 分为
`{initrd:[...],agent:[...]}`：initrd 集合至少含 `node-identity-handoff-v1`/`agent-plan-handoff-v1`，agent 集合至少含覆盖完整
TargetSystem/software transaction 的 `node-apply-v1`，静态目标网络另需 agent 的 `static-network-v1`。boot bundle initrd manifest 与
rootfs agent manifest 分别声明支持集合；旧 consumer 缺失或冲突时必须在 readiness/切根前以稳定 error code 拒绝，
不允许 initrd 代替 agent 解释高层字段，也不得回退降级。

**BootConfig 定义与 boot 写入流程**。BootConfig 是 per-boot、per-Node 的短时 DTO，由服务端按 session
DisklessEffectivePlan snapshot
在 boot 时生成、initrd 经 node-bound capability 拉取；它携带 boot 所需参数（session/capability token、bootstrap
network、rootfs URL/digest/size + Range recovery、overlay 配置、AgentPlan locator/digest/size/expiry、event URL），不携带
完整 Node 配置。rootfs lower 可共享、per-Node 差异由 agent pre-init 从服务端取得 AgentPlan 后落 overlay upper。写入流程：① DHCP/TFTP 引导 boot bundle
（kernel + 共享 NodeForge initrd）和 per-session credential capsule；kernel cmdline 只携带无密钥的 config URL、
node/session 与 `kernel_args`，config token 由 GRUB 作为第二 initrd cpio 追加；② initrd 从 capsule 读取 token，
有界重放地拉取固定 BootConfig，校验后用 config digest 确认并撤销 token；③ initrd 下载、校验并挂载 rootfs lower，
建立 upper/merged，只将 AgentPlan locator 与 agent/event token 写入 `/run` handoff，不下载 Node 配置/payload、不写目标系统配置；
④ 清除 config/rootfs-artifact token；⑤ `switch_root` 执行 `nodeforge-agent --pre-init`，agent 通过 bootstrap 网络拉取并校验
AgentPlan/全部 payload、清除 agent token，再应用全部 Node override 后 `exec /sbin/init`；⑥ NM/Netplan/sshd 等只看到
最终配置，同一 agent 的 systemd unit 再执行 effective `first-boot`。
token 与 `/var/lib/nodeforge/boot.json` 边界见本节上文。

**boot-time 职责划分与共享参数来源**。静态/公共内容（包、locale、账号/password、Profile SSH client/host keys、
authorized_keys、hosts、sshd policy）全部在 Profile rootfs build 烤入只读 lower；动态/按节点/按启动参数
（server 端点、capability token、network、hostname、machine-id 和 target-system delta）经 node-bound AgentPlan 交付；
kernel cmdline 携带无密钥 config URL 与 `kernel_args`，单用途 config token 位于 per-session credential capsule。
initrd 只验证 AgentPlan locator 并交接到 `/run`，不取得/解释 target-system 字段，也不写 overlay upper 中的配置。
boot-time 的 Node projection（含网络配置）由 rootfs 内的 **nodeforge-agent pre-init** 完成：`switch_root` 后它先从服务端
取得 session 固定的 plan/payload，再在真正
systemd 启动前写 NetworkManager/Netplan 与全部 Node effective 配置，然后 exec `/sbin/init`；renderer 接管继承的
同一地址。systemd 启动后同一 agent binary 再以 unit 执行 effective `first-boot`（一次性，无远程控制、无 reconciliation）。

跨 DHCP/TFTP/HTTP/initrd 的 canonical BootSession 状态机固定为：

```text
boot.dhcp_discover -> boot.dhcp_offer -> boot.dhcp_ack -> boot.tftp_rrq -> boot.tftp_complete
  -> boot.config_fetched -> diskless.initrd_started -> diskless.rootfs_downloading
  -> diskless.rootfs_verified -> diskless.rootfs_mounted -> diskless.switching_root
  -> diskless.agent_configuring -> diskless.running
```

历史概要中的 `pxe_seen`、`bootfile_sent`、`diskless_config_fetched` 分别是 `dhcp_discover`、携带 bootfile 的
`dhcp_ack`、`boot_config_fetched` 的展示别名，不是额外持久状态；v0.2 API、Event 和持久化只使用 canonical 名。
`<kind>.failed` 可从任一非终态进入，`boot.expired` 只能由服务端超时进入；两者都是本次 session 的终态。`node_status` 可以投影
上述状态，但不得用 `ready/booting/downloading` 等粗粒度枚举替代而丢失早期诊断证据。重复同阶段上报幂等，跳跃、
回退、错绑 node/session 一律拒绝。

canonical BootSession 只覆盖 DHCP/TFTP/boot_config 共享前缀和 diskless 尾部；install Profile 的 BootSession 在
`boot_config_fetched` 完成交付后终止，installer 进度（`installer_started`/`installing`/`installed`/`provisioning`/
`completed` 等）属于 `node_status` 部署投影，不进入 BootSession canonical phase。当前 `src/state/boot_session.zig`
的 `Phase` 枚举把 install 侧阶段与 diskless 阶段混排，v0.2 实施时须把 install 交付后的进度移出 BootSession，仅在
`node_status` 投影保留，使 BootSession 与部署投影职责分离。`node_status` 对外必须使用带 namespace 的 canonical 名：
diskless 终态为 `diskless.running`，不得新增无 kind 的 `running` 或并列 install/diskless 字段；早期 PXE/TFTP
诊断状态也保留为 `boot.*`。内部 Zig enum 可使用 snake_case，但只允许一个显式映射表。diskless/install 状态机
统一与 `node list`/`node status` kind
感知投影（`KIND` 列、时间戳按 kind 泛化、`BootKind` 扩 `install|diskless`）的细化见 `V0_2_IMPL_DETAILS.md` §1。

Quarantine 是 Node 级 boot gate，不是 BootSession phase。一次 attempt 进入 `failed` 后按 session snapshot 的
`max_attempts/backoff_seconds` 计数；达到预算才进入 quarantine，并拒绝新 session。`diskless.running` 是启动成功
终态。agent pre-init `node-apply` 成功并 exec `/sbin/init` 前仍属于 boot attempt，失败进入 `diskless.failed`/
quarantine 计数；只有真正 init 启动后的 `first-boot` 失败属于运行期，令 `postprocess=degraded` 而不倒退 BootSession。

`nodeforge node diskless retry <node>` 只清除终态 failure quarantine；不创建 install generation、不修改 Profile、
不远程重启。存在活动 session、`deploy=false`、Profile 非 diskless 或 desired digest 已变化时 fail closed。

### 4.4 无盘构建方案

M5 rootfs 构建为 Profile 共享 rootfs：rootfs builder 从 Profile build projection 生成 rootfs = OS 层（Profile software/system 经
发行版原生 install-root 工具烤入只读 lower）+ `rootfs-build` phase 业务内容（managed-file/archive/script/package 追加到 lower）
+ Profile 级 target-system 骨架。rootfs 按 `rootfs_input_digest` 缓存、跨 Node 共享；OS 层可由 builder 内部按 software
digest 缓存复用（业务内容变更不重建 OS 层），但对设计透明、不作为独立 Resource。rootfs-build 与 first-boot 共用
§5.4 统一 action 与 §5.2 八步执行契约，差异只在执行者与目标上下文（见 §5.4）。

**rootfs 构建（OS 层）**。OS 层从 boot bundle 固定 revision 的 install source/repository capability 用发行版原生
rootfs 工具生成：RHEL/Rocky 默认使用目标版本 `dnf --installroot`，Ubuntu 默认使用 debootstrap + local apt；
lorax/livecd/mkksiso 只有 adapter 明确声明为等价实现时才允许使用，不能默认用安装 ISO 制作工具代替 rootfs builder。
构建在与目标 distro/version/arch/
kernel_release 一致的环境中运行。builder 固定 software capability revision，消费与 Profile 查询相同的
environment/group/task/package selection（metapackage 仍按 `software.packages.include` 选择），并按 local-only 不变式
移除/禁用公网 mirror、metalink、GeoIP 和 vendor NTP，只引用本地 repository。OS 层可按 software capability revision
内部缓存复用；build manifest 记录 builder image/environment digest、构建工具版本与命令、module/firmware 清单、
generated locales、available timezones/keyboards、完整共享账号基线（passwd/group/shadow/home/shell/sudo membership/
authorized_keys）、capability revision、Profile system/software digest 和输出 squashfs digest/size/uncompressed size。

**rootfs-build phase**。provision bundle 的 `rootfs-build` phase 步骤在 OS 层之上向只读 lower 追加业务内容：managed-file、
archive、受控 script 和经本地 repo 解析的 package action（受限 `packages`/`group`/`environment`/`selection`，如更新
`/etc/hosts`、写入 motd、预装补充包）。该 phase 由服务端 rootfs builder 执行（无节点 agent），builder 提供
chroot/staging 上下文使步骤以 `/` 为目标写入 lower，步骤作者不感知暂存目录。OS/source/repository revisions +
rootfs-build inputs + first-boot fixed payload + Profile system/software + builder ABI 共同决定
`rootfs_input_digest`；构建输出另以 content SHA-512 标识。

**first-boot 输入固定**。builder/boot-prepare 预先解析 package closure，并把固定包列表、包管理器、nodeforged
受管 HTTP Yum/APT repository URL 与 revision/GPG policy 写入 immutable AgentPlan。first-boot 允许访问这些
local-only 受管软件源安装 RPM/DEB，但必须显式禁用系统其他源，禁止公网 mirror、metalink 和运行时依赖漂移。
默认仓库集合继承 Profile 当前 InstallSource 在导入时由 nodeforged 建立并发布的 Yum/APT 源；操作员通过 CLI
明确增加的仓库在该默认集合上合并、去重并进入同一 pinned AgentPlan，未显式配置的其他系统源不得被使用。
managed-file、archive、script 以内容寻址形式写入 Profile 本地 payload，或由 Node override 的 agent pre-init 使用
`agent:read` 一次性预取；first-boot 不再联网读取配置或 artifact。任何缺包、asset digest 不匹配或 payload
超预算都在 build/readiness 或 agent pre-init 阶段 fail closed。

**构建环境保真**。rootfs-build phase 执行 package/script 时按动作所需提供构建环境：纯 userspace 动作（写文件、装普通包、
配置）只需 chroot；触及硬件/内核的动作（装驱动、dkms、重生成 initramfs、装载内核模块）须 bind-mount `/dev`/`/proc`/
`/sys` 并使用与目标 distro/version/arch/`kernel_release` 一致的内核，否则驱动/dkms 类安装不适用；内核与 OS 一致时需
加载完整内核态以满足模块构建。v0.2 本地 server builder 按此保真执行；更高保真的临时 PXE rootfs 构建节点在真实
硬件与内核态构建 rootfs，需专用 builder boot、完整内核态/设备/proc 和有界上传 claim，作为 v0.4 后续设计，v0.2 不实现。

**rootfs 缓存与共享**。同一 Profile revision 的 `rootfs_input_digest` 唯一；其密码 hash、公共授权 key 等敏感
build 输入参与 digest 计算时必须先进入带字段域分离的 canonical secret hash，不得出现在 plan 输出或日志。节点经绑定
自身的 capability route 下载（per-Node 鉴权），只由 `profile rootfs build <profile>` 显式触发；可选
`--new-ssh-keys` 先生成并固定新 Profile client/host keys revision，再构建其新 input digest；
readiness 只读、不暗中构建。`profile rootfs status <profile>` / `assets rootfs list|show` 查询（见 §4.1/§4.2）。

**构建期与启动期边界**（只读 lower vs agent pre-init 写 per-boot overlay upper）：

| 内容 | rootfs build（公共 lower） | diskless boot（节点 upper） |
|---|---|---|
| locale 数据包、tzdata、keyboard 数据 | 安装并写 Profile 选择 | 有 Node localization override 时写 effective 选择 |
| openssh-server 二进制/unit | 安装并写共享认证策略、Profile SSH client/host keys、authorized_keys、ssh_known_hosts | 应用 Node SSH override |
| `software.*` 包 | 从本地 repo 安装并记 manifest | Node software override 由 agent `node-apply` 按 session 固定的 local-only repository revision/package closure 安装或移除 |
| `system.users` | 创建 passwd/group/home/shell/sudo，写 password hash 与 authorized_keys | 将 Node users/password/key effective 差量写 upper |
| 公共 `/etc/hosts` | 由 Profile/rootfs-build 写入 | 合并 Node hosts override、写节点 hostname/self entry，并以 effective hosts + 共享 host public key 重算 `ssh_known_hosts` |
| repository | 删除/禁用公网源，只保留 Profile 选中的本地源 | Node repositories add/remove 只接受 InstallSource capability id；compiler 固定 effective repository revision/GPG policy，agent 使用临时本地 repo 配置，不接受 URL |
| hostname | 通用占位 | 写节点 hostname |
| 网络 | 保留 DHCP bootstrap 能力和 NM/Netplan | 写目标静态/DHCP 持久配置 |
| machine-id | 清理，不在共享 lower 留唯一身份 | 每次启动在 upper 生成 |
| SSH key/authorized_keys | Profile create/clone preparation 自动生成并固定 client/host keys，合并所有 Profile 公钥并生成域内 ssh_known_hosts | 追加 key/删除可删除的继承 key；mandatory Profile client key 不可由标准 remove 删除；显式后处理仍可改最终文件 |

boot readiness 时把 Profile 的 target-system 与 rootfs manifest 对照：自定义 locale/timezone/keyboard、用户或包不存在、
SSH enabled 但无 sshd、静态网络缺 renderer/tool 时拒绝启用 PXE，不等切根后失败。

### 4.5 配置落地与后处理框架

后处理与 install 保持同等配置力度：可以通过 typed target-system 投影、managed-file、package、archive 和
script 修改最终运行根。v0.2 固定落地顺序，以便同一 effective plan 可重放且最终结果可预览：

| 层 | owner / 执行者 | 适用内容 | digest | 边界 |
|---|---|---|---|---|
| `rootfs-build` | Profile / server builder | packages、users/UID/GID、password hash、hosts、sshd policy、Profile SSH client/host keys、authorized_keys/ssh_known_hosts、公共文件与服务 | `rootfs_input_digest` | 只构建 Profile 公用 lower，不读 Node override |
| `boot-project` | Node + BootSession / server effective compiler | 把 hostname/network/machine-id、完整 target-system 与 software/service/security Node effective 差量编译为 immutable AgentPlan | `desired_plan_digest`，交付时再入 `delivery_digest` | 只编译/签名，不操作 rootfs；BootConfig 只引用 plan digest/locator |
| `node-apply` | Node effective / `nodeforge-agent --pre-init` | 从服务端获取并验证 AgentPlan/payload，清除读 token；先做 exact software add/remove transaction，再以 TargetSystem finalizer 写 users/password/SSH/hosts/network/NTP/localization/security/machine-id 与 service enablement | `desired_plan_digest` + session snapshot | `switch_root` 后、`/sbin/init` 前执行；成功后 exec 真正 init，只用 session-pinned local-only 输入 |
| `first-boot` | effective bundle / node agent | managed-file、package、archive、script，力度与 install postprocess 一致 | Profile payload manifest 入 `rootfs_input_digest`；Node override payload digest 只入 desired/delivery，执行身份入 session | 默认执行 Profile bundle；`overrides.diskless.provision.bundle` 可按 Node 完整替换 first-boot，禁止其含 rootfs-build item |

`rootfs-build` 和 `first-boot` 是 provision bundle 的声明 phase；`boot-project` 与 `node-apply` 是 effective compiler
的内建落地 stage，不是新 bundle phase。后处理可以修改 passwd/shadow/group、sudoers、sshd、
authorized_keys、hosts 和其他运行根文件，因为 install 的同类 postprocess 也具备该力度。安全边界改为
禁止读取/泄漏 `/var/lib/nodeforge/credentials`、篡改 session identity、写只读 lower 或引入远程持续任务；
plan/preview 必须显示 action 类型、目标路径、输入 revision 和最终覆盖顺序。

Profile bundle 的 rootfs-build/first-boot payload 随公共 rootfs 构建。Node 设置
`overrides.diskless.provision.bundle` 时，引用 bundle 必须只含 first-boot item；服务端将其解析为不可变 package/
asset closure，agent pre-init 使用 session-bound `agent:read` 在 `switch_root` 后下载并完整校验到
`/var/lib/nodeforge/node-firstboot/<payload-digest>/`，随后清除 agent token。first-boot 只读取本地 payload；agent 先执行
pre-init node-apply 并 exec systemd，再由同一 binary 的 first-boot unit 执行该 Node bundle；未设置 override 时执行
rootfs 内的 Profile first-boot payload。该流程不产生
per-Node rootfs、variant、远程任务或真正 init 后的配置/artifact 下载。

## 5. M6/M7 对新契约的影响

### 5.1 M6

BIOS 支持增加的是 Node confirmed firmware property和 bootloader adapter，不是 Profile 的物理磁盘 owner。
M6 增加 Node direct `firmware.mode=uefi|bios`；schema v4 到 v5 的既有 Node migration 默认为 `uefi`，新认领 Node
必须由管理员确认。DHCP observed firmware 只用于 mismatch/readiness 检查，不自动改写 desired property。该字段不能放入
Profile 或 `overrides`。partition policy 仍使用 v0.1 的逻辑磁盘角色，由 effective compiler 结合 firmware 生成
ESP/biosboot 要求。v0.1 保留的 `node.http_accel` 继续只适用于 UEFI GRUB；BIOS PXELINUX capability 必须报告
`property.not_applicable`，不能接受后静默忽略，也不能为 BIOS 新增另一个同义传输开关。

`http_accel` 治理的是 GRUB 在 PXE 阶段用 HTTP 取 kernel/initrd 的传输路径（install 与 diskless 共用，仅 UEFI）；它不
治理 initrd 自身用 node-bound capability route 发起的 rootfs GET/HEAD/Range 下载--后者始终走受认证 HTTP 路由，与
`http_accel` 开关无关，也不因 BIOS 而新增同义传输开关。

### 5.2 M7 phase 与八步执行契约

phase 固定为 `install-post|rootfs-build|first-boot`（canonical 集合；schema v4 实现 `rootfs-build`/`first-boot`，
`install-post` 随 v0.3）。`first-boot` 为 diskless 切根后 agent 开机顺序执行的一次性后处理，无 `runtime` 周期 phase、
无远程控制。每个 action 显式声明允许 phase、输入 asset、幂等 key、timeout、retryability 和敏感输出规则；同一 step 的
`(boot session, bundle revision, desired plan digest, node, phase, idempotency key)` 唯一标识本次开机的一次执行。
新 PXE session 必须重新执行全部 first-boot steps，不得用服务端历史成功记录跨启动跳过。`plan` 无副作用，`apply` 需要
目标 revision，`retry` 只重跑明确 retryable 的失败 step。M7 不成为通用远程命令或配置管理平台。

旧详细设计名称只按下表迁移，schema v4+、CLI、API、状态和事件不得继续写旧拼法：

| 历史名称 | v0.2 canonical phase | 迁移语义 |
|---|---|---|
| `install_post` | `install-post` | 原位无损迁移 |
| `rootfs_build` | `rootfs-build` | 原位无损迁移 |
| `firstboot` | `first-boot` | 原位无损迁移 |
| `diskless_boot` | `first-boot` | 迁移后为 diskless 切根后 agent 开机顺序执行 |

每个 phase 的执行顺序固定为八步，跳过不适用步骤但不得重排：1）挂载/确认 target root；2）pin effective、bundle、
asset revision 并验证 action/phase/credential-session-lower 边界；3）物化已发布的本地 repository 和输入 asset；
4）原子写 managed file（文件更新）；
5）执行只引用 snapshot 中 effective software/capability 的 package action；6）校验并展开 archive；7）按声明顺序
执行受控 script；8）运行 TargetSystem finalizer 后原子发布 status/audit。任一步失败都不得发布 succeeded 状态。
顺序固定为 文件更新 -> package -> archive -> script。

managed-file、archive 和 script 可修改 passwd/shadow/group/sudoers、sshd、authorized_keys、
Netplan/NetworkManager、resolver、locale/timezone/keyboard、firewall 和 SELinux 配置/unit，与 install postprocess
保持同等力度。它们必须声明预期影响路径，plan/preview 按顺序显示最终覆盖关系。只有
`/var/lib/nodeforge/credentials`、session handoff/journal 和只读 lower 是不可触碰边界；finalizer 验证凭据未泄漏、
effective 操作顺序和 local-only 策略。

diskless agent 的节点身份由 cmdline node/session、BootConfig 与 token claim 三方相等后确定，initrd 写入
`/var/lib/nodeforge/boot.json`（mode 0600，非 secret 摘要）。agent 切根后先执行 session 固定的 Node node-apply，
再顺序执行 effective first-boot（默认 Profile bundle，Node override 时为预下载的 first-boot-only bundle）；状态/异常/审计经
event_url best-effort 回传服务端（带 node_id），回传失败不阻塞执行、仅本地留存日志/console/boot.json。
v0.2 diskless 不引入可续期 enrollment credential、reconciliation 或远程控制（reconciliation/远程控制为永久非目标，
见 §5.3、§7）；per-boot 短时 capability token 只服务固定 session。

v0.2 diskless 不引入 enrollment 机制：agent 身份来自已验证的 session handoff（见 §5.2 上文、§5.3），
状态/异常 best-effort 回传，回传失败本地兜底（日志/console/boot.json）。可续期 enrollment credential、远程控制和
reconciliation 为永久非目标（见 §7）；install 侧 agent（确定性 first-boot，无 reconciliation）延后 v0.4。v0.2 的 HTTP bearer 只在隔离
`local-only` 网络内提供认证，不提供链路机密性；跨不可信网络的 TLS/mTLS 与远程管理仍是非目标，部署必须以隔离
VLAN/ACL 防止旁路窃听。

### 5.3 运行期后处理与 agent

三个声明 phase 的执行者不同：`install-post` 由安装器（Kickstart `%post`/Autoinstall `late-commands`）在安装期执行，无
agent、属 install（v0.3）；`rootfs-build` 由服务端 rootfs builder 执行，无节点 agent（v0.2，见 §4.4/§5.4）；`first-boot`
由 node-bound agent 在 diskless 真正 init 启动后顺序执行（一次性，无 `runtime` 周期、无远程控制）。此外，effective compiler
生成的内部 `node-apply` 由同一 agent 的 pre-init 入口在真正 PID 1 前执行，它不是第四个用户可配置 phase。v0.2 的 agent **仅服务
diskless**（diskless 无安装器，`node-apply`/`first-boot` 是其运行根执行路径）；rootfs-build 不需 agent（builder 本地受信），`install-post`
随 v0.3（PXELINUX install）落地，install 侧 agent 延后到 v0.4（reconciliation 为永久非目标，见 §7）。本节 agent 设计
以 diskless 后处理为唯一 v0.2 目标。

**agent 身份与生命周期**。agent 无 enrollment：节点身份由 cmdline node/session、BootConfig 和 token claim
三方相等后固定为 session snapshot，initrd 写入 `/var/lib/nodeforge/boot.json` 与 `agent-handoff.json`（mode 0600，非 secret 摘要）。
`switch_root` 以 `nodeforge-agent --pre-init` 为入口；agent 校验身份，使用 `agent:read` 从服务端获取 expected digest 的
AgentPlan/Node payload，清除读 token，应用 immutable `node_apply_projection` 后 exec 真正 init。systemd 启动后同一 binary
的 first-boot unit 再读取 rootfs Profile payload 或 agent pre-init 预下载的 Node override payload，固定顺序
文件更新 -> package -> archive -> script，一次性。两种入口都不接受远程任务下发、不做 reconciliation、不做通用远程命令或配置
管理平台。状态/异常/审计经 event_url best-effort 回传（带 node_id），失败本地兜底，不阻塞执行。

**first-boot 执行与重试语义**。diskless overlay upper 为 tmpfs（per-boot 易失）、系统无状态，故 first-boot **每次开机
都执行**（“一次性”指每次开机执行一次、非 `runtime` 周期，非“跨重启只跑一次”）。幂等键包含 boot session，
只用本次启动 `/run` journal 使崩溃/当次 retry 的已成功 step no-op；服务端历史仅供审计，不能让新 session 跳步。
retryable 失败 step 按 step 声明 retry 策略在当次开机内重试，耗尽则 step 标 failed（节点仍启动、该 step 失败，
经 `node postprocess show` 查询）。重新触发完整 first-boot = 重启节点重新 PXE 引导；`node diskless retry` 清
boot-level quarantine 以允许重新 PXE，
不改 Profile、不远程重启。无独立 first-boot retry CLI（重启即重跑，确定性+幂等保证安全）。

**步骤契约**。每个 step 接收执行上下文 `node_id, profile, distro, distro_version, arch, phase, target_root, workspace,
payload_root, event_url`，统一返回 `{changed, status, summary, outputs, warnings}`；first-boot 的 `payload_root` 来自
rootfs 内 content-addressed 预置目录，不在切根后解析远程 repository。`plan` 预览（安装包/改文件/脚本）
无副作用，`apply` 需目标 revision，`retry` 只重跑明确 retryable 的失败 step。runner 在每 step 前后产生
`provision.step.started`/`succeeded`/`warned`/`failed`，fields 固定含 `source=runner`、`node_id`、`phase`、`step`、`run_id`、
action、稳定 reason；脚本 stdout/stderr 仅留最后 2048 bytes 转义摘要，token/未声明输出不得进服务日志或 Event。失败只留本地
失败信息（日志/console/boot.json），不因事件上报失败中断或回滚已完成切根/后处理；事件 fields 有界且脱敏，不含下载 URL
query、Authorization、完整 journal 或 debug shell 输出。

**reconciliation**（永久非目标）。全版本不实现 reconciliation/远程控制：agent 开机顺序执行确定性 node-apply/first-boot，无 drift 重跑、
无远程任务下发。reconciliation 与远程控制不再仅延后 v0.4，而是升级为永久非目标（见 §7）；install 侧 agent（确定性
first-boot）延后 v0.4，但同样无 reconciliation。

### 5.4 统一导入动作与执行 CLI（build/运行期共用）

v0.2 的数据导入统一为四类受约束 action；`rootfs-build`（服务端 builder）与 `first-boot`（节点 agent）共用同一 action、
ItemSpec 字段与 §5.2 八步执行契约，差异只在执行者、目标上下文与持久化（见下表）。不引入自由 `packages`/
`standard_packages` 数组，也不按扩展名把普通文件自动提升为 action。

| action | 用途 | 输入 asset | 关键 ItemSpec 字段 |
|---|---|---|---|
| `managed-file` | 导入单个文件（如 `/etc/hosts.d/nodeforge`、motd） | `managed_file` | `destination`、`content_asset`、`mode`、`owner`、`group` |
| `archive` | 导入目录树或自定义软件包（`tar.bz2`） | `archive` | `archive_asset` |
| `script` | 执行受审计自定义脚本 | `script` | `script_asset`、`interpreter`、`timeout_s` |
| `package` | 安装补充标准包/组/环境（RPM/DEB） | 引用 selection 或本地 repo | `selection`、`packages`、`group`、`environment`（至少一项，经本地 repo 解析校验） |

四类 action 均声明 `phase`、`idempotency_key`、`timeout_s`、`retryable` 与影响域；`item add/set` 用 `FIELD=VALUE` 精确字段，
parser 拒绝该 action 不适用的字段。`repository`/`standard_packages` 旧 action 按 §5.2 迁移表退出，不新增同义 action。

**archive 规则**（build/运行期通用）：读取 tar，若顶层存在 `./install.sh` 则解压到临时目录并以该目录为工作目录执行
`./install.sh`（退出码 0 且幂等，禁止隐式下载未声明内容）；否则直接把 payload 解压到 `/`。步骤作者始终以 `/` 为目标，
builder/agent 提供挂载或 chroot 上下文把写入落到对应 lower 或 overlay upper；manifest 只声明 SHA256（由 asset 提供），
不设 `script|extract` 策略、`target_root`、`install --root` 参数或 `NODEFORGE_TARGET_ROOT` 环境变量。

**provision-bundle item 编写**（复用 v0.1 §7.1 structured collection `item add/set/move`、`replace-items`、`--before/--after`、
`--unset`，canonical collection key 为 `steps`）。字段示例见 `V0_2_CLI.md` §3。`managed-file` asset 只保存不可变内容；
`destination/mode/owner/group` 属于引用 asset 的 step，不得复制到 asset metadata。`destination` 为 `/` 下绝对路径（rootfs-build 落 lower、first-boot
落 overlay upper）；`archive` 无 `destination`，按 archive 规则解压到 `/` 或在临时目录执行 `install.sh`；`script` 由
`script_asset` 提供受审计可执行内容；`package` 的 `packages`/`group`/`environment`/`selection` 至少一项，均经本地
repository 解析校验、幂等。

**build 期与运行期差异**（同一 action、同一字段、不同执行者）：

| 维度 | `rootfs-build`（build 期） | `first-boot`（运行期） |
|---|---|---|
| 执行者 | 服务端 rootfs builder，无节点 agent、无 enrollment | node-bound agent，无 enrollment（身份由 cmdline、BootConfig/session snapshot 与短时 agent/event token claim 共同证明） |
| 目标上下文 | builder 提供 chroot（按需 bind-mount `/dev`/`/proc`/`/sys` 与匹配内核，见 §4.4），步骤以 `/` 写入只读 lower | agent 在已切根系统写 overlay upper，`/` 为运行系统 |
| 持久化 | 烤入 rootfs digest，跨启动只读不变 | diskless 写临时 overlay（per-boot），install 写磁盘 |
| 脚本约束 | build chroot（按需 /dev/proc/sys + 匹配内核）内执行，须 build-safe、幂等；驱动/dkms 须声明影响域 | 运行系统执行，受 bounded action 与 finalizer 约束 |
| 触发 | 显式 `profile rootfs build [--new-ssh-keys] [--if-input-digest]`；readiness 只读 | 真正 init 启动后，agent unit 执行 effective fixed bundle payload |
| 失败语义 | 阻止 rootfs ready，不发 succeeded，不入节点 session | step failed 可 retry；不回写或倒退已完成 BootSession |

**日志、进度与结果回传**（统一 step I/O，按执行者分流）：统一 step 返回 `{changed, status, summary, outputs, warnings}`；
八步顺序固定（§5.2），任一步失败不得发布 succeeded。事件 `provision.step.started/succeeded/warned/failed`，fields 固定含
`source`（`builder` 或 `runner`）、`phase`、`step`、`run_id`、action、稳定 reason；运行期事件额外含 `node_id`，rootfs-build
事件额外含 `rootfs`。`rootfs-build`：事件 `source=builder`，记入 build manifest/audit（未上节点，不回传节点）；进度经
rootfs digest 预览与构建日志暴露，失败阻止 rootfs ready。`first-boot`：事件 `source=runner` 经 `event_url` 回传；脚本
stdout/stderr 仅留最后 2048 bytes 转义摘要；断网只保留本地失败信息，不中断已切根；`plan` 预览无副作用，`apply` 需目标
revision，`retry` 只重跑明确 retryable 的失败 step。脱敏：token、Authorization、URL query、未声明输出不得进服务日志或 Event；
敏感输出按 action 声明规则裁剪。

### 5.5 按版本 CLI 参考

> 完整 CLI 接口（命令树/flag/FIELD=VALUE/示例）见 `V0_2_CLI.md`；本节按版本给出概览。

全部版本复用 v0.1 资源-动作树（`nodeforge <resource> <action>`）、三组 collection 操作、Assets 子资源与
`--from-file/--input`、`-o/--output`、`-c/--config`、`--debug`。catalog 写仍经 daemon owner，不增加
可绕过事务的 catalog path 写入口。新命令必须先进入 typed
PropertySpec/CollectionSpec/ItemSpec 再给 handler；预留 enum/空 handler 不算实现。

**v0.2（diskless）**：`operation show/wait`、`profile list/create --kind diskless`、`profile set diskless.provision.bundle/overlay.*/failure.*`、
`profile effective`、`node add/set/effective`、`assets managed-file|archive|script import`、`assets provision-bundle create/list/item add/set/remove/move/replace-items`、
`assets nodeforge-initrd config/build`、`profile rootfs plan/build/status`、`node readiness --stage build|boot`、
`node boot preview`、`node diskless retry`、`node postprocess show`、
`node trace`、`runtime dhcp-leases|tftp-sessions`、`events list|follow|types`、`nodeforge status`、`preflight diskless-builder`。

**v0.3（PXELINUX/BIOS install）**：`node set firmware.mode=bios`（schema v5，仅 install）、
`profile set install.post_install.bundle`、`install-post` phase item、`node postprocess show --phase install-post --generation`。

**v0.4（延后增强项）**：Node direct network topology ItemSpec、builder placement + 临时 PXE rootfs 构建 operation、
大规模容量压测与 install 侧 agent generation 查询随其设计落地；
reconciliation/远程控制为永久非目标，无对应 CLI（见 §7）。v0.2/v0.3 不提供这些命令的 help/handler，预留 enum 不算实现。

## 6. 对当前 v0.2 脚手架的代码影响

| 当前代码 | 结论 | v0.2 变更 |
|---|---|---|
| `model.ProfileConfig`、`BootKind` | v3 Profile 和 BootKind 都只有 install；`ProfileMode` 已不存在，legacy diskless 只保留为迁移 blocker | schema v4 基于冻结 v3 新增 tagged kind（设计名 `ProfileKind` = 代码 `BootKind` `model.zig:329`，v0.2 扩 `install|diskless`）；不恢复旧 mode/nullable source |
| `AssetKind.kernel/nodeforge_initrd/rootfs`、`BootBundleConfig` | `kernel` 当前语义是 installer kernel；`BootBundleConfig.rootfs` 会造成 Profile -> plan -> rootfs -> bundle 构建环 | v4 新增 `runtime_kernel` kind；bundle 删除 rootfs ref，固定 source+runtime kernel+initrd revisions；DeliveryManifest 绑定派生输出 |
| `boot/target.zig:resolve` | 当前无 `resolveDiskless`，`resolve` 只调用 `resolveInstall`；文件中的 diskless 注释是过时说明 | 新增只消费 session DisklessEffectivePlan snapshot 的明确分支并补负向验证 |
| `http/server.zig:bootConfig`、`http/routes.zig` | BootKind 仅 install，handler 无 diskless payload 分支，route table 无 node-bound rootfs artifact 路由 | 增强类型 DTO、node-bound rootfs route、Range/ETag/auth |
| `provision/runner.zig` M4 install_post | repository/`standard_packages` owner 冲突，且没有 M7 phase/status/retry | v0.1 先迁为 managed-file bundle；M7 在同一 ItemSpec/resource 上扩展 tagged action、phase 和运行态 |
| `AssetKind`/`ProvisionAction`（仅 `managed_file` 等） | 缺 `archive`/`script` asset kind 与 `archive`/`script`/`package` action，无统一 build/runtime 执行差异 | 增 §5.4 四类 action 的 tagged ItemSpec、`archive`/`script` asset kind 与 import CLI |
| `main.zig` 通用 asset import | 可接受预留 kind，但无 rootfs/initrd/boot-bundle/diskless resource-action tree | 复用 command modules、spec help 和 OutputDocument，不回到直接 writer |
| `boot_session.Phase`/`node_status.Phase` 中混排的 install/diskless enum | 只有预留标签，`node_status.running` 无 kind，可能形成两个投影或错误拼接 | 建 `NodeCurrentState` tagged union + 唯一 reducer/映射；每 Node 单 active session，历史仅 trace；补冲突/换 kind E2E |

## 7. 明确非目标

- DHCPv6、IPv6 target network 或 IPv6 PXE；这是项目永久非目标。
- by-id、serial、WWN 或其他稳定磁盘 selector；这是项目永久非目标，磁盘配置继续使用 v0.1 的 `/dev/...` 路径契约。
- 数据库、远程多租户管理平面或通用配置管理平台。
- Kubernetes/Slurm/Ansible 类集群编排。
- 未经强类型约束和审计的任意远程命令执行。
- reconciliation/远程控制：服务端不检测已部署节点 drift 后远程主动触发 agent 重跑收敛，agent 永远是开机确定性顺序执行
  （diskless/install 通用）；drift 仅报告（v0.1 既有）不自动修复。这是项目永久非目标。
- v0.2 不提供持久化 overlay 或跨重启 rootfs partial：无盘 upper/work 重启即丢；`rootfs.part`
  仅在同一 BootSession/initrd 运行内 Range 续传。Profile SSH client/host keys 属于共享 rootfs 基线，不依赖持久
  overlay。完整语义见 `DISKLESS_FINAL.md` §4。
- v0.2 不支持 PXE 阶段纯静态、多 NIC、VLAN、bonding 或下载后切换地址/子网；该项延后到 v0.4，需显式 capability 扩展，
  不得由 initrd 猜测或静默接受。
- 在线/远程 mirror rootfs 模式或可切换的 `local-only` 开关；v0.1 删除 `connectivity.mode` 正因 `local-only` 是唯一行为，M5
  rootfs/initrd 恒 `local-only`，不存在 online 变体，也不新增 `local-only` PropertySpec。
- 可切换的 rootfs 形态（`ram_rootfs` 等全内存模式、`diskless.overlay.mode` 字段）作为 v0.5 单独项；v0.2 固定 `squashfs_overlay`，
  不提供 mode 字段（同上单值无选择意义逻辑）。
- NFS root（任何形态）、iPXE 菜单/脚本；临时 PXE rootfs 构建节点延后 v0.4。
- enrollment 机制（可续期的运行期节点认证 secret）全版本不引入；boot/first-boot 仍使用与 session 或 generation
  绑定、短时、最小权限且服务端只存 hash 的 capability token，不能升级为 management credential。
- 跨不可信网络 TLS/mTLS、远程管理。
- `profile remove`：只允许删除当前 catalog 中零 Node 引用的 Profile。DELETE mutation 必须携带当前 catalog
  `If-Match`，并在 daemon mutation mutex/model gate 内完成引用复查、模型校验、manifest-last 发布和 snapshot 切换；
  有引用返回稳定的 `profile.in_use`，禁止隐式解绑。历史 deployment/session snapshot 是已固定事实，不随当前
  Profile 删除重写。`node remove` 继续受活动 session gate 保护；需要保留的机器通过 `deploy=false` 停用。

## 8. 文档与实现规则

- v0.2 的 schema 只能扩展 v0.1 owner，不得复制字段到新的资源对象。
- 新的 CLI/API key 必须先进入 typed PropertySpec/CollectionSpec/ItemSpec。
- registry contract test 必须计算
  `diskless_shared_node_override_paths == (v0.1_install_node_override_paths - overrides.install.*) + v0.2_shared_additions`；
  当前 shared addition 为 `overrides.system.hosts`，并同时适用于 install/diskless。不得维护“diskless 初期只开放几个字段”的手工 allowlist。
- 对上述集合中的每个 path，测试必须同时证明 help/show/parser/API operation、v0.1 merge 来源 metadata、
  `desired_plan_digest` 变化、唯一 boot-project/node-apply consumer 和重启重放；任何一项缺失都视为不支持，不能仅凭 PropertySpec 宣称完成。
- 所有 persisted/effective/runtime 输出继续遵守 v0.1 JSON 分层。
- 新的 list/item mutation、help、show 和 API operation path 必须通过 v0.1 同一组 registry contract/golden tests。
- 每个里程碑必须同时具备代码、自动化、可复现系统验证和更新后的审计记录。
- 预留 enum、空 handler、设计命令和 resolver 分支均不算实现证据。

历史 M5-M7 详细设想仍可在
[`archive/M0_M7_LEGACY_DETAILED_DESIGN.md`](../archive/M0_M7_LEGACY_DETAILED_DESIGN.md) 对照阅读；与本文或 v0.1 契约冲突时，
必须先更新设计再实现，不能依赖旧章节中的隐式 fallback。

## 9. v0.2 完成标准

各版本按其里程碑具备代码、自动化、可复现系统验证和迁移证据后完成；某一里程碑不能借用另一个里程碑的设计或脚手架作为
完成证据。v0.2 只含 M5（diskless）与 M7 diskless 后处理（`rootfs-build`/`first-boot`）；M6 与 M7 `install-post` 属 v0.3、
install 侧 agent 属 v0.4（reconciliation/远程控制为永久非目标，见 §7），其完成标准一并记录以保持连续性，但不计入 v0.2 完成。

### 9.1 M5（v0.2）

- schema v4 plan/apply/rollback 将每个 v3 Profile 无损映射为 `kind.install`，旧 parser 不接受 nullable v4 半成品。
- diskless Profile、rootfs、nodeforge-initrd 和 boot-bundle 的 PropertySpec/CollectionSpec/ItemSpec、Assets CLI/API、
  exact-key show/help 和 transaction 全部通过 contract test。
- rootfs 由完整 `rootfs_input_digest` 可复现构建/缓存；Profile software/system/SSH 基线改变 digest，
  Node override 只改 `desired_plan_digest` 并经 boot-project/node-apply 在 upper 重放，不生成第二份 rootfs。
- node-bound boot-config、rootfs 与 AgentPlan/payload GET/HEAD/Range 通过跨 Node/session/path 越权、token 过期、
  If-Range、断点续传、错误 digest、redirect/latest/catalog 拒绝、agent token 清除、
  feature mismatch、BootConfig 响应中断/有界重放、无效 token 不归责 victim、有效 claim 越权、重复失败 quarantine 和
  daemon restart-resume 负向测试。restart-resume 只保证客户端已完整取得 raw token 后的阶段；capsule 交付前/中重启且
  客户端没有完整 token时必须 `recovery_incomplete`，不能重建 secret。
- AgentPlan fixture 证明 Node password hash/authorized_keys/hosts delta 可编译且只由 agent pre-init 写 upper，
  不含明文密码或 Profile SSH private key；boot.json、access log、Event、错误和 CLI 输出均不含明文、hash、private key 或 token；
  initrd 切根前清零 config/rootfs capability；agent 在预取完成后清零 agent capability。
- `local-only` rootfs 静态检查和隔离网抓包证明无公网 mirror/metalink/GeoIP/vendor NTP/update，全部 initrd URL 使用
  server IP；静态目标地址不等于 MAC reservation、MAC 不匹配和 renderer 缺失均在切根前失败。
- BootSession 覆盖 DHCP/TFTP/boot-config/initrd 全链路、失败/过期分支、重复/跳跃/回退/错绑拒绝及 quarantine gate，
  `node_status` 不丢失早期诊断状态。
- Node current state 是 `kind` tagged union；同一 Node 不可同时存在 install/diskless current projection 或两个
  active session。跨 kind 换绑仅在 `deploy=false` 且无 active/recoverable session 时允许，历史只进 trace。
- `squashfs_overlay`（v0.2 唯一 rootfs 形态）通过 UEFI x86_64/aarch64 QEMU smoke + VMware 虚拟机部署（compute_use）
  实机代理验证；至少一架构完成断网恢复、switch_root、running event 和 retry 闭环，覆盖真机 NIC/firmware/内存差异。
  大镜像内存预算场景按统一 `available_budget` 计 squashfs compressed size + 完整 upper limit + safety margin；readiness
  用 inventory 减 kernel/initrd，initrd 直接使用 `MemAvailable`，不得重复扣 kernel/initrd。无 inventory 时 readiness 明示
  unknown/checked required minimum，并由 initrd 实测硬闸。可切换 rootfs 形态
  （`ram_rootfs` 等）属 v0.5，不纳入 v0.2 验收。
- install Profile 的既有 PXE、全部 v0.1 storage/software/override 和 schema v3 migration 回归不退化。

### 9.2 M6（v0.3）

- schema v5 migration/rollback 将全部 v4 Node 显式物化 `firmware.mode=uefi`，活动 session 保护和 digest 预览通过。
- `firmware.mode` migration、claim/config、DHCP observed mismatch、readiness 和 digest 覆盖完整。
- BIOS x86 PXELINUX DHCP/TFTP/config、kernel/initrd/cmdline、install generation gate 和 diskless 适用性通过 QEMU
  smoke；`http_accel` 对 BIOS fail closed。
- 每个新增发行版版本逐项发布 adapter capability matrix，并通过 install answer、software index、默认值、
  unsupported/not-applicable 负向测试及至少一条可复现安装验证。

### 9.3 M7（rootfs-build/first-boot -> v0.2；install-post -> v0.3；install-agent -> v0.4；reconciliation 永久非目标）

- schema v4 migration/rollback 将 v3 managed-file bundle 无损映射到 canonical tagged action/phase；v0.3 schema v5
  仅增加 `install-post` 适用性，不另建 bundle owner；同一 Assets owner 扩展后的
  tagged ItemSpec 拒绝 action/phase 非法字段组合。
- bundle CRUD、ordered item mutation、atomic file replacement、plan/apply/status、phase-specific retry、If-Match 和幂等键通过并发及
  crash-recovery 测试；plan 无副作用。
- `install-post`、`rootfs-build`、`first-boot` 各 phase 只执行明确允许的 bounded action；script 来自受管 asset，
  日志/stdout/stderr 有界且脱敏，不存在 argv script/JSON 或任意未审计远程命令入口。
- package action 的 `packages/group/environment/selection` 只能在 snapshot 固定的 software capability 与本地 repository
  revision 中解析；不存在 `standard_packages` 旧字段、未固定 repository 或在线自由安装入口。
- schema/CLI/API/event 对 canonical phase 的旧名迁移唯一且八步顺序稳定；action 可修改与 install
  postprocess 相同的运行根路径，但 credential/session/lower 边界越权在 plan 阶段被拒绝；每个 phase
  的 finalizer 失败均阻止 succeeded 发布。
- first-boot 节点身份（`nodeforge.node_id` cmdline/boot.json + session-bound event token claim）与 best-effort 事件回传
  通过测试；回传失败本地兜底不阻塞后处理；无可续期 enrollment credential（reconciliation/远程控制为永久非目标，见 §7），验收确认 agent 无远程
  任务入口、无 drift 重跑，first-boot 一次性顺序执行。
- Kickstart、Autoinstall、rootfs build 和 diskless 对同一 bundle revision 的 plan/status/audit 语义一致。
- retry 不能抽象成远程通用动作：rootfs-build 由 operation 重建；diskless first-boot 仅同 session 内自动 step retry；
  install-post 仅同 generation/installer execution 内自动 step retry；耗尽后的重新执行分别需要新 build 或新 install generation。

## 10. 变更记录（设计收敛轨迹）

**第一轮（属性适用性 / 无盘构建 / 运行期 agent / local-only / 网络）**：补全无盘属性适用性矩阵；补 rootfs 构建工具链
（lorax/debootstrap、pin capability、local-only）、`rootfs-build` phase、构建期/启动期边界表；补 step I/O、两类包（标准经本地
repo / 非标准 tar.bz2+install.sh）、credential/session/lower 边界、事件回传；补 renderer 按 adapter 选择、MAC 绑定。

**第二轮（BootConfig / 后处理与 agent / 网络 / local-only）**：补 BootConfig 定义与 boot 写入流程、per-Node 投影、共享参数来源、
boot-time 职责划分；最终边界在后续复审收敛为 initrd 只交接 AgentPlan locator、agent pre-init 从服务端取得 plan 后应用 Node override。

**第三至十一轮（共享 rootfs / CLI / rootfs 查询 / BootConfig 澄清）**：收敛为每 Profile 单一共享
rootfs（OS 层为 builder 内部按 software digest 缓存、不暴露为独立 Resource）；补 rootfs 查询/构建 CLI；
补 BootConfig per-boot per-Node 短时 DTO 流程。

**第十二轮（状态机统一 / reconciliation 升级永久非目标 / management-credential 边界澄清 / 实现细节细化）**：单一 canonical `Phase`
枚举覆盖两条流、所有者分离（BootSession 传输态 + deployment 投影）；reconciliation/远程控制升级永久非目标；management-credential
边界澄清（传输 token vs daemon 管理 API 凭据隔离，与已移除 enrollment 无关）；新增 `V0_2_IMPL_DETAILS.md`（状态机/协议栈/effective compiler）。

**第十三轮（实现细节优先级 4-8 / node list 状态 schema 草案 / enrollment 残留清理）**：`V0_2_IMPL_DETAILS.md` 补 rootfs builder / schema
迁移 / event 脱敏 / 当时的 GC 草案 / bundle 八步；GC 草案已在第二十轮从 v0.2 删除；`node list` 统一状态 schema。

**第十四轮（diskless 核心闭环对齐 1↔2↔3）**：3->2->1->3 控制流闭环、协议事件->状态迁移->校验源映射、双检点（readiness+validator）、
pin 完整性不变式、反馈闭环；§2.1 DHCP DISCOVER 补 rootfs ready 闸。

**第十五轮（闭环验收矩阵 + CLI 工具流完善审计）**：`V0_2_IMPL_DETAILS.md` §10 验收矩阵（fail-closed 断言）；补 `diskless.provision.bundle`
字段、first-boot 每次开机执行语义。

**第十六轮（旧 CLI 草案）**：当时新增 8 阶段命令树和 `node postinstall show`；该命名与隐式 build 流程已由
第十八/十九轮的 11 阶段 `rootfs plan/build/status`、`postprocess show` 与两级 readiness 取代。

**第十七轮（review：`runtime` phase 残留清理 + 命名澄清）**：canonical phase = `install-post|rootfs-build|first-boot`（无 `runtime`），清理 11
处把 `runtime` 当 phase 的残留（版本表/§5.4/CLI 示例/§9/`DISKLESS_FINAL`），执行时序“runtime”统一为“运行期”；§10 历史按惯例保留。补
`ProfileKind`=`BootKind`、BootConfig `schema_version` v2 命名空间澄清。全部改动未触碰代码、未改变 v0.1 冻结 owner 或 v0.2 进入条件。

**第十八轮（完整 diskless 流程与构建环修复）**：新增 `V0_2_DISKLESS_WORKFLOW.md`；拆分 desired plan、
rootfs input、delivery digest；BootBundle 去除 rootfs ref，新增 runtime-kernel；readiness 拆 build/boot 两级；
明确 dnf --installroot/debootstrap、first-boot payload 预置、原子 rootfs 发布和从零 CLI 流程。

**第十九轮（状态互斥与 handoff/security）**：Node current state 收敛为 install|diskless tagged union、单 active
session 和唯一 `STATE`；first-boot 仅作 postprocess 摘要；补 pre-switch `/run` move-mount、delivery snapshot、
per-session credential capsule，禁止 token 进入 kernel cmdline。

**第二十轮（移除 v0.2 rootfs GC / readiness 与 CLI 提示）**：已发布 rootfs 改为只增不删、容量告警和新
build fail-closed；删除 GC CLI/引用计数/mark-sweep。将必要的在途一致性概念改名为 delivery snapshot；补
build/boot readiness 定义及跨 kind 换绑的 blockers/next commands。

核心契约对齐结论：v0.2 与 v0.1 在所有权、override 命名空间、`/dev/...` 磁盘契约、IPv4-only、`software.*` 双集合、
`kernel_args.add/remove`、`ProfileKind=install|diskless`、schema 版本号（v3/v4/v5/v6/v7）上无遗留冲突。除 `local-only` 系
v0.1 删除字段后的孤立遗留（已固化为不变式）外，v0.2 未发现因 v0.1 变动而失效或需废弃的条款。全部改动未改变 v0.1 冻结 owner 或
v0.2 进入条件，且未触碰任何代码。

**第二十一轮（CLI 流程查漏补缺 / 跨版本命名统一 / digest 流转）**：`V0_2_CLI.md` 补全 exit code 1、`--wait`/operation id/
daemon 依赖约定；补 `profile list`、`provision-bundle list/item remove`、per-action 字段矩阵、`preflight` human 输出、
`rootfs plan` JSON digest 字段、`boot preview`/`node status`/`runtime`/`status --component` 输出格式、`postprocess` 默认 session
与 `--include-output` 语义；新增 §13 digest 流转表与从零启用流程示例；统一 `preflight diskless-builder` 命令形式
（`V0_2_DISKLESS_WORKFLOW.md` 同步）；补 `profile create` 默认 `--kind install`、`node effective` vs `node show` 区分、
`profile/node remove` 为 v0.2 非目标（§7）。`V0_3/V0_4` 的 `postinstall` 统一为 `postprocess`。全部改动未触碰代码、未改变 v0.1 冻结
owner 或 v0.2 进入条件。

**第二十二轮（跨版本契约复审）**：修正 digest 漂移分类，明确 identity/network/secret/overlay 只改变 desired plan、
不分裂 rootfs cache；补通用 opaque operation show/wait、stdout/stderr 与 exit code 边界，删除 `preflight --scope` 双语法；
修复 managed-file 字段矩阵与 BootConfig config digest 自引用、session supersede CAS。v0.3 将 BIOS 范围限定为 install，
install-post 以 install generation 标识并只在 installer 内自动 retry。v0.4 网络改为 ItemSpec topology +
BootConfig v3 bootstrap transport + AgentPlan v2 target topology，
节点构建收敛为临时 PXE rootfs 构建 operation，install first-boot 补磁盘 handoff/journal，容量验收补 workload/SLO 证据。
v0.5 固定复用同一 squashfs 传输制品，BootConfig 升 v4，mode 只改变 desired/delivery digest、不改变 rootfs input digest。

**第二十三轮（实现契约与认证复审）**：恢复 v0.1 冻结的 Assets import owner/参数顺序与 provision-bundle `steps`
collection；Profile boot effective 只输出可证明 requirements，resolved projection 归 Node，`postprocess show` 改为
active-first。v0.3 补 generation-bound callback credential。v0.4 topology 增 `routes` 并冻结无损迁移，全部新 delivery
统一使用 BootConfig v3 + AgentPlan v2；临时构建节点补 BuilderBootAttempt、boot-slot 互斥、scoped upload claim 和 digest 边界，install
first-boot 补一次性 bootstrap token 交换。v0.5 冻结 ram_rootfs 双预算公式、feature 适用性与 unsquashfs metadata 保真。

**第二十四轮（可执行性复核）**：v0.3 明确 install callback raw token 通过 per-generation credential capsule 以 0400
文件交付，服务端只持 hash 且 restart 后不产生并行有效 token。v0.4 要求 effective compiler 在选择物理 builder Node
前唯一导出 capability class/ABI 并固定 input digest。v0.5 将内存校验改为规范化 available budget：运行态限制展开根，
峰值同时计入 compressed/uncompressed 副本，避免对 initrd `MemAvailable` 重复扣 kernel/initrd，并冻结 checked
`required_min_memory_bytes` 公式。

**第二十五轮（协议恢复与迁移复核）**：DHCP 新 XID 改为 correlation-window transaction alias，不再自动误杀同次 PXE；
BootConfig token 改为 single-purpose bounded replay，以 `diskless.initrd_started` config digest 确认；冻结 hash-only raw
token 在 capsule 交付前/中的 restart 恢复边界和鉴权错误归责。统一 v0.2-v0.5 transaction rollback 与 schema downgrade
representability 契约；v0.2 squashfs 内存预算与 v0.5 共用 available-budget 口径。

**第二十六轮（v0.2-v0.5 再复审）**：修正 workflow 遗留的旧 asset/item CLI；diskless Node software override
保留与 install 相同的 effective merge，切根后由 agent `node-apply` 重放，不进入公共 rootfs；diskless Profile password hash 改为按
credential revision 固定，避免 per-session salt 破坏可复现 rootfs；mandatory Profile client key 与 effective-hosts
known_hosts 重算保证标准路径的域内互信。统一 rootfs cache key、BootConfig 挂载/投影顺序和 agent session/token 身份；
v0.5 mode 固定为 Profile-only，schema v7 下两种取值均显式表达。

**第二十七轮（initrd / Node override 边界复审）**：删除 initrd 内静态配置 projector 的设计残留。nodeforged 只编译
immutable `node_apply_projection`；initrd 只 transport/verify/mount/handoff，并以 rootfs 内
`nodeforge-agent --pre-init` 为 `switch_root` 入口。agent 使用最终 rootfs 的 TargetSystem/package/renderer 能力应用全部
Node override，成功后在同一 PID `exec /sbin/init`；systemd 启动后的同一 binary 只执行 effective first-boot。
`required_features` 按 initrd/agent consumer 分域，pre-init 失败属于 boot failure，first-boot 失败才属于 degraded postprocess。

**第二十八轮（agent 拉取模型复审）**：进一步将 initrd handoff 缩减为最小 BootConfig + AgentPlan locator。
`nodeforge-agent --pre-init` 定义为单次启动执行框架：继承 bootstrap 网络，从服务端拉取 session-pinned AgentPlan 和全部
Node payload，校验 digest/feature 后清零 `agent:read` token，再按固定 stage 应用 Node override。initrd 不下载 AgentPlan/
Node payload；first-boot 不再联网。该模型不是 enrollment、轮询或远程命令，节点侧也不重新 merge Profile/Node。

**第二十九轮（BootloaderContentConflict 修复 / diskless CLI 流程补全 / initrd 依赖清理）**：

> **设计原则**：v0.2 diskless 全流程必须通过 CLI 完成，操作员不应手动编辑 catalog JSON 文件。
> 手动编辑 catalog 只在故障恢复或紧急诊断时作为最后手段。正常操作流程中，所有 catalog 实体
> （assets、boot-bundles、profiles、nodes 等）的创建和修改都通过 `nodeforge` CLI 命令完成，
> CLI 通过 management API 调用 daemon，由 daemon 执行原子事务写入 catalog store。

1. **Bootloader 内容寻址路径**：不同发行版（Rocky vs Ubuntu）的 UEFI GRUB 二进制内容不同，固定路径
   `efi/grubaa64.efi` 导致第二个 ISO 导入时 `BootloaderContentConflict`。改为内容寻址路径
   `efi/<sha256[:16]>-grubaa64.efi`：同内容复用（零浪费）、不同内容共存（无冲突）。DHCP option 67
   在 per-node 配置中引用正确的 bootloader 路径。这消除了 M4.9 的 `copyFileIfMissing` 逻辑和
   `BootloaderContentConflict` 错误，使不同发行版的 ISO 可以在同一 NodeForge 实例中无缝共存。

2. **diskless CLI 完整流程**：v0.2 diskless 从初始化到节点启动的完整流程全部通过 CLI 实现。
   补充 `nodeforge assets boot-bundle create` 命令和 `POST /api/v1/management/boot-bundles` API
   作为流程中最后缺失的环节。完整流程如下：
   ```
   # 1. 初始化 NodeForge 实例
   nodeforge setup --install-root /opt/nodeforge --server-ip <ip> --subnet <cidr> ...

   # 2. 导入安装介质（自动提取 bootloader/kernel/initrd/repository）
   nodeforge assets import <iso-file>

   # 3. 注册 diskless 专用资产（kernel 和 nodeforge-initrd 从 ISO 或单独构建）
   nodeforge assets register --type kernel --name <k> --path <p> --distro <d> --version <v> --arch <a> --kernel-release <r>
   nodeforge assets register --type nodeforge_initrd --name <i> --path <p>

   # 4. 创建 boot bundle（仅绑定 kernel/initrd，派生 rootfs 不进入 bundle）
   nodeforge assets boot-bundle create <name> --kernel <k> --initrd <i> \
     --distro <d> --version <v> --arch <a> --kernel-release <r>

   # 5. 创建 diskless profile（引用 boot bundle）
   nodeforge profile create <name> <install-source> --kind diskless --boot-bundle <name>

   # 6. 构建 Profile 派生 rootfs
   nodeforge profile rootfs build <diskless-profile>

   # 7. 注册并启用节点
   nodeforge node add <id> mac=<mac> arch=<a> profile=<name>
   nodeforge node set <id> deploy=true

   # 节点网络启动后自动执行：
   #   DHCP → TFTP bootloader → kernel + nodeforge-initrd →
   #   HTTP BootConfig → HTTP rootfs download → squashfs mount → overlay →
   #   switch_root → nodeforge-agent --pre-init → /sbin/init
   ```
   上述每一步都通过 CLI → management API → daemon → catalog store 原子事务完成。
   操作员不需要在任何步骤中手动编辑 `catalog/boot_bundles.json` 或其他 catalog JSON 文件。

3. **nodeforge-initrd 依赖清理**：`build.zig` 中 initrd 和 agent 模块添加 `single_threaded = true`，
   消除 Zig stdlib 引入的 libpthread 依赖。Zig stdlib 在 `link_libc = true` 时默认引用 pthread 符号
   （如 `pthread_create`/`pthread_mutex_init`）。glibc >= 2.34 将 pthread 合并入 libc，但交叉编译
   sysroot 可能使用 glibc < 2.34，导致链接产物包含 `NEEDED libpthread.so.0`。最小 initrd 环境中
   不包含该库，二进制无法加载。`single_threaded = true` 阻止 stdlib 引入任何 pthread 符号。
   同时添加 `strip = true`（ReleaseSafe/ReleaseFast 模式）减小二进制体积。

4. **initrd 挂载修复**：在 `nodeforge-initrd` main() 开头：
   - 显式挂载 `/run` 为 tmpfs（rootfs 下载的 .part/.chunk 文件写入此处，initramfs 根可能只读）
   - 加载 `squashfs`/`loop`/`overlay` 内核模块（Rocky 内核中这些是模块而非内置，使用 `runIgnore`
     容忍模块已内置时的非零返回）
   - 已有全局 IPv4 时直接复用；否则优先使用 vendor initrd 的 BusyBox `udhcpc`，未配置出地址或不存在时
     回退到构建器注入的 `dhclient -v -1`；两条路径均有界退出
   - daemon 内置 DHCP 是 UDP/67 server，不能复用为 initrd 的 UDP/68 client；自定义 `/init` 也不会执行
     vendor dracut/NetworkManager 的完整网络状态机
   - 使用 shell 参数展开 `${i##*/}` 替代 `basename` 命令依赖
   - 显式设置 `PATH=/usr/bin:/usr/sbin:/bin:/sbin`（内核启动 PID 1 时不携带环境变量）
   - `switch_root` 使用 `/usr/sbin/nodeforge-agent`（rootfs 中的实际路径）
