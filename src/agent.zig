//! # nodeforge-agent（v0.2 diskless 切根后 pre-init / first-boot）
//!
//! `V0_2_DESIGN.md` §4.3/§5.3。`switch_root` 后由 initrd exec 为 `--pre-init`：
//! 从独立 0400 credential 文件取 boot_session 能力 token（v0.4 token 简化：替代 v0.2
//! 的 agent:read scope token）-> 拉取并校验 immutable AgentPlan v2 与其
//! content-addressed payload -> node-apply 写入 overlay upper -> 把校验过的 AgentPlan
//! 覆盖写回 boot.json（供 first-boot 重放八步；boot.json 从不含 token）-> 清零内存 token ->
//! `exec /sbin/init`。同一 binary 之后以 systemd unit 执行 effective `first-boot`（一次性、
//! 无远程控制、无 reconciliation）：读 boot.json 内联步骤按固定顺序 managed_file -> package
//! -> archive -> script 重放。package 只访问计划固定的 nodeforged HTTP Yum/APT 源并禁用
//! 系统其他源；失败只记日志不阻断启动。
//!
//! ## 启动时机（R9 修订）
//!
//! agent 有两个执行阶段，均使用同一 binary：
//!
//! 1. **pre-init 阶段**（`--pre-init` 参数）：由 nodeforge-initrd 在 switch_root 后以
//!    `execve` 替换 PID 1 执行。此阶段无 systemd、无日志服务，日志直接输出到 console
//!    （串口）。pre-init 完成后 agent 调用 `exec /sbin/init` 将 PID 1 交给真正 init
//!    （systemd）。
//!
//! 2. **first-boot 阶段**（无参数）：由 systemd unit `nodeforge-firstboot.service` 执行。
//!    R9 修订后该 unit 配置为 `Before=rc-local.service`，确保 agent 在 rc.local 之前
//!    完成。unit 的 `StandardOutput` 和 `StandardError` 配置为
//!    `journal+file:/var/lib/nodeforge/firstboot.log`，因此 first-boot 日志同时写入
//!    systemd journal 和文件 `/var/lib/nodeforge/firstboot.log`。
//!
//! ## 日志位置
//!
//! - **initrd 阶段**：`/var/lib/nodeforge/initrd.log`（R11：switch_root 前从 /run 复制到
//!   overlay upper，切根后可查看）+ `/var/lib/nodeforge/initrd-dmesg.log`（内核 dmesg）
//! - **pre-init 阶段**：console（串口）输出，无持久化（PID 1 在 systemd 之前运行）
//! - **first-boot 阶段**：`/var/lib/nodeforge/firstboot.log` + systemd journal
//!   (`journalctl -u nodeforge-firstboot.service`)
//!
//! ## /sbin/init 是什么
//!
//! 无盘系统中 `/sbin/init` 是发行版原生的 systemd（如 Rocky 的 `/usr/lib/systemd/systemd`）。
//! 它是 squashfs rootfs 中的标准组件，由 `dnf --installroot` 在 rootfs 构建时安装。
//! agent pre-init 完成后 `exec /sbin/init` 启动 systemd，systemd 再拉起
//! `nodeforge-firstboot.service` 等服务。
//!
//! agent 不取得/解释 BootConfig 字段，不写 Profile 共享基线（已烤入 lower）；只重放
//! Node 运行根差量。payload digest/size 不符或拉取失败时真正 init 不启动，不使用本地旧
//! plan fallback（§10 fail-closed）。
//! AgentPlan、payload 与 lifecycle event 均复用
//! `initrd/http.zig` 原生客户端，diskless 启动闭包不要求目标 rootfs 安装 curl。
//! AgentPlan/events 使用 30 秒 socket 空闲超时，payload 使用 120 秒 socket
//! 空闲超时；payload 持续有数据时没有总时长上限。Zig 0.16 POSIX Threaded Io
//! 尚不能安全设置 connect deadline，建连暂由内核 TCP 超时负责。
const std = @import("std");
const first_boot = @import("provision/first_boot.zig");
const install_first_boot = @import("provision/install_first_boot.zig");
const node_apply = @import("provision/node_apply.zig");
const diskless_dto = @import("http/diskless_dto.zig");
const http = @import("initrd/http.zig");

