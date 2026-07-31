//! PXE profile 的受约束 catalog mutation。
//!
//! 本模块只提供已进入现行 CLI/HTTP 契约的窄写入口：
//! - 从已有 install source 创建安全默认 install profile；
//! - 规范化修改 `kernel_args`；
//! 每次写入都先投影完整 config+catalog 模型并校验，再由 catalog store
//! 原子发布；这里不实现 M6 规划中的通用 profile CRUD。
const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const config_load = @import("load.zig");
const validate = @import("validate.zig");
const naming = @import("../profile/naming.zig");
const scalar_mutation = @import("scalar_mutation.zig");

/// 从已有 install source 创建安全默认 profile。
///
/// 新 profile 使用与 ISO import 自动创建相同的默认安全基线（destructive=true,
/// persistent_writes=true, reinstall_policy=explicit）。CLI 不接收任意 safety/storage JSON，
/// 避免形成绕过模型校验的第二套创建语义。
///
/// v0.2.3 §5.1: `ssh_identity` 是调用方先在两阶段事务中创建的 identity 引用
/// （handler 持有 identity store 与 journal），本函数只把它固化到新 profile；
/// 绝不创建"有 Profile、无 identity"的半成品。
pub fn addInstallProfile(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, name: []const u8, install_source: []const u8, kind: model.ProfileKind, boot_bundle: ?[]const u8, ssh_identity: model.ProfileSshIdentityRef) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const now = std.Io.Clock.real.now(io).toSeconds();
    for (parsed.value.profiles) |profile| if (std.mem.eql(u8, profile.name, name)) return error.ProfileAlreadyExists;
    var source: ?model.InstallSourceConfig = null;
    for (parsed.value.install_sources) |candidate| if (std.mem.eql(u8, candidate.name, install_source)) {
        source = candidate;
        break;
    };
    const selected = source orelse return error.InstallSourceNotFound;
    // 名称必须保留 ISO import 生成的完整 InstallSource 身份；不能接受仅由
    // distro/version 拼出的短名，否则补丁版本、架构和介质 variant 会丢失。
    if (!naming.profileIsCanonical(name, selected.name, kind)) return error.NonCanonicalProfileName;
    if (kind == .diskless) {
        if (boot_bundle == null) return error.DisklessBootBundleRequired;
        if (!naming.bootBundleIsCanonical(boot_bundle.?, selected.name)) return error.NonCanonicalBootBundleName;
    }
    const profiles = try allocator.alloc(model.ProfileConfig, parsed.value.profiles.len + 1);
    defer allocator.free(profiles);
    @memcpy(profiles[0..parsed.value.profiles.len], parsed.value.profiles);
    // 与 ISO import 自动创建的默认 profile 使用同一安全基线。CLI 不接收
    // 任意 safety/storage JSON，避免形成绕过模型校验的第二套创建语义。
    var system: model.TargetSystemConfig = .{};
    system.hosts_content = readHostHosts(io, allocator) catch null;
    profiles[parsed.value.profiles.len] = .{
        .name = name,
        .install_source = selected.name,
        .kind = kind,
        .boot_bundle = boot_bundle,
        .system = system,
        // v0.2.3 §5.1: create 语义直接初始化 revision=1 与时间戳，不经过
        // mutateProfileMetadata（create 不是对既有 profile 的 mutation）。
        .revision = 1,
        .created_at = now,
        .updated_at = now,
        .ssh_identity = ssh_identity,
        .provenance = .{
            .origin = .create,
            .install_source_name = selected.name,
            .install_source_revision = parsed.value.revision,
        },
    };
    var candidate = parsed.value;
    candidate.profiles = profiles;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

pub fn readHostHosts(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, "/etc/hosts", .{ .follow_symlinks = true });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == 0 or stat.size > 64 * 1024) return error.InvalidHostsFile;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(bytes);
    const read = try file.readPositionalAll(io, bytes, 0);
    if (read != bytes.len) return error.InvalidHostsFile;
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidHostsFile;
    if (std.mem.indexOf(u8, bytes, "NODEFORGE_HOSTS_EOF") != null) return error.InvalidHostsFile;
    return bytes;
}

