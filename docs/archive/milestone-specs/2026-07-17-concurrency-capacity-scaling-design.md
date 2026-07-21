# M4.8 并发容量扩展与启动时动态派生 — 专项设计

- 日期：2026-07-17
- 里程碑：M4.8（编号在 M4.7 之后，实施早于 M4.6）
- 详细设计章节：`docs/archive/M0_M7_LEGACY_DETAILED_DESIGN.md` §9.17
- 关联：M4.2（TFTP 性能字段）、M4.3（ConfigRuntime/observability）、M6（压测校准）

## 1. 背景与目标

支持 **512/1024 节点同时批量 PXE 部署**。经代码核查（见 §2），当前实现受三处硬约束阻碍，
任何 config 调整都无法绕过：

1. **5 处定长 256 上限**：跨 DHCP/TFTP/HTTP 共享的内存定长数组，编译期固定，改 config 无效。
2. **TFTP `max_concurrent_transfers` 为全局上限**（非文档所述 per-client），默认 4，校验封顶 64。
3. **DHCP OFFER 前串行 ICMP ping**，`ping_timeout_ms` 默认 500。

目标：以“2048 条编译期安全天花板 + 启动时有效容量、config 可覆盖”替代硬编码 256，使运维仅靠配置
（`subnet`/`pool` 调宽 + 按需覆盖）即可把规模调到 512/1024，**无需改代码重编译**。

本里程碑是横向容量优化，与 M4.6（`kernel_args`）、M4.7（路径/存储边界）内容正交，
可在 M4.5 完成后立即落地，故编号虽在 M4.7 之后但实施早于 M4.6。不依赖 `http_accel`，
纯 TFTP/DHCP/HTTP 三者一起考虑。

## 2. 现状与约束（代码证据）

### 2.1 5 处定长 256 上限

| 固定数组 | 位置 | 打满后果 |
|---|---|---|
| `boot_session.max_sessions` | `src/state/boot_session.zig:13` | TFTP 无法解析启动身份（`access_violation`），虚拟 grub.cfg 拒发 |
| `DhcpState.max_leases` | `src/state/runtime.zig:51` | 无法分配地址 |
| `node_status.max_statuses` | `src/state/node_status.zig:7` | 拒绝新投影并记录 capacity event |
| `node_inventory.max_entries` | `src/state/node_inventory.zig:4` | inventory 拒收 |
| `deployment_control.max_entries` | `src/state/deployment_control.zig:10` | 部署态拒收 |

均为 `[_]T{.{}} ** max_xxx` 形式的固定数组。

### 2.2 TFTP 并发

- `src/tftp/server.zig:107` 的 `active_transfers = std.atomic.Value(u8).init(0)` 是**单一全局
  计数器**，`reserveTransferSlot`（server.zig:132）直接比 limit；**无任何按源 IP/MAC 的 per-client
  计数**。故 `max_concurrent_transfers=4` 是系统级，非文档/per-client 措辞所述。
- 超限直接回 `ERROR "server busy, retry later"`（server.zig:134）**拒绝不排队**。
- 字段 `max_concurrent_transfers: u8`（`src/model.zig`），校验 `> 64` 拒绝（`src/config/validate.zig`）。
- GRUB 的 TFTP 客户端不协商 RFC 7440 windowsize，服务端回退 `windowsize=1`（停等），
  每传输 RTT 限约 **2 MB/s**；initrd（133 MB）单传需 ~66 s。

### 2.3 DHCP

- `src/dhcp/server.zig:217` 的 `probe.ping(io, reply.yiaddr, config.dhcp.ping_timeout_ms)` 在单线程
  循环里**串行**执行；空闲 IP 最坏等满 `ping_timeout_ms`（默认 500）。1024 台突发 = 8 分钟级
  串行瓶颈。DHCP 单线程小包循环本身非吞吐墙（基线 200 pps）。

### 2.4 HTTP

- 单事件循环 + 异步零拷贝 sendfile（`src/http/server.zig:553`），`zap.start(.{ .threads=1, .workers=1 })`
  （server.zig:188）。单线程非传输瓶颈。
- `http.max_connections`（`src/model.zig:71-79`）：**死字段，全代码未读**；M6 原计划"压测后固化"。
- 真正的并发墙在 OS 层（fd/磁盘）：每 HTTP 下载 ~2 fd，代码未调 `setrlimit`。

### 2.5 subnet / pool / 受管节点

- `dhcp.subnet`（CIDR）、`pool_start`/`pool_end` 是 config 字段（运维配置）。
- `max_leases` 等 5 个上限**不是 config 字段**，是代码常量——这是当前规模无法靠 config 突破的根因。

