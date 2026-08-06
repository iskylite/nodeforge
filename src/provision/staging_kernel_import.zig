//! # Rootfs Staging 内核扫描与导入（v0.4.1）
//!
//! 扫描保留树内的内核与模块，支持 from-staging 时选择启动面内核。
//!
//! 两层「内核」必须分开（设计 §6.2）：
//! - A. Rootfs 用户态树内：`/lib/modules`、`/boot` 内文件打进 squashfs
//! - B. PXE/BootConfig 启动内核：catalog 中的 kernel 资产 + TFTP/HTTP 启动路径
//!
//! 本模块只负责扫描树内（层 A），不自动导入到启动面（层 B）。
//! from-staging 的 `--kernel-release` 选择在 CLI handler 中实现。

const std = @import("std");

/// 一个在保留树内发现的内核 release。
pub const KernelInfo = struct {
    /// `uname -r` 风格的 release 字符串，如 `5.14.0-362.el9.x86_64`。
    release: []const u8,
    /// 树内 `/boot/vmlinuz-<release>` 的绝对路径，null 表示未找到对应 vmlinuz。
    vmlinuz_path: ?[]const u8 = null,
    /// 树内 `/lib/modules/<release>` 的绝对路径，null 表示未找到 modules 目录。
    modules_path: ?[]const u8 = null,
    /// 树内 `/boot/initramfs-<release>.img` 或 `initrd-<release>` 的绝对路径（可选）。
    initramfs_path: ?[]const u8 = null,
};

/// 扫描保留树，返回发现的内核列表。
///
/// 扫描路径：
/// - `<staging>/lib/modules/*/` → 模块 releases
/// - `<staging>/boot/vmlinuz-*` → 内核镜像
/// - `<staging>/boot/initramfs-*` 或 `initrd-*` → 可选 initramfs
///
/// 合并策略：以 modules 目录的 release 为基准，匹配 vmlinuz 和 initramfs。
/// 只有 vmlinuz 而无 modules 的 release 也包含（但标记 modules_path=null）。
pub fn scanKernels(
    io: std.Io,
    allocator: std.mem.Allocator,
    staging: []const u8,
) ![]KernelInfo {
    var releases = std.StringHashMap(KernelInfo).init(allocator);
    defer {
        var iter = releases.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.vmlinuz_path) |p| allocator.free(p);
            if (entry.value_ptr.modules_path) |p| allocator.free(p);
            if (entry.value_ptr.initramfs_path) |p| allocator.free(p);
        }
        releases.deinit();
    }

    // 1. 扫描 /lib/modules/<release>/
    const modules_dir_path = try std.fmt.allocPrint(allocator, "{s}/lib/modules", .{staging});
    defer allocator.free(modules_dir_path);

    var modules_dir = std.Io.Dir.cwd().openDir(io, modules_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            // 没有 modules 目录，继续扫描 /boot
            return try scanBootOnly(io, allocator, staging);
        },
        else => return err,
    };
    defer modules_dir.close(io);

    var modules_iter = modules_dir.iterate();
    while (try modules_iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const release = try allocator.dupe(u8, entry.name);
        const mod_path = try std.fmt.allocPrint(allocator, "{s}/lib/modules/{s}", .{ staging, release });
        try releases.put(release, .{
            .release = release,
            .modules_path = mod_path,
        });
    }

    // 2. 扫描 /boot/vmlinuz-<release>
    const boot_dir_path = try std.fmt.allocPrint(allocator, "{s}/boot", .{staging});
    defer allocator.free(boot_dir_path);

    var boot_dir = std.Io.Dir.cwd().openDir(io, boot_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return finalizeResults(allocator, releases),
        else => return err,
    };
    defer boot_dir.close(io);

    var boot_iter = boot_dir.iterate();
    while (try boot_iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // 匹配 vmlinuz-<release>
        if (std.mem.startsWith(u8, entry.name, "vmlinuz-")) {
            const release_raw = entry.name["vmlinuz-".len..];
            const release = try allocator.dupe(u8, release_raw);
            const vmlinuz_full = try std.fmt.allocPrint(allocator, "{s}/boot/{s}", .{ staging, entry.name });
            if (releases.getPtr(release)) |existing| {
                existing.vmlinuz_path = vmlinuz_full;
                allocator.free(release);
            } else {
                try releases.put(release, .{
                    .release = release,
                    .vmlinuz_path = vmlinuz_full,
                });
            }
        }
        // 匹配 initramfs-<release>.img 或 initrd-<release>
        if (std.mem.startsWith(u8, entry.name, "initramfs-") or std.mem.startsWith(u8, entry.name, "initrd-")) {
            const prefix_len: usize = if (std.mem.startsWith(u8, entry.name, "initramfs-")) "initramfs-".len else "initrd-".len;
            // 去掉常见后缀 .img, .gz 等
            var release_raw = entry.name[prefix_len..];
            if (std.mem.endsWith(u8, release_raw, ".img")) release_raw = release_raw[0 .. release_raw.len - 4];
            if (std.mem.endsWith(u8, release_raw, ".gz")) release_raw = release_raw[0 .. release_raw.len - 3];
            const release = try allocator.dupe(u8, release_raw);
            const initramfs_full = try std.fmt.allocPrint(allocator, "{s}/boot/{s}", .{ staging, entry.name });
            if (releases.getPtr(release)) |existing| {
                existing.initramfs_path = initramfs_full;
                allocator.free(release);
            } else {
                try releases.put(release, .{
                    .release = release,
                    .initramfs_path = initramfs_full,
                });
            }
        }
    }

    return finalizeResults(allocator, releases);
}

