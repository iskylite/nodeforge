# M4.3：安装源与节点模型收口、运行态热更新和可观测性完善

- 日期：2026-07-15
- 状态：设计完成，已实现（代码落地 2026-07-16）
- 前置：M4.2
- 插入位置：`docs/DETAILED_DESIGN.md` §9.12，必须在 M5 前交付
- 目标：修正 M4.2 实机验证暴露出的模型、控制面、会话恢复和可观测性问题，避免这些基础契约继续扩散到 M5–M7

> **M4.4 URL 衔接**：本文出现的 `/subiquity-report`、`/repos/**` 等路径描述 M4.3 需要修复的现有 handler
> 语义；M4.4 将其 canonical URL 分别收口到 `/installer-hooks/subiquity`、`/artifacts/repositories/**`，认证、
> 日志等级和事件语义不变。M4.3 新增的 `/management/profiles[/name]`、nodes/catalog/config/install-sources/
> operations collections 直接采用 M4.4 保留的稳定路径和 v1 DTO，避免刚新增就迁移。完整 URL 与 representation
> 契约见 M4.4 专项设计 §5。

## 1. 结论摘要

本轮反馈共 18 项。逐项对照当前代码后，归并为 10 个可独立验收的工作包：

| 工作包 | 覆盖反馈 | 结论 |
| --- | --- | --- |
| M4.3-01 安装介质身份与幂等导入 | 1、2、4 | `family` 决定 adapter，`distro` 保留真实发行版；repository 可缺省；SHA-256 重复导入幂等；logical id 统一规范；提供只读 catalog 展开和 config/catalog/目录联合事务迁移入口 |
| M4.3-02 安装目录现状验收与文档收口 | 3 | 目录和迁移主体已在 M4.2 落地；M4.3 只补冲突测试、清理残留旧路径并作为 M5 入口门槛 |
| M4.3-03 节点与 profile 聚合视图、SN 回传 | 5、14、补充确认 | `node list/show` 改读 daemon 聚合视图；新增持久化 inventory/facts 和部署时间；提供只读 `profile list/show` 发现 PXE 策略 |
| M4.3-04 CLI 去兼容层与通用属性语法 | 6、13 | 删除 deprecated 子命令；node 变更使用 typed `k=v`/`--unset`，不再每个字段加 flag |
| M4.3-05 TFTP 参数契约与 RFC 收口 | 7 | `max_blksize` 和 timeout option 已实现；不新增伪配置，补范围校验并修正不合规的 blksize/OACK 行为 |
| M4.3-06 请求、PXE gate 与下载可观测性 | 8、9、10、11、16 | 记录具体节点事件；gate 输出明确原因；repo 下载降为 debug；TFTP/HTTP 下载带 node 归属 |
| M4.3-07 Ubuntu webhook 认证修复 | 12 | `/subiquity-report` 使用专用源 IP bootstrap 认证；相关 header 的来源另行诊断，不得让它改变 webhook proof 模式 |
| M4.3-08 daemon-owned ConfigRuntime/ModelRuntime | 15 | node CRUD 进入 daemon；原子写盘后发布不可变 config/catalog snapshot pair，活动 session 固定 owned install plan，区分在线生效与需重启字段 |
| M4.3-09 BootSession 持久化与恢复 | 17 | 在 mode 0600 checkpoint 中持久化可恢复 session 元数据和 capability，daemon 重启后继续接受安装器回调 |
| M4.3-10 构建溯源信息 | 18 | 两个二进制的 `-v/--version` 输出 SemVer、构建时间、git commit 和 dirty 状态 |

M4.3 是基础契约修正，不是功能堆叠。M5 的 rootfs/initrd/boot bundle、M6 的支持矩阵和 M7 的
reconciliation 都会消费这里的发行版身份、节点属性、配置快照和 session 语义，因此不得后移。CLI 只提前
完成已交付 PXE 能力的运维闭环：完整 `node list/show`、只读 `profile list/show`、daemon-owned node mutation、
安装源 `catalog show` 和旧 catalog 的显式迁移。M5–M7 的 rootfs/diskless、profile 写操作及完整
distro/repository CRUD、全配置 diff/apply、
PXELINUX 和 provision/reconcile 命令仍留在各自里程碑，不以“补全 CLI”为由提前扩大范围。

## 2. 当前代码事实与根因

### 2.1 ISO 导入把 family 和 distro 混为一谈

`src/model.zig` 已有正确的两层模型：

- `DistroConfig.name`：真实发行版，如 `rocky`、`centos`、`kylin`；
- `DistroConfig.family`：安装器家族，当前为 `rhel` 或 `ubuntu`；
- `DistroVersionConfig.install_adapter/package_manager`：该版本实际使用的 adapter 和包管理器。

但 `src/catalog/iso_import.zig::detectRockyMedia()` 对所有 `.treeinfo` 白名单项都返回
`distro = "rocky"`，只把原始 family 放进 `source_label`。随后：

- install source、asset、repository 名称都从 `rocky-<version>-<arch>-iso` 派生；
- repository 目录也固定以 `rocky-` 开头；
- repository manager 通过 `distro == "rocky" ? dnf : apt` 推导；
- CentOS、RHEL、Alma、Kylin 等相同版本会与 Rocky 发生逻辑名称冲突。

该问题不只存在于 importer。当前审计还发现 `src/http/server.zig` 的 report/media URL、`src/main.zig` 的 preview
adapter/APT URL、`src/boot/target.zig` 的 kernel cmdline 都直接比较 `source/profile.distro == "ubuntu"`；这些分支
必须与 importer 的 Rocky 判断在同一工作包迁移到 family/version capability，不能只修导入后留下错误运行路径。

这不是显示问题，而是 catalog 身份错误。正确关系应为：

```text
family=rhel  -> kickstart/anaconda + dnf 适配能力
distro=kylin -> Kylin 的真实产品身份
version=V10  -> Kylin 的真实版本
arch=aarch64
```

### 2.2 repository 被错误地当成发行版识别前置条件

`detectRockyMedia()` 当前先取 `.treeinfo repository`，缺省时假设 ISO 根目录，然后立即验证
`repodata/repomd.xml`。只有验证通过后才读取 `family/version/arch`。因此一个 family/版本/架构都合法、
但不携带可直接发布 RPM repository 的 Kylin ISO 会在“识别发行版”前失败。

repository 是 install source 的可选关联对象，不是 ISO 身份字段。检测顺序必须改为：

1. 识别媒体格式和 installer 布局；
2. 解析 family/distro/version/arch；
3. 检测零个、一个或多个 repository；
4. 即使 repository 为零，也发布 ISO、kernel、initrd 和 install source；
5. profile 真正执行安装前，再由 preflight 判断该 source 是否具备该 adapter 所需的安装树。

### 2.3 重复导入目前既不幂等，也不能区分冲突类型

当前默认 source name 只由 `distro/version/arch` 组成。重复导入可能在以下不同位置失败：

- 同文件名：复制 ISO 时 `ImportDestinationExists`；
- 同 tuple、不同文件名：ISO 复制后在 kernel/repository 目录冲突；
- catalog 已有同名对象：发布阶段 `DuplicateObjectName`；
- 同一 ISO 换文件名：不能根据 SHA-256 复用已有对象。

这些错误都没有告诉操作员“已导入同一内容”还是“同名但内容不同”。导入必须以内容摘要和逻辑名称共同判定。

### 2.4 node CLI 仍是离线配置读取器

`node list` 只读取 `config.json`，只显示 ID/MAC/IP/profile。`node show` 也只显示 `NodeConfig`，没有读取已经存在的
`/api/v1/management/nodes/:id/status`，因此看不到 phase、generation、错误、部署时间或 profile 展开结果。

当前没有 SN 回传端点和持久化结构；`node-status.json` 只保存阶段、最后事件时间、错误和 session 状态。
所以“SN 是否有回传存储”的答案是：**目前没有**。

### 2.5 node CRUD 会重启整个 daemon

`src/config/node_mutation.zig` 由 CLI 直接 load/modify/save `config.json`，随后调用
`POST /api/v1/management/config/reload`。daemon 校验磁盘文件后主动退出，依赖 systemd 拉起。

这种方案会同时中断 DHCP/TFTP/HTTP、清空内存 BootSession，并导致安装器回调出现 `SessionInactive`。
node、policy 这类运行时资源变更不应以完整进程重启作为正常路径。

### 2.6 TFTP 配置和协商存在两类问题

反馈中“实际 TftpConfig 只有 windowsize/max_concurrent_transfers”的描述对应较早实现。当前代码已经有
`max_blksize`，`config.example.json` 也已暴露该字段。客户端请求的 RFC 2349 `timeout` option 也已经实现：
接受 1..255，并在 OACK 中原值回显；客户端未请求时使用内部固定默认值 5 秒。

因此 M4.3 **不再新增公开 `timeout_seconds` 配置**。当前没有实测证明需要按部署调整默认重传间隔，增加字段只会
制造新的 restart-required 配置面；以后若压测证明 5 秒不适用，再以独立性能变更加入。仍需补的配置问题是
`max_blksize` 目前只校验下限，必须同时限制到 RFC 2348 的 65464，防止配置值超过传输缓冲边界。

同时当前 `negotiate()` 还有两处需要在同一工作包修正的 RFC 偏差：

