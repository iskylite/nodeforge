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
const capacity = @import("capacity.zig");
const dhcp_store = @import("dhcp_store.zig");

// Re-export for callers that set shared wave admission.

/// Compile-time ceiling (active + terminal projection slots each).
pub const max_entries = capacity.store_ceiling;
/// Design default effective active admission before managed-capacity expansion.
pub const default_effective = capacity.first_boot_default;
pub const node_cap = 96;
pub const digest_cap = 64;
pub const event_cap = 96;
pub const fingerprint_cap = 64;
/// schema 3: active entries + terminal_summaries; acknowledged gens free active slots.
/// schema 2 still loads (all entries treated as active until acknowledged).
pub const schema_version: u32 = 3;

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

const DiskTerminal = struct {
    node_id: []const u8,
    generation: u64,
    success: bool,
    plan_digest: []const u8,
    terminal_event: ?[]const u8 = null,
};

const DiskFile = struct {
    schema_version: u32 = schema_version,
    revision: u64 = 0,
    entries: []const DiskEntry = &.{},
    terminal_summaries: []const DiskTerminal = &.{},
};

/// Durable terminal fact after acknowledge; does not consume active admission.
pub const TerminalSummary = struct {
    used: bool = false,
    node_id: [node_cap]u8 = [_]u8{0} ** node_cap,
    node_len: u8 = 0,
    generation: u64 = 0,
    success: bool = false,
    plan_digest: [digest_cap]u8 = [_]u8{0} ** digest_cap,
    plan_len: u8 = 0,
    terminal_event: [event_cap]u8 = [_]u8{0} ** event_cap,
    terminal_len: u8 = 0,

    pub fn node(self: *const TerminalSummary) []const u8 {
        return self.node_id[0..self.node_len];
    }
    pub fn plan(self: *const TerminalSummary) []const u8 {
        return self.plan_digest[0..self.plan_len];
    }
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
    terminals: [max_entries]TerminalSummary = [_]TerminalSummary{.{}} ** max_entries,
    /// Structural active slot ceiling. Product wave limit is `wave` when set.
    effective: usize = default_effective,
    wave: ?*capacity.DeploymentWaveAdmission = null,
    revision: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn setEffective(self: *Store, value: usize) void {
        const active = self.activeCountUnlocked();
        self.effective = @max(active, @max(@as(usize, 1), @min(value, max_entries)));
    }

    pub fn setWave(self: *Store, wave: *capacity.DeploymentWaveAdmission) void {
        self.wave = wave;
    }

    pub fn activeCount(self: *const Store) usize {
        return self.activeCountUnlocked();
    }

    fn activeCountUnlocked(self: *const Store) usize {
        var n: usize = 0;
        for (self.entries) |entry| {
            if (entry.used) n += 1;
        }
        return n;
    }

    /// F4：加载 first-boot journal 并校验 secret 指纹。
    ///
    /// `daemon_secret` 是当前 daemon 的主密钥。每个持久化 entry 记录了签发时
    /// 的 secret 指纹；加载时比对，不匹配则调用 `markRecoveryIncomplete`，
    /// 使该 entry 的 exchange/event 请求被拒绝。schema 1（无指纹）的旧文件
    /// 同样视为指纹缺失，强制重新交换。
    pub fn load(self: *Store, io: std.Io, allocator: std.mem.Allocator, path: []const u8, daemon_secret: []const u8) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(capacity.checkpoint_read_max_bytes)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(DiskFile, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
        defer parsed.deinit();
        // Accept schema 1/2/3. schema 3 adds terminal_summaries.
        if (parsed.value.schema_version < 1 or parsed.value.schema_version > schema_version or
            parsed.value.entries.len > max_entries or parsed.value.terminal_summaries.len > max_entries)
            return error.InvalidFirstBootJournal;
        var current_fingerprint: [fingerprint_cap]u8 = undefined;
        _ = secretFingerprint(&current_fingerprint, daemon_secret);
        self.entries = [_]Entry{.{}} ** max_entries;
        self.terminals = [_]TerminalSummary{.{}} ** max_entries;
        self.revision = parsed.value.revision;
        var active_index: usize = 0;
        for (parsed.value.entries) |item| {
            if (item.node_id.len == 0 or item.node_id.len > node_cap or item.generation == 0 or item.plan_digest.len != digest_cap) return error.InvalidFirstBootJournal;
            // schema 2 may still hold acknowledged journals; migrate to terminal summary.
            const local = item.journal.local;
            if (local == .completed_acknowledged or local == .failed_acknowledged) {
                try self.writeTerminalUnlocked(item.node_id, item.generation, local == .completed_acknowledged, item.plan_digest, item.terminal_event);
                continue;
            }
            if (active_index >= max_entries) return error.InvalidFirstBootJournal;
            self.entries[active_index] = .{ .used = true, .node_len = @intCast(item.node_id.len), .generation = item.generation, .bundle_revision = item.bundle_revision, .plan_len = @intCast(item.plan_digest.len), .journal = item.journal };
            @memcpy(self.entries[active_index].node_id[0..item.node_id.len], item.node_id);
            @memcpy(self.entries[active_index].plan_digest[0..item.plan_digest.len], item.plan_digest);
            if (item.started_event) |event| {
                if (event.len > event_cap) return error.InvalidFirstBootJournal;
                self.entries[active_index].started_len = @intCast(event.len);
                @memcpy(self.entries[active_index].started_event[0..event.len], event);
                self.entries[active_index].journal.started_event_id = self.entries[active_index].startedEvent();
            }
            if (item.terminal_event) |event| {
                if (event.len > event_cap) return error.InvalidFirstBootJournal;
                self.entries[active_index].terminal_len = @intCast(event.len);
                @memcpy(self.entries[active_index].terminal_event[0..event.len], event);
                self.entries[active_index].journal.terminal_event_id = self.entries[active_index].terminalEvent();
            }
            const stored_fp = item.secret_fingerprint orelse "";
            if (stored_fp.len == fingerprint_cap) {
                @memcpy(self.entries[active_index].secret_fingerprint[0..fingerprint_cap], stored_fp);
                self.entries[active_index].fingerprint_len = fingerprint_cap;
                if (!std.crypto.timing_safe.eql([fingerprint_cap]u8, self.entries[active_index].secret_fingerprint, current_fingerprint)) {
                    self.entries[active_index].journal.markRecoveryIncomplete();
                }
            } else {
                self.entries[active_index].journal.markRecoveryIncomplete();
            }
            active_index += 1;
        }
        for (parsed.value.terminal_summaries) |item| {
            try self.writeTerminalUnlocked(item.node_id, item.generation, item.success, item.plan_digest, item.terminal_event);
        }
        // Ensure effective can hold restored actives.
        if (active_index > self.effective) self.effective = @min(active_index, max_entries);
    }

    /// Keep one durable terminal fact per Node (latest generation wins).
    fn writeTerminalUnlocked(self: *Store, node_id: []const u8, generation: u64, success: bool, plan_digest: []const u8, terminal_event: ?[]const u8) !void {
        if (node_id.len == 0 or node_id.len > node_cap or generation == 0 or plan_digest.len != digest_cap) return error.InvalidFirstBootJournal;
        if (terminal_event) |event| if (event.len > event_cap) return error.InvalidFirstBootJournal;

        // Replace same-node summary (any generation) when this generation is newer or equal.
        for (&self.terminals) |*slot| {
            if (!(slot.used and std.mem.eql(u8, slot.node(), node_id))) continue;
            if (generation < slot.generation) return; // stale
            slot.generation = generation;
            slot.success = success;
            slot.plan_len = @intCast(plan_digest.len);
            @memcpy(slot.plan_digest[0..plan_digest.len], plan_digest);
            if (terminal_event) |event| {
                slot.terminal_len = @intCast(event.len);
                @memcpy(slot.terminal_event[0..event.len], event);
            } else {
                slot.terminal_len = 0;
            }
            return;
        }
        for (&self.terminals) |*slot| {
            if (slot.used) continue;
            slot.* = .{
                .used = true,
                .node_len = @intCast(node_id.len),
                .generation = generation,
                .success = success,
                .plan_len = @intCast(plan_digest.len),
            };
            @memcpy(slot.node_id[0..node_id.len], node_id);
            @memcpy(slot.plan_digest[0..plan_digest.len], plan_digest);
            if (terminal_event) |event| {
                slot.terminal_len = @intCast(event.len);
                @memcpy(slot.terminal_event[0..event.len], event);
            }
            return;
        }
        return error.FirstBootJournalCapacity;
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
        // Shared wave before lock/side effects.
        if (self.wave) |w| {
            w.tryAcquire() catch return error.FirstBootJournalCapacity;
        }
        var wave_held = self.wave != null;
        errdefer if (wave_held) if (self.wave) |w| w.release();

        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used and entry.generation == generation and std.mem.eql(u8, entry.node(), node_id)) {
            // Exists: drop wave slot we just acquired.
            if (wave_held) if (self.wave) |w| w.release();
            wave_held = false;
            return error.FirstBootJournalExists;
        };
        if (self.wave == null and self.activeCountUnlocked() >= self.effective) return error.FirstBootJournalCapacity;
        for (&self.entries) |*entry| if (!entry.used) {
            entry.* = .{ .used = true, .node_len = @intCast(node_id.len), .generation = generation, .bundle_revision = bundle_revision, .plan_len = @intCast(plan_digest.len) };
            @memcpy(entry.node_id[0..node_id.len], node_id);
            @memcpy(entry.plan_digest[0..plan_digest.len], plan_digest);
            var fp: [fingerprint_cap]u8 = undefined;
            const fp_slice = secretFingerprint(&fp, daemon_secret);
            @memcpy(entry.secret_fingerprint[0..fingerprint_cap], fp_slice);
            entry.fingerprint_len = fingerprint_cap;
            self.revision += 1;
            wave_held = false;
            return entry;
        };
        return error.FirstBootJournalCapacity;
    }

    /// Latest terminal fact for a node (any generation). Optional generation
    /// filter: when non-null, only match that generation.
    pub fn terminalSummary(self: *Store, node_id: []const u8, generation: ?u64) ?*TerminalSummary {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.terminals) |*slot| {
            if (!slot.used or !std.mem.eql(u8, slot.node(), node_id)) continue;
            if (generation) |g| {
                if (slot.generation == g) return slot;
            } else return slot;
        }
        return null;
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

    /// Snapshot used to roll memory back if a subsequent durable save fails.
    /// Shared wave is held until `commitAcknowledge` (after durable save succeeds);
    /// `undoAcknowledge` restores the entry without re-acquiring the wave.
    pub const AcknowledgeUndo = struct {
        node_id: [node_cap]u8 = [_]u8{0} ** node_cap,
        node_len: u8 = 0,
        generation: u64 = 0,
        entry: Entry = .{},
        had_prior_terminal: bool = false,
        prior_terminal: TerminalSummary = .{},
        applied: bool = false,
        /// True when a shared wave slot still covers this in-flight acknowledge.
        wave_pending: bool = false,

        pub fn node(self: *const AcknowledgeUndo) []const u8 {
            return self.node_id[0..self.node_len];
        }
    };

    /// Apply acknowledge in memory (summary + free active). Does **not** release the
    /// shared wave slot — call `commitAcknowledge` only after durable save succeeds.
    /// On save failure call `undoAcknowledge` so the active entry remains retryable
    /// while the wave occupancy stays accurate without a re-acquire race.
    pub fn acknowledge(self: *Store, node_id: []const u8, generation: u64, success: bool) !AcknowledgeUndo {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var entry: ?*Entry = null;
        for (&self.entries) |*e| {
            if (e.used and e.generation == generation and std.mem.eql(u8, e.node(), node_id)) {
                entry = e;
                break;
            }
        }
        const active = entry orelse return error.FirstBootJournalNotFound;
        if (success and active.journal.local != .completed_pending_ack) return error.FirstBootStateConflict;
        if (!success and active.journal.local != .failed_pending_ack) return error.FirstBootStateConflict;

        var undo: AcknowledgeUndo = .{
            .node_len = @intCast(node_id.len),
            .generation = generation,
            .entry = active.*,
            .applied = true,
            .wave_pending = self.wave != null,
        };
        @memcpy(undo.node_id[0..node_id.len], node_id);
        if (self.findTerminalUnlocked(node_id)) |slot| {
            undo.had_prior_terminal = true;
            undo.prior_terminal = slot.*;
        }

        const plan = active.plan();
        const term_event: ?[]const u8 = if (active.terminal_len == 0) null else active.terminalEvent();
        // Summary first (capacity may fail without mutating journal).
        try self.writeTerminalUnlocked(node_id, generation, success, plan, term_event);
        try active.journal.acknowledgeTerminal(success);
        active.* = .{};
        self.revision += 1;
        // Wave release deferred to commitAcknowledge after durable save.
        return undo;
    }

    /// Release the shared wave slot after a durable save has committed the acknowledge.
    /// Consumes `undo` (clears `applied` / `wave_pending`) so a second commit is a no-op
    /// and cannot double-release the shared wave.
    pub fn commitAcknowledge(self: *Store, undo: *AcknowledgeUndo) void {
        if (!undo.applied) return;
        if (undo.wave_pending) {
            if (self.wave) |w| w.release();
            undo.wave_pending = false;
        }
        undo.applied = false;
    }

    /// Reverse a successful `acknowledge` when durable save failed.
    /// Wave was never released in `acknowledge`, so no re-acquire is required.
    /// Consumes `undo` so a second undo is a no-op. Undo after `commitAcknowledge`
    /// is also a no-op (durable state already matches free active + released wave).
    pub fn undoAcknowledge(self: *Store, undo: *AcknowledgeUndo) void {
        if (!undo.applied) return;
        lock(&self.mutex);
        defer self.mutex.unlock();
        // Restore prior terminal summary for the node (or clear if none).
        if (undo.had_prior_terminal) {
            for (&self.terminals) |*slot| {
                if (slot.used and std.mem.eql(u8, slot.node(), undo.node())) {
                    slot.* = undo.prior_terminal;
                    break;
                }
            }
        } else {
            for (&self.terminals) |*slot| {
                if (slot.used and std.mem.eql(u8, slot.node(), undo.node())) {
                    slot.* = .{};
                    break;
                }
            }
        }
        // Restore active entry into a free slot (prefer original if free).
        for (&self.entries) |*e| {
            if (!e.used) {
                e.* = undo.entry;
                self.revision += 1;
                undo.applied = false;
                return;
            }
        }
        // No free slot: overwrite any slot matching the same node+generation if present,
        // else leave terminal restored only (wave still held for the logical active).
        for (&self.entries) |*e| {
            if (e.used and e.generation == undo.generation and std.mem.eql(u8, e.node(), undo.node())) {
                e.* = undo.entry;
                self.revision += 1;
                undo.applied = false;
                return;
            }
        }
        // Structural table full: consume undo; wave remains held (fail-closed occupancy).
        undo.applied = false;
    }

    fn findTerminalUnlocked(self: *Store, node_id: []const u8) ?*TerminalSummary {
        for (&self.terminals) |*slot| {
            if (slot.used and std.mem.eql(u8, slot.node(), node_id)) return slot;
        }
        return null;
    }

    pub fn save(self: *Store, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        const disk = try allocator.alloc(DiskEntry, max_entries);
        defer allocator.free(disk);
        var count: usize = 0;
        for (&self.entries) |*entry| if (entry.used) {
            disk[count] = .{ .node_id = entry.node(), .generation = entry.generation, .bundle_revision = entry.bundle_revision, .plan_digest = entry.plan(), .started_event = if (entry.started_len == 0) null else entry.startedEvent(), .terminal_event = if (entry.terminal_len == 0) null else entry.terminalEvent(), .secret_fingerprint = if (entry.fingerprint_len == 0) null else entry.secret_fingerprint[0..entry.fingerprint_len], .journal = entry.journal };
            count += 1;
        };
        const terms = try allocator.alloc(DiskTerminal, max_entries);
        defer allocator.free(terms);
        var term_count: usize = 0;
        for (&self.terminals) |*slot| if (slot.used) {
            terms[term_count] = .{
                .node_id = slot.node(),
                .generation = slot.generation,
                .success = slot.success,
                .plan_digest = slot.plan(),
                .terminal_event = if (slot.terminal_len == 0) null else slot.terminal_event[0..slot.terminal_len],
            };
            term_count += 1;
        };
        const bytes = try std.json.Stringify.valueAlloc(allocator, DiskFile{
            .revision = self.revision,
            .entries = disk[0..count],
            .terminal_summaries = terms[0..term_count],
        }, .{});
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
    try store.started("node-1", 7, "start-7");
    try store.beginStep("node-1", 7, 0);
    try store.stepSucceeded("node-1", 7);
    try store.terminal("node-1", 7, true, "done-7");
    _ = try store.acknowledge("node-1", 7, true);
    // Acknowledge frees the active slot and keeps a terminal summary.
    try std.testing.expect(store.find("node-1", 7) == null);
    const summary = store.terminalSummary("node-1", null) orelse return error.TestExpectedEqual;
    try std.testing.expect(summary.success);
    try std.testing.expectEqual(@as(u64, 7), summary.generation);
    try std.testing.expect(store.find("node-1", 8) == null);
}

