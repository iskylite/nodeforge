//! # 类型化结构化条目 catalog 变更
//!
//! 处理 partitions/users/routes 等结构化列表项的增删改查。
//! 每个 item 使用 stable id 定位，支持 add/set/remove/move 四种操作。
const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const validate = @import("validate.zig");
const install_compiler = @import("../profile/install.zig");
const value_mutation = @import("value_mutation.zig");

/// 列表项操作类型。
pub const Operation = enum {
    /// 追加新项。
    add,
    /// 修改已有项。
    set,
    /// 删除项。
    remove,
    /// 重排序项。
    move,
};
/// 批量替换操作类型。
pub const BulkOperation = enum {
    /// 用新列表完整替换旧列表。
    replace,
    /// 清空列表。
    clear,
};
/// 批量替换参数。根据 `key` 选择使用哪个字段。
pub const Replacement = struct {
    operation: BulkOperation,
    key: []const u8,
    partitions: []const model.PartitionConfig = &.{},
    users: []const model.TargetUserConfig = &.{},
    routes: []const model.RouteConfig = &.{},
};
/// 单个列表项 patch 参数。所有可选字段 null 表示不修改。
pub const Patch = struct {
    operation: Operation,
    key: []const u8,
    identity: []const u8,
    before: ?[]const u8 = null,
    after: ?[]const u8 = null,
    unset: []const []const u8 = &.{},
    id: ?[]const u8 = null,
    mount: ?[]const u8 = null,
    filesystem: ?[]const u8 = null,
    size_mib: ?u32 = null,
    grow: ?bool = null,
    kind: ?model.PartitionKind = null,
    name: ?[]const u8 = null,
    uid: ?u32 = null,
    shell: ?[]const u8 = null,
    locked: ?bool = null,
    password: ?[]const u8 = null,
    sudo: ?bool = null,
    destination: ?[]const u8 = null,
    gateway: ?[]const u8 = null,
    metric: ?u32 = null,
};

const automatic_partitions = [_]model.PartitionConfig{
    .{ .id = "esp", .mount = "/boot/efi", .filesystem = "fat32", .size_mib = 1024, .kind = .esp },
    .{ .id = "boot", .mount = "/boot", .filesystem = "ext4", .size_mib = 2048, .kind = .boot },
    .{ .id = "root", .mount = "/", .filesystem = "ext4", .size_mib = 1, .grow = true, .kind = .root },
};

pub fn profile(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, identity: []const u8, patch: Patch) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const profiles = try allocator.dupe(model.ProfileConfig, parsed.value.profiles);
    defer allocator.free(profiles);
    var selected: ?*model.ProfileConfig = null;
    for (profiles) |*item| if (std.mem.eql(u8, item.name, identity)) {
        selected = item;
        break;
    };
    const target = selected orelse return error.ProfileNotFound;
    var owned_partitions: ?[]model.PartitionConfig = null;
    var owned_users: ?[]model.TargetUserConfig = null;
    defer if (owned_partitions) |items| allocator.free(items);
    defer if (owned_users) |items| allocator.free(items);
    if (std.mem.eql(u8, patch.key, "install.storage.partitions")) {
        const current = if (target.install.storage.partitions.len == 0) &automatic_partitions else target.install.storage.partitions;
        owned_partitions = try mutatePartitions(allocator, current, patch);
        target.install.storage.partitions = owned_partitions.?;
    } else if (std.mem.eql(u8, patch.key, "system.users")) {
        owned_users = try mutateUsers(allocator, target.system.users, patch);
        target.system.users = owned_users.?;
    } else return error.UnsupportedProperty;
    var candidate = parsed.value;
    candidate.profiles = profiles;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

