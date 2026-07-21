//! M4 Kickstart 安装器适配器（RHEL 系：Rocky/CentOS/Alma/RHEL）。
//!
//! 本模块将 NodeForge 的 `InstallConfig` 渲染为 Anaconda 可读取的 Kickstart 文件。
//! Kickstart 是 RHEL 系发行版的无人值守安装配置格式，由 `%packages`、`%post` 等
//! 段组成。
//!
//! 渲染规则要点：
//! - `url --url=<repo_url>`：指定安装源为已发布的 dnf 仓库 URL
//! - `zerombr` + `clearpart --all`：清除磁盘分区表和所有分区
//! - 分区：无显式分区时使用安全默认布局（ESP/swap/root），有则按配置渲染 `part` 指令
//! - `%packages`：安装最小化环境加额外包
//! - `%post --erroronfail`：安装后执行 bundle 步骤和事件上报 curl
//! - `reboot`：安装完成后自动重启
//!
//! 安全说明：
//! - `boot_disk` 去掉 `/dev/` 前缀后用于 `clearpart --drives`，防止注入设备路径
//! - 密码以明文传递给 Anaconda（`--iscrypted` 未设置），由 Anaconda 自行哈希存储
//! - `%post` 中的 curl 命令携带 capability token 和 session id，用于事件关联

const std = @import("std");
const model = @import("../../model.zig");
const render = @import("../render.zig");
const runner = @import("../../provision/runner.zig");
const password_hash = @import("../password_hash.zig");

/// M4.1 Kickstart 渲染器，从共享的 TargetSystemConfig 生成。
pub fn renderAnswerM41(allocator: std.mem.Allocator, node: *const model.NodeConfig, install: model.InstallConfig, system: model.TargetSystemConfig, bootstrap_key: []const u8, repo_url: []const u8, bundle: ?*const model.ProvisioningBundle, facts_url: []const u8, event_url: []const u8, log_url: []const u8, session: []const u8, token: []const u8, password_scope: []const u8, kernel_args: ?[]const u8) ![]u8 {
    const network = node.network;
    const software: model.SoftwareSelection = .{ .packages = .{ .include = system.packages } };
    return renderEffective(allocator, node, install, system, network, software, bootstrap_key, repo_url, bundle, facts_url, event_url, log_url, session, token, password_scope, kernel_args);
}

