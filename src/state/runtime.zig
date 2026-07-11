//! NodeForge 运行态模型。
//!
//! 运行态与 `config.json` 分离，不能反向成为部署配置事实源。
//! M0 运行态只存在于内存中；M1 增加 TFTP 会话计数和活动列表，后续阶段增加 lease
//! 和节点阶段后，可通过 `state/runtime.json` 持久化以支持重启恢复。
//!
//! 线程安全：`TftpState` 的计数器使用 `std.atomic.Value`，可由 UDP worker 线程
//! 写入、HTTP 管理路由线程无锁读取。会话列表使用 `std.atomic.Mutex` 保护，
//! 因为 `begin`/`finish`/`snapshot` 需要原子地修改多个字段。

const std = @import("std");

/// M0 运行态骨架；后续阶段在这里增加 lease、会话和节点阶段。
pub const RuntimeState = struct {
    /// 运行态格式版本；M0 仅接受版本 1。
    schema_version: u32 = 1,
    /// 守护进程当前生命周期阶段。由 `app.zig` 在启动时设置为 `running`。
    service: ServiceState = .starting,
    /// 配置快照版本号；每次原子更新递增，用于判断是否需要重新加载。
    config_generation: u64 = 1,
    /// M1 TFTP 会话摘要；原子计数可由 UDP worker 与 HTTP 管理路由并发读取。
    /// 会话列表使用自旋锁保护，确保 HTTP 路由不会观察到部分写入的文件名。
    tftp: TftpState = .{},
};

/// TFTP 会话的低成本运行态摘要。
///
/// 完整的历史事件在后续事件持久化阶段记录；M1 先提供无锁可读的传输计数
/// 和有界活动列表。计数器使用 `std.atomic.Value(u64)`，`fetchAdd` 保证
/// 多线程写入安全。会话列表使用自旋锁保护短临界区（仅拷贝 128 字节文件名
/// 和更新 phase），不影响计数器的并发读取。
pub const TftpState = struct {
    started: std.atomic.Value(u64) = .init(0),
    completed: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),
    /// A bounded newest-first activity list for M1 management inspection.  It
    /// intentionally holds no client credentials or packet payloads.
    sessions: [max_sessions]TftpSession = [_]TftpSession{.{}} ** max_sessions,
    next_session_id: u64 = 1,
    mutex: std.atomic.Mutex = .unlocked,

    pub const max_sessions = 32;

    /// Records a RRQ before opening the asset.  The returned slot remains
    /// valid until completion because M1's dispatcher is serial by design.
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

    /// Marks a recorded RRQ terminal without retaining any transfer payload.
    pub fn finish(self: *TftpState, slot: usize, success: bool) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.sessions[slot].phase = if (success) .completed else .failed;
        _ = if (success) self.completed.fetchAdd(1, .monotonic) else self.failed.fetchAdd(1, .monotonic);
    }

    /// Copies the current bounded list while holding the short publication
    /// lock, so HTTP never observes a partially written filename.
    pub fn snapshot(self: *TftpState, destination: *[max_sessions]TftpSession) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        destination.* = self.sessions;
    }
};

/// One bounded, non-persistent M1 TFTP activity entry.
pub const TftpSession = struct {
    id: u64 = 0,
    phase: TftpSessionPhase = .empty,
    filename: [128]u8 = [_]u8{0} ** 128,

    pub fn filenameSlice(self: *const TftpSession) []const u8 {
        return self.filename[0 .. std.mem.indexOfScalar(u8, &self.filename, 0) orelse self.filename.len];
    }
};

pub const TftpSessionPhase = enum { empty, running, completed, failed };

fn copyLabel(destination: *[128]u8, source: []const u8) void {
    destination.* = [_]u8{0} ** destination.len;
    const len = @min(destination.len, source.len);
    @memcpy(destination[0..len], source[0..len]);
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

/// 守护进程生命周期状态。
pub const ServiceState = enum {
    starting,
    running,
    stopping,
};

test "runtime defaults to starting" {
    const state: RuntimeState = .{};
    try @import("std").testing.expectEqual(ServiceState.starting, state.service);
}
