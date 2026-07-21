//! 加载 NodeForge 唯一配置事实源。
//! 返回值拥有全部字符串；调用者必须执行 `deinit`，不得长期保存其中的裸指针。
//! 本模块不校验配置语义——校验由 `config/validate.zig` 在加载后统一执行。

const std = @import("std");
const model = @import("../model.zig");
const paths = @import("../paths.zig");
const schema_v3_dto = @import("schema_v3_dto.zig");
const schema_v2_dto = @import("schema_v2_dto.zig");

/// 默认启动配置路径。必须在进程路径自举完成后调用。
pub fn defaultPath() []const u8 {
    return paths.require().config_path;
}
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

    const Header = struct { schema_version: u32 };
    const header = try std.json.parseFromSlice(Header, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer header.deinit();
    var parsed = if (header.value.schema_version == 3)
        try schema_v3_dto.parse(allocator, bytes)
    else
        try schema_v2_dto.parse(allocator, bytes);
    canonicalizeKernelArgs(&parsed.value);
    return parsed;
}

/// M4.6 canonical 形式：去掉首尾 ASCII 空格、把连续空格折叠为一个，空结果
/// 表示为 null。解析后的字符串由 JSON arena 持有，因此原地压缩不会改变所有权。
pub fn canonicalizeKernelArgs(config: *model.AppConfig) void {
    const profiles = @constCast(config.profiles);
    for (profiles) |*profile| {
        const value = profile.kernel_args orelse continue;
        const bytes = @constCast(value);
        var read: usize = 0;
        var write: usize = 0;
        var pending_space = false;
        while (read < bytes.len) : (read += 1) {
            if (bytes[read] == ' ') {
                if (write != 0) pending_space = true;
                continue;
            }
            if (pending_space) {
                bytes[write] = ' ';
                write += 1;
                pending_space = false;
            }
            bytes[write] = bytes[read];
            write += 1;
        }
        profile.kernel_args = if (write == 0) null else bytes[0..write];
    }
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
    try std.testing.expectEqual(@as(u16, 18080), parsed.value.server.http_port);
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

test "APT fallback accepts schema-compatible hyphenated values" {
    const parsed = try std.json.parseFromSlice(
        model.InstallConfig,
        std.testing.allocator,
        \\{"apt":{"fallback":"abort"}}
    ,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(model.AptFallback.abort, parsed.value.apt.fallback);

    const default_parsed = try std.json.parseFromSlice(model.InstallConfig, std.testing.allocator, "{}", .{});
    defer default_parsed.deinit();
    try std.testing.expectEqual(model.AptFallback.@"offline-install", default_parsed.value.apt.fallback);
}

test "M4.2 target users default unless explicitly empty" {
    const omitted = try std.json.parseFromSlice(model.TargetSystemConfig, std.testing.allocator, "{}", .{});
    defer omitted.deinit();
    try std.testing.expectEqual(@as(usize, 1), omitted.value.users.len);
    try std.testing.expectEqualStrings("nodeforge", omitted.value.users[0].name);
    try std.testing.expectEqualStrings("asdf1234", omitted.value.users[0].password.?);
    try std.testing.expect(omitted.value.users[0].sudo);

    const empty = try std.json.parseFromSlice(model.TargetSystemConfig, std.testing.allocator, "{\"users\":[]}", .{});
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.users.len);
}

test "M4.6 load canonicalizes kernel args" {
    var parsed = try std.json.parseFromSlice(
        model.AppConfig,
        std.testing.allocator,
        \\{"server":{"server_ip":"192.168.50.1"},"profiles":[{"name":"p","install_source":"ubuntu","kernel_args":"  iommu=pt   isolcpus=0,2  "},{"name":"empty","install_source":"rocky","kernel_args":"   "}]}
    ,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    canonicalizeKernelArgs(&parsed.value);
    try std.testing.expectEqualStrings("iommu=pt isolcpus=0,2", parsed.value.profiles[0].kernel_args.?);
    try std.testing.expect(parsed.value.profiles[1].kernel_args == null);
}
