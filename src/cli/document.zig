//! Typed CLI output document and the only normal-result renderer.
const std = @import("std");
const output = @import("output.zig");
const table = @import("table.zig");

pub const Section = struct { key: []const u8, title: []const u8 };
pub const Field = struct {
    key: []const u8,
    value: []const u8,
    section: []const u8 = "",
    json_path: ?[]const u8 = null,
};
pub const Detail = struct { title: []const u8, sections: []const Section = &.{}, fields: []const Field };
pub const Table = struct { columns: []const table.Column, rows: []const table.Row, empty_message: []const u8 };
pub const Human = union(enum) { text: []const u8, detail: Detail, table: Table };

pub const OutputDocument = struct {
    human: Human,
    json: []const u8,
    jsonl: ?[]const []const u8 = null,

    pub fn render(self: OutputDocument, writer: *std.Io.Writer, options: output.Output) !void {
        try self.validate(options);
        switch (options.mode) {
            .human => switch (self.human) {
                .text => |value| try writeLine(writer, value),
                .detail => |value| try renderDetail(writer, value, options.sections, options.fields),
                .table => |value| try table.render(writer, value.columns, value.rows, value.empty_message, .{ .color = options.colorEnabled(), .columns = options.columns, .width = options.width, .wide = options.wide, .no_header = options.no_header }),
            },
            .json => switch (self.human) {
                .detail => |value| if (options.sections.len != 0 or options.fields.len != 0)
                    try renderFilteredJson(writer, self.json, value, options.sections, options.fields)
                else
                    try writeLine(writer, std.mem.trim(u8, self.json, "\r\n")),
                else => try writeLine(writer, std.mem.trim(u8, self.json, "\r\n")),
            },
            .jsonl => if (self.jsonl) |items| {
                for (items) |item| try writeLine(writer, std.mem.trim(u8, item, "\r\n"));
            } else unreachable,
        }
    }

    pub fn validate(self: OutputDocument, options: output.Output) output.ContractError!void {
        if (options.width != 0 and options.wide) return error.MutuallyExclusiveOptions;
        if (options.mode == .jsonl and self.jsonl == null) return error.ModeNotSupported;
        switch (self.human) {
            .table => |value| {
                if (options.sections.len != 0 or options.fields.len != 0) return error.OptionNotApplicable;
                if (options.mode != .human and (options.columns.len != 0 or options.no_header or options.width != 0 or options.wide)) return error.OptionNotApplicable;
                try validateSelection(options.columns, columnKeys(value.columns));
            },
            .detail => |value| {
                if (options.columns.len != 0 or options.no_header or options.width != 0 or options.wide) return error.OptionNotApplicable;
                try validateSelection(options.sections, sectionKeys(value.sections));
                try validateSelection(options.fields, fieldKeys(value.fields));
            },
            .text => {
                if (options.sections.len != 0 or options.fields.len != 0 or options.columns.len != 0 or options.no_header or options.width != 0 or options.wide) return error.OptionNotApplicable;
            },
        }
    }
};

fn fieldKeys(fields: []const Field) KeySet {
    return .{ .fields = fields };
}

fn columnKeys(columns: []const table.Column) KeySet {
    return .{ .columns = columns };
}

fn sectionKeys(sections: []const Section) KeySet {
    return .{ .sections = sections };
}

const KeySet = union(enum) {
    fields: []const Field,
    columns: []const table.Column,
    sections: []const Section,

    fn contains(self: KeySet, key: []const u8) bool {
        return switch (self) {
            .fields => |values| blk: {
                for (values) |value| if (std.mem.eql(u8, value.key, key)) break :blk true;
                break :blk false;
            },
            .columns => |values| blk: {
                for (values) |value| if (std.mem.eql(u8, value.key, key)) break :blk true;
                break :blk false;
            },
            .sections => |values| blk: {
                for (values) |value| if (std.mem.eql(u8, value.key, key)) break :blk true;
                break :blk false;
            },
        };
    }
};

