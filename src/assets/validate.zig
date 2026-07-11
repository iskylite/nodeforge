//! M1 资产校验与完整性工具。
//!
//! 本模块负责面向文件系统的资产检查。它不决定资产是否可被 TFTP 提供——
//! 该决策由 TFTP server 根据 catalog manifest 做出。本模块只确保文件是
//! root-confined 的常规文件，且具有稳定的 SHA-256 摘要。
//!
//! 安全不变量：
//! - 路径必须是相对路径，拒绝 `..`、绝对路径和 Windows 分隔符
//! - 文件打开时不跟随符号链接（`follow_symlinks = false`）
//! - 目录描述符使用 `resolve_beneath = true`，防止路径逃逸
//! - SHA-256 以 64 位小写十六进制字符串返回

const std = @import("std");

pub const Error = error{
    EmptyPath,
    UnsafePath,
    NotRegularFile,
};

/// Rejects paths which could escape an asset root or address a platform-specific
/// alternate separator.  Asset paths are always slash-separated relative paths.
pub fn validateRelativePath(path: []const u8) Error!void {
    if (path.len == 0) return error.EmptyPath;
    if (path[0] == '/' or path[0] == '\\') return error.UnsafePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or
            std.mem.indexOfScalar(u8, part, '\\') != null)
            return error.UnsafePath;
    }
}

/// 计算单个 manifest-relative 常规文件的 SHA-256 摘要。
///
/// 目录描述符使用 `resolve_beneath` 限制路径不逃逸 root；
/// 符号链接不跟随（`follow_symlinks = false`），防止导入时纳管 root 外的文件。
/// 文件以 64KB 块读取，避免一次性分配大缓冲区。
/// 返回小写十六进制字符串写入 `out`。
pub fn sha256File(io: std.Io, root_path: []const u8, relative_path: []const u8, out: *[64]u8) !void {
    try validateRelativePath(relative_path);
    var root = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .access_sub_paths = true });
    defer root.close(io);
    var file = try root.openFile(io, relative_path, .{ .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.NotRegularFile;

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.readPositionalAll(io, &buffer, offset);
        if (n == 0) break;
        hash.update(buffer[0..n]);
        offset += n;
        if (n < buffer.len) break;
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    out.* = std.fmt.bytesToHex(digest, .lower);
}

test "relative asset paths cannot escape a root" {
    try validateRelativePath("efi/grubaa64.efi");
    try std.testing.expectError(error.UnsafePath, validateRelativePath("../etc/passwd"));
    try std.testing.expectError(error.UnsafePath, validateRelativePath("/etc/passwd"));
    try std.testing.expectError(error.UnsafePath, validateRelativePath("efi\\grub.efi"));
}