- 客户端请求较小 `blksize` 时，服务端把它“升级”为 `max_blksize`；RFC 2348 只允许服务端返回不大于请求值的值；
- 客户端未请求 `blksize`、只请求其他 option 时，服务端主动在 OACK 中增加 `blksize`；严格 RFC 2347 下服务端不应添加未请求 option。

性能优化不能依赖不合规协商。GRUB 性能应通过客户端实际请求的 blksize、TFTP 实测参数或受控 HTTP 路径解决。

### 2.7 TFTP 事件存在，但缺 node_id 导致看起来像“没有 TFTP 事件”

`event_types.zig` 已注册并由 `tftp/server.zig` 写入：

- `tftp.rrq`；
- `tftp.transfer.complete`；
- `tftp.transfer.error`。

kernel/initrd 下载当然属于这些事件。问题是 `emit()` 只写 filename、bytes、client_ip、duration 和可选
`boot_session_id`，没有写 `node_id`。`events list --node` 按 `node_id` 过滤时会隐藏这些事件，造成“只有 DHCP、没有 TFTP”的错觉。

HTTP repository/boot 下载也只记录 client IP，没有统一的节点归属字段。

### 2.8 Ubuntu webhook 的认证注释与实现不一致

Ubuntu adapter 明确不为 curtin webhook 渲染自定义 headers，并注明 `/subiquity-report` 使用源 IP bootstrap 认证。
但 handler 实际调用通用 `auth.authenticate()`：只要请求出现任意 Authorization 或 session header，就切换到
NodeForge bearer 分支。当前 Curtin 实现只有在 OAuth 四元组被配置时才生成 OAuth Authorization；NodeForge
渲染结果没有配置这四项，因此不能仅凭这条日志断言 Authorization 一定由 Curtin OAuth 产生。

能从代码和 `MissingProof` 稳定推出的是：服务端看到了至少一个 authorization/session 相关 header，而当前日志没有
记录安全的“header present/type”诊断，来源可能是具体 Curtin/urllib 版本、代理或其他请求改写。无论来源如何，
generic auth 的自动分流都违反了该路由的源 IP bootstrap 契约。

webhook 路由必须使用专用认证策略，不能让无关 header 改变认证模式。

### 2.9 BootSession 只在内存中

DHCP leases、node status、deployment control 都已持久化，但 `boot_session.Store` 和 capability token 只在内存中。
daemon 重启会：

- 清空活动 session；
- 让恢复的 node status 强制 `session_active=false`；
- 让持有旧 capability 的安装器回调得到 `SessionInactive`；
- 让本来只需要应用 node 配置的 reload 变成安装链路故障。

M4.3 必须恢复“正在进行的交付会话”，但不得借此自动重新 arm 破坏性安装 generation。

## 3. M4.3-01：安装介质身份、可选 repository 与幂等导入

### 3.1 统一媒体检测结果

`DetectedMedia` 改为表达以下事实：

```zig
const DetectedMedia = struct {
    family: model.DistroFamily,
    distro: []const u8,
    version: []const u8,
    arch: model.Arch,
    source_label: ?[]const u8,
    layout: MediaLayout,
    media_tree: ?DetectedMediaTree = null,
    repositories: []const DetectedRepository = &.{},
};
```

其中：

- `family` 决定安装器协议能力，不进入目录名称；
- `distro` 是 config 中真实存在的 `DistroConfig.name`；
- `source_label` 仅用于保留媒体的人类可读标签，不参与身份归一；
- `media_tree` 表示可发布的安装媒体树；它可以存在而 `repositories` 为空，最终写入
  `InstallSourceConfig.media_tree_url`，不能被当作 package repository；
- `repositories` 可以为空；未来允许 BaseOS/AppStream 等多个条目。

`.treeinfo family` 到默认 distro 的归一表集中维护并测试，例如：

| family 前缀 | family | distro |
| --- | --- | --- |
| Rocky | rhel | rocky |
| CentOS | rhel | centos |
| AlmaLinux | rhel | alma |
| Red Hat Enterprise Linux | rhel | rhel |
| Kylin / Kylin Linux Advanced Server | rhel | kylin |
| openEuler | rhel | openeuler |
| TencentOS | rhel | tencentos |
| AnolisOS | rhel | anolis |
| UnionTech/UOS | rhel | uos |
| Sugon OS | rhel | sugon |
| Ubuntu-Server | ubuntu | ubuntu |

映射后的 distro 必须存在于 `AppConfig.distros`，且 tuple 支持当前 version/arch。未知 family 可以通过
`--distro <name>` 指定，但指定项的 `DistroConfig.family/install_adapter` 必须与检测到的媒体布局兼容。
`--distro` 只覆盖产品身份，不能把 Anaconda 媒体伪装成 Ubuntu/Subiquity 媒体。

### 3.2 repository 可选

RHEL-family 检测先解析 family/version/arch 和 kernel/initrd，再独立探测 repository：

- 有 `.treeinfo repository` 时，安全验证该相对路径并探测 `repodata/repomd.xml`；
- 无该字段时，可探测 ISO 根、BaseOS、AppStream 等已知位置；
- 一个都没有时 `repositories=[]`，导入仍成功；
- repository manager 从匹配的 `DistroVersionConfig.package_manager` 读取，不再比较 distro 字符串。

没有 repository 的 install source 在 catalog 中合法。profile 绑定或安装 preflight 必须给出明确诊断，例如
`install_source.repository_missing`，而不是在导入阶段谎称“无法识别发行版”。

Ubuntu 保留“发布 ISO 媒体树以支持 offline-install”的行为，但媒体树和 package repository 必须分开：只有
具备可消费 APT metadata 的树才创建 `RepositoryConfig`；不完整媒体仍通过 install source 的受管
`media_tree_url` 提供给 Subiquity fallback，不伪造“可用 APT repository”。这覆盖 M3/M4.2 中“任何 Ubuntu ISO
都创建 RepositoryConfig”的过渡写法，同时保留隔离网络不回退公网的目标。

以上不是 importer 局部规则。媒体识别完成后，HTTP answer/render、profile preflight、repository manager、
boot target 和 CLI 展示中的 adapter/package-manager 选择，必须只读取 `DistroConfig.family` 与匹配的
`DistroVersionConfig.install_adapter/package_manager`。除集中维护的媒体标签映射表和测试 fixture 外，运行时路由
不得出现 `distro == "rocky"`、`distro == "ubuntu"` 一类产品字符串分派。

### 3.3 名称与目录

默认 logical name 使用真实 distro：

```text
<distro>-<version>-<arch>-<media-kind>
kylin-v10-aarch64-dvd
centos-8.4-x86_64-dvd
rocky-8.4-x86_64-dvd
```

允许 `assets import <iso> name=<logical-name>` 显式区分同 tuple 的 DVD/Minimal/自定义介质。所有 repo、kernel、initrd
目录从 logical name 派生，绝不再把非 Rocky 介质写入 `rocky-*`。

logical name 是持久化 ID、URL segment 和目录名，不是展示标题，必须在 importer、catalog、management API 和
artifact router 之间使用同一套规范：

- canonical 字符集为小写 ASCII `[a-z0-9]`，中间允许 `.`、`_`、`-`，长度 1..128，首尾必须是字母或数字；
- 禁止空白、Unicode、`/`、`\\`、`%`、NUL、`.`、`..` 和任何 percent-encoded 变体；路径层只 percent-decode
  一次，再按同一规则校验，不能在不同层重复 normalize；
- 自动生成名称时，先对 distro/version/media-kind 分别做稳定 slug：转小写、把连续非允许字符折叠为单个 `-`、
  去掉首尾分隔符；任一分量为空或最终冲突时停止并要求显式 `name=`；
- 显式 `name=` 必须已经是 canonical form，服务端不得静默改写后再发布，避免操作者提交值与实际 ID 不一致；
- `source_label`/新增的可选 `display_name` 保存媒体原始大小写和人类可读版本，不能参与路径、唯一键或 plan digest。

因此示例的 canonical ID 为 `kylin-v10-aarch64-dvd`，CLI 可以另外显示 `Kylin V10 aarch64 DVD`。名称比较按
canonical bytes 精确比较；大小写不同不能形成两个对象，也不能依赖底层文件系统是否区分大小写。

升级加载允许旧 catalog 中不符合 grammar 的名称仅作为 `legacy_noncanonical` 迁移输入：它不能被新 profile 引用、
不能创建/覆盖文件，也不能在 M4.3 完成后继续发布。dry-run 对可唯一 slug 且无冲突者生成目录/catalog/profile 联合
rename；多个旧名映射同一 slug、外部 URL 或活动 session 引用时停止。M4.3 验收要求 catalog 中所有受管 logical id
均已 canonical；不能把兼容读取无限保留到 M4.4 router。

### 3.4 重复导入状态机

导入开始时先计算 ISO SHA-256，并在持有 model mutation gate、读取同一 Config/Catalog snapshot pair 的短临界区内做预检：

