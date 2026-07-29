const std = @import("std");
const boot_session = @import("boot_session.zig");
const dhcp_store = @import("dhcp_store.zig");
const model_transaction = @import("model_transaction.zig");

/// 操作表最大条目数。终态条目按 `retention_seconds` 自动淘汰。
pub const max_operations = 128;
/// 终态条目的保留时间（24 小时）。超过此时间的终态条目可被新操作复用槽位。
pub const retention_seconds: i64 = 24 * 60 * 60;
/// 操作类型。长任务必须先持久化 operation，再由 worker 执行。
pub const Kind = enum { install_source_import, rootfs_build };
/// 操作状态机。
pub const State = enum { queued, running, succeeded, failed };

/// 进程内操作记录。所有文本字段使用固定缓冲区避免堆分配；`id` 是
/// 32 字符十六进制 operation id，`key` 是调用方提供的幂等键。
pub const Entry = struct {
    id: [boot_session.id_len]u8 = [_]u8{0} ** boot_session.id_len,
    key: [128]u8 = [_]u8{0} ** 128,
    key_len: u8 = 0,
    request_digest: [64]u8 = [_]u8{0} ** 64,
    request_digest_len: u8 = 0,
    kind: Kind = .install_source_import,
    state: State = .queued,
    created_at: i64 = 0,
    updated_at: i64 = 0,
    result: [128]u8 = [_]u8{0} ** 128,
    result_len: u8 = 0,
    error_code: [96]u8 = [_]u8{0} ** 96,
    error_len: u8 = 0,

    /// 条目是否被使用（id 非 0）。
    pub fn used(self: *const Entry) bool {
        return self.id[0] != 0;
    }
    pub fn idSlice(self: *const Entry) []const u8 {
        return self.id[0..];
    }
    pub fn keySlice(self: *const Entry) []const u8 {
        return self.key[0..self.key_len];
    }
    pub fn requestDigestSlice(self: *const Entry) []const u8 {
        return self.request_digest[0..self.request_digest_len];
    }
    pub fn resultSlice(self: *const Entry) []const u8 {
        return self.result[0..self.result_len];
    }
    pub fn errorSlice(self: *const Entry) []const u8 {
        return self.error_code[0..self.error_len];
    }
    /// 是否处于终态（succeeded 或 failed）。
    pub fn terminal(self: *const Entry) bool {
        return self.state == .succeeded or self.state == .failed;
    }
};

/// 磁盘上的操作记录。字符串借用自 JSON 缓冲区。
const DiskEntry = struct { id: []const u8, idempotency_key: []const u8, request_digest: ?[]const u8 = null, kind: Kind, state: State, created_at: i64, updated_at: i64, result: ?[]const u8 = null, error_code: ?[]const u8 = null };
const File = struct { schema_version: u32 = 2, entries: []const DiskEntry = &.{} };
/// `begin` / `beginRequest` 的返回值。`reused=true` 表示命中已有成功或在途操作：
/// 成功态调用方直接返回缓存 result，queued/running 则返回同一 operation 并且
/// 不得重复入队；`reused=false` 表示创建了新操作，调用方负责实际工作及终态写入。
pub const BeginResult = struct { entry: Entry, reused: bool };

