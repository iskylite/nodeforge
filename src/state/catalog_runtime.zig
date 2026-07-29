//! 引用计数、不可变的 catalog 世代，由 daemon 拥有。
//!
//! CatalogRuntime 维护一个原子指针指向当前 `Snapshot`；协议 worker 通过
//! `acquire` 拿到一个引用计数 +1 的快照，期间即使 daemon 通过 `publish`
//! 替换了 `current`，旧快照仍保持存活直到最后一个 reader 调用 `release`。
//! 这种 RCU 风格的发布/订阅使协议热路径无锁读取 catalog。
//!
//! 写入路径由 `writer` mutex 串行化，与 ConfigRuntime 的 mutex 配合构成
//! `ModelRuntime.mutation_gate`——保证 config/catalog 的原子对发布。

const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const validate = @import("../config/validate.zig");
const profile_mutation = @import("../config/profile_mutation.zig");
const iso_import = @import("../catalog/iso_import.zig");
const config_runtime = @import("config_runtime.zig");

/// 不可变的 catalog 快照。`parsed` 持有堆分配的 JSON 解码结果；`refs`
/// 是原子引用计数，降到 0 时释放 parsed 和 snapshot 本身。
/// 调用方通过 `value()` 读取 catalog 内容，通过 `release()` 释放引用。
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(model.Catalog),
    /// 此快照的 catalog revision；与 `model.Catalog.revision` 相同。
    revision: u64,
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    /// 返回此快照包含的只读 catalog 指针。指针在 `release()` 前一直有效。
    pub fn value(self: *const Snapshot) *const model.Catalog {
        return &self.parsed.value;
    }
    /// 释放一个引用。引用计数降到 0 时释放 JSON 解析缓冲区和 snapshot 自身。
    pub fn release(self: *const Snapshot) void {
        const mutable: *Snapshot = @constCast(self);
        if (mutable.refs.fetchSub(1, .acq_rel) != 1) return;
        mutable.parsed.deinit();
        const allocator = mutable.allocator;
        allocator.destroy(mutable);
    }
};

/// 未知客户端观测的持久化节流器。
///
/// 背景（P0）：`recordUnknownClient` 每次调用都会执行一次**全量 catalog
/// 序列化 + 落盘**（10 个 entity 文件 + manifest），且该调用位于 DHCP 报文
/// 处理热路径上，全程持 `ModelRuntime` 的全局 mutation gate。默认策略即
/// `unknown_action = .record`，因此任何人向 UDP/67 发送合法 DISCOVER、
/// 每包更换随机 `chaddr`，即可做到「一包一次全量写盘」，同时阻塞 TFTP 与
/// 管理 API。观测数组过去也没有条数上限，catalog 随包数单调膨胀，使每包的
/// 序列化成本本身持续增长（二次放大），最终磁盘耗尽、PXE 全面不可用。
///
/// 修复分两层，本结构负责第一层：
///
/// 1. **节流**：同一 MAC 在 `throttle_seconds` 窗口内只落盘一次。窗口内的
///    重复观测仍然更新内存快照（`request_count` 等对操作员可见），但不再触发
///    写盘。一次正常 PXE 启动会产生 4-8 个 DHCP 包，节流后只写一次。
/// 2. **硬上限**：见 `max_observations`。
///
/// 与 `runtime_state.BootGateSuppressor` 采用同一套「固定槽位 + 热路径去重」
/// 模式：不分配、不增长，槽位满时按最旧条目轮转，因此节流器自身不会成为新的
/// 无界增长点。
const ObservationThrottle = struct {
    /// 跟踪的 MAC 槽位数。PXE 子网内同时首次出现的未知客户端数量远小于此值；
    /// 洪泛场景下轮转即可，不需要精确。
    pub const max_tracked = 128;
    /// 同一 MAC 的两次落盘之间的最小间隔（秒）。
    pub const throttle_seconds: i64 = 60;

    const Entry = struct {
        /// `aa:bb:cc:dd:ee:ff` 定长 17 字节；0 长度表示空槽。
        mac: [17]u8 = [_]u8{0} ** 17,
        mac_len: u8 = 0,
        /// 该 MAC 最近一次**落盘**的时间戳（秒）。
        last_persist_unix: i64 = 0,

        fn matches(self: *const Entry, mac: []const u8) bool {
            return self.mac_len != 0 and self.mac_len == mac.len and
                std.ascii.eqlIgnoreCase(self.mac[0..self.mac_len], mac);
        }
    };

    entries: [max_tracked]Entry = [_]Entry{.{}} ** max_tracked,

    /// 判断本次观测是否需要落盘，并在需要时记录落盘时间。
    ///
    /// 返回 true 表示调用方应执行持久化；false 表示窗口内已落盘过，
    /// 只更新内存即可。
    fn shouldPersist(self: *ObservationThrottle, mac: []const u8, now: i64) bool {
        if (mac.len > 17) return true;
        var free: ?*Entry = null;
        var oldest: *Entry = &self.entries[0];
        for (&self.entries) |*entry| {
            if (entry.matches(mac)) {
                // 已知 MAC：仅当超出节流窗口才再次落盘。
                if (now >= entry.last_persist_unix and now - entry.last_persist_unix < throttle_seconds)
                    return false;
                entry.last_persist_unix = now;
                return true;
            }
            if (entry.mac_len == 0) {
                if (free == null) free = entry;
            } else if (entry.last_persist_unix < oldest.last_persist_unix) {
                oldest = entry;
            }
        }
        // 新 MAC：占用空槽，槽位耗尽时替换最旧条目。
        const slot = free orelse oldest;
        @memcpy(slot.mac[0..mac.len], mac);
        slot.mac_len = @intCast(mac.len);
        slot.last_persist_unix = now;
        return true;
    }
};

