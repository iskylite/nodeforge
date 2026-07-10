//! 在服务绑定端口或修改状态前校验 config/catalog 不变量。
//! 本模块保持纯函数，不访问文件系统，也不产生副作用。
//! 校验顺序固定为 config → catalog → profiles → nodes → policy；
//! 前置检查失败时不会继续后续检查，避免在错误状态下产生误导性报告。

const std = @import("std");
const model = @import("../model.zig");
const lookup = @import("../catalog.zig");

/// 配置校验错误码。
/// 所有错误均为编译期已知集合，不包含动态字符串——
/// 具体对象名和字段通过 `@errorName` 在 `observe/error.zig` 中渲染为 message。
pub const ValidationError = error{
    UnsupportedSchemaVersion,
    EmptyServerName,
    EmptyBindInterface,
    InvalidServerIpv4,
    InvalidHttpPort,
    EmptyAssetRoot,
    EmptyObjectName,
    DuplicateObjectName,
    UnsupportedDistroTuple,
    DistroAdapterMismatch,
    RepositoryManagerMismatch,
    MissingGpgKey,
    MissingAsset,
    AssetKindMismatch,
    MissingRepository,
    MissingInstallSource,
    MissingBootBundle,
    InvalidProfileSource,
    InvalidProfileSafety,
    MissingProfile,
    InvalidNodeIpv4,
    InvalidNodeMac,
    DuplicateNodeId,
    DuplicateNodeMac,
    InvalidUnknownNodePolicy,
    KernelReleaseMismatch,
};

/// 完整校验启动配置和 catalog 的引用关系。
///
/// 执行顺序固定为 config → catalog → profiles → nodes → policy，
/// 前置校验失败时不会继续后续检查。本函数不访问文件系统、不产生副作用，
/// 适合在服务绑定端口、CLI 导入和运行期配置变更前调用。
pub fn validate(config: *const model.AppConfig, catalog: *const model.Catalog) ValidationError!void {
    try validateConfig(config);
    try validateCatalog(config, catalog);
    try validateProfiles(config, catalog);
    try validateNodes(config);
    try validatePolicy(config);
}

/// 只校验启动配置自身的格式和内部一致性。
///
/// 不检查 catalog 引用关系，适用于 CLI 在 catalog 尚未加载时
/// 对 config 做快速预检。
pub fn validateConfig(config: *const model.AppConfig) ValidationError!void {
    if (config.schema_version != 1) return error.UnsupportedSchemaVersion;
    if (config.server.name.len == 0) return error.EmptyServerName;
    if (config.server.bind_interface) |iface|
        if (iface.len == 0) return error.EmptyBindInterface;
    _ = std.Io.net.IpAddress.parseIp4(config.server.server_ip, 0) catch
        return error.InvalidServerIpv4;
    if (config.server.http_port == 0) return error.InvalidHttpPort;
    if (config.http.asset_root.len == 0 or config.http.repository_root.len == 0)
        return error.EmptyAssetRoot;
    try uniqueNamed(model.DistroConfig, config.distros);
    try uniqueNamed(model.ProfileConfig, config.profiles);
    try validateDistros(config);
}

/// 校验 catalog 的格式、对象唯一性和对 config 的引用关系。
///
/// 需要 config 已经通过 `validateConfig`；catalog 中的 distro/version/arch
/// 必须能在 config 的支持矩阵中找到，asset kind 必须与引用方期望一致。
pub fn validateCatalog(config: *const model.AppConfig, catalog: *const model.Catalog) ValidationError!void {
    if (catalog.schema_version != 1) return error.UnsupportedSchemaVersion;
    try uniqueNamed(model.RepositoryConfig, catalog.repositories);
    try uniqueNamed(model.AssetConfig, catalog.assets);
    try uniqueNamed(model.InstallSourceConfig, catalog.install_sources);
    try uniqueNamed(model.BootBundleConfig, catalog.boot_bundles);
    try validateAssets(config, catalog);
    try validateRepositories(config, catalog);
    try validateInstallSources(config, catalog);
    try validateBootBundles(config, catalog);
}

