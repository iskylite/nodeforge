//! NodeForge 唯一 HTTP listener，基于 Zap/facil.io。
//! HTTP 协议解析、连接生命周期、keep-alive、并发调度和文件/Ranges 支持由 Zap 提供；
//! 本模块仅注册 NodeForge 路由及其 JSON 响应语义。管理路由只接受 loopback peer，
//! 官方 `nodeforge` CLI 固定连接 `127.0.0.1`。
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
const status_store = @import("../state/status_store.zig");
const deployment_control = @import("../state/deployment_control.zig");
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
    deployments: *deployment_control.Store,
    config_revision: u64,
    bootstrap_key: []const u8,
    daemon_instance_id: *const [boot_session.id_len]u8,
    /// M3.1 独立的 I/O 锁，用于 `node-status.json`；永远不与 DHCP checkpoint
    /// worker 的 lease 文件锁竞争。
    status_io_mutex: *std.atomic.Mutex,
    node_status_path: []const u8,
};

/// 路由入口捕获的每请求元数据，传递给 `json` 用于结构化日志和事件追加。
const RequestMeta = struct {
    io: std.Io,
    /// 客户端 IP 地址，仅使用 direct peer，不信任 X-Forwarded-For。
    client_ip: []const u8,
    /// 请求开始时间戳，用于计算响应延迟。
    started: std.Io.Timestamp,
};

// Zap 的底层 listener 暴露一个进程全局请求回调。NodeForge 有意设计为
// 单进程、单 listener 设备，因此此指针在 `zap.start` 的整个阻塞生命周期内
// 保持有效，且之后永远不会被修改。
var active_context: ?*const RouteContext = null;
/// ISO 导入互斥锁。ISO 导入需要 loop-mount 能力并发布多对象 catalog 候选，
/// 限制为 daemon 范围内单一 worker，防止并发本地 CLI 请求耗尽 mount 或竞争发布。
var iso_import_mutex: std.atomic.Mutex = .unlocked;

/// 在所有 IPv4 接口上启动唯一的 NodeForge HTTP listener。
///
/// `server.server_ip` 有意不用作 bind 地址。Zap 将 socket 创建和 HTTP 协议
/// 处理委托给 facil.io；bind 冲突会导致 `listen` 在进程启动 worker 之前失败，
/// 保持 M0 的单 listener 不变量。
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
    deployments: *deployment_control.Store,
    config_revision: u64,
    bootstrap_key: []const u8,
    daemon_instance_id: *const [boot_session.id_len]u8,
    status_io_mutex: *std.atomic.Mutex,
    node_status_path: []const u8,
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
        .deployments = deployments,
        .config_revision = config_revision,
        .bootstrap_key = bootstrap_key,
        .daemon_instance_id = daemon_instance_id,
        .status_io_mutex = status_io_mutex,
        .node_status_path = node_status_path,
    };
    if (active_context != null) return error.HttpAlreadyRunning;
    active_context = &context;
    defer active_context = null;

    var listener = zap.HttpListener.init(.{
        .interface = "0.0.0.0",
        .port = port,
        .on_request = route,
        // Installer stage2 images are routinely larger than 1 GiB.  Zap's
        // listener default (5 seconds) terminates a healthy PXE HTTP transfer
        // on a moderately fast link before Anaconda can finish it.  Keep the
        // transfer window bounded, but long enough for low-bandwidth lab and
        // production networks; request/body limits remain enforced per route.
        .timeout = 120,
        .log = false,
    });
    try listener.listen();
    log.info("listening on http://0.0.0.0:{d}", .{port});
    event_writer.appendWithFields(io, allocator, paths.events_path, "service.started", "all protocol listeners ready", &.{}) catch |err|
        log.err("unable to record service start: {t}", .{err});

    // `workers > 1` enables facil.io cluster mode and forks the listener.
    // Boot sessions are intentionally process-local capability state shared
    // with the DHCP/TFTP threads, so a forked HTTP worker would authenticate
    // against a stale copy and reject the installer's `/answer` request.
    // One worker keeps all protocol state in this process; the event loop
    // remains non-blocking for sendfile downloads and HTTP callbacks.
    zap.start(.{ .threads = 1, .workers = 1 });
}

/// 从底层 facil.io socket 提取客户端 IP。只使用 direct peer 地址；
/// 不信任 X-Forwarded-For，除非有已配置的代理 CIDR 边界。
fn getClientIp(request: zap.Request) []const u8 {
    const addr = zap.fio.http_peer_addr(request.h);
    if (addr.len == 0 or addr.data == null) return "unknown";
    return addr.data[0..addr.len];
}

