//! schema 3 和 4 的严格启动配置 DTO。持久化的配置
//! 形态两版一致；只有 schema_version 标记不同
//! （v4 携带 diskless catalog，位于 catalog 目录中）。
const std = @import("std");
const model = @import("../model.zig");

pub const Startup = struct {
    schema_version: u32 = 3,
    server: model.ServerConfig,
    http: model.HttpConfig = .{},
    tftp: model.TftpConfig = .{},
    dhcp: model.DhcpConfig = .{},
    capacity: model.CapacityConfig = .{},
    logging: model.LoggingConfig = .{},
    events: model.EventsConfig = .{},
};

pub fn fromModel(config: *const model.AppConfig) Startup {
    return .{ .schema_version = config.schema_version, .server = config.server, .http = config.http, .tftp = config.tftp, .dhcp = config.dhcp, .capacity = config.capacity, .logging = config.logging, .events = config.events };
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(model.AppConfig) {
    var source = try std.json.parseFromSlice(Startup, allocator, bytes, .{ .allocate = .alloc_always });
    defer source.deinit();
    if (source.value.schema_version != 3 and source.value.schema_version != 4) return error.InvalidSchemaV3Config;
    const runtime: model.AppConfig = .{ .schema_version = source.value.schema_version, .server = source.value.server, .http = source.value.http, .tftp = source.value.tftp, .dhcp = source.value.dhcp, .capacity = source.value.capacity, .logging = source.value.logging, .events = source.value.events };
    const projected = try std.json.Stringify.valueAlloc(allocator, runtime, .{});
    defer allocator.free(projected);
    return std.json.parseFromSlice(model.AppConfig, allocator, projected, .{ .allocate = .alloc_always });
}

test "strict startup schema rejects legacy unknown policy" {
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Startup, std.testing.allocator, "{\"schema_version\":3,\"server\":{\"server_ip\":\"192.0.2.1\"},\"policy\":{}}", .{}));
}

test "v4 startup config round-trips preserving schema_version" {
    const json = "{\"schema_version\":4,\"server\":{\"server_ip\":\"192.0.2.1\"}}";
    var parsed = try parse(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 4), parsed.value.schema_version);
    try std.testing.expectEqualStrings("192.0.2.1", parsed.value.server.server_ip);
    const rendered = try std.json.Stringify.valueAlloc(std.testing.allocator, fromModel(&parsed.value), .{ .whitespace = .indent_2 });
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"schema_version\": 4") != null);
}
