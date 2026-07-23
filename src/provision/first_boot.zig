//! # v0.2 diskless first-boot provision executor (Phase 8)
//!
//! 切根+systemd 后由 `nodeforge-agent`（无参数，作为 systemd unit）调用。读取
//! pre-init 持久化的 AgentPlan（`/var/lib/nodeforge/agent-plan.json`），按八步执行
//! 契约的固定顺序 managed_file -> package -> archive -> script 应用 first-boot 步骤
//! 到 overlay 根。一次性、无远程控制、无 reconciliation；失败只记日志、不阻断启动。
//!
//! 步骤内容当前为内联（AgentPlan 携带）；content-addressed 大 blob 下发管线为后续。
//! 渲染复用 `provision/runner.zig` 的安全不变量：目标路径必须绝对且不含 `..`，
//! 文件字节以 POSIX `printf %b` 八进制转义避免 shell 展开/注入。

const std = @import("std");
const dto = @import("../http/diskless_dto.zig");

const log_path = "/var/lib/nodeforge/firstboot.log";

/// 读取持久化 AgentPlan JSON 并按八步顺序应用其 first-boot 步骤。
/// 返回失败步骤数（best-effort：失败不抛错、不阻断启动，详见日志）。
pub fn runFromPlanJson(io: std.Io, allocator: std.mem.Allocator, json: []const u8) usize {
    const P = struct { steps: []const dto.FirstBootStep = &.{} };
    const parsed = std.json.parseFromSlice(P, allocator, json, .{ .ignore_unknown_fields = true }) catch return 0;
    defer parsed.deinit();
    return applySteps(io, allocator, parsed.value.steps);
}

/// 按固定顺序（managed_file -> package -> archive -> script）应用步骤。
pub fn applySteps(io: std.Io, allocator: std.mem.Allocator, steps: []const dto.FirstBootStep) usize {
    var log: std.Io.Writer.Allocating = .init(allocator);
    defer log.deinit();
    var failures: usize = 0;
    const order = [_]dto.FirstBootAction{ .managed_file, .@"package", .archive, .script };
    for (order) |act| {
        for (steps) |step| {
            if (step.action != act) continue;
            log.writer.print("[first-boot] step '{s}' ({s})\n", .{ step.id, @tagName(step.action) }) catch {};
            var cmd: std.Io.Writer.Allocating = .init(allocator);
            defer cmd.deinit();
            renderStep(&cmd.writer, step) catch |err| {
                failures += 1;
                log.writer.print("  render error: {s}\n", .{@errorName(err)}) catch {};
                continue;
            };
            runSh(io, allocator, cmd.written()) catch |err| {
                failures += 1;
                log.writer.print("  FAILED: {s}\n  cmd: {s}\n", .{ @errorName(err), cmd.written() }) catch {};
                continue;
            };
            log.writer.print("  ok\n", .{}) catch {};
        }
    }
    log.writer.print("[first-boot] done: {d} failure(s)\n", .{failures}) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = log_path, .data = log.written() }) catch {};
    return failures;
}

/// 渲染单个步骤为一条 `/bin/sh -c` 命令字符串。
fn renderStep(w: *std.Io.Writer, step: dto.FirstBootStep) !void {
    switch (step.action) {
        .managed_file => {
            const dest = step.destination orelse return error.MissingDestination;
            try safeDest(dest);
            try w.writeAll("printf '%b' '");
            try writeBytes(w, step.content orelse "");
            try w.writeAll("' > ");
            try writeQuoted(w, dest);
            try w.print(" && chmod {o:0>3} ", .{step.mode});
            try writeQuoted(w, dest);
            try w.writeAll(" && chown ");
            try writeQuoted(w, step.owner);
            try w.writeByte(':');
            try writeQuoted(w, step.group);
            try w.writeByte(' ');
            try writeQuoted(w, dest);
        },
        .@"package" => {
            if (step.packages.len == 0) return error.NoPackages;
            try w.writeAll("dnf -y install");
            for (step.packages) |pkg| {
                try w.writeByte(' ');
                try writeQuoted(w, pkg);
            }
        },
        .archive => {
            const dest = step.destination orelse "/";
            try safeDest(dest);
            try w.writeAll("printf '%b' '");
            try writeBytes(w, step.content orelse "");
            try w.writeAll("' > /tmp/.nodeforge-arc && mkdir -p ");
            try writeQuoted(w, dest);
            try w.writeAll(" && tar -xf /tmp/.nodeforge-arc -C ");
            try writeQuoted(w, dest);
            try w.writeAll(" ; rm -f /tmp/.nodeforge-arc");
        },
        .script => {
            try w.writeAll("printf '%b' '");
            try writeBytes(w, step.content orelse "");
            try w.writeAll("' > /tmp/.nodeforge-script && sh /tmp/.nodeforge-script ; rm -f /tmp/.nodeforge-script");
        },
    }
}

fn safeDest(dest: []const u8) !void {
    if (dest.len == 0 or dest[0] != '/') return error.InvalidDestination;
    if (std.mem.indexOf(u8, dest, "..") != null) return error.InvalidDestination;
}

fn writeQuoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |c| if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    try w.writeByte('\'');
}

fn writeBytes(w: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |b| try w.print("\\{o:0>3}", .{b});
}

fn runSh(io: std.Io, allocator: std.mem.Allocator, cmd: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "/bin/sh", "-c", cmd } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
}

test "renderStep managed_file emits safe printf/chmod/chown" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderStep(&out.writer, .{ .id = "motd", .action = .managed_file, .content = "hi\n", .destination = "/etc/motd", .mode = 0o644 });
    const s = out.written();
    try std.testing.expect(std.mem.indexOf(u8, s, "printf '%b' '") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\\012") != null); // \n -> \012
    try std.testing.expect(std.mem.indexOf(u8, s, "chmod 644") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "chown 'root':'root' '/etc/motd'") != null);
}

test "renderStep rejects path traversal and relative paths" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidDestination, renderStep(&out.writer, .{ .id = "x", .action = .managed_file, .content = "y", .destination = "/etc/../etc/passwd" }));
    try std.testing.expectError(error.InvalidDestination, renderStep(&out.writer, .{ .id = "x", .action = .managed_file, .content = "y", .destination = "relative/path" }));
}

test "renderStep package emits dnf install and rejects empty list" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderStep(&out.writer, .{ .id = "pkgs", .action = .@"package", .packages = &.{ "tmux", "vim" } });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "dnf -y install 'tmux' 'vim'") != null);
    try std.testing.expectError(error.NoPackages, renderStep(&out.writer, .{ .id = "p", .action = .@"package" }));
}

test "renderStep archive and script render extraction/execution" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderStep(&out.writer, .{ .id = "a", .action = .archive, .content = "x", .destination = "/opt/app" });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tar -xf /tmp/.nodeforge-arc -C '/opt/app'") != null);
    out.deinit();
    out = .init(std.testing.allocator);
    try renderStep(&out.writer, .{ .id = "s", .action = .script, .content = "echo hi\n" });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "sh /tmp/.nodeforge-script") != null);
}