/// 在 Zap 解析请求后分发管理路由。
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

    // M3.6 管理平面安全边界：管理 API 能写 catalog 状态并触发特权 ISO mount，
    // 它与 PXE HTTP 数据路由共用 listener 只是为了部署便利，永远不用于远程管理。
    // 在分发之前执行此检查，使所有当前和未来的管理端点都继承相同的安全边界。
    // 不信任 X-Forwarded-For，只接受 direct peer 127.0.0.1。
    if (std.mem.startsWith(u8, path, "/api/v1/management/") and !isLoopbackPeer(client_ip))
        return json(request, .forbidden, "{\"ok\":false,\"error\":{\"code\":\"management.local_only\",\"message\":\"management API accepts loopback clients only\"}}\n", meta);

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/healthz"))
        return json(request, .ok, "{\"ok\":true,\"service\":\"nodeforge\"}\n", meta);
    if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD")) {
        if (nodePath(path, "/boot/config/")) |node_id| return bootConfig(request, context, node_id, meta);
        if (assetRoute(path, "/images/")) |name| return imageAsset(request, context, name, meta);
        if (assetRoute(path, "/rootfs/")) |name| return rootfsAsset(request, context, name, meta);
        if (repoRoute(path)) |repo| return repositoryAsset(request, context, repo.name, repo.tail, meta);
        if (std.mem.eql(u8, method, "GET") and std.mem.startsWith(u8, path, "/api/v1/nodes/")) if (splitNodeRoute(path["/api/v1/nodes/".len..])) |node_route| {
            if (std.mem.eql(u8, node_route.suffix, "/config")) return bootConfig(request, context, node_route.node_id, meta);
            if (std.mem.eql(u8, node_route.suffix, "/answer")) return answerFixture(request, context, node_route.node_id, .kickstart, meta);
            if (std.mem.eql(u8, node_route.suffix, "/answer/user-data")) return answerFixture(request, context, node_route.node_id, .user_data, meta);
            if (std.mem.eql(u8, node_route.suffix, "/answer/meta-data")) return answerFixture(request, context, node_route.node_id, .meta_data, meta);
            if (std.mem.eql(u8, node_route.suffix, "/answer/vendor-data")) return answerFixture(request, context, node_route.node_id, .vendor_data, meta);
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
    if (std.mem.eql(u8, method, "POST")) if (installRetryPath(path)) |node_id| return installRetry(request, context, node_id, meta);
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

/// M3.6：检查客户端 IP 是否为 loopback peer（127.0.0.1）。
/// HTTP listener 仅支持 IPv4。精确匹配 127.0.0.1 并 fail closed，
/// 而非信任 X-Forwarded-For 或接受任意私有子网。
fn isLoopbackPeer(client_ip: []const u8) bool {
    // The HTTP listener is IPv4-only. Keep this exact and fail closed rather
    // than trusting X-Forwarded-For or accepting an arbitrary private subnet.
    return std.mem.eql(u8, client_ip, "127.0.0.1");
}

const NodeRoute = struct { node_id: []const u8, suffix: []const u8 };

/// 只返回未转义的单个 URL 段。包含斜杠、百分号编码或第二个路径组件的
/// node id 永远不会被路由为身份。
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
    // Casper accepts a network ISO only when the kernel `url=` value ends in
    // `.iso`. Catalog asset IDs are logical names and need not have that
    // suffix, so `/images/<asset>.iso` is a read-only alias for ISO assets.
    const asset = lookup.findAsset(&context.catalog.value, name) orelse if (std.mem.endsWith(u8, name, ".iso") and name.len > ".iso".len)
        lookup.findAsset(&context.catalog.value, name[0 .. name.len - ".iso".len])
    else
        null;
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
    // M4: URL-decode the tail before file lookup. HTTP clients (e.g., Anaconda)
    // percent-encode special characters in file names such as `libstdc++` →
    // `libstdc%2b%2b`. Without decoding, the server looks for the literal
    // encoded name and returns 404. The decoded path is re-validated inside
    // `staticFile` → `openRegularFile` → `validateRelativePath` to prevent
    // path traversal attacks (e.g., `%2e%2e%2f` decodes to `../`).
    const decode_buf = try context.allocator.alloc(u8, tail.len);
    defer context.allocator.free(decode_buf);
    @memcpy(decode_buf, tail);
    const decoded_tail = std.Uri.percentDecodeInPlace(decode_buf);
    return staticFile(request, context, root, decoded_tail, null, meta);
}

