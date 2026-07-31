//! # 统一 namespace+chroot 隔离执行原语（v0.2.1 R5 扩展）
//!
//! dnf 与 apt 的 package 安装步骤统一通过本模块在独立 mount/PID namespace 内的
//! chroot 环境中执行，替换旧的 dnf `--installroot` host-context 模式——
//! `--installroot` 不 bind-mount `/dev,/proc,/sys`，任何调用 `dracut`/`depmod -a`/
//! `udevadm` 的 scriptlet 在 host-context 下可能静默失败或产生错误结果；apt/dpkg
//! 的 maintainer script 天然假设跑在真根或 chroot 里，没有等价 host-context 模式。
//!
//! 执行模型：一次性子进程 `unshare --mount --pid --fork --mount-proc`，daemon 主
//! 线程不进 namespace（避免死锁与清理风险），helper 脚本内 bind-mount
//! `/dev,/proc,/sys`、写入阻止服务自启动的 `policy-rc.d`、chroot 执行步骤脚本、
//! 显式 `umount -l` 清理。namespace 退出后 Zig 侧再做一次幂等清理并显式校验
//! `<staging>/proc`、`<staging>/sys`、`<staging>/dev` 已不是挂载点，任何残留挂载
//! 判定整个操作失败（`error.NamespaceCleanupIncomplete`），不能静默放过。
//!
//! 属环境相关执行边界（`unshare --mount` 需要 root/CAP_SYS_ADMIN），本模块的
//! `execute` 不在单元测试覆盖内；单元测试改为契约测试，断言 `renderWrapperScript`/
//! `renderPackageStep` 产出的脚本文本结构。
const std = @import("std");
const dto = @import("../http/diskless_dto.zig");

/// 步骤脚本的执行目标：
/// - `.chroot`：staging 已是完整可 chroot 的 rootfs（casper overlay 之后，或
///   rootfs-build phase 叠加时），脚本以真根路径在 chroot 内执行；
/// - `.installroot`：staging 尚为空（dnf OS 层从零构建，staging 内还没有
///   dnf/rpm 自身），只能在 namespace 内以 host dnf + `--installroot=<staging>`
///   执行——bind-mount 的 `/dev,/proc,/sys` 保证 scriptlet 仍可见，但不 chroot。
///   仅 dnf 支持；apt 恒为 `.chroot`（没有等价 host-context 安装模式）。
pub const Target = enum { chroot, installroot };

/// 在 chroot 内以真根路径执行的 package 安装步骤脚本体（默认 dnf/apt 均先禁用
/// 全部既有源，只启用调用方传入的 nodeforged 受管 `file://` 源；
/// `preserve_sources_list=true` 时 apt 保留既有源，仅附加受管源）。
pub fn renderPackageStep(
    w: *std.Io.Writer,
    package_manager: dto.FirstBootPackageManager,
    packages: []const []const u8,
    repository_urls: []const []const u8,
    nogpgcheck: bool,
    target: Target,
    staging: []const u8,
    preserve_sources_list: bool,
) !void {
    if (packages.len == 0) return error.NoPackages;
    if (repository_urls.len == 0) return error.NoManagedRepository;
    switch (package_manager) {
        .dnf => {
            try w.writeAll("dnf -y");
            if (target == .installroot) try w.print(" --installroot={s}", .{staging});
            try w.writeAll(" --disablerepo='*'");
            for (repository_urls, 0..) |url, index| {
                try w.print(" --repofrompath=nodeforge-{d},", .{index});
                try writeQuoted(w, url);
                try w.print(" --enablerepo=nodeforge-{d}", .{index});
            }
            if (nogpgcheck) try w.writeAll(" --nogpgcheck");
            try w.writeAll(" install");
            for (packages) |pkg| {
                try w.writeByte(' ');
                try writeQuoted(w, pkg);
            }
        },
        .apt => {
            // apt/dpkg 没有等价 host-context 安装模式，恒须 chroot；不支持 installroot。
            if (target == .installroot) return error.AptInstallrootUnsupported;
            // 默认先禁用全部既有源（含 casper 层自带的 cdrom:/公网条目），只留
            // 受管源；preserve_sources_list=true 时保留原有源，仅附加受管源。
            if (!preserve_sources_list) {
                try w.writeAll("(test -f /etc/apt/sources.list && mv /etc/apt/sources.list /etc/apt/sources.list.disabled; true)");
                try w.writeAll(" && rm -rf /etc/apt/sources.list.d && mkdir -p /etc/apt/sources.list.d");
            } else {
                try w.writeAll("mkdir -p /etc/apt/sources.list.d");
            }
            try w.writeAll(" && : > /etc/apt/sources.list.d/nodeforge.list");
            for (repository_urls) |url| {
                try w.writeAll(" && printf 'deb [trusted=yes] %s ./\\n' ");
                try writeQuoted(w, url);
                try w.writeAll(" >> /etc/apt/sources.list.d/nodeforge.list");
            }
            try w.writeAll(" && apt-get update");
            try w.writeAll(" && apt-get -y install");
            for (packages) |pkg| {
                try w.writeByte(' ');
                try writeQuoted(w, pkg);
            }
        },
    }
}

