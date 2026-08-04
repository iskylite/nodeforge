//! # v0.4 diskless delivery + lifecycle capability store
//!
//! 自包含的 diskless 交付子系统：按 session 持有节点/profile/rootfs 定位器、
//! 固定的 AgentPlan（immutable bytes + digest）以及跨网络切换使用的单一
//! event token。BootConfig/rootfs/payload 由 boot-session 的 DHCP peer/session
//! binding 认证，AgentPlan 才使用短时 boot-session capability；本 store 不保存
//! 读取 token。event raw token 仅驻进程内存，
//! 可由 master secret 确定性重建。session 持久化到
//! `diskless-delivery.json`，跨 daemon 重启可验证（HMAC secret 也持久化）。
//!
//! 这是与 [`boot_session.Store`] 配对的 diskless delivery/lifecycle 记录：canonical
//! boot session 负责 DHCP peer 与短时 capability，capsule 只交付 delivery session id
//! 和 event credential。管理投影在 node list/show 层统一。
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
/// schema 3 adds mandatory per-slot claim MACs and directly replaces v1/v2;
/// schema 4 fixes the durable model to `event-only-v1`. BootConfig/rootfs/
/// AgentPlan access uses a separate random in-memory BootSession capability;
/// old per-scope token checkpoints are rejected fail-closed.
pub const persistence_schema_version: u32 = 4;

