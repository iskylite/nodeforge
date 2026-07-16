//! Reproducible M4.3 catalog migration planning.
const std = @import("std");
const model = @import("../model.zig");
const validate = @import("../config/validate.zig");

pub const Rename = struct {
    source: []const u8,
    target: []const u8,
    old_distro: []const u8,
    new_distro: []const u8,
    profiles: []const []const u8,
    directory_from: []const u8,
    directory_to: []const u8,
};
pub const Blocker = struct { source: []const u8, code: []const u8, detail: []const u8 };
const Payload = struct {
    schema_version: u32 = 1,
    config_revision: u64,
    catalog_revision: u64,
    renames: []const Rename,
    blockers: []const Blocker,
};
pub const Plan = struct {
    allocator: std.mem.Allocator,
    canonical_json: []u8,
    digest: [64]u8,
    renames: []Rename,
    blockers: []Blocker,
    pub fn applicable(self: *const Plan) bool {
        return self.blockers.len == 0;
    }
    pub fn deinit(self: *Plan) void {
        for (self.renames) |rename| {
            self.allocator.free(rename.target);
            self.allocator.free(rename.directory_from);
            self.allocator.free(rename.directory_to);
            self.allocator.free(rename.profiles);
        }
        self.allocator.free(self.renames);
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

/// Materialize fully-owned typed candidates. Every relationship is updated
/// explicitly; no global text replacement is used.
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
    const config_arena = result.config.arena.allocator();
    const catalog_arena = result.catalog.arena.allocator();
    const profiles = @constCast(result.config.value.profiles);
    const sources = @constCast(result.catalog.value.install_sources);
    const assets = @constCast(result.catalog.value.assets);
    const repositories = @constCast(result.catalog.value.repositories);
    for (plan.renames) |rename| {
        var source_found = false;
        for (sources) |*source| if (std.mem.eql(u8, source.name, rename.source)) {
            source_found = true;
            source.name = try catalog_arena.dupe(u8, rename.target);
            source.distro = try catalog_arena.dupe(u8, rename.new_distro);
            source.source_asset = try replaceOne(catalog_arena, source.source_asset, rename.source, rename.target);
            source.installer_kernel = try replaceOne(catalog_arena, source.installer_kernel, rename.source, rename.target);
            source.installer_initrd = try replaceOne(catalog_arena, source.installer_initrd, rename.source, rename.target);
            if (source.media_tree_url) |url| source.media_tree_url = try replaceOne(catalog_arena, url, rename.source, rename.target);
            const repo_names = @constCast(source.repositories);
            for (repo_names) |*name| if (std.mem.eql(u8, name.*, rename.source)) {
                name.* = try catalog_arena.dupe(u8, rename.target);
            };
        };
        if (!source_found) return error.MigrationSourceMissing;
        for (assets) |*asset| if (std.mem.startsWith(u8, asset.name, rename.source)) {
            asset.name = try replaceOne(catalog_arena, asset.name, rename.source, rename.target);
            asset.path = try replaceOne(catalog_arena, asset.path, rename.source, rename.target);
            if (asset.distro != null and std.mem.eql(u8, asset.distro.?, rename.old_distro)) asset.distro = try catalog_arena.dupe(u8, rename.new_distro);
        };
        for (repositories) |*repository| if (std.mem.eql(u8, repository.name, rename.source)) {
            repository.name = try catalog_arena.dupe(u8, rename.target);
            repository.distro = try catalog_arena.dupe(u8, rename.new_distro);
            repository.base_url = try replaceOne(catalog_arena, repository.base_url, rename.source, rename.target);
        };
        for (profiles) |*profile| if (profile.install_source) |source_name| {
            if (std.mem.eql(u8, source_name, rename.source)) {
                profile.install_source = try config_arena.dupe(u8, rename.target);
                if (std.mem.eql(u8, profile.distro, rename.old_distro)) profile.distro = try config_arena.dupe(u8, rename.new_distro);
            }
        };
    }
    try validate.validate(&result.config.value, &result.catalog.value);
    return result;
}

fn replaceOne(allocator: std.mem.Allocator, value: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    const index = std.mem.indexOf(u8, value, old) orelse return allocator.dupe(u8, value);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ value[0..index], new, value[index + old.len ..] });
}

