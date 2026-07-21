//! 确定性的 PXE 启动决策点。
//!
//! DHCP handler 从不根据厂商字符串推断架构：RFC 4578 option 93（Client System
//! Architecture Type）是架构的权威来源。本模块根据已注册 MAC 或 unknown-client
//! policy 解析启动行为，并返回可审计的配置身份（profile/mode）。
//!
//! M3.6 架构一致性：已登记节点的 RFC 4578 PXE 架构必须与 node/profile arch
//! 相同。不一致时仍可完成 DHCP 诊断 lease（保证网络可达性可排查），但不下发
//! GRUB bootfile，防止跨架构 loader 再加载错误内核（例如 ARM64 节点收到
//! x86_64 GRUB 二进制后无法继续）。

const model = @import("../model.zig");
const packet = @import("../dhcp/packet.zig");
const deployment_control = @import("../state/deployment_control.zig");

/// DHCP 唯一的 PXE 决策结果。
///
/// M2.5.1 同时返回 profile/mode，使创建 boot session 时使用与 DHCP 回复相同
/// 的配置快照，而不是在之后按可变配置重新推断节点归属。这避免了 DHCP ACK
/// 和 TFTP/HTTP 之间因配置变更导致身份不一致的竞态。
pub const Decision = struct {
    /// 下发给客户端的 PXE bootfile 路径（相对于 TFTP root），null 表示不下发。
    bootfile: ?[]const u8,
    /// 客户端 MAC 是否匹配已注册节点。
    known: bool,
    /// 已注册节点的 ID，unknown 客户端为 null。
    node_id: ?[]const u8,
    /// 已注册节点的静态保留 IP，unknown 客户端为 null。
    reserved_ip: ?[]const u8 = null,
    /// 匹配到的 profile 名称，用于 boot session 创建。
    profile: ?[]const u8 = null,
    /// profile 的启动模式（install/diskless/discovery），用于 boot session 创建。
    mode: ?model.BootKind = null,
    /// 安装 profile 被有意暂停在 PXE gate，因为没有待执行的 generation
    ///（或其请求针对的是旧计划）。
    install_not_armed: bool = false,
    /// M4.2 F2: node has deploy=false; PXE denied but diagnostic lease still served.
    deploy_disabled: bool = false,
};

/// 按已注册 MAC 或 unknown-client policy 解析启动行为和可审计的配置身份。
///
/// 解析顺序：
/// 1. 遍历投影到本次不可变模型视图的 catalog nodes，按 MAC 匹配已注册节点。
///    - 如果匹配到，检查 PXE 架构是否与节点配置一致（M3.6）。
///    - 架构一致：返回对应架构的 GRUB bootfile 和 profile/mode。
///    - 架构不一致：仍返回 known=true 和 profile/mode（lease 可发放用于诊断），
///      但 bootfile=null（不下发 GRUB，阻止后续 kernel/initrd 加载）。
/// 2. 未匹配到注册节点时不下发 bootfile；DHCP record/deny policy 由 catalog singleton 处理。
pub fn resolve(config: *const model.AppConfig, mac: []const u8, arch: packet.Architecture) Decision {
    for (config.nodes) |node| if (sameMac(node.mac, mac)) {
        // M4.2 F2: deploy=false 是硬外层开关，在 mode 判定前即返回无 bootfile。
        // 仍发诊断 DHCP lease（known=true + reserved_ip），但不下发 PXE。
        // mode=null 使 resolveWithDeployment 的 generation gate 被完全绕过。
        if (!node.deploy) return .{
            .bootfile = null,
            .known = true,
            .node_id = node.id,
            .reserved_ip = node.pxe.ip_reservation orelse node.ip,
            .profile = node.profile,
            .mode = null,
            .install_not_armed = false,
            .deploy_disabled = true,
        };
        // M3.6：不给 x86 GRUB 二进制文件到 ARM profile（反之亦然）。
        // lease 仍可发放以保证网络可达性可诊断，但 PXE 必须在
        // 不匹配的 kernel/initrd 被选中之前停止。
        return .{
            .bootfile = if (node.profile != null and architectureMatches(node.arch, arch)) bootfile(arch) else null,
            .known = true,
            .node_id = node.id,
            .reserved_ip = node.pxe.ip_reservation orelse node.ip,
            .profile = node.profile,
            .mode = if (node.profile) |name| profileMode(config, name) else null,
        };
    };
    return .{ .bootfile = null, .known = false, .node_id = null, .profile = null, .mode = null };
}

/// M4.1 破坏性安装 gate。DHCP 仍可提供诊断 lease，
/// 但未武装 generation 的安装 profile 不会收到 PXE bootfile。
pub fn resolveWithDeployment(config: *const model.AppConfig, deployments: ?*deployment_control.Store, digest: deployment_control.Digest, mac: []const u8, arch: packet.Architecture) Decision {
    var decision = resolve(config, mac, arch);
    if (decision.mode == .install and decision.node_id != null and deployments != null and !deployments.?.isArmedForDigest(decision.node_id.?, digest)) {
        decision.bootfile = null;
        decision.install_not_armed = true;
    }
    return decision;
}

test "consumed install generation suppresses PXE bootfile" {
    var deployments: deployment_control.Store = .{};
    const digest: deployment_control.Digest = [_]u8{'1'} ** 64;
    try deployments.ensureInitial("node-01", digest, 1);
    _ = try deployments.consume("node-01");
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.50.1" }, .nodes = &.{.{ .id = "node-01", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "install" }}, .profiles = &.{.{ .name = "install", .install_source = "source" }} };
    const decision = resolveWithDeployment(&config, &deployments, digest, &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee }, .aarch64);
    try @import("std").testing.expect(decision.bootfile == null);
}