const handoff_path = "/var/lib/nodeforge/boot.json";
const payload_dir = "/var/lib/nodeforge/payload";
const capability_token_path = "/var/lib/nodeforge/credentials/capability.token";
const event_token_path = "/var/lib/nodeforge/credentials/event.token";

var current_stage: []const u8 = "process.start";
var running_as_pid1_pre_init = false;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print(
            "\n[nodeforge-agent] FATAL: pre-init/first-boot aborted stage={s} error={t}\n",
            .{ current_stage, err },
        );
        // 只有 pre-init 是 PID 1，必须保留控制台诊断；systemd first-boot unit
        // 则正常以非零语义结束，由 unit/journal 记录失败，不能永久占住服务。
        if (running_as_pid1_pre_init)
            while (true) std.Io.sleep(init.io, .fromSeconds(3600), .awake) catch {};
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next(); // argv[0]（跳过程序名）
    const arg1 = args_iter.next();
    const pre_init = arg1 != null and std.mem.eql(u8, arg1.?, "--pre-init");
    if (pre_init) {
        running_as_pid1_pre_init = true;
        current_stage = "pre_init";
        try preInit(io, allocator);
        current_stage = "exec_system_init";
        execInit(io);
    }
    if (arg1 != null and std.mem.eql(u8, arg1.?, "--install-first-boot")) {
        current_stage = "install_first_boot";
        return installFirstBoot(io, allocator);
    }
    if (arg1 != null) return error.UnknownAgentMode;
    // 无参数：作为 systemd unit 执行 effective first-boot。
    current_stage = "first_boot";
    try firstBoot(io, allocator);
}

