//! 规范化 CLI 变更词汇表。
//!
//! Help、list/show 导航、parser 和 contract test 必须消费这些名称，
//! 而不是维护独立的白名单。这确保 CLI 变更命令、帮助文本和校验逻辑
//! 始终引用同一组属性路径和集合语义，避免漂移。

const std = @import("std");

/// 属性归属的配置层级。决定 `node set`/`profile set`/`site set` 等命令的目标。
pub const Owner = enum { site, node, profile, assets };
/// 属性值的类型。用于 parser 校验和 help 文档。
pub const ValueKind = enum { string, boolean, positive_integer, arch, enumeration };
/// 属性的可变性。`read_only` 表示只能通过 list/show 查看不能通过 set 变更。
pub const Mutability = enum { mutable, read_only };
/// 属性的适用范围。限定属性只在特定安装适配器或引导方式下有效。
pub const Applicability = enum { all, kickstart, autoinstall, uefi_grub };

/// 标量属性规范。描述一个属性的归属、路径、值类型和变更约束。
pub const PropertySpec = struct {
    /// 归属层级（site/node/profile/assets）。
    owner: Owner,
    /// 点分属性路径（如 `storage.boot_disk`）。
    path: []const u8,
    /// 值类型。
    kind: ValueKind,
    /// 是否可选（缺省为必填）。
    optional: bool = false,
    /// 可变性。
    mutability: Mutability = .mutable,
    /// 适用范围。
    applicability: Applicability = .all,
    /// CLI 接受的有限值或格式/范围提示。枚举属性必须显式填写，帮助生成器直接消费。
    value_constraint: ?[]const u8 = null,
};

/// 集合变更语义。决定 `set`/`add`/`remove` 命令如何处理集合内容。
pub const CollectionSemantics = enum {
    /// 有序列表替换：用新列表整体替换旧列表（如 partitions、routes）。
    ordered_replace,
    /// 集合：无序去重，add/remove 增删元素。
    set,
    /// 增量：add/remove 分别追加/移除元素，不要求整体替换。
    delta,
    /// 内核参数：特殊语义，支持 `key=value` 和 `key` 两种形式。
    kernel_arguments,
};
/// 集合属性规范。描述一个集合属性的归属、路径和变更语义。
pub const CollectionSpec = struct {
    owner: Owner,
    path: []const u8,
    semantics: CollectionSemantics,
    /// 引用的 item 规格名称（如 `partition`、`route`、`user`）。
    item_spec: ?[]const u8 = null,
    mutability: Mutability = .mutable,
};

/// 集合 item 的标量字段定义。
pub const ItemField = struct {
    name: []const u8,
    kind: ValueKind,
    required: bool = false,
    /// CLI 接受的有限值或格式/范围提示；不能只依赖 mutation parser 的错误信息。
    value_constraint: ?[]const u8 = null,
};
/// 集合 item 的嵌套集合字段定义。
pub const ItemCollectionField = struct { name: []const u8, semantics: CollectionSemantics = .set };
/// 集合 item 规格。定义有序替换集合中每个元素的标识字段、标量字段和嵌套集合。
pub const ItemSpec = struct { name: []const u8, identity: []const u8, fields: []const ItemField, collections: []const ItemCollectionField = &.{} };

