//! # v0.2 rootfs 制品存储
//!
//! 持久化已构建 rootfs 制品记录，按 `rootfs_input_digest` 内容寻址。bootConfig
//! v3 交付据此解析节点 diskless Profile 的 rootfs locator（url/sha512/size）。
//!
//! 制品记录只增不删（v0.2 不做 rootfs GC，见 `V0_2_IMPL_DETAILS.md` §7）；
//! 同一 `rootfs_input_digest` 重复发布仅在不可变元数据一致时幂等；
//! `uncompressed_size` 可因服务端测量失败而保持 unknown，但发布后不可补写。
//! rootfs 文件本体存于
//! `paths.rootfs_dir`（`<profile>/<digest-prefix>/<profile>.squashfs`），本模块只持记录。
//! 目录中的 digest-prefix 仅用于可读分组；完整 `rootfs_input_digest` 才是查询、
//! 幂等发布与不可变校验依据，不能从文件名反推或截断比较。
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
    /// 逻辑展开大小；0 表示 nodeforged 构建期测量失败，不能据此执行内存硬校验。
    uncompressed_size: u64 = 0,
    /// 匹配的运行时内核 release（bootConfig kernel_release）。
    kernel_release: []const u8,
    /// 相对 rootfs_dir 的路径：
    /// `<profile>/<digest-prefix>/<profile>.squashfs`。
    file: []const u8,
    /// Unix 创建时刻。
    created_at: i64,
    /// v0.4 server-side deep-validation provenance.
    deep_validated: bool = false,
    deep_validation_version: ?[]const u8 = null,
};

const StoreFile = struct {
    schema_version: u32 = 2,
    artifacts: []const Artifact = &.{},
};

pub const current_deep_validation_version = "rootfs-deep-v1";

/// 内存 + 持久 rootfs 制品发布索引。服务端构建 worker 与 HTTP reader 可并发访问；
/// 内部 mutex 保护 ArrayList 与持久化事务。
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
        if (parsed.value.schema_version != 2) return error.InvalidRootfsArtifactStore;
        for (parsed.value.artifacts) |item| {
            try validateArtifact(item);
            try self.appendOwned(try dupArtifact(self.allocator, item));
        }
    }

    /// 发布一个 nodeforged 构建完成的就绪制品。同一输入摘要的内容与全部元数据
    /// 必须一致；发布后不允许通过第二条路径补写或替换字段。
    ///
    /// 内存变更和持久化是一个提交单元：持久化失败时恢复原内存状态，避免
    /// 当前进程可见、重启后消失的“幽灵制品”。
    pub fn publish(self: *Store, io: std.Io, artifact: Artifact) !PublishResult {
        try validateArtifact(artifact);
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.artifacts.items) |*existing| {
            if (std.mem.eql(u8, existing.rootfs_input_digest, artifact.rootfs_input_digest)) {
                if (!std.mem.eql(u8, existing.content_sha512, artifact.content_sha512)) return error.RootfsDigestDrift;
                if (!sameImmutableMetadata(existing.*, artifact)) return error.RootfsMetadataDrift;
                if (existing.uncompressed_size != artifact.uncompressed_size) return error.RootfsMetadataDrift;
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
        return .published;
    }

    /// 按 rootfs_input_digest 查找 ready 制品。
    pub fn find(self: *const Store, rootfs_input_digest: []const u8) ?Artifact {
        const mutable: *Store = @constCast(self);
        lock(&mutable.mutex);
        defer mutable.mutex.unlock();
        for (self.artifacts.items) |item| if (std.mem.eql(u8, item.rootfs_input_digest, rootfs_input_digest)) return item;
        return null;
    }

    /// Startup audit for every indexed CAS object. An index entry is never
    /// considered ready after restart if its file is missing, symlinked,
    /// truncated, or content-drifted.
    pub fn auditRuntimeFiles(self: *Store, io: std.Io, rootfs_root: []const u8) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.artifacts.items) |artifact| {
            if (artifact.file.len == 0 or std.fs.path.isAbsolute(artifact.file) or
                std.mem.indexOf(u8, artifact.file, "..") != null or
                std.mem.indexOfScalar(u8, artifact.file, '\\') != null)
                return error.InvalidRootfsArtifactPath;
            const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ rootfs_root, artifact.file });
            defer self.allocator.free(path);
            var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .follow_symlinks = false }) catch return error.RootfsArtifactMissing;
            defer file.close(io);
            const stat = try file.stat(io);
            if (stat.kind != .file or stat.size != artifact.compressed_size) return error.RootfsArtifactMismatch;
            var hasher = std.crypto.hash.sha2.Sha512.init(.{});
            var buffer: [256 * 1024]u8 = undefined;
            var offset: u64 = 0;
            while (true) {
                const count = try file.readPositionalAll(io, &buffer, offset);
                if (count == 0) break;
                hasher.update(buffer[0..count]);
                offset += count;
            }
            var raw: [64]u8 = undefined;
            hasher.final(&raw);
            var actual: [128]u8 = undefined;
            _ = std.fmt.bufPrint(&actual, "{x}", .{raw}) catch unreachable;
            if (!std.mem.eql(u8, &actual, artifact.content_sha512)) return error.RootfsArtifactMismatch;
        }
    }

    /// 仅供 daemon 启动完成前或外部已停止并发访问的诊断使用。
    pub fn list(self: *const Store) []const Artifact {
        return self.artifacts.items;
    }

    fn appendOwned(self: *Store, item: Artifact) !void {
        try self.artifacts.append(self.allocator, item);
    }

    fn persist(self: *Store, io: std.Io) !void {
        const file: StoreFile = .{ .schema_version = 2, .artifacts = self.artifacts.items };
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, file, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);
        try atomicWrite(io, self.path, bytes);
    }
};

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

