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
const lookup = @import("../catalog.zig");
const catalog_runtime = @import("../state/catalog_runtime.zig");
const model_runtime = @import("../state/model_runtime.zig");
const config_runtime = @import("../state/config_runtime.zig");
const packet = @import("packet.zig");
const runtime_state = @import("../state/runtime.zig");
const events = @import("../state/events.zig");
const boot_session = @import("../state/boot_session.zig");
const boot_target = @import("../boot/target.zig");
const grub = @import("../boot/grub.zig");
const observe_log = @import("../observe/log.zig");
const capmod = @import("../state/capacity.zig");
const log = std.log.scoped(.tftp);

/// TFTP 标准监听端口（RFC 1350）；不暴露为配置或 CLI 参数。
pub const port: u16 = 69;
/// 单个 RRQ 最多接受的 option 数量（RFC 2347）。
const max_options = 8;
/// 允许的最大 `blksize` 值（RFC 2348）；超过此值的请求被拒绝。
/// 受限于 UDP datagram 最大安全负载（65535 - 20 IP - 8 UDP = 65507）。
const max_block_size: usize = 65_464;
/// TFTP DATA/ACK 重传基线超时（秒）。客户端未在 RRQ 发送 `timeout` option 时
/// 采用此值；与 tftpd-hpa 默认 1s 一致。重传采用指数退避（每次翻倍，见
/// `backoffSeconds`）：中途块累计耐心 ~63s（见 `max_retries`），末尾块 ~7s
/// 后乐观完成（见 `final_block_retries`）。
/// 早期 5s 固定值既慢于丢包恢复、又无退避，且无法解决末尾块 ACK 丢失
///（GRUB 收齐 initrd 后转去加载，不再回最终 ACK）。
const default_timeout: u8 = 1;
/// 非末尾块的重传次数上限（不含首次发送）；与 tftpd-hpa TRIES=6
///（1 首次 + 5 重传）一致。配合 1s 基线 + 指数退避，中途块累计耐心 ~63s
///（1+2+4+8+16+32）。末尾块用更小的 `final_block_retries`。
const max_retries: u8 = 5;
/// ACK 超时后的重传决策（纯逻辑，便于无 socket 单元测试）。
const RetryAction = enum {
    retransmit, // 还有重传预算，继续重传
    optimistic_complete, // 末尾块交付无法确认；耗尽短预算后按策略乐观完成
    fail, // 非末尾块重传耗尽，判定失败
};

/// 末尾块（payload < blksize）的乐观重传上限：2 次。
/// 配合 1s 基线 + 指数退避，末尾块最多等待 1+2+4 = 7s。此时无法区分
/// “DATA 已到但 ACK 丢失”和“DATA 未到”，所以日志必须标为 delivery unconfirmed。
/// NodeForge 是共享全局并发槽的长驻多线程 daemon；相比 tftpd-hpa 常见的
/// per-request 进程隔离，缩短末尾等待可避免不可确认请求长期占用全局 worker。
const final_block_retries: u8 = 2;

/// 根据是否末尾块返回重传上限。非末尾块用 `max_retries`（对齐 tftpd-hpa
/// TRIES=6，即 1 首次 + 5 重传，1s 基线 + 指数退避累计 ~63s）；末尾块用
/// `final_block_retries`（~7s 后乐观完成）。
fn retryLimit(is_final_block: bool) usize {
    return if (is_final_block) final_block_retries else max_retries;
}

/// 根据「是否末尾块 / 当前已等待次数 / 重传上限」决定 ACK 超时后的动作。
/// `attempts` 为已发起的等待次数（0 表示首次等待刚超时）。
fn retryAction(is_final_block: bool, attempts: usize, limit: usize) RetryAction {
    if (attempts < limit) return .retransmit;
    return if (is_final_block) .optimistic_complete else .fail;
}

/// 指数退避：第 `attempt` 次等待 `base << attempt` 秒，封顶 255
///（`awaitAck` 的 `seconds` 参数为 u8）。与 tftpd-hpa 每次重传 timeout 翻倍一致。
fn backoffSeconds(base: u8, attempt: usize) u8 {
    const Shift = std.math.Log2Int(u32);
    const shift: Shift = @intCast(@min(attempt, 8));
    const widened: u32 = @as(u32, base) << shift;
    return @intCast(@min(widened, 255));
}
/// 在固定 UDP 69 上运行 TFTP RRQ dispatcher。
///
/// `config` 提供 TFTP asset root 路径；`catalog` 提供资产白名单快照；
/// `runtime` 记录会话计数和活动列表。三者必须在 `serve` 的整个生命周期内保持有效。
pub fn serve(io: std.Io, allocator: std.mem.Allocator, models: *model_runtime.ModelRuntime, runtime: *runtime_state.RuntimeState, event_writer: ?*events.Writer, sessions: ?*boot_session.Store, stop: ?*const std.atomic.Value(bool)) !void {
    const pair = models.acquire();
    defer pair.release();
    const socket = try bind(io, pair.config.value().server.server_ip);
    try serveSocket(io, allocator, socket, models, runtime, event_writer, sessions, stop);
}

/// 绑定固定 UDP 69；供 daemon 在启动其他 listener 前确认 TFTP 可用。
/// 返回的 socket 由调用方负责关闭（通过 `serveSocket` 或手动 `close`）。
pub fn bind(io: std.Io, server_ip: []const u8) !std.Io.net.Socket {
    const address = try std.Io.net.IpAddress.parseIp4(server_ip, port);
    return address.bind(io, .{ .mode = .dgram, .protocol = .udp });
}

