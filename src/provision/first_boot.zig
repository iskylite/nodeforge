//! # v0.2 无盘首启置备执行器（Phase 8）
//!
//! 切根+systemd 后由 `nodeforge-agent`（无参数，作为 systemd unit）调用。读取
//! pre-init 持久化的 AgentPlan（`/var/lib/nodeforge/agent-plan.json`），按八步执行
//! 契约的固定顺序 managed_file -> package -> archive -> script 应用 first-boot 步骤
//! 到 overlay 根。package action 只访问 AgentPlan 固定的 nodeforged 受管 HTTP
//! Yum/APT 源并显式禁用系统其他源；这不是远程任务下发。执行仍是一次性、
//! 无远程控制、无 reconciliation；失败只记日志、不阻断启动。
//!
//! 步骤内容可以内联，也可以引用 agent pre-init 已下载并校验的 content-addressed
//! payload；first-boot 本身不联网。
//! 渲染复用 `provision/runner.zig` 的安全不变量：目标路径必须绝对且不含 `..`，
//! 文件字节以 POSIX `printf %b` 八进制转义避免 shell 展开/注入。

const std = @import("std");
const dto = @import("../http/diskless_dto.zig");

const log_path = "/var/lib/nodeforge/firstboot.log";
const journal_path = "/var/lib/nodeforge/firstboot-journal.json";
/// 追加写入 firstboot.log（不截断）。diskless 下 /var/lib/nodeforge 位于 volatile
/// tmpfs upper，每次启动为空；追加保留同一启动内多次执行（如验证二次执行）的完整日志。
fn appendLog(io: std.Io, data: []const u8) void {
    const dir = std.Io.Dir.cwd();
    var file = dir.openFile(io, log_path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => dir.createFile(io, log_path, .{ .read = true, .truncate = false }) catch return,
        else => return,
    };
    defer file.close(io);
    const stat = file.stat(io) catch return;
    file.writePositionalAll(io, data, stat.size) catch return;
}

const JournalStatus = enum { succeeded, failed };

const JournalEntry = struct {
    key: []const u8,
    status: JournalStatus,
    attempts: u8,
};

const Journal = struct {
    schema_version: u32 = 1,
    session_id: []const u8,
    plan_digest: []const u8,
    entries: []const JournalEntry = &.{},
};

/// 读取持久化 AgentPlan JSON 并按八步顺序应用其 first-boot 步骤。
/// 返回失败步骤数（best-effort：失败不抛错、不阻断启动，详见日志）。
pub fn runFromPlanJson(io: std.Io, allocator: std.mem.Allocator, json: []const u8) usize {
    const P = struct {
        session_id: []const u8,
        plan_digest: []const u8,
        steps: []const dto.FirstBootStep = &.{},
        package_manager: ?dto.FirstBootPackageManager = null,
        repository_urls: []const []const u8 = &.{},
        first_boot_max_attempts: u8 = 1,
        first_boot_backoff_seconds: u32 = 0,
    };
    const parsed = std.json.parseFromSlice(P, allocator, json, .{ .ignore_unknown_fields = true }) catch return 0;
    defer parsed.deinit();
    return applyStepsJournaled(io, allocator, parsed.value);
}

