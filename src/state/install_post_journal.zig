//! v0.3 install-post journal 状态机。
//!
//! 记录 install-post 步骤执行的运行级和步骤级状态。journal 主键为
//! `(node_id, install_generation, bundle_revision, plan_digest, step_id, attempt)`，
//! 每个节点每代安装只有一个 active run。run 状态机为：
//! `pending -> running -> committing -> completed`；失败分支进入
//! `failed|recovery_incomplete`。`committing` 表示 finalizer 成功已落 WAL，但
//! deployment 终态和 journal 完成态尚未全部发布；daemon 必须在开始服务前幂等恢复。
//!
//! - `pending`：installer 已 `started`，install-post 步骤尚未开始执行。
//! - `running`：install-post 步骤正在执行（`post` 阶段）。
//! - `completed`：所有步骤成功。
//! - `failed`：有步骤失败。
//! - `recovery_incomplete`：daemon 在 run 执行中重启，且无法从持久化状态恢复。
//!
//! step 级状态跟踪每个步骤的 `succeeded|failed` 状态和 attempt 计数。
//! 重复事件幂等：相同 step_id + 相同状态不重复计数。
//!
//! 持久化：JSON 文件，原子写入（temp + rename）。daemon 启动时加载。

const std = @import("std");
const dhcp_store = @import("dhcp_store.zig");
const deployment_control = @import("deployment_control.zig");

/// Journal schema 版本。
pub const schema_version: u32 = 1;

/// Run 状态机。
pub const RunStatus = enum {
    pending,
    running,
    committing,
    completed,
    failed,
    recovery_incomplete,

    pub fn isTerminal(self: RunStatus) bool {
        return switch (self) {
            .completed, .failed, .recovery_incomplete => true,
            else => false,
        };
    }
};

/// Step 状态。
pub const StepStatus = enum {
    running,
    succeeded,
    failed_retryable,
    failed_terminal,
};

/// 单个 step 的 journal 条目。
pub const StepEntry = struct {
    step_id: []const u8,
    status: StepStatus,
    attempts: u8 = 1,
    /// 最后一次更新的 Unix 时间戳（秒）。
    updated_at: i64 = 0,
};

/// 单个 install-post run 的完整 journal 记录。
pub const Run = struct {
    node_id: []const u8,
    install_generation: u64,
    bundle_revision: u64,
    plan_digest: []const u8 = "",
    boot_session_id: []const u8 = "",
    status: RunStatus = .pending,
    /// 步骤执行结果。按固定执行顺序记录。
    steps: []StepEntry = &.{},
    /// run 创建时间（Unix 秒）。
    created_at: i64 = 0,
    /// run 最后更新时间（Unix 秒）。
    updated_at: i64 = 0,
    /// 失败步骤的 reason 摘要（最长 2048 bytes）。
    failure_reason: ?[]const u8 = null,
};

/// 持久化文件根结构。
pub const Journal = struct {
    schema_version: u32 = schema_version,
    runs: []const Run = &.{},
};

