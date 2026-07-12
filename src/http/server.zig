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
const boot_session = @import("../state/boot_session.zig");
const node_status = @import("../state/node_status.zig");
const auth = @import("auth.zig");
const lookup = @import("../catalog.zig");
const asset_validate = @import("../assets/validate.zig");
const iso_import = @import("../catalog/iso_import.zig");
const dhcp_server = @import("../dhcp/server.zig");
const dhcp_store = @import("../state/dhcp_store.zig");
const log = std.log.scoped(.http);

const RouteContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const model.AppConfig,
    catalog: *catalog_runtime.CatalogRuntime,
    runtime: *const runtime_state.RuntimeState,
    event_writer: *events.Writer,
    sessions: *boot_session.Store,
    statuses: *node_status.Store,
    daemon_instance_id: *const [boot_session.id_len]u8,
    persistence: *const dhcp_server.Persistence,
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
    sessions: *boot_session.Store,
    statuses: *node_status.Store,
    daemon_instance_id: *const [boot_session.id_len]u8,
    persistence: *const dhcp_server.Persistence,
) !void {
    if (!std.mem.eql(u8, ip, "0.0.0.0")) return error.InvalidHttpBindAddress;

    const context = RouteContext{
        .io = io,
        .allocator = allocator,
        .config = config,
        .catalog = catalog,
        .runtime = runtime,
        .event_writer = event_writer,
        .sessions = sessions,
        .statuses = statuses,
        .daemon_instance_id = daemon_instance_id,
        .persistence = persistence,
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
    if (std.mem.eql(u8, method, "GET")) {
        if (nodePath(path, "/boot/config/")) |node_id| return bootConfig(request, context, node_id, meta);
        if (assetRoute(path, "/images/")) |name| return imageAsset(request, context, name, meta);
        if (assetRoute(path, "/rootfs/")) |name| return rootfsAsset(request, context, name, meta);
        if (repoRoute(path)) |repo| return repositoryAsset(request, context, repo.name, repo.tail, meta);
        if (std.mem.startsWith(u8, path, "/api/v1/nodes/")) if (splitNodeRoute(path["/api/v1/nodes/".len..])) |node_route| {
            if (std.mem.eql(u8, node_route.suffix, "/config")) return bootConfig(request, context, node_route.node_id, meta);
            if (std.mem.eql(u8, node_route.suffix, "/answer")) return answerFixture(request, context, node_route.node_id, meta);
        };
    }
    if (std.mem.eql(u8, method, "POST")) {
        if (std.mem.startsWith(u8, path, "/api/v1/nodes/")) if (splitNodeRoute(path["/api/v1/nodes/".len..])) |node_route| {
            if (std.mem.eql(u8, node_route.suffix, "/events")) return nodeEvent(request, context, node_route.node_id, meta);
            if (std.mem.eql(u8, node_route.suffix, "/logs")) return nodeLog(request, context, node_route.node_id, meta);
        };
    }
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
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/runtime")) {
        return runtimeSummary(request, context, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/api/v1/management/nodes/")) if (managementNodePath(path)) |node_id| {
        return managementNodeStatus(request, context, node_id, meta);
    };
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
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/install-sources/import")) {
        return importInstallSource(request, context, meta);
    }
    return notFound(request, meta);
}

const NodeRoute = struct { node_id: []const u8, suffix: []const u8 };

/// Returns only an unescaped single URL segment.  A node id with a slash,
/// percent encoding or a second path component is never routed as identity.
fn nodePath(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const node_id = path[prefix.len..];
    if (!auth.nodeIdSafe(node_id)) return null;
    return node_id;
}

fn splitNodeRoute(tail: []const u8) ?NodeRoute {
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return null;
    const node_id = tail[0..slash];
    if (!auth.nodeIdSafe(node_id)) return null;
    return .{ .node_id = node_id, .suffix = tail[slash..] };
}

fn assetRoute(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const name = path[prefix.len..];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, '%') != null) return null;
    return name;
}

const RepoRoute = struct { name: []const u8, tail: []const u8 };
fn repoRoute(path: []const u8) ?RepoRoute {
    const prefix = "/repos/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const name = rest[0..slash];
    const tail = rest[slash + 1 ..];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '%') != null) return null;
    asset_validate.validateRelativePath(tail) catch return null;
    return .{ .name = name, .tail = tail };
}

