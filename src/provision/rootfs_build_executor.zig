//! # v0.2 rootfs-build phase 执行器
//!
//! `V0_2_DESIGN.md` §5.2/§5.3。把 Profile 的 rootfs-build provision 步骤
//! （`phase == .rootfs_build`）按固定顺序 managed_file -> package -> archive ->
//! script 编译为 chroot 内的一次性构建命令，向只读 lower 追加业务内容。
//!
//! 复用 `provision/first_boot.zig` 的 `renderStep`（相同安全不变量：目标路径必须
//! 绝对且不含 `..`、文件字节以 `printf %b` 八进制转义、package 只访问 pinned
//! nodeforged 受管源并禁用其他源）。
//!
//! 与 first-boot 的区别：rootfs-build 在服务端 builder 的 staging 目录内 chroot
//! 执行，是 **fail-closed**——任一步渲染/执行失败即放弃整次构建，不发布半成品
//! rootfs，不存在 journal/降级语义。OS 层 unsquashfs/chroot/mksquashfs 调用属
//! 环境相关执行边界（与 initrd/first_boot 一致），本模块只负责可单测的步骤编译
//! 与命令渲染；`execute` 在 Linux/root 构建主机上运行。
const std = @import("std");
const model = @import("../model.zig");
const dto = @import("../http/diskless_dto.zig");
const first_boot = @import("first_boot.zig");

/// 一条已编译的构建命令：渲染好的步骤体写入 staging 内的 `script_path`，再 chroot 执行。
pub const BuildCommand = struct {
    script_path: []const u8,
    body: []const u8,
    timeout_s: u32,
    /// managed_file/archive/script 在 chroot 内执行（写绝对路径到 staging lower）；
    /// package 以 `--installroot` 在 host 上下文执行（无需 bind-mount /dev/proc/sys）。
    chroot: bool = true,
};

pub const BuildPlan = struct {
    commands: []const BuildCommand,
    package_manager: ?dto.FirstBootPackageManager,
    repository_urls: []const []const u8,

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

/// 把 rootfs-build 步骤序列编译为固定顺序的 chroot 构建命令。
/// `payload_paths[i]` 对应 `steps[i]` 的 content_asset 物化路径（null 表示 inline content）。
/// 任一步 phase 非 rootfs_build、action 不允许或渲染失败即 fail-closed。
pub fn buildPlan(
    allocator: std.mem.Allocator,
    steps: []const model.ProvisionStep,
    package_manager: ?dto.FirstBootPackageManager,
    repository_urls: []const []const u8,
    payload_paths: []const ?[]const u8,
    staging: []const u8,
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
            const fb = try toFirstBootStep(step, payload_paths[i]);
            var body: std.Io.Writer.Allocating = .init(allocator);
            errdefer body.deinit();
            // package 以 --installroot 在 host 上下文安装（与 OS 层一致，本地 file:// 源，
            // 不回连 daemon、不需 chroot/bind-mount）；其余动作 chroot 写 staging lower。
            const installroot: ?[]const u8 = if (step.action == .package) staging else null;
            try first_boot.renderStep(&body.writer, fb, package_manager, repository_urls, true, installroot);
            const script_path = try std.fmt.allocPrint(allocator, "{s}{d}.sh", .{ script_prefix, index });
            try commands.append(allocator, .{
                .script_path = script_path,
                .body = try body.toOwnedSlice(),
                .timeout_s = step.timeout_s,
                .chroot = installroot == null,
            });
            index += 1;
        }
    }
    return .{
        .commands = try commands.toOwnedSlice(allocator),
        .package_manager = package_manager,
        .repository_urls = repository_urls,
    };
}

/// 在 staging 目录内执行构建计划（fail-closed，任一退出码非 0 即放弃）：
/// managed_file/archive/script 把 body 写入 staging 内脚本后 chroot 执行（写绝对
/// 路径到 staging lower）；package 直接在 host 上下文以 `--installroot` 安装（无需
/// chroot/bind-mount）。执行属环境相关边界（仅 Linux/root 构建主机可用）。
pub fn execute(io: std.Io, allocator: std.mem.Allocator, staging: []const u8, plan: BuildPlan) !void {
    for (plan.commands) |cmd| {
        if (cmd.chroot) {
            const full_script = try std.fmt.allocPrint(allocator, "{s}{s}", .{ staging, cmd.script_path });
            defer allocator.free(full_script);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_script, .data = cmd.body });
            try runChecked(io, allocator, &.{ "chroot", staging, "/bin/sh", cmd.script_path });
        } else {
            // package: --installroot 已嵌入 body，host 上下文执行。
            try runChecked(io, allocator, &.{ "sh", "-c", cmd.body });
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
    const plan = try buildPlan(std.testing.allocator, &steps, .dnf, &.{"http://127.0.0.1/repo"}, &payload_paths, "/staging");
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), plan.commands.len);
    try std.testing.expectEqualStrings("/tmp/nodeforge-rootfs-build-0.sh", plan.commands[0].script_path);
    // managed_file 先于 package 先于 archive 先于 script。
    try std.testing.expect(std.mem.indexOf(u8, plan.commands[0].body, "/etc/motd") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.commands[1].body, "dnf -y --installroot=/staging --disablerepo") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.commands[2].body, "/opt/app") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.commands[3].body, "sh /tmp/.nodeforge-script") != null);
}

test "buildPlan resolves content_asset to a staged payload path" {
    const steps = [_]model.ProvisionStep{
        .{ .name = "arc", .phase = .rootfs_build, .action = .archive, .content_asset = "myarchive", .destination = "/opt/app" },
    };
    const payload_paths = [_]?[]const u8{"myarchive/1"};
    const plan = try buildPlan(std.testing.allocator, &steps, null, &.{}, &payload_paths, "/staging");
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
    try std.testing.expectError(error.PhaseNotRootfsBuild, buildPlan(std.testing.allocator, &wrong_phase, null, &.{}, &paths, "/staging"));

    const bad_action = [_]model.ProvisionStep{
        .{ .name = "r", .phase = .rootfs_build, .action = .repository, .repository = "x" },
    };
    try std.testing.expectError(error.ActionNotAllowedInRootfsBuild, buildPlan(std.testing.allocator, &bad_action, null, &.{}, &paths, "/staging"));

    // payload_paths 长度不匹配也 fail-closed。
    const ok_steps = [_]model.ProvisionStep{
        .{ .name = "m", .phase = .rootfs_build, .action = .managed_file, .content = "y", .destination = "/etc/motd" },
    };
    try std.testing.expectError(error.PayloadPathMismatch, buildPlan(std.testing.allocator, &ok_steps, null, &.{}, &.{}, "/staging"));
}

test "buildPlan package step reuses first_boot dnf source isolation" {
    const steps = [_]model.ProvisionStep{
        .{ .name = "p", .phase = .rootfs_build, .action = .package, .packages = &.{ "tmux", "vim" } },
    };
    const plan = try buildPlan(std.testing.allocator, &steps, .dnf, &.{"http://10.0.2.2/repo"}, &.{null}, "/staging");
    defer plan.deinit(std.testing.allocator);
    const body = plan.commands[0].body;
    try std.testing.expect(std.mem.indexOf(u8, body, "--disablerepo='*'") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "install 'tmux' 'vim'") != null);
    // rootfs-build package action 与 OS 层一致使用 --nogpgcheck（本地受管受信源）。
    try std.testing.expect(std.mem.indexOf(u8, body, "--nogpgcheck") != null);
}
