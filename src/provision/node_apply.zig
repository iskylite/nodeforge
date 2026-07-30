//! v0.2 无盘 AgentPlan node-apply 渲染器。
//!
//! 只消费服务端编译好的 typed projection，生成一次性、`set -eu` 的目标系统
//! finalizer。所有动态值均作 shell quoting 或逐字节 `printf %b` 编码；不读取
//! catalog/latest，也不接受自由命令。

const std = @import("std");
const dto = @import("../http/diskless_dto.zig");
const model = @import("../model.zig");

pub fn render(allocator: std.mem.Allocator, projection: dto.NodeApplyProjection) ![]u8 {
    return renderResolved(allocator, projection, null);
}

/// `resolved_interface` 是 agent 在目标机 `/sys/class/net` 中按 MAC 查到的实际名称。
/// 显式配置的 network.interface 优先；未配置时才使用运行期探测结果。
pub fn renderResolved(allocator: std.mem.Allocator, projection: dto.NodeApplyProjection, resolved_interface: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    // `switch_root` preserves the minimal initramfs environment, whose PATH is
    // not a target-OS contract. Pin the standard administrative paths before
    // invoking usermod/systemctl and the distro package manager.
    try w.writeAll("set -eu\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nexport PATH\n");

    try renderManagedRepositories(w, allocator, projection.software_transaction);
    try renderSoftware(w, projection.software_transaction);
    try emitFile(w, "/etc/hostname", projection.hostname orelse projection.node_id, 0o644);
    var free_hosts_content = false;
    const hosts_content = (if (projection.system.import_host_hosts) projection.system.hosts_content else null) orelse blk: {
        var hosts: std.Io.Writer.Allocating = .init(allocator);
        errdefer hosts.deinit();
        try hosts.writer.print("127.0.0.1 localhost localhost.localdomain\n127.0.1.1 {s}\n::1 localhost localhost.localdomain\n", .{projection.hostname orelse projection.node_id});
        free_hosts_content = true;
        break :blk try hosts.toOwnedSlice();
    };
    defer if (free_hosts_content) allocator.free(hosts_content);
    try emitFile(w, "/etc/hosts", hosts_content, 0o644);

    try renderNetwork(w, allocator, projection, resolved_interface);
    try renderUsers(w, allocator, projection.system);
    try renderLocalization(w, projection.system);
    try renderSsh(w, allocator, projection.system.ssh);
    try renderNtp(w, allocator, projection.system.connectivity);
    try renderSecurity(w, projection.system.security);
    return out.toOwnedSlice();
}

fn renderManagedRepositories(w: *std.Io.Writer, allocator: std.mem.Allocator, transaction: dto.SoftwareTransaction) !void {
    if (transaction.repository_urls.len == 0) return;
    const manager = transaction.manager orelse return error.PackageManagerMissing;
    switch (manager) {
        .dnf => {
            var content: std.Io.Writer.Allocating = .init(allocator);
            defer content.deinit();
            for (transaction.repository_urls, 0..) |url, index|
                try content.writer.print("[nodeforge-{d}]\nname=NodeForge managed repo {d}\nbaseurl={s}\nenabled=1\ngpgcheck=0\n\n", .{ index, index, url });
            try emitFile(w, "/etc/yum.repos.d/nodeforge.repo", content.written(), 0o644);
        },
        .apt => {
            // casper layer 自带 ports.ubuntu.com/cdrom 源；diskless 运行根只能使用
            // AgentPlan 固定的 NodeForge 受管仓库，不能在启动后重新暴露公网源。
            try w.writeAll("rm -f /etc/apt/sources.list\nrm -rf /etc/apt/sources.list.d\nmkdir -p /etc/apt/sources.list.d\n");
            var content: std.Io.Writer.Allocating = .init(allocator);
            defer content.deinit();
            for (transaction.repository_urls) |url|
                try content.writer.print("deb [trusted=yes] {s} ./\n", .{url});
            try emitFile(w, "/etc/apt/sources.list.d/nodeforge.list", content.written(), 0o644);
            // Ubuntu live-server installer layer 包含 snapd/LXD、multipathd 和
            // 依赖 /cdrom 的 casper-md5check。它们不在
            // v0.2 diskless 最小运行根能力内：snapd 在 overlay root 上会反复执行
            // install hook 并触发 systemd restart loop，multipathd 在无 multipath
            // 设备的节点上进入 failed，casper-md5check 则会因无 /cdrom 失败。
            // 切到真正 init 前离线 mask，避免无意义抖动和虚假 failed unit。
            try w.writeAll(
                \\mkdir -p /etc/systemd/system
                \\for unit in snapd.service snapd.socket snapd.seeded.service multipathd.service multipathd.socket casper-md5check.service; do
                \\  ln -sf /dev/null "/etc/systemd/system/$unit"
                \\done
                \\# live-server squashfs 在 vendor unit 目录（/lib，而不是 /etc）把
                \\# getty@tty1.service 直接链接到 /dev/null，并用 drop-in 把标准 getty
                \\# 改造成 Subiquity 启动器。只执行 `systemctl unmask` 无法移除这个
                \\# vendor mask；必须删除确切链接和 installer drop-in，再从标准模板
                \\# 重建 wants。否则 PID 1、SSH 和 NodeForge lifecycle 虽都已 running，
                \\# VMware 控制台仍停在最后一行启动日志，看起来像“无盘启动卡住”。
                \\rm -f /lib/systemd/system/getty@tty1.service
                \\rm -f /lib/systemd/system/getty@.service.d/autologin.conf
                \\rm -f /lib/systemd/system/serial-getty@.service.d/subiquity-serial.conf
                \\mkdir -p /etc/systemd/system/getty.target.wants
                \\ln -sf /lib/systemd/system/getty@.service /etc/systemd/system/getty.target.wants/getty@tty1.service
                \\# ttyAMA0 并非所有 aarch64 虚拟机都存在。只在字符设备真实存在时
                \\# 启用 serial-getty，避免 VMware 上产生无意义的 device dependency failure。
                \\if [ -c /dev/ttyAMA0 ]; then
                \\  ln -sf /lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service
                \\fi
                \\
            );
        },
    }
}

