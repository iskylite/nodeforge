//! NodeForge M1.5 的 typed human view renderer。
//!
//! 每个函数只将已获得的领域事实映射为表格或详情块；不读取磁盘、不访问 daemon，
//! 因此 human 输出绝不会改变 JSON 事实、状态或错误路径。

const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const table = @import("table.zig");
const model = @import("../model.zig");

pub const AssetRow = struct { name: []const u8, kind: []const u8, path: []const u8 };
pub const TftpSessionRow = struct { id: []const u8, phase: []const u8, filename: []const u8 };
pub const DhcpLeaseRow = struct { ip: []const u8, mac: []const u8, phase: []const u8, expires_at: []const u8 };
pub const NodeRow = struct { id: []const u8, mac: []const u8, ip: []const u8, profile: []const u8, status: []const u8, started_at: []const u8, finished_at: []const u8, serial_number: []const u8 };
pub const ProfileRow = struct { name: []const u8, mode: []const u8, distro: []const u8, version: []const u8, arch: []const u8, install_source: []const u8, nodes: []const u8, valid: []const u8 };
pub const EventRow = struct { ts: []const u8, event_type: []const u8, node: []const u8, message: []const u8, fields: []const u8 };
pub const EventTypeRow = struct { name: []const u8, description: []const u8, level: []const u8 };

/// 渲染 asset 列表表格。`rows` 使用借用 slice；超过 64 行返回 `error.TooManyRows`。
pub fn assets(writer: *std.Io.Writer, rows: []const AssetRow) !void {
    const columns = [_]table.Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "kind", .title = "KIND" }, .{ .key = "path", .title = "PATH" } };
    var cells: [64][3][]const u8 = undefined;
    var table_rows: [64]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, i| {
        cells[i] = .{ row.name, row.kind, row.path };
        table_rows[i] = .{ .cells = &cells[i] };
    }
    try table.render(writer, &columns, table_rows[0..rows.len], "No assets registered.", .{});
}

pub fn assetDetail(writer: *std.Io.Writer, name: []const u8, kind: []const u8, path: []const u8, sha256: []const u8) !void {
    try writer.writeAll("Asset\n");
    try detailField(writer, "Name", name);
    try detailField(writer, "Kind", kind);
    try detailField(writer, "Path", path);
    try detailField(writer, "SHA-256", sha256);
}

pub fn tftpCounters(writer: *std.Io.Writer, started: u64, completed: u64, failed: u64) !void {
    try writer.writeAll("TFTP\n");
    try writeLabel(writer, "Started");
    try writer.print("{d}\n", .{started});
    try writeLabel(writer, "Completed");
    try writer.print("{d}\n", .{completed});
    try writeLabel(writer, "Failed");
    try writer.print("{d}\n", .{failed});
}

pub fn dhcpConfig(writer: *std.Io.Writer, subnet: []const u8, pool_start: []const u8, pool_end: []const u8, lease_seconds: u32) !void {
    try writer.writeAll("DHCP\n");
    try detailField(writer, "Subnet", subnet);
    try writeLabel(writer, "Pool");
    try writer.print("{s}-{s}\n", .{ pool_start, pool_end });
    try writeLabel(writer, "Lease seconds");
    try writer.print("{d}\n", .{lease_seconds});
}

pub fn dhcpLeases(writer: *std.Io.Writer, rows: []const DhcpLeaseRow, unknown_only: bool) !void {
    const columns = [_]table.Column{ .{ .key = "ip", .title = "IP" }, .{ .key = "mac", .title = "MAC" }, .{ .key = "phase", .title = "PHASE" }, .{ .key = "expires", .title = "EXPIRES" } };
    var cells: [256][4][]const u8 = undefined;
    var table_rows: [256]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, i| {
        cells[i] = .{ row.ip, row.mac, row.phase, row.expires_at };
        table_rows[i] = .{ .cells = &cells[i] };
    }
    try table.render(writer, &columns, table_rows[0..rows.len], if (unknown_only) "No unknown clients." else "No DHCP leases.", .{});
}

pub fn nodes(writer: *std.Io.Writer, rows: []const NodeRow) !void {
    // 节点列表展示部署开始/结束时间窗口（STARTED/FINISHED）；成功的
    // deployed 时间与 finished 重合，作为详情留给 `node show`，列表不再单独列出。
    const columns = [_]table.Column{ .{ .key = "id", .title = "ID" }, .{ .key = "mac", .title = "MAC" }, .{ .key = "ip", .title = "IP" }, .{ .key = "profile", .title = "PROFILE" }, .{ .key = "status", .title = "STATUS" }, .{ .key = "started_at", .title = "STARTED" }, .{ .key = "finished_at", .title = "FINISHED" }, .{ .key = "sn", .title = "SN" } };
    var cells: [256][8][]const u8 = undefined;
    var table_rows: [256]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, i| {
        cells[i] = .{ row.id, row.mac, row.ip, row.profile, row.status, row.started_at, row.finished_at, row.serial_number };
        table_rows[i] = .{ .cells = &cells[i] };
    }
    try table.render(writer, &columns, table_rows[0..rows.len], "No nodes registered.", .{});
}

