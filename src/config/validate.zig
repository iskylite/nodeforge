//! 在服务绑定端口或修改状态前校验 config/catalog 不变量。
//! 本模块保持纯函数，不访问文件系统，也不产生副作用。
//! 校验顺序固定为 config → catalog → profiles → nodes → policy；
//! 前置检查失败时不会继续后续检查，避免在错误状态下产生误导性报告。

const std = @import("std");
const model = @import("../model.zig");
const lookup = @import("../catalog.zig");
const asset_validate = @import("../assets/validate.zig");
const profile_install = @import("../profile/install.zig");
const capacity = @import("../state/capacity.zig");

/// Node IDs are copied into several fixed-size runtime projections
/// (`boot_session`, `deployment_control`, and `node_status`).
pub const node_id_max_len = 96;

/// 配置校验错误码。
/// 所有错误均为编译期已知集合，不包含动态字符串——
/// 具体对象名和字段通过 `@errorName` 在 `observe/error.zig` 中渲染为 message。
pub const ValidationError = error{
    UnsupportedSchemaVersion,
    EmptyServerName,
    EmptyBindInterface,
    DhcpBindInterfaceRequired,
    InvalidServerIpv4,
    InvalidHttpPort,
    EmptyAssetRoot,
    EmptyTftpAssetRoot,
    InvalidDhcpSubnet,
    InvalidDhcpPool,
    InvalidDhcpRouter,
    InvalidDhcpDns,
    InvalidDhcpLeaseTime,
    InvalidDhcpOfferTime,
    InvalidDhcpAbandonTime,
    InvalidDhcpPingTimeout,
    InvalidDhcpCapacity,
    InvalidManagedCapacity,
    InvalidLogRotation,
    InvalidEventsRotation,
    InvalidLogFilePath,
    DhcpPoolOutsideSubnet,
    DhcpPoolOrder,
    NodeOutsideDhcpSubnet,
    EmptyObjectName,
    InvalidLogicalId,
    DuplicateObjectName,
    UnsupportedDistroTuple,
    DistroAdapterMismatch,
    RepositoryManagerMismatch,
    MissingGpgKey,
    MissingAsset,
    InvalidSha256,
    UnsafeAssetPath,
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
    InvalidInstallStorage,
    UnsupportedFirmwareBootOrder,
    MissingProvisioningBundle,
    InvalidProvisioningStep,
    InvalidLocale,
    InvalidTimezone,
    InvalidKeyboard,
    InvalidRootLoginPolicy,
    InstallAccessUnavailable,
    InvalidTargetNetwork,
    StaticAddressMismatch,
    DuplicateStaticAddress,
    InstallServerUnreachable,
    InstallPackageUnavailable,
    InstallIdentityUnavailable,
    ExternalEndpointForbidden,
    InvalidReinstallPolicy,
    InvalidTftpConcurrency,
    InvalidTftpBlksize,
    InvalidKernelArgs,
    KernelArgsRequiresBootloader,
};

/// 完整校验启动配置和 catalog 的引用关系。
///
/// 执行顺序固定为 config → catalog → profiles → nodes → policy，
/// 前置校验失败时不会继续后续检查。本函数不访问文件系统、不产生副作用，
/// 适合在服务绑定端口、CLI 跨文件校验和运行期配置变更前调用。
pub fn validate(config: *const model.AppConfig, catalog: *const model.Catalog) ValidationError!void {
    try validateConfig(config);
    try validateCatalog(config, catalog);
    try validateProfiles(config, catalog);
    try validateNodes(config);
    try validatePolicy(config);
}

/// M4.7 显式三层校验入口：shape 校验不会把“文件可解析”误报为完整模型可运行。
pub fn validateConfigShape(config: *const model.AppConfig) ValidationError!void {
    var startup = config.*;
    startup.distros = &.{};
    startup.profiles = &.{};
    startup.nodes = &.{};
    startup.provisioning_bundles = &.{};
    try validateConfig(&startup);
}

pub fn validateCatalogShape(catalog: *const model.Catalog) ValidationError!void {
    if (catalog.schema_version != 1 and catalog.schema_version != 2) return error.UnsupportedSchemaVersion;
    try uniqueNamed(model.DistroConfig, catalog.distros);
    try uniqueNamed(model.ProfileConfig, catalog.profiles);
    try uniqueNamed(model.ProvisioningBundle, catalog.provisioning_bundles);
    try uniqueNamed(model.RepositoryConfig, catalog.repositories);
    try uniqueNamed(model.AssetConfig, catalog.assets);
    try uniqueNamed(model.InstallSourceConfig, catalog.install_sources);
    try uniqueNamed(model.BootBundleConfig, catalog.boot_bundles);
    for (catalog.nodes, 0..) |node, index| {
        if (!validNodeId(node.id)) return error.InvalidLogicalId;
        if (!validMac(node.mac)) return error.InvalidNodeMac;
        for (catalog.nodes[index + 1 ..]) |other| {
            if (std.mem.eql(u8, node.id, other.id)) return error.DuplicateNodeId;
            if (std.ascii.eqlIgnoreCase(node.mac, other.mac)) return error.DuplicateNodeMac;
        }
    }
    for (catalog.assets) |asset| {
        asset_validate.validateRelativePath(asset.path) catch return error.UnsafeAssetPath;
        if (asset.sha256) |digest| if (!validSha256(digest)) return error.InvalidSha256;
    }
}

