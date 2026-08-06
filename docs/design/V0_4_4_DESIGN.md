# NodeForge v0.4.4 设计：指定节点本机 rootfs 构建（nodeforge 备料 + `nodeforge-builder` 执行）

状态：**设计中**（v0.4.4 唯一设计入口；实现前评审）

## 0. 定位（收敛后）

| 角色 | 职责 |
|---|---|
| **`nodeforge`（管理节点）** | 指定「哪台节点做构建」；**同步 `nodeforge-builder` 二进制 + meta + 源访问契约**到节点 work 区；构建完成后 **收集产物并 register 进 nodeforged** |
| **`nodeforge-builder`（目标节点，按需下发）** | **只在本机执行**：rootfs 构建、staging（装驱动等）、from-staging 再打包；**不**调用管理 API 做 register |
| **`nodeforge-agent`** | **不参与**本版构建；保持 v0.4.2 生命周期面（pre-init / first-boot / install-first-boot / inspect）瘦身 |
| **`nodeforged`** | 权威 catalog/CAS；**仅**接受管理面 register；**不对**计算节点开放 import 管理口 |

形态：builder **手动子命令、非常驻**；**默认不烤进 diskless/install rootfs**；由 `prepare-remote` 下发到 work-root。  
**无**「远端代建双模」、**无**计算节点持 admin_key。

```text
管理节点                              计算节点（build 节点）
nodeforge prepare-remote ──────────►  同步：
                                        - bin/nodeforge-builder
                                        - meta.json
                                        -（可选）catalog-snapshot /
                                          离线 sources 缓存
                                      nodeforge-builder rootfs build …
                                      产出 out/<digest>.squashfs
nodeforge collect-remote ◄──────────  拉回产物（大文件契约见 §6）
nodeforge → nodeforged register       （管理面本机 API）
```

### 0.1 与 v0.4.2 版本关系

| 版本 | 关系 |
|---|---|
| **v0.4.2** | agent **子命令硬切** + inspect；**必须先落地**（install-first-boot 含在内） |
| **v0.4.3** | OS 层 minimal/full；builder **复用**同一套 OS 层 / digest 规则 |
| **v0.4.4** | 本文件：指定节点构建 + 独立 builder 二进制 + collect |

实现顺序建议：**0.4.2 → 0.4.3 → 0.4.4**。

---

## 1. 目标与非目标

### 1.1 目标

1. **nodeforge** 提供指定节点 + 备料（含 **下发 builder 二进制**）能力。  
2. **`nodeforge-builder`** 在节点上仅执行：  
   - 基于 meta 声明的 **HTTP 受管源**（默认）构建 rootfs  
   - rootfs staging enter/exec  
   - `--from-staging` 再打包  
3. **nodeforge** 取回产物并 **register** 到 nodeforged。  
4. 与 v0.4 / v0.4.1 / v0.4.3 构建与 staging **语义一致**（复用库，不第二套规则）。  
5. **agent 与 builder 进程分离**：rootfs 构建代码 **不**链进默认部署的 `nodeforge-agent`。

### 1.2 非目标

| 非目标 | 说明 |
|---|---|
| 计算节点调用管理 API / 持 admin_key | register 只在管理节点 |
| builder 做 ISO 导入进 catalog | prepare 侧处理；builder 只消费 HTTP 源或已缓存树 |
| builder 改 profile / 节点生命周期 | 管理面 |
| 克隆 / 恢复本地盘 | v0.4.5 → `nodeforge-imager` |
| 常驻服务、自动调度集群 | 手动指定节点 |
| 把 builder 默认烤进每台 diskless rootfs | 体积与攻击面；仅 build 节点按需持有 |

### 1.3 不 import ISO 能否构建？

**能。** 默认路径：**HTTP 受管源**（与节点 diskless 拉 rootfs 同源策略：只指向本集群 nodeforged 已发布 URL）。  
builder **不**负责 catalog 登记。

---

## 2. 二进制拆分与命名

### 2.1 命名裁决

现有族：`nodeforge`（管理 CLI）/ `nodeforged`（daemon）/ `nodeforge-agent`（节点生命周期）/ `nodeforge-initrd`（initrd PID1）。

