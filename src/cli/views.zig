//! NodeForge M1.5 的 typed human view renderer。
//!
//! 每个函数只将已获得的领域事实映射为表格或详情块；不读取磁盘、不访问 daemon，
//! 因此 human 输出绝不会改变 JSON 事实、状态或错误路径。

const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const table = @import("table.zig");
const output = @import("output.zig");
const document = @import("document.zig");
const model = @import("../model.zig");

/// asset 列表表格的单行数据。所有字段为预格式化字符串，由调用者负责格式化。
pub const AssetRow = struct { name: []const u8, kind: []const u8, path: []const u8 };
/// TFTP 会话列表表格的单行数据。
pub const TftpSessionRow = struct { id: []const u8, phase: []const u8, filename: []const u8 };
/// DHCP 租约列表表格的单行数据。`expires_at` 为预格式化的本地时间字符串。
pub const DhcpLeaseRow = struct { ip: []const u8, mac: []const u8, phase: []const u8, expires_at: []const u8 };
/// 节点列表表格的单行数据。start/install/finished 分别映射任务武装、安装开始和终态时间。
pub const NodeRow = struct { id: []const u8, mac: []const u8, ip: []const u8, profile: []const u8, deploy: []const u8, install_intent: []const u8, status: []const u8, start_at: []const u8, install_at: []const u8, finished_at: []const u8, serial_number: []const u8 };
/// profile 列表表格的单行数据。`nodes` 为关联节点计数，`valid` 为校验状态文本。
pub const ProfileRow = struct { name: []const u8, mode: []const u8, distro: []const u8, version: []const u8, arch: []const u8, install_source: []const u8, nodes: []const u8, valid: []const u8 };
/// 事件列表表格的单行数据。`fields` 为预格式化的 `key=value key=value` 字符串。
pub const EventRow = struct { ts: []const u8, event_type: []const u8, node: []const u8, message: []const u8, fields: []const u8 };
/// 事件类型列表表格的单行数据。
pub const EventTypeRow = struct { name: []const u8, description: []const u8, level: []const u8 };

/// 渲染 asset 列表表格。`rows` 使用借用 slice；超过 64 行返回 `error.TooManyRows`。
pub fn assets(writer: *std.Io.Writer, rows: []const AssetRow) !void {
    return assetsWithOptions(writer, rows, .{});
}
pub fn assetsWithOptions(writer: *std.Io.Writer, rows: []const AssetRow, options: table.Options) !void {
    const columns = [_]table.Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "kind", .title = "KIND" }, .{ .key = "path", .title = "PATH" } };
    var cells: [64][3][]const u8 = undefined;
    var table_rows: [64]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, i| {
        cells[i] = .{ row.name, row.kind, row.path };
        table_rows[i] = .{ .cells = &cells[i] };
    }
    try renderTableDocument(writer, &columns, table_rows[0..rows.len], "No assets registered.", options);
}

/// 渲染 asset 详情块。以标签-值形式展示名称、类型、路径和 SHA-256 校验值。
pub fn assetDetail(writer: *std.Io.Writer, name: []const u8, kind: []const u8, path: []const u8, sha256: []const u8) !void {
    try writer.writeAll("Asset\n");
    try detailField(writer, "Name", name);
    try detailField(writer, "Kind", kind);
    try detailField(writer, "Path", path);
    try detailField(writer, "SHA-256", sha256);
}

/// 渲染 TFTP 传输计数器详情块。展示已启动、已完成和失败的传输总数。
pub fn tftpCounters(writer: *std.Io.Writer, started: u64, completed: u64, failed: u64) !void {
    try writer.writeAll("TFTP\n");
    try writeLabel(writer, "Started");
    try writer.print("{d}\n", .{started});
    try writeLabel(writer, "Completed");
    try writer.print("{d}\n", .{completed});
    try writeLabel(writer, "Failed");
    try writer.print("{d}\n", .{failed});
}

