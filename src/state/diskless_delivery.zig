//! # v0.2 无盘投递会话 + 作用域令牌存储
//!
//! 自包含的 diskless 交付子系统：按 session 持有节点/profile/rootfs 定位器、
//! 固定的 AgentPlan（immutable bytes + digest）以及 config/agent/event 三类
//! scoped token 的 HMAC hash + claim。raw token 只返回给调用方（capsule/响应），
//! 内存只持 [`diskless_credential.hashOf`]。session 持久化到
//! `diskless-delivery.json`，跨 daemon 重启可验证（HMAC secret 也持久化）。
//!
//! 这是 install [`boot_session.Store`] 之外的独立 diskless 通路：install session
//! 与 DHCP 耦合，diskless 用 capsule 交付的 config-token 引导，两者不混用。统一
//! 到单一 boot_session 是后续设计收敛项（见 V0_2_V0_5_DESIGN_REVIEW §5）。
const std = @import("std");
const cred = @import("diskless_credential.zig");
const lifecycle = @import("diskless_session.zig");
const atomicWrite = @import("dhcp_store.zig").atomicWrite;

pub const id_len = 32;
pub const token_len = 64;
pub const hash_len = 64;
pub const digest_len = 64;
pub const sha512_len = 128;
pub const max_sessions = 64;
pub const name_cap = 128;
pub const kernel_cap = 64;
pub const agent_plan_cap = 16384;
pub const default_ttl_seconds: i64 = 2 * 60 * 60;
pub const persistence_schema_version: u32 = 1;

/// 加载或首次创建 diskless capability master secret。文件保存 32-byte secret
/// 的 64 位小写 hex，权限固定 0600；格式损坏时拒绝启动，绝不静默换密钥使活动
/// session 全部变成不可恢复状态。
pub fn loadOrCreateSecret(io: std.Io, allocator: std.mem.Allocator, path: []const u8, secret: *[32]u8) !void {
    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(65)) catch |err| switch (err) {
        error.FileNotFound => {
            try io.randomSecure(secret);
            var encoded: [64]u8 = undefined;
            _ = std.fmt.bufPrint(&encoded, "{x}", .{secret.*}) catch unreachable;
            try atomicWrite(io, path, &encoded);
            try chmod(allocator, io, "600", path);
            return;
        },
        else => return err,
    };
    defer allocator.free(existing);
    const value = std.mem.trim(u8, existing, " \t\r\n");
    if (value.len != 64) return error.InvalidDisklessSecret;
    _ = std.fmt.hexToBytes(secret, value) catch return error.InvalidDisklessSecret;
    try chmod(allocator, io, "600", path);
}

pub const TokenSlot = struct {
    issued: bool = false,
    hash: [hash_len]u8 = [_]u8{0} ** hash_len,
    scope: cred.Scope = .config_read,
    content_digest: [sha512_len]u8 = [_]u8{0} ** sha512_len,
    content_len: u8 = 0,
    expires_mono: i64 = 0,
    event_seq: u64 = 0,
};

