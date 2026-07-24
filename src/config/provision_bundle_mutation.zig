//! # Provisioning bundle catalog mutations
//!
//! 提供 provisioning bundle 和 step 的增删改查事务入口。
//! 每个 mutation 执行 load-patch-validate-save 事务。
const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const validate = @import("validate.zig");

/// Step 操作类型。
pub const Operation = enum {
    /// 追加新 step。
    add,
    /// 修改已有 step。
    set,
    /// 删除 step。
    remove,
    /// 重排序 step。
    move,
};
/// 单个 step patch 参数。
pub const Patch = struct {
    /// 操作类型。
    operation: Operation,
    /// step 名称（identity）。
    identity: []const u8,
    /// move 操作时插入到此 step 之前。
    before: ?[]const u8 = null,
    /// move 操作时插入到此 step 之后。
    after: ?[]const u8 = null,
    /// set 操作时清除的字段列表。
    unset: []const []const u8 = &.{},
    /// step 名称。
    name: ?[]const u8 = null,
    /// step 动作类型（`repository`/`standard_packages`/`managed_file`）。
    action: ?[]const u8 = null,
    /// 执行阶段：install-post/rootfs-build/first-boot。
    phase: ?[]const u8 = null,
    idempotency_key: ?[]const u8 = null,
    timeout_s: ?u32 = null,
    retryable: ?bool = null,
    packages: ?[]const []const u8 = null,
    /// `managed_file` 目标路径。
    destination: ?[]const u8 = null,
    /// `managed_file` 内容资产引用。
    content_asset: ?[]const u8 = null,
    /// `managed_file` 权限模式。
    mode: ?u16 = null,
    /// `managed_file` 属主。
    owner: ?[]const u8 = null,
    /// `managed_file` 属组。
    group: ?[]const u8 = null,
};
/// `managed_file` step 创建输入。
pub const StepInput = struct {
    /// step 名称。
    name: []const u8,
    /// 动作类型固定为 `managed_file`。
    action: enum { @"managed-file" } = .@"managed-file",
    /// 目标文件绝对路径。
    destination: []const u8,
    /// 内容资产引用。
    content_asset: []const u8,
    /// 权限模式。默认 `0644`。
    mode: u16 = 0o644,
    /// 属主。默认 `root`。
    owner: []const u8 = "root",
    /// 属组。默认 `root`。
    group: []const u8 = "root",
    /// 转换为 `model.ProvisionStep`。
    pub fn modelValue(self: StepInput) model.ProvisionStep { return .{ .name = self.name, .action = .managed_file, .destination = self.destination, .content_asset = self.content_asset, .mode = self.mode, .owner = self.owner, .group = self.group }; }
};

/// 创建空 provisioning bundle。重复名称返回错误。
pub fn create(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, path: []const u8, name: []const u8) !void {
    var parsed = try catalog_store.load(io, allocator, path); defer parsed.deinit();
    for (parsed.value.provisioning_bundles) |bundle| if (std.mem.eql(u8, bundle.name, name)) return error.BundleAlreadyExists;
    const bundles = try allocator.alloc(model.ProvisioningBundle, parsed.value.provisioning_bundles.len + 1); defer allocator.free(bundles);
    @memcpy(bundles[0..parsed.value.provisioning_bundles.len], parsed.value.provisioning_bundles);
    bundles[bundles.len - 1] = .{ .name = name };
    var candidate = parsed.value; candidate.provisioning_bundles = bundles;
    try validateCandidate(config, &candidate); try catalog_store.save(io, allocator, path, &candidate);
}

