//! 版本化 JSONL 审计事件。daemon 是唯一 writer，CLI 只读。
//!
//! `boot_session_id` 和 `daemon_instance_id` 是 M2.5.1 保留关联字段：前者关联
//! 同一次节点启动，后者标记进程重启边界。调用者不能自行注入 daemon id。

const std = @import("std");
const event_types = @import("event_types.zig");

pub const max_line_bytes = 8 * 1024;
pub const max_message_bytes = 2048;
pub const max_field_count = 32;
pub const max_field_key_bytes = 64;
pub const max_field_value_bytes = 1024;
pub const unix_timestamp_prefix = "unix:";

pub const Field = struct { key: []const u8, value: []const u8 };

/// daemon 写入的 Event v2。关联信息一律位于 `fields`，以保持事件类型稳定。
pub const Event = struct {
    v: u8 = 2,
    ts: []const u8,
    type: []const u8,
    message: []const u8,
    fields: []const Field = &.{},
};

/// 版本无关的读取器表示。v1 在当前写入格式中没有 `fields`，
/// 但旧的手动创建记录可能保留顶层 node 字段。
pub const ReadEvent = struct {
    v: u8 = 1,
    ts: []const u8,
    type: []const u8,
    message: []const u8 = "",
    fields: []const Field = &.{},
    node: ?[]const u8 = null,
};

