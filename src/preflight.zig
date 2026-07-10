//! 守护进程启动前的无副作用检查。
//! M0 只检查唯一 HTTP IPv4 listener；UDP 端口随对应协议阶段接入。
//! 本模块不启动长期服务，检查与真正启动之间仍存在极短竞态——
//! 服务启动必须继续处理 bind 错误。

const std = @import("std");
const model = @import("model.zig");
pub const Error = error{
    HttpAddressUnavailable,
};

/// 尝试绑定后立即释放 HTTP 端口，用于发现地址错误和端口占用。
/// 该检查与真正启动之间仍存在极短竞态，因此服务启动必须继续处理 bind 错误。
/// M0 固定检查 `0.0.0.0:http_port`，因为 `server.server_ip` 是对外广告地址，不是 HTTP bind 地址。
pub fn checkHttpPorts(io: std.Io, config: *const model.AppConfig) Error!void {
    checkTcpBind(io, "0.0.0.0", config.server.http_port) catch
        return error.HttpAddressUnavailable;
}

fn checkTcpBind(io: std.Io, ip: []const u8, port: u16) !void {
    const address = try std.Io.net.IpAddress.parseIp4(ip, port);
    // 与正式 HTTP listener 一致，允许快速重启复用刚释放的地址；
    // 未启用 reuse_port，活跃实例仍会让该检查失败。
    var listener = try address.listen(io, .{ .reuse_address = true });
    listener.deinit(io);
}