| 情况 | 行为 |
| --- | --- |
| 同 SHA-256 已存在且关联对象完整 | 幂等成功，返回 `reused=true` 和现有 install source，不复制文件、不改 catalog |
| logical name 已存在且 SHA-256 相同 | 幂等成功 |
| logical name 已存在但 SHA-256 不同 | `409 install_source.name_conflict`，显示 existing/incoming 摘要；不得覆盖 |
| 同 tuple 但不同 logical name/SHA | 允许并存 |
| 上次失败留下无 catalog 引用的 staging | 清理后重试；公共根中的未知文件不得自动删除 |

M4.3 不提供原地 `--replace`。被 profile 引用的 install source 是发布对象，内容变化必须使用新 logical name；
后续显式迁移 profile 后再删除旧对象。

### 3.5 兼容迁移

对 M4.2 已错误归一为 rocky 的对象提供一次性 dry-run 迁移：

- `source_label` 能唯一映射且目标名称无冲突时，生成新 catalog candidate 和目录 rename 计划；
- 无 `source_label`、映射不唯一或目标存在时停止，要求操作员选择；
- 先把文件和两个 JSON candidate 准备到 staging，再通过下述联合事务发布；
- 不从文件名猜 distro。

`InstallSourceConfig.media_tree_url` 是默认 `null` 的向后兼容可选字段，不因字段本身提升 catalog schema version。
迁移器必须另外审计旧 Ubuntu source：若原 `RepositoryConfig` 的 APT metadata 可消费则保留；否则只有在受管
media tree 能安全解析时，才生成“移除伪 repository 引用 + 设置 media_tree_url”的 candidate。profile 引用、
外部 URL 或目录归属有歧义时只报告 dry-run，不自动写回。新增 `node-inventory.json` 和 `boot-sessions.json`
各自带独立 schema version；旧安装不存在文件等价于空状态，不从 events 猜造 inventory/session。

M4.3 同时交付以下最小运维入口，避免操作者只能直接阅读或修改 catalog 文件：

```text
nodeforge catalog show <install-source>
nodeforge catalog migrate --dry-run
nodeforge catalog migrate --apply --plan-digest <sha256>
```

`catalog show` 只读展开真实 distro/family/version/arch、media tree、零到多条 repository、资产 SHA-256 和 profile
反向引用。CLI 必须请求 M4.4 保留的 `GET /api/v1/management/install-sources/:name`；迁移分别请求
`POST /api/v1/management/catalog/migration-plans` 和 `/catalog/migrations`，ISO import 请求
`POST /api/v1/management/install-sources`，不得在 CLI 中直接读写 catalog/config。迁移 apply 和 ISO import 返回
202 Operation，并通过 `GET /api/v1/management/operations/:id` 查询；M4.3 必须直接实现 M4.4 §5 的
Location/Idempotency-Key/operation DTO，M4.4 不再二次改变这些新接口，只迁移历史路由并接入 RouteSpec。

operation/idempotency 索引持久化到 0600 的 `state/operations.json`，terminal 结果至少保留 24 小时且有固定上限；
普通 DTO 不回显本地路径。重启时 queued/running ISO import 先清理/验证 staging，再标记
`failed(operation.interrupted)`，由同 Idempotency-Key 重试创建后继 operation；已经进入 model transaction journal 的
migration 则先恢复联合事务，再把 operation 重建为 succeeded/failed。terminal 结果和 key 映射必须一起 checkpoint，
避免 daemon restart 后同一 key 重复执行副作用；超过保留期后 GET 返回 404，key 方可被安全回收。

`--dry-run` 不写文件，输出对象重命名、目录动作、repository/media-tree 修正、profile 引用变化、当前
`config_revision`、`catalog_revision` 和 plan digest。plan 使用字段顺序稳定的 canonical JSON；digest 覆盖两个
revision、源/目标 logical id、所有 profile patch、源文件 SHA-256、目标不存在证明、目录动作和 candidate JSON 摘要。
任何歧义、活动 BootSession 正在引用待迁移 source/asset，或目标 logical id 非 canonical，都使计划不可应用。

#### 3.5.1 config/catalog/目录联合发布事务

install source 改名必然同时修改 profile 引用，不能把目录、`catalog.json` 和 `config.json` 当成三个独立成功点。
M4.3 新增 daemon 内唯一的 `ModelTransactionCoordinator`，并采用固定锁序：

```text
model mutation gate -> ConfigRuntime writer -> CatalogRuntime writer
```

普通 node/config mutation 和 catalog publish 也必须经过 model mutation gate；任何代码不得反序取锁。耗时的 ISO
hash/copy 在锁外完成到同文件系统 staging，提交阶段才持锁，且不得在锁内执行网络 I/O。

`--apply` 的提交协议如下：

1. 在锁内重新验证 config/catalog revision、全部输入摘要、目标不存在和活动 session 引用；不一致返回
   `409 model.revision_conflict`，无副作用；
2. 为 config/catalog candidate 完成全部分配和交叉校验；把目录和 candidate JSON 写入 staging，逐文件 fsync；
3. 写入并 fsync `state/model-transactions/<plan-digest>.json`（0600），记录 schema、old/new revision、old/new
   JSON 摘要、staging/final 路径和状态 `prepared`，再 fsync parent；
4. 只做可重放的 rename/link 操作，按 `files_ready -> catalog_committed -> config_committed -> complete` 更新并
   fsync journal；原文件/目录保留为事务私有 backup，直到两个 JSON 都提交；
5. 两个磁盘文件成功后，在仍持有 model gate 时一次发布新的 config/catalog snapshot pair，随后才允许新请求读取；
6. 标记 complete 后删除 backup/staging；清理失败只进入 `cleanup_pending`，不能回滚已经公开的模型。

进程崩溃可能发生在任意状态。daemon 启动必须在绑定 DHCP/TFTP/HTTP listener 前扫描 journal：`prepared` 可安全回滚，
`files_ready` 依据已记录摘要回滚或完成，任一 JSON 已 committed 则只允许验证摘要后向前完成；无法证明 old/new 任一
完整状态时以 `model.transaction_recovery_failed` fail closed。恢复完成前不得对外服务。这样运行中读者只看到 all-old
或 all-new，崩溃后也不会以 catalog/config split-brain 启动。

`ConfigRuntime` 和 `CatalogRuntime` 各自使用不可变、引用计数 snapshot；`ModelRuntime.acquire()` 在 model gate
下同时 pin `{config_snapshot, catalog_snapshot, model_revision={config,catalog}}`。profile/node/catalog 聚合查询和
answer/preflight 必须使用这一对 snapshot，不能先后读取两个独立 mutable value。普通单侧更新也通过 coordinator
发布新的 pair。status/inventory 等独立 runtime store 返回自己的 revision，聚合 DTO 携带 revision vector，不伪称
不同事实源具有同一个事务时刻。

不得提供绕过歧义、活动 session、journal 或摘要检查的 `--force`。M6 仍负责 profile/distro/repository 的完整 CRUD
和更丰富的 catalog 管理，但必须复用同一 coordinator、revision pair 和 journal，不实现第二套 writer。

## 4. M4.3-02：资源化安装目录现状验收与文档收口

这项主体已经实现，不应重新排期开发：

- `src/paths.zig` 已定义 `assets/iso|boot|repos|keys|rootfs|initrd|bundles` 和 `state/provisioned`；
- `packaging/install-layout.sh` 已创建新布局、迁移旧目录、改写 config/catalog，并在双边都有数据时 fail closed；
- `tests/install-layout.sh` 已覆盖成功迁移和重复执行幂等；
- 当前 config 默认值和主要运行时代码都使用新路径。

M4.3 只做收尾验收：

1. 增加“双边都有数据”“目标不是目录”“遗留 symlink”测试，明确 fail-closed/清理策略；
2. 清理 M5–M7 现行文档中的旧绝对路径；本次复核已将残留的 provisioned 路径改为
   `/opt/nodeforge/state/provisioned`，历史验证记录可保留并标注时代背景；
3. 运行安装布局测试并把成功结果作为 M5 入口条件；
4. M5 新代码只消费 `paths.zig` 常量，不再实现旧路径兼容分支。

除非上述测试发现真实缺陷，M4.3 不再修改目录模型或重写迁移脚本。

## 5. M4.3-03：节点 inventory、部署状态和完整 show/list

### 5.1 分离 desired、observed 和 inventory

节点信息分为三类，不能全部塞进 `NodeConfig`：

| 类别 | 事实源 | 示例 |
| --- | --- | --- |
| desired config | `config.json` | id、MAC、arch、profile、IP、hostname、deploy、overrides |
| deployment/status | `node-status.json` + `deployment-control.json` | phase、reason、generation、started/completed/applied time、drift |
| observed inventory | 新 `node-inventory.json` | serial number、product UUID、vendor/model、reported_at、source |

新增受 capability 保护的 `POST /api/v1/nodes/:id/facts`。Kickstart `%pre` 和 Ubuntu `early-commands` 在不记录敏感信息的
前提下读取 `/sys/class/dmi/id/product_serial`、`product_uuid`、`sys_vendor`、`product_name` 并上报。
字段需要长度、字符集和 body 大小限制。无 DMI 或固件返回占位值时保存为 null，不把 `To Be Filled By O.E.M.` 当成有效 SN。

