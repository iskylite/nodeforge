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
const config_load = @import("../config/load.zig");
const cli_properties = @import("../cli/properties.zig");
const adapter_capabilities = @import("../profile/capabilities.zig");
const effective_compiler = @import("../profile/effective.zig");
const value_mutation = @import("../config/value_mutation.zig");
const item_mutation = @import("../config/item_mutation.zig");
const scalar_mutation = @import("../config/scalar_mutation.zig");
const provision_bundle_mutation = @import("../config/provision_bundle_mutation.zig");
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
const identity_store = @import("../state/identity_store.zig");
const auth = @import("auth.zig");
const lookup = @import("../catalog.zig");
const asset_validate = @import("../assets/validate.zig");
const iso_import = @import("../catalog/iso_import.zig");
const catalog_discovery = @import("../catalog/discovery.zig");
const dto = @import("../catalog/dto.zig");
const model_transaction = @import("../state/model_transaction.zig");
const config_store = @import("../config/store.zig");
const catalog_store = @import("../catalog/store.zig");
const dhcp_server = @import("../dhcp/server.zig");
const status_store = @import("../state/status_store.zig");
const boot_session_store = @import("../state/boot_session_store.zig");
const deployment_control = @import("../state/deployment_control.zig");
const node_inventory = @import("../state/node_inventory.zig");
const operations = @import("../state/operations.zig");
const rootfs_artifact_store = @import("../state/rootfs_artifact_store.zig");
const repository_index_blob = @import("../state/repository_index_blob.zig");
const diskless_delivery = @import("../state/diskless_delivery.zig");
const diskless_credential = @import("../state/diskless_credential.zig");
const diskless_lifecycle = @import("../state/diskless_session.zig");
const dhcp_store = @import("../state/dhcp_store.zig");
const install_post_journal = @import("../state/install_post_journal.zig");
const diskless = @import("../profile/diskless.zig");
const diskless_dto = @import("diskless_dto.zig");
const rootfs_build_executor = @import("../provision/rootfs_build_executor.zig");
const rootfs_os_builder = @import("../provision/rootfs_os_builder.zig");
const initrd_memory = @import("../initrd/memory.zig");
const initrd_build_executor = @import("../provision/initrd_build_executor.zig");
const artifact_layout = @import("../provision/artifact_layout.zig");
const password_hash = @import("../profile/password_hash.zig");
const routes = @import("routes.zig");
const log = std.log.scoped(.http);

const max_rootfs_build_jobs = 8;
const rootfs_profile_cap = 128;
const rootfs_digest_len = 64;
const initrd_field_cap = 192;
/// ISO 导入 job 的文本字段上限：staged 不透明文件名（24 hex + 原 basename）
/// 与 logical id（≤128）都远小于此。
const iso_field_cap = 256;
const iso_id_cap = 128;

const RootfsBuildJob = struct {
    active: bool = false,
    operation_id: [boot_session.id_len]u8 = [_]u8{0} ** boot_session.id_len,
    profile: [rootfs_profile_cap]u8 = [_]u8{0} ** rootfs_profile_cap,
    profile_len: u8 = 0,
    input_digest: [rootfs_digest_len]u8 = [_]u8{0} ** rootfs_digest_len,
};

const RootfsBuildWorker = struct {
    jobs: [max_rootfs_build_jobs]RootfsBuildJob = [_]RootfsBuildJob{.{}} ** max_rootfs_build_jobs,
    mutex: std.atomic.Mutex = .unlocked,
    stop: std.atomic.Value(bool) = .init(false),

    fn submit(self: *RootfsBuildWorker, operation_id: []const u8, profile: []const u8, input_digest: []const u8) !void {
        if (operation_id.len != boot_session.id_len or profile.len == 0 or profile.len > rootfs_profile_cap or input_digest.len != rootfs_digest_len)
            return error.InvalidRootfsBuildJob;
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
        defer self.mutex.unlock();
        for (&self.jobs) |*job| if (!job.active) {
            job.* = .{ .active = true, .profile_len = @intCast(profile.len) };
            @memcpy(&job.operation_id, operation_id);
            @memcpy(job.profile[0..profile.len], profile);
            @memcpy(&job.input_digest, input_digest);
            return;
        };
        return error.RootfsBuildQueueFull;
    }

    fn take(self: *RootfsBuildWorker) ?RootfsBuildJob {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
        defer self.mutex.unlock();
        for (&self.jobs) |*job| if (job.active) {
            const result = job.*;
            job.* = .{};
            return result;
        };
        return null;
    }
};

const InitrdBuildJob = struct {
    active: bool = false,
    operation_id: [boot_session.id_len]u8 = [_]u8{0} ** boot_session.id_len,
    name: [initrd_field_cap]u8 = [_]u8{0} ** initrd_field_cap,
    name_len: u8 = 0,
    source: [initrd_field_cap]u8 = [_]u8{0} ** initrd_field_cap,
    source_len: u8 = 0,
    kernel_release: [initrd_field_cap]u8 = [_]u8{0} ** initrd_field_cap,
    kernel_release_len: u8 = 0,
};

const InitrdBuildWorker = struct {
    jobs: [max_rootfs_build_jobs]InitrdBuildJob = [_]InitrdBuildJob{.{}} ** max_rootfs_build_jobs,
    mutex: std.atomic.Mutex = .unlocked,
    stop: std.atomic.Value(bool) = .init(false),

    fn submit(self: *InitrdBuildWorker, operation_id: []const u8, name: []const u8, source: []const u8, kernel_release: []const u8) !void {
        if (operation_id.len != boot_session.id_len or name.len == 0 or name.len > initrd_field_cap or source.len == 0 or source.len > initrd_field_cap or kernel_release.len == 0 or kernel_release.len > initrd_field_cap)
            return error.InvalidInitrdBuildJob;
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
        defer self.mutex.unlock();
        for (&self.jobs) |*job| if (!job.active) {
            job.* = .{ .active = true, .name_len = @intCast(name.len), .source_len = @intCast(source.len), .kernel_release_len = @intCast(kernel_release.len) };
            @memcpy(&job.operation_id, operation_id);
            @memcpy(job.name[0..name.len], name);
            @memcpy(job.source[0..source.len], source);
            @memcpy(job.kernel_release[0..kernel_release.len], kernel_release);
            return;
        };
        return error.InitrdBuildQueueFull;
    }

    fn take(self: *InitrdBuildWorker) ?InitrdBuildJob {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
        defer self.mutex.unlock();
        for (&self.jobs) |*job| if (job.active) {
            const result = job.*;
            job.* = .{};
            return result;
        };
        return null;
    }
};

const IsoImportJob = struct {
    active: bool = false,
    operation_id: [boot_session.id_len]u8 = [_]u8{0} ** boot_session.id_len,
    filename: [iso_field_cap]u8 = [_]u8{0} ** iso_field_cap,
    filename_len: u16 = 0,
    original_filename: [iso_field_cap]u8 = [_]u8{0} ** iso_field_cap,
    original_filename_len: u16 = 0,
    name: [iso_id_cap]u8 = [_]u8{0} ** iso_id_cap,
    name_len: u16 = 0,
    qualifier: [iso_id_cap]u8 = [_]u8{0} ** iso_id_cap,
    qualifier_len: u16 = 0,
    distro: [iso_id_cap]u8 = [_]u8{0} ** iso_id_cap,
    distro_len: u16 = 0,
    version: [iso_id_cap]u8 = [_]u8{0} ** iso_id_cap,
    version_len: u16 = 0,
    arch: ?model.Arch = null,
};

/// v0.2.3 §7.3：ISO 导入 worker。队列容量为 1，保持"同一时刻最多一个 ISO
/// import"的既有语义（替代 handler 级 `iso_import_mutex`）；rootfs、initrd、
/// ISO 三类任务彼此并行，各自队列有固定容量。catalog/state 发布仍通过
/// model gate、catalog lock 和 operation-store mutex 串行化，不因 worker
/// 并行绕过。
const IsoImportWorker = struct {
    jobs: [1]IsoImportJob = [_]IsoImportJob{.{}} ** 1,
    mutex: std.atomic.Mutex = .unlocked,
    stop: std.atomic.Value(bool) = .init(false),

    fn submit(self: *IsoImportWorker, job: IsoImportJob) !void {
        if (job.operation_id.len != boot_session.id_len or job.filename_len == 0 or job.original_filename_len == 0)
            return error.InvalidIsoImportJob;
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
        defer self.mutex.unlock();
        for (&self.jobs) |*slot| if (!slot.active) {
            slot.* = job;
            slot.active = true;
            return;
        };
        return error.IsoImportQueueFull;
    }

    fn take(self: *IsoImportWorker) ?IsoImportJob {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
        defer self.mutex.unlock();
        for (&self.jobs) |*slot| if (slot.active) {
            const result = slot.*;
            slot.* = .{};
            return result;
        };
        return null;
    }
};

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
    rootfs_worker: *RootfsBuildWorker,
    initrd_worker: *InitrdBuildWorker,
    iso_worker: *IsoImportWorker,
    rootfs_artifacts: *rootfs_artifact_store.Store,
    diskless_store: *diskless_delivery.Store,
    identities: *identity_store.Store,
    /// v0.3: install-post journal store。记录 install-post 步骤执行状态。
    install_post_journal: *install_post_journal.Store,
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
var config_mutation_mutex: std.atomic.Mutex = .unlocked;
/// operation store 允许多个执行路径并发更新内存，但磁盘快照的 atomicWrite
/// 仍需串行化；否则 ISO handler 与 rootfs worker 可交错 rename 同一状态文件。
var operation_persist_mutex: std.atomic.Mutex = .unlocked;

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
    rootfs_artifacts: *rootfs_artifact_store.Store,
    diskless_store: *diskless_delivery.Store,
    identities: *identity_store.Store,
    install_post_journal_store: *install_post_journal.Store,
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

    var rootfs_worker: RootfsBuildWorker = .{};
    var initrd_worker: InitrdBuildWorker = .{};
    var iso_worker: IsoImportWorker = .{};
    // v0.2.3 §7.4：daemon 启动时清理上次崩溃遗留的 ISO import 工作树。
    // 工作树按 operation id 命名（`work/iso-import-<id>`）；queued/running
    // operation 已在 operations.load 中确定性转为 failed + interrupted，
    // 孤儿目录不再有对应执行者，直接删除。
    iso_import.cleanupOrphanStaging(io, allocator);
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
        .rootfs_worker = &rootfs_worker,
        .initrd_worker = &initrd_worker,
        .iso_worker = &iso_worker,
        .rootfs_artifacts = rootfs_artifacts,
        .diskless_store = diskless_store,
        .identities = identities,
        .install_post_journal = install_post_journal_store,
        .config_revision = config_revision,
        .bootstrap_key = bootstrap_key,
        .additional_keys = additional_keys,
        .daemon_instance_id = daemon_instance_id,
        .status_io_mutex = status_io_mutex,
        .node_status_path = node_status_path,
        .config_path = config_path,
    };
    var rootfs_thread = try std.Thread.spawn(.{}, runRootfsBuildWorker, .{ &context, &rootfs_worker });
    var initrd_thread = try std.Thread.spawn(.{}, runInitrdBuildWorker, .{ &context, &initrd_worker });
    var iso_thread = try std.Thread.spawn(.{}, runIsoImportWorker, .{ &context, &iso_worker });
    defer {
        rootfs_worker.stop.store(true, .release);
        initrd_worker.stop.store(true, .release);
        iso_worker.stop.store(true, .release);
        rootfs_thread.join();
        initrd_thread.join();
        iso_thread.join();
    }
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

    // M4.5 请求契约：每个非空 JSON API body 必须声明其
    // 媒体类型。Subiquity 的 curtin webhook 是安装器协议
    // 规定的唯一 form-urlencoded 例外。
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
            if (std.mem.eql(u8, node_route.suffix, "/rootfs")) return disklessRootfs(request, context, node_route.node_id, meta);
            if (std.mem.eql(u8, node_route.suffix, "/install-config/kickstart")) return installConfig(request, context, node_route.node_id, .kickstart, meta);
            if (std.mem.eql(u8, node_route.suffix, "/install-config/nocloud/user-data")) return installConfig(request, context, node_route.node_id, .user_data, meta);
            if (std.mem.eql(u8, node_route.suffix, "/install-config/nocloud/meta-data")) return installConfig(request, context, node_route.node_id, .meta_data, meta);
            if (std.mem.eql(u8, node_route.suffix, "/install-config/nocloud/vendor-data")) return installConfig(request, context, node_route.node_id, .vendor_data, meta);
        };
        // v0.2: diskless boot-session 交付路由（agent-plan / payload）。
        if (std.mem.startsWith(u8, path, "/api/v1/boot-sessions/")) if (splitBootSessionRoute(path["/api/v1/boot-sessions/".len..])) |bs| {
            if (bs.kind == .agent_plan) return disklessAgentPlan(request, context, bs.session, bs.digest, meta);
            if (bs.kind == .payload) return disklessPayload(request, context, bs.session, bs.tail, meta);
        };
        // ── 静态制品路由 ──────────────────────────────────────
        if (assetRoute(path, "/artifacts/images/")) |name| return imageAsset(request, context, name, meta);
        if (managedFileRoute(path)) |managed| return managedFileAsset(request, context, managed.name, managed.revision, meta);
        if (revisionedAssetRoute(path, "/artifacts/archives/")) |rev| return revisionedAsset(request, context, rev.name, rev.revision, .archive, meta);
        if (revisionedAssetRoute(path, "/artifacts/scripts/")) |rev| return revisionedAsset(request, context, rev.name, rev.revision, .script, meta);
        if (artifactRepoRoute(path)) |repo| return repositoryAsset(request, context, repo.name, repo.tail, meta);
        if (artifactBootRoute(path)) |relative| return bootFile(request, context, relative, meta);
    }
    if (std.mem.eql(u8, method, "POST")) {
        if (agentConsumedSession(path)) |session_id| return disklessAgentConsumed(request, context, session_id, meta);
        if (std.mem.startsWith(u8, path, "/api/v1/nodes/")) if (splitNodeRoute(path["/api/v1/nodes/".len..])) |node_route| {
            if (std.mem.eql(u8, node_route.suffix, "/events")) {
                if (request.getHeader("x-nodeforge-session")) |session_id|
                    if (context.diskless_store.find(session_id) != null)
                        return disklessEvent(request, context, node_route.node_id, meta);
                return nodeEvent(request, context, node_route.node_id, meta);
            }
            if (std.mem.eql(u8, node_route.suffix, "/logs")) return nodeLog(request, context, node_route.node_id, meta);
            if (std.mem.eql(u8, node_route.suffix, "/facts")) {
                if (request.getHeader("x-nodeforge-session")) |session_id|
                    if (context.diskless_store.find(session_id) != null)
                        return disklessFacts(request, context, node_route.node_id, meta);
                return nodeFacts(request, context, node_route.node_id, meta);
            }
            if (std.mem.eql(u8, node_route.suffix, "/installer-hooks/subiquity")) return subiquityReport(request, context, node_route.node_id, meta);
        };
    }

    // ── 本机管理 API ──────────────────────────────────────────
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/status")) {
        return managementStatus(request, context, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/diskless-sessions"))
        return managementDisklessSessions(request, context, meta);
    if (logicalPath(path, "/api/v1/management/diskless-sessions/")) |session_id| {
        if (std.mem.eql(u8, method, "GET")) return managementDisklessSession(request, context, session_id, meta);
        if (std.mem.eql(u8, method, "DELETE")) return managementDisklessSessionCancel(request, context, session_id, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/config")) {
        return managementConfigGet(request, context, meta);
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/config/validations")) {
        const catalog_snapshot = context.catalog_snapshot;
        config_validate.validate(context.config, catalog_snapshot.value()) catch |err| return validationError(request, err, meta);
        return json(request, .ok, "{\"ok\":true,\"result\":{}}\n", meta);
    }
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/initrds/build")) return managementInitrdBuild(request, context, meta);
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/nodes")) return managementNodeAdd(request, context, meta);
    if (std.mem.eql(u8, method, "POST")) if (claimPath(path)) |node_id| return managementNodeClaim(request, context, node_id, meta);
    if (nodePath(path, "/api/v1/management/nodes/")) |node_id| {
        if (std.mem.eql(u8, method, "DELETE")) return managementNodeRemove(request, context, node_id, meta);
    }
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/values")) |name| return managementValuesMutation(request, context, .profile, name, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/values")) |name| return managementValuesGet(request, context, .profile, name, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/items")) |name| return managementItemMutation(request, context, .profile, name, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/items")) |name| return managementItemsGet(request, context, .profile, name, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/capabilities")) |name| return managementCapabilities(request, context, .profile, name, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/properties")) |name| return managementScalarMutation(request, context, .profile, name, meta);
    if (std.mem.eql(u8, method, "POST")) if (installGenerationsPath(path)) |node_id| return installGenerations(request, context, node_id, meta);
    if (std.mem.eql(u8, method, "GET")) if (installPostJournalPath(path)) |node_id| return managementInstallPostJournal(request, context, node_id, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/nodes/", "/boot-prepare")) |node_id| return managementBootPrepare(request, context, node_id, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/nodes/", "/readiness")) |node_id| return managementNodeReadiness(request, context, node_id, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/nodes/", "/boot-preview")) |node_id| return managementNodeBootPreview(request, context, node_id, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/nodes/", "/retry")) |node_id| return managementNodeRetry(request, context, node_id, meta);
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/runtime")) {
        return runtimeSummary(request, context, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/nodes")) return managementNodes(request, context, meta);
    if (std.mem.eql(u8, method, "GET")) if (nodePath(path, "/api/v1/management/nodes/")) |node_id| return managementNode(request, context, node_id, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/nodes/", "/values")) |node_id| return managementValuesMutation(request, context, .node, node_id, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/nodes/", "/values")) |node_id| return managementValuesGet(request, context, .node, node_id, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/nodes/", "/items")) |node_id| return managementItemMutation(request, context, .node, node_id, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/nodes/", "/items")) |node_id| return managementItemsGet(request, context, .node, node_id, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/nodes/", "/capabilities")) |node_id| return managementCapabilities(request, context, .node, node_id, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/nodes/", "/properties")) |node_id| return managementScalarMutation(request, context, .node, node_id, meta);
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/profiles")) return managementProfiles(request, context, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/software/available")) |name| return managementProfileSoftware(request, context, name, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/rootfs/plan")) |name| return managementRootfsPlan(request, context, name, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/rootfs/register")) |name| return managementRootfsRegister(request, context, name, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/rootfs/build")) |name| return managementRootfsBuild(request, context, name, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/rootfs")) |name| return managementRootfsStatus(request, context, name, meta);
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/profiles")) return managementProfileCreate(request, context, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/profiles/", "/clone")) |name| return managementProfileClone(request, context, name, meta);
    if (std.mem.eql(u8, method, "DELETE")) if (logicalPath(path, "/api/v1/management/profiles/")) |name| return managementProfileRemove(request, context, name, meta);
    if (std.mem.eql(u8, method, "GET")) if (logicalPath(path, "/api/v1/management/profiles/")) |name| return managementProfile(request, context, name, meta);
    if (std.mem.eql(u8, path, "/api/v1/management/discovery/policy")) {
        if (std.mem.eql(u8, method, "GET")) return managementDiscoveryPolicy(request, context, meta);
        if (std.mem.eql(u8, method, "PATCH")) return managementDiscoveryPolicySet(request, context, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/discovery/observations")) return managementDiscoveryObservations(request, context, meta);
    if (std.mem.eql(u8, method, "GET")) if (logicalPath(path, "/api/v1/management/discovery/observations/")) |mac| return managementDiscoveryObservation(request, context, mac, meta);
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
    // v0.2 boot-bundle 管理 API：diskless profile 引用的 kernel/initrd 组合。
    // POST /api/v1/management/boot-bundles — 创建 boot bundle（校验资产类型匹配后原子写入 catalog）
    // GET  /api/v1/management/boot-bundles — 列出所有 boot bundles
    // 这是 diskless 全流程 CLI 的关键环节，使操作员无需手动编辑 catalog JSON。
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/boot-bundles")) return managementBootBundleCreate(request, context, meta);
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/boot-bundles")) return managementBootBundles(request, context, meta);
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/assets/provision-bundles")) return managementProvisionBundles(request, context, meta);
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/assets/provision-bundles")) return managementProvisionBundleCreate(request, context, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/assets/provision-bundles/", "/items")) |name| return managementProvisionBundleItems(request, context, name, meta);
    if (std.mem.eql(u8, method, "POST")) if (resourceWithSuffix(path, "/api/v1/management/assets/provision-bundles/", "/items")) |name| return managementProvisionBundleItemMutation(request, context, name, meta);
    if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "DELETE")) if (logicalPath(path, "/api/v1/management/assets/provision-bundles/")) |name| return if (std.mem.eql(u8, method, "GET")) managementProvisionBundle(request, context, name, meta) else managementProvisionBundleRemove(request, context, name, meta);
    if (std.mem.eql(u8, method, "DELETE")) if (logicalPath(path, "/api/v1/management/assets/managed-files/")) |name| return managementManagedFileRemove(request, context, name, meta);
    if (std.mem.eql(u8, method, "GET")) if (logicalPath(path, "/api/v1/management/assets/")) |name| return managementAsset(request, context, name, meta);
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, path, "/api/v1/management/install-sources")) {
        return importInstallSource(request, context, meta);
    }
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/install-sources")) return managementInstallSources(request, context, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/install-sources/", "/software")) |name| return managementInstallSourceSoftware(request, context, name, meta);
    if (std.mem.eql(u8, method, "GET")) if (logicalPath(path, "/api/v1/management/install-sources/")) |name| return managementInstallSource(request, context, name, meta);
    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/api/v1/management/repositories")) return managementRepositories(request, context, meta);
    if (std.mem.eql(u8, method, "GET")) if (resourceWithSuffix(path, "/api/v1/management/repositories/", "/software")) |name| return managementRepositorySoftware(request, context, name, meta);
    if (std.mem.eql(u8, method, "GET")) if (logicalPath(path, "/api/v1/management/repositories/")) |name| return managementRepository(request, context, name, meta);
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

fn resourceWithSuffix(path: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const value = path[prefix.len .. path.len - suffix.len];
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

const BootSessionKind = enum { agent_plan, payload };

const BootSessionRoute = struct {
    session: []const u8,
    kind: BootSessionKind,
    digest: []const u8 = "",
    tail: []const u8 = "",
};

/// v0.2: 解析 `/api/v1/boot-sessions/<session>/<kind>/<rest>` 路由。
/// session 必须是 32 hex 字符（diskless_delivery.id_len）。
fn splitBootSessionRoute(tail: []const u8) ?BootSessionRoute {
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return null;
    const session = tail[0..slash];
    if (session.len != diskless_delivery.id_len) return null;
    for (session) |c| if (!std.ascii.isHex(c)) return null;
    const rest = tail[slash + 1 ..];
    if (std.mem.startsWith(u8, rest, "agent-plan/")) {
        const digest = rest["agent-plan/".len..];
        if (digest.len == 0 or std.mem.indexOfScalar(u8, digest, '/') != null) return null;
        return .{ .session = session, .kind = .agent_plan, .digest = digest };
    }
    if (std.mem.startsWith(u8, rest, "payload/")) {
        const file_path = rest["payload/".len..];
        if (file_path.len == 0) return null;
        return .{ .session = session, .kind = .payload, .tail = file_path };
    }
    return null;
}

fn agentConsumedSession(path: []const u8) ?[]const u8 {
    const prefix = "/api/v1/boot-sessions/";
    const suffix = "/agent-consumed";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const session = path[prefix.len .. path.len - suffix.len];
    if (session.len != diskless_delivery.id_len) return null;
    for (session) |byte| if (!std.ascii.isHex(byte)) return null;
    return session;
}

/// v0.2: 从 `Authorization: Bearer <token>` 提取 raw token。
fn parseBearer(header: ?[]const u8) ?[]const u8 {
    const value = header orelse return null;
    if (!std.mem.startsWith(u8, value, "Bearer ")) return null;
    const token = value["Bearer ".len..];
    if (token.len == 0) return null;
    return token;
}

fn passwordSalt(plan_digest: []const u8, account: []const u8) [16]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("nodeforge-diskless-password-v1\x00");
    hasher.update(plan_digest);
    hasher.update("\x00");
    hasher.update(account);
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    var encoded: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&encoded, "{x}", .{raw}) catch unreachable;
    return encoded[0..16].*;
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

const ManagedFileRoute = struct { name: []const u8, revision: u64 };
fn managedFileRoute(path: []const u8) ?ManagedFileRoute {
    const prefix = "/artifacts/managed-files/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const name = rest[0..slash];
    if (!@import("../config/validate.zig").validLogicalId(name)) return null;
    const revision = std.fmt.parseInt(u64, rest[slash + 1 ..], 10) catch return null;
    if (revision == 0) return null;
    return .{ .name = name, .revision = revision };
}

test "managed-file artifact path requires canonical name and positive revision" {
    const parsed = managedFileRoute("/artifacts/managed-files/site-motd/3").?;
    try std.testing.expectEqualStrings("site-motd", parsed.name);
    try std.testing.expectEqual(@as(u64, 3), parsed.revision);
    try std.testing.expect(managedFileRoute("/artifacts/managed-files/../3") == null);
    try std.testing.expect(managedFileRoute("/artifacts/managed-files/site-motd/0") == null);
    try std.testing.expect(managedFileRoute("/artifacts/managed-files/site-motd/latest") == null);
}

fn managedFileAsset(request: zap.Request, context: *const RouteContext, name: []const u8, revision: u64, meta: RequestMeta) !void {
    const asset = lookup.findAsset(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    if (asset.kind != .managed_file or asset.revision != revision or asset.sha256 == null) return notFound(request, meta);
    return staticFile(request, context, paths.require().assets_dir, asset.path, asset.sha256, meta);
}

/// v0.3: `/artifacts/archives/{name}/{revision}` 和 `/artifacts/scripts/{name}/{revision}`
/// 路由解析。与 managedFileRoute 结构相同，但用于 archive 和 script 资产。
const RevisionedAssetRoute = struct { name: []const u8, revision: u64 };
fn revisionedAssetRoute(path: []const u8, prefix: []const u8) ?RevisionedAssetRoute {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const name = rest[0..slash];
    if (!@import("../config/validate.zig").validLogicalId(name)) return null;
    const revision = std.fmt.parseInt(u64, rest[slash + 1 ..], 10) catch return null;
    if (revision == 0) return null;
    return .{ .name = name, .revision = revision };
}

/// v0.3: 提供 archive/script 资产的 HTTP 下载。与 managedFileAsset 逻辑相同，
/// 但校验 asset.kind 与传入的 expected_kind 匹配。
fn revisionedAsset(request: zap.Request, context: *const RouteContext, name: []const u8, revision: u64, expected_kind: model.AssetKind, meta: RequestMeta) !void {
    const asset = lookup.findAsset(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    if (asset.kind != expected_kind or asset.revision != revision or asset.sha256 == null) return notFound(request, meta);
    return staticFile(request, context, paths.require().assets_dir, asset.path, asset.sha256, meta);
}

/// M4.2 F4：从 `tftp.asset_root` 提供启动文件（kernel/initrd）。
/// Catalog 白名单 + ETag checksum 支持条件请求和断点续传。
fn bootFile(request: zap.Request, context: *const RouteContext, relative: []const u8, meta: RequestMeta) !void {
    const asset_info = blk: {
        const catalog_snapshot = context.catalog_snapshot;
        const asset = lookup.findAssetByPath(catalog_snapshot.value(), relative) orelse return notFound(request, meta);
        break :blk .{ .path = asset.path, .checksum = asset.sha256, .root = if (asset.kind == .nodeforge_initrd) paths.require().initrd_dir else context.config.tftp.asset_root };
    };
    return staticFile(request, context, asset_info.root, asset_info.path, asset_info.checksum, meta);
}

fn repositoryAsset(request: zap.Request, context: *const RouteContext, name: []const u8, tail: []const u8, meta: RequestMeta) !void {
    const catalog_snapshot = context.catalog_snapshot;
    // URL 路径段 `name` 可能是两种 catalog 对象名：
    //
    // 1. Install source 名（如 `rocky-10.2-aarch64-dvd1`）：ISO 媒体树以 source_name
    //    为目录名整体复制到 `repository_root/source_name/`。所有 variant 的文件
    //    （AppStream/、BaseOS/ 等）都在此目录下。base_url 也使用 source_name
    //    作为路径前缀。Anaconda kickstart 的 `url --url=` 指向此路径。
    //
    // 2. Repository 名（如 `rocky-10.2-aarch64-dvd1-appstream`）：多 variant ISO
    //    的每个 variant 有独立的 RepositoryConfig，名含 variant 后缀。但文件
    //    仍存储在 source_name 目录下，通过 base_url 中的 variant 子路径区分。
    //
    // 因此 HTTP 路由必须同时接受 install source 名和 repository 名。如果两者
    // 都不存在则返回 404。文件系统路径始终使用 `name` 原值作为目录名——
    // install source 名和单 variant repository 名一致（向后兼容），多 variant
    // repository 名不会出现在 URL 中（其 base_url 已包含 source_name 前缀）。
    const repository = lookup.findRepository(catalog_snapshot.value(), name);
    if (repository == null and lookup.findInstallSource(catalog_snapshot.value(), name) == null)
        return artifactNotFound(request, context, tail, meta);
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
    var file = asset_validate.openRegularFile(context.io, root, relative) catch return artifactNotFound(request, context, relative, meta);
    errdefer file.close(context.io);
    const size = (try file.stat(context.io)).size;
    try request.setHeader("cache-control", "public, max-age=31536000, immutable");
    try request.setHeader("x-content-type-options", "nosniff");
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
            var etag: [132]u8 = undefined;
            try request.setHeader("etag", try std.fmt.bufPrint(&etag, "\"{s}\"", .{hash}));
        }
        try request.sendBody("");
        file.close(context.io);
        recordStaticCompletion("HEAD", request_path, context, relative, 200, 0, size, meta);
        return;
    }
    if (checksum) |hash| {
        var etag: [132]u8 = undefined;
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
        log.debug("{s} {s} -> {d} ({d} bytes, {d}us, client={s}, node={s}, asset={s}, object_bytes={d}, response_state={s})", .{ method, path, status, bytes_sent, duration_us, meta.client_ip, if (identity) |value| value.nodeId() else "-", relative, object_size, response_state })
    else
        log.info("{s} {s} -> {d} ({d} bytes, {d}us, client={s}, node={s}, asset={s}, object_bytes={d}, response_state={s})", .{ method, path, status, bytes_sent, duration_us, meta.client_ip, if (identity) |value| value.nodeId() else "-", relative, object_size, response_state });

    var status_text: [4]u8 = undefined;
    var bytes_text: [20]u8 = undefined;
    var object_bytes_text: [20]u8 = undefined;
    var duration_text: [20]u8 = undefined;
    // M4.3-06 §8.3：按请求路径前缀分类流量，写入审计事件。
    // M4.4: 静态制品路径从旧前缀切换到 /artifacts/** canonical URL。
    //   repository -> /artifacts/repositories/**（仓库制品）
    //   image      -> /artifacts/images/**（镜像制品）
    //   boot       -> /artifacts/boot/**（启动制品）
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
        fields[count] = .{ .key = "node_id", .value = value.nodeId() };
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
    // v0.2: diskless 节点走独立的 BootConfig v3 交付路径（capsule config-token 认证），
    // 不经过 DHCP-coupled boot_session 认证。
    {
        const catalog = context.catalog_snapshot.value();
        if (lookup.findNode(catalog, node_id)) |node| if (node.profile) |profile_name|
            if (lookup.findProfile(catalog, profile_name)) |profile| if (profile.kind == .diskless)
                return disklessBootConfig(request, context, node_id, meta);
    }
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
        if (!deployment_control.digestEqual(checked.session.model_plan_digest, desired_digest)) {
            logPlanDigestMismatch(node_id, checked.session, desired_revision, desired_digest, meta);
            return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_digest_mismatch\",\"message\":\"PXE session and current install-plan digests differ; inspect the correlated warning and retry\"}}\n", meta);
        }
        const plan_json = buildInstallPlan(context, node_id, checked.session.profileName(), desired_revision, desired_digest) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_invalid\",\"message\":\"cannot compile immutable install plan\"}}\n", meta);
        defer context.allocator.free(plan_json);
        if (!try captureImmutableInstallPlan(request, context, node_id, checked.session, plan_json, desired_revision, meta)) return;
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
        .{ .key = "profile", .value = session.profileName() },
    };
    context.event_writer.appendWithFields(context.io, context.allocator, paths.require().events_path, "boot.config.fetched", "authenticated boot config issued", &fields) catch |err| {
        observe_log.err("boot config event append failed: {t}", .{err});
        return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"events.unavailable\",\"message\":\"event writer unavailable\"}}\n", meta);
    };

    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    // M4.4 canonical URL：boot-config 取代 config。
    const base = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}", .{ context.config.server.server_ip, context.config.server.http_port });
    defer context.allocator.free(base);
    const config_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/boot-config", .{ base, node_id });
    defer context.allocator.free(config_url);
    const event_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/events", .{ base, node_id });
    defer context.allocator.free(event_url);
    try output.writer.print("{{\"schema_version\":1,\"node_id\":{f},\"boot_session_id\":{f},\"profile\":{f},\"mode\":{f},\"config_url\":{f},\"event_url\":{f}", .{
        std.json.fmt(node_id, .{}),    std.json.fmt(session.boot_session_id[0..], .{}), std.json.fmt(session.profileName(), .{}), std.json.fmt(@tagName(session.mode), .{}),
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
        // `bootConfig()` 入口已在上方把 diskless session 分派给
        // `disklessBootConfig()`。保留本分支作为防御性不变量：旧 install
        // BootSession 处理器绝不能意外签发 diskless capability。
        .diskless => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"diskless.not_implemented\",\"message\":\"diskless boot-config delivery is not yet available\"}}\n", meta),
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
    catalog_repositories: []const InstallPlanRepository,
    provisioning_bundles: []const model.ProvisioningBundle,
    delivery: struct { server_ip: []const u8, http_port: u16 },
};
const InstallPlanRepository = struct {
    name: []const u8,
    distro: []const u8,
    version: []const u8,
    arch: model.Arch,
    manager: model.PackageManager,
    base_url: []const u8,
    gpg_check: bool,
    gpg_key: ?[]const u8,
    software_index_revision: ?[]const u8,
    software_index_blob: struct {
        digest: []const u8,
        bytes: u64,
    },
};
fn installConfig(request: zap.Request, context: *const RouteContext, node_id: []const u8, format: AnswerFormat, meta: RequestMeta) !void {
    const checked = auth.authenticate(context.sessions, node_id, meta.client_ip, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.session.mode != .install) return nodeAuthError(request, error.ProofMismatch, meta);
    if (checked.proof == .bootstrap and checked.session.plan_digest == null) {
        const desired_revision = desiredRevision(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired model revision\"}}\n", meta);
        const desired_digest = desiredPlanDigest(context, node_id) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired node plan digest\"}}\n", meta);
        if (!deployment_control.digestEqual(checked.session.model_plan_digest, desired_digest)) {
            logPlanDigestMismatch(node_id, checked.session, desired_revision, desired_digest, meta);
            return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_digest_mismatch\",\"message\":\"PXE session and current install-plan digests differ; inspect the correlated warning and retry\"}}\n", meta);
        }
        const plan_json = buildInstallPlan(context, node_id, checked.session.profileName(), desired_revision, desired_digest) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_invalid\",\"message\":\"cannot compile immutable install plan\"}}\n", meta);
        defer context.allocator.free(plan_json);
        if (!try captureImmutableInstallPlan(request, context, node_id, checked.session, plan_json, desired_revision, meta)) return;
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
    var effective_plan = @import("../profile/effective.zig").compileInputs(context.allocator, node, profile, &plan.install_source) catch return error.MissingInstallConfig;
    defer effective_plan.deinit();
    const install = effective_plan.install;
    var system = effective_plan.system;
    // 服务端级额外 SSH 公钥属于目标系统 root SSH 策略，不进入 install alias。
    const merged_keys: []const []const u8 = if (context.additional_keys.len > 0) blk: {
        const combined = try context.allocator.alloc([]const u8, system.ssh.root_authorized_keys.len + context.additional_keys.len);
        @memcpy(combined[0..system.ssh.root_authorized_keys.len], system.ssh.root_authorized_keys);
        @memcpy(combined[system.ssh.root_authorized_keys.len..], context.additional_keys);
        break :blk combined;
    } else system.ssh.root_authorized_keys;
    defer if (context.additional_keys.len > 0) context.allocator.free(merged_keys);
    system.ssh.root_authorized_keys = merged_keys;
    const bundle = if (install.post_install.bundle) |name| findProvisioningBundleIn(plan.provisioning_bundles, name) else null;
    var password_scope_buffer: [96]u8 = undefined;
    // salt scope 必须能经受 daemon 重启。session id 是随机的，且
    // 捕获的模型 revision 对本次投递不可变；daemon 实例
    // 身份会让同一 checkpoint 渲染出不同的 password 哈希。
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
        .user_data => try @import("../profile/adapter/ubuntu.zig").renderEffective(context.allocator, node, install, system, effective_plan.network, effective_plan.software, context.bootstrap_key, bundle, apt_primary_url, facts_url, event_url, log_url, report_url, session.boot_session_id[0..], session.capability[0..], password_scope, effective_plan.kernel_args),
        .vendor_data => try context.allocator.dupe(u8, ""),
        .kickstart => blk: {
            const source = &plan.install_source;
            const install_root = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}/artifacts/repositories/{s}", .{ context.config.server.server_ip, context.config.server.http_port, source.name });
            defer context.allocator.free(install_root);
            const repository_urls = try installRepositoryUrls(context.allocator, plan.catalog_repositories, effective_plan.software.repositories, context.config.server.server_ip, context.config.server.http_port);
            defer {
                for (repository_urls) |url| context.allocator.free(url);
                context.allocator.free(repository_urls);
            }
            break :blk try @import("../profile/adapter/kickstart.zig").renderEffective(context.allocator, node, install, system, effective_plan.network, effective_plan.software, context.bootstrap_key, install_root, repository_urls, bundle, facts_url, event_url, log_url, session.boot_session_id[0..], session.capability[0..], password_scope, effective_plan.kernel_args);
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

/// 把 immutable install plan 中选中的受管仓库路径重新绑定到当前 daemon
/// authority。Catalog/plan 固定资源身份和子路径，但不能把导入时可能已过期的
/// server IP/port 持久化到新装目标系统。
fn installRepositoryUrls(allocator: std.mem.Allocator, repositories: []const InstallPlanRepository, names: []const []const u8, server_ip: []const u8, http_port: u16) ![]const []const u8 {
    const marker = "/artifacts/repositories/";
    const urls = try allocator.alloc([]const u8, names.len);
    var count: usize = 0;
    errdefer {
        for (urls[0..count]) |url| allocator.free(url);
        allocator.free(urls);
    }
    for (names) |name| {
        const repository = findRepositoryIn(repositories, name) orelse return error.MissingRepository;
        const marker_index = std.mem.indexOf(u8, repository.base_url, marker) orelse return error.ExternalEndpointForbidden;
        urls[count] = try std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{ server_ip, http_port, repository.base_url[marker_index..] });
        count += 1;
    }
    return urls;
}