fn installFirstBoot(io: std.Io, allocator: std.mem.Allocator) !void {
    const generation_bytes = try readFile(io, allocator, install_first_boot.current_generation_path);
    defer allocator.free(generation_bytes);
    const generation = try std.fmt.parseInt(u64, std.mem.trim(u8, generation_bytes, " \t\r\n"), 10);
    if (generation == 0) return error.InvalidInstallFirstBootIdentity;
    const generation_dir = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ install_first_boot.root, generation });
    defer allocator.free(generation_dir);
    const identity_path = try std.fmt.allocPrint(allocator, "{s}/identity.json", .{generation_dir});
    defer allocator.free(identity_path);
    const plan_path = try std.fmt.allocPrint(allocator, "{s}/plan.json", .{generation_dir});
    defer allocator.free(plan_path);
    const journal_path = try std.fmt.allocPrint(allocator, "{s}/journal.json", .{generation_dir});
    defer allocator.free(journal_path);
    const event_token_path_install = try std.fmt.allocPrint(allocator, "{s}/event.token", .{generation_dir});
    defer allocator.free(event_token_path_install);
    const pending_path = try std.fmt.allocPrint(allocator, "{s}/pending", .{generation_dir});
    defer allocator.free(pending_path);

    const identity_bytes = try readFile(io, allocator, identity_path);
    defer allocator.free(identity_bytes);
    var identity = try install_first_boot.parseIdentity(allocator, identity_bytes);
    defer identity.deinit();
    if (identity.value.install_generation != generation) return error.InstallFirstBootBindingMismatch;
    const plan_bytes = try readFile(io, allocator, plan_path);
    defer allocator.free(plan_bytes);
    var verified = try install_first_boot.parseAndVerifyPlan(allocator, plan_bytes, identity.value.node_id, generation);
    defer verified.deinit();
    const plan = verified.value();
    if (!std.mem.eql(u8, identity.value.first_boot_plan_digest, plan.first_boot_plan_digest)) return error.InstallFirstBootDigestMismatch;
    try install_first_boot.validatePayloadClosure(io, generation_dir, plan.*);

    var journal_parsed: ?std.json.Parsed(install_first_boot.LocalJournal) = null;
    defer if (journal_parsed) |*parsed| parsed.deinit();
    var journal: install_first_boot.LocalJournal = undefined;
    const journal_bytes = readFile(io, allocator, journal_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (journal_bytes) |bytes| {
        defer allocator.free(bytes);
        journal_parsed = std.json.parseFromSlice(install_first_boot.LocalJournal, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch return error.InvalidInstallFirstBootJournal;
        journal = journal_parsed.?.value;
        try journal.validateBinding(plan.*);
    } else {
        journal = .{
            .deployment_id = plan.deployment_id,
            .node_id = plan.node_id,
            .install_generation = plan.install_generation,
            .bundle_revision = plan.bundle_revision,
            .first_boot_plan_digest = plan.first_boot_plan_digest,
        };
        try install_first_boot.persistJournal(io, allocator, journal_path, journal);
    }

    if (journal.state == .completed_acknowledged or journal.state == .failed_acknowledged) {
        try removeInstallPending(io, pending_path);
        return;
    }
    var event_token: []u8 = undefined;
    if (journal.state == .pending) {
        const bootstrap = try readCredential(io, allocator, install_first_boot.bootstrap_token_path, false);
        defer {
            clearToken(bootstrap);
            allocator.free(bootstrap);
        }
        event_token = try installFirstBootExchange(io, allocator, plan.exchange_url, bootstrap);
        try install_first_boot.atomicWriteCredential(io, event_token_path_install, event_token);
        try install_first_boot.removeCredential(io, install_first_boot.bootstrap_token_path);
        clearToken(bootstrap);
        const started_id = try installEventId(allocator, plan.first_boot_plan_digest, "started", null);
        defer allocator.free(started_id);
        try installFirstBootEvent(io, allocator, plan.event_url, event_token, 0, "exchanging", "first_boot.started", started_id, null);
        try journal.begin();
        try install_first_boot.persistJournal(io, allocator, journal_path, journal);
    } else {
        event_token = try readCredential(io, allocator, event_token_path_install, false);
    }
    defer {
        clearToken(event_token);
        allocator.free(event_token);
    }

    if (journal.state == .completed_pending_ack or journal.state == .failed_pending_ack) {
        try resendInstallTerminal(io, allocator, plan.event_url, event_token, &journal, journal_path, event_token_path_install);
        try removeInstallPending(io, pending_path);
        return;
    }
    if (journal.state == .step_running) {
        try journal.failStep(journal.running_step.?);
        try persistAndSendInstallTerminal(io, allocator, plan.event_url, event_token, &journal, journal_path, event_token_path_install, false);
        try removeInstallPending(io, pending_path);
        return;
    }

    const order = try install_first_boot.orderedStepIndices(allocator, plan.steps);
    defer allocator.free(order);
    while (journal.next_step < order.len) {
        const canonical_index = journal.next_step;
        const step = plan.steps[order[canonical_index]];
        try journal.beginStep(canonical_index);
        try install_first_boot.persistJournal(io, allocator, journal_path, journal);
        const started_id = try installEventId(allocator, plan.first_boot_plan_digest, "step-started", canonical_index);
        defer allocator.free(started_id);
        try installFirstBootEvent(io, allocator, plan.event_url, event_token, 1, if (canonical_index == 0) "started" else "running", "first_boot.step_started", started_id, canonical_index);
        const command = try install_first_boot.renderStepCommand(allocator, generation_dir, plan.*, step);
        defer allocator.free(command);
        runInstallStep(io, allocator, command, step.timeout_s, if (step.retryable) 3 else 1) catch {
            try journal.failStep(canonical_index);
            try persistAndSendInstallTerminal(io, allocator, plan.event_url, event_token, &journal, journal_path, event_token_path_install, false);
            try removeInstallPending(io, pending_path);
            return;
        };
        const succeeded_id = try installEventId(allocator, plan.first_boot_plan_digest, "step-succeeded", canonical_index);
        defer allocator.free(succeeded_id);
        try installFirstBootEvent(io, allocator, plan.event_url, event_token, 1, "running", "first_boot.step_succeeded", succeeded_id, canonical_index);
        try journal.completeStep(canonical_index);
        try install_first_boot.persistJournal(io, allocator, journal_path, journal);
    }
    try persistAndSendInstallTerminal(io, allocator, plan.event_url, event_token, &journal, journal_path, event_token_path_install, true);
    try removeInstallPending(io, pending_path);
}

fn removeInstallPending(io: std.Io, path: []const u8) !void {
    install_first_boot.removeCredential(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn preInit(io: std.Io, allocator: std.mem.Allocator) !void {
    current_stage = "handoff.read";
    const handoff = try readFile(io, allocator, handoff_path);
    defer allocator.free(handoff);
    const h = try parseHandoff(allocator, handoff);
    defer freeHandoff(allocator, &h);
    // v0.4 token 简化：capability.token 存储 boot_session 能力 token（读取用），
    // event.token 存储 event:append 派生 token（lifecycle 用）。
    const capability_token = try readCredential(io, allocator, capability_token_path, true);
    defer allocator.free(capability_token);
    const event_token = try readCredential(io, allocator, event_token_path, false);
    defer allocator.free(event_token);

    current_stage = "lifecycle.agent_configuring";
    try postLifecycle(io, allocator, h.event_url, event_token, h.session, 5, "diskless.switching_root", "diskless.agent_configuring");
    errdefer postLifecycle(io, allocator, h.event_url, event_token, h.session, 6, "diskless.agent_configuring", "diskless.failed") catch {};

    // 拉取 AgentPlan v2（boot_session 能力 token，session-bound）；v1 不提供 target
    // topology/lease snapshot，必须 fail closed，不能回退到旧单 NIC 计划。
    // 读取请求使用 read_session（boot_session id），而非 delivery session。
    current_stage = "agent_plan.download";
    std.debug.print("[nodeforge-agent] stage={s}: downloading AgentPlan\n", .{current_stage});
    const plan_json = try nativeGet(io, allocator, h.agent_plan_url, capability_token, h.read_session);
    defer allocator.free(plan_json);
    const parsed_plan = try std.json.parseFromSlice(diskless_dto.AgentPlan, allocator, plan_json, .{ .ignore_unknown_fields = false });
    defer parsed_plan.deinit();
    if (parsed_plan.value.schema_version != diskless_dto.agent_plan_schema_version) return error.UnsupportedAgentPlanSchema;
    const plan = &parsed_plan.value;

    // 校验 plan digest（agent 不使用本地旧 plan fallback）。
    const actual_digest = try sha256Hex(allocator, plan_json);
    defer allocator.free(actual_digest);
    if (!std.mem.eql(u8, actual_digest, h.agent_plan_digest)) return error.AgentPlanDigestMismatch;

    // 拉取并校验全部 content-addressed payload。
    try std.Io.Dir.cwd().createDirPath(io, payload_dir);
    current_stage = "payload.download";
    for (plan.payload, 0..) |entry, index| {
        std.debug.print("[nodeforge-agent] stage={s}: item={d}/{d} path={s} bytes={d}\n", .{ current_stage, index + 1, plan.payload.len, entry.path, entry.size });
        const dest = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ payload_dir, entry.path });
        defer allocator.free(dest);
        const parent = std.fs.path.dirname(dest) orelse payload_dir;
        try std.Io.Dir.cwd().createDirPath(io, parent);
        const url = try std.fmt.allocPrint(allocator, "{s}/payload/{s}", .{ h.agent_plan_url_root, entry.path });
        defer allocator.free(url);
        // payload 是 digest 固定的数据面；服务端以 peer-IP、活动 session 和 plan
        // allowlist 鉴别，不向普通下载传播 capability。
        try nativeDownload(io, allocator, url, dest, entry.size);
        const payload_bytes = try readFile(io, allocator, dest);
        defer allocator.free(payload_bytes);
        if (payload_bytes.len != entry.size) return error.PayloadSizeMismatch;
        const got = try sha256Hex(allocator, payload_bytes);
        defer allocator.free(got);
        if (!std.mem.eql(u8, got, entry.digest)) return error.PayloadDigestMismatch;
    }
    // 已删除旧 per-scope agent token，server 端不存在需要确认的“consume”动作；
    // capability 仅用于 AgentPlan 控制读取，payload 校验完成后本地立即清零。
    clearToken(capability_token);

    // node-apply：把 Node effective 运行根差量写入 overlay upper（真正 init 看到最终配置）。
    current_stage = "node_apply";
    std.debug.print("[nodeforge-agent] stage={s}: applying effective node configuration\n", .{current_stage});
    try nodeApply(io, allocator, plan, h.node);

    // 持久化已校验的 AgentPlan 到 boot.json（覆盖 handoff）。同时达成两件事：
    // (1) first-boot 在切根+systemd 后可直接读 boot.json 重放八步，无需远程控制；
    // (2) credential 文件已经在读取时 unlink，boot-session capability 随后只剩内存副本并被清零。
    current_stage = "handoff.persist_verified_plan";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = handoff_path, .data = plan_json });
    std.debug.print("[nodeforge-agent] pre-init completed successfully\n", .{});
}

