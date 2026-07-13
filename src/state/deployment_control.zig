//! M4.1 durable install-generation control.
//!
//! It deliberately tracks destructive install intent separately from observed
//! node status.  A profile binding alone never authorizes a repeat PXE install.

const std = @import("std");
const dhcp_store = @import("dhcp_store.zig");
const model = @import("../model.zig");

pub const max_entries = 256;

pub const RequestSource = enum { initial, operator, policy_always };

pub const Entry = struct {
    node_id: [96]u8 = [_]u8{0} ** 96,
    node_id_len: u8 = 0,
    next_generation: u64 = 1,
    armed_generation: ?u64 = null,
    consumed_generation: ?u64 = null,
    terminal_generation: ?u64 = null,
    /// Immutable config revision captured when the currently armed generation
    /// was requested. A changed desired plan must be explicitly rearmed.
    requested_revision: u64 = 0,
    /// Revision that entered the destructive installer phase.
    consumed_revision: u64 = 0,
    /// Revision reported as successfully installed by installer completion.
    applied_revision: u64 = 0,
    requested_at: i64 = 0,
    requested_by: RequestSource = .initial,

    pub fn node(self: *const Entry) []const u8 {
        return self.node_id[0..self.node_id_len];
    }
    pub fn used(self: *const Entry) bool {
        return self.node_id_len != 0;
    }
};

/// On-disk state deliberately uses variable length node IDs.  `Entry` keeps a
/// fixed buffer for allocation-free runtime access, but serialising that
/// buffer leaked 96 NUL-padded bytes for every record (and formerly for every
/// unused slot).
pub const DiskEntry = struct {
    node_id: []const u8,
    node_id_len: u8 = 0,
    next_generation: u64 = 1,
    armed_generation: ?u64 = null,
    consumed_generation: ?u64 = null,
    terminal_generation: ?u64 = null,
    requested_revision: u64 = 0,
    consumed_revision: u64 = 0,
    applied_revision: u64 = 0,
    requested_at: i64 = 0,
    requested_by: RequestSource = .initial,
};

pub const File = struct { schema_version: u32 = 1, entries: []const DiskEntry = &.{} };

pub const RearmResult = struct {
    generation: u64,
    changed: bool,
    replaced: bool = false,
    previous_armed_generation: ?u64 = null,
    previous_next_generation: u64 = 1,
    previous_requested_revision: u64 = 0,
    previous_requested_at: i64 = 0,
    previous_requested_by: RequestSource = .initial,
};

pub const ConsumeResult = struct {
    generation: u64,
    previous_consumed_generation: ?u64,
    previous_consumed_revision: u64,
};

pub const TerminalResult = struct {
    generation: u64,
    previous_terminal_generation: ?u64,
    previous_applied_revision: u64,
};

pub const View = struct {
    next_generation: u64,
    armed_generation: ?u64,
    consumed_generation: ?u64,
    terminal_generation: ?u64,
    requested_revision: u64,
    applied_revision: u64,
    requested_at: i64,
    requested_by: RequestSource,
};

