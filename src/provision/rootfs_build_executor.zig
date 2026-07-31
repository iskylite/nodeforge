//! # v0.2/v0.2.1 rootfs-build phase 执行器
//!
//! `V0_2_DESIGN.md` §5.2/§5.3。把 Profile 的 rootfs-build provision 步骤
//! （`phase == .rootfs_build`）按固定顺序 managed_file -> package -> archive ->
//! script 编译为构建命令，向只读 lower 追加业务内容。
//!
//! 复用 `provision/first_boot.zig` 的 `renderStep`（managed_file/archive/script，
//! 相同安全不变量：目标路径必须绝对且不含 `..`、文件字节以 `printf %b` 八进制
//! 转义）在真根 chroot 内执行。package 步骤（dnf 与 apt 均适用）统一经
//! `namespaced_chroot_executor` 在独立 namespace+chroot 内执行——v0.2.1 起不再
//! 区分"dnf host-context / apt 不支持"，两者共用同一隔离原语（`isolation`
//! 字段区分 `.chroot` 与 `.namespaced_package`）。
//!
//! 与 first-boot 的区别：rootfs-build 在服务端 builder 的 staging 目录内执行，
//! 是 **fail-closed**——任一步渲染/执行失败即放弃整次构建，不发布半成品
//! rootfs，不存在 journal/降级语义。OS 层/package 安装/chroot 调用属
//! 环境相关执行边界（与 initrd/first_boot 一致），本模块只负责可单测的步骤编译
//! 与命令渲染；`execute` 在 Linux/root 构建主机上运行。
const std = @import("std");
const model = @import("../model.zig");
const dto = @import("../http/diskless_dto.zig");
const first_boot = @import("first_boot.zig");
const namespaced_chroot_executor = @import("namespaced_chroot_executor.zig");

/// 一条已编译的构建命令：managed_file/archive/script 渲染好的步骤体写入
/// staging 内的 `script_path` 后 chroot 执行；package 步骤不预渲染 body（由
/// `execute` 按 `packages`/`package_manager` 直接调用 `namespaced_chroot_executor`）。
pub const BuildCommand = struct {
    script_path: []const u8,
    body: []const u8,
    timeout_s: u32,
    /// managed_file/archive/script 在真根 chroot 内执行（写绝对路径到 staging
    /// lower）；package 步骤统一经 namespace+chroot 隔离执行（dnf 与 apt 一致）。
    isolation: enum { chroot, namespaced_package } = .chroot,
    /// 仅 `isolation == .namespaced_package` 时非空：本步骤要安装的包列表。
    packages: []const []const u8 = &.{},
};

pub const BuildPlan = struct {
    commands: []const BuildCommand,
    package_manager: ?dto.FirstBootPackageManager,
    repository_urls: []const []const u8,
    /// apt 专用：rootfs-build package 步骤是否保留 casper 自带源。
    /// 来自 Profile install.apt.preserve_sources_list；dnf 恒为 false。
    apt_preserve_sources_list: bool = false,

    pub fn deinit(self: BuildPlan, allocator: std.mem.Allocator) void {
        for (self.commands) |cmd| {
            allocator.free(cmd.script_path);
            allocator.free(cmd.body);
        }
        allocator.free(self.commands);
    }
};

const script_prefix = "/tmp/nodeforge-rootfs-build-";
const order = [_]model.ProvisionAction{ .managed_file, .package, .archive, .script };

/// rootfs-build 允许的 action 集合（与 first-boot 四类一致，排除 repository/standard_packages）。
pub fn allowedAction(action: model.ProvisionAction) bool {
    return switch (action) {
        .managed_file, .archive, .script, .package => true,
        else => false,
    };
}

fn toFirstBootAction(action: model.ProvisionAction) !dto.FirstBootAction {
    return switch (action) {
        .managed_file => .managed_file,
        .archive => .archive,
        .script => .script,
        .package => .package,
        else => error.ActionNotAllowedInRootfsBuild,
    };
}