fn nodeApply(io: std.Io, allocator: std.mem.Allocator, plan: *const diskless_dto.AgentPlan, handoff_node: []const u8) !void {
    var projection = plan.node_apply_projection;
    // v0.4 AgentPlan v2 makes target_network the single network owner.  The
    // legacy projection field is only used when reading an old local fixture;
    // a production v2 plan with structured topology must never merge two views.
    if (plan.target_network.interfaces.len > 0 or plan.target_network.bonds.len > 0 or plan.target_network.vlans.len > 0 or plan.target_network.routes.len > 0)
        projection.network = plan.target_network;
    if (!std.mem.eql(u8, projection.node_id, handoff_node) or
        !std.mem.eql(u8, plan.node_id, handoff_node))
        return error.AgentPlanNodeMismatch;
    // hostname：machine-id 与 hostname 必须在真正 init 前写定。
    try writeFile(io, allocator, "/etc/machine-id", try machineId(allocator, projection.node_id));
    // AgentPlan 以 MAC 作为稳定身份。interface_name 未显式指定时，在目标机
    // sysfs 中解析本次启动的真实名称（如 enp2s0），而不是把连接名 nodeforge
    // 误当作设备名。diskless 每次启动都会重新探测，因此 PCI 拓扑变化也可收敛。
    const resolved_interface = if (projection.network.interface == null)
        (try interfaceNameByMac(io, allocator, projection.network.match_mac orelse projection.mac)) orelse
            return error.NetworkInterfaceUnresolved
    else
        null;
    defer if (resolved_interface) |name| allocator.free(name);
    const script = try node_apply.renderResolved(allocator, projection, resolved_interface);
    defer allocator.free(script);
    try runChecked(io, allocator, &.{ "/bin/sh", "-c", script });
}

