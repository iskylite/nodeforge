# NodeForge v0.4.3 设计：Rootfs OS 层模式（minimal / full）与交互配方

状态：**设计中**（v0.4.3 唯一设计入口；实现前评审）

v0.4.3 在 v0.4 / v0.4.1 已落地的 diskless rootfs 构建与 staging 会话之上，为 **OS 层** 增加显式模式与可复现软件配方：

- `os_layer.mode = minimal | full`（默认 / 缺省 / 非法值 **fallback `minimal`** = 当前硬编码保护闭包行为）；
- **full** Profile / BootBundle 使用命名 qualifier `full`；**minimal 命名不变**；
- full 下消费 install source 的 environment / group / task / package；**optional 仅整组属性**；
- human CLI 交互补全配方；非交互缺字段 **fail closed**。

**不改变**既有强制边界：

- rootfs **只**由 `nodeforged` 所在管理节点生成；
- diskless 节点 **只**消费 ready squashfs；
- **local-only** 受管源；不因 full 拉公网 archive；
- v0.4.1 staging enter/exec 仍是运维特需路径，与 mode **正交**。

与前序版本关系：

| 版本 | 交付 |
|---|---|
| v0.4 | keep-staging / from-staging、共享 rootfs 边界 |
| v0.4.1 | staging 会话、内核扫描/启动面导入（管理面） |
| v0.4.2（设计中） | agent 子命令骨架 + diskless `inspect`（与本版正交） |
| **v0.4.3** | **OS 层 minimal/full + 交互配方 + include_optional** |
| v0.4.4 / v0.4.5 | `nodeforge-builder` 指定节点构建 / `nodeforge-imager` 克隆恢复 |

v0.4 / v0.4.1 发布闸 **不依赖** 本文件。

关联：[`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §4、[`V0_2_DESIGN.md`](V0_2_DESIGN.md) software 模型、[`naming.zig`](../../src/profile/naming.zig)、[`V0_4_DESIGN.md`](V0_4_DESIGN.md)、[`V0_4_1_DESIGN.md`](V0_4_1_DESIGN.md)、[`V0_4_2_DESIGN.md`](V0_4_2_DESIGN.md)、[`V0_4_4_DESIGN.md`](V0_4_4_DESIGN.md)、[`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md)。

---

## 1. 问题与目标

### 1.1 现状

- diskless **OS 层**实现为硬编码保护闭包（dnf 一小撮包；Ubuntu casper 叠层），**不**消费 Profile `software.environment/groups/tasks/packages`。
- install 路径 Kickstart 已能渲染 environment/groups/packages；默认 `@^minimal-environment`。
- Ubuntu live-server 受管 `Packages` 常 **无 `Task:`**，`--kind task` 为空是介质事实，不是 CLI 故障。
- comps **optional** 默认不装（mandatory+default）；Kickstart 支持整段/整组 `--optional`，无细粒度 optional 点选。

### 1.2 目标

1. 增加 **OS 层模式** `os_layer.mode = minimal | full`，**默认 / 缺省 / 非法值均 fallback 为 `minimal`**（与当前已实现行为一致）。
2. **`full` Profile / BootBundle 命名带 `full` qualifier**；**minimal 命名保持现状**（无 qualifier）。
3. **`full` 下** OS 层真正按 install source 能力与用户选择装包；支持 **groups/packages（及 Ubuntu tasks）叠加**。
4. **optional**：仅提供 **整组/整段级** 属性开关，默认关；不做 optional 细粒度扫描写入 packages。
5. **CLI 交互配方**（human 模式）：RHEL 未指定 environment 时强制从 ISO index 选；Ubuntu 有 task 则交互选 task；**无 task 时不以「介质全集」为默认安装集**，基线=casper + 用户显式 packages（交互多选或 `packages.include`）；两端均可交互增删 packages（及 RHEL groups）。
6. **非交互 / CI**：缺必填选择 **fail closed**，不静默猜「最大 environment / Server with GUI」。

### 1.3 非目标

