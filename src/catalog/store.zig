//! NodeForge 管理 catalog 的加载和原子保存。
//! catalog 是 nodeforged 的内部事实源，CLI 只能通过管理 API 请求修改。
//! 本模块不校验 catalog 语义——校验由 `config/validate.zig` 统一执行。

const std = @import("std");
const model = @import("../model.zig");
const paths = @import("../paths.zig");

/// 默认 catalog 路径；与 `config/load.zig` 的默认路径同源于 `paths.zig`。
/// catalog 是 nodeforged 管理对象，不要求管理员手写。
pub const default_path = paths.catalog_path;
/// catalog 文件最大允许 8 MiB，防止异常文件耗尽内存。
pub const max_catalog_bytes = 8 * 1024 * 1024;

/// 返回空 catalog，供 M0 骨架和未导入资产的新安装环境使用。
/// 这不是“忽略 catalog”，而是让新安装也能先完成配置校验和服务启动；
/// 一旦通过 CLI/API 导入资产，nodeforged 再原子写出真实 catalog 文件。
pub fn empty() model.Catalog {
    return .{};
}

/// 从文件系统读取并解析 catalog JSON。
///
/// 返回的 `Parsed` 对象拥有全部字符串内存，调用者必须 `deinit`。
/// 文件缓冲区在返回前释放，因此解析器必须复制所有字符串（已通过
/// `.allocate = .alloc_always` 保证）。
///
/// 可能返回的错误：`FileNotFound`（文件不存在）、`ReadError`、`ParseError`。
pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(model.Catalog) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_catalog_bytes),
    );
    defer allocator.free(bytes);

    return std.json.parseFromSlice(model.Catalog, allocator, bytes, .{
        .allocate = .alloc_always,
    });
}

/// 将 catalog 格式化为稳定、便于审阅的 JSON（缩进 2 空格），末尾补换行。
/// 返回的内存归调用者所有，需自行 `free`。
pub fn render(allocator: std.mem.Allocator, catalog: *const model.Catalog) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try std.json.Stringify.value(catalog.*, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

/// 原子写回 catalog JSON。
///
/// 临时文件与目标文件位于同一目录，以保证 rename 不跨文件系统。
/// 文件内容先 `sync`，任何写入失败都不会破坏旧 catalog；
/// 成功 rename 后旧文件才被替换。仅由 `nodeforged` 调用。
pub fn save(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    catalog: *const model.Catalog,
) !void {
    const bytes = try render(allocator, catalog);
    defer allocator.free(bytes);

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);

    const dir = std.Io.Dir.cwd();
    errdefer dir.deleteFile(io, temp_path) catch {};
    {
        var file = try dir.createFile(io, temp_path, .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try std.Io.Dir.rename(dir, temp_path, dir, path, io);
}

test "empty catalog renders parseable JSON" {
    const allocator = std.testing.allocator;
    const catalog: model.Catalog = .{};
    const bytes = try render(allocator, &catalog);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(model.Catalog, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.assets.len);
}
