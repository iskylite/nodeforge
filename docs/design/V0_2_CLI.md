# NodeForge v0.2 CLI 接口

状态：v0.2 接口分册，核心 CLI/API 已实现并持续按验证结果收口。总纲以 [`V0_2_DESIGN.md`](V0_2_DESIGN.md) 为准；本文是 CLI
命令树、flag、CAS、输出和 exit code 的唯一事实源。推荐操作顺序见
[`V0_2_DISKLESS_WORKFLOW.md`](V0_2_DISKLESS_WORKFLOW.md)。命令必须复用 v0.1
资源-动作树、typed PropertySpec/CollectionSpec/ItemSpec、统一 OutputDocument 和 optimistic concurrency；
预留 enum、help 或空 handler 不算实现。

> 本文同时包含当前接口与后续目标接口；不得据此假定每个命令已经实现。当前代码可用命令及缺口以
> [`../audits/CURRENT_IMPLEMENTATION_ALIGNMENT_REVIEW.md`](../audits/CURRENT_IMPLEMENTATION_ALIGNMENT_REVIEW.md)
> §4 为准，durable operation、boot preview 与 CLI 收口归入
> [`V0_2_2_OPERABILITY.md`](V0_2_2_OPERABILITY.md)。

本文不规定内部模块如何实现命令；流程分册可以摘录命令，但不能改变这里的接口契约。

## 0. 共用约定

- `show key == --help-full key == parser key == API operation path`。
- 所有 closed-choice/enum 参数必须在该 flag 的普通 description 中完整列出合法 token，因而 `--help`
  和 `--help-full` 都能直接发现取值；不得只写 “kind/type/state” 或依赖错误响应说明。省略参数若表示
  “全部”，必须明确写成 “omit to list all”，不能暗示存在未被 parser 接受的 `all` token。合法值按
  后端或资源而变化时，帮助同时列出全集及适用关系；动态集合则必须给出查询合法值的 CLI（例如
  `nodeforge events types`）。新增/扩展 Zig enum 时必须有 contract test 证明帮助覆盖每个枚举标签。
- 该可发现性契约不限于 Zig `enum`：布尔 token、格式名、阶段/模式字符串、整数范围、哨兵值、成组或
  互斥关系也必须在参数 description 或 `--help-full` 的 `VALUES/CONSTRAINT` 中说明。PropertySpec 和
  ItemSpec 对 enumeration/arch 字段必须登记 `value_constraint`；布尔统一展示 `true|false`，正整数
  统一展示 `>0`，更窄范围由字段覆盖。parser 已接受而 registry/help 未登记的值属于 contract bug。
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
  `runtime`）经 HTTP 管理 API 调用 daemon，要求 daemon 在线且管理 API 可达。
- exit code：0 成功；1 本地执行错误（文件 I/O、序列化、损坏的本地状态）；
  2 输入/不适用；3 revision/digest 冲突；4 not-ready/quarantined；5 operation failed；
  6 daemon 连接失败、服务不可用或等待超时。JSON error 同时返回稳定 `error.code`；exit code 只表达大类，
  自动化必须结合 `error.code` 判断具体原因。

```text
nodeforge operation show <id>
nodeforge operation follow <id> [--timeout <seconds>]
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
| 组合/新身份 | — | 只完成主命令 | — |
| 验证模式 | `--deep` | 执行普通校验 | 需要更深制品校验时；不表示绕过错误 |

正常的人机流程示例不展示 `--if-*`；自动化示例才展示。这样保留精确 CAS 能力，但不把实现细节变成日常必填参数。

## 1. 阶段 0：服务预检

```text
nodeforge status
nodeforge config validate
nodeforge catalog validate
```

`status` 执行端到端 daemon 就绪检查：环回管理 API、活动配置、HTTP/catalog/DHCP/TFTP 可达性。
`--output json` 返回结构化结果，任一 required 项失败 exit 1。

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
nodeforge assets import <iso-path> [--qualifier <value>]

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
nodeforge assets boot-bundle create <install-source> [--qualifier <value>] \
  --kernel <k> --initrd <i> \
  --distro <d> --version <v> --arch <a> --kernel-release <r>
# profile name 可选：省略时自动派生为 <install-source>-diskless
nodeforge profile create <install-source> [--qualifier <value>] --kind diskless

# 5. 构建 Profile 派生 rootfs；外部构建时改用 register
nodeforge profile rootfs build <diskless-profile> [--if-input-digest <digest>]
nodeforge profile rootfs register <diskless-profile> \
  --path <squashfs-path> [--uncompressed-size <bytes>]

# 6. 添加节点（保持 deploy=false）
nodeforge node add <id> mac=<mac> arch=<a> profile=<diskless-profile>
nodeforge node deploy <id> false

# 7. readiness 后启用部署；真实 session/capsule 在 PXE 请求时原子创建
nodeforge node readiness <id> --stage boot
nodeforge node deploy <id> true
```

