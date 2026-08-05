//! # v0.4 逻辑容量 workload harness（不启真实 PXE VM）
//!
//! 单独运行：`zig build test-v0.4-capacity`
//!
//! 覆盖：
//! - install + diskless 共享部署波次准入（`DeploymentWaveAdmission`）
//! - 256 / 512 / 1024 逻辑波次与 `capacity.exhausted` fail-closed
//! - AgentPlan 正文外置；索引 checkpoint 不吃 N×256KiB
//! - 结构化 `[capacity-evidence]`：当前/峰值 RSS、FD、线程、checkpoint/目录字节、重载毫秒
//!
//! 本模块证据是**逻辑节点** workload，不能冒充 256/512 台真实机生产吞吐
//!（见延期项 `ENV-V04-PRODUCTION-SCALE`）。

const std = @import("std");
const builtin = @import("builtin");
const diskless_delivery = @import("diskless_delivery.zig");
const install_first_boot_store = @import("install_first_boot_store.zig");
const capacity = @import("capacity.zig");
const lifecycle = @import("diskless_session.zig");

const secret_bytes = [_]u8{0xc4} ** 32;
const rootfs_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const rootfs_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// 进程生命周期峰值 RSS（KiB，getrusage maxrss）——只升不降，不能证明回落。
fn samplePeakRssKb() usize {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const raw: i64 = usage.maxrss;
    if (raw <= 0) return 0;
    return switch (builtin.os.tag) {
        .linux => @intCast(raw),
        else => @intCast(@divTrunc(raw, 1024)),
    };
}

/// 当前常驻集大小（KiB）；free/deinit 后可下降。尽力而为。
fn sampleCurrentRssKb() usize {
    const io = std.testing.io;
    switch (builtin.os.tag) {
        .linux => {
            const text = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/status", std.testing.allocator, .limited(8192)) catch return 0;
            defer std.testing.allocator.free(text);
            return parseStatusKb(text, "VmRSS:");
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            const task = std.c.mach_task_self();
            if (task == std.c.TASK.NULL) return 0;
            var info_count = std.c.TASK.VM.INFO_COUNT;
            var vm_info: std.c.task_vm_info_data_t = undefined;
            @memset(std.mem.asBytes(&vm_info), 0);
            const kr = std.c.task_info(task, std.c.TASK.VM.INFO, @ptrCast(&vm_info), &info_count);
            if (kr != 0) return 0;
            return @intCast(vm_info.resident_size / 1024);
        },
        else => return 0,
    }
}

/// 从 /proc/self/status 文本解析 `key` 后的整数（如 VmRSS、Threads）。
fn parseStatusKb(text: []const u8, key: []const u8) usize {
    const idx = std.mem.indexOf(u8, text, key) orelse return 0;
    var i = idx + key.len;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    var end = i;
    while (end < text.len and text[end] >= '0' and text[end] <= '9') : (end += 1) {}
    return std.fmt.parseInt(usize, text[i..end], 10) catch 0;
}

/// 当前线程数（Linux /proc 或 macOS task_threads）。
fn sampleThreadCount() usize {
    const io = std.testing.io;
    switch (builtin.os.tag) {
        .linux => {
            const text = std.Io.Dir.cwd().readFileAlloc(io, "/proc/self/status", std.testing.allocator, .limited(8192)) catch return 0;
            defer std.testing.allocator.free(text);
            return parseStatusKb(text, "Threads:");
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            var list: std.c.mach_port_array_t = undefined;
            var count: std.c.mach_msg_type_number_t = 0;
            const task = std.c.mach_task_self();
            const kr = std.c.task_threads(task, &list, &count);
            if (kr != 0) return 0;
            // 释放每个线程 port right，再释放内核数组。
            var i: std.c.mach_msg_type_number_t = 0;
            while (i < count) : (i += 1) {
                _ = std.c.mach_port_deallocate(task, list[i]);
            }
            const byte_len: std.c.vm_size_t = @as(std.c.vm_size_t, count) * @sizeOf(std.c.mach_port_t);
            _ = std.c.vm_deallocate(task, @intFromPtr(list), byte_len);
            return @intCast(count);
        },
        else => return 0,
    }
}

/// 打开的 FD 数量（/dev/fd 或 /proc/self/fd；不可用则 0）。
fn sampleFdCount() usize {
    const io = std.testing.io;
    var dir = std.Io.Dir.cwd().openDir(io, "/dev/fd", .{ .iterate = true }) catch
        std.Io.Dir.cwd().openDir(io, "/proc/self/fd", .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(io) catch null) |_| n += 1;
    return n;
}

/// 单文件表观字节数；失败返回 0。
fn fileSizeBytes(path: []const u8) usize {
    if (path.len == 0) return 0;
    const io = std.testing.io;
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return 0;
    defer file.close(io);
    const st = file.stat(io) catch return 0;
    return @intCast(st.size);
}

/// 目录下一层普通文件总字节（非递归）。
fn dirSizeBytes(path: []const u8) usize {
    if (path.len == 0) return 0;
    const io = std.testing.io;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    var total: usize = 0;
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        var file = dir.openFile(io, entry.name, .{}) catch continue;
        defer file.close(io);
        const st = file.stat(io) catch continue;
        total +|= @intCast(st.size);
    }
    return total;
}

fn nowMs() i64 {
    return std.Io.Clock.real.now(std.testing.io).toMilliseconds();
}

/// first-boot 终态 acknowledge 并 commit（测试辅助）。
fn ackCommit(store: *install_first_boot_store.Store, node_id: []const u8, generation: u64) !void {
    var undo = try store.acknowledge(node_id, generation, true);
    store.commitAcknowledge(&undo);
}

/// 单波次证据快照，供 `assertEvidence` / `reportWave` 使用。
const WaveEvidence = struct {
    tag: []const u8,
    wave: *const capacity.DeploymentWaveAdmission,
    diskless_active: usize,
    install_active: usize,
    diskless_terminal: usize = 0,
    install_terminal: usize = 0,
    checkpoint_bytes: usize = 0,
    plan_dir_bytes: usize = 0,
    reload_ms: i64 = -1,
    /// true 时要求 wave.count == diskless_active + install_active（无在途 ack）。
    require_wave_match: bool = true,
};

/// 逻辑容量证据硬闸（不仅靠人工读日志）。
fn assertEvidence(ev: WaveEvidence) !void {
    const total = ev.diskless_active + ev.install_active;
    if (ev.require_wave_match) {
        try std.testing.expectEqual(total, ev.wave.count());
    }
    if (ev.checkpoint_bytes > 0) {
        try std.testing.expect(ev.checkpoint_bytes < capacity.checkpoint_index_read_max_bytes);
    }
    const threads = sampleThreadCount();
    if (threads > 0) {
        try std.testing.expect(threads < 64);
    }
    const cur = sampleCurrentRssKb();
    const peak = samplePeakRssKb();
    if (cur > 0 and peak > 0) {
        try std.testing.expect(peak >= cur);
    }
}

/// 校验证据后打印 `[capacity-evidence]` 行（runbook 收集）。
fn reportWave(ev: WaveEvidence) !void {
    try assertEvidence(ev);
    const total = ev.diskless_active + ev.install_active;
    std.debug.print(
        \\
        \\[capacity-evidence] {s}
        \\  wave_active={d} wave_limit={d} diskless_active={d} install_active={d} total={d}
        \\  diskless_terminal={d} install_terminal={d}
        \\  rss_current_kb={d} rss_peak_kb={d} fd={d} threads={d}
        \\  checkpoint_bytes={d} plan_dir_bytes={d} reload_ms={d}
        \\
    ,
        .{
            ev.tag,
            ev.wave.count(),
            ev.wave.limit,
            ev.diskless_active,
            ev.install_active,
            total,
            ev.diskless_terminal,
            ev.install_terminal,
            sampleCurrentRssKb(),
            samplePeakRssKb(),
            sampleFdCount(),
            sampleThreadCount(),
            ev.checkpoint_bytes,
            ev.plan_dir_bytes,
            ev.reload_ms,
        },
    );
}