fn buildInstallPlan(context: *const RouteContext, node_id: []const u8, profile_name: []const u8, desired_revision: u64, desired_digest: deployment_control.Digest) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    const plan_allocator = arena.allocator();
    const node = lookup.findNode(context.catalog_snapshot.value(), node_id) orelse return error.MissingNode;
    const profile = lookup.findProfile(context.catalog_snapshot.value(), profile_name) orelse return error.MissingProfile;
    const catalog_snapshot = context.catalog_snapshot;
    const source = lookup.findInstallSource(catalog_snapshot.value(), profile.install_source) orelse return error.MissingInstallSource;
    const distro = lookup.findDistro(context.catalog_snapshot.value(), source.distro) orelse return error.MissingDistro;
    const kernel = lookup.findAsset(catalog_snapshot.value(), source.installer_kernel) orelse return error.MissingAsset;
    const initrd = lookup.findAsset(catalog_snapshot.value(), source.installer_initrd) orelse return error.MissingAsset;
    const repositories = try context.allocator.alloc(InstallPlanRepository, source.repositories.len);
    defer context.allocator.free(repositories);
    for (source.repositories, 0..) |name, index| {
        const repository = lookup.findRepository(catalog_snapshot.value(), name) orelse return error.MissingRepository;
        // 旧 catalog 也在首次生成计划时补建共享 blob；新 ISO 导入会提前发布，
        // 因而这里通常只进行确定性覆盖。完整 capabilities 不丢失、不复制进 session。
        const blob = try repository_index_blob.publish(context.io, context.allocator, paths.require().repository_indexes_dir, repository.software_index);
        repositories[index] = .{
            .name = repository.name,
            .distro = repository.distro,
            .version = repository.version,
            .arch = repository.arch,
            .manager = repository.manager,
            .base_url = repository.base_url,
            .gpg_check = repository.gpg_check,
            .gpg_key = repository.gpg_key,
            .software_index_revision = repository.software_index.revision_digest,
            .software_index_blob = .{ .digest = try plan_allocator.dupe(u8, &blob.digest), .bytes = blob.bytes },
        };
    }
    const bundle_count: usize = if (profile.install.post_install.bundle) |_| 1 else 0;
    const bundles = try plan_allocator.alloc(model.ProvisioningBundle, bundle_count);
    if (profile.install.post_install.bundle) |name| {
        var found: ?model.ProvisioningBundle = null;
        for (catalog_snapshot.value().provisioning_bundles) |bundle| if (std.mem.eql(u8, bundle.name, name)) {
            found = bundle;
            break;
        };
        const source_bundle = found orelse return error.MissingProvisioningBundle;
        const steps = try plan_allocator.alloc(model.ProvisionStep, source_bundle.steps.len);
        for (source_bundle.steps, 0..) |step, index| {
            // v0.3: install-post 接受四类 canonical action（managed_file/archive/
            // script/package），旧 repository/standard_packages 直接拒绝。
            switch (step.action) {
                .managed_file => {
                    const asset = lookup.findAsset(catalog_snapshot.value(), step.content_asset orelse return error.InvalidProvisioningStep) orelse return error.MissingAsset;
                    if (asset.kind != .managed_file or asset.sha256 == null) return error.InvalidProvisioningStep;
                    steps[index] = step;
                    steps[index].content_url = try std.fmt.allocPrint(plan_allocator, "http://{s}:{d}/artifacts/managed-files/{s}/{d}", .{ context.config.server.server_ip, context.config.server.http_port, asset.name, asset.revision });
                    steps[index].content_sha256 = asset.sha256;
                },
                .archive => {
                    const asset = lookup.findAsset(catalog_snapshot.value(), step.content_asset orelse return error.InvalidProvisioningStep) orelse return error.MissingAsset;
                    if (asset.kind != .archive or asset.sha256 == null) return error.InvalidProvisioningStep;
                    steps[index] = step;
                    steps[index].content_url = try std.fmt.allocPrint(plan_allocator, "http://{s}:{d}/artifacts/archives/{s}/{d}", .{ context.config.server.server_ip, context.config.server.http_port, asset.name, asset.revision });
                    steps[index].content_sha256 = asset.sha256;
                },
                .script => {
                    const asset = lookup.findAsset(catalog_snapshot.value(), step.content_asset orelse return error.InvalidProvisioningStep) orelse return error.MissingAsset;
                    if (asset.kind != .script or asset.sha256 == null) return error.InvalidProvisioningStep;
                    steps[index] = step;
                    steps[index].content_url = try std.fmt.allocPrint(plan_allocator, "http://{s}:{d}/artifacts/scripts/{s}/{d}", .{ context.config.server.server_ip, context.config.server.http_port, asset.name, asset.revision });
                    steps[index].content_sha256 = asset.sha256;
                },
                .package => {
                    // package action 不引用 asset，直接传递。
                    if (step.packages.len == 0) return error.InvalidProvisioningStep;
                    steps[index] = step;
                },
                .repository, .standard_packages => return error.InvalidProvisioningStep,
            }
        }
        bundles[0] = source_bundle;
        bundles[0].steps = steps;
    }
    const plan_json = try std.json.Stringify.valueAlloc(context.allocator, .{
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
    var shared_index_bytes: u64 = 0;
    for (repositories) |repository| shared_index_bytes += repository.software_index_blob.bytes;
    observe_log.debug(
        "install plan compiled: node={s} plan_bytes={d} repository_index_blobs={d} shared_index_bytes={d}",
        .{ node_id, plan_json.len, repositories.len, shared_index_bytes },
    );
    return plan_json;
}

fn captureImmutableInstallPlan(
    request: zap.Request,
    context: *const RouteContext,
    node_id: []const u8,
    session: boot_session.Authenticated,
    plan_json: []const u8,
    desired_revision: u64,
    meta: RequestMeta,
) !bool {
    const max_bytes = context.config.capacity.install_plan_max_bytes;
    context.sessions.captureInstallPlan(context.allocator, session.boot_session_id[0..], plan_json, desired_revision, max_bytes) catch |err| {
        switch (err) {
            error.InvalidInstallPlan => {
                observe_log.err(
                    "install plan snapshot rejected: node={s} request_id={s} plan_bytes={d} reason=invalid",
                    .{ node_id, meta.request_id[0..], plan_json.len },
                );
                try json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_invalid\",\"message\":\"generated install plan is invalid\"}}\n", meta);
            },
            error.InstallPlanTooLarge => {
                observe_log.err(
                    "install plan snapshot rejected: node={s} request_id={s} plan_bytes={d} limit_bytes={d} reason=configured_limit",
                    .{ node_id, meta.request_id[0..], plan_json.len, max_bytes.? },
                );
                try json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_too_large\",\"message\":\"generated install plan exceeds configured capacity.install_plan_max_bytes\"}}\n", meta);
            },
            error.InstallPlanChanged => {
                var candidate_digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(plan_json, &candidate_digest, .{});
                var existing_prefix: [12]u8 = "unavailable-".*;
                if (try context.sessions.copyInstallPlan(context.allocator, session.boot_session_id[0..])) |existing| {
                    defer context.allocator.free(existing);
                    var existing_digest: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(existing, &existing_digest, .{});
                    _ = std.fmt.bufPrint(&existing_prefix, "{x}", .{existing_digest[0..6]}) catch unreachable;
                }
                var candidate_prefix: [12]u8 = undefined;
                _ = std.fmt.bufPrint(&candidate_prefix, "{x}", .{candidate_digest[0..6]}) catch unreachable;
                observe_log.err(
                    "immutable install plan changed within session: node={s} request_id={s} session_revision={d} desired_revision={d} existing_sha256={s} candidate_sha256={s} candidate_bytes={d}",
                    .{ node_id, meta.request_id[0..], session.model_revision, desired_revision, &existing_prefix, &candidate_prefix, plan_json.len },
                );
                try json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.plan_snapshot_mismatch\",\"message\":\"immutable install plan changed within the active PXE session\"}}\n", meta);
            },
            error.OutOfMemory => {
                observe_log.err(
                    "install plan snapshot allocation failed: node={s} request_id={s} plan_bytes={d} error=OutOfMemory",
                    .{ node_id, meta.request_id[0..], plan_json.len },
                );
                try json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"install.plan_out_of_memory\",\"message\":\"insufficient memory to capture immutable install plan\"}}\n", meta);
            },
            error.SessionInactive => {
                observe_log.warn(
                    "install plan snapshot lost active session: node={s} request_id={s} plan_bytes={d}",
                    .{ node_id, meta.request_id[0..], plan_json.len },
                );
                try json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.session_inactive\",\"message\":\"boot session became inactive while capturing install plan\"}}\n", meta);
            },
        }
        return false;
    };
    observe_log.debug(
        "install plan snapshot captured: node={s} request_id={s} revision={d} plan_bytes={d}",
        .{ node_id, meta.request_id[0..], desired_revision, plan_json.len },
    );
    return true;
}

fn findRepositoryIn(repositories: []const InstallPlanRepository, name: []const u8) ?*const InstallPlanRepository {
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

fn installPostBundleForNode(config: *const model.Catalog, node_id: []const u8) ?*const model.ProvisioningBundle {
    const node = lookup.findNode(config, node_id) orelse return null;
    const profile = lookup.findProfile(config, node.profile orelse return null) orelse return null;
    if (profile.kind != .install) return null;
    return findProvisioningBundleIn(config.provisioning_bundles, profile.install.post_install.bundle orelse return null);
}

fn nodeEvent(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const checked = auth.authenticate(context.sessions, node_id, meta.client_ip, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.proof != .capability) return nodeAuthError(request, error.MissingProof, meta);
    if (!bodyWithin(request, 4 * 1024)) return json(request, .content_too_large, "{\"ok\":false,\"error\":{\"code\":\"http.body_too_large\",\"message\":\"node event body too large\"}}\n", meta);
    var event = parseNodeEvent(request, context.allocator) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_event\",\"message\":\"invalid node event\"}}\n", meta);
    defer event.params.deinit();
    @import("contracts.zig").validateNodeEvent(event.value) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_event\",\"message\":\"invalid node event\"}}\n", meta);
    if (!validInstallPostEventShape(event.value)) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_event\",\"message\":\"invalid install-post event fields\"}}\n", meta);
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
    // install-post 是 generation completion gate：只要配置了 bundle，installer 的
    // 粗粒度 `completed` 就不能单独关闭部署；必须先持久接受带认证 finalizer callback。
    if (checked.session.mode == .install and std.mem.eql(u8, event.value.stage, "completed")) {
        if (installPostBundleForNode(context.catalog_snapshot.value(), node_id) != null) {
            const run = context.install_post_journal.view(node_id, checked.session.deployment_generation) orelse
                return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_incomplete\",\"message\":\"install-post finalizer has not completed\"}}\n", meta);
            if (run.status != .completed)
                return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_incomplete\",\"message\":\"install-post finalizer has not completed\"}}\n", meta);
        }
    }
    if (checked.session.mode == .install and terminal) {
        const terminal_result = context.deployments.markTerminalAt(node_id, std.mem.eql(u8, event.value.stage, "completed"), unixNow());
        deployment_control.save(context.io, context.allocator, paths.require().deployment_control_path, context.deployments) catch |err| {
            if (terminal_result) |result| context.deployments.rollbackTerminal(node_id, result);
            observe_log.err("deployment-control applied revision save failed: {t}", .{err});
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot persist applied install revision\"}}\n", meta);
        };
    }
    // v0.3: install-post journal 状态机。
    // - installer `started` → 创建 pending run（复用已有 generation/plan）。
    // - installer `post` → 转为 running。
    // - installer `completed` → 转为 completed。
    // - installer `failed` → 转为 failed + 记录 failure reason。
    if (checked.session.mode == .install) {
        const gen = checked.session.deployment_generation;
        if (std.mem.eql(u8, event.value.stage, "started") and gen != 0) {
            const bundle_revision = if (installPostBundleForNode(context.catalog_snapshot.value(), node_id)) |bundle| bundle.revision else 0;
            const digest = if (deployment_control.digestSet(checked.session.model_plan_digest)) checked.session.model_plan_digest[0..] else "";
            _ = context.install_post_journal.findOrCreate(context.allocator, node_id, gen, bundle_revision, digest, checked.session.boot_session_id[0..], unixNow()) catch
                return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_binding_mismatch\",\"message\":\"install-post generation is already bound to different immutable facts\"}}\n", meta);
            install_post_journal.save(context.io, context.allocator, paths.require().install_post_journal_path, context.install_post_journal) catch |err|
                observe_log.err("install-post journal save failed: {t}", .{err});
        } else if (std.mem.eql(u8, event.value.stage, "post") or std.mem.eql(u8, event.value.stage, "post_step_started") or std.mem.eql(u8, event.value.stage, "post_finalizer_started")) {
            if (gen != 0) {
                _ = context.install_post_journal.transition(node_id, gen, .running, unixNow());
                if (std.mem.eql(u8, event.value.stage, "post_step_started")) {
                    const bundle = installPostBundleForNode(context.catalog_snapshot.value(), node_id) orelse
                        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_plan_mismatch\",\"message\":\"install-post bundle is not available\"}}\n", meta);
                    const run = context.install_post_journal.view(node_id, gen) orelse
                        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_run_missing\",\"message\":\"install-post run is not bound\"}}\n", meta);
                    if (!installPostStepIsCurrent(bundle, run, event.value.step_id.?))
                        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_step_out_of_order\",\"message\":\"install-post step is not the current planned step\"}}\n", meta);
                } else if (std.mem.eql(u8, event.value.stage, "post_finalizer_started")) {
                    const bundle = installPostBundleForNode(context.catalog_snapshot.value(), node_id) orelse
                        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_plan_mismatch\",\"message\":\"install-post bundle is not available\"}}\n", meta);
                    const run = context.install_post_journal.view(node_id, gen) orelse
                        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_run_missing\",\"message\":\"install-post run is not bound\"}}\n", meta);
                    if (!allInstallPostStepsSucceeded(bundle, run))
                        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_finalizer_early\",\"message\":\"install-post steps have not all succeeded\"}}\n", meta);
                }
                if (!std.mem.eql(u8, event.value.stage, "post"))
                    _ = context.install_post_journal.recordStepAttempt(context.allocator, node_id, gen, event.value.step_id orelse "", event.value.attempt orelse 0, .running, unixNow()) catch
                        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_event_rejected\",\"message\":\"invalid install-post step transition\"}}\n", meta);
            }
        } else if (std.mem.eql(u8, event.value.stage, "post_step_succeeded")) {
            if (gen != 0) _ = context.install_post_journal.recordStepAttempt(context.allocator, node_id, gen, event.value.step_id orelse "", event.value.attempt orelse 0, .succeeded, unixNow()) catch
                return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_event_rejected\",\"message\":\"invalid install-post step transition\"}}\n", meta);
        } else if (std.mem.eql(u8, event.value.stage, "post_step_failed_retryable")) {
            if (gen != 0) _ = context.install_post_journal.recordStepAttempt(context.allocator, node_id, gen, event.value.step_id orelse "", event.value.attempt orelse 0, .failed_retryable, unixNow()) catch
                return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_event_rejected\",\"message\":\"invalid install-post step transition\"}}\n", meta);
        } else if (std.mem.eql(u8, event.value.stage, "post_step_failed_terminal") or std.mem.eql(u8, event.value.stage, "post_finalizer_failed")) {
            if (gen != 0) {
                if (event.value.step_id) |step_id| _ = context.install_post_journal.recordStepAttempt(context.allocator, node_id, gen, step_id, event.value.attempt orelse 0, .failed_terminal, unixNow()) catch {};
                _ = context.install_post_journal.transition(node_id, gen, .failed, unixNow());
                install_post_journal.save(context.io, context.allocator, paths.require().install_post_journal_path, context.install_post_journal) catch |err|
                    observe_log.err("install-post journal save failed: {t}", .{err});
            }
        } else if (std.mem.eql(u8, event.value.stage, "post_finalizer_succeeded")) {
            if (gen != 0) {
                _ = context.install_post_journal.recordStepAttempt(context.allocator, node_id, gen, "@finalizer", event.value.attempt orelse 0, .succeeded, unixNow()) catch
                    return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_event_rejected\",\"message\":\"invalid install-post finalizer transition\"}}\n", meta);
                if (!context.install_post_journal.transition(node_id, gen, .committing, unixNow()))
                    return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_event_rejected\",\"message\":\"install-post run cannot enter completion transaction\"}}\n", meta);
                install_post_journal.save(context.io, context.allocator, paths.require().install_post_journal_path, context.install_post_journal) catch
                    return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_persist_failed\",\"message\":\"cannot prepare install-post completion\"}}\n", meta);
                const terminal_result = context.deployments.markTerminalAt(node_id, true, unixNow()) orelse
                    return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_generation_mismatch\",\"message\":\"install generation cannot be completed\"}}\n", meta);
                if (terminal_result.generation != gen) {
                    context.deployments.rollbackTerminal(node_id, terminal_result);
                    return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_generation_mismatch\",\"message\":\"install generation does not match finalizer run\"}}\n", meta);
                }
                deployment_control.save(context.io, context.allocator, paths.require().deployment_control_path, context.deployments) catch {
                    context.deployments.rollbackTerminal(node_id, terminal_result);
                    return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_persist_failed\",\"message\":\"cannot commit install generation\"}}\n", meta);
                };
                if (!context.install_post_journal.transition(node_id, gen, .completed, unixNow()))
                    return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_commit_failed\",\"message\":\"cannot publish completed install-post run\"}}\n", meta);
                install_post_journal.save(context.io, context.allocator, paths.require().install_post_journal_path, context.install_post_journal) catch {
                    _ = context.install_post_journal.rollbackCompletion(node_id, gen, unixNow());
                    return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_persist_failed\",\"message\":\"install completion requires recovery\"}}\n", meta);
                };
            }
        } else if (std.mem.eql(u8, event.value.stage, "failed")) {
            if (gen != 0) {
                _ = context.install_post_journal.transition(node_id, gen, .failed, unixNow());
                if (event.value.reason) |reason| context.install_post_journal.setFailureReason(context.allocator, node_id, gen, reason);
                install_post_journal.save(context.io, context.allocator, paths.require().install_post_journal_path, context.install_post_journal) catch |err|
                    observe_log.err("install-post journal save failed: {t}", .{err});
            }
        }
        if (std.mem.startsWith(u8, event.value.stage, "post_step_") or std.mem.startsWith(u8, event.value.stage, "post_finalizer_") or std.mem.eql(u8, event.value.stage, "post"))
            install_post_journal.save(context.io, context.allocator, paths.require().install_post_journal_path, context.install_post_journal) catch
                return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"install.postprocess_persist_failed\",\"message\":\"cannot persist install-post journal\"}}\n", meta);
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

fn validInstallPostEventShape(event: @import("contracts.zig").NodeEvent) bool {
    const post_callback = std.mem.startsWith(u8, event.stage, "post_step_") or std.mem.startsWith(u8, event.stage, "post_finalizer_");
    if (!post_callback) return event.step_id == null and event.attempt == null;
    const step_id = event.step_id orelse return false;
    _ = event.attempt orelse return false;
    if (std.mem.startsWith(u8, event.stage, "post_finalizer_")) return std.mem.eql(u8, step_id, "@finalizer");
    return !std.mem.eql(u8, step_id, "@finalizer");
}

fn installPostStepId(step: model.ProvisionStep) []const u8 {
    return if (step.idempotency_key.len != 0) step.idempotency_key else step.name;
}

fn journalStep(run: install_post_journal.Run, step_id: []const u8) ?install_post_journal.StepEntry {
    for (run.steps) |step| if (std.mem.eql(u8, step.step_id, step_id)) return step;
    return null;
}

fn installPostStepIsCurrent(bundle: *const model.ProvisioningBundle, run: install_post_journal.Run, requested: []const u8) bool {
    const order = [_]model.ProvisionAction{ .managed_file, .package, .archive, .script };
    for (order) |action| for (bundle.steps) |step| {
        if (step.phase != .install_post or step.action != action) continue;
        const id = installPostStepId(step);
        const existing = journalStep(run, id);
        if (existing == null or existing.?.status != .succeeded) return std.mem.eql(u8, id, requested);
    };
    return false;
}

fn allInstallPostStepsSucceeded(bundle: *const model.ProvisioningBundle, run: install_post_journal.Run) bool {
    for (bundle.steps) |step| {
        if (step.phase != .install_post) continue;
        const existing = journalStep(run, installPostStepId(step)) orelse return false;
        if (existing.status != .succeeded) return false;
    }
    return true;
}

fn nodeLog(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const checked = auth.authenticate(context.sessions, node_id, meta.client_ip, request.getHeader("authorization"), request.getHeader("x-nodeforge-session"), boot_session.monotonicNow()) catch |err| return nodeAuthError(request, err, meta);
    if (checked.proof != .capability) return nodeAuthError(request, error.MissingProof, meta);
    if (!bodyWithin(request, 4 * 1024)) return json(request, .content_too_large, "{\"ok\":false,\"error\":{\"code\":\"http.body_too_large\",\"message\":\"node log body too large\"}}\n", meta);
    var summary = parseLogSummary(request, context.allocator) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_log\",\"message\":\"invalid node log summary\"}}\n", meta);
    defer summary.params.deinit();
    @import("contracts.zig").validateLogSummary(summary.value) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid_log\",\"message\":\"invalid node log summary\"}}\n", meta);
    if (!std.mem.eql(u8, summary.value.boot_session_id, checked.session.boot_session_id[0..])) return nodeAuthError(request, error.ProofMismatch, meta);
    const event_type = "install.failed";
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
    normalizeFacts(&facts);
    _ = context.inventories.put(node_id, checked.session.boot_session_id[0..], checked.session.deployment_generation, checked.session.session_created_at, facts, unixNow()) catch |err| switch (err) {
        error.StaleSource => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"inventory.stale_source\",\"message\":\"facts came from a stale session\"}}\n", meta),
        else => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"inventory.invalid\",\"message\":\"facts rejected\"}}\n", meta),
    };
    node_inventory.save(context.io, context.allocator, paths.require().node_inventory_path, context.inventories) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"inventory.persist_failed\",\"message\":\"cannot persist facts\"}}\n", meta);
    context.sessions.touchDelivery(checked.session.boot_session_id[0..], boot_session.monotonicNow(), unixNow());
    return json(request, .ok, "{\"ok\":true}\n", meta);
}

fn normalizeFacts(facts: *node_inventory.Facts) void {
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
    if (facts.memory_bytes) |bytes| if (bytes == 0) {
        facts.memory_bytes = null;
    };
}

/// Diskless initrd 使用 event capability 上报硬件事实。event token 是四域
/// credential 中唯一的 telemetry 写域；facts 不推进 event_seq，因此 lifecycle
/// CAS 与 inventory 幂等摘要保持独立。
///
/// v0.2.3 起 initrd 同时上报 memory_bytes + DMI 字段（serial/uuid/vendor/
/// model），daemon 用 `putDiskless` 存储：合并 DMI（null 保留既有值）并保留
/// install generation 高水位，纯 diskless 节点也有 SN/UUID 等硬件信息且不会
/// 因 generation=0 触发 install 防回退 409。memory_bytes 是必需字段（内存闸
/// 依据），DMI 字段可选（某些固件/容器无 DMI 时为空）。
fn disklessFacts(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const token = parseBearer(request.getHeader("authorization")) orelse
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.token_required\",\"message\":\"event token is required\"}}\n", meta);
    const session_id = request.getHeader("x-nodeforge-session") orelse
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.session_required\",\"message\":\"session header is required\"}}\n", meta);
    const session = context.diskless_store.find(session_id) orelse return notFound(request, meta);
    if (!std.mem.eql(u8, session.nodeId(), node_id))
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.node_mismatch\",\"message\":\"session does not belong to this node\"}}\n", meta);
    const decision = context.diskless_store.verify(session_id, token, .event, node_id, "", "", session.event_token.event_seq, boot_session.monotonicNow());
    if (decision != .ok) {
        observe_log.warn("diskless facts credential rejected: node={s} session={s} decision={s}", .{ node_id, session_id, @tagName(decision) });
        return json(request, .unauthorized, disklessCredentialError(decision), meta);
    }
    if (!bodyWithin(request, 8 * 1024))
        return json(request, .content_too_large, "{\"ok\":false,\"error\":{\"code\":\"http.body_too_large\",\"message\":\"facts body too large\"}}\n", meta);
    const body = request.body orelse
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"inventory.invalid\",\"message\":\"missing facts body\"}}\n", meta);
    const FactsPayload = struct { memory_bytes: ?u64 = null, serial_number: ?[]const u8 = null, product_uuid: ?[]const u8 = null, vendor: ?[]const u8 = null, model: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(FactsPayload, context.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"inventory.invalid\",\"message\":\"invalid facts body\"}}\n", meta);
    defer parsed.deinit();
    // memory_bytes 是 diskless 启动的必需字段（内存闸依据），DMI 字段可选
    // （某些固件/容器无 DMI）。initrd 从 /sys/class/dmi/id/ 读取并和
    // memory_bytes 一起上报，daemon 用 putDiskless 合并 DMI 并保留 generation
    // 高水位，纯 diskless 节点也有 SN/UUID/vendor/model。
    if (parsed.value.memory_bytes == null or parsed.value.memory_bytes.? == 0)
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"inventory.invalid\",\"message\":\"memory_bytes is required for diskless facts\"}}\n", meta);
    var facts: node_inventory.Facts = .{
        .memory_bytes = parsed.value.memory_bytes,
        .serial_number = parsed.value.serial_number,
        .product_uuid = parsed.value.product_uuid,
        .vendor = parsed.value.vendor,
        .model = parsed.value.model,
    };
    normalizeFacts(&facts);
    _ = context.inventories.putDiskless(node_id, session_id, session.armed_at, facts, unixNow()) catch |err| switch (err) {
        error.StaleSource => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"inventory.stale_source\",\"message\":\"facts came from a stale session\"}}\n", meta),
        else => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"inventory.invalid\",\"message\":\"facts rejected\"}}\n", meta),
    };
    node_inventory.save(context.io, context.allocator, paths.require().node_inventory_path, context.inventories) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"inventory.persist_failed\",\"message\":\"cannot persist facts\"}}\n", meta);
    return json(request, .ok, "{\"ok\":true}\n", meta);
}

fn pinSessionGeneration(context: *const RouteContext, session: boot_session.Authenticated) !void {
    const generation: u64 = if (session.mode == .install) blk: {
        const deployment = context.deployments.view(session.nodeId()) orelse return error.DeploymentGenerationUnavailable;
        break :blk deployment.armed_generation orelse deployment.consumed_generation orelse deployment.terminal_generation orelse return error.DeploymentGenerationUnavailable;
    } else 0;
    try context.sessions.setDeploymentGeneration(session.boot_session_id[0..], generation);
}

fn logPlanDigestMismatch(node_id: []const u8, session: boot_session.Authenticated, desired_revision: u64, desired_digest: deployment_control.Digest, meta: RequestMeta) void {
    // “摘要不一致”不等价于“配置过时”：revision 不同才能证明模型在 PXE
    // 授权后变化；同 revision 不一致说明 HTTP/DHCP 使用了不同 runtime 输入或
    // snapshot，属于内部不变式异常。两者都拒绝继续，因为客户端可能已下载旧
    // kernel/initrd，直接生成当前 kickstart 会混用两个安装计划。
    const same_revision = session.model_revision == desired_revision;
    observe_log.warn(
        "install plan digest mismatch: node={s} request_id={s} session_revision={d} desired_revision={d} same_revision={s} session_digest={s} desired_digest={s}; {s}",
        .{
            node_id,
            meta.request_id[0..],
            session.model_revision,
            desired_revision,
            if (same_revision) "true" else "false",
            session.model_plan_digest[0..12],
            desired_digest[0..12],
            if (same_revision)
                "same-revision mismatch indicates inconsistent runtime inputs or snapshots; refusing mixed installer inputs"
            else
                "model changed after PXE authorization; re-arm the install generation",
        },
    );
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
    if (params.items.len < 3 or params.items.len > 7) return error.InvalidNodeEvent;
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
        } else if (std.mem.eql(u8, param.key, "step_id")) {
            if (result.step_id != null) return error.InvalidNodeEvent;
            result.step_id = stringParam(param.value) orelse return error.InvalidNodeEvent;
        } else if (std.mem.eql(u8, param.key, "attempt")) {
            if (result.attempt != null or param.value == null or param.value.? != .Int) return error.InvalidNodeEvent;
            result.attempt = std.math.cast(u8, param.value.?.Int) orelse return error.InvalidNodeEvent;
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
fn mapStage(mode: model.BootKind, stage: []const u8) ?StageMapping {
    if (mode == .install) {
        const values = [_]struct { []const u8, []const u8, node_status.Phase }{
            .{ "installer_started", "install.installer_started", .installer_started }, .{ "config_fetched", "install.config_fetched", .install_config_fetched }, .{ "started", "install.started", .install_started }, .{ "partitioning", "install.partitioning", .install_partitioning }, .{ "packages", "install.packages", .install_packages }, .{ "bootloader", "install.bootloader", .install_bootloader }, .{ "post", "install.post", .install_post }, .{ "post_step_started", "install.post_step_started", .install_post }, .{ "post_step_succeeded", "install.post_step_succeeded", .install_post }, .{ "post_step_failed_retryable", "install.post_step_failed_retryable", .install_post }, .{ "post_step_failed_terminal", "install.post_step_failed_terminal", .install_post }, .{ "post_finalizer_started", "install.post_finalizer_started", .install_post }, .{ "post_finalizer_succeeded", "install.post_finalizer_succeeded", .install_post }, .{ "post_finalizer_failed", "install.post_finalizer_failed", .install_post }, .{ "rebooting", "install.rebooting", .install_rebooting }, .{ "completed", "install.completed", .completed }, .{ "failed", "install.failed", .failed },
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
    // 自旋等待 status I/O mutex；序列化磁盘写入，避免并发 HTTP 线程交错。
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

/// 解析 `?force=true` 查询参数，用于属性变更的强制模式。
///
/// 当操作员使用 `node set --force` 等 CLI 命令时，客户端会在请求 URL
/// 上附加 `?force=true`。此函数从 zap 请求中提取该参数并返回是否启用
/// 强制模式。任何非 `"true"` 的值（包括缺省）均视为 false。
fn parseForceFlag(request: zap.Request) bool {
    const raw = request.getParamSlice("force") orelse return false;
    return std.mem.eql(u8, raw, "true");
}

/// 强制终止目标节点的所有活动 session（`boot_session.Store` + `diskless_delivery.Store`）。
///
/// 当操作员使用 `--force` 标志执行属性变更时，此函数确保目标节点的活动
/// session 被终止，使属性变更可以安全进行。这适用于以下场景：
///
/// 1. **install 模式**：节点正在 PXE 安装过程中，操作员需要修改属性。
///    `supersedeNode` 会终止 `boot_session.Store` 中的 install session，
///    终态原因为 `superseded`（与 `node retry --force` 语义一致）。
///
/// 2. **diskless 模式**：节点正在 diskless 启动过程中（尚未到达终态），
///    操作员需要修改属性。`supersedeNode` 终止 `boot_session.Store` 中的
///    DHCP session；同时 `diskless_store.cancel` 终止 `diskless_delivery.Store`
///    中的交付 session（撤销全部 capability 并从 checkpoint 中移除）。
///
/// **安全保证**：
/// - install plan 在 PXE bootstrap 时已固定为不可变快照，终止 session 不会
///   影响正在运行的 installer（它已获取所需的 kickstart/answer 文件）。
/// - diskless AgentPlan 在 boot-config 首次签发时已固定为不可变快照，终止
///   delivery session 不会影响正在运行的 diskless 节点（它已获取 rootfs
///   和 agent plan）。
/// - `supersedeNode` 和 `diskless_store.cancel` 均在同一调用中完成持久化，
///   保证 daemon 重启后不会从 checkpoint 复活已终止的 session。
/// - 持久化失败时返回 false，调用方应返回 503 错误。
///
/// 返回 true 表示所有 session 已成功终止并持久化。
fn forceTerminateNodeSessions(context: *RouteContext, node_id: []const u8) bool {
    const mono_now = boot_session.monotonicNow();
    const utc_now = unixNow();

    // 1. 终止 boot_session.Store 中该节点的所有活动 session。
    //    这包括 install 模式的 PXE session 和 diskless 模式的 DHCP session。
    //    后者由 DHCP server 在 PXE DISCOVER 时创建，用于 DHCP/TFTP 阶段的
    //    节点身份关联和 capability 认证。
    _ = context.sessions.supersedeNode(node_id, mono_now, utc_now);
    if (!checkpointSessions(context)) return false;

    // 2. 终止 diskless_delivery.Store 中该节点的活动交付 session。
    //    `cancel` 会撤销全部 capability（config/rootfs/agent/event token），
    //    并从持久化 checkpoint 中移除该 session。如果节点没有 diskless
    //    session（例如 install 模式节点），此步骤为 no-op。
    if (context.diskless_store.findByNode(node_id)) |session| {
        context.diskless_store.cancel(context.io, session.session_id[0..]) catch return false;
    }

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
    const AssetRequest = struct { name: []const u8, kind: model.AssetKind, path: []const u8, distro: ?[]const u8 = null, version: ?[]const u8 = null, arch: ?model.Arch = null, kernel_release: ?[]const u8 = null, revision: u64 = 1, size: ?u64 = null, media_type: ?[]const u8 = null };
    const body = request.body orelse return assetInputError(request, "missing body", meta);
    const parsed = std.json.parseFromSlice(AssetRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch return assetInputError(request, "invalid JSON body", meta);
    defer parsed.deinit();
    const value = parsed.value;
    const has_tuple = value.distro != null or value.version != null or value.arch != null;
    if (has_tuple and (value.distro == null or value.version == null or value.arch == null)) return assetInputError(request, "incomplete distro tuple", meta);
    var checksum: [64]u8 = undefined;
    const root = switch (value.kind) {
        .managed_file => paths.require().assets_dir,
        .iso => context.config.http.asset_root,
        .bootloader, .kernel, .installer_initrd => context.config.tftp.asset_root,
        .gpg_key => paths.require().keys_dir,
        .nodeforge_initrd => paths.require().initrd_dir,
        .rootfs => paths.require().rootfs_dir,
        .runtime_kernel => context.config.tftp.asset_root,
        .archive, .script => paths.require().assets_dir,
    };
    @import("../assets/validate.zig").sha256File(context.io, root, value.path, &checksum) catch |err| {
        observe_log.err("asset: import failed for {s}: {t}", .{ value.path, err });
        return assetInputError(request, "unreadable asset", meta);
    };
    const revisioned_content = value.kind == .managed_file or value.kind == .archive or value.kind == .script;
    if (lookup.findAsset(context.catalog_snapshot.value(), value.name)) |existing| if (!revisioned_content) {
        const same = existing.kind == value.kind and std.mem.eql(u8, existing.path, value.path) and optionalEqual(existing.distro, value.distro) and optionalEqual(existing.version, value.version) and existing.arch == value.arch and optionalEqual(existing.kernel_release, value.kernel_release) and optionalEqual(existing.sha256, &checksum);
        if (!same) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"asset.name_conflict\",\"message\":\"asset name already identifies different canonical metadata\"}}\n", meta);
        var reused: [384]u8 = undefined;
        const response = try std.fmt.bufPrint(&reused, "{{\"ok\":true,\"result\":{{\"name\":{f},\"kind\":{f},\"sha256\":{f}}}}}\n", .{ std.json.fmt(existing.name, .{}), std.json.fmt(@tagName(existing.kind), .{}), std.json.fmt(existing.sha256.?, .{}) });
        return json(request, .ok, response, meta);
    };
    if (revisioned_content and (value.revision == 0 or value.size == null or value.media_type == null)) return assetInputError(request, "content asset metadata incomplete", meta);
    context.models.lock();
    defer context.models.unlock();
    const asset: model.AssetConfig = .{
        .name = value.name,
        .kind = value.kind,
        .path = value.path,
        .distro = value.distro,
        .version = value.version,
        .arch = value.arch,
        .kernel_release = value.kernel_release,
        .sha256 = &checksum,
        .revision = value.revision,
        .size = value.size,
        .media_type = value.media_type,
    };
    if (revisioned_content) context.catalog.publishContentAsset(context.io, context.config, asset) catch |err| return assetInputError(request, @errorName(err), meta) else context.catalog.addAsset(context.io, context.config, asset) catch |err| return assetInputError(request, @errorName(err), meta);
    // 资产发布改变了 catalog 世代，因此也改变了
    // 投影出的 AppConfig 世代。在已持有的 model gate 下重新发布该配对；
    // 若仅推进 CatalogRuntime，则下一次 profile/bundle 变更会
    // 从陈旧的配对快照开始，可能
    // 覆盖刚发布到磁盘的资产。
    applyCatalogFromDisk(@constCast(context)) catch
        return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"asset persisted but paired model publication failed\"}}\n", meta);
    var location: [320]u8 = undefined;
    const location_value = try std.fmt.bufPrint(&location, "/api/v1/management/assets/{s}", .{value.name});
    try request.setHeader("location", location_value);
    var response_buffer: [384]u8 = undefined;
    const response = try std.fmt.bufPrint(&response_buffer, "{{\"ok\":true,\"result\":{{\"name\":{f},\"kind\":{f},\"sha256\":{f}}}}}\n", .{ std.json.fmt(value.name, .{}), std.json.fmt(@tagName(value.kind), .{}), std.json.fmt(&checksum, .{}) });
    try json(request, .created, response, meta);
}

/// M3.6 / v0.2.3 §7：ISO 导入 handler。完成输入校验、request digest 与
/// queued operation 持久化后立即 submit 给 daemon-owned `IsoImportWorker`
/// 并返回 202；昂贵的 mount/copy/hash 与 catalog 发布全部在 worker 线程
/// 执行，HTTP callback 不再等待。队列容量为 1，submit 失败（已有导入在途）
/// 保持既有 `install_source.busy` 409 语义。内容去重与 name 冲突检查仍在
/// handler 内基于当前 catalog 快照完成，避免已知重复/冲突进入 worker。
fn importInstallSource(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    if (!jsonRequest(request)) return unsupportedMediaType(request, meta);
    const ImportRequest = struct { filename: []const u8, original_filename: []const u8, sha256: []const u8, name: ?[]const u8 = null, qualifier: ?[]const u8 = null, distro: ?[]const u8 = null, version: ?[]const u8 = null, arch: ?model.Arch = null };
    const body = request.body orelse return assetInputError(request, "missing body", meta);
    const parsed = std.json.parseFromSlice(ImportRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch return assetInputError(request, "invalid JSON body", meta);
    defer parsed.deinit();
    const filename = parsed.value.filename;
    const declared_sha256 = parsed.value.sha256;
    if (declared_sha256.len != 64 or !allLowerHex(declared_sha256)) return assetInputError(request, "invalid sha256", meta);
    const name = parsed.value.name;
    if (name) |value| if (!config_validate.validLogicalId(value)) return assetInputError(request, "invalid logical name", meta);
    const qualifier = parsed.value.qualifier;
    if (qualifier) |value| if (!config_validate.validLogicalId(value)) return assetInputError(request, "invalid qualifier", meta);
    const distro = parsed.value.distro;
    const version = parsed.value.version;
    const arch = parsed.value.arch;
    if (distro) |value| if (!config_validate.validLogicalId(value)) return assetInputError(request, "invalid distro override", meta);
    const arch_text = if (arch) |value| @tagName(value) else null;
    const idempotency_key = request.getHeader("idempotency-key") orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"operation.idempotency_key_required\",\"message\":\"Idempotency-Key header is required\"}}\n", meta);
    var digest_buf: [32]u8 = undefined;
    const digest_input = try std.fmt.allocPrint(context.allocator, "sha256={s}&original_filename={s}&name={s}&qualifier={s}&distro={s}&version={s}&arch={s}", .{ declared_sha256, parsed.value.original_filename, name orelse "", qualifier orelse "", distro orelse "", version orelse "", arch_text orelse "" });
    defer context.allocator.free(digest_input);
    std.crypto.hash.sha2.Sha256.hash(digest_input, &digest_buf, .{});
    var digest_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&digest_hex, "{x}", .{digest_buf}) catch unreachable;
    const begun = context.operations.beginQueuedRequest(context.io, idempotency_key, &digest_hex, .install_source_import, unixNow()) catch |err| return json(request, .conflict, if (err == error.IdempotencyConflict) "{\"ok\":false,\"error\":{\"code\":\"operation.idempotency_conflict\",\"message\":\"Idempotency-Key was already used for a different request\"}}\n" else "{\"ok\":false,\"error\":{\"code\":\"operation.unavailable\",\"message\":\"cannot create durable operation\"}}\n", meta);
    saveOperations(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"operation.persist_failed\",\"message\":\"cannot persist operation\"}}\n", meta);
    if (begun.reused) return operationResponse(request, begun.entry, true, meta);
    var operation_done = false;
    defer if (!operation_done) {
        _ = context.operations.fail(begun.entry.idSlice(), "operation.failed", unixNow()) catch {};
        saveOperations(context) catch {};
    };
    var input_hash: [64]u8 = undefined;
    asset_validate.sha256File(context.io, paths.require().import_dir, filename, &input_hash) catch |err| return assetInputError(request, @errorName(err), meta);
    if (!std.mem.eql(u8, &input_hash, declared_sha256)) return assetInputError(request, "ContentDigestMismatch", meta);
    if (filename.len > iso_field_cap or parsed.value.original_filename.len > iso_field_cap)
        return assetInputError(request, "invalid filename length", meta);
    context.catalog.lock();
    const catalog_snapshot = context.catalog.acquireLocked();
    // 无限定符的重复导入按 ISO 内容自然幂等。显式提供 qualifier 表示要从同一
    // 介质派生另一个标准 InstallSource，因此不能被内容去重提前吞掉。
    if (qualifier == null) for (catalog_snapshot.value().assets) |asset| {
        if (asset.kind != .iso or asset.sha256 == null or !std.mem.eql(u8, asset.sha256.?, &input_hash)) continue;
        for (catalog_snapshot.value().install_sources) |source| if (std.mem.eql(u8, source.source_asset, asset.name)) {
            catalog_snapshot.release();
            context.catalog.unlock();
            const completed = try context.operations.succeed(begun.entry.idSlice(), source.name, unixNow());
            try saveOperations(context);
            operation_done = true;
            return operationResponse(request, completed, true, meta);
        };
    };
    if (name) |requested_name| for (catalog_snapshot.value().install_sources) |source| if (std.mem.eql(u8, source.name, requested_name)) {
        catalog_snapshot.release();
        context.catalog.unlock();
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install_source.name_conflict\",\"message\":\"logical name already refers to different content\"}}\n", meta);
    };
    catalog_snapshot.release();
    context.catalog.unlock();
    // 构造受限 job 并提交给 daemon-owned ISO worker；operation_id 同时作为
    // staging 目录名（`work/iso-import-<id>`，§7.4）。
    var job: IsoImportJob = .{};
    @memcpy(&job.operation_id, begun.entry.idSlice());
    job.filename_len = @intCast(filename.len);
    @memcpy(job.filename[0..filename.len], filename);
    job.original_filename_len = @intCast(parsed.value.original_filename.len);
    @memcpy(job.original_filename[0..parsed.value.original_filename.len], parsed.value.original_filename);
    if (name) |value| {
        job.name_len = @intCast(value.len);
        @memcpy(job.name[0..value.len], value);
    }
    if (qualifier) |value| {
        job.qualifier_len = @intCast(value.len);
        @memcpy(job.qualifier[0..value.len], value);
    }
    if (distro) |value| {
        job.distro_len = @intCast(value.len);
        @memcpy(job.distro[0..value.len], value);
    }
    if (version) |value| {
        job.version_len = @intCast(value.len);
        @memcpy(job.version[0..value.len], value);
    }
    job.arch = arch;
    context.iso_worker.submit(job) catch |err| {
        // 队列容量 1：已有导入在途。保持既有 409 `install_source.busy` 语义，
        // 并把刚创建的 queued operation 确定性落为失败（§8.3 映射 exit 3）。
        observe_log.warn("ISO import queue busy: {t}", .{err});
        _ = context.operations.fail(begun.entry.idSlice(), "install_source.busy", unixNow()) catch {};
        saveOperations(context) catch {};
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"install_source.busy\",\"message\":\"another ISO import is running\"}}\n", meta);
    };
    operation_done = true;
    return operationResponse(request, begun.entry, true, meta);
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

fn managementProvisionBundles(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"items\":[");
    for (context.catalog_snapshot.value().provisioning_bundles, 0..) |bundle, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"name\":{f},\"revision\":{d},\"steps\":{d}}}", .{ std.json.fmt(bundle.name, .{}), bundle.revision, bundle.steps.len });
    }
    try output.writer.print("],\"revision\":{d}}}}}\n", .{context.catalog_snapshot.revision});
    return json(request, .ok, output.written(), meta);
}

