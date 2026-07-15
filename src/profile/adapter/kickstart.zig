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
pub fn renderAnswerM41(allocator: std.mem.Allocator, node: *const model.NodeConfig, install: model.InstallConfig, system: model.TargetSystemConfig, bootstrap_key: []const u8, repo_url: []const u8, bundle: ?*const model.ProvisioningBundle, facts_url: []const u8, event_url: []const u8, log_url: []const u8, session: []const u8, token: []const u8, password_scope: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("url --url={s}\nlang {s}\nkeyboard {s}\ntimezone {s} --utc\n", .{ repo_url, system.localization.locale, system.localization.keyboard, system.localization.timezone });
    if (system.connectivity.time_sync) for (system.connectivity.ntp_servers) |server| try w.print("timesource --ntp-server={s}\n", .{server});
    const network = node.overrides.network orelse model.TargetNetworkConfig{};
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
    try w.print("zerombr\nclearpart --all --initlabel --drives={s}\n", .{install.storage.boot_disk[5..]});
    if (install.storage.partitions.len == 0) {
        if (install.storage.boot_mode == .uefi) try w.writeAll("part /boot/efi --fstype=efi --size=600\n");
        try w.writeAll("part swap --fstype=swap --size=2048\npart / --fstype=xfs --grow --size=10240\n");
    } else for (install.storage.partitions) |part| {
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
    if (install.bootloader.install) try w.print("bootloader --boot-drive={s}\n", .{install.storage.boot_disk[5..]});
    if (system.ssh.root_password) |plain| {
        const salt = password_hash.sessionSalt(password_scope, "root");
        const hash = try password_hash.sha512Crypt(allocator, plain, &salt);
        defer allocator.free(hash);
        try w.print("rootpw --iscrypted {s}\n", .{hash});
    } else try w.writeAll("rootpw --lock\n");
    for (system.users, 0..) |user, index| {
        try w.print("user --name={s}", .{user.name});
        if (user.password) |plain| {
            const salt = password_hash.sessionSalt(password_scope, user.name);
            const hash = try password_hash.sha512Crypt(allocator, plain, &salt);
            defer allocator.free(hash);
            try w.print(" --password={s} --iscrypted", .{hash});
        } else try w.writeAll(" --lock");
        if (user.sudo) try w.writeAll(" --groups=wheel");
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
    if (system.security.selinux == .disabled) try w.writeAll("selinux --disabled\n");
    try w.print("%pre\nnf_fact() {{ test -r /sys/class/dmi/id/$1 && head -c 256 /sys/class/dmi/id/$1 | tr -d '\\r\\n' | sed 's/\\\\/\\\\\\\\/g;s/\"/\\\\\"/g'; }}\nNF_SERIAL=$(nf_fact product_serial); NF_UUID=$(nf_fact product_uuid); NF_VENDOR=$(nf_fact sys_vendor); NF_MODEL=$(nf_fact product_name)\nNF_FACTS=$(printf '{{\"serial_number\":\"%s\",\"product_uuid\":\"%s\",\"vendor\":\"%s\",\"model\":\"%s\"}}' \"$NF_SERIAL\" \"$NF_UUID\" \"$NF_VENDOR\" \"$NF_MODEL\")\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d \"$NF_FACTS\" {s} || true\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"installer_started\"}}' {s} || true\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"started\"}}' {s} || true\n%end\n", .{ token, session, facts_url, token, session, session, event_url, token, session, session, event_url });
    try w.writeAll("%packages\n@^minimal-environment\n");
    if (system.ssh.enabled) try w.writeAll("openssh-server\n");
    for (system.packages) |package| try w.print("{s}\n", .{package});
    try w.writeAll("%end\n%post --erroronfail\n");
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
    try w.print("curl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"post\"}}' {s} || true\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"completed\"}}' {s} || true\n%end\n%onerror\nERRLOG=$(ls /tmp/anaconda-tb-*/anaconda-tb 2>/dev/null | head -1)\nSUMMARY=\"anaconda error\"\nif [ -n \"$ERRLOG\" ]; then\n  SUMMARY=\"anaconda error: $(head -c 1800 \"$ERRLOG\" 2>/dev/null | tr '\\n' ' ')\"\nfi\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' --data-urlencode 'v=1' --data-urlencode 'boot_session_id={s}' --data-urlencode 'reason=install.anaconda_error' --data-urlencode \"summary=$SUMMARY\" {s} || true\ncurl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\"v\":1,\"boot_session_id\":\"{s}\",\"stage\":\"failed\"}}' {s} || true\n%end\nreboot\n", .{ token, session, session, event_url, token, session, session, event_url, token, session, session, log_url, token, session, session, event_url });
    return out.toOwnedSlice();
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
        if (install.storage.boot_mode == .uefi) try w.writeAll("part /boot/efi --fstype=efi --size=600\n");
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
        if (user.sudo) try w.writeAll(" --groups=wheel");
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
    const bytes = try renderAnswerM41(std.testing.allocator, &node, .{}, .{ .users = &.{.{ .name = "admin", .password = "secret", .sudo = true }}, .packages = &.{"vim"} }, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+ test", "http://repo", null, "http://facts", "http://event", "http://log", "0123456789abcdef0123456789abcdef", "token", "daemon:session:1");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "rootpw --iscrypted $6$") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "user --name=admin --password=$6$") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "sshkey --username=admin \"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+ test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "network --bootproto=dhcp --device=link --hostname=node-02 --activate --onboot=on") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "selinux --disabled") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "systemctl mask firewalld") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "bootloader --location=none") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "%pre") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "http://facts") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "product_serial") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "%onerror") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--data-urlencode \"summary=$SUMMARY\"") != null);
}

test "M4.2 kickstart renders default nodeforge account" {
    const node: model.NodeConfig = .{ .id = "node-default", .mac = "00:11:22:33:44:67", .arch = .x86_64, .profile = "rocky" };
    const bytes = try renderAnswerM41(std.testing.allocator, &node, .{}, .{}, "ssh-key", "http://repo", null, "http://facts", "http://event", "http://log", "0123456789abcdef0123456789abcdef", "token", "scope");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "user --name=nodeforge --password=$6$") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--groups=wheel") != null);
}

test "M4.1 kickstart static target network uses Anaconda netmask syntax" {
    const node: model.NodeConfig = .{ .id = "node-03", .mac = "00:11:22:33:44:77", .arch = .aarch64, .profile = "rocky", .overrides = .{ .network = .{ .mode = .static, .interface = "ens192", .match_mac = "00:11:22:33:44:77", .address = "192.168.50.20", .prefix_len = 24, .search_domains = &.{"nodeforge.local"} } } };
    const bytes = try renderAnswerM41(std.testing.allocator, &node, .{}, .{ .connectivity = .{ .time_sync = true, .ntp_servers = &.{"ntp.nodeforge.local"} } }, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+ test", "http://repo", null, "http://facts", "http://event", "http://log", "0123456789abcdef0123456789abcdef", "token", "daemon:session:1");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--netmask=255.255.255.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--prefix=") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--device=ens192") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--ipv4-dns-search=nodeforge.local") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "timesource --ntp-server=ntp.nodeforge.local") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "server ntp.nodeforge.local iburst") != null);
}
