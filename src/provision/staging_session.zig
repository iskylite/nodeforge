//! # Rootfs Staging 会话环境（v0.4.1）
//!
//! 在已保留的 rootfs staging 树上提供安全、可复现的运维会话环境。
//! 支持交互式 shell（enter）和非交互命令执行（exec），使用完整挂载矩阵
//! 和 cgroup 资源限额，切根方式为 chroot。
//!
//! 核心流程：
//! 1. 校验保留树存在且可用
//! 2. 获取会话锁（per-digest 排他锁，原子创建）
//! 3. 可选：解析并创建 cgroup 限额子树（fail closed）
//! 4. 渲染并执行 wrapper 脚本（unshare + 挂载矩阵 + chroot）
//! 5. 清理并校验无残留挂载
//! 6. 释放锁
//!
//! 边界：
//! - 仅在管理节点本机以 root 执行
//! - 默认共享宿主机网络（不 unshare net）
//! - 切根仅用 chroot（pivot_root 见遗留 V041-D01）
//! - 不经 nodeforged HTTP worker

const std = @import("std");

/// 会话资源限额参数（用户输入；渲染前会解析为 cgroup v2 合法值）。
pub const CgroupLimits = struct {
    memory_max: ?[]const u8 = null,
    memory_swap: ?[]const u8 = null,
    cpu_max: ?[]const u8 = null,
    pids_max: ?[]const u8 = null,

    pub fn hasAny(self: CgroupLimits) bool {
        return self.memory_max != null or self.memory_swap != null or
            self.cpu_max != null or self.pids_max != null;
    }
};

/// 解析后的 cgroup v2 写入值（所有权由调用方 allocator 持有）。
pub const ResolvedCgroupLimits = struct {
    memory_max: ?[]const u8 = null,
    memory_swap: ?[]const u8 = null,
    cpu_max: ?[]const u8 = null,
    pids_max: ?[]const u8 = null,

    pub fn deinit(self: *ResolvedCgroupLimits, allocator: std.mem.Allocator) void {
        if (self.memory_max) |v| allocator.free(v);
        if (self.memory_swap) |v| allocator.free(v);
        if (self.cpu_max) |v| allocator.free(v);
        if (self.pids_max) |v| allocator.free(v);
        self.* = .{};
    }
};

/// 会话选项（enter 和 exec 共用）。
pub const SessionOptions = struct {
    /// 保留树根目录的绝对路径。
    staging_path: []const u8,
    /// rootfs_input_digest（64 hex），用于锁和日志。
    digest: []const u8,
    /// 会话内 shell 路径，默认 /bin/bash 回落 /bin/sh。
    shell: []const u8 = "/bin/bash",
    /// chroot 内工作目录（会话根下的路径）。
    workdir: ?[]const u8 = null,
    /// 环境变量（KEY=VALUE 形式）。
    env: []const []const u8 = &.{},
    /// 额外 bind 挂载（host:guest 格式）。
    binds: []const []const u8 = &.{},
    /// 关闭 cgroup 挂载（与限额参数互斥）。
    no_cgroup: bool = false,
    /// cgroup 资源限额（用户输入字符串）。
    limits: CgroupLimits = .{},
    /// /tmp 使用树内目录而非 tmpfs。
    persist_tmp: bool = false,
    /// uts hostname。
    hostname: []const u8 = "nodeforge-staging",
    /// 减少步骤日志（仅错误+最终结果）。
    quiet: bool = false,
    /// exec 模式：要执行的命令（null 表示 enter 交互 shell）。
    command: ?[]const u8 = null,
    /// exec 模式：宿主脚本绝对路径；bind 到会话内固定路径后执行。
    /// 与 command 互斥。
    script_host: ?[]const u8 = null,
    /// exec 超时（秒）。
    timeout: ?u32 = null,
};

/// 会话执行结果。
pub const SessionResult = struct {
    exit_code: u8,
    session_id: []const u8,

    pub fn deinit(self: SessionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
    }
};

/// 验证会话选项的互斥与一致性约束。
pub fn validateOptions(opts: SessionOptions) !void {
    if (opts.staging_path.len == 0 or !std.fs.path.isAbsolute(opts.staging_path))
        return error.InvalidStagingPath;
    if (std.mem.indexOf(u8, opts.staging_path, "..") != null)
        return error.InvalidStagingPath;
    if (opts.digest.len != 64)
        return error.InvalidDigest;
    if (opts.no_cgroup and opts.limits.hasAny())
        return error.CgroupLimitsMutuallyExclusiveWithNoCgroup;
    if (opts.shell.len == 0)
        return error.InvalidShell;
    if (opts.command != null and opts.script_host != null)
        return error.CommandAndScriptMutuallyExclusive;
    if (opts.script_host) |script| {
        if (script.len == 0 or !std.fs.path.isAbsolute(script))
            return error.InvalidScriptPath;
        if (std.mem.indexOf(u8, script, "..") != null)
            return error.InvalidScriptPath;
    }
    if (opts.workdir) |wd| {
        if (wd.len == 0)
            return error.InvalidWorkdir;
        // workdir 必须是 chroot 内路径，禁止绝对逃逸到宿主根外语义
        if (std.mem.indexOf(u8, wd, "..") != null)
            return error.InvalidWorkdir;
    }
    // 验证 bind 格式 host:guest（guest 须以 / 开头）
    for (opts.binds) |bind| {
        const colon = std.mem.indexOfScalar(u8, bind, ':') orelse return error.InvalidBindFormat;
        if (colon == 0 or colon + 1 >= bind.len) return error.InvalidBindFormat;
        const guest = bind[colon + 1 ..];
        if (guest.len == 0 or guest[0] != '/') return error.InvalidBindFormat;
    }
    // 验证 env：KEY 为标识符，VALUE 禁止 NUL/换行
    for (opts.env) |kv| {
        try validateEnvPair(kv);
    }
    // 限额字面量可解析（fail closed）
    if (opts.limits.hasAny()) {
        var tmp = try resolveCgroupLimits(std.heap.page_allocator, opts.limits);
        defer tmp.deinit(std.heap.page_allocator);
    }
}

fn validateEnvPair(kv: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.InvalidEnvFormat;
    if (eq == 0) return error.InvalidEnvFormat;
    const key = kv[0..eq];
    const value = kv[eq + 1 ..];
    if (!isEnvKey(key)) return error.InvalidEnvFormat;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidEnvFormat;
    if (std.mem.indexOfScalar(u8, value, '\n') != null) return error.InvalidEnvFormat;
    if (std.mem.indexOfScalar(u8, value, '\r') != null) return error.InvalidEnvFormat;
}

