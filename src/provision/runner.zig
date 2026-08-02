//! install-post canonical 步骤渲染器（v0.3）。
//!
//! 本模块将 `ProvisioningBundle` 中的 `install_post` 阶段步骤展开为目标系统中的
//! shell 命令脚本。v0.3 把 install-post 从受限形态（`repository`/`standard_packages`/
//! `managed_file`）升级为完整 canonical phase，与 rootfs-build/first-boot 统一执行
//! 模型：四类 canonical action（`managed_file`/`archive`/`script`/`package`），固定
//! 执行顺序 `managed_file -> package -> archive -> script`。
//!
//! 旧 `repository`/`standard_packages` action 已退出，parser/validator 直接拒绝，
//! renderer 同样返回 `error.InvalidStep`，不提供迁移分支。
//!
//! 包管理器差异：
//! - `dnf`（RHEL 系）：使用 `dnf -y install`
//! - `apt`（Ubuntu 系）：使用 `DEBIAN_FRONTEND=noninteractive apt-get -y install`
//!
//! 安全不变量：
//! - `managed_file` 的目标路径必须是绝对路径且不含 `..`，防止路径逃逸
//! - 所有命令参数使用单引号包裹，防止 shell 注入
//! - 受管文件内容编码为 POSIX `printf %b` 八进制转义，脚本保持单行且不依赖 heredoc
//! - 四类 action 按固定顺序执行（managed_file -> package -> archive -> script），
//!   同一 action 内按 bundle 声明顺序执行，不重排序

const std = @import("std");
const model = @import("../model.zig");

/// 检查路径是否包含 `..` 路径组件（而非子串），用于防止路径逃逸。
/// 以 `/` 为分隔符逐段检查，只有完整的 `..` 组件才返回 true。
/// 例如 `/opt/app..backup/file` 返回 false（合法），`/opt/../etc` 返回 true（逃逸）。
fn containsDotDotComponent(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return true;
    }
    return false;
}

/// 将字符串用单引号包裹以安全嵌入 shell 命令。字符串内的单引号通过
/// `'\''` 转义，这是 POSIX shell 中在单引号字符串中嵌入单引号的标准方法。
fn writeShellQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |c| if (c == '\'') try writer.writeAll("'\\''") else try writer.writeByte(c);
    try writer.writeByte('\'');
}

/// 写入任意文件字节，不在生成的 shell 程序中嵌入字面换行符。
/// POSIX `printf %b` 接受 `\0ddd` 八进制转义；逐字节编码也防止了
/// shell 展开和分隔符注入。
fn writePrintfBytes(writer: *std.Io.Writer, content: []const u8) !void {
    try writer.writeAll("printf '%b' '");
    for (content) |byte| try writer.print("\\0{o:0>3}", .{byte});
    try writer.writeByte('\'');
}

