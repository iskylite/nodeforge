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

/// M1 TFTP 传输计数器，由 daemon 的本机管理路由返回。
/// 字段全部通过简单 JSON 解析提取，不依赖通用 JSON 库以保持 CLI 轻量。
pub const TftpCounters = struct {
    reachable: bool = false,
    healthy: bool = false,
    started: u64 = 0,
    completed: u64 = 0,
    failed: u64 = 0,
};

/// M1 资产导入请求的受约束元数据。由 CLI 构造，通过本地 HTTP POST 发送给 daemon。
/// daemon 负责计算 SHA-256、校验路径安全性和原子写入 catalog。
/// 所有字段在发送前经过 `querySafe` 检查，拒绝包含 URL 特殊字符的值。
pub const AssetImport = struct {
    name: []const u8,
    kind: []const u8,
    path: []const u8,
    distro: ?[]const u8 = null,
    version: ?[]const u8 = null,
    arch: ?[]const u8 = null,
    kernel_release: ?[]const u8 = null,
};

/// M3.6 ISO 导入请求。CLI 先将管理员拥有的任意 ISO 原子复制到 daemon
/// 管控的 staging 目录；只有生成的不透明文件名被发送到本机管理端点。
/// distro/version/arch 三个字段是可选的一致性断言，因为 daemon 会从 ISO
/// 元数据（.treeinfo 或 .disk/info）自动检测并规范化三元组。如果操作员
/// 提供了断言值但与检测结果不一致，daemon 拒绝导入。
pub const InstallSourceImport = struct {
    /// 已暂存到 import_dir 的 ISO 文件名（不含路径前缀），由 CLI 生成。
    filename: []const u8,
    /// 可选的发行版断言；daemon 从 ISO 元数据检测后与之比对。
    distro: ?[]const u8 = null,
    /// 可选的版本断言；daemon 从 ISO 元数据检测后与之比对。
    version: ?[]const u8 = null,
    /// 可选的架构断言；daemon 从 ISO 元数据检测后与之比对。
    arch: ?[]const u8 = null,
};

/// 探测管理接口 `/healthz`。
/// 使用 `Connection: close` 保证能够以 EOF 作为响应结束，不实现通用 HTTP 客户端。
pub fn health(io: std.Io, port: u16) Status {
    return probeAt(io, management.client_ip, port, "/healthz", "GET");
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
        management.client_ip,
        port,
        "/api/v1/management/server/status",
        "GET",
    );
}

/// 请求服务端重新校验当前生效配置。
pub fn validateActiveConfig(io: std.Io, port: u16) Status {
    return probeAt(
        io,
        management.client_ip,
        port,
        "/api/v1/management/config/validate",
        "POST",
    );
}

/// 探测 M1 TFTP 运行态路由。仅由本机 daemon 提供，不接受远程地址。
pub fn tftpStatus(io: std.Io, port: u16) Status {
    return probeAt(io, management.client_ip, port, "/api/v1/management/tftp/status", "GET");
}

/// 读取 M1 TFTP 计数器响应并解析为 `TftpCounters`。
///
/// 这是一个固定路由的小型 HTTP 客户端，不实现通用远程管理。
/// 解析使用简单的字符串查找提取 `started`/`completed`/`failed` 三个数字字段，
/// 不依赖通用 JSON 库以保持 CLI 依赖最小化。
pub fn tftpCounters(io: std.Io, port: u16) TftpCounters {
    const address = std.Io.net.IpAddress.parseIp4(management.client_ip, port) catch return .{};
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return .{};
    defer stream.close(io);
    var send_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    writer.interface.print("GET /api/v1/management/tftp/status HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{}) catch return .{ .reachable = true };
    writer.interface.flush() catch return .{ .reachable = true };
    var recv_buffer: [2048]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    const status_line = reader.interface.takeDelimiterInclusive('\n') catch return .{ .reachable = true };
    if (std.mem.findPosLinear(u8, status_line, 0, " 200 ") == null) return .{ .reachable = true };
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch return .{ .reachable = true };
        if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
    }
    const body = reader.interface.takeDelimiterInclusive('\n') catch return .{ .reachable = true };
    return .{ .reachable = true, .healthy = true, .started = jsonCounter(body, "\"started\":"), .completed = jsonCounter(body, "\"completed\":"), .failed = jsonCounter(body, "\"failed\":") };
}

/// 获取 daemon 生成的 TFTP 会话列表 JSON，并写入调用方提供的缓冲区。
///
/// 返回写入的字节切片；如果响应超过 `output` 容量则返回 `error.ResponseTooLarge`。
/// 调用方负责格式化输出；本函数只负责固定路由的 HTTP GET 和响应体提取。
/// 仅连接 `127.0.0.1`，不接受远程端点。
pub fn tftpSessionsJson(io: std.Io, port: u16, output: []u8) !?[]const u8 {
    return managementJson(io, port, "/api/v1/management/tftp/sessions", output);
}

/// 从本机管理路由获取 M2 DHCP lease 观测数据。
/// `unknown_only` 为 true 时只返回未认领节点的 lease，false 返回全部。
/// 仅连接 `127.0.0.1`，不接受远程端点。
pub fn dhcpLeasesJson(io: std.Io, port: u16, unknown_only: bool, output: []u8) !?[]const u8 {
    return managementJson(io, port, if (unknown_only) "/api/v1/management/dhcp/unknown" else "/api/v1/management/dhcp/leases", output);
}