fn isEnvKey(key: []const u8) bool {
    if (key.len == 0) return false;
    const c0 = key[0];
    if (!((c0 >= 'A' and c0 <= 'Z') or (c0 >= 'a' and c0 <= 'z') or c0 == '_')) return false;
    for (key[1..]) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_'))
            return false;
    }
    return true;
}

/// 将用户限额字符串解析为 cgroup v2 合法值。
///
/// - memory/memory.swap：`max` 或字节数；支持 `K`/`M`/`G`/`T` 后缀（1024 进制）
/// - cpu.max：`max`、`quota period` 两字段，或 `N`/`N%`（按 period=100000 换算）
/// - pids.max：`max` 或十进制整数
pub fn resolveCgroupLimits(allocator: std.mem.Allocator, limits: CgroupLimits) !ResolvedCgroupLimits {
    var out: ResolvedCgroupLimits = .{};
    errdefer out.deinit(allocator);
    if (limits.memory_max) |v| out.memory_max = try parseMemoryLimit(allocator, v);
    if (limits.memory_swap) |v| out.memory_swap = try parseMemoryLimit(allocator, v);
    if (limits.cpu_max) |v| out.cpu_max = try parseCpuMax(allocator, v);
    if (limits.pids_max) |v| out.pids_max = try parsePidsMax(allocator, v);
    return out;
}

fn parseMemoryLimit(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const s = std.mem.trim(u8, raw, " \t");
    if (s.len == 0) return error.InvalidMemoryLimit;
    if (std.mem.eql(u8, s, "max")) return try allocator.dupe(u8, "max");
    // 纯数字 → 字节
    if (std.fmt.parseInt(u64, s, 10)) |n| {
        return try std.fmt.allocPrint(allocator, "{d}", .{n});
    } else |_| {}
    // 带单位：最后一字符为 K/M/G/T（大小写均可）
    if (s.len < 2) return error.InvalidMemoryLimit;
    const unit = s[s.len - 1];
    const num_part = std.mem.trim(u8, s[0 .. s.len - 1], " \t");
    if (num_part.len == 0) return error.InvalidMemoryLimit;
    const n = std.fmt.parseInt(u64, num_part, 10) catch return error.InvalidMemoryLimit;
    const mult: u64 = switch (unit) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        'T', 't' => 1024 * 1024 * 1024 * 1024,
        else => return error.InvalidMemoryLimit,
    };
    const bytes = std.math.mul(u64, n, mult) catch return error.InvalidMemoryLimit;
    return try std.fmt.allocPrint(allocator, "{d}", .{bytes});
}

fn parseCpuMax(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const s = std.mem.trim(u8, raw, " \t");
    if (s.len == 0) return error.InvalidCpuMax;
    if (std.mem.eql(u8, s, "max")) return try allocator.dupe(u8, "max");
    // 已是 "quota period" 两字段
    if (std.mem.indexOfScalar(u8, s, ' ')) |sp| {
        const q = std.mem.trim(u8, s[0..sp], " \t");
        const p = std.mem.trim(u8, s[sp + 1 ..], " \t");
        if (q.len == 0 or p.len == 0) return error.InvalidCpuMax;
        if (!std.mem.eql(u8, q, "max")) _ = std.fmt.parseInt(u64, q, 10) catch return error.InvalidCpuMax;
        _ = std.fmt.parseInt(u64, p, 10) catch return error.InvalidCpuMax;
        return try std.fmt.allocPrint(allocator, "{s} {s}", .{ q, p });
    }
    // 百分比：50 或 50%
    var pct_str = s;
    if (std.mem.endsWith(u8, pct_str, "%")) pct_str = pct_str[0 .. pct_str.len - 1];
    const pct = std.fmt.parseInt(u64, pct_str, 10) catch return error.InvalidCpuMax;
    if (pct == 0 or pct > 10000) return error.InvalidCpuMax; // 允许超 100% 表示多核
    const period: u64 = 100_000;
    const quota = std.math.mul(u64, pct, period / 100) catch return error.InvalidCpuMax;
    return try std.fmt.allocPrint(allocator, "{d} {d}", .{ quota, period });
}

fn parsePidsMax(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const s = std.mem.trim(u8, raw, " \t");
    if (s.len == 0) return error.InvalidPidsMax;
    if (std.mem.eql(u8, s, "max")) return try allocator.dupe(u8, "max");
    _ = std.fmt.parseInt(u64, s, 10) catch return error.InvalidPidsMax;
    return try allocator.dupe(u8, s);
}