/// 生成 namespace 隔离脚本：bind-mount `/dev,/proc,/sys`、写 `policy-rc.d` 阻止
/// 服务自启动，随后按 `target` 执行步骤脚本本体——`.chroot` 时 `chroot` 进
/// staging 执行（staging 已是完整 rootfs）；`.installroot` 时脚本体自身已携带
/// `--installroot=<staging>`，直接在 host 上下文（namespace 内）执行，不
/// chroot。两种模式退出后都显式 `umount -l` 清理并保留步骤退出码。
pub fn renderWrapperScript(w: *std.Io.Writer, staging: []const u8, step_script_path: []const u8, target: Target) !void {
    try w.writeAll("unshare --mount --pid --fork --mount-proc -- sh -c '\n");
    try w.print("  mkdir -p {s}/dev {s}/proc {s}/sys\n", .{ staging, staging, staging });
    try w.print("  mount --bind /dev {s}/dev\n", .{staging});
    try w.print("  mount -t proc proc {s}/proc\n", .{staging});
    try w.print("  mount -t sysfs sys {s}/sys\n", .{staging});
    try w.print("  mkdir -p {s}/usr/sbin\n", .{staging});
    try w.print("  printf \"exit 101\\n\" > {s}/usr/sbin/policy-rc.d\n", .{staging});
    try w.print("  chmod +x {s}/usr/sbin/policy-rc.d\n", .{staging});
    switch (target) {
        .chroot => try w.print("  chroot {s} /bin/sh {s}\n", .{ staging, step_script_path }),
        .installroot => try w.print("  sh {s}{s}\n", .{ staging, step_script_path }),
    }
    try w.writeAll("  status=$?\n");
    try w.print("  rm -f {s}/usr/sbin/policy-rc.d\n", .{staging});
    try w.print("  umount -l {s}/sys {s}/proc {s}/dev\n", .{ staging, staging, staging });
    try w.writeAll("  exit $status\n");
    try w.writeAll("'");
}

/// 在独立 namespace+chroot 内执行一条 package 安装步骤。写入 staging 内的步骤
/// 脚本与外层 wrapper 脚本，运行后显式校验清理完成，任何残留挂载返回
/// `error.NamespaceCleanupIncomplete`。
pub fn execute(
    io: std.Io,
    allocator: std.mem.Allocator,
    staging: []const u8,
    package_manager: dto.FirstBootPackageManager,
    packages: []const []const u8,
    repository_urls: []const []const u8,
    nogpgcheck: bool,
    target: Target,
    timeout_s: u32,
    preserve_sources_list: bool,
) !void {
    // OS 层 bootstrap 没有 ProvisionStep 可携带 timeout，使用显式构建默认值；
    // 普通 package step 必须尊重模型中的 timeout_s，任何外部包管理器都不能
    // 让 durable operation 永久停在 running。
    const effective_timeout: u32 = if (timeout_s == 0) 1800 else timeout_s;
    if (effective_timeout > 86400) return error.InvalidStepTimeout;
    var step_body: std.Io.Writer.Allocating = .init(allocator);
    defer step_body.deinit();
    try renderPackageStep(&step_body.writer, package_manager, packages, repository_urls, nogpgcheck, target, staging, preserve_sources_list);

    const step_script_rel = "/tmp/nodeforge-namespaced-step.sh";
    const step_script_full = try std.fmt.allocPrint(allocator, "{s}{s}", .{ staging, step_script_rel });
    defer allocator.free(step_script_full);
    // installroot target：staging 尚为空，需创建 staging 本身和 step script 的
    // 父目录 staging/tmp/。chroot target：staging 已是完整 rootfs，/tmp 已存在。
    if (target == .installroot) {
        try std.Io.Dir.cwd().createDirPath(io, staging);
        const step_script_dir = try std.fmt.allocPrint(allocator, "{s}/tmp", .{staging});
        defer allocator.free(step_script_dir);
        try std.Io.Dir.cwd().createDirPath(io, step_script_dir);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = step_script_full, .data = step_body.written() });

    var wrapper: std.Io.Writer.Allocating = .init(allocator);
    defer wrapper.deinit();
    try renderWrapperScript(&wrapper.writer, staging, step_script_rel, target);

    const timeout_text = try std.fmt.allocPrint(allocator, "{d}", .{effective_timeout});
    defer allocator.free(timeout_text);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "timeout", "--signal=TERM", "--kill-after=10s", timeout_text, "sh", "-c", wrapper.written() },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    }) catch |err| {
        try verifyCleanup(io, allocator, staging);
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    // 无论 helper 成功、失败还是被 timeout 终止，都执行宿主侧幂等清理检查。
    // namespace 正常退出会自动撤销其中的 mount；这里额外防御异常实现或未来改动。
    try verifyCleanup(io, allocator, staging);
    const failed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        std.log.scoped(.rootfs_build).err("namespaced package step failed: {s}", .{result.stderr});
        return switch (result.term) {
            .exited => |code| if (code == 124 or code == 137) error.StepTimedOut else error.NamespacedPackageStepFailed,
            else => error.NamespacedPackageStepFailed,
        };
    }
}

