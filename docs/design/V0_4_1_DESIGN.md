# NodeForge v0.4.1 设计：Rootfs Staging 会话环境

状态：**已实现**（v0.4.1 实现完成；本文件为 v0.4.1 唯一设计入口）

v0.4.1 在 v0.4 已落地的 **可选 rootfs staging 保留 / from-staging 再打包** 之上，增加管理节点侧的 **staging 会话环境**（`enter` / `exec`）：在保留的解包树上以近似实机的命名空间与挂载矩阵打开可交互 shell 或执行脚本，支持复杂驱动/软件（含 Lustre 等会在树内产出新内核的场景），再通过既有 `--from-staging` 发布 ready squashfs。

**不改变** v0.4 强制边界：

- rootfs **只**由 `nodeforged` 所在管理节点生成；
- diskless 节点 **只**消费 ready squashfs；
- 保留树 **不是** 交付物，initrd **不得** chroot 到管理节点保留树；
- 不提供预制 squashfs import，也不引入节点侧构建。

与 v0.4 的关系：v0.4 交付「能保留树 + 能重打包」；v0.4.1 交付「在树内安全、可复现地做运维特需操作」。v0.4 发布闸不依赖本文件。

---

## 1. 问题与目标

### 1.1 现状缺口

v0.4 已支持：

```text
profile rootfs build … --keep-staging   → work/rootfs-staging/<digest>/
profile rootfs build … --from-staging   → 对保留树 mksquashfs + 深验
profile rootfs staging list|show|remove
```

操作员若要在保留树里安装驱动、编译模块、跑厂商 installer，只能自行 `chroot`/`unshare`，并手工处理：

| 缺口 | 影响 |
|---|---|
| 挂载不全（缺 `/dev` rbind、devpts、cgroup、run/tmp…） | `dracut`/`depmod`/`udevadm`/DKMS/部分厂商脚本失败或静默错结果 |
| 无统一会话入口 | 每次手工命令不一致，易在 host 上残留挂载 |
| 无可控交互 shell 契约 | 无法约定如何进入/退出、如何清理、如何并发保护 |
| 树内换核后启动面不同步 | Lustre 等装包可能生成新 `vmlinuz` + `/lib/modules/<release>`，仅 `--from-staging` 打 squashfs **不会**自动让 diskless boot 使用新内核 |
| 正式 build 的 local-only 源 vs 会话装官方 HTTP 包 | 运维特需需要 HTTP 源；量产仍应用受管源 |

### 1.2 产品目标

1. 基于 **已保留的 rootfs stage 树**，提供一等公民的 **会话环境**（不是第二套 rootfs 构建路径）。
2. **最大化模拟实机**：需要 mount 的尽量 mount（含 device、cgroup）；命名空间尽量全面，但 **默认不隔离网络**（共享宿主机 net ns，直接使用 host 连通性与 HTTP repo）。
3. 支持 **交互式 shell** 与 **非交互脚本**（编译、装包、跑 installer）。
4. 会话结束后树内变更可被 `--from-staging` 打包；**新内核可被识别并导入启动面**（见 §6），且 **不破坏** 既有 diskless initrd 契约。
5. **不依赖** 第三方容器运行时（Docker/Podman/systemd-nspawn 非硬依赖）；实现基于 Linux `unshare` / `mount` / `chroot` 与现有 `namespaced_chroot_executor` 同族原语（**仅 chroot**，见 §3.2 / 延期清单）。

### 1.3 非目标（v0.4.1）

