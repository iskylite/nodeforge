//! One deterministic PXE boot decision point.  DHCP handlers never infer an
//! architecture from vendor strings: RFC 4578 option 93 is authoritative.
const model = @import("../model.zig");
const packet = @import("../dhcp/packet.zig");
/// DHCP 唯一的 PXE 决策结果。
///
/// M2.5.1 同时返回 profile/mode，使创建 boot session 时使用与 DHCP 回复相同
/// 的配置快照，而不是在之后按可变配置重新推断节点归属。
pub const Decision = struct {
    bootfile: ?[]const u8,
    known: bool,
    node_id: ?[]const u8,
    reserved_ip: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    mode: ?model.ProfileMode = null,
};
/// 按已注册 MAC 或 unknown-client policy 解析启动行为和可审计的配置身份。
pub fn resolve(config: *const model.AppConfig, mac: []const u8, arch: packet.Architecture) Decision {
    for (config.nodes) |node| if (sameMac(node.mac, mac)) return .{
        .bootfile = bootfile(arch),
        .known = true,
        .node_id = node.id,
        .reserved_ip = node.ip,
        .profile = node.profile,
        .mode = profileMode(config, node.profile),
    };
    const profile = config.policy.default_profile;
    return switch (config.policy.default_action) {
        .deny, .wait => .{ .bootfile = null, .known = false, .node_id = null, .profile = profile, .mode = if (profile) |name| profileMode(config, name) else null },
        .discovery => .{ .bootfile = bootfile(arch), .known = false, .node_id = null, .profile = profile, .mode = if (profile) |name| profileMode(config, name) else .discovery },
        .diskless => if (config.policy.allow_unknown_diskless) .{ .bootfile = bootfile(arch), .known = false, .node_id = null, .profile = profile, .mode = if (profile) |name| profileMode(config, name) else .diskless } else .{ .bootfile = null, .known = false, .node_id = null, .profile = profile, .mode = if (profile) |name| profileMode(config, name) else null },
    };
}
/// 配置校验保证已引用 profile 存在；保留 optional 是为了让解析器在损坏输入下
/// 仍然采取安全的无模式降级，而不是伪造一个启动模式。
fn profileMode(config: *const model.AppConfig, name: []const u8) ?model.ProfileMode {
    for (config.profiles) |profile| if (@import("std").mem.eql(u8, profile.name, name)) return profile.mode;
    return null;
}
/// Paths are relative to the TFTP root and deliberately match catalog assets.
fn bootfile(arch: packet.Architecture) ?[]const u8 {
    return switch (arch) {
        .x86_64 => "efi/grubx64.efi",
        .aarch64 => "efi/grubaa64.efi",
        .unknown => null,
    };
}
pub fn sameMac(text: []const u8, raw: []const u8) bool {
    if (text.len != 17 or raw.len != 6) return false;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const hi = hex(text[i * 3]);
        const lo = hex(text[i * 3 + 1]);
        if (hi == null or lo == null) return false;
        if (i < 5 and text[i * 3 + 2] != ':') return false;
        if ((hi.? << 4 | lo.?) != raw[i]) return false;
    }
    return true;
}
fn hex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}
