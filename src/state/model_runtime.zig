//! config/catalog 模型世代的原子 pinning 边界。
//!
//! ModelRuntime 把 `ConfigRuntime` 和 `CatalogRuntime` 组合成一个统一的
//! 读写门：`mutation_gate` 串行化所有变更（catalog mutation、ISO 导入、
//! 配置重载），`acquire` 在同一临界区内同时 pin config 和 catalog 快照，
//! 保证协议 worker 看到的总是一对匹配的世代——不会出现 config 已更新
//! 而 catalog 仍停留在旧 generation 的窗口。
//!
//! 典型用法：
//! ```zig
//! const pair = model_runtime.acquire();
//! defer pair.release();
//! // 此时 pair.config 和 pair.catalog 引用同一模型世代
//! ```

const std = @import("std");
const config_runtime = @import("config_runtime.zig");
const catalog_runtime = @import("catalog_runtime.zig");

/// 一对匹配的 config/catalog 快照引用。调用方必须 `release()` 释放两者。
/// 顺序固定：先 catalog 后 config，与 acquire 相反。
pub const Pair = struct {
    config: *const config_runtime.Snapshot,
    catalog: *const catalog_runtime.Snapshot,
    /// 释放此 pair 持有的两个引用。顺序与 acquire 相反，避免任何潜在的
    /// 析构顺序依赖。
    pub fn release(self: Pair) void {
        self.catalog.release();
        self.config.release();
    }
};

/// config/catalog 模型运行时门。`mutation_gate` 保护所有变更操作；
/// `acquire` 在同一临界区内 pin 两个 runtime 的当前快照。
pub const ModelRuntime = struct {
    configs: *config_runtime.ConfigRuntime,
    catalogs: *catalog_runtime.CatalogRuntime,
    mutation_gate: std.atomic.Mutex = .unlocked,

    /// 构造 ModelRuntime。调用方负责保证 `configs` 和 `catalogs` 的
    /// 生命周期长于本 runtime。
    pub fn init(configs: *config_runtime.ConfigRuntime, catalogs: *catalog_runtime.CatalogRuntime) ModelRuntime {
        return .{ .configs = configs, .catalogs = catalogs };
    }
    /// 获取 mutation_gate。变更操作（catalog mutation、ISO 导入等）必须
    /// 在持有此锁期间完成 config/catalog 的 prepare 和 publish。
    pub fn lock(self: *ModelRuntime) void {
        while (!self.mutation_gate.tryLock()) std.Thread.yield() catch {};
    }
    /// 释放 mutation_gate。
    pub fn unlock(self: *ModelRuntime) void {
        self.mutation_gate.unlock();
    }
    /// Pin 当前 config/catalog 世代对。返回的 `Pair` 持有两个引用计数 +1
    /// 的快照，调用方负责 `release()`。加锁顺序固定：
    /// model gate -> ConfigRuntime reader -> CatalogRuntime reader。
    pub fn acquire(self: *ModelRuntime) Pair {
        self.lock();
        defer self.unlock();
        // 固定顺序：model gate -> ConfigRuntime reader -> CatalogRuntime reader。
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
