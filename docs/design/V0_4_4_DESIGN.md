# NodeForge v0.4.4 设计：指定节点本机 rootfs 构建（nodeforge 备料 + agent 执行）

状态：**设计中**（v0.4.4 唯一设计入口；实现前评审）

## 0. 定位（收敛后）

| 角色 | 职责 |
|---|---|
| **`nodeforge`（管理节点）** | 指定「哪台节点做构建」、把 **ISO/受管源/构建所需配置与材料** 同步到该节点工作区；构建完成后 **收集本地产物并 register 进 nodeforged** |
| **`nodeforge-agent`（目标节点）** | **只在本机执行**：基于已同步材料做 **rootfs 构建**、**rootfs staging（装驱动等）**、**基于 stage 再打包**；**不**暴露/依赖管理 API 做 register |
| **`nodeforged`** | 权威 catalog/CAS；**仅**接受来自管理面（nodeforge）的 register，**不对计算节点开放 import 管理口** |

形态：agent **手动子命令**、非常驻；**无**「远端代建双模」、**无**计算节点持 admin_key 打管理 API。

```text
管理节点                         计算节点
nodeforge ──────────────────►  同步 work 区（ISO/repo/配方…）
nodeforge 指定 build 节点
                                 nodeforge-agent rootfs build / staging …
                                 产出本地 squashfs + 可选 staging 树
nodeforge 收集 ◄──────────────── 拉回产物
nodeforge → nodeforged register  （管理面本机 API，仍可 127.0.0.1）
```

---

## 1. 目标与非目标

### 1.1 目标

1. **nodeforge** 提供「指定节点 + 同步构建材料」能力（§3）。  
2. **agent** 在节点上仅执行 rootfs 相关动作（§4）：  
   - 基于已备料目录构建 rootfs  
   - rootfs staging enter/exec（装驱动）  
   - 基于 stage 再构建 rootfs（from-staging）  
3. **nodeforge** 负责取回产物并 **register** 到 nodeforged（§5）。  
4. 与 v0.4 / v0.4.1 构建与 staging **语义一致**（复用库，不第二套规则）。  
5. agent 沿用 v0.4.3 **强制子命令 + root-only** 骨架（`rootfs …`；**无**旧 argv 兼容）。

### 1.2 非目标

| 非目标 | 说明 |
|---|---|
| 计算节点调用管理 API / 持 admin_key | register 只在管理节点 |
| agent 做 ISO 导入进 catalog | **nodeforge 备料**时处理 ISO/源；agent 只消费已同步目录 |
| agent 改 profile / 节点生命周期 | 管理面 |
| 克隆 / 恢复本地盘 | v0.4.5 |
| 常驻服务、自动调度集群 | 手动指定节点 |
| 运维诊断大礼包、复杂 GC 策略 | 最小功能集 |

### 1.3 回答：不「在 agent 上 import ISO」能否构建 rootfs？

**能。**  
构建需要的是 **install source 内容**（repodata / casper 层等）和 **profile 构建输入**，不是 agent 再跑一遍 `assets import` 写 catalog。  
流程是：**nodeforge 把 ISO 解开/同步后的源树 + 配方放到节点 work 区** → agent 只读该目录做 dnf/casper/mksquashfs。  
agent **不**负责 catalog 里的 install-source 登记。

---

## 2. 目录（agent 独立布局，不借用 `/opt/nodeforge`）

agent **不**假设自己安装在管理节点 install-root 下。节点侧统一工作根：

```text
--work-root DIR     # 必填（或配置文件必填）；无隐式 /opt/nodeforge

{work-root}/
  meta.json           # nodeforge 写入：profile 名、digest 预期、源布局说明、版本
  sources/            # 同步来的受管源（repo 树 / casper 层等），供本机构建
  catalog-snapshot/   # 可选：只读 catalog 投影，供算 digest / 读 profile 字段
  build/              # agent 构建临时区
  staging/<digest>/   # keep-staging 保留树
  out/                # 产出
    <digest>.squashfs
    <digest>.meta.json  # size、sha512、digest、profile、创建时间
```