fn interfaceNameByMac(io: std.Io, allocator: std.mem.Allocator, expected_mac: []const u8) !?[]u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/net", .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "lo")) continue;
        const address_path = try std.fmt.allocPrint(allocator, "/sys/class/net/{s}/address", .{entry.name});
        defer allocator.free(address_path);
        const address = std.Io.Dir.cwd().readFileAlloc(io, address_path, allocator, .limited(64)) catch continue;
        defer allocator.free(address);
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, address, " \t\r\n"), expected_mac))
            return try allocator.dupe(u8, entry.name);
    }
    return null;
}

fn execInit(io: std.Io) noreturn {
    // exec /sbin/init：替换当前进程镜像，把 PID 1 交给真正 init。
    const err = std.process.replace(io, .{ .argv = &.{"/sbin/init"} });
    std.debug.print("[nodeforge-agent] FATAL: exec /sbin/init failed: {t}\n", .{err});
    std.process.exit(1);
}

fn firstBoot(io: std.Io, allocator: std.mem.Allocator) !void {
    // Phase 8：切根+systemd 后作为 unit 执行。读 pre-init 持久化的 boot.json（已覆盖为
    // 校验过的 AgentPlan，内联 first-boot 步骤），按固定顺序一次性重放，失败只记日志、
    // 不阻断启动。package 访问 pinned nodeforged software repository 不属于远程
    // 任务控制；agent 仍无远程控制、无 reconciliation。
    const plan_json = readFile(io, allocator, handoff_path) catch |err| {
        std.debug.print("[nodeforge-agent] WARNING: first-boot skipped: cannot read verified plan: {t}\n", .{err});
        return;
    };
    defer allocator.free(plan_json);
    const parsed = std.json.parseFromSlice(diskless_dto.AgentPlan, allocator, plan_json, .{ .ignore_unknown_fields = false }) catch |err| {
        std.debug.print("[nodeforge-agent] WARNING: first-boot skipped: invalid verified plan: {t}\n", .{err});
        return;
    };
    defer parsed.deinit();
    const failures = first_boot.runFromPlanJson(io, allocator, plan_json);
    // first-boot 失败按冻结语义只令 postprocess degraded；真正 init 已启动，
    // diskless boot 仍进入 running。详细失败数保留在 firstboot.log。
    _ = failures;
    const token = readFile(io, allocator, event_token_path) catch |err| {
        std.debug.print("[nodeforge-agent] WARNING: cannot report diskless.running: event credential unavailable: {t}\n", .{err});
        return;
    };
    defer allocator.free(token);
    postLifecycle(io, allocator, parsed.value.event_url, token, parsed.value.session_id, 6, "diskless.agent_configuring", "diskless.running") catch |err|
        std.debug.print("[nodeforge-agent] WARNING: cannot report diskless.running: {t}\n", .{err});
    @memset(token, 0);
    std.Io.Dir.cwd().deleteFile(io, event_token_path) catch {};
}

