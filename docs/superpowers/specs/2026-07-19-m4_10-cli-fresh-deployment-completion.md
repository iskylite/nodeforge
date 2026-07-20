# M4.10 CLI fresh-deployment 闭环补全

> 状态：已实现并完成 r97n0 fresh-deployment CLI 回归。本文覆盖 M4.3/M4.6 将 profile 创建留到 M6 的旧边界，以及
> M4.7/M4.9 setup、reset 和 ISO import 中妨碍 fresh deployment 的 CLI 缺口。
>
> 本文中的 Profile `boot_disk/install_disks` 是 M4.10 历史实现和验证命令，不是 v0.1 目标接口。现行设计以
> `docs/V0_1_DESIGN.md` 为准：物理盘使用 Node direct `storage.boot_disk/additional_disks`，Profile 只保存可由
> Node override 的 storage policy。

## 1. 触发与目标

r97n0 清空后仅使用 CLI 执行 setup、ISO import、profile/node 创建时发现：

- `reset-all --purge-data` 保留 backup、日志和迁移备份，不能表达真正 fresh reset。
- `setup --reconfigure --install` 无诊断地退出；systemd 生成、unit 安装和服务启动职责不清。
- ISO import 成功只返回源路径，不返回 canonical install source。
- fresh catalog 没有 profile，而 CLI 没有创建入口，导致 node add 永远无法闭环。
- node add 把 profile 不存在、重复 MAC 等原因折叠成 `node.mutation_failed`。

M4.10 的完成路径固定为：

```bash
nodeforge setup --reset-all --purge-all --reconfigure --yes --non-interactive \
  --bind-interface enp26s0 --server-ip 192.168.27.128 \
  --subnet 192.168.27.0/24 --pool-start 192.168.27.200 --pool-end 192.168.27.254
systemctl daemon-reload
systemctl restart nodeforged
nodeforge assets import /path/Rocky-9.7-aarch64-minimal.iso
nodeforge node add r97n1 mac=... arch=aarch64 profile=rocky-9.7-aarch64-iso ip=...
```

## 2. setup 与 systemd 边界

- 初始化和 `--reconfigure` 始终生成并原子发布 canonical systemd unit。
- `--reconfigure` 不启动、停止或重启服务。服务生命周期由操作员显式执行 `systemctl`。
- `--generate-systemd` 是只处理 unit 的专项操作；`--print` 和 `--install` 只属于该操作。
- `--generate-systemd --install` 安装、enable 并启动 unit，保留既有 health/rollback 事务。
- `--reconfigure --install` 是职责冲突，CLI 必须输出解释性错误和退出码 2，不能静默失败。
- `--reset-all` 与 `--reconfigure` 是唯一允许组合的 setup 主操作，执行顺序固定为
  reset/purge → 生成配置和空 catalog → 联合校验 → 原子发布 canonical unit；组合操作仍不调用 systemctl。

## 3. fresh reset

`--reset-all --purge-data` 保持可恢复语义：保留 reset backup、日志和迁移备份。

新增 `--purge-all`，只能与 `--reset-all --yes` 组合，清理：

- runtime state、catalog、全部受管 assets 和 `work/` 临时数据；
- reset backups；
- service/event logs；
- M4.7 config/catalog migration `.bak`。

它保留二进制、marker、新生成的 startup config、空 catalog 和 canonical systemd unit。
输出必须明确 backup 已被 purge，不能返回一个已经不存在的路径。

`work/` 是受管临时空间，不属于需要跨 reset 保留的部署事实。清理必须覆盖 `work/import/` 中的 CLI
ISO 暂存副本以及中断操作留下的 `work/iso-import-*` 工作树，并在完成后重建权限正确的空
`work/`、`work/import/`。安装介质复制出的目录可能是只读的；实现可以在已校验 install root 派生出的
`work/` 边界内恢复 owner 权限后重试删除，但最终删除失败必须令操作失败，不能报告 purge 成功。

### 3.1 交互与非交互

- 未提供 `--yes` 且不是 `--non-interactive` 时，组合操作一次性展示完整清理范围和安装根，并以
  `[y/N]` 确认；空输入、`n` 或其他输入在任何写入前终止。
- `--non-interactive` 下破坏性操作必须同时提供 `--yes`。
- 当前“交互模式”是安全确认，不是网络配置菜单向导。网卡、地址、子网和地址池继续来自显式 flags
  或文档化默认值；CLI 不猜测网卡，也不要求操作员绕过 CLI 手工修改生成的配置。

## 4. 默认 profile 与补充 create

ISO import 在同一 catalog publication 中自动创建与 install source 同名的默认 install profile。
这使主路径不需要额外 profile 命令。默认 profile 固定为：

- `mode=install`
- `install_source=<source>`
- `safety.destructive=true`
- `safety.persistent_writes=true`
- `safety.reinstall_policy=explicit`
- 默认受校验的 install/system 配置

