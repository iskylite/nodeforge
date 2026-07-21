//! 安装器适配器共享的渲染辅助函数。
//!
//! 本模块提供 Kickstart 和 Autoinstall 适配器共用的工具函数：
//! - 主机名推导
//! - 密码哈希（SHA-256，仅用于 Autoinstall 需要非明文密码的场景）
//! - YAML 单引号字符串转义
//!
//! 安全说明：
//! - 密码哈希使用确定性 SHA-256，不等于 crypt(3) 的 SHA-512。
//!   安装器密码哈希由目标安装器自身完成（Anaconda/Subiquity），
//!   此处的 SHA-256 仅在适配器需要非明文字段时使用。
//! - YAML 转义遵循 YAML 单引号字符串规则：单引号内的单引号用双单引号转义。

const std = @import("std");

/// 比较两个 SSH 公钥是否相同（忽略注释部分）。
///
/// SSH 公钥格式为 `<algorithm> <base64-blob> [comment]`。
/// 此函数只比较 algorithm 和 blob，忽略可选的 comment。
/// 用于检测重复密钥时去重。
pub fn sameSshKey(left: []const u8, right: []const u8) bool {
    const left_parts = sshKeyParts(left) orelse return false;
    const right_parts = sshKeyParts(right) orelse return false;
    return std.mem.eql(u8, left_parts.algorithm, right_parts.algorithm) and std.mem.eql(u8, left_parts.blob, right_parts.blob);
}

/// SSH 公钥解析结果。
const SshKeyParts = struct {
    /// 密钥算法（如 `ssh-ed25519`）。
    algorithm: []const u8,
    /// Base64 编码的密钥 blob。
    blob: []const u8,
};

/// 将 SSH 公钥字符串解析为 algorithm + blob 部分。
/// 格式无效时返回 null。
fn sshKeyParts(value: []const u8) ?SshKeyParts {
    const first = std.mem.indexOfScalar(u8, value, ' ') orelse return null;
    const tail = std.mem.trimStart(u8, value[first + 1 ..], " \t");
    const second = std.mem.indexOfScalar(u8, tail, ' ') orelse tail.len;
    if (first == 0 or second == 0) return null;
    return .{ .algorithm = value[0..first], .blob = tail[0..second] };
}

test "SSH key equality ignores comments but not key blobs" {
    try std.testing.expect(sameSshKey("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+ first", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+ second"));
    try std.testing.expect(!sameSshKey("ssh-ed25519 AAAA first", "ssh-ed25519 AAAB second"));
}
const model = @import("../model.zig");

/// 返回节点主机名。优先使用 `node.hostname`，为 null 时回退到 `node.id`。
/// 这确保所有节点都有可标识的主机名，即使操作员未显式配置。
pub fn hostname(node: *const model.NodeConfig) []const u8 {
    return node.hostname orelse node.id;
}

/// 计算 SHA-256 密码摘要并返回小写十六进制字符串。
///
/// 安装器密码格式通常需要 crypt(3) 哈希，但 MVP 配置模型有意以明文存储操作员输入。
/// SHA-512 crypt 由目标安装器完成；此确定性 SHA-256 摘要仅在适配器需要
/// 非明文字段时使用（例如 Ubuntu Autoinstall 的 `password` 字段）。
///
/// `buffer` 必须至少 64 字节（SHA-256 摘要的十六进制编码长度）。
pub fn passwordDigest(buffer: *[64]u8, password: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(buffer[0..hex.len], &hex);
    return buffer[0..hex.len];
}

/// 将字符串以 YAML 单引号格式写入。
///
/// YAML 单引号字符串规则：字符串用单引号包裹，内部的单引号用双单引号转义。
/// 例如 `it's` → `'it''s'`。
/// 这比双引号字符串更安全，因为单引号字符串不支持转义序列注入。
pub fn yamlQuote(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('\'');
    for (value) |c| {
        if (c == '\'') try writer.writeAll("''") else try writer.writeByte(c);
    }
    try writer.writeByte('\'');
}