fn renderSoftware(w: *std.Io.Writer, transaction: dto.SoftwareTransaction) !void {
    if (transaction.install.len == 0 and transaction.remove.len == 0 and
        transaction.services_enable.len == 0 and transaction.services_disable.len == 0) return;
    const manager = transaction.manager orelse return error.PackageManagerMissing;
    for (transaction.remove) |package| if (protectedPackage(package)) return error.ProtectedPackageRemoval;
    switch (manager) {
        .dnf => {
            if (transaction.install.len != 0) {
                if (transaction.repository_urls.len == 0) return error.ManagedRepositoryMissing;
                try w.writeAll("dnf -y --disablerepo='*'");
                for (transaction.repository_urls, 0..) |url, index| {
                    try w.print(" --repofrompath=nodeforge-{d},", .{index});
                    try quote(w, url);
                    try w.print(" --enablerepo=nodeforge-{d}", .{index});
                }
                try w.writeAll(" install");
                for (transaction.install) |package| {
                    try w.writeByte(' ');
                    try quote(w, package);
                }
                try w.writeByte('\n');
            }
            if (transaction.remove.len != 0) {
                try w.writeAll("dnf -y remove");
                for (transaction.remove) |package| {
                    try w.writeByte(' ');
                    try quote(w, package);
                }
                try w.writeByte('\n');
            }
        },
        .apt => {
            if (transaction.install.len != 0) {
                if (transaction.repository_urls.len == 0) return error.ManagedRepositoryMissing;
                try w.writeAll(": > /tmp/nodeforge-node-apply.sources\n");
                for (transaction.repository_urls) |url| {
                    try w.writeAll("printf 'deb [trusted=yes] %s ./\\n' ");
                    try quote(w, url);
                    try w.writeAll(" >> /tmp/nodeforge-node-apply.sources\n");
                }
                try w.writeAll("apt-get -o Dir::Etc::sourcelist=/tmp/nodeforge-node-apply.sources -o Dir::Etc::sourceparts=- update\n");
                try w.writeAll("DEBIAN_FRONTEND=noninteractive apt-get -y -o Dir::Etc::sourcelist=/tmp/nodeforge-node-apply.sources -o Dir::Etc::sourceparts=- install");
                for (transaction.install) |package| {
                    try w.writeByte(' ');
                    try quote(w, package);
                }
                try w.writeByte('\n');
            }
            if (transaction.remove.len != 0) {
                try w.writeAll("DEBIAN_FRONTEND=noninteractive apt-get -y remove");
                for (transaction.remove) |package| {
                    try w.writeByte(' ');
                    try quote(w, package);
                }
                try w.writeByte('\n');
            }
        },
    }
    for (transaction.services_enable) |service| {
        try w.writeAll("systemctl enable ");
        try quote(w, service);
        try w.writeByte('\n');
    }
    for (transaction.services_disable) |service| {
        try w.writeAll("systemctl disable ");
        try quote(w, service);
        try w.writeByte('\n');
    }
}

fn protectedPackage(package: []const u8) bool {
    const protected = [_][]const u8{ "kernel", "systemd", "openssh-server", "NetworkManager", "network-manager", "nodeforge" };
    for (protected) |prefix| if (std.mem.startsWith(u8, package, prefix)) return true;
    return false;
}