/// 仅扫描 /boot 目录（无 /lib/modules 的情况）。
fn scanBootOnly(io: std.Io, allocator: std.mem.Allocator, staging: []const u8) ![]KernelInfo {
    var releases = std.StringHashMap(KernelInfo).init(allocator);
    defer {
        var iter = releases.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.vmlinuz_path) |p| allocator.free(p);
            if (entry.value_ptr.initramfs_path) |p| allocator.free(p);
        }
        releases.deinit();
    }

    const boot_dir_path = try std.fmt.allocPrint(allocator, "{s}/boot", .{staging});
    defer allocator.free(boot_dir_path);

    var boot_dir = std.Io.Dir.cwd().openDir(io, boot_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(KernelInfo, 0),
        else => return err,
    };
    defer boot_dir.close(io);

    var boot_iter = boot_dir.iterate();
    while (try boot_iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, "vmlinuz-")) {
            const release = try allocator.dupe(u8, entry.name["vmlinuz-".len..]);
            const vmlinuz_full = try std.fmt.allocPrint(allocator, "{s}/boot/{s}", .{ staging, entry.name });
            try releases.put(release, .{
                .release = release,
                .vmlinuz_path = vmlinuz_full,
            });
        }
    }

    return finalizeResults(allocator, releases);
}

/// 将 hashmap 转为排序后的数组。
fn finalizeResults(allocator: std.mem.Allocator, releases_in: std.StringHashMap(KernelInfo)) ![]KernelInfo {
    var releases = releases_in;
    var list = try std.ArrayList(KernelInfo).initCapacity(allocator, releases.count());
    defer list.deinit(allocator);

    // 收集所有 value（KernelInfo.release 与 hashmap key 指向同一块内存，
    // 所有权转移给 result 数组），然后清空 map 但不释放 key/value。
    var iter = releases.iterator();
    while (iter.next()) |entry| {
        try list.append(allocator, entry.value_ptr.*);
    }
    // 清空 map（clearRetainingCapacity 不释放 key/value 内存），
    // 这样调用方 defer 中的 iterator 不会重复释放。
    releases.clearRetainingCapacity();

    // 按 release 字母序排序
    std.mem.sort(KernelInfo, list.items, {}, struct {
        fn lt(_: void, a: KernelInfo, b: KernelInfo) bool {
            return std.mem.lessThan(u8, a.release, b.release);
        }
    }.lt);

    return try list.toOwnedSlice(allocator);
}