/// Catalog 世代运行时。`current` 是指向当前快照的原子指针；`writer`
/// 串行化所有发布操作。`path` 是持久化 catalog 目录路径。
pub const CatalogRuntime = struct {
    /// 未知客户端观测的条数硬上限（第二层防御，见 `ObservationThrottle`）。
    ///
    /// 达到上限后，新的未知 MAC 会挤出「最旧且未被 claim」的观测；已被 claim
    /// （已关联节点）的观测永不淘汰，因为它们是操作员的工作数据。这保证
    /// catalog 体积有界，从而消除「写盘成本随攻击包数增长」的二次放大。
    pub const max_observations = 4096;

    allocator: std.mem.Allocator,
    path: []const u8,
    current: std.atomic.Value(*Snapshot),
    writer: std.atomic.Mutex = .unlocked,
    /// 未知客户端观测的落盘节流状态。由 `writer` mutex 保护。
    observation_throttle: ObservationThrottle = .{},

    /// 初始化 runtime，生成第一个 snapshot 并以 `initial.revision`（为 0 时取 1）发布。
    pub fn init(allocator: std.mem.Allocator, path: []const u8, initial: *const model.Catalog) !CatalogRuntime {
        const snapshot = try createSnapshot(allocator, initial.*, if (initial.revision == 0) 1 else initial.revision);
        return .{ .allocator = allocator, .path = path, .current = std.atomic.Value(*Snapshot).init(snapshot) };
    }
    /// 释放 runtime 持有的当前快照引用。仅在 daemon 关闭时调用。
    pub fn deinit(self: *CatalogRuntime) void {
        self.current.load(.acquire).release();
    }
    /// 获取 writer mutex。与 `unlock` 配对用于显式事务中。
    pub fn lock(self: *CatalogRuntime) void {
        lockMutex(&self.writer);
    }
    /// 释放 writer mutex。
    pub fn unlock(self: *CatalogRuntime) void {
        self.writer.unlock();
    }
    /// 获取一个引用计数 +1 的当前快照。调用方负责 `release()`。
    /// 加锁是为了避免与 `publishPreparedLocked` 的 swap 竞态。
    pub fn acquire(self: *CatalogRuntime) *const Snapshot {
        self.lock();
        defer self.unlock();
        return self.acquireLocked();
    }
    /// 在已持有 writer mutex 的情况下获取快照。用于嵌套事务中避免重复加锁。
    pub fn acquireLocked(self: *CatalogRuntime) *const Snapshot {
        const snapshot = self.current.load(.acquire);
        _ = snapshot.refs.fetchAdd(1, .monotonic);
        return snapshot;
    }
    /// 返回当前 catalog revision（获取并立即释放一个快照）。
    pub fn currentRevision(self: *CatalogRuntime) u64 {
        const snapshot = self.acquire();
        defer snapshot.release();
        return snapshot.revision;
    }

    /// 记录一个未知客户端的 DHCP 观察。调用方必须已持有
    /// `ModelRuntime.mutation_gate`，确保 config/catalog 读者看到一致的对。
    ///
    /// 观察按 MAC 去重，命中已存在条目时更新 `last_seen_unix`、
    /// `last_ip`、`request_count`、`revision` 及任何新观察到的字段。
    /// 已被 claim（关联节点）的观察永久保留；未 claim 且超过
    /// `observation_retention_days` 的观察在本次写入中被淘汰。
    pub fn recordUnknownClient(self: *CatalogRuntime, io: std.Io, mac: []const u8, client_id: ?[]const u8, arch: ?model.Arch, vendor_class: ?[]const u8, ip: ?[]const u8, seen_at: i64) !void {
        self.lock();
        defer self.unlock();
        // 热路径节流：同一 MAC 在窗口内只落盘一次（见 ObservationThrottle）。
        // 窗口内的重复包直接返回，不做序列化、不写盘、不推进 revision。
        if (!self.observation_throttle.shouldPersist(mac, seen_at)) return;
        const old = self.acquireLocked();
        defer old.release();
        const source = old.value().unknown_client_observations;
        const retention_seconds = @as(i64, old.value().discovery_policy.observation_retention_days) * 86400;

        // 判定某条观测是否已过保留期（已 claim 的审计记录永不过期）。
        const expiredAt = struct {
            fn f(item: model.UnknownClientObservation, now: i64, retention: i64) bool {
                return item.claim == null and now > item.last_seen_unix and now - item.last_seen_unix > retention;
            }
        }.f;

        var retained: usize = 0;
        var found = false;
        for (source) |item| {
            if (expiredAt(item, seen_at, retention_seconds)) continue;
            retained += 1;
            if (std.ascii.eqlIgnoreCase(item.mac, mac)) found = true;
        }

        // 硬上限：新 MAC 会使条数超过 max_observations 时，挤出最旧且未被
        // claim 的观测，保证 catalog 体积有界（消除二次放大）。
        // `evict_mac` 为待淘汰条目的主键，null 表示无需淘汰。
        var evict_mac: ?[]const u8 = null;
        if (!found and retained >= max_observations) {
            var oldest: ?model.UnknownClientObservation = null;
            for (source) |item| {
                if (item.claim != null) continue;
                if (expiredAt(item, seen_at, retention_seconds)) continue;
                if (oldest == null or item.last_seen_unix < oldest.?.last_seen_unix) oldest = item;
            }
            // 所有观测都已被 claim 时无可淘汰者，放弃本次记录而不是无界增长。
            const victim = oldest orelse return;
            evict_mac = victim.mac;
            retained -= 1;
        }

        const observations = try self.allocator.alloc(model.UnknownClientObservation, retained + @as(usize, if (found) 0 else 1));
        defer self.allocator.free(observations);
        var index: usize = 0;
        for (source) |item| {
            if (expiredAt(item, seen_at, retention_seconds)) continue;
            if (evict_mac) |victim| if (std.ascii.eqlIgnoreCase(item.mac, victim)) continue;
            observations[index] = item;
            if (std.ascii.eqlIgnoreCase(item.mac, mac)) {
                observations[index].last_seen_unix = seen_at;
                observations[index].last_ip = ip;
                observations[index].request_count +|= 1;
                observations[index].revision += 1;
                if (client_id != null) observations[index].dhcp_client_id = client_id;
                if (arch != null) observations[index].observed_architecture = arch;
                if (vendor_class != null) observations[index].vendor_class = vendor_class;
            }
            index += 1;
        }
        if (!found) observations[index] = .{
            .mac = mac,
            .dhcp_client_id = client_id,
            .observed_architecture = arch,
            .vendor_class = vendor_class,
            .first_seen_unix = seen_at,
            .last_seen_unix = seen_at,
            .last_ip = ip,
        };
        var candidate = old.value().*;
        candidate.revision = old.revision + 1;
        candidate.unknown_client_observations = observations;
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        try self.publishLocked(candidate, old.revision + 1);
    }
    /// 检查当前 catalog 中是否存在指定的 asset path。
    /// 用于判断 asset 文件是否需要一起回滚。
    pub fn containsAssetPath(self: *CatalogRuntime, path: []const u8) bool {
        const snapshot = self.acquire();
        defer snapshot.release();
        for (snapshot.value().assets) |asset| if (std.mem.eql(u8, asset.path, path)) return true;
        return false;
    }

    /// 添加一个新的 asset 到 catalog。name 必须唯一，否则返回 `DuplicateObjectName`。
    /// 校验通过后写入磁盘并发布新 revision。调用方必须持有 mutation_gate。
    pub fn addAsset(self: *CatalogRuntime, io: std.Io, config: *const model.AppConfig, asset: model.AssetConfig) !void {
        self.lock();
        defer self.unlock();
        const old = self.acquireLocked();
        defer old.release();
        for (old.value().assets) |existing| if (std.mem.eql(u8, existing.name, asset.name)) return error.DuplicateObjectName;
        const next_assets = try self.allocator.alloc(model.AssetConfig, old.value().assets.len + 1);
        defer self.allocator.free(next_assets);
        @memcpy(next_assets[0..old.value().assets.len], old.value().assets);
        next_assets[old.value().assets.len] = asset;
        var candidate = old.value().*;
        candidate.revision = old.revision + 1;
        candidate.assets = next_assets;
        try validate.validate(config, &candidate);
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        try self.publishLocked(candidate, old.revision + 1);
    }

    /// 发布或更新一个 `managed_file` asset。如果 name 已存在，必须仍是
    /// `managed_file` 类型且 `asset.revision` 恰好为 `existing.revision + 1`；
    /// 否则返回 `AssetRevisionConflict`。新 asset 的 `revision` 必须为 1。
    pub fn publishManagedFile(self: *CatalogRuntime, io: std.Io, config: *const model.AppConfig, asset: model.AssetConfig) !void {
        return self.publishContentAsset(io, config, asset);
    }

    /// 发布 managed_file/archive/script 的 immutable revision。
    pub fn publishContentAsset(self: *CatalogRuntime, io: std.Io, config: *const model.AppConfig, asset: model.AssetConfig) !void {
        if (asset.kind != .managed_file and asset.kind != .archive and asset.kind != .script)
            return error.AssetKindMismatch;
        self.lock();
        defer self.unlock();
        const old = self.acquireLocked();
        defer old.release();
        var found: ?usize = null;
        for (old.value().assets, 0..) |existing, index| if (std.mem.eql(u8, existing.name, asset.name)) {
            if (existing.kind != asset.kind or asset.revision != existing.revision + 1) return error.AssetRevisionConflict;
            found = index;
        };
        if (found == null and asset.revision != 1) return error.AssetRevisionConflict;
        const next_len = old.value().assets.len + @as(usize, if (found == null) 1 else 0);
        const next_assets = try self.allocator.alloc(model.AssetConfig, next_len);
        defer self.allocator.free(next_assets);
        @memcpy(next_assets[0..old.value().assets.len], old.value().assets);
        if (found) |index| next_assets[index] = asset else next_assets[old.value().assets.len] = asset;
        var candidate = old.value().*;
        candidate.revision = old.revision + 1;
        candidate.assets = next_assets;
        try validate.validate(config, &candidate);
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        try self.publishLocked(candidate, old.revision + 1);
    }

    /// 删除一个 `managed_file` asset。若该 asset 仍被任何 provisioning bundle
    /// 步骤引用则返回 `AssetInUse`；name 不存在返回 `AssetNotFound`；
    /// 类型不是 `managed_file` 返回 `AssetKindMismatch`。
    pub fn removeManagedFile(self: *CatalogRuntime, io: std.Io, config: *const model.AppConfig, name: []const u8) !void {
        self.lock();
        defer self.unlock();
        const old = self.acquireLocked();
        defer old.release();
        var found: ?usize = null;
        for (old.value().assets, 0..) |asset, index| if (std.mem.eql(u8, asset.name, name)) {
            if (asset.kind != .managed_file) return error.AssetKindMismatch;
            found = index;
        };
        const index = found orelse return error.AssetNotFound;
        for (old.value().provisioning_bundles) |bundle| for (bundle.steps) |step| if (step.content_asset != null and std.mem.eql(u8, step.content_asset.?, name)) return error.AssetInUse;
        const next_assets = try self.allocator.alloc(model.AssetConfig, old.value().assets.len - 1);
        defer self.allocator.free(next_assets);
        @memcpy(next_assets[0..index], old.value().assets[0..index]);
        @memcpy(next_assets[index..], old.value().assets[index + 1 ..]);
        var candidate = old.value().*;
        candidate.revision = old.revision + 1;
        candidate.assets = next_assets;
        try validate.validate(config, &candidate);
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        try self.publishLocked(candidate, old.revision + 1);
    }

    /// 将一次 ISO 导入结果作为完整 install source 发布到 catalog。
    ///
    /// 这是 M4.10 fresh-deployment 的主路径：一个 ISO 同时创建 distro/
    /// version/arch tuple、iso/kernel/initrd asset、可选 bootloader、可选
    /// repository、install source 以及同名默认 install profile。所有写入
    /// 在单一 manifest-last 事务中完成，使读者要么看到全部新增内容，
    /// 要么看到全部旧内容，不会出现中间态。
    ///
    /// `configs` 用于在同一临界区内准备 config 投影，保证 catalog 与 config
    /// 一起发布。校验失败、name/path 冲突、family 不匹配等均返回相应错误。
    pub fn publishInstallSource(
        self: *CatalogRuntime,
        io: std.Io,
        configs: *config_runtime.ConfigRuntime,
        config: *const model.AppConfig,
        config_revision: u64,
        imported: iso_import.Result,
    ) !void {
        self.lock();
        defer self.unlock();
        const old = self.acquireLocked();
        defer old.release();
        const value = old.value();
        // distro 是 ISO 导入的派生索引，不是导入前置配置。首次导入创建产品/
        // 版本/架构 tuple；后续导入只扩展缺少的版本或架构。family 冲突 fail closed。
        var distro_expansion = try expandDistroTuple(self.allocator, value, imported);
        defer distro_expansion.deinit(self.allocator);
        const required_additions = [_]model.AssetConfig{ imported.iso_asset, imported.kernel_asset, imported.initrd_asset };
        for (required_additions) |asset| for (value.assets) |existing| if (std.mem.eql(u8, existing.name, asset.name)) return error.DuplicateObjectName;
        var bootloader_addition: ?model.AssetConfig = imported.bootloader_asset;
        if (bootloader_addition) |bootloader| {
            for (value.assets) |existing| {
                if (!std.mem.eql(u8, existing.path, bootloader.path)) continue;
                if (existing.kind != .bootloader) return error.AssetPathConflict;
                bootloader_addition = null;
                break;
            }
            if (bootloader_addition != null)
                for (value.assets) |existing|
                    if (std.mem.eql(u8, existing.name, bootloader.name)) return error.DuplicateObjectName;
        }
        // 多 variant ISO 的 Result.repositories 可能包含多个 RepositoryConfig
        // （如 Rocky DVD 的 AppStream + BaseOS）。每个 repository 名必须唯一；
        // 同名异内容返回 DuplicateObjectName，绝不覆盖。
        for (imported.repositories) |repository| for (value.repositories) |existing| if (std.mem.eql(u8, existing.name, repository.name)) return error.DuplicateObjectName;
        for (value.install_sources) |existing| if (std.mem.eql(u8, existing.name, imported.install_source.name)) return error.DuplicateObjectName;
        for (value.profiles) |existing| if (std.mem.eql(u8, existing.name, imported.install_source.name)) return error.DuplicateObjectName;
        const addition_count = required_additions.len + @as(usize, if (bootloader_addition != null) 1 else 0);
        const assets = try self.allocator.alloc(model.AssetConfig, value.assets.len + addition_count);
        defer self.allocator.free(assets);
        @memcpy(assets[0..value.assets.len], value.assets);
        @memcpy(assets[value.assets.len .. value.assets.len + required_additions.len], &required_additions);
        if (bootloader_addition) |bootloader|
            assets[value.assets.len + required_additions.len] = bootloader;
        // 批量追加所有 repository（可能为 0 个、1 个或多个）。
        // 多 variant ISO 的每个 variant 对应一个独立的 RepositoryConfig，
        // 但它们共享同一个 source_name 目录的文件。
        const repo_count = imported.repositories.len;
        const repositories = try self.allocator.alloc(model.RepositoryConfig, value.repositories.len + repo_count);
        defer self.allocator.free(repositories);
        @memcpy(repositories[0..value.repositories.len], value.repositories);
        @memcpy(repositories[value.repositories.len .. value.repositories.len + repo_count], imported.repositories);
        const sources = try self.allocator.alloc(model.InstallSourceConfig, value.install_sources.len + 1);
        defer self.allocator.free(sources);
        @memcpy(sources[0..value.install_sources.len], value.install_sources);
        sources[value.install_sources.len] = imported.install_source;
        // M4.10 fresh-deployment 主路径：ISO publication 已拥有完整 tuple，
        // 因而在同一 manifest-last transaction 中创建同名默认 install
        // profile。显式 `profile create` 只用于从该 source 补充其他 profile。
        const profiles = try self.allocator.alloc(model.ProfileConfig, value.profiles.len + 1);
        defer self.allocator.free(profiles);
        @memcpy(profiles[0..value.profiles.len], value.profiles);
        const host_hosts = profile_mutation.readHostHosts(io, self.allocator) catch null;
        defer if (host_hosts) |content| self.allocator.free(content);
        var default_system: model.TargetSystemConfig = .{};
        default_system.hosts_content = host_hosts;
        profiles[value.profiles.len] = .{
            .name = imported.install_source.name,
            .install_source = imported.install_source.name,
            .system = default_system,
        };
        var candidate = value.*;
        candidate.revision = old.revision + 1;
        candidate.distros = distro_expansion.values;
        candidate.assets = assets;
        candidate.repositories = repositories;
        candidate.install_sources = sources;
        candidate.profiles = profiles;
        try validate.validateModel(config, &candidate);
        // 在持久提交前准备 catalog 与兼容 AppConfig 投影，保证 model gate
        // 释放后读者只会看到完整的新 pair，不会出现 catalog 已有 distro、
        // config 投影仍停留在旧 generation 的窗口。
        const effective = model.projectCatalog(config.*, &candidate);
        const config_next = try configs.prepare(effective, config_revision);
        errdefer config_next.release();
        const catalog_next = try self.prepare(candidate, old.revision + 1);
        errdefer catalog_next.release();
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        configs.publishPrepared(config_next);
        self.publishPreparedLocked(catalog_next);
    }

    /// 在已持有 writer mutex 的情况下发布一个新 catalog 世代。
    /// 调用方负责保证 `candidate` 已通过校验、已持久化到磁盘。
    /// 内部调用 `prepare` 创建 snapshot，再 `publishPreparedLocked` 原子替换。
    pub fn publishLocked(self: *CatalogRuntime, candidate: model.Catalog, revision: u64) !void {
        const next = try self.prepare(candidate, revision);
        self.publishPreparedLocked(next);
    }
    /// 创建一个未发布的 snapshot。用于在持久化前预先准备世代，
    /// 再通过 `publishPreparedLocked` 原子提交，缩短临界区。
    pub fn prepare(self: *CatalogRuntime, candidate: model.Catalog, revision: u64) !*Snapshot {
        return createSnapshot(self.allocator, candidate, revision);
    }
    /// 原子替换 `current` 并释放旧 snapshot 的 runtime 引用。
    /// 调用方必须已持有 writer mutex。仍在使用旧 snapshot 的 reader
    /// 不会受影响——它们的引用计数保证旧 snapshot 存活到 release。
    pub fn publishPreparedLocked(self: *CatalogRuntime, next: *Snapshot) void {
        const previous = self.current.swap(next, .acq_rel);
        previous.release();
    }
};

