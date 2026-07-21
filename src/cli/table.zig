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
pub const Options = struct {
    color: bool = false,
    columns: []const u8 = "",
    width: usize = 0,
    wide: bool = false,
    no_header: bool = false,
};

/// 渲染表头和所有行。空行列表仅输出 `empty_message`，避免产生误导的空表头。
/// 输入内的控制字符会转义，确保一个 catalog 字段不能换行或重置终端状态。
pub fn render(
    writer: *std.Io.Writer,
    columns: []const Column,
    rows: []const Row,
    empty_message: []const u8,
    options: Options,
) !void {
    if (rows.len == 0) return writer.print("{s}\n", .{empty_message});
    if (columns.len == 0) return;

    var widths: [16]usize = undefined;
    var indices: [16]usize = undefined;
    if (columns.len > widths.len) return error.TooManyColumns;
    var selected_count: usize = 0;
    for (columns, 0..) |column, index| {
        if (!selectedColumn(options.columns, column.key)) continue;
        indices[selected_count] = index;
        widths[selected_count] = @max(column.min_width, displayWidth(column.title));
        selected_count += 1;
    }
    if (selected_count == 0) return error.UnknownColumn;
    for (rows) |row| {
        if (row.cells.len != columns.len) return error.InvalidRow;
        for (indices[0..selected_count], 0..) |source_index, selected_index| {
            const maximum = if (options.wide) null else columns[source_index].max_width;
            widths[selected_index] = @max(widths[selected_index], boundedWidth(row.cells[source_index], maximum));
        }
    }
    constrainWidths(widths[0..selected_count], options.width);
    if (!options.no_header) {
        try renderSelectedLine(writer, columns, indices[0..selected_count], widths[0..selected_count], null, options.wide);
        try renderSeparator(writer, widths[0..selected_count]);
    }
    for (rows) |row| try renderSelectedLine(writer, columns, indices[0..selected_count], widths[0..selected_count], row.cells, options.wide);
}

fn selectedColumn(selection: []const u8, key: []const u8) bool {
    if (selection.len == 0) return true;
    var iterator = std.mem.splitScalar(u8, selection, ',');
    while (iterator.next()) |raw| if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t"), key)) return true;
    return false;
}

fn constrainWidths(widths: []usize, maximum: usize) void {
    if (maximum == 0 or widths.len == 0) return;
    const separators = (widths.len - 1) * 2;
    if (maximum <= separators + widths.len) return;
    const available = maximum - separators;
    while (sum(widths) > available) {
        var widest: usize = 0;
        for (widths, 0..) |width, index| if (width > widths[widest]) {
            widest = index;
        };
        if (widths[widest] <= 1) break;
        widths[widest] -= 1;
    }
}

fn sum(values: []const usize) usize {
    var total: usize = 0;
    for (values) |value| total += value;
    return total;
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

fn renderSelectedLine(writer: *std.Io.Writer, columns: []const Column, indices: []const usize, widths: []const usize, cells: ?[]const []const u8, wide: bool) !void {
    for (indices, 0..) |source_index, selected_index| {
        if (selected_index != 0) try writer.writeAll("  ");
        const column = columns[source_index];
        const value = if (cells) |line| line[source_index] else column.title;
        const maximum = if (wide) widths[selected_index] else @min(column.max_width orelse widths[selected_index], widths[selected_index]);
        const visible = boundedWidth(value, maximum);
        const padding = widths[selected_index] - visible;
        if (cells != null and column.alignment == .right) try spaces(writer, padding);
        try writeCell(writer, value, maximum);
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
        // 无效 UTF-8：回退到逐字节宽度计算，使 displayWidth 与
        // writeCell/writeEscaped 执行的 \xNN 转义一致。
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
    // NodeForge 中文操作界面使用的东亚宽/全角字符范围。
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

/// 将 `value` 中的控制字符（U+0000–U+001F, U+007F）和无效 UTF-8 字节
/// 转义为字面量 `\xNN`。此函数的转义行为与 `displayWidth` 的宽度计算
/// 和 `writeCell` 的转义逻辑一致，但不执行截断。
/// 适用于详情/分区视图等不受列宽约束的场景。
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

test "output options filter columns constrain width and suppress header" {
    const columns = [_]Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "path", .title = "PATH" } };
    const cells = [_][]const u8{ "kernel", "boot/a-very-long-image" };
    const rows = [_]Row{.{ .cells = &cells }};
    var filtered_buffer: [128]u8 = undefined;
    var filtered: std.Io.Writer = .fixed(&filtered_buffer);
    try render(&filtered, &columns, &rows, "empty", .{ .columns = "name", .no_header = true });
    try std.testing.expectEqualStrings("kernel\n", filtered.buffered());
    var width_buffer: [128]u8 = undefined;
    var width_writer: std.Io.Writer = .fixed(&width_buffer);
    try render(&width_writer, &columns, &rows, "empty", .{ .width = 14 });
    var lines = std.mem.splitScalar(u8, width_writer.buffered(), '\n');
    while (lines.next()) |line| try std.testing.expect(displayWidth(line) <= 14);
}
