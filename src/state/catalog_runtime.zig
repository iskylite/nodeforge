//! Ref-counted immutable catalog generations owned by the daemon.

const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const validate = @import("../config/validate.zig");
const iso_import = @import("../catalog/iso_import.zig");
const config_runtime = @import("config_runtime.zig");

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(model.Catalog),
    revision: u64,
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    pub fn value(self: *const Snapshot) *const model.Catalog {
        return &self.parsed.value;
    }
    pub fn release(self: *const Snapshot) void {
        const mutable: *Snapshot = @constCast(self);
        if (mutable.refs.fetchSub(1, .acq_rel) != 1) return;
        mutable.parsed.deinit();
        const allocator = mutable.allocator;
        allocator.destroy(mutable);
    }
};

pub const CatalogRuntime = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    current: std.atomic.Value(*Snapshot),
    writer: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, initial: *const model.Catalog) !CatalogRuntime {
        const snapshot = try createSnapshot(allocator, initial.*, if (initial.revision == 0) 1 else initial.revision);
        return .{ .allocator = allocator, .path = path, .current = std.atomic.Value(*Snapshot).init(snapshot) };
    }
    pub fn deinit(self: *CatalogRuntime) void {
        self.current.load(.acquire).release();
    }
    pub fn lock(self: *CatalogRuntime) void {
        lockMutex(&self.writer);
    }
    pub fn unlock(self: *CatalogRuntime) void {
        self.writer.unlock();
    }
    pub fn acquire(self: *CatalogRuntime) *const Snapshot {
        self.lock();
        defer self.unlock();
        return self.acquireLocked();
    }
    pub fn acquireLocked(self: *CatalogRuntime) *const Snapshot {
        const snapshot = self.current.load(.acquire);
        _ = snapshot.refs.fetchAdd(1, .monotonic);
        return snapshot;
    }
    pub fn currentRevision(self: *CatalogRuntime) u64 {
        const snapshot = self.acquire();
        defer snapshot.release();
        return snapshot.revision;
    }

    /// Caller holds ModelRuntime.mutation_gate so config/catalog readers see a
    /// coherent pair while this catalog-only observation generation publishes.
    pub fn recordUnknownClient(self: *CatalogRuntime, io: std.Io, mac: []const u8, client_id: ?[]const u8, arch: ?model.Arch, vendor_class: ?[]const u8, ip: ?[]const u8, seen_at: i64) !void {
        self.lock();
        defer self.unlock();
        const old = self.acquireLocked();
        defer old.release();
        const source = old.value().unknown_client_observations;
        const retention_seconds = @as(i64, old.value().discovery_policy.observation_retention_days) * 86400;
        var retained: usize = 0;
        var found = false;
        for (source) |item| {
            const expired = item.claim == null and seen_at > item.last_seen_unix and seen_at - item.last_seen_unix > retention_seconds;
            if (expired) continue;
            retained += 1;
            if (std.ascii.eqlIgnoreCase(item.mac, mac)) found = true;
        }
        const observations = try self.allocator.alloc(model.UnknownClientObservation, retained + @as(usize, if (found) 0 else 1));
        defer self.allocator.free(observations);
        var index: usize = 0;
        for (source) |item| {
            const expired = item.claim == null and seen_at > item.last_seen_unix and seen_at - item.last_seen_unix > retention_seconds;
            if (expired) continue;
            observations[index] = item;
            if (std.ascii.eqlIgnoreCase(item.mac, mac)) {
                observations[index].last_seen_unix = seen_at;
                observations[index].last_ip = ip;
                observations[index].request_count +|= 1;
                observations[index].revision += 1;
                if (client_id != null) observations[index].dhcp_client_id = client_id;
                if (arch != null) observations[index].observed_architecture = arch;
                if (vendor_class != null) observations[index].vendor_class = vendor_class;
            }
            index += 1;
        }
        if (!found) observations[index] = .{
            .mac = mac,
            .dhcp_client_id = client_id,
            .observed_architecture = arch,
            .vendor_class = vendor_class,
            .first_seen_unix = seen_at,
            .last_seen_unix = seen_at,
            .last_ip = ip,
        };
        var candidate = old.value().*;
        candidate.revision = old.revision + 1;
        candidate.unknown_client_observations = observations;
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        try self.publishLocked(candidate, old.revision + 1);
    }
    pub fn containsAssetPath(self: *CatalogRuntime, path: []const u8) bool {
        const snapshot = self.acquire();
        defer snapshot.release();
        for (snapshot.value().assets) |asset| if (std.mem.eql(u8, asset.path, path)) return true;
        return false;
    }

    pub fn addAsset(self: *CatalogRuntime, io: std.Io, config: *const model.AppConfig, asset: model.AssetConfig) !void {
        self.lock();
        defer self.unlock();
        const old = self.acquireLocked();
        defer old.release();
        for (old.value().assets) |existing| if (std.mem.eql(u8, existing.name, asset.name)) return error.DuplicateObjectName;
        const next_assets = try self.allocator.alloc(model.AssetConfig, old.value().assets.len + 1);
        defer self.allocator.free(next_assets);
        @memcpy(next_assets[0..old.value().assets.len], old.value().assets);
        next_assets[old.value().assets.len] = asset;
        var candidate = old.value().*;
        candidate.revision = old.revision + 1;
        candidate.assets = next_assets;
        try validate.validate(config, &candidate);
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        try self.publishLocked(candidate, old.revision + 1);
    }

    pub fn publishManagedFile(self: *CatalogRuntime, io: std.Io, config: *const model.AppConfig, asset: model.AssetConfig) !void {
        self.lock();
        defer self.unlock();
        const old = self.acquireLocked();
        defer old.release();
        var found: ?usize = null;
        for (old.value().assets, 0..) |existing, index| if (std.mem.eql(u8, existing.name, asset.name)) {
            if (existing.kind != .managed_file or asset.revision != existing.revision + 1) return error.AssetRevisionConflict;
            found = index;
        };
        if (found == null and asset.revision != 1) return error.AssetRevisionConflict;
        const next_len = old.value().assets.len + @as(usize, if (found == null) 1 else 0);
        const next_assets = try self.allocator.alloc(model.AssetConfig, next_len);
        defer self.allocator.free(next_assets);
        @memcpy(next_assets[0..old.value().assets.len], old.value().assets);
        if (found) |index| next_assets[index] = asset else next_assets[old.value().assets.len] = asset;
        var candidate = old.value().*;
        candidate.revision = old.revision + 1;
        candidate.assets = next_assets;
        try validate.validate(config, &candidate);
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        try self.publishLocked(candidate, old.revision + 1);
    }

    pub fn removeManagedFile(self: *CatalogRuntime, io: std.Io, config: *const model.AppConfig, name: []const u8) !void {
        self.lock();
        defer self.unlock();
        const old = self.acquireLocked();
        defer old.release();
        var found: ?usize = null;
        for (old.value().assets, 0..) |asset, index| if (std.mem.eql(u8, asset.name, name)) {
            if (asset.kind != .managed_file) return error.AssetKindMismatch;
            found = index;
        };
        const index = found orelse return error.AssetNotFound;
        for (old.value().provisioning_bundles) |bundle| for (bundle.steps) |step| if (step.content_asset != null and std.mem.eql(u8, step.content_asset.?, name)) return error.AssetInUse;
        const next_assets = try self.allocator.alloc(model.AssetConfig, old.value().assets.len - 1);
        defer self.allocator.free(next_assets);
        @memcpy(next_assets[0..index], old.value().assets[0..index]);
        @memcpy(next_assets[index..], old.value().assets[index + 1 ..]);
        var candidate = old.value().*;
        candidate.revision = old.revision + 1;
        candidate.assets = next_assets;
        try validate.validate(config, &candidate);
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        try self.publishLocked(candidate, old.revision + 1);
    }

    pub fn publishInstallSource(
        self: *CatalogRuntime,
        io: std.Io,
        configs: *config_runtime.ConfigRuntime,
        config: *const model.AppConfig,
        config_revision: u64,
        imported: iso_import.Result,
    ) !void {
        self.lock();
        defer self.unlock();
        const old = self.acquireLocked();
        defer old.release();
        const value = old.value();
        // distro 是 ISO 导入的派生索引，不是导入前置配置。首次导入创建产品/
        // 版本/架构 tuple；后续导入只扩展缺少的版本或架构。family 冲突 fail closed。
        var distro_expansion = try expandDistroTuple(self.allocator, value, imported);
        defer distro_expansion.deinit(self.allocator);
        const required_additions = [_]model.AssetConfig{ imported.iso_asset, imported.kernel_asset, imported.initrd_asset };
        for (required_additions) |asset| for (value.assets) |existing| if (std.mem.eql(u8, existing.name, asset.name)) return error.DuplicateObjectName;
        var bootloader_addition: ?model.AssetConfig = imported.bootloader_asset;
        if (bootloader_addition) |bootloader| {
            for (value.assets) |existing| {
                if (!std.mem.eql(u8, existing.path, bootloader.path)) continue;
                if (existing.kind != .bootloader) return error.AssetPathConflict;
                bootloader_addition = null;
                break;
            }
            if (bootloader_addition != null)
                for (value.assets) |existing|
                    if (std.mem.eql(u8, existing.name, bootloader.name)) return error.DuplicateObjectName;
        }
        if (imported.repository) |repository| for (value.repositories) |existing| if (std.mem.eql(u8, existing.name, repository.name)) return error.DuplicateObjectName;
        for (value.install_sources) |existing| if (std.mem.eql(u8, existing.name, imported.install_source.name)) return error.DuplicateObjectName;
        for (value.profiles) |existing| if (std.mem.eql(u8, existing.name, imported.install_source.name)) return error.DuplicateObjectName;
        const addition_count = required_additions.len + @as(usize, if (bootloader_addition != null) 1 else 0);
        const assets = try self.allocator.alloc(model.AssetConfig, value.assets.len + addition_count);
        defer self.allocator.free(assets);
        @memcpy(assets[0..value.assets.len], value.assets);
        @memcpy(assets[value.assets.len .. value.assets.len + required_additions.len], &required_additions);
        if (bootloader_addition) |bootloader|
            assets[value.assets.len + required_additions.len] = bootloader;
        const repo_count: usize = if (imported.repository == null) 0 else 1;
        const repositories = try self.allocator.alloc(model.RepositoryConfig, value.repositories.len + repo_count);
        defer self.allocator.free(repositories);
        @memcpy(repositories[0..value.repositories.len], value.repositories);
        if (imported.repository) |repository| repositories[value.repositories.len] = repository;
        const sources = try self.allocator.alloc(model.InstallSourceConfig, value.install_sources.len + 1);
        defer self.allocator.free(sources);
        @memcpy(sources[0..value.install_sources.len], value.install_sources);
        sources[value.install_sources.len] = imported.install_source;
        // M4.10 fresh-deployment 主路径：ISO publication 已拥有完整 tuple，
        // 因而在同一 manifest-last transaction 中创建同名默认 install
        // profile。显式 `profile create` 只用于从该 source 补充其他 profile。
        const profiles = try self.allocator.alloc(model.ProfileConfig, value.profiles.len + 1);
        defer self.allocator.free(profiles);
        @memcpy(profiles[0..value.profiles.len], value.profiles);
        profiles[value.profiles.len] = .{
            .name = imported.install_source.name,
            .install_source = imported.install_source.name,
        };
        var candidate = value.*;
        candidate.revision = old.revision + 1;
        candidate.distros = distro_expansion.values;
        candidate.assets = assets;
        candidate.repositories = repositories;
        candidate.install_sources = sources;
        candidate.profiles = profiles;
        try validate.validateModel(config, &candidate);
        // 在持久提交前准备 catalog 与兼容 AppConfig 投影，保证 model gate
        // 释放后读者只会看到完整的新 pair，不会出现 catalog 已有 distro、
        // config 投影仍停留在旧 generation 的窗口。
        const effective = model.projectCatalog(config.*, &candidate);
        const config_next = try configs.prepare(effective, config_revision);
        errdefer config_next.release();
        const catalog_next = try self.prepare(candidate, old.revision + 1);
        errdefer catalog_next.release();
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        configs.publishPrepared(config_next);
        self.publishPreparedLocked(catalog_next);
    }

    pub fn publishLocked(self: *CatalogRuntime, candidate: model.Catalog, revision: u64) !void {
        const next = try self.prepare(candidate, revision);
        self.publishPreparedLocked(next);
    }
    pub fn prepare(self: *CatalogRuntime, candidate: model.Catalog, revision: u64) !*Snapshot {
        return createSnapshot(self.allocator, candidate, revision);
    }
    pub fn publishPreparedLocked(self: *CatalogRuntime, next: *Snapshot) void {
        const previous = self.current.swap(next, .acq_rel);
        previous.release();
    }
};