pub fn profiles(writer: *std.Io.Writer, rows: []const ProfileRow) !void {
    const columns = [_]table.Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "mode", .title = "MODE" }, .{ .key = "distro", .title = "DISTRO" }, .{ .key = "version", .title = "VERSION" }, .{ .key = "arch", .title = "ARCH" }, .{ .key = "source", .title = "INSTALL_SOURCE" }, .{ .key = "nodes", .title = "NODES", .alignment = .right }, .{ .key = "valid", .title = "VALID" } };
    var cells: [256][8][]const u8 = undefined;
    var table_rows: [256]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, index| {
        cells[index] = .{ row.name, row.mode, row.distro, row.version, row.arch, row.install_source, row.nodes, row.valid };
        table_rows[index] = .{ .cells = &cells[index] };
    }
    try table.render(writer, &columns, table_rows[0..rows.len], "No profiles configured.", .{});
}

pub fn events(writer: *std.Io.Writer, rows: []const EventRow) !void {
    const columns = [_]table.Column{ .{ .key = "time", .title = "TIME" }, .{ .key = "type", .title = "TYPE" }, .{ .key = "node", .title = "NODE" }, .{ .key = "message", .title = "MESSAGE", .max_width = 48 }, .{ .key = "fields", .title = "FIELDS", .max_width = 64 } };
    var cells: [1000][5][]const u8 = undefined;
    var table_rows: [1000]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, index| {
        cells[index] = .{ row.ts, row.event_type, row.node, row.message, row.fields };
        table_rows[index] = .{ .cells = &cells[index] };
    }
    try table.render(writer, &columns, table_rows[0..rows.len], "No events recorded.", .{});
}

pub fn eventLine(writer: *std.Io.Writer, ts: []const u8, event_type: []const u8, fields: []const u8, message: []const u8) !void {
    try writer.print("{s}  {s}", .{ ts, event_type });
    if (fields.len != 0) try writer.print("  {s}", .{fields});
    try writer.print("  {s}\n", .{message});
}

pub fn eventTypes(writer: *std.Io.Writer, rows: []const EventTypeRow) !void {
    const columns = [_]table.Column{ .{ .key = "name", .title = "TYPE" }, .{ .key = "level", .title = "LEVEL" }, .{ .key = "description", .title = "DESCRIPTION" } };
    var cells: [64][3][]const u8 = undefined;
    var table_rows: [64]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, index| {
        cells[index] = .{ row.name, row.level, row.description };
        table_rows[index] = .{ .cells = &cells[index] };
    }
    try table.render(writer, &columns, table_rows[0..rows.len], "No event types registered.", .{});
}

/// 输出统一的成功摘要和可选键值事实。短摘要保留已有 `OK` 运维习惯，字段
/// 则使用与详情页相同的对齐规则，避免 validate/import 等命令继续手写空格。
pub fn success(writer: *std.Io.Writer, summary: []const u8, fields: []const Field) !void {
    try writer.print("OK {s}\n", .{summary});
    for (fields) |field| try detailField(writer, field.label, field.value);
}

pub const Field = struct { label: []const u8, value: []const u8 };

/// M4.2: 渲染单个节点的详情块（分组键值）。
pub fn nodeDetail(writer: *std.Io.Writer, node: model.NodeConfig) !void {
    try writer.print("Node {s}\n", .{node.id});
    try detailField(writer, "MAC", node.mac);
    try detailField(writer, "Arch", @tagName(node.arch));
    try detailField(writer, "Profile", node.profile);
    try detailField(writer, "IP", node.ip orelse "-");
    try detailField(writer, "Hostname", node.hostname orelse "-");
    try detailField(writer, "Deploy", if (node.deploy) "true" else "false");
    try detailField(writer, "HTTP accel", if (node.http_accel) "true" else "false");
}

/// check 失败时仍使用人类可读的状态块；它与 `status` 共享字段对齐而不改变退出码。
pub fn checkFailure(writer: *std.Io.Writer, process: bool, http: bool, management: bool, config: bool) !void {
    try writer.writeAll("FAIL nodeforge checks failed\n");
    try detailField(writer, "Process", if (process) "OK" else "FAIL");
    try detailField(writer, "HTTP", if (http) "OK" else "FAIL");
    try detailField(writer, "Management", if (management) "OK" else "FAIL");
    try detailField(writer, "Config API", if (config) "OK" else "FAIL");
}