| 非目标 | 说明 |
|---|---|
| 自动猜「最大 environment」 | 跨发行版不稳定（Server with GUI / GNOME / workstation 等） |
| optional 包级点选 | 过设计；用整组 `--optional` 属性即可 |
| 破 local-only 拉公网 archive | full 上界 = **该 install source 受管仓库** |
| 用 staging 会话代替 full 配方 | staging 仍是运维特需路径，与 mode 正交 |
| 把 Node `overrides.software` 烤进公共 rootfs | 共享 rootfs 边界不变 |

---

## 2. 概念模型

```text
                    Profile
         os_layer.mode = minimal | full
         software.*（environment / groups / tasks / packages / include_optional）
                              │
              ┌───────────────┴───────────────┐
              │ mode=minimal                    │ mode=full
              ▼                               ▼
     保护闭包 OS 层（现状）            配方驱动 OS 层
     （不展开 env/group/task）         + casper（Ubuntu）或 dnf 基线
     packages.include 仍可叠加*        + env/groups/tasks/packages
              │                               │
              └───────────────┬───────────────┘
                              ▼
                    rootfs-build phase → squashfs
```

\* **minimal 下 `packages.include`**：允许作为「最小闭包上的显式加包」（实现必须支持）；**不**因 mode=minimal 去交互要 environment。  
\* **full 下** 以配方为主；保护闭包仍是 **下界**（不可被 exclude 拆掉）。

| 术语 | 定义 |
|---|---|
| **保护闭包（protected closure）** | 可启动 + nodeforge-agent 收敛 + SSH/网络/包管理器所需最小集合；两 mode 均 ⊇ 此集合 |
| **配方（recipe）** | Profile 上持久化的 `software.*` + `os_layer.mode`；进入 `rootfs_input_digest` |
| **介质宇宙（universe）** | 该 install source 受管 repodata/Packages 中全部 **package** 名；**仅**作选包上界/候选，**不是**默认安装集（旧称「介质全集」已废弃为安装语义） |
| **交互配置（wizard）** | human TTY 下补全 full 配方的 CLI 流程；结果 **写回 Profile** 后才 build |

---

## 3. 命名规则（与现有一致）

既有语法（`src/profile/naming.zig`）：

```text
Profile:     <install-source>[-<qualifier>]-<install|diskless>
BootBundle:  <install-source>[-<qualifier>]-diskless-bundle
```

| mode | qualifier | 示例（install source = `rocky-9.7-aarch64-minimal`） |
|---|---|---|
| **minimal** | **无**（现状不变） | `rocky-9.7-aarch64-minimal-diskless` |
| **full** | **`full`** | `rocky-9.7-aarch64-minimal-full-diskless` |
| full + 其它用途 | `full` 与其它 qualifier **组合顺序**见下 | `…-full-compute-diskless` 或 `…-compute-full-diskless` |

### 3.1 qualifier 裁决

1. **ISO 导入自动创建的 default Profile**：仅 **minimal** 命名（今天行为），`os_layer.mode=minimal`。  
2. **创建 full Profile**（CLI `profile create` / `profile clone` / 显式 wizard「另存为 full」）：名称必须带 qualifier **`full`**。  
3. 若已有其它 qualifier（如 `compute`），**full 作为独立 token 插入 source 与 kind 后缀之间**，规范为：

```text
<install-source>-full[-<other-qualifier>]-<install|diskless>
```

示例：

```text
rocky-9.7-aarch64-minimal-full-diskless
rocky-9.7-aarch64-minimal-full-install
rocky-9.7-aarch64-minimal-full-diskless-bundle
ubuntu-22.04.5-live-server-arm64-full-diskless
```

4. **校验**：`os_layer.mode=full` 的 Profile 名 **必须** 满足 `profileIsCanonical` 且 base 段含 `-full`（或 name 在 source 后第一段 qualifier 为 `full`）。`mode=minimal` **不得** 强制改名；允许历史名无 full。  
5. **禁止** 仅靠改 mode 而不改名导致「同名 Profile 语义从 minimal 变 full」——`profile set os_layer.mode=full` 若名称无 `full` qualifier → **fail closed**，提示 `profile clone` 到规范 full 名或 rename 流程。
6. **现有 `naming.zig` 语法**：当前 `<install-source>[-<qualifier>]-<install|diskless>` 仅支持单个 qualifier 段。若需 `full` 与其它 qualifier（如 `compute`）组合，实现须扩展 qualifier 解析为有序多段；未扩展前，单 qualifier `full` 优先交付，多 qualifier 组合可在首个 full Profile 出现时再迭代。

