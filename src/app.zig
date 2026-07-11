//! NodeForge 单进程应用生命周期。
//! 负责共享配置/catalog 并启动 HTTP 与 M1 TFTP listener，不承载具体路由业务。
//! 依赖 `model.zig`（配置类型）、`http/server.zig`（HTTP 实现）和
//! `state/runtime.zig`（运行态骨架）；不直接操作文件系统或网络配置。

const std = @import("std");
const model = @import("model.zig");
const http_server = @import("http/server.zig");
const tftp_server = @import("tftp/server.zig");
const runtime_state = @import("state/runtime.zig");
const catalog_runtime = @import("state/catalog_runtime.zig");
const observe_log = @import("observe/log.zig");

/// 启动 M1 TFTP 与唯一 HTTP listener。
///
/// TFTP socket 必须在 HTTP loop 前完成 bind；这样 daemon 不会在 UDP 69 不可用时
/// 仍以“已启动”状态只提供一半服务。TFTP 在独立线程运行，HTTP 继续保持 M0 的串行模型。
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
    var live_catalog = catalog_runtime.CatalogRuntime.init(allocator, catalog_path, catalog);
    const tftp_socket = try tftp_server.bind(io);
    var tftp_thread = try std.Thread.spawn(.{}, runTftp, .{ io, tftp_socket, config, &live_catalog, &runtime });
    tftp_thread.detach();
    observe_log.info("tftp: listening on udp://0.0.0.0:{d} (advertise {s})", .{ tftp_server.port, config.server.server_ip });

    // HTTP 明确绑定所有 IPv4 地址。`server.server_ip` 是给裸机节点使用的
    // 对外广告地址，不参与 bind；后续 DHCP/TFTP 接入时也要保持这个区分。
    try http_server.serve(
        io,
        allocator,
        "0.0.0.0",
        config.server.http_port,
        config,
        &live_catalog,
        &runtime,
    );
}

fn runTftp(
    io: std.Io,
    socket: std.Io.net.Socket,
    config: *const model.AppConfig,
    catalog: *catalog_runtime.CatalogRuntime,
    runtime: *runtime_state.RuntimeState,
) void {
    tftp_server.serveSocket(io, socket, config, catalog, runtime) catch |err|
        observe_log.err("tftp: stopped: {t}", .{err});
}