fn imageAsset(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    context.catalog.lock();
    const asset = lookup.findAsset(&context.catalog.value, name);
    if (asset == null or asset.?.kind != .iso) {
        context.catalog.unlock();
        return notFound(request, meta);
    }
    const path = asset.?.path;
    const checksum = asset.?.sha256;
    context.catalog.unlock();
    return staticFile(request, context, context.config.http.asset_root, path, checksum, meta);
}

fn rootfsAsset(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    const checked = auth.authenticateAsset(context.sessions, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    const asset_info = blk: {
        context.catalog.lock();
        defer context.catalog.unlock();
        const profile = lookup.findProfile(context.config, checked.profile) orelse return notFound(request, meta);
        if (profile.mode != .diskless) return nodeAuthError(request, error.ProofMismatch, meta);
        const bundle = lookup.findBootBundle(&context.catalog.value, profile.boot_bundle orelse return notFound(request, meta)) orelse return notFound(request, meta);
        if (!std.mem.eql(u8, bundle.rootfs, name)) return nodeAuthError(request, error.ProofMismatch, meta);
        const asset = lookup.findAsset(&context.catalog.value, name) orelse return notFound(request, meta);
        if (asset.kind != .rootfs) return notFound(request, meta);
        // Catalog allocations are append-only for the daemon lifetime, therefore
        // these slices remain valid after unlock and are safe for the transfer.
        break :blk .{ .path = asset.path, .checksum = asset.sha256 };
    };
    return staticFile(request, context, context.config.http.asset_root, asset_info.path, asset_info.checksum, meta);
}

fn repositoryAsset(request: zap.Request, context: *const RouteContext, name: []const u8, tail: []const u8, meta: RequestMeta) !void {
    context.catalog.lock();
    const repository = lookup.findRepository(&context.catalog.value, name);
    context.catalog.unlock();
    if (repository == null) return notFound(request, meta);
    const root = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ context.config.http.repository_root, name });
    defer context.allocator.free(root);
    return staticFile(request, context, root, tail, null, meta);
}

/// NodeForge parses the one supported Range form before handing a verified
/// descriptor to facil.io's fd-backed sendfile path.  This keeps the managed
/// checksum ETag authoritative: facil.io's path helper has incompatible
/// `If-Range` behavior and generates a second, filesystem-derived ETag.
fn staticFile(request: zap.Request, context: *const RouteContext, root: []const u8, relative: []const u8, checksum: ?[]const u8, meta: RequestMeta) !void {
    var file = asset_validate.openRegularFile(context.io, root, relative) catch return notFound(request, meta);
    errdefer file.close(context.io);
    const size = (try file.stat(context.io)).size;
    if (checksum) |hash| {
        var etag: [68]u8 = undefined;
        const value = try std.fmt.bufPrint(&etag, "\"{s}\"", .{hash});
        try request.setHeader("etag", value);
        if (request.getHeader("range")) |range_value| if (request.getHeader("if-range")) |if_range| {
            if (!std.mem.eql(u8, if_range, value)) return sendWholeFile(request, &file, size, relative, meta);
            return sendRangedFile(request, context, &file, size, relative, range_value, meta);
        } else return sendRangedFile(request, context, &file, size, relative, range_value, meta);
    }
    if (request.getHeader("range")) |range_value| return sendRangedFile(request, context, &file, size, relative, range_value, meta);
    return sendWholeFile(request, &file, size, relative, meta);
}

const ByteRange = struct { offset: u64, length: u64 };

fn sendRangedFile(request: zap.Request, context: *const RouteContext, file: *std.Io.File, size: u64, relative: []const u8, range_value: []const u8, meta: RequestMeta) !void {
    const range = parseSingleRange(range_value, size) catch {
        file.close(context.io);
        return rangeNotSatisfiable(request, size, meta);
    };
    request.setStatusNumeric(206);
    var content_range: [96]u8 = undefined;
    const value = try std.fmt.bufPrint(&content_range, "bytes {d}-{d}/{d}", .{ range.offset, range.offset + range.length - 1, size });
    try request.setHeader("content-range", value);
    try sendManagedFile(request, file, range, relative, meta);
}

fn sendWholeFile(request: zap.Request, file: *std.Io.File, size: u64, relative: []const u8, meta: RequestMeta) !void {
    try sendManagedFile(request, file, .{ .offset = 0, .length = size }, relative, meta);
}

