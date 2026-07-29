//! M1 资产校验与完整性工具。
//!
//! 本模块负责面向文件系统的资产检查。它不决定资产是否可被 TFTP 提供——
//! 该决策由 TFTP server 根据 catalog manifest 做出。本模块只确保文件是
//! root-confined 的常规文件，且具有稳定的 SHA-256 摘要。
//!
//! 安全不变量：
//! - 路径必须是相对路径，拒绝 `..`、绝对路径和 Windows 分隔符
//! - **逐分量**打开，每一层都不跟随符号链接，因此中间目录的 symlink
//!   同样无法穿越（见 `openBeneath`）
//! - SHA-256 以 64 位小写十六进制字符串返回
//!
//! 为什么不依赖 `resolve_beneath`：`std.Io.Dir.OpenFileOptions.resolve_beneath`
//! 的语义是「若操作系统支持则生效，不支持则**静默忽略**」。其实现为
//! `if (@hasField(posix.O, "RESOLVE_BENEATH"))`，而该字段只在 FreeBSD/macOS
//! 的 `posix.O` 中存在。NodeForge 的生产目标是 Linux，实测
//! `@hasField(std.posix.O, "RESOLVE_BENEATH") == false`，即该选项在生产环境
//! 中是空操作。历史实现只传该标志加 `follow_symlinks = false`，而后者仅约束
//! 路径的**最后一个分量**（`O_NOFOLLOW` 语义），因此
//! `&lt;root&gt;/escape/secret`（`escape -&gt; /tmp` 为中间目录 symlink）可以读到
//! root 之外的文件。`/artifacts/**` 是零认证路由，故此为可被未认证请求
//! 触发的路径穿越。修复方式是不依赖任何平台可选标志，改为逐分量校验。

const std = @import("std");

pub const Error = error{
    EmptyPath,
    UnsafePath,
    NotRegularFile,
};

/// 在 `root_path` 之下逐分量打开 `relative_path`，任一分量是符号链接即失败。
///
/// 路径先经 `validateRelativePath` 拒绝 `..`、绝对路径和 Windows 分隔符；
/// 随后从 root 开始，对每个中间分量以 `follow_symlinks = false` 打开目录，
/// 最后一个分量以 `follow_symlinks = false` 打开文件。任一层若为符号链接，
/// 内核返回 `error.SymlinkLoop`（`O_NOFOLLOW` 语义），逃逸即被阻断。
///
/// 该实现只依赖所有 POSIX 平台都支持的 `O_NOFOLLOW`，不依赖
/// `RESOLVE_BENEATH`/`openat2` 等平台可选能力，因此在 Linux 上同样成立。
fn openBeneath(io: std.Io, root_path: []const u8, relative_path: []const u8) !std.Io.File {
    try validateRelativePath(relative_path);
    var current = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .access_sub_paths = true });
    var owns_current = true;
    defer if (owns_current) current.close(io);

    var parts = std.mem.splitScalar(u8, relative_path, '/');
    var pending = parts.next().?;
    while (parts.next()) |next_part| {
        // pending 是中间分量：必须是真实目录，不跟随符号链接。
        const child = try current.openDir(io, pending, .{ .follow_symlinks = false });
        if (owns_current) current.close(io);
        current = child;
        owns_current = true;
        pending = next_part;
    }
    // pending 是最后一个分量：以文件方式打开，同样不跟随符号链接。
    return current.openFile(io, pending, .{ .follow_symlinks = false });
}

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
/// 路径经 `openBeneath` 逐分量打开，中间目录与最终文件都不跟随符号链接，
/// 防止导入时纳管 root 外的文件。
/// 文件以 64KB 块读取，避免一次性分配大缓冲区。
/// 返回小写十六进制字符串写入 `out`。
pub fn sha256File(io: std.Io, root_path: []const u8, relative_path: []const u8, out: *[64]u8) !void {
    var file = try openBeneath(io, root_path, relative_path);
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

/// 在受管 root 下打开一个常规文件，逐分量拒绝符号链接。
/// 调用方拥有返回的描述符的所有权。HTTP 在需要将已验证的描述符直接传递
/// 给内核 sendfile 路径时使用此形式，避免二次打开和 TOCTOU 竞态。
pub fn openRegularFile(io: std.Io, root_path: []const u8, relative_path: []const u8) !std.Io.File {
    var file = try openBeneath(io, root_path, relative_path);
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
///
/// 与 `openBeneath` 同样逐分量打开：任一中间分量为符号链接即失败。
pub fn verifyDirectory(io: std.Io, root_path: []const u8, relative_path: []const u8) !void {
    try validateRelativePath(relative_path);
    var current = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .access_sub_paths = true });
    var owns_current = true;
    defer if (owns_current) current.close(io);
    var parts = std.mem.splitScalar(u8, relative_path, '/');
    while (parts.next()) |part| {
        const child = try current.openDir(io, part, .{ .follow_symlinks = false });
        if (owns_current) current.close(io);
        current = child;
        owns_current = true;
    }
}

