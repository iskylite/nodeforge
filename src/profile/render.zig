//! Shared, deliberately small rendering helpers for installer adapters.
const std = @import("std");
const model = @import("../model.zig");

pub fn hostname(node: *const model.NodeConfig) []const u8 {
    return node.hostname orelse node.id;
}

/// Installer password formats require a hash, while the MVP configuration
/// model deliberately stores the operator supplied value unchanged. SHA-512
/// crypt is intentionally delegated to the target installer: this deterministic
/// SHA-256 digest is only used where an adapter needs a non-cleartext field.
pub fn passwordDigest(buffer: *[64]u8, password: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(buffer[0..hex.len], &hex);
    return buffer[0..hex.len];
}

pub fn yamlQuote(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |c| {
        if (c == '\'') try writer.writeAll("''") else try writer.writeByte(c);
    }
    try writer.writeByte('\'');
}