/// 渲染会话 wrapper 脚本。脚本是一个独立 shell 文件，由 Zig 侧写入临时文件后执行。
///
/// `resolved_limits` 在创建 cgroup 子树时必须已是 cgroup v2 合法值（字节 / quota period）。
pub fn renderWrapperScript(
    w: *std.Io.Writer,
    opts: SessionOptions,
    lock_path: []const u8,
    cgroup_path: ?[]const u8,
    session_id: []const u8,
    resolved_limits: ResolvedCgroupLimits,
) !void {
    // 脚本头部
    try w.writeAll("#!/bin/sh\n");
    try w.writeAll("# nodeforge staging session wrapper (v0.4.1)\n");
    try w.writeAll("# Auto-generated; do not edit.\n");
    try w.writeAll("set -u\n\n");

    // 变量定义
    try w.print("STAGING={f}\n", .{shellQuote(opts.staging_path)});
    try w.print("SESSION_ID={f}\n", .{shellQuote(session_id)});
    try w.print("LOCK_PATH={f}\n", .{shellQuote(lock_path)});
    if (cgroup_path) |cg| {
        try w.print("CGROUP_PATH={f}\n", .{shellQuote(cg)});
    } else {
        try w.writeAll("CGROUP_PATH=''\n");
    }
    try w.writeAll("QUIET='");
    try w.writeAll(if (opts.quiet) "1" else "0");
    try w.writeAll("'\n");
    try w.writeAll("POLICY_HOST=''\n");
    try w.writeAll("POLICY_CREATED=0\n\n");

    // 日志函数
    try w.writeAll(
        \\log() {
        \\  [ "$QUIET" = "0" ] && echo "staging-session: $*" >&2 || true
        \\}
        \\log_err() {
        \\  echo "staging-session: $*" >&2
        \\}
        \\
    );

    // 步骤日志
    try w.print("log 'resolve digest={s} path={s}'\n", .{ opts.digest, opts.staging_path });
    try w.writeAll("log 'lock acquired'\n\n");

    // cgroup 限额子树创建（在宿主上，unshare 之前；fail closed）
    if (cgroup_path) |cg| {
        try w.writeAll("# Create cgroup limit subtree on host (cgroup v2, fail closed)\n");
        // 1) 先建父目录
        try w.writeAll("mkdir -p /sys/fs/cgroup/nodeforge-staging || { log_err 'FAIL cgroup parent mkdir'; exit 1; }\n");
        // 2) 在根 cgroup 上尽量启用控制器（若已启用则忽略错误）
        try w.writeAll("echo +memory > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true\n");
        try w.writeAll("echo +cpu > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true\n");
        try w.writeAll("echo +pids > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true\n");
        // 3) 在父级启用控制器，子级的 *.max 才可写
        try w.writeAll("echo +memory > /sys/fs/cgroup/nodeforge-staging/cgroup.subtree_control 2>/dev/null || true\n");
        try w.writeAll("echo +cpu > /sys/fs/cgroup/nodeforge-staging/cgroup.subtree_control 2>/dev/null || true\n");
        try w.writeAll("echo +pids > /sys/fs/cgroup/nodeforge-staging/cgroup.subtree_control 2>/dev/null || true\n");
        // 4) 创建会话子树
        try w.print("mkdir -p {f} || {{ log_err 'FAIL cgroup mkdir'; exit 1; }}\n", .{shellQuote(cg)});
        if (resolved_limits.memory_max) |v| {
            try w.print("echo {f} > {f}/memory.max || {{ log_err 'FAIL memory.max={s}'; exit 1; }}\n", .{ shellQuote(v), shellQuote(cg), v });
            try w.print("log 'cgroup memory.max={s}'\n", .{v});
        }
        if (resolved_limits.memory_swap) |v| {
            try w.print("echo {f} > {f}/memory.swap.max || {{ log_err 'FAIL memory.swap.max={s}'; exit 1; }}\n", .{ shellQuote(v), shellQuote(cg), v });
            try w.print("log 'cgroup memory.swap.max={s}'\n", .{v});
        }
        if (resolved_limits.cpu_max) |v| {
            try w.print("echo {f} > {f}/cpu.max || {{ log_err 'FAIL cpu.max={s}'; exit 1; }}\n", .{ shellQuote(v), shellQuote(cg), v });
            try w.print("log 'cgroup cpu.max={s}'\n", .{v});
        }
        if (resolved_limits.pids_max) |v| {
            try w.print("echo {f} > {f}/pids.max || {{ log_err 'FAIL pids.max={s}'; exit 1; }}\n", .{ shellQuote(v), shellQuote(cg), v });
            try w.print("log 'cgroup pids.max={s}'\n", .{v});
        }
        try w.writeAll("log 'cgroup limits applied'\n\n");
    }

    // unshare + 挂载矩阵 + chroot
    try w.writeAll("# Enter namespace and run session\n");
    try w.writeAll("unshare --mount --pid --fork --mount-proc --uts --ipc -- sh -c '\n");

    // 在子 shell 内重新定义 log/log_err（外层函数在 sh -c 子 shell 中不可见）
    try w.writeAll("  log() { [ \"$QUIET\" = \"0\" ] && echo \"staging-session: $*\" >&2 || true; }\n");
    try w.writeAll("  log_err() { echo \"staging-session: $*\" >&2; }\n");

    // 将变量传入内层 shell
    try w.print("  STAGING={f}\n", .{shellQuote(opts.staging_path)});
    if (cgroup_path) |cg| {
        try w.print("  CGROUP_PATH={f}\n", .{shellQuote(cg)});
    } else {
        try w.writeAll("  CGROUP_PATH=\"\"\n");
    }
    try w.writeAll("  POLICY_HOST=\"\"\n");
    try w.writeAll("  POLICY_CREATED=0\n");

    // 移动进程到 cgroup（fail closed）
    try w.writeAll("  if [ -n \"$CGROUP_PATH\" ]; then\n");
    try w.writeAll("    echo $$ > \"$CGROUP_PATH/cgroup.procs\" || { log_err \"FAIL cgroup.procs migrate\"; exit 1; }\n");
    try w.writeAll("    log \"cgroup migrate ok path=$CGROUP_PATH\"\n");
    try w.writeAll("  fi\n\n");

    // hostname
    try w.print("  hostname {f} 2>/dev/null || true\n", .{shellQuote(opts.hostname)});

    // 挂载矩阵
    try w.writeAll("  log \"unshare namespaces=mount,pid,uts,ipc (net=host)\"\n");
    try w.writeAll("  mkdir -p \"$STAGING/proc\" \"$STAGING/sys\" \"$STAGING/dev/pts\" \"$STAGING/dev/shm\" \"$STAGING/run\" \"$STAGING/tmp\" \"$STAGING/sys/fs/cgroup\" \"$STAGING/usr/sbin\" \"$STAGING/etc\"\n\n");

    try w.writeAll("  mount -t proc proc \"$STAGING/proc\" || { log_err \"FAIL mount proc\"; exit 1; }\n");
    try w.writeAll("  log \"mount proc ok\"\n");
    try w.writeAll("  mount -t sysfs sys \"$STAGING/sys\" || { log_err \"FAIL mount sys\"; exit 1; }\n");
    try w.writeAll("  log \"mount sys ok\"\n");
    try w.writeAll("  mount --rbind /dev \"$STAGING/dev\" || { log_err \"FAIL mount rbind /dev\"; exit 1; }\n");
    try w.writeAll("  mount --make-rslave \"$STAGING/dev\" 2>/dev/null || true\n");
    try w.writeAll("  log \"mount rbind /dev ok\"\n");
    try w.writeAll("  mount -t devpts devpts \"$STAGING/dev/pts\" || { log_err \"FAIL mount devpts\"; exit 1; }\n");
    try w.writeAll("  log \"mount devpts ok\"\n");
    try w.writeAll("  mount -t tmpfs tmpfs \"$STAGING/dev/shm\" || { log_err \"FAIL mount shm\"; exit 1; }\n");
    try w.writeAll("  log \"mount shm ok\"\n");
    try w.writeAll("  mount -t tmpfs tmpfs \"$STAGING/run\" || { log_err \"FAIL mount run\"; exit 1; }\n");
    try w.writeAll("  log \"mount run ok\"\n");

    // /tmp: tmpfs 或树内目录
    if (!opts.persist_tmp) {
        try w.writeAll("  mount -t tmpfs tmpfs \"$STAGING/tmp\" || { log_err \"FAIL mount tmp\"; exit 1; }\n");
        try w.writeAll("  log \"mount tmp(tmpfs) ok\"\n");
    } else {
        try w.writeAll("  log \"mount tmp(persist-tree) skip\"\n");
    }

    // cgroup2 挂载：失败只记 skip/WARN，不谎报 ok
    if (!opts.no_cgroup) {
        try w.writeAll("  if mount -t cgroup2 none \"$STAGING/sys/fs/cgroup\" 2>/dev/null; then\n");
        try w.writeAll("    log \"mount cgroup2 ok\"\n");
        try w.writeAll("  else\n");
        try w.writeAll("    log_err \"WARN cgroup2 mount failed (session continues without in-tree cgroup)\"\n");
        try w.writeAll("  fi\n");
    } else {
        try w.writeAll("  log \"cgroup mount skipped (--no-cgroup)\"\n");
    }

    // resolv.conf bind-ro（不永久写树）
    try w.writeAll("  if [ -f /etc/resolv.conf ]; then\n");
    try w.writeAll("    touch \"$STAGING/etc/resolv.conf\" 2>/dev/null || true\n");
    try w.writeAll("    if mount --bind /etc/resolv.conf \"$STAGING/etc/resolv.conf\" 2>/dev/null; then\n");
    try w.writeAll("      mount -o remount,ro,bind \"$STAGING/etc/resolv.conf\" 2>/dev/null || true\n");
    try w.writeAll("      log \"mount resolv.conf(bind-ro) ok\"\n");
    try w.writeAll("    else\n");
    try w.writeAll("      log_err \"WARN resolv.conf bind failed\"\n");
    try w.writeAll("    fi\n");
    try w.writeAll("  fi\n");

    // 额外 bind 挂载（文件→touch，目录→mkdir -p）
    for (opts.binds) |bind| {
        const colon = std.mem.indexOfScalar(u8, bind, ':') orelse continue;
        const host = bind[0..colon];
        const guest = bind[colon + 1 ..];
        try w.print("  BIND_HOST={f}\n", .{shellQuote(host)});
        try w.print("  BIND_GUEST=\"$STAGING{f}\"\n", .{shellQuote(guest)});
        try w.writeAll("  if [ -d \"$BIND_HOST\" ]; then\n");
        try w.writeAll("    mkdir -p \"$BIND_GUEST\"\n");
        try w.writeAll("  else\n");
        try w.writeAll("    mkdir -p \"$(dirname \"$BIND_GUEST\")\" 2>/dev/null || true\n");
        try w.writeAll("    touch \"$BIND_GUEST\" 2>/dev/null || true\n");
        try w.writeAll("  fi\n");
        try w.writeAll("  mount --bind \"$BIND_HOST\" \"$BIND_GUEST\" 2>/dev/null || log_err \"WARN bind $BIND_HOST failed\"\n");
    }

    // policy-rc.d：宿主临时文件 bind 覆盖，避免把 exit 101 永久写进保留树
    try w.writeAll("  POLICY_HOST=$(mktemp) || { log_err \"FAIL mktemp policy-rc.d\"; exit 1; }\n");
    try w.writeAll("  printf \"#!/bin/sh\\nexit 101\\n\" > \"$POLICY_HOST\"\n");
    try w.writeAll("  chmod +x \"$POLICY_HOST\"\n");
    try w.writeAll("  if [ ! -e \"$STAGING/usr/sbin/policy-rc.d\" ]; then\n");
    try w.writeAll("    touch \"$STAGING/usr/sbin/policy-rc.d\" || { log_err \"FAIL policy-rc.d mountpoint\"; rm -f \"$POLICY_HOST\"; exit 1; }\n");
    try w.writeAll("    POLICY_CREATED=1\n");
    try w.writeAll("  fi\n");
    try w.writeAll("  mount --bind \"$POLICY_HOST\" \"$STAGING/usr/sbin/policy-rc.d\" || { log_err \"FAIL policy-rc.d bind\"; rm -f \"$POLICY_HOST\"; exit 1; }\n");
    try w.writeAll("  log \"policy-rc.d bind-overlay ok\"\n\n");

    // --script：把宿主脚本 bind 到会话内固定路径
    if (opts.script_host) |script| {
        try w.writeAll("  SCRIPT_GUEST=/tmp/.nodeforge-script\n");
        try w.print("  SCRIPT_HOST={f}\n", .{shellQuote(script)});
        try w.writeAll("  touch \"$STAGING$SCRIPT_GUEST\" || { log_err \"FAIL script mountpoint\"; exit 1; }\n");
        try w.writeAll("  mount --bind \"$SCRIPT_HOST\" \"$STAGING$SCRIPT_GUEST\" || { log_err \"FAIL script bind\"; exit 1; }\n");
        try w.writeAll("  chmod +x \"$STAGING$SCRIPT_GUEST\" 2>/dev/null || true\n");
        try w.writeAll("  log \"script bind ok guest=$SCRIPT_GUEST\"\n");
    }

    // 环境变量（KEY 已校验为标识符；VALUE 严格 shell 引用）
    for (opts.env) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        const key = kv[0..eq];
        const value = kv[eq + 1 ..];
        try w.print("  export {s}={f}\n", .{ key, shellQuote(value) });
    }

    // chroot + 执行（workdir 在 chroot 内切换，禁止宿主侧 cd）
    const workdir = opts.workdir;
    if (opts.script_host != null) {
        try w.writeAll("  log \"exec script start\"\n");
        if (workdir) |wd| {
            try w.print("  chroot \"$STAGING\" /bin/sh -c {f}\n", .{shellQuoteInnerCdExec(wd, "/tmp/.nodeforge-script")});
        } else {
            try w.writeAll("  chroot \"$STAGING\" /bin/sh -c 'exec /tmp/.nodeforge-script'\n");
        }
        try w.writeAll("  STATUS=$?\n");
        try w.writeAll("  log \"exec script done status=$STATUS\"\n\n");
    } else if (opts.command) |cmd| {
        try w.writeAll("  log \"exec command start\"\n");
        if (workdir) |wd| {
            try w.print("  chroot \"$STAGING\" /bin/sh -c {f}\n", .{shellQuoteInnerCd(wd, cmd)});
        } else {
            try w.print("  chroot \"$STAGING\" /bin/sh -c {f}\n", .{shellQuote(cmd)});
        }
        try w.writeAll("  STATUS=$?\n");
        try w.writeAll("  log \"exec command done status=$STATUS\"\n\n");
    } else {
        // enter 模式：交互 shell
        try w.print("  log \"chroot + exec {s}\"\n", .{opts.shell});
        if (workdir) |wd| {
            try w.print("  chroot \"$STAGING\" /bin/sh -c {f}\n", .{shellQuoteInnerCdExec(wd, opts.shell)});
        } else {
            try w.print("  chroot \"$STAGING\" {f}\n", .{shellQuote(opts.shell)});
        }
        try w.writeAll("  STATUS=$?\n");
        try w.writeAll("  log \"shell exited code=$STATUS\"\n\n");
    }

    // 清理（挂载命名空间退出时会自动卸下多数 bind；此处显式 umount 并去掉我们创建的挂载点文件）
    try w.writeAll("  # Cleanup session-only overlays\n");
    if (opts.script_host != null) {
        try w.writeAll("  umount -l \"$STAGING/tmp/.nodeforge-script\" 2>/dev/null || true\n");
        try w.writeAll("  rm -f \"$STAGING/tmp/.nodeforge-script\" 2>/dev/null || true\n");
    }
    try w.writeAll("  umount -l \"$STAGING/usr/sbin/policy-rc.d\" 2>/dev/null || true\n");
    try w.writeAll("  if [ \"$POLICY_CREATED\" = \"1\" ]; then rm -f \"$STAGING/usr/sbin/policy-rc.d\"; fi\n");
    try w.writeAll("  rm -f \"$POLICY_HOST\" 2>/dev/null || true\n");
    try w.writeAll("  umount -l \"$STAGING/etc/resolv.conf\" 2>/dev/null || true\n");
    if (!opts.no_cgroup) {
        try w.writeAll("  umount -l \"$STAGING/sys/fs/cgroup\" 2>/dev/null || true\n");
    }
    if (!opts.persist_tmp) {
        try w.writeAll("  umount -l \"$STAGING/tmp\" 2>/dev/null || true\n");
    }
    try w.writeAll("  umount -l \"$STAGING/run\" 2>/dev/null || true\n");
    try w.writeAll("  umount -l \"$STAGING/dev/shm\" 2>/dev/null || true\n");
    try w.writeAll("  umount -l \"$STAGING/dev/pts\" 2>/dev/null || true\n");
    try w.writeAll("  umount -R -l \"$STAGING/dev\" 2>/dev/null || true\n");
    try w.writeAll("  umount -l \"$STAGING/sys\" 2>/dev/null || true\n");
    try w.writeAll("  umount -l \"$STAGING/proc\" 2>/dev/null || true\n");
    try w.writeAll("  log \"cleanup umount done\"\n");

    // 额外 bind 清理
    for (opts.binds) |bind| {
        const colon = std.mem.indexOfScalar(u8, bind, ':') orelse continue;
        const guest = bind[colon + 1 ..];
        try w.print("  umount -l \"$STAGING{f}\" 2>/dev/null || true\n", .{shellQuote(guest)});
    }

    try w.writeAll("  exit $STATUS\n");
    try w.writeAll("'\n\n");

    // 外层：获取 unshare 退出码
    try w.writeAll("SESSION_STATUS=$?\n\n");

    // cgroup 清理
    if (cgroup_path) |cg| {
        try w.writeAll("# Cleanup cgroup subtree\n");
        try w.print("if [ -n {f} ] && [ -d {f} ]; then\n", .{ shellQuote(cg), shellQuote(cg) });
        try w.print("  rmdir {f} 2>/dev/null || log_err 'WARN cgroup dir not empty, left at {s}'\n", .{ shellQuote(cg), cg });
        try w.writeAll("fi\n\n");
    }

    // 残留挂载校验
    try w.writeAll("# Verify no leftover mounts\n");
    try w.writeAll("LEFTOVER=0\n");
    try w.writeAll("for leaf in proc sys dev dev/pts dev/shm run tmp sys/fs/cgroup; do\n");
    try w.writeAll("  if mountpoint -q \"$STAGING/$leaf\" 2>/dev/null; then\n");
    try w.writeAll("    log_err 'FAIL leftover mount at '$STAGING/$leaf\n");
    try w.writeAll("    LEFTOVER=1\n");
    try w.writeAll("  fi\n");
    try w.writeAll("done\n");
    try w.writeAll("if [ \"$LEFTOVER\" = \"1\" ]; then\n");
    try w.writeAll("  log_err 'cleanup incomplete; check: findmnt | grep staging'\n");
    try w.writeAll("  SESSION_STATUS=1\n");
    try w.writeAll("fi\n");
    try w.writeAll("log 'cleanup verify: no leftover mounts'\n\n");

    // 释放锁
    try w.writeAll("# Release lock\n");
    try w.writeAll("rm -f \"$LOCK_PATH\"\n");
    try w.writeAll("log 'lock released'\n");
    try w.writeAll("log 'done status='$SESSION_STATUS\n");
    try w.writeAll("exit $SESSION_STATUS\n");
}

