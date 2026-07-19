//! 单次 PXE 启动的进程内关联状态。
//!
//! registry 只保留当前 daemon 实例中的活动 session；终态历史由 Event v2 记录。
//! 因而 daemon 重启绝不会恢复旧的 DHCP/TFTP 关联，也不会把重启前的 IP 或 MAC
//! 误绑定到新的节点启动。

const std = @import("std");
const model = @import("../model.zig");
const capacity = @import("capacity.zig");

/// 128-bit 安全随机值的固定小写十六进制编码长度。
pub const id_len = 32;
/// 有界内存注册表容量；耗尽时协议继续服务，但事件明确记录无法安全关联。
/// M4.8: session 注册表内存天花板；生效容量由 `Store.effective` 在启动时按
/// `max(usable_hosts(subnet), config)` 派生（`min(派生, max_sessions)`）。
pub const max_sessions = capacity.store_ceiling;
/// 相同 MAC/XID 在 DHCP 早期阶段的重传复用同一 session 的最长时间窗口。
pub const retransmit_window_seconds: i64 = 30;
/// 未继续推进的 bootstrap session 的存活时间。
pub const bootstrap_ttl_seconds: i64 = 15 * 60;
/// 成功认证后的投递 session 可持续两小时。capability 本身保持进程内存在，
/// 随 session 一起过期。这允许安装器在长时间安装过程中持续上报事件。
pub const delivery_ttl_seconds: i64 = 2 * 60 * 60;
pub const capability_len = 64;
pub const node_id_capacity = 96;
pub const profile_capacity = 128;

pub const InstallPlanSnapshot = struct {
    allocator: std.mem.Allocator,
    json: []u8,
    digest: [32]u8,
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    pub fn retain(self: *InstallPlanSnapshot) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    pub fn release(self: *InstallPlanSnapshot) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.allocator.free(self.json);
        self.allocator.destroy(self);
    }
};

/// `phase` 是观察性投影而非持久化状态机；后续 M3/M4 仅能在已验证的
/// node/session 关联上推进它。
pub const Phase = enum {
    dhcp_discover,
    dhcp_offer,
    dhcp_ack,
    tftp_rrq,
    tftp_complete,
    boot_config_fetched,
    installer_started,
    installing,
    installed,
    provisioning,
    completed,
    initrd_started,
    rootfs_downloading,
    rootfs_verified,
    rootfs_mounted,
    switching_root,
    diskless_running,
    failed,
    expired,
};

/// session 终止时的稳定审计原因，写入 `boot.session.terminated`。
pub const TerminalReason = enum {
    completed,
    failed,
    expired,
    superseded,
    daemon_shutdown,
};

/// 活动启动尝试的最小关联事实。字符串字段借用已验证配置的生命周期，Store
/// 不拥有它们；只有 session id、MAC 和时间戳由 Store 自己维护。
pub const Session = struct {
    id: [id_len]u8 = [_]u8{0} ** id_len,
    node_id_buf: [node_id_capacity]u8 = [_]u8{0} ** node_id_capacity,
    node_id_len: u8 = 0,
    mac: [6]u8 = [_]u8{0} ** 6,
    lease_ip: u32 = 0,
    dhcp_xid: u32 = 0,
    profile_buf: [profile_capacity]u8 = [_]u8{0} ** profile_capacity,
    profile_len: u8 = 0,
    mode: ?model.ProfileMode = null,
    model_revision: u64 = 0,
    model_plan_digest: @import("deployment_control.zig").Digest = @import("deployment_control.zig").empty_digest,
    deployment_generation: u64 = 0,
    install_plan: ?*InstallPlanSnapshot = null,
    created_at: i64 = 0,
    last_seen_at: i64 = 0,
    created_mono: i64 = 0,
    last_seen_mono: i64 = 0,
    phase: Phase = .dhcp_discover,
    terminal_reason: ?TerminalReason = null,
    capability: [capability_len]u8 = [_]u8{0} ** capability_len,
    capability_issued: bool = false,

    pub fn active(self: *const Session) bool {
        return self.id[0] != 0 and self.terminal_reason == null;
    }

    pub fn idSlice(self: *const Session) []const u8 {
        return self.id[0..];
    }

    pub fn nodeId(self: *const Session) ?[]const u8 {
        return if (self.node_id_len == 0) null else self.node_id_buf[0..self.node_id_len];
    }

    pub fn profileName(self: *const Session) ?[]const u8 {
        return if (self.profile_len == 0) null else self.profile_buf[0..self.profile_len];
    }
};

/// 节点侧授权结果的唯一类型，由 M3 handler 消费。它是值拷贝，
/// 因此没有请求会在渲染或 I/O 期间持有 session mutex。
/// 包含 node_id/boot_session_id/profile/mode/lease_ip/capability 等身份字段。
pub const Authenticated = struct {
    node_id: []const u8,
    boot_session_id: [id_len]u8,
    profile: []const u8,
    mode: model.ProfileMode,
    lease_ip: u32,
    capability: [capability_len]u8,
    capability_issued: bool,
    model_revision: u64,
    model_plan_digest: @import("deployment_control.zig").Digest,
    deployment_generation: u64,
    session_created_at: i64,
    plan_digest: ?[32]u8,
};

/// M3.5 只读 TFTP boot 身份。由 `resolveTftpBoot` 返回的安全值拷贝，
/// 使 TFTP handler 能在不持有 session mutex 的情况下渲染虚拟 GRUB 配置。
/// 所有字段都是从活动 session 复制的快照，不会在 I/O 期间被并发修改。
pub const TftpBootIdentity = struct {
    boot_session_id: [id_len]u8,
    node_id: []const u8,
    profile: []const u8,
    mode: model.ProfileMode,
    mac: [6]u8,
    lease_ip: u32,
};

/// 协议事件到 session 的关联结果。
///
/// 只有 `linked` 可以携带 `boot_session_id`。其它值不是失败的猜测，而是必须
/// 保留在事件中的显式降级原因，避免消费者把 IP、文件名或最近事件误作身份。
pub const Link = union(enum) {
    linked: [id_len]u8,
    capacity_exhausted,
    no_active_lease_match,
    ambiguous_lease_match,

    pub fn id(self: *const Link) ?[]const u8 {
        return switch (self.*) {
            .linked => self.linked[0..],
            else => null,
        };
    }

    pub fn state(self: Link) ?[]const u8 {
        return switch (self) {
            .linked => null,
            .capacity_exhausted => "capacity_exhausted",
            .no_active_lease_match => "no_active_lease_match",
            .ambiguous_lease_match => "ambiguous_lease_match",
        };
    }
};