pub const PublishResult = enum { published, already_present };

fn sameImmutableMetadata(existing: Artifact, candidate: Artifact) bool {
    return existing.compressed_size == candidate.compressed_size and
        std.mem.eql(u8, existing.kernel_release, candidate.kernel_release) and
        std.mem.eql(u8, existing.file, candidate.file) and
        existing.deep_validated == candidate.deep_validated and
        optionalEqual(existing.deep_validation_version, candidate.deep_validation_version);
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
        .deep_validated = item.deep_validated,
        .deep_validation_version = if (item.deep_validation_version) |value| try allocator.dupe(u8, value) else null,
    };
}

fn freeArtifact(allocator: std.mem.Allocator, item: Artifact) void {
    allocator.free(item.rootfs_input_digest);
    allocator.free(item.profile);
    allocator.free(item.content_sha512);
    allocator.free(item.kernel_release);
    allocator.free(item.file);
    if (item.deep_validation_version) |value| allocator.free(value);
}

fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn validateArtifact(item: Artifact) !void {
    if (item.rootfs_input_digest.len == 0 or item.content_sha512.len == 0 or item.compressed_size == 0 or
        item.kernel_release.len == 0 or item.file.len == 0 or !item.deep_validated or item.deep_validation_version == null)
        return error.InvalidRootfsArtifactStore;
    if (!std.mem.eql(u8, item.deep_validation_version.?, current_deep_validation_version))
        return error.InvalidRootfsArtifactStore;
}

test "publish is idempotent and rejects digest drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/rootfs_artifacts.json", .{root_buf[0..root_len]});
    defer std.testing.allocator.free(path);
    var store = Store.init(std.testing.allocator, path);
    defer store.deinit();
    try store.load(std.testing.io);
    const not_validated: Artifact = .{ .rootfs_input_digest = "untrusted", .profile = "p", .content_sha512 = "ab", .compressed_size = 10, .kernel_release = "5.14.0", .file = "untrusted.squashfs", .created_at = 1 };
    try std.testing.expectError(error.InvalidRootfsArtifactStore, store.publish(std.testing.io, not_validated));
    const a: Artifact = .{ .rootfs_input_digest = "d1", .profile = "p", .content_sha512 = "ab", .compressed_size = 10, .uncompressed_size = 40, .kernel_release = "5.14.0", .file = "d1.squashfs", .created_at = 1, .deep_validated = true, .deep_validation_version = current_deep_validation_version };
    try std.testing.expectEqual(PublishResult.published, try store.publish(std.testing.io, a));
    try std.testing.expectEqual(PublishResult.already_present, try store.publish(std.testing.io, a));
    try std.testing.expect(store.find("d1") != null);
    // digest 漂移被拒绝
    const drifted = Artifact{ .rootfs_input_digest = "d1", .profile = "p", .content_sha512 = "cd", .compressed_size = 10, .uncompressed_size = 40, .kernel_release = "5.14.0", .file = "d1.squashfs", .created_at = 1, .deep_validated = true, .deep_validation_version = current_deep_validation_version };
    try std.testing.expectError(error.RootfsDigestDrift, store.publish(std.testing.io, drifted));
    const metadata_drifted = Artifact{ .rootfs_input_digest = "d1", .profile = "p", .content_sha512 = "ab", .compressed_size = 11, .uncompressed_size = 40, .kernel_release = "5.14.0", .file = "d1.squashfs", .created_at = 1, .deep_validated = true, .deep_validation_version = current_deep_validation_version };
    try std.testing.expectError(error.RootfsMetadataDrift, store.publish(std.testing.io, metadata_drifted));
}

