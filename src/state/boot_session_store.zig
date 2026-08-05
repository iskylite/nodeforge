//! `boot-sessions.json` 持久化投影（v0.4 schema 5）。
//!
//! checkpoint worker 在 DHCP/session mutex 之外持久化已经接纳的 delivery
//! authority。随机 boot-session capability 永不落盘；daemon 重启后恢复会话
//! identity/TTL/immutable plan，节点必须再次通过 peer-IP bootstrap 获取新 token。
//! daemon 是唯一 writer；CLI 只读。
//!
//! 恢复策略严格 fail closed：
//! - schema 4 及更早版本含旧 token 语义，v0.4 fresh layout 直接拒载；
//! - schema 5 install session 必须与 `deployment-control.json` 做 join 校验：
//!   generation + plan digest 都必须匹配，否则视为漂移并拒绝恢复；
//! - diskless session 必须与 durable delivery authority join；
//! - 若 deployment 已记录成功，即便 checkpoint 未来得及清理 token 也不复活；
//! - install plan 的 pinned asset（kernel/initrd）若 digest 改变或消失则拒绝。

const std = @import("std");
const model = @import("../model.zig");
const boot_session = @import("boot_session.zig");
const dhcp_store = @import("dhcp_store.zig");
const deployment_control = @import("deployment_control.zig");
const diskless_delivery = @import("diskless_delivery.zig");

/// 磁盘上一条 session 记录的 JSON 投影。所有字符串借用自解析后的 JSON
/// 缓冲区，由 `parsed.deinit()` 统一释放。
pub const Record = struct {
    /// 32 字符小写十六进制 session id。
    boot_session_id: []const u8,
    /// 关联节点 ID。
    node_id: []const u8,
    /// 关联 profile 名称。
    profile: []const u8,
    /// 启动模式；install 与 diskless session 均可恢复。
    mode: model.BootKind,
    /// 客户端 MAC 地址。
    mac: [6]u8,
    /// DHCP 分配的 IPv4（大端序 u32）。
    lease_ip: u32,
    /// 序列化时的 session phase。
    phase: boot_session.Phase,
    /// session 创建时间（Unix 秒）。
    created_at: i64,
    /// 最近一次活动时间（Unix 秒）；恢复时换算回 monotonic 基准。
    last_seen_at: i64,
    /// 序列化时的 model revision；schema 4 中仅供诊断，授权以 plan_digest 为准。
    model_revision: u64 = 0,
    /// M4.9b 节点级 plan digest（64 字符小写十六进制）；`null` 视为未设置。
    plan_digest: ?[]const u8 = null,
    /// 关联的 deployment generation；install 模式下必须非 0。
    deployment_generation: u64 = 0,
    /// 可选的 install plan JSON 快照；install 模式下必须存在。
    install_plan_json: ?[]const u8 = null,
    /// install plan 的 SHA-256 摘要；恢复时用于校验 JSON 完整性。
    install_plan_digest: ?[32]u8 = null,
};

/// `boot-sessions.json` 的顶层 schema。schema 5 首次禁止持久化 raw capability。
pub const File = struct {
    schema_version: u32 = 5,
    saved_at: i64,
    sessions: []const Record,
};

