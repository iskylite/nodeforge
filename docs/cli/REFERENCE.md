# NodeForge v0.2.2 CLI Reference

本文记录 v0.2.2 的正式公开命令树。命令自身的 `--help` 是参数、默认值和约束的
唯一事实源；需要属性、集合或高级选项时使用 `--help-full`。

```text
nodeforge [-v|--version] [--install-root PATH] COMMAND [OPTIONS]
```

`--install-root` 必须位于子命令之前。结构化输出统一使用
`--output json|jsonl`；JSON stdout 不混入进度文本。

## 资源与构建

```text
assets import
assets list|show|validate
assets install-source list|show|software
assets repository
assets initrd build
assets boot-bundle
assets managed-file|archive|script
assets provision-bundle
assets key-import|key-list|key-reload|key-show
```

ISO 导入和 initrd 构建会创建 durable operation。默认跟随到终态；
`--detach` 立即返回 operation，CLI 超时不会取消 daemon 中的任务。

## Profile

```text
profile create|clone|remove
profile list|show|capabilities|software
profile set|unset
profile add-values|remove-values|replace-values|clear-values|list-values
profile item|replace-items|clear-items
profile rootfs plan|build|status|register
```

`profile clone` 只复制 desired configuration，不继承 runtime、session 或 operation。
`profile show` 已包含 Stored 与 Effective 投影，不另设 `profile effective`。

## Node 与生命周期

```text
node add|remove|list|show
node set|unset
node add-values|remove-values|replace-values|clear-values|list-values
node item|replace-items|clear-items
node capabilities|software|render
node boot preview
node readiness
node deploy
node retry [--force]
node postprocess show
node session list|show|cancel
node trace
node claim
```

`node boot preview` 严格只读，不创建 session、token 或 operation。
`node readiness` 用于 diskless build/boot readiness；install Profile 使用
`node boot preview` 检查下一次启动选择。`node retry` 由服务端单事务完成
install rearm 或 diskless failure/quarantine 恢复。

`node show` 已包含 Stored、Overrides、Effective 与 Runtime，不另设
`node effective`。有副作用的 boot prepare transition 不属于普通公开工作流。

## Durable operation

```text
operation list
operation show OPERATION_ID
operation follow OPERATION_ID
operation wait OPERATION_ID
```

`follow` 是正式名称，`wait` 保留为兼容入口。通用状态为
`queued -> running -> succeeded|failed`；v0.2.2 不提供通用 cancel。

## 其他管理入口

```text
setup
status
config validate|export
catalog validate|show
discovery
events
runtime
```

推荐主流程：

```text
setup -> assets import -> profile create|clone -> profile rootfs build
-> node add|set -> node readiness -> node boot preview
-> node deploy|retry -> node show|postprocess show
```

完整示例和 fresh setup 约束见仓库根目录 `README.md`。
