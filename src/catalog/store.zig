//! M4.7 catalog manifest/entity store。
//!
//! `manifest.json` 是唯一可见提交点；每个实体文件保存一个 JSON 数组。writer
//! 先持久化 journal 与 changed entity stage，依次发布实体，最后发布 manifest。
//! loader 在读取 manifest 前恢复未完成事务，并对每个实体做 SHA-256 校验，
//! 因而崩溃不会暴露 mixed generation。

const std = @import("std");
const model = @import("../model.zig");
const schema_v3_dto = @import("schema_v3_dto.zig");
const schema_v2_dto = @import("schema_v2_dto.zig");
const paths = @import("../paths.zig");
const atomic = @import("../state/dhcp_store.zig").atomicWrite;

/// catalog 文件最大允许 8 MiB，防止错误路径或异常文件耗尽内存。
pub const max_catalog_bytes = 8 * 1024 * 1024;
/// manifest 布局 schema 版本。当前固定为 1。
pub const layout_schema_version: u32 = 1;
const names = [_][]const u8{ "distros", "profiles", "nodes", "provisioning_bundles", "repositories", "assets", "install_sources", "boot_bundles", "discovery_policy", "unknown_client_observations" };

const ManifestEntity = struct { name: []const u8, file: []const u8, sha256: []const u8 };
const Manifest = struct {
    layout_schema_version: u32,
    catalog_schema_version: u32,
    catalog_revision: u64,
    transaction_id: []const u8,
    entities: []const ManifestEntity,
};
const TxFile = struct { final_path: []const u8, stage_path: []const u8, sha256: []const u8 };
const Journal = struct {
    schema_version: u32 = 1,
    transaction_id: []const u8,
    manifest_stage: []const u8,
    manifest_sha256: []const u8,
    files: []const TxFile,
};
const Content = struct { name: []const u8, file: []const u8, bytes: []u8, digest: [64]u8 };
pub const CrashPoint = enum { after_journal, after_entities, after_manifest };

/// 返回默认 catalog 目录路径。必须在进程路径自举完成后调用。
pub fn defaultPath() []const u8 {
    return paths.require().catalog_dir;
}
/// 返回空 catalog 对象。用于首次安装初始化。
pub fn empty() model.Catalog {
    return .{};
}

/// 显式 `.json` 路径只用于 legacy 诊断/迁移；正常路径必须是 catalog 目录。
/// 加载 catalog。路径可以是目录（manifest 布局）或 `.json` 文件（legacy 单文件）。
///
/// 目录路径走 `loadDirectory`，会先恢复未完成事务，再按 manifest 加载实体。
/// `.json` 路径走 `loadLegacy`，只用于诊断/迁移，不会触发事务恢复。
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(model.Catalog) {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return err,
        else => return err,
    };
    if (stat.kind == .file) return loadLegacy(io, allocator, path);
    if (stat.kind != .directory) return error.InvalidCatalogLayout;
    return loadDirectory(io, allocator, path);
}

/// 加载 legacy 单文件 catalog。根据 schema_version 选择 v2 或 v3 DTO 解析。
pub fn loadLegacy(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(model.Catalog) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_catalog_bytes));
    defer allocator.free(bytes);
    const Header = struct { schema_version: u32 };
    const header = try std.json.parseFromSlice(Header, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer header.deinit();
    // schema 4 直接存储完整模型形态（保留 diskless kind、
    // boot_bundle、rootfs_build/first_boot 步骤和 runtime_kernel 资产，
    // 严格 v3 DTO 会省略这些）；schema 3 使用严格 v3 DTO；其余为旧版 v2。
    if (header.value.schema_version == 3) return schema_v3_dto.parse(allocator, bytes);
    if (header.value.schema_version == 4) return std.json.parseFromSlice(model.Catalog, allocator, bytes, .{ .allocate = .alloc_always });
    return schema_v2_dto.parse(allocator, bytes);
}

pub fn initializeEmpty(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, directory);
    try saveDirectory(io, allocator, directory, &model.Catalog{}, null);
}