/// 原子保存已接纳 delivery 的活动 session 快照，不包含 raw capability。
///
/// 调用方（checkpoint worker）通过 `store.snapshot` 在 mutex 内拷贝活动
/// session 列表；本函数将其序列化为 JSON、`atomicWrite` 替换文件、再
/// `chmod 600` 收紧权限，父目录设为 `700`。install plan 的引用计数在
/// 序列化期间临时 retain，序列化完成或异常时 release。
pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *boot_session.Store, utc_now: i64) !void {
    // v0.4: never place [max_sessions]Session on the stack. On ARM with
    // store_ceiling=2048 the temporary alone is large enough to SIGSEGV in
    // memset during frame setup (observed on r97n0).
    const snapshot = try allocator.alloc(boot_session.Session, boot_session.max_sessions);
    var count: usize = 0;
    defer {
        for (snapshot[0..count]) |session| if (session.install_plan) |plan| plan.release();
        allocator.free(snapshot);
    }
    count = store.snapshot(snapshot);
    const records = try allocator.alloc(Record, count);
    defer allocator.free(records);
    for (snapshot[0..count], 0..) |session, index| records[index] = .{
        .boot_session_id = session.idSlice(),
        .node_id = session.nodeId().?,
        .profile = session.profileName().?,
        .mode = session.mode.?,
        .mac = session.mac,
        .lease_ip = session.lease_ip,
        .phase = session.phase,
        .created_at = session.created_at,
        .last_seen_at = session.last_seen_at,
        .model_revision = session.model_revision,
        .plan_digest = if (deployment_control.digestSet(session.model_plan_digest)) &session.model_plan_digest else null,
        .deployment_generation = session.deployment_generation,
        .install_plan_json = if (session.install_plan) |plan| plan.json else null,
        .install_plan_digest = if (session.install_plan) |plan| plan.digest else null,
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(File{ .saved_at = utc_now, .sessions = records }, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    try dhcp_store.atomicWrite(io, path, output.written());
    if (std.fs.path.dirname(path)) |parent| try chmod(io, allocator, "700", parent);
    try chmod(io, allocator, "600", path);
}

test "v0.4 checkpoint save uses heap snapshot for full ceiling without stack array" {
    // Regression for r97n0 SIGSEGV: save must not place [max_sessions]Session on the stack.
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/boot-sessions.json", .{dir});
    defer std.testing.allocator.free(path);

    var store: boot_session.Store = .{};
    defer store.deinit();
    // Empty store save still exercises the heap allocation path.
    try save(std.testing.io, std.testing.allocator, path, &store, 1_700_000_000);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"schema_version\": 5") != null or std.mem.indexOf(u8, bytes, "\"schema_version\":5") != null);
}

/// 调用 `chmod` 调整文件或目录权限。非零退出码返回 `PermissionUpdateFailed`。
fn chmod(io: std.Io, allocator: std.mem.Allocator, mode: []const u8, path: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "chmod", mode, path }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.PermissionUpdateFailed,
        else => return error.PermissionUpdateFailed,
    }
}

