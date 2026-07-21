//! 适配器无关的 M4.1 安装计划规范化。
const std = @import("std");
const model = @import("../model.zig");

/// 解析单周期 M4 兼容字段，不允许歧义合并。
/// 渲染器只接收返回的共享 system 模型。
pub fn effectiveSystem(profile: *const model.ProfileConfig) !model.TargetSystemConfig {
    return profile.system;
}

/// Resolve the install plan for one node. The caller-owned one-element buffer
/// backs the derived single-disk list when only boot_disk is overridden.
pub fn effectiveInstall(node: *const model.NodeConfig, profile: *const model.ProfileConfig, single_disk: *[1][]const u8) !model.InstallConfig {
    const policy_install = profile.install;
    var install: model.InstallConfig = .{
        .storage = .{ .wipe = policy_install.storage.wipe, .mode = policy_install.storage.mode, .partition_table = policy_install.storage.partition_table, .partitions = policy_install.storage.partitions },
        .bootloader = policy_install.bootloader,
        .apt = policy_install.apt,
        .reinstall_policy = policy_install.reinstall_policy,
        .completion = policy_install.completion,
        .updates = policy_install.updates,
        .proxy = policy_install.proxy,
        .post_install = policy_install.post_install,
        .packages = policy_install.packages,
        .users = policy_install.users,
        .ssh_authorized_keys = policy_install.ssh_authorized_keys,
        .bundle = policy_install.bundle,
    };
    // Schema v3 physical devices are always Node-owned. The caller scratch keeps
    // the default one-disk member list allocation-free for existing consumers.
    install.storage.boot_disk = node.storage.boot_disk;
    if (node.storage.additional_disks.len == 0) {
        single_disk[0] = node.storage.boot_disk;
        install.storage.members = single_disk;
    }

    const policy = node.overrides.install;
    if (policy.storage.mode) |value| install.storage.mode = value;
    if (policy.storage.wipe) |value| install.storage.wipe = value;
    if (policy.storage.partition_table) |value| install.storage.partition_table = value;
    if (policy.storage.partitions) |value| install.storage.partitions = value;
    if (policy.bootloader.install) |value| install.bootloader.install = value;
    if (policy.apt_fallback) |value| install.apt.fallback = value;
    if (policy.reinstall_policy) |value| install.reinstall_policy = value;
    if (policy.completion_action) |value| install.completion.action = value;
    if (policy.updates_mode) |value| install.updates.mode = value;
    if (policy.proxy_url) |value| install.proxy.url = value;
    if (policy.post_install_bundle) |value| install.post_install.bundle = value;

    return install;
}

test "M4.2 implicit users default" {
    const base: model.ProfileConfig = .{ .name = "rocky", .install_source = "rocky" };
    const default_system = try effectiveSystem(&base);
    try std.testing.expectEqual(@as(usize, 1), default_system.users.len);
    try std.testing.expectEqualStrings("nodeforge", default_system.users[0].name);

}

pub fn planDigest(allocator: std.mem.Allocator, node: *const model.NodeConfig, profile: *const model.ProfileConfig, source: *const model.InstallSourceConfig) !u64 {
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    var single_disk: [1][]const u8 = undefined;
    const install = try effectiveInstall(node, profile, &single_disk);
    try std.json.Stringify.value(.{ .node = node.*, .profile = profile.*, .effective_install = install, .source = source.* }, .{}, &json.writer);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json.written(), &digest, .{});
    const value = std.mem.readInt(u64, digest[0..8], .big);
    return if (value == 0) 1 else value;
}

test "M4.6 kernel args participate in immutable install plan digest" {
    const node: model.NodeConfig = .{ .id = "node-01", .mac = "00:11:22:33:44:55", .arch = .aarch64, .profile = "rocky" };
    const source: model.InstallSourceConfig = .{ .name = "rocky", .distro = "rocky", .version = "9.7", .arch = .aarch64, .source_asset = "iso", .installer_kernel = "kernel", .installer_initrd = "initrd" };
    var profile: model.ProfileConfig = .{ .name = "rocky", .install_source = "rocky" };
    const without = try planDigest(std.testing.allocator, &node, &profile, &source);
    profile.kernel_args = "iommu=pt";
    const with = try planDigest(std.testing.allocator, &node, &profile, &source);
    try std.testing.expect(without != with);
}

