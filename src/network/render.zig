//! # v0.4 结构化目标网络渲染器
//!
//! 规范拓扑集合（`interfaces`/`bonds`/`vlans`/`routes` 与根级 DNS/search domains）
//! 必须完整落到目标 OS，**禁止静默丢字段**。本模块是生产路径的唯一渲染入口：
//! - 装机 Ubuntu autoinstall netplan
//! - 装机 Kickstart `%post` NetworkManager 物化（keyfile / ifcfg-rh）
//! - diskless `node-apply renderNetwork`
//!
//! 当 structured 集合为空时，flat 单网卡字段仍是兼容路径；调用方用
//! `hasStructured` 分支。渲染前应已通过 `topology.validateNetwork`。

const std = @import("std");
const model = @import("../model.zig");

/// 是否声明了 structured 拓扑（任一 interface/bond/vlan 集合非空）。
pub fn hasStructured(network: model.TargetNetworkConfig) bool {
    return network.interfaces.len > 0 or network.bonds.len > 0 or network.vlans.len > 0;
}

/// 渲染 netplan v2 YAML（Ubuntu autoinstall / diskless netplan 路径）。
/// 返回调用方拥有的切片。
pub fn renderNetplan(allocator: std.mem.Allocator, network: model.TargetNetworkConfig) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("network:\n  version: 2\n");
    if (network.interfaces.len != 0) {
        try w.writeAll("  ethernets:\n");
        for (network.interfaces) |iface| {
            try w.print("    {s}:\n      match:\n        macaddress: \"{s}\"\n      set-name: {s}\n", .{ iface.id, iface.mac, iface.id });
            if (iface.mtu != 1500) try w.print("      mtu: {d}\n", .{iface.mtu});
            try writeNetplanIpv4(w, network, iface.id, iface.ipv4, 6);
        }
    }
    if (network.bonds.len != 0) {
        try w.writeAll("  bonds:\n");
        for (network.bonds) |bond| {
            try w.print("    {s}:\n      interfaces:\n", .{bond.id});
            for (bond.members) |member| try w.print("        - {s}\n", .{member});
            try w.writeAll("      parameters:\n");
            try w.print("        mode: {s}\n", .{bondModeNetplan(bond.mode)});
            try w.print("        mii-monitor-interval: {d}\n", .{bond.miimon_ms});
            if (bond.up_delay_ms != 0) try w.print("        up-delay: {d}\n", .{bond.up_delay_ms});
            if (bond.down_delay_ms != 0) try w.print("        down-delay: {d}\n", .{bond.down_delay_ms});
            if (bond.primary_id) |primary| try w.print("        primary: {s}\n", .{primary});
            switch (bond.mode) {
                .active_backup => try w.print("        primary-reselect-policy: {s}\n", .{@tagName(bond.primary_reselect)}),
                .ieee8023ad => {
                    try w.print("        lacp-rate: {s}\n", .{@tagName(bond.lacp_rate)});
                    try w.print("        transmit-hash-policy: {s}\n", .{xmitHashNetplan(bond.xmit_hash_policy)});
                    try w.print("        min-links: {d}\n", .{bond.min_links});
                },
            }
            if (bond.mtu) |mtu| try w.print("      mtu: {d}\n", .{mtu});
            try writeNetplanIpv4(w, network, bond.id, bond.ipv4, 6);
        }
    }
    if (network.vlans.len != 0) {
        try w.writeAll("  vlans:\n");
        for (network.vlans) |vlan| {
            try w.print("    {s}:\n      id: {d}\n      link: {s}\n", .{ vlan.id, vlan.vlan_id, vlan.parent_id });
            if (vlan.mtu) |mtu| try w.print("      mtu: {d}\n", .{mtu});
            try writeNetplanIpv4(w, network, vlan.id, vlan.ipv4, 6);
        }
    }
    return out.toOwnedSlice();
}