pub fn validateModel(config: *const model.AppConfig, catalog: *const model.Catalog) ValidationError!void {
    try validateConfigShape(config);
    try validateCatalogShape(catalog);
    const effective = model.projectCatalog(config.*, catalog);
    try validate(&effective, catalog);
}

/// 只校验启动配置自身的格式和内部一致性。
///
/// 不检查 catalog 引用关系，适用于 CLI 在 catalog 尚未加载时
/// 对 config 做快速预检。
pub fn validateConfig(config: *const model.AppConfig) ValidationError!void {
    if (config.schema_version != 1 and config.schema_version != 2) return error.UnsupportedSchemaVersion;
    if (config.server.name.len == 0) return error.EmptyServerName;
    if (config.server.bind_interface) |iface| {
        if (iface.len == 0) return error.EmptyBindInterface;
    } else {
        return error.DhcpBindInterfaceRequired;
    }
    _ = std.Io.net.IpAddress.parseIp4(config.server.server_ip, 0) catch
        return error.InvalidServerIpv4;
    if (config.server.ssh_authorized_public_key) |key| if (!validSshKey(key)) return error.InstallAccessUnavailable;
    for (config.server.ssh_authorized_public_keys) |key| if (!validSshKey(key)) return error.InstallAccessUnavailable;
    if (config.server.http_port == 0) return error.InvalidHttpPort;
    if (config.http.asset_root.len == 0 or config.http.repository_root.len == 0)
        return error.EmptyAssetRoot;
    if (config.tftp.asset_root.len == 0) return error.EmptyTftpAssetRoot;
    // M4.2 F4 / M4.8：校验 TFTP 性能配置。max_concurrent_transfers 为 ?u16，
    // 省略时启动按 max(128, 2×核) 自动派生；显式给出时只拒绝 0（非法）。
    if (config.tftp.max_concurrent_transfers) |v| {
        if (v == 0) return error.InvalidTftpConcurrency;
    }
    if (config.tftp.max_blksize < 8 or config.tftp.max_blksize > 65464) return error.InvalidTftpBlksize;
    try validateObservability(config);
    try validateDhcp(&config.dhcp);
    if (config.capacity.managed_entries) |value| {
        if (value == 0 or value > capacity.store_ceiling) return error.InvalidManagedCapacity;
    }
    try uniqueNamed(model.DistroConfig, config.distros);
    try uniqueNamed(model.ProfileConfig, config.profiles);
    try validateDistros(config);
    for (config.profiles) |profile| try validateKernelArgs(config, profile);
}

fn validateKernelArgs(config: *const model.AppConfig, profile: model.ProfileConfig) ValidationError!void {
    const value = profile.kernel_args orelse return;
    if (value.len == 0) return;
    if (profile.mode == .discovery) return error.InvalidKernelArgs;
    const family: ?model.DistroFamily = if (lookup.findDistro(config, profile.distro)) |distro| distro.family else null;
    if (!validKernelArgs(value, profile.mode, family)) return error.InvalidKernelArgs;
    if (profile.mode == .install) {
        const install = profile.install orelse return error.KernelArgsRequiresBootloader;
        if (!install.bootloader.install) return error.KernelArgsRequiresBootloader;
    }
}

/// 校验已经 canonicalize 的 M4.6 token 列表。保留名只与第一个 `=` 前的
/// 参数名精确比较，绝不做子串匹配。
pub fn validKernelArgs(value: []const u8, mode: model.ProfileMode, family: ?model.DistroFamily) bool {
    if (value.len == 0 or value.len > 256) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '=' or byte == '.' or byte == '-' or
            byte == '_' or byte == ',' or byte == ':' or byte == ' ')) return false;
    }

    var tokens = std.mem.tokenizeScalar(u8, value, ' ');
    var token_count: usize = 0;
    while (tokens.next()) |token| {
        token_count += 1;
        const name = kernelArgName(token);
        if (name.len == 0 or name[0] == '-' or reservedKernelArg(name, mode, family)) return false;

        var previous = std.mem.tokenizeScalar(u8, value, ' ');
        var previous_count: usize = 0;
        while (previous.next()) |candidate| {
            if (previous_count == token_count - 1) break;
            if (std.mem.eql(u8, kernelArgName(candidate), name)) return false;
            previous_count += 1;
        }
    }
    return token_count != 0;
}

fn kernelArgName(token: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, token, '=') orelse token.len;
    return token[0..end];
}