## 3. 设计

### 3.1 原则

1. 共享热路径 store 使用 **2048 条编译期安全天花板**；启动时派生 effective，config 可覆盖；
   `effective = min(2048, max(派生, config))`。
2. `subnet`/`pool_start`/`pool_end` 由运维配置；系统**只从中派生容量，不替运维调宽**。
3. daemon **启动时打印关键性能参数生效值**。
4. TFTP 并发为**全局语义**（PXE 客户端顺序取文件，per-client > 1 无意义；全局是正确节流）。
5. 不引入 `http_accel`；纯 TFTP/DHCP/HTTP。

### 3.2 容量上限动态化

5 处原固定 256 上限统一提升到 **2048 条编译期安全天花板**。leases/session/status/deployment
继续使用固定数组以保持锁内无分配和可预测内存，inventory 保持 ArrayList。`effective` 表示允许的已用条目数，
不是数组前缀长度：查找遍历全部槽位，创建时才按 used count 限流。

| 数组 | 派生来源（默认） |
|---|---|
| `DhcpState.leases` | `max(usable_hosts(dhcp.subnet), config)` |
| `boot_session` | 同 leases（并发启动 = 并发 lease，同源） |
| `node_status` | `max(受管节点数, config)` |
| `node_inventory` | `max(受管节点数, config)` |
| `deployment_control` | `max(受管节点数, config)` |

- **并发容量**（leases + sessions）= `max(usable_hosts(dhcp.subnet CIDR), config)`。
  `/22` -> 1022、`/24` -> 254。1024 个可用地址至少需要 `/21`（2046 hosts）；`/22` 不足 1024。
- **受管容量**（status/inventory/deployment）= `max(受管节点数, config)`。受管节点数取
  `config.nodes`（M4.7 后取 Catalog 节点数）。与并发不同源：未知节点拿 lease 但不进 status 投影。
- 显式字段为 `dhcp.max_leases` 和 `capacity.managed_entries`，合法范围 `1..2048`。恢复后 effective
  还要以 restored used count 为下限，确保缩容不隐藏历史状态或制造重复条目。
- `node-status.json` 升级为紧凑 schema 4，仅序列化 used 记录和实际字符串；加载器以 8 MiB 兼容读取
  现存 schema 3 固定数组快照。`leases.json` 也只写 used lease。

### 3.3 TFTP 并发：`max_concurrent_transfers` 自动派生

- 默认 = `max(128, 2 × cpu_cores)`，config 可覆盖。
- 字段 `u8` -> `u16`（2×核在 ≥128 核机器溢出 u8）。
- 计数器 `active_transfers`（server.zig:107）：`Value(u8)` -> `Value(u16)`。
- 移除 `validate.zig` 的 `> 64` 校验上限。
- 启动时 `std.Thread.getCpuCount()` 派生。
- 文档对齐：全局（非 per-client）+ auto 派生；修正 `model.zig:99-102` docstring 与
  `2026-07-14-m4_2-provisioning-robustness-design.md` §7.2 的 per-client 措辞。
- 吞吐：每传输 RTT 限 ~2 MB/s，聚合随并发线性增长至打满线。千兆下 64 并行即 ~128 MB/s 打满；
  `max(128, 2×核)` 为 10GbE/多核预留，千兆上不增反不损。每并发 = 1 detached 线程 + 1 临时 UDP socket，
  128~192 对 OS 无压力。要真正吃满 10GbE 需 ~625 并发（u16 容纳）。

### 3.4 DHCP `ping_timeout_ms`

- 默认 `500` -> `100`。保留 ping 防冲突语义，突发下 OFFER 延迟可接受。

### 3.5 HTTP `max_connections` 死字段处理

- 二选一，不得继续留作误导：**(a)** 接上做真正的并发上限；**(b)** 标注为 advisory/未强制并更新文档。
- 单事件循环 + 异步 sendfile 保留；120 s 超时保留。并发墙在 OS 层（见 §3.7）。

### 3.6 启动日志打印生效容量

daemon 启动时输出派生后的生效值：

```
nodeforged: capacity derived
  dhcp.subnet=192.168.0.0/21 -> usable_hosts=2046
  max_leases=2046  max_sessions=2046  ceiling=2048
  managed_nodes=1024 -> max_statuses/inventory/deployment=1024
  tftp.max_concurrent_transfers=128 (max(128, 2×cores=64))
  dhcp.ping_timeout_ms=100
  http.max_connections=0 (unlimited/unenforced)
```

### 3.7 系统层与运维（非代码，不进 M4.8 代码改动）