/// 格式化内核列表为人类可读文本（用于 CLI 输出）。
pub fn formatKernelList(allocator: std.mem.Allocator, kernels: []const KernelInfo) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();

    if (kernels.len == 0) {
        try buf.writer.writeAll("No kernels found in staging tree.\n");
        return try allocator.dupe(u8, buf.written());
    }

    try buf.writer.print("Found {d} kernel release(s):\n\n", .{kernels.len});
    try buf.writer.writeAll("release\t\tvmlinuz\tmodules\tinitramfs\n");
    for (kernels) |k| {
        try buf.writer.print("{s}\t", .{k.release});
        try buf.writer.writeAll(if (k.vmlinuz_path != null) "yes" else "no");
        try buf.writer.writeAll("\t");
        try buf.writer.writeAll(if (k.modules_path != null) "yes" else "no");
        try buf.writer.writeAll("\t");
        try buf.writer.writeAll(if (k.initramfs_path != null) "yes" else "no");
        try buf.writer.writeAll("\n");
        if (k.vmlinuz_path) |p| try buf.writer.print("  vmlinuz:   {s}\n", .{p});
        if (k.modules_path) |p| try buf.writer.print("  modules:   {s}\n", .{p});
        if (k.initramfs_path) |p| try buf.writer.print("  initramfs: {s}\n", .{p});
        try buf.writer.writeAll("\n");
    }

    return try allocator.dupe(u8, buf.written());
}

/// 释放 scanKernels 返回的数组。
pub fn freeKernels(allocator: std.mem.Allocator, kernels: []KernelInfo) void {
    for (kernels) |k| {
        allocator.free(k.release);
        if (k.vmlinuz_path) |p| allocator.free(p);
        if (k.modules_path) |p| allocator.free(p);
        if (k.initramfs_path) |p| allocator.free(p);
    }
    allocator.free(kernels);
}

/// 内核选择结果。
pub const KernelSelection = struct {
    /// 选定的 release 字符串（如 `5.14.0-362.el9.x86_64`）。
    release: []const u8,
    /// 树内 vmlinuz 绝对路径。
    vmlinuz_path: []const u8,
    /// 树内 modules 目录绝对路径（设计 §6.4：选中时必须存在）。
    modules_path: []const u8,
};

/// 是否可作为启动面候选：同时具备 vmlinuz 与 modules（设计 §6.4）。
pub fn isBootEligible(k: KernelInfo) bool {
    return k.vmlinuz_path != null and k.modules_path != null;
}

/// 根据 `--kernel-release` 模式从扫描结果中选择内核。
///
/// - `"keep"`：返回 `error.KernelSelectionNotNeeded`，调用方应跳过导入。
/// - `"auto"`：在 **可启动候选**（vmlinuz+modules）中，若提供 `current_release`，
///   则只考虑 **不同于** Profile 当前 release 的「新」核；恰好一个 → 选用，
///   0 个或多个 → fail closed（设计 §6.4）。
/// - 其他：视为显式 release，必须存在且同时有 vmlinuz 与 modules。
///
/// `current_release`：Profile/boot_bundle 当前记录的 kernel_release；auto 差集用。
pub fn selectKernel(kernels: []const KernelInfo, mode: []const u8, current_release: ?[]const u8) !KernelSelection {
    if (std.mem.eql(u8, mode, "keep")) return error.KernelSelectionNotNeeded;

    if (std.mem.eql(u8, mode, "auto")) {
        var chosen: ?KernelInfo = null;
        var count: usize = 0;
        for (kernels) |k| {
            if (!isBootEligible(k)) continue;
            if (current_release) |cur| {
                if (std.mem.eql(u8, k.release, cur)) continue; // 只认「新」于当前记录的核
            }
            count += 1;
            chosen = k;
        }
        if (count == 0) return error.NoKernelsFound;
        if (count > 1) return error.MultipleKernelsFound;
        const k = chosen.?;
        return .{
            .release = k.release,
            .vmlinuz_path = k.vmlinuz_path.?,
            .modules_path = k.modules_path.?,
        };
    }

    // 显式 release：必须 vmlinuz + modules
    for (kernels) |k| {
        if (!std.mem.eql(u8, k.release, mode)) continue;
        if (k.vmlinuz_path == null) return error.KernelVmlinuzNotFound;
        if (k.modules_path == null) return error.KernelModulesNotFound;
        return .{
            .release = k.release,
            .vmlinuz_path = k.vmlinuz_path.?,
            .modules_path = k.modules_path.?,
        };
    }
    return error.KernelReleaseNotFound;
}

