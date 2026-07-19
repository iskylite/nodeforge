# M4.11：统一运行状态与 mutation key 可发现性

## 1. 问题

当前同时存在 `nodeforge status`、`nodeforge check` 和 `nodeforge runtime status`。三者检查范围不同，
但输出都容易被理解为“nodeforged 可用”：旧 `status/check` 只检查少量 HTTP 管理路由，旧
`runtime status` 只增加 TFTP 计数，均不能证明配置中对 PXE 节点公布的 HTTP 地址以及 catalog、DHCP、
TFTP 管理面同时可用。

`node/profile show` 的 human 输出使用展示标签（如 `HTTP accel`、`Boot disk`），mutation 则接受
snake_case key（如 `http_accel`、`boot_disk`）。操作员无法从 show 明确判断哪些事实可修改，也不能可靠地
把查询结果复用于 `set`。

## 2. Canonical status

唯一入口为：

```bash
nodeforge status [--output human|json] [--config <path>]
```

删除根级 `nodeforge check` 和 `nodeforge runtime status`，不保留含糊的兼容别名。自动化同时使用
`nodeforge status --output json` 和退出码：全部必需检查通过返回 0，任一检查失败返回 1。

一次 status 必须检查并分别展示：

- 本机进程/端口可达；
- loopback `/healthz`；
- 配置中 `server.server_ip:http_port` 对外公布地址的 `/healthz`；
- management status 路由；
- daemon 当前生效配置重新校验；
- node 与 profile catalog API；
- DHCP leases runtime API；
- TFTP runtime API，并附带 started/completed/failed 计数。

human 输出必须有 Overall 结论和每项独立结果，不能因一个 `/healthz` 成功就报告整体可用。JSON 使用稳定的
snake_case check key，并包含 `ok`、`advertised_url` 和 TFTP 计数。

## 3. list/show 与 set key

资源是否可修改由是否存在对应 mutation 命令决定。没有 `set` 的资源（asset、catalog、runtime 等）
其 list/show 全部是只读事实，不制造伪 mutation key。

`node list` 和 `profile list` 是摘要表，必须提示对应资源的 settable key，并引导到 show。`node show` 与
`profile show` 必须提供独立的 `Settable properties` 块：

- key 必须与相应 `set` parser 完全一致；
- value 必须使用 parser 接受的规范形式，例如 bool 固定为 `true|false`；
- 当前存在的属性以 `key=value` 输出，可直接作为 set 参数复用；
- optional 属性未设置时不得输出不可执行的 `key=-`，而应明确标为 unset，并指出对应 `unset` 命令；
- 计算结果、运行态、引用展开、安全状态和 revision 必须放在 `Read-only` 分组，不能暗示可由 set 修改。

show 同时提供 `Owner / action` 映射，综合处理跨资源和只读事实：

- 当前资源直接存储且 mutation allowlist 已支持的 key，放入 Settable properties；
- 其他资源直接存储的 key 保留真实限定名（如 `profile.kernel_args`），标明 owner，并给出可执行的 owner
  命令，不能复制成当前资源的 set；
- 直接存储但设计上不可变或尚无安全 mutation 的字段，标明真实 owner 和
  `read-only (no mutation command)`，不得虚构写入口；
- 聚合/计算投影、运行态、机器上报和 revision 分别标明 projected/runtime/node-reported/model-store
  owner，并明确 read-only；
- lifecycle 状态不开放字段赋值，而是映射到 `node retry [--force]` 等状态机 action。

当前 allowlist：

- `node set`：`mac`、`arch`、`profile`、`ip`、`hostname`、`deploy`、`http_accel`；
- `node unset`：`ip`、`hostname`；
- `profile set`：`kernel_args`、`boot_disk`；
- `profile unset`：`kernel_args`。

新增 mutation 字段时，parser allowlist、show 的 settable block、list 提示、help、JSON DTO 和测试必须在同一
变更中更新，禁止重新引入展示 key 与写入 key 漂移。

`node/profile set` 与 `unset` 的 help 必须列出完整 key allowlist、bool/引号/必填等约束，并至少给出一条
可复制示例。参数帮助是 mutation key 的入口文档；不能要求操作员阅读实现代码猜测 key。

## 4. 验收

- CLI help 只暴露一个 status 入口。
- daemon 正常时 human status 的全部检查为 OK，JSON 全部布尔检查为 true，退出码为 0。
- advertised listener 或任一必需管理面失败时 Overall 为 FAIL，JSON `ok=false`，退出码为 1。
- node/profile show 输出的每个 settable key 都被相应 parser 接受。
- optional unset 不伪装成可 set 的占位值。
- 跨资源、lifecycle、计算和上报字段具有准确 owner/action 或 read-only 标记。
- set/unset help 的 key、约束、示例与 parser 和 show 一致。
- node/profile list 显示准确 allowlist；只读资源不宣称支持 set。
- 完整本地测试、格式检查和 ARM64 ReleaseSafe 交叉编译通过。
