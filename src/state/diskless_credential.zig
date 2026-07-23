//! # v0.2 diskless scoped capability tokens
//!
//! `V0_2_DESIGN.md` §2.3 / `V0_2_IMPL_DETAILS.md` §1.5 的分域、有界、一次性能力 token。
//! raw token 只驻内存且不落盘；服务端只持 [`hashOf`]（HMAC-SHA256）与对应的 [`Claim`]。
//! 校验时按 claim 的 scope/node/path/expiry 判定，无效 token 不关联任何 session
//! （§10：不归责 victim），已验证 claim 越权归责该 claim 所属 session。
//!
//! 四类 scope：`config:read`（BootConfig）、`rootfs:read`（rootfs GET/HEAD/Range）、
//! `agent:read`（AgentPlan/payload）、`event:append`（initrd/agent 事件上报）。
const std = @import("std");

/// HMAC 输出十六进制长度（HMAC-SHA256 = 32 字节 = 64 hex）。
pub const hash_len: usize = 64;
pub const Hash = [hash_len]u8;

/// raw token 长度（32 字节随机 = 64 hex）。与 v0.1 capability_len 一致，便于复用 header。
pub const token_len: usize = 64;

/// 能力域。单一职责，不可跨域复用（§10：传输 token 不能用于管理 API）。
pub const Scope = enum {
    config_read,
    rootfs_read,
    agent_read,
    event_append,

    pub fn canonicalName(self: Scope) []const u8 {
        return switch (self) {
            .config_read => "config:read",
            .rootfs_read => "rootfs:read",
            .agent_read => "agent:read",
            .event_append => "event:append",
        };
    }
};

/// 一次能力的授权范围。服务端签发时绑定，校验时逐项比对。
pub const Claim = struct {
    scope: Scope,
    node_id: []const u8,
    session_id: []const u8,
    /// 绑定的 desired plan digest（64 hex）；desired 漂移后旧 token 失效。
    plan_digest: []const u8,
    /// 允许访问的内容 digest（rootfs SHA-512 或 AgentPlan digest，64 hex）。
    content_digest: []const u8 = "",
    /// 允许的 path allowlist（相对于节点交付根）。空表示该 scope 不做 path 限定。
    path_allowlist: []const []const u8 = &.{},
    /// 单调时钟过期时刻。
    expires_mono: i64,
    /// event:append 的单调 event_seq（其他 scope 忽略）。
    event_seq: u64 = 0,
};

/// 校验结果。
pub const Decision = enum {
    ok,
    invalid_token,
    expired,
    scope_mismatch,
    node_mismatch,
    path_not_allowed,
    content_mismatch,
    event_seq_mismatch,
};

/// 计算 raw token 的 HMAC-SHA256 十六进制摘要（服务端持久/内存只存此值）。
pub fn hashOf(raw_token: []const u8, secret: []const u8) Hash {
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, raw_token, secret);
    var out: Hash = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{mac}) catch unreachable;
    return out;
}

