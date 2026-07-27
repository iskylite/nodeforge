//! # nodeforge-initrd（v0.2 diskless 启动 init）
//!
//! `V0_2_DESIGN.md` §4.3 boot-time 序列。作为 dracut initrd 的 PID 1，在获得网络后：
//! 从 per-session credential capsule 读取 config token -> 有界重试拉取 BootConfig v2 ->
//! 下载并 SHA-512 校验 rootfs -> loop 挂载只读 lower + tmpfs upper -> overlay 合并 ->
//! 写 `/var/lib/nodeforge/boot.json` handoff（AgentPlan locator 与 agent/event token）->
//! 清除 config/rootfs token -> `switch_root` 执行 `nodeforge-agent --pre-init`。
//!
//! ## initrd 环境约束与设计决策
//!
//! 本程序运行在 dracut 提供的最小 userspace 中。与标准 Linux 环境的关键差异：
//!
//! **无环境变量**：内核启动 PID 1 时不携带任何环境变量。`/init` 脚本可能
//! 设置 PATH 也可能不设置。`main()` 中显式调用 `setenv("PATH", ...)` 确保
//! `/usr/sbin/ip`、`udhcpc`/`dhclient`、`/usr/sbin/switch_root` 等命令通过裸名
//! 调用时能被找到。
//!
//! **只读根文件系统**：dracut initramfs 的根可能是只读的。rootfs 下载的
//! `.part`/`.chunk` 临时文件需要写入 `/run`，因此 `main()` 中显式挂载
//! `/run` 为 tmpfs。
//!
//! **内核模块未加载**：Rocky Linux 内核中 `squashfs`、`loop`、`overlay` 是
//! 编译为模块（`=m`）而非内置（`=y`）。`main()` 在挂载前显式 `modprobe`
//! 这三个模块。使用 `runIgnore` 而非 `mustRun`——如果模块已内置则 modprobe
//! 返回非零但不影响功能。
//!
//! **DHCP 客户端边界**：daemon 内置的是 DHCP server，不能复用为 initrd 的
//! DHCP client。initrd 先接受内核/vendor userspace 已配置的全局地址，再优先
//! 使用镜像常见的 BusyBox `udhcpc`，最后回退到构建器注入的 `dhclient`。
//! 两条客户端路径都使用 NodeForge 自带的最小 hook，避免依赖
//! NetworkManager/systemd 或发行版脚本。
//!
//! **无 coreutils 依赖**：`bringUpNetwork` 使用 shell 参数展开 `${i##*/}`
//! 替代 `basename` 命令，避免对 initrd 中可能不存在的 coreutils 的依赖。
//!
//! **HTTP 通信**：由内置 Zig 原生客户端实现（`initrd/http.zig`），不依赖
//! 外部 `curl`。自身只编排与校验，不实现第二套挂载栈。
//!
//! **安全**：切根前清零 capability；raw token 只驻内存（来自 capsule），不落盘。
//! `switch_root` 以 `execve`（replace）接管 PID 1：子进程无法删除 PID-1 旧根。
//!
//! **构建配置**（见 `build.zig`）：`single_threaded = true` 避免 Zig stdlib
//! 引入 libpthread 依赖（glibc < 2.34 的 `libpthread.so.0` 在最小 initrd 中
//! 可能不存在）。`strip = true` 减小二进制体积。
const std = @import("std");
const builtin = @import("builtin");
const memory = @import("initrd/memory.zig");
const download = @import("initrd/download.zig");
const http = @import("initrd/http.zig");

/// C 库 setenv：在 initrd 最小环境中为子进程设置 PATH。
/// 内核启动 PID 1 时不携带环境变量，`/init` 脚本可能未 export PATH，
/// 导致 `/usr/sbin/ip`、`udhcpc`/`dhclient`、`/usr/sbin/switch_root` 等
/// 命令通过裸名调用时找不到。此处显式设置 PATH 作为安全网。
/// `single_threaded = true`（见 build.zig）时 Zig 不链接 libpthread，
/// setenv 仍可用（它是 libc 函数，非 pthread 函数）。
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// initrd 环境的 PATH：覆盖 /usr/bin、/usr/sbin、/bin、/sbin。
const initrd_path = "/usr/bin:/usr/sbin:/bin:/sbin";

