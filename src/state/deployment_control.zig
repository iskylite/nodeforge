//! M4.1 持久化 install-generation 控制。
//!
//! 有意将破坏性安装意图与观测到的节点状态分开跟踪。
//! 仅凭 profile 绑定永远不能授权重复 PXE 安装。

const std = @import("std");
const dhcp_store = @import("dhcp_store.zig");
const model = @import("../model.zig");
const config_store = @import("../config/store.zig");
const catalog_store = @import("../catalog/store.zig");

pub const ModelRevision = struct {
    config: u64,
    catalog: u64,
    desired_digest: [64]u8,

    pub fn desiredRevision(self: ModelRevision) u64 {
        const value = std.fmt.parseInt(u64, self.desired_digest[0..16], 16) catch unreachable;
        return if (value == 0) 1 else value;
    }
};
const capacity = @import("capacity.zig");

/// M4.8: 投影表内存天花板；生效容量由 `Store.effective` 在启动时按
/// `max(受管节点数, config)` 派生（`min(派生, max_entries)`）。
pub const max_entries = capacity.store_ceiling;

pub const RequestSource = enum { initial, operator, policy_always };

pub const Entry = struct {
    node_id: [96]u8 = [_]u8{0} ** 96,
    node_id_len: u8 = 0,
    next_generation: u64 = 1,
    armed_generation: ?u64 = null,
    consumed_generation: ?u64 = null,
    terminal_generation: ?u64 = null,
    /// 当前已武装 generation 被请求时捕获的不可变 config revision。
    /// 更改的期望计划必须显式重新武装。
    requested_revision: u64 = 0,
    /// 进入破坏性安装器阶段的 revision。
    consumed_revision: u64 = 0,
    /// 安装器完成时报告为成功安装的 revision。
    applied_revision: u64 = 0,
    /// 当前 generation 被武装的时间；CLI/API 将其显示为整个部署任务的 Start。
    requested_at: i64 = 0,
    /// 安装器报告 `install.started`、generation 被消费的时间；CLI/API 显示为 Install。
    started_at: i64 = 0,
    /// 当前 generation 首次进入 terminal 的时间；CLI/API 显示为 Finished。
    finished_at: i64 = 0,
    /// 最近一次成功部署所属 generation；与当前 armed/consumed generation 分离。
    deployed_generation: u64 = 0,
    deployed_at: i64 = 0,
    requested_by: RequestSource = .initial,

    pub fn node(self: *const Entry) []const u8 {
        return self.node_id[0..self.node_id_len];
    }
    pub fn used(self: *const Entry) bool {
        return self.node_id_len != 0;
    }
};

/// 磁盘状态有意使用变长 node ID。`Entry` 保留固定缓冲区以实现无分配运行时访问，
/// 但序列化该缓冲区会为每条记录泄漏 96 字节的 NUL 填充（此前甚至包括每个
/// 空闲槽位）。
pub const DiskEntry = struct {
    node_id: []const u8,
    node_id_len: u8 = 0,
    next_generation: u64 = 1,
    armed_generation: ?u64 = null,
    consumed_generation: ?u64 = null,
    terminal_generation: ?u64 = null,
    requested_revision: u64 = 0,
    consumed_revision: u64 = 0,
    applied_revision: u64 = 0,
    requested_at: i64 = 0,
    started_at: i64 = 0,
    finished_at: i64 = 0,
    deployed_generation: u64 = 0,
    deployed_at: i64 = 0,
    requested_by: RequestSource = .initial,
};

pub const File = struct { schema_version: u32 = 2, revision: u64 = 0, entries: []const DiskEntry = &.{} };

pub const RearmResult = struct {
    generation: u64,
    changed: bool,
    replaced: bool = false,
    previous_armed_generation: ?u64 = null,
    previous_next_generation: u64 = 1,
    previous_requested_revision: u64 = 0,
    previous_requested_at: i64 = 0,
    previous_requested_by: RequestSource = .initial,
    /// rearm 前该条目记录的 per-generation 生命周期时间戳。rearm 会为新
    /// generation 清零这些字段；持久化失败回滚时必须原样恢复，否则一次
    /// 失败的 retry 会清空历史部署时间。
    previous_started_at: i64 = 0,
    previous_finished_at: i64 = 0,
    previous_deployed_at: i64 = 0,
};