fn managementProvisionBundle(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    for (context.catalog_snapshot.value().provisioning_bundles) |bundle| if (std.mem.eql(u8, bundle.name, name)) {
        var output: std.Io.Writer.Allocating = .init(context.allocator);
        defer output.deinit();
        try output.writer.print("{{\"ok\":true,\"result\":{f}}}\n", .{std.json.fmt(bundle, .{})});
        return json(request, .ok, output.written(), meta);
    };
    return notFound(request, meta);
}

fn managementProvisionBundleItems(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    for (context.catalog_snapshot.value().provisioning_bundles) |bundle| if (std.mem.eql(u8, bundle.name, name)) {
        const identity = request.getParamSlice("identity");
        var output: std.Io.Writer.Allocating = .init(context.allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"ok\":true,\"result\":{\"key\":\"steps\",\"items\":[");
        var first = true;
        for (bundle.steps) |step| {
            if (identity != null and !std.mem.eql(u8, identity.?, step.name)) continue;
            if (!first) try output.writer.writeByte(',');
            first = false;
            try output.writer.print("{f}", .{std.json.fmt(step, .{})});
        }
        try output.writer.print("],\"revision\":{d}}}}}\n", .{bundle.revision});
        return json(request, .ok, output.written(), meta);
    };
    return notFound(request, meta);
}

fn provisionMutationGuard(request: zap.Request, context: *RouteContext, meta: RequestMeta) !bool {
    if (!ifMatchCurrent(request, context)) {
        try revisionConflict(request, meta);
        return false;
    }
    if (context.sessions.hasActive(boot_session.monotonicNow())) {
        try json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"provision.active_session\",\"message\":\"bundle mutation is blocked by an active boot session\"}}\n", meta);
        return false;
    }
    return true;
}

/// v0.2 boot-bundle 创建：将已注册的 kernel 与 nodeforge_initrd 绑定为
/// 不可拆分的版本组合。rootfs 由 Profile build projection 独立派生。
///
/// 请求体 JSON 字段：name, distro, version, arch, kernel_release, kernel, initrd,
/// 可选 runtime_kernel。
///
/// 校验链：必填字段非空 → arch 枚举有效 → 名称不重复 → kernel 资产 kind=kernel →
/// initrd 资产 kind=nodeforge_initrd → catalog 原子写入。
///
/// 该 API 是 diskless 全流程 CLI 的关键环节。`nodeforge assets boot-bundle create`
/// 调用此 API，使操作员无需手动编辑 catalog JSON 文件。
fn managementBootBundleCreate(request: zap.Request, context: *RouteContext, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"boot_bundle.invalid\",\"message\":\"missing request body\"}}\n", meta);
    const Req = struct { name: []const u8, distro: []const u8, version: []const u8, arch: []const u8, kernel_release: []const u8, kernel: []const u8, initrd: []const u8, runtime_kernel: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(Req, context.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"boot_bundle.invalid\",\"message\":\"invalid boot bundle request\"}}\n", meta);
    defer parsed.deinit();
    if (parsed.value.name.len == 0 or parsed.value.distro.len == 0 or parsed.value.version.len == 0 or parsed.value.kernel_release.len == 0 or parsed.value.kernel.len == 0 or parsed.value.initrd.len == 0) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"boot_bundle.invalid\",\"message\":\"all fields except runtime_kernel are required\"}}\n", meta);
    const arch = std.meta.stringToEnum(model.Arch, parsed.value.arch) orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"boot_bundle.invalid\",\"message\":\"arch must be aarch64 or x86_64\"}}\n", meta);
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    const catalog = context.catalog_snapshot.value();
    for (catalog.boot_bundles) |bb| if (std.mem.eql(u8, bb.name, parsed.value.name)) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"boot_bundle.already_exists\",\"message\":\"boot bundle name already exists\"}}\n", meta);
    // BootBundle 没有独立的自由命名空间：它必须保留某个完整
    // InstallSource 前缀并以 `-diskless-bundle` 结尾；中间可追加用途/内核限定符，
    // 同时平台 tuple 必须与该 source 一致。
    var canonical_source_found = false;
    for (catalog.install_sources) |source| {
        if (!@import("../profile/naming.zig").bootBundleIsCanonical(parsed.value.name, source.name)) continue;
        if (std.mem.eql(u8, source.distro, parsed.value.distro) and
            std.mem.eql(u8, source.version, parsed.value.version) and
            source.arch == arch)
            canonical_source_found = true;
    }
    if (!canonical_source_found) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"boot_bundle.non_canonical_name\",\"message\":\"boot bundle name must retain the complete install-source prefix, end in -diskless-bundle, and match that source platform\"}}\n", meta);
    const kernel_asset = lookup.findAsset(catalog, parsed.value.kernel) orelse return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"boot_bundle.asset_not_found\",\"message\":\"kernel asset not found\"}}\n", meta);
    if (kernel_asset.kind != .kernel) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"boot_bundle.asset_kind_mismatch\",\"message\":\"kernel asset must have kind=kernel\"}}\n", meta);
    if (kernel_asset.kernel_release) |detected_release| {
        if (!std.mem.eql(u8, detected_release, parsed.value.kernel_release))
            std.log.scoped(.boot_bundle).warn(
                "creating bundle {s}: requested kernel_release={s} differs from kernel asset {s} release={s}; accepting explicit user value",
                .{ parsed.value.name, parsed.value.kernel_release, kernel_asset.name, detected_release },
            );
    }
    const initrd_asset = lookup.findAsset(catalog, parsed.value.initrd) orelse return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"boot_bundle.asset_not_found\",\"message\":\"initrd asset not found\"}}\n", meta);
    if (initrd_asset.kind != .nodeforge_initrd) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"boot_bundle.asset_kind_mismatch\",\"message\":\"initrd asset must have kind=nodeforge_initrd\"}}\n", meta);
    const new_bundle = model.BootBundleConfig{ .name = parsed.value.name, .distro = parsed.value.distro, .version = parsed.value.version, .arch = arch, .kernel_release = parsed.value.kernel_release, .kernel = parsed.value.kernel, .runtime_kernel = parsed.value.runtime_kernel, .initrd = parsed.value.initrd };
    // 加载当前 catalog、追加 boot bundle、原子保存。
    var loaded = @import("../catalog/store.zig").load(context.io, context.allocator, context.catalog.path) catch |err| return assetInputError(request, @errorName(err), meta);
    defer loaded.deinit();
    var bundles_list = std.ArrayList(model.BootBundleConfig).empty;
    defer bundles_list.deinit(context.allocator);
    try bundles_list.appendSlice(context.allocator, loaded.value.boot_bundles);
    try bundles_list.append(context.allocator, new_bundle);
    loaded.value.boot_bundles = bundles_list.items;
    // Validate the complete candidate before the catalog transaction is
    // persisted.  Publishing after save is intentionally not the first
    // validation boundary: otherwise a rejected cross-distro kernel/initrd
    // tuple leaves an invalid catalog on disk while the daemon keeps serving
    // the previous in-memory snapshot.
    const projected = model.projectCatalog(context.config.*, &loaded.value);
    config_validate.validate(&projected, &loaded.value) catch |err| return validationError(request, err, meta);
    @import("../catalog/store.zig").save(context.io, context.allocator, context.catalog.path, &loaded.value) catch |err| return assetInputError(request, @errorName(err), meta);
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"boot bundle persisted but snapshot publish failed\"}}\n", meta);
    var response: [512]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&response, "{{\"ok\":true,\"result\":{{\"name\":{f},\"distro\":{f},\"version\":{f},\"arch\":{f},\"kernel_release\":{f},\"kernel\":{f},\"initrd\":{f}}}}}\n", .{ std.json.fmt(new_bundle.name, .{}), std.json.fmt(new_bundle.distro, .{}), std.json.fmt(new_bundle.version, .{}), std.json.fmt(@tagName(new_bundle.arch), .{}), std.json.fmt(new_bundle.kernel_release, .{}), std.json.fmt(new_bundle.kernel, .{}), std.json.fmt(new_bundle.initrd, .{}) });
    return json(request, .created, rendered, meta);
}

fn managementBootBundles(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"items\":[");
    for (context.catalog_snapshot.value().boot_bundles, 0..) |bundle, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{f}", .{std.json.fmt(bundle, .{})});
    }
    try output.writer.print("],\"revision\":{d}}}}}\n", .{context.catalog_snapshot.revision});
    return json(request, .ok, output.written(), meta);
}

fn managementProvisionBundleCreate(request: zap.Request, context: *RouteContext, meta: RequestMeta) !void {
    const parsed = std.json.parseFromSlice(struct { name: []const u8 }, context.allocator, request.body orelse return assetInputError(request, "missing body", meta), .{ .allocate = .alloc_always }) catch return assetInputError(request, "invalid bundle request", meta);
    defer parsed.deinit();
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!try provisionMutationGuard(request, context, meta)) return;
    provision_bundle_mutation.create(context.io, context.allocator, context.config, context.catalog.path, parsed.value.name) catch |err| return assetInputError(request, @errorName(err), meta);
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"bundle persisted but snapshot publish failed\"}}\n", meta);
    return json(request, .created, "{\"ok\":true,\"result\":{\"created\":true}}\n", meta);
}

fn managementProvisionBundleRemove(request: zap.Request, context: *RouteContext, name: []const u8, meta: RequestMeta) !void {
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!try provisionMutationGuard(request, context, meta)) return;
    provision_bundle_mutation.remove(context.io, context.allocator, context.config, context.catalog.path, name) catch |err| return assetInputError(request, @errorName(err), meta);
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"bundle removal persisted but snapshot publish failed\"}}\n", meta);
    return json(request, .ok, "{\"ok\":true,\"result\":{\"removed\":true}}\n", meta);
}

fn managementManagedFileRemove(request: zap.Request, context: *RouteContext, name: []const u8, meta: RequestMeta) !void {
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!try provisionMutationGuard(request, context, meta)) return;
    context.catalog.removeManagedFile(context.io, context.config, name) catch |err| return assetInputError(request, @errorName(err), meta);
    return json(request, .ok, "{\"ok\":true,\"result\":{\"removed\":true,\"immutable_bytes_retained\":true}}\n", meta);
}

fn managementProvisionBundleItemMutation(request: zap.Request, context: *RouteContext, name: []const u8, meta: RequestMeta) !void {
    const body = request.body orelse return assetInputError(request, "missing body", meta);
    const raw = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return assetInputError(request, "invalid item request", meta);
    defer raw.deinit();
    const operation = if (raw.value == .object) raw.value.object.get("operation") else null;
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!try provisionMutationGuard(request, context, meta)) return;
    if (operation != null and operation.? == .string and (std.mem.eql(u8, operation.?.string, "replace") or std.mem.eql(u8, operation.?.string, "clear"))) {
        const Replacement = struct { operation: enum { replace, clear }, key: []const u8 = "steps", steps: []const provision_bundle_mutation.StepInput = &.{} };
        const parsed = std.json.parseFromSlice(Replacement, context.allocator, body, .{ .allocate = .alloc_always }) catch return assetInputError(request, "invalid step replacement", meta);
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.key, "steps")) return assetInputError(request, "unknown item collection", meta);
        const steps = try context.allocator.alloc(model.ProvisionStep, parsed.value.steps.len);
        defer context.allocator.free(steps);
        for (parsed.value.steps, 0..) |step, index| steps[index] = step.modelValue();
        provision_bundle_mutation.replace(context.io, context.allocator, context.config, context.catalog.path, name, if (parsed.value.operation == .clear) &.{} else steps) catch |err| return assetInputError(request, @errorName(err), meta);
    } else {
        const parsed = std.json.parseFromSlice(provision_bundle_mutation.Patch, context.allocator, body, .{ .allocate = .alloc_always }) catch return assetInputError(request, "invalid step patch", meta);
        defer parsed.deinit();
        provision_bundle_mutation.mutate(context.io, context.allocator, context.config, context.catalog.path, name, parsed.value) catch |err| return assetInputError(request, @errorName(err), meta);
    }
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"bundle persisted but snapshot publish failed\"}}\n", meta);
    return json(request, .ok, "{\"ok\":true,\"result\":{\"updated\":true}}\n", meta);
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

fn managementRepositories(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    const all = context.catalog_snapshot.value().repositories;
    const page = pageRequest(request, "repositories", context.catalog_snapshot.revision) catch |err| return pageError(request, err, meta);
    if (page.offset > all.len) return pageError(request, error.InvalidCursor, meta);
    const end = @min(page.offset + page.limit, all.len);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"items\":[");
    for (all[page.offset..end], 0..) |repository, index| {
        if (index != 0) try output.writer.writeByte(',');
        // List 端点不返回 software_index.capabilities（可能包含数千条目，
        // 导致响应超过 CLI 客户端的固定缓冲区）。使用 detail 端点获取完整索引。
        try output.writer.print("{f}", .{std.json.fmt(.{
            .name = repository.name,
            .distro = repository.distro,
            .version = repository.version,
            .arch = repository.arch,
            .manager = repository.manager,
            .base_url = repository.base_url,
            .gpg_check = repository.gpg_check,
            .gpg_key = repository.gpg_key,
            .software_index = .{
                .revision_digest = repository.software_index.revision_digest,
                .capabilities = &[_]model.SoftwareCapability{},
            },
        }, .{})});
    }
    try output.writer.writeByte(']');
    try writeNextCursor(&output.writer, "repositories", context.catalog_snapshot.revision, end, all.len);
    try output.writer.print(",\"view_revision\":{d}}}}}\n", .{context.catalog_snapshot.revision});
    return json(request, .ok, output.written(), meta);
}

fn managementRepository(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    const repository = lookup.findRepository(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    // Detail 端点也不返回 software_index.capabilities（可能包含数千条目，
    // 导致响应超过 CLI 客户端的固定缓冲区）。使用 /software 子端点获取完整索引。
    try output.writer.print("{{\"ok\":true,\"result\":{{\"repository\":{f},\"supported_kinds\":", .{std.json.fmt(.{
        .name = repository.name,
        .distro = repository.distro,
        .version = repository.version,
        .arch = repository.arch,
        .manager = repository.manager,
        .base_url = repository.base_url,
        .gpg_check = repository.gpg_check,
        .gpg_key = repository.gpg_key,
        .software_index = .{
            .revision_digest = repository.software_index.revision_digest,
            .capabilities = &[_]model.SoftwareCapability{},
        },
    }, .{})});
    try writeSupportedSoftwareKinds(&output.writer, repository.manager);
    try output.writer.writeAll("}}\n");
    return json(request, .ok, output.written(), meta);
}

fn managementRepositorySoftware(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    const repository = lookup.findRepository(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    return softwareCapabilitiesResponse(request, context, &.{repository}, meta);
}

fn managementInstallSourceSoftware(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    const source = lookup.findInstallSource(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    const repositories = try context.allocator.alloc(*const model.RepositoryConfig, source.repositories.len);
    defer context.allocator.free(repositories);
    for (source.repositories, 0..) |repository_name, index| repositories[index] = lookup.findRepository(context.catalog_snapshot.value(), repository_name) orelse return notFound(request, meta);
    return softwareCapabilitiesResponse(request, context, repositories, meta);
}

fn managementProfileSoftware(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    const profile = lookup.findProfile(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    const source = lookup.findInstallSource(context.catalog_snapshot.value(), profile.install_source) orelse return notFound(request, meta);
    const repositories = try context.allocator.alloc(*const model.RepositoryConfig, source.repositories.len);
    defer context.allocator.free(repositories);
    for (source.repositories, 0..) |repository_name, index| repositories[index] = lookup.findRepository(context.catalog_snapshot.value(), repository_name) orelse return notFound(request, meta);
    return softwareCapabilitiesResponse(request, context, repositories, meta);
}

fn softwareCapabilitiesResponse(request: zap.Request, context: *const RouteContext, repositories: []const *const model.RepositoryConfig, meta: RequestMeta) !void {
    if (repositories.len == 0) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"software.index_unavailable\",\"message\":\"no indexed repository is available\"}}\n", meta);
    const kind_text = request.getParamSlice("kind");
    const kind = if (kind_text) |value| std.meta.stringToEnum(model.SoftwareKind, value) orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"software.invalid_kind\",\"message\":\"unknown software capability kind\"}}\n", meta) else null;
    const manager = repositories[0].manager;
    if (kind) |value| if (!softwareKindApplicable(manager, value)) {
        var output: std.Io.Writer.Allocating = .init(context.allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"ok\":false,\"error\":{\"code\":\"software.kind_not_applicable\",\"message\":\"kind is not applicable to this repository\",\"details\":{\"supported_kinds\":");
        try writeSupportedSoftwareKinds(&output.writer, manager);
        try output.writer.writeAll("}}}\n");
        return json(request, .unprocessable_content, output.written(), meta);
    };
    const search = request.getParamSlice("search") orelse "";
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"items\":[");
    var first = true;
    for (repositories) |repository| for (repository.software_index.capabilities) |capability| {
        if (kind != null and capability.kind != kind.?) continue;
        if (search.len != 0 and !containsAsciiInsensitive(capability.id, search) and !containsAsciiInsensitive(capability.name, search)) continue;
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{{\"repository\":{f},\"capability\":{f}}}", .{ std.json.fmt(repository.name, .{}), std.json.fmt(capability, .{}) });
    };
    try output.writer.writeAll("],\"supported_kinds\":");
    try writeSupportedSoftwareKinds(&output.writer, manager);
    try output.writer.writeAll(",\"index_digests\":[");
    for (repositories, 0..) |repository, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{f}", .{std.json.fmt(repository.software_index.revision_digest, .{})});
    }
    try output.writer.writeAll("]}}\n");
    return json(request, .ok, output.written(), meta);
}

fn softwareKindApplicable(manager: model.PackageManager, kind: model.SoftwareKind) bool {
    return switch (manager) {
        .dnf => kind == .environment or kind == .group or kind == .package,
        .apt => kind == .task or kind == .metapackage or kind == .package,
    };
}
fn writeSupportedSoftwareKinds(writer: *std.Io.Writer, manager: model.PackageManager) !void {
    return switch (manager) {
        .dnf => writer.writeAll("[\"environment\",\"group\",\"package\"]"),
        .apt => writer.writeAll("[\"task\",\"metapackage\",\"package\"]"),
    };
}
fn containsAsciiInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    return false;
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

fn managementInstallSource(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    const source = lookup.findInstallSource(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    const distro = lookup.findDistro(context.catalog_snapshot.value(), source.distro) orelse return notFound(request, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"model_revision\":{{\"config\":{d},\"catalog\":{d}}},\"install_source\":{f},\"family\":{f},\"repositories\":[", .{ context.config_revision, context.catalog_snapshot.revision, std.json.fmt(source.*, .{}), std.json.fmt(@tagName(distro.family), .{}) });
    for (source.repositories, 0..) |repository_name, index| {
        const repository = lookup.findRepository(context.catalog_snapshot.value(), repository_name) orelse return notFound(request, meta);
        if (index != 0) try output.writer.writeByte(',');
        // install-source detail 中的 repository 同样使用 summary 视图。
        try output.writer.print("{f}", .{std.json.fmt(.{
            .name = repository.name,
            .distro = repository.distro,
            .version = repository.version,
            .arch = repository.arch,
            .manager = repository.manager,
            .base_url = repository.base_url,
            .gpg_check = repository.gpg_check,
            .gpg_key = repository.gpg_key,
            .software_index = .{
                .revision_digest = repository.software_index.revision_digest,
                .capabilities = &[_]model.SoftwareCapability{},
            },
        }, .{})});
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
    for (context.catalog_snapshot.value().profiles) |profile| if (std.mem.eql(u8, profile.install_source, name)) {
        if (!first) try output.writer.writeByte(',');
        first = false;
        try output.writer.print("{f}", .{std.json.fmt(profile.name, .{})});
    };
    try output.writer.writeAll("]}}\n");
    return json(request, .ok, output.written(), meta);
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

fn saveOperations(context: *const RouteContext) !void {
    while (!operation_persist_mutex.tryLock()) std.Thread.yield() catch {};
    defer operation_persist_mutex.unlock();
    try operations.save(context.io, context.allocator, paths.require().operations_path, context.operations);
}

fn writeOperation(writer: *std.Io.Writer, operation: operations.Entry) !void {
    try writer.print("{{\"id\":{f},\"kind\":{f},\"state\":{f},\"created_at\":{d},\"updated_at\":{d},\"result\":{f},\"error_code\":{f}}}", .{ std.json.fmt(operation.idSlice(), .{}), std.json.fmt(@tagName(operation.kind), .{}), std.json.fmt(@tagName(operation.state), .{}), operation.created_at, operation.updated_at, std.json.fmt(operation.resultSlice(), .{}), std.json.fmt(operation.errorSlice(), .{}) });
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

/// v0.3: 匹配 `GET /api/v1/management/nodes/:id/install-post-journal`。
fn installPostJournalPath(path: []const u8) ?[]const u8 {
    const prefix = "/api/v1/management/nodes/";
    const suffix = "/install-post-journal";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const node_id = path[prefix.len .. path.len - suffix.len];
    return if (auth.nodeIdSafe(node_id)) node_id else null;
}

/// v0.3: 返回节点最近一次 install-post run 的 journal 状态。
fn managementInstallPostJournal(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const selected = if (request.getParamSlice("generation")) |raw| blk: {
        const generation = std.fmt.parseInt(u64, raw, 10) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"postprocess.invalid_generation\",\"message\":\"generation must be a positive integer\"}}\n", meta);
        if (generation == 0) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"postprocess.invalid_generation\",\"message\":\"generation must be a positive integer\"}}\n", meta);
        break :blk context.install_post_journal.view(node_id, generation);
    } else context.install_post_journal.latestView(node_id);
    const run = selected orelse {
        var body: [80]u8 = undefined;
        const msg = try std.fmt.bufPrint(&body, "{{\"ok\":true,\"result\":{{\"node_id\":{f},\"run\":null}}}}\n", .{std.json.fmt(node_id, .{})});
        return json(request, .ok, msg, meta);
    };
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"node_id\":{f},\"run\":{{\"install_generation\":{d},\"status\":{f},\"bundle_revision\":{d},\"created_at\":{d},\"updated_at\":{d},\"steps\":[", .{ std.json.fmt(node_id, .{}), run.install_generation, std.json.fmt(@tagName(run.status), .{}), run.bundle_revision, run.created_at, run.updated_at });
    for (run.steps, 0..) |step, i| {
        if (i > 0) try output.writer.writeByte(',');
        try output.writer.print("{{\"step_id\":{f},\"status\":{f},\"attempts\":{d},\"updated_at\":{d}}}", .{ std.json.fmt(step.step_id, .{}), std.json.fmt(@tagName(step.status), .{}), step.attempts, step.updated_at });
    }
    try output.writer.writeAll("]}");
    if (run.failure_reason) |reason| {
        try output.writer.print(",\"failure_reason\":{f}", .{std.json.fmt(reason, .{})});
    }
    try output.writer.writeAll("}}\n");
    return json(request, .ok, output.written(), meta);
}

fn claimPath(path: []const u8) ?[]const u8 {
    const prefix = "/api/v1/management/nodes/";
    const suffix = "/claim";
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    const node_id = path[prefix.len .. path.len - suffix.len];
    return if (auth.nodeIdSafe(node_id)) node_id else null;
}

fn installGenerations(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const node = lookup.findNode(context.catalog_snapshot.value(), node_id) orelse return notFound(request, meta);
    const profile = lookup.findProfile(context.catalog_snapshot.value(), node.profile orelse return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.profile_unassigned\",\"message\":\"node has no bound profile\"}}\n", meta)) orelse return notFound(request, meta);
    if (profile.kind != .install) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.not_install\",\"message\":\"install retry is only available for install profiles; diskless nodes boot again when deploy=true\"}}\n", meta);
    var effective_plan = @import("../profile/effective.zig").compile(context.allocator, context.catalog_snapshot.value(), node) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"effective.unavailable\",\"message\":\"effective node plan cannot be compiled\"}}\n", meta);
    defer effective_plan.deinit();
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
    const armed_at = unixNow();
    const rearm = context.deployments.rearm(node_id, desired_digest, armed_at, .operator) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot rearm install generation\"}}\n", meta);
    if (rearm.changed) {
        deployment_control.save(context.io, context.allocator, paths.require().deployment_control_path, context.deployments) catch {
            context.deployments.rollbackRearm(node_id, rearm);
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"deployment.persist_failed\",\"message\":\"cannot persist install generation\"}}\n", meta);
        };
        var generation_text: [24]u8 = undefined;
        var revision_text: [24]u8 = undefined;
        var armed_at_text: [24]u8 = undefined;
        const fields = [_]events.Field{
            .{ .key = "node_id", .value = node_id },
            .{ .key = "generation", .value = std.fmt.bufPrint(&generation_text, "{d}", .{rearm.generation}) catch "0" },
            .{ .key = "config_revision", .value = std.fmt.bufPrint(&revision_text, "{d}", .{context.config_revision}) catch "0" },
            .{ .key = "armed_at", .value = std.fmt.bufPrint(&armed_at_text, "{d}", .{armed_at}) catch "0" },
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

const NodeAddRequest = dto.Node;

const ProfileCreateRequest = struct { name: []const u8, install_source: []const u8, kind: ?[]const u8 = null, boot_bundle: ?[]const u8 = null };
/// v0.2.3 §5.2 clone 扩展：
/// - `new_ssh_keys`：创建独立 identity（不复用 source）；
/// - `build`：clone 提交后追加 rootfs build operation（仅 diskless）；
/// - `detach`：与 `build` 同用时立即返回 operation id；
/// - `properties`：与 clone 同一 catalog 事务应用的 key=value patch
///   （范围与 `profile set` 相同）。
const ProfileCloneRequest = struct {
    target: []const u8,
    new_ssh_keys: bool = false,
    build: bool = false,
    detach: bool = false,
    properties: ?std.json.Value = null,
};
const ValuesMutationRequest = struct { operation: value_mutation.Operation, key: []const u8, values: []const []const u8 = &.{}, mutations: []const scalar_mutation.Mutation = &.{} };
const ItemValuesMutationRequest = struct { operation: value_mutation.Operation, key: []const u8, identity: []const u8, field: []const u8, values: []const []const u8 = &.{} };

fn managementValuesMutation(request: zap.Request, context: *RouteContext, owner: cli_properties.Owner, identity: []const u8, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.invalid_request\",\"message\":\"missing values request\"}}\n", meta);
    const parsed = std.json.parseFromSlice(ValuesMutationRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.invalid_request\",\"message\":\"operation, key, and values are required\"}}\n", meta);
    defer parsed.deinit();
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    // ── force 模式：终止目标节点 session 后绕过全局 hasActive() 检查 ──
    // node 变更：终止目标节点的 boot_session + diskless_delivery session。
    // profile 变更：仅绕过检查（profile 变更不影响活动 session 的不可变 plan）。
    if (parseForceFlag(request)) {
        if (owner == .node) {
            if (!forceTerminateNodeSessions(context, identity)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist forced session termination\"}}\n", meta);
        }
    } else if (context.sessions.hasActive(boot_session.monotonicNow())) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"property.active_session\",\"message\":\"collection mutation is blocked by an active boot session; use --force to override\"}}\n", meta);
    const mutation = switch (owner) {
        .profile => if (parsed.value.mutations.len == 0) value_mutation.profile(context.io, context.allocator, context.config, context.catalog.path, identity, parsed.value.key, parsed.value.operation, parsed.value.values) else error.UnsupportedProperty,
        .node => value_mutation.node(context.io, context.allocator, context.config, context.catalog.path, identity, parsed.value.key, parsed.value.operation, parsed.value.values, parsed.value.mutations),
        else => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.invalid_owner\",\"message\":\"unsupported values owner\"}}\n", meta),
    };
    mutation catch |err| switch (err) {
        error.UnknownProperty => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown collection key\"}}\n", meta),
        error.UnsupportedProperty => return json(request, .unprocessable_content, "{\"ok\":false,\"error\":{\"code\":\"property.unsupported\",\"message\":\"collection is not implemented by this resource\"}}\n", meta),
        error.DuplicateValue => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"property.duplicate_value\",\"message\":\"collection values must be unique\"}}\n", meta),
        error.ValueNotFound => return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"property.value_not_found\",\"message\":\"collection value does not exist\"}}\n", meta),
        else => return validationError(request, err, meta),
    };
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"values persisted but snapshot publish failed\"}}\n", meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"resource\":{f},\"key\":{f},\"operation\":{f},\"revision\":{d}}}}}\n", .{ std.json.fmt(identity, .{}), std.json.fmt(parsed.value.key, .{}), std.json.fmt(@tagName(parsed.value.operation), .{}), context.catalog.currentRevision() });
    try setRevisionEtag(request, context.catalog.currentRevision());
    return json(request, .ok, output.written(), meta);
}

fn managementValuesGet(request: zap.Request, context: *const RouteContext, owner: cli_properties.Owner, identity: []const u8, meta: RequestMeta) !void {
    const key = request.getParamSlice("key") orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.key_required\",\"message\":\"key query parameter is required\"}}\n", meta);
    var kernel_values: std.ArrayList([]const u8) = .empty;
    defer kernel_values.deinit(context.allocator);
    const values = switch (owner) {
        .profile => blk: {
            const profile = lookup.findProfile(context.catalog_snapshot.value(), identity) orelse return notFound(request, meta);
            if (std.mem.eql(u8, key, "kernel_args")) {
                if (profile.kernel_args) |text| {
                    var iterator = std.mem.tokenizeScalar(u8, text, ' ');
                    while (iterator.next()) |value| try kernel_values.append(context.allocator, value);
                }
                break :blk kernel_values.items;
            }
            break :blk profileValues(profile, key) orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown collection key\"}}\n", meta);
        },
        .node => blk: {
            const node = lookup.findNode(context.catalog_snapshot.value(), identity) orelse return notFound(request, meta);
            break :blk nodeValues(node, key) orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown collection key\"}}\n", meta);
        },
        else => return error.InvalidOwner,
    };
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"resource\":{f},\"key\":{f},\"values\":{f},\"revision\":{d}}}}}\n", .{ std.json.fmt(identity, .{}), std.json.fmt(key, .{}), std.json.fmt(values, .{}), context.catalog_snapshot.revision });
    return json(request, .ok, output.written(), meta);
}

fn profileValues(profile: *const model.ProfileConfig, key: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, key, "system.connectivity.ntp_servers")) return profile.system.connectivity.ntp_servers;
    if (std.mem.eql(u8, key, "system.ssh.root_authorized_keys")) return profile.system.ssh.root_authorized_keys;
    if (std.mem.eql(u8, key, "software.repositories")) return profile.software.repositories;
    if (std.mem.eql(u8, key, "software.groups")) return profile.software.groups;
    if (std.mem.eql(u8, key, "software.tasks")) return profile.software.tasks;
    if (std.mem.eql(u8, key, "software.packages.include")) return profile.software.packages.include;
    if (std.mem.eql(u8, key, "software.packages.exclude")) return profile.software.packages.exclude;
    if (std.mem.eql(u8, key, "install.proxy.no_proxy")) return profile.install.proxy.no_proxy;
    return null;
}
fn nodeValues(node: *const model.NodeConfig, key: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, key, "network.dns")) return node.network.dns;
    if (std.mem.eql(u8, key, "network.search_domains")) return node.network.search_domains;
    if (std.mem.eql(u8, key, "storage.additional_disks")) return node.storage.additional_disks;
    if (std.mem.eql(u8, key, "overrides.software.repositories.add")) return node.overrides.software.repositories.add;
    if (std.mem.eql(u8, key, "overrides.software.repositories.remove")) return node.overrides.software.repositories.remove;
    if (std.mem.eql(u8, key, "overrides.software.groups.add")) return node.overrides.software.groups.add;
    if (std.mem.eql(u8, key, "overrides.software.groups.remove")) return node.overrides.software.groups.remove;
    if (std.mem.eql(u8, key, "overrides.software.tasks.add")) return node.overrides.software.tasks.add;
    if (std.mem.eql(u8, key, "overrides.software.tasks.remove")) return node.overrides.software.tasks.remove;
    if (std.mem.eql(u8, key, "overrides.software.packages.include.add")) return node.overrides.software.packages_include.add;
    if (std.mem.eql(u8, key, "overrides.software.packages.include.remove")) return node.overrides.software.packages_include.remove;
    if (std.mem.eql(u8, key, "overrides.kernel_args.add")) return node.overrides.kernel_args.add;
    if (std.mem.eql(u8, key, "overrides.kernel_args.remove")) return node.overrides.kernel_args.remove;
    if (std.mem.eql(u8, key, "overrides.system.connectivity.ntp_servers.add")) return node.overrides.system.connectivity.ntp_servers.add;
    if (std.mem.eql(u8, key, "overrides.system.connectivity.ntp_servers.remove")) return node.overrides.system.connectivity.ntp_servers.remove;
    if (std.mem.eql(u8, key, "overrides.system.ssh.root_authorized_keys.add")) return node.overrides.system.ssh.root_authorized_keys.add;
    if (std.mem.eql(u8, key, "overrides.system.ssh.root_authorized_keys.remove")) return node.overrides.system.ssh.root_authorized_keys.remove;
    if (std.mem.eql(u8, key, "overrides.software.packages.exclude.add")) return node.overrides.software.packages_exclude.add;
    if (std.mem.eql(u8, key, "overrides.software.packages.exclude.remove")) return node.overrides.software.packages_exclude.remove;
    if (std.mem.eql(u8, key, "overrides.install.proxy.no_proxy.add")) return node.overrides.install.proxy_no_proxy.add;
    if (std.mem.eql(u8, key, "overrides.install.proxy.no_proxy.remove")) return node.overrides.install.proxy_no_proxy.remove;
    return null;
}

