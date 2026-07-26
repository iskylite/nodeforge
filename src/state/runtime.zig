//! 短期运行态状态。DHCP 状态与配置故意分离，具有小型可序列化投影用于重启恢复。
//!
//! RuntimeState 不直接持久化；DHCP lease 由 dhcp_store 独立保存到 leases.json，
//! TFTP 计数器是仅存在于内存的原子计数器，节点状态由 status_store 独立管理。
const std = @import("std");
const node_status = @import("node_status.zig");
const capacity = @import("capacity.zig");

/// 进程内运行态根对象。TFTP 和 DHCP 各有独立子状态。
pub const RuntimeState = struct {
    /// 运行态文件 schema 版本。
    schema_version: u32 = 2,
    /// 服务生命周期状态。
    service: ServiceState = .starting,
    /// 配置生成号；每次配置重载递增。
    config_generation: u64 = 1,
    /// TFTP 传输计数器和会话列表。
    tftp: TftpState = .{},
    /// DHCP lease 池和互斥锁。
    dhcp: DhcpState = .{},
};

/// DHCP lease 生命周期阶段。
pub const LeasePhase = enum { empty, offered, active, abandoned };

/// 单个 DHCP lease 记录。采用固定大小数组而非哈希表，避免动态分配。
pub const DhcpLease = struct {
    /// lease 当前阶段。
    phase: LeasePhase = .empty,
    /// 客户端是否为已注册节点。
    known: bool = false,
    /// 分配的 IPv4 地址（大端序 32 位）。
    ip: u32 = 0,
    /// 客户端 MAC 地址。
    mac: [6]u8 = [_]u8{0} ** 6,
    /// 单调时钟秒（MONOTONIC）。运行期 lease 过期判断的基准；`abandoned`
    /// 阶段用作隔离截止时间。持久化时由 `dhcp_store` 在 monotonic 与 Unix
    /// 绝对时间戳之间转换，保证跨重启即使单调时钟归零仍可与墙钟比较。
    expires_at: i64 = 0,
    /// lease 是否被使用（非 empty）。
    pub fn used(self: *const DhcpLease) bool {
        return self.phase != .empty;
    }
    /// 检查 lease 是否匹配指定 MAC。
    pub fn matches(self: *const DhcpLease, value: []const u8) bool {
        return self.used() and value.len == 6 and std.mem.eql(u8, &self.mac, value);
    }
};

