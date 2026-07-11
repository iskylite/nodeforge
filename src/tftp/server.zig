//! M1 只读 TFTP 服务。
//!
//! dispatcher 固定监听 UDP 69；每个 RRQ 使用独立临时 UDP socket 传输，符合 TFTP
//! transfer identifier (TID) 语义——服务器和客户端在 RRQ 后通过不同端口传输后续
//! DATA/ACK，允许 dispatcher 在传输期间继续接收新请求。
//!
//! 线程模型：TFTP 在独立线程运行，与 HTTP 的 Zap 事件循环并行。
//! `RuntimeState.tftp` 使用原子计数器和自旋锁保护会话列表，确保 UDP worker
//! 与 HTTP 管理路由的并发读取不产生数据竞争。
//!
//! 安全模型：文件必须同时通过相对路径安全检查和 catalog 白名单检查。
//! 路径安全拒绝 `..`、绝对路径、Windows 分隔符和符号链接逃逸；
//! catalog 白名单确保只有已导入且校验过 SHA-256 的文件可被 TFTP 提供。
//! MVP 不实现 WRQ，收到写请求直接返回标准 ERROR。

const std = @import("std");
const model = @import("../model.zig");
const catalog_runtime = @import("../state/catalog_runtime.zig");
const packet = @import("packet.zig");
const runtime_state = @import("../state/runtime.zig");

/// TFTP 标准监听端口（RFC 1350）；不暴露为配置或 CLI 参数。
pub const port: u16 = 69;
/// 单个 RRQ 最多接受的 option 数量（RFC 2347）。
const max_options = 8;
/// 允许的最大 `blksize` 值（RFC 2348）；超过此值的请求被拒绝。
/// 受限于 UDP datagram 最大安全负载（65535 - 20 IP - 8 UDP = 65507）。
const max_block_size: usize = 65_464;
/// DATA 重传次数上限；超过后放弃传输。RFC 1350 建议超时重传。
const max_retries = 3;

/// 在固定 UDP 69 上运行 TFTP RRQ dispatcher。
///
/// `config` 提供 TFTP asset root 路径；`catalog` 提供资产白名单快照；
/// `runtime` 记录会话计数和活动列表。三者必须在 `serve` 的整个生命周期内保持有效。
pub fn serve(io: std.Io, config: *const model.AppConfig, catalog: *catalog_runtime.CatalogRuntime, runtime: *runtime_state.RuntimeState) !void {
    const socket = try bind(io);
    try serveSocket(io, socket, config, catalog, runtime);
}

/// 绑定固定 UDP 69；供 daemon 在启动其他 listener 前确认 TFTP 可用。
/// 返回的 socket 由调用方负责关闭（通过 `serveSocket` 或手动 `close`）。
pub fn bind(io: std.Io) !std.Io.net.Socket {
    const address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
    return address.bind(io, .{ .mode = .dgram, .protocol = .udp });
}

/// 在已绑定 socket 上运行 RRQ dispatcher。调用方转移 socket 的关闭责任。
///
/// 主循环：接收 UDP datagram -> 解析 TFTP 报文 -> 如果是 RRQ 则启动文件传输 ->
/// 传输在当前线程串行完成（M1 单 worker 模型）。WRQ 返回 ERROR；其他类型返回 ERROR。
pub fn serveSocket(io: std.Io, owned_socket: std.Io.net.Socket, config: *const model.AppConfig, catalog: *catalog_runtime.CatalogRuntime, runtime: *runtime_state.RuntimeState) !void {
    var socket = owned_socket;
    defer socket.close(io);

    while (true) {
        var recv_buffer: [2048]u8 = undefined;
        const incoming = try socket.receive(io, &recv_buffer);
        var options: [max_options]packet.Option = undefined;
        const message = packet.parse(incoming.data, &options) catch {
            try sendError(&socket, io, &incoming.from, .illegal_operation, "invalid TFTP request");
            continue;
        };
        switch (message) {
            .rrq => |request| {
                const session = runtime.tftp.begin(request.filename);
                transfer(io, &incoming.from, request, config.tftp.asset_root, catalog) catch |err| {
                    runtime.tftp.finish(session, false);
                    const response: struct { code: packet.ErrorCode, message: []const u8 } = switch (err) {
                        error.FileNotAllowed, error.FileNotFound => .{ .code = .file_not_found, .message = "file not found" },
                        error.UnsupportedMode, error.InvalidOption => .{ .code = .illegal_operation, .message = "unsupported request" },
                        error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => .{ .code = .access_violation, .message = "access denied" },
                        else => .{ .code = .undefined, .message = "transfer failed" },
                    };
                    try sendError(&socket, io, &incoming.from, response.code, response.message);
                    continue;
                };
                runtime.tftp.finish(session, true);
            },
            .wrq => try sendError(&socket, io, &incoming.from, .access_violation, "write requests are disabled"),
            else => try sendError(&socket, io, &incoming.from, .illegal_operation, "expected RRQ"),
        }
    }
}

