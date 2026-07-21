//! Canonical effective-plan compiler shared by validation, digesting and
//! installer rendering.
const std = @import("std");
const model = @import("../model.zig");
const catalog_lookup = @import("../catalog.zig");
const install_compiler = @import("install.zig");
const storage_compiler = @import("storage.zig");

pub const Plan = struct {
    allocator: std.mem.Allocator,
    node: model.NodeConfig,
    profile_name: []const u8,
    install_source: model.InstallSourceConfig,
    install: model.InstallConfig,
    storage: storage_compiler.Plan,
    system: model.TargetSystemConfig,
    software: model.SoftwareSelection,
    network: model.TargetNetworkConfig,
    kernel_args: ?[]const u8,
    owned_strings: std.ArrayList([]u8) = .empty,
    owned_slices: std.ArrayList([]const []const u8) = .empty,

    pub fn deinit(self: *Plan) void {
        self.storage.deinit(self.allocator);
        for (self.owned_strings.items) |value| self.allocator.free(value);
        for (self.owned_slices.items) |value| self.allocator.free(value);
        self.owned_strings.deinit(self.allocator);
        self.owned_slices.deinit(self.allocator);
    }
};

pub fn compile(allocator: std.mem.Allocator, catalog: *const model.Catalog, node: *const model.NodeConfig) !Plan {
    const profile = catalog_lookup.findProfile(catalog, node.profile orelse return error.NodeUnassigned) orelse return error.MissingProfile;
    const source = catalog_lookup.findInstallSource(catalog, profile.install_source) orelse return error.MissingInstallSource;
    return compileInputs(allocator, node, profile, source);
}

pub fn compileInputs(allocator: std.mem.Allocator, node: *const model.NodeConfig, profile: *const model.ProfileConfig, source: *const model.InstallSourceConfig) !Plan {
    var storage = try storage_compiler.compile(allocator, node, profile);
    errdefer storage.deinit(allocator);
    var single_disk: [1][]const u8 = undefined;
    var install = try install_compiler.effectiveInstall(node, profile, &single_disk);
    install.storage.boot_disk = storage.members[0];
    install.storage.members = storage.members;
    install.storage.mode = storage.mode;
    install.storage.wipe = storage.wipe;
    install.storage.partition_table = storage.partition_table;
    install.storage.partitions = storage.partitions;
    var result: Plan = .{
        .allocator = allocator,
        .node = node.*,
        .profile_name = profile.name,
        .install_source = source.*,
        .install = install,
        .storage = storage,
        .system = try install_compiler.effectiveSystem(profile),
        .software = profile.software,
        .network = node.network,
        .kernel_args = profile.kernel_args,
    };
    errdefer result.deinit();
    try mergeSystem(&result, node.overrides.system);
    try mergeSoftware(&result, node.overrides.software);
    try mergeKernelArgs(&result, node.overrides.kernel_args);
    return result;
}

fn mergeSystem(plan: *Plan, override: model.SystemOverrideConfig) !void {
    if (override.localization.locale) |value| plan.system.localization.locale = value;
    if (override.localization.timezone) |value| plan.system.localization.timezone = value;
    if (override.localization.keyboard) |value| plan.system.localization.keyboard = value;
    if (override.connectivity.time_sync) |value| plan.system.connectivity.time_sync = value;
    plan.system.connectivity.ntp_servers = try mergeSet(plan, plan.system.connectivity.ntp_servers, override.connectivity.ntp_servers);
    if (override.ssh.enabled) |value| plan.system.ssh.enabled = value;
    if (override.ssh.password_authentication) |value| plan.system.ssh.password_authentication = value;
    if (override.ssh.root_login) |value| plan.system.ssh.root_login = value;
    if (override.ssh.root_password) |value| plan.system.ssh.root_password = value;
    plan.system.ssh.root_authorized_keys = try mergeSet(plan, plan.system.ssh.root_authorized_keys, override.ssh.root_authorized_keys);
    if (override.security.firewall) |value| plan.system.security.firewall = value;
    if (override.security.selinux) |value| plan.system.security.selinux = value;
    if (override.security.apparmor) |value| plan.system.security.apparmor = value;
    if (override.users) |value| plan.system.users = value;
    plan.system.packages = &.{};
    plan.install.proxy.no_proxy = try mergeSet(plan, plan.install.proxy.no_proxy, plan.node.overrides.install.proxy_no_proxy);
}