/// 渲染 archive 运行时模式 A/B 判定与解压脚本。
///
/// 此函数是 install-post、rootfs-build 和 first-boot 三个 phase 共享的 archive
/// 执行逻辑。判定规则（v0.2 设计 §5.4 冻结）：
///
/// 1. 用 `tar -tf` 读取条目列表（不解压）；
/// 2. 规范化可选的 `./` 前缀后，检查顶层是否存在精确 `install.sh`；
/// 3. 存在则模式 A：解压到临时目录 + 执行 `sh ./install.sh`；
/// 4. 不存在则模式 B：直接解压到目标根。
///
/// 子目录 `install.sh`（如 `app/install.sh`）不触发模式 A；不得通过路径规范化
/// 把含 `..` 的条目提升为顶层 `install.sh`。
///
/// 脚本以单行 `{ if ! ENTRIES=$(tar -tf ...); then exit 1; fi; if ...; then ...; else ...; fi; }` 渲染。
/// 这在 Kickstart `%post`（多行）和 Ubuntu `late-commands`（换行转 `&&`）中
/// 都能正确执行。
///
/// `tar -tf` 失败必须令 action 失败，不能静默跳过并继续发布成功状态。
///
/// 参数：
/// - `w`：输出 writer
/// - `archive_expr`：shell 表达式，求值为 archive 文件路径（如 `"$ARCFILE"` 或
///   `'/tmp/.nodeforge-arc'`）。调用方负责正确引用。
/// - `target_root`：模式 B 解压目标根（如 `/`）。函数内部用 `writeShellQuoted` 引用。
pub fn renderArchiveModeDetection(w: *std.Io.Writer, archive_expr: []const u8, target_root: []const u8) !void {
    try w.writeAll("{ if ! ENTRIES=$(timeout 10 tar -tf ");
    try w.writeAll(archive_expr);
    try w.writeAll("); then exit 1; fi; if printf '%s\\n' \"$ENTRIES\" | sed 's#^\\./##' | grep -Fxq 'install.sh'; then TMPDIR=$(mktemp -d /tmp/.nodeforge-arc-XXXXXX) && timeout 30 tar -xf ");
    try w.writeAll(archive_expr);
    try w.writeAll(" -C \"$TMPDIR\" && ( cd \"$TMPDIR\" && timeout 30 sh ./install.sh ) && rm -rf \"$TMPDIR\"; else timeout 30 tar -xf ");
    try w.writeAll(archive_expr);
    try w.writeAll(" -C ");
    try writeShellQuoted(w, target_root);
    try w.writeAll("; fi; }");
}

