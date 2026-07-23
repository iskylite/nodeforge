//! 可崩溃恢复的 schema-v3 发布事务，同时覆盖启动配置和 catalog 目录清单。
//!
//! 本模块实现日志驱动的两阶段提交（2PC），确保 config + catalog 的原子升级。
//! 事务的生命周期由 `State` 状态机驱动，journal 文件持久化每个阶段的进度。
//! daemon 启动时调用 `recoverAll` 对未完成的事务进行崩溃恢复——恢复策略
//! 依赖内容哈希而非最后一次 journal 写入来判断哪一侧是权威的，因为 prepared
//! 状态可能在 catalog manifest commit 前后崩溃。
//!
//! ## 两阶段提交流程
//!
//! 1. **prepare**：将新旧 config 和 catalog 的备份文件原子写入事务目录，
//!    计算各自的 SHA-256 校验值，写入 journal（state=prepared）。
//! 2. **catalog commit**：将新 catalog 保存到正式路径，更新 journal
//!    （state=catalog_committed）。
//! 3. **config commit**：将新 config 原子写入正式路径，更新 journal
//!    （state=complete）。
//!
//! ## 崩溃恢复
//!
//! `recoverAll` 在 daemon 启动时、config/catalog 解析之前运行。对于状态为
//! `prepared` 或 `catalog_committed` 的事务，通过比较当前 catalog 的 SHA-256
//! 与 journal 记录的 new/old catalog SHA-256 来判断哪一侧是权威的：
//! - 匹配 new：catalog 已成功提交，补写 config 并标记 complete。
//! - 匹配 old：catalog 未提交，标记 rolled_back。
//! - 都不匹配：返回 `SchemaV3RecoveryFailed`（数据损坏）。

const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const schema_v4 = @import("../catalog/schema_v4.zig");
const config_store = @import("../config/store.zig");
const atomicWrite = @import("dhcp_store.zig").atomicWrite;

/// 事务状态机的四个阶段。journal 在每次状态转换时被原子重写。
pub const State = enum {
    /// 备份文件和 journal 已写入，catalog 和 config 均未提交。
    prepared,
    /// catalog manifest 已保存到正式路径，config 尚未提交。
    catalog_committed,
    /// config 和 catalog 均已提交到正式路径，事务完成。
    complete,
    /// 已用旧备份回滚 config 和 catalog 到事务前的状态。
    rolled_back,
};

/// 持久化的事务日志。每次状态转换时通过原子写（temp + rename + fsync）重写。
/// SHA-256 校验值用于崩溃恢复时验证备份文件完整性，而非依赖 journal
/// 的最后写入状态——因为 journal 写入和文件系统之间可能存在崩溃窗口。
const Journal = struct {
    /// journal 格式版本；当前固定为 1。
    schema_version: u32 = 1,
    /// 触发本次事务的 64 字符小写十六进制 plan digest。
    plan_digest: []const u8,
    /// 当前事务状态。
    state: State,
    /// config 正式路径（如 `config.json`）。
    config_path: []const u8,
    /// catalog 目录正式路径（如 `catalog`）。
    catalog_path: []const u8,
    /// 事务目录中旧 config 备份路径。
    old_config_path: []const u8,
    /// 事务目录中新 config 备份路径。
    new_config_path: []const u8,
    /// 事务目录中旧 catalog JSON 备份路径。
    old_catalog_path: []const u8,
    /// 事务目录中新 catalog JSON 备份路径。
    new_catalog_path: []const u8,
    /// 旧 config 内容的 SHA-256（64 字符小写十六进制）。
    old_config_sha256: []const u8,
    /// 新 config 内容的 SHA-256。
    new_config_sha256: []const u8,
    /// 旧 catalog JSON 内容的 SHA-256。
    old_catalog_sha256: []const u8,
    /// 新 catalog JSON 内容的 SHA-256。
    new_catalog_sha256: []const u8,
};

