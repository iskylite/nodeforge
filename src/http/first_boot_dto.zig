//! # v0.4 装机 first-boot 类型化计划（InstallFirstBootPlan）
//!
//! 有意**不是** AgentPlan v2，也不写入 diskless rootfs。
//! 所有权在 install generation：计划本体与 payload 闭包由 generation 目录托管，
//! 与 diskless switch_root 后的 postprocess 生命周期分离。
//!
//! 契约要点：
//! - `first_boot_plan_digest` / `delivery_digest` 自引用字段在摘要计算时归零。
//! - 有步骤时必须提供 agent 下载元数据与 event/exchange URL。
//! - payload 路径禁止穿越；step.payload_path 必须落在 payloads 闭包内。

const std = @import("std");
const model = @import("../model.zig");
const diskless = @import("diskless_dto.zig");
const asset_validate = @import("../assets/validate.zig");

/// InstallFirstBootPlan 线协议 schema 版本。
pub const schema_version: u32 = 1;
/// 单份 plan JSON 的字节上限（与 capacity.agent_plan_max_bytes 对齐）。
pub const max_plan_bytes: usize = 256 * 1024;

/// 计划附带的文件载荷元数据（相对 path + size + sha256）。
pub const Payload = struct {
    path: []const u8,
    size: u64,
    sha256: []const u8,
    mode: u16 = 0o600,
};

/// first-boot 单步：动作类型复用 diskless FirstBootAction，载荷绑定不同。
pub const Step = struct {
    id: []const u8,
    idempotency_key: []const u8,
    timeout_s: u32,
    retryable: bool,
    action: diskless.FirstBootAction,
    content: ?[]const u8 = null,
    payload_path: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    mode: u16 = 0o644,
    owner: []const u8 = "root",
    group: []const u8 = "root",
    packages: []const []const u8 = &.{},
};

/// generation 绑定的装机 first-boot 计划全文（线协议 DTO）。
pub const InstallFirstBootPlan = struct {
    schema_version: u32 = schema_version,
    deployment_id: []const u8,
    node_id: []const u8,
    install_generation: u64,
    desired_plan_digest: []const u8,
    delivery_digest: []const u8,
    bundle_revision: u64,
    first_boot_plan_digest: []const u8,
    steps: []const Step = &.{},
    payloads: []const Payload = &.{},
    package_manager: ?diskless.FirstBootPackageManager = null,
    repository_urls: []const []const u8 = &.{},
    agent_url: []const u8 = "",
    agent_size: u64 = 0,
    agent_sha256: []const u8 = "",
    event_url: []const u8,
    exchange_url: []const u8,
    expires_at: i64,
};

/// 是否声明了必须执行的 first-boot 工作（steps 非空）。
pub fn hasRequiredWork(value: InstallFirstBootPlan) bool {
    return value.steps.len != 0;
}

/// 校验并序列化为 JSON；超限返回 `InstallFirstBootPlanTooLarge`。
pub fn render(allocator: std.mem.Allocator, value: InstallFirstBootPlan) ![]u8 {
    try validate(value);
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    if (bytes.len > max_plan_bytes) {
        allocator.free(bytes);
        return error.InstallFirstBootPlanTooLarge;
    }
    return bytes;
}

/// 计算 plan 的 canonical SHA-256（64 hex）。
/// digest 字段自身会写入 plan，因此摘要时将 `delivery_digest` 与
/// `first_boot_plan_digest` 替换为固定全零，避免自引用环。
pub fn digest(allocator: std.mem.Allocator, value: InstallFirstBootPlan) ![64]u8 {
    var projection = value;
    projection.delivery_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    projection.first_boot_plan_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const bytes = try render(allocator, projection);
    defer allocator.free(bytes);
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    return std.fmt.bytesToHex(raw, .lower);
}

/// 校验 plan 不变量：绑定字段、URL、payload 闭包、步骤与动作字段一致性。
pub fn validate(value: InstallFirstBootPlan) !void {
    if (value.schema_version != schema_version or value.node_id.len == 0 or value.install_generation == 0 or value.expires_at <= 0) return error.InvalidInstallFirstBootPlan;
    try validateHex(value.deployment_id, 32);
    try validateHex(value.desired_plan_digest, 64);
    try validateHex(value.delivery_digest, 64);
    try validateHex(value.first_boot_plan_digest, 64);
    if (hasRequiredWork(value)) {
        if (value.agent_url.len == 0 or value.agent_size == 0) return error.InvalidInstallFirstBootPlan;
        try validateLocalUrl(value.agent_url);
        try validateHex(value.agent_sha256, 64);
        try validateLocalUrl(value.event_url);
        try validateLocalUrl(value.exchange_url);
    }
    for (value.payloads, 0..) |payload, index| {
        if (payload.path.len == 0 or payload.size == 0) return error.InvalidInstallFirstBootPlan;
        asset_validate.validateRelativePath(payload.path) catch return error.InvalidInstallFirstBootPlan;
        try validateHex(payload.sha256, 64);
        for (value.payloads[0..index]) |earlier| if (std.mem.eql(u8, earlier.path, payload.path) or std.mem.eql(u8, earlier.sha256, payload.sha256)) return error.InvalidInstallFirstBootPlan;
    }
    for (value.steps, 0..) |step, index| {
        if (step.id.len == 0 or step.idempotency_key.len == 0 or step.timeout_s == 0 or step.timeout_s > 86400) return error.InvalidInstallFirstBootPlan;
        for (value.steps[0..index]) |earlier| if (std.mem.eql(u8, earlier.id, step.id) or std.mem.eql(u8, earlier.idempotency_key, step.idempotency_key)) return error.InvalidInstallFirstBootPlan;
        switch (step.action) {
            .package => if (step.packages.len == 0 or value.package_manager == null or value.repository_urls.len == 0) return error.InvalidInstallFirstBootPlan,
            .managed_file => if (step.destination == null or ((step.payload_path == null) == (step.content == null))) return error.InvalidInstallFirstBootPlan,
            .archive, .script => if ((step.payload_path == null) == (step.content == null)) return error.InvalidInstallFirstBootPlan,
        }
        if (step.payload_path) |path| {
            asset_validate.validateRelativePath(path) catch return error.InvalidInstallFirstBootPlan;
            var found = false;
            for (value.payloads) |payload| if (std.mem.eql(u8, payload.path, path)) {
                found = true;
                break;
            };
            if (!found) return error.InvalidInstallFirstBootPlan;
        }
    }
}