| 非目标 | 说明 |
|---|---|
| 完整虚拟机 / KVM guest | 不模拟独立机器启动；不跑完整 systemd 作为 session PID 1 |
| 网络命名空间 + veth/NAT | 用户明确暂不需要；默认共享 host net |
| 将 host 的 kernel-devel 注入 stage | 编译/装包使用 **树内** 的 kernel / kernel-devel / 发行版包 |
| 在计算节点或 initrd 内 enter | **整条会话能力只在管理节点**；见 §3.0（`nodeforge` CLI，不经 `nodeforged`） |
| 把会话步骤自动写回 Profile `rootfs-build` | 本版不自动生成可复现配方 |
| 非 Linux 管理节点上 enter | 会话依赖 Linux `unshare`/`mount`/`chroot`；必须在跑 Linux 的管理节点本机执行 |
| **`pivot_root` 切根** | **移出 v0.4.1**；仅 `chroot`。记入遗留 [`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md) `V041-D01` |
| **顶层 `nodeforge rootfs …`** | 违背既有 **资源-动作树**（rootfs 归属 Profile）；**不引入、不改树**。正式 CLI 仍是 `profile rootfs staging …`。见 §3.5 |

---

## 2. 概念模型

```text
                    Profile build projection
                              │
                              ▼
              rootfs build (nodeforged worker)
                              │
              ┌───────────────┴───────────────┐
              │ keep_staging                  │ ready squashfs (CAS)
              ▼                               ▼
   work/rootfs-staging/<digest>/     content-addressed artifact
              │
              │  v0.4.1：profile rootfs staging enter | exec
              ▼
   会话内：挂载矩阵 + ns + chroot（唯一切根方式）
   操作员：dnf/apt、编译、厂商脚本、装 Lustre…
              │
              │ 树内可能新增：
              │  /boot/vmlinuz-*  /lib/modules/<release>/
              │  用户态文件、配置、驱动
              ▼
   detect kernels（可选 / 再打包时）
              │
              ▼
   profile rootfs build --from-staging
   + 可选 kernel import 到 catalog / boot 面
              │
              ▼
   新 ready squashfs（同 rootfs_input_digest 可 replace）
   diskless 节点只下载该 squashfs + 既有 BootConfig 路径
```

| 术语 | 定义 |
|---|---|
| **保留树 / staging tree** | `work/rootfs-staging/<rootfs_input_digest>/`，完整可 chroot 的根文件系统树 |
| **staging 会话** | 针对某一保留树的一次 `profile rootfs staging enter` 或 `exec`；有生命周期、锁、挂载、步骤日志与清理契约 |
| **会话根** | 切根后的 `/`，即保留树内容 |
| **启动面** | diskless 启动用的 kernel / initrd / BootConfig 资产链（**不是** squashfs 内的用户态根） |
| **树内核** | 保留树内 `/boot`、`/lib/modules` 中的内核与模块；进入 squashfs 后成为节点用户态侧材料，**默认不自动成为 PXE 启动内核** |

---

## 3. 进程归属、shell、CLI 与可观测性

### 3.0 这是 `nodeforge` 还是 `nodeforged`？

**结论：v0.4.1 的 enter / exec / kernels 是管理节点上的 `nodeforge`（CLI）本机特权能力，不跑在计算节点，也不经 `nodeforged` HTTP worker 做交互。**

| 组件 | 与本功能的关系 |
|---|---|
| **`nodeforge` CLI** | **正式实现面**：root 在管理节点直接 `unshare` + 挂载 + `chroot`，打开 TTY 或跑命令 |
| **`nodeforged`** | **不参与会话进程**。它仍负责此前的 `rootfs build` / keep-staging 产出保留树；from-staging 打包若继续走既有 build API 则仍是 daemon worker |
| **计算节点 / initrd** | **完全不涉及**。禁止在节点或 initrd 里提供 enter |

前置条件：保留树已由 `nodeforged` 的 build（`--keep-staging`）写好；CLI 通过 install-root 下的索引/路径找到树后本地进入。  
因此「仅管理节点、仅保留树」= **运维在 r97n0 上对磁盘上的解包树操作**，不是 daemon 远程下发会话。

### 3.1 cgroup 要不要加？——**要，作为默认挂载矩阵的一部分**

**结论：默认挂载 cgroup（优先 cgroup v2），建议视为「需要」。**

| 理由 | 说明 |
|---|---|
| 实机感 | 现代发行版用户态与部分安装脚本假设 `/sys/fs/cgroup` 存在 |
| 编译与长任务 | 可在会话上挂资源上限（CPU/memory），避免一次错误编译拖死管理节点 |
| 驱动/容器化软件 | 部分工具探测 cgroup 控制器；缺失时行为分叉或失败 |
| 与 systemd 工具链 | 即便不把 systemd 当 PID 1，`systemctl`/`systemd-detect-virt` 等探测路径更接近真机 |
| 实现成本 | 在已有 mount ns 内多几条 mount，远低于引入完整容器运行时 |

**默认策略：**

1. 若宿主为 **cgroup v2 统一层级**（`/sys/fs/cgroup` 为 cgroup2）：  
   - 在会话内 `mount -t cgroup2 none <root>/sys/fs/cgroup`（或 bind 宿主 cgroup2 再可选委派子树）。  
2. 若宿主仍为 **hybrid / v1**：  
   - 至少挂载会话可用的 v1 控制器子集，或 bind 宿主 `/sys/fs/cgroup`（实现选型见 §5.3）；文档标明能力降级。  
3. **本版要做** 会话级 cgroup 资源限额 CLI（`--memory-max` / `--cpu-max` 等），见 §3.6；与「挂载可见」同属 v0.4.1 完成闸。  
4. **不做** 完整的「容器 runtime 级 cgroup 委派 + 嵌套 docker」保证；嵌套容器属 best-effort。

**何时可以关掉：** `--no-cgroup`（调试或宿主无 cgroup 权限时），但默认开启；关闭时日志 warning，且 **不得** 再接受限额参数（互斥 fail closed）。

### 3.2 切根：仅 chroot（`pivot_root` 遗留 `V041-D01`）

把进程看到的「根目录 `/`」换到保留树，v0.4.1 **唯一**实现方式是 **`chroot`**。

| | **chroot（本版）** | **pivot_root（遗留，不做）** |
|---|---|---|
| 做什么 | 把**当前进程**的根改成某目录；旧根在持有 fd / `..` 等情况下仍可能被访问 | 把新根「转」上来并卸旧根，隔离更干净 |
| 隔离强度 | 够用装包/编译；不是安全沙箱 | 更强（容器/initramfs 切根常用） |
| 依赖 / 复杂度 | coreutils/`chroot` 几乎总有；实现简单 | util-linux + 正确 pivot/umount；复杂度高 |

**裁决（2026-08-06）：**

- v0.4.1 **只实现 chroot**；产品命令是 `profile rootfs staging enter` / `exec`，操作员**不必**手敲 `chroot`。  
- **`pivot_root` 移出本版**：不进入任何实现分期，不写发布闸；状态见 [`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md) `V041-D01`。  
- 文档与代码 **不得** 预留未消费的 pivot 开关/enum 作为「半实现」。

