//! Process-wide std.log backend with runtime severity threshold, bounded
//! rendering, stderr + optional file dual sink, rotation and degradation.
//!
//! The backend renders each record into an 8 KiB stack buffer. When the
//! formatted message exceeds the budget the line is truncated with
//! `… [truncated]`. A sink mutex covers stderr and file writes so the two
//! sinks always receive the same complete line. File rotation is based on
//! `max_size_mb` and `keep`; on repeated file-write failures the backend
//! degrades to stderr-only and emits a throttled diagnostic.

const std = @import("std");
const events = @import("../state/events.zig");

pub const max_line_bytes = 8 * 1024;
const truncation_suffix = "… [truncated]";

var threshold = std.atomic.Value(u8).init(@intFromEnum(std.log.Level.info));
var sink_mutex: std.atomic.Mutex = .unlocked;
var file_backend: ?FileSink = null;
var config_io: ?std.Io = null;

pub fn setLevel(level: std.log.Level) void {
    threshold.store(@intFromEnum(level), .release);
}

pub fn enabled(comptime level: std.log.Level) bool {
    return @intFromEnum(level) <= threshold.load(.acquire);
}

/// Configures the optional file sink. Called once at daemon startup before
/// workers spawn; afterwards the pointer is read atomically without locking.
pub fn configureFileSink(io: std.Io, path: []const u8, max_size_mb: u16, keep: u8) void {
    while (!sink_mutex.tryLock()) std.Thread.yield() catch {};
    defer sink_mutex.unlock();
    config_io = io;
    file_backend = .{
        .path = path,
        .max_size_bytes = @as(u64, max_size_mb) * 1024 * 1024,
        .keep = keep,
    };
}

const FileSink = struct {
    path: []const u8,
    max_size_bytes: u64,
    keep: u8,
    degraded_count: u64 = 0,

    fn writeOrReportDegraded(self: *FileSink, io: std.Io, line: []const u8) void {
        self.writeLine(io, line) catch {
            self.degraded_count += 1;
            // Throttle: only report every 32 failures to avoid recursive noise.
            if (self.degraded_count % 32 == 1) {
                const msg = "log_backend: file sink degraded, falling back to stderr\n";
                _ = std.posix.system.write(2, msg.ptr, msg.len);
            }
            // After enough failures, disable the file sink entirely.
            if (self.degraded_count > 1000) {
                file_backend = null;
            }
        };
    }

    fn writeLine(self: *FileSink, io: std.Io, line: []const u8) !void {
        const dir = std.Io.Dir.cwd();
        try rotateIfNeeded(io, dir, self.path, self.max_size_bytes, self.keep, line.len);
        var file = dir.openFile(io, self.path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try dir.createFile(io, self.path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        defer file.close(io);
        const stat = try file.stat(io);
        try file.writePositionalAll(io, line, stat.size);
    }
};

fn rotateIfNeeded(io: std.Io, dir: std.Io.Dir, path: []const u8, max_size: u64, keep: u8, line_len: usize) !void {
    const current_size: u64 = blk: {
        var file = dir.openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk 0,
            else => return err,
        };
        defer file.close(io);
        break :blk (try file.stat(io)).size;
    };
    if (current_size == 0 or current_size + line_len <= max_size) return;

    var oldest_buf: [512]u8 = undefined;
    const oldest = try std.fmt.bufPrint(&oldest_buf, "{s}.{d}", .{ path, keep });
    dir.deleteFile(io, oldest) catch |err| if (err != error.FileNotFound) return err;

    var index: u8 = keep;
    while (index > 1) : (index -= 1) {
        var src_buf: [512]u8 = undefined;
        var dst_buf: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&src_buf, "{s}.{d}", .{ path, index - 1 });
        const destination = try std.fmt.bufPrint(&dst_buf, "{s}.{d}", .{ path, index });
        std.Io.Dir.rename(dir, source, dir, destination, io) catch |err| if (err != error.FileNotFound) return err;
    }
    var first_buf: [512]u8 = undefined;
    const first = try std.fmt.bufPrint(&first_buf, "{s}.1", .{path});
    try std.Io.Dir.rename(dir, path, dir, first, io);
}

/// Renders a log line into `buf` with timestamp, level and scope prefix.
/// Truncates with `… [truncated]` if the formatted output exceeds `max_line_bytes`.
fn renderLogLineBounded(
    buf: *[max_line_bytes]u8,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) []const u8 {
    var timestamp: [20]u8 = undefined;
    const stamp = events.rfc3339Now(&timestamp) catch return buf[0..0];

    // Build the prefix: "<timestamp> <level> [<scope>] "
    const prefix = std.fmt.bufPrint(buf, "{s} {s} [{s}] ", .{ stamp, @tagName(level), @tagName(scope) }) catch return buf[0..0];
    const prefix_len = prefix.len;

    // Reserve space for truncation suffix at the boundary.
    const reserve = if (max_line_bytes > prefix_len + truncation_suffix.len + 1)
        max_line_bytes - truncation_suffix.len - 1
    else
        max_line_bytes;

    // Format the message into the remaining sub-buffer.
    var sub: std.Io.Writer = .fixed(buf[prefix_len..reserve]);
    sub.print(format, args) catch {
        const written = prefix_len + sub.buffered().len;
        const tail = truncation_suffix ++ "\n";
        const remaining = buf.len - written;
        if (tail.len <= remaining) {
            @memcpy(buf[written .. written + tail.len], tail);
            return buf[0 .. written + tail.len];
        }
        // Extreme edge: not enough space even for the suffix.
        buf[written] = '\n';
        return buf[0 .. written + 1];
    };

    const total = prefix_len + sub.buffered().len;
    buf[total] = '\n';
    return buf[0 .. total + 1];
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!enabled(level)) return;

    var buf: [max_line_bytes]u8 = undefined;
    const line = renderLogLineBounded(&buf, level, scope, format, args);

    // The sink mutex covers stderr and file writes atomically so the two
    // sinks always receive the same complete line.
    while (!sink_mutex.tryLock()) std.Thread.yield() catch {};
    defer sink_mutex.unlock();

    // stderr sink — direct write to fd 2.
    _ = std.posix.system.write(2, line.ptr, line.len);

    // Optional file sink.
    if (file_backend) |*backend| {
        const io = config_io orelse return;
        backend.writeOrReportDegraded(io, line);
    }
}
