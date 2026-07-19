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
const node_mutation = @import("../config/node_mutation.zig");
const runtime_state = @import("../state/runtime.zig");
const catalog_runtime = @import("../state/catalog_runtime.zig");
const config_runtime = @import("../state/config_runtime.zig");
const model_runtime = @import("../state/model_runtime.zig");
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
const catalog_migration = @import("../catalog/migration.zig");
const model_transaction = @import("../state/model_transaction.zig");
const config_store = @import("../config/store.zig");
const catalog_store = @import("../catalog/store.zig");
const dhcp_server = @import("../dhcp/server.zig");
const status_store = @import("../state/status_store.zig");
const boot_session_store = @import("../state/boot_session_store.zig");
const deployment_control = @import("../state/deployment_control.zig");
const node_inventory = @import("../state/node_inventory.zig");
const operations = @import("../state/operations.zig");
const routes = @import("routes.zig");
const log = std.log.scoped(.http);

const RouteContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const model.AppConfig,
    configs: *config_runtime.ConfigRuntime,
    catalog: *catalog_runtime.CatalogRuntime,
    models: *model_runtime.ModelRuntime,
    catalog_snapshot: *const catalog_runtime.Snapshot,
    runtime: *const runtime_state.RuntimeState,
    event_writer: *events.Writer,
    sessions: *boot_session.Store,
    statuses: *node_status.Store,
    deployments: *deployment_control.Store,
    inventories: *node_inventory.Store,
    operations: *operations.Store,
    config_revision: u64,
    bootstrap_key: []const u8,
    /// M4.2 F5：来自配置和状态目录的额外 SSH 公钥。
    additional_keys: []const []const u8,
    daemon_instance_id: *const [boot_session.id_len]u8,
    /// M3.1 独立的 I/O 锁，用于 `node-status.json`；永远不与 DHCP checkpoint
    /// worker 的 lease 文件锁竞争。
    status_io_mutex: *std.atomic.Mutex,
    node_status_path: []const u8,
    /// config.json 路径，供 config+catalog 联合迁移事务定位事实源。
    config_path: []const u8,
};

/// 路由入口捕获的每请求元数据，传递给 `json` 用于结构化日志和事件追加。
const RequestMeta = struct {
    io: std.Io,
    /// 客户端 IP 地址，仅使用 direct peer，不信任 X-Forwarded-For。
    client_ip: []const u8,
    /// 请求开始时间戳，用于计算响应延迟。
    started: std.Io.Timestamp,
    /// M4.5：32 位十六进制请求标识，写入每个错误信封的 `request_id`，
    /// 便于 CLI 把失败关联回具体请求。全 0 表示路由元数据就绪前生成的响应。
    request_id: [32]u8 = [_]u8{'0'} ** 32,
};

// Zap 的底层 listener 暴露一个进程全局请求回调。NodeForge 有意设计为
// 单进程、单 listener 设备，因此此指针在 `zap.start` 的整个阻塞生命周期内
// 保持有效，且之后永远不会被修改。
var active_context: ?*RouteContext = null;
/// ISO 导入互斥锁。ISO 导入需要 loop-mount 能力并发布多对象 catalog 候选，
/// 限制为 daemon 范围内单一 worker，防止并发本地 CLI 请求耗尽 mount 或竞争发布。
var iso_import_mutex: std.atomic.Mutex = .unlocked;
var config_mutation_mutex: std.atomic.Mutex = .unlocked;

/// M4.5：单调递增的请求序号，用于生成 `request_id`。本机 daemon 请求量小，
/// 进程内序号足以区分；进程重启从 0 重新开始，不承诺跨进程全局唯一。
var request_counter: std.atomic.Value(u64) = .{ .raw = 0 };

/// M4.9：从 route entry 固定的 config/catalog pair 计算部署指纹。
/// 禁止回退 `config_revision`：它有意排除 catalog-owned node/profile，
/// 回退会让 HTTP arm/plan/status 与 DHCP generation gate 使用不同事实源。
fn desiredRevision(context: *const RouteContext) !u64 {
    const revision = try deployment_control.revisionForModel(context.allocator, context.config, context.catalog_snapshot.value());
    return revision.desiredRevision();
}

fn desiredPlanDigest(context: *const RouteContext, node_id: []const u8) !deployment_control.Digest {
    return @import("../state/plan_digest.zig").forNode(context.allocator, context.config, context.catalog_snapshot.value(), .{
        .bootstrap_key = context.bootstrap_key,
        .additional_keys = context.additional_keys,
    }, node_id);
}

/// 用 32 位零填充十六进制写入请求标识（序号足够区分本机 daemon 的请求）。
fn nextRequestId(out: *[32]u8) void {
    const seq = request_counter.fetchAdd(1, .monotonic);
    _ = std.fmt.bufPrint(out, "{x:0>32}", .{seq}) catch unreachable;
}

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
    configs: *config_runtime.ConfigRuntime,
    catalog: *catalog_runtime.CatalogRuntime,
    models: *model_runtime.ModelRuntime,
    runtime: *const runtime_state.RuntimeState,
    event_writer: *events.Writer,
    sessions: *boot_session.Store,
    statuses: *node_status.Store,
    deployments: *deployment_control.Store,
    inventories: *node_inventory.Store,
    operation_store: *operations.Store,
    config_revision: u64,
    bootstrap_key: []const u8,
    additional_keys: []const []const u8,
    daemon_instance_id: *const [boot_session.id_len]u8,
    status_io_mutex: *std.atomic.Mutex,
    node_status_path: []const u8,
    config_path: []const u8,
) !void {
    try routes.validate();
    if (!std.mem.eql(u8, ip, "0.0.0.0")) return error.InvalidHttpBindAddress;
    const initial_pair = models.acquire();
    defer initial_pair.release();
    const config = initial_pair.config.value();

    var context = RouteContext{
        .io = io,
        .allocator = allocator,
        .config = config,
        .configs = configs,
        .catalog = catalog,
        .models = models,
        .catalog_snapshot = initial_pair.catalog,
        .runtime = runtime,
        .event_writer = event_writer,
        .sessions = sessions,
        .statuses = statuses,
        .deployments = deployments,
        .inventories = inventories,
        .operations = operation_store,
        .config_revision = config_revision,
        .bootstrap_key = bootstrap_key,
        .additional_keys = additional_keys,
        .daemon_instance_id = daemon_instance_id,
        .status_io_mutex = status_io_mutex,
        .node_status_path = node_status_path,
        .config_path = config_path,
    };
    if (active_context != null) return error.HttpAlreadyRunning;
    active_context = &context;
    defer active_context = null;

    var listener = zap.HttpListener.init(.{
        .interface = "0.0.0.0",
        .port = port,
        .on_request = route,
        // 安装器 stage2 镜像通常超过 1 GiB。Zap listener 默认超时（5 秒）
        // 在中等速率链路上会在 Anaconda 完成传输前中断正常的 PXE HTTP 传输。
        // 保持传输窗口有界但足够长以适应低带宽实验和生产网络；
        // 请求体限制仍按路由独立执行。
        .timeout = 120,
        .log = false,
    });
    try listener.listen();
    log.info("listening on http://0.0.0.0:{d}", .{port});
    event_writer.appendWithFields(io, allocator, paths.require().events_path, "service.started", "all protocol listeners ready", &.{}) catch |err|
        log.err("unable to record service start: {t}", .{err});

    // `workers > 1` 启用 facil.io cluster 模式并 fork listener。
    // Boot session 是刻意设计为进程本地的能力状态，与 DHCP/TFTP 线程共享，
    // 因此 fork 出的 HTTP worker 会用过期副本认证，拒绝安装器的 `/install-config/kickstart` 请求。
    // 单 worker 保持所有协议状态在此进程内；事件循环对 sendfile 下载和
    // HTTP 回调保持非阻塞。
    zap.start(.{ .threads = 1, .workers = 1 });
}

/// 从底层 facil.io socket 提取客户端 IP。只使用 direct peer 地址；
/// 不信任 X-Forwarded-For，除非有已配置的代理 CIDR 边界。
fn getClientIp(request: zap.Request) []const u8 {
    const addr = zap.fio.http_peer_addr(request.h);
    if (addr.len == 0 or addr.data == null) return "unknown";
    return addr.data[0..addr.len];
}