pub fn build(allocator: std.mem.Allocator, config: *const model.AppConfig, catalog: *const model.Catalog, config_revision: u64, catalog_revision: u64) !Plan {
    var rename_list = std.ArrayList(Rename).empty;
    defer rename_list.deinit(allocator);
    var blocker_list = std.ArrayList(Blocker).empty;
    defer blocker_list.deinit(allocator);
    for (catalog.install_sources) |source| {
        const detected = detectDistro(source.source_label orelse continue) orelse continue;
        const needs_migration = !std.mem.eql(u8, detected, source.distro) or !validate.validLogicalId(source.name);
        if (!needs_migration) continue;
        const kind = mediaKind(source.source_label.?);
        const target = try canonicalTarget(allocator, detected, source.version, @tagName(source.arch), kind);
        errdefer allocator.free(target);
        if (!validate.validLogicalId(target)) {
            try blocker_list.append(allocator, .{ .source = source.name, .code = "migration.invalid_target", .detail = "source metadata cannot form a canonical logical id" });
            allocator.free(target);
            continue;
        }
        if (findSource(catalog, target) != null) {
            try blocker_list.append(allocator, .{ .source = source.name, .code = "migration.target_exists", .detail = target });
            allocator.free(target);
            continue;
        }
        if (!managedRelationships(catalog, source)) {
            try blocker_list.append(allocator, .{ .source = source.name, .code = "migration.ambiguous_relationship", .detail = "asset, repository, path, or media-tree relationship is not the importer-managed form" });
            allocator.free(target);
            continue;
        }
        var profile_names = std.ArrayList([]const u8).empty;
        defer profile_names.deinit(allocator);
        for (config.profiles) |profile| if (profile.install_source) |name| if (std.mem.eql(u8, name, source.name)) try profile_names.append(allocator, profile.name);
        const from = try std.fmt.allocPrint(allocator, "repos/{s}", .{source.name});
        errdefer allocator.free(from);
        const to = try std.fmt.allocPrint(allocator, "repos/{s}", .{target});
        errdefer allocator.free(to);
        try rename_list.append(allocator, .{ .source = source.name, .target = target, .old_distro = source.distro, .new_distro = detected, .profiles = try profile_names.toOwnedSlice(allocator), .directory_from = from, .directory_to = to });
    }
    const renames = try rename_list.toOwnedSlice(allocator);
    errdefer allocator.free(renames);
    const blockers = try blocker_list.toOwnedSlice(allocator);
    errdefer allocator.free(blockers);
    const payload = Payload{ .config_revision = config_revision, .catalog_revision = catalog_revision, .renames = renames, .blockers = blockers };
    const canonical_json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    errdefer allocator.free(canonical_json);
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical_json, &raw, .{});
    var digest: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&digest, "{x}", .{raw}) catch unreachable;
    return .{ .allocator = allocator, .canonical_json = canonical_json, .digest = digest, .renames = renames, .blockers = blockers };
}