fn sendManagedFile(request: zap.Request, file: *std.Io.File, range: ByteRange, relative: []const u8, meta: RequestMeta) !void {
    try request.setHeader("accept-ranges", "bytes");
    request.setContentTypeFromFilename(relative) catch try request.setHeader("content-type", "application/octet-stream");
    const result = zap.fio.http_sendfile(request.h, file.handle, @intCast(range.length), @intCast(range.offset));
    if (result != 0) return error.SendFile;
    request.markAsFinished(true);
    log.info("GET static -> {d} (asset={s}, bytes={d}, client={s})", .{ request.h.*.status, relative, range.length, meta.client_ip });
}

fn rangeNotSatisfiable(request: zap.Request, size: u64, meta: RequestMeta) !void {
    request.setStatusNumeric(416);
    var content_range: [64]u8 = undefined;
    try request.setHeader("content-range", try std.fmt.bufPrint(&content_range, "bytes */{d}", .{size}));
    try request.setHeader("accept-ranges", "bytes");
    try request.sendBody("");
    log.info("GET static -> 416 (client={s})", .{meta.client_ip});
}

fn parseSingleRange(value: []const u8, size: u64) !ByteRange {
    if (!std.mem.startsWith(u8, value, "bytes=") or std.mem.indexOfScalar(u8, value, ',') != null or size == 0) return error.InvalidRange;
    const spec = value["bytes=".len..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return error.InvalidRange;
    if (std.mem.indexOfScalar(u8, spec[dash + 1 ..], '-') != null) return error.InvalidRange;
    const first = spec[0..dash];
    const last = spec[dash + 1 ..];
    if (first.len == 0) {
        const suffix = std.fmt.parseInt(u64, last, 10) catch return error.InvalidRange;
        if (suffix == 0) return error.InvalidRange;
        const length = @min(suffix, size);
        return .{ .offset = size - length, .length = length };
    }
    const offset = std.fmt.parseInt(u64, first, 10) catch return error.InvalidRange;
    if (offset >= size) return error.InvalidRange;
    if (last.len == 0) return .{ .offset = offset, .length = size - offset };
    const requested_last = std.fmt.parseInt(u64, last, 10) catch return error.InvalidRange;
    if (requested_last < offset) return error.InvalidRange;
    const actual_last = @min(requested_last, size - 1);
    return .{ .offset = offset, .length = actual_last - offset + 1 };
}

/// Issues the M3 BootConfig v1 document after either DHCP peer bootstrap or a
/// previously issued bearer capability.  The secret only appears in this
/// authenticated response, never in an Event, error envelope, URL or log.
fn bootConfig(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const checked = auth.authenticate(
        context.sessions,
        node_id,
        meta.client_ip,
        request.getHeader("authorization"),
        request.getHeader("x-nodeforge-session"),
        boot_session.monotonicNow(),
    ) catch |err| return nodeAuthError(request, err, meta);
    const session = if (checked.proof == .bootstrap)
        context.sessions.issueCapability(context.io, checked.session.boot_session_id[0..], boot_session.monotonicNow(), unixNow()) catch |err| return nodeAuthError(request, err, meta)
    else blk: {
        context.sessions.touchDelivery(checked.session.boot_session_id[0..], boot_session.monotonicNow(), unixNow());
        break :blk checked.session;
    };

    context.statuses.update(node_id, session.boot_session_id[0..], context.daemon_instance_id, .boot_config_fetched, null, unixNow(), true) catch |err|
        observe_log.err("node status update failed: {t}", .{err});
    persistRuntime(context);
    const fields = [_]events.Field{
        .{ .key = "node_id", .value = node_id },
        .{ .key = "boot_session_id", .value = session.boot_session_id[0..] },
        .{ .key = "profile", .value = session.profile },
    };
    context.event_writer.appendWithFields(context.io, context.allocator, paths.events_path, "boot.config.fetched", "authenticated boot config issued", &fields) catch |err| {
        observe_log.err("boot config event append failed: {t}", .{err});
        return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"events.unavailable\",\"message\":\"event writer unavailable\"}}\n", meta);
    };

    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    const base = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}", .{ context.config.server.server_ip, context.config.server.http_port });
    defer context.allocator.free(base);
    const config_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/config", .{ base, node_id });
    defer context.allocator.free(config_url);
    const event_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/events", .{ base, node_id });
    defer context.allocator.free(event_url);
    try output.writer.print("{{\"schema_version\":1,\"node_id\":{f},\"boot_session_id\":{f},\"profile\":{f},\"mode\":{f},\"config_url\":{f},\"event_url\":{f}", .{
        std.json.fmt(node_id, .{}),    std.json.fmt(session.boot_session_id[0..], .{}), std.json.fmt(session.profile, .{}), std.json.fmt(@tagName(session.mode), .{}),
        std.json.fmt(config_url, .{}), std.json.fmt(event_url, .{}),
    });
    // The temporary URL strings above are intentionally copied into the writer
    // before its lifetime ends; free the writer as one response allocation.
    switch (session.mode) {
        .install => {
            const answer_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/answer", .{ base, node_id });
            defer context.allocator.free(answer_url);
            try output.writer.print(",\"answer_url\":{f}", .{std.json.fmt(answer_url, .{})});
            context.catalog.lock();
            defer context.catalog.unlock();
            const profile = lookup.findProfile(context.config, session.profile) orelse return notFound(request, meta);
            const source = lookup.findInstallSource(&context.catalog.value, profile.install_source orelse return notFound(request, meta)) orelse return notFound(request, meta);
            try output.writer.print(",\"installer\":{{\"source\":{f},\"kernel\":{f},\"initrd\":{f}}},\"repository_urls\":[", .{
                std.json.fmt(source.name, .{}), std.json.fmt(source.installer_kernel, .{}), std.json.fmt(source.installer_initrd, .{}),
            });
            for (source.repositories, 0..) |repository_name, index| {
                const repository = lookup.findRepository(&context.catalog.value, repository_name) orelse return notFound(request, meta);
                if (index != 0) try output.writer.writeByte(',');
                try output.writer.print("{f}", .{std.json.fmt(repository.base_url, .{})});
            }
            try output.writer.writeByte(']');
        },
        .diskless => {},
        .discovery => {},
    }
    try output.writer.print(",\"access\":{{\"session_header\":\"X-NodeForge-Session\",\"session_id\":{f},\"authorization_header\":\"Authorization\",\"bearer_token\":{f}}}}}\n", .{
        std.json.fmt(session.boot_session_id[0..], .{}), std.json.fmt(session.capability[0..], .{}),
    });
    return json(request, .ok, output.written(), meta);
}