/// 进程内操作存储。固定 128 槽位，mutex 保护所有读写。
/// 终态操作超过 `retention_seconds` 后可被新操作复用槽位。
pub const Store = struct {
    entries: [max_operations]Entry = [_]Entry{.{}} ** max_operations,
    mutex: std.atomic.Mutex = .unlocked,

    /// 开始一个幂等操作。key 长度 1-128。若 key 已存在且为成功或在途状态，
    /// 直接返回同一 entry；failed（包括重启恢复出的 interrupted）创建后继。
    pub fn begin(self: *Store, io: std.Io, key: []const u8, kind: Kind, now: i64) !BeginResult {
        return self.beginRequest(io, key, "", kind, now);
    }

    /// 为单个规范请求开启幂等操作。一个 key 只能
    /// 标识一个请求摘要。被中断的尝试是异常情况：
    /// 相同 key/请求创建后继，使重试可安全恢复工作。
    pub fn beginRequest(self: *Store, io: std.Io, key: []const u8, request_digest: []const u8, kind: Kind, now: i64) !BeginResult {
        return self.beginRequestWithState(io, key, request_digest, kind, .running, now);
    }

    /// 创建持久 queued operation。调用方保存快照并成功入队后，由 worker
    /// 通过 `start` 原子推进到 running。
    pub fn beginQueuedRequest(self: *Store, io: std.Io, key: []const u8, request_digest: []const u8, kind: Kind, now: i64) !BeginResult {
        return self.beginRequestWithState(io, key, request_digest, kind, .queued, now);
    }

    fn beginRequestWithState(self: *Store, io: std.Io, key: []const u8, request_digest: []const u8, kind: Kind, initial_state: State, now: i64) !BeginResult {
        if (key.len == 0 or key.len > 128) return error.InvalidIdempotencyKey;
        if (request_digest.len > 64) return error.InvalidRequestDigest;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used() and std.mem.eql(u8, entry.keySlice(), key)) {
            if (!std.mem.eql(u8, entry.requestDigestSlice(), request_digest) or entry.kind != kind) return error.IdempotencyConflict;
            // 成功与在途操作重用同一 id；失败终态允许以新 operation 重试。
            // 特别是 queued/running 不能被第二个 HTTP 请求覆盖，否则 worker
            // 完成时将找不到原 operation，且同一输入会被重复执行。
            if (entry.state != .failed)
                return .{ .entry = entry.*, .reused = true };
            entry.* = .{}; // 失败终态由其持久后继替换
            break;
        };
        var target: ?*Entry = null;
        for (&self.entries) |*entry| {
            if (!entry.used()) {
                target = entry;
                break;
            }
            if (entry.terminal() and now - entry.updated_at >= retention_seconds) {
                target = entry;
                break;
            }
        }
        const entry = target orelse return error.OperationCapacityExhausted;
        entry.* = .{ .kind = kind, .state = initial_state, .created_at = now, .updated_at = now };
        try boot_session.generateId(io, &entry.id);
        @memcpy(entry.key[0..key.len], key);
        entry.key_len = @intCast(key.len);
        @memcpy(entry.request_digest[0..request_digest.len], request_digest);
        entry.request_digest_len = @intCast(request_digest.len);
        return .{ .entry = entry.*, .reused = false };
    }

    /// queued -> running。重复 start running 是幂等；终态不可重新启动。
    pub fn start(self: *Store, id: []const u8, now: i64) !Entry {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used() and std.mem.eql(u8, entry.idSlice(), id)) {
            if (entry.state == .running) return entry.*;
            if (entry.state != .queued) return error.OperationNotStartable;
            entry.state = .running;
            entry.updated_at = now;
            return entry.*;
        };
        return error.OperationNotFound;
    }

    /// 标记操作为成功并记录 result 文本（长度 <=128）。
    pub fn succeed(self: *Store, id: []const u8, result: []const u8, now: i64) !Entry {
        return self.finish(id, .succeeded, result, now);
    }
    /// 标记操作为失败并记录 error code（长度 <=96）。
    pub fn fail(self: *Store, id: []const u8, code: []const u8, now: i64) !Entry {
        return self.finish(id, .failed, code, now);
    }
    /// 内部终态写入函数。succeeded 写入 `result`（<=128），failed 写入 `error_code`（<=96）。
    /// 两个缓冲区长度不同，按状态分别校验上限，避免静默截断。
    fn finish(self: *Store, id: []const u8, state: State, text: []const u8, now: i64) !Entry {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used() and std.mem.eql(u8, entry.idSlice(), id)) {
            // result 缓冲区 128 字节，error_code 缓冲区仅 96 字节；
            // 按状态分别校验上限，防止 97-128 范围的 error_code 被静默截断。
            const max_len = if (state == .succeeded) entry.result.len else entry.error_code.len;
            if (text.len > max_len) return error.OperationResultTooLong;
            entry.state = state;
            entry.updated_at = now;
            if (state == .succeeded) {
                @memcpy(entry.result[0..text.len], text);
                entry.result_len = @intCast(text.len);
                entry.error_len = 0;
            } else {
                @memcpy(entry.error_code[0..text.len], text);
                entry.error_len = @intCast(text.len);
                entry.result_len = 0;
            }
            return entry.*;
        };
        return error.OperationNotFound;
    }
    /// 查询操作状态。终态操作超过 `retention_seconds` 后返回 null（视为已淘汰）。
    pub fn get(self: *Store, id: []const u8, now: i64) ?Entry {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.idSlice(), id)) {
            if (entry.terminal() and now - entry.updated_at >= retention_seconds) return null;
            return entry;
        };
        return null;
    }
    /// 快照当前所有操作到 `out`。调用方用于持久化或 CLI 展示。
    pub fn snapshot(self: *Store, out: *[max_operations]Entry) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        out.* = self.entries;
    }
};