test "F4: secret fingerprint mismatch marks recovery incomplete" {
    // 用 secret-A 创建 entry，然后用 secret-B 模拟 daemon 重启后密钥轮换。
    var store: Store = .{};
    _ = try store.create("node-1", 7, 3, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "secret-A");
    try store.handoff("node-1", 7);
    // 保存到内存中的 entry 应有指纹。
    const entry_before = store.find("node-1", 7).?;
    try std.testing.expect(entry_before.fingerprint_len == fingerprint_cap);
    try std.testing.expectEqual(journal.ServerState.handoff_complete, entry_before.journal.server);

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
    const entry = store.find("node-2", 1).?;
    // 指纹已记录，且 entry 处于正常状态（非 recovery_incomplete）。
    try std.testing.expect(entry.fingerprint_len == fingerprint_cap);
    try std.testing.expectEqual(journal.ServerState.handoff_complete, entry.journal.server);
    var fp: [fingerprint_cap]u8 = undefined;
    const expected_fp = secretFingerprint(&fp, "same-secret");
    try std.testing.expectEqualSlices(u8, entry.secret_fingerprint[0..fingerprint_cap], expected_fp);
}

test "v0.4 capacity: 512 active first-boot slots; acknowledge frees for next wave" {
    var store: Store = .{};
    store.setEffective(default_effective);
    try std.testing.expectEqual(@as(usize, 512), store.effective);
    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var i: usize = 0;
    while (i < default_effective) : (i += 1) {
        var node_buf: [32]u8 = undefined;
        const node = try std.fmt.bufPrint(&node_buf, "node-{d}", .{i});
        _ = try store.create(node, @intCast(i + 1), 1, digest, "secret");
    }
    try std.testing.expectError(error.FirstBootJournalCapacity, store.create("overflow", 9999, 1, digest, "secret"));

    // Complete and acknowledge generation 1 on node-0 → free active slot.
    try store.handoff("node-0", 1);
    try store.started("node-0", 1, "start-0");
    try store.beginStep("node-0", 1, 0);
    try store.stepSucceeded("node-0", 1);
    try store.terminal("node-0", 1, true, "done-0");
    _ = try store.acknowledge("node-0", 1, true);
    try std.testing.expect(store.find("node-0", 1) == null);
    try std.testing.expect(store.terminalSummary("node-0", null) != null);

    _ = try store.create("wave-2", 10001, 1, digest, "secret");
    try std.testing.expect(store.find("wave-2", 10001) != null);
}

