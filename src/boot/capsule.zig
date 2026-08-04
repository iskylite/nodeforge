//! Memory-only per-boot credential capsule, encoded as an uncompressed `newc`
//! archive that GRUB loads after the base initrd.

const std = @import("std");

/// PR3-1（token 简化）：diskless capsule 只携带 session id + event:append token。
/// config/rootfs/agent 三个读取作用域 token 已删除 —— initrd 通过 peer-IP 引导
/// 认证（boot_session.Store）获取 BootConfig/rootfs/payload；BootConfig 另签发
/// 仅供 AgentPlan 的短时 capability。仅 event:append token 保留（diskless 有界切网后 lease-IP
/// 身份可能变化，无法用 peer-IP 认证，但仍需推进生命周期 CAS）。
pub const Values = struct {
    session: []const u8,
    event_token: []const u8,
};

pub fn render(allocator: std.mem.Allocator, values: Values) ![]u8 {
    try validateHex(values.session, 32);
    try validateHex(values.event_token, 64);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var ino: u32 = 1;
    try appendEntry(&out.writer, ino, 0o100400, "capsule/session", values.session);
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
        .event_token = "5" ** 64,
    });
    defer std.testing.allocator.free(archive);
    try std.testing.expect(std.mem.startsWith(u8, archive, "070701"));
    try std.testing.expect(std.mem.indexOf(u8, archive, "capsule/session") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "capsule/event.token") != null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "TRAILER!!!") != null);
    // PR3-1: 不再包含 config/rootfs/agent token 文件。
    try std.testing.expect(std.mem.indexOf(u8, archive, "config.token") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "rootfs.token") == null);
    try std.testing.expect(std.mem.indexOf(u8, archive, "agent.token") == null);
}
