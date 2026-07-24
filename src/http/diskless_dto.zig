//! # v0.2 diskless delivery DTOs
//!
//! `V0_2_DESIGN.md` §2.3 / §4.3 的 BootConfig v2 与 AgentPlan v1。两者均为独立
//! 命名空间（`schema_version` 各自计数，见 `V0_2_IMPL_DETAILS.md` §5）。
//!
//! - BootConfig v2：initrd 用 config:read token 拉取的固定 immutable 快照，引用
//!   rootfs 与 AgentPlan 的 URL/digest/size，不携带任何 token（token 经 per-session
//!   credential capsule 交付）。相同 token/相同 config digest 重复 GET 返回相同 bytes。
//! - AgentPlan v1：agent pre-init 用 agent:read token 拉取的 immutable 运行根计划，
//!   列出 content-addressed payload path/digest/size 供 agent 校验后清零 token。
const std = @import("std");
const model = @import("../model.zig");

pub const boot_config_schema_version: u32 = 2;
pub const agent_plan_schema_version: u32 = 1;

/// BootConfig v2 中引用的 rootfs 定位器。
pub const RootfsLocator = struct {
    url: []const u8,
    /// rootfs 内容 SHA-512（immutable ETag）。
    sha512: []const u8,
    size: u64,
    uncompressed_size: u64,
};

/// BootConfig v2 中引用的 AgentPlan 定位器。
pub const AgentPlanLocator = struct {
    url: []const u8,
    digest: []const u8,
    size: u64,
};

pub const OverlayBudget = struct {
    tmpfs_percent: u8,
    minimum_free_bytes: u64,
    safety_margin_bytes: u64,
    node_payload_size: u64 = 0,
};

/// BootConfig v2。initrd 下载 rootfs 并交接 agent_plan locator 的最小 DTO。
pub const BootConfig = struct {
    schema_version: u32 = boot_config_schema_version,
    node_id: []const u8,
    session_id: []const u8,
    profile: []const u8,
    kind: []const u8 = "diskless",
    kernel_release: []const u8,
    kernel_args: ?[]const u8 = null,
    /// 自身 boot-config URL（有界重放时重复 GET 相同 bytes）。
    config_url: []const u8,
    rootfs: RootfsLocator,
    overlay: OverlayBudget,
    agent_plan: AgentPlanLocator,
    event_url: []const u8,
    /// 过期时刻（Unix 秒）。
    expires_at: i64,
};

/// AgentPlan v1 中 content-addressed payload 条目。
pub const PayloadEntry = struct {
    path: []const u8,
    digest: []const u8,
    size: u64,
};

/// First-boot 步骤动作（八步契约固定顺序 managed_file -> package -> archive -> script）。
pub const FirstBootAction = enum { managed_file, @"package", archive, script };
pub const FirstBootPackageManager = enum { dnf, apt };

pub const AgentUser = struct {
    name: []const u8,
    uid: ?u32 = null,
    shell: ?[]const u8 = null,
    locked: bool = false,
    password_hash: ?[]const u8 = null,
    sudo: bool = false,
    groups: []const []const u8 = &.{},
    ssh_authorized_keys: []const []const u8 = &.{},
};

pub const AgentSsh = struct {
    enabled: bool,
    password_authentication: bool,
    root_login: model.RootLoginPolicy,
    root_password_hash: ?[]const u8 = null,
    root_authorized_keys: []const []const u8 = &.{},
};

pub const AgentSystem = struct {
    localization: model.LocalizationConfig,
    connectivity: model.ConnectivityPolicy,
    ssh: AgentSsh,
    security: model.TargetSecurityConfig,
    users: []const AgentUser,
    packages: []const []const u8 = &.{},
};

pub const SoftwareTransaction = struct {
    manager: ?FirstBootPackageManager = null,
    repository_urls: []const []const u8 = &.{},
    install: []const []const u8 = &.{},
    remove: []const []const u8 = &.{},
    services_enable: []const []const u8 = &.{},
    services_disable: []const []const u8 = &.{},
};

/// AgentPlan 唯一的运行根配置 owner。字段是服务端已经合并完成的 effective
/// snapshot；agent 只能重放，不能在节点侧重新读取 Profile/Node 或自行合并。
pub const NodeApplyProjection = struct {
    node_id: []const u8,
    mac: []const u8,
    arch: model.Arch,
    hostname: ?[]const u8,
    network: model.TargetNetworkConfig,
    system: AgentSystem,
    software: model.SoftwareSelection,
    software_transaction: SoftwareTransaction = .{},
};

