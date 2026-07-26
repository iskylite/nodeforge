//! 节点状态的持久化投影（M3.1）。
//!
//! `node-status.json` 是 HTTP node-status 投影的唯一持久化事实源。
//! 它使用独立的 I/O 锁，与 DHCP checkpoint 锁分离，使 HTTP 状态转换
//! 永远不会与 DHCP lease 持久化争用。损坏的快照会被加载器拒绝。
//! 旧版 `runtime.json` 文件仅作为状态部分的迁移输入被接受。

const std = @import("std");
const node_status = @import("node_status.zig");
const runtime = @import("runtime.zig");
const dhcp_store = @import("dhcp_store.zig");
const boot_session = @import("boot_session.zig");
const deployment_control = @import("deployment_control.zig");

/// M4.8 紧凑磁盘记录。运行时仍使用固定缓冲区以避免锁内分配，磁盘格式只写
/// 实际字符串，避免把 2048 个空槽和每条记录的 NUL padding 序列化。
pub const DiskStatus = struct {
    node_id: []const u8,
    boot_session_id: []const u8,
    daemon_instance_id: []const u8,
    model_revision: u64 = 0,
    plan_digest: ?[]const u8 = null,
    deployment_generation: u64 = 0,
    phase: node_status.Phase,
    last_event_at: i64,
    last_error: bool = false,
    reason: []const u8 = &.{},
    session_active: bool = false,
};

/// M4.9b `node-status.json` schema 5。
pub const StatusFile = struct {
    schema_version: u32 = 5,
    revision: u64 = 0,
    saved_at: i64,
    statuses: []const DiskStatus,
};

/// schema 3 使用运行时固定数组布局；仅用于一次性读取并迁移现有快照。
const LegacyStatusFile = struct {
    schema_version: u32 = 3,
    revision: u64 = 0,
    saved_at: i64,
    statuses: []const node_status.Status,
};

/// 原子保存节点状态快照到 `node-status.json`。
/// 调用方必须已在 node_status.Store mutex 下获取一致快照（通过 `snapshot`）。
///
/// I/O 互斥说明：本模块的 `save`/`load` 不自带 I/O 锁。实际的 I/O 互斥由
/// 调用方（`app.zig` 中的 `status_io_mutex`）通过 `RouteContext` 传入 HTTP
/// server，确保 HTTP 状态保存不会与 DHCP lease 持久化争用。此前此处曾有一个
/// 模块级 `io_mutex` 声明但从未被 `save`/`load` 使用——它是误导性死代码，已移除。
pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, statuses: *const [node_status.max_statuses]node_status.Status, revision: u64, now: i64) !void {
    var compact: [node_status.max_statuses]DiskStatus = undefined;
    const used = compactStatuses(statuses, &compact);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(StatusFile{ .revision = revision, .saved_at = now, .statuses = used }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try dhcp_store.atomicWrite(io, path, output.written());
}

fn compactStatuses(statuses: *const [node_status.max_statuses]node_status.Status, compact: *[node_status.max_statuses]DiskStatus) []const DiskStatus {
    var count: usize = 0;
    for (statuses) |*status| {
        if (!status.used()) continue;
        compact[count] = .{
            .node_id = status.node(),
            .boot_session_id = &status.boot_session_id,
            .daemon_instance_id = &status.daemon_instance_id,
            .model_revision = status.model_revision,
            .plan_digest = if (deployment_control.digestSet(status.model_plan_digest)) &status.model_plan_digest else null,
            .deployment_generation = status.deployment_generation,
            .phase = status.phase,
            .last_event_at = status.last_event_at,
            .last_error = status.last_error,
            .reason = status.reasonSlice(),
            // 进程活性不属于可恢复事实；磁盘始终写 false，读取也强制 false。
            .session_active = false,
        };
        count += 1;
    }
    return compact[0..count];
}

/// 加载 `node-status.json` 并以非活动状态恢复投影。
/// daemon 重启永远不会恢复 capability 或使旧 boot session 变为活动；
/// 历史投影仅为 `node status` 查询而保留。
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *node_status.Store) !void {
    // schema 3 的 2048 槽快照约 4.1 MiB。迁移读取上限需容纳它；schema 4
    // 只写已用记录，正常文件远小于此兼容上限。
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(bytes);
    const Header = struct { schema_version: u32 };
    const header = try std.json.parseFromSlice(Header, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer header.deinit();
    switch (header.value.schema_version) {
        3 => {
            const parsed = try std.json.parseFromSlice(LegacyStatusFile, allocator, bytes, .{ .allocate = .alloc_always });
            defer parsed.deinit();
            if (parsed.value.statuses.len > node_status.max_statuses) return error.InvalidStatusState;
            var snapshot = [_]node_status.Status{.{}} ** node_status.max_statuses;
            var count: usize = 0;
            for (parsed.value.statuses) |status| {
                if (!status.used()) continue;
                if (!validRuntimeStatus(&status) or containsNode(snapshot[0..count], status.node())) return error.InvalidStatusState;
                snapshot[count] = status;
                count += 1;
            }
            store.restoreInactive(&snapshot, parsed.value.revision);
        },
        4, 5 => {
            const parsed = try std.json.parseFromSlice(StatusFile, allocator, bytes, .{ .allocate = .alloc_always });
            defer parsed.deinit();
            if (parsed.value.statuses.len > node_status.max_statuses) return error.InvalidStatusState;
            var snapshot = [_]node_status.Status{.{}} ** node_status.max_statuses;
            for (parsed.value.statuses, 0..) |disk, index| {
                if (!validDiskStatus(disk) or containsNode(snapshot[0..index], disk.node_id)) return error.InvalidStatusState;
                var status: node_status.Status = .{
                    .phase = disk.phase,
                    .model_revision = disk.model_revision,
                    .model_plan_digest = if (disk.plan_digest) |digest| try parseDigest(digest) else deployment_control.empty_digest,
                    .deployment_generation = disk.deployment_generation,
                    .last_event_at = disk.last_event_at,
                    .last_error = disk.last_error,
                    // capability/session 活性只存在于当前进程；磁盘值不可信。
                    .session_active = false,
                };
                @memcpy(status.node_id[0..disk.node_id.len], disk.node_id);
                status.node_id_len = @intCast(disk.node_id.len);
                @memcpy(&status.boot_session_id, disk.boot_session_id);
                @memcpy(&status.daemon_instance_id, disk.daemon_instance_id);
                @memcpy(status.reason[0..disk.reason.len], disk.reason);
                status.reason_len = @intCast(disk.reason.len);
                snapshot[index] = status;
            }
            store.restoreInactive(&snapshot, parsed.value.revision);
        },
        else => return error.InvalidStatusState,
    }
}

fn parseDigest(value: []const u8) !deployment_control.Digest {
    if (value.len != 64) return error.InvalidStatusState;
    var result: deployment_control.Digest = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isHex(byte) or std.ascii.toLower(byte) != byte) return error.InvalidStatusState;
        result[index] = byte;
    }
    return result;
}