inventory 原子写入独立文件，daemon 启动恢复。服务端不接受客户端自报时间作为排序依据：`reported_at` 是 daemon
接受并通过认证的 UTC 时间，同时保存 `deployment_generation`、`boot_session_id`、session 创建序号和 source。
写入仲裁固定为：更高 generation 胜出；同 generation 只接受当前未 superseded session；同一 session 的后到请求
覆盖先到请求。来自旧 generation、已 superseded/terminal session 或不匹配 capability 的迟到事实返回
`409 inventory.stale_source`，记录安全摘要但不得覆盖当前投影。重复提交完全相同的 facts digest 幂等成功且不刷新
`reported_at`。M4.3 不引入常驻 agent；SN 是最近一次被该仲裁规则接受的安装/discovery 环境观测值。

### 5.2 部署时间定义

避免“部署时间”语义含糊，持久化以下时间：

- `deployment_start_at`：generation arm/request 时间，是整个部署任务的 Start；
- `deployment_install_at`：第一次接受 `install.started` 的时间，是安装链路实际开始执行的 Install；
- `deployment_finished_at`：本 generation 首次 terminal 时间；
- `deployed_at`：最近一次成功 `install.completed` 的时间，失败不得覆盖；
- `last_event_at`：最近一次状态事件时间。

这些字段随 generation 一起恢复，重复事件必须幂等，不得刷新首次 install/terminal 时间。

per-generation 语义要求：`rearm` 武装一个新 generation 时更新 `requested_at`（新的 Start），并清零上一 generation 的
`started_at`/`finished_at`（新的 Install/Finished 尚未发生）。`deployed_at` 明确定义为最近一次成功时间，
必须与 `deployed_generation` 一起跨 retry/失败保留，直到下一 generation 成功后才替换。
`consume`/`markTerminal` 在本 generation 内保持幂等，不重复刷新。
`consumed_generation`/`terminal_generation` 作为历史不清零，由后续 consume/markTerminal
为新 generation 覆盖。管理查询的当前代固定为 `armed_generation orelse consumed_generation`；
node status 必须携带并匹配 `model_revision` 与 `deployment_generation`，否则只能作为历史事实，不能
与当前 desired profile 拼成一行。

### 5.3 daemon 聚合查询 API

新增：

```text
GET /api/v1/management/nodes
GET /api/v1/management/nodes/:id
```

返回 desired config、profile 摘要、status、deployment 和 inventory 的一致投影。handler 先通过
`ModelRuntime.acquire()` 同时 pin config/catalog snapshot pair，再在各 runtime store 锁内复制值，释放所有锁后
渲染 JSON，不能持锁执行 I/O。响应必须包含
`view_revision { config, catalog, node_status, deployment, inventory }`；其中 config/catalog 是同一次联合发布的 pair，
runtime store 是带各自 revision 的观察值。实现不得把依次读取多个独立 store 描述成单一线性化事务快照。

`node list` 默认列展示部署开始/结束时间窗口：

```text
ID  MAC  IP  PROFILE  STATUS  START  INSTALL  FINISHED  SN
```

列表 `start_at` 取 deployment_control 的 `requested_at`，`install_at` 取内部 `started_at`/`install.started`，
`finished_at` 来自 per-generation terminal 时间。三者明确区分任务边界与安装阶段；后续 diskless 复用
Start/Finished 任务边界，并为其实际启动阶段定义与 Install 并列的字段，不能重新解释 Start；
成功的 `deployed_at` 与 `finished_at` 重合，作为详情留给 `node show`，列表不再单独列出，
management API JSON 返回 `start_at`/`install_at`/`finished_at`，并在详情中保留最近成功的 `deployed_at`。

所有 CLI human 输出时间统一渲染为 RFC 3339 UTC 可视化时间（复用事件写入器的
`rfc3339FromUnix`），不再直接打印裸 epoch 整数；未发生（0）显示 `-`，旧 `unix:<seconds>`
事件时间戳在展示时同样归一化为 RFC 3339，JSON 输出保留原始机器可读值。

`node show <id>` 分组显示：

1. Node：全部 NodeConfig 字段；
2. Profile：名称、mode、distro/version/arch、install source/boot bundle、safety；
3. Effective system：合并后的 locale/network/SSH/security/users/packages，secret 值默认脱敏；
4. Deployment：generation、revision、drift、Start/Install/Finished 和最近成功 deployed 时间；
5. Runtime：phase、session active、last error/reason；
6. Inventory：SN、UUID、vendor/model、reported time/source；
7. View revisions：config/catalog/status/deployment/inventory 的独立 revision vector。

`--output json` 提供完整稳定结构。密码、capability、private key 永不输出；“完整”指所有非 secret 参数及 secret 的
存在性/来源，不等于把明文密码打印到终端。

### 5.4 profile 发现与完整只读视图

PXE 已经由 node 引用 profile，若只能修改 node 却不能发现和检查 profile，CLI 运维闭环不成立。M4.3 增加：

```text
nodeforge profile list
nodeforge profile show <name>
```

对应只读管理 API：

```text
GET /api/v1/management/profiles
GET /api/v1/management/profiles/:name
```

两者从同一个 `ModelRuntime` config/catalog snapshot pair 生成结果，并返回相同的 model revision。`profile list` 默认显示
`NAME MODE DISTRO VERSION ARCH INSTALL_SOURCE NODES VALID`；`NODES` 是当前引用计数，`VALID` 是当前 config/catalog
关系校验投影，不在 list 时执行昂贵媒体扫描。`profile show` 分组展开全部非 secret ProfileConfig、版本 capability
（adapter/package manager）、install source/media tree/repositories/kernel/initrd、effective system、安全/重装策略、
引用该 profile 的 node id 和当前 validation/preflight 摘要。secret 只显示 configured/source/fingerprint，不能输出值。

M4.3 只提供发现和诊断，不提供 `profile add/update/remove`。M4.6 仅为 `kernel_args` 增加
`profile set <name> 'kernel_args=…'` / `profile unset <name> kernel_args` 的受限 mutation；通用 profile mutation 会影响多个节点的 install plan、drift、
活动 session 保护和引用迁移，仍由 M6 在 ConfigRuntime revision/diff/apply 基础上实现。CLI `node show` 的 profile
部分是摘要并链接/提示 `profile show <name>`，不能替代完整 profile DTO。

## 6. M4.3-04：删除 deprecated CLI 与 typed k=v 属性语法

### 6.1 删除兼容别名

M4.2 已完成命令树迁移，M4.3 删除一个版本周期的 deprecated alias，包括：

- 顶层 `tftp`、`dhcp`、`trace`、`import-iso`、`install-render`、`install-retry`；
- 旧 `runtime leases list`、`runtime unknown list`；
- 其他仅用于输出 `Deprecated: use ...` 的旧路径。

帮助、补全、测试和文档只保留 canonical resource-action 命令。调用旧命令返回标准 unknown-command 错误，
不再 warning 后继续执行。

> **实现状态（2026-07-16）**：`main.zig` 中的 deprecated alias 函数已全部删除
> （`deprecatedAliasCommand`、`deprecatedDhcpCommand`、`deprecatedTftpCommand`、
> `deprecatedRuntimeLeasesCommand`、`deprecatedRuntimeUnknownCommand`）。
> 这些函数此前未被注册到命令树中（已是死代码），删除后旧命令返回标准
> unknown-command 错误。`node add/set/unset` 使用 typed `k=v` variadic 参数已实现。

### 6.2 node 通用属性语法

CLI 改为：

```text
nodeforge node add r97n1 mac=... arch=aarch64 profile=kylin-v10 ip=192.168.27.210
nodeforge node set r97n1 deploy=false hostname=r97n1 overrides.network.mode=static
nodeforge node unset r97n1 hostname overrides.network.gateway
```

不再为每个新字段新增 `--hostname`、`--deploy`、`--http-accel` 等专用 flag。

`k=v` 不是无类型字符串 map。CLI 将键和值编码为 JSON Merge Patch，daemon 以 `NodeConfig` schema 做强类型解析：

- bool/int/enum/IP/MAC/数组都执行原类型校验；
- 未知 key 返回 `node.unknown_attribute`；
- `id` 创建后不可变；
- 清空字段必须使用 `node unset`，避免空字符串和 null 歧义；
- 同一命令重复 key 失败；
- JSON 输出回显 changed field names，不回显 secret value。

API 使用 `POST /management/nodes`、`PATCH /management/nodes/:id`、`DELETE /management/nodes/:id`。
CLI 只是 API 客户端，不拥有字段列表，也不直接修改配置文件。

### 6.3 M4.3 CLI 收口边界

M4.3 只实现当前 PXE OS 部署已经需要、但现有 CLI 无法完整观察或安全操作的表面：

| 资源 | M4.3 必须完成 | 明确保留到后续 |
| --- | --- | --- |
| `node` | 聚合 `list/show`；typed `add/set/unset/remove` | M7 provision/reconciliation 动作 |
| `profile` | 只读 `list/show`，展开 PXE 选择和引用关系 | M6 `add/update/remove/validate` 和复杂 mutation |
| `config` | runtime-applicable allowlist `set` | M6 全配置 `diff/apply` 与复杂对象影响分析 |
| `assets` | `import ... name=`、SHA 幂等和 reused/conflict 结果 | M5 rootfs/initrd/bundle 构建 |
| `catalog` | install source `show`；旧 catalog `migrate --dry-run/--apply` | M6 profile/distro/repository CRUD 和支持矩阵扩展 |
| `runtime` | 现有 `tftp-sessions` 补 node/session/client/result | M5/M7 新运行类型和 agent 状态 |
| version | 两个二进制的构建溯源 | 无新 `version` 子命令 |