const DistroExpansion = struct {
    values: []const model.DistroConfig,
    distros: ?[]model.DistroConfig = null,
    versions: ?[]model.DistroVersionConfig = null,
    archs: ?[]model.Arch = null,

    fn deinit(self: *DistroExpansion, allocator: std.mem.Allocator) void {
        if (self.archs) |items| allocator.free(items);
        if (self.versions) |items| allocator.free(items);
        if (self.distros) |items| allocator.free(items);
    }
};

/// 把 ISO 已验证出的 tuple 合并进 catalog distro 索引。
///
/// adapter/package manager 由 family 唯一派生；操作员既无需也不能在 ISO
/// 导入命令中选择它们。此函数只准备候选切片，真正持久化仍由 manifest-last
/// catalog 事务与 install source/assets/repository 一起完成。
fn expandDistroTuple(allocator: std.mem.Allocator, catalog: *const model.Catalog, imported: iso_import.Result) !DistroExpansion {
    const distro_name = imported.install_source.distro;
    const version_name = imported.install_source.version;
    const arch = imported.install_source.arch;

    for (catalog.distros, 0..) |distro, distro_index| {
        if (!std.mem.eql(u8, distro.name, distro_name)) continue;
        if (distro.family != imported.family) return error.DistroFamilyMismatch;
        for (distro.versions, 0..) |version, version_index| {
            if (!std.mem.eql(u8, version.version, version_name)) continue;
            for (version.archs) |existing_arch| if (existing_arch == arch)
                return .{ .values = catalog.distros };

            const archs = try allocator.alloc(model.Arch, version.archs.len + 1);
            errdefer allocator.free(archs);
            @memcpy(archs[0..version.archs.len], version.archs);
            archs[version.archs.len] = arch;
            const versions = try allocator.alloc(model.DistroVersionConfig, distro.versions.len);
            errdefer allocator.free(versions);
            @memcpy(versions, distro.versions);
            versions[version_index].archs = archs;
            const distros = try allocator.alloc(model.DistroConfig, catalog.distros.len);
            errdefer allocator.free(distros);
            @memcpy(distros, catalog.distros);
            distros[distro_index].versions = versions;
            return .{ .values = distros, .distros = distros, .versions = versions, .archs = archs };
        }

        const archs = try allocator.alloc(model.Arch, 1);
        errdefer allocator.free(archs);
        archs[0] = arch;
        const versions = try allocator.alloc(model.DistroVersionConfig, distro.versions.len + 1);
        errdefer allocator.free(versions);
        @memcpy(versions[0..distro.versions.len], distro.versions);
        versions[distro.versions.len] = .{
            .version = version_name,
            .archs = archs,
            .install_adapter = model.installAdapterForFamily(imported.family),
            .package_manager = model.packageManagerForFamily(imported.family),
        };
        const distros = try allocator.alloc(model.DistroConfig, catalog.distros.len);
        errdefer allocator.free(distros);
        @memcpy(distros, catalog.distros);
        distros[distro_index].versions = versions;
        return .{ .values = distros, .distros = distros, .versions = versions, .archs = archs };
    }

    const archs = try allocator.alloc(model.Arch, 1);
    errdefer allocator.free(archs);
    archs[0] = arch;
    const versions = try allocator.alloc(model.DistroVersionConfig, 1);
    errdefer allocator.free(versions);
    versions[0] = .{
        .version = version_name,
        .archs = archs,
        .install_adapter = model.installAdapterForFamily(imported.family),
        .package_manager = model.packageManagerForFamily(imported.family),
    };
    const distros = try allocator.alloc(model.DistroConfig, catalog.distros.len + 1);
    errdefer allocator.free(distros);
    @memcpy(distros[0..catalog.distros.len], catalog.distros);
    distros[catalog.distros.len] = .{ .name = distro_name, .family = imported.family, .versions = versions };
    return .{ .values = distros, .distros = distros, .versions = versions, .archs = archs };
}