/// 把单个 rootfs-build `ProvisionStep` 转换为 first-boot 渲染所需的 `FirstBootStep`。
/// `payload_path` 为 content_asset 已物化到 staging 内的 chroot 路径；inline content 时传 null。
pub fn toFirstBootStep(step: model.ProvisionStep, payload_path: ?[]const u8) !dto.FirstBootStep {
    return .{
        .id = step.name,
        .idempotency_key = step.idempotency_key,
        .timeout_s = step.timeout_s,
        .retryable = step.retryable,
        .action = try toFirstBootAction(step.action),
        .content = if (payload_path == null) step.content else null,
        .payload_path = payload_path,
        .destination = step.destination,
        .mode = step.mode,
        .owner = step.owner,
        .group = step.group,
        .packages = step.packages,
    };
}

/// 把 rootfs-build 步骤序列编译为固定顺序的构建命令。
/// `payload_paths[i]` 对应 `steps[i]` 的 content_asset 物化路径（null 表示 inline content）。
/// 任一步 phase 非 rootfs_build、action 不允许即 fail-closed。
pub fn buildPlan(
    allocator: std.mem.Allocator,
    steps: []const model.ProvisionStep,
    package_manager: ?dto.FirstBootPackageManager,
    repository_urls: []const []const u8,
    payload_paths: []const ?[]const u8,
    apt_preserve_sources_list: bool,
) !BuildPlan {
    if (steps.len != payload_paths.len) return error.PayloadPathMismatch;
    // fail-closed 前置校验：每一步 phase 必须为 rootfs_build、action 必须属于允许集合。
    for (steps) |step| {
        if (step.phase != .rootfs_build) return error.PhaseNotRootfsBuild;
        if (!allowedAction(step.action)) return error.ActionNotAllowedInRootfsBuild;
    }
    var commands: std.ArrayList(BuildCommand) = .empty;
    errdefer {
        for (commands.items) |cmd| {
            allocator.free(cmd.script_path);
            allocator.free(cmd.body);
        }
        commands.deinit(allocator);
    }
    var index: usize = 0;
    for (order) |act| {
        for (steps, 0..) |step, i| {
            if (step.action != act) continue;
            if (step.action == .package) {
                // package 步骤不预渲染 shell body：dnf 与 apt 统一经
                // namespaced_chroot_executor 在独立 namespace+chroot 内执行。
                const script_path = try std.fmt.allocPrint(allocator, "{s}{d}.sh", .{ script_prefix, index });
                try commands.append(allocator, .{
                    .script_path = script_path,
                    .body = try allocator.dupe(u8, ""),
                    .timeout_s = step.timeout_s,
                    .isolation = .namespaced_package,
                    .packages = step.packages,
                });
                index += 1;
                continue;
            }
            const fb = try toFirstBootStep(step, payload_paths[i]);
            var body: std.Io.Writer.Allocating = .init(allocator);
            errdefer body.deinit();
            try first_boot.renderStep(&body.writer, fb, package_manager, repository_urls, true, null);
            const script_path = try std.fmt.allocPrint(allocator, "{s}{d}.sh", .{ script_prefix, index });
            try commands.append(allocator, .{
                .script_path = script_path,
                .body = try body.toOwnedSlice(),
                .timeout_s = step.timeout_s,
                .isolation = .chroot,
            });
            index += 1;
        }
    }
    return .{
        .commands = try commands.toOwnedSlice(allocator),
        .package_manager = package_manager,
        .repository_urls = repository_urls,
        .apt_preserve_sources_list = apt_preserve_sources_list,
    };
}