fn validateSelection(selection: []const u8, keys: KeySet) output.ContractError!void {
    if (selection.len == 0) return;
    var outer = std.mem.splitScalar(u8, selection, ',');
    var index: usize = 0;
    while (outer.next()) |raw| : (index += 1) {
        const key = std.mem.trim(u8, raw, " \t");
        if (key.len == 0 or !keys.contains(key)) return error.UnknownSelection;
        var inner = std.mem.splitScalar(u8, selection, ',');
        var prior: usize = 0;
        while (prior < index) : (prior += 1) {
            const previous = std.mem.trim(u8, inner.next().?, " \t");
            if (std.mem.eql(u8, previous, key)) return error.DuplicateSelection;
        }
    }
}

fn renderDetail(writer: *std.Io.Writer, detail: Detail, sections: []const u8, fields: []const u8) !void {
    try writer.print("{s}\n", .{detail.title});
    if (detail.sections.len == 0) {
        for (detail.fields) |field| if (selected(fields, field.key)) try writer.print("{s}\t{s}\n", .{ field.key, field.value });
        return;
    }
    for (detail.sections) |section| {
        if (!selected(sections, section.key)) continue;
        var heading_written = false;
        for (detail.fields) |field| {
            if (!std.mem.eql(u8, field.section, section.key) or !selected(fields, field.key)) continue;
            if (!heading_written) {
                try writer.print("\n{s}\n", .{section.title});
                heading_written = true;
            }
            try writer.print("{s}\t{s}\n", .{ field.key, field.value });
        }
    }
}

fn renderFilteredJson(writer: *std.Io.Writer, raw: []const u8, detail: Detail, sections: []const u8, fields: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    var filtered_result: std.json.ObjectMap = .empty;
    const source_result = root.get("result") orelse return error.InvalidJsonEnvelope;
    for (detail.fields) |field| {
        if (!selected(sections, field.section) or !selected(fields, field.key)) continue;
        const path = field.json_path orelse field.key;
        const value = valueAtPath(source_result, path) orelse continue;
        try putAtPath(allocator, &filtered_result, path, value);
    }
    var envelope: std.json.ObjectMap = .empty;
    try envelope.put(allocator, "ok", root.get("ok") orelse .{ .bool = true });
    try envelope.put(allocator, "result", .{ .object = filtered_result });
    try writer.print("{f}\n", .{std.json.fmt(std.json.Value{ .object = envelope }, .{})});
}

fn valueAtPath(root: std.json.Value, path: []const u8) ?std.json.Value {
    var current = root;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| current = switch (current) {
        .object => |object| object.get(part) orelse return null,
        else => return null,
    };
    return current;
}

fn putAtPath(allocator: std.mem.Allocator, root: *std.json.ObjectMap, path: []const u8, value: std.json.Value) !void {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return root.put(allocator, path, value);
    const head = path[0..dot];
    const tail = path[dot + 1 ..];
    const entry = try root.getOrPut(allocator, head);
    if (!entry.found_existing) entry.value_ptr.* = .{ .object = .empty };
    if (entry.value_ptr.* != .object) return error.InvalidJsonEnvelope;
    try putAtPath(allocator, &entry.value_ptr.object, tail, value);
}

fn selected(selection: []const u8, key: []const u8) bool {
    if (selection.len == 0) return true;
    var iterator = std.mem.splitScalar(u8, selection, ',');
    while (iterator.next()) |raw| if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t"), key)) return true;
    return false;
}

