//! 面向持久化的 M3 节点状态投影。该 store 有意与 JSONL 审计写入器分离：
//! status 回答“节点现在处于哪个阶段”，而 events 保留到达该状态的历史记录。

const std = @import("std");
const boot_session = @import("boot_session.zig");
const capacity = @import("capacity.zig");
const deployment_control = @import("deployment_control.zig");

/// M4.8: 投影表内存天花板；生效容量由 `Store.effective` 在启动时按
/// `max(受管节点数, config)` 派生（`min(派生, max_statuses)`）。
pub const max_statuses = capacity.store_ceiling;

pub const Phase = enum {
    boot_config_fetched,
    installer_started,
    install_config_fetched,
    install_started,
    install_partitioning,
    install_packages,
    install_bootloader,
    install_post,
    install_rebooting,
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
    /// 该投影所属的不可变 config/model revision；0 仅表示旧格式未知。
    model_revision: u64 = 0,
    model_plan_digest: deployment_control.Digest = deployment_control.empty_digest,
    /// install generation；diskless/discovery 或旧格式可为 0。
    deployment_generation: u64 = 0,
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
    /// M4.8: 生效投影容量，启动时按受管节点数派生收敛。
    effective: usize = max_statuses,
    revision: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,

    /// M4.8: 按 `max(受管节点数, config)` 派生并 clamp 到 `[1, max_statuses]`。
    pub fn setEffective(self: *Store, derived: usize) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var used: usize = 0;
        for (self.entries) |entry| if (entry.used()) {
            used += 1;
        };
        self.effective = @max(used, @max(@as(usize, 1), @min(derived, max_statuses)));
    }

    pub fn growEffective(self: *Store, minimum: usize) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.effective = @max(self.effective, @min(minimum, max_statuses));
    }

    pub fn update(self: *Store, node_id: []const u8, session_id: []const u8, daemon_id: []const u8, phase: Phase, reason: ?[]const u8, timestamp: i64, active: bool) !void {
        return self.updateForDeployment(node_id, session_id, daemon_id, 0, deployment_control.empty_digest, 0, phase, reason, timestamp, active);
    }

    /// 更新带来源归属的当前状态。管理聚合必须同时匹配 model revision 与
    /// deployment generation，不能把旧 profile/session 的 completed 拼到新 desired config。
    pub fn updateForDeployment(self: *Store, node_id: []const u8, session_id: []const u8, daemon_id: []const u8, model_revision: u64, model_plan_digest: deployment_control.Digest, deployment_generation: u64, phase: Phase, reason: ?[]const u8, timestamp: i64, active: bool) !void {
        if (node_id.len == 0 or node_id.len > 96 or !boot_session.validId(session_id) or !boot_session.validId(daemon_id)) return error.InvalidNodeStatus;
        lock(&self.mutex);
        defer self.mutex.unlock();
        var existing: ?*Status = null;
        var free: ?*Status = null;
        var used: usize = 0;
        for (&self.entries) |*entry| {
            if (entry.used() and std.mem.eql(u8, entry.node(), node_id)) {
                // 重传或重试的 HTTP 请求属于同一个 boot session。
                // 它可能产生另一条审计 Event，但绝不能让持久的
                // “该节点处于哪个阶段”状态回退（例如安装器已启动后的
                // 第二次配置获取）。
                if (std.mem.eql(u8, &entry.boot_session_id, session_id) and
                    !phaseAdvances(entry.phase, phase)) return;
                existing = entry;
                break;
            }
            if (entry.used()) used += 1 else if (free == null) free = entry;
        }
        const entry = existing orelse blk: {
            if (used >= self.effective) return error.NodeStatusCapacityExhausted;
            break :blk free orelse return error.NodeStatusCapacityExhausted;
        };
        entry.* = .{ .model_revision = model_revision, .model_plan_digest = model_plan_digest, .deployment_generation = deployment_generation, .phase = phase, .last_event_at = timestamp, .last_error = phase == .failed, .session_active = active };
        @memcpy(entry.node_id[0..node_id.len], node_id);
        entry.node_id_len = @intCast(node_id.len);
        @memcpy(&entry.boot_session_id, session_id);
        @memcpy(&entry.daemon_instance_id, daemon_id);
        if (reason) |value| {
            const len = @min(value.len, entry.reason.len);
            @memcpy(entry.reason[0..len], value[0..len]);
            entry.reason_len = @intCast(len);
        }
        self.revision += 1;
    }

    pub fn deactivateAll(self: *Store) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var changed = false;
        for (&self.entries) |*entry| {
            if (entry.used() and entry.session_active) {
                entry.session_active = false;
                changed = true;
            }
        }
        if (changed) self.revision += 1;
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
    pub fn currentRevision(self: *Store) u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return self.revision;
    }

    /// 恢复的投影仅为历史观测。daemon 重启永远不会恢复 capability
    /// 或使旧 boot session 变为活跃。
    pub fn restoreInactive(self: *Store, source: *const [max_statuses]Status, revision: u64) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.entries = source.*;
        self.revision = revision;
        for (&self.entries) |*entry| {
            if (entry.used()) entry.session_active = false;
        }
    }
};