pub const ConsumeResult = struct {
    generation: u64,
    previous_consumed_generation: ?u64,
    previous_consumed_revision: u64,
};

pub const TerminalResult = struct {
    generation: u64,
    previous_terminal_generation: ?u64,
    previous_applied_revision: u64,
    previous_deployed_generation: u64,
    previous_deployed_at: i64,
};

pub const View = struct {
    next_generation: u64,
    armed_generation: ?u64,
    consumed_generation: ?u64,
    terminal_generation: ?u64,
    requested_revision: u64,
    applied_revision: u64,
    requested_at: i64,
    started_at: i64,
    finished_at: i64,
    deployed_generation: u64 = 0,
    deployed_at: i64,
    requested_by: RequestSource,

    /// 当前操作对象优先取尚待执行的 armed generation；安装开始后才转为 consumed。
    pub fn currentGeneration(self: View) ?u64 {
        return self.armed_generation orelse self.consumed_generation;
    }
};

pub const Store = struct {
    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,
    /// M4.8: 生效投影容量，启动时按受管节点数派生收敛。
    effective: usize = max_entries,
    revision: u64 = 0,
    mutex: std.atomic.Mutex = .unlocked,

    /// M4.8: 按 `max(受管节点数, config)` 派生并 clamp 到 `[1, max_entries]`。
    pub fn setEffective(self: *Store, derived: usize) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var used: usize = 0;
        for (self.entries) |entry| if (entry.used()) {
            used += 1;
        };
        self.effective = @max(used, @max(@as(usize, 1), @min(derived, max_entries)));
    }

    /// 首次观测武装 generation 1。已有条目永远不会
    /// 被 config 重载自动重新武装。
    pub fn ensureInitial(self: *Store, node_id: []const u8, revision: u64, requested_at: i64) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        const entry = try self.findOrCreateLocked(node_id);
        if (entry.armed_generation == null and entry.consumed_generation == null) {
            entry.armed_generation = entry.next_generation;
            entry.next_generation += 1;
            entry.requested_revision = revision;
            entry.requested_at = requested_at;
            entry.requested_by = .initial;
        }
    }

    pub fn isArmed(self: *Store, node_id: []const u8) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id)) return entry.armed_generation != null;
        return false;
    }

    /// 待执行 generation 必须仍指向操作员已确认的精确快照。这防止
    /// 配置重载在 `install retry` 与 PXE 之间静默改变破坏性部署计划。
    pub fn isArmedForRevision(self: *Store, node_id: []const u8, revision: u64) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id))
            return entry.armed_generation != null and entry.requested_revision == revision;
        return false;
    }

    /// `install.started` 精确消费当前已武装的 generation。
    pub fn consume(self: *Store, node_id: []const u8) !?ConsumeResult {
        return self.consumeAt(node_id, 0);
    }

    pub fn consumeAt(self: *Store, node_id: []const u8, timestamp: i64) !?ConsumeResult {
        lock(&self.mutex);
        defer self.mutex.unlock();
        const entry = try self.findOrCreateLocked(node_id);
        const generation = entry.armed_generation orelse return null;
        const result = ConsumeResult{
            .generation = generation,
            .previous_consumed_generation = entry.consumed_generation,
            .previous_consumed_revision = entry.consumed_revision,
        };
        entry.consumed_generation = generation;
        entry.consumed_revision = entry.requested_revision;
        if (entry.started_at == 0 and timestamp != 0) entry.started_at = timestamp;
        entry.finished_at = 0;
        entry.armed_generation = null;
        return result;
    }

    /// 幂等地武装下一个破坏性 generation。调用方在执行此状态变更前
    /// 已检查 profile/session 约束。
    ///
    /// started/finished 是当前 generation 生命周期时间戳，rearm 时清零。
    /// deployed_at/deployed_generation 表示最近一次成功事实，必须跨 retry 保留；
    /// 否则新 generation 尚未开始时会错误地抹掉上一次成功部署记录。
    /// consumed/terminal generation 作为历史不在此处清零，由后续 consume/
    /// markTerminal 为新 generation 覆盖。
    pub fn rearm(self: *Store, node_id: []const u8, revision: u64, requested_at: i64, requested_by: RequestSource) !RearmResult {
        lock(&self.mutex);
        defer self.mutex.unlock();
        const entry = try self.findOrCreateLocked(node_id);
        if (entry.armed_generation) |generation| {
            if (entry.requested_revision == revision) return .{ .generation = generation, .changed = false };
            const previous = RearmResult{
                .generation = entry.next_generation,
                .changed = true,
                .replaced = true,
                .previous_armed_generation = generation,
                .previous_next_generation = entry.next_generation,
                .previous_requested_revision = entry.requested_revision,
                .previous_requested_at = entry.requested_at,
                .previous_requested_by = entry.requested_by,
                .previous_started_at = entry.started_at,
                .previous_finished_at = entry.finished_at,
                .previous_deployed_at = entry.deployed_at,
            };
            entry.armed_generation = entry.next_generation;
            entry.next_generation += 1;
            entry.requested_revision = revision;
            entry.requested_at = requested_at;
            entry.requested_by = requested_by;
            entry.started_at = 0;
            entry.finished_at = 0;
            return previous;
        }
        const generation = entry.next_generation;
        const previous_next = entry.next_generation;
        const previous_started = entry.started_at;
        const previous_finished = entry.finished_at;
        const previous_deployed = entry.deployed_at;
        entry.next_generation += 1;
        entry.armed_generation = generation;
        entry.requested_revision = revision;
        entry.requested_at = requested_at;
        entry.requested_by = requested_by;
        entry.started_at = 0;
        entry.finished_at = 0;
        return .{ .generation = generation, .changed = true, .previous_next_generation = previous_next, .previous_requested_revision = entry.consumed_revision, .previous_started_at = previous_started, .previous_finished_at = previous_finished, .previous_deployed_at = previous_deployed };
    }

    pub fn rollbackConsume(self: *Store, node_id: []const u8, result: ConsumeResult) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id) and entry.consumed_generation != null and entry.consumed_generation.? == result.generation and entry.armed_generation == null) {
            entry.consumed_generation = result.previous_consumed_generation;
            entry.consumed_revision = result.previous_consumed_revision;
            entry.armed_generation = result.generation;
            return;
        };
    }

    /// 当原子状态写入失败时回滚内存中的 retry 武装操作。
    /// 该操作有意保持窄范围：已待执行的 generation 不是本次调用创建的，
    /// 绝不能被移除。
    pub fn rollbackRearm(self: *Store, node_id: []const u8, result: RearmResult) void {
        if (!result.changed) return;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id) and entry.armed_generation != null and entry.armed_generation.? == result.generation) {
            entry.armed_generation = result.previous_armed_generation;
            entry.next_generation = result.previous_next_generation;
            entry.requested_revision = result.previous_requested_revision;
            entry.requested_at = result.previous_requested_at;
            entry.requested_by = result.previous_requested_by;
            entry.started_at = result.previous_started_at;
            entry.finished_at = result.previous_finished_at;
            entry.deployed_at = result.previous_deployed_at;
            return;
        };
    }

    pub fn canAutoRearm(self: *Store, node_id: []const u8) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id))
            return entry.armed_generation == null and entry.consumed_generation != null and entry.terminal_generation == entry.consumed_generation;
        return false;
    }

    /// 完成是唯一推进已应用期望状态的节点。
    /// 失败的尝试保留其消费历史，永远不会自动重新武装。
    pub fn markTerminal(self: *Store, node_id: []const u8, applied: bool) ?TerminalResult {
        return self.markTerminalAt(node_id, applied, 0);
    }

    pub fn markTerminalAt(self: *Store, node_id: []const u8, applied: bool, timestamp: i64) ?TerminalResult {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id)) {
            if (entry.consumed_generation) |generation| {
                const result = TerminalResult{
                    .generation = generation,
                    .previous_terminal_generation = entry.terminal_generation,
                    .previous_applied_revision = entry.applied_revision,
                    .previous_deployed_generation = entry.deployed_generation,
                    .previous_deployed_at = entry.deployed_at,
                };
                entry.terminal_generation = generation;
                if (entry.finished_at == 0 and timestamp != 0) entry.finished_at = timestamp;
                if (applied) {
                    entry.applied_revision = entry.consumed_revision;
                    if (entry.deployed_generation != generation and timestamp != 0) {
                        entry.deployed_generation = generation;
                        entry.deployed_at = timestamp;
                    }
                }
                return result;
            }
            return null;
        };
        return null;
    }

    pub fn rollbackTerminal(self: *Store, node_id: []const u8, result: TerminalResult) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |*entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id) and entry.terminal_generation != null and entry.terminal_generation.? == result.generation) {
            entry.terminal_generation = result.previous_terminal_generation;
            entry.applied_revision = result.previous_applied_revision;
            entry.deployed_generation = result.previous_deployed_generation;
            entry.deployed_at = result.previous_deployed_at;
            return;
        };
    }

    pub fn isDrifted(self: *Store, node_id: []const u8, revision: u64) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id))
            return entry.applied_revision != 0 and entry.applied_revision != revision;
        return false;
    }

    pub fn view(self: *Store, node_id: []const u8) ?View {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.entries) |entry| if (entry.used() and std.mem.eql(u8, entry.node(), node_id)) return .{
            .next_generation = entry.next_generation,
            .armed_generation = entry.armed_generation,
            .consumed_generation = entry.consumed_generation,
            .terminal_generation = entry.terminal_generation,
            .requested_revision = entry.requested_revision,
            .applied_revision = entry.applied_revision,
            .requested_at = entry.requested_at,
            .started_at = entry.started_at,
            .finished_at = entry.finished_at,
            .deployed_generation = entry.deployed_generation,
            .deployed_at = entry.deployed_at,
            .requested_by = entry.requested_by,
        };
        return null;
    }

    pub fn snapshot(self: *Store, out: *[max_entries]Entry) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        out.* = self.entries;
    }
    pub fn snapshotForSave(self: *Store, out: *[max_entries]Entry) u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        out.* = self.entries;
        return self.revision + 1;
    }
    pub fn commitRevision(self: *Store, revision: u64) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (revision > self.revision) self.revision = revision;
    }
    pub fn currentRevision(self: *Store) u64 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return self.revision;
    }

    fn findOrCreateLocked(self: *Store, node_id: []const u8) !*Entry {
        if (node_id.len == 0 or node_id.len > 96) return error.InvalidNodeId;
        var free: ?*Entry = null;
        var used: usize = 0;
        for (&self.entries) |*entry| {
            if (entry.used() and std.mem.eql(u8, entry.node(), node_id)) return entry;
            if (entry.used()) used += 1 else if (free == null) free = entry;
        }
        if (used >= self.effective) return error.DeploymentControlCapacity;
        const entry = free orelse return error.DeploymentControlCapacity;
        @memcpy(entry.node_id[0..node_id.len], node_id);
        entry.node_id_len = @intCast(node_id.len);
        return entry;
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *Store) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(File, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if ((parsed.value.schema_version != 1 and parsed.value.schema_version != 2) or parsed.value.entries.len > max_entries) return error.InvalidDeploymentControl;
    lock(&store.mutex);
    defer store.mutex.unlock();
    store.entries = [_]Entry{.{}} ** max_entries;
    store.revision = parsed.value.revision;
    var count: usize = 0;
    for (parsed.value.entries) |disk_entry| {
        // Version-1 固定数组文件包含 256 条记录。空记录的字符串为 96 字节
        // NUL，因此其字符串长度并非 node ID 长度；`node_id_len` 是旧版和
        // 紧凑编码共用的权威判别字段。
        const node_len: usize = disk_entry.node_id_len;
        if (node_len == 0) continue;
        if (node_len > 96 or node_len > disk_entry.node_id.len or count == max_entries or !validNodeId(disk_entry.node_id[0..node_len])) return error.InvalidDeploymentControl;
        for (store.entries[0..count]) |existing| if (std.mem.eql(u8, existing.node(), disk_entry.node_id[0..node_len])) return error.InvalidDeploymentControl;
        if (!validGenerations(disk_entry)) return error.InvalidDeploymentControl;
        const entry = &store.entries[count];
        @memcpy(entry.node_id[0..node_len], disk_entry.node_id[0..node_len]);
        entry.node_id_len = @intCast(node_len);
        entry.next_generation = disk_entry.next_generation;
        entry.armed_generation = disk_entry.armed_generation;
        entry.consumed_generation = disk_entry.consumed_generation;
        entry.terminal_generation = disk_entry.terminal_generation;
        entry.requested_revision = disk_entry.requested_revision;
        entry.consumed_revision = disk_entry.consumed_revision;
        entry.applied_revision = disk_entry.applied_revision;
        entry.requested_at = disk_entry.requested_at;
        entry.started_at = disk_entry.started_at;
        entry.finished_at = disk_entry.finished_at;
        entry.deployed_generation = if (disk_entry.deployed_generation == 0 and disk_entry.deployed_at != 0)
            disk_entry.terminal_generation orelse 0
        else
            disk_entry.deployed_generation;
        entry.deployed_at = disk_entry.deployed_at;
        entry.requested_by = disk_entry.requested_by;
        count += 1;
    }
    store.effective = @max(store.effective, count);
}

