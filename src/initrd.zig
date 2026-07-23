//! # nodeforge-initrd（v0.2 diskless 启动 init）
//!
//! `V0_2_DESIGN.md` §4.3 boot-time 序列。作为 dracut initrd 的 PID 1，在获得网络后：
//! 从 per-session credential capsule 读取 config token -> 有界重放拉取 BootConfig v2 ->
//! 下载并 SHA-512 校验 rootfs -> loop 挂载只读 lower + tmpfs upper -> overlay 合并 ->
//! 写 `/var/lib/nodeforge/boot.json` handoff（AgentPlan locator 与 agent/event token）->
//! 清除 config/rootfs token -> `switch_root` 执行 `nodeforge-agent --pre-init`。
//!
//! 本程序运行在 dracut 提供的最小 userspace（含 `ip`/`dhclient`/`curl`/`mount`/
//! `losetup`/`switch_root`）中，自身只编排与校验，不实现第二套网络/挂载栈。
//! 切根前清零 capability；raw token 只驻内存（来自 capsule），不落盘。
//! `switch_root` 以 `execve`（replace）接管 PID 1：子进程无法删除 PID-1 旧根。
const std = @import("std");

const capsule_token_path = "/capsule/config-token";
const cmdline_path = "/proc/cmdline";
const handoff_dir = "/merged/var/lib/nodeforge";
const handoff_path = "/merged/var/lib/nodeforge/boot.json";
const rootfs_blob = "/run/rootfs.squashfs";
const lower_mnt = "/lower";
const rw_mnt = "/rw";
const merged_mnt = "/merged";

const Cmdline = struct {
    config_url: ?[]const u8 = null,
    node: ?[]const u8 = null,
    session: ?[]const u8 = null,
    kernel_args: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    try mustRun(io, allocator, &.{ "mount", "-t", "proc", "proc", "/proc" });
    try mustRun(io, allocator, &.{ "mount", "-t", "sysfs", "sysfs", "/sys" });
    try mustRun(io, allocator, &.{ "mount", "-t", "devtmpfs", "devtmpfs", "/dev" });

    const cmdline = try readCmdline(io, allocator);
    defer freeCmdline(allocator, cmdline);

    // 基本网络：链路 up + DHCP（dracut 环境提供 dhclient/udhcpc）。
    try bringUpNetwork(io, allocator);

    const token = try readFile(io, allocator, capsule_token_path);
    defer allocator.free(token);

    // 拉取 BootConfig v2（config:read token，有界重放）。
    const config_json = try curlGet(io, allocator, cmdline.config_url orelse return error.MissingConfigUrl, token, cmdline.session);
    defer allocator.free(config_json);
    const bc = try parseBootConfig(allocator, config_json);
    defer freeBootConfig(allocator, &bc);

    // 下载 rootfs 并 SHA-512 校验。
    try curlDownload(io, allocator, bc.rootfs_url, token, cmdline.session, rootfs_blob);
    verifySha512(io, allocator, rootfs_blob, bc.rootfs_sha512) catch return error.RootfsHashMismatch;

    // 只读 lower（loop 挂载 squashfs）+ tmpfs upper/work（同一 tmpfs）+ overlay 合并。
    try mustRun(io, allocator, &.{ "mkdir", "-p", lower_mnt, rw_mnt, merged_mnt });
    try mustRun(io, allocator, &.{ "mount", "-t", "squashfs", "-o", "ro,loop", rootfs_blob, lower_mnt });
    try mustRun(io, allocator, &.{ "mount", "-t", "tmpfs", "tmpfs", rw_mnt });
    const upper_dir = try std.fmt.allocPrint(allocator, "{s}/upper", .{rw_mnt});
    defer allocator.free(upper_dir);
    const work_dir = try std.fmt.allocPrint(allocator, "{s}/work", .{rw_mnt});
    defer allocator.free(work_dir);
    try mustRun(io, allocator, &.{ "mkdir", "-p", upper_dir, work_dir });
    const overlay_opts = try std.fmt.allocPrint(allocator, "lowerdir={s},upperdir={s},workdir={s}", .{ lower_mnt, upper_dir, work_dir });
    defer allocator.free(overlay_opts);
    try mustRun(io, allocator, &.{ "mount", "-t", "overlay", "overlay", "-o", overlay_opts, merged_mnt });

    // handoff：AgentPlan locator + agent/event token 交给 agent pre-init（写入新根 /var/lib）。
    try writeHandoff(io, allocator, &bc, cmdline.session, cmdline.node);
    // 切根前清零 config/rootfs capability（内存 token 用后即弃）。
    try zeroMemoryToken(allocator);

    // switch_root -> nodeforge-agent --pre-init（agent 校验 plan/payload、node-apply 后 exec /sbin/init）。
    // 必须 by PID 1 执行：用 replace（execve）替换当前进程，而非 spawn 子进程。
    // 仅 exec 失败才会返回（成功时进程镜像已被替换，不返回）。
    return std.process.replace(io, .{ .argv = &.{ "switch_root", merged_mnt, "/sbin/nodeforge-agent", "--pre-init" } });
}

fn bringUpNetwork(io: std.Io, allocator: std.mem.Allocator) !void {
    // 找到第一个非 lo 的网卡并 up，再 DHCP。dracut 环境提供 ip/dhclient。
    try runIgnore(io, allocator, &.{ "ip", "link", "set", "lo", "up" });
    try runIgnore(io, allocator, &.{ "sh", "-c", "for i in /sys/class/net/*; do dev=$(basename $i); [ $dev != lo ] && ip link set $dev up && break; done" });
    try runIgnore(io, allocator, &.{ "dhclient", "-v" });
}