fn reservedKernelArg(name: []const u8, mode: model.ProfileMode, family: ?model.DistroFamily) bool {
    const common = [_][]const u8{ "ip", "root", "initrd", "BOOT_IMAGE", "nodeforge.config", "boot_session_id", "token", "capability" };
    for (common) |reserved| if (std.mem.eql(u8, name, reserved)) return true;
    if (mode != .install) return false;
    if (family == .rhel) {
        const rhel = [_][]const u8{ "rd.neednet", "inst.ks", "inst.repo", "inst.stage2" };
        for (rhel) |reserved| if (std.mem.eql(u8, name, reserved)) return true;
    } else if (family == .ubuntu) {
        const ubuntu = [_][]const u8{ "boot", "url", "cloud-config-url", "autoinstall", "ds", "ramdisk_size" };
        for (ubuntu) |reserved| if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

fn validateObservability(config: *const model.AppConfig) ValidationError!void {
    if (config.events.max_size_mb == 0 or config.events.keep == 0 or config.events.keep > 20)
        return error.InvalidEventsRotation;
    if (config.logging.file) |file| {
        if (file.path.len == 0 or file.path[0] != '/') return error.InvalidLogFilePath;
        if (file.max_size_mb == 0 or file.keep == 0 or file.keep > 20)
            return error.InvalidLogRotation;
    }
}

fn validateDhcp(dhcp: *const model.DhcpConfig) ValidationError!void {
    const slash = std.mem.indexOfScalar(u8, dhcp.subnet, '/') orelse return error.InvalidDhcpSubnet;
    const network = std.Io.net.IpAddress.parseIp4(dhcp.subnet[0..slash], 0) catch return error.InvalidDhcpSubnet;
    const prefix = std.fmt.parseInt(u6, dhcp.subnet[slash + 1 ..], 10) catch return error.InvalidDhcpSubnet;
    if (prefix > 30) return error.InvalidDhcpSubnet;
    const start = std.Io.net.IpAddress.parseIp4(dhcp.pool_start, 0) catch return error.InvalidDhcpPool;
    const end = std.Io.net.IpAddress.parseIp4(dhcp.pool_end, 0) catch return error.InvalidDhcpPool;
    const network_value = ipv4Value(network);
    const mask = prefixMask(prefix);
    if ((ipv4Value(start) & mask) != (network_value & mask) or (ipv4Value(end) & mask) != (network_value & mask))
        return error.DhcpPoolOutsideSubnet;
    if (ipv4Value(start) > ipv4Value(end)) return error.DhcpPoolOrder;
    if (dhcp.lease_seconds == 0) return error.InvalidDhcpLeaseTime;
    if (dhcp.offer_seconds == 0) return error.InvalidDhcpOfferTime;
    if (dhcp.abandon_seconds == 0) return error.InvalidDhcpAbandonTime;
    if (dhcp.ping_timeout_ms == 0) return error.InvalidDhcpPingTimeout;
    if (dhcp.max_leases) |value| {
        if (value == 0 or value > capacity.store_ceiling) return error.InvalidDhcpCapacity;
    }
    if (dhcp.router) |router| _ = std.Io.net.IpAddress.parseIp4(router, 0) catch return error.InvalidDhcpRouter;
    for (dhcp.dns) |dns| _ = std.Io.net.IpAddress.parseIp4(dns, 0) catch return error.InvalidDhcpDns;
}

/// 校验 catalog 的格式、对象唯一性和对 config 的引用关系。
///
/// 需要 config 已经通过 `validateConfig`；catalog 中的 distro/version/arch
/// 必须能在 ISO 导入所维护的 distro 能力索引中找到，asset kind 必须与引用方期望一致。
pub fn validateCatalog(config: *const model.AppConfig, catalog: *const model.Catalog) ValidationError!void {
    if (catalog.schema_version != 1 and catalog.schema_version != 2) return error.UnsupportedSchemaVersion;
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
        if (!validLogicalId(item.name)) return error.InvalidLogicalId;
        for (items[i + 1 ..]) |other|
            if (std.mem.eql(u8, item.name, other.name)) return error.DuplicateObjectName;
    }
}

pub fn validLogicalId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0]) or !std.ascii.isAlphanumeric(value[value.len - 1])) return false;
    for (value) |byte| {
        if (std.ascii.isUpper(byte)) return false;
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '.' or byte == '_' or byte == '-')) return false;
    }
    return !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..");
}

/// Node IDs use the canonical logical-ID alphabet but have a smaller bound
/// because they are retained in fixed-size hot-path and persisted state.
pub fn validNodeId(value: []const u8) bool {
    return value.len <= node_id_max_len and validLogicalId(value);
}

test "M4.3 logical ids are canonical path-safe lowercase ASCII" {
    try std.testing.expect(validLogicalId("kylin-v10-aarch64-dvd"));
    try std.testing.expect(validLogicalId("rocky_9.7-aarch64"));
    try std.testing.expect(!validLogicalId("Rocky-9"));
    try std.testing.expect(!validLogicalId("../rocky"));
    try std.testing.expect(!validLogicalId("岩石-9"));
}

test "node id must be a canonical logical id" {
    // Node ID 使用 logical-id 字符集，但运行态固定投影上限为 96 字节。
    // 校验在 catalog shape 与 config nodes 两处都生效。
    const upper: model.Catalog = .{
        .nodes = &.{.{ .id = "NodeA", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "install" }},
    };
    try std.testing.expectError(error.InvalidLogicalId, validateCatalogShape(&upper));

    const max_length: model.Catalog = .{
        .nodes = &.{.{ .id = "n" ** node_id_max_len, .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "install" }},
    };
    try validateCatalogShape(&max_length);

    const too_long: model.Catalog = .{
        .nodes = &.{.{ .id = "n" ** (node_id_max_len + 1), .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "install" }},
    };
    try std.testing.expectError(error.InvalidLogicalId, validateCatalogShape(&too_long));
}

test "node mac must be a valid hardware address" {
    const cat: model.Catalog = .{
        .nodes = &.{.{ .id = "n1", .mac = "not-a-mac", .arch = .aarch64, .profile = "install" }},
    };
    try std.testing.expectError(error.InvalidNodeMac, validateCatalogShape(&cat));
}