/// 渲染 DHCP 配置详情块。展示子网、地址池范围和租约时长。
pub fn dhcpConfig(writer: *std.Io.Writer, subnet: []const u8, pool_start: []const u8, pool_end: []const u8, lease_seconds: u32) !void {
    try writer.writeAll("DHCP\n");
    try detailField(writer, "Subnet", subnet);
    try writeLabel(writer, "Pool");
    try writer.print("{s}-{s}\n", .{ pool_start, pool_end });
    try writeLabel(writer, "Lease seconds");
    try writer.print("{d}\n", .{lease_seconds});
}

/// 渲染 DHCP 租约列表表格。`unknown_only` 控制空表提示消息。
pub fn dhcpLeases(writer: *std.Io.Writer, rows: []const DhcpLeaseRow, unknown_only: bool) !void {
    return dhcpLeasesWithOptions(writer, rows, unknown_only, .{});
}
/// 渲染 DHCP 租约列表表格（带选项）。超过 256 行返回 `error.TooManyRows`。
pub fn dhcpLeasesWithOptions(writer: *std.Io.Writer, rows: []const DhcpLeaseRow, unknown_only: bool, options: table.Options) !void {
    const columns = [_]table.Column{ .{ .key = "ip", .title = "IP" }, .{ .key = "mac", .title = "MAC" }, .{ .key = "phase", .title = "PHASE" }, .{ .key = "expires", .title = "EXPIRES" } };
    var cells: [256][4][]const u8 = undefined;
    var table_rows: [256]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, i| {
        cells[i] = .{ row.ip, row.mac, row.phase, row.expires_at };
        table_rows[i] = .{ .cells = &cells[i] };
    }
    try renderTableDocument(writer, &columns, table_rows[0..rows.len], if (unknown_only) "No unknown clients." else "No DHCP leases.", options);
}

/// 渲染节点列表表格。使用默认选项（无列筛选、无宽度限制）。
pub fn nodes(writer: *std.Io.Writer, rows: []const NodeRow) !void {
    return nodesWithOptions(writer, rows, .{});
}
/// 渲染节点列表表格（带选项）。超过 256 行返回 `error.TooManyRows`。
pub fn nodesWithOptions(writer: *std.Io.Writer, rows: []const NodeRow, options: table.Options) !void {
    // Start/Install/Finished 分别映射任务武装、实际安装阶段开始和任务终态，
    // 避免把内部 requested_at/started_at 字段名误当成用户语义。
    const columns = [_]table.Column{ .{ .key = "id", .title = "ID" }, .{ .key = "mac", .title = "MAC" }, .{ .key = "ip", .title = "IP" }, .{ .key = "profile", .title = "PROFILE" }, .{ .key = "deploy", .title = "DEPLOY" }, .{ .key = "intent", .title = "INSTALL_INTENT" }, .{ .key = "status", .title = "STATUS" }, .{ .key = "start_at", .title = "START" }, .{ .key = "install_at", .title = "INSTALL" }, .{ .key = "finished_at", .title = "FINISHED" }, .{ .key = "sn", .title = "SN" } };
    var cells: [256][11][]const u8 = undefined;
    var table_rows: [256]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, i| {
        cells[i] = .{ row.id, row.mac, row.ip, row.profile, row.deploy, row.install_intent, row.status, row.start_at, row.install_at, row.finished_at, row.serial_number };
        table_rows[i] = .{ .cells = &cells[i] };
    }
    try renderTableDocument(writer, &columns, table_rows[0..rows.len], "No nodes registered.", options);
}

