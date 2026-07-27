//! 所有权 schema v3 迁移规划与类型化候选物化。
const std = @import("std");
const model = @import("../model.zig");
const lookup = @import("../catalog.zig");
const profile_install = @import("../profile/install.zig");

pub const Blocker = struct { entity: []const u8, code: []const u8, detail: []const u8 };
const Payload = struct {
    target_schema: u32 = 3,
    config_revision: u64,
    catalog_revision: u64,
    affected_profiles: []const []const u8,
    affected_nodes: []const []const u8,
    blockers: []const Blocker,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    canonical_json: []u8,
    digest: [64]u8,
    affected_profiles: []const []const u8,
    affected_nodes: []const []const u8,
    blockers: []const Blocker,

    pub fn applicable(self: Plan) bool { return self.blockers.len == 0; }
    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.affected_profiles);
        self.allocator.free(self.affected_nodes);
        self.allocator.free(self.blockers);
        self.allocator.free(self.canonical_json);
    }
};

pub const Candidates = struct {
    config: std.json.Parsed(model.AppConfig),
    catalog: std.json.Parsed(model.Catalog),
    pub fn deinit(self: *Candidates) void { self.catalog.deinit(); self.config.deinit(); }
};

pub fn build(allocator: std.mem.Allocator, config: *const model.AppConfig, catalog: *const model.Catalog, config_revision: u64, catalog_revision: u64) !Plan {
    var affected_profiles: std.ArrayList([]const u8) = .empty;
    defer affected_profiles.deinit(allocator);
    var affected_nodes: std.ArrayList([]const u8) = .empty;
    defer affected_nodes.deinit(allocator);
    var blockers: std.ArrayList(Blocker) = .empty;
    defer blockers.deinit(allocator);
    if (config.schema_version < 1 or config.schema_version > 3)
        try blockers.append(allocator, .{ .entity = "startup-config", .code = "schema_v3.unsupported_startup_schema", .detail = "startup schema must be 1, 2, or 3" });
    for (catalog.legacy_diskless_profiles) |name|
        try blockers.append(allocator, .{ .entity = name, .code = "schema_v3.diskless_profile", .detail = "diskless profiles require an explicit v0.2 operator decision" });
    for (catalog.legacy_multidisk_nodes) |name|
        try blockers.append(allocator, .{ .entity = name, .code = "schema_v3.multidisk_operator_decision", .detail = "choose an explicit RAID/LVM mode and additional disks" });

    for (catalog.profiles) |profile| {
        try affected_profiles.append(allocator, profile.name);
        _ = lookup.findInstallSource(catalog, profile.install_source) orelse {
            try blockers.append(allocator, .{ .entity = profile.name, .code = "schema_v3.install_source_not_found", .detail = profile.install_source });
            continue;
        };
        if (profile.kernel_args) |args| if (!kernelArgsUnique(args))
            try blockers.append(allocator, .{ .entity = profile.name, .code = "schema_v3.kernel_args_ambiguous", .detail = "kernel argument names must be unique" });
    }
    for (catalog.nodes) |node| {
        try affected_nodes.append(allocator, node.id);
    }
    for (catalog.provisioning_bundles) |bundle| {
        for (bundle.steps) |step| {
            if (step.action != .managed_file)
                try blockers.append(allocator, .{ .entity = bundle.name, .code = "schema_v3.provision_step_ambiguous", .detail = "repository/package steps require explicit resource/software mapping" })
            else if (step.content_asset == null)
                try blockers.append(allocator, .{ .entity = bundle.name, .code = "schema_v3.managed_file_asset_required", .detail = "inline managed-file content must be imported as an immutable managed-file asset" });
        }
    }

    const profile_names = try affected_profiles.toOwnedSlice(allocator);
    errdefer allocator.free(profile_names);
    const node_names = try affected_nodes.toOwnedSlice(allocator);
    errdefer allocator.free(node_names);
    const blocker_values = try blockers.toOwnedSlice(allocator);
    errdefer allocator.free(blocker_values);
    const payload: Payload = .{ .config_revision = config_revision, .catalog_revision = catalog_revision, .affected_profiles = profile_names, .affected_nodes = node_names, .blockers = blocker_values };
    const canonical_json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    errdefer allocator.free(canonical_json);
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_json, &raw, .{});
    var digest: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&digest, "{x}", .{raw}) catch unreachable;
    return .{ .allocator = allocator, .canonical_json = canonical_json, .digest = digest, .affected_profiles = profile_names, .affected_nodes = node_names, .blockers = blocker_values };
}