pub fn renderEffective(allocator: std.mem.Allocator, node: *const model.NodeConfig, install: model.InstallConfig, system: model.TargetSystemConfig, network: model.TargetNetworkConfig, software: model.SoftwareSelection, bootstrap_key: []const u8, repo_url: []const u8, bundle: ?*const model.ProvisioningBundle, facts_url: []const u8, event_url: []const u8, log_url: []const u8, session: []const u8, token: []const u8, password_scope: []const u8, kernel_args: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("url --url={s}", .{repo_url});
    if (install.proxy.url) |proxy| try w.print(" --proxy={s}", .{proxy});
    try w.print("\nlang {s}\nkeyboard {s}\ntimezone {s} --utc\n", .{ system.localization.locale, system.localization.keyboard, system.localization.timezone });
    if (system.connectivity.time_sync) for (system.connectivity.ntp_servers) |server| try w.print("timesource --ntp-server={s}\n", .{server});
    if (network.mode == .dhcp) {
        // `--activate` 仅配置安装器环境。同时将连接持久化为开机
        // 启动的 profile，否则安装成功的系统可能在到达登录提示时
        // 没有任何路由可供 bootstrap SSH 使用。
        try w.print("network --bootproto=dhcp --device=link --hostname={s} --activate --onboot=on\n", .{render.hostname(node)});
    } else {
        const device = network.interface orelse network.match_mac orelse node.mac;
        // Anaconda/Kickstart 接受点分 IPv4 `--netmask`；与 Netplan 不同，
        // 它不接受 CIDR `--prefix` 参数（已通过 Rocky 8 和 Rocky 9
        // ksvalidator fixture 验证）。
        var netmask_buf: [15]u8 = undefined;
        const netmask = ipv4Netmask(&netmask_buf, network.prefix_len.?);
        try w.print("network --bootproto=static --device={s} --ip={s} --netmask={s} --hostname={s} --activate --onboot=on", .{ device, network.address.?, netmask, render.hostname(node) });
        if (network.gateway) |gateway| try w.print(" --gateway={s}", .{gateway});
        if (network.dns.len != 0) {
            try w.writeAll(" --nameserver=");
            for (network.dns, 0..) |dns, i| {
                if (i != 0) try w.writeByte(',');
                try w.writeAll(dns);
            }
        }
        if (network.search_domains.len != 0) {
            try w.writeAll(" --ipv4-dns-search=");
            for (network.search_domains, 0..) |domain, i| {
                if (i != 0) try w.writeByte(',');
                try w.writeAll(domain);
            }
        }
        try w.writeByte('\n');
    }
    try w.writeAll("zerombr\nclearpart --all --initlabel --drives=");
    for (install.storage.members, 0..) |disk, index| {
        if (index != 0) try w.writeByte(',');
        try w.writeAll(disk[5..]);
    }
    try w.writeByte('\n');
    if (install.storage.partitions.len == 0) {
        try renderAutomaticStorage(w, install.storage);
    } else try renderCustomStorage(w, install.storage);
    if (install.bootloader.install) {
        if (kernel_args) |args|
            try w.print("bootloader --boot-drive={s} --append=\"{s}\"\n", .{ install.storage.boot_disk[5..], args })
        else
            try w.print("bootloader --boot-drive={s}\n", .{install.storage.boot_disk[5..]});
    }
    if (system.ssh.root_password) |plain| {
        const salt = password_hash.sessionSalt(password_scope, "root");
        const hash = try password_hash.sha512Crypt(allocator, plain, &salt);
        defer allocator.free(hash);
        try w.print("rootpw --iscrypted {s}\n", .{hash});
    } else try w.writeAll("rootpw --lock\n");
    for (system.users, 0..) |user, index| {
        try w.print("user --name={s}", .{user.name});
        if (user.uid) |uid| try w.print(" --uid={d}", .{uid});
        if (user.shell) |shell| try w.print(" --shell={s}", .{shell});
        if (user.password) |plain| {
            const salt = password_hash.sessionSalt(password_scope, user.name);
            const hash = try password_hash.sha512Crypt(allocator, plain, &salt);
            defer allocator.free(hash);
            try w.print(" --password={s} --iscrypted", .{hash});
        } else try w.writeAll(" --lock");
        if (user.locked and user.password != null) try w.writeAll(" --lock");
        try renderUserGroups(w, user);
        try w.writeByte('\n');
        try w.print("sshkey --username={s} ", .{user.name});
        try kickstartQuote(w, bootstrap_key);
        try w.writeByte('\n');
        for (user.ssh_authorized_keys, 0..) |key, key_index| {
            var duplicate = render.sameSshKey(key, bootstrap_key);
            for (user.ssh_authorized_keys[0..key_index]) |existing| if (render.sameSshKey(key, existing)) {
                duplicate = true;
                break;
            };
            if (!duplicate) {
                try w.print("sshkey --username={s} ", .{user.name});
                try kickstartQuote(w, key);
                try w.writeByte('\n');
            }
        }
        if (index == 0) for (install.ssh_authorized_keys) |key| {
            var duplicate = render.sameSshKey(key, bootstrap_key);
            for (user.ssh_authorized_keys) |existing| {
                if (render.sameSshKey(key, existing)) duplicate = true;
            }
            if (!duplicate) {
                try w.print("sshkey --username={s} ", .{user.name});
                try kickstartQuote(w, key);
                try w.writeByte('\n');
            }
        };
    }
    try w.writeAll("sshkey --username=root ");
    try kickstartQuote(w, bootstrap_key);
    try w.writeByte('\n');
    for (system.ssh.root_authorized_keys, 0..) |key, key_index| {
        var duplicate = render.sameSshKey(key, bootstrap_key);
        for (system.ssh.root_authorized_keys[0..key_index]) |existing| if (render.sameSshKey(key, existing)) {
            duplicate = true;
            break;
        };
        if (!duplicate) {
            try w.writeAll("sshkey --username=root ");
            try kickstartQuote(w, key);
            try w.writeByte('\n');
        }
    }
    if (system.ssh.enabled) try w.writeAll("services --enabled=sshd\n");
    try w.print("selinux --{s}\n", .{@tagName(system.security.selinux)});
    try w.print("%pre\nnf_fact() {{ test -r /sys/class/dmi/id/$1 && head -c 256 /sys/class/dmi/id/$1 | tr -d '\\r\\n' | sed 's/\\\\/\\\\\\\\/g;s/\"/\\\\\"/g'; }}\nNF_SERIAL=$(nf_fact product_serial); NF_UUID=$(nf_fact product_uuid); NF_VENDOR=$(nf_fact sys_vendor); NF_MODEL=$(nf_fact product_name)\nNF_FACTS=$(printf '{{\"serial_number\":\"%s\",\"product_uuid\":\"%s\",\"vendor\":\"%s\",\"model\":\"%s\"}}' \"$NF_SERIAL\" \"$NF_UUID\" \"$NF_VENDOR\" \"$NF_MODEL\")\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d \"$NF_FACTS\" {s} || true\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"installer_started\"}}' {s} || true\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"started\"}}' {s} || true\n%end\n", .{ token, session, facts_url, token, session, session, event_url, token, session, session, event_url });
    try w.writeAll("%packages\n");
    if (software.environment) |environment| try w.print("@^{s}\n", .{environment}) else try w.writeAll("@^minimal-environment\n");
    for (software.groups) |group| try w.print("@{s}\n", .{group});
    if (system.ssh.enabled) try w.writeAll("openssh-server\n");
    for (software.packages.include) |package| try w.print("{s}\n", .{package});
    for (software.packages.exclude) |package| try w.print("-{s}\n", .{package});
    try w.writeAll("%end\n%post --erroronfail\n");
    if (install.proxy.url) |proxy| {
        try w.print("install -d -m 0755 /etc/profile.d\nprintf '%s\\n' 'export http_proxy={s}' 'export https_proxy={s}'", .{ proxy, proxy });
        if (install.proxy.no_proxy.len != 0) {
            try w.writeAll(" 'export no_proxy=");
            for (install.proxy.no_proxy, 0..) |value, index| {
                if (index != 0) try w.writeByte(',');
                try w.writeAll(value);
            }
            try w.writeByte('\'');
        }
        try w.writeAll(" > /etc/profile.d/nodeforge-proxy.sh\nchmod 0644 /etc/profile.d/nodeforge-proxy.sh\n");
    }
    switch (install.updates.mode) {
        .none => {},
        .security => try w.writeAll("dnf -y update --security\n"),
        .all => try w.writeAll("dnf -y update\n"),
    }
    for (network.routes) |route| {
        try w.print("nmcli connection modify $(nmcli -t -f NAME connection show --active | head -n1) +ipv4.routes '{s} {s}", .{ route.destination, route.gateway });
        if (route.metric) |metric| try w.print(" {d}", .{metric});
        try w.writeAll("'\n");
    }
    if (system.ssh.enabled) try w.print("mkdir -p /etc/ssh/sshd_config.d\nprintf '%s\\n' 'PermitRootLogin {s}' 'PasswordAuthentication {s}' > /etc/ssh/sshd_config.d/60-nodeforge.conf\n", .{ @tagName(system.ssh.root_login), if (system.ssh.password_authentication) "yes" else "no" });
    if (system.security.firewall == .disabled) try w.writeAll("systemctl disable --now firewalld || true\nsystemctl mask firewalld || true\n");
    if (!system.connectivity.time_sync) {
        try w.writeAll("systemctl disable --now chronyd || true\n");
    } else {
        try w.writeAll("printf '%s\\n'");
        for (system.connectivity.ntp_servers) |server| try w.print(" 'server {s} iburst'", .{server});
        try w.writeAll(" > /etc/chrony.conf\nsystemctl enable chronyd\n");
    }
    if (bundle) |value| {
        const script = try runner.renderInstallPost(allocator, value, .dnf);
        defer allocator.free(script);
        try w.writeAll(script);
    }
    try w.print("curl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"post\"}}' {s} || true\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"completed\"}}' {s} || true\n%end\n%onerror\nERRLOG=$(ls /tmp/anaconda-tb-*/anaconda-tb 2>/dev/null | head -1)\nSUMMARY=\"anaconda error\"\nif [ -n \"$ERRLOG\" ]; then\n  SUMMARY=\"anaconda error: $(head -c 1800 \"$ERRLOG\" 2>/dev/null | tr '\\n' ' ')\"\nfi\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' --data-urlencode 'v=1' --data-urlencode 'boot_session_id={s}' --data-urlencode 'reason=install.anaconda_error' --data-urlencode \"summary=$SUMMARY\" {s} || true\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"failed\"}}' {s} || true\n%end\n", .{ token, session, session, event_url, token, session, session, event_url, token, session, session, log_url, token, session, session, event_url });
    try w.print("{s}\n", .{@tagName(install.completion.action)});
    return out.toOwnedSlice();
}

