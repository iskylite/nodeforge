const std = @import("std");
const model = @import("../model.zig");
const boot_session = @import("boot_session.zig");
const dhcp_store = @import("dhcp_store.zig");
const deployment_control = @import("deployment_control.zig");

pub const Record = struct {
    boot_session_id: []const u8,
    node_id: []const u8,
    profile: []const u8,
    mode: model.ProfileMode,
    mac: [6]u8,
    lease_ip: u32,
    phase: boot_session.Phase,
    created_at: i64,
    last_seen_at: i64,
    capability: [boot_session.capability_len]u8,
    model_revision: u64 = 0,
    plan_digest: ?[]const u8 = null,
    deployment_generation: u64 = 0,
    install_plan_json: ?[]const u8 = null,
    install_plan_digest: ?[32]u8 = null,
};

pub const File = struct {
    schema_version: u32 = 4,
    saved_at: i64,
    sessions: []const Record,
};

pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, store: *boot_session.Store, utc_now: i64) !void {
    var snapshot: [boot_session.max_sessions]boot_session.Session = undefined;
    const count = store.snapshot(&snapshot);
    defer for (snapshot[0..count]) |session| if (session.install_plan) |plan| plan.release();
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
        .capability = session.capability,
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

fn chmod(io: std.Io, allocator: std.mem.Allocator, mode: []const u8, path: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "chmod", mode, path }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.PermissionUpdateFailed,
        else => return error.PermissionUpdateFailed,
    }
}

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, config: *const model.AppConfig, catalog: *const model.Catalog, deployments: *deployment_control.Store, store: *boot_session.Store, utc_now: i64, mono_now: i64) !usize {
    _ = config; // retained in the public signature for checkpoint schema compatibility
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    const Header = struct { schema_version: u32 };
    const header = try std.json.parseFromSlice(Header, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer header.deinit();
    // schema 3 只有全局 u64 provenance，升级后不得恢复任何 capability。
    // 接受文件仅用于不中断 daemon 升级；下一次 checkpoint 会写 schema 4。
    if (header.value.schema_version == 3) return 0;
    if (header.value.schema_version != 4) return error.InvalidBootSessionState;
    const parsed = try std.json.parseFromSlice(File, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value.sessions.len > boot_session.max_sessions or utc_now < parsed.value.saved_at) return error.InvalidBootSessionState;
    var restored: usize = 0;
    for (parsed.value.sessions) |record| {
        if (!boot_session.validId(record.boot_session_id) or !validCapability(&record.capability) or utc_now < record.last_seen_at) continue;
        // schema 4 的完整 plan digest 才是恢复授权事实；u64 revision 仅保留
        // 为读取兼容和诊断，不能继续作为 capability 的授权门槛。
        const record_digest = try parsePlanDigest(record.plan_digest);
        const elapsed = utc_now - record.last_seen_at;
        if (elapsed >= boot_session.delivery_ttl_seconds) continue;
        const node = findNode(catalog, record.node_id) orelse continue;
        const node_mac = parseMac(node.mac) catch continue;
        if (!std.mem.eql(u8, node.profile, record.profile) or !std.mem.eql(u8, &record.mac, &node_mac)) continue;
        const profile = findProfile(catalog, record.profile) orelse continue;
        if (profile.mode != record.mode) continue;
        if (record.mode == .install) {
            // M4.9：boot-sessions.json 与 deployment-control.json 分别原子写。
            // 恢复破坏性 delivery 前必须校验 join，避免只清理/回滚一个文件后
            // 把旧 capability/plan 接到新 generation。
            if (record.deployment_generation == 0) return error.InvalidBootSessionState;
            const deployment = deployments.view(record.node_id) orelse return error.BootSessionDeploymentMismatch;
            if (deployment.currentGeneration() != record.deployment_generation or !deployment_control.digestEqual(deployment.requested_plan_digest, record_digest))
                return error.BootSessionDeploymentMismatch;
            // 若 deployment 已记录成功而 terminal checkpoint 尚未来得及删除
            // token，也不得复活 capability。
            if (deployment.deployed_generation == record.deployment_generation) continue;
        }
        var id: [boot_session.id_len]u8 = undefined;
        @memcpy(&id, record.boot_session_id);
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
            .capability_issued = true,
            .capability = record.capability,
            .model_revision = record.model_revision,
            .model_plan_digest = record_digest,
            .deployment_generation = record.deployment_generation,
        };
        try boot_session.copyIdentity(&restored_session, record.node_id, record.profile);
        try store.restore(restored_session);
        if (record.install_plan_json) |plan_json| {
            if (record.mode != .install) return error.InvalidBootSessionState;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(plan_json, &digest, .{});
            if (record.install_plan_digest == null or !std.crypto.timing_safe.eql([32]u8, digest, record.install_plan_digest.?)) return error.InvalidBootSessionState;
            try validatePlanAssets(allocator, plan_json, catalog, record_digest);
            try store.captureInstallPlan(allocator, record.boot_session_id, plan_json, record.model_revision);
        } else if (record.mode == .install) return error.InvalidBootSessionState;
        restored += 1;
    }
    return restored;
}

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

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn findNode(catalog: *const model.Catalog, id: []const u8) ?*const model.NodeConfig {
    for (catalog.nodes) |*node| if (std.mem.eql(u8, node.id, id)) return node;
    return null;
}
fn findProfile(catalog: *const model.Catalog, name: []const u8) ?*const model.ProfileConfig {
    for (catalog.profiles) |*profile| if (std.mem.eql(u8, profile.name, name)) return profile;
    return null;
}
fn parseMac(text: []const u8) ![6]u8 {
    var out: [6]u8 = undefined;
    var parts = std.mem.splitScalar(u8, text, ':');
    for (&out) |*byte| byte.* = try std.fmt.parseInt(u8, parts.next() orelse return error.InvalidMac, 16);
    if (parts.next() != null) return error.InvalidMac;
    return out;
}
fn validCapability(value: []const u8) bool {
    if (value.len != boot_session.capability_len) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn parsePlanDigest(value: ?[]const u8) !deployment_control.Digest {
    if (value == null or value.?.len != 64) return error.InvalidBootSessionState;
    var result: deployment_control.Digest = undefined;
    for (value.?, 0..) |byte, index| {
        if (!std.ascii.isHex(byte) or std.ascii.toLower(byte) != byte) return error.InvalidBootSessionState;
        result[index] = byte;
    }
    return result;
}

test "delivery checkpoint restores capability and remaining TTL" {
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
    try before.captureInstallPlan(std.testing.allocator, issued.boot_session_id[0..], plan, 42);
    try save(std.testing.io, std.testing.allocator, path, &before, 1002);
    var after: boot_session.Store = .{};
    defer after.deinit();
    var deployments: deployment_control.Store = .{};
    try deployments.ensureInitial("n1", [_]u8{'4'} ** 64, 999);
    const catalog: model.Catalog = .{
        .profiles = &.{.{ .name = "install", .mode = .install, .distro = "rocky", .version = "9.7", .arch = .aarch64 }},
        .nodes = &.{.{ .id = "n1", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "install" }},
        .assets = &.{
            .{ .name = "kernel", .kind = .kernel, .path = "install/kernel", .sha256 = "aa" },
            .{ .name = "initrd", .kind = .installer_initrd, .path = "install/initrd", .sha256 = "bb" },
        },
    };
    try std.testing.expectEqual(@as(usize, 1), try load(std.testing.io, std.testing.allocator, path, &config, &catalog, &deployments, &after, 1012, 500));
    const restored = try after.authenticateCapability("n1", issued.boot_session_id[0..], issued.capability[0..], 501);
    try std.testing.expectEqual(@as(u64, 42), restored.model_revision);
    before.finishDelivery(issued.boot_session_id[0..], .completed, 103, 1003);
    after.finishDelivery(issued.boot_session_id[0..], .completed, 502, 1013);
}

test "resume rejects install session whose deployment provenance was reset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/boot-sessions.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.27.128" } };
    const catalog: model.Catalog = .{
        .profiles = &.{.{ .name = "install", .mode = .install, .distro = "rocky", .version = "9.7", .arch = .aarch64 }},
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
    try before.captureInstallPlan(std.testing.allocator, issued.boot_session_id[0..], plan, 42);
    try save(std.testing.io, std.testing.allocator, path, &before, 1002);

    var reset_deployments: deployment_control.Store = .{};
    try reset_deployments.ensureInitial("n1", [_]u8{'9'} ** 64, 1003);
    var after: boot_session.Store = .{};
    defer after.deinit();
    try std.testing.expectError(error.BootSessionDeploymentMismatch, load(std.testing.io, std.testing.allocator, path, &config, &catalog, &reset_deployments, &after, 1012, 500));
}