不得在 M4.3 新增 `rootfs`、`initrd`、`boot-bundle`、`diskless`、`repository`、`provision`、`reconcile` 顶层资源，
也不得新增 profile 写 action、提前实现远程 TLS/agent 或批量编排。现有命令的正确性与可观测性是 M4.3 完成条件，
后续里程碑的功能数量不是。

## 7. M4.3-05：TFTP 配置契约和 RFC 合规

最终 `TftpConfig` 保持当前三个运行参数，不新增未被实测证明必要的 timeout 配置：

```zig
pub const TftpConfig = struct {
    asset_root: []const u8 = paths.boot_dir,
    max_blksize: u16 = 1468,
    windowsize: u16 = 4,
    max_concurrent_transfers: u8 = 4,
};
```

校验规则：

- `max_blksize`: 8..65464；
- `windowsize`: 0 表示不接受 RFC 7440，其他值 1..65535；
- `max_concurrent_transfers`: 1..64，0 只作为兼容输入归一为 1；
- 这些字段均为 restart-required。

timeout 不是缺失功能：客户端请求 `timeout=N` 时，现有实现已按 RFC 2349 接受 1..255 并原值回显；未请求时
继续使用内部 `default_timeout=5`。M4.3 为这两条路径补显式单元测试，但不把内部常量暴露成配置。

协商规则：

1. 客户端请求 `blksize=N` 时返回 `min(N, max_blksize)`，绝不返回大于 N 的值；
2. 客户端未请求 `blksize` 时保持 512，不在 OACK 中主动增加该 option；
3. 客户端请求 `timeout=N` 时按 RFC 2349 原值回显；未请求时内部重传计时使用固定默认 5 秒；
4. `windowsize` 只在客户端请求时回 OACK，并 clamp 到配置上限；
5. 文件和虚拟 GRUB config 共用同一 Settings/重传实现；
6. 配置示例、概要设计、详细设计和代码字段保持一致。

## 8. M4.3-06：服务日志、PXE gate 和传输归属

### 8.1 具体节点事件日志

通用 `http: request received POST .../events` 保持 debug。完成认证、解析和 schema 校验后增加一条安全的领域日志：

```text
info [nodeforge] node event accepted node=r97n1 stage=packages reason=- session=6d4d...5264
```

只打印 node、stage、稳定 reason 和缩短 session；不打印 token、header、完整 message/body。拒绝时打印 route、node、client、
稳定 auth/error reason，使 401/409 能直接定位。

### 8.2 install_not_armed 严格诊断

`boot.install_not_armed` 事件已有状态转换去重，但缺少服务日志。首次进入 gate 时输出：

```text
warn [nodeforge] PXE withheld node=r97n1 reason=install_not_armed armed_generation=null \
  terminal_generation=1 requested_revision=... desired_revision=... next_action="nodeforge node retry r97n1"
```

`deploy=false`、arch mismatch、profile/source 无效也使用稳定 reason。日志和事件共享同一决策对象，不能各自重新推导。
同一 gate 状态不重复刷屏；重新 arm 后再次进入才记录新一条。

> **实现状态（2026-07-16）**：`dhcp/server.zig` 的 `emitInstallNotArmed()` 已扩展为接收
> `deployments` 和 `desired_revision` 参数，从 `deployment_control.Store.view()` 读取
> `armed_generation`/`terminal_generation`/`requested_revision`，并输出 warn 级服务日志：
> ```
> warn [dhcp] PXE withheld for <node>: install_not_armed (armed_generation=0, terminal_generation=1, requested_revision=0, desired_revision=42)
> ```
> 事件追加 6 个字段：`node_id`、`armed_generation`、`terminal_generation`、`requested_revision`、
> `desired_revision`、`next_action`（固定提示 `nodeforge node retry <node_id>`）。
> 节点未在 deployment store 中登记时使用全零默认值，不暴露 store 内部状态。

### 8.3 repository 下载日志降级

`/repos/**` 的成功 GET/HEAD、Range chunk 和包文件完成日志改为 debug。以下仍为 info/warn：

- repository 首次开始/结束的可选聚合摘要；
- 4xx/5xx；
- 超时、sendfile/磁盘错误；
- 安装 source、answer、boot config、kernel/initrd/rootfs 等控制面或大对象传输。

`http.request` 审计事件保留，并增加 `traffic_class=repository|boot|image|rootfs|api`，生产环境可按 class 查询。

> **实现状态（2026-07-16）**：`http/server.zig` 全部 3 处 `http.request` 事件写入点已增加
> `traffic_class` 字段，按请求路径前缀分类：
> - `/repos/` -> `repository`
> - `/images/` -> `image`
> - `/boot/` -> `boot`
> - `/rootfs/` -> `rootfs`
> - 其他 -> `api`
> 仓库下载成功路径已使用 `log.debug`，控制面和大对象传输仍为 `log.info`。

### 8.4 TFTP/HTTP 下载关联节点

扩展 `boot_session.Link`/传输关联值，成功关联时同时携带 `node_id` 和 `boot_session_id`。TFTP 的三个事件全部增加
`node_id`，因此 `events list --node r97n1` 能看到 grub.cfg、kernel 和 initrd 下载。

HTTP `/boot`、`/images`、`/repos` 请求在开始时按 direct peer IP 关联唯一活动 session，并固定本请求的
`TransferIdentity`。完成时日志和事件写入：

- `node_id`；
- `boot_session_id`；
- `asset`/`filename`；
- bytes/duration/status；
- 无法唯一关联时写稳定 `session_link_state`，绝不猜 node。

示例：

```text
info [tftp] transfer completed node=r97n1 file=install/kylin-v10-aarch64-dvd/initrd.img bytes=...
debug [http] repository object node=r97n1 repo=kylin-v10-aarch64-dvd path=Packages/...rpm status=200
```

## 9. M4.3-07：Ubuntu Subiquity webhook 认证

`/api/v1/nodes/:id/subiquity-report` 不再调用会根据任意 header 自动切换模式的通用 `auth.authenticate()`。
新增专用认证函数：

1. 以 path node id + direct peer IPv4 匹配活动 install BootSession；
2. 验证 peer IP 等于该 session 的 lease IP；
3. 忽略与该路由 proof 契约无关的 Authorization；不预设该 header 一定来自 Curtin；
4. 不信任 `X-Forwarded-For`；
5. 若未来 reporter 明确支持成对的 NodeForge bearer + session header，可作为第二种显式 proof，但部分 header 仍拒绝；
6. 日志记录 `proof=bootstrap_ip`，不记录 OAuth 或 bearer 内容。

必须覆盖以下集成测试：

- 无 Authorization 的合法 webhook -> 200；
- 带无关 `Authorization: OAuth ...` 的合法 peer -> 200（鲁棒性用例，不代表 Curtin 默认会发送）；
- 错误 peer IP -> 403；
- 无活动/已过期 session -> 409 `session_inactive`；
- 合法事件映射到 partitioning/packages/bootloader/completed/failed；
- webhook FAIL 后带 bearer 的 `/logs` 仍可提交 traceback。

## 10. M4.3-08：daemon-owned ConfigRuntime 和在线 node CRUD

### 10.1 所有权

`RouteContext.config` 从 `*const AppConfig` 改为 `*ConfigRuntime`，同时由 `ModelRuntime` 协调 config/catalog
联合发布。ConfigRuntime 持有不可变、引用计数的 `ConfigSnapshot { value, revision, allocator/arena }`，
CatalogRuntime 使用对称的 `CatalogSnapshot`，不能继续暴露可变 `catalog.value` 给 handler。读取方：

1. 在短锁内 acquire 当前 snapshot；
2. 释放锁；
3. 使用 snapshot 执行业务和 I/O；
4. release；最后一个引用释放旧 generation。

不能只在锁内取 slice 后解锁，因为 replace 后旧 arena 可能释放；也不能为简单起见永远保留所有旧快照。

只需要 config 的短请求可以 pin ConfigSnapshot；会解析 profile/install source/asset 的协议决策必须 pin 同一个
`ModelSnapshotPair`。生命周期可能跨越 config replace 的对象不得借用 snapshot 中的
slice：`BootSession`、持久 store、事件队列和异步 worker DTO 必须深拷贝并拥有其 node_id/profile/MAC/IP 等身份值。
`BootSession` 记录创建时的 model revision 和 normalized install plan/digest 用于稳定交付、drift/受保护字段检查，
但不为了最长两小时 session 固定整个 `ConfigSnapshot`，否则旧 arena 无法及时回收。spawn worker 之前必须选择“worker 持有
snapshot 引用直到结束”或“复制完整 owned DTO”之一，禁止只复制 slice 指针。

### 10.1.1 BootSession 的不可变安装计划

当 install generation 通过 gate 并创建 delivery session 时，服务端使用同一个 model snapshot pair 编译完全 owned 的
`InstallPlanSnapshot`。它至少包含：node identity/hostname/network、profile/mode、family/distro/version/arch 与
adapter capability、effective system/users/packages/storage、install source/media tree/repository、kernel/initrd/boot
asset logical id + SHA-256，以及生成 answer 所需的非 token 输入。计划使用 canonical JSON 计算 `plan_digest`。