/// v0.4 token 简化：handoff schema v2。`session` 是 delivery session id（event:append
/// 用），`read_session` 是 boot_session id（capability 读取用）。两者来自不同的
/// session store，在 initrd 引导认证时由服务端分别签发。
const Handoff = struct {
    node: []u8,
    /// delivery session id：配合 event_token 推进 lifecycle 事件。
    session: []u8,
    /// boot_session id：配合 capability token 拉取 agent-plan/payload。
    /// handoff schema v1 不含此字段，回退为 session（兼容旧 initrd 写入的 handoff）。
    read_session: []u8,
    agent_plan_url: []u8,
    agent_plan_digest: []u8,
    event_url: []u8,
    agent_plan_url_root: []u8,
};

fn parseHandoff(allocator: std.mem.Allocator, json: []const u8) !Handoff {
    const P = struct {
        node: []const u8,
        session: []const u8,
        read_session: ?[]const u8 = null,
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
        // handoff schema v2 有 read_session；v1 回退为 session（兼容性）。
        .read_session = try allocator.dupe(u8, p.value.read_session orelse p.value.session),
        .agent_plan_url = try allocator.dupe(u8, p.value.agent_plan_url),
        .agent_plan_digest = try allocator.dupe(u8, p.value.agent_plan_digest),
        .event_url = try allocator.dupe(u8, p.value.event_url),
        .agent_plan_url_root = try allocator.dupe(u8, root),
    };
}

fn freeHandoff(allocator: std.mem.Allocator, h: *const Handoff) void {
    allocator.free(h.node);
    allocator.free(h.session);
    allocator.free(h.read_session);
    allocator.free(h.agent_plan_url);
    allocator.free(h.agent_plan_digest);
    allocator.free(h.event_url);
    allocator.free(h.agent_plan_url_root);
}

fn nativeHeaders(allocator: std.mem.Allocator, token: []const u8, session: []const u8) !struct { auth: []u8, session: []u8 } {
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    const sess = try allocator.dupe(u8, session);
    return .{ .auth = auth, .session = sess };
}

fn nativeGet(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: []const u8) ![]u8 {
    const parsed = try http.Url.parse(url);
    const headers = try nativeHeaders(allocator, token, session);
    defer allocator.free(headers.auth);
    defer allocator.free(headers.session);
    return http.get(io, allocator, parsed, &.{
        .{ .name = "Authorization", .value = headers.auth },
        .{ .name = "X-NodeForge-Session", .value = headers.session },
    });
}

fn nativeDownload(io: std.Io, allocator: std.mem.Allocator, url: []const u8, dest: []const u8, expected_size: u64) !void {
    const parsed = try http.Url.parse(url);
    const response_headers = try http.getToFile(io, allocator, parsed, &.{}, dest, 200, expected_size);
    allocator.free(response_headers);
}

fn bearerHeader(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
}