/// 加载或首次创建 daemon 主密钥（daemon_secret）。文件保存 32-byte secret
/// 的 64 位小写 hex，权限固定 0600；格式损坏时拒绝启动，绝不静默换密钥使活动
/// session 全部变成不可恢复状态。v0.4 中它只用于 diskless event 和
/// first-boot 等必须跨网络或 daemon restart 的确定性凭证。
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
    scope: cred.Scope = .event_append,
    content_digest: [sha512_len]u8 = [_]u8{0} ** sha512_len,
    content_len: u8 = 0,
    expires_mono: i64 = 0,
    event_seq: u64 = 0,
    claim_mac: [hash_len]u8 = [_]u8{0} ** hash_len,
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
    event_token: TokenSlot = .{ .scope = .event_append },
    /// raw event token 只驻内存（不落盘）；capsule 重放时返回相同 bytes。
    event_token_raw: [token_len]u8 = [_]u8{0} ** token_len,
    /// 非 persistent 运行时标志。daemon 重启后若唯一 durable event token
    /// 因 master secret 变化或 hash 不匹配而无法安全重构，则设为 true。
    /// 这只关闭 `event:append`；读取链使用 BootSession authority 重新 bootstrap
    /// 的随机内存 capability，不由本 store 恢复。session 按 TTL 回收且不改变
    /// 持久 canonical phase；terminal session 不重构 event token。
    recovery_incomplete: bool = false,

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
    /// deployment_id 参与 durable event token 的域分离派生，使同一 master
    /// secret 在不同 deployment 之间产生不兼容凭证。由 `init` 绑定。
    deployment_id: []const u8,
    sessions: [max_sessions]Session = [_]Session{.{}} ** max_sessions,
    path: []const u8,
    revision: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, secret: []const u8, deployment_id: []const u8, path: []const u8) Store {
        return .{ .allocator = allocator, .secret = secret, .deployment_id = deployment_id, .path = path };
    }

    pub fn deinit(self: *Store) void {
        _ = self;
    }

    /// 从 checkpoint 恢复尚未过期的 delivery session。这里只重构不落盘的 raw
    /// `event:append` token，并核对持久 HMAC hash；随机 boot-session capability
    /// 属于 BootSession store，restart 后必须由同 lease peer 重新 bootstrap。
    pub fn load(self: *Store, io: std.Io, now_mono: i64, now_utc: i64) !usize {
        if (self.path.len == 0) return 0;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, self.allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer self.allocator.free(bytes);
        const header = try std.json.parseFromSlice(PersistedHeader, self.allocator, bytes, .{ .ignore_unknown_fields = true });
        defer header.deinit();
        switch (header.value.schema_version) {
            persistence_schema_version => {
                const parsed = std.json.parseFromSlice(PersistedFile, self.allocator, bytes, .{ .allocate = .alloc_always }) catch
                    return error.InvalidDisklessDeliveryStore;
                defer parsed.deinit();
                if (!std.mem.eql(u8, parsed.value.credential_model, "event-only-v1")) return error.InvalidDisklessDeliveryStore;
                return self.restorePersisted(parsed.value.revision, parsed.value.sessions, now_mono, now_utc);
            },
            else => return error.InvalidDisklessDeliveryStore,
        }
    }

    fn restorePersisted(self: *Store, revision: u64, items: []const PersistedSession, now_mono: i64, now_utc: i64) !usize {
        if (items.len > max_sessions) return error.InvalidDisklessDeliveryStore;
        self.revision = revision;
        var restored: usize = 0;
        for (items) |item| {
            // capability TTL 到期只淘汰未完成的 delivery。running/failed/expired
            // 是节点长期运行事实，必须跨 daemon 重启保留给 node list 投影。
            if (item.expires_at <= now_utc and !item.phase.isTerminal()) continue;
            const slot_index = self.findFree() orelse return error.DisklessSessionCapacity;
            var session = try restoreSession(item, now_mono, now_utc);
            try requireClaimMacs(&session);
            if (session.phase.isTerminal()) {
                // Terminal facts remain visible, but lifecycle authority is gone.
                session.event_token.issued = false;
            } else {
                // 非 terminal 且未过期 session 才执行确定性重构和 hash 验证。
                // 任一重构 token 与合法长度 hash 不匹配时，不恢复任何 scope、
                // 清零已重构 raw bytes 并设 recovery_incomplete；其他 session 继续。
                try reconstructAllOrMarkIncomplete(self, &session);
                // token hash 不匹配维持 recovery_incomplete 语义；只有 token 本身
                // 可重构时，claim MAC 不匹配才证明 checkpoint claim 被篡改。
                if (!session.recovery_incomplete) try verifyClaimMacs(self.secret, &session);
            }
            self.sessions[slot_index] = session;
            restored += 1;
        }
        return restored;
    }

    /// 原子 checkpoint。只序列化 active session 的 immutable snapshot、claim、
    /// token HMAC 与 claim MAC；raw token 永不落盘。
    pub fn persist(self: *Store, io: std.Io) !void {
        if (self.path.len == 0) return;
        const previous_revision = self.revision;
        self.revision = std.math.add(u64, self.revision, 1) catch return error.DisklessRevisionOverflow;
        errdefer self.revision = previous_revision;
        var compact: [max_sessions]PersistedSession = undefined;
        var count: usize = 0;
        for (&self.sessions) |*session| {
            if (!session.active) continue;
            refreshClaimMacs(self.secret, session);
            compact[count] = persistedSession(session);
            count += 1;
        }
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, PersistedFile{
            .credential_model = "event-only-v1",
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
    /// event token 由 prepare 签发；读取认证属于 boot-session store。
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
        const previous_raw = s.event_token_raw;
        var raw: [token_len]u8 = undefined;
        deriveToken(self, &s.session_id, slot_kind, &raw);
        slot.hash = cred.hashOf(&raw, self.secret);
        slot.issued = true;
        @memcpy(&s.event_token_raw, &raw);
        self.persist(io) catch |err| {
            slot.* = previous_slot;
            s.event_token_raw = previous_raw;
            return err;
        };
    }

    pub fn rawToken(self: *Store, s: *const Session, kind: SlotKind) []const u8 {
        _ = self;
        _ = kind;
        return &s.event_token_raw;
    }

    pub const SlotKind = enum { event };

    fn slotOf(self: *Store, s: *Session, kind: SlotKind) *TokenSlot {
        _ = self;
        _ = kind;
        return &s.event_token;
    }

    /// 校验 raw token：定位 session（按 session_id），取对应 slot 的 hash + claim，
    /// 委托 [`diskless_credential.verify`]。返回校验结果。
    pub fn verify(self: *Store, session_id: []const u8, raw_token: []const u8, kind: SlotKind, request_node: []const u8, request_path: []const u8, request_content: []const u8, request_event_seq: u64, now_mono: i64) cred.Decision {
        const s = self.find(session_id) orelse return .invalid_token;
        if (s.recovery_incomplete) return .recovery_incomplete;
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
        const previous_raw = session.event_token_raw;
        slot.issued = false;
        @memset(&slot.hash, 0);
        @memset(&session.event_token_raw, 0);
        self.persist(io) catch |err| {
            slot.* = previous_slot;
            session.event_token_raw = previous_raw;
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
    claim_mac: []const u8 = "",
};

const PersistedSession = struct {
    session_id: []const u8,
    node_id: []const u8,
    profile: []const u8,
    rootfs_input_digest: []const u8,
    rootfs_sha512: []const u8,
    rootfs_size: u64,
    /// schema v1 早期记录可能缺少该字段；缺失时保持 unknown(0)，不能把
    /// 压缩大小冒充展开大小。
    rootfs_uncompressed_size: u64 = 0,
    tmpfs_percent: u8,
    minimum_free_bytes: u64,
    safety_margin_bytes: u64,
    kernel_release: []const u8,
    agent_plan_json: []const u8,
    agent_plan_digest: []const u8,
    armed_at: i64,
    /// 进入 initrd 的生命周期时间；0 表示尚未进入。
    install_at: i64 = 0,
    finished_at: i64 = 0,
    expires_at: i64,
    phase: lifecycle.Phase,
    event_token: PersistedSlot,
};

const PersistedHeader = struct {
    schema_version: u32,
};

const PersistedFile = struct {
    schema_version: u32 = persistence_schema_version,
    credential_model: []const u8,
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
        .claim_mac = &slot.claim_mac,
    };
}

/// 将内存中的 session 投影为可持久化形式：event capability 只存 hash+claim，
/// raw token 从不落盘；读取 token 不属于该 schema。
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
    session.event_token = try restoreSlot(item.event_token, now_mono + remaining);
    return session;
}