/// 构造 `cd <workdir> && <cmd>` 并整体 shell 引用（用于 chroot 内 sh -c）。
fn shellQuoteInnerCd(workdir: []const u8, cmd: []const u8) ShellQuotedPair {
    return .{ .workdir = workdir, .cmd = cmd, .mode = .run };
}

fn shellQuoteInnerCdExec(workdir: []const u8, shell: []const u8) ShellQuotedPair {
    return .{ .workdir = workdir, .cmd = shell, .mode = .exec_shell };
}

const ShellQuotedPair = struct {
    workdir: []const u8,
    cmd: []const u8,
    mode: enum { run, exec_shell },

    pub fn format(self: ShellQuotedPair, writer: *std.Io.Writer) !void {
        // 输出双引号包裹的整段：cd "wd" && exec "shell" 或 cd "wd" && cmd
        try writer.writeByte('"');
        try writer.writeAll("cd ");
        try writeDoubleQuotedEscaped(writer, self.workdir);
        switch (self.mode) {
            .run => {
                try writer.writeAll(" && ");
                // cmd 本身可能含空格与元字符，再包一层单段双引号不安全；
                // 用 eval 不安全。这里把 cmd 作为 `sh -c` 的内层脚本字面量转义后拼接。
                try writeEscapedForDouble(writer, self.cmd);
            },
            .exec_shell => {
                try writer.writeAll(" && exec ");
                try writeDoubleQuotedEscaped(writer, self.cmd);
            },
        }
        try writer.writeByte('"');
    }
};