/// 渲染 profile 列表表格。使用默认选项。
pub fn profiles(writer: *std.Io.Writer, rows: []const ProfileRow) !void {
    return profilesWithOptions(writer, rows, .{});
}
/// 渲染 profile 列表表格（带选项）。超过 256 行返回 `error.TooManyRows`。
pub fn profilesWithOptions(writer: *std.Io.Writer, rows: []const ProfileRow, options: table.Options) !void {
    const columns = [_]table.Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "mode", .title = "MODE" }, .{ .key = "distro", .title = "DISTRO" }, .{ .key = "version", .title = "VERSION" }, .{ .key = "arch", .title = "ARCH" }, .{ .key = "source", .title = "INSTALL_SOURCE" }, .{ .key = "nodes", .title = "NODES", .alignment = .right }, .{ .key = "valid", .title = "VALID" } };
    var cells: [256][8][]const u8 = undefined;
    var table_rows: [256]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, index| {
        cells[index] = .{ row.name, row.mode, row.distro, row.version, row.arch, row.install_source, row.nodes, row.valid };
        table_rows[index] = .{ .cells = &cells[index] };
    }
    try renderTableDocument(writer, &columns, table_rows[0..rows.len], "No profiles configured.", options);
}

/// 渲染事件列表表格。使用默认选项。MESSAGE 和 FIELDS 列有最大宽度限制。
pub fn events(writer: *std.Io.Writer, rows: []const EventRow) !void {
    return eventsWithOptions(writer, rows, .{});
}
/// 渲染事件列表表格（带选项）。超过 1000 行返回 `error.TooManyRows`。
pub fn eventsWithOptions(writer: *std.Io.Writer, rows: []const EventRow, options: table.Options) !void {
    const columns = [_]table.Column{ .{ .key = "time", .title = "TIME" }, .{ .key = "type", .title = "TYPE" }, .{ .key = "node", .title = "NODE" }, .{ .key = "message", .title = "MESSAGE", .max_width = 48 }, .{ .key = "fields", .title = "FIELDS", .max_width = 64 } };
    var cells: [1000][5][]const u8 = undefined;
    var table_rows: [1000]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, index| {
        cells[index] = .{ row.ts, row.event_type, row.node, row.message, row.fields };
        table_rows[index] = .{ .cells = &cells[index] };
    }
    try renderTableDocument(writer, &columns, table_rows[0..rows.len], "No events recorded.", options);
}

/// 渲染单行事件摘要。格式为 `时间  类型  [字段]  消息`，用于 follow 模式的实时输出。
pub fn eventLine(writer: *std.Io.Writer, ts: []const u8, event_type: []const u8, fields: []const u8, message: []const u8) !void {
    try writer.print("{s}  {s}", .{ ts, event_type });
    if (fields.len != 0) try writer.print("  {s}", .{fields});
    try writer.print("  {s}\n", .{message});
}

/// 渲染事件类型列表表格。使用默认选项。
pub fn eventTypes(writer: *std.Io.Writer, rows: []const EventTypeRow) !void {
    return eventTypesWithOptions(writer, rows, .{});
}
/// 渲染事件类型列表表格（带选项）。超过 64 行返回 `error.TooManyRows`。
pub fn eventTypesWithOptions(writer: *std.Io.Writer, rows: []const EventTypeRow, options: table.Options) !void {
    const columns = [_]table.Column{ .{ .key = "name", .title = "TYPE" }, .{ .key = "level", .title = "LEVEL" }, .{ .key = "description", .title = "DESCRIPTION" } };
    var cells: [64][3][]const u8 = undefined;
    var table_rows: [64]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, index| {
        cells[index] = .{ row.name, row.level, row.description };
        table_rows[index] = .{ .cells = &cells[index] };
    }
    try renderTableDocument(writer, &columns, table_rows[0..rows.len], "No event types registered.", options);
}

/// 输出统一的成功摘要和可选键值事实。短摘要保留已有 `OK` 运维习惯，字段
/// 则使用与详情页相同的对齐规则，避免 validate/import 等命令继续手写空格。
pub fn success(writer: *std.Io.Writer, summary: []const u8, fields: []const Field) !void {
    try writer.print("OK {s}\n", .{summary});
    for (fields) |field| try detailField(writer, field.label, field.value);
}