| 二进制 | 版本 | 语义 | 默认部署到计算节点？ |
|---|---|---|---|
| **`nodeforge-agent`** | ≤0.4.2 定型 | **Agent** = 启动收敛与本机事实查询 | **是**（initrd/rootfs/install handoff） |
| **`nodeforge-builder`** | **0.4.4** | **Builder** = 在指定节点上 **构建** rootfs 制品 | **否**；prepare-remote **按需同步** |
| **`nodeforge-imager`** | **0.4.5** | **Imager** = 磁盘 **镜像** 打包与恢复 | **否**；同类按需下发 |

**为何不用 `nodeforge-agent-rootfs`：**  
「agent」在本项目已固定为 boot/first-boot 角色；把 GB 级构建依赖链进 agent 会污染每台节点的默认 rootfs，并模糊职责。

**为何不用 `nodeforge-worker`：** 过泛，看不出构建/镜像语义。

**CLI 风格：** builder 使用与 agent 相同的 **强制子命令 + root-only** 习惯，但是 **独立 argv0**，不共享 agent 分发器。

```text
sudo nodeforge-builder rootfs build   --work-root DIR …
sudo nodeforge-builder rootfs staging enter|exec|… --work-root DIR …
sudo nodeforge-builder rootfs status  --work-root DIR
sudo nodeforge-builder version|help
```

### 2.2 下发与版本

- prepare-remote **必须**把与管理面 **同构建版本** 的 `nodeforge-builder` 放到  
  `{work-root}/bin/nodeforge-builder`（或 meta 声明的 `builder_path`）。  
- meta 写入：`builder_binary_sha512`、`builder_revision`（与 `ProfileBuildProjection.builder_revision` 对齐）、`min_builder_version`。  
- builder 启动时：校验自身支持的 `builder_revision` ⊇ meta 声明；不匹配 → **fail closed**，不产出。  
- 节点上可残留旧 builder；**以 work-root 内本次下发的二进制为准**（PATH 优先 work-root/bin）。

### 2.3 线程模型

| 二进制 | 策略 |
|---|---|
| `nodeforge-initrd` | **始终** `single_threaded=true` |
| `nodeforge-agent` | 见 v0.4.2 / `build.zig`（生命周期；**不**因本版改线程） |
| **`nodeforge-builder`** | **Linux 默认允许多线程**；非 Linux 交叉默认单线程；可用 build option 覆盖 |

**不得**为 builder 开线程而改 initrd 或向 initrd 注入 libpthread。

---

## 3. 目录（builder 独立 work-root）

```text
--work-root DIR     # 必填（或环境变量 NODEFORGE_BUILDER_WORK_ROOT）；无隐式 /opt/nodeforge

{work-root}/
  bin/
    nodeforge-builder     # prepare 下发，可执行
  meta.json               # 见 §4
  sources/                # 可选：离线/缓存树（§5.2）；HTTP 模式可为空
  catalog-snapshot/       # full 模式 **必填**（software_index 投影）；minimal 可省略若 meta 已内联足够字段
  build/                  # 构建临时区
  staging/<digest>/       # keep-staging
  out/
    <digest>.squashfs
    <digest>.meta.json    # size、sha512、digest、profile、builder_revision、created_at
  collect/                # collect 侧状态（见 §6）：.part、.sha512、manifest
```

- diskless 节点：work-root 必须在 **足够空间的可写盘**；ENOSPC 即失败。  
- staging enter 前提：cgroup v2 + mount namespace 等与 v0.4.1 **相同**；不满足则明确错误（不静默降级）。

---

## 4. `meta.json` 契约（schema）

```json
{
  "schema_version": 1,
  "profile": "…-diskless",
  "rootfs_input_digest": "<hex>",
  "builder_revision": "rootfs-os-v7",
  "min_builder_version": "0.4.4",
  "source_mode": "http",
  "http": {
    "base_url": "http://<nodeforged-artifacts-host>:<port>",
    "repository_urls": ["http://…/repos/…"],
    "casper_layer_urls": ["http://…/casper/….squashfs"],
    "local_only": true
  },
  "os_layer": { "mode": "minimal" },
  "software": { },
  "catalog_snapshot_required": false,
  "expected_out": {
    "squashfs": "out/<digest>.squashfs",
    "meta": "out/<digest>.meta.json"
  }
}
```

