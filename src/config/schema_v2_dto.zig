//! 只读启动 schema 1/2 DTO，用于进入 schema-v3 迁移。
const std = @import("std");
const model = @import("../model.zig");
const catalog_v2 = @import("../catalog/schema_v2_dto.zig");

const Startup = struct {
    schema_version: u32,
    server: model.ServerConfig,
    http: model.HttpConfig = .{},
    tftp: model.TftpConfig = .{},
    dhcp: model.DhcpConfig = .{},
    capacity: model.CapacityConfig = .{},
    logging: model.LoggingConfig = .{},
    events: model.EventsConfig = .{},
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(model.AppConfig) {
    var source = try std.json.parseFromSlice(Startup, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer source.deinit();
    if (source.value.schema_version != 1 and source.value.schema_version != 2) return error.InvalidLegacyStartupSchema;
    var entities = try catalog_v2.parse(allocator, bytes);
    defer entities.deinit();
    const runtime: model.AppConfig = .{
        .schema_version = source.value.schema_version,
        .server = source.value.server,
        .http = source.value.http,
        .tftp = source.value.tftp,
        .dhcp = source.value.dhcp,
        .capacity = source.value.capacity,
        .logging = source.value.logging,
        .events = source.value.events,
        .distros = entities.value.distros,
        .profiles = entities.value.profiles,
        .nodes = entities.value.nodes,
        .provisioning_bundles = entities.value.provisioning_bundles,
    };
    const projected = try std.json.Stringify.valueAlloc(allocator, runtime, .{});
    defer allocator.free(projected);
    return std.json.parseFromSlice(model.AppConfig, allocator, projected, .{ .allocate = .alloc_always });
}

test "legacy unknown policy is accepted but not projected" {
    var parsed = try parse(std.testing.allocator, "{\"schema_version\":2,\"server\":{\"server_ip\":\"192.0.2.1\"},\"policy\":{\"default_action\":\"discovery\"}}");
    defer parsed.deinit();
    const rendered = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "policy") == null);
}
