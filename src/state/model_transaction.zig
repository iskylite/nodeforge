//! Crash-recoverable publication of config.json and catalog.json as one model.
const std = @import("std");
const dhcp_store = @import("dhcp_store.zig");
const paths = @import("../paths.zig");

pub const State = enum { prepared, files_ready, catalog_committed, config_committed, complete, cleanup_pending };
pub const CrashPoint = enum { after_prepared, after_files_ready, after_catalog, after_config };
pub const Move = struct { old: []const u8, new: []const u8 };
pub const RecoveryOutcome = enum { rolled_back, committed };
const RecoveryRecord = struct { schema_version: u32 = 1, plan_digest: []const u8, outcome: RecoveryOutcome };

pub fn directoryForConfig(allocator: std.mem.Allocator, config_path: []const u8) ![]u8 {
    const runtime_paths: ?*const paths.Paths = paths.current() catch null;
    if (runtime_paths) |value| if (std.mem.eql(u8, config_path, value.config_path))
        return allocator.dupe(u8, value.model_transactions_dir);
    const parent = std.fs.path.dirname(config_path) orelse ".";
    return std.fmt.allocPrint(allocator, "{s}/model-transactions", .{parent});
}
const Journal = struct {
    schema_version: u32 = 1,
    plan_digest: []const u8,
    state: State,
    config_path: []const u8,
    catalog_path: []const u8,
    config_stage: []const u8,
    catalog_stage: []const u8,
    config_backup: []const u8,
    catalog_backup: []const u8,
    old_config_sha256: []const u8,
    new_config_sha256: []const u8,
    old_catalog_sha256: []const u8,
    new_catalog_sha256: []const u8,
    old_catalog_present: bool = true,
    moves: []const Move = &.{},
};

pub fn commit(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, digest: []const u8, config_path: []const u8, catalog_path: []const u8, new_config: []const u8, new_catalog: []const u8, moves: []const Move, crash: ?CrashPoint) !void {
    if (digest.len != 64) return error.InvalidPlanDigest;
    try std.Io.Dir.cwd().createDirPath(io, directory);
    try chmod(io, allocator, "700", directory);
    const journal_path = try pathFor(allocator, directory, digest, ".json");
    defer allocator.free(journal_path);
    const config_stage = try pathFor(allocator, directory, digest, ".config.new");
    defer allocator.free(config_stage);
    const catalog_stage = try pathFor(allocator, directory, digest, ".catalog.new");
    defer allocator.free(catalog_stage);
    const config_backup = try pathFor(allocator, directory, digest, ".config.old");
    defer allocator.free(config_backup);
    const catalog_backup = try pathFor(allocator, directory, digest, ".catalog.old");
    defer allocator.free(catalog_backup);
    const old_config = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(old_config);
    const old_catalog_present = pathExists(io, catalog_path);
    const old_catalog = if (old_catalog_present) try std.Io.Dir.cwd().readFileAlloc(io, catalog_path, allocator, .limited(16 * 1024 * 1024)) else try allocator.dupe(u8, "");
    defer allocator.free(old_catalog);
    var old_config_sha: [64]u8 = undefined;
    var new_config_sha: [64]u8 = undefined;
    var old_catalog_sha: [64]u8 = undefined;
    var new_catalog_sha: [64]u8 = undefined;
    hash(old_config, &old_config_sha);
    hash(new_config, &new_config_sha);
    hash(old_catalog, &old_catalog_sha);
    hash(new_catalog, &new_catalog_sha);
    try dhcp_store.atomicWrite(io, config_stage, new_config);
    try dhcp_store.atomicWrite(io, catalog_stage, new_catalog);
    try dhcp_store.atomicWrite(io, config_backup, old_config);
    if (old_catalog_present) try dhcp_store.atomicWrite(io, catalog_backup, old_catalog);
    for (moves) |move| {
        if (!validMoveSource(io, move.old) or pathExists(io, move.new)) return error.InvalidMovePrecondition;
    }
    var journal: Journal = .{ .plan_digest = digest, .state = .prepared, .config_path = config_path, .catalog_path = catalog_path, .config_stage = config_stage, .catalog_stage = catalog_stage, .config_backup = config_backup, .catalog_backup = catalog_backup, .old_config_sha256 = &old_config_sha, .new_config_sha256 = &new_config_sha, .old_catalog_sha256 = &old_catalog_sha, .new_catalog_sha256 = &new_catalog_sha, .old_catalog_present = old_catalog_present, .moves = moves };
    try saveJournal(io, allocator, journal_path, journal);
    if (crash == .after_prepared) return error.InjectedCrash;
    for (moves) |move| try std.Io.Dir.rename(std.Io.Dir.cwd(), move.old, std.Io.Dir.cwd(), move.new, io);
    journal.state = .files_ready;
    try saveJournal(io, allocator, journal_path, journal);
    if (crash == .after_files_ready) return error.InjectedCrash;
    try std.Io.Dir.rename(std.Io.Dir.cwd(), catalog_stage, std.Io.Dir.cwd(), catalog_path, io);
    journal.state = .catalog_committed;
    try saveJournal(io, allocator, journal_path, journal);
    if (crash == .after_catalog) return error.InjectedCrash;
    try std.Io.Dir.rename(std.Io.Dir.cwd(), config_stage, std.Io.Dir.cwd(), config_path, io);
    journal.state = .config_committed;
    try saveJournal(io, allocator, journal_path, journal);
    if (crash == .after_config) return error.InjectedCrash;
    journal.state = .complete;
    try saveJournal(io, allocator, journal_path, journal);
    cleanup(io, journal_path, journal);
}