/// Journal store。进程内持有，带互斥锁。
pub const Store = struct {
    runs: std.ArrayList(Run) = .empty,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn deinit(self: *Store, allocator: std.mem.Allocator) void {
        for (self.runs.items) |run| {
            if (run.node_id.len > 0) allocator.free(run.node_id);
            for (run.steps) |step| allocator.free(step.step_id);
            if (run.steps.len > 0) allocator.free(run.steps);
            if (run.plan_digest.len > 0) allocator.free(run.plan_digest);
            if (run.boot_session_id.len > 0) allocator.free(run.boot_session_id);
            if (run.failure_reason) |reason| allocator.free(reason);
        }
        self.runs.deinit(allocator);
    }

    /// 查找或创建一个 run。如果存在匹配的 (node_id, generation) run 则返回它，
    /// 否则创建新的 pending run。
    pub fn findOrCreate(
        self: *Store,
        allocator: std.mem.Allocator,
        node_id: []const u8,
        install_generation: u64,
        bundle_revision: u64,
        plan_digest: []const u8,
        boot_session_id: []const u8,
        timestamp: i64,
    ) !*Run {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.runs.items) |*run| {
            if (std.mem.eql(u8, run.node_id, node_id) and run.install_generation == install_generation) {
                if (run.bundle_revision != bundle_revision or !std.mem.eql(u8, run.plan_digest, plan_digest) or !std.mem.eql(u8, run.boot_session_id, boot_session_id))
                    return error.RunBindingMismatch;
                return run;
            }
        }
        const run = Run{
            .node_id = try allocator.dupe(u8, node_id),
            .install_generation = install_generation,
            .bundle_revision = bundle_revision,
            .plan_digest = try allocator.dupe(u8, plan_digest),
            .boot_session_id = try allocator.dupe(u8, boot_session_id),
            .status = .pending,
            .created_at = timestamp,
            .updated_at = timestamp,
        };
        try self.runs.append(allocator, run);
        return &self.runs.items[self.runs.items.len - 1];
    }

    /// 推进 run 状态。成功路径使用 crash-recoverable intermediate state:
    /// pending -> running -> committing -> completed。
    /// 终态后拒绝进一步迁移（幂等）。
    pub fn transition(self: *Store, node_id: []const u8, install_generation: u64, new_status: RunStatus, timestamp: i64) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.runs.items) |*run| {
            if (!std.mem.eql(u8, run.node_id, node_id) or run.install_generation != install_generation) continue;
            if (run.status.isTerminal()) return run.status == new_status;
            switch (new_status) {
                .running => if (run.status != .pending) return false,
                .committing => if (run.status != .running) return false,
                .completed => if (run.status != .committing) return false,
                .failed => if (run.status != .running and run.status != .committing) return false,
                else => return false,
            }
            run.status = new_status;
            run.updated_at = timestamp;
            return true;
        }
        return false;
    }

    pub fn rollbackCompletion(self: *Store, node_id: []const u8, install_generation: u64, timestamp: i64) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.runs.items) |*run| {
            if (!std.mem.eql(u8, run.node_id, node_id) or run.install_generation != install_generation) continue;
            if (run.status != .completed) return false;
            run.status = .committing;
            run.updated_at = timestamp;
            return true;
        }
        return false;
    }

    /// 更新或插入 step 条目。返回 true 如果状态实际变化（非幂等重复）。
    pub fn upsertStep(self: *Store, allocator: std.mem.Allocator, node_id: []const u8, install_generation: u64, step_id: []const u8, status: StepStatus, timestamp: i64) !bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.runs.items) |*run| {
            if (!std.mem.eql(u8, run.node_id, node_id) or run.install_generation != install_generation) continue;
            for (run.steps) |*step| {
                if (std.mem.eql(u8, step.step_id, step_id)) {
                    if (step.status == status) return false;
                    step.status = status;
                    step.attempts += 1;
                    step.updated_at = timestamp;
                    run.updated_at = timestamp;
                    return true;
                }
            }
            // 不存在：追加新 step 条目。
            const new_steps = try allocator.alloc(StepEntry, run.steps.len + 1);
            @memcpy(new_steps[0..run.steps.len], run.steps);
            new_steps[run.steps.len] = .{
                .step_id = try allocator.dupe(u8, step_id),
                .status = status,
                .attempts = 1,
                .updated_at = timestamp,
            };
            // 只释放旧 steps 容器，不释放 step_id（新数组仍引用它们）。
            if (run.steps.len > 0) allocator.free(run.steps);
            run.steps = new_steps;
            run.updated_at = timestamp;
            return true;
        }
        return error.RunNotFound;
    }

    /// 记录带显式 attempt 的 callback。attempt 从 1 开始；只有上一次为
    /// `failed_retryable` 时才能递增一次。succeeded/terminal 步骤不可倒退，完全相同的
    /// callback 重放则幂等返回 false。
    pub fn recordStepAttempt(self: *Store, allocator: std.mem.Allocator, node_id: []const u8, install_generation: u64, step_id: []const u8, attempt: u8, status: StepStatus, timestamp: i64) !bool {
        if (attempt == 0 or step_id.len == 0) return error.InvalidStepEvent;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.runs.items) |*run| {
            if (!std.mem.eql(u8, run.node_id, node_id) or run.install_generation != install_generation) continue;
            if (run.status.isTerminal()) return error.RunTerminal;
            for (run.steps) |*step| {
                if (!std.mem.eql(u8, step.step_id, step_id)) continue;
                if (attempt < step.attempts) return false;
                if (attempt > step.attempts + 1) return error.AttemptOutOfOrder;
                if (step.status == .succeeded or step.status == .failed_terminal) return error.StepTerminal;
                if (attempt == step.attempts) {
                    if (step.status == status) return false;
                    if (step.status != .running) return error.InvalidStepTransition;
                } else {
                    if (step.status != .failed_retryable or status != .running) return error.InvalidStepTransition;
                    step.attempts = attempt;
                }
                step.status = status;
                step.updated_at = timestamp;
                run.updated_at = timestamp;
                return true;
            }
            if (attempt != 1 or status != .running) return error.AttemptOutOfOrder;
            const new_steps = try allocator.alloc(StepEntry, run.steps.len + 1);
            @memcpy(new_steps[0..run.steps.len], run.steps);
            new_steps[run.steps.len] = .{ .step_id = try allocator.dupe(u8, step_id), .status = .running, .attempts = 1, .updated_at = timestamp };
            if (run.steps.len > 0) allocator.free(run.steps);
            run.steps = new_steps;
            run.updated_at = timestamp;
            return true;
        }
        return error.RunNotFound;
    }

    /// 设置 failure reason。
    pub fn setFailureReason(self: *Store, allocator: std.mem.Allocator, node_id: []const u8, install_generation: u64, reason: []const u8) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        const trimmed = if (reason.len > 2048) reason[0..2048] else reason;
        for (self.runs.items) |*run| {
            if (!std.mem.eql(u8, run.node_id, node_id) or run.install_generation != install_generation) continue;
            if (run.failure_reason) |old| allocator.free(old);
            run.failure_reason = allocator.dupe(u8, trimmed) catch null;
            return;
        }
    }

    /// 查看 run。
    pub fn view(self: *Store, node_id: []const u8, install_generation: u64) ?Run {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.runs.items) |run| {
            if (std.mem.eql(u8, run.node_id, node_id) and run.install_generation == install_generation) {
                return run;
            }
        }
        return null;
    }

    /// 查看 node 的最近 run（按 generation 降序）。
    pub fn latestView(self: *Store, node_id: []const u8) ?Run {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var best: ?Run = null;
        for (self.runs.items) |run| {
            if (std.mem.eql(u8, run.node_id, node_id)) {
                if (best == null or run.install_generation > best.?.install_generation) {
                    best = run;
                }
            }
        }
        return best;
    }

    /// daemon 重启恢复：将所有非终态 run 标记为 recovery_incomplete。
    pub fn markRecoveryIncomplete(self: *Store, timestamp: i64) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.runs.items) |*run| {
            if (!run.status.isTerminal()) {
                run.status = .recovery_incomplete;
                run.updated_at = timestamp;
            }
        }
    }
};

