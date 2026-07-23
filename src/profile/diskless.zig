//! # Diskless effective-plan compiler (v0.2)
//!
//! 将 diskless Profile + Node + InstallSource + BootBundle + Catalog 编译为三个
//! 投影和两个摘要，对应 `V0_2_IMPL_DETAILS.md` §3.1 的控制流根：
//!
//! - `profile_build_projection`：Profile 固定的共享 rootfs 输入。**不含任何 Node
//!   输入**，因此同一 diskless Profile revision 的所有 Node 解析到同一个
//!   `rootfs_input_digest`。
//! - `node_boot_projection`：只在 kernel/rootfs 之前生效的内容（合并后的 kernel
//!   arguments、transport/overlay/session 参数）。
//! - `node_apply_projection`：切根后由 agent pre-init 重放的运行根差量（node 身份、
//!   网络、合并后的 target-system/software、first-boot descriptor）。
//!
//! 只有第一项进入 `rootfs_input_digest`；后两项进入 `desired_plan_digest`。
//! target-system/software/kernel-args 复用 v0.1 [`effective`] 编译器的合并逻辑，
//! 不建立第二套 users/packages/network 默认值。
const std = @import("std");
const model = @import("../model.zig");
const catalog_lookup = @import("../catalog.zig");
const effective = @import("effective.zig");
const install_compiler = @import("install.zig");

pub const Digest = [64]u8;

/// v0.2 唯一 rootfs 形态。单值枚举保留可读标签，不提供可切换 mode 字段。
pub const OverlayMode = enum { @"squashfs-overlay" };

/// Profile 引用仓库的固定 revision 快照，进入 rootfs 缓存 key。
pub const RepositoryRevision = struct {
    name: []const u8,
    revision_digest: ?[]const u8,
};

/// Profile-fixed rootfs 构建输入。Node-independent。
pub const ProfileBuildProjection = struct {
    profile_name: []const u8,
    kind: model.ProfileKind,
    install_source: []const u8,
    source_asset: []const u8,
    distro: []const u8,
    version: []const u8,
    arch: model.Arch,
    boot_bundle: ?[]const u8,
    runtime_kernel: ?[]const u8,
    kernel_release: []const u8,
    kernel: []const u8,
    initrd: []const u8,
    system: model.TargetSystemConfig,
    software: model.SoftwareSelection,
    repository_revisions: []const RepositoryRevision,
    rootfs_build_steps: []const model.ProvisionStep,
    first_boot_fixed_steps: []const model.ProvisionStep,
};

/// 只在 kernel/rootfs 之前生效的内容。
pub const NodeBootProjection = struct {
    kernel_args: ?[]const u8,
    server_ip: []const u8,
    http_port: u16,
    overlay_mode: OverlayMode,
};

/// Per-Node 运行根差量，由 agent pre-init 重放。
pub const NodeApplyProjection = struct {
    node_id: []const u8,
    mac: []const u8,
    arch: model.Arch,
    hostname: ?[]const u8,
    network: model.TargetNetworkConfig,
    system: model.TargetSystemConfig,
    software: model.SoftwareSelection,
    first_boot_bundle: ?[]const u8,
};

/// 完整 diskless effective plan。`inner` 持有合并后的 system/software/kernel_args
/// 及其动态内存；投影中的切片引用 `inner` 或调用方拥有的 catalog/profile 内存，
/// 在 `deinit` 前保持有效。
pub const DisklessPlan = struct {
    allocator: std.mem.Allocator,
    profile_build: ProfileBuildProjection,
    node_boot: NodeBootProjection,
    node_apply: NodeApplyProjection,
    rootfs_input_digest: Digest,
    desired_plan_digest: Digest,
    inner: effective.Plan,
    repository_revisions: []const RepositoryRevision = &.{},

    pub fn deinit(self: *DisklessPlan) void {
        self.inner.deinit();
        if (self.repository_revisions.len != 0) self.allocator.free(self.repository_revisions);
    }
};

