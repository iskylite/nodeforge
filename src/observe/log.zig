//! NodeForge M0 服务日志门面。
//! 默认只输出日常 info/error；debug 由启动配置或 daemon `--debug` 启用。

const std = @import("std");

/// 服务日志等级。M0 只区分日常信息与深度诊断。
pub const Level = enum { info, debug };

var current_level: Level = .info;

/// 设置当前进程的服务日志等级。
/// M0 单进程启动期设置一次，后续运行期日志读取该值。
pub fn setLevel(level: Level) void {
    current_level = level;
}

/// 输出日常服务日志。
pub fn info(comptime format: []const u8, args: anytype) void {
    std.debug.print("info: " ++ format ++ "\n", args);
}

/// 输出错误摘要；调用方不得传入密码、token 或请求体。
pub fn err(comptime format: []const u8, args: anytype) void {
    std.debug.print("error: " ++ format ++ "\n", args);
}

/// 仅在 debug 等级输出协议和连接诊断。
pub fn debug(comptime format: []const u8, args: anytype) void {
    if (current_level == .debug) std.debug.print("debug: " ++ format ++ "\n", args);
}