/// 执行 schema-v3 发布事务：原子地将新 config 和新 catalog 提交到正式路径。
///
/// 提交按三阶段进行（prepare → catalog commit → config commit），每阶段
/// 都通过原子写更新 journal。如果同 digest 的事务已存在（journal 文件
/// 已存在），返回 `TransactionAlreadyExists` 防止重复提交。
///
/// 参数：
/// - `directory`：事务文件目录（journal 和备份文件的存放位置）。
/// - `digest`：64 字符 plan digest，用作事务唯一标识和文件名前缀。
/// - `config_path`/`catalog_path`：正式路径，事务完成后新内容写入此处。
/// - `new_config`/`new_catalog`：待提交的新内容。
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
    // digest 必须是 64 字符十六进制，作为事务文件名前缀和唯一标识。
    if (digest.len != 64) return error.InvalidPlanDigest;
    try std.Io.Dir.cwd().createDirPath(io, directory);
    const journal_path = try pathFor(allocator, directory, digest, ".schema-v3.json");
    defer allocator.free(journal_path);
    // 防止重复提交：同 digest 的事务已存在说明上一次提交可能未完成或已成功。
    if (exists(io, journal_path)) return error.TransactionAlreadyExists;
    const old_config_path = try pathFor(allocator, directory, digest, ".schema-v3.config.old");
    defer allocator.free(old_config_path);
    const new_config_path = try pathFor(allocator, directory, digest, ".schema-v3.config.new");
    defer allocator.free(new_config_path);
    const old_catalog_path = try pathFor(allocator, directory, digest, ".schema-v3.catalog.old");
    defer allocator.free(old_catalog_path);
    const new_catalog_path = try pathFor(allocator, directory, digest, ".schema-v3.catalog.new");
    defer allocator.free(new_catalog_path);

    // 读取当前正式路径上的旧 config 和旧 catalog，作为回滚备份和校验基准。
    const old_config = try std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(old_config);
    var old_catalog = try catalog_store.load(io, allocator, catalog_path);
    defer old_catalog.deinit();
    const old_catalog_json = try catalog_store.render(allocator, &old_catalog.value);
    defer allocator.free(old_catalog_json);
    const new_catalog_json = try catalog_store.render(allocator, new_catalog);
    defer allocator.free(new_catalog_json);
    // 计算四份内容的 SHA-256 校验值，用于崩溃恢复时判断哪一侧是权威的。
    var old_config_sha: [64]u8 = undefined;
    var new_config_sha: [64]u8 = undefined;
    var old_catalog_sha: [64]u8 = undefined;
    var new_catalog_sha: [64]u8 = undefined;
    sha256(old_config, &old_config_sha);
    sha256(new_config, &new_config_sha);
    sha256(old_catalog_json, &old_catalog_sha);
    sha256(new_catalog_json, &new_catalog_sha);
    // 阶段 1（prepare）：将四份备份文件原子写入事务目录。
    // 备份文件在崩溃恢复和 rollback 时通过 SHA-256 校验后使用。
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
    // 写入 journal 标记 prepared，此时备份文件已就绪但正式路径未变更。
    try saveJournal(io, allocator, journal_path, journal);
    // 阶段 2（catalog commit）：将新 catalog 保存到正式路径。
    // catalog_store.save 内部使用 manifest 原子写协议。
    try catalog_store.save(io, allocator, catalog_path, new_catalog);
    journal.state = .catalog_committed;
    try saveJournal(io, allocator, journal_path, journal);
    // 阶段 3（config commit）：将新 config 原子写入正式路径。
    // 到此为止事务完成，config 和 catalog 均已更新到新版本。
    try atomicWrite(io, config_path, new_config);
    journal.state = .complete;
    try saveJournal(io, allocator, journal_path, journal);
}

/// 回滚一个已完成的 schema-v3 事务，将 config 和 catalog 恢复到旧版本。
///
/// 仅 `complete` 状态的事务可以回滚——因为只有此时 config 和 catalog 都
/// 已提交到正式路径。回滚操作从备份文件恢复旧内容，每份文件都通过 SHA-256
/// 校验确保完整性。回滚后 journal 标记为 `rolled_back`。
///
/// 参数：
/// - `directory`：事务文件目录。
/// - `digest`：目标事务的 64 字符 plan digest。
pub fn rollback(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, digest: []const u8) !void {
    const journal_path = try pathFor(allocator, directory, digest, ".schema-v3.json");
    defer allocator.free(journal_path);
    var parsed = try loadJournal(io, allocator, journal_path);
    defer parsed.deinit();
    // 只有 complete 事务才能回滚，未完成的事务应通过 recoverAll 处理。
    if (parsed.value.state != .complete) return error.TransactionNotCommitted;
    // 从备份恢复旧 config，校验 SHA-256 完整性。
    const old_config = try verifiedFile(io, allocator, parsed.value.old_config_path, parsed.value.old_config_sha256);
    defer allocator.free(old_config);
    // 从备份恢复旧 catalog JSON，校验后解析为 model.Catalog。
    var old_catalog = try loadCatalogFile(io, allocator, parsed.value.old_catalog_path, parsed.value.old_catalog_sha256);
    defer old_catalog.deinit();
    // 先回滚 catalog manifest，再回滚 config。
    try catalog_store.save(io, allocator, parsed.value.catalog_path, &old_catalog.value);
    try atomicWrite(io, parsed.value.config_path, old_config);
    parsed.value.state = .rolled_back;
    try saveJournal(io, allocator, journal_path, parsed.value);
}