pub fn save(io: std.Io, allocator: std.mem.Allocator, path: []const u8, catalog: *const model.Catalog) !void {
    if (std.mem.endsWith(u8, path, ".json")) return saveLegacy(io, allocator, path, catalog);
    return saveDirectory(io, allocator, path, catalog, null);
}

pub fn saveWithCrash(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, catalog: *const model.Catalog, crash: CrashPoint) !void {
    return saveDirectory(io, allocator, directory, catalog, crash);
}

pub fn render(allocator: std.mem.Allocator, catalog: *const model.Catalog) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try std.json.Stringify.value(catalog.*, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

fn loadDirectory(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !std.json.Parsed(model.Catalog) {
    try recover(io, allocator, directory);
    const legacy = try joinPath(allocator, directory, "catalog.json");
    defer allocator.free(legacy);
    const manifest_path = try joinPath(allocator, directory, "manifest.json");
    defer allocator.free(manifest_path);
    if (exists(io, legacy) and exists(io, manifest_path)) return error.MixedCatalogLayout;
    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(1024 * 1024));
    defer allocator.free(manifest_bytes);
    var parsed_manifest = try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{ .allocate = .alloc_always });
    defer parsed_manifest.deinit();
    const manifest = parsed_manifest.value;
    // schema 3 和 4 持久化完整 10 实体集；旧版 v2 仅 8 个。
    const entity_names = if (manifest.catalog_schema_version >= 3) names[0..] else names[0..8];
    if (manifest.layout_schema_version != layout_schema_version or (manifest.catalog_schema_version < 2 or manifest.catalog_schema_version > 4) or manifest.catalog_revision == 0 or manifest.transaction_id.len != 64 or manifest.entities.len != entity_names.len)
        return error.InvalidCatalogManifest;
    var declared_tx: [64]u8 = undefined;
    try transactionId(manifest.catalog_revision, manifest.entities, &declared_tx);
    if (!std.mem.eql(u8, &declared_tx, manifest.transaction_id)) return error.InvalidCatalogManifest;

    var combined: std.Io.Writer.Allocating = .init(allocator);
    defer combined.deinit();
    try combined.writer.print("{{\"schema_version\":{d},\"revision\":{d}", .{ manifest.catalog_schema_version, manifest.catalog_revision });
    for (entity_names) |name| {
        const entity = findEntity(manifest.entities, name) orelse return error.InvalidCatalogManifest;
        const expected_file = try std.fmt.allocPrint(allocator, "{s}.json", .{name});
        defer allocator.free(expected_file);
        if (!std.mem.eql(u8, entity.file, expected_file) or entity.sha256.len != 64) return error.InvalidCatalogManifest;
        const entity_path = try joinPath(allocator, directory, entity.file);
        defer allocator.free(entity_path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, entity_path, allocator, .limited(max_catalog_bytes));
        defer allocator.free(bytes);
        var actual: [64]u8 = undefined;
        sha256(bytes, &actual);
        if (!std.mem.eql(u8, &actual, entity.sha256)) return error.CatalogDigestMismatch;
        try combined.writer.print(",\"{s}\":", .{name});
        try combined.writer.writeAll(bytes);
    }
    try combined.writer.writeByte('}');
    // schema 4 实体为直接模型序列化；按 model.Catalog 解析。
    return if (manifest.catalog_schema_version == 3)
        schema_v3_dto.parse(allocator, combined.written())
    else if (manifest.catalog_schema_version == 4)
        std.json.parseFromSlice(model.Catalog, allocator, combined.written(), .{ .allocate = .alloc_always })
    else
        schema_v2_dto.parse(allocator, combined.written());
}