---

## 4. 配置模型

### 4.1 新 / 明确字段

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `os_layer.mode` | enum `minimal` \| `full` | **`minimal`** | 缺省、空、未知值 → **fallback `minimal`**（不报错，日志 debug 一条） |
| `software.include_optional` | bool | **`false`** | 仅 **full** 且存在 group/environment 展开时生效；映射 Kickstart/dnf **整组 optional** |
| `software.environment` | string? | null | **RHEL/dnf only**；full 且未设置时交互必选或非交互失败 |
| `software.groups` | set | [] | RHEL groups 叠加 |
| `software.tasks` | set | [] | Ubuntu tasks 叠加 |
| `software.packages.include` | set | [] | 显式加包 |
| `software.packages.exclude` | set | [] | 显式减包（不可减 protected） |

存储位置：Profile catalog（与其它 software 字段同级 owner）。  
`os_layer.mode` 建议挂在 Profile 根或 `software` 旁；**PropertySpec 注册**为 scalar，mutable，进 digest。

### 4.2 include_optional（整组级，非细粒度）

| 值 | dnf diskless OS 层 | Kickstart install 渲染 |
|---|---|---|
| `false`（默认） | `group install` **不含** optional（mandatory+default） | `%packages` **无** `--optional`；`@group` 无 `--optional` |
| `true` | 对选中的 environment 所含 groups + 显式 groups 使用 **with-optional** 语义 | `%packages --optional` **或** 每个 `@group --optional`（实现选一种并固定；推荐 **段级 `--optional`** 与「全局/整组」产品语义一致） |

**不做**：扫描 comps optional 列表自动写入 `packages.include`。

`mode=minimal` 时 `include_optional=true` → **fail closed**（minimal 无 group 展开，属性无意义）。

**校验时机**：在 **`profile validate` / `rootfs build`（及 daemon 构建入口）** 时执行，**不**在单字段 `profile set` 时硬拦中间态（允许先设 optional 再切 mode，或先切 minimal 再清 optional）。`profile set` 可给 warning，但以 build 时闭合为准。

### 4.3 fallback 规则

```text
mode_raw = profile.os_layer.mode
if mode_raw is null or empty or not in {minimal, full}:
    mode = minimal
else:
    mode = mode_raw
```

---

## 5. OS 层装包语义（按 mode × 发行版）

### 5.1 公共：保护闭包

两 mode 在 Stage 1 结束后必须满足保护闭包。`packages.exclude` 若触及闭包 → **fail closed**。

**dnf 严格闭包**（缺一构建失败；对齐 `rootfs_os_builder.dnf_core_packages`）：

`bash`, `coreutils`, `dnf`, `systemd`, `shadow-utils`, `util-linux`, `iproute`, `NetworkManager`, `openssh-server`, `procps-ng`, `kernel-core`, `kernel-modules`

**dnf archive 工具**（best-effort，**不**算保护闭包，exclude 可去掉）：`tar`, `gzip`, `xz`

**apt/casper 严格文件**（对齐 `casper_required_files`）：

`sbin/init`, `usr/lib/systemd/systemd`, `usr/bin/apt`, `usr/sbin/sshd`

清单变更必须 bump `builder_revision`。

### 5.2 mode = minimal

| 族 | 行为 |
|---|---|
| **dnf** | **仅**保护闭包（+ 可选 archive 工具 best-effort，与现状一致）；**不**安装 environment/groups/tasks |
| **apt** | **仅** casper 叠层 + 保护文件检查；**不**按 task 装 |
| **packages.include** | 在闭包/casper **之后** 从受管源安装（显式加包）。**当前代码未接线，本版新增实现**（非「现状已支持」） |
| **packages.exclude** | 仅对 **本模式实际装上的可移除包** 生效；不可拆闭包 |
| **environment/groups/tasks** | 可存在于 Profile（供 install 路径或将来展示），**minimal diskless OS 层忽略**；`profile show` 标注 `os_layer: ignored for diskless OS` |