fn countDisklessTerminals(store: *const diskless_delivery.Store) usize {
    var n: usize = 0;
    for (&store.terminal_summaries) |slot| {
        if (slot.used) n += 1;
    }
    return n;
}

fn countInstallTerminals(store: *const install_first_boot_store.Store) usize {
    var n: usize = 0;
    for (&store.terminals) |slot| {
        if (slot.used) n += 1;
    }
    return n;
}

/// 断言错误映射到公共码 `capacity.exhausted`。
fn expectCapacityExhaustedMapped(err: anyerror) !void {
    const code = capacity.publicErrorCode(err) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(capacity.exhausted_code, code);
}

/// 连续 begin 填充 `count` 个活跃 diskless session。
fn fillDisklessWave(store: *diskless_delivery.Store, count: usize, name_prefix: []const u8) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var node_buf: [48]u8 = undefined;
        const node = try std.fmt.bufPrint(&node_buf, "{s}-{d}", .{ name_prefix, i });
        _ = try store.begin(
            std.testing.io,
            node,
            "profile",
            rootfs_digest,
            rootfs_sha,
            4096,
            16384,
            "5.14.0",
            50,
            64,
            32,
            100,
            1000 + @as(i64, @intCast(i)),
        );
    }
}

/// 将单个 diskless session 推到终态（canonical 事件链）。
fn driveOneToTerminal(store: *diskless_delivery.Store, session_id: *const [diskless_delivery.id_len]u8) !void {
    try store.markBootConfigFetched(std.testing.io, session_id);
    var seq: u64 = 0;
    const chain = [_]lifecycle.Phase{
        .diskless_initrd_started,
        .diskless_rootfs_downloading,
        .diskless_rootfs_verified,
        .diskless_rootfs_mounted,
        .diskless_switching_root,
        .diskless_agent_configuring,
        .diskless_running,
    };
    var expected: lifecycle.Phase = .boot_config_fetched;
    for (chain) |target| {
        _ = try store.advanceEvent(std.testing.io, session_id, expected, target, seq, 2000 + @as(i64, @intCast(seq)));
        expected = target;
        seq += 1;
    }
}

/// 将 store 结构槽抬到 ceiling 并绑定共享波次准入。
fn bindWave(diskless: *diskless_delivery.Store, first_boot: ?*install_first_boot_store.Store, wave: *capacity.DeploymentWaveAdmission) void {
    diskless.setEffective(capacity.store_ceiling);
    diskless.setWave(wave);
    if (first_boot) |fb| {
        fb.setEffective(capacity.store_ceiling);
        fb.setWave(wave);
    }
}

/// 加载持久 diskless checkpoint，断言每个非终态 session 恢复，
/// 并按恢复的 active 数 reseed 新的共享波次。
/// 返回墙钟重载毫秒 + reseed 后的 wave。
fn reloadDisklessCheckpoint(checkpoint: []const u8, expected_active: usize, wave_limit: usize) !struct { reload_ms: i64, wave: capacity.DeploymentWaveAdmission } {
    const after = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(after);
    after.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
    defer after.deinit();
    after.setEffective(capacity.store_ceiling);
    const t0 = nowMs();
    const restored = try after.load(std.testing.io, 10, 2000);
    const t1 = nowMs();
    try std.testing.expectEqual(expected_active, restored);
    try std.testing.expectEqual(expected_active, after.activeAdmissionCount());

    // 枚举每个恢复槽：须为 active、非终态、可用。
    var live: usize = 0;
    for (&after.sessions) |s| {
        if (!s.active) continue;
        try std.testing.expect(!s.phase.isTerminal());
        try std.testing.expect(!s.recovery_incomplete);
        live += 1;
    }
    try std.testing.expectEqual(expected_active, live);

    // 生产恢复路径：按真实 store 占用 reseed 共享波次。
    var wave = capacity.DeploymentWaveAdmission.init(wave_limit);
    after.setWave(&wave);
    wave.reseed(after.activeAdmissionCount());
    try std.testing.expectEqual(expected_active, wave.count());
    // 达限或超限时，reseed 后新准入仍 fail-closed。
    if (expected_active >= wave_limit) {
        try std.testing.expectEqual(@as(usize, 0), wave.remaining());
        try std.testing.expectError(error.CapacityExhausted, wave.tryAcquire());
        // 绑定 store 的 begin 在 reseed 波次下同样 fail-closed。
        try std.testing.expectError(error.DisklessSessionCapacity, after.begin(
            std.testing.io,
            "reload-overflow",
            "profile",
            rootfs_digest,
            rootfs_sha,
            1,
            2,
            "k",
            50,
            1,
            1,
            100,
            9999,
        ));
    }
    return .{ .reload_ms = t1 - t0, .wave = wave };
}

/// 相对保留后基线的有界增长：`pct_num/pct_den` 比例余量 + `absolute_slack`。
fn expectStableBand(value: usize, baseline: usize, pct_num: usize, pct_den: usize, absolute_slack: usize) !void {
    if (baseline == 0) return;
    const frac = if (pct_den == 0) 0 else (baseline * pct_num) / pct_den;
    const allowed = baseline + frac + absolute_slack;
    try std.testing.expect(value <= allowed);
}

/// 同 Node 复用轮次中，持久化体积应基本持平。
fn expectNearEqualSize(value: usize, baseline: usize, absolute_slack: usize) !void {
    if (baseline == 0 and value == 0) return;
    const hi = baseline + absolute_slack;
    const lo = if (baseline > absolute_slack) baseline - absolute_slack else 0;
    try std.testing.expect(value <= hi);
    try std.testing.expect(value >= lo);
}

/// 拒绝连续释放采样之间的**失控** RSS 斜率。
/// 进程级 allocator 下 JSON 持久化造成的等幅 freelist 跳动是预期的；
/// 产品保留 bug 应体现为 checkpoint / terminal 计数增长（另有断言）。
/// 第二次跳变既大又显著超过第一次时，不是 freelist 噪声——判 FAIL。
fn expectNoRunawayRssSlope(delta_prev: usize, delta_now: usize) !void {
    const large: usize = 12 * 1024;
    if (delta_now <= large) return;
    // 第二次跳变在已较大时不得超过第一次 + 4 MiB。
    try std.testing.expect(delta_now <= delta_prev + 4 * 1024);
}

/// 将 install first-boot entry 推到 handoff→steps→terminal→ack。
fn driveInstallToAck(store: *install_first_boot_store.Store, node: []const u8, gen: u64) !void {
    try store.handoff(node, gen);
    try store.started(node, gen, "s");
    try store.beginStep(node, gen, 0);
    try store.stepSucceeded(node, gen);
    try store.terminal(node, gen, true, "t");
    try ackCommit(store, node, gen);
}

/// 加载 first-boot checkpoint，校验 active/terminal 计数、指纹完整性、
/// journal 切片回绑。**不会**让 `store.wave` 指向辅助局部变量——调用方
/// 返回后须对自有 wave 存储执行 `setWave` + `reseed`。
fn reloadFirstBootCheckpoint(
    path: []const u8,
    expected_active: usize,
    expected_terminal: usize,
    daemon_secret: []const u8,
) !struct { reload_ms: i64, store: *install_first_boot_store.Store } {
    const after = try std.testing.allocator.create(install_first_boot_store.Store);
    errdefer std.testing.allocator.destroy(after);
    after.* = .{};
    after.setEffective(capacity.store_ceiling);
    const t0 = nowMs();
    try after.load(std.testing.io, std.testing.allocator, path, daemon_secret);
    const t1 = nowMs();
    try std.testing.expectEqual(expected_active, after.activeCount());
    try std.testing.expectEqual(expected_terminal, countInstallTerminals(after));

    // 指纹 + journal 内部切片须回绑到 entry 自有缓冲。
    var checked: usize = 0;
    for (&after.entries) |*e| {
        if (!e.used) continue;
        try std.testing.expectEqual(@as(u8, install_first_boot_store.fingerprint_cap), e.fingerprint_len);
        try std.testing.expect(e.journal.server != .recovery_incomplete);
        try std.testing.expect(e.journal.local != .recovery_incomplete);
        if (e.started_len > 0) {
            try std.testing.expectEqualStrings(e.startedEvent(), e.journal.started_event_id.?);
        }
        if (e.terminal_len > 0) {
            try std.testing.expectEqualStrings(e.terminalEvent(), e.journal.terminal_event_id.?);
        }
        checked += 1;
        if (checked >= 8) break; // 抽样即可，避免 O(N) 噪音
    }
    try std.testing.expect(checked > 0 or expected_active == 0);

    return .{ .reload_ms = t1 - t0, .store = after };
}

