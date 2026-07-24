//! v0.2 squashfs-overlay initrd memory gate。

const std = @import("std");

pub const Inputs = struct {
    available_budget: u64,
    rootfs_size: u64,
    node_payload_size: u64,
    tmpfs_percent: u8,
    minimum_free_bytes: u64,
    safety_margin_bytes: u64,
};

pub fn upperLimit(inputs: Inputs) !u64 {
    if (inputs.tmpfs_percent < 10 or inputs.tmpfs_percent > 80) return error.InvalidTmpfsPercent;
    const scaled = std.math.mul(u64, inputs.available_budget, inputs.tmpfs_percent) catch return error.MemoryBudgetOverflow;
    const upper = scaled / 100;
    if (inputs.minimum_free_bytes > upper) return error.MinimumFreeBudgetUnsatisfied;
    var required = std.math.add(u64, inputs.rootfs_size, inputs.node_payload_size) catch return error.MemoryBudgetOverflow;
    required = std.math.add(u64, required, upper) catch return error.MemoryBudgetOverflow;
    required = std.math.add(u64, required, inputs.safety_margin_bytes) catch return error.MemoryBudgetOverflow;
    if (required > inputs.available_budget) return error.InsufficientMemory;
    return upper;
}

pub fn memAvailableBytes(meminfo: []const u8) !u64 {
    var lines = std.mem.splitScalar(u8, meminfo, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemAvailable:")) continue;
        var fields = std.mem.tokenizeAny(u8, line["MemAvailable:".len..], " \t");
        const kib = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidMeminfo, 10);
        const unit = fields.next() orelse return error.InvalidMeminfo;
        if (!std.mem.eql(u8, unit, "kB")) return error.InvalidMeminfo;
        return std.math.mul(u64, kib, 1024) catch error.MemoryBudgetOverflow;
    }
    return error.MemAvailableMissing;
}

test "memory gate uses MemAvailable once and checked arithmetic" {
    const available = try memAvailableBytes("MemTotal: 4096 kB\nMemAvailable: 2048 kB\n");
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), available);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), try upperLimit(.{
        .available_budget = available,
        .rootfs_size = 256 * 1024,
        .node_payload_size = 0,
        .tmpfs_percent = 50,
        .minimum_free_bytes = 512 * 1024,
        .safety_margin_bytes = 128 * 1024,
    }));
}

test "memory gate rejects impossible and overflowing budgets" {
    try std.testing.expectError(error.InsufficientMemory, upperLimit(.{
        .available_budget = 1024,
        .rootfs_size = 600,
        .node_payload_size = 0,
        .tmpfs_percent = 50,
        .minimum_free_bytes = 1,
        .safety_margin_bytes = 1,
    }));
    try std.testing.expectError(error.MemoryBudgetOverflow, upperLimit(.{
        .available_budget = std.math.maxInt(u64),
        .rootfs_size = 0,
        .node_payload_size = 0,
        .tmpfs_percent = 80,
        .minimum_free_bytes = 1,
        .safety_margin_bytes = 1,
    }));
}
