//! 只读 Event v1/v2 历史访问，由本地 CLI 命令共享。
//!
//! daemon 仍是唯一的 JSONL 写入者。本模块只扫描保留的轮转文件，
//! 将解析的记录克隆到命令分配器中，并为 list、follow 和 trace
//! 视图暴露稳定的字段过滤器。

const std = @import("std");
const events = @import("../state/events.zig");

pub const max_records = 1000;
pub const max_rotations: u8 = 20;

/// 事件过滤条件。空字符串表示不筛选该维度；limit 限制最大返回记录数。
pub const Filters = struct {
    /// 事件类型名称筛选（如 `dhcp.ack`）。
    event_type: []const u8 = "",
    /// 节点 ID 筛选。
    node: []const u8 = "",
    /// boot session ID 筛选。
    session: []const u8 = "",
    /// 起始时间（Unix 秒，闭区间）。
    since: ?i64 = null,
    /// 截止时间（Unix 秒，闭区间）。
    until: ?i64 = null,
    /// 最大返回记录数。
    limit: usize = 100,
};

/// 事件读取结果统计。
pub const ReadResult = struct {
    /// 成功解析并匹配的记录数。
    count: usize,
    /// 因损坏或半写入而跳过的行数。
    skipped: usize,
};

/// 从最旧保留文件到活动文件扫描，并只保留最后 N 条匹配记录。
///
/// 这让 list/trace 即使没有索引也按时间自然读取；损坏或半写入的 JSONL 行会被
/// 计入 `skipped`，由调用者在结果中明确呈现，而不会使整个历史不可读取。
pub fn read(io: std.Io, allocator: std.mem.Allocator, base_path: []const u8, filters: *const Filters, rows: []events.ReadEvent) !ReadResult {
    var count: usize = 0;
    var skipped: usize = 0;
    var rotation: u8 = max_rotations;
    while (rotation > 0) : (rotation -= 1) {
        const path = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ base_path, rotation });
        defer allocator.free(path);
        readFile(io, allocator, path, filters, rows, &count, &skipped) catch |err| if (err != error.FileNotFound) return err;
    }
    readFile(io, allocator, base_path, filters, rows, &count, &skipped) catch |err| if (err != error.FileNotFound) return err;
    return .{ .count = count, .skipped = skipped };
}

/// 使用 Event v2 field 和旧 v1 顶层 node 的兼容规则执行本地过滤。
pub fn matches(event: events.ReadEvent, filters: *const Filters) bool {
    if (filters.event_type.len != 0 and !std.mem.eql(u8, event.type, filters.event_type)) return false;
    if (filters.node.len != 0 and !(if (node(event)) |value| std.mem.eql(u8, value, filters.node) else false)) return false;
    if (filters.session.len != 0 and !(if (session(event)) |value| std.mem.eql(u8, value, filters.session) else false)) return false;
    const stamp = parseTime(event.ts) catch return false;
    if (filters.since) |since| if (stamp < since) return false;
    if (filters.until) |until| if (stamp > until) return false;
    return true;
}

/// 从事件中提取节点 ID。优先使用 v1 顶层 `node` 字段，回退到 v2 fields 中的 `node_id`。
pub fn node(event: events.ReadEvent) ?[]const u8 {
    if (event.node) |value| return value;
    return field(event, "node_id");
}

/// 只把显式写入的 boot session 当作关联证据，缺失时绝不做推断。
pub fn session(event: events.ReadEvent) ?[]const u8 {
    return field(event, "boot_session_id");
}

/// 从事件 fields 中按 key 查找值。用于提取 `node_id`、`mac` 等关联字段。
pub fn field(event: events.ReadEvent, key: []const u8) ?[]const u8 {
    for (event.fields) |item| if (std.mem.eql(u8, item.key, key)) return item.value;
    return null;
}

/// 将 fields 渲染为 `key=value key=value` 格式的单行字符串。用于 human 输出。
pub fn fieldsText(allocator: std.mem.Allocator, fields: []const events.Field) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    for (fields, 0..) |field_value, index| {
        if (index != 0) try output.writer.writeByte(' ');
        try output.writer.print("{s}={s}", .{ field_value.key, field_value.value });
    }
    return output.toOwnedSlice();
}

/// 将事件时间戳归一化为人类可读的 RFC 3339 展示值。
/// daemon 新写入的事件已是 RFC 3339，原样返回；仅 `unix:<seconds>` 这种
/// 旧/紧凑格式被转换为 UTC 可视化时间，使 CLI 任何输出位置的时间展示一致。
/// 解析失败时退回原值，绝不丢弃记录。
pub fn displayTs(buffer: *[20]u8, ts: []const u8) []const u8 {
    if (std.mem.startsWith(u8, ts, events.unix_timestamp_prefix)) {
        const seconds = std.fmt.parseInt(i64, ts[events.unix_timestamp_prefix.len..], 10) catch return ts;
        return events.rfc3339FromUnix(buffer, seconds) catch ts;
    }
    return ts;
}

