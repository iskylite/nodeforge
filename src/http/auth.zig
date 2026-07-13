//! M3 认证规范化层。
//!
//! 路由 handler 接收此模块返回的服务端推导值，不得自行解释 node ID、peer
//! 地址或 bearer header。这确保认证逻辑集中在单一位置，减少攻击面。
//!
//! 两种认证方式：
//! - `bootstrap`：基于 DHCP lease-IP 对等认证。节点首次访问 HTTP 时只有
//!   IP 地址，通过匹配活动 boot session 的 lease-IP 确认身份。适用于
//!   Anaconda/Subiquity 在安装阶段拉取 answer 文件的场景。
//! - `capability`：基于 bearer token + session header 认证。节点通过
//!   `/api/v1/nodes/<id>/config` 获取 capability token 后，使用
//!   `Authorization: Bearer <token>` 和 `X-NodeForge-Session: <id>` header
//!   访问受保护资源。适用于安装后事件上报和 rootfs 下载。

const std = @import("std");
const boot_session = @import("../state/boot_session.zig");
const contracts = @import("contracts.zig");

/// 认证方式类型。
pub const Proof = enum {
    /// 基于 DHCP lease-IP 的对等认证（无需 token）。
    bootstrap,
    /// 基于 bearer token + session header 的能力认证。
    capability,
};

/// 认证结果，包含认证方式和已验证的 session 身份。
pub const Result = struct {
    /// 使用的认证方式。
    proof: Proof,
    /// 已验证的 session 身份（值拷贝，不持有 mutex）。
    session: boot_session.Authenticated,
};

/// 将 peer 地址字符串解析为 32 位大端序 IPv4 值。
///
/// facil.io 通常提供裸 IPv4 字面量。此函数也接受可选的端口后缀，
/// 但拒绝 IPv6 和非地址标签。
pub fn parsePeerIpv4(value: []const u8) !u32 {
    // facil.io 通常提供裸 IPv4 字面量。也接受可选的端口后缀，
    // 但拒绝 IPv6 和非地址标签。
    const literal = if (std.mem.lastIndexOfScalar(u8, value, ':')) |index| value[0..index] else value;
    const address = std.Io.net.IpAddress.parseIp4(literal, 0) catch return error.InvalidPeerAddress;
    return switch (address) {
        .ip4 => |ip| std.mem.readInt(u32, &ip.bytes, .big),
        else => error.InvalidPeerAddress,
    };
}

/// 校验 node ID 是否只包含安全字符（字母、数字、连字符、下划线）。
/// 长度限制 96 字符，防止过长的 ID 消耗资源。
pub fn nodeIdSafe(value: []const u8) bool {
    if (value.len == 0 or value.len > 96) return false;
    for (value) |byte| if (!((byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '-' or byte == '_')) return false;
    return true;
}

/// 从 Authorization header 值中提取 bearer token。
///
/// 接受格式：`Bearer <64位十六进制token>`。
/// token 长度必须与 `boot_session.capability_len` 一致（64 字符）。
/// 返回 null 表示格式不匹配；调用方应将其视为缺少认证。
pub fn bearer(value: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    const token = value[prefix.len..];
    if (token.len != boot_session.capability_len) return null;
    for (token) |byte| if (!std.ascii.isHex(byte)) return null;
    return token;
}

/// 认证节点请求。根据是否携带 Authorization/Session header 选择认证方式。
///
/// - 有 Authorization 和 Session header：使用 capability 认证
/// - 无 header：使用 bootstrap（peer IP）认证
/// - 只有其中一个 header：返回 MissingProof 错误
///
/// 认证失败时返回对应错误（InvalidNodeId、MissingProof 等）。
pub fn authenticate(store: *boot_session.Store, node_id: []const u8, peer: []const u8, authorization: ?[]const u8, session_header: ?[]const u8, mono_now: i64) !Result {
    if (!nodeIdSafe(node_id)) return error.InvalidNodeId;
    if (authorization != null or session_header != null) {
        const token = bearer(authorization orelse return error.MissingProof) orelse return error.MissingProof;
        const session_id = session_header orelse return error.MissingProof;
        return .{ .proof = .capability, .session = try store.authenticateCapability(node_id, session_id, token, mono_now) };
    }
    return .{ .proof = .bootstrap, .session = try store.authenticateBootstrap(node_id, try parsePeerIpv4(peer), mono_now) };
}

/// 认证资产下载请求。只接受 capability 认证（不支持 bootstrap）。
///
/// 资产下载（如 ISO、rootfs）需要比 bootstrap 更强的认证，
/// 因为这些文件可能包含敏感内容。调用方必须同时提供
/// Authorization 和 Session header。
pub fn authenticateAsset(store: *boot_session.Store, authorization: ?[]const u8, session_header: ?[]const u8, mono_now: i64) !boot_session.Authenticated {
    const token = bearer(authorization orelse return error.MissingProof) orelse return error.MissingProof;
    return store.authenticateCapabilityAny(session_header orelse return error.MissingProof, token, mono_now);
}

// 测试：验证 bearer token 解析只接受正确格式的 token。
test "bearer parsing never accepts a token in another shape" {
    const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expectEqualStrings(token, bearer("Bearer " ++ token).?);
    try std.testing.expect(bearer(token) == null);
    try std.testing.expect(bearer("Bearer short") == null);
}
