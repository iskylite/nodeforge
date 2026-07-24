//! Schema v4 迁移：带标签 `ProfileKind = install | diskless`，以及规范的
//! `rootfs_build | first_boot` phase 与 `managed_file | archive | script | package`
//! action 集合。
//!
//! v3 install Profile 无损包装为 `ProfileKind.install`，不移动任何冻结的 v0.1
//! owner。前向计划只改变 Profile 的外层判别形状（v3 输入时 `kind` 默认为
//! `.install`）并盖戳 `schema_version = 4`。v0.2 专有特性（diskless kind、boot
//! bundle、`rootfs_build`/`first_boot` phase、`archive`/`script`/`package`
//! action、`runtime_kernel`/`archive`/`script` asset）在 v4 可表示但不可降级到
//! v3：以 `migration.non_representable` 阻断项暴露。
const std = @import("std");
const model = @import("../model.zig");
const lookup = @import("../catalog.zig");

pub const Blocker = struct { entity: []const u8, code: []const u8, detail: []const u8 };

const Payload = struct {
    target_schema: u32 = 4,
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

    pub fn applicable(self: Plan) bool {
        return self.blockers.len == 0;
    }
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
    pub fn deinit(self: *Candidates) void {
        self.catalog.deinit();
        self.config.deinit();
    }
};

/// 构建无副作用的 v3 -> v4 迁移计划。
///
/// 计划对给定 (config, catalog, revisions) 元组确定；当无阻断项阻止把每个
/// Profile 包装为 `ProfileKind.install` 时 `applicable()` 为真。
pub fn build(allocator: std.mem.Allocator, config: *const model.AppConfig, catalog: *const model.Catalog, config_revision: u64, catalog_revision: u64) !Plan {
    var affected_profiles: std.ArrayList([]const u8) = .empty;
    defer affected_profiles.deinit(allocator);
    var affected_nodes: std.ArrayList([]const u8) = .empty;
    defer affected_nodes.deinit(allocator);
    var blockers: std.ArrayList(Blocker) = .empty;
    defer blockers.deinit(allocator);

    if (config.schema_version != 3 and config.schema_version != 4)
        try blockers.append(allocator, .{ .entity = "startup-config", .code = "schema_v4.unsupported_source_schema", .detail = "schema v4 migration requires source schema 3" });
    for (catalog.legacy_diskless_profiles) |name|
        try blockers.append(allocator, .{ .entity = name, .code = "schema_v4.legacy_diskless_profile", .detail = "resolve legacy diskless profile via schema-v3 migration first" });

    for (catalog.profiles) |profile| {
        try affected_profiles.append(allocator, profile.name);
        _ = lookup.findInstallSource(catalog, profile.install_source) orelse {
            try blockers.append(allocator, .{ .entity = profile.name, .code = "schema_v4.install_source_not_found", .detail = profile.install_source });
            continue;
        };
        if (profile.kind == .diskless) {
            const bundle_name = profile.boot_bundle orelse {
                try blockers.append(allocator, .{ .entity = profile.name, .code = "schema_v4.diskless_bundle_required", .detail = "diskless profile requires a boot_bundle reference" });
                continue;
            };
            _ = lookup.findBootBundle(catalog, bundle_name) orelse {
                try blockers.append(allocator, .{ .entity = profile.name, .code = "schema_v4.boot_bundle_not_found", .detail = bundle_name });
                continue;
            };
        }
    }
    for (catalog.nodes) |node| try affected_nodes.append(allocator, node.id);

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

/// 从可应用的计划物化迁移后的 v4 模型。
///
/// 经 JSON 深拷贝 config/catalog，结果归调用方所有。每个 Profile 显式包装为
/// `ProfileKind.install`（对 v3 输入幂等）并盖戳 `schema_version = 4`。不移动
/// 任何冻结的 v0.1 owner。
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
    result.config.value.schema_version = 4;
    result.catalog.value.schema_version = 4;
    result.catalog.value.discovery_policy.unknown_action = .record;
    try migrateProfiles(result.catalog.arena.allocator(), &result.catalog.value);
    result.config.value.profiles = result.catalog.value.profiles;
    result.config.value.nodes = result.catalog.value.nodes;
    result.config.value.provisioning_bundles = result.catalog.value.provisioning_bundles;
    return result;
}

fn migrateProfiles(allocator: std.mem.Allocator, catalog: *model.Catalog) !void {
    const profiles = try allocator.dupe(model.ProfileConfig, catalog.profiles);
    for (profiles) |*profile| profile.kind = .install;
    catalog.profiles = profiles;
}

/// v4 -> v3 可表示性预检。
///
/// 对任何无法用 schema v3 表达的 v0.2 专有特性返回阻断项（code
/// `migration.non_representable`）：diskless Profile kind、`boot_bundle`、
/// `rootfs_build`/`first_boot` phase、`archive`/`script`/`package` action，以及
/// `runtime_kernel`/`archive`/`script` asset kind。干净的前向迁移 v4 catalog 产生
/// 零阻断项，可降级。
pub fn downgradeBlockers(allocator: std.mem.Allocator, catalog: *const model.Catalog) ![]const Blocker {
    var blockers: std.ArrayList(Blocker) = .empty;
    defer blockers.deinit(allocator);
    for (catalog.profiles) |profile| {
        if (profile.kind == .diskless)
            try blockers.append(allocator, .{ .entity = profile.name, .code = "migration.non_representable", .detail = "profile.kind=diskless is not expressible in schema v3" });
        if (profile.boot_bundle != null)
            try blockers.append(allocator, .{ .entity = profile.name, .code = "migration.non_representable", .detail = "profile.boot_bundle is not expressible in schema v3" });
    }
    for (catalog.provisioning_bundles) |bundle| {
        for (bundle.steps) |step| {
            if (step.phase != .install_post)
                try blockers.append(allocator, .{ .entity = bundle.name, .code = "migration.non_representable", .detail = "provision phase is not expressible in schema v3" });
            switch (step.action) {
                .archive, .script, .@"package" => try blockers.append(allocator, .{ .entity = bundle.name, .code = "migration.non_representable", .detail = "provision action is not expressible in schema v3" }),
                .managed_file, .repository, .standard_packages => {},
            }
        }
    }
    for (catalog.assets) |asset| switch (asset.kind) {
        .runtime_kernel, .archive, .script => try blockers.append(allocator, .{ .entity = asset.name, .code = "migration.non_representable", .detail = "asset kind is not expressible in schema v3" }),
        else => {},
    };
    return blockers.toOwnedSlice(allocator);
}