/// 幂等兜底清理 + 显式校验 `<staging>/proc,sys,dev` 已不是挂载点；helper 脚本
/// 自身崩溃导致的残留挂载在此处兜底捕获。
fn verifyCleanup(io: std.Io, allocator: std.mem.Allocator, staging: []const u8) !void {
    for ([_][]const u8{ "sys", "proc", "dev" }) |leaf| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staging, leaf });
        defer allocator.free(path);
        _ = std.process.run(allocator, io, .{
            .argv = &.{ "umount", "-l", path },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch null;
    }
    const mountpoint_result = try std.process.run(allocator, io, .{
        .argv = &.{ "sh", "-c", try std.fmt.allocPrint(allocator, "mountpoint -q {s}/proc || mountpoint -q {s}/sys || mountpoint -q {s}/dev", .{ staging, staging, staging }) },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(mountpoint_result.stdout);
    defer allocator.free(mountpoint_result.stderr);
    const still_mounted = switch (mountpoint_result.term) {
        .exited => |code| code == 0,
        else => true,
    };
    if (still_mounted) return error.NamespaceCleanupIncomplete;
}

fn writeQuoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') {
            try w.writeAll("'\\''");
        } else {
            try w.writeByte(c);
        }
    }
    try w.writeByte('\'');
}

test "renderPackageStep dnf disables host repos and installs from managed source only" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderPackageStep(&out.writer, .dnf, &.{"jq"}, &.{"file:///managed/dnf"}, true, .chroot, "/staging", false);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "--disablerepo='*'") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "--repofrompath=nodeforge-0,'file:///managed/dnf'") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "--installroot") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "install 'jq'") != null);
}

test "renderPackageStep dnf installroot target injects --installroot for bootstrap OS layer" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderPackageStep(&out.writer, .dnf, &.{"bash"}, &.{"file:///managed/dnf"}, true, .installroot, "/staging", false);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "--installroot=/staging") != null);
}

test "renderPackageStep apt disables all existing sources before installing" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderPackageStep(&out.writer, .apt, &.{"curl"}, &.{"file:///managed/apt"}, true, .chroot, "/staging", false);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "sources.list.disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "rm -rf /etc/apt/sources.list.d") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "nodeforge.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "apt-get -y install 'curl'") != null);
}

test "renderPackageStep apt rejects installroot target (no host-context mode exists)" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(
        error.AptInstallrootUnsupported,
        renderPackageStep(&out.writer, .apt, &.{"curl"}, &.{"file:///managed/apt"}, true, .installroot, "/staging", false),
    );
}

test "renderPackageStep fails closed with no packages or no repository" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.NoPackages, renderPackageStep(&out.writer, .dnf, &.{}, &.{"file:///x"}, true, .chroot, "/staging", false));
    try std.testing.expectError(error.NoManagedRepository, renderPackageStep(&out.writer, .dnf, &.{"jq"}, &.{}, true, .chroot, "/staging", false));
}

test "renderPackageStep apt preserves existing sources when preserve_sources_list is set" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderPackageStep(&out.writer, .apt, &.{"curl"}, &.{"file:///managed/apt"}, true, .chroot, "/staging", true);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "sources.list.disabled") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "rm -rf /etc/apt/sources.list.d") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mkdir -p /etc/apt/sources.list.d") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "nodeforge.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "apt-get -y install 'curl'") != null);
}

test "renderWrapperScript wraps chroot execution in an isolated namespace with policy-rc.d guard" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, "/staging", "/tmp/nodeforge-namespaced-step.sh", .chroot);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "unshare --mount --pid") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "chroot /staging /bin/sh /tmp/nodeforge-namespaced-step.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "policy-rc.d") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "umount -l /staging/sys /staging/proc /staging/dev") != null);
    // 契约：mount/policy-rc.d 写入必须发生在 staging 前缀路径下，不能对宿主根裸写。
    try std.testing.expect(std.mem.indexOf(u8, body, "mount --bind /dev /staging/dev") != null);
}

test "renderWrapperScript installroot target does not chroot" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, "/staging", "/tmp/nodeforge-namespaced-step.sh", .installroot);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "chroot") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sh /staging/tmp/nodeforge-namespaced-step.sh") != null);
}