/// 在 Zap 解析请求后分发路由。
///
/// M4.4 路由平面分离：
/// - 节点交付 API：`/api/v1/nodes/:id/**`
/// - 本机管理 API：`/api/v1/management/**`（loopback only）
/// - 静态制品：`/artifacts/**`
/// - 进程健康探针：`/healthz`（无版本、无认证）
///
/// 旧 URL 不注册，直接返回 404；不实现 redirect、alias 或兼容路由。
fn route(request: zap.Request) !void {
    const shared_context = active_context orelse return error.MissingRouteContext;
    const model_pair = shared_context.models.acquire();
    defer model_pair.release();
    var request_context = shared_context.*;
    request_context.config = model_pair.config.value();
    request_context.config_revision = model_pair.config.revision;
    request_context.catalog_snapshot = model_pair.catalog;
    const context = &request_context;
    const path = request.path orelse return notFound(request, undefined_meta(context));
    const method = request.method orelse return notFound(request, undefined_meta(context));
    const started = std.Io.Clock.awake.now(context.io);
    const client_ip = getClientIp(request);
    var meta = RequestMeta{ .io = context.io, .client_ip = client_ip, .started = started };
    nextRequestId(&meta.request_id);

    observe_log.debug("http: request received {s} {s}", .{ method, path });

    // M4.5 request contract: every non-empty JSON API body must declare its
    // media type. Subiquity's curtin webhook is the single form-urlencoded
    // exception mandated by the installer protocol.
    if (request.body) |body| if (body.len != 0 and
        !std.mem.endsWith(u8, path, "/installer-hooks/subiquity") and
        (std.mem.startsWith(u8, path, "/api/v1/") and !jsonRequest(request)))
        return unsupportedMediaType(request, meta);

    // M4.5：管理写请求体必须有界。仅当请求声明了 Content-Length 且超过 64 KiB
    // 时返回 413；空 body 的写请求（如 config/validations、install-generations）
    // 不声明或声明 0，不触发 413，交由 handler 处理。
    if (std.mem.startsWith(u8, path, "/api/v1/management/") and
        (std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "PATCH")) and
        managementBodyTooLarge(request))
        return json(request, .content_too_large, "{\"ok\":false,\"error\":{\"code\":\"http.body_too_large\",\"message\":\"management request body exceeds 64 KiB limit\"}}\n", meta);

    // M3.6 管理平面安全边界：管理 API 能写 catalog 状态并触发特权 ISO mount，
    // 它与 PXE HTTP 数据路由共用 listener 只是为了部署便利，永远不用于远程管理。
    // 在分发之前执行此检查，使所有当前和未来的管理端点都继承相同的安全边界。
    // 不信任 X-Forwarded-For，只接受 direct peer 127.0.0.1。
    if (std.mem.startsWith(u8, path, "/api/v1/management/") and !isLoopbackPeer(client_ip))
        return json(request, .forbidden, "{\"ok\":false,\"error\":{\"code\":\"management.local_only\",\"message\":\"management API accepts loopback clients only\"}}\n", meta);

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/healthz"))
        return json(request, .ok, "{\"ok\":true,\"service\":\"nodeforge\"}\n", meta);

    // ── 节点交付 API ──────────────────────────────────────────
    if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD")) {
        if (std.mem.startsWith(u8, path, "/api/v1/nodes/")) if (splitNodeRoute(path["/api/v1/nodes/".len..])) |node_route| {
            if (std.mem.eql(u8, node_route.suffix, "/boot-config")) return bootConfig(request, context, node_route.node_id, meta);
            if (std.mem.eql(u8, node_route.suffix, "/install-config/kickstart")) return installConfig(request, context, node_route.node_id, .kickstart, meta);
            if (std.mem.eql(u8, node_route.suffix, "/install-config/nocloud/user-data")) return installConfig(request, context, node_route.node_id, .user_data, meta);
            if (std.mem.eql(u8, node_route.suffix, "/install-config/nocloud/meta-data")) return installConfig(request, context, node_route.node_id, .meta_data, meta);
            if (std.mem.eql(u8, node_route.suffix, "/install-config/nocloud/vendor-data")) return installConfig(request, context, node_route.node_id, .vendor_data, meta);
        };
        // ── 静态制品路由 ──────────────────────────────────────
        if (assetRoute(path, "/artifacts/images/")) |name| return imageAsset(request, context, name, meta);
        if (artifactRepoRoute(path)) |repo| return repositoryAsset(request, context, repo.name, repo.tail, meta);
        if (artifactBootRoute(path)) |relative| return bootFile(request, context, relative, meta);
    }
    if (std.mem.eql(u8, method, "POST")) {
        if (std.mem.startsWith(u8, path, "/api/v1/nodes/")) if (splitNodeRoute(path["/api/v1/nodes/".len..])) |node_route| {
            if (std.mem.eql(u8, node_route.suffix, "/events")) return nodeEvent(request, context, node_route.node_id, meta);
            if (std.mem.eql(u8, node_route.suffix, "/logs")) return nodeLog(request, context, node_route.node_id, meta);
            if (std.mem.eql(u8, node_route.suffix, "/facts")) return nodeFacts(request, context, node_route.node_id, meta);
            if (std.mem.eql(u8, node_route.suffix, "/installer-hooks/subiquity")) return subiquityReport(request, context, node_route.node_id, meta);
        };
    }

    // ── 本机管理 API ──────────────────────────────────────────
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/status")) {
        return managementStatus(request, context, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/config")) {
        return managementConfigGet(request, context, meta);
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/config/validations")) {
        const catalog_snapshot = context.catalog_snapshot;
        config_validate.validate(context.config, catalog_snapshot.value()) catch |err| return validationError(request, err, meta);
        return json(request, .ok, "{\"ok\":true,\"result\":{}}\n", meta);
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/nodes")) return managementNodeAdd(request, context, meta);
    if (nodePath(path, "/api/v1/management/nodes/")) |node_id| {
        if (std.mem.eql(u8, method, "PATCH")) return managementNodeSet(request, context, node_id, meta);
        if (std.mem.eql(u8, method, "DELETE")) return managementNodeRemove(request, context, node_id, meta);
    }
    if (std.mem.eql(u8, method, "PATCH")) if (logicalPath(path, "/api/v1/management/profiles/")) |name| return managementProfileSet(request, context, name, meta);
    if (std.mem.eql(u8, method, "POST")) if (installGenerationsPath(path)) |node_id| return installGenerations(request, context, node_id, meta);
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/runtime")) {
        return runtimeSummary(request, context, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/nodes")) return managementNodes(request, context, meta);
    if (std.mem.eql(u8, method, "GET")) if (nodePath(path, "/api/v1/management/nodes/")) |node_id| return managementNode(request, context, node_id, meta);
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/profiles")) return managementProfiles(request, context, meta);
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/profiles")) return managementProfileCreate(request, context, meta);
    if (std.mem.eql(u8, method, "GET")) if (logicalPath(path, "/api/v1/management/profiles/")) |name| return managementProfile(request, context, name, meta);
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/runtime/tftp")) {
        return tftpStatus(request, context.runtime, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/runtime/tftp/sessions")) {
        return tftpSessions(request, context.runtime, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/runtime/dhcp/leases")) {
        const scope_unclaimed = blk: {
            if (request.getParamSlice("scope")) |scope| break :blk std.mem.eql(u8, scope, "unclaimed");
            break :blk false;
        };
        return dhcpLeases(request, context.allocator, context.runtime, scope_unclaimed, meta);
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/assets")) {
        return importAsset(request, context, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/assets")) return managementAssets(request, context, meta);
    if (std.mem.eql(u8, method, "GET")) if (logicalPath(path, "/api/v1/management/assets/")) |name| return managementAsset(request, context, name, meta);
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/install-sources")) {
        return importInstallSource(request, context, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/install-sources")) return managementInstallSources(request, context, meta);
    if (std.mem.eql(u8, method, "GET")) if (logicalPath(path, "/api/v1/management/install-sources/")) |name| return managementInstallSource(request, context, name, meta);
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/catalog/migration-plans")) return catalogMigrationPlan(request, context, meta);
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/catalog/migrations")) return catalogMigrationApply(request, context, meta);
    if (std.mem.eql(u8, method, "GET")) if (nodePath(path, "/api/v1/management/operations/")) |operation_id| return managementOperation(request, context, operation_id, meta);
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/operations")) return managementOperations(request, context, meta);
    var allow_buffer: [128]u8 = undefined;
    if (routes.allowed(path, &allow_buffer)) |allow| {
        // 路径匹配已知通配符路由，但具体子路径无 handler（如
        // `/install-config/foo`）。若方法本身被允许，语义是 404 而非 405：
        // 告诉客户端「GET 可用」但 GET 刚刚不被处理是自相矛盾的。
        if (routes.methodAllowed(path, method)) return notFound(request, meta);
        return methodNotAllowed(request, allow, meta);
    }
    return notFound(request, meta);
}

/// M3.6：检查客户端 IP 是否为 loopback peer（127.0.0.1）。
/// HTTP listener 仅支持 IPv4。精确匹配 127.0.0.1 并 fail closed，
/// 而非信任 X-Forwarded-For 或接受任意私有子网。
fn isLoopbackPeer(client_ip: []const u8) bool {
    // HTTP listener 仅支持 IPv4。精确匹配并 fail closed，
    // 而非信任 X-Forwarded-For 或接受任意私有子网。
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

fn logicalPath(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const value = path[prefix.len..];
    return if (config_validate.validLogicalId(value)) value else null;
}

test "logical resource route accepts canonical dots but rejects encoded paths" {
    try std.testing.expectEqualStrings("ubuntu-22.04-install", logicalPath("/profiles/ubuntu-22.04-install", "/profiles/").?);
    try std.testing.expect(logicalPath("/profiles/ubuntu%2fescape", "/profiles/") == null);
    try std.testing.expect(logicalPath("/profiles/../escape", "/profiles/") == null);
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

/// M4.4: `/artifacts/repositories/:name/*` 路由。
fn artifactRepoRoute(path: []const u8) ?RepoRoute {
    const prefix = "/artifacts/repositories/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const name = rest[0..slash];
    const tail = rest[slash + 1 ..];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '%') != null) return null;
    asset_validate.validateRelativePath(tail) catch return null;
    return .{ .name = name, .tail = tail };
}

/// M4.4: `/artifacts/boot/*` 路由——通过 HTTP 从 `tftp.asset_root` 提供
/// kernel/initrd 文件，启用 GRUB HTTP 加速。
fn artifactBootRoute(path: []const u8) ?[]const u8 {
    const prefix = "/artifacts/boot/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const relative = path[prefix.len..];
    if (relative.len == 0) return null;
    asset_validate.validateRelativePath(relative) catch return null;
    return relative;
}

fn imageAsset(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    const catalog_snapshot = context.catalog_snapshot;
    // Casper 仅在 kernel `url=` 值以 `.iso` 结尾时接受网络 ISO。Catalog 资产
    // ID 是逻辑名，不一定有该后缀，因此 `/artifacts/images/<asset>.iso` 是 ISO 资产的
    // 只读别名。
    const asset = lookup.findAsset(catalog_snapshot.value(), name) orelse if (std.mem.endsWith(u8, name, ".iso") and name.len > ".iso".len)
        lookup.findAsset(catalog_snapshot.value(), name[0 .. name.len - ".iso".len])
    else
        null;
    if (asset == null or asset.?.kind != .iso) {
        return notFound(request, meta);
    }
    const path = asset.?.path;
    const checksum = asset.?.sha256;
    return staticFile(request, context, context.config.http.asset_root, path, checksum, meta);
}

/// M4.2 F4：从 `tftp.asset_root` 提供启动文件（kernel/initrd）。
/// Catalog 白名单 + ETag checksum 支持条件请求和断点续传。
fn bootFile(request: zap.Request, context: *const RouteContext, relative: []const u8, meta: RequestMeta) !void {
    const asset_info = blk: {
        const catalog_snapshot = context.catalog_snapshot;
        const asset = lookup.findAssetByPath(catalog_snapshot.value(), relative) orelse return notFound(request, meta);
        break :blk .{ .path = asset.path, .checksum = asset.sha256 };
    };
    return staticFile(request, context, context.config.tftp.asset_root, asset_info.path, asset_info.checksum, meta);
}

fn repositoryAsset(request: zap.Request, context: *const RouteContext, name: []const u8, tail: []const u8, meta: RequestMeta) !void {
    const catalog_snapshot = context.catalog_snapshot;
    const repository = lookup.findRepository(catalog_snapshot.value(), name);
    if (repository == null) return notFound(request, meta);
    const root = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ context.config.http.repository_root, name });
    defer context.allocator.free(root);
    // M4：在文件查找前对 tail 做 URL 解码。HTTP 客户端（如 Anaconda）
    // 会对文件名中的特殊字符做百分号编码，例如 `libstdc++` →
    // `libstdc%2b%2b`。不解码则服务器查找字面编码名并返回 404。
    // 解码后的路径在 `staticFile` → `openRegularFile` → `validateRelativePath`
    // 中重新校验，防止路径穿越攻击（例如 `%2e%2e%2f` 解码为 `../`）。
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
    // Subiquity 在运行 apt-get 前用 HEAD 探测 APT 候选镜像。因此仅支持
    // GET 的仓库会表现为不可用，尽管包文件可以被下载。保留与 GET 相同的
    // 路径约束和元数据，但按 HTTP HEAD 要求不返回响应体。
    if (std.mem.eql(u8, request.method orelse "", "HEAD")) {
        // Zap 可能在 sendBody 将响应交回 facil.io 后立即失效 request 拥有的
        // method/path slice。保留 path 以确保终端日志和事件不会观察已释放的
        // request 内存。
        const request_path = try context.allocator.dupe(u8, request.path orelse "<missing>");
        defer context.allocator.free(request_path);
        request.setStatus(.ok);
        try request.setHeader("accept-ranges", "bytes");
        request.setContentTypeFromFilename(relative) catch try request.setHeader("content-type", "application/octet-stream");
        var length: [20]u8 = undefined;
        try request.setHeader("content-length", try std.fmt.bufPrint(&length, "{d}", .{size}));
        if (checksum) |hash| {
            var etag: [68]u8 = undefined;
            try request.setHeader("etag", try std.fmt.bufPrint(&etag, "\"{s}\"", .{hash}));
        }
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
    // GRUB HTTP 兼容（RFC 7233 §4.2 边界情况）：
    //
    // GRUB 的 HTTP 客户端在下载完整文件后会发送 `Range: bytes=<size>-`
    // 做完整性验证（offset 恰好等于文件大小）。严格按 RFC 7233，这应返回
    // 416 Range Not Satisfiable。但 GRUB 将 416 视为致命错误，会中止启动
    // 流程，不下载后续文件（如 initrd）。
    //
    // 修复方案：当 `range.length == 0`（即 offset == size 的空范围）时，
    // 返回 206 Partial Content + `Content-Range: bytes */<size>` +
    // `Content-Length: 0` + 空响应体。这不违反 RFC 7233（空范围在语义上
    // 是“已读完”的合法状态），同时满足 GRUB 的验证预期。
    //
    // 仅对 `offset == size` 生效；`offset > size` 仍返回 416。
    if (range.length == 0) {
        file.close(context.io);
        const request_path = try context.allocator.dupe(u8, request.path orelse "<missing>");
        defer context.allocator.free(request_path);
        request.setStatusNumeric(206);
        var content_range: [96]u8 = undefined;
        const value = try std.fmt.bufPrint(&content_range, "bytes */{d}", .{size});
        try request.setHeader("content-range", value);
        try request.setHeader("accept-ranges", "bytes");
        var length: [20]u8 = undefined;
        try request.setHeader("content-length", try std.fmt.bufPrint(&length, "0", .{}));
        try request.sendBody("");
        recordStaticCompletion("GET", request_path, context, relative, 206, 0, size, meta);
        return;
    }
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
    // `http_sendfile` 可能在返回前释放 request 拥有的 method/path 存储。
    // 为下方同步审计事件保留 path，与 sendBody 支持的 HEAD 和 416 分支一致。
    const request_path = try context.allocator.dupe(u8, request.path orelse "<missing>");
    defer context.allocator.free(request_path);
    try request.setHeader("accept-ranges", "bytes");
    request.setContentTypeFromFilename(relative) catch try request.setHeader("content-type", "application/octet-stream");
    // M3.6 下载日志：info 记录每个 HTTP 下载请求的对象、范围、字节数和客户端 IP。
    if (std.mem.startsWith(u8, request_path, "/artifacts/repositories/"))
        log.debug("HTTP repository request GET {s} (range={d}+{d}/{d}, client={s})", .{ relative, range.offset, range.length, total_size, meta.client_ip })
    else
        log.info("HTTP download request GET {s} (range={d}+{d}/{d}, client={s})", .{ relative, range.offset, range.length, total_size, meta.client_ip });
    const result = zap.fio.http_sendfile(request.h, file.handle, @intCast(range.length), @intCast(range.offset));
    if (result != 0) return error.SendFile;
    // M3.6 下载日志：facil.io 拥有异步 sendfile 完成回调。我们有意将其标记为
    // queued progress 而非声称是 peer ACK progress；每个 HTTP Range 请求
    // 仍被记录为一个精确的 chunk。
    log.debug("HTTP download queued {s}: {d}/{d} bytes (range {d}+{d})", .{ relative, range.offset + range.length, total_size, range.offset, range.length });
    // `request.h.*.status` 在此处不可靠：facil.io 可能保留其默认值直到异步
    // sendfile 响应提交。调用方拥有 HTTP 决策（200 整文件或 206 范围），
    // 因此显式传递该值以保持终端日志和事件准确。
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

/// 记录每个静态 HTTP 响应的终态，包括 HEAD 探测。对于 sendfile 支持的 GET
/// 响应，这意味着响应已成功排队到 facil.io；不代表对端已 ACK 所有字节。
/// 显式的 `response_state` 字段保留了这一区分。
fn recordStaticCompletion(method: []const u8, path: []const u8, context: *const RouteContext, relative: []const u8, status: u16, bytes_sent: u64, object_size: u64, meta: RequestMeta) void {
    const duration_us = meta.started.durationTo(std.Io.Clock.awake.now(meta.io)).toMicroseconds();
    const response_state = if (std.mem.eql(u8, method, "GET") and status >= 200 and status < 300) "queued" else "completed";
    const peer_ip = auth.parsePeerIpv4(meta.client_ip) catch 0;
    const identity = if (peer_ip != 0) context.sessions.resolveTftpBoot(peer_ip, boot_session.monotonicNow()) else null;
    if (std.mem.startsWith(u8, path, "/artifacts/repositories/"))
        log.debug("{s} {s} -> {d} ({d} bytes, {d}us, client={s}, node={s}, asset={s}, object_bytes={d}, response_state={s})", .{ method, path, status, bytes_sent, duration_us, meta.client_ip, if (identity) |value| value.node_id else "-", relative, object_size, response_state })
    else
        log.info("{s} {s} -> {d} ({d} bytes, {d}us, client={s}, node={s}, asset={s}, object_bytes={d}, response_state={s})", .{ method, path, status, bytes_sent, duration_us, meta.client_ip, if (identity) |value| value.node_id else "-", relative, object_size, response_state });

    var status_text: [4]u8 = undefined;
    var bytes_text: [20]u8 = undefined;
    var object_bytes_text: [20]u8 = undefined;
    var duration_text: [20]u8 = undefined;
    // M4.3-06 §8.3：按请求路径前缀分类流量，写入审计事件。
    // M4.4: 静态制品路径从旧前缀切换到 /artifacts/** canonical URL。
    //   repository -> /artifacts/repositories/**
    //   image      -> /artifacts/images/**
    //   boot       -> /artifacts/boot/**
    //   api        -> 管理端点、安装 install-config、事件上报等控制面请求
    const traffic_class: []const u8 = if (std.mem.startsWith(u8, path, "/artifacts/repositories/")) "repository" else if (std.mem.startsWith(u8, path, "/artifacts/images/")) "image" else if (std.mem.startsWith(u8, path, "/artifacts/boot/")) "boot" else "api";
    var fields: [11]events.Field = undefined;
    var count: usize = 0;
    inline for ([_]events.Field{
        .{ .key = "method", .value = method }, .{ .key = "path", .value = path }, .{ .key = "status", .value = std.fmt.bufPrint(&status_text, "{d}", .{status}) catch "0" }, .{ .key = "bytes_sent", .value = std.fmt.bufPrint(&bytes_text, "{d}", .{bytes_sent}) catch "0" }, .{ .key = "object_bytes", .value = std.fmt.bufPrint(&object_bytes_text, "{d}", .{object_size}) catch "0" }, .{ .key = "client_ip", .value = meta.client_ip }, .{ .key = "duration_us", .value = std.fmt.bufPrint(&duration_text, "{d}", .{duration_us}) catch "0" }, .{ .key = "response_state", .value = response_state }, .{ .key = "traffic_class", .value = traffic_class },
    }) |field| {
        fields[count] = field;
        count += 1;
    }
    if (identity) |value| {
        fields[count] = .{ .key = "node_id", .value = value.node_id };
        count += 1;
        fields[count] = .{ .key = "boot_session_id", .value = value.boot_session_id[0..] };
        count += 1;
    }
    context.event_writer.appendWithFields(context.io, context.allocator, paths.require().events_path, "http.request", "HTTP request completed", fields[0..count]) catch |err|
        observe_log.err("http: event append failed: {t}", .{err});
}

fn parseSingleRange(value: []const u8, size: u64) !ByteRange {
    // RFC 7233 §2.1: 只支持单一 bytes= Range（含 suffix 形式），拒绝多段 Range。
    if (!std.mem.startsWith(u8, value, "bytes=") or std.mem.indexOfScalar(u8, value, ',') != null or size == 0) return error.InvalidRange;
    const spec = value["bytes=".len..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return error.InvalidRange;
    if (std.mem.indexOfScalar(u8, spec[dash + 1 ..], '-') != null) return error.InvalidRange;
    const first = spec[0..dash];
    const last = spec[dash + 1 ..];
    // 后缀形式：bytes=-N → 最后 N 字节
    if (first.len == 0) {
        const suffix = std.fmt.parseInt(u64, last, 10) catch return error.InvalidRange;
        if (suffix == 0) return error.InvalidRange;
        const length = @min(suffix, size);
        return .{ .offset = size - length, .length = length };
    }
    const offset = std.fmt.parseInt(u64, first, 10) catch return error.InvalidRange;
    // GRUB HTTP 兼容（RFC 7233 §2.1 边界情况）：
    //
    // bytes=<size>-  表示 offset 恰好等于文件大小——客户端已完成下载后的
    // 完整性验证探测。返回 length=0 的空范围，由 sendRangedFile 发送
    // 206 + 0 字节。这避免 GRUB 将 416 视为致命错误而中止启动。
    //
    // bytes=<size+1>- 及更大的 offset 仍为非法范围，返回 error.InvalidRange
    // (416)，符合 RFC 7233 §4.4。
    if (offset > size) return error.InvalidRange;
    if (offset == size) return .{ .offset = offset, .length = 0 };
    // 开放形式：bytes=N- → 从 N 到末尾
    if (last.len == 0) return .{ .offset = offset, .length = size - offset };
    // 有界形式：bytes=N-M → 从 N 到 M（含），截断到 size-1
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
    if (checked.session.mode == .install and checked.proof == .bootstrap and checked.session.plan_digest == null) {
        const desired_revision = desiredRevision(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired model revision\"}}\n", meta);
        const desired_digest = desiredPlanDigest(context, node_id) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired node plan digest\"}}\n", meta);
        if (!deployment_control.digestEqual(checked.session.model_plan_digest, desired_digest)) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_changed\",\"message\":\"node plan changed after PXE authorization; retry is required\"}}\n", meta);
        const plan_json = buildInstallPlan(context, node_id, checked.session.profile, desired_revision, desired_digest) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_invalid\",\"message\":\"cannot compile immutable install plan\"}}\n", meta);
        defer context.allocator.free(plan_json);
        context.sessions.captureInstallPlan(context.allocator, checked.session.boot_session_id[0..], plan_json, desired_revision) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_changed\",\"message\":\"boot session plan is already pinned to different inputs\"}}\n", meta);
    }
    if (checked.proof == .bootstrap) pinSessionGeneration(context, checked.session) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"deployment.generation_unavailable\",\"message\":\"cannot pin deployment generation to boot session\"}}\n", meta);
    const session = if (checked.proof == .bootstrap)
        context.sessions.issueCapability(context.io, checked.session.boot_session_id[0..], boot_session.monotonicNow(), unixNow()) catch |err| return nodeAuthError(request, err, meta)
    else blk: {
        context.sessions.touchDelivery(checked.session.boot_session_id[0..], boot_session.monotonicNow(), unixNow());
        break :blk checked.session;
    };
    if (!checkpointSessions(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist delivery session\"}}\n", meta);

    context.statuses.updateForDeployment(node_id, session.boot_session_id[0..], context.daemon_instance_id, session.model_revision, session.model_plan_digest, session.deployment_generation, .boot_config_fetched, null, unixNow(), true) catch |err|
        observe_log.err("node status update failed: {t}", .{err});
    if (!persistStatus(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"status.persist_failed\",\"message\":\"node status persistence failed\"}}\n", meta);
    const fields = [_]events.Field{
        .{ .key = "node_id", .value = node_id },
        .{ .key = "boot_session_id", .value = session.boot_session_id[0..] },
        .{ .key = "profile", .value = session.profile },
    };
    context.event_writer.appendWithFields(context.io, context.allocator, paths.require().events_path, "boot.config.fetched", "authenticated boot config issued", &fields) catch |err| {
        observe_log.err("boot config event append failed: {t}", .{err});
        return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"events.unavailable\",\"message\":\"event writer unavailable\"}}\n", meta);
    };

    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    // M4.4 canonical URL: boot-config replaces config.
    const base = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}", .{ context.config.server.server_ip, context.config.server.http_port });
    defer context.allocator.free(base);
    const config_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/boot-config", .{ base, node_id });
    defer context.allocator.free(config_url);
    const event_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/events", .{ base, node_id });
    defer context.allocator.free(event_url);
    try output.writer.print("{{\"schema_version\":1,\"node_id\":{f},\"boot_session_id\":{f},\"profile\":{f},\"mode\":{f},\"config_url\":{f},\"event_url\":{f}", .{
        std.json.fmt(node_id, .{}),    std.json.fmt(session.boot_session_id[0..], .{}), std.json.fmt(session.profile, .{}), std.json.fmt(@tagName(session.mode), .{}),
        std.json.fmt(config_url, .{}), std.json.fmt(event_url, .{}),
    });
    // M4.4 安全响应头：boot-config 和 install-config 响应可能包含 capability、
    // password hash 或 SSH key，必须统一设置 no-store/nosniff/referrer policy。
    try request.setHeader("cache-control", "no-store, private");
    try request.setHeader("pragma", "no-cache");
    try request.setHeader("x-content-type-options", "nosniff");
    try request.setHeader("referrer-policy", "no-referrer");
    // 上方临时 URL 字符串在其生命周期结束前被有意复制到 writer 中；
    // 将 writer 作为一次响应分配释放。
    switch (session.mode) {
        .install => {
            // M4.4: boot-config 返回按 profile adapter 明确生成的 install-config URL，
            // 不再返回含糊的单一 answer_url。
            const plan_bytes = (try context.sessions.copyInstallPlan(context.allocator, session.boot_session_id[0..])) orelse return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_missing\",\"message\":\"boot session has no immutable install plan\"}}\n", meta);
            defer context.allocator.free(plan_bytes);
            const parsed_plan = std.json.parseFromSlice(InstallPlanEnvelope, context.allocator, plan_bytes, .{ .allocate = .alloc_always }) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_invalid\",\"message\":\"immutable install plan cannot be decoded\"}}\n", meta);
            defer parsed_plan.deinit();
            const source = &parsed_plan.value.install_source;
            const distro = &parsed_plan.value.distro;
            if (distro.family == .ubuntu) {
                // Ubuntu 使用 NoCloud seed_url 指向 install-config/nocloud/。
                const seed_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/install-config/nocloud/", .{ base, node_id });
                defer context.allocator.free(seed_url);
                try output.writer.print(",\"install_config\":{{\"kind\":\"no-cloud\",\"seed_url\":{f}}}", .{std.json.fmt(seed_url, .{})});
            } else {
                // RHEL 系使用 Kickstart URL。
                const ks_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/install-config/kickstart", .{ base, node_id });
                defer context.allocator.free(ks_url);
                try output.writer.print(",\"install_config\":{{\"kind\":\"kickstart\",\"url\":{f}}}", .{std.json.fmt(ks_url, .{})});
            }
            try output.writer.print(",\"installer\":{{\"source\":{f},\"kernel\":{f},\"initrd\":{f}}},\"repository_urls\":[", .{
                std.json.fmt(source.name, .{}), std.json.fmt(source.installer_kernel, .{}), std.json.fmt(source.installer_initrd, .{}),
            });
            for (source.repositories, 0..) |repository_name, index| {
                const repository = findRepositoryIn(parsed_plan.value.catalog_repositories, repository_name) orelse return notFound(request, meta);
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

/// M4 安装器 answer 渲染器：向已认证的 install 模式节点提供 Kickstart（RHEL）
/// 或 Autoinstall user-data/meta-data（Ubuntu）。首次获取时接受 bootstrap
/// proof（peer IP 匹配）并升级为 capability token；后续请求使用 capability proof。
const AnswerFormat = enum { kickstart, user_data, meta_data, vendor_data };
const InstallPlanEnvelope = struct {
    schema_version: u32,
    model_revision: u64,
    plan_digest: deployment_control.Digest,
    node: model.NodeConfig,
    profile: model.ProfileConfig,
    distro: model.DistroConfig,
    install_source: model.InstallSourceConfig,
    kernel: model.AssetConfig,
    initrd: model.AssetConfig,
    catalog_repositories: []const model.RepositoryConfig,
    provisioning_bundles: []const model.ProvisioningBundle,
    delivery: struct { server_ip: []const u8, http_port: u16 },
};
fn installConfig(request: zap.Request, context: *const RouteContext, node_id: []const u8, format: AnswerFormat, meta: RequestMeta) !void {
    const checked = auth.authenticate(context.sessions, node_id, meta.client_ip, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.session.mode != .install) return nodeAuthError(request, error.ProofMismatch, meta);
    if (checked.proof == .bootstrap and checked.session.plan_digest == null) {
        const desired_revision = desiredRevision(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired model revision\"}}\n", meta);
        const desired_digest = desiredPlanDigest(context, node_id) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired node plan digest\"}}\n", meta);
        if (!deployment_control.digestEqual(checked.session.model_plan_digest, desired_digest)) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_changed\",\"message\":\"node plan changed after PXE authorization; retry is required\"}}\n", meta);
        const plan_json = buildInstallPlan(context, node_id, checked.session.profile, desired_revision, desired_digest) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_invalid\",\"message\":\"cannot compile immutable install plan\"}}\n", meta);
        defer context.allocator.free(plan_json);
        context.sessions.captureInstallPlan(context.allocator, checked.session.boot_session_id[0..], plan_json, desired_revision) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_changed\",\"message\":\"boot session plan is already pinned to different inputs\"}}\n", meta);
    }
    if (checked.proof == .bootstrap) pinSessionGeneration(context, checked.session) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"deployment.generation_unavailable\",\"message\":\"cannot pin deployment generation to boot session\"}}\n", meta);
    const session = if (checked.proof == .bootstrap)
        context.sessions.issueCapability(context.io, checked.session.boot_session_id[0..], boot_session.monotonicNow(), unixNow()) catch |err| return nodeAuthError(request, err, meta)
    else
        checked.session;
    const plan_bytes = (try context.sessions.copyInstallPlan(context.allocator, session.boot_session_id[0..])) orelse return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_missing\",\"message\":\"boot session has no immutable install plan\"}}\n", meta);
    defer context.allocator.free(plan_bytes);
    const parsed_plan = std.json.parseFromSlice(InstallPlanEnvelope, context.allocator, plan_bytes, .{ .allocate = .alloc_always }) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_invalid\",\"message\":\"immutable install plan cannot be decoded\"}}\n", meta);
    defer parsed_plan.deinit();
    const plan = &parsed_plan.value;
    context.sessions.touchDelivery(session.boot_session_id[0..], boot_session.monotonicNow(), unixNow());
    if (!checkpointSessions(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist delivery session\"}}\n", meta);
    const event_url = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}/api/v1/nodes/{s}/events", .{ context.config.server.server_ip, context.config.server.http_port, node_id });
    defer context.allocator.free(event_url);
    const log_url = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}/api/v1/nodes/{s}/logs", .{ context.config.server.server_ip, context.config.server.http_port, node_id });
    defer context.allocator.free(log_url);
    const facts_url = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}/api/v1/nodes/{s}/facts", .{ context.config.server.server_ip, context.config.server.http_port, node_id });
    defer context.allocator.free(facts_url);
    const node = &plan.node;
    const profile = &plan.profile;
    // M4.2: Subiquity webhook reporting 在 22.04 和 24.04 均可用（curtin handler 相同）。
    // 始终为 Ubuntu 传入 report_url；webhook reporter 无认证，端点通过源 IP 校验。
    const distro = &plan.distro;
    const report_url: []const u8 = if (distro.family == .ubuntu) blk: {
        const url = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}/api/v1/nodes/{s}/installer-hooks/subiquity", .{ context.config.server.server_ip, context.config.server.http_port, node_id });
        break :blk url;
    } else "";
    defer if (report_url.len > 0) context.allocator.free(report_url);
    const install_orig = profile.install orelse return error.MissingInstallConfig;
    // M4.2 F5：将服务端级别的额外 SSH 公钥合并到安装配置中。
    const merged_keys: []const []const u8 = if (context.additional_keys.len > 0) blk: {
        const combined = try context.allocator.alloc([]const u8, install_orig.ssh_authorized_keys.len + context.additional_keys.len);
        @memcpy(combined[0..install_orig.ssh_authorized_keys.len], install_orig.ssh_authorized_keys);
        @memcpy(combined[install_orig.ssh_authorized_keys.len..], context.additional_keys);
        break :blk combined;
    } else install_orig.ssh_authorized_keys;
    defer if (context.additional_keys.len > 0) context.allocator.free(merged_keys);
    const install: model.InstallConfig = if (context.additional_keys.len > 0) .{
        .storage = install_orig.storage,
        .bootloader = install_orig.bootloader,
        .packages = install_orig.packages,
        .users = install_orig.users,
        .ssh_authorized_keys = merged_keys,
        .bundle = install_orig.bundle,
        .apt = install_orig.apt,
    } else install_orig;
    const system = try @import("../profile/install.zig").effectiveSystem(profile);
    const bundle = if (install.bundle) |name| findProvisioningBundleIn(plan.provisioning_bundles, name) else null;
    var password_scope_buffer: [96]u8 = undefined;
    // Salt scope must survive daemon restart. The session id is random and the
    // captured model revision is immutable for this delivery; daemon instance
    // identity would make the same checkpoint render different password hashes.
    const password_scope = try std.fmt.bufPrint(&password_scope_buffer, "{s}:{d}", .{ session.boot_session_id[0..], session.model_revision });
    // APT 源 URL 解析：Ubuntu ISO 导入时始终创建 repository 条目
    //（即使 ISO 不含完整 APT metadata），因此 findRepository 应总能找到。
    // 保留 fallback 逻辑以兼容手动配置场景：当 repository 不存在时，
    // 构造 /artifacts/repositories/<source_name>/ URL，使 apt 请求快速 404 而非 DNS 超时。
    const apt_primary_url = if (format == .user_data) blk: {
        const source = &plan.install_source;
        if (plan.distro.family == .ubuntu) {
            // Ubuntu: 优先使用 repository.base_url；若不存在则构造 fallback URL
            const repository = findRepositoryIn(plan.catalog_repositories, source.name);
            if (repository) |repo| if (repo.manager == .apt) break :blk repo.base_url;
            break :blk try std.fmt.allocPrint(context.allocator, "http://{s}:{d}/artifacts/repositories/{s}", .{ context.config.server.server_ip, context.config.server.http_port, source.name });
        }
        break :blk null;
    } else null;
    const body = switch (format) {
        .meta_data => try @import("../profile/adapter/ubuntu.zig").renderMetaData(context.allocator, node),
        .user_data => try @import("../profile/adapter/ubuntu.zig").renderUserDataM41(context.allocator, node, install, system, context.bootstrap_key, bundle, apt_primary_url, facts_url, event_url, log_url, report_url, session.boot_session_id[0..], session.capability[0..], password_scope, profile.kernel_args),
        .vendor_data => try context.allocator.dupe(u8, ""),
        .kickstart => blk: {
            const source = &plan.install_source;
            const install_root = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}/artifacts/repositories/{s}", .{ context.config.server.server_ip, context.config.server.http_port, source.name });
            defer context.allocator.free(install_root);
            break :blk try @import("../profile/adapter/kickstart.zig").renderAnswerM41(context.allocator, node, install, system, context.bootstrap_key, install_root, bundle, facts_url, event_url, log_url, session.boot_session_id[0..], session.capability[0..], password_scope, profile.kernel_args);
        },
    };
    defer context.allocator.free(body);
    request.setStatus(.ok);
    try request.setHeader("content-type", "text/plain; charset=utf-8");
    // M4.5：install-config 携带 password hash / SSH key，必须与 boot-config 一样
    // 设置完整安全头（no-store/private + nosniff + no-referrer + no-cache），
    // 不再只设 no-store。
    try request.setHeader("cache-control", "no-store, private");
    try request.setHeader("pragma", "no-cache");
    try request.setHeader("x-content-type-options", "nosniff");
    try request.setHeader("referrer-policy", "no-referrer");
    // `sendBody` 可能立即将响应交回 facil.io；在交接前记录借用的路由段，
    // 而非之后保留 request 拥有的 slice 用于诊断。
    log.info("GET installer answer -> 200 (node={s}, client={s})", .{ node_id, meta.client_ip });
    // M4：记录 HTTP 请求事件用于可观测性。`installConfig` 不使用 `json()`
    // 助手（后者处理事件日志），因此必须显式追加事件。否则成功的
    // kickstart/autoinstall 获取在 events.jsonl 中不可见。
    {
        const duration_us = meta.started.durationTo(std.Io.Clock.awake.now(meta.io)).toMicroseconds();
        var status_text: [4]u8 = undefined;
        var bytes_text: [20]u8 = undefined;
        var duration_text: [20]u8 = undefined;
        const req_path = request.path orelse "<missing>";
        const req_method = request.method orelse "OTHER";
        // M4.3-06 §8.3：按请求路径前缀分类流量，写入审计事件。
        // M4.4: 静态制品路径从旧前缀切换到 /artifacts/** canonical URL。
        const traffic_class: []const u8 = if (std.mem.startsWith(u8, req_path, "/artifacts/repositories/")) "repository" else if (std.mem.startsWith(u8, req_path, "/artifacts/images/")) "image" else if (std.mem.startsWith(u8, req_path, "/artifacts/boot/")) "boot" else "api";
        const fields = [_]events.Field{
            .{ .key = "method", .value = req_method },
            .{ .key = "path", .value = req_path },
            .{ .key = "status", .value = std.fmt.bufPrint(&status_text, "200", .{}) catch "0" },
            .{ .key = "bytes_sent", .value = std.fmt.bufPrint(&bytes_text, "{d}", .{body.len}) catch "0" },
            .{ .key = "client_ip", .value = meta.client_ip },
            .{ .key = "duration_us", .value = std.fmt.bufPrint(&duration_text, "{d}", .{duration_us}) catch "0" },
            .{ .key = "traffic_class", .value = traffic_class },
        };
        context.event_writer.appendWithFields(context.io, context.allocator, paths.require().events_path, "http.request", "HTTP request completed", &fields) catch |err|
            observe_log.err("http: event append failed: {t}", .{err});
    }
    try request.sendBody(body);
}

