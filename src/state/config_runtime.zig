//! 引用计数、不可变的启动配置（`AppConfig`）世代，由 daemon 拥有。
//!
//! 与 `CatalogRuntime` 对称：`ConfigRuntime` 维护一个原子指针指向当前
//! `Snapshot`；协议 worker 通过 `acquire` 获取引用计数 +1 的快照，期间
//! 即使 daemon 通过 `publish` 替换了 `current`，旧快照仍保持存活直到
//! 最后一个 reader 调用 `release`。写入路径由 `writer` mutex 串行化。
//!
//! `ModelRuntime` 在更高层把 ConfigRuntime 和 CatalogRuntime 的 mutex
//! 组合成 `mutation_gate`，保证 config/catalog 的原子对发布。

const std = @import("std");
const model = @import("../model.zig");

/// 不可变的启动配置快照。`parsed` 持有堆分配的 JSON 解码结果；`refs`
/// 是原子引用计数，降到 0 时释放 parsed 和 snapshot 本身。
/// runtime 自身持有一个引用（代表 "current"）；每个协议 worker 再持有一个。
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(model.AppConfig),
    /// 此快照的 config revision；由 `revisionForConfig` 计算。
    revision: u64,
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    /// 返回此快照包含的只读 AppConfig 指针。指针在 `release()` 前一直有效。
    pub fn value(self: *const Snapshot) *const model.AppConfig {
        return &self.parsed.value;
    }

    /// 释放一个引用。引用计数降到 0 时释放 JSON 解析缓冲区和 snapshot 自身。
    pub fn release(self: *const Snapshot) void {
        const mutable: *Snapshot = @constCast(self);
        if (mutable.refs.fetchSub(1, .acq_rel) != 1) return;
        mutable.parsed.deinit();
        const allocator = mutable.allocator;
        allocator.destroy(mutable);
    }
};

/// 启动配置世代运行时。`current` 是指向当前快照的原子指针；`writer`
/// 串行化所有发布操作。
pub const ConfigRuntime = struct {
    allocator: std.mem.Allocator,
    current: std.atomic.Value(*Snapshot),
    writer: std.atomic.Mutex = .unlocked,

    /// 初始化 runtime，生成第一个 snapshot 并以 `initial_revision` 发布。
    pub fn init(allocator: std.mem.Allocator, initial: *const model.AppConfig, initial_revision: u64) !ConfigRuntime {
        const snapshot = try createSnapshot(allocator, initial.*, initial_revision);
        return .{ .allocator = allocator, .current = std.atomic.Value(*Snapshot).init(snapshot) };
    }

    /// 释放 runtime 持有的当前快照引用。仅在 daemon 关闭时调用。
    pub fn deinit(self: *ConfigRuntime) void {
        self.current.load(.acquire).release();
    }

    /// 在持有 publication mutex 的情况下 pin 当前世代。这关闭了
    /// load/increment 与 writer 释放旧 root 引用的竞态窗口。
    pub fn acquire(self: *ConfigRuntime) *const Snapshot {
        lock(&self.writer);
        defer self.writer.unlock();
        const snapshot = self.current.load(.acquire);
        _ = snapshot.refs.fetchAdd(1, .monotonic);
        return snapshot;
    }

    /// 返回当前 config revision（获取并立即释放一个快照）。
    pub fn currentRevision(self: *ConfigRuntime) u64 {
        const snapshot = self.acquire();
        defer snapshot.release();
        return snapshot.revision;
    }

    /// 校验、序列化、持久化并发布一个新 config 世代。
    /// 所有分配发生在 disk/publish 临界区之前，以缩短 mutex 持有时间。
    pub fn publish(self: *ConfigRuntime, candidate: model.AppConfig, new_revision: u64) !void {
        // 所有分配发生在 disk/publish 临界区之前。
        const next = try self.prepare(candidate, new_revision);
        errdefer next.release();
        self.publishPrepared(next);
    }

    /// 创建一个未发布的 snapshot。用于在持久化前预先准备世代，
    /// 再通过 `publishPrepared` 原子提交。典型用法见 `CatalogRuntime.publishInstallSource`。
    pub fn prepare(self: *ConfigRuntime, candidate: model.AppConfig, new_revision: u64) !*Snapshot {
        return createSnapshot(self.allocator, candidate, new_revision);
    }

    /// 原子替换 `current` 并释放旧 snapshot 的 runtime 引用。
    /// 仍在使用旧 snapshot 的 reader 不会受影响——它们的引用计数保证
    /// 旧 snapshot 存活到 release。
    pub fn publishPrepared(self: *ConfigRuntime, next: *Snapshot) void {
        lock(&self.writer);
        const previous = self.current.swap(next, .acq_rel);
        self.writer.unlock();
        previous.release();
    }
};

/// 创建一个独立的 snapshot：先序列化 `value` 为 JSON，再解析回来，
/// 使 snapshot 完全拥有其堆分配且不与任何外部切片共享。`revision`
/// 直接写入 snapshot；调用方负责保证其单调性。
fn createSnapshot(allocator: std.mem.Allocator, value: model.AppConfig, revision: u64) !*Snapshot {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(model.AppConfig, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const snapshot = try allocator.create(Snapshot);
    snapshot.* = .{ .allocator = allocator, .parsed = parsed, .revision = revision };
    return snapshot;
}

/// 自旋获取 mutex，通过 `Thread.yield` 让出 CPU 而非忙等。
/// config 发布操作时间短，自旋比 futex 更高效。
fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

test "old generation is reclaimed only after its final reader releases" {
    var runtime = try ConfigRuntime.init(std.testing.allocator, &model.AppConfig{ .server = .{ .server_ip = "192.0.2.1" } }, 1);
    defer runtime.deinit();
    const old = runtime.acquire();
    try runtime.publish(.{ .server = .{ .server_ip = "192.0.2.2" } }, 2);
    try std.testing.expectEqualStrings("192.0.2.1", old.value().server.server_ip);
    old.release();
    const current = runtime.acquire();
    defer current.release();
    try std.testing.expectEqual(@as(u64, 2), current.revision);
    try std.testing.expectEqualStrings("192.0.2.2", current.value().server.server_ip);
}