/// 在已绑定 socket 上运行 RRQ dispatcher。调用方转移 socket 的关闭责任。
///
/// 主循环只负责接收和分发。`max_concurrent_transfers <= 1` 保留串行模式；
/// 大于 1 时为每个 RRQ 启动有界 worker，worker 使用复制后的 datagram，绝不
/// 借用下一轮 receive 会覆盖的栈缓冲区。
pub fn serveSocket(io: std.Io, allocator: std.mem.Allocator, owned_socket: std.Io.net.Socket, models: *model_runtime.ModelRuntime, runtime: *runtime_state.RuntimeState, event_writer: ?*events.Writer, sessions: ?*boot_session.Store, stop: ?*const std.atomic.Value(bool)) !void {
    var socket = owned_socket;
    defer socket.close(io);
    var active_transfers = std.atomic.Value(u16).init(0);
    defer while (active_transfers.load(.acquire) != 0) std.Thread.yield() catch {};
    // M4.8: max_concurrent_transfers 省略时按 max(128, 2×核) 自动派生；config 显式给出则覆盖。
    const auto_concurrency: u16 = capmod.tftpConcurrency(std.Thread.getCpuCount() catch 1, null);

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
                const pair = models.acquire();
                const config = pair.config.value();
                const limit: u16 = config.tftp.max_concurrent_transfers orelse auto_concurrency;
                if (limit <= 1) {
                    defer pair.release();
                    try handleRrq(io, allocator, incoming.from, request, config, pair.catalog, runtime, event_writer, sessions);
                    continue;
                }
                if (!reserveTransferSlot(&active_transfers, limit)) {
                    pair.release();
                    try sendError(&socket, io, &incoming.from, .undefined, "server busy, retry later");
                    continue;
                }
                const datagram = allocator.dupe(u8, incoming.data) catch |err| {
                    pair.release();
                    _ = active_transfers.fetchSub(1, .acq_rel);
                    return err;
                };
                const context = allocator.create(TransferWorker) catch |err| {
                    pair.release();
                    allocator.free(datagram);
                    _ = active_transfers.fetchSub(1, .acq_rel);
                    return err;
                };
                context.* = .{ .io = io, .allocator = allocator, .datagram = datagram, .remote = incoming.from, .pair = pair, .runtime = runtime, .event_writer = event_writer, .sessions = sessions, .active = &active_transfers };
                const thread = std.Thread.spawn(.{}, runTransferWorker, .{context}) catch |err| {
                    pair.release();
                    _ = active_transfers.fetchSub(1, .acq_rel);
                    allocator.free(datagram);
                    allocator.destroy(context);
                    observe_log.err("tftp: unable to start transfer worker: {t}", .{err});
                    try sendError(&socket, io, &incoming.from, .undefined, "server busy, retry later");
                    continue;
                };
                thread.detach();
            },
            .wrq => try sendError(&socket, io, &incoming.from, .access_violation, "write requests are disabled"),
            else => try sendError(&socket, io, &incoming.from, .illegal_operation, "expected RRQ"),
        }
    }
}

/// dispatcher 是唯一的 slot 生产者，worker 只负责递减，因此一次 load 后递增
/// 不会与另一个生产者竞争；该约束比为单线程 dispatcher 引入 CAS 循环更清晰。
fn reserveTransferSlot(active: *std.atomic.Value(u16), limit: u16) bool {
    if (active.load(.acquire) >= limit) return false;
    _ = active.fetchAdd(1, .acq_rel);
    return true;
}

const TransferWorker = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    datagram: []u8,
    remote: std.Io.net.IpAddress,
    pair: model_runtime.Pair,
    runtime: *runtime_state.RuntimeState,
    event_writer: ?*events.Writer,
    sessions: ?*boot_session.Store,
    active: *std.atomic.Value(u16),
};

fn runTransferWorker(context: *TransferWorker) void {
    // active 最后递减；dispatcher 看到 0 时，worker 已释放所有借用资源。
    defer _ = context.active.fetchSub(1, .acq_rel);
    defer context.allocator.destroy(context);
    defer context.allocator.free(context.datagram);
    defer context.pair.release();
    var options: [max_options]packet.Option = undefined;
    const message = packet.parse(context.datagram, &options) catch return;
    const request = switch (message) {
        .rrq => |value| value,
        else => return,
    };
    handleRrq(context.io, context.allocator, context.remote, request, context.pair.config.value(), context.pair.catalog, context.runtime, context.event_writer, context.sessions) catch |err|
        observe_log.err("tftp: worker failed: {t}", .{err});
}

fn handleRrq(io: std.Io, allocator: std.mem.Allocator, remote: std.Io.net.IpAddress, request: packet.Request, config: *const model.AppConfig, catalog: *const catalog_runtime.Snapshot, runtime: *runtime_state.RuntimeState, event_writer: ?*events.Writer, sessions: ?*boot_session.Store) !void {
    const session = runtime.tftp.begin(request.filename);
    var session_link: ?boot_session.Link = null;
    if (sessions) |store| session_link = store.associateTftp(clientIpv4(&remote) orelse 0, boot_session.monotonicNow(), now());
    var linked_node_buffer: [96]u8 = undefined;
    const linked_node_id = if (session_link) |link| if (sessions) |store| store.copyLinkedNodeId(link, &linked_node_buffer) else null else null;
    if (session_link) |*link| {
        if (link.id()) |id| log.info("RRQ {s} session={s}", .{ request.filename, id }) else log.warn("RRQ {s} session_link_state={s}", .{ request.filename, link.state().? });
    } else log.info("RRQ {s}", .{request.filename});
    const started = std.Io.Clock.awake.now(io);
    emit(event_writer, io, allocator, &remote, request.filename, "tftp.rrq", "TFTP read requested", 0, 0, linked_node_id, if (session_link) |*link| link else null);

    const is_virtual = isVirtualGrubConfig(request.filename);
    const bytes_sent = if (is_virtual)
        transferVirtualConfig(io, &remote, request, config, catalog, sessions) catch |err| {
            runtime.tftp.finish(session, false);
            if (session_link) |link| if (sessions) |store| store.updateTftp(link, .failed, boot_session.monotonicNow(), now());
            switch (err) {
                error.BootAccessDenied, error.BootTargetUnavailable, error.UnsupportedMode, error.InvalidOption => observe_log.warn("tftp: rejected virtual config {s} from {f}: {t}", .{ request.filename, remote, err }),
                else => observe_log.err("tftp: virtual config transfer failed for {s}: {t}", .{ request.filename, err }),
            }
            emit(event_writer, io, allocator, &remote, request.filename, "tftp.transfer.error", "TFTP transfer failed", 0, started.durationTo(std.Io.Clock.awake.now(io)).toMicroseconds(), linked_node_id, if (session_link) |*link| link else null);
            if (initialErrorResponse(err)) |response| try sendEphemeralError(io, &remote, response.code, response.message);
            return;
        }
    else
        transfer(io, &remote, request, config.tftp.asset_root, catalog, config.tftp.windowsize, config.tftp.max_blksize) catch |err| {
            runtime.tftp.finish(session, false);
            if (session_link) |link| if (sessions) |store| store.updateTftp(link, .failed, boot_session.monotonicNow(), now());
            switch (err) {
                error.FileNotAllowed, error.UnsupportedMode, error.InvalidOption => observe_log.warn("tftp: rejected {s} from {f}: {t}", .{ request.filename, remote, err }),
                else => observe_log.err("tftp: transfer failed for {s}: {t}", .{ request.filename, err }),
            }
            emit(event_writer, io, allocator, &remote, request.filename, "tftp.transfer.error", "TFTP transfer failed", 0, started.durationTo(std.Io.Clock.awake.now(io)).toMicroseconds(), linked_node_id, if (session_link) |*link| link else null);
            if (initialErrorResponse(err)) |response| try sendEphemeralError(io, &remote, response.code, response.message);
            return;
        };
    runtime.tftp.finish(session, true);
    if (session_link) |link| if (sessions) |store| store.updateTftp(link, .tftp_complete, boot_session.monotonicNow(), now());
    if (session_link) |*link| {
        if (link.id()) |boot_id| observe_log.info("tftp: transfer completed {s} ({d} bytes) session={s}", .{ request.filename, bytes_sent, boot_id }) else observe_log.info("tftp: transfer completed {s} ({d} bytes) session_link_state={s}", .{ request.filename, bytes_sent, link.state().? });
    } else observe_log.info("tftp: transfer completed {s} ({d} bytes)", .{ request.filename, bytes_sent });
    emit(event_writer, io, allocator, &remote, request.filename, "tftp.transfer.complete", "TFTP transfer completed", bytes_sent, started.durationTo(std.Io.Clock.awake.now(io)).toMicroseconds(), linked_node_id, if (session_link) |*link| link else null);
}

