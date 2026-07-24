//! # 规范无盘 BootSession 状态机（v0.2）
//!
//! `V0_2_IMPL_DETAILS.md` §1.1 的 canonical 状态迁移与 §10 的 fail-closed 断言。
//! reducer 是纯函数：输入当前 canonical phase 与目标 phase，按唯一有序迁移图判定，
//! 拒绝跳跃、回退与终态后推进；重复同阶段上报幂等成功。`<kind>.failed` 可从任一
//! 非终态进入，`boot.expired` 仅由服务端超时进入。后续 session store / HTTP handler
//! 必须经此 reducer 推进 phase，禁止直接写 session.phase。
//!
//! install Profile 的 BootSession 在 `boot_config_fetched` 完成交付后终止；installer
//! 进度属 node_status 部署投影，不进入此 diskless 状态机。
const std = @import("std");

/// Canonical diskless lifecycle phase。Zig 内部 snake_case，经 [`canonicalName`]
/// 映射为带 namespace 的对外字符串（`boot.*` / `diskless.*`）。
pub const Phase = enum {
    boot_dhcp_discover,
    boot_dhcp_offer,
    boot_dhcp_ack,
    boot_tftp_rrq,
    boot_tftp_complete,
    boot_config_fetched,
    diskless_initrd_started,
    diskless_rootfs_downloading,
    diskless_rootfs_verified,
    diskless_rootfs_mounted,
    diskless_switching_root,
    diskless_agent_configuring,
    diskless_running,

    failed,
    expired,

    /// 对外 canonical 名（带 namespace）。历史 `pxe_seen`/`bootfile_sent`/
    /// `diskless_config_fetched` 是 `dhcp_discover`/携带 bootfile 的 `dhcp_ack`/
    /// `boot_config_fetched` 的展示别名，不在此枚举为额外状态。
    pub fn canonicalName(self: Phase) []const u8 {
        return switch (self) {
            .boot_dhcp_discover => "boot.dhcp_discover",
            .boot_dhcp_offer => "boot.dhcp_offer",
            .boot_dhcp_ack => "boot.dhcp_ack",
            .boot_tftp_rrq => "boot.tftp_rrq",
            .boot_tftp_complete => "boot.tftp_complete",
            .boot_config_fetched => "boot.config_fetched",
            .diskless_initrd_started => "diskless.initrd_started",
            .diskless_rootfs_downloading => "diskless.rootfs_downloading",
            .diskless_rootfs_verified => "diskless.rootfs_verified",
            .diskless_rootfs_mounted => "diskless.rootfs_mounted",
            .diskless_switching_root => "diskless.switching_root",
            .diskless_agent_configuring => "diskless.agent_configuring",
            .diskless_running => "diskless.running",
            .failed => "diskless.failed",
            .expired => "boot.expired",
        };
    }

    /// 终态：成功（`diskless.running`）、失败（`diskless.failed`）与超时（`boot.expired`）。
    pub fn isTerminal(self: Phase) bool {
        return self == .diskless_running or self == .failed or self == .expired;
    }

    /// 成功终态。
    pub fn isRunning(self: Phase) bool {
        return self == .diskless_running;
    }
};

/// 状态推进失败原因（对应 §10 fail-closed 断言）。
pub const AdvanceError = error{
    AlreadyTerminal,
    InvalidExpiredSource,
    JumpRejected,
    BackwardRejected,
};

/// 唯一有序后继。返回 `null` 表示 `boot_config_fetched` 之后无 diskless 后继（install
/// 在此前终止）或已是终态。
pub fn successor(current: Phase) ?Phase {
    return switch (current) {
        .boot_dhcp_discover => .boot_dhcp_offer,
        .boot_dhcp_offer => .boot_dhcp_ack,
        .boot_dhcp_ack => .boot_tftp_rrq,
        .boot_tftp_rrq => .boot_tftp_complete,
        .boot_tftp_complete => .boot_config_fetched,
        .boot_config_fetched => .diskless_initrd_started,
        .diskless_initrd_started => .diskless_rootfs_downloading,
        .diskless_rootfs_downloading => .diskless_rootfs_verified,
        .diskless_rootfs_verified => .diskless_rootfs_mounted,
        .diskless_rootfs_mounted => .diskless_switching_root,
        .diskless_switching_root => .diskless_agent_configuring,
        .diskless_agent_configuring => .diskless_running,
        .diskless_running, .failed, .expired => null,
    };
}

