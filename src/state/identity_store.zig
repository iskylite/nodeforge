//! # v0.2.3 SSH Identity Store
//!
//! daemon-owned identity store for Profile SSH key pairs. Independent from
//! `daemon_secret` (state/diskless-secret, the HMAC master secret for durable
//! diskless-event, first-boot, and discovery tokens). Random boot-session
//! capabilities do not depend on this secret.
//!
//! Storage path: `<install-root>/state/identities.json` (0600)
//! Key generation/verification staging: `<install-root>/state/identity-staging` (0700)
//!
//! Logical primary key is the **(id, revision)** composite key. The same `id`
//! can hold multiple immutable revisions; the same composite key must not repeat.
//! Identity records are immutable after creation. All reads must match both
//! `id` and `revision` from the catalog reference.
//!
//! Load 校验（fail closed，daemon 拒启）：
//! - schema_version、`(id, revision)` 复合键重复、`revision == 0`、id/密钥长度
//!   越界 → `InvalidIdentityStore`；
//! - 公钥指纹用纯 Zig 重算（`server/admin_key.zig` `fingerprint`，与
//!   `ssh-keygen -lf` 输出一致）并与持久化指纹比对；
//! - private/public 用 `ssh-keygen -y` 派生比对（私钥写入暂存目录 0600，
//!   校验后立即删除）。
//!
//! §4.2 两阶段发布（identity + catalog 原子性）：`create`/`createRevision`
//! 携带 `IdentityTx` 时先在 `state/identity-transactions/<txid>.json` 写入
//! prepared journal（0600），再持久化 identities.json；调用方发布 catalog 后
//! `commit` 删除 journal，失败则 `rollback`。daemon 启动在 serve 前调用
//! `recoverPendingTransactions`：catalog 已引用且指纹匹配 → 收尾提交；未引用 →
//! 幂等回滚；已引用但缺失/不匹配 → fail closed（`IdentityRecoveryFailed`）。
const std = @import("std");
const dhcp_store = @import("dhcp_store.zig");
const paths = @import("../paths.zig");
const admin_key = @import("../server/admin_key.zig");
const model = @import("../model.zig");

pub const id_len: usize = 32;
pub const fingerprint_cap: usize = 80;
pub const key_cap: usize = 4096;
pub const max_identities: usize = 256;
pub const schema_version: u32 = 1;

pub const IdentityRecord = struct {
    id: [id_len]u8 = [_]u8{0} ** id_len,
    revision: u64 = 1,
    created_at: i64 = 0,
    client_private_key: [key_cap]u8 = [_]u8{0} ** key_cap,
    client_private_key_len: u32 = 0,
    client_public_key: [key_cap]u8 = [_]u8{0} ** key_cap,
    client_public_key_len: u32 = 0,
    host_private_key: [key_cap]u8 = [_]u8{0} ** key_cap,
    host_private_key_len: u32 = 0,
    host_public_key: [key_cap]u8 = [_]u8{0} ** key_cap,
    host_public_key_len: u32 = 0,
    client_public_fingerprint: [fingerprint_cap]u8 = [_]u8{0} ** fingerprint_cap,
    client_public_fingerprint_len: u8 = 0,
    host_public_fingerprint: [fingerprint_cap]u8 = [_]u8{0} ** fingerprint_cap,
    host_public_fingerprint_len: u8 = 0,

    pub fn idSlice(self: *const IdentityRecord) []const u8 {
        return &self.id;
    }
    pub fn clientPrivateKey(self: *const IdentityRecord) []const u8 {
        return self.client_private_key[0..self.client_private_key_len];
    }
    pub fn clientPublicKey(self: *const IdentityRecord) []const u8 {
        return self.client_public_key[0..self.client_public_key_len];
    }
    pub fn hostPrivateKey(self: *const IdentityRecord) []const u8 {
        return self.host_private_key[0..self.host_private_key_len];
    }
    pub fn hostPublicKey(self: *const IdentityRecord) []const u8 {
        return self.host_public_key[0..self.host_public_key_len];
    }
    pub fn clientFingerprint(self: *const IdentityRecord) []const u8 {
        return self.client_public_fingerprint[0..self.client_public_fingerprint_len];
    }
    pub fn hostFingerprint(self: *const IdentityRecord) []const u8 {
        return self.host_public_fingerprint[0..self.host_public_fingerprint_len];
    }
};

/// v0.2.3: 两阶段发布 journal（`<state>/identity-transactions/<txid>.json`）。
/// 记录旧 catalog revision、待增加的 `(id, revision)` 复合键和目标 Profile；
/// daemon 启动恢复按 §4.2 用它判断事务是已提交（catalog 已引用）还是需回滚。
pub const IdentityTransaction = struct {
    schema_version: u32 = 1,
    /// 64 位小写 hex，同时作为 journal 文件名（`<txid>.json`）。
    transaction_id: []const u8,
    /// 事务开始时的 catalog revision（恢复时仅作日志与健全性参考）。
    old_catalog_revision: u64,
    /// 目标 Profile 名称；恢复时据其在 catalog 中的 ssh_identity 引用定位。
    profile_name: []const u8,
    /// 待发布 identity 复合键。
    id: []const u8,
    revision: u64,
    created_at: i64,
};

