//! # nodeforge-agent（v0.2 diskless 切根后 pre-init / first-boot）
//!
//! `V0_2_DESIGN.md` §4.3/§5.3。`switch_root` 后由 initrd exec 为 `--pre-init`：
//! 从独立 0400 credential 文件取 agent:read token -> 拉取并校验 immutable AgentPlan v1
//! 与其 content-addressed payload -> node-apply 写入 overlay upper -> 把校验过的 AgentPlan
//! 覆盖写回 boot.json（供 first-boot 重放八步；boot.json 从不含 token）-> 清零内存 token ->
//! `exec /sbin/init`。同一 binary 之后以 systemd unit 执行 effective `first-boot`（一次性、
//! 无远程控制、无 reconciliation）：读 boot.json 内联步骤按固定顺序 managed_file -> package
//! -> archive -> script 重放。package 只访问计划固定的 nodeforged HTTP Yum/APT 源并禁用
//! 系统其他源；失败只记日志不阻断启动。
//!
//! agent 不取得/解释 BootConfig 字段，不写 Profile 共享基线（已烤入 lower）；只重放
//! Node 运行根差量。payload digest/size 不符或拉取失败时真正 init 不启动，不使用本地旧
//! plan fallback（§10 fail-closed）。
const std = @import("std");
const first_boot = @import("provision/first_boot.zig");
const node_apply = @import("provision/node_apply.zig");
const diskless_dto = @import("http/diskless_dto.zig");

const handoff_path = "/var/lib/nodeforge/boot.json";
const payload_dir = "/var/lib/nodeforge/payload";
const agent_token_path = "/var/lib/nodeforge/credentials/agent.token";
const event_token_path = "/var/lib/nodeforge/credentials/event.token";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next(); // argv[0]（跳过程序名）
    const arg1 = args_iter.next();
    const pre_init = arg1 != null and std.mem.eql(u8, arg1.?, "--pre-init");
    if (pre_init) {
        try preInit(io, allocator);
        execInit(io);
    }
    // 无参数：作为 systemd unit 执行 effective first-boot。
    try firstBoot(io, allocator);
}

fn preInit(io: std.Io, allocator: std.mem.Allocator) !void {
    const handoff = try readFile(io, allocator, handoff_path);
    defer allocator.free(handoff);
    const h = try parseHandoff(allocator, handoff);
    defer freeHandoff(allocator, &h);
    const agent_token = try readCredential(io, allocator, agent_token_path, true);
    defer allocator.free(agent_token);
    const event_token = try readCredential(io, allocator, event_token_path, false);
    defer allocator.free(event_token);

    try postLifecycle(io, allocator, h.event_url, event_token, h.session, 5, "diskless.switching_root", "diskless.agent_configuring");
    errdefer postLifecycle(io, allocator, h.event_url, event_token, h.session, 6, "diskless.agent_configuring", "diskless.failed") catch {};

    // 拉取 AgentPlan v1（agent:read token，session-bound）。
    const plan_json = try curlGet(io, allocator, h.agent_plan_url, agent_token, h.session);
    defer allocator.free(plan_json);
    const parsed_plan = try std.json.parseFromSlice(diskless_dto.AgentPlan, allocator, plan_json, .{ .ignore_unknown_fields = false });
    defer parsed_plan.deinit();
    const plan = &parsed_plan.value;

    // 校验 plan digest（agent 不使用本地旧 plan fallback）。
    const actual_digest = try sha256Hex(allocator, plan_json);
    defer allocator.free(actual_digest);
    if (!std.mem.eql(u8, actual_digest, h.agent_plan_digest)) return error.AgentPlanDigestMismatch;

    // 拉取并校验全部 content-addressed payload。
    try std.Io.Dir.cwd().createDirPath(io, payload_dir);
    for (plan.payload) |entry| {
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ payload_dir, entry.path });
        defer allocator.free(dest);
        const parent = std.fs.path.dirname(dest) orelse payload_dir;
        try std.Io.Dir.cwd().createDirPath(io, parent);
        const url = try std.fmt.allocPrint(allocator, "{s}/payload/{s}", .{ h.agent_plan_url_root, entry.path });
        defer allocator.free(url);
        try curlDownload(io, allocator, url, agent_token, h.session, dest);
        const payload_bytes = try readFile(io, allocator, dest);
        defer allocator.free(payload_bytes);
        if (payload_bytes.len != entry.size) return error.PayloadSizeMismatch;
        const got = try sha256Hex(allocator, payload_bytes);
        defer allocator.free(got);
        if (!std.mem.eql(u8, got, entry.digest)) return error.PayloadDigestMismatch;
    }
    const consumed_url = try std.fmt.allocPrint(allocator, "{s}/agent-consumed", .{h.agent_plan_url_root});
    defer allocator.free(consumed_url);
    try curlPostEmpty(io, allocator, consumed_url, agent_token, h.session);
    clearToken(agent_token);

    // node-apply：把 Node effective 运行根差量写入 overlay upper（真正 init 看到最终配置）。
    try nodeApply(io, allocator, plan, h.node);

    // 持久化已校验的 AgentPlan 到 boot.json（覆盖 handoff）。同时达成两件事：
    // (1) first-boot 在切根+systemd 后可直接读 boot.json 重放八步，无需远程控制；
    // (2) credential 文件已经在读取时 unlink，agent:read token 随后只剩内存副本并被清零。
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = handoff_path, .data = plan_json });

}

