//! 配置序列化和原子写回。
//! 始终先写同目录临时文件并同步内容，再通过 rename 替换事实源。
//! 本模块不校验配置语义——调用者必须在写回前完成校验。

const std = @import("std");
const model = @import("../model.zig");

/// 将配置格式化为稳定、便于审阅的 JSON，并在末尾补换行。
/// 返回内存归调用者所有。
pub fn render(allocator: std.mem.Allocator, config: *const model.AppConfig) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try std.json.Stringify.value(config.*, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

/// 原子写回配置。
///
/// 临时文件与目标文件位于同一目录，以保证 rename 不跨文件系统。文件内容先
/// `sync`，任何写入失败都不会破坏旧配置；成功 rename 后旧配置才被替换。
pub fn save(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    config: *const model.AppConfig,
) !void {
    const bytes = try render(allocator, config);
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

test "render produces parseable JSON" {
    const allocator = std.testing.allocator;
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.50.1" } };
    const bytes = try render(allocator, &config);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(model.AppConfig, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("192.168.50.1", parsed.value.server.server_ip);
    try std.testing.expectEqual(@as(u8, '\n'), bytes[bytes.len - 1]);
}

test "render preserves hyphenated APT fallback" {
    const allocator = std.testing.allocator;
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.50.1" },
        .profiles = &.{.{
            .name = "strict-ubuntu",
            .mode = .install,
            .distro = "ubuntu",
            .version = "22.04",
            .arch = .aarch64,
            .install = .{ .apt = .{ .fallback = .abort } },
        }},
    };
    const bytes = try render(allocator, &config);
    defer allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"fallback\": \"abort\"") != null);
}