/// 写入单条链路的 IPv4 段（none/dhcp/static + 归属路由 + DNS）。
fn writeNetplanIpv4(w: *std.Io.Writer, network: model.TargetNetworkConfig, link_id: []const u8, ipv4: model.TopologyIpv4, indent: usize) !void {
    _ = indent;
    switch (ipv4.mode) {
        .none => try w.writeAll("      dhcp4: false\n"),
        .dhcp => {
            try w.writeAll("      dhcp4: true\n      dhcp6: false\n");
            try writeNetplanNameservers(w, network, 6);
        },
        .static => {
            try w.writeAll("      dhcp4: false\n      dhcp6: false\n");
            try w.print("      addresses:\n        - {s}/{d}\n", .{ ipv4.address.?, ipv4.prefix_len.? });
            var wrote_routes = false;
            if (ipv4.default_route) {
                // 默认路由：仅当本链路上存在 destination 为 default/0.0.0.0/0 的 route 时写出。
                for (network.routes) |route| {
                    if (!routeOwnsLink(route, link_id)) continue;
                    if (isDefaultDestination(route.destination)) {
                        if (!wrote_routes) {
                            try w.writeAll("      routes:\n");
                            wrote_routes = true;
                        }
                        try w.print("        - to: default\n          via: {s}\n", .{route.gateway});
                        if (route.metric) |metric| try w.print("          metric: {d}\n", .{metric});
                    }
                }
            }
            for (network.routes) |route| {
                if (!routeOwnsLink(route, link_id)) continue;
                if (isDefaultDestination(route.destination)) continue;
                if (!wrote_routes) {
                    try w.writeAll("      routes:\n");
                    wrote_routes = true;
                }
                try w.print("        - to: {s}\n          via: {s}\n", .{ route.destination, route.gateway });
                if (route.metric) |metric| try w.print("          metric: {d}\n", .{metric});
            }
            try writeNetplanNameservers(w, network, 6);
        },
    }
}

fn writeNetplanNameservers(w: *std.Io.Writer, network: model.TargetNetworkConfig, indent: usize) !void {
    _ = indent;
    if (network.dns.len == 0 and network.search_domains.len == 0) return;
    try w.writeAll("      nameservers:\n");
    if (network.dns.len != 0) {
        try w.writeAll("        addresses: [");
        for (network.dns, 0..) |dns, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", dns });
        try w.writeAll("]\n");
    }
    if (network.search_domains.len != 0) {
        try w.writeAll("        search: [");
        for (network.search_domains, 0..) |domain, i| try w.print("{s}{s}", .{ if (i == 0) "" else ", ", domain });
        try w.writeAll("]\n");
    }
}

/// NetworkManager keyfile 单文件（文件名 + 正文）；由 `renderNmKeyfiles` 分配。
pub const Keyfile = struct {
    filename: []const u8,
    content: []const u8,
};

/// 释放 `renderNmKeyfiles` 返回的切片及其内容。
pub fn freeKeyfiles(allocator: std.mem.Allocator, files: []Keyfile) void {
    for (files) |file| {
        allocator.free(file.filename);
        allocator.free(file.content);
    }
    allocator.free(files);
}