fn saveDirectory(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, catalog: *const model.Catalog, crash: ?CrashPoint) !void {
    try std.Io.Dir.cwd().createDirPath(io, directory);
    try recover(io, allocator, directory);
    const manifest_path = try joinPath(allocator, directory, "manifest.json");
    defer allocator.free(manifest_path);
    const old_revision = loadRevision(io, allocator, manifest_path) catch |err| switch (err) {
        error.FileNotFound => 0,
        else => return err,
    };
    const revision = old_revision + 1;

    var contents: [names.len]Content = undefined;
    var initialized: usize = 0;
    defer for (contents[0..initialized]) |item| {
        allocator.free(item.bytes);
        allocator.free(item.file);
    };
    contents[0] = try content(allocator, names[0], catalog.distros);
    initialized += 1;
    contents[1] = if (catalog.schema_version == 3)
        try contentBytes(allocator, names[1], try schema_v3_dto.renderProfiles(allocator, catalog.profiles))
    else
        try content(allocator, names[1], catalog.profiles);
    initialized += 1;
    contents[2] = if (catalog.schema_version == 3)
        try contentBytes(allocator, names[2], try schema_v3_dto.renderNodes(allocator, catalog.nodes))
    else
        try content(allocator, names[2], catalog.nodes);
    initialized += 1;
    contents[3] = if (catalog.schema_version == 3)
        try contentBytes(allocator, names[3], try schema_v3_dto.renderBundles(allocator, catalog.provisioning_bundles))
    else
        try content(allocator, names[3], catalog.provisioning_bundles);
    initialized += 1;
    contents[4] = try content(allocator, names[4], catalog.repositories);
    initialized += 1;
    contents[5] = if (catalog.schema_version == 3)
        try contentBytes(allocator, names[5], try schema_v3_dto.renderAssets(allocator, catalog.assets))
    else
        try content(allocator, names[5], catalog.assets);
    initialized += 1;
    contents[6] = try content(allocator, names[6], catalog.install_sources);
    initialized += 1;
    contents[7] = try content(allocator, names[7], catalog.boot_bundles);
    initialized += 1;
    contents[8] = try content(allocator, names[8], catalog.discovery_policy);
    initialized += 1;
    contents[9] = try content(allocator, names[9], catalog.unknown_client_observations);
    initialized += 1;

    // schema 3 和 4 持久化全部 10 个实体；旧版 v2 仅 8 个。
    const content_count: usize = if (catalog.schema_version >= 3) names.len else 8;
    const selected_contents = contents[0..content_count];
    var entities: [names.len]ManifestEntity = undefined;
    for (selected_contents, 0..) |*item, index| entities[index] = .{ .name = item.name, .file = item.file, .sha256 = &item.digest };
    const selected_entities = entities[0..content_count];
    var transaction_id: [64]u8 = undefined;
    try transactionId(revision, selected_entities, &transaction_id);
    const manifest: Manifest = .{ .layout_schema_version = layout_schema_version, .catalog_schema_version = catalog.schema_version, .catalog_revision = revision, .transaction_id = &transaction_id, .entities = selected_entities };
    const manifest_bytes = try std.json.Stringify.valueAlloc(allocator, manifest, .{ .whitespace = .indent_2 });
    defer allocator.free(manifest_bytes);
    var manifest_digest: [64]u8 = undefined;
    sha256(manifest_bytes, &manifest_digest);
    const manifest_stage = try std.fmt.allocPrint(allocator, "{s}/manifest.json.stage-{s}", .{ directory, transaction_id });
    defer allocator.free(manifest_stage);

    var old_manifest: ?std.json.Parsed(Manifest) = null;
    if (std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(1024 * 1024))) |bytes| {
        defer allocator.free(bytes);
        old_manifest = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .allocate = .alloc_always });
    } else |_| {}
    defer if (old_manifest) |*parsed| parsed.deinit();

    var changes: [names.len]TxFile = undefined;
    var change_count: usize = 0;
    for (selected_contents) |*item| {
        const unchanged = if (old_manifest) |*old| if (findEntity(old.value.entities, item.name)) |entity| std.mem.eql(u8, entity.sha256, &item.digest) else false else false;
        if (unchanged) continue;
        const final_path = try joinPath(allocator, directory, item.file);
        const stage_path = try std.fmt.allocPrint(allocator, "{s}.stage-{s}", .{ final_path, transaction_id });
        try secureAtomic(io, allocator, stage_path, item.bytes);
        changes[change_count] = .{ .final_path = final_path, .stage_path = stage_path, .sha256 = &item.digest };
        change_count += 1;
    }
    defer for (changes[0..change_count]) |change| {
        allocator.free(change.final_path);
        allocator.free(change.stage_path);
    };
    try secureAtomic(io, allocator, manifest_stage, manifest_bytes);
    const journal_path = try joinPath(allocator, directory, "transaction.json");
    defer allocator.free(journal_path);
    const journal: Journal = .{ .transaction_id = &transaction_id, .manifest_stage = manifest_stage, .manifest_sha256 = &manifest_digest, .files = changes[0..change_count] };
    const journal_bytes = try std.json.Stringify.valueAlloc(allocator, journal, .{ .whitespace = .indent_2 });
    defer allocator.free(journal_bytes);
    try secureAtomic(io, allocator, journal_path, journal_bytes);
    if (crash == .after_journal) return error.InjectedCrash;
    for (changes[0..change_count]) |change| try std.Io.Dir.rename(std.Io.Dir.cwd(), change.stage_path, std.Io.Dir.cwd(), change.final_path, io);
    if (crash == .after_entities) return error.InjectedCrash;
    try std.Io.Dir.rename(std.Io.Dir.cwd(), manifest_stage, std.Io.Dir.cwd(), manifest_path, io);
    if (crash == .after_manifest) return error.InjectedCrash;
    try std.Io.Dir.cwd().deleteFile(io, journal_path);
}