pub fn node(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, identity: []const u8, patch: Patch) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const nodes = try allocator.dupe(model.NodeConfig, parsed.value.nodes);
    defer allocator.free(nodes);
    var selected: ?*model.NodeConfig = null;
    for (nodes) |*item| if (std.mem.eql(u8, item.id, identity)) {
        selected = item;
        break;
    };
    const target = selected orelse return error.NodeNotFound;
    var owned_routes: ?[]model.RouteConfig = null;
    var owned_partitions: ?[]model.PartitionConfig = null;
    var owned_users: ?[]model.TargetUserConfig = null;
    defer if (owned_routes) |items| allocator.free(items);
    defer if (owned_partitions) |items| allocator.free(items);
    defer if (owned_users) |items| allocator.free(items);
    if (std.mem.eql(u8, patch.key, "network.routes")) {
        owned_routes = try mutateRoutes(allocator, target.network.routes, patch);
        target.network.routes = owned_routes.?;
    } else if (std.mem.eql(u8, patch.key, "overrides.install.storage.partitions")) {
        const profile_value = if (target.profile) |name| findProfile(&parsed.value, name) else null;
        const inherited = if (target.overrides.install.storage.partitions) |items| items else if (profile_value) |profile_value_ptr| if (profile_value_ptr.install.storage.partitions.len == 0) &automatic_partitions else profile_value_ptr.install.storage.partitions else return error.MissingProfile;
        owned_partitions = try mutatePartitions(allocator, inherited, patch);
        target.overrides.install.storage.partitions = owned_partitions.?;
    } else if (std.mem.eql(u8, patch.key, "overrides.system.users")) {
        const inherited = if (target.overrides.system.users) |items| items else blk: {
            const profile_value = if (target.profile) |name| findProfile(&parsed.value, name) else null;
            break :blk (try install_compiler.effectiveSystem(profile_value orelse return error.MissingProfile)).users;
        };
        owned_users = try mutateUsers(allocator, inherited, patch);
        target.overrides.system.users = owned_users.?;
    } else return error.UnsupportedProperty;
    var candidate = parsed.value;
    candidate.nodes = nodes;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

pub fn profileUserValues(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, identity: []const u8, user_name: []const u8, field: []const u8, operation: value_mutation.Operation, requested: []const []const u8) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const profiles = try allocator.dupe(model.ProfileConfig, parsed.value.profiles);
    defer allocator.free(profiles);
    var selected: ?*model.ProfileConfig = null;
    for (profiles) |*item| if (std.mem.eql(u8, item.name, identity)) {
        selected = item;
        break;
    };
    const target = selected orelse return error.ProfileNotFound;
    const users = try allocator.dupe(model.TargetUserConfig, target.system.users);
    defer allocator.free(users);
    const owned = try mutateUserValueField(allocator, users, user_name, field, operation, requested);
    defer allocator.free(owned);
    target.system.users = users;
    var candidate = parsed.value;
    candidate.profiles = profiles;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

pub fn nodeUserValues(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, identity: []const u8, user_name: []const u8, field: []const u8, operation: value_mutation.Operation, requested: []const []const u8) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const nodes = try allocator.dupe(model.NodeConfig, parsed.value.nodes);
    defer allocator.free(nodes);
    var selected: ?*model.NodeConfig = null;
    for (nodes) |*item| if (std.mem.eql(u8, item.id, identity)) {
        selected = item;
        break;
    };
    const target = selected orelse return error.NodeNotFound;
    const inherited = if (target.overrides.system.users) |items| items else blk: {
        const profile_value = if (target.profile) |name| findProfile(&parsed.value, name) else null;
        break :blk (try install_compiler.effectiveSystem(profile_value orelse return error.MissingProfile)).users;
    };
    const users = try allocator.dupe(model.TargetUserConfig, inherited);
    defer allocator.free(users);
    const owned = try mutateUserValueField(allocator, users, user_name, field, operation, requested);
    defer allocator.free(owned);
    target.overrides.system.users = users;
    var candidate = parsed.value;
    candidate.nodes = nodes;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

fn mutateUserValueField(allocator: std.mem.Allocator, users: []model.TargetUserConfig, user_name: []const u8, field: []const u8, operation: value_mutation.Operation, requested: []const []const u8) ![]const []const u8 {
    const index = userIndex(users, user_name) orelse return error.ItemNotFound;
    const current = if (std.mem.eql(u8, field, "groups")) users[index].groups else if (std.mem.eql(u8, field, "ssh_authorized_keys")) users[index].ssh_authorized_keys else return error.UnknownItemField;
    const values = try mutateStringSet(allocator, current, operation, requested);
    if (std.mem.eql(u8, field, "groups")) users[index].groups = values else users[index].ssh_authorized_keys = values;
    return values;
}

