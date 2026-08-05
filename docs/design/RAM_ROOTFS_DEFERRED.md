# NodeForge `ram_rootfs` materialization 保留设计

状态：独立保留设计，短期不计划实现；不属于 v0.4 设计、实现或完成闸，也不占用当前产品版本号。当前排期状态以 [`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md) 为准。

统一索引：[`DEFERRED_DESIGN_INDEX.md`](DEFERRED_DESIGN_INDEX.md)。

保留说明：本文保存从主路线划出的 `ram_rootfs` 设计，供未来需求与验收条件成熟后重新立项。本文已经按
[`V0_4_DESIGN.md`](V0_4_DESIGN.md) 的 BootConfig v3、AgentPlan v2、strict encoding 和 fresh replacement 边界整理，
但不冻结未来产品版本、catalog schema 或 DTO 编号，也不属于 v0.4 完成闸。未来重新立项时必须从当时已实现基线分配
新的唯一编号；本文中的“下一版/后续 DTO”不是预留 enum 或兼容承诺。

延后原因与 BIOS/PXELINUX 不同：`ram_rootfs` 不受 x86 验证环境阻塞，当前 aarch64 VMware 理论上可以验证；
但现有 `squashfs_overlay` 已满足主流程，而全内存展开还需要峰值内存、metadata 保真、内存压力和长稳 E2E，
短期收益不足以进入实现计划。因此它属于“有设计价值但未排期”，不是“当前环境无法验证”。

本文不属于带版本号路线图；最早只能在 v0.4 完成后重新评审。
v0.2 已固定 `squashfs_overlay` 为唯一形态（见 [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md)）；
未来立项可引入 `ram_rootfs` 全内存模式与 `diskless.overlay.mode` 字段，但当前任何产品 schema/help/handler 都不得
出现这些字段。

## 1. 范围与定位

未来候选只增加 **rootfs 形态可切换**，不动 diskless 主流程的其他部分：

| 项 | v0.4 基线 | 未来候选 |
|---|---|---|
| rootfs 形态 | 固定 `squashfs_overlay` | 可选 `squashfs_overlay` / `ram_rootfs` |
| `diskless.overlay.mode` 字段 | 不存在（单值无选择意义） | 新增 Profile-only PropertySpec |
| BootConfig / AgentPlan / initrd / agent | BootConfig v3 + AgentPlan v2、固定 squashfs mount | BootConfig 必须升到立项时分配的下一版本并增 mode/expanded size；若 AP shape 不变则保持当时版本 |

未来该候选也不引入 NFS root、iPXE、持久化 overlay 或跨重启 rootfs partial（仍为永久非目标）。

## 2. 两种 rootfs 形态

| 形态 | lower | upper | 内存占用 | 共享性 | 适用 |
|---|---|---|---|---|---|
| `squashfs_overlay`（默认，v0.2 已有） | squashfs 压缩镜像，loop 只读挂载 | tmpfs 写入层 | 中（压缩 lower + 写时 upper） | lower 跨 Node 共享 | 通用，VMware/实机可验证 |
| `ram_rootfs` | 同一 squashfs 传输制品解压进内存（无 loop lower） | 内存即根 | 高（整 rootfs 解压常驻） | 制品共享、运行实例不共享 | 无盘纯内存、极低延迟、无 loop 依赖 |

### 2.1 ram_rootfs 预算校验

`ram_rootfs` 必须在切根前做**运行态与解压峰值双重内存预算校验**。先规范化可分配预算：服务端 readiness 使用
`available_budget = inventory.memory_bytes - kernel_initrd_bytes`（checked subtraction），initrd 使用当时
`/proc/meminfo` 的 `MemAvailable` 作为 `available_budget`，因为该值已扣除正在运行的 kernel/initrd 占用，不能再次扣减：

- 令 `growth_reserve = overlay.minimum_free_bytes`、`root_limit = floor(available_budget * tmpfs_percent / 100)`，
  `node_payload_size` 为 Node first-boot override payload 的精确字节数（无 override 时为 0），
  `ram_rootfs` 必须同时满足：

  ```text
  uncompressed_size + growth_reserve <= root_limit
  compressed_size + uncompressed_size + node_payload_size + growth_reserve + safety_margin <= available_budget
  ```

  第一式限制展开后的可写根预算；第二式覆盖下载完成到删除 squashfs 前压缩制品、展开副本与 Node payload 同时驻留的峰值，并保留
  系统安全余量。不能漏掉压缩副本或 Node payload，也不能在 initrd 的 `MemAvailable` 上重复计算 kernel/initrd。所有 size 使用
  `u64` bytes 并做 checked arithmetic，溢出按 `diskless.invalid_memory_budget` fail closed。
- 预算不足时 initrd 在 `switch_root` 前以稳定 error code 拒绝（`diskless.insufficient_memory`），
  进 `diskless.failed` 并按 failure budget 进入 quarantine，不静默降级到 `squashfs_overlay`。
- 校验依赖 BootConfig 携带的 rootfs `uncompressed_size` 与节点内存（可经 cmdline 或 initrd 探测）。
- 服务端只有在可信 inventory 存在时才能给出 pass/fail。面向 inventory 总内存的最小值固定为：

  ```text
  runtime_required = ceil_div((uncompressed_size + growth_reserve) * 100, tmpfs_percent)
  peak_required = compressed_size + uncompressed_size + node_payload_size + growth_reserve + safety_margin
  required_min_memory_bytes = kernel_initrd_bytes + max(runtime_required, peak_required)
  ```

  `tmpfs_percent` 必须在既定 10-80 范围内；乘法、加法和 `ceil_div` 全部 checked。inventory memory 未知时 readiness
  输出 `memory=unknown`、`required_min_memory_bytes` 与 warning，最终由 initrd 以实测 `MemAvailable` 对前两式硬闸，
  不能把 unknown 显示成 passed。

## 3. 与 v0.4 BootConfig 基线的关系

两种形态沿用同一 BootConfig 投递方法，但字段 shape 变化时必须分配新的 BootConfig 版本，不能在 v3 下静默加字段。
BootConfig 是 per-boot、per-Node 的短时 DTO，由服务端按
pinned DisklessEffectivePlan 在 boot 时生成、initrd 经 node-bound capability 拉取（见
[`DISKLESS_FINAL.md`](DISKLESS_FINAL.md) §5）。它携带 rootfs URL/digest/size + Range recovery 与
overlay 配置，与 rootfs **如何物化**（squashfs loop vs 全内存解压）正交：

- `squashfs_overlay`：initrd 下载 squashfs -> loop 挂载 lower -> 建 tmpfs upper -> 交接 AgentPlan locator
  -> switch_root 到 agent pre-init；agent 从服务端拉取并校验 immutable plan/payload，写 target-system 投影到 upper，再 exec 真正 init。
- `ram_rootfs`：initrd 仍下载并完整校验同一 squashfs 文件 -> 预算校验 -> `unsquashfs` 解压为内存根 ->
  校验展开后 metadata -> 删除 `/run/nodeforge/image/rootfs.part` -> 确认没有 loop/fd 继续引用压缩制品 ->
  交接 AgentPlan locator -> move-mount `/run` -> switch_root 到 agent pre-init；agent 拉取并校验 plan/payload 后直接写内存根。删除或引用检查失败时不得声称进入 steady-state memory
  budget，也不得 handoff。该候选不增加 raw/tar/流式未校验传输变体。

两种形态下 per-Node 差异都不烤入共享 rootfs；BootConfig 只携带 immutable AgentPlan locator，统一由 agent pre-init
从服务端取得 expected digest 的 plan 后落运行根
（`ram_rootfs` 没有 overlay upper，直接写内存根）。后续 BootConfig 在 v0.4 v3 基础上给 `overlay` 增加必填 `mode`，
并把 `rootfs.uncompressed_size` 从 optional 提升为 required；token 边界不变。该未来版本的全部 delivery 只使用新 DTO，
v3 及更早 initrd 在 readiness 阶段被拒绝。就 materialization 维度而言，仅 `mode=ram_rootfs` 增加
`ram-rootfs-v1`；继承的
`node-apply-v1`/`node-firstboot-payload-v1` 仍按 projection 是否存在决定。`squashfs_overlay` 不得无故要求
ram-only feature，但其 initrd 仍必须声明支持新 BootConfig schema。

`ram-rootfs-v1` 不只是 enum token：initrd manifest 必须证明包含与目标 squashfs 兼容的 `unsquashfs`，并在解压后
校验文件类型、mode/uid/gid、硬链接、symlink、xattr、ACL、Linux file capability 与 SELinux label 保真。任何不支持的
manifest feature 或解压后校验差异在 handoff 前失败，不能通过忽略 xattr/capability 降级启动。

该能力必须采用与 v0.4 相同的 fresh replacement：旧 deployment 的 active/recoverable session 全部拒载，不存在跨产品
版本继续消费旧 BootConfig。新 deployment 内较早 Profile revision 的 active session 仍消费自身 immutable snapshot，
这只是同一 deployment 内的 snapshot 稳定性，不是跨版本兼容。

## 4. 通用与差异

**通用（rootfs 物化之外全部一致）**：

- BootConfig 生成/投递方法、capability token、secret 边界（DTO schema 在立项时分配下一版本）。
- nodeforge-initrd 引导程序（拉最小 BootConfig、下载/校验/物化 rootfs、交接 AgentPlan locator、switch_root）。
- nodeforge-agent 切根后先以 pre-init 入口拉取并校验 immutable AgentPlan/payload，执行 Node node-apply 并 exec 真正 init，再由 systemd first-boot unit
  执行 effective bundle（固定顺序、一次性、确定性+幂等）；
  Node first-boot override payload 在两种 rootfs 形态下都由 agent pre-init 预取到 `/run`，不进入共享 rootfs。
- canonical BootSession 状态机、DHCP/TFTP/HTTP 协议栈。
- effective compiler / readiness / validator、pin 完整性不变式。
- rootfs 共享构建模型（OS 层 + rootfs-build phase + Profile 骨架，按 `rootfs_input_digest` 缓存）。
- provision-bundle 四类 action、八步执行契约、event 脱敏。

**差异（仅 rootfs 物化）**：

| 维度 | squashfs_overlay | ram_rootfs |
|---|---|---|
| lower 物化 | squashfs 压缩镜像 loop 只读 | 整 rootfs 解压进内存 |
| 写层 | tmpfs overlay upper | 内存根可写部分 |
| 内存预算校验 | 需要：压缩镜像 tmpfs + upper + reserve | 需要：uncompressed root + reserve（阈值更高） |
| Range recovery | 支持（squashfs 文件） | 支持（传输层一致） |
| 共享 cache artifact | 是 | 是（同一 squashfs/input digest） |
| 运行时 lower | 共享制品各节点 loop mount | 无 loop lower；每节点独立解压 |
| `diskless.overlay.mode` | `squashfs_overlay` | `ram_rootfs` |

## 5. schema 与字段

- 未来立项新增 `diskless.overlay.mode` PropertySpec，取值 `squashfs_overlay`（默认）/ `ram_rootfs`。
- `diskless.overlay.mode` 是 diskless Profile policy，不提供 Node override；同一 Profile revision 的全部 Node 使用同一
  materialization mode。主机内存等 Node 特性只参与 readiness/实测预算，不反向改写或自动选择 mode。
- v0.4 及更早不存在该字段（单值无选择意义）。fresh replacement 后新 Profile 缺省显式物化为
  `squashfs_overlay`；旧 config/catalog 不加载，因此不存在“缺字段兼容等价”或迁移时补默认值。
- v0.4 BootConfig v3 在 nodeforged 构建期测量失败时可将 `uncompressed_size` 留为 unknown（此时只告警并跳过容量硬校验）；
  后续 DTO 若把它提升为 required，fresh deployment 中所有 artifact 都必须重新构建并 deep validate 得到可信
  manifest，不能复用旧 index、回填旧 artifact 或按压缩大小猜测。
- `diskless.overlay.tmpfs_percent` 在 `squashfs_overlay` 下继续控制 upper 预算；在 `ram_rootfs` 下控制展开后
  writable root 可占 `MemAvailable` 的最大比例。这样既有字段不被静默忽略，范围仍为 10-80。
- catalog、BootConfig 和 state 是独立 namespace；未来立项分别分配“当时基线的下一唯一版本”，不能预占 catalog v7、
  BootConfig v4/v5 或假设中间没有其他 schema 变更。
- `diskless.overlay.mode` 进入 `desired_plan_digest` 和 `delivery_digest`，但不进入 `rootfs_input_digest`：两种 mode
  消费同一 squashfs cache artifact。mode 改变需要重新 readiness/enable，不需要重建 rootfs。

## 6. 候选 CLI（未排期）

```text
nodeforge profile set <profile> diskless.overlay.mode=squashfs_overlay
nodeforge profile set <profile> diskless.overlay.mode=ram_rootfs
nodeforge node show <node>                  # Effective 分区展示绑定 Profile 的 rootfs mode
nodeforge node boot preview <node>          # 展示本次启动选择与节点内存预算
nodeforge profile rootfs status <profile>   # 显示所选交付形态/digest/uncompressed_size（复用 v0.2 命令）
```

- `profile rootfs status` 复用 v0.2 已有命令，输出增加 Profile 当前选择的 `overlay_mode` 和 artifact 的
  `uncompressed_size` 字段；mode 不是 artifact identity，同一 digest 可被两种 mode 复用。
  不新增 `node rootfs show`（避免把 Profile 制品所有权误放到 Node；节点解析结果由 `node status` 显示）。
- 两种形态都在 readiness/initrd 双检预算；可信 inventory 已知且不足时 readiness 失败
  （`diskless.insufficient_memory`），不发 bootfile。inventory 未知时输出 warning 与 required minimum，initrd 以实测
  `MemAvailable` 执行同一公式，失败时不 `switch_root`。
- `profile rootfs plan` 输出增加 `overlay_mode` 和 `estimated.uncompressed_bytes`（v0.2 已有）；
  `estimated.compressed_bytes` 始终是共享 squashfs 传输大小，不因 mode 改变；另输出 mode 对应的
  `required_min_memory_bytes`。
- `boot preview` 的 capsule/kernel/initrd 路径不变，但 JSON 必须显示实际分配的 `bootconfig_schema`、`overlay_mode`、
  `required_features` 和内存预算摘要，不能声称输出完全不受影响。
- 从实施时产品基线到该能力采用 fresh replacement：旧 config/catalog/state/session/artifact index 全部拒载，操作员重新
  `setup`、导入/构建制品。新 Profile 默认显式为 `squashfs_overlay`；不存在跨 deployment active session 延续。
- 当前 v0.4 及更早不提供 `diskless.overlay.mode` 的 help/handler；预留 enum 不算实现。

## 7. 验收不变式

- 当前 v0.4 及更早不存在 `diskless.overlay.mode` 字段、`ram_rootfs` 路径或其 help/enum。
- 未来两种形态下 token/effective plan/agent node-apply/first-boot 行为一致；新 BootConfig 显式携带 mode/expanded size，
  差异只在经过完整校验后的 rootfs 物化。
- `ram_rootfs` 预算不足时 fail closed（`diskless.insufficient_memory`），不静默降级。
- mode 只改变 desired/delivery digest，不改变 rootfs input digest；同一 ready squashfs 可在两种 mode 间复用。
- 新 delivery 面对旧 BootConfig initrd、缺可信 uncompressed size 时在 boot readiness 阶段 fail closed；
  旧 deployment session 不加载、不迁移。`mode=ram_rootfs` 时
  另要求 `ram-rootfs-v1`、`unsquashfs` 与 metadata/xattr/capability 保真 fixture，`squashfs_overlay` 不要求 ram-only feature。
- ram_rootfs 两条内存公式在 readiness 与 initrd 使用相同 checked arithmetic，并覆盖压缩/展开副本并存峰值、等号边界、
  `MemAvailable` 不重复扣 kernel/initrd、ceil-div/加乘溢出、inventory unknown、initrd 实测不足和 safety margin 负向测试。
- 两种形态的 BootSession canonical 状态机、事件、脱敏、quarantine 语义一致。
- `ram_rootfs` 在 handoff 前删除压缩 `.part` 并证明无 loop/fd 引用；删除失败不能进入 steady-state budget。
- fresh replacement、旧 layout/DTO/session/artifact index 全部拒载、同一新 deployment 内 immutable snapshot 稳定均有 fixture；
  不提供迁移/downgrade/双读路径。
- 未来候选不引入 NFS root/iPXE/持久化 overlay/跨重启 rootfs partial（永久非目标不变）。
