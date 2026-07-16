# 自定义内核引导参数（kernel_args）设计

- 日期：2026-07-16（2026-07-16 更新：补充 pykickstart/autoinstall 官方文档依据）
- 状态：设计完成，待实现
- 前置：M4.5
- 权威位置：`docs/DETAILED_DESIGN.md` §9.15（M4.6）；本文件给出实现细化，冲突时以 §9.15 的后续修订为准
- 目标：为 profile 增加 `kernel_args` 字段，使 `iommu=pt`、`intel_iommu=on`、`hugepagesz=1G hugepages=4` 等内核参数可配置，覆盖 PXE 引导和目标系统持久 GRUB 两条链路

## 1. 背景：当前代码事实

### 1.1 cmdline 生成完全硬编码

`src/boot/target.zig` 是唯一生成 PXE kernel cmdline 的模块。当前三种模式的 cmdline 全部由 `std.fmt.bufPrint` 硬编码拼接，没有任何外部参数注入点：

| 模式 | 发版 | 当前 cmdline（硬编码） | 代码位置 |
| --- | --- | --- | --- |
| install (RHEL) | Rocky/CentOS | `ip=dhcp rd.neednet=1 inst.repo=<url> inst.ks=<url>` | target.zig:163 |
| install (Ubuntu) | Ubuntu | `boot=casper root=/dev/ram0 ramdisk_size=1500000 ip=dhcp url=<url> ... autoinstall ds=nocloud-net;s=<url>` | target.zig:148 |
| diskless | 全部 | `ip=dhcp nodeforge.config=<url>` | target.zig:204 |
| discovery | — | 返回 null，不提供 kernel/initrd | target.zig:73 |

### 1.2 数据模型缺失字段

- `ProfileConfig`（`src/model.zig:302-325`）：没有 `kernel_args`、`cmdline_extra`、`boot_args` 等字段
- `BootloaderInstallConfig`（`src/model.zig:495-502`）：没有 `append` 字段
- `NodeConfig`（`src/model.zig:553-592`）：只有 `http_accel`、`deploy` 等节点级开关，无内核参数覆盖

### 1.3 设计文档中的遗留概念

`docs/DETAILED_DESIGN.md` 第 432 行的伪代码 `ProfileConfig` 包含 `cmdline_template: []const u8` 字段，但实际 `model.zig` 从未实现此字段。M3.5 实现时将 cmdline 拼接逻辑直接硬编码到 `target.zig`，放弃了模板方案。本设计不恢复模板方案，而是采用更安全的"追加"模型。

### 1.4 目标系统 GRUB 配置缺失

Kickstart 渲染器（`src/profile/adapter/kickstart.zig:83`）生成的 bootloader 指令为：

```text
bootloader --boot-drive=sda
```

不含 `--append=` 参数。Ubuntu autoinstall 渲染器使用 `storage.layout: direct`，也不写入 GRUB kernel 参数。

### 1.5 已实现 vs 未实现的注入点

| 注入点 | 链路 | 实现状态 | 涉及文件 |
| --- | --- | --- | --- |
| ① PXE install cmdline | install (GRUB UEFI) | ✅ 已实现，需改造 | `src/boot/target.zig` |
| ② PXE diskless cmdline | diskless (GRUB UEFI) | ✅ 已实现，需改造 | `src/boot/target.zig` |
| ③ 目标系统 GRUB (Kickstart) | install 持久化 | ✅ 已实现，需改造 | `src/profile/adapter/kickstart.zig` |
| ④ 目标系统 GRUB (Autoinstall) | install 持久化 | ✅ 已实现，需改造 | `src/profile/adapter/ubuntu.zig` |
| ⑤ PXELINUX APPEND | BIOS x86 (M6) | ❌ 未实现 | `src/boot/pxelinux.zig`（待创建） |
| ⑥ diskless initrd /proc/cmdline | diskless (M5) | ❌ 未实现 | `initrd/dracut/95nodeforge/nodeforge-init.sh`（待创建） |
| ⑦ BootConfig JSON (diskless) | diskless HTTP 响应 | ✅ 已实现，需扩展 | `src/http/server.zig:709` |

## 1A. 官方文档研究依据

### 1A.1 Kickstart `bootloader --append`（RHEL 7/8/9/10）

**来源**：pykickstart 源码 `pykickstart/commands/bootloader.py`（master 分支）

`--append` 选项自 FC3（RHEL 4 之前）引入，在 **所有** RHEL 版本中稳定支持，从未被废弃或移除：