fn buildInstallPlan(context: *const RouteContext, node_id: []const u8, profile_name: []const u8, desired_revision: u64, desired_digest: deployment_control.Digest) ![]u8 {
    const node = lookup.findNode(context.catalog_snapshot.value(), node_id) orelse return error.MissingNode;
    const profile = lookup.findProfile(context.catalog_snapshot.value(), profile_name) orelse return error.MissingProfile;
    const distro = lookup.findDistro(context.catalog_snapshot.value(), profile.distro) orelse return error.MissingDistro;
    const catalog_snapshot = context.catalog_snapshot;
    const source = lookup.findInstallSource(catalog_snapshot.value(), profile.install_source orelse return error.MissingInstallSource) orelse return error.MissingInstallSource;
    const kernel = lookup.findAsset(catalog_snapshot.value(), source.installer_kernel) orelse return error.MissingAsset;
    const initrd = lookup.findAsset(catalog_snapshot.value(), source.installer_initrd) orelse return error.MissingAsset;
    const repositories = try context.allocator.alloc(model.RepositoryConfig, source.repositories.len);
    defer context.allocator.free(repositories);
    for (source.repositories, 0..) |name, index|
        repositories[index] = (lookup.findRepository(catalog_snapshot.value(), name) orelse return error.MissingRepository).*;
    const bundle_count: usize = if (profile.install != null and profile.install.?.bundle != null) 1 else 0;
    const bundles = try context.allocator.alloc(model.ProvisioningBundle, bundle_count);
    defer context.allocator.free(bundles);
    if (profile.install) |install| if (install.bundle) |name| {
        var found: ?model.ProvisioningBundle = null;
        for (catalog_snapshot.value().provisioning_bundles) |bundle| if (std.mem.eql(u8, bundle.name, name)) {
            found = bundle;
            break;
        };
        bundles[0] = found orelse return error.MissingProvisioningBundle;
    };
    return std.json.Stringify.valueAlloc(context.allocator, .{
        .schema_version = @as(u32, 1),
        .model_revision = desired_revision,
        .plan_digest = desired_digest,
        .node = node.*,
        .profile = profile.*,
        .distro = distro.*,
        .install_source = source.*,
        .kernel = kernel.*,
        .initrd = initrd.*,
        .catalog_repositories = repositories,
        .provisioning_bundles = bundles,
        .delivery = .{ .server_ip = context.config.server.server_ip, .http_port = context.config.server.http_port },
    }, .{});
}

fn findRepositoryIn(repositories: []const model.RepositoryConfig, name: []const u8) ?*const model.RepositoryConfig {
    for (repositories) |*repository| if (std.mem.eql(u8, repository.name, name)) return repository;
    return null;
}

fn findProvisioningBundleIn(bundles: []const model.ProvisioningBundle, name: []const u8) ?*const model.ProvisioningBundle {
    for (bundles) |*bundle| if (std.mem.eql(u8, bundle.name, name)) return bundle;
    return null;
}

fn findProvisioningBundle(config: *const model.AppConfig, name: []const u8) ?*const model.ProvisioningBundle {
    for (config.provisioning_bundles) |*bundle| if (std.mem.eql(u8, bundle.name, name)) return bundle;
    return null;
}

fn nodeEvent(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const checked = auth.authenticate(context.sessions, node_id, meta.client_ip, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.proof != .capability) return nodeAuthError(request, error.MissingProof, meta);
    if (!bodyWithin(request, 4 * 1024)) return json(request, .content_too_large, "{\"ok\":false,\"error\":{\"code\":\"http.body_too_large\",\"message\":\"node event body too large\"}}\n", meta);
    var event = parseNodeEvent(request, context.allocator) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_event\",\"message\":\"invalid node event\"}}\n", meta);
    defer event.params.deinit();
    @import("contracts.zig").validateNodeEvent(event.value) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_event\",\"message\":\"invalid node event\"}}\n", meta);
    if (!std.mem.eql(u8, event.value.boot_session_id, checked.session.boot_session_id[0..])) return nodeAuthError(request, error.ProofMismatch, meta);
    const mapped = mapStage(checked.session.mode, event.value.stage) orelse return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.stage_invalid\",\"message\":\"stage not allowed for profile mode\"}}\n", meta);
    const terminal = std.mem.eql(u8, event.value.stage, "completed") or std.mem.eql(u8, event.value.stage, "failed");
    // generation 仅在安装器自身报告已启动时被消费，
    // 而非 DHCP、TFTP 或 answer 下发成功时消费。
    if (checked.session.mode == .install and std.mem.eql(u8, event.value.stage, "started")) {
        const consumed = context.deployments.consumeAt(node_id, unixNow()) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot consume install generation\"}}\n", meta);
        deployment_control.save(context.io, context.allocator, paths.require().deployment_control_path, context.deployments) catch |err| {
            if (consumed) |result| context.deployments.rollbackConsume(node_id, result);
            observe_log.err("deployment-control save failed: {t}", .{err});
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot persist install generation\"}}\n", meta);
        };
    }
    if (checked.session.mode == .install and terminal) {
        const terminal_result = context.deployments.markTerminalAt(node_id, std.mem.eql(u8, event.value.stage, "completed"), unixNow());
        deployment_control.save(context.io, context.allocator, paths.require().deployment_control_path, context.deployments) catch |err| {
            if (terminal_result) |result| context.deployments.rollbackTerminal(node_id, result);
            observe_log.err("deployment-control applied revision save failed: {t}", .{err});
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot persist applied install revision\"}}\n", meta);
        };
    }
    context.statuses.updateForDeployment(node_id, checked.session.boot_session_id[0..], context.daemon_instance_id, checked.session.model_revision, checked.session.model_plan_digest, checked.session.deployment_generation, mapped.phase, event.value.reason, unixNow(), !terminal) catch |err|
        observe_log.err("node status update failed: {t}", .{err});
    if (!persistStatus(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"status.persist_failed\",\"message\":\"node status persistence failed\"}}\n", meta);
    var fields: [4]events.Field = .{
        .{ .key = "node_id", .value = node_id },
        .{ .key = "boot_session_id", .value = checked.session.boot_session_id[0..] },
        .{ .key = "stage", .value = event.value.stage },
        .{ .key = "reason", .value = event.value.reason orelse "" },
    };
    const field_count: usize = if (event.value.reason == null) 3 else 4;
    context.event_writer.appendWithFields(context.io, context.allocator, paths.require().events_path, mapped.event_type, event.value.message orelse "node stage update", fields[0..field_count]) catch |err| {
        observe_log.err("node event append failed: {t}", .{err});
        return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"events.unavailable\",\"message\":\"event writer unavailable\"}}\n", meta);
    };
    if (terminal) {
        context.sessions.finishDelivery(checked.session.boot_session_id[0..], if (std.mem.eql(u8, event.value.stage, "completed")) .completed else .failed, boot_session.monotonicNow(), unixNow());
        // M4.9：同步持久化 capability 删除；否则响应后崩溃会在重启时复活
        // 上一个 active checkpoint。
        if (!checkpointSessions(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist terminal delivery session\"}}\n", meta);
    } else {
        const phase: boot_session.Phase = if (std.mem.eql(u8, event.value.stage, "installer_started")) .installer_started else .installing;
        context.sessions.advanceDelivery(checked.session.boot_session_id[0..], phase, boot_session.monotonicNow(), unixNow());
    }
    return json(request, .ok, "{\"ok\":true}\n", meta);
}

