//! catalog 实体的严格持久化 DTO（API/CLI 渲染用）。
//! setup 始终生成 schema 5；不存在版本迁移。
const std = @import("std");
const model = @import("../model.zig");

const Connectivity = struct {
    time_sync: bool = false,
    ntp_servers: []const []const u8 = &.{},
};
const System = struct {
    localization: model.LocalizationConfig = .{},
    connectivity: Connectivity = .{},
    ssh: model.SshConfig = .{},
    security: model.TargetSecurityConfig = .{},
    users: []const model.TargetUserConfig = &model.default_target_users,
    import_host_hosts: bool = true,
    hosts_content: ?[]const u8 = null,
};
const Network = struct {
    mode: model.NetworkMode = .dhcp,
    interface_name: ?[]const u8 = null,
    address: ?[]const u8 = null,
    prefix_len: ?u8 = null,
    gateway: ?[]const u8 = null,
    dns: []const []const u8 = &.{},
    search_domains: []const []const u8 = &.{},
    routes: []const model.RouteConfig = &.{},
};
const Storage = struct {
    wipe: bool = true,
    mode: model.StorageMode = .single,
    partition_table: model.PartitionTable = .gpt,
    partitions: []const model.PartitionConfig = &.{},
};
const Bootloader = struct { install: bool = true };
const PostInstall = struct { bundle: ?[]const u8 = null };
const Install = struct {
    storage: Storage = .{},
    bootloader: Bootloader = .{},
    apt: model.AptInstallConfig = .{},
    reinstall_policy: model.ReinstallPolicy = .explicit,
    post_install: PostInstall = .{},
    completion: model.CompletionConfig = .{},
    updates: model.UpdateConfig = .{},
    proxy: model.ProxyConfig = .{},
};
const Profile = struct {
    name: []const u8,
    install_source: []const u8,
    kind: model.ProfileKind = .install,
    boot_bundle: ?[]const u8 = null,
    bundle: ?[]const u8 = null,
    diskless: model.DisklessConfig = .{},
    system: System = .{},
    software: model.SoftwareSelection = .{},
    install: Install = .{},
    kernel_args: []const []const u8 = &.{},
    /// v0.2.3: Profile 级单调递增 revision。
    revision: u64 = 1,
    /// v0.2.3: 创建时间（daemon UTC Unix seconds）。
    created_at: i64 = 0,
    /// v0.2.3: 最后更新时间。
    updated_at: i64 = 0,
    /// v0.2.3: 创建/克隆来源审计信息。
    provenance: model.ProfileProvenance = .{},
    /// v0.2.3: SSH identity 引用。
    ssh_identity: model.ProfileSshIdentityRef = .{},
};
const AptOverride = struct { fallback: ?model.AptFallback = null, preserve_sources_list: ?bool = null };
const CompletionOverride = struct { action: ?model.CompletionAction = null };
const UpdatesOverride = struct { mode: ?model.UpdateMode = null };
const ProxyOverride = struct { url: ?[]const u8 = null, no_proxy: model.StringSetDelta = .{} };
const PostInstallOverride = struct { bundle: ?[]const u8 = null };
const InstallOverride = struct {
    storage: model.NullableStorageOverride = .{},
    bootloader: model.BootloaderOverride = .{},
    apt: AptOverride = .{},
    completion: CompletionOverride = .{},
    updates: UpdatesOverride = .{},
    proxy: ProxyOverride = .{},
    reinstall_policy: ?model.ReinstallPolicy = null,
    post_install: PostInstallOverride = .{},
};
const PackageDelta = struct { include: model.StringSetDelta = .{}, exclude: model.StringSetDelta = .{} };
const SoftwareOverride = struct {
    repositories: model.StringSetDelta = .{},
    environment: ?[]const u8 = null,
    groups: model.StringSetDelta = .{},
    tasks: model.StringSetDelta = .{},
    packages: PackageDelta = .{},
};
const Override = struct {
    install: InstallOverride = .{},
    system: model.SystemOverrideConfig = .{},
    software: SoftwareOverride = .{},
    kernel_args: model.StringSetDelta = .{},
};
pub const Node = struct {
    id: []const u8,
    mac: []const u8,
    arch: model.Arch,
    profile: ?[]const u8 = null,
    pxe: model.PxeConfig = .{},
    hostname: ?[]const u8 = null,
    overrides: Override = .{},
    storage: model.NodeStorageConfig = .{},
    network: Network = .{},
    deploy: bool = true,
    http_accel: bool = false,

    pub fn modelValue(value: Node) model.NodeConfig {
        return toNode(value);
    }
};

