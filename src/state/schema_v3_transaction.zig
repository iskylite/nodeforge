//! Crash-recoverable schema-v3 publication for startup config plus a
//! manifest-backed catalog directory.
const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const atomicWrite = @import("dhcp_store.zig").atomicWrite;

pub const State = enum { prepared, catalog_committed, complete, rolled_back };

const Journal = struct {
    schema_version: u32 = 1,
    plan_digest: []const u8,
    state: State,
    config_path: []const u8,
    catalog_path: []const u8,
    old_config_path: []const u8,
    new_config_path: []const u8,
    old_catalog_path: []const u8,
    new_catalog_path: []const u8,
    old_config_sha256: []const u8,
    new_config_sha256: []const u8,
    old_catalog_sha256: []const u8,
    new_catalog_sha256: []const u8,
};

pub fn commit(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: []const u8,
    digest: []const u8,
    config_path: []const u8,
    catalog_path: []const u8,
    new_config: []const u8,
    new_catalog: *const model.Catalog,
) !void {
    if (digest.len != 64) return error.InvalidPlanDigest;
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const journal_path = try pathFor(allocator, directory, digest, ".schema-v3.json");
    defer allocator.free(journal_path);
    if (exists(io, journal_path)) return error.TransactionAlreadyExists;
    const old_config_path = try pathFor(allocator, directory, digest, ".schema-v3.config.old");
    defer allocator.free(old_config_path);
    const new_config_path = try pathFor(allocator, directory, digest, ".schema-v3.config.new");
    defer allocator.free(new_config_path);
    const old_catalog_path = try pathFor(allocator, directory, digest, ".schema-v3.catalog.old");
    defer allocator.free(old_catalog_path);
    const new_catalog_path = try pathFor(allocator, directory, digest, ".schema-v3.catalog.new");
    defer allocator.free(new_catalog_path);

    const old_config = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(old_config);
    var old_catalog = try catalog_store.load(io, allocator, catalog_path);
    defer old_catalog.deinit();
    const old_catalog_json = try catalog_store.render(allocator, &old_catalog.value);
    defer allocator.free(old_catalog_json);
    const new_catalog_json = try catalog_store.render(allocator, new_catalog);
    defer allocator.free(new_catalog_json);
    var old_config_sha: [64]u8 = undefined;
    var new_config_sha: [64]u8 = undefined;
    var old_catalog_sha: [64]u8 = undefined;
    var new_catalog_sha: [64]u8 = undefined;
    sha256(old_config, &old_config_sha);
    sha256(new_config, &new_config_sha);
    sha256(old_catalog_json, &old_catalog_sha);
    sha256(new_catalog_json, &new_catalog_sha);
    try atomicWrite(io, old_config_path, old_config);
    try atomicWrite(io, new_config_path, new_config);
    try atomicWrite(io, old_catalog_path, old_catalog_json);
    try atomicWrite(io, new_catalog_path, new_catalog_json);
    var journal: Journal = .{
        .plan_digest = digest,
        .state = .prepared,
        .config_path = config_path,
        .catalog_path = catalog_path,
        .old_config_path = old_config_path,
        .new_config_path = new_config_path,
        .old_catalog_path = old_catalog_path,
        .new_catalog_path = new_catalog_path,
        .old_config_sha256 = &old_config_sha,
        .new_config_sha256 = &new_config_sha,
        .old_catalog_sha256 = &old_catalog_sha,
        .new_catalog_sha256 = &new_catalog_sha,
    };
    try saveJournal(io, allocator, journal_path, journal);
    try catalog_store.save(io, allocator, catalog_path, new_catalog);
    journal.state = .catalog_committed;
    try saveJournal(io, allocator, journal_path, journal);
    try atomicWrite(io, config_path, new_config);
    journal.state = .complete;
    try saveJournal(io, allocator, journal_path, journal);
}

pub fn rollback(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, digest: []const u8) !void {
    const journal_path = try pathFor(allocator, directory, digest, ".schema-v3.json");
    defer allocator.free(journal_path);
    var parsed = try loadJournal(io, allocator, journal_path);
    defer parsed.deinit();
    if (parsed.value.state != .complete) return error.TransactionNotCommitted;
    const old_config = try verifiedFile(io, allocator, parsed.value.old_config_path, parsed.value.old_config_sha256);
    defer allocator.free(old_config);
    var old_catalog = try loadCatalogFile(io, allocator, parsed.value.old_catalog_path, parsed.value.old_catalog_sha256);
    defer old_catalog.deinit();
    try catalog_store.save(io, allocator, parsed.value.catalog_path, &old_catalog.value);
    try atomicWrite(io, parsed.value.config_path, old_config);
    parsed.value.state = .rolled_back;
    try saveJournal(io, allocator, journal_path, parsed.value);
}

