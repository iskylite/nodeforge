# NodeForge CLI Reference

现行公开命令树速查。命令自身的 `--help` / `--help-full` 是参数、默认值和约束的
**唯一事实源**；本文可能滞后于代码，冲突时以 help 与源码为准。

v0.2 时期完整接口论述见冻结分册 [`../design/V0_2_CLI.md`](../design/V0_2_CLI.md)（只读）。

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

ISO 导入和 initrd 构建会创建 durable operation。ISO 导入由 daemon 的
`IsoImportWorker` 后台执行（staging 按 operation id 隔离），CLI 默认跟随到
终态，超时不会取消 daemon 中的任务。`assets initrd build --detach` 立即返回
operation；CLI 超时均不取消 daemon 侧任务。

## Profile

```text
profile create|clone|remove
profile list|show|capabilities|software
profile set|unset
profile add-values|remove-values|replace-values|clear-values|list-values
profile item|replace-items|clear-items
profile rootfs plan|build|status
profile rootfs staging list|show|remove
profile rootfs staging enter|exec|kernels
```

v0.4.1 会话与换核（详情以 `--help-full` 为准）：

```text
# 交互 / 非交互会话（管理节点本机 root；不经 nodeforged）
sudo nodeforge profile rootfs staging enter <profile> [--digest HEX]
  [--shell PATH] [--workdir PATH] [--env K=V,...] [--bind host:guest,...]
  [--no-cgroup | --memory-max SIZE --memory-swap SIZE --cpu-max SPEC --pids-max N]
  [--persist-tmp] [--hostname NAME] [--quiet]

sudo nodeforge profile rootfs staging exec <profile> [--script /host/path.sh | -- <cmd>...]
  [同上限额/bind/env/timeout 等]

# 扫描保留树内内核
nodeforge profile rootfs staging kernels <profile> [--digest HEX]

# 再打包 + 可选启动面换核（默认 keep = 与 v0.4 一致）
nodeforge profile rootfs build <profile> --from-staging
  [--kernel-release keep|auto|<uname-r>]
```

- 限额单位：`memory-max` 支持 `2G`/`512M` 等，内部换算为 cgroup v2 字节；写失败 **fail closed**。
- `--no-cgroup` 与任一限额 flag 互斥。
- `--script` 与位置命令互斥；脚本从宿主 bind 进会话后执行。
- 同 digest 会话锁与 `from-staging` / `staging remove` 互斥。

`profile clone` 只复制 desired configuration，不继承 runtime、session 或 operation。
`profile show` 已包含 Stored 与 Effective 投影，不另设 `profile effective`。
`profile clone <source> <target> [KEY=VALUE...] [--new-ssh-keys] [--build] [--detach]`：
- `--new-ssh-keys` 为克隆创建独立 SSH identity；缺省复用源 Profile 的 identity；
- `[KEY=VALUE...]` 与 `profile set` 同范围的 property patch，与 clone 在同一
  catalog 事务中校验并提交（不允许 patch `provenance`/`revision`/
  `ssh_identity`）；
- `--build` 在 clone 提交后追加 rootfs build operation（仅 diskless Profile，
  install Profile 上返回 exit code 2）；build 提交失败不回滚 clone，
  JSON 结果含 `profile_created=true, build_submitted=false`，exit code 5
  （`rootfs.build_submit_failed`）；
- `--detach` 仅与 `--build` 同用，立即返回 operation id（不 follow）；
  单独使用返回 exit code 2。

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
`node deploy <id>` 缺省等价于 `node deploy <id> true`；显式 `false` 关闭部署闸门。

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

`setup` 的 reset/purge 边界：

| 入口 | 保留/删除语义 |
|---|---|
| `--reset-state --yes` | 备份并清空 runtime state；保留 config、catalog、assets、work、logs、backups |
| `--reset-all --yes` | 另重新生成 config；默认仍保留 catalog/assets，不等于 fresh replacement |
| `--reset-all --purge-data --yes` | 再删除 catalog/assets；保留 work/logs/backups |
| `--reset-all --purge-all --reconfigure --yes` | 不可恢复地删除 catalog/assets/work/logs/backups/migration history，生成空部署并重新发布 unit |

所有 reset/purge 要求 daemon 已停止；`--reconfigure` 不调用 `systemctl start/restart`。

推荐主流程：

```text
setup -> assets import -> profile create|clone -> profile rootfs build
-> node add|set -> node readiness -> node boot preview
-> node deploy|retry -> node show|postprocess show
```

完整示例和 fresh setup 约束见仓库根目录 `README.md`。

## Exit code（v0.2.3 §8 冻结契约）

| code | 类别 |
|---:|---|
| 0 | 命令成功 |
| 1 | 本地数据、协议或未知产品错误（daemon 返回未知业务错误、JSON 解析失败） |
| 2 | CLI 输入错误（参数缺失、格式错误、无效选项值） |
| 3 | revision/idempotency 并发冲突（`catalog.revision_conflict`、`http.precondition_required`、`install_source.busy` 等） |
| 4 | readiness 或前置条件不满足（`profile.not_diskless`、`rootfs.digest_drift`、install source 不存在） |
| 5 | durable operation 终态 failed/interrupted |
| 6 | daemon 不可达或等待超时 |

错误信封（`error.code`）按 §8.3 唯一映射到 exit class；同一 code 不会被映射到
不同 exit class。业务诊断写 stderr，JSON stdout 保持单一错误文档。
