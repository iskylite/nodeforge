//! # nodeforge-initrd（v0.2 diskless 启动 init）
//!
//! `V0_2_DESIGN.md` §4.3 boot-time 序列。作为 dracut initrd 的 PID 1，在获得网络后：
//! 用 DHCP lease peer-IP 引导认证拉取 BootConfig v3，并接收随机、仅内存的
//! boot-session capability ->
//! 下载并 SHA-512 校验 rootfs -> loop 挂载只读 lower + tmpfs upper -> overlay 合并 ->
//! 写 `/var/lib/nodeforge/boot.json` handoff（仅 AgentPlan locator 等非 secret 元数据），
//! capability 与 durable event token 分别写入 0400 credential 文件 ->
//! `switch_root` 执行 `nodeforge-agent --pre-init`；终态后删除 capability 文件。
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
//! **硬件冷插拔**：自定义 PID 1 不会自动执行 installer initrd 原本由 systemd
//! 完成的 udev coldplug。`main()` 启动 ISO initrd 自带的 systemd-udevd，并通过
//! `udevadm trigger` 按内核 modalias 自动加载介质自带驱动；不写死任何网卡模块。
//! Rocky Linux 内核中的 `squashfs`、`loop`、`overlay` 则在挂载前显式加载。
//!
//! **DHCP 客户端边界**：daemon 内置的是 DHCP server，不能复用为 initrd 的
//! DHCP client。正常路径先按已绑定租约 IP、再按 PXE MAC 选择接口并直接配置；
//! 只有旧 cmdline 缺少结构化租约事实时，才依次尝试 vendor initrd 已有的
//! BusyBox `udhcpc`/`dhclient`。构建器只提供最小 hook，不从宿主注入客户端或 libc。
//!
//! **无 coreutils 依赖**：`bringUpNetwork` 使用 shell 参数展开 `${i##*/}`
//! 替代 `basename` 命令，避免对 initrd 中可能不存在的 coreutils 的依赖。
//!
//! **HTTP 通信**：由内置 Zig 原生客户端实现（`initrd/http.zig`），不依赖
//! 外部 `curl`。连接建立最多等待 10 秒；API 请求按 30 秒 socket 空闲超时，
//! rootfs Range 按 120 秒 socket 空闲超时，持续有数据时不限制总下载时长。
//! 自身只编排与校验，不实现第二套挂载栈。
//!
//! **安全**：切根前清零 capability；raw token 只驻内存（来自 capsule），不落盘。
//! `switch_root` 以 `execve`（replace）接管 PID 1：子进程无法删除 PID-1 旧根。
//!
//! **构建配置**（见 `build.zig`）：`single_threaded = true` 避免 Zig stdlib
//! 引入 libpthread 依赖（glibc < 2.34 的 `libpthread.so.0` 在最小 initrd 中
//! 可能不存在）。该开关不降低 GLIBC symbol version，旧发行版仍须使用对应
//! sysroot 交叉编译；取消时必须随 `/init` 提供目标 ISO/sysroot 的完整 ELF
//! interpreter/DT_NEEDED 闭包，不能复制构建宿主库。`strip = true` 减小体积。
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
extern "c" fn ioctl(fd: c_int, request: c_ulong, argp: *anyopaque) c_int;

/// initrd 环境的 PATH：覆盖常见 Linux、dracut 和管理员本地路径。
const initrd_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/run/current-system/sw/bin:/run/current-system/sw/sbin";

/// 恢复 vendor installer initrd 的硬件自动发现流程。脚本只触发 udev
/// subsystem/device coldplug，具体模块完全由 ISO 规则与内核 modalias 决定。
const hardware_coldplug_script =
    \\mkdir -p /run/udev
    \\if [ -x /usr/lib/systemd/systemd-udevd ] && [ -x /usr/bin/udevadm ]; then
    \\ /usr/lib/systemd/systemd-udevd --daemon >/dev/console 2>&1
    \\ /usr/bin/udevadm trigger --type=subsystems --action=add
    \\ /usr/bin/udevadm trigger --type=devices --action=add
    \\ /usr/bin/udevadm settle --timeout=10
    \\fi
;

/// 向 stderr（console）输出一行日志。在 initrd 中 stderr 连接到串口控制台。
/// 与 `http.zig` 中的 log 函数一致，使用 write(2) 直接输出。
/// R11: 同时追加写入 /run/initrd.log，用于 switch_root 前复制到无盘 overlay，
/// 使 initrd 阶段的启动日志在切根后仍然可用用于后续分析。
var initrd_log_fd: i32 = -1;
/// 当前启动阶段。PID 1 的任意错误最终都会连同此阶段打印到控制台，避免
/// `try` 直接冒泡后只留下上一条成功操作日志、误导为“卡在 HTTP 请求”。
var current_stage: []const u8 = "process.start";
var diagnostic_node: []const u8 = "(unknown)";
var diagnostic_session: []const u8 = "(unknown)";

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.c.write(2, msg.ptr, msg.len);
    if (initrd_log_fd >= 0) _ = std.c.write(initrd_log_fd, msg.ptr, msg.len);
}

// PR3-1（token 简化）：diskless capsule 只携带 session id + event:append token。
// config/rootfs/agent 读取作用域 token 已删除 —— initrd 通过 peer-IP 引导认证
// （boot_session.Store）获取 BootConfig 和 rootfs/AgentPlan 等读取资源。
const capsule_event_token_path = "/capsule/event.token";
const capsule_session_path = "/capsule/session";
const cmdline_path = "/proc/cmdline";
const handoff_dir = "/merged/var/lib/nodeforge";
const handoff_path = "/merged/var/lib/nodeforge/boot.json";
const event_token_dir = "/merged/var/lib/nodeforge/credentials";
/// v0.4 token 简化：此文件存储 boot_session 能力 token（替代 v0.2 的 agent:read
/// scope token），供 agent pre-init 拉取 agent-plan/payload。
const capability_token_path = "/merged/var/lib/nodeforge/credentials/capability.token";
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

fn moveMount(comptime source: [:0]const u8, comptime target: [:0]const u8) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedOperatingSystem;
    const rc = std.os.linux.mount(source.ptr, target.ptr, null, std.os.linux.MS.MOVE, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.MoveMountFailed;
}

