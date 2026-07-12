//! M3 面向节点的 HTTP 契约。
//!
//! 这些类型有意保持客户端输入的最小化：节点身份、事件类型、时间戳和审计
//! 字段都由服务端推导而非从 JSON 接受。这减少攻击面，防止节点伪造身份。

const std = @import("std");
const boot_session = @import("../state/boot_session.zig");

pub const schema_version: u8 = 1;
pub const max_event_body_bytes = 4 * 1024;
pub const max_reason_bytes = 128;
pub const max_message_bytes = 1024;
pub const max_log_summary_bytes = 2048;

/// 稳定的 capability 传输 header 名称。token 永远不允许出现在 query string 中，
/// 只通过 HTTP header 传输，防止通过 URL 日志泄漏。
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