### 3.3 enter 如何打开可交互 shell（机制）

本质：**当前终端的 stdin/stdout/stderr（TTY）原样交给「已切根的 bash」**，不是起一个后台 daemon 再连进去。

```text
你的 SSH/本地终端
        │  同一 TTY（/dev/pts/N）
        ▼
   nodeforge (root, 管理节点本机)
        │  校验索引、加锁、打步骤日志
        ▼
   unshare( mount,pid,uts,ipc ) + fork
        │  子进程在新 mount/pid ns 里
        ▼
   mount 矩阵（proc/sys/dev/cgroup…）
        ▼
   chroot(保留树)
        ▼
   execve("/bin/bash", ["-bash"], env)   ← 进程镜像变成 bash
        │
        ▼
   你看到 bash 提示符；键入由 bash 读 TTY
   exit / Ctrl-D → bash 退出 → 父进程清理挂载 → nodeforge 结束
```

要点：

1. **交互 = 继承 TTY**：`nodeforge` 不自己实现终端模拟；`isatty(0)==true` 时 bash 进入交互模式。  
2. **`execve` 进 shell**：会话内前台就是 shell，Ctrl-C 由 shell/子进程处理。  
3. **挂载在 shell 之前完成**：你进 shell 时已经是「像真根」的环境。  
4. 从远程 SSH 到管理节点再 `nodeforge profile rootfs staging enter`，TTY 经 SSH 转发即可，**不需要** WebSocket。

### 3.4 enter 与 exec：v0.4.1 **都做**；不做 WebSocket / 远程 TTY

| 命令 | v0.4.1 | 含义 |
|---|---|---|
| **enter** | **做** | 交互式：打开 TTY shell，人肉操作 |
| **exec** | **做** | 非交互：跑一条命令/脚本后退出（CI、一键装包） |

**不做** WebSocket / 远程 TTY：交互终端只在本机 `nodeforge` CLI 上（TTY 即当前终端），不把交互 shell 做成 `nodeforged` 上的网页/远程 TTY 服务。

### 3.5 CLI 路径：沿用 `profile rootfs …` 资源树（不引入顶层 `rootfs`）

NodeForge CLI 是 **资源-动作树**（`profile` / `node` / `assets` / …）。rootfs 制品与保留树归属 **Profile**，v0.4 已落地：

```text
profile rootfs plan|build|status
profile rootfs staging list|show|remove
```

**裁决（2026-08-06）：**

| 提案 | 结论 |
|---|---|
| 顶层 `nodeforge rootfs …`（含 enter/exec/kernels 等短名） | **不合适**；把 rootfs 抬成与 `profile`/`node` 同级顶层资源，**违背**既有资源-动作树与 ownership 规则 |
| 是否为「好打字」改树 | **不改**。正式入口继续挂在 `profile rootfs staging …` 下 |

| 用途 | **正式命令** |
|---|---|
| 交互 shell | `nodeforge profile rootfs staging enter <profile>` |
| 非交互命令 | `nodeforge profile rootfs staging exec <profile> -- <cmd>...` |
| 列 / 查 / 删保留树 | `nodeforge profile rootfs staging list\|show\|remove`（v0.4 已有） |
| 扫树内核 | `nodeforge profile rootfs staging kernels <profile>` |
| 再打包 | `nodeforge profile rootfs build <profile> --from-staging`（与 build 同族） |

示例：

```text
sudo nodeforge profile rootfs staging enter rocky9-diskless
sudo nodeforge profile rootfs staging exec rocky9-diskless -- dnf -y install lustre-client
sudo nodeforge profile rootfs staging kernels rocky9-diskless
```

help / `cli/REFERENCE` / 完成闸只认上述长路径；**不得**注册未文档化的顶层 `rootfs` 别名作为正式面。

### 3.6 资源 cgroup 限额参数（**本版要做**）

**挂载 cgroup** 与 **给会话加配额** 是两件事：前者让树内「看得到 cgroup」；后者限制这次会话能吃多少宿主资源。二者 **均在 v0.4.1 交付**，不记入延期。

| CLI 参数 | cgroup v2 对应 | 作用 | 首版 |
|---|---|---|---|
| `--memory-max <size>` | `memory.max` | 会话内 RSS+cache 上限，保护管理节点内存 | **要做** |
| `--memory-swap <size>` | `memory.swap.max` | 交换区上限（可 `0` 禁止 swap） | **要做** |
| `--cpu-max <percent>` 或 `quota/period` | `cpu.max` | 限制编译/多线程别占满所有核 | **要做** |
| `--pids-max <n>` | `pids.max` | 防止 fork 炸弹 / 失控构建脚本 | **要做** |

**本版行为：**

