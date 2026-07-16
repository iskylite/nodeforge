//! M4 Ubuntu Autoinstall 适配器（Ubuntu 20.04+）。
//!
//! 本模块将 NodeForge 的 `InstallConfig` 渲染为 Subiquity（Ubuntu 安装器）
//! 可读取的 cloud-config/autoinstall user-data 和 meta-data 文件。
//!
//! ## Schema 依据
//!
//! autoinstall 字段名和结构以 Subiquity 官方 `autoinstall-schema.json`
//! （canonical/subiquity 仓库根目录）为唯一权威来源。以下字段曾因名称
//! 错误或不在 schema 中而引发线上故障，修复时已逐项对照 schema 确认：
//!
//! - `refresh-installer`（不是 `refresh`）：控制 Subiquity 是否从 snapstore.io
//!   刷新安装器 snap。写成 `refresh` 会被 Subiquity 静默忽略。
//! - `apt.fallback` 枚举值为 `abort` | `continue-anyway` | `offline-install`，
//!   由 profile 的 `install.apt.fallback` 强类型配置。默认 `offline-install`
//!   兼容隔离 PXE；严格要求 HTTP mirror 时使用 `abort`。
//! - `apt` 段没有 `disable_suites` 字段。该字段属于 curtin 内部，Subiquity
//!   会静默忽略。要控制 suite 必须使用 `apt.sources` 显式指定 sources.list。
//! - `apt` 段合法字段：`preserve_sources_list`、`primary`（legacy）、
//!   `mirror-selection`、`geoip`、`sources`、`disable_components`、
//!   `preferences`、`fallback`。
//!
//! ## 与 Kickstart 的关键差异
//!
//! - Ubuntu 使用 NoCloud-Net 数据源：通过 HTTP 提供 user-data 和 meta-data
//! - user-data 以 `#cloud-config` 开头，包含 `autoinstall:` 段
//! - 密码需要 SHA-256 哈希（Subiquity 要求非明文），而非 Kickstart 的明文
//! - 存储布局使用 `direct` 模式（Subiquity 自行决定分区），而非 Kickstart 的显式 `part` 指令
//! - 安装后命令使用 `curtin in-target` 在目标系统中执行，而非 Kickstart 的直接 `%post`
//! - `late-commands` 中的 shell 脚本需要单引号转义（`'` → `'\''`）
//!
//! ## 安全说明
//!
//! - YAML 字符串使用单引号包裹并转义内部单引号，防止注入
//! - `late-commands` 中的脚本换行符转为 `&&`，保持单行并在任一步失败时停止
//! - 事件上报 curl 携带 capability token 和 session id

const std = @import("std");
const model = @import("../../model.zig");
const render = @import("../render.zig");
const runner = @import("../../provision/runner.zig");
const password_hash = @import("../password_hash.zig");