/// 从持久化 hash+claim 恢复 token slot（不含 raw token）；过期时间由调用方按 TTL 重算。
fn restoreSlot(item: PersistedSlot, expires_mono: i64) !TokenSlot {
    if (item.hash.len != hash_len or item.content_digest.len > sha512_len or (item.claim_mac.len != 0 and item.claim_mac.len != hash_len)) return error.InvalidDisklessDeliveryStore;
    var slot: TokenSlot = .{
        .issued = item.issued,
        .scope = item.scope,
        .content_len = @intCast(item.content_digest.len),
        .expires_mono = expires_mono,
        .event_seq = item.event_seq,
    };
    @memcpy(&slot.hash, item.hash);
    if (item.claim_mac.len == hash_len) @memcpy(&slot.claim_mac, item.claim_mac);
    @memcpy(slot.content_digest[0..item.content_digest.len], item.content_digest);
    return slot;
}

fn updateClaimMac(hmac: *std.crypto.auth.hmac.sha2.HmacSha256, bytes: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, bytes.len, .big);
    hmac.update(&length);
    hmac.update(bytes);
}

fn claimMac(secret: []const u8, session: *const Session, kind: Store.SlotKind, slot: *const TokenSlot) [hash_len]u8 {
    // claim MAC 使用 daemon master secret；恢复时先处理 token-hash mismatch，
    // 因而 secret 变化仍进入 recovery_incomplete，单独 claim 篡改则 fail closed。
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    hmac.update("nodeforge-diskless-checkpoint-claim-v1\x00");
    updateClaimMac(&hmac, &session.session_id);
    updateClaimMac(&hmac, session.nodeId());
    updateClaimMac(&hmac, session.rootfsInputDigest());
    updateClaimMac(&hmac, session.rootfsSha512());
    updateClaimMac(&hmac, session.agentPlanDigest());
    updateClaimMac(&hmac, @tagName(kind));
    updateClaimMac(&hmac, slot.scope.canonicalName());
    updateClaimMac(&hmac, slot.content_digest[0..slot.content_len]);
    updateClaimMac(&hmac, &slot.hash);
    var scalars: [17]u8 = undefined;
    scalars[0] = @intFromBool(slot.issued);
    std.mem.writeInt(u64, scalars[1..9], slot.event_seq, .big);
    std.mem.writeInt(i64, scalars[9..17], session.expires_at, .big);
    hmac.update(&scalars);
    var mac: [32]u8 = undefined;
    hmac.final(&mac);
    var encoded: [hash_len]u8 = undefined;
    _ = std.fmt.bufPrint(&encoded, "{x}", .{mac}) catch unreachable;
    return encoded;
}