const ManagedFileStep = struct {
    name: []const u8,
    action: enum { @"managed-file" } = .@"managed-file",
    destination: []const u8,
    content_asset: []const u8,
    mode: u16 = 0o644,
    owner: []const u8 = "root",
    group: []const u8 = "root",
};

const ProvisioningBundle = struct { name: []const u8, revision: u64 = 1, steps: []const ManagedFileStep = &.{} };

const ManagedAsset = struct {
    name: []const u8,
    kind: model.AssetKind,
    path: []const u8,
    distro: ?[]const u8 = null,
    version: ?[]const u8 = null,
    arch: ?model.Arch = null,
    kernel_release: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    revision: u64 = 1,
    size: ?u64 = null,
    media_type: ?[]const u8 = null,
};

const Catalog = struct {
    schema_version: u32,
    revision: u64,
    distros: []const model.DistroConfig = &.{},
    profiles: []const Profile = &.{},
    nodes: []const Node = &.{},
    provisioning_bundles: []const ProvisioningBundle = &.{},
    repositories: []const model.RepositoryConfig = &.{},
    assets: []const ManagedAsset = &.{},
    install_sources: []const model.InstallSourceConfig = &.{},
    boot_bundles: []const model.BootBundleConfig = &.{},
    discovery_policy: model.DiscoveryPolicy = .{},
    unknown_client_observations: []const model.UnknownClientObservation = &.{},
};

pub fn renderProfiles(allocator: std.mem.Allocator, values: []const model.ProfileConfig) ![]u8 {
    const dtos = try allocator.alloc(Profile, values.len);
    defer allocator.free(dtos);
    const argument_slices = try allocator.alloc([]const []const u8, values.len);
    defer allocator.free(argument_slices);
    var initialized: usize = 0;
    defer for (argument_slices[0..initialized]) |arguments| allocator.free(arguments);
    for (values, 0..) |value, index| {
        argument_slices[index] = try splitKernelArgs(allocator, value.kernel_args);
        initialized += 1;
        dtos[index] = fromProfile(value, argument_slices[index]);
    }
    return std.json.Stringify.valueAlloc(allocator, dtos, .{ .whitespace = .indent_2 });
}

pub fn renderNodes(allocator: std.mem.Allocator, values: []const model.NodeConfig) ![]u8 {
    const dtos = try allocator.alloc(Node, values.len);
    defer allocator.free(dtos);
    for (values, 0..) |value, index| dtos[index] = fromNode(value);
    return std.json.Stringify.valueAlloc(allocator, dtos, .{ .whitespace = .indent_2 });
}

pub fn renderNode(allocator: std.mem.Allocator, value: model.NodeConfig) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, fromNode(value), .{});
}

pub fn renderBundles(allocator: std.mem.Allocator, values: []const model.ProvisioningBundle) ![]u8 {
    const bundles = try allocator.alloc(ProvisioningBundle, values.len);
    defer allocator.free(bundles);
    var initialized: usize = 0;
    defer for (bundles[0..initialized]) |bundle| allocator.free(bundle.steps);
    for (values, 0..) |value, index| {
        const steps = try allocator.alloc(ManagedFileStep, value.steps.len);
        errdefer allocator.free(steps);
        for (value.steps, 0..) |step, step_index| {
            if (step.action != .managed_file) return error.LegacyProvisionStep;
            steps[step_index] = .{ .name = step.name, .destination = step.destination orelse return error.InvalidManagedFileStep, .content_asset = step.content_asset orelse return error.InvalidManagedFileStep, .mode = step.mode, .owner = step.owner, .group = step.group };
        }
        bundles[index] = .{ .name = value.name, .revision = value.revision, .steps = steps };
        initialized += 1;
    }
    return std.json.Stringify.valueAlloc(allocator, bundles, .{ .whitespace = .indent_2 });
}

pub fn renderAssets(allocator: std.mem.Allocator, values: []const model.AssetConfig) ![]u8 {
    const assets = try allocator.alloc(ManagedAsset, values.len);
    defer allocator.free(assets);
    for (values, 0..) |value, index| assets[index] = .{ .name = value.name, .kind = value.kind, .path = value.path, .distro = value.distro, .version = value.version, .arch = value.arch, .kernel_release = value.kernel_release, .sha256 = value.sha256, .revision = value.revision, .size = value.size, .media_type = value.media_type };
    return std.json.Stringify.valueAlloc(allocator, assets, .{ .whitespace = .indent_2 });
}

