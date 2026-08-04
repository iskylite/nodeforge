//! NodeForge v0.4 target-network topology validator.
//!
//! This module is deliberately independent of DHCP/PXE.  `node.mac` and
//! `pxe.ip_reservation` describe the bootstrap transport; this validator only
//! accepts the network that the installed or diskless target must adopt.

const std = @import("std");
const model = @import("../model.zig");

pub const max_interfaces: usize = 64;
pub const max_bonds: usize = 16;
pub const max_vlans: usize = 64;
pub const max_routes: usize = 256;
pub const max_dns: usize = 16;
pub const max_search_domains: usize = 16;
pub const max_bond_members: usize = 32;

pub const ValidationError = error{
    TopologyTooLarge,
    InvalidLinkId,
    InvalidMac,
    DuplicateLinkId,
    DuplicateRouteId,
    DuplicateMac,
    DuplicateBondMember,
    InterfaceNotFound,
    BondNotFound,
    InvalidBondMembers,
    InterfaceAlreadyBonded,
    BondMacSourceInvalid,
    BondPrimaryInvalid,
    BondModeFieldMismatch,
    BondTimingInvalid,
    BondMinLinksInvalid,
    InvalidMtu,
    InvalidVlan,
    VlanParentNotFound,
    VlanOnVlan,
    InvalidIpv4Mode,
    MissingIpv4Address,
    UnexpectedIpv4Address,
    InvalidIpv4,
    InvalidPrefix,
    DuplicateStaticAddress,
    TooManyDhcpLinks,
    MissingL3Link,
    DuplicateDefaultRoute,
    InvalidRoute,
    RouteInterfaceNotFound,
    RouteInterfaceHasNoL3,
    GatewayUnreachable,
    DuplicateDns,
    DuplicateSearchDomain,
    InvalidDns,
    InvalidSearchDomain,
    BootstrapInterfaceMissing,
    BootstrapMacMismatch,
};

