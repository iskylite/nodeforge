//! NodeForge M0 唯一 HTTP listener，基于 Zap/facil.io。
//! HTTP 协议解析、连接生命周期、keep-alive、并发调度和文件/Ranges 支持由 Zap 提供；
//! 本模块仅注册 NodeForge 路由及其 JSON 响应语义。管理路由接受所有可达客户端，
//! 官方 `nodeforge` CLI 仍固定连接 `127.0.0.1`。

const std = @import("std");
const zap = @import("zap");
const model = @import("../model.zig");
const config_validate = @import("../config/validate.zig");
const runtime_state = @import("../state/runtime.zig");
const observe_error = @import("../observe/error.zig");
const observe_log = @import("../observe/log.zig");

const RouteContext = struct {
    config: *const model.AppConfig,
    catalog: *const model.Catalog,
    runtime: *const runtime_state.RuntimeState,
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
    ip: []const u8,
    port: u16,
    config: *const model.AppConfig,
    catalog: *const model.Catalog,
    runtime: *const runtime_state.RuntimeState,
) !void {
    _ = io;
    if (!std.mem.eql(u8, ip, "0.0.0.0")) return error.InvalidHttpBindAddress;

    const context = RouteContext{
        .config = config,
        .catalog = catalog,
        .runtime = runtime,
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
    observe_log.info("http: listening on http://0.0.0.0:{d}", .{port});

    // Zap owns the blocking event loop and worker lifecycle. One worker keeps M0's
    // state model serial while eliminating the hand-written HTTP parser/connection loop.
    zap.start(.{ .threads = 1, .workers = 1 });
}

/// Dispatches M0 management routes after Zap has parsed the request.
/// The route table stays explicit until M3 adds static assets and PXE data paths.
fn route(request: zap.Request) !void {
    const context = active_context orelse return error.MissingRouteContext;
    const path = request.path orelse return notFound(request);
    const method = request.method orelse return notFound(request);
    observe_log.debug("http: request received {s} {s}", .{ method, path });

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/healthz"))
        return json(request, .ok, "{\"ok\":true,\"service\":\"nodeforge\"}\n");
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/config/status"))
        return json(request, .ok, "{\"ok\":true,\"result\":{\"config\":\"valid\"}}\n");
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/config/validate")) {
        config_validate.validate(context.config, context.catalog) catch |err| return validationError(request, err);
        return json(request, .ok, "{\"ok\":true,\"result\":{}}\n");
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/server/status")) {
        const body = switch (context.runtime.service) {
            .starting => "{\"ok\":true,\"result\":{\"service\":\"starting\"}}\n",
            .running => "{\"ok\":true,\"result\":{\"service\":\"running\"}}\n",
            .stopping => "{\"ok\":true,\"result\":{\"service\":\"stopping\"}}\n",
        };
        return json(request, .ok, body);
    }
    return notFound(request);
}

/// Renders configuration validation failures using NodeForge's stable error envelope.
fn validationError(request: zap.Request, err: anyerror) !void {
    var buffer: [512]u8 = undefined;
    const body = observe_error.renderJson(&buffer, observe_error.fromValidation(err)) catch
        "{\"ok\":false,\"error\":{\"code\":\"internal.buffer\",\"message\":\"response too large\"}}\n";
    try json(request, .bad_request, body);
}

/// Emits a uniform JSON 404 envelope instead of bypassing the management error contract.
fn notFound(request: zap.Request) !void {
    try json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"http.not_found\",\"message\":\"route not found\"}}\n");
}

/// Sends a JSON response through Zap and logs only method, path, and status.
/// Request bodies and credentials never enter the service log.
fn json(request: zap.Request, status: zap.http.StatusCode, body: []const u8) !void {
    request.setStatus(status);
    observe_log.info("http: {s} {s} -> {d}", .{
        request.method orelse "OTHER",
        request.path orelse "<missing>",
        @intFromEnum(status),
    });
    // Set the header directly instead of `sendJson`: Zap's helper emits its own
    // debug line even when NodeForge is configured for info-level logging.
    try request.setHeader("content-type", "application/json");
    try request.sendBody(body);
}

test "Zap-backed route module compiles" {
    try std.testing.expect(active_context == null);
}