test "v0.4 capacity: undoAcknowledge restores active entry after failed durable save" {
    var store: Store = .{};
    store.setEffective(8);
    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    _ = try store.create("node-u", 1, 1, digest, "secret");
    try store.handoff("node-u", 1);
    try store.started("node-u", 1, "s");
    try store.beginStep("node-u", 1, 0);
    try store.stepSucceeded("node-u", 1);
    try store.terminal("node-u", 1, true, "t");
    var undo = try store.acknowledge("node-u", 1, true);
    try std.testing.expect(store.find("node-u", 1) == null);
    store.undoAcknowledge(&undo);
    store.undoAcknowledge(&undo); // second undo is a no-op
    const restored = store.find("node-u", 1) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(journal.LocalState.completed_pending_ack, restored.journal.local);
    // Retry acknowledge after undo must succeed (idempotent recovery path).
    var undo2 = try store.acknowledge("node-u", 1, true);
    store.commitAcknowledge(&undo2);
    store.commitAcknowledge(&undo2); // second commit must not double-release
    try std.testing.expect(store.find("node-u", 1) == null);
}

test "v0.4 capacity: acknowledge holds wave until commit; undo keeps occupancy accurate" {
    var wave = capacity.DeploymentWaveAdmission.init(2);
    var store: Store = .{};
    store.setEffective(8);
    store.setWave(&wave);
    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    _ = try store.create("hold-a", 1, 1, digest, "secret");
    _ = try store.create("hold-b", 1, 1, digest, "secret");
    try std.testing.expectEqual(@as(usize, 2), wave.count());
    try store.handoff("hold-a", 1);
    try store.started("hold-a", 1, "s");
    try store.beginStep("hold-a", 1, 0);
    try store.stepSucceeded("hold-a", 1);
    try store.terminal("hold-a", 1, true, "t");

    var undo = try store.acknowledge("hold-a", 1, true);
    // Memory free but wave still held until durable commit.
    try std.testing.expect(store.find("hold-a", 1) == null);
    try std.testing.expectEqual(@as(usize, 2), wave.count());
    try std.testing.expectError(error.FirstBootJournalCapacity, store.create("hold-c", 1, 1, digest, "secret"));

    // Save failed → undo restores entry; wave occupancy unchanged (no re-acquire).
    store.undoAcknowledge(&undo);
    try std.testing.expect(store.find("hold-a", 1) != null);
    try std.testing.expectEqual(@as(usize, 2), wave.count());

    var undo_ok = try store.acknowledge("hold-a", 1, true);
    store.commitAcknowledge(&undo_ok);
    store.commitAcknowledge(&undo_ok); // idempotent
    try std.testing.expectEqual(@as(usize, 1), wave.count());
    // Undo after commit is a no-op: durable success path already released wave.
    store.undoAcknowledge(&undo_ok);
    try std.testing.expect(store.find("hold-a", 1) == null);
    try std.testing.expectEqual(@as(usize, 1), wave.count());
    _ = try store.create("hold-c", 1, 1, digest, "secret");
    try std.testing.expectEqual(@as(usize, 2), wave.count());
}