pub fn validateNetwork(network: model.TargetNetworkConfig, bootstrap_mac: []const u8, deployable: bool) ValidationError!void {
    // BOND-字段契约：structured collections 的上限是协议/plan 的硬边界，
    // 不能通过截断来“修复”一个过大的 immutable plan。
    if (network.interfaces.len > max_interfaces or network.bonds.len > max_bonds or
        network.vlans.len > max_vlans or network.routes.len > max_routes or
        network.dns.len > max_dns or network.search_domains.len > max_search_domains)
        return error.TopologyTooLarge;

    for (network.dns, 0..) |dns, i| {
        _ = parseIpv4(dns) catch return error.InvalidDns;
        for (network.dns[i + 1 ..]) |other| if (std.ascii.eqlIgnoreCase(dns, other)) return error.DuplicateDns;
    }
    for (network.search_domains, 0..) |domain, i| {
        if (!validDomain(domain)) return error.InvalidSearchDomain;
        for (network.search_domains[i + 1 ..]) |other| if (std.ascii.eqlIgnoreCase(domain, other)) return error.DuplicateSearchDomain;
    }

    var dhcp_count: usize = 0;
    var default_count: usize = 0;
    var bootstrap_seen = false;
    var static_addresses: [max_interfaces + max_bonds + max_vlans][]const u8 = undefined;
    var static_count: usize = 0;
    var all_ids: [max_interfaces + max_bonds + max_vlans][]const u8 = undefined;
    var all_count: usize = 0;

    for (network.interfaces) |iface| {
        try validateLinkId(iface.id);
        try validateMtu(iface.mtu);
        try validateMac(iface.mac);
        try appendUniqueLink(&all_ids, &all_count, iface.id);
        if (std.ascii.eqlIgnoreCase(iface.mac, bootstrap_mac)) bootstrap_seen = true;
        try validateIpv4(iface.ipv4, &dhcp_count, &default_count, &static_addresses, &static_count);
    }
    for (network.bonds) |bond| {
        try validateLinkId(bond.id);
        try appendUniqueLink(&all_ids, &all_count, bond.id);
        if (bond.members.len < 2 or bond.members.len > max_bond_members) return error.InvalidBondMembers;
        if (bond.miimon_ms < 50 or bond.miimon_ms > 1000 or bond.up_delay_ms % bond.miimon_ms != 0 or bond.down_delay_ms % bond.miimon_ms != 0)
            return error.BondTimingInvalid;
        if (bond.mtu) |mtu| try validateMtu(mtu);
        var member_count: usize = 0;
        for (bond.members) |member| {
            if (findInterface(network.interfaces, member) == null) return error.InterfaceNotFound;
            for (bond.members[0..member_count]) |prior| if (std.mem.eql(u8, prior, member)) return error.DuplicateBondMember;
            member_count += 1;
            const iface = findInterface(network.interfaces, member).?;
            if (iface.ipv4.mode != .none or iface.ipv4.address != null or iface.ipv4.prefix_len != null)
                return error.InvalidBondMembers;
        }
        for (network.bonds) |other| if (!std.mem.eql(u8, other.id, bond.id)) for (other.members) |member| for (bond.members) |candidate| if (std.mem.eql(u8, member, candidate)) return error.InterfaceAlreadyBonded;
        if (findInterface(network.interfaces, bond.mac_source_id) == null or !contains(bond.members, bond.mac_source_id)) return error.BondMacSourceInvalid;
        switch (bond.mode) {
            .active_backup => {
                if (bond.primary_id == null or !contains(bond.members, bond.primary_id.?)) return error.BondPrimaryInvalid;
                if (bond.min_links != 1 or bond.lacp_rate != .fast or bond.xmit_hash_policy != .layer2_3) return error.BondModeFieldMismatch;
            },
            .ieee8023ad => {
                if (bond.primary_id != null or bond.min_links == 0 or bond.min_links > bond.members.len) return error.BondModeFieldMismatch;
            },
        }
        try validateIpv4(bond.ipv4, &dhcp_count, &default_count, &static_addresses, &static_count);
    }
    for (network.vlans) |vlan| {
        try validateLinkId(vlan.id);
        try appendUniqueLink(&all_ids, &all_count, vlan.id);
        if (vlan.vlan_id == 0 or vlan.vlan_id > 4094) return error.InvalidVlan;
        if (findInterface(network.interfaces, vlan.parent_id) == null and findBond(network.bonds, vlan.parent_id) == null) return error.VlanParentNotFound;
        if (findVlan(network.vlans, vlan.parent_id) != null) return error.VlanOnVlan;
        const parent_mtu = if (findInterface(network.interfaces, vlan.parent_id)) |iface| iface.mtu else if (findBond(network.bonds, vlan.parent_id)) |bond| bond.mtu orelse 1500 else 0;
        if (vlan.mtu) |mtu| if (mtu > parent_mtu) return error.InvalidMtu;
        try validateIpv4(vlan.ipv4, &dhcp_count, &default_count, &static_addresses, &static_count);
    }
    for (network.interfaces) |iface| for (network.interfaces) |other| if (!std.mem.eql(u8, iface.id, other.id) and std.ascii.eqlIgnoreCase(iface.mac, other.mac)) return error.DuplicateMac;

    for (network.routes) |route| {
        try validateLinkId(route.id);
        if (route.interface_id == null) return error.InvalidRoute;
        if (findLink(network, route.interface_id.?) == null) return error.RouteInterfaceNotFound;
        const link = findLink(network, route.interface_id.?).?;
        if (link.mode == .none) return error.RouteInterfaceHasNoL3;
        _ = parseCidr(route.destination) catch return error.InvalidRoute;
        _ = parseIpv4(route.gateway) catch return error.InvalidRoute;
        if (link.mode == .static) {
            const addr = link.address.?;
            const prefix = link.prefix_len.?;
            if (!sameSubnet(addr, route.gateway, prefix)) return error.GatewayUnreachable;
        }
        const parsed_dest = parseCidr(route.destination) catch return error.InvalidRoute;
        if (parsed_dest.network == 0 and parsed_dest.prefix == 0) default_count += 1;
    }
    if (default_count > 1) return error.DuplicateDefaultRoute;
    if (deployable and network.interfaces.len > 0 and !bootstrap_seen) return error.BootstrapMacMismatch;
    if (deployable and network.interfaces.len > 0 and !hasL3(network)) return error.MissingL3Link;
}

const Link = struct { mode: model.TopologyIpv4Mode, address: ?[]const u8, prefix_len: ?u8 };

fn validateIpv4(value: model.TopologyIpv4, dhcp_count: *usize, default_count: *usize, addresses: *[max_interfaces + max_bonds + max_vlans][]const u8, address_count: *usize) ValidationError!void {
    switch (value.mode) {
        .none => if (value.address != null or value.prefix_len != null) return error.UnexpectedIpv4Address,
        .dhcp => {
            if (value.address != null or value.prefix_len != null) return error.UnexpectedIpv4Address;
            dhcp_count.* += 1;
            if (dhcp_count.* > 1) return error.TooManyDhcpLinks;
            if (value.default_route) default_count.* += 1;
        },
        .static => {
            const address = value.address orelse return error.MissingIpv4Address;
            const prefix = value.prefix_len orelse return error.MissingIpv4Address;
            _ = parseIpv4(address) catch return error.InvalidIpv4;
            if (prefix == 0 or prefix > 32) return error.InvalidPrefix;
            for (addresses.*[0..address_count.*]) |existing| if (std.mem.eql(u8, existing, address)) return error.DuplicateStaticAddress;
            addresses.*[address_count.*] = address;
            address_count.* += 1;
        },
    }
}

fn hasL3(network: model.TargetNetworkConfig) bool {
    for (network.interfaces) |i| if (i.ipv4.mode != .none) return true;
    for (network.bonds) |b| if (b.ipv4.mode != .none) return true;
    for (network.vlans) |v| if (v.ipv4.mode != .none) return true;
    return false;
}

