//! Adapter-independent schema v3 storage compiler.
const std = @import("std");
const model = @import("../model.zig");

pub const Plan = struct {
    mode: model.StorageMode,
    wipe: bool,
    partition_table: model.PartitionTable,
    members: []const []const u8,
    partitions: []const model.PartitionConfig,
    bootloader_install: bool,

    pub fn deinit(self: Plan, allocator: std.mem.Allocator) void {
        allocator.free(self.members);
    }
};

pub fn compile(allocator: std.mem.Allocator, node: *const model.NodeConfig, profile: *const model.ProfileConfig) !Plan {
    const install = profile.install;
    var mode = install.storage.mode;
    var wipe = install.storage.wipe;
    var partition_table = install.storage.partition_table;
    var partitions = install.storage.partitions;
    var bootloader_install = install.bootloader.install;
    const override = node.overrides.install;
    if (override.storage.mode) |value| mode = value;
    if (override.storage.wipe) |value| wipe = value;
    if (override.storage.partition_table) |value| partition_table = value;
    if (override.storage.partitions) |value| partitions = value;
    if (override.bootloader.install) |value| bootloader_install = value;

    const members = try allocator.alloc([]const u8, 1 + node.storage.additional_disks.len);
    errdefer allocator.free(members);
    members[0] = node.storage.boot_disk;
    @memcpy(members[1..], node.storage.additional_disks);
    try validateMembers(mode, members);

    return .{
        .mode = mode,
        .wipe = wipe,
        .partition_table = partition_table,
        .members = members,
        .partitions = partitions,
        .bootloader_install = bootloader_install,
    };
}

pub fn validateMembers(mode: model.StorageMode, members: []const []const u8) !void {
    for (members, 0..) |disk, i| {
        if (!validWholeDiskPath(disk)) return error.InvalidDiskPath;
        for (members[0..i]) |previous| {
            if (std.mem.eql(u8, disk, previous)) return error.DuplicateDisk;
        }
    }
    const count = members.len;
    switch (mode) {
        .single, .lvm => if (count != 1) return error.InvalidStorageMemberCount,
        .raid0, .raid1, .@"raid0-lvm", .@"raid1-lvm" => if (count < 2) return error.InvalidStorageMemberCount,
        .raid5, .@"raid5-lvm" => if (count < 3) return error.InvalidStorageMemberCount,
        .raid6, .@"raid6-lvm" => if (count < 4) return error.InvalidStorageMemberCount,
        .raid10, .@"raid10-lvm" => if (count < 4 or count % 2 != 0) return error.InvalidStorageMemberCount,
    }
}

fn validWholeDiskPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/dev/") or path.len <= "/dev/".len) return false;
    if (std.mem.indexOf(u8, path[5..], "/") != null) return false;
    const name = path[5..];
    if (std.mem.startsWith(u8, name, "nvme") or std.mem.startsWith(u8, name, "mmcblk")) {
        if (std.mem.lastIndexOfScalar(u8, name, 'p')) |p| {
            if (p + 1 < name.len and std.ascii.isDigit(name[p + 1])) return false;
        }
        return true;
    }
    return !std.ascii.isDigit(name[name.len - 1]);
}

test "all storage modes enforce native member constraints" {
    const one = [_][]const u8{"/dev/sda"};
    const two = [_][]const u8{ "/dev/sda", "/dev/sdb" };
    const three = [_][]const u8{ "/dev/sda", "/dev/sdb", "/dev/sdc" };
    const four = [_][]const u8{ "/dev/sda", "/dev/sdb", "/dev/sdc", "/dev/sdd" };
    try validateMembers(.single, &one);
    try validateMembers(.lvm, &one);
    try validateMembers(.raid0, &two);
    try validateMembers(.raid1, &two);
    try validateMembers(.raid5, &three);
    try validateMembers(.raid6, &four);
    try validateMembers(.raid10, &four);
    try validateMembers(.@"raid0-lvm", &two);
    try validateMembers(.@"raid1-lvm", &two);
    try validateMembers(.@"raid5-lvm", &three);
    try validateMembers(.@"raid6-lvm", &four);
    try validateMembers(.@"raid10-lvm", &four);
    try std.testing.expectError(error.InvalidStorageMemberCount, validateMembers(.single, &two));
    try std.testing.expectError(error.InvalidStorageMemberCount, validateMembers(.raid10, &three));
    try std.testing.expectError(error.DuplicateDisk, validateMembers(.raid1, &.{ "/dev/sda", "/dev/sda" }));
    try std.testing.expectError(error.InvalidDiskPath, validateMembers(.single, &.{"/dev/nvme0n1p1"}));
}

test "compiler combines Node direct disks and policy override" {
    const profile: model.ProfileConfig = .{ .name = "p", .install_source = "s", .install = .{ .storage = .{ .mode = .raid1 } } };
    const node: model.NodeConfig = .{ .id = "n", .mac = "02:00:00:00:00:01", .arch = .x86_64, .profile = "p", .storage = .{ .boot_disk = "/dev/vda", .additional_disks = &.{"/dev/vdb"} }, .overrides = .{ .install = .{ .storage = .{ .mode = .@"raid1-lvm" } } } };
    const plan = try compile(std.testing.allocator, &node, &profile);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(model.StorageMode.@"raid1-lvm", plan.mode);
    try std.testing.expectEqualStrings("/dev/vda", plan.members[0]);
    try std.testing.expectEqualStrings("/dev/vdb", plan.members[1]);
}
