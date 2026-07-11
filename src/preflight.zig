//! 守护进程启动前的无副作用检查。
//!
//! M0 检查唯一 HTTP IPv4 listener 的 TCP 端口可用性；M1 增加固定 UDP 69 TFTP
//! listener 和 `server.server_ip` 的本地 bind 可用性检查。
//!
//! 本模块不启动长期服务，检查与真正启动之间仍存在极短竞态——
//! 服务启动必须继续处理 bind 错误。预检的价值在于在 systemd 启动流程中
//! 提前发现明显的配置错误或端口占用，避免 `ExecStart` 进入不可恢复状态。

const std = @import("std");
const model = @import("model.zig");

/// M0 preflight failures that callers can present as actionable diagnostics.
pub const Error = error{
    HttpAddressUnavailable,
    TftpAdvertiseAddressUnavailable,
    TftpAddressUnavailable,
};

/// TFTP 标准监听端口；不暴露为配置或 CLI 参数。
pub const tftp_port: u16 = 69;

/// 尝试绑定后立即释放 HTTP 与 TFTP 端口，用于发现地址错误和端口占用。
///
/// 检查项：
/// 1. HTTP TCP `0.0.0.0:http_port` — 先 connect 探测活跃 listener，再 SO_REUSEADDR bind
/// 2. `server.server_ip` 的 UDP bind（端口 0）— 确保广告地址在本地可 bind
/// 3. `server.server_ip:69` 的 UDP bind — 确认 TFTP listener 可用
///
/// 该检查与真正启动之间仍存在极短竞态，因此服务启动必须继续处理 bind 错误。
/// HTTP 固定检查 `0.0.0.0:http_port`，因为 `server.server_ip` 不是 HTTP bind 地址；
/// M1 则额外检查该地址可作为固定 UDP/69 TFTP listener 的本地 bind 地址。
pub fn checkPorts(io: std.Io, config: *const model.AppConfig) Error!void {
    checkTcpBind(io, "0.0.0.0", config.server.http_port) catch
        return error.HttpAddressUnavailable;
    // The advertised PXE address must be locally bindable.  This catches a
    // misspelled/nonexistent service address before a daemon can advertise a
    // TFTP endpoint it cannot actually serve.
    checkUdpBind(io, config.server.server_ip, 0) catch
        return error.TftpAdvertiseAddressUnavailable;
    checkUdpBind(io, config.server.server_ip, tftp_port) catch
        return error.TftpAddressUnavailable;
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

/// 尝试绑定后立即释放 UDP 端口。UDP 没有可靠的 connect 探测，因此使用
/// 独占 bind 作为预检；实际服务启动仍须处理预检之后的竞态。
fn checkUdpBind(io: std.Io, ip: []const u8, port: u16) !void {
    const address = try std.Io.net.IpAddress.parseIp4(ip, port);
    var socket = try address.bind(io, .{ .mode = .dgram, .protocol = .udp });
    socket.close(io);
}