- `ulimit -n` / systemd `LimitNOFILE` ≥ 8192。
- TFTP UDP 接收缓冲：`SO_RCVBUF` / `net.core.rmem_max` 调大。
- 资产盘 SSD/NVMe。
- 波次部署：`reinstall_policy=explicit` + generation 门控，每波 ≤ 派生并发容量。

## 4. 代码改动清单

1. **5 处 256 上限 -> 2048 安全天花板 + 各自 effective 派生 + config 覆盖**。
   - `src/state/runtime.zig`（leases）、`boot_session.zig`、`node_status.zig`、`node_inventory.zig`、
     `deployment_control.zig`；新增启动时派生 `usable_hosts(subnet)` 与受管节点数。
2. **TFTP**：`max_concurrent_transfers` 字段 `u8`->`u16`、`active_transfers` `Value(u8)`->`Value(u16)`、
   去 `validate.zig` 的 64 上限、启动 `getCpuCount()` 派生 `max(128, 2×核)`。
3. **DHCP**：`ping_timeout_ms` 默认 `500`->`100`（`src/model.zig` DhcpConfig）。
4. **HTTP**：`max_connections` 死字段处理（接上 or 标注）。
5. **启动日志**：打印派生容量生效值。
6. **文档**：对齐 `max_concurrent_transfers` 全局/auto 语义（docstring + spec §7.2）。
7. **持久化**：status schema 4 紧凑写入并兼容 schema 3；leases 仅写 used。

## 5. 不在范围

- `subnet`/`pool_start`/`pool_end`：运维配置，系统只读取派生。
- `http_accel`：实验性（GRUB EFI 内存碎片），不在 M4.8 改动。
- 实际压测生产数字：M6 在 M4.8 动态派生基础上压测校准，不再设静态默认值。
- 数据库：单机 1000 节点仍用 JSON/JSONL。

## 6. 测试与验收

- 网段派生容量：`subnet=/22` -> leases/sessions=1022；`/24` -> 254。
- auto 并发：`getCpuCount` 派生 `max(128, 2×核)`；config 显式覆盖生效。
- > 256 并发不再被拒：派生到 1022 时第 257 台仍能完成 PXE。
- `u16` 字段：`max_concurrent_transfers = 128/192/255` 通过校验。
- 启动日志：派生生效值打印正确且与实际配置一致。
- `ping_timeout=100`：突发下 OFFER 延迟可接受，防冲突语义保留。
- 回归：config 显式指定旧值（`max_concurrent_transfers=4`、容量 256）时行为不变。
- 恢复条目即使位于 effective 之外的槽位也能查找/更新；达到 used count 上限才拒绝新增。
- schema 4 状态文件只写 used，schema 3 大快照可迁移；lease 文件只写 used。

## 6.1 r97n0 实测发现与修正依据（2026-07-17）

- 2048 槽 schema 3 的空状态快照约 4.12 MiB，而旧加载上限仅 1 MiB；生产日志已出现
  `node-status snapshot: StreamTooLong`。因此必须采用紧凑 schema 4，并为一次性迁移放宽读取上限。
- effective=1、历史条目位于 slot 1 时，原“扫描前缀”实现会在 slot 0 再创建一条；因此 effective
  必须是 used count 门控，不能是存储布局边界。
- `/16` 派生 65534，但实际安全天花板仍是 2048。启动日志必须同时输出 derived/effective/ceiling，
  不能把 clamp 前的派生值误报为实际容量。
- profile 修改触发 daemon reload 时，旧 schema 3 状态快照加载失败会使 Runtime Phase 变成 `-`；同时
  list/show 把新 desired profile、旧 consumed generation 和新 requested_at 拼到一行。紧凑 schema 4 只解决
  “丢状态”，聚合层还必须要求 status 的 `model_revision`/`deployment_generation` 与当前视图一致。
- `deployed_at` 定义为最近一次成功时间，不能在 retry 时清零。当前尝试只清零 started/finished；CLI 分开显示
  current generation 与 last successful generation，inventory 也显示其来源 generation，避免把历史硬件观测误认为
  本次安装刚刚上报。

## 7. 容量预估（千兆，全部生效后）

| 阶段 | 1024 台 | 瓶颈 |
|---|---|---|
| PXE 启动（TFTP 内核+initrd） | ~20 min | 千兆线 + initrd ~2 MB/s/传输 |
| OS 安装（HTTP repo/ISO） | 数十分钟~数小时 | 磁盘 IO + 千兆线 |

## 8. 实施顺序

M4.5 完成后立即落地 M4.8（横向优化，与 M4.6/M4.7 正交），随后再按 M4.6、M4.7 推进。
编号保持 M4.8 以反映其"容量扩展"的归属，不与 M4.6/M4.7 内容混淆。
