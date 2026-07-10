//! NodeForge 运行态模型。
//! 运行态与 `config.json` 分离，不能反向成为部署配置事实源。
//! M0 运行态只存在于内存中；后续阶段增加 lease、会话和节点阶段后，
//! 可通过 `state/runtime.json` 持久化以支持重启恢复。

/// M0 运行态骨架；后续阶段在这里增加 lease、会话和节点阶段。
pub const RuntimeState = struct {
    /// 运行态格式版本；M0 仅接受版本 1。
    schema_version: u32 = 1,
    /// 守护进程当前生命周期阶段。
    service: ServiceState = .starting,
    /// 配置快照版本号；每次原子更新递增，用于判断是否需要重新加载。
    config_generation: u64 = 1,
};

/// 守护进程生命周期状态。
pub const ServiceState = enum {
    starting,
    running,
    stopping,
};

test "runtime defaults to starting" {
    const state: RuntimeState = .{};
    try @import("std").testing.expectEqual(ServiceState.starting, state.service);
}