外部制品首次省略 `--uncompressed-size` 时仍会登记成功，但容量状态为 unknown。
之后可对同一文件再次执行 register 并提供可信正数；服务端返回
`state=metadata_updated` 并持久化补全。已知值冲突或其他不可变元数据漂移会返回
冲突，并保证不覆盖正式 rootfs 文件。

默认安装根初始化和 `setup --reconfigure` 必须原子生成 `/etc/profile.d/nodeforge.sh`（`0644`），
幂等地将 `/opt/nodeforge/bin` 加入登录 shell 的 `PATH`。新登录会话可直接执行 `nodeforge`；当前会话可
执行 `source /etc/profile.d/nodeforge.sh`。自定义安装根不写宿主全局 profile.d。

**已实现**（见 V0_2_DESIGN.md 实现修订记录）：
- R5: `assets initrd build` 已接线为同步 CLI；异步 durable operation 是 v0.2.2 增强
- R4: `profile rootfs build` capability 已在 `setup.zig` 中修复
- R6: ISO 导入自动注册 kernel（`<source>-kernel`），无需手动 `assets register`
- R1: `catalog schema-v4` CLI 命令已移除，setup 始终生成最新 schema 版本

## 2. 阶段 1：导入本地 OS 源

```text
nodeforge assets import <iso> [--name <source-base>] [--qualifier <value>] \
  [--distro <id>] [--version <version>] [--arch <arch>]
nodeforge assets install-source list
nodeforge assets install-source show <source>
nodeforge assets install-source software list <source> [--kind package|group|environment|task|metapackage]
nodeforge assets repository list
nodeforge assets repository show <repository>
nodeforge assets repository render <repository>
nodeforge assets repository software list <repository> [--kind package|group|environment|task|metapackage]

```

ISO import 成功必须原子发布 install source、installer kernel、media tree、本地 repositories 和 software index。
默认 InstallSource 由完整 ISO basename 去掉 `.iso` 后规范化得到；可选 `--qualifier`
只追加到该基础名。导入事务同时创建 `<InstallSource>-install` 默认 Profile。
因此所有发行版都保留 Kylin 等介质文件名中的 SP、发行批次和 Release 日期。
`--name` 仅用于无法正确识别的介质基础名覆盖，`--version` 可覆盖媒体元数据中的
catalog 版本事实。Ubuntu point release（如 `22.04.5`）保留为 catalog 版本和资源身份；
APT Release 的 `Version` 校验使用对应 series（如 `22.04`），两者不得混为一个字段。每个 source 使用独立
ISO、boot 和 repository 路径；导入不覆盖既有同名内容。

`repository render` 生成客户端配置：DNF 输出 `.repo`，APT 从已发布的 `dists/*/Release` 读取
Codename/Suite 和 Components 输出 `sources.list`。该命令只消费 catalog 与介质 metadata，不猜测发行版代号。
重复 import 相同内容返回 existing resource；同名不同 digest 返回 conflict，不静默覆盖。

Install 与 diskless 的 effective software 都默认继承当前 InstallSource 的全部 repository。Profile
`software.repositories` 在默认集合上追加并去重，Node
`overrides.software.repositories.remove` 可显式移除。Install 不再只把受管源当作一次性安装介质：

- Rocky/RHEL Kickstart 在目标系统删除 vendor 公网 `.repo`，并生成
  `/etc/yum.repos.d/nodeforge.repo`；URL 按当前 nodeforged IP/port 重新绑定。
- Ubuntu Autoinstall 通过 `apt.mirror-selection.primary` 将 NodeForge 本地 APT 源交给
  Subiquity/curtin 持久化。
- `profile/node software show` 展示 stored override 与 effective closure。API 中软件包 delta
  使用 `packages.include/exclude.{add,remove}` 嵌套结构；字段或 effective software 为空时 CLI
  显示空值，不得 panic。