/// M4.1 渲染器。原始 M4 入口点保留为兼容包装；
/// 所有 daemon answer 下发均使用此 common-system 变体。
pub fn renderUserDataM41(allocator: std.mem.Allocator, node: *const model.NodeConfig, install: model.InstallConfig, system: model.TargetSystemConfig, bootstrap_key: []const u8, bundle: ?*const model.ProvisioningBundle, apt_primary_url: ?[]const u8, facts_url: []const u8, event_url: []const u8, log_url: []const u8, report_url: []const u8, session: []const u8, token: []const u8, password_scope: []const u8, kernel_args: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("#cloud-config\nautoinstall:\n  version: 1\n  interactive-sections: []\n  shutdown: reboot\n  refresh-installer:\n    update: false\n  locale: ");
    try render.yamlQuote(w, system.localization.locale);
    try w.writeAll("\n  timezone: ");
    try render.yamlQuote(w, system.localization.timezone);
    try w.writeAll("\n  keyboard:\n    layout: ");
    try render.yamlQuote(w, system.localization.keyboard);
    try w.writeAll("\n  ssh:\n    install-server: ");
    try w.writeAll(if (system.ssh.enabled) "true" else "false");
    try w.writeAll("\n    allow-pw: ");
    try w.writeAll(if (system.ssh.password_authentication) "true" else "false");
    try w.writeAll("\n  packages:\n");
    if (system.ssh.enabled) try w.writeAll("    - 'openssh-server'\n");
    for (system.packages) |package| {
        try w.writeAll("    - ");
        try render.yamlQuote(w, package);
        try w.writeByte('\n');
    }
    // Jammy 在请求普通用户时要求完整的 identity 段。Root 和其他账户
    // 在下方显式配置。
    if (system.users.len != 0) {
        const identity = system.users[0];
        try w.writeAll("  identity:\n    hostname: ");
        try render.yamlQuote(w, render.hostname(node));
        try w.writeAll("\n    username: ");
        try render.yamlQuote(w, identity.name);
        try w.writeAll("\n    password: ");
        if (identity.password) |plain| {
            const salt = password_hash.sessionSalt(password_scope, identity.name);
            const hash = try password_hash.sha512Crypt(allocator, plain, &salt);
            defer allocator.free(hash);
            try render.yamlQuote(w, hash);
        } else try render.yamlQuote(w, "!");
        try w.writeByte('\n');
    }
    try w.writeAll("  apt:\n    mirror-selection:\n      primary:\n        - uri: ");
    try render.yamlQuote(w, apt_primary_url orelse "");
    try w.print("\n    fallback: {s}\n    geoip: false\n", .{@tagName(install.apt.fallback)});
    // ── Subiquity 原生 reporting（curtin webhook reporter）──────────────
    //
    // curtin 的 HTTP-POST reporter 类型名为 `webhook`（不是 `http`），
    // 在 Ubuntu 22.04 和 24.04 中均可用（handler 注册表完全相同）。
    //
    // webhook reporter 的 schema：
    //   type: webhook         # 固定
    //   endpoint: <url>       # 必填，HTTP POST 目标
    //   level: INFO           # 可选，默认 DEBUG
    //   retries: 5            # 可选
    //   timeout: 30           # 可选
    //
    // webhook reporter 不支持 `headers` 字段（会 TypeError）。
    // 认证通过源 IP 校验：/subiquity-report 端点检查请求来源 IP 匹配节点 DHCP lease。
    // OAuth（consumer_key/consumer_secret/token_key/token_secret）全部省略时为无认证 POST。
    //
    // webhook POST 的 JSON 事件格式（ReportingEvent.as_dict）：
    //   {"name":"<stage>","description":"<msg>","event_type":"start|finish|result",
    //    "origin":"curtin","timestamp":1234567890.0,"level":"INFO"}
    // finish 事件额外含 "result":"SUCCESS|WARN|FAIL"。
    //
    // report_url 为空时不渲染 reporting 块（调用方未配置 subiquity-report 端点时）。
    // ──────────────────────────────────────────────────────────────
    if (report_url.len > 0) {
        try w.writeAll("  reporting:\n    nodeforge:\n      type: webhook\n      endpoint: ");
        try render.yamlQuote(w, report_url);
        try w.writeAll("\n      level: INFO\n");
    }
    const network = node.overrides.network orelse model.TargetNetworkConfig{};
    try renderStorageM41(w, install);
    try w.writeAll("  network:\n    version: 2\n    ethernets:\n      ");
    try w.writeAll(network.interface orelse "nodeforge");
    try w.writeAll(":\n        match:\n          macaddress: ");
    try render.yamlQuote(w, network.match_mac orelse node.mac);
    if (network.interface) |interface| {
        try w.writeAll("\n        set-name: ");
        try render.yamlQuote(w, interface);
    }
    if (network.mode == .dhcp) {
        try w.writeAll("\n        dhcp4: true\n");
    } else {
        try w.writeAll("\n        dhcp4: false\n        addresses: [");
        const cidr = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ network.address.?, network.prefix_len.? });
        defer allocator.free(cidr);
        try render.yamlQuote(w, cidr);
        try w.writeAll("]\n");
        if (network.gateway) |gateway| {
            try w.writeAll("        routes:\n          - to: default\n            via: ");
            try render.yamlQuote(w, gateway);
            try w.writeByte('\n');
        }
        if (network.dns.len != 0 or network.search_domains.len != 0) {
            try w.writeAll("        nameservers:\n");
            if (network.dns.len != 0) {
                try w.writeAll("          addresses: [");
                for (network.dns, 0..) |dns, i| {
                    if (i != 0) try w.writeAll(", ");
                    try render.yamlQuote(w, dns);
                }
                try w.writeAll("]\n");
            }
            if (network.search_domains.len != 0) {
                try w.writeAll("          search: [");
                for (network.search_domains, 0..) |domain, i| {
                    if (i != 0) try w.writeAll(", ");
                    try render.yamlQuote(w, domain);
                }
                try w.writeAll("]\n");
            }
        }
    }
    // 目标系统的 cloud-init 只消费 autoinstall.user-data。文档根节点的
    // hostname 仅影响安装环境，不能替代这里的目标 hostname。
    try w.writeAll("  user-data:\n    hostname: ");
    try render.yamlQuote(w, render.hostname(node));
    try w.writeAll("\n    preserve_hostname: false\n    disable_root: false\n    ssh_pwauth: ");
    try w.writeAll(if (system.ssh.password_authentication) "true" else "false");
    try w.writeAll("\n    users:\n");
    try renderCloudUser(w, allocator, "root", system.ssh.root_password, false, bootstrap_key, system.ssh.root_authorized_keys, &.{}, password_scope);
    for (system.users, 0..) |user, index| try renderCloudUser(w, allocator, user.name, user.password, user.sudo, bootstrap_key, user.ssh_authorized_keys, if (index == 0) install.ssh_authorized_keys else &.{}, password_scope);
    try w.writeAll("  early-commands:\n");
    const facts_command = try std.fmt.allocPrint(allocator, "nf_fact() {{ test -r /sys/class/dmi/id/$1 && head -c 256 /sys/class/dmi/id/$1 | tr -d '\\r\\n' | sed 's/\\\\/\\\\\\\\/g;s/\"/\\\\\"/g'; }}; s=$(nf_fact product_serial); u=$(nf_fact product_uuid); v=$(nf_fact sys_vendor); m=$(nf_fact product_name); d=$(printf '{{\"serial_number\":\"%s\",\"product_uuid\":\"%s\",\"vendor\":\"%s\",\"model\":\"%s\"}}' \"$s\" \"$u\" \"$v\" \"$m\"); curl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d \"$d\" {s} || true", .{ token, session, facts_url });
    defer allocator.free(facts_command);
    try w.writeAll("    - ");
    try render.yamlQuote(w, facts_command);
    try w.writeByte('\n');
    try w.print("    - 'curl -fsS -H \"Authorization: Bearer {s}\" -H \"X-NodeForge-Session: {s}\" -H \"Content-Type: application/json\" -d \"{{\\\"v\\\":1,\\\"boot_session_id\\\":\\\"{s}\\\",\\\"stage\\\":\\\"installer_started\\\"}}\" {s} || true'\n", .{ token, session, session, event_url });
    try w.print("    - 'curl -fsS -H \"Authorization: Bearer {s}\" -H \"X-NodeForge-Session: {s}\" -H \"Content-Type: application/json\" -d \"{{\\\"v\\\":1,\\\"boot_session_id\\\":\\\"{s}\\\",\\\"stage\\\":\\\"started\\\"}}\" {s} || true'\n", .{ token, session, session, event_url });
    try w.writeAll("  late-commands:\n");
    if (kernel_args) |args| {
        const grub_command = try std.fmt.allocPrint(allocator, "mkdir -p /target/etc/default/grub.d && printf '%s\\n' 'GRUB_CMDLINE_LINUX=\"${{GRUB_CMDLINE_LINUX}} {s}\"' > /target/etc/default/grub.d/99-nodeforge.cfg && chmod 0644 /target/etc/default/grub.d/99-nodeforge.cfg", .{args});
        defer allocator.free(grub_command);
        try w.writeAll("    - ");
        try render.yamlQuote(w, grub_command);
        try w.writeByte('\n');
        try w.writeAll("    - 'curtin in-target --target=/target -- update-grub'\n");
    }
    if (system.ssh.enabled) {
        const root_login = @tagName(system.ssh.root_login);
        const sshd = try std.fmt.allocPrint(allocator, "printf '%s\\n' 'PermitRootLogin {s}' 'PasswordAuthentication {s}' > /target/etc/ssh/sshd_config.d/60-nodeforge.conf", .{ root_login, if (system.ssh.password_authentication) "yes" else "no" });
        defer allocator.free(sshd);
        try w.writeAll("    - ");
        try render.yamlQuote(w, sshd);
        try w.writeByte('\n');
    }
    if (system.ssh.root_password) |plain| {
        const salt = password_hash.sessionSalt(password_scope, "root");
        const hash = try password_hash.sha512Crypt(allocator, plain, &salt);
        defer allocator.free(hash);
        const root_password = try std.fmt.allocPrint(allocator, "curtin in-target --target=/target -- usermod --password '{s}' root", .{hash});
        defer allocator.free(root_password);
        try w.writeAll("    - ");
        try render.yamlQuote(w, root_password);
        try w.writeByte('\n');
    }
    if (system.security.firewall == .disabled) try w.writeAll("    - 'curtin in-target --target=/target -- systemctl disable --now ufw || true'\n");
    if (!system.connectivity.time_sync) {
        try w.writeAll("    - 'curtin in-target --target=/target -- systemctl disable --now systemd-timesyncd || true'\n");
    } else {
        var ntp_servers: std.Io.Writer.Allocating = .init(allocator);
        defer ntp_servers.deinit();
        for (system.connectivity.ntp_servers, 0..) |server, index| {
            if (index != 0) try ntp_servers.writer.writeByte(' ');
            try ntp_servers.writer.writeAll(server);
        }
        const ntp_command = try std.fmt.allocPrint(allocator, "mkdir -p /target/etc/systemd/timesyncd.conf.d && printf '%s\\n' '[Time]' 'NTP={s}' 'FallbackNTP=' > /target/etc/systemd/timesyncd.conf.d/60-nodeforge.conf && curtin in-target --target=/target -- systemctl enable systemd-timesyncd", .{ntp_servers.written()});
        defer allocator.free(ntp_command);
        try w.writeAll("    - ");
        try render.yamlQuote(w, ntp_command);
        try w.writeByte('\n');
    }
    if (bundle) |value| {
        const script = try runner.renderInstallPost(allocator, value, .apt);
        defer allocator.free(script);
        var command: std.Io.Writer.Allocating = .init(allocator);
        defer command.deinit();
        try command.writer.writeAll("curtin in-target --target=/target -- sh -c '");
        for (std.mem.trimEnd(u8, script, "\r\n")) |c| if (c == '\'') try command.writer.writeAll("'\\''") else if (c == '\n') try command.writer.writeAll(" && ") else try command.writer.writeByte(c);
        try command.writer.writeByte('\'');
        try w.writeAll("    - ");
        try render.yamlQuote(w, command.written());
        try w.writeByte('\n');
    }
    try w.print("    - 'curl -fsS -H \"Authorization: Bearer {s}\" -H \"X-NodeForge-Session: {s}\" -H \"Content-Type: application/json\" -d \"{{\\\"v\\\":1,\\\"boot_session_id\\\":\\\"{s}\\\",\\\"stage\\\":\\\"post\\\"}}\" {s} || true'\n", .{ token, session, session, event_url });
    // 这是刻意安排的最后一个安装器侧成功操作。它在 Subiquity 执行
    // 配置的重启之前关闭持久化 generation 并记录已应用的修订版本。
    try w.print("    - 'curl -fsS -H \"Authorization: Bearer {s}\" -H \"X-NodeForge-Session: {s}\" -H \"Content-Type: application/json\" -d \"{{\\\"v\\\":1,\\\"boot_session_id\\\":\\\"{s}\\\",\\\"stage\\\":\\\"completed\\\"}}\" {s} || true'\n", .{ token, session, session, event_url });
    try w.writeAll("  error-commands:\n");
    try w.print("    - 'ERR_CMD=${{ERROR_CMD}} ERR_STATUS=${{ERROR_STATUS}} ERR_TB=${{ERROR_TRACEBACK}} && SUMMARY=$(printf \"subiquity error: %s %s %s\" \"$ERR_CMD\" \"$ERR_STATUS\" \"$ERR_TB\" | head -c 1800) && curl -fsS -H \"Authorization: Bearer {s}\" -H \"X-NodeForge-Session: {s}\" --data-urlencode \"v=1\" --data-urlencode \"boot_session_id={s}\" --data-urlencode \"reason=install.subiquity_error\" --data-urlencode \"summary=$SUMMARY\" {s} || true'\n", .{ token, session, session, log_url });
    try w.print("    - 'curl -fsS -H \"Authorization: Bearer {s}\" -H \"X-NodeForge-Session: {s}\" -H \"Content-Type: application/json\" -d \"{{\\\"v\\\":1,\\\"boot_session_id\\\":\\\"{s}\\\",\\\"stage\\\":\\\"failed\\\"}}\" {s} || true'\n", .{ token, session, session, event_url });
    if (system.connectivity.time_sync) {
        try w.writeAll("ntp:\n  enabled: true\n  servers:\n");
        for (system.connectivity.ntp_servers) |server| {
            try w.writeAll("    - ");
            try render.yamlQuote(w, server);
            try w.writeByte('\n');
        }
    } else try w.writeAll("ntp:\n  enabled: false\n");
    // 同时设置安装环境 hostname；目标系统由上方 autoinstall.user-data 设置。
    try w.writeAll("hostname: ");
    try render.yamlQuote(w, render.hostname(node));
    try w.writeByte('\n');
    try w.writeAll("package_update: false\npackage_upgrade: false\n");
    return out.toOwnedSlice();
}