/// ISO 导入后 distro/version/arch tuple 的扩展结果。`values` 是最终用于
/// 写入 catalog 的 distros 切片；其它字段记录中间分配的切片，用于 `deinit`。
const DistroExpansion = struct {
    values: []const model.DistroConfig,
    distros: ?[]model.DistroConfig = null,
    versions: ?[]model.DistroVersionConfig = null,
    archs: ?[]model.Arch = null,

    /// 释放所有中间分配。`values` 不被释放——它指向 `distros` 或 catalog
    /// 原有切片，由调用方在持久化后决定生命周期。
    fn deinit(self: *DistroExpansion, allocator: std.mem.Allocator) void {
        if (self.archs) |items| allocator.free(items);
        if (self.versions) |items| allocator.free(items);
        if (self.distros) |items| allocator.free(items);
    }
};

/// 把 ISO 已验证出的 tuple 合并进 catalog distro 索引。
///
/// adapter/package manager 由 family 唯一派生；操作员既无需也不能在 ISO
/// 导入命令中选择它们。此函数只准备候选切片，真正持久化仍由 manifest-last
/// catalog 事务与 install source/assets/repository 一起完成。
fn expandDistroTuple(allocator: std.mem.Allocator, catalog: *const model.Catalog, imported: iso_import.Result) !DistroExpansion {
    const distro_name = imported.install_source.distro;
    const version_name = imported.install_source.version;
    const arch = imported.install_source.arch;

    for (catalog.distros, 0..) |distro, distro_index| {
        if (!std.mem.eql(u8, distro.name, distro_name)) continue;
        if (distro.family != imported.family) return error.DistroFamilyMismatch;
        for (distro.versions, 0..) |version, version_index| {
            if (!std.mem.eql(u8, version.version, version_name)) continue;
            for (version.archs) |existing_arch| if (existing_arch == arch)
                return .{ .values = catalog.distros };

            const archs = try allocator.alloc(model.Arch, version.archs.len + 1);
            errdefer allocator.free(archs);
            @memcpy(archs[0..version.archs.len], version.archs);
            archs[version.archs.len] = arch;
            const versions = try allocator.alloc(model.DistroVersionConfig, distro.versions.len);
            errdefer allocator.free(versions);
            @memcpy(versions, distro.versions);
            versions[version_index].archs = archs;
            const distros = try allocator.alloc(model.DistroConfig, catalog.distros.len);
            errdefer allocator.free(distros);
            @memcpy(distros, catalog.distros);
            distros[distro_index].versions = versions;
            return .{ .values = distros, .distros = distros, .versions = versions, .archs = archs };
        }

        const archs = try allocator.alloc(model.Arch, 1);
        errdefer allocator.free(archs);
        archs[0] = arch;
        const versions = try allocator.alloc(model.DistroVersionConfig, distro.versions.len + 1);
        errdefer allocator.free(versions);
        @memcpy(versions[0..distro.versions.len], distro.versions);
        versions[distro.versions.len] = .{
            .version = version_name,
            .archs = archs,
            .install_adapter = model.installAdapterForFamily(imported.family),
            .package_manager = model.packageManagerForFamily(imported.family),
        };
        const distros = try allocator.alloc(model.DistroConfig, catalog.distros.len);
        errdefer allocator.free(distros);
        @memcpy(distros, catalog.distros);
        distros[distro_index].versions = versions;
        return .{ .values = distros, .distros = distros, .versions = versions, .archs = archs };
    }

    const archs = try allocator.alloc(model.Arch, 1);
    errdefer allocator.free(archs);
    archs[0] = arch;
    const versions = try allocator.alloc(model.DistroVersionConfig, 1);
    errdefer allocator.free(versions);
    versions[0] = .{
        .version = version_name,
        .archs = archs,
        .install_adapter = model.installAdapterForFamily(imported.family),
        .package_manager = model.packageManagerForFamily(imported.family),
    };
    const distros = try allocator.alloc(model.DistroConfig, catalog.distros.len + 1);
    errdefer allocator.free(distros);
    @memcpy(distros[0..catalog.distros.len], catalog.distros);
    distros[catalog.distros.len] = .{ .name = distro_name, .family = imported.family, .versions = versions };
    return .{ .values = distros, .distros = distros, .versions = versions, .archs = archs };
}