test "duplicate node mac is rejected case-insensitively" {
    const cat: model.Catalog = .{
        .nodes = &.{
            .{ .id = "n1", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "install" },
            .{ .id = "n2", .mac = "02:AA:BB:CC:DD:EE", .arch = .aarch64, .profile = "install" },
        },
    };
    try std.testing.expectError(error.DuplicateNodeMac, validateCatalogShape(&cat));
}

test "unsafe asset path is rejected" {
    const cat: model.Catalog = .{
        .assets = &.{.{ .name = "escape", .kind = .iso, .path = "../escape.iso" }},
    };
    try std.testing.expectError(error.UnsafeAssetPath, validateCatalogShape(&cat));
}

test "dhcp subnet prefix beyond /30 is rejected" {
    const config: model.AppConfig = .{
        .server = .{ .bind_interface = "pxe0", .server_ip = "192.168.50.1" },
        .http = test_http,
        .tftp = test_tftp,
        .dhcp = .{ .subnet = "192.168.50.0/31" },
    };
    try std.testing.expectError(error.InvalidDhcpSubnet, validateConfig(&config));
}

fn validateDistros(config: *const model.AppConfig) ValidationError!void {
    for (config.distros) |distro| {
        for (distro.versions) |version| {
            if (version.version.len == 0 or version.archs.len == 0)
                return error.UnsupportedDistroTuple;
            if (version.install_adapter != model.installAdapterForFamily(distro.family) or
                version.package_manager != model.packageManagerForFamily(distro.family))
                return error.DistroAdapterMismatch;
        }
    }
}

fn validateAssets(config: *const model.AppConfig, catalog: *const model.Catalog) ValidationError!void {
    for (catalog.assets) |asset| {
        asset_validate.validateRelativePath(asset.path) catch return error.UnsafeAssetPath;
        if (asset.sha256) |sha256|
            if (!validSha256(sha256)) return error.InvalidSha256;
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
        if (!managedRepositoryUrl(config, repository.base_url)) return error.ExternalEndpointForbidden;
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

/// M3.6：校验 install profile 与 InstallSourceConfig、diskless profile 与
/// BootBundleConfig 的 distro/version/arch 三元组完全相同。
/// 这拒绝“Ubuntu profile 引 Rocky source”或“aarch64 profile 引 x86_64 source”
/// 等配置错误，防止启动时加载不兼容的 kernel/initrd。
///
/// install profile 还必须显式标记 destructive=true 与 persistent_writes=true，
/// 因为安装会擦写磁盘。diskless profile 不允许 destructive=true，
/// 因为无盘模式不应写本地磁盘。
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
                const source = lookup.findInstallSource(catalog, name) orelse return error.InvalidProfileSource;
                if (profile.boot_bundle != null or !sameTuple(profile.distro, profile.version, profile.arch, source.distro, source.version, source.arch))
                    return error.InvalidProfileSource;
                if (!profile.safety.destructive or !profile.safety.persistent_writes) return error.InvalidProfileSafety;
                const system = profile_install.effectiveSystem(&profile) catch return error.InstallIdentityUnavailable;
                if (profile.install) |install| try validateInstallConfig(config, system, install) else return error.InvalidProfileSource;
                try validateTargetSystem(system);
                // `always` 保留为刻意高风险选项，但仅对已要求 destructive
                // persistent 的 profile 有效。
                if (profile.safety.reinstall_policy == .always and (!profile.safety.destructive or !profile.safety.persistent_writes)) return error.InvalidReinstallPolicy;
            },
            .diskless => {
                const name = profile.boot_bundle orelse return error.MissingBootBundle;
                const bundle = lookup.findBootBundle(catalog, name) orelse return error.InvalidProfileSource;
                if (profile.install_source != null or !sameTuple(profile.distro, profile.version, profile.arch, bundle.distro, bundle.version, bundle.arch))
                    return error.InvalidProfileSource;
                if (profile.safety.destructive) return error.InvalidProfileSafety;
            },
        }
    }
}

fn validateTargetSystem(system: model.TargetSystemConfig) ValidationError!void {
    if (!validLocale(system.localization.locale)) return error.InvalidLocale;
    if (!validTimezone(system.localization.timezone)) return error.InvalidTimezone;
    if (!validIdentifier(system.localization.keyboard)) return error.InvalidKeyboard;
    if (system.connectivity.time_sync and system.connectivity.ntp_servers.len == 0) return error.InvalidTargetNetwork;
    for (system.connectivity.ntp_servers) |server| if (!validNetworkName(server)) return error.InvalidTargetNetwork;
    if (system.ssh.root_login == .yes and system.ssh.root_password == null and system.ssh.root_authorized_keys.len == 0 and system.users.len == 0) return error.InstallAccessUnavailable;
    for (system.users, 0..) |user, i| {
        if (!validUser(user.name) or std.mem.eql(u8, user.name, "root")) return error.InstallAccessUnavailable;
        for (system.users[i + 1 ..]) |other| if (std.mem.eql(u8, user.name, other.name)) return error.InstallAccessUnavailable;
        for (user.ssh_authorized_keys) |key| if (!validSshKey(key)) return error.InstallAccessUnavailable;
    }
    for (system.ssh.root_authorized_keys) |key| if (!validSshKey(key)) return error.InstallAccessUnavailable;
}

