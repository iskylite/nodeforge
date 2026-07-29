# NodeForge 运行时产物实测事实

状态：实机产物取证记录
取证环境：r97n0（VMware Fusion / aarch64 / Rocky Linux 9.8）
取证日期：2026-07-29
对应代码基线：`d026bf1`

本文记录直接从 r97n0 已构建产物取证得到的事实。它不定义目标行为，只回答
“当前实现产出的制品到底长什么样”。设计文档与代码注释中关于 initrd 组装、
压缩格式和运行时依赖的表述，必须与本文一致。

## 1. initrd 组装结构

以 `rocky-9.7-nodeforge-initrd.img` 为例：

| 维度 | 实测值 |
|---|---|
| vendor initrd（`assets/boot/install/rocky-9.7-aarch64-minimal/initrd.img`） | 139 507 444 B |
| NodeForge 产物总大小 | 140 012 145 B |
| NodeForge overlay 段 | 504 701 B |
| 前缀保真 | `cmp -n 139507444` 结果为**逐字节一致** |

结论：实现确实是「vendor initrd 原样字节前缀 + 追加独立压缩段」，不是重新打包。

## 2. 压缩格式：vendor 段与 overlay 段不同

实测三个已导入 install source 的 vendor initrd 魔数：

| Install source | 魔数 | 格式 |
|---|---|---|
| `rocky-9.7-aarch64-minimal` | `fd377a585a00` | XZ |
| `rocky-10.2-aarch64-dvd1` | `fd377a585a00` | XZ |
| `ubuntu-22.04.5-live-server-arm64` | `28b52ffd8448` | Zstd |

NodeForge 追加的 overlay 段为 **gzip/newc**（`file` 报告
`gzip compressed data, max compression`）。

这解释了「原样前缀」策略的真实动机，它不只是为了保真：

- 内核的 initramfs 装载器支持**多段拼接**，各段可使用不同压缩格式，依次解压叠加；
- 因此 NodeForge **不需要解压、理解或重新压缩 vendor 段**，也就不需要为
  XZ/Zstd/gzip 各写一套拆装逻辑；
- 跨发行版（Rocky XZ 与 Ubuntu Zstd）用同一条代码路径即可工作。

对应约束：该策略依赖内核 `CONFIG_RD_GZIP` 与 vendor 段格式对应的
`CONFIG_RD_XZ`/`CONFIG_RD_ZSTD`。同源 kernel 与 initrd 必然满足，
这也是 boot bundle 强制 kernel/initrd 同源的一个额外理由。

## 3. overlay 段内容清单

overlay 解包后仅 5 个条目：

```text
./init
./usr/sbin/nodeforge-initrd
./usr/sbin/nodeforge-agent
./usr/sbin/nodeforge-dhclient-script
./usr/sbin/nodeforge-udhcpc-script
```

`init` 与 `usr/sbin/nodeforge-initrd` 的 MD5 相同
（`3227ddea3be9db28afc05971904f81b6`），即 **PID 1 直接是 Zig 二进制**，
中间没有 shell 包装层。

## 4. 运行时依赖契约（重要且此前未成文）

`nodeforge-initrd` 由 `zig build -Dtarget=aarch64-linux-gnu` 产出，是
**动态链接**可执行文件：

```text
ELF 64-bit LSB executable, ARM aarch64, dynamically linked,
interpreter /lib/ld-linux-aarch64.so.1
```

而 overlay 段本身**不包含** glibc。实测 vendor initrd 解包后提供：

| 依赖 | vendor initrd 中的路径 |
|---|---|
| 动态链接器 | `./usr/lib/ld-linux-aarch64.so.1` |
| C 运行时 | `./usr/lib64/libc.so.6` |
| iproute2 | `./sbin/ip`、`./usr/sbin/ip` |

vendor 段共 5747 个条目。两个 DHCP 脚本显式调用 `/sbin/ip`，同样由 vendor 段满足。

因此存在一条此前未写入设计文档的**硬契约**：

> NodeForge diskless initrd 的 PID 1 及其辅助脚本，其 glibc 动态链接器、
> `libc.so.6` 和 iproute2 全部由 vendor initrd 提供。vendor initrd 必须是
> 包含完整 glibc 用户态的 dracut/casper 产物。

违反该契约的后果是**节点在 PID 1 启动瞬间失败**（内核找不到 interpreter），
且此时尚无网络与日志通道，现场只有 console 上一行内核报错，排障成本极高。

该契约对后续版本的直接约束：

1. 不能改用「仅内核模块、无 userspace」的极简 vendor initrd；
2. v0.2.1 接入 Ubuntu casper vendor initrd 时，必须同样校验其提供
   glibc 与 `ip`，不能假定与 dracut 布局一致；
3. 若未来要解除该耦合，正确做法是把 `nodeforge-initrd` 构建为**静态链接**
   （`-Dtarget=aarch64-linux-musl` 或 glibc 静态），而不是把 glibc 复制进 overlay。

建议在 initrd builder 中增加一条构建期校验：解析 vendor initrd 的段结构，
确认动态链接器与 `libc.so.6` 存在，缺失时 fail-closed 并给出可操作错误，
把一个「节点侧无声 panic」前移为「构建期明确失败」。

## 5. 交叉编译产物基线

本地 `zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe`（约 32 s）：

| 产物 | 大小 | 链接与符号 |
|---|---|---|
| `nodeforge` | 10 864 536 B | 动态链接，含 debug_info，未 strip |
| `nodeforged` | 20 326 304 B | 动态链接，含 debug_info，未 strip |
| `nodeforge-initrd` | 353 368 B | 动态链接，已 strip |
| `nodeforge-agent` | 418 176 B | 动态链接，已 strip |

两个节点侧执行器已 strip，两个管理面程序保留 debug_info。

## 6. 制品目录观察：rootfs 无回收机制

`/opt/nodeforge/assets/rootfs/` 实测有 **6 个 squashfs**，而当前 catalog 中
只有 2 个 profile 引用其中 2 个：

| 内容寻址文件 | 大小 | 是否被引用 |
|---|---|---|
| `e9374835…squashfs` | 139 964 416 B | 是（`rocky-9.7-diskless`） |
| `482aba97…squashfs` | 111 497 216 B | 是（`rocky-10.2-diskless`） |
| `9d4ed51d…`、`2bc74691…`、`46953599…`、`9793dd07…` | 111–140 MB | 否 |

即重复构建产生的历史制品会**无限累积**，当前没有 GC、引用计数或保留策略。
本轮实测中 4 个孤儿制品已占用约 495 MB。这不是数据正确性缺陷（内容寻址保证
不会错误命中），但属于可运营性缺口，应纳入 v0.2.2：制品引用计数 +
`nodeforge assets rootfs prune` 保留策略。
