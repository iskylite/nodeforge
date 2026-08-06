const std = @import("std");
const builtin = @import("builtin");

/// NodeForge 产品版本的唯一构建事实源。发布新版本时同步更新 build.zig.zon。
const nodeforge_version = "0.4.1";

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

    // nodeforge-initrd：diskless 启动 PID 1，跑在最小 initramfs 闭包里。
    //
    // 始终 single_threaded=true：Zig 在 link_libc 且非 single_threaded 时可能引入
    // pthread 符号，链接结果常带 NEEDED libpthread.so.0。NodeForge overlay 故意
    // 不注入宿主/sysroot 的 libc/pthread（防 ABI 混配），最小 initrd 往往也无该库，
    // 一加载即失败。PID 1 本身是顺序状态机，无线程收益。
    // 与「是否在 Mac 上交叉」无关：任何主机上编出的 initrd 都不得依赖 pthread。
    // strip=true：Release* 去调试信息，减小 TFTP/HTTP 传输体积。
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

    // nodeforge-agent：切根后 pre-init / first-boot /（后续）inspect 与本机构建。
    // 跑在完整目标 rootfs 用户态（glibc 自带 pthread 或已并入 libc），与 initrd 不同。
    //
    // 线程模型默认按**构建主机** OS：
    // - Linux 本机编译：single_threaded=false（允许多线程，依赖目标 rootfs 的 glibc）
    // - 非 Linux（如 macOS 交叉）：single_threaded=true，避免交叉 sysroot 下轻易
    //   NEEDED libpthread 而与「最小闭包/旧 sysroot」纠缠；可用 -Dagent-single-threaded=
    //   显式覆盖。
    // initrd 仍始终单线程；不因 agent 开线程去改 /init 或往 initrd 塞 libpthread。
    const agent_single_threaded = b.option(
        bool,
        "agent-single-threaded",
        "Force nodeforge-agent single_threaded (default: false on Linux hosts, true otherwise)",
    ) orelse (builtin.os.tag != .linux);
    const agent = b.addExecutable(.{
        .name = "nodeforge-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .single_threaded = agent_single_threaded,
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

    // 目标环境发布闸默认不挂到本地 test：它会实际修改配置的 r97n1 虚拟机，
    // 并依赖可访问的 r97n0 管理节点，因此必须由操作员显式触发。
    const v03_install_post_e2e = b.addSystemCommand(&.{"bash"});
    v03_install_post_e2e.addFileArg(b.path("tests/v0_3_install_post_e2e.sh"));
    const v03_install_post_e2e_step = b.step("test-v0.3-install-post-e2e", "Run the real PXE install-post v0.3 gate");
    v03_install_post_e2e_step.dependOn(&v03_install_post_e2e.step);

    const v04_contract = b.addSystemCommand(&.{"sh"});
    v04_contract.addFileArg(b.path("tests/v0_4_contract.sh"));
    v04_contract.addArtifactArg(cli);
    v04_contract.addArtifactArg(daemon);
    v04_contract.addArtifactArg(agent);
    v04_contract.addArtifactArg(initrd);
    const v04_contract_step = b.step("test-v0.4-contract", "Run the local v0.4 strict contract gate");
    v04_contract_step.dependOn(&v04_contract.step);

    // Capacity workload only — same core module, filtered to "v0.4 workload" tests.
    // Does not re-run CLI/HTTP/setup shell suites.
    const workload_tests = b.addTest(.{
        .root_module = core,
        .filters = &.{"v0.4 workload"},
    });
    const run_workload = b.addRunArtifact(workload_tests);
    const v04_capacity_step = b.step("test-v0.4-capacity", "Run v0.4 logical capacity workload (256/512/1024 waves)");
    v04_capacity_step.dependOn(&run_workload.step);

    // v0.4.1 staging session unit tests — filtered to staging_kernel_import + staging_session tests.
    const staging_unit_tests = b.addTest(.{
        .root_module = core,
        .filters = &.{ "staging_kernel_import", "staging_session" },
    });
    const run_staging_unit = b.addRunArtifact(staging_unit_tests);
    const v041_staging_unit_step = b.step("test-v0.4.1-staging-unit", "Run v0.4.1 staging session + kernel import unit tests");
    v041_staging_unit_step.dependOn(&run_staging_unit.step);

    // v0.4.1 staging session contract gate — CLI surface + negative binary assertions.
    const v041_staging_contract = b.addSystemCommand(&.{"sh"});
    v041_staging_contract.addFileArg(b.path("tests/v0_4_1_staging_session.sh"));
    v041_staging_contract.addArtifactArg(cli);
    v041_staging_contract.addArtifactArg(daemon);
    v041_staging_contract.addArtifactArg(agent);
    v041_staging_contract.addArtifactArg(initrd);
    const v041_staging_step = b.step("test-v0.4.1-staging", "Run v0.4.1 staging session contract gate");
    v041_staging_step.dependOn(&v041_staging_contract.step);
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
