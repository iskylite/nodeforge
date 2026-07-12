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
const events = @import("../state/events.zig");
const boot_session = @import("../state/boot_session.zig");
const boot_target = @import("../boot/target.zig");
const grub = @import("../boot/grub.zig");
const observe_log = @import("../observe/log.zig");
const log = std.log.scoped(.tftp);

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
pub fn serve(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog: *catalog_runtime.CatalogRuntime, runtime: *runtime_state.RuntimeState, event_writer: ?*events.Writer, sessions: ?*boot_session.Store, stop: ?*const std.atomic.Value(bool)) !void {
    const socket = try bind(io, config.server.server_ip);
    try serveSocket(io, allocator, socket, config, catalog, runtime, event_writer, sessions, stop);
}

/// 绑定固定 UDP 69；供 daemon 在启动其他 listener 前确认 TFTP 可用。
/// 返回的 socket 由调用方负责关闭（通过 `serveSocket` 或手动 `close`）。
pub fn bind(io: std.Io, server_ip: []const u8) !std.Io.net.Socket {
    const address = try std.Io.net.IpAddress.parseIp4(server_ip, port);
    return address.bind(io, .{ .mode = .dgram, .protocol = .udp });
}

/// 在已绑定 socket 上运行 RRQ dispatcher。调用方转移 socket 的关闭责任。
///
/// 主循环：接收 UDP datagram -> 解析 TFTP 报文 -> 如果是 RRQ 则启动文件传输 ->
/// 传输在当前线程串行完成（M1 单 worker 模型）。WRQ 返回 ERROR；其他类型返回 ERROR。
pub fn serveSocket(io: std.Io, allocator: std.mem.Allocator, owned_socket: std.Io.net.Socket, config: *const model.AppConfig, catalog: *catalog_runtime.CatalogRuntime, runtime: *runtime_state.RuntimeState, event_writer: ?*events.Writer, sessions: ?*boot_session.Store, stop: ?*const std.atomic.Value(bool)) !void {
    var socket = owned_socket;
    defer socket.close(io);

    while (true) {
        if (if (stop) |flag| flag.load(.acquire) else false) return;
        var recv_buffer: [2048]u8 = undefined;
        const incoming = socket.receiveTimeout(io, &recv_buffer, .{ .duration = .{ .raw = .fromMilliseconds(200), .clock = .awake } }) catch |err| {
            if (err == error.Timeout) continue;
            return err;
        };
        var options: [max_options]packet.Option = undefined;
        const message = packet.parse(incoming.data, &options) catch {
            try sendError(&socket, io, &incoming.from, .illegal_operation, "invalid TFTP request");
            continue;
        };
        switch (message) {
            .rrq => |request| {
                const session = runtime.tftp.begin(request.filename);
                // TFTP 没有 MAC/XID；只接受活动 session 中唯一的已 ACK lease-IP。
                // 零个或多个命中均保留 session_link_state，绝不能按文件名、TID
                // 或最近 DHCP 日志猜测关联。
                var session_link: ?boot_session.Link = null;
                if (sessions) |store| session_link = store.associateTftp(clientIpv4(&incoming.from) orelse 0, boot_session.monotonicNow(), now());
                if (session_link) |*link| {
                    if (link.id()) |id| log.info("RRQ {s} session={s}", .{ request.filename, id }) else log.warn("RRQ {s} session_link_state={s}", .{ request.filename, link.state().? });
                } else log.info("RRQ {s}", .{request.filename});
                const started = std.Io.Clock.awake.now(io);
                emit(event_writer, io, allocator, &incoming.from, request.filename, "tftp.rrq", "TFTP read requested", 0, 0, if (session_link) |*link| link else null);

                // M3.5/M3.6：在 catalog manifest 白名单检查之前拦截虚拟 GRUB 配置请求。
                // 只有严格匹配的文件名才是虚拟配置候选；仍需要一个有效的已 ACK
                // session 才能渲染和传输配置。虚拟名称是动态策略端点而非磁盘文件，
                // 因此访问拒绝必须返回 TFTP ERROR code 2（access violation）
                // 而非 code 1（file not found）。这区分了“策略拒绝”和“文件不存在”，
                // 使 PXE 客户端和操作员能正确诊断启动失败原因。
                const is_virtual = isVirtualGrubConfig(request.filename);
                const bytes_sent = if (is_virtual)
                    transferVirtualConfig(io, &incoming.from, request, config, catalog, sessions) catch |err| {
                        runtime.tftp.finish(session, false);
                        if (session_link) |link| if (sessions) |store| store.updateTftp(link, .failed, boot_session.monotonicNow(), now());
                        switch (err) {
                            error.BootAccessDenied, error.BootTargetUnavailable, error.UnsupportedMode, error.InvalidOption => observe_log.warn("tftp: rejected virtual config {s} from {f}: {t}", .{ request.filename, incoming.from, err }),
                            else => observe_log.err("tftp: virtual config transfer failed for {s}: {t}", .{ request.filename, err }),
                        }
                        emit(event_writer, io, allocator, &incoming.from, request.filename, "tftp.transfer.error", "TFTP transfer failed", 0, started.durationTo(std.Io.Clock.awake.now(io)).toMicroseconds(), if (session_link) |*link| link else null);
                        // M3.6 错误语义：虚拟 GRUB 配置请求的失败是授权/策略拒绝，
                        // 不是文件缺失。返回 TFTP ERROR code 2（access violation）
                        // 而非 code 1（file not found）。
                        // - BootAccessDenied：无活动 DHCP lease 或 session 已过期
                        // - BootTargetUnavailable：有 session 但 profile/catalog 引用无效
                        // - UnsupportedMode/InvalidOption：TFTP mode 非 octet 或 option 非法
                        const response: struct { code: packet.ErrorCode, message: []const u8 } = switch (err) {
                            error.BootAccessDenied => .{ .code = .access_violation, .message = "boot configuration requires an active DHCP lease" },
                            error.BootTargetUnavailable => .{ .code = .access_violation, .message = "boot configuration unavailable for this node" },
                            error.UnsupportedMode, error.InvalidOption => .{ .code = .illegal_operation, .message = "unsupported request" },
                            else => .{ .code = .undefined, .message = "transfer failed" },
                        };
                        try sendError(&socket, io, &incoming.from, response.code, response.message);
                        continue;
                    }
                else
                    transfer(io, &incoming.from, request, config.tftp.asset_root, catalog) catch |err| {
                        runtime.tftp.finish(session, false);
                        if (session_link) |link| if (sessions) |store| store.updateTftp(link, .failed, boot_session.monotonicNow(), now());
                        switch (err) {
                            error.FileNotAllowed, error.UnsupportedMode, error.InvalidOption => observe_log.warn("tftp: rejected {s} from {f}: {t}", .{ request.filename, incoming.from, err }),
                            else => observe_log.err("tftp: transfer failed for {s}: {t}", .{ request.filename, err }),
                        }
                        emit(event_writer, io, allocator, &incoming.from, request.filename, "tftp.transfer.error", "TFTP transfer failed", 0, started.durationTo(std.Io.Clock.awake.now(io)).toMicroseconds(), if (session_link) |*link| link else null);
                        // 静态文件传输的错误语义遵循 RFC 1350 标准：
                        // - FileNotAllowed/FileNotFound → code 1（file not found）
                        // - UnsupportedMode/InvalidOption → code 4（illegal operation）
                        // - AccessDenied/PermissionDenied/SymLinkLoop → code 2（access violation）
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
                if (session_link) |link| if (sessions) |store| store.updateTftp(link, .tftp_complete, boot_session.monotonicNow(), now());
                if (session_link) |*link| {
                    if (link.id()) |boot_id| observe_log.info("tftp: transfer completed {s} ({d} bytes) session={s}", .{ request.filename, bytes_sent, boot_id }) else observe_log.info("tftp: transfer completed {s} ({d} bytes) session_link_state={s}", .{ request.filename, bytes_sent, link.state().? });
                } else observe_log.info("tftp: transfer completed {s} ({d} bytes)", .{ request.filename, bytes_sent });
                emit(event_writer, io, allocator, &incoming.from, request.filename, "tftp.transfer.complete", "TFTP transfer completed", bytes_sent, started.durationTo(std.Io.Clock.awake.now(io)).toMicroseconds(), if (session_link) |*link| link else null);
            },
            .wrq => try sendError(&socket, io, &incoming.from, .access_violation, "write requests are disabled"),
            else => try sendError(&socket, io, &incoming.from, .illegal_operation, "expected RRQ"),
        }
    }
}

/// M3.5/M3.6：识别严格匹配的虚拟 GRUB 配置请求。
///
/// 只有以下精确模式被识别为虚拟配置候选：
/// - `efi/grub.cfg-01-<客户端 MAC 的小写连字符形式>`
///   例如 `efi/grub.cfg-01-02-aa-bb-cc-dd-ef`
///   MAC 各字节必须是小写 hex，用连字符分隔（GRUB 的标准 MAC 格式）。
/// - `efi/grub.cfg-<客户端 IPv4 的大写十六进制形式>`
///   例如 `efi/grub.cfg-C0A81BC8`（对应 192.168.27.200）
///   IP 各字节必须是大写 hex，无分隔符（GRUB 的标准 IP hex 格式）。
/// - `efi/grub.cfg`（GRUB 回退名称）
///
/// 其他路径继续走正常的 catalog asset 白名单检查。
/// 文件名本身不决定响应内容；调用方还必须拥有该 peer IP 的有效已 ACK session
/// 才能渲染和传输配置。允许 GRUB 常见的单个前导 `/`（如 `/efi/grub.cfg-...`）。
fn isVirtualGrubConfig(filename: []const u8) bool {
    const normalized = trimLeadingSlash(filename);
    // MAC form: efi/grub.cfg-01-<6 hex pairs separated by hyphens>
    // Total length: "efi/grub.cfg-01-" (16) + "XX-XX-XX-XX-XX-XX" (17) = 33
    if (std.mem.startsWith(u8, normalized, "efi/grub.cfg-01-")) {
        const suffix = normalized["efi/grub.cfg-01-".len..];
        if (suffix.len != 17) return false;
        for (suffix, 0..) |c, i| {
            if (i % 3 == 2) {
                if (c != '-') return false;
            } else if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
        }
        return true;
    }
    if (std.mem.startsWith(u8, normalized, "efi/grub.cfg-")) {
        // Hex IP form: grub.cfg-<8 hex chars> (e.g. C0A81BC8)
        const suffix = normalized["efi/grub.cfg-".len..];
        if (suffix.len == 8) {
            for (suffix) |c| if (!(std.ascii.isDigit(c) or (c >= 'A' and c <= 'F'))) return false;
            return true;
        }
        return false;
    }
    if (std.mem.eql(u8, normalized, "efi/grub.cfg")) return true;
    return false;
}

/// 去除 GRUB/PXE 客户端可能发送的单个前导 `/`。
/// PXE 客户端（GRUB、PXELINUX）经常发送以 `/` 开头的路径；
/// 去除后使路径相对于 TFTP asset root 进行后续匹配和文件打开。
fn trimLeadingSlash(filename: []const u8) []const u8 {
    return if (filename.len > 0 and filename[0] == '/') filename[1..] else filename;
}

/// M3.5/M3.6：从内存渲染并传输虚拟 GRUB 配置。
///
/// 配置根据已 ACK session 的身份和当前 catalog/config 快照动态生成。
/// 它永远不会持久化到磁盘、不会加入 catalog、不包含 token 或 boot_session_id。
/// 这确保了即使 TFTP root 被入侵，也无法从磁盘文件获取其他节点的启动配置。
///
/// 责任链：
/// 1. 验证 TFTP mode 为 octet
/// 2. 从 peer IP 解析唯一的已 ACK boot session 身份
/// 3. 在 catalog 锁内：调用 boot_target.resolve 展开 kernel/initrd/cmdline
/// 4. 在 catalog 锁内：为路径补充前导 `/` 并调用 grub.render 生成配置文本
/// 5. 释放 catalog 锁后，通过 transferFromMemory 传输渲染好的配置
///
/// 返回已发送的字节数；如果 session 无法解析、profile/catalog 引用无效
/// 或传输失败，返回对应错误。
fn transferVirtualConfig(
    io: std.Io,
    remote: *const std.Io.net.IpAddress,
    request: packet.Request,
    config: *const model.AppConfig,
    catalog: *catalog_runtime.CatalogRuntime,
    sessions: ?*boot_session.Store,
) !u64 {
    if (!std.ascii.eqlIgnoreCase(request.mode, "octet")) return error.UnsupportedMode;

    const client_ip = clientIpv4(remote) orelse return error.BootAccessDenied;
    const store = sessions orelse return error.BootAccessDenied;
    const identity = store.resolveTftpBoot(client_ip, boot_session.monotonicNow()) orelse return error.BootAccessDenied;

    var cmdline_buf: [512]u8 = undefined;
    catalog.lock();
    var config_buf: [2048]u8 = undefined;
    var kernel_grub: [256]u8 = undefined;
    var initrd_grub: [256]u8 = undefined;
    const rendered = blk: {
        defer catalog.unlock();
        // 在 catalog 锁内解析 boot target 并渲染 GRUB 配置。
        // 渲染结果写入栈缓冲区，在 TFTP I/O 开始前就已完成自包含，
        // 因此慢速客户端不会长时间持有 catalog mutex。
        const target = boot_target.resolve(identity, config, &catalog.value, config.server.server_ip, config.server.http_port, &cmdline_buf) orelse return error.BootTargetUnavailable;
        // 为路径补充前导 `/` 以符合 GRUB 语法（GRUB 路径以 `/` 开头）。
        // 此操作在 catalog 锁内完成，确保路径切片引用的 catalog 数据有效。
        const kernel_path = std.fmt.bufPrint(&kernel_grub, "/{s}", .{target.kernel_path}) catch return error.BootTargetUnavailable;
        const initrd_path = std.fmt.bufPrint(&initrd_grub, "/{s}", .{target.initrd_path}) catch return error.BootTargetUnavailable;
        break :blk grub.render(&config_buf, .{
            .node_id = identity.node_id,
            .kernel_path = kernel_path,
            .initrd_path = initrd_path,
            .cmdline = target.cmdline,
            .arch = target.arch,
        }) catch return error.BootTargetUnavailable;
    };

    return transferFromMemory(io, remote, request, rendered);
}

/// 使用与文件传输相同的 TFTP OACK/DATA/ACK 逻辑传输内存缓冲区。
///
/// 与文件传输的唯一区别是数据源是内存切片而非磁盘文件。
/// 这确保了虚拟 GRUB 配置和静态文件在 TFTP 协议层面行为一致，
/// 包括 option 协商、分块传输、超时重传等。
fn transferFromMemory(
    io: std.Io,
    remote: *const std.Io.net.IpAddress,
    request: packet.Request,
    content: []const u8,
) !u64 {
    const file_size: u64 = content.len;
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
    while (true) {
        const end = @min(offset + settings.block_size, content.len);
        const chunk = content[offset..end];
        var out: [max_block_size + 4]u8 = undefined;
        const datagram = try packet.encodeData(&out, block, chunk);
        // 超时重传：最多重试 max_retries 次，每次重传后等待 ACK。
        // 这处理 UDP 丢包和客户端处理延迟，但不无限重试以避免资源浪费。
        var attempts: usize = 0;
        while (true) {
            try socket.send(io, remote, datagram);
            awaitAck(&socket, io, remote, block, settings.timeout) catch |err| {
                if (err == error.Timeout and attempts < max_retries) {
                    attempts += 1;
                    log.warn("retransmit virtual config block {d} attempt {d}/{d}", .{ block, attempts, max_retries });
                    continue;
                }
                return err;
            };
            break;
        }
        offset += chunk.len;
        // 最后一个 DATA 的负载小于 block_size 时传输完成（RFC 1350 标准）。
        if (chunk.len < settings.block_size) return offset;
        block +%= 1;
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
) !u64 {
    if (!std.ascii.eqlIgnoreCase(request.mode, "octet")) return error.UnsupportedMode;
    // PXE clients (GRUB, PXELINUX) often send paths with a leading '/';
    // strip it so the path is relative to the TFTP asset root.
    const filename = trimLeadingSlash(request.filename);
    if (!isSafeRelativePath(filename) or !isManifestPath(catalog, filename))
        return error.FileNotAllowed;

    var root = try std.Io.Dir.openDirAbsolute(io, asset_root, .{ .access_sub_paths = true });
    defer root.close(io);
    var file = try root.openFile(io, filename, .{
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
    // M3.6 下载可观测性：debug 进度在 ACK 之后输出，因此每个数字反映的是
    // 对端已确认接收的字节数，而非仅仅已排入 UDP 发送队列的字节数。
    // 按 10% 增量输出进度日志（debug 级别），避免在 info 级别产生过多日志。
    var next_progress: u64 = if (file_size < 10) file_size else @max(@as(u64, 1), file_size / 10);
    var data: [max_block_size]u8 = undefined;
    while (true) {
        const capacity = data[0..settings.block_size];
        const read = try file.readPositionalAll(io, capacity, offset);
        var out: [max_block_size + 4]u8 = undefined;
        const datagram = try packet.encodeData(&out, block, capacity[0..read]);
        // 超时重传逻辑与虚拟配置传输相同。
        var attempts: usize = 0;
        while (true) {
            try socket.send(io, remote, datagram);
            awaitAck(&socket, io, remote, block, settings.timeout) catch |err| {
                if (err == error.Timeout and attempts < max_retries) {
                    attempts += 1;
                    log.warn("retransmit {s} block {d} attempt {d}/{d}", .{ request.filename, block, attempts, max_retries });
                    continue;
                }
                return err;
            };
            break;
        }
        offset += read;
        // 按 10% 增量输出 debug 级别的下载进度日志。
        while (file_size != 0 and offset >= next_progress) : (next_progress += @max(@as(u64, 1), file_size / 10)) {
            const reported = @min(offset, file_size);
            log.debug("download progress {s}: {d}/{d} bytes ({d}%)", .{ request.filename, reported, file_size, (reported * 100) / file_size });
            if (reported == file_size) break;
        }
        // 最后一个 DATA 的负载小于 block_size 时传输完成（RFC 1350 标准）。
        if (read < settings.block_size) return offset;
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

/// 追加 TFTP 审计事件并保留本次 RRQ 的关联结果。
///
/// 关联结果在传输开始时确定，同一 RRQ 的 success/error 事件复用它；传输期间
/// 不重新查询 Store，避免 session 过期或新 lease 把一条传输拆到不同 session。
fn emit(writer: ?*events.Writer, io: std.Io, allocator: std.mem.Allocator, remote: *const std.Io.net.IpAddress, filename: []const u8, event_type: []const u8, message: []const u8, bytes_sent: u64, duration_us: i64, session_link: ?*const boot_session.Link) void {
    const target = writer orelse return;
    var bytes_text: [20]u8 = undefined;
    var duration_text: [20]u8 = undefined;
    var client_ip: [64]u8 = undefined;
    var fields: [6]events.Field = .{
        .{ .key = "filename", .value = filename },
        .{ .key = "bytes_sent", .value = std.fmt.bufPrint(&bytes_text, "{d}", .{bytes_sent}) catch "0" },
        .{ .key = "client_ip", .value = std.fmt.bufPrint(&client_ip, "{f}", .{remote}) catch "unknown" },
        .{ .key = "duration_us", .value = std.fmt.bufPrint(&duration_text, "{d}", .{duration_us}) catch "0" },
        .{ .key = "", .value = "" },
        .{ .key = "", .value = "" },
    };
    var count: usize = 4;
    if (session_link) |link| {
        if (link.id()) |id| {
            fields[count] = .{ .key = "boot_session_id", .value = id };
            count += 1;
        } else if (link.state()) |state| {
            fields[count] = .{ .key = "session_link_state", .value = state };
            count += 1;
        }
    }
    target.appendWithFields(io, allocator, @import("../paths.zig").events_path, event_type, message, fields[0..count]) catch |err|
        observe_log.err("tftp: event append failed: {t}", .{err});
}

/// 返回与 DHCP lease 相同字节序的 IPv4 值；IPv6 不参与当前 DHCPv4 关联。
fn clientIpv4(remote: *const std.Io.net.IpAddress) ?u32 {
    return switch (remote.*) {
        .ip4 => |address| (@as(u32, address.bytes[0]) << 24) | (@as(u32, address.bytes[1]) << 16) | (@as(u32, address.bytes[2]) << 8) | address.bytes[3],
        .ip6 => null,
    };
}

fn now() i64 {
    var timestamp: std.posix.timespec = undefined;
    return if (std.posix.errno(std.posix.system.clock_gettime(.REALTIME, &timestamp)) == .SUCCESS) @intCast(timestamp.sec) else 0;
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

test "identifies virtual GRUB config filenames" {
    // MAC form
    try std.testing.expect(isVirtualGrubConfig("efi/grub.cfg-01-02-aa-bb-cc-dd-ef"));
    // Hex IP form (uppercase)
    try std.testing.expect(isVirtualGrubConfig("efi/grub.cfg-C0A81BC8"));
    // Fallback
    try std.testing.expect(isVirtualGrubConfig("efi/grub.cfg"));
    try std.testing.expect(isVirtualGrubConfig("/efi/grub.cfg-C0A81BC8"));
    // Non-matching
    try std.testing.expect(!isVirtualGrubConfig("efi/grub.cfg-01-02-aa-bb-cc-dd-ef-extra"));
    try std.testing.expect(!isVirtualGrubConfig("efi/grub.cfg-XYZ"));
    try std.testing.expect(!isVirtualGrubConfig("efi/grub.cfg-c0a81bc8"));
    try std.testing.expect(!isVirtualGrubConfig("efi/grub.cfg-01-02-AA-bb-cc-dd-ef"));
    try std.testing.expect(!isVirtualGrubConfig("efi/grub.cfg-01-02-aa-bb-cc-dd-gg"));
    try std.testing.expect(!isVirtualGrubConfig("efi/grubaa64.efi"));
    try std.testing.expect(!isVirtualGrubConfig("grub.cfg"));
    try std.testing.expect(!isVirtualGrubConfig("../etc/grub.cfg"));
}