/// 删除一个未被 Node 引用的 Profile。
///
/// 删除前先检查全部 Node 的绑定关系；任何引用都会返回 `ProfileInUse`，避免
/// 产生悬空 Profile 引用。候选 catalog 会经过完整模型校验，再由 manifest-last
/// store 原子发布，因此失败不会暴露半写入 generation。
pub fn removeProfile(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, name: []const u8) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    for (parsed.value.nodes) |node| if (node.profile) |profile_name| if (std.mem.eql(u8, profile_name, name)) return error.ProfileInUse;
    var target: ?usize = null;
    for (parsed.value.profiles, 0..) |profile, index| if (std.mem.eql(u8, profile.name, name)) {
        target = index;
        break;
    };
    const remove = target orelse return error.ProfileNotFound;
    const profiles = try allocator.alloc(model.ProfileConfig, parsed.value.profiles.len - 1);
    defer allocator.free(profiles);
    var write: usize = 0;
    for (parsed.value.profiles, 0..) |profile, index| if (index != remove) {
        profiles[write] = profile;
        write += 1;
    };
    var candidate = parsed.value;
    candidate.profiles = profiles;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

/// 原子克隆一个 Profile 的完整 desired 配置。
///
/// Profile 不包含 runtime/session/operation，因此只复制 catalog-owned desired
/// shape。目标名称必须是 canonical logical id 且不存在；source 与 target 在同一
/// catalog generation 中完成查找、校验和发布，不暴露半克隆状态。
///
/// v0.2.3 §5.2: `ssh_identity_override` 为 null 时复用 source 的 identity 引用；
/// 非 null（`--new-ssh-keys` 新建的 identity）时替换为新引用。provenance 记录
/// `cloned_from` 直接 source。`properties` 与 clone 在同一 catalog 事务中校验
/// 并应用（范围与 `profile set` 相同，由 handler 预先按 PropertySpec 过滤；
/// 不允许 patch `provenance`/`revision`/`ssh_identity`）。
pub fn cloneProfile(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, source_name: []const u8, target_name: []const u8, ssh_identity_override: ?model.ProfileSshIdentityRef, properties: []const scalar_mutation.Mutation) !void {
    if (!validate.validLogicalId(target_name)) return error.InvalidProfileName;
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    var source: ?model.ProfileConfig = null;
    for (parsed.value.profiles) |profile| {
        if (std.mem.eql(u8, profile.name, target_name)) return error.ProfileAlreadyExists;
        if (std.mem.eql(u8, profile.name, source_name)) source = profile;
    }
    var cloned = source orelse return error.ProfileNotFound;
    cloned.name = target_name;
    if (ssh_identity_override) |identity| cloned.ssh_identity = identity;
    // §5.2: property patch 先于 provenance/时间戳应用，patch 对 install_source
    // 的改写会反映到 `cloned_from` 外的 provenance 字段；patch 与 clone 在同一
    // 事务中提交，任一校验失败整体回滚。
    for (properties) |mutation| try scalar_mutation.applyProfile(&parsed.value, &cloned, mutation.key, mutation.value);
    // v0.2.3 §5.2: clone target 的 revision 始终从 1 开始（不继承 source 的
    // revision/provenance/时间戳），provenance 记录直接 source。
    const now = std.Io.Clock.real.now(io).toSeconds();
    const clone_catalog_revision = std.math.add(u64, parsed.value.revision, 1) catch return error.CatalogRevisionOverflow;
    cloned.revision = 1;
    cloned.created_at = now;
    cloned.updated_at = now;
    cloned.provenance = .{
        .origin = .clone,
        .install_source_name = cloned.install_source,
        .install_source_revision = parsed.value.revision,
        .cloned_from = .{
            .profile_name = source_name,
            .profile_revision = source.?.revision,
            .catalog_revision = clone_catalog_revision,
            .cloned_at = now,
        },
    };
    const profiles = try allocator.alloc(model.ProfileConfig, parsed.value.profiles.len + 1);
    defer allocator.free(profiles);
    @memcpy(profiles[0..parsed.value.profiles.len], parsed.value.profiles);
    profiles[parsed.value.profiles.len] = cloned;
    var candidate = parsed.value;
    candidate.profiles = profiles;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

/// 修改已有 profile 的 kernel_args 字段。
///
/// 执行 load-find-canonicalize-validate-save 事务。
/// canonicalize 在写入前折叠空格并消除空字符串为 null。
pub fn setKernelArgs(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, profile_name: []const u8, kernel_args: ?[]const u8) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const profiles = try allocator.dupe(model.ProfileConfig, parsed.value.profiles);
    defer allocator.free(profiles);
    // `canonicalizeKernelArgs` 会在候选投影上就地折叠空格（@constCast 写回），
    // 因此必须持有可写副本，不能把调用方的 const 输入（可能位于只读段）直接
    // 挂到 profile 上。
    var owned_args: ?[]u8 = null;
    defer if (owned_args) |args| allocator.free(args);
    var found = false;
    for (profiles) |*profile| if (std.mem.eql(u8, profile.name, profile_name)) {
        if (kernel_args) |text| {
            owned_args = try allocator.dupe(u8, text);
            profile.kernel_args = owned_args.?;
        } else {
            profile.kernel_args = null;
        }
        found = true;
        break;
    };
    if (!found) return error.ProfileNotFound;
    var candidate = parsed.value;
    candidate.profiles = profiles;
    var projected = model.projectCatalog(config.*, &candidate);
    config_load.canonicalizeKernelArgs(&projected);
    candidate.profiles = projected.profiles;
    try validate.validate(&projected, &candidate);
    try mutateProfileMetadata(profiles, profile_name, std.Io.Clock.real.now(io).toSeconds());
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

/// v0.2.3 §3.3: `profile rootfs build --new-ssh-keys` 的 Profile 发布步。
/// 把 `ssh_identity` 替换为调用方先在两阶段事务中创建的新 identity 引用，
/// 并经过 `mutateProfileMetadata` 递增 revision / 更新 updated_at。
/// identity 与 catalog 的原子性由调用方（handler 持有 identity store + journal）
/// 保证；本函数只做 catalog 侧发布。
pub fn rotateSshIdentity(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, profile_name: []const u8, ssh_identity: model.ProfileSshIdentityRef) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const profiles = try allocator.dupe(model.ProfileConfig, parsed.value.profiles);
    defer allocator.free(profiles);
    var found = false;
    for (profiles) |*profile| if (std.mem.eql(u8, profile.name, profile_name)) {
        profile.ssh_identity = ssh_identity;
        found = true;
        break;
    };
    if (!found) return error.ProfileNotFound;
    var candidate = parsed.value;
    candidate.profiles = profiles;
    const projected = model.projectCatalog(config.*, &candidate);
    try validate.validate(&projected, &candidate);
    try mutateProfileMetadata(profiles, profile_name, std.Io.Clock.real.now(io).toSeconds());
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

/// v0.2.3 §5.4: Profile revision 的统一 mutation 入口。在候选 catalog 校验
/// 通过、持久化提交前执行：`revision = revision + 1`（溢出时事务失败）、
/// `updated_at = now`；`created_at`、`provenance` 保持不变，除非操作本身是
/// create/clone。所有 Profile mutation 入口必须经过该 helper，禁止 handler
/// 各自递增；失败或 no-op 不递增（profile 不存在时返回 `ProfileNotFound`）。
pub fn mutateProfileMetadata(profiles: []model.ProfileConfig, profile_name: []const u8, now: i64) !void {
    for (profiles) |*profile| {
        if (!std.mem.eql(u8, profile.name, profile_name)) continue;
        profile.revision = std.math.add(u64, profile.revision, 1) catch return error.ProfileRevisionOverflow;
        profile.updated_at = now;
        return;
    }
    return error.ProfileNotFound;
}

test "mutateProfileMetadata bumps revision exactly once and no-ops on missing profile" {
    var profiles = [_]model.ProfileConfig{.{ .name = "p1", .install_source = "s", .revision = 3, .created_at = 100, .updated_at = 100 }};
    try mutateProfileMetadata(&profiles, "p1", 200);
    try std.testing.expectEqual(@as(u64, 4), profiles[0].revision);
    try std.testing.expectEqual(@as(i64, 200), profiles[0].updated_at);
    // created_at / provenance 不被普通 mutation 触碰。
    try std.testing.expectEqual(@as(i64, 100), profiles[0].created_at);
    // 失败/no-op 不递增。
    try std.testing.expectError(error.ProfileNotFound, mutateProfileMetadata(&profiles, "missing", 300));
    try std.testing.expectEqual(@as(u64, 4), profiles[0].revision);
    // 溢出时事务失败、不递增。
    profiles[0].revision = std.math.maxInt(u64);
    try std.testing.expectError(error.ProfileRevisionOverflow, mutateProfileMetadata(&profiles, "p1", 400));
}

test "profile kernel args mutation canonicalizes projected catalog data" {
    var args = [_]u8{ ' ', 'i', 'o', 'm', 'm', 'u', '=', 'p', 't', ' ', ' ', 'i', 's', 'o', 'l', 'c', 'p', 'u', 's', '=', '0', ',', '2', ' ' };
    var profiles = [_]model.ProfileConfig{.{ .name = "install", .install_source = "source", .kernel_args = &args }};
    var catalog: model.Catalog = .{ .profiles = &profiles };
    var projected = model.projectCatalog(.{ .server = .{ .server_ip = "192.0.2.1" } }, &catalog);
    config_load.canonicalizeKernelArgs(&projected);
    try std.testing.expectEqualStrings("iommu=pt isolcpus=0,2", profiles[0].kernel_args.?);
}