### 5.3 mode = full · RHEL/Rocky（dnf）

**输入要求：**

1. `software.environment` **必须** 已设置且落在 install source software index 的 `kind=environment` 中。  
2. 未设置：见 §6 交互；非交互 → `error os_layer.environment_required`。  
3. **禁止** 实现「自动选包数最多的 environment」。

**装包顺序（受管 file:// only）：**

```text
1. bootstrap 保护闭包（可与 minimal 共用原语）
2. dnf group install @^<environment>
   （include_optional=true 时带 optional）
3. dnf group install @<group>…（software.groups）
4. dnf install <packages.include>…
5. dnf remove <packages.exclude>…（受 protected 约束）
6. 再次断言保护闭包存在
```

**与「介质全包 `*`」的关系：**  
本设计 **不以 `*` 作为 full 定义**。full = **用户选定的 environment（+ groups/packages）**。  
若用户希望「尽量多」：交互时选择更完整的 environment，并追加 groups/packages；**不**静默 `*`。

### 5.4 mode = full · Ubuntu（apt）

**分支 A — index 中存在至少一个 `kind=task`：**

1. `software.tasks` **必须** 非空（交互必选至少一个，或允许显式空？→ **至少一个 task 或显式 packages.include 非空** 二选一，避免空 full）。  
2. 解析 task → 包闭包：仅使用 **受管 Packages 中带对应 `Task:` 的包** + metapackage 惯例；解析失败 fail closed。  
3. casper 叠层 → `apt-get install`（tasks 闭包 ∪ packages.include）→ exclude。

**分支 B — index 中无任何 task（live-server 典型）：**

**裁决（相对旧稿「介质全集默认安装」的收敛）：**

| 概念 | 定义 |
|---|---|
| **介质宇宙（universe）** | 受管 `Packages*` 中全部 `Package:` 名 —— **仅**作可选集 / 校验上界 / 交互候选列表，**不是**默认 `apt-get install` 目标 |
| **OS 层基线** | **casper 叠层**（已是 live 介质 rootfs，内容远大于 dnf 保护闭包） |
| **full 配方** | 在 casper 之上 **显式** 安装 `packages.include`（及交互所选包）；`packages.exclude` 仅对本次实际装上的可移除包生效，不可拆保护闭包文件 |

**规则：**

1. **禁止**将「Packages 索引内全部包名」作为默认安装列表（体积、冲突、离线解算均不可接受）。  
2. full 且无 task 时：`packages.include` **必须非空**，或 human wizard 从 universe **多选至少 1 个包**后写回 Profile。  
3. 非交互且 `packages.include` 空 → fail closed：`os_layer.packages_required`。  
4. 装包顺序：casper 叠层 → `apt-get install <packages.include>`（仅受管源）→ exclude。  
5. 包名不在 universe 内 → `software.unknown_capability`。  
6. **禁止**：chroot 后改写 sources 指向公网 archive 来补 task/包组。

**与 RHEL full 对称性：** RHEL full 也不以 `*` 为定义，而要求显式 environment；Ubuntu 无 task 时对称要求显式 packages，casper 承担「介质已提供的文件系统基线」。

### 5.5 install Profile（Kickstart / Autoinstall）

| mode | Kickstart | Autoinstall |
|---|---|---|
| minimal | 现状：`@^minimal-environment` 或已配置 environment；groups/packages 照旧 | packages/tasks 照旧 |
| full | 必须有 environment；`%packages` 写 `@^env` + `@groups` + pkgs；`include_optional` → 段级 `--optional` | tasks + packages；无 task 时 **仅** 显式 packages 列表（非介质全集） |

install 的 full Profile **同样**遵守 `-full-` 命名。

---

## 6. CLI 交互配方（human）

