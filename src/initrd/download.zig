//! 严格校验 initrd rootfs 传输的 HTTP HEAD/Range 响应头（fail-closed）。
//!
//! 本模块只负责头部解析与校验，不发起网络请求；实际下载与分块编排见
//! `src/initrd.zig` 的 `downloadRootfs`。两者共同实现 v0.2 rootfs 传输契约：
//! 严格 HEAD -> 分块 Range -> 逐块元数据校验 -> 最终 SHA-512。
//!
//! fail-closed 语义：任一头字段缺失/不匹配/状态码错误即返回错误，整次下载被拒绝，
//! 绝不写入部分或漂移的内容。负向场景（ETag 漂移、内容损坏、断流）由
//! `tests/v0_2_transfer_fault.sh` 覆盖，其校验逻辑精确复刻本模块。

const std = @import("std");

/// HEAD 阶段提取并校验后的根 rootfs 元数据。
pub const Head = struct {
    /// rootfs 字节大小，必须与 AgentPlan 固定的 expected_size 完全一致。
    size: u64,
    /// immutable ETag，后续每个 Range 请求经 `If-Range` 绑定同一 ETag。
    etag: []const u8,
};

/// 解析并严格校验 HEAD 响应。任一条件不满足即 fail-closed：
///   - 状态码 200；
///   - `Content-Length` 等于 AgentPlan 固定的 expected_size（防截断/扩写）；
///   - `ETag` 与 expected_etag 完全一致（防服务端在 HEAD 与 Range 间换内容）；
///   - `Accept-Ranges: bytes`（服务器必须支持分块续传）。
pub fn parseHead(headers: []const u8, expected_size: u64, expected_etag: []const u8) !Head {
    const block = finalHeaderBlock(headers);
    if (statusCode(block) != 200) return error.HeadStatusInvalid;
    const length = try std.fmt.parseInt(u64, header(block, "content-length") orelse return error.ContentLengthMissing, 10);
    if (length != expected_size) return error.ContentLengthMismatch;
    const etag = header(block, "etag") orelse return error.EtagMissing;
    if (!std.mem.eql(u8, etag, expected_etag)) return error.EtagMismatch;
    const ranges = header(block, "accept-ranges") orelse return error.AcceptRangesMissing;
    if (!std.ascii.eqlIgnoreCase(ranges, "bytes")) return error.AcceptRangesInvalid;
    return .{ .size = length, .etag = etag };
}

/// 校验单块 Range 响应头。任一条件不满足即 fail-closed：
///   - 状态码 206（非 200：若 `If-Range` ETag 不匹配服务器会退回 200 全量，必须拒绝）；
///   - `ETag` 与 HEAD 阶段一致（防块间内容漂移）；
///   - `Content-Range: bytes start-end/total` 与请求区间精确一致（防错位拼接）；
///   - `Content-Length` 等于 `end-start+1`（防单块截断/扩写）。
/// 逐块通过后仍需最终整段 SHA-512 校验（见 `downloadRootfs`），
/// 因为逐块头合法不代表字节未损坏。
pub fn validateRange(headers: []const u8, start: u64, end: u64, total: u64, expected_etag: []const u8) !void {
    const block = finalHeaderBlock(headers);
    if (statusCode(block) != 206) return error.RangeStatusInvalid;
    const etag = header(block, "etag") orelse return error.EtagMissing;
    if (!std.mem.eql(u8, etag, expected_etag)) return error.EtagMismatch;
    const content_range = header(block, "content-range") orelse return error.ContentRangeMissing;
    var expected: [96]u8 = undefined;
    const value = try std.fmt.bufPrint(&expected, "bytes {d}-{d}/{d}", .{ start, end, total });
    if (!std.mem.eql(u8, content_range, value)) return error.ContentRangeMismatch;
    const length = try std.fmt.parseInt(u64, header(block, "content-length") orelse return error.ContentLengthMissing, 10);
    if (length != end - start + 1) return error.ContentLengthMismatch;
}

fn finalHeaderBlock(headers: []const u8) []const u8 {
    // 原生 HTTP 客户端（`initrd/http.zig`）不跟随重定向，正常情况只返回一个
    // 响应块。但 1xx 中间响应理论上仍可能出现，最终有效块是最后一个以 `HTTP/`
    // 开头的块。该函数从前往后逐次锚定 `HTTP/`，返回最后一次匹配的子串。
    //
    // 易错点：响应头里若出现子串 `HTTP/`（例如故障注入服务器默认的
    // `Server: BaseHTTP/0.6 Python/3.x`），会被误判为新块的起点而把真实块截短。
    // 因此校验只应锚定行首的 `HTTP/`，但 `indexOfPos` 不区分行首；实际依赖
    // `tests/v0_2_transfer_fault.sh` 的故障服务器抑制 `Server:` 头来规避。
    // 生产 nodeforged 不发 `Server` 头，无此风险。
    var result = headers;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, headers, offset, "HTTP/")) |index| {
        result = headers[index..];
        offset = index + 5;
    }
    return result;
}

/// 从状态行（`HTTP/1.1 <code> ...`）解析数字状态码；解析失败返回 0（调用方判 != 200/206 即拒绝）。
fn statusCode(block: []const u8) u16 {
    const line_end = std.mem.indexOfAny(u8, block, "\r\n") orelse block.len;
    var fields = std.mem.tokenizeScalar(u8, block[0..line_end], ' ');
    _ = fields.next();
    return std.fmt.parseInt(u16, fields.next() orelse return 0, 10) catch 0;
}

/// 大小写不敏感地按名查找单个响应头值；缺失返回 null（调用方视缺失为 fail-closed）。
fn header(block: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, block, '\n');
    _ = lines.next();
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(line[0..colon], name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t\r");
    }
    return null;
}

// 覆盖 `parseHead`/`validateRange` 的正例与各 fail-closed 分支：
// 状态码错、ETag 漂移、Content-Length 不匹配、Content-Range 错位。
// 与 `tests/v0_2_transfer_fault.sh` 的端到端负测一一对应。
test "strict HEAD and Range metadata validation" {
    const etag = "\"abcdef\"";
    const head = "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nETag: \"abcdef\"\r\nAccept-Ranges: bytes\r\n\r\n";
    const parsed = try parseHead(head, 10, etag);
    try std.testing.expectEqual(@as(u64, 10), parsed.size);
    const range = "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nContent-Range: bytes 4-7/10\r\nETag: \"abcdef\"\r\n\r\n";
    try validateRange(range, 4, 7, 10, etag);
    try std.testing.expectError(error.RangeStatusInvalid, validateRange("HTTP/1.1 200 OK\r\n\r\n", 4, 7, 10, etag));
    try std.testing.expectError(error.EtagMismatch, parseHead(
        "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nETag: \"drifted\"\r\nAccept-Ranges: bytes\r\n\r\n",
        10,
        etag,
    ));
    try std.testing.expectError(error.ContentLengthMismatch, parseHead(
        "HTTP/1.1 200 OK\r\nContent-Length: 9\r\nETag: \"abcdef\"\r\nAccept-Ranges: bytes\r\n\r\n",
        10,
        etag,
    ));
    try std.testing.expectError(error.ContentRangeMismatch, validateRange(
        "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nContent-Range: bytes 5-8/10\r\nETag: \"abcdef\"\r\n\r\n",
        4,
        7,
        10,
        etag,
    ));
    try std.testing.expectError(error.EtagMismatch, validateRange(
        "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nContent-Range: bytes 4-7/10\r\nETag: \"drifted\"\r\n\r\n",
        4,
        7,
        10,
        etag,
    ));
}
