//! Strict startup configuration DTO for schema 3.
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
    return .{ .server = config.server, .http = config.http, .tftp = config.tftp, .dhcp = config.dhcp, .capacity = config.capacity, .logging = config.logging, .events = config.events };
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(model.AppConfig) {
    var source = try std.json.parseFromSlice(Startup, allocator, bytes, .{ .allocate = .alloc_always });
    defer source.deinit();
    if (source.value.schema_version != 3) return error.InvalidSchemaV3Config;
    const runtime: model.AppConfig = .{ .schema_version = 3, .server = source.value.server, .http = source.value.http, .tftp = source.value.tftp, .dhcp = source.value.dhcp, .capacity = source.value.capacity, .logging = source.value.logging, .events = source.value.events };
    const projected = try std.json.Stringify.valueAlloc(allocator, runtime, .{});
    defer allocator.free(projected);
    return std.json.parseFromSlice(model.AppConfig, allocator, projected, .{ .allocate = .alloc_always });
}

test "strict startup schema rejects legacy unknown policy" {
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Startup, std.testing.allocator, "{\"schema_version\":3,\"server\":{\"server_ip\":\"192.0.2.1\"},\"policy\":{}}", .{}));
}
