//! NodeForge 唯一 HTTP listener，基于 Zap/facil.io。
//! HTTP 协议解析、连接生命周期、keep-alive、并发调度和文件/Ranges 支持由 Zap 提供；
//! 本模块仅注册 NodeForge 路由及其 JSON 响应语义。管理路由接受所有可达客户端，
//! 官方 `nodeforge` CLI 仍固定连接 `127.0.0.1`。
//!
//! M0 提供健康检查、配置状态和服务器状态路由；M1 增加只读 TFTP 会话计数、
//! 会话列表和资产导入路由。所有路由在同一个 `0.0.0.0:http_port` listener 上分发。

const std = @import("std");
const zap = @import("zap");
const model = @import("../model.zig");
const config_validate = @import("../config/validate.zig");
const runtime_state = @import("../state/runtime.zig");
const catalog_runtime = @import("../state/catalog_runtime.zig");
const observe_error = @import("../observe/error.zig");
const observe_log = @import("../observe/log.zig");
const events = @import("../state/events.zig");
const paths = @import("../paths.zig");
const log = std.log.scoped(.http);

const RouteContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const model.AppConfig,
    catalog: *catalog_runtime.CatalogRuntime,
    runtime: *const runtime_state.RuntimeState,
    event_writer: *events.Writer,
};

/// Per-request metadata captured at route entry and threaded through to `json`
/// for structured logging and event emission.
const RequestMeta = struct {
    io: std.Io,
    client_ip: []const u8,
    started: std.Io.Timestamp,
};

// Zap's low-level listener exposes one process-global request callback. NodeForge is
// intentionally a single-process, single-listener appliance, so this pointer remains
// valid for the full blocking lifetime of `zap.start` and is never mutated afterwards.
var active_context: ?*const RouteContext = null;

/// Starts the only NodeForge HTTP listener on every IPv4 interface.
///
/// `server.server_ip` is intentionally not used as a bind address. Zap delegates
/// socket creation and HTTP protocol handling to facil.io; a bind conflict causes
/// `listen` to fail before the process starts workers, preserving M0's one-listener
/// invariant.
pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    ip: []const u8,
    port: u16,
    config: *const model.AppConfig,
    catalog: *catalog_runtime.CatalogRuntime,
    runtime: *const runtime_state.RuntimeState,
    event_writer: *events.Writer,
) !void {
    if (!std.mem.eql(u8, ip, "0.0.0.0")) return error.InvalidHttpBindAddress;

    const context = RouteContext{
        .io = io,
        .allocator = allocator,
        .config = config,
        .catalog = catalog,
        .runtime = runtime,
        .event_writer = event_writer,
    };
    if (active_context != null) return error.HttpAlreadyRunning;
    active_context = &context;
    defer active_context = null;

    var listener = zap.HttpListener.init(.{
        .interface = "0.0.0.0",
        .port = port,
        .on_request = route,
        .log = false,
    });
    try listener.listen();
    log.info("listening on http://0.0.0.0:{d}", .{port});
    event_writer.appendWithFields(io, allocator, paths.events_path, "service.started", "all protocol listeners ready", &.{}) catch |err|
        log.err("unable to record service start: {t}", .{err});

    // Zap owns the blocking event loop and worker lifecycle. One worker keeps M0's
    // state model serial while eliminating the hand-written HTTP parser/connection loop.
    zap.start(.{ .threads = 1, .workers = 1 });
}

/// Extracts the client IP from the underlying facil.io socket. Only the direct
/// peer address is used; X-Forwarded-For is never trusted without a configured
/// proxy CIDR boundary.
fn getClientIp(request: zap.Request) []const u8 {
    const addr = zap.fio.http_peer_addr(request.h);
    if (addr.len == 0 or addr.data == null) return "unknown";
    return addr.data[0..addr.len];
}

