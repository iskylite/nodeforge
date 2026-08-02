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

/// 测试夹具将共享 system 字段投影为 canonical software 输入；所有断言最终
/// 覆盖唯一的 `renderEffective`，不会重新引入简化版 Autoinstall 路径。
fn renderTestFixture(allocator: std.mem.Allocator, node: *const model.NodeConfig, install: model.InstallConfig, system: model.TargetSystemConfig, bootstrap_key: []const u8, bundle: ?*const model.ProvisioningBundle, apt_primary_url: ?[]const u8, facts_url: []const u8, event_url: []const u8, log_url: []const u8, report_url: []const u8, session: []const u8, token: []const u8, password_scope: []const u8, kernel_args: ?[]const u8) ![]u8 {
    const network = node.network;
    const software: model.SoftwareSelection = .{ .packages = .{ .include = system.packages } };
    return renderEffective(allocator, node, install, system, network, software, bootstrap_key, bundle, apt_primary_url, facts_url, event_url, log_url, report_url, session, token, password_scope, kernel_args);
}

/// 从已编译的唯一 effective plan 渲染 Ubuntu Autoinstall。Profile、Node
/// override、软件选择和目标网络必须在进入 adapter 前完成合并与校验。
pub fn renderEffective(allocator: std.mem.Allocator, node: *const model.NodeConfig, install: model.InstallConfig, system: model.TargetSystemConfig, network: model.TargetNetworkConfig, software: model.SoftwareSelection, bootstrap_key: []const u8, bundle: ?*const model.ProvisioningBundle, apt_primary_url: ?[]const u8, facts_url: []const u8, event_url: []const u8, log_url: []const u8, report_url: []const u8, session: []const u8, token: []const u8, password_scope: []const u8, kernel_args: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("#cloud-config\nautoinstall:\n  version: 1\n  interactive-sections: []\n  shutdown: ");
    try w.writeAll(if (install.completion.action == .reboot) "reboot" else "poweroff");
    try w.writeAll("\n  refresh-installer:\n    update: false\n  locale: ");
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
    if (bundleHasInstallPostArchive(bundle)) try w.writeAll("    - 'tar'\n");
    for (software.tasks) |task| {
        try w.writeAll("    - ");
        const task_name = try std.fmt.allocPrint(allocator, "{s}^", .{task});
        defer allocator.free(task_name);
        try render.yamlQuote(w, task_name);
        try w.writeByte('\n');
    }
    for (software.packages.include) |package| {
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
    if (install.proxy.url) |proxy| {
        try w.writeAll("  proxy: ");
        try render.yamlQuote(w, proxy);
        try w.writeByte('\n');
    }
    if (install.updates.mode != .none) try w.print("  updates: {s}\n", .{@tagName(install.updates.mode)});
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
    // 认证通过源 IP 校验：/api/v1/nodes/:id/installer-hooks/subiquity 端点检查请求来源 IP 匹配节点 DHCP lease。
    // OAuth（consumer_key/consumer_secret/token_key/token_secret）全部省略时为无认证 POST。
    //
    // webhook POST 的 JSON 事件格式（ReportingEvent.as_dict）：
    //   {"name":"<stage>","description":"<msg>","event_type":"start|finish|result",
    //    "origin":"curtin","timestamp":1234567890.0,"level":"INFO"}
    // finish 事件额外含 "result":"SUCCESS|WARN|FAIL"。
    //
    // report_url 为空时不渲染 reporting 块（调用方未配置 installer-hooks/subiquity 端点时）。
    // ──────────────────────────────────────────────────────────────
    if (report_url.len > 0) {
        try w.writeAll("  reporting:\n    nodeforge:\n      type: webhook\n      endpoint: ");
        try render.yamlQuote(w, report_url);
        try w.writeAll("\n      level: INFO\n");
    }
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
        if (network.gateway != null or network.routes.len != 0) {
            try w.writeAll("        routes:\n");
            if (network.gateway) |gateway| {
                try w.writeAll("          - to: default\n            via: ");
                try render.yamlQuote(w, gateway);
                try w.writeByte('\n');
            }
            for (network.routes) |route| {
                try w.writeAll("          - to: ");
                try render.yamlQuote(w, route.destination);
                try w.writeAll("\n            via: ");
                try render.yamlQuote(w, route.gateway);
                if (route.metric) |metric| try w.print("\n            metric: {d}", .{metric});
                try w.writeByte('\n');
            }
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
    try renderCloudUser(w, allocator, "root", system.ssh.root_password, false, &.{}, bootstrap_key, system.ssh.root_authorized_keys, password_scope);
    for (system.users) |user| try renderCloudUser(w, allocator, user.name, user.password, user.sudo, user.groups, bootstrap_key, user.ssh_authorized_keys, password_scope);
    try w.writeAll("  early-commands:\n");
    const facts_command = try std.fmt.allocPrint(allocator, "nf_fact() {{ test -r /sys/class/dmi/id/$1 && head -c 256 /sys/class/dmi/id/$1 | tr -d '\\r\\n' | sed 's/\\\\/\\\\\\\\/g;s/\"/\\\\\"/g'; }}; s=$(nf_fact product_serial); u=$(nf_fact product_uuid); v=$(nf_fact sys_vendor); m=$(nf_fact product_name); k=$(awk '$1 == \"MemTotal:\" {{ print $2; exit }}' /proc/meminfo); case \"$k\" in ''|*[!0-9]*) k=0;; esac; b=$((k * 1024)); d=$(printf '{{\"serial_number\":\"%s\",\"product_uuid\":\"%s\",\"vendor\":\"%s\",\"model\":\"%s\",\"memory_bytes\":%s}}' \"$s\" \"$u\" \"$v\" \"$m\" \"$b\"); curl -fsS -H 'Authorization: Bearer {s}' -H 'X-NodeForge-Session: {s}' -H 'Content-Type: application/json' -d \"$d\" {s} || true", .{ token, session, facts_url });
    defer allocator.free(facts_command);
    try w.writeAll("    - ");
    try render.yamlQuote(w, facts_command);
    try w.writeByte('\n');
    try w.print("    - 'curl -fsS -H \"Authorization: Bearer {s}\" -H \"X-NodeForge-Session: {s}\" -H \"Content-Type: application/json\" -d \"{{\\\"v\\\":1,\\\"boot_session_id\\\":\\\"{s}\\\",\\\"stage\\\":\\\"installer_started\\\"}}\" {s} || true'\n", .{ token, session, session, event_url });
    try w.print("    - 'curl -fsS -H \"Authorization: Bearer {s}\" -H \"X-NodeForge-Session: {s}\" -H \"Content-Type: application/json\" -d \"{{\\\"v\\\":1,\\\"boot_session_id\\\":\\\"{s}\\\",\\\"stage\\\":\\\"started\\\"}}\" {s} || true'\n", .{ token, session, session, event_url });
    try w.writeAll("  late-commands:\n");
    // Subiquity's offline-install fallback may restore Ubuntu's public mirrors
    // in the target even when mirror-selection points at NodeForge. Persist the
    // imported repository explicitly from the ISO's signed Release metadata so
    // the installed system has the same local-only repository contract as the
    // effective plan and the diskless node-apply path. When
    // install.apt.preserve_sources_list is enabled, the installer/ISO-written
    // sources are kept and the managed repository is added alongside.
    if (apt_primary_url) |url| {
        const apt_source = try std.fmt.allocPrint(
            allocator,
            "set -eu; d=''; for x in /cdrom/dists/*; do test -f \"$x/Release\" && d=\"$x\" && break; done; test -n \"$d\"; suite=$(basename \"$d\"); components=$(awk '/^Components:/ {{ $1=\"\"; sub(/^ /,\"\"); print; exit }}' \"$d/Release\"); test -n \"$components\"; mkdir -p /target/etc/apt/sources.list.d; {s}printf 'deb [trusted=yes] {s} %s %s\\n' \"$suite\" \"$components\" > /target/etc/apt/sources.list.d/nodeforge.list; chmod 0644 /target/etc/apt/sources.list.d/nodeforge.list",
            .{ if (install.apt.preserve_sources_list) "" else "rm -f /target/etc/apt/sources.list /target/etc/apt/sources.list.d/*.list /target/etc/apt/sources.list.d/*.sources; ", url },
        );
        defer allocator.free(apt_source);
        try w.writeAll("    - ");
        try render.yamlQuote(w, apt_source);
        try w.writeByte('\n');
    }
    if (system.import_host_hosts) {
        if (system.hosts_content) |hosts| {
            try w.writeAll("    - ");
            var command: std.Io.Writer.Allocating = .init(allocator);
            defer command.deinit();
            // Encode content as base64 to avoid YAML newline folding.
            // YAML single-quoted flow scalars fold literal newlines into spaces,
            // so heredocs and multi-line content must be encoded.
            const content = if (hosts.len > 0 and hosts[hosts.len - 1] != '\n')
                try std.fmt.allocPrint(allocator, "{s}\n", .{hosts})
            else
                try allocator.dupe(u8, hosts);
            defer allocator.free(content);
            const encoder = std.base64.standard;
            const encoded_len = encoder.Encoder.calcSize(content.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = encoder.Encoder.encode(encoded, content);
            try command.writer.print("printf '%s' '{s}' | base64 -d > /target/etc/hosts && chmod 0644 /target/etc/hosts", .{encoded});
            try render.yamlQuote(w, command.written());
            try w.writeByte('\n');
        }
    }
    if (install.completion.action == .halt) try w.writeAll("    - 'printf \"[Unit]\\nDescription=Halt after NodeForge install\\n[Service]\\nType=oneshot\\nExecStart=/usr/bin/systemctl halt\\n[Install]\\nWantedBy=multi-user.target\\n\" > /target/etc/systemd/system/nodeforge-halt-after-install.service && curtin in-target --target=/target -- systemctl enable nodeforge-halt-after-install.service'\n");
    if (system.security.apparmor == .disabled) try w.writeAll("    - 'curtin in-target --target=/target -- systemctl disable --now apparmor || true'\n") else if (system.security.apparmor == .complain) try w.writeAll("    - 'curtin in-target --target=/target -- aa-complain /etc/apparmor.d/* || true'\n") else try w.writeAll("    - 'curtin in-target --target=/target -- aa-enforce /etc/apparmor.d/* || true'\n");
    if (install.proxy.no_proxy.len != 0) {
        var no_proxy: std.Io.Writer.Allocating = .init(allocator);
        defer no_proxy.deinit();
        for (install.proxy.no_proxy, 0..) |value, index| {
            if (index != 0) try no_proxy.writer.writeByte(',');
            try no_proxy.writer.writeAll(value);
        }
        const command = try std.fmt.allocPrint(allocator, "printf '%s\\n' 'no_proxy={s}' > /target/etc/environment.d/60-nodeforge-proxy.conf", .{no_proxy.written()});
        defer allocator.free(command);
        try w.writeAll("    - ");
        try render.yamlQuote(w, command);
        try w.writeByte('\n');
    }
    for (system.users) |user| {
        if (user.uid) |uid| try w.print("    - 'curtin in-target --target=/target -- usermod --uid {d} {s}'\n", .{ uid, user.name });
        if (user.shell) |shell| try w.print("    - 'curtin in-target --target=/target -- usermod --shell {s} {s}'\n", .{ shell, user.name });
        if (user.locked) try w.print("    - 'curtin in-target --target=/target -- usermod --lock {s}'\n", .{user.name});
    }
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
        const sshd = try std.fmt.allocPrint(allocator, "printf '%s\\n' 'PermitRootLogin {s}' 'PasswordAuthentication {s}' > /target/etc/ssh/sshd_config.d/00-nodeforge.conf", .{ root_login, if (system.ssh.password_authentication) "yes" else "no" });
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
        const script = try runner.renderInstallPostInstrumented(allocator, value, .apt, .{
            .event_url = event_url,
            .token = token,
            .boot_session_id = session,
        });
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

fn bundleHasInstallPostArchive(bundle: ?*const model.ProvisioningBundle) bool {
    const value = bundle orelse return false;
    for (value.steps) |step| if (step.phase == .install_post and step.action == .archive) return true;
    return false;
}

/// 渲染绑定到 `boot_disk` 的受约束 direct 布局，或显式 curtin action graph。
/// 防止 profile 选择的目标磁盘/分区被 Subiquity 静默丢弃。
fn renderStorageM41(w: *std.Io.Writer, install: model.InstallConfig) !void {
    if (install.storage.partitions.len == 0) {
        return renderAutomaticStorage(w, install.storage);
    }
    return renderCustomStorage(w, install.storage);
}

fn renderCustomStorage(w: *std.Io.Writer, storage: model.StorageConfig) !void {
    const members = storage.members;
    try w.writeAll("  storage:\n    config:\n");
    for (members, 0..) |disk, index| {
        try w.print("      - type: disk\n        id: nodeforge-disk-{d}\n        path: ", .{index});
        try render.yamlQuote(w, disk);
        try w.writeAll("\n        ptable: gpt\n        wipe: superblock-recursive\n        preserve: false\n");
    }
    for (storage.partitions) |part| if (part.kind == .esp) try curtinPhysical(w, part, 0, true);
    switch (storage.mode) {
        .single => for (storage.partitions) |part| if (part.kind != .esp) try curtinPhysical(w, part, 0, true),
        .lvm => {
            for (storage.partitions) |part| if (part.kind == .boot) try curtinPhysical(w, part, 0, true);
            try w.writeAll("      - type: partition\n        id: nodeforge-pv-part\n        device: nodeforge-disk-0\n        size: -1\n      - type: lvm_volgroup\n        id: nodeforge-vg\n        name: nodeforge\n        devices: [nodeforge-pv-part]\n");
            for (storage.partitions) |part| if (part.kind != .esp and part.kind != .boot) try curtinLogical(w, part);
        },
        else => {
            for (storage.partitions) |part| if (part.kind == .boot) try curtinRaidVolume(w, part, members.len, "1", true);
            if (isRaidLvm(storage.mode)) {
                for (members, 0..) |_, index| try physicalPartition(w, "pv", index, "-1");
                try raidAction(w, "pv", curtinRaidLevel(storage.mode), members.len);
                try w.writeAll("      - type: lvm_volgroup\n        id: nodeforge-vg\n        name: nodeforge\n        devices: [nodeforge-pv-raid]\n");
                for (storage.partitions) |part| if (part.kind != .esp and part.kind != .boot) try curtinLogical(w, part);
            } else for (storage.partitions) |part| if (part.kind != .esp and part.kind != .boot) try curtinRaidVolume(w, part, members.len, curtinRaidLevel(storage.mode), true);
        },
    }
}

fn curtinPhysical(w: *std.Io.Writer, part: model.PartitionConfig, disk: usize, format: bool) !void {
    const id = part.id orelse return error.InvalidPartition;
    try w.print("      - type: partition\n        id: nodeforge-{s}-part\n        device: nodeforge-disk-{d}\n        size: ", .{ id, disk });
    try curtinSize(w, part);
    try w.writeByte('\n');
    if (part.kind == .esp) try w.writeAll("        flag: boot\n        grub_device: true\n");
    if (format) {
        var volume: [128]u8 = undefined;
        try curtinFormatMount(w, part, try std.fmt.bufPrint(&volume, "nodeforge-{s}-part", .{id}));
    }
}
fn curtinLogical(w: *std.Io.Writer, part: model.PartitionConfig) !void {
    const id = part.id orelse return error.InvalidPartition;
    try w.print("      - type: lvm_partition\n        id: nodeforge-{s}-lv\n        name: {s}\n        volgroup: nodeforge-vg\n        size: ", .{ id, id });
    try curtinSize(w, part);
    try w.writeByte('\n');
    var volume: [128]u8 = undefined;
    try curtinFormatMount(w, part, try std.fmt.bufPrint(&volume, "nodeforge-{s}-lv", .{id}));
}
fn curtinRaidVolume(w: *std.Io.Writer, part: model.PartitionConfig, count: usize, level: []const u8, format: bool) !void {
    const id = part.id orelse return error.InvalidPartition;
    for (0..count) |index| {
        try w.print("      - type: partition\n        id: nodeforge-{s}-part-{d}\n        device: nodeforge-disk-{d}\n        size: ", .{ id, index, index });
        try curtinSize(w, part);
        try w.writeByte('\n');
    }
    try w.print("      - type: raid\n        id: nodeforge-{s}-raid\n        name: md-{s}\n        raidlevel: {s}\n        devices:\n", .{ id, id, level });
    for (0..count) |index| try w.print("          - nodeforge-{s}-part-{d}\n", .{ id, index });
    if (format) {
        var volume: [128]u8 = undefined;
        try curtinFormatMount(w, part, try std.fmt.bufPrint(&volume, "nodeforge-{s}-raid", .{id}));
    }
}
fn curtinFormatMount(w: *std.Io.Writer, part: model.PartitionConfig, volume: []const u8) !void {
    const id = part.id orelse return error.InvalidPartition;
    const fs = part.filesystem orelse switch (part.kind) {
        .esp => "fat32",
        .swap => "swap",
        else => "ext4",
    };
    try w.print("      - type: format\n        id: nodeforge-{s}-format\n        volume: {s}\n        fstype: {s}\n", .{ id, volume, fs });
    const mount = part.mount orelse switch (part.kind) {
        .root => "/",
        .boot => "/boot",
        .esp => "/boot/efi",
        else => null,
    };
    if (mount) |path| {
        try w.print("      - type: mount\n        id: nodeforge-{s}-mount\n        device: nodeforge-{s}-format\n        path: ", .{ id, id });
        try render.yamlQuote(w, path);
        try w.writeByte('\n');
    }
}
fn curtinSize(w: *std.Io.Writer, part: model.PartitionConfig) !void {
    if (part.grow) try w.writeAll("-1") else try w.print("{d}", .{@as(u64, part.size_mib) * 1024 * 1024});
}

fn renderAutomaticStorage(w: *std.Io.Writer, storage: model.StorageConfig) !void {
    const members = storage.members;
    if (members.len == 0) return error.InvalidStorageMembers;
    try w.writeAll("  storage:\n    config:\n");
    for (members, 0..) |disk, index| {
        try w.print("      - type: disk\n        id: nodeforge-disk-{d}\n        path: ", .{index});
        try render.yamlQuote(w, disk);
        try w.writeAll("\n        ptable: gpt\n        wipe: superblock-recursive\n        preserve: false\n");
    }
    try w.writeAll("      - type: partition\n        id: nodeforge-esp-part\n        device: nodeforge-disk-0\n        size: 1G\n        flag: boot\n        grub_device: true\n");
    try w.writeAll("      - type: format\n        id: nodeforge-esp-format\n        volume: nodeforge-esp-part\n        fstype: fat32\n      - type: mount\n        id: nodeforge-esp-mount\n        device: nodeforge-esp-format\n        path: /boot/efi\n");
    switch (storage.mode) {
        .single => {
            try physicalPartition(w, "boot", 0, "2G");
            try formatMount(w, "boot", "ext4", "/boot");
            try physicalPartition(w, "root", 0, "-1");
            try formatMount(w, "root", "ext4", "/");
        },
        .lvm => {
            try physicalPartition(w, "boot", 0, "2G");
            try formatMount(w, "boot", "ext4", "/boot");
            try physicalPartition(w, "pv", 0, "-1");
            try w.writeAll("      - type: lvm_volgroup\n        id: nodeforge-vg\n        name: nodeforge\n        devices: [nodeforge-pv-part-0]\n      - type: lvm_partition\n        id: nodeforge-root-lv\n        name: root\n        volgroup: nodeforge-vg\n        size: -1\n      - type: format\n        id: nodeforge-root-format\n        volume: nodeforge-root-lv\n        fstype: ext4\n      - type: mount\n        id: nodeforge-root-mount\n        device: nodeforge-root-format\n        path: /\n");
        },
        else => {
            for (members, 0..) |_, index| try physicalPartition(w, "boot", index, "2G");
            try raidAction(w, "boot", "1", members.len);
            try w.writeAll("      - type: format\n        id: nodeforge-boot-format\n        volume: nodeforge-boot-raid\n        fstype: ext4\n      - type: mount\n        id: nodeforge-boot-mount\n        device: nodeforge-boot-format\n        path: /boot\n");
            for (members, 0..) |_, index| try physicalPartition(w, "root", index, "-1");
            try raidAction(w, "root", curtinRaidLevel(storage.mode), members.len);
            if (isRaidLvm(storage.mode)) {
                try w.writeAll("      - type: lvm_volgroup\n        id: nodeforge-vg\n        name: nodeforge\n        devices: [nodeforge-root-raid]\n      - type: lvm_partition\n        id: nodeforge-root-lv\n        name: root\n        volgroup: nodeforge-vg\n        size: -1\n      - type: format\n        id: nodeforge-root-format\n        volume: nodeforge-root-lv\n        fstype: ext4\n");
            } else try w.writeAll("      - type: format\n        id: nodeforge-root-format\n        volume: nodeforge-root-raid\n        fstype: ext4\n");
            try w.writeAll("      - type: mount\n        id: nodeforge-root-mount\n        device: nodeforge-root-format\n        path: /\n");
        },
    }
}

fn physicalPartition(w: *std.Io.Writer, comptime name: []const u8, disk: usize, size: []const u8) !void {
    try w.print("      - type: partition\n        id: nodeforge-{s}-part-{d}\n        device: nodeforge-disk-{d}\n        size: {s}\n", .{ name, disk, disk, size });
}

fn formatMount(w: *std.Io.Writer, comptime name: []const u8, fs: []const u8, path: []const u8) !void {
    try w.print("      - type: format\n        id: nodeforge-{s}-format\n        volume: nodeforge-{s}-part-0\n        fstype: {s}\n      - type: mount\n        id: nodeforge-{s}-mount\n        device: nodeforge-{s}-format\n        path: {s}\n", .{ name, name, fs, name, name, path });
}

fn raidAction(w: *std.Io.Writer, comptime name: []const u8, level: []const u8, count: usize) !void {
    try w.print("      - type: raid\n        id: nodeforge-{s}-raid\n        name: md-{s}\n        raidlevel: {s}\n        devices:\n", .{ name, name, level });
    for (0..count) |index| try w.print("          - nodeforge-{s}-part-{d}\n", .{ name, index });
}

fn isRaidLvm(mode: model.StorageMode) bool {
    return switch (mode) {
        .@"raid0-lvm", .@"raid1-lvm", .@"raid5-lvm", .@"raid6-lvm", .@"raid10-lvm" => true,
        else => false,
    };
}

fn curtinRaidLevel(mode: model.StorageMode) []const u8 {
    return switch (mode) {
        .raid0, .@"raid0-lvm" => "0",
        .raid1, .@"raid1-lvm" => "1",
        .raid5, .@"raid5-lvm" => "5",
        .raid6, .@"raid6-lvm" => "6",
        .raid10, .@"raid10-lvm" => "10",
        else => unreachable,
    };
}

test "automatic storage renders all modes with native Curtin actions" {
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
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "id: nodeforge-esp-part"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "flag: boot"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "grub_device: true"));
        try std.testing.expectEqual(count, std.mem.count(u8, bytes, "type: disk"));
        try std.testing.expect(std.mem.indexOf(u8, bytes, "fstype: ext4") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "late-commands") == null);
        if (mode != .single and mode != .lvm) {
            try std.testing.expect(std.mem.indexOf(u8, bytes, "type: raid") != null);
            var level: [24]u8 = undefined;
            const expected = try std.fmt.bufPrint(&level, "raidlevel: {s}", .{curtinRaidLevel(mode)});
            try std.testing.expect(std.mem.indexOf(u8, bytes, expected) != null);
        }
        if (mode == .lvm or isRaidLvm(mode)) try std.testing.expect(std.mem.indexOf(u8, bytes, "type: lvm_volgroup") != null);
        if (mode == .lvm) {
            try std.testing.expect(std.mem.indexOf(u8, bytes, "id: nodeforge-pv-part-0") != null);
            try std.testing.expect(std.mem.indexOf(u8, bytes, "devices: [nodeforge-pv-part-0]") != null);
        }
    }
}