/// 从 catalog 编译节点的 diskless effective plan。
///
/// 查找节点绑定的 diskless profile、install source 与 boot bundle，复用 v0.1
/// effective 编译器合并 Node override，再产出三投影与两摘要。
pub fn compile(allocator: std.mem.Allocator, config: *const model.AppConfig, catalog: *const model.Catalog, node: *const model.NodeConfig) !DisklessPlan {
    const profile = catalog_lookup.findProfile(catalog, node.profile orelse return error.NodeUnassigned) orelse return error.MissingProfile;
    if (profile.kind != .diskless) return error.ProfileNotDiskless;
    const source = catalog_lookup.findInstallSource(catalog, profile.install_source) orelse return error.MissingInstallSource;
    const bundle_name = profile.boot_bundle orelse return error.MissingBootBundle;
    const boot_bundle = catalog_lookup.findBootBundle(catalog, bundle_name) orelse return error.MissingBootBundle;

    // 复用 v0.1 编译器：得到 Node-merged system/software/kernel_args（含 owned 内存）。
    var inner = try effective.compileInputs(allocator, node, profile, source);
    errdefer inner.deinit();

    // Profile-fixed 基线：effectiveSystem(profile) 不含 Node override。
    const profile_system = try install_compiler.effectiveSystem(profile);

    // Profile build bundle 的 rootfs_build / first_boot 步骤拆分（Profile 固定）。
    const build_steps = findBundle(catalog, profile.bundle);
    const rootfs_build_steps = phaseSteps(build_steps, .rootfs_build);
    const first_boot_fixed_steps = phaseSteps(build_steps, .first_boot);

    // Node first-boot descriptor：override 完整替换，否则继承 Profile 的 first_boot 标记。
    const node_firstboot_bundle = node.overrides.diskless.provision.bundle orelse profile.bundle;

    const repository_revisions = try resolveRepositoryRevisions(allocator, catalog, &profile.software);
    errdefer allocator.free(repository_revisions);

    const profile_build: ProfileBuildProjection = .{
        .profile_name = profile.name,
        .kind = profile.kind,
        .install_source = source.name,
        .source_asset = source.source_asset,
        .distro = source.distro,
        .version = source.version,
        .arch = source.arch,
        .boot_bundle = bundle_name,
        .runtime_kernel = boot_bundle.runtime_kernel,
        .kernel_release = boot_bundle.kernel_release,
        .kernel = boot_bundle.kernel,
        .initrd = boot_bundle.initrd,
        .system = profile_system,
        .software = profile.software,
        .repository_revisions = repository_revisions,
        .rootfs_build_steps = rootfs_build_steps,
        .first_boot_fixed_steps = first_boot_fixed_steps,
    };
    const node_boot: NodeBootProjection = .{
        .kernel_args = inner.kernel_args,
        .server_ip = config.server.server_ip,
        .http_port = config.server.http_port,
        .overlay_mode = .@"squashfs-overlay",
    };
    const node_apply: NodeApplyProjection = .{
        .node_id = node.id,
        .mac = node.mac,
        .arch = node.arch,
        .hostname = node.hostname,
        .network = node.network,
        .system = inner.system,
        .software = inner.software,
        .first_boot_bundle = node_firstboot_bundle,
    };

    return .{
        .allocator = allocator,
        .profile_build = profile_build,
        .node_boot = node_boot,
        .node_apply = node_apply,
        .rootfs_input_digest = try digestOf(allocator, profile_build),
        .desired_plan_digest = try digestOfPair(allocator, node_boot, node_apply),
        .inner = inner,
        .repository_revisions = repository_revisions,
    };
}

/// 计算一个 diskless Profile 的 `rootfs_input_digest`（Node-independent）。
/// 供 `profile rootfs plan`/`register` 等不绑定具体 Node 的操作使用；
/// 结果与 `compile(...).rootfs_input_digest` 完全一致（profile_build 投影相同）。
pub fn rootfsInputDigest(allocator: std.mem.Allocator, config: *const model.AppConfig, catalog: *const model.Catalog, profile: *const model.ProfileConfig) !Digest {
    _ = config;
    if (profile.kind != .diskless) return error.ProfileNotDiskless;
    const source = catalog_lookup.findInstallSource(catalog, profile.install_source) orelse return error.MissingInstallSource;
    const bundle_name = profile.boot_bundle orelse return error.MissingBootBundle;
    const boot_bundle = catalog_lookup.findBootBundle(catalog, bundle_name) orelse return error.MissingBootBundle;
    const profile_system = try install_compiler.effectiveSystem(profile);
    const build_steps = findBundle(catalog, profile.bundle);
    const rootfs_build_steps = phaseSteps(build_steps, .rootfs_build);
    const first_boot_fixed_steps = phaseSteps(build_steps, .first_boot);
    const repository_revisions = try resolveRepositoryRevisions(allocator, catalog, &profile.software);
    defer allocator.free(repository_revisions);
    const profile_build: ProfileBuildProjection = .{
        .profile_name = profile.name,
        .kind = profile.kind,
        .install_source = source.name,
        .source_asset = source.source_asset,
        .distro = source.distro,
        .version = source.version,
        .arch = source.arch,
        .boot_bundle = bundle_name,
        .runtime_kernel = boot_bundle.runtime_kernel,
        .kernel_release = boot_bundle.kernel_release,
        .kernel = boot_bundle.kernel,
        .initrd = boot_bundle.initrd,
        .system = profile_system,
        .software = profile.software,
        .repository_revisions = repository_revisions,
        .rootfs_build_steps = rootfs_build_steps,
        .first_boot_fixed_steps = first_boot_fixed_steps,
    };
    return digestOf(allocator, profile_build);
}