test "v4 plan wraps v3 install profiles losslessly and is stable" {
    const profile: model.ProfileConfig = .{ .name = "p", .install_source = "s" };
    const source: model.InstallSourceConfig = .{ .name = "s", .distro = "rocky", .version = "9", .arch = .x86_64, .source_asset = "iso", .installer_kernel = "kernel", .installer_initrd = "initrd" };
    const node: model.NodeConfig = .{ .id = "n", .mac = "02:00:00:00:00:01", .arch = .x86_64, .profile = "p" };
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1" }, .schema_version = 3 };
    const catalog: model.Catalog = .{ .schema_version = 3, .profiles = &.{profile}, .nodes = &.{node}, .install_sources = &.{source} };
    var first = try build(std.testing.allocator, &config, &catalog, 1, 2);
    defer first.deinit();
    var second = try build(std.testing.allocator, &config, &catalog, 1, 2);
    defer second.deinit();
    try std.testing.expect(first.applicable());
    try std.testing.expectEqual(@as(usize, 0), first.blockers.len);
    try std.testing.expectEqualSlices(u8, &first.digest, &second.digest);
    try std.testing.expectEqualStrings("p", first.affected_profiles[0]);
    var next = try candidates(std.testing.allocator, &config, &catalog, &first);
    defer next.deinit();
    try std.testing.expectEqual(@as(u32, 4), next.catalog.value.schema_version);
    try std.testing.expectEqual(model.ProfileKind.install, next.catalog.value.profiles[0].kind);
}

test "v4 plan blocks diskless profile without boot bundle" {
    const profile: model.ProfileConfig = .{ .name = "d", .install_source = "s", .kind = .diskless };
    const source: model.InstallSourceConfig = .{ .name = "s", .distro = "rocky", .version = "9", .arch = .x86_64, .source_asset = "iso", .installer_kernel = "kernel", .installer_initrd = "initrd" };
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1" }, .schema_version = 3 };
    const catalog: model.Catalog = .{ .schema_version = 3, .profiles = &.{profile}, .install_sources = &.{source} };
    var plan = try build(std.testing.allocator, &config, &catalog, 1, 2);
    defer plan.deinit();
    try std.testing.expect(!plan.applicable());
    try std.testing.expectEqualStrings("schema_v4.diskless_bundle_required", plan.blockers[0].code);
}

test "clean forward-migrated v4 catalog is downgrade-representable" {
    const profile: model.ProfileConfig = .{ .name = "p", .install_source = "s" };
    const source: model.InstallSourceConfig = .{ .name = "s", .distro = "rocky", .version = "9", .arch = .x86_64, .source_asset = "iso", .installer_kernel = "kernel", .installer_initrd = "initrd" };
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1" }, .schema_version = 3 };
    const catalog: model.Catalog = .{ .schema_version = 3, .profiles = &.{profile}, .install_sources = &.{source} };
    var plan = try build(std.testing.allocator, &config, &catalog, 1, 2);
    defer plan.deinit();
    var next = try candidates(std.testing.allocator, &config, &catalog, &plan);
    defer next.deinit();
    const blockers = try downgradeBlockers(std.testing.allocator, &next.catalog.value);
    defer std.testing.allocator.free(blockers);
    try std.testing.expectEqual(@as(usize, 0), blockers.len);
}

test "v0.2-only features are non-representable on downgrade" {
    const diskless: model.ProfileConfig = .{ .name = "d", .install_source = "s", .kind = .diskless, .boot_bundle = "b" };
    const bundle = model.BootBundleConfig{ .name = "b", .distro = "rocky", .version = "9", .arch = .x86_64, .kernel_release = "5.14.0", .kernel = "k", .initrd = "i", .rootfs = "r" };
    const step: model.ProvisionStep = .{ .name = "x", .phase = .rootfs_build, .action = .@"package" };
    const prov_bundle = model.ProvisioningBundle{ .name = "pb", .steps = &.{step} };
    const asset: model.AssetConfig = .{ .name = "rk", .kind = .runtime_kernel, .path = "/rk" };
    const catalog: model.Catalog = .{ .schema_version = 4, .profiles = &.{diskless}, .boot_bundles = &.{bundle}, .provisioning_bundles = &.{prov_bundle}, .assets = &.{asset} };
    const blockers = try downgradeBlockers(std.testing.allocator, &catalog);
    defer std.testing.allocator.free(blockers);
    // diskless kind + boot_bundle（profile d）+ rootfs_build 阶段 + package 动作（pb）+ runtime_kernel 资产（rk）
    try std.testing.expectEqual(@as(usize, 5), blockers.len);
    for (blockers) |b| try std.testing.expectEqualStrings("migration.non_representable", b.code);
}
