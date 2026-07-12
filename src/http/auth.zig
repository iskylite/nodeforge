//! M3 proof normalization.  Route handlers receive this one server-derived
//! value and must not reinterpret node ids, peer addresses or bearer headers.

const std = @import("std");
const boot_session = @import("../state/boot_session.zig");
const contracts = @import("contracts.zig");

pub const Proof = enum { bootstrap, capability };

pub const Result = struct {
    proof: Proof,
    session: boot_session.Authenticated,
};

pub fn parsePeerIpv4(value: []const u8) !u32 {
    // facil.io normally supplies a bare IPv4 literal.  Accept an optional
    // port suffix too, while still rejecting IPv6 and non-address labels.
    const literal = if (std.mem.lastIndexOfScalar(u8, value, ':')) |index| value[0..index] else value;
    const address = std.Io.net.IpAddress.parseIp4(literal, 0) catch return error.InvalidPeerAddress;
    return switch (address) {
        .ip4 => |ip| std.mem.readInt(u32, &ip.bytes, .big),
        else => error.InvalidPeerAddress,
    };
}

pub fn nodeIdSafe(value: []const u8) bool {
    if (value.len == 0 or value.len > 96) return false;
    for (value) |byte| if (!((byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '_')) return false;
    return true;
}

pub fn bearer(value: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    const token = value[prefix.len..];
    if (token.len != boot_session.capability_len) return null;
    for (token) |byte| if (!std.ascii.isHex(byte)) return null;
    return token;
}

pub fn authenticate(store: *boot_session.Store, node_id: []const u8, peer: []const u8, authorization: ?[]const u8, session_header: ?[]const u8, mono_now: i64) !Result {
    if (!nodeIdSafe(node_id)) return error.InvalidNodeId;
    if (authorization != null or session_header != null) {
        const token = bearer(authorization orelse return error.MissingProof) orelse return error.MissingProof;
        const session_id = session_header orelse return error.MissingProof;
        return .{ .proof = .capability, .session = try store.authenticateCapability(node_id, session_id, token, mono_now) };
    }
    return .{ .proof = .bootstrap, .session = try store.authenticateBootstrap(node_id, try parsePeerIpv4(peer), mono_now) };
}

pub fn authenticateAsset(store: *boot_session.Store, authorization: ?[]const u8, session_header: ?[]const u8, mono_now: i64) !boot_session.Authenticated {
    const token = bearer(authorization orelse return error.MissingProof) orelse return error.MissingProof;
    return store.authenticateCapabilityAny(session_header orelse return error.MissingProof, token, mono_now);
}

test "bearer parsing never accepts a token in another shape" {
    const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expectEqualStrings(token, bearer("Bearer " ++ token).?);
    try std.testing.expect(bearer(token) == null);
    try std.testing.expect(bearer("Bearer short") == null);
}