test "node storage owns effective boot disk" {
    const profile: model.ProfileConfig = .{ .name = "rocky", .install_source = "rocky" };
    const node: model.NodeConfig = .{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "rocky", .storage = .{ .boot_disk = "/dev/nvme0n1" } };
    var scratch: [1][]const u8 = undefined;
    const install = try effectiveInstall(&node, &profile, &scratch);
    try std.testing.expectEqualStrings("/dev/nvme0n1", install.storage.boot_disk);
    try std.testing.expectEqualStrings("/dev/nvme0n1", install.storage.members[0]);
}

test "every install policy override clears back to profile inheritance" {
    const profile: model.ProfileConfig = .{
        .name = "ubuntu",
        .install_source = "ubuntu",
        .install = .{
            .storage = .{ .wipe = false, .mode = .lvm, .partition_table = .gpt },
            .bootloader = .{ .install = false },
            .apt = .{ .fallback = .abort },
            .reinstall_policy = .always,
            .completion = .{ .action = .halt },
            .updates = .{ .mode = .security },
            .proxy = .{ .url = "http://profile-proxy.invalid:3128", .no_proxy = &.{"profile.invalid"} },
            .post_install = .{ .bundle = "profile-bundle" },
        },
    };
    var node: model.NodeConfig = .{
        .id = "n1",
        .mac = "02:00:00:00:00:01",
        .arch = .aarch64,
        .profile = "ubuntu",
        .overrides = .{ .install = .{
            .storage = .{ .wipe = true, .mode = .single, .partition_table = .mbr, .partitions = &.{} },
            .bootloader = .{ .install = true },
            .apt_fallback = .@"continue-anyway",
            .reinstall_policy = .explicit,
            .completion_action = .poweroff,
            .updates_mode = .all,
            .proxy_url = "http://node-proxy.invalid:3128",
            .post_install_bundle = "node-bundle",
        } },
    };
    var scratch: [1][]const u8 = undefined;
    const overridden = try effectiveInstall(&node, &profile, &scratch);
    try std.testing.expect(overridden.storage.wipe);
    try std.testing.expectEqual(model.StorageMode.single, overridden.storage.mode);
    try std.testing.expectEqual(model.PartitionTable.mbr, overridden.storage.partition_table);
    try std.testing.expect(overridden.bootloader.install);
    try std.testing.expectEqual(model.AptFallback.@"continue-anyway", overridden.apt.fallback);
    try std.testing.expectEqual(model.ReinstallPolicy.explicit, overridden.reinstall_policy);
    try std.testing.expectEqual(model.CompletionAction.poweroff, overridden.completion.action);
    try std.testing.expectEqual(model.UpdateMode.all, overridden.updates.mode);
    try std.testing.expectEqualStrings("http://node-proxy.invalid:3128", overridden.proxy.url.?);
    try std.testing.expectEqualStrings("node-bundle", overridden.post_install.bundle.?);

    node.overrides.install = .{};
    const inherited = try effectiveInstall(&node, &profile, &scratch);
    try std.testing.expect(!inherited.storage.wipe);
    try std.testing.expectEqual(model.StorageMode.lvm, inherited.storage.mode);
    try std.testing.expectEqual(model.PartitionTable.gpt, inherited.storage.partition_table);
    try std.testing.expect(!inherited.bootloader.install);
    try std.testing.expectEqual(model.AptFallback.abort, inherited.apt.fallback);
    try std.testing.expectEqual(model.ReinstallPolicy.always, inherited.reinstall_policy);
    try std.testing.expectEqual(model.CompletionAction.halt, inherited.completion.action);
    try std.testing.expectEqual(model.UpdateMode.security, inherited.updates.mode);
    try std.testing.expectEqualStrings("http://profile-proxy.invalid:3128", inherited.proxy.url.?);
    try std.testing.expectEqualStrings("profile-bundle", inherited.post_install.bundle.?);
}

test "kickstart consumes the effective node storage override" {
    const kickstart = @import("adapter/kickstart.zig");
    const profile: model.ProfileConfig = .{ .name = "rocky", .install_source = "rocky" };
    const node: model.NodeConfig = .{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "rocky", .storage = .{ .boot_disk = "/dev/nvme0n1" } };
    var scratch: [1][]const u8 = undefined;
    const install = try effectiveInstall(&node, &profile, &scratch);
    const answer = try kickstart.renderAnswer(std.testing.allocator, &node, install, "http://repo", null, "http://event", "0123456789abcdef0123456789abcdef", "token");
    defer std.testing.allocator.free(answer);
    try std.testing.expect(std.mem.indexOf(u8, answer, "clearpart --all --initlabel --drives=nvme0n1") != null);
    try std.testing.expect(std.mem.indexOf(u8, answer, "--drives=sda") == null);
}
