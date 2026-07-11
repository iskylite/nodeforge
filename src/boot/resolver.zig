//! One deterministic PXE boot decision point.  DHCP handlers never infer an
//! architecture from vendor strings: RFC 4578 option 93 is authoritative.
const model = @import("../model.zig");
const packet = @import("../dhcp/packet.zig");
pub const Decision = struct { bootfile: ?[]const u8, known: bool, node_id: ?[]const u8, reserved_ip: ?[]const u8 = null };
pub fn resolve(config: *const model.AppConfig, mac: []const u8, arch: packet.Architecture) Decision {
    for (config.nodes) |node| if (sameMac(node.mac, mac)) return .{ .bootfile = bootfile(arch), .known = true, .node_id = node.id, .reserved_ip = node.ip };
    return switch (config.policy.default_action) { .deny, .wait => .{ .bootfile = null, .known = false, .node_id = null }, .discovery => .{ .bootfile = bootfile(arch), .known = false, .node_id = null }, .diskless => if (config.policy.allow_unknown_diskless) .{ .bootfile = bootfile(arch), .known = false, .node_id = null } else .{ .bootfile = null, .known = false, .node_id = null } };
}
/// Paths are relative to the TFTP root and deliberately match catalog assets.
fn bootfile(arch: packet.Architecture) ?[]const u8 { return switch (arch) { .x86_64 => "efi/grubx64.efi", .aarch64 => "efi/grubaa64.efi", .unknown => null }; }
pub fn sameMac(text: []const u8, raw: []const u8) bool { if (text.len != 17 or raw.len != 6) return false; var i: usize = 0; while (i < 6) : (i += 1) { const hi = hex(text[i * 3]); const lo = hex(text[i * 3 + 1]); if (hi == null or lo == null) return false; if (i < 5 and text[i * 3 + 2] != ':') return false; if ((hi.? << 4 | lo.?) != raw[i]) return false; } return true; }
fn hex(c: u8) ?u8 { return switch (c) { '0'...'9' => c - '0', 'a'...'f' => c - 'a' + 10, 'A'...'F' => c - 'A' + 10, else => null }; }
