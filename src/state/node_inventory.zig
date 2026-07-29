const std = @import("std");
const dhcp_store = @import("dhcp_store.zig");
const capacity_policy = @import("capacity.zig");

/// M4.8: inventory 内存天花板；生效容量由 `Store.capacity` 在启动时按
/// `max(受管节点数, config)` 派生（`min(派生, max_entries)`）。
pub const max_entries = capacity_policy.store_ceiling;
/// 已认证硬件 facts 用于启动前容量证明的最长有效期。物理内存通常稳定，但
/// 更换 DIMM/主板后必须在 30 天内重新启动并上报；过期值保留审计、不参与闸门。
pub const memory_freshness_seconds: i64 = 30 * 24 * 60 * 60;

/// 安装器上报的硬件事实集合。全部为可选字段；未上报的字段为 null。
/// 这些事实用于审计与漂移检测，不直接参与安装授权。
pub const Facts = struct {
    serial_number: ?[]const u8 = null,
    product_uuid: ?[]const u8 = null,
    vendor: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// `/proc/meminfo` 的 MemTotal，单位为 bytes；null 表示来源未提供。
    memory_bytes: ?u64 = null,
};

/// 磁盘上一条 inventory 记录的 JSON 投影。字符串借用自解析后的 JSON 缓冲区。
/// `digest` 是 `digestFacts` 计算的 SHA-256，用于快速判断 facts 是否变化。
pub const DiskEntry = struct { node_id: []const u8, serial_number: ?[]const u8 = null, product_uuid: ?[]const u8 = null, vendor: ?[]const u8 = null, model: ?[]const u8 = null, memory_bytes: ?u64 = null, reported_at: i64, deployment_generation: u64, session_created_at: i64 = 0, boot_session_id: []const u8, digest: [32]u8 };
pub const File = struct { schema_version: u32 = 2, revision: u64 = 0, entries: []const DiskEntry = &.{} };
const FileHeader = struct { schema_version: u32 };
const LegacyDiskEntryV1 = struct { node_id: []const u8, serial_number: ?[]const u8 = null, product_uuid: ?[]const u8 = null, vendor: ?[]const u8 = null, model: ?[]const u8 = null, reported_at: i64, deployment_generation: u64, session_created_at: i64 = 0, boot_session_id: []const u8, digest: [32]u8 };
const LegacyFileV1 = struct { schema_version: u32, revision: u64 = 0, entries: []const LegacyDiskEntryV1 = &.{} };

pub const MemoryObservation = struct {
    bytes: ?u64,
    reported_at: i64,
    fresh: bool,
};