/// 加载 schema 5 checkpoint，恢复 authority 但不恢复随机 capability。
/// install、diskless 分别与自己的 durable domain state 做 join；成功
/// 恢复后 `delivery_accepted=true` 保留原 delivery TTL，`capability_issued=false`
/// 强制客户端重新完成 peer-IP bootstrap。
///
/// 返回成功恢复的 session 数。
pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    config: *const model.AppConfig,
    catalog: *const model.Catalog,
    deployments: *deployment_control.Store,
    diskless_store: *diskless_delivery.Store,
    store: *boot_session.Store,
    utc_now: i64,
    mono_now: i64,
) !usize {
    _ = config; // 为 checkpoint schema 兼容性而保留在公共签名中
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const Header = struct { schema_version: u32 };
    const header = try std.json.parseFromSlice(Header, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer header.deinit();
    if (header.value.schema_version != 5) return error.InvalidBootSessionState;
    const parsed = try std.json.parseFromSlice(File, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value.sessions.len > boot_session.max_sessions or utc_now < parsed.value.saved_at) return error.InvalidBootSessionState;
    var restored: usize = 0;
    for (parsed.value.sessions) |record| {
        if (!boot_session.validId(record.boot_session_id) or utc_now < record.last_seen_at) continue;
        const record_digest = try parsePlanDigest(record.plan_digest);
        const elapsed = utc_now - record.last_seen_at;
        if (elapsed >= boot_session.delivery_ttl_seconds) continue;
        // Catalog 必须仍包含此节点，且其 MAC/profile 未被改动。
        const node = findNode(catalog, record.node_id) orelse continue;
        const node_mac = parseMac(node.mac) catch continue;
        if (node.profile == null or !std.mem.eql(u8, node.profile.?, record.profile) or !std.mem.eql(u8, &record.mac, &node_mac)) continue;
        _ = findProfile(catalog, record.profile) orelse continue;
        if (record.mode == .install) {
            // M4.9：boot-sessions.json 与 deployment-control.json 分别原子写。
            // 恢复破坏性 delivery 前必须校验 join，避免只清理/回滚一个文件后
            // 把旧 capability/plan 接到新 generation。
            if (record.deployment_generation == 0) return error.InvalidBootSessionState;
            const deployment = deployments.view(record.node_id) orelse return error.BootSessionDeploymentMismatch;
            if (deployment.currentGeneration() != record.deployment_generation or !deployment_control.digestEqual(deployment.requested_plan_digest, record_digest))
                return error.BootSessionDeploymentMismatch;
            // 已完成 generation 不恢复 authority，也不会复活旧 capability。
            if (deployment.deployed_generation == record.deployment_generation) continue;
        } else if (record.mode == .diskless) {
            const delivery = diskless_store.findByNode(record.node_id) orelse return error.BootSessionDisklessMismatch;
            if (delivery.phase.isTerminal() or delivery.expires_at <= utc_now or !std.mem.eql(u8, delivery.profileName(), record.profile))
                return error.BootSessionDisklessMismatch;
            if (record.install_plan_json != null or record.install_plan_digest != null or record.deployment_generation != 0)
                return error.InvalidBootSessionState;
        } else return error.InvalidBootSessionState;
        var id: [boot_session.id_len]u8 = undefined;
        @memcpy(&id, record.boot_session_id);
        // 以 wall-clock elapsed 反推 monotonic 时间戳，使 session 在运行期
        // TTL 判定与未重启时一致。
        var restored_session: boot_session.Session = .{
            .id = id,
            .mac = record.mac,
            .lease_ip = record.lease_ip,
            .mode = record.mode,
            .created_at = record.created_at,
            .last_seen_at = record.last_seen_at,
            .created_mono = mono_now - elapsed,
            .last_seen_mono = mono_now - elapsed,
            .phase = record.phase,
            .delivery_accepted = true,
            .capability_issued = false,
            .model_revision = record.model_revision,
            .model_plan_digest = record_digest,
            .deployment_generation = record.deployment_generation,
        };
        try boot_session.copyIdentity(&restored_session, record.node_id, record.profile);
        try store.restore(restored_session);
        // install immutable plan 与 authority 一起恢复，但 token 始终重新签发。
        if (record.install_plan_json) |plan_json| {
            if (record.mode != .install) return error.InvalidBootSessionState;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(plan_json, &digest, .{});
            if (record.install_plan_digest == null or !std.crypto.timing_safe.eql([32]u8, digest, record.install_plan_digest.?)) return error.InvalidBootSessionState;
            try validatePlanAssets(allocator, plan_json, catalog, record_digest);
            try store.captureInstallPlan(allocator, record.boot_session_id, plan_json, record.model_revision, null);
        } else if (record.mode == .install) return error.InvalidBootSessionState;
        restored += 1;
    }
    return restored;
}

/// 校验恢复的 install plan JSON 中 pinned 的 kernel/initrd asset 仍与
/// 当前 catalog 一致。任一 asset 的 name/path/sha256 不匹配或缺失则
/// 返回 `BootSessionAssetMismatch`；plan_digest 不匹配返回
/// `BootSessionDeploymentMismatch`。这防止一次安装会话中途 catalog
/// 被替换（如 ISO 重新导入）后继续按旧 plan 执行破坏性安装。
fn validatePlanAssets(allocator: std.mem.Allocator, bytes: []const u8, catalog: *const model.Catalog, expected_digest: deployment_control.Digest) !void {
    const Envelope = struct { plan_digest: deployment_control.Digest, kernel: model.AssetConfig, initrd: model.AssetConfig };
    const parsed = std.json.parseFromSlice(Envelope, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return error.InvalidBootSessionState;
    defer parsed.deinit();
    if (!deployment_control.digestEqual(parsed.value.plan_digest, expected_digest)) return error.BootSessionDeploymentMismatch;
    inline for (.{ parsed.value.kernel, parsed.value.initrd }) |expected| {
        var matched = false;
        for (catalog.assets) |actual| if (std.mem.eql(u8, actual.name, expected.name)) {
            if (!std.mem.eql(u8, actual.path, expected.path) or !optionalEqual(actual.sha256, expected.sha256)) return error.BootSessionAssetMismatch;
            matched = true;
            break;
        };
        if (!matched) return error.BootSessionAssetMismatch;
    }
}

/// 比较两个可选字符串：两者皆 null 视为相等，否则按内容比较。
fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// 在 catalog 中按 id 查找节点，返回只读指针；未找到返回 null。
fn findNode(catalog: *const model.Catalog, id: []const u8) ?*const model.NodeConfig {
    for (catalog.nodes) |*node| if (std.mem.eql(u8, node.id, id)) return node;
    return null;
}

/// 在 catalog 中按 name 查找 profile，返回只读指针；未找到返回 null。
fn findProfile(catalog: *const model.Catalog, name: []const u8) ?*const model.ProfileConfig {
    for (catalog.profiles) |*profile| if (std.mem.eql(u8, profile.name, name)) return profile;
    return null;
}

/// 解析冒号分隔的 MAC 地址（`02:aa:bb:cc:dd:ee`）为 6 字节数组。
/// 长度或字节格式非法时返回 `InvalidMac`。
fn parseMac(text: []const u8) ![6]u8 {
    var out: [6]u8 = undefined;
    var parts = std.mem.splitScalar(u8, text, ':');
    for (&out) |*byte| byte.* = try std.fmt.parseInt(u8, parts.next() orelse return error.InvalidMac, 16);
    if (parts.next() != null) return error.InvalidMac;
    return out;
}

/// 将 64 字符小写十六进制 plan digest 解析为 `Digest`。
/// `null` 或长度不为 64 视为文件损坏；大写字母视为损坏（强制小写规范）。
fn parsePlanDigest(value: ?[]const u8) !deployment_control.Digest {
    if (value == null or value.?.len != 64) return error.InvalidBootSessionState;
    var result: deployment_control.Digest = undefined;
    for (value.?, 0..) |byte, index| {
        if (!std.ascii.isHex(byte) or std.ascii.toLower(byte) != byte) return error.InvalidBootSessionState;
        result[index] = byte;
    }
    return result;
}

test "schema 5 restores authority but rotates the in-memory capability" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/boot-sessions.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.27.128" },
    };
    var before: boot_session.Store = .{};
    defer before.deinit();
    const acquired = try before.acquireDhcp(std.testing.io, .{ .mac = &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee }, .xid = 1, .node_id = "n1", .profile = "install", .mode = .install, .model_revision = 42, .model_plan_digest = [_]u8{'4'} ** 64 }, 100, 1000);
    before.updateDhcp(acquired.link, .dhcp_ack, 0xc0a81bc8, 101, 1001);
    try before.setDeploymentGeneration(acquired.link.id().?, 1);
    const issued = try before.issueCapability(std.testing.io, acquired.link.id().?, 102, 1002);
    const plan = "{\"plan_digest\":\"4444444444444444444444444444444444444444444444444444444444444444\",\"kernel\":{\"name\":\"kernel\",\"kind\":\"kernel\",\"path\":\"install/kernel\",\"sha256\":\"aa\"},\"initrd\":{\"name\":\"initrd\",\"kind\":\"installer_initrd\",\"path\":\"install/initrd\",\"sha256\":\"bb\"}}";
    try before.captureInstallPlan(std.testing.allocator, issued.boot_session_id[0..], plan, 42, null);
    try save(std.testing.io, std.testing.allocator, path, &before, 1002);
    const checkpoint = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(checkpoint);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint, &issued.capability) == null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint, "\"capability\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, checkpoint, "\"schema_version\": 5") != null);
    var after: boot_session.Store = .{};
    defer after.deinit();
    var deployments: deployment_control.Store = .{};
    try deployments.ensureInitial("n1", [_]u8{'4'} ** 64, 999);
    var secret = [_]u8{1} ** 32;
    var diskless_store = diskless_delivery.Store.init(std.testing.allocator, &secret, "deployment", "unused");
    const catalog: model.Catalog = .{
        .profiles = &.{.{ .name = "install", .install_source = "source" }},
        .nodes = &.{.{ .id = "n1", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "install" }},
        .assets = &.{
            .{ .name = "kernel", .kind = .kernel, .path = "install/kernel", .sha256 = "aa" },
            .{ .name = "initrd", .kind = .installer_initrd, .path = "install/initrd", .sha256 = "bb" },
        },
    };
    try std.testing.expectEqual(@as(usize, 1), try load(std.testing.io, std.testing.allocator, path, &config, &catalog, &deployments, &diskless_store, &after, 1012, 500));
    try std.testing.expectError(error.ProofMismatch, after.authenticateCapability("n1", issued.boot_session_id[0..], issued.capability[0..], 501));
    const bootstrap = try after.authenticateBootstrap("n1", 0xc0a81bc8, 501);
    try std.testing.expect(!bootstrap.capability_issued);
    const rotated = try after.issueCapability(std.testing.io, bootstrap.boot_session_id[0..], 502, 1013);
    try std.testing.expect(!std.mem.eql(u8, &issued.capability, &rotated.capability));
    try std.testing.expectEqual(@as(u64, 42), rotated.model_revision);
    before.finishDelivery(issued.boot_session_id[0..], .completed, 103, 1003);
    after.finishDelivery(issued.boot_session_id[0..], .completed, 502, 1013);
}