/// M3 intentionally returns a transport fixture rather than an installer
/// dialect. M4 replaces this with a Kickstart/Autoinstall renderer, but the
/// capability delivery and answer URL contract are already exercised here.
fn answerFixture(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const checked = auth.authenticate(context.sessions, node_id, meta.client_ip, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.session.mode != .install) return nodeAuthError(request, error.ProofMismatch, meta);
    const session = if (checked.proof == .bootstrap)
        context.sessions.issueCapability(context.io, checked.session.boot_session_id[0..], boot_session.monotonicNow(), unixNow()) catch |err| return nodeAuthError(request, err, meta)
    else
        checked.session;
    context.sessions.touchDelivery(session.boot_session_id[0..], boot_session.monotonicNow(), unixNow());
    const event_url = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}/api/v1/nodes/{s}/events", .{ context.config.server.server_ip, context.config.server.http_port, node_id });
    defer context.allocator.free(event_url);
    var output: [1024]u8 = undefined;
    const body = try std.fmt.bufPrint(&output, "# NodeForge M3 bootstrap answer fixture; M4 replaces this with a distro adapter.\nnodeforge_boot_session_id={s}\nnodeforge_access_token={s}\nnodeforge_event_url={s}\n", .{ session.boot_session_id[0..], session.capability[0..], event_url });
    request.setStatus(.ok);
    try request.setHeader("content-type", "text/plain; charset=utf-8");
    try request.setHeader("cache-control", "no-store");
    // `sendBody` may hand the response back to facil.io immediately; log the
    // borrowed route segment before that hand-off rather than retaining a
    // request-owned slice for diagnostics afterwards.
    log.info("GET answer fixture -> 200 (node={s}, client={s})", .{ node_id, meta.client_ip });
    try request.sendBody(body);
}