fn enterRoot(comptime root: [:0]const u8) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedOperatingSystem;
    // 将新根 mount tree 递归设为 PRIVATE，切断与 initramfs root 的 MS_SHARED
    // 传播关系。chroot 不创建新 mount namespace，只是换根目录；若不设 PRIVATE，
    // systemd 接管后在 per-service 私有 namespace 中创建的 credential tmpfs
    // （如 /run/credentials/systemd-journald.service）会通过 SHARED 传播链路
    // 回泄到主 namespace，导致 df 能看到本应隔离的挂载。与 dracut switch_root
    // 前的 `mount --make-rprivate /sysroot` 等价。best-effort：已经是 PRIVATE
    // 时返回 EINVAL，忽略即可。
    const prop_rc = std.os.linux.mount(root.ptr, root.ptr, null, std.os.linux.MS.PRIVATE | std.os.linux.MS.REC, 0);
    _ = std.os.linux.errno(prop_rc);
    if (std.os.linux.errno(std.os.linux.chroot(root.ptr)) != .SUCCESS) return error.ChrootFailed;
    if (std.os.linux.errno(std.os.linux.chdir("/")) != .SUCCESS) return error.ChdirFailed;
}

const Cmdline = struct {
    config_url: ?[]const u8 = null,
    node: ?[]const u8 = null,
    session: ?[]const u8 = null,
    kernel_args: ?[]const u8 = null,
    mac: ?[]const u8 = null,
    ip: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    gateway: ?[]const u8 = null,
    discovery: bool = false,
    discovery_session: ?[]const u8 = null,
    discovery_url: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        log(
            "\n[nodeforge-initrd] FATAL: diskless boot aborted\n" ++
                "[nodeforge-initrd] FATAL: stage={s} error={t} node={s} session={s}\n" ++
                "[nodeforge-initrd] FATAL: inspect the preceding [nodeforge-initrd] diagnostics for measured and required values\n",
            .{ current_stage, err, diagnostic_node, diagnostic_session },
        );
        // PID 1 返回只会触发不透明的 kernel panic。保持控制台上的最终诊断，
        // 让操作员能够抄录错误或通过虚拟机控制台复位。
        while (true) std.Io.sleep(init.io, .fromSeconds(3600), .awake) catch {};
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    // 内核启动 PID 1 时不设置环境变量。显式设置 PATH 确保 ip/DHCP client/
    // switch_root/losetup 等 /usr/sbin 下的命令可通过裸名调用。
    _ = setenv("PATH", initrd_path, 1);

    current_stage = "bootstrap.mounts";
    log("[nodeforge-initrd] stage={s}: mounting /proc /sys /dev /run...\n", .{current_stage});
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
    mountBootstrap("tmpfs", "/run", "tmpfs", "mode=0755") catch |err|
        log("[nodeforge-initrd] WARNING: cannot mount dedicated /run tmpfs: {t}; continuing only if vendor initrd already provides writable /run\n", .{err});
    // R11: 打开 initrd 日志文件，用于 switch_root 前复制到无盘系统。
    // Zig 0.16 的 std.c.O 使用 ACCMODE 枚举（.WRONLY）+ CREAT/TRUNC 布尔字段，
    // 而非传统 POSIX 的 O_WRONLY/O_CREAT/O_TRUNC 前缀名。
    initrd_log_fd = std.c.open("/run/initrd.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    log("[nodeforge-initrd] initrd log retention enabled (/run/initrd.log)\n", .{});
    // 恢复 vendor installer initrd 的硬件 coldplug 语义。自定义 /init 替换了
    // systemd 后，udev 不会自行启动；若不触发 modalias，ISO 中即使包含正确
    // 网卡驱动，内核也不会自动加载，DHCP 客户端最终看不到任何广播接口。
    // 这里只运行 ISO 自带的 udev 规则，不指定 vmxnet3/virtio_net 等具体模块。
    try mustRun(io, allocator, &.{ "sh", "-c", hardware_coldplug_script });
    // 加载 squashfs/loop/overlay 内核模块（这些在 Rocky 内核中是模块而非内置）。
    // 在挂载 squashfs rootfs 和 overlay 合并前必须已加载。
    try runIgnore(io, allocator, &.{ "/sbin/modprobe", "squashfs" });
    try runIgnore(io, allocator, &.{ "/sbin/modprobe", "loop" });
    try runIgnore(io, allocator, &.{ "/sbin/modprobe", "overlay" });
    const cmdline = try readCmdline(io, allocator);
    defer freeCmdline(allocator, cmdline);
    log("[nodeforge-initrd] boot mode parsed: discovery={} node={}\n", .{ cmdline.discovery, cmdline.node != null });

    // 基本网络：按 IP/MAC 复用 PXE 租约；旧启动参数才调用 vendor DHCP client。
    current_stage = "network.configure";
    log("[nodeforge-initrd] stage={s}: bringing up network...\n", .{current_stage});
    try bringUpNetwork(io, allocator, &cmdline);
    log("[nodeforge-initrd] network setup done\n", .{});

    if (cmdline.discovery) return discoveryProbe(io, allocator, &cmdline);

    // PR3-1（token 简化）：diskless capsule 只携带 event:append token + delivery
    // session id。config/rootfs/agent 三个读取作用域 token 已删除——initrd 通过
    // peer-IP 引导认证获取 BootConfig，其中内嵌 boot_session 能力 token（access
    // 对象），仅用于后续 AgentPlan 等小型敏感控制面读取。
    //
    // 两 session 模型：
    // - `session`（delivery session，从 capsule/cmdline 读取）：配合 event_token
    //   推进 lifecycle 事件与 facts 上报。event:append token 是跨网络跳变存活的
    //   派生凭证，绑定 delivery session。
    // - `bc.access_session_id`（boot_session id，从 BootConfig.access 解析）：
    //   配合 `bc.access_bearer_token`（随机能力 token）读取 AgentPlan；rootfs/
    //   payload 固定大对象只走 peer/session/digest 数据面，不携带 token。
    const event_token = try readToken(io, allocator, capsule_event_token_path);
    defer allocator.free(event_token);

    // delivery session 优先从 cmdline 读取（direct boot / QEMU -append 模式）；
    // 不在 cmdline 时从 capsule 文件读取（PXE boot 模式，GRUB cmdline 不含
    // session，由 capsule 文件提供 diskless delivery session ID）。
    const session = blk: {
        if (cmdline.session) |s| break :blk try allocator.dupe(u8, s);
        break :blk readCapsuleHex(io, allocator, capsule_session_path, 32) catch {
            log("[nodeforge-initrd] error: missing nodeforge.session in cmdline and no /capsule/session file\n", .{});
            return error.MissingSession;
        };
    };
    defer allocator.free(session);
    const node = cmdline.node orelse return error.MissingNode;
    diagnostic_node = node;
    diagnostic_session = session;
    log("[nodeforge-initrd] session={s} node={s}\n", .{ session, node });
    current_stage = "boot_config.fetch";
    log("[nodeforge-initrd] fetching BootConfig from {s} (peer-IP bootstrap auth)...\n", .{cmdline.config_url orelse "(none)"});
    // 引导认证：无 Authorization / X-NodeForge-Session header，服务端通过 peer-IP
    // 匹配 DHCP lease-IP 认证（与 install 路径一致的 bootstrap proof）。
    const config_url_parsed = try http.Url.parse(cmdline.config_url orelse return error.MissingConfigUrl);
    const config_json = try http.getWithRetry(io, allocator, config_url_parsed, &.{}, 3);
    defer allocator.free(config_json);
    const bc = try parseBootConfig(allocator, config_json);
    log("[nodeforge-initrd] BootConfig fetched, rootfs size={d} access_session={s}\n", .{ bc.rootfs_size, bc.access_session_id });
    defer freeBootConfig(allocator, &bc);
    var next_event_seq: u64 = 0;
    var current_phase: []const u8 = "boot.config_fetched";
    errdefer postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.failed") catch {};

    // 下载 rootfs 并 SHA-512 校验。
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.initrd_started");
    next_event_seq += 1;
    current_phase = "diskless.initrd_started";
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.rootfs_downloading");
    next_event_seq += 1;
    current_phase = "diskless.rootfs_downloading";
    current_stage = "memory.preflight";
    const meminfo = try captureRun(io, allocator, &.{ "cat", "/proc/meminfo" });
    defer allocator.free(meminfo);
    const available_budget = try memory.memAvailableBytes(meminfo);
    const memory_bytes = try memory.memTotalBytes(meminfo);
    log(
        "[nodeforge-initrd] stage={s}: MemTotal={d} MemAvailable={d} rootfs_compressed={d} rootfs_uncompressed={?d} payload={d} tmpfs_percent={d} minimum_free={d} safety_margin={d}\n",
        .{ current_stage, memory_bytes, available_budget, bc.rootfs_size, bc.rootfs_uncompressed_size, bc.node_payload_size, bc.tmpfs_percent, bc.minimum_free_bytes, bc.safety_margin_bytes },
    );
    current_stage = "facts.upload";
    postFacts(io, allocator, bc.facts_url, event_token, session, memory_bytes) catch |err|
        log("[nodeforge-initrd] WARNING: authenticated facts upload failed: {t}\n", .{err});
    current_stage = "memory.capacity_gate";
    const scaled_upper = std.math.mul(u64, available_budget, bc.tmpfs_percent) catch return error.MemoryBudgetOverflow;
    const upper_limit = if (bc.rootfs_uncompressed_size) |uncompressed_size|
        memory.upperLimit(.{
            .available_budget = available_budget,
            .rootfs_size = bc.rootfs_size,
            .rootfs_uncompressed_size = uncompressed_size,
            .node_payload_size = bc.node_payload_size,
            .tmpfs_percent = bc.tmpfs_percent,
            .minimum_free_bytes = bc.minimum_free_bytes,
            .safety_margin_bytes = bc.safety_margin_bytes,
        }) catch |err| {
            const required = memory.minimumAvailableBytes(.{
                .available_budget = 0,
                .rootfs_size = bc.rootfs_size,
                .rootfs_uncompressed_size = uncompressed_size,
                .node_payload_size = bc.node_payload_size,
                .tmpfs_percent = bc.tmpfs_percent,
                .minimum_free_bytes = bc.minimum_free_bytes,
                .safety_margin_bytes = bc.safety_margin_bytes,
            }) catch 0;
            log(
                "[nodeforge-initrd] ERROR: memory capacity gate rejected diskless boot: error={t} MemAvailable={d} required_min_available={d} deficit={d}\n",
                .{ err, available_budget, required, if (required > available_budget) required - available_budget else 0 },
            );
            return err;
        }
    else blk: {
        // 未知不等于 0 字节，也不能拿压缩大小冒充展开大小。继续启动并仅使用
        // Profile 配置的 tmpfs 百分比；实际分配失败仍由 mount/write 自然报告。
        log("[nodeforge-initrd] WARNING: rootfs uncompressed size is unknown; skipping hard memory-capacity check\n", .{});
        break :blk scaled_upper / 100;
    };
    current_stage = "rootfs.download";
    log("[nodeforge-initrd] stage={s}: starting rootfs download ({d} bytes)\n", .{ current_stage, bc.rootfs_size });
    // rootfs 是 peer-IP + immutable digest 数据面，不传播 BootConfig access token。
    try downloadRootfs(io, allocator, &bc);
    current_stage = "rootfs.verify";
    log("[nodeforge-initrd] rootfs downloaded, verifying SHA-512...\n", .{});
    verifySha512(io, rootfs_blob, bc.rootfs_sha512) catch return error.RootfsHashMismatch;
    log("[nodeforge-initrd] rootfs verified, mounting...\n", .{});
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.rootfs_verified");
    next_event_seq += 1;
    current_phase = "diskless.rootfs_verified";

    // 只读 lower（loop 挂载 squashfs）+ tmpfs upper/work（同一 tmpfs）+ overlay 合并。
    // squashfs/loop/overlay 模块已在 main() 开头加载，此处直接挂载。
    current_stage = "rootfs.mount_overlay";
    log("[nodeforge-initrd] stage={s}: creating mount points...\n", .{current_stage});
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
    current_stage = "handoff.write";
    log("[nodeforge-initrd] stage={s}: writing AgentPlan locator and credentials\n", .{current_stage});
    // handoff：AgentPlan locator + capability token（读取用）+ event_token（lifecycle 用）
    // 交给 agent pre-init（写入新根 /var/lib）。read_session（boot_session id）也写入
    // handoff，使 agent pre-init 能用正确的 session header 发起读取请求。
    try writeHandoff(io, allocator, &bc, session, node, bc.access_bearer_token, event_token);
    try postLifecycle(io, allocator, bc.event_url, event_token, session, next_event_seq, current_phase, "diskless.switching_root");
    next_event_seq += 1;
    current_phase = "diskless.switching_root";
    // token 已分别复制到 0400 handoff credential，清零 initrd 内存副本。
    @memset(event_token, 0);

    // R11: 将 initrd 日志留存到无盘 overlay，使切根后可查看完整启动链日志。
    // /run/initrd.log 由 log() 函数在每次调用时追加写入；此处复制到 overlay
    // upper 的 /var/lib/nodeforge/initrd.log，同时捕获 dmesg 用于内核层诊断。
    log("[nodeforge-initrd] retaining logs to overlay...\n", .{});
    const retain_logs = try std.fmt.allocPrint(allocator, "mkdir -p /merged/var/lib/nodeforge && cp /run/initrd.log /merged/var/lib/nodeforge/initrd.log 2>/dev/null; dmesg > /merged/var/lib/nodeforge/initrd-dmesg.log 2>/dev/null; printf '%s\\n' '{s}' > /merged/var/lib/nodeforge/session-id 2>/dev/null", .{session});
    defer allocator.free(retain_logs);
    runIgnore(io, allocator, &.{ "sh", "-c", retain_logs }) catch {};

    // 直接通过内核 syscall 把 bootstrap mounts 交给新根并 chroot，避免 util-linux
    // mount 在移动 /run 后因无法更新 utab 返回 16，也避免依赖 vendor initrd 或
    // rootfs 中的 mount/chroot 命令及其 libc closure。replace 保持 agent 为 PID 1。
    current_stage = "switch_root.move_mounts";
    log("[nodeforge-initrd] stage={s}: moving kernel filesystems\n", .{current_stage});
    inline for (.{ "proc", "sys", "dev", "run" }) |mount_name| {
        const source = "/" ++ mount_name;
        const target = merged_mnt ++ "/" ++ mount_name;
        try moveMount(source, target);
    }
    current_stage = "switch_root.enter";
    try enterRoot(merged_mnt);
    current_stage = "switch_root.exec_agent";
    log("[nodeforge-initrd] stage={s}: exec /usr/sbin/nodeforge-agent --pre-init in new root\n", .{current_stage});
    return std.process.replace(io, .{ .argv = &.{ "/usr/sbin/nodeforge-agent", "--pre-init" } });
}

/// 优先按已配置的租约 IP、其次按 PXE MAC 确定网卡并取得 IPv4 配置。
/// 只有缺少控制面静态租约事实的兼容路径才尝试 DHCP client；所有路径都有界
/// 退出，避免 PID 1 无限阻塞。
fn bringUpNetwork(io: std.Io, allocator: std.mem.Allocator, cmdline: *const Cmdline) !void {
    if (cmdline.ip != null and cmdline.prefix != null) {
        // PXE DHCP lease 已由 daemon 确认；直接复用该地址，避免自定义 PID 1
        // 依赖 vendor systemd/NetworkManager 或宿主机注入的 DHCP client。
        // 参数由控制面从结构化 DHCP 配置生成，只接受 IPv4/prefix 字符集。
        if ((cmdline.mac != null and !validMac(cmdline.mac.?)) or
            !validIpv4(cmdline.ip.?) or !validPrefix(cmdline.prefix.?) or
            (cmdline.gateway != null and !validIpv4(cmdline.gateway.?)))
            return error.InvalidBootstrapNetwork;
        log("[nodeforge-initrd] applying PXE lease {s}/{s} mac={s} gateway={s}\n", .{
            cmdline.ip.?,
            cmdline.prefix.?,
            cmdline.mac orelse "(none)",
            cmdline.gateway orelse "(none)",
        });
        const interface = try configureBootstrapIpv4(io, allocator, cmdline.mac, cmdline.ip.?, cmdline.prefix.?);
        if (cmdline.gateway) |gateway| {
            try mustRun(io, allocator, &.{ "/sbin/ip", "route", "replace", "default", "via", gateway, "dev", interface });
        }
        log("[nodeforge-initrd] PXE lease configured with native ioctl\n", .{});
        log("[nodeforge-initrd] PXE lease network stage returning\n", .{});
        return;
    } else {
        try runIgnore(io, allocator, &.{ "ip", "link", "set", "lo", "up" });
        // 用 ${i##*/} 取接口名，不依赖 basename。
        try runIgnore(io, allocator, &.{ "sh", "-c", "for i in /sys/class/net/*; do dev=${i##*/}; [ \"$dev\" != lo ] && ip link set \"$dev\" up && break; done" });
    }
    const existing = try captureRun(io, allocator, &.{ "/sbin/ip", "-4", "-o", "addr", "show", "scope", "global" });
    defer allocator.free(existing);
    if (std.mem.trim(u8, existing, " \t\r\n").len != 0) {
        log("[nodeforge-initrd] using preconfigured network: {s}", .{existing});
        return;
    }
    try runIgnore(io, allocator, &.{ "mkdir", "-p", "/var/lib/dhclient" });
    try mustRun(io, allocator, &.{
        "sh", "-c",
        \\PATH=/usr/bin:/usr/sbin:/bin:/sbin
        \\export PATH
        \\udhcpc_path=''
        \\for candidate in /usr/sbin/udhcpc /sbin/udhcpc /usr/bin/udhcpc /bin/udhcpc; do [ -x "$candidate" ] && udhcpc_path="$candidate" && break; done
        \\if [ -n "$udhcpc_path" ]; then
        \\ "$udhcpc_path" -n -q -t 5 -T 3 -s /usr/sbin/nodeforge-udhcpc-script >/dev/console 2>&1
        \\ if [ -n "$(/sbin/ip -4 -o addr show scope global)" ]; then exit 0; fi
        \\ echo 'udhcpc did not configure a global IPv4 address; trying dhclient' >&2
        \\fi
        \\if [ -x /usr/sbin/dhclient ]; then
        \\ exec /usr/sbin/dhclient -v -1 -sf /usr/sbin/nodeforge-dhclient-script >/dev/console 2>&1
        \\fi
        \\echo 'no supported DHCP client (udhcpc or dhclient)' >&2
        \\exit 127
    });
    const addresses = try captureRun(io, allocator, &.{ "/sbin/ip", "-4", "-o", "addr", "show", "scope", "global" });
    defer allocator.free(addresses);
    if (std.mem.trim(u8, addresses, " \t\r\n").len == 0) return error.DhcpAddressMissing;
    log("[nodeforge-initrd] DHCP configured: {s}", .{addresses});
}

const Ifreq = extern struct {
    name: [16]u8 = [_]u8{0} ** 16,
    data: [24]u8 = [_]u8{0} ** 24,
};

fn configureBootstrapIpv4(io: std.Io, allocator: std.mem.Allocator, mac_text: ?[]const u8, ip_text: []const u8, prefix_text: []const u8) ![]const u8 {
    const ip = parseIpv4(ip_text) orelse return error.InvalidBootstrapNetwork;
    const socket_rc = std.os.linux.socket(std.os.linux.AF.INET, std.os.linux.SOCK.DGRAM, 0);
    if (std.os.linux.errno(socket_rc) != .SUCCESS) return error.NetworkSocketFailed;
    const fd: c_int = @intCast(socket_rc);
    defer _ = std.c.close(fd);

    var dir = try std.Io.Dir.openDirAbsolute(io, "/sys/class/net", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var interface_buf: [15]u8 = undefined;
    var interface_len: usize = 0;

    // `ip=dhcp` 可能已由内核/vendor initramfs 配好地址。先以实际地址反查接口，
    // 这是最强的现场事实；找不到时才使用 DHCP/TFTP 会话携带的 PXE MAC。
    while (try iterator.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "lo") or entry.name.len >= 16) continue;
        var address_request: Ifreq = .{};
        @memcpy(address_request.name[0..entry.name.len], entry.name);
        if (ioctl(fd, 0x8915, &address_request) == 0 and std.mem.eql(u8, address_request.data[4..8], &ip)) { // SIOCGIFADDR
            @memcpy(interface_buf[0..entry.name.len], entry.name);
            interface_len = entry.name.len;
            break;
        }
    }
    if (interface_len == 0 and mac_text != null) {
        iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, "lo") or entry.name.len >= 16) continue;
            const address_path = try std.fmt.allocPrint(allocator, "/sys/class/net/{s}/address", .{entry.name});
            defer allocator.free(address_path);
            const address = readFile(io, allocator, address_path) catch continue;
            defer allocator.free(address);
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, address, " \t\r\n"), mac_text.?)) continue;
            @memcpy(interface_buf[0..entry.name.len], entry.name);
            interface_len = entry.name.len;
            break;
        }
    }
    if (interface_len == 0) return error.NetworkInterfaceMissing;
    const name = interface_buf[0..interface_len];
    const prefix = std.fmt.parseInt(u8, prefix_text, 10) catch return error.InvalidBootstrapNetwork;
    const mask_value: u32 = if (prefix == 0) 0 else ~@as(u32, 0) << @intCast(32 - prefix);
    const mask = [4]u8{
        @intCast((mask_value >> 24) & 0xff),
        @intCast((mask_value >> 16) & 0xff),
        @intCast((mask_value >> 8) & 0xff),
        @intCast(mask_value & 0xff),
    };

    var request: Ifreq = .{};
    @memcpy(request.name[0..name.len], name);
    if (ioctl(fd, 0x8913, &request) != 0) return error.NetworkIoctlFailed; // SIOCGIFFLAGS
    const current_flags = std.mem.readInt(u16, request.data[0..2], .native);
    std.mem.writeInt(u16, request.data[0..2], current_flags | 0x1, .native); // IFF_UP
    if (ioctl(fd, 0x8914, &request) != 0) return error.NetworkIoctlFailed; // SIOCSIFFLAGS

    setSockaddr(&request, ip);
    if (ioctl(fd, 0x8916, &request) != 0) return error.NetworkIoctlFailed; // SIOCSIFADDR
    setSockaddr(&request, mask);
    if (ioctl(fd, 0x891c, &request) != 0) return error.NetworkIoctlFailed; // SIOCSIFNETMASK
    return try allocator.dupe(u8, name);
}