fn managementJson(io: std.Io, port: u16, path: []const u8, output: []u8) !?[]const u8 {
    const address = std.Io.net.IpAddress.parseIp4(management.client_ip, port) catch return null;
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return null;
    defer stream.close(io);
    var send_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{path});
    try writer.interface.flush();
    var recv_buffer: [12 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    const status_line = reader.interface.takeDelimiterInclusive('\n') catch return null;
    if (std.mem.findPosLinear(u8, status_line, 0, " 200 ") == null) return null;
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch return null;
        if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
    }
    const body = reader.interface.takeDelimiterInclusive('\n') catch return null;
    if (body.len > output.len) return error.ResponseTooLarge;
    @memcpy(output[0..body.len], body);
    return output[0..body.len];
}

/// 请求 daemon 导入资产并写入 catalog。
///
/// 所有字段在发送前经过 `querySafe` 检查，拒绝包含 `&=?#%\r\n` 的值，
/// 防止 URL 注入。请求通过 `POST /api/v1/management/assets/import` 发送，
/// 参数放在 query string 中，Content-Length 为 0。
/// daemon 负责计算 SHA-256、校验路径和原子写入 catalog。
/// 返回 `true` 表示 daemon 接受了导入（HTTP 200），`false` 表示拒绝或连接失败。
pub fn importAsset(io: std.Io, port: u16, asset: AssetImport) !bool {
    inline for ([_][]const u8{ asset.name, asset.kind, asset.path }) |value|
        if (!querySafe(value)) return error.InvalidAssetField;
    inline for ([_]?[]const u8{ asset.distro, asset.version, asset.arch, asset.kernel_release }) |optional|
        if (optional) |value| if (!querySafe(value)) return error.InvalidAssetField;
    const address = try std.Io.net.IpAddress.parseIp4(management.client_ip, port);
    var stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    var send_buffer: [2048]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.print("POST /api/v1/management/assets/import?name={s}&kind={s}&path={s}", .{ asset.name, asset.kind, asset.path });
    if (asset.distro) |value| try writer.interface.print("&distro={s}", .{value});
    if (asset.version) |value| try writer.interface.print("&version={s}", .{value});
    if (asset.arch) |value| try writer.interface.print("&arch={s}", .{value});
    if (asset.kernel_release) |value| try writer.interface.print("&kernel_release={s}", .{value});
    try writer.interface.writeAll(" HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();
    var recv_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    const status = reader.interface.takeDelimiterInclusive('\n') catch return false;
    return std.mem.findPosLinear(u8, status, 0, " 200 ") != null;
}

/// 请求 daemon 导入已暂存的 ISO 并发布 install source。
///
/// M3.6 安全设计：此函数只接受不透明文件名（不含路径前缀），
/// 因为 ISO 已由 CLI 复制到 daemon 管控的 import_dir。
/// daemon 在受管根内打开文件，不会接触任意 host 路径。
///
/// 所有字段在发送前经过 `querySafe` 检查，拒绝包含 `&=?#%\r\n` 的值，
/// 防止 URL 参数注入。请求通过 `POST /api/v1/management/install-sources/import`
/// 发送，参数放在 query string 中，Content-Length 为 0。
/// 返回 `true` 表示 daemon 接受了导入（HTTP 200），`false` 表示拒绝或连接失败。
pub fn importInstallSource(io: std.Io, port: u16, request: InstallSourceImport) !bool {
    if (!querySafe(request.filename)) return error.InvalidInstallSourceField;
    inline for ([_]?[]const u8{ request.distro, request.version, request.arch }) |optional|
        if (optional) |value|
            if (!querySafe(value)) return error.InvalidInstallSourceField;
    const address = try std.Io.net.IpAddress.parseIp4(management.client_ip, port);
    var stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    var send_buffer: [2048]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.print("POST /api/v1/management/install-sources/import?filename={s}", .{request.filename});
    if (request.distro) |value| try writer.interface.print("&distro={s}", .{value});
    if (request.version) |value| try writer.interface.print("&version={s}", .{value});
    if (request.arch) |value| try writer.interface.print("&arch={s}", .{value});
    try writer.interface.writeAll(" HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();
    var recv_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    const status = reader.interface.takeDelimiterInclusive('\n') catch return false;
    return std.mem.findPosLinear(u8, status, 0, " 200 ") != null;
}

/// 检查值是否可安全嵌入 HTTP query string。
/// 拒绝空字符串和包含 `&=?#%\r\n` 的值，防止 URL 参数注入。
fn querySafe(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfAny(u8, value, "&=?#%\r\n") == null;
}

/// 从简单 JSON 响应体中提取数字字段的值。
/// 使用字符串查找定位 `key`，然后解析到下一个 `,` 或 `}` 为止的数字。
/// 解析失败时返回 0，不产生错误——计数器是尽力而为的运行态摘要。
fn jsonCounter(body: []const u8, key: []const u8) u64 {
    const start = std.mem.indexOf(u8, body, key) orelse return 0;
    const value = body[start + key.len ..];
    const end = std.mem.indexOfAny(u8, value, ",}") orelse value.len;
    return std.fmt.parseInt(u64, value[0..end], 10) catch 0;
}

/// 向指定 IPv4:port 发送一个原始 HTTP 请求并检查首行状态码。
///
/// 使用 `Connection: close` 保证能够以 EOF 作为响应结束，不实现通用 HTTP 客户端。
/// 收发缓冲区在栈上分配，函数返回后自动释放。
/// 返回的 `Status` 区分 TCP 连接可达性（`reachable`）和 HTTP 200 响应（`healthy`）。
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
