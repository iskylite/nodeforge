//! 解析 NodeForge 持久化的 bootstrap SSH 客户端密钥。
//!
//! 私钥永远不进入配置或 answer 数据。生成的密钥使用 `ssh-keygen`，
//! 因此磁盘上的私钥编码和文件权限与操作员使用的 OpenSSH 客户端直接兼容。

const std = @import("std");
const model = @import("../model.zig");
const paths = @import("../paths.zig");

pub const Error = error{ ServerAdminKeyUnavailable, InvalidPublicKey } || std.mem.Allocator.Error;

fn generatedDir() []const u8 {
    return paths.require().keys_dir;
}
fn generatedPrivate() []const u8 {
    return paths.require().bootstrap_private_key_path;
}
fn generatedPublic() []const u8 {
    return paths.require().bootstrap_public_key_path;
}
fn generatedPrivateTemp() []const u8 {
    return paths.require().bootstrap_private_key_temp_path;
}
fn generatedPublicTemp() []const u8 {
    return paths.require().bootstrap_public_key_temp_path;
}

pub fn resolve(io: std.Io, allocator: std.mem.Allocator, server: model.ServerConfig) ![]u8 {
    // 显式公钥数组是最高优先级事实源。第一个 key 是 bootstrap key，
    // 其余 key 由 resolveAdditional 返回；不得混入磁盘来源。
    if (server.ssh_authorized_public_keys.len > 0) return checkedDupe(allocator, server.ssh_authorized_public_keys[0]);
    const imported = try readImportedKeys(io, allocator);
    if (imported.len > 0) {
        const primary = imported[0];
        for (imported[1..]) |key| allocator.free(key);
        allocator.free(imported);
        return @constCast(primary);
    }
    allocator.free(imported);
    for ([_][]const u8{ "/root/.ssh/id_rsa.pub", "/root/.ssh/id_ed25519.pub" }) |path| {
        if (readKey(io, allocator, path)) |key| return key else |_| {}
    }
    if (readKey(io, allocator, generatedPublic())) |key| {
        errdefer allocator.free(key);
        if (!try pairMatches(io, allocator, generatedPrivate(), key)) return error.ServerAdminKeyUnavailable;
        return key;
    } else |err| if (err != error.FileNotFound) return error.ServerAdminKeyUnavailable;
    if (try pathExists(io, generatedPrivate())) return error.ServerAdminKeyUnavailable;
    try std.Io.Dir.cwd().createDirPath(io, generatedDir());
    const dir = std.Io.Dir.cwd();
    dir.deleteFile(io, generatedPrivateTemp()) catch {};
    dir.deleteFile(io, generatedPublicTemp()) catch {};
    errdefer dir.deleteFile(io, generatedPrivateTemp()) catch {};
    errdefer dir.deleteFile(io, generatedPublicTemp()) catch {};
    const result = std.process.run(allocator, io, .{ .argv = &.{ "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", generatedPrivateTemp() }, .stdout_limit = .limited(1024), .stderr_limit = .limited(4096) }) catch return error.ServerAdminKeyUnavailable;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ServerAdminKeyUnavailable,
        else => return error.ServerAdminKeyUnavailable,
    }
    const public_key = readKey(io, allocator, generatedPublicTemp()) catch return error.ServerAdminKeyUnavailable;
    defer allocator.free(public_key);
    if (!try pairMatches(io, allocator, generatedPrivateTemp(), public_key)) return error.ServerAdminKeyUnavailable;
    try chmod(io, allocator, generatedDir(), "700");
    try chmod(io, allocator, generatedPrivateTemp(), "600");
    try chmod(io, allocator, generatedPublicTemp(), "644");
    try syncFile(io, generatedPrivateTemp());
    try syncFile(io, generatedPublicTemp());
    try std.Io.Dir.rename(dir, generatedPrivateTemp(), dir, generatedPrivate(), io);
    try std.Io.Dir.rename(dir, generatedPublicTemp(), dir, generatedPublic(), io);
    try syncDirectory(io, generatedDir());
    return readKey(io, allocator, generatedPublic()) catch error.ServerAdminKeyUnavailable;
}

/// 解析主 key 之外需要一并注入的 SSH 公钥。
/// 显式公钥数组非空时只采用该数组；为空时才扫描 assets/keys，
/// 并把排序后的第一个 key 留给 resolve()。
pub fn resolveAdditional(io: std.Io, allocator: std.mem.Allocator, server: model.ServerConfig) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    if (server.ssh_authorized_public_keys.len > 0) {
        for (server.ssh_authorized_public_keys[1..]) |key| {
            if (!valid(key)) return error.InvalidPublicKey;
            var duplicate = sameKey(server.ssh_authorized_public_keys[0], key);
            for (keys.items) |existing| if (sameKey(existing, key)) {
                duplicate = true;
                break;
            };
            if (!duplicate) try keys.append(allocator, try allocator.dupe(u8, key));
        }
        return keys.toOwnedSlice(allocator);
    }
    const imported = try readImportedKeys(io, allocator);
    defer allocator.free(imported);
    if (imported.len == 0) return keys.toOwnedSlice(allocator);
    defer allocator.free(imported[0]);
    for (imported[1..]) |key| {
        var duplicate = false;
        for (keys.items) |existing| if (sameKey(existing, key)) {
            duplicate = true;
            break;
        };
        if (duplicate) {
            allocator.free(key);
        } else {
            try keys.append(allocator, key);
        }
    }
    return keys.toOwnedSlice(allocator);
}

