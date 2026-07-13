//! M2 DHCPv4/BOOTP 报文编解码器。
//!
//! 本模块是零分配的：所有 option slice 借用接收到的 datagram 缓冲区，
//! 未知 option 被安全跳过。调用方必须在复用缓冲区前处理完解析结果。
//!
//! 协议参考：
//! - RFC 2131: Dynamic Host Configuration Protocol — DHCP 核心协议
//! - RFC 2132: DHCP Options and BOOTP Vendor Extensions — option 定义
//! - RFC 4578: DHCP Options for PXE — option 93/94/97 定义客户端架构
//! - RFC 3527: DHCP Relay Agent Information — option 82 link-selection 子选项
//!
//! 字节序：所有多字节字段均为大端序（网络字节序）。

const std = @import("std");

/// DHCPv4 服务端监听端口（RFC 2131 Section 4.1）。
pub const server_port: u16 = 67;
/// DHCPv4 客户端监听端口（RFC 2131 Section 4.1）。
pub const client_port: u16 = 68;
/// BOOTP/DHCP magic cookie，标识 options 区域的开始（RFC 2131 Section 2）。
pub const magic_cookie = [_]u8{ 99, 130, 83, 99 };

/// DHCP 消息类型（RFC 2132 Section 9.6, option 53）。
pub const MessageType = enum(u8) {
    discover = 1,
    offer = 2,
    request = 3,
    decline = 4,
    ack = 5,
    nak = 6,
    release = 7,
    inform = 8,
};

/// RFC 4578 option 93 定义的 PXE 客户端架构类型。
/// NodeForge 使用此值确定下发哪种 GRUB EFI 二进制（x86_64 或 aarch64）。
/// `unknown` 表示无法识别的架构，此时不下发 bootfile。
pub const Architecture = enum(u16) {
    x86_64 = 7,
    aarch64 = 11,
    unknown = 0,
};

/// 解析后的 DHCPv4 报文。所有 option slice 借用原始 datagram 缓冲区。
pub const Packet = struct {
    /// BOOTP op 字段；1 = BOOTREQUEST，2 = BOOTREPLY。
    op: u8,
    /// 事务 ID（RFC 2131 Section 4.1），用于匹配请求和响应。
    xid: u32,
    /// BOOTP flags（RFC 2131 Section 2.1）；bit 0 = broadcast 标志。
    flags: u16,
    /// 客户端 IP 地址（ciaddr）；客户端已有地址时填入。
    ciaddr: u32,
    /// "你的" IP 地址（yiaddr）；服务端分配给客户端的地址。
    yiaddr: u32,
    /// 服务端 IP 地址（siaddr）；DHCP next-server，用于 TFTP 引导。
    siaddr: u32,
    /// 中继代理 IP 地址（giaddr）；非零表示通过中继转发。
    giaddr: u32,
    /// 客户端硬件地址（chaddr）；前 6 字节为 MAC 地址。
    chaddr: [16]u8,
    /// 硬件地址长度（hlen）；以太网为 6。
    hlen: u8,
    /// DHCP 消息类型（option 53）；null 表示未包含或无法识别。
    message_type: ?MessageType = null,
    /// 客户端请求的 IP 地址（option 50）；用于 REQUEST 续约。
    requested_ip: ?u32 = null,
    /// 服务端标识符（option 54）；客户端用它确认要向哪个服务端 REQUEST。
    server_identifier: ?u32 = null,
    /// 厂商类别标识（option 60）；例如 "PXEClient"。
    vendor_class: ?[]const u8 = null,
    /// 客户端标识符（option 61）；某些客户端用此替代 MAC 作为唯一标识。
    client_identifier: ?[]const u8 = null,
    /// 客户端 PXE 架构（option 93, RFC 4578）；决定下发哪种 GRUB 二进制。
    architecture: Architecture = .unknown,
    /// 客户端 UUID（option 97, RFC 4578）；PXE 客户端的唯一标识。
    client_uuid: ?[]const u8 = null,
    /// RFC 3527 link-selection 子选项（option 82 sub-option 5）；
    /// 中继代理用它指定地址分配的子网，覆盖 giaddr 的子网语义。
    link_selection: ?u32 = null,

    /// 返回客户端 MAC 地址切片（前 hlen 字节，最多 16 字节）。
    pub fn mac(self: *const Packet) []const u8 {
        return self.chaddr[0..@min(self.hlen, 16)];
    }
};

