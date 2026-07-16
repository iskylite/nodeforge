//! Ref-counted immutable catalog generations owned by the daemon.

const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const validate = @import("../config/validate.zig");
const iso_import = @import("../catalog/iso_import.zig");

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    parsed: std.json.Parsed(model.Catalog),
    revision: u64,
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),

    pub fn value(self: *const Snapshot) *const model.Catalog {
        return &self.parsed.value;
    }
    pub fn release(self: *const Snapshot) void {
        const mutable: *Snapshot = @constCast(self);
        if (mutable.refs.fetchSub(1, .acq_rel) != 1) return;
        mutable.parsed.deinit();
        const allocator = mutable.allocator;
        allocator.destroy(mutable);
    }
};

pub const CatalogRuntime = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    current: std.atomic.Value(*Snapshot),
    writer: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, initial: *const model.Catalog) !CatalogRuntime {
        const snapshot = try createSnapshot(allocator, initial.*, if (initial.revision == 0) 1 else initial.revision);
        return .{ .allocator = allocator, .path = path, .current = std.atomic.Value(*Snapshot).init(snapshot) };
    }
    pub fn deinit(self: *CatalogRuntime) void {
        self.current.load(.acquire).release();
    }
    pub fn lock(self: *CatalogRuntime) void {
        lockMutex(&self.writer);
    }
    pub fn unlock(self: *CatalogRuntime) void {
        self.writer.unlock();
    }
    pub fn acquire(self: *CatalogRuntime) *const Snapshot {
        self.lock();
        defer self.unlock();
        return self.acquireLocked();
    }
    pub fn acquireLocked(self: *CatalogRuntime) *const Snapshot {
        const snapshot = self.current.load(.acquire);
        _ = snapshot.refs.fetchAdd(1, .monotonic);
        return snapshot;
    }
    pub fn currentRevision(self: *CatalogRuntime) u64 {
        const snapshot = self.acquire();
        defer snapshot.release();
        return snapshot.revision;
    }
    pub fn containsAssetPath(self: *CatalogRuntime, path: []const u8) bool {
        const snapshot = self.acquire();
        defer snapshot.release();
        for (snapshot.value().assets) |asset| if (std.mem.eql(u8, asset.path, path)) return true;
        return false;
    }

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

    pub fn publishInstallSource(self: *CatalogRuntime, io: std.Io, config: *const model.AppConfig, imported: iso_import.Result) !void {
        self.lock();
        defer self.unlock();
        const old = self.acquireLocked();
        defer old.release();
        const value = old.value();
        const additions = [_]model.AssetConfig{ imported.iso_asset, imported.kernel_asset, imported.initrd_asset };
        for (additions) |asset| for (value.assets) |existing| if (std.mem.eql(u8, existing.name, asset.name)) return error.DuplicateObjectName;
        if (imported.repository) |repository| for (value.repositories) |existing| if (std.mem.eql(u8, existing.name, repository.name)) return error.DuplicateObjectName;
        for (value.install_sources) |existing| if (std.mem.eql(u8, existing.name, imported.install_source.name)) return error.DuplicateObjectName;
        const assets = try self.allocator.alloc(model.AssetConfig, value.assets.len + additions.len);
        defer self.allocator.free(assets);
        @memcpy(assets[0..value.assets.len], value.assets);
        @memcpy(assets[value.assets.len..], &additions);
        const repo_count: usize = if (imported.repository == null) 0 else 1;
        const repositories = try self.allocator.alloc(model.RepositoryConfig, value.repositories.len + repo_count);
        defer self.allocator.free(repositories);
        @memcpy(repositories[0..value.repositories.len], value.repositories);
        if (imported.repository) |repository| repositories[value.repositories.len] = repository;
        const sources = try self.allocator.alloc(model.InstallSourceConfig, value.install_sources.len + 1);
        defer self.allocator.free(sources);
        @memcpy(sources[0..value.install_sources.len], value.install_sources);
        sources[value.install_sources.len] = imported.install_source;
        var candidate = value.*;
        candidate.revision = old.revision + 1;
        candidate.assets = assets;
        candidate.repositories = repositories;
        candidate.install_sources = sources;
        try validate.validate(config, &candidate);
        try catalog_store.save(io, self.allocator, self.path, &candidate);
        try self.publishLocked(candidate, old.revision + 1);
    }

    pub fn publishLocked(self: *CatalogRuntime, candidate: model.Catalog, revision: u64) !void {
        const next = try self.prepare(candidate, revision);
        self.publishPreparedLocked(next);
    }
    pub fn prepare(self: *CatalogRuntime, candidate: model.Catalog, revision: u64) !*Snapshot {
        return createSnapshot(self.allocator, candidate, revision);
    }
    pub fn publishPreparedLocked(self: *CatalogRuntime, next: *Snapshot) void {
        const previous = self.current.swap(next, .acq_rel);
        previous.release();
    }
};

fn createSnapshot(allocator: std.mem.Allocator, value: model.Catalog, revision: u64) !*Snapshot {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(model.Catalog, allocator, bytes, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    const snapshot = try allocator.create(Snapshot);
    snapshot.* = .{ .allocator = allocator, .parsed = parsed, .revision = revision };
    return snapshot;
}
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