/// DHCP lease 池。使用固定大小数组和自旋锁保护并发访问。
/// 所有 mutation 方法在锁内执行 `reapLocked` 清理过期条目。
pub const DhcpState = struct {
    /// lease 池内存上限（comptime 天花板）。M4.8 后实际并发容量由
    /// `effective` 在启动时按 `max(usable_hosts(subnet), config)` 派生，
    /// 取 `min(派生, max_leases)`。要超过本上限需提升此常量并重编译。
    pub const max_leases = capacity.store_ceiling;
    leases: [max_leases]DhcpLease = [_]DhcpLease{.{}} ** max_leases,
    /// M4.8: 运行时生效的 lease 并发上限。默认取满天花板；app.zig 启动时
    /// 调 `setEffective` 按 subnet 派生值收敛。
    effective: usize = max_leases,
    /// 自旋锁，保护 lease 数组的并发访问。
    mutex: std.atomic.Mutex = .unlocked,
    /// M3.1 单调递增的 lease 生成号。DHCP 热路径在每次真实 lease 变更后递增它；
    /// checkpoint worker 对比它与已保存的生成号，决定是否需要新的 leases.json 快照。
    lease_generation: u64 = 0,
    /// M4.2 F9: boot-gate 事件去重器。DHCP 客户端一次启动周期产生 4-8+ 个包
    /// （PXE 固件 + OS），`offerAfterProbe` 在每个包中检查 boot-gate 状态。
    /// 本抑制器基于 per-node 状态转换去重，避免 `boot.install_not_armed`
    /// 和 `boot.deploy_disabled` 事件在 events.jsonl 中泛滥。详见
    /// `BootGateSuppressor` 文档注释。
    gate_suppressor: BootGateSuppressor = .{},

    /// M4.8: 启动时按 `max(usable_hosts(subnet), config)` 派生并收敛生效容量。
    /// 传入值会被 clamp 到 `[1, max_leases]`。
    pub fn setEffective(self: *DhcpState, derived: usize) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var used: usize = 0;
        for (self.leases) |lease| if (lease.used()) {
            used += 1;
        };
        self.effective = @max(used, @max(@as(usize, 1), @min(derived, max_leases)));
    }

    /// 提供（OFFER）一个地址但不提交为 lease。每次分配前先清理过期 offer 和隔离条目。
    /// 返回 0 表示分配失败（地址被占用或池已满）。
    pub fn offer(self: *DhcpState, mac: []const u8, candidate: u32, known: bool, now: i64, seconds: u32) u32 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.reapLocked(now);
        for (&self.leases) |*lease| if (lease.matches(mac)) {
            // 被废弃的地址仍保持隔离状态，但其客户端可以从
            // 同一地址池中获得其他空闲地址。
            if (lease.phase == .abandoned) continue;
            lease.known = known;
            lease.expires_at = now + @as(i64, seconds);
            self.lease_generation += 1;
            if (lease.ip == candidate or lease.phase == .active) return lease.ip;
            return 0;
        };
        var used: usize = 0;
        var free: ?*DhcpLease = null;
        for (&self.leases) |*lease| {
            if (lease.used()) {
                used += 1;
                if (lease.ip == candidate) return 0;
            } else if (free == null) free = lease;
        }
        if (used >= self.effective) return 0;
        const lease = free orelse return 0;
        lease.* = .{ .phase = .offered, .known = known, .ip = candidate, .expires_at = now + @as(i64, seconds) };
        @memcpy(&lease.mac, mac[0..6]);
        self.lease_generation += 1;
        return candidate;
    }

    /// 检查 `ip` 是否已是此 MAC 的活动 lease。续约场景下客户端会回答自身地址的
    /// ICMP 探测，因此不应将此视为冲突。
    pub fn ownsActiveLease(self: *DhcpState, mac: []const u8, ip: u32, now: i64) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.reapLocked(now);
        for (&self.leases) |*lease| {
            if (lease.matches(mac) and lease.ip == ip and lease.phase == .active) return true;
        }
        return false;
    }

    /// 仅撤销从未上线的待定 OFFER。当 ICMP 探测不可用时使用：
    /// 活动 lease 绝不能因为后续 DISCOVER 无法做冲突检查而被移除。
    pub fn cancelOffer(self: *DhcpState, mac: []const u8, candidate: u32) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.leases) |*lease| if (lease.matches(mac) and lease.ip == candidate and lease.phase == .offered) {
            lease.* = .{};
            self.lease_generation += 1;
            return true;
        };
        return false;
    }

    /// 确认（ACK）之前已 OFFER 给此 MAC 的地址。配置的静态保留是唯一例外：
    /// 它可以在重启后没有内存 OFFER 的情况下 ACK 其声明地址。
    /// 仅仅作为已注册节点永远不授权任意 DHCP REQUEST。
    pub fn acknowledge(self: *DhcpState, mac: []const u8, candidate: u32, known: bool, static_reservation: bool, now: i64, seconds: u32) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.reapLocked(now);
        for (&self.leases) |*lease| if (lease.matches(mac) and lease.ip == candidate) {
            if (lease.phase == .abandoned) return false;
            lease.phase = .active;
            lease.known = known;
            lease.expires_at = now + @as(i64, seconds);
            self.lease_generation += 1;
            return true;
        };
        if (!static_reservation) return false;
        var used: usize = 0;
        var free: ?*DhcpLease = null;
        for (&self.leases) |*lease| {
            if (lease.used()) {
                used += 1;
                if (lease.ip == candidate) return false;
            } else if (free == null) free = lease;
        }
        if (used >= self.effective) return false;
        const lease = free orelse return false;
        lease.* = .{ .phase = .active, .known = true, .ip = candidate, .expires_at = now + @as(i64, seconds) };
        @memcpy(&lease.mac, mac[0..6]);
        self.lease_generation += 1;
        return true;
    }
    /// 释放（RELEASE）此 MAC 的所有非隔离 lease。
    pub fn release(self: *DhcpState, mac: []const u8) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var released = false;
        for (&self.leases) |*lease| if (lease.matches(mac) and lease.phase != .abandoned) {
            lease.* = .{};
            released = true;
        };
        if (released) self.lease_generation += 1;
        return released;
    }
    /// 拒绝（DECLINE）此 MAC 的地址，将其隔离指定时间后再允许重新分配。
    pub fn decline(self: *DhcpState, mac: []const u8, now: i64, quarantine_seconds: u32) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.leases) |*lease| if (lease.matches(mac) and lease.phase != .abandoned) {
            lease.phase = .abandoned;
            lease.expires_at = now + @as(i64, quarantine_seconds);
            self.lease_generation += 1;
            return true;
        };
        return false;
    }
    /// 在锁内快照当前 lease 数组。
    pub fn snapshot(self: *DhcpState, destination: *[max_leases]DhcpLease) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        destination.* = self.leases;
    }

    /// 在同一锁内捕获当前 lease 数组及其生成号。checkpoint worker 使用此方法
    /// 避免与 DHCP 热路径的竞态。
    pub fn snapshotWithGeneration(self: *DhcpState, destination: *[max_leases]DhcpLease) u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        destination.* = self.leases;
        return self.lease_generation;
    }

    /// 返回当前 lease 生成号（不快照数组）。
    pub fn generation(self: *DhcpState) u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return self.lease_generation;
    }
    /// 在与所有 DHCP mutation 相同的锁下恢复持久化快照中的 lease。
    /// 启动当前是单线程的，但保持此边界防止未来生命周期变更绕过状态同步。
    pub fn restore(self: *DhcpState, source: *const [max_leases]DhcpLease) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.leases = source.*;
    }
    /// 在锁内清理所有过期 lease。过期包括 offer 超时和隔离超时。
    fn reapLocked(self: *DhcpState, now: i64) void {
        var reaped = false;
        for (&self.leases) |*lease| {
            if (lease.used() and lease.expires_at <= now) {
                lease.* = .{};
                reaped = true;
            }
        }
        if (reaped) self.lease_generation += 1;
    }
};

