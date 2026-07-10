//! 守护进程启动前的无副作用检查。
//! M0 只检查唯一 HTTP IPv4 listener；UDP 端口随对应协议阶段接入。
//! 本模块不启动长期服务，检查与真正启动之间仍存在极短竞态——
//! 服务启动必须继续处理 bind 错误。

const std = @import("std");
const model = @import("model.zig");

/// M0 preflight failures that callers can present as actionable diagnostics.
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
    // 首先探测已有 TCP listener。macOS 在两个 socket 都设置 SO_REUSEADDR
    // 时允许它们共同 bind wildcard 地址，单靠 bind 无法识别活跃实例。
    // 本机连接成功后立即拒绝；连接失败则继续以 SO_REUSEADDR bind，避免
    // systemd 快速重启被刚释放 socket 的 TIME_WAIT 窗口误伤。
    if (address.connect(io, .{ .mode = .stream, .protocol = .tcp })) |stream| {
        var connected = stream;
        connected.close(io);
        return error.HttpAddressUnavailable;
    } else |_| {}

    // 没有活跃 listener 后，允许刚释放端口快速复用。正式 listener 仍须处理
    // bind 竞态；预检本身不承诺替代实际启动时的独占校验。
    var listener = try address.listen(io, .{ .reuse_address = true });
    listener.deinit(io);
}