/// 为每条 structured 链路渲染 NetworkManager keyfile 正文。
/// bond 成员额外生成 `*-slave.nmconnection`；L3 只挂在 bond/vlan 本体上。
/// 返回拥有切片，调用方经 `freeKeyfiles` 释放。
pub fn renderNmKeyfiles(allocator: std.mem.Allocator, network: model.TargetNetworkConfig) ![]Keyfile {
    var list: std.ArrayList(Keyfile) = .empty;
    errdefer {
        for (list.items) |file| {
            allocator.free(file.filename);
            allocator.free(file.content);
        }
        list.deinit(allocator);
    }

    for (network.interfaces) |iface| {
        var content: std.Io.Writer.Allocating = .init(allocator);
        errdefer content.deinit();
        const w = &content.writer;
        try w.print("[connection]\nid={s}\ntype=ethernet\ninterface-name={s}\nautoconnect=true\n", .{ iface.id, iface.id });
        try w.print("[ethernet]\nmac-address={s}\n", .{iface.mac});
        if (iface.mtu != 1500) try w.print("mtu={d}\n", .{iface.mtu});
        try writeNmIpv4(w, network, iface.id, iface.ipv4);
        const body = try content.toOwnedSlice();
        errdefer allocator.free(body);
        const name = try std.fmt.allocPrint(allocator, "{s}.nmconnection", .{iface.id});
        errdefer allocator.free(name);
        try list.append(allocator, .{ .filename = name, .content = body });
    }
    for (network.bonds) |bond| {
        var content: std.Io.Writer.Allocating = .init(allocator);
        errdefer content.deinit();
        const w = &content.writer;
        try w.print("[connection]\nid={s}\ntype=bond\ninterface-name={s}\nautoconnect=true\n", .{ bond.id, bond.id });
        try w.print("[bond]\nmode={s}\nmiimon={d}\n", .{ bondModeNm(bond.mode), bond.miimon_ms });
        if (bond.up_delay_ms != 0) try w.print("updelay={d}\n", .{bond.up_delay_ms});
        if (bond.down_delay_ms != 0) try w.print("downdelay={d}\n", .{bond.down_delay_ms});
        if (bond.primary_id) |primary| try w.print("primary={s}\n", .{primary});
        switch (bond.mode) {
            .active_backup => try w.print("primary_reselect={s}\n", .{@tagName(bond.primary_reselect)}),
            .ieee8023ad => {
                try w.print("lacp_rate={s}\n", .{@tagName(bond.lacp_rate)});
                try w.print("xmit_hash_policy={s}\n", .{xmitHashNm(bond.xmit_hash_policy)});
                try w.print("min_links={d}\n", .{bond.min_links});
            },
        }
        if (bond.mtu) |mtu| try w.print("mtu={d}\n", .{mtu});
        // 从口连接单独成文件；bond 连接本体只承载 L3。
        try writeNmIpv4(w, network, bond.id, bond.ipv4);
        const body = try content.toOwnedSlice();
        errdefer allocator.free(body);
        const name = try std.fmt.allocPrint(allocator, "{s}.nmconnection", .{bond.id});
        errdefer allocator.free(name);
        try list.append(allocator, .{ .filename = name, .content = body });

        // bond 成员：ethernet + slave-type=bond，IPv4 关闭。
        for (network.interfaces) |iface| {
            if (!memberOf(bond.members, iface.id)) continue;
            var slave: std.Io.Writer.Allocating = .init(allocator);
            errdefer slave.deinit();
            const sw = &slave.writer;
            try sw.print("[connection]\nid={s}-slave\ntype=ethernet\ninterface-name={s}\nmaster={s}\nslave-type=bond\nautoconnect=true\n", .{ iface.id, iface.id, bond.id });
            try sw.print("[ethernet]\nmac-address={s}\n", .{iface.mac});
            try sw.writeAll("[ipv4]\nmethod=disabled\n[ipv6]\nmethod=ignore\n");
            const sbody = try slave.toOwnedSlice();
            errdefer allocator.free(sbody);
            const sname = try std.fmt.allocPrint(allocator, "{s}-slave.nmconnection", .{iface.id});
            errdefer allocator.free(sname);
            try list.append(allocator, .{ .filename = sname, .content = sbody });
        }
    }
    for (network.vlans) |vlan| {
        var content: std.Io.Writer.Allocating = .init(allocator);
        errdefer content.deinit();
        const w = &content.writer;
        try w.print("[connection]\nid={s}\ntype=vlan\ninterface-name={s}\nautoconnect=true\n", .{ vlan.id, vlan.id });
        try w.print("[vlan]\nid={d}\nparent={s}\n", .{ vlan.vlan_id, vlan.parent_id });
        if (vlan.mtu) |mtu| try w.print("mtu={d}\n", .{mtu});
        try writeNmIpv4(w, network, vlan.id, vlan.ipv4);
        const body = try content.toOwnedSlice();
        errdefer allocator.free(body);
        const name = try std.fmt.allocPrint(allocator, "{s}.nmconnection", .{vlan.id});
        errdefer allocator.free(name);
        try list.append(allocator, .{ .filename = name, .content = body });
    }
    return try list.toOwnedSlice(allocator);
}

fn writeNmIpv4(w: *std.Io.Writer, network: model.TargetNetworkConfig, link_id: []const u8, ipv4: model.TopologyIpv4) !void {
    switch (ipv4.mode) {
        .none => try w.writeAll("[ipv4]\nmethod=disabled\n[ipv6]\nmethod=ignore\n"),
        .dhcp => {
            try w.writeAll("[ipv4]\nmethod=auto\n");
            try writeNmDns(w, network);
            try w.writeAll("[ipv6]\nmethod=ignore\n");
        },
        .static => {
            try w.print("[ipv4]\nmethod=manual\naddress1={s}/{d}\n", .{ ipv4.address.?, ipv4.prefix_len.? });
            var route_index: usize = 1;
            for (network.routes) |route| {
                if (!routeOwnsLink(route, link_id)) continue;
                try w.print("route{d}={s},{s}", .{ route_index, route.destination, route.gateway });
                if (route.metric) |metric| try w.print(",{d}", .{metric});
                try w.writeByte('\n');
                route_index += 1;
            }
            try writeNmDns(w, network);
            try w.writeAll("[ipv6]\nmethod=ignore\n");
        },
    }
}

