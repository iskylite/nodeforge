//! Short-lived operational state.  DHCP state is deliberately separate from
//! configuration and has a small, serialisable projection for restart recovery.
const std = @import("std");

pub const RuntimeState = struct {
    schema_version: u32 = 2,
    service: ServiceState = .starting,
    config_generation: u64 = 1,
    tftp: TftpState = .{},
    dhcp: DhcpState = .{},
};

pub const LeasePhase = enum { empty, offered, active, abandoned };

pub const DhcpLease = struct {
    phase: LeasePhase = .empty,
    known: bool = false,
    ip: u32 = 0,
    mac: [6]u8 = [_]u8{0} ** 6,
    /// Unix seconds.  `abandoned` uses this as its quarantine deadline.
    expires_at: i64 = 0,
    pub fn used(self: *const DhcpLease) bool {
        return self.phase != .empty;
    }
    pub fn matches(self: *const DhcpLease, value: []const u8) bool {
        return self.used() and value.len == 6 and std.mem.eql(u8, &self.mac, value);
    }
};

pub const DhcpState = struct {
    pub const max_leases = 256;
    leases: [max_leases]DhcpLease = [_]DhcpLease{.{}} ** max_leases,
    mutex: std.atomic.Mutex = .unlocked,

    /// Offer an address without turning it into a committed lease.  Expired
    /// offers and abandoned entries are reclaimed before every allocation.
    pub fn offer(self: *DhcpState, mac: []const u8, candidate: u32, known: bool, now: i64, seconds: u32) u32 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.reapLocked(now);
        for (&self.leases) |*lease| if (lease.matches(mac)) {
            // An abandoned address remains quarantined, but its client may be
            // offered a different free address from the same pool.
            if (lease.phase == .abandoned) continue;
            lease.known = known;
            lease.expires_at = now + @as(i64, seconds);
            if (lease.ip == candidate or lease.phase == .active) return lease.ip;
            return 0;
        };
        for (&self.leases) |*lease| if (lease.used() and lease.ip == candidate) return 0;
        for (&self.leases) |*lease| if (!lease.used()) {
            lease.* = .{ .phase = .offered, .known = known, .ip = candidate, .expires_at = now + @as(i64, seconds) };
            @memcpy(&lease.mac, mac[0..6]);
            return candidate;
        };
        return 0;
    }

    /// Drop only a pending OFFER that was never put on the wire. This is used
    /// when Ping Probe cannot run: an active lease must never be removed just
    /// because a later DISCOVER could not be conflict-checked.
    pub fn cancelOffer(self: *DhcpState, mac: []const u8, candidate: u32) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.leases) |*lease| if (lease.matches(mac) and lease.ip == candidate and lease.phase == .offered) {
            lease.* = .{};
            return true;
        };
        return false;
    }

    /// Commit only an address previously offered to this MAC. A configured
    /// static reservation is the sole exception: it may ACK its declared
    /// address after a restart without retaining an in-memory OFFER. Merely
    /// being a known node never authorizes an arbitrary DHCP REQUEST.
    pub fn acknowledge(self: *DhcpState, mac: []const u8, candidate: u32, known: bool, static_reservation: bool, now: i64, seconds: u32) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.reapLocked(now);
        for (&self.leases) |*lease| if (lease.matches(mac) and lease.ip == candidate) {
            if (lease.phase == .abandoned) return false;
            lease.phase = .active;
            lease.known = known;
            lease.expires_at = now + @as(i64, seconds);
            return true;
        };
        if (!static_reservation) return false;
        for (&self.leases) |*lease| if (lease.used() and lease.ip == candidate) return false;
        for (&self.leases) |*lease| if (!lease.used()) {
            lease.* = .{ .phase = .active, .known = true, .ip = candidate, .expires_at = now + @as(i64, seconds) };
            @memcpy(&lease.mac, mac[0..6]);
            return true;
        };
        return false;
    }
    pub fn release(self: *DhcpState, mac: []const u8) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var released = false;
        for (&self.leases) |*lease| if (lease.matches(mac) and lease.phase != .abandoned) {
            lease.* = .{};
            released = true;
        };
        return released;
    }
    pub fn decline(self: *DhcpState, mac: []const u8, now: i64, quarantine_seconds: u32) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (&self.leases) |*lease| if (lease.matches(mac) and lease.phase != .abandoned) {
            lease.phase = .abandoned;
            lease.expires_at = now + @as(i64, quarantine_seconds);
            return true;
        };
        return false;
    }
    pub fn snapshot(self: *DhcpState, destination: *[max_leases]DhcpLease) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        destination.* = self.leases;
    }
    /// Replace leases restored from the durable snapshot under the same lock
    /// used by all DHCP mutations. Startup is currently single-threaded, but
    /// keeping this boundary prevents future lifecycle changes from bypassing
    /// state synchronization.
    pub fn restore(self: *DhcpState, source: *const [max_leases]DhcpLease) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.leases = source.*;
    }
    fn reapLocked(self: *DhcpState, now: i64) void {
        for (&self.leases) |*lease| {
            if (lease.used() and lease.expires_at <= now) lease.* = .{};
        }
    }
};

/// JSON-safe durable projection. Mutexes and TFTP counters never enter this file.
pub const DhcpRuntimeFile = struct { schema_version: u32 = 1, saved_at: i64, leases: []const DhcpLease };