pub fn recoverAll(io: std.Io, allocator: std.mem.Allocator, directory: []const u8) !usize {
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);
    var names = std.ArrayList([]u8).empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| if (entry.kind == .file and entry.name.len == 69 and std.mem.endsWith(u8, entry.name, ".json")) try names.append(allocator, try allocator.dupe(u8, entry.name));
    var count: usize = 0;
    for (names.items) |name| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
        defer allocator.free(path);
        try recoverOne(io, allocator, path);
        count += 1;
    }
    return count;
}

fn recoverOne(io: std.Io, allocator: std.mem.Allocator, journal_path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, journal_path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Journal, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const journal = parsed.value;
    if (journal.schema_version != 1 or journal.plan_digest.len != 64) return error.ModelTransactionRecoveryFailed;
    switch (journal.state) {
        .prepared, .files_ready => {
            if (!try fileHashEquals(io, allocator, journal.config_path, journal.old_config_sha256) or !try restoreOldCatalog(io, allocator, journal)) return error.ModelTransactionRecoveryFailed;
            try rollbackMoves(io, journal.moves);
            try saveRecoveryRecord(io, allocator, journal_path, journal.plan_digest, .rolled_back);
            cleanup(io, journal_path, journal);
        },
        .catalog_committed => {
            if (!try fileHashEquals(io, allocator, journal.catalog_path, journal.new_catalog_sha256)) return error.ModelTransactionRecoveryFailed;
            if (try fileHashEquals(io, allocator, journal.config_path, journal.new_config_sha256)) {
                try saveRecoveryRecord(io, allocator, journal_path, journal.plan_digest, .committed);
                cleanup(io, journal_path, journal);
                return;
            }
            if (!try fileHashEquals(io, allocator, journal.config_path, journal.old_config_sha256) or !try fileHashEquals(io, allocator, journal.config_stage, journal.new_config_sha256)) return error.ModelTransactionRecoveryFailed;
            try std.Io.Dir.rename(std.Io.Dir.cwd(), journal.config_stage, std.Io.Dir.cwd(), journal.config_path, io);
            if (!try fileHashEquals(io, allocator, journal.config_path, journal.new_config_sha256)) return error.ModelTransactionRecoveryFailed;
            try saveRecoveryRecord(io, allocator, journal_path, journal.plan_digest, .committed);
            cleanup(io, journal_path, journal);
        },
        .config_committed, .complete, .cleanup_pending => {
            if (!try fileHashEquals(io, allocator, journal.catalog_path, journal.new_catalog_sha256) or !try fileHashEquals(io, allocator, journal.config_path, journal.new_config_sha256)) return error.ModelTransactionRecoveryFailed;
            try saveRecoveryRecord(io, allocator, journal_path, journal.plan_digest, .committed);
            cleanup(io, journal_path, journal);
        },
    }
}

