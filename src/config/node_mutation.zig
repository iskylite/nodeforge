//! M4.2 F6: 节点资源的增删改（node add/set/remove）。
//!
//! 采用 CLI 直接操作 config.json 的方式（与 config import 一致），
//! 写回后由 CLI 调用 `POST /management/config/reload` 通知 daemon 重新加载。
//! 这样避免修改 RouteContext 的 const 语义和线程安全问题。
//!
//! 每个 mutation 函数：load config -> 修改 nodes 数组 -> validateConfig -> save。
//! 任何步骤失败都不会破坏旧配置（save 使用 tmp+sync+rename 原子写）。

const std = @import("std");
const model = @import("../model.zig");
const config_load = @import("load.zig");
const config_store = @import("store.zig");
const config_validate = @import("validate.zig");

/// `node add` 的输入参数。
pub const AddParams = struct {
    id: []const u8,
    mac: []const u8,
    arch: model.Arch,
    profile: []const u8,
    ip: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    deploy: bool = true,
    /// M4.2 F4: HTTP 加速下载 kernel/initrd（默认开启）。
    /// 参见 `model.NodeConfig.http_accel` 字段说明。
    http_accel: bool = false,
};

/// `node set` 的可选修改字段。null 表示不修改。
pub const SetParams = struct {
    mac: ?[]const u8 = null,
    arch: ?model.Arch = null,
    profile: ?[]const u8 = null,
    ip: ?[]const u8 = null, // 注意: null 表示"不修改"，不是"清空"
    ip_set: bool = false, // true 时 ip 字段有意义（含 null=清空）
    hostname: ?[]const u8 = null,
    hostname_set: bool = false,
    deploy: ?bool = null,
    /// M4.2 F4: HTTP 加速开关。null 表示不修改。
    http_accel: ?bool = null,
};

/// 添加节点。校验 id 唯一、mac 不重复、profile 存在后原子写回 config.json。
pub fn addNode(
    io: std.Io,
    allocator: std.mem.Allocator,
    config_path: []const u8,
    params: AddParams,
) !void {
    var parsed = try config_load.load(io, allocator, config_path);
    defer parsed.deinit();
    const config = &parsed.value;

    // 校验 id 唯一
    for (config.nodes) |n| {
        if (std.mem.eql(u8, n.id, params.id)) return error.NodeAlreadyExists;
        if (std.mem.eql(u8, n.mac, params.mac)) return error.DuplicateMac;
    }
    // 校验 profile 存在
    if (!profileExists(config, params.profile)) return error.ProfileNotFound;

    // 分配新数组 (len+1)
    const new_nodes = try allocator.alloc(model.NodeConfig, config.nodes.len + 1);
    defer allocator.free(new_nodes);
    @memcpy(new_nodes[0..config.nodes.len], config.nodes);
    new_nodes[config.nodes.len] = .{
        .id = params.id,
        .mac = params.mac,
        .arch = params.arch,
        .profile = params.profile,
        .ip = params.ip,
        .hostname = params.hostname,
        .deploy = params.deploy,
        .http_accel = params.http_accel,
    };

    // 构造候选 config 并校验
    var candidate = config.*;
    candidate.nodes = new_nodes;
    try config_validate.validateConfig(&candidate);
    try config_store.save(io, allocator, config_path, &candidate);
}

/// 修改节点属性。找到 node_id 后按 SetParams 修改字段，校验后原子写回。
pub fn setNode(
    io: std.Io,
    allocator: std.mem.Allocator,
    config_path: []const u8,
    node_id: []const u8,
    params: SetParams,
) !void {
    var parsed = try config_load.load(io, allocator, config_path);
    defer parsed.deinit();
    const config = &parsed.value;

    // 找到节点索引
    var idx: ?usize = null;
    for (config.nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, node_id)) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return error.NodeNotFound;

    // 如果改了 mac，校验不重复
    if (params.mac) |new_mac| {
        for (config.nodes, 0..) |n, j| {
            if (j != i and std.mem.eql(u8, n.mac, new_mac)) return error.DuplicateMac;
        }
    }
    // 如果改了 profile，校验存在
    if (params.profile) |new_profile| {
        if (!profileExists(config, new_profile)) return error.ProfileNotFound;
    }

    // 复制 nodes 数组（const slice -> mutable copy）
    const new_nodes = try allocator.alloc(model.NodeConfig, config.nodes.len);
    defer allocator.free(new_nodes);
    @memcpy(new_nodes, config.nodes);

    // 修改目标节点
    var node = new_nodes[i];
    if (params.mac) |v| node.mac = v;
    if (params.arch) |v| node.arch = v;
    if (params.profile) |v| node.profile = v;
    if (params.ip_set) node.ip = params.ip;
    if (params.hostname_set) node.hostname = params.hostname;
    if (params.deploy) |v| node.deploy = v;
    if (params.http_accel) |v| node.http_accel = v;
    new_nodes[i] = node;

    // 构造候选 config 并校验
    var candidate = config.*;
    candidate.nodes = new_nodes;
    try config_validate.validateConfig(&candidate);
    try config_store.save(io, allocator, config_path, &candidate);
}

/// 移除节点。找到 node_id 后从数组删除，校验后原子写回。
pub fn removeNode(
    io: std.Io,
    allocator: std.mem.Allocator,
    config_path: []const u8,
    node_id: []const u8,
) !void {
    var parsed = try config_load.load(io, allocator, config_path);
    defer parsed.deinit();
    const config = &parsed.value;

    // 找到节点索引
    var idx: ?usize = null;
    for (config.nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, node_id)) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return error.NodeNotFound;

    // 分配新数组 (len-1)
    const new_nodes = try allocator.alloc(model.NodeConfig, config.nodes.len - 1);
    defer allocator.free(new_nodes);
    // 复制除目标外的所有节点
    var dst: usize = 0;
    for (config.nodes, 0..) |n, src| {
        if (src == i) continue;
        new_nodes[dst] = n;
        dst += 1;
    }

    // 构造候选 config 并校验
    var candidate = config.*;
    candidate.nodes = new_nodes;
    try config_validate.validateConfig(&candidate);
    try config_store.save(io, allocator, config_path, &candidate);
}

fn profileExists(config: *const model.AppConfig, name: []const u8) bool {
    for (config.profiles) |p| {
        if (std.mem.eql(u8, p.name, name)) return true;
    }
    return false;
}