/// 向 stderr（console）输出一行日志。在 initrd 中 stderr 连接到串口控制台。
/// 与 `http.zig` 中的 log 函数一致，使用 write(2) 直接输出。
/// R11: 同时追加写入 /run/initrd.log，用于 switch_root 前复制到无盘 overlay，
/// 使 initrd 阶段的启动日志在切根后仍然可用用于后续分析。
var initrd_log_fd: i32 = -1;

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, msg.ptr, msg.len);
    if (initrd_log_fd >= 0) _ = std.c.write(initrd_log_fd, msg.ptr, msg.len);
}

const capsule_config_token_path = "/capsule/config.token";
const capsule_rootfs_token_path = "/capsule/rootfs.token";
const capsule_agent_token_path = "/capsule/agent.token";
const capsule_event_token_path = "/capsule/event.token";
const capsule_session_path = "/capsule/session";
const cmdline_path = "/proc/cmdline";
const handoff_dir = "/merged/var/lib/nodeforge";
const handoff_path = "/merged/var/lib/nodeforge/boot.json";
const event_token_dir = "/merged/var/lib/nodeforge/credentials";
const agent_token_path = "/merged/var/lib/nodeforge/credentials/agent.token";
const event_token_path = "/merged/var/lib/nodeforge/credentials/event.token";
const rootfs_blob = "/run/rootfs.squashfs";
const rootfs_part = "/run/rootfs.squashfs.part";
const rootfs_chunk = "/run/rootfs.squashfs.chunk";
const lower_mnt = "/lower";
const rw_mnt = "/rw";
const merged_mnt = "/merged";

fn mountBootstrap(
    comptime source: [:0]const u8,
    comptime target: [:0]const u8,
    comptime fs_type: [:0]const u8,
    comptime data: ?[:0]const u8,
) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedOperatingSystem;
    const data_ptr: usize = if (data) |value| @intFromPtr(value.ptr) else 0;
    const rc = std.os.linux.mount(source.ptr, target.ptr, fs_type.ptr, 0, data_ptr);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.MountFailed;
}

