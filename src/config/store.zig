//! 配置序列化和原子写回。
//! 始终先写同目录临时文件并同步内容，再通过 rename 替换事实源。
//! 本模块不校验配置语义——调用者必须在写回前完成校验。

const std = @import("std");
const model = @import("../model.zig");

/// 磁盘 `config.json` 的唯一可序列化形状。AppConfig 中保留的 legacy 管理实体
/// 只用于 schema 1 迁移/运行时投影，绝不能被 daemon 写回启动配置。
const StartupConfig = struct {
    schema_version: u32 = 2,
    server: model.ServerConfig,
    http: model.HttpConfig,
    tftp: model.TftpConfig,
    dhcp: model.DhcpConfig,
    capacity: model.CapacityConfig,
    logging: model.LoggingConfig,
    events: model.EventsConfig,
    policy: model.PolicyConfig,
};

/// 将配置格式化为稳定、便于审阅的 JSON，并在末尾补换行。
/// 返回内存归调用者所有。
pub fn render(allocator: std.mem.Allocator, config: *const model.AppConfig) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    const startup: StartupConfig = .{
        .server = config.server,
        .http = config.http,
        .tftp = config.tftp,
        .dhcp = config.dhcp,
        .capacity = config.capacity,
        .logging = config.logging,
        .events = config.events,
        .policy = config.policy,
    };
    try std.json.Stringify.value(startup, .{ .whitespace = .indent_2 }, &output.writer);
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
    try chmod(io, allocator, "600", path);
}

fn chmod(io: std.Io, allocator: std.mem.Allocator, mode: []const u8, path: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "chmod", mode, path }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ChmodFailed,
        else => return error.ChmodFailed,
    }
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

test "M4.7 render excludes legacy catalog-owned entities" {
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"profiles\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"schema_version\": 2") != null);
}
