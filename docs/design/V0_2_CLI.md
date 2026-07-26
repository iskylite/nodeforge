# NodeForge v0.2 CLI 接口

状态：v0.2 接口分册，设计收敛、实现未开始。总纲以 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) 为准；本文是 CLI
命令树、flag、CAS、输出和 exit code 的唯一事实源。推荐操作顺序见
[`V0_2_DISKLESS_WORKFLOW.md`](V0_2_DISKLESS_WORKFLOW.md)。命令必须复用 v0.1
资源-动作树、typed PropertySpec/CollectionSpec/ItemSpec、统一 OutputDocument 和 optimistic concurrency；
预留 enum、help 或空 handler 不算实现。

本文不规定内部模块如何实现命令；流程分册可以摘录命令，但不能改变这里的接口契约。

## 0. 共用约定

- `show key == --help-full key == parser key == API operation path`。
- 结构化输入使用 `FIELD=VALUE` 或 `--from-file`，不要求 shell 内嵌 JSON。
- 全局 flag：`-c/--config <path>`、`-o/--output human|json|jsonl`、`--debug`；catalog 路径从 config
  解析，不另建会绕过 daemon owner 的写入口。
- 服务端 mutation 始终以原子 current snapshot 执行。CLI 延续 v0.1 行为：普通调用不要求用户手工复制 revision/digest；
  服务端或 CLI 自动取得当前值并在同一操作中校验。只有自动化/read-modify-write 需要“观察后若发生任何漂移就失败”时，
  才显式传 `--if-revision`、`--if-input-digest`、`--if-plan-digest` 或 `--if-failure-revision`。显式 guard 冲突后
  禁止 CLI 静默重读重试。
- artifact stdout 只对白名单 export 命令开放；日志、命令回显、JSON 和 error 不得包含 token/password hash。
- 所有异步动作返回不透明、不可猜且至少 128 bit 熵的 operation id；调用方不得解析其格式。`--wait` 只等待
  同一 operation 到达终态，不在客户端轮询后重复提交。`--wait --timeout <seconds>` 可选，超时返回 exit 6 且不取消
  服务端 operation。不带 `--wait` 时立即返回 operation id 与 canonical operation URL。
- `--wait` 的 human 进度写 stderr，stdout 只写最终结果；`json` 只在终态输出一个 OutputDocument，进度写 stderr；
  `jsonl` 可把进度与终态各写一行 stdout。非 TTY 不输出 spinner/cursor control。任何模式都不得用定时输出改变
  operation 状态，服务端 operation event/revision 才是进度真相。
- 不带 `--wait` 的 exit 0 只表示 operation 已成功受理，不表示构建完成；带 `--wait` 后 exit 0 才表示 operation
  已到 succeeded。等待超时返回 exit 6，但 operation 继续运行，可用返回的 id 执行 `operation show|wait`。
- 所有异步动作统一用 `nodeforge operation show|wait <id>` 查询；资源专用 `status --operation <id>` 只提供
  带资源上下文的投影，不能成为 import/initrd/rootfs 等 operation 的唯一查询入口。
- daemon 依赖：`events list/types/follow`、`config validate/export`、`catalog export` 为纯本地文件操作，
  不要求 `nodeforged` 在线；其余管理命令（`node/profile/assets` mutation、`rootfs build`、`readiness`、
  `status --component`、`runtime`）经 HTTP 管理 API 调用 daemon，要求 daemon 在线且管理 API 可达。
- exit code：0 成功；1 本地执行错误（文件 I/O、序列化、损坏的本地状态）；
  2 输入/不适用；3 revision/digest 冲突；4 not-ready/quarantined；5 operation failed；
  6 daemon 连接失败、服务不可用或等待超时。JSON error 同时返回稳定 `error.code`；exit code 只表达大类，
  自动化必须结合 `error.code` 判断具体原因。

```text
nodeforge operation show <id>
nodeforge operation wait <id> [--timeout <seconds>]
```

operation JSON 至少含 `id/kind/resource/state/created_at/updated_at/result/error/revision`；`state` 固定为
`queued|running|succeeded|failed|cancelled`。v0.2 不提供通用 cancel：客户端超时、断开或重复 wait 都不取消工作。

容易混淆的共用 flag 归为以下六类；同类必须保持完全相同语义，不得为单个命令重新解释：

| 类别 | flag | 默认行为 | 何时需要显式传入 |
|---|---|---|---|
| 输出/过滤 | `--output`、`--kind`、`--state`、`--section`、`--stage` | 输出完整默认视图 | 只想过滤或选择视图时 |
| 异步等待 | `--wait [--timeout N]` | 提交一次并立即返回 operation id | 交互式命令希望在当前终端等待同一 operation 完成时；`--timeout` 仅能与 `--wait` 同用 |
| 防漂移 guard | `--if-revision`、`--if-input-digest`、`--if-plan-digest`、`--if-failure-revision` | 原子使用执行时最新 snapshot | 自动化必须保证输入仍等于先前观察值时；guard 不选择历史版本 |
| 历史选择 | `--from-revision` | 使用 source 当前 revision | clone 明确要复制 source 的某个历史 revision 时；它不是并发 guard |
| 组合/新身份 | `--build`、`--new-ssh-keys` | 只完成主命令；复用已有 Profile SSH keys | clone 后立即构建，或显式生成新的 Profile client keypair + sshd host keys 时 |
| 验证模式 | `--deep`、`--verify-reproducibility` | 执行普通校验/构建 | 需要更深制品校验，或用相同输入重建并比较输出时；二者都不表示绕过错误 |

正常的人机流程示例不展示 `--if-*`；自动化示例才展示。这样保留精确 CAS 能力，但不把实现细节变成日常必填参数。

## 1. 阶段 0：服务与 builder 预检

```text
nodeforge preflight diskless-builder
nodeforge status --component dhcp,tftp,http,builder
nodeforge config validate
nodeforge catalog validate
```