fn managementItemMutation(request: zap.Request, context: *RouteContext, owner: cli_properties.Owner, identity: []const u8, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"item.invalid_request\",\"message\":\"missing item patch\"}}\n", meta);
    const raw = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"item.invalid_request\",\"message\":\"invalid item request\"}}\n", meta);
    defer raw.deinit();
    if (raw.value == .object and raw.value.object.get("field") != null) return managementItemValuesMutation(request, context, owner, identity, body, meta);
    if (raw.value == .object) if (raw.value.object.get("operation")) |operation| if (operation == .string and (std.mem.eql(u8, operation.string, "replace") or std.mem.eql(u8, operation.string, "clear"))) return managementItemReplacement(request, context, owner, identity, body, meta);
    const parsed = std.json.parseFromSlice(item_mutation.Patch, context.allocator, body, .{ .allocate = .alloc_always }) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"item.invalid_request\",\"message\":\"invalid typed item patch\"}}\n", meta);
    defer parsed.deinit();
    const spec = cli_properties.collection(owner, parsed.value.key) orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown structured collection\"}}\n", meta);
    if (spec.item_spec == null or spec.mutability != .mutable) return json(request, .unprocessable_content, "{\"ok\":false,\"error\":{\"code\":\"property.unsupported\",\"message\":\"collection does not support item mutation\"}}\n", meta);
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    // ── force 模式：终止目标节点 session 后绕过全局 hasActive() 检查 ──
    if (parseForceFlag(request)) {
        if (owner == .node) {
            if (!forceTerminateNodeSessions(context, identity)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist forced session termination\"}}\n", meta);
        }
    } else if (context.sessions.hasActive(boot_session.monotonicNow())) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"item.active_session\",\"message\":\"item mutation is blocked by an active boot session; use --force to override\"}}\n", meta);
    const mutation = switch (owner) {
        .profile => item_mutation.profile(context.io, context.allocator, context.config, context.catalog.path, identity, parsed.value),
        .node => item_mutation.node(context.io, context.allocator, context.config, context.catalog.path, identity, parsed.value),
        else => return error.InvalidOwner,
    };
    mutation catch |err| switch (err) {
        error.ItemNotFound => return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"item.not_found\",\"message\":\"item identity does not exist\"}}\n", meta),
        error.InvalidItemIdentity => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"item.invalid_identity\",\"message\":\"identity field is missing, duplicate, or inconsistent\"}}\n", meta),
        error.UnknownItemField => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"item.unknown_field\",\"message\":\"field is not part of this ItemSpec\"}}\n", meta),
        else => return validationError(request, err, meta),
    };
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"item persisted but snapshot publish failed\"}}\n", meta);
    var output: [320]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&output, "{{\"ok\":true,\"result\":{{\"resource\":{f},\"key\":{f},\"identity\":{f},\"operation\":{f},\"revision\":{d}}}}}\n", .{ std.json.fmt(identity, .{}), std.json.fmt(parsed.value.key, .{}), std.json.fmt(parsed.value.identity, .{}), std.json.fmt(@tagName(parsed.value.operation), .{}), context.catalog.currentRevision() });
    return json(request, .ok, rendered, meta);
}

fn managementItemValuesMutation(request: zap.Request, context: *RouteContext, owner: cli_properties.Owner, resource_identity: []const u8, body: []const u8, meta: RequestMeta) !void {
    const parsed = std.json.parseFromSlice(ItemValuesMutationRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"item.invalid_request\",\"message\":\"invalid item values request\"}}\n", meta);
    defer parsed.deinit();
    const expected_key = if (owner == .profile) "system.users" else "overrides.system.users";
    if (!std.mem.eql(u8, parsed.value.key, expected_key) or (!std.mem.eql(u8, parsed.value.field, "groups") and !std.mem.eql(u8, parsed.value.field, "ssh_authorized_keys"))) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"item.unknown_field\",\"message\":\"unknown item collection field\"}}\n", meta);
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    // ── force 模式：终止目标节点 session 后绕过全局 hasActive() 检查 ──
    if (parseForceFlag(request)) {
        if (owner == .node) {
            if (!forceTerminateNodeSessions(context, resource_identity)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist forced session termination\"}}\n", meta);
        }
    } else if (context.sessions.hasActive(boot_session.monotonicNow())) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"item.active_session\",\"message\":\"item mutation is blocked by an active boot session; use --force to override\"}}\n", meta);
    const mutation = switch (owner) {
        .profile => item_mutation.profileUserValues(context.io, context.allocator, context.config, context.catalog.path, resource_identity, parsed.value.identity, parsed.value.field, parsed.value.operation, parsed.value.values),
        .node => item_mutation.nodeUserValues(context.io, context.allocator, context.config, context.catalog.path, resource_identity, parsed.value.identity, parsed.value.field, parsed.value.operation, parsed.value.values),
        else => return error.InvalidOwner,
    };
    mutation catch |err| switch (err) {
        error.ItemNotFound => return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"item.not_found\",\"message\":\"item identity does not exist\"}}\n", meta),
        error.DuplicateValue => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"property.duplicate_value\",\"message\":\"collection values must be unique\"}}\n", meta),
        error.ValueNotFound => return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"property.value_not_found\",\"message\":\"collection value does not exist\"}}\n", meta),
        else => return validationError(request, err, meta),
    };
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"item values persisted but snapshot publish failed\"}}\n", meta);
    return json(request, .ok, "{\"ok\":true,\"result\":{\"updated\":true}}\n", meta);
}

fn managementItemReplacement(request: zap.Request, context: *RouteContext, owner: cli_properties.Owner, identity: []const u8, body: []const u8, meta: RequestMeta) !void {
    const parsed = std.json.parseFromSlice(item_mutation.Replacement, context.allocator, body, .{ .allocate = .alloc_always }) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"item.invalid_request\",\"message\":\"invalid typed item replacement\"}}\n", meta);
    defer parsed.deinit();
    const spec = cli_properties.collection(owner, parsed.value.key) orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown structured collection\"}}\n", meta);
    if (spec.item_spec == null or spec.mutability != .mutable) return json(request, .unprocessable_content, "{\"ok\":false,\"error\":{\"code\":\"property.unsupported\",\"message\":\"collection does not support replacement\"}}\n", meta);
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    // ── force 模式：终止目标节点 session 后绕过全局 hasActive() 检查 ──
    if (parseForceFlag(request)) {
        if (owner == .node) {
            if (!forceTerminateNodeSessions(context, identity)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist forced session termination\"}}\n", meta);
        }
    } else if (context.sessions.hasActive(boot_session.monotonicNow())) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"item.active_session\",\"message\":\"item replacement is blocked by an active boot session; use --force to override\"}}\n", meta);
    const mutation = switch (owner) {
        .profile => item_mutation.replaceProfile(context.io, context.allocator, context.config, context.catalog.path, identity, parsed.value),
        .node => item_mutation.replaceNode(context.io, context.allocator, context.config, context.catalog.path, identity, parsed.value),
        else => return error.InvalidOwner,
    };
    mutation catch |err| switch (err) {
        error.UnsupportedProperty => return json(request, .unprocessable_content, "{\"ok\":false,\"error\":{\"code\":\"property.unsupported\",\"message\":\"collection replacement is not implemented\"}}\n", meta),
        else => return validationError(request, err, meta),
    };
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"items persisted but snapshot publish failed\"}}\n", meta);
    var output: [320]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&output, "{{\"ok\":true,\"result\":{{\"resource\":{f},\"key\":{f},\"operation\":{f},\"revision\":{d}}}}}\n", .{ std.json.fmt(identity, .{}), std.json.fmt(parsed.value.key, .{}), std.json.fmt(@tagName(parsed.value.operation), .{}), context.catalog.currentRevision() });
    return json(request, .ok, rendered, meta);
}

const ScalarMutationRequest = struct { mutations: []const scalar_mutation.Mutation };

fn managementScalarMutation(request: zap.Request, context: *RouteContext, owner: cli_properties.Owner, identity: []const u8, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.invalid_request\",\"message\":\"missing property request\"}}\n", meta);
    const parsed = std.json.parseFromSlice(ScalarMutationRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.invalid_request\",\"message\":\"mutations array is required\"}}\n", meta);
    defer parsed.deinit();
    if (parsed.value.mutations.len == 0) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.invalid_request\",\"message\":\"at least one scalar mutation is required\"}}\n", meta);
    for (parsed.value.mutations, 0..) |mutation, index| {
        const spec = cli_properties.property(owner, mutation.key) orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown scalar property\"}}\n", meta);
        if (spec.mutability != .mutable or (mutation.value == null and !spec.optional)) return json(request, .unprocessable_content, "{\"ok\":false,\"error\":{\"code\":\"property.required\",\"message\":\"required scalar cannot be unset\"}}\n", meta);
        for (parsed.value.mutations[0..index]) |prior| if (std.mem.eql(u8, prior.key, mutation.key)) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"property.duplicate\",\"message\":\"a scalar key may appear only once per atomic request\"}}\n", meta);
    }
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    // ── force 模式：终止目标节点 session 后绕过全局 hasActive() 检查 ──
    // node 变更：终止目标节点的 boot_session + diskless_delivery session。
    // profile 变更：仅绕过检查（profile 变更不影响活动 session 的不可变 plan）。
    if (parseForceFlag(request)) {
        if (owner == .node) {
            if (!forceTerminateNodeSessions(context, identity)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist forced session termination\"}}\n", meta);
        }
    } else if (context.sessions.hasActive(boot_session.monotonicNow())) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"property.active_session\",\"message\":\"property mutation is blocked by an active boot session; use --force to override\"}}\n", meta);
    const mutation = switch (owner) {
        .profile => scalar_mutation.profileBatch(context.io, context.allocator, context.config, context.catalog.path, identity, parsed.value.mutations),
        .node => scalar_mutation.nodeBatch(context.io, context.allocator, context.config, context.catalog.path, identity, parsed.value.mutations),
        else => return error.InvalidOwner,
    };
    mutation catch |err| switch (err) {
        error.UnknownProperty => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown scalar property\"}}\n", meta),
        error.InvalidPropertyValue => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.invalid_value\",\"message\":\"scalar value does not match PropertySpec\"}}\n", meta),
        else => return validationError(request, err, meta),
    };
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"property persisted but snapshot publish failed\"}}\n", meta);
    return json(request, .ok, "{\"ok\":true,\"result\":{\"updated\":true}}\n", meta);
}

fn managementItemsGet(request: zap.Request, context: *const RouteContext, owner: cli_properties.Owner, identity: []const u8, meta: RequestMeta) !void {
    const key = request.getParamSlice("key") orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.key_required\",\"message\":\"key query parameter is required\"}}\n", meta);
    const item_identity = request.getParamSlice("identity");
    if (request.getParamSlice("field")) |field| return managementItemValuesGet(request, context, owner, identity, key, item_identity orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"item.identity_required\",\"message\":\"item identity is required\"}}\n", meta), field, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"resource\":{f},\"key\":{f},\"items\":", .{ std.json.fmt(identity, .{}), std.json.fmt(key, .{}) });
    switch (owner) {
        .profile => {
            const profile = lookup.findProfile(context.catalog_snapshot.value(), identity) orelse return notFound(request, meta);
            if (std.mem.eql(u8, key, "install.storage.partitions")) {
                const configured = profile.install.storage.partitions;
                const automatic = [_]model.PartitionConfig{ .{ .id = "esp", .mount = "/boot/efi", .filesystem = "fat32", .size_mib = 1024, .kind = .esp }, .{ .id = "boot", .mount = "/boot", .filesystem = "ext4", .size_mib = 2048, .kind = .boot }, .{ .id = "root", .mount = "/", .filesystem = "ext4", .size_mib = 1, .grow = true, .kind = .root } };
                try writeFilteredItems(&output.writer, if (configured.len == 0) &automatic else configured, item_identity, "id");
            } else if (std.mem.eql(u8, key, "system.users")) try writeFilteredItems(&output.writer, profile.system.users, item_identity, "name") else return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown structured collection\"}}\n", meta);
        },
        .node => {
            const node = lookup.findNode(context.catalog_snapshot.value(), identity) orelse return notFound(request, meta);
            if (std.mem.eql(u8, key, "network.routes")) try writeFilteredItems(&output.writer, node.network.routes, item_identity, "id") else if (std.mem.eql(u8, key, "overrides.install.storage.partitions")) try writeFilteredItems(&output.writer, node.overrides.install.storage.partitions orelse &.{}, item_identity, "id") else if (std.mem.eql(u8, key, "effective.install.storage.partitions")) {
                var plan = @import("../profile/effective.zig").compile(context.allocator, context.catalog_snapshot.value(), node) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"effective.unavailable\",\"message\":\"effective plan is unavailable\"}}\n", meta);
                defer plan.deinit();
                try writeFilteredItems(&output.writer, plan.storage.partitions, item_identity, "id");
            } else if (std.mem.eql(u8, key, "overrides.system.users")) {
                if (node.overrides.system.users) |users| try writeFilteredItems(&output.writer, users, item_identity, "name") else {
                    const profile = lookup.findProfile(context.catalog_snapshot.value(), node.profile orelse return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"effective.unavailable\",\"message\":\"node has no profile\"}}\n", meta)) orelse return notFound(request, meta);
                    const system = @import("../profile/install.zig").effectiveSystem(profile) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"effective.unavailable\",\"message\":\"effective users unavailable\"}}\n", meta);
                    try writeFilteredItems(&output.writer, system.users, item_identity, "name");
                }
            } else return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown structured collection\"}}\n", meta);
        },
        else => return error.InvalidOwner,
    }
    try output.writer.print(",\"revision\":{d}}}}}\n", .{context.catalog_snapshot.revision});
    return json(request, .ok, output.written(), meta);
}

fn managementCapabilities(request: zap.Request, context: *const RouteContext, owner: cli_properties.Owner, identity: []const u8, meta: RequestMeta) !void {
    var target_node: ?*const model.NodeConfig = null;
    const profile = switch (owner) {
        .profile => lookup.findProfile(context.catalog_snapshot.value(), identity) orelse return notFound(request, meta),
        .node => blk: {
            const node = lookup.findNode(context.catalog_snapshot.value(), identity) orelse return notFound(request, meta);
            target_node = node;
            break :blk lookup.findProfile(context.catalog_snapshot.value(), node.profile orelse return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.profile_unassigned\",\"message\":\"node has no bound profile\"}}\n", meta)) orelse return notFound(request, meta);
        },
        else => return error.InvalidOwner,
    };
    const source = lookup.findInstallSource(context.catalog_snapshot.value(), profile.install_source) orelse return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"capabilities.platform_missing\",\"message\":\"profile install source is unavailable\"}}\n", meta);
    const capability = lookup.findDistroVersion(context.catalog_snapshot.value(), source.distro, source.version, source.arch) orelse return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"capabilities.platform_missing\",\"message\":\"profile platform capability is unavailable\"}}\n", meta);
    var readiness_issue: ?anyerror = null;
    config_validate.validateProfileSoftwareReadiness(context.catalog_snapshot.value(), profile) catch |err| {
        readiness_issue = err;
    };
    if (target_node) |node| {
        var effective: ?effective_compiler.Plan = effective_compiler.compile(context.allocator, context.catalog_snapshot.value(), node) catch |err| blk: {
            readiness_issue = err;
            break :blk null;
        };
        if (effective) |*plan| {
            defer plan.deinit();
            config_validate.validateEffectiveSoftwareReadiness(context.catalog_snapshot.value(), &plan.install_source, plan.software) catch |err| {
                readiness_issue = err;
            };
        }
    }
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"resource\":{f},\"profile\":{f},\"adapter\":{f},\"readiness\":", .{ std.json.fmt(identity, .{}), std.json.fmt(profile.name, .{}), std.json.fmt(@tagName(capability.install_adapter), .{}) });
    if (readiness_issue) |issue|
        try output.writer.print("{{\"install\":\"blocked\",\"issues\":[{{\"code\":{f},\"message\":\"effective install plan is not ready\"}}]}}", .{std.json.fmt(@errorName(issue), .{})})
    else
        try output.writer.writeAll("{\"install\":\"ready\",\"issues\":[]}");
    try output.writer.writeAll(",\"domains\":[");
    for (adapter_capabilities.entries, 0..) |entry, index| {
        if (index != 0) try output.writer.writeByte(',');
        const status = if (capability.install_adapter == .kickstart) entry.kickstart else entry.autoinstall;
        try output.writer.print("{{\"domain\":{f},\"status\":{f}}}", .{ std.json.fmt(entry.domain, .{}), std.json.fmt(@tagName(status), .{}) });
    }
    try output.writer.writeAll("],\"properties\":[");
    var first = true;
    for (cli_properties.properties) |spec| {
        if (spec.owner != owner or spec.mutability != .mutable) continue;
        if (!first) try output.writer.writeByte(',');
        first = false;
        const status = adapter_capabilities.status(capability.install_adapter, spec.path, spec.applicability);
        try output.writer.print("{{\"key\":{f},\"status\":{f}}}", .{ std.json.fmt(spec.path, .{}), std.json.fmt(@tagName(status), .{}) });
    }
    for (cli_properties.collections) |spec| {
        if (spec.owner != owner or spec.mutability != .mutable) continue;
        if (!first) try output.writer.writeByte(',');
        first = false;
        const status = adapter_capabilities.status(capability.install_adapter, spec.path, .all);
        try output.writer.print("{{\"key\":{f},\"status\":{f}}}", .{ std.json.fmt(spec.path, .{}), std.json.fmt(@tagName(status), .{}) });
    }
    try output.writer.writeAll("]}}\n");
    return json(request, .ok, output.written(), meta);
}

fn managementItemValuesGet(request: zap.Request, context: *const RouteContext, owner: cli_properties.Owner, resource_identity: []const u8, key: []const u8, item_identity: []const u8, field: []const u8, meta: RequestMeta) !void {
    const users = switch (owner) {
        .profile => blk: {
            if (!std.mem.eql(u8, key, "system.users")) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown structured collection\"}}\n", meta);
            const profile = lookup.findProfile(context.catalog_snapshot.value(), resource_identity) orelse return notFound(request, meta);
            break :blk profile.system.users;
        },
        .node => blk: {
            if (!std.mem.eql(u8, key, "overrides.system.users")) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown structured collection\"}}\n", meta);
            const node = lookup.findNode(context.catalog_snapshot.value(), resource_identity) orelse return notFound(request, meta);
            if (node.overrides.system.users) |values| break :blk values;
            const profile = lookup.findProfile(context.catalog_snapshot.value(), node.profile orelse return notFound(request, meta)) orelse return notFound(request, meta);
            break :blk profile.system.users;
        },
        else => return error.InvalidOwner,
    };
    const user = blk: {
        for (users) |*value| if (std.mem.eql(u8, value.name, item_identity)) break :blk value;
        return notFound(request, meta);
    };
    const values = if (std.mem.eql(u8, field, "groups")) user.groups else if (std.mem.eql(u8, field, "ssh_authorized_keys")) user.ssh_authorized_keys else return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"item.unknown_field\",\"message\":\"unknown item collection field\"}}\n", meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"resource\":{f},\"key\":{f},\"identity\":{f},\"field\":{f},\"values\":{f},\"revision\":{d}}}}}\n", .{ std.json.fmt(resource_identity, .{}), std.json.fmt(key, .{}), std.json.fmt(item_identity, .{}), std.json.fmt(field, .{}), std.json.fmt(values, .{}), context.catalog_snapshot.revision });
    return json(request, .ok, output.written(), meta);
}

fn writeFilteredItems(writer: *std.Io.Writer, items: anytype, identity: ?[]const u8, comptime field_name: []const u8) !void {
    try writer.writeByte('[');
    var first = true;
    for (items) |item| {
        const item_id = if (comptime std.mem.eql(u8, field_name, "name")) item.name else if (comptime @TypeOf(item) == model.RouteConfig) item.id else item.id orelse continue;
        if (identity != null and !std.mem.eql(u8, identity.?, item_id)) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try writer.print("{f}", .{std.json.fmt(item, .{})});
    }
    try writer.writeByte(']');
}

fn managementProfileCreate(request: zap.Request, context: *RouteContext, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"missing request body\"}}\n", meta);
    const parsed = std.json.parseFromSlice(ProfileCreateRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"name and install_source are required\"}}\n", meta);
    defer parsed.deinit();
    if (!config_validate.validLogicalId(parsed.value.name) or !config_validate.validLogicalId(parsed.value.install_source))
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"name and install_source must be canonical logical identifiers\"}}\n", meta);
    const kind: model.ProfileKind = if (parsed.value.kind) |k| std.meta.stringToEnum(model.ProfileKind, k) orelse
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.invalid\",\"message\":\"--kind must be install or diskless\"}}\n", meta) else .install;
    const boot_bundle = parsed.value.boot_bundle;
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    // v0.2.3 §5.1: 先按 §4.2 两阶段协议创建 identity（prepared journal 先于
    // identity 持久化），再发布引用它的 catalog，最后 commit 删除 journal。
    // 任何失败都幂等回滚（移除该 revision + journal），绝不留下"有 Profile、
    // 无 identity"的半成品；catalog 持久化成功后的 snapshot 发布失败不触发
    // 回滚（journal 已提交，磁盘状态一致，重启恢复即可收尾）。
    const now = std.Io.Clock.real.now(context.io).toSeconds();
    var tx: identity_store.IdentityTx = .{
        .old_catalog_revision = context.catalog.currentRevision(),
        .profile_name = parsed.value.name,
        .created_at = now,
    };
    const identity = context.identities.create(context.io, context.allocator, now, &tx) catch |err| switch (err) {
        error.IdentityStoreCapacity => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"identity.capacity\",\"message\":\"identity store capacity exhausted\"}}\n", meta),
        error.IdentityStagingDirUnset => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"identity.staging_unset\",\"message\":\"identity staging directory is not configured\"}}\n", meta),
        else => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"identity.create_failed\",\"message\":\"cannot create profile ssh identity\"}}\n", meta),
    };
    errdefer if (tx.transaction_id) |tx_id| context.identities.rollback(context.io, context.allocator, tx_id) catch {};
    const ssh_identity: model.ProfileSshIdentityRef = .{
        .id = identity.id,
        .revision = identity.revision,
        .client_public_fingerprint = identity.client_public_fingerprint,
        .host_public_fingerprint = identity.host_public_fingerprint,
    };
    @import("../config/profile_mutation.zig").addInstallProfile(context.io, context.allocator, context.config, context.catalog.path, parsed.value.name, parsed.value.install_source, kind, boot_bundle, ssh_identity) catch |err| switch (err) {
        error.ProfileAlreadyExists => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"profile.already_exists\",\"message\":\"profile name already exists\"}}\n", meta),
        error.InstallSourceNotFound => return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"profile.install_source_not_found\",\"message\":\"install source does not exist\"}}\n", meta),
        error.DisklessBootBundleRequired => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.boot_bundle_required\",\"message\":\"--kind diskless requires a boot bundle\"}}\n", meta),
        error.NonCanonicalProfileName => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.non_canonical_name\",\"message\":\"profile name must be <complete-install-source>[-<qualifier>]-<install|diskless>\"}}\n", meta),
        error.NonCanonicalBootBundleName => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.non_canonical_boot_bundle\",\"message\":\"diskless boot bundle name must retain the complete install-source prefix and end in -diskless-bundle\"}}\n", meta),
        else => return validationError(request, err, meta),
    };
    if (tx.transaction_id) |tx_id| {
        // catalog 已持久化，此后绝不能再由 errdefer 删除其 identity；若 journal
        // 删除失败，保留 journal 供启动恢复按 catalog 引用安全收尾。
        tx.transaction_id = null;
        context.identities.commit(context.io, context.allocator, tx_id) catch
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"identity.commit_failed\",\"message\":\"profile persisted but identity transaction cleanup failed\"}}\n", meta);
    }
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"profile persisted but snapshot publish failed\"}}\n", meta);
    var location: [320]u8 = undefined;
    try request.setHeader("location", try std.fmt.bufPrint(&location, "/api/v1/management/profiles/{s}", .{parsed.value.name}));
    // v0.2.3 §5.1: 响应含 revision/provenance/ssh_identity 后可达 ~600B（profile
    // 名 128 + 两个 59B 指纹 + 32B id + 结构开销）；512B 缓冲会在 bufPrint 返回
    // NoSpaceLeft，zap 随后回 200 空 body，破坏契约。放大到 1536B。
    var response: [1536]u8 = undefined;
    // §5.1: 响应增加 provenance 与 ssh_identity（identity 引用与指纹）。
    const rendered = try std.fmt.bufPrint(&response, "{{\"ok\":true,\"result\":{{\"name\":{f},\"mode\":{f},\"kind\":{f},\"install_source\":{f},\"boot_bundle\":{f},\"revision\":{d},\"provenance\":{{\"origin\":{f},\"install_source_revision\":{d}}},\"ssh_identity\":{{\"id\":{f},\"revision\":{d},\"client_public_fingerprint\":{f},\"host_public_fingerprint\":{f}}}}}\n", .{ std.json.fmt(parsed.value.name, .{}), std.json.fmt(@tagName(kind), .{}), std.json.fmt(@tagName(kind), .{}), std.json.fmt(parsed.value.install_source, .{}), std.json.fmt(boot_bundle, .{}), context.catalog.currentRevision(), std.json.fmt(@tagName(model.ProfileProvenanceOrigin.create), .{}), context.catalog.currentRevision(), std.json.fmt(identity.id, .{}), identity.revision, std.json.fmt(identity.client_public_fingerprint, .{}), std.json.fmt(identity.host_public_fingerprint, .{}) });
    try setRevisionEtag(request, context.catalog.currentRevision());
    return json(request, .created, rendered, meta);
}

fn managementProfileClone(request: zap.Request, context: *RouteContext, source: []const u8, meta: RequestMeta) !void {
    if (!jsonRequest(request)) return unsupportedMediaType(request, meta);
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.clone_invalid\",\"message\":\"target is required\"}}\n", meta);
    const parsed = std.json.parseFromSlice(ProfileCloneRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.clone_invalid\",\"message\":\"target is required\"}}\n", meta);
    defer parsed.deinit();
    if (!config_validate.validLogicalId(source) or !config_validate.validLogicalId(parsed.value.target))
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.clone_invalid\",\"message\":\"source and target must be canonical logical identifiers\"}}\n", meta);
    // v0.2.3 §5.2: `--detach` 必须与 `--build` 同用；单独使用是 CLI 输入错误。
    if (parsed.value.detach and !parsed.value.build)
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.clone_invalid\",\"message\":\"detach requires build\"}}\n", meta);
    // v0.2.3 §5.2: property patch 范围与 `profile set` 相同——只接受 mutable
    // 标量 key；集合键须走 values 命令；provenance/revision/ssh_identity 不在
    // PropertySpec 内，天然被拒绝。patch 在 clone 事务内应用（见 cloneProfile）。
    var patch_mutations: std.ArrayListUnmanaged(scalar_mutation.Mutation) = .empty;
    defer patch_mutations.deinit(context.allocator);
    if (parsed.value.properties) |properties_value| {
        if (properties_value != .object)
            return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.invalid_value\",\"message\":\"properties must be a JSON object\"}}\n", meta);
        const properties = properties_value.object;
        for (properties.keys(), properties.values()) |key, value| {
            if (cli_properties.collection(.profile, key) != null)
                return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.list_operation_required\",\"message\":\"structured collection keys require profile add-values/remove-values/replace-values/clear-values\"}}\n", meta);
            const spec = cli_properties.property(.profile, key) orelse
                return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown scalar profile property\"}}\n", meta);
            if (spec.mutability != .mutable)
                return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown scalar profile property\"}}\n", meta);
            try patch_mutations.append(context.allocator, .{
                .key = key,
                .value = switch (value) {
                    .string => |text| text,
                    .null => null,
                    else => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.invalid_value\",\"message\":\"property values must be strings\"}}\n", meta),
                },
            });
        }
    }
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    // v0.2.3 §5.2: `--build` 仅对 diskless Profile 有意义（target 继承 source
    // 的 kind）；install source 上显式 `--build` 是 CLI 输入错误（exit 2）。
    if (parsed.value.build) {
        const source_profile = lookup.findProfile(context.catalog_snapshot.value(), source) orelse return notFound(request, meta);
        if (source_profile.kind != .diskless)
            return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.clone_invalid\",\"message\":\"clone --build requires a diskless source profile\"}}\n", meta);
    }
    // v0.2.3 §5.2: `--new-ssh-keys` 时先按 §4.2 创建独立 identity 再克隆，
    // 失败幂等回滚；默认复用 source 的 identity 引用（null override）。
    var tx_opt: ?identity_store.IdentityTx = null;
    var identity_override: ?model.ProfileSshIdentityRef = null;
    if (parsed.value.new_ssh_keys) {
        const now = std.Io.Clock.real.now(context.io).toSeconds();
        var tx: identity_store.IdentityTx = .{
            .old_catalog_revision = context.catalog.currentRevision(),
            .profile_name = parsed.value.target,
            .created_at = now,
        };
        const identity = context.identities.create(context.io, context.allocator, now, &tx) catch |err| switch (err) {
            error.IdentityStoreCapacity => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"identity.capacity\",\"message\":\"identity store capacity exhausted\"}}\n", meta),
            error.IdentityStagingDirUnset => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"identity.staging_unset\",\"message\":\"identity staging directory is not configured\"}}\n", meta),
            else => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"identity.create_failed\",\"message\":\"cannot create clone ssh identity\"}}\n", meta),
        };
        identity_override = .{
            .id = identity.id,
            .revision = identity.revision,
            .client_public_fingerprint = identity.client_public_fingerprint,
            .host_public_fingerprint = identity.host_public_fingerprint,
        };
        tx_opt = tx;
    }
    errdefer if (tx_opt) |tx| if (tx.transaction_id) |tx_id| context.identities.rollback(context.io, context.allocator, tx_id) catch {};
    @import("../config/profile_mutation.zig").cloneProfile(context.io, context.allocator, context.config, context.catalog.path, source, parsed.value.target, identity_override, patch_mutations.items) catch |err| switch (err) {
        error.ProfileNotFound => return notFound(request, meta),
        error.ProfileAlreadyExists => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"profile.already_exists\",\"message\":\"target profile already exists\"}}\n", meta),
        error.InvalidProfileName => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.clone_invalid\",\"message\":\"target profile name is invalid\"}}\n", meta),
        error.UnknownProperty => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.unknown\",\"message\":\"unknown scalar profile property\"}}\n", meta),
        error.InvalidPropertyValue => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.invalid_value\",\"message\":\"property value does not match PropertySpec\"}}\n", meta),
        error.PropertyRequired => return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"property.required\",\"message\":\"required scalar cannot be unset\"}}\n", meta),
        else => return validationError(request, err, meta),
    };
    if (tx_opt) |*tx| if (tx.transaction_id) |tx_id| {
        tx.transaction_id = null;
        context.identities.commit(context.io, context.allocator, tx_id) catch
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"identity.commit_failed\",\"message\":\"profile clone persisted but identity transaction cleanup failed\"}}\n", meta);
    };
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"profile clone persisted but snapshot publish failed\"}}\n", meta);
    var location: [320]u8 = undefined;
    try request.setHeader("location", try std.fmt.bufPrint(&location, "/api/v1/management/profiles/{s}", .{parsed.value.target}));
    // §5.2/§8.4: 响应包含 `profile_created`/`build_submitted`；`--build` 时在
    // clone 提交后追加 rootfs build operation（提交失败不回滚 clone）。
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    if (!parsed.value.build) {
        try output.writer.print("{{\"ok\":true,\"result\":{{\"source\":{f},\"target\":{f},\"revision\":{d},\"new_ssh_keys\":{s},\"profile_created\":true,\"build_submitted\":false}}}}\n", .{ std.json.fmt(source, .{}), std.json.fmt(parsed.value.target, .{}), context.catalog.currentRevision(), if (parsed.value.new_ssh_keys) "true" else "false" });
        try setRevisionEtag(request, context.catalog.currentRevision());
        return json(request, .created, output.written(), meta);
    }
    const catalog = context.catalog_snapshot.value();
    const profile = lookup.findProfile(catalog, parsed.value.target) orelse
        return cloneBuildSubmitFailed(request, meta, "clone committed but target profile is missing");
    const digest = diskless.rootfsInputDigest(context.allocator, context.config, catalog, profile) catch
        return cloneBuildSubmitFailed(request, meta, "cannot compute rootfs input digest after clone");
    const digest_hex: []const u8 = digest[0..];
    // 缓存命中：内容寻址制品已 ready，build 视为已提交（幂等，不建 operation）。
    if (context.rootfs_artifacts.find(digest_hex)) |existing| {
        try output.writer.print("{{\"ok\":true,\"result\":{{\"source\":{f},\"target\":{f},\"revision\":{d},\"new_ssh_keys\":{s},\"profile_created\":true,\"build_submitted\":true,\"state\":\"already_present\",\"content_sha512\":{f},\"compressed_bytes\":{d},\"kernel_release\":{f},\"file\":{f}}}}}\n", .{ std.json.fmt(source, .{}), std.json.fmt(parsed.value.target, .{}), context.catalog.currentRevision(), if (parsed.value.new_ssh_keys) "true" else "false", std.json.fmt(existing.content_sha512, .{}), existing.compressed_size, std.json.fmt(existing.kernel_release, .{}), std.json.fmt(existing.file, .{}) });
        try setRevisionEtag(request, context.catalog.currentRevision());
        return json(request, .created, output.written(), meta);
    }
    var idempotency_key_buffer: [80]u8 = undefined;
    const idempotency_key = try std.fmt.bufPrint(&idempotency_key_buffer, "rootfs-{s}", .{digest_hex});
    const begun = context.operations.beginQueuedRequest(context.io, idempotency_key, digest_hex, .rootfs_build, unixNow()) catch
        return cloneBuildSubmitFailed(request, meta, "cannot create rootfs build operation");
    saveOperations(context) catch return cloneBuildSubmitFailed(request, meta, "cannot persist rootfs build operation");
    if (!begun.reused) {
        context.rootfs_worker.submit(begun.entry.idSlice(), profile.name, digest_hex) catch |err| {
            _ = context.operations.fail(begun.entry.idSlice(), if (err == error.RootfsBuildQueueFull) "rootfs.queue_full" else "rootfs.invalid_job", unixNow()) catch {};
            saveOperations(context) catch {};
            return cloneBuildSubmitFailed(request, meta, "rootfs build worker queue is unavailable");
        };
    }
    try output.writer.print("{{\"ok\":true,\"result\":{{\"source\":{f},\"target\":{f},\"revision\":{d},\"new_ssh_keys\":{s},\"profile_created\":true,\"build_submitted\":true,\"operation\":{{\"id\":{f},\"kind\":\"rootfs_build\",\"state\":{f},\"created_at\":{d},\"updated_at\":{d},\"result\":{f},\"error_code\":{f}}}}}}}\n", .{ std.json.fmt(source, .{}), std.json.fmt(parsed.value.target, .{}), context.catalog.currentRevision(), if (parsed.value.new_ssh_keys) "true" else "false", std.json.fmt(begun.entry.idSlice(), .{}), std.json.fmt(@tagName(begun.entry.state), .{}), begun.entry.created_at, begun.entry.updated_at, std.json.fmt(begun.entry.resultSlice(), .{}), std.json.fmt(begun.entry.errorSlice(), .{}) });
    var operation_location: [256]u8 = undefined;
    try request.setHeader("location", try std.fmt.bufPrint(&operation_location, "/api/v1/management/operations/{s}", .{begun.entry.idSlice()}));
    try setRevisionEtag(request, context.catalog.currentRevision());
    return json(request, .created, output.written(), meta);
}

/// v0.2.3 §8.4: clone 已提交但 build operation 提交失败时的复合响应：
/// `profile_created=true, build_submitted=false` + 稳定 error code
/// `rootfs.build_submit_failed`（CLI exit code 5）。不回滚已成功的 clone。
fn cloneBuildSubmitFailed(request: zap.Request, meta: RequestMeta, detail: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    const body = std.fmt.bufPrint(&buffer, "{{\"ok\":false,\"error\":{{\"code\":\"rootfs.build_submit_failed\",\"message\":{f}}},\"result\":{{\"profile_created\":true,\"build_submitted\":false}}}}\n", .{std.json.fmt(detail, .{})}) catch
        "{\"ok\":false,\"error\":{\"code\":\"rootfs.build_submit_failed\",\"message\":\"clone committed but build submission failed\"},\"result\":{\"profile_created\":true,\"build_submitted\":false}}\n";
    return json(request, .service_unavailable, body, meta);
}

/// 处理 Profile 删除请求。mutation mutex、model gate 与 `If-Match` 一起保证
/// 引用检查、持久化和内存 snapshot 发布串行发生；有 Node 引用时稳定返回
/// `profile.in_use`，不会隐式解绑或修改任何 Node。
fn managementProfileRemove(request: zap.Request, context: *RouteContext, name: []const u8, meta: RequestMeta) !void {
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    @import("../config/profile_mutation.zig").removeProfile(context.io, context.allocator, context.config, context.catalog.path, name) catch |err| switch (err) {
        error.ProfileNotFound => return notFound(request, meta),
        error.ProfileInUse => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"profile.in_use\",\"message\":\"profile is referenced by one or more nodes\"}}\n", meta),
        else => return validationError(request, err, meta),
    };
    applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"profile removed but snapshot publish failed\"}}\n", meta);
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
    // 在发布任一世代前先分配两个世代。调用方持有
    // model gate，因此读者看到的是旧配对或完整准备好的配对。
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

/// v0.2.3 §3.3: `new_ssh_keys` 为 true 时先轮换 identity revision 并发布
/// Profile（ssh_identity 引用 + revision+1），再以新投影提交 build。
const RootfsBuildRequest = struct { if_input_digest: ?[]const u8 = null, new_ssh_keys: bool = false };
const InitrdBuildRequest = struct {
    name: []const u8,
    install_source: []const u8,
    kernel_release: []const u8,
};