/// 在 daemon 启动时、config/catalog 解析之前运行，恢复所有未完成的 schema-v3 事务。
///
/// 遍历事务目录中所有 `.schema-v3.json` journal 文件。对于状态为 `prepared`
/// 或 `catalog_committed` 的事务，通过比较当前 catalog 的 SHA-256 与 journal
/// 记录的 new/old catalog SHA-256 来判断哪一侧是权威的：
/// - 匹配 new_catalog_sha256：catalog 已成功提交，补写新 config 并标记 complete。
/// - 匹配 old_catalog_sha256：catalog 未提交（仍在旧版本），标记 rolled_back。
/// - 都不匹配：数据损坏，返回 `SchemaV3RecoveryFailed`。
///
/// 之所以使用内容哈希而非 journal 最后状态，是因为 prepared 状态可能在
/// catalog manifest commit 前后崩溃，journal 写入和文件系统之间的崩溃窗口
/// 会导致 journal 状态与实际文件不一致。
///
/// 参数：
/// - `directory`：事务文件目录。不存在则返回 0（无事务可恢复）。
///
/// 返回恢复的事务数量。
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
    // 先收集所有 journal 文件名，避免在迭代目录时并发修改。
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".schema-v3.json"))
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    var recovered: usize = 0;
    for (names.items) |name| {
        const journal_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
        defer allocator.free(journal_path);
        var parsed = try loadJournal(io, allocator, journal_path);
        defer parsed.deinit();
        // complete 和 rolled_back 是终态，无需恢复。
        if (parsed.value.state == .complete or parsed.value.state == .rolled_back) continue;
        // 加载当前正式路径上的 catalog 并渲染为 JSON，计算其 SHA-256。
        var current = try catalog_store.load(io, allocator, parsed.value.catalog_path);
        defer current.deinit();
        const rendered = try catalog_store.render(allocator, &current.value);
        defer allocator.free(rendered);
        var current_sha: [64]u8 = undefined;
        sha256(rendered, &current_sha);
        // 判断当前 catalog 匹配哪一侧（new 还是 old）。
        if (std.mem.eql(u8, &current_sha, parsed.value.new_catalog_sha256)) {
            // catalog 已提交到新版本，但 config 可能未写入——补写新 config。
            const next_config = try verifiedFile(io, allocator, parsed.value.new_config_path, parsed.value.new_config_sha256);
            defer allocator.free(next_config);
            try atomicWrite(io, parsed.value.config_path, next_config);
            parsed.value.state = .complete;
        } else if (std.mem.eql(u8, &current_sha, parsed.value.old_catalog_sha256)) {
            // catalog 仍在旧版本，说明 catalog commit 未完成——标记为回滚。
            parsed.value.state = .rolled_back;
        } else return error.SchemaV3RecoveryFailed;
        try saveJournal(io, allocator, journal_path, parsed.value);
        recovered += 1;
    }
    return recovered;
}

/// 从校验过的备份文件加载并解析 catalog JSON。
/// 先通过 `verifiedFile` 校验 SHA-256 完整性，再解析为 `model.Catalog`。
fn loadCatalogFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, digest: []const u8) !std.json.Parsed(model.Catalog) {
    const bytes = try verifiedFile(io, allocator, path, digest);
    defer allocator.free(bytes);
    return std.json.parseFromSlice(model.Catalog, allocator, bytes, .{ .allocate = .alloc_always });
}

/// 读取文件并校验其 SHA-256 是否与期望的 digest 匹配。
/// 校验失败返回 `SchemaV3BackupDigestMismatch`，确保备份文件未被篡改或损坏。
fn verifiedFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, digest: []const u8) ![]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    errdefer allocator.free(bytes);
    var actual: [64]u8 = undefined;
    sha256(bytes, &actual);
    if (!std.mem.eql(u8, &actual, digest)) return error.SchemaV3BackupDigestMismatch;
    return bytes;
}

/// 加载并校验 journal 文件。验证 schema_version 为 1 且 plan_digest
/// 长度为 64，否则返回 `InvalidSchemaV3Journal`。
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