test "relative asset paths cannot escape a root" {
    try validateRelativePath("efi/grubaa64.efi");
    try std.testing.expectError(error.UnsafePath, validateRelativePath("../etc/passwd"));
    try std.testing.expectError(error.UnsafePath, validateRelativePath("/etc/passwd"));
    try std.testing.expectError(error.UnsafePath, validateRelativePath("efi\\grub.efi"));
}

// 回归：中间目录符号链接不得穿越受管 root。
//
// 历史实现依赖 `resolve_beneath`，而该选项在 Linux 上被静默忽略
// （`posix.O` 无 `RESOLVE_BENEATH` 字段），`follow_symlinks = false` 又只
// 约束最后一个分量，因此 `<root>/escape/secret`（`escape` 指向 root 外）
// 可被读取。`/artifacts/**` 为零认证路由，构成未认证路径穿越。
//
// 本测试在临时目录中重建该布局，要求三个入口全部拒绝。
test "symlinked intermediate directory cannot escape the managed root" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    // 目标文件位于受管 root 之外。
    try temp.dir.writeFile(io, .{ .sub_path = "outside-secret", .data = "SECRET" });
    try temp.dir.createDirPath(io, "root");

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_len = try temp.dir.realPath(io, &root_buffer);
    const temp_abs = root_buffer[0..temp_len];

    var root_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = try std.fmt.bufPrint(&root_path_buffer, "{s}/root", .{temp_abs});

    // root 内的中间目录 symlink 指向 root 之外。
    try temp.dir.symLink(io, temp_abs, "root/escape", .{});

    // 内核对 `O_NOFOLLOW` 命中符号链接的报错取决于打开方式：
    // 作为目录打开（`O_DIRECTORY`）得到 `ENOTDIR`，作为文件打开得到 `ELOOP`。
    // 两者都表示逃逸被阻断，断言只要求「拒绝」而不锁定具体错误码。
    const escaping = "escape/outside-secret";
    try expectRejected(openRegularFile(io, root_abs, escaping));
    try expectRejected(verifyRegularFile(io, root_abs, escaping));
    var digest: [64]u8 = undefined;
    try expectRejected(sha256File(io, root_abs, escaping, &digest));
    try expectRejected(verifyDirectory(io, root_abs, "escape"));
}

// 断言某次受管打开被拒绝，且拒绝原因是符号链接约束而非其他错误。
fn expectRejected(result: anytype) !void {
    if (result) |value| {
        if (@TypeOf(value) == std.Io.File) value.close(std.testing.io);
        return error.TestExpectedRejection;
    } else |err| {
        const actual: anyerror = err;
        if (actual == error.SymlinkLoop or actual == error.NotDir) return;
        return actual;
    }
}

// root 内的正常嵌套文件必须仍可访问——修复不得误伤合法深层路径。
test "nested regular files beneath the root remain accessible" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "root/efi/nested");
    try temp.dir.writeFile(io, .{ .sub_path = "root/efi/nested/grub.efi", .data = "GRUB" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temp_len = try temp.dir.realPath(io, &root_buffer);
    const temp_abs = root_buffer[0..temp_len];
    var root_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = try std.fmt.bufPrint(&root_path_buffer, "{s}/root", .{temp_abs});

    try std.testing.expectEqual(@as(u64, 4), try verifyRegularFile(io, root_abs, "efi/nested/grub.efi"));
    try verifyDirectory(io, root_abs, "efi/nested");
    var digest: [64]u8 = undefined;
    try sha256File(io, root_abs, "efi/nested/grub.efi", &digest);
}
