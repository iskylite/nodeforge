//! # diskless initrd/agent 共享原生 HTTP 客户端（替代 curl 依赖）
//!
//! ## 设计动机
//!
//! v0.2 初期启动组件依赖外部 `curl` 子进程与服务端通信。但
//! dracut/casper initrd 环境不一定预装 curl 及其依赖库（`libcurl.so.4`、
//! `libnghttp2.so.14` 等），每次注入需从 rootfs 拷贝二进制和共享库、配置
//! `LD_LIBRARY_PATH`，增加了跨发行版 initrd 构建的脆弱性。
//!
//! v0.2（原生 HTTP）：直接用 Zig 实现 HTTP/1.1 客户端，同时编译进
//! `nodeforge-initrd` 与 `nodeforge-agent`，不依赖目标 initrd/rootfs 中的
//! curl 或其共享库。支持 GET/HEAD/POST/PATCH/Range，响应体可写入文件或内存。
//!
//! ## 功能矩阵
//!
//! | 方法   | 响应体目标 | 重试 | 用途                           |
//! |--------|-----------|------|--------------------------------|
//! | GET    | 内存      | 是   | BootConfig / AgentPlan            |
//! | HEAD   | 无        | 是   | rootfs 传输契约的元数据校验       |
//! | POST   | 丢弃      | 否   | facts/events/agent-consumed        |
//! | GET    | 文件      | 否*  | rootfs Range / AgentPlan payload   |
//!
//! *rootfs Range 重试由 `initrd.zig:downloadRootfs` 编排；agent payload 的
//! 完整性由 AgentPlan 中固定的 size/digest 校验，失败即阻止进入 systemd。
//!
//! ## 限制
//!
//! - 仅支持 HTTP（不支持 HTTPS/TLS），与 nodeforged 同网段通信模式一致。
//! - 仅支持 IPv4 地址（不支持域名和 IPv6），initrd 阶段不做 DNS 解析。
//! - 不跟随 HTTP 重定向（3xx），避免被引导到非预期地址。
//! - 不支持 chunked transfer-encoding（`Transfer-Encoding: chunked`），
//!   nodeforged 对所有响应显式设置 `Content-Length`。
//! - 制品响应先校验调用方声明的状态码/长度，再以固定缓冲流式落盘；Range
//!   必须在读取 body 前确认 206，避免异常 200 把完整 rootfs 拉入内存。
//!
//! ## 进度输出
//!
//! 所有请求向 stderr（initrd 中连接到串口控制台）输出一行请求/响应日志，
//! 格式为 `[nodeforge-initrd] METHOD url → status (size)`，类似 curl 的
//! 进度条，便于在 PXE 启动串口日志中定位传输阶段和排查故障。

const std = @import("std");

/// 解析后的 HTTP URL。
pub const Url = struct {
    host: []const u8,
    port: u16,
    path: []const u8,

    /// 解析 `http://host:port/path` 格式的 URL。
    /// 不支持 HTTPS、IPv6 或 URL 编码的路径。
    pub fn parse(url: []const u8) !Url {
        if (!std.mem.startsWith(u8, url, "http://")) return error.UnsupportedScheme;
        const rest = url["http://".len..];
        const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse {
            return parseHostPort(rest, "/");
        };
        return parseHostPort(rest[0..path_start], rest[path_start..]);
    }

    fn parseHostPort(host_port: []const u8, path: []const u8) !Url {
        if (host_port.len == 0) return error.InvalidUrl;
        if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
            const host = host_port[0..colon];
            const port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return error.InvalidPort;
            if (host.len == 0) return error.InvalidUrl;
            return .{ .host = host, .port = port, .path = path };
        }
        return .{ .host = host_port, .port = 80, .path = path };
    }
};

/// HTTP 请求头（name/value 对）。
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// 向 stderr（console）输出一行日志。在 initrd 中 stderr 连接到串口控制台。
/// 使用 `write(2)` 系统调用直接输出，不依赖 stdio 缓冲，确保在 panic
/// 前的进度信息也能被看到。
fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, msg.ptr, msg.len);
}