/// 将 store 绑定到调用方 wave，按真实 active reseed；满时可断言 fail-closed。
fn reseedFirstBootWave(
    store: *install_first_boot_store.Store,
    wave: *capacity.DeploymentWaveAdmission,
    expect_full: bool,
    daemon_secret: []const u8,
) !void {
    store.setWave(wave);
    wave.reseed(store.activeCount());
    try std.testing.expectEqual(store.activeCount(), wave.count());
    if (expect_full) {
        try std.testing.expectError(error.CapacityExhausted, wave.tryAcquire());
        try std.testing.expectError(error.FirstBootJournalCapacity, store.create("reload-overflow", 99999, 1, plan_digest, daemon_secret));
        try expectCapacityExhaustedMapped(error.FirstBootJournalCapacity);
    }
}

test "v0.4 workload: 256 diskless active wave" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
    defer std.testing.allocator.free(checkpoint);
    const plan_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-agent-plans", .{dir});
    defer std.testing.allocator.free(plan_dir);

    var wave = capacity.DeploymentWaveAdmission.init(256);
    const store = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(store);
    store.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
    defer store.deinit();
    bindWave(store, null, &wave);
    try fillDisklessWave(store, 256, "w256");
    try std.testing.expectEqual(@as(usize, 256), wave.count());
    try std.testing.expectEqual(@as(usize, 256), store.activeAdmissionCount());
    const overflow = store.begin(
        std.testing.io,
        "overflow",
        "profile",
        rootfs_digest,
        rootfs_sha,
        1,
        2,
        "k",
        50,
        1,
        1,
        100,
        9999,
    );
    try std.testing.expectError(error.DisklessSessionCapacity, overflow);
    try expectCapacityExhaustedMapped(error.DisklessSessionCapacity);
    const ck_bytes = fileSizeBytes(checkpoint);
    try std.testing.expect(ck_bytes > 0);
    const reload = try reloadDisklessCheckpoint(checkpoint, 256, 256);
    try reportWave(.{
        .tag = "diskless-256",
        .wave = &wave,
        .diskless_active = store.activeAdmissionCount(),
        .install_active = 0,
        .checkpoint_bytes = ck_bytes,
        .plan_dir_bytes = dirSizeBytes(plan_dir),
        .reload_ms = reload.reload_ms,
    });
    try reportWave(.{
        .tag = "diskless-256-reload",
        .wave = &reload.wave,
        .diskless_active = 256,
        .install_active = 0,
        .checkpoint_bytes = ck_bytes,
        .plan_dir_bytes = dirSizeBytes(plan_dir),
        .reload_ms = reload.reload_ms,
    });
}

// Config lowered across restart: restored active may exceed new limit. reseed must
// keep the real count and refuse new admits until drain (never truncate).
test "v0.4 workload: reseed preserves active above lowered limit" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
    defer std.testing.allocator.free(checkpoint);

    // First wave: admit 24 under limit 24 and persist.
    {
        var wave_hi = capacity.DeploymentWaveAdmission.init(24);
        const writer = try std.testing.allocator.create(diskless_delivery.Store);
        defer std.testing.allocator.destroy(writer);
        writer.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
        defer writer.deinit();
        bindWave(writer, null, &wave_hi);
        try fillDisklessWave(writer, 24, "rs");
        try std.testing.expectEqual(@as(usize, 24), writer.activeAdmissionCount());
    }

    // Restart with lowered limit 16; restore 24 non-terminal sessions.
    var wave_lo = capacity.DeploymentWaveAdmission.init(16);
    const restored_store = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(restored_store);
    restored_store.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
    defer restored_store.deinit();
    restored_store.setEffective(capacity.store_ceiling);
    restored_store.setWave(&wave_lo);
    const n = try restored_store.load(std.testing.io, 10, 2000);
    try std.testing.expectEqual(@as(usize, 24), n);
    // Production path: reseed from real store counts (may exceed new limit).
    wave_lo.reseed(restored_store.activeAdmissionCount());
    try std.testing.expectEqual(@as(usize, 24), wave_lo.count());
    try std.testing.expect(wave_lo.overLimit());
    try std.testing.expectError(error.DisklessSessionCapacity, restored_store.begin(
        std.testing.io,
        "new-after-lower",
        "profile",
        rootfs_digest,
        rootfs_sha,
        1,
        2,
        "k",
        50,
        1,
        1,
        100,
        9999,
    ));
    // Drain one session to terminal → still over limit → still refuse.
    const heap = try std.testing.allocator.alloc(diskless_delivery.Session, diskless_delivery.max_sessions);
    defer std.testing.allocator.free(heap);
    const sessions = restored_store.snapshot(heap);
    try std.testing.expect(sessions.len >= 1);
    try driveOneToTerminal(restored_store, &sessions[0].session_id);
    try std.testing.expectEqual(@as(usize, 23), wave_lo.count());
    try std.testing.expectError(error.DisklessSessionCapacity, restored_store.begin(
        std.testing.io,
        "still-over",
        "profile",
        rootfs_digest,
        rootfs_sha,
        1,
        2,
        "k",
        50,
        1,
        1,
        100,
        9999,
    ));
    try reportWave(.{
        .tag = "reseed-over-limit-24>16",
        .wave = &wave_lo,
        .diskless_active = restored_store.activeAdmissionCount(),
        .install_active = 0,
        .diskless_terminal = countDisklessTerminals(restored_store),
        .checkpoint_bytes = fileSizeBytes(checkpoint),
    });
}

// Mixed install+diskless reseed after config lower: sum of both stores preserved above limit.
test "v0.4 workload: reseed mixed install+diskless above lowered limit" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const d_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
    defer std.testing.allocator.free(d_path);
    const fb_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/first-boot.json", .{dir});
    defer std.testing.allocator.free(fb_path);

    // Wave 20: 12 diskless + 8 install, durable.
    {
        var wave_hi = capacity.DeploymentWaveAdmission.init(20);
        const d = try std.testing.allocator.create(diskless_delivery.Store);
        defer std.testing.allocator.destroy(d);
        d.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", d_path);
        defer d.deinit();
        const fb = try std.testing.allocator.create(install_first_boot_store.Store);
        defer std.testing.allocator.destroy(fb);
        fb.* = .{};
        bindWave(d, fb, &wave_hi);
        try fillDisklessWave(d, 12, "mix-rs-d");
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            var node_buf: [32]u8 = undefined;
            const node = try std.fmt.bufPrint(&node_buf, "mix-rs-i-{d}", .{i});
            _ = try fb.create(node, 1, 1, plan_digest, "secret");
        }
        try std.testing.expectEqual(@as(usize, 20), wave_hi.count());
        try fb.save(std.testing.io, std.testing.allocator, fb_path);
    }

    var wave_lo = capacity.DeploymentWaveAdmission.init(12);
    const d2 = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(d2);
    d2.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", d_path);
    defer d2.deinit();
    const fb2 = try std.testing.allocator.create(install_first_boot_store.Store);
    defer std.testing.allocator.destroy(fb2);
    fb2.* = .{};
    d2.setEffective(capacity.store_ceiling);
    d2.setWave(&wave_lo);
    fb2.setEffective(capacity.store_ceiling);
    fb2.setWave(&wave_lo);
    const restored_d = try d2.load(std.testing.io, 10, 2000);
    try fb2.load(std.testing.io, std.testing.allocator, fb_path, "secret");
    try std.testing.expectEqual(@as(usize, 12), restored_d);
    try std.testing.expectEqual(@as(usize, 8), fb2.activeCount());
    wave_lo.reseed(d2.activeAdmissionCount() + fb2.activeCount());
    try std.testing.expectEqual(@as(usize, 20), wave_lo.count());
    try std.testing.expect(wave_lo.overLimit());
    try std.testing.expectError(error.DisklessSessionCapacity, d2.begin(
        std.testing.io,
        "new-d",
        "profile",
        rootfs_digest,
        rootfs_sha,
        1,
        2,
        "k",
        50,
        1,
        1,
        100,
        9999,
    ));
    try std.testing.expectError(error.FirstBootJournalCapacity, fb2.create("new-i", 1, 1, plan_digest, "secret"));
    try reportWave(.{
        .tag = "reseed-mixed-20>12",
        .wave = &wave_lo,
        .diskless_active = d2.activeAdmissionCount(),
        .install_active = fb2.activeCount(),
        .checkpoint_bytes = fileSizeBytes(d_path),
    });
}