test "schema 4 checkpoint is rejected instead of reviving persisted tokens" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/boot-sessions-v4.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "{\"schema_version\":4,\"saved_at\":1,\"sessions\":[]}" });
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.27.128" } };
    const catalog: model.Catalog = .{};
    var deployments: deployment_control.Store = .{};
    var secret = [_]u8{1} ** 32;
    var diskless_store = diskless_delivery.Store.init(std.testing.allocator, &secret, "deployment", "unused");
    var sessions: boot_session.Store = .{};
    defer sessions.deinit();
    try std.testing.expectError(error.InvalidBootSessionState, load(
        std.testing.io,
        std.testing.allocator,
        path,
        &config,
        &catalog,
        &deployments,
        &diskless_store,
        &sessions,
        2,
        2,
    ));
}

test "schema 5 rejoins diskless delivery and rotates only its boot capability" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/diskless-boot-sessions.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.27.128" } };
    const catalog: model.Catalog = .{
        .profiles = &.{.{ .name = "diskless-profile", .install_source = "source" }},
        .nodes = &.{.{ .id = "diskless-node", .mac = "02:aa:bb:cc:dd:f0", .arch = .aarch64, .profile = "diskless-profile" }},
    };
    var secret = [_]u8{2} ** 32;
    var diskless_store = diskless_delivery.Store.init(std.testing.allocator, &secret, "deployment", "");
    defer diskless_store.deinit();
    const delivery = try diskless_store.begin(
        std.testing.io,
        "diskless-node",
        "diskless-profile",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        4096,
        16384,
        "6.8.0",
        50,
        64,
        32,
        100,
        1000,
    );
    try diskless_store.pinAgentPlan(std.testing.io, &delivery.session_id, "{\"schema_version\":2}");
    try diskless_store.issue(std.testing.io, &delivery.session_id, .event);
    const event_token = delivery.event_token_raw;

    var before: boot_session.Store = .{};
    defer before.deinit();
    const acquired = try before.acquireDhcp(std.testing.io, .{
        .mac = &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xf0 },
        .xid = 43,
        .node_id = "diskless-node",
        .profile = "diskless-profile",
        .mode = .diskless,
        .model_revision = 8,
        .model_plan_digest = [_]u8{'8'} ** 64,
    }, 100, 1000);
    before.updateDhcp(acquired.link, .dhcp_ack, 0xc0a81bca, 101, 1001);
    const issued = try before.issueCapability(std.testing.io, acquired.link.id().?, 102, 1002);
    try save(std.testing.io, std.testing.allocator, path, &before, 1002);

    var after: boot_session.Store = .{};
    defer after.deinit();
    var deployments: deployment_control.Store = .{};
    try std.testing.expectEqual(@as(usize, 1), try load(std.testing.io, std.testing.allocator, path, &config, &catalog, &deployments, &diskless_store, &after, 1012, 500));
    try std.testing.expectError(error.ProofMismatch, after.authenticateCapability("diskless-node", issued.boot_session_id[0..], issued.capability[0..], 501));
    const bootstrap = try after.authenticateBootstrap("diskless-node", 0xc0a81bca, 501);
    try std.testing.expect(!bootstrap.capability_issued);
    const rotated = try after.issueCapability(std.testing.io, bootstrap.boot_session_id[0..], 502, 1013);
    try std.testing.expect(!std.mem.eql(u8, &issued.capability, &rotated.capability));
    try std.testing.expectEqualSlices(u8, &event_token, diskless_store.rawToken(delivery, .event));
}