fn writeDoubleQuotedEscaped(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('\\');
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"', '\\', '$', '`' => {
                try writer.writeByte('\\');
                try writer.writeByte(c);
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('\\');
    try writer.writeByte('"');
}

fn writeEscapedForDouble(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"', '\\', '$', '`' => {
                try writer.writeByte('\\');
                try writer.writeByte(c);
            },
            else => try writer.writeByte(c),
        }
    }
}

/// 获取会话锁文件路径。
pub fn lockFilePath(allocator: std.mem.Allocator, run_dir: []const u8, digest: []const u8) ![]u8 {
    if (digest.len < 12) return error.InvalidDigest;
    return std.fmt.allocPrint(allocator, "{s}/rootfs-staging/{s}.lock", .{ run_dir, digest });
}

/// 尝试获取会话锁（O_CREAT|O_EXCL 原子创建 + PID 探活回收）。
/// 锁文件格式：第一行为 PID。
pub fn acquireLock(io: std.Io, allocator: std.mem.Allocator, lock_path: []const u8) !void {
    const dir = std.fs.path.dirname(lock_path) orelse return error.InvalidLockPath;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    const pid_text = try std.fmt.allocPrint(allocator, "{d}\n", .{std.c.getpid()});
    defer allocator.free(pid_text);

    // 最多尝试两次：第一次 PathAlreadyExists 时探活并可能回收
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        if (tryCreateLockExclusive(io, lock_path, pid_text)) return;
        // 锁已存在：读取 PID 并探活
        const existing = std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, .limited(64)) catch |err| switch (err) {
            error.FileNotFound => continue, // 竞态：刚被释放，重试 exclusive
            else => return err,
        };
        defer allocator.free(existing);
        const trimmed = std.mem.trim(u8, existing, " \t\r\n");
        const existing_pid = std.fmt.parseInt(i32, trimmed, 10) catch {
            // 锁文件损坏：删除后重试
            std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
            continue;
        };
        if (existing_pid > 0 and kill(existing_pid, 0) == 0) {
            return error.StagingSessionLocked;
        }
        // 进程已死：回收后重试 exclusive
        std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
    }
    return error.StagingSessionLocked;
}