fn fromProfile(value: model.ProfileConfig, kernel_args: []const []const u8) Profile {
    const install = value.install;
    return .{
        .name = value.name,
        .install_source = value.install_source,
        .kind = value.kind,
        .boot_bundle = value.boot_bundle,
        .bundle = value.bundle,
        .diskless = value.diskless,
        .system = .{
            .localization = value.system.localization,
            .connectivity = .{ .time_sync = value.system.connectivity.time_sync, .ntp_servers = value.system.connectivity.ntp_servers },
            .ssh = value.system.ssh,
            .security = value.system.security,
            .users = value.system.users,
            .import_host_hosts = value.system.import_host_hosts,
            .hosts_content = value.system.hosts_content,
        },
        .software = value.software,
        .install = .{
            .storage = .{ .wipe = install.storage.wipe, .mode = install.storage.mode, .partition_table = install.storage.partition_table, .partitions = install.storage.partitions },
            .bootloader = .{ .install = install.bootloader.install },
            .apt = install.apt,
            .reinstall_policy = install.reinstall_policy,
            .post_install = .{ .bundle = install.post_install.bundle },
            .completion = install.completion,
            .updates = install.updates,
            .proxy = install.proxy,
        },
        .kernel_args = kernel_args,
        .revision = value.revision,
        .created_at = value.created_at,
        .updated_at = value.updated_at,
        .provenance = value.provenance,
        .ssh_identity = value.ssh_identity,
    };
}

fn toBundles(allocator: std.mem.Allocator, values: []const ProvisioningBundle) ![]const model.ProvisioningBundle {
    const bundles = try allocator.alloc(model.ProvisioningBundle, values.len);
    for (values, 0..) |value, index| {
        const steps = try allocator.alloc(model.ProvisionStep, value.steps.len);
        for (value.steps, 0..) |step, step_index| steps[step_index] = .{ .name = step.name, .action = .managed_file, .destination = step.destination, .content_asset = step.content_asset, .mode = step.mode, .owner = step.owner, .group = step.group };
        bundles[index] = .{ .name = value.name, .revision = value.revision, .steps = steps };
    }
    return bundles;
}

fn toAssets(allocator: std.mem.Allocator, values: []const ManagedAsset) ![]const model.AssetConfig {
    const assets = try allocator.alloc(model.AssetConfig, values.len);
    for (values, 0..) |value, index| assets[index] = .{ .name = value.name, .kind = value.kind, .path = value.path, .distro = value.distro, .version = value.version, .arch = value.arch, .kernel_release = value.kernel_release, .sha256 = value.sha256, .revision = value.revision, .size = value.size, .media_type = value.media_type };
    return assets;
}

fn toProfile(allocator: std.mem.Allocator, value: Profile, source: *const model.InstallSourceConfig) !model.ProfileConfig {
    _ = source;
    return .{
        .name = value.name,
        .install_source = value.install_source,
        .system = .{
            .localization = value.system.localization,
            .connectivity = .{ .time_sync = value.system.connectivity.time_sync, .ntp_servers = value.system.connectivity.ntp_servers },
            .ssh = value.system.ssh,
            .security = value.system.security,
            .users = value.system.users,
            .import_host_hosts = value.system.import_host_hosts,
            .hosts_content = value.system.hosts_content,
        },
        .software = value.software,
        .install = .{
            .storage = .{ .wipe = value.install.storage.wipe, .mode = value.install.storage.mode, .partition_table = value.install.storage.partition_table, .partitions = value.install.storage.partitions },
            .bootloader = .{ .install = value.install.bootloader.install },
            .apt = value.install.apt,
            .reinstall_policy = value.install.reinstall_policy,
            .post_install = .{ .bundle = value.install.post_install.bundle },
            .completion = value.install.completion,
            .updates = value.install.updates,
            .proxy = value.install.proxy,
        },
        .kernel_args = try joinKernelArgs(allocator, value.kernel_args),
    };
}

fn splitKernelArgs(allocator: std.mem.Allocator, text: ?[]const u8) ![]const []const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    if (text) |raw| {
        var iterator = std.mem.tokenizeScalar(u8, raw, ' ');
        while (iterator.next()) |value| try values.append(allocator, value);
    }
    return values.toOwnedSlice(allocator);
}

fn joinKernelArgs(allocator: std.mem.Allocator, values: []const []const u8) !?[]const u8 {
    if (values.len == 0) return null;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    for (values, 0..) |value, index| {
        if (index != 0) try output.writer.writeByte(' ');
        try output.writer.writeAll(value);
    }
    return try output.toOwnedSlice();
}