/// 创建一个独立的 snapshot：先序列化 `value` 为 JSON，再解析回来，
/// 使 snapshot 完全拥有其堆分配且不与任何外部切片共享。`revision`
/// 直接写入 snapshot；调用方负责保证其单调性。
fn createSnapshot(allocator: std.mem.Allocator, value: model.Catalog, revision: u64) !*Snapshot {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(model.Catalog, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const snapshot = try allocator.create(Snapshot);
    snapshot.* = .{ .allocator = allocator, .parsed = parsed, .revision = revision };
    return snapshot;
}
/// 自旋获取 mutex，通过 `Thread.yield` 让出 CPU 而非忙等。
/// catalog 发布操作时间短，自旋比 futex 更高效。
fn lockMutex(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}

test "old catalog generation survives replacement until reader release" {
    var runtime = try CatalogRuntime.init(std.testing.allocator, "/tmp/catalog.json", &.{});
    defer runtime.deinit();
    const old = runtime.acquire();
    runtime.lock();
    try runtime.publishLocked(.{ .assets = &.{.{ .name = "new", .kind = .iso, .path = "new.iso" }} }, 2);
    runtime.unlock();
    try std.testing.expectEqual(@as(usize, 0), old.value().assets.len);
    old.release();
    const current = runtime.acquire();
    defer current.release();
    try std.testing.expectEqual(@as(u64, 2), current.revision);
    try std.testing.expectEqualStrings("new", current.value().assets[0].name);
}

test "persistent observations update revisions and retain claimed audit past retention" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try temp.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];
    try catalog_store.initializeEmpty(std.testing.io, std.testing.allocator, path);
    const initial: model.Catalog = .{
        .discovery_policy = .{ .observation_retention_days = 1 },
        .unknown_client_observations = &.{
            .{ .mac = "02:00:00:00:00:01", .first_seen_unix = 1, .last_seen_unix = 1 },
            .{ .mac = "02:00:00:00:00:02", .first_seen_unix = 1, .last_seen_unix = 1, .claim = .{ .node_id = "audit-node", .claimed_at_unix = 2 } },
        },
    };
    var runtime = try CatalogRuntime.init(std.testing.allocator, path, &initial);
    defer runtime.deinit();
    // 两次观测的时间戳必须跨过落盘节流窗口，否则第二次按设计被抑制
    // （见 ObservationThrottle）。这里验证的是跨窗口时的累加语义。
    try runtime.recordUnknownClient(std.testing.io, "02:00:00:00:00:03", "0102", .x86_64, "PXEClient", "192.0.2.10", 200000);
    try runtime.recordUnknownClient(std.testing.io, "02:00:00:00:00:03", null, .x86_64, null, "192.0.2.11", 200000 + ObservationThrottle.throttle_seconds);
    const snapshot = runtime.acquire();
    defer snapshot.release();
    try std.testing.expectEqual(@as(usize, 2), snapshot.value().unknown_client_observations.len);
    try std.testing.expect(snapshot.value().unknown_client_observations[0].claim != null);
    try std.testing.expectEqual(@as(u64, 2), snapshot.value().unknown_client_observations[1].request_count);
    try std.testing.expectEqual(@as(u64, 2), snapshot.value().unknown_client_observations[1].revision);
    try std.testing.expectEqualStrings("192.0.2.11", snapshot.value().unknown_client_observations[1].last_ip.?);
}