/// 恢复持久化 `committing` 标记后中断的 finalizer 事务。
///
/// 顺序固定为先提交 deployment generation 终态并持久化，再把 journal run 发布为
/// completed，避免出现 journal 已完成但 deployment 尚未成功。重复恢复不会二次推进。
pub fn recoverCommitting(io: std.Io, allocator: std.mem.Allocator, journal_path: []const u8, store: *Store, deployment_path: []const u8, deployments: *deployment_control.Store, timestamp: i64) !usize {
    var recovered: usize = 0;
    var index: usize = 0;
    while (index < store.runs.items.len) : (index += 1) {
        const run = store.runs.items[index];
        if (run.status != .committing) continue;
        const deployment = deployments.view(run.node_id) orelse return error.CompletionDeploymentMissing;
        if (deployment.consumed_generation == null or deployment.consumed_generation.? != run.install_generation) return error.CompletionGenerationMismatch;
        if (deployment.terminal_generation != run.install_generation) {
            _ = deployments.markTerminalAt(run.node_id, true, timestamp) orelse return error.CompletionGenerationMismatch;
            try deployment_control.save(io, allocator, deployment_path, deployments);
        }
        if (!store.transition(run.node_id, run.install_generation, .completed, timestamp)) return error.CompletionJournalInvalid;
        try save(io, allocator, journal_path, store);
        recovered += 1;
    }
    return recovered;
}

/// 从 JSON 文件加载 journal。
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *Store) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(Journal, allocator, bytes, .{ .allocate = .alloc_always }) catch return;
    defer parsed.deinit();
    if (parsed.value.schema_version != schema_version) return error.UnsupportedJournalSchema;
    lock(&store.mutex);
    defer store.mutex.unlock();
    for (parsed.value.runs) |run| {
        const owned_steps = try allocator.alloc(StepEntry, run.steps.len);
        for (run.steps, 0..) |step, i| {
            owned_steps[i] = .{
                .step_id = try allocator.dupe(u8, step.step_id),
                .status = step.status,
                .attempts = step.attempts,
                .updated_at = step.updated_at,
            };
        }
        try store.runs.append(allocator, .{
            .node_id = try allocator.dupe(u8, run.node_id),
            .install_generation = run.install_generation,
            .bundle_revision = run.bundle_revision,
            .plan_digest = if (run.plan_digest.len > 0) try allocator.dupe(u8, run.plan_digest) else "",
            .boot_session_id = if (run.boot_session_id.len > 0) try allocator.dupe(u8, run.boot_session_id) else "",
            .status = run.status,
            .steps = owned_steps,
            .created_at = run.created_at,
            .updated_at = run.updated_at,
            .failure_reason = if (run.failure_reason) |r| try allocator.dupe(u8, r) else null,
        });
    }
}