/// 原子保存操作快照到磁盘。写入后 `chmod 600` 收紧权限，父目录 `chmod 700`。
pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *Store) !void {
    var snapshot: [max_operations]Entry = undefined;
    store.snapshot(&snapshot);
    var disk: [max_operations]DiskEntry = undefined;
    var count: usize = 0;
    for (&snapshot) |*entry| if (entry.used()) {
        disk[count] = .{ .id = entry.idSlice(), .idempotency_key = entry.keySlice(), .request_digest = if (entry.request_digest_len == 0) null else entry.requestDigestSlice(), .kind = entry.kind, .state = entry.state, .created_at = entry.created_at, .updated_at = entry.updated_at, .result = if (entry.result_len == 0) null else entry.resultSlice(), .error_code = if (entry.error_len == 0) null else entry.errorSlice() };
        count += 1;
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(File{ .entries = disk[0..count] }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try dhcp_store.atomicWrite(io, path, output.written());
    if (std.fs.path.dirname(path)) |parent| try chmod(io, allocator, "700", parent);
    try chmod(io, allocator, "600", path);
}

/// 从磁盘加载操作快照。schema 2 增加 `rootfs_build` kind；schema 1 的字段布局
/// 相同且历史上仅包含 install_source_import，因此显式兼容读取。loading 时会将
/// queued/running 强制转为 failed + `operation.interrupted`，提供确定性恢复语义。
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *Store, now: i64) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(File, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if ((parsed.value.schema_version != 1 and parsed.value.schema_version != 2) or parsed.value.entries.len > max_operations) return error.InvalidOperationsState;
    for (parsed.value.entries, 0..) |disk, index| {
        if (!boot_session.validId(disk.id) or disk.idempotency_key.len == 0 or disk.idempotency_key.len > 128) return error.InvalidOperationsState;
        if ((disk.state == .queued or disk.state == .running)) {
            store.entries[index] = try fromDisk(disk);
            store.entries[index].state = .failed;
            store.entries[index].updated_at = now;
            const code = "operation.interrupted";
            @memcpy(store.entries[index].error_code[0..code.len], code);
            store.entries[index].error_len = code.len;
        } else store.entries[index] = try fromDisk(disk);
    }
}

/// 从磁盘记录重建内存 Entry。校验所有字段的长度不越界。
fn fromDisk(disk: DiskEntry) !Entry {
    var entry: Entry = .{ .kind = disk.kind, .state = disk.state, .created_at = disk.created_at, .updated_at = disk.updated_at };
    @memcpy(&entry.id, disk.id);
    @memcpy(entry.key[0..disk.idempotency_key.len], disk.idempotency_key);
    entry.key_len = @intCast(disk.idempotency_key.len);
    if (disk.request_digest) |v| {
        if (v.len > entry.request_digest.len) return error.InvalidOperationsState;
        @memcpy(entry.request_digest[0..v.len], v);
        entry.request_digest_len = @intCast(v.len);
    }
    if (disk.result) |v| {
        if (v.len > entry.result.len) return error.InvalidOperationsState;
        @memcpy(entry.result[0..v.len], v);
        entry.result_len = @intCast(v.len);
    }
    if (disk.error_code) |v| {
        if (v.len > entry.error_code.len) return error.InvalidOperationsState;
        @memcpy(entry.error_code[0..v.len], v);
        entry.error_len = @intCast(v.len);
    }
    return entry;
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
/// 自旋获取 mutex，通过 `Thread.yield` 让出 CPU。
fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

test "idempotency key reuses terminal operation" {
    var store: Store = .{};
    const first = try store.begin(std.testing.io, "key-1", .install_source_import, 1);
    _ = try store.succeed(first.entry.idSlice(), "source", 2);
    const repeated = try store.begin(std.testing.io, "key-1", .install_source_import, 3);
    try std.testing.expect(repeated.reused);
    try std.testing.expectEqual(State.succeeded, repeated.entry.state);
}

test "running operation is durably recovered as interrupted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/operations.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    var before: Store = .{};
    const begun = try before.begin(std.testing.io, "durable-key", .install_source_import, 10);
    try save(std.testing.io, std.testing.allocator, path, &before);
    var after: Store = .{};
    try load(std.testing.io, std.testing.allocator, path, &after, 20);
    const restored = after.get(begun.entry.idSlice(), 20).?;
    try std.testing.expectEqual(State.failed, restored.state);
    try std.testing.expectEqualStrings("operation.interrupted", restored.errorSlice());
}

test "queued operation starts exactly once and is interrupted on restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/queued-operations.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    var before: Store = .{};
    const begun = try before.beginQueuedRequest(std.testing.io, "rootfs-key", "digest", .rootfs_build, 10);
    try std.testing.expectEqual(State.queued, begun.entry.state);
    const running = try before.start(begun.entry.idSlice(), 11);
    try std.testing.expectEqual(State.running, running.state);
    try std.testing.expectEqual(State.running, (try before.start(begun.entry.idSlice(), 12)).state);
    try save(std.testing.io, std.testing.allocator, path, &before);
    var after: Store = .{};
    try load(std.testing.io, std.testing.allocator, path, &after, 20);
    const restored = after.get(begun.entry.idSlice(), 20).?;
    try std.testing.expectEqual(State.failed, restored.state);
    try std.testing.expectEqualStrings("operation.interrupted", restored.errorSlice());
    try std.testing.expectError(error.OperationNotStartable, after.start(begun.entry.idSlice(), 21));
}