/// 执行单个 RRQ 的完整文件传输。
///
/// 流程：
/// 1. 校验 mode 和路径安全性（相对路径 + catalog 白名单）
/// 2. 打开文件，计算 `stat().size` 用于 `tsize` option
/// 3. 协商 `blksize`/`timeout`/`tsize` options，如有则发送 OACK 并等待 ACK
/// 4. 按 `blksize` 分块读取文件，发送 DATA，等待 ACK，超时重传（最多 `max_retries` 次）
/// 5. 最后一个 DATA 的负载小于 `blksize` 时传输完成
///
/// 每个 RRQ 使用独立的临时 UDP socket（TID），不阻塞 dispatcher 接收新请求。
fn transfer(
    io: std.Io,
    remote: *const std.Io.net.IpAddress,
    request: packet.Request,
    asset_root: []const u8,
    catalog: *catalog_runtime.CatalogRuntime,
) !void {
    if (!std.ascii.eqlIgnoreCase(request.mode, "octet")) return error.UnsupportedMode;
    if (!isSafeRelativePath(request.filename) or !isManifestPath(catalog, request.filename))
        return error.FileNotAllowed;

    var root = try std.Io.Dir.openDirAbsolute(io, asset_root, .{ .access_sub_paths = true });
    defer root.close(io);
    var file = try root.openFile(io, request.filename, .{
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    defer file.close(io);
    const file_size = (try file.stat(io)).size;
    const settings = try negotiate(request.options, file_size);

    const local = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 0);
    var socket = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);

    if (settings.hasOptions()) {
        var out: [1024]u8 = undefined;
        var option_values: [3][20]u8 = undefined;
        var accepted: [3]packet.Option = undefined;
        const oack = try packet.encodeOack(&out, settings.oackOptions(file_size, &option_values, &accepted));
        try socket.send(io, remote, oack);
        try awaitAck(&socket, io, remote, 0, settings.timeout);
    }

    var block: u16 = 1;
    var offset: u64 = 0;
    var data: [max_block_size]u8 = undefined;
    while (true) {
        const capacity = data[0..settings.block_size];
        const read = try file.readPositionalAll(io, capacity, offset);
        var out: [max_block_size + 4]u8 = undefined;
        const datagram = try packet.encodeData(&out, block, capacity[0..read]);
        var attempts: usize = 0;
        while (true) {
            try socket.send(io, remote, datagram);
            awaitAck(&socket, io, remote, block, settings.timeout) catch |err| {
                if (err == error.Timeout and attempts < max_retries) {
                    attempts += 1;
                    continue;
                }
                return err;
            };
            break;
        }
        offset += read;
        if (read < settings.block_size) return;
        block +%= 1;
    }
}

/// 传输参数协商结果。仅接受 `blksize`/`timeout`/`tsize` 三个标准 option。
/// 其他 option 被安全忽略，不返回给客户端。
const Settings = struct {
    block_size: usize = packet.default_block_size,
    timeout: u8 = 3,
    use_blksize: bool = false,
    use_timeout: bool = false,
    use_tsize: bool = false,

    fn hasOptions(self: Settings) bool {
        return self.use_blksize or self.use_timeout or self.use_tsize;
    }

    fn oackOptions(self: Settings, file_size: u64, values: *[3][20]u8, options: *[3]packet.Option) []const packet.Option {
        var count: usize = 0;
        if (self.use_blksize) {
            const value = std.fmt.bufPrint(&values[count], "{d}", .{self.block_size}) catch unreachable;
            options[count] = .{ .name = "blksize", .value = value };
            count += 1;
        }
        if (self.use_timeout) {
            const value = std.fmt.bufPrint(&values[count], "{d}", .{self.timeout}) catch unreachable;
            options[count] = .{ .name = "timeout", .value = value };
            count += 1;
        }
        if (self.use_tsize) {
            const value = std.fmt.bufPrint(&values[count], "{d}", .{file_size}) catch unreachable;
            options[count] = .{ .name = "tsize", .value = value };
            count += 1;
        }
        return options[0..count];
    }
};