/// 渲染绑定到 `boot_disk` 的受约束 direct 布局，或显式 curtin action graph。
/// 防止 profile 选择的目标磁盘/分区被 Subiquity 静默丢弃。
fn renderStorageM41(w: *std.Io.Writer, install: model.InstallConfig) !void {
    if (install.storage.partitions.len == 0) {
        try w.writeAll("  storage:\n    layout:\n      name: direct\n      match:\n        path: ");
        try render.yamlQuote(w, install.storage.boot_disk);
        try w.writeByte('\n');
        return;
    }
    try w.writeAll("  storage:\n    config:\n      - type: disk\n        id: nodeforge-disk\n        path: ");
    try render.yamlQuote(w, install.storage.boot_disk);
    try w.writeAll("\n        ptable: ");
    try w.writeAll(@tagName(install.storage.partition_table));
    try w.writeAll("\n        wipe: superblock-recursive\n        preserve: false\n");
    for (install.storage.partitions, 0..) |part, index| {
        const fs = part.filesystem orelse switch (part.kind) {
            .esp => "fat32",
            .swap => "swap",
            else => "ext4",
        };
        try w.print("      - type: partition\n        id: nodeforge-part-{d}\n        device: nodeforge-disk\n        size: {d}\n", .{ index, @as(u64, part.size_mib) * 1024 * 1024 });
        if (part.kind == .esp) try w.writeAll("        flag: boot\n");
        try w.print("      - type: format\n        id: nodeforge-format-{d}\n        volume: nodeforge-part-{d}\n        fstype: {s}\n", .{ index, index, fs });
        const mount = part.mount orelse switch (part.kind) {
            .root => "/",
            .boot => "/boot",
            .esp => "/boot/efi",
            .swap => null,
            else => null,
        };
        if (mount) |path| {
            try w.print("      - type: mount\n        id: nodeforge-mount-{d}\n        device: nodeforge-format-{d}\n        path: ", .{ index, index });
            try render.yamlQuote(w, path);
            try w.writeByte('\n');
        }
    }
}

