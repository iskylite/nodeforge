# NodeForge v0.4.3 设计：节点本地部署信息查询（agent 子命令）

状态：**设计中**（v0.4.3 唯一设计入口；实现前评审）

## 0. 定位

运维 SSH 登录 **diskless 目标节点** 后，管理 API 通常在管理节点本机（如 `127.0.0.1`），无法远程 `node show`。  
本版只解决：在节点上用 **`nodeforge-agent inspect`** 读取 **本机已有** NodeForge 部署事实（**只读、不连 nodeforged**）。

| 做 | 不做 |
|---|---|
| diskless 节点本地 inspect | **install 节点不在本版范围**（无对等 plan 痕迹需求） |
| 只读本机文件 | 连接 nodeforged / 管理 API |
| 子命令式 CLI 重构（与 0.4.4 共用骨架） | 写配置、诊断包、构建 rootfs |

后续：本机构建 → [`V0_4_4_DESIGN.md`](V0_4_4_DESIGN.md)；克隆/恢复 → [`V0_4_5_DESIGN.md`](V0_4_5_DESIGN.md)。

---

## 1. 目标

1. **`nodeforge-agent` 改为子命令入口**（见 §3），`inspect` 为正式子命令。  
2. **仅 diskless**：输出本机部署摘要；数据 **只来自本机**。  
3. **仅 root 可执行**（`euid==0`，否则非 0 退出）。  
4. human + `--output json`；无新常驻服务。

---

## 2. 数据源与字段契约（对齐代码）

pre-init 成功后，`/var/lib/nodeforge/boot.json` **内容为已校验的 AgentPlan v2 JSON**（**不含 token**）。  
initrd 另写 `/var/lib/nodeforge/session-id`。

### 2.1 字段 ← 来源（实现必须按此映射）

| 输出字段 | 来源 | 缺失时 |
|---|---|---|
| `schema_version` | 固定 `1` | — |
| `kind` | 固定 `"diskless"`（本版仅此路径） | — |
| `node_id` | `boot.json` → `node_id` | 整体失败（见 §4） |
| `session_id` | 优先文件 `session-id` 首行；否则 `boot.json` → `session_id` | null |
| `plan_digest` | `boot.json` → `plan_digest` | null |
| `rootfs_input_digest` | `boot.json` → `rootfs_input_digest` | null |
| `desired_plan_digest` | `boot.json` → `desired_plan_digest` | null |
| `deployment_id` | `boot.json` → `deployment_id` | null |
| `hostname` | `node_apply_projection.hostname` | null |
| `mac` | `node_apply_projection.mac` | null |
| `arch` | `node_apply_projection.arch` | null |
| `first_boot_bundle` | `boot.json` → `first_boot_bundle` | null |
| `profile` | **AgentPlan 无此字段** → **恒为 null**（不臆造） | null |
| `paths.boot_json` | 文件是否存在 | bool |
| `paths.session_id_file` | `/var/lib/nodeforge/session-id` 是否存在 | bool |
| `paths.initrd_log` / `firstboot_log` | 是否存在（不倾倒内容） | bool |
| `notes` | 固定短文案（只读 lower / upper 易失等） | 可选数组 |
| `generated_at` | 执行时刻 UTC | — |

**禁止输出：** `credentials/*`、任何 token、密码哈希、完整 authorized_keys 列表。

### 2.2 成功 / 失败条件（exit）

| 码 | 条件 |
|---|---|
| `0` | root，且 `boot.json` 存在且能解析为含 `node_id` 的 AgentPlan 对象；允许部分字段 null |
| `1` | root，但 **不是** 可识别的 diskless 部署痕迹（无 boot.json / 解析失败 / 无 node_id） |
| `2` | 非 root、用法错误、未知子命令 |
| `其它` | 意外 I/O |

说明：exit `1` 表示「这台机器上没有可展示的 diskless 部署信息」，不是「字段缺一个就失败」。

---

## 3. CLI 重构（v0.4.3 起骨架，0.4.4 沿用）

### 3.1 子命令模型（**不**兼容旧 argv）

```text
nodeforge-agent <subcommand> [flags…]
```

**硬性规则：必须有子命令。** 无子命令 / 仅旧式 `--pre-init` flag → **usage + exit 2**，**不**再隐式 first-boot / pre-init。

| 子命令 | 版本 | 行为 |
|---|---|---|
| `pre-init` | 既有逻辑迁入 | 原 `--pre-init` 路径（切根后 PID1） |
| `first-boot` | 既有逻辑迁入 | 原 unit 无参路径 |
| `inspect` | **0.4.3** | 本机部署摘要 |
| `version` | **0.4.3** | 打印版本 |
| `help` | **0.4.3** | 用法 |
| （0.4.4）`rootfs …` | 见 V0_4_4 | 本机构建 |

**调用方必须同步改（实现本版时一并改，不做双认过渡）：**

| 调用方 | 旧 | 新 |
|---|---|---|
| initrd `execve` agent | `nodeforge-agent --pre-init` | `nodeforge-agent pre-init` |
| `nodeforge-firstboot.service` | `ExecStart=…/nodeforge-agent` | `ExecStart=…/nodeforge-agent first-boot` |
| 文档 / runbook / 测试脚本 | 旧 argv | 子命令 |