/// 解析事件时间戳为 Unix 秒。支持 RFC 3339 和 `unix:<seconds>` 两种格式。
/// RFC 3339 解析手动实现以避免引入额外的日期库依赖。
pub fn parseTime(value: []const u8) !i64 {
    if (std.mem.startsWith(u8, value, events.unix_timestamp_prefix)) return std.fmt.parseInt(i64, value[events.unix_timestamp_prefix.len..], 10);
    if (value.len != 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':' or value[19] != 'Z') return error.InvalidTimestamp;
    const year = try std.fmt.parseInt(u16, value[0..4], 10);
    const month = try std.fmt.parseInt(u8, value[5..7], 10);
    const day = try std.fmt.parseInt(u8, value[8..10], 10);
    const hour = try std.fmt.parseInt(u8, value[11..13], 10);
    const minute = try std.fmt.parseInt(u8, value[14..16], 10);
    const second = try std.fmt.parseInt(u8, value[17..19], 10);
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;
    var days: i64 = 0;
    var current: u16 = 1970;
    while (current < year) : (current += 1) days += if (std.time.epoch.isLeapYear(current)) 366 else 365;
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    for (month_days[0 .. month - 1], 0..) |count, index| days += @as(i64, count) + if (index == 1 and std.time.epoch.isLeapYear(year)) @as(i64, 1) else @as(i64, 0);
    const maximum_day: u8 = month_days[month - 1] + if (month == 2 and std.time.epoch.isLeapYear(year)) @as(u8, 1) else @as(u8, 0);
    if (day > maximum_day) return error.InvalidTimestamp;
    return days * 86400 + @as(i64, day - 1) * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, filters: *const Filters, rows: []events.ReadEvent, count: *usize, skipped: *usize) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(100 * 1024 * 1024));
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(events.ReadEvent, allocator, line, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            skipped.* += 1;
            continue;
        };
        defer parsed.deinit();
        if (!matches(parsed.value, filters)) continue;
        const capacity = @min(rows.len, filters.limit);
        if (capacity == 0) continue;
        const cloned = try cloneEvent(allocator, parsed.value);
        if (count.* == capacity) {
            freeEvent(allocator, rows[0]);
            std.mem.copyForwards(events.ReadEvent, rows[0 .. capacity - 1], rows[1..capacity]);
            rows[capacity - 1] = cloned;
        } else {
            rows[count.*] = cloned;
            count.* += 1;
        }
    }
}

/// 释放克隆事件的分配器内存。每个字段（ts/type/message/fields/node）单独释放。
pub fn freeEvent(allocator: std.mem.Allocator, event: events.ReadEvent) void {
    allocator.free(event.ts);
    allocator.free(event.type);
    allocator.free(event.message);
    for (event.fields) |field_value| {
        allocator.free(field_value.key);
        allocator.free(field_value.value);
    }
    allocator.free(event.fields);
    if (event.node) |node_value| allocator.free(node_value);
}

fn cloneEvent(allocator: std.mem.Allocator, source: events.ReadEvent) !events.ReadEvent {
    const fields = try allocator.alloc(events.Field, source.fields.len);
    for (source.fields, 0..) |item, index| fields[index] = .{
        .key = try allocator.dupe(u8, item.key),
        .value = try allocator.dupe(u8, item.value),
    };
    return .{
        .v = source.v,
        .ts = try allocator.dupe(u8, source.ts),
        .type = try allocator.dupe(u8, source.type),
        .message = try allocator.dupe(u8, source.message),
        .fields = fields,
        .node = if (source.node) |value| try allocator.dupe(u8, value) else null,
    };
}

test "filters accept a session id only when present in fields" {
    const event: events.ReadEvent = .{
        .ts = "2026-07-11T08:30:00Z",
        .type = "dhcp.ack",
        .fields = &.{.{ .key = "boot_session_id", .value = "0123456789abcdef0123456789abcdef" }},
    };
    try std.testing.expect(matches(event, &.{ .session = "0123456789abcdef0123456789abcdef" }));
    try std.testing.expect(!matches(event, &.{ .session = "abcdef0123456789abcdef0123456789" }));
}

test "read keeps the newest bounded matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(relative_root);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative_root, std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/events.jsonl", .{root});
    defer std.testing.allocator.free(path);
    try @import("../state/dhcp_store.zig").atomicWrite(std.testing.io, path, "{\"ts\":\"unix:1\",\"type\":\"one\",\"message\":\"\"}\n" ++
        "{\"ts\":\"unix:2\",\"type\":\"two\",\"message\":\"\"}\n" ++
        "{\"ts\":\"unix:3\",\"type\":\"three\",\"message\":\"\"}\n");
    var rows: [2]events.ReadEvent = undefined;
    const result = try read(std.testing.io, std.testing.allocator, path, &.{ .limit = 2 }, &rows);
    defer for (rows[0..result.count]) |event| freeEvent(std.testing.allocator, event);
    try std.testing.expectEqual(@as(usize, 2), result.count);
    try std.testing.expectEqualStrings("two", rows[0].type);
    try std.testing.expectEqualStrings("three", rows[1].type);
}