`preflight diskless-builder` 是只读检查，至少输出 bind interface/IP、端口、asset/repository/staging 路径、
本地磁盘空间、`mksquashfs`、dnf/debootstrap/dracut capability、可构建 arch/kernel release 和 local-only
网络策略。`--output json` 为每项返回 `status/reason/remediation`，任一 required 项失败 exit 4。

human 输出为分组对齐表：

```text
CHECK                          STATUS    REASON                         REMEDIATION
bind_interface                 ok        192.168.50.1@eth0              -
builder.dnf                    ok        dnf 4.15.2                     -
builder.mksquashfs             failed   not on PATH                    install squashfs-tools
builder.debootstrap            ok        debootstrap 1.0.126            -
storage.staging_bytes          ok        48 GiB available, 12 GiB used  -
cross_arch_build               ok       binfmt/qemu-user registered     -
local_only_network             ok       no public mirror/metalink      -
```

`preflight diskless-builder` 是唯一 canonical 形式；help、parser 与 API operation path 只登记该 key，不同时维护
`--scope` 别名。通用服务状态使用 `nodeforge status --component dhcp,tftp,http`，不再定义含义重叠的裸 `preflight`。

## 1.5. diskless 全流程 CLI 命令链

以下是从空 catalog 到 diskless PXE boot 的端到端 CLI 命令链。每个步骤都应通过 CLI 完成，
不依赖手动 shell 命令（dracut/dnf/mksquashfs 等）。

```text
# 1. 初始化服务（生成 schema v4 config + catalog + systemd unit）
nodeforge setup --install-root /opt/nodeforge --non-interactive --yes \
  --bind-interface <iface> --server-ip <ip> --http-port 18080 \
  --subnet <cidr> --pool-start <ip> --pool-end <ip>
nodeforge setup --install-root /opt/nodeforge --generate-systemd --install --yes
systemctl enable --now nodeforged

# 2. 导入 ISO（自动注册 install source + default install profile + bootloader）
nodeforge assets import <iso-path>

# 3. 注册 diskless 资产
#    a) kernel — 已由 ISO 导入自动注册（<source>-kernel, kind=kernel），可直接用于 boot bundle
#    b) nodeforge initrd：由受支持的同步 builder 构建并原子注册
nodeforge assets initrd build <name> \
  --from-install-source <source> --kernel-release <r>
# 无可用 ISO/install source 时才使用通用 fallback：
nodeforge assets initrd build <name> \
  --distro <d> --version <v> --arch <a> --kernel-release <r>
#    已有外部制品仍可通过受管路径 register
nodeforge assets register --type nodeforge_initrd --name <i> --path <p> \
  --distro <d> --version <v> --arch <a> --kernel-release <r>
# 4. 创建 boot bundle + diskless profile（bundle 不含派生 rootfs，避免创建环）
nodeforge assets boot-bundle create <name> \
  --kernel <k> --initrd <i> \
  --distro <d> --version <v> --arch <a> --kernel-release <r>
nodeforge profile create <name> <install-source> --kind diskless --boot-bundle <bundle>

# 5. 构建 Profile 派生 rootfs；外部构建时改用 register
nodeforge profile rootfs build <diskless-profile> [--wait]
nodeforge profile rootfs register <diskless-profile> --path <squashfs-path>

# 6. 添加节点（保持 deploy=false）
nodeforge node add <id> mac=<mac> arch=<a> profile=<diskless-profile>
nodeforge node set <id> deploy=false

# 7. readiness 后启用部署；真实 session/capsule 在 PXE 请求时原子创建
nodeforge node readiness <id> --stage boot
nodeforge node set <id> deploy=true
```

**已实现**（见 V0_2_DESIGN.md 实现修订记录）：
- R5: `assets initrd build` 已接线为同步 CLI；异步 durable operation 是 v0.2.2 增强
- R4: `profile rootfs build` capability 已在 `setup.zig` 中修复
- R6: ISO 导入自动注册 kernel（`<source>-kernel`），无需手动 `assets register`
- R1: `catalog schema-v4` CLI 命令已移除，setup 始终生成最新 schema 版本

## 2. 阶段 1：导入本地 OS 源

```text
nodeforge assets import <iso> [--name <source>] [--wait]
nodeforge assets install-source list
nodeforge assets install-source show <source>
nodeforge assets install-source software list <source> [--kind package|group|environment|task]
nodeforge assets repository list
nodeforge assets repository validate <repository>
nodeforge assets repository software list <repository> [--kind package|group|environment|task]

nodeforge assets runtime-kernel prepare --source <install-source> [--release <release>] [--wait]
nodeforge assets runtime-kernel list
nodeforge assets runtime-kernel show <kernel-asset>
nodeforge assets runtime-kernel validate <kernel-asset>
```

ISO import 成功必须原子发布 install source、installer kernel、media tree、本地 repositories 和 software index。
diskless `runtime-kernel prepare` 从固定 revision 的本地 kernel package 提取可启动 kernel，并记录完全匹配的 modules/package
closure、release 与 arch；不能默认把安装器 kernel 当作运行 kernel。重复 import 相同内容返回 existing resource；同名
不同 digest 返回 conflict，不静默覆盖。

## 3. 阶段 2：导入定制资产与 bundle

