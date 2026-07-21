//! # Canonical scalar property mutations
//!
//! 提供 `profile set <name> <key>=<value>` 和 `node set <id> <key>=<value>` 的
//! 标量属性写入口。每个 mutation 执行 load-patch-validate-save 事务。
//! 支持的 key 由 `applyProfile`/`applyNode` 的 switch 分支定义。
const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const validate = @import("validate.zig");

/// 单个标量 mutation。
pub const Mutation = struct {
    /// 属性键（如 `install.storage.mode`）。
    key: []const u8,
    /// 属性值；null 表示清空。
    value: ?[]const u8 = null,
};

/// 修改单个 profile 标量属性。`profile set` 命令的入口。
pub fn profile(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, name: []const u8, key: []const u8, value: ?[]const u8) !void {
    return profileBatch(io, allocator, config, catalog_path, name, &.{.{ .key = key, .value = value }});
}

/// 批量修改 profile 标量属性。所有 mutation 在同一事务中提交，任一失败回滚。
pub fn profileBatch(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, name: []const u8, mutations: []const Mutation) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const profiles = try allocator.dupe(model.ProfileConfig, parsed.value.profiles);
    defer allocator.free(profiles);
    var selected: ?*model.ProfileConfig = null;
    for (profiles) |*item| if (std.mem.eql(u8, item.name, name)) {
        selected = item;
        break;
    };
    const target = selected orelse return error.ProfileNotFound;
    for (mutations) |mutation| try applyProfile(&parsed.value, target, mutation.key, mutation.value);
    var candidate = parsed.value;
    candidate.profiles = profiles;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

/// 将单个 key=value 应用到 profile 对象。不支持的关键字返回 `UnknownProperty`。
fn applyProfile(catalog: *const model.Catalog, target: *model.ProfileConfig, key: []const u8, text: ?[]const u8) !void {
    if (eq(key, "install_source")) {
        const source_name = text orelse return error.PropertyRequired;
        const source = findSource(catalog, source_name) orelse return error.MissingInstallSource;
        target.install_source = source.name;
    } else if (eq(key, "install.storage.mode")) target.install.storage.mode = try parseEnum(model.StorageMode, text) else if (eq(key, "install.storage.wipe")) target.install.storage.wipe = try parseBool(text) else if (eq(key, "install.storage.partition_table")) target.install.storage.partition_table = try parseEnum(model.PartitionTable, text) else if (eq(key, "install.bootloader.install")) target.install.bootloader.install = try parseBool(text) else if (eq(key, "system.localization.locale")) target.system.localization.locale = text orelse return error.PropertyRequired else if (eq(key, "system.localization.timezone")) target.system.localization.timezone = text orelse return error.PropertyRequired else if (eq(key, "system.localization.keyboard")) target.system.localization.keyboard = text orelse return error.PropertyRequired else if (eq(key, "system.connectivity.time_sync")) target.system.connectivity.time_sync = try parseBool(text) else if (eq(key, "system.ssh.enabled")) target.system.ssh.enabled = try parseBool(text) else if (eq(key, "system.ssh.password_authentication")) target.system.ssh.password_authentication = try parseBool(text) else if (eq(key, "system.ssh.root_login")) target.system.ssh.root_login = try parseEnum(model.RootLoginPolicy, text) else if (eq(key, "system.ssh.root_password")) target.system.ssh.root_password = text else if (eq(key, "system.security.firewall")) target.system.security.firewall = try parseEnum(model.FirewallPolicy, text) else if (eq(key, "system.security.selinux")) target.system.security.selinux = try parseEnum(model.SelinuxMode, text) else if (eq(key, "system.security.apparmor")) target.system.security.apparmor = try parseEnum(model.AppArmorMode, text) else if (eq(key, "software.environment")) target.software.environment = text else if (eq(key, "install.apt.fallback")) target.install.apt.fallback = try parseEnum(model.AptFallback, text) else if (eq(key, "install.completion.action")) target.install.completion.action = try parseEnum(model.CompletionAction, text) else if (eq(key, "install.updates.mode")) target.install.updates.mode = try parseEnum(model.UpdateMode, text) else if (eq(key, "install.proxy.url")) target.install.proxy.url = text else if (eq(key, "install.reinstall_policy")) target.install.reinstall_policy = try parseEnum(model.ReinstallPolicy, text) else if (eq(key, "install.post_install.bundle")) target.install.post_install.bundle = text else return error.UnknownProperty;
}

/// 修改单个 node 标量属性。`node set <id> <key>=<value>` 的入口。
pub fn node(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, id: []const u8, key: []const u8, value: ?[]const u8) !void {
    return nodeBatch(io, allocator, config, catalog_path, id, &.{.{ .key = key, .value = value }});
}

/// 批量修改 node 标量属性。所有 mutation 在同一事务中提交，任一失败回滚。
pub fn nodeBatch(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, id: []const u8, mutations: []const Mutation) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const nodes = try allocator.dupe(model.NodeConfig, parsed.value.nodes);
    defer allocator.free(nodes);
    var selected: ?*model.NodeConfig = null;
    for (nodes) |*item| if (std.mem.eql(u8, item.id, id)) {
        selected = item;
        break;
    };
    const target = selected orelse return error.NodeNotFound;
    for (mutations) |mutation| try applyNode(target, mutation.key, mutation.value);
    var candidate = parsed.value;
    candidate.nodes = nodes;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

