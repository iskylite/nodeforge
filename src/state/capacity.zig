//! M4.8 启动时容量与并发的动态派生。
//!
//! 替代硬编码的 256 上限与 TFTP 固定并发默认值。所有派生均取
//! `max(按来源计算, config 显式覆盖)`，绝不因派生缩小运维意图。
//! 详见 docs/archive/M0_M7_LEGACY_DETAILED_DESIGN.md §9.17 与
//! docs/archive/milestone-specs/2026-07-17-concurrency-capacity-scaling-design.md。

const std = @import("std");

/// 持久 daemon 中共享热路径状态表的编译期安全天花板。
/// 固定上限避免协议 worker 在锁内分配，并提供可预测的内存占用；
/// `effective` 是允许的已用条目数，而不是数组前缀长度。
pub const store_ceiling: usize = 2048;

/// v0.4 stable public error code for domain capacity exhaustion.
/// Design requires DisklessSessionCapacity (and peer admission failures) to
/// surface as this code with HTTP 503 fail-closed semantics.
pub const exhausted_code = "capacity.exhausted";

/// Canonical JSON error body for capacity exhaustion (HTTP 503).
pub fn exhaustedJsonBody() []const u8 {
    return "{\"ok\":false,\"error\":{\"code\":\"capacity.exhausted\",\"message\":\"capacity limit reached; retry after active slots free\"}}\n";
}

/// Map Zig capacity-exhaustion errors to the stable public code.
/// Returns null for non-capacity errors so callers can fall through.
pub fn publicErrorCode(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.CapacityExhausted,
        error.DisklessSessionCapacity,
        error.SessionCapacityExhausted,
        error.NodeStatusCapacityExhausted,
        error.OperationCapacityExhausted,
        error.NodeDiscoveryCapacityExhausted,
        error.InventoryCapacityExhausted,
        error.IdentityStoreCapacity,
        error.FirstBootJournalCapacity,
        => exhausted_code,
        else => null,
    };
}

pub const Resource = enum { http_connection, boot_session, rootfs_download };

pub const Admission = struct {
    http_connections: usize = 0,
    boot_sessions: usize = 0,
    rootfs_downloads: usize = 0,

    pub fn tryAcquire(self: *Admission, resource: Resource, limit: usize) !void {
        if (limit == 0) return error.CapacityLimitInvalid;
        const value = self.count(resource);
        if (value >= limit) return error.CapacityExhausted;
        self.setCount(resource, value + 1);
    }

    pub fn release(self: *Admission, resource: Resource) void {
        const value = self.count(resource);
        if (value != 0) self.setCount(resource, value - 1);
    }

    pub fn count(self: *const Admission, resource: Resource) usize {
        return switch (resource) {
            .http_connection => self.http_connections,
            .boot_session => self.boot_sessions,
            .rootfs_download => self.rootfs_downloads,
        };
    }

    fn setCount(self: *Admission, resource: Resource, value: usize) void {
        switch (resource) {
            .http_connection => self.http_connections = value,
            .boot_session => self.boot_sessions = value,
            .rootfs_download => self.rootfs_downloads = value,
        }
    }
};

pub const TokenBucket = struct {
    tokens: u64,
    last_second: i64,
    refill_per_second: u64,
    burst: u64,

    pub fn init(refill_per_second: u32, burst: u32, now: i64) !TokenBucket {
        if (refill_per_second == 0 or burst == 0 or now <= 0) return error.InvalidTokenBucket;
        return .{ .tokens = burst, .last_second = now, .refill_per_second = refill_per_second, .burst = burst };
    }

    pub fn take(self: *TokenBucket, count: u32, now: i64) !void {
        if (count == 0 or now <= 0 or now < self.last_second) return error.InvalidTokenBucket;
        const elapsed = @as(u64, @intCast(now - self.last_second));
        const refill = elapsed *| self.refill_per_second;
        self.tokens = @min(self.burst, self.tokens +| refill);
        self.last_second = now;
        if (self.tokens < count) return error.RateLimited;
        self.tokens -= count;
    }
};