fn managementInitrdBuild(request: zap.Request, context: *RouteContext, meta: RequestMeta) !void {
    if (!jsonRequest(request)) return unsupportedMediaType(request, meta);
    const parsed = std.json.parseFromSlice(InitrdBuildRequest, context.allocator, request.body orelse "", .{ .allocate = .alloc_always }) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"initrd.invalid\",\"message\":\"name, install_source and kernel_release are required\"}}\n", meta);
    defer parsed.deinit();
    const value = parsed.value;
    if (!config_validate.validLogicalId(value.name) or !config_validate.validLogicalId(value.install_source) or value.kernel_release.len == 0 or value.kernel_release.len > initrd_field_cap or std.mem.indexOfAny(u8, value.kernel_release, "/\\\x00") != null)
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"initrd.invalid\",\"message\":\"initrd build inputs are invalid\"}}\n", meta);
    const catalog = context.catalog_snapshot.value();
    const source = lookup.findInstallSource(catalog, value.install_source) orelse return notFound(request, meta);
    const installer = lookup.findAsset(catalog, source.installer_initrd) orelse return validationError(request, error.MissingAsset, meta);
    if (installer.kind != .installer_initrd) return validationError(request, error.InvalidAssetKind, meta);
    if (lookup.findAsset(catalog, value.name)) |existing| {
        if (existing.kind == .nodeforge_initrd and optionalEqual(existing.distro, source.distro) and optionalEqual(existing.version, source.version) and existing.arch == source.arch and optionalEqual(existing.kernel_release, value.kernel_release))
            return json(request, .ok, "{\"ok\":true,\"result\":{\"state\":\"already_present\"}}\n", meta);
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"initrd.name_conflict\",\"message\":\"initrd name already identifies different metadata\"}}\n", meta);
    }
    var digest_input: std.Io.Writer.Allocating = .init(context.allocator);
    defer digest_input.deinit();
    try digest_input.writer.print("{s}\x00{s}\x00{s}", .{ value.name, value.install_source, value.kernel_release });
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(digest_input.written(), &raw, .{});
    var request_digest: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&request_digest, "{x}", .{raw}) catch unreachable;
    var key_buffer: [128]u8 = undefined;
    const key = request.getHeader("idempotency-key") orelse try std.fmt.bufPrint(&key_buffer, "initrd-{s}", .{request_digest[0..32]});
    const begun = context.operations.beginQueuedRequest(context.io, key, &request_digest, .initrd_build, unixNow()) catch |err|
        return json(request, .conflict, if (err == error.IdempotencyConflict)
            "{\"ok\":false,\"error\":{\"code\":\"operation.idempotency_conflict\",\"message\":\"Idempotency-Key was already used for another initrd input\"}}\n"
        else
            "{\"ok\":false,\"error\":{\"code\":\"operation.unavailable\",\"message\":\"cannot create initrd operation\"}}\n", meta);
    saveOperations(context) catch {
        _ = context.operations.fail(begun.entry.idSlice(), "operation.persist_failed", unixNow()) catch {};
        saveOperations(context) catch {};
        return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"operation.persist_failed\",\"message\":\"cannot persist initrd operation\"}}\n", meta);
    };
    if (!begun.reused) context.initrd_worker.submit(begun.entry.idSlice(), value.name, value.install_source, value.kernel_release) catch |err| {
        _ = context.operations.fail(begun.entry.idSlice(), if (err == error.InitrdBuildQueueFull) "initrd.queue_full" else "initrd.invalid_job", unixNow()) catch {};
        saveOperations(context) catch {};
        return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"initrd.queue_unavailable\",\"message\":\"initrd worker queue is unavailable\"}}\n", meta);
    };
    return operationResponse(request, begun.entry, true, meta);
}

/// `profile rootfs build`：从 Profile build projection 构建内容寻址 rootfs 制品。
/// daemon 用发行版原生 install-root 工具从 install source 受管 repository 构建
/// OS 层 lower，叠加 rootfs-build phase 步骤（managed_file/archive/script/package），
/// 再 mksquashfs 压缩，按 `rootfs_input_digest` 内容寻址登记。fail-closed：OS 层、
/// 任一 rootfs-build 步骤或 squashfs 压缩失败即放弃整次构建，不发布半成品。
///
/// rootfs 按 `rootfs_input_digest` 缓存：若该 digest 已有 ready 制品则直接命中
/// （幂等），不重复重构建。OS 层/chroot/squashfs 属环境相关执行边界（仅
/// Linux/root 构建主机可用，与 initrd/first_boot 一致）。
fn managementRootfsBuild(request: zap.Request, context: *RouteContext, name: []const u8, meta: RequestMeta) !void {
    if (!jsonRequest(request)) return unsupportedMediaType(request, meta);
    const body = request.body orelse "";
    var parsed_request: ?std.json.Parsed(RootfsBuildRequest) = null;
    defer if (parsed_request) |*parsed| parsed.deinit();
    if (body.len != 0) {
        parsed_request = std.json.parseFromSlice(RootfsBuildRequest, context.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch
            return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"rootfs.invalid\",\"message\":\"invalid request body\"}}\n", meta);
    }
    const if_input_digest = if (parsed_request) |parsed| parsed.value.if_input_digest else null;
    const new_ssh_keys = if (parsed_request) |parsed| parsed.value.new_ssh_keys else false;

    if (new_ssh_keys) {
        // v0.2.3 §3.3 操作序列：先创建新 identity revision（同 id，revision+1，
        // 旧 revision 保持不可变），再发布 Profile revision（ssh_identity 引用
        // 递增 + updated_at），随后用新投影提交 build。失败边界：
        // - identity 创建失败 → identity.create_failed（identity/Profile 均未发布）；
        // - Profile 发布失败 → catalog.publish_failed（identity 已写入，事务
        //   恢复立即回收该 revision）；
        // - build 提交失败 → rootfs.build_submit_failed（Profile 已发布，旧
        //   artifact 仍可消费，等价于"先改 Profile 再 build"普通序列）。
        while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
        defer config_mutation_mutex.unlock();
        context.models.lock();
        defer context.models.unlock();
        if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
        const snapshot = context.catalog_snapshot.value();
        const existing = lookup.findProfile(snapshot, name) orelse return notFound(request, meta);
        if (existing.kind != .diskless)
            return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.not_diskless\",\"message\":\"rootfs build is only available for diskless profiles\"}}\n", meta);
        if (existing.ssh_identity.id.len != identity_store.id_len)
            return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"identity.not_found\",\"message\":\"profile has no ssh identity to rotate\"}}\n", meta);
        const now = std.Io.Clock.real.now(context.io).toSeconds();
        var tx: identity_store.IdentityTx = .{
            .old_catalog_revision = context.catalog.currentRevision(),
            .profile_name = name,
            .created_at = now,
        };
        const identity = context.identities.createRevision(context.io, context.allocator, existing.ssh_identity.id, now, &tx) catch |err| switch (err) {
            error.IdentityNotFound => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"identity.not_found\",\"message\":\"identity referenced by profile is missing\"}}\n", meta),
            error.IdentityStoreCapacity => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"identity.capacity\",\"message\":\"identity store capacity exhausted\"}}\n", meta),
            else => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"identity.create_failed\",\"message\":\"cannot create new ssh identity revision\"}}\n", meta),
        };
        errdefer if (tx.transaction_id) |tx_id| context.identities.rollback(context.io, context.allocator, tx_id) catch {};
        const ssh_identity: model.ProfileSshIdentityRef = .{
            .id = identity.id,
            .revision = identity.revision,
            .client_public_fingerprint = identity.client_public_fingerprint,
            .host_public_fingerprint = identity.host_public_fingerprint,
        };
        @import("../config/profile_mutation.zig").rotateSshIdentity(context.io, context.allocator, context.config, context.catalog.path, name, ssh_identity) catch |err| switch (err) {
            error.ProfileNotFound => return notFound(request, meta),
            error.ProfileRevisionOverflow => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"profile.revision_overflow\",\"message\":\"profile revision overflow\"}}\n", meta),
            else => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"ssh identity rotation persisted but catalog publish failed\"}}\n", meta),
        };
        if (tx.transaction_id) |tx_id| {
            tx.transaction_id = null;
            context.identities.commit(context.io, context.allocator, tx_id) catch
                return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"identity.commit_failed\",\"message\":\"ssh identity rotation persisted but transaction cleanup failed\"}}\n", meta);
        }
        applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"ssh identity rotated but snapshot publish failed\"}}\n", meta);
    }

    const catalog = context.catalog_snapshot.value();
    const profile = lookup.findProfile(catalog, name) orelse return notFound(request, meta);
    if (profile.kind != .diskless) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.not_diskless\",\"message\":\"rootfs build is only available for diskless profiles\"}}\n", meta);

    const digest = diskless.rootfsInputDigest(context.allocator, context.config, catalog, profile) catch |err| return validationError(request, err, meta);
    const digest_hex: []const u8 = digest[0..];

    // 防漂移：调用方锁定预期 digest，不匹配则拒绝（readiness 不暗中触发漂移构建）。
    if (if_input_digest) |expected| if (!std.mem.eql(u8, expected, digest_hex))
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"rootfs.digest_drift\",\"message\":\"current rootfs input digest does not match if_input_digest\"}}\n", meta);

    // 缓存命中：该 digest 已有 ready 制品，幂等返回，不重构建。
    if (context.rootfs_artifacts.find(digest_hex)) |existing| {
        var output: std.Io.Writer.Allocating = .init(context.allocator);
        defer output.deinit();
        try output.writer.print("{{\"ok\":true,\"result\":{{\"profile\":{f},\"rootfs_input_digest\":{f},\"state\":\"already_present\",\"content_sha512\":{f},\"compressed_bytes\":{d},\"kernel_release\":{f},\"file\":{f}", .{ std.json.fmt(profile.name, .{}), std.json.fmt(digest_hex, .{}), std.json.fmt(existing.content_sha512, .{}), existing.compressed_size, std.json.fmt(existing.kernel_release, .{}), std.json.fmt(existing.file, .{}) });
        try output.writer.writeAll("}}\n");
        return json(request, .ok, output.written(), meta);
    }

    var idempotency_key_buffer: [80]u8 = undefined;
    const idempotency_key = request.getHeader("idempotency-key") orelse
        try std.fmt.bufPrint(&idempotency_key_buffer, "rootfs-{s}", .{digest_hex});
    const begun = context.operations.beginQueuedRequest(context.io, idempotency_key, digest_hex, .rootfs_build, unixNow()) catch |err|
        return json(request, .conflict, if (err == error.IdempotencyConflict)
            "{\"ok\":false,\"error\":{\"code\":\"operation.idempotency_conflict\",\"message\":\"Idempotency-Key was already used for a different rootfs input\"}}\n"
        else
            "{\"ok\":false,\"error\":{\"code\":\"operation.unavailable\",\"message\":\"cannot create rootfs build operation\"}}\n", meta);
    saveOperations(context) catch {
        _ = context.operations.fail(begun.entry.idSlice(), "operation.persist_failed", unixNow()) catch {};
        saveOperations(context) catch {};
        return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"operation.persist_failed\",\"message\":\"cannot persist rootfs build operation\"}}\n", meta);
    };
    if (!begun.reused) {
        context.rootfs_worker.submit(begun.entry.idSlice(), profile.name, digest_hex) catch |err| {
            _ = context.operations.fail(begun.entry.idSlice(), if (err == error.RootfsBuildQueueFull) "rootfs.queue_full" else "rootfs.invalid_job", unixNow()) catch {};
            saveOperations(context) catch {};
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"rootfs.queue_unavailable\",\"message\":\"rootfs build worker queue is unavailable\"}}\n", meta);
        };
    }
    return operationResponse(request, begun.entry, true, meta);
}

/// Worker-side rootfs build. It consumes a newly acquired immutable model pair,
/// rechecks the submitted input digest, and never touches an HTTP request.
/// 读取宿主 `/etc/os-release` 的 `ID_LIKE`/`ID`，判断构建主机是否为
/// Debian/Ubuntu family（casper overlay 假设与目标 Ubuntu diskless rootfs 同源
/// 工具链存在时的最佳情况；非 Debian family 宿主上 kernel-dependent 包仍可能
/// 因内核版本不一致失败，见 §5.1 CLI 提示）。读取失败按"非 Debian family"处理
/// （fail-closed 到"总是提示"，而不是静默假设安全）。
fn hostIsDebianFamily(io: std.Io, allocator: std.mem.Allocator) bool {
    const content = std.Io.Dir.cwd().readFileAlloc(io, "/etc/os-release", allocator, .limited(16 * 1024)) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, "ID_LIKE=debian") != null or
        std.mem.indexOf(u8, content, "ID=debian") != null or
        std.mem.indexOf(u8, content, "ID=ubuntu") != null;
}

fn performRootfsBuild(context: *RouteContext, name: []const u8, expected_digest: []const u8, operation_id: []const u8) !void {
    const catalog = context.catalog_snapshot.value();
    const profile = lookup.findProfile(catalog, name) orelse return error.MissingProfile;
    if (profile.kind != .diskless) return error.ProfileNotDiskless;
    const digest = try diskless.rootfsInputDigest(context.allocator, context.config, catalog, profile);
    const digest_hex: []const u8 = &digest;
    if (!std.mem.eql(u8, expected_digest, digest_hex)) return error.RootfsDigestDrift;
    if (context.rootfs_artifacts.find(digest_hex) != null) return;
    const bundle_name = profile.boot_bundle orelse return error.MissingBootBundle;
    const boot_bundle = lookup.findBootBundle(catalog, bundle_name) orelse return error.MissingBootBundle;
    const install_source = lookup.findInstallSource(catalog, profile.install_source) orelse return error.MissingInstallSource;
    const build_steps = try diskless.rootfsBuildSteps(context.allocator, context.config, catalog, profile);
    defer if (build_steps.len != 0) context.allocator.free(build_steps);

    // Worker-side builds consume the same managed repository closure directly
    // from disk; no daemon HTTP callback participates in the build.
    const base = try std.fmt.allocPrint(context.allocator, "file://{s}", .{paths.require().repos_dir});
    defer context.allocator.free(base);
    var repo_closure = try buildRepositoryClosure(context.allocator, catalog, profile, install_source, base);
    defer repo_closure.deinit(context.allocator);
    const dto_manager = repo_closure.package_manager orelse return error.NoPackageManager;
    const os_package_manager: model.PackageManager = switch (dto_manager) {
        .dnf => .dnf,
        .apt => .apt,
    };

    // staging 目录（digest 命名）：OS 层构建 + rootfs-build 步骤叠加。
    const work_dir = paths.require().work_dir;
    const staging = try std.fmt.allocPrint(context.allocator, "{s}/rootfs-build-{s}-{s}", .{ work_dir, digest_hex, operation_id });
    defer context.allocator.free(staging);
    std.Io.Dir.cwd().deleteTree(context.io, staging) catch {};
    try std.Io.Dir.cwd().createDirPath(context.io, staging);
    defer std.Io.Dir.cwd().deleteTree(context.io, staging) catch {};

    // 1. OS 层：dnf 走统一 namespace+chroot 隔离原语从受管 repository 构建；
    //    apt（Ubuntu）走同源 ISO 的 casper squashfs layer overlay。
    std.log.scoped(.rootfs_build).info("rootfs build [{s}]: stage 1/6 - building OS layer (staging={s})", .{ name, staging });
    var casper_layer_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (casper_layer_paths.items) |p| context.allocator.free(p);
        casper_layer_paths.deinit(context.allocator);
    }
    if (os_package_manager == .apt) {
        for (install_source.casper_layers) |layer| {
            const abs = try std.fmt.allocPrint(context.allocator, "{s}/{s}/{s}", .{ context.config.http.repository_root, install_source.name, layer.path });
            // catalog 中的完整 size/SHA-256 才是 layer 的不可变身份。不能只信
            // 当前受管目录路径，否则磁盘损坏或人工覆盖会让相同 input digest
            // 构建出不同 rootfs 内容。
            try verifyCasperLayer(context.io, abs, layer.size, layer.sha256);
            try casper_layer_paths.append(context.allocator, abs);
        }
        // §5.1：非 Ubuntu/Debian 宿主构建 Ubuntu diskless rootfs 时提示 kernel
        // 依赖风险（rootfs-build phase 的 *-dkms/kernel-*/kmod 类包可能因宿主
        // 内核版本与目标 casper 内核不一致而失败；纯用户态包不受影响）。
        if (!hostIsDebianFamily(context.io, context.allocator)) {
            std.log.scoped(.rootfs_build).warn(
                "rootfs build [{s}]: WARNING building Ubuntu diskless rootfs on a non-Ubuntu/Debian host. " ++
                    "OS layer uses the casper squashfs overlay (not apt/debootstrap from scratch); initrd is " ++
                    "extracted from the ISO's casper/initrd (host dracut is not used). Packages requiring kernel " ++
                    "headers/modules (*-dkms, kernel-*, kmod) may fail if the host kernel does not match the " ++
                    "target Ubuntu kernel; pure userspace packages are unaffected.",
                .{name},
            );
        }
    }
    // v0.2.3 §3.3: OS 层内从 identity store 按 profile 的 (id, revision) 读取
    // SSH keys 写入 staging（fail closed，不再构建期 ssh-keygen）。
    rootfs_os_builder.buildOsLayer(context.io, context.allocator, staging, os_package_manager, install_source.version, repo_closure.repository_urls, casper_layer_paths.items, context.identities, profile) catch |err| {
        std.log.scoped(.rootfs_build).err("rootfs build [{s}]: stage 1 FAILED - OS layer ({t})", .{ name, err });
        return err;
    };
    std.log.scoped(.rootfs_build).info("rootfs build [{s}]: stage 1/6 - OS layer done", .{name});

    // 2. 物化 rootfs-build content_asset 到 chroot 内 payload 目录。
    std.log.scoped(.rootfs_build).info("rootfs build [{s}]: stage 2/6 - materializing payload assets ({d} step(s))", .{ name, build_steps.len });
    var payload_paths = try context.allocator.alloc(?[]const u8, build_steps.len);
    defer context.allocator.free(payload_paths);
    for (payload_paths) |*p| p.* = null;
    var owned_payload_rel: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_payload_rel.items) |str| context.allocator.free(str);
        owned_payload_rel.deinit(context.allocator);
    }
    for (build_steps, 0..) |step, i| {
        const asset_name = step.content_asset orelse continue;
        const asset = lookup.findAsset(catalog, asset_name) orelse return error.MissingAsset;
        const rel = try std.fmt.allocPrint(context.allocator, "{s}/{d}", .{ asset.name, asset.revision });
        try owned_payload_rel.append(context.allocator, rel);
        payload_paths[i] = rel;
        const src = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ paths.require().assets_dir, asset.path });
        defer context.allocator.free(src);
        const dest = try std.fmt.allocPrint(context.allocator, "{s}/var/lib/nodeforge/payload/{s}", .{ staging, rel });
        defer context.allocator.free(dest);
        const parent = std.fs.path.dirname(dest) orelse dest;
        try std.Io.Dir.cwd().createDirPath(context.io, parent);
        try streamCopy(context.io, src, dest);
    }

    // 3. rootfs-build phase：编译固定顺序命令并执行（fail-closed）。
    //    package action 与 OS 层一致从 nodeforged HTTP 受管源安装到 staging
    //    （host 上下文，不进入 chroot），无需 bind-mount /dev/proc/sys；
    //    managed_file/archive/script 仍
    //    chroot 执行（写绝对路径到 staging lower）。两者都不接触公网。
    std.log.scoped(.rootfs_build).info("rootfs build [{s}]: stage 3/6 - executing rootfs-build steps ({d} step(s))", .{ name, build_steps.len });
    const plan = try rootfs_build_executor.buildPlan(context.allocator, build_steps, dto_manager, repo_closure.repository_urls, payload_paths, profile.install.apt.preserve_sources_list);
    defer plan.deinit(context.allocator);
    rootfs_build_executor.execute(context.io, context.allocator, staging, plan) catch |err| {
        std.log.scoped(.rootfs_build).err("rootfs build [{s}]: stage 3 FAILED - rootfs-build steps ({t})", .{ name, err });
        return err;
    };
    std.log.scoped(.rootfs_build).info("rootfs build [{s}]: stage 3/6 - rootfs-build steps done", .{name});

    // 4a. 注入 nodeforge-agent 和 firstboot systemd unit。
    //     agent 是 switch_root 后第一个执行的程序，因此是每个 rootfs 基线的必要组件，
    //     与 Profile 步骤无关。
    std.log.scoped(.rootfs_build).info("rootfs build [{s}]: stage 4/6 - injecting agent + firstboot unit", .{name});
    const agent_source = try std.fmt.allocPrint(context.allocator, "{s}/nodeforge-agent", .{paths.require().bin_dir});
    defer context.allocator.free(agent_source);
    const agent_dest = try std.fmt.allocPrint(context.allocator, "{s}/usr/sbin/nodeforge-agent", .{staging});
    defer context.allocator.free(agent_dest);
    try std.Io.Dir.copyFileAbsolute(agent_source, agent_dest, context.io, .{ .replace = true, .make_path = true });
    try runBuildCmd(context.io, context.allocator, &.{ "chmod", "0755", agent_dest });
    const firstboot_unit = try std.fmt.allocPrint(context.allocator, "{s}/etc/systemd/system/nodeforge-firstboot.service", .{staging});
    defer context.allocator.free(firstboot_unit);
    try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = firstboot_unit, .data =
        \\[Unit]
        \\Description=NodeForge diskless first-boot provisioning
        \\After=local-fs.target network-online.target
        \\Before=rc-local.service
        \\Wants=network-online.target
        \\ConditionPathExists=/var/lib/nodeforge/boot.json
        \\
        \\[Service]
        \\Type=oneshot
        \\ExecStart=/usr/sbin/nodeforge-agent
        \\RemainAfterExit=yes
        \\StandardOutput=journal+file:/var/lib/nodeforge/firstboot.log
        \\StandardError=journal+file:/var/lib/nodeforge/firstboot.log
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    });
    const firstboot_wants = try std.fmt.allocPrint(context.allocator, "{s}/etc/systemd/system/multi-user.target.wants", .{staging});
    defer context.allocator.free(firstboot_wants);
    try std.Io.Dir.cwd().createDirPath(context.io, firstboot_wants);
    const firstboot_link = try std.fmt.allocPrint(context.allocator, "{s}/nodeforge-firstboot.service", .{firstboot_wants});
    defer context.allocator.free(firstboot_link);
    try runBuildCmd(context.io, context.allocator, &.{ "ln", "-sfn", "../nodeforge-firstboot.service", firstboot_link });
    std.log.scoped(.rootfs_build).info("rootfs build [{s}]: stage 4/6 - agent + firstboot unit injected", .{name});

    // R9: 默认确保 /etc/rc.d/rc.local 可执行。Rocky/RHEL 系默认 rc.local 无执行权限，
    //     导致 install/diskless 后处理中写入的 rc.local 指令不会被执行。
    //     在 rootfs staging 中创建目录并 chmod +x，使节点启动后 rc-local.service 能正确执行。
    const rc_local_dir = try std.fmt.allocPrint(context.allocator, "{s}/etc/rc.d", .{staging});
    defer context.allocator.free(rc_local_dir);
    try std.Io.Dir.cwd().createDirPath(context.io, rc_local_dir);
    const rc_local_path = try std.fmt.allocPrint(context.allocator, "{s}/etc/rc.d/rc.local", .{staging});
    defer context.allocator.free(rc_local_path);
    if (std.Io.Dir.cwd().openFile(context.io, rc_local_path, .{})) |f| {
        f.close(context.io);
    } else |_| {
        try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = rc_local_path, .data = "#!/bin/sh\n" });
    }
    try runBuildCmd(context.io, context.allocator, &.{ "chmod", "0755", rc_local_path });

    // ── Stage 5/6：Profile 共享 SSH 信任基线 ──────────────────────────
    // 设计依据：DISKLESS_FINAL.md §4「Profile 共享 SSH keys」、
    //           V0_2_DESIGN.md §5.4 构建期与启动期边界表、
    //           V0_2_3_PROFILE_IDENTITY_AND_RECOVERY.md §3.3。
    //
    // v0.2.3 起 SSH 资产（client/host keypair、authorized_keys、
    // ssh_known_hosts、sshd drop-in）由 OS 层构建器从 identity store 按
    // `(ssh_identity.id, revision)` 复合键写入 staging
    // （`rootfs_os_builder.buildOsLayer` → `installIdentityKeys`，dnf 与
    // casper/apt 两分支一致），构建期不再调用 `ssh-keygen`；未命中返回
    // `IdentityNotFound` fail closed。此处仅为阶段日志，不再重复生成密钥。
    std.log.scoped(.rootfs_build).info("rootfs build [{s}]: stage 5/6 - SSH identity baseline installed from identity store", .{name});

    // ── Stage 6/6：squashfs 压缩 + SHA-512 校验 + 原子发布 ──────────
    // 设计依据：DISKLESS_FINAL.md §4「共享 rootfs 构建模型」、
    //           V0_2_DESIGN.md §5.4「rootfs 缓存与共享」。
    //
    // 使用 mksquashfs 将构建暂存目录压缩为只读下层镜像，压缩算法为 zstd。
    // 输出文件以 rootfs_input_digest 命名（内容寻址），先写请求独占的临时文件，
    // 再在发布临界区内原子改名。
    // SHA-512 流式校验确保下载端 initrd 可验证完整性。
    // 同一 rootfs_input_digest 的构建输出可跨 Node 共享，只增不删。
    std.log.scoped(.rootfs_build).info("rootfs build [{s}]: stage 6/6 - compressing squashfs + SHA-512", .{name});
    // 必须在压缩前统计目录树的逻辑占用字节数。squashfs 文件属性只能得到压缩后
    // 大小，不能将其当作临时文件系统或内存就绪检查所需的展开大小。
    const uncompressed_size = measureTreeApparentSize(context.io, context.allocator, staging) catch |err| blk: {
        std.log.scoped(.rootfs_build).warn("cannot measure rootfs uncompressed size ({t}); publishing with unknown size and skipping hard memory-capacity checks", .{err});
        break :blk 0;
    };
    const rootfs_dir = paths.require().rootfs_dir;
    try std.Io.Dir.cwd().createDirPath(context.io, rootfs_dir);
    const file_name = try @import("../provision/artifact_layout.zig").rootfsRelative(context.allocator, profile.name, digest_hex);
    defer context.allocator.free(file_name);
    const dest = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ rootfs_dir, file_name });
    defer context.allocator.free(dest);
    if (std.fs.path.dirname(dest)) |parent| try std.Io.Dir.cwd().createDirPath(context.io, parent);
    const part = try std.fmt.allocPrint(context.allocator, "{s}.part-{s}", .{ dest, operation_id });
    defer context.allocator.free(part);
    std.Io.Dir.cwd().deleteFile(context.io, part) catch {};
    errdefer std.Io.Dir.cwd().deleteFile(context.io, part) catch {};
    runBuildCmd(context.io, context.allocator, &.{ "mksquashfs", staging, part, "-noappend", "-no-progress", "-comp", "zstd" }) catch |err| {
        std.log.scoped(.rootfs_build).err("rootfs build [{s}]: stage 6 FAILED - mksquashfs ({t})", .{ name, err });
        return err;
    };

    // 5b. 流式计算 SHA-512（rootfs 可能有数 GB，使用固定大小缓冲区）。
    var sha = std.crypto.hash.sha2.Sha512.init(.{});
    var total_size: u64 = 0;
    {
        var f = try std.Io.Dir.cwd().openFile(context.io, part, .{ .follow_symlinks = false });
        defer f.close(context.io);
        var buf: [256 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n = try f.readPositionalAll(context.io, &buf, offset);
            if (n == 0) break;
            sha.update(buf[0..n]);
            offset += n;
            total_size += n;
        }
    }
    var sha512_raw: [64]u8 = undefined;
    sha.final(&sha512_raw);
    var content_sha512: [128]u8 = undefined;
    _ = std.fmt.bufPrint(&content_sha512, "{x}", .{sha512_raw}) catch unreachable;
    // 6. 在同一发布临界区内校验已有记录、原子替换文件并持久化登记。
    // 临时文件包含请求标识；相同摘要的并发构建不会共享或删除彼此的临时文件。
    const artifact: rootfs_artifact_store.Artifact = .{
        .rootfs_input_digest = digest_hex,
        .profile = profile.name,
        .content_sha512 = content_sha512[0..],
        .compressed_size = total_size,
        .uncompressed_size = uncompressed_size,
        .kernel_release = boot_bundle.kernel_release,
        .file = file_name,
        .created_at = unixNow(),
    };
    const result = try publishRootfsArtifact(context, part, dest, artifact);
    const state_str: []const u8 = @tagName(result);
    std.log.scoped(.rootfs_build).info("rootfs build [{s}]: DONE - state={s} file={s} size={d} bytes sha512={s}", .{ name, state_str, file_name, total_size, content_sha512[0..16] });
    return;
}

fn runRootfsBuildWorker(shared_context: *RouteContext, worker: *RootfsBuildWorker) void {
    while (true) {
        const job = worker.take() orelse {
            if (worker.stop.load(.acquire)) return;
            std.Io.sleep(shared_context.io, .fromMilliseconds(50), .awake) catch {};
            continue;
        };
        const operation_id: []const u8 = &job.operation_id;
        const profile = job.profile[0..job.profile_len];
        _ = shared_context.operations.start(operation_id, unixNow()) catch |err| {
            log.err("rootfs worker cannot start operation {s}: {t}", .{ operation_id, err });
            continue;
        };
        saveOperations(shared_context) catch |err| {
            log.err("rootfs worker cannot persist running operation {s}: {t}", .{ operation_id, err });
            _ = shared_context.operations.fail(operation_id, "operation.persist_failed", unixNow()) catch {};
            saveOperations(shared_context) catch |save_err|
                log.err("rootfs worker cannot persist persistence failure for operation {s}: {t}", .{ operation_id, save_err });
            continue;
        };

        const pair = shared_context.models.acquire();
        var context = shared_context.*;
        context.config = pair.config.value();
        context.config_revision = pair.config.revision;
        context.catalog_snapshot = pair.catalog;
        performRootfsBuild(&context, profile, &job.input_digest, operation_id) catch |err| {
            pair.release();
            var error_buffer: [96]u8 = undefined;
            const error_code = std.fmt.bufPrint(&error_buffer, "rootfs.{s}", .{@errorName(err)}) catch "rootfs.build_failed";
            log.err("rootfs build operation {s} failed for profile {s}: {t}", .{ operation_id, profile, err });
            _ = shared_context.operations.fail(operation_id, error_code, unixNow()) catch {};
            saveOperations(shared_context) catch |save_err|
                log.err("rootfs worker cannot persist failed operation {s}: {t}", .{ operation_id, save_err });
            continue;
        };
        pair.release();
        _ = shared_context.operations.succeed(operation_id, &job.input_digest, unixNow()) catch |err| {
            log.err("rootfs worker cannot complete operation {s}: {t}", .{ operation_id, err });
            continue;
        };
        saveOperations(shared_context) catch |err| {
            log.err("rootfs worker cannot persist completed operation {s}: {t}", .{ operation_id, err });
            _ = shared_context.operations.fail(operation_id, "operation.persist_failed", unixNow()) catch {};
            saveOperations(shared_context) catch |save_err|
                log.err("rootfs worker cannot persist terminal persistence failure for operation {s}: {t}", .{ operation_id, save_err });
        };
    }
}

fn performInitrdBuild(context: *RouteContext, name: []const u8, source_name: []const u8, kernel_release: []const u8, operation_id: []const u8) !void {
    const catalog = context.catalog_snapshot.value();
    const source = lookup.findInstallSource(catalog, source_name) orelse return error.MissingInstallSource;
    const installer = lookup.findAsset(catalog, source.installer_initrd) orelse return error.MissingAsset;
    if (installer.kind != .installer_initrd) return error.InvalidAssetKind;
    const relative = try artifact_layout.initrdRelative(context.allocator, name, kernel_release);
    defer context.allocator.free(relative);
    const destination = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ paths.require().initrd_dir, relative });
    defer context.allocator.free(destination);
    if (std.fs.path.dirname(destination)) |parent| try std.Io.Dir.cwd().createDirPath(context.io, parent);
    if (std.Io.Dir.cwd().statFile(context.io, destination, .{ .follow_symlinks = false })) |_| return error.InitrdAlreadyExists else |err| if (err != error.FileNotFound) return err;
    const part = try std.fmt.allocPrint(context.allocator, "{s}.part-{s}", .{ destination, operation_id });
    defer context.allocator.free(part);
    std.Io.Dir.cwd().deleteFile(context.io, part) catch {};
    errdefer std.Io.Dir.cwd().deleteFile(context.io, part) catch {};
    const base = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ context.config.tftp.asset_root, installer.path });
    defer context.allocator.free(base);
    const initrd_binary = try std.fmt.allocPrint(context.allocator, "{s}/nodeforge-initrd", .{paths.require().bin_dir});
    defer context.allocator.free(initrd_binary);
    const agent_binary = try std.fmt.allocPrint(context.allocator, "{s}/nodeforge-agent", .{paths.require().bin_dir});
    defer context.allocator.free(agent_binary);
    for ([_][]const u8{ initrd_binary, agent_binary }) |binary| {
        const stat = try std.Io.Dir.cwd().statFile(context.io, binary, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.MissingCompanionBinary;
    }
    try initrd_build_executor.buildFromInstaller(context.io, context.allocator, kernel_release, initrd_binary, base, part);
    var checksum: [64]u8 = undefined;
    try asset_validate.sha256File(context.io, std.fs.path.dirname(part) orelse return error.InvalidInitrdPath, std.fs.path.basename(part), &checksum);
    try std.Io.Dir.rename(std.Io.Dir.cwd(), part, std.Io.Dir.cwd(), destination, context.io);
    errdefer std.Io.Dir.cwd().deleteFile(context.io, destination) catch {};
    const asset: model.AssetConfig = .{
        .name = name,
        .kind = .nodeforge_initrd,
        .path = relative,
        .distro = source.distro,
        .version = source.version,
        .arch = source.arch,
        .kernel_release = kernel_release,
        .sha256 = &checksum,
    };
    context.models.lock();
    defer context.models.unlock();
    try context.catalog.addAsset(context.io, context.config, asset);
    try applyCatalogFromDisk(context);
}

fn runInitrdBuildWorker(shared_context: *RouteContext, worker: *InitrdBuildWorker) void {
    while (true) {
        const job = worker.take() orelse {
            if (worker.stop.load(.acquire)) return;
            std.Io.sleep(shared_context.io, .fromMilliseconds(50), .awake) catch {};
            continue;
        };
        const operation_id: []const u8 = &job.operation_id;
        _ = shared_context.operations.start(operation_id, unixNow()) catch |err| {
            log.err("initrd worker cannot start operation {s}: {t}", .{ operation_id, err });
            continue;
        };
        saveOperations(shared_context) catch |err| {
            log.err("initrd worker cannot persist running operation {s}: {t}", .{ operation_id, err });
            _ = shared_context.operations.fail(operation_id, "operation.persist_failed", unixNow()) catch {};
            saveOperations(shared_context) catch {};
            continue;
        };
        const pair = shared_context.models.acquire();
        var context = shared_context.*;
        context.config = pair.config.value();
        context.config_revision = pair.config.revision;
        context.catalog_snapshot = pair.catalog;
        const name = job.name[0..job.name_len];
        const source = job.source[0..job.source_len];
        const kernel_release = job.kernel_release[0..job.kernel_release_len];
        performInitrdBuild(&context, name, source, kernel_release, operation_id) catch |err| {
            pair.release();
            var error_buffer: [96]u8 = undefined;
            const error_code = std.fmt.bufPrint(&error_buffer, "initrd.{s}", .{@errorName(err)}) catch "initrd.build_failed";
            log.err("initrd build operation {s} failed for {s}: {t}", .{ operation_id, name, err });
            _ = shared_context.operations.fail(operation_id, error_code, unixNow()) catch {};
            saveOperations(shared_context) catch {};
            continue;
        };
        pair.release();
        _ = shared_context.operations.succeed(operation_id, name, unixNow()) catch |err| {
            log.err("initrd worker cannot complete operation {s}: {t}", .{ operation_id, err });
            continue;
        };
        saveOperations(shared_context) catch |err|
            log.err("initrd worker cannot persist completed operation {s}: {t}", .{ operation_id, err });
    }
}

/// v0.2.3 §7.3：ISO 导入 worker 主循环。daemon 启动时 spawn、停止时 join；
/// 队列容量为 1，worker 内保持 ISO 单并发（替代 handler 级互斥）。每次 job
/// 从 models 获取不可变世代对后执行 `performIsoImport`，终态经 operation
/// store 持久化；daemon restart 对 queued/running operation 统一恢复为
/// `operation.interrupted`（不自动重跑），孤儿 staging 由启动扫描清理。
fn runIsoImportWorker(shared_context: *RouteContext, worker: *IsoImportWorker) void {
    while (true) {
        const job = worker.take() orelse {
            if (worker.stop.load(.acquire)) return;
            std.Io.sleep(shared_context.io, .fromMilliseconds(50), .awake) catch {};
            continue;
        };
        const operation_id: []const u8 = &job.operation_id;
        _ = shared_context.operations.start(operation_id, unixNow()) catch |err| {
            log.err("iso import worker cannot start operation {s}: {t}", .{ operation_id, err });
            continue;
        };
        saveOperations(shared_context) catch |err| {
            log.err("iso import worker cannot persist running operation {s}: {t}", .{ operation_id, err });
            _ = shared_context.operations.fail(operation_id, "operation.persist_failed", unixNow()) catch {};
            saveOperations(shared_context) catch {};
            continue;
        };
        const pair = shared_context.models.acquire();
        var context = shared_context.*;
        context.config = pair.config.value();
        context.config_revision = pair.config.revision;
        context.catalog_snapshot = pair.catalog;
        const source_name = performIsoImport(&context, &job, operation_id) catch |err| {
            pair.release();
            var error_buffer: [96]u8 = undefined;
            const error_code = std.fmt.bufPrint(&error_buffer, "install_source.{s}", .{@errorName(err)}) catch "install_source.import_failed";
            log.err("ISO import operation {s} failed: {t}", .{ operation_id, err });
            _ = shared_context.operations.fail(operation_id, error_code, unixNow()) catch {};
            saveOperations(shared_context) catch {};
            continue;
        };
        pair.release();
        _ = shared_context.operations.succeed(operation_id, source_name, unixNow()) catch |err| {
            log.err("iso import worker cannot complete operation {s}: {t}", .{ operation_id, err });
            continue;
        };
        saveOperations(shared_context) catch |err|
            log.err("iso import worker cannot persist completed operation {s}: {t}", .{ operation_id, err });
    }
}