/// 报文解析错误。
pub const ParseError = error{
    PacketTooShort,
    InvalidHardwareAddress,
    InvalidCookie,
    InvalidOption,
    MissingEnd,
};

/// 解析 DHCPv4 datagram。零分配：返回的 Packet 中所有 slice 借用 `bytes`。
///
/// 最小报文长度 240 字节（236 字节 BOOTP 头 + 4 字节 magic cookie）。
/// option 255（End）必须存在；option 0（Pad）被跳过。
pub fn parse(bytes: []const u8) ParseError!Packet {
    if (bytes.len < 240) return error.PacketTooShort;
    // htype 必须为 1（以太网），hlen 必须 >= 6
    if (bytes[1] != 1 or bytes[2] < 6) return error.InvalidHardwareAddress;
    if (!std.mem.eql(u8, bytes[236..240], &magic_cookie)) return error.InvalidCookie;
    var p: Packet = .{ .op = bytes[0], .hlen = bytes[2], .xid = std.mem.readInt(u32, bytes[4..8], .big), .flags = std.mem.readInt(u16, bytes[10..12], .big), .ciaddr = readIp(bytes[12..16]), .yiaddr = readIp(bytes[16..20]), .siaddr = readIp(bytes[20..24]), .giaddr = readIp(bytes[24..28]), .chaddr = [_]u8{0} ** 16 };
    @memcpy(&p.chaddr, bytes[28..44]);
    var i: usize = 240;
    var saw_end = false;
    while (i < bytes.len) {
        const code = bytes[i];
        i += 1;
        // Pad option（code 0）：1 字节，跳过
        if (code == 0) continue;
        // End option（code 255）：1 字节，标记 options 结束
        if (code == 255) {
            saw_end = true;
            break;
        }
        if (i >= bytes.len) return error.InvalidOption;
        const len: usize = bytes[i];
        i += 1;
        if (bytes.len - i < len) return error.InvalidOption;
        const value = bytes[i .. i + len];
        i += len;
        switch (code) {
            53 => {
                // DHCP Message Type（option 53）：1 字节
                if (len != 1) return error.InvalidOption;
                p.message_type = messageType(value[0]);
            },
            50 => {
                // Requested IP Address（option 50）：4 字节
                if (len != 4) return error.InvalidOption;
                p.requested_ip = readIp(value);
            },
            54 => {
                // Server Identifier（option 54）：4 字节
                if (len != 4) return error.InvalidOption;
                p.server_identifier = readIp(value);
            },
            60 => p.vendor_class = value, // Vendor Class Identifier
            61 => p.client_identifier = value, // Client Identifier
            93 => {
                // Client System Architecture Type（option 93, RFC 4578）：2 字节
                if (len < 2) return error.InvalidOption;
                p.architecture = architecture(std.mem.readInt(u16, value[0..2], .big));
            },
            97 => p.client_uuid = value, // Client UUID (option 97, RFC 4578)
            82 => p.link_selection = parseRelay(value), // Relay Agent Information
            else => {},
        }
    }
    if (!saw_end) return error.MissingEnd;
    return p;
}

/// 将数字转换为 MessageType 枚举；无法识别的值返回 null。
fn messageType(value: u8) ?MessageType {
    return switch (value) {
        1 => .discover,
        2 => .offer,
        3 => .request,
        4 => .decline,
        5 => .ack,
        6 => .nak,
        7 => .release,
        8 => .inform,
        else => null,
    };
}