/// 进程内 inventory 存储。使用动态数组而非固定数组，因为 inventory 记录
/// 的字符串字段需要堆分配（不像 deployment_control 的固定 node_id 缓冲区）。
/// `mutex` 保护所有读写；`revision` 单调递增，供 checkpoint 判断是否需要持久化。
pub const Store = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(DiskEntry) = .empty,
    /// M4.8: 生效 inventory 容量，启动时按受管节点数派生收敛。
    capacity: usize = max_entries,
    revision: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,

    /// 初始化空 store。调用方随后应调用 `setCapacity` 按受管节点数收敛。
    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }
    /// 释放所有堆分配的字符串和 entries 数组。
    pub fn deinit(self: *Store) void {
        for (self.entries.items) |*entry| freeEntry(self.allocator, entry);
        self.entries.deinit(self.allocator);
    }

    /// M4.8: 按 `max(受管节点数, config)` 派生并 clamp 到 `[1, max_entries]`。
    pub fn setCapacity(self: *Store, derived: usize) void {
        self.capacity = @max(self.entries.items.len, @max(@as(usize, 1), @min(derived, max_entries)));
    }

    /// 在线 node add 只能扩大启动时派生容量，不能意外缩小显式 override。
    pub fn growCapacity(self: *Store, minimum: usize) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.capacity = @max(self.capacity, @min(minimum, max_entries));
    }

    /// 写入或更新一个节点的硬件 facts。返回 `true` 表示 facts 发生变化并
    /// 已更新；`false` 表示 facts 与现有记录相同（幂等重报）。返回
    /// `StaleSource` 表示请求来自较旧的 generation/session，拒绝覆盖更新。
    /// 返回 `InventoryCapacityExhausted` 表示已达容量上限。
    pub fn put(self: *Store, node_id: []const u8, session_id: []const u8, generation: u64, session_created_at: i64, facts: Facts, reported_at: i64) !bool {
        try validateFacts(facts);
        const digest = digestFacts(facts);
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.node_id, node_id)) {
            if (generation < entry.deployment_generation or (generation == entry.deployment_generation and session_created_at < entry.session_created_at) or (generation == entry.deployment_generation and session_created_at == entry.session_created_at and !std.mem.eql(u8, entry.boot_session_id, session_id))) return error.StaleSource;
            const same_source = generation == entry.deployment_generation and session_created_at == entry.session_created_at and std.mem.eql(u8, entry.boot_session_id, session_id);
            if (same_source and std.crypto.timing_safe.eql([32]u8, digest, entry.digest)) return false;
            const replacement = try ownedEntry(self.allocator, node_id, session_id, generation, session_created_at, facts, reported_at, digest);
            freeEntry(self.allocator, entry);
            entry.* = replacement;
            self.revision += 1;
            return true;
        };
        if (self.entries.items.len >= self.capacity) return error.InventoryCapacityExhausted;
        try self.entries.append(self.allocator, try ownedEntry(self.allocator, node_id, session_id, generation, session_created_at, facts, reported_at, digest));
        self.revision += 1;
        return true;
    }

    /// 仅刷新内存事实并保留既有 DMI 字段。diskless initrd 不应因为只负责
    /// `/proc/meminfo` 容量证明而清空先前安装环境上报的序列号/厂商信息。
    pub fn putMemory(self: *Store, node_id: []const u8, session_id: []const u8, generation: u64, session_created_at: i64, memory_bytes: u64, reported_at: i64) !bool {
        if (memory_bytes == 0) return error.InvalidFacts;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.node_id, node_id)) {
            // install generation 与 diskless delivery 没有可比较的编号域。memory-only
            // 更新以服务端签发的 session 创建时间排序，同时保留较大的 install
            // generation 供完整 installer facts 的旧 session 防回退判断。
            if (session_created_at < entry.session_created_at or (session_created_at == entry.session_created_at and !std.mem.eql(u8, entry.boot_session_id, session_id))) return error.StaleSource;
            const facts: Facts = .{ .serial_number = entry.serial_number, .product_uuid = entry.product_uuid, .vendor = entry.vendor, .model = entry.model, .memory_bytes = memory_bytes };
            const digest = digestFacts(facts);
            const same_source = session_created_at == entry.session_created_at and std.mem.eql(u8, entry.boot_session_id, session_id);
            if (same_source and std.crypto.timing_safe.eql([32]u8, digest, entry.digest)) return false;
            const replacement = try ownedEntry(self.allocator, node_id, session_id, @max(generation, entry.deployment_generation), session_created_at, facts, reported_at, digest);
            freeEntry(self.allocator, entry);
            entry.* = replacement;
            self.revision += 1;
            return true;
        };
        if (self.entries.items.len >= self.capacity) return error.InventoryCapacityExhausted;
        const facts: Facts = .{ .memory_bytes = memory_bytes };
        try self.entries.append(self.allocator, try ownedEntry(self.allocator, node_id, session_id, generation, session_created_at, facts, reported_at, digestFacts(facts)));
        self.revision += 1;
        return true;
    }

    /// 读取一个节点的当前 inventory 记录。未找到返回 null。
    pub fn get(self: *Store, node_id: []const u8) ?DiskEntry {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.node_id, node_id)) return entry;
        return null;
    }
    /// 深拷贝一条记录供并发 HTTP reader 使用；调用方必须 `freeOwned`。
    pub fn getOwned(self: *Store, allocator: std.mem.Allocator, node_id: []const u8) !?DiskEntry {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.node_id, node_id)) {
            const facts: Facts = .{ .serial_number = entry.serial_number, .product_uuid = entry.product_uuid, .vendor = entry.vendor, .model = entry.model, .memory_bytes = entry.memory_bytes };
            return try ownedEntry(allocator, entry.node_id, entry.boot_session_id, entry.deployment_generation, entry.session_created_at, facts, entry.reported_at, entry.digest);
        };
        return null;
    }
    pub fn freeOwned(allocator: std.mem.Allocator, entry: *DiskEntry) void {
        freeEntry(allocator, entry);
    }
    /// 在 mutex 内复制 readiness 所需的纯值字段，避免把可释放字符串切片暴露给
    /// 并发 facts 更新。过期观测仍返回以便 API 给出 stale 而不是 missing 诊断。
    pub fn memoryObservation(self: *Store, node_id: []const u8, now: i64) ?MemoryObservation {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.node_id, node_id)) {
            const age = std.math.sub(i64, now, entry.reported_at) catch return .{ .bytes = entry.memory_bytes, .reported_at = entry.reported_at, .fresh = false };
            return .{ .bytes = entry.memory_bytes, .reported_at = entry.reported_at, .fresh = age >= 0 and age <= memory_freshness_seconds };
        };
        return null;
    }
    /// 返回当前 store revision。checkpoint worker 比较它与已保存的 revision，
    /// 决定是否需要新的持久化快照。
    pub fn currentRevision(self: *Store) u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return self.revision;
    }
};