/// create/createRevision 的可选两阶段事务参数。调用方先填充前三个字段；
/// 成功后 `transaction_id` 被填充为归调用者所有的 64 hex，须传给 commit/rollback。
pub const IdentityTx = struct {
    old_catalog_revision: u64,
    profile_name: []const u8,
    created_at: i64,
    transaction_id: ?[]u8 = null,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    /// v0.2.3: 密钥生成/校验暂存目录（0700）。daemon 启动时由 `app.zig` 注入
    /// `paths.require().identity_staging_dir` 并 mkdir；为空时 create 系列
    /// 拒绝工作（测试可指向临时目录）。
    staging_dir: []const u8 = "",
    /// v0.2.3: 两阶段事务 journal 目录（0700）。daemon 启动时由 `app.zig`
    /// 注入 `paths.require().identity_transactions_dir`；为空时 prepare/commit/
    /// rollback/recover 拒绝工作。
    transactions_dir: []const u8 = "",
    mutex: std.atomic.Mutex = .unlocked,
    identities: [max_identities]IdentityRecord = [_]IdentityRecord{.{}} ** max_identities,
    count: usize = 0,
    loaded: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Store {
        return .{ .allocator = allocator, .path = path };
    }

    pub fn deinit(self: *Store) void {
        _ = self;
    }

    /// Load identity store from disk. If file doesn't exist, creates empty store.
    /// On file corruption, schema/length violation, composite-key duplication,
    /// fingerprint mismatch, or key pair inconsistency: fail closed (daemon
    /// refuses to start).
    pub fn load(self: *Store, io: std.Io) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (self.loaded) return;
        if (self.path.len == 0) {
            self.loaded = true;
            return;
        }
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, self.path, self.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                self.loaded = true;
                return;
            },
            else => return err,
        };
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(PersistedFile, self.allocator, bytes, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value.schema_version != schema_version) return error.InvalidIdentityStore;
        if (parsed.value.identities.len > max_identities) return error.InvalidIdentityStore;
        // 先解析到局部数组，全部校验通过后再一次性提交：任一记录失败时
        // `self.identities`/`self.count` 保持原状，调用方重试不会重复追加。
        var staged: [max_identities]IdentityRecord = undefined;
        var staged_count: usize = 0;
        for (parsed.value.identities) |item| {
            const record = try restoreRecord(self.allocator, io, self.staging_dir, item);
            // (id, revision) 复合键去重。
            for (staged[0..staged_count]) |*prior| {
                if (std.mem.eql(u8, &prior.id, &record.id) and prior.revision == record.revision)
                    return error.InvalidIdentityStore;
            }
            staged[staged_count] = record;
            staged_count += 1;
        }
        @memcpy(self.identities[0..staged_count], staged[0..staged_count]);
        self.count = staged_count;
        self.loaded = true;
    }

    /// Create a new identity with fresh ed25519 key pair. Returns the composite
    /// key (id, revision=1) and fingerprints. Uses `ssh-keygen` to generate keys
    /// in `self.staging_dir` (never `/tmp`); staging material is removed
    /// unconditionally on success and failure.
    ///
    /// `journal` 非空时启用 §4.2 两阶段发布：在持久化新记录**之前**原子写入
    /// prepared journal（崩溃时启动恢复据 catalog 引用决定提交或回滚），成功
    /// 后把事务 id 填入 `journal.transaction_id`；调用方须随后发布 catalog。
    /// catalog 落盘前失败时 `rollback`；落盘后先解除 rollback 再 `commit`，
    /// commit 失败保留 identity+journal 供启动恢复收尾。
    pub fn create(self: *Store, io: std.Io, allocator: std.mem.Allocator, now: i64, journal: ?*IdentityTx) !IdentityRef {
        lock(&self.mutex);
        defer self.mutex.unlock();

        if (self.count >= max_identities) return error.IdentityStoreCapacity;
        if (self.staging_dir.len == 0) return error.IdentityStagingDirUnset;

        var id: [id_len]u8 = undefined;
        try generateId(io, &id);

        const staging = try std.fmt.allocPrint(allocator, "{s}/identity-{s}", .{ self.staging_dir, id });
        defer allocator.free(staging);
        const client_key = try std.fmt.allocPrint(allocator, "{s}-client", .{staging});
        defer allocator.free(client_key);
        const host_key = try std.fmt.allocPrint(allocator, "{s}-host", .{staging});
        defer allocator.free(host_key);
        const client_pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{client_key});
        defer allocator.free(client_pub_path);
        const host_pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{host_key});
        defer allocator.free(host_pub_path);

        // 生成前先删除残留目标，避免 ssh-keygen 对已存在文件交互式询问
        // "Overwrite?" 导致生成挂起；随后无论成败都清理全部暂存密钥材料。
        removeFile(io, client_key);
        removeFile(io, client_pub_path);
        removeFile(io, host_key);
        removeFile(io, host_pub_path);
        defer {
            removeFile(io, client_key);
            removeFile(io, client_pub_path);
            removeFile(io, host_key);
            removeFile(io, host_pub_path);
        }

        try generateSshKey(allocator, io, client_key, "nodeforge-client");
        try generateSshKey(allocator, io, host_key, "nodeforge-host");

        const client_private = try readFileAlloc(allocator, io, client_key);
        defer zeroAndFree(allocator, client_private);
        const client_public = try readFileAlloc(allocator, io, client_pub_path);
        defer allocator.free(client_public);
        const host_private = try readFileAlloc(allocator, io, host_key);
        defer zeroAndFree(allocator, host_private);
        const host_public = try readFileAlloc(allocator, io, host_pub_path);
        defer allocator.free(host_public);

        const client_fp = try computeFingerprint(allocator, io, client_pub_path);
        defer allocator.free(client_fp);
        const host_fp = try computeFingerprint(allocator, io, host_pub_path);
        defer allocator.free(host_fp);

        const idx = self.count;
        try fillSlot(&self.identities[idx], id, 1, now, client_private, client_public, host_private, host_public, client_fp, host_fp);
        self.count += 1;
        errdefer self.count -= 1; // persist 失败回滚，槽位下次覆盖
        if (journal) |tx| {
            tx.transaction_id = try self.prepareLocked(io, allocator, tx.old_catalog_revision, tx.profile_name, &id, 1, tx.created_at);
        }
        try self.persistLocked(io);

        // 返回指向稳定槽位的引用，不是栈副本；见 get() 的不变量文档。
        const stored = &self.identities[idx];
        return .{
            .id = &stored.id,
            .revision = stored.revision,
            .client_public_fingerprint = stored.clientFingerprint(),
            .host_public_fingerprint = stored.hostFingerprint(),
        };
    }

    /// Create a new revision of an existing identity (for --new-ssh-keys).
    /// Returns the new composite key (id, revision+1).
    ///
    /// `journal` 语义同 `create`：prepared journal 在新 revision 持久化前写入。
    pub fn createRevision(self: *Store, io: std.Io, allocator: std.mem.Allocator, id: []const u8, now: i64, journal: ?*IdentityTx) !IdentityRef {
        lock(&self.mutex);
        defer self.mutex.unlock();

        if (id.len != id_len) return error.InvalidIdentityId;
        // Find the existing identity to get its current max revision.
        var max_revision: u64 = 0;
        for (self.identities[0..self.count]) |r| {
            if (std.mem.eql(u8, &r.id, id) and r.revision > max_revision) {
                max_revision = r.revision;
            }
        }
        if (max_revision == 0) return error.IdentityNotFound;
        const next_revision = std.math.add(u64, max_revision, 1) catch return error.IdentityRevisionOverflow;

        if (self.count >= max_identities) return error.IdentityStoreCapacity;
        if (self.staging_dir.len == 0) return error.IdentityStagingDirUnset;

        const staging = try std.fmt.allocPrint(allocator, "{s}/identity-rev-{s}-{d}", .{ self.staging_dir, id, next_revision });
        defer allocator.free(staging);
        const client_key = try std.fmt.allocPrint(allocator, "{s}-client", .{staging});
        defer allocator.free(client_key);
        const host_key = try std.fmt.allocPrint(allocator, "{s}-host", .{staging});
        defer allocator.free(host_key);
        const client_pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{client_key});
        defer allocator.free(client_pub_path);
        const host_pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{host_key});
        defer allocator.free(host_pub_path);

        removeFile(io, client_key);
        removeFile(io, client_pub_path);
        removeFile(io, host_key);
        removeFile(io, host_pub_path);
        defer {
            removeFile(io, client_key);
            removeFile(io, client_pub_path);
            removeFile(io, host_key);
            removeFile(io, host_pub_path);
        }

        try generateSshKey(allocator, io, client_key, "nodeforge-client");
        try generateSshKey(allocator, io, host_key, "nodeforge-host");

        const client_private = try readFileAlloc(allocator, io, client_key);
        defer zeroAndFree(allocator, client_private);
        const client_public = try readFileAlloc(allocator, io, client_pub_path);
        defer allocator.free(client_public);
        const host_private = try readFileAlloc(allocator, io, host_key);
        defer zeroAndFree(allocator, host_private);
        const host_public = try readFileAlloc(allocator, io, host_pub_path);
        defer allocator.free(host_public);

        const client_fp = try computeFingerprint(allocator, io, client_pub_path);
        defer allocator.free(client_fp);
        const host_fp = try computeFingerprint(allocator, io, host_pub_path);
        defer allocator.free(host_fp);

        var id_buf: [id_len]u8 = undefined;
        @memcpy(&id_buf, id);
        const idx = self.count;
        try fillSlot(&self.identities[idx], id_buf, next_revision, now, client_private, client_public, host_private, host_public, client_fp, host_fp);
        self.count += 1;
        errdefer self.count -= 1;
        if (journal) |tx| {
            tx.transaction_id = try self.prepareLocked(io, allocator, tx.old_catalog_revision, tx.profile_name, &id_buf, next_revision, tx.created_at);
        }
        try self.persistLocked(io);

        const stored = &self.identities[idx];
        return .{
            .id = &stored.id,
            .revision = stored.revision,
            .client_public_fingerprint = stored.clientFingerprint(),
            .host_public_fingerprint = stored.hostFingerprint(),
        };
    }

    // ── §4.2 两阶段发布 ─────────────────────────────────────────────────────

    /// 对已存在于 store 的复合键原子写入 prepared journal（0600），返回归调用者
    /// 所有的 transaction_id（64 hex，调用方负责 free）。用于 clone 复用既有
    /// identity 的事务；新生成密钥走 `create`/`createRevision` 的 `journal` 参数。
    pub fn prepare(self: *Store, io: std.Io, allocator: std.mem.Allocator, old_catalog_revision: u64, profile_name: []const u8, id: []const u8, revision: u64, created_at: i64) ![]u8 {
        lock(&self.mutex);
        defer self.mutex.unlock();
        return self.prepareLocked(io, allocator, old_catalog_revision, profile_name, id, revision, created_at);
    }

    /// 两阶段发布收尾：catalog 已发布后删除 journal（删除即提交标记），并
    /// fsync 父目录；删除/fsync 错误必须向上传播。
    /// journal 缺失视为已提交（幂等）。调用方必须先完成 §4.2 第 2、3 步
    /// （发布 identities.json 与引用该复合键的 catalog）。
    pub fn commit(self: *Store, io: std.Io, allocator: std.mem.Allocator, transaction_id: []const u8) !void {
        if (self.transactions_dir.len == 0) return error.IdentityTransactionsDirUnset;
        if (transaction_id.len != 64) return error.InvalidIdentityTransaction;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ self.transactions_dir, transaction_id });
        defer allocator.free(path);
        try removeFileDurable(io, path);
    }

    /// 两阶段发布失败路径：先移除该事务新增的 `(id, revision)` 记录（幂等，记录
    /// 未发布时无操作），再删除 journal。先删记录后删 journal：若中途崩溃，启动
    /// 恢复会再次执行幂等回滚。journal 缺失视为已回滚（幂等）。
    pub fn rollback(self: *Store, io: std.Io, allocator: std.mem.Allocator, transaction_id: []const u8) !void {
        if (self.transactions_dir.len == 0) return error.IdentityTransactionsDirUnset;
        if (transaction_id.len != 64) return error.InvalidIdentityTransaction;
        const parsed = try self.readJournal(io, allocator, transaction_id) orelse return;
        defer parsed.deinit();
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.removeRevisionLocked(io, parsed.value.id, parsed.value.revision);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ self.transactions_dir, transaction_id });
        defer allocator.free(path);
        try removeFileDurable(io, path);
    }

    /// daemon 启动恢复（serve 前调用，见 `app.zig`）：按 §4.2 处理全部未完成
    /// journal，返回处理数量。逐文件决策：
    /// - catalog 已引用 `(id, revision)` 且指纹匹配 → 确认 identity 存在后删除
    ///   journal（事务实际已提交）；
    /// - catalog 未引用 → 从 identity store 移除该 revision 并删除 journal
    ///   （回滚，幂等）；
    /// - catalog 已引用但 identity 缺失或指纹不匹配 → `IdentityRecoveryFailed`
    ///   fail closed：禁止自动生成替代密钥，daemon 拒启。
    pub fn recoverPendingTransactions(self: *Store, io: std.Io, allocator: std.mem.Allocator, catalog: *const model.Catalog) !usize {
        if (self.transactions_dir.len == 0) return error.IdentityTransactionsDirUnset;
        var dir = std.Io.Dir.cwd().openDir(io, self.transactions_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return 0, // 尚无事务目录 = 无未完成 journal
            else => return err,
        };
        defer dir.close(io);
        var recovered: usize = 0;
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.transactions_dir, entry.name });
            defer allocator.free(path);
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer allocator.free(bytes);
            var parsed = std.json.parseFromSlice(IdentityTransaction, allocator, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidIdentityTransaction,
            };
            defer parsed.deinit();
            try validateJournal(parsed.value, entry.name);
            if (referencedProfile(catalog, parsed.value.id, parsed.value.revision)) |profile| {
                // 事务已发布到 catalog：确认 identity 与指纹一致后收尾。
                var record: IdentityRecord = undefined;
                if (!self.copy(parsed.value.id, parsed.value.revision, &record)) return error.IdentityRecoveryFailed;
                if (!std.mem.eql(u8, record.clientFingerprint(), profile.ssh_identity.client_public_fingerprint) or
                    !std.mem.eql(u8, record.hostFingerprint(), profile.ssh_identity.host_public_fingerprint))
                    return error.IdentityRecoveryFailed;
            } else {
                // catalog 未发布：回滚该事务（幂等移除记录 + 删除 journal）。
                lock(&self.mutex);
                defer self.mutex.unlock();
                try self.removeRevisionLocked(io, parsed.value.id, parsed.value.revision);
            }
            try removeFileDurable(io, path);
            recovered += 1;
        }
        return recovered;
    }

    /// 原子写入 prepared journal。调用方必须持有 mutex。返回归调用者所有的
    /// transaction_id（64 hex）。
    fn prepareLocked(self: *Store, io: std.Io, allocator: std.mem.Allocator, old_catalog_revision: u64, profile_name: []const u8, id: []const u8, revision: u64, created_at: i64) ![]u8 {
        if (self.transactions_dir.len == 0) return error.IdentityTransactionsDirUnset;
        if (id.len != id_len) return error.InvalidIdentityId;
        if (revision == 0) return error.InvalidIdentityTransaction;
        if (profile_name.len == 0 or profile_name.len > 255) return error.InvalidIdentityTransaction;
        var tx_id: [64]u8 = undefined;
        try journalTransactionId(id, revision, created_at, &tx_id);
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ self.transactions_dir, tx_id });
        defer allocator.free(path);
        const journal: IdentityTransaction = .{
            .schema_version = 1,
            .transaction_id = &tx_id,
            .old_catalog_revision = old_catalog_revision,
            .profile_name = profile_name,
            .id = id,
            .revision = revision,
            .created_at = created_at,
        };
        const bytes = try std.json.Stringify.valueAlloc(allocator, journal, .{ .whitespace = .indent_2 });
        defer allocator.free(bytes);
        try atomicWriteSecret(io, path, bytes);
        return allocator.dupe(u8, &tx_id);
    }

    /// 读取并基本校验 journal；文件缺失返回 null（幂等回滚/提交场景）。
    fn readJournal(self: *Store, io: std.Io, allocator: std.mem.Allocator, transaction_id: []const u8) !?std.json.Parsed(IdentityTransaction) {
        if (transaction_id.len != 64) return error.InvalidIdentityTransaction;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ self.transactions_dir, transaction_id });
        defer allocator.free(path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(bytes);
        var parsed = std.json.parseFromSlice(IdentityTransaction, allocator, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidIdentityTransaction,
        };
        errdefer parsed.deinit();
        try validateJournal(parsed.value, null);
        return parsed;
    }

    /// 移除 `(id, revision)` 记录并持久化。仅用于两阶段回滚/启动恢复（此时无
    /// 并发调用方持有 ref，安全）；正常生命周期记录不可变、不删除。
    fn removeRevisionLocked(self: *Store, io: std.Io, id: []const u8, revision: u64) !void {
        var found = false;
        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            const record = &self.identities[index];
            if (!std.mem.eql(u8, &record.id, id) or record.revision != revision) continue;
            const last = self.count - 1;
            if (index != last) record.* = self.identities[last];
            // 尾部槽位清零（含私钥），避免移除后敏感材料残留在驻留数组中。
            self.identities[last] = .{};
            self.count -= 1;
            found = true;
            break;
        }
        if (!found) return; // 幂等：记录尚未发布（prepare 后、persist 前崩溃）
        try self.persistLocked(io);
    }

    /// 将记录复制到调用方缓冲。锁释放后调用方不再引用内部槽位，因此事务
    /// rollback 的 swap-remove/清零不会影响并发消费者。
    pub fn copy(self: *Store, id: []const u8, revision: u64, destination: *IdentityRecord) bool {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.identities[0..self.count]) |*r| {
            if (std.mem.eql(u8, &r.id, id) and r.revision == revision) {
                destination.* = r.*;
                return true;
            }
        }
        return false;
    }

    /// 测试/存在性检查使用；生产消费者必须使用 `copy`，不得在解锁后持有指针。
    fn get(self: *Store, id: []const u8, revision: u64) ?*const IdentityRecord {
        lock(&self.mutex);
        defer self.mutex.unlock();
        for (self.identities[0..self.count]) |*r| {
            if (std.mem.eql(u8, &r.id, id) and r.revision == revision) return r;
        }
        return null;
    }

    /// Persist all identities to disk atomically. Caller must hold mutex.
    /// 私钥文件通过 `atomicWriteSecret` 落盘：临时文件创建时即 0600。
    fn persistLocked(self: *Store, io: std.Io) !void {
        if (self.path.len == 0) return;
        var compact: [max_identities]PersistedIdentity = undefined;
        // 必须按指针迭代：`|r|` 是槽位按值副本，`persistedIdentity(&r)` 会把
        // 切片指向循环栈槽；循环结束后悬垂，Stringify 会读到最后一轮的数据，
        // 导致多记录持久化时全部记录退化为最后一条（id/密钥/指纹丢失）。
        for (self.identities[0..self.count], 0..) |*r, i| {
            compact[i] = persistedIdentity(r);
        }
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, PersistedFile{
            .schema_version = schema_version,
            .identities = compact[0..self.count],
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(bytes);
        try atomicWriteSecret(io, self.path, bytes);
    }

    /// Persist current state to disk.
    pub fn persist(self: *Store, io: std.Io) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.persistLocked(io);
    }
};