fn mutateStringSet(allocator: std.mem.Allocator, current: []const []const u8, operation: value_mutation.Operation, requested: []const []const u8) ![]const []const u8 {
    for (requested, 0..) |value, index| {
        if (value.len == 0) return error.InvalidValue;
        for (requested[index + 1 ..]) |other| if (std.mem.eql(u8, value, other)) return error.DuplicateValue;
    }
    if (operation == .clear) return allocator.alloc([]const u8, 0);
    if (operation == .replace) return allocator.dupe([]const u8, requested);
    var output: std.ArrayList([]const u8) = .empty;
    defer output.deinit(allocator);
    try output.appendSlice(allocator, current);
    for (requested) |value| {
        var index: ?usize = null;
        for (output.items, 0..) |existing, existing_index| if (std.mem.eql(u8, existing, value)) {
            index = existing_index;
            break;
        };
        if (operation == .add) {
            if (index != null) return error.DuplicateValue;
            try output.append(allocator, value);
        } else {
            const found = index orelse return error.ValueNotFound;
            _ = output.orderedRemove(found);
        }
    }
    return output.toOwnedSlice(allocator);
}

pub fn replaceProfile(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, identity: []const u8, replacement: Replacement) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const profiles = try allocator.dupe(model.ProfileConfig, parsed.value.profiles);
    defer allocator.free(profiles);
    var selected: ?*model.ProfileConfig = null;
    for (profiles) |*item| if (std.mem.eql(u8, item.name, identity)) {
        selected = item;
        break;
    };
    const target = selected orelse return error.ProfileNotFound;
    if (std.mem.eql(u8, replacement.key, "install.storage.partitions")) {
        target.install.storage.partitions = replacement.partitions;
    } else if (std.mem.eql(u8, replacement.key, "system.users")) {
        target.system.users = replacement.users;
    } else return error.UnsupportedProperty;
    var candidate = parsed.value;
    candidate.profiles = profiles;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

pub fn replaceNode(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, identity: []const u8, replacement: Replacement) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const nodes = try allocator.dupe(model.NodeConfig, parsed.value.nodes);
    defer allocator.free(nodes);
    var selected: ?*model.NodeConfig = null;
    for (nodes) |*item| if (std.mem.eql(u8, item.id, identity)) {
        selected = item;
        break;
    };
    const target = selected orelse return error.NodeNotFound;
    if (std.mem.eql(u8, replacement.key, "network.routes")) {
        target.network.routes = replacement.routes;
    } else if (std.mem.eql(u8, replacement.key, "overrides.install.storage.partitions")) {
        target.overrides.install.storage.partitions = if (replacement.operation == .clear) null else replacement.partitions;
    } else if (std.mem.eql(u8, replacement.key, "overrides.system.users")) {
        target.overrides.system.users = if (replacement.operation == .clear) null else replacement.users;
    } else return error.UnsupportedProperty;
    var candidate = parsed.value;
    candidate.nodes = nodes;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

fn mutatePartitions(allocator: std.mem.Allocator, current: []const model.PartitionConfig, patch: Patch) ![]model.PartitionConfig {
    const found = partitionIndex(current, patch.identity);
    return switch (patch.operation) {
        .add => blk: {
            if (found != null or patch.id == null or !std.mem.eql(u8, patch.id.?, patch.identity)) return error.InvalidItemIdentity;
            const values = try allocator.alloc(model.PartitionConfig, current.len + 1);
            @memcpy(values[0..current.len], current);
            values[current.len] = .{ .id = patch.id, .mount = patch.mount, .filesystem = patch.filesystem, .size_mib = patch.size_mib orelse 0, .grow = patch.grow orelse false, .kind = patch.kind orelse .plain };
            break :blk values;
        },
        .set => blk: {
            const index = found orelse return error.ItemNotFound;
            const values = try allocator.dupe(model.PartitionConfig, current);
            var value = values[index];
            if (patch.mount) |field_value| value.mount = field_value;
            if (patch.filesystem) |field_value| value.filesystem = field_value;
            if (patch.size_mib) |field_value| value.size_mib = field_value;
            if (patch.grow) |field_value| value.grow = field_value;
            if (patch.kind) |field_value| value.kind = field_value;
            for (patch.unset) |field_name| {
                if (std.mem.eql(u8, field_name, "mount")) value.mount = null else if (std.mem.eql(u8, field_name, "filesystem")) value.filesystem = null else if (std.mem.eql(u8, field_name, "size_mib")) value.size_mib = 0 else return error.UnknownItemField;
            }
            values[index] = value;
            break :blk values;
        },
        .remove => try removeAt(model.PartitionConfig, allocator, current, found orelse return error.ItemNotFound),
        .move => try moveAt(model.PartitionConfig, allocator, current, found orelse return error.ItemNotFound, try destinationIndexPartitions(current, patch)),
    };
}

