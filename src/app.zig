//! NodeForge 单进程应用生命周期。
//! 负责共享配置/catalog 并启动唯一 HTTP listener，不承载具体路由业务。
//! 依赖 `model.zig`（配置类型）、`http/server.zig`（HTTP 实现）和
//! `state/runtime.zig`（运行态骨架）；不直接操作文件系统或网络配置。

const std = @import("std");
const model = @import("model.zig");
const http_server = @import("http/server.zig");
const runtime_state = @import("state/runtime.zig");

/// 启动唯一 HTTP listener。管理路由和 PXE 数据路由共享同一端口。
pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    config: *const model.AppConfig,
    catalog: *const model.Catalog,
) !void {
    _ = allocator;
    var runtime: runtime_state.RuntimeState = .{
        .service = .running,
        .config_generation = 1,
    };
    // M0 明确绑定所有 IPv4 地址。`server.server_ip` 是给裸机节点使用的
    // 对外广告地址，不参与 bind；后续 DHCP/TFTP 接入时也要保持这个区分。
    try http_server.serve(
        io,
        "0.0.0.0",
        config.server.http_port,
        config,
        catalog,
        &runtime,
    );
}