fn createSnapshot(allocator: std.mem.Allocator, value: model.Catalog, revision: u64) !*Snapshot {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(model.Catalog, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const snapshot = try allocator.create(Snapshot);
    snapshot.* = .{ .allocator = allocator, .parsed = parsed, .revision = revision };
    return snapshot;
}
fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

test "old catalog generation survives replacement until reader release" {
    var runtime = try CatalogRuntime.init(std.testing.allocator, "/tmp/catalog.json", &.{});
    defer runtime.deinit();
    const old = runtime.acquire();
    runtime.lock();
    try runtime.publishLocked(.{ .assets = &.{.{ .name = "new", .kind = .iso, .path = "new.iso" }} }, 2);
    runtime.unlock();
    try std.testing.expectEqual(@as(usize, 0), old.value().assets.len);
    old.release();
    const current = runtime.acquire();
    defer current.release();
    try std.testing.expectEqual(@as(u64, 2), current.revision);
    try std.testing.expectEqualStrings("new", current.value().assets[0].name);
}

test "persistent observations update revisions and retain claimed audit past retention" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try temp.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];
    try catalog_store.initializeEmpty(std.testing.io, std.testing.allocator, path);
    const initial: model.Catalog = .{
        .discovery_policy = .{ .observation_retention_days = 1 },
        .unknown_client_observations = &.{
            .{ .mac = "02:00:00:00:00:01", .first_seen_unix = 1, .last_seen_unix = 1 },
            .{ .mac = "02:00:00:00:00:02", .first_seen_unix = 1, .last_seen_unix = 1, .claim = .{ .node_id = "audit-node", .claimed_at_unix = 2 } },
        },
    };
    var runtime = try CatalogRuntime.init(std.testing.allocator, path, &initial);
    defer runtime.deinit();
    try runtime.recordUnknownClient(std.testing.io, "02:00:00:00:00:03", "0102", .x86_64, "PXEClient", "192.0.2.10", 200000);
    try runtime.recordUnknownClient(std.testing.io, "02:00:00:00:00:03", null, .x86_64, null, "192.0.2.11", 200001);
    const snapshot = runtime.acquire();
    defer snapshot.release();
    try std.testing.expectEqual(@as(usize, 2), snapshot.value().unknown_client_observations.len);
    try std.testing.expect(snapshot.value().unknown_client_observations[0].claim != null);
    try std.testing.expectEqual(@as(u64, 2), snapshot.value().unknown_client_observations[1].request_count);
    try std.testing.expectEqual(@as(u64, 2), snapshot.value().unknown_client_observations[1].revision);
    try std.testing.expectEqualStrings("192.0.2.11", snapshot.value().unknown_client_observations[1].last_ip.?);
}