/// DHCP 创建 session 时可从已解析请求和配置安全得到的身份快照。
pub const DhcpIdentity = struct {
    mac: []const u8,
    xid: u32,
    node_id: ?[]const u8,
    profile: ?[]const u8,
    mode: ?model.ProfileMode,
    model_revision: u64 = 0,
    model_plan_digest: @import("deployment_control.zig").Digest = @import("deployment_control.zig").empty_digest,
};

/// `acquireDhcp` 的附带结果；被替换的 session 必须由调用者写出终态事件。
pub const AcquireResult = struct {
    link: Link,
    created: bool = false,
    retired: ?Session = null,
};

/// 受 mutex 保护的固定容量 session 注册表。
///
/// 所有变更先在锁内完成，事件在锁外由调用方通过唯一 Writer 追加，以避免
/// session lock 与文件 I/O 相互阻塞。
pub const Store = struct {
    sessions: [max_sessions]Session = [_]Session{.{}} ** max_sessions,
    /// M4.8: 生效并发 session 上限，启动时按 subnet 派生收敛。
    effective: usize = max_sessions,
    mutex: std.atomic.Mutex = .unlocked,

    /// M4.8: 按 `max(usable_hosts(subnet), config)` 派生并 clamp 到 `[1, max_sessions]`。
    pub fn setEffective(self: *Store, derived: usize) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var active: usize = 0;
        for (self.sessions) |session| if (session.active()) {
            active += 1;
        };
        self.effective = @max(active, @max(@as(usize, 1), @min(derived, max_sessions)));
    }

    pub fn captureInstallPlan(self: *Store, allocator: std.mem.Allocator, session_id: []const u8, json: []const u8, model_revision: u64) !void {
        if (!validId(session_id) or json.len == 0 or json.len > 1024 * 1024) return error.InvalidInstallPlan;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(json, &digest, .{});
        const plan = try allocator.create(InstallPlanSnapshot);
        const owned_json = allocator.dupe(u8, json) catch |err| {
            allocator.destroy(plan);
            return err;
        };
        plan.* = .{ .allocator = allocator, .json = owned_json, .digest = digest };
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), session_id)) continue;
            if (session.install_plan) |existing| {
                if (!std.crypto.timing_safe.eql([32]u8, existing.digest, digest)) {
                    plan.release();
                    return error.InstallPlanChanged;
                }
                plan.release();
                return;
            }
            session.install_plan = plan;
            session.model_revision = model_revision;
            return;
        }
        plan.release();
        return error.SessionInactive;
    }

    pub fn setDeploymentGeneration(self: *Store, session_id: []const u8, generation: u64) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| if (session.active() and std.mem.eql(u8, session.idSlice(), session_id)) {
            if (session.deployment_generation != 0 and session.deployment_generation != generation) return error.DeploymentGenerationChanged;
            session.deployment_generation = generation;
            return;
        };
        return error.SessionInactive;
    }

    pub fn copyInstallPlan(self: *Store, allocator: std.mem.Allocator, session_id: []const u8) !?[]u8 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), session_id)) continue;
            const plan = session.install_plan orelse return null;
            return try allocator.dupe(u8, plan.json);
        }
        return null;
    }

    pub fn hasActiveNode(self: *Store, node_id: []const u8, mono_now: i64) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| if (session.active() and !sessionExpired(session, mono_now) and session.nodeId() != null and std.mem.eql(u8, session.nodeId().?, node_id)) return true;
        return false;
    }

    /// 操作员确认目标机已停止后，强制 retry 可终止无法回报 terminal event
    /// 的坏 installer session（例如 kickstart 在 capability 下发后解析失败）。
    pub fn supersedeNode(self: *Store, node_id: []const u8, mono_now: i64, utc_now: i64) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var changed = false;
        for (&self.sessions) |*session| {
            if (!session.active() or session.nodeId() == null or !std.mem.eql(u8, session.nodeId().?, node_id)) continue;
            _ = terminateLocked(session, .superseded, mono_now, utc_now);
            session.* = .{};
            changed = true;
        }
        return changed;
    }

    pub fn hasActiveInstallSource(self: *Store, source: []const u8, mono_now: i64) bool {
        var needle_buffer: [256]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buffer, "\"name\":\"{s}\"", .{source}) catch return true;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or sessionExpired(session, mono_now)) continue;
            const plan = session.install_plan orelse continue;
            // The owned canonical plan contains several names. Pair the exact
            // name with the install_source object prefix to avoid matching an
            // unrelated asset suffix.
            const marker = "\"install_source\":";
            const start = std.mem.indexOf(u8, plan.json, marker) orelse continue;
            const tail = plan.json[start + marker.len ..];
            if (std.mem.indexOf(u8, tail[0..@min(tail.len, 2048)], needle) != null) return true;
        }
        return false;
    }

    /// 在关联确定时复制节点 ID，供传输期间固定使用；调用方不得在 I/O 后重查归属。
    pub fn copyLinkedNodeId(self: *Store, link: Link, buffer: []u8) ?[]const u8 {
        const session_id = link.id() orelse return null;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            const owned_node_id = session.nodeId() orelse continue;
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), session_id)) continue;
            if (owned_node_id.len > buffer.len) return null;
            @memcpy(buffer[0..owned_node_id.len], owned_node_id);
            return buffer[0..owned_node_id.len];
        }
        return null;
    }

    /// 为新的 MAC/XID 对创建 session，或仅在有界 DHCP 重传窗口内刷新同一 session。
    /// 不同 XID 会取代旧的活动 session（标记为 superseded）。
    ///
    /// 关联策略：
    /// - 相同 MAC + 相同 XID 且处于 DHCP 早期阶段（discover/offer/ack）且在
    ///   重传窗口内：刷新时间戳，复用同一 session，返回 `linked`。
    /// - 相同 MAC 但不同 XID：终止旧 session（superseded），创建新 session。
    /// - 相同 MAC + 相同 XID 但已超出重传窗口或已进入 TFTP 阶段：终止旧 session
    ///   （expired），创建新 session。
    /// - 注册表已满：返回 `capacity_exhausted`，不创建新 session。
    pub fn acquireDhcp(self: *Store, io: std.Io, identity: DhcpIdentity, mono_now: i64, utc_now: i64) !AcquireResult {
        if (identity.mac.len != 6) return .{ .link = .capacity_exhausted };
        lock(&self.mutex);
        defer self.mutex.unlock();

        var same_mac_index: ?usize = null;
        for (&self.sessions, 0..) |*session, index| {
            if (!session.active() or !std.mem.eql(u8, &session.mac, identity.mac)) continue;
            if (session.dhcp_xid == identity.xid and isDhcpEarly(session.phase) and mono_now - session.last_seen_mono <= retransmit_window_seconds) {
                session.last_seen_mono = mono_now;
                session.last_seen_at = utc_now;
                return .{ .link = .{ .linked = session.id } };
            }
            // 安装器 initrd 通常在 GRUB 下载 kernel/initrd 后发起全新的
            // DHCP 事务。这仍是同一物理客户端（相同 MAC）和同一次启动尝试，
            // 因此替换这个已 ACK/TFTP 绑定的 session 会使 bootstrap proof
            // 在 `inst.ks`/NoCloud 获取前失效。保留 session 身份并记录
            // 最新的 DHCP XID。
            if (!isDhcpEarly(session.phase) and session.lease_ip != 0 and mono_now - session.last_seen_mono <= bootstrap_ttl_seconds) {
                session.dhcp_xid = identity.xid;
                session.last_seen_mono = mono_now;
                session.last_seen_at = utc_now;
                return .{ .link = .{ .linked = session.id } };
            }
            same_mac_index = index;
            break;
        }

        var retired: ?Session = null;
        if (same_mac_index) |index| {
            const reason: TerminalReason = if (self.sessions[index].dhcp_xid == identity.xid) .expired else .superseded;
            retired = terminateLocked(&self.sessions[index], reason, mono_now, utc_now);
            self.sessions[index] = .{};
        }

        var active: usize = 0;
        var free: ?*Session = null;
        for (&self.sessions) |*session| {
            if (session.active()) active += 1 else if (free == null) free = session;
        }
        if (active >= self.effective) return .{ .link = .capacity_exhausted, .retired = retired };
        if (free) |session| {
            session.* = try newSession(io, identity, mono_now, utc_now, self.sessions[0..]);
            return .{ .link = .{ .linked = session.id }, .created = true, .retired = retired };
        }
        return .{ .link = .capacity_exhausted, .retired = retired };
    }

    /// 推进已与 DHCP 包关联的 session 阶段。降级的容量结果有意不提供可变 session。
    ///
    /// 根据 `link` 中的 session id 查找活动 session，更新其 phase、lease_ip
    /// 和时间戳。如果 link 不是 `linked`（如 `capacity_exhausted`），则直接返回，
    /// 不执行任何变更——降级结果不应有可变 session。
    pub fn updateDhcp(self: *Store, link: Link, phase: Phase, lease_ip: u32, mono_now: i64, utc_now: i64) void {
        const id = link.id() orelse return;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), id)) continue;
            // M4：不要将 phase 从 post-TFTP 状态降级回 DHCP 早期状态。
            // 当安装器 initrd 在 GRUB 加载 kernel/initrd 后执行自己的 DHCP
            // 时，DHCP 服务器会以 .dhcp_ack 调用 updateDhcp，这会将 phase
            // 从 tftp_complete 重置为 dhcp_ack（早期）。这会导致下一次 DHCP
            // 续约终止 session（superseded）而非保留它，在 inst.ks / NoCloud
            // 获取前使 bootstrap proof 失效。
            if (!isDhcpEarly(phase) or isDhcpEarly(session.phase)) {
                session.phase = phase;
            }
            if (lease_ip != 0) session.lease_ip = lease_ip;
            session.last_seen_mono = mono_now;
            session.last_seen_at = utc_now;
            return;
        }
    }

    /// 移除 lease-IP 关联但不终止诊断 session。用于 DHCP DECLINE 或 NAK 场景。
    ///
    /// 当客户端发送 DHCP DECLINE 或收到 NAK 时，IP 地址不再有效，但 session
    /// 仍保留用于诊断。此函数清除 lease_ip 字段，保持 session 活动，
    /// 以便后续 TFTP 或 HTTP 请求仍可关联到该 MAC。
    pub fn clearLease(self: *Store, mac: []const u8, xid: u32, mono_now: i64, utc_now: i64) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or session.dhcp_xid != xid or !std.mem.eql(u8, &session.mac, mac)) continue;
            session.lease_ip = 0;
            session.last_seen_mono = mono_now;
            session.last_seen_at = utc_now;
            return;
        }
    }

    /// 仅当存在唯一的活动 lease-IP 匹配时关联 TFTP RRQ。
    /// 零个或多个匹配均返回降级 Link，绝不能按文件名、TID 或最近 DHCP 日志猜测关联。
    ///
    /// 这是 TFTP 虚拟配置安全模型的基础：只有经过 DHCP ACK 的客户端才能
    /// 获取 GRUB 配置。ambiguous（多个 session 匹配同一 IP）或
    /// no_active_lease_match（无匹配）都返回降级结果，TFTP handler 不会
    /// 为这些情况渲染任何配置。
    pub fn associateTftp(self: *Store, client_ip: u32, mono_now: i64, utc_now: i64) Link {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var found: ?*Session = null;
        for (&self.sessions) |*session| {
            if (!session.active() or session.lease_ip != client_ip) continue;
            if (found != null) return .ambiguous_lease_match;
            found = session;
        }
        const session = found orelse return .no_active_lease_match;
        session.phase = .tftp_rrq;
        session.last_seen_mono = mono_now;
        session.last_seen_at = utc_now;
        return .{ .linked = session.id };
    }

    /// M3.5/M3.6：为已 ACK 的客户端解析只读 TFTP boot 身份。
    ///
    /// 返回 null 的条件（任一满足）：
    /// - 没有活动 session 匹配该 lease IP
    /// - 多个活动 session 匹配该 lease IP（ambiguous）
    /// - session 缺少 node_id/profile/mode（未注册节点的诊断 lease）
    /// - session 已过期（bootstrap TTL 或 delivery TTL 超时）
    ///
    /// 调用方收到值拷贝，在 I/O 期间不持有 mutex。
    /// 这使 TFTP 虚拟配置渲染能在不阻塞 DHCP session 管理的情况下进行。
    pub fn resolveTftpBoot(self: *Store, client_ip: u32, mono_now: i64) ?TftpBootIdentity {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var found: ?*Session = null;
        for (&self.sessions) |*session| {
            if (!session.active() or session.lease_ip != client_ip) continue;
            if (found != null) return null; // 多个 session 匹配同一 lease IP，ambiguous
            found = session;
        }
        const session = found orelse return null;
        if (sessionExpired(session, mono_now)) return null;
        if (session.nodeId() == null or session.profileName() == null or session.mode == null) return null;
        return .{
            .boot_session_id = session.id,
            .node_id = session.nodeId().?,
            .profile = session.profileName().?,
            .mode = session.mode.?,
            .mac = session.mac,
            .lease_ip = session.lease_ip,
        };
    }

    /// 推进已关联的 TFTP session 阶段。委托给 `updateDhcp`，但不更新 lease_ip
    ///（传 0 表示不变更）。用于 TFTP 传输完成等阶段推进。
    pub fn updateTftp(self: *Store, link: Link, phase: Phase, mono_now: i64, utc_now: i64) void {
        self.updateDhcp(link, phase, 0, mono_now, utc_now);
    }

    /// 仅使用 direct TCP peer 和活动 DHCP lease 验证 bootstrap proof。
    /// 调用方的 node id 本身永远不被单独信任，必须与 session 中的 lease IP 匹配。
    ///
    /// 验证逻辑：
    /// 1. 查找活动且未过期的 session，其 node_id 与参数匹配。
    /// 2. 检查 session.lease_ip 是否等于 peer_ip（direct TCP 连接的对端 IP）。
    /// 3. 匹配成功返回 `Authenticated` 值拷贝；lease_ip 不匹配返回 `ProofMismatch`。
    /// 4. 无匹配 session 返回 `SessionInactive`。
    ///
    /// 这是 HTTP bootstrap 端点的第一道认证：只有从 DHCP 分配的 IP 发起的
    /// 连接才能获取安装配置和 capability token。
    pub fn authenticateBootstrap(self: *Store, node_id: []const u8, peer_ip: u32, mono_now: i64) !Authenticated {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var node_match = false;
        var lease_match = false;
        for (&self.sessions) |*session| {
            if (!session.active() or sessionExpired(session, mono_now)) continue;
            if (session.nodeId() == null or session.profileName() == null or session.mode == null) continue;
            if (!std.mem.eql(u8, session.nodeId().?, node_id)) continue;
            node_match = true;
            if (session.lease_ip == peer_ip) lease_match = true;
            if (session.lease_ip != peer_ip) return error.ProofMismatch;
            return authenticated(session);
        }
        // 有意返回稳定的诊断分类，使 HTTP 层可以记录安全原因
        // 而不暴露 session 标识符或令牌。
        if (node_match and !lease_match) return error.ProofMismatch;
        return error.SessionInactive;
    }

    /// 验证 bearer capability 和显式关联 header。session id 本身有意永远不是 proof，
    /// 必须同时提供正确的 capability token。
    ///
    /// 验证逻辑：
    /// 1. session_id 长度必须是 32 字符的十六进制，token 长度必须是 64 字符。
    /// 2. 查找活动 session，其 id 与参数匹配。
    /// 3. session 必须已过期检查通过，且 node_id、profile、mode 均非 null。
    /// 4. node_id 必须匹配，capability_issued 必须为 true，token 必须完全匹配。
    /// 5. 任一条件不满足返回 `ProofMismatch`；无匹配 session 返回 `SessionInactive`。
    ///
    /// 这用于安装器上报进度的 HTTP 端点：安装器在 bootstrap 认证后获得
    /// capability token，后续请求必须携带 session_id + token 才能继续操作。
    pub fn authenticateCapability(self: *Store, node_id: []const u8, session_id: []const u8, token: []const u8, mono_now: i64) !Authenticated {
        if (!validId(session_id) or token.len != capability_len) return error.ProofMismatch;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), session_id)) continue;
            if (sessionExpired(session, mono_now)) return error.SessionInactive;
            if (session.nodeId() == null or session.profileName() == null or session.mode == null) return error.ProofMismatch;
            if (!std.mem.eql(u8, session.nodeId().?, node_id) or !session.capability_issued or !tokenMatches(session, token)) return error.ProofMismatch;
            return authenticated(session);
        }
        return error.SessionInactive;
    }

    /// 用于 catalog 范围 URL（如 `/rootfs/:name`）的仅 capability proof。
    /// 该路由没有 node id 段，因此由解析出的 session 提供身份，
    /// 调用方必须执行 profile/asset 绑定检查。
    ///
    /// 与 `authenticateCapability` 的区别：此方法不验证 node_id 参数，
    /// 因为 URL 路径中没有 node id 段。但它仍要求 session 有完整的身份信息
    ///（node_id/profile/mode 非 null），且 capability token 必须匹配。
    /// 调用方负责检查请求的 asset 是否属于该 session profile 允许的范围。
    pub fn authenticateCapabilityAny(self: *Store, session_id: []const u8, token: []const u8, mono_now: i64) !Authenticated {
        if (!validId(session_id) or token.len != capability_len) return error.ProofMismatch;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), session_id)) continue;
            if (sessionExpired(session, mono_now)) return error.SessionInactive;
            if (session.nodeId() == null or session.profileName() == null or session.mode == null or !session.capability_issued or !tokenMatches(session, token)) return error.ProofMismatch;
            return authenticated(session);
        }
        return error.SessionInactive;
    }

    /// 仅在 bootstrap 认证后生成 256-bit bearer token。
    /// token 只保存在内存 Session 中，永远不会持久化到磁盘。
    ///
    /// 如果 session 已有 capability（capability_issued=true），直接返回现有值；
    /// 否则从安全随机源生成 256-bit token，写入 session.capability，
    /// 标记 capability_issued=true，并推进 phase 到 boot_config_fetched。
    /// daemon 重启后所有 capability 失效，客户端必须重新完成 bootstrap 认证。
    pub fn issueCapability(self: *Store, io: std.Io, session_id: []const u8, mono_now: i64, utc_now: i64) !Authenticated {
        if (!validId(session_id)) return error.SessionInactive;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), session_id) or sessionExpired(session, mono_now)) continue;
            if (!session.capability_issued) {
                try generateCapability(io, &session.capability);
                session.capability_issued = true;
            }
            session.phase = .boot_config_fetched;
            session.last_seen_mono = mono_now;
            session.last_seen_at = utc_now;
            return authenticated(session);
        }
        return error.SessionInactive;
    }

    /// 有效的投递会延长 session 的 delivery TTL，但不改变其身份或生成新 token。
    ///
    /// 每次安装器成功下载一个文件（如 kernel、initrd、rootfs）后调用此方法，
    /// 更新 last_seen_mono/last_seen_at，使 session 在长时间安装过程中不会过期。
    /// 这不会改变 session 的任何身份字段或 capability。
    pub fn touchDelivery(self: *Store, session_id: []const u8, mono_now: i64, utc_now: i64) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (session.active() and std.mem.eql(u8, session.idSlice(), session_id)) {
                session.last_seen_mono = mono_now;
                session.last_seen_at = utc_now;
                return;
            }
        }
    }

    /// 推进已认证的安装器/无盘 session 超越 DHCP/TFTP 阶段。
    /// 此操作有意与 node-status 分离：它防止新的 DHCP 事务
    // 覆盖已携带 capability 的安装器回调。
    pub fn advanceDelivery(self: *Store, session_id: []const u8, phase: Phase, mono_now: i64, utc_now: i64) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), session_id)) continue;
            session.phase = phase;
            session.last_seen_mono = mono_now;
            session.last_seen_at = utc_now;
            return;
        }
    }

    /// Terminal installer events must release the in-memory capability
    /// immediately: otherwise a failed attempt blocks `install retry` for the
    /// two-hour delivery TTL. Terminal history remains in the durable event
    /// and node-status stores.
    pub fn finishDelivery(self: *Store, session_id: []const u8, reason: TerminalReason, mono_now: i64, utc_now: i64) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), session_id)) continue;
            _ = terminateLocked(session, reason, mono_now, utc_now);
            return;
        }
    }

    /// 过期清理不活跃的 bootstrap session，并拷贝终态记录供调用方通过唯一
    /// EventWriter 追加审计事件。
    ///
    /// 遍历所有活动 session，将超过 TTL 的标记为 expired 并拷贝到 destination。
    /// 调用方负责将 destination 中的记录写入事件日志。过期不影响已获得
    /// capability 的 session（它们使用更长的 delivery TTL），只影响
    /// 未完成 bootstrap 的 session。
    pub fn expire(self: *Store, mono_now: i64, utc_now: i64, destination: *[max_sessions]Session) usize {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var count: usize = 0;
        for (&self.sessions) |*session| {
            if (!session.active() or !sessionExpired(session, mono_now)) continue;
            destination[count] = terminateLocked(session, .expired, mono_now, utc_now);
            count += 1;
            session.* = .{};
        }
        return count;
    }

    /// 在 daemon 有序停止前终止所有活动 session，拷贝终态记录供事件日志使用。
    pub fn terminateAll(self: *Store, mono_now: i64, utc_now: i64, destination: *[max_sessions]Session) usize {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var count: usize = 0;
        for (&self.sessions) |*session| {
            if (!session.active()) continue;
            destination[count] = terminateLocked(session, .daemon_shutdown, mono_now, utc_now);
            count += 1;
            session.* = .{};
        }
        return count;
    }

    /// 释放 Store 持有的所有 install plan 快照。用于测试清理和显式销毁；
    /// daemon 正常停机应优先用 terminateAll 把终态写入事件日志后再清空。
    pub fn deinit(self: *Store) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (session.install_plan) |plan| {
                plan.release();
                session.install_plan = null;
            }
        }
    }

    pub fn snapshot(self: *Store, destination: *[max_sessions]Session) usize {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.sessions) |session| {
            if (!session.active() or !session.capability_issued) continue;
            destination[count] = session;
            if (destination[count].install_plan) |plan| plan.retain();
            count += 1;
        }
        return count;
    }

    pub fn restore(self: *Store, restored: Session) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*slot| if (!slot.active()) {
            slot.* = restored;
            return;
        };
        return error.SessionCapacityExhausted;
    }
};