fn nodeEvent(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const checked = auth.authenticate(context.sessions, node_id, meta.client_ip, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.proof != .capability) return nodeAuthError(request, error.MissingProof, meta);
    if (!bodyWithin(request, 4 * 1024)) return json(request, .content_too_large, "{\"ok\":false,\"error\":{\"code\":\"body_too_large\",\"message\":\"node event body too large\"}}\n", meta);
    var event = parseNodeEvent(request, context.allocator) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_event\",\"message\":\"invalid node event\"}}\n", meta);
    defer event.params.deinit();
    @import("contracts.zig").validateNodeEvent(event.value) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_event\",\"message\":\"invalid node event\"}}\n", meta);
    if (!std.mem.eql(u8, event.value.boot_session_id, checked.session.boot_session_id[0..])) return nodeAuthError(request, error.ProofMismatch, meta);
    const mapped = mapStage(checked.session.mode, event.value.stage) orelse return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"stage_invalid\",\"message\":\"stage not allowed for profile mode\"}}\n", meta);
    context.statuses.update(node_id, checked.session.boot_session_id[0..], context.daemon_instance_id, mapped.phase, event.value.reason, unixNow(), true) catch |err|
        observe_log.err("node status update failed: {t}", .{err});
    persistRuntime(context);
    var fields: [4]events.Field = .{
        .{ .key = "node_id", .value = node_id },
        .{ .key = "boot_session_id", .value = checked.session.boot_session_id[0..] },
        .{ .key = "stage", .value = event.value.stage },
        .{ .key = "reason", .value = event.value.reason orelse "" },
    };
    const field_count: usize = if (event.value.reason == null) 3 else 4;
    context.event_writer.appendWithFields(context.io, context.allocator, paths.events_path, mapped.event_type, event.value.message orelse "node stage update", fields[0..field_count]) catch |err| {
        observe_log.err("node event append failed: {t}", .{err});
        return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"events.unavailable\",\"message\":\"event writer unavailable\"}}\n", meta);
    };
    context.sessions.touchDelivery(checked.session.boot_session_id[0..], boot_session.monotonicNow(), unixNow());
    return json(request, .ok, "{\"ok\":true}\n", meta);
}

fn nodeLog(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const checked = auth.authenticate(context.sessions, node_id, meta.client_ip, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.proof != .capability) return nodeAuthError(request, error.MissingProof, meta);
    if (!bodyWithin(request, 4 * 1024)) return json(request, .content_too_large, "{\"ok\":false,\"error\":{\"code\":\"body_too_large\",\"message\":\"node log body too large\"}}\n", meta);
    var summary = parseLogSummary(request, context.allocator) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_log\",\"message\":\"invalid node log summary\"}}\n", meta);
    defer summary.params.deinit();
    @import("contracts.zig").validateLogSummary(summary.value) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_log\",\"message\":\"invalid node log summary\"}}\n", meta);
    if (!std.mem.eql(u8, summary.value.boot_session_id, checked.session.boot_session_id[0..])) return nodeAuthError(request, error.ProofMismatch, meta);
    const event_type = switch (checked.session.mode) {
        .install => "install.failed",
        .diskless => "diskless.failed",
        .discovery => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"stage_invalid\",\"message\":\"logs unavailable for discovery\"}}\n", meta),
    };
    context.statuses.update(node_id, checked.session.boot_session_id[0..], context.daemon_instance_id, .failed, summary.value.reason, unixNow(), true) catch |err|
        observe_log.err("node status update failed: {t}", .{err});
    persistRuntime(context);
    const fields = [_]events.Field{ .{ .key = "node_id", .value = node_id }, .{ .key = "boot_session_id", .value = checked.session.boot_session_id[0..] }, .{ .key = "reason", .value = summary.value.reason } };
    context.event_writer.appendWithFields(context.io, context.allocator, paths.events_path, event_type, summary.value.summary, &fields) catch |err| {
        observe_log.err("node log append failed: {t}", .{err});
        return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"events.unavailable\",\"message\":\"event writer unavailable\"}}\n", meta);
    };
    return json(request, .ok, "{\"ok\":true}\n", meta);
}

const ParsedNodeEvent = struct { value: @import("contracts.zig").NodeEvent, params: zap.Request.HttpParamKVList };
const ParsedLogSummary = struct { value: @import("contracts.zig").LogSummary, params: zap.Request.HttpParamKVList };

