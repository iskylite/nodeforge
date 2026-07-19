# M4.12 Node/Profile 属性归属与存储覆盖设计

## 目标

M4.12 解决节点硬件事实、节点局部配置和 profile 部署策略混放的问题。设计必须覆盖模型、校验、渲染、持久化、HTTP API、CLI `show/set/unset`、帮助文本、迁移和后续 M5–M7 的接口边界。

本里程碑先冻结设计和兼容契约，不改变 M4.11 已交付的主体行为。

## 归属原则

* 节点属性：单台机器的身份、发现事实或物理设备差异；不能因修改一台机器而改变其他节点。
* profile 属性：可被多个节点复用的部署能力、安装策略和目标系统策略。
* 节点 override：profile 默认值之上的单节点例外；必须显式显示 owner 和 effective value。
* 派生属性：由多个字段计算或由运行时观察得到，只读，不能伪装成可 `set` 的直接 key。

## 属性盘点

| 属性 | 归属 | 可写性 | 说明 |
|---|---|---|---|
| `node.id/mac/ip/hostname/arch` | node | 按现有命令 | 节点身份、匹配和发现事实 |
| `node.deploy/http_accel` | node | 按现有命令 | 节点运行开关 |
| `node.overrides.network.*` | node override | 按现有命令 | 静态网络只属于单节点 |
| `node.overrides.storage.boot_disk` | node override | M4.12 新增 | 实际目标设备路径；优先于 profile 默认值 |
| `node.overrides.storage.install_disks` | node override | M4.12 新增/可选 | 仅多盘安装时覆盖 profile 策略 |
| `node.overrides.storage.boot_mode` | node override（可选） | 需事实来源后启用 | UEFI/BIOS 节点差异，不直接假定可探测 |
| `node.overrides.storage.partition_table` | node override（可选） | 需联合校验 | 必须与 boot mode/partitions 一致 |
| `profile.mode/distro/version/arch` | profile | 只读或按现有策略 | 部署能力边界 |
| `profile.install_source/boot_bundle` | profile/catalog | catalog mutation | 共享安装输入 |
| `profile.install.storage.wipe/partitions/bootloader` | profile | profile set | 共享安装策略 |
| `profile.install.storage.boot_disk` | profile 默认值 | 兼容保留 | 未设置 node override 时的 fallback；后续可弃用 |
| `profile.install.storage.install_disks` | profile 默认值 | profile set | 默认参与安装的磁盘集合 |
| `profile.kernel_args` | profile | profile set | 部署能力参数；硬件 quirks 需另建 profile，不允许 node 随意覆盖 |
| `effective_*`、计数、状态、校验结果 | 派生 | 只读 | 不注册为 settable key |

## Effective 合并规则

`effective storage` 按 `node override > profile default > schema default` 合并。合并后执行现有 storage 联合校验；校验失败时不得渲染、不生成新的 desired digest，也不得影响其他节点。

旧配置只含 profile storage 时，行为必须与 M4.11 完全一致。新增 node override 后，节点渲染和 plan digest 必须包含 effective storage，避免缓存复用错误安装计划。

## 已实现代码影响清单

实施时必须逐项检查：

1. `model.zig`：扩展 `NodeOverrideConfig`，保持旧 JSON/TOML 默认值兼容。
2. `validate.zig`：把 storage 联合校验应用到 effective 配置；profile 默认值仍单独校验。
3. `kickstart.zig`、`ubuntu.zig`：所有 `boot_disk/install_disks/boot_mode/partition_table` 读取统一经过 effective storage，禁止继续直接读取 profile 字段。
4. `profile_mutation.zig`：保留旧 profile default mutation；新增 node storage mutation，不得修改共享 profile。
5. `node_mutation.zig`、management API：增加 set/unset、ETag/revision 和审计事件；旧接口返回兼容错误或弃用提示。
6. `main.zig`/views：`node show` 显示 `override`、`profile default`、`effective` 和 owner/action；`node set/unset` 与显示 key 完全一致；`profile show` 明确 default/fallback，不把派生字段列为可写。
7. desired digest、retry、安装任务：digest 输入必须是合并后的 node+profile 事实；profile 修改只影响未覆盖该字段的引用节点。
8. fixtures、CLI help、JSON schema、文档和回归测试同步更新。

## CLI/API 契约

推荐命令：

```text
nodeforge node show <id>
nodeforge node set <id> boot_disk=/dev/nvme0n1
nodeforge node unset <id> boot_disk
nodeforge profile show <name>
nodeforge profile set <name> boot_disk=/dev/sda   # 仅修改默认值并提示影响范围
```

`show` 只把直接存储 key 标为 settable；`effective_*`、状态、校验摘要和聚合列表必须标为 read-only。JSON 与 human 输出使用同一 key vocabulary。

## M5–M7 边界

* M5 diskless 不得复用安装 storage override；它只消费 profile 的 rootfs/initrd/boot-bundle 策略，并保留 node network override。
* M6 PXELINUX/新 adapter 必须消费 effective storage 抽象，不能重新读取 profile 原始字段。
* M7 reconciliation、finalizer、desired digest 和 retry 必须区分 profile default 变更与 node override 变更，避免无关节点重部署。
* 后续节点硬件探测若提供 firmware/disk facts，才可启用 `boot_mode/partition_table` 的自动来源；在此之前它们不能被声明为已实现的 node facts。

## 迁移与非回归验收

迁移采用“保留 profile default、节点 override 可选”的向后兼容格式，不自动复制 default 到所有节点。必须验证旧配置渲染字节级兼容、旧 CLI/API 行为、无 override 节点安装流程、profile 共享复用、单节点 override 隔离、失败回滚、并发 revision、JSON/human show 一致性，以及 M5–M7 未实现命令仍保持未注册状态。