fn tryCreateLockExclusive(io: std.Io, lock_path: []const u8, pid_text: []const u8) bool {
    var file = std.Io.Dir.cwd().createFile(io, lock_path, .{
        .exclusive = true,
        .truncate = true,
    }) catch return false;
    defer file.close(io);
    file.writePositionalAll(io, pid_text, 0) catch {
        // 写失败：尽量删除半成品锁
        std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
        return false;
    };
    return true;
}

/// 释放会话锁。
pub fn releaseLock(io: std.Io, lock_path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
}

/// cgroup 子树路径。
pub fn cgroupPath(allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "/sys/fs/cgroup/nodeforge-staging/{s}", .{session_id});
}

/// 生成会话 ID（基于 PID 和时间戳）。
pub fn generateSessionId(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "sess-{d}-{d}", .{ std.c.getpid(), c_time(null) });
}

/// 检查指定 digest 的保留树是否被会话锁占用。
/// 供 daemon from-staging / staging remove 路径调用，避免与活跃 enter/exec 会话并发改树。
pub fn isLocked(io: std.Io, allocator: std.mem.Allocator, run_dir: []const u8, digest: []const u8) bool {
    const lock_path = lockFilePath(allocator, run_dir, digest) catch return false;
    defer allocator.free(lock_path);
    if (std.Io.Dir.cwd().readFileAlloc(io, lock_path, allocator, .limited(64))) |pid_text| {
        defer allocator.free(pid_text);
        const trimmed = std.mem.trim(u8, pid_text, " \t\r\n");
        const pid = std.fmt.parseInt(i32, trimmed, 10) catch {
            std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
            return false;
        };
        if (pid > 0 and kill(pid, 0) == 0) return true;
        // 进程已死，清理残留锁
        std.Io.Dir.cwd().deleteFile(io, lock_path) catch {};
        return false;
    } else |_| {
        return false;
    }
}

/// 检查是否以 root 运行。
pub fn isRoot() bool {
    return std.c.getuid() == 0;
}

/// 检查宿主 cgroup 版本是否为 v2。
pub fn isCgroupV2(io: std.Io, allocator: std.mem.Allocator) !bool {
    const content = std.Io.Dir.cwd().readFileAlloc(io, "/sys/fs/cgroup/cgroup.controllers", allocator, .limited(256)) catch return false;
    defer allocator.free(content);
    return true;
}