pub const Store = struct {
    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,
    mutex: std.atomic.Mutex = .unlocked,

    /// First observation arms generation 1. Existing entries are never
    /// automatically rearmed by a config reload.
    pub fn ensureInitial(self: *Store, node_id: []const u8, revision: u64, requested_at: i64) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        const entry = try self.findOrCreateLocked(node_id);
        if (entry.armed_generation == null and entry.consumed_generation == null) {
            entry.armed_generation = entry.next_generation;
            entry.next_generation += 1;
            entry.requested_revision = revision;
            entry.requested_at = requested_at;
            entry.requested_by = .initial;
        }
    }

    pub fn isArmed(self: *Store, node_id: []const u8) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id)) return entry.armed_generation != null;
        return false;
    }

    /// A pending generation must still refer to the exact desired snapshot
    /// accepted by the operator. This prevents a config reload from silently
    /// changing the destructive plan between `install retry` and PXE.
    pub fn isArmedForRevision(self: *Store, node_id: []const u8, revision: u64) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id))
            return entry.armed_generation != null and entry.requested_revision == revision;
        return false;
    }

    /// `install.started` consumes exactly the currently armed generation.
    pub fn consume(self: *Store, node_id: []const u8) !?ConsumeResult {
        lock(&self.mutex);
        defer self.mutex.unlock();
        const entry = try self.findOrCreateLocked(node_id);
        const generation = entry.armed_generation orelse return null;
        const result = ConsumeResult{
            .generation = generation,
            .previous_consumed_generation = entry.consumed_generation,
            .previous_consumed_revision = entry.consumed_revision,
        };
        entry.consumed_generation = generation;
        entry.consumed_revision = entry.requested_revision;
        entry.armed_generation = null;
        return result;
    }

    /// Idempotently arm the next destructive generation. The caller checks
    /// profile/session constraints before invoking this state mutation.
    pub fn rearm(self: *Store, node_id: []const u8, revision: u64, requested_at: i64, requested_by: RequestSource) !RearmResult {
        lock(&self.mutex);
        defer self.mutex.unlock();
        const entry = try self.findOrCreateLocked(node_id);
        if (entry.armed_generation) |generation| {
            if (entry.requested_revision == revision) return .{ .generation = generation, .changed = false };
            const previous = RearmResult{
                .generation = entry.next_generation,
                .changed = true,
                .replaced = true,
                .previous_armed_generation = generation,
                .previous_next_generation = entry.next_generation,
                .previous_requested_revision = entry.requested_revision,
                .previous_requested_at = entry.requested_at,
                .previous_requested_by = entry.requested_by,
            };
            entry.armed_generation = entry.next_generation;
            entry.next_generation += 1;
            entry.requested_revision = revision;
            entry.requested_at = requested_at;
            entry.requested_by = requested_by;
            return previous;
        }
        const generation = entry.next_generation;
        const previous_next = entry.next_generation;
        entry.next_generation += 1;
        entry.armed_generation = generation;
        entry.requested_revision = revision;
        entry.requested_at = requested_at;
        entry.requested_by = requested_by;
        return .{ .generation = generation, .changed = true, .previous_next_generation = previous_next, .previous_requested_revision = entry.consumed_revision };
    }

    pub fn rollbackConsume(self: *Store, node_id: []const u8, result: ConsumeResult) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id) and entry.consumed_generation != null and entry.consumed_generation.? == result.generation and entry.armed_generation == null) {
            entry.consumed_generation = result.previous_consumed_generation;
            entry.consumed_revision = result.previous_consumed_revision;
            entry.armed_generation = result.generation;
            return;
        };
    }

    /// Roll back an in-memory retry arm when the atomic state write fails.
    /// The operation is intentionally narrow: an already-pending generation
    /// was not created by this call and must never be removed.
    pub fn rollbackRearm(self: *Store, node_id: []const u8, result: RearmResult) void {
        if (!result.changed) return;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id) and entry.armed_generation != null and entry.armed_generation.? == result.generation) {
            entry.armed_generation = result.previous_armed_generation;
            entry.next_generation = result.previous_next_generation;
            entry.requested_revision = result.previous_requested_revision;
            entry.requested_at = result.previous_requested_at;
            entry.requested_by = result.previous_requested_by;
            return;
        };
    }

    pub fn canAutoRearm(self: *Store, node_id: []const u8) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id))
            return entry.armed_generation == null and entry.consumed_generation != null and entry.terminal_generation == entry.consumed_generation;
        return false;
    }

    /// Completion is the only point that advances the applied desired state.
    /// Failed attempts retain their consumed history and are never auto-rearmed.
    pub fn markTerminal(self: *Store, node_id: []const u8, applied: bool) ?TerminalResult {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id)) {
            if (entry.consumed_generation) |generation| {
                const result = TerminalResult{
                    .generation = generation,
                    .previous_terminal_generation = entry.terminal_generation,
                    .previous_applied_revision = entry.applied_revision,
                };
                entry.terminal_generation = generation;
                if (applied) entry.applied_revision = entry.consumed_revision;
                return result;
            }
            return null;
        };
        return null;
    }

    pub fn rollbackTerminal(self: *Store, node_id: []const u8, result: TerminalResult) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id) and entry.terminal_generation != null and entry.terminal_generation.? == result.generation) {
            entry.terminal_generation = result.previous_terminal_generation;
            entry.applied_revision = result.previous_applied_revision;
            return;
        };
    }

    pub fn isDrifted(self: *Store, node_id: []const u8, revision: u64) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id))
            return entry.applied_revision != 0 and entry.applied_revision != revision;
        return false;
    }

    pub fn view(self: *Store, node_id: []const u8) ?View {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id)) return .{
            .next_generation = entry.next_generation,
            .armed_generation = entry.armed_generation,
            .consumed_generation = entry.consumed_generation,
            .terminal_generation = entry.terminal_generation,
            .requested_revision = entry.requested_revision,
            .applied_revision = entry.applied_revision,
            .requested_at = entry.requested_at,
            .requested_by = entry.requested_by,
        };
        return null;
    }

    pub fn snapshot(self: *Store, out: *[max_entries]Entry) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        out.* = self.entries;
    }

    fn findOrCreateLocked(self: *Store, node_id: []const u8) !*Entry {
        if (node_id.len == 0 or node_id.len > 96) return error.InvalidNodeId;
        var free: ?*Entry = null;
        for (&self.entries) |*entry| {
            if (entry.used() and std.mem.eql(u8, entry.node(), node_id)) return entry;
            if (!entry.used() and free == null) free = entry;
        }
        const entry = free orelse return error.DeploymentControlCapacity;
        @memcpy(entry.node_id[0..node_id.len], node_id);
        entry.node_id_len = @intCast(node_id.len);
        return entry;
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *Store) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(File, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value.schema_version != 1 or parsed.value.entries.len > max_entries) return error.InvalidDeploymentControl;
    lock(&store.mutex);
    defer store.mutex.unlock();
    store.entries = [_]Entry{.{}} ** max_entries;
    var count: usize = 0;
    for (parsed.value.entries) |disk_entry| {
        // Version-1 fixed-array files contain 256 records.  An empty record
        // has a 96-byte NUL string, so its string length is not its node ID
        // length; `node_id_len` is the authoritative discriminator for both
        // the legacy and compact encodings.
        const node_len: usize = disk_entry.node_id_len;
        if (node_len == 0) continue;
        if (node_len > 96 or node_len > disk_entry.node_id.len or count == max_entries or !validNodeId(disk_entry.node_id[0..node_len])) return error.InvalidDeploymentControl;
        for (store.entries[0..count]) |existing| if (std.mem.eql(u8, existing.node(), disk_entry.node_id[0..node_len])) return error.InvalidDeploymentControl;
        if (!validGenerations(disk_entry)) return error.InvalidDeploymentControl;
        const entry = &store.entries[count];
        @memcpy(entry.node_id[0..node_len], disk_entry.node_id[0..node_len]);
        entry.node_id_len = @intCast(node_len);
        entry.next_generation = disk_entry.next_generation;
        entry.armed_generation = disk_entry.armed_generation;
        entry.consumed_generation = disk_entry.consumed_generation;
        entry.terminal_generation = disk_entry.terminal_generation;
        entry.requested_revision = disk_entry.requested_revision;
        entry.consumed_revision = disk_entry.consumed_revision;
        entry.applied_revision = disk_entry.applied_revision;
        entry.requested_at = disk_entry.requested_at;
        entry.requested_by = disk_entry.requested_by;
        count += 1;
    }
}