pub fn remove(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, path: []const u8, name: []const u8) !void {
    var parsed = try catalog_store.load(io, allocator, path); defer parsed.deinit();
    var index: ?usize = null;
    for (parsed.value.provisioning_bundles, 0..) |bundle, current| {
        if (std.mem.eql(u8, bundle.name, name)) index = current;
    }
    const found = index orelse return error.BundleNotFound;
    for (parsed.value.profiles) |profile| if (profile.install.post_install.bundle) |reference| if (std.mem.eql(u8, reference, name)) return error.BundleInUse;
    const bundles = try allocator.alloc(model.ProvisioningBundle, parsed.value.provisioning_bundles.len - 1); defer allocator.free(bundles);
    @memcpy(bundles[0..found], parsed.value.provisioning_bundles[0..found]);
    @memcpy(bundles[found..], parsed.value.provisioning_bundles[found + 1 ..]);
    var candidate = parsed.value; candidate.provisioning_bundles = bundles;
    try validateCandidate(config, &candidate); try catalog_store.save(io, allocator, path, &candidate);
}

pub fn mutate(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, path: []const u8, name: []const u8, patch: Patch) !void {
    var parsed = try catalog_store.load(io, allocator, path); defer parsed.deinit();
    const bundles = try allocator.dupe(model.ProvisioningBundle, parsed.value.provisioning_bundles); defer allocator.free(bundles);
    var selected: ?*model.ProvisioningBundle = null;
    for (bundles) |*bundle| if (std.mem.eql(u8, bundle.name, name)) { selected = bundle; break; };
    const bundle = selected orelse return error.BundleNotFound;
    const steps = try mutateSteps(allocator, bundle.steps, patch); defer allocator.free(steps);
    bundle.steps = steps; bundle.revision += 1;
    var candidate = parsed.value; candidate.provisioning_bundles = bundles;
    try validateCandidate(config, &candidate); try catalog_store.save(io, allocator, path, &candidate);
}

pub fn replace(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, path: []const u8, name: []const u8, steps: []const model.ProvisionStep) !void {
    var parsed = try catalog_store.load(io, allocator, path); defer parsed.deinit();
    const bundles = try allocator.dupe(model.ProvisioningBundle, parsed.value.provisioning_bundles); defer allocator.free(bundles);
    var selected: ?*model.ProvisioningBundle = null;
    for (bundles) |*bundle| if (std.mem.eql(u8, bundle.name, name)) { selected = bundle; break; };
    const bundle = selected orelse return error.BundleNotFound;
    bundle.steps = steps; bundle.revision += 1;
    var candidate = parsed.value; candidate.provisioning_bundles = bundles;
    try validateCandidate(config, &candidate); try catalog_store.save(io, allocator, path, &candidate);
}

fn validateCandidate(config: *const model.AppConfig, catalog: *const model.Catalog) !void {
    const projected = model.projectCatalog(config.*, catalog);
    try validate.validate(&projected, catalog);
}

fn mutateSteps(allocator: std.mem.Allocator, current: []const model.ProvisionStep, patch: Patch) ![]model.ProvisionStep {
    const found = stepIndex(current, patch.identity);
    return switch (patch.operation) {
        .add => blk: {
            if (found != null or patch.name == null or !std.mem.eql(u8, patch.name.?, patch.identity)) return error.InvalidStepIdentity;
            const action = try parseAction(patch.action orelse "managed-file");
            const values = try allocator.alloc(model.ProvisionStep, current.len + 1); @memcpy(values[0..current.len], current);
            values[current.len] = .{ .name = patch.name.?, .idempotency_key = patch.idempotency_key orelse patch.name.?, .timeout_s = patch.timeout_s orelse 300, .retryable = patch.retryable orelse false, .phase = try parsePhase(patch.phase orelse "install-post"), .action = action, .destination = patch.destination, .content_asset = patch.content_asset, .packages = patch.packages orelse &.{}, .mode = patch.mode orelse 0o644, .owner = patch.owner orelse "root", .group = patch.group orelse "root" };
            break :blk values;
        },
        .set => blk: {
            const index = found orelse return error.StepNotFound;
            const values = try allocator.dupe(model.ProvisionStep, current); var value = values[index];
            if (patch.action) |action| value.action = try parseAction(action);
            if (patch.phase) |phase| value.phase = try parsePhase(phase);
            if (patch.idempotency_key) |key| value.idempotency_key = key;
            if (patch.timeout_s) |seconds| value.timeout_s = seconds;
            if (patch.retryable) |enabled| value.retryable = enabled;
            if (patch.packages) |packages| value.packages = packages;
            if (patch.destination) |field| value.destination = field;
            if (patch.content_asset) |field| value.content_asset = field;
            if (patch.mode) |field| value.mode = field;
            if (patch.owner) |field| value.owner = field;
            if (patch.group) |field| value.group = field;
            for (patch.unset) |field| {
                if (std.mem.eql(u8, field, "mode")) value.mode = 0o644 else if (std.mem.eql(u8, field, "owner")) value.owner = "root" else if (std.mem.eql(u8, field, "group")) value.group = "root" else return error.RequiredStepField;
            }
            values[index] = value; break :blk values;
        },
        .remove => removeAt(allocator, current, found orelse return error.StepNotFound),
        .move => moveAt(allocator, current, found orelse return error.StepNotFound, try destinationIndex(current, patch)),
    };
}

