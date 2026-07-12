//! 单次 PXE 启动的进程内关联状态。
//!
//! registry 只保留当前 daemon 实例中的活动 session；终态历史由 Event v2 记录。
//! 因而 daemon 重启绝不会恢复旧的 DHCP/TFTP 关联，也不会把重启前的 IP 或 MAC
//! 误绑定到新的节点启动。

const std = @import("std");
const model = @import("../model.zig");

/// 128-bit 安全随机值的固定小写十六进制编码长度。
pub const id_len = 32;
/// 有界内存注册表容量；耗尽时协议继续服务，但事件明确记录无法安全关联。
pub const max_sessions = 256;
/// 相同 MAC/XID 在 DHCP 早期阶段的重传复用同一 session 的最长时间窗口。
pub const retransmit_window_seconds: i64 = 30;
/// 未继续推进的 bootstrap session 的存活时间。
pub const bootstrap_ttl_seconds: i64 = 15 * 60;
/// A successfully authenticated delivery may continue for two hours.  The
/// capability itself remains process-local and expires with the session.
pub const delivery_ttl_seconds: i64 = 2 * 60 * 60;
pub const capability_len = 64;

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
    node_id: ?[]const u8 = null,
    mac: [6]u8 = [_]u8{0} ** 6,
    lease_ip: u32 = 0,
    dhcp_xid: u32 = 0,
    profile: ?[]const u8 = null,
    mode: ?model.ProfileMode = null,
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
};

/// The sole node-side authorization result consumed by M3 handlers.  It is a
/// value copy so no request keeps the session mutex while rendering or I/O.
pub const Authenticated = struct {
    node_id: []const u8,
    boot_session_id: [id_len]u8,
    profile: []const u8,
    mode: model.ProfileMode,
    lease_ip: u32,
    capability: [capability_len]u8,
    capability_issued: bool,
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
    mutex: std.atomic.Mutex = .unlocked,

    /// Creates a session for a new MAC/XID pair or refreshes only a bounded
    /// DHCP retransmission. A different XID supersedes the old active session.
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
            same_mac_index = index;
            break;
        }

        var retired: ?Session = null;
        if (same_mac_index) |index| {
            const reason: TerminalReason = if (self.sessions[index].dhcp_xid == identity.xid) .expired else .superseded;
            retired = terminateLocked(&self.sessions[index], reason, mono_now, utc_now);
            self.sessions[index] = .{};
        }

        for (&self.sessions) |*session| if (!session.active()) {
            session.* = try newSession(io, identity, mono_now, utc_now, self.sessions[0..]);
            return .{ .link = .{ .linked = session.id }, .created = true, .retired = retired };
        };
        return .{ .link = .capacity_exhausted, .retired = retired };
    }

    /// Advances the session already associated with a DHCP packet. A degraded
    /// capacity result intentionally has no mutable session.
    pub fn updateDhcp(self: *Store, link: Link, phase: Phase, lease_ip: u32, mono_now: i64, utc_now: i64) void {
        const id = link.id() orelse return;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), id)) continue;
            session.phase = phase;
            if (lease_ip != 0) session.lease_ip = lease_ip;
            session.last_seen_mono = mono_now;
            session.last_seen_at = utc_now;
            return;
        }
    }

    /// Removes the lease-IP association without ending the diagnostic session.
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

    /// Associates a TFTP RRQ only when one active lease-IP match exists.
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

    pub fn updateTftp(self: *Store, link: Link, phase: Phase, mono_now: i64, utc_now: i64) void {
        self.updateDhcp(link, phase, 0, mono_now, utc_now);
    }

    /// Verifies the bootstrap proof using only the direct TCP peer and the
    /// active DHCP lease.  The caller's node id is never trusted by itself.
    pub fn authenticateBootstrap(self: *Store, node_id: []const u8, peer_ip: u32, mono_now: i64) !Authenticated {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or sessionExpired(session, mono_now)) continue;
            if (session.node_id == null or session.profile == null or session.mode == null) continue;
            if (!std.mem.eql(u8, session.node_id.?, node_id)) continue;
            if (session.lease_ip != peer_ip) return error.ProofMismatch;
            return authenticated(session);
        }
        return error.SessionInactive;
    }

    /// Verifies the bearer capability and explicit correlation header.  A
    /// session id alone is intentionally never a proof.
    pub fn authenticateCapability(self: *Store, node_id: []const u8, session_id: []const u8, token: []const u8, mono_now: i64) !Authenticated {
        if (!validId(session_id) or token.len != capability_len) return error.ProofMismatch;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), session_id)) continue;
            if (sessionExpired(session, mono_now)) return error.SessionInactive;
            if (session.node_id == null or session.profile == null or session.mode == null) return error.ProofMismatch;
            if (!std.mem.eql(u8, session.node_id.?, node_id) or !session.capability_issued or !std.mem.eql(u8, &session.capability, token)) return error.ProofMismatch;
            return authenticated(session);
        }
        return error.SessionInactive;
    }

    /// Capability-only proof for a catalog-scoped URL such as `/rootfs/:name`.
    /// The route has no node id segment, so the resolved session supplies the
    /// identity and the caller must perform the profile/asset binding.
    pub fn authenticateCapabilityAny(self: *Store, session_id: []const u8, token: []const u8, mono_now: i64) !Authenticated {
        if (!validId(session_id) or token.len != capability_len) return error.ProofMismatch;
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.sessions) |*session| {
            if (!session.active() or !std.mem.eql(u8, session.idSlice(), session_id)) continue;
            if (sessionExpired(session, mono_now)) return error.SessionInactive;
            if (session.node_id == null or session.profile == null or session.mode == null or !session.capability_issued or !std.mem.eql(u8, &session.capability, token)) return error.ProofMismatch;
            return authenticated(session);
        }
        return error.SessionInactive;
    }

    /// Generates a 256-bit bearer token only after bootstrap authentication.
    /// It is kept exclusively in the in-memory Session and is never persisted.
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

    /// A valid delivery extends the session's delivery TTL, without altering its
    /// identity or minting a new token.
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

    /// Expires inactive bootstrap attempts and copies their terminal records for
    /// the caller to append through the sole EventWriter.
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

    /// Terminates all active sessions before an orderly daemon stop.
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
};

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
    return .{
        .id = id,
        .node_id = identity.node_id,
        .mac = mac,
        .dhcp_xid = identity.xid,
        .profile = identity.profile,
        .mode = identity.mode,
        .created_at = utc_now,
        .last_seen_at = utc_now,
        .created_mono = mono_now,
        .last_seen_mono = mono_now,
    };
}

