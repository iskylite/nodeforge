//! # v0.4 diskless lifecycle capability
//!
//! Diskless 读取统一使用随机、内存中的 boot-session capability。这里只保留跨
//! 有界网络切换继续存活的确定性 `event:append` token；旧的 config/rootfs/agent
//! scope 已从 v0.4 runtime 与 checkpoint schema 删除。
const std = @import("std");

/// HMAC 输出十六进制长度（HMAC-SHA256 = 32 字节 = 64 hex）。
pub const hash_len: usize = 64;
pub const Hash = [hash_len]u8;

/// raw token 长度（32 字节随机 = 64 hex）。与 v0.1 capability_len 一致，便于复用 header。
pub const token_len: usize = 64;

pub const Scope = enum {
    event_append,

    pub fn canonicalName(self: Scope) []const u8 {
        return switch (self) {
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
    /// Durable event credential 在 daemon restart 后无法安全重构。
    /// 该 delivery 的跨网络生命周期写入 authority 不可用，需重新启动 delivery。
    recovery_incomplete,
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
///
/// 安全说明：hash 比较使用 `timing_safe.eql` 而非 `mem.eql`，避免短路比较
/// 引入的时序侧信道。虽然 HMAC 输出是伪随机的（攻击者难以控制前缀来利用
/// 时序差异），但安全令牌验证路径应始终遵循常量时间比较的最佳实践。
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
    // 使用常量时间比较 hash，防止时序侧信道攻击。
    if (!std.crypto.timing_safe.eql([hash_len]u8, computed, stored_hash[0..hash_len].*)) return .invalid_token;
    // TTL 判定必须 fail-closed。`boot_session.monotonicNow()` 在
    // `clock_gettime(CLOCK_MONOTONIC)` 失败时返回 0（见该函数注释），而
    // `0 > expires_mono` 恒为 false，会让**所有已过期 token 重新生效**。
    // 单调时钟不可读属于灾难性系统状态，此时唯一安全的语义是拒绝，
    // 而不是把无法判定当作「未过期」。
    if (now_mono <= 0 or now_mono > claim.expires_mono) return .expired;
    if (claim.scope != request_scope) return .scope_mismatch;
    if (!std.mem.eql(u8, claim.node_id, request_node)) return .node_mismatch;
    if (claim.path_allowlist.len != 0 and !contains(claim.path_allowlist, request_path)) return .path_not_allowed;
    if (claim.content_digest.len != 0 and !std.mem.eql(u8, claim.content_digest, request_content)) return .content_mismatch;
    if (claim.event_seq != request_event_seq) return .event_seq_mismatch;
    return .ok;
}

pub fn deriveToken(
    out: *[token_len]u8,
    master_secret: []const u8,
    deployment_id: []const u8,
    audience: []const u8,
    resource_id: []const u8,
    generation: u64,
    counter: u64,
) void {
    var input: [1024]u8 = undefined;
    const input_len = std.fmt.bufPrint(&input, "{s}\x00{s}\x00{s}\x00{s}\x00{d}\x00{d}", .{
        deployment_id,
        audience,
        resource_id,
        "nodeforge-capability-v1",
        generation,
        counter,
    }) catch unreachable;
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, input_len, master_secret);
    _ = std.fmt.bufPrint(out, "{x}", .{mac}) catch unreachable;
}

fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

test "invalid token does not match stored hash" {
    const claim: Claim = .{ .scope = .event_append, .node_id = "n1", .session_id = "s1", .plan_digest = "p", .expires_mono = 100 };
    const stored = hashOf("a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "s");
    // 错误的 raw token -> hash 不匹配 -> invalid_token（无受害方）
    const wrong = "0000000000000000000000000000000000000000000000000000000000000000";
    try std.testing.expectEqual(Decision.invalid_token, verify(wrong, "s", &stored, &claim, .event_append, "n1", "", "", 0, 50));
}

test "expired token is rejected" {
    const claim: Claim = .{ .scope = .event_append, .node_id = "n1", .session_id = "s1", .plan_digest = "p", .expires_mono = 100 };
    const raw = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const stored = hashOf(raw, "s");
    try std.testing.expectEqual(Decision.expired, verify(raw, "s", &stored, &claim, .event_append, "n1", "", "", 0, 200));
}

// 回归：单调时钟不可读时 TTL 判定必须 fail-closed。
//
// `boot_session.monotonicNow()` 在 clock_gettime 失败时返回 0。若 TTL 判定
// 仅为 `now_mono > expires_mono`，则 `0 > 100` 为 false，**所有已过期
// token 全部复活**。这里固定该语义：now_mono <= 0 一律视为过期。
test "unreadable monotonic clock fails closed instead of reviving tokens" {
    const claim: Claim = .{ .scope = .event_append, .node_id = "n1", .session_id = "s1", .plan_digest = "p", .expires_mono = 100 };
    const raw = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const stored = hashOf(raw, "s");
    // monotonicNow() 的失败返回值。
    try std.testing.expectEqual(Decision.expired, verify(raw, "s", &stored, &claim, .event_append, "n1", "", "", 0, 0));
    // 防御性：负值同样不可用于判定。
    try std.testing.expectEqual(Decision.expired, verify(raw, "s", &stored, &claim, .event_append, "n1", "", "", 0, -1));
    // 正常时钟下仍必须放行，避免修复引入误伤。
    try std.testing.expectEqual(Decision.ok, verify(raw, "s", &stored, &claim, .event_append, "n1", "", "", 0, 50));
}

test "event append enforces monotonic event seq" {
    const claim: Claim = .{ .scope = .event_append, .node_id = "n1", .session_id = "s1", .plan_digest = "p", .expires_mono = 100, .event_seq = 7 };
    const raw = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";
    const stored = hashOf(raw, "s");
    try std.testing.expectEqual(Decision.ok, verify(raw, "s", &stored, &claim, .event_append, "n1", "", "", 7, 50));
    try std.testing.expectEqual(Decision.event_seq_mismatch, verify(raw, "s", &stored, &claim, .event_append, "n1", "", "", 8, 50));
}

test "v0.4 capability derivation is deterministic and domain separated" {
    var first: [token_len]u8 = undefined;
    var second: [token_len]u8 = undefined;
    var other_audience: [token_len]u8 = undefined;
    deriveToken(&first, "master", "deployment", "first-boot:exchange", "node-1", 4, 2);
    deriveToken(&second, "master", "deployment", "first-boot:exchange", "node-1", 4, 2);
    deriveToken(&other_audience, "master", "deployment", "first-boot:event", "node-1", 4, 2);
    try std.testing.expectEqualSlices(u8, &first, &second);
    try std.testing.expect(!std.mem.eql(u8, &first, &other_audience));
}