test "resume rejects install session whose deployment provenance was reset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/boot-sessions.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.27.128" } };
    const catalog: model.Catalog = .{
        .profiles = &.{.{ .name = "install", .install_source = "source" }},
        .nodes = &.{.{ .id = "n1", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "install" }},
        .assets = &.{
            .{ .name = "kernel", .kind = .kernel, .path = "install/kernel", .sha256 = "aa" },
            .{ .name = "initrd", .kind = .installer_initrd, .path = "install/initrd", .sha256 = "bb" },
        },
    };
    var before: boot_session.Store = .{};
    defer before.deinit();
    const acquired = try before.acquireDhcp(std.testing.io, .{ .mac = &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee }, .xid = 1, .node_id = "n1", .profile = "install", .mode = .install, .model_revision = 42, .model_plan_digest = [_]u8{'4'} ** 64 }, 100, 1000);
    before.updateDhcp(acquired.link, .dhcp_ack, 0xc0a81bc8, 101, 1001);
    try before.setDeploymentGeneration(acquired.link.id().?, 3);
    const issued = try before.issueCapability(std.testing.io, acquired.link.id().?, 102, 1002);
    const plan = "{\"plan_digest\":\"4444444444444444444444444444444444444444444444444444444444444444\",\"kernel\":{\"name\":\"kernel\",\"kind\":\"kernel\",\"path\":\"install/kernel\",\"sha256\":\"aa\"},\"initrd\":{\"name\":\"initrd\",\"kind\":\"installer_initrd\",\"path\":\"install/initrd\",\"sha256\":\"bb\"}}";
    try before.captureInstallPlan(std.testing.allocator, issued.boot_session_id[0..], plan, 42, null);
    try save(std.testing.io, std.testing.allocator, path, &before, 1002);

    var reset_deployments: deployment_control.Store = .{};
    try reset_deployments.ensureInitial("n1", [_]u8{'9'} ** 64, 1003);
    var secret = [_]u8{1} ** 32;
    var diskless_store = diskless_delivery.Store.init(std.testing.allocator, &secret, "deployment", "unused");
    var after: boot_session.Store = .{};
    defer after.deinit();
    try std.testing.expectError(error.BootSessionDeploymentMismatch, load(std.testing.io, std.testing.allocator, path, &config, &catalog, &reset_deployments, &diskless_store, &after, 1012, 500));
}

