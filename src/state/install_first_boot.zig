//! v0.4 install first-boot server/local journal reducers.

const std = @import("std");

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

    pub fn handoff(self: *Journal) !void {
        if (self.server != .pending_handoff) return error.FirstBootStateConflict;
        self.server = .handoff_complete;
    }

    pub fn started(self: *Journal, event_id: []const u8) !void {
        if (event_id.len == 0) return error.FirstBootEventInvalid;
        if (self.server == .started or self.server == .running) {
            if (std.mem.eql(u8, self.started_event_id orelse "", event_id)) return;
            return error.FirstBootReplay;
        }
        // 单个 generation event token 由 capsule 直接交付；handoff 后即可上报
        // started，不再引入 bootstrap→event 的交换状态。
        if (self.server != .handoff_complete) return error.FirstBootStateConflict;
        self.started_event_id = event_id;
        self.server = .started;
        self.local = .started;
        self.event_seq += 1;
    }

    pub fn beginStep(self: *Journal, expected_step: usize) !void {
        if (self.server != .started and self.server != .running) return error.FirstBootStateConflict;
        if (expected_step != self.completed_step_count) return error.FirstBootStepOrder;
        self.server = .running;
        self.local = .step_running;
    }

    pub fn stepSucceeded(self: *Journal) !void {
        if (self.local != .step_running) return error.FirstBootStateConflict;
        self.completed_step_count += 1;
        self.local = .started;
    }

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

    pub fn acknowledgeTerminal(self: *Journal, success: bool) !void {
        if (success and self.local != .completed_pending_ack) return error.FirstBootStateConflict;
        if (!success and self.local != .failed_pending_ack) return error.FirstBootStateConflict;
        self.local = if (success) .completed_acknowledged else .failed_acknowledged;
    }

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