fn renderCloudUser(w: *std.Io.Writer, allocator: std.mem.Allocator, name: []const u8, password: ?[]const u8, sudo: bool, bootstrap_key: []const u8, keys: []const []const u8, legacy_keys: []const []const u8, session: []const u8) !void {
    try w.writeAll("      - name: ");
    try render.yamlQuote(w, name);
    try w.writeAll("\n        lock_passwd: ");
    try w.writeAll(if (password == null) "true" else "false");
    if (password) |plain| {
        const salt = password_hash.sessionSalt(session, name);
        const hash = try password_hash.sha512Crypt(allocator, plain, &salt);
        defer allocator.free(hash);
        try w.writeAll("\n        passwd: ");
        try render.yamlQuote(w, hash);
    }
    if (sudo) try w.writeAll("\n        groups: [sudo]");
    try w.writeAll("\n        ssh_authorized_keys:\n          - ");
    try render.yamlQuote(w, bootstrap_key);
    try w.writeByte('\n');
    for (keys, 0..) |key, key_index| {
        var duplicate = render.sameSshKey(key, bootstrap_key);
        for (keys[0..key_index]) |existing| if (render.sameSshKey(key, existing)) {
            duplicate = true;
            break;
        };
        if (!duplicate) {
            try w.writeAll("          - ");
            try render.yamlQuote(w, key);
            try w.writeByte('\n');
        }
    }
    for (legacy_keys, 0..) |key, legacy_index| if (!render.sameSshKey(key, bootstrap_key)) {
        var duplicate = false;
        for (keys) |existing| {
            if (render.sameSshKey(key, existing)) duplicate = true;
        }
        for (legacy_keys[0..legacy_index]) |existing| if (render.sameSshKey(key, existing)) {
            duplicate = true;
            break;
        };
        if (!duplicate) {
            try w.writeAll("          - ");
            try render.yamlQuote(w, key);
            try w.writeByte('\n');
        }
    };
}