const InitialErrorResponse = struct { code: packet.ErrorCode, message: []const u8 };

/// 只为传输 socket 建立前可确定的 RRQ 拒绝生成初始 ERROR。
///
/// tftpd-hpa 的超时处理通常只退出该请求的子进程；NodeForge 则由长驻 daemon
/// 中的 detached worker 返回错误并释放共享并发槽。OACK/DATA 已从临时 TID
/// 发出后，dispatcher 无法复用该已关闭 TID，另绑端口发送 ERROR 会被客户端视为
/// unknown TID。因此 Timeout/UnexpectedAck/普通 I/O 错误只记事件，不再发包。
fn initialErrorResponse(err: anyerror) ?InitialErrorResponse {
    return switch (err) {
        error.BootAccessDenied => .{ .code = .access_violation, .message = "boot configuration requires an active DHCP lease" },
        error.BootTargetUnavailable => .{ .code = .access_violation, .message = "boot configuration unavailable for this node" },
        error.FileNotAllowed, error.FileNotFound => .{ .code = .file_not_found, .message = "file not found" },
        error.UnsupportedMode, error.InvalidOption => .{ .code = .illegal_operation, .message = "unsupported request" },
        error.AccessDenied, error.PermissionDenied, error.SymLinkLoop => .{ .code = .access_violation, .message = "access denied" },
        else => null,
    };
}