/// 将 bundle 中的 `install_post` 阶段步骤渲染为目标系统的 shell 命令脚本。
///
/// v0.3 将 install-post 扩展为完整 canonical phase，与 rootfs-build/first-boot
/// 统一执行模型。四类 canonical action 按固定顺序执行：
/// `managed_file -> package -> archive -> script`。
///
/// 参数说明：
/// - `bundle`：后处理步骤集合
/// - `manager`：目标系统的包管理器（dnf 或 apt），决定命令格式
///
/// 返回调用方拥有的堆分配字节切片，包含按行分隔的 shell 命令。
/// 跳过非 `install_post` 阶段的步骤；遇到无效步骤（缺少必填字段）或旧
/// `repository`/`standard_packages` action 时返回 `error.InvalidStep`。
pub fn renderInstallPost(allocator: std.mem.Allocator, bundle: *const model.ProvisioningBundle, manager: model.PackageManager) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    // 先扫描一次：拒绝旧 action，不迁移、不兼容。
    for (bundle.steps) |step| {
        if (step.phase != .install_post) continue;
        switch (step.action) {
            .repository, .standard_packages => return error.InvalidStep,
            else => {},
        }
    }

    // 固定执行顺序：managed_file -> package -> archive -> script。
    // 同一 action 内按 bundle 声明顺序执行，不重排序。
    const order = [_]model.ProvisionAction{ .managed_file, .package, .archive, .script };

    for (order) |act| {
        for (bundle.steps) |step| {
            if (step.phase != .install_post) continue;
            if (step.action != act) continue;

            switch (step.action) {
                // 旧 action 已在预扫描中拒绝，此处不会到达。
                .repository, .standard_packages => unreachable,

                // 受管文件写入：使用单行 printf，避免 autoinstall 将 heredoc
                // 换行折叠后把终止标记当成命令执行。
                .managed_file => {
                    const destination = step.destination orelse return error.InvalidStep;
                    // 路径安全校验：必须是绝对路径且不含 `..` 路径组件，防止路径逃逸。
                    if (!std.mem.startsWith(u8, destination, "/") or containsDotDotComponent(destination)) return error.InvalidStep;
                    try w.writeAll("install -d -m 0755 \"$(dirname -- ");
                    try writeShellQuoted(w, destination);
                    try w.writeAll(")\" && ");
                    if (step.content_asset != null) {
                        const url = step.content_url orelse return error.InvalidStep;
                        const digest = step.content_sha256 orelse return error.InvalidStep;
                        try w.writeAll("curl -fsS --output ");
                        try writeShellQuoted(w, destination);
                        try w.writeByte(' ');
                        try writeShellQuoted(w, url);
                        try w.writeAll(" && printf '%s  %s\\n' ");
                        try writeShellQuoted(w, digest);
                        try w.writeByte(' ');
                        try writeShellQuoted(w, destination);
                        try w.writeAll(" | sha256sum -c - && chmod ");
                        try w.print("{o:0>4} ", .{step.mode});
                        try writeShellQuoted(w, destination);
                        try w.writeAll(" && chown ");
                        try writeShellQuoted(w, step.owner);
                        try w.writeByte(':');
                        try writeShellQuoted(w, step.group);
                        try w.writeByte(' ');
                        try writeShellQuoted(w, destination);
                        try w.writeByte('\n');
                    } else {
                        const content = step.content orelse return error.InvalidStep;
                        try writePrintfBytes(w, content);
                        try w.writeAll(" > ");
                        try writeShellQuoted(w, destination);
                        try w.writeByte('\n');
                    }
                },

                // package action：安装包列表。install-post 上下文中，managed
                // repository 已由适配器写入目标系统（/etc/yum.repos.d/nodeforge.repo
                // 或 /etc/apt/sources.list.d/nodeforge.list），因此直接使用 dnf/apt
                // 安装即可，package 引用的是 pinned effective software/capability。
                .package => {
                    if (step.packages.len == 0) return error.InvalidStep;
                    try w.writeAll(if (manager == .dnf) "dnf -y install" else "DEBIAN_FRONTEND=noninteractive apt-get -y install");
                    for (step.packages) |package| {
                        try w.writeByte(' ');
                        try writeShellQuoted(w, package);
                    }
                    try w.writeByte('\n');
                },

                // archive action：下载 catalog asset 到临时文件，校验 digest，
                // 然后运行时自判定模式 A（./install.sh 存在 -> 解压到临时目录 +
                // 执行）或模式 B（直接解压到目标根 /）。
                // archive 只允许引用 catalog asset（content_asset + content_url +
                // content_sha256），禁止 inline content；没有 destination 字段，
                // 目标根由执行上下文决定（install-post 为 /）。
                .archive => {
                    const url = step.content_url orelse return error.InvalidStep;
                    const digest = step.content_sha256 orelse return error.InvalidStep;
                    // 下载到临时文件 + digest 校验 + 模式 A/B 判定 + 清理
                    try w.writeAll("ARCFILE=$(mktemp /tmp/.nodeforge-arc-XXXXXX) && curl -fsS --output \"$ARCFILE\" ");
                    try writeShellQuoted(w, url);
                    try w.writeAll(" && printf '%s  %s\\n' ");
                    try writeShellQuoted(w, digest);
                    try w.writeAll(" \"$ARCFILE\" | sha256sum -c - && ");
                    try renderArchiveModeDetection(w, "\"$ARCFILE\"", "/");
                    try w.writeAll(" && rm -f \"$ARCFILE\"\n");
                },

                // script action：下载 catalog asset 到临时文件，校验 digest，
                // 然后用 sh 执行，执行后清理临时文件。
                // script 只允许引用 catalog asset（content_asset + content_url +
                // content_sha256），禁止 inline content。
                .script => {
                    const url = step.content_url orelse return error.InvalidStep;
                    const digest = step.content_sha256 orelse return error.InvalidStep;
                    try w.writeAll("SCRFILE=$(mktemp /tmp/.nodeforge-script-XXXXXX) && curl -fsS --output \"$SCRFILE\" ");
                    try writeShellQuoted(w, url);
                    try w.writeAll(" && printf '%s  %s\\n' ");
                    try writeShellQuoted(w, digest);
                    try w.writeAll(" \"$SCRFILE\" | sha256sum -c - && sh \"$SCRFILE\" && rm -f \"$SCRFILE\"\n");
                },
            }
        }
    }
    return out.toOwnedSlice();
}