// 回归（P0）：未知客户端观测不得让 DHCP 报文热路径做全量 catalog 落盘。
//
// `recordUnknownClient` 会执行「全量 JSON 序列化 + 落盘 + 重新解析快照」
// （createSnapshot 自身也序列化+反序列化），且调用点在 DHCP 报文处理路径上
// 并持全局 model gate。默认策略即 record，因此每包更换随机 chaddr 即可做到
// 一包一次全量写盘，同时阻塞 TFTP 与管理 API。
//
// 本测试断言同一 MAC 在节流窗口内的重复观测不推进 catalog revision
// （即未发生序列化与落盘）。
test "repeated observations from one MAC do not persist within the throttle window" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try temp.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];
    try catalog_store.initializeEmpty(std.testing.io, std.testing.allocator, path);
    var runtime = try CatalogRuntime.init(std.testing.allocator, path, &.{});
    defer runtime.deinit();

    const base_revision = runtime.currentRevision();
    // 一次正常 PXE 启动产生 4-8 个 DHCP 包；节流后只应落盘一次。
    var packet_index: usize = 0;
    while (packet_index < 8) : (packet_index += 1) {
        try runtime.recordUnknownClient(std.testing.io, "02:00:00:00:00:aa", null, .aarch64, null, "192.0.2.50", 500000 + @as(i64, @intCast(packet_index)));
    }
    try std.testing.expectEqual(base_revision + 1, runtime.currentRevision());

    // 跨过窗口后允许再次落盘，保证观测事实最终仍会更新。
    try runtime.recordUnknownClient(std.testing.io, "02:00:00:00:00:aa", null, .aarch64, null, "192.0.2.50", 500000 + ObservationThrottle.throttle_seconds);
    try std.testing.expectEqual(base_revision + 2, runtime.currentRevision());

    const snapshot = runtime.acquire();
    defer snapshot.release();
    try std.testing.expectEqual(@as(usize, 1), snapshot.value().unknown_client_observations.len);
}