1. 默认挂载 cgroup 层次；若指定任一限额 flag，则创建 **会话专用 cgroup 子树**，把 enter/exec 子进程迁入并写入对应 controller。  
2. 未指定任何限额 flag 时：只挂载可见，**不**强加产品默认配额（宿主运维可用外部 cgroup/systemd 约束 `nodeforge` 进程）。  
3. 宿主为 cgroup v1 / 无写权限时：限额 flag **fail closed**（明确错误），不得静默忽略。  
4. `--no-cgroup` 与任一限额 flag **互斥**。  
5. 步骤日志须打印是否创建了限额子树及生效值（不含无关 host 拓扑 dump）。  
6. help / `cli/REFERENCE` / 完成闸必须覆盖上述参数；**不得**预留空 handler。

### 3.7 步骤日志（强制产品要求）

会话路径步骤多，**禁止「卡住无输出」**。`profile rootfs staging enter` / `exec` 在 human 模式下默认对 **stderr** 打印带阶段前缀的步骤日志；`--output json` 时步骤进 jsonl/结构化事件，不污染 stdout 业务流（若有）。

**最少必须打印的阶段（示例）：**

```text
staging-session: resolve profile=rocky9-diskless digest=abc… path=/var/.../rootfs-staging/abc…
staging-session: lock acquired id=sess-…
staging-session: unshare namespaces=mount,pid,uts,ipc (net=host)
staging-session: mount proc -> …/proc
staging-session: mount sys -> …/sys
staging-session: mount rbind /dev -> …/dev
staging-session: mount cgroup2 -> …/sys/fs/cgroup
staging-session: mount … (每一项成功/跳过/失败都打一行)
staging-session: chroot + exec /bin/bash
# —— 此处开始是用户 shell，nodeforge 不再刷屏 ——
# 用户 exit 后：
staging-session: shell exited code=0
staging-session: cleanup umount …
staging-session: cleanup verify: no leftover mounts on staging tree
staging-session: lock released
staging-session: done
```

规则：

1. **每一步一行**：开始可 `…`，结束 `ok` 或 `FAIL reason=`；  
2. 失败时打印 **已做到哪一步**、保留树路径、如何手工检查（如 `findmnt | grep staging`）；  
3. `exec` 在用户命令开始前/结束后打界标；用户命令自己的 stdout/stderr **原样透传**，不吞；  
4. `--quiet` 可降噪（仅错误+最终结果）；默认 **verbose steps on**；  
5. 不打印 secret、token、完整环境变量 dump（除非 `--debug` 且打码策略允许）。

### 3.8 退出与清理

| 方式 | 结果 |
|---|---|
| shell 内 `exit` / Ctrl-D | shell 退出 → 清理 → 返回 shell 退出码 |
| 被信号杀死（SIGHUP 断 SSH 等） | trap/监督仍清理并校验 |
| `exec` 命令结束 | 返回命令退出码；同样清理 |
| 超时（仅 `exec --timeout`） | TERM → 宽限期 → KILL；清理后超时错误码 |

**清理（fail-closed）：** ns 退出后宿主侧确认 staging 上无残留 bind；残留 → `rootfs.staging_session_cleanup_incomplete`。

```text
进入：sudo nodeforge profile rootfs staging enter <profile>
退出：exit  或  Ctrl-D
```

### 3.9 与「手动 chroot」的差异

| 项 | 手动 chroot | v0.4.1 `profile rootfs staging enter` |
|---|---|---|
| 挂载 | 操作员自理 | 规范矩阵 + 逐步日志 + 校验 |
| 网络 | 视手工 unshare | 默认 = host 网 |
| cgroup 限额 | 自理 | 可选 `--memory-max` / `--cpu-max` / … |
| 清理 | 易残留 | 强制校验 |
| 并发 | 无锁 | 同树会话锁 |
| 内核导入 | 无 | 再打包/显式 detect（§6） |

---

## 4. 网络与软件源

### 4.1 默认：共享宿主机网络（不 unshare net）

```text
unshare --mount --pid --fork --uts --ipc ...   # 不加 --net
→ curl / dnf / apt 使用宿主机路由、NIC、防火墙与 DNS 解析能力
```

这 **不是**「把 host net 再 mount 进来」，而是 **不创建 net ns**。

| 配置 | 行为 |
|---|---|
| 默认 | 共享 host 网络；可访问 host 能访问的 HTTP/HTTPS |

### 4.2 HTTP URL 仓库

| 场景 | HTTP/HTTPS repo | 说明 |
|---|---|---|
| **staging enter/exec 内** | **允许** | 运维特需：官方 Lustre、厂商源、临时 mirror |
| **正式 `profile rootfs build` package 步骤** | 仍按 v0.2/v0.4 **受管 / local-only 闸** | 量产可复现；与会话实验室路径分离 |

会话内 DNS：共享 net 后通常足够；若树内 `/etc/resolv.conf` 为空或无效，会话启动时可 **可选** 从宿主复制一份到 **会话覆盖层**（优先 tmpfs overlay 或 bind-ro 宿主 resolv，避免把宿主 DNS 永久写进保留树——默认 **bind-ro 覆盖**，不修改树内文件；若操作员在会话里 `cp` 则属手改）。

