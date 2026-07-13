//! daemon 持有的可变 catalog 快照。
//!
//! 所有 catalog 写入都经由本类型：先构造候选快照、完整校验、原子落盘，最后替换内存视图。
//! TFTP 与 HTTP 读取只在锁内取得短生命周期的数据，避免读取到半更新 slice。

const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const validate = @import("../config/validate.zig");
const iso_import = @import("../catalog/iso_import.zig");

pub const CatalogRuntime = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    value: model.Catalog,
    // 此锁保护 catalog 发布，同时 UDP 和 HTTP worker 读取它。
    // `atomic.Mutex` 是同步的，因此不会将 catalog 读取耦合到
    // daemon 的特定 `std.Io` 后端。
    mutex: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, initial: *const model.Catalog) CatalogRuntime {
        return .{ .allocator = allocator, .path = path, .value = initial.* };
    }

    /// 获取短期 catalog 发布锁。catalog 操作只复制元数据并原子替换小型 JSON 文件，
    /// 因此基于 yield 的自旋锁使同步 HTTP/UDP 接口独立于 Io 循环。
    pub fn lock(self: *CatalogRuntime) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }

    /// 释放由 `lock` 获取的 catalog 发布锁。
    pub fn unlock(self: *CatalogRuntime) void {
        self.mutex.unlock();
    }

    /// 判断给定相对路径是否是当前 manifest 的受管资产。
    pub fn containsAssetPath(self: *CatalogRuntime, path: []const u8) bool {
        self.lock();
        defer self.unlock();
        for (self.value.assets) |asset| if (std.mem.eql(u8, asset.path, path)) return true;
        return false;
    }

    /// 将一个已解析、已复制的资产写入 catalog，并立即发布内存快照。
    pub fn addAsset(self: *CatalogRuntime, io: std.Io, config: *const model.AppConfig, asset: model.AssetConfig) !void {
        self.lock();
        defer self.unlock();
        for (self.value.assets) |existing| if (std.mem.eql(u8, existing.name, asset.name)) return error.DuplicateObjectName;

        const owned = try copyAsset(self.allocator, asset);
        const next_assets = try self.allocator.alloc(model.AssetConfig, self.value.assets.len + 1);
        @memcpy(next_assets[0..self.value.assets.len], self.value.assets);
        next_assets[self.value.assets.len] = owned;
        var candidate = self.value;
        candidate.assets = next_assets;
        try validate.validate(config, &candidate);
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        self.value = candidate;
    }

    /// 在一次 catalog 替换中发布关联的 ISO、安装器资产、可选仓库和安装入口。
    /// 文件可能已存在于不同的受管根中，但在本方法成功之前没有任何东西能解析它们。
    pub fn publishInstallSource(self: *CatalogRuntime, io: std.Io, config: *const model.AppConfig, imported: iso_import.Result) !void {
        self.lock();
        defer self.unlock();
        const assets_to_add = [_]model.AssetConfig{ imported.iso_asset, imported.kernel_asset, imported.initrd_asset };
        for (assets_to_add) |asset| {
            for (self.value.assets) |existing| if (std.mem.eql(u8, existing.name, asset.name)) return error.DuplicateObjectName;
        }
        if (imported.repository) |repository| for (self.value.repositories) |existing| if (std.mem.eql(u8, existing.name, repository.name)) return error.DuplicateObjectName;
        for (self.value.install_sources) |existing| if (std.mem.eql(u8, existing.name, imported.install_source.name)) return error.DuplicateObjectName;

        const next_assets = try self.allocator.alloc(model.AssetConfig, self.value.assets.len + assets_to_add.len);
        @memcpy(next_assets[0..self.value.assets.len], self.value.assets);
        @memcpy(next_assets[self.value.assets.len..], &assets_to_add);
        const repository_count: usize = if (imported.repository == null) 0 else 1;
        const next_repositories = try self.allocator.alloc(model.RepositoryConfig, self.value.repositories.len + repository_count);
        @memcpy(next_repositories[0..self.value.repositories.len], self.value.repositories);
        if (imported.repository) |repository| next_repositories[self.value.repositories.len] = repository;
        const next_sources = try self.allocator.alloc(model.InstallSourceConfig, self.value.install_sources.len + 1);
        @memcpy(next_sources[0..self.value.install_sources.len], self.value.install_sources);
        next_sources[self.value.install_sources.len] = imported.install_source;
        var candidate = self.value;
        candidate.assets = next_assets;
        candidate.repositories = next_repositories;
        candidate.install_sources = next_sources;
        try validate.validate(config, &candidate);
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        self.value = candidate;
    }
};

/// 在 catalog 发布前拷贝所有可能来自 HTTP 请求的字符串。
/// 请求缓冲区在路由处理完成后立即释放，因此 catalog 必须拥有自己的字符串副本。
fn copyAsset(allocator: std.mem.Allocator, source: model.AssetConfig) !model.AssetConfig {
    return .{
        .name = try allocator.dupe(u8, source.name),
        .kind = source.kind,
        .path = try allocator.dupe(u8, source.path),
        .distro = if (source.distro) |v| try allocator.dupe(u8, v) else null,
        .version = if (source.version) |v| try allocator.dupe(u8, v) else null,
        .arch = source.arch,
        .kernel_release = if (source.kernel_release) |v| try allocator.dupe(u8, v) else null,
        .sha256 = if (source.sha256) |v| try allocator.dupe(u8, v) else null,
    };
}
