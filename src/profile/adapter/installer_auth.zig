//! Runtime acquisition of the volatile installer boot-session capability.
//!
//! Kickstart and Autoinstall documents are routinely copied into the installed
//! system by Anaconda/Subiquity. They therefore contain only the authenticated
//! boot-config endpoint and non-secret session id. The installer fetches the
//! current random capability into a 0400 `/run` file and every callback reads it
//! at execution time. Daemon restart naturally rotates the value on refresh.

const std = @import("std");

pub const token_path = "/run/nodeforge-installer.token";

pub fn bootstrapCommand(allocator: std.mem.Allocator, boot_config_url: []const u8, session_id: []const u8, destination: []const u8) ![]u8 {
    if (!safe(boot_config_url) or !std.mem.startsWith(u8, boot_config_url, "http://") or !safe(session_id) or !safe(destination) or destination.len == 0 or destination[0] != '/')
        return error.InvalidInstallerAuth;
    return std.fmt.allocPrint(
        allocator,
        "set -eu; NF_AUTH_FILE='{s}'; NF_AUTH_TMP='{s}.part'; umask 077; rm -f \"$NF_AUTH_TMP\" \"$NF_AUTH_FILE\"; trap 'rm -f \"$NF_AUTH_TMP\"' 0 HUP INT TERM; curl -fsS --max-redirs 0 '{s}' | python3 -c 'import json,sys; d=sys.stdin.buffer.read(65537); assert len(d)<=65536; p=json.loads(d)[\"access\"]; assert p[\"session_id\"]==sys.argv[1]; t=p[\"bearer_token\"]; assert len(t)==64 and all(c in \"0123456789abcdef\" for c in t); sys.stdout.write(t)' '{s}' > \"$NF_AUTH_TMP\"; test \"$(wc -c < \"$NF_AUTH_TMP\")\" -eq 64; chmod 0400 \"$NF_AUTH_TMP\"; mv -f \"$NF_AUTH_TMP\" \"$NF_AUTH_FILE\"",
        .{ destination, destination, boot_config_url, session_id },
    );
}

fn safe(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfAny(u8, value, "'\n\r\t ") == null;
}

test "bootstrap command contains endpoint and path but no bearer material" {
    const command = try bootstrapCommand(
        std.testing.allocator,
        "http://192.0.2.1:18080/api/v1/nodes/n1/boot-config",
        "0123456789abcdef0123456789abcdef",
        token_path,
    );
    defer std.testing.allocator.free(command);
    try std.testing.expect(std.mem.indexOf(u8, command, "boot-config") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, token_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "Authorization: Bearer") == null);
    try std.testing.expect(std.mem.indexOf(u8, command, "read(65537)") != null);
    try std.testing.expect(std.mem.indexOf(u8, command, "rm -f \"$NF_AUTH_TMP\" \"$NF_AUTH_FILE\"") != null);
}

test "bootstrap command is valid POSIX shell syntax" {
    const command = try bootstrapCommand(
        std.testing.allocator,
        "http://192.0.2.1:18080/api/v1/nodes/n1/boot-config",
        "0123456789abcdef0123456789abcdef",
        token_path,
    );
    defer std.testing.allocator.free(command);
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "sh", "-n", "-c", command } });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.InstallerAuthShellSyntaxFailed,
    }
}
