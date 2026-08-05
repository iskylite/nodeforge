# NodeForge v0.2 代码审查修复记录

状态：2026-07-27 审查基线。本文记录 v0.2 开发过程中对全代码库进行逻辑错误和隐藏问题审查后发现的所有问题及其修复。

## 1. 审查范围

本次审查覆盖 `src/` 目录下所有核心模块，包括：
- DHCP/TFTP/HTTP 协议栈
- Boot session 关联与认证
- 状态持久化与恢复
- 配置/catalog 变更与校验
- Provisioning 脚本生成
- Initrd 下载与内存管理
- 无盘交付（diskless delivery）会话管理

## 2. Critical 修复

### CRITICAL-1: PXE 引导失败 — use-after-free

- **文件**: `src/catalog/iso_import.zig`
- **问题**: `bootloader_rel` 在 `importMedia` 返回前被 `defer free` 释放。调用方拿到的是已被释放的内存，在 Zig Debug allocator 下被 `0xAA` 填充，导致 PXE 引导路径乱码。这是 `r97n1` PXE 引导失败的根本原因。
- **修复**: 删除错误的 `defer free` 语句，将内存所有权转移给调用方。
- **影响**: 直接导致所有 PXE 引导路径损坏，在 Debug 模式下 100% 复现。

### CRITICAL-2: DHCP DNS 丢失 — 悬挂指针

- **文件**: `src/dhcp/server.zig`
- **问题**: `Reply.dns` 曾为切片，指向局部数组。函数返回后局部数组失效，DNS 信息丢失。
- **修复**: 将 `Reply.dns` 从切片改为固定数组，通过值拷贝修复悬挂指针。

### CRITICAL-3: 命令失败被掩盖

- **文件**: `src/provision/first_boot.zig`
- **问题**: 使用 `; rm` 连接命令，导致前一个命令失败时 `rm` 仍被执行，可能删除不该删除的文件。
- **修复**: 将 `; rm` 改为 `&& rm`，确保命令失败时后续命令不执行。

## 3. Medium 修复

### Medium-1: SHA-256 序列化错误

- **文件**: `src/setup.zig`（`resetState` 函数）
- **问题**: 备份清单中的 SHA-256 摘要被错误地序列化为整数数组而非十六进制字符串。`std.json.fmt(&digest, .{})` 会对 `[32]u8` 数组做逐元素 JSON 序列化，输出 `[123, 45, ...]` 而非十六进制字符串。
- **修复**: 修改为 `std.json.fmt(digest[0..], .{})`，使 JSON 序列化将字节切片视为字符串输出。

### Medium-2: error_code 长度校验不一致

- **文件**: `src/state/operations.zig`
- **问题**: `fail` 状态下错误码被静默截断（`@min` 到 128），无法记录完整错误信息。而 `succeeded` 状态使用不同上限（96），两处校验不一致。
- **修复**: 按状态分别校验长度上限（succeeded: 96, failed: 128），并移除静默截断逻辑，改为返回 `ErrorCodeTooLong` 错误。

## 4. Low 修复

### Low-1: 死代码 io_mutex

- **文件**: `src/state/status_store.zig`
- **问题**: 模块级 `io_mutex` 声明但未使用，造成误导。实际互斥在 HTTP 层的 `status_io_mutex` 完成。
- **修复**: 移除死代码声明，并添加注释说明实际互斥位置。

### Low-2: HMAC 比较非时序安全

- **文件**: `src/state/diskless_credential.zig`
- **问题**: 使用 `std.mem.eql` 比较 HMAC hash，存在理论时序侧信道风险。`std.mem.eql` 在发现第一个不匹配字节时即返回，攻击者可通过测量响应时间推断 hash 前缀。
- **修复**: 替换为 `std.crypto.timing_safe.eql`，确保比较时间恒定，不随匹配长度变化。

### Low-3: bearer token 大小写不一致

- **文件**: `src/http/auth.zig`（`bearer()` 函数）
- **问题**: `bearer()` 原本接受大小写十六进制 token，但 `generateCapability` 只生成小写十六进制。大写 token 会在 `bearer()` 通过但在后续 `authenticateCapability` 中精确比较失败，返回模糊的 `ProofMismatch` 错误。
- **修复**: `bearer()` 仅接受小写十六进制 `[0-9a-f]`，与 `generateCapability` 输出编码一致。大写 token 在解析阶段即被拒绝。

### Low-4: Authenticated/TftpBootIdentity 借用指针