/// AgentPlan v1 内联的 first-boot 步骤；切根后由 agent 一次性按固定顺序重放。
/// 步骤内容当前为内联（`content`）；content-addressed payload blob 下发为后续增强。
pub const FirstBootStep = struct {
    id: []const u8 = "",
    idempotency_key: []const u8 = "",
    timeout_s: u32 = 300,
    retryable: bool = false,
    action: FirstBootAction,
    content: ?[]const u8 = null,
    /// 相对 `/var/lib/nodeforge/payload` 的已校验 payload 路径。与 content 二选一。
    payload_path: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    mode: u16 = 0o644,
    owner: []const u8 = "root",
    group: []const u8 = "root",
    packages: []const []const u8 = &.{},
};

/// AgentPlan v1。切根后 agent pre-init 拉取并校验的 immutable 运行根计划。
pub const AgentPlan = struct {
    schema_version: u32 = agent_plan_schema_version,
    node_id: []const u8,
    session_id: []const u8,
    plan_digest: []const u8,
    rootfs_input_digest: []const u8,
    node_apply_projection: NodeApplyProjection,
    /// Node first-boot bundle（override 完整替换 Profile 继承值）。
    first_boot_bundle: ?[]const u8 = null,
    /// content-addressed payload 列表；相同 token 只能访问此处明列的 path。
    payload: []const PayloadEntry = &.{},
    /// first-boot 步骤（内联）；agent 切根后按固定顺序一次性重放（Phase 8）。
    steps: []const FirstBootStep = &.{},
    /// package action 使用的固定仓库：默认包含 InstallSource 由 nodeforged
    /// 发布的仓库，并合并 CLI 明确配置的 Yum/APT 源。
    package_manager: ?FirstBootPackageManager = null,
    repository_urls: []const []const u8 = &.{},
    first_boot_max_attempts: u8 = 1,
    first_boot_backoff_seconds: u32 = 0,
    event_url: []const u8,
    expires_at: i64,
};

/// 渲染 BootConfig v2 为 JSON。
pub fn renderBootConfig(allocator: std.mem.Allocator, config: BootConfig) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, config, .{ .whitespace = .indent_2 });
}

/// 渲染 AgentPlan v1 为 JSON。
pub fn renderAgentPlan(allocator: std.mem.Allocator, plan: AgentPlan) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, plan, .{ .whitespace = .indent_2 });
}

/// 计算 BootConfig 的 canonical SHA-256 十六进制（config digest，用于固定 immutable
/// bytes 与有界重放比对）。
pub fn bootConfigDigest(allocator: std.mem.Allocator, config: BootConfig) ![64]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, config, .{});
    defer allocator.free(json);
    return sha256Hex(json);
}

/// 计算 AgentPlan 的 canonical SHA-256 十六进制（plan digest，用于 agent 校验）。
pub fn agentPlanDigest(allocator: std.mem.Allocator, plan: AgentPlan) ![64]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, plan, .{});
    defer allocator.free(json);
    return sha256Hex(json);
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{raw}) catch unreachable;
    return out;
}

test "boot config v2 renders stable canonical digest" {
    const cfg: BootConfig = .{
        .node_id = "n1",
        .session_id = "s1",
        .profile = "p",
        .kernel_release = "5.14.0",
        .kernel_args = "console=ttyAMA0",
        .config_url = "https://srv/api/v1/nodes/n1/boot-config",
        .rootfs = .{ .url = "https://srv/api/v1/nodes/n1/rootfs", .sha512 = "ab", .size = 100, .uncompressed_size = 400 },
        .overlay = .{ .tmpfs_percent = 50, .minimum_free_bytes = 64, .safety_margin_bytes = 32 },
        .agent_plan = .{ .url = "https://srv/api/v1/nodes/n1/boot-sessions/s1/agent-plan/d", .digest = "d", .size = 50 },
        .event_url = "https://srv/api/v1/nodes/n1/events",
        .expires_at = 1234,
    };
    const first = try bootConfigDigest(std.testing.allocator, cfg);
    const second = try bootConfigDigest(std.testing.allocator, cfg);
    try std.testing.expectEqualSlices(u8, &first, &second);
    const rendered = try renderBootConfig(std.testing.allocator, cfg);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"schema_version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"sha512\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"ab\"") != null);
}

