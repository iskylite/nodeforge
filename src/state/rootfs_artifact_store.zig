//! # v0.2 rootfs artifact store
//!
//! 持久化已构建 rootfs 制品记录，按 `rootfs_input_digest` 内容寻址。bootConfig
//! v2 交付据此解析节点 diskless Profile 的 rootfs locator（url/sha512/size）。
//!
//! 制品记录只增不删（v0.2 不做 rootfs GC，见 `V0_2_IMPL_DETAILS.md` §7）；
//! 同一 `rootfs_input_digest` 重复 register 为幂等覆盖（仅当 sha512 一致），
//! sha512 漂移则拒绝（immutable ETag 不变式）。rootfs 文件本体存于
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
    uncompressed_size: u64,
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

/// 内存 + 持久 rootfs 制品登记。非线程安全；调用方持有 model gate（与其它
/// catalog mutation 串行），或在外层加锁。
pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    artifacts: std.ArrayList(Artifact),

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

    /// 登记一个 ready 制品。同 digest 幂等：sha512 一致则静默成功，漂移则
    /// 返回 `RootfsDigestDrift`（immutable ETag 不变式）。新增制品持久化。
    pub fn register(self: *Store, io: std.Io, artifact: Artifact) !RegisterResult {
        for (self.artifacts.items) |*existing| {
            if (std.mem.eql(u8, existing.rootfs_input_digest, artifact.rootfs_input_digest)) {
                if (!std.mem.eql(u8, existing.content_sha512, artifact.content_sha512)) return error.RootfsDigestDrift;
                return .already_present;
            }
        }
        try self.appendOwned(try dupArtifact(self.allocator, artifact));
        try self.persist(io);
        return .registered;
    }

    /// 按 rootfs_input_digest 查找 ready 制品。
    pub fn find(self: *const Store, rootfs_input_digest: []const u8) ?Artifact {
        for (self.artifacts.items) |item| if (std.mem.eql(u8, item.rootfs_input_digest, rootfs_input_digest)) return item;
        return null;
    }

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

pub const RegisterResult = enum { registered, already_present };

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
    // digest drift rejected
    const drifted = Artifact{ .rootfs_input_digest = "d1", .profile = "p", .content_sha512 = "cd", .compressed_size = 10, .uncompressed_size = 40, .kernel_release = "5.14.0", .file = "d1.squashfs", .created_at = 1 };
    try std.testing.expectError(error.RootfsDigestDrift, store.register(std.testing.io, drifted));
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