fn nodeLog(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const checked = auth.authenticate(context.sessions, node_id, meta.client_ip, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.proof != .capability) return nodeAuthError(request, error.MissingProof, meta);
    if (!bodyWithin(request, 4 * 1024)) return json(request, .content_too_large, "{\"ok\":false,\"error\":{\"code\":\"http.body_too_large\",\"message\":\"node log body too large\"}}\n", meta);
    var summary = parseLogSummary(request, context.allocator) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_log\",\"message\":\"invalid node log summary\"}}\n", meta);
    defer summary.params.deinit();
    @import("contracts.zig").validateLogSummary(summary.value) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_log\",\"message\":\"invalid node log summary\"}}\n", meta);
    if (!std.mem.eql(u8, summary.value.boot_session_id, checked.session.boot_session_id[0..])) return nodeAuthError(request, error.ProofMismatch, meta);
    const event_type = switch (checked.session.mode) {
        .install => "install.failed",
        .diskless => "diskless.failed",
        .discovery => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.stage_invalid\",\"message\":\"logs unavailable for discovery\"}}\n", meta),
    };
    context.statuses.updateForDeployment(node_id, checked.session.boot_session_id[0..], context.daemon_instance_id, checked.session.model_revision, checked.session.model_plan_digest, checked.session.deployment_generation, .failed, summary.value.reason, unixNow(), false) catch |err|
        observe_log.err("node status update failed: {t}", .{err});
    if (!persistStatus(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"status.persist_failed\",\"message\":\"node status persistence failed\"}}\n", meta);
    const fields = [_]events.Field{ .{ .key = "node_id", .value = node_id }, .{ .key = "boot_session_id", .value = checked.session.boot_session_id[0..] }, .{ .key = "reason", .value = summary.value.reason } };
    context.event_writer.appendWithFields(context.io, context.allocator, paths.require().events_path, event_type, summary.value.summary, &fields) catch |err| {
        observe_log.err("node log append failed: {t}", .{err});
        return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"events.unavailable\",\"message\":\"event writer unavailable\"}}\n", meta);
    };
    context.sessions.finishDelivery(checked.session.boot_session_id[0..], .failed, boot_session.monotonicNow(), unixNow());
    if (!checkpointSessions(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist terminal delivery session\"}}\n", meta);
    return json(request, .ok, "{\"ok\":true}\n", meta);
}

fn nodeFacts(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const checked = auth.authenticate(context.sessions, node_id, meta.client_ip, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.proof != .capability) return nodeAuthError(request, error.MissingProof, meta);
    if (!bodyWithin(request, 8 * 1024)) return json(request, .content_too_large, "{\"ok\":false,\"error\":{\"code\":\"http.body_too_large\",\"message\":\"facts body too large\"}}\n", meta);
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"inventory.invalid\",\"message\":\"missing facts body\"}}\n", meta);
    const parsed = std.json.parseFromSlice(node_inventory.Facts, context.allocator, body, .{ .allocate = .alloc_always }) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"inventory.invalid\",\"message\":\"invalid facts body\"}}\n", meta);
    defer parsed.deinit();
    var facts = parsed.value;
    if (facts.serial_number) |value| if (value.len == 0) {
        facts.serial_number = null;
    };
    if (facts.product_uuid) |value| if (value.len == 0) {
        facts.product_uuid = null;
    };
    if (facts.vendor) |value| if (value.len == 0) {
        facts.vendor = null;
    };
    if (facts.model) |value| if (value.len == 0) {
        facts.model = null;
    };
    if (facts.serial_number) |value| {
        if (isFirmwarePlaceholder(value)) facts.serial_number = null;
    }
    _ = context.inventories.put(node_id, checked.session.boot_session_id[0..], checked.session.deployment_generation, checked.session.session_created_at, facts, unixNow()) catch |err| switch (err) {
        error.StaleSource => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"inventory.stale_source\",\"message\":\"facts came from a stale session\"}}\n", meta),
        else => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"inventory.invalid\",\"message\":\"facts rejected\"}}\n", meta),
    };
    node_inventory.save(context.io, context.allocator, paths.require().node_inventory_path, context.inventories) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"inventory.persist_failed\",\"message\":\"cannot persist facts\"}}\n", meta);
    context.sessions.touchDelivery(checked.session.boot_session_id[0..], boot_session.monotonicNow(), unixNow());
    return json(request, .ok, "{\"ok\":true}\n", meta);
}

fn pinSessionGeneration(context: *const RouteContext, session: boot_session.Authenticated) !void {
    const generation: u64 = if (session.mode == .install) blk: {
        const deployment = context.deployments.view(session.node_id) orelse return error.DeploymentGenerationUnavailable;
        break :blk deployment.armed_generation orelse deployment.consumed_generation orelse deployment.terminal_generation orelse return error.DeploymentGenerationUnavailable;
    } else 0;
    try context.sessions.setDeploymentGeneration(session.boot_session_id[0..], generation);
}

fn isFirmwarePlaceholder(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "To Be Filled By O.E.M.") or std.ascii.eqlIgnoreCase(value, "Default string") or std.ascii.eqlIgnoreCase(value, "Unknown");
}

/// M4.2 F1：Subiquity/curtin 原生 webhook reporting 回调。
/// curtin 的 `ReportingEvent.as_dict` 使用 `name`、`description`、
/// `event_type` 和可选 `result` 字段，不是 NodeForge `/events` DTO 的
/// `event`/`message` 字段。这里先把 curtin 层级事件归一为 NodeForge 阶段。
///
/// Subiquity 的 curtin webhook reporter 不支持自定义 headers
///（参见 ubuntu adapter："webhook reporter 不支持 `headers` 字段"）。
/// 因此此端点同时接受 bootstrap（源 IP）和 capability（bearer token）认证。
/// Bootstrap 认证验证请求来源于活跃 boot session 的 DHCP lease IP，
/// 这对隔离的 PXE 部署网络已足够。
fn subiquityReport(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const checked = auth.authenticateWebhook(context.sessions, node_id, meta.client_ip, boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.session.mode != .install) return nodeAuthError(request, error.ProofMismatch, meta);
    if (!bodyWithin(request, 4 * 1024)) return json(request, .content_too_large, "{\"ok\":false,\"error\":{\"code\":\"http.body_too_large\",\"message\":\"subiquity report body too large\"}}\n", meta);
    try request.parseBody();
    var params = try request.parametersToOwnedList(context.allocator);
    defer params.deinit();
    var event_name: ?[]const u8 = null;
    var event_type: ?[]const u8 = null;
    var webhook_result: ?[]const u8 = null;
    var message: []const u8 = "";
    for (params.items) |param| {
        if (std.mem.eql(u8, param.key, "name")) {
            event_name = stringParam(param.value);
        } else if (std.mem.eql(u8, param.key, "description")) {
            message = stringParam(param.value) orelse "";
        } else if (std.mem.eql(u8, param.key, "event_type")) {
            event_type = stringParam(param.value);
        } else if (std.mem.eql(u8, param.key, "result")) {
            webhook_result = stringParam(param.value);
        }
    }
    const event = event_name orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"subiquity.invalid\",\"message\":\"missing name field\"}}\n", meta);
    const resolved_stage = mapSubiquityStage(event, event_type orelse "", webhook_result orelse "");
    const stage = resolved_stage orelse {
        // 未知的 Subiquity 事件被确认但不记录。
        return json(request, .ok, "{\"ok\":true}\n", meta);
    };
    const deployment_terminal = std.mem.eql(u8, stage, "completed") or std.mem.eql(u8, stage, "failed");
    // curtin 的 FAIL webhook 通常先于 error-commands。失败时先更新 deployment
    // 和状态，但保留 capability，让随后携带 traceback 的 /logs 仍可认证；
    // 成功没有后续失败摘要，可以立即关闭 delivery。
    const delivery_terminal = std.mem.eql(u8, stage, "completed");
    const mapped = mapStage(.install, stage) orelse return json(request, .ok, "{\"ok\":true}\n", meta);
    if (std.mem.eql(u8, stage, "started")) {
        const consumed = context.deployments.consumeAt(node_id, unixNow()) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot consume install generation\"}}\n", meta);
        deployment_control.save(context.io, context.allocator, paths.require().deployment_control_path, context.deployments) catch |err| {
            if (consumed) |result| context.deployments.rollbackConsume(node_id, result);
            observe_log.err("deployment-control save failed: {t}", .{err});
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot persist install generation\"}}\n", meta);
        };
    }
    if (deployment_terminal) {
        const terminal_result = context.deployments.markTerminalAt(node_id, std.mem.eql(u8, stage, "completed"), unixNow());
        deployment_control.save(context.io, context.allocator, paths.require().deployment_control_path, context.deployments) catch |err| {
            if (terminal_result) |result| context.deployments.rollbackTerminal(node_id, result);
            observe_log.err("deployment-control applied revision save failed: {t}", .{err});
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot persist applied install revision\"}}\n", meta);
        };
    }
    context.statuses.updateForDeployment(node_id, checked.session.boot_session_id[0..], context.daemon_instance_id, checked.session.model_revision, checked.session.model_plan_digest, checked.session.deployment_generation, mapped.phase, null, unixNow(), !delivery_terminal) catch |err|
        observe_log.err("node status update failed: {t}", .{err});
    if (!persistStatus(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"status.persist_failed\",\"message\":\"node status persistence failed\"}}\n", meta);
    var fields: [3]events.Field = .{
        .{ .key = "node_id", .value = node_id },
        .{ .key = "boot_session_id", .value = checked.session.boot_session_id[0..] },
        .{ .key = "stage", .value = stage },
    };
    context.event_writer.appendWithFields(context.io, context.allocator, paths.require().events_path, mapped.event_type, if (message.len > 0) message else "subiquity report", &fields) catch |err| {
        observe_log.err("subiquity report event append failed: {t}", .{err});
        return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"events.unavailable\",\"message\":\"event writer unavailable\"}}\n", meta);
    };
    if (delivery_terminal) {
        context.sessions.finishDelivery(checked.session.boot_session_id[0..], .completed, boot_session.monotonicNow(), unixNow());
        if (!checkpointSessions(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist terminal delivery session\"}}\n", meta);
    } else if (!std.mem.eql(u8, stage, "failed")) {
        const phase: boot_session.Phase = if (std.mem.eql(u8, stage, "installer_started")) .installer_started else if (std.mem.eql(u8, stage, "started")) .installing else .installing;
        context.sessions.advanceDelivery(checked.session.boot_session_id[0..], phase, boot_session.monotonicNow(), unixNow());
    }
    return json(request, .ok, "{\"ok\":true}\n", meta);
}

/// 将 curtin 的层级事件名映射为稳定的 NodeForge 安装阶段。
/// 子阶段通常形如 `curtin/command-install/stage-partitioning`；只有根级
/// `command-install` 的成功终态才映射为 completed，避免某个子阶段完成时
/// 提前关闭 boot session。失败 result 则无论发生在哪个子阶段都立即上报。
fn mapSubiquityStage(name: []const u8, event_type: []const u8, result: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(result, "FAIL")) return "failed";
    const install_root = endsWithIgnoreCase(name, "command-install");
    if (install_root and std.ascii.eqlIgnoreCase(event_type, "start")) return "started";
    if (install_root and (std.ascii.eqlIgnoreCase(event_type, "finish") or std.ascii.eqlIgnoreCase(event_type, "result")) and std.ascii.eqlIgnoreCase(result, "SUCCESS")) return "completed";

    // curtin 会为每个子阶段同时发送 start 和 finish。NodeForge 的阶段事件
    // 表示“进入该阶段”，因此只消费 start，避免成功结束时重复写同一阶段。
    if (!std.ascii.eqlIgnoreCase(event_type, "start")) return null;
    if (containsIgnoreCase(name, "partition")) return "partitioning";
    if (containsIgnoreCase(name, "extract") or containsIgnoreCase(name, "package") or containsIgnoreCase(name, "apt-config")) return "packages";
    if (containsIgnoreCase(name, "bootloader") or containsIgnoreCase(name, "grub") or containsIgnoreCase(name, "curthooks")) return "bootloader";
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

const ParsedNodeEvent = struct { value: @import("contracts.zig").NodeEvent, params: zap.Request.HttpParamKVList };
const ParsedLogSummary = struct { value: @import("contracts.zig").LogSummary, params: zap.Request.HttpParamKVList };

fn parseNodeEvent(request: zap.Request, allocator: std.mem.Allocator) !ParsedNodeEvent {
    try request.parseBody();
    var params = try request.parametersToOwnedList(allocator);
    errdefer params.deinit();
    if (params.items.len < 3 or params.items.len > 5) return error.InvalidNodeEvent;
    // `reason` 和 `message` 是可选字段。从 contract 默认值开始，
    // 而非在检查有效客户端负载中的重复键时检查未初始化的 optional。
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

/// M4.5：管理写请求体上限判定。仅当请求声明了 Content-Length 且解析成功、
/// 且值超过 64 KiB 时返回 true；缺头、空 body 或解析失败均返回 false（不误伤
/// config/validations、install-generations 这类无 body 的写请求）。
fn managementBodyTooLarge(request: zap.Request) bool {
    const cl = request.getHeader("content-length") orelse return false;
    const len = std.fmt.parseInt(usize, std.mem.trim(u8, cl, " \t"), 10) catch return false;
    return len > 64 * 1024;
}

fn nodeAuthError(request: zap.Request, err: anyerror, meta: RequestMeta) !void {
    // 刻意仅记录稳定的错误标签和 direct peer；
    // 凭据、headers 和请求体永远不会被记录。
    // 被拒绝的安装器 bootstrap 必须在正常操作日志级别可见，
    // 同时仍排除凭据、headers 和请求体。
    observe_log.warn("node auth rejected client={s} reason={t}", .{ meta.client_ip, err });
    return switch (err) {
        error.MissingProof => json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"node.missing_proof\",\"message\":\"node proof required\"}}\n", meta),
        error.SessionInactive => json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.session_inactive\",\"message\":\"boot session inactive\"}}\n", meta),
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
    status_store.save(context.io, context.allocator, context.node_status_path, &snapshot, context.statuses.currentRevision(), unixNow()) catch |err| {
        observe_log.err("status: persistence failed: {t}", .{err});
        return false;
    };
    return true;
}

fn checkpointSessions(context: *const RouteContext) bool {
    boot_session_store.save(context.io, context.allocator, paths.require().boot_sessions_path, context.sessions, unixNow()) catch |err| {
        observe_log.err("boot-session: persistence failed: {t}", .{err});
        return false;
    };
    return true;
}

/// 为时间不重要的提前退出构造占位 meta。
fn undefined_meta(context: *const RouteContext) RequestMeta {
    var meta = RequestMeta{ .io = context.io, .client_ip = "unknown", .started = std.Io.Clock.awake.now(context.io) };
    nextRequestId(&meta.request_id);
    return meta;
}

/// 通过 daemon 注册一个已存在的资产，只有 daemon 能发布新的 catalog 快照。
/// 查询字段有意只接受受约束的 M1 CLI 词汇表；任意文件路径和已解码的 URL
/// 字符串会被与直接 TFTP 服务相同的资产校验器拒绝。
fn importAsset(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    if (!jsonRequest(request)) return unsupportedMediaType(request, meta);
    const AssetRequest = struct { name: []const u8, kind: model.AssetKind, path: []const u8, distro: ?[]const u8 = null, version: ?[]const u8 = null, arch: ?model.Arch = null, kernel_release: ?[]const u8 = null };
    const body = request.body orelse return assetInputError(request, "missing body", meta);
    const parsed = std.json.parseFromSlice(AssetRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch return assetInputError(request, "invalid JSON body", meta);
    defer parsed.deinit();
    const value = parsed.value;
    const has_tuple = value.distro != null or value.version != null or value.arch != null;
    if (has_tuple and (value.distro == null or value.version == null or value.arch == null)) return assetInputError(request, "incomplete distro tuple", meta);
    var checksum: [64]u8 = undefined;
    @import("../assets/validate.zig").sha256File(context.io, context.config.tftp.asset_root, value.path, &checksum) catch |err| {
        observe_log.err("asset: import failed for {s}: {t}", .{ value.path, err });
        return assetInputError(request, "unreadable asset", meta);
    };
    if (lookup.findAsset(context.catalog_snapshot.value(), value.name)) |existing| {
        const same = existing.kind == value.kind and std.mem.eql(u8, existing.path, value.path) and optionalEqual(existing.distro, value.distro) and optionalEqual(existing.version, value.version) and existing.arch == value.arch and optionalEqual(existing.kernel_release, value.kernel_release) and optionalEqual(existing.sha256, &checksum);
        if (!same) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"asset.name_conflict\",\"message\":\"asset name already identifies different canonical metadata\"}}\n", meta);
        var reused: [384]u8 = undefined;
        const response = try std.fmt.bufPrint(&reused, "{{\"ok\":true,\"result\":{{\"name\":{f},\"kind\":{f},\"sha256\":{f}}}}}\n", .{ std.json.fmt(existing.name, .{}), std.json.fmt(@tagName(existing.kind), .{}), std.json.fmt(existing.sha256.?, .{}) });
        return json(request, .ok, response, meta);
    }
    context.models.lock();
    defer context.models.unlock();
    context.catalog.addAsset(context.io, context.config, .{
        .name = value.name,
        .kind = value.kind,
        .path = value.path,
        .distro = value.distro,
        .version = value.version,
        .arch = value.arch,
        .kernel_release = value.kernel_release,
        .sha256 = &checksum,
    }) catch |err| return assetInputError(request, @errorName(err), meta);
    var location: [320]u8 = undefined;
    const location_value = try std.fmt.bufPrint(&location, "/api/v1/management/assets/{s}", .{value.name});
    try request.setHeader("location", location_value);
    var response_buffer: [384]u8 = undefined;
    const response = try std.fmt.bufPrint(&response_buffer, "{{\"ok\":true,\"result\":{{\"name\":{f},\"kind\":{f},\"sha256\":{f}}}}}\n", .{ std.json.fmt(value.name, .{}), std.json.fmt(@tagName(value.kind), .{}), std.json.fmt(&checksum, .{}) });
    try json(request, .created, response, meta);
}