### 6.1 入口

推荐一等公民命令（资源树内，不引入顶层乱命令）：

```text
nodeforge profile os-layer configure <profile>
# 或
nodeforge profile software configure <profile> --os-layer full
```

亦可在：

```text
nodeforge profile create <name> --kind diskless --from-install-source <src> --os-layer full
```

时，若 TTY 且缺配方，**进入同一 wizard**；`--yes` / `--output json` / 非 TTY → **不进入 wizard**，缺字段直接失败。

### 6.2 何时触发强制交互

| 条件 | 行为 |
|---|---|
| `mode=full`，dnf，`environment` 未设，human TTY | **必须**列出 index environments，用户选 1 个 |
| `mode=full`，apt，存在 tasks，且 `tasks` 空且 `packages.include` 空，human TTY | **必须**多选 tasks（至少 1 个）或进入「仅自定义 packages」路径 |
| `mode=full`，apt，无 tasks，且 `packages.include` 空，human TTY | **不**问 task；提示 casper 为基线、须从介质宇宙选包；**强制**多选 packages（≥1） |
| `mode=minimal` | **不**强制 env/task 交互 |
| 非交互且缺必填 | fail closed，打印可执行的 `profile set` / `add-values` 示例 |

### 6.3 Wizard 步骤（full · RHEL）

```text
1. 确认 install source 与 software index revision
2. 列表 environments（id + name），单选 → software.environment
3. 可选：列表 groups，多选 → software.groups（可跳过）
4. 可选：include_optional? [y/N] → software.include_optional
5. 可选：packages include（逗号/多行，校验在 index 内）
6. 可选：packages exclude（校验 protected）
7. 预览配方摘要 + 写回 Profile
8. 询问是否立即 rootfs build
```

### 6.4 Wizard 步骤（full · Ubuntu · 有 task）

```text
1. 列表 tasks，多选（至少 1）或选「跳过 task，仅 packages」
2. packages include / exclude
3. 写回 + 可选 build
```

### 6.5 Wizard 步骤（full · Ubuntu · 无 task）

```text
1. 提示：index 无 Task 字段；基线 = casper；介质宇宙仅作候选（共 N 个 package）
2. 从候选多选 packages.include（至少 1；支持搜索/过滤，禁止一键「全选介质」作为默认路径）
3. 可选 packages.exclude
4. 写回 + 可选 build
```

### 6.6 非交互完备示例

```bash
# RHEL full
nodeforge profile clone rocky-9.7-aarch64-minimal-diskless \
  rocky-9.7-aarch64-minimal-full-diskless
nodeforge profile set rocky-9.7-aarch64-minimal-full-diskless os_layer.mode=full
nodeforge profile set rocky-9.7-aarch64-minimal-full-diskless software.environment=minimal-environment
nodeforge profile add-values rocky-9.7-aarch64-minimal-full-diskless software.groups -- core
nodeforge profile add-values rocky-9.7-aarch64-minimal-full-diskless software.packages.include -- vim-enhanced
nodeforge profile set rocky-9.7-aarch64-minimal-full-diskless software.include_optional=false
nodeforge profile rootfs build rocky-9.7-aarch64-minimal-full-diskless --yes

# Ubuntu full（无 task → casper 基线 + 显式 packages.include）
nodeforge profile set ubuntu-…-full-diskless os_layer.mode=full
nodeforge profile add-values ubuntu-…-full-diskless software.packages.include -- openssh-server vim
nodeforge profile add-values ubuntu-…-full-diskless software.packages.exclude -- unneeded-pkg
nodeforge profile rootfs build ubuntu-…-full-diskless --yes
```

---

## 7. 构建与 digest

### 7.1 `rootfs_input_digest` 必须包含

- `os_layer.mode`（归一化后的 minimal/full）  
- `software.environment` / `groups` / `tasks` / `packages.include|exclude`  
- `software.include_optional`  
- 相关 repository `software_index.revision_digest`  
- 既有 OS/source/casper/builder ABI 等  