/// M3.6 下载可观测性：NodeForge 解析唯一支持的 Range 形式后，将验证过的
/// 描述符交给 facil.io 的 fd-backed sendfile 路径。这保证了受管 checksum ETag
/// 的权威性：facil.io 的路径助手有不兼容的 `If-Range` 行为并会生成第二个
/// 文件系统派生的 ETag。
///
/// M3.6 日志策略：info 记录每个请求的对象、范围、字节数和客户端；
/// debug 记录已排队的 Range chunk。这使操作员能在 info 级别看到所有下载活动，
/// 在 debug 级别看到更细粒度的分块进度。
fn staticFile(request: zap.Request, context: *const RouteContext, root: []const u8, relative: []const u8, checksum: ?[]const u8, meta: RequestMeta) !void {
    var file = asset_validate.openRegularFile(context.io, root, relative) catch return notFound(request, meta);
    errdefer file.close(context.io);
    const size = (try file.stat(context.io)).size;
    // Subiquity probes APT candidates with HEAD before it runs apt-get.  A
    // GET-only repository therefore appears unavailable even though package
    // files can be downloaded.  Preserve the same path confinement and
    // metadata as GET, but return no body as required by HTTP HEAD.
    if (std.mem.eql(u8, request.method orelse "", "HEAD")) {
        // Zap may invalidate request-owned method/path slices as soon as
        // sendBody hands the response back to facil.io. Preserve the path so
        // the terminal log and event never observe released request memory.
        const request_path = try context.allocator.dupe(u8, request.path orelse "<missing>");
        defer context.allocator.free(request_path);
        request.setStatus(.ok);
        try request.setHeader("accept-ranges", "bytes");
        request.setContentTypeFromFilename(relative) catch try request.setHeader("content-type", "application/octet-stream");
        var length: [20]u8 = undefined;
        try request.setHeader("content-length", try std.fmt.bufPrint(&length, "{d}", .{size}));
        try request.sendBody("");
        file.close(context.io);
        recordStaticCompletion("HEAD", request_path, context, relative, 200, 0, size, meta);
        return;
    }
    if (checksum) |hash| {
        var etag: [68]u8 = undefined;
        const value = try std.fmt.bufPrint(&etag, "\"{s}\"", .{hash});
        try request.setHeader("etag", value);
        if (request.getHeader("range")) |range_value| if (request.getHeader("if-range")) |if_range| {
            if (!std.mem.eql(u8, if_range, value)) return sendWholeFile(request, context, &file, size, relative, meta);
            return sendRangedFile(request, context, &file, size, relative, range_value, meta);
        } else return sendRangedFile(request, context, &file, size, relative, range_value, meta);
    }
    if (request.getHeader("range")) |range_value| return sendRangedFile(request, context, &file, size, relative, range_value, meta);
    return sendWholeFile(request, context, &file, size, relative, meta);
}

const ByteRange = struct { offset: u64, length: u64 };

fn sendRangedFile(request: zap.Request, context: *const RouteContext, file: *std.Io.File, size: u64, relative: []const u8, range_value: []const u8, meta: RequestMeta) !void {
    const range = parseSingleRange(range_value, size) catch {
        file.close(context.io);
        return rangeNotSatisfiable(request, context, size, relative, meta);
    };
    request.setStatusNumeric(206);
    var content_range: [96]u8 = undefined;
    const value = try std.fmt.bufPrint(&content_range, "bytes {d}-{d}/{d}", .{ range.offset, range.offset + range.length - 1, size });
    try request.setHeader("content-range", value);
    try sendManagedFile(request, context, file, range, size, relative, 206, meta);
}

fn sendWholeFile(request: zap.Request, context: *const RouteContext, file: *std.Io.File, size: u64, relative: []const u8, meta: RequestMeta) !void {
    try sendManagedFile(request, context, file, .{ .offset = 0, .length = size }, size, relative, 200, meta);
}

