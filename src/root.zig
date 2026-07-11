//! NodeForge 核心库入口。
//! 统一导出配置事实模型、校验器和服务实现，业务模块不得重复定义影子结构。

pub const model = @import("model.zig");
pub const paths = @import("paths.zig");
pub const version = @import("version.zig");
pub const catalog = @import("catalog.zig");
pub const catalog_store = @import("catalog/store.zig");
pub const app = @import("app.zig");
pub const config = @import("config/load.zig");
pub const config_store = @import("config/store.zig");
pub const config_validate = @import("config/validate.zig");
pub const preflight = @import("preflight.zig");
pub const runtime_state = @import("state/runtime.zig");
pub const catalog_runtime = @import("state/catalog_runtime.zig");
pub const events = @import("state/events.zig");
pub const management_client = @import("http/client.zig");
pub const management = @import("http/management.zig");
pub const http_server = @import("http/server.zig");
pub const tftp_packet = @import("tftp/packet.zig");
pub const tftp_server = @import("tftp/server.zig");
pub const asset_validate = @import("assets/validate.zig");
pub const grub = @import("boot/grub.zig");
pub const observe_error = @import("observe/error.zig");
pub const observe_log = @import("observe/log.zig");

test {
    _ = model;
    _ = paths;
    _ = version;
    _ = catalog;
    _ = catalog_store;
    _ = app;
    _ = config;
    _ = config_store;
    _ = config_validate;
    _ = preflight;
    _ = runtime_state;
    _ = catalog_runtime;
    _ = events;
    _ = management_client;
    _ = management;
    _ = http_server;
    _ = tftp_packet;
    _ = tftp_server;
    _ = asset_validate;
    _ = grub;
    _ = observe_error;
    _ = observe_log;
}