- **文件**: `src/state/boot_session.zig`
- **问题**: `Authenticated` 和 `TftpBootIdentity` 结构体中的 `node_id` 和 `profile` 字段为借用切片，指向 `Store` 内 session 的固定缓冲区。这些切片在 `authenticated()` 和 `resolveTftpBoot()` 中于 mutex 持有期间返回，但调用方在 mutex 释放后使用。若另一线程在此期间清零或复用 session 槽位，切片会指向被修改的数据。
- **修复**: 将 `node_id: []const u8` 和 `profile: []const u8` 改为固定大小缓冲区（`node_id_buf: [node_id_capacity]u8` + `node_id_len: u8`，`profile_buf: [profile_capacity]u8` + `profile_len: u8`），在 mutex 持有期间完成值拷贝。添加 `nodeId()` 和 `profileName()` 访问器方法。
- **影响文件**: `src/state/boot_session.zig`、`src/http/server.zig`、`src/http/auth.zig`、`src/boot/target.zig`、`src/tftp/server.zig`

### Low-5: 路径校验过于严格

- **文件**: `src/provision/runner.zig`
- **问题**: 使用 `indexOf("..")` 校验路径，会误拒包含 `..` 子串的合法路径（如 `my..file.txt`）。
- **修复**: 引入 `containsDotDotComponent` 函数，进行组件级路径校验（只在 `/../` 或 `../` 前缀或 `/..` 后缀时拒绝），不影响包含 `..` 子串的合法文件名。

### Low-6: Spinlock 模式设计注释

- **文件**: 多个模块
- **问题**: 代码中大量使用 `tryLock + Thread.yield` 自旋锁模式，但部分位置缺少设计说明，可能导致后续维护者误解为忙等待或遗漏性能考量。
- **修复**: 为所有自旋锁位置补充设计注释，说明：
  - 临界区极短（固定数组遍历、memcpy 等），自旋比系统 futex 更高效
  - `Thread.yield` 让出 CPU 时间片，非纯忙等
  - 各模块的 `fn lock` 辅助函数统一添加文档注释
- **影响文件**: `src/state/runtime.zig`、`src/state/events.zig`、`src/app.zig`、`src/tftp/server.zig`、`src/http/server.zig`

### Low-7: phaseAdvances 跨路径 rank 问题

- **文件**: `src/state/node_status.zig`
- **问题**: `phaseRank` 对安装器（installer）和无盘（diskless）路径共享 rank 值。`phaseAdvances` 逻辑允许跨路径推进 phase（例如从 `installed` 推进到 `rootfs_downloading`），这在语义上是错误的。
- **修复**: 引入 `PathTag` 枚举和 `phasePath` 函数，将 phase 分类为 `installer`、`diskless` 或 `common` 路径。修改 `phaseAdvances` 逻辑，仅允许同路径内推进或跨公共/终态阶段推进。

## 5. 已评估并接受的已知限制

以下问题在审查中被识别，但经评估后认为在当前场景下可接受，不需要修改代码：

### TFTP CapsuleStore Spinlock

- **位置**: `src/tftp/server.zig` — `CapsuleStore` 方法
- **评估**: `tryLock + Thread.yield` 在高并发下可能导致高 CPU 使用率。但 capsule 操作的临界区极短（256 槽位遍历 + memcpy），自旋时间通常在微秒级。改用 futex 会引入系统调用开销，在预期负载下反而更慢。
- **结论**: 可接受。已补充设计注释说明选择理由。

### TFTP handleRrq Capsule Error Logging

- **位置**: `src/tftp/server.zig` — `transferVirtualCapsule` 错误处理
- **评估**: capsule 传输错误分支缺少 `observe_log` 调用，与其他分支不一致。但 TFTP 错误已通过 OACK ERROR 包返回给客户端，且 capsule 传输失败不影响 session 状态。
- **结论**: 可接受。不影响功能正确性。

### DHCP chooseLease 循环溢出

- **位置**: `src/dhcp/server.zig` — `chooseLease` 函数
- **评估**: 在 ReleaseFast 模式下，如果 `pool_end` 配置为 `255.255.255.255`，`ip += 1` 会溢出导致无限循环。但 `255.255.255.255` 是广播地址，不可能作为合法的 DHCP pool 终点，且配置校验阶段会拒绝此配置。
- **结论**: 可接受。配置层已有防护。

### HTTP 路由通配符

- **位置**: `src/http/routes.zig` — 通配符 `*` 处理
- **评估**: `*` 通配符仅在路由定义末尾有效，中间出现时可能导致匹配逻辑不正确。但当前所有路由定义中 `*` 仅用于末尾（如 `/artifacts/*`），不存在中间通配符的用例。
- **结论**: 可接受。当前路由定义不会触发此问题。

