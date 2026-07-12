//! NodeForge 单进程应用生命周期。
//! 负责共享配置/catalog 并启动 HTTP 与 M1 TFTP listener，不承载具体路由业务。
//! 依赖 `model.zig`（配置类型）、`http/server.zig`（HTTP 实现）和
//! `state/runtime.zig`（运行态骨架）；不直接操作文件系统或网络配置。
//!
//! M2.5/M2.5.1 shutdown coordinator: 当 HTTP 事件循环退出（SIGINT/SIGTERM 或错误），
//! 设置共享 stop 标志，DHCP/TFTP worker 通过 200ms 超时轮询检测到后自行退出
//! 并 close 各自的 socket，主线程 join worker 线程、持久化运行态、写入
//! 每个活动 boot session 的 `boot.session.terminated` 和 `service.stopped` 事件。
//! 初始化失败或 SIGKILL 等不可控终止不写入这些有序终态事件。

const std = @import("std");
const model = @import("model.zig");
const http_server = @import("http/server.zig");
const tftp_server = @import("tftp/server.zig");
const dhcp_server = @import("dhcp/server.zig");
const runtime_state = @import("state/runtime.zig");
const catalog_runtime = @import("state/catalog_runtime.zig");
const observe_log = @import("observe/log.zig");
const paths = @import("paths.zig");
const dhcp_store = @import("state/dhcp_store.zig");
const events = @import("state/events.zig");
const boot_session = @import("state/boot_session.zig");
const node_status = @import("state/node_status.zig");

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
    dhcp_store.load(io, allocator, paths.runtime_path, &runtime.dhcp, &statuses, current_time) catch |err| switch (err) {
        error.FileNotFound => {},
        else => observe_log.err("dhcp: ignoring invalid runtime snapshot: {t}", .{err}),
    };
    var event_writer: events.Writer = .{};
    event_writer.configure(config.events.max_size_mb, config.events.keep);
    // 进程 id 与 boot session id 使用同一不可预测编码，但生命周期不同：前者
    // 标记本次 daemon 启动，后者只关联一台节点的一次启动尝试。
    var daemon_instance_id: [boot_session.id_len]u8 = undefined;
    try boot_session.generateId(io, &daemon_instance_id);
    try event_writer.setDaemonInstanceId(daemon_instance_id);
    var sessions: boot_session.Store = .{};
    var runtime_mutex: std.atomic.Mutex = .unlocked;
    var last_runtime_checkpoint = std.atomic.Value(i64).init(0);

    event_writer.appendWithFields(io, allocator, paths.events_path, "config.loaded", "validated configuration loaded", &.{}) catch |err|
        observe_log.err("events: unable to record configuration load: {t}", .{err});
    const persistence: dhcp_server.Persistence = .{
        .allocator = allocator,
        .runtime_path = paths.runtime_path,
        .events_path = paths.events_path,
        .writer = &event_writer,
        .sessions = &sessions,
        .statuses = &statuses,
        .runtime_mutex = &runtime_mutex,
        .last_runtime_checkpoint = &last_runtime_checkpoint,
    };
    var live_catalog = catalog_runtime.CatalogRuntime.init(allocator, catalog_path, catalog);
    // DHCP needs a wildcard receive socket for client broadcasts.  The DHCP
    // server applies the configured PXE NIC as a Linux socket-level boundary;
    // TFTP remains bound to the advertised unicast address below.
    const dhcp_socket = try dhcp_server.bind(io, config.server.server_ip, config.server.bind_interface);
    var stop_workers = std.atomic.Value(bool).init(false);
    var dhcp_thread = try std.Thread.spawn(.{}, runDhcp, .{ io, dhcp_socket, config, &runtime, &persistence, &stop_workers });
    observe_log.info("dhcp: listening on udp://{s}:{d}", .{ config.server.server_ip, dhcp_server.port });
    const tftp_socket = try tftp_server.bind(io, config.server.server_ip);
    var tftp_thread = try std.Thread.spawn(.{}, runTftp, .{ io, allocator, tftp_socket, config, &live_catalog, &runtime, &event_writer, &sessions, &stop_workers });
    observe_log.info("tftp: listening on udp://{s}:{d}", .{ config.server.server_ip, tftp_server.port });

    // HTTP 明确绑定所有 IPv4 地址。`server.server_ip` 是给裸机节点使用的
    // 对外广告地址，不参与 bind；后续 DHCP/TFTP 接入时也要保持这个区分。
    //
    // Zap/facil.io installs its own SIGINT/SIGTERM handler. When either signal
    // arrives, the event loop stops and `zap.start()` returns, causing
    // `serve()` to return normally.
    var serve_error: ?anyerror = null;
    http_server.serve(
        io,
        allocator,
        "0.0.0.0",
        config.server.http_port,
        config,
        &live_catalog,
        &runtime,
        &event_writer,
        &sessions,
        &statuses,
        &daemon_instance_id,
        &persistence,
    ) catch |err| {
        serve_error = err;
    };

    // ── Shutdown sequence ──────────────────────────────────────────────
    // 1. Mark service as stopping so management API can report the state.
    // 2. Set stop flag; workers poll with 200ms timeout and self-exit,
    //    closing their own sockets via defer.
    // 3. Join worker threads (wait for orderly exit).
    // 4. Persist runtime state.
    // 5. Write service.stopped event.
    runtime.service = .stopping;
    observe_log.info("shutdown: stopping protocol workers", .{});
    stop_workers.store(true, .release);
    dhcp_thread.join();
    tftp_thread.join();

    while (!runtime_mutex.tryLock()) std.Thread.yield() catch {};
    dhcp_store.save(io, allocator, paths.runtime_path, &runtime.dhcp, &statuses, now()) catch |err|
        observe_log.err("dhcp: runtime persistence failed: {t}", .{err});
    runtime_mutex.unlock();

    // worker 已退出后才终止活动 session，确保不会再有 DHCP/TFTP 事件引用它们；
    // 每个 session 仍单独写审计终态，随后才写全局 service.stopped。
    var terminated: [boot_session.max_sessions]boot_session.Session = undefined;
    const terminated_count = sessions.terminateAll(boot_session.monotonicNow(), now(), &terminated);
    statuses.deactivateAll();
    for (terminated[0..terminated_count]) |session| dhcp_server.emitSessionTermination(io, &persistence, session);

    event_writer.appendWithFields(io, allocator, paths.events_path, "service.stopped", "orderly shutdown complete", &.{}) catch |err|
        observe_log.err("events: unable to record service stop: {t}", .{err});

    observe_log.info("shutdown: complete", .{});

    if (serve_error) |err| return err;
}

fn now() i64 {
    var ts: std.posix.timespec = undefined;
    return if (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &ts)) == .SUCCESS) @intCast(ts.sec) else 0;
}

fn runDhcp(io: std.Io, socket: std.Io.net.Socket, config: *const model.AppConfig, runtime: *runtime_state.RuntimeState, persistence: *const dhcp_server.Persistence, stop: *const std.atomic.Value(bool)) void {
    dhcp_server.serveSocket(io, socket, config, runtime, persistence, stop) catch |err| observe_log.err("dhcp: stopped: {t}", .{err});
}

fn runTftp(
    io: std.Io,
    allocator: std.mem.Allocator,
    socket: std.Io.net.Socket,
    config: *const model.AppConfig,
    catalog: *catalog_runtime.CatalogRuntime,
    runtime: *runtime_state.RuntimeState,
    event_writer: *events.Writer,
    sessions: *boot_session.Store,
    stop: *const std.atomic.Value(bool),
) void {
    tftp_server.serveSocket(io, allocator, socket, config, catalog, runtime, event_writer, sessions, stop) catch |err|
        observe_log.err("tftp: stopped: {t}", .{err});
}