fn recover(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !void {
    const journal_path = try joinPath(allocator, directory, "transaction.json");
    defer allocator.free(journal_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, journal_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(Journal, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const journal = parsed.value;
    if (journal.schema_version != 1 or journal.transaction_id.len != 64 or journal.manifest_sha256.len != 64) return error.InvalidCatalogJournal;
    const manifest_path = try joinPath(allocator, directory, "manifest.json");
    defer allocator.free(manifest_path);
    if (manifestTransaction(io, allocator, manifest_path, journal.transaction_id)) {
        for (journal.files) |file| std.Io.Dir.cwd().deleteFile(io, file.stage_path) catch {};
        std.Io.Dir.cwd().deleteFile(io, journal.manifest_stage) catch {};
        try std.Io.Dir.cwd().deleteFile(io, journal_path);
        return;
    }
    for (journal.files) |file| {
        if (try fileDigestEquals(io, allocator, file.final_path, file.sha256)) continue;
        if (!try fileDigestEquals(io, allocator, file.stage_path, file.sha256)) return error.CatalogRecoveryFailed;
        try std.Io.Dir.rename(std.Io.Dir.cwd(), file.stage_path, std.Io.Dir.cwd(), file.final_path, io);
    }
    if (!try fileDigestEquals(io, allocator, journal.manifest_stage, journal.manifest_sha256)) return error.CatalogRecoveryFailed;
    try std.Io.Dir.rename(std.Io.Dir.cwd(), journal.manifest_stage, std.Io.Dir.cwd(), manifest_path, io);
    try std.Io.Dir.cwd().deleteFile(io, journal_path);
}

fn saveLegacy(io: std.Io, allocator: std.mem.Allocator, path_name: []const u8, catalog: *const model.Catalog) !void {
    const bytes = try render(allocator, catalog);
    defer allocator.free(bytes);
    try secureAtomic(io, allocator, path_name, bytes);
}
fn content(allocator: std.mem.Allocator, name: []const u8, values: anytype) !Content {
    const bytes = try std.json.Stringify.valueAlloc(allocator, values, .{ .whitespace = .indent_2 });
    errdefer allocator.free(bytes);
    var digest: [64]u8 = undefined;
    sha256(bytes, &digest);
    return .{ .name = name, .file = try std.fmt.allocPrint(allocator, "{s}.json", .{name}), .bytes = bytes, .digest = digest };
}
fn contentBytes(allocator: std.mem.Allocator, name: []const u8, bytes: []u8) !Content {
    errdefer allocator.free(bytes);
    var digest: [64]u8 = undefined;
    sha256(bytes, &digest);
    return .{ .name = name, .file = try std.fmt.allocPrint(allocator, "{s}.json", .{name}), .bytes = bytes, .digest = digest };
}
fn findEntity(entities: []const ManifestEntity, name: []const u8) ?ManifestEntity {
    for (entities) |entity| if (std.mem.eql(u8, entity.name, name)) return entity;
    return null;
}
fn loadRevision(io: std.Io, allocator: std.mem.Allocator, manifest_path: []const u8) !u64 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value.layout_schema_version != layout_schema_version) return error.InvalidCatalogManifest;
    return parsed.value.catalog_revision;
}
fn manifestTransaction(io: std.Io, allocator: std.mem.Allocator, manifest_path: []const u8, transaction_id: []const u8) bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(1024 * 1024)) catch return false;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(Manifest, allocator, bytes, .{ .allocate = .alloc_always }) catch return false;
    defer parsed.deinit();
    return std.mem.eql(u8, parsed.value.transaction_id, transaction_id);
}
fn fileDigestEquals(io: std.Io, allocator: std.mem.Allocator, path_name: []const u8, expected: []const u8) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path_name, allocator, .limited(max_catalog_bytes)) catch return false;
    defer allocator.free(bytes);
    var actual: [64]u8 = undefined;
    sha256(bytes, &actual);
    return std.mem.eql(u8, &actual, expected);
}
fn sha256(bytes: []const u8, output: *[64]u8) void {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    _ = std.fmt.bufPrint(output, "{x}", .{raw}) catch unreachable;
}
fn secureAtomic(io: std.Io, allocator: std.mem.Allocator, path_name: []const u8, bytes: []const u8) !void {
    try atomic(io, path_name, bytes);
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "chmod", "600", path_name }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ChmodFailed,
        else => return error.ChmodFailed,
    }
}
fn transactionId(revision: u64, entities: []const ManifestEntity, output: *[64]u8) !void {
    var revision_text: [24]u8 = undefined;
    const text = try std.fmt.bufPrint(&revision_text, "{d}", .{revision});
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(text);
    for (entities) |entity| {
        hash.update(entity.name);
        hash.update(entity.sha256);
    }
    var raw: [32]u8 = undefined;
    hash.final(&raw);
    _ = std.fmt.bufPrint(output, "{x}", .{raw}) catch unreachable;
}
fn joinPath(allocator: std.mem.Allocator, directory: []const u8, file: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, file });
}
fn exists(io: std.Io, path_name: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path_name, .{ .follow_symlinks = false }) catch return false;
    return true;
}

