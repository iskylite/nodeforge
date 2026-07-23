//! # v0.2 diskless delivery session + scoped token store
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
    rootfs_size: u64 = 0,
    kernel_buf: [kernel_cap]u8 = [_]u8{0} ** kernel_cap,
    kernel_len: u8 = 0,
    agent_plan_buf: [agent_plan_cap]u8 = [_]u8{0} ** agent_plan_cap,
    agent_plan_len: u32 = 0,
    agent_plan_digest: [digest_len]u8 = [_]u8{0} ** digest_len,
    created_at: i64 = 0,
    expires_at: i64 = 0,
    config_token: TokenSlot = .{},
    agent_token: TokenSlot = .{ .scope = .agent_read },
    event_token: TokenSlot = .{ .scope = .event_append },
    /// raw token 只驻内存（不落盘）；boot-config 响应重放时返回相同 bytes。
    config_token_raw: [token_len]u8 = [_]u8{0} ** token_len,
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

    pub fn init(allocator: std.mem.Allocator, secret: []const u8, path: []const u8) Store {
        return .{ .allocator = allocator, .secret = secret, .path = path };
    }

    pub fn deinit(self: *Store) void { _ = self; }

    /// 创建一个 diskless session（不签发 token）。返回新 session 的只读引用；
    /// config/agent/event token 由 prepare/boot-config 分别签发。
    pub fn begin(self: *Store, io: std.Io, node_id: []const u8, profile: []const u8, rootfs_input_digest: []const u8, rootfs_sha512: []const u8, rootfs_size: u64, kernel_release: []const u8, now_mono: i64, now_utc: i64) !*Session {
        const slot = self.findFree() orelse return error.DisklessSessionCapacity;
        var s: Session = .{ .active = true, .created_at = now_utc, .expires_at = now_utc + default_ttl_seconds };
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
        s.kernel_len = @intCast(@min(kernel_release.len, kernel_cap));
        @memcpy(s.kernel_buf[0..s.kernel_len], kernel_release[0..s.kernel_len]);
        // config token expires with the session; bind content to rootfs sha512.
        s.config_token = .{ .issued = false, .scope = .config_read, .expires_mono = now_mono + default_ttl_seconds };
        const cd_len = @min(sh_len, sha512_len);
        @memcpy(s.config_token.content_digest[0..cd_len], rootfs_sha512[0..cd_len]);
        s.config_token.content_len = @intCast(cd_len);
        s.agent_token = .{ .issued = false, .scope = .agent_read, .expires_mono = now_mono + default_ttl_seconds };
        s.event_token = .{ .issued = false, .scope = .event_append, .expires_mono = now_mono + default_ttl_seconds };
        self.sessions[slot] = s;
        return &self.sessions[slot];
    }

    /// 固定 immutable AgentPlan JSON（boot-config 首次签发时写入），并计算其
    /// canonical SHA-256 作为 agent_plan_digest。后续 agent-plan GET 返回相同 bytes。
    pub fn pinAgentPlan(self: *Store, session_id: []const u8, json: []const u8) !void {
        const s = self.find(session_id) orelse return error.DisklessSessionNotFound;
        if (json.len > agent_plan_cap) return error.AgentPlanTooLarge;
        @memcpy(s.agent_plan_buf[0..json.len], json);
        s.agent_plan_len = @intCast(json.len);
        var raw: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(json, &raw, .{});
        _ = std.fmt.bufPrint(&s.agent_plan_digest, "{x}", .{raw}) catch unreachable;
    }

    /// 签发一个 scoped token（32 字节随机 -> 64 hex）。持久 HMAC hash + claim，
    /// raw token 只驻内存（`*_token_raw`），供 capsule 交付 / boot-config 响应重放。
    pub fn issue(self: *Store, io: std.Io, session_id: []const u8, slot_kind: SlotKind) !void {
        const s = self.find(session_id) orelse return error.DisklessSessionNotFound;
        const slot = self.slotOf(s, slot_kind);
        var raw: [token_len]u8 = undefined;
        try generateToken(io, &raw);
        slot.hash = cred.hashOf(&raw, self.secret);
        slot.issued = true;
        switch (slot_kind) {
            .config => @memcpy(&s.config_token_raw, &raw),
            .agent => @memcpy(&s.agent_token_raw, &raw),
            .event => @memcpy(&s.event_token_raw, &raw),
        }
        if (slot_kind == .agent) {
            const cd_len = @min(s.agent_plan_digest.len, digest_len);
            @memcpy(slot.content_digest[0..cd_len], s.agent_plan_digest[0..cd_len]);
            slot.content_len = @intCast(cd_len);
        }
    }

    pub fn rawToken(self: *Store, s: *const Session, kind: SlotKind) []const u8 {
        _ = self;
        return switch (kind) {
            .config => &s.config_token_raw,
            .agent => &s.agent_token_raw,
            .event => &s.event_token_raw,
        };
    }

    pub const SlotKind = enum { config, agent, event };

    fn slotOf(self: *Store, s: *Session, kind: SlotKind) *TokenSlot {
        _ = self;
        return switch (kind) {
            .config => &s.config_token,
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
            .event_seq = slot.event_seq,
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
        for (&self.sessions) |*s| if (s.active and std.mem.eql(u8, s.nodeId(), node_id)) return s;
        return null;
    }

    fn findFree(self: *Store) ?usize {
        for (&self.sessions, 0..) |*s, i| if (!s.active) return i;
        return null;
    }
};

fn generateId(io: std.Io, destination: *[id_len]u8) !void {
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    for (random, 0..) |byte, index| {
        destination[index * 2] = hex(byte >> 4);
        destination[index * 2 + 1] = hex(byte & 0x0f);
    }
}

fn generateToken(io: std.Io, destination: *[token_len]u8) !void {
    var random: [32]u8 = undefined;
    try io.randomSecure(&random);
    for (random, 0..) |byte, index| {
        destination[index * 2] = hex(byte >> 4);
        destination[index * 2 + 1] = hex(byte & 0x0f);
    }
}

fn hex(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + (nibble - 10);
}