### 4.3 代理与环境变量

- 支持 `--env KEY=VAL` 与继承白名单（如 `http_proxy`/`https_proxy`/`no_proxy`）。
- **禁止** 把管理面 token、bootstrap key 自动注入会话环境。

---

## 5. 命名空间与挂载矩阵

### 5.1 命名空间默认集合

| Namespace | 默认 | 说明 |
|---|---|---|
| mount | **开** | 挂载隔离与清理基础 |
| pid + fork + mount-proc | **开** | 会话内进程树；避免看到宿主全部 PID 的误操作面 |
| uts | **开** | 可设 `NODEFORGE-STAGING` hostname，避免与宿主混淆 |
| ipc | **开** | 与实机隔离 IPC |
| **cgroup ns** | **开（若内核支持）** | 配合 cgroup 挂载，会话视图更干净 |
| **user** | **关（首版）** | 保持 root 在树内映射简单；复杂驱动 installer 常要真实 root |
| **net** | **关（共享 host）** | 见 §4 |
| time | 关 | 无强需求 |

能力：会话进程保持 `CAP_SYS_ADMIN` 等以完成挂载与装包；**不**做 rootless。

### 5.2 挂载矩阵（默认 profile：`full`）

| 目标（会话内） | 类型 | 来源 / 选项 | 必须 |
|---|---|---|---|
| `/proc` | proc | `mount -t proc` | 是 |
| `/sys` | sysfs | `mount -t sysfs` | 是 |
| `/dev` | rbind | 宿主 `/dev`，`rbind,rslave` 或等价 | **是**（复杂驱动） |
| `/dev/pts` | devpts | 新建或确保可用 | 是（交互 TTY） |
| `/dev/shm` | tmpfs | | 是 |
| `/run` | tmpfs | | 是 |
| `/tmp` | tmpfs **或** 树内目录 | 默认 tmpfs，避免编译垃圾永久进树；可用 `--persist-tmp` 用树内 `/tmp` | 默认 tmpfs |
| `/sys/fs/cgroup` | cgroup2 或 bind | 见 §3.1 | **默认是** |
| `/sys/kernel/config` 等 | 按需 | configfs 等，驱动需要时 `--mount-extra` | 否 |
| 宿主源码/ISO 目录 | bind | `--bind host:path` 可重复 | 否 |
| `/etc/resolv.conf` | bind-ro 覆盖 | 可选，默认开启当树内无效时 | 建议 |

实现注意：

- **rbind `/dev`** 后，会话内可见宿主块设备与字符设备；这是装依赖硬件驱动所需要的，也意味着 **会话等同高权限运维操作**（与 root 登录管理节点同级）。
- 与现有 `namespaced_chroot_executor`（仅 bind `/dev,/proc,/sys`）相比，本矩阵是 **超集**；package build 路径 **不必** 一次升到 full，避免扩大 build worker 面。enter/exec 使用 `full`；自动化 rootfs-build 继续用精简矩阵。

### 5.3 切根方式

| 方式 | v0.4.1 | 说明 |
|---|---|---|
| `chroot <staging> <shell>` | **唯一** | 实现简单，与现有 executor 一致；本版完成闸只认 chroot |
| `pivot_root` | **不做** | 更强隔离（看不见旧根）；**已移出本版**，见延期 `V041-D01` |

本版 **chroot 足够** 满足装包/编译；文档 **不承诺** pivot 级隔离，也 **不** 预留 pivot 开关/enum。

### 5.4 服务自启动抑制

默认写入 **仅会话可见** 的 `policy-rc.d`（exit 101）或等价手段，避免 `dnf install` 在会话里拉起真实网络服务污染宿主网络命名空间（因共享 net）。该文件 **不得** 留在最终 squashfs：清理阶段删除，或放在不打包的挂载覆盖中。

---

## 6. 内核、Lustre 与启动面

### 6.1 正确模型（按产品诉求）

操作员在 **stage 会话（已切到树）** 内：

1. 使用 **树内** 包管理器安装与本发行版对应的 `kernel` / `kernel-devel` / 头文件；
2. 安装官方 Lustre 包或源码编译（可能 patch ext4 等并 **在树内生成新内核 RPM/deb 产物**）；
3. 树内出现新的 `/boot/vmlinuz-<release>`、`/lib/modules/<release>/`、initramfs（若生成）等；
4. 退出会话后，**再打包 rootfs**，并 **识别/选择** 用于 diskless 启动的内核。

**不要求** 管理节点 `uname -r` 与树内核一致；**不要求** 在宿主上 `insmod` 验证。能否在管理节点编译取决于树内工具链与源，属于运维环境问题，产品只提供会话与导入路径。

### 6.2 两层「内核」必须分开

| 层级 | 内容 | 谁消费 |
|---|---|---|
| **A. Rootfs 用户态树内** | `/lib/modules`、可选 `/boot` 内文件打进 squashfs | 节点 `switch_root` 之后的用户态；**diskless 启动瞬间仍用 PXE 下发的 kernel** |
| **B. PXE / BootConfig 启动内核** | catalog 中的 `kernel` / `runtime_kernel` 资产 + TFTP/HTTP 启动路径 | firmware → bootloader → 内核 → initrd → 挂 rootfs |