/// v0.2.3 §7.2/§7.4：ISO worker 执行体。运行 `importMedia`（staging 目录按
/// operation id 命名，`work/iso-import-<id>`），成功后发布 repository index
/// blob 与 catalog；失败路径不留下公开幽灵 artifact：importMedia 内部 defer
/// 清理未发布输出与 staging，catalog 发布失败调用 `cleanupPublishedOutputs`。
/// 返回 source_name（arena 承载，`operations.succeed` 会拷贝进固定缓冲区）。
fn performIsoImport(context: *RouteContext, job: *const IsoImportJob, operation_id: []const u8) ![]const u8 {
    // importMedia 构造大量彼此共享切片的临时 Result；CatalogRuntime 发布时
    // 深拷贝为独立 snapshot，因此每次 job 使用独立 arena，完成后统一释放，
    // 避免长生命周期 daemon allocator 随 ISO 导入次数增长。
    var import_arena = std.heap.ArenaAllocator.init(context.allocator);
    defer import_arena.deinit();
    const request = iso_import.Request{
        .filename = job.filename[0..job.filename_len],
        .original_filename = job.original_filename[0..job.original_filename_len],
        .name = if (job.name_len == 0) null else job.name[0..job.name_len],
        .qualifier = if (job.qualifier_len == 0) null else job.qualifier[0..job.qualifier_len],
        .distro = if (job.distro_len == 0) null else job.distro[0..job.distro_len],
        .version = if (job.version_len == 0) null else job.version[0..job.version_len],
        .arch = job.arch,
    };
    const imported = try iso_import.importMedia(context.io, import_arena.allocator(), context.config, request, operation_id);
    // ISO 扫描阶段已经拥有完整、稳定的软件能力索引，因此在 catalog 发布前
    // 生成内容寻址 blob。最终 InstallPlan 仍需等 Node/profile/generation 确定，
    // 但同一索引从此可被所有 profile、节点和 boot session 共享。
    for (imported.repositories) |repository| {
        const blob = repository_index_blob.publish(context.io, context.allocator, paths.require().repository_indexes_dir, repository.software_index) catch |err| {
            observe_log.err("ISO repository index blob publication failed: repository={s} error={t}", .{ repository.name, err });
            return error.RepositoryIndexBlobPublishFailed;
        };
        observe_log.info(
            "ISO repository index blob published: repository={s} digest={s} bytes={d} capabilities={d}",
            .{ repository.name, blob.digest[0..12], blob.bytes, repository.software_index.capabilities.len },
        );
    }
    context.models.lock();
    defer context.models.unlock();
    context.catalog.publishInstallSource(context.io, context.configs, context.config, context.config_revision, imported) catch |err| {
        // importMedia 已经将不可变文件复制到受管根目录。
        // 被拒绝的候选不得积累不可访问的 public-root 孤儿文件
        //（例如，ISO 覆盖产生了与既有同名 distro 不一致的 family）。
        iso_import.cleanupPublishedOutputs(context.io, context.allocator, context.config, &imported);
        observe_log.err("ISO catalog publication failed: {t}", .{err});
        return err;
    };
    return imported.source_name;
}

const RepoClosure = struct {
    package_manager: ?diskless_dto.FirstBootPackageManager,
    /// 目标节点运行期使用当前 nodeforged HTTP endpoint；后台构建 worker 则
    /// 把同一受管仓库身份重绑定为本机 file:// URL，直接消费受管内容。
    repository_urls: []const []const u8,

    pub fn deinit(self: RepoClosure, allocator: std.mem.Allocator) void {
        for (self.repository_urls) |url| allocator.free(url);
        allocator.free(self.repository_urls);
    }
};

/// 合并 install source 与 Profile software 的受管 repository 引用，去重后把每个
/// repository 的 `/artifacts/repositories/**` 路径重新绑定到 nodeforged 本机
/// 受管 repository 根。rootfs worker 不依赖 listener，daemon 停止时在途
/// operation 由 schema 2 loader 确定性恢复为 `operation.interrupted`。
fn buildRepositoryClosure(allocator: std.mem.Allocator, catalog: *const model.Catalog, profile: *const model.ProfileConfig, install_source: *const model.InstallSourceConfig, base: []const u8) !RepoClosure {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    for (install_source.repositories) |repository_name| try names.append(allocator, repository_name);
    for (profile.software.repositories) |repository_name| {
        var found = false;
        for (names.items) |existing| if (std.mem.eql(u8, existing, repository_name)) {
            found = true;
            break;
        };
        if (!found) try names.append(allocator, repository_name);
    }
    var urls: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (urls.items) |url| allocator.free(url);
        urls.deinit(allocator);
    }
    var package_manager: ?diskless_dto.FirstBootPackageManager = null;
    const repository_marker = "/artifacts/repositories/";
    for (names.items) |repository_name| {
        const repository = lookup.findRepository(catalog, repository_name) orelse return error.MissingRepository;
        const manager: diskless_dto.FirstBootPackageManager = switch (repository.manager) {
            .dnf => .dnf,
            .apt => .apt,
        };
        if (package_manager != null and package_manager.? != manager) return error.RepositoryManagerMismatch;
        package_manager = manager;
        const marker_index = std.mem.indexOf(u8, repository.base_url, repository_marker) orelse return error.ExternalEndpointForbidden;
        const managed_relative = repository.base_url[marker_index + repository_marker.len ..];
        if (managed_relative.len == 0) return error.ExternalEndpointForbidden;
        try urls.append(allocator, try managedRepositoryBuildUrl(allocator, base, managed_relative));
    }
    return .{
        .package_manager = package_manager,
        .repository_urls = try urls.toOwnedSlice(allocator),
    };
}

fn managedRepositoryBuildUrl(allocator: std.mem.Allocator, base: []const u8, relative: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{
        std.mem.trimEnd(u8, base, "/"),
        std.mem.trimStart(u8, relative, "/"),
    });
}

test "rootfs build repository URL uses the local managed repository root" {
    const allocator = std.testing.allocator;
    const url = try managedRepositoryBuildUrl(
        allocator,
        "file:///opt/nodeforge/assets/repos/",
        "/rocky-9.7-aarch64-minimal/Minimal",
    );
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "file:///opt/nodeforge/assets/repos/rocky-9.7-aarch64-minimal/Minimal",
        url,
    );
}

test "rootfs worker queue copies jobs and rejects overflow" {
    var worker: RootfsBuildWorker = .{};
    const operation_id = "0123456789abcdef0123456789abcdef";
    const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try worker.submit(operation_id, "profile-a", digest);
    const first = worker.take() orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(operation_id, &first.operation_id);
    try std.testing.expectEqualStrings("profile-a", first.profile[0..first.profile_len]);
    try std.testing.expectEqualStrings(digest, &first.input_digest);
    try std.testing.expect(worker.take() == null);

    for (0..max_rootfs_build_jobs) |_| try worker.submit(operation_id, "profile-a", digest);
    try std.testing.expectError(error.RootfsBuildQueueFull, worker.submit(operation_id, "profile-a", digest));
}

test "v0.2.3: iso worker queue holds one job and rejects concurrent submit" {
    var worker: IsoImportWorker = .{};
    const operation_id = "0123456789abcdef0123456789abcdef";
    var first: IsoImportJob = .{};
    @memcpy(&first.operation_id, operation_id);
    first.filename_len = 5;
    @memcpy(first.filename[0..5], "a.iso");
    first.original_filename_len = 5;
    @memcpy(first.original_filename[0..5], "a.iso");
    first.name_len = 3;
    @memcpy(first.name[0..3], "src");
    first.arch = .aarch64;
    try worker.submit(first);
    // 队列容量为 1：并发 submit 被拒绝（§7.5 单并发语义，handler 映射为
    // 409 install_source.busy）。
    try std.testing.expectError(error.IsoImportQueueFull, worker.submit(first));
    const taken = worker.take() orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(operation_id, &taken.operation_id);
    try std.testing.expectEqualStrings("a.iso", taken.filename[0..taken.filename_len]);
    try std.testing.expectEqualStrings("a.iso", taken.original_filename[0..taken.original_filename_len]);
    try std.testing.expectEqualStrings("src", taken.name[0..taken.name_len]);
    try std.testing.expectEqual(@as(?model.Arch, .aarch64), taken.arch);
    try std.testing.expect(worker.take() == null);
    // 取走后新 job 可入队。
    try worker.submit(first);
    _ = worker.take() orelse return error.TestExpectedEqual;
    // 非法 job（缺 filename）被拒绝。
    var invalid: IsoImportJob = .{};
    @memcpy(&invalid.operation_id, operation_id);
    try std.testing.expectError(error.InvalidIsoImportJob, worker.submit(invalid));
}

test "AgentPlan first-boot metadata follows profile default and node override" {
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.0.2.1", .http_port = 18080 } };
    const source: model.InstallSourceConfig = .{
        .name = "source",
        .distro = "rocky",
        .version = "9",
        .arch = .aarch64,
        .source_asset = "iso",
        .installer_kernel = "installer-kernel",
        .installer_initrd = "installer-initrd",
    };
    const boot_bundle: model.BootBundleConfig = .{
        .name = "boot-assets",
        .distro = "rocky",
        .version = "9",
        .arch = .aarch64,
        .kernel_release = "5.14.0",
        .kernel = "kernel",
        .initrd = "initrd",
    };
    const profile_bundle: model.ProvisioningBundle = .{ .name = "profile-firstboot" };
    const node_bundle: model.ProvisioningBundle = .{ .name = "node-firstboot" };
    const profile: model.ProfileConfig = .{
        .name = "profile",
        .install_source = "source",
        .kind = .diskless,
        .boot_bundle = "boot-assets",
        .bundle = "profile-firstboot",
    };
    const nodes = [_]model.NodeConfig{
        .{ .id = "profile-default", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "profile" },
        .{
            .id = "node-override",
            .mac = "02:00:00:00:00:02",
            .arch = .aarch64,
            .profile = "profile",
            .overrides = .{ .diskless = .{ .provision = .{ .bundle = "node-firstboot" } } },
        },
    };
    const catalog: model.Catalog = .{
        .profiles = &.{profile},
        .nodes = &nodes,
        .install_sources = &.{source},
        .boot_bundles = &.{boot_bundle},
        .provisioning_bundles = &.{ profile_bundle, node_bundle },
    };

    var inherited = try diskless.compile(std.testing.allocator, &config, &catalog, &nodes[0]);
    defer inherited.deinit();
    try std.testing.expectEqualStrings("profile-firstboot", effectiveFirstBootBundle(&inherited).?);
    try std.testing.expect(!std.mem.eql(u8, "boot-assets", effectiveFirstBootBundle(&inherited).?));

    var overridden = try diskless.compile(std.testing.allocator, &config, &catalog, &nodes[1]);
    defer overridden.deinit();
    try std.testing.expectEqualStrings("node-firstboot", effectiveFirstBootBundle(&overridden).?);
}

/// 流式拷贝文件（固定缓冲，不整块读入内存）。
fn streamCopy(io: std.Io, src: []const u8, dest: []const u8) !void {
    var in_file = std.Io.Dir.cwd().openFile(io, src, .{ .follow_symlinks = false }) catch |err| return err;
    defer in_file.close(io);
    var out_file = std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true }) catch |err| return err;
    defer out_file.close(io);
    var buf: [256 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try in_file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        try out_file.writeStreamingAll(io, buf[0..n]);
        offset += n;
    }
    try out_file.sync(io);
}

/// 在解包前重新验证已发布 casper layer，保证 catalog 中记录的不可变输入身份
/// 与磁盘实际内容一致。使用固定缓冲流式计算，避免大型 squashfs 占用堆内存。
fn verifyCasperLayer(io: std.Io, path: []const u8, expected_size: u64, expected_sha256: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.CasperLayerNotRegularFile;
    if (stat.size != expected_size) return error.CasperLayerSizeMismatch;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [256 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositionalAll(io, &buffer, offset);
        if (count == 0) break;
        hasher.update(buffer[0..count]);
        offset += count;
    }
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    var actual: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&actual, "{x}", .{raw}) catch unreachable;
    if (!std.mem.eql(u8, &actual, expected_sha256)) return error.CasperLayerDigestMismatch;
}

/// 提交一个已经完整写入并同步到磁盘的 rootfs 临时文件。
///
/// 相同输入摘要的检查、正式文件原子改名和制品存储持久化由同一把变更互斥锁
/// 串行化。已有制品时先执行不可变元数据校验，绝不替换正式文件；新制品只有在
/// 原子改名成功后才登记，登记失败则删除刚发布但尚无记录的文件。
fn publishRootfsArtifact(
    context: *RouteContext,
    temporary_path: []const u8,
    destination_path: []const u8,
    artifact: rootfs_artifact_store.Artifact,
) !rootfs_artifact_store.RegisterResult {
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();

    if (context.rootfs_artifacts.find(artifact.rootfs_input_digest) != null) {
        const result = try context.rootfs_artifacts.register(context.io, artifact);
        std.Io.Dir.cwd().deleteFile(context.io, temporary_path) catch {};
        return result;
    }

    try std.Io.Dir.rename(std.Io.Dir.cwd(), temporary_path, std.Io.Dir.cwd(), destination_path, context.io);
    _ = context.rootfs_artifacts.register(context.io, artifact) catch |err| {
        // 当前锁内已证明该输入摘要尚无记录，因此目标路径不可能属于另一个
        // 已发布制品；持久化失败时删除它，避免留下无记录的半发布文件。
        std.Io.Dir.cwd().deleteFile(context.io, destination_path) catch {};
        return err;
    };
    return .registered;
}

/// 运行构建期 OS 命令，退出码非 0 返回 BuildStepFailed。
fn runBuildCmd(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(65536), .stderr_limit = .limited(65536) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.log.scoped(.rootfs_build).err("build cmd failed ({s}): {s}", .{ argv[0], result.stderr });
                return error.BuildStepFailed;
            }
        },
        else => {
            std.log.scoped(.rootfs_build).err("build cmd did not exit cleanly ({s})", .{argv[0]});
            return error.BuildStepFailed;
        },
    }
}

/// 返回目录树的表观大小（普通文件逻辑字节数）。rootfs 构建只在 Linux 构建主机
/// 运行，使用 GNU coreutils 的 `du -sb`；该值在 mksquashfs 前采集，与压缩文件
/// 大小保持清晰区分。
fn measureTreeApparentSize(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !u64 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "du", "-sb", "--", path },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.RootfsSizeProbeFailed,
        else => return error.RootfsSizeProbeFailed,
    }
    var fields = std.mem.tokenizeAny(u8, result.stdout, " \t\r\n");
    const first = fields.next() orelse return error.RootfsSizeProbeFailed;
    const size = std.fmt.parseInt(u64, first, 10) catch return error.RootfsSizeProbeFailed;
    if (size == 0) return error.RootfsSizeProbeFailed;
    return size;
}

const RootfsRegisterRequest = struct {
    path: []const u8,
    /// 外部 squashfs 无法从压缩文件大小可靠推导逻辑展开大小。0/缺失表示未知；
    /// 登记仍然成功，但 readiness/initrd 不得据此执行内存容量硬校验。
    uncompressed_size: u64 = 0,
};

/// `profile rootfs plan`：编译 diskless Profile 的 `rootfs_input_digest`（Node-independent）
/// 并报告该 digest 是否已有 ready 制品（cache_state）。不要求存在 Node 或 deploy=true。
fn managementRootfsPlan(request: zap.Request, context: *RouteContext, name: []const u8, meta: RequestMeta) !void {
    const catalog = context.catalog_snapshot.value();
    const profile = lookup.findProfile(catalog, name) orelse return notFound(request, meta);
    if (profile.kind != .diskless) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.not_diskless\",\"message\":\"rootfs plan is only available for diskless profiles\"}}\n", meta);
    const digest = diskless.rootfsInputDigest(context.allocator, context.config, catalog, profile) catch |err| return validationError(request, err, meta);
    const digest_hex: []const u8 = digest[0..];
    const artifact = context.rootfs_artifacts.find(digest_hex);
    const cache_state: []const u8 = if (artifact != null) "ready" else "miss";
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"profile\":{f},\"rootfs_input_digest\":{f},\"cache_state\":{f}", .{ std.json.fmt(profile.name, .{}), std.json.fmt(digest_hex, .{}), std.json.fmt(cache_state, .{}) });
    if (artifact) |a| {
        try output.writer.print(",\"content_sha512\":{f},\"compressed_bytes\":{d},\"uncompressed_bytes\":", .{ std.json.fmt(a.content_sha512, .{}), a.compressed_size });
        if (a.uncompressed_size == 0) try output.writer.writeAll("null") else try output.writer.print("{d}", .{a.uncompressed_size});
        try output.writer.print(",\"kernel_release\":{f},\"file\":{f}", .{ std.json.fmt(a.kernel_release, .{}), std.json.fmt(a.file, .{}) });
    }
    try output.writer.writeAll("}}\n");
    return json(request, .ok, output.written(), meta);
}

/// `profile rootfs register`：登记一个已构建 rootfs 制品（测试/导入用）。daemon 从
/// Profile 编译 `rootfs_input_digest`，校验文件 sha512+size，内容寻址拷贝到 rootfs_dir，
/// 再经 rootfs_artifact_store 幂等登记（同 digest sha512 一致则静默成功，漂移则拒绝）。
fn managementRootfsRegister(request: zap.Request, context: *RouteContext, name: []const u8, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"rootfs.invalid\",\"message\":\"missing request body\"}}\n", meta);
    const parsed = std.json.parseFromSlice(RootfsRegisterRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"rootfs.invalid\",\"message\":\"path is required\"}}\n", meta);
    defer parsed.deinit();
    if (parsed.value.path.len == 0) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"rootfs.invalid\",\"message\":\"path is required\"}}\n", meta);
    if (parsed.value.uncompressed_size == 0)
        std.log.scoped(.rootfs).warn("registering external rootfs for profile {s} without uncompressed_size; hard memory-capacity checks will be skipped", .{name});
    const catalog = context.catalog_snapshot.value();
    const profile = lookup.findProfile(catalog, name) orelse return notFound(request, meta);
    if (profile.kind != .diskless) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.not_diskless\",\"message\":\"rootfs register is only available for diskless profiles\"}}\n", meta);
    const digest = diskless.rootfsInputDigest(context.allocator, context.config, catalog, profile) catch |err| return validationError(request, err, meta);
    const digest_hex: []const u8 = digest[0..];
    const bundle_name = profile.boot_bundle orelse return validationError(request, error.MissingBootBundle, meta);
    const boot_bundle = lookup.findBootBundle(catalog, bundle_name) orelse return validationError(request, error.MissingBootBundle, meta);
    const cwd = std.Io.Dir.cwd();
    // 流式导入：rootfs 可能数 GB，不能整块读入内存。边读边算 SHA-512、边写
    // 内容寻址目标文件（先写 .part 再原子 rename），仅持有固定缓冲。
    const rootfs_dir = paths.require().rootfs_dir;
    cwd.createDirPath(context.io, rootfs_dir) catch {};
    const file_name = try @import("../provision/artifact_layout.zig").rootfsRelative(context.allocator, profile.name, digest_hex);
    defer context.allocator.free(file_name);
    const dest = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ rootfs_dir, file_name });
    defer context.allocator.free(dest);
    if (std.fs.path.dirname(dest)) |parent| try cwd.createDirPath(context.io, parent);
    const tmp = try std.fmt.allocPrint(context.allocator, "{s}.part-{s}", .{ dest, &meta.request_id });
    defer context.allocator.free(tmp);
    errdefer cwd.deleteFile(context.io, tmp) catch {};

    var src_file = cwd.openFile(context.io, parsed.value.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"rootfs.file_not_found\",\"message\":\"rootfs file does not exist\"}}\n", meta),
        else => return validationError(request, err, meta),
    };
    defer src_file.close(context.io);
    const src_stat = src_file.stat(context.io) catch |err| return validationError(request, err, meta);
    if (src_stat.kind != .file) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"rootfs.invalid\",\"message\":\"rootfs path is not a regular file\"}}\n", meta);
    const total_size: u64 = src_stat.size;

    var sha = std.crypto.hash.sha2.Sha512.init(.{});
    {
        var out_file = cwd.createFile(context.io, tmp, .{ .truncate = true }) catch |err| return validationError(request, err, meta);
        defer out_file.close(context.io);
        var buf: [256 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (true) {
            const n = src_file.readPositionalAll(context.io, &buf, offset) catch |err| return validationError(request, err, meta);
            if (n == 0) break;
            sha.update(buf[0..n]);
            out_file.writeStreamingAll(context.io, buf[0..n]) catch |err| return validationError(request, err, meta);
            offset += n;
        }
        out_file.sync(context.io) catch |err| return validationError(request, err, meta);
    }
    var sha512_raw: [64]u8 = undefined;
    sha.final(&sha512_raw);
    var content_sha512: [128]u8 = undefined;
    _ = std.fmt.bufPrint(&content_sha512, "{x}", .{sha512_raw}) catch unreachable;
    const artifact: rootfs_artifact_store.Artifact = .{
        .rootfs_input_digest = digest_hex,
        .profile = profile.name,
        .content_sha512 = content_sha512[0..],
        .compressed_size = total_size,
        .uncompressed_size = parsed.value.uncompressed_size,
        .kernel_release = boot_bundle.kernel_release,
        .file = file_name,
        .created_at = unixNow(),
    };
    const result = publishRootfsArtifact(context, tmp, dest, artifact) catch |err| switch (err) {
        error.RootfsDigestDrift, error.RootfsMetadataDrift => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"rootfs.digest_drift\",\"message\":\"a different rootfs is already registered for this profile build\"}}\n", meta),
        else => return validationError(request, err, meta),
    };
    const state_str: []const u8 = @tagName(result);
    const effective_uncompressed_size = context.rootfs_artifacts.find(digest_hex).?.uncompressed_size;
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"profile\":{f},\"rootfs_input_digest\":{f},\"state\":{f},\"content_sha512\":{f},\"compressed_bytes\":{d},\"kernel_release\":{f},\"file\":{f}", .{ std.json.fmt(profile.name, .{}), std.json.fmt(digest_hex, .{}), std.json.fmt(state_str, .{}), std.json.fmt(content_sha512[0..], .{}), total_size, std.json.fmt(boot_bundle.kernel_release, .{}), std.json.fmt(file_name, .{}) });
    if (effective_uncompressed_size != 0)
        try output.writer.print(",\"uncompressed_bytes\":{d},\"warnings\":[]", .{effective_uncompressed_size})
    else
        try output.writer.writeAll(",\"uncompressed_bytes\":null,\"warnings\":[{\"code\":\"rootfs.uncompressed_size_unknown\",\"message\":\"uncompressed rootfs size is unknown; hard memory-capacity checks will be skipped\"}]");
    try output.writer.writeAll("}}\n");
    return json(request, .created, output.written(), meta);
}

/// `profile rootfs status`：报告 Profile 当前 rootfs_input_digest 对应的 ready 制品。
fn managementRootfsStatus(request: zap.Request, context: *RouteContext, name: []const u8, meta: RequestMeta) !void {
    const catalog = context.catalog_snapshot.value();
    const profile = lookup.findProfile(catalog, name) orelse return notFound(request, meta);
    if (profile.kind != .diskless) return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.not_diskless\",\"message\":\"rootfs status is only available for diskless profiles\"}}\n", meta);
    const digest = diskless.rootfsInputDigest(context.allocator, context.config, catalog, profile) catch |err| return validationError(request, err, meta);
    const digest_hex: []const u8 = digest[0..];
    const artifact = context.rootfs_artifacts.find(digest_hex);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    if (artifact) |a| {
        try output.writer.print("{{\"ok\":true,\"result\":{{\"profile\":{f},\"rootfs_input_digest\":{f},\"state\":\"ready\",\"content_sha512\":{f},\"compressed_bytes\":{d},\"uncompressed_bytes\":", .{ std.json.fmt(profile.name, .{}), std.json.fmt(digest_hex, .{}), std.json.fmt(a.content_sha512, .{}), a.compressed_size });
        if (a.uncompressed_size == 0) try output.writer.writeAll("null") else try output.writer.print("{d}", .{a.uncompressed_size});
        try output.writer.print(",\"kernel_release\":{f},\"file\":{f},\"created_at\":{d}", .{ std.json.fmt(a.kernel_release, .{}), std.json.fmt(a.file, .{}), a.created_at });
    } else {
        try output.writer.print("{{\"ok\":true,\"result\":{{\"profile\":{f},\"rootfs_input_digest\":{f},\"state\":\"miss\"", .{ std.json.fmt(profile.name, .{}), std.json.fmt(digest_hex, .{}) });
    }
    try output.writer.writeAll("}}\n");
    return json(request, .ok, output.written(), meta);
}

/// 将 credential `Decision` 映射为对外的稳定错误信封 JSON。
///
/// 安全策略（§10 分域能力令牌）：
/// - `expired` 单独返回 `diskless.token_expired`，允许 initrd/agent 据此区分
///   "token 过期需重新 boot-prepare"与"token 被篡改/越权"，实现精准重试；
/// - 其余 decision（`invalid_token`/`scope_mismatch`/`node_mismatch`/
///   `path_not_allowed`/`content_mismatch`/`event_seq_mismatch`）仍归为笼统的
///   `diskless.unauthorized`，避免向客户端泄露具体失败原因（防探测攻击）。
///
/// 返回的 JSON 字面量是编译期常量，不涉及分配；调用方直接传给 `json()`
/// 即可，`appendRequestId` 会自动补充 `request_id` 字段。
/// 具体的 decision 值由调用方在 `observe_log.warn` 中记录，不进入 HTTP 响应。
fn disklessCredentialError(decision: diskless_credential.Decision) []const u8 {
    return switch (decision) {
        .expired => "{\"ok\":false,\"error\":{\"code\":\"diskless.token_expired\",\"message\":\"capability token has expired\"}}\n",
        .recovery_incomplete => "{\"ok\":false,\"error\":{\"code\":\"capability.recovery_incomplete\",\"message\":\"session capability cannot be reconstructed after daemon restart\"}}\n",
        else => "{\"ok\":false,\"error\":{\"code\":\"diskless.unauthorized\",\"message\":\"diskless credential verification failed\"}}\n",
    };
}

/// v0.2 diskless BootConfig v3 交付。initrd 用 capsule 交付的 config-token +
/// X-NodeForge-Session 认证后返回 immutable rootfs + AgentPlan 定位器。四类
/// capability 已由 boot-prepare 签发并通过 capsule 分离交付，BootConfig 不含 token。
fn disklessBootConfig(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const config_token = parseBearer(request.getHeader("authorization")) orelse
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.token_required\",\"message\":\"Authorization: Bearer <config-token> is required\"}}\n", meta);
    const session_hdr = request.getHeader("x-nodeforge-session") orelse
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.session_required\",\"message\":\"X-NodeForge-Session header is required\"}}\n", meta);
    const session = context.diskless_store.find(session_hdr) orelse
        return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"diskless.session_not_found\",\"message\":\"no diskless session found\"}}\n", meta);
    if (!std.mem.eql(u8, session.nodeId(), node_id))
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.node_mismatch\",\"message\":\"session does not belong to this node\"}}\n", meta);
    const decision = context.diskless_store.verify(session_hdr, config_token, .config, node_id, "", session.rootfsSha512(), 0, boot_session.monotonicNow());
    // 凭证校验失败：日志记录具体 decision（如 invalid_token/expired/scope_mismatch），
    // 供运维定位；HTTP 响应只对外暴露笼统的 unauthorized 或 token_expired（见
    // disklessCredentialError），不泄露具体原因以防探测。此前此路径缺失日志，
    // 导致 5 种不同安全语义的失败在日志中无法区分。
    if (decision != .ok) {
        observe_log.warn(
            "diskless config credential rejected: node={s} session={s} decision={s}",
            .{ node_id, session_hdr, @tagName(decision) },
        );
        return json(request, .unauthorized, disklessCredentialError(decision), meta);
    }
    context.diskless_store.markBootConfigFetched(context.io, session_hdr) catch
        return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"diskless.session_persist_failed\",\"message\":\"cannot persist boot-config lifecycle\"}}\n", meta);
    const base = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}", .{ context.config.server.server_ip, context.config.server.http_port });
    defer context.allocator.free(base);
    const config_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/boot-config", .{ base, node_id });
    defer context.allocator.free(config_url);
    const rootfs_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/rootfs", .{ base, node_id });
    defer context.allocator.free(rootfs_url);
    const session_id_slice: []const u8 = session.session_id[0..];
    const agent_plan_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/boot-sessions/{s}/agent-plan/{s}", .{ base, session_id_slice, session.agentPlanDigest() });
    defer context.allocator.free(agent_plan_url);
    const event_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/events", .{ base, node_id });
    defer context.allocator.free(event_url);
    const facts_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/facts", .{ base, node_id });
    defer context.allocator.free(facts_url);
    const PayloadProjection = struct { payload: []const diskless_dto.PayloadEntry = &.{} };
    const payload_projection = std.json.parseFromSlice(PayloadProjection, context.allocator, session.agentPlanJson(), .{ .ignore_unknown_fields = true }) catch
        return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"diskless.plan_invalid\",\"message\":\"pinned AgentPlan is invalid\"}}\n", meta);
    defer payload_projection.deinit();
    var node_payload_size: u64 = 0;
    for (payload_projection.value.payload) |entry|
        node_payload_size = std.math.add(u64, node_payload_size, entry.size) catch
            return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"diskless.payload_size_overflow\",\"message\":\"payload closure size overflow\"}}\n", meta);
    const bc: diskless_dto.BootConfig = .{
        .node_id = node_id,
        .session_id = session_id_slice,
        .profile = session.profileName(),
        .kernel_release = session.kernelRelease(),
        .config_url = config_url,
        .rootfs = .{ .url = rootfs_url, .sha512 = session.rootfsSha512(), .size = session.rootfs_size, .uncompressed_size = if (session.rootfs_uncompressed_size == 0) null else session.rootfs_uncompressed_size },
        .overlay = .{
            .tmpfs_percent = session.tmpfs_percent,
            .minimum_free_bytes = session.minimum_free_bytes,
            .safety_margin_bytes = session.safety_margin_bytes,
            .node_payload_size = node_payload_size,
        },
        .agent_plan = .{ .url = agent_plan_url, .digest = session.agentPlanDigest(), .size = @intCast(session.agent_plan_len) },
        .event_url = event_url,
        .facts_url = facts_url,
        .expires_at = session.expires_at,
    };
    const body = try diskless_dto.renderBootConfig(context.allocator, bc);
    defer context.allocator.free(body);
    try request.setHeader("cache-control", "no-store, private");
    try request.setHeader("x-content-type-options", "nosniff");
    return json(request, .ok, body, meta);
}

/// v0.2 diskless rootfs 下载。initrd 用独立 rootfs:read token 认证，
/// 通过 rootfs_artifact_store 定位已注册的 squashfs 制品并经 staticFile 交付。
fn disklessRootfs(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const rootfs_token = parseBearer(request.getHeader("authorization")) orelse
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.token_required\",\"message\":\"Authorization: Bearer <rootfs-token> is required\"}}\n", meta);
    const session_hdr = request.getHeader("x-nodeforge-session") orelse
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.session_required\",\"message\":\"X-NodeForge-Session header is required\"}}\n", meta);
    const session = context.diskless_store.find(session_hdr) orelse
        return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"diskless.session_not_found\",\"message\":\"no diskless session found\"}}\n", meta);
    if (!std.mem.eql(u8, session.nodeId(), node_id))
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.node_mismatch\",\"message\":\"session does not belong to this node\"}}\n", meta);
    const decision = context.diskless_store.verify(session_hdr, rootfs_token, .rootfs, node_id, "", session.rootfsSha512(), 0, boot_session.monotonicNow());
    // 凭证校验失败：日志记录具体 decision（如 invalid_token/expired/scope_mismatch），
    // 供运维定位；HTTP 响应只对外暴露笼统的 unauthorized 或 token_expired。
    // 此前此路径缺失日志，导致 token 过期与 token 篡改在日志中无法区分。
    if (decision != .ok) {
        observe_log.warn(
            "diskless rootfs credential rejected: node={s} session={s} decision={s}",
            .{ node_id, session_hdr, @tagName(decision) },
        );
        return json(request, .unauthorized, disklessCredentialError(decision), meta);
    }
    const artifact = context.rootfs_artifacts.find(session.rootfsInputDigest()) orelse
        return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"diskless.rootfs_not_found\",\"message\":\"no rootfs artifact registered for this profile build\"}}\n", meta);
    return staticFile(request, context, paths.require().rootfs_dir, artifact.file, artifact.content_sha512, meta);
}

/// v0.2 diskless AgentPlan v1 交付。agent pre-init 用 agent:read token 认证后，
/// 获取 pinned immutable AgentPlan JSON（digest 必须与 URL 中的 digest 一致）。
fn disklessAgentPlan(request: zap.Request, context: *const RouteContext, session_id: []const u8, digest: []const u8, meta: RequestMeta) !void {
    const agent_token = parseBearer(request.getHeader("authorization")) orelse
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.token_required\",\"message\":\"Authorization: Bearer <agent-token> is required\"}}\n", meta);
    const session = context.diskless_store.find(session_id) orelse
        return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"diskless.session_not_found\",\"message\":\"no diskless session found\"}}\n", meta);
    if (!std.mem.eql(u8, digest, session.agentPlanDigest()))
        return notFound(request, meta);
    const decision = context.diskless_store.verify(session_id, agent_token, .agent, session.nodeId(), "", session.agentPlanDigest(), 0, boot_session.monotonicNow());
    // 凭证校验失败：日志记录具体 decision（如 invalid_token/expired/node_mismatch），
    // 供运维定位；HTTP 响应只对外暴露笼统的 unauthorized 或 token_expired。
    // 此前此路径缺失日志，agent pre-init 拉取 AgentPlan 失败时无法区分原因。
    if (decision != .ok) {
        observe_log.warn(
            "diskless agent-plan credential rejected: session={s} decision={s}",
            .{ session_id, @tagName(decision) },
        );
        return json(request, .unauthorized, disklessCredentialError(decision), meta);
    }
    return json(request, .ok, session.agentPlanJson(), meta);
}

/// agent 已把 AgentPlan 与完整 payload closure 校验到本地后主动撤销读能力。
fn disklessAgentConsumed(request: zap.Request, context: *const RouteContext, session_id: []const u8, meta: RequestMeta) !void {
    const token = parseBearer(request.getHeader("authorization")) orelse
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.token_required\",\"message\":\"agent token is required\"}}\n", meta);
    const session = context.diskless_store.find(session_id) orelse return notFound(request, meta);
    const decision = context.diskless_store.verify(session_id, token, .agent, session.nodeId(), "", session.agentPlanDigest(), 0, boot_session.monotonicNow());
    // 凭证校验失败：日志记录具体 decision（如 invalid_token/expired/node_mismatch），
    // 供运维定位；HTTP 响应只对外暴露笼统的 unauthorized 或 token_expired。
    // 此前此路径缺失日志，agent 撤销 token 失败时无法区分原因。
    if (decision != .ok) {
        observe_log.warn(
            "diskless agent-consumed credential rejected: session={s} decision={s}",
            .{ session_id, @tagName(decision) },
        );
        return json(request, .unauthorized, disklessCredentialError(decision), meta);
    }
    context.diskless_store.revoke(context.io, session_id, .agent) catch
        return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"diskless.token_revoke_failed\",\"message\":\"cannot persist agent token revocation\"}}\n", meta);
    return json(request, .ok, "{\"ok\":true}\n", meta);
}

/// v0.2 diskless payload 交付。agent 用 agent:read token 认证后下载 content-addressed
/// payload。v0.2 smoke test 的 AgentPlan payload 为空，此路由 fail-closed（404）。
fn disklessPayload(request: zap.Request, context: *const RouteContext, session_id: []const u8, file_path: []const u8, meta: RequestMeta) !void {
    const agent_token = parseBearer(request.getHeader("authorization")) orelse
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.token_required\",\"message\":\"Authorization: Bearer <agent-token> is required\"}}\n", meta);
    const session = context.diskless_store.find(session_id) orelse
        return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"diskless.session_not_found\",\"message\":\"no diskless session found\"}}\n", meta);
    const decision = context.diskless_store.verify(session_id, agent_token, .agent, session.nodeId(), file_path, session.agentPlanDigest(), 0, boot_session.monotonicNow());
    // 凭证校验失败：日志记录具体 decision（含请求路径，便于定位越权访问），
    // 供运维定位；HTTP 响应只对外暴露笼统的 unauthorized 或 token_expired。
    // 此前此路径缺失日志，payload 下载失败时无法区分 path_not_allowed 与 token 错误。
    if (decision != .ok) {
        observe_log.warn(
            "diskless payload credential rejected: session={s} path={s} decision={s}",
            .{ session_id, file_path, @tagName(decision) },
        );
        return json(request, .unauthorized, disklessCredentialError(decision), meta);
    }
    const P = struct { payload: []const diskless_dto.PayloadEntry = &.{} };
    const parsed = std.json.parseFromSlice(P, context.allocator, session.agentPlanJson(), .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch
        return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"diskless.plan_invalid\",\"message\":\"pinned AgentPlan is invalid\"}}\n", meta);
    defer parsed.deinit();
    var entry: ?diskless_dto.PayloadEntry = null;
    for (parsed.value.payload) |candidate| if (std.mem.eql(u8, candidate.path, file_path)) {
        entry = candidate;
        break;
    };
    const payload = entry orelse return notFound(request, meta);
    const slash = std.mem.indexOfScalar(u8, file_path, '/') orelse return notFound(request, meta);
    const name = file_path[0..slash];
    const revision = std.fmt.parseInt(u64, file_path[slash + 1 ..], 10) catch return notFound(request, meta);
    const asset = lookup.findAsset(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    if (asset.revision != revision or asset.sha256 == null or !std.mem.eql(u8, asset.sha256.?, payload.digest))
        return notFound(request, meta);
    const full_path = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ paths.require().assets_dir, asset.path });
    defer context.allocator.free(full_path);
    const stat = std.Io.Dir.cwd().statFile(context.io, full_path, .{}) catch return notFound(request, meta);
    if (stat.size != payload.size) return notFound(request, meta);
    return staticFile(request, context, paths.require().assets_dir, asset.path, asset.sha256, meta);
}