**minimal 忽略 env/groups/tasks 装包时**：这些字段 **仍进入 digest**（避免「改了 env 却不 rebuild」的认知陷阱）；或文档明确 minimal 下变更 env **不改变** digest——**推荐仍进入 digest**，实现简单、可预期。

### 7.2 Stage 1 伪代码

```text
mode = normalize(profile.os_layer.mode)  // default minimal
protected = protectedClosure(family)
recipe = profile.software

if mode == minimal:
    installMinimal(protected)
    installPackages(recipe.packages.include)
    applyExclude(recipe.packages.exclude, protected)
else: // full
    validateFullRecipe(family, recipe, index)  // 非交互缺字段则失败
    if family == rhel:
        installMinimal(protected)  // bootstrap
        groupInstallEnvironment(recipe.environment, optional=recipe.include_optional)
        groupInstall(recipe.groups, optional=recipe.include_optional)
        installPackages(recipe.packages.include)
        applyExclude(...)
    else: // ubuntu
        casperOverlay()
        if index.hasTasks:
            pkgs = resolveTasks(recipe.tasks) ∪ recipe.packages.include
        else:
            // universe = allPackagesInIndex() 仅校验；不安装全集
            requireNonEmpty(recipe.packages.include)  // 或 task 路径
            pkgs = recipe.packages.include
        aptInstall(pkgs)  // 仅受管源；包须 ∈ universe
        applyExclude(...)
assertProtected(protected)
```

### 7.3 与 rootfs-build phase

- OS 层只负责 mode+software 基线。  
- `rootfs-build` 的 package/script/archive **之后**叠加，语义不变。  
- staging enter / from-staging **不**改 `os_layer.mode`。

---

## 8. 校验与错误码

| 条件 | 码（稳定字符串） |
|---|---|
| full Profile 名无 `full` qualifier | `os_layer.full_name_required` |
| full + dnf + 无 environment（非交互） | `os_layer.environment_required` |
| full + dnf + environment 不在 index | `software.unknown_capability` |
| full + apt + 有 task + tasks 与 packages.include 皆空（非交互） | `os_layer.task_or_packages_required` |
| full + apt + **无** task + packages.include 空（非交互） | `os_layer.packages_required` |
| include_optional=true + mode=minimal | `os_layer.optional_requires_full` |
| exclude 命中 protected | `software.protected_exclude` |
| 包/group/task 不在 index | `software.unknown_capability` |
| Ubuntu full 拉公网 | 不实现 |

---

## 9. CLI / API 表面

```text
# 属性
nodeforge profile set <p> os_layer.mode=minimal|full
nodeforge profile set <p> software.include_optional=true|false
nodeforge profile set <p> software.environment=<id>
nodeforge profile add-values <p> software.groups|tasks|packages.include|packages.exclude -- …

# 交互配方
nodeforge profile os-layer configure <p> [--os-layer full]

# 创建
nodeforge profile create … --os-layer full   # 生成 -full- 名并 mode=full
nodeforge profile clone <src> <dst-full-name> --os-layer full

# 查询（增强提示）
nodeforge profile software available <p> --kind environment|group|task|package
# task 为空时 stderr hint：live ISO 常无 Task 字段；full 基线=casper，须显式 packages.include
```

HTTP：与 CLI 同字段；**无** 远程 TTY wizard；daemon 只接受已完备的 Profile 做 rootfs build。

---

## 10. 实现落点（v0.4.3 全量清单）