fn sendManagedFile(request: zap.Request, context: *const RouteContext, file: *std.Io.File, range: ByteRange, total_size: u64, relative: []const u8, status: u16, meta: RequestMeta) !void {
    // `http_sendfile` can release request-owned method/path storage before it
    // returns. Preserve the path for the synchronous audit event below, just
    // as the sendBody-backed HEAD and 416 branches do.
    const request_path = try context.allocator.dupe(u8, request.path orelse "<missing>");
    defer context.allocator.free(request_path);
    try request.setHeader("accept-ranges", "bytes");
    request.setContentTypeFromFilename(relative) catch try request.setHeader("content-type", "application/octet-stream");
    // M3.6 下载日志：info 记录每个 HTTP 下载请求的对象、范围、字节数和客户端 IP。
    log.info("HTTP download request GET {s} (range={d}+{d}/{d}, client={s})", .{ relative, range.offset, range.length, total_size, meta.client_ip });
    const result = zap.fio.http_sendfile(request.h, file.handle, @intCast(range.length), @intCast(range.offset));
    if (result != 0) return error.SendFile;
    // M3.6 下载日志：facil.io 拥有异步 sendfile 完成回调。我们有意将其标记为
    // queued progress 而非声称是 peer ACK progress；每个 HTTP Range 请求
    // 仍被记录为一个精确的 chunk。
    log.debug("HTTP download queued {s}: {d}/{d} bytes (range {d}+{d})", .{ relative, range.offset + range.length, total_size, range.offset, range.length });
    // `request.h.*.status` is not authoritative here: facil.io can retain its
    // default value until the asynchronous sendfile response is committed.
    // The caller owns the HTTP decision (200 whole file or 206 range), so pass
    // that value explicitly to keep terminal logs and events accurate.
    recordStaticCompletion("GET", request_path, context, relative, status, range.length, total_size, meta);
    request.markAsFinished(true);
}

fn rangeNotSatisfiable(request: zap.Request, context: *const RouteContext, size: u64, relative: []const u8, meta: RequestMeta) !void {
    const request_path = try context.allocator.dupe(u8, request.path orelse "<missing>");
    defer context.allocator.free(request_path);
    request.setStatusNumeric(416);
    var content_range: [64]u8 = undefined;
    try request.setHeader("content-range", try std.fmt.bufPrint(&content_range, "bytes */{d}", .{size}));
    try request.setHeader("accept-ranges", "bytes");
    try request.sendBody("");
    recordStaticCompletion("GET", request_path, context, relative, 416, 0, size, meta);
}