fn writeNmDns(w: *std.Io.Writer, network: model.TargetNetworkConfig) !void {
    if (network.dns.len != 0) {
        try w.writeAll("dns=");
        for (network.dns, 0..) |dns, i| try w.print("{s}{s}", .{ if (i == 0) "" else ";", dns });
        try w.writeAll(";\n");
    }
    if (network.search_domains.len != 0) {
        try w.writeAll("dns-search=");
        for (network.search_domains, 0..) |domain, i| try w.print("{s}{s}", .{ if (i == 0) "" else ";", domain });
        try w.writeAll(";\n");
    }
}

/// ifcfg-rh 单文件（Rocky/RHEL NetworkManager ifcfg 插件路径）。
pub const IfcfgFile = struct {
    filename: []const u8,
    content: []const u8,
};

/// 释放 `renderIfcfg` 返回的切片及其内容。
pub fn freeIfcfgFiles(allocator: std.mem.Allocator, files: []IfcfgFile) void {
    for (files) |file| {
        allocator.free(file.filename);
        allocator.free(file.content);
    }
    allocator.free(files);
}

/// 渲染 ifcfg-* 与 route-* 文件集合。
/// 先写 bond 成员（明确 MASTER/SLAVE），再写独立以太网与 VLAN。
pub fn renderIfcfg(allocator: std.mem.Allocator, network: model.TargetNetworkConfig) ![]IfcfgFile {
    var list: std.ArrayList(IfcfgFile) = .empty;
    errdefer {
        for (list.items) |file| {
            allocator.free(file.filename);
            allocator.free(file.content);
        }
        list.deinit(allocator);
    }

    // 先写 bond 成员，保证 MASTER/SLAVE 关系在文件集合中显式可见。
    for (network.bonds) |bond| {
        for (network.interfaces) |iface| {
            if (!memberOf(bond.members, iface.id)) continue;
            var content: std.Io.Writer.Allocating = .init(allocator);
            errdefer content.deinit();
            const w = &content.writer;
            try w.print("TYPE=Ethernet\nNAME={s}\nDEVICE={s}\nONBOOT=yes\nNM_CONTROLLED=yes\nHWADDR={s}\nBOOTPROTO=none\nMASTER={s}\nSLAVE=yes\nIPV6INIT=no\n", .{ iface.id, iface.id, iface.mac, bond.id });
            if (iface.mtu != 1500) try w.print("MTU={d}\n", .{iface.mtu});
            const body = try content.toOwnedSlice();
            errdefer allocator.free(body);
            const name = try std.fmt.allocPrint(allocator, "ifcfg-{s}", .{iface.id});
            errdefer allocator.free(name);
            try list.append(allocator, .{ .filename = name, .content = body });
        }
        var bond_content: std.Io.Writer.Allocating = .init(allocator);
        errdefer bond_content.deinit();
        const bw = &bond_content.writer;
        try bw.print("TYPE=Bond\nNAME={s}\nDEVICE={s}\nONBOOT=yes\nNM_CONTROLLED=yes\nBONDING_MASTER=yes\n", .{ bond.id, bond.id });
        try bw.print("BONDING_OPTS=\"mode={s} miimon={d}", .{ bondModeNm(bond.mode), bond.miimon_ms });
        if (bond.up_delay_ms != 0) try bw.print(" updelay={d}", .{bond.up_delay_ms});
        if (bond.down_delay_ms != 0) try bw.print(" downdelay={d}", .{bond.down_delay_ms});
        if (bond.primary_id) |primary| try bw.print(" primary={s}", .{primary});
        switch (bond.mode) {
            .active_backup => try bw.print(" primary_reselect={s}", .{@tagName(bond.primary_reselect)}),
            .ieee8023ad => {
                try bw.print(" lacp_rate={s} xmit_hash_policy={s} min_links={d}", .{ @tagName(bond.lacp_rate), xmitHashNm(bond.xmit_hash_policy), bond.min_links });
            },
        }
        try bw.writeAll("\"\n");
        if (bond.mtu) |mtu| try bw.print("MTU={d}\n", .{mtu});
        try writeIfcfgIpv4(bw, network, bond.id, bond.ipv4);
        const bbody = try bond_content.toOwnedSlice();
        errdefer allocator.free(bbody);
        const bname = try std.fmt.allocPrint(allocator, "ifcfg-{s}", .{bond.id});
        errdefer allocator.free(bname);
        try list.append(allocator, .{ .filename = bname, .content = bbody });
        try maybeAppendRouteFile(allocator, &list, network, bond.id);
    }

    for (network.interfaces) |iface| {
        if (isBondMember(network, iface.id)) continue;
        var content: std.Io.Writer.Allocating = .init(allocator);
        errdefer content.deinit();
        const w = &content.writer;
        try w.print("TYPE=Ethernet\nNAME={s}\nDEVICE={s}\nONBOOT=yes\nNM_CONTROLLED=yes\nHWADDR={s}\n", .{ iface.id, iface.id, iface.mac });
        if (iface.mtu != 1500) try w.print("MTU={d}\n", .{iface.mtu});
        try writeIfcfgIpv4(w, network, iface.id, iface.ipv4);
        const body = try content.toOwnedSlice();
        errdefer allocator.free(body);
        const name = try std.fmt.allocPrint(allocator, "ifcfg-{s}", .{iface.id});
        errdefer allocator.free(name);
        try list.append(allocator, .{ .filename = name, .content = body });
        try maybeAppendRouteFile(allocator, &list, network, iface.id);
    }

    for (network.vlans) |vlan| {
        var content: std.Io.Writer.Allocating = .init(allocator);
        errdefer content.deinit();
        const w = &content.writer;
        try w.print("TYPE=Vlan\nNAME={s}\nDEVICE={s}\nONBOOT=yes\nNM_CONTROLLED=yes\nVLAN=yes\nPHYSDEV={s}\nVLAN_ID={d}\n", .{ vlan.id, vlan.id, vlan.parent_id, vlan.vlan_id });
        if (vlan.mtu) |mtu| try w.print("MTU={d}\n", .{mtu});
        try writeIfcfgIpv4(w, network, vlan.id, vlan.ipv4);
        const body = try content.toOwnedSlice();
        errdefer allocator.free(body);
        const name = try std.fmt.allocPrint(allocator, "ifcfg-{s}", .{vlan.id});
        errdefer allocator.free(name);
        try list.append(allocator, .{ .filename = name, .content = body });
        try maybeAppendRouteFile(allocator, &list, network, vlan.id);
    }
    return try list.toOwnedSlice(allocator);
}

