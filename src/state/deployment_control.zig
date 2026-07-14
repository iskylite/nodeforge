//! M4.1 持久化 install-generation 控制。
//!
//! 有意将破坏性安装意图与观测到的节点状态分开跟踪。
//! 仅凭 profile 绑定永远不能授权重复 PXE 安装。

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
    /// 当前已武装 generation 被请求时捕获的不可变 config revision。
    /// 更改的期望计划必须显式重新武装。
    requested_revision: u64 = 0,
    /// 进入破坏性安装器阶段的 revision。
    consumed_revision: u64 = 0,
    /// 安装器完成时报告为成功安装的 revision。
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

/// 磁盘状态有意使用变长 node ID。`Entry` 保留固定缓冲区以实现无分配运行时访问，
/// 但序列化该缓冲区会为每条记录泄漏 96 字节的 NUL 填充（此前甚至包括每个
/// 空闲槽位）。
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

    /// 首次观测武装 generation 1。已有条目永远不会
    /// 被 config 重载自动重新武装。
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

    /// 待执行 generation 必须仍指向操作员已确认的精确快照。这防止
    /// 配置重载在 `install retry` 与 PXE 之间静默改变破坏性部署计划。
    pub fn isArmedForRevision(self: *Store, node_id: []const u8, revision: u64) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id))
            return entry.armed_generation != null and entry.requested_revision == revision;
        return false;
    }

    /// `install.started` 精确消费当前已武装的 generation。
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

    /// 幂等地武装下一个破坏性 generation。调用方在执行此状态变更前
    /// 已检查 profile/session 约束。
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

    /// 当原子状态写入失败时回滚内存中的 retry 武装操作。
    /// 该操作有意保持窄范围：已待执行的 generation 不是本次调用创建的，
    /// 绝不能被移除。
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

    /// 完成是唯一推进已应用期望状态的节点。
    /// 失败的尝试保留其消费历史，永远不会自动重新武装。
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
        // Version-1 固定数组文件包含 256 条记录。空记录的字符串为 96 字节
        // NUL，因此其字符串长度并非 node ID 长度；`node_id_len` 是旧版和
        // 紧凑编码共用的权威判别字段。
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

/// 为已校验的配置快照计算稳定的、非密钥的 revision 值。
/// 仅以不透明 u64 存储；此辅助函数不会将密码、密钥或序列化配置
/// 写入日志/事件/状态文件。
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
    // 取指针：按值遍历 `for (entries) |entry|` 会导致序列化切片指向
    // 循环临时变量，该变量会被后续迭代覆盖，导致磁盘上的 node ID 损坏。
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
    // 精确测试 `load` 使用的固定缓冲区拷贝，无需实际文件。
    const disk = parsed.value.entries[0];
    @memcpy(store.entries[0].node_id[0..disk.node_id_len], disk.node_id[0..disk.node_id_len]);
    store.entries[0].node_id_len = disk.node_id_len;
    try std.testing.expectEqualStrings("node-01", store.entries[0].node());
}