test "manifest store round trips and only changes nodes entity" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try temp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..n];
    try initializeEmpty(std.testing.io, std.testing.allocator, root);
    var first = try load(std.testing.io, std.testing.allocator, root);
    defer first.deinit();
    var catalog = first.value;
    catalog.nodes = &.{.{ .id = "n1", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "discovery" }};
    const assets_path = try joinPath(std.testing.allocator, root, "assets.json");
    defer std.testing.allocator.free(assets_path);
    const before = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, assets_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(before);
    try save(std.testing.io, std.testing.allocator, root, &catalog);
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, assets_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
    var second = try load(std.testing.io, std.testing.allocator, root);
    defer second.deinit();
    try std.testing.expectEqualStrings("n1", second.value.nodes[0].id);
    try std.testing.expectEqual(@as(u64, 2), second.value.revision);
}

test "manifest journal recovers every visible commit phase" {
    inline for (.{ CrashPoint.after_journal, CrashPoint.after_entities, CrashPoint.after_manifest }) |point| {
        var temp = std.testing.tmpDir(.{});
        defer temp.cleanup();
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try temp.dir.realPath(std.testing.io, &root_buf);
        const root = root_buf[0..n];
        try initializeEmpty(std.testing.io, std.testing.allocator, root);
        const candidate: model.Catalog = .{ .nodes = &.{.{ .id = "recover", .mac = "02:aa:bb:cc:dd:ee", .arch = .aarch64, .profile = "discovery" }} };
        try std.testing.expectError(error.InjectedCrash, saveWithCrash(std.testing.io, std.testing.allocator, root, &candidate, point));
        var recovered = try load(std.testing.io, std.testing.allocator, root);
        defer recovered.deinit();
        try std.testing.expectEqualStrings("recover", recovered.value.nodes[0].id);
        const journal = try joinPath(std.testing.allocator, root, "transaction.json");
        defer std.testing.allocator.free(journal);
        try std.testing.expect(!exists(std.testing.io, journal));
    }
}

