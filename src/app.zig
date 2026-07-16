//! NodeForge 单进程应用生命周期。
//! 负责共享配置/catalog 并启动 HTTP 与 M1 TFTP listener，不承载具体路由业务。
//! 依赖 `model.zig`（配置类型）、`http/server.zig`（HTTP 实现）和
//! `state/runtime.zig`（运行态骨架）；不直接操作文件系统或网络配置。
//!
//! M3.1 持久化边界：DHCP lease 由专属 checkpoint worker 至多每秒一次
//! checkpoint 至 `leases.json`；HTTP `node_status` 独立同步保存至
//! `node-status.json`；两者不共享 I/O 锁。旧 `runtime.json` 只作迁移输入。
//!
//! M2.5/M2.5.1 shutdown coordinator: 当 HTTP 事件循环退出（SIGINT/SIGTERM 或错误），
//! 设置共享 stop 标志，DHCP/TFTP worker 通过 200ms 超时轮询检测到后自行退出
//! 并 close 各自的 socket，主线程 join worker 线程、flush DHCP checkpoint、
//! 持久化最终 status 快照、写入每个活动 boot session 的
//! `boot.session.terminated` 和 `service.stopped` 事件。
//! 初始化失败或 SIGKILL 等不可控终止不写入这些有序终态事件。

const std = @import("std");
const model = @import("model.zig");
const http_server = @import("http/server.zig");
const tftp_server = @import("tftp/server.zig");
const dhcp_server = @import("dhcp/server.zig");
const runtime_state = @import("state/runtime.zig");
const catalog_runtime = @import("state/catalog_runtime.zig");
const config_runtime = @import("state/config_runtime.zig");
const model_runtime = @import("state/model_runtime.zig");
const observe_log = @import("observe/log.zig");
const paths = @import("paths.zig");
const dhcp_store = @import("state/dhcp_store.zig");
const status_store = @import("state/status_store.zig");
const events = @import("state/events.zig");
const boot_session = @import("state/boot_session.zig");
const boot_session_store = @import("state/boot_session_store.zig");
const node_status = @import("state/node_status.zig");
const deployment_control = @import("state/deployment_control.zig");
const node_inventory = @import("state/node_inventory.zig");
const operations = @import("state/operations.zig");
const model_transaction = @import("state/model_transaction.zig");
const capacity = @import("state/capacity.zig");