pub const Session = struct {
    active: bool = false,
    session_id: [id_len]u8 = [_]u8{0} ** id_len,
    node_buf: [name_cap]u8 = [_]u8{0} ** name_cap,
    node_len: u8 = 0,
    profile_buf: [name_cap]u8 = [_]u8{0} ** name_cap,
    profile_len: u8 = 0,
    rootfs_input_digest: [digest_len]u8 = [_]u8{0} ** digest_len,
    rootfs_sha512: [sha512_len]u8 = [_]u8{0} ** sha512_len,
    /// squashfs 传输字节数。
    rootfs_size: u64 = 0,
    /// squashfs 展开后的逻辑字节数，用于启动期内存峰值校验；0 表示未知。
    /// 未知值必须原样跨 checkpoint 保存，禁止回退成 rootfs_size。
    rootfs_uncompressed_size: u64 = 0,
    tmpfs_percent: u8 = 50,
    minimum_free_bytes: u64 = 0,
    safety_margin_bytes: u64 = 0,
    kernel_buf: [kernel_cap]u8 = [_]u8{0} ** kernel_cap,
    kernel_len: u8 = 0,
    agent_plan_buf: [agent_plan_cap]u8 = [_]u8{0} ** agent_plan_cap,
    agent_plan_len: u32 = 0,
    agent_plan_digest: [digest_len]u8 = [_]u8{0} ** digest_len,
    armed_at: i64 = 0,
    /// 节点首次进入 initrd 阶段的 UTC 时间；供 node list 的 INSTALL 列投影。
    install_at: i64 = 0,
    /// 进入 running/failed/expired 终态的 UTC 时间；0 表示尚未结束。
    finished_at: i64 = 0,
    expires_at: i64 = 0,
    phase: lifecycle.Phase = .boot_tftp_complete,
    config_token: TokenSlot = .{},
    rootfs_token: TokenSlot = .{ .scope = .rootfs_read },
    agent_token: TokenSlot = .{ .scope = .agent_read },
    event_token: TokenSlot = .{ .scope = .event_append },
    /// raw token 只驻内存（不落盘）；boot-config 响应重放时返回相同 bytes。
    config_token_raw: [token_len]u8 = [_]u8{0} ** token_len,
    rootfs_token_raw: [token_len]u8 = [_]u8{0} ** token_len,
    agent_token_raw: [token_len]u8 = [_]u8{0} ** token_len,
    event_token_raw: [token_len]u8 = [_]u8{0} ** token_len,

    pub fn nodeId(self: *const Session) []const u8 {
        return self.node_buf[0..self.node_len];
    }
    pub fn profileName(self: *const Session) []const u8 {
        return self.profile_buf[0..self.profile_len];
    }
    pub fn kernelRelease(self: *const Session) []const u8 {
        return self.kernel_buf[0..self.kernel_len];
    }
    pub fn rootfsInputDigest(self: *const Session) []const u8 {
        return &self.rootfs_input_digest;
    }
    pub fn rootfsSha512(self: *const Session) []const u8 {
        return &self.rootfs_sha512;
    }
    pub fn agentPlanDigest(self: *const Session) []const u8 {
        return &self.agent_plan_digest;
    }
    pub fn agentPlanJson(self: *const Session) []const u8 {
        return self.agent_plan_buf[0..self.agent_plan_len];
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    secret: []const u8,
    sessions: [max_sessions]Session = [_]Session{.{}} ** max_sessions,
    path: []const u8,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, secret: []const u8, path: []const u8) Store {
        return .{ .allocator = allocator, .secret = secret, .path = path };
    }

    pub fn deinit(self: *Store) void {
        _ = self;
    }

    /// 从 checkpoint 恢复尚未过期的 delivery session。raw capability 不在 JSON
    /// 中；它由持久 master secret + session/scope 确定性重建，并再次核对保存的
    /// HMAC hash，避免损坏 checkpoint 静默扩大权限。
    pub fn load(self: *Store, io: std.Io, now_mono: i64, now_utc: i64) !usize {
        if (self.path.len == 0) return 0;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, self.allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(PersistedFile, self.allocator, bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value.schema_version != persistence_schema_version) return error.InvalidDisklessDeliveryStore;
        self.revision = parsed.value.revision;
        if (parsed.value.sessions.len > max_sessions) return error.InvalidDisklessDeliveryStore;
        var restored: usize = 0;
        for (parsed.value.sessions) |item| {
            // capability TTL 到期只淘汰未完成的 delivery。running/failed/expired
            // 是节点长期运行事实，必须跨 daemon 重启保留给 node list 投影。
            if (item.expires_at <= now_utc and !item.phase.isTerminal()) continue;
            const slot_index = self.findFree() orelse return error.DisklessSessionCapacity;
            var session = try restoreSession(item, now_mono, now_utc);
            try reconstructAndVerifyRaw(self.secret, &session, .config);
            try reconstructAndVerifyRaw(self.secret, &session, .rootfs);
            try reconstructAndVerifyRaw(self.secret, &session, .agent);
            try reconstructAndVerifyRaw(self.secret, &session, .event);
            self.sessions[slot_index] = session;
            restored += 1;
        }
        return restored;
    }

    /// 原子 checkpoint。只序列化 active session 的 immutable snapshot、claim 和
    /// token HMAC；raw token 永不落盘。
    pub fn persist(self: *Store, io: std.Io) !void {
        if (self.path.len == 0) return;
        const previous_revision = self.revision;
        self.revision = std.math.add(u64, self.revision, 1) catch return error.DisklessRevisionOverflow;
        errdefer self.revision = previous_revision;
        var compact: [max_sessions]PersistedSession = undefined;
        var count: usize = 0;
        for (&self.sessions) |*session| {
            if (!session.active) continue;
            compact[count] = persistedSession(session);
            count += 1;
        }
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, PersistedFile{
            .revision = self.revision,
            .sessions = compact[0..count],
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);
        try atomicWrite(io, self.path, bytes);
        try chmod(self.allocator, io, "600", self.path);
    }

    pub fn currentRevision(self: *const Store) u64 {
        return self.revision;
    }

    /// 创建一个 diskless session（不签发 token）。返回新 session 的只读引用；
    /// config/agent/event token 由 prepare/boot-config 分别签发。
    pub fn begin(self: *Store, io: std.Io, node_id: []const u8, profile: []const u8, rootfs_input_digest: []const u8, rootfs_sha512: []const u8, rootfs_size: u64, rootfs_uncompressed_size: u64, kernel_release: []const u8, tmpfs_percent: u8, minimum_free_bytes: u64, safety_margin_bytes: u64, now_mono: i64, now_utc: i64) !*Session {
        // 同节点新 delivery 原位取代旧终态快照；每个节点最多保留一条长期事实。
        // 保存原值，checkpoint 失败时完整回滚。
        var replacement: ?usize = null;
        for (&self.sessions, 0..) |*existing, index| {
            if (existing.active and existing.phase.isTerminal() and std.mem.eql(u8, existing.nodeId(), node_id)) {
                replacement = index;
                break;
            }
        }
        const slot = replacement orelse self.findFree() orelse return error.DisklessSessionCapacity;
        const previous_session = self.sessions[slot];
        var s: Session = .{ .active = true, .armed_at = now_utc, .expires_at = now_utc + default_ttl_seconds };
        try generateId(io, &s.session_id);
        s.node_len = @intCast(@min(node_id.len, name_cap));
        @memcpy(s.node_buf[0..s.node_len], node_id[0..s.node_len]);
        s.profile_len = @intCast(@min(profile.len, name_cap));
        @memcpy(s.profile_buf[0..s.profile_len], profile[0..s.profile_len]);
        const rid_len = @min(rootfs_input_digest.len, digest_len);
        @memcpy(s.rootfs_input_digest[0..rid_len], rootfs_input_digest[0..rid_len]);
        const sh_len = @min(rootfs_sha512.len, sha512_len);
        @memcpy(s.rootfs_sha512[0..sh_len], rootfs_sha512[0..sh_len]);
        s.rootfs_size = rootfs_size;
        s.rootfs_uncompressed_size = rootfs_uncompressed_size;
        s.tmpfs_percent = tmpfs_percent;
        s.minimum_free_bytes = minimum_free_bytes;
        s.safety_margin_bytes = safety_margin_bytes;
        s.kernel_len = @intCast(@min(kernel_release.len, kernel_cap));
        @memcpy(s.kernel_buf[0..s.kernel_len], kernel_release[0..s.kernel_len]);
        // config token 随会话过期；将内容绑定到 rootfs sha512。
        s.config_token = .{ .issued = false, .scope = .config_read, .expires_mono = now_mono + default_ttl_seconds };
        const cd_len = @min(sh_len, sha512_len);
        @memcpy(s.config_token.content_digest[0..cd_len], rootfs_sha512[0..cd_len]);
        s.config_token.content_len = @intCast(cd_len);
        s.rootfs_token = .{ .issued = false, .scope = .rootfs_read, .expires_mono = now_mono + default_ttl_seconds };
        @memcpy(s.rootfs_token.content_digest[0..cd_len], rootfs_sha512[0..cd_len]);
        s.rootfs_token.content_len = @intCast(cd_len);
        s.agent_token = .{ .issued = false, .scope = .agent_read, .expires_mono = now_mono + default_ttl_seconds };
        s.event_token = .{ .issued = false, .scope = .event_append, .expires_mono = now_mono + default_ttl_seconds };
        self.sessions[slot] = s;
        self.persist(io) catch {
            self.sessions[slot] = previous_session;
            return error.DisklessSessionPersistFailed;
        };
        return &self.sessions[slot];
    }

    /// 固定 immutable AgentPlan JSON（boot-config 首次签发时写入），并计算其
    /// canonical SHA-256 作为 agent_plan_digest。后续 agent-plan GET 返回相同 bytes。
    pub fn pinAgentPlan(self: *Store, io: std.Io, session_id: []const u8, json: []const u8) !void {
        const s = self.find(session_id) orelse return error.DisklessSessionNotFound;
        if (json.len > agent_plan_cap) return error.AgentPlanTooLarge;
        @memcpy(s.agent_plan_buf[0..json.len], json);
        s.agent_plan_len = @intCast(json.len);
        var raw: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(json, &raw, .{});
        _ = std.fmt.bufPrint(&s.agent_plan_digest, "{x}", .{raw}) catch unreachable;
        try self.persist(io);
    }

    /// 签发一个 scoped token（32 字节随机 -> 64 hex）。持久 HMAC hash + claim，
    /// raw token 只驻内存（`*_token_raw`），供 capsule 交付 / boot-config 响应重放。
    pub fn issue(self: *Store, io: std.Io, session_id: []const u8, slot_kind: SlotKind) !void {
        const s = self.find(session_id) orelse return error.DisklessSessionNotFound;
        const slot = self.slotOf(s, slot_kind);
        const previous_slot = slot.*;
        const previous_raw = switch (slot_kind) {
            .config => s.config_token_raw,
            .rootfs => s.rootfs_token_raw,
            .agent => s.agent_token_raw,
            .event => s.event_token_raw,
        };
        var raw: [token_len]u8 = undefined;
        deriveToken(self.secret, &s.session_id, slot_kind, &raw);
        slot.hash = cred.hashOf(&raw, self.secret);
        slot.issued = true;
        switch (slot_kind) {
            .config => @memcpy(&s.config_token_raw, &raw),
            .rootfs => @memcpy(&s.rootfs_token_raw, &raw),
            .agent => @memcpy(&s.agent_token_raw, &raw),
            .event => @memcpy(&s.event_token_raw, &raw),
        }
        if (slot_kind == .agent) {
            const cd_len = @min(s.agent_plan_digest.len, digest_len);
            @memcpy(slot.content_digest[0..cd_len], s.agent_plan_digest[0..cd_len]);
            slot.content_len = @intCast(cd_len);
        }
        self.persist(io) catch |err| {
            slot.* = previous_slot;
            switch (slot_kind) {
                .config => s.config_token_raw = previous_raw,
                .rootfs => s.rootfs_token_raw = previous_raw,
                .agent => s.agent_token_raw = previous_raw,
                .event => s.event_token_raw = previous_raw,
            }
            return err;
        };
    }

    pub fn rawToken(self: *Store, s: *const Session, kind: SlotKind) []const u8 {
        _ = self;
        return switch (kind) {
            .config => &s.config_token_raw,
            .rootfs => &s.rootfs_token_raw,
            .agent => &s.agent_token_raw,
            .event => &s.event_token_raw,
        };
    }

    pub const SlotKind = enum { config, rootfs, agent, event };

    fn slotOf(self: *Store, s: *Session, kind: SlotKind) *TokenSlot {
        _ = self;
        return switch (kind) {
            .config => &s.config_token,
            .rootfs => &s.rootfs_token,
            .agent => &s.agent_token,
            .event => &s.event_token,
        };
    }

    /// 校验 raw token：定位 session（按 session_id），取对应 slot 的 hash + claim，
    /// 委托 [`diskless_credential.verify`]。返回校验结果。
    pub fn verify(self: *Store, session_id: []const u8, raw_token: []const u8, kind: SlotKind, request_node: []const u8, request_path: []const u8, request_content: []const u8, request_event_seq: u64, now_mono: i64) cred.Decision {
        const s = self.find(session_id) orelse return .invalid_token;
        const slot = self.slotOf(s, kind);
        if (!slot.issued) return .invalid_token;
        const claim: cred.Claim = .{
            .scope = slot.scope,
            .node_id = s.nodeId(),
            .session_id = &s.session_id,
            .plan_digest = s.rootfsInputDigest(),
            .content_digest = self.contentDigestOf(slot),
            .expires_mono = slot.expires_mono,
            // 允许仅上一次 seq 进入 reducer，以便 reducer 对“相同 seq + 相同
            // phase”作幂等确认；任何不同 payload 仍由 advanceEvent 拒绝。
            .event_seq = if (kind == .event and request_event_seq != std.math.maxInt(u64) and request_event_seq + 1 == slot.event_seq)
                request_event_seq
            else
                slot.event_seq,
        };
        return cred.verify(raw_token, self.secret, &slot.hash, &claim, slot.scope, request_node, request_path, request_content, request_event_seq, now_mono);
    }

    fn contentDigestOf(self: *Store, slot: *const TokenSlot) []const u8 {
        _ = self;
        return slot.content_digest[0..slot.content_len];
    }

    pub fn find(self: *Store, session_id: []const u8) ?*Session {
        for (&self.sessions) |*s| if (s.active and std.mem.eql(u8, &s.session_id, session_id)) return s;
        return null;
    }

    pub fn findByNode(self: *Store, node_id: []const u8) ?*Session {
        var latest: ?*Session = null;
        for (&self.sessions) |*s| {
            if (!s.active or !std.mem.eql(u8, s.nodeId(), node_id)) continue;
            // 历史 checkpoint 可能保留同节点的终态会话；列表和强制终止均选择
            // armed_at 最新的一次，不能由固定数组槽位顺序决定运行态。
            if (latest == null or s.armed_at > latest.?.armed_at) latest = s;
        }
        return latest;
    }

    pub fn snapshot(self: *Store, out: *[max_sessions]Session) []const Session {
        var count: usize = 0;
        for (self.sessions) |session| {
            if (!session.active) continue;
            out[count] = session;
            count += 1;
        }
        return out[0..count];
    }

    /// Operator cancellation invalidates every capability and removes the
    /// session from the durable active set in one checkpoint. If persistence
    /// fails, restore the complete prior session so cancellation is never
    /// reported while usable credentials remain durable.
    pub fn cancel(self: *Store, io: std.Io, session_id: []const u8) !void {
        const session = self.find(session_id) orelse return error.DisklessSessionNotFound;
        const previous = session.*;
        session.* = .{};
        self.persist(io) catch |err| {
            session.* = previous;
            return err;
        };
    }

    pub fn markBootConfigFetched(self: *Store, io: std.Io, session_id: []const u8) !void {
        const session = self.find(session_id) orelse return error.DisklessSessionNotFound;
        const previous = session.phase;
        session.phase = try lifecycle.advance(session.phase, .boot_config_fetched);
        self.persist(io) catch |err| {
            session.phase = previous;
            return err;
        };
    }

    /// 校验 canonical lifecycle 的单步推进与 event_seq，并在同一 checkpoint
    /// 中提交新 phase/next sequence。重复/跳步/回退均由 reducer fail closed。
    pub const EventAdvanceResult = enum { applied, idempotent };

    pub fn advanceEvent(self: *Store, io: std.Io, session_id: []const u8, expected: lifecycle.Phase, target: lifecycle.Phase, event_seq: u64, now_utc: i64) !EventAdvanceResult {
        const session = self.find(session_id) orelse return error.DisklessSessionNotFound;
        if (event_seq != std.math.maxInt(u64) and event_seq + 1 == session.event_token.event_seq and target == session.phase)
            return .idempotent;
        if (event_seq != session.event_token.event_seq) return error.DisklessEventSequenceMismatch;
        if (expected != session.phase) return error.DisklessExpectedPhaseMismatch;
        const previous_phase = session.phase;
        const previous_seq = session.event_token.event_seq;
        const previous_install_at = session.install_at;
        const previous_finished_at = session.finished_at;
        session.phase = try lifecycle.advance(session.phase, target);
        session.event_token.event_seq = std.math.add(u64, previous_seq, 1) catch return error.DisklessEventSequenceOverflow;
        // INSTALL 对无盘节点表示真正开始执行 initrd，而不是服务端 prepare。
        if (target == .diskless_initrd_started and session.install_at == 0) session.install_at = now_utc;
        if (target.isTerminal() and session.finished_at == 0) session.finished_at = now_utc;
        self.persist(io) catch |err| {
            session.phase = previous_phase;
            session.event_token.event_seq = previous_seq;
            session.install_at = previous_install_at;
            session.finished_at = previous_finished_at;
            return err;
        };
        return .applied;
    }

    pub fn revoke(self: *Store, io: std.Io, session_id: []const u8, kind: SlotKind) !void {
        const session = self.find(session_id) orelse return error.DisklessSessionNotFound;
        const slot = self.slotOf(session, kind);
        const previous_slot = slot.*;
        const previous_raw = switch (kind) {
            .config => session.config_token_raw,
            .rootfs => session.rootfs_token_raw,
            .agent => session.agent_token_raw,
            .event => session.event_token_raw,
        };
        slot.issued = false;
        @memset(&slot.hash, 0);
        switch (kind) {
            .config => @memset(&session.config_token_raw, 0),
            .rootfs => @memset(&session.rootfs_token_raw, 0),
            .agent => @memset(&session.agent_token_raw, 0),
            .event => @memset(&session.event_token_raw, 0),
        }
        self.persist(io) catch |err| {
            slot.* = previous_slot;
            switch (kind) {
                .config => session.config_token_raw = previous_raw,
                .rootfs => session.rootfs_token_raw = previous_raw,
                .agent => session.agent_token_raw = previous_raw,
                .event => session.event_token_raw = previous_raw,
            }
            return err;
        };
    }

    fn findFree(self: *Store) ?usize {
        for (&self.sessions, 0..) |*s, i| if (!s.active) return i;
        return null;
    }
};