/// 读取并按文件名排序导入公钥，确保 daemon 重启后主 key 选择稳定。
/// 自动生成的 id_ed25519.pub 属于更低优先级的兜底来源，不参与此扫描。
fn readImportedKeys(io: std.Io, allocator: std.mem.Allocator) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var dir = std.Io.Dir.cwd().openDir(io, generatedDir(), .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc([]const u8, 0),
        else => return err,
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".pub")) continue;
        if (std.mem.eql(u8, entry.name, "id_ed25519.pub")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);

    var imported: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (imported.items) |key| allocator.free(key);
        imported.deinit(allocator);
    }
    for (names.items) |name| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ generatedDir(), name });
        defer allocator.free(path);
        const key = readKey(io, allocator, path) catch continue;
        var duplicate = false;
        for (imported.items) |existing| if (sameKey(existing, key)) {
            duplicate = true;
            break;
        };
        if (duplicate) allocator.free(key) else try imported.append(allocator, key);
    }
    return imported.toOwnedSlice(allocator);
}

fn pathExists(io: std.Io, path: []const u8) !bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.ServerAdminKeyUnavailable,
    };
    file.close(io);
    return true;
}

fn pairMatches(io: std.Io, allocator: std.mem.Allocator, private_path: []const u8, public_key: []const u8) !bool {
    var private = std.Io.Dir.cwd().openFile(io, private_path, .{ .allow_directory = false, .follow_symlinks = false }) catch return false;
    defer private.close(io);
    if ((try private.stat(io)).kind != .file) return false;
    const result = std.process.run(allocator, io, .{ .argv = &.{ "ssh-keygen", "-y", "-f", private_path }, .stdout_limit = .limited(16 * 1024), .stderr_limit = .limited(4096) }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    const derived = std.mem.trim(u8, result.stdout, " \t\r\n");
    return sameKey(derived, public_key);
}

fn sameKey(left: []const u8, right: []const u8) bool {
    const left_parts = keyParts(left) orelse return false;
    const right_parts = keyParts(right) orelse return false;
    return std.mem.eql(u8, left_parts.algorithm, right_parts.algorithm) and std.mem.eql(u8, left_parts.blob, right_parts.blob);
}

const KeyParts = struct { algorithm: []const u8, blob: []const u8 };

fn keyParts(key: []const u8) ?KeyParts {
    const separator = std.mem.indexOfScalar(u8, key, ' ') orelse return null;
    const tail = std.mem.trimStart(u8, key[separator + 1 ..], " \t");
    const blob_end = std.mem.indexOfScalar(u8, tail, ' ') orelse tail.len;
    if (separator == 0 or blob_end == 0) return null;
    return .{ .algorithm = key[0..separator], .blob = tail[0..blob_end] };
}

fn chmod(io: std.Io, allocator: std.mem.Allocator, path: []const u8, mode: []const u8) !void {
    const result = std.process.run(allocator, io, .{ .argv = &.{ "chmod", mode, path }, .stdout_limit = .limited(64), .stderr_limit = .limited(4096) }) catch return error.ServerAdminKeyUnavailable;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ServerAdminKeyUnavailable,
        else => return error.ServerAdminKeyUnavailable,
    }
}

fn syncFile(io: std.Io, path: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    try file.sync(io);
}

fn syncDirectory(io: std.Io, path: []const u8) !void {
    var directory = try std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = true });
    defer directory.close(io);
    try directory.sync(io);
}

fn readKey(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // 永远不从特权密钥搜索路径跟随符号链接。公钥部分仍被视为不可信输入，
    // 在下方解析校验。
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > 16 * 1024) return error.InvalidPublicKey;
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(16 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => return err,
    };
    defer allocator.free(bytes);
    const key = std.mem.trim(u8, bytes, " \t\r\n");
    if (!valid(key)) return error.InvalidPublicKey;
    return allocator.dupe(u8, key);
}

fn checkedDupe(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    if (!valid(key)) return error.InvalidPublicKey;
    return allocator.dupe(u8, key);
}

pub fn valid(key: []const u8) bool {
    if (key.len < 32 or key.len > 16 * 1024 or std.mem.indexOfAny(u8, key, "\r\n") != null or std.mem.indexOf(u8, key, "-----") != null) return false;
    const separator = std.mem.indexOfScalar(u8, key, ' ') orelse return false;
    const kind = key[0..separator];
    if (!(std.mem.eql(u8, kind, "ssh-ed25519") or std.mem.eql(u8, kind, "ssh-rsa") or std.mem.startsWith(u8, kind, "ecdsa-sha2-"))) return false;
    const tail = key[separator + 1 ..];
    const blob_end = std.mem.indexOfScalar(u8, tail, ' ') orelse tail.len;
    const blob = tail[0..blob_end];
    if (blob.len == 0) return false;
    const size = std.base64.standard_no_pad.Decoder.calcSizeForSlice(blob) catch return false;
    return size >= 16;
}