/// 在 staging 目录内执行构建计划（fail-closed，任一退出码非 0 即放弃）：
/// managed_file/archive/script 把 body 写入 staging 内脚本后在真根 chroot 执行；
/// package 步骤（dnf 与 apt 均适用）统一经 `namespaced_chroot_executor` 在独立
/// namespace+chroot 内执行。执行属环境相关边界（仅 Linux/root 构建主机可用）。
pub fn execute(io: std.Io, allocator: std.mem.Allocator, staging: []const u8, plan: BuildPlan) !void {
    for (plan.commands) |cmd| {
        switch (cmd.isolation) {
            .chroot => {
                const full_script = try std.fmt.allocPrint(allocator, "{s}{s}", .{ staging, cmd.script_path });
                defer allocator.free(full_script);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_script, .data = cmd.body });
                try runChecked(io, allocator, &.{ "chroot", staging, "/bin/sh", cmd.script_path });
            },
            .namespaced_package => {
                const package_manager = plan.package_manager orelse return error.UnsafeHostBuildCommand;
                try namespaced_chroot_executor.execute(io, allocator, staging, package_manager, cmd.packages, plan.repository_urls, true, .chroot, cmd.timeout_s, plan.apt_preserve_sources_list);
            },
        }
    }
}

fn runChecked(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(131072), .stderr_limit = .limited(131072) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.log.scoped(.rootfs_build).err("chroot step failed ({s}): {s}", .{ argv[0], result.stderr });
            return error.BuildStepFailed;
        },
        else => {
            std.log.scoped(.rootfs_build).err("chroot step did not exit cleanly ({s}): {s}", .{ argv[0], result.stderr });
            return error.BuildStepFailed;
        },
    }
}

test "allowedAction accepts the four rootfs-build actions and rejects others" {
    try std.testing.expect(allowedAction(.managed_file));
    try std.testing.expect(allowedAction(.archive));
    try std.testing.expect(allowedAction(.script));
    try std.testing.expect(allowedAction(.package));
    try std.testing.expect(!allowedAction(.repository));
    try std.testing.expect(!allowedAction(.standard_packages));
}

test "buildPlan orders steps managed_file -> package -> archive -> script and reuses first_boot rendering" {
    // 故意乱序输入；输出必须按固定顺序排列。
    const steps = [_]model.ProvisionStep{
        .{ .name = "s", .phase = .rootfs_build, .action = .script, .content = "echo hi\n" },
        .{ .name = "a", .phase = .rootfs_build, .action = .archive, .content = "x", .destination = "/opt/app" },
        .{ .name = "p", .phase = .rootfs_build, .action = .package, .packages = &.{"jq"} },
        .{ .name = "m", .phase = .rootfs_build, .action = .managed_file, .content = "hi\n", .destination = "/etc/motd" },
    };
    const payload_paths = [_]?[]const u8{ null, null, null, null };
    const plan = try buildPlan(std.testing.allocator, &steps, .dnf, &.{"http://127.0.0.1/repo"}, &payload_paths, false);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), plan.commands.len);
    try std.testing.expectEqualStrings("/tmp/nodeforge-rootfs-build-0.sh", plan.commands[0].script_path);
    // managed_file 先于 package 先于 archive 先于 script。
    try std.testing.expect(std.mem.indexOf(u8, plan.commands[0].body, "/etc/motd") != null);
    try std.testing.expectEqual(.namespaced_package, plan.commands[1].isolation);
    try std.testing.expectEqualStrings("jq", plan.commands[1].packages[0]);
    try std.testing.expect(std.mem.indexOf(u8, plan.commands[2].body, "/opt/app") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.commands[3].body, "sh /tmp/.nodeforge-script") != null);
}

