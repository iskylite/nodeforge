//! Resolves NodeForge's persistent bootstrap SSH client key.
//!
//! The private key never enters config or answer data. `ssh-keygen` is used for
//! generated keys so the on-disk private-key encoding and file permissions are
//! directly compatible with the OpenSSH client used by operators.

const std = @import("std");
const model = @import("../model.zig");
const paths = @import("../paths.zig");

pub const Error = error{ ServerAdminKeyUnavailable, InvalidPublicKey } || std.mem.Allocator.Error;

const generated_dir = paths.keys_dir;
const generated_private = generated_dir ++ "/id_ed25519";
const generated_public = generated_private ++ ".pub";
const generated_private_temp = generated_private ++ ".tmp";
const generated_public_temp = generated_private_temp ++ ".pub";

pub fn resolve(io: std.Io, allocator: std.mem.Allocator, server: model.ServerConfig) ![]u8 {
    if (server.ssh_authorized_public_key) |key| return checkedDupe(allocator, key);
    inline for ([_][]const u8{ "/root/.ssh/id_rsa.pub", "/root/.ssh/id_ed25519.pub" }) |path| {
        if (readKey(io, allocator, path)) |key| return key else |_| {}
    }
    if (readKey(io, allocator, generated_public)) |key| {
        errdefer allocator.free(key);
        if (!try pairMatches(io, allocator, generated_private, key)) return error.ServerAdminKeyUnavailable;
        return key;
    } else |err| if (err != error.FileNotFound) return error.ServerAdminKeyUnavailable;
    if (try pathExists(io, generated_private)) return error.ServerAdminKeyUnavailable;
    try std.Io.Dir.cwd().createDirPath(io, generated_dir);
    const dir = std.Io.Dir.cwd();
    dir.deleteFile(io, generated_private_temp) catch {};
    dir.deleteFile(io, generated_public_temp) catch {};
    errdefer dir.deleteFile(io, generated_private_temp) catch {};
    errdefer dir.deleteFile(io, generated_public_temp) catch {};
    const result = std.process.run(allocator, io, .{ .argv = &.{ "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", generated_private_temp }, .stdout_limit = .limited(1024), .stderr_limit = .limited(4096) }) catch return error.ServerAdminKeyUnavailable;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ServerAdminKeyUnavailable,
        else => return error.ServerAdminKeyUnavailable,
    }
    const public_key = readKey(io, allocator, generated_public_temp) catch return error.ServerAdminKeyUnavailable;
    defer allocator.free(public_key);
    if (!try pairMatches(io, allocator, generated_private_temp, public_key)) return error.ServerAdminKeyUnavailable;
    try chmod(io, allocator, generated_dir, "700");
    try chmod(io, allocator, generated_private_temp, "600");
    try chmod(io, allocator, generated_public_temp, "644");
    try syncFile(io, generated_private_temp);
    try syncFile(io, generated_public_temp);
    try std.Io.Dir.rename(dir, generated_private_temp, dir, generated_private, io);
    try std.Io.Dir.rename(dir, generated_public_temp, dir, generated_public, io);
    try syncDirectory(io, generated_dir);
    return readKey(io, allocator, generated_public) catch error.ServerAdminKeyUnavailable;
}

/// M4.2 F5: Resolve additional SSH public keys from config and assets directory.
/// Scans `ssh_authorized_public_keys` from ServerConfig and the
/// `assets/keys/` directory for `.pub` files.
/// Returns an allocated slice of allocated key strings; caller must free each
/// element and the slice itself.
pub fn resolveAdditional(io: std.Io, allocator: std.mem.Allocator, server: model.ServerConfig) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |key| allocator.free(key);
        keys.deinit(allocator);
    }
    // Config-specified additional keys.
    for (server.ssh_authorized_public_keys) |key| {
        if (!valid(key)) return error.InvalidPublicKey;
        try keys.append(allocator, try allocator.dupe(u8, key));
    }
    // State directory scan for .pub files.
    var dir = std.Io.Dir.cwd().openDir(io, generated_dir, .{ .iterate = true, .follow_symlinks = false }) catch {
        return keys.toOwnedSlice(allocator);
    };
    defer dir.close(io);
    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".pub")) continue;
        if (std.mem.eql(u8, entry.name, "id_ed25519.pub")) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ generated_dir, entry.name });
        defer allocator.free(path);
        const key = readKey(io, allocator, path) catch continue;
        // Deduplicate against already-collected keys.
        var duplicate = false;
        for (keys.items) |existing| if (sameKey(existing, key)) {
            duplicate = true;
            break;
        };
        if (duplicate) {
            allocator.free(key);
            continue;
        }
        try keys.append(allocator, key);
    }
    return keys.toOwnedSlice(allocator);
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
    // Never follow a symlink from a privileged key search path. The public
    // component is still treated as untrusted input and parsed below.
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
