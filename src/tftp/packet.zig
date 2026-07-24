//! RFC 1350 / RFC 2347 TFTP 报文编解码。
//!
//! 本模块只处理单个 UDP datagram 的纯编解码，不访问网络或文件系统。所有字符串和数据
//! 均借用调用方的接收缓冲区，调用方必须在下一次复用缓冲区前处理完结果。
//!
//! 协议参考：
//! - RFC 1350: The TFTP Protocol (Revision 2) — 定义 RRQ/WRQ/DATA/ACK/ERROR
//! - RFC 2347: TFTP Option Extension — 定义 OACK 和 option 协商
//! - RFC 2348: TFTP Blocksize Option — `blksize` 协商
//! - RFC 2349：TFTP 超时间隔与传输大小选项 - `timeout`/`tsize`
//!
//! 字节序：所有 opcode 和 block number 均为大端序（网络字节序）。
//! 字符串字段以单个 `\0` 结尾，不允许内部嵌入 `\0`。
//! DATA 负载最大值由调用方传入的 `blksize` 决定，本模块不限制。

const std = @import("std");

/// TFTP 操作码。所有值以大端序传输。
/// 详见 RFC 1350 Section 5 和 RFC 2347 Section 1。
pub const Opcode = enum(u16) {
    rrq = 1,
    wrq = 2,
    data = 3,
    ack = 4,
    err = 5,
    oack = 6,
};

/// TFTP 标准 ERROR code。详见 RFC 1350 Appendix I。
/// `undefined` 用于不匹配已知 code 的错误值，保持报文边界完整。
pub const ErrorCode = enum(u16) {
    undefined = 0,
    file_not_found = 1,
    access_violation = 2,
    disk_full = 3,
    illegal_operation = 4,
    unknown_transfer_id = 5,
    file_exists = 6,
    no_such_user = 7,
};

/// RFC 2347 的 name/value option。
pub const Option = struct {
    name: []const u8,
    value: []const u8,
};

/// RRQ/WRQ 共享的请求格式。
/// `filename` 和 `mode` 以 `\0` 结尾；`options` 为 RFC 2347 扩展选项列表。
/// `mode` 在 TFTP 标准中定义为 netascii/octet/mail；NodeForge 只接受 octet。
pub const Request = struct {
    filename: []const u8,
    mode: []const u8,
    options: []const Option,
};

/// 解析后的 TFTP datagram。
pub const Message = union(enum) {
    rrq: Request,
    wrq: Request,
    data: struct { block: u16, bytes: []const u8 },
    ack: u16,
    err: struct { code: ErrorCode, message: []const u8 },
    oack: []const Option,
};

pub const ParseError = error{
    PacketTooShort,
    InvalidOpcode,
    InvalidRequest,
    InvalidData,
    InvalidAck,
    InvalidError,
    InvalidOption,
    TooManyOptions,
};

pub const EncodeError = error{BufferTooSmall};

/// TFTP 的默认 DATA 负载大小（RFC 1350 Section 4.1）。
/// 当客户端未请求 `blksize` 或请求值非法时使用此默认值。
pub const default_block_size: u16 = 512;

/// 解析一个 TFTP datagram。`option_storage` 由调用方提供，避免报文路径分配内存。
///
/// 返回 `ParseError` 之一；所有错误都不消耗外部资源。
/// 解析后的 `Message` 中所有 slice 均借用 `bytes` 的内存，调用方必须在释放原始缓冲区前处理完结果。
pub fn parse(bytes: []const u8, option_storage: []Option) ParseError!Message {
    if (bytes.len < 2) return error.PacketTooShort;
    const opcode = std.mem.readInt(u16, bytes[0..2], .big);
    return switch (opcode) {
        @intFromEnum(Opcode.rrq) => .{ .rrq = try parseRequest(bytes[2..], option_storage) },
        @intFromEnum(Opcode.wrq) => .{ .wrq = try parseRequest(bytes[2..], option_storage) },
        @intFromEnum(Opcode.data) => blk: {
            if (bytes.len < 4) return error.InvalidData;
            break :blk .{ .data = .{
                .block = std.mem.readInt(u16, bytes[2..4], .big),
                .bytes = bytes[4..],
            } };
        },
        @intFromEnum(Opcode.ack) => blk: {
            if (bytes.len != 4) return error.InvalidAck;
            break :blk .{ .ack = std.mem.readInt(u16, bytes[2..4], .big) };
        },
        @intFromEnum(Opcode.err) => blk: {
            if (bytes.len < 5 or bytes[bytes.len - 1] != 0) return error.InvalidError;
            const code: ErrorCode = switch (std.mem.readInt(u16, bytes[2..4], .big)) {
                1 => .file_not_found,
                2 => .access_violation,
                3 => .disk_full,
                4 => .illegal_operation,
                5 => .unknown_transfer_id,
                6 => .file_exists,
                7 => .no_such_user,
                else => .undefined,
            };
            break :blk .{ .err = .{ .code = code, .message = bytes[4 .. bytes.len - 1] } };
        },
        @intFromEnum(Opcode.oack) => .{ .oack = try parseOptions(bytes[2..], option_storage) },
        else => error.InvalidOpcode,
    };
}