pub const IdentityRef = struct {
    id: []const u8,
    revision: u64,
    client_public_fingerprint: []const u8,
    host_public_fingerprint: []const u8,
};

const PersistedIdentity = struct {
    id: []const u8,
    revision: u64,
    created_at: i64,
    client_private_key: []const u8,
    client_public_key: []const u8,
    host_private_key: []const u8,
    host_public_key: []const u8,
    client_public_fingerprint: []const u8,
    host_public_fingerprint: []const u8,
};

const PersistedFile = struct {
    schema_version: u32 = schema_version,
    identities: []const PersistedIdentity = &.{},
};

fn persistedIdentity(r: *const IdentityRecord) PersistedIdentity {
    return .{
        .id = &r.id,
        .revision = r.revision,
        .created_at = r.created_at,
        .client_private_key = r.clientPrivateKey(),
        .client_public_key = r.clientPublicKey(),
        .host_private_key = r.hostPrivateKey(),
        .host_public_key = r.hostPublicKey(),
        .client_public_fingerprint = r.clientFingerprint(),
        .host_public_fingerprint = r.hostFingerprint(),
    };
}

/// 把生成的密钥材料填入指定槽位（就地构造，避免 16KB 栈副本与悬垂 ref）。
/// 长度越界显式报错（替代旧实现的静默 `@min` 截断，与 `restoreRecord` 一致）。
/// 失败返回错误，调用方负责在 persist 失败时回滚 count。
fn fillSlot(slot: *IdentityRecord, id: [id_len]u8, revision: u64, now: i64, cpriv: []const u8, cpub: []const u8, hpriv: []const u8, hpub: []const u8, cfp: []const u8, hfp: []const u8) !void {
    if (cpriv.len > key_cap or cpub.len > key_cap or hpriv.len > key_cap or hpub.len > key_cap)
        return error.KeyTooLarge;
    if (cfp.len > fingerprint_cap or hfp.len > fingerprint_cap) return error.KeyTooLarge;
    slot.* = .{ .id = id, .revision = revision, .created_at = now };
    slot.client_private_key_len = @intCast(cpriv.len);
    @memcpy(slot.client_private_key[0..cpriv.len], cpriv);
    slot.client_public_key_len = @intCast(cpub.len);
    @memcpy(slot.client_public_key[0..cpub.len], cpub);
    slot.host_private_key_len = @intCast(hpriv.len);
    @memcpy(slot.host_private_key[0..hpriv.len], hpriv);
    slot.host_public_key_len = @intCast(hpub.len);
    @memcpy(slot.host_public_key[0..hpub.len], hpub);
    slot.client_public_fingerprint_len = @intCast(cfp.len);
    @memcpy(slot.client_public_fingerprint[0..cfp.len], cfp);
    slot.host_public_fingerprint_len = @intCast(hfp.len);
    @memcpy(slot.host_public_fingerprint[0..hfp.len], hfp);
}

