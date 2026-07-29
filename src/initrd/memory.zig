//! v0.2 squashfs-overlay initrd memory gate。

const std = @import("std");

pub const Inputs = struct {
    available_budget: u64,
    /// squashfs 下载后驻留的压缩字节数。
    rootfs_size: u64,
    /// 已证明的逻辑展开字节数。unknown 不进入本函数：调用方应跳过硬闸，
    /// 而不是传 0、压缩大小或估算值伪造确定性。
    rootfs_uncompressed_size: u64,
    node_payload_size: u64,
    tmpfs_percent: u8,
    minimum_free_bytes: u64,
    safety_margin_bytes: u64,
};

/// 给定完整可信输入时，计算能通过 `upperLimit` 的保守最小 MemAvailable。
/// 服务端 readiness 用它展示 required minimum；initrd 仍以启动时实测
/// MemAvailable 调用 `upperLimit`。两端因此共享百分比、payload 与余量公式。
pub fn minimumAvailableBytes(inputs: Inputs) !u64 {
    if (inputs.tmpfs_percent < 10 or inputs.tmpfs_percent > 80) return error.InvalidTmpfsPercent;
    var fixed = std.math.add(u64, inputs.rootfs_size, inputs.rootfs_uncompressed_size) catch return error.MemoryBudgetOverflow;
    fixed = std.math.add(u64, fixed, inputs.node_payload_size) catch return error.MemoryBudgetOverflow;
    fixed = std.math.add(u64, fixed, inputs.safety_margin_bytes) catch return error.MemoryBudgetOverflow;
    const fixed_scaled = std.math.mul(u64, fixed, 100) catch return error.MemoryBudgetOverflow;
    const free_scaled = std.math.mul(u64, inputs.minimum_free_bytes, 100) catch return error.MemoryBudgetOverflow;
    var candidate = @max(try ceilDiv(fixed_scaled, 100 - inputs.tmpfs_percent), try ceilDiv(free_scaled, inputs.tmpfs_percent));
    // floor(available*p/100) 可能让闭式上界保守 1-4 字节；向下验证到真正边界，
    // 使 API 的 required_min_memory_bytes 与 initrd 判定精确一致。
    while (candidate > 0) {
        var previous = inputs;
        previous.available_budget = candidate - 1;
        _ = upperLimit(previous) catch break;
        candidate -= 1;
    }
    return candidate;
}

pub fn upperLimit(inputs: Inputs) !u64 {
    // 只有所有容量输入都可信时才执行 fail-closed。公式同时覆盖压缩副本、
    // 逻辑展开需求、Node payload、overlay upper 和安全余量。
    if (inputs.tmpfs_percent < 10 or inputs.tmpfs_percent > 80) return error.InvalidTmpfsPercent;
    const scaled = std.math.mul(u64, inputs.available_budget, inputs.tmpfs_percent) catch return error.MemoryBudgetOverflow;
    const upper = scaled / 100;
    if (inputs.minimum_free_bytes > upper) return error.MinimumFreeBudgetUnsatisfied;
    var required = std.math.add(u64, inputs.rootfs_size, inputs.rootfs_uncompressed_size) catch return error.MemoryBudgetOverflow;
    required = std.math.add(u64, required, inputs.node_payload_size) catch return error.MemoryBudgetOverflow;
    required = std.math.add(u64, required, upper) catch return error.MemoryBudgetOverflow;
    required = std.math.add(u64, required, inputs.safety_margin_bytes) catch return error.MemoryBudgetOverflow;
    if (required > inputs.available_budget) return error.InsufficientMemory;
    return upper;
}

fn ceilDiv(numerator: u64, denominator: u64) !u64 {
    if (denominator == 0) return error.InvalidTmpfsPercent;
    const quotient = numerator / denominator;
    return if (numerator % denominator == 0) quotient else std.math.add(u64, quotient, 1) catch error.MemoryBudgetOverflow;
}

pub fn memTotalBytes(meminfo: []const u8) !u64 {
    return meminfoValueBytes(meminfo, "MemTotal:");
}

pub fn memAvailableBytes(meminfo: []const u8) !u64 {
    return meminfoValueBytes(meminfo, "MemAvailable:");
}

fn meminfoValueBytes(meminfo: []const u8, name: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, meminfo, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, name)) continue;
        var fields = std.mem.tokenizeAny(u8, line[name.len..], " \t");
        const kib = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidMeminfo, 10);
        const unit = fields.next() orelse return error.InvalidMeminfo;
        if (!std.mem.eql(u8, unit, "kB")) return error.InvalidMeminfo;
        return std.math.mul(u64, kib, 1024) catch error.MemoryBudgetOverflow;
    }
    return error.MemoryFactMissing;
}

test "memory gate uses MemAvailable once and checked arithmetic" {
    const available = try memAvailableBytes("MemTotal: 4096 kB\nMemAvailable: 2048 kB\n");
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), available);
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024), try memTotalBytes("MemTotal: 4096 kB\nMemAvailable: 2048 kB\n"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024), try upperLimit(.{
        .available_budget = available,
        .rootfs_size = 256 * 1024,
        .rootfs_uncompressed_size = 256 * 1024,
        .node_payload_size = 0,
        .tmpfs_percent = 50,
        .minimum_free_bytes = 512 * 1024,
        .safety_margin_bytes = 128 * 1024,
    }));
}

test "readiness minimum and initrd gate use one formula" {
    const inputs: Inputs = .{
        .available_budget = 0,
        .rootfs_size = 100,
        .rootfs_uncompressed_size = 200,
        .node_payload_size = 50,
        .tmpfs_percent = 50,
        .minimum_free_bytes = 80,
        .safety_margin_bytes = 50,
    };
    const minimum = try minimumAvailableBytes(inputs);
    try std.testing.expectEqual(@as(u64, 799), minimum);
    var at_minimum = inputs;
    at_minimum.available_budget = minimum;
    try std.testing.expectEqual(@as(u64, 399), try upperLimit(at_minimum));
    var below = inputs;
    below.available_budget = minimum - 1;
    try std.testing.expectError(error.InsufficientMemory, upperLimit(below));
}

test "memory gate rejects impossible and overflowing budgets" {
    try std.testing.expectError(error.InsufficientMemory, upperLimit(.{
        .available_budget = 1024,
        .rootfs_size = 600,
        .rootfs_uncompressed_size = 100,
        .node_payload_size = 0,
        .tmpfs_percent = 50,
        .minimum_free_bytes = 1,
        .safety_margin_bytes = 1,
    }));
    try std.testing.expectError(error.MemoryBudgetOverflow, upperLimit(.{
        .available_budget = std.math.maxInt(u64),
        .rootfs_size = 0,
        .rootfs_uncompressed_size = 0,
        .node_payload_size = 0,
        .tmpfs_percent = 80,
        .minimum_free_bytes = 1,
        .safety_margin_bytes = 1,
    }));
}