const Cmdline = struct {
    config_url: ?[]const u8 = null,
    node: ?[]const u8 = null,
    session: ?[]const u8 = null,
    kernel_args: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    // 内核启动 PID 1 时不设置环境变量。显式设置 PATH 确保 ip/DHCP client/
    // switch_root/losetup 等 /usr/sbin 下的命令可通过裸名调用。
    _ = setenv("PATH", initrd_path, 1);

    log("[nodeforge-initrd] mounting /proc /sys /dev /run...\n", .{});
    // PID 1 must not depend on the vendor initrd's userspace loader before
    // /proc, /sys and /dev exist. Some installer initrds ship a dynamically
    // linked mount(8) whose early exec can fail even though its archive entry
    // is present. Use the kernel mount syscall for the bootstrap filesystems.
    try mountBootstrap("proc", "/proc", "proc", null);
    try mountBootstrap("sysfs", "/sys", "sysfs", null);
    try mountBootstrap("devtmpfs", "/dev", "devtmpfs", null);
    // /run 需要 tmpfs 挂载：rootfs 下载的 .part/.chunk 文件写入此处。
    // initramfs 根可能是只读的（取决于 dracut 配置），必须显式挂载 tmpfs。
    try mustRun(io, allocator, &.{ "mkdir", "-p", "/run" });
    mountBootstrap("tmpfs", "/run", "tmpfs", "mode=0755") catch {};
    // R11: 打开 initrd 日志文件，用于 switch_root 前复制到无盘系统。
    // Zig 0.16 的 std.c.O 使用 ACCMODE 枚举（.WRONLY）+ CREAT/TRUNC 布尔字段，
    // 而非传统 POSIX 的 O_WRONLY/O_CREAT/O_TRUNC 前缀名。
    initrd_log_fd = std.c.open("/run/initrd.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    log("[nodeforge-initrd] initrd log retention enabled (/run/initrd.log)\n", .{});
    // 加载 squashfs/loop/overlay 内核模块（这些在 Rocky 内核中是模块而非内置）。
    // 在挂载 squashfs rootfs 和 overlay 合并前必须已加载。
    try runIgnore(io, allocator, &.{ "/sbin/modprobe", "squashfs" });
    try runIgnore(io, allocator, &.{ "/sbin/modprobe", "loop" });
    try runIgnore(io, allocator, &.{ "/sbin/modprobe", "overlay" });
    // QEMU/VMware 常见的 virtio NIC 在最小 initramfs 中不会由 udev 自动加载；
    // DHCP client 可能在无可用网卡时仍退出，因此必须先显式加载常见驱动。
    try runIgnore(io, allocator, &.{ "/sbin/modprobe", "virtio_net" });
    try runIgnore(io, allocator, &.{ "/sbin/modprobe", "vmxnet3" });
    try runIgnore(io, allocator, &.{ "/sbin/modprobe", "e1000e" });

    const cmdline = try readCmdline(io, allocator);
    defer freeCmdline(allocator, cmdline);

    // 基本网络：复用已有地址，或通过 vendor udhcpc / 注入的 dhclient 获取。
    log("[nodeforge-initrd] bringing up network...\n", .{});
    try bringUpNetwork(io, allocator);
    log("[nodeforge-initrd] network setup done\n", .{});

    const config_token = try readToken(io, allocator, capsule_config_token_path);
    defer allocator.free(config_token);
    const rootfs_token = try readToken(io, allocator, capsule_rootfs_token_path);
    defer allocator.free(rootfs_token);
    const agent_token = try readToken(io, allocator, capsule_agent_token_path);
    defer allocator.free(agent_token);
    const event_token = try readToken(io, allocator, capsule_event_token_path);
    defer allocator.free(event_token);

    // 拉取 BootConfig v2（config:read token，有界重放，3 次重试）。
    // session 优先从 cmdline 读取（direct boot / QEMU -append 模式）；
    // 不在 cmdline 时从 capsule 文件读取（PXE boot 模式，GRUB cmdline
    // 不含 session，由 capsule 文件提供 diskless session ID）。
    // 无论来源，统一由 allocator 持有，避免 cmdline buffer 与独立 free 冲突。
    const session = blk: {
        if (cmdline.session) |s| break :blk try allocator.dupe(u8, s);
        break :blk readCapsuleHex(io, allocator, capsule_session_path, 32) catch {
            log("[nodeforge-initrd] error: missing nodeforge.session in cmdline and no /capsule/session file\n", .{});
            return error.MissingSession;
        };
    };
    defer allocator.free(session);
    const node = cmdline.node orelse return error.MissingNode;
    log("[nodeforge-initrd] fetching BootConfig from {s}...\n", .{cmdline.config_url orelse "(none)"});
    const config_url_parsed = try http.Url.parse(cmdline.config_url orelse return error.MissingConfigUrl);
    const config_auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{config_token});
    defer allocator.free(config_auth);
    const config_json = try http.getWithRetry(io, allocator, config_url_parsed, &.{
        .{ .name = "Authorization", .value = config_auth },
        .{ .name = "X-NodeForge-Session", .value = session },
    }, 3);
    defer allocator.free(config_json);
    const bc = try parseBootConfig(allocator, config_json);
    log("[nodeforge-initrd] BootConfig fetched, rootfs size={d}\n", .{bc.rootfs_size});
    defer freeBootConfig(allocator, &bc);
    var next_event_seq: u64 = 0;
    var current_phase: []const u8 = "boot.config_fetched";
    errdefer postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.failed") catch {};

    // 下载 rootfs 并 SHA-512 校验。
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.initrd_started");
    @memset(config_token, 0);
    next_event_seq += 1;
    current_phase = "diskless.initrd_started";
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.rootfs_downloading");
    next_event_seq += 1;
    current_phase = "diskless.rootfs_downloading";
    const meminfo = try captureRun(io, allocator, &.{ "cat", "/proc/meminfo" });
    defer allocator.free(meminfo);
    const upper_limit = try memory.upperLimit(.{
        .available_budget = try memory.memAvailableBytes(meminfo),
        .rootfs_size = bc.rootfs_size,
        .node_payload_size = bc.node_payload_size,
        .tmpfs_percent = bc.tmpfs_percent,
        .minimum_free_bytes = bc.minimum_free_bytes,
        .safety_margin_bytes = bc.safety_margin_bytes,
    });
    try downloadRootfs(io, allocator, &bc, rootfs_token, session);
    log("[nodeforge-initrd] rootfs downloaded, verifying SHA-512...\n", .{});
    verifySha512(io, rootfs_blob, bc.rootfs_sha512) catch return error.RootfsHashMismatch;
    log("[nodeforge-initrd] rootfs verified, mounting...\n", .{});
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.rootfs_verified");
    @memset(rootfs_token, 0);
    next_event_seq += 1;
    current_phase = "diskless.rootfs_verified";

    // 只读 lower（loop 挂载 squashfs）+ tmpfs upper/work（同一 tmpfs）+ overlay 合并。
    // squashfs/loop/overlay 模块已在 main() 开头加载，此处直接挂载。
    log("[nodeforge-initrd] creating mount points...\n", .{});
    try mustRun(io, allocator, &.{ "mkdir", "-p", lower_mnt, rw_mnt, merged_mnt });
    log("[nodeforge-initrd] mounting squashfs lower...\n", .{});
    // `mount -t squashfs -o loop` 需要 loop 模块和 squashfs 模块都已加载。
    // /run 已挂载为 tmpfs，rootfs_blob (/run/rootfs.squashfs) 可读。
    try mustRun(io, allocator, &.{ "mount", "-t", "squashfs", "-o", "loop", rootfs_blob, lower_mnt });
    log("[nodeforge-initrd] squashfs lower mounted, mounting tmpfs rw...\n", .{});
    const tmpfs_options = try std.fmt.allocPrint(allocator, "size={d},mode=0755", .{upper_limit});
    defer allocator.free(tmpfs_options);
    try mustRun(io, allocator, &.{ "mount", "-t", "tmpfs", "-o", tmpfs_options, "tmpfs", rw_mnt });
    const upper_dir = try std.fmt.allocPrint(allocator, "{s}/upper", .{rw_mnt});
    defer allocator.free(upper_dir);
    const work_dir = try std.fmt.allocPrint(allocator, "{s}/work", .{rw_mnt});
    defer allocator.free(work_dir);
    log("[nodeforge-initrd] creating upper/work dirs...\n", .{});
    try mustRun(io, allocator, &.{ "mkdir", "-p", upper_dir, work_dir });
    const overlay_opts = try std.fmt.allocPrint(allocator, "lowerdir={s},upperdir={s},workdir={s}", .{ lower_mnt, upper_dir, work_dir });
    defer allocator.free(overlay_opts);
    log("[nodeforge-initrd] mounting overlay (lowerdir={s})...\n", .{lower_mnt});
    // overlay 模块已在 main() 开头加载。
    try mustRun(io, allocator, &.{ "mount", "-t", "overlay", "overlay", "-o", overlay_opts, merged_mnt });
    // initrd 与 pre-init agent 是同一个 boot closure。rootfs 是可复用的
    // Node-independent lower，不能让其中构建时固化的旧 agent 覆盖当前 initrd
    // 协议实现；写入 overlay upper 后 switch_root 必然执行配套版本。
    const target_agent = try std.fmt.allocPrint(allocator, "{s}/usr/sbin/nodeforge-agent", .{merged_mnt});
    defer allocator.free(target_agent);
    try mustRun(io, allocator, &.{ "/usr/bin/cp", "-f", "/usr/sbin/nodeforge-agent", target_agent });
    try mustRun(io, allocator, &.{ "/usr/bin/chmod", "0755", target_agent });
    log("[nodeforge-initrd] overlay mounted, writing handoff...\n", .{});
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.rootfs_mounted");
    next_event_seq += 1;
    current_phase = "diskless.rootfs_mounted";

    // handoff：AgentPlan locator + agent/event token 交给 agent pre-init（写入新根 /var/lib）。
    try writeHandoff(io, allocator, &bc, session, node, agent_token, event_token);
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.switching_root");
    next_event_seq += 1;
    current_phase = "diskless.switching_root";
    // token 已分别撤销或复制到 0400 handoff credential，清零 initrd 副本。
    @memset(agent_token, 0);
    @memset(event_token, 0);

    // R11: 将 initrd 日志留存到无盘 overlay，使切根后可查看完整启动链日志。
    // /run/initrd.log 由 log() 函数在每次调用时追加写入；此处复制到 overlay
    // upper 的 /var/lib/nodeforge/initrd.log，同时捕获 dmesg 用于内核层诊断。
    log("[nodeforge-initrd] retaining logs to overlay...\n", .{});
    runIgnore(io, allocator, &.{ "sh", "-c", "mkdir -p /merged/var/lib/nodeforge && cp /run/initrd.log /merged/var/lib/nodeforge/initrd.log 2>/dev/null; dmesg > /merged/var/lib/nodeforge/initrd-dmesg.log 2>/dev/null" }) catch {};

    // switch_root -> nodeforge-agent --pre-init（agent 校验 plan/payload、node-apply 后 exec /sbin/init）。
    // 必须 by PID 1 执行：用 replace（execve）替换当前进程，而非 spawn 子进程。
    // 仅 exec 失败才会返回（成功时进程镜像已被替换，不返回）。
    // nodeforge-agent 在 rootfs 中的路径是 /usr/sbin/nodeforge-agent
    // （由 `nodeforge profile rootfs build` 安装到 rootfs squashfs 中）。
    log("[nodeforge-initrd] switch_root to {s}/usr/sbin/nodeforge-agent --pre-init\n", .{merged_mnt});
    return std.process.replace(io, .{ .argv = &.{ "/usr/sbin/switch_root", merged_mnt, "/usr/sbin/nodeforge-agent", "--pre-init" } });
}