BootConfig、Kickstart、NoCloud 和后续同 session 的配置请求只能读取该 plan，不能再次从最新 config/catalog 解析。
服务地址和当前里程碑 URL 集合作为明确的 delivery context 输入，不允许借“重新渲染 URL”切换计划语义。capability
明文、SSH private key 不进入 plan；配置中本来就以明文保存且 answer 必需的 password 可能出现在 0600 plan checkpoint，
但不得写日志、event 或普通查询 DTO。derived password hash 若需跨重启稳定，salt/scope 必须由 session 自有字段派生，
不能使用会随 daemon restart 变化的 instance id。

desired config 可以在 session 期间修改 hostname/overrides 等 runtime-applicable 字段，但只影响下一次 session，并在
deployment view 标记 `plan_drift=true`；当前 session 仍返回原 plan。若修改 MAC/profile/arch/IP、删除 node，或迁移/
删除当前 plan 引用的 source/asset，则因身份或可交付制品无法保持而返回稳定 409。terminal/expiry 后 plan 随 session
checkpoint 删除。这样既允许在线维护 desired state，也不会让安装器在同一次安装中收到两套答案。

### 10.2 mutation 事务

node POST/PATCH/DELETE 在 daemon 内执行：

```text
acquire current snapshot
-> apply typed patch to fully owned candidate（所有字符串/嵌套 slice 深拷贝）
-> validateConfig + validate(config, catalog)
-> classify diff
-> tmp write + fsync(file) + rename + fsync(parent dir)
-> publish new in-memory snapshot/revision
-> emit config.updated（只含 changed paths/revision）
```

写盘成功、内存发布失败必须被设计为不可发生：publish 所需分配在写盘前完成。并发 mutation 使用 revision/ETag；
过期 `If-Match` 返回 `409 config.revision_conflict`，防止 lost update。

### 10.3 在线生效与需重启分类

M4.3 分类：

| 变更 | 分类 | 说明 |
| --- | --- | --- |
| node add/set/remove、deploy、hostname、overrides | runtime-applicable | 无活动 session 时下一协议决策读新 snapshot；活动 session 固定旧 plan、只标 drift |
| discovery policy | runtime-applicable | 下一次未知节点请求生效 |
| logging level、events rotation | runtime-applicable | 调用对应 runtime reconfigure |
| server bind IP/interface/HTTP port | restart-required | listener/socket 结构变化 |
| DHCP subnet/pool、TFTP/HTTP asset roots、TFTP 参数 | restart-required | 协议状态或 worker 配置变化 |
| distro/profile 安装计划 | M4.3 默认 restart-required | M6 config diff/apply 再开放；不得隐式 rearm |

在线 API 遇到 restart-required path 返回 `409 config.restart_required` 和字段列表，不修改磁盘。全量 `config import/apply`
可以写入后明确要求重启，但不能声称即时生效。

M4.3 同时提供窄范围的 `config set <typed k=v...>`，首批只允许 discovery policy、logging level 和 events
rotation 等已实现 runtime reconfigure 的路径。它必须复用 §10.2 的 revision/If-Match、深拷贝、全量校验、
持久化和 snapshot publish 事务；遇到结构字段整个请求无副作用并返回 `config.restart_required`。M6 的完整
`config diff/apply` 在同一机制上扩展复杂对象和影响分析，不得创建第二个 store 或 writer。

### 10.4 运行中安全规则

- 有活动 install session 时，禁止删除节点或修改其 MAC/profile/arch/IP；禁止迁移/删除其 plan 引用的 source/asset；
- `deploy=false` 只阻止新的 PXE，不中断已经进入安装器的 delivery session；
- hostname/overrides 等影响 install plan 的 desired 变更只标记 drift，不自动 arm generation，也不改变当前 session plan；
- 新增 install 节点可 `ensureInitial` generation 1；删除节点同时清理无活动的 gate cache，但保留审计历史；
- handler 不持 ConfigRuntime/Store 锁执行磁盘或网络 I/O。
- 活动 session 的受保护身份由 session 自有副本判定；相关 node/profile mutation 返回稳定冲突，不得让 replace 后
  的 session 读取悬空字符串或悄悄切换到新 profile。

## 11. M4.3-09：BootSession 持久化和 resume cache

新增 `state/boot-sessions.json`（0600，原子写入），只保存仍在 TTL 内、可恢复的活动 session：

- boot_session_id、node_id、profile、mode、MAC、lease IP；
- phase、created_at、last_seen_at、capability_issued；
- capability token（checkpoint 必须为 mode 0600，且不得进入普通查询、日志或事件）；
- captured model revision、owned normalized install plan 及 plan digest；
- schema version。

上述 node_id/profile 等字符串和所有嵌套值都是 store/session 自有数据；恢复和新建路径使用同一深拷贝 helper，
不得保存 `AppConfig`/`ConfigSnapshot` arena 的借用 slice。checkpoint 只序列化这份 owned state。由于 plan 可能包含
与 `config.json` 同级的敏感安装输入，文件和 parent 目录权限必须为 0600/0700，JSON export、node/profile show 和
诊断 bundle 均不得包含 plan body，只显示 digest/revision/drift。

### 11.1 时间恢复

磁盘只保存 UTC 时间。启动时用 `now_utc - last_seen_at` 计算已消耗 TTL，再将剩余时间重建为本进程单调时钟 deadline。
系统时钟回拨时 fail closed；剩余 TTL 不得超过原类别上限。恢复项必须同时满足：

- node 仍存在且 MAC/IP 身份兼容；
- profile/mode 仍可识别；
- 对应 DHCP lease 尚未过期，或 session 已进入 capability delivery 阶段；
- 未 terminal；
- 当前 config/catalog 仍能提供 plan 中所有 immutable asset SHA；config revision 变化未触及受保护身份字段。hostname/
  overrides 等 desired drift 不阻止恢复，因为恢复后继续使用 checkpoint 中的旧 plan；source/asset 缺失或摘要变化
  必须以 `boot.session.resume_asset_mismatch` fail closed。

### 11.2 capability 恢复

token 是高熵随机值，随 session 写入 mode 0600 checkpoint；Store 仍使用恒定时间比较。
恢复后节点重新获取 `/config` 时继续返回同一 token，避免旧/new answer 并发回调互相失效。terminal 或过期时立即删除 token 并 checkpoint。

### 11.3 重启边界

- daemon shutdown 不再无条件把可恢复 delivery session 标为 terminated；先 checkpoint 并写
  `boot.session.suspended(reason=daemon_restart)`；
- 新实例恢复后写 `boot.session.resumed`，包含旧 session id 和新 daemon_instance_id；
- session resume 只恢复 HTTP capability、不可变 install plan 和用于关联后续重新发起传输的 session 元数据；不恢复
  已中断的 TFTP UDP transfer/TID，也绝不恢复或创建 `armed_generation`；
- 无法恢复的项写稳定 reason 后失效；
- node status 的 `session_active` 按实际恢复结果设置，不再一律 false。

## 12. M4.3-10：构建时间和 git 信息注入

`build.zig` 生成两个二进制共享的 build-options module：

```zig
pub const version = "0.1.0";
pub const git_commit = "a54afabd6501";
pub const git_dirty = false;
pub const build_time = "2026-07-15T03:27:00Z";
```

规则：

- commit 使用完整 SHA 存储、默认显示 12 位；
- dirty 来自构建时 worktree，但发布构建应要求 clean；
- build time 优先使用 `SOURCE_DATE_EPOCH`，保证可复现构建；未设置时使用当前 UTC；
- 源码包或无 git 环境允许显式 `-Dgit-commit=`/`-Dbuild-time=`，缺省显示 `unknown`；
- 不注入构建用户名、hostname、绝对路径或 remote URL。

输出统一为：

```text
nodeforge 0.1.0 (commit a54afabd6501, built 2026-07-15T03:27:00Z, clean)
nodeforged 0.1.0 (commit a54afabd6501, built 2026-07-15T03:27:00Z, clean)
```

## 13. 与既有里程碑的冲突和处理规则

M4.3 是对已实现链路的实机复核，不是与旧设计并列的另一种可选方案。处理优先级固定为：

1. 仍在生效的总设计章节必须就地改写或增加明确的 M4.3 supersession；
2. M4.1/M4.2 规格和实机验证记录保留当时原文，但顶部标注“历史结果/已被覆盖”，不能继续作为新实现依据；
3. 涉及 catalog/config/state 的变化必须提供显式 schema 迁移、dry-run 和 fail-closed 冲突处理；
4. 后续 M5–M7 只能继承 M4.3 新契约，不得以“旧里程碑曾这样设计”为由恢复过渡实现。