RHEL comps 选择区分 environment、group 与 package。未设置
`software.environment` 时 Kickstart 使用 `@^minimal-environment`。`@^environment` 或 `@group`
安装 comps 定义的 mandatory/default 内容，不代表安装 optional 包，也不代表安装仓库全部包。
当前 CLI 没有“包含某 group 全部 optional 包”的开关；需要该语义时必须新增显式 package-type
策略，不能把全局 `%packages --optional` 隐式套用到 minimal environment。

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
nodeforge assets initrd build <name> \
  --from-install-source <source> --kernel-release <r> \
  [--target-sysroot <path>] [--module-source <asset>] \
  [--add-drivers <module-or-alias>]... [--install-package <package>]...
# 无可用 ISO/install source 时使用通用 fallback：
nodeforge assets initrd build <name> \
  --distro <d> --version <v> --arch <a> --kernel-release <r>
# 已有外部制品仍可通过受管路径 register
nodeforge assets register --type nodeforge_initrd --name <i> --path <p> \
  --distro <d> --version <v> --arch <a> --kernel-release <r>

nodeforge assets boot-bundle create <install-source> [--qualifier <value>] \
  --kernel <k> --initrd <i> \
  --distro <d> --version <v> --arch <a> --kernel-release <r>
nodeforge assets boot-bundle list
nodeforge assets boot-bundle show <name>
```

`assets initrd build` 优先使用 `--from-install-source`：保留 ISO vendor initrd（含发行版补丁、固件和内核模块）
并追加 NodeForge overlay。无 `--from-install-source` 时使用 `--distro/--version/--arch` 选择通用 dracut fallback。
原子发布到受管 initrd store 并注册结果。source 模式的物理路径为
`assets/diskless/initrd/<name>/<kernel-release>/initrd.img`；source/tuple provenance
由 catalog 保存，不再通过 `sources/manual` 多层目录重复表达，
目录直接表达操作员使用的制品名；精确 ISO/source 来源通过 asset show 查询。

`--kernel-release` 是用户明确指定的目标 ABI，不做阻断式一致性校验。若 source 中
installer kernel 已检测出 release 且与参数不同，CLI 输出警告并继续；后续
BootBundle 创建也只记录警告。initrd asset 自身声明的 release 仍必须与
BootBundle 一致，否则 kernel/modules ABI 无法成立。

BootBundle 只固定 source + prepared kernel + NodeForge initrd revisions，不含 rootfs。active session
的旧 snapshot 不得被原位破坏。

### 4.1 initrd 扩展输入模型

`--add-drivers` 与 `--install-package` 是目标 initrd 的声明式输入，不是宿主
`dracut` 参数透传。只要出现任一扩展参数，builder 必须能确定目标四元组
`(distro, version, arch, kernel_release)`，并从 `--from-install-source`、
`--target-sysroot` 或 `--module-source` 得到目标文件来源。

- `--target-sysroot` 是已物化的目标发行版文件树；动态加载器、package database
  和 `/lib/modules/<kernel_release>` 都必须来自这里，禁止回退宿主 `/`。
- `--module-source` 是已导入的 module bundle；manifest 声明四元组、模块、
  firmware、签名状态和 digest，适用于预编译厂商/OOT 驱动。
- `--add-drivers` 按模块名或 modalias 从目标 module tree 求依赖闭包；所有 `.ko`
  的 vermagic 必须匹配 `kernel_release`。
- `--install-package` 从匹配 install source 的 RPM/DEB 仓库离线解析并提取到
  extension staging。纯 userspace、firmware、匹配内核的 kmod 可用；覆盖 `/init`、
  动态加载器、libc、shell 或 vendor 自有文件默认拒绝。

| 场景 | 基底 | 扩展执行器 | 禁止事项 |
|---|---|---|---|
| Rocky/RHEL vendor | ISO vendor initrd | 在匹配目标 sysroot 中运行的 dracut/module 工具，或受控 closure copier | 读取宿主 `/` 的 `dracut-install`、宿主模块 |
| Ubuntu casper | ISO `/casper/initrd` | DEB/module bundle 提取 + depmod + NodeForge 追加层 | 在 Rocky 宿主用 dracut 生成 Ubuntu initrd |
| 通用 fallback | 明确 target sysroot | target dracut | 未给 sysroot 时安装包/驱动 |
| 异架构目标 | install source/module bundle | 纯提取工具；必要时显式构建执行环境 | 隐式 qemu/chroot 执行目标 ELF |

这里的“禁止宿主 dracut”特指禁止 dracut 从构建机 `/` 解析 userspace/module
闭包；并不禁止在明确的匹配目标 sysroot/构建环境里运行 dracut。

manifest 记录 source revision/digest、四元组、请求参数、解析后的文件/模块闭包、
vermagic/签名检查、碰撞清单和最终 digest。`plan` 先完成解析与冲突检查，`build`
只消费不可变计划。CLI 实现前，parser 不得提前接受这些 flag，以免形成把宿主内容
静默注入目标 initrd 的半契约。

外部 rootfs 注册可提供 `--uncompressed-size <bytes>`。该值是解压后文件树的
apparent size，不是 squashfs 文件大小；有值时进入 BootConfig 并参与 diskless
内存预算。缺失时登记为 unknown、输出 warning 并跳过内存容量硬校验，不阻止
注册或部署。只有明确大小与可用内存证明预算不足时才拒绝启动。由 NodeForge
构建的 rootfs 会在压缩前自动测量；测量失败同样降级为 unknown，而不是终止构建。

## 5. 阶段 4：创建 diskless Profile

```text
nodeforge profile list
nodeforge profile create <install-source> [--qualifier <value>] --kind diskless
nodeforge profile set <profile> FIELD=VALUE...
nodeforge profile unset <profile> KEY...
nodeforge profile add-values <profile> software.packages.include <package>...
nodeforge profile remove-values <profile> software.packages.include <package>
nodeforge profile set <profile> software.environment=minimal-environment
nodeforge profile add-values <profile> software.groups development network-tools
nodeforge profile software available <profile> --kind environment
nodeforge profile software available <profile> --kind group
nodeforge profile software show <profile>
nodeforge profile item add <profile> system.hosts id=controller address=192.168.50.2 names=controller,controller.local
nodeforge profile show <profile>
nodeforge profile remove <profile>
```

`--kind` 是 immutable discriminant，默认 `install`。Profile 名不再由用户手写，而由
`<完整-install-source>[-<qualifier>]-<kind>` 唯一生成。例如 source 为
`rocky-9.7-aarch64-minimal` 时，默认 install Profile 是
`rocky-9.7-aarch64-minimal-install`，`--qualifier compute --kind diskless` 生成
`rocky-9.7-aarch64-minimal-compute-diskless`。BootBundle 使用同一 source/qualifier
投影并固定 `diskless-bundle` 后缀，因此对应名称为
`rocky-9.7-aarch64-minimal-compute-diskless-bundle`。完整名称包含 ISO 探测出的
补丁版本、架构和介质 variant；CLI 与
HTTP API 使用同一服务端校验，不能绕过。

ISO 导入的 `--qualifier` 只追加到 ISO basename 派生（或 `--name` 覆盖）的基础名，
例如 `assets import rocky.iso --qualifier site-a` 生成 `<ISO标准基础名>-site-a`
InstallSource，并自动创建 `<InstallSource>-install`。它不能替换或缩写 ISO 基础身份。
一旦创建后 kind 不可改变；diskless 不接受 `install.*`，install Profile 不接受 `diskless.*`。
`profile show` 必须提供可追溯 provenance，不要求额外 flag。

### 5.1 旧短名称迁移

已有无 `-install` 后缀或使用短 source 前缀的名称不得在 daemon 启动时静默改名：
Profile 名被 Node 引用，BootBundle
又参与 rootfs input digest 和运行中 session 快照，原地自动改写会破坏可追溯性。
升级后旧对象可继续读取，但所有新建入口立即执行规范名称校验。迁移必须在节点
`deploy=false` 且没有活动 session 时显式完成：

1. 使用 `<完整-install-source>-diskless-bundle`（或保留完整 source 前缀的限定名称）
   创建新的 BootBundle；
2. 用同一完整 source 前缀创建新的 diskless Profile，并重新应用旧 Profile
   的可变配置；
3. 重新构建/注册新 Profile 的 rootfs；
4. 将 Node 切换到新 Profile，完成 readiness 后再恢复 `deploy=true`；
5. 确认零引用后删除旧 Profile。旧 BootBundle 在提供受引用保护的 remove
   命令前保留为不可变历史对象，不手工编辑 catalog 删除。
`profile remove` 只删除当前 catalog 中零 Node 引用的 Profile。有任何 Node 引用时返回 `profile.in_use`，
不会隐式解绑、停用或修改 Node。
list/set 类型必须使用对应 collection 命令（`add-values`/`remove-values`/`replace-values`/`item`）。

## 6. 阶段 5：创建 Node，先保持 deploy=false

```text
nodeforge node add <id> mac=<mac> arch=<arch> profile=<diskless-profile> deploy=false
# hostname 未显式指定时默认使用 node_id；network.mode 默认 dhcp
nodeforge node set <id> pxe.ip_reservation=<ip> hostname=<fqdn>
nodeforge node set <id> network.mode=dhcp network.interface_name=<nic>
nodeforge node set <id> network.mode=static network.interface_name=<nic> network.match_mac=<mac> \
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
```

- `node add` 与 `node set` 共享同一套 scalar `PropertySpec`/parser；创建时可一次提交 PXE 保留地址、hostname、
  storage/network 标量和 `overrides.*` 标量。集合仍使用 `add-values`/`replace-values` 或 item 命令，不能伪装成
  `key=value`。CLI 只发送 canonical create DTO；`profile` 是必需 nullable 字段，`deploy=false` 的未绑定节点
  显式发送 null。
- `node show` 输出 Node direct 字段、Node overrides、绑定 Profile 编译出的 effective 摘要与 current state 投影；human
  视图固定按 `Stored / Overrides / Effective / Runtime` 分区，并把点路径展开为缩进层级、按可见宽度对齐。host fingerprint
  属于绑定 Profile，由 `profile show` 展示；Node 不保存独立 host key。
  当前详情 API 需要已绑定 Profile 才能编译 effective；未认领节点可 list/claim/set/remove，但 `node show` 返回
  `node.profile_unassigned`。若未来需要 unclaimed detail，应单独定义 nullable effective DTO，不得伪造默认 Profile。
  Node 级 effective projection 由 `node readiness --stage boot` 在校验时编译，不作为独立 CLI 命令输出。
  Node 差量不合入 diskless rootfs lower。
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
  本地执行。`node readiness --stage boot`
  显示 effective bundle 来源为 profile 或 node override。
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
  2. nodeforge node show c001
  3. wait until the session is terminal, then run: nodeforge node set c001 profile=rocky-install
note: deploy=false blocks new PXE boots; it does not terminate the active session
```