test "manifest load rejects entity digest mismatch" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try temp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..n];
    try initializeEmpty(std.testing.io, std.testing.allocator, root);
    const nodes = try joinPath(std.testing.allocator, root, "nodes.json");
    defer std.testing.allocator.free(nodes);
    try secureAtomic(std.testing.io, std.testing.allocator, nodes, "[{\"id\":\"tampered\"}]");
    try std.testing.expectError(error.CatalogDigestMismatch, load(std.testing.io, std.testing.allocator, root));
}

test "v4 catalog round-trips diskless profile, boot bundle and rootfs_build step" {
    // v4 使用直接模型序列化，因此 diskless 专属字段（kind=diskless、
    // boot_bundle、rootfs_build 阶段、package 动作、runtime_kernel 资产）必须
    // 在 save/load 后完整保留。v3 DTO 往返会静默丢弃它们。
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try temp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..n];
    try initializeEmpty(std.testing.io, std.testing.allocator, root);
    const profiles = [_]model.ProfileConfig{.{ .name = "diskless-9", .install_source = "s", .kind = .diskless, .boot_bundle = "bb", .software = .{ .packages = .{ .include = &.{"curl"} } } }};
    const bundles = [_]model.BootBundleConfig{.{ .name = "bb", .distro = "rocky", .version = "9", .arch = .aarch64, .kernel_release = "5.14.0", .kernel = "k", .initrd = "i", .rootfs = "r" }};
    const steps = [_]model.ProvisionStep{.{ .name = "pkgs", .phase = .rootfs_build, .action = .@"package", .packages = &.{"vim"} }};
    const prov_bundles = [_]model.ProvisioningBundle{.{ .name = "pb", .steps = &steps }};
    const assets = [_]model.AssetConfig{.{ .name = "rk", .kind = .runtime_kernel, .path = "/rk" }};
    const candidate: model.Catalog = .{ .schema_version = 4, .profiles = &profiles, .boot_bundles = &bundles, .provisioning_bundles = &prov_bundles, .assets = &assets };
    try save(std.testing.io, std.testing.allocator, root, &candidate);
    var loaded = try load(std.testing.io, std.testing.allocator, root);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 4), loaded.value.schema_version);
    try std.testing.expectEqual(model.ProfileKind.diskless, loaded.value.profiles[0].kind);
    try std.testing.expectEqualStrings("bb", loaded.value.profiles[0].boot_bundle.?);
    try std.testing.expectEqual(model.ProvisionPhase.rootfs_build, loaded.value.provisioning_bundles[0].steps[0].phase);
    try std.testing.expectEqual(model.ProvisionAction.@"package", loaded.value.provisioning_bundles[0].steps[0].action);
    try std.testing.expectEqual(model.AssetKind.runtime_kernel, loaded.value.assets[0].kind);
    // 幂等再次保存使 manifest 在 schema 4 下保持稳定（10 个实体）。
    try save(std.testing.io, std.testing.allocator, root, &loaded.value);
    var reloaded = try load(std.testing.io, std.testing.allocator, root);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(u32, 4), reloaded.value.schema_version);
    try std.testing.expectEqual(model.ProfileKind.diskless, reloaded.value.profiles[0].kind);
}