/// 成功摘要的键值对字段。`label` 为人类可读标签，`value` 为预格式化字符串。
pub const Field = struct { label: []const u8, value: []const u8 };

/// M4.11：将可变节点事实渲染为精确的 `node set` key=value
/// 词汇表。可选的缺失值描述为未设置，而非
/// 输出无效赋值（例如 `ip=-`）。
pub fn nodeDetail(writer: *std.Io.Writer, node: model.NodeConfig) !void {
    try writer.print("Node {s}\n", .{node.id});
    try writer.writeAll("\nSettable properties (nodeforge node set ");
    try table.writeEscaped(writer, node.id);
    try writer.writeAll(" key=value)\n");
    try writer.print("  mac={s}\n  arch={s}\n  profile={s}\n", .{ node.mac, @tagName(node.arch), node.profile orelse "<unassigned>" });
    if (node.ip) |ip| try writer.print("  ip={s}\n", .{ip}) else try writer.print("  # ip is unset; action: nodeforge node unset {s} ip\n", .{node.id});
    if (node.hostname) |hostname| try writer.print("  hostname={s}\n", .{hostname}) else try writer.print("  # hostname is unset; action: nodeforge node unset {s} hostname\n", .{node.id});
    try writer.print("  deploy={s}\n  http_accel={s}\n", .{ if (node.deploy) "true" else "false", if (node.http_accel) "true" else "false" });
    try writer.print("  storage.boot_disk={s}\n", .{node.storage.boot_disk});
    try writer.writeAll("  storage.additional_disks=");
    try writeCommaList(writer, node.storage.additional_disks);
    try writer.writeByte('\n');
    try writer.writeAll("\nRead-only detail\n");
    try writer.writeAll("  Network\n");
    try detailField(writer, "Mode", @tagName(node.network.mode));
    try detailField(writer, "Interface", node.network.interface orelse "-");
    try detailField(writer, "Address", node.network.address orelse "-");
    if (node.network.prefix_len) |prefix| {
        try writeLabel(writer, "Prefix length");
        try writer.print("{d}\n", .{prefix});
    } else try detailField(writer, "Prefix length", "-");
    try detailField(writer, "Gateway", node.network.gateway orelse "-");
    try writeStringList(writer, "DNS", node.network.dns);
    try writeStringList(writer, "Search domains", node.network.search_domains);
}

/// 写入标签和字符串列表。空列表输出 "-"，非空列表以逗号分隔并转义控制字符。
fn writeStringList(writer: *std.Io.Writer, label: []const u8, values: []const []const u8) !void {
    try writeLabel(writer, label);
    if (values.len == 0) return writer.writeAll("-\n");
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(", ");
        try table.writeEscaped(writer, value);
    }
    try writer.writeByte('\n');
}

/// 写入逗号分隔的字符串列表（无标签前缀）。用于 `storage.additional_disks` 等内联集合。
fn writeCommaList(writer: *std.Io.Writer, values: []const []const u8) !void {
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeByte(',');
        try table.writeEscaped(writer, value);
    }
}

/// 渲染 TFTP 会话列表表格。`rows` 使用借用 slice；超过 32 行返回 `error.TooManyRows`。
pub fn tftpSessions(writer: *std.Io.Writer, rows: []const TftpSessionRow) !void {
    return tftpSessionsWithOptions(writer, rows, .{});
}
pub fn tftpSessionsWithOptions(writer: *std.Io.Writer, rows: []const TftpSessionRow, options: table.Options) !void {
    const columns = [_]table.Column{ .{ .key = "id", .title = "ID", .alignment = .right }, .{ .key = "phase", .title = "PHASE" }, .{ .key = "filename", .title = "FILENAME" } };
    var cells: [32][3][]const u8 = undefined;
    var table_rows: [32]table.Row = undefined;
    if (rows.len > table_rows.len) return error.TooManyRows;
    for (rows, 0..) |row, i| {
        cells[i] = .{ row.id, row.phase, row.filename };
        table_rows[i] = .{ .cells = &cells[i] };
    }
    try renderTableDocument(writer, &columns, table_rows[0..rows.len], "No TFTP sessions recorded.", options);
}