/// 从持久化投影恢复记录并做完整校验（fail closed）：
/// - id 长度、revision >= 1、密钥/指纹长度上限；
/// - 公钥指纹纯 Zig 重算比对（`admin_key.fingerprint`，与 `ssh-keygen -lf` 一致）；
/// - private/public 用 `ssh-keygen -y` 派生比对。
fn restoreRecord(allocator: std.mem.Allocator, io: std.Io, staging_dir: []const u8, item: PersistedIdentity) !IdentityRecord {
    if (item.id.len != id_len) return error.InvalidIdentityStore;
    if (item.revision == 0) return error.InvalidIdentityStore;
    if (item.client_private_key.len > key_cap or item.client_public_key.len > key_cap or
        item.host_private_key.len > key_cap or item.host_public_key.len > key_cap or
        item.client_public_fingerprint.len > fingerprint_cap or item.host_public_fingerprint.len > fingerprint_cap)
        return error.InvalidIdentityStore;
    var r: IdentityRecord = .{
        .revision = item.revision,
        .created_at = item.created_at,
    };
    @memcpy(&r.id, item.id);
    r.client_private_key_len = @intCast(item.client_private_key.len);
    @memcpy(r.client_private_key[0..r.client_private_key_len], item.client_private_key);
    r.client_public_key_len = @intCast(item.client_public_key.len);
    @memcpy(r.client_public_key[0..r.client_public_key_len], item.client_public_key);
    r.host_private_key_len = @intCast(item.host_private_key.len);
    @memcpy(r.host_private_key[0..r.host_private_key_len], item.host_private_key);
    r.host_public_key_len = @intCast(item.host_public_key.len);
    @memcpy(r.host_public_key[0..r.host_public_key_len], item.host_public_key);
    r.client_public_fingerprint_len = @intCast(item.client_public_fingerprint.len);
    @memcpy(r.client_public_fingerprint[0..r.client_public_fingerprint_len], item.client_public_fingerprint);
    r.host_public_fingerprint_len = @intCast(item.host_public_fingerprint.len);
    @memcpy(r.host_public_fingerprint[0..r.host_public_fingerprint_len], item.host_public_fingerprint);

    const client_fp = admin_key.fingerprint(allocator, r.clientPublicKey()) catch return error.InvalidIdentityStore;
    defer allocator.free(client_fp);
    if (!std.mem.eql(u8, client_fp, r.clientFingerprint())) return error.InvalidIdentityStore;
    const host_fp = admin_key.fingerprint(allocator, r.hostPublicKey()) catch return error.InvalidIdentityStore;
    defer allocator.free(host_fp);
    if (!std.mem.eql(u8, host_fp, r.hostFingerprint())) return error.InvalidIdentityStore;

    try verifyKeyPair(allocator, io, staging_dir, r.clientPrivateKey(), r.clientPublicKey());
    try verifyKeyPair(allocator, io, staging_dir, r.hostPrivateKey(), r.hostPublicKey());
    return r;
}

/// 用 `ssh-keygen -y` 从私钥派生公钥并与存储公钥比对，验证 private/public
/// 成对。私钥写入暂存目录（临时文件创建时即 0600），校验后立即删除；
/// 任一失败即 fail closed（`InvalidIdentityStore`）。
fn verifyKeyPair(allocator: std.mem.Allocator, io: std.Io, staging_dir: []const u8, private_key: []const u8, public_key: []const u8) !void {
    if (staging_dir.len == 0) return error.IdentityStagingDirUnset;
    var rnd: [8]u8 = undefined;
    try io.randomSecure(&rnd);
    const temp = try std.fmt.allocPrint(allocator, "{s}/pair-check-{x}", .{ staging_dir, std.mem.readInt(u64, &rnd, .little) });
    defer allocator.free(temp);
    defer removeFile(io, temp);
    {
        var file = try std.Io.Dir.cwd().createFile(io, temp, .{ .truncate = true, .permissions = @enumFromInt(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, private_key);
        try file.sync(io);
    }
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "ssh-keygen", "-y", "-f", temp },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.InvalidIdentityStore,
        else => return error.InvalidIdentityStore,
    }
    const derived = std.mem.trim(u8, result.stdout, " \t\r\n");
    const expected = std.mem.trim(u8, public_key, " \t\r\n");
    if (!std.mem.eql(u8, derived, expected)) return error.InvalidIdentityStore;
}

fn generateSshKey(allocator: std.mem.Allocator, io: std.Io, path: []const u8, comment: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "ssh-keygen", "-t", "ed25519", "-N", "", "-C", comment, "-f", path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SshKeygenFailed,
        else => return error.SshKeygenFailed,
    }
}