fn validGenerations(entry: DiskEntry) bool {
    if (entry.next_generation == 0) return false;
    if (entry.armed_generation) |generation| if (generation == 0 or generation >= entry.next_generation) return false;
    if (entry.consumed_generation) |generation| if (generation == 0 or generation >= entry.next_generation) return false;
    if (entry.terminal_generation) |generation| {
        // terminal_generation 是上一个完成（或失败）的 generation；
        // consumed_generation 是当前正在进行的 generation。新安装开始时
        // consumed 会递增到新 generation，但 terminal 仍保留上一次的值，
        // 因此 terminal <= consumed 是合法的（正在进行的安装比上次完成的更新）。
        // 仅 terminal > consumed 是非法的（上次完成的比当前消费的更新，逻辑矛盾）。
        if (entry.consumed_generation == null or generation > entry.consumed_generation.?) return false;
    }
    if (entry.deployed_generation != 0 and (entry.terminal_generation == null or entry.deployed_generation > entry.terminal_generation.?)) return false;
    return true;
}

fn validNodeId(value: []const u8) bool {
    if (value.len == 0 or value.len > 96) return false;
    for (value) |byte| if (!((byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '_')) return false;
    return true;
}

/// 为已校验的配置快照计算稳定的、非密钥的 revision 值。
/// 仅以不透明 u64 存储；此辅助函数不会将密码、密钥或序列化配置
/// 写入日志/事件/状态文件。
pub fn revisionForConfig(allocator: std.mem.Allocator, config: *const model.AppConfig) !u64 {
    const json = try config_store.render(allocator, config);
    defer allocator.free(json);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    // config_store 只渲染 schema 2 启动字段；profile.kernel_args 等 Catalog
    // mutation 因而不会伪装成 config revision，滚动升级也不会切断启动配置来源。
    std.crypto.hash.sha2.Sha256.hash(json, &digest, .{});
    const value = std.mem.readInt(u64, digest[0..8], .big);
    return if (value == 0) 1 else value;
}

/// config/catalog 两条 revision 与不可变期望模型 digest 的统一投影。catalog
/// mutation 不再伪装成 config revision；部署控制使用 digest 折叠值判断 drift。
pub fn revisionForModel(allocator: std.mem.Allocator, config: *const model.AppConfig, catalog: *const model.Catalog) !ModelRevision {
    const config_json = try config_store.render(allocator, config);
    defer allocator.free(config_json);
    const catalog_json = try catalog_store.render(allocator, catalog);
    defer allocator.free(catalog_json);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(config_json);
    hash.update(catalog_json);
    var raw: [32]u8 = undefined;
    hash.final(&raw);
    var desired: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&desired, "{x}", .{raw}) catch unreachable;
    return .{ .config = try revisionForConfig(allocator, config), .catalog = if (catalog.revision == 0) 1 else catalog.revision, .desired_digest = desired };
}