/// 通过 `OutputDocument` 管道渲染表格，确保 human 表格输出与 JSON 输出走同一渲染路径。
fn renderTableDocument(writer: *std.Io.Writer, columns: []const table.Column, rows: []const table.Row, empty_message: []const u8, options: table.Options) !void {
    const value: document.OutputDocument = .{ .human = .{ .table = .{ .columns = columns, .rows = rows, .empty_message = empty_message } }, .json = "{}" };
    try value.render(writer, output.Output{ .mode = .human, .no_color = !options.color, .columns = options.columns, .width = options.width, .wide = options.wide, .no_header = options.no_header });
}

/// M4.11 运维就绪状态视图。每个字段对应一个必须检查的运维平面，
/// 确保绿色摘要意味着 nodeforged 真正能服务 provisioning 流量，
/// 而不仅仅是某个 HTTP 路由可达。
pub const StatusView = struct {
    ok: bool,
    process: bool,
    loopback_http: bool,
    advertised_http: bool,
    management_api: bool,
    active_config: bool,
    catalog_api: bool,
    dhcp_api: bool,
    tftp_api: bool,
    server_ip: []const u8,
    port: u16,
    tftp_started: u64,
    tftp_completed: u64,
    tftp_failed: u64,
};

/// 渲染单一的 M4.11 运行就绪视图。每个必需平面都
/// 显式列出，因此绿色摘要意味着 nodeforged 确实能对外提供
/// 置备流量，而非仅某个 HTTP 路由能应答。
pub fn status(writer: *std.Io.Writer, value: StatusView) !void {
    try writer.writeAll("NodeForge status\n");
    try statusField(writer, "Overall", if (value.ok) "OK nodeforged operational" else "FAIL nodeforged unavailable");
    try statusField(writer, "Process", if (value.process) "OK reachable" else "FAIL unreachable");
    try statusField(writer, "Loopback HTTP", if (value.loopback_http) "OK /healthz" else "FAIL /healthz");
    try writeStatusLabel(writer, "Advertised HTTP");
    try writer.print("{s} http://", .{if (value.advertised_http) "OK /healthz" else "FAIL /healthz"});
    try table.writeEscaped(writer, value.server_ip);
    try writer.print(":{d}\n", .{value.port});
    try statusField(writer, "Management API", if (value.management_api) "OK status route" else "FAIL status route");
    try statusField(writer, "Active config", if (value.active_config) "OK daemon validation" else "FAIL daemon validation");
    try statusField(writer, "Catalog API", if (value.catalog_api) "OK nodes + profiles" else "FAIL nodes/profiles");
    try statusField(writer, "DHCP API", if (value.dhcp_api) "OK leases route" else "FAIL leases route");
    try statusField(writer, "TFTP API", if (value.tftp_api) "OK runtime route" else "FAIL runtime route");
    try writeStatusLabel(writer, "TFTP transfers");
    try writer.print("started={d} completed={d} failed={d}\n", .{ value.tftp_started, value.tftp_completed, value.tftp_failed });
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
// 16 列可容纳最长的人可读详情标签（例如
// "Network override" 和 "Prefix length"），同时保持每个 key/value
// 块在各命令间对齐。
const label_width: usize = 16;

/// 写入 label 并用空格填充到 `label_width`，末尾留一个分隔空格。
/// 写入标签并用空格填充到 `label_width`，末尾留一个分隔空格。
/// 使用 display-width-aware 填充确保 CJK 字符也能正确对齐。
fn writeLabel(writer: *std.Io.Writer, label: []const u8) !void {
    try writer.writeAll("  ");
    try writer.writeAll(label);
    const visible = table.displayWidth(label);
    if (label_width > visible) {
        for (0..label_width - visible) |_| try writer.writeByte(' ');
    }
    try writer.writeByte(' ');
}

/// 写入详情字段行：标签 + 填充 + 转义值 + 换行。用于 asset/node 详情等块状输出。
fn detailField(writer: *std.Io.Writer, label: []const u8, value: []const u8) !void {
    try writeLabel(writer, label);
    try table.writeEscaped(writer, value);
    try writer.writeByte('\n');
}

const status_label_width: usize = label_width;

/// 写入状态标签并用空格填充到 `status_label_width`（不追加末尾空格）。
/// 状态行的值由调用者自行格式化（如含 OK/FAIL 前缀和 URL）。
fn writeStatusLabel(writer: *std.Io.Writer, label: []const u8) !void {
    try writer.writeAll("  ");
    try writer.writeAll(label);
    const visible = table.displayWidth(label);
    if (status_label_width > visible) {
        for (0..status_label_width - visible) |_| try writer.writeByte(' ');
    }
}

/// 写入状态字段行：标签 + 填充 + 转义值 + 换行。用于 status 命令的各检查项输出。
fn statusField(writer: *std.Io.Writer, label: []const u8, value: []const u8) !void {
    try writeStatusLabel(writer, label);
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

test "node list table shows task start install and finish columns" {
    const columns = [_]table.Column{ .{ .key = "id", .title = "ID" }, .{ .key = "start_at", .title = "START" }, .{ .key = "install_at", .title = "INSTALL" }, .{ .key = "finished_at", .title = "FINISHED" } };
    const cells = [_][]const u8{ "node-01", "2026-07-11 16:29:00", "2026-07-11 16:30:00", "2026-07-11 16:45:00" };
    const rows = [_]table.Row{.{ .cells = &cells }};
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try table.render(&writer, &columns, &rows, "empty", .{});
    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "START") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "INSTALL") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "FINISHED") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "2026-07-11 16:30:00") != null);
}