| 规则 | 行为 |
|---|---|
| 缺 `schema_version` / 不支持版本 | fail closed |
| `source_mode` 非 `http` / `file` / `http+cache` | fail closed |
| `source_mode=http` 且 URL 非本集群受管前缀 | fail closed（local-only） |
| `os_layer.mode=full` 且无可用 software_index（snapshot 或内联） | fail closed |
| meta 损坏 / digest 与配方不一致 | fail closed，不写 out |

---

## 5. 源访问：**默认仅 HTTP**

### 5.1 默认路径（本版 MVP 必须可交付）

**`source_mode=http`（默认）。**

1. prepare-remote **不必** rsync 整棵 ISO/repo 到节点。  
2. meta 写入本集群 **artifacts HTTP 基址** 与 repository / casper layer URL 列表。  
3. builder 用与管理面构建 **同一语义** 的 dnf/apt/casper 步骤，但源地址为 **HTTP**（节点可达的 nodeforged 制品面，**不是**公网 archive）。  
4. 构建机仍需本地工具：`dnf` 或 `unsquashfs`/`mksquashfs`、`mount`/`umount` 等——prepare 文档列出；builder 启动时存在性检查。

**结论：当前 v0.4.4 可以（且应当）默认只用 HTTP 源。**  
file 同步树 **不是** MVP 前提。

### 5.2 可选：离线 / 弱网

| `source_mode` | 含义 |
|---|---|
| `http` | **默认**；只拉 HTTP 受管源 |
| `file` | 仅 `sources/` 本地树（`file://`）；完全离线 |
| `http+cache` | HTTP 优先；prepare 可预填 `sources/` 作缓存；**meta 声明优先级**，禁止歧义双真源 |

**禁止** builder 自行发现公网 mirror。  
**禁止** meta 同时写两套未声明优先级的真源。

### 5.3 与 v0.4.3 full 的交叉

- full 需要 software_index：prepare **必须** 同步 `catalog-snapshot/`（或等价 index blob），`catalog_snapshot_required=true`。  
- minimal 可只带 digest 计算所需的最小投影。

---

## 6. 大文件 `collect-remote`（完善）

squashfs 可达 **数百 MB～数 GB**。collect 必须是 **可恢复、可校验、可预检** 的传输，而不是「scp 一把梭」的实现细节附录。

### 6.1 产物与旁路文件

```text
out/<digest>.squashfs
out/<digest>.meta.json          # 含 size、sha512、digest、builder_revision
out/<digest>.squashfs.sha512    # 可选冗余；以 .meta.json 为准
```

### 6.2 collect 阶段（管理节点）

```text
nodeforge profile rootfs collect-remote <profile> \
  --node <id> --work-root <远端路径> \
  [--local-staging DIR] \
  [--bandwidth-limit <bytes/s>] \
  [--resume]
```

**强制步骤：**

1. **远端预检**  
   - `out/<digest>.meta.json` 存在且可解析  
   - squashfs 存在且 `size` 与 meta 一致  
   - 远端 `sha512` 已写（builder 完成后必写；未写则 collect 拒绝）  

2. **本机磁盘预检**  
   - 目标目录可用空间 ≥ `size * 1.05 + 预留`（常量或 flag，默认 1 GiB 预留）  
   - 不足 → 明确错误，**不**开始传输  

3. **传输**  
   - 写入本机 `*.squashfs.part`（或 `--local-staging` 下同名）  
   - 支持 **断点续传**（`--resume` 默认 **true**）：按已有 `.part` 大小与远端 size 比较，rsync/`--partial` 或等价  
   - 可选带宽限制，避免打满管理/计算网  

4. **校验**  
   - 传完后本机计算 sha512，与 meta **全等**；失败删除 `.part` 或保留并报错（flag 控制），**不得** register 半成品  

5. **原子发布到管理面 staging**  
   - `.part` → 最终文件名（rename）  
   - 再调 register  

6. **并发**  
   - **默认同管理节点串行 collect**（一把全局锁或 per-profile 锁）  
   - 显式 `--allow-parallel` 才允许多节点并行；文档写明磁盘与网卡风险  

### 6.3 失败与重试