/// 解析点分十进制 IPv4 为 u32；非法返回 null。
fn parseIpv4U32(s: []const u8) ?u32 {
    var parts: [4]u32 = .{ 0, 0, 0, 0 };
    var idx: usize = 0;
    var iter = std.mem.splitScalar(u8, s, '.');
    while (iter.next()) |seg| {
        if (idx >= 4) return null;
        if (seg.len == 0 or seg.len > 3) return null;
        var v: u32 = 0;
        for (seg) |ch| {
            if (ch < '0' or ch > '9') return null;
            v = v * 10 + (ch - '0');
        }
        if (v > 255) return null;
        parts[idx] = v;
        idx += 1;
    }
    if (idx != 4) return null;
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
}

/// 解析 CIDR 子网前缀，返回可用主机数（2^(32-prefix)-2）。
/// 与 `src/dhcp/server.zig` 的 `network()` 一致，仅接受 prefix <= 30；
/// /31、/32 或非法 CIDR 返回 0（不作为 lease 容量来源）。
pub fn usableHosts(cidr: []const u8) usize {
    const slash = std.mem.indexOfScalar(u8, cidr, '/') orelse return 0;
    if (parseIpv4U32(cidr[0..slash]) == null) return 0;
    const prefix = std.fmt.parseInt(u6, cidr[slash + 1 ..], 10) catch return 0;
    if (prefix > 30) return 0;
    const host_bits: u6 = 32 - prefix;
    return (@as(usize, 1) << host_bits) - 2;
}

/// 并发容量（leases + sessions）：max(usable_hosts(subnet), config 覆盖)，下限 1。
pub fn leaseCapacity(subnet: []const u8, config_override: ?u32) usize {
    const derived = usableHosts(subnet);
    const cap = if (config_override) |o| @max(derived, @as(usize, o)) else derived;
    return @max(cap, 1);
}

/// 受管容量（status/inventory/deployment）：max(受管节点数, config 覆盖)，下限 1。
pub fn managedCapacity(node_count: usize, config_override: ?u32) usize {
    const cap = if (config_override) |o| @max(node_count, @as(usize, o)) else node_count;
    return @max(cap, 1);
}

/// Shared non-terminal install + diskless deployment wave default (product limit).
pub const deployment_wave_default: usize = 512;
/// Legacy alias: diskless storage defaults track the wave default.
pub const diskless_delivery_default: usize = deployment_wave_default;
pub const first_boot_default: usize = deployment_wave_default;

/// Shared wave capacity: one budget for non-terminal install + diskless nodes.
/// Explicit override only enlarges the default; clamped to `store_ceiling`.
pub fn deploymentWaveCapacity(config_override: ?u32) usize {
    const derived = deployment_wave_default;
    const cap = if (config_override) |o| @max(derived, @as(usize, o)) else derived;
    return @min(@max(cap, 1), store_ceiling);
}

/// Structural diskless slot ceiling helper (not a separate product admission budget).
pub fn disklessDeliveryCapacity(config_override: ?u32) usize {
    return deploymentWaveCapacity(config_override);
}

/// Structural first-boot active slot helper (not a separate product admission budget).
pub fn firstBootCapacity(managed: usize, config_override: ?u32) usize {
    const derived = @max(first_boot_default, managed);
    const cap = if (config_override) |o| @max(derived, @as(usize, o)) else derived;
    return @min(@max(cap, 1), store_ceiling);
}