fn setSockaddr(request: *Ifreq, address: [4]u8) void {
    @memset(&request.data, 0);
    std.mem.writeInt(u16, request.data[0..2], std.os.linux.AF.INET, .native);
    @memcpy(request.data[4..8], &address);
}

fn parseIpv4(value: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var index: usize = 0;
    var it = std.mem.splitScalar(u8, value, '.');
    while (it.next()) |part| {
        if (index == result.len or part.len == 0) return null;
        result[index] = std.fmt.parseInt(u8, part, 10) catch return null;
        index += 1;
    }
    return if (index == result.len) result else null;
}

fn validIpv4(value: []const u8) bool {
    if (value.len < 7 or value.len > 15) return false;
    var dots: u8 = 0;
    for (value) |c| {
        if (c == '.') {
            dots += 1;
        } else if (!std.ascii.isDigit(c)) return false;
    }
    return dots == 3;
}

fn validMac(value: []const u8) bool {
    if (value.len != 17) return false;
    for (value, 0..) |c, index| {
        if (index % 3 == 2) {
            if (c != ':') return false;
        } else if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn validPrefix(value: []const u8) bool {
    if (value.len == 0 or value.len > 2) return false;
    var parsed: u8 = 0;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return false;
        parsed = parsed * 10 + (c - '0');
    }
    return parsed <= 32;
}

/// 把 AgentPlan locator + agent/event token 写入新根 `/var/lib/nodeforge`（boot.json +
/// 0400 credential 文件），交给 agent pre-init；切根后持久可读。
/// handoff schema v2：在 v1 基础上增加 `read_session`（boot_session 能力认证用
/// session id），与 `session`（delivery session id，event:append 用）分离。
/// v0.4 token 简化后，agent pre-init 需要两个 session id：
/// - `session`（delivery）：配合 event_token 推进 lifecycle 事件
/// - `read_session`（boot_session）：配合 capability token 拉取 agent-plan/payload
fn writeHandoff(io: std.Io, allocator: std.mem.Allocator, bc: *const BootConfig, session: ?[]const u8, node: ?[]const u8, capability_token: []const u8, event_token: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, handoff_dir);
    try std.Io.Dir.cwd().createDirPath(io, event_token_dir);
    const json = try std.fmt.allocPrint(allocator, "{{\"schema_version\":2,\"node\":\"{s}\",\"session\":\"{s}\",\"read_session\":\"{s}\",\"agent_plan_url\":\"{s}\",\"agent_plan_digest\":\"{s}\",\"event_url\":\"{s}\"}}\n", .{
        node orelse "",
        session orelse "",
        bc.access_session_id,
        bc.agent_plan_url,
        bc.agent_plan_digest,
        bc.event_url,
    });
    defer allocator.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = handoff_path, .data = json });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = capability_token_path, .data = capability_token });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = event_token_path, .data = event_token });
    try mustRun(io, allocator, &.{ "chmod", "0400", capability_token_path });
    try mustRun(io, allocator, &.{ "chmod", "0400", event_token_path });
}