fn tokenMatches(session: *const Session, token: []const u8) bool {
    if (token.len != capability_len) return false;
    return std.crypto.timing_safe.eql([capability_len]u8, session.capability, token[0..capability_len].*);
}

/// 返回用于 TTL 和重传窗口的单调秒数；绝不用于对外审计时间。
pub fn monotonicNow() i64 {
    var clock: std.posix.timespec = undefined;
    return if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &clock)) == .SUCCESS) @intCast(clock.sec) else 0;
}

/// 从安全随机源生成不可预测的 128-bit session/daemon id。
pub fn generateId(io: std.Io, destination: *[id_len]u8) !void {
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    for (random, 0..) |byte, index| {
        destination[index * 2] = hex(byte >> 4);
        destination[index * 2 + 1] = hex(byte & 0x0f);
    }
}

/// 从安全随机源生成 256-bit（64 字符十六进制）bearer capability token。
/// 与 session id 不同，capability token 用于后续 HTTP 请求的持续认证，
/// 只有 bootstrap 认证通过后才会生成。
pub fn generateCapability(io: std.Io, destination: *[capability_len]u8) !void {
    var random: [32]u8 = undefined;
    try io.randomSecure(&random);
    for (random, 0..) |byte, index| {
        destination[index * 2] = hex(byte >> 4);
        destination[index * 2 + 1] = hex(byte & 0x0f);
    }
}