// ── 测试 ──────────────────────────────────────────────────

test "scanKernels finds vmlinuz and modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root: []const u8 = root_buf[0..root_len];

    // Create /lib/modules/5.14.0-362.el9.x86_64/
    const mod_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/lib/modules/5.14.0-362.el9.x86_64", .{root});
    defer std.testing.allocator.free(mod_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, mod_dir);

    // Create /boot/vmlinuz-5.14.0-362.el9.x86_64
    const boot_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/boot", .{root});
    defer std.testing.allocator.free(boot_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, boot_dir);
    const vmlinuz = try std.fmt.allocPrint(std.testing.allocator, "{s}/boot/vmlinuz-5.14.0-362.el9.x86_64", .{root});
    defer std.testing.allocator.free(vmlinuz);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = vmlinuz, .data = "fake" });

    const kernels = try scanKernels(std.testing.io, std.testing.allocator, root);
    defer freeKernels(std.testing.allocator, kernels);

    try std.testing.expectEqual(@as(usize, 1), kernels.len);
    try std.testing.expectEqualStrings("5.14.0-362.el9.x86_64", kernels[0].release);
    try std.testing.expect(kernels[0].vmlinuz_path != null);
    try std.testing.expect(kernels[0].modules_path != null);
}

test "scanKernels handles missing /lib/modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root: []const u8 = root_buf[0..root_len];

    // Only create /boot/vmlinuz-6.1.0
    const boot_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/boot", .{root});
    defer std.testing.allocator.free(boot_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, boot_dir);
    const vmlinuz = try std.fmt.allocPrint(std.testing.allocator, "{s}/boot/vmlinuz-6.1.0", .{root});
    defer std.testing.allocator.free(vmlinuz);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = vmlinuz, .data = "fake" });

    const kernels = try scanKernels(std.testing.io, std.testing.allocator, root);
    defer freeKernels(std.testing.allocator, kernels);

    try std.testing.expectEqual(@as(usize, 1), kernels.len);
    try std.testing.expectEqualStrings("6.1.0", kernels[0].release);
    try std.testing.expect(kernels[0].vmlinuz_path != null);
    try std.testing.expect(kernels[0].modules_path == null);
}

test "scanKernels returns empty for tree without kernels" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root: []const u8 = root_buf[0..root_len];

    const kernels = try scanKernels(std.testing.io, std.testing.allocator, root);
    defer freeKernels(std.testing.allocator, kernels);

    try std.testing.expectEqual(@as(usize, 0), kernels.len);
}

test "formatKernelList produces human readable output" {
    const kernels = [_]KernelInfo{
        .{ .release = "5.14.0", .vmlinuz_path = "/boot/vmlinuz-5.14.0", .modules_path = "/lib/modules/5.14.0" },
        .{ .release = "6.1.0", .vmlinuz_path = null, .modules_path = null },
    };
    const text = try formatKernelList(std.testing.allocator, &kernels);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "5.14.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "6.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Found 2") != null);
}

test "selectKernel returns NotNeeded for keep" {
    const kernels = [_]KernelInfo{
        .{ .release = "5.14.0", .vmlinuz_path = "/boot/vmlinuz-5.14.0", .modules_path = "/lib/modules/5.14.0" },
    };
    try std.testing.expectError(error.KernelSelectionNotNeeded, selectKernel(&kernels, "keep", null));
}