pub const properties = [_]PropertySpec{
    .{ .owner = .site, .path = "discovery.policy.unknown_action", .kind = .enumeration, .value_constraint = "record|deny" },
    .{ .owner = .site, .path = "discovery.policy.observation_retention_days", .kind = .positive_integer },
    .{ .owner = .node, .path = "mac", .kind = .string },
    .{ .owner = .node, .path = "arch", .kind = .arch, .value_constraint = "x86_64|aarch64" },
    .{ .owner = .node, .path = "profile", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "pxe.ip_reservation", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "hostname", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "deploy", .kind = .boolean },
    .{ .owner = .node, .path = "http_accel", .kind = .boolean, .applicability = .uefi_grub },
    .{ .owner = .node, .path = "network.mode", .kind = .enumeration, .value_constraint = "dhcp|static" },
    .{ .owner = .node, .path = "network.interface_name", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "network.match_mac", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "network.address", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "network.prefix_len", .kind = .positive_integer, .optional = true, .value_constraint = "1..32" },
    .{ .owner = .node, .path = "network.gateway", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "storage.boot_disk", .kind = .string },
    .{ .owner = .node, .path = "overrides.install.storage.mode", .kind = .enumeration, .optional = true, .value_constraint = "single|lvm|raid0|raid1|raid5|raid6|raid10|raid0-lvm|raid1-lvm|raid5-lvm|raid6-lvm|raid10-lvm" },
    .{ .owner = .node, .path = "overrides.install.storage.wipe", .kind = .boolean, .optional = true },
    .{ .owner = .node, .path = "overrides.install.storage.partition_table", .kind = .enumeration, .optional = true, .value_constraint = "gpt|mbr" },
    .{ .owner = .node, .path = "overrides.install.bootloader.install", .kind = .boolean, .optional = true },
    .{ .owner = .node, .path = "overrides.system.localization.locale", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "overrides.system.localization.timezone", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "overrides.system.localization.keyboard", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "overrides.system.connectivity.time_sync", .kind = .boolean, .optional = true },
    .{ .owner = .node, .path = "overrides.system.ssh.enabled", .kind = .boolean, .optional = true },
    .{ .owner = .node, .path = "overrides.system.ssh.password_authentication", .kind = .boolean, .optional = true },
    .{ .owner = .node, .path = "overrides.system.ssh.root_login", .kind = .enumeration, .optional = true, .value_constraint = "no|prohibit-password|yes" },
    .{ .owner = .node, .path = "overrides.system.ssh.root_password", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "overrides.system.security.firewall", .kind = .enumeration, .optional = true, .value_constraint = "disabled|enabled" },
    .{ .owner = .node, .path = "overrides.system.security.selinux", .kind = .enumeration, .optional = true, .value_constraint = "disabled|permissive|enforcing" },
    .{ .owner = .node, .path = "overrides.system.security.apparmor", .kind = .enumeration, .optional = true, .value_constraint = "disabled|complain|enforce" },
    .{ .owner = .node, .path = "overrides.software.environment", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "overrides.install.apt.fallback", .kind = .enumeration, .optional = true, .value_constraint = "abort|offline-install|continue-anyway" },
    .{ .owner = .node, .path = "overrides.install.apt.preserve_sources_list", .kind = .boolean, .optional = true },
    .{ .owner = .node, .path = "overrides.install.completion.action", .kind = .enumeration, .optional = true, .value_constraint = "reboot|poweroff|halt" },
    .{ .owner = .node, .path = "overrides.install.updates.mode", .kind = .enumeration, .optional = true, .value_constraint = "none|security|all" },
    .{ .owner = .node, .path = "overrides.install.proxy.url", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "overrides.install.reinstall_policy", .kind = .enumeration, .optional = true, .value_constraint = "explicit|always" },
    .{ .owner = .node, .path = "overrides.install.post_install.bundle", .kind = .string, .optional = true },
    .{ .owner = .node, .path = "overrides.diskless.overlay.tmpfs_percent", .kind = .positive_integer, .optional = true },
    .{ .owner = .node, .path = "overrides.diskless.provision.bundle", .kind = .string, .optional = true },
    .{ .owner = .profile, .path = "install_source", .kind = .string },
    .{ .owner = .profile, .path = "install.storage.mode", .kind = .enumeration, .value_constraint = "single|lvm|raid0|raid1|raid5|raid6|raid10|raid0-lvm|raid1-lvm|raid5-lvm|raid6-lvm|raid10-lvm" },
    .{ .owner = .profile, .path = "install.storage.wipe", .kind = .boolean },
    .{ .owner = .profile, .path = "install.storage.partition_table", .kind = .enumeration, .value_constraint = "gpt|mbr" },
    .{ .owner = .profile, .path = "install.bootloader.install", .kind = .boolean },
    .{ .owner = .profile, .path = "system.localization.locale", .kind = .string },
    .{ .owner = .profile, .path = "system.localization.timezone", .kind = .string },
    .{ .owner = .profile, .path = "system.localization.keyboard", .kind = .string },
    .{ .owner = .profile, .path = "system.connectivity.time_sync", .kind = .boolean },
    .{ .owner = .profile, .path = "system.ssh.enabled", .kind = .boolean },
    .{ .owner = .profile, .path = "system.ssh.password_authentication", .kind = .boolean },
    .{ .owner = .profile, .path = "system.ssh.root_login", .kind = .enumeration, .value_constraint = "no|prohibit-password|yes" },
    .{ .owner = .profile, .path = "system.ssh.root_password", .kind = .string, .optional = true },
    .{ .owner = .profile, .path = "system.import_host_hosts", .kind = .boolean },
    .{ .owner = .profile, .path = "system.hosts_content", .kind = .string, .optional = true },
    .{ .owner = .profile, .path = "system.security.firewall", .kind = .enumeration, .value_constraint = "disabled|enabled" },
    .{ .owner = .profile, .path = "system.security.selinux", .kind = .enumeration, .applicability = .kickstart, .value_constraint = "disabled|permissive|enforcing" },
    .{ .owner = .profile, .path = "system.security.apparmor", .kind = .enumeration, .applicability = .autoinstall, .value_constraint = "disabled|complain|enforce" },
    .{ .owner = .profile, .path = "software.environment", .kind = .string, .optional = true, .applicability = .kickstart },
    .{ .owner = .profile, .path = "install.apt.fallback", .kind = .enumeration, .applicability = .autoinstall, .value_constraint = "abort|offline-install|continue-anyway" },
    .{ .owner = .profile, .path = "install.apt.preserve_sources_list", .kind = .boolean, .applicability = .autoinstall },
    .{ .owner = .profile, .path = "install.completion.action", .kind = .enumeration, .value_constraint = "reboot|poweroff|halt" },
    .{ .owner = .profile, .path = "install.updates.mode", .kind = .enumeration, .value_constraint = "none|security|all" },
    .{ .owner = .profile, .path = "install.proxy.url", .kind = .string, .optional = true },
    .{ .owner = .profile, .path = "install.reinstall_policy", .kind = .enumeration, .value_constraint = "explicit|always" },
    .{ .owner = .profile, .path = "install.post_install.bundle", .kind = .string, .optional = true },
    .{ .owner = .profile, .path = "diskless.boot_bundle", .kind = .string },
    .{ .owner = .profile, .path = "diskless.overlay.tmpfs_percent", .kind = .positive_integer },
    .{ .owner = .profile, .path = "diskless.overlay.minimum_free_bytes", .kind = .positive_integer },
    .{ .owner = .profile, .path = "diskless.overlay.safety_margin_bytes", .kind = .positive_integer },
    .{ .owner = .profile, .path = "diskless.failure.max_attempts", .kind = .positive_integer },
    .{ .owner = .profile, .path = "diskless.failure.backoff_seconds", .kind = .positive_integer },
    .{ .owner = .profile, .path = "diskless.provision.bundle", .kind = .string, .optional = true },
};

