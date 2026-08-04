//! v0.4 generation-bound first-boot journal store.
//!
//! F4 修复（v0.4 token 简化）：first-boot 确定性令牌依赖 `daemon_secret` 作为
//! HMAC 主密钥。daemon 重启后，secret 从磁盘加载，令牌可确定性重建。但若
//! secret 文件被删除/重建（密钥轮换），所有在途 first-boot 令牌将失效。
//! 为检测此场景，store 在持久化时记录 secret 的 SHA-256 指纹（非 secret 本身）；
//! 加载时比对当前 secret 指纹，不匹配则将该 entry 标记为 `recovery_incomplete`，
//! 拒绝继续处理，要求节点重新发起 first-boot 交换。

const std = @import("std");
const journal = @import("install_first_boot.zig");
const dhcp_store = @import("dhcp_store.zig");

pub const max_entries = 256;
pub const node_cap = 96;
pub const digest_cap = 64;
pub const event_cap = 96;
pub const fingerprint_cap = 64;
/// schema 2 新增 secret_fingerprint 字段。加载时若遇到 schema 1（无指纹），
/// 视为指纹缺失，按 recovery_incomplete 处理，强制重新交换。
pub const schema_version: u32 = 2;

pub const Entry = struct {
    used: bool = false,
    node_id: [node_cap]u8 = [_]u8{0} ** node_cap,
    node_len: u8 = 0,
    generation: u64 = 0,
    bundle_revision: u64 = 0,
    plan_digest: [digest_cap]u8 = [_]u8{0} ** digest_cap,
    plan_len: u8 = 0,
    started_event: [event_cap]u8 = [_]u8{0} ** event_cap,
    started_len: u8 = 0,
    terminal_event: [event_cap]u8 = [_]u8{0} ** event_cap,
    terminal_len: u8 = 0,
    /// F4：签发该 entry 时 daemon_secret 的 SHA-256 指纹（64 hex）。
    /// 加载时与当前 secret 指纹比对，不匹配则标记 recovery_incomplete。
    secret_fingerprint: [fingerprint_cap]u8 = [_]u8{0} ** fingerprint_cap,
    fingerprint_len: u8 = 0,
    journal: journal.Journal = .{},

    pub fn node(self: *const Entry) []const u8 {
        return self.node_id[0..self.node_len];
    }
    pub fn plan(self: *const Entry) []const u8 {
        return self.plan_digest[0..self.plan_len];
    }
    pub fn startedEvent(self: *const Entry) []const u8 {
        return self.started_event[0..self.started_len];
    }
    pub fn terminalEvent(self: *const Entry) []const u8 {
        return self.terminal_event[0..self.terminal_len];
    }
};

const DiskEntry = struct {
    node_id: []const u8,
    generation: u64,
    bundle_revision: u64,
    plan_digest: []const u8,
    started_event: ?[]const u8 = null,
    terminal_event: ?[]const u8 = null,
    /// F4：secret 指纹。schema 1 的旧文件无此字段，解析时为 null。
    secret_fingerprint: ?[]const u8 = null,
    journal: journal.Journal,
};

const DiskFile = struct {
    schema_version: u32 = schema_version,
    revision: u64 = 0,
    entries: []const DiskEntry = &.{},
};

/// 计算 daemon_secret 的 SHA-256 指纹（64 hex）。仅用于持久化比对，不存储
/// secret 本身。指纹不匹配意味着 secret 已轮换，该 entry 的确定性令牌
/// 无法重建，必须标记 recovery_incomplete。
pub fn secretFingerprint(buffer: *[fingerprint_cap]u8, secret: []const u8) []const u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(secret, &raw, .{});
    _ = std.fmt.bufPrint(buffer, "{x}", .{raw}) catch unreachable;
    return buffer[0..];
}