fn writeIfcfgIpv4(w: *std.Io.Writer, network: model.TargetNetworkConfig, link_id: []const u8, ipv4: model.TopologyIpv4) !void {
    _ = link_id;
    switch (ipv4.mode) {
        .none => try w.writeAll("BOOTPROTO=none\nIPV6INIT=no\n"),
        .dhcp => {
            try w.writeAll("BOOTPROTO=dhcp\nIPV6INIT=no\n");
            try writeIfcfgDns(w, network);
        },
        .static => {
            try w.print("BOOTPROTO=none\nIPADDR={s}\nPREFIX={d}\nIPV6INIT=no\n", .{ ipv4.address.?, ipv4.prefix_len.? });
            try writeIfcfgDns(w, network);
        },
    }
}

fn writeIfcfgDns(w: *std.Io.Writer, network: model.TargetNetworkConfig) !void {
    for (network.dns, 0..) |dns, i| try w.print("DNS{d}={s}\n", .{ i + 1, dns });
    if (network.search_domains.len != 0) {
        try w.writeAll("DOMAIN=\"");
        for (network.search_domains, 0..) |domain, i| try w.print("{s}{s}", .{ if (i == 0) "" else " ", domain });
        try w.writeAll("\"\n");
    }
}

fn maybeAppendRouteFile(allocator: std.mem.Allocator, list: *std.ArrayList(IfcfgFile), network: model.TargetNetworkConfig, link_id: []const u8) !void {
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    var any = false;
    for (network.routes) |route| {
        if (!routeOwnsLink(route, link_id)) continue;
        any = true;
        try content.writer.print("{s} via {s}", .{ route.destination, route.gateway });
        if (route.metric) |metric| try content.writer.print(" metric {d}", .{metric});
        try content.writer.writeByte('\n');
    }
    if (!any) return;
    const body = try content.toOwnedSlice();
    errdefer allocator.free(body);
    const name = try std.fmt.allocPrint(allocator, "route-{s}", .{link_id});
    errdefer allocator.free(name);
    try list.append(allocator, .{ .filename = name, .content = body });
}