### 3.2 全局约束

| 项 | 裁决 |
|---|---|
| 执行身份 | **所有子命令要求 root**（`euid==0`），含 `inspect` / `version` |
| 连接 nodeforged | **inspect 禁止** |
| 输出 | `inspect --output human\|json`（默认 human）；json 时业务在 stdout，诊断在 stderr |

### 3.3 全面调整清单（实现 v0.4.3 时必须闭合）

子命令硬切、**不做旧 argv 兼容**。下表为变更全集；实现 PR 应按表勾选，缺一即 boot 断链。

#### A. 代码 / 构建产物

| # | 项 | 现状 | 目标 |
|---|---|---|---|
| A1 | `src/agent.zig` 入口 | `--pre-init` / 无参 first-boot | **强制** `pre-init` \| `first-boot` \| `inspect` \| `version` \| `help` |
| A2 | 删除旧解析 | flag / 无参语义 | 无子命令 → exit 2 + usage |
| A3 | `src/initrd.zig` | `argv = {agent, "--pre-init"}`（约 L407） | `argv = {agent, "pre-init"}`；日志字符串同步 |
| A4 | initrd 模块注释 | 写 `--pre-init` | 改为 `pre-init` 子命令 |
| A5 | agent 文件头注释 | 两阶段旧 argv | 子命令说明 |
| A6 | `zig-out/share/.../nodeforge-firstboot.service` 源模板 | `ExecStart=.../nodeforge-agent` | `ExecStart=.../nodeforge-agent first-boot` |
| A7 | rootfs 烤入 unit 的路径 | 构建/注入逻辑若写死 ExecStart | 与 A6 一致（搜 firstboot.service 注入点） |
| A8 | agent 单测 | 无分发测试 | 无子命令失败；inspect 夹具；pre-init/first-boot 入口仍可测 |
| A9 | （可选预留）`rootfs` 命名空间 | — | 仅 help 列出「见 v0.4.4」，本版不实现 |

#### B. 启动链与制品（必须同版发布）

| # | 项 | 说明 |
|---|---|---|
| B1 | **nodeforge-initrd 与 nodeforge-agent 必须同构建、同发版** | initrd 内嵌/拷贝的 agent 与 rootfs 内 agent 调用约定一致；禁止只升其一 |
| B2 | **重建 diskless initrd 资产** | 改 A3 后旧 initrd 仍会 exec `--pre-init` → 新 agent 直接失败；发版闸：相关 boot_bundle 的 initrd 必须 rebuild |
| B3 | **重建 / 替换已发布 rootfs 中的 unit + agent** | 旧 squashfs 内 unit 无参、旧 agent 不认 `first-boot`；发版或运维须 rootfs rebuild 或明确「仅新 profile」 |
| B4 | install-root 的 `share/systemd` 与 setup 拷贝 | `setup` / 打包脚本带上新 unit |
| B5 | 现场已部署节点 | 滚动：先发管理节点新二进制 → rebuild initrd+rootfs → 再开 diskless；文档写清顺序 |

#### C. 文档（现行有效，非 archive）

