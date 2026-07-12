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

/// 校验资产相对路径的安全性。拒绝可能逃逸资产 root 的路径或使用平台特定
/// 分隔符的路径。资产路径始终是斜杠分隔的相对路径。
///
/// 拒绝的路径模式：
/// - 空路径
/// - 以 `/` 或 `\` 开头的绝对路径
/// - 包含 `..` 或 `.` 的路径段
/// - 包含 Windows 分隔符 `\` 的路径段
/// 这防止 `../etc/passwd` 类路径穿越攻击。
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

/// 在不读取文件内容的情况下校验解析器边界。HTTP 静态文件服务在将传输
/// 委托给 I/O 后端之前调用此函数，确认文件存在且是常规文件。
/// 返回文件大小（字节），供 HTTP Content-Length header 使用。
pub fn verifyRegularFile(io: std.Io, root_path: []const u8, relative_path: []const u8) !u64 {
    var file = try openRegularFile(io, root_path, relative_path);
    defer file.close(io);
    return (try file.stat(io)).size;
}

/// 在受管 root 下打开一个不跟随符号链接的常规文件。
/// 调用方拥有返回的描述符的所有权。HTTP 在需要将已验证的描述符直接传递
/// 给内核 sendfile 路径时使用此形式，避免二次打开和 TOCTOU 竞态。
pub fn openRegularFile(io: std.Io, root_path: []const u8, relative_path: []const u8) !std.Io.File {
    try validateRelativePath(relative_path);
    var root = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .access_sub_paths = true });
    defer root.close(io);
    var file = try root.openFile(io, relative_path, .{ .follow_symlinks = false, .resolve_beneath = true });
    const stat = try file.stat(io);
    if (stat.kind != .file) {
        file.close(io);
        return error.NotRegularFile;
    }
    return file;
}

/// 确认受管路径是一个真实目录而非符号链接或其他特殊文件。
/// ISO 导入在将 `dists` 或 `pool` 视为可发布的 repository root 之前
/// 调用此函数，防止将符号链接目录误发布为 repository。
pub fn verifyDirectory(io: std.Io, root_path: []const u8, relative_path: []const u8) !void {
    try validateRelativePath(relative_path);
    var root = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .access_sub_paths = true });
    defer root.close(io);
    var directory = try root.openDir(io, relative_path, .{ .follow_symlinks = false });
    directory.close(io);
}

test "relative asset paths cannot escape a root" {
    try validateRelativePath("efi/grubaa64.efi");
    try std.testing.expectError(error.UnsafePath, validateRelativePath("../etc/passwd"));
    try std.testing.expectError(error.UnsafePath, validateRelativePath("/etc/passwd"));
    try std.testing.expectError(error.UnsafePath, validateRelativePath("efi\\grub.efi"));
}