pub const collections = [_]CollectionSpec{
    .{ .owner = .node, .path = "network.dns", .semantics = .set },
    .{ .owner = .node, .path = "network.search_domains", .semantics = .set },
    .{ .owner = .node, .path = "network.routes", .semantics = .ordered_replace, .item_spec = "route" },
    .{ .owner = .node, .path = "overrides.install.storage.partitions", .semantics = .ordered_replace, .item_spec = "partition" },
    .{ .owner = .node, .path = "overrides.system.users", .semantics = .ordered_replace, .item_spec = "user" },
    .{ .owner = .node, .path = "storage.additional_disks", .semantics = .set },
    .{ .owner = .node, .path = "overrides.software.repositories.add", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.software.repositories.remove", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.software.groups.add", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.software.groups.remove", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.software.tasks.add", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.software.tasks.remove", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.software.packages.include.add", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.software.packages.include.remove", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.kernel_args.add", .semantics = .kernel_arguments },
    .{ .owner = .node, .path = "overrides.kernel_args.remove", .semantics = .kernel_arguments },
    .{ .owner = .node, .path = "overrides.system.connectivity.ntp_servers.add", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.system.connectivity.ntp_servers.remove", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.system.ssh.root_authorized_keys.add", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.system.ssh.root_authorized_keys.remove", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.software.packages.exclude.add", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.software.packages.exclude.remove", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.install.proxy.no_proxy.add", .semantics = .delta },
    .{ .owner = .node, .path = "overrides.install.proxy.no_proxy.remove", .semantics = .delta },
    .{ .owner = .profile, .path = "install.storage.partitions", .semantics = .ordered_replace, .item_spec = "partition" },
    .{ .owner = .profile, .path = "system.connectivity.ntp_servers", .semantics = .set },
    .{ .owner = .profile, .path = "system.ssh.root_authorized_keys", .semantics = .set },
    .{ .owner = .profile, .path = "system.users", .semantics = .ordered_replace, .item_spec = "user" },
    .{ .owner = .profile, .path = "software.repositories", .semantics = .set },
    .{ .owner = .profile, .path = "software.groups", .semantics = .set },
    .{ .owner = .profile, .path = "software.tasks", .semantics = .set },
    .{ .owner = .profile, .path = "software.packages.include", .semantics = .set },
    .{ .owner = .profile, .path = "software.packages.exclude", .semantics = .set },
    .{ .owner = .profile, .path = "kernel_args", .semantics = .kernel_arguments },
    .{ .owner = .profile, .path = "install.proxy.no_proxy", .semantics = .set },
    .{ .owner = .node, .path = "effective.install.storage.partitions", .semantics = .ordered_replace, .item_spec = "partition", .mutability = .read_only },
    .{ .owner = .assets, .path = "steps", .semantics = .ordered_replace, .item_spec = "managed-file-step" },
};