/// 渲染 Ubuntu Autoinstall user-data（cloud-config 格式）。
///
/// 输出的 YAML 分为两个区域：
///
/// 1. **`autoinstall:` 段**（缩进 2 空格）：Subiquity 读取的安装配置。
///    所有字段名和枚举值严格遵循 Subiquity 官方 `autoinstall-schema.json`。
///
/// 2. **cloud-config 顶层键**（零缩进）：cloud-init 自身模块读取的配置。
///    这些键不在 `autoinstall:` 段内，而是 cloud-config 文档的顶层属性。
///
/// ## autoinstall 段字段清单（按渲染顺序）
///
/// | 字段 | 值 | schema 依据 / 离线 PXE 原因 |
/// | --- | --- | --- |
/// | `version` | `1` | schema required，唯一支持值 |
/// | `refresh-installer.update` | `false` | 阻止 Subiquity 从 snapstore.io 刷新 snap；隔离网段无 NAT/DNS 会超时 |
/// | `timezone` | `UTC` | 阻止 Subiquity geoIP 检测时区（需 HTTP 请求 ubuntu.com） |
/// | `locale` | `en_US.UTF-8` | 阻止交互式语言选择 |
/// | `identity` | hostname/username/password | schema required（username/hostname/password）；密码为 SHA-256 摘要 |
/// | `ssh` | install-server + allow-pw | 允许安装阶段 SSH 调试 |
/// | `packages` | 来自 InstallConfig | 额外包列表 |
/// | `apt.mirror-selection.primary` | NodeForge 本地 URL | 阻止 Subiquity 默认访问 archive.ubuntu.com |
/// | `apt.fallback` | `install.apt.fallback` | mirror 失败时终止、离线回退或继续；默认离线回退 |
/// | `apt.geoip` | `false` | 阻止 geoIP 镜像检测 |
/// | `storage.layout` | `direct` | Subiquity 自行决定分区方案 |
/// | `late-commands` | bundle + event curl | 安装后命令，通过 curtin in-target 在 /target 中执行 |
///
/// ## cloud-config 顶层字段清单
///
/// | 字段 | 值 | 原因 |
/// | --- | --- | --- |
/// | `ntp.enabled` | `false` | 禁用 cloud-init NTP 模块；隔离网段无 NTP 服务器 |
/// | `package_update` | `false` | 禁用 cloud-init 的 apt-get update 步骤 |
/// | `package_upgrade` | `false` | 禁用 cloud-init 的 apt-get upgrade 步骤 |
///
/// ## 参数说明
///
/// - `node`：目标节点配置，提供主机名
/// - `install`：安装器输入配置（存储、用户、包等）
/// - `bundle`：可选的后处理 bundle，展开为 `late-commands` 中的 curtin 命令
/// - `apt_primary_url`：NodeForge 发布的 APT 仓库 URL；null 时渲染空 uri
/// - `event_url`：事件上报端点 URL
/// - `session`：boot session ID，用于事件关联
/// - `token`：capability token，用于 HTTP 认证
///
/// 返回调用方拥有的堆分配字节切片，包含完整的 user-data 内容。
/// 输出以 `#cloud-config` 开头，供 Subiquity 通过 NoCloud-Net 数据源读取。
pub fn renderUserData(allocator: std.mem.Allocator, node: *const model.NodeConfig, install: model.InstallConfig, bundle: ?*const model.ProvisioningBundle, apt_primary_url: ?[]const u8, event_url: []const u8, session: []const u8, token: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    // cloud-config 头部 + autoinstall 版本 1
    //
    // 隔离 PXE 网段防超时配置（autoinstall 段内）：
    // - refresh-installer: { update: false }：阻止 Subiquity 从 snapstore.io
    //   刷新安装器 snap。字段名是 refresh-installer（经 autoinstall-schema.json
    //   确认），旧代码误写为 refresh 会被 Subiquity 静默忽略，导致隔离网段
    //   长时间等待 snap 刷新超时。
    // - timezone: UTC：显式指定时区，阻止 Subiquity 通过 geoIP 检测时区
    // - locale: en_US.UTF-8：显式指定语言环境，阻止交互式语言选择
    try w.writeAll("#cloud-config\nautoinstall:\n  version: 1\n  refresh-installer:\n    update: false\n  timezone: UTC\n  locale: en_US.UTF-8\n  identity:\n    hostname: ");
    try render.yamlQuote(w, render.hostname(node));
    // 用户配置：Subiquity 只支持 identity 段中的单个用户
    if (install.users.len != 0) {
        const user = install.users[0];
        // 密码使用 SHA-256 哈希，因为 Subiquity 要求非明文密码
        // 不使用 crypt(3) SHA-512，因为 MVP 配置模型以明文存储密码
        var digest: [64]u8 = undefined;
        try w.writeAll("\n    username: ");
        try render.yamlQuote(w, user.name);
        // 密码为 null 时使用 "!" 表示禁用密码登录
        try w.writeAll("\n    password: ");
        try render.yamlQuote(w, if (user.password) |p| render.passwordDigest(&digest, p) else "!");
    }
    // SSH 配置：允许安装阶段 SSH 登录（用于调试）和密码认证
    try w.writeAll("\n  ssh:\n    install-server: true\n    allow-pw: true\n  packages:\n");
    // 额外包列表
    for (install.packages) |package| {
        try w.writeAll("    - ");
        try render.yamlQuote(w, package);
        try w.writeByte('\n');
    }
    // APT 源配置必须在 packages 前由 Subiquity 处理，不能交给 late-commands。
    // mirror-selection 中不限定架构（不写 arches），使 ARM64 与 AMD64 都探测
    // 本地 repository。Jammy ARM64 若使用 legacy `arches: [default]` 会被解释
    // 为 ports 的默认候选，导致即使 URI 指向 NodeForge 仍访问 ports.ubuntu.com。
    //
    // APT 失败策略（经 autoinstall-schema.json 确认）：
    // - fallback 由 install.apt.fallback 配置。默认 offline-install 在 mirror
    //   不完整时使用 squashfs；abort 用于强制验证 HTTP APT；continue-anyway
    //   仅透传 Subiquity 能力，不建议用于生产。
    // - geoip: false：关闭 geoIP 镜像检测，阻止 HTTP 请求到 ubuntu.com。
    // - 不使用 disable_suites：该字段是 curtin 的内部字段，不在 Subiquity 的
    //   autoinstall schema 中。Subiquity 会静默忽略它，导致所有默认 suite 仍
    //   被配置，apt-get update 因 404 返回失败。
    try w.writeAll("  apt:\n    mirror-selection:\n      primary:\n        - uri: ");
    try render.yamlQuote(w, apt_primary_url orelse "");
    try w.print("\n    fallback: {s}\n    geoip: false\n", .{@tagName(install.apt.fallback)});
    // 存储布局：使用 direct 模式，Subiquity 自行决定分区方案
    // 这比显式分区更安全，因为 Subiquity 会根据磁盘类型选择合适的方案
    try w.writeAll("  storage:\n    layout:\n      name: direct\n  late-commands:\n");
    // bundle 后处理步骤：通过 curtin in-target 在目标系统中执行
    if (bundle) |value| {
        // Ubuntu 使用 apt 包管理器
        const script = try runner.renderInstallPost(allocator, value, .apt);
        defer allocator.free(script);
        // curtin in-target 在 /target chroot 中执行命令
        // shell 脚本中的单引号需要转义（`'` → `'\''`），步骤换行符
        // 转为 `&&`，使整个脚本保持单行并保留失败状态。
        var command: std.Io.Writer.Allocating = .init(allocator);
        defer command.deinit();
        const command_writer = &command.writer;
        try command_writer.writeAll("curtin in-target --target=/target -- sh -c '");
        const trimmed_script = std.mem.trimEnd(u8, script, "\r\n");
        for (trimmed_script) |c| if (c == '\'') try command_writer.writeAll("'\\''") else if (c == '\n') try command_writer.writeAll(" && ") else try command_writer.writeByte(c);
        try command_writer.writeAll("'");
        try w.writeAll("    - ");
        try render.yamlQuote(w, command.written());
        try w.writeByte('\n');
    }
    // 事件上报：通过 curl 在目标系统中上报安装后阶段完成
    // 携带 capability token 和 session id 用于认证和关联
    // `|| true` 确保即使事件上报失败也不阻塞安装完成
    const event_command = try std.fmt.allocPrint(allocator, "curtin in-target --target=/target -- sh -c \"curl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d '{{\\\"v\\\":1,\\\"boot_session_id\\\":\\\"{s}\\\",\\\"stage\\\":\\\"post\\\"}}' {s} || true\"", .{ token, session, session, event_url });
    defer allocator.free(event_command);
    try w.writeAll("    - ");
    try render.yamlQuote(w, event_command);
    try w.writeByte('\n');
    // cloud-config 顶层配置（autoinstall 段外）：
    // 以下键由 cloud-init 自身模块读取，用于阻止隔离网段中的超时行为。
    // 它们必须位于 YAML 顶层（零缩进），不在 autoinstall: 段内。
    //
    // - ntp: { enabled: false }：禁用 cloud-init NTP 模块。隔离网段无 NTP
    //   服务器，cloud-init 会等待 NTP 同步超时，导致 Subiquity 显示
    //   "waiting for cloud-init"。
    // - package_update: false：禁用 cloud-init 的 apt-get update 步骤。
    //   apt 源已在 autoinstall.apt 中配置为 NodeForge 本地 URL，但
    //   cloud-init 的 package_update 仍可能触发额外网络操作。
    // - package_upgrade: false：禁用 cloud-init 的 apt-get upgrade 步骤。
    //   安装阶段不需要升级已安装的包。
    try w.writeAll("ntp:\n  enabled: false\npackage_update: false\npackage_upgrade: false\n");
    return out.toOwnedSlice();
}