test "published artifact metadata cannot be supplemented through a second path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/rootfs_artifacts.json", .{root_buf[0..root_len]});
    defer std.testing.allocator.free(path);
    var store = Store.init(std.testing.allocator, path);
    defer store.deinit();
    const unknown: Artifact = .{ .rootfs_input_digest = "d3", .profile = "p", .content_sha512 = "ab", .compressed_size = 10, .kernel_release = "5.14.0", .file = "d3.squashfs", .created_at = 1, .deep_validated = true, .deep_validation_version = current_deep_validation_version };
    try std.testing.expectEqual(PublishResult.published, try store.publish(std.testing.io, unknown));
    var changed = unknown;
    changed.uncompressed_size = 400;
    try std.testing.expectError(error.RootfsMetadataDrift, store.publish(std.testing.io, changed));
}

test "rootfs artifact startup audit verifies indexed bytes and rejects legacy schema" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const index_path = try std.fmt.allocPrint(allocator, "{s}/rootfs-artifacts.json", .{root});
    defer allocator.free(index_path);
    const runtime_root = try std.fmt.allocPrint(allocator, "{s}/rootfs", .{root});
    defer allocator.free(runtime_root);
    const object_path = try std.fmt.allocPrint(allocator, "{s}/sha256/aa/object.squashfs", .{runtime_root});
    defer allocator.free(object_path);
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(object_path).?);
    const bytes = "rootfs-object";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = object_path, .data = bytes });
    var raw: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &raw, .{});
    var sha512: [128]u8 = undefined;
    _ = std.fmt.bufPrint(&sha512, "{x}", .{raw}) catch unreachable;
    var store = Store.init(allocator, index_path);
    defer store.deinit();
    _ = try store.publish(io, .{
        .rootfs_input_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .profile = "p",
        .content_sha512 = &sha512,
        .compressed_size = bytes.len,
        .kernel_release = "5.14.0",
        .file = "sha256/aa/object.squashfs",
        .created_at = 1,
        .deep_validated = true,
        .deep_validation_version = current_deep_validation_version,
    });
    try store.auditRuntimeFiles(io, runtime_root);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = object_path, .data = "tamper-object" });
    try std.testing.expectError(error.RootfsArtifactMismatch, store.auditRuntimeFiles(io, runtime_root));

    const legacy_path = try std.fmt.allocPrint(allocator, "{s}/legacy.json", .{root});
    defer allocator.free(legacy_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = legacy_path, .data = "{\"schema_version\":1,\"artifacts\":[]}" });
    var legacy = Store.init(allocator, legacy_path);
    defer legacy.deinit();
    try std.testing.expectError(error.InvalidRootfsArtifactStore, legacy.load(io));
}

test "publish rolls back memory when persistence fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const missing_parent_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing/rootfs_artifacts.json", .{root_buf[0..root_len]});
    defer std.testing.allocator.free(missing_parent_path);
    var store = Store.init(std.testing.allocator, missing_parent_path);
    defer store.deinit();
    const artifact: Artifact = .{ .rootfs_input_digest = "d4", .profile = "p", .content_sha512 = "ab", .compressed_size = 10, .kernel_release = "5.14.0", .file = "d4.squashfs", .created_at = 1, .deep_validated = true, .deep_validation_version = current_deep_validation_version };
    try std.testing.expectError(error.FileNotFound, store.publish(std.testing.io, artifact));
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
        try std.testing.expectEqual(PublishResult.published, try store.publish(std.testing.io, .{ .rootfs_input_digest = "d2", .profile = "p2", .content_sha512 = "ef", .compressed_size = 99, .uncompressed_size = 200, .kernel_release = "6.1.0", .file = "d2.squashfs", .created_at = 7, .deep_validated = true, .deep_validation_version = current_deep_validation_version }));
    }
    var store = Store.init(std.testing.allocator, path);
    defer store.deinit();
    try store.load(std.testing.io);
    const found = store.find("d2") orelse return error.NotFound;
    try std.testing.expectEqualStrings("ef", found.content_sha512);
    try std.testing.expectEqual(@as(u64, 99), found.compressed_size);
    try std.testing.expectEqualStrings("6.1.0", found.kernel_release);
}
