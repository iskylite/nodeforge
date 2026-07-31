//! # registry 寻址的标量集合变更
//!
//! 处理 `software.packages.include`、`system.connectivity.ntp_servers` 等
//! 字符串集合的 add/remove/replace/clear 操作。与 item_mutation 不同，
//! 这些集合的元素是字符串而非结构化对象。
const std = @import("std");
const model = @import("../model.zig");
const properties = @import("../cli/properties.zig");
const catalog_store = @import("../catalog/store.zig");
const validate = @import("validate.zig");
const scalar_mutation = @import("scalar_mutation.zig");
const profile_mutation = @import("profile_mutation.zig");

/// 集合操作类型。
pub const Operation = enum {
    /// 追加元素。
    add,
    /// 删除元素。
    remove,
    /// 用新列表完整替换。
    replace,
    /// 清空集合。
    clear,
};

/// 修改 profile 的字符串集合属性。
/// `key` 指定目标字段（如 `software.groups`），`operation` 指定操作类型。
pub fn profile(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, name: []const u8, key: []const u8, operation: Operation, values: []const []const u8) !void {
    const spec = properties.collection(.profile, key) orelse return error.UnknownProperty;
    if (spec.mutability != .mutable or spec.item_spec != null) return error.UnsupportedProperty;
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const profiles = try allocator.dupe(model.ProfileConfig, parsed.value.profiles);
    defer allocator.free(profiles);
    var target: ?*model.ProfileConfig = null;
    for (profiles) |*item| if (std.mem.eql(u8, item.name, name)) {
        target = item;
        break;
    };
    const selected = target orelse return error.ProfileNotFound;
    var owned: ?[]const []const u8 = null;
    defer if (owned) |items| allocator.free(items);
    if (std.mem.eql(u8, key, "system.connectivity.ntp_servers")) {
        owned = try apply(allocator, selected.system.connectivity.ntp_servers, operation, values);
        selected.system.connectivity.ntp_servers = owned.?;
    } else if (std.mem.eql(u8, key, "system.ssh.root_authorized_keys")) {
        owned = try apply(allocator, selected.system.ssh.root_authorized_keys, operation, values);
        selected.system.ssh.root_authorized_keys = owned.?;
    } else if (std.mem.eql(u8, key, "software.repositories")) {
        owned = try apply(allocator, selected.software.repositories, operation, values);
        selected.software.repositories = owned.?;
    } else if (std.mem.eql(u8, key, "software.groups")) {
        owned = try apply(allocator, selected.software.groups, operation, values);
        selected.software.groups = owned.?;
    } else if (std.mem.eql(u8, key, "software.tasks")) {
        owned = try apply(allocator, selected.software.tasks, operation, values);
        selected.software.tasks = owned.?;
    } else if (std.mem.eql(u8, key, "software.packages.include")) {
        owned = try apply(allocator, selected.software.packages.include, operation, values);
        selected.software.packages.include = owned.?;
    } else if (std.mem.eql(u8, key, "software.packages.exclude")) {
        owned = try apply(allocator, selected.software.packages.exclude, operation, values);
        selected.software.packages.exclude = owned.?;
    } else if (std.mem.eql(u8, key, "kernel_args")) {
        var old: std.ArrayList([]const u8) = .empty;
        defer old.deinit(allocator);
        if (selected.kernel_args) |text| {
            var iterator = std.mem.tokenizeScalar(u8, text, ' ');
            while (iterator.next()) |value| try old.append(allocator, value);
        }
        owned = try applyKernelArgs(allocator, old.items, operation, values);
        selected.kernel_args = try join(allocator, owned.?);
        defer if (selected.kernel_args) |text| allocator.free(text);
    } else if (std.mem.eql(u8, key, "install.proxy.no_proxy")) {
        owned = try apply(allocator, selected.install.proxy.no_proxy, operation, values);
        selected.install.proxy.no_proxy = owned.?;
    } else return error.UnsupportedProperty;
    var candidate = parsed.value;
    candidate.profiles = profiles;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    // v0.2.3 §5.4: 所有 profile mutation 统一走 revision helper。
    try profile_mutation.mutateProfileMetadata(profiles, name, std.Io.Clock.real.now(io).toSeconds());
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

pub fn node(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, id: []const u8, key: []const u8, operation: Operation, values: []const []const u8, scalar_mutations: []const scalar_mutation.Mutation) !void {
    const spec = properties.collection(.node, key) orelse return error.UnknownProperty;
    if (spec.mutability != .mutable or spec.item_spec != null) return error.UnsupportedProperty;
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const nodes = try allocator.dupe(model.NodeConfig, parsed.value.nodes);
    defer allocator.free(nodes);
    var target: ?*model.NodeConfig = null;
    for (nodes) |*item| if (std.mem.eql(u8, item.id, id)) {
        target = item;
        break;
    };
    const selected = target orelse return error.NodeNotFound;
    for (scalar_mutations) |mutation| try scalar_mutation.applyNode(selected, mutation.key, mutation.value);
    var owned: ?[]const []const u8 = null;
    defer if (owned) |items| allocator.free(items);
    if (std.mem.eql(u8, key, "network.dns")) {
        owned = try apply(allocator, selected.network.dns, operation, values);
        selected.network.dns = owned.?;
    } else if (std.mem.eql(u8, key, "network.search_domains")) {
        owned = try apply(allocator, selected.network.search_domains, operation, values);
        selected.network.search_domains = owned.?;
    } else if (std.mem.eql(u8, key, "storage.additional_disks")) {
        owned = try apply(allocator, selected.storage.additional_disks, operation, values);
        selected.storage.additional_disks = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.software.repositories.add")) {
        owned = try apply(allocator, selected.overrides.software.repositories.add, operation, values);
        selected.overrides.software.repositories.add = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.software.repositories.remove")) {
        owned = try apply(allocator, selected.overrides.software.repositories.remove, operation, values);
        selected.overrides.software.repositories.remove = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.software.groups.add")) {
        owned = try apply(allocator, selected.overrides.software.groups.add, operation, values);
        selected.overrides.software.groups.add = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.software.groups.remove")) {
        owned = try apply(allocator, selected.overrides.software.groups.remove, operation, values);
        selected.overrides.software.groups.remove = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.software.tasks.add")) {
        owned = try apply(allocator, selected.overrides.software.tasks.add, operation, values);
        selected.overrides.software.tasks.add = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.software.tasks.remove")) {
        owned = try apply(allocator, selected.overrides.software.tasks.remove, operation, values);
        selected.overrides.software.tasks.remove = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.software.packages.include.add")) {
        owned = try apply(allocator, selected.overrides.software.packages_include.add, operation, values);
        selected.overrides.software.packages_include.add = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.software.packages.include.remove")) {
        owned = try apply(allocator, selected.overrides.software.packages_include.remove, operation, values);
        selected.overrides.software.packages_include.remove = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.kernel_args.add")) {
        owned = try applyKernelArgs(allocator, selected.overrides.kernel_args.add, operation, values);
        selected.overrides.kernel_args.add = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.kernel_args.remove")) {
        owned = try applyKernelArgs(allocator, selected.overrides.kernel_args.remove, operation, values);
        selected.overrides.kernel_args.remove = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.system.connectivity.ntp_servers.add")) {
        owned = try apply(allocator, selected.overrides.system.connectivity.ntp_servers.add, operation, values);
        selected.overrides.system.connectivity.ntp_servers.add = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.system.connectivity.ntp_servers.remove")) {
        owned = try apply(allocator, selected.overrides.system.connectivity.ntp_servers.remove, operation, values);
        selected.overrides.system.connectivity.ntp_servers.remove = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.system.ssh.root_authorized_keys.add")) {
        owned = try apply(allocator, selected.overrides.system.ssh.root_authorized_keys.add, operation, values);
        selected.overrides.system.ssh.root_authorized_keys.add = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.system.ssh.root_authorized_keys.remove")) {
        owned = try apply(allocator, selected.overrides.system.ssh.root_authorized_keys.remove, operation, values);
        selected.overrides.system.ssh.root_authorized_keys.remove = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.software.packages.exclude.add")) {
        owned = try apply(allocator, selected.overrides.software.packages_exclude.add, operation, values);
        selected.overrides.software.packages_exclude.add = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.software.packages.exclude.remove")) {
        owned = try apply(allocator, selected.overrides.software.packages_exclude.remove, operation, values);
        selected.overrides.software.packages_exclude.remove = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.install.proxy.no_proxy.add")) {
        owned = try apply(allocator, selected.overrides.install.proxy_no_proxy.add, operation, values);
        selected.overrides.install.proxy_no_proxy.add = owned.?;
    } else if (std.mem.eql(u8, key, "overrides.install.proxy.no_proxy.remove")) {
        owned = try apply(allocator, selected.overrides.install.proxy_no_proxy.remove, operation, values);
        selected.overrides.install.proxy_no_proxy.remove = owned.?;
    } else return error.UnsupportedProperty;
    var candidate = parsed.value;
    candidate.nodes = nodes;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

fn apply(allocator: std.mem.Allocator, current: []const []const u8, operation: Operation, values: []const []const u8) ![]const []const u8 {
    try unique(values);
    if (operation == .clear) {
        if (values.len != 0) return error.ValuesNotAllowed;
        return allocator.alloc([]const u8, 0);
    }
    if (values.len == 0) return error.ValuesRequired;
    if (operation == .replace) return allocator.dupe([]const u8, values);
    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);
    try result.appendSlice(allocator, current);
    switch (operation) {
        .add => for (values) |value| {
            if (contains(result.items, value)) return error.DuplicateValue;
            try result.append(allocator, value);
        },
        .remove => for (values) |value| {
            const index = indexOf(result.items, value) orelse return error.ValueNotFound;
            _ = result.orderedRemove(index);
        },
        else => unreachable,
    }
    return result.toOwnedSlice(allocator);
}

fn applyKernelArgs(allocator: std.mem.Allocator, current: []const []const u8, operation: Operation, values: []const []const u8) ![]const []const u8 {
    try uniqueKernelNames(values);
    if (operation == .clear) {
        if (values.len != 0) return error.ValuesNotAllowed;
        return allocator.alloc([]const u8, 0);
    }
    if (values.len == 0) return error.ValuesRequired;
    if (operation == .replace) return allocator.dupe([]const u8, values);
    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);
    try result.appendSlice(allocator, current);
    switch (operation) {
        .add => for (values) |value| {
            if (kernelIndex(result.items, kernelName(value))) |index| result.items[index] = value else try result.append(allocator, value);
        },
        .remove => for (values) |value| {
            const index = kernelIndex(result.items, kernelName(value)) orelse return error.ValueNotFound;
            _ = result.orderedRemove(index);
        },
        else => unreachable,
    }
    return result.toOwnedSlice(allocator);
}