| RHEL 版本 | pykickstart 继承链 | `--append` 支持 | 语法 |
| --- | --- | --- | --- |
| RHEL 7 | `RHEL7_Bootloader` → `F21_Bootloader` | ✅ FC3 引入 | `bootloader --append="params"` |
| RHEL 8 | `RHEL8_Bootloader` → `F29_Bootloader` → `F21_Bootloader` | ✅ | 同上 |
| RHEL 9 | `RHEL9_Bootloader` → `F34_Bootloader` → `F29_Bootloader` | ✅ | 同上 |
| RHEL 10 | 基于 `F39_Bootloader`（含 `--sdboot`） | ✅ | 同上 |

关键发现：
- `--append` 接受双引号包裹的空格分隔内核参数字符串
- Anaconda 在安装 plymouth 时会自动追加 `rhgb quiet`，操作员无法通过 `--append` 覆盖此行为
- `--append` 的值被写入目标系统 `/boot/grub2/grub.cfg` 的 `GRUB_CMDLINE_LINUX` 行
- 无需任何版本分支处理，所有 RHEL 版本语法完全一致

### 1A.2 Ubuntu Autoinstall（22.04+）内核参数

**来源**：subiquity `autoinstall-reference.rst`、`autoinstall-schema.json`、curtin `config.html`

关键发现：

1. **autoinstall schema 中无原生内核参数字段**
   - `kernel` 段只有 `package` 和 `flavor`，用于选择安装哪个内核包，**不**控制 kernel 命令行
   - `boot`/`grub` 段（curtin config）控制 GRUB 安装（`install_devices`、`terminal`、`update_nvram`、`probe_additional_os`、`reorder_uefi`），但**没有** `--append` 等效项
   - schema 中的 `append` 字段位于 `identity.groups`（用户组追加字段），与内核参数完全无关

2. **唯一可行路径：`late-commands` + `/etc/default/grub.d/`**
   - autoinstall 的 `late-commands` 在安装完成后、重启前执行
   - 目标系统挂载在 `/target`，通过 `curtin in-target --target=/target -- <cmd>` 在 chroot 中执行
   - 标准做法：写入 `/etc/default/grub.d/99-nodeforge.cfg` drop-in 文件，然后 `update-grub`

3. **为什么用 drop-in 文件而非直接修改 `/etc/default/grub`**
   - `/etc/default/grub.d/*.cfg` 是 GRUB 2.02+ 支持的 drop-in 机制（Ubuntu 22.04/24.04 均支持）
   - drop-in 文件不会被 grub-pc 包更新覆盖；直接修改 `/etc/default/grub` 会在包升级时触发 `ucf` 冲突
   - 可以精确控制追加到 `GRUB_CMDLINE_LINUX` 的内容，使普通和 recovery entry 语义一致

4. **curtin `write_files` 不可用于 `/target`**
   - curtin 的 `write_files` 写入安装环境而非目标系统；写入目标文件系统必须通过 `late-commands`

### 1A.3 两种安装器的参数持久化对比

| 维度 | Kickstart (RHEL 7-10) | Autoinstall (Ubuntu 22.04+) |
| --- | --- | --- |
| 原生内核参数支持 | ✅ `bootloader --append=` | ❌ 无原生字段 |
| 参数写入位置 | `/boot/grub2/grub.cfg` GRUB_CMDLINE_LINUX | `/etc/default/grub.d/99-nodeforge.cfg` |
| 执行时机 | Anaconda 安装阶段 | `late-commands`（安装后、重启前） |
| 版本兼容性 | 全版本一致 | 22.04/24.04 一致（grub.d drop-in） |
| 需要额外命令 | 不需要 | 需要 `update-grub` |

## 2. 设计决策

### 2.1 "追加"而非"模板"

不恢复设计文档中的 `cmdline_template` 模板方案。原因：

1. 模板方案要求操作员理解 NodeForge 内部 cmdline 结构（`inst.repo`、`ds=nocloud-net;s=` 等），容易误删必要参数导致安装器无法启动
2. NodeForge 的 install cmdline 包含认证 URL（`inst.ks=`、`nodeforge.config=`），模板化后存在泄露 token 到 cmdline 的风险
3. 不同发行版的 cmdline 结构差异巨大（RHEL 用 `inst.repo`，Ubuntu 用 `url=` + casper），模板无法统一

采用"追加"模型：NodeForge 保留对所有必要参数的完整控制，操作员只能通过 `kernel_args` 在 cmdline **末尾追加** 自定义参数。

### 2.2 profile 级配置，不设 node 级覆盖