```text
nodeforge assets managed-file import <asset> --from-file <path> [--media-type <type>]
nodeforge assets archive import <asset> --from-file <path> [--media-type <type>]
nodeforge assets script import <asset> --from-file <path> [--media-type <type>]

nodeforge assets provision-bundle create <bundle>
nodeforge assets provision-bundle list
nodeforge assets provision-bundle show <bundle>
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=rootfs-build action=managed-file content_asset=<asset> destination=/etc/motd mode=0644 owner=root group=root \
  idempotency_key=<key> timeout_s=30 retryable=false
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=rootfs-build action=package packages=tmux,nmap idempotency_key=<key> timeout_s=600 retryable=true
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=first-boot action=archive archive_asset=<asset> idempotency_key=<key> timeout_s=300 retryable=true
nodeforge assets provision-bundle item add <bundle> steps \
  id=<id> phase=first-boot action=script script_asset=<asset> interpreter=/bin/bash idempotency_key=<key> timeout_s=120 retryable=false
nodeforge assets provision-bundle item set <bundle> steps <id> FIELD=VALUE...
nodeforge assets provision-bundle item remove <bundle> steps <id>
nodeforge assets provision-bundle item move <bundle> steps <id> --before|--after <ref>
nodeforge assets provision-bundle replace-items <bundle> steps --from-file <file> [--input yaml|json]
nodeforge assets provision-bundle item list <bundle> steps [--phase rootfs-build|first-boot]
nodeforge assets provision-bundle plan <bundle> --phase rootfs-build|first-boot
```

asset import flag 约束：

| 命令 | 必填 flag | 可选 flag | 说明 |
|---|---|---|---|
| `managed-file import` | `<asset>`、`--from-file` | `--media-type` | 只导入不可变文件内容；不保存 destination/mode/owner/group |
| `archive import` | `<asset>`、`--from-file` | `--media-type` | 导入 tar 归档；destination 由 archive action 规则在执行期决定 |
| `script import` | `<asset>`、`--from-file` | `--media-type` | 导入受审计脚本；interpreter 在 item add 时指定 |

三类 import 延续 v0.1 `assets <kind> import <name> --from-file <path>` 契约。asset 是可跨 bundle 复用的不可变内容；
`destination/mode/owner/group/interpreter/phase` 全部属于引用它的 `steps` ItemSpec，不能复制到 asset metadata。
`steps` 是 provision-bundle 唯一 canonical structured collection key；`phase` 是每个 step 的必填 tagged 字段，
不是另一套 collection 或修改 owner 的命令 flag。

per-action 必填字段矩阵（`item add` 拒绝不适用的字段）：

| action | 必填字段 | 可选字段 | 禁止字段 |
|---|---|---|---|
| `managed-file` | `destination`、`content_asset` | `mode`、`owner`、`group` | `packages`、`environment`、`selection`、`archive_asset`、`script_asset`、`interpreter` |
| `package` | `packages`/`group`/`environment`/`selection` 至少一项 | 其余 selection 维度 | `destination`、`content_asset`、`archive_asset`、`script_asset` |
| `archive` | `archive_asset` | — | `destination`、`content_asset`、`packages`、`script_asset` |
| `script` | `script_asset`、`interpreter` | — | `destination`、`content_asset`、`packages`、`archive_asset` |

- v0.2 parser 只接受 `rootfs-build|first-boot`；`install-post` 到 v0.3 才可用，不应提前出现在 v0.2 help。
- action 固定 `managed-file|package|archive|script`。每项必须有稳定 `id` 与 `idempotency_key`。
- plan 必须显示执行顺序、输入 digest、目标路径、package resolution 和执行环境，无副作用。
- archive 顶层仅允许单一 `install.sh` 特例；拒绝绝对路径、`..`、device、FIFO 和越界 symlink。
  first-boot 与 install postprocess 一样可修改用户、SSH、hosts 和系统文件，但不得读取/复制
  `/run/nodeforge/credentials`、修改只读 lower 或篡改 session handoff。script 只能来自已导入 asset，
  不能接收 argv 内联脚本。

## 4. 阶段 3：构建 initrd 与 BootBundle

```text
nodeforge assets nodeforge-initrd config show
nodeforge assets nodeforge-initrd config set KEY=VALUE...
nodeforge assets nodeforge-initrd modules-values add|remove|replace|clear VALUE...
nodeforge assets nodeforge-initrd firmware-values add|remove|replace|clear VALUE...
nodeforge assets nodeforge-initrd build --source <install-source> --kernel <kernel-asset> [--wait]
nodeforge assets nodeforge-initrd list
nodeforge assets nodeforge-initrd show <asset>
nodeforge assets nodeforge-initrd validate <asset> [--deep]

nodeforge assets boot-bundle create <bundle> \
  install_source=<source> kernel=<kernel-asset> initrd=<nodeforge-initrd-asset>
nodeforge assets boot-bundle set <bundle> FIELD=VALUE...
nodeforge assets boot-bundle list
nodeforge assets boot-bundle show <bundle>
nodeforge assets boot-bundle validate <bundle>
```

BootBundle 只固定 source + prepared runtime kernel + NodeForge initrd revisions，不含 rootfs。`set` 产生新 resource revision；
active session 的旧 snapshot 不得被原位破坏。validate 联合检查 arch、kernel release、modules ABI、NIC firmware 和
required features，但不要求 rootfs 已构建。

## 5. 阶段 4：创建 diskless Profile

```text
nodeforge profile list [--kind install|diskless]
nodeforge profile create <profile> --kind diskless --source <install-source> \
  diskless.boot_bundle=<boot-bundle> [diskless.provision.bundle=<bundle>]
nodeforge profile clone <source-profile> <new-profile> [--from-revision <revision>] \
  [--set KEY=VALUE]... [--new-ssh-keys] [--build] [--wait]
# 大量节点共用或体积较大的 software 差异可 clone 烤入 rootfs，减少每次启动的 node-apply 成本
nodeforge profile clone <source-profile> <new-profile>
nodeforge profile add-values <new-profile> software.packages.include <package>...
nodeforge profile rootfs build <new-profile> --wait
nodeforge profile set <profile> diskless.overlay.tmpfs_percent=40 \
  diskless.failure.max_attempts=3 diskless.failure.backoff_seconds=30
nodeforge profile set <profile> system.ssh.enabled=true system.timezone=Asia/Shanghai
nodeforge profile add-values <profile> system.ssh.root_authorized_keys <public-key>...
nodeforge profile item add <profile> system.hosts id=controller address=192.168.50.2 names=controller,controller.local
nodeforge profile add-values <profile> software.packages.include chrony
nodeforge profile remove-values <profile> software.packages.include <package>
nodeforge profile show <profile>
nodeforge profile effective <profile> [--section build|boot|all]
```