fn renderAutomaticStorage(w: *std.Io.Writer, storage: model.StorageConfig) !void {
    const members = storage.members;
    if (members.len == 0) return error.InvalidStorageMembers;
    try w.print("part /boot/efi --fstype=efi --size=1024 --ondisk={s}\n", .{members[0][5..]});
    switch (storage.mode) {
        .single => try w.print("part /boot --fstype=ext4 --size=2048 --ondisk={s}\npart / --fstype=ext4 --grow --size=1 --ondisk={s}\n", .{ members[0][5..], members[0][5..] }),
        .lvm => {
            try w.print("part /boot --fstype=ext4 --size=2048 --ondisk={s}\npart pv.01 --grow --size=1 --ondisk={s}\n", .{ members[0][5..], members[0][5..] });
            try w.writeAll("volgroup nodeforge --pesize=4096 pv.01\nlogvol / --fstype=ext4 --name=root --vgname=nodeforge --grow --size=1\n");
        },
        else => {
            for (members, 0..) |disk, index| try w.print("part raid.boot.{d} --size=2048 --ondisk={s}\n", .{ index, disk[5..] });
            try w.writeAll("raid /boot --fstype=ext4 --device=mdboot --level=RAID1");
            for (members, 0..) |_, index| try w.print(" raid.boot.{d}", .{index});
            try w.writeByte('\n');
            for (members, 0..) |disk, index| try w.print("part raid.root.{d} --grow --size=1 --ondisk={s}\n", .{ index, disk[5..] });
            const level = raidLevel(storage.mode);
            if (isRaidLvm(storage.mode)) {
                try w.print("raid pv.01 --fstype=lvmpv --device=mdroot --level={s}", .{level});
                for (members, 0..) |_, index| try w.print(" raid.root.{d}", .{index});
                try w.writeAll("\nvolgroup nodeforge --pesize=4096 pv.01\nlogvol / --fstype=ext4 --name=root --vgname=nodeforge --grow --size=1\n");
            } else {
                try w.print("raid / --fstype=ext4 --device=mdroot --level={s}", .{level});
                for (members, 0..) |_, index| try w.print(" raid.root.{d}", .{index});
                try w.writeByte('\n');
            }
        },
    }
}