/// 保存 journal 到 JSON 文件。原子写入。
pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *Store) !void {
    lock(&store.mutex);
    defer store.mutex.unlock();
    var runs = try allocator.alloc(Run, store.runs.items.len);
    defer allocator.free(runs);
    for (store.runs.items, 0..) |run, i| {
        runs[i] = .{
            .node_id = run.node_id,
            .install_generation = run.install_generation,
            .bundle_revision = run.bundle_revision,
            .plan_digest = run.plan_digest,
            .boot_session_id = run.boot_session_id,
            .status = run.status,
            .steps = run.steps,
            .created_at = run.created_at,
            .updated_at = run.updated_at,
            .failure_reason = run.failure_reason,
        };
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(Journal{ .runs = runs }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try dhcp_store.atomicWrite(io, path, output.written());
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

// ── 测试 ──────────────────────────────────────────────────────────────

test "run state machine pending -> running -> completed" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    _ = try store.findOrCreate(std.testing.allocator, "node-01", 1, 1, "digest-abc", "session-1", 100);
    try std.testing.expect(store.transition("node-01", 1, .running, 200));
    try std.testing.expect(store.transition("node-01", 1, .committing, 250));
    try std.testing.expect(store.transition("node-01", 1, .completed, 300));
    // 终态后拒绝进一步迁移
    try std.testing.expect(!store.transition("node-01", 1, .running, 400));
    const v = store.view("node-01", 1).?;
    try std.testing.expectEqual(RunStatus.completed, v.status);
}

test "run state machine pending -> running -> failed" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    _ = try store.findOrCreate(std.testing.allocator, "node-02", 1, 1, "digest", "session", 100);
    try std.testing.expect(store.transition("node-02", 1, .running, 200));
    try std.testing.expect(store.transition("node-02", 1, .failed, 300));
    const v = store.view("node-02", 1).?;
    try std.testing.expectEqual(RunStatus.failed, v.status);
}

test "findOrCreate is idempotent for same node+generation" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    const run1 = try store.findOrCreate(std.testing.allocator, "node-01", 1, 1, "d", "s", 100);
    const run2 = try store.findOrCreate(std.testing.allocator, "node-01", 1, 1, "d", "s", 200);
    try std.testing.expectEqual(run1, run2);
    try std.testing.expectEqual(@as(usize, 1), store.runs.items.len);
}

test "findOrCreate rejects generation rebind" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    _ = try store.findOrCreate(std.testing.allocator, "node-01", 1, 2, "digest-a", "session-a", 100);
    try std.testing.expectError(error.RunBindingMismatch, store.findOrCreate(std.testing.allocator, "node-01", 1, 3, "digest-a", "session-a", 200));
    try std.testing.expectError(error.RunBindingMismatch, store.findOrCreate(std.testing.allocator, "node-01", 1, 2, "digest-b", "session-a", 200));
    try std.testing.expectError(error.RunBindingMismatch, store.findOrCreate(std.testing.allocator, "node-01", 1, 2, "digest-a", "session-b", 200));
}

test "upsertStep records and deduplicates step events" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    _ = try store.findOrCreate(std.testing.allocator, "node-01", 1, 1, "d", "s", 100);
    try std.testing.expect(try store.upsertStep(std.testing.allocator, "node-01", 1, "step-a", .succeeded, 200));
    // 重复 succeeded 不计数
    try std.testing.expect(!try store.upsertStep(std.testing.allocator, "node-01", 1, "step-a", .succeeded, 300));
    // 失败后重新成功
    try std.testing.expect(try store.upsertStep(std.testing.allocator, "node-01", 1, "step-a", .failed_retryable, 400));
    try std.testing.expect(try store.upsertStep(std.testing.allocator, "node-01", 1, "step-a", .succeeded, 500));
    const v = store.view("node-01", 1).?;
    try std.testing.expectEqual(@as(usize, 1), v.steps.len);
    try std.testing.expectEqual(@as(u8, 3), v.steps[0].attempts);
}