/// Record the terminal state of every static HTTP response, including HEAD
/// probes. For sendfile-backed GET responses this means the response was
/// successfully queued to facil.io; it is not a claim that the peer ACKed all
/// bytes. The explicit `response_state` field preserves that distinction.
fn recordStaticCompletion(method: []const u8, path: []const u8, context: *const RouteContext, relative: []const u8, status: u16, bytes_sent: u64, object_size: u64, meta: RequestMeta) void {
    const duration_us = meta.started.durationTo(std.Io.Clock.awake.now(meta.io)).toMicroseconds();
    const response_state = if (std.mem.eql(u8, method, "GET") and status >= 200 and status < 300) "queued" else "completed";
    log.info("{s} {s} -> {d} ({d} bytes, {d}us, client={s}, asset={s}, object_bytes={d}, response_state={s})", .{
        method, path, status, bytes_sent, duration_us, meta.client_ip, relative, object_size, response_state,
    });

    var status_text: [4]u8 = undefined;
    var bytes_text: [20]u8 = undefined;
    var object_bytes_text: [20]u8 = undefined;
    var duration_text: [20]u8 = undefined;
    const fields = [_]events.Field{
        .{ .key = "method", .value = method },
        .{ .key = "path", .value = path },
        .{ .key = "status", .value = std.fmt.bufPrint(&status_text, "{d}", .{status}) catch "0" },
        .{ .key = "bytes_sent", .value = std.fmt.bufPrint(&bytes_text, "{d}", .{bytes_sent}) catch "0" },
        .{ .key = "object_bytes", .value = std.fmt.bufPrint(&object_bytes_text, "{d}", .{object_size}) catch "0" },
        .{ .key = "client_ip", .value = meta.client_ip },
        .{ .key = "duration_us", .value = std.fmt.bufPrint(&duration_text, "{d}", .{duration_us}) catch "0" },
        .{ .key = "response_state", .value = response_state },
    };
    context.event_writer.appendWithFields(context.io, context.allocator, paths.events_path, "http.request", "HTTP request completed", &fields) catch |err|
        observe_log.err("http: event append failed: {t}", .{err});
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

/// 在 DHCP peer bootstrap 或先前签发的 bearer capability 认证通过后，
/// 签发 M3 BootConfig v1 文档。密钥只出现在此认证响应中，永远不会出现在
/// 事件、错误信封、URL 或日志中。
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
    if (!persistStatus(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"status.persist_failed\",\"message\":\"node status persistence failed\"}}\n", meta);
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

/// M4 installer answer renderer: serves Kickstart (RHEL) or Autoinstall
/// user-data/meta-data (Ubuntu) to authenticated install-mode nodes.
/// Bootstrap proof (peer IP match) is accepted on the first fetch and
/// upgraded to a capability token; subsequent requests use capability proof.
const AnswerFormat = enum { kickstart, user_data, meta_data, vendor_data };
fn answerFixture(request: zap.Request, context: *const RouteContext, node_id: []const u8, format: AnswerFormat, meta: RequestMeta) !void {
    const checked = auth.authenticate(context.sessions, node_id, meta.client_ip, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.session.mode != .install) return nodeAuthError(request, error.ProofMismatch, meta);
    const session = if (checked.proof == .bootstrap)
        context.sessions.issueCapability(context.io, checked.session.boot_session_id[0..], boot_session.monotonicNow(), unixNow()) catch |err| return nodeAuthError(request, err, meta)
    else
        checked.session;
    context.sessions.touchDelivery(session.boot_session_id[0..], boot_session.monotonicNow(), unixNow());
    const event_url = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}/api/v1/nodes/{s}/events", .{ context.config.server.server_ip, context.config.server.http_port, node_id });
    defer context.allocator.free(event_url);
    const node = lookup.findNode(context.config, node_id) orelse return notFound(request, meta);
    const profile = lookup.findProfile(context.config, session.profile) orelse return notFound(request, meta);
    const install = profile.install orelse return error.MissingInstallConfig;
    const system = try @import("../profile/install.zig").effectiveSystem(profile);
    const bundle = if (install.bundle) |name| findProvisioningBundle(context.config, name) else null;
    var password_scope_buffer: [128]u8 = undefined;
    const password_scope = try std.fmt.bufPrint(&password_scope_buffer, "{s}:{s}:{d}", .{ context.daemon_instance_id.*[0..], session.boot_session_id[0..], context.config_revision });
    // APT 源 URL 解析：Ubuntu ISO 导入时始终创建 repository 条目
    //（即使 ISO 不含完整 APT metadata），因此 findRepository 应总能找到。
    // 保留 fallback 逻辑以兼容手动配置场景：当 repository 不存在时，
    // 构造 /repos/<source_name>/ URL，使 apt 请求快速 404 而非 DNS 超时。
    const apt_primary_url = if (format == .user_data) blk: {
        context.catalog.lock();
        defer context.catalog.unlock();
        const source = lookup.findInstallSource(&context.catalog.value, profile.install_source orelse break :blk null) orelse break :blk null;
        if (std.mem.eql(u8, source.distro, "ubuntu")) {
            // Ubuntu: 优先使用 repository.base_url；若不存在则构造 fallback URL
            const repository = lookup.findRepository(&context.catalog.value, source.name);
            if (repository) |repo| if (repo.manager == .apt) break :blk repo.base_url;
            break :blk try std.fmt.allocPrint(context.allocator, "http://{s}:{d}/repos/{s}", .{ context.config.server.server_ip, context.config.server.http_port, source.name });
        }
        break :blk null;
    } else null;
    const body = switch (format) {
        .meta_data => try @import("../profile/adapter/ubuntu.zig").renderMetaData(context.allocator, node),
        .user_data => try @import("../profile/adapter/ubuntu.zig").renderUserDataM41(context.allocator, node, install, system, context.bootstrap_key, bundle, apt_primary_url, event_url, session.boot_session_id[0..], session.capability[0..], password_scope),
        .vendor_data => try context.allocator.dupe(u8, ""),
        .kickstart => blk: {
            context.catalog.lock();
            defer context.catalog.unlock();
            const source = lookup.findInstallSource(&context.catalog.value, profile.install_source orelse return notFound(request, meta)) orelse return notFound(request, meta);
            const install_root = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}/repos/{s}", .{ context.config.server.server_ip, context.config.server.http_port, source.name });
            defer context.allocator.free(install_root);
            break :blk try @import("../profile/adapter/kickstart.zig").renderAnswerM41(context.allocator, node, install, system, context.bootstrap_key, install_root, bundle, event_url, session.boot_session_id[0..], session.capability[0..], password_scope);
        },
    };
    defer context.allocator.free(body);
    request.setStatus(.ok);
    try request.setHeader("content-type", "text/plain; charset=utf-8");
    try request.setHeader("cache-control", "no-store");
    // `sendBody` may hand the response back to facil.io immediately; log the
    // borrowed route segment before that hand-off rather than retaining a
    // request-owned slice for diagnostics afterwards.
    log.info("GET installer answer -> 200 (node={s}, client={s})", .{ node_id, meta.client_ip });
    // M4: Record the HTTP request event for observability. `answerFixture`
    // does not use the `json()` helper (which handles event logging), so the
    // event must be appended explicitly. Without this, successful kickstart/
    // autoinstall fetches are invisible in events.jsonl.
    {
        const duration_us = meta.started.durationTo(std.Io.Clock.awake.now(meta.io)).toMicroseconds();
        var status_text: [4]u8 = undefined;
        var bytes_text: [20]u8 = undefined;
        var duration_text: [20]u8 = undefined;
        const req_path = request.path orelse "<missing>";
        const req_method = request.method orelse "OTHER";
        const fields = [_]events.Field{
            .{ .key = "method", .value = req_method },
            .{ .key = "path", .value = req_path },
            .{ .key = "status", .value = std.fmt.bufPrint(&status_text, "200", .{}) catch "0" },
            .{ .key = "bytes_sent", .value = std.fmt.bufPrint(&bytes_text, "{d}", .{body.len}) catch "0" },
            .{ .key = "client_ip", .value = meta.client_ip },
            .{ .key = "duration_us", .value = std.fmt.bufPrint(&duration_text, "{d}", .{duration_us}) catch "0" },
        };
        context.event_writer.appendWithFields(context.io, context.allocator, paths.events_path, "http.request", "HTTP request completed", &fields) catch |err|
            observe_log.err("http: event append failed: {t}", .{err});
    }
    try request.sendBody(body);
}

