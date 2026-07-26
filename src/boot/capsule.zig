//! Memory-only per-boot credential capsule, encoded as an uncompressed `newc`
//! archive that GRUB loads after the base initrd.

const std = @import("std");

pub const Values = struct {
    session: []const u8,
    config_token: []const u8,
    rootfs_token: []const u8,
    agent_token: []const u8,
    event_token: []const u8,
};

pub fn render(allocator: std.mem.Allocator, values: Values) ![]u8 {
    try validateHex(values.session, 32);
    try validateHex(values.config_token, 64);
    try validateHex(values.rootfs_token, 64);
    try validateHex(values.agent_token, 64);
    try validateHex(values.event_token, 64);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var ino: u32 = 1;
    try appendEntry(&out.writer, ino, 0o100400, "capsule/session", values.session);
    ino += 1;
    try appendEntry(&out.writer, ino, 0o100400, "capsule/config.token", values.config_token);
    ino += 1;
    try appendEntry(&out.writer, ino, 0o100400, "capsule/rootfs.token", values.rootfs_token);
    ino += 1;
    try appendEntry(&out.writer, ino, 0o100400, "capsule/agent.token", values.agent_token);
    ino += 1;
    try appendEntry(&out.writer, ino, 0o100400, "capsule/event.token", values.event_token);
    try appendEntry(&out.writer, ino + 1, 0, "TRAILER!!!", "");
    return out.toOwnedSlice();
}

fn validateHex(value: []const u8, expected: usize) !void {
    if (value.len != expected) return error.InvalidCapsuleValue;
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.InvalidCapsuleValue;
}

fn appendEntry(writer: *std.Io.Writer, ino: u32, mode: u32, name: []const u8, data: []const u8) !void {
    const name_size = name.len + 1;
    try writer.print(
        "070701{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}",
        .{ ino, mode, 0, 0, 1, 0, data.len, 0, 0, 0, 0, name_size, 0 },
    );
    try writer.writeAll(name);
    try writer.writeByte(0);
    try pad4(writer, 110 + name_size);
    try writer.writeAll(data);
    try pad4(writer, data.len);
}

fn pad4(writer: *std.Io.Writer, length: usize) !void {
    try writer.splatByteAll(0, (4 - (length % 4)) % 4);
}

test "renders a memory-only newc capsule" {
    const archive = try render(std.testing.allocator, .{
        .session = "1" ** 32,
        .config_token = "2" ** 64,
        .rootfs_token = "3" ** 64,
        .agent_token = "4" ** 64,
        .event_token = "5" ** 64,
    });
    defer std.testing.allocator.free(archive);
    try std.testing.expect(std.mem.startsWith(u8, archive, "070701"));
    try std.testing.expect(std.mem.indexOf(u8, archive, "capsule/session") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "TRAILER!!!") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "config_url") == null);
}