`--kind` 是 immutable discriminant。`--source` 对 install/diskless 都必填，diskless boot bundle 内的 source 必须与其
一致。`profile create` 不带 `--kind` 时默认 `--kind install`（向后兼容 v0.1）；
一旦创建后 kind 不可改变；v0.2 通过创建新 Profile、换绑 Node 和归档旧引用完成替换。diskless 不接受
`install.*`；install Profile 不接受 `diskless.*`。
`profile list --kind` 按 kind 过滤；human 输出保留 v0.1 install 信息并增加 tagged kind 字段：
`NAME KIND PLATFORM SOURCE BOOT_BUNDLE PROVISION_BUNDLE NODES REVISION VALID`。不适用列显示 `-`；JSON 的
kind-specific detail 使用 tagged object，不能为了 diskless 列删除 install source/platform 投影。
`profile show` 必须提供可追溯 provenance，不要求额外 flag。human 至少显示：

```text
NAME              compute-diskless
KIND              diskless
REVISION          revision-4
CREATED_AT        2026-07-22T10:15:00Z
UPDATED_AT        2026-07-22T11:30:00Z
INSTALL_SOURCE    rocky-9.7@revision-12
SOURCE_IMPORTED   2026-07-20T08:00:00Z
CREATED_FROM      clone:compute-base@revision-7
CLONED_AT         2026-07-22T10:15:00Z
CLONE_CHAIN       compute-base@revision-7 -> compute-diskless@revision-1
SSH_CLIENT_KEY    SHA256:... (public fingerprint only)
SSH_HOST_KEY      SHA256:... (shared host public fingerprint)
```

直接 create 的 `CREATED_FROM` 显示 `install-source:<name>@<revision>`、`CLONED_AT` 显示 `-`。clone 必须保存
直接 source Profile 名称/revision 和 clone 时间；若 source 也是 clone，`profile show` 继续解析并显示只读
`CLONE_CHAIN`（根 Profile 到当前 Profile），但运行时仍没有继承关系。JSON 固定包含 `created_at`、`updated_at`、
`install_source{name,revision,digest,imported_at}`、`provenance{origin,cloned_from,cloned_at,clone_chain}`、
`ssh_client_public_fingerprint` 和 `ssh_host_public_fingerprints`，不输出任何 private key。
`profile effective --section build` 输出完整 Profile build projection（软件/system/bundle/target-system）以及
`rootfs_input_digest`；该 digest 是规范化构建输入的确定性指纹，不是加密后的配置，也不是 rootfs 文件校验和。
`--section boot` 只输出 Profile 可证明的 boot requirements（所需 feature、Node 必填字段、内存预算公式），不能在没有
具体 Node 的情况下声称网络、inventory memory、rootfs readiness 或 quarantine 已通过；`--section all`（默认）输出两者。
只有 `node effective --section boot`/`node readiness --stage boot` 消费 Node direct/override/runtime 后给出最终 boot 投影与
readiness。Profile 输出不产生可供 `deploy=true` 使用的 `desired_plan_digest`。
Profile 删除是 v0.2 非目标：有引用 Node 的 Profile 不能删除，无引用时也不提供 `profile remove`
（避免与 active session/delivery snapshot 产生孤儿引用；废弃 Profile 通过换绑 Node 归档）。
`diskless.provision.bundle` 可省略；Node 可通过 `overrides.diskless.provision.bundle` 完整替换自身 first-boot，
但该 override bundle 只能包含 `phase=first-boot` item，出现 rootfs-build item 在 mutation/compile 阶段拒绝。
Profile first-boot manifest/assets/package closure 在 rootfs build 中预置；Node override payload 由 agent pre-init 切根后
通过 session-bound `agent:read` 下载并校验到 `/run`，并在修改目标系统前清除读 token。CLI plan 必须分别显示 source、
digest、closure 与 payload size；agent 只获取 expected digest 的 immutable AgentPlan/closure，不拉取可变 bundle 或在线
解析依赖。Profile 与 Node effective first-boot 都为空时，agent 只完成 running handoff/event。
list/set 类型必须使用对应 collection 命令。

`profile clone` 拷贝 source 指定 revision 的完整 stored Profile 配置；source/target kind 相同，target 创建后
不再动态继承 source。`--set` 只修改 target，与 create 在同一 CAS 事务中提交。diskless clone 默认
复用 source 的 Profile SSH client keypair 与 sshd host keys；`--new-ssh-keys` 在 clone 事务中重新生成两者，
用新 client 公钥重算 Profile `authorized_keys`，并用新 host public key 重算 Profile 域 `ssh_known_hosts`。
`--new-ssh-keys` 与 `--build` 均仅适用于 diskless；install clone 的 SSH 行为继续沿用 v0.1，不由 v0.2 flag 改写。
`--build` 创建成功后以 target 的 `rootfs_input_digest` 紧接执行
rootfs build；`--wait` 仅在同时传 `--build` 时合法，含义与 `profile rootfs build --wait` 一致。输出包含
`source_profile/source_revision/target_profile/target_revision/ssh_keys_reused/rootfs_input_digest/
build_operation`，但不输出任何私钥。
`--set` 只接受 scalar PropertySpec。software/users/hosts 等 collection 继续使用已有 collection/item CLI；需要修改
collection 时不要在 clone 上同时传 `--build`，先完成 target mutation，再显式 build，避免产生无意义的中间 rootfs。

## 6. 阶段 5：创建 Node，先保持 deploy=false

