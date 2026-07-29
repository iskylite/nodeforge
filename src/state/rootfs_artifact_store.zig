//! # v0.2 rootfs 制品存储
//!
//! 持久化已构建 rootfs 制品记录，按 `rootfs_input_digest` 内容寻址。bootConfig
//! v3 交付据此解析节点 diskless Profile 的 rootfs locator（url/sha512/size）。
//!
//! 制品记录只增不删（v0.2 不做 rootfs GC，见 `V0_2_IMPL_DETAILS.md` §7）；
//! 同一 `rootfs_input_digest` 重复登记仅在不可变元数据一致时幂等；
//! `uncompressed_size` 允许从未知补全为已知，其余漂移均拒绝。rootfs 文件本体存于
//! `paths.rootfs_dir`（内容寻址 `<digest>.squashfs`），本模块只持记录。
const std = @import("std");
const atomicWrite = @import("dhcp_store.zig").atomicWrite;

/// 已发布 rootfs 制品记录（持久事实）。
pub const Artifact = struct {
    /// Profile build projection 的 canonical SHA-256（64 hex），内容寻址 key。
    rootfs_input_digest: []const u8,
    /// 所属 Profile 名（诊断/展示用，不参与寻址）。
    profile: []const u8,
    /// 压缩 squashfs 内容 SHA-512（immutable ETag）。
    content_sha512: []const u8,
    compressed_size: u64,
    /// 逻辑展开大小；0 表示外部制品未提供，不能据此执行内存硬校验。
    uncompressed_size: u64 = 0,
    /// 匹配的运行时内核 release（bootConfig kernel_release）。
    kernel_release: []const u8,
    /// 相对 rootfs_dir 的 squashfs 文件名（`<digest>.squashfs`）。
    file: []const u8,
    /// Unix 创建时刻。
    created_at: i64,
};

const StoreFile = struct {
    schema_version: u32 = 1,
    artifacts: []const Artifact = &.{},
};

/// 内存 + 持久 rootfs 制品登记。后台 builder 与 HTTP reader 可并发访问；
/// 内部 mutex 保护 ArrayList、metadata 补全及持久化事务。
pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    artifacts: std.ArrayList(Artifact),
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Store {
        return .{ .allocator = allocator, .path = path, .artifacts = .empty };
    }

    pub fn deinit(self: *Store) void {
        for (self.artifacts.items) |item| freeArtifact(self.allocator, item);
        self.artifacts.deinit(self.allocator);
    }

    /// 从磁盘加载；文件不存在视为空。
    pub fn load(self: *Store, io: std.Io) !void {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, self.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(StoreFile, self.allocator, bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value.schema_version != 1) return error.InvalidRootfsArtifactStore;
        for (parsed.value.artifacts) |item| try self.appendOwned(try dupArtifact(self.allocator, item));
    }

    /// 登记一个就绪制品。同一输入摘要的内容与不可变元数据必须一致；
    /// `uncompressed_size` 唯一允许从 0（未知）补全为已知值。
    ///
    /// 内存变更和持久化是一个提交单元：持久化失败时恢复原内存状态，避免
    /// 当前进程可见、重启后消失的“幽灵制品”。
    pub fn register(self: *Store, io: std.Io, artifact: Artifact) !RegisterResult {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.artifacts.items) |*existing| {
            if (std.mem.eql(u8, existing.rootfs_input_digest, artifact.rootfs_input_digest)) {
                if (!std.mem.eql(u8, existing.content_sha512, artifact.content_sha512)) return error.RootfsDigestDrift;
                if (!sameImmutableMetadata(existing.*, artifact)) return error.RootfsMetadataDrift;
                if (existing.uncompressed_size != 0 and artifact.uncompressed_size != 0 and
                    existing.uncompressed_size != artifact.uncompressed_size)
                    return error.RootfsMetadataDrift;
                if (existing.uncompressed_size == 0 and artifact.uncompressed_size != 0) {
                    existing.uncompressed_size = artifact.uncompressed_size;
                    self.persist(io) catch |err| {
                        existing.uncompressed_size = 0;
                        return err;
                    };
                    return .metadata_updated;
                }
                return .already_present;
            }
        }
        const owned = try dupArtifact(self.allocator, artifact);
        self.appendOwned(owned) catch |err| {
            freeArtifact(self.allocator, owned);
            return err;
        };
        self.persist(io) catch |err| {
            const removed = self.artifacts.pop().?;
            freeArtifact(self.allocator, removed);
            return err;
        };
        return .registered;
    }

    /// 按 rootfs_input_digest 查找 ready 制品。
    pub fn find(self: *const Store, rootfs_input_digest: []const u8) ?Artifact {
        const mutable: *Store = @constCast(self);
        lock(&mutable.mutex);
        defer mutable.mutex.unlock();
        for (self.artifacts.items) |item| if (std.mem.eql(u8, item.rootfs_input_digest, rootfs_input_digest)) return item;
        return null;
    }

    /// 仅供 daemon 启动完成前或外部已停止并发访问的诊断使用。
    pub fn list(self: *const Store) []const Artifact {
        return self.artifacts.items;
    }

    fn appendOwned(self: *Store, item: Artifact) !void {
        try self.artifacts.append(self.allocator, item);
    }

    fn persist(self: *Store, io: std.Io) !void {
        const file: StoreFile = .{ .schema_version = 1, .artifacts = self.artifacts.items };
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, file, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);
        try atomicWrite(io, self.path, bytes);
    }
};

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

