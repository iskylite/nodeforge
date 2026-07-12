//! Durable-facing M3 node-status projection.  The store is deliberately
//! distinct from the JSONL audit writer: status answers "where is the node
//! now", while events retain the history that led there.

const std = @import("std");
const boot_session = @import("boot_session.zig");

pub const max_statuses = 256;

pub const Phase = enum {
    boot_config_fetched,
    installer_started,
    installing,
    completed,
    initrd_started,
    rootfs_downloading,
    rootfs_verified,
    rootfs_mounted,
    switching_root,
    running,
    failed,
};

pub const Status = struct {
    node_id: [96]u8 = [_]u8{0} ** 96,
    node_id_len: u8 = 0,
    boot_session_id: [boot_session.id_len]u8 = [_]u8{0} ** boot_session.id_len,
    daemon_instance_id: [boot_session.id_len]u8 = [_]u8{0} ** boot_session.id_len,
    phase: Phase = .boot_config_fetched,
    last_event_at: i64 = 0,
    last_error: bool = false,
    reason: [128]u8 = [_]u8{0} ** 128,
    reason_len: u8 = 0,
    session_active: bool = false,

    pub fn node(self: *const Status) []const u8 {
        return self.node_id[0..self.node_id_len];
    }
    pub fn reasonSlice(self: *const Status) []const u8 {
        return self.reason[0..self.reason_len];
    }
    pub fn used(self: *const Status) bool {
        return self.node_id_len != 0;
    }
};

pub const Store = struct {
    entries: [max_statuses]Status = [_]Status{.{}} ** max_statuses,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn update(self: *Store, node_id: []const u8, session_id: []const u8, daemon_id: []const u8, phase: Phase, reason: ?[]const u8, timestamp: i64, active: bool) !void {
        if (node_id.len == 0 or node_id.len > 96 or !boot_session.validId(session_id) or !boot_session.validId(daemon_id)) return error.InvalidNodeStatus;
        lock(&self.mutex);
        defer self.mutex.unlock();
        var target: ?*Status = null;
        for (&self.entries) |*entry| {
            if (entry.used() and std.mem.eql(u8, entry.node(), node_id)) {
                // A retransmitted or retried HTTP request belongs to the
                // same boot session.  It may produce another audit Event,
                // but it must never move the durable "where is this node"
                // projection backwards (for example, a second config fetch
                // after the installer has already started).
                if (std.mem.eql(u8, &entry.boot_session_id, session_id) and
                    !phaseAdvances(entry.phase, phase)) return;
                target = entry;
                break;
            }
            if (!entry.used() and target == null) target = entry;
        }
        const entry = target orelse return error.NodeStatusCapacityExhausted;
        entry.* = .{ .phase = phase, .last_event_at = timestamp, .last_error = phase == .failed, .session_active = active };
        @memcpy(entry.node_id[0..node_id.len], node_id);
        entry.node_id_len = @intCast(node_id.len);
        @memcpy(&entry.boot_session_id, session_id);
        @memcpy(&entry.daemon_instance_id, daemon_id);
        if (reason) |value| {
            const len = @min(value.len, entry.reason.len);
            @memcpy(entry.reason[0..len], value[0..len]);
            entry.reason_len = @intCast(len);
        }
    }

    pub fn deactivateAll(self: *Store) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.used()) entry.session_active = false;
        }
    }

    pub fn get(self: *Store, node_id: []const u8) ?Status {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id)) return entry;
        return null;
    }

    pub fn snapshot(self: *Store, destination: *[max_statuses]Status) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        destination.* = self.entries;
    }

    /// Restored projections are historical observations only.  A daemon
    /// restart never revives a capability or makes an old boot session active.
    pub fn restoreInactive(self: *Store, source: *const [max_statuses]Status) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.entries = source.*;
        for (&self.entries) |*entry| {
            if (entry.used()) entry.session_active = false;
        }
    }
};

/// M3 has two independent progress paths (installer and diskless), plus the
/// common initial config fetch.  A failure is terminal for the current
/// session; a new boot session is handled by `update` as a fresh projection.
fn phaseAdvances(current: Phase, next: Phase) bool {
    if (current == next) return true;
    if (current == .failed or current == .completed or current == .running) return next == .failed;
    if (next == .failed) return true;
    return phaseRank(next) >= phaseRank(current);
}

fn phaseRank(phase: Phase) u8 {
    return switch (phase) {
        .boot_config_fetched => 1,
        .installer_started, .initrd_started => 2,
        .installing, .rootfs_downloading => 3,
        .rootfs_verified => 4,
        .rootfs_mounted => 5,
        .switching_root => 6,
        .completed, .running => 7,
        .failed => 8,
    };
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

test "node status replaces only the current projection" {
    var store: Store = .{};
    const id = "0123456789abcdef0123456789abcdef";
    try store.update("n1", id, id, .boot_config_fetched, null, 1, true);
    try store.update("n1", id, id, .failed, "network_timeout", 2, true);
    const status = store.get("n1").?;
    try std.testing.expectEqual(Phase.failed, status.phase);
    try std.testing.expectEqualStrings("network_timeout", status.reasonSlice());
}

test "restored status retains history but invalidates old session" {
    var original: Store = .{};
    const id = "0123456789abcdef0123456789abcdef";
    try original.update("n1", id, id, .running, null, 3, true);
    var snapshot: [max_statuses]Status = undefined;
    original.snapshot(&snapshot);
    var restored: Store = .{};
    restored.restoreInactive(&snapshot);
    const status = restored.get("n1").?;
    try std.testing.expectEqual(Phase.running, status.phase);
    try std.testing.expect(!status.session_active);
}

test "a retried boot config cannot regress an active install projection" {
    var store: Store = .{};
    const id = "0123456789abcdef0123456789abcdef";
    try store.update("n1", id, id, .installer_started, null, 2, true);
    try store.update("n1", id, id, .boot_config_fetched, null, 3, true);
    const status = store.get("n1").?;
    try std.testing.expectEqual(Phase.installer_started, status.phase);
    try std.testing.expectEqual(@as(i64, 2), status.last_event_at);
}