fn renderNetwork(w: *std.Io.Writer, allocator: std.mem.Allocator, projection: dto.NodeApplyProjection, resolved_interface: ?[]const u8) !void {
    const net = projection.network;
    const interface = net.interface orelse resolved_interface orelse return error.NetworkInterfaceUnresolved;
    const mac = net.match_mac orelse projection.mac;
    const nm_path = try std.fmt.allocPrint(allocator, "/etc/NetworkManager/system-connections/{s}.nmconnection", .{interface});
    defer allocator.free(nm_path);
    const ifcfg_path = try std.fmt.allocPrint(allocator, "/etc/sysconfig/network-scripts/ifcfg-{s}", .{interface});
    defer allocator.free(ifcfg_path);
    const route_path = try std.fmt.allocPrint(allocator, "/etc/sysconfig/network-scripts/route-{s}", .{interface});
    defer allocator.free(route_path);

    var nm: std.Io.Writer.Allocating = .init(allocator);
    defer nm.deinit();
    try nm.writer.print("[connection]\nid={s}\ntype=ethernet\nautoconnect=true\ninterface-name={s}\n[ethernet]\nmac-address={s}\n", .{ interface, interface, mac });
    var ifcfg: std.Io.Writer.Allocating = .init(allocator);
    defer ifcfg.deinit();
    try ifcfg.writer.print("TYPE=Ethernet\nNAME={s}\nDEVICE={s}\nONBOOT=yes\nNM_CONTROLLED=yes\nHWADDR={s}\n", .{ interface, interface, mac });
    var route_file: std.Io.Writer.Allocating = .init(allocator);
    defer route_file.deinit();
    var netplan: std.Io.Writer.Allocating = .init(allocator);
    defer netplan.deinit();
    try netplan.writer.print("network:\n  version: 2\n  ethernets:\n    {s}:\n      match:\n        macaddress: {s}\n      set-name: {s}\n", .{ interface, mac, interface });
    var nmcli: std.Io.Writer.Allocating = .init(allocator);
    defer nmcli.deinit();
    try nmcli.writer.writeAll("nmcli --offline connection add type ethernet con-name ");
    try quote(&nmcli.writer, interface);
    try nmcli.writer.writeAll(" ifname ");
    try quote(&nmcli.writer, interface);
    try nmcli.writer.writeAll(" 802-3-ethernet.mac-address ");
    try quote(&nmcli.writer, mac);

    if (net.mode == .dhcp) {
        try nm.writer.writeAll("[ipv4]\nmethod=auto\n[ipv6]\nmethod=ignore\n");
        try ifcfg.writer.writeAll("BOOTPROTO=dhcp\nIPV6INIT=no\n");
        try netplan.writer.writeAll("      dhcp4: true\n      dhcp6: false\n");
        try nmcli.writer.writeAll(" ipv4.method auto ipv6.method disabled");
    } else {
        const address = net.address orelse return error.StaticAddressMissing;
        const prefix = net.prefix_len orelse return error.StaticPrefixMissing;
        try nm.writer.print("[ipv4]\nmethod=manual\naddress1={s}/{d}", .{ address, prefix });
        if (net.gateway) |gateway| try nm.writer.print(",{s}", .{gateway});
        try nm.writer.writeByte('\n');
        try ifcfg.writer.print("BOOTPROTO=none\nIPADDR={s}\nPREFIX={d}\n", .{ address, prefix });
        if (net.gateway) |gateway| try ifcfg.writer.print("GATEWAY={s}\n", .{gateway});
        if (net.dns.len != 0) {
            try nm.writer.writeAll("dns=");
            for (net.dns, 0..) |server, i| {
                try nm.writer.print("{s}{s}", .{ if (i == 0) "" else ";", server });
                try ifcfg.writer.print("DNS{d}={s}\n", .{ i + 1, server });
            }
            try nm.writer.writeAll(";\n");
        }
        if (net.search_domains.len != 0) {
            try ifcfg.writer.writeAll("DOMAIN=\"");
            for (net.search_domains, 0..) |domain, i| try ifcfg.writer.print("{s}{s}", .{ if (i == 0) "" else " ", domain });
            try ifcfg.writer.writeAll("\"\n");
        }
        for (net.routes, 0..) |route, i| {
            try nm.writer.print("route{d}={s},{s}", .{ i + 1, route.destination, route.gateway });
            if (route.metric) |metric| try nm.writer.print(",{d}", .{metric});
            try nm.writer.writeByte('\n');
            try route_file.writer.print("{s} via {s}", .{ route.destination, route.gateway });
            if (route.metric) |metric| try route_file.writer.print(" metric {d}", .{metric});
            try route_file.writer.writeByte('\n');
        }
        try nm.writer.writeAll("[ipv6]\nmethod=ignore\n");
        try ifcfg.writer.writeAll("IPV6INIT=no\n");
        try nmcli.writer.writeAll(" ipv4.method manual ipv4.addresses ");
        const cidr = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ address, prefix });
        defer allocator.free(cidr);
        try quote(&nmcli.writer, cidr);
        if (net.gateway) |gateway| {
            try nmcli.writer.writeAll(" ipv4.gateway ");
            try quote(&nmcli.writer, gateway);
        }
        for (net.dns) |server| {
            try nmcli.writer.writeAll(" +ipv4.dns ");
            try quote(&nmcli.writer, server);
        }
        for (net.search_domains) |domain| {
            try nmcli.writer.writeAll(" +ipv4.dns-search ");
            try quote(&nmcli.writer, domain);
        }
        for (net.routes) |route| {
            const value = if (route.metric) |metric|
                try std.fmt.allocPrint(allocator, "{s} {s} {d}", .{ route.destination, route.gateway, metric })
            else
                try std.fmt.allocPrint(allocator, "{s} {s}", .{ route.destination, route.gateway });
            defer allocator.free(value);
            try nmcli.writer.writeAll(" +ipv4.routes ");
            try quote(&nmcli.writer, value);
        }
        try nmcli.writer.writeAll(" ipv6.method disabled");
        try netplan.writer.print("      addresses:\n        - {s}/{d}\n", .{ address, prefix });
        var wrote_routes_header = false;
        if (net.gateway) |gateway| {
            try netplan.writer.print("      routes:\n        - to: default\n          via: {s}\n", .{gateway});
            wrote_routes_header = true;
        }
        for (net.routes) |route| {
            if (!wrote_routes_header) {
                try netplan.writer.writeAll("      routes:\n");
                wrote_routes_header = true;
            }
            try netplan.writer.print("        - to: {s}\n          via: {s}\n", .{ route.destination, route.gateway });
            if (route.metric) |metric| try netplan.writer.print("          metric: {d}\n", .{metric});
        }
        if (net.dns.len != 0 or net.search_domains.len != 0) {
            try netplan.writer.writeAll("      nameservers:\n");
            if (net.dns.len != 0) {
                try netplan.writer.writeAll("        addresses: [");
                for (net.dns, 0..) |server, i| try netplan.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", server });
                try netplan.writer.writeAll("]\n");
            }
            if (net.search_domains.len != 0) {
                try netplan.writer.writeAll("        search: [");
                for (net.search_domains, 0..) |domain, i| try netplan.writer.print("{s}{s}", .{ if (i == 0) "" else ", ", domain });
                try netplan.writer.writeAll("]\n");
            }
        }
    }

    // 统一 adapter 以目标 rootfs 的实际能力选择后端。现代 NetworkManager
    // 必须实际执行目标 nmcli --offline 生成 keyfile；`--help` 返回成功不证明
    // 当前版本能离线创建连接。ifcfg/keyfile fallback 也必须由目标
    // NetworkManager 配置明确声明 plugin，不能只看目录是否存在。
    try w.writeAll("rm -f /etc/NetworkManager/system-connections/nodeforge.nmconnection /etc/netplan/60-nodeforge.yaml\n");
    try w.writeAll("if [ -d /etc/netplan ] && command -v netplan >/dev/null 2>&1; then ");
    try emitFileInline(w, "/etc/netplan/60-nodeforge.yaml", netplan.written(), 0o600);
    try w.writeAll("; elif command -v nmcli >/dev/null 2>&1; then install -d -m 0700 /etc/NetworkManager/system-connections; if ");
    try w.writeAll(nmcli.written());
    try w.writeAll(" > ");
    try quote(w, nm_path);
    try w.writeAll(".tmp; then chmod 0600 ");
    try quote(w, nm_path);
    try w.writeAll(".tmp; mv -f ");
    try quote(w, nm_path);
    try w.writeAll(".tmp ");
    try quote(w, nm_path);
    try w.writeAll("; else rm -f ");
    try quote(w, nm_path);
    try w.writeAll(".tmp; echo 'nodeforge: target nmcli lacks usable offline keyfile generation' >&2; exit 1; fi");
    try w.writeAll("; elif command -v NetworkManager >/dev/null 2>&1 && NetworkManager --print-config 2>/dev/null | grep -Eq 'plugins=.*ifcfg-rh'; then ");
    try emitFileInline(w, ifcfg_path, ifcfg.written(), 0o600);
    if (route_file.written().len != 0) {
        try w.writeAll("; ");
        try emitFileInline(w, route_path, route_file.written(), 0o600);
    } else {
        try w.writeAll("; rm -f ");
        try quote(w, route_path);
    }
    try w.writeAll("; elif command -v NetworkManager >/dev/null 2>&1 && NetworkManager --print-config 2>/dev/null | grep -Eq 'plugins=.*keyfile'; then install -d -m 0700 /etc/NetworkManager/system-connections; ");
    try emitFileInline(w, nm_path, nm.written(), 0o600);
    try w.writeAll("; else echo 'nodeforge: no supported target network adapter' >&2; exit 1; fi\n");
}