fn findProvisioningBundle(config: *const model.AppConfig, name: []const u8) ?*const model.ProvisioningBundle {
    for (config.provisioning_bundles) |*bundle| if (std.mem.eql(u8, bundle.name, name)) return bundle;
    return null;
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
    const terminal = std.mem.eql(u8, event.value.stage, "completed") or std.mem.eql(u8, event.value.stage, "failed");
    // A generation is consumed only when the installer itself reports it has
    // started, never when DHCP, TFTP, or answer delivery merely succeeds.
    if (checked.session.mode == .install and std.mem.eql(u8, event.value.stage, "started")) {
        const consumed = context.deployments.consume(node_id) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot consume install generation\"}}\n", meta);
        deployment_control.save(context.io, context.allocator, paths.deployment_control_path, context.deployments) catch |err| {
            if (consumed) |result| context.deployments.rollbackConsume(node_id, result);
            observe_log.err("deployment-control save failed: {t}", .{err});
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot persist install generation\"}}\n", meta);
        };
    }
    if (checked.session.mode == .install and terminal) {
        const terminal_result = context.deployments.markTerminal(node_id, std.mem.eql(u8, event.value.stage, "completed"));
        deployment_control.save(context.io, context.allocator, paths.deployment_control_path, context.deployments) catch |err| {
            if (terminal_result) |result| context.deployments.rollbackTerminal(node_id, result);
            observe_log.err("deployment-control applied revision save failed: {t}", .{err});
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot persist applied install revision\"}}\n", meta);
        };
    }
    context.statuses.update(node_id, checked.session.boot_session_id[0..], context.daemon_instance_id, mapped.phase, event.value.reason, unixNow(), !terminal) catch |err|
        observe_log.err("node status update failed: {t}", .{err});
    if (!persistStatus(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"status.persist_failed\",\"message\":\"node status persistence failed\"}}\n", meta);
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
    if (terminal) {
        context.sessions.finishDelivery(checked.session.boot_session_id[0..], if (std.mem.eql(u8, event.value.stage, "completed")) .completed else .failed, boot_session.monotonicNow(), unixNow());
    } else {
        const phase: boot_session.Phase = if (std.mem.eql(u8, event.value.stage, "installer_started")) .installer_started else .installing;
        context.sessions.advanceDelivery(checked.session.boot_session_id[0..], phase, boot_session.monotonicNow(), unixNow());
    }
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
    context.statuses.update(node_id, checked.session.boot_session_id[0..], context.daemon_instance_id, .failed, summary.value.reason, unixNow(), false) catch |err|
        observe_log.err("node status update failed: {t}", .{err});
    if (!persistStatus(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"status.persist_failed\",\"message\":\"node status persistence failed\"}}\n", meta);
    const fields = [_]events.Field{ .{ .key = "node_id", .value = node_id }, .{ .key = "boot_session_id", .value = checked.session.boot_session_id[0..] }, .{ .key = "reason", .value = summary.value.reason } };
    context.event_writer.appendWithFields(context.io, context.allocator, paths.events_path, event_type, summary.value.summary, &fields) catch |err| {
        observe_log.err("node log append failed: {t}", .{err});
        return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"events.unavailable\",\"message\":\"event writer unavailable\"}}\n", meta);
    };
    context.sessions.finishDelivery(checked.session.boot_session_id[0..], .failed, boot_session.monotonicNow(), unixNow());
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
            .{ "installer_started", "install.installer_started", .installer_started }, .{ "config_fetched", "install.config_fetched", .install_config_fetched }, .{ "started", "install.started", .install_started }, .{ "partitioning", "install.partitioning", .install_partitioning }, .{ "packages", "install.packages", .install_packages }, .{ "bootloader", "install.bootloader", .install_bootloader }, .{ "post", "install.post", .install_post }, .{ "rebooting", "install.rebooting", .install_rebooting }, .{ "completed", "install.completed", .completed }, .{ "failed", "install.failed", .failed },
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
    // This deliberately records only the stable error tag and direct peer;
    // credentials, headers and request body are never logged.
    // A rejected installer bootstrap must be visible at the normal operating
    // log level while still excluding credentials, headers and request bodies.
    observe_log.warn("node auth rejected client={s} reason={t}", .{ meta.client_ip, err });
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

fn persistStatus(context: *const RouteContext) bool {
    var snapshot: [node_status.max_statuses]node_status.Status = undefined;
    context.statuses.snapshot(&snapshot);
    while (!context.status_io_mutex.tryLock()) std.Thread.yield() catch {};
    defer context.status_io_mutex.unlock();
    status_store.save(context.io, context.allocator, context.node_status_path, &snapshot, unixNow()) catch |err| {
        observe_log.err("status: persistence failed: {t}", .{err});
        return false;
    };
    return true;
}

/// 为时间不重要的提前退出构造占位 meta。
fn undefined_meta(context: *const RouteContext) RequestMeta {
    return .{ .io = context.io, .client_ip = "unknown", .started = std.Io.Clock.awake.now(context.io) };
}

/// 通过 daemon 注册一个已存在的资产，只有 daemon 能发布新的 catalog 快照。
/// 查询字段有意只接受受约束的 M1 CLI 词汇表；任意文件路径和已解码的 URL
/// 字符串会被与直接 TFTP 服务相同的资产校验器拒绝。
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

/// M3.6：本地管理请求等待一个有界 import worker，但昂贵的 mount/copy/hash
/// 工作本身永远不在 HTTP callback 线程上执行。等待中的 handler 占用两个
/// HTTP worker 之一，而 daemon 范围内的 import mutex 拒绝并发 import 并
/// 保留另一个 worker 供数据面请求使用。Publication 保留在此处，使 catalog
/// 替换仅在完整候选存在后才被序列化。
fn importInstallSource(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    const filename = request.getParamSlice("filename") orelse return assetInputError(request, "missing filename", meta);
    const distro = request.getParamSlice("distro");
    const version = request.getParamSlice("version");
    const arch_text = request.getParamSlice("arch");
    const arch = if (arch_text) |value| std.meta.stringToEnum(model.Arch, value) orelse return assetInputError(request, "invalid arch", meta) else null;
    if (!iso_import_mutex.tryLock()) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install_source.busy\",\"message\":\"another ISO import is running\"}}\n", meta);
    defer iso_import_mutex.unlock();
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
        // importMedia has already copied immutable files into managed roots.
        // A rejected candidate must not accumulate inaccessible public-root
        // orphans (for example, when the media tuple is not declared in the
        // operator's configured distro matrix).
        iso_import.cleanupPublishedOutputs(context.io, context.allocator, context.config, &imported);
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

fn installRetryPath(path: []const u8) ?[]const u8 {
    const prefix = "/api/v1/management/nodes/";
    const suffix = "/install/retry";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const node_id = path[prefix.len .. path.len - suffix.len];
    return if (auth.nodeIdSafe(node_id)) node_id else null;
}

fn installRetry(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const node = lookup.findNode(context.config, node_id) orelse return notFound(request, meta);
    const profile = lookup.findProfile(context.config, node.profile) orelse return notFound(request, meta);
    if (profile.mode != .install) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.not_profile\",\"message\":\"node does not have an install profile\"}}\n", meta);
    if (context.sessions.hasActiveNode(node_id, boot_session.monotonicNow())) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.session_active\",\"message\":\"active install session cannot be rearmed\"}}\n", meta);
    const requested_at = unixNow();
    const rearm = context.deployments.rearm(node_id, context.config_revision, requested_at, .operator) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot rearm install generation\"}}\n", meta);
    if (rearm.changed) {
        deployment_control.save(context.io, context.allocator, paths.deployment_control_path, context.deployments) catch {
            context.deployments.rollbackRearm(node_id, rearm);
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot persist install generation\"}}\n", meta);
        };
        var generation_text: [24]u8 = undefined;
        var revision_text: [24]u8 = undefined;
        var requested_at_text: [24]u8 = undefined;
        const fields = [_]events.Field{
            .{ .key = "node_id", .value = node_id },
            .{ .key = "generation", .value = std.fmt.bufPrint(&generation_text, "{d}", .{rearm.generation}) catch "0" },
            .{ .key = "config_revision", .value = std.fmt.bufPrint(&revision_text, "{d}", .{context.config_revision}) catch "0" },
            .{ .key = "requested_at", .value = std.fmt.bufPrint(&requested_at_text, "{d}", .{requested_at}) catch "0" },
            .{ .key = "requested_by", .value = "operator" },
            .{ .key = "replaced_stale_revision", .value = if (rearm.replaced) "true" else "false" },
        };
        context.event_writer.appendWithFields(context.io, context.allocator, paths.events_path, "install.retry.requested", "install generation rearmed", &fields) catch |err| observe_log.err("retry event append failed: {t}", .{err});
    }
    var body: [160]u8 = undefined;
    return json(request, .ok, try std.fmt.bufPrint(&body, "{{\"ok\":true,\"result\":{{\"node_id\":{f},\"generation\":{d},\"message\":\"rearmed; waiting for next PXE\"}}}}\n", .{ std.json.fmt(node_id, .{}), rearm.generation }), meta);
}