fn mergeSoftware(plan: *Plan, override: model.SoftwareOverrideConfig) !void {
    plan.software.repositories = try mergeSet(plan, plan.software.repositories, override.repositories);
    if (override.environment) |value| plan.software.environment = value;
    plan.software.groups = try mergeSet(plan, plan.software.groups, override.groups);
    plan.software.tasks = try mergeSet(plan, plan.software.tasks, override.tasks);
    plan.software.packages.include = try mergeSet(plan, plan.software.packages.include, override.packages_include);
    plan.software.packages.exclude = try mergeSet(plan, plan.software.packages.exclude, override.packages_exclude);
}

fn mergeKernelArgs(plan: *Plan, delta: model.StringSetDelta) !void {
    var base: std.ArrayList([]const u8) = .empty;
    defer base.deinit(plan.allocator);
    if (plan.kernel_args) |text| {
        var iterator = std.mem.tokenizeScalar(u8, text, ' ');
        while (iterator.next()) |value| try base.append(plan.allocator, value);
    }
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(plan.allocator);
    for (base.items) |value| if (!kernelContains(delta.remove, kernelName(value))) try values.append(plan.allocator, value);
    for (delta.add) |value| {
        if (kernelContains(delta.remove, kernelName(value))) continue;
        if (kernelIndex(values.items, kernelName(value))) |index| values.items[index] = value else try values.append(plan.allocator, value);
    }
    const merged = try values.toOwnedSlice(plan.allocator);
    try plan.owned_slices.append(plan.allocator, merged);
    if (merged.len == 0) {
        plan.kernel_args = null;
        return;
    }
    var output: std.Io.Writer.Allocating = .init(plan.allocator);
    defer output.deinit();
    for (merged, 0..) |value, index| {
        if (index != 0) try output.writer.writeByte(' ');
        try output.writer.writeAll(value);
    }
    const owned = try output.toOwnedSlice();
    try plan.owned_strings.append(plan.allocator, owned);
    plan.kernel_args = owned;
}

fn kernelName(value: []const u8) []const u8 { return value[0 .. std.mem.indexOfScalar(u8, value, '=') orelse value.len]; }
fn kernelIndex(values: []const []const u8, name: []const u8) ?usize { for (values, 0..) |value, index| if (std.mem.eql(u8, kernelName(value), name)) return index; return null; }
fn kernelContains(values: []const []const u8, name: []const u8) bool { return kernelIndex(values, name) != null; }

fn mergeSet(plan: *Plan, base: []const []const u8, delta: model.StringSetDelta) ![]const []const u8 {
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(plan.allocator);
    for (base) |value| if (!contains(delta.remove, value) and !contains(values.items, value)) try values.append(plan.allocator, value);
    for (delta.add) |value| if (!contains(delta.remove, value) and !contains(values.items, value)) try values.append(plan.allocator, value);
    const owned = try values.toOwnedSlice(plan.allocator);
    try plan.owned_slices.append(plan.allocator, owned);
    return owned;
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

test "effective plan merges policy collections and direct node facts" {
    const source: model.InstallSourceConfig = .{ .name = "s", .distro = "rocky", .version = "9", .arch = .x86_64, .source_asset = "iso", .installer_kernel = "kernel", .installer_initrd = "initrd" };
    const profile: model.ProfileConfig = .{ .name = "p", .install_source = "s", .software = .{ .packages = .{ .include = &.{ "a", "b" } } }, .kernel_args = "quiet console=tty0", .install = .{ .storage = .{ .mode = .raid1 } } };
    const node: model.NodeConfig = .{ .id = "n", .mac = "02:00:00:00:00:01", .arch = .x86_64, .profile = "p", .storage = .{ .boot_disk = "/dev/vda", .additional_disks = &.{"/dev/vdb"} }, .network = .{ .mode = .static, .address = "192.0.2.2", .prefix_len = 24 }, .overrides = .{ .software = .{ .packages_include = .{ .add = &.{"c"}, .remove = &.{"a"} } }, .kernel_args = .{ .add = &.{ "iommu=pt", "console=ttyS0" }, .remove = &.{"quiet"} } } };
    const catalog: model.Catalog = .{ .profiles = &.{profile}, .nodes = &.{node}, .install_sources = &.{source} };
    var plan = try compile(std.testing.allocator, &catalog, &node);
    defer plan.deinit();
    try std.testing.expectEqualStrings("/dev/vda", plan.storage.members[0]);
    try std.testing.expectEqual(@as(usize, 2), plan.storage.members.len);
    try std.testing.expectEqualStrings("b", plan.software.packages.include[0]);
    try std.testing.expectEqualStrings("c", plan.software.packages.include[1]);
    try std.testing.expectEqualStrings("console=ttyS0 iommu=pt", plan.kernel_args.?);
    try std.testing.expectEqual(model.NetworkMode.static, plan.network.mode);
}