| 冲突面 | 旧里程碑/章节 | M4.3 最终契约 | 处理方式 |
| --- | --- | --- | --- |
| family 与 distro | M4.2 F3 把 RHEL-family 全部归一为 Rocky，M6 按 `source_label` 区分 | family 选 adapter，distro 保留真实产品身份 | M4.2 原文保留为历史；catalog/目录做可审计 dry-run rename，歧义停止；M6 能力表按 family 复用、按 distro/version 验证 |
| repository 与媒体身份 | M3/M4.2 部分段落把 repodata 或 `RepositoryConfig` 当作导入成功条件 | 先识别/发布 install media，repository 是零个或多个派生能力 | RHEL-family 仅在有效 repomd 时建 repo；Ubuntu 可继续发布媒体树，但不完整 APT 树不伪装成可用 package repo，offline fallback 通过 install-source media URL 表达 |
| 重复导入 | M3/M4.2/历史实测把 NoClobber/duplicate error 当作正确结果 | 同 SHA + 同 logical name 幂等复用；同名不同 SHA 冲突 | 历史验证不改写；新增返回状态和 SHA 索引，禁止原地覆盖 |
| NodeFacts/SN | 总模型已有 `NodeFacts`/`node.serial_number`，但当前代码没有持久回传 | `node-inventory.json` 保存非 secret observed facts；`node.serial_number` 是管理员确认的 desired 值 | 不建第二套概念；实现既有模型的持久投影。observed/desired 不自动互相覆盖，冲突在 `node show` 标记；IPMI 密码不得进入 inventory |
| node list/show 与 M7 status | M2 的 list 只读 config；M7 计划提供 provisioning plan/status | M4.3 提供节点聚合事实视图；M7 只增加 step/reconciliation 计划和结果 | `node list/show` 不后移到 M7；M7 的 `provision plan/status` 作为其子视图，不复制 node 基础 DTO |
| profile CLI 与 M6 CRUD | 旧规划把 profile 的所有 CLI 都留到 M6，导致当前 PXE profile 无法通过 CLI 发现 | M4.3 提前只读 `profile list/show`；M6 保留 add/update/remove/validate | M4.3 API 只读同一 ConfigRuntime snapshot/catalog revision；不提前 profile mutation、drift apply 或引用迁移 |
| node mutation 与 M6 config apply | M4.2 CLI 直写 + reload；M6 原计划才引入 snapshot apply | M4.3 先交付 ConfigRuntime、node CRUD 和 allowlist `config set` 在线 mutation | M6 继承同一 snapshot/revision，扩展全配置 diff/apply；不得再实现第二套 snapshot 或把 node CRUD退回重启 |
| CLI flags 与兼容 alias | M4.2 每字段 flag，并承诺 alias 保留一个版本周期 | typed `k=v`/`unset`；M4.3 删除已完成兼容窗口的 aliases | M4.2 命令例只作历史；现行帮助、测试、M5–M7 全用 canonical form；脚本升级失败应显式暴露 unknown command |
| catalog CLI 与 M6 边界 | M4.2 把 `catalog show` 全部留到 M6，且迁移器没有明确操作入口 | M4.3 提前只读 install-source `show` 和带 plan digest 的迁移 plan/apply | 这是修复既有 catalog 数据的必要运维闭环；M6 仍拥有 profile/distro/repository CRUD、完整支持矩阵和复杂 catalog 管理 |
| TFTP 参数与 RFC | M4.2 用主动/放大 blksize 换吞吐；旧设计提到未实现的 timeout 配置 | 三个公开参数；timeout option 已实现；OACK 只回请求项且 blksize 不放大 | 删除伪 `timeout_seconds` 待办；修 RFC 行为和 65464 上限；性能优化转到客户端请求、windowsize 或受控 HTTP |
| TFTP/HTTP 日志等级 | M2.5/M3 要求每个 HTTP 成功请求 info；TFTP 仅带 session | `/repos/**` 成功包请求 debug；关联成功的传输带 node_id | route-class 覆盖通用 access log 等级；错误仍为 info/warn。TFTP 唯一 lease/session 关联时反规范化 node_id，否则写 link failure |
| Subiquity webhook proof | M4.2 文档写源 IP proof，handler 却复用 header 自动分流 | webhook 固定 direct peer + active install lease proof | 不信任 header 改变 proof；header 来源单独诊断。`/events`、`/logs` 继续使用 capability，不放宽 |
| BootSession 重启语义 | M2.5.1/M3 明确仅进程内、重启 token 必失效 | 只恢复已签发 capability 的 active delivery session，在 mode 0600 checkpoint 保存 token，不恢复早期 DHCP/TFTP socket 状态或 install arm | 原章节就地加 supersession；trace 仍显示 daemon instance 边界。恢复失败/过期才标 inactive，重启本身不是 SessionInactive 理由 |
| 资源目录 | M4.2 已实现新布局，原计划可能被误读为 M4.3 重新开发 | M4.2 实现为基线，M4.3 只做边界测试/文档收尾 | 不重写迁移器；M5–M7 只用 `paths.zig`，旧路径仅保留在历史迁移说明 |
| 版本输出 | M0 只要求 `nodeforge -v` 和静态版本 | CLI/daemon 都输出 SemVer + build time + git commit + dirty | M4.3 覆盖 M0 通用 CLI 限定；保持 `-v/--version` 顶层参数，不新增 version 子命令 |

上述覆盖不改变两个安全边界：恢复 BootSession 不等于恢复 TFTP UDP transfer，也不重新 arm 安装；在线
ConfigRuntime 不等于所有字段都热生效，bind/port/root/TFTP 参数仍返回 restart-required。

## 14. 对 M5–M7 的强制影响

| M4.3 契约 | 后续影响 |
| --- | --- |
| family 与真实 distro 分离 | M5 bundle tuple、M6 支持矩阵和所有目录名必须使用真实 distro；adapter 按 family/capability 选择 |
| repository 可空/多条 | M5/M6 preflight 不能假设 install source 恰有一条 repo |
| 内容幂等导入 | rootfs/initrd/boot bundle 发布复用同一 SHA + logical name 冲突模型 |
| node inventory/status 聚合 API | M5 diskless 状态和 M7 reconciliation 扩展同一 node view，不新增平行 show 命令 |
| profile 只读聚合 API | M5/M6 扩展同一 profile DTO 的 bundle/capability 和 mutation 字段，不新建第二套 profile show |
| typed k=v + daemon-owned CRUD | M6 profile/distro/repo CRUD 复用 patch/revision/ConfigRuntime，不得 CLI 直写文件 |
| ConfigSnapshot pinning | DHCP/TFTP/HTTP/M5 worker 都必须 acquire/release，不得借用 replace 后悬空 slice |
| 长生命周期状态所有权 | BootSession/store/队列拥有身份字段，只记录 config revision/digest；M5–M7 不得以长时间 pin 整个 snapshot 代替深拷贝 |
| session resume | M5 installer/diskless delivery 可复用 hash/TTL/checkpoint 基础设施；M7 agent/finalizer 必须使用独立 enrollment/credential namespace，只复用持久化模式，不复用 installer token |
| 传输 node 归属 | M5 rootfs/initrd、M6 PXELINUX 下载事件必须带 node_id 或明确 link failure |
| deprecated alias 删除 | 后续文档、脚本、测试只能使用 canonical CLI |
| M4.4 URL 接口 | M4.3 生成器仍输出本阶段 URL；M4.4 以开发期 breaking cutover 直接替换全部 URL，不提供 alias 或旧 session loader。切换前必须结束活动安装并显式清理 M4.3 checkpoint；切换后重新创建的 session 使用最新 canonical URL，不改变本章 auth、generation、ModelRuntime、immutable plan 和事件语义 |

## 15. 文件变更范围

| 文件/模块 | 主要变更 |
| --- | --- |
| `src/model.zig` | node inventory/status DTO；`InstallSourceConfig.media_tree_url`；媒体检测能力字段；TFTP 不新增 timeout 字段 |
| `src/catalog/iso_import.zig`、`src/catalog.zig` | family/distro 分离、可空/多 repo、logical name、SHA 幂等预检；删除运行时产品字符串分派 |
| `src/boot/target.zig`、`src/profile/adapter/*.zig` | 根据版本 capability 生成 cmdline/answer/facts，不按产品字符串选择 adapter |
| `src/state/catalog_runtime.zig` | 不可变 CatalogSnapshot、revision、按 SHA/name 查重并返回 reused/conflict；迁移候选发布 |
| `src/state/model_runtime.zig`（新） | config/catalog snapshot pair、固定锁序、联合发布和聚合读取 revision vector |
| `src/catalog/migration.zig`（新） | 可复现迁移 plan、config+catalog revision/digest 校验、journal、dry-run/apply 和 crash recovery |
| `src/state/config_runtime.zig`（新） | 不可变 snapshot、引用计数、revision、replace/diff 分类 |
| `src/config/node_mutation.zig` | 删除 CLI writer 职责；保留/迁移为 daemon 内 typed patch helper |
| `src/state/node_inventory.zig`（新） | SN/UUID/vendor/model 投影和原子持久化 |
| `src/state/node_status.zig` | `last_event_at`/phase + model revision/deployment generation 来源归属 |
| `src/state/deployment_control.zig` | 当前代 requested/started/finished；最近成功 deployed generation/time 跨 retry 保留 |
| `src/state/boot_session.zig` | owned node/profile 身份与 InstallPlanSnapshot、node-aware Link、capability checkpoint/restore、resume |
| `src/state/operations.zig`（新） | ISO import/catalog migration 长任务、Idempotency-Key 去重、有限保留和 operation 查询 |
| `src/http/server.zig` | node CRUD/聚合 API、profile list/show、facts、webhook 专用认证、日志分级、HTTP 传输关联 |
| `src/http/auth.zig` | webhook bootstrap proof；capability 恒定时间验证 |
| `src/tftp/server.zig` | RFC 合规协商、timeout 现状回归测试、node_id 事件/日志 |
| `src/dhcp/server.zig` | gate 决策日志与 deployment 字段 |
| `src/main.zig`、`src/http/client.zig` | 删除 deprecated 命令；k=v/unset；node/profile 聚合 list/show；catalog show/migrate 客户端；CLI 时间统一渲染为 RFC 3339 可视化时间 |
| `src/cli/views.zig` | 新 node/profile list 列和完整 show 分组；`formatTimestamp` 可视化时间；node list 增 START/INSTALL/FINISHED 列 |
| `src/cli/events.zig` | `displayTs` 把旧 `unix:<seconds>` 事件时间归一化为 RFC 3339 展示 |
| `src/version.zig`、`build.zig` | build-options 注入和统一版本输出 |
| `src/paths.zig`、`packaging/install-layout.sh` | 原则上无需改动；只在新增迁移边界测试发现缺陷时修正 |
| `config.example.json` | 保持现有 TFTP 字段，更新真实 distro 示例 |
| `tests/*.sh`、fixtures | 10 个工作包的 CLI/HTTP/迁移/重启集成测试 |