fn findBundle(catalog: *const model.Catalog, name: ?[]const u8) ?*const model.ProvisioningBundle {
    const n = name orelse return null;
    for (catalog.provisioning_bundles) |*b| if (std.mem.eql(u8, b.name, n)) return b;
    return null;
}

fn phaseSteps(bundle: ?*const model.ProvisioningBundle, phase: model.ProvisionPhase) []const model.ProvisionStep {
    const b = bundle orelse return &.{};
    var start: usize = 0;
    var len: usize = 0;
    var begun = false;
    for (b.steps, 0..) |step, i| {
        if (step.phase == phase) {
            if (!begun) {
                start = i;
                begun = true;
            }
            len += 1;
        }
    }
    return b.steps[start .. start + len];
}

fn resolveRepositoryRevisions(allocator: std.mem.Allocator, catalog: *const model.Catalog, software: *const model.SoftwareSelection) ![]const RepositoryRevision {
    if (software.repositories.len == 0) return &.{};
    const out = try allocator.alloc(RepositoryRevision, software.repositories.len);
    errdefer allocator.free(out);
    for (software.repositories, 0..) |name, i| {
        const rev: ?[]const u8 = if (catalog_lookup.findRepository(catalog, name)) |repo| repo.software_index.revision_digest else null;
        out[i] = .{ .name = name, .revision_digest = rev };
    }
    return out;
}

fn digestOf(allocator: std.mem.Allocator, value: anytype) !Digest {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    return sha256Hex(json);
}

fn digestOfPair(allocator: std.mem.Allocator, boot: NodeBootProjection, apply: NodeApplyProjection) !Digest {
    const Pair = struct { boot: NodeBootProjection, apply: NodeApplyProjection };
    const json = try std.json.Stringify.valueAlloc(allocator, Pair{ .boot = boot, .apply = apply }, .{});
    defer allocator.free(json);
    return sha256Hex(json);
}

fn sha256Hex(bytes: []const u8) Digest {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    var out: Digest = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{raw}) catch unreachable;
    return out;
}

test "rootfs input digest is shared across nodes; desired digest is per-node" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1", .http_port = 18080 } };
    const source: model.InstallSourceConfig = .{ .name = "s", .distro = "rocky", .version = "9", .arch = .aarch64, .source_asset = "iso", .installer_kernel = "k", .installer_initrd = "i" };
    const bundle = model.BootBundleConfig{ .name = "bb", .distro = "rocky", .version = "9", .arch = .aarch64, .kernel_release = "5.14.0", .kernel = "k", .initrd = "i", .rootfs = "r" };
    const profile: model.ProfileConfig = .{ .name = "p", .install_source = "s", .kind = .diskless, .boot_bundle = "bb" };
    const nodes = [_]model.NodeConfig{
        .{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "p" },
        .{ .id = "n2", .mac = "02:00:00:00:00:02", .arch = .aarch64, .profile = "p" },
    };
    const catalog: model.Catalog = .{ .profiles = &.{profile}, .nodes = &nodes, .install_sources = &.{source}, .boot_bundles = &.{bundle} };
    var p1 = try compile(std.testing.allocator, &config, &catalog, &nodes[0]);
    defer p1.deinit();
    var p2 = try compile(std.testing.allocator, &config, &catalog, &nodes[1]);
    defer p2.deinit();
    try std.testing.expectEqualSlices(u8, &p1.rootfs_input_digest, &p2.rootfs_input_digest);
    try std.testing.expect(!std.mem.eql(u8, &p1.desired_plan_digest, &p2.desired_plan_digest));
}

