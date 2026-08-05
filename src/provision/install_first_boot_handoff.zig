//! # 装机侧 generation 绑定 first-boot 原子 handoff 脚本
//!
//! 在 kickstart/autoinstall 的 late-command / %post 中执行：从 nodeforged 拉取
//! plan、agent、payloads、capsule，落到目标根（`target_root`），原子提交
//! current-generation 与 pending 标记，**最后**再 POST `/handoff`。
//!
//! 安全：answer 文件只嵌入 capability **路径**（0400 运行时文件），从不嵌入
//! 原始 bearer；脚本校验 token 为 64 hex。

const std = @import("std");

/// handoff 脚本渲染输入。字段不得含空白或引号（防 shell 注入）。
pub const Config = struct {
    node_id: []const u8,
    generation: u64,
    base_url: []const u8,
    boot_session_id: []const u8,
    /// 仅运行时存在的 0400 boot-session capability 文件路径；answer 只写路径。
    capability_file: []const u8,
    /// 目标根前缀（如 `/target`）；空表示主机根。
    target_root: []const u8 = "",
    /// 启用 first-boot unit 的命令（Ubuntu 可用 curtin in-target 包装）。
    enable_command: []const u8 = "systemctl enable nodeforge-install-firstboot.service",
};

/// 渲染 POSIX shell handoff 脚本（调用方拥有返回切片）。
/// 提交顺序：凭据 part → agent → generation 目录 → current-generation → pending → handoff。
pub fn render(allocator: std.mem.Allocator, config: Config) ![]u8 {
    if (config.node_id.len == 0 or config.generation == 0 or !std.mem.startsWith(u8, config.base_url, "http://")) return error.InvalidFirstBootHandoff;
    for ([_][]const u8{ config.node_id, config.boot_session_id, config.capability_file }) |value| if (value.len == 0 or std.mem.indexOfAny(u8, value, "'\n\r\t ") != null) return error.InvalidFirstBootHandoff;
    if (config.capability_file[0] != '/') return error.InvalidFirstBootHandoff;
    if (config.target_root.len != 0 and config.target_root[0] != '/') return error.InvalidFirstBootHandoff;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print(
        \\set -eu
        \\NF_ROOT='{s}'
        \\NF_NODE='{s}'
        \\NF_GEN='{d}'
        \\NF_BASE='{s}/api/v1/nodes/{s}/install-generations/{d}/first-boot'
        \\NF_CAPABILITY_FILE='{s}'
        \\test -r "$NF_CAPABILITY_FILE"
        \\NF_TOKEN=$(cat "$NF_CAPABILITY_FILE")
        \\case "$NF_TOKEN" in ''|*[!0-9a-fA-F]*) exit 70;; esac
        \\test "${{#NF_TOKEN}}" -eq 64
        \\NF_AUTH="Authorization: Bearer $NF_TOKEN"
        \\NF_SESSION='X-NodeForge-Session: {s}'
        \\NF_STAGE="$NF_ROOT/var/lib/nodeforge/install-firstboot/$NF_GEN.staging"
        \\NF_FINAL="$NF_ROOT/var/lib/nodeforge/install-firstboot/$NF_GEN"
        \\NF_CREDS="$NF_ROOT/var/lib/nodeforge/credentials"
        \\test ! -e "$NF_FINAL"
        \\install -d -m 0700 "$NF_STAGE/payload" "$NF_CREDS" "$NF_ROOT/usr/sbin" "$NF_ROOT/etc/systemd/system"
        \\curl -fsS --max-redirs 0 -H "$NF_AUTH" -H "$NF_SESSION" "$NF_BASE/plan" -o "$NF_STAGE/plan.json"
        \\NF_PLAN_DIGEST=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["first_boot_plan_digest"])' "$NF_STAGE/plan.json")
        \\NF_AGENT_URL=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["agent_url"])' "$NF_STAGE/plan.json")
        \\NF_AGENT_SIZE=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["agent_size"])' "$NF_STAGE/plan.json")
        \\NF_AGENT_SHA=$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["agent_sha256"])' "$NF_STAGE/plan.json")
        \\curl -fsS --max-redirs 0 -H "$NF_AUTH" -H "$NF_SESSION" "$NF_AGENT_URL" -o "$NF_STAGE/nodeforge-agent"
        \\test "$(wc -c < "$NF_STAGE/nodeforge-agent")" -eq "$NF_AGENT_SIZE"
        \\test "$(sha256sum "$NF_STAGE/nodeforge-agent" | cut -d' ' -f1)" = "$NF_AGENT_SHA"
        \\chmod 0755 "$NF_STAGE/nodeforge-agent"
        \\python3 - "$NF_STAGE/plan.json" > "$NF_STAGE/payload-manifest" <<'NODEFORGE_PAYLOADS'
        \\import json,sys
        \\for p in json.load(open(sys.argv[1]))["payloads"]:
        \\ print("%s\t%s\t%s" % (p["path"], p["size"], p["sha256"]))
        \\NODEFORGE_PAYLOADS
        \\NF_TAB=$(printf '\tX')
        \\NF_TAB=${{NF_TAB%X}}
        \\while IFS="$NF_TAB" read -r NF_PATH NF_SIZE NF_SHA; do
        \\  test -n "$NF_PATH"
        \\  case "$NF_PATH" in /*|*..*|*\\*) exit 71;; esac
        \\  install -d -m 0700 "$(dirname "$NF_STAGE/payload/$NF_PATH")"
        \\  curl -fsS --max-redirs 0 -H "$NF_AUTH" -H "$NF_SESSION" "$NF_BASE/payloads/$NF_SHA" -o "$NF_STAGE/payload/$NF_PATH"
        \\  test "$(wc -c < "$NF_STAGE/payload/$NF_PATH")" -eq "$NF_SIZE"
        \\  test "$(sha256sum "$NF_STAGE/payload/$NF_PATH" | cut -d' ' -f1)" = "$NF_SHA"
        \\done < "$NF_STAGE/payload-manifest"
        \\rm -f "$NF_STAGE/payload-manifest"
        \\curl -fsS --max-redirs 0 -H "$NF_AUTH" -H "$NF_SESSION" "$NF_BASE/capsule" -o "$NF_STAGE/capsule.json"
        \\python3 - "$NF_STAGE/capsule.json" "$NF_CREDS/first-boot.token.part" <<'NODEFORGE_CAPSULE'
        \\import json,os,sys
        \\token=json.load(open(sys.argv[1]))["bootstrap_token"]
        \\assert len(token)==64 and all(c in "0123456789abcdefABCDEF" for c in token)
        \\fd=os.open(sys.argv[2], os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o400)
        \\os.write(fd,(token+"\n").encode()); os.fsync(fd); os.close(fd)
        \\NODEFORGE_CAPSULE
        \\rm -f "$NF_STAGE/capsule.json"
        \\printf '{{"schema_version":1,"node_id":"%s","install_generation":%s,"first_boot_plan_digest":"%s"}}\n' "$NF_NODE" "$NF_GEN" "$NF_PLAN_DIGEST" > "$NF_STAGE/identity.json"
        \\cat > "$NF_ROOT/etc/systemd/system/nodeforge-install-firstboot.service" <<NODEFORGE_UNIT
        \\[Unit]
        \\Description=NodeForge install first-boot
        \\Wants=network-online.target
        \\After=network-online.target
        \\ConditionPathExists=/var/lib/nodeforge/install-firstboot/$NF_GEN/pending
        \\[Service]
        \\Type=oneshot
        \\ExecStart=/usr/sbin/nodeforge-agent --install-first-boot
        \\[Install]
        \\WantedBy=multi-user.target
        \\NODEFORGE_UNIT
        \\python3 - "$NF_STAGE" "$NF_CREDS" <<'NODEFORGE_FSYNC'
        \\import os,sys
        \\for root,dirs,files in os.walk(sys.argv[1]):
        \\ for name in files:
        \\  fd=os.open(os.path.join(root,name),os.O_RDONLY); os.fsync(fd); os.close(fd)
        \\ for name in dirs:
        \\  fd=os.open(os.path.join(root,name),os.O_RDONLY|os.O_DIRECTORY); os.fsync(fd); os.close(fd)
        \\fd=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY); os.fsync(fd); os.close(fd)
        \\fd=os.open(sys.argv[2],os.O_RDONLY|os.O_DIRECTORY); os.fsync(fd); os.close(fd)
        \\NODEFORGE_FSYNC
        \\mv "$NF_STAGE/nodeforge-agent" "$NF_ROOT/usr/sbin/nodeforge-agent.part"
        \\mv "$NF_ROOT/usr/sbin/nodeforge-agent.part" "$NF_ROOT/usr/sbin/nodeforge-agent"
        \\mv "$NF_CREDS/first-boot.token.part" "$NF_CREDS/first-boot.token"
        \\mv "$NF_STAGE" "$NF_FINAL"
        \\printf '%s\n' "$NF_GEN" > "$NF_ROOT/var/lib/nodeforge/install-firstboot/current-generation.part"
        \\mv "$NF_ROOT/var/lib/nodeforge/install-firstboot/current-generation.part" "$NF_ROOT/var/lib/nodeforge/install-firstboot/current-generation"
        \\: > "$NF_FINAL/pending.part"
        \\mv "$NF_FINAL/pending.part" "$NF_FINAL/pending"
        \\python3 - "$NF_ROOT/etc/systemd/system/nodeforge-install-firstboot.service" "$NF_ROOT/var/lib/nodeforge/install-firstboot/current-generation" "$NF_FINAL/pending" "$NF_ROOT/usr/sbin/nodeforge-agent" "$NF_CREDS/first-boot.token" "$NF_ROOT/var/lib/nodeforge/install-firstboot" "$NF_CREDS" "$NF_ROOT/usr/sbin" "$NF_ROOT/etc/systemd/system" <<'NODEFORGE_FINAL_FSYNC'
        \\import os,sys
        \\for path in sys.argv[1:]:
        \\ flags=os.O_RDONLY|(os.O_DIRECTORY if os.path.isdir(path) else 0)
        \\ fd=os.open(path,flags); os.fsync(fd); os.close(fd)
        \\NODEFORGE_FINAL_FSYNC
        \\{s}
        \\curl -fsS --max-redirs 0 -X POST -H "$NF_AUTH" -H "$NF_SESSION" -H 'Content-Type: application/json' -d '{{}}' "$NF_BASE/handoff"
        \\unset NF_TOKEN NF_AUTH
        \\
    , .{ config.target_root, config.node_id, config.generation, config.base_url, config.node_id, config.generation, config.capability_file, config.boot_session_id, config.enable_command });
    return out.toOwnedSlice();
}

test "handoff stages credentials and commits handoff last" {
    const script = try render(std.testing.allocator, .{ .node_id = "n1", .generation = 9, .base_url = "http://192.0.2.1:18080", .boot_session_id = "session", .capability_file = "/run/nodeforge-installer.token" });
    defer std.testing.allocator.free(script);
    const token_write = std.mem.indexOf(u8, script, "first-boot.token.part").?;
    const pending = std.mem.lastIndexOf(u8, script, "pending.part").?;
    const handoff = std.mem.lastIndexOf(u8, script, "/handoff").?;
    try std.testing.expect(token_write < pending and pending < handoff);
    try std.testing.expect(std.mem.indexOf(u8, script, "ExecStart=/usr/sbin/nodeforge-agent --install-first-boot") != null);
    try std.testing.expect(std.mem.startsWith(u8, script, "set -eu\n"));
    try std.testing.expect(std.mem.indexOf(u8, script, "print(\"%s\\t%s\\t%s\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "print(\"%s\\\\t%s") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "NF_TAB=$(printf '\\tX')") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "NF_TAB=$(printf '\\\\tX')") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "token+\"\\n\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "token+\"\\\\n\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "printf '%s\\n' \"$NF_GEN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "printf '%s\\\\n' \"$NF_GEN\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, script, "NF_TAB=${NF_TAB%X}") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "done < \"$NF_STAGE/payload-manifest\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "Authorization: Bearer $NF_TOKEN") != null);
}

test "rendered handoff is valid POSIX shell syntax" {
    const script = try render(std.testing.allocator, .{ .node_id = "node-01", .generation = 9, .base_url = "http://192.0.2.1:18080", .boot_session_id = "0123456789abcdef0123456789abcdef", .capability_file = "/run/nodeforge-installer.token", .target_root = "/target", .enable_command = "curtin in-target --target=/target -- systemctl enable nodeforge-install-firstboot.service" });
    defer std.testing.allocator.free(script);
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "sh", "-n", "-c", script } });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.HandoffShellSyntaxFailed,
    }
}