/// 服务端 BootConfig v3 解析结果（per-Node 短时 DTO）。字符串字段由 `parseBootConfig`
/// dupe 到 arena 之外，必须经 `freeBootConfig` 释放。
const BootConfig = struct {
    rootfs_url: []u8,
    rootfs_sha512: []u8,
    agent_plan_url: []u8,
    agent_plan_digest: []u8,
    event_url: []u8,
    facts_url: []u8,
    /// rootfs 字节大小，HEAD 与最终落盘大小都须与之精确相等。
    rootfs_size: u64,
    /// null 表示 nodeforged 构建时未能测得展开大小；此时跳过容量硬校验。
    rootfs_uncompressed_size: ?u64,
    /// tmpfs upper 占 MemAvailable 的百分比上限。
    tmpfs_percent: u8,
    /// 内存闸保留的最小空闲字节（低于即 fail-closed，见 memory.upperLimit）。
    minimum_free_bytes: u64,
    /// squashfs + upper + payload 之外再扣减的额外安全余量。
    safety_margin_bytes: u64,
    /// Node 级 payload 预算（纳入 upper limit 扣减，防 first-boot 写爆 tmpfs）。
    node_payload_size: u64,
    /// v0.4 token 简化：引导认证签发的 boot_session 能力凭证，仅用于
    /// AgentPlan 控制面读取；rootfs/payload 大对象不携带此凭证。
    access_session_id: []u8,
    access_bearer_token: []u8,
};