fn refreshClaimMacs(secret: []const u8, session: *Session) void {
    session.event_token.claim_mac = claimMac(secret, session, .event, &session.event_token);
}

fn verifyClaimMacs(secret: []const u8, session: *const Session) !void {
    try verifyClaimMac(secret, session, .event, &session.event_token);
}

fn requireClaimMacs(session: *const Session) !void {
    if (std.mem.allEqual(u8, &session.event_token.claim_mac, 0))
        return error.InvalidDisklessDeliveryStore;
}

fn verifyClaimMac(secret: []const u8, session: *const Session, kind: Store.SlotKind, slot: *const TokenSlot) !void {
    // Empty MAC is accepted only for the one-time schema-2 migration path.
    if (std.mem.allEqual(u8, &slot.claim_mac, 0)) return;
    const expected = claimMac(secret, session, kind, slot);
    if (!std.crypto.timing_safe.eql([hash_len]u8, expected, slot.claim_mac)) return error.InvalidDisklessDeliveryStore;
}

/// 从 master secret + deployment_id + session_id + `event:append` audience
/// 确定性派生唯一 durable token，复用共享域分离原语。
///
/// 确定性是 session 跨 daemon 重启可恢复的关键：重启后用同一 secret +
/// deployment_id + session_id + scope 重构出与签发时完全相同的 raw token。
/// raw token 本身从不持久化，内存只存 `cred.hashOf(raw, secret)`。
///
/// audience 固定为 `event:append`，resource_id = session_id；generation/counter
/// 固定 0（diskless delivery 无 generation/counter 概念）。
fn deriveToken(self: *const Store, session_id: []const u8, kind: Store.SlotKind, destination: *[token_len]u8) void {
    _ = kind;
    const scope: cred.Scope = .event_append;
    cred.deriveToken(destination, self.secret, self.deployment_id, scope.canonicalName(), session_id, 0, 0);
}

/// 重启恢复：用 `deriveToken` 重构 raw token，再与持久化 hash 比对验证。
/// 这是 session 跨 daemon 重启可恢复的依据。v0.2.3 冻结语义：
/// - hash 长度合法但内容不匹配 → `CapabilityRecoveryMismatch`（调用方设
///   `recovery_incomplete`，不全局 fail closed）
/// - hash 长度非法、claim 篡改、session id 篡改等结构性损坏 →
///   `InvalidDisklessDeliveryStore`（daemon 拒绝启动）
/// terminal phase session 不调用此函数（由 `restorePersisted` 跳过）。
fn reconstructAndVerifyRaw(self: *const Store, session: *Session, kind: Store.SlotKind) !void {
    const slot = &session.event_token;
    if (!slot.issued) return;
    const raw = &session.event_token_raw;
    deriveToken(self, &session.session_id, kind, raw);
    const computed = cred.hashOf(raw, self.secret);
    if (!std.mem.eql(u8, &computed, &slot.hash)) return error.CapabilityRecoveryMismatch;
}

/// Reconstruct the only durable scoped token (event). A hash mismatch marks the
/// delivery recovery-incomplete and clears the raw token.
fn reconstructAllOrMarkIncomplete(self: *const Store, session: *Session) !void {
    const kinds = [_]Store.SlotKind{.event};
    for (kinds) |kind| {
        reconstructAndVerifyRaw(self, session, kind) catch |err| switch (err) {
            // hash 内容不匹配（master secret 变化或 hash 被篡改）：
            // 标记该 session 为 recovery_incomplete，durable event token 不可用。
            // 若 reconstructAndVerifyRaw 未来增加结构性损坏错误（如
            // InvalidDisklessDeliveryStore），编译器会在此处强制要求显式处理，
            // 确保结构性损坏不会降级为 recovery_incomplete。
            error.CapabilityRecoveryMismatch => {
                session.recovery_incomplete = true;
                @memset(&session.event_token_raw, 0);
                session.event_token.issued = false;
                return;
            },
        };
    }
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

test "event-only checkpoint restores lifecycle capability without raw token" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{path});
    defer std.testing.allocator.free(checkpoint);
    const secret = [_]u8{0x5a} ** 32;

    var before = Store.init(std.testing.allocator, &secret, "dep-test", checkpoint);
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
    try before.issue(std.testing.io, &session_id, .event);
    const event_raw = session.event_token_raw;

    const persisted = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, checkpoint, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(persisted);
    try std.testing.expect(std.mem.indexOf(u8, persisted, &event_raw) == null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "\"credential_model\": \"event-only-v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "config_token") == null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "rootfs_token") == null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "agent_token") == null);

    var after = Store.init(std.testing.allocator, &secret, "dep-test", checkpoint);
    try std.testing.expectEqual(@as(usize, 1), try after.load(std.testing.io, 10, 1010));
    const restored = after.find(&session_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u64, 4096), restored.rootfs_size);
    try std.testing.expectEqual(@as(u64, 16384), restored.rootfs_uncompressed_size);
    try std.testing.expectEqualSlices(u8, &event_raw, &restored.event_token_raw);
    try std.testing.expectEqual(cred.Decision.ok, after.verify(
        &session_id,
        &restored.event_token_raw,
        .event,
        "node-1",
        "",
        "",
        0,
        11,
    ));
}