fn saveRecoveryRecord(io: std.Io, allocator: std.mem.Allocator, journal_path: []const u8, digest: []const u8, outcome: RecoveryOutcome) !void {
    const record_path = try std.fmt.allocPrint(allocator, "{s}.recovered", .{journal_path});
    defer allocator.free(record_path);
    const bytes = try std.json.Stringify.valueAlloc(allocator, RecoveryRecord{ .plan_digest = digest, .outcome = outcome }, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    try dhcp_store.atomicWrite(io, record_path, bytes);
    try chmod(io, allocator, "600", record_path);
}

fn saveJournal(io: std.Io, allocator: std.mem.Allocator, path: []const u8, journal: Journal) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, journal, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    try dhcp_store.atomicWrite(io, path, bytes);
    try chmod(io, allocator, "600", path);
}
fn cleanup(io: std.Io, journal_path: []const u8, journal: Journal) void {
    inline for ([_][]const u8{ journal.config_stage, journal.catalog_stage, journal.config_backup, journal.catalog_backup, journal_path }) |path| std.Io.Dir.cwd().deleteFile(io, path) catch {};
}
fn rollbackMoves(io: std.Io, moves: []const Move) !void {
    var index = moves.len;
    while (index != 0) {
        index -= 1;
        const move = moves[index];
        const old_exists = pathExists(io, move.old);
        const new_exists = pathExists(io, move.new);
        if (old_exists and !new_exists) continue;
        if (!old_exists and new_exists) {
            try std.Io.Dir.rename(std.Io.Dir.cwd(), move.new, std.Io.Dir.cwd(), move.old, io);
            continue;
        }
        return error.ModelTransactionRecoveryFailed;
    }
}
fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}
fn validMoveSource(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .file or stat.kind == .directory;
}
fn pathFor(allocator: std.mem.Allocator, directory: []const u8, digest: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ directory, digest, suffix });
}
fn hash(bytes: []const u8, output: *[64]u8) void {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    _ = std.fmt.bufPrint(output, "{x}", .{raw}) catch unreachable;
}
fn fileHashEquals(io: std.Io, allocator: std.mem.Allocator, path: []const u8, expected: []const u8) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch return false;
    defer allocator.free(bytes);
    var actual: [64]u8 = undefined;
    hash(bytes, &actual);
    return std.mem.eql(u8, &actual, expected);
}
fn restoreOldCatalog(io: std.Io, allocator: std.mem.Allocator, journal: Journal) !bool {
    if (journal.old_catalog_present) {
        if (try fileHashEquals(io, allocator, journal.catalog_path, journal.old_catalog_sha256)) return true;
        if (!try fileHashEquals(io, allocator, journal.catalog_path, journal.new_catalog_sha256) or !try fileHashEquals(io, allocator, journal.catalog_backup, journal.old_catalog_sha256)) return false;
        try std.Io.Dir.rename(std.Io.Dir.cwd(), journal.catalog_backup, std.Io.Dir.cwd(), journal.catalog_path, io);
        return try fileHashEquals(io, allocator, journal.catalog_path, journal.old_catalog_sha256);
    }
    if (!pathExists(io, journal.catalog_path)) return true;
    if (!try fileHashEquals(io, allocator, journal.catalog_path, journal.new_catalog_sha256)) return false;
    try std.Io.Dir.cwd().deleteFile(io, journal.catalog_path);
    return true;
}
fn chmod(io: std.Io, allocator: std.mem.Allocator, mode: []const u8, path: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "chmod", mode, path }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.PermissionUpdateFailed,
        else => return error.PermissionUpdateFailed,
    }
}

test "recovery rolls back pre-commit and completes split commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(relative_root);
    const root = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative_root, std.testing.allocator);
    defer std.testing.allocator.free(root);
    const tx = try std.fmt.allocPrint(std.testing.allocator, "{s}/tx", .{root});
    defer std.testing.allocator.free(tx);
    const config = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{root});
    defer std.testing.allocator.free(config);
    const catalog = try std.fmt.allocPrint(std.testing.allocator, "{s}/catalog.json", .{root});
    defer std.testing.allocator.free(catalog);
    try dhcp_store.atomicWrite(std.testing.io, config, "old-config");
    try dhcp_store.atomicWrite(std.testing.io, catalog, "old-catalog");
    const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const old_asset = try std.fmt.allocPrint(std.testing.allocator, "{s}/old.asset", .{root});
    defer std.testing.allocator.free(old_asset);
    const new_asset = try std.fmt.allocPrint(std.testing.allocator, "{s}/new.asset", .{root});
    defer std.testing.allocator.free(new_asset);
    try dhcp_store.atomicWrite(std.testing.io, old_asset, "asset");
    const moves = [_]Move{.{ .old = old_asset, .new = new_asset }};
    try std.testing.expectError(error.InjectedCrash, commit(std.testing.io, std.testing.allocator, tx, digest, config, catalog, "new-config", "new-catalog", &moves, .after_files_ready));
    try std.testing.expectEqual(@as(usize, 1), try recoverAll(std.testing.io, std.testing.allocator, tx));
    var old_expected: [64]u8 = undefined;
    hash("old-config", &old_expected);
    try std.testing.expect(try fileHashEquals(std.testing.io, std.testing.allocator, config, &old_expected));
    try std.testing.expect(pathExists(std.testing.io, old_asset));
    try std.testing.expectError(error.InjectedCrash, commit(std.testing.io, std.testing.allocator, tx, digest, config, catalog, "new-config", "new-catalog", &moves, .after_catalog));
    try std.testing.expectEqual(@as(usize, 1), try recoverAll(std.testing.io, std.testing.allocator, tx));
    var expected: [64]u8 = undefined;
    hash("new-config", &expected);
    try std.testing.expect(try fileHashEquals(std.testing.io, std.testing.allocator, config, &expected));
    try std.testing.expect(pathExists(std.testing.io, new_asset));
}