/// 渲染 NoCloud-Net meta-data 文件。
///
/// NoCloud-Net 规范要求 HTTP 数据源在 `<base_url>/meta-data` 返回 YAML
/// 格式的实例元数据。Subiquity/cloud-init 使用其中的 `instance-id` 区分
/// 不同节点实例，`local-hostname` 设置初始主机名。
///
/// `instance-id` 以 `nodeforge-` 前缀加节点 ID 构成，确保每个节点有唯一
/// 的实例标识。如果两个节点使用相同的 `instance-id`，cloud-init 会认为
/// 是同一实例的重复启动，跳过首次初始化步骤。
///
/// NoCloud-Net 还会请求 `<base_url>/vendor-data`；即使为空也必须返回
/// HTTP 200（由 HTTP 路由的 `answerFixture` 处理），否则 cloud-init 会重试，
/// 增加约十秒无效等待。
pub fn renderMetaData(allocator: std.mem.Allocator, node: *const model.NodeConfig) ![]u8 {
    return std.fmt.allocPrint(allocator, "instance-id: nodeforge-{s}\nlocal-hostname: {s}\n", .{ node.id, render.hostname(node) });
}

// 测试：Autoinstall user-data 渲染正确性。
// 验证要点：
// - #cloud-config 头部存在（NoCloud 数据源要求）
// - autoinstall 段存在且包含 version: 1
// - late-commands 包含 curtin in-target 事件上报
// - APT mirror-selection 使用传入的 URL，而非 Subiquity 默认的 archive.ubuntu.com
// - fallback 默认 offline-install，并可由 profile 切换为严格 abort
// - disable_suites 不出现（不在 Subiquity schema 中，被静默忽略）
// - refresh-installer（不是 refresh）阻止 snap 刷新超时
// - timezone/locale 显式指定，阻止 geoIP 检测
// - cloud-config 顶层 ntp/package_update/package_upgrade 禁用网络操作
test "autoinstall has NoCloud header and late event hook" {
    const node: model.NodeConfig = .{ .id = "node-01", .mac = "00:11:22:33:44:55", .arch = .aarch64, .profile = "ubuntu" };
    const bytes = try renderUserData(std.testing.allocator, &node, .{ .packages = &.{"curl"} }, null, "http://repo", "http://event", "0123456789abcdef0123456789abcdef", "token");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "#cloud-config") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "autoinstall:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "late-commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "    - 'curtin in-target") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "uri: 'http://repo'") != null);
    // ARM64 必须使用 mirror-selection，而不是 legacy primary/default 匹配。
    try std.testing.expect(std.mem.indexOf(u8, bytes, "mirror-selection:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "fallback: offline-install") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "geoip: false") != null);
    // disable_suites 不在 Subiquity autoinstall schema 中，不能出现在输出里
    try std.testing.expect(std.mem.indexOf(u8, bytes, "disable_suites") == null);
    // 隔离网段防超时配置
    try std.testing.expect(std.mem.indexOf(u8, bytes, "refresh-installer:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "update: false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "timezone: UTC") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "locale: en_US.UTF-8") != null);
    // cloud-config 顶层键（零缩进，在 autoinstall 段外）
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\nntp:\n  enabled: false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\npackage_update: false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\npackage_upgrade: false") != null);
}