const PersistedSlot = struct {
    issued: bool,
    hash: []const u8,
    scope: cred.Scope,
    content_digest: []const u8,
    event_seq: u64,
};

const PersistedSession = struct {
    session_id: []const u8,
    node_id: []const u8,
    profile: []const u8,
    rootfs_input_digest: []const u8,
    rootfs_sha512: []const u8,
    rootfs_size: u64,
    /// schema v1 旧记录缺少该字段；恢复时临时回退 rootfs_size。
    rootfs_uncompressed_size: u64 = 0,
    tmpfs_percent: u8,
    minimum_free_bytes: u64,
    safety_margin_bytes: u64,
    kernel_release: []const u8,
    agent_plan_json: []const u8,
    agent_plan_digest: []const u8,
    armed_at: i64,
    /// schema v1 旧记录没有生命周期时间，缺省为 0 可向后兼容恢复。
    install_at: i64 = 0,
    finished_at: i64 = 0,
    expires_at: i64,
    phase: lifecycle.Phase,
    config_token: PersistedSlot,
    rootfs_token: PersistedSlot,
    agent_token: PersistedSlot,
    event_token: PersistedSlot,
};

const PersistedFile = struct {
    schema_version: u32 = persistence_schema_version,
    revision: u64 = 0,
    sessions: []const PersistedSession = &.{},
};