fn validDiskStatus(status: DiskStatus) bool {
    return status.node_id.len > 0 and status.node_id.len <= 96 and
        boot_session.validId(status.boot_session_id) and
        boot_session.validId(status.daemon_instance_id) and status.reason.len <= 128;
}

fn validRuntimeStatus(status: *const node_status.Status) bool {
    return status.node_id_len <= status.node_id.len and status.reason_len <= status.reason.len and
        boot_session.validId(&status.boot_session_id) and boot_session.validId(&status.daemon_instance_id);
}

fn containsNode(statuses: []const node_status.Status, node_id: []const u8) bool {
    for (statuses) |status| if (std.mem.eql(u8, status.node(), node_id)) return true;
    return false;
}

/// 从旧版 `runtime.json` 文件迁移节点状态。只提取 status 部分；
/// lease 部分由 `dhcp_store.zig` 处理。
pub fn migrateLegacy(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *node_status.Store) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(dhcp_store.LegacyRuntimeFile, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if ((parsed.value.schema_version != 1 and parsed.value.schema_version != 2) or parsed.value.statuses.len > node_status.max_statuses) return error.InvalidRuntimeState;
    var snapshot = [_]node_status.Status{.{}} ** node_status.max_statuses;
    for (parsed.value.statuses, 0..) |status, i| snapshot[i] = status;
    store.restoreInactive(&snapshot, 1);
}

test "schema 4 status snapshot serializes only used compact records" {
    const id = "0123456789abcdef0123456789abcdef";
    var statuses = [_]node_status.Status{.{}} ** node_status.max_statuses;
    statuses[17].node_id_len = 2;
    @memcpy(statuses[17].node_id[0..2], "n1");
    @memcpy(&statuses[17].boot_session_id, id);
    @memcpy(&statuses[17].daemon_instance_id, id);
    statuses[17].phase = .running;
    statuses[17].model_revision = 42;
    statuses[17].deployment_generation = 5;
    statuses[17].reason_len = 2;
    @memcpy(statuses[17].reason[0..2], "ok");
    var compact: [node_status.max_statuses]DiskStatus = undefined;
    const used = compactStatuses(&statuses, &compact);
    try std.testing.expectEqual(@as(usize, 1), used.len);

    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.json.Stringify.value(StatusFile{ .saved_at = 1, .statuses = used }, .{}, &output.writer);
    try std.testing.expect(output.written().len < 1024);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"schema_version\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"node_id\":\"n1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"model_revision\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"deployment_generation\":5") != null);
}

test "schema 3 status snapshot remains loadable and is compacted in memory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/node-status.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const id = "0123456789abcdef0123456789abcdef";
    var statuses = [_]node_status.Status{.{}} ** 2;
    statuses[1].node_id_len = 2;
    @memcpy(statuses[1].node_id[0..2], "n1");
    @memcpy(&statuses[1].boot_session_id, id);
    @memcpy(&statuses[1].daemon_instance_id, id);
    statuses[1].session_active = true;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.json.Stringify.value(LegacyStatusFile{ .saved_at = 1, .revision = 7, .statuses = &statuses }, .{}, &output.writer);
    try dhcp_store.atomicWrite(std.testing.io, path, output.written());

    var store: node_status.Store = .{};
    try load(std.testing.io, std.testing.allocator, path, &store);
    const restored = store.get("n1").?;
    try std.testing.expect(!restored.session_active);
    try std.testing.expectEqual(@as(u64, 7), store.currentRevision());
}