/// 渲染 TFTP 会话列表表格。`rows` 使用借用 slice；超过 32 行返回 `error.TooManyRows`。
pub fn tftpSessions(writer: *std.Io.Writer, rows: []const TftpSessionRow) !void {
    const columns = [_]table.Column{ .{ .key = "id", .title = "ID", .alignment = .right }, .{ .key = "phase", .title = "PHASE" }, .{ .key = "filename", .title = "FILENAME" } };
    var cells: [32][3][]const u8 = undefined;
    var table_rows: [32]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, i| {
        cells[i] = .{ row.id, row.phase, row.filename };
        table_rows[i] = .{ .cells = &cells[i] };
    }
    try table.render(writer, &columns, table_rows[0..rows.len], "No TFTP sessions recorded.", .{});
}

pub fn status(writer: *std.Io.Writer, process: bool, http: bool, management: bool, config: bool, server_ip: []const u8, port: u16) !void {
    try writer.writeAll("NodeForge status\n");
    try writeLabel(writer, "Process");
    try writer.print("{s}\n", .{if (process) "OK reachable" else "FAIL unreachable"});
    try writeLabel(writer, "HTTP");
    try writer.print("{s} http://", .{if (http) "OK healthy" else "FAIL unhealthy"});
    try table.writeEscaped(writer, server_ip);
    try writer.print(":{d}\n", .{port});
    try writeLabel(writer, "Management");
    try writer.print("{s} http://127.0.0.1:{d}\n", .{ if (management) "OK route" else "FAIL route", port });
    try writeLabel(writer, "Config API");
    try writer.print("{s}\n", .{if (config) "OK config valid" else "FAIL config unavailable"});
}

/// 将 epoch 秒格式化为宿主机本地时间。CLI human 输出使用 24 小时制并遵循
/// 系统时区；结构化 JSON/API 和 Event v2 仍保持 UTC 时间语义。
/// 0 或负值（未发生）返回 "-"。
pub fn formatTimestamp(buffer: *[20]u8, epoch: i64) []const u8 {
    if (epoch <= 0) return "-";
    var seconds: c.time_t = @intCast(epoch);
    var local: c.struct_tm = undefined;
    if (c.localtime_r(&seconds, &local) == null) return "-";
    const length = c.strftime(buffer, buffer.len, "%Y-%m-%d %H:%M:%S", &local);
    if (length != 19) return "-";
    return buffer[0..length];
}

/// 所有详情/状态块的 label 统一缩进和对齐宽度。使用 display-width-aware 填充，
/// 确保包含 CJK 字符的 label 也能正确对齐。
const label_width: usize = 12;

/// 写入 label 并用空格填充到 `label_width`，末尾留一个分隔空格。
fn writeLabel(writer: *std.Io.Writer, label: []const u8) !void {
    try writer.writeAll("  ");
    try writer.writeAll(label);
    const visible = table.displayWidth(label);
    if (label_width > visible) {
        for (0..label_width - visible) |_| try writer.writeByte(' ');
    }
    try writer.writeByte(' ');
}

fn detailField(writer: *std.Io.Writer, label: []const u8, value: []const u8) !void {
    try writeLabel(writer, label);
    try table.writeEscaped(writer, value);
    try writer.writeByte('\n');
}

test "formatTimestamp renders local 24-hour visualization time" {
    var buffer: [20]u8 = undefined;
    const rendered = formatTimestamp(&buffer, 1783758600);
    try std.testing.expectEqual(@as(usize, 19), rendered.len);
    try std.testing.expectEqual(@as(u8, '-'), rendered[4]);
    try std.testing.expectEqual(@as(u8, '-'), rendered[7]);
    try std.testing.expectEqual(@as(u8, ' '), rendered[10]);
    try std.testing.expectEqual(@as(u8, ':'), rendered[13]);
    try std.testing.expectEqual(@as(u8, ':'), rendered[16]);
    try std.testing.expectEqualStrings("-", formatTimestamp(&buffer, 0));
    try std.testing.expectEqualStrings("-", formatTimestamp(&buffer, -1));
}

test "node list table shows deployment start and end columns" {
    const columns = [_]table.Column{ .{ .key = "id", .title = "ID" }, .{ .key = "started_at", .title = "STARTED" }, .{ .key = "finished_at", .title = "FINISHED" } };
    const cells = [_][]const u8{ "node-01", "2026-07-11 16:30:00", "2026-07-11 16:45:00" };
    const rows = [_]table.Row{.{ .cells = &cells }};
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try table.render(&writer, &columns, &rows, "empty", .{});
    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "STARTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FINISHED") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "2026-07-11 16:30:00") != null);
}
