//! Explicit read-only schema-v2 migration DTO.
const std = @import("std");
const model = @import("../model.zig");

const Mode = enum { discovery, install, diskless };
const Storage = struct {
    wipe: bool = true,
    mode: model.StorageMode = .single,
    boot_disk: []const u8 = "/dev/sda",
    install_disks: []const []const u8 = &.{"/dev/sda"},
    boot_mode: enum { uefi, bios } = .uefi,
    partition_table: model.PartitionTable = .gpt,
    partitions: []const model.PartitionConfig = &.{},
};
const Install = struct {
    storage: Storage = .{},
    bootloader: model.BootloaderInstallConfig = .{},
    apt: model.AptInstallConfig = .{},
    reinstall_policy: model.ReinstallPolicy = .explicit,
    completion: model.CompletionConfig = .{},
    updates: model.UpdateConfig = .{},
    proxy: model.ProxyConfig = .{},
    post_install: model.PostInstallConfig = .{},
    packages: []const []const u8 = &.{},
    users: []const model.UserConfig = &.{},
    ssh_authorized_keys: []const []const u8 = &.{},
    bundle: ?[]const u8 = null,
};
const Profile = struct {
    name: []const u8,
    mode: Mode,
    distro: []const u8,
    version: []const u8,
    arch: model.Arch,
    install_source: ?[]const u8 = null,
    boot_bundle: ?[]const u8 = null,
    safety: model.ProfileSafetyConfig = .{},
    system: model.TargetSystemConfig = .{},
    software: model.SoftwareSelection = .{},
    install: ?Install = null,
    kernel_args: ?[]const u8 = null,
};
const StorageOverride = struct { boot_disk: ?[]const u8 = null, install_disks: ?[]const []const u8 = null };
const Override = struct {
    network: ?model.TargetNetworkConfig = null,
    storage: ?StorageOverride = null,
    install: model.InstallOverrideConfig = .{},
    system: model.SystemOverrideConfig = .{},
    software: model.SoftwareOverrideConfig = .{},
    kernel_args: model.StringSetDelta = .{},
};
const Node = struct {
    id: []const u8,
    mac: []const u8,
    arch: model.Arch,
    profile: ?[]const u8 = null,
    ip: ?[]const u8 = null,
    pxe: model.PxeConfig = .{},
    hostname: ?[]const u8 = null,
    overrides: Override = .{},
    storage: model.NodeStorageConfig = .{},
    network: model.TargetNetworkConfig = .{},
    deploy: bool = true,
    http_accel: bool = false,
};
const Catalog = struct {
    schema_version: u32,
    revision: u64 = 0,
    distros: []const model.DistroConfig = &.{},
    profiles: []const Profile = &.{},
    nodes: []const Node = &.{},
    provisioning_bundles: []const model.ProvisioningBundle = &.{},
    repositories: []const model.RepositoryConfig = &.{},
    assets: []const model.AssetConfig = &.{},
    install_sources: []const model.InstallSourceConfig = &.{},
    boot_bundles: []const model.BootBundleConfig = &.{},
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(model.Catalog) {
    var source = try std.json.parseFromSlice(Catalog, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer source.deinit();
    if (source.value.schema_version != 1 and source.value.schema_version != 2) return error.InvalidSchemaV2Catalog;
    const arena = source.arena.allocator();

    var profile_count: usize = 0;
    var diskless_count: usize = 0;
    for (source.value.profiles) |profile| switch (profile.mode) {
        .install => profile_count += 1,
        .diskless => diskless_count += 1,
        .discovery => {},
    };
    const profiles = try arena.alloc(model.ProfileConfig, profile_count);
    const diskless = try arena.alloc([]const u8, diskless_count);
    var profile_index: usize = 0;
    var diskless_index: usize = 0;
    for (source.value.profiles) |profile| switch (profile.mode) {
        .install => {
            const install_source = profile.install_source orelse return error.LegacyInstallSourceMissing;
            profiles[profile_index] = .{
                .name = profile.name,
                .install_source = install_source,
                .system = profile.system,
                .software = profile.software,
                .install = toInstall(profile.install orelse .{}, profile.safety.reinstall_policy),
                .kernel_args = profile.kernel_args,
            };
            profile_index += 1;
        },
        .diskless => {
            diskless[diskless_index] = profile.name;
            diskless_index += 1;
        },
        .discovery => {},
    };

    const nodes = try arena.alloc(model.NodeConfig, source.value.nodes.len);
    var multidisk: std.ArrayList([]const u8) = .empty;
    defer multidisk.deinit(arena);
    for (source.value.nodes, 0..) |node, index| {
        const legacy_profile = findProfile(source.value.profiles, node.profile);
        const canonical_profile = if (legacy_profile) |profile| profile.mode == .install else false;
        const install = if (legacy_profile) |profile| profile.install orelse Install{} else Install{};
        const boot_disk = if (node.overrides.storage) |storage| storage.boot_disk orelse install.storage.boot_disk else install.storage.boot_disk;
        const disks = if (node.overrides.storage) |storage| storage.install_disks orelse install.storage.install_disks else install.storage.install_disks;
        for (disks) |disk| if (!std.mem.eql(u8, disk, boot_disk)) {
            try multidisk.append(arena, node.id);
            break;
        };
        nodes[index] = .{
            .id = node.id,
            .mac = node.mac,
            .arch = node.arch,
            .profile = if (canonical_profile) node.profile else null,
            .pxe = .{ .ip_reservation = node.pxe.ip_reservation orelse node.ip },
            .hostname = node.hostname,
            .overrides = .{ .install = node.overrides.install, .system = node.overrides.system, .software = node.overrides.software, .kernel_args = node.overrides.kernel_args },
            .storage = .{ .boot_disk = boot_disk },
            .network = node.overrides.network orelse node.network,
            .deploy = if (canonical_profile) node.deploy else false,
            .http_accel = node.http_accel,
        };
    }
    const runtime: model.Catalog = .{
        .schema_version = source.value.schema_version,
        .revision = source.value.revision,
        .distros = source.value.distros,
        .profiles = profiles,
        .nodes = nodes,
        .provisioning_bundles = source.value.provisioning_bundles,
        .repositories = source.value.repositories,
        .assets = source.value.assets,
        .install_sources = source.value.install_sources,
        .boot_bundles = source.value.boot_bundles,
        .legacy_diskless_profiles = diskless,
        .legacy_multidisk_nodes = try multidisk.toOwnedSlice(arena),
    };
    const projected = try std.json.Stringify.valueAlloc(allocator, runtime, .{});
    defer allocator.free(projected);
    return std.json.parseFromSlice(model.Catalog, allocator, projected, .{ .allocate = .alloc_always });
}

fn toInstall(value: Install, reinstall_policy: model.ReinstallPolicy) model.ProfileInstallConfig {
    return .{
        .storage = .{ .wipe = value.storage.wipe, .mode = value.storage.mode, .partition_table = value.storage.partition_table, .partitions = value.storage.partitions },
        .bootloader = value.bootloader,
        .apt = value.apt,
        .reinstall_policy = reinstall_policy,
        .completion = value.completion,
        .updates = value.updates,
        .proxy = value.proxy,
        .post_install = value.post_install,
        .packages = value.packages,
        .users = value.users,
        .ssh_authorized_keys = value.ssh_authorized_keys,
        .bundle = value.bundle,
    };
}

fn findProfile(profiles: []const Profile, name: ?[]const u8) ?Profile {
    const target = name orelse return null;
    for (profiles) |profile| if (std.mem.eql(u8, profile.name, target)) return profile;
    return null;
}

test "legacy discovery is unassigned and multidisk evidence is retained" {
    const bytes =
        \\{"schema_version":2,"profiles":[{"name":"discover","mode":"discovery","distro":"rocky","version":"9","arch":"x86_64"},{"name":"install","mode":"install","distro":"rocky","version":"9","arch":"x86_64","install_source":"source","install":{"storage":{"boot_disk":"/dev/sda","install_disks":["/dev/sda","/dev/sdb"]}}}],"nodes":[{"id":"u","mac":"02:00:00:00:00:01","arch":"x86_64","profile":"discover"},{"id":"n","mac":"02:00:00:00:00:02","arch":"x86_64","profile":"install"}]}
    ;
    var parsed = try parse(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.nodes[0].profile == null and !parsed.value.nodes[0].deploy);
    try std.testing.expectEqualStrings("n", parsed.value.legacy_multidisk_nodes[0]);
}