/// initrd/agent 的 HTTP 都是启动关键路径，不能允许 connect/read/write 永久阻塞。
/// Zig 0.16 Threaded Io 的 POSIX connect timeout 尚未实现，传入 deadline 会直接
/// panic 并杀死整个 nodeforged（TFTP loopback boot-prepare 也复用本模块）。
/// 因此这里暂时使用内核有界 TCP connect，已连接 socket 再按请求类型设置空闲
/// 收发超时（API/HEAD 30 秒、制品 Range 120 秒）。空闲超时会沿现有错误链进入
/// 调用方的有界重试或 fail-closed 路径，最终由 PID 1 顶层打印具体 stage/error。
/// 这里没有“总下载时长”上限：只要 socket 持续产生收发进展，慢速大文件可继续下载。
fn connect(url: Url, io: std.Io, idle_timeout_seconds: isize) !std.Io.net.Stream {
    const address = std.Io.net.IpAddress.parseIp4(url.host, url.port) catch return error.InvalidHost;
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return error.ConnectionFailed;
    errdefer stream.close(io);
    const timeout: std.posix.timeval = .{ .sec = idle_timeout_seconds, .usec = 0 };
    try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
    try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout));
    return stream;
}

/// 读取 HTTP 响应头（状态行 + 所有头部，直到空行）。
/// 返回 heap 分配的原始头文本，调用方负责释放。
fn readResponseHeaders(allocator: std.mem.Allocator, reader: *std.Io.Reader) !struct { raw: []u8, status: u16, content_length: ?u64 } {
    var stack_buf: [8192]u8 = undefined;
    var len: usize = 0;

    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch return error.TruncatedResponse;
        if (len + line.len > stack_buf.len) return error.HeadersTooLarge;
        @memcpy(stack_buf[len..][0..line.len], line);
        len += line.len;
        if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
    }

    const raw = try allocator.dupe(u8, stack_buf[0..len]);

    // 解析状态行
    const line_end = std.mem.indexOfAny(u8, raw, "\r\n") orelse raw.len;
    var fields = std.mem.tokenizeScalar(u8, raw[0..line_end], ' ');
    _ = fields.next(); // HTTP/1.1
    const status = if (fields.next()) |s| std.fmt.parseInt(u16, s, 10) catch 0 else 0;

    // 解析 Content-Length
    var content_length: ?u64 = null;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    _ = lines.next(); // 状态行
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(u64, value, 10) catch null;
        }
    }

    return .{ .raw = raw, .status = status, .content_length = content_length };
}

/// GET 请求，响应体读取到内存。调用方负责释放返回的 body。
pub fn get(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: Url,
    headers: []const Header,
) ![]u8 {
    log("[nodeforge-initrd] GET http://{s}:{d}{s}\n", .{ url.host, url.port, url.path });

    var stream = try connect(url, io, 30);
    defer stream.close(io);

    // 发送请求
    {
        var send_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &send_buf);
        try writer.interface.print("GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ url.path, url.host, url.port });
        for (headers) |hdr| {
            try writer.interface.print("{s}: {s}\r\n", .{ hdr.name, hdr.value });
        }
        try writer.interface.print("Connection: close\r\n\r\n", .{});
        try writer.interface.flush();
    }

    // 读取响应头
    var recv_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    const resp = try readResponseHeaders(allocator, &reader.interface);
    defer allocator.free(resp.raw);

    if (resp.status < 200 or resp.status >= 300) {
        // 非 2xx 响应：尽力读取 body 中的错误信封并打印到串口日志，
        // 帮助 PXE 启动排障时区分"凭证失败（401 diskless.token_expired/
        // diskless.unauthorized）vs 服务端故障（500）vs 路由不存在（404）"。
        //
        // 安全考量：body 只用于日志预览，不返回给调用方（initrd main 只拿到
        // error.HttpError），避免错误信封中的 request_id 等字段进入后续逻辑。
        // 预览上限 1024 字节，足以容纳服务端的标准错误信封（code+message+
        // request_id 约 200 字节），超过此大小的响应体不读取。
        //
        // Content-Length 缺失或 > 1024 时退化为只打印状态码，与旧行为一致。
        if (resp.content_length) |cl| {
            if (cl <= 1024) {
                var err_body: [1024]u8 = undefined;
                // 按实际 Content-Length 截取切片，避免读取过多或过少。
                const preview = err_body[0..@intCast(cl)];
                // readSliceAll 失败表示响应被截断（网络中断等），
                // 单独打印 truncated 提示，不吞掉错误。
                reader.interface.readSliceAll(preview) catch {
                    log("[nodeforge-initrd] GET → {d} (error body truncated)\n", .{resp.status});
                    return error.HttpError;
                };
                log("[nodeforge-initrd] GET → {d} (error): {s}\n", .{ resp.status, preview });
                return error.HttpError;
            }
        }
        // Content-Length 缺失或响应体过大：只打印状态码，不尝试读取 body。
        log("[nodeforge-initrd] GET → {d} (error)\n", .{resp.status});
        return error.HttpError;
    }
    const len = resp.content_length orelse return error.MissingContentLength;
    if (len > 16 * 1024 * 1024) return error.ResponseTooLarge;

    // 读取响应体
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    reader.interface.readSliceAll(body) catch return error.TruncatedResponse;

    log("[nodeforge-initrd] GET → {d} ({d} bytes)\n", .{ resp.status, len });
    return body;
}