/// Daemon-level shared admission for non-terminal install + diskless deployments.
/// Stores hold structural slots up to `store_ceiling`; this counter enforces the
/// product wave limit (default 512, max 2048).
///
/// `active` is an atomic counter so lifecycle acquire/release and diagnostic
/// readers (`count` / `remaining` / `overLimit`) never form a data race under
/// Zig's memory model. `limit` is fixed after `init` and may be read plainly.
pub const DeploymentWaveAdmission = struct {
    active: std.atomic.Value(usize) = .init(0),
    limit: usize = deployment_wave_default,

    pub fn init(limit: usize) DeploymentWaveAdmission {
        return .{ .limit = @max(@as(usize, 1), @min(limit, store_ceiling)) };
    }

    pub fn tryAcquire(self: *DeploymentWaveAdmission) !void {
        // When restored active exceeds the configured limit (config lowered across
        // restart), refuse new admits until real occupancy falls at/below limit.
        while (true) {
            const a = self.active.load(.acquire);
            if (a >= self.limit) return error.CapacityExhausted;
            if (self.active.cmpxchgWeak(a, a + 1, .acq_rel, .acquire) == null) return;
        }
    }

    pub fn release(self: *DeploymentWaveAdmission) void {
        while (true) {
            const a = self.active.load(.acquire);
            if (a == 0) return;
            if (self.active.cmpxchgWeak(a, a - 1, .acq_rel, .acquire) == null) return;
        }
    }

    /// After restore from disk, set active to the real sum of non-terminal
    /// install+diskless. Never truncates to `limit`: in-flight objects must keep
    /// counting even when config was lowered; `tryAcquire` stays fail-closed
    /// until occupancy drops to/below the new limit.
    pub fn reseed(self: *DeploymentWaveAdmission, active: usize) void {
        self.active.store(active, .release);
    }

    pub fn count(self: *const DeploymentWaveAdmission) usize {
        return self.active.load(.acquire);
    }

    pub fn remaining(self: *const DeploymentWaveAdmission) usize {
        const a = self.active.load(.acquire);
        return if (a >= self.limit) 0 else self.limit - a;
    }

    /// True when restored (or live) occupancy is above the configured product limit.
    pub fn overLimit(self: *const DeploymentWaveAdmission) bool {
        return self.active.load(.acquire) > self.limit;
    }
};

/// AgentPlan / InstallFirstBootPlan wire DTO ceiling (bytes).
pub const agent_plan_max_bytes: usize = 256 * 1024;

/// Index checkpoint (sessions + digests + terminals) read ceiling.
/// AgentPlan bodies are stored as separate content-addressed files and are not
/// loaded through this limit. Sized for 2048 lightweight session records with
/// JSON overhead, not for N×256 KiB plan bodies.
pub const checkpoint_index_read_max_bytes: usize = 32 * 1024 * 1024;

/// Legacy name kept for callers; equals the index ceiling after plan externalization.
pub const checkpoint_read_max_bytes: usize = checkpoint_index_read_max_bytes;

/// Single external plan file read ceiling (one AgentPlan body).
pub const agent_plan_file_read_max_bytes: usize = agent_plan_max_bytes + 4096;

/// TFTP 并发：config 覆盖优先，否则 max(128, 2×核)，封顶 u16。
pub fn tftpConcurrency(cpu_count: usize, config_override: ?u16) u16 {
    if (config_override) |o| return o;
    const doubled: usize = cpu_count *| 2;
    const v: usize = @max(128, doubled);
    return @intCast(@min(v, 65535));
}

test "usableHosts parses CIDR prefix" {
    try std.testing.expectEqual(@as(usize, 254), usableHosts("192.168.27.0/24"));
    try std.testing.expectEqual(@as(usize, 1022), usableHosts("192.168.0.0/22"));
    try std.testing.expectEqual(@as(usize, 65534), usableHosts("10.0.0.0/16"));
    try std.testing.expectEqual(@as(usize, 0), usableHosts("192.168.27.0/31"));
    try std.testing.expectEqual(@as(usize, 0), usableHosts("not-a-cidr"));
    try std.testing.expectEqual(@as(usize, 0), usableHosts("192.168.27.0"));
}

test "leaseCapacity takes max of subnet-derived and config override" {
    // /22 -> 1022，覆盖更小则取派生
    try std.testing.expectEqual(@as(usize, 1022), leaseCapacity("192.168.0.0/22", 256));
    // 覆盖更大则取覆盖
    try std.testing.expectEqual(@as(usize, 2048), leaseCapacity("192.168.0.0/22", 2048));
    // 无覆盖取派生
    try std.testing.expectEqual(@as(usize, 254), leaseCapacity("192.168.27.0/24", null));
    // 非法子网 + 覆盖取覆盖
    try std.testing.expectEqual(@as(usize, 512), leaseCapacity("bad", 512));
    // 全空下限 1
    try std.testing.expectEqual(@as(usize, 1), leaseCapacity("bad", null));
}