/// 原子保存 inventory 快照到磁盘。调用方必须已通过 `snapshot` 获取一致快照。
/// 写入后 `chmod 600` 收紧文件权限，父目录 `chmod 700`。
pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *Store) !void {
    lock(&store.mutex);
    defer store.mutex.unlock();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(File{ .revision = store.revision, .entries = store.entries.items }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try dhcp_store.atomicWrite(io, path, output.written());
    if (std.fs.path.dirname(path)) |parent| try chmod(io, allocator, "700", parent);
    try chmod(io, allocator, "600", path);
}

/// 调用 `chmod` 调整文件权限。非零退出码返回 `PermissionUpdateFailed`。
fn chmod(io: std.Io, allocator: std.mem.Allocator, mode: []const u8, path: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "chmod", mode, path }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.PermissionUpdateFailed,
        else => return error.PermissionUpdateFailed,
    }
}

/// 从磁盘加载 inventory 快照。schema 2 增加 `memory_bytes`；schema 1 显式
/// 升级为 memory unknown 并重算 facts digest。加载后 capacity 至少容纳恢复条目。
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *Store) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(bytes);
    const header = std.json.parseFromSlice(FileHeader, allocator, bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidInventoryState;
    defer header.deinit();
    switch (header.value.schema_version) {
        1 => {
            const parsed = std.json.parseFromSlice(LegacyFileV1, allocator, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidInventoryState;
            defer parsed.deinit();
            if (parsed.value.entries.len > max_entries) return error.InvalidInventoryState;
            for (parsed.value.entries) |entry| {
                const facts: Facts = .{ .serial_number = entry.serial_number, .product_uuid = entry.product_uuid, .vendor = entry.vendor, .model = entry.model };
                try validateFacts(facts);
                try store.entries.append(store.allocator, try ownedEntry(store.allocator, entry.node_id, entry.boot_session_id, entry.deployment_generation, entry.session_created_at, facts, entry.reported_at, digestFacts(facts)));
            }
            store.revision = parsed.value.revision;
        },
        2 => {
            const parsed = std.json.parseFromSlice(File, allocator, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidInventoryState;
            defer parsed.deinit();
            if (parsed.value.entries.len > max_entries) return error.InvalidInventoryState;
            for (parsed.value.entries) |entry| {
                const facts: Facts = .{ .serial_number = entry.serial_number, .product_uuid = entry.product_uuid, .vendor = entry.vendor, .model = entry.model, .memory_bytes = entry.memory_bytes };
                try validateFacts(facts);
                const digest = digestFacts(facts);
                if (!std.crypto.timing_safe.eql([32]u8, digest, entry.digest)) return error.InvalidInventoryState;
                try store.entries.append(store.allocator, try ownedEntry(store.allocator, entry.node_id, entry.boot_session_id, entry.deployment_generation, entry.session_created_at, facts, entry.reported_at, digest));
            }
            store.revision = parsed.value.revision;
        },
        else => return error.InvalidInventoryState,
    }
    store.capacity = @max(store.capacity, store.entries.items.len);
}

/// 创建一个深拷贝的 DiskEntry：所有字符串字段通过 `allocator.dupe` 复制。
/// 调用方负责通过 `freeEntry` 释放。
fn ownedEntry(a: std.mem.Allocator, node: []const u8, session: []const u8, generation: u64, session_created_at: i64, facts: Facts, at: i64, digest: [32]u8) !DiskEntry {
    return .{ .node_id = try a.dupe(u8, node), .serial_number = if (facts.serial_number) |v| try a.dupe(u8, v) else null, .product_uuid = if (facts.product_uuid) |v| try a.dupe(u8, v) else null, .vendor = if (facts.vendor) |v| try a.dupe(u8, v) else null, .model = if (facts.model) |v| try a.dupe(u8, v) else null, .memory_bytes = facts.memory_bytes, .reported_at = at, .deployment_generation = generation, .session_created_at = session_created_at, .boot_session_id = try a.dupe(u8, session), .digest = digest };
}
/// 释放 DiskEntry 持有的所有堆分配字符串。
fn freeEntry(a: std.mem.Allocator, entry: *DiskEntry) void {
    a.free(entry.node_id);
    a.free(entry.boot_session_id);
    if (entry.serial_number) |value| a.free(value);
    if (entry.product_uuid) |value| a.free(value);
    if (entry.vendor) |value| a.free(value);
    if (entry.model) |value| a.free(value);
}
/// 校验 facts 的每个非 null 字段：长度 1-256，且不含控制字符。
fn validateFacts(f: Facts) !void {
    inline for (.{ f.serial_number, f.product_uuid, f.vendor, f.model }) |field| if (field) |v| {
        if (v.len == 0 or v.len > 256) return error.InvalidFacts;
        for (v) |c| if (c < 0x20 or c == 0x7f) return error.InvalidFacts;
    };
    if (f.memory_bytes) |bytes| if (bytes == 0) return error.InvalidFacts;
}
/// 计算 facts 的 SHA-256 摘要。每个字段以 NUL 分隔，使不同字段的
/// 组合产生不同的摘要（如 `"a"+"b"` 与 `"ab"+""` 不同）。
fn digestFacts(f: Facts) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (.{ f.serial_number, f.product_uuid, f.vendor, f.model }) |field| {
        if (field) |v| h.update(v);
        h.update(&.{0});
    }
    if (f.memory_bytes) |bytes| {
        var encoded: [32]u8 = undefined;
        const value = std.fmt.bufPrint(&encoded, "{d}", .{bytes}) catch unreachable;
        h.update(value);
    }
    h.update(&.{0});
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}
/// 自旋获取 mutex，通过 `Thread.yield` 让出 CPU。
fn lock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.Thread.yield() catch {};
}