// Product contract: install_active + diskless_active share one limit; limit+1 fails closed
// with capacity.exhausted mapping, for both fill orderings.
test "v0.4 workload: shared wave fails closed across install/diskless orders" {
    // Order A: fill with diskless to limit-1, last slot install, then both types fail.
    {
        var wave = capacity.DeploymentWaveAdmission.init(8);
        const d = try std.testing.allocator.create(diskless_delivery.Store);
        defer std.testing.allocator.destroy(d);
        d.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", "");
        defer d.deinit();
        const fb = try std.testing.allocator.create(install_first_boot_store.Store);
        defer std.testing.allocator.destroy(fb);
        fb.* = .{};
        bindWave(d, fb, &wave);

        try fillDisklessWave(d, 7, "ord-a");
        _ = try fb.create("ord-a-last", 1, 1, plan_digest, "secret");
        try std.testing.expectEqual(@as(usize, 8), wave.count());
        try std.testing.expectEqual(@as(usize, 7), d.activeAdmissionCount());
        try std.testing.expectEqual(@as(usize, 1), fb.activeCount());
        try std.testing.expectEqual(@as(usize, 8), d.activeAdmissionCount() + fb.activeCount());

        try std.testing.expectError(error.DisklessSessionCapacity, d.begin(
            std.testing.io,
            "overflow-d",
            "profile",
            rootfs_digest,
            rootfs_sha,
            1,
            2,
            "k",
            50,
            1,
            1,
            100,
            9999,
        ));
        try std.testing.expectError(error.FirstBootJournalCapacity, fb.create("overflow-i", 1, 1, plan_digest, "secret"));
        try expectCapacityExhaustedMapped(error.DisklessSessionCapacity);
        try expectCapacityExhaustedMapped(error.FirstBootJournalCapacity);
        try reportWave(.{
            .tag = "shared-order-diskless-first",
            .wave = &wave,
            .diskless_active = d.activeAdmissionCount(),
            .install_active = fb.activeCount(),
        });
    }
    // Order B: fill with install to limit-1, last slot diskless.
    {
        var wave = capacity.DeploymentWaveAdmission.init(8);
        const d = try std.testing.allocator.create(diskless_delivery.Store);
        defer std.testing.allocator.destroy(d);
        d.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", "");
        defer d.deinit();
        const fb = try std.testing.allocator.create(install_first_boot_store.Store);
        defer std.testing.allocator.destroy(fb);
        fb.* = .{};
        bindWave(d, fb, &wave);

        var i: usize = 0;
        while (i < 7) : (i += 1) {
            var node_buf: [32]u8 = undefined;
            const node = try std.fmt.bufPrint(&node_buf, "ord-b-{d}", .{i});
            _ = try fb.create(node, 1, 1, plan_digest, "secret");
        }
        try fillDisklessWave(d, 1, "ord-b-d");
        try std.testing.expectEqual(@as(usize, 8), wave.count());
        try std.testing.expectEqual(@as(usize, 1), d.activeAdmissionCount());
        try std.testing.expectEqual(@as(usize, 7), fb.activeCount());

        try std.testing.expectError(error.DisklessSessionCapacity, d.begin(
            std.testing.io,
            "overflow-d2",
            "profile",
            rootfs_digest,
            rootfs_sha,
            1,
            2,
            "k",
            50,
            1,
            1,
            100,
            9999,
        ));
        try std.testing.expectError(error.FirstBootJournalCapacity, fb.create("overflow-i2", 1, 1, plan_digest, "secret"));
        try reportWave(.{
            .tag = "shared-order-install-first",
            .wave = &wave,
            .diskless_active = d.activeAdmissionCount(),
            .install_active = fb.activeCount(),
        });
    }
}