fn compactJson(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn writeLine(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeAll(value);
    try writer.writeByte('\n');
}

test "document renders detail fields and JSONL through one pipeline" {
    const fields = [_]Field{ .{ .key = "name", .value = "n1" }, .{ .key = "secret", .value = "hidden" } };
    const document: OutputDocument = .{ .human = .{ .detail = .{ .title = "Node", .fields = &fields } }, .json = "{\"ok\":true}\n" };
    var human_buffer: [128]u8 = undefined;
    var human: std.Io.Writer = .fixed(&human_buffer);
    try document.render(&human, .{ .mode = .human, .no_color = true, .fields = "name" });
    try std.testing.expectEqualStrings("Node\nname\tn1\n", human.buffered());
    try std.testing.expectError(error.ModeNotSupported, document.validate(.{ .mode = .jsonl, .no_color = true }));
}

test "document rejects unknown duplicate and inapplicable selectors" {
    const fields = [_]Field{ .{ .key = "name", .value = "n1" }, .{ .key = "arch", .value = "x86_64" } };
    const detail: OutputDocument = .{ .human = .{ .detail = .{ .title = "Node", .fields = &fields } }, .json = "{}" };
    try std.testing.expectError(error.UnknownSelection, detail.validate(.{ .mode = .human, .no_color = true, .fields = "missing" }));
    try std.testing.expectError(error.DuplicateSelection, detail.validate(.{ .mode = .human, .no_color = true, .fields = "name,name" }));
    try std.testing.expectError(error.OptionNotApplicable, detail.validate(.{ .mode = .human, .no_color = true, .columns = "name" }));
    try std.testing.expectError(error.MutuallyExclusiveOptions, detail.validate(.{ .mode = .human, .no_color = true, .width = 80, .wide = true }));

    const columns = [_]table.Column{.{ .key = "name", .title = "NAME" }};
    const list: OutputDocument = .{ .human = .{ .table = .{ .columns = &columns, .rows = &.{}, .empty_message = "empty" } }, .json = "{}", .jsonl = &.{} };
    try std.testing.expectError(error.UnknownSelection, list.validate(.{ .mode = .human, .no_color = true, .columns = "missing" }));
    try std.testing.expectError(error.OptionNotApplicable, list.validate(.{ .mode = .json, .no_color = true, .no_header = true }));
}

test "detail sections and fields compose as an intersection" {
    const sections = [_]Section{ .{ .key = "stored", .title = "Stored" }, .{ .key = "runtime", .title = "Runtime" } };
    const fields = [_]Field{ .{ .key = "name", .value = "n1", .section = "stored" }, .{ .key = "phase", .value = "ready", .section = "runtime" } };
    const detail: OutputDocument = .{ .human = .{ .detail = .{ .title = "Node", .sections = &sections, .fields = &fields } }, .json = "{}" };
    var buffer: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try detail.render(&writer, .{ .mode = .human, .no_color = true, .sections = "runtime", .fields = "phase" });
    try std.testing.expectEqualStrings("Node\n\nRuntime\nphase\tready\n", writer.buffered());
    try std.testing.expectError(error.UnknownSelection, detail.validate(.{ .mode = .human, .no_color = true, .sections = "missing" }));
    try std.testing.expectError(error.DuplicateSelection, detail.validate(.{ .mode = .human, .no_color = true, .sections = "stored,stored" }));
}

test "detail selections filter JSON envelope structurally" {
    const sections = [_]Section{ .{ .key = "stored", .title = "Stored" }, .{ .key = "runtime", .title = "Runtime" } };
    const fields = [_]Field{
        .{ .key = "name", .value = "n1", .section = "stored" },
        .{ .key = "phase", .value = "ready", .section = "runtime", .json_path = "status.phase" },
    };
    const detail: OutputDocument = .{ .human = .{ .detail = .{ .title = "Node", .sections = &sections, .fields = &fields } }, .json = "{\"ok\":true,\"result\":{\"name\":\"n1\",\"status\":{\"phase\":\"ready\",\"reason\":\"done\"}}}" };
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try detail.render(&writer, .{ .mode = .json, .no_color = true, .sections = "runtime", .fields = "phase" });
    try std.testing.expectEqualStrings("{\"ok\":true,\"result\":{\"status\":{\"phase\":\"ready\"}}}\n", writer.buffered());
}