test "selectKernel auto picks the single eligible kernel" {
    const kernels = [_]KernelInfo{
        .{ .release = "5.14.0", .vmlinuz_path = "/boot/vmlinuz-5.14.0", .modules_path = "/lib/modules/5.14.0" },
    };
    const sel = try selectKernel(&kernels, "auto", null);
    try std.testing.expectEqualStrings("5.14.0", sel.release);
    try std.testing.expectEqualStrings("/boot/vmlinuz-5.14.0", sel.vmlinuz_path);
    try std.testing.expectEqualStrings("/lib/modules/5.14.0", sel.modules_path);
}

test "selectKernel auto ignores current release and picks the new one" {
    const kernels = [_]KernelInfo{
        .{ .release = "5.14.0", .vmlinuz_path = "/boot/vmlinuz-5.14.0", .modules_path = "/lib/modules/5.14.0" },
        .{ .release = "6.1.0", .vmlinuz_path = "/boot/vmlinuz-6.1.0", .modules_path = "/lib/modules/6.1.0" },
    };
    const sel = try selectKernel(&kernels, "auto", "5.14.0");
    try std.testing.expectEqualStrings("6.1.0", sel.release);
}

test "selectKernel auto fails when multiple new kernels" {
    const kernels = [_]KernelInfo{
        .{ .release = "5.14.0", .vmlinuz_path = "/boot/vmlinuz-5.14.0", .modules_path = "/lib/modules/5.14.0" },
        .{ .release = "6.1.0", .vmlinuz_path = "/boot/vmlinuz-6.1.0", .modules_path = "/lib/modules/6.1.0" },
        .{ .release = "6.2.0", .vmlinuz_path = "/boot/vmlinuz-6.2.0", .modules_path = "/lib/modules/6.2.0" },
    };
    try std.testing.expectError(error.MultipleKernelsFound, selectKernel(&kernels, "auto", "5.14.0"));
}

test "selectKernel auto skips ineligible (no modules)" {
    const kernels = [_]KernelInfo{
        .{ .release = "6.1.0", .vmlinuz_path = "/boot/vmlinuz-6.1.0", .modules_path = null },
    };
    try std.testing.expectError(error.NoKernelsFound, selectKernel(&kernels, "auto", null));
}

test "selectKernel auto fails on zero kernels" {
    const kernels = [_]KernelInfo{};
    try std.testing.expectError(error.NoKernelsFound, selectKernel(&kernels, "auto", null));
}

test "selectKernel explicit release matches" {
    const kernels = [_]KernelInfo{
        .{ .release = "5.14.0", .vmlinuz_path = "/boot/vmlinuz-5.14.0", .modules_path = "/lib/modules/5.14.0" },
        .{ .release = "6.1.0", .vmlinuz_path = "/boot/vmlinuz-6.1.0", .modules_path = "/lib/modules/6.1.0" },
    };
    const sel = try selectKernel(&kernels, "6.1.0", null);
    try std.testing.expectEqualStrings("6.1.0", sel.release);
}

test "selectKernel explicit release not found" {
    const kernels = [_]KernelInfo{
        .{ .release = "5.14.0", .vmlinuz_path = "/boot/vmlinuz-5.14.0", .modules_path = "/lib/modules/5.14.0" },
    };
    try std.testing.expectError(error.KernelReleaseNotFound, selectKernel(&kernels, "9.9.9", null));
}

test "selectKernel fails when vmlinuz missing for explicit" {
    const kernels = [_]KernelInfo{
        .{ .release = "5.14.0", .vmlinuz_path = null, .modules_path = "/lib/modules/5.14.0" },
    };
    try std.testing.expectError(error.KernelVmlinuzNotFound, selectKernel(&kernels, "5.14.0", null));
}

test "selectKernel fails when modules missing for explicit" {
    const kernels = [_]KernelInfo{
        .{ .release = "5.14.0", .vmlinuz_path = "/boot/vmlinuz-5.14.0", .modules_path = null },
    };
    try std.testing.expectError(error.KernelModulesNotFound, selectKernel(&kernels, "5.14.0", null));
}
