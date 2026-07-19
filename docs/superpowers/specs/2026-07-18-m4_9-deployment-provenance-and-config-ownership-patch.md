# M4.9 部署溯源、PXE 门禁与配置入口收口补丁

> 状态：M4.9a 已实现并完成 Rocky 9.7 aarch64 fresh-deployment 回归；M4.9b 的完整
> node-scoped SHA-256、schema 迁移和授权门禁已实现；自动测试、r97n0/Ubuntu
> PXE、force-retry 和 systemd readiness rollback 系统验收均已完成。
>
> 本文是 M4.1–M4.8 之后的覆盖性补丁。旧章节保留当时设计和验证事实；发生冲突时，以本文和
> `DETAILED_DESIGN.md` §9.18 为准。

## 1. 背景与触发

2026-07-18 在 r97n0 清空二进制、startup config、catalog、runtime state 和其他 NodeForge 受管数据后，
使用当前分支重新交叉编译并执行 fresh setup、ISO 导入和 node add。r97n1 从 VMware UEFI PXE 启动时，
r97n0 记录：

```text
PXE withheld ... install_not_armed
armed_generation=1
requested_revision=2632895608528107461
desired_revision=11733222931490568455
```

两个数字不是递增 revision，也不表示数值较小者更旧。它们是 SHA-256 截断为 u64 后的 opaque 内容指纹，
不同只代表 arm 时确认的模型与 DHCP 当前使用的模型指纹不一致。

故障不是 unknown-node 防护不足。r97n1 已有完整 MAC、arch、profile 和 deploy 属性；真正问题是 HTTP/retry
使用 config+catalog 联合指纹，而 DHCP 仍可能使用 config-only 指纹，导致同一进程中的两条链路使用不同事实源。

## 2. 最近提交关联

| 提交 | 关联 | 结论 |
| --- | --- | --- |
| `c86b324` | 保留 DHCP 读取 config-only revision 的既有实现 | 与复现有关，但不是首次引入 |
| `3ca9259` | 尝试让部分路径使用 ModelRuntime；计算失败仍回退 startup revision | 只完成一半，仍可分叉 |
| `6d282d2` | 较早引入 config-only 读取 | 初始技术来源 |
| `46d935f` | M4.7 拆分 config/catalog ownership | 使两类指纹差异稳定可见，但拆分本身正确 |
| `0ed4395` | ISO/catalog 收口 | 暴露 fresh 环境对 bootloader 残留文件的隐式依赖 |

因此不能简单回退最近一次提交。修复必须统一事实源、删除错误 fallback，并补齐 fresh-environment 自举。

## 3. M4.9a 已实现范围

### 3.1 revision 计算与失败关闭

- DHCP、HTTP arm、install plan、status/drift 投影统一基于同一 config/catalog pair 计算联合 desired revision。
- HTTP 计算失败返回 `503 model.revision_unavailable`，不得回退 config-only revision。
- DHCP 没有错误响应通道，计算失败使用 0 sentinel 并 withholding PXE。
- DHCP persistence 必须持有 ModelRuntime；旧 `config_revision`/ConfigRuntime fallback 字段删除，缺少联合模型不能构造该依赖。
- `reinstall_policy=always` 在 revision unavailable 时不得把 0 武装为可消费 generation。
- 每个 HTTP request 在 route entry pin 同一 model pair；一个请求不能跨 snapshot 拼接 config/catalog。

联合 SHA-256 的前 64 bit 只保留为 view revision 和旧 schema/CLI 读取兼容。安装授权、恢复 join 和 drift
均使用完整 node-scoped digest。

### 3.2 四层安装门禁

四层职责必须分离：

1. node identity：完整且唯一的 MAC、arch、profile 决定“是谁”；未知或不完整节点不安装。
2. `node.deploy`：已知节点是否允许参与 PXE 的长期硬开关。
3. install generation：防止已安装、PXE-first 节点自动重复安装；retry 只武装下一 generation。
4. plan digest/revision：防止操作员 retry 后、PXE 消费前，破坏性安装计划被替换。

revision 不是 unknown-node 防护，也不是 generation 的替代品。删除全部比较会失去 retry 与实际 PXE 之间的
compare-and-swap；使用全局摘要又会让无关 ISO/node mutation 误伤当前节点。最终应改为 node-scoped plan digest。

### 3.3 retry 与 PXE 可见性

`node list/show` 和 management DTO 增加：

- `install_intent`
- `pxe_ready`
- `retry_pending`
- `armed_generation`

`install_intent` 的稳定值：

| 值 | 含义 |
| --- | --- |
| `disabled` | `deploy=false` |
| `initial-armed` | 首次 install generation 已武装且当前兼容 revision 匹配 |
| `retry-armed` | 操作员 retry 已武装且当前兼容 revision 匹配 |
| `policy-armed` | reinstall-always policy 武装 |
| `rearm-required` | 有 armed generation，但确认时 revision 与当前 desired 不同 |
| `installing` | generation 已消费、尚未 terminal |
| `not-armed` | 没有待消费安装意图 |

`retry_pending=true` 只表示存在 operator-armed generation；能否下发 PXE 以 `pxe_ready` 为准。

### 3.4 BootSession 与重启恢复

`boot-sessions.json` 与 `deployment-control.json` 分别原子写，但不是跨文件事务。启动顺序固定为：

1. 加载并校验 deployment-control。
2. 加载 BootSession checkpoint。
3. install session 以 node/profile/MAC、deployment generation、model revision、immutable asset 和 plan
   provenance 与 control join。
4. 任一不一致 fail closed，不能恢复 capability，也不能重新 arm。

status 恢复只作为历史投影，重启后强制 `session_active=false`；后续合法 session event 才能重新激活。