fn kernelName(value: []const u8) []const u8 {
    return value[0 .. std.mem.indexOfScalar(u8, value, '=') orelse value.len];
}
fn kernelIndex(values: []const []const u8, name: []const u8) ?usize {
    for (values, 0..) |value, index| if (std.mem.eql(u8, kernelName(value), name)) return index;
    return null;
}
fn uniqueKernelNames(values: []const []const u8) !void {
    for (values, 0..) |value, index| {
        const name = kernelName(value);
        if (name.len == 0) return error.InvalidKernelArgument;
        for (values[index + 1 ..]) |other| if (std.mem.eql(u8, name, kernelName(other))) return error.DuplicateValue;
    }
}
fn unique(values: []const []const u8) !void {
    for (values, 0..) |value, index| for (values[index + 1 ..]) |other| if (std.mem.eql(u8, value, other)) return error.DuplicateValue;
}
fn contains(values: []const []const u8, value: []const u8) bool {
    return indexOf(values, value) != null;
}
fn indexOf(values: []const []const u8, value: []const u8) ?usize {
    for (values, 0..) |item, index| if (std.mem.eql(u8, item, value)) return index;
    return null;
}
fn join(allocator: std.mem.Allocator, values: []const []const u8) !?[]u8 {
    if (values.len == 0) return null;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    for (values, 0..) |value, index| {
        if (index != 0) try output.writer.writeByte(' ');
        try output.writer.writeAll(value);
    }
    const owned = try output.toOwnedSlice();
    return owned;
}

test "collection operations reject duplicates and preserve order" {
    const added = try apply(std.testing.allocator, &.{ "a", "b" }, .add, &.{"c"});
    defer std.testing.allocator.free(added);
    try std.testing.expectEqualStrings("c", added[2]);
    try std.testing.expectError(error.DuplicateValue, apply(std.testing.allocator, &.{"a"}, .add, &.{"a"}));
}

test "kernel argument collections replace and remove by parameter name" {
    const replaced = try applyKernelArgs(std.testing.allocator, &.{ "quiet", "console=tty0" }, .add, &.{"console=ttyS0"});
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("console=ttyS0", replaced[1]);
    const removed = try applyKernelArgs(std.testing.allocator, replaced, .remove, &.{"console"});
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualSlices([]const u8, &.{"quiet"}, removed);
    try std.testing.expectError(error.DuplicateValue, applyKernelArgs(std.testing.allocator, &.{}, .replace, &.{ "iommu", "iommu=pt" }));
}