/// 校验 session id 的固定编码，供 fixture 和边界输入使用。
pub fn validId(value: []const u8) bool {
    if (value.len != id_len) return false;
    for (value) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    return true;
}

/// 创建新 session，生成不与现有活动 session 冲突的 128-bit 随机 id。
/// 从 DhcpIdentity 拷贝 MAC 地址，借用 node_id/profile/mode 的生命周期
///（它们指向已验证的 config 字符串，Store 不拥有这些字符串）。
fn newSession(io: std.Io, identity: DhcpIdentity, mono_now: i64, utc_now: i64, existing: []const Session) !Session {
    var id: [id_len]u8 = undefined;
    while (true) {
        try generateId(io, &id);
        var collision = false;
        for (existing) |session| {
            if (session.active() and std.mem.eql(u8, &session.id, &id)) {
                collision = true;
                break;
            }
        }
        if (!collision) break;
    }
    var mac: [6]u8 = undefined;
    @memcpy(&mac, identity.mac[0..6]);
    var session: Session = .{
        .id = id,
        .mac = mac,
        .dhcp_xid = identity.xid,
        .mode = identity.mode,
        .model_revision = identity.model_revision,
        .model_plan_digest = identity.model_plan_digest,
        .created_at = utc_now,
        .last_seen_at = utc_now,
        .created_mono = mono_now,
        .last_seen_mono = mono_now,
    };
    try copyIdentity(&session, identity.node_id, identity.profile);
    return session;
}