fn mutateUsers(allocator: std.mem.Allocator, current: []const model.TargetUserConfig, patch: Patch) ![]model.TargetUserConfig {
    const found = userIndex(current, patch.identity);
    return switch (patch.operation) {
        .add => blk: {
            if (found != null or patch.name == null or !std.mem.eql(u8, patch.name.?, patch.identity)) return error.InvalidItemIdentity;
            const values = try allocator.alloc(model.TargetUserConfig, current.len + 1);
            @memcpy(values[0..current.len], current);
            values[current.len] = .{ .name = patch.name.?, .uid = patch.uid, .shell = patch.shell, .locked = patch.locked orelse false, .password = patch.password, .sudo = patch.sudo orelse false };
            break :blk values;
        },
        .set => blk: {
            const index = found orelse return error.ItemNotFound;
            const values = try allocator.dupe(model.TargetUserConfig, current);
            var value = values[index];
            if (patch.uid) |field_value| value.uid = field_value;
            if (patch.shell) |field_value| value.shell = field_value;
            if (patch.locked) |field_value| value.locked = field_value;
            if (patch.password) |field_value| value.password = field_value;
            if (patch.sudo) |field_value| value.sudo = field_value;
            for (patch.unset) |field_name| {
                if (std.mem.eql(u8, field_name, "uid")) value.uid = null else if (std.mem.eql(u8, field_name, "shell")) value.shell = null else if (std.mem.eql(u8, field_name, "password")) value.password = null else return error.UnknownItemField;
            }
            values[index] = value;
            break :blk values;
        },
        .remove => try removeAt(model.TargetUserConfig, allocator, current, found orelse return error.ItemNotFound),
        .move => try moveAt(model.TargetUserConfig, allocator, current, found orelse return error.ItemNotFound, try destinationIndexUsers(current, patch)),
    };
}

fn mutateRoutes(allocator: std.mem.Allocator, current: []const model.RouteConfig, patch: Patch) ![]model.RouteConfig {
    const found = routeIndex(current, patch.identity);
    return switch (patch.operation) {
        .add => blk: {
            if (found != null or patch.id == null or !std.mem.eql(u8, patch.id.?, patch.identity) or patch.destination == null or patch.gateway == null) return error.InvalidItemIdentity;
            const values = try allocator.alloc(model.RouteConfig, current.len + 1);
            @memcpy(values[0..current.len], current);
            values[current.len] = .{ .id = patch.id.?, .destination = patch.destination.?, .gateway = patch.gateway.?, .metric = patch.metric };
            break :blk values;
        },
        .set => blk: {
            const index = found orelse return error.ItemNotFound;
            const values = try allocator.dupe(model.RouteConfig, current);
            if (patch.destination) |field_value| values[index].destination = field_value;
            if (patch.gateway) |field_value| values[index].gateway = field_value;
            if (patch.metric) |field_value| values[index].metric = field_value;
            for (patch.unset) |field_name| {
                if (std.mem.eql(u8, field_name, "metric")) values[index].metric = null else return error.UnknownItemField;
            }
            break :blk values;
        },
        .remove => try removeAt(model.RouteConfig, allocator, current, found orelse return error.ItemNotFound),
        .move => try moveAt(model.RouteConfig, allocator, current, found orelse return error.ItemNotFound, try destinationIndexRoutes(current, patch)),
    };
}