/// 启动 M1 TFTP 与唯一 HTTP listener。
///
/// TFTP socket 必须在 HTTP loop 前完成 bind；这样 daemon 不会在 UDP 69 不可用时
/// 仍以"已启动"状态只提供一半服务。TFTP 在独立线程运行，HTTP 继续保持 M0 的串行模型。
///
/// `service.started` 在 DHCP、TFTP、HTTP 均成功就绪后写入；`service.stopped`
/// 在有序关闭后写入。
pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const model.AppConfig,
    config_path: []const u8,
    catalog: *const model.Catalog,
    catalog_path: []const u8,
) !void {
    var runtime: runtime_state.RuntimeState = .{
        .service = .running,
        .config_generation = 1,
    };
    var statuses: node_status.Store = .{};
    var clock: std.posix.timespec = undefined;
    const current_time: i64 = if (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &clock)) == .SUCCESS) @intCast(clock.sec) else 0;

    // M3.1：优先从新文件加载；每个域独立回退到旧版 runtime.json 迁移。
    loadLeases(io, allocator, &runtime.dhcp, current_time);
    loadStatuses(io, allocator, &statuses);

    var event_writer: events.Writer = .{};
    event_writer.configure(config.events.max_size_mb, config.events.keep);
    // 进程 id 与 boot session id 使用同一不可预测编码，但生命周期不同：前者
    // 标记本次 daemon 启动，后者只关联一台节点的一次启动尝试。
    var daemon_instance_id: [boot_session.id_len]u8 = undefined;
    try boot_session.generateId(io, &daemon_instance_id);
    try event_writer.setDaemonInstanceId(daemon_instance_id);
    var sessions: boot_session.Store = .{};
    const restored_sessions = boot_session_store.load(io, allocator, paths.boot_sessions_path, config, catalog, &sessions, current_time, boot_session.monotonicNow()) catch |err| switch (err) {
        error.FileNotFound => 0,
        else => {
            observe_log.err("boot-session: refusing invalid checkpoint: {t}", .{err});
            return err;
        },
    };
    if (restored_sessions != 0) observe_log.info("boot-session: resumed {d} delivery session(s)", .{restored_sessions});
    var deployments: deployment_control.Store = .{};
    var inventories = node_inventory.Store.init(allocator);
    defer inventories.deinit();

    // M4.8: 启动时按网段/受管节点数/CPU 派生有效容量，config 可覆盖。
    const lease_cap = capacity.leaseCapacity(config.dhcp.subnet, config.dhcp.max_leases);
    const managed_cap = capacity.managedCapacity(config.nodes.len, config.capacity.managed_entries);
    const tftp_conc = capacity.tftpConcurrency(std.Thread.getCpuCount() catch 1, config.tftp.max_concurrent_transfers);
    runtime.dhcp.setEffective(lease_cap);
    sessions.setEffective(lease_cap);
    statuses.setEffective(managed_cap);
    deployments.setEffective(managed_cap);
    inventories.setCapacity(managed_cap);
    if (lease_cap > runtime_state.DhcpState.max_leases)
        observe_log.warn("capacity: lease/session derived={d} exceeds compiled ceiling={d}; effective capacity is clamped", .{ lease_cap, runtime_state.DhcpState.max_leases });
    if (managed_cap > node_status.max_statuses)
        observe_log.warn("capacity: managed derived={d} exceeds compiled ceiling={d}; effective capacity is clamped", .{ managed_cap, node_status.max_statuses });
    node_inventory.load(io, allocator, paths.node_inventory_path, &inventories) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var operation_store: operations.Store = .{};
    operations.load(io, allocator, paths.operations_path, &operation_store, current_time) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const transaction_dir = try model_transaction.directoryForConfig(allocator, config_path);
    defer allocator.free(transaction_dir);
    _ = try operations.reconcileMigrationRecovery(io, allocator, transaction_dir, &operation_store, current_time);
    try operations.save(io, allocator, paths.operations_path, &operation_store);
    try operations.clearMigrationRecoveryRecords(io, allocator, transaction_dir);
    const config_revision = try deployment_control.revisionForConfig(allocator, config);
    var live_config = try config_runtime.ConfigRuntime.init(allocator, config, config_revision);
    defer live_config.deinit();
    deployment_control.load(io, allocator, paths.deployment_control_path, &deployments) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {
            observe_log.err("deployment-control: refusing startup with invalid state: {t}", .{err});
            return err;
        },
    };
    // inventory/deployment 恢复可能把 effective 下限抬高；必须在加载后报告实际值，
    // 不能把 clamp 前派生值或加载前默认值误报为生效容量。
    observe_log.info("capacity: subnet={s} derived={d}, lease/session effective={d}/{d} (ceiling {d}); managed nodes={d}, status={d} inventory={d} deployment={d} (ceiling {d}); tftp concurrency={d}; ping_timeout_ms={d}", .{ config.dhcp.subnet, lease_cap, runtime.dhcp.effective, sessions.effective, runtime_state.DhcpState.max_leases, config.nodes.len, statuses.effective, inventories.capacity, deployments.effective, node_status.max_statuses, tftp_conc, config.dhcp.ping_timeout_ms });
    for (config.nodes) |node| if (forProfile(config, node.profile)) |profile| if (profile.mode == .install) {
        deployments.ensureInitial(node.id, config_revision, current_time) catch |err| return err;
    };
    try deployment_control.save(io, allocator, paths.deployment_control_path, &deployments);
    const bootstrap_key = try @import("server/admin_key.zig").resolve(io, allocator, config.server);
    defer allocator.free(bootstrap_key);
    const additional_keys = try @import("server/admin_key.zig").resolveAdditional(io, allocator, config.server);
    defer {
        for (additional_keys) |key| allocator.free(key);
        allocator.free(additional_keys);
    }

    // M3.1：leases.json 和 node-status.json 使用独立的 I/O 锁。
    // DHCP checkpoint worker 持有 leases.json；HTTP handler 持有
    // node-status.json。两者互不争用。
    var status_io_mutex: std.atomic.Mutex = .unlocked;
    var checkpoint_flush_stop = std.atomic.Value(bool).init(false);
    // M4.2：config reload 标志。HTTP handler 在 node add/set/remove 写入
    // config.json 后设置此标志。serve() 在下一个事件循环 tick 后返回；
    // app.zig 随后干净退出，systemd 用新配置重启。
    var reload_requested = std.atomic.Value(bool).init(false);

    event_writer.appendWithFields(io, allocator, paths.events_path, "config.loaded", "validated configuration loaded", &.{}) catch |err|
        observe_log.err("events: unable to record configuration load: {t}", .{err});
    for (config.nodes) |node| if (deployments.view(node.id)) |deployment| {
        if (deployment.applied_revision != 0 and deployment.applied_revision != config_revision) {
            var applied_text: [24]u8 = undefined;
            var desired_text: [24]u8 = undefined;
            const fields = [_]events.Field{
                .{ .key = "node_id", .value = node.id },
                .{ .key = "applied_revision", .value = std.fmt.bufPrint(&applied_text, "{d}", .{deployment.applied_revision}) catch "0" },
                .{ .key = "desired_revision", .value = std.fmt.bufPrint(&desired_text, "{d}", .{config_revision}) catch "0" },
            };
            event_writer.appendWithFields(io, allocator, paths.events_path, "install.configuration_drifted", "installed node configuration differs from current desired state", &fields) catch |err|
                observe_log.err("events: unable to record install drift: {t}", .{err});
        }
    };
    const persistence: dhcp_server.Persistence = .{
        .allocator = allocator,
        .events_path = paths.events_path,
        .writer = &event_writer,
        .sessions = &sessions,
        .deployments = &deployments,
        .config_revision = config_revision,
        .configs = &live_config,
    };
    var live_catalog = try catalog_runtime.CatalogRuntime.init(allocator, catalog_path, catalog);
    defer live_catalog.deinit();
    var live_models = model_runtime.ModelRuntime.init(&live_config, &live_catalog);
    // DHCP 需要 wildcard 接收 socket 以处理客户端广播。DHCP 服务器将配置的
    // PXE NIC 作为 Linux socket 级别的边界；TFTP 保持绑定在广告的 unicast 地址。
    const dhcp_socket = try dhcp_server.bind(io, config.server.server_ip, config.server.bind_interface);
    var stop_workers = std.atomic.Value(bool).init(false);
    var dhcp_thread = try std.Thread.spawn(.{}, runDhcp, .{ io, dhcp_socket, &live_config, &runtime, &persistence, &stop_workers });
    observe_log.info("dhcp: listening on udp://{s}:{d}", .{ config.server.server_ip, dhcp_server.port });
    const tftp_socket = try tftp_server.bind(io, config.server.server_ip);
    var tftp_thread = try std.Thread.spawn(.{}, runTftp, .{ io, allocator, tftp_socket, &live_models, &runtime, &event_writer, &sessions, &stop_workers });
    observe_log.info("tftp: listening on udp://{s}:{d}", .{ config.server.server_ip, tftp_server.port });

    // M3.1：启动 DHCP lease checkpoint worker。它是 leases.json 的唯一写入者，
    // 运行直到有序关闭时收到 flush-and-stop 命令。
    var checkpoint_thread = try std.Thread.spawn(.{}, runCheckpoint, .{ io, allocator, &runtime.dhcp, paths.leases_path, &checkpoint_flush_stop });
    observe_log.info("dhcp: lease checkpoint worker started", .{});

    // HTTP 明确绑定所有 IPv4 地址。`server.server_ip` 是给裸机节点使用的
    // 对外广告地址，不参与 bind；后续 DHCP/TFTP 接入时也要保持这个区分。
    //
    // Zap/facil.io 安装自己的 SIGINT/SIGTERM handler。当任一信号到达时，
    // 事件循环停止，`zap.start()` 返回，`serve()` 正常返回。
    var serve_error: ?anyerror = null;
    http_server.serve(
        io,
        allocator,
        "0.0.0.0",
        config.server.http_port,
        &live_config,
        &live_catalog,
        &live_models,
        &runtime,
        &event_writer,
        &sessions,
        &statuses,
        &deployments,
        &inventories,
        &operation_store,
        config_revision,
        bootstrap_key,
        additional_keys,
        &daemon_instance_id,
        &status_io_mutex,
        paths.node_status_path,
        config_path,
        &reload_requested,
    ) catch |err| {
        serve_error = err;
    };

    // M4.2：如果请求了 config reload（node add/set/remove），干净退出
    // 以便 systemd 用新 config.json 重启 daemon。这比原地配置替换更简单
    // 且更安全（后者需要重新初始化 DHCP/TFTP/HTTP 状态机）。
    if (reload_requested.load(.acquire)) {
        observe_log.info("config: reload requested, exiting for systemd restart", .{});
        // 进入正常关闭流程，然后 systemd 自动重启。
    }

    // ── 关闭序列（M3.1）───────────────────────────────────────────────────
    // 1. 标记服务为 stopping，使管理 API 能报告该状态。
    // 2. 设置 stop 标志；DHCP/TFTP worker 以 200ms 超时轮询并自行退出，
    //    通过 defer 关闭各自的 socket。
    // 3. join DHCP 和 TFTP worker 线程。
    // 4. 向 DHCP checkpoint worker 发送 flush-and-stop 并 join。
    // 5. 终止活跃 boot session 并停用所有 status。
    // 6. 最终保存 node-status.json（在 status_io_mutex 下）。
    // 7. 写入 service.stopped 事件。
    runtime.service = .stopping;
    observe_log.info("shutdown: stopping protocol workers", .{});
    stop_workers.store(true, .release);
    dhcp_thread.join();
    tftp_thread.join();

    // M3.1: The checkpoint worker must complete its final flush after the DHCP
    // worker has stopped.  It is the sole writer of leases.json; no other
    // thread may write that file while the worker is alive.
    observe_log.info("shutdown: flushing lease checkpoint worker", .{});
    checkpoint_flush_stop.store(true, .release);
    checkpoint_thread.join();

    // 已签发 capability 的 delivery session 在有序重启前保存到权限为 0600
    // 的 checkpoint；下一实例继续使用同一 token 和 session 身份。
    boot_session_store.save(io, allocator, paths.boot_sessions_path, &sessions, now()) catch |err|
        observe_log.err("boot-session: checkpoint failed: {t}", .{err});

    // worker 已退出后才终止活动 session，确保不会再有 DHCP/TFTP 事件引用它们；
    // 每个 session 仍单独写审计终态，随后才写全局 service.stopped。
    var terminated: [boot_session.max_sessions]boot_session.Session = undefined;
    const terminated_count = sessions.terminateAll(boot_session.monotonicNow(), now(), &terminated);
    statuses.deactivateAll();

    // M3.1: final save of node-status.json with all sessions marked inactive.
    {
        var status_snapshot: [node_status.max_statuses]node_status.Status = undefined;
        statuses.snapshot(&status_snapshot);
        while (!status_io_mutex.tryLock()) std.Thread.yield() catch {};
        defer status_io_mutex.unlock();
        status_store.save(io, allocator, paths.node_status_path, &status_snapshot, statuses.currentRevision(), now()) catch |err|
            observe_log.err("status: final persistence failed: {t}", .{err});
    }

    for (terminated[0..terminated_count]) |session| dhcp_server.emitSessionTermination(io, &persistence, session);

    event_writer.appendWithFields(io, allocator, paths.events_path, "service.stopped", "orderly shutdown complete", &.{}) catch |err|
        observe_log.err("events: unable to record service stop: {t}", .{err});

    observe_log.info("shutdown: complete", .{});

    if (serve_error) |err| return err;
}

