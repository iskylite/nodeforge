//! # 持久化未知客户端观察与原子认领操作
//!
//! 管理未知 DHCP 客户端的观察记录和原子认领操作。
//! 认领将观察记录转换为 Node，使用乐观并发控制防止竞争。
const std = @import("std");
const model = @import("../model.zig");

/// 原子认领请求参数。
pub const Claim = struct {
    /// 要创建或绑定的 Node ID。
    node_id: []const u8,
    /// 观察到的客户端 MAC 地址。
    mac: []const u8,
    /// 客户端架构。
    arch: model.Arch,
    /// 预期的观察记录 revision，用于乐观并发控制。
    expected_observation_revision: u64,
    /// 认领操作的 Unix 时间戳（秒）。
    claimed_at_unix: i64,
};

/// 原子认领未知 DHCP 客户端为 Node。
///
/// 执行以下检查：
/// 1. 观察记录存在且 revision 匹配（乐观并发控制）。
/// 2. 观察记录未被认领。
/// 3. MAC 未被其他 Node 占用。
///
/// 成功后创建/更新 Node 并标记观察记录为已认领。
pub fn claim(allocator: std.mem.Allocator, catalog: *model.Catalog, request: Claim) !void {
    var observation_index: ?usize = null;
    for (catalog.unknown_client_observations, 0..) |observation, index| {
        if (sameMac(observation.mac, request.mac)) {
            observation_index = index;
            if (observation.revision != request.expected_observation_revision) return error.ObservationRevisionConflict;
            if (observation.claim != null) return error.ObservationAlreadyClaimed;
            break;
        }
    }
    const oi = observation_index orelse return error.ObservationNotFound;

    var node_index: ?usize = null;
    for (catalog.nodes, 0..) |node, index| {
        if (std.mem.eql(u8, node.id, request.node_id)) node_index = index;
        if (sameMac(node.mac, request.mac) and !std.mem.eql(u8, node.id, request.node_id)) return error.MacAlreadyClaimed;
    }

    const observations = try allocator.dupe(model.UnknownClientObservation, catalog.unknown_client_observations);
    errdefer allocator.free(observations);
    observations[oi].claim = .{ .node_id = request.node_id, .claimed_at_unix = request.claimed_at_unix };
    observations[oi].revision += 1;

    var nodes: []model.NodeConfig = undefined;
    if (node_index) |index| {
        nodes = try allocator.dupe(model.NodeConfig, catalog.nodes);
        errdefer allocator.free(nodes);
        if (nodes[index].profile != null or nodes[index].deploy) return error.NodeNotClaimable;
        nodes[index].mac = request.mac;
        nodes[index].arch = request.arch;
    } else {
        nodes = try allocator.alloc(model.NodeConfig, catalog.nodes.len + 1);
        errdefer allocator.free(nodes);
        @memcpy(nodes[0..catalog.nodes.len], catalog.nodes);
        nodes[catalog.nodes.len] = .{
            .id = request.node_id,
            .mac = request.mac,
            .arch = request.arch,
            .profile = null,
            .deploy = false,
        };
    }

    // 将两个数组一起发布到调用方的 catalog 事务中。
    catalog.nodes = nodes;
    catalog.unknown_client_observations = observations;
}

fn sameMac(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

test "claim creates an unassigned disarmed Node and retains claimed audit" {
    var catalog: model.Catalog = .{ .unknown_client_observations = &.{.{
        .mac = "02:00:00:00:00:01",
        .first_seen_unix = 10,
        .last_seen_unix = 20,
        .revision = 4,
    }} };
    try claim(std.testing.allocator, &catalog, .{
        .node_id = "node-01",
        .mac = "02:00:00:00:00:01",
        .arch = .x86_64,
        .expected_observation_revision = 4,
        .claimed_at_unix = 30,
    });
    defer std.testing.allocator.free(catalog.nodes);
    defer std.testing.allocator.free(catalog.unknown_client_observations);
    try std.testing.expectEqual(@as(usize, 1), catalog.nodes.len);
    try std.testing.expect(catalog.nodes[0].profile == null);
    try std.testing.expect(!catalog.nodes[0].deploy);
    try std.testing.expectEqualStrings("node-01", catalog.unknown_client_observations[0].claim.?.node_id);
    try std.testing.expectEqual(@as(u64, 5), catalog.unknown_client_observations[0].revision);
}

test "claim is guarded by observation revision and node state" {
    const observations = [_]model.UnknownClientObservation{.{ .mac = "02:00:00:00:00:02", .first_seen_unix = 1, .last_seen_unix = 1, .revision = 2 }};
    const nodes = [_]model.NodeConfig{.{ .id = "node-02", .mac = "02:00:00:00:00:99", .arch = .x86_64, .profile = "profile", .deploy = false }};
    var catalog: model.Catalog = .{ .nodes = &nodes, .unknown_client_observations = &observations };
    const base: Claim = .{ .node_id = "node-02", .mac = "02:00:00:00:00:02", .arch = .x86_64, .expected_observation_revision = 1, .claimed_at_unix = 3 };
    try std.testing.expectError(error.ObservationRevisionConflict, claim(std.testing.allocator, &catalog, base));
    var current = base;
    current.expected_observation_revision = 2;
    try std.testing.expectError(error.NodeNotClaimable, claim(std.testing.allocator, &catalog, current));
}