test "inventory rejects a different session at the same generation" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expect(try store.put("n1", "0123456789abcdef0123456789abcdef", 1, 10, .{ .serial_number = "SN1" }, 10));
    try std.testing.expectError(error.StaleSource, store.put("n1", "abcdef0123456789abcdef0123456789", 1, 9, .{ .serial_number = "SN2" }, 11));
}

test "identical facts retry preserves timestamp and revision" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const session = "0123456789abcdef0123456789abcdef";
    try std.testing.expect(try store.put("n1", session, 2, 5, .{ .serial_number = "SN1" }, 10));
    const revision = store.currentRevision();
    try std.testing.expect(!try store.put("n1", session, 2, 5, .{ .serial_number = "SN1" }, 99));
    try std.testing.expectEqual(revision, store.currentRevision());
    try std.testing.expectEqual(@as(i64, 10), store.get("n1").?.reported_at);
}

test "newer session at the same discovery generation supersedes old facts" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expect(try store.put("n1", "0123456789abcdef0123456789abcdef", 0, 10, .{ .serial_number = "OLD" }, 10));
    try std.testing.expect(try store.put("n1", "abcdef0123456789abcdef0123456789", 0, 20, .{ .serial_number = "NEW" }, 20));
    try std.testing.expectEqualStrings("NEW", store.get("n1").?.serial_number.?);
    try std.testing.expectError(error.StaleSource, store.put("n1", "0123456789abcdef0123456789abcdef", 0, 10, .{ .serial_number = "LATE" }, 30));
}

