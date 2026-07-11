//! M1 UEFI PXE 启动的确定性 GRUB 配置渲染器。
//!
//! DHCP 策略不在此处实现：调用方提供已经解析完毕的路径和 kernel 命令行。
//! 本渲染器只输出 GRUB 可读取的小型配置文件，随后通过 TFTP 提供。
//!
//! 支持的架构：UEFI x86_64 使用 `grubx64.efi`，UEFI aarch64 使用 `grubaa64.efi`。
//! BIOS PXELINUX 支持在 M6 补齐。

const std = @import("std");

pub const Entry = struct {
    node_id: []const u8,
    kernel_path: []const u8,
    initrd_path: []const u8,
    cmdline: []const u8,
};

/// 渲染 UEFI GRUB 菜单项，使用固定的 5 秒 NodeForge 超时。
///
/// 路径应在调用前通过 asset-root 校验。`linuxefi`/`initrdefi` 指令用于
/// UEFI 模式下的 GRUB；BIOS 模式使用不同的指令集。
pub fn render(buffer: []u8, entry: Entry) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        "set timeout=5\n" ++
            "menuentry 'NodeForge {s}' {{\n" ++
            "  linuxefi {s} {s}\n" ++
            "  initrdefi {s}\n" ++
            "}}\n",
        .{ entry.node_id, entry.kernel_path, entry.cmdline, entry.initrd_path },
    );
}

test "renders a GRUB UEFI entry" {
    var buffer: [512]u8 = undefined;
    const value = try render(&buffer, .{ .node_id = "node-a", .kernel_path = "/vmlinuz", .initrd_path = "/initrd.img", .cmdline = "ip=dhcp" });
    try std.testing.expect(std.mem.indexOf(u8, value, "linuxefi /vmlinuz ip=dhcp") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "initrdefi /initrd.img") != null);
}