| 模块 | 工作 |
|---|---|
| `model` / PropertySpec / catalog schema | `os_layer.mode`、`software.include_optional` |
| `profile/naming.zig` | full qualifier 约定与 `full` 名校验 helper；现有语法 `<source>[-<qualifier>]-<kind>` 仅支持单个 qualifier 段，需扩展为支持 `full` 与其它 qualifier（如 `compute`）的组合解析（见 §3.1 point 3） |
| `config/validate.zig` | §8 规则；family 与 kind 适用性 |
| `provision/os_layer_software.zig`（新） | recipe 归一化、protected、解析 task 闭包、装包计划 |
| `provision/rootfs_os_builder.zig` | Stage 1 按 mode 分支；去掉「software 未接线」状态 |
| `profile/adapter/kickstart.zig` | full + include_optional 渲染 |
| `profile/adapter/ubuntu.zig` | full tasks/packages |
| `main.zig` | set/configure wizard、create/clone `--os-layer`、available hint |
| `profile/diskless.zig` `ProfileBuildProjection` | **新增** `os_layer_mode` 字段（归一化后的 `minimal`/`full`），确保 `rootfs_input_digest` 覆盖 mode 变更；`software.include_optional` 作为 `SoftwareSelection` 新字段自动进入既有 `software` 序列化路径 |
| 测试 | 命名、fallback、validate、recipe 渲染契约、wizard 非 TTY 失败 |
| 文档 | REFERENCE、DISKLESS_FINAL 交叉链接、本文件完成闸 |

---

## 11. 完成标准（v0.4.3 发布闸）

1. 未配置 / 非法 `os_layer.mode` → 行为与 **当前 minimal OS 层**一致。  
2. `mode=minimal` 命名 **无需** `full`；现有 `*-diskless` 回归通过。  
3. `mode=full` 要求规范名含 `-full-`；否则 set/build fail closed。  
4. RHEL full：必须选定 index 内 environment；groups/packages/include_optional 按 §5.3 装入 rootfs。  
5. Ubuntu full：有 task 则按 tasks；无 task 则 casper + 非空 packages.include（禁止默认装介质全集）；packages 增删生效。  
6. `include_optional=true` 仅 full；Kickstart/dnf 呈整组 optional，默认 false。  
7. human wizard 在缺 environment（RHEL）时强制选择；非交互缺字段失败。  
8. exclude 无法拆除 protected；local-only 无公网。  
9. digest 随 mode/software 变化；改配方必须 rebuild 才变内容。  
10. 无「自动最大 environment」逻辑。

---

## 12. 裁决摘要

1. **`os_layer.mode=minimal|full`，默认与 fallback 均为 minimal。**  
2. **full 资源名使用 qualifier `full`：`<source>-full[-…]-diskless|install`；minimal 名不变。**  
3. **full · RHEL = 必选 environment + 可选 groups/packages；不猜最大 env；不以 `*` 为定义。**  
4. **full · Ubuntu = 有 task 则选 task；无 task 则 casper 基线 + 显式 packages（介质宇宙仅作上界/候选，非默认安装集）。**  
5. **`software.include_optional` 整组级，默认 false；不扫 optional 进 packages。**  
6. **交互写回 Profile；CI 非交互 fail closed。**  
7. **保护闭包两 mode 下界；local-only 不变。**


---

## 13. 文档与版本关系

| 文档 | 角色 |
|---|---|
| 本文件 `V0_4_3_DESIGN.md` | v0.4.3 **唯一设计入口** |
| [`V0_4_DESIGN.md`](V0_4_DESIGN.md) | v0.4 冻结基线；rootfs 服务端生成与 staging 保留 |
| [`V0_4_1_DESIGN.md`](V0_4_1_DESIGN.md) | v0.4.1 staging 会话；与 os_layer mode 正交 |
| [`V0_4_2_DESIGN.md`](V0_4_2_DESIGN.md) | v0.4.2 agent 子命令 + inspect；与本版正交 |
| [`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md) | 延期/非目标；本主题自独立设计进入 v0.4.3 |
| 后续 `V0_4_3` validation runbook | 实现接近完成时再写证据清单 |

### 13.1 相对 v0.4.1 的增量

| 增量 | v0.4.1 | v0.4.3 |
|---|---|---|
| OS 层硬编码保护闭包 | 有（唯一路径） | **minimal** 保留为默认 |
| `os_layer.mode=full` + 配方装包 | 无 | **有** |
| full 命名 qualifier | 无 | **有**（`-full-`） |
| 交互 wizard 选 env/task/packages | 无 | **有** |
| `software.include_optional` | 无 | **有**（默认 false） |
| staging enter/exec | 有 | 保留，正交 |

---

*本文件为 NodeForge **v0.4.3** 设计入口，作为实现与评审基准。*