## 16. M4.3 总验收标准

1. 无 `repository` 的 Kylin `.treeinfo` 仍能识别 `distro=kylin` 并导入 ISO/kernel/initrd；catalog repo 列表可空。
2. Rocky 8.4、CentOS 8.4 同时导入后拥有不同 logical name、目录和 catalog tuple，均不被归一成对方。
3. 同一 SHA-256 ISO 重复导入返回幂等成功且不复制；同名不同 SHA 返回稳定 409；不同 name 可并存。
4. 已有目录迁移通过成功/幂等回归，并新增双边有数据、非目录和 symlink 边界测试；现行 M5–M7 文档不再引用旧路径。
5. installer/discovery 上报 SN 后重启 daemon，`node list` 显示 SN、状态和 started/finished（RFC 3339）；无 SN 显示 `-`。
6. `node show` 同时显示完整 node、profile/effective system、status、deployment 和 inventory；secret 默认脱敏。
7. 所有 deprecated alias 从 help 和命令树删除；旧 `nodeforge tftp ...` 返回 unknown command。
8. `node set r97n1 deploy=false hostname=r97n1` 一次原子修改；未知/错类型 key 失败且旧配置不变。
9. node CRUD 通过 daemon API 即时生效，不停止 DHCP/TFTP/HTTP，不改变 daemon_instance_id；server port 修改返回 restart-required。
10. TFTP `max_blksize/windowsize/max_concurrent_transfers` 均被解析、校验和使用，`max_blksize` 上限为 65464；timeout 请求原值回显、缺省使用内部 5 秒；OACK 不增加未请求 option、不把 blksize 调大。
11. `POST /events` 成功日志含 node/stage/reason；不含 token/body。未 arm PXE 的单条日志明确给出 gate 状态和 next action。
12. `/repos/**` 成功下载在 info 级别不刷屏；debug 可见包路径；4xx/5xx 仍在 info/warn。
13. `events list --node r97n1` 能看到 DHCP、TFTP grub/kernel/initrd、HTTP 和 installer 事件；每条传输有 node_id 或 link failure reason。
14. Ubuntu webhook 在无认证 header 和存在无关 Authorization 两种情况下都只按合法 direct peer + 活动 session 认证；错误 peer 被拒绝，并记录不含 header 值的安全诊断。
15. 安装进行中重启 daemon 后，旧 capability 能继续提交 event/log，node status 恢复 active；未自动 arm 新 generation。
16. `nodeforge -v` 与 `nodeforged -v` 同时包含版本、build time、git commit 和 clean/dirty；`SOURCE_DATE_EPOCH` 构建结果稳定。
17. `catalog show` 能展开 install source 全关系；迁移 dry-run 无写入，apply 只接受未过期的同 config/catalog revision
    与 plan digest；profile 引用、目录和两个 JSON 通过 journal 联合发布。逐状态 crash injection 后启动只得到 all-old 或
    all-new，歧义、活动 session 引用和并发变化均 fail closed。
18. 运行时 adapter/package-manager/repository/boot 路由不按 `rocky`/`ubuntu` 产品字符串分支；集中映射表之外的审计测试通过。
19. 连续 config/catalog replace 与 session/worker 并发压力测试无 UAF、状态串扰、torn snapshot pair 或旧 snapshot
    无界滞留；活动 session 的受保护 mutation 被明确拒绝，hostname/overrides 更新只形成 drift，重复请求 answer 的
    plan digest 和内容保持不变。
20. `tests/cli.sh`、`tests/http.sh` 等现行测试只调用 canonical 命令；版本断言匹配 provenance 格式；重启用例区分 `resumed` 与真正的 `daemon_restart_gap`。
21. `zig build test`、CLI/HTTP 集成测试和目录迁移测试全部通过；并在 M4.3 最终代码上重新完成 Rocky 9.7、Ubuntu 22.04 的完整 PXE 安装至可登录，以及 Ubuntu 安装中重启 daemon 后旧回调恢复并完成，且没有自动 rearm generation。M4/M4.1 的历史成功记录不能替代本次回归。
22. `profile list` 能发现所有当前 profile、引用节点数和校验状态；`profile show` 展开 PXE 所需的 profile/capability/install-source/repository/资产/effective system，JSON 稳定且 secret 脱敏；M4.3 不出现 profile 写 action。
23. logical name 的 importer/API/router 使用同一 canonical grammar；大小写、Unicode、encoded slash、dot segment、超长
    ID 和 slug collision 均在落盘前被稳定拒绝，display label 不参与路径和 digest。
24. 旧 generation/session 的迟到 facts 返回 `inventory.stale_source` 且不能覆盖新 SN；相同 facts 重试幂等且不刷新
    reported_at；聚合响应携带 config/catalog/status/deployment/inventory revision vector。
25. `boot-sessions.json` 中 M4.3 session 带 owned plan 和 digest；M4.3 同版本重启后 Kickstart/NoCloud 内容保持一致，
    缺失/变更 asset 时 fail closed，且不声称恢复已中断的 TFTP UDP transfer。M4.4 切换不承诺恢复这些旧 session。
26. migration/import 返回 durable Operation；同 Idempotency-Key 不重复执行，daemon restart 后 terminal 结果仍可查询，
    running import 稳定标记 interrupted，已 journaled migration 按 all-old/all-new 恢复结果重建状态。

## 17. 逐条反馈覆盖表

| # | 落点 |
| --- | --- |
| 1 | §3.2：repository 可空，发行版识别先于 repo 探测 |
| 2 | §3.1/§3.3：family 与 distro 分离，目录使用真实 distro |
| 3 | §4：确认目录主体已在 M4.2 实现；M4.3 只补迁移边界测试和文档收尾，作为 M5 前硬门槛 |
| 4 | §3.4：SHA + logical name 幂等/冲突状态机 |
| 5 | §5：list 增加部署时间/状态/SN，新增 SN 回传持久化 |
| 6 | §6.1：删除 tftp 等 deprecated 子命令 |
| 7 | §7：确认 max_blksize 和 timeout option 已实现；不新增 timeout 配置，只补范围校验和修正 RFC 偏差 |
| 8 | §8.1：成功解析后打印具体 node event |
| 9 | §8.2：install_not_armed 输出 gate/generation/next action 且去重 |
| 10 | §8.3：apt/yum repository 成功下载日志降 debug |
| 11 | §2.7/§8.4：TFTP 事件已存在，补 node_id 后可按 node 看到 kernel/initrd |
| 12 | §9：webhook 专用源 IP认证，修复 MissingProof |
| 13 | §6.2：typed k=v 和 unset，不再为每个字段加 flag |
| 14 | §5.3：node show 展开完整 node/profile/effective/status/deployment/inventory |
| 15 | §10：ConfigRuntime + daemon-owned CRUD + runtime/restart 分类 |
| 16 | §8.4：TFTP/HTTP 下载日志和事件显示节点 |
| 17 | §11：session/capability 的 mode 0600 持久化与 resume |
| 18 | §12：构建时间/git commit 注入版本输出 |

## 18. 本轮补充确认覆盖

| 确认项 | M4.3 决策 |
| --- | --- |
| 当前 CLI 还有哪些未实现功能需要提前 | 提前 §6.3 所列既有 PXE 运维闭环，包括只读 `profile list/show`；不提前 profile 写操作及 M5–M7 功能型命令 |
| 前述里程碑已有实现发生变化时如何处理 | M4.3 规格必须驱动实际代码迁移，不是只改文档；历史规格保留 supersession，现行代码/测试/示例全部改用新契约 |
| 基于 M4.3 能否达到计划目标 | 可以，但必须同时关闭全局 distro 分派、ConfigRuntime/BootSession 所有权、现行测试升级和双发行版实机回归；任一缺失都不能把 M4.3 标记完成 |
| 资源目录是否继续后移 | 不后移；既有迁移实现作为基线，M4.3 完成边界测试、旧引用清理和 M5 入口验收 |