fn forProfile(config: *const model.AppConfig, name: []const u8) ?*const model.ProfileConfig {
    for (config.profiles) |*profile| if (std.mem.eql(u8, profile.name, name)) return profile;
    return null;
}

/// M3.1：从 `leases.json` 加载 DHCP lease。如果新文件不存在，
/// 尝试从旧版 `runtime.json` 迁移。
fn loadLeases(io: std.Io, allocator: std.mem.Allocator, dhcp: *runtime_state.DhcpState, now_val: i64) void {
    dhcp_store.load(io, allocator, paths.leases_path, dhcp, now_val) catch |err| switch (err) {
        error.FileNotFound => {
            // 新文件缺失：尝试从旧版 runtime.json 迁移 lease。
            dhcp_store.migrateLegacy(io, allocator, paths.runtime_path, dhcp, now_val) catch |legacy_err| switch (legacy_err) {
                error.FileNotFound => {},
                else => observe_log.err("dhcp: ignoring invalid legacy runtime snapshot: {t}", .{legacy_err}),
            };
        },
        else => observe_log.err("dhcp: ignoring invalid leases snapshot: {t}", .{err}),
    };
}

/// M3.1: Load node statuses from `node-status.json`.  If the new file does not
/// exist, attempt to migrate from the legacy `runtime.json`.
fn loadStatuses(io: std.Io, allocator: std.mem.Allocator, store: *node_status.Store) void {
    status_store.load(io, allocator, paths.node_status_path, store) catch |err| switch (err) {
        error.FileNotFound => {
            // New file missing: try legacy runtime.json migration for statuses.
            status_store.migrateLegacy(io, allocator, paths.runtime_path, store) catch |legacy_err| switch (legacy_err) {
                error.FileNotFound => {},
                else => observe_log.err("status: ignoring invalid legacy runtime snapshot: {t}", .{legacy_err}),
            };
        },
        else => observe_log.err("status: ignoring invalid node-status snapshot: {t}", .{err}),
    };
}

