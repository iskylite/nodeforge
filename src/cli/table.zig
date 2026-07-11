//! 面向 human CLI 输出的无状态表格 renderer。
//!
//! 本模块只处理列宽、对齐和安全的单行 cell 渲染；不读取文件、不分配内存、
//! 不理解 asset/node 等领域对象，也绝不参与 JSON 输出。调用者先构造稳定顺序的
//! `Column` 与 `Row`，因此同一事实模型在 human/JSON 两种模式下不会发生二次查询。

const std = @import("std");

/// Cell 的水平对齐方式。资源名称和路径通常左对齐；计数、ID 等数值通常右对齐。
pub const Alignment = enum { left, right };

/// 一个稳定的 human 表格列定义。
/// `key` 仅用于 view 层识别，不强制与 JSON 字段同名；`max_width` 可限制极长字段。
pub const Column = struct {
    key: []const u8,
    title: []const u8,
    alignment: Alignment = .left,
    min_width: usize = 0,
    max_width: ?usize = null,
};

/// 一行借用的 cell 切片。表格在 `render` 调用期间不会保存这些 slice。
pub const Row = struct { cells: []const []const u8 };

/// 统一 renderer 的小型选项集。当前 M1.5 不输出颜色；保留 `color` 是为了让未来
/// TTY 状态色在一个入口启用，且测试、重定向和 `--no-color` 可明确传 false。
pub const Options = struct { color: bool = false };

/// 渲染表头和所有行。空行列表仅输出 `empty_message`，避免产生误导的空表头。
/// 输入内的控制字符会转义，确保一个 catalog 字段不能换行或重置终端状态。
pub fn render(
    writer: *std.Io.Writer,
    columns: []const Column,
    rows: []const Row,
    empty_message: []const u8,
    options: Options,
) !void {
    _ = options; // M1.5 保持无颜色输出；后续仅在此处集中增加 ANSI 包装。
    if (rows.len == 0) return writer.print("{s}\n", .{empty_message});
    if (columns.len == 0) return;

    var widths: [16]usize = undefined;
    if (columns.len > widths.len) return error.TooManyColumns;
    for (columns, 0..) |column, i| widths[i] = @max(column.min_width, displayWidth(column.title));
    for (rows) |row| {
        if (row.cells.len != columns.len) return error.InvalidRow;
        for (row.cells, 0..) |cell, i| widths[i] = @max(widths[i], boundedWidth(cell, columns[i].max_width));
    }
    try renderLine(writer, columns, widths[0..columns.len], null);
    try renderSeparator(writer, widths[0..columns.len]);
    for (rows) |row| try renderLine(writer, columns, widths[0..columns.len], row.cells);
}

/// 表头与数据之间的分隔线是 human table 的固定组成部分。它让长列表在滚动
/// 终端中仍可快速辨认表头，同时不引入颜色或 Unicode 边框到管道输出。
fn renderSeparator(writer: *std.Io.Writer, widths: []const usize) !void {
    for (widths, 0..) |width, i| {
        if (i != 0) try writer.writeAll("  ");
        for (0..width) |_| try writer.writeByte('-');
    }
    try writer.writeByte('\n');
}

fn renderLine(writer: *std.Io.Writer, columns: []const Column, widths: []const usize, cells: ?[]const []const u8) !void {
    for (columns, 0..) |column, i| {
        if (i != 0) try writer.writeAll("  ");
        const value = if (cells) |line| line[i] else column.title;
        const visible = boundedWidth(value, column.max_width);
        const padding = widths[i] - visible;
        if (cells != null and column.alignment == .right) try spaces(writer, padding);
        try writeCell(writer, value, column.max_width);
        if (cells == null or column.alignment == .left) try spaces(writer, padding);
    }
    try writer.writeByte('\n');
}

