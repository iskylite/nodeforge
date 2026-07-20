//! M4.9b 节点级不可变部署计划 SHA-256。
//!
//! 摘要只覆盖实际影响目标节点 PXE/安装结果的事实，不包含 catalog revision、
//! 其他节点、其他 profile 或未被引用的资产。调用方必须使用完整 64 字符小写
//! 十六进制值做授权、恢复 join 和 drift 判断；禁止截断后比较。

const std = @import("std");
const model = @import("../model.zig");
const catalog = @import("../catalog.zig");

pub const Digest = [64]u8;

/// 已解析的实际交付密钥。配置为空时，bootstrap key 可能来自受管 key
/// 文件、root 公钥或 daemon 自动生成文件，因此不能只对 ServerConfig 做摘要。
pub const Delivery = struct {
    bootstrap_key: []const u8,
    additional_keys: []const []const u8,
};

pub fn forNode(allocator: std.mem.Allocator, config: *const model.AppConfig, source: *const model.Catalog, delivery: Delivery, node_id: []const u8) !Digest {
    const node = catalog.findNode(source, node_id) orelse return error.NodeNotFound;
    const profile = catalog.findProfile(source, node.profile) orelse return error.ProfileNotFound;
    const distro = catalog.findDistro(source, profile.distro) orelse return error.DistroNotFound;
    const distro_version = catalog.findDistroVersion(source, profile.distro, profile.version, profile.arch) orelse return error.DistroVersionNotFound;

    var canonical: std.Io.Writer.Allocating = .init(allocator);
    defer canonical.deinit();
    try append(&canonical.writer, "delivery", .{
        .server_ip = config.server.server_ip,
        .http_port = config.server.http_port,
        .bootstrap_key = delivery.bootstrap_key,
        .additional_keys = delivery.additional_keys,
    });
    try append(&canonical.writer, "node", node.*);
    var effective_profile = profile.*;
    var single_disk: [1][]const u8 = undefined;
    if (profile.mode == .install) effective_profile.install = try @import("../profile/install.zig").effectiveInstall(node, profile, &single_disk);
    // Hash the effective profile, not the raw shared storage default. A profile
    // disk-default change must not drift nodes that explicitly override it.
    try append(&canonical.writer, "profile", effective_profile);
    try append(&canonical.writer, "distro", .{ .name = distro.name, .family = distro.family, .version = distro_version.* });

    switch (profile.mode) {
        .install => {
            const install_source = catalog.findInstallSource(source, profile.install_source orelse return error.InstallSourceNotFound) orelse return error.InstallSourceNotFound;
            try append(&canonical.writer, "install_source", install_source.*);
            try appendAsset(&canonical.writer, source, install_source.source_asset);
            try appendAsset(&canonical.writer, source, install_source.installer_kernel);
            try appendAsset(&canonical.writer, source, install_source.installer_initrd);
            // DHCP option 67 使用每架构共享的 canonical UEFI bootloader。
            const bootloader_name = switch (profile.arch) {
                .aarch64 => "grub-uefi-aarch64",
                .x86_64 => "grub-uefi-x86-64",
            };
            var found_bootloader = false;
            for (source.assets) |asset| {
                if (asset.kind != .bootloader or !std.mem.eql(u8, asset.name, bootloader_name)) continue;
                try append(&canonical.writer, "bootloader_asset", asset);
                found_bootloader = true;
            }
            if (!found_bootloader) return error.BootloaderNotFound;
            for (install_source.repositories) |name| {
                const repository = catalog.findRepository(source, name) orelse return error.RepositoryNotFound;
                try append(&canonical.writer, "repository", repository.*);
                if (repository.gpg_key) |key| try appendAsset(&canonical.writer, source, key);
            }
            if (profile.install) |install| if (install.bundle) |name| {
                var found = false;
                for (source.provisioning_bundles) |bundle| if (std.mem.eql(u8, bundle.name, name)) {
                    try append(&canonical.writer, "provisioning_bundle", bundle);
                    found = true;
                    break;
                };
                if (!found) return error.ProvisioningBundleNotFound;
            };
        },
        .diskless => {
            const bundle = catalog.findBootBundle(source, profile.boot_bundle orelse return error.BootBundleNotFound) orelse return error.BootBundleNotFound;
            try append(&canonical.writer, "boot_bundle", bundle.*);
            try appendAsset(&canonical.writer, source, bundle.kernel);
            try appendAsset(&canonical.writer, source, bundle.initrd);
            try appendAsset(&canonical.writer, source, bundle.rootfs);
        },
        .discovery => {},
    }

    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical.written(), &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

fn appendAsset(writer: *std.Io.Writer, source: *const model.Catalog, name: []const u8) !void {
    const asset = catalog.findAsset(source, name) orelse return error.AssetNotFound;
    try append(writer, "asset", asset.*);
}

fn append(writer: *std.Io.Writer, tag: []const u8, value: anytype) !void {
    try std.json.Stringify.value(tag, .{}, writer);
    try writer.writeByte(':');
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

test "node plan digest ignores unrelated entities and tracks referenced inputs" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1" } };
    const versions = [_]model.DistroVersionConfig{.{ .version = "9.7", .archs = &.{.aarch64}, .install_adapter = .kickstart, .package_manager = .dnf }};
    const distros = [_]model.DistroConfig{.{ .name = "rocky", .family = .rhel, .versions = &versions }};
    var profiles = [_]model.ProfileConfig{
        .{ .name = "target", .mode = .install, .distro = "rocky", .version = "9.7", .arch = .aarch64, .install_source = "source", .install = .{} },
        .{ .name = "unrelated", .mode = .discovery, .distro = "rocky", .version = "9.7", .arch = .aarch64 },
    };
    var nodes = [_]model.NodeConfig{
        .{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "target" },
        .{ .id = "n2", .mac = "02:00:00:00:00:02", .arch = .aarch64, .profile = "unrelated" },
    };
    var assets = [_]model.AssetConfig{
        .{ .name = "iso", .kind = .iso, .path = "iso", .sha256 = "aa" },
        .{ .name = "kernel", .kind = .kernel, .path = "kernel", .sha256 = "bb" },
        .{ .name = "initrd", .kind = .installer_initrd, .path = "initrd", .sha256 = "cc" },
        .{ .name = "grub-uefi-aarch64", .kind = .bootloader, .path = "efi/grubaa64.efi", .arch = .aarch64, .sha256 = "dd" },
        .{ .name = "unused", .kind = .iso, .path = "unused", .sha256 = "ee" },
    };
    const sources = [_]model.InstallSourceConfig{.{ .name = "source", .distro = "rocky", .version = "9.7", .arch = .aarch64, .source_asset = "iso", .installer_kernel = "kernel", .installer_initrd = "initrd" }};
    var model_catalog: model.Catalog = .{ .distros = &distros, .profiles = &profiles, .nodes = &nodes, .assets = &assets, .install_sources = &sources };
    const delivery: Delivery = .{ .bootstrap_key = "ssh-ed25519 AAAA-primary", .additional_keys = &.{"ssh-ed25519 AAAA-extra"} };
    const baseline = try forNode(std.testing.allocator, &config, &model_catalog, delivery, "n1");
    profiles[1].kernel_args = "unrelated=1";
    nodes[1].hostname = "other";
    assets[4].sha256 = "changed-unused";
    try std.testing.expectEqualSlices(u8, &baseline, &(try forNode(std.testing.allocator, &config, &model_catalog, delivery, "n1")));
    assets[1].sha256 = "changed-kernel";
    try std.testing.expect(!std.mem.eql(u8, &baseline, &(try forNode(std.testing.allocator, &config, &model_catalog, delivery, "n1"))));
    const changed_delivery: Delivery = .{ .bootstrap_key = "ssh-ed25519 AAAA-replaced", .additional_keys = delivery.additional_keys };
    try std.testing.expect(!std.mem.eql(u8, &baseline, &(try forNode(std.testing.allocator, &config, &model_catalog, changed_delivery, "n1"))));
}

test "profile disk default does not drift an overridden node" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1" } };
    const versions = [_]model.DistroVersionConfig{.{ .version = "9.7", .archs = &.{.aarch64}, .install_adapter = .kickstart, .package_manager = .dnf }};
    const distros = [_]model.DistroConfig{.{ .name = "rocky", .family = .rhel, .versions = &versions }};
    var profiles = [_]model.ProfileConfig{.{ .name = "target", .mode = .install, .distro = "rocky", .version = "9.7", .arch = .aarch64, .install_source = "source", .install = .{} }};
    const nodes = [_]model.NodeConfig{.{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "target", .overrides = .{ .storage = .{ .boot_disk = "/dev/nvme0n1" } } }};
    const assets = [_]model.AssetConfig{
        .{ .name = "iso", .kind = .iso, .path = "iso", .sha256 = "aa" },
        .{ .name = "kernel", .kind = .kernel, .path = "kernel", .sha256 = "bb" },
        .{ .name = "initrd", .kind = .installer_initrd, .path = "initrd", .sha256 = "cc" },
        .{ .name = "grub-uefi-aarch64", .kind = .bootloader, .path = "efi/grubaa64.efi", .arch = .aarch64, .sha256 = "dd" },
    };
    const sources = [_]model.InstallSourceConfig{.{ .name = "source", .distro = "rocky", .version = "9.7", .arch = .aarch64, .source_asset = "iso", .installer_kernel = "kernel", .installer_initrd = "initrd" }};
    var model_catalog: model.Catalog = .{ .distros = &distros, .profiles = &profiles, .nodes = &nodes, .assets = &assets, .install_sources = &sources };
    const delivery: Delivery = .{ .bootstrap_key = "ssh-ed25519 AAAA-primary", .additional_keys = &.{} };
    const baseline = try forNode(std.testing.allocator, &config, &model_catalog, delivery, "n1");
    profiles[0].install.?.storage.boot_disk = "/dev/vda";
    profiles[0].install.?.storage.install_disks = &.{"/dev/vda"};
    try std.testing.expectEqualSlices(u8, &baseline, &(try forNode(std.testing.allocator, &config, &model_catalog, delivery, "n1")));
}