test "agent plan v1 lists payload entries" {
    const payload = [_]PayloadEntry{
        .{ .path = "payload/a.bin", .digest = "da", .size = 10 },
        .{ .path = "payload/b.bin", .digest = "db", .size = 20 },
    };
    const plan: AgentPlan = .{
        .node_id = "n1",
        .session_id = "s1",
        .plan_digest = "pd",
        .rootfs_input_digest = "rid",
        .node_apply_projection = .{
            .node_id = "n1",
            .mac = "02:00:00:00:00:01",
            .arch = .aarch64,
            .hostname = "node-1",
            .network = .{},
            .system = .{
                .localization = .{},
                .connectivity = .{},
                .ssh = .{ .enabled = true, .password_authentication = false, .root_login = .@"prohibit-password" },
                .security = .{},
                .users = &.{},
            },
            .software = .{},
        },
        .first_boot_bundle = "fb",
        .payload = &payload,
        .event_url = "https://srv/api/v1/nodes/n1/events",
        .expires_at = 99,
    };
    const rendered = try renderAgentPlan(std.testing.allocator, plan);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"schema_version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "payload/a.bin") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "payload/b.bin") != null);
    const digest = try agentPlanDigest(std.testing.allocator, plan);
    // 相同输入稳定。
    const again = try agentPlanDigest(std.testing.allocator, plan);
    try std.testing.expectEqualSlices(u8, &digest, &again);
}

test "agent plan v1 round-trips first-boot steps" {
    const steps = [_]FirstBootStep{
        .{ .id = "motd", .action = .managed_file, .content = "hello\n", .destination = "/etc/motd", .mode = 0o644 },
        .{ .id = "pkgs", .action = .@"package", .packages = &.{ "tmux", "vim" } },
        .{ .id = "arc", .action = .archive, .content = "x", .destination = "/opt/app" },
        .{ .id = "scr", .action = .script, .content = "echo hi\n" },
    };
    const plan: AgentPlan = .{
        .node_id = "n1",
        .session_id = "s1",
        .plan_digest = "pd",
        .rootfs_input_digest = "rid",
        .node_apply_projection = .{
            .node_id = "n1",
            .mac = "02:00:00:00:00:01",
            .arch = .aarch64,
            .hostname = null,
            .network = .{},
            .system = .{
                .localization = .{},
                .connectivity = .{},
                .ssh = .{ .enabled = true, .password_authentication = false, .root_login = .@"prohibit-password" },
                .security = .{},
                .users = &.{},
            },
            .software = .{},
        },
        .first_boot_bundle = "fb",
        .payload = &.{},
        .steps = &steps,
        .package_manager = .dnf,
        .repository_urls = &.{"http://10.0.2.2:8080/artifacts/repositories/base"},
        .event_url = "https://srv/api/v1/nodes/n1/events",
        .expires_at = 99,
    };
    const rendered = try renderAgentPlan(std.testing.allocator, plan);
    defer std.testing.allocator.free(rendered);
    // 枚举动作序列化为 tag 名（@"package" -> "package"）。
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"managed_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"package\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"archive\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"script\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "/etc/motd") != null);
    // 解析回来：步骤顺序与内容保持。
    const P = struct { steps: []const FirstBootStep = &.{} };
    const parsed = try std.json.parseFromSlice(P, std.testing.allocator, rendered, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 4), parsed.value.steps.len);
    try std.testing.expectEqual(FirstBootAction.managed_file, parsed.value.steps[0].action);
    try std.testing.expectEqual(FirstBootAction.@"package", parsed.value.steps[1].action);
    try std.testing.expect(std.mem.eql(u8, parsed.value.steps[1].packages[1], "vim"));
    try std.testing.expect(std.mem.eql(u8, parsed.value.steps[0].destination.?, "/etc/motd"));
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"package_manager\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"dnf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "/artifacts/repositories/base") != null);
}

test "agent system projection exposes hashes but no plaintext password fields" {
    try std.testing.expect(!@hasField(AgentUser, "password"));
    try std.testing.expect(@hasField(AgentUser, "password_hash"));
    try std.testing.expect(!@hasField(AgentSsh, "root_password"));
    try std.testing.expect(@hasField(AgentSsh, "root_password_hash"));
}