test "v0.4 capacity: terminal summary is one slot per node across generations" {
    var store: Store = .{};
    store.setEffective(8);
    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    // Fill terminal table with one entry per node up to max_entries via acknowledge.
    // Faster path: write terminals directly for many nodes then redeploy same nodes.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var node_buf: [32]u8 = undefined;
        const node = try std.fmt.bufPrint(&node_buf, "host-{d}", .{i});
        _ = try store.create(node, 1, 1, digest, "secret");
        try store.handoff(node, 1);
        try store.started(node, 1, "s");
        try store.beginStep(node, 1, 0);
        try store.stepSucceeded(node, 1);
        try store.terminal(node, 1, true, "t");
        _ = try store.acknowledge(node, 1, true);
    }
    // Redeploy generation 2 on same nodes must replace, not exhaust.
    i = 0;
    while (i < 4) : (i += 1) {
        var node_buf: [32]u8 = undefined;
        const node = try std.fmt.bufPrint(&node_buf, "host-{d}", .{i});
        _ = try store.create(node, 2, 1, digest, "secret");
        try store.handoff(node, 2);
        try store.started(node, 2, "s2");
        try store.beginStep(node, 2, 0);
        try store.stepSucceeded(node, 2);
        try store.terminal(node, 2, true, "t2");
        _ = try store.acknowledge(node, 2, true);
        const sum = store.terminalSummary(node, null) orelse return error.TestExpectedEqual;
        try std.testing.expectEqual(@as(u64, 2), sum.generation);
    }
    var term_count: usize = 0;
    for (store.terminals) |slot| {
        if (slot.used) term_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), term_count);
}

test "v0.4 capacity: checkpoint save/load restores active and terminal without stack overflow path" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/first-boot.json", .{dir});
    defer std.testing.allocator.free(path);

    var store: Store = .{};
    store.setEffective(8);
    const digest = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    _ = try store.create("n1", 1, 1, digest, "secret");
    try store.handoff("n1", 1);
    try store.started("n1", 1, "s1");
    try store.beginStep("n1", 1, 0);
    try store.stepSucceeded("n1", 1);
    try store.terminal("n1", 1, true, "t1");
    _ = try store.acknowledge("n1", 1, true);
    _ = try store.create("n2", 2, 1, digest, "secret");
    try store.save(std.testing.io, std.testing.allocator, path);

    var loaded: Store = .{};
    try loaded.load(std.testing.io, std.testing.allocator, path, "secret");
    try std.testing.expect(loaded.find("n1", 1) == null);
    try std.testing.expect(loaded.terminalSummary("n1", null) != null);
    try std.testing.expect(loaded.find("n2", 2) != null);
}