### 3.5 fresh ISO 自举与 systemd readiness

- ISO importer 必须从媒体提取对应架构的 UEFI GRUB bootloader，并与 kernel/initrd/source 在同一 catalog
  publication 中发布；不得依赖旧安装目录残留 `efi/grub*.efi`。
- 同架构、同内容 bootloader 重复导入幂等复用；内容冲突 fail closed。
- `systemctl start` 对 `Type=simple` 只证明进程已 exec，不证明 HTTP listener ready。setup 使用 5 秒有界
  health retry；超时或真实模型错误仍执行既有 rollback。

### 3.6 startup config 单一写入口

M0 遗留的独立 `config import` 和 M4.3 遗留的 `config set` 已删除：

- `config import` 只校验单文件，绕过 setup 的 config+catalog 联合校验，并与 setup 形成重复 writer。
- `config set` 在 M4.7 后对应的 PATCH 永远返回 `config.offline_only`，是不可成功的死命令。
- `PATCH /api/v1/management/config` 不再注册；config management API 只保留 GET 摘要和 POST validation。

唯一受支持的 startup-config 写流程：

```bash
nodeforge config export > candidate.json
# 编辑 candidate.json
nodeforge setup --reconfigure --import-config candidate.json
systemctl restart nodeforged
```

setup 在写入前完成：

1. source JSON 解析和 startup config shape 校验。
2. schema 2 与 startup-only ownership 校验；拒绝夹带 distro/profile/node/bundle。
3. 与当前 catalog 的完整 model 校验。
4. 原子覆盖 canonical config 并明确输出 restart requirement。

setup 不改写 deployment 的 requested/applied provenance。前者会替操作员自动确认新的擦盘计划，后者会伪造
目标机已应用新配置。daemon 重启加载新 pair 后重新计算 desired；真正受影响的 pending install 显示
`rearm-required`。

## 4. M4.9b：完整 256-bit node-scoped digest

该部分是当前实现契约。自动门槛与系统验收状态分别记录。

### 4.1 持久化模型

deployment-control schema 3 保存三个 64 字符小写 SHA-256：

- `requested_plan_digest`
- `consumed_plan_digest`
- `applied_plan_digest`

BootSession、node-status 和 install-plan envelope 保存同一个完整 `plan_digest`。CLI 可以显示前 12 字符，
但授权、状态 join 和 drift 判断禁止使用截断值。

### 4.2 node-scoped 输入

digest 只包含实际影响目标节点的：

- node identity、hostname、network overrides
- profile mode、system、storage、bootloader、kernel args
- referenced distro/source/repository/bundle/assets 的 logical identity 和完整内容 digest
- answer 实际采用的 bootstrap key 和 additional keys（包括配置外解析出的受管/自动生成 key）

导入未被该节点引用的 ISO、增加另一节点或修改无关 profile，不得使 pending retry 失效。
受管 ISO repository 的字节身份由同一被引用 source ISO 的 SHA-256 约束；外部 mirror 只能绑定声明 URL，
NodeForge 不把远端可变内容伪装成 immutable asset。

### 4.3 迁移

- 旧 u64 仅允许在一个读取兼容窗口展示，不再授权安装。
- 旧 schema 的 pending arm 无法证明完整 digest，升级后标记 `rearm-required`。
- 只有旧 applied u64 的节点，其 drift 为 `unknown`，下一次成功安装建立完整基线。
- deployment/session/status 必须同一版本窗口升级，不能只迁移单个 checkpoint。

## 5. supersession 矩阵

| 历史条款 | M4.9 现行结论 |
| --- | --- |
| M0 `config import` 直接覆盖配置 | 命令删除，setup `--import-config` 是唯一 startup-config writer |
| M4.3 allowlist `config set` | 命令和 client 删除，management config PATCH 未注册 |
| M4.7 `PATCH config -> 409 config.offline_only` 兼容路由 | 删除死路由，未注册 method 返回 405 |
| DHCP 使用 config revision | DHCP/HTTP 都使用同一 pinned config+catalog desired revision |
| revision 计算失败回退 config-only | 禁止 fallback，HTTP 503、DHCP fail closed |
| node list/show 通过内部 generation 字段推测 retry | 显式 `install_intent`/`retry_pending`/`pxe_ready` |
| BootSession 仅按 TTL/node 恢复 | 必须与 deployment generation/revision 和 immutable plan provenance join |
| ISO import 假设 bootloader 已存在 | importer 从 fresh media 自举并发布 bootloader |

## 6. 验证证据

自动门槛：

- `zig build test --summary all`：244/244（最终代码上重跑）。
- CLI 契约：`config import`、`config set` 不出现在 help，setup 暴露 `--import-config`。
- HTTP 契约：management config PATCH 返回 405，GET/validation 保持只读。
- setup：合法 candidate 联合校验后落盘；非法 candidate 不改变 canonical config。
- `make arm64`：aarch64-linux-gnu ReleaseSafe 通过。

系统门槛：

- r97n0 清空 NodeForge 受管数据并 fresh setup。
- 导入 Rocky 9.7 aarch64 ISO 后 bootloader/kernel/initrd/source 完整。
- 添加 r97n1，VMware UEFI 获得 lease 和 bootfile。
- r97n1 拉取 GRUB/kernel/initrd，完成 Anaconda 安装。
- 重启后从本地虚拟磁盘正常进入 Rocky 9.7。
- r97n2 使用 Ubuntu 22.04.5 完成 UEFI PXE、NVMe 安装、本地盘启动和 force-retry generation 3。
- active daemon 不响应时 readiness 在 6 秒内失败，unit link、enabled/active 状态和健康服务全部恢复。

完整证据见 `docs/UBUNTU_22_04_M4_9_M4_10_VALIDATION.md`。
