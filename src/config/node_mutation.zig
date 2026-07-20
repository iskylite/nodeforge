//! M4.7 节点实体 mutation。
//!
//! 节点只写 daemon-owned catalog；`config.json` 仅作为只读启动/策略输入。
//! catalog store 负责 entity stage + journal + manifest-last 提交，因此一次节点
//! 变更不会重写无关实体文件，也不会暴露 mixed generation。

const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const validate = @import("validate.zig");

pub const AddParams = struct {
    id: []const u8,
    mac: []const u8,
    arch: model.Arch,
    profile: []const u8,
    ip: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    deploy: bool = true,
    http_accel: bool = false,
    boot_disk: ?[]const u8 = null,
    install_disks: ?[]const []const u8 = null,
};
pub const SetParams = struct {
    mac: ?[]const u8 = null,
    arch: ?model.Arch = null,
    profile: ?[]const u8 = null,
    ip: ?[]const u8 = null,
    ip_set: bool = false,
    hostname: ?[]const u8 = null,
    hostname_set: bool = false,
    deploy: ?bool = null,
    http_accel: ?bool = null,
    boot_disk: ?[]const u8 = null,
    boot_disk_set: bool = false,
    install_disks: ?[]const []const u8 = null,
    install_disks_set: bool = false,
};

pub fn addNode(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, params: AddParams) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    for (parsed.value.nodes) |node| {
        if (std.mem.eql(u8, node.id, params.id)) return error.NodeAlreadyExists;
        if (std.mem.eql(u8, node.mac, params.mac)) return error.DuplicateMac;
    }
    if (!profileExists(&parsed.value, params.profile)) return error.ProfileNotFound;
    const nodes = try allocator.alloc(model.NodeConfig, parsed.value.nodes.len + 1);
    defer allocator.free(nodes);
    @memcpy(nodes[0..parsed.value.nodes.len], parsed.value.nodes);
    nodes[parsed.value.nodes.len] = .{ .id = params.id, .mac = params.mac, .arch = params.arch, .profile = params.profile, .ip = params.ip, .hostname = params.hostname, .deploy = params.deploy, .http_accel = params.http_accel, .overrides = .{ .storage = if (params.boot_disk != null or params.install_disks != null) .{ .boot_disk = params.boot_disk, .install_disks = params.install_disks } else null } };
    var candidate = parsed.value;
    candidate.nodes = nodes;
    try validateCandidate(config, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

pub fn setNode(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, node_id: []const u8, params: SetParams) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    var index: ?usize = null;
    for (parsed.value.nodes, 0..) |node, i| if (std.mem.eql(u8, node.id, node_id)) {
        index = i;
        break;
    };
    const target = index orelse return error.NodeNotFound;
    if (params.mac) |mac| for (parsed.value.nodes, 0..) |node, i| if (i != target and std.mem.eql(u8, node.mac, mac)) return error.DuplicateMac;
    if (params.profile) |profile| if (!profileExists(&parsed.value, profile)) return error.ProfileNotFound;
    const nodes = try allocator.dupe(model.NodeConfig, parsed.value.nodes);
    defer allocator.free(nodes);
    var node = nodes[target];
    if (params.mac) |value| node.mac = value;
    if (params.arch) |value| node.arch = value;
    if (params.profile) |value| node.profile = value;
    if (params.ip_set) node.ip = params.ip;
    if (params.hostname_set) node.hostname = params.hostname;
    if (params.deploy) |value| node.deploy = value;
    if (params.http_accel) |value| node.http_accel = value;
    if (params.boot_disk_set or params.install_disks_set) {
        var storage = node.overrides.storage orelse model.NodeStorageOverrideConfig{};
        if (params.boot_disk_set) storage.boot_disk = params.boot_disk;
        if (params.install_disks_set) storage.install_disks = params.install_disks;
        node.overrides.storage = if (storage.boot_disk == null and storage.install_disks == null) null else storage;
    }
    nodes[target] = node;
    var candidate = parsed.value;
    candidate.nodes = nodes;
    try validateCandidate(config, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

pub fn removeNode(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, node_id: []const u8) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    var target: ?usize = null;
    for (parsed.value.nodes, 0..) |node, i| if (std.mem.eql(u8, node.id, node_id)) {
        target = i;
        break;
    };
    const remove = target orelse return error.NodeNotFound;
    const nodes = try allocator.alloc(model.NodeConfig, parsed.value.nodes.len - 1);
    defer allocator.free(nodes);
    var write: usize = 0;
    for (parsed.value.nodes, 0..) |node, i| if (i != remove) {
        nodes[write] = node;
        write += 1;
    };
    var candidate = parsed.value;
    candidate.nodes = nodes;
    try validateCandidate(config, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

fn validateCandidate(config: *const model.AppConfig, catalog: *const model.Catalog) !void {
    const projected = model.projectCatalog(config.*, catalog);
    try validate.validate(&projected, catalog);
}
fn profileExists(catalog: *const model.Catalog, name: []const u8) bool {
    for (catalog.profiles) |profile| if (std.mem.eql(u8, profile.name, name)) return true;
    return false;
}