fn parseNodeEvent(request: zap.Request, allocator: std.mem.Allocator) !ParsedNodeEvent {
    try request.parseBody();
    var params = try request.parametersToOwnedList(allocator);
    errdefer params.deinit();
    if (params.items.len < 3 or params.items.len > 5) return error.InvalidNodeEvent;
    // `reason` and `message` are optional.  Start from their contract
    // defaults rather than inspecting uninitialized optionals while checking
    // duplicate keys in an otherwise valid client payload.
    var result: @import("contracts.zig").NodeEvent = .{ .v = 0, .boot_session_id = "", .stage = "" };
    var seen_v = false;
    var seen_session = false;
    var seen_stage = false;
    for (params.items) |param| {
        if (std.mem.eql(u8, param.key, "v")) {
            if (seen_v or param.value == null or param.value.? != .Int) return error.InvalidNodeEvent;
            result.v = @intCast(param.value.?.Int);
            seen_v = true;
        } else if (std.mem.eql(u8, param.key, "boot_session_id")) {
            if (seen_session) return error.InvalidNodeEvent;
            result.boot_session_id = stringParam(param.value) orelse return error.InvalidNodeEvent;
            seen_session = true;
        } else if (std.mem.eql(u8, param.key, "stage")) {
            if (seen_stage) return error.InvalidNodeEvent;
            result.stage = stringParam(param.value) orelse return error.InvalidNodeEvent;
            seen_stage = true;
        } else if (std.mem.eql(u8, param.key, "reason")) {
            if (result.reason != null) return error.InvalidNodeEvent;
            result.reason = stringParam(param.value) orelse return error.InvalidNodeEvent;
        } else if (std.mem.eql(u8, param.key, "message")) {
            if (result.message != null) return error.InvalidNodeEvent;
            result.message = stringParam(param.value) orelse return error.InvalidNodeEvent;
        } else return error.InvalidNodeEvent;
    }
    if (!seen_v or !seen_session or !seen_stage) return error.InvalidNodeEvent;
    return .{ .value = result, .params = params };
}

fn parseLogSummary(request: zap.Request, allocator: std.mem.Allocator) !ParsedLogSummary {
    try request.parseBody();
    var params = try request.parametersToOwnedList(allocator);
    errdefer params.deinit();
    if (params.items.len != 4) return error.InvalidLogSummary;
    var result: @import("contracts.zig").LogSummary = undefined;
    var mask: u4 = 0;
    for (params.items) |param| {
        if (std.mem.eql(u8, param.key, "v")) {
            if (param.value == null or param.value.? != .Int or mask & 1 != 0) return error.InvalidLogSummary;
            result.v = @intCast(param.value.?.Int);
            mask |= 1;
        } else if (std.mem.eql(u8, param.key, "boot_session_id")) {
            if (mask & 2 != 0) return error.InvalidLogSummary;
            result.boot_session_id = stringParam(param.value) orelse return error.InvalidLogSummary;
            mask |= 2;
        } else if (std.mem.eql(u8, param.key, "reason")) {
            if (mask & 4 != 0) return error.InvalidLogSummary;
            result.reason = stringParam(param.value) orelse return error.InvalidLogSummary;
            mask |= 4;
        } else if (std.mem.eql(u8, param.key, "summary")) {
            if (mask & 8 != 0) return error.InvalidLogSummary;
            result.summary = stringParam(param.value) orelse return error.InvalidLogSummary;
            mask |= 8;
        } else return error.InvalidLogSummary;
    }
    if (mask != 15) return error.InvalidLogSummary;
    return .{ .value = result, .params = params };
}

fn stringParam(value: ?zap.Request.HttpParam) ?[]const u8 {
    return if (value) |item| switch (item) {
        .String => |string| string,
        else => null,
    } else null;
}

