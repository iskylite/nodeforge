//! NodeForge 服务日志门面。
//! 实际等级由 `config.logging.level` 决定；fresh setup 在开发阶段写入 debug，
//! 既有/导入配置保留自身等级，daemon `--debug` 只对本次启动强制覆盖。

const std = @import("std");
const backend = @import("log_backend.zig");
const model = @import("../model.zig");

/// NodeForge 服务日志的 scoped logger。所有模块通过此 logger 输出日志，
/// 确保日志前缀统一为 `[nodeforge]`。
pub const log = std.log.scoped(.nodeforge);

/// 服务日志等级，按严重程度从低到高排列。
pub const Level = model.LogLevel;

/// HTTP/TFTP worker 与启动线程都会读取此值，必须使用原子变量避免 debug
/// 配置在 worker 线程中出现数据竞争或不可见。
/// 设置当前进程的服务日志等级。
/// M0 单进程启动期设置一次，后续运行期日志读取该值。
pub fn setLevel(level: Level) void {
    backend.setLevel(toStdLevel(level));
}

/// 输出日常服务日志。
pub fn info(comptime format: []const u8, args: anytype) void {
    log.info(format, args);
}

/// 输出可恢复异常摘要。
pub fn warn(comptime format: []const u8, args: anytype) void {
    log.warn(format, args);
}

/// 输出错误摘要；调用方不得传入密码、token 或请求体。
pub fn err(comptime format: []const u8, args: anytype) void {
    log.err(format, args);
}

/// 仅在 debug 等级输出协议和连接诊断。
pub fn debug(comptime format: []const u8, args: anytype) void {
    log.debug(format, args);
}

/// 将 `model.LogLevel` 转换为 `std.log.Level`，供 `log_backend` 使用。
fn toStdLevel(level: Level) std.log.Level {
    return level.toStdLevel();
}