fn importedFixture(distro: []const u8, version: []const u8, arch: model.Arch, family: model.DistroFamily) iso_import.Result {
    return .{
        .source_name = "fixture-source",
        .family = family,
        .iso_asset = .{ .name = "fixture-image", .kind = .iso, .path = "fixture.iso", .distro = distro, .version = version, .arch = arch },
        .kernel_asset = .{ .name = "fixture-kernel", .kind = .kernel, .path = "install/fixture/vmlinuz", .distro = distro, .version = version, .arch = arch },
        .initrd_asset = .{ .name = "fixture-initrd", .kind = .installer_initrd, .path = "install/fixture/initrd.img", .distro = distro, .version = version, .arch = arch },
        .repository = null,
        .install_source = .{ .name = "fixture-source", .distro = distro, .version = version, .arch = arch, .source_asset = "fixture-image", .installer_kernel = "fixture-kernel", .installer_initrd = "fixture-initrd" },
    };
}

test "first ISO import derives distro capability without a pre-created distro" {
    const imported = importedFixture("rocky", "9.7", .aarch64, .rhel);
    var expanded = try expandDistroTuple(std.testing.allocator, &.{}, imported);
    defer expanded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), expanded.values.len);
    try std.testing.expectEqualStrings("rocky", expanded.values[0].name);
    try std.testing.expectEqual(model.DistroFamily.rhel, expanded.values[0].family);
    try std.testing.expectEqualStrings("9.7", expanded.values[0].versions[0].version);
    try std.testing.expectEqual(model.InstallAdapter.kickstart, expanded.values[0].versions[0].install_adapter);
    try std.testing.expectEqual(model.PackageManager.dnf, expanded.values[0].versions[0].package_manager);
}