fn computeFingerprint(allocator: std.mem.Allocator, io: std.Io, pubkey_path: []const u8) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "ssh-keygen", "-lf", pubkey_path },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.FingerprintFailed,
        else => return error.FingerprintFailed,
    }
    const stdout = std.mem.trim(u8, result.stdout, " \t\r\n");
    // ssh-keygen -lf output: "256 SHA256:xxxxx nodeforge-client (ED25519)"
    // We want the "SHA256:xxxxx" part
    var parts = std.mem.tokenizeScalar(u8, stdout, ' ');
    _ = parts.next(); // skip bit length
    const fp = parts.next() orelse return error.FingerprintParseFailed;
    return try allocator.dupe(u8, fp);
}

fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(key_cap));
}

fn removeFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn removeFileDurable(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try @import("dhcp_store.zig").syncParentDirectory(io, path);
}

/// 释放堆私钥缓冲区前清零，避免敏感材料残留在进程内存/堆上。
fn zeroAndFree(allocator: std.mem.Allocator, buf: []const u8) void {
    @memset(@constCast(buf), 0);
    allocator.free(buf);
}

fn chmod(allocator: std.mem.Allocator, io: std.Io, mode: []const u8, path: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "chmod", mode, path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.PermissionUpdateFailed,
        else => return error.PermissionUpdateFailed,
    }
}

/// 确保私钥暂存目录存在并固定 0700。daemon 启动时调用；重复调用幂等。
pub fn ensurePrivateDir(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    std.Io.Dir.cwd().createDir(io, path, @enumFromInt(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try chmod(allocator, io, "700", path);
}

/// 私钥落盘协议：临时文件以 0600 创建、写入、fsync、rename、fsync 父目录。
/// 与 `dhcp_store.atomicWrite` 的区别：临时文件创建时即 0600，私钥字节不会以
/// 默认 umask（通常 0644）短暂暴露在磁盘上；rename 后目标文件继承 0600。
fn atomicWriteSecret(io: std.Io, path: []const u8, content: []const u8) !void {
    const dir = std.Io.Dir.cwd();
    const temp = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp", .{path});
    defer std.heap.page_allocator.free(temp);
    errdefer dir.deleteFile(io, temp) catch {};
    {
        var file = try dir.createFile(io, temp, .{ .truncate = true, .permissions = @enumFromInt(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, content);
        try file.sync(io);
    }
    try std.Io.Dir.rename(dir, temp, dir, path, io);
    try dhcp_store.syncParentDirectory(io, path);
}

/// Generate 32-char lowercase hex id (128-bit secure random).
fn generateId(io: std.Io, destination: *[id_len]u8) !void {
    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    for (random, 0..) |byte, index| {
        destination[index * 2] = hex(byte >> 4);
        destination[index * 2 + 1] = hex(byte & 0x0f);
    }
}

fn hex(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + (nibble - 10);
}

fn lock(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.Thread.yield() catch {};
}

/// 事务 id = SHA-256(id ‖ revision 十进制 ‖ created_at 十进制) 的 64 位 hex。
/// 由幂等恢复对账使用；同参重算结果稳定。
fn journalTransactionId(id: []const u8, revision: u64, created_at: i64, output: *[64]u8) !void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(id);
    var text: [24]u8 = undefined;
    hash.update(try std.fmt.bufPrint(&text, "{d}", .{revision}));
    hash.update(try std.fmt.bufPrint(&text, "{d}", .{created_at}));
    var raw: [32]u8 = undefined;
    hash.final(&raw);
    _ = std.fmt.bufPrint(output, "{x}", .{raw}) catch unreachable;
}

/// 校验 journal 结构；`file_name` 非空时还要求等于 `<transaction_id>.json`，
/// 防止错放/串包 journal。
fn validateJournal(journal: IdentityTransaction, file_name: ?[]const u8) !void {
    if (journal.schema_version != 1) return error.InvalidIdentityTransaction;
    if (journal.transaction_id.len != 64 or journal.id.len != id_len) return error.InvalidIdentityTransaction;
    if (journal.revision == 0) return error.InvalidIdentityTransaction;
    if (journal.profile_name.len == 0 or journal.profile_name.len > 255) return error.InvalidIdentityTransaction;
    if (file_name) |name| {
        if (name.len != 64 + ".json".len) return error.InvalidIdentityTransaction;
        if (!std.mem.eql(u8, name[0..64], journal.transaction_id)) return error.InvalidIdentityTransaction;
    }
}

/// 在 catalog 中查找引用 `(id, revision)` 复合键的 Profile；未引用返回 null。
fn referencedProfile(catalog: *const model.Catalog, id: []const u8, revision: u64) ?*const model.ProfileConfig {
    for (catalog.profiles) |*profile| {
        if (std.mem.eql(u8, profile.ssh_identity.id, id) and profile.ssh_identity.revision == revision)
            return profile;
    }
    return null;
}

// ── 测试 ────────────────────────────────────────────────────────────────────

test {
    // 强制 `Store`/`create`/`createRevision` 等全部声明参与语义分析：
    // A1/A2 这类"测试不引用就不编译"的回归会立即变红（治假绿）。
    std.testing.refAllDecls(@This());
}

test "identity store loads empty when file missing" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/missing.json", .{dir_path});
    defer std.testing.allocator.free(store_path);

    // Store is ~4 MB (256 × 16 KB IdentityRecord); allocate on heap to avoid
    // stack overflow in the test runner.
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = Store.init(std.testing.allocator, store_path);
    try store.load(std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), store.count);
    try std.testing.expect(store.loaded);
}

test "identity store create/persist/load round-trip" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/identities.json", .{dir_path});
    defer std.testing.allocator.free(store_path);

    const store1 = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store1);
    store1.* = Store.init(std.testing.allocator, store_path);
    store1.staging_dir = dir_path;
    const ref = try store1.create(std.testing.io, std.testing.allocator, 1000, null);
    try std.testing.expectEqual(@as(u64, 1), ref.revision);
    try std.testing.expect(ref.client_public_fingerprint.len != 0);
    try std.testing.expect(ref.host_public_fingerprint.len != 0);

    // Reload in a fresh store: strict validation (fingerprint + pairing) passes.
    const store2 = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store2);
    store2.* = Store.init(std.testing.allocator, store_path);
    store2.staging_dir = dir_path;
    try store2.load(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), store2.count);
    const found = store2.get(ref.id, 1) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(ref.client_public_fingerprint, found.clientFingerprint());
    try std.testing.expectEqualStrings(ref.host_public_fingerprint, found.hostFingerprint());
    try std.testing.expectEqual(@as(i64, 1000), found.created_at);
}

test "identity store multi-record persist keeps distinct identities" {
    // v0.2.3 回归：persistLocked 曾按值迭代槽位并把切片指向循环副本，导致
    // 多记录持久化后全部记录退化为最后一条（r97n0 生产 identities.json 出现
    // 三条相同 id/密钥但 created_at 递增的损坏记录）。此处连续 create 三条并
    // 重载校验 id/指纹/created_at 全部保持独立。
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/identities.json", .{dir_path});
    defer std.testing.allocator.free(store_path);

    const store1 = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store1);
    store1.* = Store.init(std.testing.allocator, store_path);
    store1.staging_dir = dir_path;
    const ref_a = try store1.create(std.testing.io, std.testing.allocator, 1000, null);
    const ref_b = try store1.create(std.testing.io, std.testing.allocator, 2000, null);
    const ref_c = try store1.create(std.testing.io, std.testing.allocator, 3000, null);
    try std.testing.expect(!std.mem.eql(u8, ref_a.id, ref_b.id));
    try std.testing.expect(!std.mem.eql(u8, ref_b.id, ref_c.id));
    try std.testing.expect(!std.mem.eql(u8, ref_a.client_public_fingerprint, ref_b.client_public_fingerprint));
    try std.testing.expect(!std.mem.eql(u8, ref_b.client_public_fingerprint, ref_c.client_public_fingerprint));

    const store2 = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store2);
    store2.* = Store.init(std.testing.allocator, store_path);
    store2.staging_dir = dir_path;
    try store2.load(std.testing.io);
    try std.testing.expectEqual(@as(usize, 3), store2.count);
    const found_a = store2.get(ref_a.id, 1) orelse return error.TestExpectedEqual;
    const found_b = store2.get(ref_b.id, 1) orelse return error.TestExpectedEqual;
    const found_c = store2.get(ref_c.id, 1) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(ref_a.client_public_fingerprint, found_a.clientFingerprint());
    try std.testing.expectEqualStrings(ref_b.client_public_fingerprint, found_b.clientFingerprint());
    try std.testing.expectEqualStrings(ref_c.client_public_fingerprint, found_c.clientFingerprint());
    try std.testing.expectEqual(@as(i64, 1000), found_a.created_at);
    try std.testing.expectEqual(@as(i64, 2000), found_b.created_at);
    try std.testing.expectEqual(@as(i64, 3000), found_c.created_at);
}