fn renderCustomStorage(w: *std.Io.Writer, storage: model.StorageConfig) !void {
    const members = storage.members;
    const primary = members[0][5..];
    for (storage.partitions) |part| if (part.kind == .esp) try kickstartPart(w, part, primary, null);
    switch (storage.mode) {
        .single => for (storage.partitions) |part| if (part.kind != .esp) try kickstartPart(w, part, primary, null),
        .lvm => {
            for (storage.partitions) |part| if (part.kind == .boot) try kickstartPart(w, part, primary, null);
            try w.print("part pv.01 --fstype=lvmpv --grow --size=1 --ondisk={s}\nvolgroup nodeforge --pesize=4096 pv.01\n", .{primary});
            for (storage.partitions) |part| if (part.kind != .esp and part.kind != .boot) try kickstartLogical(w, part);
        },
        else => {
            for (storage.partitions) |part| if (part.kind == .boot) try kickstartRaidPartition(w, part, members, "RAID1", false);
            if (isRaidLvm(storage.mode)) {
                for (members, 0..) |disk, index| try w.print("part raid.pv.{d} --grow --size=1 --ondisk={s}\n", .{ index, disk[5..] });
                try w.print("raid pv.01 --fstype=lvmpv --device=mdpv --level={s}", .{raidLevel(storage.mode)});
                for (members, 0..) |_, index| try w.print(" raid.pv.{d}", .{index});
                try w.writeAll("\nvolgroup nodeforge --pesize=4096 pv.01\n");
                for (storage.partitions) |part| if (part.kind != .esp and part.kind != .boot) try kickstartLogical(w, part);
            } else for (storage.partitions) |part| if (part.kind != .esp and part.kind != .boot) try kickstartRaidPartition(w, part, members, raidLevel(storage.mode), false);
        },
    }
}