test "managedCapacity takes max of node count and override" {
    try std.testing.expectEqual(@as(usize, 1024), managedCapacity(1024, null));
    try std.testing.expectEqual(@as(usize, 2048), managedCapacity(100, 2048));
    try std.testing.expectEqual(@as(usize, 100), managedCapacity(100, 50));
    try std.testing.expectEqual(@as(usize, 1), managedCapacity(0, null));
}

test "tftpConcurrency auto-derives max(128, 2x cores) when no override" {
    try std.testing.expectEqual(@as(u16, 128), tftpConcurrency(8, null)); // 2x8=16 < 128
    try std.testing.expectEqual(@as(u16, 128), tftpConcurrency(64, null)); // 2x64=128
    try std.testing.expectEqual(@as(u16, 192), tftpConcurrency(96, null)); // 2x96=192
    try std.testing.expectEqual(@as(u16, 256), tftpConcurrency(128, null)); // 2x128=256
    // 超大核数封顶 u16
    try std.testing.expectEqual(@as(u16, 65535), tftpConcurrency(40000, null));
    // 覆盖优先
    try std.testing.expectEqual(@as(u16, 4), tftpConcurrency(96, 4));
    try std.testing.expectEqual(@as(u16, 255), tftpConcurrency(8, 255));
}

test "v0.4 token buckets enforce refill and burst" {
    var bucket = try TokenBucket.init(2, 2, 1);
    try bucket.take(2, 1);
    try std.testing.expectError(error.RateLimited, bucket.take(1, 1));
    try bucket.take(1, 2);
    try std.testing.expectError(error.InvalidTokenBucket, bucket.take(1, 1));
}

test "v0.4 Admission.tryAcquire exhausts with CapacityExhausted mapped to capacity.exhausted" {
    var admission: Admission = .{};
    try admission.tryAcquire(.boot_session, 1);
    try std.testing.expectError(error.CapacityExhausted, admission.tryAcquire(.boot_session, 1));
    const code = publicErrorCode(error.CapacityExhausted) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(exhausted_code, code);
    try std.testing.expect(std.mem.indexOf(u8, exhaustedJsonBody(), "\"code\":\"capacity.exhausted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exhaustedJsonBody(), "\"ok\":false") != null);
}

test "v0.4 diskless and first-boot capacity helpers honor defaults and ceiling" {
    try std.testing.expectEqual(@as(usize, 512), deploymentWaveCapacity(null));
    try std.testing.expectEqual(@as(usize, 1024), deploymentWaveCapacity(1024));
    try std.testing.expectEqual(@as(usize, 512), deploymentWaveCapacity(64)); // never shrink below default
    try std.testing.expectEqual(@as(usize, 2048), deploymentWaveCapacity(4096)); // clamp ceiling
    try std.testing.expectEqual(@as(usize, 512), disklessDeliveryCapacity(null));
    try std.testing.expectEqual(@as(usize, 512), firstBootCapacity(1, null));
    try std.testing.expectEqual(@as(usize, 1024), firstBootCapacity(1024, null));
    try std.testing.expectEqual(@as(usize, 2048), firstBootCapacity(100, 2048));
    try std.testing.expectEqual(@as(usize, 256 * 1024), agent_plan_max_bytes);
    // Index ceiling is far below N×256KiB plan bodies — bodies are external files.
    try std.testing.expect(checkpoint_index_read_max_bytes < 256 * agent_plan_max_bytes);
    try std.testing.expectEqual(checkpoint_index_read_max_bytes, checkpoint_read_max_bytes);
}

test "v0.4 shared deployment wave admits install+diskless under one limit" {
    var wave = DeploymentWaveAdmission.init(4);
    try wave.tryAcquire();
    try wave.tryAcquire();
    try wave.tryAcquire();
    try wave.tryAcquire();
    try std.testing.expectError(error.CapacityExhausted, wave.tryAcquire());
    wave.release();
    try wave.tryAcquire();
    try std.testing.expectEqual(@as(usize, 4), wave.count());
    wave.reseed(1);
    try std.testing.expectEqual(@as(usize, 1), wave.count());
}