/// up 第一个非 lo 网卡并取得 IPv4 配置。
/// 使用 shell 参数展开 `${i##*/}` 替代 `basename`，避免对 coreutils 的依赖。
/// 已有全局地址时直接复用；否则优先使用 initrd 自带 `udhcpc`，再回退到
/// `dhclient -1`。所有路径都有界退出，避免 PID 1 无限阻塞。
fn bringUpNetwork(io: std.Io, allocator: std.mem.Allocator) !void {
    try runIgnore(io, allocator, &.{ "ip", "link", "set", "lo", "up" });
    // 用 ${i##*/} 取接口名，不依赖 basename。
    try runIgnore(io, allocator, &.{ "sh", "-c", "for i in /sys/class/net/*; do dev=${i##*/}; [ \"$dev\" != lo ] && ip link set \"$dev\" up && break; done" });
    const existing = try captureRun(io, allocator, &.{ "/sbin/ip", "-4", "-o", "addr", "show", "scope", "global" });
    defer allocator.free(existing);
    if (std.mem.trim(u8, existing, " \t\r\n").len != 0) {
        log("[nodeforge-initrd] using preconfigured network: {s}", .{existing});
        return;
    }
    try runIgnore(io, allocator, &.{ "mkdir", "-p", "/var/lib/dhclient" });
    try mustRun(io, allocator, &.{
        "sh", "-c",
        \\if command -v udhcpc >/dev/null 2>&1; then
        \\ udhcpc -n -q -t 5 -T 3 -s /usr/sbin/nodeforge-udhcpc-script
        \\ if [ -n "$(/sbin/ip -4 -o addr show scope global)" ]; then exit 0; fi
        \\ echo 'udhcpc did not configure a global IPv4 address; trying dhclient' >&2
        \\fi
        \\if command -v dhclient >/dev/null 2>&1; then
        \\ exec dhclient -v -1 -sf /usr/sbin/nodeforge-dhclient-script
        \\fi
        \\echo 'no supported DHCP client (udhcpc or dhclient)' >&2
        \\exit 127
    });
    const addresses = try captureRun(io, allocator, &.{ "/sbin/ip", "-4", "-o", "addr", "show", "scope", "global" });
    defer allocator.free(addresses);
    if (std.mem.trim(u8, addresses, " \t\r\n").len == 0) return error.DhcpAddressMissing;
    log("[nodeforge-initrd] DHCP configured: {s}", .{addresses});
}