fn kickstartPart(w: *std.Io.Writer, part: model.PartitionConfig, disk: []const u8, prefix: ?[]const u8) !void {
    const mount = part.mount orelse switch (part.kind) {
        .swap => "swap",
        .esp => "/boot/efi",
        .biosboot => "biosboot",
        .root => "/",
        .boot => "/boot",
        else => return error.InvalidPartition,
    };
    const fs = part.filesystem orelse switch (part.kind) {
        .esp => "efi",
        .swap => "swap",
        .biosboot => "biosboot",
        else => "ext4",
    };
    try w.print("part {s}{s} --fstype={s} --size={d}", .{ prefix orelse "", mount, fs, @max(part.size_mib, 1) });
    if (part.grow) try w.writeAll(" --grow");
    try w.print(" --ondisk={s}\n", .{disk});
}
fn kickstartLogical(w: *std.Io.Writer, part: model.PartitionConfig) !void {
    const id = part.id orelse return error.InvalidPartition;
    const mount = part.mount orelse switch (part.kind) {
        .swap => "swap",
        .root => "/",
        else => return error.InvalidPartition,
    };
    const fs = part.filesystem orelse if (part.kind == .swap) "swap" else "ext4";
    try w.print("logvol {s} --fstype={s} --name={s} --vgname=nodeforge --size={d}", .{ mount, fs, id, @max(part.size_mib, 1) });
    if (part.grow) try w.writeAll(" --grow");
    try w.writeByte('\n');
}
fn kickstartRaidPartition(w: *std.Io.Writer, part: model.PartitionConfig, members: []const []const u8, level: []const u8, _: bool) !void {
    const id = part.id orelse return error.InvalidPartition;
    for (members, 0..) |disk, index| {
        try w.print("part raid.{s}.{d} --size={d}", .{ id, index, @max(part.size_mib, 1) });
        if (part.grow) try w.writeAll(" --grow");
        try w.print(" --ondisk={s}\n", .{disk[5..]});
    }
    const mount = part.mount orelse switch (part.kind) {
        .swap => "swap",
        .root => "/",
        .boot => "/boot",
        else => return error.InvalidPartition,
    };
    const fs = part.filesystem orelse if (part.kind == .swap) "swap" else "ext4";
    try w.print("raid {s} --fstype={s} --device=md-{s} --level={s}", .{ mount, fs, id, level });
    for (members, 0..) |_, index| try w.print(" raid.{s}.{d}", .{ id, index });
    try w.writeByte('\n');
}

fn isRaidLvm(mode: model.StorageMode) bool {
    return switch (mode) {
        .@"raid0-lvm", .@"raid1-lvm", .@"raid5-lvm", .@"raid6-lvm", .@"raid10-lvm" => true,
        else => false,
    };
}

fn raidLevel(mode: model.StorageMode) []const u8 {
    return switch (mode) {
        .raid0, .@"raid0-lvm" => "RAID0",
        .raid1, .@"raid1-lvm" => "RAID1",
        .raid5, .@"raid5-lvm" => "RAID5",
        .raid6, .@"raid6-lvm" => "RAID6",
        .raid10, .@"raid10-lvm" => "RAID10",
        else => unreachable,
    };
}