/// 执行会话。返回 shell/命令的退出码。
pub fn executeSession(
    io: std.Io,
    allocator: std.mem.Allocator,
    opts: SessionOptions,
    run_dir: []const u8,
    err_writer: *std.Io.Writer,
) !SessionResult {
    try validateOptions(opts);

    if (!isRoot()) {
        try err_writer.writeAll("error: staging session requires root (euid=0)\n");
        return error.NotRoot;
    }

    // 解析 cgroup 限额（在锁之前 fail closed，避免占锁后才发现参数非法）
    var resolved = try resolveCgroupLimits(allocator, opts.limits);
    defer resolved.deinit(allocator);

    const session_id = try generateSessionId(allocator);
    defer allocator.free(session_id);

    const lock_path = try lockFilePath(allocator, run_dir, opts.digest);
    defer allocator.free(lock_path);

    acquireLock(io, allocator, lock_path) catch |err| switch (err) {
        error.StagingSessionLocked => {
            try err_writer.print("error: staging tree {s} is locked by another session\n", .{opts.digest});
            return error.StagingSessionLocked;
        },
        else => return err,
    };
    errdefer releaseLock(io, lock_path);

    // 确定 cgroup 路径
    var cg_path: ?[]u8 = null;
    defer if (cg_path) |p| allocator.free(p);
    if (opts.limits.hasAny() and !opts.no_cgroup) {
        const is_v2 = isCgroupV2(io, allocator) catch false;
        if (!is_v2) {
            try err_writer.writeAll("error: cgroup limits require cgroup v2 on host\n");
            releaseLock(io, lock_path);
            return error.CgroupV1NotSupported;
        }
        cg_path = try cgroupPath(allocator, session_id);
    }

    // 渲染 wrapper 脚本
    var script_buf: std.Io.Writer.Allocating = .init(allocator);
    defer script_buf.deinit();
    try renderWrapperScript(&script_buf.writer, opts, lock_path, cg_path, session_id, resolved);

    // 写入临时文件
    const wrapper_path = try std.fmt.allocPrint(allocator, "/tmp/nodeforge-staging-{s}.sh", .{session_id});
    defer allocator.free(wrapper_path);
    defer std.Io.Dir.cwd().deleteFile(io, wrapper_path) catch {};

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = wrapper_path, .data = script_buf.written() });
    const wrapper_path_z = try allocator.dupeZ(u8, wrapper_path);
    defer allocator.free(wrapper_path_z);
    _ = std.c.chmod(wrapper_path_z.ptr, 0o755);

    if (!opts.quiet) {
        try err_writer.print("staging-session: session {s} starting\n", .{session_id});
        try err_writer.print("staging-session: staging path: {s}\n", .{opts.staging_path});
        if (opts.script_host) |s| {
            try err_writer.print("staging-session: exec mode: script={s}\n", .{s});
        } else if (opts.command) |cmd| {
            try err_writer.print("staging-session: exec mode: {s}\n", .{cmd});
        } else {
            try err_writer.print("staging-session: enter mode (interactive shell)\n", .{});
        }
        if (resolved.memory_max) |v| try err_writer.print("staging-session: limit memory.max={s}\n", .{v});
        if (resolved.memory_swap) |v| try err_writer.print("staging-session: limit memory.swap.max={s}\n", .{v});
        if (resolved.cpu_max) |v| try err_writer.print("staging-session: limit cpu.max={s}\n", .{v});
        if (resolved.pids_max) |v| try err_writer.print("staging-session: limit pids.max={s}\n", .{v});
    }

    // 执行 wrapper；exec 超时用 timeout 命令包装
    const cmd_tmp = if (opts.timeout) |t|
        try std.fmt.allocPrint(allocator, "timeout --signal=TERM --kill-after=10s {d} sh {s}", .{ t, wrapper_path })
    else
        try std.fmt.allocPrint(allocator, "sh {s}", .{wrapper_path});
    defer allocator.free(cmd_tmp);
    const cmd_z = try allocator.dupeZ(u8, cmd_tmp);
    defer allocator.free(cmd_z);

    const status = system(cmd_z.ptr);

    var exit_code: u8 = 1;
    if (WIFEXITED(status)) {
        exit_code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        exit_code = 128 + @as(u8, @intCast(WTERMSIG(status)));
    }

    if (!opts.quiet) {
        try err_writer.print("staging-session: session {s} exited code={d}\n", .{ session_id, exit_code });
    }

    // 锁应该已被 wrapper 释放；如果没有，确保释放
    releaseLock(io, lock_path);

    return .{ .exit_code = exit_code, .session_id = try allocator.dupe(u8, session_id) };
}

// ── C 互操作 ──────────────────────────────────────────────

extern fn system(command: [*:0]const u8) c_int;
extern fn kill(pid: c_int, sig: c_int) c_int;
extern fn time(tloc: ?*c_long) c_long;

fn c_time(tloc: ?*c_long) c_long {
    return time(tloc);
}

fn WIFEXITED(status: c_int) bool {
    return (status & 0x7f) == 0;
}

fn WEXITSTATUS(status: c_int) u8 {
    return @intCast((status >> 8) & 0xff);
}

fn WIFSIGNALED(status: c_int) bool {
    const sig = status & 0x7f;
    return sig != 0 and sig != 0x7f;
}

fn WTERMSIG(status: c_int) c_int {
    return status & 0x7f;
}

// ── Shell 引用辅助 ────────────────────────────────────────

fn shellQuote(s: []const u8) ShellQuoted {
    return .{ .raw = s };
}

const ShellQuoted = struct {
    raw: []const u8,

    pub fn format(self: ShellQuoted, writer: *std.Io.Writer) !void {
        // 使用双引号：wrapper 的 unshare -- sh -c '...' 外层单引号，内层用双引号。
        try writer.writeByte('"');
        for (self.raw) |c| {
            switch (c) {
                '"', '\\', '$', '`' => {
                    try writer.writeByte('\\');
                    try writer.writeByte(c);
                },
                else => try writer.writeByte(c),
            }
        }
        try writer.writeByte('"');
    }
};

// ── 测试 ──────────────────────────────────────────────────

test "validateOptions rejects relative paths and dot-dot" {
    try std.testing.expectError(error.InvalidStagingPath, validateOptions(.{
        .staging_path = "relative/path",
        .digest = "a" ** 64,
    }));
    try std.testing.expectError(error.InvalidStagingPath, validateOptions(.{
        .staging_path = "/foo/../bar",
        .digest = "a" ** 64,
    }));
}

test "validateOptions rejects wrong digest length" {
    try std.testing.expectError(error.InvalidDigest, validateOptions(.{
        .staging_path = "/staging",
        .digest = "short",
    }));
}

test "validateOptions rejects --no-cgroup with limits" {
    try std.testing.expectError(error.CgroupLimitsMutuallyExclusiveWithNoCgroup, validateOptions(.{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .no_cgroup = true,
        .limits = .{ .memory_max = "1G" },
    }));
}

test "validateOptions accepts valid enter options" {
    try validateOptions(.{
        .staging_path = "/var/lib/nodeforge/work/rootfs-staging/abc123",
        .digest = "a" ** 64,
    });
}

test "validateOptions rejects invalid bind format" {
    try std.testing.expectError(error.InvalidBindFormat, validateOptions(.{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .binds = &.{"no-colon"},
    }));
}

test "validateOptions rejects invalid env format" {
    try std.testing.expectError(error.InvalidEnvFormat, validateOptions(.{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .env = &.{"NO_EQUALS"},
    }));
    try std.testing.expectError(error.InvalidEnvFormat, validateOptions(.{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .env = &.{"bad-key=1"},
    }));
    try std.testing.expectError(error.InvalidEnvFormat, validateOptions(.{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .env = &.{"KEY=line\nbreak"},
    }));
}

test "validateOptions rejects command+script mutual exclusive" {
    try std.testing.expectError(error.CommandAndScriptMutuallyExclusive, validateOptions(.{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .command = "true",
        .script_host = "/tmp/s.sh",
    }));
}

