//! Atomic pinning boundary for config/catalog model generations.
const std = @import("std");
const config_runtime = @import("config_runtime.zig");
const catalog_runtime = @import("catalog_runtime.zig");

pub const Pair = struct {
    config: *const config_runtime.Snapshot,
    catalog: *const catalog_runtime.Snapshot,
    pub fn release(self: Pair) void {
        self.catalog.release();
        self.config.release();
    }
};

pub const ModelRuntime = struct {
    configs: *config_runtime.ConfigRuntime,
    catalogs: *catalog_runtime.CatalogRuntime,
    mutation_gate: std.atomic.Mutex = .unlocked,

    pub fn init(configs: *config_runtime.ConfigRuntime, catalogs: *catalog_runtime.CatalogRuntime) ModelRuntime {
        return .{ .configs = configs, .catalogs = catalogs };
    }
    pub fn lock(self: *ModelRuntime) void { while (!self.mutation_gate.tryLock()) std.Thread.yield() catch {}; }
    pub fn unlock(self: *ModelRuntime) void { self.mutation_gate.unlock(); }
    pub fn acquire(self: *ModelRuntime) Pair {
        self.lock();
        defer self.unlock();
        // Fixed order: model gate -> ConfigRuntime reader -> CatalogRuntime reader.
        return .{ .config = self.configs.acquire(), .catalog = self.catalogs.acquire() };
    }
};

test "pair pins matching generations until both are released" {
    const model = @import("../model.zig");
    var configs = try config_runtime.ConfigRuntime.init(std.testing.allocator, &model.AppConfig{ .server = .{ .server_ip = "192.0.2.1" } }, 7);
    defer configs.deinit();
    var catalogs = try catalog_runtime.CatalogRuntime.init(std.testing.allocator, "/tmp/catalog", &.{});
    defer catalogs.deinit();
    var runtime = ModelRuntime.init(&configs, &catalogs);
    const pair = runtime.acquire();
    defer pair.release();
    try std.testing.expectEqual(@as(u64, 7), pair.config.revision);
    try std.testing.expectEqual(@as(u64, 1), pair.catalog.revision);
}