// 测试：apt 段在 apt_primary_url 为 null 时仍然渲染（空 uri）。
// 这阻止 Subiquity 回退到 archive.ubuntu.com/ports.ubuntu.com。
// 即使 URI 为空，默认 fallback: offline-install 仍能保证安装继续。
test "apt section is always rendered even when apt_primary_url is null" {
    const node: model.NodeConfig = .{ .id = "node-02", .mac = "00:11:22:33:44:66", .arch = .x86_64, .profile = "ubuntu" };
    const bytes = try renderUserData(std.testing.allocator, &node, .{}, null, null, "http://event", "0123456789abcdef0123456789abcdef", "token");
    defer std.testing.allocator.free(bytes);
    // 即使 apt_primary_url 为 null，apt 段也必须存在
    try std.testing.expect(std.mem.indexOf(u8, bytes, "apt:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "mirror-selection:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "primary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "fallback: offline-install") != null);
}

test "apt fallback is rendered from the install profile" {
    const node: model.NodeConfig = .{ .id = "node-strict", .mac = "00:11:22:33:44:88", .arch = .aarch64, .profile = "ubuntu" };
    const bytes = try renderUserData(std.testing.allocator, &node, .{ .apt = .{ .fallback = .abort } }, null, "http://repo", "http://event", "0123456789abcdef0123456789abcdef", "token");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "fallback: abort") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "fallback: offline-install") == null);
}

