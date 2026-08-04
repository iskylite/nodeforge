//! v0.4 NodeDiscoveryState v1。
//!
//! 该状态与 catalog 分离：catalog 记录期望身份和预约，discovery state 记录
//! 一次 discovery arm 的生命周期。这样 discovery 的 pending/expired/cancelled
//! 不会改变节点 desired model，也不会意外打开 deploy gate。

const std = @import("std");
const model = @import("../model.zig");
const dhcp_store = @import("dhcp_store.zig");

pub const max_states = 2048;
pub const node_id_cap = 96;
pub const serial_cap = 256;
pub const error_cap = 256;
pub const session_cap = 128;

pub const State = enum { pending, matched, failed, expired, cancelled };

pub const Entry = struct {
    used: bool = false,
    node_id: [node_id_cap]u8 = [_]u8{0} ** node_id_cap,
    node_id_len: u8 = 0,
    node_revision: u64 = 0,
    expected_serial_sha256: [64]u8 = [_]u8{0} ** 64,
    serial_display: [serial_cap]u8 = [_]u8{0} ** serial_cap,
    serial_len: u16 = 0,
    created_at: i64 = 0,
    expires_at: i64 = 0,
    state: State = .pending,
    matched_probe_session_id: [session_cap]u8 = [_]u8{0} ** session_cap,
    matched_probe_session_len: u8 = 0,
    matched_facts_sha256: [64]u8 = [_]u8{0} ** 64,
    matched_facts_sha256_len: u8 = 0,
    observed_mac: [17]u8 = [_]u8{0} ** 17,
    observed_mac_len: u8 = 0,
    observed_arch: ?model.Arch = null,
    last_error: [error_cap]u8 = [_]u8{0} ** error_cap,
    last_error_len: u16 = 0,

    pub fn node(self: *const Entry) []const u8 {
        return self.node_id[0..self.node_id_len];
    }
    pub fn serial(self: *const Entry) []const u8 {
        return self.serial_display[0..self.serial_len];
    }
    pub fn session(self: *const Entry) ?[]const u8 {
        return if (self.matched_probe_session_len == 0) null else self.matched_probe_session_id[0..self.matched_probe_session_len];
    }
    pub fn mac(self: *const Entry) ?[]const u8 {
        return if (self.observed_mac_len == 0) null else self.observed_mac[0..self.observed_mac_len];
    }
    pub fn errorMessage(self: *const Entry) ?[]const u8 {
        return if (self.last_error_len == 0) null else self.last_error[0..self.last_error_len];
    }
};

const DiskEntry = struct {
    node_id: []const u8,
    node_revision: u64,
    expected_serial_sha256: []const u8,
    serial_display: []const u8,
    created_at: i64,
    expires_at: i64,
    state: State,
    matched_probe_session_id: ?[]const u8 = null,
    matched_facts_sha256: ?[]const u8 = null,
    observed_mac: ?[]const u8 = null,
    observed_arch: ?model.Arch = null,
    last_error: ?[]const u8 = null,
};
const File = struct { schema_version: u32 = 1, revision: u64 = 0, saved_at: i64 = 0, states: []const DiskEntry = &.{} };