test "v0.4 reseed keeps real active above limit and blocks new admits until drain" {
    var wave = DeploymentWaveAdmission.init(4);
    // Checkpoint restored 6 non-terminal objects after config was lowered to 4.
    wave.reseed(6);
    try std.testing.expectEqual(@as(usize, 6), wave.count());
    try std.testing.expect(wave.overLimit());
    try std.testing.expectEqual(@as(usize, 0), wave.remaining());
    try std.testing.expectError(error.CapacityExhausted, wave.tryAcquire());
    // One terminal release → still above limit → still refuse.
    wave.release();
    try std.testing.expectEqual(@as(usize, 5), wave.count());
    try std.testing.expectError(error.CapacityExhausted, wave.tryAcquire());
    wave.release(); // 4
    try std.testing.expectError(error.CapacityExhausted, wave.tryAcquire()); // active==limit
    wave.release(); // 3
    try wave.tryAcquire(); // back to limit
    try std.testing.expectEqual(@as(usize, 4), wave.count());
    try std.testing.expect(!wave.overLimit());
}

// Concurrent acquire/release + diagnostic reads must not data-race (atomic active).
test "v0.4 DeploymentWaveAdmission concurrent acquire release and count" {
    var wave = DeploymentWaveAdmission.init(64);
    const Ctx = struct {
        wave: *DeploymentWaveAdmission,
        fn worker(ctx: *@This()) void {
            var i: usize = 0;
            while (i < 2000) : (i += 1) {
                ctx.wave.tryAcquire() catch {
                    _ = ctx.wave.count();
                    _ = ctx.wave.remaining();
                    _ = ctx.wave.overLimit();
                    continue;
                };
                _ = ctx.wave.count();
                _ = ctx.wave.remaining();
                ctx.wave.release();
            }
        }
    };
    var ctx: Ctx = .{ .wave = &wave };
    const t1 = try std.Thread.spawn(.{}, Ctx.worker, .{&ctx});
    const t2 = try std.Thread.spawn(.{}, Ctx.worker, .{&ctx});
    const t3 = try std.Thread.spawn(.{}, Ctx.worker, .{&ctx});
    t1.join();
    t2.join();
    t3.join();
    // All releases matched acquires → counter must drain to zero.
    try std.testing.expectEqual(@as(usize, 0), wave.count());
    try std.testing.expectEqual(@as(usize, 64), wave.remaining());
}

test "v0.4 DisklessSessionCapacity and SessionCapacityExhausted map to capacity.exhausted" {
    try std.testing.expectEqualStrings(exhausted_code, publicErrorCode(error.DisklessSessionCapacity).?);
    try std.testing.expectEqualStrings(exhausted_code, publicErrorCode(error.SessionCapacityExhausted).?);
    try std.testing.expectEqualStrings(exhausted_code, publicErrorCode(error.NodeStatusCapacityExhausted).?);
    try std.testing.expectEqualStrings(exhausted_code, publicErrorCode(error.OperationCapacityExhausted).?);
    try std.testing.expectEqualStrings(exhausted_code, publicErrorCode(error.NodeDiscoveryCapacityExhausted).?);
    try std.testing.expectEqualStrings(exhausted_code, publicErrorCode(error.InventoryCapacityExhausted).?);
    try std.testing.expectEqualStrings(exhausted_code, publicErrorCode(error.FirstBootJournalCapacity).?);
    try std.testing.expectEqualStrings(exhausted_code, publicErrorCode(error.IdentityStoreCapacity).?);
    try std.testing.expect(publicErrorCode(error.OutOfMemory) == null);
    try std.testing.expect(publicErrorCode(error.FileNotFound) == null);
}

test "v0.4 boot session Link.state surfaces capacity.exhausted for trace and events" {
    const boot_session = @import("boot_session.zig");
    const link: boot_session.Link = .capacity_exhausted;
    const state = link.state() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(exhausted_code, state);
    try std.testing.expectEqualStrings(exhausted_code, publicErrorCode(error.DisklessSessionCapacity).?);
}