fn renderUsers(w: *std.Io.Writer, allocator: std.mem.Allocator, system: dto.AgentSystem) !void {
    try setPassword(w, "root", system.ssh.root_password_hash, false);
    try authorizedKeys(w, allocator, "root", "/root", system.ssh.root_authorized_keys);
    for (system.users) |user| {
        try w.writeAll("if ! /usr/bin/getent passwd ");
        try quote(w, user.name);
        try w.writeAll(" >/dev/null; then /usr/sbin/useradd -m");
        if (user.uid) |uid| try w.print(" -u {d}", .{uid});
        if (user.shell) |shell| {
            try w.writeAll(" -s ");
            try quote(w, shell);
        }
        try w.writeByte(' ');
        try quote(w, user.name);
        try w.writeAll("; fi\n");
        if (user.groups.len != 0) {
            var groups: std.Io.Writer.Allocating = .init(allocator);
            defer groups.deinit();
            for (user.groups, 0..) |group, i| try groups.writer.print("{s}{s}", .{ if (i == 0) "" else ",", group });
            try w.writeAll("/usr/sbin/usermod -a -G ");
            try quote(w, groups.written());
            try w.writeByte(' ');
            try quote(w, user.name);
            try w.writeByte('\n');
        }
        // sudo 通过 portable sudoers.d drop-in 授予，替代硬编码 wheel/sudo 组成员。
        // 后者在 Ubuntu（无 wheel 组）上 usermod -a -G wheel 会失败并因 set -e 中断
        // node-apply；drop-in 不依赖发行版默认 %wheel/%sudo 条目，跨发行版一致生效。
        if (user.sudo) {
            var sudoers: std.Io.Writer.Allocating = .init(allocator);
            defer sudoers.deinit();
            try sudoers.writer.print("{s} ALL=(ALL) ALL\n", .{user.name});
            const s_path = try std.fmt.allocPrint(allocator, "/etc/sudoers.d/nodeforge-{s}", .{user.name});
            defer allocator.free(s_path);
            try emitFile(w, s_path, sudoers.written(), 0o440);
        }
        try setPassword(w, user.name, user.password_hash, user.locked);
        const home = try std.fmt.allocPrint(allocator, "/home/{s}", .{user.name});
        defer allocator.free(home);
        try authorizedKeys(w, allocator, user.name, home, user.ssh_authorized_keys);
    }
}