fn terminateLocked(session: *Session, reason: TerminalReason, mono_now: i64, utc_now: i64) Session {
    session.terminal_reason = reason;
    session.last_seen_mono = mono_now;
    session.last_seen_at = utc_now;
    if (reason == .expired) session.phase = .expired;
    return session.*;
}

fn authenticated(session: *const Session) Authenticated {
    return .{
        .node_id = session.node_id.?,
        .boot_session_id = session.id,
        .profile = session.profile.?,
        .mode = session.mode.?,
        .lease_ip = session.lease_ip,
        .capability = session.capability,
        .capability_issued = session.capability_issued,
    };
}

fn sessionExpired(session: *const Session, mono_now: i64) bool {
    const ttl = if (session.capability_issued) delivery_ttl_seconds else bootstrap_ttl_seconds;
    return mono_now - session.last_seen_mono >= ttl;
}

fn isDhcpEarly(phase: Phase) bool {
    return switch (phase) {
        .dhcp_discover, .dhcp_offer, .dhcp_ack => true,
        else => false,
    };
}

fn hex(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + value - 10;
}

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

test "capacity exhaustion remains explicit and bootstrap sessions expire" {
    var store: Store = .{};
    for (0..max_sessions) |index| {
        const mac = [_]u8{ @intCast(index & 0xff), @intCast(index >> 8), 0, 0, 0, 1 };
        const result = try store.acquireDhcp(std.testing.io, .{ .mac = &mac, .xid = @intCast(index + 1), .node_id = null, .profile = null, .mode = null }, 1, 1);
        try std.testing.expect(result.link == .linked);
    }
    const overflow = try store.acquireDhcp(std.testing.io, .{ .mac = &.{ 0, 1, 0, 0, 0, 1 }, .xid = 999, .node_id = null, .profile = null, .mode = null }, 1, 1);
    try std.testing.expectEqual(Link.capacity_exhausted, overflow.link);

    var expired: [max_sessions]Session = undefined;
    const count = store.expire(1 + bootstrap_ttl_seconds, 2, &expired);
    try std.testing.expectEqual(@as(usize, max_sessions), count);
    try std.testing.expectEqual(TerminalReason.expired, expired[0].terminal_reason.?);
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
        .node_id = "node-01",
        .lease_ip = 0xc0a81b0a,
        .profile = "rocky-install",
        .mode = .install,
        .last_seen_mono = 100,
        .capability = token,
        .capability_issued = true,
    };
    const bootstrap = try store.authenticateBootstrap("node-01", 0xc0a81b0a, 101);
    try std.testing.expectEqualStrings("node-01", bootstrap.node_id);
    try std.testing.expectError(error.ProofMismatch, store.authenticateBootstrap("node-01", 0xc0a81b0b, 101));
    _ = try store.authenticateCapability("node-01", &session_id, &token, 101);
    try std.testing.expectError(error.ProofMismatch, store.authenticateCapability("node-02", &session_id, &token, 101));
    try std.testing.expectError(error.SessionInactive, store.authenticateCapability("node-01", &session_id, &token, 100 + delivery_ttl_seconds));
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