/// 暴露有界的 M3 状态投影，不读取事件流。
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
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"id\":{f},\"boot_session_id\":{f},\"phase\":{f},\"last_event_at\":{d},\"last_error\":{s},\"reason\":{f},\"session_active\":{s}", .{
        std.json.fmt(status.node(), .{}),           std.json.fmt(status.boot_session_id[0..], .{}), std.json.fmt(@tagName(status.phase), .{}),      status.last_event_at,
        if (status.last_error) "true" else "false", std.json.fmt(status.reasonSlice(), .{}),        if (status.session_active) "true" else "false",
    });
    if (context.deployments.view(node_id)) |deployment| {
        try output.writer.print(",\"deployment\":{{\"armed_generation\":{f},\"consumed_generation\":{f},\"terminal_generation\":{f},\"requested_revision\":{d},\"applied_revision\":{d},\"desired_revision\":{d},\"drifted\":{s},\"requested_at\":{d},\"requested_by\":{f}}}", .{
            std.json.fmt(deployment.armed_generation, .{}),
            std.json.fmt(deployment.consumed_generation, .{}),
            std.json.fmt(deployment.terminal_generation, .{}),
            deployment.requested_revision,
            deployment.applied_revision,
            context.config_revision,
            if (deployment.applied_revision != 0 and deployment.applied_revision != context.config_revision) "true" else "false",
            deployment.requested_at,
            std.json.fmt(@tagName(deployment.requested_by), .{}),
        });
    }
    try output.writer.writeAll("}}\n");
    try json(request, .ok, output.written(), meta);
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

/// 渲染有界的 M1 传输活动列表。条目有意设计为短生命周期操作状态；
/// 审计历史属于后续阶段的 `events.jsonl`，不是无界的 HTTP 响应。
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

/// 使用 NodeForge 的稳定错误信封渲染配置校验失败。
fn validationError(request: zap.Request, err: anyerror, meta: RequestMeta) !void {
    var buffer: [512]u8 = undefined;
    const body = observe_error.renderJson(&buffer, observe_error.fromValidation(err)) catch
        "{\"ok\":false,\"error\":{\"code\":\"internal.buffer\",\"message\":\"response too large\"}}\n";
    try json(request, .bad_request, body, meta);
}

/// 发出统一的 JSON 404 信封，而非绕过管理错误契约。
fn notFound(request: zap.Request, meta: RequestMeta) !void {
    try json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"http.not_found\",\"message\":\"route not found\"}}\n", meta);
}

/// 通过 Zap 发送 JSON 响应并记录方法、路径、状态码、字节数、持续时间和
/// 客户端 IP。请求体和凭据永远不会进入日志。
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
    try std.testing.expect(isLoopbackPeer("127.0.0.1"));
    try std.testing.expect(!isLoopbackPeer("192.168.50.9"));
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
