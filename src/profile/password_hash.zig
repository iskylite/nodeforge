//! SHA-512 crypt (`$6$`) for installer-only password delivery.
//!
//! Config remains plaintext by design.  This module derives a standard SHA-crypt
//! value in memory and never writes it to config, events, or runtime state.

const std = @import("std");

const crypt_b64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/// Derive a SHA-512 crypt string using an explicit salt.  The salt must contain
/// 1..16 characters from the crypt alphabet; explicit salts make fixture vectors
/// deterministic while production callers use `randomSalt`.
pub fn sha512Crypt(allocator: std.mem.Allocator, password: []const u8, salt: []const u8) ![]u8 {
    if (salt.len == 0 or salt.len > 16) return error.InvalidSalt;
    for (salt) |c| if (std.mem.indexOfScalar(u8, crypt_b64, c) == null) return error.InvalidSalt;

    var alt: [64]u8 = undefined;
    sha(&alt, &.{ password, salt, password });

    var initial = std.ArrayList(u8).empty;
    defer initial.deinit(allocator);
    try initial.appendSlice(allocator, password);
    try initial.appendSlice(allocator, salt);
    try appendRepeatedDigest(&initial, allocator, &alt, password.len);
    var remaining = password.len;
    while (remaining > 0) : (remaining >>= 1) {
        if ((remaining & 1) != 0) try initial.appendSlice(allocator, alt[0..]) else try initial.appendSlice(allocator, password);
    }
    var digest: [64]u8 = undefined;
    sha(&digest, &.{initial.items});

    var p_digest: [64]u8 = undefined;
    var p_input = std.ArrayList(u8).empty;
    defer p_input.deinit(allocator);
    for (0..password.len) |_| try p_input.appendSlice(allocator, password);
    sha(&p_digest, &.{p_input.items});
    const p_bytes = try repeatDigest(allocator, &p_digest, password.len);
    defer allocator.free(p_bytes);

    var s_digest: [64]u8 = undefined;
    var s_input = std.ArrayList(u8).empty;
    defer s_input.deinit(allocator);
    const repeats: usize = 16 + digest[0];
    for (0..repeats) |_| try s_input.appendSlice(allocator, salt);
    sha(&s_digest, &.{s_input.items});
    const s_bytes = try repeatDigest(allocator, &s_digest, salt.len);
    defer allocator.free(s_bytes);

    for (0..5000) |round| {
        var round_input = std.ArrayList(u8).empty;
        defer round_input.deinit(allocator);
        if ((round & 1) != 0) try round_input.appendSlice(allocator, p_bytes) else try round_input.appendSlice(allocator, digest[0..]);
        if (round % 3 != 0) try round_input.appendSlice(allocator, s_bytes);
        if (round % 7 != 0) try round_input.appendSlice(allocator, p_bytes);
        if ((round & 1) != 0) try round_input.appendSlice(allocator, digest[0..]) else try round_input.appendSlice(allocator, p_bytes);
        sha(&digest, &.{round_input.items});
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "$6$");
    try out.appendSlice(allocator, salt);
    try out.append(allocator, '$');
    const groups = [_][3]usize{ .{ 0, 21, 42 }, .{ 22, 43, 1 }, .{ 44, 2, 23 }, .{ 3, 24, 45 }, .{ 25, 46, 4 }, .{ 47, 5, 26 }, .{ 6, 27, 48 }, .{ 28, 49, 7 }, .{ 50, 8, 29 }, .{ 9, 30, 51 }, .{ 31, 52, 10 }, .{ 53, 11, 32 }, .{ 12, 33, 54 }, .{ 34, 55, 13 }, .{ 56, 14, 35 }, .{ 15, 36, 57 }, .{ 37, 58, 16 }, .{ 59, 17, 38 }, .{ 18, 39, 60 }, .{ 40, 61, 19 }, .{ 62, 20, 41 } };
    for (groups) |g| try b64(&out, allocator, digest[g[0]], digest[g[1]], digest[g[2]], 4);
    // The final SHA-512 byte is encoded as two low-to-high crypt-base64 chars.
    try out.append(allocator, crypt_b64[digest[63] & 0x3f]);
    try out.append(allocator, crypt_b64[digest[63] >> 6]);
    return out.toOwnedSlice(allocator);
}

pub fn randomSalt(io: std.Io) ![16]u8 {
    var source: [16]u8 = undefined;
    try io.randomSecure(&source);
    var salt: [16]u8 = undefined;
    for (&salt, source) |*item, byte| item.* = crypt_b64[byte & 0x3f];
    return salt;
}

/// Deterministic per boot-session salt: answer retries stay byte-stable while
/// different capability sessions produce different hashes.
pub fn sessionSalt(session: []const u8, account: []const u8) [16]u8 {
    var digest: [64]u8 = undefined;
    sha(&digest, &.{ session, ":", account });
    var salt: [16]u8 = undefined;
    for (&salt, 0..) |*item, i| item.* = crypt_b64[digest[i] & 0x3f];
    return salt;
}

fn sha(destination: *[64]u8, inputs: []const []const u8) void {
    var hash = std.crypto.hash.sha2.Sha512.init(.{});
    for (inputs) |input| hash.update(input);
    hash.final(destination);
}

fn repeatDigest(allocator: std.mem.Allocator, digest: *const [64]u8, length: usize) ![]u8 {
    const value = try allocator.alloc(u8, length);
    for (value, 0..) |*item, i| item.* = digest[i % digest.len];
    return value;
}

fn appendRepeatedDigest(out: *std.ArrayList(u8), allocator: std.mem.Allocator, digest: *const [64]u8, length: usize) !void {
    var remaining = length;
    while (remaining > digest.len) : (remaining -= digest.len) try out.appendSlice(allocator, digest);
    try out.appendSlice(allocator, digest[0..remaining]);
}

fn b64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, a: u8, b: u8, c: u8, count: usize) !void {
    var value: u32 = (@as(u32, a) << 16) | (@as(u32, b) << 8) | c;
    for (0..count) |_| {
        try out.append(allocator, crypt_b64[@intCast(value & 0x3f)]);
        value >>= 6;
    }
}

test "SHA-512 crypt matches OpenSSL vector" {
    const actual = try sha512Crypt(std.testing.allocator, "asdf1234", "cMSfREEyDS62.C3i");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("$6$cMSfREEyDS62.C3i$YXaVabtf/dJlna3TpfDRZDzxCTpkRCl.u9GFcwm35HRFJkXDsyJCHZ1Qh6K9vrfbRPBJmIazQD0oenSkIQ9ff/", actual);
}

test "preview salts use secure randomness and the crypt alphabet" {
    const first = try randomSalt(std.testing.io);
    const second = try randomSalt(std.testing.io);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    for (first ++ second) |byte| try std.testing.expect(std.mem.indexOfScalar(u8, crypt_b64, byte) != null);
}