/// 将内存中的 token slot 投影为可持久化形式（只存 hash+claim，不含 raw token）。
fn persistedSlot(slot: *const TokenSlot) PersistedSlot {
    return .{
        .issued = slot.issued,
        .hash = &slot.hash,
        .scope = slot.scope,
        .content_digest = slot.content_digest[0..slot.content_len],
        .event_seq = slot.event_seq,
    };
}

/// 将内存中的 session 投影为可持久化形式：四类 capability 只存 hash+claim，
/// raw token 从不落盘。
fn persistedSession(session: *const Session) PersistedSession {
    return .{
        .session_id = &session.session_id,
        .node_id = session.nodeId(),
        .profile = session.profileName(),
        .rootfs_input_digest = session.rootfsInputDigest(),
        .rootfs_sha512 = session.rootfsSha512(),
        .rootfs_size = session.rootfs_size,
        .rootfs_uncompressed_size = session.rootfs_uncompressed_size,
        .tmpfs_percent = session.tmpfs_percent,
        .minimum_free_bytes = session.minimum_free_bytes,
        .safety_margin_bytes = session.safety_margin_bytes,
        .kernel_release = session.kernelRelease(),
        .agent_plan_json = session.agentPlanJson(),
        .agent_plan_digest = session.agentPlanDigest(),
        .armed_at = session.armed_at,
        .install_at = session.install_at,
        .finished_at = session.finished_at,
        .expires_at = session.expires_at,
        .phase = session.phase,
        .config_token = persistedSlot(&session.config_token),
        .rootfs_token = persistedSlot(&session.rootfs_token),
        .agent_token = persistedSlot(&session.agent_token),
        .event_token = persistedSlot(&session.event_token),
    };
}