test "schema v3 automatic storage renders all modes with native Kickstart actions" {
    const modes = [_]model.StorageMode{ .single, .lvm, .raid0, .raid1, .raid5, .raid6, .raid10, .@"raid0-lvm", .@"raid1-lvm", .@"raid5-lvm", .@"raid6-lvm", .@"raid10-lvm" };
    const disks = [_][]const u8{ "/dev/sda", "/dev/sdb", "/dev/sdc", "/dev/sdd" };
    for (modes) |mode| {
        const count: usize = switch (mode) {
            .single, .lvm => 1,
            .raid0, .raid1, .@"raid0-lvm", .@"raid1-lvm" => 2,
            .raid5, .@"raid5-lvm" => 3,
            else => 4,
        };
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try renderAutomaticStorage(&output.writer, .{ .mode = mode, .boot_disk = disks[0], .members = disks[0..count] });
        const bytes = output.written();
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "part /boot/efi"));
        try std.testing.expect(std.mem.indexOf(u8, bytes, "--fstype=ext4") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "part swap") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "%pre") == null and std.mem.indexOf(u8, bytes, "%post") == null);
        if (mode != .single and mode != .lvm) {
            try std.testing.expect(std.mem.indexOf(u8, bytes, "raid /boot --fstype=ext4 --device=mdboot --level=RAID1") != null);
            try std.testing.expect(std.mem.indexOf(u8, bytes, raidLevel(mode)) != null);
        }
        if (mode == .lvm or isRaidLvm(mode)) try std.testing.expect(std.mem.indexOf(u8, bytes, "volgroup nodeforge") != null);
    }
}

test "schema v3 custom logical layout renders all modes natively in Kickstart" {
    const modes = [_]model.StorageMode{ .single, .lvm, .raid0, .raid1, .raid5, .raid6, .raid10, .@"raid0-lvm", .@"raid1-lvm", .@"raid5-lvm", .@"raid6-lvm", .@"raid10-lvm" };
    const disks = [_][]const u8{ "/dev/sda", "/dev/sdb", "/dev/sdc", "/dev/sdd" };
    const partitions = [_]model.PartitionConfig{ .{ .id = "esp", .mount = "/boot/efi", .filesystem = "efi", .size_mib = 1024, .kind = .esp }, .{ .id = "boot", .mount = "/boot", .filesystem = "ext4", .size_mib = 2048, .kind = .boot }, .{ .id = "var", .mount = "/var", .filesystem = "ext4", .size_mib = 8192 }, .{ .id = "root", .mount = "/", .filesystem = "ext4", .grow = true, .kind = .root } };
    for (modes) |mode| {
        const count: usize = switch (mode) {
            .single, .lvm => 1,
            .raid0, .raid1, .@"raid0-lvm", .@"raid1-lvm" => 2,
            .raid5, .@"raid5-lvm" => 3,
            else => 4,
        };
        var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer output.deinit();
        try renderCustomStorage(&output.writer, .{ .mode = mode, .boot_disk = disks[0], .members = disks[0..count], .partitions = &partitions });
        const bytes = output.written();
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "part /boot/efi"));
        try std.testing.expect(std.mem.indexOf(u8, bytes, "%pre") == null and std.mem.indexOf(u8, bytes, "storage-script") == null);
        if (mode == .lvm or isRaidLvm(mode)) try std.testing.expect(std.mem.indexOf(u8, bytes, "logvol /var") != null);
        if (mode != .single and mode != .lvm) try std.testing.expect(std.mem.indexOf(u8, bytes, "raid /boot") != null);
    }
}

/// `sshkey` 只有一个位置参数。SSH 公钥包含类型、base64 负载和通常还有
/// 注释，因此将其作为一个带引号的 Kickstart token 输出，而不是让解析器
/// 拆分为三个 token。
fn kickstartQuote(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |byte| switch (byte) {
        '"', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(byte);
        },
        else => try w.writeByte(byte),
    };
    try w.writeByte('"');
}

fn ipv4Netmask(buffer: *[15]u8, prefix_len: u8) []const u8 {
    const bits: u5 = @intCast(32 - prefix_len);
    const mask: u32 = if (prefix_len == 0) 0 else @as(u32, std.math.maxInt(u32)) << bits;
    return std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{ (mask >> 24) & 0xff, (mask >> 16) & 0xff, (mask >> 8) & 0xff, mask & 0xff }) catch unreachable;
}