// Product contract: continuous 3×256 mixed waves reuse the same 128 install +
// 128 diskless Node ids (only generation/session advances). After each wave's
// terminal retention/compact, terminal summaries stay at 128/128 and resource
// sizes return to a bounded stable band (not linear growth with wave number).
//
// Critical harness rule: large temporary buffers must NOT be `defer`-freed inside
// the while body — Zig defers run at function/scope exit, so loop-body defers
// retain N copies and fake an RSS leak. Snapshot buffers are allocated once
// outside the loop; per-round work uses a nested `{ ... }` block only for
// non-retained locals.
test "v0.4 workload: 3x256 mixed reuse after terminal" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
    defer std.testing.allocator.free(checkpoint);
    const plan_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-agent-plans", .{dir});
    defer std.testing.allocator.free(plan_dir);

    var wave = capacity.DeploymentWaveAdmission.init(256);
    // Leak-checking GPA owned by this test only (not the process-global testing
    // allocator). deinit asserts no product-side leak after all rounds.
    var store_gpa: std.heap.DebugAllocator(.{}) = .init;
    defer switch (store_gpa.deinit()) {
        .ok => {},
        .leak => @panic("3x256 mixed: store_gpa reported a leak"),
    };
    const store_alloc = store_gpa.allocator();
    const diskless = try store_alloc.create(diskless_delivery.Store);
    defer store_alloc.destroy(diskless);
    diskless.* = diskless_delivery.Store.init(store_alloc, &secret_bytes, "dep", checkpoint);
    defer diskless.deinit();
    const first_boot = try store_alloc.create(install_first_boot_store.Store);
    defer store_alloc.destroy(first_boot);
    first_boot.* = .{};
    bindWave(diskless, first_boot, &wave);

    // Fixed Node set across rounds — capacity-reuse stability, not fleet expansion.
    const diskless_prefix = "mix-d";
    const install_prefix = "mix-fb";

    // ONE snapshot buffer for all rounds — never alloc+defer inside the while body
    // (Zig defers run at function/scope exit, not each iteration).
    const heap = try store_alloc.alloc(diskless_delivery.Session, diskless_delivery.max_sessions);
    defer store_alloc.free(heap);
    var id_buf: [256][diskless_delivery.id_len]u8 = undefined;

    const fd_baseline = sampleFdCount();
    var fd_after_release_max: usize = 0;
    var rss_after: [3]usize = .{ 0, 0, 0 };
    var baseline_ck_bytes: usize = 0;
    var baseline_plan_bytes: usize = 0;
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const gen: u64 = @intCast(round + 1);
        {
            // Nested scope: round-local control flow only; no large deferred allocs.
            try fillDisklessWave(diskless, 128, diskless_prefix);
            var i: usize = 0;
            while (i < 128) : (i += 1) {
                var node_buf: [32]u8 = undefined;
                const node = try std.fmt.bufPrint(&node_buf, "{s}-{d}", .{ install_prefix, i });
                _ = try first_boot.create(node, gen, 1, plan_digest, "secret");
            }
            try std.testing.expectEqual(@as(usize, 256), wave.count());
            try std.testing.expectEqual(@as(usize, 128), diskless.activeAdmissionCount());
            try std.testing.expectEqual(@as(usize, 128), first_boot.activeCount());
            try std.testing.expectEqual(
                @as(usize, 256),
                diskless.activeAdmissionCount() + first_boot.activeCount(),
            );
            try std.testing.expectError(error.DisklessSessionCapacity, diskless.begin(
                std.testing.io,
                "overflow-d",
                "profile",
                rootfs_digest,
                rootfs_sha,
                1,
                2,
                "k",
                50,
                1,
                1,
                100,
                9999,
            ));
            try std.testing.expectError(error.FirstBootJournalCapacity, first_boot.create("overflow-i", 99, 1, plan_digest, "secret"));
            try expectCapacityExhaustedMapped(error.DisklessSessionCapacity);
            try expectCapacityExhaustedMapped(error.FirstBootJournalCapacity);
            // Same-node reuse: diskless begin supersedes prior terminal in-place.
            // Install keeps last-gen terminal until the new gen is acknowledged.
            try std.testing.expectEqual(@as(usize, 0), countDisklessTerminals(diskless));
            try std.testing.expectEqual(@as(usize, if (round == 0) 0 else 128), countInstallTerminals(first_boot));
            try reportWave(.{
                .tag = "mixed-256-full",
                .wave = &wave,
                .diskless_active = diskless.activeAdmissionCount(),
                .install_active = first_boot.activeCount(),
                .diskless_terminal = countDisklessTerminals(diskless),
                .install_terminal = countInstallTerminals(first_boot),
                .checkpoint_bytes = fileSizeBytes(checkpoint),
                .plan_dir_bytes = dirSizeBytes(plan_dir),
            });

            // Reuse outer heap/id_buf — do NOT alloc+defer free here.
            const sessions = diskless.snapshot(heap);
            try std.testing.expectEqual(@as(usize, 128), sessions.len);
            for (sessions, 0..) |s, idx| id_buf[idx] = s.session_id;
            var j: usize = 0;
            while (j < sessions.len) : (j += 1) {
                if (diskless.find(&id_buf[j])) |s| {
                    if (!s.phase.isTerminal()) try driveOneToTerminal(diskless, &id_buf[j]);
                }
            }
            i = 0;
            while (i < 128) : (i += 1) {
                var node_buf: [32]u8 = undefined;
                const node = try std.fmt.bufPrint(&node_buf, "{s}-{d}", .{ install_prefix, i });
                try driveInstallToAck(first_boot, node, gen);
            }
        }

        try std.testing.expectEqual(@as(usize, 0), wave.count());
        try std.testing.expectEqual(@as(usize, 0), diskless.activeAdmissionCount());
        try std.testing.expectEqual(@as(usize, 0), first_boot.activeCount());
        // Retention keeps one terminal fact per Node, not per wave (128+128, not 128*round).
        try std.testing.expectEqual(@as(usize, 128), countDisklessTerminals(diskless));
        try std.testing.expectEqual(@as(usize, 128), countInstallTerminals(first_boot));

        const ck_now = fileSizeBytes(checkpoint);
        const plan_now = dirSizeBytes(plan_dir);
        // Sample RSS only after the round's nested work finished (no stack temps retained).
        const rss_now = sampleCurrentRssKb();
        rss_after[round] = rss_now;
        try reportWave(.{
            .tag = "mixed-256-after-release",
            .wave = &wave,
            .diskless_active = diskless.activeAdmissionCount(),
            .install_active = first_boot.activeCount(),
            .diskless_terminal = countDisklessTerminals(diskless),
            .install_terminal = countInstallTerminals(first_boot),
            .checkpoint_bytes = ck_now,
            .plan_dir_bytes = plan_now,
        });

        if (round == 0) {
            baseline_ck_bytes = ck_now;
            baseline_plan_bytes = plan_now;
        } else {
            // Primary product retention proof: durable footprint flat under same-Node
            // reuse (old bug: checkpoint ~318→636→953 KiB with distinct prefixes).
            try expectNearEqualSize(ck_now, baseline_ck_bytes, 4096);
            try expectNearEqualSize(plan_now, baseline_plan_bytes, 4096);
        }
        const fd_now = sampleFdCount();
        if (fd_now > fd_after_release_max) fd_after_release_max = fd_now;
    }
    // Process RSS (best-effort): after loop-body defer fix + dedicated store GPA +
    // same-Node reuse, hops must not runaway. OS/page retention can still hold
    // freed pages, so absolute RSS is not the product proof — checkpoint +
    // terminal counts + store_gpa leak check are. Still reject accelerating hops
    // and multi-round total > 48 MiB (would match old ~20 MiB×N harness bug).
    if (rss_after[0] > 0 and rss_after[1] > 0 and rss_after[2] > 0) {
        const d01 = if (rss_after[1] > rss_after[0]) rss_after[1] - rss_after[0] else 0;
        const d12 = if (rss_after[2] > rss_after[1]) rss_after[2] - rss_after[1] else 0;
        std.debug.print(
            "\n[capacity-evidence] mixed-256-rss-hops d01_kb={d} d12_kb={d} rss=[{d},{d},{d}]\n",
            .{ d01, d12, rss_after[0], rss_after[1], rss_after[2] },
        );
        try expectNoRunawayRssSlope(d01, d12);
        try std.testing.expect(d01 + d12 <= 48 * 1024);
    }
    // FD must not grow unboundedly across release rounds (allow small sampling noise).
    if (fd_baseline > 0 and fd_after_release_max > 0) {
        try std.testing.expect(fd_after_release_max <= fd_baseline + 32);
    }
}