/// 把 AgentPlan locator + agent/event token 写入新根 `/var/lib/nodeforge`（boot.json +
/// 0400 credential 文件），交给 agent pre-init；切根后持久可读。
fn writeHandoff(io: std.Io, allocator: std.mem.Allocator, bc: *const BootConfig, session: ?[]const u8, node: ?[]const u8, agent_token: []const u8, event_token: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, handoff_dir);
    try std.Io.Dir.cwd().createDirPath(io, event_token_dir);
    const json = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"node\":\"{s}\",\"session\":\"{s}\",\"agent_plan_url\":\"{s}\",\"agent_plan_digest\":\"{s}\",\"event_url\":\"{s}\"}}\n", .{
        node orelse "",
        session orelse "",
        bc.agent_plan_url,
        bc.agent_plan_digest,
        bc.event_url,
    });
    defer allocator.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = handoff_path, .data = json });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = agent_token_path, .data = agent_token });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = event_token_path, .data = event_token });
    try mustRun(io, allocator, &.{ "chmod", "0400", agent_token_path });
    try mustRun(io, allocator, &.{ "chmod", "0400", event_token_path });
}

/// 服务端 BootConfig v2 解析结果（per-Node 短时 DTO）。字符串字段由 `parseBootConfig`
/// dupe 到 arena 之外，必须经 `freeBootConfig` 释放。
const BootConfig = struct {
    rootfs_url: []u8,
    rootfs_sha512: []u8,
    agent_plan_url: []u8,
    agent_plan_digest: []u8,
    event_url: []u8,
    /// rootfs 字节大小，HEAD 与最终落盘大小都须与之精确相等。
    rootfs_size: u64,
    /// tmpfs upper 占 MemAvailable 的百分比上限。
    tmpfs_percent: u8,
    /// 内存闸保留的最小空闲字节（低于即 fail-closed，见 memory.upperLimit）。
    minimum_free_bytes: u64,
    /// squashfs + upper + payload 之外再扣减的额外安全余量。
    safety_margin_bytes: u64,
    /// Node 级 payload 预算（纳入 upper limit 扣减，防 first-boot 写爆 tmpfs）。
    node_payload_size: u64,
};