pub const RegisterResult = enum { registered, already_present, metadata_updated };

fn sameImmutableMetadata(existing: Artifact, candidate: Artifact) bool {
    return existing.compressed_size == candidate.compressed_size and
        std.mem.eql(u8, existing.profile, candidate.profile) and
        std.mem.eql(u8, existing.kernel_release, candidate.kernel_release) and
        std.mem.eql(u8, existing.file, candidate.file);
}

fn dupArtifact(allocator: std.mem.Allocator, item: Artifact) !Artifact {
    return .{
        .rootfs_input_digest = try allocator.dupe(u8, item.rootfs_input_digest),
        .profile = try allocator.dupe(u8, item.profile),
        .content_sha512 = try allocator.dupe(u8, item.content_sha512),
        .compressed_size = item.compressed_size,
        .uncompressed_size = item.uncompressed_size,
        .kernel_release = try allocator.dupe(u8, item.kernel_release),
        .file = try allocator.dupe(u8, item.file),
        .created_at = item.created_at,
    };
}

fn freeArtifact(allocator: std.mem.Allocator, item: Artifact) void {
    allocator.free(item.rootfs_input_digest);
    allocator.free(item.profile);
    allocator.free(item.content_sha512);
    allocator.free(item.kernel_release);
    allocator.free(item.file);
}

test "register is idempotent and rejects digest drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/rootfs_artifacts.json", .{root_buf[0..root_len]});
    defer std.testing.allocator.free(path);
    var store = Store.init(std.testing.allocator, path);
    defer store.deinit();
    try store.load(std.testing.io);
    const a: Artifact = .{ .rootfs_input_digest = "d1", .profile = "p", .content_sha512 = "ab", .compressed_size = 10, .uncompressed_size = 40, .kernel_release = "5.14.0", .file = "d1.squashfs", .created_at = 1 };
    try std.testing.expectEqual(RegisterResult.registered, try store.register(std.testing.io, a));
    try std.testing.expectEqual(RegisterResult.already_present, try store.register(std.testing.io, a));
    try std.testing.expect(store.find("d1") != null);
    // digest 漂移被拒绝
    const drifted = Artifact{ .rootfs_input_digest = "d1", .profile = "p", .content_sha512 = "cd", .compressed_size = 10, .uncompressed_size = 40, .kernel_release = "5.14.0", .file = "d1.squashfs", .created_at = 1 };
    try std.testing.expectError(error.RootfsDigestDrift, store.register(std.testing.io, drifted));
    const metadata_drifted = Artifact{ .rootfs_input_digest = "d1", .profile = "p", .content_sha512 = "ab", .compressed_size = 11, .uncompressed_size = 40, .kernel_release = "5.14.0", .file = "d1.squashfs", .created_at = 1 };
    try std.testing.expectError(error.RootfsMetadataDrift, store.register(std.testing.io, metadata_drifted));
}

test "register fills unknown uncompressed size and persists the update" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/rootfs_artifacts.json", .{root_buf[0..root_len]});
    defer std.testing.allocator.free(path);
    const unknown: Artifact = .{ .rootfs_input_digest = "d3", .profile = "p", .content_sha512 = "ab", .compressed_size = 10, .kernel_release = "5.14.0", .file = "d3.squashfs", .created_at = 1 };
    {
        var store = Store.init(std.testing.allocator, path);
        defer store.deinit();
        try std.testing.expectEqual(RegisterResult.registered, try store.register(std.testing.io, unknown));
        var known = unknown;
        known.uncompressed_size = 400;
        try std.testing.expectEqual(RegisterResult.metadata_updated, try store.register(std.testing.io, known));
    }
    var restored = Store.init(std.testing.allocator, path);
    defer restored.deinit();
    try restored.load(std.testing.io);
    try std.testing.expectEqual(@as(u64, 400), restored.find("d3").?.uncompressed_size);
}

test "register rolls back memory when persistence fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const missing_parent_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing/rootfs_artifacts.json", .{root_buf[0..root_len]});
    defer std.testing.allocator.free(missing_parent_path);
    var store = Store.init(std.testing.allocator, missing_parent_path);
    defer store.deinit();
    const artifact: Artifact = .{ .rootfs_input_digest = "d4", .profile = "p", .content_sha512 = "ab", .compressed_size = 10, .kernel_release = "5.14.0", .file = "d4.squashfs", .created_at = 1 };
    try std.testing.expectError(error.FileNotFound, store.register(std.testing.io, artifact));
    try std.testing.expect(store.find("d4") == null);
}

test "store persists and reloads across instances" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/rootfs_artifacts.json", .{root_buf[0..root_len]});
    defer std.testing.allocator.free(path);
    {
        var store = Store.init(std.testing.allocator, path);
        defer store.deinit();
        try store.load(std.testing.io);
        try std.testing.expectEqual(RegisterResult.registered, try store.register(std.testing.io, .{ .rootfs_input_digest = "d2", .profile = "p2", .content_sha512 = "ef", .compressed_size = 99, .uncompressed_size = 200, .kernel_release = "6.1.0", .file = "d2.squashfs", .created_at = 7 }));
    }
    var store = Store.init(std.testing.allocator, path);
    defer store.deinit();
    try store.load(std.testing.io);
    const found = store.find("d2") orelse return error.NotFound;
    try std.testing.expectEqualStrings("ef", found.content_sha512);
    try std.testing.expectEqual(@as(u64, 99), found.compressed_size);
    try std.testing.expectEqualStrings("6.1.0", found.kernel_release);
}