fn detectDistro(label: []const u8) ?[]const u8 {
    if (containsIgnoreCase(label, "centos")) return "centos";
    if (containsIgnoreCase(label, "kylin")) return "kylin";
    if (containsIgnoreCase(label, "ubuntu")) return "ubuntu";
    if (containsIgnoreCase(label, "debian")) return "debian";
    if (containsIgnoreCase(label, "rocky")) return "rocky";
    return null;
}
fn mediaKind(label: []const u8) []const u8 {
    if (containsIgnoreCase(label, "minimal")) return "minimal";
    if (containsIgnoreCase(label, "dvd")) return "dvd";
    return "iso";
}
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    return false;
}
fn canonicalTarget(allocator: std.mem.Allocator, distro: []const u8, version: []const u8, arch: []const u8, kind: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    for ([_][]const u8{ distro, version, arch, kind }, 0..) |part, part_index| {
        if (part_index != 0) try output.append(allocator, '-');
        var separator = false;
        for (part) |byte| {
            const lower = std.ascii.toLower(byte);
            if (std.ascii.isAlphanumeric(lower) or lower == '.' or lower == '_') {
                try output.append(allocator, lower);
                separator = false;
            } else if (!separator) {
                try output.append(allocator, '-');
                separator = true;
            }
        }
        while (output.items.len != 0 and output.items[output.items.len - 1] == '-') _ = output.pop();
    }
    return output.toOwnedSlice(allocator);
}
fn findSource(catalog: *const model.Catalog, name: []const u8) ?*const model.InstallSourceConfig {
    for (catalog.install_sources) |*source| if (std.mem.eql(u8, source.name, name)) return source;
    return null;
}
fn findAsset(catalog: *const model.Catalog, name: []const u8) ?*const model.AssetConfig {
    for (catalog.assets) |*asset| if (std.mem.eql(u8, asset.name, name)) return asset;
    return null;
}
fn managedRelationships(catalog: *const model.Catalog, source: model.InstallSourceConfig) bool {
    const expected_image = std.fmt.count("{s}-image", .{source.name});
    const expected_kernel = std.fmt.count("{s}-installer-kernel", .{source.name});
    const expected_initrd = std.fmt.count("{s}-installer-initrd", .{source.name});
    if (source.source_asset.len != expected_image or source.installer_kernel.len != expected_kernel or source.installer_initrd.len != expected_initrd) return false;
    if (!std.mem.startsWith(u8, source.source_asset, source.name) or !std.mem.endsWith(u8, source.source_asset, "-image")) return false;
    if (!std.mem.startsWith(u8, source.installer_kernel, source.name) or !std.mem.endsWith(u8, source.installer_kernel, "-installer-kernel")) return false;
    if (!std.mem.startsWith(u8, source.installer_initrd, source.name) or !std.mem.endsWith(u8, source.installer_initrd, "-installer-initrd")) return false;
    const image = findAsset(catalog, source.source_asset) orelse return false;
    const kernel = findAsset(catalog, source.installer_kernel) orelse return false;
    const initrd = findAsset(catalog, source.installer_initrd) orelse return false;
    if (image.kind != .iso or kernel.kind != .kernel or initrd.kind != .installer_initrd) return false;
    if (source.media_tree_url) |url| if (std.mem.indexOf(u8, url, source.name) == null) return false;
    for (source.repositories) |repo_name| if (!std.mem.eql(u8, repo_name, source.name)) return false;
    return true;
}

test "legacy wrong distro produces stable migration plan and profile patch" {
    const assets = [_]model.AssetConfig{
        .{ .name = "rocky-old-image", .kind = .iso, .path = "rocky-old.iso" },
        .{ .name = "rocky-old-installer-kernel", .kind = .kernel, .path = "install/rocky-old/vmlinuz" },
        .{ .name = "rocky-old-installer-initrd", .kind = .installer_initrd, .path = "install/rocky-old/initrd.img" },
    };
    const source: model.InstallSourceConfig = .{ .name = "rocky-old", .source_label = "CentOS Linux 8.4 DVD", .distro = "rocky", .version = "8.4", .arch = .x86_64, .source_asset = "rocky-old-image", .installer_kernel = "rocky-old-installer-kernel", .installer_initrd = "rocky-old-installer-initrd", .media_tree_url = "http://192.0.2.1/artifacts/repositories/rocky-old" };
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1" }, .profiles = &.{.{ .name = "legacy", .mode = .install, .distro = "rocky", .version = "8.4", .arch = .x86_64, .install_source = "rocky-old" }} };
    const catalog: model.Catalog = .{ .assets = &assets, .install_sources = &.{source} };
    var first = try build(std.testing.allocator, &config, &catalog, 11, 4);
    defer first.deinit();
    var second = try build(std.testing.allocator, &config, &catalog, 11, 4);
    defer second.deinit();
    try std.testing.expect(first.applicable());
    try std.testing.expectEqualStrings("centos-8.4-x86_64-dvd", first.renames[0].target);
    try std.testing.expectEqualStrings("legacy", first.renames[0].profiles[0]);
    try std.testing.expectEqualSlices(u8, &first.digest, &second.digest);
}