fn uniqueNamed(comptime T: type, items: []const T) ValidationError!void {
    for (items, 0..) |item, i| {
        if (item.name.len == 0) return error.EmptyObjectName;
        for (items[i + 1 ..]) |other|
            if (std.mem.eql(u8, item.name, other.name)) return error.DuplicateObjectName;
    }
}

fn validateDistros(config: *const model.AppConfig) ValidationError!void {
    for (config.distros) |distro| {
        for (distro.versions) |version| {
            if (version.version.len == 0 or version.archs.len == 0)
                return error.UnsupportedDistroTuple;
            const expected = switch (distro.family) {
                .rhel => .{ model.InstallAdapter.kickstart, model.PackageManager.dnf },
                .ubuntu => .{ model.InstallAdapter.autoinstall, model.PackageManager.apt },
            };
            if (version.install_adapter != expected[0] or version.package_manager != expected[1])
                return error.DistroAdapterMismatch;
        }
    }
}

fn validateAssets(config: *const model.AppConfig, catalog: *const model.Catalog) ValidationError!void {
    for (catalog.assets) |asset| {
        if (asset.path.len == 0) return error.MissingAsset;
        if (asset.distro) |distro| {
            const version = asset.version orelse return error.UnsupportedDistroTuple;
            const arch = asset.arch orelse return error.UnsupportedDistroTuple;
            if (lookup.findDistroVersion(config, distro, version, arch) == null)
                return error.UnsupportedDistroTuple;
        } else if (asset.version != null or asset.arch != null) {
            return error.UnsupportedDistroTuple;
        }
    }
}

fn validateRepositories(config: *const model.AppConfig, catalog: *const model.Catalog) ValidationError!void {
    for (catalog.repositories) |repository| {
        const version = lookup.findDistroVersion(
            config,
            repository.distro,
            repository.version,
            repository.arch,
        ) orelse return error.UnsupportedDistroTuple;
        if (repository.manager != version.package_manager)
            return error.RepositoryManagerMismatch;
        if (repository.base_url.len == 0) return error.MissingRepository;
        if (repository.gpg_check) {
            const key_name = repository.gpg_key orelse return error.MissingGpgKey;
            const key = lookup.findAsset(catalog, key_name) orelse return error.MissingGpgKey;
            if (key.kind != .gpg_key) return error.AssetKindMismatch;
        }
    }
}

fn validateInstallSources(config: *const model.AppConfig, catalog: *const model.Catalog) ValidationError!void {
    for (catalog.install_sources) |source| {
        _ = lookup.findDistroVersion(config, source.distro, source.version, source.arch) orelse
            return error.UnsupportedDistroTuple;
        const iso = try requireAssetKind(catalog, source.source_asset, .iso);
        const kernel = try requireAssetKind(catalog, source.installer_kernel, .kernel);
        const initrd = try requireAssetKind(catalog, source.installer_initrd, .installer_initrd);
        for ([_]*const model.AssetConfig{ iso, kernel, initrd }) |asset| {
            if (!optionalEqual(asset.distro, source.distro) or
                !optionalEqual(asset.version, source.version) or
                asset.arch == null or asset.arch.? != source.arch)
                return error.UnsupportedDistroTuple;
        }
        for (source.repositories) |name|
            _ = lookup.findRepository(catalog, name) orelse return error.MissingRepository;
    }
}

fn validateBootBundles(config: *const model.AppConfig, catalog: *const model.Catalog) ValidationError!void {
    for (catalog.boot_bundles) |bundle| {
        _ = lookup.findDistroVersion(config, bundle.distro, bundle.version, bundle.arch) orelse
            return error.UnsupportedDistroTuple;
        const kernel = try requireAssetKind(catalog, bundle.kernel, .kernel);
        const initrd = try requireAssetKind(catalog, bundle.initrd, .nodeforge_initrd);
        const rootfs = try requireAssetKind(catalog, bundle.rootfs, .rootfs);

        for ([_]*const model.AssetConfig{ kernel, initrd, rootfs }) |asset| {
            if (!optionalEqual(asset.distro, bundle.distro) or
                !optionalEqual(asset.version, bundle.version) or
                asset.arch == null or asset.arch.? != bundle.arch or
                !optionalEqual(asset.kernel_release, bundle.kernel_release))
                return error.KernelReleaseMismatch;
        }
    }
}