M4.10 同时提前交付窄创建能力，用于从已有 source 补充第二个 profile：

```bash
nodeforge profile create <name> <install-source>
```

CLI 不接受重复 tuple 或任意 safety/storage JSON，从而避免把 M6 的全量 profile mutation
提前变成第二套不受控接口。后续复杂变更仍由 M6 设计。

实机磁盘名不能由 ISO tuple 推导。自动 profile 使用兼容默认值 `/dev/sda`，操作员可在不编辑
catalog JSON 的情况下显式修正 profile 级安装目标：

```bash
nodeforge profile set <profile> boot_disk=/dev/nvme0n1
nodeforge node retry <node>
```

该变更同时更新 `storage.boot_disk` 与单盘 `install_disks`，并经过完整 model 校验。`profile show`
必须展示 boot disk 与 wipe 状态。磁盘属于共享安装计划，不放入 `node set` 的发现/身份属性。

若安装器已获取 capability、但在发送 terminal event 前失败，普通 retry 继续拒绝覆盖活动 session。
操作员确认目标机已停止后，可使用 `node retry <node> --force` 显式 supersede 卡死 session 并重新武装；
不得要求手工删除 session checkpoint。

M4.9b 已以 node-scoped 完整 digest 武装 generation；节点 arm 后补充一个无关 profile 不再导致
`rearm-required`。只有实际影响该节点的 profile/source/asset、目标系统字段或有效交付 key 变化才要求 retry。

## 5. 输出和错误契约

- ISO import human/JSON 输出 canonical `install_source`、同名默认 `profile` 和下一步 node add 提示。
- profile create 返回 profile/source/mode。
- node add 至少区分 `node.profile_not_found`、`node.already_exists`、`node.duplicate_mac`。
- 在线添加 `deploy=true` 的 install 节点立即持久化 initial generation；不得依赖 daemon 重启或额外 retry。
- 在线 node add 按新受管节点数只增不减地扩大 deployment/status/inventory effective capacity；启动时按旧
  节点数派生的容量不得使第二个节点“已落 catalog、未能 initial arm”。
- 所有失败继续携带 request id；CLI 不把结构化服务端错误重新折叠成通用消息。
- human `profile show` 必须接受 ISO 自动 profile 的 nullable `source_label`，为空时回退 source name。

## 6. 验收

- setup help 和冲突 flag 诊断测试。
- reset-all/purge-all + reconfigure 覆盖 stale unit，但不调用 systemctl；交互拒绝时无写入。
- purge-all 后不存在 backups、日志文件、migration backup 或旧 work/import 数据；空 `work/import/`
  已按 canonical 权限重建。测试必须覆盖交互拒绝保留 work 哨兵，以及确认后清理只读 ISO 工作树。
- profile create 正向、重复、missing source 测试。
- node add missing profile 错误透传测试。
- ISO import 输出 install source。
- 本地完整测试、ARM64 交叉编译通过。
- r97n0 从 purge-all 开始，仅用 CLI 完成 ISO import（自动 profile）和 node add；另验显式补充 profile create。
- node add 后立即为 `initial-armed/pxe_ready=true`；补充无关 profile 后仍保持 ready。
- r97n1 NVMe 实机使用 profile set 修正目标盘后完成 Anaconda 安装；卡死 session 通过显式
  `node retry --force` 恢复，不修改 JSON/checkpoint。

## 7. 设计—实现映射

| 现行契约 | 实现事实源 | 自动/实机证据 |
| --- | --- | --- |
| reset/purge → reconfigure，且不隐式控制服务 | `src/main.zig` `setupHandler`、`purgeSetupHistory` | `tests/setup.sh`；r97n0 fresh CLI 回归 |
| standalone systemd 安装带 readiness/rollback | `src/main.zig` `installSystemd`、`waitForSystemdHealth` | setup 合约测试；Rocky 激活验证，负向回滚清单继续保留 |
| ISO import 原子发布 source + 同名默认 profile | `src/catalog/iso_import.zig`、`src/state/catalog_runtime.zig` | catalog 单测、`tests/http.sh`、r97n0 ISO 导入 |
| 窄 profile create / boot disk mutation | `src/config/profile_mutation.zig`、`src/http/server.zig` | `tests/http.sh`；r97n1 NVMe 安装 |
| node add 立即 initial arm；容量在线扩大；retry 可强制替代卡死 session | `src/http/server.zig`、`src/state/deployment_control.zig`、`src/state/boot_session_store.zig` | 244 个 Zig 测试、HTTP/CLI 合约、r97n2 Ubuntu generation 3 |

本表只映射 M4.10 范围。M4.9b 的 node-scoped 完整 SHA-256 已实现，但其系统验收必须引用独立的
schema/迁移负向证据和本轮 r97n0/Ubuntu PXE 记录，不能只引用旧 PXE 正向成功。