/// M3.6：本地管理请求等待一个有界 import worker，但昂贵的 mount/copy/hash
/// 工作本身永远不在 HTTP callback 线程上执行。等待中的 handler 占用两个
/// HTTP worker 之一，而 daemon 范围内的 import mutex 拒绝并发 import 并
/// 保留另一个 worker 供数据面请求使用。Publication 保留在此处，使 catalog
/// 替换仅在完整候选存在后才被序列化。
fn importInstallSource(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    if (!jsonRequest(request)) return unsupportedMediaType(request, meta);
    const ImportRequest = struct { filename: []const u8, sha256: []const u8, name: ?[]const u8 = null, distro: ?[]const u8 = null, version: ?[]const u8 = null, arch: ?model.Arch = null };
    const body = request.body orelse return assetInputError(request, "missing body", meta);
    const parsed = std.json.parseFromSlice(ImportRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch return assetInputError(request, "invalid JSON body", meta);
    defer parsed.deinit();
    const filename = parsed.value.filename;
    const declared_sha256 = parsed.value.sha256;
    if (declared_sha256.len != 64 or !allLowerHex(declared_sha256)) return assetInputError(request, "invalid sha256", meta);
    const name = parsed.value.name;
    if (name) |value| if (!config_validate.validLogicalId(value)) return assetInputError(request, "invalid logical name", meta);
    const distro = parsed.value.distro;
    const version = parsed.value.version;
    const arch = parsed.value.arch;
    if (distro) |value| if (!config_validate.validLogicalId(value)) return assetInputError(request, "invalid distro override", meta);
    const arch_text = if (arch) |value| @tagName(value) else null;
    const idempotency_key = request.getHeader("idempotency-key") orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"operation.idempotency_key_required\",\"message\":\"Idempotency-Key header is required\"}}\n", meta);
    var digest_buf: [32]u8 = undefined;
    const digest_input = try std.fmt.allocPrint(context.allocator, "sha256={s}&name={s}&distro={s}&version={s}&arch={s}", .{ declared_sha256, name orelse "", distro orelse "", version orelse "", arch_text orelse "" });
    defer context.allocator.free(digest_input);
    std.crypto.hash.sha2.Sha256.hash(digest_input, &digest_buf, .{});
    var digest_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&digest_hex, "{x}", .{digest_buf}) catch unreachable;
    const begun = context.operations.beginRequest(context.io, idempotency_key, &digest_hex, .install_source_import, unixNow()) catch |err| return json(request, .conflict, if (err == error.IdempotencyConflict) "{\"ok\":false,\"error\":{\"code\":\"operation.idempotency_conflict\",\"message\":\"Idempotency-Key was already used for a different request\"}}\n" else "{\"ok\":false,\"error\":{\"code\":\"operation.unavailable\",\"message\":\"cannot create durable operation\"}}\n", meta);
    operations.save(context.io, context.allocator, paths.require().operations_path, context.operations) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"operation.persist_failed\",\"message\":\"cannot persist operation\"}}\n", meta);
    if (begun.reused) return operationResponse(request, begun.entry, true, meta);
    var operation_done = false;
    defer if (!operation_done) {
        _ = context.operations.fail(begun.entry.idSlice(), "operation.failed", unixNow()) catch {};
        operations.save(context.io, context.allocator, paths.require().operations_path, context.operations) catch {};
    };
    var input_hash: [64]u8 = undefined;
    asset_validate.sha256File(context.io, paths.require().import_dir, filename, &input_hash) catch |err| return assetInputError(request, @errorName(err), meta);
    if (!std.mem.eql(u8, &input_hash, declared_sha256)) return assetInputError(request, "ContentDigestMismatch", meta);
    context.catalog.lock();
    const catalog_snapshot = context.catalog.acquireLocked();
    for (catalog_snapshot.value().assets) |asset| {
        if (asset.kind != .iso or asset.sha256 == null or !std.mem.eql(u8, asset.sha256.?, &input_hash)) continue;
        for (catalog_snapshot.value().install_sources) |source| if (std.mem.eql(u8, source.source_asset, asset.name)) {
            catalog_snapshot.release();
            context.catalog.unlock();
            const completed = try context.operations.succeed(begun.entry.idSlice(), source.name, unixNow());
            try operations.save(context.io, context.allocator, paths.require().operations_path, context.operations);
            operation_done = true;
            return operationResponse(request, completed, true, meta);
        };
    }
    if (name) |requested_name| for (catalog_snapshot.value().install_sources) |source| if (std.mem.eql(u8, source.name, requested_name)) {
        catalog_snapshot.release();
        context.catalog.unlock();
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install_source.name_conflict\",\"message\":\"logical name already refers to different content\"}}\n", meta);
    };
    catalog_snapshot.release();
    context.catalog.unlock();
    if (!iso_import_mutex.tryLock()) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install_source.busy\",\"message\":\"another ISO import is running\"}}\n", meta);
    defer iso_import_mutex.unlock();
    var task: IsoImportTask = .{
        .io = context.io,
        .allocator = context.allocator,
        .config = context.config,
        .request = .{ .filename = filename, .name = name, .distro = distro, .version = version, .arch = arch },
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
    context.models.lock();
    defer context.models.unlock();
    context.catalog.publishInstallSource(context.io, context.configs, context.config, context.config_revision, imported) catch |err| {
        // importMedia 已经将不可变文件复制到受管根目录。
        // 被拒绝的候选不得积累不可访问的 public-root 孤儿文件
        //（例如，ISO 覆盖产生了与既有同名 distro 不一致的 family）。
        iso_import.cleanupPublishedOutputs(context.io, context.allocator, context.config, &imported);
        observe_log.err("ISO catalog publication failed: {t}", .{err});
        return assetInputError(request, @errorName(err), meta);
    };
    const completed = try context.operations.succeed(begun.entry.idSlice(), imported.source_name, unixNow());
    try operations.save(context.io, context.allocator, paths.require().operations_path, context.operations);
    operation_done = true;
    try operationResponse(request, completed, true, meta);
}

fn managementOperation(request: zap.Request, context: *const RouteContext, operation_id: []const u8, meta: RequestMeta) !void {
    const operation = context.operations.get(operation_id, unixNow()) orelse return notFound(request, meta);
    return operationResponse(request, operation, false, meta);
}

const Page = struct { offset: usize, limit: usize };

fn pageRequest(request: zap.Request, collection: []const u8, revision: u64) !Page {
    const limit = if (request.getParamSlice("limit")) |raw| std.fmt.parseInt(usize, raw, 10) catch return error.InvalidCursor else 100;
    if (limit < 1 or limit > 200) return error.InvalidCursor;
    const cursor = request.getParamSlice("cursor") orelse return .{ .offset = 0, .limit = limit };
    var decoded: [128]u8 = undefined;
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(cursor) catch return error.InvalidCursor;
    if (decoded_len > decoded.len) return error.InvalidCursor;
    std.base64.url_safe_no_pad.Decoder.decode(decoded[0..decoded_len], cursor) catch return error.InvalidCursor;
    var parts = std.mem.splitScalar(u8, decoded[0..decoded_len], ':');
    const cursor_collection = parts.next() orelse return error.InvalidCursor;
    const cursor_revision = std.fmt.parseInt(u64, parts.next() orelse return error.InvalidCursor, 10) catch return error.InvalidCursor;
    const offset = std.fmt.parseInt(usize, parts.next() orelse return error.InvalidCursor, 10) catch return error.InvalidCursor;
    if (parts.next() != null or !std.mem.eql(u8, cursor_collection, collection)) return error.InvalidCursor;
    if (cursor_revision != revision) return error.StaleCursor;
    return .{ .offset = offset, .limit = limit };
}

fn writeNextCursor(writer: *std.Io.Writer, collection: []const u8, revision: u64, next: usize, total: usize) !void {
    try writer.writeAll(",\"next_cursor\":");
    if (next >= total) return writer.writeAll("null");
    var plain: [96]u8 = undefined;
    const token = try std.fmt.bufPrint(&plain, "{s}:{d}:{d}", .{ collection, revision, next });
    var encoded: [128]u8 = undefined;
    const value = std.base64.url_safe_no_pad.Encoder.encode(&encoded, token);
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

fn pageError(request: zap.Request, err: anyerror, meta: RequestMeta) !void {
    if (err == error.StaleCursor) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"pagination.snapshot_changed\",\"message\":\"cursor snapshot is no longer current\"}}\n", meta);
    return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"pagination.invalid_cursor\",\"message\":\"limit or cursor is invalid\"}}\n", meta);
}

fn managementAssets(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    const all = context.catalog_snapshot.value().assets;
    const page = pageRequest(request, "assets", context.catalog_snapshot.revision) catch |err| return pageError(request, err, meta);
    const end = @min(page.offset + page.limit, all.len);
    if (page.offset > all.len) return pageError(request, error.InvalidCursor, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"items\":[");
    for (all[page.offset..end], 0..) |asset, i| {
        if (i != 0) try output.writer.writeByte(',');
        try output.writer.print("{f}", .{std.json.fmt(asset, .{})});
    }
    try output.writer.writeByte(']');
    try writeNextCursor(&output.writer, "assets", context.catalog_snapshot.revision, end, all.len);
    try output.writer.print(",\"view_revision\":{d}}}}}\n", .{context.catalog_snapshot.revision});
    try setRevisionEtag(request, context.catalog_snapshot.revision);
    return json(request, .ok, output.written(), meta);
}

fn managementAsset(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    const asset = lookup.findAsset(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    var output: [2048]u8 = undefined;
    const body = try std.fmt.bufPrint(&output, "{{\"ok\":true,\"result\":{f}}}\n", .{std.json.fmt(asset.*, .{})});
    try setRevisionEtag(request, context.catalog_snapshot.revision);
    return json(request, .ok, body, meta);
}

fn managementInstallSources(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    const all = context.catalog_snapshot.value().install_sources;
    const page = pageRequest(request, "install-sources", context.catalog_snapshot.revision) catch |err| return pageError(request, err, meta);
    const end = @min(page.offset + page.limit, all.len);
    if (page.offset > all.len) return pageError(request, error.InvalidCursor, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"items\":[");
    for (all[page.offset..end], 0..) |source, i| {
        if (i != 0) try output.writer.writeByte(',');
        try output.writer.print("{f}", .{std.json.fmt(source, .{})});
    }
    try output.writer.writeByte(']');
    try writeNextCursor(&output.writer, "install-sources", context.catalog_snapshot.revision, end, all.len);
    try output.writer.print(",\"view_revision\":{d}}}}}\n", .{context.catalog_snapshot.revision});
    try setRevisionEtag(request, context.catalog_snapshot.revision);
    return json(request, .ok, output.written(), meta);
}

fn managementOperations(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    var all: [operations.max_operations]operations.Entry = undefined;
    context.operations.snapshot(&all);
    var used: [operations.max_operations]operations.Entry = undefined;
    var count: usize = 0;
    for (all) |entry| if (entry.used()) {
        used[count] = entry;
        count += 1;
    };
    const revision: u64 = @intCast(count);
    const page = pageRequest(request, "operations", revision) catch |err| return pageError(request, err, meta);
    const end = @min(page.offset + page.limit, count);
    if (page.offset > count) return pageError(request, error.InvalidCursor, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"items\":[");
    for (used[page.offset..end], 0..) |entry, i| {
        if (i != 0) try output.writer.writeByte(',');
        try writeOperation(&output.writer, entry);
    }
    try output.writer.writeByte(']');
    try writeNextCursor(&output.writer, "operations", revision, end, count);
    try output.writer.print(",\"view_revision\":{d}}}}}\n", .{revision});
    try setRevisionEtag(request, revision);
    return json(request, .ok, output.written(), meta);
}

fn catalogMigrationPlan(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    if (request.body) |body| if (body.len != 0 and !std.mem.eql(u8, std.mem.trim(u8, body, " \t\r\n"), "{}"))
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"request.unknown_field\",\"message\":\"migration plan currently accepts an empty object\"}}\n", meta);
    var plan = catalog_migration.build(context.allocator, context.config, context.catalog_snapshot.value(), context.config_revision, context.catalog_snapshot.revision) catch
        return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"migration.plan_failed\",\"message\":\"cannot construct migration plan\"}}\n", meta);
    defer plan.deinit();
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"plan_digest\":{f},\"applicable\":{s},\"plan\":", .{ std.json.fmt(&plan.digest, .{}), if (plan.applicable()) "true" else "false" });
    try output.writer.writeAll(plan.canonical_json);
    try output.writer.writeAll("}}\n");
    return json(request, .ok, output.written(), meta);
}

fn managementInstallSource(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    const source = lookup.findInstallSource(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    const distro = lookup.findDistro(context.catalog_snapshot.value(), source.distro) orelse return notFound(request, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"model_revision\":{{\"config\":{d},\"catalog\":{d}}},\"install_source\":{f},\"family\":{f},\"repositories\":[", .{ context.config_revision, context.catalog_snapshot.revision, std.json.fmt(source.*, .{}), std.json.fmt(@tagName(distro.family), .{}) });
    for (source.repositories, 0..) |repository_name, index| {
        const repository = lookup.findRepository(context.catalog_snapshot.value(), repository_name) orelse return notFound(request, meta);
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{f}", .{std.json.fmt(repository.*, .{})});
    }
    try output.writer.writeAll("],\"assets\":[");
    const asset_names = [_][]const u8{ source.source_asset, source.installer_kernel, source.installer_initrd };
    for (asset_names, 0..) |asset_name, index| {
        const asset = lookup.findAsset(context.catalog_snapshot.value(), asset_name) orelse return notFound(request, meta);
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{f}", .{std.json.fmt(asset.*, .{})});
    }
    try output.writer.writeAll("],\"profiles\":[");
    var first = true;
    for (context.catalog_snapshot.value().profiles) |profile| if (profile.install_source) |source_name| if (std.mem.eql(u8, source_name, name)) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{f}", .{std.json.fmt(profile.name, .{})});
    };
    try output.writer.writeAll("]}}\n");
    return json(request, .ok, output.written(), meta);
}

const MigrationApplyRequest = struct { plan_digest: []const u8 };

fn catalogMigrationApply(request: zap.Request, context: *RouteContext, meta: RequestMeta) !void {
    const idempotency_key = request.getHeader("idempotency-key") orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"operation.idempotency_key_required\",\"message\":\"Idempotency-Key header is required\"}}\n", meta);
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"migration.invalid_request\",\"message\":\"missing request body\"}}\n", meta);
    const parsed = std.json.parseFromSlice(MigrationApplyRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"migration.invalid_request\",\"message\":\"invalid request body\"}}\n", meta);
    defer parsed.deinit();
    if (parsed.value.plan_digest.len != 64 or !allLowerHex(parsed.value.plan_digest)) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"migration.invalid_digest\",\"message\":\"plan_digest must be 64 lowercase hexadecimal characters\"}}\n", meta);
    const begun = context.operations.beginRequest(context.io, idempotency_key, parsed.value.plan_digest, .catalog_migration, unixNow()) catch |err| return json(request, .conflict, if (err == error.IdempotencyConflict) "{\"ok\":false,\"error\":{\"code\":\"operation.idempotency_conflict\",\"message\":\"Idempotency-Key was already used for another migration\"}}\n" else "{\"ok\":false,\"error\":{\"code\":\"operation.unavailable\",\"message\":\"cannot create migration operation\"}}\n", meta);
    try operations.save(context.io, context.allocator, paths.require().operations_path, context.operations);
    if (begun.reused) return operationResponse(request, begun.entry, true, meta);
    var operation_done = false;
    defer if (!operation_done) {
        _ = context.operations.fail(begun.entry.idSlice(), "migration.failed", unixNow()) catch {};
        operations.save(context.io, context.allocator, paths.require().operations_path, context.operations) catch {};
    };
    context.models.lock();
    defer context.models.unlock();
    if (context.configs.currentRevision() != context.config_revision or context.catalog.currentRevision() != context.catalog_snapshot.revision)
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"model.revision_conflict\",\"message\":\"model changed after migration plan was read\"}}\n", meta);
    var plan = try catalog_migration.build(context.allocator, context.config, context.catalog_snapshot.value(), context.config_revision, context.catalog_snapshot.revision);
    defer plan.deinit();
    if (!std.mem.eql(u8, &plan.digest, parsed.value.plan_digest)) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"model.revision_conflict\",\"message\":\"plan digest no longer identifies the current model\"}}\n", meta);
    if (!plan.applicable()) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"migration.blocked\",\"message\":\"migration plan contains blockers\"}}\n", meta);
    for (plan.renames) |rename| if (context.sessions.hasActiveInstallSource(rename.source, boot_session.monotonicNow())) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"migration.active_session\",\"message\":\"an active boot session owns a source in this plan\"}}\n", meta);
    if (plan.renames.len == 0) {
        const completed = try context.operations.succeed(begun.entry.idSlice(), &plan.digest, unixNow());
        try operations.save(context.io, context.allocator, paths.require().operations_path, context.operations);
        operation_done = true;
        return operationResponse(request, completed, true, meta);
    }
    var candidate = try catalog_migration.candidates(context.allocator, context.config, context.catalog_snapshot.value(), &plan);
    defer candidate.deinit();
    const config_json = try config_store.render(context.allocator, &candidate.config.value);
    defer context.allocator.free(config_json);
    const catalog_json = try catalog_store.render(context.allocator, &candidate.catalog.value);
    defer context.allocator.free(catalog_json);
    var moves = try migrationMoves(context.allocator, context.config, context.catalog_snapshot.value(), &candidate.catalog.value, &plan);
    defer moves.deinit();
    const config_revision = try deployment_control.revisionForConfig(context.allocator, &candidate.config.value);
    const prepared_config = try context.configs.prepare(candidate.config.value, config_revision);
    var snapshots_published = false;
    defer if (!snapshots_published) prepared_config.release();
    const prepared_catalog = try context.catalog.prepare(candidate.catalog.value, context.catalog_snapshot.revision + 1);
    defer if (!snapshots_published) prepared_catalog.release();
    const transaction_dir = try model_transaction.directoryForConfig(context.allocator, context.config_path);
    defer context.allocator.free(transaction_dir);
    model_transaction.commit(context.io, context.allocator, transaction_dir, &plan.digest, context.config_path, context.catalog.path, config_json, catalog_json, moves.items.items, null) catch |err| {
        observe_log.err("catalog migration transaction failed: {t}", .{err});
        return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.transaction_failed\",\"message\":\"migration transaction did not commit\"}}\n", meta);
    };
    // All fallible snapshot allocation is complete before the durable commit.
    // From here publication only swaps pointers while the model gate is held.
    context.configs.publishPrepared(prepared_config);
    context.catalog.lock();
    context.catalog.publishPreparedLocked(prepared_catalog);
    context.catalog.unlock();
    snapshots_published = true;
    const completed = try context.operations.succeed(begun.entry.idSlice(), &plan.digest, unixNow());
    try operations.save(context.io, context.allocator, paths.require().operations_path, context.operations);
    operation_done = true;
    return operationResponse(request, completed, true, meta);
}

const MigrationMoves = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(model_transaction.Move) = .empty,
    owned: std.ArrayList([]u8) = .empty,
    fn deinit(self: *MigrationMoves) void {
        for (self.owned.items) |value| self.allocator.free(value);
        self.owned.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }
    fn add(self: *MigrationMoves, old: []u8, new: []u8) !void {
        try self.owned.append(self.allocator, old);
        errdefer _ = self.owned.pop();
        try self.owned.append(self.allocator, new);
        try self.items.append(self.allocator, .{ .old = old, .new = new });
    }
};