/// Per-node boot-gate 事件抑制器（M4.2 F9）。
///
/// ## 问题背景
///
/// DHCP 客户端在一次启动周期内会发送多个 DISCOVER/REQUEST 包：
/// - PXE 固件阶段：DISCOVER → OFFER → REQUEST → ACK（4 个包）
/// - OS 内核/initrd 加载后重新获取 DHCP：DISCOVER → OFFER → REQUEST → ACK（4 个包）
/// - lease 续约（T1 = lease_time/2）：REQUEST → ACK（每周期 2 个包）
///
/// `offerAfterProbe`（`dhcp/server.zig`）在每个包的处理中都会调用
/// `resolveWithDeployment` 检查 `install_not_armed` 和 `deploy_disabled`。
/// 在引入本抑制器之前，每次检查到异常状态都会直接调用
/// `Writer.appendWithFields` 写入 events.jsonl，且 Writer 没有任何去重或
/// 限速逻辑。这导致一个未武装的安装节点在数秒内产生 8-10+ 条重复的
/// `boot.install_not_armed` 事件，污染审计日志。
///
/// ## 去重策略：状态转换去重
///
/// 本结构维护 per-node 的三态状态机（`normal`/`not_armed`/`deploy_disabled`），
/// 只在状态**发生变化**时才允许写事件：
/// - `normal → not_armed`：写 `boot.install_not_armed` 事件
/// - `normal → deploy_disabled`：写 `boot.deploy_disabled` 事件
/// - `not_armed → not_armed`：抑制（DHCP 重传/续约，状态未变）
/// - `not_armed → normal`：静默清除（节点被重新武装，不写"恢复"事件）
/// - `not_armed ↔ deploy_disabled`：写事件（状态类型变化）
///
/// ## 持久性
///
/// 状态仅在内存中，不持久化。daemon 重启后所有节点的状态重置为 `normal`，
/// 下一次 DHCP 包会重新触发一次事件——这是可接受的，因为 daemon 重启本身
/// 也需要操作员关注。与持久化方案相比，内存方案避免了重启恢复逻辑的复杂性
/// 和潜在的状态不一致风险。
///
/// ## 容量与降级
///
/// 固定 64 个槽位（`max_tracked`），在实践中足够覆盖一个 PXE 子网的活跃
/// 节点数。槽位耗尽时复用第一个槽位（LRU 风格），被驱逐节点的状态重置为
/// `normal`，下次该节点发 DHCP 包时会重新触发一次事件——这是安全的降级。
///
/// ## 不影响审计完整性
///
/// 去重只影响 `boot.install_not_armed` 和 `boot.deploy_disabled` 两类
/// 服务器侧诊断事件。DHCP 审计事件（`dhcp.discover`/`dhcp.offer`/
/// `dhcp.ack` 等）不受影响，每个 DHCP 包仍产生完整的审计记录。
pub const BootGateSuppressor = struct {
    pub const max_tracked = 64;

    /// 三态状态机：normal 表示节点可正常 PXE 引导。
    const State = enum { normal, not_armed, deploy_disabled };

    const Entry = struct {
        const node_id_capacity = 96;
        node_id: [node_id_capacity]u8 = [_]u8{0} ** node_id_capacity,
        node_id_len: u8 = 0,
        last_state: State = .normal,

        fn used(self: *const Entry) bool {
            return self.node_id_len != 0;
        }
        fn matches(self: *const Entry, node_id: []const u8) bool {
            return self.used() and self.node_id_len == node_id.len and
                std.mem.eql(u8, self.node_id[0..self.node_id_len], node_id);
        }
    };

    entries: [max_tracked]Entry = [_]Entry{.{}} ** max_tracked,
    mutex: std.atomic.Mutex = .unlocked,

    /// 检查是否应该写 boot-gate 事件。
    ///
    /// 调用方在每次 DHCP 包处理时传入当前节点的 `not_armed` 和
    /// `deploy_disabled` 标志（两者互斥，不会同时为 true）。
    ///
    /// 返回 `true` 表示发生了状态转换且新状态非 `normal`（应该写事件）；
    /// 返回 `false` 表示状态未变或回到 `normal`（应该抑制）。
    ///
    /// 内部自动维护 per-node 状态机，调用方无需关心状态管理细节。
    pub fn shouldEmit(self: *BootGateSuppressor, node_id: []const u8, not_armed: bool, deploy_disabled: bool) bool {
        // 配置校验将 node ID 限制为 96 字节；这里独立 fail closed，避免未来
        // 未校验的调用方写出固定缓冲区，也不能复用其他节点的去重状态。
        if (node_id.len == 0 or node_id.len > Entry.node_id_capacity) return false;
        const new_state: State = if (not_armed) .not_armed else if (deploy_disabled) .deploy_disabled else .normal;
        lock(&self.mutex);
        defer self.mutex.unlock();
        const entry = self.findOrCreate(node_id);
        if (entry.last_state == new_state) return false;
        entry.last_state = new_state;
        return new_state != .normal;
    }

    fn findOrCreate(self: *BootGateSuppressor, node_id: []const u8) *Entry {
        // 优先查找已存在的条目。
        for (&self.entries) |*entry| {
            if (entry.matches(node_id)) return entry;
        }
        // 查找空闲槽位。
        for (&self.entries) |*entry| {
            if (!entry.used()) {
                @memcpy(entry.node_id[0..node_id.len], node_id);
                entry.node_id_len = @intCast(node_id.len);
                return entry;
            }
        }
        // 所有槽位已用：复用第一个槽位（LRU 风格降级）。
        // 被驱逐节点的状态重置为 normal，下次该节点发 DHCP 包时
        // 会重新触发一次事件——这是安全的降级行为。
        const entry = &self.entries[0];
        @memcpy(entry.node_id[0..node_id.len], node_id);
        entry.node_id_len = @intCast(node_id.len);
        entry.last_state = .normal;
        return entry;
    }
};