test "v0.4 workload: 512 standard extension wave (diskless + install + 256 mixed)" {
    {
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir);
        const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
        defer std.testing.allocator.free(checkpoint);
        const plan_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-agent-plans", .{dir});
        defer std.testing.allocator.free(plan_dir);

        var wave = capacity.DeploymentWaveAdmission.init(512);
        const d_only = try std.testing.allocator.create(diskless_delivery.Store);
        defer std.testing.allocator.destroy(d_only);
        d_only.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
        defer d_only.deinit();
        bindWave(d_only, null, &wave);
        try fillDisklessWave(d_only, 512, "d512");
        try std.testing.expectEqual(@as(usize, 512), wave.count());
        try std.testing.expectError(error.DisklessSessionCapacity, d_only.begin(
            std.testing.io,
            "overflow",
            "profile",
            rootfs_digest,
            rootfs_sha,
            1,
            2,
            "k",
            50,
            1,
            1,
            100,
            9999,
        ));
        try expectCapacityExhaustedMapped(error.DisklessSessionCapacity);
        const ck_bytes = fileSizeBytes(checkpoint);
        try std.testing.expect(ck_bytes > 0);
        const reload = try reloadDisklessCheckpoint(checkpoint, 512, 512);
        try reportWave(.{
            .tag = "diskless-512",
            .wave = &wave,
            .diskless_active = d_only.activeAdmissionCount(),
            .install_active = 0,
            .checkpoint_bytes = ck_bytes,
            .plan_dir_bytes = dirSizeBytes(plan_dir),
            .reload_ms = reload.reload_ms,
        });
        try reportWave(.{
            .tag = "diskless-512-reload",
            .wave = &reload.wave,
            .diskless_active = 512,
            .install_active = 0,
            .checkpoint_bytes = ck_bytes,
            .plan_dir_bytes = dirSizeBytes(plan_dir),
            .reload_ms = reload.reload_ms,
        });
    }
    // 512 active first-boot: durable save/load + fingerprint/journal rebind + reseed.
    {
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir);
        const fb_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/first-boot.json", .{dir});
        defer std.testing.allocator.free(fb_path);

        var wave = capacity.DeploymentWaveAdmission.init(512);
        const fb_only = try std.testing.allocator.create(install_first_boot_store.Store);
        defer std.testing.allocator.destroy(fb_only);
        fb_only.* = .{};
        fb_only.setEffective(capacity.store_ceiling);
        fb_only.setWave(&wave);
        var i: usize = 0;
        while (i < 512) : (i += 1) {
            var node_buf: [32]u8 = undefined;
            const node = try std.fmt.bufPrint(&node_buf, "i512-{d}", .{i});
            _ = try fb_only.create(node, 1, 1, plan_digest, "secret");
            // Progress a sample so journal slices and fingerprints hit the wire.
            if (i < 16) {
                try fb_only.handoff(node, 1);
                try fb_only.started(node, 1, "s");
                try fb_only.beginStep(node, 1, 0);
                try fb_only.stepSucceeded(node, 1);
                try fb_only.terminal(node, 1, true, "t");
            }
        }
        try std.testing.expectEqual(@as(usize, 512), wave.count());
        try std.testing.expectError(error.FirstBootJournalCapacity, fb_only.create("overflow", 1, 1, plan_digest, "secret"));
        try expectCapacityExhaustedMapped(error.FirstBootJournalCapacity);
        try fb_only.save(std.testing.io, std.testing.allocator, fb_path);
        const ck_bytes = fileSizeBytes(fb_path);
        try std.testing.expect(ck_bytes > 0);
        try std.testing.expect(ck_bytes < capacity.checkpoint_index_read_max_bytes);
        try reportWave(.{
            .tag = "install-512",
            .wave = &wave,
            .diskless_active = 0,
            .install_active = fb_only.activeCount(),
            .checkpoint_bytes = ck_bytes,
        });

        const reload = try reloadFirstBootCheckpoint(fb_path, 512, 0, "secret");
        defer std.testing.allocator.destroy(reload.store);
        var wave_reload = capacity.DeploymentWaveAdmission.init(512);
        try reseedFirstBootWave(reload.store, &wave_reload, true, "secret");
        // Spot-check journal rebind on a progressed entry.
        const sample = reload.store.find("i512-0", 1) orelse return error.TestExpectedEqual;
        try std.testing.expectEqualStrings("s", sample.startedEvent());
        try std.testing.expectEqualStrings("t", sample.terminalEvent());
        try std.testing.expectEqualStrings(sample.startedEvent(), sample.journal.started_event_id.?);
        try std.testing.expectEqualStrings(sample.terminalEvent(), sample.journal.terminal_event_id.?);
        try reportWave(.{
            .tag = "install-512-reload",
            .wave = &wave_reload,
            .diskless_active = 0,
            .install_active = reload.store.activeCount(),
            .checkpoint_bytes = ck_bytes,
            .reload_ms = reload.reload_ms,
        });
    }
    // Durable mixed 256 diskless + 256 first-boot: separate reload then joint reseed.
    {
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(dir);
        const d_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
        defer std.testing.allocator.free(d_path);
        const fb_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/first-boot.json", .{dir});
        defer std.testing.allocator.free(fb_path);

        {
            var wave = capacity.DeploymentWaveAdmission.init(512);
            const d_mix = try std.testing.allocator.create(diskless_delivery.Store);
            defer std.testing.allocator.destroy(d_mix);
            d_mix.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", d_path);
            defer d_mix.deinit();
            const fb_mix = try std.testing.allocator.create(install_first_boot_store.Store);
            defer std.testing.allocator.destroy(fb_mix);
            fb_mix.* = .{};
            bindWave(d_mix, fb_mix, &wave);
            try fillDisklessWave(d_mix, 256, "mix-d");
            var i: usize = 0;
            while (i < 256) : (i += 1) {
                var node_buf: [32]u8 = undefined;
                const node = try std.fmt.bufPrint(&node_buf, "mix-i-{d}", .{i});
                _ = try fb_mix.create(node, 1, 1, plan_digest, "secret");
            }
            try std.testing.expectEqual(@as(usize, 512), wave.count());
            try std.testing.expectEqual(@as(usize, 256), d_mix.activeAdmissionCount());
            try std.testing.expectEqual(@as(usize, 256), fb_mix.activeCount());
            try std.testing.expectError(error.DisklessSessionCapacity, d_mix.begin(
                std.testing.io,
                "overflow",
                "profile",
                rootfs_digest,
                rootfs_sha,
                1,
                2,
                "k",
                50,
                1,
                1,
                100,
                9999,
            ));
            try std.testing.expectError(error.FirstBootJournalCapacity, fb_mix.create("overflow-i", 1, 1, plan_digest, "secret"));
            try fb_mix.save(std.testing.io, std.testing.allocator, fb_path);
            try reportWave(.{
                .tag = "mixed-256+256",
                .wave = &wave,
                .diskless_active = d_mix.activeAdmissionCount(),
                .install_active = fb_mix.activeCount(),
                .checkpoint_bytes = fileSizeBytes(d_path),
            });
        }

        // Restart both stores independently, then reseed shared wave from real sum.
        var wave2 = capacity.DeploymentWaveAdmission.init(512);
        const d2 = try std.testing.allocator.create(diskless_delivery.Store);
        defer std.testing.allocator.destroy(d2);
        d2.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", d_path);
        defer d2.deinit();
        const fb2 = try std.testing.allocator.create(install_first_boot_store.Store);
        defer std.testing.allocator.destroy(fb2);
        fb2.* = .{};
        d2.setEffective(capacity.store_ceiling);
        fb2.setEffective(capacity.store_ceiling);
        d2.setWave(&wave2);
        fb2.setWave(&wave2);
        const t0 = nowMs();
        const restored_d = try d2.load(std.testing.io, 10, 2000);
        try fb2.load(std.testing.io, std.testing.allocator, fb_path, "secret");
        const t1 = nowMs();
        try std.testing.expectEqual(@as(usize, 256), restored_d);
        try std.testing.expectEqual(@as(usize, 256), d2.activeAdmissionCount());
        try std.testing.expectEqual(@as(usize, 256), fb2.activeCount());
        const total = d2.activeAdmissionCount() + fb2.activeCount();
        try std.testing.expectEqual(@as(usize, 512), total);
        wave2.reseed(total);
        try std.testing.expectEqual(@as(usize, 512), wave2.count());
        // 513th object of either kind must fail closed after joint reseed.
        try std.testing.expectError(error.DisklessSessionCapacity, d2.begin(
            std.testing.io,
            "overflow-after-reseed",
            "profile",
            rootfs_digest,
            rootfs_sha,
            1,
            2,
            "k",
            50,
            1,
            1,
            100,
            9999,
        ));
        try std.testing.expectError(error.FirstBootJournalCapacity, fb2.create("overflow-after-reseed", 1, 1, plan_digest, "secret"));
        try expectCapacityExhaustedMapped(error.DisklessSessionCapacity);
        try expectCapacityExhaustedMapped(error.FirstBootJournalCapacity);
        try reportWave(.{
            .tag = "mixed-256+256-reload-reseed",
            .wave = &wave2,
            .diskless_active = d2.activeAdmissionCount(),
            .install_active = fb2.activeCount(),
            .checkpoint_bytes = fileSizeBytes(d_path),
            .reload_ms = t1 - t0,
        });
    }
}