pub fn copyIdentity(session: *Session, node_id: ?[]const u8, profile: ?[]const u8) !void {
    if (node_id) |value| {
        if (value.len == 0 or value.len > node_id_capacity) return error.InvalidSessionIdentity;
        @memcpy(session.node_id_buf[0..value.len], value);
        session.node_id_len = @intCast(value.len);
    }
    if (profile) |value| {
        if (value.len == 0 or value.len > profile_capacity) return error.InvalidSessionIdentity;
        @memcpy(session.profile_buf[0..value.len], value);
        session.profile_len = @intCast(value.len);
    }
}

/// 在 mutex 已锁定的情况下标记 session 终态并返回终态快照。
/// 不清理 session 槽位（调用方负责置零），只设置 terminal_reason 和时间戳。
fn terminateLocked(session: *Session, reason: TerminalReason, mono_now: i64, utc_now: i64) Session {
    session.terminal_reason = reason;
    session.last_seen_mono = mono_now;
    session.last_seen_at = utc_now;
    if (reason == .expired) session.phase = .expired;
    var result = session.*;
    if (session.install_plan) |plan| plan.release();
    session.install_plan = null;
    result.install_plan = null;
    return result;
}

/// 从已验证的活动 session 构造 Authenticated 值拷贝。
/// 调用方获得的是快照，在 I/O 期间不持有 mutex。
fn authenticated(session: *const Session) Authenticated {
    return .{
        .node_id = session.nodeId().?,
        .boot_session_id = session.id,
        .profile = session.profileName().?,
        .mode = session.mode.?,
        .lease_ip = session.lease_ip,
        .capability = session.capability,
        .capability_issued = session.capability_issued,
        .model_revision = session.model_revision,
        .model_plan_digest = session.model_plan_digest,
        .deployment_generation = session.deployment_generation,
        .session_created_at = session.created_at,
        .plan_digest = if (session.install_plan) |plan| plan.digest else null,
    };
}