test "same idempotency key rejects a different request" {
    var store: Store = .{};
    _ = try store.beginRequest(std.testing.io, "key", "aaaa", .install_source_import, 1);
    try std.testing.expectError(error.IdempotencyConflict, store.beginRequest(std.testing.io, "key", "bbbb", .install_source_import, 2));
}

test "duplicate queued request reuses active operation without replacement" {
    var store: Store = .{};
    const first = try store.beginQueuedRequest(std.testing.io, "rootfs-key", "digest", .rootfs_build, 1);
    const repeated = try store.beginQueuedRequest(std.testing.io, "rootfs-key", "digest", .rootfs_build, 2);
    try std.testing.expect(repeated.reused);
    try std.testing.expectEqualStrings(first.entry.idSlice(), repeated.entry.idSlice());
    try std.testing.expectEqual(State.queued, repeated.entry.state);
    try std.testing.expectError(error.IdempotencyConflict, store.beginQueuedRequest(std.testing.io, "rootfs-key", "digest", .install_source_import, 3));
}

test "expired terminal operation is no longer queryable" {
    var store: Store = .{};
    const begun = try store.begin(std.testing.io, "key", .install_source_import, 1);
    _ = try store.succeed(begun.entry.idSlice(), "done", 2);
    try std.testing.expect(store.get(begun.entry.idSlice(), 2 + retention_seconds) == null);
}