fn spaces(writer: *std.Io.Writer, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

/// 返回 display width；无效 UTF-8 以单字节可见占位计算，确保 renderer 永不崩溃。
pub fn displayWidth(value: []const u8) usize {
    var view = std.unicode.Utf8View.init(value) catch {
        // Invalid UTF-8: fall back to byte-by-byte width calculation so that
        // displayWidth matches the \xNN escaping performed by writeCell/writeEscaped.
        var width: usize = 0;
        var i: usize = 0;
        while (i < value.len) {
            const byte = value[i];
            if (byte < 0x20 or byte == 0x7f) {
                width += 4;
                i += 1;
                continue;
            }
            if (byte < 0x80) {
                width += 1;
                i += 1;
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(byte) catch {
                width += 4;
                i += 1;
                continue;
            };
            if (i + len > value.len) {
                width += 4;
                i += 1;
                continue;
            }
            const codepoint = std.unicode.utf8Decode(value[i .. i + len]) catch {
                width += 4;
                i += 1;
                continue;
            };
            width += codepointWidth(codepoint);
            i += len;
        }
        return width;
    };
    var iterator = view.iterator();
    var width: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| width += codepointWidth(codepoint);
    return width;
}

fn codepointWidth(codepoint: u21) usize {
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0)) return 4; // rendered as \xNN (4 visible chars)
    if ((codepoint >= 0x300 and codepoint <= 0x36f) or (codepoint >= 0x1ab0 and codepoint <= 0x1aff)) return 0;
    // East Asian wide/fullwidth ranges used by NodeForge's Chinese operator-facing output.
    if ((codepoint >= 0x1100 and codepoint <= 0x115f) or (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or
        (codepoint >= 0xac00 and codepoint <= 0xd7a3) or (codepoint >= 0xf900 and codepoint <= 0xfaff) or
        (codepoint >= 0xff01 and codepoint <= 0xff60) or (codepoint >= 0x20000 and codepoint <= 0x3fffd)) return 2;
    return 1;
}

fn boundedWidth(value: []const u8, maximum: ?usize) usize {
    const width = displayWidth(value);
    return if (maximum) |limit| @min(width, limit) else width;
}

fn writeCell(writer: *std.Io.Writer, value: []const u8, maximum: ?usize) !void {
    var width: usize = 0;
    var index: usize = 0;
    const needs_truncate = if (maximum) |limit| displayWidth(value) > limit else false;
    const content_limit = if (maximum) |limit| if (needs_truncate and limit > 0) limit - 1 else limit else null;
    while (index < value.len) {
        const byte = value[index];
        if (byte < 0x20 or byte == 0x7f) {
            if (content_limit) |limit| if (width + 4 > limit) break;
            try writer.print("\\x{x:0>2}", .{byte});
            width += 4;
            index += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        if (index + len > value.len) break;
        const codepoint = std.unicode.utf8Decode(value[index .. index + len]) catch {
            try writer.print("\\x{x:0>2}", .{byte});
            width += 4;
            index += 1;
            continue;
        };
        const next = codepointWidth(codepoint);
        if (content_limit) |limit| if (width + next > limit) break;
        try writer.writeAll(value[index .. index + len]);
        width += next;
        index += len;
    }
    if (maximum) |limit| if (needs_truncate and limit >= 1) try writer.writeAll("…");
}

/// Write `value` with control characters (U+0000–U+001F, U+007F) and invalid
/// UTF-8 bytes escaped as literal `\xNN`. This matches the width returned by
/// `displayWidth` and the escaping in `writeCell`, but performs no truncation.
/// Use this for detail/section views where column width is not constrained.
pub fn writeEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        if (byte < 0x20 or byte == 0x7f) {
            try writer.print("\\x{x:0>2}", .{byte});
            index += 1;
            continue;
        }
        if (byte < 0x80) {
            try writer.writeByte(byte);
            index += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try writer.print("\\x{x:0>2}", .{byte});
            index += 1;
            continue;
        };
        if (index + len > value.len) {
            try writer.print("\\x{x:0>2}", .{byte});
            index += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(value[index .. index + len]) catch {
            try writer.print("\\x{x:0>2}", .{byte});
            index += 1;
            continue;
        };
        _ = codepoint;
        try writer.writeAll(value[index .. index + len]);
        index += len;
    }
}

test "aligns variable-width columns" {
    const columns = [_]Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "count", .title = "COUNT", .alignment = .right } };
    const first = [_][]const u8{ "kernel", "2" };
    const second = [_][]const u8{ "long-bootloader", "10" };
    const rows = [_]Row{ .{ .cells = &first }, .{ .cells = &second } };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &columns, &rows, "empty", .{});
    try std.testing.expectEqualStrings("NAME             COUNT\n---------------  -----\nkernel               2\nlong-bootloader     10\n", writer.buffered());
}

test "escapes controls and counts wide unicode" {
    try std.testing.expectEqual(@as(usize, 4), displayWidth("节点"));
    const columns = [_]Column{.{ .key = "value", .title = "VALUE" }};
    const cells = [_][]const u8{"a\nb"};
    const rows = [_]Row{.{ .cells = &cells }};
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &columns, &rows, "empty", .{});
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "a\\x0ab") != null);
}

test "truncates a bounded low-value cell with an ellipsis" {
    const columns = [_]Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "path", .title = "PATH", .max_width = 8 } };
    const cells = [_][]const u8{ "kernel", "boot/very-long-image" };
    const rows = [_]Row{.{ .cells = &cells }};
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try render(&writer, &columns, &rows, "empty", .{});
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "boot/ve…") != null);
}

test "control characters have display width 4" {
    try std.testing.expectEqual(@as(usize, 6), displayWidth("a\nb"));
    try std.testing.expectEqual(@as(usize, 4), displayWidth("\t"));
}

test "invalid UTF-8 bytes have display width 4" {
    try std.testing.expectEqual(@as(usize, 4), displayWidth(&[_]u8{0xff}));
    try std.testing.expectEqual(@as(usize, 6), displayWidth("a\xffb"));
}

test "writeEscaped escapes control characters" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeEscaped(&writer, "a\nb\t");
    try std.testing.expectEqualStrings("a\\x0ab\\x09", writer.buffered());
}
