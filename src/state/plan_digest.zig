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
/// `additional_keys` 是除 bootstrap key 外还需注入目标节点的 SSH 公钥列表。
pub const Delivery = struct {
    /// bootstrap SSH 公钥（来自受管 key 文件或 daemon 自动生成）。
    bootstrap_key: []const u8,
    /// 额外注入的 SSH 公钥列表（如运维人员 key）。
    additional_keys: []const []const u8,
};

/// 计算单个节点的不可变部署计划 SHA-256 摘要。
///
/// 摘要只覆盖实际影响目标节点 PXE/安装结果的事实，不包含 catalog revision、
/// 其他节点、其他 profile 或未被引用的资产。这确保两个引用相同安装输入的
/// 节点会得到相同的 digest，而修改仅影响一个节点的配置不会改变另一个节点
/// 的 digest（避免误触发 drift）。
///
/// 摘要覆盖的输入范围：
/// - **delivery**：server IP/port、bootstrap key、additional keys。
/// - **distro**：发行版名称、family、版本（arch/install_adapter/package_manager 等）。
/// - **effective**：编译后的 effective 配置（node + profile 合并结果），包括
///   node_id/mac/arch/hostname/deploy/http_accel/pxe、profile install/system/
///   software/network/kernel_args 等字段。
/// - **install_source**：安装源配置（source_asset/installer_kernel/initrd 等）。
/// - **assets**：被引用的 ISO/kernel/initrd/bootloader asset 及其 SHA-256。
/// - **repositories**：安装源引用的仓库及其 GPG key asset。
/// - **provisioning_bundle**（可选）：profile 引用的 provisioning bundle。
///
/// 返回完整 64 字符小写十六进制 SHA-256。调用方必须使用完整值做授权、
/// 恢复 join 和 drift 判断；禁止截断后比较。
pub fn forNode(allocator: std.mem.Allocator, config: *const model.AppConfig, source: *const model.Catalog, delivery: Delivery, node_id: []const u8) !Digest {
    // 解析引用链：node -> profile -> install_source -> distro/distro_version。
    // 任一引用缺失都返回对应的 NotFound 错误。
    const node = catalog.findNode(source, node_id) orelse return error.NodeNotFound;
    const profile = catalog.findProfile(source, node.profile orelse return error.ProfileNotFound) orelse return error.ProfileNotFound;
    const install_source = catalog.findInstallSource(source, profile.install_source) orelse return error.InstallSourceNotFound;
    const distro = catalog.findDistro(source, install_source.distro) orelse return error.DistroNotFound;
    const distro_version = catalog.findDistroVersion(source, install_source.distro, install_source.version, install_source.arch) orelse return error.DistroVersionNotFound;

    // 使用 Allocating Writer 构建规范化字符串，按有序的 tag:value 格式逐段追加。
    // 每段以 tag 名开头，确保不同段不会因字段顺序变化而产生不同的 hash。
    var canonical: std.Io.Writer.Allocating = .init(allocator);
    defer canonical.deinit();
    // 投递信息：server 地址和 SSH 密钥。
    try append(&canonical.writer, "delivery", .{
        .server_ip = config.server.server_ip,
        .http_port = config.server.http_port,
        .bootstrap_key = delivery.bootstrap_key,
        .additional_keys = delivery.additional_keys,
    });
    // 发行版信息：名称、family 和完整版本配置。
    try append(&canonical.writer, "distro", .{ .name = distro.name, .family = distro.family, .version = distro_version.* });

    {
        // 编译 effective 配置：将 node 和 profile 的默认值、覆盖值合并为
        // 最终安装输入。effective 包含存储、网络、软件包等所有影响
        // 安装结果的字段。
        var effective = try @import("../profile/effective.zig").compileInputs(allocator, node, profile, install_source);
        defer effective.deinit();
        try append(&canonical.writer, "effective", .{
            .node_id = effective.node.id,
            .mac = effective.node.mac,
            .arch = effective.node.arch,
            .hostname = effective.node.hostname,
            .deploy = effective.node.deploy,
            .http_accel = effective.node.http_accel,
            .pxe = effective.node.pxe,
            .profile_name = effective.profile_name,
            .install = effective.install,
            .system = effective.system,
            .software = effective.software,
            .network = effective.network,
            .kernel_args = effective.kernel_args,
        });
        try append(&canonical.writer, "install_source", install_source.*);
        // 追加被引用的 asset：ISO、kernel、initrd。每个 asset 的 SHA-256
        // 也参与摘要，确保资产内容变更会改变 digest（触发 drift 检测）。
        try appendAsset(&canonical.writer, source, install_source.source_asset);
        try appendAsset(&canonical.writer, source, install_source.installer_kernel);
        try appendAsset(&canonical.writer, source, install_source.installer_initrd);
        // DHCP option 67 使用每架构共享的 canonical UEFI bootloader。
        // bootloader 文件名由架构决定，不取决于配置。
        const bootloader_name = switch (install_source.arch) {
            .aarch64 => "grub-uefi-aarch64",
            .x86_64 => "grub-uefi-x86-64",
        };
        for (source.assets) |asset| {
            if (asset.kind != .bootloader or !std.mem.eql(u8, asset.name, bootloader_name)) continue;
            try append(&canonical.writer, "bootloader_asset", asset);
        }
        // bootloader asset 是架构级共享资产；不含可用 UEFI bootloader 的
        // 迁移输入仍可计算 plan，但 drift 摘要不含该资产。
        // 仓库配置及其 GPG key asset 也参与摘要。
        for (install_source.repositories) |name| {
            const repository = catalog.findRepository(source, name) orelse return error.RepositoryNotFound;
            try append(&canonical.writer, "repository", repository.*);
            if (repository.gpg_key) |key| try appendAsset(&canonical.writer, source, key);
        }
        // provisioning bundle（可选）：post_install 或 install bundle。
        if (profile.install.post_install.bundle) |name| {
            var found = false;
            for (source.provisioning_bundles) |bundle| if (std.mem.eql(u8, bundle.name, name)) {
                try append(&canonical.writer, "provisioning_bundle", bundle);
                found = true;
                break;
            };
            if (!found) return error.ProvisioningBundleNotFound;
        }
    }

    // 对规范化字符串计算 SHA-256，输出为 64 字符小写十六进制。
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(canonical.written(), &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

/// 在 canonical writer 中追加一个带 tag 前缀的 asset。
/// 通过名称查找 asset 并以 "asset" tag 追加其完整配置（包含 SHA-256）。
fn appendAsset(writer: *std.Io.Writer, source: *const model.Catalog, name: []const u8) !void {
    const asset = catalog.findAsset(source, name) orelse return error.AssetNotFound;
    try append(writer, "asset", asset.*);
}

/// 将 `tag:value` 以 JSON 格式追加到 writer。tag 先序列化为 JSON 字符串，
/// 然后跟冒号和 value 的 JSON 序列化结果，最后换行。
/// 这种格式保证了相同输入总是产生相同的 canonical 字符串。
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
        .{ .name = "target", .install_source = "source" },
        .{ .name = "unrelated", .install_source = "other-source" },
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

test "node direct disk participates in plan digest" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1" } };
    const versions = [_]model.DistroVersionConfig{.{ .version = "9.7", .archs = &.{.aarch64}, .install_adapter = .kickstart, .package_manager = .dnf }};
    const distros = [_]model.DistroConfig{.{ .name = "rocky", .family = .rhel, .versions = &versions }};
    var profiles = [_]model.ProfileConfig{.{ .name = "target", .install_source = "source" }};
    var nodes = [_]model.NodeConfig{.{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "target", .storage = .{ .boot_disk = "/dev/nvme0n1" } }};
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
    nodes[0].storage.boot_disk = "/dev/vda";
    try std.testing.expect(!std.mem.eql(u8, &baseline, &(try forNode(std.testing.allocator, &config, &model_catalog, delivery, "n1"))));
}
