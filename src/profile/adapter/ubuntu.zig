const std = @import("std");
const model = @import("../../model.zig");
const render = @import("../render.zig");
const runner = @import("../../provision/runner.zig");

pub fn renderUserData(allocator: std.mem.Allocator, node: *const model.NodeConfig, install: model.InstallConfig, bundle: ?*const model.ProvisioningBundle, event_url: []const u8, session: []const u8, token: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("#cloud-config\nautoinstall:\n  version: 1\n  identity:\n    hostname: ");
    try render.yamlQuote(w, render.hostname(node));
    if (install.users.len != 0) {
        const user = install.users[0]; var digest: [64]u8 = undefined;
        try w.writeAll("\n    username: "); try render.yamlQuote(w, user.name);
        try w.writeAll("\n    password: "); try render.yamlQuote(w, if (user.password) |p| render.passwordDigest(&digest, p) else "!");
    }
    try w.writeAll("\n  ssh:\n    install-server: true\n    allow-pw: true\n  packages:\n");
    for (install.packages) |package| { try w.writeAll("    - "); try render.yamlQuote(w, package); try w.writeByte('\n'); }
    try w.writeAll("  storage:\n    layout:\n      name: direct\n  late-commands:\n");
    if (bundle) |value| {
        const script = try runner.renderInstallPost(allocator, value, .apt);
        defer allocator.free(script);
        try w.writeAll("    - curtin in-target --target=/target -- sh -c '");
        for (script) |c| if (c == '\'') try w.writeAll("'\\''") else if (c == '\n') try w.writeAll("; ") else try w.writeByte(c);
        try w.writeAll("'\n");
    }
    try w.print("    - curtin in-target --target=/target -- sh -c \"curl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\\\"v\\\":1,\\\"boot_session_id\\\":\\\"{s}\\\",\\\"stage\\\":\\\"post\\\"}}' {s} || true\"\n", .{ token, session, session, event_url });
    return out.toOwnedSlice();
}

pub fn renderMetaData(allocator: std.mem.Allocator, node: *const model.NodeConfig) ![]u8 {
    return std.fmt.allocPrint(allocator, "instance-id: nodeforge-{s}\nlocal-hostname: {s}\n", .{ node.id, render.hostname(node) });
}

test "autoinstall has NoCloud header and late event hook" {
    const node: model.NodeConfig = .{ .id = "node-01", .mac = "00:11:22:33:44:55", .arch = .aarch64, .profile = "ubuntu" };
    const bytes = try renderUserData(std.testing.allocator, &node, .{ .packages = &.{"curl"} }, null, "http://event", "0123456789abcdef0123456789abcdef", "token");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "#cloud-config") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "autoinstall:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "late-commands") != null);
}