test "custom logical layout renders all modes natively in Curtin" {
    const modes = [_]model.StorageMode{ .single, .lvm, .raid0, .raid1, .raid5, .raid6, .raid10, .@"raid0-lvm", .@"raid1-lvm", .@"raid5-lvm", .@"raid6-lvm", .@"raid10-lvm" };
    const disks = [_][]const u8{ "/dev/sda", "/dev/sdb", "/dev/sdc", "/dev/sdd" };
    const partitions = [_]model.PartitionConfig{ .{ .id = "esp", .mount = "/boot/efi", .filesystem = "fat32", .size_mib = 1024, .kind = .esp }, .{ .id = "boot", .mount = "/boot", .filesystem = "ext4", .size_mib = 2048, .kind = .boot }, .{ .id = "var", .mount = "/var", .filesystem = "ext4", .size_mib = 8192 }, .{ .id = "root", .mount = "/", .filesystem = "ext4", .grow = true, .kind = .root } };
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
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "id: nodeforge-esp-part"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "flag: boot"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "grub_device: true"));
        try std.testing.expectEqual(count, std.mem.count(u8, bytes, "type: disk"));
        try std.testing.expect(std.mem.indexOf(u8, bytes, "late-commands") == null and std.mem.indexOf(u8, bytes, "storage-script") == null);
        if (mode == .lvm or isRaidLvm(mode)) try std.testing.expect(std.mem.indexOf(u8, bytes, "id: nodeforge-var-lv") != null);
        if (mode != .single and mode != .lvm) try std.testing.expect(std.mem.indexOf(u8, bytes, "id: nodeforge-boot-raid") != null);
    }
}

