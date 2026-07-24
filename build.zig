const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zli = b.dependency("zli", .{});
    const zap = b.dependency("zap", .{ .target = target, .optimize = optimize });
    const build_options = b.addOptions();
    const git_commit = b.option([]const u8, "git-commit", "Git commit recorded in version output") orelse commandOutput(b, &.{ "git", "rev-parse", "HEAD" }) orelse "unknown";
    const build_time = b.option([]const u8, "build-time", "UTC build time recorded in version output") orelse commandOutput(b, &.{ "sh", "-c", "if [ -n \"${SOURCE_DATE_EPOCH:-}\" ]; then date -u -r \"$SOURCE_DATE_EPOCH\" '+%Y-%m-%dT%H:%M:%SZ'; else date -u '+%Y-%m-%dT%H:%M:%SZ'; fi" }) orelse "unknown";
    const git_dirty = if (commandOutput(b, &.{ "git", "status", "--porcelain", "--untracked-files=no" })) |status| status.len != 0 else false;
    build_options.addOption([]const u8, "version", "0.2.0");
    build_options.addOption([]const u8, "git_commit", git_commit);
    build_options.addOption(bool, "git_dirty", git_dirty);
    build_options.addOption([]const u8, "build_time", build_time);

    // 核心模块是两个二进制共享的唯一业务实现，避免 CLI 与守护进程行为分叉。
    const core = b.addModule("nodeforge", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zap", .module = zap.module("zap") },
        },
    });
    core.addOptions("build_options", build_options);

    // nodeforged 承载协议服务和本机管理接口。
    const daemon = b.addExecutable(.{
        .name = "nodeforged",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nodeforged.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nodeforge", .module = core },
                .{ .name = "zli", .module = zli.module("zli") },
            },
        }),
    });
    b.installArtifact(daemon);

    // nodeforge 只作为管理客户端，不直接持有服务运行态。
    const cli = b.addExecutable(.{
        .name = "nodeforge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nodeforge", .module = core },
                .{ .name = "zli", .module = zli.module("zli") },
            },
        }),
    });
    b.installArtifact(cli);

    // nodeforge-initrd：v0.2 diskless 启动 init（PID 1），运行在 dracut userspace。
    const initrd = b.addExecutable(.{
        .name = "nodeforge-initrd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/initrd.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(initrd);

    // nodeforge-agent：v0.2 切根后 pre-init / first-boot。
    const agent = b.addExecutable(.{
        .name = "nodeforge-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(agent);
    // Rootfs/image builder installs this unit together with nodeforge-agent.
    // Keeping the unit in the product artifact avoids relying on host-specific
    // validation scripts to reconstruct the first-boot runtime contract.
    b.installFile("packaging/systemd/nodeforge-firstboot.service", "share/nodeforge/systemd/nodeforge-firstboot.service");

    const run_daemon = b.addRunArtifact(daemon);
    if (b.args) |args| run_daemon.addArgs(args);
    const run_daemon_step = b.step("run-daemon", "Run nodeforged");
    run_daemon_step.dependOn(&run_daemon.step);

    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| run_cli.addArgs(args);
    const run_cli_step = b.step("run", "Run nodeforge CLI");
    run_cli_step.dependOn(&run_cli.step);

    // 所有核心模块的 test 块由一个测试入口统一执行。
    const unit_tests = b.addTest(.{ .root_module = core });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run NodeForge tests");
    test_step.dependOn(&run_tests.step);

    // CLI contract tests exercise the installed command tree, generated help,
    // command-local flags, and parse-error exit codes end to end.
    const cli_tests = b.addSystemCommand(&.{"sh"});
    cli_tests.addFileArg(b.path("tests/cli.sh"));
    cli_tests.addArtifactArg(cli);
    cli_tests.addArtifactArg(daemon);
    test_step.dependOn(&cli_tests.step);

    // HTTP integration tests exercise the Zap-backed listener, management
    // routes, and the M0 single-listener/port-preflight invariant.
    // Both shell tests start daemon processes that bind privileged UDP ports
    // (DHCP 67, TFTP 69); run them serially to avoid port conflicts.
    // `tests/http.sh` exits early on Darwin (macOS cannot bind privileged UDP
    // ports without root); run the HTTP suite on Linux root for full coverage.
    // `tests/cli.sh` and `setup.sh` still run on macOS.
    const http_tests = b.addSystemCommand(&.{"sh"});
    http_tests.addFileArg(b.path("tests/http.sh"));
    http_tests.addArtifactArg(cli);
    http_tests.addArtifactArg(daemon);
    http_tests.step.dependOn(&cli_tests.step);
    test_step.dependOn(&http_tests.step);

    const setup_tests = b.addSystemCommand(&.{"sh"});
    setup_tests.addFileArg(b.path("tests/setup.sh"));
    setup_tests.addArtifactArg(cli);
    setup_tests.addArtifactArg(daemon);
    setup_tests.step.dependOn(&http_tests.step);
    test_step.dependOn(&setup_tests.step);
}

fn commandOutput(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{ .argv = argv, .stdout_limit = .limited(16 * 1024), .stderr_limit = .limited(16 * 1024) }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return b.allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n")) catch null;
}