fn setPassword(w: *std.Io.Writer, account: []const u8, hash: ?[]const u8, locked: bool) !void {
    if (hash) |value| {
        try w.writeAll("/usr/sbin/usermod -p ");
        try quote(w, value);
        try w.writeByte(' ');
        try quote(w, account);
        try w.writeByte('\n');
    }
    if (locked or hash == null) {
        try w.writeAll("/usr/sbin/usermod -L ");
        try quote(w, account);
        try w.writeByte('\n');
    } else {
        try w.writeAll("/usr/sbin/usermod -U ");
        try quote(w, account);
        try w.writeByte('\n');
    }
}

fn authorizedKeys(w: *std.Io.Writer, allocator: std.mem.Allocator, account: []const u8, home: []const u8, keys: []const []const u8) !void {
    const directory = try std.fmt.allocPrint(allocator, "{s}/.ssh", .{home});
    defer allocator.free(directory);
    const path = try std.fmt.allocPrint(allocator, "{s}/authorized_keys", .{directory});
    defer allocator.free(path);
    try w.writeAll("install -d -m 0700 -o ");
    try quote(w, account);
    try w.writeAll(" -g ");
    try quote(w, account);
    try w.writeByte(' ');
    try quote(w, directory);
    try w.writeByte('\n');
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    for (keys) |key| try content.writer.print("{s}\n", .{key});
    try emitFile(w, path, content.written(), 0o600);
    try w.writeAll("chown ");
    try quote(w, account);
    try w.writeByte(':');
    try quote(w, account);
    try w.writeByte(' ');
    try quote(w, path);
    try w.writeByte('\n');
}

fn renderLocalization(w: *std.Io.Writer, system: dto.AgentSystem) !void {
    var locale: [256]u8 = undefined;
    const locale_text = try std.fmt.bufPrint(&locale, "LANG={s}\n", .{system.localization.locale});
    try emitFile(w, "/etc/locale.conf", locale_text, 0o644);
    var keyboard: [256]u8 = undefined;
    const keyboard_text = try std.fmt.bufPrint(&keyboard, "KEYMAP={s}\n", .{system.localization.keyboard});
    try emitFile(w, "/etc/vconsole.conf", keyboard_text, 0o644);
    try w.writeAll("ln -snf ");
    var zone: [512]u8 = undefined;
    const zone_path = try std.fmt.bufPrint(&zone, "/usr/share/zoneinfo/{s}", .{system.localization.timezone});
    try quote(w, zone_path);
    try w.writeAll(" /etc/localtime\n");
}

