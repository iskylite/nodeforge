const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zli = b.dependency("zli", .{});
    const zap = b.dependency("zap", .{ .target = target, .optimize = optimize });

    // 核心模块是两个二进制共享的唯一业务实现，避免 CLI 与守护进程行为分叉。
    const core = b.addModule("nodeforge", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zap", .module = zap.module("zap") },
        },
    });

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
    const http_tests = b.addSystemCommand(&.{"sh"});
    http_tests.addFileArg(b.path("tests/http.sh"));
    http_tests.addArtifactArg(cli);
    http_tests.addArtifactArg(daemon);
    test_step.dependOn(&http_tests.step);
}