fn migrationMoves(allocator: std.mem.Allocator, config: *const model.AppConfig, old_catalog: *const model.Catalog, new_catalog: *const model.Catalog, plan: *const catalog_migration.Plan) !MigrationMoves {
    var result: MigrationMoves = .{ .allocator = allocator };
    errdefer result.deinit();
    for (plan.renames) |rename| {
        try result.add(try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.repository_root, rename.source }), try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.repository_root, rename.target }));
        try result.add(try std.fmt.allocPrint(allocator, "{s}/install/{s}", .{ config.tftp.asset_root, rename.source }), try std.fmt.allocPrint(allocator, "{s}/install/{s}", .{ config.tftp.asset_root, rename.target }));
    }
    for (old_catalog.assets, new_catalog.assets) |old, new| {
        if (old.kind != .iso or std.mem.eql(u8, old.path, new.path)) continue;
        try result.add(try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.asset_root, old.path }), try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.asset_root, new.path }));
    }
    return result;
}

fn allLowerHex(value: []const u8) bool {
    for (value) |byte| if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    return true;
}

fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

fn jsonRequest(request: zap.Request) bool {
    const raw = request.getHeader("content-type") orelse return false;
    const media_type = std.mem.trim(u8, std.mem.sliceTo(raw, ';'), " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/json");
}

fn unsupportedMediaType(request: zap.Request, meta: RequestMeta) !void {
    return json(request, .unsupported_media_type, "{\"ok\":false,\"error\":{\"code\":\"http.unsupported_media_type\",\"message\":\"Content-Type must be application/json\"}}\n", meta);
}

fn setRevisionEtag(request: zap.Request, revision: u64) !void {
    var buffer: [32]u8 = undefined;
    try request.setHeader("etag", try std.fmt.bufPrint(&buffer, "\"{d}\"", .{revision}));
}

fn operationResponse(request: zap.Request, operation: operations.Entry, accepted: bool, meta: RequestMeta) !void {
    var body: [768]u8 = undefined;
    var location: [256]u8 = undefined;
    const location_value = try std.fmt.bufPrint(&location, "/api/v1/management/operations/{s}", .{operation.idSlice()});
    try request.setHeader("location", location_value);
    const rendered = try std.fmt.bufPrint(&body, "{{\"ok\":true,\"result\":{{\"id\":{f},\"kind\":{f},\"state\":{f},\"created_at\":{d},\"updated_at\":{d},\"result\":{f},\"error_code\":{f}}}}}\n", .{ std.json.fmt(operation.idSlice(), .{}), std.json.fmt(@tagName(operation.kind), .{}), std.json.fmt(@tagName(operation.state), .{}), operation.created_at, operation.updated_at, std.json.fmt(operation.resultSlice(), .{}), std.json.fmt(operation.errorSlice(), .{}) });
    return json(request, if (accepted) .accepted else .ok, rendered, meta);
}

fn writeOperation(writer: *std.Io.Writer, operation: operations.Entry) !void {
    try writer.print("{{\"id\":{f},\"kind\":{f},\"state\":{f},\"created_at\":{d},\"updated_at\":{d},\"result\":{f},\"error_code\":{f}}}", .{ std.json.fmt(operation.idSlice(), .{}), std.json.fmt(@tagName(operation.kind), .{}), std.json.fmt(@tagName(operation.state), .{}), operation.created_at, operation.updated_at, std.json.fmt(operation.resultSlice(), .{}), std.json.fmt(operation.errorSlice(), .{}) });
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

fn installGenerationsPath(path: []const u8) ?[]const u8 {
    const prefix = "/api/v1/management/nodes/";
    const suffix = "/install-generations";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const node_id = path[prefix.len .. path.len - suffix.len];
    return if (auth.nodeIdSafe(node_id)) node_id else null;
}

fn installGenerations(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const node = lookup.findNode(context.catalog_snapshot.value(), node_id) orelse return notFound(request, meta);
    const profile = lookup.findProfile(context.catalog_snapshot.value(), node.profile) orelse return notFound(request, meta);
    if (profile.mode != .install) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.not_profile\",\"message\":\"node does not have an install profile\"}}\n", meta);
    const ForceRequest = struct { force: bool = false };
    const force = if (request.body) |body| blk: {
        const parsed = std.json.parseFromSlice(ForceRequest, context.allocator, body, .{}) catch
            return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"install.invalid_retry\",\"message\":\"expected {force:true}\"}}\n", meta);
        defer parsed.deinit();
        break :blk parsed.value.force;
    } else false;
    const mono_now = boot_session.monotonicNow();
    if (context.sessions.hasActiveNode(node_id, mono_now)) {
        if (!force) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.session_active\",\"message\":\"active install session cannot be rearmed; stop the target and use node retry --force\"}}\n", meta);
        _ = context.sessions.supersedeNode(node_id, mono_now, unixNow());
        @import("../state/boot_session_store.zig").save(context.io, context.allocator, paths.require().boot_sessions_path, context.sessions, unixNow()) catch
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist forced session termination\"}}\n", meta);
    }
    const desired_digest = desiredPlanDigest(context, node_id) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired node plan digest\"}}\n", meta);
    const requested_at = unixNow();
    const rearm = context.deployments.rearm(node_id, desired_digest, requested_at, .operator) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot rearm install generation\"}}\n", meta);
    if (rearm.changed) {
        deployment_control.save(context.io, context.allocator, paths.require().deployment_control_path, context.deployments) catch {
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
        context.event_writer.appendWithFields(context.io, context.allocator, paths.require().events_path, "install.retry.requested", "install generation rearmed", &fields) catch |err| observe_log.err("retry event append failed: {t}", .{err});
    }
    // M4.4: install-generations 返回 201 + Location header。
    var location: [256]u8 = undefined;
    const location_value = try std.fmt.bufPrint(&location, "/api/v1/management/nodes/{s}/install-generations", .{node_id});
    try request.setHeader("location", location_value);
    var body: [160]u8 = undefined;
    return json(request, .created, try std.fmt.bufPrint(&body, "{{\"ok\":true,\"result\":{{\"node_id\":{f},\"generation\":{d},\"message\":\"rearmed; waiting for next PXE\"}}}}\n", .{ std.json.fmt(node_id, .{}), rearm.generation }), meta);
}

/// M4.4: `/management/status` — server/config/runtime 摘要，替代旧 /server/status 和 /config/status。
fn managementStatus(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    const service_text = switch (context.runtime.service) {
        .starting => "starting",
        .running => "running",
        .stopping => "stopping",
    };
    const catalog_snapshot = context.catalog_snapshot;
    const config_valid = blk: {
        config_validate.validate(context.config, catalog_snapshot.value()) catch break :blk false;
        break :blk true;
    };
    var body: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&body, "{{\"ok\":true,\"result\":{{\"service\":\"{s}\",\"config_valid\":{s},\"config_revision\":{d},\"catalog_revision\":{d}}}}}\n", .{ service_text, if (config_valid) "true" else "false", context.config_revision, context.catalog_snapshot.revision });
    return json(request, .ok, rendered, meta);
}

/// M4.4: `/management/config` GET — revision、valid、restart-required 摘要，不返回 secrets。
/// 替代旧 /config/status。
fn managementConfigGet(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    const catalog_snapshot = context.catalog_snapshot;
    const config_valid = blk: {
        config_validate.validate(context.config, catalog_snapshot.value()) catch break :blk false;
        break :blk true;
    };
    var body: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&body, "{{\"ok\":true,\"result\":{{\"config\":\"{s}\",\"revision\":{d},\"catalog_revision\":{d}}}}}\n", .{ if (config_valid) "valid" else "invalid", context.config_revision, context.catalog_snapshot.revision });
    try setRevisionEtag(request, context.config_revision);
    return json(request, .ok, rendered, meta);
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

const NodeAddRequest = struct {
    id: []const u8,
    mac: []const u8,
    arch: model.Arch,
    profile: []const u8,
    ip: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    deploy: bool = true,
    http_accel: bool = false,
};

const NodeSetRequest = struct {
    mac: ?[]const u8 = null,
    arch: ?model.Arch = null,
    profile: ?[]const u8 = null,
    ip: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    deploy: ?bool = null,
    http_accel: ?bool = null,
    unset: []const []const u8 = &.{},
};

const ProfileMutationRequest = struct {
    kernel_args: ?[]const u8 = null,
    boot_disk: ?[]const u8 = null,
};
const ProfileCreateRequest = struct { name: []const u8, install_source: []const u8 };

fn managementProfileCreate(request: zap.Request, context: *RouteContext, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"missing request body\"}}\n", meta);
    const parsed = std.json.parseFromSlice(ProfileCreateRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"name and install_source are required\"}}\n", meta);
    defer parsed.deinit();
    if (!config_validate.validLogicalId(parsed.value.name) or !config_validate.validLogicalId(parsed.value.install_source))
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"name and install_source must be canonical logical identifiers\"}}\n", meta);
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    @import("../config/profile_mutation.zig").addInstallProfile(context.io, context.allocator, context.config, context.catalog.path, parsed.value.name, parsed.value.install_source) catch |err| switch (err) {
        error.ProfileAlreadyExists => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"profile.already_exists\",\"message\":\"profile name already exists\"}}\n", meta),
        error.InstallSourceNotFound => return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"profile.install_source_not_found\",\"message\":\"install source does not exist\"}}\n", meta),
        else => return validationError(request, err, meta),
    };
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"profile persisted but snapshot publish failed\"}}\n", meta);
    var location: [320]u8 = undefined;
    try request.setHeader("location", try std.fmt.bufPrint(&location, "/api/v1/management/profiles/{s}", .{parsed.value.name}));
    var response: [384]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&response, "{{\"ok\":true,\"result\":{{\"name\":{f},\"mode\":\"install\",\"install_source\":{f},\"revision\":{d}}}}}\n", .{ std.json.fmt(parsed.value.name, .{}), std.json.fmt(parsed.value.install_source, .{}), context.catalog.currentRevision() });
    try setRevisionEtag(request, context.catalog.currentRevision());
    return json(request, .created, rendered, meta);
}

test "profile kernel args patch requires the single typed field" {
    const set = try std.json.parseFromSlice(ProfileMutationRequest, std.testing.allocator, "{\"kernel_args\":\"iommu=pt\"}", .{});
    defer set.deinit();
    try std.testing.expectEqualStrings("iommu=pt", set.value.kernel_args.?);
    const unset = try std.json.parseFromSlice(ProfileMutationRequest, std.testing.allocator, "{\"kernel_args\":null}", .{});
    defer unset.deinit();
    try std.testing.expect(unset.value.kernel_args == null);
    const disk = try std.json.parseFromSlice(ProfileMutationRequest, std.testing.allocator, "{\"boot_disk\":\"/dev/nvme0n1\"}", .{});
    defer disk.deinit();
    try std.testing.expectEqualStrings("/dev/nvme0n1", disk.value.boot_disk.?);
}

/// Profile 安装计划属性的唯一写入口。活动 session 已经固定 PXE/answer 计划，
/// 因此引用该 profile 的任一节点仍有活动 session 时拒绝变更；成功后发布新的
/// catalog revision，install 节点仍需显式 `node retry` 武装新计划。
fn managementProfileSet(request: zap.Request, context: *RouteContext, name: []const u8, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"missing request body\"}}\n", meta);
    const raw = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"expected one profile property\"}}\n", meta);
    defer raw.deinit();
    if (raw.value != .object or raw.value.object.count() != 1)
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"expected exactly one of kernel_args or boot_disk\"}}\n", meta);
    const has_kernel_args = raw.value.object.contains("kernel_args");
    const has_boot_disk = raw.value.object.contains("boot_disk");
    if (!has_kernel_args and !has_boot_disk)
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"expected exactly one of kernel_args or boot_disk\"}}\n", meta);
    const parsed = std.json.parseFromSlice(ProfileMutationRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"kernel_args accepts string/null; boot_disk accepts a device path\"}}\n", meta);
    defer parsed.deinit();
    if (lookup.findProfile(context.catalog_snapshot.value(), name) == null) return notFound(request, meta);
    for (context.catalog_snapshot.value().nodes) |node| {
        if (!std.mem.eql(u8, node.profile, name)) continue;
        if (context.sessions.hasActiveNode(node.id, boot_session.monotonicNow()))
            return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"profile.active_session_conflict\",\"message\":\"profile install plan is pinned by an active boot session\"}}\n", meta);
    }
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    const mutation_result = if (has_kernel_args)
        @import("../config/profile_mutation.zig").setKernelArgs(context.io, context.allocator, context.config, context.catalog.path, name, parsed.value.kernel_args)
    else if (parsed.value.boot_disk) |boot_disk|
        @import("../config/profile_mutation.zig").setBootDisk(context.io, context.allocator, context.config, context.catalog.path, name, boot_disk)
    else
        error.InvalidInstallStorage;
    mutation_result catch |err| switch (err) {
        error.InvalidKernelArgs, error.KernelArgsRequiresBootloader => return validationError(request, err, meta),
        error.InvalidInstallStorage, error.NotInstallProfile => return validationError(request, err, meta),
        error.ProfileNotFound => return notFound(request, meta),
        else => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"profile.persist_failed\",\"message\":\"cannot persist profile install plan\"}}\n", meta),
    };
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"profile persisted but snapshot publish failed\"}}\n", meta);
    try setRevisionEtag(request, context.catalog.currentRevision());
    return json(request, .ok, "{\"ok\":true,\"result\":{\"mutation\":\"applied_online\"}}\n", meta);
}

/// 在 model gate 内从 manifest store 载入新 catalog generation，同时用相同
/// config revision 发布兼容投影视图。启动配置 revision 不会因 node/profile
/// mutation 改变；catalog revision 由 manifest 单调推进。
fn applyCatalogFromDisk(context: *RouteContext) !void {
    var parsed = try @import("../catalog/store.zig").load(context.io, context.allocator, context.catalog.path);
    defer parsed.deinit();
    const effective = model.projectCatalog(context.config.*, &parsed.value);
    try config_validate.validate(&effective, &parsed.value);
    // Allocate both generations before publishing either one. The caller holds
    // the model gate, so readers observe the old pair or the fully prepared pair.
    const config_next = try context.configs.prepare(effective, context.config_revision);
    errdefer config_next.release();
    const catalog_revision = if (parsed.value.revision == 0) context.catalog_snapshot.revision + 1 else parsed.value.revision;
    const catalog_next = try context.catalog.prepare(parsed.value, catalog_revision);
    errdefer catalog_next.release();
    context.configs.publishPrepared(config_next);
    context.catalog.lock();
    defer context.catalog.unlock();
    context.catalog.publishPreparedLocked(catalog_next);
}

fn managementNodeAdd(request: zap.Request, context: *RouteContext, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid\",\"message\":\"missing request body\"}}\n", meta);
    var parsed = std.json.parseFromSlice(NodeAddRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid\",\"message\":\"invalid node properties\"}}\n", meta);
    defer parsed.deinit();
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    const value = parsed.value;
    node_mutation.addNode(context.io, context.allocator, context.config, context.catalog.path, .{ .id = value.id, .mac = value.mac, .arch = value.arch, .profile = value.profile, .ip = value.ip, .hostname = value.hostname, .deploy = value.deploy, .http_accel = value.http_accel }) catch |err| switch (err) {
        error.ProfileNotFound => return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"node.profile_not_found\",\"message\":\"referenced profile does not exist; create it with nodeforge profile create\"}}\n", meta),
        error.NodeAlreadyExists => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.already_exists\",\"message\":\"node identifier already exists\"}}\n", meta),
        error.DuplicateMac => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.duplicate_mac\",\"message\":\"MAC address is already assigned to another node\"}}\n", meta),
        else => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.mutation_failed\",\"message\":\"node could not be added\"}}\n", meta),
    };
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"node persisted but snapshot publish failed\"}}\n", meta);
    const current = context.catalog.acquire();
    defer current.release();
    // M4.8 的启动派生容量不能阻止 M4.10 的在线 node add。只按新受管
    // 节点数扩大各投影表，保留更大的 config override，不超过安全天花板。
    context.deployments.growEffective(current.value().nodes.len);
    context.statuses.growEffective(current.value().nodes.len);
    context.inventories.growCapacity(current.value().nodes.len);
    // M4.10：在线添加 install 节点必须与 daemon 启动恢复具有相同的首次
    // generation 语义。否则 fresh CLI 流程会在 node add 成功后仍显示
    // deployment=null，必须额外重启或 retry 才能获得 PXE。
    if (value.deploy) {
        if (lookup.findProfile(current.value(), value.profile)) |profile| if (profile.mode == .install) {
            const desired_digest = @import("../state/plan_digest.zig").forNode(context.allocator, context.config, current.value(), .{
                .bootstrap_key = context.bootstrap_key,
                .additional_keys = context.additional_keys,
            }, value.id) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"node persisted but initial install plan digest could not be computed\"}}\n", meta);
            context.deployments.ensureInitial(value.id, desired_digest, unixNow()) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.capacity_exceeded\",\"message\":\"node persisted but initial install generation could not be allocated\"}}\n", meta);
            deployment_control.save(context.io, context.allocator, paths.require().deployment_control_path, context.deployments) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"node persisted but initial install generation could not be persisted\"}}\n", meta);
        };
    }
    var location: [320]u8 = undefined;
    try request.setHeader("location", try std.fmt.bufPrint(&location, "/api/v1/management/nodes/{s}", .{value.id}));
    var result: [256]u8 = undefined;
    const response = try std.fmt.bufPrint(&result, "{{\"ok\":true,\"result\":{{\"node_id\":{f},\"revision\":{d}}}}}\n", .{ std.json.fmt(value.id, .{}), context.catalog.currentRevision() });
    try setRevisionEtag(request, context.catalog.currentRevision());
    return json(request, .created, response, meta);
}

