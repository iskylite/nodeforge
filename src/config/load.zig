//! 加载 NodeForge 唯一配置事实源。
//! 返回值拥有全部字符串；调用者必须执行 `deinit`，不得长期保存其中的裸指针。
//! 本模块不校验配置语义——校验由 `config/validate.zig` 在加载后统一执行。

const std = @import("std");
const model = @import("../model.zig");
const paths = @import("../paths.zig");

/// 默认启动配置路径。正常安装时无需传参，守护进程会自动读取此位置。
pub const default_path = paths.config_path;
/// 配置文件最大允许 4 MiB，防止错误路径或异常文件耗尽内存。
pub const max_config_bytes = 4 * 1024 * 1024;

/// 读取并解析配置文件。
///
/// 文件缓冲区在函数返回前释放，因此解析器必须复制所有字符串；返回的
/// `Parsed` 对象拥有这些内存，并由调用者负责 `deinit`。
pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(model.AppConfig) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_config_bytes),
    );
    defer allocator.free(bytes);

    return std.json.parseFromSlice(model.AppConfig, allocator, bytes, .{
        .allocate = .alloc_always,
    });
}

test "load parses a minimal config" {
    const parsed = try std.json.parseFromSlice(
        model.AppConfig,
        std.testing.allocator,
        \\{"schema_version":1,"server":{"server_ip":"192.168.50.1"}}
    ,
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("192.168.50.1", parsed.value.server.server_ip);
    try std.testing.expectEqual(@as(u16, 8080), parsed.value.server.http_port);
}

test "parsed strings do not borrow the input buffer" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8,
        \\{"schema_version":1,"server":{"server_ip":"192.168.50.1"}}
    );
    defer allocator.free(source);

    const parsed = try std.json.parseFromSlice(model.AppConfig, allocator, source, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    @memset(source, 'x');
    try std.testing.expectEqualStrings("192.168.50.1", parsed.value.server.server_ip);
}