/// JSON 安全的持久化投影。Mutex 和 TFTP 计数器不会进入此文件。
/// M3 持久化运行时状态文件。M1/M2 文件使用 schema 1 且只包含 lease；
/// 加载器接受它们并用空的节点状态集合补全。
pub const RuntimeFile = struct {
    /// schema 版本。
    schema_version: u32 = 2,
    /// 保存时间戳。
    saved_at: i64,
    /// DHCP lease 列表。
    leases: []const DhcpLease,
    /// 节点状态列表（M3 新增；M1/M2 文件为空）。
    statuses: []const node_status.Status = &.{},
};

/// TFTP 传输计数器和活动会话列表。计数器使用原子操作，
/// 会话列表使用自旋锁保护。
pub const TftpState = struct {
    /// 已启动的 TFTP 传输总数。
    started: std.atomic.Value(u64) = .init(0),
    /// 已完成的 TFTP 传输总数。
    completed: std.atomic.Value(u64) = .init(0),
    /// 失败的 TFTP 传输总数。
    failed: std.atomic.Value(u64) = .init(0),
    /// 活动会话数组（环形缓冲）。
    sessions: [max_sessions]TftpSession = [_]TftpSession{.{}} ** max_sessions,
    /// 下一个会话 ID（单调递增）。
    next_session_id: u64 = 1,
    /// 保护会话数组的自旋锁。
    mutex: std.atomic.Mutex = .unlocked,
    /// 活动会话最大数量。
    pub const max_sessions = 32;
    pub fn begin(self: *TftpState, filename: []const u8) usize {
        lock(&self.mutex);
        defer self.mutex.unlock();
        const slot: usize = @intCast((self.next_session_id - 1) % max_sessions);
        self.sessions[slot] = .{ .id = self.next_session_id, .phase = .running };
        copyLabel(&self.sessions[slot].filename, filename);
        self.next_session_id +%= 1;
        _ = self.started.fetchAdd(1, .monotonic);
        return slot;
    }
    pub fn finish(self: *TftpState, slot: usize, success: bool) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.sessions[slot].phase = if (success) .completed else .failed;
        _ = if (success) self.completed.fetchAdd(1, .monotonic) else self.failed.fetchAdd(1, .monotonic);
    }
    pub fn snapshot(self: *TftpState, destination: *[max_sessions]TftpSession) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        destination.* = self.sessions;
    }
};
pub const TftpSession = struct {
    /// 会话 ID（0 表示空槽）。
    id: u64 = 0,
    /// 会话阶段。
    phase: TftpSessionPhase = .empty,
    /// 请求的文件名（NUL 结尾的固定缓冲区）。
    filename: [128]u8 = [_]u8{0} ** 128,
    /// 返回文件名的有效切片（到第一个 NUL 为止）。
    pub fn filenameSlice(self: *const TftpSession) []const u8 {
        return self.filename[0 .. std.mem.indexOfScalar(u8, &self.filename, 0) orelse self.filename.len];
    }
};
/// TFTP 会话阶段。
pub const TftpSessionPhase = enum { empty, running, completed, failed };
/// 服务生命周期状态。
pub const ServiceState = enum { starting, running, stopping };
fn copyLabel(destination: *[128]u8, source: []const u8) void {
    destination.* = [_]u8{0} ** destination.len;
    const len = @min(destination.len, source.len);
    @memcpy(destination[0..len], source[0..len]);
}
/// 自旋等待获取 mutex。DHCP/TFTP 运行时状态操作时间极短，自旋比系统 futex 更高效。
fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