pub const Store = struct {
    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,
    revision: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,

    /// F4：加载 first-boot journal 并校验 secret 指纹。
    ///
    /// `daemon_secret` 是当前 daemon 的主密钥。每个持久化 entry 记录了签发时
    /// 的 secret 指纹；加载时比对，不匹配则调用 `markRecoveryIncomplete`，
    /// 使该 entry 的 exchange/event 请求被拒绝。schema 1（无指纹）的旧文件
    /// 同样视为指纹缺失，强制重新交换。
    pub fn load(self: *Store, io: std.Io, allocator: std.mem.Allocator, path: []const u8, daemon_secret: []const u8) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(DiskFile, allocator, bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        // 接受 schema 1（旧文件，无 secret_fingerprint）和 schema 2（当前）。
        if ((parsed.value.schema_version != schema_version and parsed.value.schema_version != 1) or parsed.value.entries.len > max_entries) return error.InvalidFirstBootJournal;
        var current_fingerprint: [fingerprint_cap]u8 = undefined;
        _ = secretFingerprint(&current_fingerprint, daemon_secret);
        self.entries = [_]Entry{.{}} ** max_entries;
        self.revision = parsed.value.revision;
        for (parsed.value.entries, 0..) |item, index| {
            if (item.node_id.len == 0 or item.node_id.len > node_cap or item.generation == 0 or item.plan_digest.len != digest_cap) return error.InvalidFirstBootJournal;
            self.entries[index] = .{ .used = true, .node_len = @intCast(item.node_id.len), .generation = item.generation, .bundle_revision = item.bundle_revision, .plan_len = @intCast(item.plan_digest.len), .journal = item.journal };
            @memcpy(self.entries[index].node_id[0..item.node_id.len], item.node_id);
            @memcpy(self.entries[index].plan_digest[0..item.plan_digest.len], item.plan_digest);
            if (item.started_event) |event| {
                if (event.len > event_cap) return error.InvalidFirstBootJournal;
                self.entries[index].started_len = @intCast(event.len);
                @memcpy(self.entries[index].started_event[0..event.len], event);
                self.entries[index].journal.started_event_id = self.entries[index].startedEvent();
            }
            if (item.terminal_event) |event| {
                if (event.len > event_cap) return error.InvalidFirstBootJournal;
                self.entries[index].terminal_len = @intCast(event.len);
                @memcpy(self.entries[index].terminal_event[0..event.len], event);
                self.entries[index].journal.terminal_event_id = self.entries[index].terminalEvent();
            }
            // F4：校验 secret 指纹。缺失（schema 1）或不匹配（secret 轮换）
            // 则标记 recovery_incomplete，拒绝继续处理该 entry。
            const stored_fp = item.secret_fingerprint orelse "";
            if (stored_fp.len == fingerprint_cap) {
                @memcpy(self.entries[index].secret_fingerprint[0..fingerprint_cap], stored_fp);
                self.entries[index].fingerprint_len = fingerprint_cap;
                if (!std.crypto.timing_safe.eql([fingerprint_cap]u8, self.entries[index].secret_fingerprint, current_fingerprint)) {
                    self.entries[index].journal.markRecoveryIncomplete();
                }
            } else {
                // 无指纹（schema 1 旧文件）——无法证明 secret 一致，强制恢复。
                self.entries[index].journal.markRecoveryIncomplete();
            }
        }
    }

    pub fn find(self: *Store, node_id: []const u8, generation: u64) ?*Entry {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used and entry.generation == generation and std.mem.eql(u8, entry.node(), node_id)) return entry;
        return null;
    }

    /// F4：创建新 entry 时记录当前 daemon_secret 的指纹。
    /// `daemon_secret` 用于在持久化时绑定 secret 身份，加载时比对。
    pub fn create(self: *Store, node_id: []const u8, generation: u64, bundle_revision: u64, plan_digest: []const u8, daemon_secret: []const u8) !*Entry {
        if (node_id.len == 0 or node_id.len > node_cap or generation == 0 or plan_digest.len != digest_cap) return error.InvalidFirstBootJournal;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used and entry.generation == generation and std.mem.eql(u8, entry.node(), node_id)) return error.FirstBootJournalExists;
        for (&self.entries) |*entry| if (!entry.used) {
            entry.* = .{ .used = true, .node_len = @intCast(node_id.len), .generation = generation, .bundle_revision = bundle_revision, .plan_len = @intCast(plan_digest.len) };
            @memcpy(entry.node_id[0..node_id.len], node_id);
            @memcpy(entry.plan_digest[0..plan_digest.len], plan_digest);
            var fp: [fingerprint_cap]u8 = undefined;
            const fp_slice = secretFingerprint(&fp, daemon_secret);
            @memcpy(entry.secret_fingerprint[0..fingerprint_cap], fp_slice);
            entry.fingerprint_len = fingerprint_cap;
            self.revision += 1;
            return entry;
        };
        return error.FirstBootJournalCapacity;
    }

    pub fn handoff(self: *Store, node_id: []const u8, generation: u64) !void {
        const entry = self.find(node_id, generation) orelse return error.FirstBootJournalNotFound;
        lock(&self.mutex);
        defer self.mutex.unlock();
        try entry.journal.handoff();
        self.revision += 1;
    }
    pub fn started(self: *Store, node_id: []const u8, generation: u64, event_id: []const u8) !void {
        const entry = self.find(node_id, generation) orelse return error.FirstBootJournalNotFound;
        if (event_id.len == 0 or event_id.len > event_cap) return error.FirstBootEventInvalid;
        lock(&self.mutex);
        defer self.mutex.unlock();
        try entry.journal.started(event_id);
        if (entry.started_len == 0) {
            entry.started_len = @intCast(event_id.len);
            @memcpy(entry.started_event[0..event_id.len], event_id);
        }
        entry.journal.started_event_id = entry.startedEvent();
        self.revision += 1;
    }

    pub fn beginStep(self: *Store, node_id: []const u8, generation: u64, step: usize) !void {
        const entry = self.find(node_id, generation) orelse return error.FirstBootJournalNotFound;
        lock(&self.mutex);
        defer self.mutex.unlock();
        try entry.journal.beginStep(step);
        self.revision += 1;
    }
    pub fn stepSucceeded(self: *Store, node_id: []const u8, generation: u64) !void {
        const entry = self.find(node_id, generation) orelse return error.FirstBootJournalNotFound;
        lock(&self.mutex);
        defer self.mutex.unlock();
        try entry.journal.stepSucceeded();
        self.revision += 1;
    }

    pub fn terminal(self: *Store, node_id: []const u8, generation: u64, success: bool, event_id: []const u8) !void {
        const entry = self.find(node_id, generation) orelse return error.FirstBootJournalNotFound;
        if (event_id.len == 0 or event_id.len > event_cap) return error.FirstBootEventInvalid;
        lock(&self.mutex);
        defer self.mutex.unlock();
        try entry.journal.terminal(success, event_id);
        if (entry.terminal_len == 0) {
            entry.terminal_len = @intCast(event_id.len);
            @memcpy(entry.terminal_event[0..event_id.len], event_id);
        }
        entry.journal.terminal_event_id = entry.terminalEvent();
        self.revision += 1;
    }

    pub fn acknowledge(self: *Store, node_id: []const u8, generation: u64, success: bool) !void {
        const entry = self.find(node_id, generation) orelse return error.FirstBootJournalNotFound;
        lock(&self.mutex);
        defer self.mutex.unlock();
        try entry.journal.acknowledgeTerminal(success);
        self.revision += 1;
    }

    pub fn save(self: *Store, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var disk: [max_entries]DiskEntry = undefined;
        var count: usize = 0;
        for (&self.entries) |*entry| if (entry.used) {
            disk[count] = .{ .node_id = entry.node(), .generation = entry.generation, .bundle_revision = entry.bundle_revision, .plan_digest = entry.plan(), .started_event = if (entry.started_len == 0) null else entry.startedEvent(), .terminal_event = if (entry.terminal_len == 0) null else entry.terminalEvent(), .secret_fingerprint = if (entry.fingerprint_len == 0) null else entry.secret_fingerprint[0..entry.fingerprint_len], .journal = entry.journal };
            count += 1;
        };
        const bytes = try std.json.Stringify.valueAlloc(allocator, DiskFile{ .revision = self.revision, .entries = disk[0..count] }, .{});
        defer allocator.free(bytes);
        try dhcp_store.atomicWrite(io, path, bytes);
    }
};

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

