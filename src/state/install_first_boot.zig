//! # v0.4 装机 first-boot 服务端/本地 journal 归约器
//!
//! 纯状态机：不碰磁盘、不签发 token。服务端 `ServerState` 与目标侧
//! `LocalState` 同结构体推进，顺序强制为
//! handoff → started → steps → terminal → acknowledge。
//! 事件 id 幂等重放；id 漂移返回 `FirstBootReplay`。

const std = @import("std");

/// 服务端视角的 generation first-boot 状态。
pub const ServerState = enum {
    not_required,
    pending_handoff,
    handoff_complete,
    started,
    running,
    succeeded,
    failed,
    expired,
    recovery_incomplete,
};

/// 目标机视角（与 provision/install_first_boot.LocalState 语义对齐）。
pub const LocalState = enum {
    pending,
    started,
    step_running,
    completed_pending_ack,
    completed_acknowledged,
    failed_pending_ack,
    failed_acknowledged,
    recovery_incomplete,
};

/// 双端 journal 快照；由 store 持久化，本模块只做合法迁移。
pub const Journal = struct {
    server: ServerState = .pending_handoff,
    local: LocalState = .pending,
    event_seq: u64 = 0,
    /// 仅用于读取 v0.4 早期 journal 的兼容字段；新协议既不写也不读取它。
    /// 保留该字段避免 daemon 因历史持久化 JSON 的未知字段循环重启。
    exchange_counter: u64 = 0,
    started_event_id: ?[]const u8 = null,
    terminal_event_id: ?[]const u8 = null,
    completed_step_count: usize = 0,

    /// 装机 handoff 成功：pending_handoff → handoff_complete。
    pub fn handoff(self: *Journal) !void {
        if (self.server != .pending_handoff) return error.FirstBootStateConflict;
        self.server = .handoff_complete;
    }

    /// 上报 started；同 event_id 幂等，不同 id 记为 replay。
    pub fn started(self: *Journal, event_id: []const u8) !void {
        if (event_id.len == 0) return error.FirstBootEventInvalid;
        if (self.server == .started or self.server == .running) {
            if (std.mem.eql(u8, self.started_event_id orelse "", event_id)) return;
            return error.FirstBootReplay;
        }
        // generation event token 由 capsule 直接交付；handoff 后即可上报 started，
        // 不再引入 bootstrap→event 交换状态。
        if (self.server != .handoff_complete) return error.FirstBootStateConflict;
        self.started_event_id = event_id;
        self.server = .started;
        self.local = .started;
        self.event_seq += 1;
    }

    /// 按 completed_step_count 顺序进入 running/step_running。
    pub fn beginStep(self: *Journal, expected_step: usize) !void {
        if (self.server != .started and self.server != .running) return error.FirstBootStateConflict;
        if (expected_step != self.completed_step_count) return error.FirstBootStepOrder;
        self.server = .running;
        self.local = .step_running;
    }

    /// 当前步骤成功，completed_step_count++。
    pub fn stepSucceeded(self: *Journal) !void {
        if (self.local != .step_running) return error.FirstBootStateConflict;
        self.completed_step_count += 1;
        self.local = .started;
    }

    /// 写入终态；同 event_id 幂等。
    pub fn terminal(self: *Journal, success: bool, event_id: []const u8) !void {
        if (event_id.len == 0) return error.FirstBootEventInvalid;
        if (self.terminal_event_id) |existing| {
            if (std.mem.eql(u8, existing, event_id)) return;
            return error.FirstBootReplay;
        }
        if (self.server != .running) return error.FirstBootStateConflict;
        self.terminal_event_id = event_id;
        self.server = if (success) .succeeded else .failed;
        self.local = if (success) .completed_pending_ack else .failed_pending_ack;
        self.event_seq += 1;
    }

    /// 服务端确认终态，释放后续 active 槽位（由 store 配合）。
    pub fn acknowledgeTerminal(self: *Journal, success: bool) !void {
        if (success and self.local != .completed_pending_ack) return error.FirstBootStateConflict;
        if (!success and self.local != .failed_pending_ack) return error.FirstBootStateConflict;
        self.local = if (success) .completed_acknowledged else .failed_acknowledged;
    }

    /// secret 轮换或凭据丢失：两端进入 recovery_incomplete。
    pub fn markRecoveryIncomplete(self: *Journal) void {
        self.server = .recovery_incomplete;
        self.local = .recovery_incomplete;
    }
};

test "first-boot journal enforces handoff, event and terminal order" {
    var journal: Journal = .{};
    try journal.handoff();
    try journal.started("start-1");
    try std.testing.expectError(error.FirstBootStepOrder, journal.beginStep(1));
    try journal.beginStep(0);
    try journal.stepSucceeded();
    try journal.terminal(true, "done-1");
    try std.testing.expectEqual(ServerState.succeeded, journal.server);
    try std.testing.expectEqual(LocalState.completed_pending_ack, journal.local);
    try journal.acknowledgeTerminal(true);
    try std.testing.expectEqual(LocalState.completed_acknowledged, journal.local);
}

test "first-boot events are idempotent but body/event drift is rejected" {
    var journal: Journal = .{};
    try journal.handoff();
    try journal.started("same-event");
    try journal.started("same-event");
    try std.testing.expectError(error.FirstBootReplay, journal.started("other-event"));
}

test "first-boot missing credentials enter recovery incomplete" {
    var journal: Journal = .{};
    journal.markRecoveryIncomplete();
    try std.testing.expectEqual(ServerState.recovery_incomplete, journal.server);
    try std.testing.expectEqual(LocalState.recovery_incomplete, journal.local);
}