/// HEAD 请求，返回原始响应头文本（供 `download.parseHead` 校验）。
/// 调用方负责释放返回的 headers。
pub fn head(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: Url,
    headers: []const Header,
) ![]u8 {
    log("[nodeforge-initrd] HEAD http://{s}:{d}{s}\n", .{ url.host, url.port, url.path });

    var stream = try connect(url, io, 30);
    defer stream.close(io);

    // 发送请求
    {
        var send_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &send_buf);
        try writer.interface.print("HEAD {s} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ url.path, url.host, url.port });
        for (headers) |hdr| {
            try writer.interface.print("{s}: {s}\r\n", .{ hdr.name, hdr.value });
        }
        try writer.interface.print("Connection: close\r\n\r\n", .{});
        try writer.interface.flush();
    }

    // 读取响应头（HEAD 无响应体）
    var recv_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    const resp = try readResponseHeaders(allocator, &reader.interface);

    log("[nodeforge-initrd] HEAD → {d}\n", .{resp.status});
    return resp.raw;
}

/// POST 请求，发送 body 并返回 HTTP 状态码。best-effort：失败返回 error。
pub fn post(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: Url,
    headers: []const Header,
    body: []const u8,
) !u16 {
    log("[nodeforge-initrd] POST http://{s}:{d}{s} ({d} bytes)\n", .{ url.host, url.port, url.path, body.len });

    var stream = try connect(url, io, 30);
    defer stream.close(io);

    // 发送请求
    {
        var send_buf: [8192]u8 = undefined;
        var writer = stream.writer(io, &send_buf);
        try writer.interface.print("POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ url.path, url.host, url.port });
        for (headers) |hdr| {
            try writer.interface.print("{s}: {s}\r\n", .{ hdr.name, hdr.value });
        }
        try writer.interface.print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        try writer.interface.writeAll(body);
        try writer.interface.flush();
    }

    // 读取响应头
    var recv_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    const resp = try readResponseHeaders(allocator, &reader.interface);
    defer allocator.free(resp.raw);

    // 读取并丢弃响应体（如果有）
    if (resp.content_length) |cl| {
        if (cl > 0) {
            var discard_buf: [4096]u8 = undefined;
            var remaining = cl;
            while (remaining > 0) {
                const to_read = @min(remaining, discard_buf.len);
                reader.interface.readSliceAll(discard_buf[0..to_read]) catch break;
                remaining -= to_read;
            }
        }
    }

    log("[nodeforge-initrd] POST → {d}\n", .{resp.status});
    return resp.status;
}

pub fn postForBody(io: std.Io, allocator: std.mem.Allocator, url: Url, headers: []const Header, body: []const u8) ![]u8 {
    var stream = try connect(url, io, 30);
    defer stream.close(io);
    {
        var send_buf: [8192]u8 = undefined;
        var writer = stream.writer(io, &send_buf);
        try writer.interface.print("POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ url.path, url.host, url.port });
        for (headers) |hdr| try writer.interface.print("{s}: {s}\r\n", .{ hdr.name, hdr.value });
        try writer.interface.print("Content-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
        try writer.interface.writeAll(body);
        try writer.interface.flush();
    }
    var recv_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    const resp = try readResponseHeaders(allocator, &reader.interface);
    defer allocator.free(resp.raw);
    if (resp.status < 200 or resp.status >= 300) return error.HttpError;
    const len = resp.content_length orelse return error.MissingContentLength;
    if (len > 1024 * 1024) return error.ResponseTooLarge;
    const response = try allocator.alloc(u8, len);
    errdefer allocator.free(response);
    reader.interface.readSliceAll(response) catch return error.TruncatedResponse;
    return response;
}

/// GET 请求，响应体写入文件。返回原始响应头文本（供 `download.validateRange` 校验）。
/// 调用方负责释放返回的 headers。
pub fn getToFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: Url,
    headers: []const Header,
    dest: []const u8,
    expected_status: ?u16,
    expected_length: ?u64,
) ![]u8 {
    log("[nodeforge-initrd] GET http://{s}:{d}{s} → {s}\n", .{ url.host, url.port, url.path, dest });

    // rootfs/payload 等制品请求允许长时间持续传输；这里的 120 秒是 socket
    // 连续无进展的空闲超时，不是整个响应必须在 120 秒内完成。
    var stream = try connect(url, io, 120);
    defer stream.close(io);

    // 发送请求
    {
        var send_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &send_buf);
        try writer.interface.print("GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{ url.path, url.host, url.port });
        for (headers) |hdr| {
            try writer.interface.print("{s}: {s}\r\n", .{ hdr.name, hdr.value });
        }
        try writer.interface.print("Connection: close\r\n\r\n", .{});
        try writer.interface.flush();
    }

    // 读取响应头
    var recv_buf: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    const resp = try readResponseHeaders(allocator, &reader.interface);
    errdefer allocator.free(resp.raw);

    if (resp.status < 200 or resp.status >= 300) {
        log("[nodeforge-initrd] GET → {d} (error)\n", .{resp.status});
        return error.HttpError;
    }
    if (expected_status) |status| {
        if (resp.status != status) return error.UnexpectedHttpStatus;
    }
    const len = resp.content_length orelse return error.MissingContentLength;
    if (expected_length) |expected| {
        if (len != expected) return error.UnexpectedContentLength;
    }

    // 不能按服务端 Content-Length 一次性申请内存：payload 可能很大，而异常的
    // If-Range 响应甚至可能返回完整 rootfs。先校验调用方声明的 status/长度，
    // 再用固定缓冲流式写临时文件，使内存占用与制品大小无关。
    var file = try std.Io.Dir.cwd().createFile(io, dest, .{ .truncate = true });
    defer file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, dest) catch {};
    var buffer: [256 * 1024]u8 = undefined;
    var remaining = len;
    while (remaining > 0) {
        const count: usize = @intCast(@min(remaining, buffer.len));
        reader.interface.readSliceAll(buffer[0..count]) catch return error.TruncatedResponse;
        try file.writeStreamingAll(io, buffer[0..count]);
        remaining -= count;
    }
    try file.sync(io);

    log("[nodeforge-initrd] GET → {d} ({d} bytes → {s})\n", .{ resp.status, len, dest });
    return resp.raw;
}

// ─── 带重试的封装 ───────────────────────────────────────────

/// 带重试的 GET。最多 `max_retries` 次尝试，指数退避（1s, 2s, 4s, ...）。
pub fn getWithRetry(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: Url,
    headers: []const Header,
    max_retries: u8,
) ![]u8 {
    var attempts: u8 = 0;
    while (true) {
        return get(io, allocator, url, headers) catch |err| {
            attempts += 1;
            if (attempts >= max_retries) return err;
            const delay_ms: i64 = @as(i64, 1000) << @intCast(attempts - 1);
            log("[nodeforge-initrd] GET retry {d}/{d} after {d}ms ({t})\n", .{ attempts, max_retries, delay_ms, err });
            std.Io.sleep(io, .fromMilliseconds(delay_ms), .awake) catch {};
            continue;
        };
    }
}

/// 带重试的 HEAD。最多 `max_retries` 次尝试，指数退避。
pub fn headWithRetry(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: Url,
    headers: []const Header,
    max_retries: u8,
) ![]u8 {
    var attempts: u8 = 0;
    while (true) {
        return head(io, allocator, url, headers) catch |err| {
            attempts += 1;
            if (attempts >= max_retries) return err;
            const delay_ms: i64 = @as(i64, 1000) << @intCast(attempts - 1);
            log("[nodeforge-initrd] HEAD retry {d}/{d} after {d}ms ({t})\n", .{ attempts, max_retries, delay_ms, err });
            std.Io.sleep(io, .fromMilliseconds(delay_ms), .awake) catch {};
            continue;
        };
    }
}

// ─── 单元测试 ───────────────────────────────────────────────

test "Url parses http://host:port/path" {
    const u = try Url.parse("http://10.0.2.2:18090/api/v1/boot/config");
    try std.testing.expectEqualStrings("10.0.2.2", u.host);
    try std.testing.expectEqual(@as(u16, 18090), u.port);
    try std.testing.expectEqualStrings("/api/v1/boot/config", u.path);
}

test "Url parses http://host/path (default port 80)" {
    const u = try Url.parse("http://192.168.1.1/index.html");
    try std.testing.expectEqualStrings("192.168.1.1", u.host);
    try std.testing.expectEqual(@as(u16, 80), u.port);
    try std.testing.expectEqualStrings("/index.html", u.path);
}

test "Url rejects https" {
    try std.testing.expectError(error.UnsupportedScheme, Url.parse("https://10.0.2.2:443/path"));
}

test "Url rejects empty host" {
    try std.testing.expectError(error.InvalidUrl, Url.parse("http://:8080/path"));
}

test "Url handles path-only" {
    const u = try Url.parse("http://10.0.2.2:8080");
    try std.testing.expectEqualStrings("10.0.2.2", u.host);
    try std.testing.expectEqual(@as(u16, 8080), u.port);
    try std.testing.expectEqualStrings("/", u.path);
}