test "checkpoint rejects legacy schemas and pre-simplification v4" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/diskless-delivery.json", .{dir});
    defer std.testing.allocator.free(checkpoint);
    const secret = [_]u8{0x61} ** 32;

    for ([_]u32{ 1, 2, 3, 4 }) |version| {
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":{d},\"revision\":0,\"sessions\":[]}}", .{version});
        defer std.testing.allocator.free(bytes);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = checkpoint, .data = bytes });
        var store = Store.init(std.testing.allocator, &secret, "dep-test", checkpoint);
        try std.testing.expectError(error.InvalidDisklessDeliveryStore, store.load(std.testing.io, 100, 1000));
    }
}

test "diskless event CAS is ordered and exact retry is idempotent" {
    const secret = [_]u8{0x33} ** 32;
    var store = Store.init(std.testing.allocator, &secret, "dep-test", "");
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
    var store = Store.init(std.testing.allocator, &secret, "dep-test", "");
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

test "terminal phase session restores without capability reconstruction" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/terminal-delivery.json", .{path});
    defer std.testing.allocator.free(checkpoint);
    const secret = [_]u8{0x6b} ** 32;

    var before = Store.init(std.testing.allocator, &secret, "dep-test", checkpoint);
    const session = try before.begin(
        std.testing.io,
        "node-term",
        "profile-term",
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
    try before.issue(std.testing.io, &session_id, .event);
    try before.markBootConfigFetched(std.testing.io, &session_id);
    try before.issue(std.testing.io, &session_id, .event);
    _ = try before.advanceEvent(std.testing.io, &session_id, .boot_config_fetched, .diskless_initrd_started, 0, 1100);
    _ = try before.advanceEvent(std.testing.io, &session_id, .diskless_initrd_started, .diskless_rootfs_downloading, 1, 1200);
    _ = try before.advanceEvent(std.testing.io, &session_id, .diskless_rootfs_downloading, .diskless_rootfs_verified, 2, 1300);
    _ = try before.advanceEvent(std.testing.io, &session_id, .diskless_rootfs_verified, .diskless_rootfs_mounted, 3, 1400);
    _ = try before.advanceEvent(std.testing.io, &session_id, .diskless_rootfs_mounted, .diskless_switching_root, 4, 1500);
    _ = try before.advanceEvent(std.testing.io, &session_id, .diskless_switching_root, .diskless_agent_configuring, 5, 1600);
    _ = try before.advanceEvent(std.testing.io, &session_id, .diskless_agent_configuring, .diskless_running, 6, 1700);
    // session is now terminal (diskless.running)
    try std.testing.expect(before.find(&session_id).?.phase.isTerminal());

    // reload with same secret — terminal session should be restored but without capability
    var after = Store.init(std.testing.allocator, &secret, "dep-test", checkpoint);
    try std.testing.expectEqual(@as(usize, 1), try after.load(std.testing.io, 10, 1800));
    const restored = after.find(&session_id) orelse return error.TestExpectedEqual;
    try std.testing.expect(restored.phase.isTerminal());
    try std.testing.expectEqual(@as(bool, false), restored.recovery_incomplete);
    // terminal session: lifecycle capability is revoked
    try std.testing.expectEqual(@as(bool, false), restored.event_token.issued);
    // verify returns invalid_token (not recovery_incomplete) for terminal session
    try std.testing.expectEqual(cred.Decision.invalid_token, after.verify(
        &session_id,
        &restored.event_token_raw,
        .event,
        "node-term",
        "",
        "",
        0,
        11,
    ));
}

/// 构造一个已持久化为 terminal（diskless.running）的 checkpoint 并返回
/// session id 与文件字节，供 §6.3 语义冻结负测篡改。
fn terminalCheckpointBytes(io: std.Io, allocator: std.mem.Allocator, path: []const u8, secret: []const u8) !struct { session_id: [id_len]u8, bytes: []u8 } {
    var before = Store.init(allocator, secret, "dep-test", path);
    const session = try before.begin(
        io,
        "node-term",
        "profile-term",
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
    try before.pinAgentPlan(io, &session_id, "{\"schema_version\":1}");
    try before.issue(io, &session_id, .event);
    try before.markBootConfigFetched(io, &session_id);
    try before.issue(io, &session_id, .event);
    _ = try before.advanceEvent(io, &session_id, .boot_config_fetched, .diskless_initrd_started, 0, 1100);
    _ = try before.advanceEvent(io, &session_id, .diskless_initrd_started, .diskless_rootfs_downloading, 1, 1200);
    _ = try before.advanceEvent(io, &session_id, .diskless_rootfs_downloading, .diskless_rootfs_verified, 2, 1300);
    _ = try before.advanceEvent(io, &session_id, .diskless_rootfs_verified, .diskless_rootfs_mounted, 3, 1400);
    _ = try before.advanceEvent(io, &session_id, .diskless_rootfs_mounted, .diskless_switching_root, 4, 1500);
    _ = try before.advanceEvent(io, &session_id, .diskless_switching_root, .diskless_agent_configuring, 5, 1600);
    _ = try before.advanceEvent(io, &session_id, .diskless_agent_configuring, .diskless_running, 6, 1700);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    return .{ .session_id = session_id, .bytes = bytes };
}

/// 篡改第 `occurrence` 个 `"hash": "` 后的 hash 内容；replacement 长度必须
/// <= 64，其余字节填 'a' 以保持 JSON 结构。
fn tamperHash(bytes: []u8, occurrence: usize, replacement: []const u8) !void {
    if (replacement.len > hash_len) return error.TestUnexpectedResult;
    // persist 使用 indent_2，Stringify 在冒号后输出一个空格。
    const needle = "\"hash\": \"";
    var found: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search_from, needle)) |pos| {
        if (found == occurrence) {
            @memset(bytes[pos + needle.len .. pos + needle.len + hash_len], 'a');
            @memcpy(bytes[pos + needle.len .. pos + needle.len + replacement.len], replacement);
            return;
        }
        found += 1;
        search_from = pos + needle.len;
    }
    return error.TestUnexpectedResult;
}