test "DHCP offer becomes ACK and declined address is quarantined" {
    var state: DhcpState = .{};
    const mac = [_]u8{ 0, 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(u32, 0xc0a81b0a), state.offer(&mac, 0xc0a81b0a, false, 100, 30));
    try std.testing.expect(state.acknowledge(&mac, 0xc0a81b0a, false, false, 101, 60));
    try std.testing.expect(state.decline(&mac, 102, 3600));
    try std.testing.expectEqual(@as(u32, 0), state.offer(&mac, 0xc0a81b0a, false, 103, 30));
}

test "refreshing an existing offer advances the checkpoint generation" {
    var state: DhcpState = .{};
    const mac = [_]u8{ 0, 1, 2, 3, 4, 12 };
    const ip: u32 = 0xc0a81b0a;
    try std.testing.expectEqual(ip, state.offer(&mac, ip, false, 100, 30));
    const before = state.generation();
    try std.testing.expectEqual(ip, state.offer(&mac, ip, true, 110, 60));
    try std.testing.expectEqual(before + 1, state.generation());
}

test "active lease renewal is distinguishable from a new offer" {
    var state: DhcpState = .{};
    const mac = [_]u8{ 0, 1, 2, 3, 4, 13 };
    const ip: u32 = 0xc0a81b0a;
    try std.testing.expectEqual(ip, state.offer(&mac, ip, false, 100, 30));
    try std.testing.expect(state.acknowledge(&mac, ip, false, false, 101, 60));
    try std.testing.expect(state.ownsActiveLease(&mac, ip, 102));
    try std.testing.expect(!state.ownsActiveLease(&[_]u8{ 0, 1, 2, 3, 4, 14 }, ip, 102));
}