test "identity store createRevision appends immutable revision" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/identities.json", .{dir_path});
    defer std.testing.allocator.free(store_path);

    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = Store.init(std.testing.allocator, store_path);
    store.staging_dir = dir_path;
    const ref1 = try store.create(std.testing.io, std.testing.allocator, 1000, null);
    const ref2 = try store.createRevision(std.testing.io, std.testing.allocator, ref1.id, 2000, null);
    try std.testing.expectEqual(@as(u64, 2), ref2.revision);
    try std.testing.expect(store.get(ref1.id, 1) != null);
    try std.testing.expect(store.get(ref1.id, 2) != null);
    try std.testing.expect(store.get(ref1.id, 3) == null);
    // 两次生成必须是不同密钥材料（指纹不同）。
    try std.testing.expect(!std.mem.eql(u8, ref1.client_public_fingerprint, ref2.client_public_fingerprint));
}

test "identity store rejects wrong schema version" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/wrong-schema.json", .{dir_path});
    defer std.testing.allocator.free(store_path);

    const bad_json = "{\"schema_version\":99,\"identities\":[]}";
    try dhcp_store.atomicWrite(std.testing.io, store_path, bad_json);

    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = Store.init(std.testing.allocator, store_path);
    try std.testing.expectError(error.InvalidIdentityStore, store.load(std.testing.io));
}

test "identity store get uses composite key" {
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = Store.init(std.testing.allocator, "");
    var record: IdentityRecord = .{ .revision = 2, .created_at = 500 };
    const test_id = "11223344556677889900aabbccddeeff";
    @memcpy(&record.id, test_id[0..id_len]);
    store.identities[0] = record;
    store.count = 1;

    // Correct composite key finds the record.
    const found = store.get(test_id, 2) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(test_id, &found.id);
    try std.testing.expectEqual(@as(u64, 2), found.revision);

    // Wrong revision does not find it.
    try std.testing.expect(store.get(test_id, 1) == null);
    // Wrong id does not find it.
    try std.testing.expect(store.get("00000000000000000000000000000000", 2) == null);
}

/// journal 测试夹具：构造带 staging + transactions 目录的 store。
/// 返回的 store 与其内部路径均为调用者内存（std.testing.allocator）。
fn journalTestStore(io: std.Io, dir_path: []const u8) !*Store {
    const allocator = std.testing.allocator;
    const tx_dir = try std.fmt.allocPrint(allocator, "{s}/tx", .{dir_path});
    errdefer allocator.free(tx_dir);
    try ensurePrivateDir(io, allocator, tx_dir);
    const store_path = try std.fmt.allocPrint(allocator, "{s}/identities.json", .{dir_path});
    errdefer allocator.free(store_path);
    const store = try allocator.create(Store);
    errdefer allocator.destroy(store);
    store.* = Store.init(allocator, store_path);
    store.staging_dir = dir_path;
    store.transactions_dir = tx_dir;
    return store;
}

fn destroyJournalTestStore(store: *Store) void {
    const allocator = std.testing.allocator;
    allocator.free(store.transactions_dir);
    allocator.free(store.path);
    allocator.destroy(store);
}

fn journalPath(allocator: std.mem.Allocator, dir_path: []const u8, tx_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/tx/{s}.json", .{ dir_path, tx_id });
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn catalogWithReference(id: []const u8, revision: u64, cfp: []const u8, hfp: []const u8) model.Catalog {
    return .{
        .profiles = &.{
            .{
                .name = "p1",
                .install_source = "src",
                .ssh_identity = .{
                    .id = id,
                    .revision = revision,
                    .client_public_fingerprint = cfp,
                    .host_public_fingerprint = hfp,
                },
            },
        },
    };
}

test "identity journal prepare/commit round trip" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store = try journalTestStore(std.testing.io, dir_path);
    defer destroyJournalTestStore(store);

    var tx: IdentityTx = .{ .old_catalog_revision = 0, .profile_name = "p1", .created_at = 1000 };
    const ref = try store.create(std.testing.io, std.testing.allocator, 1000, &tx);
    const tx_id = tx.transaction_id orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(tx_id);

    // prepared journal 已落盘，identity 已发布。
    const journal_path = try journalPath(std.testing.allocator, dir_path, tx_id);
    defer std.testing.allocator.free(journal_path);
    try std.testing.expect(fileExists(std.testing.io, journal_path));
    try std.testing.expect(store.get(ref.id, 1) != null);

    // commit（catalog 已发布后）：journal 删除即提交标记，记录保留。
    try store.commit(std.testing.io, std.testing.allocator, tx_id);
    try std.testing.expect(!fileExists(std.testing.io, journal_path));
    try std.testing.expect(store.get(ref.id, 1) != null);
}

test "identity journal commit propagates deletion failure" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store = try journalTestStore(std.testing.io, dir_path);
    defer destroyJournalTestStore(store);

    var tx: IdentityTx = .{ .old_catalog_revision = 0, .profile_name = "p1", .created_at = 1000 };
    const ref = try store.create(std.testing.io, std.testing.allocator, 1000, &tx);
    const tx_id = tx.transaction_id orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(tx_id);
    const journal_path = try journalPath(std.testing.allocator, dir_path, tx_id);
    defer std.testing.allocator.free(journal_path);

    // 用同名目录替换 journal，使 deleteFile 确定失败；commit 必须传播错误，
    // 同时 identity 仍保留，供启动恢复根据已发布 catalog 决策。
    try std.Io.Dir.cwd().deleteFile(std.testing.io, journal_path);
    try std.Io.Dir.cwd().createDir(std.testing.io, journal_path, .default_dir);
    if (store.commit(std.testing.io, std.testing.allocator, tx_id)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expect(store.get(ref.id, ref.revision) != null);
}

test "identity journal rollback removes unpublished revision" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store = try journalTestStore(std.testing.io, dir_path);
    defer destroyJournalTestStore(store);

    var tx: IdentityTx = .{ .old_catalog_revision = 0, .profile_name = "p1", .created_at = 1000 };
    const ref = try store.create(std.testing.io, std.testing.allocator, 1000, &tx);
    const tx_id = tx.transaction_id orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(tx_id);

    try store.rollback(std.testing.io, std.testing.allocator, tx_id);
    const journal_path = try journalPath(std.testing.allocator, dir_path, tx_id);
    defer std.testing.allocator.free(journal_path);
    try std.testing.expect(store.get(ref.id, 1) == null);
    try std.testing.expect(!fileExists(std.testing.io, journal_path));

    // rollback 幂等：journal 已删除后再调一次也成功。
    try store.rollback(std.testing.io, std.testing.allocator, tx_id);
}

test "identity copy remains stable when rollback swap-removes another record" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store = try journalTestStore(std.testing.io, dir_path);
    defer destroyJournalTestStore(store);

    var tx: IdentityTx = .{ .old_catalog_revision = 0, .profile_name = "rollback", .created_at = 1000 };
    _ = try store.create(std.testing.io, std.testing.allocator, 1000, &tx);
    const tx_id = tx.transaction_id orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(tx_id);
    const retained = try store.create(std.testing.io, std.testing.allocator, 1001, null);
    var retained_id: [id_len]u8 = undefined;
    @memcpy(&retained_id, retained.id);
    const retained_revision = retained.revision;
    var copied: IdentityRecord = undefined;
    try std.testing.expect(store.copy(&retained_id, retained_revision, &copied));
    const fingerprint = try std.testing.allocator.dupe(u8, copied.clientFingerprint());
    defer std.testing.allocator.free(fingerprint);

    try store.rollback(std.testing.io, std.testing.allocator, tx_id);
    try std.testing.expectEqualStrings(fingerprint, copied.clientFingerprint());
    var after: IdentityRecord = undefined;
    try std.testing.expect(store.copy(&retained_id, retained_revision, &after));
    try std.testing.expectEqualStrings(fingerprint, after.clientFingerprint());
}