fn renderSsh(w: *std.Io.Writer, allocator: std.mem.Allocator, ssh: dto.AgentSsh) !void {
    var content: std.Io.Writer.Allocating = .init(allocator);
    defer content.deinit();
    try content.writer.print("PermitRootLogin {s}\nPasswordAuthentication {s}\nPubkeyAuthentication yes\n", .{ @tagName(ssh.root_login), if (ssh.password_authentication) "yes" else "no" });
    // OpenSSH keeps the first value it reads for most scalar options.  Use an
    // early drop-in so the effective NodeForge policy wins over the rootfs
    // safety default and vendor drop-ins such as 50-redhat.conf.
    try emitFile(w, "/etc/ssh/sshd_config.d/00-nodeforge.conf", content.written(), 0o600);
    // rootfs 是共享只读 squashfs lower，不包含 per-node SSH host key。
    // 切根后在 volatile overlay 上生成 host key（ssh-keygen -A）。
    // 已存在时 ssh-keygen -A 跳过，幂等。
    try w.writeAll("ssh-keygen -A 2>/dev/null || true\n");
    // sshd/ssh 单元可能尚未安装（由 software transaction 或 first-boot 安装，或在最小 rootfs 中缺失）。
    // 与 disable 分支一致地 best-effort：启用失败不阻断 node-apply（readiness 阶段已对正式部署校验 sshd 存在）。
    if (ssh.enabled) {
        try w.writeAll("systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true\n");
        // diskless node-apply runs after the rootfs has started systemd.  Merely
        // enabling the unit does not make the running daemon reread the newly
        // written policy or generated host keys.
        try w.writeAll("systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true\n");
    } else {
        try w.writeAll("systemctl disable --now sshd 2>/dev/null || systemctl disable --now ssh 2>/dev/null || true\n");
    }
}

fn renderNtp(w: *std.Io.Writer, allocator: std.mem.Allocator, connectivity: model.ConnectivityPolicy) !void {
    if (!connectivity.time_sync) {
        try w.writeAll("systemctl disable chronyd 2>/dev/null || true\nsystemctl disable systemd-timesyncd 2>/dev/null || true\n");
        return;
    }
    var chrony: std.Io.Writer.Allocating = .init(allocator);
    defer chrony.deinit();
    for (connectivity.ntp_servers) |server| try chrony.writer.print("server {s} iburst\n", .{server});
    try emitFile(w, "/etc/chrony.conf", chrony.written(), 0o644);
    // NTP 单元可能尚未安装；与 disable 分支一致地 best-effort 启用。
    try w.writeAll("systemctl enable chronyd 2>/dev/null || systemctl enable systemd-timesyncd 2>/dev/null || true\n");
}

fn renderSecurity(w: *std.Io.Writer, security: model.TargetSecurityConfig) !void {
    try w.writeAll(if (security.firewall == .enabled) "systemctl enable firewalld 2>/dev/null || true\n" else "systemctl disable firewalld 2>/dev/null || true\n");
    try w.print("if [ -f /etc/selinux/config ]; then sed -i 's/^SELINUX=.*/SELINUX={s}/' /etc/selinux/config; fi\n", .{@tagName(security.selinux)});
    try w.writeAll(switch (security.apparmor) {
        .disabled => "systemctl disable apparmor 2>/dev/null || true\n",
        .complain => "systemctl enable apparmor 2>/dev/null || true\n",
        .enforce => "systemctl enable apparmor 2>/dev/null || true\n",
    });
}

fn emitFile(w: *std.Io.Writer, path: []const u8, content: []const u8, mode: u16) !void {
    try w.writeAll("install -d -m 0755 \"$(dirname -- ");
    try quote(w, path);
    try w.writeAll(")\"\n");
    try emitFileInline(w, path, content, mode);
    try w.writeByte('\n');
}

fn emitFileInline(w: *std.Io.Writer, path: []const u8, content: []const u8, mode: u16) !void {
    try w.writeAll("printf '%b' '");
    try encodeOctal(w, content);
    try w.writeAll("' > ");
    try quote(w, path);
    try w.print(" && chmod {o:0>4} ", .{mode});
    try quote(w, path);
}

/// 把字节以 POSIX `printf %b` 八进制转义（`\NNN`，固定 3 位）逐字节编码，
/// 避免 shell 展开/注入。任何读取 1-3 位八进制转义的 printf %b 实现都能逐字节还原。
fn encodeOctal(w: *std.Io.Writer, content: []const u8) !void {
    for (content) |byte| try w.print("\\{o:0>3}", .{byte});
}

fn quote(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('\'');
    for (value) |byte| if (byte == '\'') try w.writeAll("'\\''") else try w.writeByte(byte);
    try w.writeByte('\'');
}