test "schema 1 inventory upgrades with unknown memory and schema 2 round trips" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/inventory.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const legacy =
        \\{"schema_version":1,"revision":7,"entries":[{"node_id":"n1","serial_number":"SN1","reported_at":10,"deployment_generation":1,"session_created_at":9,"boot_session_id":"0123456789abcdef0123456789abcdef","digest":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]}]}
    ;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = legacy });
    var upgraded = Store.init(std.testing.allocator);
    defer upgraded.deinit();
    try load(std.testing.io, std.testing.allocator, path, &upgraded);
    try std.testing.expect(upgraded.get("n1").?.memory_bytes == null);
    try std.testing.expect(try upgraded.put("n1", "0123456789abcdef0123456789abcdef", 1, 9, .{ .serial_number = "SN1", .memory_bytes = 4096 }, 11));
    try save(std.testing.io, std.testing.allocator, path, &upgraded);
    var restored = Store.init(std.testing.allocator);
    defer restored.deinit();
    try load(std.testing.io, std.testing.allocator, path, &restored);
    try std.testing.expectEqual(@as(?u64, 4096), restored.get("n1").?.memory_bytes);
}

test "memory observation expires without deleting audit fact" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expect(try store.put("n1", "0123456789abcdef0123456789abcdef", 0, 1, .{ .memory_bytes = 1024 }, 10));
    try std.testing.expect(store.memoryObservation("n1", 10 + memory_freshness_seconds).?.fresh);
    const stale = store.memoryObservation("n1", 11 + memory_freshness_seconds).?;
    try std.testing.expect(!stale.fresh);
    try std.testing.expectEqual(@as(?u64, 1024), stale.bytes);
}

test "memory-only update preserves DMI facts" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const session = "0123456789abcdef0123456789abcdef";
    try std.testing.expect(try store.put("n1", session, 0, 1, .{ .serial_number = "SN1" }, 10));
    try std.testing.expect(try store.putMemory("n1", session, 0, 1, 8192, 11));
    const entry = store.get("n1").?;
    try std.testing.expectEqualStrings("SN1", entry.serial_number.?);
    try std.testing.expectEqual(@as(?u64, 8192), entry.memory_bytes);
}

test "new diskless memory report refreshes identical facts across install generation domain" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expect(try store.put("n1", "0123456789abcdef0123456789abcdef", 9, 10, .{ .memory_bytes = 8192 }, 10));
    try std.testing.expect(try store.putMemory("n1", "abcdef0123456789abcdef0123456789", 0, 20, 8192, 20));
    const refreshed = store.get("n1").?;
    try std.testing.expectEqual(@as(u64, 9), refreshed.deployment_generation);
    try std.testing.expectEqual(@as(i64, 20), refreshed.reported_at);
}