/// 渲染 Kickstart answer 文件。
///
/// 参数说明：
/// - `node`：目标节点配置，提供主机名
/// - `install`：安装器输入配置（存储、分区、用户、包等）
/// - `repo_url`：已发布的 dnf 仓库基础 URL（对应 Anaconda `url --url`）
/// - `bundle`：可选的后处理 bundle，展开为 `%post` 中的 shell 命令
/// - `event_url`：事件上报端点 URL，`%post` 末尾通过 curl 上报安装完成事件
/// - `session`：boot session ID，用于事件关联
/// - `token`：capability token，用于 HTTP 认证
///
/// 返回调用方拥有的堆分配字节切片，包含完整的 Kickstart 文件内容。
pub fn renderAnswer(allocator: std.mem.Allocator, node: *const model.NodeConfig, install: model.InstallConfig, repo_url: []const u8, bundle: ?*const model.ProvisioningBundle, event_url: []const u8, session: []const u8, token: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    // 基础配置：安装源、语言、键盘、时区
    try w.print("url --url={s}\nlang en_US.UTF-8\nkeyboard us\ntimezone UTC --utc\n", .{repo_url});
    // 网络配置：DHCP 获取地址，设置主机名并激活网卡
    try w.print("network --bootproto=dhcp --hostname={s} --activate\n", .{render.hostname(node)});
    // 磁盘初始化：zerombr 清除 MBR，clearpart 清除所有分区
    // boot_disk 去掉 /dev/ 前缀（如 sda），防止注入完整设备路径
    try w.print("zerombr\nclearpart --all --initlabel --drives={s}\n", .{install.storage.boot_disk[5..]});
    // 分区配置：无显式分区时使用安全默认布局
    if (install.storage.partitions.len == 0) {
        // UEFI 模式需要 ESP 分区（600 MiB，FAT32/efi 类型）
        try w.writeAll("part /boot/efi --fstype=efi --size=600\n");
        // 交换分区（2048 MiB）和根分区（使用剩余空间，最小 10240 MiB，xfs 文件系统）
        try w.writeAll("part swap --fstype=swap --size=2048\npart / --fstype=xfs --grow --size=10240\n");
    } else for (install.storage.partitions) |part| {
        // 显式分区：按 kind 推导默认挂载点和文件系统
        const mount = part.mount orelse switch (part.kind) {
            .swap => "swap",
            .esp => "/boot/efi",
            .biosboot => "biosboot",
            else => return error.InvalidPartition,
        };
        const fs = part.filesystem orelse switch (part.kind) {
            .esp => "efi",
            .swap => "swap",
            .biosboot => "biosboot",
            else => "xfs",
        };
        try w.print("part {s} --fstype={s} --size={d}\n", .{ mount, fs, part.size_mib });
    }
    // 引导加载器：MVP 使用 --location=none，因为 GRUB 已由 clearpart 后的分区自动安装
    if (install.bootloader.install) try w.print("bootloader --location=none --boot-drive={s}\n", .{install.storage.boot_disk});
    // 用户创建：每个用户渲染为一个 user 指令
    for (install.users) |user| {
        try w.print("user --name={s}", .{user.name});
        // Anaconda 在未设置 --iscrypted 时接受明文密码；配置模型有意保持明文
        if (user.password) |password| try w.print(" --password={s}", .{password});
        // sudo 权限通过加入 wheel 组实现
        try renderUserGroups(w, user);
        try w.writeByte('\n');
    }
    // 软件包选择：最小化环境 + 额外包
    try w.writeAll("%packages\n@^minimal-environment\n");
    for (install.packages) |package| try w.print("{s}\n", .{package});
    // 安装后脚本：展开 bundle 步骤 + 事件上报
    try w.writeAll("%end\n%post --erroronfail\n");
    if (bundle) |value| {
        // 将 bundle 中的步骤渲染为 dnf 命令（RHEL 系使用 dnf）
        const script = try runner.renderInstallPost(allocator, value, .dnf);
        defer allocator.free(script);
        try w.writeAll(script);
    }
    // 事件上报：通过 curl 向 daemon 上报安装后阶段完成
    // 携带 capability token（Authorization）和 session id（X-NodeForge-Session）
    // `|| true` 确保即使事件上报失败也不阻塞安装完成
    try w.print("curl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"post\"}}' {s} || true\n", .{ token, session, session, event_url });
    try w.writeAll("%end\nreboot\n");
    return out.toOwnedSlice();
}