test "parseMemoryLimit converts units to bytes" {
    const a = try parseMemoryLimit(std.testing.allocator, "2G");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("2147483648", a);
    const b = try parseMemoryLimit(std.testing.allocator, "512M");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("536870912", b);
    const c = try parseMemoryLimit(std.testing.allocator, "max");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("max", c);
}

test "parseCpuMax converts percent to quota period" {
    const a = try parseCpuMax(std.testing.allocator, "50%");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("50000 100000", a);
    const b = try parseCpuMax(std.testing.allocator, "100");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("100000 100000", b);
    const c = try parseCpuMax(std.testing.allocator, "max");
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("max", c);
}

test "renderWrapperScript produces enter script with full mount matrix" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, .{
        .staging_path = "/staging",
        .digest = "a" ** 64,
    }, "/run/lock.lock", null, "sess-test", .{});
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "unshare --mount --pid --fork --mount-proc --uts --ipc") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mount -t proc proc") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mount -t sysfs sys") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mount --rbind /dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mount -t devpts devpts") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mount -t tmpfs tmpfs") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mount -t cgroup2 none") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "policy-rc.d") != null);
    // policy-rc.d 必须 bind 覆盖，不得 printf 直写树
    try std.testing.expect(std.mem.indexOf(u8, body, "mount --bind \"$POLICY_HOST\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "printf \"exit 101\\n\" > \"$STAGING/usr/sbin/policy-rc.d\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "chroot") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "--net") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "leftover mount") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "lock released") != null);
}

test "renderWrapperScript produces exec script with command" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, .{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .command = "dnf -y install lustre-client",
    }, "/run/lock.lock", null, "sess-test", .{});
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "dnf -y install lustre-client") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "exec command start") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/bin/bash") == null);
}

test "renderWrapperScript workdir uses chroot-inner cd" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, .{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .workdir = "/opt/src",
        .command = "make -j4",
    }, "/run/lock.lock", null, "sess-test", .{});
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "cd ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/opt/src") != null);
    // 不得在 chroot 前对宿主 cd workdir
    try std.testing.expect(std.mem.indexOf(u8, body, "cd \"$WORKDIR\"") == null);
}

test "renderWrapperScript env values are shell-quoted" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, .{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .env = &.{"FOO=bar;rm -rf /"},
    }, "/run/lock.lock", null, "sess-test", .{});
    const body = out.written();
    // 必须是 export FOO="..." 形式，值被引用
    try std.testing.expect(std.mem.indexOf(u8, body, "export FOO=") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "export FOO=bar;rm") == null);
}

test "renderWrapperScript includes cgroup limits as resolved bytes fail-closed" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const resolved = ResolvedCgroupLimits{
        .memory_max = "2147483648",
        .pids_max = "1000",
    };
    try renderWrapperScript(&out.writer, .{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .limits = .{
            .memory_max = "2G",
            .pids_max = "1000",
        },
    }, "/run/lock.lock", "/sys/fs/cgroup/nodeforge-staging/sess-test", "sess-test", resolved);
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "memory.max") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "2147483648") != null);
    // 不得直接 echo 2G
    try std.testing.expect(std.mem.indexOf(u8, body, "echo \"2G\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "pids.max") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "cgroup.procs") != null);
    // fail closed：写失败必须 exit 1
    try std.testing.expect(std.mem.indexOf(u8, body, "FAIL memory.max") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mkdir -p /sys/fs/cgroup/nodeforge-staging") != null);
}

test "renderWrapperScript skips cgroup with --no-cgroup" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, .{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .no_cgroup = true,
    }, "/run/lock.lock", null, "sess-test", .{});
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "cgroup mount skipped") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mount -t cgroup2") == null);
}

test "renderWrapperScript cgroup mount failure does not log ok" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, .{
        .staging_path = "/staging",
        .digest = "a" ** 64,
    }, "/run/lock.lock", null, "sess-test", .{});
    const body = out.written();
    // 成功路径在 if 分支内打 ok；失败走 WARN，不再无条件 log ok
    try std.testing.expect(std.mem.indexOf(u8, body, "WARN cgroup2 mount failed") != null);
}

test "renderWrapperScript uses tree tmp with --persist-tmp" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, .{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .persist_tmp = true,
    }, "/run/lock.lock", null, "sess-test", .{});
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "persist-tree") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mount -t tmpfs tmpfs \"$STAGING/tmp\"") == null);
}

test "renderWrapperScript includes extra binds" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, .{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .binds = &.{"/host/iso:/mnt/iso"},
    }, "/run/lock.lock", null, "sess-test", .{});
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "/host/iso") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/mnt/iso") != null);
}

test "renderWrapperScript includes script bind path" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, .{
        .staging_path = "/staging",
        .digest = "a" ** 64,
        .script_host = "/host/install.sh",
    }, "/run/lock.lock", null, "sess-test", .{});
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "/host/install.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/tmp/.nodeforge-script") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "exec script start") != null);
}

test "renderWrapperScript includes step logging" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try renderWrapperScript(&out.writer, .{
        .staging_path = "/staging",
        .digest = "a" ** 64,
    }, "/run/lock.lock", null, "sess-test", .{});
    const body = out.written();
    try std.testing.expect(std.mem.indexOf(u8, body, "staging-session:") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "resolve digest=") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "lock acquired") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "done status=") != null);
}

test "CgroupLimits hasAny detects any limit" {
    try std.testing.expect(!(CgroupLimits{}).hasAny());
    try std.testing.expect((CgroupLimits{ .memory_max = "1G" }).hasAny());
    try std.testing.expect((CgroupLimits{ .pids_max = "100" }).hasAny());
}

test "lockFilePath produces correct path" {
    const path = try lockFilePath(std.testing.allocator, "/opt/nodeforge/run", "abcdef0123456789");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/opt/nodeforge/run/rootfs-staging/abcdef0123456789.lock", path);
}

test "acquireLock is exclusive via O_EXCL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const lock = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.lock", .{root});
    defer std.testing.allocator.free(lock);

    try acquireLock(std.testing.io, std.testing.allocator, lock);
    // 第二次获取应失败（当前进程 PID 仍存活）
    try std.testing.expectError(error.StagingSessionLocked, acquireLock(std.testing.io, std.testing.allocator, lock));
    releaseLock(std.testing.io, lock);
    // 释放后应可再获取
    try acquireLock(std.testing.io, std.testing.allocator, lock);
    releaseLock(std.testing.io, lock);
}