test "later ISO imports extend an existing distro version and architecture" {
    const base_versions = [_]model.DistroVersionConfig{.{
        .version = "9.7",
        .archs = &.{.aarch64},
        .install_adapter = .kickstart,
        .package_manager = .dnf,
    }};
    const base: model.Catalog = .{ .distros = &.{.{ .name = "rocky", .family = .rhel, .versions = &base_versions }} };
    var arch_expanded = try expandDistroTuple(std.testing.allocator, &base, importedFixture("rocky", "9.7", .x86_64, .rhel));
    defer arch_expanded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), arch_expanded.values[0].versions[0].archs.len);

    const with_arch: model.Catalog = .{ .distros = arch_expanded.values };
    var version_expanded = try expandDistroTuple(std.testing.allocator, &with_arch, importedFixture("rocky", "10.0", .x86_64, .rhel));
    defer version_expanded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), version_expanded.values[0].versions.len);
    try std.testing.expectEqualStrings("10.0", version_expanded.values[0].versions[1].version);
}

test "same distro id cannot change family through an ISO override" {
    const versions = [_]model.DistroVersionConfig{.{
        .version = "22.04",
        .archs = &.{.aarch64},
        .install_adapter = .autoinstall,
        .package_manager = .apt,
    }};
    const catalog: model.Catalog = .{ .distros = &.{.{ .name = "custom", .family = .ubuntu, .versions = &versions }} };
    try std.testing.expectError(error.DistroFamilyMismatch, expandDistroTuple(std.testing.allocator, &catalog, importedFixture("custom", "9.7", .aarch64, .rhel)));
}