const StageMapping = struct { event_type: []const u8, phase: node_status.Phase };
fn mapStage(mode: model.ProfileMode, stage: []const u8) ?StageMapping {
    if (mode == .install) {
        const values = [_]struct { []const u8, []const u8, node_status.Phase }{
            .{ "installer_started", "install.installer_started", .installer_started }, .{ "config_fetched", "install.config_fetched", .installer_started }, .{ "started", "install.started", .installing }, .{ "partitioning", "install.partitioning", .installing }, .{ "packages", "install.packages", .installing }, .{ "bootloader", "install.bootloader", .installing }, .{ "post", "install.post", .installing }, .{ "rebooting", "install.rebooting", .installing }, .{ "completed", "install.completed", .completed }, .{ "failed", "install.failed", .failed },
        };
        for (values) |value| if (std.mem.eql(u8, stage, value[0])) return .{ .event_type = value[1], .phase = value[2] };
    } else if (mode == .diskless) {
        const values = [_]struct { []const u8, []const u8, node_status.Phase }{
            .{ "initrd_started", "diskless.initrd_started", .initrd_started }, .{ "rootfs_download_started", "diskless.rootfs_download_started", .rootfs_downloading }, .{ "rootfs_verified", "diskless.rootfs_verified", .rootfs_verified }, .{ "rootfs_mounted", "diskless.rootfs_mounted", .rootfs_mounted }, .{ "switch_root", "diskless.switch_root", .switching_root }, .{ "running", "diskless.running", .running }, .{ "failed", "diskless.failed", .failed },
        };
        for (values) |value| if (std.mem.eql(u8, stage, value[0])) return .{ .event_type = value[1], .phase = value[2] };
    }
    return null;
}

fn bodyWithin(request: zap.Request, maximum: usize) bool {
    const content_length = request.getHeader("content-length") orelse return false;
    const value = std.fmt.parseInt(usize, content_length, 10) catch return false;
    return value <= maximum;
}

fn nodeAuthError(request: zap.Request, err: anyerror, meta: RequestMeta) !void {
    return switch (err) {
        error.MissingProof => json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"node.missing_proof\",\"message\":\"node proof required\"}}\n", meta),
        error.SessionInactive => json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"session_inactive\",\"message\":\"boot session inactive\"}}\n", meta),
        error.ProofMismatch => json(request, .forbidden, "{\"ok\":false,\"error\":{\"code\":\"node.proof_mismatch\",\"message\":\"node proof does not match request\"}}\n", meta),
        else => json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_request\",\"message\":\"invalid node request\"}}\n", meta),
    };
}

fn unixNow() i64 {
    var ts: std.posix.timespec = undefined;
    return if (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts)) == .SUCCESS) @intCast(ts.sec) else 0;
}

fn persistRuntime(context: *const RouteContext) void {
    while (!context.persistence.runtime_mutex.tryLock()) std.Thread.yield() catch {};
    defer context.persistence.runtime_mutex.unlock();
    dhcp_store.save(context.io, context.allocator, context.persistence.runtime_path, @constCast(&context.runtime.dhcp), context.statuses, unixNow()) catch |err|
        observe_log.err("runtime persistence failed: {t}", .{err});
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
        .name = name,
        .kind = kind,
        .path = path,
        .distro = distro,
        .version = version,
        .arch = arch,
        .kernel_release = request.getParamSlice("kernel_release"),
        .sha256 = &checksum,
    }) catch |err| return assetInputError(request, @errorName(err), meta);
    try json(request, .ok, "{\"ok\":true}\n", meta);
}

/// The local management request waits for one bounded import worker, but the
/// expensive mount/copy/hash work itself never runs on the HTTP callback
/// thread.  Publication remains here so catalog replacement is serialized by
/// `CatalogRuntime` only after the worker produced a complete candidate.
fn importInstallSource(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    const filename = request.getParamSlice("filename") orelse return assetInputError(request, "missing filename", meta);
    const distro = request.getParamSlice("distro") orelse return assetInputError(request, "missing distro", meta);
    const version = request.getParamSlice("version") orelse return assetInputError(request, "missing version", meta);
    const arch_text = request.getParamSlice("arch") orelse return assetInputError(request, "missing arch", meta);
    const arch = std.meta.stringToEnum(model.Arch, arch_text) orelse return assetInputError(request, "invalid arch", meta);
    var task: IsoImportTask = .{
        .io = context.io,
        .allocator = context.allocator,
        .config = context.config,
        .request = .{ .filename = filename, .distro = distro, .version = version, .arch = arch },
    };
    const worker = std.Thread.spawn(.{}, runIsoImport, .{&task}) catch |err| {
        observe_log.err("ISO import worker could not start: {t}", .{err});
        return assetInputError(request, "ImportWorkerUnavailable", meta);
    };
    worker.join();
    const imported = task.result orelse {
        const err = task.failure orelse error.ImportWorkerFailed;
        observe_log.err("ISO import failed: {t}", .{err});
        return assetInputError(request, @errorName(err), meta);
    };
    context.catalog.publishInstallSource(context.io, context.config, imported) catch |err| {
        observe_log.err("ISO catalog publication failed: {t}", .{err});
        return assetInputError(request, @errorName(err), meta);
    };
    var body: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&body, "{{\"ok\":true,\"result\":{{\"install_source\":{f}}}}}\n", .{std.json.fmt(imported.source_name, .{})});
    try json(request, .ok, rendered, meta);
}