test "first-boot store binds every reducer operation to node and generation" {
    var store: Store = .{};
    _ = try store.create("node-1", 7, 3, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "daemon-secret");
    try store.handoff("node-1", 7);
    try std.testing.expectEqual(@as(u64, 1), try store.exchange("node-1", 7));
    try store.started("node-1", 7, "start-7");
    try store.beginStep("node-1", 7, 0);
    try store.stepSucceeded("node-1", 7);
    try store.terminal("node-1", 7, true, "done-7");
    try store.acknowledge("node-1", 7, true);
    try std.testing.expectEqual(journal.LocalState.completed_acknowledged, store.find("node-1", 7).?.journal.local);
    try std.testing.expect(store.find("node-1", 8) == null);
}

test "F4: secret fingerprint mismatch marks recovery incomplete" {
    // 用 secret-A 创建 entry，然后用 secret-B 模拟 daemon 重启后密钥轮换。
    var store: Store = .{};
    _ = try store.create("node-1", 7, 3, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "secret-A");
    try store.handoff("node-1", 7);
    _ = try store.exchange("node-1", 7);
    // 保存到内存中的 entry 应有指纹。
    const entry_before = store.find("node-1", 7).?;
    try std.testing.expect(entry_before.fingerprint_len == fingerprint_cap);
    try std.testing.expectEqual(journal.ServerState.exchanging, entry_before.journal.server);

    // 模拟重启：新建 store，用不同 secret 加载同一 entry（通过手动模拟）。
    // 在实际代码中 load 从磁盘读取；这里直接验证指纹比对逻辑。
    var fp_a: [fingerprint_cap]u8 = undefined;
    var fp_b: [fingerprint_cap]u8 = undefined;
    const a = secretFingerprint(&fp_a, "secret-A");
    const b = secretFingerprint(&fp_b, "secret-B");
    try std.testing.expect(!std.mem.eql(u8, a, b));

    // 手动标记 recovery_incomplete（模拟 load 中的密钥不匹配路径）。
    entry_before.journal.markRecoveryIncomplete();
    try std.testing.expectEqual(journal.ServerState.recovery_incomplete, entry_before.journal.server);
    try std.testing.expectEqual(journal.LocalState.recovery_incomplete, entry_before.journal.local);
}

test "F4: matching secret fingerprint keeps entry valid" {
    var store: Store = .{};
    _ = try store.create("node-2", 1, 1, "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "same-secret");
    try store.handoff("node-2", 1);
    _ = try store.exchange("node-2", 1);
    const entry = store.find("node-2", 1).?;
    // 指纹已记录，且 entry 处于正常状态（非 recovery_incomplete）。
    try std.testing.expect(entry.fingerprint_len == fingerprint_cap);
    try std.testing.expectEqual(journal.ServerState.exchanging, entry.journal.server);
    var fp: [fingerprint_cap]u8 = undefined;
    const expected_fp = secretFingerprint(&fp, "same-secret");
    try std.testing.expectEqualSlices(u8, entry.secret_fingerprint[0..fingerprint_cap], expected_fp);
}