/// 按 §1.1 canonical 迁移图校验 `current -> target` 是否合法，返回合法后的 phase。
///
/// - 终态后任何推进返回 `AlreadyTerminal`（成功/失败/超时均为本次 session 终态）。
/// - 重复同阶段（`target == current`）幂等成功。
/// - `failed` 可从任一非终态进入。
/// - `expired` 仅允许由非终态进入（调用方保证只由服务端超时触发）。
/// - 否则 `target` 必须是 `current` 的直接后继；越级前跳返回 `JumpRejected`，
///   回退返回 `BackwardRejected`。
pub fn advance(current: Phase, target: Phase) AdvanceError!Phase {
    if (current.isTerminal()) return error.AlreadyTerminal;
    if (target == current) return current; // 幂等重复
    if (target == .failed) return .failed; // 任一非终态可失败
    if (target == .expired) return .expired; // 仅服务端超时；调用方保证来源
    if (isBackward(current, target)) return error.BackwardRejected;
    if (successor(current)) |succ| {
        if (target == succ) return target;
        return error.JumpRejected; // 越级前跳
    }
    return error.JumpRejected;
}

/// 判定 `target` 是否相对 `current` 回退（用于诊断/拒绝）。终态或同阶段不算回退。
pub fn isBackward(current: Phase, target: Phase) bool {
    if (current.isTerminal() or target == current or target == .failed or target == .expired) return false;
    return orderIndex(target) < orderIndex(current);
}

fn orderIndex(phase: Phase) usize {
    return switch (phase) {
        .boot_dhcp_discover => 0,
        .boot_dhcp_offer => 1,
        .boot_dhcp_ack => 2,
        .boot_tftp_rrq => 3,
        .boot_tftp_complete => 4,
        .boot_config_fetched => 5,
        .diskless_initrd_started => 6,
        .diskless_rootfs_downloading => 7,
        .diskless_rootfs_verified => 8,
        .diskless_rootfs_mounted => 9,
        .diskless_switching_root => 10,
        .diskless_agent_configuring => 11,
        .diskless_running => 12,
        .failed, .expired => 13,
    };
}

test "canonical forward sequence advances one step at a time" {
    const seq = [_]Phase{
        .boot_dhcp_discover, .boot_dhcp_offer, .boot_dhcp_ack, .boot_tftp_rrq, .boot_tftp_complete,
        .boot_config_fetched, .diskless_initrd_started, .diskless_rootfs_downloading,
        .diskless_rootfs_verified, .diskless_rootfs_mounted, .diskless_switching_root,
        .diskless_agent_configuring, .diskless_running,
    };
    var current = seq[0];
    for (seq[1..]) |target| {
        current = try advance(current, target);
    }
    try std.testing.expect(current.isRunning());
    try std.testing.expect(current.isTerminal());
}

test "repeated same phase is idempotent" {
    var current = try advance(.boot_dhcp_discover, .boot_dhcp_offer);
    current = try advance(current, .boot_dhcp_offer); // 重复
    try std.testing.expectEqual(Phase.boot_dhcp_offer, current);
}

test "forward jump is rejected" {
    try std.testing.expectError(error.JumpRejected, advance(.boot_dhcp_discover, .boot_tftp_complete));
    try std.testing.expectError(error.JumpRejected, advance(.boot_config_fetched, .diskless_rootfs_verified));
}

test "backward transition is rejected" {
    try std.testing.expectError(error.BackwardRejected, advance(.boot_tftp_complete, .boot_dhcp_ack));
    try std.testing.expect(isBackward(.boot_tftp_complete, .boot_dhcp_ack));
}

test "failed is reachable from any non-terminal phase" {
    try std.testing.expectEqual(Phase.failed, try advance(.boot_dhcp_ack, .failed));
    try std.testing.expectEqual(Phase.failed, try advance(.diskless_agent_configuring, .failed));
}

test "terminal phase rejects further advance" {
    try std.testing.expectError(error.AlreadyTerminal, advance(.diskless_running, .failed));
    try std.testing.expectError(error.AlreadyTerminal, advance(.failed, .diskless_running));
    try std.testing.expectError(error.AlreadyTerminal, advance(.expired, .boot_dhcp_offer));
}

test "canonical names are namespaced and unique" {
    const names = [_]Phase{
        .boot_dhcp_discover, .boot_config_fetched, .diskless_initrd_started, .diskless_running, .failed, .expired,
    };
    for (names) |p| {
        const n = p.canonicalName();
        try std.testing.expect(std.mem.startsWith(u8, n, "boot.") or std.mem.startsWith(u8, n, "diskless."));
    }
    try std.testing.expectEqualStrings("diskless.failed", Phase.failed.canonicalName());
    try std.testing.expectEqualStrings("boot.expired", Phase.expired.canonicalName());
    try std.testing.expectEqualStrings("diskless.running", Phase.diskless_running.canonicalName());
}