/// 从持久化 JSON 恢复单个 session：逐字段校验长度，任一越界即 fail-closed
/// （`InvalidDisklessDeliveryStore`）。按剩余 TTL（`expires_at - now_utc`）重算
/// monotonic 过期时间。raw token 不在持久化文件中，由 `reconstructAndVerifyRaw`
/// 在校验时按需重构。
fn restoreSession(item: PersistedSession, now_mono: i64, now_utc: i64) !Session {
    if (item.session_id.len != id_len or item.rootfs_input_digest.len != digest_len or
        item.rootfs_sha512.len != sha512_len or item.agent_plan_digest.len != digest_len or
        item.node_id.len > name_cap or item.profile.len > name_cap or
        item.kernel_release.len > kernel_cap or item.agent_plan_json.len > agent_plan_cap)
        return error.InvalidDisklessDeliveryStore;
    var session: Session = .{
        .active = true,
        .rootfs_size = item.rootfs_size,
        // 旧 checkpoint 缺少该字段时保持 unknown(0)，不能拿压缩大小冒充展开大小。
        .rootfs_uncompressed_size = item.rootfs_uncompressed_size,
        .tmpfs_percent = item.tmpfs_percent,
        .minimum_free_bytes = item.minimum_free_bytes,
        .safety_margin_bytes = item.safety_margin_bytes,
        .armed_at = item.armed_at,
        .install_at = item.install_at,
        .finished_at = item.finished_at,
        .expires_at = item.expires_at,
        .phase = item.phase,
    };
    @memcpy(&session.session_id, item.session_id);
    session.node_len = @intCast(item.node_id.len);
    @memcpy(session.node_buf[0..session.node_len], item.node_id);
    session.profile_len = @intCast(item.profile.len);
    @memcpy(session.profile_buf[0..session.profile_len], item.profile);
    @memcpy(&session.rootfs_input_digest, item.rootfs_input_digest);
    @memcpy(&session.rootfs_sha512, item.rootfs_sha512);
    session.kernel_len = @intCast(item.kernel_release.len);
    @memcpy(session.kernel_buf[0..session.kernel_len], item.kernel_release);
    session.agent_plan_len = @intCast(item.agent_plan_json.len);
    @memcpy(session.agent_plan_buf[0..session.agent_plan_len], item.agent_plan_json);
    @memcpy(&session.agent_plan_digest, item.agent_plan_digest);
    const remaining = item.expires_at - now_utc;
    session.config_token = try restoreSlot(item.config_token, now_mono + remaining);
    session.rootfs_token = try restoreSlot(item.rootfs_token, now_mono + remaining);
    session.agent_token = try restoreSlot(item.agent_token, now_mono + remaining);
    session.event_token = try restoreSlot(item.event_token, now_mono + remaining);
    return session;
}