// 回归（P0）：观测条数必须有硬上限，否则 catalog 体积随攻击包数单调增长，
// 使每包的序列化成本本身持续上升（二次放大），最终磁盘耗尽。
test "unknown observations stay bounded and never evict claimed records" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try temp.dir.realPath(std.testing.io, &path_buffer);
    const path = path_buffer[0..path_len];
    try catalog_store.initializeEmpty(std.testing.io, std.testing.allocator, path);

    // 构造一个已达上限的观测集：最后一条已被 claim，必须永不淘汰。
    var seeded: [CatalogRuntime.max_observations]model.UnknownClientObservation = undefined;
    const mac_storage = try std.testing.allocator.alloc([17]u8, CatalogRuntime.max_observations);
    defer std.testing.allocator.free(mac_storage);
    for (&seeded, 0..) |*item, index| {
        _ = std.fmt.bufPrint(&mac_storage[index], "02:00:00:{x:0>2}:{x:0>2}:{x:0>2}", .{
            @as(u8, @truncate(index >> 16)), @as(u8, @truncate(index >> 8)), @as(u8, @truncate(index)),
        }) catch unreachable;
        item.* = .{
            .mac = &mac_storage[index],
            .first_seen_unix = @intCast(1000 + index),
            .last_seen_unix = @intCast(1000 + index),
            .claim = if (index == CatalogRuntime.max_observations - 1)
                .{ .node_id = "claimed-node", .claimed_at_unix = 1 }
            else
                null,
        };
    }
    const initial: model.Catalog = .{
        // 保留期设得足够长，确保淘汰确实由条数上限触发而非过期回收。
        .discovery_policy = .{ .observation_retention_days = 36500 },
        .unknown_client_observations = &seeded,
    };
    var runtime = try CatalogRuntime.init(std.testing.allocator, path, &initial);
    defer runtime.deinit();

    try runtime.recordUnknownClient(std.testing.io, "02:ff:ff:ff:ff:ff", null, .x86_64, null, "192.0.2.99", 900000);

    const snapshot = runtime.acquire();
    defer snapshot.release();
    const observations = snapshot.value().unknown_client_observations;
    // 条数不得超过上限。
    try std.testing.expect(observations.len <= CatalogRuntime.max_observations);
    // 已 claim 的观测必须仍在（它是操作员工作数据）。
    var claimed_present = false;
    var newcomer_present = false;
    for (observations) |item| {
        if (item.claim != null) claimed_present = true;
        if (std.mem.eql(u8, item.mac, "02:ff:ff:ff:ff:ff")) newcomer_present = true;
    }
    try std.testing.expect(claimed_present);
    try std.testing.expect(newcomer_present);
    // 被淘汰的应是最旧的未 claim 条目。
    for (observations) |item| {
        if (item.claim == null and std.mem.eql(u8, item.mac, "02:00:00:00:00:00")) return error.OldestUnclaimedShouldHaveBeenEvicted;
    }
}