fn validateProfiles(config: *const model.AppConfig, catalog: *const model.Catalog) ValidationError!void {
    for (config.profiles) |profile| {
        _ = lookup.findDistroVersion(config, profile.distro, profile.version, profile.arch) orelse
            return error.UnsupportedDistroTuple;
        switch (profile.mode) {
            .discovery => {
                if (profile.install_source != null or profile.boot_bundle != null)
                    return error.InvalidProfileSource;
                if (profile.safety.destructive or profile.safety.persistent_writes)
                    return error.InvalidProfileSafety;
            },
            .install => {
                const name = profile.install_source orelse return error.MissingInstallSource;
                if (profile.boot_bundle != null or lookup.findInstallSource(catalog, name) == null)
                    return error.InvalidProfileSource;
                if (!profile.safety.destructive) return error.InvalidProfileSafety;
            },
            .diskless => {
                const name = profile.boot_bundle orelse return error.MissingBootBundle;
                if (profile.install_source != null or lookup.findBootBundle(catalog, name) == null)
                    return error.InvalidProfileSource;
                if (profile.safety.destructive) return error.InvalidProfileSafety;
            },
        }
    }
}

fn validateNodes(config: *const model.AppConfig) ValidationError!void {
    for (config.nodes, 0..) |node, i| {
        if (node.id.len == 0) return error.EmptyObjectName;
        if (!validMac(node.mac)) return error.InvalidNodeMac;
        const profile = lookup.findProfile(config, node.profile) orelse return error.MissingProfile;
        if (profile.arch != node.arch) return error.InvalidProfileSource;
        if (node.ip) |ip| _ = std.Io.net.IpAddress.parseIp4(ip, 0) catch
            return error.InvalidNodeIpv4;
        for (config.nodes[i + 1 ..]) |other| {
            if (std.mem.eql(u8, node.id, other.id)) return error.DuplicateNodeId;
            if (std.ascii.eqlIgnoreCase(node.mac, other.mac)) return error.DuplicateNodeMac;
        }
    }
}

fn validatePolicy(config: *const model.AppConfig) ValidationError!void {
    const profile_name = config.policy.default_profile;
    switch (config.policy.default_action) {
        .wait, .deny => if (profile_name != null) return error.InvalidUnknownNodePolicy,
        .discovery => {
            const profile = lookup.findProfile(config, profile_name orelse
                return error.InvalidUnknownNodePolicy) orelse return error.MissingProfile;
            if (profile.mode != .discovery) return error.InvalidUnknownNodePolicy;
        },
        .diskless => {
            if (!config.policy.allow_unknown_diskless)
                return error.InvalidUnknownNodePolicy;
            const profile = lookup.findProfile(config, profile_name orelse
                return error.InvalidUnknownNodePolicy) orelse return error.MissingProfile;
            if (profile.mode != .diskless or !profile.safety.safe_for_unknown or
                profile.safety.destructive or profile.safety.persistent_writes)
                return error.InvalidUnknownNodePolicy;
        },
    }
}

fn requireAssetKind(
    catalog: *const model.Catalog,
    name: []const u8,
    kind: model.AssetKind,
) ValidationError!*const model.AssetConfig {
    const asset = lookup.findAsset(catalog, name) orelse return error.MissingAsset;
    if (asset.kind != kind) return error.AssetKindMismatch;
    return asset;
}

fn optionalEqual(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |actual| std.mem.eql(u8, actual, expected) else false;
}

fn validMac(value: []const u8) bool {
    if (value.len != 17) return false;
    for (value, 0..) |char, i| {
        if (i % 3 == 2) {
            if (char != ':') return false;
        } else if (!std.ascii.isHex(char)) return false;
    }
    return true;
}

test "最小配置和空 catalog 有效" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.50.1" } };
    const cat: model.Catalog = .{};
    try validate(&config, &cat);
}

test "拒绝 IPv6 和非法 HTTP 端口" {
    var config: model.AppConfig = .{ .server = .{ .server_ip = "::1" } };
    const cat: model.Catalog = .{};
    try std.testing.expectError(error.InvalidServerIpv4, validate(&config, &cat));

    config.server.server_ip = "192.168.50.1";
    config.server.http_port = 0;
    try std.testing.expectError(error.InvalidHttpPort, validate(&config, &cat));
}