/// 路由是否归属指定链路。校验器已要求 `interface_id`；缺省时对单 L3 owner 兼容回落。
fn routeOwnsLink(route: model.RouteConfig, link_id: []const u8) bool {
    if (route.interface_id) |id| return std.mem.eql(u8, id, link_id);
    // flat 兼容：无 owner 的 route 在校验器已拒绝多 L3 无 interface_id 后，
    // 可安全绑定到唯一 L3 链路。
    return true;
}

fn isDefaultDestination(destination: []const u8) bool {
    return std.mem.eql(u8, destination, "0.0.0.0/0") or std.mem.eql(u8, destination, "default");
}

fn memberOf(members: []const []const u8, id: []const u8) bool {
    for (members) |member| if (std.mem.eql(u8, member, id)) return true;
    return false;
}

fn isBondMember(network: model.TargetNetworkConfig, id: []const u8) bool {
    for (network.bonds) |bond| if (memberOf(bond.members, id)) return true;
    return false;
}

fn bondModeNetplan(mode: model.BondMode) []const u8 {
    return switch (mode) {
        .active_backup => "active-backup",
        .ieee8023ad => "802.3ad",
    };
}

fn bondModeNm(mode: model.BondMode) []const u8 {
    return switch (mode) {
        .active_backup => "active-backup",
        .ieee8023ad => "802.3ad",
    };
}

fn xmitHashNetplan(policy: model.XmitHashPolicy) []const u8 {
    return switch (policy) {
        .layer2 => "layer2",
        .layer2_3 => "layer2+3",
        .layer3_4 => "layer3+4",
    };
}

fn xmitHashNm(policy: model.XmitHashPolicy) []const u8 {
    return switch (policy) {
        .layer2 => "layer2",
        .layer2_3 => "layer2+3",
        .layer3_4 => "layer3+4",
    };
}

test "structured netplan renders bond vlan routes dns without silent drops" {
    const network: model.TargetNetworkConfig = .{
        .dns = &.{ "1.1.1.1", "8.8.8.8" },
        .search_domains = &.{"nodeforge.local"},
        .interfaces = &.{
            .{ .id = "eth0", .mac = "02:00:00:00:00:01", .mtu = 9000, .ipv4 = .{} },
            .{ .id = "eth1", .mac = "02:00:00:00:00:02", .ipv4 = .{} },
        },
        .bonds = &.{.{
            .id = "bond0",
            .mode = .active_backup,
            .members = &.{ "eth0", "eth1" },
            .mac_source_id = "eth0",
            .primary_id = "eth0",
            .ipv4 = .{},
        }},
        .vlans = &.{.{
            .id = "bond0.100",
            .parent_id = "bond0",
            .vlan_id = 100,
            .ipv4 = .{ .mode = .static, .address = "10.10.0.20", .prefix_len = 24, .default_route = true },
        }},
        .routes = &.{
            .{ .id = "def", .destination = "0.0.0.0/0", .gateway = "10.10.0.1", .metric = 100, .interface_id = "bond0.100" },
            .{ .id = "svc", .destination = "10.20.0.0/16", .gateway = "10.10.0.1", .interface_id = "bond0.100" },
        },
    };
    const yaml = try renderNetplan(std.testing.allocator, network);
    defer std.testing.allocator.free(yaml);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "ethernets:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "eth0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "macaddress: \"02:00:00:00:00:01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "mtu: 9000") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "bonds:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "mode: active-backup") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "primary: eth0") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "vlans:") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "id: 100") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "link: bond0") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "10.10.0.20/24") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "to: default") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "via: 10.10.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "to: 10.20.0.0/16") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "1.1.1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, yaml, "nodeforge.local") != null);
}