// 256 acknowledged terminals + 256 still-active first-boot entries survive save/load
// with active/terminal separation and fingerprint integrity.
test "v0.4 workload: first-boot 256 terminal + 256 active checkpoint reload" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const fb_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/first-boot.json", .{dir});
    defer std.testing.allocator.free(fb_path);

    {
        var wave = capacity.DeploymentWaveAdmission.init(512);
        const store = try std.testing.allocator.create(install_first_boot_store.Store);
        defer std.testing.allocator.destroy(store);
        store.* = .{};
        store.setEffective(capacity.store_ceiling);
        store.setWave(&wave);

        // Wave A: 256 nodes → terminal + ack (free active, keep terminal summary).
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            var node_buf: [32]u8 = undefined;
            const node = try std.fmt.bufPrint(&node_buf, "term-{d}", .{i});
            _ = try store.create(node, 1, 1, plan_digest, "secret");
            try driveInstallToAck(store, node, 1);
        }
        try std.testing.expectEqual(@as(usize, 0), store.activeCount());
        try std.testing.expectEqual(@as(usize, 256), countInstallTerminals(store));
        try std.testing.expectEqual(@as(usize, 0), wave.count());

        // Wave B: 256 different nodes remain active (with journal progress on a sample).
        i = 0;
        while (i < 256) : (i += 1) {
            var node_buf: [32]u8 = undefined;
            const node = try std.fmt.bufPrint(&node_buf, "act-{d}", .{i});
            _ = try store.create(node, 1, 1, plan_digest, "secret");
            if (i < 8) {
                try store.handoff(node, 1);
                try store.started(node, 1, "s");
                try store.beginStep(node, 1, 0);
                try store.stepSucceeded(node, 1);
                try store.terminal(node, 1, true, "t");
            }
        }
        try std.testing.expectEqual(@as(usize, 256), store.activeCount());
        try std.testing.expectEqual(@as(usize, 256), countInstallTerminals(store));
        try std.testing.expectEqual(@as(usize, 256), wave.count());
        try store.save(std.testing.io, std.testing.allocator, fb_path);
        try reportWave(.{
            .tag = "install-256term+256act",
            .wave = &wave,
            .diskless_active = 0,
            .install_active = store.activeCount(),
            .install_terminal = countInstallTerminals(store),
            .checkpoint_bytes = fileSizeBytes(fb_path),
        });
    }

    const reload = try reloadFirstBootCheckpoint(fb_path, 256, 256, "secret");
    defer std.testing.allocator.destroy(reload.store);
    var wave_reload = capacity.DeploymentWaveAdmission.init(512);
    try reseedFirstBootWave(reload.store, &wave_reload, false, "secret");
    // Terminals separated from actives after restart.
    try std.testing.expect(reload.store.find("term-0", 1) == null);
    try std.testing.expect(reload.store.terminalSummary("term-0", null) != null);
    try std.testing.expect(reload.store.terminalSummary("term-0", null).?.success);
    const act = reload.store.find("act-0", 1) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("s", act.startedEvent());
    try std.testing.expectEqualStrings(act.startedEvent(), act.journal.started_event_id.?);
    // Remaining wave budget: 512 - 256 active = 256 free (terminals do not occupy wave).
    try std.testing.expectEqual(@as(usize, 256), wave_reload.remaining());
    _ = try reload.store.create("post-reload", 1, 1, plan_digest, "secret");
    try std.testing.expectEqual(@as(usize, 257), wave_reload.count());
    try std.testing.expectEqual(@as(usize, 257), reload.store.activeCount());
    try reportWave(.{
        .tag = "install-256term+256act-reload",
        .wave = &wave_reload,
        .diskless_active = 0,
        .install_active = reload.store.activeCount(),
        .install_terminal = countInstallTerminals(reload.store),
        .checkpoint_bytes = fileSizeBytes(fb_path),
        .reload_ms = reload.reload_ms,
    });
}

test "v0.4 workload: 1024 pressure wave" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
    defer std.testing.allocator.free(checkpoint);
    const plan_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-agent-plans", .{dir});
    defer std.testing.allocator.free(plan_dir);

    var wave = capacity.DeploymentWaveAdmission.init(1024);
    const store = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(store);
    store.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
    defer store.deinit();
    bindWave(store, null, &wave);
    try fillDisklessWave(store, 1024, "w1024");
    try std.testing.expectEqual(@as(usize, 1024), wave.count());
    try std.testing.expectError(error.DisklessSessionCapacity, store.begin(
        std.testing.io,
        "overflow",
        "profile",
        rootfs_digest,
        rootfs_sha,
        1,
        2,
        "k",
        50,
        1,
        1,
        100,
        9999,
    ));
    try expectCapacityExhaustedMapped(error.DisklessSessionCapacity);
    const ck_bytes = fileSizeBytes(checkpoint);
    try std.testing.expect(ck_bytes > 0);
    // Runbook: each capacity tier's legal max checkpoint must reload fully.
    const reload = try reloadDisklessCheckpoint(checkpoint, 1024, 1024);
    try reportWave(.{
        .tag = "diskless-1024",
        .wave = &wave,
        .diskless_active = store.activeAdmissionCount(),
        .install_active = 0,
        .checkpoint_bytes = ck_bytes,
        .plan_dir_bytes = dirSizeBytes(plan_dir),
        .reload_ms = reload.reload_ms,
    });
    try reportWave(.{
        .tag = "diskless-1024-reload",
        .wave = &reload.wave,
        .diskless_active = 1024,
        .install_active = 0,
        .checkpoint_bytes = ck_bytes,
        .plan_dir_bytes = dirSizeBytes(plan_dir),
        .reload_ms = reload.reload_ms,
    });
}

test "v0.4 workload: external plans keep index under read ceiling with large bodies" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
    defer std.testing.allocator.free(checkpoint);

    const store = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(store);
    store.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
    defer store.deinit();
    store.setEffective(capacity.store_ceiling);

    const body = try std.testing.allocator.alloc(u8, diskless_delivery.agent_plan_cap);
    defer std.testing.allocator.free(body);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        @memset(body, @as(u8, 'A') + @as(u8, @intCast(i)));
        var node_buf: [16]u8 = undefined;
        const node = try std.fmt.bufPrint(&node_buf, "p{d}", .{i});
        const session = try store.begin(std.testing.io, node, "profile", rootfs_digest, rootfs_sha, 1, 2, "k", 50, 1, 1, 100, 1000);
        try store.pinAgentPlan(std.testing.io, &session.session_id, body);
    }

    const index_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, checkpoint, std.testing.allocator, .limited(capacity.checkpoint_index_read_max_bytes));
    defer std.testing.allocator.free(index_bytes);
    try std.testing.expect(index_bytes.len < 256 * 1024);
    const plan_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-agent-plans", .{dir});
    defer std.testing.allocator.free(plan_dir);
    const plan_dir_bytes = dirSizeBytes(plan_dir);
    std.debug.print(
        "\n[capacity-evidence] external_plans index_bytes={d} plan_body_bytes_each={d} plans={d} plan_dir_bytes={d} rss_current_kb={d} rss_peak_kb={d} fd={d} threads={d}\n",
        .{ index_bytes.len, diskless_delivery.agent_plan_cap, @as(usize, 3), plan_dir_bytes, sampleCurrentRssKb(), samplePeakRssKb(), sampleFdCount(), sampleThreadCount() },
    );

    const after = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(after);
    after.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
    defer after.deinit();
    const t0 = nowMs();
    const restored = try after.load(std.testing.io, 10, 2000);
    const t1 = nowMs();
    try std.testing.expectEqual(@as(usize, 3), restored);
    try std.testing.expectEqual(@as(usize, diskless_delivery.agent_plan_cap), after.findByNode("p0").?.agentPlanLen());
    std.debug.print(
        "[capacity-evidence] reload_ms={d} restored_sessions={d} rss_current_kb={d} rss_peak_kb={d} fd={d} threads={d} checkpoint_bytes={d} plan_dir_bytes={d}\n",
        .{ t1 - t0, restored, sampleCurrentRssKb(), samplePeakRssKb(), sampleFdCount(), sampleThreadCount(), fileSizeBytes(checkpoint), plan_dir_bytes },
    );
}

test "v0.4 workload: plan digest path safety and content hash verification" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
    defer std.testing.allocator.free(checkpoint);

    const store = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(store);
    store.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
    defer store.deinit();
    const session = try store.begin(std.testing.io, "n", "p", rootfs_digest, rootfs_sha, 1, 2, "k", 50, 1, 1, 100, 1000);
    try store.pinAgentPlan(std.testing.io, &session.session_id, "{\"schema_version\":2,\"payload\":[]}");
    const digest = session.agentPlanDigest();

    const plan_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-agent-plans/{s}", .{ dir, digest });
    defer std.testing.allocator.free(plan_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = plan_path, .data = "TAMPERED" });

    const after = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(after);
    after.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
    defer after.deinit();
    try std.testing.expectError(error.InvalidDisklessDeliveryStore, after.load(std.testing.io, 10, 2000));
}