/// 解析客户端请求的 options 并生成协商结果。
///
/// - `blksize`：接受 8 到 `max_block_size` 之间的值（RFC 2348）
/// - `timeout`：接受 1-255 秒，0 被拒绝（RFC 2349）
/// - `tsize`：仅当客户端发送 `0` 时返回文件实际大小（RFC 2349）
/// 未知 option 被安全忽略。
fn negotiate(options: []const packet.Option, file_size: u64) !Settings {
    var settings: Settings = .{};
    for (options) |option| {
        if (std.ascii.eqlIgnoreCase(option.name, "blksize")) {
            const value = std.fmt.parseInt(u16, option.value, 10) catch return error.InvalidOption;
            if (value < 8 or value > max_block_size) return error.InvalidOption;
            settings.block_size = value;
            settings.use_blksize = true;
        } else if (std.ascii.eqlIgnoreCase(option.name, "timeout")) {
            const value = std.fmt.parseInt(u8, option.value, 10) catch return error.InvalidOption;
            if (value == 0) return error.InvalidOption;
            settings.timeout = value;
            settings.use_timeout = true;
        } else if (std.ascii.eqlIgnoreCase(option.name, "tsize") and std.mem.eql(u8, option.value, "0")) {
            _ = file_size;
            settings.use_tsize = true;
        }
    }
    return settings;
}

/// 等待指定 block number 的 ACK，超时返回 `error.Timeout`。
///
/// 同时验证来源地址和 TID：如果 ACK 来自不同地址，返回 `error.UnexpectedTransferId`。
/// 这防止其他客户端干扰正在进行的传输。
fn awaitAck(socket: *std.Io.net.Socket, io: std.Io, remote: *const std.Io.net.IpAddress, expected: u16, seconds: u8) !void {
    var recv_buffer: [516]u8 = undefined;
    var options: [0]packet.Option = .{};
    const incoming = try socket.receiveTimeout(io, &recv_buffer, .{ .duration = .{
        .raw = .fromSeconds(seconds),
        .clock = .awake,
    } });
    if (!incoming.from.eql(remote)) return error.UnexpectedTransferId;
    const message = try packet.parse(incoming.data, &options);
    if (message != .ack or message.ack != expected) return error.UnexpectedAck;
}

/// 通过 dispatcher socket 向客户端发送 TFTP ERROR 报文。
/// 用于在解析失败或 WRQ 时返回标准错误，不启动独立传输 socket。
fn sendError(socket: *std.Io.net.Socket, io: std.Io, remote: *const std.Io.net.IpAddress, code: packet.ErrorCode, message: []const u8) !void {
    var buffer: [512]u8 = undefined;
    try socket.send(io, remote, try packet.encodeError(&buffer, code, message));
}

/// 拒绝绝对路径、空组件、`.`、`..` 和 Windows 分隔符。
/// 这是最外层的路径安全检查；`isManifestPath` 进一步限制只有 catalog 中的文件可被提供。
/// 符号链接在文件打开时通过 `follow_symlinks = false` 再次拒绝。
pub fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfScalar(u8, part, '\\') != null)
            return false;
    }
    return true;
}

/// 检查路径是否在当前 catalog 的资产清单中。
/// 只有同时通过路径安全检查和 catalog 白名单的文件才可被 TFTP 提供。
/// catalog 的锁在 `containsAssetPath` 内部获取和释放。
fn isManifestPath(catalog: *catalog_runtime.CatalogRuntime, path: []const u8) bool {
    return catalog.containsAssetPath(path);
}

test "rejects unsafe TFTP paths" {
    try std.testing.expect(isSafeRelativePath("efi/grubx64.efi"));
    try std.testing.expect(!isSafeRelativePath("../etc/passwd"));
    try std.testing.expect(!isSafeRelativePath("/etc/passwd"));
    try std.testing.expect(!isSafeRelativePath("efi\\grubx64.efi"));
}