/// 将 option 93 的值转换为 Architecture 枚举。
/// 参考 RFC 4578：7 = x86_64 UEFI，11 = aarch64 UEFI。
fn architecture(value: u16) Architecture {
    return switch (value) {
        7 => .x86_64,
        11 => .aarch64,
        else => .unknown,
    };
}

/// DHCPv4 服务端响应。由 `process` 生成，`encodeReply` 编码为 UDP datagram。
pub const Reply = struct {
    /// 响应消息类型（OFFER 或 ACK 或 NAK）。
    kind: MessageType,
    /// 分配给客户端的 IP 地址（yiaddr）。
    yiaddr: u32 = 0,
    /// 服务端 IP 地址（siaddr）。
    server_ip: u32,
    /// 子网掩码（option 1）。
    subnet_mask: u32,
    /// 默认网关（option 3）；null 表示不下发。
    router: ?u32 = null,
    /// DNS 服务器列表（option 6）；最多 8 个。
    dns: []const u32 = &.{},
    /// 租约时长（option 51），秒。
    lease_seconds: u32,
    /// PXE bootfile 路径（option 67/sname）；null 表示不下发。
    bootfile: ?[]const u8 = null,
};

/// 将 DHCP 响应编码为 UDP datagram。
///
/// `buffer` 由调用方提供，需至少 300 字节。返回的有效切片借用 `buffer`。
/// 编码的 options 包括：消息类型、子网掩码、网关、DNS、租约时长、服务端标识符和 bootfile。
pub fn encodeReply(buffer: []u8, request: *const Packet, reply: Reply) ![]const u8 {
    if (buffer.len < 300) return error.BufferTooSmall;
    @memset(buffer, 0);
    // BOOTP 头：op=2（BOOTREPLY），htype=1（以太网），hlen 从请求中复制
    buffer[0] = 2;
    buffer[1] = 1;
    buffer[2] = request.hlen;
    // 复制 xid 以匹配请求
    std.mem.writeInt(u32, buffer[4..8], request.xid, .big);
    // 复制 flags（保留 broadcast 标志）
    std.mem.writeInt(u16, buffer[10..12], request.flags, .big);
    // yiaddr：分配给客户端的地址
    writeIp(buffer[16..20], reply.yiaddr);
    // siaddr：服务端 IP（next-server）
    writeIp(buffer[20..24], reply.server_ip);
    // giaddr：原样回传中继代理地址
    writeIp(buffer[24..28], request.giaddr);
    // chaddr：复制客户端硬件地址
    @memcpy(buffer[28..44], &request.chaddr);
    // magic cookie
    @memcpy(buffer[236..240], &magic_cookie);
    var i: usize = 240;
    // option 53: DHCP Message Type
    try put(&i, buffer, 53, &.{@intFromEnum(reply.kind)});
    var ip: [4]u8 = undefined;
    // option 1: Subnet Mask
    writeIp(&ip, reply.subnet_mask);
    try put(&i, buffer, 1, &ip);
    // option 3: Router (可选)
    if (reply.router) |router| {
        writeIp(&ip, router);
        try put(&i, buffer, 3, &ip);
    }
    // option 6: DNS Servers (可选，最多 8 个)
    if (reply.dns.len != 0) {
        if (reply.dns.len > 8) return error.BufferTooSmall;
        var values: [32]u8 = undefined;
        for (reply.dns, 0..) |dns, n| writeIp(values[n * 4 ..][0..4], dns);
        try put(&i, buffer, 6, values[0 .. reply.dns.len * 4]);
    }
    // option 51: IP Address Lease Time
    var seconds: [4]u8 = undefined;
    std.mem.writeInt(u32, &seconds, reply.lease_seconds, .big);
    try put(&i, buffer, 51, &seconds);
    // option 54: Server Identifier
    writeIp(&ip, reply.server_ip);
    try put(&i, buffer, 54, &ip);
    // option 67: Bootfile Name (可选)
    if (reply.bootfile) |bootfile| {
        if (bootfile.len > 128) return error.BufferTooSmall;
        try put(&i, buffer, 67, bootfile);
    }
    // option 255: End
    if (i == buffer.len) return error.BufferTooSmall;
    buffer[i] = 255;
    return buffer[0 .. i + 1];
}