fn validateInstallConfig(config: *const model.AppConfig, system: model.TargetSystemConfig, install: model.InstallConfig) ValidationError!void {
    const storage = install.storage;
    if (storage.boot_disk.len == 0 or storage.install_disks.len == 0) return error.InvalidInstallStorage;
    var disk_found = false;
    for (storage.install_disks) |disk| {
        if (!validDevicePath(disk)) return error.InvalidInstallStorage;
        if (std.mem.eql(u8, disk, storage.boot_disk)) disk_found = true;
    }
    if (!disk_found) return error.InvalidInstallStorage;
    if (install.bootloader.install and !std.mem.eql(u8, install.bootloader.target, "storage.boot_disk")) return error.InvalidInstallStorage;
    if (install.bootloader.set_firmware_boot_order) return error.UnsupportedFirmwareBootOrder;
    var esp = false;
    var biosboot = false;
    var root_count: usize = 0;
    for (storage.partitions) |part| {
        if (part.size_mib == 0) return error.InvalidInstallStorage;
        if (part.filesystem) |fs| if (!validIdentifier(fs)) return error.InvalidInstallStorage;
        if (part.mount) |mount| if (!validMountPath(mount)) return error.InvalidInstallStorage;
        if (part.kind == .esp and part.mount != null and std.mem.eql(u8, part.mount.?, "/boot/efi")) esp = true;
        if (part.kind == .biosboot) biosboot = true;
        if (part.kind == .root) root_count += 1;
    }
    // 空分区列表请求适配器默认布局；显式布局必须包含固件要求的分区。
    if (storage.partitions.len != 0 and storage.boot_mode == .uefi and !esp) return error.InvalidInstallStorage;
    if (storage.partitions.len != 0 and storage.boot_mode == .bios and storage.partition_table == .gpt and !biosboot) return error.InvalidInstallStorage;
    if (storage.partitions.len != 0 and root_count != 1) return error.InvalidInstallStorage;
    try validatePackages(system.packages);
    if (install.bundle) |name| {
        var found = false;
        for (config.provisioning_bundles) |bundle| {
            if (std.mem.eql(u8, bundle.name, name)) found = true;
        }
        if (!found) return error.MissingProvisioningBundle;
        for (config.provisioning_bundles) |bundle| if (std.mem.eql(u8, bundle.name, name)) for (bundle.steps) |step| if (step.action == .standard_packages) for (step.packages) |package| for (system.packages) |requested| if (std.mem.eql(u8, package, requested)) return error.InstallPackageUnavailable;
    }
}

/// 比较两组 distro/version/arch 三元组是否完全相同。
/// M3.6 要求 profile 与其引用的 source/bundle 三元组严格匹配。
fn sameTuple(distro: []const u8, version: []const u8, arch: model.Arch, other_distro: []const u8, other_version: []const u8, other_arch: model.Arch) bool {
    return std.mem.eql(u8, distro, other_distro) and std.mem.eql(u8, version, other_version) and arch == other_arch;
}

fn validateNodes(config: *const model.AppConfig) ValidationError!void {
    for (config.nodes, 0..) |node, i| {
        if (!validNodeId(node.id)) return error.InvalidLogicalId;
        if (!validMac(node.mac)) return error.InvalidNodeMac;
        const profile = lookup.findProfile(config, node.profile) orelse return error.MissingProfile;
        if (profile.arch != node.arch) return error.InvalidProfileSource;
        if (node.ip) |ip| {
            const parsed_ip = std.Io.net.IpAddress.parseIp4(ip, 0) catch return error.InvalidNodeIpv4;
            if (!inDhcpSubnet(config.dhcp.subnet, ipv4Value(parsed_ip))) return error.NodeOutsideDhcpSubnet;
        }
        if (node.overrides.network) |network| try validateTargetNetwork(config, node, network);
        if (profile.mode != .install and node.overrides.storage != null) return error.InvalidInstallStorage;
        if (profile.mode == .install) {
            var single_disk: [1][]const u8 = undefined;
            const install = profile_install.effectiveInstall(&node, profile, &single_disk) catch return error.InvalidInstallStorage;
            const system = profile_install.effectiveSystem(profile) catch return error.InstallIdentityUnavailable;
            try validateInstallConfig(config, system, install);
        }
        for (config.nodes[i + 1 ..]) |other| {
            if (std.mem.eql(u8, node.id, other.id)) return error.DuplicateNodeId;
            if (std.ascii.eqlIgnoreCase(node.mac, other.mac)) return error.DuplicateNodeMac;
            if (node.overrides.network) |network| if (network.address) |address| if (other.overrides.network) |other_network| if (other_network.address) |other_address| if (std.mem.eql(u8, address, other_address)) return error.DuplicateStaticAddress;
        }
    }
}