fn nodeApply(io: std.Io, allocator: std.mem.Allocator, plan: *const diskless_dto.AgentPlan, handoff_node: []const u8) !void {
    const projection = plan.node_apply_projection;
    if (!std.mem.eql(u8, projection.node_id, handoff_node) or
        !std.mem.eql(u8, plan.node_id, handoff_node))
        return error.AgentPlanNodeMismatch;
    // hostname：machine-id 与 hostname 必须在真正 init 前写定。
    try writeFile(io, allocator, "/etc/machine-id", try machineId(allocator, projection.node_id));
    const script = try node_apply.render(allocator, projection);
    defer allocator.free(script);
    try runChecked(io, allocator, &.{ "/bin/sh", "-c", script });
}

fn execInit(io: std.Io) noreturn {
    // exec /sbin/init：替换当前进程镜像，把 PID 1 交给真正 init。
    std.process.replace(io, .{ .argv = &.{"/sbin/init"} }) catch {};
    std.process.exit(1);
}

fn firstBoot(io: std.Io, allocator: std.mem.Allocator) !void {
    // Phase 8：切根+systemd 后作为 unit 执行。读 pre-init 持久化的 boot.json（已覆盖为
    // 校验过的 AgentPlan，内联 first-boot 步骤），按固定顺序一次性重放，失败只记日志、
    // 不阻断启动。package 访问 pinned nodeforged software repository 不属于远程
    // 任务控制；agent 仍无远程控制、无 reconciliation。
    const plan_json = readFile(io, allocator, handoff_path) catch return;
    defer allocator.free(plan_json);
    const parsed = std.json.parseFromSlice(diskless_dto.AgentPlan, allocator, plan_json, .{ .ignore_unknown_fields = false }) catch return;
    defer parsed.deinit();
    const failures = first_boot.runFromPlanJson(io, allocator, plan_json);
    // first-boot 失败按冻结语义只令 postprocess degraded；真正 init 已启动，
    // diskless boot 仍进入 running。详细失败数保留在 firstboot.log。
    _ = failures;
    const token = readFile(io, allocator, event_token_path) catch return;
    defer allocator.free(token);
    postLifecycle(io, allocator, parsed.value.event_url, token, parsed.value.session_id, 6, "diskless.agent_configuring", "diskless.running") catch {};
    @memset(token, 0);
    std.Io.Dir.cwd().deleteFile(io, event_token_path) catch {};
}

const Handoff = struct {
    node: []u8,
    session: []u8,
    agent_plan_url: []u8,
    agent_plan_digest: []u8,
    event_url: []u8,
    agent_plan_url_root: []u8,
};

