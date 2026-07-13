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

fn writeShellQuoted(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |c| if (c == '\'') try writer.writeAll("'\\''") else try writer.writeByte(c);
    try writer.writeByte('\'');
}

/// Write arbitrary file bytes without embedding literal newlines in the
/// generated shell program. POSIX `printf %b` accepts `\0ddd` octal escapes;
/// encoding every byte also prevents shell expansion and delimiter injection.
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
                const content = step.content orelse return error.InvalidStep;
                // 路径安全校验：必须是绝对路径且不含 `..`，防止路径逃逸
                if (!std.mem.startsWith(u8, destination, "/") or std.mem.indexOf(u8, destination, "..") != null) return error.InvalidStep;
                try w.writeAll("install -d -m 0755 \"$(dirname -- ");
                try writeShellQuoted(w, destination);
                try w.writeAll(")\" && ");
                try writePrintfBytes(w, content);
                try w.writeAll(" > ");
                try writeShellQuoted(w, destination);
                try w.writeByte('\n');
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