test "M4.7 config revision excludes catalog-owned profiles" {
    var profiles = [_]model.ProfileConfig{.{
        .name = "rocky-install",
        .mode = .install,
        .distro = "rocky",
        .version = "9.7",
        .arch = .aarch64,
        .install_source = "rocky-source",
        .install = .{},
    }};
    var config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.50.1" },
        .profiles = &profiles,
    };
    const expected = try revisionForConfig(std.testing.allocator, &config);
    profiles[0].kernel_args = "iommu=pt";
    try std.testing.expectEqual(expected, try revisionForConfig(std.testing.allocator, &config));
    config.events.keep += 1;
    try std.testing.expect((try revisionForConfig(std.testing.allocator, &config)) != expected);
}

pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *Store) !void {
    var entries: [max_entries]Entry = undefined;
    const revision = store.snapshotForSave(&entries);
    var used: [max_entries]DiskEntry = undefined;
    var used_len: usize = 0;
    // 取指针：按值遍历 `for (entries) |entry|` 会导致序列化切片指向
    // 循环临时变量，该变量会被后续迭代覆盖，导致磁盘上的 node ID 损坏。
    for (&entries) |*entry| {
        if (!entry.used()) continue;
        used[used_len] = .{
            .node_id = entry.node(),
            .node_id_len = entry.node_id_len,
            .next_generation = entry.next_generation,
            .armed_generation = entry.armed_generation,
            .consumed_generation = entry.consumed_generation,
            .terminal_generation = entry.terminal_generation,
            .requested_revision = entry.requested_revision,
            .consumed_revision = entry.consumed_revision,
            .applied_revision = entry.applied_revision,
            .requested_at = entry.requested_at,
            .started_at = entry.started_at,
            .finished_at = entry.finished_at,
            .deployed_generation = entry.deployed_generation,
            .deployed_at = entry.deployed_at,
            .requested_by = entry.requested_by,
        };
        used_len += 1;
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(File{ .revision = revision, .entries = used[0..used_len] }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try dhcp_store.atomicWrite(io, path, output.written());
    store.commitRevision(revision);
}

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

test "generation consumes once and retry is idempotent" {
    var store: Store = .{};
    try store.ensureInitial("node-01", 1, 10);
    try std.testing.expect(store.isArmed("node-01"));
    const consumed = (try store.consume("node-01")).?;
    try std.testing.expectEqual(@as(u64, 1), consumed.generation);
    try std.testing.expect(!store.isArmed("node-01"));
    const first_retry = try store.rearm("node-01", 2, 20, .operator);
    try std.testing.expectEqual(@as(u64, 2), first_retry.generation);
    try std.testing.expect(first_retry.changed);
    const repeated_retry = try store.rearm("node-01", 2, 21, .operator);
    try std.testing.expectEqual(@as(u64, 2), repeated_retry.generation);
    try std.testing.expect(!repeated_retry.changed);
}

test "current generation prefers armed work over the previous consumed generation" {
    const pending: View = .{
        .next_generation = 6,
        .armed_generation = 5,
        .consumed_generation = 4,
        .terminal_generation = 4,
        .requested_revision = 2,
        .applied_revision = 1,
        .requested_at = 10,
        .started_at = 0,
        .finished_at = 0,
        .deployed_generation = 4,
        .deployed_at = 9,
        .requested_by = .operator,
    };
    try std.testing.expectEqual(@as(?u64, 5), pending.currentGeneration());
    var running = pending;
    running.armed_generation = null;
    running.consumed_generation = 5;
    try std.testing.expectEqual(@as(?u64, 5), running.currentGeneration());
}

test "retry replaces stale pending revision" {
    var store: Store = .{};
    try store.ensureInitial("node-01", 1, 10);
    const result = try store.rearm("node-01", 2, 20, .operator);
    try std.testing.expect(result.changed);
    try std.testing.expect(result.replaced);
    try std.testing.expectEqual(@as(u64, 2), result.generation);
    try std.testing.expect(store.isArmedForRevision("node-01", 2));
}

test "failed persistence rollback restores stale pending generation" {
    var store: Store = .{};
    try store.ensureInitial("node-01", 1, 10);
    const result = try store.rearm("node-01", 2, 20, .operator);
    store.rollbackRearm("node-01", result);
    try std.testing.expect(store.isArmedForRevision("node-01", 1));
    try std.testing.expect(!store.isArmedForRevision("node-01", 2));
}

test "always policy can rearm only after a terminal consumed generation" {
    var store: Store = .{};
    try store.ensureInitial("node-01", 1, 10);
    _ = try store.consume("node-01");
    try std.testing.expect(!store.canAutoRearm("node-01"));
    _ = store.markTerminal("node-01", false);
    try std.testing.expect(store.canAutoRearm("node-01"));
    _ = try store.rearm("node-01", 1, 20, .policy_always);
    try std.testing.expect(!store.canAutoRearm("node-01"));
}

test "deployment state rejects impossible generation ordering" {
    try std.testing.expect(!validGenerations(.{ .node_id = "node-01", .node_id_len = 7, .next_generation = 2, .armed_generation = 2 }));
    try std.testing.expect(!validGenerations(.{ .node_id = "node-01", .node_id_len = 7, .next_generation = 2, .consumed_generation = 1, .terminal_generation = 2 }));
}

test "completion records applied revision without arming another install" {
    var store: Store = .{};
    try store.ensureInitial("node-01", 11, 10);
    _ = try store.consume("node-01");
    _ = store.markTerminal("node-01", true);
    try std.testing.expect(!store.isArmed("node-01"));
    try std.testing.expect(!store.isDrifted("node-01", 11));
    try std.testing.expect(store.isDrifted("node-01", 12));
}

test "retry resets current attempt timestamps but preserves last successful deployment" {
    // rearm 清零当前尝试的 install/finished，但最近成功 deployed 必须保留，
    // 直到新 generation 真正完成后再原子替换。
    var store: Store = .{};
    try store.ensureInitial("node-01", 1, 10);
    _ = (try store.consumeAt("node-01", 100)).?;
    _ = store.markTerminalAt("node-01", true, 200);
    const first = store.view("node-01").?;
    try std.testing.expectEqual(@as(i64, 100), first.started_at);
    try std.testing.expectEqual(@as(i64, 200), first.finished_at);
    try std.testing.expectEqual(@as(u64, 1), first.deployed_generation);
    try std.testing.expectEqual(@as(i64, 200), first.deployed_at);

    _ = try store.rearm("node-01", 1, 300, .operator);
    const rearmed = store.view("node-01").?;
    try std.testing.expectEqual(@as(i64, 0), rearmed.started_at);
    try std.testing.expectEqual(@as(i64, 0), rearmed.finished_at);
    try std.testing.expectEqual(@as(u64, 1), rearmed.deployed_generation);
    try std.testing.expectEqual(@as(i64, 200), rearmed.deployed_at);
    try std.testing.expect(store.isArmed("node-01"));

    _ = (try store.consumeAt("node-01", 400)).?;
    _ = store.markTerminalAt("node-01", true, 500);
    const retried = store.view("node-01").?;
    try std.testing.expectEqual(@as(i64, 400), retried.started_at);
    try std.testing.expectEqual(@as(i64, 500), retried.finished_at);
    try std.testing.expectEqual(@as(u64, 2), retried.deployed_generation);
    try std.testing.expectEqual(@as(i64, 500), retried.deployed_at);
}

test "rearm rollback restores per-generation deployment timestamps" {
    var store: Store = .{};
    try store.ensureInitial("node-01", 1, 10);
    _ = (try store.consumeAt("node-01", 100)).?;
    _ = store.markTerminalAt("node-01", true, 200);
    const result = try store.rearm("node-01", 2, 300, .operator);
    store.rollbackRearm("node-01", result);
    const restored = store.view("node-01").?;
    try std.testing.expectEqual(@as(i64, 100), restored.started_at);
    try std.testing.expectEqual(@as(i64, 200), restored.finished_at);
    try std.testing.expectEqual(@as(i64, 200), restored.deployed_at);
}

test "compact deployment state preserves node id bytes" {
    const source = "{\"schema_version\":1,\"entries\":[{\"node_id\":\"node-01\",\"node_id_len\":7}]}";
    const parsed = try std.json.parseFromSlice(File, std.testing.allocator, source, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("node-01", parsed.value.entries[0].node_id);
    var store: Store = .{};
    // 精确测试 `load` 使用的固定缓冲区拷贝，无需实际文件。
    const disk = parsed.value.entries[0];
    @memcpy(store.entries[0].node_id[0..disk.node_id_len], disk.node_id[0..disk.node_id_len]);
    store.entries[0].node_id_len = disk.node_id_len;
    try std.testing.expectEqualStrings("node-01", store.entries[0].node());
}

test "effective deployment capacity searches restored entries outside the prefix" {
    var store: Store = .{};
    @memcpy(store.entries[1].node_id[0..7], "node-01");
    store.entries[1].node_id_len = 7;
    store.setEffective(1);
    try store.ensureInitial("node-01", 1, 1);
    try std.testing.expect(!store.entries[0].used());
    try std.testing.expectError(error.DeploymentControlCapacity, store.ensureInitial("node-02", 1, 1));
}
