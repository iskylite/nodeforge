//! # Rootfs staging 保留树索引（v0.4）
//!
//! 可选保留的 rootfs 构建解包目录位于 `<work>/rootfs-staging/<digest>/`。
//! 操作员可 chroot 进保留树做特殊手工调整，再用 `profile rootfs build --from-staging`
//! 重新打包发布。索引持久化于 `state/rootfs-stagings.json`；查询时若磁盘树缺失，
//! 视为不可用（`ready=false`），不自动复活。
//!
//! 边界：
//! - 保留树**不是**正式制品；diskless 节点只消费 ready squashfs。
//! - `rootfs_input_digest` 仍按 Profile build projection 计算；手改树后再打包
//!   会替换同一 digest 下的 CAS 对象（`replace`），便于实验室特需，不改变摘要语义。
//! - 默认构建不保留；仅 `--keep-staging` / `keep_staging:true` 时写入。
const std = @import("std");
const atomicWrite = @import("dhcp_store.zig").atomicWrite;

pub const Entry = struct {
    /// Profile build projection 的 canonical SHA-256（64 hex），稳定寻址键与目录名。
    rootfs_input_digest: []const u8,
    /// 保留时的 Profile 名（诊断/展示用，不参与寻址）。
    profile: []const u8,
    /// 保留树根目录的绝对路径。
    path: []const u8,
    /// 最近一次保留/提升的 Unix 时间。
    kept_at: i64,
    /// 写入/提升该树的 rootfs_build operation id（可空）。
    operation_id: []const u8 = "",
    /// 测量到的目录树表观字节数；0 表示未知。
    apparent_bytes: u64 = 0,
};

const StoreFile = struct {
    schema_version: u32 = 1,
    entries: []const Entry = &.{},
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    entries: std.ArrayList(Entry),
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Store {
        return .{ .allocator = allocator, .path = path, .entries = .empty };
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |item| freeEntry(self.allocator, item);
        self.entries.deinit(self.allocator);
    }

    pub fn load(self: *Store, io: std.Io) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, self.allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(StoreFile, self.allocator, bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value.schema_version != 1) return error.InvalidRootfsStagingStore;
        for (parsed.value.entries) |item| {
            try validateEntry(item);
            try self.entries.append(self.allocator, try dupEntry(self.allocator, item));
        }
    }

    /// 按 digest 插入或覆盖一条保留记录（内存 + 磁盘同一事务）。
    pub fn upsert(self: *Store, io: std.Io, entry: Entry) !void {
        try validateEntry(entry);
        lock(&self.mutex);
        defer self.mutex.unlock();
        const owned = try dupEntry(self.allocator, entry);
        errdefer freeEntry(self.allocator, owned);
        for (self.entries.items, 0..) |*existing, i| {
            if (std.mem.eql(u8, existing.rootfs_input_digest, entry.rootfs_input_digest)) {
                freeEntry(self.allocator, existing.*);
                self.entries.items[i] = owned;
                try self.persist(io);
                return;
            }
        }
        try self.entries.append(self.allocator, owned);
        self.persist(io) catch |err| {
            const removed = self.entries.pop().?;
            freeEntry(self.allocator, removed);
            return err;
        };
    }

    pub fn find(self: *const Store, rootfs_input_digest: []const u8) ?Entry {
        const mutable: *Store = @constCast(self);
        lock(&mutable.mutex);
        defer mutable.mutex.unlock();
        for (self.entries.items) |item| {
            if (std.mem.eql(u8, item.rootfs_input_digest, rootfs_input_digest)) return item;
        }
        return null;
    }

    pub fn findByProfile(self: *const Store, profile: []const u8) ?Entry {
        const mutable: *Store = @constCast(self);
        lock(&mutable.mutex);
        defer mutable.mutex.unlock();
        var best: ?Entry = null;
        for (self.entries.items) |item| {
            if (!std.mem.eql(u8, item.profile, profile)) continue;
            if (best == null or item.kept_at >= best.?.kept_at) best = item;
        }
        return best;
    }

    pub fn list(self: *const Store) []const Entry {
        return self.entries.items;
    }

    /// 删除索引条目；`delete_tree=true` 时同时删除磁盘上的保留树。
    pub fn remove(self: *Store, io: std.Io, rootfs_input_digest: []const u8, delete_tree: bool) !bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.entries.items, 0..) |item, i| {
            if (!std.mem.eql(u8, item.rootfs_input_digest, rootfs_input_digest)) continue;
            const path = try self.allocator.dupe(u8, item.path);
            defer self.allocator.free(path);
            freeEntry(self.allocator, item);
            _ = self.entries.orderedRemove(i);
            try self.persist(io);
            if (delete_tree) std.Io.Dir.cwd().deleteTree(io, path) catch {};
            return true;
        }
        return false;
    }

    fn persist(self: *Store, io: std.Io) !void {
        const file: StoreFile = .{ .schema_version = 1, .entries = self.entries.items };
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, file, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);
        try atomicWrite(io, self.path, bytes);
    }
};

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

