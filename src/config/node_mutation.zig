//! M4.7 节点实体 mutation。
//!
//! 节点只写 daemon-owned catalog；`config.json` 仅作为只读启动/策略输入。
//! catalog store 负责 entity stage + journal + manifest-last 提交，因此一次节点
//! 变更不会重写无关实体文件，也不会暴露 mixed generation。

const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const validate = @import("validate.zig");

/// `node add` 命令的参数集。所有字符串由调用方拥有，mutation 期间不释放。
pub const AddParams = struct {
    /// 节点 ID（canonical logical-id）。
    id: []const u8,
    /// 网卡 MAC 地址（冒号分隔）。
    mac: []const u8,
    /// 节点架构。
    arch: model.Arch,
    /// 绑定的 profile 名称；null 且 `deploy=true` 时返回错误。
    profile: ?[]const u8,
    /// PXE 静态保留 IP；null 时从 DHCP 地址池动态分配。
    pxe_ip_reservation: ?[]const u8 = null,
    /// 节点 hostname；null 时回退到 node.id。
    hostname: ?[]const u8 = null,
    /// 创建时一并设置的 Node 级策略覆盖。
    overrides: model.NodeOverrideConfig = .{},
    /// 是否参与 PXE 部署。
    deploy: bool = true,
    /// 是否使用 HTTP 加速 initrd 下载。
    http_accel: bool = false,
    /// 物理设备存储配置。
    storage: model.NodeStorageConfig = .{},
    /// 目标系统网络配置。
    network: model.TargetNetworkConfig = .{},
};
/// `node set` 命令的参数集。每对 `_set`/value 控制是否覆盖对应字段。
pub const SetParams = struct {
    /// 新 MAC 地址；null 不修改。
    mac: ?[]const u8 = null,
    /// 新架构；null 不修改。
    arch: ?model.Arch = null,
    /// 新 profile 名称；null 不修改。空字符串显式解绑。
    profile: ?[]const u8 = null,
    /// hostname 值。
    hostname: ?[]const u8 = null,
    /// hostname 是否被显式设置。
    hostname_set: bool = false,
    /// deploy 开关。
    deploy: ?bool = null,
    /// http_accel 开关。
    http_accel: ?bool = null,
    /// boot_disk 设备路径。
    boot_disk: ?[]const u8 = null,
    /// boot_disk 是否被显式设置。
    boot_disk_set: bool = false,
};

/// 向 catalog 原子添加一个节点。执行 load-duplicate-check-validate-save 事务。
/// 重复 ID 或 MAC 返回错误；`deploy=true` 但 `profile=null` 返回错误。
pub fn addNode(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, params: AddParams) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    for (parsed.value.nodes) |node| {
        if (std.mem.eql(u8, node.id, params.id)) return error.NodeAlreadyExists;
        if (std.mem.eql(u8, node.mac, params.mac)) return error.DuplicateMac;
    }
    if (params.profile) |profile| if (!profileExists(&parsed.value, profile)) return error.ProfileNotFound;
    if (params.profile == null and params.deploy) return error.ProfileRequiredWhileDeployed;
    const nodes = try allocator.alloc(model.NodeConfig, parsed.value.nodes.len + 1);
    defer allocator.free(nodes);
    @memcpy(nodes[0..parsed.value.nodes.len], parsed.value.nodes);
    nodes[parsed.value.nodes.len] = .{ .id = params.id, .mac = params.mac, .arch = params.arch, .profile = params.profile, .pxe = .{ .ip_reservation = params.pxe_ip_reservation }, .hostname = params.hostname, .overrides = params.overrides, .deploy = params.deploy, .http_accel = params.http_accel, .storage = params.storage, .network = params.network };
    var candidate = parsed.value;
    candidate.nodes = nodes;
    try validateCandidate(config, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

/// 修改已有节点的属性。执行 load-find-patch-validate-save 事务。
/// `_set` 标志区分 null=不修改 vs null=显式清空。
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
    if (params.hostname_set) node.hostname = params.hostname;
    if (params.deploy) |value| node.deploy = value;
    if (params.http_accel) |value| node.http_accel = value;
    if (params.boot_disk_set) node.storage.boot_disk = params.boot_disk orelse return error.InvalidInstallStorage;
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