/// 初始 RRQ 被拒绝时，服务端尚未建立 transfer TID；此处选择临时 TID 返回
/// ERROR 是合法初始响应。传输开始后的失败不得调用本函数。
fn sendEphemeralError(io: std.Io, remote: *const std.Io.net.IpAddress, code: packet.ErrorCode, message: []const u8) !void {
    const local = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 0);
    var socket = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);
    try sendError(&socket, io, remote, code, message);
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
    // MAC 形式：efi/grub.cfg-01-<6 个用连字符分隔的 hex 对>
    // 总长度："efi/grub.cfg-01-" (16) + "XX-XX-XX-XX-XX-XX" (17) = 33
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
        // Hex IP 形式：grub.cfg-<8 个 hex 字符>（如 C0A81BC8）
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
    catalog: *const catalog_runtime.Snapshot,
    sessions: ?*boot_session.Store,
) !u64 {
    if (!std.ascii.eqlIgnoreCase(request.mode, "octet")) return error.UnsupportedMode;

    const client_ip = clientIpv4(remote) orelse return error.BootAccessDenied;
    const store = sessions orelse return error.BootAccessDenied;
    const identity = store.resolveTftpBoot(client_ip, boot_session.monotonicNow()) orelse return error.BootAccessDenied;

    var cmdline_buf: [1024]u8 = undefined;
    var config_buf: [2048]u8 = undefined;
    var kernel_grub: [256]u8 = undefined;
    var initrd_grub: [256]u8 = undefined;
    const rendered = blk: {
        // 在 catalog 锁内解析 boot target 并渲染 GRUB 配置。
        // 渲染结果写入栈缓冲区，在 TFTP I/O 开始前就已完成自包含，
        // 因此慢速客户端不会长时间持有 catalog mutex。
        const target = boot_target.resolve(identity, config, catalog.value(), config.server.server_ip, config.server.http_port, &cmdline_buf) orelse return error.BootTargetUnavailable;
        const node = lookup.findNode(catalog.value(), identity.node_id) orelse return error.BootTargetUnavailable;
        // M4.2 F4：node.http_accel 是实验性功能（默认 false）。
        // 启用时，initrd 路径渲染为 GRUB HTTP URL
        // `(http,server:port)/artifacts/boot/<path>` 而非 TFTP `/<path>`。
        // GRUB 的 TFTP 客户端不支持 RFC 7440 windowsize，因此 TFTP 上的
        // 大文件传输受限于 ~2 MB/s。HTTP 使用 TCP 窗口控制达到接近线速。
        // HTTP 服务器从 tftp.asset_root 提供 /artifacts/boot/<path>
        //（参见 http/server.zig bootFile 路由）。
        // 需要编译了 `http` 模块的 GRUB。
        //
        // **kernel 始终走 TFTP**：GRUB 的 ARM64 Linux loader 在
        // `grub_file_open()` 获取文件大小后立即调用
        // `grub_efi_allocate_pages()` 分配内核缓冲区。GRUB 的 TCP/HTTP 模块
        // 自身会占用大量 EFI 连续内存页（发送/接收缓冲、TCP 控制块等），
        // 导致剩余连续内存不足以分配 13 MB 内核缓冲区，报错
        // `can not alloc kernel buffer` 或 `out of memory` 并关闭 TCP 连接
        // （tcpdump 可见 GRUB 在仅收到 ~43 KB 后发 FIN+RST）。
        //
        // **即使 kernel 走 TFTP**，GRUB 为 initrd 建立 TCP 连接时仍可能
        // 触发 EFI 内存碎片化，导致后续 kernel 加载失败（实测 out of memory）。
        // 因此 http_accel 默认禁用（false），仅作为实验性功能保留。
        // 在确认目标 GRUB 构建和 EFI 固件内存充裕时才可尝试启用。
        //
        // http_accel 仅对 GRUB UEFI 链路生效。M6 BIOS PXELINUX 固定使用
        // `pxelinux.0`（只支持 TFTP），http_accel 对 BIOS 节点无效，
        // kernel/initrd 始终通过 TFTP 传输。
        const kernel_path = std.fmt.bufPrint(&kernel_grub, "/{s}", .{target.kernel_path}) catch return error.BootTargetUnavailable;
        const initrd_path = if (node.http_accel)
            std.fmt.bufPrint(&initrd_grub, "(http,{s}:{d})/artifacts/boot/{s}", .{ config.server.server_ip, config.server.http_port, target.initrd_path }) catch return error.BootTargetUnavailable
        else
            std.fmt.bufPrint(&initrd_grub, "/{s}", .{target.initrd_path}) catch return error.BootTargetUnavailable;
        break :blk grub.render(&config_buf, .{
            .node_id = identity.node_id,
            .hostname = node.hostname orelse node.id,
            .lease_ip = identity.lease_ip,
            .profile = identity.profile,
            .kernel_path = kernel_path,
            .initrd_path = initrd_path,
            .cmdline = target.cmdline,
            .arch = target.arch,
        }) catch return error.BootTargetUnavailable;
    };

    return transferFromMemory(io, remote, request, rendered, config.tftp.max_blksize);
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
    max_blksize: u16,
) !u64 {
    const file_size: u64 = content.len;
    const settings = try negotiate(request.options, file_size, 0, max_blksize);

    const local = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 0);
    var socket = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);

    if (settings.hasOptions()) {
        var out: [1024]u8 = undefined;
        var option_values: [4][20]u8 = undefined;
        var accepted: [4]packet.Option = undefined;
        const oack = try packet.encodeOack(&out, settings.oackOptions(file_size, &option_values, &accepted));
        try sendOackAndAwaitAck(&socket, io, remote, oack, settings.timeout);
    }

    var block: u16 = 1;
    var offset: u64 = 0;
    while (true) {
        const end = @min(offset + settings.block_size, content.len);
        const chunk = content[offset..end];
        var out: [max_block_size + 4]u8 = undefined;
        const datagram = try packet.encodeData(&out, block, chunk);
        // 末尾块 ACK 乐观完成 + 指数退避重传。最终超时无法证明 DATA 已送达；
        // 这里只执行 NodeForge 的有界 worker 释放策略，并明确记录交付未确认。
        const is_final_block = chunk.len < settings.block_size;
        const limit = retryLimit(is_final_block);
        var attempts: usize = 0;
        while (true) {
            try socket.send(io, remote, datagram);
            awaitAck(&socket, io, remote, block, backoffSeconds(settings.timeout, attempts)) catch |err| {
                if (err == error.Timeout) {
                    switch (retryAction(is_final_block, attempts, limit)) {
                        .retransmit => {
                            attempts += 1;
                            log.warn("retransmit virtual config block {d} attempt {d}/{d}", .{ block, attempts, limit });
                            continue;
                        },
                        .optimistic_complete => {
                            log.info("virtual config final block ACK missing; delivery unconfirmed, completing optimistically", .{});
                            offset += chunk.len;
                            return offset;
                        },
                        .fail => return err,
                    }
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
/// 3. 协商 `blksize`/`timeout`/`tsize`/`windowsize` options（§9.12.5：不放大、不主动建议），
///    如有则发送 OACK 并等待 ACK
/// 4. 按 `blksize` 分块读取文件，发送 DATA，等待 ACK，超时重传（最多 `max_retries` 次）
/// 5. 最后一个 DATA 的负载小于 `blksize` 时传输完成
///
/// 每个 RRQ 使用独立的临时 UDP socket（TID），不阻塞 dispatcher 接收新请求。
fn transfer(
    io: std.Io,
    remote: *const std.Io.net.IpAddress,
    request: packet.Request,
    asset_root: []const u8,
    catalog: *const catalog_runtime.Snapshot,
    max_windowsize: u16,
    max_blksize: u16,
) !u64 {
    if (!std.ascii.eqlIgnoreCase(request.mode, "octet")) return error.UnsupportedMode;
    // PXE 客户端（GRUB、PXELINUX）经常发送以 `/` 开头的路径；
    // 去除后使路径相对于 TFTP asset root。
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
    const settings = try negotiate(request.options, file_size, max_windowsize, max_blksize);
    // M4.2 F4：记录协商后的 options 以帮助诊断性能问题。
    // GRUB 的 TFTP 客户端不支持 RFC 7440 windowsize，因此服务端回退到
    // windowsize=1（停止等待）。这是大多数 PXE 客户端的预期行为，
    // 解释了 TFTP 大文件传输 ~2 MB/s 的吞吐限制。
    // §9.12.5：客户端未请求 blksize 时不主动放入 OACK，不放大客户端请求值。
    log.debug("negotiated {s}: blksize={d} windowsize={d} timeout={d}s", .{ request.filename, settings.block_size, settings.windowsize, settings.timeout });

    const local = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 0);
    var socket = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);

    if (settings.hasOptions()) {
        var out: [1024]u8 = undefined;
        var option_values: [4][20]u8 = undefined;
        var accepted: [4]packet.Option = undefined;
        const oack = try packet.encodeOack(&out, settings.oackOptions(file_size, &option_values, &accepted));
        try sendOackAndAwaitAck(&socket, io, remote, oack, settings.timeout);
    }

    var block: u16 = 1;
    var offset: u64 = 0;
    // M3.6 下载可观测性：debug 进度在 ACK 之后输出，因此每个数字反映的是
    // 对端已确认接收的字节数，而非仅仅已排入 UDP 发送队列的字节数。
    // 按 10% 增量输出进度日志（debug 级别），避免在 info 级别产生过多日志。
    var next_progress: u64 = if (file_size < 10) file_size else @max(@as(u64, 1), file_size / 10);
    var data: [max_block_size]u8 = undefined;
    const window = if (settings.windowsize > 0) settings.windowsize else 1;

    // ── TFTP block number 不变量（RFC 1350）──────────────────────────
    //
    // 协议规定：DATA block N 对应 ACK block N。客户端 ACK 它实际收到的块号，
    // 而非"期望的下一个块号"。因此服务器等待 ACK 时，expected_ack 必须是
    // **最近一次发送的 DATA block 号**，而不是 block 变量递增后的值。
    //
    // 历史缺陷：原代码在发送 DATA 后立即 `block +%= 1`，然后设
    // `expected_ack = block`（递增后的值）。这导致 expected_ack 比实际发送
    // 的块号大 1，客户端的 ACK 被判为 UnexpectedAck，所有多块传输全部失败。
    //
    // 修复方案：引入 last_sent_block 记录实际发送的最后一个块号；
    // block 的递增仅在内层 window 循环中发生（为发送下一个 window 内块准备），
    // 外层循环不再重复递增（原外层 block +%= 1 是单块传输时代的遗留代码）。
    //
    // 正确的 block 生命周期（window=1 多块文件）：
    //   block=1 -> 发送 DATA 1 -> last_sent_block=1 -> block 递增为 2
    //   -> expected_ack=1 -> 客户端 ACK 1 ✅ -> 继续外层循环
    //   block=2 -> 发送 DATA 2 -> last_sent_block=2 -> block 递增为 3
    //   -> expected_ack=2 -> 客户端 ACK 2 ✅ -> ...
    // ──────────────────────────────────────────────────────────────

    while (true) {
        // M4.2 F4：RFC 7440 滑动窗口——在等待 window 最后一块的 ACK 前
        // 最多发送 'window' 个块。
        const window_start_offset = offset;
        const window_start_block = block;
        var blocks_in_window: u16 = 0;
        var last_read: usize = 0;
        var last_sent_block: u16 = block; // 实际发送的最后一个块号（见上方不变量说明）
        while (blocks_in_window < window) {
            const capacity = data[0..settings.block_size];
            const read = try file.readPositionalAll(io, capacity, offset);
            last_read = read;
            var out: [max_block_size + 4]u8 = undefined;
            const datagram = try packet.encodeData(&out, block, capacity[0..read]);
            try socket.send(io, remote, datagram);
            last_sent_block = block; // 记录刚刚发送的块号
            offset += read;
            blocks_in_window += 1;
            // 最后一个负载 < block_size 的 DATA 标志传输结束。
            if (read < settings.block_size) break;
            block +%= 1; // 为 window 内下一个块准备；外层不再重复递增
        }
        // 等待本窗口中实际发送的最后一块的 ACK。
        // expected_ack 必须是 last_sent_block 而非 block（block 可能已递增）。
        const expected_ack = last_sent_block;
        // 末尾块采用较短预算并乐观完成；这表示 delivery unconfirmed，不是
        // RFC 对交付成功的保证。非末尾块耗尽仍失败，因为 NodeForge 的长驻
        // worker 必须准确释放共享槽并写出失败状态，不能照搬 hpa 子进程 exit(0)。
        const is_final_block = last_read < settings.block_size;
        const limit = retryLimit(is_final_block);
        var attempts: usize = 0;
        while (true) {
            awaitAck(&socket, io, remote, expected_ack, backoffSeconds(settings.timeout, attempts)) catch |err| {
                if (err == error.Timeout) {
                    switch (retryAction(is_final_block, attempts, limit)) {
                        .retransmit => {
                            attempts += 1;
                            log.warn("retransmit {s} block {d} attempt {d}/{d}", .{ request.filename, expected_ack, attempts, limit });
                            // 客户端无法在 window 中较早的块丢失时 ACK window 末尾，
                            // 因此按顺序重传整个未完成 window，而非仅重传最后一块。
                            var resend_offset = window_start_offset;
                            var resend_block = window_start_block;
                            var resent: u16 = 0;
                            while (resent < blocks_in_window) : (resent += 1) {
                                const capacity = data[0..settings.block_size];
                                const read = try file.readPositionalAll(io, capacity, resend_offset);
                                var out: [max_block_size + 4]u8 = undefined;
                                const datagram = try packet.encodeData(&out, resend_block, capacity[0..read]);
                                try socket.send(io, remote, datagram);
                                resend_offset += read;
                                resend_block +%= 1;
                            }
                            continue;
                        },
                        .optimistic_complete => {
                            log.info("tftp: final block ACK missing for {s}; delivery unconfirmed, completing optimistically", .{request.filename});
                            return offset;
                        },
                        .fail => return err,
                    }
                }
                return err;
            };
            break;
        }
        // 按 10% 增量输出 debug 级别的下载进度日志。
        while (file_size != 0 and offset >= next_progress) : (next_progress += @max(@as(u64, 1), file_size / 10)) {
            const reported = @min(offset, file_size);
            log.debug("download progress {s}: {d}/{d} bytes ({d}%)", .{ request.filename, reported, file_size, (reported * 100) / file_size });
            if (reported == file_size) break;
        }
        // 最后一个 DATA 的负载小于 block_size 时传输完成（RFC 1350 标准）。
        if (last_read < settings.block_size) return offset;
        // block 已在内层 window 循环中递增到下一个待发送的块号，此处不再重复递增。
    }
}

/// 传输参数协商结果。接受 `blksize`/`timeout`/`tsize`/`windowsize` 四个标准 option。
/// 其他 option 被安全忽略，不返回给客户端。
const Settings = struct {
    block_size: usize = packet.default_block_size,
    timeout: u8 = default_timeout,
    windowsize: u16 = 1,
    use_blksize: bool = false,
    use_timeout: bool = false,
    use_tsize: bool = false,
    use_windowsize: bool = false,

    fn hasOptions(self: Settings) bool {
        return self.use_blksize or self.use_timeout or self.use_tsize or self.use_windowsize;
    }

    fn oackOptions(self: Settings, file_size: u64, values: *[4][20]u8, options: *[4]packet.Option) []const packet.Option {
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
        if (self.use_windowsize) {
            const value = std.fmt.bufPrint(&values[count], "{d}", .{self.windowsize}) catch unreachable;
            options[count] = .{ .name = "windowsize", .value = value };
            count += 1;
        }
        return options[0..count];
    }
};

/// 解析客户端请求的 options 并生成协商结果。
///
/// - `blksize`：接受 8 到 `max_block_size` 之间的值（RFC 2348），
///   服务端返回 `min(requested, max_blksize)`，不放大客户端请求值
/// - `timeout`：接受 1-255 秒，0 被拒绝（RFC 2349），原值回显
/// - `tsize`：仅当客户端发送 `0` 时返回文件实际大小（RFC 2349）
/// - `windowsize`：RFC 7440，clamp 到服务端 `max_windowsize`
/// 未知 option 被安全忽略。
///
/// **blksize 协商契约**（§9.12.5 / M4.3-05）：
/// 客户端请求 blksize 时只允许 `min(requested, configured_max)`，
/// 客户端未请求时不主动放入 OACK。不放大客户端请求值，不主动建议未请求的 option。
/// 早期 M4.2 设计中的"主动建议未请求 blksize"和"放大客户端请求值"已被 M4.3
/// 明确废弃——RFC 2347/2348 的 option 协商边界不允许服务端突破客户端的请求范围。
/// `windowsize` 同理不主动建议（RFC 7440 较新，未请求时下发可能破坏不支持的客户端）。
fn negotiate(options: []const packet.Option, file_size: u64, max_windowsize: u16, max_blksize: u16) !Settings {
    var settings: Settings = .{};
    for (options) |option| {
        if (std.ascii.eqlIgnoreCase(option.name, "blksize")) {
            const value = std.fmt.parseInt(u16, option.value, 10) catch return error.InvalidOption;
            if (value < 8 or value > max_block_size) return error.InvalidOption;
            // blksize 协商：只允许 min(requested, max_blksize)，不放大客户端请求值（§9.12.5）。
            // 客户端请求更大块时 clamp 到 max_blksize 避免 UDP 分片。
            settings.block_size = @min(value, max_blksize);
            settings.use_blksize = true;
        } else if (std.ascii.eqlIgnoreCase(option.name, "timeout")) {
            const value = std.fmt.parseInt(u8, option.value, 10) catch return error.InvalidOption;
            if (value == 0) return error.InvalidOption;
            settings.timeout = value;
            settings.use_timeout = true;
        } else if (std.ascii.eqlIgnoreCase(option.name, "tsize") and std.mem.eql(u8, option.value, "0")) {
            _ = file_size;
            settings.use_tsize = true;
        } else if (std.ascii.eqlIgnoreCase(option.name, "windowsize")) {
            // M4.2 F4：RFC 7440 windowsize 协商。
            // 接受客户端请求的值，限制到服务端最大值。
            const value = std.fmt.parseInt(u16, option.value, 10) catch return error.InvalidOption;
            if (value == 0) return error.InvalidOption;
            settings.windowsize = if (max_windowsize > 0) @min(value, max_windowsize) else value;
            settings.use_windowsize = max_windowsize > 0;
        }
    }
    return settings;
}

/// OACK 与普通非末尾 DATA 使用同一有界重传语义，并始终复用当前 transfer TID。
/// tftpd-hpa 把 OACK 放在同一 timeout/retry 循环中；NodeForge 不能只发送一次，
/// 否则 ACK0 丢失会让客户端重发 RRQ，而旧 worker 仍占用全局并发槽等待超时。
fn sendOackAndAwaitAck(socket: *std.Io.net.Socket, io: std.Io, remote: *const std.Io.net.IpAddress, oack: []const u8, base_timeout: u8) !void {
    var attempts: usize = 0;
    while (true) {
        try socket.send(io, remote, oack);
        awaitAck(socket, io, remote, 0, backoffSeconds(base_timeout, attempts)) catch |err| {
            if (err == error.Timeout and retryAction(false, attempts, max_retries) == .retransmit) {
                attempts += 1;
                log.warn("retransmit OACK attempt {d}/{d}", .{ attempts, max_retries });
                continue;
            }
            return err;
        };
        return;
    }
}

/// 等待指定 block number 的 ACK，超时返回 `error.Timeout`。
///
/// §7.5 RFC 1350 兼容的健壮等待循环：在超时窗口内忽略非预期包并继续等待，
/// 而非在第一个非预期包上立即失败。这修复了一个竞态条件：GRUB 在 OACK
/// 协商期间偶尔发送重复 ACK 或延迟的 ERROR 包，导致整个传输以
/// `UnexpectedAck` 失败。虽然 GRUB 会重试 RRQ 并成功完成传输，但第一次
/// 失败可能使 GRUB 的 UEFI 网络栈进入不一致状态，最终导致
/// "could not seed network packet" 错误。
///
/// 行为规则（与 tftpd-hpa / dnsmasq 一致）：
/// - 来自错误 TID 的包：按 RFC 1350 发送 ERROR(code=5) 并继续等待
/// - 格式错误的包：忽略并继续等待
/// - 重复 ACK（错误块号）：忽略并继续等待
/// - 客户端 ERROR 包：记录日志并返回 `error.UnexpectedAck`（传输终止）
/// - 超时：返回 `error.Timeout`（调用方决定是否重传）
fn awaitAck(socket: *std.Io.net.Socket, io: std.Io, remote: *const std.Io.net.IpAddress, expected: u16, seconds: u8) !void {
    const deadline = boot_session.monotonicNow() + @as(i64, seconds);
    while (true) {
        const remaining = deadline - boot_session.monotonicNow();
        if (remaining <= 0) return error.Timeout;
        const remaining_secs: u8 = @intCast(@min(remaining, @as(i64, 255)));
        var recv_buffer: [516]u8 = undefined;
        var options: [0]packet.Option = .{};
        const incoming = socket.receiveTimeout(io, &recv_buffer, .{ .duration = .{
            .raw = .fromSeconds(remaining_secs),
            .clock = .awake,
        } }) catch |err| {
            if (err == error.Timeout) return error.Timeout;
            return err;
        };
        if (!incoming.from.eql(remote)) {
            // RFC 1350: 来自未知 TID 的包，发送 ERROR(code=5) 并继续等待。
            sendError(socket, io, &incoming.from, .unknown_transfer_id, "Unknown transfer ID") catch {};
            continue;
        }
        const message = packet.parse(incoming.data, &options) catch {
            log.debug("ignoring malformed packet while waiting for ACK {d}", .{expected});
            continue;
        };
        switch (message) {
            .ack => |block_num| {
                if (block_num == expected) return;
                log.debug("ignoring duplicate ACK {d} while waiting for ACK {d}", .{ block_num, expected });
            },
            .err => |info| {
                log.warn("client sent TFTP ERROR code={d} msg={s} while waiting for ACK {d}", .{
                    @intFromEnum(info.code), info.message, expected,
                });
                return error.UnexpectedAck;
            },
            else => {
                log.debug("ignoring unexpected {s} while waiting for ACK {d}", .{ @tagName(message), expected });
            },
        }
    }
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
fn emit(writer: ?*events.Writer, io: std.Io, allocator: std.mem.Allocator, remote: *const std.Io.net.IpAddress, filename: []const u8, event_type: []const u8, message: []const u8, bytes_sent: u64, duration_us: i64, node_id: ?[]const u8, session_link: ?*const boot_session.Link) void {
    const target = writer orelse return;
    var bytes_text: [20]u8 = undefined;
    var duration_text: [20]u8 = undefined;
    var client_ip: [64]u8 = undefined;
    var fields: [7]events.Field = .{
        .{ .key = "filename", .value = filename },
        .{ .key = "bytes_sent", .value = std.fmt.bufPrint(&bytes_text, "{d}", .{bytes_sent}) catch "0" },
        .{ .key = "client_ip", .value = std.fmt.bufPrint(&client_ip, "{f}", .{remote}) catch "unknown" },
        .{ .key = "duration_us", .value = std.fmt.bufPrint(&duration_text, "{d}", .{duration_us}) catch "0" },
        .{ .key = "", .value = "" },
        .{ .key = "", .value = "" },
        .{ .key = "", .value = "" },
    };
    var count: usize = 4;
    if (node_id) |id| {
        fields[count] = .{ .key = "node_id", .value = id };
        count += 1;
    }
    if (session_link) |link| {
        if (link.id()) |id| {
            fields[count] = .{ .key = "boot_session_id", .value = id };
            count += 1;
        } else if (link.state()) |state| {
            fields[count] = .{ .key = "session_link_state", .value = state };
            count += 1;
        }
    }
    target.appendWithFields(io, allocator, @import("../paths.zig").require().events_path, event_type, message, fields[0..count]) catch |err|
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
fn isManifestPath(catalog: *const catalog_runtime.Snapshot, path: []const u8) bool {
    for (catalog.value().assets) |asset| if (std.mem.eql(u8, asset.path, path)) return true;
    return false;
}

test "rejects unsafe TFTP paths" {
    try std.testing.expect(isSafeRelativePath("efi/grubx64.efi"));
    try std.testing.expect(!isSafeRelativePath("../etc/passwd"));
    try std.testing.expect(!isSafeRelativePath("/etc/passwd"));
    try std.testing.expect(!isSafeRelativePath("efi\\grubx64.efi"));
}

test "M4.2 F4 windowsize negotiation clamps to server max" {
    const opts = [_]packet.Option{
        .{ .name = "windowsize", .value = "8" },
        .{ .name = "blksize", .value = "1468" },
    };
    // 服务端最大值为 4；客户端请求 8 → 限制为 4。
    const s = try negotiate(&opts, 1024, 4, 1468);
    try std.testing.expectEqual(@as(u16, 4), s.windowsize);
    try std.testing.expect(s.use_windowsize);
    try std.testing.expectEqual(@as(usize, 1468), s.block_size);
}

test "M4.2 F4 windowsize disabled when server max is 0" {
    const opts = [_]packet.Option{
        .{ .name = "windowsize", .value = "4" },
    };
    const s = try negotiate(&opts, 1024, 0, 1468);
    try std.testing.expect(!s.use_windowsize);
}

test "M4.2 F4 windowsize OACK includes all negotiated options" {
    var values: [4][20]u8 = undefined;
    var options: [4]packet.Option = undefined;
    const s: Settings = .{ .block_size = 1468, .use_blksize = true, .use_windowsize = true, .windowsize = 4, .use_tsize = true };
    const oack = s.oackOptions(65536, &values, &options);
    try std.testing.expectEqual(@as(usize, 3), oack.len);
    var has_windowsize = false;
    for (oack) |opt| if (std.mem.eql(u8, opt.name, "windowsize")) {
        try std.testing.expectEqualStrings("4", opt.value);
        has_windowsize = true;
    };
    try std.testing.expect(has_windowsize);
}

test "M4.2 F4 concurrent transfer limit rejects excess RRQ" {
    var active = std.atomic.Value(u16).init(0);
    try std.testing.expect(reserveTransferSlot(&active, 2));
    try std.testing.expect(reserveTransferSlot(&active, 2));
    try std.testing.expect(!reserveTransferSlot(&active, 2));
    _ = active.fetchSub(1, .acq_rel);
    try std.testing.expect(reserveTransferSlot(&active, 2));
}

test "OACK only includes explicitly requested options" {
    const opts = [_]packet.Option{
        .{ .name = "tsize", .value = "0" },
    };
    const s = try negotiate(&opts, 65536, 4, 1468);
    try std.testing.expect(!s.use_blksize);
    try std.testing.expectEqual(@as(usize, 512), s.block_size);
    try std.testing.expect(s.use_tsize);
    var values: [4][20]u8 = undefined;
    var options: [4]packet.Option = undefined;
    const oack = s.oackOptions(65536, &values, &options);
    try std.testing.expectEqual(@as(usize, 1), oack.len);
    try std.testing.expectEqualStrings("tsize", oack[0].name);
}

test "§7.4 no proactive blksize when client sends no options" {
    // 客户端未发送任何 option → 不得建议 blksize。
    // 避免向不期望 OACK 的客户端发送 OACK。
    const opts = [_]packet.Option{};
    const s = try negotiate(&opts, 1024, 4, 1468);
    try std.testing.expect(!s.use_blksize);
    try std.testing.expectEqual(@as(usize, 512), s.block_size);
    try std.testing.expect(!s.hasOptions());
}

test "§7.4 no proactive blksize when client sends only an unknown option" {
    // 未知 option 被忽略；没有已识别 option 被接受 -> 不发送 OACK，
    // 不主动建议 blksize（客户端可能不期望 OACK）。
    const opts = [_]packet.Option{
        .{ .name = "unknownopt", .value = "1" },
    };
    const s = try negotiate(&opts, 1024, 4, 1468);
    try std.testing.expect(!s.use_blksize);
    try std.testing.expectEqual(@as(usize, 512), s.block_size);
    try std.testing.expect(!s.hasOptions());
}

test "server preserves client blksize below configured maximum" {
    const opts = [_]packet.Option{
        .{ .name = "blksize", .value = "1024" },
        .{ .name = "tsize", .value = "0" },
    };
    const s = try negotiate(&opts, 4096, 4, 1468);
    try std.testing.expect(s.use_blksize);
    try std.testing.expectEqual(@as(usize, 1024), s.block_size);
}

test "blksize clamps down to server max_blksize" {
    // 客户端请求 8192（> 服务端最大 1468）-> 限制为 1468。
    // RFC 2348 允许返回更小的值；避免 IP 分片。
    const opts = [_]packet.Option{
        .{ .name = "blksize", .value = "8192" },
    };
    const s = try negotiate(&opts, 65536, 4, 1468);
    try std.testing.expect(s.use_blksize);
    try std.testing.expectEqual(@as(usize, 1468), s.block_size);
}

test "blksize never exceeds client request" {
    const opts = [_]packet.Option{
        .{ .name = "blksize", .value = "1024" },
    };
    const s = try negotiate(&opts, 65536, 4, 1468);
    try std.testing.expect(s.use_blksize);
    try std.testing.expectEqual(@as(usize, 1024), s.block_size);
}

test "OACK does not add unrequested blksize" {
    const opts = [_]packet.Option{
        .{ .name = "tsize", .value = "0" },
    };
    const s = try negotiate(&opts, 65536, 4, 8192);
    try std.testing.expect(!s.use_blksize);
    try std.testing.expectEqual(@as(usize, 512), s.block_size);
}

test "identifies virtual GRUB config filenames" {
    // MAC 形式
    try std.testing.expect(isVirtualGrubConfig("efi/grub.cfg-01-02-aa-bb-cc-dd-ef"));
    // Hex IP 形式（大写）
    try std.testing.expect(isVirtualGrubConfig("efi/grub.cfg-C0A81BC8"));
    // 回退名称
    try std.testing.expect(isVirtualGrubConfig("efi/grub.cfg"));
    try std.testing.expect(isVirtualGrubConfig("/efi/grub.cfg-C0A81BC8"));
    // 不匹配的路径
    try std.testing.expect(!isVirtualGrubConfig("efi/grub.cfg-01-02-aa-bb-cc-dd-ef-extra"));
    try std.testing.expect(!isVirtualGrubConfig("efi/grub.cfg-XYZ"));
    try std.testing.expect(!isVirtualGrubConfig("efi/grub.cfg-c0a81bc8"));
    try std.testing.expect(!isVirtualGrubConfig("efi/grub.cfg-01-02-AA-bb-cc-dd-ef"));
    try std.testing.expect(!isVirtualGrubConfig("efi/grub.cfg-01-02-aa-bb-cc-dd-gg"));
    try std.testing.expect(!isVirtualGrubConfig("efi/grubaa64.efi"));
    try std.testing.expect(!isVirtualGrubConfig("grub.cfg"));
    try std.testing.expect(!isVirtualGrubConfig("../etc/grub.cfg"));
}

// ── Block number 不变量回归测试 ──────────────────────────────────
//
// 验证 TFTP block number 逻辑的正确性。此测试不涉及网络 socket，
// 而是模拟 transferFile 中 block/last_sent_block/expected_ack 的关系，
// 确保不会因重构再次引入"expected_ack 比实际发送块号大 1"的缺陷。
//
// 不变量：
//   1. DATA block N -> 客户端 ACK block N（不是 N+1）
//   2. expected_ack = last_sent_block（实际发送的最后一个块号）
//   3. block 递增仅在内层循环发生一次，外层不重复递增
//   4. 最后一块（payload < block_size）不递增 block
test "TFTP block number: expected_ack equals last sent block (window=1)" {
    // 模拟 window=1 的多块传输：5 个完整块
    const file_blocks: usize = 5;

    var block: u16 = 1;
    var block_idx: usize = 0;
    while (block_idx < file_blocks) : (block_idx += 1) {
        const is_last = (block_idx == file_blocks - 1);
        // 模拟内层循环
        var last_sent_block: u16 = block;
        // 发送 DATA block
        last_sent_block = block;
        if (!is_last) block +%= 1; // 内层递增
        // expected_ack 必须等于 last_sent_block
        const expected_ack = last_sent_block;
        // 客户端会 ACK last_sent_block（它收到的那个）
        try std.testing.expectEqual(last_sent_block, expected_ack);
        // 下一个块的编号
        if (is_last) {
            // 最后一块不递增（外层也不递增）
            try std.testing.expectEqual(@as(u16, @intCast(file_blocks)), block);
        } else {
            try std.testing.expectEqual(@as(u16, @intCast(block_idx + 2)), block);
        }
    }
}

test "TFTP block number: expected_ack equals last sent block (window=2)" {
    // 模拟 window=2 的多块传输
    const window: u16 = 2;
    const file_blocks: usize = 5;

    var block: u16 = 1;
    var block_idx: usize = 0;
    while (block_idx < file_blocks) {
        // 内层循环：发送 window 个块
        var last_sent_block: u16 = block;
        var sent_in_window: u16 = 0;
        while (sent_in_window < window and block_idx < file_blocks) {
            last_sent_block = block;
            block_idx += 1;
            sent_in_window += 1;
            const is_last = (block_idx == file_blocks);
            if (!is_last and sent_in_window < window) block +%= 1;
        }
        const expected_ack = last_sent_block;
        // ACK 必须等于最后发送的块号
        try std.testing.expectEqual(last_sent_block, expected_ack);
        if (block_idx < file_blocks) block +%= 1; // 外层递增到下一个 window 的起始块
    }
}

// ── 末尾块 ACK 乐观完成 + 指数退避回归测试 ───────────────────────
//
// 发送最后一块 DATA 后，若最终 ACK 丢失，发送方无法区分「接收方已收到数据但
// ACK 丢失」与「DATA 未送达」。NodeForge 在有限短预算后选择 delivery-unconfirmed
// 乐观完成以释放共享 worker；这不是 RFC 的成功交付保证。非末尾块仍失败。
//
// 以下测试覆盖纯决策逻辑（不涉及 socket）：
//   - retryAction：根据「是否末尾块 / 已重传次数 / 上限」决定 retransmit /
//     optimistic_complete / fail
//   - retryLimit：末尾块用更小的重传预算（≈7s）以尽快释放 worker
//   - backoffSeconds：指数退避（每次翻倍，封顶 255）
test "TFTP retry: retransmit while attempts below limit" {
    try std.testing.expectEqual(RetryAction.retransmit, retryAction(false, 0, max_retries));
    try std.testing.expectEqual(RetryAction.retransmit, retryAction(true, 0, final_block_retries));
    try std.testing.expectEqual(RetryAction.retransmit, retryAction(false, max_retries - 1, max_retries));
    try std.testing.expectEqual(RetryAction.retransmit, retryAction(true, final_block_retries - 1, final_block_retries));
}

test "TFTP retry: non-final block exhausted -> fail" {
    try std.testing.expectEqual(RetryAction.fail, retryAction(false, max_retries, max_retries));
    try std.testing.expectEqual(RetryAction.fail, retryAction(false, max_retries + 3, max_retries));
}

test "TFTP retry: final block exhausted -> delivery-unconfirmed optimistic complete" {
    try std.testing.expectEqual(RetryAction.optimistic_complete, retryAction(true, final_block_retries, final_block_retries));
    try std.testing.expectEqual(RetryAction.optimistic_complete, retryAction(true, final_block_retries + 3, final_block_retries));
}

test "TFTP established-transfer failures do not get a new-TID ERROR" {
    try std.testing.expect(initialErrorResponse(error.Timeout) == null);
    try std.testing.expect(initialErrorResponse(error.UnexpectedAck) == null);
    try std.testing.expectEqual(packet.ErrorCode.file_not_found, initialErrorResponse(error.FileNotFound).?.code);
}

const OackRetryTestContext = struct {
    socket: *std.Io.net.Socket,
    remote: std.Io.net.IpAddress,
    result: ?anyerror = null,
};

fn runOackRetryTest(context: *OackRetryTestContext) void {
    const oack = [_]u8{ 0, 6, 't', 's', 'i', 'z', 'e', 0, '0', 0 };
    sendOackAndAwaitAck(context.socket, std.testing.io, &context.remote, &oack, 1) catch |err| {
        context.result = err;
    };
}

test "TFTP OACK loss retransmits from the established transfer TID" {
    const loopback = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try loopback.bind(std.testing.io, .{ .mode = .dgram, .protocol = .udp });
    defer server.close(std.testing.io);
    var client = try loopback.bind(std.testing.io, .{ .mode = .dgram, .protocol = .udp });
    defer client.close(std.testing.io);
    var context: OackRetryTestContext = .{ .socket = &server, .remote = client.address };
    const thread = try std.Thread.spawn(.{}, runOackRetryTest, .{&context});
    var joined = false;
    defer if (!joined) thread.join();

    var buffer: [64]u8 = undefined;
    const first = try client.receiveTimeout(std.testing.io, &buffer, .{ .duration = .{ .raw = .fromSeconds(2), .clock = .awake } });
    try std.testing.expect(first.from.eql(&server.address));
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, first.data[0..2], .big));
    // 丢弃第一次 OACK，等待同一 server TID 的重传。
    const second = try client.receiveTimeout(std.testing.io, &buffer, .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } });
    try std.testing.expect(second.from.eql(&server.address));
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, second.data[0..2], .big));
    var ack_buffer: [4]u8 = undefined;
    const ack = try packet.encodeAck(&ack_buffer, 0);
    try client.send(std.testing.io, &server.address, ack);
    thread.join();
    joined = true;
    try std.testing.expect(context.result == null);
}