const IsoImportTask = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const model.AppConfig,
    request: iso_import.Request,
    result: ?iso_import.Result = null,
    failure: ?anyerror = null,
};

fn runIsoImport(task: *IsoImportTask) void {
    task.result = iso_import.importMedia(task.io, task.allocator, task.config, task.request) catch |err| {
        task.failure = err;
        return;
    };
}

fn assetInputError(request: zap.Request, message: []const u8, meta: RequestMeta) !void {
    var buffer: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buffer, "{{\"ok\":false,\"error\":{{\"code\":\"asset.invalid\",\"message\":{f}}}}}\n", .{std.json.fmt(message, .{})});
    try json(request, .bad_request, body, meta);
}

fn managementNodePath(path: []const u8) ?[]const u8 {
    const prefix = "/api/v1/management/nodes/";
    const suffix = "/status";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const node_id = path[prefix.len .. path.len - suffix.len];
    return if (auth.nodeIdSafe(node_id)) node_id else null;
}

/// Exposes the bounded M3 state projection without reading the event stream.
fn runtimeSummary(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    var statuses: [node_status.max_statuses]node_status.Status = undefined;
    context.statuses.snapshot(&statuses);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"nodes\":[");
    var first = true;
    for (statuses) |status| {
        if (!status.used()) continue;
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"id\":{f},\"boot_session_id\":{f},\"phase\":{f},\"last_event_at\":{d},\"last_error\":{s},\"reason\":{f},\"session_active\":{s}}}", .{
            std.json.fmt(status.node(), .{}),           std.json.fmt(status.boot_session_id[0..], .{}), std.json.fmt(@tagName(status.phase), .{}),      status.last_event_at,
            if (status.last_error) "true" else "false", std.json.fmt(status.reasonSlice(), .{}),        if (status.session_active) "true" else "false",
        });
    }
    try output.writer.writeAll("]}}\n");
    try json(request, .ok, output.written(), meta);
}

fn managementNodeStatus(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const status = context.statuses.get(node_id) orelse return notFound(request, meta);
    var output: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&output, "{{\"ok\":true,\"result\":{{\"id\":{f},\"boot_session_id\":{f},\"phase\":{f},\"last_event_at\":{d},\"last_error\":{s},\"reason\":{f},\"session_active\":{s}}}}}\n", .{
        std.json.fmt(status.node(), .{}),           std.json.fmt(status.boot_session_id[0..], .{}), std.json.fmt(@tagName(status.phase), .{}),      status.last_event_at,
        if (status.last_error) "true" else "false", std.json.fmt(status.reasonSlice(), .{}),        if (status.session_active) "true" else "false",
    });
    try json(request, .ok, body, meta);
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
            lease.mac[0],
            lease.mac[1],
            lease.mac[2],
            lease.mac[3],
            lease.mac[4],
            lease.mac[5],
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

test "single byte ranges cover bounded, open-ended and suffix forms" {
    const bounded = try parseSingleRange("bytes=4-7", 10);
    try std.testing.expectEqual(ByteRange{ .offset = 4, .length = 4 }, bounded);
    const clipped = try parseSingleRange("bytes=8-99", 10);
    try std.testing.expectEqual(ByteRange{ .offset = 8, .length = 2 }, clipped);
    const open_ended = try parseSingleRange("bytes=7-", 10);
    try std.testing.expectEqual(ByteRange{ .offset = 7, .length = 3 }, open_ended);
    const suffix = try parseSingleRange("bytes=-4", 10);
    try std.testing.expectEqual(ByteRange{ .offset = 6, .length = 4 }, suffix);
    try std.testing.expectError(error.InvalidRange, parseSingleRange("bytes=0-1,3-4", 10));
    try std.testing.expectError(error.InvalidRange, parseSingleRange("bytes=10-", 10));
}