/// 生成 DATA 包。`block` 从 1 开始递增；`bytes` 为 DATA 负载。
/// 返回的 slice 借用 `buffer` 的内存。详见 RFC 1350 Section 4.1。
pub fn encodeData(buffer: []u8, block: u16, bytes: []const u8) EncodeError![]const u8 {
    if (buffer.len < bytes.len + 4) return error.BufferTooSmall;
    writeHeader(buffer[0..4], .data, block);
    @memcpy(buffer[4 .. 4 + bytes.len], bytes);
    return buffer[0 .. 4 + bytes.len];
}

/// 生成 ACK 包。`block` 为已确认的 DATA block number。
/// 详见 RFC 1350 Section 4.2。
pub fn encodeAck(buffer: []u8, block: u16) EncodeError![]const u8 {
    if (buffer.len < 4) return error.BufferTooSmall;
    writeHeader(buffer[0..4], .ack, block);
    return buffer[0..4];
}

/// 生成 ERROR 包。`code` 为标准 TFTP error code，`message` 为人类可读原因。
/// `message` 以单个 `\0` 结尾。详见 RFC 1350 Section 4.3。
pub fn encodeError(buffer: []u8, code: ErrorCode, message: []const u8) EncodeError![]const u8 {
    if (buffer.len < message.len + 5) return error.BufferTooSmall;
    writeHeader(buffer[0..4], .err, @intFromEnum(code));
    @memcpy(buffer[4 .. 4 + message.len], message);
    buffer[4 + message.len] = 0;
    return buffer[0 .. 5 + message.len];
}

/// 生成 OACK 包；仅写入已接受的 option。
/// 每个 option 由 `name\0value\0` 对组成。详见 RFC 2347 Section 2.1。
pub fn encodeOack(buffer: []u8, options: []const Option) EncodeError![]const u8 {
    if (buffer.len < 2) return error.BufferTooSmall;
    std.mem.writeInt(u16, buffer[0..2], @intFromEnum(Opcode.oack), .big);
    var index: usize = 2;
    for (options) |option| {
        const needed = option.name.len + option.value.len + 2;
        if (buffer.len - index < needed) return error.BufferTooSmall;
        @memcpy(buffer[index .. index + option.name.len], option.name);
        index += option.name.len;
        buffer[index] = 0;
        index += 1;
        @memcpy(buffer[index .. index + option.value.len], option.value);
        index += option.value.len;
        buffer[index] = 0;
        index += 1;
    }
    return buffer[0..index];
}

fn parseRequest(bytes: []const u8, option_storage: []Option) ParseError!Request {
    var cursor: usize = 0;
    const filename = try nextField(bytes, &cursor, error.InvalidRequest);
    const mode = try nextField(bytes, &cursor, error.InvalidRequest);
    if (filename.len == 0 or mode.len == 0) return error.InvalidRequest;
    return .{
        .filename = filename,
        .mode = mode,
        .options = try parseOptions(bytes[cursor..], option_storage),
    };
}

fn parseOptions(bytes: []const u8, option_storage: []Option) ParseError![]const Option {
    if (bytes.len == 0) return &.{};
    var cursor: usize = 0;
    var count: usize = 0;
    while (cursor < bytes.len) {
        if (count == option_storage.len) return error.TooManyOptions;
        const name = try nextField(bytes, &cursor, error.InvalidOption);
        const value = try nextField(bytes, &cursor, error.InvalidOption);
        if (name.len == 0 or value.len == 0) return error.InvalidOption;
        option_storage[count] = .{ .name = name, .value = value };
        count += 1;
    }
    return option_storage[0..count];
}

fn nextField(bytes: []const u8, cursor: *usize, comptime err: ParseError) ParseError![]const u8 {
    const start = cursor.*;
    const end = std.mem.indexOfScalarPos(u8, bytes, start, 0) orelse return err;
    cursor.* = end + 1;
    return bytes[start..end];
}

fn writeHeader(buffer: []u8, opcode: Opcode, value: u16) void {
    std.mem.writeInt(u16, buffer[0..2], @intFromEnum(opcode), .big);
    std.mem.writeInt(u16, buffer[2..4], value, .big);
}

test "parses RRQ options" {
    var options: [4]Option = undefined;
    const message = try parse(&.{ 0, 1, 'g', 'r', 'u', 'b', 0, 'o', 'c', 't', 'e', 't', 0, 'b', 'l', 'k', 's', 'i', 'z', 'e', 0, '1', '4', '6', '8', 0 }, &options);
    const request = message.rrq;
    try std.testing.expectEqualStrings("grub", request.filename);
    try std.testing.expectEqualStrings("octet", request.mode);
    try std.testing.expectEqual(@as(usize, 1), request.options.len);
    try std.testing.expectEqualStrings("1468", request.options[0].value);
}

test "encodes and parses DATA" {
    var buffer: [32]u8 = undefined;
    const encoded = try encodeData(&buffer, 3, "payload");
    var options: [0]Option = .{};
    const message = try parse(encoded, &options);
    try std.testing.expectEqual(@as(u16, 3), message.data.block);
    try std.testing.expectEqualStrings("payload", message.data.bytes);
}

test "rejects malformed requests" {
    var options: [2]Option = undefined;
    try std.testing.expectError(error.InvalidRequest, parse(&.{ 0, 1, 'a' }, &options));
    try std.testing.expectError(error.InvalidAck, parse(&.{ 0, 4, 0, 1, 0 }, &options));
}
