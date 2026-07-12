const std = @import("std");
const model = @import("../../model.zig");
const render = @import("../render.zig");
const runner = @import("../../provision/runner.zig");

pub fn renderAnswer(allocator: std.mem.Allocator, node: *const model.NodeConfig, install: model.InstallConfig, repo_url: []const u8, bundle: ?*const model.ProvisioningBundle, event_url: []const u8, session: []const u8, token: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("url --url={s}\nlang en_US.UTF-8\nkeyboard us\ntimezone UTC --utc\n", .{repo_url});
    try w.print("network --bootproto=dhcp --hostname={s} --activate\n", .{render.hostname(node)});
    try w.print("zerombr\nclearpart --all --initlabel --drives={s}\n", .{install.storage.boot_disk[5..]});
    if (install.storage.partitions.len == 0) {
        if (install.storage.boot_mode == .uefi) try w.writeAll("part /boot/efi --fstype=efi --size=600\n");
        try w.writeAll("part swap --fstype=swap --size=2048\npart / --fstype=xfs --grow --size=10240\n");
    } else for (install.storage.partitions) |part| {
        const mount = part.mount orelse switch (part.kind) { .swap => "swap", .esp => "/boot/efi", .biosboot => "biosboot", else => return error.InvalidPartition };
        const fs = part.filesystem orelse switch (part.kind) { .esp => "efi", .swap => "swap", .biosboot => "biosboot", else => "xfs" };
        try w.print("part {s} --fstype={s} --size={d}\n", .{ mount, fs, part.size_mib });
    }
    if (install.bootloader.install) try w.print("bootloader --location=none --boot-drive={s}\n", .{install.storage.boot_disk});
    for (install.users) |user| {
        try w.print("user --name={s}", .{user.name});
        // Anaconda accepts a plain value when --iscrypted is absent; the
        // configuration model intentionally keeps the operator input plain.
        if (user.password) |password| try w.print(" --password={s}", .{password});
        if (user.sudo) try w.writeAll(" --groups=wheel");
        try w.writeByte('\n');
    }
    try w.writeAll("%packages\n@^minimal-environment\n");
    for (install.packages) |package| try w.print("{s}\n", .{package});
    try w.writeAll("%end\n%post --erroronfail\n");
    if (bundle) |value| {
        const script = try runner.renderInstallPost(allocator, value, .dnf);
        defer allocator.free(script);
        try w.writeAll(script);
    }
    try w.print("curl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"post\"}}' {s} || true\n", .{ token, session, session, event_url });
    try w.writeAll("%end\nreboot\n");
    return out.toOwnedSlice();
}

test "kickstart renders UEFI defaults and installer event hook" {
    const node: model.NodeConfig = .{ .id = "node-01", .mac = "00:11:22:33:44:55", .arch = .aarch64, .profile = "rocky" };
    const bytes = try renderAnswer(std.testing.allocator, &node, .{ .users = &.{.{ .name = "admin", .password = "asdf1234" }} }, "http://repo", null, "http://event", "0123456789abcdef0123456789abcdef", "token");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "part /boot/efi") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "curl -fsS") != null);
}