/// 将 journal 序列化为 JSON 并通过原子写协议保存。
/// 使用 indent_2 格式以便运维人员可直接阅读 journal 内容。
fn saveJournal(io: std.Io, allocator: std.mem.Allocator, path: []const u8, journal: Journal) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, journal, .{ .whitespace = .indent_2 });
    defer allocator.free(bytes);
    try atomicWrite(io, path, bytes);
}

/// 构造事务目录中的文件路径：`{directory}/{digest}{suffix}`。
/// 所有事务文件都以 digest 为前缀，确保同一目录下不同事务的文件互不冲突。
fn pathFor(allocator: std.mem.Allocator, directory: []const u8, digest: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ directory, digest, suffix });
}

/// 检查文件是否存在（通过 statFile，不跟随符号链接）。
fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

/// 计算字节内容的 SHA-256 并输出为 64 字符小写十六进制字符串。
/// 用于 journal 中记录的校验值和崩溃恢复时的内容比对。
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

test "schema-v4 migration commits diskless-ready catalog and rolls back to v3" {
    // Phase 1b 契约：v4 apply 经同一 2PC 事务持久化 config+catalog，schema_version
    // 升至 4 且 Profile 显式 wrap 为 install；rollback 恢复 v3 备份。事务机制与 v3
    // 完全复用，仅内容（schema_version=4 的 catalog）不同。
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
    const old_config = "{\"schema_version\":3,\"server\":{\"server_ip\":\"192.0.2.1\"}}\n";
    try atomicWrite(std.testing.io, config_path, old_config);
    try catalog_store.initializeEmpty(std.testing.io, std.testing.allocator, catalog_path);
    const profile: model.ProfileConfig = .{ .name = "rocky-install", .install_source = "s" };
    const source: model.InstallSourceConfig = .{ .name = "s", .distro = "rocky", .version = "9", .arch = .aarch64, .source_asset = "iso", .installer_kernel = "k", .installer_initrd = "i" };
    const nodes = [_]model.NodeConfig{.{ .id = "n1", .mac = "02:00:00:00:00:01", .arch = .aarch64, .profile = "rocky-install" }};
    const old_catalog: model.Catalog = .{ .schema_version = 3, .profiles = &.{profile}, .nodes = &nodes, .install_sources = &.{source} };
    try catalog_store.save(std.testing.io, std.testing.allocator, catalog_path, &old_catalog);
    var loaded = try catalog_store.load(std.testing.io, std.testing.allocator, catalog_path);
    defer loaded.deinit();
    const config: model.AppConfig = .{ .schema_version = 3, .server = .{ .server_ip = "192.0.2.1" } };
    var plan = try schema_v4.build(std.testing.allocator, &config, &loaded.value, 1, loaded.value.revision);
    defer plan.deinit();
    try std.testing.expect(plan.applicable());
    var candidate = try schema_v4.candidates(std.testing.allocator, &config, &loaded.value, &plan);
    defer candidate.deinit();
    try std.testing.expectEqual(@as(u32, 4), candidate.catalog.value.schema_version);
    try std.testing.expectEqual(model.ProfileKind.install, candidate.catalog.value.profiles[0].kind);
    const new_config = try config_store.render(std.testing.allocator, &candidate.config.value);
    defer std.testing.allocator.free(new_config);
    try std.testing.expect(std.mem.indexOf(u8, new_config, "\"schema_version\": 4") != null);
    try commit(std.testing.io, std.testing.allocator, tx_path, &plan.digest, config_path, catalog_path, new_config, &candidate.catalog.value);
    const committed_config = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(committed_config);
    try std.testing.expect(std.mem.indexOf(u8, committed_config, "\"schema_version\": 4") != null);
    var committed_catalog = try catalog_store.load(std.testing.io, std.testing.allocator, catalog_path);
    defer committed_catalog.deinit();
    try std.testing.expectEqual(@as(u32, 4), committed_catalog.value.schema_version);
    try std.testing.expectEqual(model.ProfileKind.install, committed_catalog.value.profiles[0].kind);
    try rollback(std.testing.io, std.testing.allocator, tx_path, &plan.digest);
    const restored_config = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(restored_config);
    try std.testing.expectEqualStrings(old_config, restored_config);
    var restored_catalog = try catalog_store.load(std.testing.io, std.testing.allocator, catalog_path);
    defer restored_catalog.deinit();
    try std.testing.expectEqual(@as(u32, 3), restored_catalog.value.schema_version);
}