test "renderer contains no plaintext password and writes effective identity" {
    const projection: dto.NodeApplyProjection = .{
        .node_id = "n1",
        .mac = "02:00:00:00:00:01",
        .arch = .aarch64,
        .hostname = "worker-1",
        .network = .{ .interface = "eth0" },
        .system = .{
            .localization = .{},
            .connectivity = .{},
            .ssh = .{ .enabled = true, .password_authentication = false, .root_login = .@"prohibit-password", .root_password_hash = "$6$salt$root" },
            .security = .{},
            .users = &.{.{ .name = "ops", .password_hash = "$6$salt$user", .sudo = true, .ssh_authorized_keys = &.{"ssh-ed25519 AAAA test"} }},
        },
        .software = .{},
    };
    const script = try render(std.testing.allocator, projection);
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "/etc/hostname") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "$6$salt$user") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "authorized_keys") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/etc/ssh/sshd_config.d/00-nodeforge.conf") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/etc/ssh/sshd_config.d/60-nodeforge.conf") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "systemctl restart sshd") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "nodeforge-diskless") == null);
}

test "software transaction precedes target finalizer and protects boot closure" {
    var projection: dto.NodeApplyProjection = .{
        .node_id = "n1",
        .mac = "02:00:00:00:00:01",
        .arch = .aarch64,
        .hostname = null,
        .network = .{ .interface = "eth0" },
        .system = .{
            .localization = .{},
            .connectivity = .{},
            .ssh = .{ .enabled = true, .password_authentication = false, .root_login = .no },
            .security = .{},
            .users = &.{},
        },
        .software = .{},
        .software_transaction = .{
            .manager = .dnf,
            .repository_urls = &.{"http://192.0.2.1/repo"},
            .install = &.{"jq"},
            .remove = &.{"telnet"},
        },
    };
    const script = try render(std.testing.allocator, projection);
    defer std.testing.allocator.free(script);
    const install_at = std.mem.indexOf(u8, script, "dnf -y --disablerepo").?;
    const hostname_at = std.mem.indexOf(u8, script, "/etc/hostname").?;
    try std.testing.expect(install_at < hostname_at);
    try std.testing.expect(std.mem.indexOf(u8, script, "/etc/yum.repos.d/nodeforge.repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "baseurl=http://192.0.2.1/repo") == null);

    projection.software_transaction.remove = &.{"kernel-core"};
    try std.testing.expectError(error.ProtectedPackageRemoval, render(std.testing.allocator, projection));
}

test "managed repository persists without package delta and resolved interface is emitted" {
    const projection: dto.NodeApplyProjection = .{
        .node_id = "n1",
        .mac = "02:00:00:00:00:01",
        .arch = .aarch64,
        .hostname = null,
        .network = .{},
        .system = .{
            .localization = .{},
            .connectivity = .{},
            .ssh = .{ .enabled = false, .password_authentication = false, .root_login = .no },
            .security = .{},
            .users = &.{},
        },
        .software = .{},
        .software_transaction = .{
            .manager = .dnf,
            .repository_urls = &.{"http://192.0.2.1/repo"},
        },
    };
    const script = try renderResolved(std.testing.allocator, projection, "enp2s0");
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "/etc/yum.repos.d/nodeforge.repo") != null);
    var encoded_interface: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded_interface.deinit();
    try encodeOctal(&encoded_interface.writer, "interface-name=enp2s0");
    try std.testing.expect(std.mem.indexOf(u8, script, encoded_interface.written()) != null);
    var encoded_netplan: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded_netplan.deinit();
    try encodeOctal(&encoded_netplan.writer, "set-name: enp2s0");
    try std.testing.expect(std.mem.indexOf(u8, script, encoded_netplan.written()) != null);
}