/// 按固定顺序（managed_file -> package -> archive -> script）应用步骤。
pub fn applySteps(io: std.Io, allocator: std.mem.Allocator, steps: []const dto.FirstBootStep, package_manager: ?dto.FirstBootPackageManager, repository_urls: []const []const u8) usize {
    var log: std.Io.Writer.Allocating = .init(allocator);
    defer log.deinit();
    var failures: usize = 0;
    const order = [_]dto.FirstBootAction{ .managed_file, .package, .archive, .script };
    for (order) |act| {
        for (steps) |step| {
            if (step.action != act) continue;
            log.writer.print("[first-boot] step '{s}' ({s})\n", .{ step.id, @tagName(step.action) }) catch {};
            var cmd: std.Io.Writer.Allocating = .init(allocator);
            defer cmd.deinit();
            renderStep(&cmd.writer, step, package_manager, repository_urls, false, null) catch |err| {
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
    appendLog(io, log.written());
    return failures;
}

fn applyStepsJournaled(io: std.Io, allocator: std.mem.Allocator, plan: anytype) usize {
    var log: std.Io.Writer.Allocating = .init(allocator);
    defer log.deinit();
    var entries: std.ArrayList(JournalEntry) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.key);
        entries.deinit(allocator);
    }
    loadJournal(io, allocator, plan.session_id, plan.plan_digest, &entries);
    var failures: usize = 0;
    const order = [_]dto.FirstBootAction{ .managed_file, .package, .archive, .script };
    for (order) |act| for (plan.steps) |step| {
        if (step.action != act) continue;
        const key = if (step.idempotency_key.len == 0) step.id else step.idempotency_key;
        if (journalSucceeded(entries.items, key)) {
            log.writer.print("[first-boot] step '{s}' skipped (journal succeeded)\n", .{step.id}) catch {};
            continue;
        }
        var cmd: std.Io.Writer.Allocating = .init(allocator);
        defer cmd.deinit();
        renderStep(&cmd.writer, step, plan.package_manager, plan.repository_urls, false, null) catch |err| {
            failures += 1;
            upsertJournal(&entries, allocator, key, .failed, 1) catch {};
            persistJournal(io, allocator, plan.session_id, plan.plan_digest, entries.items) catch {};
            log.writer.print("[first-boot] step '{s}' render FAILED: {s}\n", .{ step.id, @errorName(err) }) catch {};
            continue;
        };
        const budget: u8 = if (step.retryable) @max(@as(u8, 1), plan.first_boot_max_attempts) else 1;
        var attempt: u8 = 0;
        var succeeded = false;
        while (attempt < budget) {
            attempt += 1;
            runShTimeout(io, allocator, cmd.written(), step.timeout_s) catch |err| {
                log.writer.print("[first-boot] step '{s}' attempt {d}/{d} FAILED: {s}\n", .{ step.id, attempt, budget, @errorName(err) }) catch {};
                if (attempt < budget and plan.first_boot_backoff_seconds != 0)
                    sleepSeconds(io, allocator, plan.first_boot_backoff_seconds);
                continue;
            };
            succeeded = true;
            break;
        }
        if (!succeeded) failures += 1;
        upsertJournal(&entries, allocator, key, if (succeeded) .succeeded else .failed, attempt) catch {};
        persistJournal(io, allocator, plan.session_id, plan.plan_digest, entries.items) catch {};
        if (succeeded) log.writer.print("[first-boot] step '{s}' ok after {d} attempt(s)\n", .{ step.id, attempt }) catch {};
    };
    log.writer.print("[first-boot] done: {d} failure(s)\n", .{failures}) catch {};
    appendLog(io, log.written());
    return failures;
}

fn loadJournal(io: std.Io, allocator: std.mem.Allocator, session_id: []const u8, plan_digest: []const u8, entries: *std.ArrayList(JournalEntry)) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, journal_path, allocator, .limited(1024 * 1024)) catch return;
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(Journal, allocator, bytes, .{ .allocate = .alloc_always }) catch return;
    defer parsed.deinit();
    if (parsed.value.schema_version != 1 or !std.mem.eql(u8, parsed.value.session_id, session_id) or !std.mem.eql(u8, parsed.value.plan_digest, plan_digest)) return;
    for (parsed.value.entries) |entry| entries.append(allocator, .{
        .key = allocator.dupe(u8, entry.key) catch return,
        .status = entry.status,
        .attempts = entry.attempts,
    }) catch return;
}

fn journalSucceeded(entries: []const JournalEntry, key: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.status == .succeeded;
    return false;
}

fn upsertJournal(entries: *std.ArrayList(JournalEntry), allocator: std.mem.Allocator, key: []const u8, status: JournalStatus, attempts: u8) !void {
    for (entries.items) |*entry| if (std.mem.eql(u8, entry.key, key)) {
        entry.status = status;
        entry.attempts = attempts;
        return;
    };
    try entries.append(allocator, .{ .key = try allocator.dupe(u8, key), .status = status, .attempts = attempts });
}