test "identity revision overflow fails before key generation" {
    var store = Store.init(std.testing.allocator, "");
    store.count = 1;
    @memcpy(&store.identities[0].id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    store.identities[0].revision = std.math.maxInt(u64);
    try std.testing.expectError(error.IdentityRevisionOverflow, store.createRevision(std.testing.io, std.testing.allocator, &store.identities[0].id, 1000, null));
}

test "identity journal recovery completes committed transaction" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store = try journalTestStore(std.testing.io, dir_path);
    defer destroyJournalTestStore(store);

    var tx: IdentityTx = .{ .old_catalog_revision = 0, .profile_name = "p1", .created_at = 1000 };
    const ref = try store.create(std.testing.io, std.testing.allocator, 1000, &tx);
    const tx_id = tx.transaction_id orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(tx_id);
    const journal_path = try journalPath(std.testing.allocator, dir_path, tx_id);
    defer std.testing.allocator.free(journal_path);

    // catalog 已引用 (id, revision) 且指纹匹配 → 收尾提交。
    const catalog = catalogWithReference(ref.id, ref.revision, ref.client_public_fingerprint, ref.host_public_fingerprint);
    try std.testing.expectEqual(@as(usize, 1), try store.recoverPendingTransactions(std.testing.io, std.testing.allocator, &catalog));
    try std.testing.expect(!fileExists(std.testing.io, journal_path));
    try std.testing.expect(store.get(ref.id, 1) != null);
}

test "identity journal recovery rolls back unpublished transaction" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store = try journalTestStore(std.testing.io, dir_path);
    defer destroyJournalTestStore(store);

    var tx: IdentityTx = .{ .old_catalog_revision = 0, .profile_name = "p1", .created_at = 1000 };
    const ref = try store.create(std.testing.io, std.testing.allocator, 1000, &tx);
    const tx_id = tx.transaction_id orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(tx_id);
    const journal_path = try journalPath(std.testing.allocator, dir_path, tx_id);
    defer std.testing.allocator.free(journal_path);

    // catalog 未引用 → 幂等回滚：记录移除、journal 删除。
    try std.testing.expectEqual(@as(usize, 1), try store.recoverPendingTransactions(std.testing.io, std.testing.allocator, &model.Catalog{}));
    try std.testing.expect(store.get(ref.id, 1) == null);
    try std.testing.expect(!fileExists(std.testing.io, journal_path));
}

test "identity journal recovery fails closed on fingerprint mismatch" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store = try journalTestStore(std.testing.io, dir_path);
    defer destroyJournalTestStore(store);

    var tx: IdentityTx = .{ .old_catalog_revision = 0, .profile_name = "p1", .created_at = 1000 };
    const ref = try store.create(std.testing.io, std.testing.allocator, 1000, &tx);
    const tx_id = tx.transaction_id orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(tx_id);

    // catalog 引用同一复合键但指纹不一致 → fail closed，禁止自动补钥。
    const catalog = catalogWithReference(ref.id, ref.revision, "SHA256:mismatched", ref.host_public_fingerprint);
    try std.testing.expectError(error.IdentityRecoveryFailed, store.recoverPendingTransactions(std.testing.io, std.testing.allocator, &catalog));
}

test "identity journal recovery fails closed on missing identity" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store = try journalTestStore(std.testing.io, dir_path);
    defer destroyJournalTestStore(store);

    // 直接 prepare 一个 store 中不存在的 (id, revision) journal。
    const missing_id = "11223344556677889900aabbccddeeff";
    const tx_id = try store.prepare(std.testing.io, std.testing.allocator, 0, "p1", missing_id, 1, 1000);
    defer std.testing.allocator.free(tx_id);

    // catalog 已引用但 identity 缺失 → fail closed（daemon 拒启）。
    const catalog = catalogWithReference(missing_id, 1, "SHA256:cfp", "SHA256:hfp");
    try std.testing.expectError(error.IdentityRecoveryFailed, store.recoverPendingTransactions(std.testing.io, std.testing.allocator, &catalog));
}

test "identity journal recovery rejects malformed journal" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const store = try journalTestStore(std.testing.io, dir_path);
    defer destroyJournalTestStore(store);

    // schema_version 非法 → InvalidIdentityTransaction（fail closed）。
    const bad_path = try journalPath(std.testing.allocator, dir_path, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    defer std.testing.allocator.free(bad_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bad_path, .data = "{\"schema_version\":2}" });
    try std.testing.expectError(error.InvalidIdentityTransaction, store.recoverPendingTransactions(std.testing.io, std.testing.allocator, &model.Catalog{}));
}

// v0.2.3 §4.3 crash fixture：两阶段发布在三个崩溃点分别中断后，启动恢复
// （`recoverPendingTransactions`）必须得到确定结果且不留半成品。
// identity 文件损坏 → daemon 拒启由 `load` 的 fail-closed 测试覆盖
// （schema/length/id/revision 篡改与指纹/配对负测）。
test "v0.2.3 §4.3 crash fixtures recover deterministically at all three crash points" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    // ── 崩溃点 1：prepared 之后（journal 已写，identity/catalog 均未发布）──
    {
        const sub = try std.fmt.allocPrint(std.testing.allocator, "{s}/a", .{dir_path});
        defer std.testing.allocator.free(sub);
        std.Io.Dir.cwd().createDir(std.testing.io, sub, @enumFromInt(0o700)) catch {};
        const store = try journalTestStore(std.testing.io, sub);
        defer destroyJournalTestStore(store);
        const tx_id = try store.prepare(std.testing.io, std.testing.allocator, 0, "p1", "11223344556677889900aabbccddeeff", 1, 1000);
        defer std.testing.allocator.free(tx_id);
        // 恢复：catalog 未引用 → 回滚（记录不存在，幂等）+ journal 删除。
        try std.testing.expectEqual(@as(usize, 1), try store.recoverPendingTransactions(std.testing.io, std.testing.allocator, &model.Catalog{}));
        try std.testing.expectEqual(@as(usize, 0), store.count);
        const journal_path = try journalPath(std.testing.allocator, sub, tx_id);
        defer std.testing.allocator.free(journal_path);
        try std.testing.expect(!fileExists(std.testing.io, journal_path));
    }

    // ── 崩溃点 2：identity publish 之后（journal + identity 已落盘，catalog 未发布）──
    {
        const sub = try std.fmt.allocPrint(std.testing.allocator, "{s}/b", .{dir_path});
        defer std.testing.allocator.free(sub);
        std.Io.Dir.cwd().createDir(std.testing.io, sub, @enumFromInt(0o700)) catch {};
        const store = try journalTestStore(std.testing.io, sub);
        defer destroyJournalTestStore(store);
        var tx: IdentityTx = .{ .old_catalog_revision = 0, .profile_name = "p1", .created_at = 1000 };
        const ref = try store.create(std.testing.io, std.testing.allocator, 1000, &tx);
        const tx_id = tx.transaction_id orelse return error.TestExpectedEqual;
        defer std.testing.allocator.free(tx_id);
        // 恢复：catalog 未引用 → 回滚该 revision（orphan 不留存）。
        try std.testing.expectEqual(@as(usize, 1), try store.recoverPendingTransactions(std.testing.io, std.testing.allocator, &model.Catalog{}));
        try std.testing.expect(store.get(ref.id, 1) == null);
        try std.testing.expectEqual(@as(usize, 0), store.count);
        const journal_path = try journalPath(std.testing.allocator, sub, tx_id);
        defer std.testing.allocator.free(journal_path);
        try std.testing.expect(!fileExists(std.testing.io, journal_path));
        // 落盘文件与内存一致（重载后仍无记录）。
        const reload = try std.testing.allocator.create(Store);
        defer std.testing.allocator.destroy(reload);
        reload.* = Store.init(std.testing.allocator, store.path);
        reload.staging_dir = sub;
        try reload.load(std.testing.io);
        try std.testing.expectEqual(@as(usize, 0), reload.count);
    }

    // ── 崩溃点 3：catalog publish 之后（journal + identity + catalog 引用齐全）──
    {
        const sub = try std.fmt.allocPrint(std.testing.allocator, "{s}/c", .{dir_path});
        defer std.testing.allocator.free(sub);
        std.Io.Dir.cwd().createDir(std.testing.io, sub, @enumFromInt(0o700)) catch {};
        const store = try journalTestStore(std.testing.io, sub);
        defer destroyJournalTestStore(store);
        var tx: IdentityTx = .{ .old_catalog_revision = 0, .profile_name = "p1", .created_at = 1000 };
        const ref = try store.create(std.testing.io, std.testing.allocator, 1000, &tx);
        const tx_id = tx.transaction_id orelse return error.TestExpectedEqual;
        defer std.testing.allocator.free(tx_id);
        // 恢复：catalog 已引用且指纹匹配 → 收尾提交，记录保留。
        const catalog = catalogWithReference(ref.id, ref.revision, ref.client_public_fingerprint, ref.host_public_fingerprint);
        try std.testing.expectEqual(@as(usize, 1), try store.recoverPendingTransactions(std.testing.io, std.testing.allocator, &catalog));
        try std.testing.expect(store.get(ref.id, 1) != null);
        const journal_path = try journalPath(std.testing.allocator, sub, tx_id);
        defer std.testing.allocator.free(journal_path);
        try std.testing.expect(!fileExists(std.testing.io, journal_path));
    }
}