Diskless 路径是：

```text
PXE kernel (B) + nodeforge initrd → 下载 squashfs (含 A) → switch_root 到用户态
```

因此：

- **仅** `--from-staging` 更新 squashfs → 只保证 **A** 进入节点；若 PXE 仍用旧 **B**，可能出现 **启动内核 ≠ 树内模块**（vermagic 不匹配）→ 驱动/Lustre 模块装了却对不上运行中的内核。
- v0.4.1 必须提供 **把树内选定内核提升为启动面资产（B）** 的路径，并在 Profile/Boot 解析中可选使用。

### 6.3 对 diskless initrd 的影响——**默认无影响**

| 组件 | 影响 |
|---|---|
| `nodeforge-initrd` 构建与内容 | **不**因 staging 会话自动重建；契约不变 |
| initrd 内逻辑 | 仍只下载/校验 ready squashfs + plan；**不** chroot 管理节点 stage |
| 何时需要动 initrd | 仅当操作员 **显式** 要求「用新 kernel 重做 boot_bundle / 导入 runtime_kernel」且产品流程触发既有 initrd/kernel 资产更新时 |

**不变式：** staging 会话与 from-staging **不得**静默改写正在服务的 initrd 文件而不改 digest/登记；任何启动面变更必须走 catalog 资产 + 可观测的导入步骤。

### 6.4 内核发现与选择

会话后或再打包前：

```text
nodeforge profile rootfs staging kernels <profile>
# 扫描保留树：
#   /lib/modules/*          → module releases
#   /boot/vmlinuz-*         → images
#   /boot/initramfs-*|initrd-* → 可选
```

再打包时：

```text
nodeforge profile rootfs build <profile> --from-staging \
  [--kernel-release <release> | --kernel-release auto | --kernel-release keep]
```

| 模式 | 行为 |
|---|---|
| `keep`（默认） | 不修改启动面内核资产；仅重打 squashfs（与 v0.4 行为兼容） |
| `auto` | 若树内 **恰好一个** 新的、比 Profile 当前记录更新的 release 则选用；0 个或多个候选 → fail closed，要求显式指定 |
| `<release>` | 使用该 `uname -r` 风格 release；树内必须存在对应 modules 目录与 vmlinuz |

### 6.5 导入启动面（B）的规范步骤

选定 `kernel_release` 后，服务端（或本机特权辅助）执行：

1. 从保留树拷出：
   - `vmlinuz` → 登记为 catalog asset（kind：`kernel` 或既有 `runtime_kernel` 语义，与当前 diskless 配置模型对齐）；
   - 若树内已有匹配 initramfs **且** 策略允许复用，可导入；**默认仍优先 nodeforge 受管 initrd 流水线**，避免用发行版 initramfs 替换 nodeforge-initrd；
2. **模块** 已在 squashfs（A）中，一般 **不必** 再单独导入 modules 到 TFTP（节点 switch_root 后从 rootfs 加载）；
3. 更新 Profile / boot 解析使用的 kernel 引用与 `kernel_release` 记录（具体字段落在实现时对照现有 `AssetKind` / Profile 模型，**不**为此发明第二套 diskless 协议）；
4. 若 BootConfig 内容变 → 新 revision / 新 digest；旧会话 fail closed 于既有规则；
5. 输出明确变更摘要：旧 release → 新 release、资产路径、是否触碰 initrd。

**Lustre 场景推荐操作序：**

```text
1. profile rootfs build --keep-staging
2. profile rootfs staging enter → 装 kernel-devel / lustre（树内产出新核）
3. exit
4. profile rootfs staging kernels   # 确认 release
5. profile rootfs build --from-staging --kernel-release <release>
6. 验证 BootConfig / TFTP 文件与 ready squashfs（**管理面**，本版发布闸）
7. 节点 diskless 启动验证模块 vermagic（**节点侧实机**；环境延期 `ENV-V041-KERNEL-VERMAGIC` / `V041-D09`，见 [`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md)）
```

### 6.6 明确不做什么

- 不在 shell 会话中自动改 catalog（避免半会话状态）；
- 不在 from-staging 默认静默换核（默认 `keep`）；
- 不要求 host 与 stage 内核一致；
- 不把「能在管理节点 modprobe 成功」作为发布闸；
- **不把**「换核后节点 vermagic / Lustre-class 实机 E2E」作为 v0.4.1 发布闸（环境延期 `ENV-V041-KERNEL-VERMAGIC`）。

---

## 7. 并发、锁与安全

### 7.1 会话锁

| 规则 | 说明 |
|---|---|
| 粒度 | 每个 `rootfs_input_digest` 一把排他锁（写会话） |
| 持有者 | enter/exec 进程；崩溃后靠 PID 探活 + 超时回收锁文件 |
| 与 build | `from-staging` / full build 提升树时必须与会话互斥 |

锁文件建议：`<install-root>/run/rootfs-staging/<digest>.lock`。

### 7.2 安全边界

- 会话 = **root 级** 运维能力（可见宿主 `/dev`）。
- 仅管理员在管理节点执行；CLI 检查 euid==0（或明确 CAP）。
- 审计：本地 syslog/nodeforge 日志记录 session id、profile、digest、起止时间、argv（exec）。
- 不把 secret 打进会话环境；树内若已有密钥文件，属构建投影既有内容。

### 7.3 与 daemon 的关系

- **enter/exec 不经过、不占用** `nodeforged` 的 durable operation worker（避免堵构建）。

---

## 8. CLI / API 表面

### 8.1 CLI（正式：仅 `profile rootfs …` 资源树，见 §3.5）

**不引入** 顶层 `nodeforge rootfs …`。v0.4 已有与 v0.4.1 增量统一挂在 Profile 下：

```text
# 查询/清理保留树（v0.4 已有）
nodeforge profile rootfs staging list|show|remove …