/// 把第 `occurrence` 个 hash 的 64 字符值缩短为 `replacement`（保持 JSON
/// 结构合法），返回重排后的新缓冲区。
fn shortenHash(allocator: std.mem.Allocator, bytes: []const u8, occurrence: usize, replacement: []const u8) ![]u8 {
    if (replacement.len >= hash_len) return error.TestUnexpectedResult;
    const needle = "\"hash\": \"";
    var found: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search_from, needle)) |pos| {
        if (found == occurrence) {
            const out = try allocator.alloc(u8, bytes.len - hash_len + replacement.len);
            const head = bytes[0 .. pos + needle.len];
            const tail = bytes[pos + needle.len + hash_len ..];
            @memcpy(out[0..head.len], head);
            @memcpy(out[head.len .. head.len + replacement.len], replacement);
            @memcpy(out[head.len + replacement.len ..], tail);
            return out;
        }
        found += 1;
        search_from = pos + needle.len;
    }
    return error.TestUnexpectedResult;
}

fn shortenClaimMac(allocator: std.mem.Allocator, bytes: []const u8, replacement: []const u8) ![]u8 {
    if (replacement.len >= hash_len) return error.TestUnexpectedResult;
    const needle = "\"claim_mac\": \"";
    const pos = std.mem.indexOf(u8, bytes, needle) orelse return error.TestUnexpectedResult;
    const out = try allocator.alloc(u8, bytes.len - hash_len + replacement.len);
    const head = bytes[0 .. pos + needle.len];
    const tail = bytes[pos + needle.len + hash_len ..];
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len .. head.len + replacement.len], replacement);
    @memcpy(out[head.len + replacement.len ..], tail);
    return out;
}