/// 从持久化 hash+claim 恢复 token slot（不含 raw token）；过期时间由调用方按 TTL 重算。
fn restoreSlot(item: PersistedSlot, expires_mono: i64) !TokenSlot {
    if (item.hash.len != hash_len or item.content_digest.len > sha512_len) return error.InvalidDisklessDeliveryStore;
    var slot: TokenSlot = .{
        .issued = item.issued,
        .scope = item.scope,
        .content_len = @intCast(item.content_digest.len),
        .expires_mono = expires_mono,
        .event_seq = item.event_seq,
    };
    @memcpy(&slot.hash, item.hash);
    @memcpy(slot.content_digest[0..item.content_digest.len], item.content_digest);
    return slot;
}

/// 从 master secret + session_id + capability kind 确定性派生 raw token
/// （HMAC-SHA256 -> 64 位 hex）。确定性是 session 跨 daemon 重启可恢复的关键：
/// 重启后用同一 secret+session_id+kind 重构出与签发时完全相同的 raw token。
/// raw token 本身从不持久化，内存只存 `cred.hashOf(raw, secret)`。
fn deriveToken(secret: []const u8, session_id: []const u8, kind: Store.SlotKind, destination: *[token_len]u8) void {
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    hmac.update("nodeforge-diskless-capability-v1\x00");
    hmac.update(session_id);
    hmac.update(switch (kind) {
        .config => "\x00config",
        .rootfs => "\x00rootfs",
        .agent => "\x00agent",
        .event => "\x00event",
    });
    var mac: [32]u8 = undefined;
    hmac.final(&mac);
    _ = std.fmt.bufPrint(destination, "{x}", .{mac}) catch unreachable;
}

