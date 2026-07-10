//! nodeforge CLI 使用的最小健康检查 HTTP 客户端。
//! 管理探测固定连接 localhost；PXE 探测只连接配置中的服务 IPv4。

const std = @import("std");
const management = @import("management.zig");

pub const Status = struct {
    /// TCP 连接是否成功建立；false 表示进程不可达或端口未监听。
    reachable: bool,
    /// HTTP 响应是否为 200；false 包括连接成功但响应非 200。
    healthy: bool,
};

/// 探测管理接口 `/healthz`。
/// 使用 `Connection: close` 保证能够以 EOF 作为响应结束，不实现通用 HTTP 客户端。
pub fn health(io: std.Io, port: u16) Status {
    return probeAt(io, management.bind_ip, port, "/healthz", "GET");
}

/// 探测指定 NodeForge IPv4 listener 的 `/healthz`。
/// 该函数不接受 URL、DNS 或 IPv6，避免演变为通用远程管理客户端。
pub fn healthAt(io: std.Io, ip: []const u8, port: u16) Status {
    return probeAt(io, ip, port, "/healthz", "GET");
}

/// 探测本机管理状态接口，确认进程不仅监听端口，而且注册了管理路由。
pub fn managementStatus(io: std.Io, port: u16) Status {
    return probeAt(
        io,
        management.bind_ip,
        port,
        "/api/v1/management/server/status",
        "GET",
    );
}

/// 请求服务端重新校验当前生效配置。
pub fn validateActiveConfig(io: std.Io, port: u16) Status {
    return probeAt(
        io,
        management.bind_ip,
        port,
        "/api/v1/management/config/validate",
        "POST",
    );
}

/// 向指定 IPv4:port 发送一个原始 HTTP 请求并检查首行状态码。
///
/// 使用 `Connection: close` 保证能够以 EOF 作为响应结束，不实现通用 HTTP 客户端。
/// 收发缓冲区在栈上分配，函数返回后自动释放。
fn probeAt(io: std.Io, ip: []const u8, port: u16, path: []const u8, method: []const u8) Status {
    const address = std.Io.net.IpAddress.parseIp4(ip, port) catch
        return .{ .reachable = false, .healthy = false };
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch
        return .{ .reachable = false, .healthy = false };
    defer stream.close(io);

    var send_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    writer.interface.print(
        "{s} {s} HTTP/1.1\r\nHost: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{ method, path, ip },
    ) catch return .{ .reachable = true, .healthy = false };
    writer.interface.flush() catch return .{ .reachable = true, .healthy = false };

    var recv_buffer: [2048]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    const response = reader.interface.takeDelimiterInclusive('\n') catch
        return .{ .reachable = true, .healthy = false };
    return .{
        .reachable = true,
        .healthy = std.mem.findPosLinear(u8, response, 0, " 200 ") != null,
    };
}

test "status distinguishes reachability and health" {
    const status: Status = .{ .reachable = true, .healthy = false };
    try std.testing.expect(status.reachable);
    try std.testing.expect(!status.healthy);
}