pub const Callback = struct {
    event_url: []const u8,
    token: []const u8,
    boot_session_id: []const u8,
    max_attempts: u8 = 3,
};

/// 渲染带认证的 install-post step/attempt 与 finalizer callback。
///
/// 任一 callback 失败都按终止错误处理：daemon 未持久接受已执行 action 的状态迁移时，
/// installer 不得继续发布 `install.completed`，否则会绕过 canonical completion gate。
pub fn renderInstallPostInstrumented(allocator: std.mem.Allocator, bundle: *const model.ProvisioningBundle, manager: model.PackageManager, callback: Callback) ![]u8 {
    if (callback.max_attempts == 0) return error.InvalidStep;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("nf_post_event() { curl -fsS -H ");
    const authorization = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{callback.token});
    defer allocator.free(authorization);
    try writeShellQuoted(w, authorization);
    try w.writeAll(" -H ");
    const session_header = try std.fmt.allocPrint(allocator, "X-NodeForge-Session: {s}", .{callback.boot_session_id});
    defer allocator.free(session_header);
    try writeShellQuoted(w, session_header);
    try w.writeAll(" -H 'Content-Type: application/json' -d \"{\\\"v\\\":1,\\\"boot_session_id\\\":\\\"");
    try w.writeAll(callback.boot_session_id);
    try w.writeAll("\\\",\\\"stage\\\":\\\"$1\\\",\\\"step_id\\\":\\\"$2\\\",\\\"attempt\\\":$3}\" ");
    try writeShellQuoted(w, callback.event_url);
    try w.writeAll("; }\n");

    const order = [_]model.ProvisionAction{ .managed_file, .package, .archive, .script };
    for (order) |action| for (bundle.steps) |step| {
        if (step.phase != .install_post or step.action != action) continue;
        const one = model.ProvisioningBundle{ .name = bundle.name, .version = bundle.version, .revision = bundle.revision, .steps = &.{step} };
        const command = try renderInstallPost(allocator, &one, manager);
        defer allocator.free(command);
        const step_id = if (step.idempotency_key.len != 0) step.idempotency_key else step.name;
        if (!validCallbackStepId(step_id)) return error.InvalidStep;
        try w.writeAll("NF_ATTEMPT=1; while :; do nf_post_event post_step_started ");
        try writeShellQuoted(w, step_id);
        try w.print(" \"$NF_ATTEMPT\" || exit 1; if timeout {d} sh -c ", .{step.timeout_s});
        try writeShellQuoted(w, std.mem.trim(u8, command, "\r\n"));
        try w.writeAll("; then nf_post_event post_step_succeeded ");
        try writeShellQuoted(w, step_id);
        try w.writeAll(" \"$NF_ATTEMPT\" || exit 1; break; fi; ");
        if (step.retryable) {
            try w.print("if [ \"$NF_ATTEMPT\" -lt {d} ]; then nf_post_event post_step_failed_retryable ", .{callback.max_attempts});
            try writeShellQuoted(w, step_id);
            try w.writeAll(" \"$NF_ATTEMPT\" || exit 1; NF_ATTEMPT=$((NF_ATTEMPT + 1)); continue; fi; ");
        }
        try w.writeAll("nf_post_event post_step_failed_terminal ");
        try writeShellQuoted(w, step_id);
        try w.writeAll(" \"$NF_ATTEMPT\" || true; exit 1; done\n");
    };
    try w.writeAll("nf_post_event post_finalizer_started '@finalizer' 1 || exit 1\n");
    try w.writeAll("nf_post_event post_finalizer_succeeded '@finalizer' 1 || exit 1\n");
    return out.toOwnedSlice();
}

fn validCallbackStepId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '@')) return false;
    return true;
}

// ── 测试 ──────────────────────────────────────────────────────────────

