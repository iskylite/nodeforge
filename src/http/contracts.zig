//! M3 node-facing HTTP contracts.  These types deliberately keep client input
//! small: node identity, event type, timestamps and audit fields are derived on
//! the server rather than accepted from JSON.

const std = @import("std");
const boot_session = @import("../state/boot_session.zig");

pub const schema_version: u8 = 1;
pub const max_event_body_bytes = 4 * 1024;
pub const max_reason_bytes = 128;
pub const max_message_bytes = 1024;
pub const max_log_summary_bytes = 2048;

/// Stable capability transport names. Tokens are never valid in query strings.
pub const authorization_header = "authorization";
pub const session_header = "x-nodeforge-session";

pub const NodeEvent = struct {
    v: u8,
    boot_session_id: []const u8,
    stage: []const u8,
    reason: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

pub const LogSummary = struct {
    v: u8,
    boot_session_id: []const u8,
    reason: []const u8,
    summary: []const u8,
};

pub fn validateNodeEvent(value: NodeEvent) !void {
    if (value.v != schema_version or !boot_session.validId(value.boot_session_id)) return error.InvalidNodeEvent;
    if (!safeToken(value.stage, 64)) return error.InvalidNodeEvent;
    if (value.reason) |reason| if (!safeToken(reason, max_reason_bytes)) return error.InvalidNodeEvent;
    if (value.message) |message| if (!safeSingleLine(message, max_message_bytes)) return error.InvalidNodeEvent;
}

pub fn validateLogSummary(value: LogSummary) !void {
    if (value.v != schema_version or !boot_session.validId(value.boot_session_id)) return error.InvalidLogSummary;
    if (!safeToken(value.reason, max_reason_bytes) or !safeSingleLine(value.summary, max_log_summary_bytes)) return error.InvalidLogSummary;
}

/// A stable machine reason contains no spaces or control characters.  It is
/// intentionally stricter than a display label so it can safely enter Event v2.
pub fn safeToken(value: []const u8, maximum: usize) bool {
    if (value.len == 0 or value.len > maximum) return false;
    for (value) |byte| if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '.' or byte == '_' or byte == '-')) return false;
    return true;
}

pub fn safeSingleLine(value: []const u8, maximum: usize) bool {
    if (value.len == 0 or value.len > maximum) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

test "M3 DTO boundaries reject untrusted free-form data" {
    try validateNodeEvent(.{ .v = 1, .boot_session_id = "0123456789abcdef0123456789abcdef", .stage = "rootfs_verified", .reason = "sha256_ok", .message = "verified" });
    try std.testing.expectError(error.InvalidNodeEvent, validateNodeEvent(.{ .v = 1, .boot_session_id = "bad", .stage = "running" }));
    try std.testing.expectError(error.InvalidNodeEvent, validateNodeEvent(.{ .v = 1, .boot_session_id = "0123456789abcdef0123456789abcdef", .stage = "running", .message = "line1\nline2" }));
}