/// 向 buffer 写入一个 DHCP option（code + len + value）。
fn put(i: *usize, buffer: []u8, code: u8, value: []const u8) !void {
    if (value.len > 255 or buffer.len - i.* < value.len + 2) return error.BufferTooSmall;
    buffer[i.*] = code;
    buffer[i.* + 1] = @intCast(value.len);
    @memcpy(buffer[i.* + 2 .. i.* + 2 + value.len], value);
    i.* += value.len + 2;
}

/// 解析 option 82（Relay Agent Information）中的 link-selection 子选项（sub-option 5）。
/// 返回 32 位 IPv4 地址；如果不存在或格式无效则返回 null。
fn parseRelay(value: []const u8) ?u32 {
    var i: usize = 0;
    while (i + 2 <= value.len) {
        const code = value[i];
        const len: usize = value[i + 1];
        i += 2;
        if (value.len - i < len) return null;
        // sub-option 5 = link-selection（RFC 3527）
        if (code == 5 and len == 4) return readIp(value[i..][0..4]);
        i += len;
    }
    return null;
}

/// 从 4 字节大端序缓冲区读取 IPv4 地址。
pub fn readIp(v: []const u8) u32 {
    return std.mem.readInt(u32, v[0..4], .big);
}

/// 将 IPv4 地址写入 4 字节大端序缓冲区。
pub fn writeIp(v: []u8, ip: u32) void {
    std.mem.writeInt(u32, v[0..4], ip, .big);
}

// 测试：验证 PXE DHCP 报文的解码和编码往返。
test "decode and encode PXE DHCP" {
    var in: [300]u8 = [_]u8{0} ** 300;
    in[0] = 1;
    in[1] = 1;
    in[2] = 6;
    std.mem.writeInt(u32, in[4..8], 9, .big);
    @memcpy(in[236..240], &magic_cookie);
    in[240] = 53;
    in[241] = 1;
    in[242] = 1;
    in[243] = 93;
    in[244] = 2;
    std.mem.writeInt(u16, in[245..247], 11, .big);
    in[247] = 255;
    const p = try parse(in[0..248]);
    try std.testing.expectEqual(Architecture.aarch64, p.architecture);
    var out: [512]u8 = undefined;
    const encoded = try encodeReply(&out, &p, .{ .kind = .offer, .yiaddr = 0xc0a83264, .server_ip = 0xc0a83201, .subnet_mask = 0xffffff00, .lease_seconds = 1800, .bootfile = "grubaa64.efi" });
    const decoded = try parse(encoded);
    try std.testing.expectEqual(MessageType.offer, decoded.message_type.?);
}

// 测试：验证客户端身份和 RFC 3527 link-selection option 的解析。
test "parses client identity and RFC 3527 link selection options" {
    var input: [340]u8 = [_]u8{0} ** 340;
    input[0] = 1;
    input[1] = 1;
    input[2] = 6;
    @memcpy(input[236..240], &magic_cookie);
    var i: usize = 240;
    try put(&i, &input, 53, &.{1});
    try put(&i, &input, 60, "PXEClient");
    try put(&i, &input, 61, &.{ 1, 2, 3, 4, 5, 6, 7 });
    try put(&i, &input, 93, &.{ 0, 7 });
    try put(&i, &input, 97, &.{ 0, 0xaa, 0xbb, 0xcc });
    try put(&i, &input, 82, &.{ 5, 4, 192, 168, 50, 0 });
    input[i] = 255;
    i += 1;
    const parsed = try parse(input[0..i]);
    try std.testing.expectEqualStrings("PXEClient", parsed.vendor_class.?);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7 }, parsed.client_identifier.?);
    try std.testing.expectEqual(Architecture.x86_64, parsed.architecture);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xaa, 0xbb, 0xcc }, parsed.client_uuid.?);
    try std.testing.expectEqual(@as(?u32, 0xc0a83200), parsed.link_selection);
}
