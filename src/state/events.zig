//! Versioned JSONL audit events. The daemon owns the only writer; CLI only reads.

const std = @import("std");
const event_types = @import("event_types.zig");

pub const max_line_bytes = 8 * 1024;
pub const max_message_bytes = 2048;
pub const max_field_count = 32;
pub const max_field_key_bytes = 64;
pub const max_field_value_bytes = 1024;
pub const unix_timestamp_prefix = "unix:";

pub const Field = struct { key: []const u8, value: []const u8 };

/// Event v2 emitted by M2.5 writers.
pub const Event = struct {
    v: u8 = 2,
    ts: []const u8,
    @"type": []const u8,
    message: []const u8,
    fields: []const Field = &.{},
};

/// Version-neutral reader representation. v1 has no `fields` in the current
/// writer format, but older manually-created records may retain a top-level node.
pub const ReadEvent = struct {
    v: u8 = 1,
    ts: []const u8,
    @"type": []const u8,
    message: []const u8 = "",
    fields: []const Field = &.{},
    node: ?[]const u8 = null,
};

/// A process-local serializer. The lock covers rendering, size check, rotation
/// and append, so concurrent protocol workers cannot overwrite the file tail.
pub const Writer = struct {
    mutex: std.atomic.Mutex = .unlocked,
    max_size_bytes: u64 = 100 * 1024 * 1024,
    keep: u8 = 5,

    pub fn configure(self: *Writer, max_size_mb: u16, keep: u8) void {
        self.max_size_bytes = @as(u64, max_size_mb) * 1024 * 1024;
        self.keep = keep;
    }

    /// Compatibility entrypoint for v1 fixture producers. New daemon code must
    /// call `appendWithFields` and therefore always produce Event v2.
    pub fn append(self: *Writer, io: std.Io, allocator: std.mem.Allocator, path: []const u8, event: Event) !void {
        try self.appendWithFields(io, allocator, path, event.@"type", event.message, event.fields);
    }

    pub fn appendWithFields(
        self: *Writer,
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        event_type: []const u8,
        message: []const u8,
        fields: []const Field,
    ) !void {
        try validate(event_type, message, fields);
        var timestamp: [20]u8 = undefined;
        const ts = try rfc3339Now(&timestamp);
        const event = Event{ .ts = ts, .@"type" = event_type, .message = message, .fields = fields };
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try std.json.Stringify.value(event, .{}, &output.writer);
        try output.writer.writeByte('\n');
        if (output.written().len > max_line_bytes) return error.EventTooLarge;

        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
        defer self.mutex.unlock();
        try rotateBeforeAppend(io, allocator, path, self.max_size_bytes, self.keep, output.written().len);
        const dir = std.Io.Dir.cwd();
        var file = dir.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(io, path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        defer file.close(io);
        const stat = try file.stat(io);
        try file.writePositionalAll(io, output.written(), stat.size);
    }
};

pub fn validate(event_type: []const u8, message: []const u8, fields: []const Field) !void {
    if (event_types.fromName(event_type) == null) return error.UnknownEventType;
    if (message.len > max_message_bytes) return error.MessageTooLong;
    if (fields.len > max_field_count) return error.TooManyFields;
    for (fields, 0..) |field, index| {
        if (!validFieldKey(field.key)) return error.InvalidFieldKey;
        if (field.value.len > max_field_value_bytes) return error.FieldValueTooLong;
        for (fields[index + 1 ..]) |other|
            if (std.mem.eql(u8, field.key, other.key)) return error.DuplicateFieldKey;
    }
}

pub fn validFieldKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_field_key_bytes or key[0] < 'a' or key[0] > 'z') return false;
    for (key[1..]) |byte|
        if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '_')) return false;
    return true;
}

fn rotateBeforeAppend(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_size: u64, keep: u8, line_len: usize) !void {
    const dir = std.Io.Dir.cwd();
    const current_size: u64 = blk: {
        var file = dir.openFile(io, path, .{}) catch |err| switch (err) { error.FileNotFound => break :blk 0, else => return err };
        defer file.close(io);
        break :blk (try file.stat(io)).size;
    };
    if (current_size == 0 or current_size + line_len <= max_size) return;
    const oldest = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, keep });
    defer allocator.free(oldest);
    dir.deleteFile(io, oldest) catch |err| if (err != error.FileNotFound) return err;
    var index: u8 = keep;
    while (index > 1) : (index -= 1) {
        const source = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, index - 1 });
        defer allocator.free(source);
        const destination = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ path, index });
        defer allocator.free(destination);
        std.Io.Dir.rename(dir, source, dir, destination, io) catch |err| if (err != error.FileNotFound) return err;
    }
    const first = try std.fmt.allocPrint(allocator, "{s}.1", .{path});
    defer allocator.free(first);
    try std.Io.Dir.rename(dir, path, dir, first, io);
}

pub fn rfc3339Now(buffer: *[20]u8) ![]const u8 {
    var clock: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &clock)) != .SUCCESS) return error.ClockUnavailable;
    return rfc3339FromUnix(buffer, clock.sec);
}

pub fn rfc3339FromUnix(buffer: *[20]u8, seconds: i64) ![]const u8 {
    if (seconds < 0) return error.InvalidTimestamp;
    const instant: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const year_day = instant.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = instant.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

test "event v2 validates fields and renders rfc3339" {
    var stamp: [20]u8 = undefined;
    try std.testing.expectEqualStrings("2026-07-11T08:30:00Z", try rfc3339FromUnix(&stamp, 1783758600));
    try validate("dhcp.ack", "sent ACK", &.{ .{ .key = "mac", .value = "52:54:00:aa:bb:cc" } });
    try std.testing.expectError(error.DuplicateFieldKey, validate("dhcp.ack", "sent ACK", &.{ .{ .key = "mac", .value = "a" }, .{ .key = "mac", .value = "b" } }));
}