test "deploy=false suppresses PXE bootfile but keeps diagnostic lease" {
    const std = @import("std");
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.50.1" },
        .nodes = &.{.{ .id = "node-01", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "install", .deploy = false }},
        .profiles = &.{.{ .name = "install", .install_source = "source" }},
    };
    const decision = resolve(&config, &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee }, .aarch64);
    try std.testing.expect(decision.bootfile == null);
    try std.testing.expect(decision.known);
    try std.testing.expect(decision.mode == null); // generation gate bypassed
}

test "deploy=true (default) still gets bootfile" {
    const std = @import("std");
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.50.1" },
        .nodes = &.{.{ .id = "node-01", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "install" }},
        .profiles = &.{.{ .name = "install", .install_source = "source" }},
    };
    const decision = resolve(&config, &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee }, .aarch64);
    try std.testing.expect(decision.bootfile != null);
    try std.testing.expect(decision.known);
}

test "always reinstall policy still requires an armed generation" {
    var deployments: deployment_control.Store = .{};
    const digest: deployment_control.Digest = [_]u8{'1'} ** 64;
    try deployments.ensureInitial("node-01", digest, 1);
    _ = try deployments.consume("node-01");
    const config: model.AppConfig = .{ .server = .{ .server_ip = "192.168.50.1" }, .nodes = &.{.{ .id = "node-01", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "install" }}, .profiles = &.{.{ .name = "install", .install_source = "source", .install = .{ .reinstall_policy = .always } }} };
    const decision = resolveWithDeployment(&config, &deployments, digest, &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee }, .aarch64);
    try @import("std").testing.expect(decision.bootfile == null);
    try @import("std").testing.expect(decision.install_not_armed);
}

/// 检查节点配置的架构与 PXE 客户端申报的架构是否一致。
///
/// RFC 4578 option 93 定义了客户端的 PXE 架构。如果客户端以 x86_64 PXE
/// 架构发起请求但节点配置为 aarch64，说明可能存在错误的 DHCP 中继或
/// 节点配置错误。此时不下发 bootfile 以阻止加载错误架构的 GRUB/kernel。
/// `unknown` 架构永远返回 false（保守策略，不猜测）。
fn architectureMatches(expected: model.Arch, actual: packet.Architecture) bool {
    return switch (actual) {
        .x86_64 => expected == .x86_64,
        .aarch64 => expected == .aarch64,
        .unknown => false,
    };
}

/// 按名称查找 profile 并返回其 mode。
///
/// 配置校验保证已引用的 profile 存在；保留 optional 返回值是为了让解析器
/// 在损坏输入下仍然采取安全的无模式降级，而不是伪造一个启动模式。
/// 返回 null 时，DHCP 仍可发放 lease 但 TFTP 不会渲染虚拟 GRUB 配置。
fn profileMode(config: *const model.AppConfig, name: []const u8) ?model.BootKind {
    for (config.profiles) |profile| if (@import("std").mem.eql(u8, profile.name, name)) return .install;
    return null;
}

/// 返回指定 PXE 架构对应的 GRUB EFI bootfile 路径。
///
/// 路径相对于 TFTP root，与 catalog 中的 asset 路径一致。
/// - x86_64 UEFI：`efi/grubx64.efi`
/// - aarch64 UEFI：`efi/grubaa64.efi`
/// - unknown：null（不猜测，不下发 bootfile）
/// BIOS PXELINUX 支持在 M6 补齐。
fn bootfile(arch: packet.Architecture) ?[]const u8 {
    return switch (arch) {
        .x86_64 => "efi/grubx64.efi",
        .aarch64 => "efi/grubaa64.efi",
        .unknown => null,
    };
}

/// 比较文本形式 MAC 地址（如 `02:aa:bb:cc:dd:ee`）与原始 6 字节 MAC。
///
/// 文本 MAC 必须是严格的 `XX:XX:XX:XX:XX:XX` 格式（17 字符），十六进制
/// 字母大小写均可。此函数用于 DHCP 请求中的原始 MAC 与 config 中注册的
/// 文本 MAC 匹配。
pub fn sameMac(text: []const u8, raw: []const u8) bool {
    if (text.len != 17 or raw.len != 6) return false;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const hi = hex(text[i * 3]);
        const lo = hex(text[i * 3 + 1]);
        if (hi == null or lo == null) return false;
        // 前 5 组后面必须是冒号分隔符。
        if (i < 5 and text[i * 3 + 2] != ':') return false;
        // 将两个 hex nibble 组合为一个字节并与原始 MAC 比较。
        if ((hi.? << 4 | lo.?) != raw[i]) return false;
    }
    return true;
}

/// 将单个 ASCII 字符转换为 0-15 的十六进制值，非 hex 字符返回 null。
fn hex(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// M3.6 测试：已注册节点以不匹配的 PXE 架构发起 DHCP 请求时，
// 仍可完成 lease（known=true），但不下发 bootfile（bootfile=null）。
// 这保证了网络诊断的可达性，同时阻止跨架构 kernel/initrd 加载。
test "known node with mismatched PXE architecture gets no bootfile" {
    const config: model.AppConfig = .{
        .server = .{ .server_ip = "192.168.50.1" },
        .nodes = &.{.{ .id = "arm-node", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "arm-profile" }},
        .profiles = &.{.{ .name = "arm-profile", .install_source = "source" }},
    };
    // 节点配置为 aarch64，但 PXE 客户端以 x86_64 架构发起请求。
    const decision = resolve(&config, &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee }, .x86_64);
    try @import("std").testing.expect(decision.known);
    try @import("std").testing.expect(decision.bootfile == null);
}
