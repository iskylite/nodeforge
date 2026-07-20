//! Canonical CLI mutation vocabulary.
//!
//! Help, list/show navigation, parsers and contract tests must consume these
//! names instead of maintaining independent allowlists.

const std = @import("std");

pub const node_set_keys = "mac, arch, profile, ip, hostname, deploy, http_accel, boot_disk, install_disks";
pub const node_unset_keys = "ip, hostname, boot_disk, install_disks";
pub const profile_set_keys = "kernel_args, boot_disk";
pub const profile_unset_keys = "kernel_args";

pub const NodeKey = enum(u4) {
    mac,
    arch,
    profile,
    ip,
    hostname,
    deploy,
    http_accel,
    boot_disk,
    install_disks,

    pub fn parse(value: []const u8) ?NodeKey {
        return std.meta.stringToEnum(NodeKey, value);
    }

    pub fn mask(self: NodeKey) u16 {
        return @as(u16, 1) << @intFromEnum(self);
    }

    pub fn optional(self: NodeKey) bool {
        return switch (self) {
            .ip, .hostname, .boot_disk, .install_disks => true,
            else => false,
        };
    }
};

test "node mutation vocabulary has stable masks and optional boundary" {
    try std.testing.expectEqual(NodeKey.boot_disk, NodeKey.parse("boot_disk").?);
    try std.testing.expect(NodeKey.install_disks.optional());
    try std.testing.expect(!NodeKey.profile.optional());
    try std.testing.expectEqual(@as(u16, 256), NodeKey.install_disks.mask());
    try std.testing.expect(NodeKey.parse("effective_storage") == null);
}