fn managementNodeSet(request: zap.Request, context: *RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid\",\"message\":\"missing request body\"}}\n", meta);
    var parsed = std.json.parseFromSlice(NodeSetRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid\",\"message\":\"invalid node properties\"}}\n", meta);
    defer parsed.deinit();
    var clears_ip = false;
    for (parsed.value.unset) |key| if (std.mem.eql(u8, key, "ip")) {
        clears_ip = true;
    };
    const protected_change = parsed.value.mac != null or parsed.value.arch != null or parsed.value.profile != null or parsed.value.ip != null or clears_ip;
    if (protected_change and context.sessions.hasActiveNode(node_id, boot_session.monotonicNow())) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.active_session_conflict\",\"message\":\"protected identity is pinned by an active boot session\"}}\n", meta);
    var params: node_mutation.SetParams = .{ .mac = parsed.value.mac, .arch = parsed.value.arch, .profile = parsed.value.profile, .deploy = parsed.value.deploy, .http_accel = parsed.value.http_accel };
    if (parsed.value.ip) |value| {
        params.ip_set = true;
        params.ip = value;
    }
    if (parsed.value.hostname) |value| {
        params.hostname_set = true;
        params.hostname = value;
    }
    for (parsed.value.unset) |key| {
        if (std.mem.eql(u8, key, "ip")) {
            params.ip_set = true;
            params.ip = null;
        } else if (std.mem.eql(u8, key, "hostname")) {
            params.hostname_set = true;
            params.hostname = null;
        } else return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_unset\",\"message\":\"only ip and hostname can be unset\"}}\n", meta);
    }
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    node_mutation.setNode(context.io, context.allocator, context.config, context.catalog.path, node_id, params) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.mutation_failed\",\"message\":\"node could not be updated\"}}\n", meta);
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"node persisted but snapshot publish failed\"}}\n", meta);
    try setRevisionEtag(request, context.catalog.currentRevision());
    return json(request, .ok, "{\"ok\":true,\"result\":{\"mutation\":\"applied_online\"}}\n", meta);
}

fn managementNodeRemove(request: zap.Request, context: *RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    if (context.sessions.hasActiveNode(node_id, boot_session.monotonicNow())) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.active_session_conflict\",\"message\":\"node is pinned by an active boot session\"}}\n", meta);
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    node_mutation.removeNode(context.io, context.allocator, context.config, context.catalog.path, node_id) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.mutation_failed\",\"message\":\"node could not be removed\"}}\n", meta);
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"node persisted but snapshot publish failed\"}}\n", meta);
    try setRevisionEtag(request, context.catalog.currentRevision());
    return json(request, .ok, "{\"ok\":true,\"result\":{\"mutation\":\"applied_online\"}}\n", meta);
}

fn ifMatchCurrent(request: zap.Request, context: *RouteContext) bool {
    const raw = request.getHeader("if-match") orelse return false;
    const value = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') raw[1 .. raw.len - 1] else raw;
    const expected = std.fmt.parseInt(u64, value, 10) catch return false;
    return expected == context.catalog.currentRevision();
}

fn revisionConflict(request: zap.Request, meta: RequestMeta) !void {
    if (request.getHeader("if-match") == null)
        return json(request, .precondition_required, "{\"ok\":false,\"error\":{\"code\":\"http.precondition_required\",\"message\":\"If-Match is required\"}}\n", meta);
    return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"catalog.revision_conflict\",\"message\":\"If-Match does not identify the current catalog revision\"}}\n", meta);
}

fn managementNodes(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    const page = pageRequest(request, "nodes", context.catalog_snapshot.revision) catch |err| return pageError(request, err, meta);
    if (page.offset > context.catalog_snapshot.value().nodes.len) return pageError(request, error.InvalidCursor, meta);
    const end = @min(page.offset + page.limit, context.catalog_snapshot.value().nodes.len);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"view_revision\":{{\"config\":{d},\"catalog\":{d},\"node_status\":{d},\"deployment\":{d},\"inventory\":{d}}},\"items\":[", .{ context.config_revision, context.catalog_snapshot.revision, context.statuses.currentRevision(), context.deployments.currentRevision(), context.inventories.currentRevision() });
    for (context.catalog_snapshot.value().nodes[page.offset..end], 0..) |node, index| {
        if (index != 0) try output.writer.writeByte(',');
        const desired_digest = desiredPlanDigest(context, node.id) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired node plan digest\"}}\n", meta);
        const deployment = context.deployments.view(node.id);
        const status = currentProjectedStatus(context, node.id, deployment, desired_digest);
        const inventory = context.inventories.get(node.id);
        try output.writer.print("{{\"id\":{f},\"mac\":{f},\"ip\":", .{ std.json.fmt(node.id, .{}), std.json.fmt(node.mac, .{}) });
        if (node.ip) |ip| try output.writer.print("{f}", .{std.json.fmt(ip, .{})}) else try output.writer.writeAll("null");
        try output.writer.print(",\"profile\":{f},\"deploy\":{s},\"install_intent\":{f},\"pxe_ready\":{s},\"retry_pending\":{s},\"armed_generation\":{f},\"status\":", .{
            std.json.fmt(node.profile, .{}),
            if (node.deploy) "true" else "false",
            std.json.fmt(installIntent(node.deploy, deployment, desired_digest), .{}),
            if (installPxeReady(node.deploy, deployment, desired_digest)) "true" else "false",
            if (retryPending(deployment)) "true" else "false",
            std.json.fmt(if (deployment) |value| value.armed_generation else null, .{}),
        });
        if (status) |value|
            try output.writer.print("{f}", .{std.json.fmt(@tagName(value.phase), .{})})
        else if (deployment) |value|
            if (deploymentPhaseFallback(value)) |phase| try output.writer.print("{f}", .{std.json.fmt(phase, .{})}) else try output.writer.writeAll("null")
        else
            try output.writer.writeAll("null");
        // 三个时间使用部署任务语义，而不是把内部状态字段名直接暴露给用户：
        // Start=requested_at，Install=install.started/started_at，
        // Finished=首次 terminal/finished_at。Install 后续可与 diskless 的实际
        // 启动阶段并列扩展，Start/Finished 仍保持任务边界不变。
        if (deployment) |value| {
            const times = deploymentTimes(value);
            try output.writer.writeAll(",\"start_at\":");
            if (times.start_at != 0) try output.writer.print("{d}", .{times.start_at}) else try output.writer.writeAll("null");
            try output.writer.writeAll(",\"install_at\":");
            if (times.install_at != 0) try output.writer.print("{d}", .{times.install_at}) else try output.writer.writeAll("null");
            try output.writer.writeAll(",\"finished_at\":");
            if (times.finished_at != 0) try output.writer.print("{d}", .{times.finished_at}) else try output.writer.writeAll("null");
            try output.writer.writeAll(",\"deployed_at\":");
            if (value.deployed_at != 0) try output.writer.print("{d}", .{value.deployed_at}) else try output.writer.writeAll("null");
            const drift = context.deployments.drift(node.id, desired_digest);
            try output.writer.print(",\"drifted\":{s},\"drift_state\":{f}", .{ if (drift == .drifted) "true" else "false", std.json.fmt(@tagName(drift), .{}) });
        } else try output.writer.writeAll(",\"start_at\":null,\"install_at\":null,\"finished_at\":null,\"deployed_at\":null,\"drifted\":false");
        try output.writer.writeAll(",\"serial_number\":");
        if (inventory) |value| if (value.serial_number) |serial| try output.writer.print("{f}", .{std.json.fmt(serial, .{})}) else try output.writer.writeAll("null") else try output.writer.writeAll("null");
        try output.writer.writeByte('}');
    }
    try output.writer.writeByte(']');
    try writeNextCursor(&output.writer, "nodes", context.catalog_snapshot.revision, end, context.catalog_snapshot.value().nodes.len);
    try output.writer.writeAll("}}\n");
    try setRevisionEtag(request, context.catalog_snapshot.revision);
    return json(request, .ok, output.written(), meta);
}

fn managementNode(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const node = lookup.findNode(context.catalog_snapshot.value(), node_id) orelse return notFound(request, meta);
    const profile = lookup.findProfile(context.catalog_snapshot.value(), node.profile) orelse return notFound(request, meta);
    const desired_revision = desiredRevision(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired model revision\"}}\n", meta);
    const desired_digest = desiredPlanDigest(context, node_id) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired node plan digest\"}}\n", meta);
    const deployment = context.deployments.view(node_id);
    const status = currentProjectedStatus(context, node_id, deployment, desired_digest);
    const inventory = context.inventories.get(node_id);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"view_revision\":{{\"config\":{d},\"catalog\":{d},\"node_status\":{d},\"deployment\":{d},\"inventory\":{d}}},\"node\":{f},\"profile\":{{\"name\":{f},\"mode\":{f},\"distro\":{f},\"version\":{f},\"arch\":{f},\"install_source\":{f},\"boot_bundle\":{f},\"kernel_args\":{f},\"safety\":{f}}},\"effective_system\":", .{ context.config_revision, context.catalog_snapshot.revision, context.statuses.currentRevision(), context.deployments.currentRevision(), context.inventories.currentRevision(), std.json.fmt(node, .{}), std.json.fmt(profile.name, .{}), std.json.fmt(@tagName(profile.mode), .{}), std.json.fmt(profile.distro, .{}), std.json.fmt(profile.version, .{}), std.json.fmt(@tagName(profile.arch), .{}), std.json.fmt(profile.install_source, .{}), std.json.fmt(profile.boot_bundle, .{}), std.json.fmt(profile.kernel_args, .{}), std.json.fmt(profile.safety, .{}) });
    try writeEffectiveSystem(&output.writer, profile);
    try output.writer.writeAll(",\"status\":");
    if (status) |value| try output.writer.print("{{\"phase\":{f},\"boot_session_id\":{f},\"model_revision\":{d},\"deployment_generation\":{d},\"last_event_at\":{d},\"last_error\":{s},\"reason\":{f},\"session_active\":{s}}}", .{
        std.json.fmt(@tagName(value.phase), .{}),
        std.json.fmt(value.boot_session_id[0..], .{}),
        value.model_revision,
        value.deployment_generation,
        value.last_event_at,
        if (value.last_error) "true" else "false",
        std.json.fmt(value.reasonSlice(), .{}),
        if (value.session_active) "true" else "false",
    }) else try output.writer.writeAll("null");
    try output.writer.writeAll(",\"deployment\":");
    if (deployment) |value| {
        const times = deploymentTimes(value);
        const drift = context.deployments.drift(node_id, desired_digest);
        try output.writer.print("{{\"install_intent\":{f},\"pxe_ready\":{s},\"retry_pending\":{s},\"current_generation\":{f},\"armed_generation\":{f},\"consumed_generation\":{f},\"terminal_generation\":{f},\"requested_revision\":{d},\"applied_revision\":{d},\"desired_revision\":{d},\"requested_plan_digest\":{f},\"applied_plan_digest\":{f},\"desired_plan_digest\":{f},\"drifted\":{s},\"drift_state\":{f},\"requested_by\":{f},\"start_at\":{d},\"install_at\":{d},\"finished_at\":{d},\"successful_generation\":{d},\"deployed_at\":{d}}}", .{
            std.json.fmt(installIntent(node.deploy, value, desired_digest), .{}),
            if (installPxeReady(node.deploy, value, desired_digest)) "true" else "false",
            if (retryPending(value)) "true" else "false",
            std.json.fmt(value.currentGeneration(), .{}),
            std.json.fmt(value.armed_generation, .{}),
            std.json.fmt(value.consumed_generation, .{}),
            std.json.fmt(value.terminal_generation, .{}),
            value.requested_revision,
            value.applied_revision,
            desired_revision,
            std.json.fmt(if (deployment_control.digestSet(value.requested_plan_digest)) value.requested_plan_digest[0..] else null, .{}),
            std.json.fmt(if (deployment_control.digestSet(value.applied_plan_digest)) value.applied_plan_digest[0..] else null, .{}),
            std.json.fmt(desired_digest[0..], .{}),
            if (drift == .drifted) "true" else "false",
            std.json.fmt(@tagName(drift), .{}),
            std.json.fmt(@tagName(value.requested_by), .{}),
            times.start_at,
            times.install_at,
            times.finished_at,
            value.deployed_generation,
            value.deployed_at,
        });
    } else try output.writer.writeAll("null");
    try output.writer.writeAll(",\"inventory\":");
    if (inventory) |value| try output.writer.print("{f}", .{std.json.fmt(value, .{})}) else try output.writer.writeAll("null");
    try output.writer.writeAll("}}\n");
    try setRevisionEtag(request, context.catalog_snapshot.revision);
    return json(request, .ok, output.written(), meta);
}

/// 返回与当前 desired model 和当前 deployment generation 同源的状态。
/// node list/show 是一致投影，不能把历史 session 的 phase 与新 profile/retry 拼接。
fn currentProjectedStatus(context: *const RouteContext, node_id: []const u8, deployment: ?deployment_control.View, desired_digest: deployment_control.Digest) ?node_status.Status {
    var status = context.statuses.get(node_id) orelse return null;
    // schema 4 首版尚无 provenance。只在 deployment state 能以“同一 terminal
    // generation + 同一 finished timestamp”严格佐证时补全；不能仅凭 node_id
    // 接受旧 completed，否则 profile 修改后又会把旧结果拼到新 desired config。
    if (!deployment_control.digestSet(status.model_plan_digest)) {
        const view = deployment orelse return null;
        status = corroborateLegacyStatus(status, view) orelse return null;
    }
    if (!deployment_control.digestSet(status.model_plan_digest) or !deployment_control.digestEqual(status.model_plan_digest, desired_digest)) return null;
    if (status.deployment_generation != 0) {
        const view = deployment orelse return null;
        const current_generation = view.currentGeneration() orelse return null;
        if (status.deployment_generation != current_generation) return null;
    }
    return status;
}

fn corroborateLegacyStatus(raw: node_status.Status, view: deployment_control.View) ?node_status.Status {
    const current_generation = view.currentGeneration() orelse return null;
    if (view.terminal_generation != current_generation or view.finished_at == 0 or raw.last_event_at != view.finished_at) return null;
    const terminal_matches = switch (raw.phase) {
        .completed => view.deployed_generation == current_generation,
        .failed => view.deployed_generation != current_generation,
        else => false,
    };
    if (!terminal_matches) return null;
    var status = raw;
    status.model_revision = view.requested_revision;
    status.model_plan_digest = view.requested_plan_digest;
    status.deployment_generation = current_generation;
    return status;
}

/// status 快照不可用时，从持久 deployment state 给出保守阶段，避免已武装或
/// 已消费 generation 在 CLI 中显示为无状态。它不推测细粒度安装阶段。
fn deploymentPhaseFallback(view: deployment_control.View) ?[]const u8 {
    if (view.armed_generation != null) return "pending";
    const consumed = view.consumed_generation orelse return null;
    if (view.terminal_generation == consumed)
        return if (view.deployed_generation == consumed) "completed" else "failed";
    if (view.started_at != 0) return "install_started";
    return null;
}

/// M4.9 破坏性安装意图投影：node identity 与 `deploy` 决定节点是否参与，
/// generation/revision 决定某一次具体安装是否仍获授权。
fn installIntent(deploy: bool, view: ?deployment_control.View, desired_digest: deployment_control.Digest) []const u8 {
    if (!deploy) return "disabled";
    const value = view orelse return "not-applicable";
    if (value.armed_generation != null) {
        if (!deployment_control.digestSet(value.requested_plan_digest) or !deployment_control.digestEqual(value.requested_plan_digest, desired_digest)) return "rearm-required";
        return switch (value.requested_by) {
            .initial => "initial-armed",
            .operator => "retry-armed",
            .policy_always => "policy-armed",
        };
    }
    if (value.consumed_generation) |generation| {
        if (value.terminal_generation == null or value.terminal_generation.? != generation) return "installing";
    }
    return "not-armed";
}

fn installPxeReady(deploy: bool, view: ?deployment_control.View, desired_digest: deployment_control.Digest) bool {
    const value = view orelse return false;
    return deploy and value.armed_generation != null and deployment_control.digestSet(value.requested_plan_digest) and deployment_control.digestEqual(value.requested_plan_digest, desired_digest);
}

fn retryPending(view: ?deployment_control.View) bool {
    const value = view orelse return false;
    return value.armed_generation != null and value.requested_by == .operator;
}

test "install intent distinguishes initial retry stale and consumed states" {
    const digest_42: deployment_control.Digest = [_]u8{'4'} ** 64;
    const digest_43: deployment_control.Digest = [_]u8{'5'} ** 64;
    var view: deployment_control.View = .{
        .next_generation = 2,
        .armed_generation = 1,
        .consumed_generation = null,
        .terminal_generation = null,
        .requested_revision = 42,
        .requested_plan_digest = digest_42,
        .applied_revision = 0,
        .requested_at = 1,
        .started_at = 0,
        .finished_at = 0,
        .deployed_at = 0,
        .requested_by = .initial,
    };
    try std.testing.expectEqualStrings("disabled", installIntent(false, view, digest_42));
    try std.testing.expectEqualStrings("initial-armed", installIntent(true, view, digest_42));
    try std.testing.expect(installPxeReady(true, view, digest_42));
    view.requested_by = .operator;
    try std.testing.expectEqualStrings("retry-armed", installIntent(true, view, digest_42));
    try std.testing.expect(retryPending(view));
    try std.testing.expectEqualStrings("rearm-required", installIntent(true, view, digest_43));
    try std.testing.expect(!installPxeReady(true, view, digest_43));
    view.armed_generation = null;
    view.consumed_generation = 1;
    try std.testing.expectEqualStrings("installing", installIntent(true, view, digest_42));
    view.terminal_generation = 1;
    try std.testing.expectEqualStrings("not-armed", installIntent(true, view, digest_42));
}

const DeploymentTimes = struct { start_at: i64, install_at: i64, finished_at: i64 };

/// 对外时间名称与内部状态字段的唯一映射。Start/Finished 是部署任务边界；
/// Install 是 install.started 的阶段点。M5 添加 diskless 阶段时必须扩展并列
/// 字段，不能改变这三个字段的既有含义。
fn deploymentTimes(view: deployment_control.View) DeploymentTimes {
    return .{ .start_at = view.requested_at, .install_at = view.started_at, .finished_at = view.finished_at };
}

test "deployment time projection maps task and install boundaries" {
    const view: deployment_control.View = .{
        .next_generation = 2,
        .armed_generation = null,
        .consumed_generation = 1,
        .terminal_generation = 1,
        .requested_revision = 42,
        .applied_revision = 42,
        .requested_at = 10,
        .started_at = 20,
        .finished_at = 30,
        .deployed_at = 30,
        .requested_by = .operator,
    };
    const times = deploymentTimes(view);
    try std.testing.expectEqual(@as(i64, 10), times.start_at);
    try std.testing.expectEqual(@as(i64, 20), times.install_at);
    try std.testing.expectEqual(@as(i64, 30), times.finished_at);
}