# v0.4.1 会话与内核扫描
nodeforge profile rootfs staging enter   <profile> [options]
nodeforge profile rootfs staging exec    <profile> [options] -- <cmd>...
nodeforge profile rootfs staging kernels <profile>

nodeforge profile rootfs build <profile> --from-staging \
  [--kernel-release keep|auto|<release>]
```

**enter 主要 options：**

| 选项 | 含义 |
|---|---|
| `--digest <hex>` | 不按 profile 当前 digest，而按指定保留树 |
| `--shell <path>` | 会话内 shell，默认 `/bin/bash` 回落 `/bin/sh` |
| `--workdir <path>` | chroot 内 cwd |
| `--env K=V` | 可重复 |
| `--bind host:guest` | 可重复，bind 宿主目录 |
| `--no-cgroup` | 关闭 cgroup 挂载（与限额 flag 互斥） |
| `--memory-max <size>` | cgroup v2 `memory.max`（§3.6） |
| `--memory-swap <size>` | cgroup v2 `memory.swap.max` |
| `--cpu-max <spec>` | cgroup v2 `cpu.max`（percent 或 quota/period） |
| `--pids-max <n>` | cgroup v2 `pids.max` |
| `--persist-tmp` | `/tmp` 使用树内目录而非 tmpfs |
| `--hostname <name>` | uts hostname |
| `--quiet` | 减少步骤日志（默认打印完整步骤，§3.7） |

**exec 额外：**

| 选项 | 含义 |
|---|---|
| `--timeout <sec>` | 超时 |
| `--script <host-path>` | 将宿主脚本 bind 到固定路径后执行 |

退出码：透传命令/shell；清理失败使用稳定业务码（实现时写入 `cli/REFERENCE` 与 `--help-full`）。

---

## 9. 实现架构（建议落点）

| 模块 | 职责 |
|---|---|
| `src/provision/staging_session.zig`（新） | 渲染会话 wrapper：ns、挂载矩阵、cgroup 挂载与限额子树、清理、enter/exec |
| 扩展 `namespaced_chroot_executor.zig` **或** 共享 mount 表 | 避免两套挂载语义漂移；build 用 `minimal`，session 用 `full` |
| `src/state/rootfs_staging_store.zig` | 锁路径辅助、可选 session 元数据 |
| `src/main.zig` CLI | `profile rootfs staging enter` / `exec` / `kernels` + 步骤日志 + 限额 flag |
| `src/provision/staging_kernel_import.zig`（新） | 扫描树、拷贝 vmlinuz、更新资产/Profile 引用（from-staging 钩子） |
| 测试 | wrapper 脚本文本契约测试（与现有 executor 相同策略）；cleanup 负向；kernel scan fixture；限额 flag 互斥与 fail-closed |

环境边界：真实 `unshare` 需 root，单元测试测脚本渲染与路径校验；集成测试在 Linux 管理节点或 CI root 作业中跑。

---

## 10. 完成标准（v0.4.1 发布闸）

1. `profile rootfs staging enter` 能在保留树上打开交互 shell；`exit`/Ctrl-D 后无残留挂载，重复进入成功。
2. 默认挂载含 **`/dev` rbind、proc、sys、devpts、cgroup**；文档与 `--help-full` 写清。
3. **cgroup 限额参数**（§3.6）：`--memory-max` / `--memory-swap` / `--cpu-max` / `--pids-max` 生效并可在步骤日志中核对；`--no-cgroup` 与限额互斥 fail closed；cgroup v1/无权限 fail closed。
4. 默认共享 host 网络：会话内可 `curl` 可达的 HTTP URL（环境允许时）。
5. `profile rootfs staging exec` 能非交互执行命令并返回退出码；超时可杀。
6. 同 digest 第二会话/并发 from-staging 被锁拒绝并给出明确错误。
7. `profile rootfs staging kernels` 能列出树内 modules/vmlinuz；`--kernel-release` 显式选择后 from-staging 更新启动面资产（或明确报告已对齐）。
8. 默认 `--kernel-release keep` 时行为与 v0.4 from-staging 一致。
9. diskless **管理面**回归：未换核（`keep`）时不静默改写 initrd/BootConfig/启动核引用；换核路径在管理节点侧可观测（catalog / boot_bundle / artifact `kernel_release` 更新摘要）。
10. **步骤日志默认开启**（§3.7）：失败能看出卡在哪一步；中文模块注释与 README 示例更新。
11. 不引入 Docker/Podman 硬依赖；不引入节点侧构建或 squashfs import；**不经 nodeforged 做交互 shell**。
12. **不引入** 顶层 `nodeforge rootfs …`；help / REFERENCE / 完成闸只认 `profile rootfs staging …`。
13. **不实现** `pivot_root`；切根仅 chroot（遗留 `V041-D01`）。

**不在本版发布闸（环境延期）：**

| 项 | 说明 |
|---|---|
| 换核后 **节点侧** vermagic / Lustre-class 实机闭环 | 树内新 release + 模块 → 启动面导入 → diskless 节点启动并加载模块（vermagic 对齐）。能力与操作序已实现/文档化（§6.5），**实机证据**记入 [`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md) `ENV-V041-KERNEL-VERMAGIC`（`V041-D09`），不阻断 v0.4.1 发布闸。 |

