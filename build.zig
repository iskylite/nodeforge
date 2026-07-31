const std = @import("std");

/// NodeForge 产品版本的唯一构建事实源。发布新版本时同步更新 build.zig.zon。
const nodeforge_version = "0.2.3";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zli = b.dependency("zli", .{});
    const zap = b.dependency("zap", .{ .target = target, .optimize = optimize });
    const build_options = b.addOptions();
    const git_commit = b.option([]const u8, "git-commit", "Git commit recorded in version output") orelse commandOutput(b, &.{ "git", "rev-parse", "HEAD" }) orelse "unknown";
    // 使用 Zig 标准库读取实时时钟并格式化为 UTC，避免依赖宿主 shell/date。
    // 可复现构建可通过 -Dbuild-time 显式注入固定值。
    const build_time = b.option([]const u8, "build-time", "UTC build time recorded in version output") orelse utcBuildTime(b) orelse "unknown";
    const git_dirty = if (commandOutput(b, &.{ "git", "status", "--porcelain", "--untracked-files=no" })) |status| status.len != 0 else false;
    build_options.addOption([]const u8, "version", nodeforge_version);
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
    //
    // single_threaded=true 只约束早期启动二进制，不影响 daemon/CLI。Zig stdlib
    // 在 link_libc=true 时默认引用 pthread 符号
    // （如 pthread_create/pthread_mutex_init）。glibc >= 2.34 将 pthread 合并入 libc，
    // 但 Rocky 9 / Ubuntu 22.04 等可能使用 glibc < 2.34 的 sysroot 交叉编译，
    // 导致链接产物包含 NEEDED libpthread.so.0。最小 initrd 环境中不包含该库，
    // 二进制无法加载。single_threaded=true 阻止 stdlib 引入任何 pthread 符号。
    // 代价是该程序及其依赖不能创建线程或依赖线程同步；当前 PID 1 是顺序状态机。
    // 此设置不降低 GLIBC symbol version：CentOS 7 仍须用 gnu.2.17 sysroot 构建。
    // 若未来取消，构建器必须从目标 ISO/sysroot 注入 interpreter + 递归
    // DT_NEEDED（glibc < 2.34 包括 libpthread.so.0），严禁复制宿主库。
    //
    // strip=true：ReleaseSafe/ReleaseFast 时 strip 调试信息。initrd 二进制通过
    // TFTP/HTTP 传输到节点，体积直接影响启动延迟。Debug 模式保留符号便于开发调试。
    const initrd = b.addExecutable(.{
        .name = "nodeforge-initrd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/initrd.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .single_threaded = true,
            .strip = optimize == .ReleaseSafe or optimize == .ReleaseFast,
        }),
    });
    b.installArtifact(initrd);

    // nodeforge-agent：v0.2 切根后 pre-init / first-boot。
    // single_threaded=true 和 strip=true 的理由与 nodeforge-initrd 相同。未来若
    // agent 确需并行下载/心跳，可只对 agent 启用线程并消费完整目标 rootfs 闭包，
    // 无需同时扩大最早期 /init 的 ABI 依赖面。
    const agent = b.addExecutable(.{
        .name = "nodeforge-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .single_threaded = true,
            .strip = optimize == .ReleaseSafe or optimize == .ReleaseFast,
        }),
    });
    b.installArtifact(agent);
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

/// 使用 Zig 标准库生成秒精度 RFC 3339 UTC 构建时间。
fn utcBuildTime(b: *std.Build) ?[]const u8 {
    const timestamp = std.Io.Clock.real.now(b.graph.io).toSeconds();
    if (timestamp < 0) return null;
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return std.fmt.allocPrint(b.allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch null;
}