test "management node fallback stays on the current generation" {
    var view: deployment_control.View = .{
        .next_generation = 6,
        .armed_generation = 5,
        .consumed_generation = 4,
        .terminal_generation = 4,
        .requested_revision = 2,
        .applied_revision = 1,
        .requested_at = 10,
        .started_at = 0,
        .finished_at = 0,
        .deployed_generation = 4,
        .deployed_at = 9,
        .requested_by = .operator,
    };
    try std.testing.expectEqualStrings("pending", deploymentPhaseFallback(view).?);
    view.armed_generation = null;
    view.consumed_generation = 5;
    view.started_at = 11;
    try std.testing.expectEqualStrings("install_started", deploymentPhaseFallback(view).?);
    view.terminal_generation = 5;
    try std.testing.expectEqualStrings("failed", deploymentPhaseFallback(view).?);
    view.deployed_generation = 5;
    try std.testing.expectEqualStrings("completed", deploymentPhaseFallback(view).?);
}

test "legacy terminal status is adopted only when deployment facts corroborate it" {
    var status: node_status.Status = .{ .phase = .completed, .last_event_at = 20 };
    var view: deployment_control.View = .{
        .next_generation = 6,
        .armed_generation = null,
        .consumed_generation = 5,
        .terminal_generation = 5,
        .requested_revision = 42,
        .applied_revision = 42,
        .requested_at = 10,
        .started_at = 15,
        .finished_at = 20,
        .deployed_generation = 5,
        .deployed_at = 20,
        .requested_by = .operator,
    };
    const adopted = corroborateLegacyStatus(status, view).?;
    try std.testing.expectEqual(@as(u64, 42), adopted.model_revision);
    try std.testing.expectEqual(@as(u64, 5), adopted.deployment_generation);
    view.armed_generation = 6;
    try std.testing.expect(corroborateLegacyStatus(status, view) == null);
    status.last_event_at = 19;
    view.armed_generation = null;
    try std.testing.expect(corroborateLegacyStatus(status, view) == null);
}

fn writeEffectiveSystem(writer: *std.Io.Writer, profile: *const model.ProfileConfig) !void {
    const system = @import("../profile/install.zig").effectiveSystem(profile) catch return error.InvalidEffectiveSystem;
    try writer.print("{{\"localization\":{f},\"connectivity\":{f},\"ssh\":{{\"enabled\":{s},\"password_authentication\":{s},\"root_login\":{f},\"root_password_configured\":{s},\"root_authorized_key_count\":{d}}},\"security\":{f},\"users\":[", .{
        std.json.fmt(system.localization, .{}),
        std.json.fmt(system.connectivity, .{}),
        if (system.ssh.enabled) "true" else "false",
        if (system.ssh.password_authentication) "true" else "false",
        std.json.fmt(@tagName(system.ssh.root_login), .{}),
        if (system.ssh.root_password != null) "true" else "false",
        system.ssh.root_authorized_keys.len,
        std.json.fmt(system.security, .{}),
    });
    for (system.users, 0..) |user, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{{\"name\":{f},\"sudo\":{s},\"password_configured\":{s},\"authorized_key_count\":{d}}}", .{ std.json.fmt(user.name, .{}), if (user.sudo) "true" else "false", if (user.password != null) "true" else "false", user.ssh_authorized_keys.len });
    }
    try writer.writeAll("],\"packages\":");
    try std.json.Stringify.value(system.packages, .{}, writer);
    try writer.writeByte('}');
}

fn managementProfiles(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    const page = pageRequest(request, "profiles", context.catalog_snapshot.revision) catch |err| return pageError(request, err, meta);
    if (page.offset > context.catalog_snapshot.value().profiles.len) return pageError(request, error.InvalidCursor, meta);
    const end = @min(page.offset + page.limit, context.catalog_snapshot.value().profiles.len);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"items\":[");
    for (context.catalog_snapshot.value().profiles[page.offset..end], 0..) |profile, index| {
        if (index != 0) try output.writer.writeByte(',');
        var refs: usize = 0;
        for (context.catalog_snapshot.value().nodes) |node| if (std.mem.eql(u8, node.profile, profile.name)) {
            refs += 1;
        };
        try output.writer.print("{{\"name\":{f},\"mode\":{f},\"distro\":{f},\"version\":{f},\"arch\":{f},\"install_source\":", .{ std.json.fmt(profile.name, .{}), std.json.fmt(@tagName(profile.mode), .{}), std.json.fmt(profile.distro, .{}), std.json.fmt(profile.version, .{}), std.json.fmt(@tagName(profile.arch), .{}) });
        if (profile.install_source) |source| try output.writer.print("{f}", .{std.json.fmt(source, .{})}) else try output.writer.writeAll("null");
        try output.writer.print(",\"nodes\":{d},\"valid\":true}}", .{refs});
    }
    try output.writer.writeByte(']');
    try writeNextCursor(&output.writer, "profiles", context.catalog_snapshot.revision, end, context.catalog_snapshot.value().profiles.len);
    try output.writer.print(",\"view_revision\":{d}}}}}\n", .{context.catalog_snapshot.revision});
    try setRevisionEtag(request, context.catalog_snapshot.revision);
    return json(request, .ok, output.written(), meta);
}

fn managementProfile(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    const profile = lookup.findProfile(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    const distro = lookup.findDistro(context.catalog_snapshot.value(), profile.distro) orelse return notFound(request, meta);
    const capability = lookup.findDistroVersion(context.catalog_snapshot.value(), profile.distro, profile.version, profile.arch) orelse return notFound(request, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"model_revision\":{{\"config\":{d},\"catalog\":{d}}},\"name\":{f},\"mode\":{f},\"distro\":{f},\"version\":{f},\"arch\":{f},\"boot_bundle\":{f},\"kernel_args\":{f},\"install\":{f},\"safety\":{f},\"validation\":{{\"valid\":true}},\"capability\":{{\"family\":{f},\"install_adapter\":{f},\"package_manager\":{f}}},\"effective_system\":", .{ context.config_revision, context.catalog_snapshot.revision, std.json.fmt(profile.name, .{}), std.json.fmt(@tagName(profile.mode), .{}), std.json.fmt(profile.distro, .{}), std.json.fmt(profile.version, .{}), std.json.fmt(@tagName(profile.arch), .{}), std.json.fmt(profile.boot_bundle, .{}), std.json.fmt(profile.kernel_args, .{}), std.json.fmt(profile.install, .{}), std.json.fmt(profile.safety, .{}), std.json.fmt(@tagName(distro.family), .{}), std.json.fmt(@tagName(capability.install_adapter), .{}), std.json.fmt(@tagName(capability.package_manager), .{}) });
    try writeEffectiveSystem(&output.writer, profile);
    try output.writer.writeAll(",\"install_source\":");
    const catalog_snapshot = context.catalog_snapshot;
    if (profile.install_source) |source_name| {
        const source = lookup.findInstallSource(catalog_snapshot.value(), source_name) orelse return notFound(request, meta);
        try output.writer.print("{f},\"assets\":[", .{std.json.fmt(source.*, .{})});
        const asset_names = [_][]const u8{ source.source_asset, source.installer_kernel, source.installer_initrd };
        for (asset_names, 0..) |asset_name, index| {
            const asset = lookup.findAsset(catalog_snapshot.value(), asset_name) orelse return notFound(request, meta);
            if (index != 0) try output.writer.writeByte(',');
            try output.writer.print("{f}", .{std.json.fmt(asset.*, .{})});
        }
        try output.writer.writeByte(']');
    } else try output.writer.writeAll("null,\"assets\":[]");
    try output.writer.writeAll(",\"nodes\":[");
    var first = true;
    for (context.catalog_snapshot.value().nodes) |node| if (std.mem.eql(u8, node.profile, name)) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{f}", .{std.json.fmt(node.id, .{})});
    };
    try output.writer.writeAll("]}}\n");
    try setRevisionEtag(request, context.catalog_snapshot.revision);
    return json(request, .ok, output.written(), meta);
}

fn managementNodeStatus(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const desired_revision = desiredRevision(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired model revision\"}}\n", meta);
    const desired_digest = desiredPlanDigest(context, node_id) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired node plan digest\"}}\n", meta);
    const deployment = context.deployments.view(node_id);
    const status = currentProjectedStatus(context, node_id, deployment, desired_digest) orelse return notFound(request, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"id\":{f},\"boot_session_id\":{f},\"model_revision\":{d},\"deployment_generation\":{d},\"phase\":{f},\"last_event_at\":{d},\"last_error\":{s},\"reason\":{f},\"session_active\":{s}", .{
        std.json.fmt(status.node(), .{}),           std.json.fmt(status.boot_session_id[0..], .{}), status.model_revision,                          status.deployment_generation, std.json.fmt(@tagName(status.phase), .{}), status.last_event_at,
        if (status.last_error) "true" else "false", std.json.fmt(status.reasonSlice(), .{}),        if (status.session_active) "true" else "false",
    });
    if (deployment) |value| {
        const drift = context.deployments.drift(node_id, desired_digest);
        try output.writer.print(",\"deployment\":{{\"armed_generation\":{f},\"consumed_generation\":{f},\"terminal_generation\":{f},\"requested_revision\":{d},\"applied_revision\":{d},\"desired_revision\":{d},\"desired_plan_digest\":{f},\"drifted\":{s},\"drift_state\":{f},\"requested_at\":{d},\"requested_by\":{f}}}", .{
            std.json.fmt(value.armed_generation, .{}),
            std.json.fmt(value.consumed_generation, .{}),
            std.json.fmt(value.terminal_generation, .{}),
            value.requested_revision,
            value.applied_revision,
            desired_revision,
            std.json.fmt(desired_digest[0..], .{}),
            if (drift == .drifted) "true" else "false",
            std.json.fmt(@tagName(drift), .{}),
            value.requested_at,
            std.json.fmt(@tagName(value.requested_by), .{}),
        });
        try output.writer.print(",\"deployment_start_at\":{d},\"deployment_install_at\":{d},\"deployment_finished_at\":{d},\"deployed_at\":{d}", .{ value.requested_at, value.started_at, value.finished_at, value.deployed_at });
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
    // Runtime lease deadlines use MONOTONIC, but `expires_at` is a public Unix
    // timestamp. Sample both clocks once so every row in this response shares
    // the same conversion basis.
    const realtime_now = unixNow();
    const monotonic_now = boot_session.monotonicNow();
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
            monotonicExpiryToUnix(lease.expires_at, realtime_now, monotonic_now),
        });
    }
    try output.writer.writeAll("]}}\n");
    try json(request, .ok, output.written(), meta);
}

fn monotonicExpiryToUnix(expires_at: i64, realtime_now: i64, monotonic_now: i64) i64 {
    return realtime_now + (expires_at - monotonic_now);
}

test "DHCP management expiry projects monotonic deadlines as Unix time" {
    try std.testing.expectEqual(@as(i64, 2100), monotonicExpiryToUnix(1100, 2000, 1000));
    try std.testing.expectEqual(@as(i64, 1990), monotonicExpiryToUnix(990, 2000, 1000));
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

fn methodNotAllowed(request: zap.Request, allow: []const u8, meta: RequestMeta) !void {
    try request.setHeader("allow", allow);
    try json(request, .method_not_allowed, "{\"ok\":false,\"error\":{\"code\":\"http.method_not_allowed\",\"message\":\"method not allowed\"}}\n", meta);
}

/// M4.5：为错误信封补充 `request_id`。所有错误响应统一形如
/// `{"ok":false,"error":{...}}\n`；这里在 error 对象闭合前（结构性的 `}}\n`）
/// 插入 `,"request_id":"<hex>"`。成功信封 (`{"ok":true,`) 与结尾非 `}}\n`
/// 的响应保持原样，避免破坏 boot/install-config 等非错误或非标准响应。
/// 纯函数，便于单测；返回 null 表示不重写，调用方回退到原 body。
fn appendRequestId(body: []const u8, request_id: []const u8, out: []u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, body, "{\"ok\":false,")) return null;
    if (!std.mem.endsWith(u8, body, "}}\n")) return null;
    const tail = ",\"request_id\":\"";
    const suffix = "\"}}\n";
    const needed = (body.len - 3) + tail.len + request_id.len + suffix.len;
    if (needed > out.len) return null;
    var n: usize = 0;
    @memcpy(out[n .. n + body.len - 3], body[0 .. body.len - 3]);
    n += body.len - 3;
    @memcpy(out[n .. n + tail.len], tail);
    n += tail.len;
    @memcpy(out[n .. n + request_id.len], request_id);
    n += request_id.len;
    @memcpy(out[n .. n + suffix.len], suffix);
    return out[0 .. n + suffix.len];
}

test "appendRequestId injects request_id only into error envelopes" {
    var out: [256]u8 = undefined;
    const id = "0000000000000000000000000000000a";
    const err = "{\"ok\":false,\"error\":{\"code\":\"http.not_found\",\"message\":\"route not found\"}}\n";
    const rewritten = appendRequestId(err, id, &out).?;
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":{\"code\":\"http.not_found\",\"message\":\"route not found\",\"request_id\":\"0000000000000000000000000000000a\"}}\n", rewritten);
    // 成功信封不重写。
    try std.testing.expect(appendRequestId("{\"ok\":true,\"result\":{}}\n", id, &out) == null);
    // 结尾非 }}\n 的响应安全回退到原 body。
    try std.testing.expect(appendRequestId("{\"ok\":false,\"error\":{}}", id, &out) == null);
}

/// 通过 Zap 发送 JSON 响应并记录方法、路径、状态码、字节数、持续时间和
/// 客户端 IP。请求体和凭据永远不会进入日志。
fn json(request: zap.Request, status: zap.http.StatusCode, body: []const u8, meta: RequestMeta) !void {
    request.setStatus(status);
    // M4.5：错误信封统一补充 request_id，便于 CLI 关联失败请求；成功信封、
    // 非 JSON 或超长 body 安全回退到原 body（appendRequestId 返回 null）。
    var envelope: [4096]u8 = undefined;
    const effective_body = appendRequestId(body, &meta.request_id, &envelope) orelse body;
    const duration_us = meta.started.durationTo(std.Io.Clock.awake.now(meta.io)).toMicroseconds();
    const is_health = std.mem.eql(u8, request.path orelse "", "/healthz");
    if (is_health) log.debug("{s} {s} -> {d} ({d} bytes, {d}us, client={s})", .{
        request.method orelse "OTHER", request.path orelse "<missing>", @intFromEnum(status), effective_body.len, duration_us, meta.client_ip,
    }) else log.info("{s} {s} -> {d} ({d} bytes, {d}us, client={s})", .{
        request.method orelse "OTHER",
        request.path orelse "<missing>",
        @intFromEnum(status),
        effective_body.len,
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
            // M4.3-06 §8.3：按请求路径前缀分类流量，写入审计事件。
            const traffic_class: []const u8 = if (std.mem.startsWith(u8, path, "/artifacts/repositories/")) "repository" else if (std.mem.startsWith(u8, path, "/artifacts/images/")) "image" else if (std.mem.startsWith(u8, path, "/artifacts/boot/")) "boot" else "api";
            const fields = [_]events.Field{
                .{ .key = "method", .value = method },
                .{ .key = "path", .value = path },
                .{ .key = "status", .value = std.fmt.bufPrint(&status_text, "{d}", .{@intFromEnum(status)}) catch "0" },
                .{ .key = "bytes_sent", .value = std.fmt.bufPrint(&bytes_text, "{d}", .{effective_body.len}) catch "0" },
                .{ .key = "client_ip", .value = meta.client_ip },
                .{ .key = "duration_us", .value = std.fmt.bufPrint(&duration_text, "{d}", .{duration_us}) catch "0" },
                .{ .key = "traffic_class", .value = traffic_class },
            };
            context.event_writer.appendWithFields(context.io, context.allocator, paths.require().events_path, "http.request", "HTTP request completed", &fields) catch |err|
                observe_log.err("http: event append failed: {t}", .{err});
        }
    }
    // 直接设置 header 而非使用 `sendJson`：Zap 的助手会发出自己的
    // debug 行，即使 NodeForge 配置为 info 级别日志。
    try request.setHeader("content-type", "application/json");
    try request.setHeader("cache-control", "no-store, private");
    try request.setHeader("x-content-type-options", "nosniff");
    try request.sendBody(effective_body);
}

test "Zap-backed route module compiles" {
    try std.testing.expect(active_context == null);
    try std.testing.expect(isLoopbackPeer("127.0.0.1"));
    try std.testing.expect(!isLoopbackPeer("192.168.50.9"));
}

test "M4.2 curtin webhook events map to stable install stages" {
    try std.testing.expectEqualStrings("started", mapSubiquityStage("curtin/command-install", "start", "").?);
    try std.testing.expectEqualStrings("partitioning", mapSubiquityStage("curtin/command-install/stage-partitioning", "start", "").?);
    try std.testing.expectEqualStrings("packages", mapSubiquityStage("curtin/command-install/stage-extract", "start", "").?);
    try std.testing.expectEqualStrings("bootloader", mapSubiquityStage("curtin/command-install/stage-curthooks", "start", "").?);
    try std.testing.expectEqualStrings("completed", mapSubiquityStage("curtin/command-install", "finish", "SUCCESS").?);
    try std.testing.expectEqualStrings("failed", mapSubiquityStage("curtin/command-install/stage-extract", "finish", "FAIL").?);
    // 子阶段成功只表示该阶段结束，不能提前关闭整个 boot session。
    try std.testing.expect(mapSubiquityStage("curtin/command-install/stage-extract", "finish", "SUCCESS") == null);
}

test "single byte ranges cover bounded, open-ended, suffix and EOF forms" {
    // 有界形式：bytes=4-7 → offset=4, length=4
    const bounded = try parseSingleRange("bytes=4-7", 10);
    try std.testing.expectEqual(ByteRange{ .offset = 4, .length = 4 }, bounded);
    // 截断形式：bytes=8-99 → offset=8, length=2（截断到 size-1）
    const clipped = try parseSingleRange("bytes=8-99", 10);
    try std.testing.expectEqual(ByteRange{ .offset = 8, .length = 2 }, clipped);
    // 开放形式：bytes=7- → offset=7, length=3
    const open_ended = try parseSingleRange("bytes=7-", 10);
    try std.testing.expectEqual(ByteRange{ .offset = 7, .length = 3 }, open_ended);
    // 后缀形式：bytes=-4 → offset=6, length=4
    const suffix = try parseSingleRange("bytes=-4", 10);
    try std.testing.expectEqual(ByteRange{ .offset = 6, .length = 4 }, suffix);
    // 多段 Range 被拒绝
    try std.testing.expectError(error.InvalidRange, parseSingleRange("bytes=0-1,3-4", 10));
    // GRUB HTTP 兼容：bytes=<size>- 返回空范围(offset=size, length=0)而非 error
    const eof_range = try parseSingleRange("bytes=10-", 10);
    try std.testing.expectEqual(ByteRange{ .offset = 10, .length = 0 }, eof_range);
    // offset > size 仍为非法范围
    try std.testing.expectError(error.InvalidRange, parseSingleRange("bytes=11-", 10));
}