/// 从 BootConfig v3 JSON 解析 rootfs/overlay/agent_plan/event/facts 定位与内存预算，
/// 以及 v0.4 引导认证签发的 access 凭证（boot_session 能力 token + session_id）。
fn parseBootConfig(allocator: std.mem.Allocator, json: []const u8) !BootConfig {
    const Parsed = struct {
        schema_version: u32,
        rootfs: struct { url: []const u8, sha512: []const u8, size: u64, uncompressed_size: ?u64 = null },
        overlay: struct {
            tmpfs_percent: u8,
            minimum_free_bytes: u64,
            safety_margin_bytes: u64,
            node_payload_size: u64 = 0,
        },
        agent_plan: struct { url: []const u8, digest: []const u8 },
        event_url: []const u8,
        facts_url: []const u8,
        access: struct { session_id: []const u8, bearer_token: []const u8 },
    };
    const p = try std.json.parseFromSlice(Parsed, allocator, json, .{ .ignore_unknown_fields = true });
    defer p.deinit();
    if (p.value.schema_version != 3) return error.UnsupportedBootConfigSchema;
    return .{
        .rootfs_url = try allocator.dupe(u8, p.value.rootfs.url),
        .rootfs_sha512 = try allocator.dupe(u8, p.value.rootfs.sha512),
        .agent_plan_url = try allocator.dupe(u8, p.value.agent_plan.url),
        .agent_plan_digest = try allocator.dupe(u8, p.value.agent_plan.digest),
        .event_url = try allocator.dupe(u8, p.value.event_url),
        .facts_url = try allocator.dupe(u8, p.value.facts_url),
        .rootfs_size = p.value.rootfs.size,
        .rootfs_uncompressed_size = p.value.rootfs.uncompressed_size,
        .tmpfs_percent = p.value.overlay.tmpfs_percent,
        .minimum_free_bytes = p.value.overlay.minimum_free_bytes,
        .safety_margin_bytes = p.value.overlay.safety_margin_bytes,
        .node_payload_size = p.value.overlay.node_payload_size,
        .access_session_id = try allocator.dupe(u8, p.value.access.session_id),
        .access_bearer_token = try allocator.dupe(u8, p.value.access.bearer_token),
    };
}