test "renderInstallPost rejects legacy repository and standard_packages actions" {
    const bundle_repo: model.ProvisioningBundle = .{ .name = "legacy", .steps = &.{.{ .name = "repo", .action = .repository, .repository = "http://repo" }} };
    try std.testing.expectError(error.InvalidStep, renderInstallPost(std.testing.allocator, &bundle_repo, .dnf));

    const bundle_pkgs: model.ProvisioningBundle = .{ .name = "legacy", .steps = &.{.{ .name = "pkgs", .action = .standard_packages, .packages = &.{"curl"} }} };
    try std.testing.expectError(error.InvalidStep, renderInstallPost(std.testing.allocator, &bundle_pkgs, .dnf));
}

test "renderInstallPost renders canonical package action" {
    const bundle: model.ProvisioningBundle = .{ .name = "base", .steps = &.{
        .{ .name = "pkgs", .action = .package, .packages = &.{ "tmux", "nmap" } },
    } };
    const bytes = try renderInstallPost(std.testing.allocator, &bundle, .dnf);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "dnf -y install 'tmux' 'nmap'") != null);
}

test "renderInstallPost renders apt package action" {
    const bundle: model.ProvisioningBundle = .{ .name = "base", .steps = &.{
        .{ .name = "pkgs", .action = .package, .packages = &.{"curl"} },
    } };
    const bytes = try renderInstallPost(std.testing.allocator, &bundle, .apt);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "DEBIAN_FRONTEND=noninteractive apt-get -y install 'curl'") != null);
}

test "renderInstallPost preserves fixed action order managed_file package archive script" {
    // 声明顺序故意打乱：script, archive, package, managed_file
    // 固定执行顺序应为：managed_file, package, archive, script
    const bundle: model.ProvisioningBundle = .{ .name = "ordered", .steps = &.{
        .{ .name = "s1", .action = .script, .content_url = "http://srv/script", .content_sha256 = "aaaa" },
        .{ .name = "a1", .action = .archive, .content_url = "http://srv/archive", .content_sha256 = "bbbb" },
        .{ .name = "p1", .action = .package, .packages = &.{"vim"} },
        .{ .name = "m1", .action = .managed_file, .destination = "/etc/motd", .content = "hello" },
    } };
    const bytes = try renderInstallPost(std.testing.allocator, &bundle, .dnf);
    defer std.testing.allocator.free(bytes);
    // 验证固定顺序：managed_file 在 package 前，package 在 archive 前，archive 在 script 前
    const motd_pos = std.mem.indexOf(u8, bytes, "/etc/motd").?;
    const pkg_pos = std.mem.indexOf(u8, bytes, "dnf -y install").?;
    const arc_pos = std.mem.indexOf(u8, bytes, "ARCFILE=").?;
    const scr_pos = std.mem.indexOf(u8, bytes, "SCRFILE=").?;
    try std.testing.expect(motd_pos < pkg_pos);
    try std.testing.expect(pkg_pos < arc_pos);
    try std.testing.expect(arc_pos < scr_pos);
}

test "renderInstallPost archive renders mode A/B detection" {
    const bundle: model.ProvisioningBundle = .{ .name = "arc", .steps = &.{
        .{ .name = "app", .action = .archive, .content_url = "http://srv/app.tar", .content_sha256 = "0123456789abcdef" },
    } };
    const bytes = try renderInstallPost(std.testing.allocator, &bundle, .dnf);
    defer std.testing.allocator.free(bytes);
    // 验证下载 + digest 校验
    try std.testing.expect(std.mem.indexOf(u8, bytes, "curl -fsS --output \"$ARCFILE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sha256sum -c -") != null);
    // 验证模式 A/B 判定
    try std.testing.expect(std.mem.indexOf(u8, bytes, "tar -tf") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "grep -Fxq 'install.sh'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "mktemp -d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sh ./install.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "tar -xf \"$ARCFILE\" -C") != null);
    // 验证清理
    try std.testing.expect(std.mem.indexOf(u8, bytes, "rm -f \"$ARCFILE\"") != null);
}

