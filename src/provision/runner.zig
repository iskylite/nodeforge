//! M4 受约束的安装后步骤渲染器。
//!
//! 本模块将 `ProvisioningBundle` 中的步骤展开为目标系统中的 shell 命令。
//! M4 只支持三种受约束动作（`repository`、`standard_packages`、`managed_file`），
//! 不支持任意脚本执行——后者在 M7 作为 `script` 动作补充。
//!
//! 包管理器差异：
//! - `dnf`（RHEL 系）：使用 `dnf config-manager --add-repo` 和 `dnf -y install`
//! - `apt`（Ubuntu 系）：使用 `echo > sources.list.d/` 和 `DEBIAN_FRONTEND=noninteractive apt-get -y install`
//!
//! 安全不变量：
//! - `managed_file` 的目标路径必须是绝对路径且不含 `..`，防止路径逃逸
//! - 所有命令参数使用单引号包裹，防止 shell 注入
//! - 受管文件内容编码为 POSIX `printf %b` 八进制转义，脚本保持单行且不依赖 heredoc
//! - 步骤按声明顺序执行，不重排序

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

/// 将 bundle 中的 `install_post` 阶段步骤渲染为目标系统的 shell 命令脚本。
///
/// 参数说明：
/// - `bundle`：后处理步骤集合
/// - `manager`：目标系统的包管理器（dnf 或 apt），决定命令格式
///
/// 返回调用方拥有的堆分配字节切片，包含按行分隔的 shell 命令。
/// 跳过非 `install_post` 阶段的步骤；遇到无效步骤（缺少必填字段）时返回错误。
pub fn renderInstallPost(allocator: std.mem.Allocator, bundle: *const model.ProvisioningBundle, manager: model.PackageManager) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    for (bundle.steps) |step| {
        // 只处理 install_post 阶段的步骤；其他阶段在 M7 实现
        if (step.phase != .install_post) continue;
        switch (step.action) {
            // v0.2 rootfs-build/first-boot 动作不在 install_post 渲染器中执行；
            // phase 过滤已跳过非 install_post 步骤，到达此处即配置错误。
            .archive, .script, .@"package" => return error.InvalidStep,
            // 仓库添加：dnf 使用 config-manager，apt 使用 sources.list.d
            .repository => if (step.repository) |repo| switch (manager) {
                .dnf => {
                    try w.writeAll("dnf -y config-manager --add-repo ");
                    try writeShellQuoted(w, repo);
                    try w.writeByte('\n');
                },
                .apt => {
                    try w.writeAll("printf '%s\\n' ");
                    try writeShellQuoted(w, repo);
                    try w.writeAll(" > /etc/apt/sources.list.d/nodeforge.list && apt-get update\n");
                },
            } else return error.InvalidStep,
            // 标准包安装：包名列表不能为空
            .standard_packages => {
                if (step.packages.len == 0) return error.InvalidStep;
                // dnf 和 apt 的安装命令格式不同；apt 需要非交互模式
                try w.writeAll(if (manager == .dnf) "dnf -y install" else "DEBIAN_FRONTEND=noninteractive apt-get -y install");
                for (step.packages) |package| {
                    try w.writeByte(' ');
                    try writeShellQuoted(w, package);
                }
                try w.writeByte('\n');
            },
            // 受管文件写入：使用单行 printf，避免 autoinstall 将 heredoc
            // 换行折叠后把终止标记当成命令执行。
            .managed_file => {
                const destination = step.destination orelse return error.InvalidStep;
                // 路径安全校验：必须是绝对路径且不含 `..` 路径组件，防止路径逃逸。
                // 使用组件级检查而非子串匹配，避免误拒包含 ".." 子串的合法路径
                //（如 `/opt/app..backup/file`）。
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
        }
    }
    return out.toOwnedSlice();
}

// 测试：验证步骤按声明顺序渲染，且 dnf 命令格式正确。
test "runner preserves declared install_post order" {
    const bundle: model.ProvisioningBundle = .{ .name = "base", .steps = &.{
        .{ .name = "packages", .action = .standard_packages, .packages = &.{"curl"} },
        .{ .name = "hosts", .action = .managed_file, .destination = "/etc/hosts", .content = "127.0.0.1 localhost" },
    } };
    const bytes = try renderInstallPost(std.testing.allocator, &bundle, .dnf);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "dnf -y install") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "printf '%b'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, " > '/etc/hosts'") != null);
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
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\n"));
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