pub const Store = struct {
    entries: [max_states]Entry = [_]Entry{.{}} ** max_states,
    revision: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn currentRevision(self: *Store) u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return self.revision;
    }

    pub fn load(self: *Store, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024));
        defer allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(File, allocator, bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value.schema_version != 1 or parsed.value.states.len > max_states) return error.InvalidNodeDiscoveryState;
        var next: [max_states]Entry = [_]Entry{.{}} ** max_states;
        for (parsed.value.states, 0..) |disk, index| {
            if (!validDisk(disk) or findIn(next[0..index], disk.node_id) != null) return error.InvalidNodeDiscoveryState;
            next[index] = try fromDisk(disk);
        }
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.entries = next;
        self.revision = parsed.value.revision;
    }

    pub fn save(self: *Store, io: std.Io, allocator: std.mem.Allocator, path: []const u8, now: i64) !void {
        var disk: [max_states]DiskEntry = undefined;
        lock(&self.mutex);
        defer self.mutex.unlock();
        const used = compact(&self.entries, &disk);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try std.json.Stringify.value(File{ .revision = self.revision, .saved_at = now, .states = used }, .{ .whitespace = .indent_2 }, &output.writer);
        try output.writer.writeByte('\n');
        try dhcp_store.atomicWrite(io, path, output.written());
    }

    pub fn find(self: *const Store, node_id: []const u8, now: i64) ?Entry {
        _ = now;
        const mutable = @constCast(self);
        lock(&mutable.mutex);
        defer mutable.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used and std.mem.eql(u8, entry.node(), node_id)) {
            return entry.*;
        };
        return null;
    }

    /// Whether at least one arm is currently eligible to admit an unknown PXE
    /// client. Expired pending entries are treated as inactive without
    /// mutating the checkpoint; the next management read/start persists the
    /// terminal projection.
    pub fn hasPending(self: *const Store, now: i64) bool {
        const mutable = @constCast(self);
        lock(&mutable.mutex);
        defer mutable.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used and entry.state == .pending and entry.expires_at > now) return true;
        return false;
    }

    pub fn findPendingSerial(self: *const Store, serial: []const u8, now: i64) ?Entry {
        var hash: [64]u8 = undefined;
        serialHash(serial, &hash) catch return null;
        const mutable = @constCast(self);
        lock(&mutable.mutex);
        defer mutable.mutex.unlock();
        var found: ?Entry = null;
        for (&self.entries) |*entry| {
            if (!entry.used or entry.state != .pending or entry.expires_at <= now) continue;
            if (!std.mem.eql(u8, entry.expected_serial_sha256[0..], hash[0..])) continue;
            if (found != null) return null; // duplicate pending SN is ambiguous
            found = entry.*;
        }
        return found;
    }

    /// Locate a completed match for a bounded, idempotent facts replay. The
    /// body digest is stored so a replay with changed optional facts cannot be
    /// mistaken for the original terminal probe.
    pub fn findMatchedFacts(self: *const Store, session_id: []const u8, facts_sha256: []const u8, now: i64) ?Entry {
        if (session_id.len == 0 or facts_sha256.len != 64) return null;
        const mutable = @constCast(self);
        lock(&mutable.mutex);
        defer mutable.mutex.unlock();
        for (&self.entries) |*entry| {
            if (!entry.used or entry.state != .matched or entry.expires_at <= now) continue;
            if (entry.session()) |session| if (std.mem.eql(u8, session, session_id) and
                std.mem.eql(u8, entry.matched_facts_sha256[0..entry.matched_facts_sha256_len], facts_sha256)) return entry.*;
        }
        return null;
    }

    pub fn markMatched(self: *Store, io: std.Io, allocator: std.mem.Allocator, path: []const u8, node_id: []const u8, session_id: []const u8, mac: []const u8, arch: model.Arch, facts_sha256: []const u8, now: i64) !Entry {
        if (node_id.len == 0 or node_id.len > node_id_cap or session_id.len > session_cap or mac.len != 17 or facts_sha256.len != 64) return error.InvalidDiscoveryMatch;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used and std.mem.eql(u8, entry.node(), node_id)) {
            if (entry.state != .pending or entry.expires_at <= now) return error.DiscoveryNotPending;
            @memcpy(entry.matched_probe_session_id[0..session_id.len], session_id);
            entry.matched_probe_session_len = @intCast(session_id.len);
            @memcpy(entry.matched_facts_sha256[0..facts_sha256.len], facts_sha256);
            entry.matched_facts_sha256_len = @intCast(facts_sha256.len);
            @memcpy(entry.observed_mac[0..mac.len], mac);
            entry.observed_mac_len = @intCast(mac.len);
            entry.observed_arch = arch;
            entry.state = .matched;
            self.revision += 1;
            try saveLocked(self, io, allocator, path, now);
            return entry.*;
        };
        return error.DiscoveryNotFound;
    }

    pub const Start = struct { entry: Entry, reused: bool };
    pub fn start(self: *Store, io: std.Io, allocator: std.mem.Allocator, path: []const u8, node_id: []const u8, node_revision: u64, serial: []const u8, expires_in: i64, now: i64, allow_restart: bool) !Start {
        if (node_id.len == 0 or node_id.len > node_id_cap or serial.len == 0 or serial.len > serial_cap or expires_in <= 0 or expires_in > 7 * 24 * 60 * 60) return error.InvalidNodeDiscoveryRequest;
        var hash: [64]u8 = undefined;
        try serialHash(serial, &hash);
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used and std.mem.eql(u8, entry.node(), node_id)) {
            if (entry.state == .pending and entry.expires_at <= now) entry.state = .expired;
            if (entry.state == .pending and entry.node_revision == node_revision and std.mem.eql(u8, entry.expected_serial_sha256[0..], hash[0..])) return .{ .entry = entry.*, .reused = true };
            if (entry.state == .pending) return error.DiscoveryAlreadyPending;
            if (!allow_restart) return error.DiscoveryTerminalRequiresRestart;
            entry.* = .{};
            break;
        };
        var target: ?*Entry = null;
        for (&self.entries) |*entry| if (!entry.used) {
            target = entry;
            break;
        };
        const entry = target orelse return error.NodeDiscoveryCapacityExhausted;
        entry.* = .{ .used = true, .node_revision = node_revision, .created_at = now, .expires_at = now + expires_in };
        @memcpy(entry.node_id[0..node_id.len], node_id);
        entry.node_id_len = @intCast(node_id.len);
        @memcpy(&entry.expected_serial_sha256, &hash);
        @memcpy(entry.serial_display[0..serial.len], serial);
        entry.serial_len = @intCast(serial.len);
        self.revision += 1;
        const result = entry.*;
        // Keep the state file update in the same critical section as the state transition.
        var disk: [max_states]DiskEntry = undefined;
        const used = compact(&self.entries, &disk);
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try std.json.Stringify.value(File{ .revision = self.revision, .saved_at = now, .states = used }, .{ .whitespace = .indent_2 }, &output.writer);
        try output.writer.writeByte('\n');
        try dhcp_store.atomicWrite(io, path, output.written());
        return .{ .entry = result, .reused = false };
    }

    pub fn cancel(self: *Store, io: std.Io, allocator: std.mem.Allocator, path: []const u8, node_id: []const u8, now: i64) !Entry {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used and std.mem.eql(u8, entry.node(), node_id)) {
            if (entry.state == .pending) entry.state = .cancelled;
            self.revision += 1;
            try saveLocked(self, io, allocator, path, now);
            return entry.*;
        };
        return error.DiscoveryNotFound;
    }

    /// Node 删除是 catalog 的业务删除边界；不保留同名节点未来可误用的旧 arm。
    pub fn remove(self: *Store, io: std.Io, allocator: std.mem.Allocator, path: []const u8, node_id: []const u8, now: i64) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used and std.mem.eql(u8, entry.node(), node_id)) {
            entry.* = .{};
            self.revision += 1;
            try saveLocked(self, io, allocator, path, now);
            return;
        };
    }
};

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

