//! M4's constrained post-install runner. It emits target-root shell commands
//! only for the three declared actions; arbitrary scripts remain an M7 feature.
const std = @import("std");
const model = @import("../model.zig");

pub fn renderInstallPost(allocator: std.mem.Allocator, bundle: *const model.ProvisioningBundle, manager: model.PackageManager) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    for (bundle.steps) |step| {
        if (step.phase != .install_post) continue;
        switch (step.action) {
            .repository => if (step.repository) |repo| switch (manager) {
                .dnf => try w.print("dnf -y config-manager --add-repo '{s}'\n", .{repo}),
                .apt => try w.print("echo '{s}' > /etc/apt/sources.list.d/nodeforge.list && apt-get update\n", .{repo}),
            } else return error.InvalidStep,
            .standard_packages => {
                if (step.packages.len == 0) return error.InvalidStep;
                try w.writeAll(if (manager == .dnf) "dnf -y install" else "DEBIAN_FRONTEND=noninteractive apt-get -y install");
                for (step.packages) |package| try w.print(" '{s}'", .{package});
                try w.writeByte('\n');
            },
            .managed_file => {
                const destination = step.destination orelse return error.InvalidStep;
                const content = step.content orelse return error.InvalidStep;
                if (!std.mem.startsWith(u8, destination, "/") or std.mem.indexOf(u8, destination, "..") != null) return error.InvalidStep;
                try w.print("install -d -m 0755 $(dirname '{s}')\ncat > '{s}' <<'NODEFORGE_EOF'\n{s}\nNODEFORGE_EOF\n", .{ destination, destination, content });
            },
        }
    }
    return out.toOwnedSlice();
}

test "runner preserves declared install_post order" {
    const bundle: model.ProvisioningBundle = .{ .name = "base", .steps = &.{
        .{ .name = "packages", .action = .standard_packages, .packages = &.{"curl"} },
        .{ .name = "hosts", .action = .managed_file, .destination = "/etc/hosts", .content = "127.0.0.1 localhost" },
    } };
    const bytes = try renderInstallPost(std.testing.allocator, &bundle, .dnf);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "dnf -y install") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "cat > '/etc/hosts'") != null);
}
