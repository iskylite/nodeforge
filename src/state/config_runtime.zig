const std = @import("std");
const model = @import("../model.zig");

/// An immutable, owned configuration generation. The runtime itself owns one
/// reference to `current`; every protocol request/worker pins another reference.
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(model.AppConfig),
    revision: u64,
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    pub fn value(self: *const Snapshot) *const model.AppConfig {
        return &self.parsed.value;
    }

    pub fn release(self: *const Snapshot) void {
        const mutable: *Snapshot = @constCast(self);
        if (mutable.refs.fetchSub(1, .acq_rel) != 1) return;
        mutable.parsed.deinit();
        const allocator = mutable.allocator;
        allocator.destroy(mutable);
    }
};

pub const ConfigRuntime = struct {
    allocator: std.mem.Allocator,
    current: std.atomic.Value(*Snapshot),
    writer: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, initial: *const model.AppConfig, initial_revision: u64) !ConfigRuntime {
        const snapshot = try createSnapshot(allocator, initial.*, initial_revision);
        return .{ .allocator = allocator, .current = std.atomic.Value(*Snapshot).init(snapshot) };
    }

    pub fn deinit(self: *ConfigRuntime) void {
        self.current.load(.acquire).release();
    }

    /// Pin the current generation while holding the publication mutex. This
    /// closes the load/increment race with a writer releasing the old root ref.
    pub fn acquire(self: *ConfigRuntime) *const Snapshot {
        lock(&self.writer);
        defer self.writer.unlock();
        const snapshot = self.current.load(.acquire);
        _ = snapshot.refs.fetchAdd(1, .monotonic);
        return snapshot;
    }

    pub fn currentRevision(self: *ConfigRuntime) u64 {
        const snapshot = self.acquire();
        defer snapshot.release();
        return snapshot.revision;
    }

    pub fn publish(self: *ConfigRuntime, candidate: model.AppConfig, new_revision: u64) !void {
        // All allocations happen before the disk/publish critical section.
        const next = try self.prepare(candidate, new_revision);
        errdefer next.release();
        self.publishPrepared(next);
    }

    pub fn prepare(self: *ConfigRuntime, candidate: model.AppConfig, new_revision: u64) !*Snapshot {
        return createSnapshot(self.allocator, candidate, new_revision);
    }

    pub fn publishPrepared(self: *ConfigRuntime, next: *Snapshot) void {
        lock(&self.writer);
        const previous = self.current.swap(next, .acq_rel);
        self.writer.unlock();
        previous.release();
    }
};

fn createSnapshot(allocator: std.mem.Allocator, value: model.AppConfig, revision: u64) !*Snapshot {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(model.AppConfig, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const snapshot = try allocator.create(Snapshot);
    snapshot.* = .{ .allocator = allocator, .parsed = parsed, .revision = revision };
    return snapshot;
}

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