test "renderInstallPost script downloads and executes" {
    const bundle: model.ProvisioningBundle = .{ .name = "scr", .steps = &.{
        .{ .name = "setup", .action = .script, .content_url = "http://srv/setup.sh", .content_sha256 = "abcdef" },
    } };
    const bytes = try renderInstallPost(std.testing.allocator, &bundle, .dnf);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "curl -fsS --output \"$SCRFILE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sha256sum -c -") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sh \"$SCRFILE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "rm -f \"$SCRFILE\"") != null);
}

test "managed file rendering is single-line and heredoc-free" {
    const bundle: model.ProvisioningBundle = .{ .name = "base", .steps = &.{
        .{ .name = "hosts", .action = .managed_file, .destination = "/etc/hosts.d/nodeforge", .content = "127.0.0.1 localhost\nline'2" },
    } };
    const bytes = try renderInstallPost(std.testing.allocator, &bundle, .apt);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "NODEFORGE_EOF") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "printf '%b'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\\0012") != null);
}

test "canonical managed file downloads immutable revision and verifies digest" {
    const bundle: model.ProvisioningBundle = .{ .name = "base", .steps = &.{.{
        .name = "motd",
        .action = .managed_file,
        .destination = "/etc/motd",
        .content_asset = "motd",
        .content_url = "http://192.0.2.1/artifacts/managed-files/motd/2",
        .content_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .mode = 0o640,
        .owner = "root",
        .group = "adm",
    }} };
    const bytes = try renderInstallPost(std.testing.allocator, &bundle, .dnf);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "artifacts/managed-files/motd/2") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sha256sum -c -") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "chmod 0640") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "chown 'root':'adm'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "printf '%b'") == null);
}

test "renderArchiveModeDetection produces valid single-line if/then/else/fi" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderArchiveModeDetection(&out.writer, "\"$ARCFILE\"", "/");
    const s = out.written();
    // 验证单行（无换行）
    try std.testing.expect(std.mem.indexOf(u8, s, "\n") == null);
    // 使用显式 if 保留 tar 错误，避免 `set -e`/命令替换的可移植性差异。
    try std.testing.expect(std.mem.indexOf(u8, s, "|| exit 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, s, "if ! ENTRIES=$(timeout 10 tar -tf") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "then exit 1; fi") != null);
    // 验证内层 if/then/else/fi 结构
    try std.testing.expect(std.mem.indexOf(u8, s, "fi; if printf") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "then") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "else") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "fi; }") != null);
    // 验证模式 A：解压到临时目录 + 执行 install.sh
    try std.testing.expect(std.mem.indexOf(u8, s, "mktemp -d") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "sh ./install.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "rm -rf \"$TMPDIR\"") != null);
    // 验证模式 B：直接解压到目标根
    try std.testing.expect(std.mem.indexOf(u8, s, "tar -xf \"$ARCFILE\" -C '/'") != null);
}

test "instrumented install-post emits ordered attempts and finalizer callbacks" {
    const bundle: model.ProvisioningBundle = .{ .name = "callbacks", .revision = 7, .steps = &.{
        .{ .name = "script-last", .idempotency_key = "script-v1", .action = .script, .content_url = "http://srv/script", .content_sha256 = "aa" },
        .{ .name = "file-first", .idempotency_key = "file-v1", .action = .managed_file, .destination = "/etc/motd", .content = "ok", .retryable = true },
    } };
    const bytes = try renderInstallPostInstrumented(std.testing.allocator, &bundle, .dnf, .{
        .event_url = "http://srv/events",
        .token = "secret",
        .boot_session_id = "0123456789abcdef0123456789abcdef",
    });
    defer std.testing.allocator.free(bytes);
    const file_pos = std.mem.indexOf(u8, bytes, "'file-v1'").?;
    const script_pos = std.mem.indexOf(u8, bytes, "'script-v1'").?;
    try std.testing.expect(file_pos < script_pos);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "post_step_started") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "post_step_failed_retryable") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "NF_ATTEMPT=$((NF_ATTEMPT + 1))") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "post_finalizer_succeeded '@finalizer' 1") != null);
}