test "explicit attempts reject jumps and terminal regression" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    _ = try store.findOrCreate(std.testing.allocator, "node-01", 1, 2, "digest", "session", 1);
    try std.testing.expect(store.transition("node-01", 1, .running, 2));
    try std.testing.expect(try store.recordStepAttempt(std.testing.allocator, "node-01", 1, "step-a", 1, .running, 3));
    try std.testing.expectError(error.InvalidStepTransition, store.recordStepAttempt(std.testing.allocator, "node-01", 1, "step-a", 2, .running, 4));
    try std.testing.expect(try store.recordStepAttempt(std.testing.allocator, "node-01", 1, "step-a", 1, .failed_retryable, 5));
    try std.testing.expect(try store.recordStepAttempt(std.testing.allocator, "node-01", 1, "step-a", 2, .running, 6));
    try std.testing.expect(try store.recordStepAttempt(std.testing.allocator, "node-01", 1, "step-a", 2, .succeeded, 7));
    try std.testing.expectError(error.StepTerminal, store.recordStepAttempt(std.testing.allocator, "node-01", 1, "step-a", 2, .failed_terminal, 8));
}

test "committing completion recovers deployment then publishes completed run" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const journal_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/install-post.json", .{dir_path});
    defer std.testing.allocator.free(journal_path);
    const deployment_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/deployments.json", .{dir_path});
    defer std.testing.allocator.free(deployment_path);

    const deployments = try std.testing.allocator.create(deployment_control.Store);
    defer std.testing.allocator.destroy(deployments);
    deployments.* = .{};
    deployments.setEffective(1);
    const digest: deployment_control.Digest = [_]u8{'a'} ** 64;
    try deployments.ensureInitial("node-01", digest, 1);
    _ = try deployments.consumeAt("node-01", 2);
    try deployment_control.save(std.testing.io, std.testing.allocator, deployment_path, deployments);

    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    _ = try store.findOrCreate(std.testing.allocator, "node-01", 1, 1, &digest, "session", 1);
    try std.testing.expect(store.transition("node-01", 1, .running, 2));
    try std.testing.expect(store.transition("node-01", 1, .committing, 3));
    try save(std.testing.io, std.testing.allocator, journal_path, &store);

    try std.testing.expectEqual(@as(usize, 1), try recoverCommitting(std.testing.io, std.testing.allocator, journal_path, &store, deployment_path, deployments, 4));
    try std.testing.expectEqual(RunStatus.completed, store.view("node-01", 1).?.status);
    const deployment = deployments.view("node-01").?;
    try std.testing.expectEqual(@as(?u64, 1), deployment.terminal_generation);
    try std.testing.expectEqual(@as(u64, 1), deployment.deployed_generation);
    try std.testing.expectEqual(@as(usize, 0), try recoverCommitting(std.testing.io, std.testing.allocator, journal_path, &store, deployment_path, deployments, 5));
}

test "markRecoveryIncomplete converts non-terminal runs on restart" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    _ = try store.findOrCreate(std.testing.allocator, "node-01", 1, 1, "d", "s", 100);
    _ = store.transition("node-01", 1, .running, 200);
    _ = try store.findOrCreate(std.testing.allocator, "node-02", 1, 1, "d", "s", 100);
    _ = store.transition("node-02", 1, .running, 200);
    _ = store.transition("node-02", 1, .committing, 250);
    _ = store.transition("node-02", 1, .completed, 300);
    store.markRecoveryIncomplete(999);
    try std.testing.expectEqual(RunStatus.recovery_incomplete, store.view("node-01", 1).?.status);
    // 已终态的不变
    try std.testing.expectEqual(RunStatus.completed, store.view("node-02", 1).?.status);
}

test "latestView returns highest generation" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    _ = try store.findOrCreate(std.testing.allocator, "node-01", 1, 1, "d", "s", 100);
    _ = try store.findOrCreate(std.testing.allocator, "node-01", 2, 1, "d2", "s2", 200);
    const v = store.latestView("node-01").?;
    try std.testing.expectEqual(@as(u64, 2), v.install_generation);
}

test "setFailureReason truncates to 2048 bytes" {
    var store: Store = .{};
    defer store.deinit(std.testing.allocator);
    _ = try store.findOrCreate(std.testing.allocator, "node-01", 1, 1, "d", "s", 100);
    const long_reason = "x" ** 4096;
    store.setFailureReason(std.testing.allocator, "node-01", 1, long_reason);
    const v = store.view("node-01", 1).?;
    try std.testing.expect(v.failure_reason != null);
    try std.testing.expectEqual(@as(usize, 2048), v.failure_reason.?.len);
}