/// 测试夹具：用 ssh-keygen 生成真实 ed25519 密钥对，供 load 校验测试使用
/// （load 现在对指纹/配对做 fail-closed 校验，伪密钥无法通过）。
fn generateTestKeys(io: std.Io, allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !TestKeys {
    const key_path = try std.fmt.allocPrint(allocator, "{s}/test-key-{s}", .{ dir, name });
    defer allocator.free(key_path);
    const pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{key_path});
    defer allocator.free(pub_path);
    defer std.Io.Dir.cwd().deleteFile(io, key_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, pub_path) catch {};
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "ssh-keygen", "-t", "ed25519", "-N", "", "-C", "nodeforge-test", "-f", key_path },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SshKeygenFailed,
        else => return error.SshKeygenFailed,
    }
    const private = try std.Io.Dir.cwd().readFileAlloc(io, key_path, allocator, .limited(key_cap));
    const public = try std.Io.Dir.cwd().readFileAlloc(io, pub_path, allocator, .limited(key_cap));
    errdefer allocator.free(private);
    errdefer allocator.free(public);
    const fingerprint = try admin_key.fingerprint(allocator, public);
    return .{ .private = private, .public = public, .fingerprint = fingerprint };
}

const TestKeys = struct {
    private: []const u8,
    public: []const u8,
    fingerprint: []const u8,
};

const TestIdentity = struct {
    id: []const u8,
    revision: u64,
    created_at: i64,
    client_private_key: []const u8,
    client_public_key: []const u8,
    host_private_key: []const u8,
    host_public_key: []const u8,
    client_public_fingerprint: []const u8,
    host_public_fingerprint: []const u8,
};

const TestFile = struct {
    schema_version: u32 = 1,
    identities: []const TestIdentity = &.{},
};

test "identity store fails closed on schema/length/id/revision corruption" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const dir_path = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const keys = try generateTestKeys(std.testing.io, std.testing.allocator, dir_path, "client");
    defer std.testing.allocator.free(keys.private);
    defer std.testing.allocator.free(keys.public);
    defer std.testing.allocator.free(keys.fingerprint);
    const host_keys = try generateTestKeys(std.testing.io, std.testing.allocator, dir_path, "host");
    defer std.testing.allocator.free(host_keys.private);
    defer std.testing.allocator.free(host_keys.public);
    defer std.testing.allocator.free(host_keys.fingerprint);

    const store_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/corrupt.json", .{dir_path});
    defer std.testing.allocator.free(store_path);
    const valid: TestIdentity = .{
        .id = "abcdef0123456789abcdef0123456789",
        .revision = 1,
        .created_at = 1000,
        .client_private_key = keys.private,
        .client_public_key = keys.public,
        .host_private_key = host_keys.private,
        .host_public_key = host_keys.public,
        .client_public_fingerprint = keys.fingerprint,
        .host_public_fingerprint = host_keys.fingerprint,
    };
    const base = [_]TestIdentity{valid};

    try std.testing.expectError(error.InvalidIdentityStore, loadFromFile(std.testing.io, dir_path, store_path, &base, .{ .revision = 0 }));
    const short_id = "abc";
    try std.testing.expectError(error.InvalidIdentityStore, loadFromFile(std.testing.io, dir_path, store_path, &base, .{ .id = short_id }));
    try std.testing.expectError(error.InvalidIdentityStore, loadFromFile(std.testing.io, dir_path, store_path, &base, .{ .client_public_fingerprint = "SHA256:tampered" }));
    // 私钥与公钥不成对（用 host 公钥配 client 私钥）：derive 不匹配。
    try std.testing.expectError(error.InvalidIdentityStore, loadFromFileSwap(std.testing.io, dir_path, store_path, &base));
    // (id, revision) 复合键重复。
    const dup = [_]TestIdentity{ valid, valid };
    try std.testing.expectError(error.InvalidIdentityStore, loadFromFile(std.testing.io, dir_path, store_path, &dup, .{}));
    // 合法文件可正常加载（对照）。
    const loaded = try loadFromFile(std.testing.io, dir_path, store_path, &base, .{});
    defer std.testing.allocator.destroy(loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.count);
}

/// 把 `identities` 序列化到 store_path 并用全新 Store 加载；返回加载后的
/// store 引用（调用方负责 destroy）。`overrides` 用于篡改第一个记录。
fn loadFromFile(io: std.Io, dir_path: []const u8, store_path: []const u8, identities: []const TestIdentity, overrides: Overrides) !*Store {
    var entries = try std.testing.allocator.dupe(TestIdentity, identities);
    defer std.testing.allocator.free(entries);
    if (overrides.revision) |revision| entries[0].revision = revision;
    if (overrides.id) |id| entries[0].id = id;
    if (overrides.client_public_fingerprint) |fp| entries[0].client_public_fingerprint = fp;
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, TestFile{ .identities = entries }, .{});
    defer std.testing.allocator.free(bytes);
    try dhcp_store.atomicWrite(io, store_path, bytes);
    const store = try std.testing.allocator.create(Store);
    errdefer std.testing.allocator.destroy(store);
    store.* = Store.init(std.testing.allocator, store_path);
    store.staging_dir = dir_path;
    try store.load(io);
    return store;
}

const Overrides = struct {
    revision: ?u64 = null,
    id: ?[]const u8 = null,
    client_public_fingerprint: ?[]const u8 = null,
};

/// 把 client 私钥与 host 公钥互换配对，验证 `ssh-keygen -y` 派生比对拒绝。
fn loadFromFileSwap(io: std.Io, dir_path: []const u8, store_path: []const u8, identities: []const TestIdentity) !*Store {
    var entries = try std.testing.allocator.dupe(TestIdentity, identities);
    defer std.testing.allocator.free(entries);
    const host_pub = entries[0].host_public_key;
    const host_fp = entries[0].host_public_fingerprint;
    entries[0].host_public_key = entries[0].client_public_key;
    entries[0].host_public_fingerprint = entries[0].client_public_fingerprint;
    entries[0].client_public_key = host_pub;
    entries[0].client_public_fingerprint = host_fp;
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, TestFile{ .identities = entries }, .{});
    defer std.testing.allocator.free(bytes);
    try dhcp_store.atomicWrite(io, store_path, bytes);
    const store = try std.testing.allocator.create(Store);
    errdefer std.testing.allocator.destroy(store);
    store.* = Store.init(std.testing.allocator, store_path);
    store.staging_dir = dir_path;
    try store.load(io);
    return store;
}