/// 重启恢复：用 `deriveToken` 重构 raw token，再与持久化 hash 比对验证。
/// 这是 session 跨 daemon 重启可恢复的依据；hash 不匹配即 fail-closed
/// （防持久化文件被篡改或换密钥后误判为有效）。对应设计 §9.1：capsule 交付
/// 前/中重启且客户端无完整 token 时，必须 `recovery_incomplete`，不能重建 secret。
fn reconstructAndVerifyRaw(secret: []const u8, session: *Session, kind: Store.SlotKind) !void {
    const slot = switch (kind) {
        .config => &session.config_token,
        .rootfs => &session.rootfs_token,
        .agent => &session.agent_token,
        .event => &session.event_token,
    };
    if (!slot.issued) return;
    const raw = switch (kind) {
        .config => &session.config_token_raw,
        .rootfs => &session.rootfs_token_raw,
        .agent => &session.agent_token_raw,
        .event => &session.event_token_raw,
    };
    deriveToken(secret, &session.session_id, kind, raw);
    const computed = cred.hashOf(raw, secret);
    if (!std.mem.eql(u8, &computed, &slot.hash)) return error.InvalidDisklessDeliveryStore;
}

/// 用 `chmod` 子进程设置文件权限；失败即返回错误（secret 文件必须 0600）。
fn chmod(allocator: std.mem.Allocator, io: std.Io, mode: []const u8, path: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "chmod", mode, path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.PermissionUpdateFailed,
        else => return error.PermissionUpdateFailed,
    }
}