test "buildPlan resolves content_asset to a staged payload path" {
    const steps = [_]model.ProvisionStep{
        .{ .name = "arc", .phase = .rootfs_build, .action = .archive, .content_asset = "myarchive", .destination = "/opt/app" },
    };
    const payload_paths = [_]?[]const u8{"myarchive/1"};
    const plan = try buildPlan(std.testing.allocator, &steps, null, &.{}, &payload_paths, false);
    defer plan.deinit(std.testing.allocator);
    // 走 payload_path 分支：archive 用 cp/tar 引用已校验 payload，不内联字节。
    try std.testing.expect(std.mem.indexOf(u8, plan.commands[0].body, "/var/lib/nodeforge/payload/myarchive/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.commands[0].body, "printf '%b'") == null);
}

test "buildPlan is fail-closed on wrong phase and disallowed action" {
    const wrong_phase = [_]model.ProvisionStep{
        .{ .name = "x", .phase = .first_boot, .action = .managed_file, .content = "y", .destination = "/etc/motd" },
    };
    const paths = [_]?[]const u8{null};
    try std.testing.expectError(error.PhaseNotRootfsBuild, buildPlan(std.testing.allocator, &wrong_phase, null, &.{}, &paths, false));

    const bad_action = [_]model.ProvisionStep{
        .{ .name = "r", .phase = .rootfs_build, .action = .repository, .repository = "x" },
    };
    try std.testing.expectError(error.ActionNotAllowedInRootfsBuild, buildPlan(std.testing.allocator, &bad_action, null, &.{}, &paths, false));

    // payload_paths 长度不匹配也 fail-closed。
    const ok_steps = [_]model.ProvisionStep{
        .{ .name = "m", .phase = .rootfs_build, .action = .managed_file, .content = "y", .destination = "/etc/motd" },
    };
    try std.testing.expectError(error.PayloadPathMismatch, buildPlan(std.testing.allocator, &ok_steps, null, &.{}, &.{}, false));
}

test "buildPlan package step carries packages for namespaced execution regardless of package manager" {
    const steps = [_]model.ProvisionStep{
        .{ .name = "p", .phase = .rootfs_build, .action = .package, .packages = &.{ "tmux", "vim" } },
    };
    const plan = try buildPlan(std.testing.allocator, &steps, .dnf, &.{"http://10.0.2.2/repo"}, &.{null}, false);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(.namespaced_package, plan.commands[0].isolation);
    try std.testing.expectEqualStrings("tmux", plan.commands[0].packages[0]);
    try std.testing.expectEqualStrings("vim", plan.commands[0].packages[1]);
}

test "apt rootfs-build package step compiles to namespaced_package isolation" {
    const steps = [_]model.ProvisionStep{
        .{ .name = "p", .phase = .rootfs_build, .action = .package, .packages = &.{"curl"} },
    };
    const plan = try buildPlan(std.testing.allocator, &steps, .apt, &.{"file:///managed/apt"}, &.{null}, false);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(.namespaced_package, plan.commands[0].isolation);
    try std.testing.expectEqualStrings("curl", plan.commands[0].packages[0]);
}

test "buildPlan threads apt preserve_sources_list into the plan" {
    const steps = [_]model.ProvisionStep{
        .{ .name = "p", .phase = .rootfs_build, .action = .package, .packages = &.{"curl"} },
    };
    const preserved = try buildPlan(std.testing.allocator, &steps, .apt, &.{"file:///managed/apt"}, &.{null}, true);
    defer preserved.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, preserved.apt_preserve_sources_list);
    const replaced = try buildPlan(std.testing.allocator, &steps, .apt, &.{"file:///managed/apt"}, &.{null}, false);
    defer replaced.deinit(std.testing.allocator);
    try std.testing.expectEqual(false, replaced.apt_preserve_sources_list);
}

test "dnf rootfs-build package step also compiles to namespaced_package isolation" {
    const steps = [_]model.ProvisionStep{
        .{ .name = "p", .phase = .rootfs_build, .action = .package, .packages = &.{"jq"} },
    };
    const plan = try buildPlan(std.testing.allocator, &steps, .dnf, &.{"file:///managed/dnf"}, &.{null}, false);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(.namespaced_package, plan.commands[0].isolation);
}

test "execute refuses namespaced_package commands with no package manager set" {
    const commands = [_]BuildCommand{.{
        .script_path = "/tmp/never-runs.sh",
        .body = "",
        .timeout_s = 30,
        .isolation = .namespaced_package,
        .packages = &.{"curl"},
    }};
    const plan: BuildPlan = .{
        .commands = &commands,
        .package_manager = null,
        .repository_urls = &.{"file:///managed/apt"},
    };
    try std.testing.expectError(
        error.UnsafeHostBuildCommand,
        execute(std.testing.io, std.testing.allocator, "/staging", plan),
    );
}