test "apt runtime keeps only managed sources and masks installer-only services" {
    const projection: dto.NodeApplyProjection = .{
        .node_id = "n1",
        .mac = "02:00:00:00:00:01",
        .arch = .aarch64,
        .hostname = null,
        .network = .{},
        .system = .{
            .localization = .{},
            .connectivity = .{},
            .ssh = .{ .enabled = true, .password_authentication = true, .root_login = .yes },
            .security = .{},
            .users = &.{},
        },
        .software = .{},
        .software_transaction = .{
            .manager = .apt,
            .repository_urls = &.{"http://192.0.2.1/ubuntu"},
        },
    };
    const script = try renderResolved(std.testing.allocator, projection, "enp2s0");
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.indexOf(u8, script, "rm -f /etc/apt/sources.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "rm -rf /etc/apt/sources.list.d") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/etc/apt/sources.list.d/nodeforge.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "ln -sf /dev/null") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "snapd.service snapd.socket snapd.seeded.service multipathd.service multipathd.socket casper-md5check.service") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "rm -f /lib/systemd/system/getty@tty1.service") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "getty.target.wants/getty@tty1.service") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "getty.target.wants/serial-getty@ttyAMA0.service") != null);
}

test "encodeOctal round-trips arbitrary bytes through 3-digit octal" {
    // 覆盖易错字节：控制字符、引号、反斜杠、八进制边界、高位字节。
    const tricky = [_]u8{ 0, 1, 7, 8, 9, 10, 12, 13, 26, 39, 47, 48, 55, 56, 65, 92, 127, 200, 255 };
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try encodeOctal(&encoded.writer, &tricky);
    // 每个转义必须是 `\` + 恰好 3 位八进制；用符合 POSIX 的解码器逐字节还原。
    var decoded = std.ArrayList(u8).empty;
    defer decoded.deinit(std.testing.allocator);
    const esc = encoded.written();
    try std.testing.expectEqual(@as(usize, 0), esc.len % 4);
    var i: usize = 0;
    while (i < esc.len) {
        try std.testing.expectEqual(@as(u8, '\\'), esc[i]);
        i += 1;
        var value: u16 = 0;
        var n: usize = 0;
        while (n < 3) : (n += 1) {
            const c = esc[i];
            try std.testing.expect(c >= '0' and c <= '7');
            value = value * 8 + (c - '0');
            i += 1;
        }
        try decoded.append(std.testing.allocator, @intCast(value));
    }
    try std.testing.expectEqualSlices(u8, &tricky, decoded.items);
}

test "static network projection contains capability-selected netplan keyfile and ifcfg adapters" {
    const projection: dto.NodeApplyProjection = .{
        .node_id = "n1",
        .mac = "02:00:00:00:00:01",
        .arch = .aarch64,
        .hostname = null,
        .network = .{
            .mode = .static,
            .interface = "enp2s0",
            .match_mac = "02:00:00:00:00:01",
            .address = "192.0.2.10",
            .prefix_len = 24,
            .gateway = "192.0.2.1",
            .dns = &.{ "8.8.8.8", "1.1.1.1" },
        },
        .system = .{
            .localization = .{},
            .connectivity = .{},
            .ssh = .{ .enabled = false, .password_authentication = false, .root_login = .no },
            .security = .{},
            .users = &.{},
        },
        .software = .{},
    };
    const script = try render(std.testing.allocator, projection);
    defer std.testing.allocator.free(script);
    // 内容本身以八进制编码；这里验证三个 adapter 的路径和能力选择 guard。
    try std.testing.expect(std.mem.indexOf(u8, script, "/etc/netplan/60-nodeforge.yaml") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/etc/NetworkManager/system-connections/enp2s0.nmconnection") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "/etc/sysconfig/network-scripts/ifcfg-enp2s0") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "command -v netplan") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "nmcli --offline connection add") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "NetworkManager --print-config") != null);
}

test "sudo granted via portable sudoers drop-in; service enable best-effort" {
    // 跨发行版可移植性：Ubuntu 无 wheel 组，硬编码 wheel 会让 usermod -a -G wheel 失败
    // 并因 set -e 中断 node-apply。改用 /etc/sudoers.d drop-in 授予 sudo；同时 ssh/ntp
    // 的 enable 在单元未安装时 best-effort（|| true），与 disable 分支对称。
    const projection: dto.NodeApplyProjection = .{
        .node_id = "n1",
        .mac = "02:00:00:00:00:01",
        .arch = .aarch64,
        .hostname = null,
        .network = .{ .interface = "eth0" },
        .system = .{
            .localization = .{},
            .connectivity = .{ .time_sync = true, .ntp_servers = &.{"ntp.example.org"} },
            .ssh = .{ .enabled = true, .password_authentication = false, .root_login = .no },
            .security = .{},
            .users = &.{.{ .name = "admin", .sudo = true }},
        },
        .software = .{},
    };
    const script = try render(std.testing.allocator, projection);
    defer std.testing.allocator.free(script);
    // sudo：drop-in 路径与 0440 模式存在；不再硬编码 wheel 组成员。
    // 文件内容字节经 encodeOctal 八进制转义，逐字节保真由 encodeOctal 往返测试覆盖。
    try std.testing.expect(std.mem.indexOf(u8, script, "/etc/sudoers.d/nodeforge-admin") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "chmod 0440 '/etc/sudoers.d/nodeforge-admin'") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "wheel") == null);
    // ssh enable best-effort（与 disable 分支对称）。
    try std.testing.expect(std.mem.indexOf(u8, script, "systemctl enable sshd 2>/dev/null || systemctl enable ssh 2>/dev/null || true") != null);
    // ntp enable best-effort（time_sync=true 触发 enable 分支）。
    try std.testing.expect(std.mem.indexOf(u8, script, "systemctl enable chronyd 2>/dev/null || systemctl enable systemd-timesyncd 2>/dev/null || true") != null);
}