| # | 路径 | 改什么 |
|---|---|---|
| C1 | 本文件 | 契约与清单（本文） |
| C2 | [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) | 凡 `nodeforge-agent --pre-init` / 无参 unit → 子命令（现行行为入口） |
| C3 | [`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md) 等仍被引用的冻结分册 | 启动 argv 处加脚注「v0.4.3 起为子命令」或改关键句，避免与实现矛盾 |
| C4 | [`README.md`](../../README.md) | agent 职责一句 + 子命令示例 |
| C5 | [`docs/cli/REFERENCE.md`](../cli/REFERENCE.md) | 增加 **nodeforge-agent** 小节：子命令表、root-only、inspect |
| C6 | [`docs/validation/PLATFORM_VALIDATION_RUNBOOK.md`](../validation/PLATFORM_VALIDATION_RUNBOOK.md) | 核验 agent/initrd 成对、unit ExecStart、实机 boot 用新 argv |
| C7 | [`docs/validation/V0_4_FULL_VALIDATION_RUNBOOK.md`](../validation/V0_4_FULL_VALIDATION_RUNBOOK.md) | diskless 闭环步骤注明 first-boot unit 子命令 |
| C8 | v0.4.1 / v0.4.4 设计交叉引用 | 已/同步指向子命令模型 |

#### D. 测试与脚本

| # | 路径 / 类型 | 改什么 |
|---|---|---|
| D1 | `tests/v0_4_contract.sh` 等 | 若 strings/调用假定旧 argv，改为新约定 |
| D2 | `tests/setup.sh` / `cli.sh` / rootfs 相关 | 不直接起 agent 则至少安装产物检查 unit 模板 |
| D3 | 任何手工 QEMU/VMware 脚本 | `pre-init` / `first-boot` |
| D4 | CI 若有 agent 冒烟 | 无子命令必须 fail |

#### E. 明确不改（避免误伤）

| 项 | 原因 |
|---|---|
| `nodeforge-initrd` 的 `single_threaded` / 无 pthread | 见 §6；与子命令无关 |
| install first-boot **plan** 协议 | 另一路径；本版 inspect 不做 install |
| 管理 CLI `nodeforge` 命令树 | 不改 |
| archive/ 下历史验证记录 | 只读快照，不回写 |

#### F. 发版检查单（勾选）

```text
[ ] agent 无子命令 → exit 2
[ ] initrd 源码 argv = pre-init
[ ] firstboot.service ExecStart = … first-boot
[ ] zig build 产物 unit 已更新
[ ] 新 initrd 资产已 build 并挂到测试 boot_bundle
[ ] 新 rootfs 含新 agent + 新 unit（或明确仅测新 profile）
[ ] r97n1（或等价）diskless 冷启动：pre-init → systemd → first-boot 成功
[ ] inspect 在已启动 diskless 上 root 可跑
[ ] 文档 C1–C7 已改
[ ] 旧 initrd + 新 agent 组合已在文档标为不支持
```

---

## 4. 完成标准

1. diskless 节点 root 执行 `nodeforge-agent inspect`，JSON 含 `node_id`、`rootfs_input_digest` 或 `plan_digest` 等 AgentPlan 实有字段；`profile` 为 null 可接受。  
2. 无 boot.json 的机器 → exit 1。  
3. 非 root → exit 2。  
4. 无 token/密钥泄漏；不访问网络管理 API。  
5. `pre-init` / `first-boot` **仅**子命令形式可用；旧 argv 拒绝。  
6. §3.3 清单 A–F 完成（含新 initrd + 新 rootfs/unit 联调 boot）。  
7. `version`/`help` 可用。

---

## 5. diskless initrd 如何构建？（现状说明）

实现入口：`src/provision/initrd_build_executor.zig`（`nodeforge assets initrd build …` → daemon worker）。

### 5.1 流水线（摘要）

```text
1. 准备 work 目录
2a. 有 vendor installer initrd（来自 ISO / install source）
    → 不解包重打 vendor 成员（防宿主 libc 混进发行版 initrd）
    → 只搭 NodeForge overlay 根
2b. 无 vendor 基底
    → dracut --no-hostonly（network base + squashfs/overlay 等）→ 解包为根
3. 注入 nodeforge-initrd → /usr/sbin/nodeforge-initrd
4. 注入 同目录构建的 nodeforge-agent → /usr/sbin/nodeforge-agent
5. 注入最小 DHCP hook 脚本（udhcpc/dhclient 脚本）
6. 将 nodeforge-initrd 安装为 /init（PID 1，不用 #!/bin/sh wrapper）
7. 预创建 /capsule 等目录
8. 打 gzip/newc overlay；有 vendor 时：vendor initrd 字节作前缀 + overlay 第二 member
```

运行时：`/init`（nodeforge-initrd）拉 rootfs → overlay → 把 initrd 内 agent **再 cp 到 merged root** `/usr/sbin/nodeforge-agent` → `execve(agent, pre-init 子命令)`（v0.4.3 起）。

### 5.2 是否支持「导入 pthread」？

| 问题 | 结论 |
|---|---|
| 当前 initrd/agent 是否链 pthread？ | **否**。`build.zig` 对二者 `single_threaded=true`，产物仅 `NEEDED libc`（r97n0 实证） |
| 构建器会不会往 initrd 里塞 libpthread.so？ | **不会**。overlay 只拷贝 **nodeforge 自有二进制 + 文本 hook**，明确 **禁止** 用宿主 `dracut-install` 拉 libc/pthread（防 Rocky 版本混配） |
| 若强行 agent/initrd 关闭 single_threaded？ | 链接可能出现 `NEEDED libpthread.so.0`；**vendor initrd 或 dracut fallback 不保证提供该 .so** → 早期 PID 1 / pre-init **加载失败** 风险高 |
| 正确做法若需要线程 | **仅**对运行在 **完整 rootfs 用户态** 的二进制考虑线程；**initrd 内 `/init` 与 pre-init 保持无 pthread**。0.4.4 本机构建若需线程，也只影响「运维场景 agent」，且依赖 **目标盘上完整 glibc**，与 initrd 闭包分离 |

**产品裁决：**

- **initrd：始终 single_threaded**，不导入、不依赖 pthread。  
- **agent：Linux 构建主机默认允许多线程**（`single_threaded=false`）；非 Linux 交叉默认单线程；可用 `-Dagent-single-threaded=` 覆盖。详见 `build.zig`。

---

## 6. 裁决摘要

1. **仅 diskless 本地 inspect**；install 不考虑。  
2. **字段严格映射 AgentPlan + session-id 文件**；无 profile 字段则 null。  
3. **只读本机**；不连 nodeforged。  
4. **子命令硬切、不兼容旧 argv**；§3.3 全量调整清单 + 发版检查单。  
5. **initrd = vendor/dracut 基底 + NodeForge overlay**；**不支持/不引入 pthread**。  
6. **构建能力在 0.4.4**（nodeforge 备料 + 节点 agent 执行）。

---

*v0.4.3 唯一设计入口。*