fn parseHandoff(allocator: std.mem.Allocator, json: []const u8) !Handoff {
    const P = struct {
        node: []const u8,
        session: []const u8,
        agent_plan_url: []const u8,
        agent_plan_digest: []const u8,
        event_url: []const u8,
    };
    const p = try std.json.parseFromSlice(P, allocator, json, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    // AgentPlan URL 形如 .../agent-plan/<digest>；payload 位于同级 .../payload/<path>。
    const root = blk: {
        const idx = std.mem.lastIndexOf(u8, p.value.agent_plan_url, "/agent-plan/") orelse break :blk p.value.agent_plan_url;
        break :blk p.value.agent_plan_url[0..idx];
    };
    return .{
        .node = try allocator.dupe(u8, p.value.node),
        .session = try allocator.dupe(u8, p.value.session),
        .agent_plan_url = try allocator.dupe(u8, p.value.agent_plan_url),
        .agent_plan_digest = try allocator.dupe(u8, p.value.agent_plan_digest),
        .event_url = try allocator.dupe(u8, p.value.event_url),
        .agent_plan_url_root = try allocator.dupe(u8, root),
    };
}

fn freeHandoff(allocator: std.mem.Allocator, h: *const Handoff) void {
    allocator.free(h.node);
    allocator.free(h.session);
    allocator.free(h.agent_plan_url);
    allocator.free(h.agent_plan_digest);
    allocator.free(h.event_url);
    allocator.free(h.agent_plan_url_root);
}

fn curlGet(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: []const u8) ![]u8 {
    const tmp = "/tmp/agentplan.json";
    try curlToFile(io, allocator, url, token, session, tmp);
    return readFile(io, allocator, tmp);
}

fn curlDownload(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: []const u8, dest: []const u8) !void {
    try curlToFile(io, allocator, url, token, session, dest);
}

fn curlToFile(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: []const u8, dest: []const u8) !void {
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
    defer allocator.free(auth);
    const sess = try std.fmt.allocPrint(allocator, "X-NodeForge-Session: {s}", .{session});
    defer allocator.free(sess);
    try runChecked(io, allocator, &.{ "curl", "-fsS", "-H", auth, "-H", sess, "-o", dest, url });
}

fn postLifecycle(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: []const u8, seq: u64, expected: []const u8, phase: []const u8) !void {
    const body = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"session_id\":\"{s}\",\"event_seq\":{d},\"expected_phase\":\"{s}\",\"phase\":\"{s}\"}}\n", .{ session, seq, expected, phase });
    defer allocator.free(body);
    const event_file = "/tmp/nodeforge-agent-event.json";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = event_file, .data = body });
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
    defer allocator.free(auth);
    const session_header = try std.fmt.allocPrint(allocator, "X-NodeForge-Session: {s}", .{session});
    defer allocator.free(session_header);
    try runChecked(io, allocator, &.{ "curl", "-fsS", "-H", auth, "-H", session_header, "-H", "Content-Type: application/json", "--data-binary", "@/tmp/nodeforge-agent-event.json", url });
}

fn curlPostEmpty(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: []const u8) !void {
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token});
    defer allocator.free(auth);
    const session_header = try std.fmt.allocPrint(allocator, "X-NodeForge-Session: {s}", .{session});
    defer allocator.free(session_header);
    try runChecked(io, allocator, &.{ "curl", "-fsS", "-X", "POST", "-H", auth, "-H", session_header, "-o", "/dev/null", url });
}

fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    const out = try allocator.alloc(u8, 64);
    _ = std.fmt.bufPrint(out, "{x}", .{raw}) catch unreachable;
    return out;
}

fn machineId(allocator: std.mem.Allocator, node: []const u8) ![]u8 {
    // systemd machine-id：32 hex 字符（16 字节）。取 SHA-256 前 16 字节。
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(node, &raw, .{});
    const out = try allocator.alloc(u8, 32);
    _ = std.fmt.bufPrint(out, "{x}", .{raw[0..16]}) catch unreachable;
    return out;
}

fn writeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const data = try std.fmt.allocPrint(allocator, "{s}\n", .{content});
    defer allocator.free(data);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn clearToken(token: []u8) void {
    // 内存 token 用后即弃；显式置零 Handoff 副本以防残留（盘上 boot.json 已被覆盖）。
    @memset(token, 0);
}

fn readCredential(io: std.Io, allocator: std.mem.Allocator, path: []const u8, unlink_after_read: bool) ![]u8 {
    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);
    const token = std.mem.trim(u8, bytes, " \t\r\n");
    if (token.len != 64) return error.InvalidCredential;
    for (token) |byte| if (!std.ascii.isHex(byte)) return error.InvalidCredential;
    if (unlink_after_read) std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return allocator.dupe(u8, token);
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
}

fn runChecked(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        // 失败时把退出码与 stderr 打到控制台：agent 作为 PID 1 此前静默 panic，无任何
        // 诊断，难以定位 node-apply 脚本究竟哪条命令失败（如 Ubuntu 上 usermod/enable）。
        .exited => |code| if (code != 0) {
            std.debug.print("nodeforge-agent: 命令失败 exit={d}: {s}\n", .{ code, result.stderr });
            return error.SubprocessFailed;
        },
        else => {
            std.debug.print("nodeforge-agent: 子进程异常终止: {s}\n", .{result.stderr });
            return error.SubprocessFailed;
        },
    }
}