fn findInterface(items: []const model.TopologyInterface, id: []const u8) ?model.TopologyInterface {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}
fn findBond(items: []const model.TopologyBond, id: []const u8) ?model.TopologyBond {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}
fn findVlan(items: []const model.TopologyVlan, id: []const u8) ?model.TopologyVlan {
    for (items) |item| if (std.mem.eql(u8, item.id, id)) return item;
    return null;
}

fn findLink(network: model.TargetNetworkConfig, id: []const u8) ?Link {
    if (findInterface(network.interfaces, id)) |i| return .{ .mode = i.ipv4.mode, .address = i.ipv4.address, .prefix_len = i.ipv4.prefix_len };
    if (findBond(network.bonds, id)) |b| return .{ .mode = b.ipv4.mode, .address = b.ipv4.address, .prefix_len = b.ipv4.prefix_len };
    if (findVlan(network.vlans, id)) |v| return .{ .mode = v.ipv4.mode, .address = v.ipv4.address, .prefix_len = v.ipv4.prefix_len };
    return null;
}

fn appendUniqueLink(buffer: *[max_interfaces + max_bonds + max_vlans][]const u8, count: *usize, value: []const u8) ValidationError!void {
    for (buffer.*[0..count.*]) |prior| if (std.mem.eql(u8, prior, value)) return error.DuplicateLinkId;
    buffer.*[count.*] = value;
    count.* += 1;
}

fn validateLinkId(value: []const u8) ValidationError!void {
    if (value.len == 0 or value.len > 15 or !std.ascii.isAlphabetic(value[0]) or std.mem.startsWith(u8, value, "nf")) return error.InvalidLinkId;
    if (std.mem.eql(u8, value, "lo") or std.mem.eql(u8, value, "all") or std.mem.eql(u8, value, "default")) return error.InvalidLinkId;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return error.InvalidLinkId;
}

fn validateMac(value: []const u8) ValidationError!void {
    if (value.len != 17) return error.InvalidMac;
    for (value, 0..) |c, i| if (i % 3 == 2) {
        if (c != ':') return error.InvalidMac;
    } else if (!std.ascii.isHex(c)) return error.InvalidMac;
}
fn validateMtu(value: u16) ValidationError!void {
    if (value < 576 or value > 9216) return error.InvalidMtu;
}
fn parseIpv4(value: []const u8) !u32 {
    return switch (try std.Io.net.IpAddress.parseIp4(value, 0)) {
        .ip4 => |ip| std.mem.readInt(u32, &ip.bytes, .big),
        else => error.InvalidIpv4,
    };
}
const Cidr = struct { network: u32, prefix: u8 };
fn parseCidr(value: []const u8) !Cidr {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return error.InvalidRoute;
    const prefix = try std.fmt.parseInt(u8, value[slash + 1 ..], 10);
    if (prefix > 32) return error.InvalidRoute;
    const ip = try parseIpv4(value[0..slash]);
    const mask: u32 = if (prefix == 0) 0 else @as(u32, 0xffffffff) << @as(u5, @intCast(32 - prefix));
    return .{ .network = ip & mask, .prefix = prefix };
}
fn sameSubnet(address: []const u8, other: []const u8, prefix: u8) bool {
    const a = parseIpv4(address) catch return false;
    const b = parseIpv4(other) catch return false;
    const mask: u32 = if (prefix == 0) 0 else @as(u32, 0xffffffff) << @as(u5, @intCast(32 - prefix));
    return (a & mask) == (b & mask);
}
fn contains(items: []const []const u8, value: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}
fn validDomain(value: []const u8) bool {
    if (value.len == 0 or value.len > 253 or value[value.len - 1] == '.') return false;
    for (value) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.')) return false;
    return true;
}

test "v0.4 topology accepts a bond with one DHCP L3 owner" {
    const network: model.TargetNetworkConfig = .{
        .interfaces = &.{
            .{ .id = "eth0", .mac = "02:00:00:00:00:01", .ipv4 = .{} },
            .{ .id = "eth1", .mac = "02:00:00:00:00:02", .ipv4 = .{} },
        },
        .bonds = &.{.{ .id = "bond0", .mode = .active_backup, .members = &.{ "eth0", "eth1" }, .mac_source_id = "eth0", .primary_id = "eth0", .ipv4 = .{ .mode = .dhcp } }},
    };
    try validateNetwork(network, "02:00:00:00:00:01", true);
}

test "v0.4 reservation never changes target DHCP topology" {
    const network: model.TargetNetworkConfig = .{ .mode = .dhcp };
    try validateNetwork(network, "02:00:00:00:00:01", false);
}

test "v0.4 topology rejects member L3 and duplicate DHCP" {
    const network: model.TargetNetworkConfig = .{
        .interfaces = &.{
            .{ .id = "eth0", .mac = "02:00:00:00:00:01", .ipv4 = .{ .mode = .dhcp } },
            .{ .id = "eth1", .mac = "02:00:00:00:00:02", .ipv4 = .{ .mode = .dhcp } },
        },
    };
    try std.testing.expectError(error.TooManyDhcpLinks, validateNetwork(network, "02:00:00:00:00:01", true));
}