/// 判断 session 是否已过期。已获得 capability 的 session 使用 delivery TTL（2 小时），
/// 未获得 capability 的使用 bootstrap TTL（15 分钟）。
fn sessionExpired(session: *const Session, mono_now: i64) bool {
    const ttl = if (session.capability_issued) delivery_ttl_seconds else bootstrap_ttl_seconds;
    return mono_now - session.last_seen_mono >= ttl;
}

/// 判断 phase 是否属于 DHCP 早期阶段（discover/offer/ack）。
/// 只有早期阶段的重传才能复用同一 session。
fn isDhcpEarly(phase: Phase) bool {
    return switch (phase) {
        .dhcp_discover, .dhcp_offer, .dhcp_ack => true,
        else => false,
    };
}

/// 将 4-bit 值映射为小写十六进制字符（0-9, a-f）。
fn hex(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

/// 自旋等待获取 mutex，通过 Thread.yield 让出 CPU 而非忙等。
/// session 操作时间极短，自旋比系统 futex 更高效。
fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

test "DHCP retransmits reuse an early MAC and XID session" {
    var store: Store = .{};
    const identity: DhcpIdentity = .{ .mac = &.{ 1, 2, 3, 4, 5, 6 }, .xid = 7, .node_id = "node-a", .profile = "discovery", .mode = .discovery };
    const first = try store.acquireDhcp(std.testing.io, identity, 10, 100);
    const retry = try store.acquireDhcp(std.testing.io, identity, 20, 110);
    try std.testing.expect(first.link == .linked);
    try std.testing.expect(retry.link == .linked);
    try std.testing.expect(std.mem.eql(u8, first.link.id().?, retry.link.id().?));
    try std.testing.expect(!retry.created);
}

test "a new DHCP XID supersedes the previous session" {
    var store: Store = .{};
    const first = try store.acquireDhcp(std.testing.io, .{ .mac = &.{ 1, 2, 3, 4, 5, 6 }, .xid = 7, .node_id = null, .profile = null, .mode = null }, 10, 100);
    const second = try store.acquireDhcp(std.testing.io, .{ .mac = &.{ 1, 2, 3, 4, 5, 6 }, .xid = 8, .node_id = null, .profile = null, .mode = null }, 11, 101);
    try std.testing.expect(second.retired != null);
    try std.testing.expectEqual(TerminalReason.superseded, second.retired.?.terminal_reason.?);
    try std.testing.expect(!std.mem.eql(u8, first.link.id().?, second.link.id().?));
}

test "TFTP links only a unique active lease address" {
    var store: Store = .{};
    const first = try store.acquireDhcp(std.testing.io, .{ .mac = &.{ 1, 2, 3, 4, 5, 6 }, .xid = 1, .node_id = null, .profile = null, .mode = null }, 1, 1);
    const second = try store.acquireDhcp(std.testing.io, .{ .mac = &.{ 7, 8, 9, 10, 11, 12 }, .xid = 2, .node_id = null, .profile = null, .mode = null }, 1, 1);
    store.updateDhcp(first.link, .dhcp_ack, 0xc0a83264, 2, 2);
    const linked = store.associateTftp(0xc0a83264, 3, 3);
    try std.testing.expectEqualStrings(first.link.id().?, linked.id().?);
    store.updateDhcp(second.link, .dhcp_ack, 0xc0a83264, 3, 3);
    try std.testing.expectEqual(Link.ambiguous_lease_match, store.associateTftp(0xc0a83264, 4, 4));
    try std.testing.expectEqual(Link.no_active_lease_match, store.associateTftp(0xc0a83265, 4, 4));
}

test "resolveTftpBoot returns identity for a unique ACK'd session" {
    var store: Store = .{};
    const acquired = try store.acquireDhcp(std.testing.io, .{
        .mac = &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xef },
        .xid = 0x12345678,
        .node_id = "m3-node",
        .profile = "rocky-install",
        .mode = .install,
    }, 10, 10);
    store.updateDhcp(acquired.link, .dhcp_ack, 0xc0a81bc8, 11, 11);
    const identity = store.resolveTftpBoot(0xc0a81bc8, 12).?;
    try std.testing.expectEqualStrings("m3-node", identity.node_id);
    try std.testing.expectEqualStrings("rocky-install", identity.profile);
    try std.testing.expectEqual(model.ProfileMode.install, identity.mode);
    try std.testing.expectEqual(@as(u32, 0xc0a81bc8), identity.lease_ip);
}