```text
nodeforge node add <id> mac=<mac> arch=<arch> profile=<diskless-profile> deploy=false
# hostname 未显式指定时默认使用 node_id；network.mode 默认 dhcp
nodeforge node set <id> pxe.ip_reservation=<ip> hostname=<fqdn>
nodeforge node set <id> network.mode=dhcp network.interface=<nic>
nodeforge node set <id> network.mode=static network.interface=<nic> \
  network.address=<ip> network.prefix_len=<prefix> network.gateway=<gw>
nodeforge node add-values <id> network.dns <dns>...
nodeforge node add-values <id> overrides.kernel_args.add console=ttyS0
nodeforge node set <id> overrides.system.ssh.root_password=<password>
nodeforge node add-values <id> overrides.system.ssh.root_authorized_keys.add <public-key>...
nodeforge node set <id> overrides.system.connectivity.time_sync=true
nodeforge node add-values <id> overrides.system.connectivity.ntp_servers.add <ntp-server>...
nodeforge node set <id> overrides.system.security.firewall=enabled overrides.system.security.selinux=enforcing
nodeforge node add-values <id> overrides.software.repositories.add <repository-capability-id>...
nodeforge node set <id> overrides.software.environment=<environment-capability-id>
nodeforge node add-values <id> overrides.software.groups.add <group-capability-id>...
nodeforge node add-values <id> overrides.software.tasks.add <task-capability-id>...
nodeforge node add-values <id> overrides.software.packages.include.add <package>...
nodeforge node add-values <id> overrides.software.packages.include.remove <package>...
nodeforge node add-values <id> overrides.software.packages.exclude.add <package>...
nodeforge node set <id> overrides.diskless.provision.bundle=<first-boot-only-bundle>
nodeforge node unset <id> overrides.diskless.provision.bundle
nodeforge node set <id> overrides.diskless.overlay.tmpfs_percent=60 overrides.diskless.failure.max_attempts=3
nodeforge node item add <id> overrides.system.hosts id=peer-extra address=192.168.50.120 names=peer-extra
nodeforge node show <id>
nodeforge node effective <id> [--section build|boot|all]
```

- `node show` 输出 Node direct 字段 + 绑定 Profile + current state 投影（不含 effective 编译结果）。host fingerprint
  属于绑定 Profile，由 `profile show` 展示；Node 不保存独立 host key。
  `node effective` 引用绑定 Profile 的不可变 build projection，并按 v0.1 优先级合并适用的 Node override 得到
  Node boot/node-apply/effective first-boot projection；Node 差量不合入 diskless rootfs lower。两者使用相同 section 名，
  但 `boot` 在 Profile 下是 requirements，在 Node 下才是 resolved projection/readiness 输入。
- Node direct 字段不进入 overrides；diskless 不消费 storage，非空 install-only override 使 readiness 失败。
- diskless 支持 v0.1 全部跨 kind 的 system/software/kernel args override，canonical path 与 merge 语义不改；服务端
  boot-project 只编译 immutable pre-init plan，不操作 rootfs。password、users、`authorized_keys.add/remove`、sshd、
  localization、NTP、security、hosts、network/machine-id 与 software 全部由 `nodeforge-agent --pre-init` 写 upper；Profile 自动生成的
  client public key 是 mandatory 域内 key，标准 remove 不能删除，hosts 改变时同步以共享 host public key 重算
  `ssh_known_hosts`。software 的 repositories/environment/groups/tasks/packages include/exclude 全部按 v0.1 merge 后进入
  AgentPlan/`node_apply_projection`；initrd 只交接 AgentPlan URL/digest/size/expiry 与短时 `agent:read` token，不取得或
  解释字段、不写 target-system。agent 切根后以 bootstrap 网络从服务端拉取并校验 plan/全部 payload，清除读 token，
  再在真正 init 前按 pinned closure 执行。Node override
  变化只改 `desired_plan_digest`，
  不触发 Profile rootfs 重建。
- `overrides.diskless.provision.bundle` 是 nullable scalar replacement，引用 bundle 必须 first-boot-only。其 immutable
  payload digest 进入 `desired_plan_digest`/`delivery_digest` 而不进入 `rootfs_input_digest`；agent pre-init 在切根后、
  修改目标系统前从服务端下载校验并清除读 token，完成 node-apply、exec 真正 init 后，由 systemd 的 agent first-boot unit
  本地执行。`node effective --section boot`
  必须显示 effective bundle 来源为 profile 或 node override。
- `overrides.system.hosts` 是 nullable ordered replacement；首次 `node item add|set|remove` 原子物化 Profile
  `system.hosts`，`node unset <id> overrides.system.hosts` 恢复完全继承。SSH key 仍使用 v0.1 add/remove
  set delta，不增加第二套 key 合并语义。
- Profile 换绑只允许 `deploy=false` 且无 active/recoverable session。kind 改变时旧 current state 归档。
- 同一 MAC 只能对应一个 Node；同一 Node 只能有一个 Profile kind 和一个 current session。
- Node 删除是 v0.2 非目标：有 active/recoverable session 的 Node 不能删除；无 session 时也不提供
  `node remove`（避免 delivery snapshot 孤儿；废弃 Node 通过 `deploy=false` 停用 + 换绑归档）。

跨 kind 换绑被阻止时，human error 必须给出当前阻塞事实和可复制的下一步，禁止只报 `conflict`：

```text
error: node.profile_kind_change_blocked
node c001: diskless -> install is not allowed yet
blockers:
  - deploy is true
  - session 9a2c... is active at diskless.rootfs_downloading
next:
  1. nodeforge node set c001 deploy=false
  2. nodeforge node status c001
  3. wait until the session is terminal, then run: nodeforge node set c001 profile=rocky-install
note: deploy=false blocks new PXE boots; it does not terminate the active session
```

若已经 `deploy=false` 但存在 recoverable session，提示其 expiry 和 `node trace` 命令；v0.2 不提供 `--force`
绕过，也不为换 kind 远程停止节点。JSON error 固定包含 `code/from_kind/to_kind/blockers/active_session/
recoverable_until/next_commands`。

## 7. 阶段 6：build plan 与 rootfs 构建