const DisklessEventEnvelope = struct {
    schema_version: u32,
    session_id: []const u8,
    event_seq: u64,
    expected_phase: []const u8,
    phase: []const u8,
    message: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

fn parseDisklessPhase(name: []const u8) ?diskless_lifecycle.Phase {
    const candidates = [_]diskless_lifecycle.Phase{
        .boot_config_fetched,
        .diskless_initrd_started,
        .diskless_rootfs_downloading,
        .diskless_rootfs_verified,
        .diskless_rootfs_mounted,
        .diskless_switching_root,
        .diskless_agent_configuring,
        .diskless_running,
        .failed,
    };
    for (candidates) |phase| if (std.mem.eql(u8, name, phase.canonicalName())) return phase;
    return null;
}

/// v0.2 diskless lifecycle event append。event token 只能推进自身 session；
/// expected_phase + event_seq 提供 CAS，完全相同的上一次请求可安全重放。
fn disklessEvent(request: zap.Request, context: *const RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const token = parseBearer(request.getHeader("authorization")) orelse
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.token_required\",\"message\":\"event token is required\"}}\n", meta);
    const session_id = request.getHeader("x-nodeforge-session") orelse
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.session_required\",\"message\":\"session header is required\"}}\n", meta);
    const session = context.diskless_store.find(session_id) orelse return notFound(request, meta);
    if (!std.mem.eql(u8, session.nodeId(), node_id))
        return json(request, .unauthorized, "{\"ok\":false,\"error\":{\"code\":\"diskless.node_mismatch\",\"message\":\"session does not belong to this node\"}}\n", meta);
    if (!bodyWithin(request, 4 * 1024))
        return json(request, .content_too_large, "{\"ok\":false,\"error\":{\"code\":\"http.body_too_large\",\"message\":\"diskless event body too large\"}}\n", meta);
    const body = request.body orelse
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"diskless.event_invalid\",\"message\":\"missing event body\"}}\n", meta);
    const parsed = std.json.parseFromSlice(DisklessEventEnvelope, context.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"diskless.event_invalid\",\"message\":\"invalid event envelope\"}}\n", meta);
    defer parsed.deinit();
    const event = parsed.value;
    if (event.schema_version != 1 or !std.mem.eql(u8, event.session_id, session_id))
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"diskless.event_invalid\",\"message\":\"event schema/session mismatch\"}}\n", meta);
    const expected = parseDisklessPhase(event.expected_phase) orelse
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"diskless.phase_invalid\",\"message\":\"unknown expected phase\"}}\n", meta);
    const target = parseDisklessPhase(event.phase) orelse
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"diskless.phase_invalid\",\"message\":\"unknown target phase\"}}\n", meta);
    const decision = context.diskless_store.verify(session_id, token, .event, node_id, "", "", event.event_seq, boot_session.monotonicNow());
    // 凭证校验失败：日志记录具体 decision（如 event_seq_mismatch/expired/invalid_token）
    // 和 event_seq，供运维定位；HTTP 响应只对外暴露笼统的 unauthorized 或 token_expired。
    // 此路径是唯一原有日志的 verify 失败点，保留并保持与其他路径一致的结构。
    if (decision != .ok) {
        observe_log.warn(
            "diskless event credential rejected: node={s} session={s} event_seq={d} decision={s}",
            .{ node_id, session_id, event.event_seq, @tagName(decision) },
        );
        return json(request, .unauthorized, disklessCredentialError(decision), meta);
    }

    const result = context.diskless_store.advanceEvent(context.io, session_id, expected, target, event.event_seq, unixNow()) catch |err| switch (err) {
        // 5 种 lifecycle 冲突错误全部压成同一个 409 + diskless.event_conflict，
        // 但日志记录具体 cause（如 JumpRejected/AlreadyTerminal/...），
        // 供运维区分"序号跳变""phase 不匹配""非法跳转""回退""已终态"。
        error.DisklessEventSequenceMismatch, error.DisklessExpectedPhaseMismatch, error.JumpRejected, error.BackwardRejected, error.AlreadyTerminal => {
            observe_log.warn(
                "diskless event transition rejected: node={s} session={s} event_seq={d} expected={s} target={s} cause={t}",
                .{ node_id, session_id, event.event_seq, event.expected_phase, event.phase, err },
            );
            return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"diskless.event_conflict\",\"message\":\"event sequence or lifecycle transition rejected\"}}\n", meta);
        },
        else => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"diskless.session_persist_failed\",\"message\":\"cannot persist diskless lifecycle\"}}\n", meta),
    };
    if (result == .applied) {
        const revoke_kinds: []const diskless_delivery.Store.SlotKind = switch (target) {
            .diskless_initrd_started => &.{.config},
            .diskless_rootfs_verified => &.{.rootfs},
            .diskless_running => &.{ .agent, .event },
            .failed => &.{ .config, .rootfs, .agent, .event },
            else => &.{},
        };
        for (revoke_kinds) |kind| context.diskless_store.revoke(context.io, session_id, kind) catch
            return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"diskless.token_revoke_failed\",\"message\":\"cannot persist capability revocation\"}}\n", meta);
        var fields: [5]events.Field = .{
            .{ .key = "node_id", .value = node_id },
            .{ .key = "boot_session_id", .value = session_id },
            .{ .key = "phase", .value = event.phase },
            .{ .key = "event_seq", .value = try std.fmt.allocPrint(context.allocator, "{d}", .{event.event_seq}) },
            .{ .key = "reason", .value = event.reason orelse "" },
        };
        defer context.allocator.free(fields[3].value);
        const field_count: usize = if (event.reason == null) 4 else 5;
        context.event_writer.appendWithFields(context.io, context.allocator, paths.require().events_path, event.phase, event.message orelse "diskless lifecycle advanced", fields[0..field_count]) catch |err| {
            observe_log.err("diskless event audit append failed after checkpoint: {t}", .{err});
            return json(request, .internal_server_error, "{\"ok\":false,\"error\":{\"code\":\"events.unavailable\",\"message\":\"event writer unavailable\"}}\n", meta);
        };

        // ── boot_session.Store 终态同步（R9 bug 修复）──────────────────────
        //
        // v0.2 有两套独立的 session 存储：
        //
        // 1. `boot_session.Store`（M2/M3）：DHCP/TFTP 阶段的协议关联注册表。
        //    DHCP DISCOVER 时由 `dhcp/server.zig:acquireSession` 创建，用于
        //    DHCP/TFTP/boot_config 阶段的节点身份关联和 capability 认证。
        //    `hasActive()` 全局检查用于阻止活动 session 期间的属性修改。
        //
        // 2. `diskless_delivery.Store`（v0.2）：diskless 交付 session，由
        //    `managementBootPrepare` 创建，跟踪完整的 diskless 生命周期
        //    （boot_config_fetched → rootfs_downloading → ... → diskless_running）。
        //    `node session cancel` 操作的是这个 store。
        //
        // 两套 store 的 session ID 不同，但都绑定到同一个 node_id。diskless
        // 节点 PXE 启动时，DHCP 会在 `boot_session.Store` 中创建 session；
        // 当 diskless 生命周期到达终态（`diskless_running` 或 `failed`）时，
        // 必须同步终止 `boot_session.Store` 中的对应 session。
        //
        // BUG 历史：此处曾缺少终态同步逻辑。diskless 节点进入 `diskless_running`
        // 后，`diskless_delivery.Store` 正确到达终态，但 `boot_session.Store`
        // 中的 DHCP session 仍保持 active，直到 2 小时 delivery TTL 自然过期。
        // 期间 `hasActive()` 返回 true，导致所有节点的 `node set`/`node unset`
        // 等属性修改操作被 409 `property.active_session` 拒绝。
        //
        // 对比 install 模式：install terminal event（completed/failed）由
        // `nodeEvent`/`nodeLog`/`subiquityReport` 处理，这些 handler 通过
        // `context.sessions.finishDelivery(session_id, reason, ...)` 正确终止了
        // `boot_session.Store` session。diskless 路径遗漏了这一步。
        //
        // 修复：在 diskless 终态时按 node_id 终止 `boot_session.Store` session。
        // 使用 `finishNodeDelivery` 而非 `supersedeNode`，以传入语义准确的
        // 终态原因（`completed`/`failed` 而非 `superseded`）。
        if (target == .diskless_running or target == .failed) {
            const terminal_reason: boot_session.TerminalReason = if (target == .diskless_running) .completed else .failed;
            _ = context.sessions.finishNodeDelivery(node_id, terminal_reason, boot_session.monotonicNow(), unixNow());
            // 同步持久化 capability 删除，避免 daemon 重启后从 checkpoint 复活。
            // 注意：`boot_session_store.load()` 只恢复 install 模式 session
            // （`if (record.mode != .install) continue`），diskless session 不会
            // 被恢复，但保持 checkpoint 一致性仍是必要的。
            if (!checkpointSessions(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist terminal delivery session\"}}\n", meta);
        }
    }
    return json(request, .ok, "{\"ok\":true}\n", meta);
}

const NodeReadinessRequest = struct {
    stage: enum { build, boot } = .boot,
};

const NodeRetryRequest = struct { force: bool = false };

/// 严格只读的启动投影。该 handler 只读取当前 immutable model pair 和制品索引，
/// 不创建 session/operation，不签发 capability，也不修改 deploy/generation。
fn managementNodeBootPreview(request: zap.Request, context: *RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    if (!jsonRequest(request)) return unsupportedMediaType(request, meta);
    const catalog = context.catalog_snapshot.value();
    const node = lookup.findNode(catalog, node_id) orelse return notFound(request, meta);
    const profile_name = node.profile orelse
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"preview.profile_missing\",\"message\":\"node has no profile assigned\"}}\n", meta);
    const profile = lookup.findProfile(catalog, profile_name) orelse return notFound(request, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    if (profile.kind == .diskless) {
        var plan = diskless.compile(context.allocator, context.config, catalog, node) catch |err| return validationError(request, err, meta);
        defer plan.deinit();
        const rootfs_digest: []const u8 = &plan.rootfs_input_digest;
        const desired_digest: []const u8 = &plan.desired_plan_digest;
        const bundle_name = profile.boot_bundle orelse return validationError(request, error.MissingBootBundle, meta);
        const bundle = lookup.findBootBundle(catalog, bundle_name) orelse return validationError(request, error.MissingBootBundle, meta);
        const rootfs_ready = context.rootfs_artifacts.find(rootfs_digest) != null;
        try output.writer.print(
            "{{\"ok\":true,\"result\":{{\"node\":{f},\"profile\":{f},\"kind\":\"diskless\",\"catalog_revision\":{d},\"deploy\":{s},\"would_boot\":{s},\"rootfs_input_digest\":{f},\"desired_plan_digest\":{f},\"boot_bundle\":{f},\"kernel\":{f},\"initrd\":{f},\"kernel_release\":{f},\"rootfs_state\":{f},\"tmpfs_percent\":{d},\"minimum_free_bytes\":{d},\"safety_margin_bytes\":{d}}}}}\n",
            .{ std.json.fmt(node.id, .{}), std.json.fmt(profile.name, .{}), context.catalog_snapshot.revision, if (node.deploy) "true" else "false", if (node.deploy and rootfs_ready) "true" else "false", std.json.fmt(rootfs_digest, .{}), std.json.fmt(desired_digest, .{}), std.json.fmt(bundle.name, .{}), std.json.fmt(bundle.kernel, .{}), std.json.fmt(bundle.initrd, .{}), std.json.fmt(bundle.kernel_release, .{}), std.json.fmt(if (rootfs_ready) "ready" else "missing", .{}), plan.node_boot.tmpfs_percent, plan.node_boot.minimum_free_bytes, plan.node_boot.safety_margin_bytes },
        );
    } else {
        var plan = effective_compiler.compile(context.allocator, catalog, node) catch |err| return validationError(request, err, meta);
        defer plan.deinit();
        const digest = desiredPlanDigest(context, node_id) catch return validationError(request, error.ModelRevisionUnavailable, meta);
        try output.writer.print(
            "{{\"ok\":true,\"result\":{{\"node\":{f},\"profile\":{f},\"kind\":\"install\",\"catalog_revision\":{d},\"deploy\":{s},\"would_boot\":{s},\"desired_plan_digest\":{f},\"install_source\":{f},\"arch\":{f}}}}}\n",
            .{ std.json.fmt(node.id, .{}), std.json.fmt(profile.name, .{}), context.catalog_snapshot.revision, if (node.deploy) "true" else "false", if (node.deploy) "true" else "false", std.json.fmt(&digest, .{}), std.json.fmt(plan.install_source.name, .{}), std.json.fmt(@tagName(node.arch), .{}) },
        );
    }
    return json(request, .ok, output.written(), meta);
}

/// Kind-aware retry。deploy gate、活动 session 处理和 install generation rearm
/// 均由服务端决定；CLI 不再编排多个 management 请求。
fn managementNodeRetry(request: zap.Request, context: *RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    if (!jsonRequest(request)) return unsupportedMediaType(request, meta);
    const parsed = std.json.parseFromSlice(NodeRetryRequest, context.allocator, request.body orelse "{}", .{}) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"retry.invalid\",\"message\":\"expected {force:boolean}\"}}\n", meta);
    defer parsed.deinit();
    const catalog = context.catalog_snapshot.value();
    const node = lookup.findNode(catalog, node_id) orelse return notFound(request, meta);
    const profile = lookup.findProfile(catalog, node.profile orelse return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.profile_unassigned\",\"message\":\"node has no bound profile\"}}\n", meta)) orelse return notFound(request, meta);
    const mono_now = boot_session.monotonicNow();
    const install_active = context.sessions.hasActiveNode(node_id, mono_now);
    var diskless_active = false;
    var diskless_snapshot: [diskless_delivery.max_sessions]diskless_delivery.Session = undefined;
    for (context.diskless_store.snapshot(&diskless_snapshot)) |session| if (std.mem.eql(u8, session.nodeId(), node_id) and !session.phase.isTerminal()) {
        diskless_active = true;
        break;
    };
    if ((install_active or diskless_active) and !parsed.value.force)
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"retry.session_active\",\"message\":\"active session cannot be retried; stop the target and use --force\"}}\n", meta);
    if (parsed.value.force) {
        if (install_active) {
            _ = context.sessions.supersedeNode(node_id, mono_now, unixNow());
            if (!checkpointSessions(context)) return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist forced session termination\"}}\n", meta);
        }
        if (diskless_active) {
            while (context.diskless_store.findByNode(node_id)) |session| {
                if (session.phase.isTerminal()) break;
                var id: [boot_session.id_len]u8 = undefined;
                @memcpy(&id, &session.session_id);
                context.diskless_store.cancel(context.io, &id) catch
                    return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"session.persist_failed\",\"message\":\"cannot persist forced diskless session termination\"}}\n", meta);
            }
        }
    }
    if (!node.deploy) {
        while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
        defer config_mutation_mutex.unlock();
        context.models.lock();
        defer context.models.unlock();
        scalar_mutation.nodeBatch(context.io, context.allocator, context.config, context.catalog.path, node_id, &.{.{ .key = "deploy", .value = "true" }}) catch |err|
            return validationError(request, err, meta);
        applyCatalogFromDisk(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"catalog.publish_failed\",\"message\":\"cannot enable node deployment gate\"}}\n", meta);
    }
    if (profile.kind == .diskless) {
        var response: [256]u8 = undefined;
        return json(request, .ok, try std.fmt.bufPrint(&response, "{{\"ok\":true,\"result\":{{\"node_id\":{f},\"kind\":\"diskless\",\"deploy\":true,\"superseded\":{s},\"message\":\"ready for next PXE\"}}}}\n", .{ std.json.fmt(node_id, .{}), if (diskless_active) "true" else "false" }), meta);
    }
    // Enabling deploy publishes a new catalog generation. The request's pinned
    // RouteContext intentionally remains on the old generation, so arming from it
    // would persist the pre-mutation plan digest and DHCP would immediately reject
    // the retry as install_not_armed. Pin the newly published pair and make the
    // generation decision from exactly that model.
    const current = context.models.acquire();
    defer current.release();
    var current_context = context.*;
    current_context.config = current.config.value();
    current_context.config_revision = current.config.revision;
    current_context.catalog_snapshot = current.catalog;
    return installGenerations(request, &current_context, node_id, meta);
}

fn writeDisklessSession(writer: *std.Io.Writer, session: *const diskless_delivery.Session) !void {
    try writer.print("{{\"session_id\":{f},\"node_id\":{f},\"profile\":{f},\"phase\":{f},\"rootfs_input_digest\":{f},\"agent_plan_digest\":{f},\"kernel_release\":{f},\"rootfs_size\":{d},\"rootfs_uncompressed_size\":", .{
        std.json.fmt(session.session_id[0..], .{}),
        std.json.fmt(session.nodeId(), .{}),
        std.json.fmt(session.profileName(), .{}),
        std.json.fmt(@tagName(session.phase), .{}),
        std.json.fmt(session.rootfsInputDigest(), .{}),
        std.json.fmt(session.agentPlanDigest(), .{}),
        std.json.fmt(session.kernelRelease(), .{}),
        session.rootfs_size,
    });
    if (session.rootfs_uncompressed_size == 0) try writer.writeAll("null") else try writer.print("{d}", .{session.rootfs_uncompressed_size});
    try writer.print(",\"armed_at\":{d},\"expires_at\":{d},\"capabilities\":{{\"config\":{s},\"rootfs\":{s},\"agent\":{s},\"event\":{s}}}}}", .{
        session.armed_at,
        session.expires_at,
        if (session.config_token.issued) "true" else "false",
        if (session.rootfs_token.issued) "true" else "false",
        if (session.agent_token.issued) "true" else "false",
        if (session.event_token.issued) "true" else "false",
    });
}

fn managementDisklessSessions(request: zap.Request, context: *RouteContext, meta: RequestMeta) !void {
    var snapshot: [diskless_delivery.max_sessions]diskless_delivery.Session = undefined;
    const sessions = context.diskless_store.snapshot(&snapshot);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"items\":[");
    for (sessions, 0..) |*session, index| {
        if (index != 0) try output.writer.writeByte(',');
        try writeDisklessSession(&output.writer, session);
    }
    try output.writer.writeAll("]}}\n");
    return json(request, .ok, output.written(), meta);
}

fn managementDisklessSession(request: zap.Request, context: *RouteContext, session_id: []const u8, meta: RequestMeta) !void {
    const session = context.diskless_store.find(session_id) orelse return notFound(request, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":");
    try writeDisklessSession(&output.writer, session);
    try output.writer.writeAll("}\n");
    return json(request, .ok, output.written(), meta);
}

fn managementDisklessSessionCancel(request: zap.Request, context: *RouteContext, session_id: []const u8, meta: RequestMeta) !void {
    context.diskless_store.cancel(context.io, session_id) catch |err| switch (err) {
        error.DisklessSessionNotFound => return notFound(request, meta),
        else => return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"diskless.cancel_failed\",\"message\":\"cannot persist session cancellation\"}}\n", meta),
    };
    var output: [192]u8 = undefined;
    const body = try std.fmt.bufPrint(&output, "{{\"ok\":true,\"result\":{{\"session_id\":{f},\"state\":\"cancelled\"}}}}\n", .{std.json.fmt(session_id, .{})});
    return json(request, .ok, body, meta);
}

fn managementNodeReadiness(request: zap.Request, context: *RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    if (!jsonRequest(request)) return unsupportedMediaType(request, meta);
    const body = request.body orelse "{}";
    const parsed = std.json.parseFromSlice(NodeReadinessRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"readiness.invalid\",\"message\":\"stage must be build or boot\"}}\n", meta);
    defer parsed.deinit();
    const catalog = context.catalog_snapshot.value();
    const node = lookup.findNode(catalog, node_id) orelse return notFound(request, meta);
    const profile_name = node.profile orelse
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.profile_missing\",\"message\":\"node has no profile assigned\"}}\n", meta);
    const profile = lookup.findProfile(catalog, profile_name) orelse return notFound(request, meta);
    if (profile.kind != .diskless)
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.not_diskless\",\"message\":\"readiness is only available for diskless profiles\"}}\n", meta);
    var plan = diskless.compile(context.allocator, context.config, catalog, node) catch |err| return validationError(request, err, meta);
    defer plan.deinit();
    const rootfs_digest: []const u8 = plan.rootfs_input_digest[0..];
    const desired_digest: []const u8 = plan.desired_plan_digest[0..];

    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    if (parsed.value.stage == .build) {
        _ = lookup.findInstallSource(catalog, profile.install_source) orelse
            return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.source_missing\",\"message\":\"install source not found\"}}\n", meta);
        try output.writer.print("{{\"ok\":true,\"result\":{{\"node_id\":{f},\"stage\":\"build\",\"ready\":true,\"rootfs_input_digest\":{f},\"desired_plan_digest\":{f},\"issues\":[],\"warnings\":[]}}}}\n", .{
            std.json.fmt(node_id, .{}), std.json.fmt(rootfs_digest, .{}), std.json.fmt(desired_digest, .{}),
        });
        return json(request, .ok, output.written(), meta);
    }

    const artifact = context.rootfs_artifacts.find(rootfs_digest) orelse
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.rootfs_missing\",\"message\":\"rootfs is not ready for the current build projection\"}}\n", meta);
    const bundle_name = profile.boot_bundle orelse return validationError(request, error.MissingBootBundle, meta);
    const bundle = lookup.findBootBundle(catalog, bundle_name) orelse return validationError(request, error.MissingBootBundle, meta);
    const kernel = lookup.findAsset(catalog, bundle.kernel) orelse return validationError(request, error.MissingAsset, meta);
    const initrd_asset = lookup.findAsset(catalog, bundle.initrd) orelse return validationError(request, error.MissingAsset, meta);
    if (kernel.kind != .kernel or initrd_asset.kind != .nodeforge_initrd or kernel.sha256 == null or initrd_asset.sha256 == null)
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.boot_assets_invalid\",\"message\":\"boot bundle assets are incomplete or have invalid kinds\"}}\n", meta);
    const kernel_path = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ context.config.tftp.asset_root, kernel.path });
    defer context.allocator.free(kernel_path);
    const initrd_path = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ paths.require().initrd_dir, initrd_asset.path });
    defer context.allocator.free(initrd_path);
    const rootfs_path = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ paths.require().rootfs_dir, artifact.file });
    defer context.allocator.free(rootfs_path);
    const kernel_stat = std.Io.Dir.cwd().statFile(context.io, kernel_path, .{ .follow_symlinks = false }) catch
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.kernel_missing\",\"message\":\"registered kernel file is missing\"}}\n", meta);
    const initrd_stat = std.Io.Dir.cwd().statFile(context.io, initrd_path, .{ .follow_symlinks = false }) catch
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.initrd_missing\",\"message\":\"registered initrd file is missing\"}}\n", meta);
    const rootfs_stat = std.Io.Dir.cwd().statFile(context.io, rootfs_path, .{ .follow_symlinks = false }) catch
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.rootfs_file_missing\",\"message\":\"registered rootfs file is missing\"}}\n", meta);
    if (kernel_stat.kind != .file or initrd_stat.kind != .file or rootfs_stat.kind != .file or rootfs_stat.size != artifact.compressed_size)
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.artifact_drift\",\"message\":\"registered artifact metadata does not match managed files\"}}\n", meta);
    var kernel_sha256: [64]u8 = undefined;
    asset_validate.sha256File(context.io, context.config.tftp.asset_root, kernel.path, &kernel_sha256) catch
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.kernel_digest_unavailable\",\"message\":\"cannot validate registered kernel digest\"}}\n", meta);
    var initrd_sha256: [64]u8 = undefined;
    asset_validate.sha256File(context.io, paths.require().initrd_dir, initrd_asset.path, &initrd_sha256) catch
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.initrd_digest_unavailable\",\"message\":\"cannot validate registered initrd digest\"}}\n", meta);
    if (!std.mem.eql(u8, &kernel_sha256, kernel.sha256.?) or !std.mem.eql(u8, &initrd_sha256, initrd_asset.sha256.?))
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.boot_asset_digest_mismatch\",\"message\":\"kernel or initrd content digest does not match catalog identity\"}}\n", meta);
    const rootfs_sha512 = sha512File(context.io, rootfs_path) catch
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.rootfs_digest_unavailable\",\"message\":\"cannot validate registered rootfs digest\"}}\n", meta);
    if (!std.mem.eql(u8, &rootfs_sha512, artifact.content_sha512))
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.rootfs_digest_mismatch\",\"message\":\"rootfs content digest does not match registered identity\"}}\n", meta);
    try output.writer.print("{{\"ok\":true,\"result\":{{\"node_id\":{f},\"stage\":\"boot\",\"ready\":true,\"rootfs_input_digest\":{f},\"desired_plan_digest\":{f},\"kernel_path\":{f},\"initrd_path\":{f},\"rootfs_file\":{f},\"compressed_bytes\":{d},\"uncompressed_bytes\":", .{
        std.json.fmt(node_id, .{}), std.json.fmt(rootfs_digest, .{}), std.json.fmt(desired_digest, .{}), std.json.fmt(kernel.path, .{}), std.json.fmt(initrd_asset.path, .{}), std.json.fmt(artifact.file, .{}), artifact.compressed_size,
    });
    // unknown 只能产生 warning，不能伪造成容量证明；最终仍由 initrd 的实测
    // MemAvailable 硬闸。只有展开大小已知时，服务端才计算共享公式。
    if (artifact.uncompressed_size == 0) {
        try output.writer.print("null,\"initrd_bytes\":{d},\"kernel_bytes\":{d},\"node_payload_bytes\":null,\"required_min_memory_bytes\":null,\"memory_bytes\":null,\"memory\":\"unknown\",\"issues\":[],\"warnings\":[{{\"code\":\"readiness.rootfs_uncompressed_size_unknown\",\"message\":\"rootfs uncompressed size is unknown; hard memory-capacity checks will be skipped\"}}]}}}}\n", .{ initrd_stat.size, kernel_stat.size });
    } else {
        const payload_size = readinessNodePayloadSize(context, catalog, &plan) catch |err|
            return validationError(request, err, meta);
        const memory_inputs: initrd_memory.Inputs = .{
            .available_budget = 0,
            .rootfs_size = artifact.compressed_size,
            .rootfs_uncompressed_size = artifact.uncompressed_size,
            .node_payload_size = payload_size,
            .tmpfs_percent = plan.node_boot.tmpfs_percent,
            .minimum_free_bytes = plan.node_boot.minimum_free_bytes,
            .safety_margin_bytes = plan.node_boot.safety_margin_bytes,
        };
        const minimum_available = initrd_memory.minimumAvailableBytes(memory_inputs) catch
            return validationError(request, error.Overflow, meta);
        const boot_assets_bytes = std.math.add(u64, kernel_stat.size, initrd_stat.size) catch
            return validationError(request, error.Overflow, meta);
        const required_total = std.math.add(u64, boot_assets_bytes, minimum_available) catch
            return validationError(request, error.Overflow, meta);
        const observation = context.inventories.memoryObservation(node_id, unixNow());
        if (observation) |memory_fact| {
            if (memory_fact.bytes) |memory_bytes| {
                if (memory_fact.fresh) {
                    const available = std.math.sub(u64, memory_bytes, boot_assets_bytes) catch
                        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.memory_insufficient\",\"message\":\"fresh node inventory proves insufficient memory for kernel and initrd\"}}\n", meta);
                    var checked_inputs = memory_inputs;
                    checked_inputs.available_budget = available;
                    _ = initrd_memory.upperLimit(checked_inputs) catch |err| switch (err) {
                        error.InsufficientMemory, error.MinimumFreeBudgetUnsatisfied => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"readiness.memory_insufficient\",\"message\":\"fresh node inventory proves insufficient memory for diskless boot\"}}\n", meta),
                        else => return validationError(request, error.Overflow, meta),
                    };
                    try output.writer.print("{d},\"initrd_bytes\":{d},\"kernel_bytes\":{d},\"node_payload_bytes\":{d},\"required_min_memory_bytes\":{d},\"memory_bytes\":{d},\"memory_reported_at\":{d},\"memory\":\"sufficient\",\"issues\":[],\"warnings\":[]}}}}\n", .{ artifact.uncompressed_size, initrd_stat.size, kernel_stat.size, payload_size, required_total, memory_bytes, memory_fact.reported_at });
                    return json(request, .ok, output.written(), meta);
                }
                try output.writer.print("{d},\"initrd_bytes\":{d},\"kernel_bytes\":{d},\"node_payload_bytes\":{d},\"required_min_memory_bytes\":{d},\"memory_bytes\":{d},\"memory_reported_at\":{d},\"memory\":\"stale\",\"issues\":[],\"warnings\":[{{\"code\":\"readiness.memory_stale\",\"message\":\"node inventory memory is stale; initrd will enforce the hard memory gate\"}}]}}}}\n", .{ artifact.uncompressed_size, initrd_stat.size, kernel_stat.size, payload_size, required_total, memory_bytes, memory_fact.reported_at });
                return json(request, .ok, output.written(), meta);
            }
        }
        try output.writer.print("{d},\"initrd_bytes\":{d},\"kernel_bytes\":{d},\"node_payload_bytes\":{d},\"required_min_memory_bytes\":{d},\"memory_bytes\":null,\"memory\":\"unknown\",\"issues\":[],\"warnings\":[{{\"code\":\"readiness.memory_unknown\",\"message\":\"node inventory memory is unknown; initrd will enforce the hard memory gate\"}}]}}}}\n", .{ artifact.uncompressed_size, initrd_stat.size, kernel_stat.size, payload_size, required_total });
    }
    return json(request, .ok, output.written(), meta);
}

fn sha512File(io: std.Io, path: []const u8) ![128]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    var hash = std.crypto.hash.sha2.Sha512.init(.{});
    var buffer: [256 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const count = try file.readPositionalAll(io, &buffer, offset);
        if (count == 0) break;
        hash.update(buffer[0..count]);
        offset += count;
    }
    var raw: [64]u8 = undefined;
    hash.final(&raw);
    var encoded: [128]u8 = undefined;
    _ = std.fmt.bufPrint(&encoded, "{x}", .{raw}) catch unreachable;
    return encoded;
}

/// 计算 effective first-boot content_asset closure 的去重字节数。该值与
/// boot-prepare pin 入 AgentPlan 的 payload 集合使用相同 owner/phase/action 规则。
fn readinessNodePayloadSize(context: *const RouteContext, catalog: *const model.Catalog, plan: *const diskless.DisklessPlan) !u64 {
    const bundle_name = plan.node_apply.first_boot_bundle orelse return 0;
    const bundle = findProvisioningBundleIn(catalog.provisioning_bundles, bundle_name) orelse return error.MissingProvisioningBundle;
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(context.allocator);
    var total: u64 = 0;
    for (bundle.steps) |step| {
        if (step.phase != .first_boot or step.content_asset == null) continue;
        switch (step.action) {
            .managed_file, .archive, .script, .package => {},
            else => continue,
        }
        const asset = lookup.findAsset(catalog, step.content_asset.?) orelse return error.MissingAsset;
        if (asset.sha256 == null) return error.InvalidProvisioningStep;
        var duplicate = false;
        for (seen.items) |name| if (std.mem.eql(u8, name, asset.name)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        const full_path = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ paths.require().assets_dir, asset.path });
        defer context.allocator.free(full_path);
        const stat = try std.Io.Dir.cwd().statFile(context.io, full_path, .{ .follow_symlinks = false });
        if (stat.kind != .file) return error.InvalidProvisioningStep;
        total = std.math.add(u64, total, stat.size) catch return error.PayloadSizeOverflow;
        try seen.append(context.allocator, asset.name);
    }
    return total;
}

/// AgentPlan provenance must name the effective provisioning bundle compiled
/// into the node-apply projection. `Profile.boot_bundle` is a kernel/initrd
/// owner and must never be exposed as first-boot metadata.
fn effectiveFirstBootBundle(plan: *const diskless.DisklessPlan) ?[]const u8 {
    return plan.node_apply.first_boot_bundle;
}

/// `node boot-prepare`：为 diskless 节点创建交付 session。编译 diskless plan 得到
/// rootfs_input_digest + desired_plan_digest，定位已注册 rootfs 制品，创建 session，
/// 渲染并 pin immutable AgentPlan，签发 config-token。返回 capsule 交付所需的全部门票。
fn managementBootPrepare(request: zap.Request, context: *RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const catalog = context.catalog_snapshot.value();
    const node = lookup.findNode(catalog, node_id) orelse return notFound(request, meta);
    const profile_name = node.profile orelse
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"diskless.node_unassigned\",\"message\":\"node has no profile assigned\"}}\n", meta);
    const profile = lookup.findProfile(catalog, profile_name) orelse return notFound(request, meta);
    if (profile.kind != .diskless)
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"profile.not_diskless\",\"message\":\"boot-prepare is only available for diskless profiles\"}}\n", meta);
    var plan = diskless.compile(context.allocator, context.config, catalog, node) catch |err| return validationError(request, err, meta);
    defer plan.deinit();
    const rootfs_input_digest: []const u8 = plan.rootfs_input_digest[0..];
    const desired_plan_digest: []const u8 = plan.desired_plan_digest[0..];
    const artifact = context.rootfs_artifacts.find(rootfs_input_digest) orelse
        return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"diskless.rootfs_not_registered\",\"message\":\"no rootfs artifact registered for this profile build; run 'profile rootfs register' first\"}}\n", meta);
    const bundle_name = profile.boot_bundle orelse return validationError(request, error.MissingBootBundle, meta);
    const boot_bundle = lookup.findBootBundle(catalog, bundle_name) orelse return validationError(request, error.MissingBootBundle, meta);
    const session = context.diskless_store.begin(
        context.io,
        node_id,
        profile.name,
        rootfs_input_digest,
        artifact.content_sha512,
        artifact.compressed_size,
        artifact.uncompressed_size,
        boot_bundle.kernel_release,
        plan.node_boot.tmpfs_percent,
        plan.node_boot.minimum_free_bytes,
        plan.node_boot.safety_margin_bytes,
        boot_session.monotonicNow(),
        unixNow(),
    ) catch |err| return validationError(request, err, meta);
    const session_id_slice: []const u8 = session.session_id[0..];
    // begin() 已把 active session 持久化。后续 AgentPlan 渲染、pin、token 签发
    // 或响应发送任一步失败，都必须撤销该 session，不能留下客户端不知道 ID 的
    // 半成品 authority 占用容量或阻塞节点 mutation。
    var session_committed = false;
    defer if (!session_committed)
        context.diskless_store.cancel(context.io, session_id_slice) catch
            std.log.scoped(.diskless).err("failed to roll back incomplete boot-prepare session {s}", .{session_id_slice});
    const base = try std.fmt.allocPrint(context.allocator, "http://{s}:{d}", .{ context.config.server.server_ip, context.config.server.http_port });
    defer context.allocator.free(base);
    const event_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/events", .{ base, node_id });
    defer context.allocator.free(event_url);
    // AgentPlan 禁止明文密码。按 immutable desired plan + account 派生稳定 salt，
    // 服务端只把 `$6$` hash 投影给 agent。
    var owned_password_hashes: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_password_hashes.items) |value| context.allocator.free(value);
        owned_password_hashes.deinit(context.allocator);
    }
    const agent_users = try context.allocator.alloc(diskless_dto.AgentUser, plan.node_apply.system.users.len);
    defer context.allocator.free(agent_users);
    for (plan.node_apply.system.users, 0..) |user, index| {
        const hash: ?[]const u8 = if (user.password) |plain| blk: {
            const salt = passwordSalt(desired_plan_digest, user.name);
            const value = try password_hash.sha512Crypt(context.allocator, plain, &salt);
            try owned_password_hashes.append(context.allocator, value);
            break :blk value;
        } else null;
        agent_users[index] = .{
            .name = user.name,
            .uid = user.uid,
            .shell = user.shell,
            .locked = user.locked,
            .password_hash = hash,
            .sudo = user.sudo,
            .groups = user.groups,
            .ssh_authorized_keys = user.ssh_authorized_keys,
        };
    }
    const root_password_hash: ?[]const u8 = if (plan.node_apply.system.ssh.root_password) |plain| blk: {
        const salt = passwordSalt(desired_plan_digest, "root");
        const value = try password_hash.sha512Crypt(context.allocator, plain, &salt);
        try owned_password_hashes.append(context.allocator, value);
        break :blk value;
    } else null;
    const diskless_root_keys = try context.allocator.alloc([]const u8, plan.node_apply.system.ssh.root_authorized_keys.len + 1 + context.additional_keys.len);
    defer context.allocator.free(diskless_root_keys);
    @memcpy(diskless_root_keys[0..plan.node_apply.system.ssh.root_authorized_keys.len], plan.node_apply.system.ssh.root_authorized_keys);
    diskless_root_keys[plan.node_apply.system.ssh.root_authorized_keys.len] = context.bootstrap_key;
    @memcpy(diskless_root_keys[plan.node_apply.system.ssh.root_authorized_keys.len + 1 ..], context.additional_keys);
    // Phase 8：把 Profile-fixed first-boot 步骤与完整 content-addressed payload
    // closure 固定进 AgentPlan。小型 inline content 仍可直接携带；content_asset
    // 只投影 payload path/digest/size，节点不再按 catalog 的 latest 名称取文件。
    var fb_steps: std.ArrayList(diskless_dto.FirstBootStep) = .empty;
    defer fb_steps.deinit(context.allocator);
    var payload_entries: std.ArrayList(diskless_dto.PayloadEntry) = .empty;
    defer payload_entries.deinit(context.allocator);
    var owned_payload_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_payload_paths.items) |value| context.allocator.free(value);
        owned_payload_paths.deinit(context.allocator);
    }
    const effective_first_boot_bundle = if (plan.node_apply.first_boot_bundle) |name|
        findProvisioningBundleIn(catalog.provisioning_bundles, name) orelse return validationError(request, error.MissingProvisioningBundle, meta)
    else
        null;
    const effective_first_boot_steps = if (effective_first_boot_bundle) |bundle_value| bundle_value.steps else &.{};
    for (effective_first_boot_steps) |ps| {
        if (ps.phase != .first_boot) continue;
        const act: ?diskless_dto.FirstBootAction = switch (ps.action) {
            .managed_file => .managed_file,
            .archive => .archive,
            .script => .script,
            .package => .package,
            else => null,
        };
        if (act) |a| {
            var payload_path: ?[]const u8 = null;
            if (ps.content_asset) |asset_name| {
                const asset = lookup.findAsset(catalog, asset_name) orelse return validationError(request, error.MissingAsset, meta);
                const digest = asset.sha256 orelse return validationError(request, error.InvalidProvisioningStep, meta);
                const relative = try std.fmt.allocPrint(context.allocator, "{s}/{d}", .{ asset.name, asset.revision });
                try owned_payload_paths.append(context.allocator, relative);
                const full_path = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ paths.require().assets_dir, asset.path });
                defer context.allocator.free(full_path);
                const stat = std.Io.Dir.cwd().statFile(context.io, full_path, .{ .follow_symlinks = false }) catch |err|
                    return validationError(request, err, meta);
                if (stat.kind != .file) return validationError(request, error.InvalidProvisioningStep, meta);
                var already_pinned = false;
                for (payload_entries.items) |entry| if (std.mem.eql(u8, entry.path, relative)) {
                    already_pinned = true;
                    break;
                };
                if (!already_pinned)
                    try payload_entries.append(context.allocator, .{ .path = relative, .digest = digest, .size = stat.size });
                payload_path = relative;
            }
            try fb_steps.append(context.allocator, .{
                .id = ps.name,
                .idempotency_key = if (ps.idempotency_key.len == 0) ps.name else ps.idempotency_key,
                .timeout_s = ps.timeout_s,
                .retryable = ps.retryable,
                .action = a,
                .content = if (payload_path == null) ps.content else null,
                .payload_path = payload_path,
                .destination = ps.destination,
                .mode = ps.mode,
                .owner = ps.owner,
                .group = ps.group,
                .packages = ps.packages,
            });
        }
    }
    const fb_steps_slice = try fb_steps.toOwnedSlice(context.allocator);
    defer context.allocator.free(fb_steps_slice);
    var repository_urls: std.ArrayList([]const u8) = .empty;
    defer {
        for (repository_urls.items) |url| context.allocator.free(url);
        repository_urls.deinit(context.allocator);
    }
    var package_manager: ?diskless_dto.FirstBootPackageManager = null;
    // 默认源来自当前 InstallSource：ISO 导入时由 nodeforged 建立并通过
    // /artifacts/repositories/** 发布。effective software.repositories 是操作员
    // 通过 CLI 明确增加/删除后的附加选择；两者合并去重后 pin 进 AgentPlan。
    const install_source = lookup.findInstallSource(catalog, plan.profile_build.install_source) orelse
        return validationError(request, error.MissingInstallSource, meta);
    var repository_names: std.ArrayList([]const u8) = .empty;
    defer repository_names.deinit(context.allocator);
    for (install_source.repositories) |repository_name|
        try repository_names.append(context.allocator, repository_name);
    for (plan.node_apply.software.repositories) |repository_name| {
        var found = false;
        for (repository_names.items) |existing| {
            if (std.mem.eql(u8, existing, repository_name)) {
                found = true;
                break;
            }
        }
        if (!found) try repository_names.append(context.allocator, repository_name);
    }
    for (repository_names.items) |repository_name| {
        const repository = lookup.findRepository(catalog, repository_name) orelse return validationError(request, error.MissingRepository, meta);
        const manager: diskless_dto.FirstBootPackageManager = switch (repository.manager) {
            .dnf => .dnf,
            .apt => .apt,
        };
        if (package_manager != null and package_manager.? != manager)
            return validationError(request, error.RepositoryManagerMismatch, meta);
        package_manager = manager;
        // Catalog 保存受管 repository 的路径身份；会话交付必须使用当前
        // nodeforged endpoint。这样 setup/migration 后 server_ip 或 port 改变时，
        // AgentPlan 不会把节点引向 catalog 中已经过期的 authority，同时仍保留
        // ISO repository 的子路径（例如 /Minimal）。
        const repository_marker = "/artifacts/repositories/";
        const marker_index = std.mem.indexOf(u8, repository.base_url, repository_marker) orelse
            return validationError(request, error.ExternalEndpointForbidden, meta);
        const managed_path = repository.base_url[marker_index..];
        const session_repository_url = try std.fmt.allocPrint(context.allocator, "{s}{s}", .{ base, managed_path });
        try repository_urls.append(context.allocator, session_repository_url);
    }
    var packages_remove: std.ArrayList([]const u8) = .empty;
    defer packages_remove.deinit(context.allocator);
    for (node.overrides.software.packages_include.remove) |package|
        try packages_remove.append(context.allocator, package);
    for (node.overrides.software.packages_exclude.add) |package| {
        var duplicate = false;
        for (packages_remove.items) |existing| if (std.mem.eql(u8, existing, package)) {
            duplicate = true;
            break;
        };
        if (!duplicate) try packages_remove.append(context.allocator, package);
    }
    const ap: diskless_dto.AgentPlan = .{
        .node_id = node_id,
        .session_id = session_id_slice,
        .plan_digest = desired_plan_digest,
        .rootfs_input_digest = rootfs_input_digest,
        .node_apply_projection = .{
            .node_id = plan.node_apply.node_id,
            .mac = plan.node_apply.mac,
            .arch = plan.node_apply.arch,
            .hostname = plan.node_apply.hostname,
            .network = plan.node_apply.network,
            .system = .{
                .localization = plan.node_apply.system.localization,
                .connectivity = plan.node_apply.system.connectivity,
                .ssh = .{
                    .enabled = plan.node_apply.system.ssh.enabled,
                    .password_authentication = plan.node_apply.system.ssh.password_authentication,
                    .root_login = plan.node_apply.system.ssh.root_login,
                    .root_password_hash = root_password_hash,
                    .root_authorized_keys = diskless_root_keys,
                },
                .security = plan.node_apply.system.security,
                .import_host_hosts = plan.node_apply.system.import_host_hosts,
                .hosts_content = plan.node_apply.system.hosts_content,
                .users = agent_users,
                .packages = plan.node_apply.system.packages,
            },
            .software = plan.node_apply.software,
            .software_transaction = .{
                .manager = package_manager,
                .repository_urls = repository_urls.items,
                .install = node.overrides.software.packages_include.add,
                .remove = packages_remove.items,
                .preserve_sources_list = plan.node_apply.apt_preserve_sources_list,
            },
        },
        .first_boot_bundle = effectiveFirstBootBundle(&plan),
        .payload = payload_entries.items,
        .steps = fb_steps_slice,
        .package_manager = package_manager,
        .repository_urls = repository_urls.items,
        .first_boot_max_attempts = profile.diskless.failure.max_attempts,
        .first_boot_backoff_seconds = profile.diskless.failure.backoff_seconds,
        .event_url = event_url,
        .expires_at = session.expires_at,
    };
    const plan_json = try diskless_dto.renderAgentPlan(context.allocator, ap);
    defer context.allocator.free(plan_json);
    context.diskless_store.pinAgentPlan(context.io, session_id_slice, plan_json) catch |err| return validationError(request, err, meta);
    context.diskless_store.issue(context.io, session_id_slice, .config) catch |err| return validationError(request, err, meta);
    context.diskless_store.issue(context.io, session_id_slice, .rootfs) catch |err| return validationError(request, err, meta);
    context.diskless_store.issue(context.io, session_id_slice, .agent) catch |err| return validationError(request, err, meta);
    context.diskless_store.issue(context.io, session_id_slice, .event) catch |err| return validationError(request, err, meta);
    const config_token = context.diskless_store.rawToken(session, .config);
    const rootfs_token = context.diskless_store.rawToken(session, .rootfs);
    const agent_token = context.diskless_store.rawToken(session, .agent);
    const event_token = context.diskless_store.rawToken(session, .event);
    const config_url = try std.fmt.allocPrint(context.allocator, "{s}/api/v1/nodes/{s}/boot-config", .{ base, node_id });
    defer context.allocator.free(config_url);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    const internal_capsule = if (request.getHeader("x-nodeforge-internal-capsule")) |value| std.mem.eql(u8, value, "1") else false;
    if (internal_capsule)
        try output.writer.print("{{\"ok\":true,\"result\":{{\"node_id\":{f},\"session_id\":{f},\"config_token\":{f},\"rootfs_token\":{f},\"agent_token\":{f},\"event_token\":{f},\"config_url\":{f},\"agent_plan_digest\":{f},\"rootfs_input_digest\":{f}}}}}\n", .{
            std.json.fmt(node_id, .{}), std.json.fmt(session_id_slice, .{}), std.json.fmt(config_token, .{}), std.json.fmt(rootfs_token, .{}), std.json.fmt(agent_token, .{}), std.json.fmt(event_token, .{}), std.json.fmt(config_url, .{}), std.json.fmt(session.agentPlanDigest(), .{}), std.json.fmt(rootfs_input_digest, .{}),
        })
    else
        try output.writer.print("{{\"ok\":true,\"result\":{{\"node_id\":{f},\"session_id\":{f},\"state\":\"prepared\",\"config_url\":{f},\"agent_plan_digest\":{f},\"rootfs_input_digest\":{f}}}}}\n", .{
            std.json.fmt(node_id, .{}), std.json.fmt(session_id_slice, .{}), std.json.fmt(config_url, .{}), std.json.fmt(session.agentPlanDigest(), .{}), std.json.fmt(rootfs_input_digest, .{}),
        });
    try json(request, .ok, output.written(), meta);
    session_committed = true;
}