test "an abandoned candidate does not block ACK or release of the replacement" {
    var state: DhcpState = .{};
    const mac = [_]u8{ 0, 1, 2, 3, 4, 6 };
    try std.testing.expectEqual(@as(u32, 0xc0a81b0a), state.offer(&mac, 0xc0a81b0a, false, 100, 30));
    try std.testing.expect(state.decline(&mac, 101, 3600));
    try std.testing.expectEqual(@as(u32, 0xc0a81b0b), state.offer(&mac, 0xc0a81b0b, false, 102, 30));
    try std.testing.expect(state.acknowledge(&mac, 0xc0a81b0b, false, false, 103, 60));
    try std.testing.expect(state.release(&mac));
    var snapshot: [DhcpState.max_leases]DhcpLease = undefined;
    state.snapshot(&snapshot);
    try std.testing.expectEqual(LeasePhase.abandoned, snapshot[0].phase);
    try std.testing.expectEqual(LeasePhase.empty, snapshot[1].phase);
}

test "unprobed offer can be cancelled without releasing an active lease" {
    var state: DhcpState = .{};
    const offered_mac = [_]u8{ 0, 1, 2, 3, 4, 7 };
    const active_mac = [_]u8{ 0, 1, 2, 3, 4, 8 };
    try std.testing.expectEqual(@as(u32, 0xc0a81b0a), state.offer(&offered_mac, 0xc0a81b0a, false, 100, 30));
    try std.testing.expect(state.cancelOffer(&offered_mac, 0xc0a81b0a));
    try std.testing.expectEqual(@as(u32, 0xc0a81b0b), state.offer(&active_mac, 0xc0a81b0b, false, 100, 30));
    try std.testing.expect(state.acknowledge(&active_mac, 0xc0a81b0b, false, false, 101, 60));
    try std.testing.expect(!state.cancelOffer(&active_mac, 0xc0a81b0b));
}