test "first install source publication persists and projects its derived distro" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    try catalog_store.initializeEmpty(std.testing.io, std.testing.allocator, root);

    const config: model.AppConfig = .{
        .server = .{ .bind_interface = "eth0", .server_ip = "192.168.50.1" },
        .http = .{ .asset_root = "/tmp/nodeforge-assets", .repository_root = "/tmp/nodeforge-repositories" },
        .tftp = .{ .asset_root = "/tmp/nodeforge-tftp" },
    };
    var configs = try config_runtime.ConfigRuntime.init(std.testing.allocator, &config, 1);
    defer configs.deinit();
    var catalog = try CatalogRuntime.init(std.testing.allocator, root, &.{});
    defer catalog.deinit();

    var imported = importedFixture("rocky", "9.7", .aarch64, .rhel);
    imported.bootloader_asset = .{
        .name = "grub-uefi-aarch64",
        .kind = .bootloader,
        .path = "efi/grubaa64.efi",
    };
    try catalog.publishInstallSource(
        std.testing.io,
        &configs,
        &config,
        1,
        imported,
    );

    const live_catalog = catalog.acquire();
    defer live_catalog.release();
    try std.testing.expectEqual(@as(usize, 1), live_catalog.value().distros.len);
    try std.testing.expectEqual(@as(usize, 1), live_catalog.value().install_sources.len);
    try std.testing.expectEqual(@as(usize, 1), live_catalog.value().profiles.len);
    try std.testing.expectEqualStrings("fixture-source", live_catalog.value().profiles[0].name);
    try std.testing.expectEqualStrings("fixture-source", live_catalog.value().profiles[0].install_source);
    try std.testing.expectEqual(@as(usize, 4), live_catalog.value().assets.len);
    try std.testing.expectEqualStrings("efi/grubaa64.efi", live_catalog.value().assets[3].path);
    try std.testing.expectEqualStrings("rocky", live_catalog.value().distros[0].name);

    const projected_config = configs.acquire();
    defer projected_config.release();
    try std.testing.expectEqual(@as(usize, 1), projected_config.value().distros.len);
    try std.testing.expectEqualStrings("rocky", projected_config.value().distros[0].name);

    var persisted = try catalog_store.load(std.testing.io, std.testing.allocator, root);
    defer persisted.deinit();
    try std.testing.expectEqual(@as(usize, 1), persisted.value.distros.len);
    try std.testing.expectEqualStrings("fixture-source", persisted.value.install_sources[0].name);
}