fn persistJournal(io: std.Io, allocator: std.mem.Allocator, session_id: []const u8, plan_digest: []const u8, entries: []const JournalEntry) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, Journal{ .session_id = session_id, .plan_digest = plan_digest, .entries = entries }, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    const tmp = "/var/lib/nodeforge/firstboot-journal.json.tmp";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes });
    try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), journal_path, io);
}

fn runShTimeout(io: std.Io, allocator: std.mem.Allocator, cmd: []const u8, timeout_s: u32) !void {
    if (timeout_s == 0 or timeout_s > 86400) return error.InvalidStepTimeout;
    const seconds = try std.fmt.allocPrint(allocator, "{d}", .{timeout_s});
    defer allocator.free(seconds);
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "timeout", "--signal=TERM", seconds, "/bin/sh", "-c", cmd } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return if (code == 124) error.StepTimedOut else error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
}

fn sleepSeconds(io: std.Io, allocator: std.mem.Allocator, seconds: u32) void {
    const value = std.fmt.allocPrint(allocator, "{d}", .{seconds}) catch return;
    defer allocator.free(value);
    const result = std.process.run(allocator, io, .{ .argv = &.{ "sleep", value } }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

/// 渲染单个步骤为一条 `/bin/sh -c` 命令字符串。first-boot 与 rootfs-build 共用本函数：
///   - `nogpgcheck`：rootfs-build 构建期为 true（ISO 导出的受管 HTTP 源未单独
///     签名，跳过 GPG）；first-boot 运行期为 false（强制 GPG 校验）。
///   - `installroot`：非 null（rootfs-build）时为 dnf 注入 `--installroot=<staging>`，
///     在 host 上下文安装到 staging，不进 chroot、不 bind-mount `/dev/proc/sys`，
///     规避单 worker daemon 自死锁与 bind-mount 清理风险；first-boot 传 null（chroot 到真根）。
///   - package 段以 `--disablerepo='*'` + `--repofrompath/--enablerepo` 把包安装
///     限制到 nodeforged 受管源，禁止访问系统/自由源。
pub fn renderStep(w: *std.Io.Writer, step: dto.FirstBootStep, package_manager: ?dto.FirstBootPackageManager, repository_urls: []const []const u8, nogpgcheck: bool, installroot: ?[]const u8) !void {
    switch (step.action) {
        .managed_file => {
            const dest = step.destination orelse return error.MissingDestination;
            try safeDest(dest);
            if (step.payload_path) |relative| {
                try w.writeAll("cp -- ");
                try writePayloadPath(w, relative);
                try w.writeByte(' ');
                try writeQuoted(w, dest);
            } else {
                try w.writeAll("printf '%b' '");
                try writeBytes(w, step.content orelse "");
                try w.writeAll("' > ");
                try writeQuoted(w, dest);
            }
            try w.print(" && chmod {o:0>3} ", .{step.mode});
            try writeQuoted(w, dest);
            try w.writeAll(" && chown ");
            try writeQuoted(w, step.owner);
            try w.writeByte(':');
            try writeQuoted(w, step.group);
            try w.writeByte(' ');
            try writeQuoted(w, dest);
        },
        .package => {
            if (step.packages.len == 0) return error.NoPackages;
            if (repository_urls.len == 0) return error.NoManagedRepository;
            switch (package_manager orelse return error.NoPackageManager) {
                .dnf => {
                    try w.writeAll("dnf -y");
                    // rootfs-build：在 host 上下文安装到 staging（--installroot），不进 chroot；first-boot 此处为 null。
                    if (installroot) |root| try w.print(" --installroot={s}", .{root});
                    // 禁用系统所有源，只允许下面声明的 nodeforged 受管源（local-only 保真）。
                    try w.writeAll(" --disablerepo='*'");
                    for (repository_urls, 0..) |url, index| {
                        try w.print(" --repofrompath=nodeforge-{d},", .{index});
                        try writeQuoted(w, url);
                        try w.print(" --enablerepo=nodeforge-{d}", .{index});
                    }
                    // 构建期 ISO 导出的受管 HTTP 源未签名才跳过 GPG；运行期强制校验。
                    if (nogpgcheck) try w.writeAll(" --nogpgcheck");
                    try w.writeAll(" install");
                    for (step.packages) |pkg| {
                        try w.writeByte(' ');
                        try writeQuoted(w, pkg);
                    }
                },
                .apt => {
                    try w.writeAll(": > /tmp/nodeforge.sources.list");
                    for (repository_urls) |url| {
                        try w.writeAll(" && printf 'deb [trusted=yes] %s ./\\n' ");
                        try writeQuoted(w, url);
                        try w.writeAll(" >> /tmp/nodeforge.sources.list");
                    }
                    try w.writeAll(" && apt-get -o Dir::Etc::sourcelist=/tmp/nodeforge.sources.list -o Dir::Etc::sourceparts=- update");
                    try w.writeAll(" && apt-get -y -o Dir::Etc::sourcelist=/tmp/nodeforge.sources.list -o Dir::Etc::sourceparts=- install");
                    for (step.packages) |pkg| {
                        try w.writeByte(' ');
                        try writeQuoted(w, pkg);
                    }
                },
            }
        },
        .archive => {
            const dest = step.destination orelse "/";
            try safeDest(dest);
            if (step.payload_path) |relative| {
                try w.writeAll("mkdir -p ");
                try writeQuoted(w, dest);
                try w.writeAll(" && tar -xf ");
                try writePayloadPath(w, relative);
                try w.writeAll(" -C ");
            } else {
                try w.writeAll("printf '%b' '");
                try writeBytes(w, step.content orelse "");
                try w.writeAll("' > /tmp/.nodeforge-arc && mkdir -p ");
                try writeQuoted(w, dest);
                try w.writeAll(" && tar -xf /tmp/.nodeforge-arc -C ");
            }
            try writeQuoted(w, dest);
            // BUG 修复：原代码使用 ` ; rm -f /tmp/.nodeforge-arc`，分号使 rm 无条件执行
            // 且其退出码（0）成为整条命令的最终退出码，掩盖了 tar 解压失败。
            // 改为 `&& rm` 确保仅解压成功后才删除临时文件；解压失败时退出码正确传播，
            // runShTimeout 才能检测到 SubprocessFailed 并计入 failures。
            // 临时文件在失败时不会被清理，但 first-boot 在 tmpfs upper 中运行，
            // 重启后自动清空，不存在持久泄漏风险。
            if (step.payload_path == null) try w.writeAll(" && rm -f /tmp/.nodeforge-arc");
        },
        .script => {
            if (step.payload_path) |relative| {
                try w.writeAll("sh ");
                try writePayloadPath(w, relative);
            } else {
                try w.writeAll("printf '%b' '");
                try writeBytes(w, step.content orelse "");
                // BUG 修复：原代码使用 ` ; rm -f /tmp/.nodeforge-script`，分号使 rm 的
                // 退出码（0）掩盖了 sh 脚本执行失败。改为 `&& rm` 确保仅脚本成功后才
                // 删除临时文件；脚本失败时退出码正确传播。
                try w.writeAll("' > /tmp/.nodeforge-script && sh /tmp/.nodeforge-script && rm -f /tmp/.nodeforge-script");
            }
        },
    }
}

fn writePayloadPath(w: *std.Io.Writer, relative: []const u8) !void {
    if (relative.len == 0 or relative[0] == '/' or std.mem.indexOfScalar(u8, relative, '%') != null)
        return error.InvalidPayloadPath;
    var parts = std.mem.splitScalar(u8, relative, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
        return error.InvalidPayloadPath;
    try w.writeAll("'/var/lib/nodeforge/payload/");
    for (relative) |c| if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    try w.writeByte('\'');
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
    try renderStep(&out.writer, .{ .id = "motd", .action = .managed_file, .content = "hi\n", .destination = "/etc/motd", .mode = 0o644 }, null, &.{}, false, null);
    const s = out.written();
    try std.testing.expect(std.mem.indexOf(u8, s, "printf '%b' '") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\\012") != null); // \n -> \012
    try std.testing.expect(std.mem.indexOf(u8, s, "chmod 644") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "chown 'root':'root' '/etc/motd'") != null);
}

test "renderStep rejects path traversal and relative paths" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidDestination, renderStep(&out.writer, .{ .id = "x", .action = .managed_file, .content = "y", .destination = "/etc/../etc/passwd" }, null, &.{}, false, null));
    try std.testing.expectError(error.InvalidDestination, renderStep(&out.writer, .{ .id = "x", .action = .managed_file, .content = "y", .destination = "relative/path" }, null, &.{}, false, null));
}

test "renderStep package emits dnf install and rejects empty list" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderStep(&out.writer, .{ .id = "pkgs", .action = .package, .packages = &.{ "tmux", "vim" } }, .dnf, &.{"http://10.0.2.2/repo"}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--disablerepo='*'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--repofrompath=nodeforge-0,'http://10.0.2.2/repo'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "install 'tmux' 'vim'") != null);
    try std.testing.expectError(error.NoPackages, renderStep(&out.writer, .{ .id = "p", .action = .package }, .dnf, &.{"http://10.0.2.2/repo"}, false, null));
    try std.testing.expectError(error.NoManagedRepository, renderStep(&out.writer, .{ .id = "p", .action = .package, .packages = &.{"vim"} }, .dnf, &.{}, false, null));
}