- **nodeforge** 负责创建/填充 `sources/`、`meta.json`、可选 snapshot。  
- **agent** 只认 `--work-root`，不写集群路径。  
- diskless 节点：work-root 应落在 **有足够空间的可写盘**（数据盘等）；空间不足即失败（ENOSPC），不另造产品码。

---

## 3. nodeforge 侧（备料 + 收集 register）

> 具体 CLI 名实现时可落在现有资源树下，语义如下（设计契约）。

### 3.1 指定构建节点并同步材料

```text
nodeforge profile rootfs prepare-remote <profile> --node <node-id> --work-root <远端路径>
  # 或等价：--target host:/path 经 ssh
```

**行为（设计要求）：**

1. 在管理面解析 profile → 计算/校验 `rootfs_input_digest` 所需输入。  
2. 将构建所需材料同步到目标节点 `{work-root}`：  
   - 受管 **HTTP 可拉** 时：meta 中写明 **本集群 artifacts HTTP 基址**（仅受管源 URL 列表），agent 构建时用 HTTP 取包/层（见 §4.3）；和/或  
   - **直接同步** ISO 展开树 / repo / casper 文件到 `sources/`（大、但离线友好）。  
3. 写入 `meta.json`（profile、digest、source 布局、agent 最低版本等）。  
4. **不**在此步要求 agent 已跑完 build。

传输手段（ssh/rsync/scp）为实现细节，须可重复、可失败重试；设计不绑死某一种。

### 3.2 收集并 register

```text
nodeforge profile rootfs collect-remote <profile> --node <node-id> --work-root <远端路径>
```

**行为：**

1. 从节点取回 `out/<digest>.squashfs` + `out/<digest>.meta.json`（及可选 kernel 文件）。  
2. 本机（管理节点）对 **nodeforged 本机管理 API** 做 **register**（扩展或复用现有 artifact 发布路径）：深验、CAS、索引。  
3. 成功后集群与「管理节点本地 build 发布」等价。  

**不**在计算节点上调用管理 API。

---

## 4. agent 侧（只执行）

### 4.1 子命令（接 v0.4.3 骨架）

```text
sudo nodeforge-agent rootfs build   --work-root DIR [--keep-staging] [--from-staging]
                                    [--kernel-release keep|auto|<r>]
sudo nodeforge-agent rootfs staging enter|exec|kernels|list|show|remove --work-root DIR …
sudo nodeforge-agent rootfs status  --work-root DIR
```

- **必须** `--work-root`（或环境变量 `NODEFORGE_AGENT_WORK_ROOT`，与 flag 二选一，缺则 exit 2）。  
- **不**提供 `rootfs import` 打管理 API。  
- **不**提供 assets import。  
- staging flags 对齐 v0.4.1 能力子集（cgroup 限额等按实现复用，不额外发明）。

### 4.2 功能边界（仅此）

| 能力 | 说明 |
|---|---|
| 构建 rootfs | 读 work-root 内 meta + sources（或 HTTP 受管源），跑 OS 层 + rootfs-build 步骤 + mksquashfs → `out/` |
| rootfs stage | 对 `staging/<digest>` enter/exec，供装驱动 |
| stage 后再构建 | `--from-staging` 再打包写入 `out/` |

不包含：profile CRUD、节点 deploy、ISO catalog 登记、register。

### 4.3 源访问

- **优先 HTTP 受管源**（meta 中 daemon artifacts URL，与集群 local-only 策略一致：只指向本集群 nodeforged 已发布 URL，不随意公网）。  
- 若 prepare-remote 已把树同步到 `sources/`，构建使用 `file://` 本地树。  
- 两种方式由 meta 声明；agent 不自行发现公网 mirror。

### 4.4 线程模型