fn installFirstBootExchange(io: std.Io, allocator: std.mem.Allocator, url: []const u8, bootstrap: []const u8) ![]u8 {
    const parsed_url = try http.Url.parse(url);
    const auth_header = try bearerHeader(allocator, bootstrap);
    defer allocator.free(auth_header);
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const response = http.postForBody(io, allocator, parsed_url, &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
        }, "{}") catch |err| {
            if (attempt == 2) return err;
            std.Io.sleep(io, .fromSeconds(@as(i64, 1) << @intCast(attempt)), .awake) catch {};
            continue;
        };
        defer allocator.free(response);
        const Response = struct { ok: bool, result: struct { event_token: []const u8, event_seq: u64 } };
        const decoded = std.json.parseFromSlice(Response, allocator, response, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch return error.InvalidFirstBootExchange;
        defer decoded.deinit();
        if (!decoded.value.ok or decoded.value.result.event_seq != 0 or decoded.value.result.event_token.len != 64) return error.InvalidFirstBootExchange;
        for (decoded.value.result.event_token) |byte| if (!std.ascii.isHex(byte)) return error.InvalidFirstBootExchange;
        return allocator.dupe(u8, decoded.value.result.event_token);
    }
    unreachable;
}

fn installEventBody(allocator: std.mem.Allocator, event_seq: u64, expected_state: []const u8, event: []const u8, event_id: []const u8, step_index: ?usize) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.print("{{\"schema_version\":1,\"event_seq\":{d},\"expected_state\":{f},\"event\":{f},\"event_id\":{f}", .{ event_seq, std.json.fmt(expected_state, .{}), std.json.fmt(event, .{}), std.json.fmt(event_id, .{}) });
    if (step_index) |index| try output.writer.print(",\"step_index\":{d}", .{index});
    try output.writer.writeAll("}\n");
    return output.toOwnedSlice();
}

fn postInstallEventBody(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, body: []const u8) !void {
    const parsed_url = try http.Url.parse(url);
    const auth_header = try bearerHeader(allocator, token);
    defer allocator.free(auth_header);
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const status = http.post(io, allocator, parsed_url, &.{
            .{ .name = "Authorization", .value = auth_header },
            .{ .name = "Content-Type", .value = "application/json" },
        }, body) catch |err| {
            if (attempt == 2) return err;
            std.Io.sleep(io, .fromSeconds(@as(i64, 1) << @intCast(attempt)), .awake) catch {};
            continue;
        };
        if (status >= 200 and status < 300) return;
        return error.InstallFirstBootEventRejected;
    }
    unreachable;
}

fn installFirstBootEvent(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, event_seq: u64, expected_state: []const u8, event: []const u8, event_id: []const u8, step_index: ?usize) !void {
    const body = try installEventBody(allocator, event_seq, expected_state, event, event_id, step_index);
    defer allocator.free(body);
    try postInstallEventBody(io, allocator, url, token, body);
}

fn installEventId(allocator: std.mem.Allocator, plan_digest: []const u8, kind: []const u8, index: ?usize) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("nodeforge-install-firstboot-event-v1\x00");
    hasher.update(plan_digest);
    hasher.update("\x00");
    hasher.update(kind);
    if (index) |value| {
        var buffer: [24]u8 = undefined;
        hasher.update(try std.fmt.bufPrint(&buffer, ":{d}", .{value}));
    }
    var raw: [32]u8 = undefined;
    hasher.final(&raw);
    const result = try allocator.alloc(u8, 64);
    _ = std.fmt.bufPrint(result, "{x}", .{raw}) catch unreachable;
    return result;
}

fn persistAndSendInstallTerminal(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, journal: *install_first_boot.LocalJournal, journal_path: []const u8, token_path: []const u8, success: bool) !void {
    const event_id = try installEventId(allocator, journal.first_boot_plan_digest, if (success) "succeeded" else "failed", null);
    defer allocator.free(event_id);
    const body = try installEventBody(allocator, 1, "running", if (success) "first_boot.succeeded" else "first_boot.failed", event_id, null);
    defer allocator.free(body);
    try journal.terminal(success, event_id, body);
    try install_first_boot.persistJournal(io, allocator, journal_path, journal.*);
    try postInstallEventBody(io, allocator, url, token, body);
    try journal.acknowledge();
    try install_first_boot.persistJournal(io, allocator, journal_path, journal.*);
    try install_first_boot.removeCredential(io, token_path);
}