/// 释放 `parseBootConfig` dupe 的字符串字段（URL/digest/access 凭证等）。
fn freeBootConfig(allocator: std.mem.Allocator, bc: *const BootConfig) void {
    allocator.free(bc.rootfs_url);
    allocator.free(bc.rootfs_sha512);
    allocator.free(bc.agent_plan_url);
    allocator.free(bc.agent_plan_digest);
    allocator.free(bc.event_url);
    allocator.free(bc.facts_url);
    allocator.free(bc.access_session_id);
    allocator.free(bc.access_bearer_token);
}

test "BootConfig v3 requires authenticated facts URL" {
    const json =
        \\{"schema_version":3,"rootfs":{"url":"http://s/rootfs","sha512":"ab","size":10,"uncompressed_size":20},"overlay":{"tmpfs_percent":50,"minimum_free_bytes":1,"safety_margin_bytes":2,"node_payload_size":3},"agent_plan":{"url":"http://s/plan","digest":"cd"},"event_url":"http://s/events","facts_url":"http://s/facts","access":{"session_id":"bs1","bearer_token":"cap1"}}
    ;
    const parsed = try parseBootConfig(std.testing.allocator, json);
    defer freeBootConfig(std.testing.allocator, &parsed);
    try std.testing.expectEqualStrings("http://s/facts", parsed.facts_url);
    try std.testing.expectEqualStrings("bs1", parsed.access_session_id);
    try std.testing.expectEqualStrings("cap1", parsed.access_bearer_token);
    try std.testing.expectError(error.UnsupportedBootConfigSchema, parseBootConfig(std.testing.allocator,
        \\{"schema_version":2,"rootfs":{"url":"u","sha512":"a","size":1},"overlay":{"tmpfs_percent":50,"minimum_free_bytes":1,"safety_margin_bytes":1},"agent_plan":{"url":"u","digest":"d"},"event_url":"u","facts_url":"u","access":{"session_id":"s","bearer_token":"t"}}
    ));
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
    const status = http.post(io, allocator, event_url, &.{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "X-NodeForge-Session", .value = session },
        .{ .name = "Content-Type", .value = "application/json" },
    }, body) catch |err| {
        log("[nodeforge-initrd] WARNING: lifecycle event upload failed: phase={s} seq={d} error={t}\n", .{ phase, seq, err });
        return;
    };
    if (status < 200 or status >= 300)
        log("[nodeforge-initrd] WARNING: lifecycle event rejected: phase={s} seq={d} status={d}\n", .{ phase, seq, status });
}

