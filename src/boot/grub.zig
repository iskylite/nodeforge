//! M1 UEFI PXE 启动的确定性 GRUB 配置渲染器。
//!
//! DHCP 策略不在此处实现：调用方提供已经解析完毕的路径和 kernel 命令行。
//! 本渲染器只输出 GRUB 可读取的小型配置文件，随后通过 TFTP 提供。
//!
//! 支持的架构：UEFI x86_64 使用 `grubx64.efi`，UEFI aarch64 使用 `grubaa64.efi`。
//! BIOS PXELINUX 支持在 M6 补齐。
//!
//! 指令选择：ARM64 `grubaa64.efi` 只含 `linux`/`initrd` 指令（不含 `linuxefi`/
//! `initrdefi` 模块）；x86_64 `grubx64.efi` 可能包含 `linuxefi`/`initrdefi` 模块，
//! 但其实际可用性需由真实 x86 GRUB 启动测试确认，不能仅凭二进制字符串决定。
//! 因此两种架构统一使用标准 `linux`/`initrd` 指令，这是 GRUB UEFI 模块的
//! 默认行为，兼容性最好。

const std = @import("std");
const model = @import("../model.zig");

/// GRUB 菜单项输入，由 boot target resolver 填充后传入渲染器。
///
/// 所有字段都是已验证的安全值：
/// - `node_id`：用于菜单项标题，不含特殊字符
/// - `kernel_path`/`initrd_path`：已通过 toGrubPath 安全校验的 GRUB 路径
/// - `cmdline`：由 resolveInstall/resolveDiskless 拼接的 kernel 命令行
/// - `arch`：用于选择 GRUB 指令（当前两种架构统一使用 linux/initrd）
pub const Entry = struct {
    node_id: []const u8,
    kernel_path: []const u8,
    initrd_path: []const u8,
    cmdline: []const u8,
    arch: model.Arch,
};

/// 渲染 UEFI GRUB 菜单项。
///
/// 输出格式是一个最小化的 `grub.cfg`，包含：
/// - `set timeout=5`：5 秒菜单超时，允许操作员在启动时看到菜单
/// - `menuentry`：以节点 ID 为标题的菜单项
/// - `linux` 指令：指定 kernel 路径和命令行参数
/// - `initrd` 指令：指定 initrd 路径
///
/// ARM64 和 x86_64 统一使用标准 `linux`/`initrd` 指令，因为标准 GRUB UEFI
/// 模块默认包含这两个指令。`linuxefi`/`initrdefi` 仅在特定发行版的 GRUB
/// 构建中可用，不能作为默认假设。
///
/// 路径应在调用前通过 asset-root 校验，且需要以 `/` 开头以符合 GRUB 语法。
/// 调用方（tftp/server.zig 中的 transferVirtualConfig）在 catalog 锁内
/// 为路径补充前导 `/` 后再调用本函数。
///
/// `buffer` 由调用方提供，渲染结果写入其中并返回有效切片。
pub fn render(buffer: []u8, entry: Entry) ![]const u8 {
    return std.fmt.bufPrint(buffer,
        "set timeout=5\n" ++
            "menuentry 'NodeForge {s}' {{\n" ++
            "  linux {s} {s}\n" ++
            "  initrd {s}\n" ++
            "}}\n",
        .{ entry.node_id, entry.kernel_path, entry.cmdline, entry.initrd_path },
    );
}

// 测试：ARM64 GRUB 条目使用标准 linux/initrd 指令，不含 linuxefi/initrdefi。
test "renders an ARM64 GRUB entry with linux/initrd" {
    var buffer: [512]u8 = undefined;
    const value = try render(&buffer, .{ .node_id = "node-a", .kernel_path = "/install/rocky/vmlinuz", .initrd_path = "/install/rocky/initrd.img", .cmdline = "ip=dhcp", .arch = .aarch64 });
    try std.testing.expect(std.mem.indexOf(u8, value, "linux /install/rocky/vmlinuz ip=dhcp") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "initrd /install/rocky/initrd.img") != null);
    // 确保不使用 linuxefi/initrdefi，因为 ARM64 GRUB 不含这些模块。
    try std.testing.expect(std.mem.indexOf(u8, value, "linuxefi") == null);
    try std.testing.expect(std.mem.indexOf(u8, value, "initrdefi") == null);
}

// 测试：x86_64 GRUB 条目也使用标准 linux/initrd 指令。
// 虽然 x86_64 GRUB 可能包含 linuxefi/initrdefi 模块，但统一使用 linux/initrd
// 更安全，因为标准 GRUB UEFI 模块默认包含这两个指令。
test "renders an x86_64 GRUB entry with linux/initrd" {
    var buffer: [512]u8 = undefined;
    const value = try render(&buffer, .{ .node_id = "node-x", .kernel_path = "/install/rocky/vmlinuz", .initrd_path = "/install/rocky/initrd.img", .cmdline = "ip=dhcp", .arch = .x86_64 });
    try std.testing.expect(std.mem.indexOf(u8, value, "linux /install/rocky/vmlinuz ip=dhcp") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "initrd /install/rocky/initrd.img") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "linuxefi") == null);
    try std.testing.expect(std.mem.indexOf(u8, value, "initrdefi") == null);
}

// 测试：菜单超时为 5 秒，确保操作员在 PXE 启动时能看到菜单。
test "timeout is 5 seconds for boot menu visibility" {
    var buffer: [512]u8 = undefined;
    const value = try render(&buffer, .{ .node_id = "node-a", .kernel_path = "/vmlinuz", .initrd_path = "/initrd.img", .cmdline = "ip=dhcp", .arch = .aarch64 });
    try std.testing.expect(std.mem.indexOf(u8, value, "set timeout=5") != null);
}