pub const TftpState = struct {
    started: std.atomic.Value(u64) = .init(0),
    completed: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),
    sessions: [max_sessions]TftpSession = [_]TftpSession{.{}} ** max_sessions,
    next_session_id: u64 = 1,
    mutex: std.atomic.Mutex = .unlocked,
    pub const max_sessions = 32;
    pub fn begin(self: *TftpState, filename: []const u8) usize {
        lock(&self.mutex);
        defer self.mutex.unlock();
        const slot: usize = @intCast((self.next_session_id - 1) % max_sessions);
        self.sessions[slot] = .{ .id = self.next_session_id, .phase = .running };
        copyLabel(&self.sessions[slot].filename, filename);
        self.next_session_id +%= 1;
        _ = self.started.fetchAdd(1, .monotonic);
        return slot;
    }
    pub fn finish(self: *TftpState, slot: usize, success: bool) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        self.sessions[slot].phase = if (success) .completed else .failed;
        _ = if (success) self.completed.fetchAdd(1, .monotonic) else self.failed.fetchAdd(1, .monotonic);
    }
    pub fn snapshot(self: *TftpState, destination: *[max_sessions]TftpSession) void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        destination.* = self.sessions;
    }
};
pub const TftpSession = struct {
    id: u64 = 0,
    phase: TftpSessionPhase = .empty,
    filename: [128]u8 = [_]u8{0} ** 128,
    pub fn filenameSlice(self: *const TftpSession) []const u8 {
        return self.filename[0 .. std.mem.indexOfScalar(u8, &self.filename, 0) orelse self.filename.len];
    }
};
pub const TftpSessionPhase = enum { empty, running, completed, failed };
pub const ServiceState = enum { starting, running, stopping };
fn copyLabel(destination: *[128]u8, source: []const u8) void {
    destination.* = [_]u8{0} ** destination.len;
    const len = @min(destination.len, source.len);
    @memcpy(destination[0..len], source[0..len]);
}
fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

test "DHCP offer becomes ACK and declined address is quarantined" {
    var state: DhcpState = .{};
    const mac = [_]u8{ 0, 1, 2, 3, 4, 5 };
    try std.testing.expectEqual(@as(u32, 0xc0a81b0a), state.offer(&mac, 0xc0a81b0a, false, 100, 30));
    try std.testing.expect(state.acknowledge(&mac, 0xc0a81b0a, false, false, 101, 60));
    try std.testing.expect(state.decline(&mac, 102, 3600));
    try std.testing.expectEqual(@as(u32, 0), state.offer(&mac, 0xc0a81b0a, false, 103, 30));
}

test "an abandoned candidate does not block ACK or release of the replacement" {
    var state: DhcpState = .{};
    const mac = [_]u8{ 0, 1, 2, 3, 4, 6 };
    try std.testing.expectEqual(@as(u32, 0xc0a81b0a), state.offer(&mac, 0xc0a81b0a, false, 100, 30));
    try std.testing.expect(state.decline(&mac, 101, 3600));
    try std.testing.expectEqual(@as(u32, 0xc0a81b0b), state.offer(&mac, 0xc0a81b0b, false, 102, 30));
    try std.testing.expect(state.acknowledge(&mac, 0xc0a81b0b, false, false, 103, 60));
    try std.testing.expect(state.release(&mac));
    var snapshot: [DhcpState.max_leases]DhcpLease = undefined;
    state.snapshot(&snapshot);
    try std.testing.expectEqual(LeasePhase.abandoned, snapshot[0].phase);
    try std.testing.expectEqual(LeasePhase.empty, snapshot[1].phase);
}

test "unprobed offer can be cancelled without releasing an active lease" {
    var state: DhcpState = .{};
    const offered_mac = [_]u8{ 0, 1, 2, 3, 4, 7 };
    const active_mac = [_]u8{ 0, 1, 2, 3, 4, 8 };
    try std.testing.expectEqual(@as(u32, 0xc0a81b0a), state.offer(&offered_mac, 0xc0a81b0a, false, 100, 30));
    try std.testing.expect(state.cancelOffer(&offered_mac, 0xc0a81b0a));
    try std.testing.expectEqual(@as(u32, 0xc0a81b0b), state.offer(&active_mac, 0xc0a81b0b, false, 100, 30));
    try std.testing.expect(state.acknowledge(&active_mac, 0xc0a81b0b, false, false, 101, 60));
    try std.testing.expect(!state.cancelOffer(&active_mac, 0xc0a81b0b));
}

test "only a static reservation may acknowledge without an offer" {
    var state: DhcpState = .{};
    const unknown_mac = [_]u8{ 0, 1, 2, 3, 4, 9 };
    const known_dynamic_mac = [_]u8{ 0, 1, 2, 3, 4, 10 };
    const static_mac = [_]u8{ 0, 1, 2, 3, 4, 11 };
    const candidate: u32 = 0xc0a81b0a;

    try std.testing.expect(!state.acknowledge(&unknown_mac, candidate, false, false, 100, 60));
    try std.testing.expect(!state.acknowledge(&known_dynamic_mac, candidate, true, false, 100, 60));
    try std.testing.expect(state.acknowledge(&static_mac, candidate, true, true, 100, 60));
}