/// Runs before config/catalog parsing. A prepared transaction may have crashed
/// immediately before or after the catalog manifest commit, so content hashes,
/// rather than the last journal write, determine which side is authoritative.
pub fn recoverAll(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !usize {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".schema-v3.json"))
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    var recovered: usize = 0;
    for (names.items) |name| {
        const journal_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
        defer allocator.free(journal_path);
        var parsed = try loadJournal(io, allocator, journal_path);
        defer parsed.deinit();
        if (parsed.value.state == .complete or parsed.value.state == .rolled_back) continue;
        var current = try catalog_store.load(io, allocator, parsed.value.catalog_path);
        defer current.deinit();
        const rendered = try catalog_store.render(allocator, &current.value);
        defer allocator.free(rendered);
        var current_sha: [64]u8 = undefined;
        sha256(rendered, &current_sha);
        if (std.mem.eql(u8, &current_sha, parsed.value.new_catalog_sha256)) {
            const next_config = try verifiedFile(io, allocator, parsed.value.new_config_path, parsed.value.new_config_sha256);
            defer allocator.free(next_config);
            try atomicWrite(io, parsed.value.config_path, next_config);
            parsed.value.state = .complete;
        } else if (std.mem.eql(u8, &current_sha, parsed.value.old_catalog_sha256)) {
            parsed.value.state = .rolled_back;
        } else return error.SchemaV3RecoveryFailed;
        try saveJournal(io, allocator, journal_path, parsed.value);
        recovered += 1;
    }
    return recovered;
}

fn loadCatalogFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, digest: []const u8) !std.json.Parsed(model.Catalog) {
    const bytes = try verifiedFile(io, allocator, path, digest);
    defer allocator.free(bytes);
    return std.json.parseFromSlice(model.Catalog, allocator, bytes, .{ .allocate = .alloc_always });
}

fn verifiedFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, digest: []const u8) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    errdefer allocator.free(bytes);
    var actual: [64]u8 = undefined;
    sha256(bytes, &actual);
    if (!std.mem.eql(u8, &actual, digest)) return error.SchemaV3BackupDigestMismatch;
    return bytes;
}

fn loadJournal(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Journal) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Journal, allocator, bytes, .{ .allocate = .alloc_always });
    if (parsed.value.schema_version != 1 or parsed.value.plan_digest.len != 64) {
        parsed.deinit();
        return error.InvalidSchemaV3Journal;
    }
    return parsed;
}

fn saveJournal(io: std.Io, allocator: std.mem.Allocator, path: []const u8, journal: Journal) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, journal, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    try atomicWrite(io, path, bytes);
}
fn pathFor(allocator: std.mem.Allocator, directory: []const u8, digest: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ directory, digest, suffix });
}
fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}
fn sha256(bytes: []const u8, output: *[64]u8) void {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    _ = std.fmt.bufPrint(output, "{x}", .{raw}) catch unreachable;
}

test "directory catalog schema migration commits and rolls back retained generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(root);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{root});
    defer std.testing.allocator.free(config_path);
    const catalog_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/catalog", .{root});
    defer std.testing.allocator.free(catalog_path);
    const tx_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/transactions", .{root});
    defer std.testing.allocator.free(tx_path);
    const old_config = "{\"schema_version\":2,\"server\":{\"server_ip\":\"192.0.2.1\"}}\n";
    const new_config = "{\"schema_version\":3,\"server\":{\"server_ip\":\"192.0.2.1\"}}\n";
    try atomicWrite(std.testing.io, config_path, old_config);
    try catalog_store.initializeEmpty(std.testing.io, std.testing.allocator, catalog_path);
    const old_catalog: model.Catalog = .{ .schema_version = 2 };
    try catalog_store.save(std.testing.io, std.testing.allocator, catalog_path, &old_catalog);
    var next: model.Catalog = .{ .schema_version = 3 };
    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try commit(std.testing.io, std.testing.allocator, tx_path, digest, config_path, catalog_path, new_config, &next);
    const committed_config = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(committed_config);
    try std.testing.expect(std.mem.indexOf(u8, committed_config, "\"schema_version\":3") != null);
    var committed_catalog = try catalog_store.load(std.testing.io, std.testing.allocator, catalog_path);
    defer committed_catalog.deinit();
    try std.testing.expectEqual(@as(u32, 3), committed_catalog.value.schema_version);
    try rollback(std.testing.io, std.testing.allocator, tx_path, digest);
    const restored_config = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(restored_config);
    try std.testing.expectEqualStrings(old_config, restored_config);
    var restored_catalog = try catalog_store.load(std.testing.io, std.testing.allocator, catalog_path);
    defer restored_catalog.deinit();
    try std.testing.expectEqual(@as(u32, 2), restored_catalog.value.schema_version);
}