fn now() i64 {
    var ts: std.posix.timespec = undefined;
    return if (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts)) == .SUCCESS) @intCast(ts.sec) else 0;
}

/// M3.1 DHCP lease checkpoint worker（检查点工作线程）。
///
/// 它是 `leases.json` 的唯一写入者。DHCP 热路径在每次真实 lease 变更后
/// 只递增 `lease_generation`；此 worker 对比已保存的生成号，在 DhcpState
/// mutex 下获取一致性快照，然后在锁外序列化和保存。使用单调时钟限制
/// 最多每秒保存一次。在 flush-and-stop 时执行最后一次保存后退出。
fn runCheckpoint(
    io: std.Io,
    allocator: std.mem.Allocator,
    dhcp: *runtime_state.DhcpState,
    leases_path: []const u8,
    flush_stop: *const std.atomic.Value(bool),
) void {
    var saved_generation: u64 = 0;
    var leases: [runtime_state.DhcpState.max_leases]runtime_state.DhcpLease = undefined;

    while (true) {
        // Throttle: at most one save attempt per second.
        std.Io.sleep(io, .fromSeconds(1), .awake) catch {};

        if (flush_stop.load(.acquire)) {
            // Final flush: the DHCP worker has already stopped, so no new
            // mutations can occur.  Save unconditionally if there are unsaved
            // changes.  If the final save fails, log the error and exit without
            // faking success or blocking the orderly shutdown indefinitely.
            const gen = dhcp.snapshotWithGeneration(&leases);
            if (gen > saved_generation) {
                dhcp_store.save(io, allocator, leases_path, &leases, now()) catch |err| {
                    observe_log.err("dhcp: checkpoint final flush failed: {t}", .{err});
                };
            }
            return;
        }

        // Normal checkpoint: save only if the generation advanced.
        const gen = dhcp.snapshotWithGeneration(&leases);
        if (gen > saved_generation) {
            dhcp_store.save(io, allocator, leases_path, &leases, now()) catch |err| {
                observe_log.err("dhcp: checkpoint save failed: {t}", .{err});
                // Do not update saved_generation on failure; the unsaved
                // changes remain pending for the next iteration.
                continue;
            };
            saved_generation = gen;
        }
    }
}

fn runDhcp(io: std.Io, socket: std.Io.net.Socket, configs: *config_runtime.ConfigRuntime, runtime: *runtime_state.RuntimeState, persistence: *const dhcp_server.Persistence, stop: *const std.atomic.Value(bool)) void {
    dhcp_server.serveSocket(io, socket, configs, runtime, persistence, stop) catch |err| observe_log.err("dhcp: stopped: {t}", .{err});
}

fn runTftp(
    io: std.Io,
    allocator: std.mem.Allocator,
    socket: std.Io.net.Socket,
    models: *model_runtime.ModelRuntime,
    runtime: *runtime_state.RuntimeState,
    event_writer: *events.Writer,
    sessions: *boot_session.Store,
    stop: *const std.atomic.Value(bool),
) void {
    tftp_server.serveSocket(io, allocator, socket, models, runtime, event_writer, sessions, stop) catch |err|
        observe_log.err("tftp: stopped: {t}", .{err});
}
