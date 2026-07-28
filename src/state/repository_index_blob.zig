//! Repository 软件能力索引的内容寻址共享存储。
//!
//! ISO 导入得到的 SoftwareIndex 与具体 Node/session 无关。把它完整复制进每个
//! InstallPlan 会让同一 profile 的并发节点重复占用内存和 checkpoint 空间。
//! 本模块将完整 JSON 按 SHA-256 保存一次；InstallPlan 只保存 digest/bytes 引用。

const std = @import("std");
const model = @import("../model.zig");
const atomicWrite = @import("dhcp_store.zig").atomicWrite;

pub const Ref = struct {
    digest: [64]u8,
    bytes: u64,
};

/// 发布完整 SoftwareIndex；相同内容得到相同路径，可跨 profile/node/session 复用。
/// 原子发布成功后 digest 路径不可变；已存在时先确认普通文件/长度，再流式重算
/// SHA-256。长度相同不代表内容相同，禁止只凭 size 复用或覆盖损坏的 digest 路径。
pub fn publish(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, index: model.SoftwareIndex) !Ref {
    const json = try std.json.Stringify.valueAlloc(allocator, index, .{});
    defer allocator.free(json);
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json, &raw, .{});
    var digest: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&digest, "{x}", .{raw}) catch unreachable;
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ directory, &digest });
    defer allocator.free(path);
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
        if (stat.kind != .file or stat.size != json.len) return error.RepositoryIndexBlobCorrupt;
        const existing_digest = try sha256File(io, path);
        if (!std.crypto.timing_safe.eql([32]u8, raw, existing_digest))
            return error.RepositoryIndexBlobCorrupt;
        return .{ .digest = digest, .bytes = @intCast(json.len) };
    } else |err| if (err != error.FileNotFound) return err;
    try atomicWrite(io, path, json);
    return .{ .digest = digest, .bytes = @intCast(json.len) };
}

fn sha256File(io: std.Io, path: []const u8) ![32]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [256 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositionalAll(io, &buffer, offset);
        if (count == 0) break;
        hash.update(buffer[0..count]);
        offset += count;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

test "identical repository indexes share one content digest" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try temp.dir.realPath(std.testing.io, &buffer);
    const index: model.SoftwareIndex = .{
        .revision_digest = "catalog-revision",
        .capabilities = &.{.{ .id = "bash", .name = "Bash", .kind = .package }},
    };
    const first = try publish(std.testing.io, std.testing.allocator, buffer[0..len], index);
    const second = try publish(std.testing.io, std.testing.allocator, buffer[0..len], index);
    try std.testing.expectEqualSlices(u8, &first.digest, &second.digest);
    try std.testing.expectEqual(first.bytes, second.bytes);
}

test "same-size corrupted repository index blob is rejected" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try temp.dir.realPath(std.testing.io, &buffer);
    const index: model.SoftwareIndex = .{
        .revision_digest = "catalog-revision",
        .capabilities = &.{.{ .id = "bash", .name = "Bash", .kind = .package }},
    };
    const ref = try publish(std.testing.io, std.testing.allocator, buffer[0..len], index);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}.json", .{ buffer[0..len], &ref.digest });
    defer std.testing.allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    bytes[0] ^= 1;
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    try std.testing.expectError(error.RepositoryIndexBlobCorrupt, publish(std.testing.io, std.testing.allocator, buffer[0..len], index));
}