test "structured nm keyfiles and ifcfg retain bond members vlan and interface-bound routes" {
    const network: model.TargetNetworkConfig = .{
        .dns = &.{"9.9.9.9"},
        .interfaces = &.{
            .{ .id = "eno1", .mac = "02:00:00:00:00:11", .ipv4 = .{} },
            .{ .id = "eno2", .mac = "02:00:00:00:00:12", .ipv4 = .{} },
        },
        .bonds = &.{.{
            .id = "bond0",
            .mode = .ieee8023ad,
            .members = &.{ "eno1", "eno2" },
            .mac_source_id = "eno1",
            .lacp_rate = .fast,
            .xmit_hash_policy = .layer3_4,
            .min_links = 1,
            .ipv4 = .{ .mode = .dhcp },
        }},
        .vlans = &.{.{
            .id = "vlan200",
            .parent_id = "bond0",
            .vlan_id = 200,
            .ipv4 = .{ .mode = .static, .address = "192.0.2.50", .prefix_len = 24 },
        }},
        .routes = &.{
            .{ .id = "r1", .destination = "198.51.100.0/24", .gateway = "192.0.2.1", .interface_id = "vlan200" },
        },
    };
    const keys = try renderNmKeyfiles(std.testing.allocator, network);
    defer freeKeyfiles(std.testing.allocator, keys);
    var saw_bond = false;
    var saw_slave = false;
    var saw_vlan = false;
    var saw_route = false;
    for (keys) |file| {
        if (std.mem.eql(u8, file.filename, "bond0.nmconnection")) {
            saw_bond = true;
            try std.testing.expect(std.mem.indexOf(u8, file.content, "type=bond") != null);
            try std.testing.expect(std.mem.indexOf(u8, file.content, "mode=802.3ad") != null);
            try std.testing.expect(std.mem.indexOf(u8, file.content, "method=auto") != null);
        }
        if (std.mem.eql(u8, file.filename, "eno1-slave.nmconnection")) {
            saw_slave = true;
            try std.testing.expect(std.mem.indexOf(u8, file.content, "master=bond0") != null);
            try std.testing.expect(std.mem.indexOf(u8, file.content, "mac-address=02:00:00:00:00:11") != null);
        }
        if (std.mem.eql(u8, file.filename, "vlan200.nmconnection")) {
            saw_vlan = true;
            try std.testing.expect(std.mem.indexOf(u8, file.content, "type=vlan") != null);
            try std.testing.expect(std.mem.indexOf(u8, file.content, "id=200") != null);
            try std.testing.expect(std.mem.indexOf(u8, file.content, "parent=bond0") != null);
            try std.testing.expect(std.mem.indexOf(u8, file.content, "address1=192.0.2.50/24") != null);
            if (std.mem.indexOf(u8, file.content, "route1=198.51.100.0/24,192.0.2.1") != null) saw_route = true;
        }
    }
    try std.testing.expect(saw_bond and saw_slave and saw_vlan and saw_route);

    const ifcfgs = try renderIfcfg(std.testing.allocator, network);
    defer freeIfcfgFiles(std.testing.allocator, ifcfgs);
    var saw_ifcfg_bond = false;
    var saw_ifcfg_slave = false;
    var saw_ifcfg_vlan = false;
    var saw_ifcfg_route = false;
    for (ifcfgs) |file| {
        if (std.mem.eql(u8, file.filename, "ifcfg-bond0")) {
            saw_ifcfg_bond = true;
            try std.testing.expect(std.mem.indexOf(u8, file.content, "TYPE=Bond") != null);
            try std.testing.expect(std.mem.indexOf(u8, file.content, "mode=802.3ad") != null);
            try std.testing.expect(std.mem.indexOf(u8, file.content, "BOOTPROTO=dhcp") != null);
        }
        if (std.mem.eql(u8, file.filename, "ifcfg-eno1")) {
            saw_ifcfg_slave = true;
            try std.testing.expect(std.mem.indexOf(u8, file.content, "MASTER=bond0") != null);
            try std.testing.expect(std.mem.indexOf(u8, file.content, "SLAVE=yes") != null);
        }
        if (std.mem.eql(u8, file.filename, "ifcfg-vlan200")) {
            saw_ifcfg_vlan = true;
            try std.testing.expect(std.mem.indexOf(u8, file.content, "VLAN_ID=200") != null);
            try std.testing.expect(std.mem.indexOf(u8, file.content, "IPADDR=192.0.2.50") != null);
        }
        if (std.mem.eql(u8, file.filename, "route-vlan200")) {
            saw_ifcfg_route = true;
            try std.testing.expect(std.mem.indexOf(u8, file.content, "198.51.100.0/24 via 192.0.2.1") != null);
        }
    }
    try std.testing.expect(saw_ifcfg_bond and saw_ifcfg_slave and saw_ifcfg_vlan and saw_ifcfg_route);
}