test "resolveTftpBoot returns null for ambiguous lease" {
    var store: Store = .{};
    const first = try store.acquireDhcp(std.testing.io, .{ .mac = &.{ 1, 2, 3, 4, 5, 6 }, .xid = 1, .node_id = "a", .profile = "p", .mode = .install }, 1, 1);
    const second = try store.acquireDhcp(std.testing.io, .{ .mac = &.{ 7, 8, 9, 10, 11, 12 }, .xid = 2, .node_id = "b", .profile = "p", .mode = .install }, 1, 1);
    store.updateDhcp(first.link, .dhcp_ack, 0xc0a83264, 2, 2);
    store.updateDhcp(second.link, .dhcp_ack, 0xc0a83264, 3, 3);
    try std.testing.expect(store.resolveTftpBoot(0xc0a83264, 4) == null);
}

test "resolveTftpBoot returns null for session without node_id" {
    var store: Store = .{};
    const acquired = try store.acquireDhcp(std.testing.io, .{
        .mac = &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xf0 },
        .xid = 0x99999999,
        .node_id = null,
        .profile = null,
        .mode = null,
    }, 10, 10);
    store.updateDhcp(acquired.link, .dhcp_ack, 0xc0a81bc9, 11, 11);
    try std.testing.expect(store.resolveTftpBoot(0xc0a81bc9, 12) == null);
}

test "installer DHCP renewal preserves bootstrap proof after TFTP" {
    var store: Store = .{};
    const mac = &.{ 0x00, 0x0c, 0x29, 0x38, 0xb9, 0x1f };
    const first = try store.acquireDhcp(std.testing.io, .{ .mac = mac, .xid = 1, .node_id = "node-01", .profile = "rocky", .mode = .install }, 10, 10);
    store.updateDhcp(first.link, .dhcp_ack, 0xc0a81bd2, 11, 11);
    store.updateTftp(first.link, .tftp_complete, 12, 12);
    const renewal = try store.acquireDhcp(std.testing.io, .{ .mac = mac, .xid = 2, .node_id = "node-01", .profile = "rocky", .mode = .install }, 20, 20);
    try std.testing.expectEqualStrings(first.link.id().?, renewal.link.id().?);
    store.updateDhcp(renewal.link, .dhcp_ack, 0xc0a81bd2, 21, 21);
    const auth = try store.authenticateBootstrap("node-01", 0xc0a81bd2, 22);
    try std.testing.expectEqualStrings(first.link.id().?, auth.boot_session_id[0..]);
}

test "repeated installer DHCP renewals preserve bootstrap proof" {
    // M4 回归测试：首次安装器 DHCP 续约后，updateDhcp 被调用时传入
    // .dhcp_ack，将 phase 从 tftp_complete 降级为 dhcp_ack（早期阶段）。
    // 随后的 DHCP 续约会终止 session（被 superseded）而非保留它，
    // 导致 inst.ks 获取前 bootstrap proof 失效。
    var store: Store = .{};
    const mac = &.{ 0x00, 0x0c, 0x29, 0x38, 0xb9, 0x1f };
    const first = try store.acquireDhcp(std.testing.io, .{ .mac = mac, .xid = 1, .node_id = "node-01", .profile = "rocky", .mode = .install }, 10, 10);
    store.updateDhcp(first.link, .dhcp_ack, 0xc0a81bd2, 11, 11);
    store.updateTftp(first.link, .tftp_complete, 12, 12);

    // 首次安装器 DHCP 续约（XID 2）
    const second = try store.acquireDhcp(std.testing.io, .{ .mac = mac, .xid = 2, .node_id = "node-01", .profile = "rocky", .mode = .install }, 20, 20);
    try std.testing.expectEqualStrings(first.link.id().?, second.link.id().?);
    store.updateDhcp(second.link, .dhcp_ack, 0xc0a81bd2, 21, 21);

    // 第二次安装器 DHCP 续约（XID 3）—— 此前因 updateDhcp 将 phase
    // 重置为 dhcp_ack（早期阶段）而失败
    const third = try store.acquireDhcp(std.testing.io, .{ .mac = mac, .xid = 3, .node_id = "node-01", .profile = "rocky", .mode = .install }, 30, 30);
    try std.testing.expectEqualStrings(first.link.id().?, third.link.id().?);
    store.updateDhcp(third.link, .dhcp_ack, 0xc0a81bd2, 31, 31);

    // 多次续约后 bootstrap proof 必须仍然有效
    const auth = try store.authenticateBootstrap("node-01", 0xc0a81bd2, 32);
    try std.testing.expectEqualStrings(first.link.id().?, auth.boot_session_id[0..]);
}