若已经 `deploy=false` 但存在 recoverable session，提示其 expiry 和 `node trace` 命令；v0.2 不提供 `--force`
绕过，也不为换 kind 远程停止节点。JSON error 固定包含 `code/from_kind/to_kind/blockers/active_session/
recoverable_until/next_commands`。

> **注意**：上述 `--force` 限制仅适用于 Profile kind 换绑（diskless ↔ install）。普通属性变更命令
>（`node set`、`node unset`、`node add-values` 等）支持 `--force` 标志，用于在活动 session 期间
> 强制终止目标节点的 session（install PXE session 和/或 diskless delivery session）后执行变更。
> 详见 `V0_2_DESIGN.md` R13 和 `V0_1_DESIGN.md` §13。

## 7. 阶段 6：build plan 与 rootfs 构建

```text
nodeforge profile rootfs plan <profile>
nodeforge profile rootfs build <profile> [--if-input-digest <digest>]
nodeforge profile rootfs status <profile>
nodeforge node readiness <node> --stage build
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

`rootfs build`：

- 不带 guard 时由服务端原子确定 input digest；带 `--if-input-digest` 时若已漂移，返回
  `operation.input_digest_conflict`（exit 3）。相同 digest building 时 join operation，ready 时返回 cache hit。
- operation 输出 `queued|building|validating|ready|failed`、step、percent/bytes、started/updated、稳定 reason。
- build/register 的中间路径包含请求标识；已有制品校验、正式文件改名和 Store
  持久化在同一临界区提交。冲突请求不会覆盖已发布文件，持久化失败不会留下内存幽灵记录。

## 8. 阶段 7：boot readiness 与启用

```text
nodeforge node readiness <node> --stage boot
nodeforge node boot preview <node>
nodeforge node deploy <node> true
nodeforge node deploy <node> false
```

`--stage build` 与 `--stage boot` 必须分开：前者回答“能否构建”，后者回答“现在能否发 bootfile”。boot
readiness 检查 rootfs ready、deep validation、delivery manifest、feature/kernel/modules、AgentPlan renderer、
MAC/IP、quarantine 和 session gate。

`node deploy` 是启用入口：`node deploy <id>` 缺省等价于 `node deploy <id> true`；`node deploy false` 立即阻止新 PXE，但不终止正在下载/运行的 session。
`node boot preview` 严格只读地展示启动选择；真实 boot-prepare 是 daemon 内部
transition（签发 config token + agent plan），真实 per-session capsule
在 PXE 请求时随 BootSession/delivery snapshot 原子生成。

## 9. 阶段 8：唯一状态与观测

```text
nodeforge node list
nodeforge node show <node>
nodeforge node trace <node> [--session <id>]
nodeforge runtime dhcp-leases
nodeforge runtime tftp-sessions
nodeforge events list [--node <id>] [--session <id>] [--type <type>] [--since <iso>] [--until <iso>] [--limit <n>]
nodeforge events follow [--node <id>] [--session <id>]
nodeforge events types
```

`node show <node>` human 输出展开当前 session 的 canonical phase、时间戳、plan/rootfs digest 摘要、
quarantine 状态。JSON 输出 `current` tagged union + `history` 最近 sessions。
`runtime dhcp-leases` human 输出列：`NODE MAC IP LEASE_EXPIRES SESSION`；`tftp-sessions` 列：
`NODE MAC FILENAME BYTES TRANSFERRED STATUS SESSION`。`events list --limit` 默认 100，`--until` 与 `--since`
均为包含边界，构成闭区间，与 v0.1 本地 event reader 契约一致。`events types` 列出全部已注册事件类型（继承 v0.1）。
`node list` human 输出列：`ID MAC IP PROFILE DEPLOY INSTALL_INTENT STATUS ARMED INSTALL FINISHED SN`。
`ARMED` 取 deployment_control 的 `armed_at`（generation 武装时刻），`INSTALL` 取 `install_at`/`install.started`，
`FINISHED` 取首次 terminal/`finished_at`。management API JSON 返回 `armed_at`/`install_at`/`finished_at`，
并在详情中保留最近成功的 `deployed_at`。

`STATE` 是唯一 current lifecycle state。JSON `current` 是 tagged union：

```json
{"kind":"diskless","state":"diskless.running","session_id":"...","plan_digest":"..."}
```

禁止同时输出 `install_state` 和 `diskless_state`。历史不同 kind 只由 trace/events 展示，并明确 session/kind/digest。

## 11. 阶段 9：quarantine 与 retry

```text
nodeforge node retry <node> [--force]
```

- retry 重新启用 deploy 并 rearm PXE generation；`--force` 可超越卡住的 active session。
- v0.2 没有 rootfs delete/GC 命令。

## 12. v0.3+ 命令隔离

- v0.3 才提供 `install-post` canonical 扩展（BIOS PXELINUX 独立延后，见 [`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)）。
- v0.4 才提供多 NIC/VLAN/bonding、临时 PXE rootfs 构建节点和 install first-boot agent。
- v0.5 才提供 `diskless.overlay.mode=ram_rootfs`。

这些字段/enum/handler 不得出现在 v0.2 help 或 parser 中；reconciliation、远程命令、NFS root、iPXE、IPv6
永久没有对应 CLI。

## 13. digest 流转与命令对应

三个 digest 在 CLI 各阶段的使用固定如下，不得混用：

| guard 对象 | 观察命令 | 消费命令 | 可选防漂移 flag |
|---|---|---|---|
| `desired_plan_digest` | `node readiness` | `node deploy true` | — |
| `rootfs_input_digest` | `profile rootfs plan` | `profile rootfs build` | `--if-input-digest` |
| `delivery_digest` | 服务端在允许 bootfile 前原子创建 BootSession/delivery snapshot 时生成 | 不作为 CAS 输入；`node show`/`node trace` 只显示摘要 | — |

正常的人机流程不需要复制 digest：

```text
profile rootfs build <profile>
node readiness <node> --stage boot
node deploy <node> true
```

需要严格“按刚才预览内容执行”的自动化流程才传 guard：

```text
profile rootfs plan <profile>
  -> 输出 rootfs_input_digest=R
profile rootfs build <profile> --if-input-digest R
  -> 构建完成，rootfs ready
node readiness <node> --stage boot
node deploy <node> true
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