---

## 11. 文档与版本关系

| 文档 | 角色 |
|---|---|
| 本文件 `V0_4_1_DESIGN.md` | v0.4.1 **唯一设计入口** |
| [`V0_4_DESIGN.md`](V0_4_DESIGN.md) | v0.4 冻结基线；staging 保留/再打包契约 |
| [`V0_4_2_DESIGN.md`](V0_4_2_DESIGN.md) | **下一增量（设计中）**：OS 层 minimal/full 与交互配方；与 staging 正交 |
| [`V0_4_3_DESIGN.md`](V0_4_3_DESIGN.md) | diskless `inspect` + agent 子命令（设计中） |
| [`V0_4_4_DESIGN.md`](V0_4_4_DESIGN.md) | nodeforge 备料/register + agent 本机 build/stage（设计中） |
| [`V0_4_5_DESIGN.md`](V0_4_5_DESIGN.md) | 克隆/恢复本地盘（骨架） |
| [`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md) | 延期项；节点 vermagic 等环境延期 |
| [`V0_4_1_VALIDATION_RUNBOOK.md`](../validation/V0_4_1_VALIDATION_RUNBOOK.md) | v0.4.1 验证任务书 |

### 11.1 相对 v0.4 的增量清单

| 增量 | v0.4 | v0.4.1 |
|---|---|---|
| keep/from-staging / list/show/remove | 有 | 保留 |
| full 挂载会话 enter/exec | 无（手工） | 有（`profile rootfs staging …`） |
| 默认 cgroup 挂载 | 无 | 有 |
| 会话 cgroup 资源限额 CLI | 无 | **有**（§3.6） |
| 共享 host 网 + 会话 HTTP 源 | 无产品入口 | 有 |
| 树内核扫描与启动面导入 | 无 | 有（显式，管理面） |
| 节点 vermagic / Lustre 实机闭环证据 | 无 | **环境延期** `ENV-V041-KERNEL-VERMAGIC` |
| `pivot_root` | 无 | **仍无**（遗留 `V041-D01`） |
| 顶层 `nodeforge rootfs …` | 无 | **仍无**（违背资源树） |
| 自动把会话步骤固化为 Profile | 无 | 仍无 |

---

## 12. 实现分期（建议）

| 阶段 | 内容 | 可演示结果 |
|---|---|---|
| **P0** | `profile rootfs staging enter`/`exec` + full 挂载 + cgroup **挂载** + **限额参数**（§3.6）+ 锁 + 清理 + **完整步骤日志** | 可安全会话运维并保护管理节点 |
| **P1** | kernels 扫描；from-staging `--kernel-release` 启动面导入 | 管理面换核可闭环（catalog/boot_bundle） |

P0+P1 构成 v0.4.1 **最小可发布集**（含 cgroup 限额；**不含**节点 vermagic 实机证据）。  
**不在本版分期：** `pivot_root`（`V041-D01`）、顶层 `rootfs` 命令、WebSocket TTY、net ns 隔离。  
**环境延期（非实现缺口）：** 节点侧 vermagic / Lustre-class 实机闭环 → `ENV-V041-KERNEL-VERMAGIC`。

---

## 13. 裁决摘要（供评审）

1. **归属：`nodeforge` CLI 本机特权**，管理节点保留树；**不是** `nodeforged` 交互能力，也不是节点/initrd。  
2. **cgroup：默认挂载 + 限额参数本版要做**（§3.6）；可 `--no-cgroup`。  
3. **切根：仅 chroot**；**`pivot_root` 移出 v0.4.1**，记入遗留 `V041-D01`。  
4. **enter + exec 均做**；不做 WebSocket/远程 TTY。  
5. **正式 CLI：仅 `profile rootfs staging enter|exec|kernels`**；顶层 `nodeforge rootfs …` 违背资源树，**不引入**。  
6. **默认完整步骤日志**（§3.7）。  
7. **网络：默认 = 宿主机**；会话允许 HTTP 源；正式 build 仍受管。  
8. **内核：树内 → squashfs；启动核显式 import**；默认 keep。  
9. **不引入** 容器运行时与节点侧构建。

---

*本设计依据 v0.4 staging 能力与 2026-08-05/06 需求对齐讨论整理，作为 v0.4.1 实现与评审基准。*