/// 从 BootConfig v2 JSON 解析 rootfs/overlay/agent_plan/event 定位与内存预算字段。
fn parseBootConfig(allocator: std.mem.Allocator, json: []const u8) !BootConfig {
    const Parsed = struct {
        rootfs: struct { url: []const u8, sha512: []const u8, size: u64 },
        overlay: struct {
            tmpfs_percent: u8,
            minimum_free_bytes: u64,
            safety_margin_bytes: u64,
            node_payload_size: u64 = 0,
        },
        agent_plan: struct { url: []const u8, digest: []const u8 },
        event_url: []const u8,
    };
    const p = try std.json.parseFromSlice(Parsed, allocator, json, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    return .{
        .rootfs_url = try allocator.dupe(u8, p.value.rootfs.url),
        .rootfs_sha512 = try allocator.dupe(u8, p.value.rootfs.sha512),
        .agent_plan_url = try allocator.dupe(u8, p.value.agent_plan.url),
        .agent_plan_digest = try allocator.dupe(u8, p.value.agent_plan.digest),
        .event_url = try allocator.dupe(u8, p.value.event_url),
        .rootfs_size = p.value.rootfs.size,
        .tmpfs_percent = p.value.overlay.tmpfs_percent,
        .minimum_free_bytes = p.value.overlay.minimum_free_bytes,
        .safety_margin_bytes = p.value.overlay.safety_margin_bytes,
        .node_payload_size = p.value.overlay.node_payload_size,
    };
}

/// 释放 `parseBootConfig` dupe 的字符串字段（URL/digest 等）。
fn freeBootConfig(allocator: std.mem.Allocator, bc: *const BootConfig) void {
    allocator.free(bc.rootfs_url);
    allocator.free(bc.rootfs_sha512);
    allocator.free(bc.agent_plan_url);
    allocator.free(bc.agent_plan_digest);
    allocator.free(bc.event_url);
}

/// 读取并校验 capsule 中的 capability token：必须为 64 位十六进制，校验通过后删除
/// capsule 文件（单次消费，防重放）。任一校验失败即 fail-closed 返回错误。
fn readToken(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return readCapsuleHex(io, allocator, path, 64);
}

/// 读取固定长度的十六进制 capsule 值，并在成功后单次消费。delivery session
/// ID 是 32 hex；capability token 是 64 hex，二者不可共用固定 64 位校验。
fn readCapsuleHex(io: std.Io, allocator: std.mem.Allocator, path: []const u8, expected_len: usize) ![]u8 {
    const bytes = try readFile(io, allocator, path);
    defer allocator.free(bytes);
    const token = std.mem.trim(u8, bytes, " \t\r\n");
    if (token.len != expected_len) return error.InvalidCapsuleToken;
    for (token) |byte| if (!std.ascii.isHex(byte)) return error.InvalidCapsuleToken;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    return allocator.dupe(u8, token);
}

/// 向服务端 event_url 上报 lifecycle 事件（带 event_seq 与 expected_phase 做单调序校验）。
/// best-effort：`main` 的 errdefer 用它上报 `diskless.failed`，网络失败不阻塞切根。
fn postLifecycle(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: []const u8, seq: u64, expected: []const u8, phase: []const u8) !void {
    const body = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"session_id\":\"{s}\",\"event_seq\":{d},\"expected_phase\":\"{s}\",\"phase\":\"{s}\"}}\n", .{ session, seq, expected, phase });
    defer allocator.free(body);
    const event_url = try http.Url.parse(url);
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth);
    _ = http.post(io, allocator, event_url, &.{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "X-NodeForge-Session", .value = session },
        .{ .name = "Content-Type", .value = "application/json" },
    }, body) catch {};
}