fn resendInstallTerminal(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, journal: *install_first_boot.LocalJournal, journal_path: []const u8, token_path: []const u8) !void {
    const body = journal.terminal_event_body orelse return error.InvalidInstallFirstBootJournal;
    if (journal.terminal_event_id == null) return error.InvalidInstallFirstBootJournal;
    try postInstallEventBody(io, allocator, url, token, body);
    try journal.acknowledge();
    try install_first_boot.persistJournal(io, allocator, journal_path, journal.*);
    try install_first_boot.removeCredential(io, token_path);
}

fn runInstallStep(io: std.Io, allocator: std.mem.Allocator, command: []const u8, timeout_s: u32, attempts: u8) !void {
    const timeout = try std.fmt.allocPrint(allocator, "{d}", .{timeout_s});
    defer allocator.free(timeout);
    var attempt: u8 = 0;
    while (attempt < attempts) : (attempt += 1) {
        const result = try std.process.run(allocator, io, .{ .argv = &.{ "timeout", "--signal=TERM", timeout, "/bin/sh", "-c", command } });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        if (attempt + 1 < attempts) std.Io.sleep(io, .fromSeconds(1), .awake) catch {};
    }
    return error.InstallFirstBootStepFailed;
}

fn postLifecycle(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: []const u8, seq: u64, expected: []const u8, phase: []const u8) !void {
    const body = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"session_id\":\"{s}\",\"event_seq\":{d},\"expected_phase\":\"{s}\",\"phase\":\"{s}\"}}\n", .{ session, seq, expected, phase });
    defer allocator.free(body);
    const parsed = try http.Url.parse(url);
    const headers = try nativeHeaders(allocator, token, session);
    defer allocator.free(headers.auth);
    defer allocator.free(headers.session);
    const status = try http.post(io, allocator, parsed, &.{
        .{ .name = "Authorization", .value = headers.auth },
        .{ .name = "X-NodeForge-Session", .value = headers.session },
        .{ .name = "Content-Type", .value = "application/json" },
    }, body);
    if (status < 200 or status >= 300) return error.LifecycleEventRejected;
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
            std.debug.print("nodeforge-agent: 子进程异常终止: {s}\n", .{result.stderr});
            return error.SubprocessFailed;
        },
    }
}

// ── v0.4 token 简化：两 session handoff 解析测试 ──────────────────────────

test "handoff schema v2 separates read_session from delivery session" {
    const json =
        \\{"schema_version":2,"node":"n1","session":"delivery-sess","read_session":"boot-sess","agent_plan_url":"http://srv/api/v1/boot-sessions/delivery-sess/agent-plan/abcd","agent_plan_digest":"abcd","event_url":"http://srv/api/v1/nodes/n1/events"}
    ;
    const h = try parseHandoff(std.testing.allocator, json);
    defer freeHandoff(std.testing.allocator, &h);
    try std.testing.expectEqualStrings("n1", h.node);
    try std.testing.expectEqualStrings("delivery-sess", h.session);
    try std.testing.expectEqualStrings("boot-sess", h.read_session);
    try std.testing.expectEqualStrings("abcd", h.agent_plan_digest);
    try std.testing.expectEqualStrings("http://srv/api/v1/boot-sessions/delivery-sess", h.agent_plan_url_root);
}

test "handoff schema v1 falls back read_session to session for backward compat" {
    const json =
        \\{"schema_version":1,"node":"n1","session":"only-sess","agent_plan_url":"http://srv/api/v1/boot-sessions/only-sess/agent-plan/abcd","agent_plan_digest":"abcd","event_url":"http://srv/api/v1/nodes/n1/events"}
    ;
    const h = try parseHandoff(std.testing.allocator, json);
    defer freeHandoff(std.testing.allocator, &h);
    // v1 没有 read_session 字段，回退为 session。
    try std.testing.expectEqualStrings("only-sess", h.session);
    try std.testing.expectEqualStrings("only-sess", h.read_session);
}