test "renderStep package omits nogpgcheck by default and emits it for build-time" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderStep(&out.writer, .{ .id = "pkgs", .action = .package, .packages = &.{"jq"} }, .dnf, &.{"http://10.0.2.2/repo"}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--nogpgcheck") == null);
    out.deinit();
    out = .init(std.testing.allocator);
    try renderStep(&out.writer, .{ .id = "pkgs", .action = .package, .packages = &.{"jq"} }, .dnf, &.{"http://10.0.2.2/repo"}, true, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "--nogpgcheck") != null);
}

test "renderStep package confines apt to nodeforged sources" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderStep(&out.writer, .{ .id = "pkgs", .action = .package, .packages = &.{"curl"} }, .apt, &.{"http://10.0.2.2/apt"}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Dir::Etc::sourcelist=/tmp/nodeforge.sources.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Dir::Etc::sourceparts=-") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "http://10.0.2.2/apt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "install 'curl'") != null);
}

test "renderStep archive and script render extraction/execution" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderStep(&out.writer, .{ .id = "a", .action = .archive, .content = "x", .destination = "/opt/app" }, null, &.{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "tar -xf /tmp/.nodeforge-arc -C '/opt/app'") != null);
    out.deinit();
    out = .init(std.testing.allocator);
    try renderStep(&out.writer, .{ .id = "s", .action = .script, .content = "echo hi\n" }, null, &.{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "sh /tmp/.nodeforge-script") != null);
}

test "renderStep consumes validated local payload without embedding bytes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderStep(&out.writer, .{ .id = "m", .action = .managed_file, .payload_path = "motd/3", .destination = "/etc/motd" }, null, &.{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "cp -- '/var/lib/nodeforge/payload/motd/3' '/etc/motd'") != null);
    out.deinit();
    out = .init(std.testing.allocator);
    try std.testing.expectError(error.InvalidPayloadPath, renderStep(&out.writer, .{ .id = "s", .action = .script, .payload_path = "../escape" }, null, &.{}, false, null));
}

test "journal upsert records attempts and succeeded entries become no-op" {
    var entries: std.ArrayList(JournalEntry) = .empty;
    defer {
        for (entries.items) |entry| std.testing.allocator.free(entry.key);
        entries.deinit(std.testing.allocator);
    }
    try upsertJournal(&entries, std.testing.allocator, "step-a", .failed, 2);
    try std.testing.expect(!journalSucceeded(entries.items, "step-a"));
    try upsertJournal(&entries, std.testing.allocator, "step-a", .succeeded, 3);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqual(@as(u8, 3), entries.items[0].attempts);
    try std.testing.expect(journalSucceeded(entries.items, "step-a"));
}