test "v0.2.3: terminal session hash 内容篡改不 fail closed 且 capability 全拒" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/tamper-content.json", .{path});
    defer std.testing.allocator.free(checkpoint);
    const secret = [_]u8{0x6b} ** 32;
    const helper = try terminalCheckpointBytes(std.testing.io, std.testing.allocator, checkpoint, &secret);
    defer std.testing.allocator.free(helper.bytes);
    // 内容篡改但保持 64 字节合法长度 → 不 fail closed。
    try tamperHash(helper.bytes, 0, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = checkpoint, .data = helper.bytes });

    var after = Store.init(std.testing.allocator, &secret, "dep-test", checkpoint);
    try std.testing.expectEqual(@as(usize, 1), try after.load(std.testing.io, 10, 1800));
    const restored = after.find(&helper.session_id) orelse return error.TestExpectedEqual;
    try std.testing.expect(restored.phase.isTerminal());
    // Terminal session does not reconstruct lifecycle authority.
    try std.testing.expectEqual(cred.Decision.invalid_token, after.verify(&helper.session_id, &restored.event_token_raw, .event, "node-term", "", "", 1, 11));
}

test "v0.2.3: terminal session hash 长度非法仍 fail closed" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/tamper-length.json", .{path});
    defer std.testing.allocator.free(checkpoint);
    const secret = [_]u8{0x6b} ** 32;
    const helper = try terminalCheckpointBytes(std.testing.io, std.testing.allocator, checkpoint, &secret);
    defer std.testing.allocator.free(helper.bytes);
    // hash 长度 != 64 → restoreSlot 结构性损坏 → daemon 拒启。
    const tampered = try shortenHash(std.testing.allocator, helper.bytes, 0, "aa");
    defer std.testing.allocator.free(tampered);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = checkpoint, .data = tampered });
    var after = Store.init(std.testing.allocator, &secret, "dep-test", checkpoint);
    try std.testing.expectError(error.InvalidDisklessDeliveryStore, after.load(std.testing.io, 10, 1800));
}

test "v0.2.3: non-terminal checkpoint claim tampering fails closed" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/claim-tamper.json", .{dir});
    defer std.testing.allocator.free(checkpoint);
    const secret = [_]u8{0x4d} ** 32;
    var before = Store.init(std.testing.allocator, &secret, "dep-test", checkpoint);
    const session = try before.begin(std.testing.io, "node-claim", "profile-claim", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 1, 2, "6.8.0", 50, 1, 1, 100, 1000);
    const session_id = session.session_id;
    try before.issue(std.testing.io, &session_id, .event);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, checkpoint, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    const needle = "\"node_id\": \"node-claim\"";
    const pos = std.mem.indexOf(u8, bytes, needle) orelse return error.TestUnexpectedResult;
    bytes[pos + "\"node_id\": \"node-".len] = 'X';
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = checkpoint, .data = bytes });

    var after = Store.init(std.testing.allocator, &secret, "dep-test", checkpoint);
    try std.testing.expectError(error.InvalidDisklessDeliveryStore, after.load(std.testing.io, 10, 1010));
}

test "checkpoint schema v3 requires every claim MAC" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing-mac.json", .{dir});
    defer std.testing.allocator.free(checkpoint);
    const secret = [_]u8{0x5e} ** 32;
    var before = Store.init(std.testing.allocator, &secret, "dep-test", checkpoint);
    _ = try before.begin(std.testing.io, "node-mac", "profile-mac", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", 1, 2, "6.8.0", 50, 1, 1, 100, 1000);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, checkpoint, std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(bytes);
    const missing = try shortenClaimMac(std.testing.allocator, bytes, "");
    defer std.testing.allocator.free(missing);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = checkpoint, .data = missing });
    var after = Store.init(std.testing.allocator, &secret, "dep-test", checkpoint);
    try std.testing.expectError(error.InvalidDisklessDeliveryStore, after.load(std.testing.io, 10, 1010));
}