test "status renders every M4.11 readiness plane" {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try status(&writer, .{
        .ok = true,
        .process = true,
        .loopback_http = true,
        .advertised_http = true,
        .management_api = true,
        .active_config = true,
        .catalog_api = true,
        .dhcp_api = true,
        .tftp_api = true,
        .server_ip = "192.168.27.128",
        .port = 18080,
        .tftp_started = 3,
        .tftp_completed = 2,
        .tftp_failed = 1,
    });
    const out = writer.buffered();
    inline for (.{ "Overall", "Loopback HTTP", "Advertised HTTP", "Management API", "Active config", "Catalog API", "DHCP API", "TFTP API", "started=3 completed=2 failed=1" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, out, needle) != null);
}

test "node detail uses exact set parser keys" {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try nodeDetail(&writer, .{
        .id = "r97n1",
        .mac = "00:50:56:2A:23:DB",
        .arch = .aarch64,
        .profile = "rocky",
        .ip = "192.168.27.210",
        .hostname = "r97n1",
        .deploy = true,
        .http_accel = false,
    });
    const out = writer.buffered();
    inline for (.{ "mac=00:50:56:2A:23:DB", "arch=aarch64", "profile=rocky", "ip=192.168.27.210", "hostname=r97n1", "deploy=true", "http_accel=false", "storage.boot_disk=/dev/sda", "storage.additional_disks=" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, out, needle) != null);
}

test "node detail renders storage override in parser vocabulary" {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try nodeDetail(&writer, .{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "rocky", .storage = .{ .boot_disk = "/dev/nvme0n1", .additional_disks = &.{"/dev/nvme1n1"} } });
    const out = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "boot_disk=/dev/nvme0n1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "storage.additional_disks=/dev/nvme1n1") != null);
}
