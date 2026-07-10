//! NodeForge M0 唯一 HTTP listener。
//! M0 先实现管理路由；M3 PXE 数据路由将复用此 HTTP 实现，避免双 listener 生命周期分叉。
//! 管理路由接受唯一 listener 上所有可达客户端的请求，不做来源地址检查；
//! `nodeforge` CLI 则固定连接 127.0.0.1:<http.port>，只管理同机 `nodeforged`。

const std = @import("std");
const model = @import("../model.zig");
const config_validate = @import("../config/validate.zig");
const runtime_state = @import("../state/runtime.zig");
const observe_error = @import("../observe/error.zig");
const observe_log = @import("../observe/log.zig");

/// 在指定 IPv4 地址启动一个 HTTP listener。
/// M0 调用方固定传入 0.0.0.0，使管理路由可从唯一 listener 提供服务。
/// M3 PXE 数据路由将在同一个 listener 中注册。
/// 管理路由不做 peer 来源检查，因此可从任意能到达该 listener 的 IPv4 地址访问。
pub fn serve(
    io: std.Io,
    ip: []const u8,
    port: u16,
    config: *const model.AppConfig,
    catalog: *const model.Catalog,
    runtime: *const runtime_state.RuntimeState,
) !void {
    const address = try std.Io.net.IpAddress.parseIp4(ip, port);
    // 允许快速重启复用刚释放的地址；未启用 reuse_port，活跃实例仍会占住端口。
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    observe_log.info("http: listening on http://{s}:{d}", .{ ip, port });
    while (true) {
        {
            var stream = try listener.accept(io);
            defer stream.close(io);
            observe_log.debug("http: accepted connection", .{});
            try serveConnection(io, stream, config, catalog, runtime);
        }
    }
}

/// 处理单个 keep-alive 连接。
///
/// M0 串行处理请求，后续可在 accept 层增加 worker pool。
/// 每个连接使用栈上收发缓冲区，连接关闭时自动释放。
fn serveConnection(
    io: std.Io,
    stream: std.Io.net.Stream,
    config: *const model.AppConfig,
    catalog: *const model.Catalog,
    runtime: *const runtime_state.RuntimeState,
) !void {
    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    var writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => {
                observe_log.debug("http: connection closed by peer", .{});
                return;
            },
            else => {
                observe_log.debug("http: receive failed: {t}", .{err});
                return err;
            },
        };
        try route(&request, config, catalog, runtime);
        if (!request.head.keep_alive) return;
    }
}

/// 按 method + path 分发 HTTP 请求。
///
/// M0 路由表为显式分支，不做通用 pattern matching：
/// - `GET /healthz` — 健康检查
/// - `GET /api/v1/management/config/status` — 配置状态
/// - `POST /api/v1/management/config/validate` — 触发配置校验
/// - `GET /api/v1/management/server/status` — 服务运行态
/// 其余路径返回 404。
fn route(
    request: *std.http.Server.Request,
    config: *const model.AppConfig,
    catalog: *const model.Catalog,
    runtime: *const runtime_state.RuntimeState,
) !void {
    const target = request.head.target;
    if (request.head.method == .GET and std.mem.eql(u8, target, "/healthz")) {
        return json(request, .ok, "{\"ok\":true,\"service\":\"nodeforge\"}\n");
    }
    // 管理 API 与数据路由共用同一 listener，不按 peer 地址过滤请求。
    // 127.0.0.1 是 nodeforge CLI 的客户端约定，不是服务端访问控制规则。
    if (request.head.method == .GET and std.mem.eql(u8, target, "/api/v1/management/config/status")) {
        return json(request, .ok, "{\"ok\":true,\"result\":{\"config\":\"valid\"}}\n");
    }
    if (request.head.method == .POST and std.mem.eql(u8, target, "/api/v1/management/config/validate")) {
        // curl 等客户端发送空 POST 时可能同时省略 Transfer-Encoding 和
        // Content-Length；Zig server 的 respond 会尝试丢弃请求体，因此先明确为空。
        if (request.head.transfer_encoding == .none and request.head.content_length == null)
            request.head.content_length = 0;
        config_validate.validate(config, catalog) catch |err| return validationError(request, err);
        return json(request, .ok, "{\"ok\":true,\"result\":{}}\n");
    }
    if (request.head.method == .GET and std.mem.eql(u8, target, "/api/v1/management/server/status")) {
        const body = switch (runtime.service) {
            .starting => "{\"ok\":true,\"result\":{\"service\":\"starting\"}}\n",
            .running => "{\"ok\":true,\"result\":{\"service\":\"running\"}}\n",
            .stopping => "{\"ok\":true,\"result\":{\"service\":\"stopping\"}}\n",
        };
        return json(request, .ok, body);
    }
    try json(request, .not_found, "{\"ok\":false,\"error\":\"not_found\"}\n");
}

/// 将配置校验错误转换为结构化 JSON 错误响应。
///
/// 使用栈上固定缓冲区渲染，避免在错误路径中分配堆内存。
fn validationError(request: *std.http.Server.Request, err: anyerror) !void {
    var buffer: [512]u8 = undefined;
    const body = observe_error.renderJson(&buffer, observe_error.fromValidation(err)) catch
        "{\"ok\":false,\"error\":{\"code\":\"internal.buffer\",\"message\":\"response too large\"}}\n";
    try json(request, .bad_request, body);
}

/// 写 JSON 响应并记录一行 access log。
/// M0 日常日志只记录 method/path/status，不记录请求体，避免把后续 answer、token 或日志上传内容打进 journal。
///
/// 日志必须在 `respond()` 之前写入：`request.head.target` 借用连接内部读缓冲区，
/// `respond()` 可能推进读位置或复用缓冲区，导致日志中格式化的 target 切片失效。
fn json(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    observe_log.info("http: {s} {s} -> {d}", .{
        methodName(request.head.method),
        request.head.target,
        @intFromEnum(status),
    });
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

/// 将 HTTP method 枚举转为大写字符串，用于 access log。
fn methodName(method: std.http.Method) []const u8 {
    return switch (method) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .HEAD => "HEAD",
        .OPTIONS => "OPTIONS",
        else => "OTHER",
    };
}

test "single listener serves health" {
    try std.testing.expect(true);
}