fn parsePhase(value: []const u8) !model.ProvisionPhase {
    if (std.mem.eql(u8, value, "install-post")) return .install_post;
    if (std.mem.eql(u8, value, "rootfs-build")) return .rootfs_build;
    if (std.mem.eql(u8, value, "first-boot")) return .first_boot;
    return error.InvalidProvisionPhase;
}

fn parseAction(value: []const u8) !model.ProvisionAction {
    if (std.mem.eql(u8, value, "managed-file")) return .managed_file;
    if (std.mem.eql(u8, value, "archive")) return .archive;
    if (std.mem.eql(u8, value, "script")) return .script;
    if (std.mem.eql(u8, value, "package")) return .@"package";
    return error.InvalidStepAction;
}

fn stepIndex(values: []const model.ProvisionStep, identity: []const u8) ?usize { for (values, 0..) |value, index| if (std.mem.eql(u8, value.name, identity)) return index; return null; }
fn removeAt(allocator: std.mem.Allocator, values: []const model.ProvisionStep, index: usize) ![]model.ProvisionStep { const output = try allocator.alloc(model.ProvisionStep, values.len - 1); @memcpy(output[0..index], values[0..index]); @memcpy(output[index..], values[index + 1 ..]); return output; }
fn moveAt(allocator: std.mem.Allocator, current: []const model.ProvisionStep, from: usize, target: usize) ![]model.ProvisionStep { const values = try allocator.dupe(model.ProvisionStep, current); const value = values[from]; if (from < target) { std.mem.copyForwards(model.ProvisionStep, values[from..target], values[from + 1 .. target + 1]); values[target] = value; } else if (from > target) { std.mem.copyBackwards(model.ProvisionStep, values[target + 1 .. from + 1], values[target..from]); values[target] = value; } return values; }
fn destinationIndex(values: []const model.ProvisionStep, patch: Patch) !usize { if ((patch.before == null) == (patch.after == null)) return error.MoveDestinationRequired; if (patch.before) |id| return stepIndex(values, id) orelse error.StepNotFound; const index = stepIndex(values, patch.after.?) orelse return error.StepNotFound; return @min(index + 1, values.len - 1); }

test "managed-file step item mutation preserves stable identity and order" {
    const current = [_]model.ProvisionStep{ .{ .name = "a", .action = .managed_file }, .{ .name = "b", .action = .managed_file } };
    const moved = try mutateSteps(std.testing.allocator, &current, .{ .operation = .move, .identity = "a", .after = "b" }); defer std.testing.allocator.free(moved);
    try std.testing.expectEqualStrings("b", moved[0].name); try std.testing.expectEqualStrings("a", moved[1].name);
}