```text
nodeforge profile effective <profile> --section build
nodeforge profile rootfs plan <profile>
nodeforge profile rootfs build <profile> [--new-ssh-keys|--verify-reproducibility] [--wait] \
  [--if-input-digest <digest>]
nodeforge profile rootfs status <profile> [--operation <id>]
nodeforge node readiness <node> --stage build
nodeforge assets rootfs list [--state building|ready|failed]
nodeforge assets rootfs show <rootfs-input-digest>
nodeforge assets rootfs validate <rootfs-input-digest> [--deep]
```

`profile rootfs plan` 输出 `rootfs_input_digest`、cache state、fixed revisions、builder/arch capability、软件解析、
预计 compressed/uncompressed size、rootfs-build steps 和明确排除的 Node boot projection。它不产生
`desired_plan_digest`，也不要求存在 Node 或 deploy=true。

JSON 输出关键字段（用于后续命令的 CAS）：

```json
{
  "rootfs_input_digest": "sha256:...",
  "cache_state": "ready|building|miss",
  "estimated": {"compressed_bytes": ..., "uncompressed_bytes": ...}
}
```

普通 `profile rootfs build` 原子快照执行时最新 build projection；可选 `--if-input-digest` 取此前
`profile rootfs plan` 输出的 `rootfs_input_digest`，仅用于自动化防止“plan 后配置发生变化仍继续构建”。
`profile effective --section build` 是 `profile rootfs plan` 的超集；前者输出完整 build projection，后者是构建专用简表。

`rootfs build`：

- 不带 guard 时由服务端原子确定 input digest；带 `--if-input-digest` 时若已漂移，返回
  `operation.input_digest_conflict`（exit 3）。相同 digest building 时 join operation，ready 时返回 cache hit。
- `--new-ssh-keys` 生成新的 Profile SSH client 公钥/私钥与 sshd host keys，用新 client public key 重算
  `authorized_keys`，用新 host public key 重算 Profile 域 `ssh_known_hosts`，发布新 Profile revision/new input digest，并直接构建该
  revision。输出同时包含 `previous_profile_revision/new_profile_revision/previous_rootfs_input_digest/
  rootfs_input_digest/ssh_keys_created/build_operation`，永不输出私钥。
- 新 SSH keys 总会产生新 input digest，不能命中旧 rootfs cache；它与 `--verify-reproducibility` 互斥。build 失败时新 Profile revision
  保留为 not-ready，修复后用输出的新 digest 普通重试，不再次生成密钥。
- 新 SSH keys 不修改 active BootSession。旧、新 rootfs 混跑期间不保证双向免密，host fingerprint 也会变化；
  human 输出必须给出该 rollout 警告。
- `--verify-reproducibility` 仅用完全相同输入重新构建并比较输出，不覆盖旧对象；输出不同则失败。禁用含义模糊的
  `--force` 名称。
- operation 输出 `queued|building|validating|ready|failed`、step、percent/bytes、started/updated、稳定 reason。

## 8. 阶段 7：boot readiness 与启用

```text
nodeforge node readiness <node> --stage boot
nodeforge node boot preview <node>
nodeforge node set <node> deploy=true [--if-plan-digest <desired-plan-digest>]
nodeforge node set <node> deploy=false
```

`--stage build` 与 `--stage boot` 必须分开：前者回答“能否构建”，后者回答“现在能否发 bootfile”。boot
readiness 检查 rootfs ready、deep validation、delivery manifest、feature/kernel/modules、AgentPlan renderer、
MAC/IP、quarantine 和 session gate。若已有可信 `inventory.memory_bytes`，服务端执行硬内存预算；新节点内存
未知时输出 `memory=unknown` 与 `required_min_memory_bytes` warning，不能伪造通过结论，最终由 initrd 实测硬闸。
v0.2 squashfs 预算使用统一 `available_budget`：readiness 以 inventory 减 kernel/initrd，initrd 直接使用
`MemAvailable`；输出同时包含 `compressed_bytes/node_firstboot_payload_bytes/upper_limit_bytes/safety_margin_bytes/
required_min_memory_bytes`，所有
计算为 checked `u64`，不能在 initrd 侧再次扣 kernel/initrd。

`deploy=true` 是唯一启用入口；普通调用原子使用执行时最新 `desired_plan_digest`，自动化可用从 `node effective` 或
`node readiness` 取得的 `--if-plan-digest` 防止观察后漂移。not-ready 返回逐项 reason，不创建失败 attempt。
`deploy=false` 立即阻止新 PXE，但不终止正在下载/运行的 session。
`boot preview` 只显示 capsule digest/path template/expiry，不显示 config token；真实 per-session capsule 在允许 bootfile
前随 BootSession/delivery snapshot 原子生成，不能由 CLI 预生成或导出。`boot preview` human 输出：

```text
CAPSULE_DIGEST    KERNEL_PATH                          INITRD_PATH                          EXPIRES_AT
sha256:...        rocky-9.7/vmlinuz-5.14.0...          rocky-9.7/nodeforge-initrd...        2026-07-22T12:00Z
```

JSON 输出额外包含 `config_url_template`（占位符不展开）、`kernel_args`、
`agent_plan:{schema_version,digest,size,url_template}` 和
`required_features:{initrd:[...],agent:[...]}`，不含 token；两个集合分别由 initrd manifest 与 rootfs agent manifest 校验，
不能合成一个模糊列表。

## 9. 阶段 8：唯一状态与观测

```text
nodeforge node list [--kind install|diskless] [--state <canonical-state>]
nodeforge node status <node>
nodeforge node trace <node> [--session <id>]
nodeforge runtime dhcp-leases [--node <id>]
nodeforge runtime tftp-sessions [--node <id>]
nodeforge events list --node <id> [--session <id>] [--type <type>] [--since <iso>] [--until <iso>] [--limit <n>]
nodeforge events follow --node <id> [--session <id>]
nodeforge events types
```