/// event capability 同时是本 session 的 telemetry 写凭据；facts 写入不消耗或
/// 推进 lifecycle event_seq。失败不削弱当前启动的本地 MemAvailable 硬闸。
fn postFacts(io: std.Io, allocator: std.mem.Allocator, url: []const u8, token: []const u8, session: []const u8, memory_bytes: u64) !void {
    // 采集 DMI 硬件事实（与 kickstart %pre 的 nf_fact 等价）。纯 diskless 节点
    // 从未走过 install 路径，需要 initrd 自行上报 serial/uuid/vendor/model。
    // sysfs 文件可能不存在（某些固件/容器无 DMI），读失败或空值在序列化时
    // 映射为 null（sanitizeDmi），server 端按可选字段处理。
    const serial = readSysfsTrimmed(io, allocator, "/sys/class/dmi/id/product_serial");
    defer if (serial) |s| allocator.free(s);
    const uuid = readSysfsTrimmed(io, allocator, "/sys/class/dmi/id/product_uuid");
    defer if (uuid) |u| allocator.free(u);
    const vendor = readSysfsTrimmed(io, allocator, "/sys/class/dmi/id/sys_vendor");
    defer if (vendor) |v| allocator.free(v);
    const model = readSysfsTrimmed(io, allocator, "/sys/class/dmi/id/product_name");
    defer if (model) |m| allocator.free(m);
    const Payload = struct {
        memory_bytes: u64,
        serial_number: ?[]const u8 = null,
        product_uuid: ?[]const u8 = null,
        vendor: ?[]const u8 = null,
        model: ?[]const u8 = null,
    };
    // 用正规 JSON 序列化而不是手工 `"{s}"` 内插：DMI 值含 `"`/`\`/控制字符时
    // 手工拼接会产出非法 body，导致 daemon 400 并把连带的 memory_bytes 一起丢。
    const body = try std.json.Stringify.valueAlloc(allocator, Payload{
        .memory_bytes = memory_bytes,
        .serial_number = sanitizeDmi(serial),
        .product_uuid = sanitizeDmi(uuid),
        .vendor = sanitizeDmi(vendor),
        .model = sanitizeDmi(model),
    }, .{});
    defer allocator.free(body);
    const facts_url = try http.Url.parse(url);
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(auth);
    const status = try http.post(io, allocator, facts_url, &.{
        .{ .name = "Authorization", .value = auth },
        .{ .name = "X-NodeForge-Session", .value = session },
        .{ .name = "Content-Type", .value = "application/json" },
    }, body);
    if (status < 200 or status >= 300) return error.FactsUploadRejected;
}

/// Discovery mode is intentionally a separate, non-destructive initrd path:
/// it reads DMI facts, posts them over the lease-bound probe session, and then
/// remains idle. It never fetches BootConfig/AgentPlan/rootfs, writes a block
/// device, or starts an agent shell.
fn discoveryProbe(io: std.Io, allocator: std.mem.Allocator, cmdline: *const Cmdline) !void {
    const session = cmdline.discovery_session orelse return error.MissingDiscoverySession;
    const url_text = cmdline.discovery_url orelse return error.MissingDiscoveryUrl;
    const serial = readSysfsTrimmed(io, allocator, "/sys/class/dmi/id/product_serial");
    defer if (serial) |value| allocator.free(value);
    const uuid = readSysfsTrimmed(io, allocator, "/sys/class/dmi/id/product_uuid");
    defer if (uuid) |value| allocator.free(value);
    const vendor = readSysfsTrimmed(io, allocator, "/sys/class/dmi/id/sys_vendor");
    defer if (vendor) |value| allocator.free(value);
    const product = readSysfsTrimmed(io, allocator, "/sys/class/dmi/id/product_name");
    defer if (product) |value| allocator.free(value);
    const Payload = struct {
        schema_version: u32 = 1,
        mac: ?[]const u8 = null,
        arch: []const u8,
        serial_number: ?[]const u8 = null,
        product_uuid: ?[]const u8 = null,
        vendor: ?[]const u8 = null,
        model: ?[]const u8 = null,
    };
    const body = try std.json.Stringify.valueAlloc(allocator, Payload{
        .mac = cmdline.mac,
        .arch = @tagName(builtin.cpu.arch),
        .serial_number = sanitizeDmi(serial),
        .product_uuid = sanitizeDmi(uuid),
        .vendor = sanitizeDmi(vendor),
        .model = sanitizeDmi(product),
    }, .{});
    defer allocator.free(body);
    log("[nodeforge-initrd] discovery facts serial={s} arch={s} mac={s}\n", .{ sanitizeDmi(serial) orelse "(missing)", @tagName(builtin.cpu.arch), cmdline.mac orelse "(missing)" });
    const url = try http.Url.parse(url_text);
    const session_header = try std.fmt.allocPrint(allocator, "{s}", .{session});
    defer allocator.free(session_header);
    const status = try http.post(io, allocator, url, &.{
        .{ .name = "X-NodeForge-Discovery-Session", .value = session_header },
        .{ .name = "Content-Type", .value = "application/json" },
    }, body);
    if (status < 200 or status >= 300) return error.DiscoveryProbeRejected;
    log("[nodeforge-initrd] discovery facts accepted session={s} serial={s}; remaining idle\n", .{ session, sanitizeDmi(serial) orelse "(missing)" });
    while (true) std.Io.sleep(io, .fromSeconds(3600), .awake) catch {};
}

/// DMI 值进入 JSON body 前的卫生处理：截断到 255 字节并剔除 `< 0x20` 控制
/// 字符；结果为空返回 null（server 端 `validateFacts` 对空串整包拒绝，宁可
/// 丢该可选字段也不能损坏整包）。`"`/`\` 等 JSON 特殊字符由序列化器转义，
/// 不在此处理。
fn sanitizeDmi(value: ?[]u8) ?[]const u8 {
    const raw = value orelse return null;
    var write: usize = 0;
    var read: usize = 0;
    const cap = @min(raw.len, 255);
    while (read < cap) : (read += 1) {
        if (raw[read] < 0x20) continue;
        raw[write] = raw[read];
        write += 1;
    }
    if (write == 0) return null;
    return raw[0..write];
}