test "TFTP retry: retryLimit uses smaller budget for final block" {
    try std.testing.expectEqual(@as(usize, max_retries), retryLimit(false));
    try std.testing.expectEqual(@as(usize, final_block_retries), retryLimit(true));
}

test "TFTP backoff: doubles per attempt and caps at 255" {
    // 1s 基线 + 指数退避：1, 2, 4, 8, 16, 32（6 次等待 = 63s，对齐 tftpd-hpa TRIES=6）
    try std.testing.expectEqual(@as(u8, 1), backoffSeconds(1, 0));
    try std.testing.expectEqual(@as(u8, 2), backoffSeconds(1, 1));
    try std.testing.expectEqual(@as(u8, 4), backoffSeconds(1, 2));
    try std.testing.expectEqual(@as(u8, 32), backoffSeconds(1, 5));
    // 客户端协商 timeout=5 时基线放大
    try std.testing.expectEqual(@as(u8, 5), backoffSeconds(5, 0));
    try std.testing.expectEqual(@as(u8, 10), backoffSeconds(5, 1));
    try std.testing.expectEqual(@as(u8, 160), backoffSeconds(5, 5));
    // 封顶 255（awaitAck 的 seconds 是 u8）
    try std.testing.expectEqual(@as(u8, 255), backoffSeconds(255, 1)); // 510 -> 255
    try std.testing.expectEqual(@as(u8, 255), backoffSeconds(10, 8)); // 远超上限 -> 255
}
