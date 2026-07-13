//! 短期运行态状态。DHCP 状态与配置故意分离，具有小型可序列化投影用于重启恢复。
//!
//! RuntimeState 不直接持久化；DHCP lease 由 dhcp_store 独立保存到 leases.json，
//! TFTP 计数器是仅存在于内存的原子计数器，节点状态由 status_store 独立管理。
const std = @import("std");
const node_status = @import("node_status.zig");

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
    /// Unix 时间戳（秒）。`abandoned` 阶段用作隔离截止时间。
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
    /// lease 池最大容量。超过时新请求无法分配地址。
    pub const max_leases = 256;
    leases: [max_leases]DhcpLease = [_]DhcpLease{.{}} ** max_leases,
    /// 自旋锁，保护 lease 数组的并发访问。
    mutex: std.atomic.Mutex = .unlocked,
    /// M3.1 单调递增的 lease 生成号。DHCP 热路径在每次真实 lease 变更后递增它；
    /// checkpoint worker 对比它与已保存的生成号，决定是否需要新的 leases.json 快照。
    lease_generation: u64 = 0,

    /// 提供（OFFER）一个地址但不提交为 lease。每次分配前先清理过期 offer 和隔离条目。
    /// 返回 0 表示分配失败（地址被占用或池已满）。
    pub fn offer(self: *DhcpState, mac: []const u8, candidate: u32, known: bool, now: i64, seconds: u32) u32 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.reapLocked(now);
        for (&self.leases) |*lease| if (lease.matches(mac)) {
            // An abandoned address remains quarantined, but its client may be
            // offered a different free address from the same pool.
            if (lease.phase == .abandoned) continue;
            lease.known = known;
            lease.expires_at = now + @as(i64, seconds);
            self.lease_generation += 1;
            if (lease.ip == candidate or lease.phase == .active) return lease.ip;
            return 0;
        };
        for (&self.leases) |*lease| if (lease.used() and lease.ip == candidate) return 0;
        for (&self.leases) |*lease| if (!lease.used()) {
            lease.* = .{ .phase = .offered, .known = known, .ip = candidate, .expires_at = now + @as(i64, seconds) };
            @memcpy(&lease.mac, mac[0..6]);
            self.lease_generation += 1;
            return candidate;
        };
        return 0;
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
        for (&self.leases) |*lease| if (lease.used() and lease.ip == candidate) return false;
        for (&self.leases) |*lease| if (!lease.used()) {
            lease.* = .{ .phase = .active, .known = true, .ip = candidate, .expires_at = now + @as(i64, seconds) };
            @memcpy(&lease.mac, mac[0..6]);
            self.lease_generation += 1;
            return true;
        };
        return false;
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