test "resume accepts diskless capability without an install plan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/boot-sessions.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.27.128" } };
    const catalog: model.Catalog = .{
        .profiles = &.{.{ .name = "diskless", .mode = .diskless, .distro = "rocky", .version = "9.7", .arch = .aarch64 }},
        .nodes = &.{.{ .id = "n1", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "diskless" }},
    };
    var before: boot_session.Store = .{};
    defer before.deinit();
    const acquired = try before.acquireDhcp(std.testing.io, .{ .mac = &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee }, .xid = 1, .node_id = "n1", .profile = "diskless", .mode = .diskless, .model_revision = 7, .model_plan_digest = [_]u8{'7'} ** 64 }, 100, 1000);
    before.updateDhcp(acquired.link, .dhcp_ack, 0xc0a81bc8, 101, 1001);
    const issued = try before.issueCapability(std.testing.io, acquired.link.id().?, 102, 1002);
    try save(std.testing.io, std.testing.allocator, path, &before, 1002);

    var deployments: deployment_control.Store = .{};
    var after: boot_session.Store = .{};
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), try load(std.testing.io, std.testing.allocator, path, &config, &catalog, &deployments, &after, 1012, 500));
    _ = try after.authenticateCapability("n1", issued.boot_session_id[0..], issued.capability[0..], 501);
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
