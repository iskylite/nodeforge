# NodeForge v0.5 设计：可切换 rootfs 形态

状态：设计草案，实现未开始。本文定义 v0.5 的 rootfs 形态切换，作为 v0.2 diskless 之后的独立项。
v0.2 已固定 `squashfs_overlay` 为唯一形态（见 [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md)）；
v0.5 引入 `ram_rootfs` 全内存模式与 `diskless.overlay.mode` 字段。与
[`V0_2_DESIGN.md`](V0_2_DESIGN.md) §2/§7 一致。

## 1. 范围与定位

v0.5 只增加 **rootfs 形态可切换**，不动 diskless 主流程的其他部分：

| 项 | v0.2 | v0.5 |
|---|---|---|
| rootfs 形态 | 固定 `squashfs_overlay` | 可选 `squashfs_overlay` / `ram_rootfs` |
| `diskless.overlay.mode` 字段 | 不存在（单值无选择意义） | 新增 PropertySpec |
| BootConfig / initrd / agent / 协议栈 / 状态机 | 已实现 | 原样复用 |

v0.5 不引入 NFS root、iPXE、持久化 overlay 或跨重启 rootfs partial（仍为永久非目标）。

## 2. 两种 rootfs 形态

| 形态 | lower | upper | 内存占用 | 共享性 | 适用 |
|---|---|---|---|---|---|
| `squashfs_overlay`（默认，v0.2 已有） | squashfs 压缩镜像，loop 只读挂载 | tmpfs 写入层 | 中（压缩 lower + 写时 upper） | lower 跨 Node 共享 | 通用，VMware/实机可验证 |
| `ram_rootfs` | 整 rootfs 解压进内存（无 squashfs loop） | 内存即根 | 高（整 rootfs 解压常驻） | 不可共享 lower | 无盘纯内存、极低延迟、无 loop 依赖 |

### 2.1 ram_rootfs 预算校验

`ram_rootfs` 必须在切根前做**内存预算校验**：

- rootfs 的 uncompressed size（build manifest 已记录）+ overlay upper 预留 + 内核/initrd 占用
  须小于节点可用物理内存。
- 预算不足时 initrd 在 `switch_root` 前以稳定 error code 拒绝（`diskless.insufficient_memory`），
  进 `failed` + quarantine，不静默降级到 `squashfs_overlay`。
- 校验依赖 BootConfig 携带的 rootfs `uncompressed_size` 与节点内存（可经 cmdline 或 initrd 探测）。

## 3. 与 BootConfig 的兼容性

**两种形态都能满足 BootConfig 配置方法**。BootConfig 是 per-boot、per-Node 的短时 DTO，由服务端按
pinned DisklessEffectivePlan 在 boot 时生成、initrd 经 node-bound capability 拉取（见
[`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §5）。它携带 rootfs URL/digest/size + Range recovery 与
overlay 配置，与 rootfs **如何物化**（squashfs loop vs 全内存解压）正交：

- `squashfs_overlay`：initrd 下载 squashfs -> loop 挂载 lower -> 建 tmpfs upper -> 写 target-system
  投影到 upper -> switch_root。
- `ram_rootfs`：initrd 下载（可仍是 squashfs 传输，解压到内存 / 或直接传输解压流）-> 预算校验 ->
  解压为内存根 -> 写 target-system 投影 -> switch_root。

两种形态下 per-Node 差异都不烤入 rootfs，只经 BootConfig 落 overlay upper（`ram_rootfs` 的“upper”
即内存根的可写部分）；BootConfig DTO 字段、token 边界、`required_features` 不变。

## 4. 通用与差异

**通用（rootfs 物化之外全部一致）**：

- BootConfig 生成/投递、capability token、secret 边界。
- nodeforge-initrd 引导程序（拉 BootConfig、下载/校验、写 target-system 投影、switch_root）。
- nodeforge-agent 切根后 first-boot 后处理（固定顺序、一次性、确定性+幂等）。
- canonical BootSession 状态机、DHCP/TFTP/HTTP 协议栈。
- effective compiler / readiness / validator、pin 完整性不变式。
- rootfs 共享构建模型（OS 层 + rootfs-build phase + Profile 骨架，按 effective digest 缓存）。
- provision-bundle 四类 action、八步执行契约、event 脱敏。

**差异（仅 rootfs 物化）**：

| 维度 | squashfs_overlay | ram_rootfs |
|---|---|---|
| lower 物化 | squashfs 压缩镜像 loop 只读 | 整 rootfs 解压进内存 |
| 写层 | tmpfs overlay upper | 内存根可写部分 |
| 内存预算校验 | 需要：压缩镜像 tmpfs + upper + reserve | 需要：uncompressed root + reserve（阈值更高） |
| Range recovery | 支持（squashfs 文件） | 支持（传输层一致） |
| 共享 lower | 是 | 否（每节点独立解压） |
| `diskless.overlay.mode` | 不声明（v0.2 单值） | 声明 `ram_rootfs` |

## 5. schema 与字段

- v0.5 新增 `diskless.overlay.mode` PropertySpec，取值 `squashfs_overlay`（默认）/ `ram_rootfs`。
- v0.2 不存在该字段（单值无选择意义，同 v0.1 `connectivity.mode` 逻辑）；v0.5 迁移时默认补
  `squashfs_overlay`，旧配置无 mode 字段等价于 `squashfs_overlay`。
- `ram_rootfs` 形态的 rootfs build manifest 必须记录 `uncompressed_size`（预算校验依赖）。
- schema 版本：v0.5 rootfs 形态字段对应 catalog schema v7（v0.4 使用 v6），与 BootConfig DTO v2、
  `firmware.mode` v5 分属不同命名空间。

## 6. CLI（v0.5）

```text
nodeforge profile set <profile> diskless.overlay.mode=squashfs_overlay
nodeforge profile set <profile> diskless.overlay.mode=ram_rootfs
nodeforge node effective <node>          # 投影 rootfs mode 与 uncompressed_size
nodeforge node rootfs show <node>         # 显示当前形态/digest/uncompressed_size
```

- 两种形态都在 readiness/initrd 双检预算；`ram_rootfs` 额外要求节点可用内存 >= uncompressed_size + 预留；不足则
  readiness 失败（`diskless.insufficient_memory`），不发 bootfile。
- v0.2/v0.3/v0.4 不提供 `diskless.overlay.mode` 的 help/handler；预留 enum 不算实现。

## 7. 验收不变式

- v0.2 不存在 `diskless.overlay.mode` 字段、`ram_rootfs` 路径或其 help/enum。
- v0.5 两种形态下 BootConfig/token/effective plan/agent first-boot 行为一致，差异只在 rootfs 物化。
- `ram_rootfs` 预算不足时 fail closed（`diskless.insufficient_memory`），不静默降级。
- 两种形态的 BootSession canonical 状态机、事件、脱敏、quarantine 语义一致。
- v0.5 不引入 NFS root/iPXE/持久化 overlay/跨重启 rootfs partial（永久非目标不变）。