fn validateTargetNetwork(config: *const model.AppConfig, node: model.NodeConfig, network: model.TargetNetworkConfig) ValidationError!void {
    if (network.interface) |name| if (!validIdentifier(name)) return error.InvalidTargetNetwork;
    for (network.search_domains) |domain| if (!validNetworkName(domain)) return error.InvalidTargetNetwork;
    if (network.mode == .dhcp) return;
    const address = network.address orelse return error.InvalidTargetNetwork;
    const prefix = network.prefix_len orelse return error.InvalidTargetNetwork;
    if (prefix == 0 or prefix > 32) return error.InvalidTargetNetwork;
    const node_ip = node.ip orelse return error.StaticAddressMismatch;
    if (!std.mem.eql(u8, node_ip, address)) return error.StaticAddressMismatch;
    if (network.match_mac) |mac| if (!std.ascii.eqlIgnoreCase(mac, node.mac)) return error.InvalidTargetNetwork;
    const parsed = std.Io.net.IpAddress.parseIp4(address, 0) catch return error.InvalidTargetNetwork;
    if (!inDhcpSubnet(config.dhcp.subnet, ipv4Value(parsed))) return error.NodeOutsideDhcpSubnet;
    if (network.gateway) |gateway| _ = std.Io.net.IpAddress.parseIp4(gateway, 0) catch return error.InvalidTargetNetwork;
    for (network.dns) |dns| _ = std.Io.net.IpAddress.parseIp4(dns, 0) catch return error.InvalidTargetNetwork;
}

fn managedRepositoryUrl(config: *const model.AppConfig, value: []const u8) bool {
    var prefix_buffer: [160]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "http://{s}:{d}/artifacts/repositories/", .{ config.server.server_ip, config.server.http_port }) catch return false;
    if (!std.mem.startsWith(u8, value, prefix) or value.len == prefix.len) return false;
    const path = value[prefix.len..];
    if (std.mem.indexOfAny(u8, path, "?#%\\\r\n") != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~')) return false;
    }
    return true;
}

fn validNetworkName(value: []const u8) bool {
    if (value.len == 0 or value.len > 253 or value[0] == '.' or value[value.len - 1] == '.') return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.')) return false;
    return true;
}

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    return true;
}
fn validPackage(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '+' or c == ':')) return false;
    return true;
}
fn validatePackages(packages: []const []const u8) ValidationError!void {
    for (packages, 0..) |package, i| {
        if (!validPackage(package)) return error.InstallPackageUnavailable;
        for (packages[i + 1 ..]) |other| if (std.mem.eql(u8, package, other)) return error.InstallPackageUnavailable;
    }
}
fn validDevicePath(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "/dev/") and value.len > 5 and validIdentifier(value[5..]);
}
fn validMountPath(value: []const u8) bool {
    if (value.len == 0 or value[0] != '/' or std.mem.indexOf(u8, value, "..") != null) return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '/' or c == '_' or c == '-' or c == '.')) return false;
    return true;
}
fn validLocale(value: []const u8) bool {
    return std.mem.eql(u8, value, "C") or std.mem.eql(u8, value, "C.UTF-8") or validIdentifier(value) or (value.len != 0 and std.mem.indexOfScalar(u8, value, '@') != null);
}
fn validTimezone(value: []const u8) bool {
    if (std.mem.eql(u8, value, "UTC")) return true;
    if (value.len == 0 or value[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, value, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or !validIdentifier(part)) return false;
    return true;
}
fn validUser(value: []const u8) bool {
    if (value.len == 0 or value.len > 32 or !std.ascii.isLower(value[0])) return false;
    for (value) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    return true;
}
fn validSshKey(value: []const u8) bool {
    if (value.len <= 32 or value.len >= 16384 or std.mem.indexOfScalar(u8, value, '\n') != null) return false;
    const first_space = std.mem.indexOfScalar(u8, value, ' ') orelse return false;
    const kind = value[0..first_space];
    if (!(std.mem.eql(u8, kind, "ssh-ed25519") or std.mem.eql(u8, kind, "ssh-rsa") or std.mem.startsWith(u8, kind, "ecdsa-sha2-"))) return false;
    const tail = value[first_space + 1 ..];
    const body_end = std.mem.indexOfScalar(u8, tail, ' ') orelse tail.len;
    const body = tail[0..body_end];
    if (body.len == 0) return false;
    const decoded_len = std.base64.standard_no_pad.Decoder.calcSizeForSlice(body) catch return false;
    return decoded_len >= 16;
}

fn inDhcpSubnet(cidr: []const u8, ip: u32) bool {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return false;
    const network = std.Io.net.IpAddress.parseIp4(cidr[0..slash], 0) catch return false;
    const prefix = std.fmt.parseInt(u6, cidr[slash + 1 ..], 10) catch return false;
    return (ip & prefixMask(prefix)) == (ipv4Value(network) & prefixMask(prefix));
}

fn ipv4Value(address: std.Io.net.IpAddress) u32 {
    return switch (address) {
        .ip4 => |ip| std.mem.readInt(u32, &ip.bytes, .big),
        else => unreachable,
    };
}

fn prefixMask(prefix: u6) u32 {
    return if (prefix == 0) 0 else @as(u32, 0xffffffff) << @as(u5, @intCast(32 - prefix));
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

fn validSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |char|
        if (!std.ascii.isHex(char)) return false;
    return true;
}

const test_http: model.HttpConfig = .{ .asset_root = "/tmp/nodeforge/iso", .repository_root = "/tmp/nodeforge/repos" };
const test_tftp: model.TftpConfig = .{ .asset_root = "/tmp/nodeforge/boot" };

test "最小配置和空 catalog 有效" {
    const config: model.AppConfig = .{ .server = .{ .bind_interface = "pxe0", .server_ip = "192.168.50.1" }, .http = test_http, .tftp = test_tftp };
    const cat: model.Catalog = .{};
    try validate(&config, &cat);
}

test "M4.1 default UTC timezone is accepted" {
    try std.testing.expect(validTimezone("UTC"));
    try std.testing.expect(validTimezone("Asia/Shanghai"));
    try std.testing.expect(!validTimezone("/UTC"));
}

test "M4.1 repositories must use the managed local HTTP namespace" {
    const config: model.AppConfig = .{ .server = .{
        .bind_interface = "pxe0",
        .server_ip = "192.168.50.1",
        .http_port = 18080,
    } };
    try std.testing.expect(managedRepositoryUrl(&config, "http://192.168.50.1:18080/artifacts/repositories/ubuntu-22.04"));
    try std.testing.expect(!managedRepositoryUrl(&config, "https://archive.ubuntu.com/ubuntu"));
    try std.testing.expect(!managedRepositoryUrl(&config, "http://192.168.50.1:18080/artifacts/repositories/"));
    try std.testing.expect(!managedRepositoryUrl(&config, "http://192.168.50.1:18080/artifacts/repositories/local?mirror=external"));
    try std.testing.expect(!managedRepositoryUrl(&config, "http://192.168.50.1:18080/artifacts/repositories/../images/private"));
    try std.testing.expect(!managedRepositoryUrl(&config, "http://192.168.50.1:18080/artifacts/repositories/%2e%2e/images/private"));

    const catalog: model.Catalog = .{
        .repositories = &.{.{
            .name = "external",
            .distro = "ubuntu",
            .version = "22.04",
            .arch = .aarch64,
            .manager = .apt,
            .base_url = "https://archive.ubuntu.com/ubuntu",
        }},
    };
    var full_config = config;
    full_config.distros = &.{.{
        .name = "ubuntu",
        .family = .ubuntu,
        .versions = &.{.{
            .version = "22.04",
            .archs = &.{.aarch64},
            .install_adapter = .autoinstall,
            .package_manager = .apt,
        }},
    }};
    try std.testing.expectError(error.ExternalEndpointForbidden, validateCatalog(&full_config, &catalog));
}

test "DHCP requires an explicit PXE interface" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.50.1" } };
    try std.testing.expectError(error.DhcpBindInterfaceRequired, validateConfig(&config));
}