human list 固定列：

```text
ID   KIND      PROFILE      STATE                    SESSION  POSTPROCESS  QUARANTINE  SEEN
c001 diskless  compute      diskless.running         9a2c...  succeeded    ok          ...
n002 install   rocky-base   install.packages         c017...  -            ok          ...
```

`node status <node>` human 输出展开当前 session 的 canonical phase、时间戳、plan/rootfs digest 摘要、
quarantine 状态和 postprocess 摘要；处于 `diskless.agent_configuring` 时还显示
`agent_stage=plan-fetch|payload-prefetch|node-apply` 及无进展时长，但这些只是 stage 事件，不新增 lifecycle state。
JSON 输出 `current` tagged union + `history` 最近 sessions。
`runtime dhcp-leases` human 输出列：`NODE MAC IP LEASE_EXPIRES SESSION`；`tftp-sessions` 列：
`NODE MAC FILENAME BYTES TRANSFERRED STATUS SESSION`。`events list --limit` 默认 100，`--until` 与 `--since`
均为包含边界，构成闭区间，与 v0.1 本地 event reader 契约一致。`events types` 列出全部已注册事件类型（继承 v0.1）。

`STATE` 是唯一 current lifecycle state。JSON `current` 是 tagged union：

```json
{"kind":"diskless","state":"diskless.running","session_id":"...","plan_digest":"...","postprocess":{"status":"succeeded"}}
```

禁止同时输出 `install_state` 和 `diskless_state`。历史不同 kind 只由 trace/events 展示，并明确 session/kind/digest。

## 10. 阶段 9：first-boot 结果

```text
nodeforge node postprocess show <node> [--session <id>]
nodeforge node postprocess show <node> --step <id> [--include-output]
```

使用 `postprocess` 而不是 `postinstall`：diskless 没有 install，`postinstall` 会造成所有权误解。输出 step 的
`pending|running|succeeded|warned|failed|skipped`、attempt、summary、bounded output 和时间戳。
不带 `--session` 时优先查当前 active session；没有 active session 才查最近终态 session。这样运行中的 first-boot
可以直接观测，且普通重启后仍能回看最近结果。无任何 session 时返回空结果（exit 0）。
`--include-output` 额外显示 step 声明的允许输出（脚本 stdout/stderr 最后 2048 bytes 转义摘要），
受 action 声明的敏感输出规则裁剪；不带该 flag 时不显示 step output。

pre-init node-apply 属 boot lifecycle：失败时真正 init 未启动，状态为 `diskless.failed` 并进入 failure/quarantine
计数，不显示成 postprocess。first-boot 失败不把 lifecycle 从 `diskless.running` 回退为 failed；它只令
`postprocess=degraded`。没有独立
远程 retry：当次 retryable step 按策略自动重试；新 PXE session 会重新执行所有 first-boot items。
该命令展示服务端已收到的 event 投影，不远程读取节点；事件回传中断时返回 `reporting=incomplete` 和最后 seq，
本地 journal 只能通过节点 console/SSH 运维查看，CLI 不伪造最终 succeeded/failed。

## 11. 阶段 10：quarantine、retry 与缓存容量

```text
nodeforge node diskless retry <node> [--if-failure-revision <revision>]
nodeforge status --component rootfs-cache,quarantine
```

- retry 只清当前 `(node, plan_digest)` failure gate；普通调用使用执行时最新 failure revision，自动化可用
  `--if-failure-revision` 防漂移；active session、deploy=false、kind!=diskless、digest 漂移均拒绝。
- v0.2 没有 rootfs delete/GC 命令。`status --component rootfs-cache` human 输出：

```text
OBJECT_COUNT    TOTAL_BYTES    AVAILABLE_BYTES    WARN_THRESHOLD    STATUS
42              128 GiB        256 GiB            80%               ok
```

  空间不足时 `STATUS=warn`/`critical` 且新 build 返回 `rootfs.insufficient_storage`（exit 5），不得自动删旧镜像。
  `status --component quarantine` 输出所有 quarantined node 的 `(node, plan_digest, reason, quarantined_at)`。

## 12. v0.3+ 命令隔离

- v0.3 才提供 `firmware.mode=bios`、PXELINUX 和 `install-post` phase。
- v0.4 才提供多 NIC/VLAN/bonding、临时 PXE rootfs 构建节点和 install first-boot agent。
- v0.5 才提供 `diskless.overlay.mode=ram_rootfs`。

这些字段/enum/handler 不得出现在 v0.2 help 或 parser 中；reconciliation、远程命令、NFS root、iPXE、IPv6
永久没有对应 CLI。

## 13. digest 流转与命令对应

三个 digest 在 CLI 各阶段的使用固定如下，不得混用：

| guard 对象 | 观察命令 | 消费命令 | 可选防漂移 flag |
|---|---|---|---|
| `desired_plan_digest` | `node effective`、`node readiness` | `node set deploy=true` | `--if-plan-digest` |
| `rootfs_input_digest` | `profile rootfs plan`、`profile effective --section build` | `profile rootfs build` | `--if-input-digest` |
| `delivery_digest` | 服务端在允许 bootfile 前原子创建 BootSession/delivery snapshot 时生成 | 不作为 CAS 输入；`node status`/`node trace` 只显示摘要 | — |
| failure revision | `node status`（quarantined 时输出 `failure_revision`） | `node diskless retry` | `--if-failure-revision` |

正常的人机流程不需要复制 digest：

```text
profile rootfs build <profile> --wait
node readiness <node> --stage boot
node set <node> deploy=true
```

需要严格“按刚才预览内容执行”的自动化流程才传 guard：

```text
profile rootfs plan <profile>
  -> 输出 rootfs_input_digest=R
profile rootfs build <profile> --if-input-digest R --wait
  -> 构建完成，rootfs ready
node readiness <node> --stage boot
  -> 解析绑定 Profile 的 R，输出 desired_plan_digest=D
node set <node> deploy=true --if-plan-digest D
  -> PXE 启用
```