| 场景 | 行为 |
|---|---|
| 传输中断 | `.part` 保留；下次 `--resume` 继续 |
| sha512 不匹配 | 失败；默认删除 `.part`；`--keep-bad-partial` 留存诊断 |
| 远端 build 未完成 | 明确「missing out artifact」，exit ≠ 0 |
| register 失败 | 本机已完整文件可保留，允许重试 register 而不重传 |

### 6.4 传输手段

- 实现可选用 rsync/scp/sftp；**契约**是 §6.2，不绑死单一工具。  
- 验收：≥1 次 **人为中断后 resume 成功** + **损坏文件 sha 失败不 register**。

---

## 7. nodeforge 侧命令（语义）

### 7.1 prepare-remote

```text
nodeforge profile rootfs prepare-remote <profile> --node <node-id> --work-root <远端路径>
```

1. 解析 profile，算/校验 `rootfs_input_digest`。  
2. 写 meta.json（§4）；默认 `source_mode=http`。  
3. 同步 `bin/nodeforge-builder`（同版）。  
4. full 时同步 catalog-snapshot。  
5. **不**要求 builder 已跑完。

### 7.2 collect-remote

见 §6；成功后对本机 nodeforged **register**。

### 7.3 端到端序

```text
# 管理节点
nodeforge profile rootfs prepare-remote rocky-…-diskless \
  --node node-01 --work-root /data/nf-build

# 构建节点（SSH）
sudo /data/nf-build/bin/nodeforge-builder rootfs build \
  --work-root /data/nf-build --keep-staging
# staging / from-staging 同理

# 管理节点
nodeforge profile rootfs collect-remote rocky-…-diskless \
  --node node-01 --work-root /data/nf-build
```

---

## 8. register（仅管理节点）

- 输入：本机已校验的 squashfs + meta。  
- 深验、CAS、索引与本机 build 同级。  
- 幂等：相同 digest+sha512 → already_present。  
- 管理 API 保持仅管理节点可达。

---

## 9. 实现落点

| 位置 | 工作 |
|---|---|
| `build.zig` | 新产物 `nodeforge-builder`（链接 rootfs/staging 库；**不**改 agent 依赖面） |
| `src/builder.zig`（或等价） | 子命令入口、meta 校验、HTTP 源构建 |
| `nodeforge` CLI | prepare-remote / collect-remote + §6 |
| 复用 | rootfs_os_builder、staging_session、diskless digest |
| nodeforged | 管理面 register（复用 publish 若已有） |
| 测试 | meta fail closed；无 work-root 失败；HTTP local-only；collect resume/sha；**agent 二进制体积不因本版暴涨** |
| 文档 | 分工表；builder vs agent；collect runbook |

---

## 10. 完成标准

1. prepare-remote 后节点 work-root 含 **同版 builder + 合法 meta**；默认 **无**整树 ISO 同步亦可 build（HTTP 可达时）。  
2. builder 仅凭 work-root 产出 squashfs + sha512 meta。  
3. staging enter + from-staging 可再产出。  
4. collect-remote：**预检空间**、**resume**、**sha512 失败不 register**；成功后管理面 rootfs status 可见。  
5. builder **无** 管理 API register 客户端路径。  
6. **默认 rootfs/agent 路径不包含 builder**；agent 回归不受构建依赖拖累。  
7. full 缺 snapshot → fail closed。  
8. 无克隆/恢复；无节点侧 ISO catalog import。

---

## 11. 裁决摘要

1. **指定节点构建 = nodeforge 备料/收集/register + `nodeforge-builder` 本机执行。**  
2. **`nodeforge-agent` 不承载 rootfs 构建**；保持瘦生命周期面。  
3. **命名：`nodeforge-builder`（0.4.4）/ `nodeforge-imager`（0.4.5）**；按需下发，默认不部署到全体节点。  
4. **默认 `source_mode=http` 即可交付**；整树 file 同步为可选离线模式。  
5. **collect 必须支持空间预检、断点续传、内容哈希校验与并发控制。**  
6. **meta.schema_version + builder_revision 协商 fail closed。**  
7. **initrd 始终单线程**；builder 在 Linux 上默认可多线程。

---

*v0.4.4 唯一设计入口。*