/// M3 有两条独立进度路径（安装器和无盘），加上公共的初始配置获取。
/// 失败对当前 session 是终止性的；新的 boot session 由 `update` 作为
/// 全新投影处理。
fn phaseAdvances(current: Phase, next: Phase) bool {
    if (current == next) return true;
    if (current == .failed or current == .completed or current == .running) return next == .failed;
    if (next == .failed) return true;
    return phaseRank(next) >= phaseRank(current);
}

fn phaseRank(phase: Phase) u8 {
    return switch (phase) {
        .boot_config_fetched => 1,
        .installer_started, .install_config_fetched, .initrd_started => 2,
        .install_started, .install_partitioning, .rootfs_downloading => 3,
        .install_packages => 4,
        .install_bootloader => 5,
        .install_post => 6,
        .install_rebooting => 7,
        .rootfs_verified => 4,
        .rootfs_mounted => 5,
        .switching_root => 6,
        .completed, .running => 8,
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

test "node status records model revision and deployment generation provenance" {
    var store: Store = .{};
    const id = "0123456789abcdef0123456789abcdef";
    try store.updateForDeployment("n1", id, id, 42, [_]u8{'4'} ** 64, 5, .install_started, null, 10, true);
    const status = store.get("n1").?;
    try std.testing.expectEqual(@as(u64, 42), status.model_revision);
    try std.testing.expectEqual(@as(u64, 5), status.deployment_generation);
}

test "restored status retains history but invalidates old session" {
    var original: Store = .{};
    const id = "0123456789abcdef0123456789abcdef";
    try original.update("n1", id, id, .running, null, 3, true);
    var snapshot: [max_statuses]Status = undefined;
    original.snapshot(&snapshot);
    var restored: Store = .{};
    restored.restoreInactive(&snapshot, original.currentRevision());
    const status = restored.get("n1").?;
    try std.testing.expectEqual(Phase.running, status.phase);
    try std.testing.expect(!status.session_active);
}

test "effective status capacity searches restored entries outside the prefix" {
    const id = "0123456789abcdef0123456789abcdef";
    var source = [_]Status{.{}} ** max_statuses;
    source[1].node_id_len = 2;
    @memcpy(source[1].node_id[0..2], "n1");
    @memcpy(&source[1].boot_session_id, id);
    @memcpy(&source[1].daemon_instance_id, id);
    var store: Store = .{};
    store.restoreInactive(&source, 1);
    store.setEffective(1);
    try store.update("n1", id, id, .running, null, 2, true);
    try std.testing.expectEqual(Phase.running, store.entries[1].phase);
    try std.testing.expect(!store.entries[0].used());
    try std.testing.expectError(error.NodeStatusCapacityExhausted, store.update("n2", id, id, .running, null, 3, true));
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

test "install projection retains the most specific verified stage" {
    var store: Store = .{};
    const id = "0123456789abcdef0123456789abcdef";
    try store.update("n1", id, id, .install_partitioning, null, 1, true);
    try store.update("n1", id, id, .install_packages, null, 2, true);
    try store.update("n1", id, id, .install_bootloader, null, 3, true);
    const status = store.get("n1").?;
    try std.testing.expectEqual(Phase.install_bootloader, status.phase);
}
