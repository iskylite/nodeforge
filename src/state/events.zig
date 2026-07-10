//! JSONL 事件追加写入器。
//! M0 单进程内串行调用；后续并发服务必须通过单 writer 队列调用本模块。
//! 事件文件是追加写日志，不是当前状态事实源——状态查询应走 `state/runtime.zig`。

const std = @import("std");

pub const Event = struct {
    /// 事件信封版本；当前固定为 1。
    v: u8 = 1,
    /// ISO 8601 UTC 时间戳字符串。
    timestamp: []const u8,
    /// 事件类型，例如 `service.started`、`dhcp.lease.allocated`。
    event_type: []const u8,
    /// 人类可读的事件摘要。
    message: []const u8,
};

/// 以单行 JSON 追加事件。
///
/// 先完整渲染一行，再进行一次 positional write，避免半个 JSON 对象跨多次写入。
/// M0 不在这里执行日志轮转，也不把事件文件当作当前状态事实源。
pub fn append(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    event: Event,
) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(event, .{}, &output.writer);
    try output.writer.writeByte('\n');

    const dir = std.Io.Dir.cwd();
    var file = dir.openFile(io, path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try dir.createFile(io, path, .{ .read = true, .truncate = false }),
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    try file.writePositionalAll(io, output.written(), stat.size);
}

test "event renders as one JSON line" {
    const allocator = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(Event{
        .timestamp = "2026-07-09T12:00:00Z",
        .event_type = "service.started",
        .message = "ready",
    }, .{}, &output.writer);
    try output.writer.writeByte('\n');

    try std.testing.expectEqual(@as(u8, '\n'), output.written()[output.written().len - 1]);
    try std.testing.expect(std.mem.count(u8, output.written(), "\n") == 1);
}