fn validGenerations(entry: DiskEntry) bool {
    if (entry.next_generation == 0) return false;
    if (entry.armed_generation) |generation| if (generation == 0 or generation >= entry.next_generation) return false;
    if (entry.consumed_generation) |generation| if (generation == 0 or generation >= entry.next_generation) return false;
    if (entry.terminal_generation) |generation| {
        if (entry.consumed_generation == null or generation != entry.consumed_generation.?) return false;
    }
    return true;
}

fn validNodeId(value: []const u8) bool {
    if (value.len == 0 or value.len > 96) return false;
    for (value) |byte| if (!((byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '_')) return false;
    return true;
}

/// Computes a stable, non-secret revision for a validated config snapshot.
/// It is stored only as an opaque u64; no password, key, or serialized config
/// is emitted to logs/events/state by this helper.
pub fn revisionForConfig(allocator: std.mem.Allocator, config: *const model.AppConfig) !u64 {
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    try std.json.Stringify.value(config.*, .{}, &json.writer);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json.written(), &digest, .{});
    const value = std.mem.readInt(u64, digest[0..8], .big);
    return if (value == 0) 1 else value;
}

pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *Store) !void {
    var entries: [max_entries]Entry = undefined;
    store.snapshot(&entries);
    var used: [max_entries]DiskEntry = undefined;
    var used_len: usize = 0;
    // Take pointers: a by-value `for (entries) |entry|` loop would leave the
    // serialized slice pointing at the loop temporary, which is overwritten
    // by later iterations and corrupts node IDs on disk.
    for (&entries) |*entry| {
        if (!entry.used()) continue;
        used[used_len] = .{
            .node_id = entry.node(),
            .node_id_len = entry.node_id_len,
            .next_generation = entry.next_generation,
            .armed_generation = entry.armed_generation,
            .consumed_generation = entry.consumed_generation,
            .terminal_generation = entry.terminal_generation,
            .requested_revision = entry.requested_revision,
            .consumed_revision = entry.consumed_revision,
            .applied_revision = entry.applied_revision,
            .requested_at = entry.requested_at,
            .requested_by = entry.requested_by,
        };
        used_len += 1;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(File{ .entries = used[0..used_len] }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try dhcp_store.atomicWrite(io, path, output.written());
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

test "generation consumes once and retry is idempotent" {
    var store: Store = .{};
    try store.ensureInitial("node-01", 1, 10);
    try std.testing.expect(store.isArmed("node-01"));
    const consumed = (try store.consume("node-01")).?;
    try std.testing.expectEqual(@as(u64, 1), consumed.generation);
    try std.testing.expect(!store.isArmed("node-01"));
    const first_retry = try store.rearm("node-01", 2, 20, .operator);
    try std.testing.expectEqual(@as(u64, 2), first_retry.generation);
    try std.testing.expect(first_retry.changed);
    const repeated_retry = try store.rearm("node-01", 2, 21, .operator);
    try std.testing.expectEqual(@as(u64, 2), repeated_retry.generation);
    try std.testing.expect(!repeated_retry.changed);
}

test "retry replaces stale pending revision" {
    var store: Store = .{};
    try store.ensureInitial("node-01", 1, 10);
    const result = try store.rearm("node-01", 2, 20, .operator);
    try std.testing.expect(result.changed);
    try std.testing.expect(result.replaced);
    try std.testing.expectEqual(@as(u64, 2), result.generation);
    try std.testing.expect(store.isArmedForRevision("node-01", 2));
}

test "failed persistence rollback restores stale pending generation" {
    var store: Store = .{};
    try store.ensureInitial("node-01", 1, 10);
    const result = try store.rearm("node-01", 2, 20, .operator);
    store.rollbackRearm("node-01", result);
    try std.testing.expect(store.isArmedForRevision("node-01", 1));
    try std.testing.expect(!store.isArmedForRevision("node-01", 2));
}

test "always policy can rearm only after a terminal consumed generation" {
    var store: Store = .{};
    try store.ensureInitial("node-01", 1, 10);
    _ = try store.consume("node-01");
    try std.testing.expect(!store.canAutoRearm("node-01"));
    _ = store.markTerminal("node-01", false);
    try std.testing.expect(store.canAutoRearm("node-01"));
    _ = try store.rearm("node-01", 1, 20, .policy_always);
    try std.testing.expect(!store.canAutoRearm("node-01"));
}

test "deployment state rejects impossible generation ordering" {
    try std.testing.expect(!validGenerations(.{ .node_id = "node-01", .node_id_len = 7, .next_generation = 2, .armed_generation = 2 }));
    try std.testing.expect(!validGenerations(.{ .node_id = "node-01", .node_id_len = 7, .next_generation = 2, .consumed_generation = 1, .terminal_generation = 2 }));
}

test "completion records applied revision without arming another install" {
    var store: Store = .{};
    try store.ensureInitial("node-01", 11, 10);
    _ = try store.consume("node-01");
    _ = store.markTerminal("node-01", true);
    try std.testing.expect(!store.isArmed("node-01"));
    try std.testing.expect(!store.isDrifted("node-01", 11));
    try std.testing.expect(store.isDrifted("node-01", 12));
}

test "compact deployment state preserves node id bytes" {
    const source = "{\"schema_version\":1,\"entries\":[{\"node_id\":\"node-01\",\"node_id_len\":7}]}";
    const parsed = try std.json.parseFromSlice(File, std.testing.allocator, source, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("node-01", parsed.value.entries[0].node_id);
    var store: Store = .{};
    // Exercise exactly the fixed-buffer copy used by `load` without a file.
    const disk = parsed.value.entries[0];
    @memcpy(store.entries[0].node_id[0..disk.node_id_len], disk.node_id[0..disk.node_id_len]);
    store.entries[0].node_id_len = disk.node_id_len;
    try std.testing.expectEqualStrings("node-01", store.entries[0].node());
}