test "resume fails closed when a pinned asset digest changes or disappears" {
    const plan = "{\"plan_digest\":\"4444444444444444444444444444444444444444444444444444444444444444\",\"kernel\":{\"name\":\"kernel\",\"kind\":\"kernel\",\"path\":\"install/kernel\",\"sha256\":\"aa\"},\"initrd\":{\"name\":\"initrd\",\"kind\":\"installer_initrd\",\"path\":\"install/initrd\",\"sha256\":\"bb\"}}";
    const changed: model.Catalog = .{ .assets = &.{
        .{ .name = "kernel", .kind = .kernel, .path = "install/kernel", .sha256 = "changed" },
        .{ .name = "initrd", .kind = .installer_initrd, .path = "install/initrd", .sha256 = "bb" },
    } };
    try std.testing.expectError(error.BootSessionAssetMismatch, validatePlanAssets(std.testing.allocator, plan, &changed, [_]u8{'4'} ** 64));
    const missing: model.Catalog = .{ .assets = &.{.{ .name = "kernel", .kind = .kernel, .path = "install/kernel", .sha256 = "aa" }} };
    try std.testing.expectError(error.BootSessionAssetMismatch, validatePlanAssets(std.testing.allocator, plan, &missing, [_]u8{'4'} ** 64));
}