fn importedFixture(distro: []const u8, version: []const u8, arch: model.Arch, family: model.DistroFamily) iso_import.Result {
    return .{
        .source_name = "fixture-source",
        .family = family,
        .iso_asset = .{ .name = "fixture-image", .kind = .iso, .path = "fixture.iso", .distro = distro, .version = version, .arch = arch },
        .kernel_asset = .{ .name = "fixture-kernel", .kind = .kernel, .path = "install/fixture/vmlinuz", .distro = distro, .version = version, .arch = arch },
        .initrd_asset = .{ .name = "fixture-initrd", .kind = .installer_initrd, .path = "install/fixture/initrd.img", .distro = distro, .version = version, .arch = arch },
        .repositories = &.{},
        .install_source = .{ .name = "fixture-source", .distro = distro, .version = version, .arch = arch, .source_asset = "fixture-image", .installer_kernel = "fixture-kernel", .installer_initrd = "fixture-initrd" },
    };
}

test "first ISO import derives distro capability without a pre-created distro" {
    const imported = importedFixture("rocky", "9.7", .aarch64, .rhel);
    var expanded = try expandDistroTuple(std.testing.allocator, &.{}, imported);
    defer expanded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), expanded.values.len);
    try std.testing.expectEqualStrings("rocky", expanded.values[0].name);
    try std.testing.expectEqual(model.DistroFamily.rhel, expanded.values[0].family);
    try std.testing.expectEqualStrings("9.7", expanded.values[0].versions[0].version);
    try std.testing.expectEqual(model.InstallAdapter.kickstart, expanded.values[0].versions[0].install_adapter);
    try std.testing.expectEqual(model.PackageManager.dnf, expanded.values[0].versions[0].package_manager);
}

