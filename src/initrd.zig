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
const memory = @import("initrd/memory.zig");
const download = @import("initrd/download.zig");

const capsule_config_token_path = "/capsule/config.token";
const capsule_rootfs_token_path = "/capsule/rootfs.token";
const capsule_agent_token_path = "/capsule/agent.token";
const capsule_event_token_path = "/capsule/event.token";
const cmdline_path = "/proc/cmdline";
const handoff_dir = "/merged/var/lib/nodeforge";
const handoff_path = "/merged/var/lib/nodeforge/boot.json";
const event_token_dir = "/merged/var/lib/nodeforge/credentials";
const agent_token_path = "/merged/var/lib/nodeforge/credentials/agent.token";
const event_token_path = "/merged/var/lib/nodeforge/credentials/event.token";
const rootfs_blob = "/run/rootfs.squashfs";
const rootfs_part = "/run/rootfs.squashfs.part";
const rootfs_chunk = "/run/rootfs.squashfs.chunk";
const rootfs_headers = "/run/rootfs.headers";
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

    const config_token = try readToken(io, allocator, capsule_config_token_path);
    defer allocator.free(config_token);
    const rootfs_token = try readToken(io, allocator, capsule_rootfs_token_path);
    defer allocator.free(rootfs_token);
    const agent_token = try readToken(io, allocator, capsule_agent_token_path);
    defer allocator.free(agent_token);
    const event_token = try readToken(io, allocator, capsule_event_token_path);
    defer allocator.free(event_token);

    // 拉取 BootConfig v2（config:read token，有界重放）。
    const config_json = try curlGet(io, allocator, cmdline.config_url orelse return error.MissingConfigUrl, config_token, cmdline.session);
    defer allocator.free(config_json);
    const bc = try parseBootConfig(allocator, config_json);
    defer freeBootConfig(allocator, &bc);
    const session = cmdline.session orelse return error.MissingSession;
    const node = cmdline.node orelse return error.MissingNode;
    var next_event_seq: u64 = 0;
    var current_phase: []const u8 = "boot.config_fetched";
    errdefer postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.failed") catch {};

    // 下载 rootfs 并 SHA-512 校验。
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.initrd_started");
    @memset(config_token, 0);
    next_event_seq += 1;
    current_phase = "diskless.initrd_started";
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.rootfs_downloading");
    next_event_seq += 1;
    current_phase = "diskless.rootfs_downloading";
    const meminfo = try captureRun(io, allocator, &.{ "cat", "/proc/meminfo" });
    defer allocator.free(meminfo);
    const upper_limit = try memory.upperLimit(.{
        .available_budget = try memory.memAvailableBytes(meminfo),
        .rootfs_size = bc.rootfs_size,
        .node_payload_size = bc.node_payload_size,
        .tmpfs_percent = bc.tmpfs_percent,
        .minimum_free_bytes = bc.minimum_free_bytes,
        .safety_margin_bytes = bc.safety_margin_bytes,
    });
    try downloadRootfs(io, allocator, &bc, rootfs_token, session);
    verifySha512(io, allocator, rootfs_blob, bc.rootfs_sha512) catch return error.RootfsHashMismatch;
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.rootfs_verified");
    @memset(rootfs_token, 0);
    next_event_seq += 1;
    current_phase = "diskless.rootfs_verified";

    // 只读 lower（loop 挂载 squashfs）+ tmpfs upper/work（同一 tmpfs）+ overlay 合并。
    try mustRun(io, allocator, &.{ "mkdir", "-p", lower_mnt, rw_mnt, merged_mnt });
    try mustRun(io, allocator, &.{ "mount", "-t", "squashfs", "-o", "ro,loop", rootfs_blob, lower_mnt });
    const tmpfs_options = try std.fmt.allocPrint(allocator, "size={d},mode=0755", .{upper_limit});
    defer allocator.free(tmpfs_options);
    try mustRun(io, allocator, &.{ "mount", "-t", "tmpfs", "-o", tmpfs_options, "tmpfs", rw_mnt });
    const upper_dir = try std.fmt.allocPrint(allocator, "{s}/upper", .{rw_mnt});
    defer allocator.free(upper_dir);
    const work_dir = try std.fmt.allocPrint(allocator, "{s}/work", .{rw_mnt});
    defer allocator.free(work_dir);
    try mustRun(io, allocator, &.{ "mkdir", "-p", upper_dir, work_dir });
    const overlay_opts = try std.fmt.allocPrint(allocator, "lowerdir={s},upperdir={s},workdir={s}", .{ lower_mnt, upper_dir, work_dir });
    defer allocator.free(overlay_opts);
    try mustRun(io, allocator, &.{ "mount", "-t", "overlay", "overlay", "-o", overlay_opts, merged_mnt });
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.rootfs_mounted");
    next_event_seq += 1;
    current_phase = "diskless.rootfs_mounted";

    // handoff：AgentPlan locator + agent/event token 交给 agent pre-init（写入新根 /var/lib）。
    try writeHandoff(io, allocator, &bc, session, node, agent_token, event_token);
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.switching_root");
    next_event_seq += 1;
    current_phase = "diskless.switching_root";
    // token 已分别撤销或复制到 0400 handoff credential，清零 initrd 副本。
    @memset(agent_token, 0);
    @memset(event_token, 0);

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