test "external media relationship blocks automatic migration" {
    const source: model.InstallSourceConfig = .{ .name = "rocky-old", .source_label = "Kylin V10 DVD", .distro = "rocky", .version = "v10", .arch = .aarch64, .source_asset = "custom", .installer_kernel = "kernel", .installer_initrd = "initrd" };
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1" } };
    const catalog: model.Catalog = .{ .install_sources = &.{source} };
    var plan = try build(std.testing.allocator, &config, &catalog, 1, 1);
    defer plan.deinit();
    try std.testing.expect(!plan.applicable());
    try std.testing.expectEqualStrings("migration.ambiguous_relationship", plan.blockers[0].code);
}

test "typed candidates update source assets and profile without text-wide replacement" {
    const assets = [_]model.AssetConfig{
        .{ .name = "rocky-old-image", .kind = .iso, .path = "rocky-old.iso", .distro = "rocky", .version = "8.4", .arch = .x86_64, .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .{ .name = "rocky-old-installer-kernel", .kind = .kernel, .path = "install/rocky-old/vmlinuz", .distro = "rocky", .version = "8.4", .arch = .x86_64, .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        .{ .name = "rocky-old-installer-initrd", .kind = .installer_initrd, .path = "install/rocky-old/initrd.img", .distro = "rocky", .version = "8.4", .arch = .x86_64, .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" },
    };
    const source: model.InstallSourceConfig = .{ .name = "rocky-old", .source_label = "CentOS Linux 8.4 DVD", .distro = "rocky", .version = "8.4", .arch = .x86_64, .source_asset = "rocky-old-image", .installer_kernel = "rocky-old-installer-kernel", .installer_initrd = "rocky-old-installer-initrd", .media_tree_url = "http://192.0.2.1/artifacts/repositories/rocky-old" };
    const versions = [_]model.DistroVersionConfig{.{ .version = "8.4", .archs = &.{.x86_64}, .install_adapter = .kickstart, .package_manager = .dnf }};
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1", .bind_interface = "eth0" }, .http = .{ .asset_root = "/tmp/nodeforge/iso", .repository_root = "/tmp/nodeforge/repos" }, .tftp = .{ .asset_root = "/tmp/nodeforge/boot" }, .distros = &.{.{ .name = "centos", .family = .rhel, .versions = &versions }}, .profiles = &.{.{ .name = "legacy", .mode = .install, .distro = "rocky", .version = "8.4", .arch = .x86_64, .install_source = "rocky-old", .safety = .{ .destructive = true, .persistent_writes = true }, .install = .{} }} };
    const catalog: model.Catalog = .{ .assets = &assets, .install_sources = &.{source} };
    var plan = try build(std.testing.allocator, &config, &catalog, 3, 4);
    defer plan.deinit();
    var next = try candidates(std.testing.allocator, &config, &catalog, &plan);
    defer next.deinit();
    try std.testing.expectEqualStrings("centos-8.4-x86_64-dvd", next.catalog.value.install_sources[0].name);
    try std.testing.expectEqualStrings("install/centos-8.4-x86_64-dvd/vmlinuz", next.catalog.value.assets[1].path);
    try std.testing.expectEqualStrings("centos", next.config.value.profiles[0].distro);
}
