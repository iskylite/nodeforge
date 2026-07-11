//! DHCPv4/BOOTP packet codec for M2.  It is deliberately allocation-free: all
//! option slices borrow the received datagram and unknown options are skipped.
const std = @import("std");

pub const server_port: u16 = 67;
pub const client_port: u16 = 68;
pub const magic_cookie = [_]u8{ 99, 130, 83, 99 };
pub const MessageType = enum(u8) { discover = 1, offer = 2, request = 3, decline = 4, ack = 5, nak = 6, release = 7, inform = 8 };
pub const Architecture = enum(u16) { x86_64 = 7, aarch64 = 11, unknown = 0 };

pub const Packet = struct {
    op: u8,
    xid: u32,
    flags: u16,
    ciaddr: u32,
    yiaddr: u32,
    siaddr: u32,
    giaddr: u32,
    chaddr: [16]u8,
    hlen: u8,
    message_type: ?MessageType = null,
    requested_ip: ?u32 = null,
    server_identifier: ?u32 = null,
    vendor_class: ?[]const u8 = null,
    client_identifier: ?[]const u8 = null,
    architecture: Architecture = .unknown,
    client_uuid: ?[]const u8 = null,
    link_selection: ?u32 = null,
    pub fn mac(self: *const Packet) []const u8 {
        return self.chaddr[0..@min(self.hlen, 16)];
    }
};

pub const ParseError = error{ PacketTooShort, InvalidHardwareAddress, InvalidCookie, InvalidOption, MissingEnd };

pub fn parse(bytes: []const u8) ParseError!Packet {
    if (bytes.len < 240) return error.PacketTooShort;
    if (bytes[1] != 1 or bytes[2] < 6) return error.InvalidHardwareAddress;
    if (!std.mem.eql(u8, bytes[236..240], &magic_cookie)) return error.InvalidCookie;
    var p: Packet = .{ .op = bytes[0], .hlen = bytes[2], .xid = std.mem.readInt(u32, bytes[4..8], .big), .flags = std.mem.readInt(u16, bytes[10..12], .big), .ciaddr = readIp(bytes[12..16]), .yiaddr = readIp(bytes[16..20]), .siaddr = readIp(bytes[20..24]), .giaddr = readIp(bytes[24..28]), .chaddr = [_]u8{0} ** 16 };
    @memcpy(&p.chaddr, bytes[28..44]);
    var i: usize = 240;
    var saw_end = false;
    while (i < bytes.len) {
        const code = bytes[i];
        i += 1;
        if (code == 0) continue;
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
                if (len != 1) return error.InvalidOption;
                p.message_type = messageType(value[0]);
            },
            50 => {
                if (len != 4) return error.InvalidOption;
                p.requested_ip = readIp(value);
            },
            54 => {
                if (len != 4) return error.InvalidOption;
                p.server_identifier = readIp(value);
            },
            60 => p.vendor_class = value,
            61 => p.client_identifier = value,
            93 => {
                if (len < 2) return error.InvalidOption;
                p.architecture = architecture(std.mem.readInt(u16, value[0..2], .big));
            },
            97 => p.client_uuid = value,
            82 => p.link_selection = parseRelay(value),
            else => {},
        }
    }
    if (!saw_end) return error.MissingEnd;
    return p;
}
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
fn architecture(value: u16) Architecture {
    return switch (value) {
        7 => .x86_64,
        11 => .aarch64,
        else => .unknown,
    };
}

pub const Reply = struct { kind: MessageType, yiaddr: u32 = 0, server_ip: u32, subnet_mask: u32, router: ?u32 = null, dns: []const u32 = &.{}, lease_seconds: u32, bootfile: ?[]const u8 = null };

pub fn encodeReply(buffer: []u8, request: *const Packet, reply: Reply) ![]const u8 {
    if (buffer.len < 300) return error.BufferTooSmall;
    @memset(buffer, 0);
    buffer[0] = 2;
    buffer[1] = 1;
    buffer[2] = request.hlen;
    std.mem.writeInt(u32, buffer[4..8], request.xid, .big);
    std.mem.writeInt(u16, buffer[10..12], request.flags, .big);
    writeIp(buffer[16..20], reply.yiaddr);
    writeIp(buffer[20..24], reply.server_ip);
    writeIp(buffer[24..28], request.giaddr);
    @memcpy(buffer[28..44], &request.chaddr);
    @memcpy(buffer[236..240], &magic_cookie);
    var i: usize = 240;
    try put(&i, buffer, 53, &.{@intFromEnum(reply.kind)});
    var ip: [4]u8 = undefined;
    writeIp(&ip, reply.subnet_mask);
    try put(&i, buffer, 1, &ip);
    if (reply.router) |router| {
        writeIp(&ip, router);
        try put(&i, buffer, 3, &ip);
    }
    if (reply.dns.len != 0) {
        if (reply.dns.len > 8) return error.BufferTooSmall;
        var values: [32]u8 = undefined;
        for (reply.dns, 0..) |dns, n| writeIp(values[n * 4 ..][0..4], dns);
        try put(&i, buffer, 6, values[0 .. reply.dns.len * 4]);
    }
    var seconds: [4]u8 = undefined;
    std.mem.writeInt(u32, &seconds, reply.lease_seconds, .big);
    try put(&i, buffer, 51, &seconds);
    writeIp(&ip, reply.server_ip);
    try put(&i, buffer, 54, &ip);
    if (reply.bootfile) |bootfile| {
        if (bootfile.len > 128) return error.BufferTooSmall;
        try put(&i, buffer, 67, bootfile);
    }
    if (i == buffer.len) return error.BufferTooSmall;
    buffer[i] = 255;
    return buffer[0 .. i + 1];
}
fn put(i: *usize, buffer: []u8, code: u8, value: []const u8) !void {
    if (value.len > 255 or buffer.len - i.* < value.len + 2) return error.BufferTooSmall;
    buffer[i.*] = code;
    buffer[i.* + 1] = @intCast(value.len);
    @memcpy(buffer[i.* + 2 .. i.* + 2 + value.len], value);
    i.* += value.len + 2;
}
fn parseRelay(value: []const u8) ?u32 {
    var i: usize = 0;
    while (i + 2 <= value.len) {
        const code = value[i];
        const len: usize = value[i + 1];
        i += 2;
        if (value.len - i < len) return null;
        if (code == 5 and len == 4) return readIp(value[i..][0..4]);
        i += len;
    }
    return null;
}
pub fn readIp(v: []const u8) u32 {
    return std.mem.readInt(u32, v[0..4], .big);
}
pub fn writeIp(v: []u8, ip: u32) void {
    std.mem.writeInt(u32, v[0..4], ip, .big);
}

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