fn managementDiscoveryPolicy(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    var output: [384]u8 = undefined;
    const policy = context.catalog_snapshot.value().discovery_policy;
    const body = try std.fmt.bufPrint(&output, "{{\"ok\":true,\"result\":{{\"unknown_action\":{f},\"observation_retention_days\":{d},\"revision\":{d},\"catalog_revision\":{d}}}}}\n", .{
        std.json.fmt(@tagName(policy.unknown_action), .{}), policy.observation_retention_days, policy.revision, context.catalog_snapshot.revision,
    });
    try setRevisionEtag(request, context.catalog_snapshot.revision);
    return json(request, .ok, body, meta);
}

const DiscoveryPolicyMutation = struct {
    unknown_action: ?model.UnknownAction = null,
    observation_retention_days: ?u32 = null,
};

fn managementDiscoveryPolicySet(request: zap.Request, context: *RouteContext, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"discovery.policy.invalid\",\"message\":\"missing request body\"}}\n", meta);
    var parsed = std.json.parseFromSlice(DiscoveryPolicyMutation, context.allocator, body, .{}) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"discovery.policy.invalid\",\"message\":\"invalid discovery policy properties\"}}\n", meta);
    defer parsed.deinit();
    if (parsed.value.unknown_action == null and parsed.value.observation_retention_days == null)
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"discovery.policy.invalid\",\"message\":\"at least one policy property is required\"}}\n", meta);
    if (parsed.value.observation_retention_days) |days| if (days == 0)
        return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"discovery.policy.invalid_retention\",\"message\":\"observation_retention_days must be positive\"}}\n", meta);
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    var candidate = context.catalog_snapshot.value().*;
    if (parsed.value.unknown_action) |value| candidate.discovery_policy.unknown_action = value;
    if (parsed.value.observation_retention_days) |value| candidate.discovery_policy.observation_retention_days = value;
    candidate.discovery_policy.revision += 1;
    candidate.revision = context.catalog_snapshot.revision + 1;
    try catalog_store.save(context.io, context.allocator, context.catalog.path, &candidate);
    try applyCatalogFromDisk(context);
    try setRevisionEtag(request, context.catalog.currentRevision());
    return json(request, .ok, "{\"ok\":true,\"result\":{\"mutation\":\"applied_online\"}}\n", meta);
}

fn managementDiscoveryObservations(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    const observations = context.catalog_snapshot.value().unknown_client_observations;
    const page = pageRequest(request, "discovery-observations", context.catalog_snapshot.revision) catch |err| return pageError(request, err, meta);
    if (page.offset > observations.len) return pageError(request, error.InvalidCursor, meta);
    const end = @min(page.offset + page.limit, observations.len);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"items\":[");
    for (observations[page.offset..end], 0..) |observation, index| {
        if (index != 0) try output.writer.writeByte(',');
        try std.json.Stringify.value(observation, .{}, &output.writer);
    }
    try output.writer.writeByte(']');
    try writeNextCursor(&output.writer, "discovery-observations", context.catalog_snapshot.revision, end, observations.len);
    try output.writer.print(",\"view_revision\":{d}}}}}\n", .{context.catalog_snapshot.revision});
    try setRevisionEtag(request, context.catalog_snapshot.revision);
    return json(request, .ok, output.written(), meta);
}

fn managementDiscoveryObservation(request: zap.Request, context: *const RouteContext, mac: []const u8, meta: RequestMeta) !void {
    for (context.catalog_snapshot.value().unknown_client_observations) |observation| {
        if (!std.ascii.eqlIgnoreCase(observation.mac, mac)) continue;
        var output: std.Io.Writer.Allocating = .init(context.allocator);
        defer output.deinit();
        try output.writer.writeAll("{\"ok\":true,\"result\":");
        try std.json.Stringify.value(observation, .{}, &output.writer);
        try output.writer.writeAll("}\n");
        try setRevisionEtag(request, context.catalog_snapshot.revision);
        return json(request, .ok, output.written(), meta);
    }
    return notFound(request, meta);
}

const NodeClaimRequest = struct {
    mac: []const u8,
    arch: model.Arch,
    observation_revision: u64,
};

fn managementNodeClaim(request: zap.Request, context: *RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"discovery.claim.invalid\",\"message\":\"missing request body\"}}\n", meta);
    var parsed = std.json.parseFromSlice(NodeClaimRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"discovery.claim.invalid\",\"message\":\"invalid claim properties\"}}\n", meta);
    defer parsed.deinit();
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    var candidate = context.catalog_snapshot.value().*;
    catalog_discovery.claim(context.allocator, &candidate, .{
        .node_id = node_id,
        .mac = parsed.value.mac,
        .arch = parsed.value.arch,
        .expected_observation_revision = parsed.value.observation_revision,
        .claimed_at_unix = unixNow(),
    }) catch |err| switch (err) {
        error.ObservationNotFound => return json(request, .not_found, "{\"ok\":false,\"error\":{\"code\":\"discovery.observation_not_found\",\"message\":\"unknown client observation does not exist\"}}\n", meta),
        error.ObservationRevisionConflict => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"discovery.observation_revision_conflict\",\"message\":\"observation revision changed; refresh before claiming\"}}\n", meta),
        error.ObservationAlreadyClaimed => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"discovery.already_claimed\",\"message\":\"observation is already claimed\"}}\n", meta),
        error.MacAlreadyClaimed => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.duplicate_mac\",\"message\":\"MAC address is already assigned to another node\"}}\n", meta),
        error.NodeNotClaimable => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.not_claimable\",\"message\":\"existing node must be unassigned and deploy=false\"}}\n", meta),
        else => return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"discovery.claim_failed\",\"message\":\"observation could not be claimed\"}}\n", meta),
    };
    defer context.allocator.free(candidate.nodes);
    defer context.allocator.free(candidate.unknown_client_observations);
    candidate.revision = context.catalog_snapshot.revision + 1;
    config_validate.validate(context.config, &candidate) catch |err| return validationError(request, err, meta);
    try catalog_store.save(context.io, context.allocator, context.catalog.path, &candidate);
    try applyCatalogFromDisk(context);
    try setRevisionEtag(request, context.catalog.currentRevision());
    var output: [320]u8 = undefined;
    const response = try std.fmt.bufPrint(&output, "{{\"ok\":true,\"result\":{{\"node_id\":{f},\"profile\":null,\"deploy\":false,\"revision\":{d}}}}}\n", .{ std.json.fmt(node_id, .{}), context.catalog.currentRevision() });
    return json(request, .created, response, meta);
}

fn managementNodeAdd(request: zap.Request, context: *RouteContext, meta: RequestMeta) !void {
    const body = request.body orelse return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid\",\"message\":\"missing request body\"}}\n", meta);
    var parsed = std.json.parseFromSlice(NodeAddRequest, context.allocator, body, .{ .allocate = .alloc_always }) catch return json(request, .bad_request, "{\"ok\":false,\"error\":{\"code\":\"node.invalid\",\"message\":\"invalid node properties\"}}\n", meta);
    defer parsed.deinit();
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
    while (!config_mutation_mutex.tryLock()) std.Thread.yield() catch {};
    defer config_mutation_mutex.unlock();
    context.models.lock();
    defer context.models.unlock();
    if (!ifMatchCurrent(request, context)) return revisionConflict(request, meta);
    const value = parsed.value.modelValue();
    node_mutation.addNode(context.io, context.allocator, context.config, context.catalog.path, .{ .id = value.id, .mac = value.mac, .arch = value.arch, .profile = value.profile, .pxe_ip_reservation = value.pxe.ip_reservation, .hostname = value.hostname, .overrides = value.overrides, .deploy = value.deploy, .http_accel = value.http_accel, .storage = value.storage, .network = value.network }) catch |err| switch (err) {
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
        if (value.profile) |profile_name| if (lookup.findProfile(current.value(), profile_name) != null) {
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

fn managementNodeRemove(request: zap.Request, context: *RouteContext, node_id: []const u8, meta: RequestMeta) !void {
    if (context.sessions.hasActiveNode(node_id, boot_session.monotonicNow())) return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.active_session_conflict\",\"message\":\"node is pinned by an active boot session\"}}\n", meta);
    // 自旋等待 config_mutation_mutex（短临界区，自旋比 futex 更高效）。
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
    try output.writer.print("{{\"ok\":true,\"result\":{{\"view_revision\":{{\"config\":{d},\"catalog\":{d},\"node_status\":{d},\"deployment\":{d},\"inventory\":{d},\"diskless\":{d}}},\"items\":[", .{ context.config_revision, context.catalog_snapshot.revision, context.statuses.currentRevision(), context.deployments.currentRevision(), context.inventories.currentRevision(), context.diskless_store.currentRevision() });
    for (context.catalog_snapshot.value().nodes[page.offset..end], 0..) |node, index| {
        if (index != 0) try output.writer.writeByte(',');
        const profile = if (node.profile) |profile_name| lookup.findProfile(context.catalog_snapshot.value(), profile_name) else null;
        const is_install = if (profile) |value| value.kind == .install else false;
        const is_diskless = if (profile) |value| value.kind == .diskless else false;
        const desired_digest: ?deployment_control.Digest = if (is_install) desiredPlanDigest(context, node.id) catch null else null;
        const deployment = if (is_install) context.deployments.view(node.id) else null;
        const status = if (is_install) if (desired_digest) |digest| currentProjectedStatus(context, node.id, deployment, digest) else null else null;
        // diskless 不使用 install deployment。只投影当前节点且 profile 仍匹配的
        // delivery session，避免 profile 切换后把旧会话状态拼到新模型上。
        const diskless_session = if (is_diskless) blk: {
            const session = context.diskless_store.findByNode(node.id) orelse break :blk null;
            const profile_name = node.profile orelse break :blk null;
            break :blk if (std.mem.eql(u8, session.profileName(), profile_name)) session else null;
        } else null;
        var inventory = try context.inventories.getOwned(context.allocator, node.id);
        defer if (inventory) |*value| node_inventory.Store.freeOwned(context.allocator, value);
        try output.writer.print("{{\"id\":{f},\"mac\":{f},\"pxe\":{{\"ip_reservation\":", .{ std.json.fmt(node.id, .{}), std.json.fmt(node.mac, .{}) });
        if (node.pxe.ip_reservation) |ip| try output.writer.print("{f}", .{std.json.fmt(ip, .{})}) else try output.writer.writeAll("null");
        try output.writer.print("}},\"profile\":{f},\"deploy\":{s},\"install_intent\":{f},\"pxe_ready\":{s},\"retry_pending\":{s},\"armed_generation\":{f},\"status\":", .{
            std.json.fmt(node.profile, .{}),
            if (node.deploy) "true" else "false",
            std.json.fmt(if (is_install) if (desired_digest) |digest| installIntent(node.deploy, deployment, digest) else if (node.deploy) "blocked" else "disabled" else "not-applicable", .{}),
            if (desired_digest) |digest| if (installPxeReady(node.deploy, deployment, digest)) "true" else "false" else "false",
            if (retryPending(deployment)) "true" else "false",
            std.json.fmt(if (deployment) |value| value.armed_generation else null, .{}),
        });
        if (status) |value|
            try output.writer.print("{f}", .{std.json.fmt(@tagName(value.phase), .{})})
        else if (deployment) |value|
            if (deploymentPhaseFallback(value)) |phase| try output.writer.print("{f}", .{std.json.fmt(phase, .{})}) else try output.writer.writeAll("null")
        else if (diskless_session) |session|
            try output.writer.print("{f}", .{std.json.fmt(session.phase.canonicalName(), .{})})
        else
            try output.writer.writeAll("null");
        // install 与 diskless 各自使用自己的事实源，但列语义一致：
        // Armed=服务端创建任务；Install=节点开始执行；Finished=首次进入终态。
        if (deployment) |value| {
            const times = deploymentTimes(value);
            try output.writer.writeAll(",\"armed_at\":");
            if (times.armed_at != 0) try output.writer.print("{d}", .{times.armed_at}) else try output.writer.writeAll("null");
            try output.writer.writeAll(",\"install_at\":");
            if (times.install_at != 0) try output.writer.print("{d}", .{times.install_at}) else try output.writer.writeAll("null");
            try output.writer.writeAll(",\"finished_at\":");
            if (times.finished_at != 0) try output.writer.print("{d}", .{times.finished_at}) else try output.writer.writeAll("null");
            try output.writer.writeAll(",\"deployed_at\":");
            if (value.deployed_at != 0) try output.writer.print("{d}", .{value.deployed_at}) else try output.writer.writeAll("null");
            if (desired_digest) |digest| {
                const drift = context.deployments.drift(node.id, digest);
                try output.writer.print(",\"drifted\":{s},\"drift_state\":{f}", .{ if (drift == .drifted) "true" else "false", std.json.fmt(@tagName(drift), .{}) });
            } else try output.writer.writeAll(",\"drifted\":false,\"drift_state\":\"unavailable\"");
        } else if (diskless_session) |session| {
            try output.writer.print(",\"armed_at\":{d},\"install_at\":", .{session.armed_at});
            if (session.install_at != 0) try output.writer.print("{d}", .{session.install_at}) else try output.writer.writeAll("null");
            try output.writer.writeAll(",\"finished_at\":");
            if (session.finished_at != 0) try output.writer.print("{d}", .{session.finished_at}) else try output.writer.writeAll("null");
            try output.writer.writeAll(",\"deployed_at\":null,\"drifted\":false,\"drift_state\":\"not-applicable\"");
        } else try output.writer.writeAll(",\"armed_at\":null,\"install_at\":null,\"finished_at\":null,\"deployed_at\":null,\"drifted\":false");
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
    const profile = lookup.findProfile(context.catalog_snapshot.value(), node.profile orelse return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"node.profile_unassigned\",\"message\":\"node has no bound profile\"}}\n", meta)) orelse return notFound(request, meta);
    const profile_source = lookup.findInstallSource(context.catalog_snapshot.value(), profile.install_source) orelse return notFound(request, meta);
    var effective_plan = @import("../profile/effective.zig").compile(context.allocator, context.catalog_snapshot.value(), node) catch return json(request, .conflict, "{\"ok\":false,\"error\":{\"code\":\"effective.unavailable\",\"message\":\"effective node plan cannot be compiled\"}}\n", meta);
    defer effective_plan.deinit();
    const desired_revision = desiredRevision(context) catch return json(request, .service_unavailable, "{\"ok\":false,\"error\":{\"code\":\"model.revision_unavailable\",\"message\":\"cannot compute desired model revision\"}}\n", meta);
    const is_install = profile.kind == .install;
    const desired_digest = if (is_install) desiredPlanDigest(context, node_id) catch deployment_control.empty_digest else deployment_control.empty_digest;
    const deployment = if (is_install) context.deployments.view(node_id) else null;
    const status = if (is_install) currentProjectedStatus(context, node_id, deployment, desired_digest) else null;
    var inventory = try context.inventories.getOwned(context.allocator, node_id);
    defer if (inventory) |*value| node_inventory.Store.freeOwned(context.allocator, value);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    const node_json = try dto.renderNode(context.allocator, node.*);
    defer context.allocator.free(node_json);
    // Node detail 的 profile 投影必须包含 kind/boot_bundle：它们决定 install 与
    // diskless 分支以及实际启动材料，也是 CLI Runtime 区域的权威数据源。
    try output.writer.print("{{\"ok\":true,\"result\":{{\"view_revision\":{{\"config\":{d},\"catalog\":{d},\"node_status\":{d},\"deployment\":{d},\"inventory\":{d}}},\"node\":{s},\"profile\":{{\"name\":{f},\"kind\":{f},\"boot_bundle\":{f},\"install_source\":{f},\"kernel_args\":{f},\"platform\":{{\"distro\":{f},\"version\":{f},\"arch\":{f}}}}},\"effective_system\":", .{ context.config_revision, context.catalog_snapshot.revision, context.statuses.currentRevision(), context.deployments.currentRevision(), context.inventories.currentRevision(), node_json, std.json.fmt(profile.name, .{}), std.json.fmt(@tagName(profile.kind), .{}), std.json.fmt(profile.boot_bundle, .{}), std.json.fmt(profile.install_source, .{}), std.json.fmt(profile.kernel_args, .{}), std.json.fmt(profile_source.distro, .{}), std.json.fmt(profile_source.version, .{}), std.json.fmt(@tagName(profile_source.arch), .{}) });
    try writeTargetSystem(&output.writer, effective_plan.system);
    try output.writer.print(",\"effective_software\":{f}", .{std.json.fmt(effective_plan.software, .{})});
    try output.writer.writeAll(",\"storage\":");
    try output.writer.print("{{\"direct\":{f},\"override\":{f},\"effective\":{f}}}", .{ std.json.fmt(node.storage, .{}), std.json.fmt(node.overrides.install.storage, .{}), std.json.fmt(effective_plan.install.storage, .{}) });
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
    if (!is_install) {
        try output.writer.writeAll("{\"install_intent\":\"not-applicable\",\"pxe_ready\":false,\"retry_pending\":false,\"current_generation\":null,\"armed_generation\":null,\"consumed_generation\":null,\"terminal_generation\":null,\"requested_revision\":0,\"applied_revision\":0,\"desired_revision\":");
        try output.writer.print("{d}", .{desired_revision});
        try output.writer.writeAll(",\"requested_plan_digest\":null,\"applied_plan_digest\":null,\"desired_plan_digest\":null,\"drifted\":false,\"drift_state\":\"not-applicable\",\"requested_by\":null,\"armed_at\":0,\"install_at\":0,\"finished_at\":0,\"successful_generation\":0,\"deployed_at\":0}");
    } else if (deployment) |value| {
        const times = deploymentTimes(value);
        const digest_available = deployment_control.digestSet(desired_digest);
        const drift = if (digest_available) context.deployments.drift(node_id, desired_digest) else .unknown;
        try output.writer.print("{{\"install_intent\":{f},\"pxe_ready\":{s},\"retry_pending\":{s},\"current_generation\":{f},\"armed_generation\":{f},\"consumed_generation\":{f},\"terminal_generation\":{f},\"requested_revision\":{d},\"applied_revision\":{d},\"desired_revision\":{d},\"requested_plan_digest\":{f},\"applied_plan_digest\":{f},\"desired_plan_digest\":{f},\"drifted\":{s},\"drift_state\":{f},\"requested_by\":{f},\"armed_at\":{d},\"install_at\":{d},\"finished_at\":{d},\"successful_generation\":{d},\"deployed_at\":{d}}}", .{
            std.json.fmt(if (digest_available) installIntent(node.deploy, value, desired_digest) else if (node.deploy) "blocked" else "disabled", .{}),
            if (digest_available and installPxeReady(node.deploy, value, desired_digest)) "true" else "false",
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
            std.json.fmt(if (digest_available) desired_digest[0..] else null, .{}),
            if (drift == .drifted) "true" else "false",
            std.json.fmt(if (digest_available) @tagName(drift) else "unavailable", .{}),
            std.json.fmt(@tagName(value.requested_by), .{}),
            times.armed_at,
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
    if (view.install_at != 0) return "install_started";
    return null;
}

/// M4.9 破坏性安装意图投影：node identity 与 `deploy` 决定节点是否参与，
/// generation/revision 决定某一次具体安装是否仍获授权。
fn installIntent(deploy: bool, view: ?deployment_control.View, desired_digest: deployment_control.Digest) []const u8 {
    if (!deploy) return "disabled";
    // deploy=true 但尚无 deployment 记录：节点已启用 PXE 部署但还未触发安装。
    // 用 "not-armed" 而非 "not-applicable"，后者仅用于非 install profile。
    const value = view orelse return "not-armed";
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
        .armed_at = 1,
        .install_at = 0,
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

const DeploymentTimes = struct { armed_at: i64, install_at: i64, finished_at: i64 };

/// 对外时间名称与内部状态字段的唯一映射。Armed/Finished 是部署任务边界；
/// Install 是 install.started 的阶段点。M5 添加 diskless 阶段时必须扩展并列
/// 字段，不能改变这三个字段的既有含义。
fn deploymentTimes(view: deployment_control.View) DeploymentTimes {
    return .{ .armed_at = view.armed_at, .install_at = view.install_at, .finished_at = view.finished_at };
}

test "deployment time projection maps task and install boundaries" {
    const view: deployment_control.View = .{
        .next_generation = 2,
        .armed_generation = null,
        .consumed_generation = 1,
        .terminal_generation = 1,
        .requested_revision = 42,
        .applied_revision = 42,
        .armed_at = 10,
        .install_at = 20,
        .finished_at = 30,
        .deployed_at = 30,
        .requested_by = .operator,
    };
    const times = deploymentTimes(view);
    try std.testing.expectEqual(@as(i64, 10), times.armed_at);
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
        .armed_at = 10,
        .install_at = 0,
        .finished_at = 0,
        .deployed_generation = 4,
        .deployed_at = 9,
        .requested_by = .operator,
    };
    try std.testing.expectEqualStrings("pending", deploymentPhaseFallback(view).?);
    view.armed_generation = null;
    view.consumed_generation = 5;
    view.install_at = 11;
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
        .armed_at = 10,
        .install_at = 15,
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
    return writeTargetSystem(writer, system);
}

fn writeTargetSystem(writer: *std.Io.Writer, system: model.TargetSystemConfig) !void {
    try writer.print("{{\"localization\":{f},\"connectivity\":{f},\"ssh\":{{\"enabled\":{s},\"password_authentication\":{s},\"root_login\":{f},\"root_password\":{f},\"root_authorized_keys\":{f}}},\"security\":{f},\"users\":[", .{
        std.json.fmt(system.localization, .{}),
        std.json.fmt(system.connectivity, .{}),
        if (system.ssh.enabled) "true" else "false",
        if (system.ssh.password_authentication) "true" else "false",
        std.json.fmt(@tagName(system.ssh.root_login), .{}),
        std.json.fmt(system.ssh.root_password, .{}),
        std.json.fmt(system.ssh.root_authorized_keys, .{}),
        std.json.fmt(system.security, .{}),
    });
    for (system.users, 0..) |user, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{f}", .{std.json.fmt(user, .{})});
    }
    try writer.writeAll("],\"packages\":");
    try std.json.Stringify.value(system.packages, .{}, writer);
    try writer.print(",\"import_host_hosts\":{s},\"hosts_content\":{f}}}", .{
        if (system.import_host_hosts) "true" else "false",
        std.json.fmt(system.hosts_content, .{}),
    });
}

test "management effective system exposes canonical password policy values" {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeTargetSystem(&writer, .{ .ssh = .{ .root_password = "root-secret" }, .users = &.{.{ .name = "nodeforge", .password = "user-secret" }} });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"root_password\":\"root-secret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"password\":\"user-secret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "password_configured") == null);
}

fn managementProfiles(request: zap.Request, context: *const RouteContext, meta: RequestMeta) !void {
    // list/show 对 profile 身份字段保持同一契约，避免 valid=true 但调用者无法
    // 判断其类型或所引用 BootBundle 的不完整 DTO。
    const page = pageRequest(request, "profiles", context.catalog_snapshot.revision) catch |err| return pageError(request, err, meta);
    if (page.offset > context.catalog_snapshot.value().profiles.len) return pageError(request, error.InvalidCursor, meta);
    const end = @min(page.offset + page.limit, context.catalog_snapshot.value().profiles.len);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.writeAll("{\"ok\":true,\"result\":{\"items\":[");
    for (context.catalog_snapshot.value().profiles[page.offset..end], 0..) |profile, index| {
        if (index != 0) try output.writer.writeByte(',');
        var refs: usize = 0;
        for (context.catalog_snapshot.value().nodes) |node| if (node.profile != null and std.mem.eql(u8, node.profile.?, profile.name)) {
            refs += 1;
        };
        const source = lookup.findInstallSource(context.catalog_snapshot.value(), profile.install_source) orelse return notFound(request, meta);
        try output.writer.print("{{\"name\":{f},\"kind\":{f},\"boot_bundle\":{f},\"install_source\":{f},\"platform\":{{\"distro\":{f},\"version\":{f},\"arch\":{f}}},\"nodes\":{d},\"valid\":true}}", .{ std.json.fmt(profile.name, .{}), std.json.fmt(@tagName(profile.kind), .{}), std.json.fmt(profile.boot_bundle, .{}), std.json.fmt(profile.install_source, .{}), std.json.fmt(source.distro, .{}), std.json.fmt(source.version, .{}), std.json.fmt(@tagName(source.arch), .{}), refs });
    }
    try output.writer.writeByte(']');
    try writeNextCursor(&output.writer, "profiles", context.catalog_snapshot.revision, end, context.catalog_snapshot.value().profiles.len);
    try output.writer.print(",\"view_revision\":{d}}}}}\n", .{context.catalog_snapshot.revision});
    try setRevisionEtag(request, context.catalog_snapshot.revision);
    return json(request, .ok, output.written(), meta);
}

fn managementProfile(request: zap.Request, context: *const RouteContext, name: []const u8, meta: RequestMeta) !void {
    const profile = lookup.findProfile(context.catalog_snapshot.value(), name) orelse return notFound(request, meta);
    const source = lookup.findInstallSource(context.catalog_snapshot.value(), profile.install_source) orelse return notFound(request, meta);
    const distro = lookup.findDistro(context.catalog_snapshot.value(), source.distro) orelse return notFound(request, meta);
    const capability = lookup.findDistroVersion(context.catalog_snapshot.value(), source.distro, source.version, source.arch) orelse return notFound(request, meta);
    var output: std.Io.Writer.Allocating = .init(context.allocator);
    defer output.deinit();
    try output.writer.print("{{\"ok\":true,\"result\":{{\"model_revision\":{{\"config\":{d},\"catalog\":{d}}},\"name\":{f},\"kind\":{f},\"boot_bundle\":{f},\"kernel_args\":{f},\"install\":{f},\"validation\":{{\"valid\":true}},\"platform\":{{\"distro\":{f},\"version\":{f},\"arch\":{f}}},\"capability\":{{\"family\":{f},\"install_adapter\":{f},\"package_manager\":{f}}},\"effective_system\":", .{ context.config_revision, context.catalog_snapshot.revision, std.json.fmt(profile.name, .{}), std.json.fmt(@tagName(profile.kind), .{}), std.json.fmt(profile.boot_bundle, .{}), std.json.fmt(profile.kernel_args, .{}), std.json.fmt(profile.install, .{}), std.json.fmt(source.distro, .{}), std.json.fmt(source.version, .{}), std.json.fmt(@tagName(source.arch), .{}), std.json.fmt(@tagName(distro.family), .{}), std.json.fmt(@tagName(capability.install_adapter), .{}), std.json.fmt(@tagName(capability.package_manager), .{}) });
    try writeEffectiveSystem(&output.writer, profile);
    try output.writer.print(",\"software\":{f}", .{std.json.fmt(profile.software, .{})});
    try output.writer.writeAll(",\"install_source\":");
    const catalog_snapshot = context.catalog_snapshot;
    {
        try output.writer.print("{f},\"assets\":[", .{std.json.fmt(source.*, .{})});
        const asset_names = [_][]const u8{ source.source_asset, source.installer_kernel, source.installer_initrd };
        for (asset_names, 0..) |asset_name, index| {
            const asset = lookup.findAsset(catalog_snapshot.value(), asset_name) orelse return notFound(request, meta);
            if (index != 0) try output.writer.writeByte(',');
            try output.writer.print("{f}", .{std.json.fmt(asset.*, .{})});
        }
        try output.writer.writeByte(']');
    }
    try output.writer.writeAll(",\"nodes\":[");
    var first = true;
    for (context.catalog_snapshot.value().nodes) |node| if (node.profile != null and std.mem.eql(u8, node.profile.?, name)) {
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
        try output.writer.print(",\"deployment\":{{\"armed_generation\":{f},\"consumed_generation\":{f},\"terminal_generation\":{f},\"requested_revision\":{d},\"applied_revision\":{d},\"desired_revision\":{d},\"desired_plan_digest\":{f},\"drifted\":{s},\"drift_state\":{f},\"armed_at\":{d},\"requested_by\":{f}}}", .{
            std.json.fmt(value.armed_generation, .{}),
            std.json.fmt(value.consumed_generation, .{}),
            std.json.fmt(value.terminal_generation, .{}),
            value.requested_revision,
            value.applied_revision,
            desired_revision,
            std.json.fmt(desired_digest[0..], .{}),
            if (drift == .drifted) "true" else "false",
            std.json.fmt(@tagName(drift), .{}),
            value.armed_at,
            std.json.fmt(@tagName(value.requested_by), .{}),
        });
        try output.writer.print(",\"deployment_armed_at\":{d},\"deployment_install_at\":{d},\"deployment_finished_at\":{d},\"deployed_at\":{d}", .{ value.armed_at, value.install_at, value.finished_at, value.deployed_at });
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
    // 运行时租约截止时间用 MONOTONIC，但 `expires_at` 是公共 Unix
    // 时间戳。两个时钟各采样一次，使本响应的每一行共享
    // 相同的换算基准。
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

/// 已匹配资产路由但目标对象不存在。它与真正的路由缺失使用不同错误码，
/// 并沿用静态资源完成日志；仓库客户端对可选文件的正常探测因此不会产生
/// `http request rejected` 警告。
fn artifactNotFound(request: zap.Request, context: *const RouteContext, relative: []const u8, meta: RequestMeta) !void {
    const body = "{\"ok\":false,\"error\":{\"code\":\"artifact.not_found\",\"message\":\"artifact not found\"}}\n";
    var envelope: [512]u8 = undefined;
    const effective_body = appendRequestId(body, &meta.request_id, &envelope) orelse body;
    const method = request.method orelse "OTHER";
    const request_path = try context.allocator.dupe(u8, request.path orelse "<missing>");
    defer context.allocator.free(request_path);

    request.setStatus(.not_found);
    try request.setHeader("content-type", "application/json");
    try request.setHeader("cache-control", "no-store, private");
    try request.setHeader("x-content-type-options", "nosniff");
    try request.sendBody(effective_body);
    recordStaticCompletion(method, request_path, context, relative, 404, effective_body.len, 0, meta);
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
    const artifact_err = "{\"ok\":false,\"error\":{\"code\":\"artifact.not_found\",\"message\":\"artifact not found\"}}\n";
    const artifact_rewritten = appendRequestId(artifact_err, id, &out).?;
    try std.testing.expectEqualStrings("{\"ok\":false,\"error\":{\"code\":\"artifact.not_found\",\"message\":\"artifact not found\",\"request_id\":\"0000000000000000000000000000000a\"}}\n", artifact_rewritten);
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
    if (@intFromEnum(status) >= 400) {
        observe_log.warn(
            "http request rejected: method={s} path={s} status={d} error_code={s} reason=\"{s}\" request_id={s} client={s}",
            .{
                request.method orelse "OTHER",
                request.path orelse "<missing>",
                @intFromEnum(status),
                jsonErrorField(body, "\"code\":\"") orelse "unknown",
                jsonErrorField(body, "\"message\":\"") orelse "unspecified",
                meta.request_id[0..],
                meta.client_ip,
            },
        );
    }
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

/// Error envelopes are server-authored constants. Extracting their stable code/message
/// here makes every rejected HTTP request actionable without logging request bodies,
/// credentials, or response payloads wholesale.
fn jsonErrorField(body: []const u8, marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, body, marker) orelse return null;
    const value = body[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, value, '"') orelse return null;
    return value[0..end];
}

test "json error field extraction exposes stable diagnostics" {
    const body = "{\"ok\":false,\"error\":{\"code\":\"install.plan_digest_mismatch\",\"message\":\"digests differ\"}}\n";
    try std.testing.expectEqualStrings("install.plan_digest_mismatch", jsonErrorField(body, "\"code\":\"").?);
    try std.testing.expectEqualStrings("digests differ", jsonErrorField(body, "\"message\":\"").?);
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