fn renderUserGroups(w: *std.Io.Writer, user: model.TargetUserConfig) !void {
    if (!user.sudo and user.groups.len == 0) return;
    try w.writeAll(" --groups=");
    var first = true;
    if (user.sudo) {
        try w.writeAll("wheel");
        first = false;
    }
    for (user.groups) |group| {
        if (user.sudo and std.mem.eql(u8, group, "wheel")) continue;
        if (!first) try w.writeByte(',');
        try w.writeAll(group);
        first = false;
    }
}

// 测试：Kickstart 渲染包含 UEFI 默认分区和安装后事件上报 curl 命令。
test "kickstart renders UEFI defaults and installer event hook" {
    const node: model.NodeConfig = .{ .id = "node-01", .mac = "00:11:22:33:44:55", .arch = .aarch64, .profile = "rocky" };
    const bytes = try renderAnswer(std.testing.allocator, &node, .{ .users = &.{.{ .name = "admin", .password = "asdf1234" }} }, "http://repo", null, "http://event", "0123456789abcdef0123456789abcdef", "token");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "part /boot/efi") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "curl -fsS") != null);
}

test "M4.1 kickstart renders root crypt and security defaults" {
    const node: model.NodeConfig = .{ .id = "node-02", .mac = "00:11:22:33:44:66", .arch = .aarch64, .profile = "rocky" };
    const bytes = try renderAnswerM41(std.testing.allocator, &node, .{}, .{ .users = &.{.{ .name = "admin", .password = "secret", .sudo = true }}, .packages = &.{"vim"} }, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+ test", "http://repo", null, "http://facts", "http://event", "http://log", "0123456789abcdef0123456789abcdef", "token", "daemon:session:1", null);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "rootpw --iscrypted $6$") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "user --name=admin --password=$6$") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sshkey --username=admin \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+ test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "network --bootproto=dhcp --device=link --hostname=node-02 --activate --onboot=on") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "selinux --disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "systemctl mask firewalld") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "bootloader --location=none") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--append=") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "%pre") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "http://facts") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "product_serial") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "%onerror") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--data-urlencode \"summary=$SUMMARY\"") != null);
}

test "M4.2 kickstart renders default nodeforge account" {
    const node: model.NodeConfig = .{ .id = "node-default", .mac = "00:11:22:33:44:67", .arch = .x86_64, .profile = "rocky" };
    const bytes = try renderAnswerM41(std.testing.allocator, &node, .{}, .{}, "ssh-key", "http://repo", null, "http://facts", "http://event", "http://log", "0123456789abcdef0123456789abcdef", "token", "scope", null);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "user --name=nodeforge --password=$6$") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--groups=wheel") != null);
}

test "M4.6 kickstart persists kernel args with bootloader append" {
    const node: model.NodeConfig = .{ .id = "node-kargs", .mac = "00:11:22:33:44:68", .arch = .aarch64, .profile = "rocky" };
    const bytes = try renderAnswerM41(std.testing.allocator, &node, .{}, .{}, "ssh-key", "http://repo", null, "http://facts", "http://event", "http://log", "0123456789abcdef0123456789abcdef", "token", "scope", "iommu=pt hugepages=4");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "bootloader --boot-drive=sda --append=\"iommu=pt hugepages=4\"") != null);
}

test "M4.1 kickstart static target network uses Anaconda netmask syntax" {
    const node: model.NodeConfig = .{ .id = "node-03", .mac = "00:11:22:33:44:77", .arch = .aarch64, .profile = "rocky", .network = .{ .mode = .static, .interface = "ens192", .match_mac = "00:11:22:33:44:77", .address = "192.168.50.20", .prefix_len = 24, .search_domains = &.{"nodeforge.local"} } };
    const bytes = try renderAnswerM41(std.testing.allocator, &node, .{}, .{ .connectivity = .{ .time_sync = true, .ntp_servers = &.{"ntp.nodeforge.local"} } }, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+ test", "http://repo", null, "http://facts", "http://event", "http://log", "0123456789abcdef0123456789abcdef", "token", "daemon:session:1", null);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--netmask=255.255.255.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--prefix=") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--device=ens192") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--ipv4-dns-search=nodeforge.local") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "timesource --ntp-server=ntp.nodeforge.local") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "server ntp.nodeforge.local iburst") != null);
}