test "only a static reservation may acknowledge without an offer" {
    var state: DhcpState = .{};
    const unknown_mac = [_]u8{ 0, 1, 2, 3, 4, 9 };
    const known_dynamic_mac = [_]u8{ 0, 1, 2, 3, 4, 10 };
    const static_mac = [_]u8{ 0, 1, 2, 3, 4, 11 };
    const candidate: u32 = 0xc0a81b0a;

    try std.testing.expect(!state.acknowledge(&unknown_mac, candidate, false, false, 100, 60));
    try std.testing.expect(!state.acknowledge(&known_dynamic_mac, candidate, true, false, 100, 60));
    try std.testing.expect(state.acknowledge(&static_mac, candidate, true, true, 100, 60));
}

test "effective lease capacity counts restored entries outside the prefix" {
    var state: DhcpState = .{};
    const restored_mac = [_]u8{ 0, 1, 2, 3, 4, 5 };
    const new_mac = [_]u8{ 0, 1, 2, 3, 4, 6 };
    state.leases[1] = .{ .phase = .active, .ip = 0xc0a81b0a, .expires_at = 1000 };
    @memcpy(&state.leases[1].mac, &restored_mac);
    state.setEffective(1);
    try std.testing.expectEqual(@as(usize, 1), state.effective);
    try std.testing.expectEqual(@as(u32, 0), state.offer(&new_mac, 0xc0a81b0b, false, 1, 30));
    try std.testing.expect(!state.leases[0].used());
}

test "boot-gate suppressor emits only on state transition" {
    var suppressor: BootGateSuppressor = .{};

    // 首个 DHCP 包：normal → not_armed → 应发出
    try std.testing.expect(suppressor.shouldEmit("r97n1", true, false));
    // 第二个 DHCP 包（重传）：not_armed → not_armed → 抑制
    try std.testing.expect(!suppressor.shouldEmit("r97n1", true, false));
    // 第三个 DHCP 包（OS 启动）：仍为 not_armed → 抑制
    try std.testing.expect(!suppressor.shouldEmit("r97n1", true, false));

    // 节点被武装：not_armed → normal → 抑制（恢复时不发事件）
    try std.testing.expect(!suppressor.shouldEmit("r97n1", false, false));
    // 节点再次变为 not_armed：normal → not_armed → 应发出
    try std.testing.expect(suppressor.shouldEmit("r97n1", true, false));
}

test "boot-gate suppressor tracks deploy_disabled independently" {
    var suppressor: BootGateSuppressor = .{};

    // not_armed → deploy_disabled 是状态转换 → 发出
    try std.testing.expect(suppressor.shouldEmit("r97n2", true, false));
    try std.testing.expect(!suppressor.shouldEmit("r97n2", true, false));
    // not_armed → deploy_disabled → 发出（不同状态）
    try std.testing.expect(suppressor.shouldEmit("r97n2", false, true));
    try std.testing.expect(!suppressor.shouldEmit("r97n2", false, true));
    // deploy_disabled → normal → 抑制
    try std.testing.expect(!suppressor.shouldEmit("r97n2", false, false));
    // normal → deploy_disabled → 发出
    try std.testing.expect(suppressor.shouldEmit("r97n2", false, true));
}

test "boot-gate suppressor tracks multiple nodes independently" {
    var suppressor: BootGateSuppressor = .{};

    try std.testing.expect(suppressor.shouldEmit("node-a", true, false));
    // node-b 同样未 armed，但相互独立 -> emit
    try std.testing.expect(suppressor.shouldEmit("node-b", true, false));
    // node-a 仍未 armed -> suppress
    try std.testing.expect(!suppressor.shouldEmit("node-a", true, false));
    // node-b 仍未 armed -> suppress
    try std.testing.expect(!suppressor.shouldEmit("node-b", true, false));
}

test "boot-gate suppressor fails closed for an oversized node id" {
    var suppressor: BootGateSuppressor = .{};
    try std.testing.expect(!suppressor.shouldEmit("n" ** 97, true, false));
    // 非法输入不得占用或修改首个真实节点的槽位。
    try std.testing.expect(suppressor.shouldEmit("node-a", true, false));
    try std.testing.expect(!suppressor.shouldEmit("node-a", true, false));
}