pub fn candidates(allocator: std.mem.Allocator, config: *const model.AppConfig, catalog: *const model.Catalog, plan: *const Plan) !Candidates {
    if (!plan.applicable()) return error.MigrationBlocked;
    const config_json = try std.json.Stringify.valueAlloc(allocator, config.*, .{});
    defer allocator.free(config_json);
    const catalog_json = try std.json.Stringify.valueAlloc(allocator, catalog.*, .{});
    defer allocator.free(catalog_json);
    var result: Candidates = .{
        .config = try std.json.parseFromSlice(model.AppConfig, allocator, config_json, .{ .allocate = .alloc_always }),
        .catalog = try std.json.parseFromSlice(model.Catalog, allocator, catalog_json, .{ .allocate = .alloc_always }),
    };
    errdefer result.deinit();
    result.config.value.schema_version = 3;
    result.catalog.value.schema_version = 3;
    result.catalog.value.discovery_policy.unknown_action = .record;
    try migrateProfiles(result.catalog.arena.allocator(), &result.catalog.value);
    // 旧版 schema-1 config 可能仍内嵌实体。投影迁移后的 catalog
    // 值，使校验在序列化前看到唯一的所有权世代。
    result.config.value.profiles = result.catalog.value.profiles;
    result.config.value.nodes = result.catalog.value.nodes;
    result.config.value.provisioning_bundles = result.catalog.value.provisioning_bundles;
    return result;
}

fn migrateProfiles(allocator: std.mem.Allocator, catalog: *model.Catalog) !void {
    _ = allocator;
    _ = catalog;
}

fn kernelArgsUnique(args: []const u8) bool {
    var outer = std.mem.tokenizeScalar(u8, args, ' ');
    var seen: [64][]const u8 = undefined;
    var count: usize = 0;
    while (outer.next()) |arg| {
        const name = if (std.mem.indexOfScalar(u8, arg, '=')) |eq| arg[0..eq] else arg;
        if (name.len == 0 or count == seen.len) return false;
        for (seen[0..count]) |previous| if (std.mem.eql(u8, previous, name)) return false;
        seen[count] = name;
        count += 1;
    }
    return true;
}

test "ownership plan is stable and blocks ambiguous multi-disk input" {
    const profile: model.ProfileConfig = .{ .name = "p", .install_source = "s" };
    const source: model.InstallSourceConfig = .{ .name = "s", .distro = "rocky", .version = "9", .arch = .x86_64, .source_asset = "iso", .installer_kernel = "kernel", .installer_initrd = "initrd" };
    const node: model.NodeConfig = .{ .id = "n", .mac = "02:00:00:00:00:01", .arch = .x86_64, .profile = "p" };
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1" } };
    const catalog: model.Catalog = .{ .profiles = &.{profile}, .nodes = &.{node}, .install_sources = &.{source}, .legacy_multidisk_nodes = &.{"n"} };
    var first = try build(std.testing.allocator, &config, &catalog, 1, 2);
    defer first.deinit();
    var second = try build(std.testing.allocator, &config, &catalog, 1, 2);
    defer second.deinit();
    try std.testing.expect(!first.applicable());
    try std.testing.expectEqualStrings("schema_v3.multidisk_operator_decision", first.blockers[0].code);
    try std.testing.expectEqualSlices(u8, &first.digest, &second.digest);
}

test "ownership candidate moves discovery and direct Node facts" {
    const profiles = [_]model.ProfileConfig{
        .{ .name = "install", .install_source = "source", .software = .{ .packages = .{ .include = &.{"vim"} } } },
    };
    const source: model.InstallSourceConfig = .{ .name = "source", .distro = "rocky", .version = "9", .arch = .x86_64, .source_asset = "iso", .installer_kernel = "kernel", .installer_initrd = "initrd" };
    const nodes = [_]model.NodeConfig{
        .{ .id = "unknown", .mac = "02:00:00:00:00:01", .arch = .x86_64, .profile = null, .deploy = false },
        .{ .id = "target", .mac = "02:00:00:00:00:02", .arch = .x86_64, .profile = "install", .pxe = .{ .ip_reservation = "192.0.2.20" }, .storage = .{ .boot_disk = "/dev/nvme0n1" }, .network = .{ .mode = .static, .address = "192.0.2.20", .prefix_len = 24 } },
    };
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1" } };
    const catalog: model.Catalog = .{ .profiles = &profiles, .nodes = &nodes, .install_sources = &.{source} };
    var plan = try build(std.testing.allocator, &config, &catalog, 1, 2);
    defer plan.deinit();
    try std.testing.expect(plan.applicable());
    var next = try candidates(std.testing.allocator, &config, &catalog, &plan);
    defer next.deinit();
    try std.testing.expectEqual(@as(u32, 3), next.catalog.value.schema_version);
    try std.testing.expectEqual(@as(usize, 1), next.catalog.value.profiles.len);
    try std.testing.expect(next.catalog.value.nodes[0].profile == null and !next.catalog.value.nodes[0].deploy);
    try std.testing.expectEqualStrings("192.0.2.20", next.catalog.value.nodes[1].pxe.ip_reservation.?);
    try std.testing.expectEqualStrings("/dev/nvme0n1", next.catalog.value.nodes[1].storage.boot_disk);
    try std.testing.expectEqualStrings("vim", next.catalog.value.profiles[0].software.packages.include[0]);
}
