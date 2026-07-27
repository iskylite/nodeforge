//! 只读启动 schema 1/2 DTO，用于进入 schema-v3 迁移。
const std = @import("std");
const model = @import("../model.zig");
const catalog_v2 = @import("../catalog/schema_v2_dto.zig");

/// schema 1/2 的迁移输入。旧单值 SSH key 在解析后立即提升为 canonical 数组，
/// 不进入 runtime model，也不会被当前 schema 写回。
const ServerInput = struct {
    name: []const u8 = "nodeforge",
    bind_interface: ?[]const u8 = null,
    server_ip: []const u8,
    http_port: u16 = 18080,
    ssh_authorized_public_key: ?[]const u8 = null,
    ssh_authorized_public_keys: []const []const u8 = &.{},
};

const Startup = struct {
    schema_version: u32,
    server: ServerInput,
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
    const input_server = source.value.server;
    // 已存在数组时以数组为唯一事实源；否则迁移旧单值，保持确定性顺序。
    const keys = if (input_server.ssh_authorized_public_keys.len != 0)
        input_server.ssh_authorized_public_keys
    else if (input_server.ssh_authorized_public_key) |key| blk: {
        const migrated = try source.arena.allocator().alloc([]const u8, 1);
        migrated[0] = key;
        break :blk migrated;
    } else &.{};
    const runtime: model.AppConfig = .{
        .schema_version = source.value.schema_version,
        .server = .{ .name = input_server.name, .bind_interface = input_server.bind_interface, .server_ip = input_server.server_ip, .http_port = input_server.http_port, .ssh_authorized_public_keys = keys },
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

test "schema two single SSH key migrates to canonical key array" {
    var parsed = try parse(std.testing.allocator, "{\"schema_version\":2,\"server\":{\"server_ip\":\"192.0.2.1\",\"ssh_authorized_public_key\":\"ssh-ed25519 key\"}}");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ssh-ed25519 key", parsed.value.server.ssh_authorized_public_keys[0]);
}