| 二进制 | 策略 |
|---|---|
| **nodeforge-initrd** | **始终** `single_threaded=true`（最小 initrd 闭包不依赖 libpthread） |
| **nodeforge-agent** | **Linux 构建主机默认多线程**；非 Linux（如 macOS 交叉）默认单线程；可用 `-Dagent-single-threaded=` 覆盖（见 `build.zig`） |

- rootfs 构建流水线本身仍是顺序阶段；开线程只是 **允许** 后续并行，不强制改算法。  
- agent 跑在完整 rootfs 用户态，动态库来自目标系统 glibc，**不是**往 initrd 塞宿主 pthread。  
- **不得**为 agent 开线程而改 initrd 或向 initrd overlay 注入 libpthread。

### 4.5 依赖（与 B1 一起）

agent 构建需要宿主机工具（dnf/unsquashfs/mksquashfs 等）——**由 nodeforge prepare-remote 文档/检查列出**；agent 启动 build 时做存在性检查，缺则明确失败。  
**不**要求 agent 使用 `/opt/nodeforge` 布局。

---

## 5. register（仅管理节点）

- 输入：本地已收集的 squashfs + meta（digest、sha512、profile、可选 kernel）。  
- 处理：nodeforged 现有/扩展发布路径，深验与 CAS 与本机 build 同级。  
- 幂等：相同 digest+sha512 → already_present。  
- 管理 API **保持仅管理节点可达**（如 127.0.0.1）；与 0.4.3 叙事一致。

---

## 6. 端到端操作序

```text
# 管理节点
nodeforge profile rootfs prepare-remote rocky-…-diskless \
  --node node-01 --work-root /data/nf-build

# 计算节点（SSH）
sudo nodeforge-agent rootfs build --work-root /data/nf-build --keep-staging
sudo nodeforge-agent rootfs staging enter --work-root /data/nf-build
# 装驱动…
exit
sudo nodeforge-agent rootfs build --work-root /data/nf-build --from-staging

# 管理节点
nodeforge profile rootfs collect-remote rocky-…-diskless \
  --node node-01 --work-root /data/nf-build
# 内部：取回 + register → nodeforged
```

---

## 7. 实现落点

| 位置 | 工作 |
|---|---|
| `nodeforge` CLI | `prepare-remote` / `collect-remote`（名可调整）+ register 调用 |
| `nodeforge-agent` | `rootfs build|status|staging *`，强制 work-root |
| 复用 | rootfs_os_builder、staging_session、build 步骤执行器 |
| nodeforged | 仅管理面 register 路径（若已有 publish 则复用） |
| 测试 | meta/work-root 契约；无 work-root 失败；不测节点调管理 API |
| 文档 | 分工表；HTTP 源 vs 同步树 |

---

## 8. 完成标准

1. prepare-remote 后节点 work-root 材料齐全，agent 仅凭 work-root 能 build 出 squashfs。  
2. staging enter + from-staging 可再产出。  
3. collect-remote + register 后，管理面 rootfs status 可见，与内容哈希一致。  
4. agent **无任何** 管理 API 客户端路径用于 register。  
5. 管理 API 无需对计算网暴露。  
6. pre-init / first-boot / inspect 回归。  
7. 无克隆/恢复；无 agent 侧 ISO catalog import。

---

## 9. 裁决摘要

1. **nodeforge 指定节点、同步材料、收集并 register。**  
2. **agent 只本机 build / stage / from-staging，目录自有 work-root。**  
3. **不 import 管理 API 到计算节点；不双模远端建。**  
4. **不在 agent 上 import ISO 进 catalog**；ISO/源由 prepare 同步或 HTTP 受管源提供，**可以**构建 rootfs。  
5. **initrd 始终单线程**；**agent 在 Linux 本机构建默认允许多线程**（见 `build.zig`）。  
6. **运维面保持短**：备料 → 执行 → 收集 register。

---

*v0.4.4 唯一设计入口。*
