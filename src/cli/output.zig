//! CLI human 输出的统一入口。
//!
//! `Output` 将是否为 JSON、是否禁用颜色等展示策略集中在一个值中。它不负责
//! 领域查询或 JSON 序列化；这样 handler 可以先取得事实，再交给 views/table 渲染。

const std = @import("std");

/// 输出模式：human（表格/详情）、json（结构化 JSON）、jsonl（逐行 JSON）。
pub const Mode = enum {
    /// human 可读输出：表格、详情块或纯文本。适合终端交互。
    human,
    /// 结构化 JSON 输出。使用 `{"ok":true,"result":...}` 信封。
    json,
    /// 逐行 JSONL 输出。每行一个 JSON 对象，适合流式处理和管道操作。
    jsonl,
};

/// CLI 输出策略。集中管理输出模式、颜色、筛选等展示选项。
/// handler 先取得事实数据，再根据此策略选择渲染路径。
pub const Output = struct {
    /// 输出模式（human/json/jsonl）。
    mode: Mode,
    /// 禁用颜色输出。M1.5 实际不输出 ANSI 颜色，此字段为未来 TTY 状态色保留。
    no_color: bool,
    /// 详情视图的分区筛选（逗号分隔的 key 列表）。
    sections: []const u8 = "",
    /// 详情视图的字段筛选（逗号分隔的 key 列表）。
    fields: []const u8 = "",
    /// 表格视图的列筛选（逗号分隔的 key 列表）。
    columns: []const u8 = "",
    /// 表格最大总宽度（0 表示不限制）。与 `wide` 互斥。
    width: usize = 0,
    /// 宽表格模式：禁用列截断，显示完整内容。与 `width` 互斥。
    wide: bool = false,
    /// 隐藏表头行。仅对表格模式有效。
    no_header: bool = false,

    /// M1.5 不输出 ANSI；此函数为未来仅 TTY 的状态色保留唯一判定位置。
    pub fn colorEnabled(self: Output) bool {
        return self.mode == .human and !self.no_color and false;
    }
};

/// 输出选项校验错误类型。用于 `OutputDocument.validate` 返回的合约错误。
pub const ContractError = error{
    /// 输出模式不被当前命令支持（如 text 文档不支持 jsonl 模式）。
    ModeNotSupported,
    /// 输出选项不适用于当前文档类型（如对 text 使用 --columns）。
    OptionNotApplicable,
    /// 筛选选择中包含未知的 key。
    UnknownSelection,
    /// 筛选选择中包含重复的 key。
    DuplicateSelection,
    /// 互斥选项同时指定（如 --width 和 --wide）。
    MutuallyExclusiveOptions,
};

/// 将合约错误映射为稳定的错误代码和消息。用于 JSON 错误信封的 `code` 和 `message` 字段。
pub fn contractError(error_value: ContractError) struct { code: []const u8, message: []const u8 } {
    return switch (error_value) {
        error.ModeNotSupported => .{ .code = "output.mode_not_supported", .message = "output mode is not supported for this command" },
        error.OptionNotApplicable => .{ .code = "output.option_not_applicable", .message = "output option is not applicable to this command" },
        error.UnknownSelection => .{ .code = "output.unknown_selection", .message = "output selection contains an unknown key" },
        error.DuplicateSelection => .{ .code = "output.duplicate_selection", .message = "output selection contains a duplicate key" },
        error.MutuallyExclusiveOptions => .{ .code = "output.options_conflict", .message = "--width and --wide are mutually exclusive" },
    };
}

/// 所有机器输出 handler 共享的稳定 JSON-line writer。
/// 使用结构化序列化避免每条命令各自处理转义和逗号。
pub fn writeJsonLine(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

/// 写入成功结果 JSON 信封：`{"ok":true,"result":...}`。
pub fn writeResult(writer: *std.Io.Writer, result: anytype) !void {
    try writeJsonLine(writer, .{ .ok = true, .result = result });
}

/// 写入错误响应。JSON/JSONL 模式输出结构化错误信封，human 模式输出 `error: <message>`。
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