test "M4.1 autoinstall renders target defaults and static network" {
    const node: model.NodeConfig = .{ .id = "node-04", .mac = "00:11:22:33:44:99", .arch = .aarch64, .profile = "ubuntu", .ip = "192.168.50.27", .overrides = .{ .network = .{ .mode = .static, .interface = "ens160", .address = "192.168.50.27", .prefix_len = 24, .gateway = "192.168.50.1", .dns = &.{"192.168.50.1"}, .search_domains = &.{"nodeforge.local"} } } };
    const system: model.TargetSystemConfig = .{ .localization = .{ .locale = "zh_CN.UTF-8", .timezone = "Asia/Shanghai", .keyboard = "us" }, .connectivity = .{ .time_sync = true, .ntp_servers = &.{"ntp.nodeforge.local"} }, .users = &.{.{ .name = "admin", .password = "secret", .sudo = true }} };
    const bytes = try renderUserDataM41(std.testing.allocator, &node, .{}, system, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+ test", null, "http://192.168.50.1/artifacts/repositories/ubuntu", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "daemon:session:1", null);
    // report_url="" 表示未配置 subiquity-report 端点（不渲染 reporting 块）
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "locale: 'zh_CN.UTF-8'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "timezone: 'Asia/Shanghai'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "$6$") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "usermod --password ''$6$") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "addresses: ['192.168.50.27/24']") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "set-name: 'ens160'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "search: ['nodeforge.local']") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "NTP=ntp.nodeforge.local") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "servers:\n    - 'ntp.nodeforge.local'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "early-commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "http://facts") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "product_serial") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "error-commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "--data-urlencode \"summary=$SUMMARY\"") != null);
    // reporting 块不渲染（report_url 为空时跳过）
    try std.testing.expect(std.mem.indexOf(u8, bytes, "reporting:") == null);
    // curl 回调中仍含 Authorization: Bearer header（降级路径）
    try std.testing.expect(std.mem.indexOf(u8, bytes, "Authorization: Bearer token") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "archive.ubuntu.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "99-nodeforge.cfg") == null);
}

test "M4.2 webhook reporting rendered when report_url is non-empty" {
    // 非空 report_url 渲染 reporting 块（webhook reporter 在 22.04 和 24.04 均可用）
    const node: model.NodeConfig = .{ .id = "node-rpt", .mac = "00:11:22:33:44:aa", .arch = .aarch64, .profile = "ubuntu", .hostname = "noderpt" };
    const bytes = try renderUserDataM41(std.testing.allocator, &node, .{}, .{}, "ssh-key", null, "http://repo", "http://facts", "http://event", "http://log", "http://192.168.50.1:8080/report", "0123456789abcdef0123456789abcdef", "token", "scope", null);
    defer std.testing.allocator.free(bytes);
    // reporting 块应渲染，type 必须是 webhook（不是 http）
    try std.testing.expect(std.mem.indexOf(u8, bytes, "reporting:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "type: webhook") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "type: http") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "endpoint:") != null);
    // 不应渲染 headers 字段（webhook handler 不支持）
    try std.testing.expect(std.mem.indexOf(u8, bytes, "headers:") == null);
    // hostname 应始终渲染
    try std.testing.expect(std.mem.indexOf(u8, bytes, "hostname: 'noderpt'") != null);
}

test "M4.2 hostname always rendered even without users" {
    // 显式空 users 保留 root-only；目标 hostname 必须位于 autoinstall.user-data。
    const node: model.NodeConfig = .{ .id = "node-nh", .mac = "00:11:22:33:44:bb", .arch = .aarch64, .profile = "ubuntu", .hostname = "myhost" };
    const bytes = try renderUserDataM41(std.testing.allocator, &node, .{}, .{ .users = &.{} }, "ssh-key", null, "http://repo", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "scope", null);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "  user-data:\n    hostname: 'myhost'\n    preserve_hostname: false\n    disable_root: false") != null);
    // identity 不应出现（无 users）
    try std.testing.expect(std.mem.indexOf(u8, bytes, "identity:") == null);
}

test "M4.2 autoinstall renders default nodeforge identity" {
    const node: model.NodeConfig = .{ .id = "node-default", .mac = "00:11:22:33:44:bc", .arch = .aarch64, .profile = "ubuntu", .hostname = "ubuntu-default" };
    const bytes = try renderUserDataM41(std.testing.allocator, &node, .{}, .{}, "ssh-key", null, "http://repo", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "scope", null);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "identity:\n    hostname: 'ubuntu-default'\n    username: 'nodeforge'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "name: 'nodeforge'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "groups: [sudo]") != null);
}

test "M4.6 autoinstall persists literal kernel args in GRUB drop-in" {
    const node: model.NodeConfig = .{ .id = "node-kargs", .mac = "00:11:22:33:44:bd", .arch = .aarch64, .profile = "ubuntu" };
    const bytes = try renderUserDataM41(std.testing.allocator, &node, .{}, .{}, "ssh-key", null, "http://repo", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "scope", "iommu=pt hugepages=4");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/target/etc/default/grub.d/99-nodeforge.cfg") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "GRUB_CMDLINE_LINUX=\"${GRUB_CMDLINE_LINUX} iommu=pt hugepages=4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "chmod 0644") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "curtin in-target --target=/target -- update-grub") != null);
}

test "late command keeps managed files single-line and fail-fast" {
    const node: model.NodeConfig = .{ .id = "node-03", .mac = "00:11:22:33:44:77", .arch = .aarch64, .profile = "ubuntu" };
    const bundle: model.ProvisioningBundle = .{ .name = "base", .steps = &.{
        .{ .name = "packages", .action = .standard_packages, .packages = &.{"curl"} },
        .{ .name = "hosts", .action = .managed_file, .destination = "/etc/hosts.d/nodeforge", .content = "127.0.0.1 localhost\n" },
    } };
    const bytes = try renderUserData(std.testing.allocator, &node, .{}, &bundle, "http://repo", "http://event", "0123456789abcdef0123456789abcdef", "token");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "NODEFORGE_EOF") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, " && install -d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "printf") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "%b") != null);
}