fn writeHandoff(io: std.Io, allocator: std.mem.Allocator, bc: *const BootConfig, session: ?[]const u8, node: ?[]const u8, agent_token: []const u8, event_token: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, handoff_dir);
    try std.Io.Dir.cwd().createDirPath(io, event_token_dir);
    const json = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"node\":\"{s}\",\"session\":\"{s}\",\"agent_plan_url\":\"{s}\",\"agent_plan_digest\":\"{s}\",\"event_url\":\"{s}\"}}\n", .{
        node orelse "",
        session orelse "",
        bc.agent_plan_url,
        bc.agent_plan_digest,
        bc.event_url,
    });
    defer allocator.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = handoff_path, .data = json });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = agent_token_path, .data = agent_token });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = event_token_path, .data = event_token });
    try mustRun(io, allocator, &.{ "chmod", "0400", agent_token_path });
    try mustRun(io, allocator, &.{ "chmod", "0400", event_token_path });
}

const BootConfig = struct {
    rootfs_url: []u8,
    rootfs_sha512: []u8,
    agent_plan_url: []u8,
    agent_plan_digest: []u8,
    event_url: []u8,
    rootfs_size: u64,
    tmpfs_percent: u8,
    minimum_free_bytes: u64,
    safety_margin_bytes: u64,
    node_payload_size: u64,
};

fn parseBootConfig(allocator: std.mem.Allocator, json: []const u8) !BootConfig {
    const Parsed = struct {
        rootfs: struct { url: []const u8, sha512: []const u8, size: u64 },
        overlay: struct {
            tmpfs_percent: u8,
            minimum_free_bytes: u64,
            safety_margin_bytes: u64,
            node_payload_size: u64 = 0,
        },
        agent_plan: struct { url: []const u8, digest: []const u8 },
        event_url: []const u8,
    };
    const p = try std.json.parseFromSlice(Parsed, allocator, json, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    return .{
        .rootfs_url = try allocator.dupe(u8, p.value.rootfs.url),
        .rootfs_sha512 = try allocator.dupe(u8, p.value.rootfs.sha512),
        .agent_plan_url = try allocator.dupe(u8, p.value.agent_plan.url),
        .agent_plan_digest = try allocator.dupe(u8, p.value.agent_plan.digest),
        .event_url = try allocator.dupe(u8, p.value.event_url),
        .rootfs_size = p.value.rootfs.size,
        .tmpfs_percent = p.value.overlay.tmpfs_percent,
        .minimum_free_bytes = p.value.overlay.minimum_free_bytes,
        .safety_margin_bytes = p.value.overlay.safety_margin_bytes,
        .node_payload_size = p.value.overlay.node_payload_size,
    };
}

fn freeBootConfig(allocator: std.mem.Allocator, bc: *const BootConfig) void {
    allocator.free(bc.rootfs_url);
    allocator.free(bc.rootfs_sha512);
    allocator.free(bc.agent_plan_url);
    allocator.free(bc.agent_plan_digest);
    allocator.free(bc.event_url);
}

fn readToken(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);
    const token = std.mem.trim(u8, bytes, " \t\r\n");
    if (token.len != 64) return error.InvalidCapsuleToken;
    for (token) |byte| if (!std.ascii.isHex(byte)) return error.InvalidCapsuleToken;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return allocator.dupe(u8, token);
}