test "master secret change causes recovery_incomplete for non-terminal session" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/recovery-delivery.json", .{path});
    defer std.testing.allocator.free(checkpoint);
    const secret_original = [_]u8{0x7c} ** 32;
    const secret_changed = [_]u8{0x8d} ** 32;

    var before = Store.init(std.testing.allocator, &secret_original, "dep-test", checkpoint);
    const session = try before.begin(
        std.testing.io,
        "node-rec",
        "profile-rec",
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
    try before.issue(std.testing.io, &session_id, .event);
    // session is non-terminal (boot_tftp_complete)
    try std.testing.expect(!before.find(&session_id).?.phase.isTerminal());

    // reload with different secret — hash won't match, should set recovery_incomplete
    var after = Store.init(std.testing.allocator, &secret_changed, "dep-test", checkpoint);
    try std.testing.expectEqual(@as(usize, 1), try after.load(std.testing.io, 10, 1010));
    const restored = after.find(&session_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(bool, true), restored.recovery_incomplete);
    try std.testing.expectEqual(@as(bool, false), restored.event_token.issued);
    // verify returns recovery_incomplete for this session
    try std.testing.expectEqual(cred.Decision.recovery_incomplete, after.verify(
        &session_id,
        &restored.event_token_raw,
        .event,
        "node-rec",
        "",
        "",
        0,
        11,
    ));
}

test "multiple sessions: recovery_incomplete only affects mismatched session" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const checkpoint = try std.fmt.allocPrint(std.testing.allocator, "{s}/multi-recovery.json", .{path});
    defer std.testing.allocator.free(checkpoint);
    const secret_original = [_]u8{0x9e} ** 32;
    const secret_changed = [_]u8{0xae} ** 32;

    var before = Store.init(std.testing.allocator, &secret_original, "dep-test", checkpoint);
    // session 1: non-terminal, will have hash mismatch
    const session1 = try before.begin(
        std.testing.io,
        "node-a",
        "profile-a",
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
    try before.pinAgentPlan(std.testing.io, &session1.session_id, "{\"schema_version\":1}");
    try before.issue(std.testing.io, &session1.session_id, .event);

    // session 2: terminal, should restore without issues
    const session2 = try before.begin(
        std.testing.io,
        "node-b",
        "profile-b",
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        4096,
        16384,
        "5.14.0",
        50,
        64,
        32,
        100,
        1000,
    );
    try before.pinAgentPlan(std.testing.io, &session2.session_id, "{\"schema_version\":2}");
    try before.issue(std.testing.io, &session2.session_id, .event);
    try before.markBootConfigFetched(std.testing.io, &session2.session_id);
    try before.issue(std.testing.io, &session2.session_id, .event);
    _ = try before.advanceEvent(std.testing.io, &session2.session_id, .boot_config_fetched, .diskless_initrd_started, 0, 1100);
    _ = try before.advanceEvent(std.testing.io, &session2.session_id, .diskless_initrd_started, .diskless_rootfs_downloading, 1, 1200);
    _ = try before.advanceEvent(std.testing.io, &session2.session_id, .diskless_rootfs_downloading, .diskless_rootfs_verified, 2, 1300);
    _ = try before.advanceEvent(std.testing.io, &session2.session_id, .diskless_rootfs_verified, .diskless_rootfs_mounted, 3, 1400);
    _ = try before.advanceEvent(std.testing.io, &session2.session_id, .diskless_rootfs_mounted, .diskless_switching_root, 4, 1500);
    _ = try before.advanceEvent(std.testing.io, &session2.session_id, .diskless_switching_root, .diskless_agent_configuring, 5, 1600);
    _ = try before.advanceEvent(std.testing.io, &session2.session_id, .diskless_agent_configuring, .diskless_running, 6, 1700);

    // reload with different secret
    var after = Store.init(std.testing.allocator, &secret_changed, "dep-test", checkpoint);
    try std.testing.expectEqual(@as(usize, 2), try after.load(std.testing.io, 10, 1800));

    const restored1 = after.find(&session1.session_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(bool, true), restored1.recovery_incomplete);

    const restored2 = after.find(&session2.session_id) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(bool, false), restored2.recovery_incomplete);
    try std.testing.expect(restored2.phase.isTerminal());
}