digest 漂移按输入归属区分，不能笼统认为任意 Node 修改都会使 rootfs cache miss：

| 变化 | `desired_plan_digest` | `rootfs_input_digest` | 结果 |
|---|---|---|---|
| Profile software/system（含用户、password hash、authorized_keys、hosts）、rootfs-build、first-boot closure、source/kernel/builder ABI | 所有绑定 Node 都变 | 变 | 旧 build/deploy CAS 均冲突 |
| Node identity/network、kernel args、overlay/failure policy | 变 | 不变 | 可复用 Profile rootfs；旧 deploy CAS 冲突 |
| Node system/software/SSH/hosts/kernel args/overlay/failure/provision bundle override | 变 | 不变 | 复用 Profile rootfs；全部 target-system/software 差量由 agent pre-init 写 upper，Node first-boot payload 进 delivery；旧 deploy CAS 冲突 |
| rootfs 构建输出 content SHA-512 | 不变 | 不变 | 只进入 `delivery_digest`；同输入不同输出报 non-reproducible |

显式 guard 使用旧 digest 时，`build`/`deploy=true` 分别返回 exit 3（`operation.input_digest_conflict` /
`operation.plan_digest_conflict`）；未传 guard 时原子采用最新 snapshot，不产生这类"复制值过期"错误。只有
`rootfs_input_digest` 变化才要求重建；仅 desired 输入变化时重新 readiness 并复用相同 rootfs。

## 8. diskless 全流程 CLI（v0.2 新增）

> **设计原则**：v0.2 diskless 全流程必须通过 CLI 完成。操作员不应手动编辑 catalog JSON 文件。
> 所有 catalog 实体（assets、boot-bundles、profiles、nodes 等）的创建和修改都通过 `nodeforge` CLI
> 命令完成，CLI 通过 management API 调用 daemon，由 daemon 执行原子事务写入 catalog store。
> 手动编辑 catalog 只在故障恢复或紧急诊断时作为最后手段。

### 8.1 完整流程

```bash
# 1. 初始化 NodeForge 实例
nodeforge setup --install-root /opt/nodeforge --server-ip <ip> --subnet <cidr> \
  --pool-start <start> --pool-end <end> --http-port <port>

# 2. 导入安装介质（自动提取 bootloader/kernel/initrd/repository）
#    bootloader 使用内容寻址路径，不同发行版不冲突
nodeforge assets import <iso-file>

# 3. 注册 diskless 专用资产
#    kernel：从 ISO 提取或单独提供（kind=kernel）
nodeforge assets register --type kernel --name <k> --path <p> \
  --distro <d> --version <v> --arch <a> --kernel-release <r>
#    nodeforge-initrd：dracut 构建、原子发布并注册（kind=nodeforge_initrd）
nodeforge assets initrd build <i> \
  --from-install-source <source> --kernel-release <r>

# 4. 创建 boot bundle（仅绑定 kernel/initrd；派生 rootfs 不进入 bundle）
#    这是 diskless 全流程 CLI 的关键环节，替代手动编辑 catalog JSON
nodeforge assets boot-bundle create <name> \
  --kernel <k> --initrd <i> \
  --distro <d> --version <v> --arch <a> --kernel-release <r>

# 5. 创建 diskless profile（引用 boot bundle）
nodeforge profile create <name> <install-source> --kind diskless --boot-bundle <name>
# 后续切换不可变 bundle：
nodeforge profile set <name> diskless.boot_bundle=<new-bundle>

# 6. 构建并注册 Profile 派生 rootfs
nodeforge profile rootfs build <diskless-profile>

# 7. 注册节点并启用；session/capsule 由 PXE 请求创建
nodeforge node add <id> --mac <mac> --arch <a> --profile <name>
nodeforge node set <id> deploy=true
```

### 8.2 `assets boot-bundle create` 命令

```text
nodeforge assets boot-bundle create <name> --kernel <asset> --initrd <asset> \
  --distro <d> --version <v> --arch <a> --kernel-release <r> [options]
```

**参数**：

| 参数 | 必填 | 说明 |
|---|---|---|
| `name` | 是 | Canonical boot bundle name（逻辑标识符） |
| `--kernel` | 是 | Kernel 资产名称（必须 kind=kernel） |
| `--initrd` | 是 | NodeForge initrd 资产名称（必须 kind=nodeforge_initrd） |
| `--distro` | 是 | 发行版名称（如 rocky, ubuntu） |
| `--version` | 是 | 发行版版本（如 9.7, 24.04） |
| `--arch` | 是 | 架构：aarch64 或 x86_64 |
| `--kernel-release` | 是 | 内核 uname release（如 5.14.0-611.5.1.el9_7.aarch64） |

**前置条件**：kernel/initrd 资产必须已通过 `nodeforge assets register` 注册到 catalog。

**API**：`POST /api/v1/management/boot-bundles`

**校验链**：必填字段非空 → arch 枚举有效 → 名称不重复 → kernel 资产 kind=kernel →
initrd 资产 kind=nodeforge_initrd → catalog 原子写入。

**错误码**：

| code | HTTP | 说明 |
|---|---|---|
| `boot_bundle.invalid` | 400 | 缺少必填字段或 arch 无效 |
| `boot_bundle.already_exists` | 409 | boot bundle 名称已存在 |
| `boot_bundle.asset_not_found` | 404 | 引用的资产不存在 |
| `boot_bundle.asset_kind_mismatch` | 400 | 资产类型不匹配（如 kernel 资产 kind 不是 kernel） |
| `catalog.publish_failed` | 503 | catalog 持久化但快照发布失败 |

### 8.3 `assets boot-bundle list` 命令（计划中）

```text
nodeforge assets boot-bundle list [options]
```

列出所有已注册的 boot bundles。**API**：`GET /api/v1/management/boot-bundles`