/// 读取 sysfs 文件并 trim 空白。文件不存在或不可读时返回 null。
fn readSysfsTrimmed(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256)) catch return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }
    const result = allocator.dupe(u8, trimmed) catch {
        allocator.free(raw);
        return null;
    };
    allocator.free(raw);
    return result;
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
fn downloadRootfs(io: std.Io, allocator: std.mem.Allocator, bc: *const BootConfig) !void {
    const rootfs_url = try http.Url.parse(bc.rootfs_url);
    const expected_etag = try std.fmt.allocPrint(allocator, "\"{s}\"", .{bc.rootfs_sha512});
    defer allocator.free(expected_etag);

    // HEAD：校验 rootfs 元数据（Content-Length/ETag/Accept-Ranges），3 次重试。
    const head_bytes = try http.headWithRetry(io, allocator, rootfs_url, &.{.{ .name = "Accept-Encoding", .value = "identity" }}, 3);
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
            rangeOnce(io, allocator, rootfs_url, expected_etag, offset, end, bc.rootfs_size) catch |err| {
                attempts += 1;
                cwd.deleteFile(io, rootfs_chunk) catch {};
                log(
                    "[nodeforge-initrd] rootfs range failed: bytes={d}-{d} attempt={d}/5 error={t}\n",
                    .{ offset, end, attempts, err },
                );
                if (attempts >= 5) return err;
                const delay_ms: i64 = @as(i64, 1000) << @intCast(attempts - 1);
                log("[nodeforge-initrd] retrying rootfs range after {d}ms\n", .{delay_ms});
                std.Io.sleep(io, .fromMilliseconds(delay_ms), .awake) catch {};
                continue;
            };
            break;
        }
        // 追加 chunk 到 part 文件
        try mustRun(io, allocator, &.{ "sh", "-c", "cat /run/rootfs.squashfs.chunk >> /run/rootfs.squashfs.part" });
        offset = end + 1;
        const percent = if (bc.rootfs_size == 0) 100 else (offset * 100) / bc.rootfs_size;
        log("[nodeforge-initrd] rootfs download progress: {d}/{d} bytes ({d}%)\n", .{ offset, bc.rootfs_size, percent });
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
fn rangeOnce(io: std.Io, allocator: std.mem.Allocator, url: http.Url, etag: []const u8, start: u64, end: u64, total: u64) !void {
    const range_value = try std.fmt.allocPrint(allocator, "bytes={d}-{d}", .{ start, end });
    defer allocator.free(range_value);
    const headers = try http.getToFile(io, allocator, url, &.{
        .{ .name = "Accept-Encoding", .value = "identity" },
        .{ .name = "Range", .value = range_value },
        .{ .name = "If-Range", .value = etag },
    }, rootfs_chunk, 206, end - start + 1);
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
        if (std.mem.startsWith(u8, tok, "nodeforge.mac=")) c.mac = try allocator.dupe(u8, tok["nodeforge.mac=".len..]);
        if (std.mem.startsWith(u8, tok, "nodeforge.ip=")) c.ip = try allocator.dupe(u8, tok["nodeforge.ip=".len..]);
        if (std.mem.startsWith(u8, tok, "nodeforge.prefix=")) c.prefix = try allocator.dupe(u8, tok["nodeforge.prefix=".len..]);
        if (std.mem.startsWith(u8, tok, "nodeforge.gateway=")) c.gateway = try allocator.dupe(u8, tok["nodeforge.gateway=".len..]);
        if (std.mem.eql(u8, tok, "nodeforge.discovery=1")) c.discovery = true;
        if (std.mem.startsWith(u8, tok, "nodeforge.discovery_session=")) c.discovery_session = try allocator.dupe(u8, tok["nodeforge.discovery_session=".len..]);
        if (std.mem.startsWith(u8, tok, "nodeforge.discovery_url=")) c.discovery_url = try allocator.dupe(u8, tok["nodeforge.discovery_url=".len..]);
    }
    return c;
}

/// 释放 `readCmdline` dupe 的各参数字符串。
fn freeCmdline(allocator: std.mem.Allocator, c: Cmdline) void {
    if (c.config_url) |s| allocator.free(s);
    if (c.node) |s| allocator.free(s);
    if (c.session) |s| allocator.free(s);
    if (c.kernel_args) |s| allocator.free(s);
    if (c.mac) |s| allocator.free(s);
    if (c.ip) |s| allocator.free(s);
    if (c.prefix) |s| allocator.free(s);
    if (c.gateway) |s| allocator.free(s);
    if (c.discovery_session) |s| allocator.free(s);
    if (c.discovery_url) |s| allocator.free(s);
}

/// 运行子进程并返回 stdout；退出码非 0 即失败。
fn captureRun(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) {
            log("[nodeforge-initrd] command failed while capturing output: {s} exit={d} stderr={s}\n", .{ argv[0], code, result.stderr });
            return error.SubprocessFailed;
        },
        else => {
            log("[nodeforge-initrd] command terminated abnormally while capturing output: {s}\n", .{argv[0]});
            return error.SubprocessFailed;
        },
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
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch |err| {
        log("[nodeforge-initrd] WARNING: optional command could not execute: {s}: {t}\n", .{ argv[0], err });
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0)
            log("[nodeforge-initrd] WARNING: optional command failed: {s} exit={d} stderr={s}\n", .{ argv[0], code, result.stderr }),
        else => log("[nodeforge-initrd] WARNING: optional command terminated abnormally: {s}\n", .{argv[0]}),
    }
}

test "vendor coldplug delegates NIC selection to udev modalias" {
    try std.testing.expect(std.mem.containsAtLeast(u8, hardware_coldplug_script, 1, "udevadm trigger --type=subsystems"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hardware_coldplug_script, 1, "udevadm trigger --type=devices"));
    try std.testing.expect(std.mem.containsAtLeast(u8, hardware_coldplug_script, 1, "udevadm settle --timeout=10"));
    for ([_][]const u8{ "vmxnet3", "virtio_net", "e1000e" }) |driver| {
        try std.testing.expect(!std.mem.containsAtLeast(u8, hardware_coldplug_script, 1, driver));
    }
}