/// 校验 raw token：先比 hash，再比 claim 的 scope/node/path/content/expiry/event_seq。
///
/// `stored_hash` 是服务端为该 token 保存的 [`hashOf`]；`claim` 是签发时绑定的授权范围。
/// 请求侧参数（scope/node/path/content/event_seq/now）任一不符按其错误返回；
/// hash 不匹配返回 `invalid_token`（不归责任何 session）。
pub fn verify(
    raw_token: []const u8,
    secret: []const u8,
    stored_hash: []const u8,
    claim: *const Claim,
    request_scope: Scope,
    request_node: []const u8,
    request_path: []const u8,
    request_content: []const u8,
    request_event_seq: u64,
    now_mono: i64,
) Decision {
    if (raw_token.len != token_len) return .invalid_token;
    const computed = hashOf(raw_token, secret);
    if (!std.mem.eql(u8, &computed, stored_hash)) return .invalid_token;
    if (now_mono > claim.expires_mono) return .expired;
    if (claim.scope != request_scope) return .scope_mismatch;
    if (!std.mem.eql(u8, claim.node_id, request_node)) return .node_mismatch;
    if (claim.path_allowlist.len != 0 and !contains(claim.path_allowlist, request_path)) return .path_not_allowed;
    if (claim.content_digest.len != 0 and !std.mem.eql(u8, claim.content_digest, request_content)) return .content_mismatch;
    if (claim.scope == .event_append and claim.event_seq != request_event_seq) return .event_seq_mismatch;
    return .ok;
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

test "valid token with matching claim verifies ok" {
    const claim: Claim = .{ .scope = .rootfs_read, .node_id = "n1", .session_id = "s1", .plan_digest = "p", .content_digest = "c", .path_allowlist = &.{"rootfs.squashfs"}, .expires_mono = 100 };
    const secret = "server-secret";
    const raw = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"; // 64 hex
    const stored = hashOf(raw, secret);
    try std.testing.expectEqual(Decision.ok, verify(raw, secret, &stored, &claim, .rootfs_read, "n1", "rootfs.squashfs", "c", 0, 50));
}

test "invalid token does not match stored hash" {
    const claim: Claim = .{ .scope = .config_read, .node_id = "n1", .session_id = "s1", .plan_digest = "p", .expires_mono = 100 };
    const stored = hashOf("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "s");
    // wrong raw token -> hash mismatch -> invalid_token (no victim)
    const wrong = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectEqual(Decision.invalid_token, verify(wrong, "s", &stored, &claim, .config_read, "n1", "", "", 0, 50));
}

test "expired token is rejected" {
    const claim: Claim = .{ .scope = .config_read, .node_id = "n1", .session_id = "s1", .plan_digest = "p", .expires_mono = 100 };
    const raw = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const stored = hashOf(raw, "s");
    try std.testing.expectEqual(Decision.expired, verify(raw, "s", &stored, &claim, .config_read, "n1", "", "", 0, 200));
}

test "scope mismatch and cross-node rootfs access are rejected" {
    const claim: Claim = .{ .scope = .rootfs_read, .node_id = "n1", .session_id = "s1", .plan_digest = "p", .content_digest = "c", .path_allowlist = &.{"rootfs.squashfs"}, .expires_mono = 100 };
    const raw = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const stored = hashOf(raw, "s");
    // config token reused for rootfs scope
    try std.testing.expectEqual(Decision.scope_mismatch, verify(raw, "s", &stored, &claim, .config_read, "n1", "rootfs.squashfs", "c", 0, 50));
    // rootfs accessed for a different node
    try std.testing.expectEqual(Decision.node_mismatch, verify(raw, "s", &stored, &claim, .rootfs_read, "n2", "rootfs.squashfs", "c", 0, 50));
}

test "path not in allowlist is rejected" {
    const claim: Claim = .{ .scope = .agent_read, .node_id = "n1", .session_id = "s1", .plan_digest = "p", .content_digest = "plan", .path_allowlist = &.{ "payload/a.bin", "payload/b.bin" }, .expires_mono = 100 };
    const raw = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const stored = hashOf(raw, "s");
    try std.testing.expectEqual(Decision.ok, verify(raw, "s", &stored, &claim, .agent_read, "n1", "payload/a.bin", "plan", 0, 50));
    try std.testing.expectEqual(Decision.path_not_allowed, verify(raw, "s", &stored, &claim, .agent_read, "n1", "payload/evil.bin", "plan", 0, 50));
}

test "event append enforces monotonic event seq" {
    const claim: Claim = .{ .scope = .event_append, .node_id = "n1", .session_id = "s1", .plan_digest = "p", .expires_mono = 100, .event_seq = 7 };
    const raw = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const stored = hashOf(raw, "s");
    try std.testing.expectEqual(Decision.ok, verify(raw, "s", &stored, &claim, .event_append, "n1", "", "", 7, 50));
    try std.testing.expectEqual(Decision.event_seq_mismatch, verify(raw, "s", &stored, &claim, .event_append, "n1", "", "", 8, 50));
}