const partition_fields = [_]ItemField{
    .{ .name = "id", .kind = .string, .required = true }, .{ .name = "kind", .kind = .enumeration, .value_constraint = "esp|biosboot|swap|root|boot|plain" }, .{ .name = "mount", .kind = .string }, .{ .name = "filesystem", .kind = .string }, .{ .name = "size_mib", .kind = .positive_integer }, .{ .name = "grow", .kind = .boolean },
};
const route_fields = [_]ItemField{
    .{ .name = "id", .kind = .string, .required = true }, .{ .name = "destination", .kind = .string, .required = true }, .{ .name = "gateway", .kind = .string, .required = true }, .{ .name = "metric", .kind = .positive_integer },
};
const user_fields = [_]ItemField{
    .{ .name = "name", .kind = .string, .required = true }, .{ .name = "uid", .kind = .positive_integer }, .{ .name = "shell", .kind = .string }, .{ .name = "locked", .kind = .boolean }, .{ .name = "password", .kind = .string }, .{ .name = "sudo", .kind = .boolean },
};
const user_collections = [_]ItemCollectionField{ .{ .name = "groups" }, .{ .name = "ssh_authorized_keys" } };
const managed_file_step_fields = [_]ItemField{
    .{ .name = "name", .kind = .string, .required = true }, .{ .name = "action", .kind = .enumeration, .required = true, .value_constraint = "managed-file" }, .{ .name = "destination", .kind = .string, .required = true }, .{ .name = "content_asset", .kind = .string, .required = true }, .{ .name = "mode", .kind = .positive_integer }, .{ .name = "owner", .kind = .string }, .{ .name = "group", .kind = .string },
};
pub const items = [_]ItemSpec{
    .{ .name = "partition", .identity = "id", .fields = &partition_fields },
    .{ .name = "route", .identity = "id", .fields = &route_fields },
    .{ .name = "user", .identity = "name", .fields = &user_fields, .collections = &user_collections },
    .{ .name = "managed-file-step", .identity = "name", .fields = &managed_file_step_fields },
};

/// 按归属和路径查找标量属性规范。未找到返回 null。
pub fn property(owner: Owner, path: []const u8) ?*const PropertySpec {
    for (&properties) |*spec| if (spec.owner == owner and std.mem.eql(u8, spec.path, path)) return spec;
    return null;
}

/// 按归属和路径查找集合属性规范。未找到返回 null。
pub fn collection(owner: Owner, path: []const u8) ?*const CollectionSpec {
    for (&collections) |*spec| if (spec.owner == owner and std.mem.eql(u8, spec.path, path)) return spec;
    return null;
}

/// 返回帮助中展示的输入约束。显式约束优先；通用标量类型使用统一 token/range。
pub fn valueConstraint(kind: ValueKind, explicit: ?[]const u8) []const u8 {
    if (explicit) |value| return value;
    return switch (kind) {
        .boolean => "true|false",
        .positive_integer => ">0",
        .arch => "x86_64|aarch64",
        .enumeration => "<registry-error>",
        .string => "-",
    };
}

test "typed registries have unique canonical paths and valid item references" {
    for (properties, 0..) |left, index| {
        try std.testing.expect(left.path.len != 0 and left.path[0] != '.');
        for (properties[index + 1 ..]) |right| try std.testing.expect(!(left.owner == right.owner and std.mem.eql(u8, left.path, right.path)));
        try std.testing.expect(collection(left.owner, left.path) == null);
        if (left.kind == .enumeration or left.kind == .arch) try std.testing.expect(left.value_constraint != null);
    }
    for (collections, 0..) |left, index| {
        for (collections[index + 1 ..]) |right| try std.testing.expect(!(left.owner == right.owner and std.mem.eql(u8, left.path, right.path)));
        if (left.item_spec) |name| {
            var found = false;
            for (items) |item| {
                if (std.mem.eql(u8, item.name, name)) found = true;
            }
            try std.testing.expect(found);
        }
    }
    for (items) |item| {
        var identity_found = false;
        for (item.fields, 0..) |field, index| {
            if (std.mem.eql(u8, field.name, item.identity) and field.required) identity_found = true;
            if (field.kind == .enumeration or field.kind == .arch) try std.testing.expect(field.value_constraint != null);
            for (item.fields[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, field.name, other.name));
        }
        for (item.collections, 0..) |field, index| {
            for (item.collections[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, field.name, other.name));
            for (item.fields) |scalar| try std.testing.expect(!std.mem.eql(u8, field.name, scalar.name));
        }
        try std.testing.expect(identity_found);
    }
}

test "canonical v3 storage and discovery keys are registered without legacy aliases" {
    try std.testing.expect(property(.site, "discovery.policy.unknown_action") != null);
    try std.testing.expect(property(.node, "storage.boot_disk") != null);
    try std.testing.expect(collection(.node, "storage.additional_disks") != null);
    try std.testing.expect(property(.node, "ip") == null);
    try std.testing.expect(property(.profile, "boot_disk") == null);
    try std.testing.expect(collection(.node, "install_disks") == null);
}