/// 生成与 OpenSSH `ssh-keygen -lf` 一致的 SHA256 指纹，不包含 key 注释。
/// 返回内存归调用者所有，格式固定为 `SHA256:<base64-no-padding>`。
pub fn fingerprint(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const parts = keyParts(key) orelse return error.InvalidPublicKey;
    const decoded_len = std.base64.standard_no_pad.Decoder.calcSizeForSlice(parts.blob) catch return error.InvalidPublicKey;
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    std.base64.standard_no_pad.Decoder.decode(decoded, parts.blob) catch return error.InvalidPublicKey;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(decoded, &digest, .{});
    const encoded_len = std.base64.standard_no_pad.Encoder.calcSize(digest.len);
    const output = try allocator.alloc(u8, "SHA256:".len + encoded_len);
    @memcpy(output[0.."SHA256:".len], "SHA256:");
    _ = std.base64.standard_no_pad.Encoder.encode(output["SHA256:".len..], &digest);
    return output;
}

/// 从任意本地路径读取并校验单行 OpenSSH 公钥，供 CLI 导入复用。
pub fn loadPublicKey(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readKey(io, allocator, path);
}

/// 根据已解析 key 反查运维可读来源。返回值归调用者所有；配置来源使用稳定
/// 字段路径，文件来源返回绝对路径，便于排查“私钥与注入公钥不匹配”。
pub fn sourceLabel(io: std.Io, allocator: std.mem.Allocator, server: model.ServerConfig, key: []const u8) ![]u8 {
    for (server.ssh_authorized_public_keys, 0..) |configured, index| {
        if (sameKey(configured, key)) return std.fmt.allocPrint(allocator, "config:server.ssh_authorized_public_keys[{d}]", .{index});
    }
    var directory = std.Io.Dir.cwd().openDir(io, generatedDir(), .{ .iterate = true, .follow_symlinks = false }) catch null;
    if (directory) |*dir| {
        defer dir.close(io);
        var iterator = dir.iterate();
        while (iterator.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".pub")) continue;
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ generatedDir(), entry.name });
            const candidate = readKey(io, allocator, path) catch {
                allocator.free(path);
                continue;
            };
            defer allocator.free(candidate);
            if (sameKey(candidate, key)) return path;
            allocator.free(path);
        }
    }
    for ([_][]const u8{ "/root/.ssh/id_rsa.pub", "/root/.ssh/id_ed25519.pub" }) |path| {
        const candidate = readKey(io, allocator, path) catch continue;
        defer allocator.free(candidate);
        if (sameKey(candidate, key)) return allocator.dupe(u8, path);
    }
    return allocator.dupe(u8, "generated-or-unknown");
}

test "explicit bootstrap key is accepted without filesystem access" {
    const key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+ test";
    const result = try checkedDupe(std.testing.allocator, key);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(key, result);
}

test "bootstrap key identity ignores comments but not algorithm or blob" {
    const blob = "AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+";
    try std.testing.expect(sameKey("ssh-ed25519 " ++ blob ++ " first", "ssh-ed25519 " ++ blob ++ " second"));
    try std.testing.expect(!sameKey("ssh-rsa " ++ blob, "ssh-ed25519 " ++ blob));
    try std.testing.expect(!sameKey("ssh-ed25519 " ++ blob, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeDifferentBlobValue1234567890"));
}

test "M4.2 explicit key array is authoritative and deduplicated" {
    const blob = "AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+";
    const first = "ssh-ed25519 " ++ blob ++ " operator";
    const duplicate = "ssh-ed25519 " ++ blob ++ " duplicate-comment";
    const second = "ssh-rsa " ++ blob ++ " auditor";
    const server: model.ServerConfig = .{
        .server_ip = "192.168.50.1",
        .ssh_authorized_public_keys = &.{ first, duplicate, second },
    };

    const primary = try resolve(std.testing.io, std.testing.allocator, server);
    defer std.testing.allocator.free(primary);
    try std.testing.expectEqualStrings(first, primary);

    const additional = try resolveAdditional(std.testing.io, std.testing.allocator, server);
    defer {
        for (additional) |key| std.testing.allocator.free(key);
        std.testing.allocator.free(additional);
    }
    try std.testing.expectEqual(@as(usize, 1), additional.len);
    try std.testing.expectEqualStrings(second, additional[0]);
    const source = try sourceLabel(std.testing.io, std.testing.allocator, server, additional[0]);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings("config:server.ssh_authorized_public_keys[2]", source);
}

test "M4.2 SSH fingerprint ignores comments" {
    const blob = "AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+";
    const first = try fingerprint(std.testing.allocator, "ssh-ed25519 " ++ blob ++ " first");
    defer std.testing.allocator.free(first);
    const second = try fingerprint(std.testing.allocator, "ssh-ed25519 " ++ blob ++ " second");
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.startsWith(u8, first, "SHA256:"));
}