/// 生成 32-byte 随机 session_id（安全随机源）。
fn generateId(io: std.Io, destination: *[id_len]u8) !void {
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    for (random, 0..) |byte, index| {
        destination[index * 2] = hex(byte >> 4);
        destination[index * 2 + 1] = hex(byte & 0x0f);
    }
}

fn hex(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + (nibble - 10);
}

test "delivery checkpoint restores session and reconstructs raw capabilities" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{path});
    defer std.testing.allocator.free(checkpoint);
    const secret = [_]u8{0x5a} ** 32;

    var before = Store.init(std.testing.allocator, &secret, checkpoint);
    const session = try before.begin(
        std.testing.io,
        "node-1",
        "profile-1",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        4096,
        16384,
        "5.14.0",
        50,
        64,
        32,
        100,
        1000,
    );
    const session_id = session.session_id;
    try before.pinAgentPlan(std.testing.io, &session_id, "{\"schema_version\":1}");
    try before.issue(std.testing.io, &session_id, .config);
    try before.issue(std.testing.io, &session_id, .rootfs);
    try before.issue(std.testing.io, &session_id, .agent);
    try before.issue(std.testing.io, &session_id, .event);
    const config_raw = session.config_token_raw;
    const rootfs_raw = session.rootfs_token_raw;
    const agent_raw = session.agent_token_raw;
    const event_raw = session.event_token_raw;

    const persisted = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, checkpoint, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(persisted);
    try std.testing.expect(std.mem.indexOf(u8, persisted, &config_raw) == null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, &rootfs_raw) == null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, &agent_raw) == null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, &event_raw) == null);

    var after = Store.init(std.testing.allocator, &secret, checkpoint);
    try std.testing.expectEqual(@as(usize, 1), try after.load(std.testing.io, 10, 1010));
    const restored = after.find(&session_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u64, 4096), restored.rootfs_size);
    try std.testing.expectEqual(@as(u64, 16384), restored.rootfs_uncompressed_size);
    try std.testing.expectEqualSlices(u8, &config_raw, &restored.config_token_raw);
    try std.testing.expectEqualSlices(u8, &rootfs_raw, &restored.rootfs_token_raw);
    try std.testing.expectEqualSlices(u8, &agent_raw, &restored.agent_token_raw);
    try std.testing.expectEqualSlices(u8, &event_raw, &restored.event_token_raw);
    try std.testing.expectEqual(cred.Decision.ok, after.verify(
        &session_id,
        &restored.config_token_raw,
        .config,
        "node-1",
        "",
        restored.rootfsSha512(),
        0,
        11,
    ));
}

test "diskless event CAS is ordered and exact retry is idempotent" {
    const secret = [_]u8{0x33} ** 32;
    var store = Store.init(std.testing.allocator, &secret, "");
    const session = try store.begin(
        std.testing.io,
        "n1",
        "p1",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        1,
        4,
        "k",
        50,
        64,
        32,
        0,
        0,
    );
    const id = session.session_id;
    try store.markBootConfigFetched(std.testing.io, &id);
    try store.issue(std.testing.io, &id, .event);
    try std.testing.expectEqual(Store.EventAdvanceResult.applied, try store.advanceEvent(
        std.testing.io,
        &id,
        .boot_config_fetched,
        .diskless_initrd_started,
        0,
        100,
    ));
    try std.testing.expectEqual(Store.EventAdvanceResult.idempotent, try store.advanceEvent(
        std.testing.io,
        &id,
        .boot_config_fetched,
        .diskless_initrd_started,
        0,
        101,
    ));
    try std.testing.expectEqual(@as(i64, 100), store.find(&id).?.install_at);
    try std.testing.expectError(error.DisklessEventSequenceMismatch, store.advanceEvent(
        std.testing.io,
        &id,
        .diskless_initrd_started,
        .diskless_rootfs_downloading,
        4,
        102,
    ));
    try std.testing.expectError(error.JumpRejected, store.advanceEvent(
        std.testing.io,
        &id,
        .diskless_initrd_started,
        .diskless_rootfs_verified,
        1,
        102,
    ));
}

test "missing rootfs uncompressed size remains unknown" {
    const secret = [_]u8{0x44} ** 32;
    var store = Store.init(std.testing.allocator, &secret, "");
    const session = try store.begin(
        std.testing.io,
        "n-unknown",
        "p-unknown",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        4096,
        0,
        "k",
        50,
        64,
        32,
        0,
        0,
    );
    try std.testing.expectEqual(@as(u64, 0), session.rootfs_uncompressed_size);
}