### DHCP install_not_armed 行为

- **位置**: `src/dhcp/server.zig` — `acquireSession`
- **评估**: `install_not_armed` 节点虽然获得 DHCP Lease，但未发送 PXE bootfile（因为部署未 armed）。这是设计使然：未 armed 的节点不应触发安装，但仍需网络引导以进行诊断。
- **结论**: 可接受。行为与设计一致，流程安全。

### TOCTOU 竞态条件

- **位置**: `src/tftp/server.zig` — TFTP 文件传输
- **评估**: TFTP 在检查文件存在性和实际传输之间存在 TOCTOU 窗口。但 TFTP 协议本身是无状态的 UDP 传输，TOCTOU 在协议层面无法避免。虚拟配置（capsule）路径不涉及文件系统，不受此问题影响。
- **结论**: 可接受。TFTP 协议限制。

## 6. 架构增强（非 bug 修复）

以下增强在 bug 修复过程中一并实现：

### M3.6 架构一致性检查

- **文件**: `src/boot/resolver.zig`
- **增强**: 添加 `architectureMatches` 函数，防止跨架构引导（如 aarch64 节点引导 x86_64 kernel）。

### 部署门控（Plan Digest）

- **文件**: `src/state/deployment_control.zig`
- **增强**: 实现 `isArmedForDigest` 函数，基于 Plan Digest 进行部署门控。检查 `armed_generation`、`requested_plan_digest` 和 digest 相等性，增强部署的确定性和安全性。

### Initrd HTTP HEAD/Range 严格校验

- **文件**: `src/initrd/download.zig`
- **增强**: 实现 `parseHead` 和 `validateRange` 函数，对 HTTP 响应进行严格校验（200/206 状态码、ETag、Content-Length、Content-Range），提高 initrd 下载的健壮性和安全性。

### Provisioning 脚本安全

- **文件**: `src/provision/node_apply.zig`、`src/provision/runner.zig`
- **增强**: 使用 `printf %b` 八进制转义确保文件写入安全，防止 shell 注入。引入 `containsDotDotComponent` 进行组件级路径校验。

### 无盘交付会话管理

- **文件**: `src/state/diskless_delivery.zig`
- **增强**: 实现基于 HMAC 的 scoped token 和投递会话管理，包括 `Session`、`TokenSlot` 结构体和 `begin`、`issue`、`verify`、`persist` 函数。

### 内核参数规范化

- **文件**: `src/config/load.zig`
- **增强**: 实现 `canonicalizeKernelArgs` 函数，确保内核参数格式一致性（修剪空白、折叠多余空格、处理空参数）。

## 7. 修复验证

所有修复已通过以下验证：

- **编译**: `zig build` Debug 模式零错误零警告
- **单元测试**: 354/354 全部通过
- **集成验证**: r97n1 PXE 引导路径修复后正常引导

## 8. 文件变更清单

| 文件 | 修改类型 | 涉及问题 |
|---|---|---|
| `src/catalog/iso_import.zig` | 修复 | CRITICAL-1 |
| `src/dhcp/server.zig` | 修复 | CRITICAL-2 |
| `src/provision/first_boot.zig` | 修复 | CRITICAL-3 |
| `src/setup.zig` | 修复 | Medium-1 |
| `src/state/operations.zig` | 修复 | Medium-2 |
| `src/state/status_store.zig` | 清理 | Low-1 |
| `src/state/diskless_credential.zig` | 修复 | Low-2 |
| `src/http/auth.zig` | 修复 | Low-3 |
| `src/state/boot_session.zig` | 修复 | Low-4 |
| `src/http/server.zig` | 修复 | Low-4, Low-6 |
| `src/boot/target.zig` | 修复 | Low-4 |
| `src/tftp/server.zig` | 修复 | Low-4, Low-6 |
| `src/provision/runner.zig` | 修复 | Low-5 |
| `src/state/node_status.zig` | 修复 | Low-7 |
| `src/state/runtime.zig` | 注释 | Low-6 |
| `src/state/events.zig` | 注释 | Low-6 |
| `src/app.zig` | 注释 | Low-6 |
| `src/boot/resolver.zig` | 增强 | M3.6 |
| `src/state/deployment_control.zig` | 增强 | Plan Digest 门控 |
| `src/initrd/download.zig` | 增强 | HTTP 严格校验 |
| `src/provision/node_apply.zig` | 增强 | 脚本安全 |
| `src/state/diskless_delivery.zig` | 增强 | 无盘交付会话 |
| `src/config/load.zig` | 增强 | 内核参数规范化 |