fn fromNode(value: model.NodeConfig) Node {
    return .{
        .id = value.id,
        .mac = value.mac,
        .arch = value.arch,
        .profile = value.profile,
        .pxe = value.pxe,
        .hostname = value.hostname,
        .overrides = .{
            .install = .{
                .storage = value.overrides.install.storage,
                .bootloader = value.overrides.install.bootloader,
                .apt = .{ .fallback = value.overrides.install.apt_fallback, .preserve_sources_list = value.overrides.install.apt_preserve_sources_list },
                .completion = .{ .action = value.overrides.install.completion_action },
                .updates = .{ .mode = value.overrides.install.updates_mode },
                .proxy = .{ .url = value.overrides.install.proxy_url, .no_proxy = value.overrides.install.proxy_no_proxy },
                .reinstall_policy = value.overrides.install.reinstall_policy,
                .post_install = .{ .bundle = value.overrides.install.post_install_bundle },
            },
            .system = value.overrides.system,
            .software = .{ .repositories = value.overrides.software.repositories, .environment = value.overrides.software.environment, .groups = value.overrides.software.groups, .tasks = value.overrides.software.tasks, .packages = .{ .include = value.overrides.software.packages_include, .exclude = value.overrides.software.packages_exclude } },
            .kernel_args = value.overrides.kernel_args,
        },
        .storage = value.storage,
        .network = .{ .mode = value.network.mode, .interface_name = value.network.interface, .address = value.network.address, .prefix_len = value.network.prefix_len, .gateway = value.network.gateway, .dns = value.network.dns, .search_domains = value.network.search_domains, .routes = value.network.routes },
        .deploy = value.deploy,
        .http_accel = value.http_accel,
    };
}

fn toNode(value: Node) model.NodeConfig {
    return .{
        .id = value.id,
        .mac = value.mac,
        .arch = value.arch,
        .profile = value.profile,
        .pxe = value.pxe,
        .hostname = value.hostname,
        .overrides = .{
            .install = .{
                .storage = value.overrides.install.storage,
                .bootloader = value.overrides.install.bootloader,
                .apt_fallback = value.overrides.install.apt.fallback,
                .apt_preserve_sources_list = value.overrides.install.apt.preserve_sources_list,
                .completion_action = value.overrides.install.completion.action,
                .updates_mode = value.overrides.install.updates.mode,
                .proxy_url = value.overrides.install.proxy.url,
                .proxy_no_proxy = value.overrides.install.proxy.no_proxy,
                .reinstall_policy = value.overrides.install.reinstall_policy,
                .post_install_bundle = value.overrides.install.post_install.bundle,
            },
            .system = value.overrides.system,
            .software = .{ .repositories = value.overrides.software.repositories, .environment = value.overrides.software.environment, .groups = value.overrides.software.groups, .tasks = value.overrides.software.tasks, .packages_include = value.overrides.software.packages.include, .packages_exclude = value.overrides.software.packages.exclude },
            .kernel_args = value.overrides.kernel_args,
        },
        .storage = value.storage,
        .network = .{ .mode = value.network.mode, .interface = value.network.interface_name, .address = value.network.address, .prefix_len = value.network.prefix_len, .gateway = value.network.gateway, .dns = value.network.dns, .search_domains = value.network.search_domains, .routes = value.network.routes },
        .deploy = value.deploy,
        .http_accel = value.http_accel,
    };
}

fn findSource(values: []const model.InstallSourceConfig, name: []const u8) ?*const model.InstallSourceConfig {
    for (values) |*value| if (std.mem.eql(u8, value.name, name)) return value;
    return null;
}

test "strict profile and node render omit legacy ownership keys" {
    const profile: model.ProfileConfig = .{ .name = "p", .install_source = "s" };
    const node: model.NodeConfig = .{ .id = "n", .mac = "02:00:00:00:00:01", .arch = .x86_64, .pxe = .{ .ip_reservation = "192.0.2.2" } };
    const profiles = try renderProfiles(std.testing.allocator, &.{profile});
    defer std.testing.allocator.free(profiles);
    const nodes = try renderNodes(std.testing.allocator, &.{node});
    defer std.testing.allocator.free(nodes);
    try std.testing.expect(std.mem.indexOf(u8, profiles, "\"mode\"") != null); // storage.mode 保持为 canonical
    try std.testing.expect(std.mem.indexOf(u8, profiles, "\"distro\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, profiles, "install_disks") == null);
    try std.testing.expect(std.mem.indexOf(u8, nodes, "\"ip\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, nodes, "ip_reservation") != null);
    try std.testing.expect(std.mem.indexOf(u8, nodes, "match_mac") == null);
}

test "strict profile DTO rejects removed legacy keys" {
    const bytes = "[{\"name\":\"p\",\"install_source\":\"s\",\"mode\":\"install\"}]";
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice([]const Profile, std.testing.allocator, bytes, .{}));
}