test "v0.4 workload: first-boot 256 wave and per-node terminal reuse" {
    var wave = capacity.DeploymentWaveAdmission.init(256);
    const store = try std.testing.allocator.create(install_first_boot_store.Store);
    defer std.testing.allocator.destroy(store);
    store.* = .{};
    store.setEffective(capacity.store_ceiling);
    store.setWave(&wave);
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        var node_buf: [32]u8 = undefined;
        const node = try std.fmt.bufPrint(&node_buf, "fb-{d}", .{i});
        _ = try store.create(node, 1, 1, plan_digest, "secret");
    }
    try std.testing.expectEqual(@as(usize, 256), wave.count());
    try std.testing.expectError(error.FirstBootJournalCapacity, store.create("overflow", 1, 1, plan_digest, "secret"));
    try expectCapacityExhaustedMapped(error.FirstBootJournalCapacity);
    try reportWave(.{
        .tag = "install-256",
        .wave = &wave,
        .diskless_active = 0,
        .install_active = store.activeCount(),
        .install_terminal = countInstallTerminals(store),
    });

    i = 0;
    while (i < 256) : (i += 1) {
        var node_buf: [32]u8 = undefined;
        const node = try std.fmt.bufPrint(&node_buf, "fb-{d}", .{i});
        try store.handoff(node, 1);
        try store.started(node, 1, "s");
        try store.beginStep(node, 1, 0);
        try store.stepSucceeded(node, 1);
        try store.terminal(node, 1, true, "t");
        try ackCommit(store, node, 1);
    }
    try std.testing.expectEqual(@as(usize, 0), wave.count());

    i = 0;
    while (i < 256) : (i += 1) {
        var node_buf: [32]u8 = undefined;
        const node = try std.fmt.bufPrint(&node_buf, "fb-{d}", .{i});
        _ = try store.create(node, 2, 1, plan_digest, "secret");
    }
    const terms = countInstallTerminals(store);
    try std.testing.expectEqual(@as(usize, 256), terms);
    try reportWave(.{
        .tag = "install-256-gen2",
        .wave = &wave,
        .diskless_active = 0,
        .install_active = store.activeCount(),
        .install_terminal = terms,
    });
}

// Durable checkpoint + plan dir sizes at a mixed wave; proves resource evidence
// is available for production-scale logical waves (not only 3-plan micro case).
test "v0.4 workload: durable mixed wave reports checkpoint and plan dir bounds" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
    defer std.testing.allocator.free(checkpoint);
    const plan_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-agent-plans", .{dir});
    defer std.testing.allocator.free(plan_dir);

    var wave = capacity.DeploymentWaveAdmission.init(64);
    const diskless = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(diskless);
    diskless.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
    defer diskless.deinit();
    const first_boot = try std.testing.allocator.create(install_first_boot_store.Store);
    defer std.testing.allocator.destroy(first_boot);
    first_boot.* = .{};
    bindWave(diskless, first_boot, &wave);

    const body = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(body);
    @memset(body, 'Z');

    try fillDisklessWave(diskless, 32, "dur-d");
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        var node_buf: [32]u8 = undefined;
        const node = try std.fmt.bufPrint(&node_buf, "dur-i-{d}", .{i});
        _ = try first_boot.create(node, 1, 1, plan_digest, "secret");
    }
    // Pin a few plans so plan_dir_bytes is non-zero and index stays lean.
    const heap = try std.testing.allocator.alloc(diskless_delivery.Session, diskless_delivery.max_sessions);
    defer std.testing.allocator.free(heap);
    const sessions = diskless.snapshot(heap);
    var pinned: usize = 0;
    for (sessions) |s| {
        if (pinned >= 8) break;
        if (!s.active or s.phase.isTerminal()) continue;
        // Distinct bodies so each plan file is unique.
        body[0] = @as(u8, @intCast('A' + pinned));
        try diskless.pinAgentPlan(std.testing.io, &s.session_id, body);
        pinned += 1;
    }
    try std.testing.expectEqual(@as(usize, 64), wave.count());
    try std.testing.expectEqual(@as(usize, 32), diskless.activeAdmissionCount());
    try std.testing.expectEqual(@as(usize, 32), first_boot.activeCount());
    try std.testing.expectError(error.DisklessSessionCapacity, diskless.begin(
        std.testing.io,
        "overflow",
        "profile",
        rootfs_digest,
        rootfs_sha,
        1,
        2,
        "k",
        50,
        1,
        1,
        100,
        9999,
    ));

    const ck_bytes = fileSizeBytes(checkpoint);
    const plan_bytes = dirSizeBytes(plan_dir);
    try std.testing.expect(ck_bytes > 0);
    try std.testing.expect(plan_bytes >= 8 * 4096);
    // Index must stay far below the read ceiling even with external plan bodies.
    try std.testing.expect(ck_bytes < capacity.checkpoint_index_read_max_bytes);

    const t0 = nowMs();
    const after = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(after);
    after.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
    defer after.deinit();
    const restored = try after.load(std.testing.io, 10, 2000);
    const t1 = nowMs();
    try std.testing.expectEqual(@as(usize, 32), restored);

    try reportWave(.{
        .tag = "durable-mixed-64",
        .wave = &wave,
        .diskless_active = diskless.activeAdmissionCount(),
        .install_active = first_boot.activeCount(),
        .checkpoint_bytes = ck_bytes,
        .plan_dir_bytes = plan_bytes,
        .reload_ms = t1 - t0,
    });
}

test "v0.4 workload: terminal transition rolls back capability when persist fails" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
    defer std.testing.allocator.free(checkpoint);

    const store = try std.testing.allocator.create(diskless_delivery.Store);
    defer std.testing.allocator.destroy(store);
    store.* = diskless_delivery.Store.init(std.testing.allocator, &secret_bytes, "dep", checkpoint);
    defer store.deinit();
    const session = try store.begin(std.testing.io, "node-rb", "profile", rootfs_digest, rootfs_sha, 1, 2, "k", 50, 1, 1, 100, 1000);
    const session_id = session.session_id;
    try store.issue(std.testing.io, &session_id, .event);
    const raw_before = session.event_token_raw;
    try store.markBootConfigFetched(std.testing.io, &session_id);
    var seq: u64 = 0;
    const pre_terminal = [_]lifecycle.Phase{
        .diskless_initrd_started,
        .diskless_rootfs_downloading,
        .diskless_rootfs_verified,
        .diskless_rootfs_mounted,
        .diskless_switching_root,
        .diskless_agent_configuring,
    };
    var expected: lifecycle.Phase = .boot_config_fetched;
    for (pre_terminal) |target| {
        _ = try store.advanceEvent(std.testing.io, &session_id, expected, target, seq, 1100 + @as(i64, @intCast(seq)));
        expected = target;
        seq += 1;
    }

    const bad_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/not-a-dir/diskless-delivery.json", .{checkpoint});
    defer std.testing.allocator.free(bad_path);
    if (store.plan_dir.len != 0) {
        store.allocator.free(store.plan_dir);
        store.plan_dir = "";
    }
    store.path = bad_path;

    const result = store.advanceEvent(std.testing.io, &session_id, .diskless_agent_configuring, .diskless_running, seq, 2000);
    try std.testing.expect(std.meta.isError(result));
    const restored = store.find(&session_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(lifecycle.Phase.diskless_agent_configuring, restored.phase);
    try std.testing.expect(restored.event_token.issued);
    try std.testing.expectEqualSlices(u8, &raw_before, &restored.event_token_raw);
    try std.testing.expect(store.terminalSummaryForNode("node-rb") == null);
}