pub fn applyNode(target: *model.NodeConfig, key: []const u8, text: ?[]const u8) !void {
    if (eq(key, "mac")) target.mac = text orelse return error.PropertyRequired else if (eq(key, "arch")) target.arch = try parseEnum(model.Arch, text) else if (eq(key, "profile")) {
        if (text == null and target.deploy) return error.ProfileRequiredWhileDeployed;
        target.profile = text;
    } else if (eq(key, "pxe.ip_reservation")) target.pxe.ip_reservation = text else if (eq(key, "hostname")) target.hostname = text else if (eq(key, "deploy")) target.deploy = try parseBool(text) else if (eq(key, "http_accel")) target.http_accel = try parseBool(text) else if (eq(key, "network.mode")) target.network.mode = try parseEnum(model.NetworkMode, text) else if (eq(key, "network.interface_name")) target.network.interface = text else if (eq(key, "network.address")) target.network.address = text else if (eq(key, "network.prefix_len")) target.network.prefix_len = if (text) |raw| try std.fmt.parseInt(u8, raw, 10) else null else if (eq(key, "network.gateway")) target.network.gateway = text else if (eq(key, "storage.boot_disk")) target.storage.boot_disk = text orelse return error.PropertyRequired else if (eq(key, "overrides.install.storage.mode")) target.overrides.install.storage.mode = try parseOptionalEnum(model.StorageMode, text) else if (eq(key, "overrides.install.storage.wipe")) target.overrides.install.storage.wipe = try parseOptionalBool(text) else if (eq(key, "overrides.install.storage.partition_table")) target.overrides.install.storage.partition_table = try parseOptionalEnum(model.PartitionTable, text) else if (eq(key, "overrides.install.bootloader.install")) target.overrides.install.bootloader.install = try parseOptionalBool(text) else if (eq(key, "overrides.system.localization.locale")) target.overrides.system.localization.locale = text else if (eq(key, "overrides.system.localization.timezone")) target.overrides.system.localization.timezone = text else if (eq(key, "overrides.system.localization.keyboard")) target.overrides.system.localization.keyboard = text else if (eq(key, "overrides.system.connectivity.time_sync")) target.overrides.system.connectivity.time_sync = try parseOptionalBool(text) else if (eq(key, "overrides.system.ssh.enabled")) target.overrides.system.ssh.enabled = try parseOptionalBool(text) else if (eq(key, "overrides.system.ssh.password_authentication")) target.overrides.system.ssh.password_authentication = try parseOptionalBool(text) else if (eq(key, "overrides.system.ssh.root_login")) target.overrides.system.ssh.root_login = try parseOptionalEnum(model.RootLoginPolicy, text) else if (eq(key, "overrides.system.ssh.root_password")) target.overrides.system.ssh.root_password = text else if (eq(key, "overrides.system.security.firewall")) target.overrides.system.security.firewall = try parseOptionalEnum(model.FirewallPolicy, text) else if (eq(key, "overrides.system.security.selinux")) target.overrides.system.security.selinux = try parseOptionalEnum(model.SelinuxMode, text) else if (eq(key, "overrides.system.security.apparmor")) target.overrides.system.security.apparmor = try parseOptionalEnum(model.AppArmorMode, text) else if (eq(key, "overrides.software.environment")) target.overrides.software.environment = text else if (eq(key, "overrides.install.apt.fallback")) target.overrides.install.apt_fallback = try parseOptionalEnum(model.AptFallback, text) else if (eq(key, "overrides.install.completion.action")) target.overrides.install.completion_action = try parseOptionalEnum(model.CompletionAction, text) else if (eq(key, "overrides.install.updates.mode")) target.overrides.install.updates_mode = try parseOptionalEnum(model.UpdateMode, text) else if (eq(key, "overrides.install.proxy.url")) target.overrides.install.proxy_url = text else if (eq(key, "overrides.install.reinstall_policy")) target.overrides.install.reinstall_policy = try parseOptionalEnum(model.ReinstallPolicy, text) else if (eq(key, "overrides.install.post_install.bundle")) target.overrides.install.post_install_bundle = text else return error.UnknownProperty;
}

fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn parseBool(value: ?[]const u8) !bool {
    const text = value orelse return error.PropertyRequired;
    if (eq(text, "true")) return true;
    if (eq(text, "false")) return false;
    return error.InvalidPropertyValue;
}
fn parseOptionalBool(value: ?[]const u8) !?bool {
    return if (value == null) null else try parseBool(value);
}
fn parseEnum(comptime T: type, value: ?[]const u8) !T {
    return std.meta.stringToEnum(T, value orelse return error.PropertyRequired) orelse error.InvalidPropertyValue;
}
fn parseOptionalEnum(comptime T: type, value: ?[]const u8) !?T {
    return if (value == null) null else try parseEnum(T, value);
}
fn findSource(catalog: *const model.Catalog, name: []const u8) ?*const model.InstallSourceConfig {
    for (catalog.install_sources) |*source| if (eq(source.name, name)) return source;
    return null;
}

pub fn recognizes(owner: @import("../cli/properties.zig").Owner, key: []const u8) bool {
    return switch (owner) {
        .profile => blk: {
            var target: model.ProfileConfig = .{ .name = "contract", .install_source = "source" };
            applyProfile(&.{}, &target, key, null) catch |err| break :blk err != error.UnknownProperty;
            break :blk true;
        },
        .node => blk: {
            var target: model.NodeConfig = .{ .id = "contract", .mac = "00:11:22:33:44:55", .arch = .aarch64 };
            applyNode(&target, key, null) catch |err| break :blk err != error.UnknownProperty;
            break :blk true;
        },
        else => false,
    };
}

test "every registered resource scalar has one mutation consumer" {
    const properties = @import("../cli/properties.zig");
    for (properties.properties) |spec| {
        if (spec.mutability != .mutable or (spec.owner != .profile and spec.owner != .node)) continue;
        try std.testing.expect(recognizes(spec.owner, spec.path));
    }
}