test "node override changes desired digest but not rootfs input digest" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1", .http_port = 18080 } };
    const source: model.InstallSourceConfig = .{ .name = "s", .distro = "rocky", .version = "9", .arch = .aarch64, .source_asset = "iso", .installer_kernel = "k", .installer_initrd = "i" };
    const bundle = model.BootBundleConfig{ .name = "bb", .distro = "rocky", .version = "9", .arch = .aarch64, .kernel_release = "5.14.0", .kernel = "k", .initrd = "i", .rootfs = "r" };
    // 使用具名数组，使后续对 Profile 基线的修改对 catalog 可见（`&.{profile}` 会拷贝）。
    var profiles = [_]model.ProfileConfig{.{ .name = "p", .install_source = "s", .kind = .diskless, .boot_bundle = "bb", .software = .{ .packages = .{ .include = &.{"vim"} } } }};
    var nodes = [_]model.NodeConfig{.{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "p" }};
    const catalog: model.Catalog = .{ .profiles = &profiles, .nodes = &nodes, .install_sources = &.{source}, .boot_bundles = &.{bundle} };
    var baseline = try compile(std.testing.allocator, &config, &catalog, &nodes[0]);
    defer baseline.deinit();
    const rootfs_before = baseline.rootfs_input_digest;
    // Node-only change: hostname + software delta. Must NOT change rootfs input digest.
    nodes[0].hostname = "node-a";
    nodes[0].overrides.software.packages_include = .{ .add = &.{"curl"} };
    var after = try compile(std.testing.allocator, &config, &catalog, &nodes[0]);
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, &rootfs_before, &after.rootfs_input_digest);
    try std.testing.expect(!std.mem.eql(u8, &baseline.desired_plan_digest, &after.desired_plan_digest));
    // Profile-fixed change: software baseline. Must change rootfs input digest.
    profiles[0].software.packages.include = &.{ "vim", "tmux" };
    var rebuilt = try compile(std.testing.allocator, &config, &catalog, &nodes[0]);
    defer rebuilt.deinit();
    try std.testing.expect(!std.mem.eql(u8, &rootfs_before, &rebuilt.rootfs_input_digest));
}

test "non-diskless profile is rejected" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1", .http_port = 18080 } };
    const source: model.InstallSourceConfig = .{ .name = "s", .distro = "rocky", .version = "9", .arch = .aarch64, .source_asset = "iso", .installer_kernel = "k", .installer_initrd = "i" };
    const profile: model.ProfileConfig = .{ .name = "p", .install_source = "s" };
    const nodes = [_]model.NodeConfig{.{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "p" }};
    const catalog: model.Catalog = .{ .profiles = &.{profile}, .nodes = &nodes, .install_sources = &.{source} };
    try std.testing.expectError(error.ProfileNotDiskless, compile(std.testing.allocator, &config, &catalog, &nodes[0]));
}

test "rootfsInputDigest matches compile without a node" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1", .http_port = 18080 } };
    const source: model.InstallSourceConfig = .{ .name = "s", .distro = "rocky", .version = "9", .arch = .aarch64, .source_asset = "iso", .installer_kernel = "k", .installer_initrd = "i" };
    const bundle = model.BootBundleConfig{ .name = "bb", .distro = "rocky", .version = "9", .arch = .aarch64, .kernel_release = "5.14.0", .kernel = "k", .initrd = "i", .rootfs = "r" };
    const profile: model.ProfileConfig = .{ .name = "p", .install_source = "s", .kind = .diskless, .boot_bundle = "bb" };
    const nodes = [_]model.NodeConfig{.{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "p" }};
    const catalog: model.Catalog = .{ .profiles = &.{profile}, .nodes = &nodes, .install_sources = &.{source}, .boot_bundles = &.{bundle} };
    const direct = try rootfsInputDigest(std.testing.allocator, &config, &catalog, &profile);
    var plan = try compile(std.testing.allocator, &config, &catalog, &nodes[0]);
    defer plan.deinit();
    try std.testing.expectEqualSlices(u8, &direct, &plan.rootfs_input_digest);
}
