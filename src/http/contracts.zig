//! M3 面向节点的 HTTP 契约。
//!
//! 这些类型有意保持客户端输入的最小化：节点身份、事件类型、时间戳和审计
//! 字段都由服务端推导而非从 JSON 接受。这减少攻击面，防止节点伪造身份。

const std = @import("std");
const boot_session = @import("../state/boot_session.zig");

/// 面向节点 HTTP 契约的 schema 版本。
pub const schema_version: u8 = 1;
/// 节点事件 POST 请求体最大字节数。防止安装器异常导致内存耗尽。
pub const max_event_body_bytes = 4 * 1024;
/// 安装失败 reason 字段最大字节数。
pub const max_reason_bytes = 128;
/// 安装日志 message 字段最大字节数。
pub const max_message_bytes = 1024;
/// 安装失败日志摘要最大字节数。
pub const max_log_summary_bytes = 2048;

/// M4.2 F1：安装失败日志摘要的稳定 reason 值。
pub const reason_anaconda_error = "install.anaconda_error";
pub const reason_subiquity_error = "install.subiquity_error";

/// 稳定的能力 token 传输 header 名称。token 永远不允许出现在 query string 中，
/// 只通过 HTTP header 传输，防止通过 URL 日志泄漏。
pub const authorization_header = "authorization";
/// session ID 传输 header 名称。
pub const session_header = "x-nodeforge-session";

/// M4.5 稳定的管理端信封。资源载荷仍是端点
/// 特定的；这些公共形态由 golden fixture 固定。
pub fn Success(comptime T: type) type {
    return struct { ok: bool, result: T };
}

pub const ErrorEnvelope = struct {
    ok: bool,
    @"error": struct { code: []const u8, message: []const u8, details: ?std.json.Value = null, request_id: ?[]const u8 = null },
};

pub const Operation = struct {
    id: []const u8,
    kind: []const u8,
    state: []const u8,
    created_at: i64,
    updated_at: i64,
    result: []const u8,
    error_code: []const u8,
};

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

/// 稳定的机器可读原因字符串，不含空格和控制字符。
/// 比显示标签更严格，使其能安全进入 Event v2。
pub fn safeToken(value: []const u8, maximum: usize) bool {
    if (value.len == 0 or value.len > maximum) return false;
    for (value) |byte| if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '.' or byte == '_' or byte == '-')) return false;
    return true;
}

/// 单行安全字符串，不含控制字符。允许空格但拒绝换行符等控制字符。
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

test "M4.5 golden collection envelope matches items/next_cursor/view_revision" {
    const Collection = Success(struct {
        items: []const struct { id: []const u8 },
        next_cursor: ?[]const u8,
        view_revision: u64,
    });
    const parsed = try std.json.parseFromSlice(Collection, std.testing.allocator, @embedFile("fixtures/m4_5-collection.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.result.items.len);
    try std.testing.expectEqualStrings("node-01", parsed.value.result.items[0].id);
    try std.testing.expect(parsed.value.result.next_cursor == null);
    try std.testing.expectEqual(@as(u64, 42), parsed.value.result.view_revision);
}

test "M4.5 golden error envelope carries code/message/request_id" {
    const parsed = try std.json.parseFromSlice(ErrorEnvelope, std.testing.allocator, @embedFile("fixtures/m4_5-error.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqualStrings("http.precondition_required", parsed.value.@"error".code);
    try std.testing.expect(parsed.value.@"error".request_id != null);
    try std.testing.expectEqual(@as(usize, 32), parsed.value.@"error".request_id.?.len);
}

test "M4.5 golden operation envelope carries terminal state" {
    const parsed = try std.json.parseFromSlice(Success(Operation), std.testing.allocator, @embedFile("fixtures/m4_5-operation.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqualStrings("succeeded", parsed.value.result.state);
    try std.testing.expectEqualStrings("install_source_import", parsed.value.result.kind);
}

test "M4.5 golden created envelope matches 201 resource result" {
    const Created = Success(struct { node_id: []const u8, revision: u64 });
    const parsed = try std.json.parseFromSlice(Created, std.testing.allocator, @embedFile("fixtures/m4_5-created.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqualStrings("node-01", parsed.value.result.node_id);
    try std.testing.expectEqual(@as(u64, 42), parsed.value.result.revision);
}

test "M4.5 golden resource detail envelope carries canonical metadata" {
    const Resource = Success(struct { name: []const u8, kind: []const u8, path: []const u8, sha256: ?[]const u8 });
    const parsed = try std.json.parseFromSlice(Resource, std.testing.allocator, @embedFile("fixtures/m4_5-resource.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqualStrings("rocky-kernel", parsed.value.result.name);
    try std.testing.expectEqualStrings("kernel", parsed.value.result.kind);
    try std.testing.expect(parsed.value.result.sha256 != null);
}