fn saveLocked(self: *Store, io: std.Io, allocator: std.mem.Allocator, path: []const u8, now: i64) !void {
    var disk: [max_states]DiskEntry = undefined;
    const used = compact(&self.entries, &disk);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(File{ .revision = self.revision, .saved_at = now, .states = used }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try dhcp_store.atomicWrite(io, path, output.written());
}

fn compact(entries: *const [max_states]Entry, output: *[max_states]DiskEntry) []const DiskEntry {
    var count: usize = 0;
    for (entries) |*entry| if (entry.used) {
        output[count] = .{ .node_id = entry.node(), .node_revision = entry.node_revision, .expected_serial_sha256 = entry.expected_serial_sha256[0..], .serial_display = entry.serial(), .created_at = entry.created_at, .expires_at = entry.expires_at, .state = entry.state, .matched_probe_session_id = entry.session(), .matched_facts_sha256 = if (entry.matched_facts_sha256_len == 0) null else entry.matched_facts_sha256[0..entry.matched_facts_sha256_len], .observed_mac = entry.mac(), .observed_arch = entry.observed_arch, .last_error = entry.errorMessage() };
        count += 1;
    };
    return output[0..count];
}

fn validDisk(value: DiskEntry) bool {
    return value.node_id.len > 0 and value.node_id.len <= node_id_cap and value.node_revision > 0 and value.expected_serial_sha256.len == 64 and value.serial_display.len > 0 and value.serial_display.len <= serial_cap and value.created_at > 0 and value.expires_at > value.created_at and (value.matched_facts_sha256 == null or value.matched_facts_sha256.?.len == 64) and (value.observed_mac == null or value.observed_mac.?.len == 17) and (value.last_error == null or value.last_error.?.len <= error_cap);
}

fn fromDisk(value: DiskEntry) !Entry {
    var result: Entry = .{ .used = true, .node_revision = value.node_revision, .created_at = value.created_at, .expires_at = value.expires_at, .state = value.state };
    @memcpy(result.node_id[0..value.node_id.len], value.node_id);
    result.node_id_len = @intCast(value.node_id.len);
    @memcpy(&result.expected_serial_sha256, value.expected_serial_sha256);
    @memcpy(result.serial_display[0..value.serial_display.len], value.serial_display);
    result.serial_len = @intCast(value.serial_display.len);
    if (value.matched_probe_session_id) |session| {
        if (session.len > session_cap) return error.InvalidNodeDiscoveryState;
        @memcpy(result.matched_probe_session_id[0..session.len], session);
        result.matched_probe_session_len = @intCast(session.len);
    }
    if (value.matched_facts_sha256) |facts| {
        if (facts.len != 64) return error.InvalidNodeDiscoveryState;
        @memcpy(&result.matched_facts_sha256, facts);
        result.matched_facts_sha256_len = @intCast(facts.len);
    }
    if (value.observed_mac) |mac| {
        @memcpy(result.observed_mac[0..mac.len], mac);
        result.observed_mac_len = @intCast(mac.len);
    }
    result.observed_arch = value.observed_arch;
    if (value.last_error) |message| {
        @memcpy(result.last_error[0..message.len], message);
        result.last_error_len = @intCast(message.len);
    }
    return result;
}

fn findIn(entries: []const Entry, node_id: []const u8) ?usize {
    for (entries, 0..) |entry, index| if (entry.used and std.mem.eql(u8, entry.node(), node_id)) return index;
    return null;
}

fn serialHash(serial: []const u8, output: *[64]u8) !void {
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (std.mem.trim(u8, serial, " \t\r\n\x00")) |byte| hasher.update(&.{std.ascii.toUpper(byte)});
    hasher.final(&digest);
    _ = std.fmt.bufPrint(output, "{x}", .{digest}) catch return error.InvalidNodeDiscoveryRequest;
}

test "node discovery state is idempotent and expires" {
    var store: Store = .{};
    const first = try store.start(std.testing.io, std.testing.allocator, "/tmp/nodeforge-discovery-test.json", "node-a", 2, "ABC-001", 30, 100, false);
    try std.testing.expect(!first.reused);
    const same = try store.start(std.testing.io, std.testing.allocator, "/tmp/nodeforge-discovery-test.json", "node-a", 2, "ABC-001", 30, 101, false);
    try std.testing.expect(same.reused);
    try std.testing.expectEqual(State.pending, store.find("node-a", 129).?.state);
}