/// 进程内唯一序列化器。
///
/// mutex 覆盖渲染后的大小检查、轮转和追加，避免并发协议 worker 覆盖文件尾部；
/// 每条 daemon 事件自动附加同一个 `daemon_instance_id`，供 trace 区分重启。
pub const Writer = struct {
    mutex: std.atomic.Mutex = .unlocked,
    max_size_bytes: u64 = 100 * 1024 * 1024,
    keep: u8 = 5,
    daemon_instance_id: ?[32]u8 = null,

    pub fn configure(self: *Writer, max_size_mb: u16, keep: u8) void {
        self.max_size_bytes = @as(u64, max_size_mb) * 1024 * 1024;
        self.keep = keep;
    }

    /// 配置注入到每条 daemon 事件的进程身份标识。调用方不能提供或覆盖此字段。
    pub fn setDaemonInstanceId(self: *Writer, value: [32]u8) !void {
        if (!validCorrelationId(&value)) return error.InvalidDaemonInstanceId;
        self.daemon_instance_id = value;
    }

    /// v1 fixture 生产者的兼容入口。新 daemon 代码必须调用 `appendWithFields`，
    /// 因此总是生成 Event v2。
    pub fn append(self: *Writer, io: std.Io, allocator: std.mem.Allocator, path: []const u8, event: Event) !void {
        try self.appendWithFields(io, allocator, path, event.type, event.message, event.fields);
    }

    /// 校验字段、注入 daemon instance、轮转并原子地追加一行 JSONL。
    ///
    /// 该方法是新 daemon 代码唯一可用的追加入口；保留 `append` 仅为旧 fixture
    /// 兼容，不能用它绕过关联字段校验。
    pub fn appendWithFields(
        self: *Writer,
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        event_type: []const u8,
        message: []const u8,
        fields: []const Field,
    ) !void {
        try validateFields(event_type, message, fields, false);
        var rendered_fields: [max_field_count]Field = undefined;
        var stored_fields = fields;
        if (self.daemon_instance_id) |instance_id| {
            if (fields.len == max_field_count) return error.TooManyFields;
            @memcpy(rendered_fields[0..fields.len], fields);
            rendered_fields[fields.len] = .{ .key = "daemon_instance_id", .value = &instance_id };
            stored_fields = rendered_fields[0 .. fields.len + 1];
            try validateFields(event_type, message, stored_fields, true);
        }
        var timestamp: [20]u8 = undefined;
        const ts = try rfc3339Now(&timestamp);
        const event = Event{ .ts = ts, .type = event_type, .message = message, .fields = stored_fields };
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try std.json.Stringify.value(event, .{}, &output.writer);
        try output.writer.writeByte('\n');
        if (output.written().len > max_line_bytes) return error.EventTooLarge;

        // 自旋等待 mutex；事件追加是短临界区（序列化已完成），自旋比 futex 更高效。
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

/// 对外暴露的事件校验入口。校验事件类型、消息长度、字段格式和保留字段规则。
/// 不包含 daemon instance id 注入逻辑，用于 HTTP API 等外部入口。
pub fn validate(event_type: []const u8, message: []const u8, fields: []const Field) !void {
    try validateFields(event_type, message, fields, false);
}

/// 内部校验实现。`allow_daemon_instance` 控制是否允许 `daemon_instance_id`
/// 字段——只有 Writer 内部注入时才为 true。
fn validateFields(event_type: []const u8, message: []const u8, fields: []const Field, allow_daemon_instance: bool) !void {
    if (event_types.fromName(event_type) == null) return error.UnknownEventType;
    if (message.len > max_message_bytes) return error.MessageTooLong;
    if (fields.len > max_field_count) return error.TooManyFields;
    for (fields, 0..) |field, index| {
        if (!validFieldKey(field.key)) return error.InvalidFieldKey;
        if (field.value.len > max_field_value_bytes) return error.FieldValueTooLong;
        try validateReservedField(field, allow_daemon_instance);
        for (fields[index + 1 ..]) |other|
            if (std.mem.eql(u8, field.key, other.key)) return error.DuplicateFieldKey;
    }
}

/// 校验保留字段（boot_session_id、daemon_instance_id、session_link_state）
/// 的格式和权限。`daemon_instance_id` 只有在 Writer 内部注入时才被允许。
fn validateReservedField(field: Field, allow_daemon_instance: bool) !void {
    if (std.mem.eql(u8, field.key, "boot_session_id")) {
        if (!validCorrelationId(field.value)) return error.InvalidBootSessionId;
        return;
    }
    if (std.mem.eql(u8, field.key, "daemon_instance_id")) {
        if (!allow_daemon_instance) return error.ReservedField;
        if (!validCorrelationId(field.value)) return error.InvalidDaemonInstanceId;
        return;
    }
    if (std.mem.eql(u8, field.key, "session_link_state") and !validSessionLinkState(field.value)) return error.InvalidSessionLinkState;
}

/// 校验 session 与 daemon id 共用的 32 位小写十六进制编码。
pub fn validCorrelationId(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    return true;
}

/// 校验无法安全关联时允许写入的、面向运维的稳定降级原因。
pub fn validSessionLinkState(value: []const u8) bool {
    return std.mem.eql(u8, value, "capacity.exhausted") or
        std.mem.eql(u8, value, "capacity_exhausted") or // legacy event spelling
        std.mem.eql(u8, value, "no_active_lease_match") or
        std.mem.eql(u8, value, "ambiguous_lease_match");
}

/// 校验字段 key 格式：以小写字母开头，只含小写字母、数字和下划线，长度 1-64。
pub fn validFieldKey(key: []const u8) bool {
    if (key.len == 0 or key.len > max_field_key_bytes or key[0] < 'a' or key[0] > 'z') return false;
    for (key[1..]) |byte|
        if (!((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '_')) return false;
    return true;
}

/// 在追加前检查文件大小并在超过 `max_size` 时执行轮转。
/// 轮转策略：删除最旧的 `.{keep}` 文件，将 `.{n}` 重命名为 `.{n+1}`，
/// 最后将当前文件重命名为 `.1`。文件不存在时静默跳过。
fn rotateBeforeAppend(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_size: u64, keep: u8, line_len: usize) !void {
    const dir = std.Io.Dir.cwd();
    const current_size: u64 = blk: {
        var file = dir.openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk 0,
            else => return err,
        };
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

/// 获取当前时间的 RFC 3339 UTC 时间戳（秒精度，20 字节固定缓冲区）。
pub fn rfc3339Now(buffer: *[20]u8) ![]const u8 {
    var clock: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &clock)) != .SUCCESS) return error.ClockUnavailable;
    return rfc3339FromUnix(buffer, clock.sec);
}

/// 将 Unix 时间戳（秒）格式化为 RFC 3339 UTC 字符串（`YYYY-MM-DDTHH:MM:SSZ`）。
/// 负时间戳返回 `InvalidTimestamp`。
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
    try validate("dhcp.ack", "sent ACK", &.{.{ .key = "mac", .value = "52:54:00:aa:bb:cc" }});
    try std.testing.expectError(error.DuplicateFieldKey, validate("dhcp.ack", "sent ACK", &.{ .{ .key = "mac", .value = "a" }, .{ .key = "mac", .value = "b" } }));
    try validate("dhcp.ack", "sent ACK", &.{.{ .key = "boot_session_id", .value = "0123456789abcdef0123456789abcdef" }});
    try std.testing.expectError(error.InvalidBootSessionId, validate("dhcp.ack", "sent ACK", &.{.{ .key = "boot_session_id", .value = "not-a-session" }}));
    try std.testing.expectError(error.ReservedField, validate("dhcp.ack", "sent ACK", &.{.{ .key = "daemon_instance_id", .value = "0123456789abcdef0123456789abcdef" }}));
    try std.testing.expectError(error.InvalidSessionLinkState, validate("dhcp.ack", "sent ACK", &.{.{ .key = "session_link_state", .value = "guess" }}));
}