/// 用内建 SHA-512 流式校验下载产物，不依赖最小 initramfs 未必携带的
/// `sha512sum`。逐块头合法不代表字节未损坏，故下载完成后仍须整段校验
/// （与逐块 Range 校验互为冗余闸）。
fn verifySha512(io: std.Io, path: []const u8, expected: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    var sha = std.crypto.hash.sha2.Sha512.init(.{});
    var buf: [256 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        sha.update(buf[0..n]);
        offset += n;
    }
    var raw: [64]u8 = undefined;
    sha.final(&raw);
    var actual: [128]u8 = undefined;
    _ = std.fmt.bufPrint(&actual, "{x}", .{raw}) catch unreachable;
    if (!std.mem.eql(u8, &actual, expected)) {
        log("[nodeforge-initrd] SHA-512 mismatch: expected={s}, actual={s}\n", .{ expected, actual });
        return error.HashMismatch;
    }
}

/// 严格 HEAD + 分块 Range 下载 rootfs（4 MiB/块）。支持断点续传（从 `.part` 已有
/// 大小恢复）与有界重试（指数退避，最多 5 次）。逐块经 `download.validateRange`
/// fail-closed 校验；全部块就绪后重命名为最终 blob，并清理临时文件。
/// HTTP 请求由 `initrd/http.zig` 原生客户端发起，不依赖外部 `curl`。
fn downloadRootfs(io: std.Io, allocator: std.mem.Allocator, bc: *const BootConfig, token: []const u8, session: []const u8) !void {
    const rootfs_url = try http.Url.parse(bc.rootfs_url);
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth);
    const expected_etag = try std.fmt.allocPrint(allocator, "\"{s}\"", .{bc.rootfs_sha512});
    defer allocator.free(expected_etag);

    // HEAD：校验 rootfs 元数据（Content-Length/ETag/Accept-Ranges），3 次重试。
    const head_bytes = try http.headWithRetry(io, allocator, rootfs_url, &.{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "X-NodeForge-Session", .value = session },
        .{ .name = "Accept-Encoding", .value = "identity" },
    }, 3);
    defer allocator.free(head_bytes);
    _ = try download.parseHead(head_bytes, bc.rootfs_size, expected_etag);

    const cwd = std.Io.Dir.cwd();
    var offset: u64 = if (cwd.statFile(io, rootfs_part, .{}) catch null) |stat| stat.size else 0;
    if (offset > bc.rootfs_size) {
        cwd.deleteFile(io, rootfs_part) catch {};
        offset = 0;
    }
    if (offset == 0) try cwd.writeFile(io, .{ .sub_path = rootfs_part, .data = "" });
    const chunk_size: u64 = 4 * 1024 * 1024;
    while (offset < bc.rootfs_size) {
        const end = @min(bc.rootfs_size - 1, offset + chunk_size - 1);
        var attempts: u8 = 0;
        while (true) {
            rangeOnce(io, allocator, rootfs_url, auth, session, expected_etag, offset, end, bc.rootfs_size) catch |err| {
                attempts += 1;
                cwd.deleteFile(io, rootfs_chunk) catch {};
                if (attempts >= 5) return err;
                const delay_ms: i64 = @as(i64, 1000) << @intCast(attempts - 1);
                std.Io.sleep(io, .fromMilliseconds(delay_ms), .awake) catch {};
                continue;
            };
            break;
        }
        // 追加 chunk 到 part 文件
        try mustRun(io, allocator, &.{ "sh", "-c", "cat /run/rootfs.squashfs.chunk >> /run/rootfs.squashfs.part" });
        offset = end + 1;
    }
    const completed = try cwd.statFile(io, rootfs_part, .{});
    if (completed.size != bc.rootfs_size) return error.RootfsSizeMismatch;
    cwd.deleteFile(io, rootfs_blob) catch {};
    try std.Io.Dir.rename(cwd, rootfs_part, cwd, rootfs_blob, io);
    cwd.deleteFile(io, rootfs_chunk) catch {};
}

