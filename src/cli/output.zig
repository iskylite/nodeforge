//! CLI human 输出的统一入口。
//!
//! `Output` 将是否为 JSON、是否禁用颜色等展示策略集中在一个值中。它不负责
//! 领域查询或 JSON 序列化；这样 handler 可以先取得事实，再交给 views/table 渲染。

const std = @import("std");

pub const Mode = enum { human, json, jsonl };

pub const Output = struct {
    mode: Mode,
    no_color: bool,
    sections: []const u8 = "",
    fields: []const u8 = "",
    columns: []const u8 = "",
    width: usize = 0,
    wide: bool = false,
    no_header: bool = false,

    /// M1.5 不输出 ANSI；此函数为未来仅 TTY 的状态色保留唯一判定位置。
    pub fn colorEnabled(self: Output) bool {
        return self.mode == .human and !self.no_color and false;
    }
};

pub const ContractError = error{
    ModeNotSupported,
    OptionNotApplicable,
    UnknownSelection,
    DuplicateSelection,
    MutuallyExclusiveOptions,
};

pub fn contractError(error_value: ContractError) struct { code: []const u8, message: []const u8 } {
    return switch (error_value) {
        error.ModeNotSupported => .{ .code = "output.mode_not_supported", .message = "output mode is not supported for this command" },
        error.OptionNotApplicable => .{ .code = "output.option_not_applicable", .message = "output option is not applicable to this command" },
        error.UnknownSelection => .{ .code = "output.unknown_selection", .message = "output selection contains an unknown key" },
        error.DuplicateSelection => .{ .code = "output.duplicate_selection", .message = "output selection contains a duplicate key" },
        error.MutuallyExclusiveOptions => .{ .code = "output.options_conflict", .message = "--width and --wide are mutually exclusive" },
    };
}

/// Stable JSON-line writer shared by all machine-output handlers. Structured
/// serialization avoids per-command escaping and comma handling.
pub fn writeJsonLine(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

pub fn writeResult(writer: *std.Io.Writer, result: anytype) !void {
    try writeJsonLine(writer, .{ .ok = true, .result = result });
}

pub fn writeError(writer: *std.Io.Writer, output: Output, code: []const u8, message: []const u8) !void {
    if (output.mode == .json or output.mode == .jsonl) return writeJsonLine(writer, .{ .ok = false, .@"error" = .{ .code = code, .message = message } });
    try writer.print("error: {s}\n", .{message});
}

test "JSON errors use the common envelope" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeError(&writer, .{ .mode = .json, .no_color = true }, "node.invalid", "bad property");
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":{\"code\":\"node.invalid\",\"message\":\"bad property\"}}\n", writer.buffered());
}

test "JSON successes use the common result envelope" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeResult(&writer, .{ .node_id = "n1" });
    try std.testing.expectEqualStrings("{\"ok\":true,\"result\":{\"node_id\":\"n1\"}}\n", writer.buffered());
}

test "JSONL errors are one stable envelope line" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeError(&writer, .{ .mode = .jsonl, .no_color = true }, "property.invalid", "bad value");
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":{\"code\":\"property.invalid\",\"message\":\"bad value\"}}\n", writer.buffered());
}