test "terminal install event releases retry gate" {
    var store: Store = .{};
    const id = "0123456789abcdef0123456789abcdef";
    store.sessions[0] = .{ .id = id.*, .mode = .install, .last_seen_mono = 1 };
    try copyIdentity(&store.sessions[0], "node-01", "install");
    try std.testing.expect(store.hasActiveNode("node-01", 2));
    store.finishDelivery(id, .failed, 3, 3);
    try std.testing.expect(!store.hasActiveNode("node-01", 4));
}

test "capacity exhaustion remains explicit and bootstrap sessions expire" {
    var store: Store = .{};
    // M4.8: 容量改为运行时派生；用小 effective 验证门控与显式耗尽。
    store.setEffective(4);
    for (0..4) |index| {
        const mac = [_]u8{ @intCast(index & 0xff), @intCast(index >> 8), 0, 0, 0, 1 };
        const result = try store.acquireDhcp(std.testing.io, .{ .mac = &mac, .xid = @intCast(index + 1), .node_id = null, .profile = null, .mode = null }, 1, 1);
        try std.testing.expect(result.link == .linked);
    }
    const overflow = try store.acquireDhcp(std.testing.io, .{ .mac = &.{ 0, 1, 0, 0, 0, 1 }, .xid = 999, .node_id = null, .profile = null, .mode = null }, 1, 1);
    try std.testing.expectEqual(Link.capacity_exhausted, overflow.link);

    var expired: [max_sessions]Session = undefined;
    const count = store.expire(1 + bootstrap_ttl_seconds, 2, &expired);
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(TerminalReason.expired, expired[0].terminal_reason.?);
}

test "effective session capacity counts restored entries outside the prefix" {
    var store: Store = .{};
    const first = try store.acquireDhcp(std.testing.io, .{ .mac = &.{ 1, 2, 3, 4, 5, 6 }, .xid = 1, .node_id = null, .profile = null, .mode = null }, 1, 1);
    try std.testing.expect(first.link == .linked);
    store.sessions[1] = store.sessions[0];
    store.sessions[0] = .{};
    store.setEffective(1);
    const overflow = try store.acquireDhcp(std.testing.io, .{ .mac = &.{ 7, 8, 9, 10, 11, 12 }, .xid = 2, .node_id = null, .profile = null, .mode = null }, 2, 2);
    try std.testing.expectEqual(Link.capacity_exhausted, overflow.link);
    try std.testing.expect(!store.sessions[0].active());
}

test "generated identifiers are lowercase fixed-width hex" {
    var id: [id_len]u8 = undefined;
    try generateId(std.testing.io, &id);
    try std.testing.expect(validId(&id));
}

test "M3 bootstrap and capability proofs remain bound to one active lease" {
    var store: Store = .{};
    const session_id: [id_len]u8 = "0123456789abcdef0123456789abcdef".*;
    const token: [capability_len]u8 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".*;
    store.sessions[0] = .{
        .id = session_id,
        .lease_ip = 0xc0a81b0a,
        .mode = .install,
        .last_seen_mono = 100,
        .capability = token,
        .capability_issued = true,
    };
    try copyIdentity(&store.sessions[0], "node-01", "rocky-install");
    const bootstrap = try store.authenticateBootstrap("node-01", 0xc0a81b0a, 101);
    try std.testing.expectEqualStrings("node-01", bootstrap.node_id);
    try std.testing.expectError(error.ProofMismatch, store.authenticateBootstrap("node-01", 0xc0a81b0b, 101));
    _ = try store.authenticateCapability("node-01", &session_id, &token, 101);
    try std.testing.expectError(error.ProofMismatch, store.authenticateCapability("node-02", &session_id, &token, 101));
    try std.testing.expectError(error.SessionInactive, store.authenticateCapability("node-01", &session_id, &token, 100 + delivery_ttl_seconds));
}

test "M4.3 restored plaintext capability authenticates in constant time" {
    const token = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    var store: Store = .{};
    var id: [id_len]u8 = undefined;
    @memcpy(&id, "0123456789abcdef0123456789abcdef");
    var restored_session: Session = .{
        .id = id,
        .mode = .install,
        .lease_ip = 0xc0a81b10,
        .created_at = 100,
        .last_seen_at = 100,
        .created_mono = 100,
        .last_seen_mono = 100,
        .capability_issued = true,
        .capability = token.*,
    };
    try copyIdentity(&restored_session, "node-01", "install");
    try store.restore(restored_session);
    const checked = try store.authenticateCapability("node-01", &id, token, 101);
    try std.testing.expectEqualStrings("node-01", checked.node_id);
    try std.testing.expectError(error.ProofMismatch, store.authenticateCapability("node-01", &id, "0000000000000000000000000000000000000000000000000000000000000000", 101));
}

test "immutable install plan cannot change within one boot session" {
    var store: Store = .{};
    const acquired = try store.acquireDhcp(std.testing.io, .{ .mac = &.{ 2, 0, 0, 0, 0, 1 }, .xid = 1, .node_id = "node-01", .profile = "install", .mode = .install, .model_revision = 7 }, 1, 1);
    const id = acquired.link.id().?;
    try store.captureInstallPlan(std.testing.allocator, id, "{\"revision\":7}", 7);
    try store.captureInstallPlan(std.testing.allocator, id, "{\"revision\":7}", 7);
    try std.testing.expectError(error.InstallPlanChanged, store.captureInstallPlan(std.testing.allocator, id, "{\"revision\":8}", 8));
    const copied = (try store.copyInstallPlan(std.testing.allocator, id)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("{\"revision\":7}", copied);
    store.finishDelivery(id, .completed, 2, 2);
}

test "DHCP offer phase alone is never an HTTP bootstrap proof" {
    var store: Store = .{};
    const acquired = try store.acquireDhcp(std.testing.io, .{
        .mac = &.{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xef },
        .xid = 0x12345678,
        .node_id = "m3-node",
        .profile = "rocky-install",
        .mode = .install,
    }, 10, 10);
    store.updateDhcp(acquired.link, .dhcp_offer, 0, 11, 11);
    try std.testing.expectError(error.ProofMismatch, store.authenticateBootstrap("m3-node", 0xc0a81bc8, 12));
    store.updateDhcp(acquired.link, .dhcp_ack, 0xc0a81bc8, 13, 13);
    _ = try store.authenticateBootstrap("m3-node", 0xc0a81bc8, 14);
}