test "install profile must match its install source tuple" {
    const config: model.AppConfig = .{
        .server = .{ .bind_interface = "pxe0", .server_ip = "192.168.50.1" },
        .http = test_http,
        .tftp = test_tftp,
        .distros = &.{
            .{ .name = "rocky", .family = .rhel, .versions = &.{.{ .version = "9.7", .archs = &.{.aarch64}, .install_adapter = .kickstart, .package_manager = .dnf }} },
            .{ .name = "ubuntu", .family = .ubuntu, .versions = &.{.{ .version = "22.04", .archs = &.{.aarch64}, .install_adapter = .autoinstall, .package_manager = .apt }} },
        },
        .profiles = &.{.{ .name = "wrong-profile", .mode = .install, .distro = "ubuntu", .version = "22.04", .arch = .aarch64, .install_source = "rocky-source", .safety = .{ .destructive = true } }},
    };
    const catalog: model.Catalog = .{
        .assets = &.{
            .{ .name = "rocky-iso", .kind = .iso, .path = "iso/rocky.iso", .distro = "rocky", .version = "9.7", .arch = .aarch64 },
            .{ .name = "rocky-kernel", .kind = .kernel, .path = "install/rocky/vmlinuz", .distro = "rocky", .version = "9.7", .arch = .aarch64 },
            .{ .name = "rocky-initrd", .kind = .installer_initrd, .path = "install/rocky/initrd.img", .distro = "rocky", .version = "9.7", .arch = .aarch64 },
        },
        .install_sources = &.{.{ .name = "rocky-source", .distro = "rocky", .version = "9.7", .arch = .aarch64, .source_asset = "rocky-iso", .installer_kernel = "rocky-kernel", .installer_initrd = "rocky-initrd" }},
    };
    try std.testing.expectError(error.InvalidProfileSource, validate(&config, &catalog));
}

test "拒绝 IPv6 和非法 HTTP 端口" {
    var config: model.AppConfig = .{ .server = .{ .bind_interface = "pxe0", .server_ip = "::1" } };
    const cat: model.Catalog = .{};
    try std.testing.expectError(error.InvalidServerIpv4, validate(&config, &cat));

    config.server.server_ip = "192.168.50.1";
    config.server.http_port = 0;
    try std.testing.expectError(error.InvalidHttpPort, validate(&config, &cat));
}

test "DHCP 地址池和静态保留必须位于服务子网" {
    var config: model.AppConfig = .{ .server = .{ .bind_interface = "pxe0", .server_ip = "192.168.50.1" }, .http = test_http, .tftp = test_tftp };
    config.dhcp.pool_end = "192.168.51.10";
    try std.testing.expectError(error.DhcpPoolOutsideSubnet, validateConfig(&config));
    config.dhcp.pool_end = "192.168.50.10";
    config.dhcp.pool_start = "192.168.50.20";
    try std.testing.expectError(error.DhcpPoolOrder, validateConfig(&config));
}