test "later ISO imports extend an existing distro version and architecture" {
    const base_versions = [_]model.DistroVersionConfig{.{
        .version = "9.7",
        .archs = &.{.aarch64},
        .install_adapter = .kickstart,
        .package_manager = .dnf,
    }};
    const base: model.Catalog = .{ .distros = &.{.{ .name = "rocky", .family = .rhel, .versions = &base_versions }} };
    var arch_expanded = try expandDistroTuple(std.testing.allocator, &base, importedFixture("rocky", "9.7", .x86_64, .rhel));
    defer arch_expanded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), arch_expanded.values[0].versions[0].archs.len);

    const with_arch: model.Catalog = .{ .distros = arch_expanded.values };
    var version_expanded = try expandDistroTuple(std.testing.allocator, &with_arch, importedFixture("rocky", "10.0", .x86_64, .rhel));
    defer version_expanded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), version_expanded.values[0].versions.len);
    try std.testing.expectEqualStrings("10.0", version_expanded.values[0].versions[1].version);
}

test "same distro id cannot change family through an ISO override" {
    const versions = [_]model.DistroVersionConfig{.{
        .version = "22.04",
        .archs = &.{.aarch64},
        .install_adapter = .autoinstall,
        .package_manager = .apt,
    }};
    const catalog: model.Catalog = .{ .distros = &.{.{ .name = "custom", .family = .ubuntu, .versions = &versions }} };
    try std.testing.expectError(error.DistroFamilyMismatch, expandDistroTuple(std.testing.allocator, &catalog, importedFixture("custom", "9.7", .aarch64, .rhel)));
}

test "first install source publication persists and projects its derived distro" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try temp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    try catalog_store.initializeEmpty(std.testing.io, std.testing.allocator, root);

    const config: model.AppConfig = .{
        .server = .{ .bind_interface = "eth0", .server_ip = "192.168.50.1" },
        .http = .{ .asset_root = "/tmp/nodeforge-assets", .repository_root = "/tmp/nodeforge-repositories" },
        .tftp = .{ .asset_root = "/tmp/nodeforge-tftp" },
    };
    var configs = try config_runtime.ConfigRuntime.init(std.testing.allocator, &config, 1);
    defer configs.deinit();
    var catalog = try CatalogRuntime.init(std.testing.allocator, root, &.{});
    defer catalog.deinit();

    var imported = importedFixture("rocky", "9.7", .aarch64, .rhel);
    imported.bootloader_asset = .{
        .name = "grub-uefi-aarch64",
        .kind = .bootloader,
        .path = "efi/grubaa64.efi",
    };
    try catalog.publishInstallSource(
        std.testing.io,
        &configs,
        &config,
        1,
        imported,
    );

    const live_catalog = catalog.acquire();
    defer live_catalog.release();
    try std.testing.expectEqual(@as(usize, 1), live_catalog.value().distros.len);
    try std.testing.expectEqual(@as(usize, 1), live_catalog.value().install_sources.len);
    try std.testing.expectEqual(@as(usize, 1), live_catalog.value().profiles.len);
    try std.testing.expectEqualStrings("fixture-source", live_catalog.value().profiles[0].name);
    try std.testing.expectEqualStrings("fixture-source", live_catalog.value().profiles[0].install_source);
    try std.testing.expect(live_catalog.value().profiles[0].system.import_host_hosts);
    try std.testing.expect(live_catalog.value().profiles[0].system.hosts_content != null);
    try std.testing.expect(std.mem.indexOf(u8, live_catalog.value().profiles[0].system.hosts_content.?, "localhost") != null);
    try std.testing.expectEqual(@as(usize, 4), live_catalog.value().assets.len);
    try std.testing.expectEqualStrings("efi/grubaa64.efi", live_catalog.value().assets[3].path);
    try std.testing.expectEqualStrings("rocky", live_catalog.value().distros[0].name);

    const projected_config = configs.acquire();
    defer projected_config.release();
    try std.testing.expectEqual(@as(usize, 1), projected_config.value().distros.len);
    try std.testing.expectEqualStrings("rocky", projected_config.value().distros[0].name);

    var persisted = try catalog_store.load(std.testing.io, std.testing.allocator, root);
    defer persisted.deinit();
    try std.testing.expectEqual(@as(usize, 1), persisted.value.distros.len);
    try std.testing.expectEqualStrings("fixture-source", persisted.value.install_sources[0].name);
}
