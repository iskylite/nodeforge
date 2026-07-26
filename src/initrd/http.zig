//! # nodeforge-initrd 原生 HTTP 客户端（替代 curl 依赖）
//!
//! ## 设计动机
//!
//! v0.2 初期 nodeforge-initrd 依赖外部 `curl` 子进程与服务端通信。但
//! dracut/casper initrd 环境不一定预装 curl 及其依赖库（`libcurl.so.4`、
//! `libnghttp2.so.14` 等），每次注入需从 rootfs 拷贝二进制和共享库、配置
//! `LD_LIBRARY_PATH`，增加了跨发行版 initrd 构建的脆弱性。
//!
//! v0.2（原生 HTTP）：直接用 Zig 实现 HTTP/1.1 客户端，编译进
//! `nodeforge-initrd` 单一二进制，不依赖任何外部共享库。支持
//! GET/HEAD/POST/Range，响应体可写入文件或内存。
//!
//! ## 功能矩阵
//!
//! | 方法   | 响应体目标 | 重试 | 用途                           |
//! |--------|-----------|------|--------------------------------|
//! | GET    | 内存      | 是   | 拉取 BootConfig v2 JSON          |
//! | HEAD   | 无        | 是   | rootfs 传输契约的元数据校验      |
//! | POST   | 丢弃      | 否   | lifecycle 事件上报（best-effort）|
//! | GET    | 文件      | 否*  | 分块 Range 下载 rootfs            |
//!
//! *Range 下载的重试在 `initrd.zig:downloadRootfs` 中编排（5 次指数退避）。
//!
//! ## 限制
//!
//! - 仅支持 HTTP（不支持 HTTPS/TLS），与 nodeforged 同网段通信模式一致。
//! - 仅支持 IPv4 地址（不支持域名和 IPv6），initrd 阶段不做 DNS 解析。
//! - 不跟随 HTTP 重定向（3xx），避免被引导到非预期地址。
//! - 不支持 chunked transfer-encoding（`Transfer-Encoding: chunked`），
//!   nodeforged 对所有响应显式设置 `Content-Length`。
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

    const address = std.Io.net.IpAddress.parseIp4(url.host, url.port) catch return error.InvalidHost;
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return error.ConnectionFailed;
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

    const address = std.Io.net.IpAddress.parseIp4(url.host, url.port) catch return error.InvalidHost;
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return error.ConnectionFailed;
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

    const address = std.Io.net.IpAddress.parseIp4(url.host, url.port) catch return error.InvalidHost;
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return error.ConnectionFailed;
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

/// GET 请求，响应体写入文件。返回原始响应头文本（供 `download.validateRange` 校验）。
/// 调用方负责释放返回的 headers。
pub fn getToFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: Url,
    headers: []const Header,
    dest: []const u8,
) ![]u8 {
    log("[nodeforge-initrd] GET http://{s}:{d}{s} → {s}\n", .{ url.host, url.port, url.path, dest });

    const address = std.Io.net.IpAddress.parseIp4(url.host, url.port) catch return error.InvalidHost;
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return error.ConnectionFailed;
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
    const len = resp.content_length orelse return error.MissingContentLength;

    // 读取响应体到 heap buffer，然后写入文件
    const body = try allocator.alloc(u8, len);
    defer allocator.free(body);
    reader.interface.readSliceAll(body) catch return error.TruncatedResponse;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = body });

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