/// 下载单块 Range：以 `If-Range` 绑定 HEAD 的 ETag，校验 206/Content-Range/ETag/
/// Content-Length，并校验落盘块大小等于 `end-start+1`。
/// HTTP 请求由 `initrd/http.zig` 原生客户端发起，响应体直接写入文件。
fn rangeOnce(io: std.Io, allocator: std.mem.Allocator, url: http.Url, auth: []const u8, session: []const u8, etag: []const u8, start: u64, end: u64, total: u64) !void {
    const range_value = try std.fmt.allocPrint(allocator, "bytes={d}-{d}", .{ start, end });
    defer allocator.free(range_value);
    const headers = try http.getToFile(io, allocator, url, &.{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "X-NodeForge-Session", .value = session },
        .{ .name = "Accept-Encoding", .value = "identity" },
        .{ .name = "Range", .value = range_value },
        .{ .name = "If-Range", .value = etag },
    }, rootfs_chunk);
    defer allocator.free(headers);
    try download.validateRange(headers, start, end, total, etag);
    const stat = try std.Io.Dir.cwd().statFile(io, rootfs_chunk, .{});
    if (stat.size != end - start + 1) return error.RootfsChunkSizeMismatch;
}

/// 解析 `/proc/cmdline` 中的 `nodeforge.*` 参数（config_url/node/session/kernel_args）。
fn readCmdline(io: std.Io, allocator: std.mem.Allocator) !Cmdline {
    // /proc/cmdline 是 procfs 文件：用 `cat` 子进程读取（Io 流式读取对 procfs 不可靠）。
    const bytes = try captureRun(io, allocator, &.{ "cat", cmdline_path });
    defer allocator.free(bytes);
    var c: Cmdline = .{};
    var it = std.mem.tokenizeAny(u8, bytes, " \t\n");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "nodeforge.config_url=")) c.config_url = try allocator.dupe(u8, tok["nodeforge.config_url=".len..]);
        if (std.mem.startsWith(u8, tok, "nodeforge.node=")) c.node = try allocator.dupe(u8, tok["nodeforge.node=".len..]);
        if (std.mem.startsWith(u8, tok, "nodeforge.session=")) c.session = try allocator.dupe(u8, tok["nodeforge.session=".len..]);
        if (std.mem.startsWith(u8, tok, "nodeforge.kernel_args=")) c.kernel_args = try allocator.dupe(u8, tok["nodeforge.kernel_args=".len..]);
    }
    return c;
}

/// 释放 `readCmdline` dupe 的各参数字符串。
fn freeCmdline(allocator: std.mem.Allocator, c: Cmdline) void {
    if (c.config_url) |s| allocator.free(s);
    if (c.node) |s| allocator.free(s);
    if (c.session) |s| allocator.free(s);
    if (c.kernel_args) |s| allocator.free(s);
}

/// 运行子进程并返回 stdout；退出码非 0 即失败。
fn captureRun(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
    return result.stdout;
}

/// 读取文件到分配的缓冲（上限 8 MiB，用于 header/cmdline 等小文件）。
fn readFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
}

/// 运行子进程，退出码非 0 即返回 `SubprocessFailed`（initrd 关键步骤不容忍失败）。
fn mustRun(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch |err| {
        log("[nodeforge-initrd] command exec failed: {s}: {t}\n", .{ argv[0], err });
        return error.SubprocessFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            log("[nodeforge-initrd] command failed: {s} exit={d} stderr={s}\n", .{ argv[0], code, result.stderr });
            return error.SubprocessFailed;
        },
        else => {
            log("[nodeforge-initrd] command terminated abnormally: {s}\n", .{argv[0]});
            return error.SubprocessFailed;
        },
    }
}

/// 运行子进程但忽略其退出码（用于 best-effort 的网络 up 等幂等步骤）。
fn runIgnore(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
}