fn validateEntry(item: Entry) !void {
    if (item.rootfs_input_digest.len != 64) return error.InvalidRootfsStagingStore;
    for (item.rootfs_input_digest) |b| {
        if (!std.ascii.isHex(b) or std.ascii.isUpper(b)) return error.InvalidRootfsStagingStore;
    }
    if (item.profile.len == 0 or item.path.len == 0 or !std.fs.path.isAbsolute(item.path))
        return error.InvalidRootfsStagingStore;
    if (std.mem.indexOf(u8, item.path, "..") != null) return error.InvalidRootfsStagingStore;
}

fn dupEntry(allocator: std.mem.Allocator, item: Entry) !Entry {
    return .{
        .rootfs_input_digest = try allocator.dupe(u8, item.rootfs_input_digest),
        .profile = try allocator.dupe(u8, item.profile),
        .path = try allocator.dupe(u8, item.path),
        .kept_at = item.kept_at,
        .operation_id = try allocator.dupe(u8, item.operation_id),
        .apparent_bytes = item.apparent_bytes,
    };
}

fn freeEntry(allocator: std.mem.Allocator, item: Entry) void {
    allocator.free(item.rootfs_input_digest);
    allocator.free(item.profile);
    allocator.free(item.path);
    allocator.free(item.operation_id);
}

/// 某 digest 对应的规范保留路径：`<staging_root>/<digest>`。
pub fn retainedPath(allocator: std.mem.Allocator, staging_root: []const u8, digest_hex: []const u8) ![]u8 {
    if (digest_hex.len != 64) return error.InvalidRootfsDigest;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ staging_root, digest_hex });
}

/// 粗检保留树是否可作 from-staging 源（至少存在 nodeforge-agent）。
pub fn treeLooksReady(io: std.Io, tree: []const u8) bool {
    var agent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const agent = std.fmt.bufPrint(&agent_buf, "{s}/usr/sbin/nodeforge-agent", .{tree}) catch return false;
    var file = std.Io.Dir.cwd().openFile(io, agent, .{ .mode = .read_only, .follow_symlinks = false }) catch return false;
    file.close(io);
    return true;
}

test "staging store upsert find remove and reload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const index = try std.fmt.allocPrint(std.testing.allocator, "{s}/stagings.json", .{root});
    defer std.testing.allocator.free(index);
    const tree = try std.fmt.allocPrint(std.testing.allocator, "{s}/tree", .{root});
    defer std.testing.allocator.free(tree);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, tree);

    const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var store = Store.init(std.testing.allocator, index);
    defer store.deinit();
    try store.upsert(std.testing.io, .{
        .rootfs_input_digest = digest,
        .profile = "p1",
        .path = tree,
        .kept_at = 10,
        .operation_id = "op1",
        .apparent_bytes = 99,
    });
    try std.testing.expect(store.find(digest) != null);
    try std.testing.expectEqualStrings("p1", store.findByProfile("p1").?.profile);

    var reloaded = Store.init(std.testing.allocator, index);
    defer reloaded.deinit();
    try reloaded.load(std.testing.io);
    const found = reloaded.find(digest) orelse return error.NotFound;
    try std.testing.expectEqual(@as(u64, 99), found.apparent_bytes);
    try std.testing.expect(try reloaded.remove(std.testing.io, digest, true));
    try std.testing.expect(reloaded.find(digest) == null);
}