`kernel_args` 放在 `ProfileConfig` 而非 `NodeConfig`。原因：

1. 内核参数（如 `iommu=pt`）通常按硬件型号/用途分组，profile 正是为此设计
2. node 级覆盖会与 profile 的 distro/version/arch 三元组产生交互复杂性
3. 当前 CLI 没有 `profile add/set` 命令（profile 只通过 JSON 配置），node 级覆盖也无 CLI 入口
4. 如果后续确有节点级需求，可在 `NodeOverrideConfig` 中增加 `kernel_args`，但 MVP 不做

### 2.3 discovery 模式不注入

discovery 模式不提供 kernel/initrd（返回 null），`kernel_args` 对 discovery profile 无意义。校验阶段拒绝 discovery profile 设置 `kernel_args`。

### 2.4 安全约束

`kernel_args` 的字符集必须严格限制，防止破坏 GRUB/Kickstart/YAML 语法或注入命令：

- 允许：字母、数字、`=.-_` 和空格
- 拒绝：控制字符（`< 0x20`、`0x7f`）、引号（`"`、`'`、`` ` ``）、分号（`;`）、反斜杠（`\`）、换行符、`$`、`()`、`{}`
  - **Kickstart 依据**：`--append` 值用双引号包裹（pykickstart `FC3_Bootloader._getArgsAsStr`：`retval += " --append=\"%s\""`），拒绝双引号防止截断
  - **Autoinstall 依据**：`late-commands` 使用 YAML 单引号字符串（`render.yamlQuote`），拒绝单引号防止 YAML 注入
  - **`$` 拒绝依据**：用户值拒绝 `$` 防止变量注入；NodeForge 自有 `${GRUB_CMDLINE_LINUX}` 仅作为单引号保护的字面量写入
- 最大长度 256 字节
- 按空格解析 token，只对 `=` 前的完整参数名匹配 mode/distro 保留表，不做子串匹配；common 包含
  `ip/root/initrd/BOOT_IMAGE/nodeforge.config`，RHEL 包含 `rd.neednet/inst.ks/inst.repo/inst.stage2`，Ubuntu 包含
  `boot/url/cloud-config-url/autoinstall/ds/ramdisk_size`，内部名包含 `boot_session_id/token/capability`
- 输入空字符串 canonicalize 为 `null`；前后/连续空格折叠；重复参数名和参数名以 `-` 开头均拒绝
- install profile 设置参数时要求 `bootloader.install=true`，否则不能保证目标系统持久化
- **逗号（`,`）允许**：某些内核参数使用逗号分隔（如 `vfio-pci.ids=10de:1b06,8086:1a16`），但当前字符集不含逗号。需确认是否增加

### 2.5 字符集补充决策

经过分析常见内核参数，**增加逗号 `,` 和冒号 `:` 到允许字符集**：

- `vfio-pci.ids=10de:1b06` — VFIO 设备直通（需要 `:`）
- `hugepagesz=1G hugepages=4` — 大页（已有 `=` 和空格）
- `isolcpus=0,2,4-7` — CPU 隔离（需要 `,`）
- `processor.max_cstate=1` — 已有 `.`

修订后的允许字符集：字母、数字、`=.-_,:` 和空格

## 3. 数据模型变更

### 3.1 ProfileConfig 新增字段

```zig
// src/model.zig ProfileConfig
pub const ProfileConfig = struct {
    // ... 现有字段 ...
    /// 可选的自定义内核命令行参数，追加到 PXE 引导 cmdline 末尾和
    /// 目标系统 GRUB 配置中。用于 IOMMU、大页、调试等内核功能开关。
    /// 示例："iommu=pt"、"intel_iommu=on iommu=pt"、"hugepagesz=1G hugepages=4"
    /// discovery 模式下必须为 null。校验阶段会拒绝不安全字符。
    kernel_args: ?[]const u8 = null,
};
```

### 3.2 JSON 配置示例

```json
{
  "profiles": [
    {
      "name": "rocky-install-aarch64",
      "mode": "install",
      "distro": "rocky",
      "version": "9.7",
      "arch": "aarch64",
      "install_source": "rocky-9.7-aarch64-iso",
      "safety": { "destructive": true, "persistent_writes": true },
      "kernel_args": "iommu=pt iommu.passthrough=1"
    },
    {
      "name": "ubuntu-diskless-vfio",
      "mode": "diskless",
      "distro": "ubuntu",
      "version": "22.04",
      "arch": "x86_64",
      "boot_bundle": "ubuntu-22.04-x86_64-5.15.0-diskless",
      "kernel_args": "intel_iommu=on iommu=pt vfio-pci.ids=10de:1b06"
    }
  ]
}
```

## 4. 代码变更清单

### 4.1 `src/model.zig` — 新增字段

在 `ProfileConfig` 中增加 `kernel_args: ?[]const u8 = null`。

### 4.2 `src/config/validate.zig` — 安全校验

新增校验函数 `validKernelArgs`，在 `validateProfiles` 中调用：

```zig
fn validKernelArgs(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    for (value) |c| {
        if (c < 0x20 or c == 0x7f) return false;
        // 允许：字母、数字、= . - _ , : 空格
        if (!(std.ascii.isAlphanumeric(c) or c == '=' or c == '.' or
            c == '-' or c == '_' or c == ',' or c == ':' or c == ' ')) return false;
    }
    // 拒绝保留关键字
    const reserved = [_][]const u8{
        "nodeforge.config", "inst.ks", "inst.repo",
        "boot_session_id", "token", "capability",
    };
    for (reserved) |kw| if (std.mem.indexOf(u8, value, kw) != null) return false;
    return true;
}
```

**字符集依据**：
- `=` — `key=value` 参数赋值
- `.` — 点分参数名（`iommu.passthrough`、`processor.max_cstate`）
- `-` — 连字符参数名（`intel_iommu`）和范围（`4-7`）
- `_` — 下划线参数名（`nr_cpus`）
- `,` — 多值分隔（`isolcpus=0,2,4`、`vfio-pci.ids=10de:1b06,8086:1a16`）
- `:` — 十六进制 ID 分隔（`vfio-pci.ids=10de:1b06`）
- 空格 — 多参数分隔

在 `validateProfiles` 中增加：
- discovery 模式：`kernel_args` 必须为 null
- install/diskless 模式：`kernel_args` 非空时调用 `validKernelArgs`

新增错误码 `InvalidKernelArgs`。

### 4.3 `src/boot/target.zig` — PXE cmdline 追加

#### 4.3.1 resolveInstall 改造

当前使用 `std.fmt.bufPrint(cmdline_buf, ...)` 一次性拼接。改造为两段式：

```zig
fn resolveInstall(...) ?BootTarget {
    // ... 现有 profile/source/asset 查找逻辑不变 ...

    const cmdline = if (distro.family == .ubuntu) blk: {
        // ... Ubuntu cmdline 基础部分不变 ...
        const base = std.fmt.bufPrint(cmdline_buf, "...", .{...}) catch return null;
        break :blk appendKernelArgs(cmdline_buf, base, profile.kernel_args) orelse return null;
    } else blk: {
        // ... RHEL cmdline 基础部分不变 ...
        const base = std.fmt.bufPrint(cmdline_buf, "...", .{...}) catch return null;
        break :blk appendKernelArgs(cmdline_buf, base, profile.kernel_args) orelse return null;
    };
    // ... 返回 BootTarget ...
}
```

#### 4.3.2 resolveDiskless 改造

```zig
fn resolveDiskless(...) ?BootTarget {
    // ... 现有 profile/bundle/asset 查找逻辑不变 ...
    const base = std.fmt.bufPrint(cmdline_buf,
        "ip=dhcp nodeforge.config=http://{s}:{d}/api/v1/nodes/{s}/boot-config",
        .{ server_ip, http_port, identity.node_id },
    ) catch return null;
    const cmdline = appendKernelArgs(cmdline_buf, base, profile.kernel_args) orelse return null;
    // ... 返回 BootTarget ...
}
```

#### 4.3.3 新增 appendKernelArgs 辅助函数

```zig
/// 将 kernel_args 追加到 base cmdline 末尾。
/// 返回 cmdline_buf 中的有效切片；缓冲区不足时返回 null（调用方须 log.warn 记录 node_id 与 kernel_args 长度，避免静默失败）。
/// kernel_args 为 null 或空时原样返回 base。
fn appendKernelArgs(buf: []u8, base: []const u8, kernel_args: ?[]const u8) ?[]const u8 {
    const extra = kernel_args orelse return base;
    if (extra.len == 0) return base;
    // base 已经写入 buf[0..base.len]，在后面追加 " " + extra
    if (base.len + 1 + extra.len > buf.len) return null;
    buf[base.len] = ' ';
    @memcpy(buf[base.len + 1 ..][0..extra.len], extra);
    return buf[0 .. base.len + 1 + extra.len];
}
```

**注意**：当前 `cmdline_buf` 大小为 512 字节，RHEL install cmdline 约 180 字节，Ubuntu 约 300 字节。追加 256 字节的 `kernel_args` 可能超限。需要将调用方（`src/tftp/server.zig` 中的 `transferVirtualConfig`）的缓冲区从 512 增大到 1024。

### 4.4 `src/profile/adapter/kickstart.zig` — 目标系统 GRUB

#### 4.4.1 `bootloader --append` 版本兼容性

**pykickstart 源码依据**：`--append` 自 FC3（2003 年）引入，在 RHEL 7/8/9/10 中完整继承，语法完全一致（`bootloader --append="params"`），无需任何版本分支。Anaconda 将 `--append` 值写入目标系统 `/boot/grub2/grub.cfg` 的 `GRUB_CMDLINE_LINUX` 行。

#### 4.4.2 渲染器改造

将 `bootloader` 指令从：

```zig
try w.print("bootloader --boot-drive={s}\n", .{install.storage.boot_disk[5..]});
```

改为：

```zig
if (install.bootloader.install) {
    if (kernel_args) |args| {
        try w.print("bootloader --boot-drive={s} --append=\"{s}\"\n", .{install.storage.boot_disk[5..], args});
    } else {
        try w.print("bootloader --boot-drive={s}\n", .{install.storage.boot_disk[5..]});
    }
}
```

#### 4.4.3 签名变更

`renderAnswerM41` 新增 `kernel_args: ?[]const u8` 参数（而非完整 `ProfileConfig`），最小化接口变更：

```zig
pub fn renderAnswerM41(
    allocator: std.mem.Allocator,
    node: *const model.NodeConfig,
    install: model.InstallConfig,
    system: model.TargetSystemConfig,
    bootstrap_key: []const u8,
    repo_url: []const u8,
    bundle: ?*const model.ProvisioningBundle,
    facts_url: []const u8,
    event_url: []const u8,
    log_url: []const u8,
    session: []const u8,
    token: []const u8,
    password_scope: []const u8,
    kernel_args: ?[]const u8,  // 新增
) ![]u8 {
```

调用方（`src/http/server.zig:818`）已有 `profile` 引用（line 762），传入 `profile.kernel_args` 即可。

**安全说明**：`--append` 值使用双引号包裹，`validKernelArgs` 已拒绝双引号字符，不会发生引号截断注入。Anaconda 解析器以 `--append="` 开始、下一个 `"` 结束，内部不含 `"` 即安全。

### 4.5 `src/profile/adapter/ubuntu.zig` — 目标系统 GRUB

#### 4.5.1 autoinstall 无原生内核参数支持

**官方文档依据**：subiquity `autoinstall-schema.json` 中的 `kernel` 段只有 `package`/`flavor`（选择内核包），`boot`/`grub` 段控制 GRUB 安装但无 `--append` 等效项。唯一可行路径是 `late-commands` 写入 `/etc/default/grub.d/` drop-in 文件。

#### 4.5.2 渲染器改造

在 `renderUserDataM41` 的 `late-commands` 数组**开头**（在所有现有 late-commands 之前）插入两条命令：

```yaml
late-commands:
  # 写入 GRUB drop-in 配置文件（在所有其他 late-commands 之前执行）
  - 'mkdir -p /target/etc/default/grub.d && printf ''%s\n'' ''GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} iommu=pt"'' > /target/etc/default/grub.d/99-nodeforge.cfg && chmod 0644 /target/etc/default/grub.d/99-nodeforge.cfg'
  - 'curtin in-target --target=/target -- update-grub'
  # ... 现有 late-commands 继续 ...
```

#### 4.5.3 实现细节

在 Zig 渲染器中，当 `kernel_args` 非空时：

```zig
if (kernel_args) |args| {
    const grub_cmd = try std.fmt.allocPrint(allocator,
        "mkdir -p /target/etc/default/grub.d && printf '%s\\n' 'GRUB_CMDLINE_LINUX=\"${{GRUB_CMDLINE_LINUX}} {s}\"' > /target/etc/default/grub.d/99-nodeforge.cfg && chmod 0644 /target/etc/default/grub.d/99-nodeforge.cfg",
        .{args});
    defer allocator.free(grub_cmd);
    try w.writeAll("    - ");
    try render.yamlQuote(w, grub_cmd);
    try w.writeByte('\n');
    try w.writeAll("    - 'curtin in-target --target=/target -- update-grub'\n");
}
```

#### 4.5.4 签名变更

`renderUserDataM41` 同样新增 `kernel_args: ?[]const u8` 参数。

#### 4.5.5 安全说明

- `late-commands` 中的 shell 命令通过 `render.yamlQuote` 用 YAML 单引号包裹，`validKernelArgs` 已拒绝单引号，不会发生 YAML 注入
- `${GRUB_CMDLINE_LINUX}` 必须作为字面量写入 drop-in；late-command 在 installer 环境执行，若使用双引号/echo 会
  提前展开错误环境中的变量。fixture 必须逐字断言目标文本保留 `$`，`validKernelArgs` 对用户值拒绝 `$`
- `>` 重定向写入文件（而非 `>>` 追加），确保 99-nodeforge.cfg 只含 NodeForge 管理的参数，不与已有内容冲突

#### 4.5.6 为什么用 `/etc/default/grub.d/` 而非直接修改 `/etc/default/grub`

1. GRUB 2.02+（Ubuntu 22.04/24.04 均使用）支持 `/etc/default/grub.d/*.cfg` drop-in 机制
2. drop-in 文件不会被 grub-pc/grub-efi-amd64 包更新覆盖
3. 直接修改 `/etc/default/grub` 在包升级时触发 `ucf` 冲突提示
4. drop-in 文件可以独立管理，删除时只需 `rm /etc/default/grub.d/99-nodeforge.cfg`

### 4.6 `src/http/server.zig` — BootConfig 响应扩展（diskless）

当前 diskless 模式的 BootConfig 响应体为空（`.diskless => {}`）。M5 diskless initrd 从 `/proc/cmdline` 解析 `nodeforge.config` URL，PXE cmdline 已经携带了 `kernel_args`。

但 BootConfig 也可以将 `kernel_args` 作为 JSON 字段返回，供 initrd 验证或覆盖使用（防止 PXE cmdline 被篡改或截断）。这是 M5 的前置设计，当前实现可以先不做，在 BootConfig 中预留字段：

```json
{
  "mode": "diskless",
  "kernel_args": "iommu=pt",
  ...
}
```

**MVP 决策**：不在 BootConfig 中增加 `kernel_args`。PXE cmdline 是唯一的 kernel_args 传递通道，diskless initrd 从 `/proc/cmdline` 解析即可。如果 M5 发现需要从 BootConfig 覆盖，再增加。

### 4.7 `src/boot/grub.zig` — 无需改动

GRUB 渲染器接收完整的 `cmdline` 字符串，`kernel_args` 已经在 `target.zig` 中拼入。GRUB 渲染器透明传递。

### 4.8 `src/boot/pxelinux.zig`（M6 未实现）— 设计预留

M6 PXELINUX 渲染器将在 `APPEND` 指令末尾追加 `kernel_args`：

```text
LABEL nodeforge
  KERNEL install/rocky/9.7/x86_64/vmlinuz
  APPEND initrd=install/rocky/9.7/x86_64/initrd.img inst.ks=<url> inst.repo=<url> iommu=pt
```

当前不需要实现，但设计文档 §11.4 需要注明 `kernel_args` 的传递方式。

### 4.9 `initrd/dracut/95nodeforge/nodeforge-init.sh`（M5 未实现）— 设计预留

M5 diskless initrd 从 `/proc/cmdline` 解析所有参数。`kernel_args` 中的 `iommu=pt` 等参数由内核直接消费，initrd 不需要特殊处理。initrd 只需要解析 `nodeforge.config` URL，其余参数透传给内核。

### 4.10 缓冲区大小调整

| 位置 | 当前大小 | 调整后 | 原因 |
| --- | --- | --- | --- |
| `src/tftp/server.zig` transferVirtualConfig 中的 cmdline_buf | 512 | 1024 | install cmdline 最长约 300 字节 + kernel_args 256 字节 + 余量 |
| `src/boot/target.zig` 测试中的 cmdline_buf | 512 | 1024 | 同上 |

## 5. 安全分析

### 5.1 注入风险

| 攻击面 | 防护措施 | 依据 |
| --- | --- | --- |
| GRUB 配置注入 | `validKernelArgs` 拒绝引号、分号、反斜杠、`$`、`()`、`{}` | GRUB `linux` 指令以空格分隔参数，拒绝这些字符防止语法逃逸 |
| Kickstart 注入 | 同上；`--append=` 值用双引号包裹（pykickstart `FC3_Bootloader._getArgsAsStr`），双引号已被拒绝 | Anaconda 解析器在 `--append="` 和下一个 `"` 之间取值 |
| YAML 注入（Ubuntu） | 同上；`late-commands` 使用 `render.yamlQuote` 单引号包裹，单引号已被拒绝 | YAML 单引号字符串中 `'` 只能以 `''` 转义，拒绝单引号即安全 |
| Shell 变量注入（Ubuntu） | 用户值拒绝 `$`；NodeForge 自有 `${GRUB_CMDLINE_LINUX}` 以单引号字面量写入 | 防止 installer 环境提前展开和用户变量注入 |
| cmdline token 泄露 | `validKernelArgs` 拒绝 `nodeforge.config`、`inst.ks` 等保留关键字 | 防止操作员覆盖 NodeForge 管理的引导参数 |
| 缓冲区溢出 | `appendKernelArgs` 检查缓冲区剩余空间，不足时返回 null，调用方 `log.warn` 记录上下文 | `cmdline_buf` 从 512 增大到 1024 字节 |

### 5.2 与现有安全策略的关系

- §9.3.3（M4 kernel cmdline 只携带 answer/config URL，不携带 token）：`kernel_args` 不携带任何认证信息，符合此策略
- §9.10.11（一次性安装意图）：`kernel_args` 不影响 install generation / retry 语义
- `toGrubPath` 已有的路径安全校验不受影响（`kernel_args` 不经过 `toGrubPath`）

### 5.3 SELinux 联动

设计文档 §9.10.10 第 3735 行提到"RHEL cmdline 同步 `selinux=0`"，但当前代码未实现。本设计不自动追加 `selinux=0`，但操作员可以手动在 `kernel_args` 中设置 `"selinux=0"`。后续可以作为独立的 SELinux 联动特性实现。

## 6. 文档变更

### 6.1 `docs/DETAILED_DESIGN.md`

#### §9.15 M4.6 自定义内核引导参数

详细设计的权威里程碑为 §9.15，本文件不再插入旧 §9.10.12。

#### 修改 §9.10 配置域表

在 §9.10.10 的配置域表中新增一行：

| 配置域 | 权威事实源 | M4.1 自动安装 | M5 无盘系统 |
| --- | --- | --- | --- |
| 内核引导参数 | `profile.kernel_args` | PXE cmdline 追加 + Kickstart `--append=` | PXE cmdline 追加；initrd 从 /proc/cmdline 透传 |

#### 修改 §11.4 BIOS PXELINUX

在 PXELINUX APPEND 指令说明中注明 `kernel_args` 追加方式。

#### 修改第 432 行 ProfileConfig 伪代码

将 `cmdline_template: []const u8` 替换为 `kernel_args: ?[]const u8 = null`，与实际实现对齐。

#### 修改 §10.4 小 initrd 行为

在 `parse /proc/cmdline` 步骤后注明：`kernel_args` 中的内核参数由内核直接消费，initrd 只解析 `nodeforge.config`。

### 6.2 `docs/DESIGN.md`

#### 修改 §5.2 标准 PXE 引导链

在引导链说明中增加：PXE cmdline 末尾追加 profile 配置的 `kernel_args`。

#### 修改 profile 配置示例

在 Install profile 示例中增加 `"kernel_args": "iommu=pt"`。

### 6.3 `config.example.json`

当前 `config.example.json` 没有 profiles 配置（profiles 通过单独的 JSON 管理）。在文档的 profile 示例中增加 `kernel_args` 字段说明。

## 7. 测试计划

### 7.1 单元测试

| 测试 | 文件 | 验证点 |
| --- | --- | --- |
| `resolve install with kernel_args appends to cmdline` | `src/boot/target.zig` | RHEL install cmdline 末尾包含 `iommu=pt` |
| `resolve Ubuntu install with kernel_args appends to cmdline` | `src/boot/target.zig` | Ubuntu install cmdline 末尾包含 `iommu=pt` |
| `resolve diskless with kernel_args appends to cmdline` | `src/boot/target.zig` | diskless cmdline 末尾包含 `iommu=pt` |
| `resolve install without kernel_args unchanged` | `src/boot/target.zig` | 无 `kernel_args` 时 cmdline 与当前行为一致 |
| `validKernelArgs rejects quotes and semicolons` | `src/config/validate.zig` | `"`、`'`、`;`、`\`、`$` 被拒绝 |
| `validKernelArgs rejects reserved keywords` | `src/config/validate.zig` | `nodeforge.config`、`inst.ks` 被拒绝 |
| `validKernelArgs accepts iommu=pt` | `src/config/validate.zig` | `iommu=pt` 被接受 |
| `validKernelArgs accepts comma and colon` | `src/config/validate.zig` | `vfio-pci.ids=10de:1b06,8086:1a16` 被接受 |
| `validKernelArgs accepts isolcpus range` | `src/config/validate.zig` | `isolcpus=0,2,4-7` 被接受 |
| `discovery profile rejects kernel_args` | `src/config/validate.zig` | discovery 模式设置 `kernel_args` 返回 `InvalidProfileSource` |
| `kickstart renders bootloader --append` | `src/profile/adapter/kickstart.zig` | `bootloader --boot-drive=sda --append="iommu=pt"` |
| `kickstart omits --append when kernel_args null` | `src/profile/adapter/kickstart.zig` | 无 `kernel_args` 时 `bootloader --boot-drive=sda`（不含 `--append`） |
| `autoinstall renders late-commands grub config` | `src/profile/adapter/ubuntu.zig` | 包含 `GRUB_CMDLINE_LINUX` 字面量、0644 和 `update-grub` |
| `autoinstall omits grub config when kernel_args null` | `src/profile/adapter/ubuntu.zig` | 无 `kernel_args` 时 `late-commands` 不含 `99-nodeforge.cfg` |
| `autoinstall writes to grub.d drop-in` | `src/profile/adapter/ubuntu.zig` | 写入 `/target/etc/default/grub.d/99-nodeforge.cfg`（非 `/etc/default/grub`） |

### 7.2 缓冲区边界测试

| 测试 | 验证点 |
| --- | --- |
| `appendKernelArgs with max length` | 256 字节 kernel_args 成功追加 |
| `appendKernelArgs overflow returns null` | 超出缓冲区时返回 null，boot target 解析失败 |
| `cmdline_buf 1024 sufficient for maximum model input` | 以 logical id/URL/host/port 最大合法长度计算 base，再加 256 字节不溢出 |

## 8. 实现顺序

1. **`src/model.zig`**：新增 `kernel_args` 字段（1 行）
2. **`src/config/validate.zig`**：新增 `validKernelArgs` + 错误码 + discovery 校验
3. **`src/boot/target.zig`**：新增 `appendKernelArgs` + 改造 `resolveInstall` / `resolveDiskless` + 测试
4. **`src/tftp/server.zig`**：增大 `cmdline_buf` 到 1024
5. **`src/profile/adapter/kickstart.zig`**：改造 `bootloader` 指令 + 调整 `renderAnswerM41` 签名
6. **`src/profile/adapter/ubuntu.zig`**：在 `late-commands` 中增加 GRUB 配置 + 调整 `renderUserDataM41` 签名
7. **`src/http/server.zig`**：调整 `installConfig` 调用处，传入 `kernel_args`
8. **文档更新**：DETAILED_DESIGN.md、DESIGN.md
9. **测试**：运行全部测试确保无回归

## 8A. 官方文档参考

### Kickstart (pykickstart)

- 源码：`pykickstart/commands/bootloader.py`（GitHub `pykickstart/pykickstart` master 分支）
- `--append` 选项定义在 `FC3_Bootloader._getArgsAsStr()`（line 43-44）
- 版本继承链：`FC3 → FC4 → F8 → F12 → F14 → F15 → F17 → F18 → F19 → F21 → RHEL7 → F29 → RHEL8 → F34 → RHEL9 → F39`
- `--append` 在所有版本中保持不变，未被 deprecated 或 removed
- Anaconda 在安装 plymouth 时自动追加 `rhgb quiet`（pykickstart 帮助文本注释）

### Ubuntu Autoinstall (Subiquity)

- 官方参考：`canonical-subiquity.readthedocs.io/en/latest/reference/autoinstall-reference.html`
- JSON Schema：`raw.githubusercontent.com/canonical/subiquity/main/autoinstall-schema.json`
- `kernel` 段（reference line 1202-1242）：只有 `package` 和 `flavor` 字段
- `late-commands` 段（reference line 1367-1391）：在安装完成后、重启前执行，目标系统挂载在 `/target`
- curtin `boot`/`grub` 配置（`curtin.readthedocs.io/en/latest/topics/config.html#grub`）：控制 GRUB 安装但无内核参数字段
- GRUB drop-in 机制：`/etc/default/grub.d/*.cfg` 由 GRUB 2.02+ 支持，`update-grub` 自动包含

## 9. 非目标

- 不实现 `cmdline_template` 模板方案
- 不在 `NodeConfig` 中增加 node 级 `kernel_args` 覆盖
- 不在 BootConfig JSON 中增加 `kernel_args` 字段（M5 再决定）
- 不自动追加 `selinux=0`（作为独立特性）
- 不实现 PXELINUX 渲染器（M6）
- 不实现 diskless initrd（M5）