fn renderCloudUser(w: *std.Io.Writer, allocator: std.mem.Allocator, name: []const u8, password: ?[]const u8, sudo: bool, groups: []const []const u8, bootstrap_key: []const u8, keys: []const []const u8, session: []const u8) !void {
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
    if (sudo or groups.len != 0) {
        try w.writeAll("\n        groups: [");
        var first = true;
        if (sudo) {
            try w.writeAll("sudo");
            first = false;
        }
        for (groups) |group| {
            if (sudo and std.mem.eql(u8, group, "sudo")) continue;
            if (!first) try w.writeAll(", ");
            try render.yamlQuote(w, group);
            first = false;
        }
        try w.writeByte(']');
    }
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
    const bytes = try renderTestFixture(std.testing.allocator, &node, .{}, .{}, "ssh-key", null, "http://repo", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "scope", null);
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/target/etc/apt/sources.list.d/nodeforge.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "deb [trusted=yes] http://repo %s %s") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/cdrom/dists/*") != null);
    // 默认（preserve_sources_list=false）：late-command 删除安装器/ISO 写入的
    // 原有源，只保留 NodeForge 受管源。
    try std.testing.expect(std.mem.indexOf(u8, bytes, "rm -f /target/etc/apt/sources.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/target/etc/apt/sources.list.d/*.sources") != null);
    // disable_suites 不在 Subiquity autoinstall schema 中，不能出现在输出里
    try std.testing.expect(std.mem.indexOf(u8, bytes, "disable_suites") == null);
    // 隔离网段防超时配置
    try std.testing.expect(std.mem.indexOf(u8, bytes, "refresh-installer:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "update: false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "timezone: 'UTC'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "locale: 'en_US.UTF-8'") != null);
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
    const bytes = try renderTestFixture(std.testing.allocator, &node, .{}, .{}, "ssh-key", null, null, "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "scope", null);
    defer std.testing.allocator.free(bytes);
    // 即使 apt_primary_url 为 null，apt 段也必须存在
    try std.testing.expect(std.mem.indexOf(u8, bytes, "apt:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "mirror-selection:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "primary:") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "fallback: offline-install") != null);
}

test "apt fallback is rendered from the install profile" {
    const node: model.NodeConfig = .{ .id = "node-strict", .mac = "00:11:22:33:44:88", .arch = .aarch64, .profile = "ubuntu" };
    const bytes = try renderTestFixture(std.testing.allocator, &node, .{ .apt = .{ .fallback = .abort } }, .{}, "ssh-key", null, "http://repo", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "scope", null);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "fallback: abort") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "fallback: offline-install") == null);
}

test "preserve_sources_list keeps the original target sources in the late command" {
    const node: model.NodeConfig = .{ .id = "node-preserve", .mac = "00:11:22:33:44:cc", .arch = .aarch64, .profile = "ubuntu" };
    const bytes = try renderTestFixture(std.testing.allocator, &node, .{ .apt = .{ .preserve_sources_list = true } }, .{}, "ssh-key", null, "http://repo", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "scope", null);
    defer std.testing.allocator.free(bytes);
    // preserve=true：late-command 不再删除原有源，只附加 NodeForge 受管源。
    try std.testing.expect(std.mem.indexOf(u8, bytes, "rm -f /target/etc/apt/sources.list") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/target/etc/apt/sources.list.d/*.list") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/target/etc/apt/sources.list.d/*.sources") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/target/etc/apt/sources.list.d/nodeforge.list") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "deb [trusted=yes] http://repo %s %s") != null);
}

test "M4.1 autoinstall renders target defaults and static network" {
    const node: model.NodeConfig = .{ .id = "node-04", .mac = "00:11:22:33:44:99", .arch = .aarch64, .profile = "ubuntu", .pxe = .{ .ip_reservation = "192.168.50.27" }, .network = .{ .mode = .static, .interface = "ens160", .address = "192.168.50.27", .prefix_len = 24, .gateway = "192.168.50.1", .dns = &.{"192.168.50.1"}, .search_domains = &.{"nodeforge.local"} } };
    const system: model.TargetSystemConfig = .{ .localization = .{ .locale = "zh_CN.UTF-8", .timezone = "Asia/Shanghai", .keyboard = "us" }, .connectivity = .{ .time_sync = true, .ntp_servers = &.{"ntp.nodeforge.local"} }, .users = &.{.{ .name = "admin", .password = "secret", .sudo = true }} };
    const bytes = try renderTestFixture(std.testing.allocator, &node, .{}, system, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE8w9Aw2QE0Wqg1MUJELZyaLlRC4V1hD2dNBo6w+ test", null, "http://192.168.50.1/artifacts/repositories/ubuntu", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "daemon:session:1", null);
    // report_url="" 表示未配置 installer-hooks/subiquity 端点（不渲染 reporting 块）
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"memory_bytes\":%s") != null);
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
    const bytes = try renderTestFixture(std.testing.allocator, &node, .{}, .{}, "ssh-key", null, "http://repo", "http://facts", "http://event", "http://log", "http://192.168.50.1:18080/report", "0123456789abcdef0123456789abcdef", "token", "scope", null);
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
    const bytes = try renderTestFixture(std.testing.allocator, &node, .{}, .{ .users = &.{} }, "ssh-key", null, "http://repo", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "scope", null);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "  user-data:\n    hostname: 'myhost'\n    preserve_hostname: false\n    disable_root: false") != null);
    // identity 不应出现（无 users）
    try std.testing.expect(std.mem.indexOf(u8, bytes, "identity:") == null);
}

test "M4.2 autoinstall renders default nodeforge identity" {
    const node: model.NodeConfig = .{ .id = "node-default", .mac = "00:11:22:33:44:bc", .arch = .aarch64, .profile = "ubuntu", .hostname = "ubuntu-default" };
    const bytes = try renderTestFixture(std.testing.allocator, &node, .{}, .{}, "ssh-key", null, "http://repo", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "scope", null);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "identity:\n    hostname: 'ubuntu-default'\n    username: 'nodeforge'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "name: 'nodeforge'") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "groups: [sudo]") != null);
}

test "M4.6 autoinstall persists literal kernel args in GRUB drop-in" {
    const node: model.NodeConfig = .{ .id = "node-kargs", .mac = "00:11:22:33:44:bd", .arch = .aarch64, .profile = "ubuntu" };
    const bytes = try renderTestFixture(std.testing.allocator, &node, .{}, .{}, "ssh-key", null, "http://repo", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "scope", "iommu=pt hugepages=4");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "/target/etc/default/grub.d/99-nodeforge.cfg") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "GRUB_CMDLINE_LINUX=\"${GRUB_CMDLINE_LINUX} iommu=pt hugepages=4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "chmod 0644") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "curtin in-target --target=/target -- update-grub") != null);
}

test "late command keeps managed files single-line and fail-fast" {
    const node: model.NodeConfig = .{ .id = "node-03", .mac = "00:11:22:33:44:77", .arch = .aarch64, .profile = "ubuntu" };
    const bundle: model.ProvisioningBundle = .{ .name = "base", .steps = &.{
        .{ .name = "packages", .action = .package, .packages = &.{"curl"} },
        .{ .name = "hosts", .action = .managed_file, .destination = "/etc/hosts.d/nodeforge", .content = "127.0.0.1 localhost\n" },
    } };
    const bytes = try renderTestFixture(std.testing.allocator, &node, .{}, .{}, "ssh-key", &bundle, "http://repo", "http://facts", "http://event", "http://log", "", "0123456789abcdef0123456789abcdef", "token", "scope", null);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "NODEFORGE_EOF") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "install -d") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "printf") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "%b") != null);
}