/// Dispatches management routes after Zap has parsed the request.
/// 路由表保持显式匹配，不引入动态路由框架；M3 将在同一 listener 增加
/// PXE 数据路由（boot config、answer file、repo/rootfs 下载）。
///
/// 当前路由表：
/// - `GET  /healthz`                              — 进程存活与 HTTP 可达性
/// - `GET  /api/v1/management/config/status`      — 配置加载有效性
/// - `POST /api/v1/management/config/validate`    — 重新校验已加载的 config/catalog 快照
/// - `GET  /api/v1/management/server/status`      — 守护进程生命周期阶段
/// - `GET  /api/v1/management/tftp/status`        — M1 TFTP 传输计数
/// - `GET  /api/v1/management/tftp/sessions`      — M1 TFTP 会话列表
/// - `GET  /api/v1/management/dhcp/leases`        — M2 DHCP lease 列表
/// - `GET  /api/v1/management/dhcp/unknown`       — M2 未认领节点列表
/// - `POST /api/v1/management/assets/import`      — M1 资产导入（daemon 写入 catalog）
fn route(request: zap.Request) !void {
    const context = active_context orelse return error.MissingRouteContext;
    const path = request.path orelse return notFound(request, undefined_meta(context));
    const method = request.method orelse return notFound(request, undefined_meta(context));
    const started = std.Io.Clock.awake.now(context.io);
    const client_ip = getClientIp(request);
    const meta = RequestMeta{ .io = context.io, .client_ip = client_ip, .started = started };

    observe_log.debug("http: request received {s} {s}", .{ method, path });

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/healthz"))
        return json(request, .ok, "{\"ok\":true,\"service\":\"nodeforge\"}\n", meta);
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/config/status"))
        return json(request, .ok, "{\"ok\":true,\"result\":{\"config\":\"valid\"}}\n", meta);
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/config/validate")) {
        context.catalog.lock();
        defer context.catalog.unlock();
        config_validate.validate(context.config, &context.catalog.value) catch |err| return validationError(request, err, meta);
        return json(request, .ok, "{\"ok\":true,\"result\":{}}\n", meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/server/status")) {
        const body = switch (context.runtime.service) {
            .starting => "{\"ok\":true,\"result\":{\"service\":\"starting\"}}\n",
            .running => "{\"ok\":true,\"result\":{\"service\":\"running\"}}\n",
            .stopping => "{\"ok\":true,\"result\":{\"service\":\"stopping\"}}\n",
        };
        return json(request, .ok, body, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/tftp/status")) {
        return tftpStatus(request, context.runtime, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/tftp/sessions")) {
        return tftpSessions(request, context.runtime, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/dhcp/leases")) {
        return dhcpLeases(request, context.allocator, context.runtime, false, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/dhcp/unknown")) {
        return dhcpLeases(request, context.allocator, context.runtime, true, meta);
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/assets/import")) {
        return importAsset(request, context, meta);
    }
    return notFound(request, meta);
}

/// Constructs a placeholder meta for early exits where timing is not meaningful.
fn undefined_meta(context: *const RouteContext) RequestMeta {
    return .{ .io = context.io, .client_ip = "unknown", .started = std.Io.Clock.awake.now(context.io) };
}

/// Registers an already-present asset via the daemon, which alone publishes a
/// new catalog snapshot.  Query fields intentionally accept the constrained M1
/// CLI vocabulary; arbitrary file paths and decoded URL strings are rejected by
/// the same asset validator used by direct TFTP serving.
fn importAsset(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    const name = request.getParamSlice("name") orelse return assetInputError(request, "missing name", meta);
    const path = request.getParamSlice("path") orelse return assetInputError(request, "missing path", meta);
    const kind_text = request.getParamSlice("kind") orelse return assetInputError(request, "missing kind", meta);
    const kind = std.meta.stringToEnum(model.AssetKind, kind_text) orelse return assetInputError(request, "invalid kind", meta);
    const distro = request.getParamSlice("distro");
    const version = request.getParamSlice("version");
    const arch_text = request.getParamSlice("arch");
    const has_tuple = distro != null or version != null or arch_text != null;
    if (has_tuple and (distro == null or version == null or arch_text == null)) return assetInputError(request, "incomplete distro tuple", meta);
    const arch = if (arch_text) |value| std.meta.stringToEnum(model.Arch, value) orelse return assetInputError(request, "invalid arch", meta) else null;
    var checksum: [64]u8 = undefined;
    @import("../assets/validate.zig").sha256File(context.io, context.config.tftp.asset_root, path, &checksum) catch |err| {
        observe_log.err("asset: import failed for {s}: {t}", .{ path, err });
        return assetInputError(request, "unreadable asset", meta);
    };
    context.catalog.addAsset(context.io, context.config, .{
        .name = name, .kind = kind, .path = path, .distro = distro, .version = version, .arch = arch,
        .kernel_release = request.getParamSlice("kernel_release"), .sha256 = &checksum,
    }) catch |err| return assetInputError(request, @errorName(err), meta);
    try json(request, .ok, "{\"ok\":true}\n", meta);
}

fn assetInputError(request: zap.Request, message: []const u8, meta: RequestMeta) !void {
    var buffer: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buffer, "{{\"ok\":false,\"error\":{{\"code\":\"asset.invalid\",\"message\":{f}}}}}\n", .{std.json.fmt(message, .{})});
    try json(request, .bad_request, body, meta);
}

/// 渲染 M1 TFTP 会话计数；读取使用原子 load，不阻塞 UDP transfer worker。
fn tftpStatus(request: zap.Request, runtime: *const runtime_state.RuntimeState, meta: RequestMeta) !void {
    var buffer: [192]u8 = undefined;
    const body = try std.fmt.bufPrint(&buffer, "{{\"ok\":true,\"result\":{{\"started\":{d},\"completed\":{d},\"failed\":{d}}}}}\n", .{
        runtime.tftp.started.load(.monotonic),
        runtime.tftp.completed.load(.monotonic),
        runtime.tftp.failed.load(.monotonic),
    });
    try json(request, .ok, body, meta);
}

/// Renders the bounded M1 transfer activity list.  Entries are intentionally
/// short-lived operational state; audit history belongs to `events.jsonl` in a
/// later stage, not an unbounded HTTP response.
fn tftpSessions(request: zap.Request, runtime: *const runtime_state.RuntimeState, meta: RequestMeta) !void {
    var sessions: [runtime_state.TftpState.max_sessions]runtime_state.TftpSession = undefined;
    @constCast(&runtime.tftp).snapshot(&sessions);
    var buffer: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writer.writeAll("{\"ok\":true,\"result\":{\"sessions\":[");
    var first = true;
    for (sessions) |session| {
        if (session.id == 0) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{{\"id\":{d},\"phase\":\"{t}\",\"filename\":{f}}}", .{
            session.id,
            session.phase,
            std.json.fmt(session.filenameSlice(), .{}),
        });
    }
    try writer.writeAll("]}}\n");
    try json(request, .ok, writer.buffered(), meta);
}

fn dhcpLeases(request: zap.Request, allocator: std.mem.Allocator, runtime: *const runtime_state.RuntimeState, unknown_only: bool, meta: RequestMeta) !void {
    var leases: [runtime_state.DhcpState.max_leases]runtime_state.DhcpLease = undefined;
    @constCast(&runtime.dhcp).snapshot(&leases);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"leases\":[");
    var first = true;
    for (leases) |lease| {
        if (!lease.used() or (unknown_only and lease.known)) continue;
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"phase\":\"{t}\",\"known\":{s},\"ip\":\"{d}.{d}.{d}.{d}\",\"mac\":\"{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\",\"expires_at\":{d}}}", .{
            lease.phase,
            if (lease.known) "true" else "false",
            (lease.ip >> 24) & 255,
            (lease.ip >> 16) & 255,
            (lease.ip >> 8) & 255,
            lease.ip & 255,
            lease.mac[0], lease.mac[1], lease.mac[2], lease.mac[3], lease.mac[4], lease.mac[5],
            lease.expires_at,
        });
    }
    try output.writer.writeAll("]}}\n");
    try json(request, .ok, output.written(), meta);
}

/// Renders configuration validation failures using NodeForge's stable error envelope.
fn validationError(request: zap.Request, err: anyerror, meta: RequestMeta) !void {
    var buffer: [512]u8 = undefined;
    const body = observe_error.renderJson(&buffer, observe_error.fromValidation(err)) catch
        "{\"ok\":false,\"error\":{\"code\":\"internal.buffer\",\"message\":\"response too large\"}}\n";
    try json(request, .bad_request, body, meta);
}

/// Emits a uniform JSON 404 envelope instead of bypassing the management error contract.
fn notFound(request: zap.Request, meta: RequestMeta) !void {
    try json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"http.not_found\",\"message\":\"route not found\"}}\n", meta);
}

/// Sends a JSON response through Zap and logs method, path, status, bytes,
/// duration and client IP. Request bodies and credentials never enter the log.
fn json(request: zap.Request, status: zap.http.StatusCode, body: []const u8, meta: RequestMeta) !void {
    request.setStatus(status);
    const duration_us = meta.started.durationTo(std.Io.Clock.awake.now(meta.io)).toMicroseconds();
    const is_health = std.mem.eql(u8, request.path orelse "", "/healthz");
    if (is_health) log.debug("{s} {s} -> {d} ({d} bytes, {d}us, client={s})", .{
        request.method orelse "OTHER", request.path orelse "<missing>", @intFromEnum(status), body.len, duration_us, meta.client_ip,
    }) else log.info("{s} {s} -> {d} ({d} bytes, {d}us, client={s})", .{
        request.method orelse "OTHER",
        request.path orelse "<missing>",
        @intFromEnum(status),
        body.len,
        duration_us,
        meta.client_ip,
    });
    if (active_context) |context| {
        const method = request.method orelse "OTHER";
        const path = request.path orelse "<missing>";
        if (!std.mem.eql(u8, path, "/healthz")) {
            var status_text: [4]u8 = undefined;
            var bytes_text: [20]u8 = undefined;
            var duration_text: [20]u8 = undefined;
            const fields = [_]events.Field{
                .{ .key = "method", .value = method },
                .{ .key = "path", .value = path },
                .{ .key = "status", .value = std.fmt.bufPrint(&status_text, "{d}", .{@intFromEnum(status)}) catch "0" },
                .{ .key = "bytes_sent", .value = std.fmt.bufPrint(&bytes_text, "{d}", .{body.len}) catch "0" },
                .{ .key = "client_ip", .value = meta.client_ip },
                .{ .key = "duration_us", .value = std.fmt.bufPrint(&duration_text, "{d}", .{duration_us}) catch "0" },
            };
            context.event_writer.appendWithFields(context.io, context.allocator, paths.events_path, "http.request", "HTTP request completed", &fields) catch |err|
                observe_log.err("http: event append failed: {t}", .{err});
        }
    }
    // Set the header directly instead of `sendJson`: Zap's helper emits its own
    // debug line even when NodeForge is configured for info-level logging.
    try request.setHeader("content-type", "application/json");
    try request.sendBody(body);
}

test "Zap-backed route module compiles" {
    try std.testing.expect(active_context == null);
}