test "M4.8 explicit state capacity must fit the compiled safety ceiling" {
    var config: model.AppConfig = .{ .server = .{ .bind_interface = "pxe0", .server_ip = "192.168.50.1" }, .http = test_http, .tftp = test_tftp };
    config.dhcp.max_leases = 2049;
    try std.testing.expectError(error.InvalidDhcpCapacity, validateConfig(&config));
    config.dhcp.max_leases = null;
    config.capacity.managed_entries = 2049;
    try std.testing.expectError(error.InvalidManagedCapacity, validateConfig(&config));
    config.capacity.managed_entries = 1024;
    try validateConfig(&config);
}

test "M4.6 kernel args accept hardware parameters and reject injection" {
    try std.testing.expect(validKernelArgs("iommu=pt hugepagesz=1G hugepages=4", .install, .rhel));
    try std.testing.expect(validKernelArgs("vfio-pci.ids=10de:1b06,8086:1a16 isolcpus=0,2,4-7", .diskless, .ubuntu));
    try std.testing.expect(!validKernelArgs("iommu=pt;reboot", .install, .rhel));
    try std.testing.expect(!validKernelArgs("foo='bar'", .install, .rhel));
    try std.testing.expect(!validKernelArgs("foo=$bar", .install, .rhel));
    try std.testing.expect(!validKernelArgs("-debug", .diskless, .ubuntu));
    try std.testing.expect(!validKernelArgs("iommu=pt iommu=strict", .install, .rhel));
}

test "M4.6 reserved kernel args use exact mode-aware token names" {
    try std.testing.expect(!validKernelArgs("inst.ks=http", .install, .rhel));
    try std.testing.expect(!validKernelArgs("url=http", .install, .ubuntu));
    try std.testing.expect(!validKernelArgs("nodeforge.config=x", .diskless, .ubuntu));
    try std.testing.expect(validKernelArgs("foo.inst.ks=1", .install, .rhel));
    try std.testing.expect(validKernelArgs("url=http", .diskless, .ubuntu));
}

test "M4.6 kernel args length boundary is 256 bytes" {
    var accepted: [256]u8 = undefined;
    @memset(&accepted, 'a');
    accepted[1] = '=';
    try std.testing.expect(validKernelArgs(&accepted, .diskless, .ubuntu));
    var rejected: [257]u8 = undefined;
    @memset(&rejected, 'a');
    rejected[1] = '=';
    try std.testing.expect(!validKernelArgs(&rejected, .diskless, .ubuntu));
}

test "M4.6 discovery rejects kernel args and install requires bootloader" {
    var config: model.AppConfig = .{
        .server = .{ .bind_interface = "pxe0", .server_ip = "192.168.50.1" },
        .http = test_http,
        .tftp = test_tftp,
        .distros = &.{.{ .name = "rocky", .family = .rhel, .versions = &.{.{ .version = "9.7", .archs = &.{.aarch64}, .install_adapter = .kickstart, .package_manager = .dnf }} }},
        .profiles = &.{.{ .name = "discovery", .mode = .discovery, .distro = "rocky", .version = "9.7", .arch = .aarch64, .kernel_args = "iommu=pt" }},
    };
    try std.testing.expectError(error.InvalidKernelArgs, validateConfig(&config));
    config.profiles = &.{.{ .name = "install", .mode = .install, .distro = "rocky", .version = "9.7", .arch = .aarch64, .install_source = "rocky", .install = .{ .bootloader = .{ .install = false } }, .kernel_args = "iommu=pt" }};
    try std.testing.expectError(error.KernelArgsRequiresBootloader, validateConfig(&config));
}

test "node storage overrides are install-only" {
    var config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.50.1" },
        .profiles = &.{.{ .name = "discovery", .mode = .discovery, .distro = "rocky", .version = "9.7", .arch = .aarch64 }},
        .nodes = &.{.{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "discovery", .overrides = .{ .storage = .{ .boot_disk = "/dev/vda" } } }},
    };
    try std.testing.expectError(error.InvalidInstallStorage, validateNodes(&config));

    config.profiles = &.{.{ .name = "diskless", .mode = .diskless, .distro = "rocky", .version = "9.7", .arch = .aarch64 }};
    config.nodes = &.{.{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "diskless", .overrides = .{ .storage = .{ .boot_disk = "/dev/vda" } } }};
    try std.testing.expectError(error.InvalidInstallStorage, validateNodes(&config));
}

test "node storage override validates the effective install plan" {
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.50.1" },
        .profiles = &.{.{ .name = "install", .mode = .install, .distro = "rocky", .version = "9.7", .arch = .aarch64, .install = .{} }},
        .nodes = &.{.{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "install", .overrides = .{ .storage = .{ .boot_disk = "/tmp/not-a-device" } } }},
    };
    try std.testing.expectError(error.InvalidInstallStorage, validateNodes(&config));
}

test "拒绝格式错误的 SHA256" {
    const config: model.AppConfig = .{ .server = .{ .bind_interface = "pxe0", .server_ip = "192.168.50.1" }, .http = test_http, .tftp = test_tftp };
    const catalog: model.Catalog = .{
        .assets = &.{.{
            .name = "invalid-checksum",
            .kind = .iso,
            .path = "iso/test.iso",
            .sha256 = "not-a-sha256",
        }},
    };
    try std.testing.expectError(error.InvalidSha256, validate(&config, &catalog));
}