/// 仅接受本机管理面风格 `http://host/path`，拒绝 fragment 与路径 `..`。
fn validateLocalUrl(value: []const u8) !void {
    if (!std.mem.startsWith(u8, value, "http://")) return error.InvalidInstallFirstBootPlan;
    const rest = value["http://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidInstallFirstBootPlan;
    if (slash == 0 or rest[slash..].len < 2 or std.mem.indexOf(u8, rest[slash..], "..") != null or std.mem.indexOfScalar(u8, rest, '#') != null) return error.InvalidInstallFirstBootPlan;
}

/// 小写十六进制固定长度（digest / deployment_id 等）。
fn validateHex(value: []const u8, expected_len: usize) !void {
    if (value.len != expected_len) return error.InvalidInstallFirstBootPlan;
    for (value) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidInstallFirstBootPlan;
}

test "empty install first-boot plan is valid but not required" {
    const plan: InstallFirstBootPlan = .{
        .deployment_id = "0123456789abcdef0123456789abcdef",
        .node_id = "n1",
        .install_generation = 1,
        .desired_plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .delivery_digest = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        .bundle_revision = 1,
        .first_boot_plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .event_url = "http://192.0.2.1/events",
        .exchange_url = "http://192.0.2.1/exchange",
        .expires_at = 100,
    };
    try std.testing.expect(!hasRequiredWork(plan));
    _ = try digest(std.testing.allocator, plan);
}

test "first-boot plan rejects a package step without package closure" {
    const steps = [_]Step{.{ .id = "pkg", .idempotency_key = "pkg", .timeout_s = 30, .retryable = false, .action = .package }};
    const plan: InstallFirstBootPlan = .{
        .deployment_id = "0123456789abcdef0123456789abcdef",
        .node_id = "n1",
        .install_generation = 1,
        .desired_plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .delivery_digest = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        .bundle_revision = 1,
        .first_boot_plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .steps = &steps,
        .event_url = "http://192.0.2.1/events",
        .exchange_url = "http://192.0.2.1/exchange",
        .expires_at = 100,
    };
    try std.testing.expectError(error.InvalidInstallFirstBootPlan, render(std.testing.allocator, plan));
}

test "first-boot plan rejects traversal and unbound payloads" {
    const payloads = [_]Payload{.{ .path = "../escape", .size = 1, .sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }};
    const steps = [_]Step{.{ .id = "script", .idempotency_key = "script-v1", .timeout_s = 30, .retryable = false, .action = .script, .payload_path = "../escape" }};
    const plan: InstallFirstBootPlan = .{
        .deployment_id = "0123456789abcdef0123456789abcdef",
        .node_id = "n1",
        .install_generation = 1,
        .desired_plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .delivery_digest = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        .bundle_revision = 1,
        .first_boot_plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .steps = &steps,
        .payloads = &payloads,
        .agent_url = "http://192.0.2.1/agent",
        .agent_size = 1,
        .agent_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .event_url = "http://192.0.2.1/events",
        .exchange_url = "http://192.0.2.1/exchange",
        .expires_at = 100,
    };
    try std.testing.expectError(error.InvalidInstallFirstBootPlan, render(std.testing.allocator, plan));
}

test "first-boot plan digest is stable and independent of embedded digest" {
    const plan: InstallFirstBootPlan = .{
        .deployment_id = "0123456789abcdef0123456789abcdef",
        .node_id = "n1",
        .install_generation = 7,
        .desired_plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .delivery_digest = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
        .bundle_revision = 3,
        .first_boot_plan_digest = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        .event_url = "http://192.0.2.1/events",
        .exchange_url = "http://192.0.2.1/exchange",
        .expires_at = 100,
    };
    const first = try digest(std.testing.allocator, plan);
    var changed = plan;
    changed.delivery_digest = "1111111111111111111111111111111111111111111111111111111111111111";
    changed.first_boot_plan_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const second = try digest(std.testing.allocator, changed);
    try std.testing.expectEqualSlices(u8, first[0..], second[0..]);
}