fn postLifecycle(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: []const u8, seq: u64, expected: []const u8, phase: []const u8) !void {
    const body = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"session_id\":\"{s}\",\"event_seq\":{d},\"expected_phase\":\"{s}\",\"phase\":\"{s}\"}}\n", .{ session, seq, expected, phase });
    defer allocator.free(body);
    const event_file = "/tmp/nodeforge-event.json";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = event_file, .data = body });
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
    defer allocator.free(auth);
    const session_header = try std.fmt.allocPrint(allocator, "X-NodeForge-Session: {s}", .{session});
    defer allocator.free(session_header);
    try mustRun(io, allocator, &.{ "curl", "-fsS", "-H", auth, "-H", session_header, "-H", "Content-Type: application/json", "--data-binary", "@/tmp/nodeforge-event.json", url });
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

fn downloadRootfs(io: std.Io, allocator: std.mem.Allocator, bc: *const BootConfig, token: []const u8, session: []const u8) !void {
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
    defer allocator.free(auth);
    const session_header = try std.fmt.allocPrint(allocator, "X-NodeForge-Session: {s}", .{session});
    defer allocator.free(session_header);
    try mustRun(io, allocator, &.{
        "curl", "-fsS", "--max-redirs", "0", "--proto", "=http", "-I",
        "-H", auth, "-H", session_header, "-H", "Accept-Encoding: identity",
        "-D", rootfs_headers, "-o", "/dev/null", bc.rootfs_url,
    });
    const head_bytes = try readFile(io, allocator, rootfs_headers);
    defer allocator.free(head_bytes);
    const expected_etag = try std.fmt.allocPrint(allocator, "\"{s}\"", .{bc.rootfs_sha512});
    defer allocator.free(expected_etag);
    _ = try download.parseHead(head_bytes, bc.rootfs_size, expected_etag);

    const cwd = std.Io.Dir.cwd();
    var offset: u64 = if (cwd.statFile(io, rootfs_part, .{}) catch null) |stat| stat.size else 0;
    if (offset > bc.rootfs_size) {
        cwd.deleteFile(io, rootfs_part) catch {};
        offset = 0;
    }
    if (offset == 0) try cwd.writeFile(io, .{ .sub_path = rootfs_part, .data = "" });
    const chunk_size: u64 = 4 * 1024 * 1024;
    while (offset < bc.rootfs_size) {
        const end = @min(bc.rootfs_size - 1, offset + chunk_size - 1);
        var attempts: u8 = 0;
        while (true) {
            rangeOnce(io, allocator, bc.rootfs_url, auth, session_header, expected_etag, offset, end, bc.rootfs_size) catch |err| {
                attempts += 1;
                cwd.deleteFile(io, rootfs_chunk) catch {};
                if (attempts >= 5) return err;
                var seconds: [4]u8 = undefined;
                const delay = try std.fmt.bufPrint(&seconds, "{d}", .{@as(u8, 1) << @intCast(attempts - 1)});
                try mustRun(io, allocator, &.{ "sleep", delay });
                continue;
            };
            break;
        }
        try mustRun(io, allocator, &.{ "sh", "-c", "cat /run/rootfs.squashfs.chunk >> /run/rootfs.squashfs.part" });
        offset = end + 1;
    }
    const completed = try cwd.statFile(io, rootfs_part, .{});
    if (completed.size != bc.rootfs_size) return error.RootfsSizeMismatch;
    cwd.deleteFile(io, rootfs_blob) catch {};
    try std.Io.Dir.rename(cwd, rootfs_part, cwd, rootfs_blob, io);
    cwd.deleteFile(io, rootfs_chunk) catch {};
    cwd.deleteFile(io, rootfs_headers) catch {};
}

fn rangeOnce(io: std.Io, allocator: std.mem.Allocator, url: []const u8, auth: []const u8, session_header: []const u8, etag: []const u8, start: u64, end: u64, total: u64) !void {
    const range_header = try std.fmt.allocPrint(allocator, "Range: bytes={d}-{d}", .{ start, end });
    defer allocator.free(range_header);
    const if_range = try std.fmt.allocPrint(allocator, "If-Range: {s}", .{etag});
    defer allocator.free(if_range);
    try mustRun(io, allocator, &.{
        "curl", "-fsS", "--max-redirs", "0", "--proto", "=http",
        "-H", auth, "-H", session_header, "-H", "Accept-Encoding: identity",
        "-H", range_header, "-H", if_range,
        "-D", rootfs_headers, "-o", rootfs_chunk, url,
    });
    const headers = try readFile(io, allocator, rootfs_headers);
    defer allocator.free(headers);
    try download.validateRange(headers, start, end, total, etag);
    const stat = try std.Io.Dir.cwd().statFile(io, rootfs_chunk, .{});
    if (stat.size != end - start + 1) return error.RootfsChunkSizeMismatch;
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