fn removeAt(comptime T: type, allocator: std.mem.Allocator, current: []const T, index: usize) ![]T {
    const values = try allocator.alloc(T, current.len - 1);
    @memcpy(values[0..index], current[0..index]);
    @memcpy(values[index..], current[index + 1 ..]);
    return values;
}
fn moveAt(comptime T: type, allocator: std.mem.Allocator, current: []const T, from: usize, target_index: usize) ![]T {
    const values = try allocator.dupe(T, current);
    const value = values[from];
    if (from < target_index) {
        std.mem.copyForwards(T, values[from..target_index], values[from + 1 .. target_index + 1]);
        values[target_index] = value;
    } else if (from > target_index) {
        std.mem.copyBackwards(T, values[target_index + 1 .. from + 1], values[target_index..from]);
        values[target_index] = value;
    }
    return values;
}
fn partitionIndex(values: []const model.PartitionConfig, id: []const u8) ?usize {
    for (values, 0..) |value, index| if (value.id != null and std.mem.eql(u8, value.id.?, id)) return index;
    return null;
}
fn userIndex(values: []const model.TargetUserConfig, id: []const u8) ?usize {
    for (values, 0..) |value, index| if (std.mem.eql(u8, value.name, id)) return index;
    return null;
}
fn routeIndex(values: []const model.RouteConfig, id: []const u8) ?usize {
    for (values, 0..) |value, index| if (std.mem.eql(u8, value.id, id)) return index;
    return null;
}
fn destination(patch: Patch) !struct { id: []const u8, before: bool } {
    if ((patch.before == null) == (patch.after == null)) return error.MoveDestinationRequired;
    return if (patch.before) |id| .{ .id = id, .before = true } else .{ .id = patch.after.?, .before = false };
}
fn destinationIndexPartitions(values: []const model.PartitionConfig, patch: Patch) !usize {
    const target = try destination(patch);
    const index = partitionIndex(values, target.id) orelse return error.ItemNotFound;
    return if (target.before) index else @min(index + 1, values.len - 1);
}
fn destinationIndexUsers(values: []const model.TargetUserConfig, patch: Patch) !usize {
    const target = try destination(patch);
    const index = userIndex(values, target.id) orelse return error.ItemNotFound;
    return if (target.before) index else @min(index + 1, values.len - 1);
}
fn destinationIndexRoutes(values: []const model.RouteConfig, patch: Patch) !usize {
    const target = try destination(patch);
    const index = routeIndex(values, target.id) orelse return error.ItemNotFound;
    return if (target.before) index else @min(index + 1, values.len - 1);
}
fn findProfile(catalog: *const model.Catalog, name: []const u8) ?*const model.ProfileConfig {
    for (catalog.profiles) |*profile_value| if (std.mem.eql(u8, profile_value.name, name)) return profile_value;
    return null;
}

test "first partition edit materializes stable automatic identities" {
    const values = try mutatePartitions(std.testing.allocator, &automatic_partitions, .{ .operation = .set, .key = "install.storage.partitions", .identity = "root", .grow = false, .size_mib = 51200 });
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(usize, 3), values.len);
    try std.testing.expectEqualStrings("root", values[2].id.?);
    try std.testing.expectEqual(@as(u32, 51200), values[2].size_mib);
}

test "user replacement edits preserve inherited users and stable names" {
    const inherited = [_]model.TargetUserConfig{.{ .name = "nodeforge", .password = "asdf1234" }};
    const values = try mutateUsers(std.testing.allocator, &inherited, .{ .operation = .set, .key = "overrides.system.users", .identity = "nodeforge", .shell = "/bin/zsh" });
    defer std.testing.allocator.free(values);
    try std.testing.expectEqual(@as(usize, 1), values.len);
    try std.testing.expectEqualStrings("nodeforge", values[0].name);
    try std.testing.expectEqualStrings("asdf1234", values[0].password.?);
    try std.testing.expectEqualStrings("/bin/zsh", values[0].shell.?);
}

test "item-scoped user collections mutate atomically" {
    var users = [_]model.TargetUserConfig{.{ .name = "ops", .groups = &.{"wheel"}, .ssh_authorized_keys = &.{"ssh-ed25519 AAAA old"} }};
    const groups = try mutateUserValueField(std.testing.allocator, &users, "ops", "groups", .add, &.{"adm"});
    defer std.testing.allocator.free(groups);
    try std.testing.expectEqualSlices([]const u8, &.{ "wheel", "adm" }, users[0].groups);
    const keys = try mutateUserValueField(std.testing.allocator, &users, "ops", "ssh_authorized_keys", .replace, &.{"ssh-ed25519 BBBB new"});
    defer std.testing.allocator.free(keys);
    try std.testing.expectEqualSlices([]const u8, &.{"ssh-ed25519 BBBB new"}, users[0].ssh_authorized_keys);
    try std.testing.expectError(error.DuplicateValue, mutateUserValueField(std.testing.allocator, &users, "ops", "groups", .add, &.{"wheel"}));
}
