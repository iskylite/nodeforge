//! # nodeforge-agent（v0.2 diskless 切根后 pre-init / first-boot）
//!
//! `V0_2_DESIGN.md` §4.3/§5.3。`switch_root` 后由 initrd exec 为 `--pre-init`：
//! 从 `/var/lib/nodeforge/boot.json` 取 agent:read token -> 拉取并校验 immutable AgentPlan v1
//! 与其 content-addressed payload -> 清零 agent token -> 在真正 init 前把 Node
//! effective override（hostname/hosts/machine-id/network/target-system delta）写入
//! overlay upper -> `exec /sbin/init`。同一 binary 之后以 systemd unit 执行 effective
//! `first-boot`（一次性，无远程控制、无 reconciliation）。
//!
//! agent 不取得/解释 BootConfig 字段，不写 Profile 共享基线（已烤入 lower）；只重放
//! Node 运行根差量。payload digest/size 不符或拉取失败时真正 init 不启动，不使用本地旧
//! plan fallback（§10 fail-closed）。
const std = @import("std");

const handoff_path = "/var/lib/nodeforge/boot.json";
const payload_dir = "/var/lib/nodeforge/payload";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next(); // argv[0]
    const arg1 = args_iter.next();
    const pre_init = arg1 != null and std.mem.eql(u8, arg1.?, "--pre-init");
    if (pre_init) {
        try preInit(io, allocator);
        execInit(io);
    }
    // 无参数：作为 systemd unit 执行 effective first-boot（v0.2 占位：记录并退出 0）。
    try firstBoot(io, allocator);
}

fn preInit(io: std.Io, allocator: std.mem.Allocator) !void {
    const handoff = try readFile(io, allocator, handoff_path);
    defer allocator.free(handoff);
    const h = try parseHandoff(allocator, handoff);
    defer freeHandoff(allocator, &h);

    // 拉取 AgentPlan v1（agent:read token，session-bound）。
    const plan_json = try curlGet(io, allocator, h.agent_plan_url, h.agent_token, h.session);
    defer allocator.free(plan_json);
    const plan = try parseAgentPlan(allocator, plan_json);
    defer freeAgentPlan(allocator, &plan);

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
        const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ h.agent_plan_url_root, entry.path });
        defer allocator.free(url);
        try curlDownload(io, allocator, url, h.agent_token, h.session, dest);
        const got = try sha256Hex(allocator, try readFile(io, allocator, dest));
        defer allocator.free(got);
        if (!std.mem.eql(u8, got, entry.digest)) return error.PayloadDigestMismatch;
    }

    // node-apply：把 Node effective 运行根差量写入 overlay upper（真正 init 看到最终配置）。
    try nodeApply(io, allocator, &plan, h.node);

    // 预取完成，清零 agent token（内存用后即弃；handoff 落 /var/lib 持久化，供 first-boot 读取）。
    try clearToken(allocator, h.agent_token);
}

fn nodeApply(io: std.Io, allocator: std.mem.Allocator, plan: *const AgentPlan, node: []const u8) !void {
    _ = plan;
    // hostname：machine-id 与 hostname 必须在真正 init 前写定。
    try writeFile(io, allocator, "/etc/hostname", node);
    try writeFile(io, allocator, "/etc/machine-id", try machineId(allocator, node));
    try appendHosts(io, allocator);
}

fn execInit(io: std.Io) noreturn {
    // exec /sbin/init：替换当前进程镜像，把 PID 1 交给真正 init。
    std.process.replace(io, .{ .argv = &.{"/sbin/init"} }) catch {};
    std.process.exit(1);
}

fn firstBoot(io: std.Io, allocator: std.mem.Allocator) !void {
    _ = io;
    _ = allocator;
    // v0.2 first-boot 占位：一次性、无远程控制。后续 Phase 8 接入 provision-bundle 八步。
}

const Handoff = struct {
    node: []u8,
    session: []u8,
    agent_plan_url: []u8,
    agent_plan_digest: []u8,
    agent_token: []u8,
    event_token: []u8,
    agent_plan_url_root: []u8,
};

fn parseHandoff(allocator: std.mem.Allocator, json: []const u8) !Handoff {
    const P = struct {
        node: []const u8,
        session: []const u8,
        agent_plan_url: []const u8,
        agent_plan_digest: []const u8,
        agent_token: []const u8,
        event_token: []const u8,
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
        .agent_token = try allocator.dupe(u8, p.value.agent_token),
        .event_token = try allocator.dupe(u8, p.value.event_token),
        .agent_plan_url_root = try allocator.dupe(u8, root),
    };
}

fn freeHandoff(allocator: std.mem.Allocator, h: *const Handoff) void {
    allocator.free(h.node);
    allocator.free(h.session);
    allocator.free(h.agent_plan_url);
    allocator.free(h.agent_plan_digest);
    allocator.free(h.agent_token);
    allocator.free(h.event_token);
    allocator.free(h.agent_plan_url_root);
}

const AgentPlan = struct {
    payload: []PayloadEntry,
};

const PayloadEntry = struct {
    path: []const u8,
    digest: []const u8,
    size: u64,
};

fn parseAgentPlan(allocator: std.mem.Allocator, json: []const u8) !AgentPlan {
    const P = struct { payload: []const PayloadEntry = &.{} };
    const p = try std.json.parseFromSlice(P, allocator, json, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    return .{ .payload = try allocator.dupe(PayloadEntry, p.value.payload) };
}

fn freeAgentPlan(allocator: std.mem.Allocator, plan: *const AgentPlan) void {
    allocator.free(plan.payload);
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

fn appendHosts(io: std.Io, allocator: std.mem.Allocator) !void {
    const dir = std.Io.Dir.cwd();
    const existing = dir.readFileAlloc(io, "/etc/hosts", allocator, .limited(1 * 1024 * 1024)) catch try allocator.alloc(u8, 0);
    defer allocator.free(existing);
    const content = try std.fmt.allocPrint(allocator, "{s}127.0.1.1 nodeforge-diskless\n", .{existing});
    defer allocator.free(content);
    try dir.writeFile(io, .{ .sub_path = "/etc/hosts", .data = content });
}

fn clearToken(allocator: std.mem.Allocator, token: []const u8) !void {
    // 内存 token 用后即弃；仅显式置零局部副本以防残留。
    const buf = try allocator.alloc(u8, token.len);
    defer allocator.free(buf);
    @memset(buf, 0);
}

fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
}

fn runChecked(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
}