fn writeHandoff(io: std.Io, allocator: std.mem.Allocator, bc: *const BootConfig, session: ?[]const u8, node: ?[]const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, handoff_dir);
    const json = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"node\":\"{s}\",\"session\":\"{s}\",\"agent_plan_url\":\"{s}\",\"agent_plan_digest\":\"{s}\",\"agent_token\":\"{s}\",\"event_token\":\"{s}\"}}\n", .{
        node orelse "",
        session orelse "",
        bc.agent_plan_url,
        bc.agent_plan_digest,
        bc.agent_token,
        bc.event_token,
    });
    defer allocator.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = handoff_path, .data = json });
}

fn zeroMemoryToken(allocator: std.mem.Allocator) !void {
    // capsule 文件随 initramfs 释放；内存 token 不落盘，无需持久清零。
    _ = allocator;
}

const BootConfig = struct {
    rootfs_url: []u8,
    rootfs_sha512: []u8,
    agent_plan_url: []u8,
    agent_plan_digest: []u8,
    agent_token: []u8,
    event_token: []u8,
};

fn parseBootConfig(allocator: std.mem.Allocator, json: []const u8) !BootConfig {
    const Parsed = struct {
        rootfs: struct { url: []const u8, sha512: []const u8 },
        agent_plan: struct { url: []const u8, digest: []const u8 },
        access: ?struct { agent_token: []const u8, event_token: []const u8 } = null,
    };
    const p = try std.json.parseFromSlice(Parsed, allocator, json, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    const access = p.value.access orelse return error.MissingAccessTokens;
    return .{
        .rootfs_url = try allocator.dupe(u8, p.value.rootfs.url),
        .rootfs_sha512 = try allocator.dupe(u8, p.value.rootfs.sha512),
        .agent_plan_url = try allocator.dupe(u8, p.value.agent_plan.url),
        .agent_plan_digest = try allocator.dupe(u8, p.value.agent_plan.digest),
        .agent_token = try allocator.dupe(u8, access.agent_token),
        .event_token = try allocator.dupe(u8, access.event_token),
    };
}

fn freeBootConfig(allocator: std.mem.Allocator, bc: *const BootConfig) void {
    allocator.free(bc.rootfs_url);
    allocator.free(bc.rootfs_sha512);
    allocator.free(bc.agent_plan_url);
    allocator.free(bc.agent_plan_digest);
    allocator.free(bc.agent_token);
    allocator.free(bc.event_token);
}

fn verifySha512(io: std.Io, allocator: std.mem.Allocator, path: []const u8, expected: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "sha512sum", path } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
    const actual = std.mem.trim(u8, result.stdout, " \t\r\n");
    const digest = if (std.mem.indexOfScalar(u8, actual, ' ')) |sp| actual[0..sp] else actual;
    if (!std.mem.eql(u8, digest, expected)) return error.HashMismatch;
}

fn curlGet(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: ?[]const u8) ![]u8 {
    const tmp = "/tmp/bootconfig.json";
    try curlToFile(io, allocator, url, token, session, tmp);
    return readFile(io, allocator, tmp);
}

fn curlDownload(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: ?[]const u8, dest: []const u8) !void {
    try curlToFile(io, allocator, url, token, session, dest);
}

fn curlToFile(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: ?[]const u8, dest: []const u8) !void {
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
    defer allocator.free(auth);
    if (session) |s| {
        const hdr = try std.fmt.allocPrint(allocator, "X-NodeForge-Session: {s}", .{s});
        defer allocator.free(hdr);
        try mustRun(io, allocator, &.{ "curl", "-fsS", "-H", auth, "-H", hdr, "-o", dest, url });
    } else {
        try mustRun(io, allocator, &.{ "curl", "-fsS", "-H", auth, "-o", dest, url });
    }
}

fn readCmdline(io: std.Io, allocator: std.mem.Allocator) !Cmdline {
    // /proc/cmdline 是 procfs 文件：用 `cat` 子进程读取（Io 流式读取对 procfs 不可靠）。
    const bytes = try captureRun(io, allocator, &.{ "cat", cmdline_path });
    defer allocator.free(bytes);
    var c: Cmdline = .{};
    var it = std.mem.tokenizeAny(u8, bytes, " \t\n");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "nodeforge.config_url=")) c.config_url = try allocator.dupe(u8, tok["nodeforge.config_url=".len..]);
        if (std.mem.startsWith(u8, tok, "nodeforge.node=")) c.node = try allocator.dupe(u8, tok["nodeforge.node=".len..]);
        if (std.mem.startsWith(u8, tok, "nodeforge.session=")) c.session = try allocator.dupe(u8, tok["nodeforge.session=".len..]);
        if (std.mem.startsWith(u8, tok, "nodeforge.kernel_args=")) c.kernel_args = try allocator.dupe(u8, tok["nodeforge.kernel_args=".len..]);
    }
    return c;
}

fn freeCmdline(allocator: std.mem.Allocator, c: Cmdline) void {
    if (c.config_url) |s| allocator.free(s);
    if (c.node) |s| allocator.free(s);
    if (c.session) |s| allocator.free(s);
    if (c.kernel_args) |s| allocator.free(s);
}

fn captureRun(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
    return result.stdout;
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
}

fn mustRun(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch return error.SubprocessFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
}

fn runIgnore(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
}
