//! Strict HTTP metadata/range response validation for the v0.2 initrd downloader.

const std = @import("std");

pub const Head = struct {
    size: u64,
    etag: []const u8,
};

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
    // curl -D may contain interim 1xx blocks. With redirects disabled the final
    // HTTP block is the last block beginning with HTTP/.
    var result = headers;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, headers, offset, "HTTP/")) |index| {
        result = headers[index..];
        offset = index + 5;
    }
    return result;
}

fn statusCode(block: []const u8) u16 {
    const line_end = std.mem.indexOfAny(u8, block, "\r\n") orelse block.len;
    var fields = std.mem.tokenizeScalar(u8, block[0..line_end], ' ');
    _ = fields.next();
    return std.fmt.parseInt(u16, fields.next() orelse return 0, 10) catch 0;
}

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
