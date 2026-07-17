//! M4.7 deployment initialization and offline reset primitives.
//!
//! CLI owns prompting/confirmation; this module owns path-bounded filesystem
//! effects. All generated paths come from runtime `Paths`, configuration is
//! validated before publication, and legacy config/catalog are backed up before
//! the manifest becomes visible.

const std = @import("std");
const paths_mod = @import("paths.zig");
const model = @import("model.zig");
const config_load = @import("config/load.zig");
const config_store = @import("config/store.zig");
const catalog_store = @import("catalog/store.zig");
const validate = @import("config/validate.zig");
const deployment_control = @import("state/deployment_control.zig");
const model_transaction = @import("state/model_transaction.zig");
const atomicWrite = @import("state/dhcp_store.zig").atomicWrite;

pub const Network = struct {
    bind_interface: []const u8 = "eth0",
    server_ip: []const u8 = "192.168.50.1",
    subnet: []const u8 = "192.168.50.0/24",
    pool_start: []const u8 = "192.168.50.100",
    pool_end: []const u8 = "192.168.50.200",
};

pub fn generatedConfig(p: *const paths_mod.Paths, network: Network) model.AppConfig {
    return .{
        .schema_version = 2,
        .server = .{ .bind_interface = network.bind_interface, .server_ip = network.server_ip },
        .http = .{ .asset_root = p.iso_dir, .repository_root = p.repos_dir },
        .tftp = .{ .asset_root = p.boot_dir },
        .dhcp = .{ .subnet = network.subnet, .pool_start = network.pool_start, .pool_end = network.pool_end },
    };
}

pub fn repairDirectories(io: std.Io, allocator: std.mem.Allocator, p: *const paths_mod.Paths) !void {
    const cwd = std.Io.Dir.cwd();
    inline for (.{ p.bin_dir, p.systemd_dir, p.config_dir, p.catalog_dir, p.state_dir, p.logs_dir, p.iso_dir, p.boot_dir, p.repos_dir, p.keys_dir, p.initrd_dir, p.rootfs_dir, p.bundles_dir, p.provisioned_dir, p.run_dir, p.work_dir, p.import_dir, p.model_transactions_dir }) |directory|
        try cwd.createDirPath(io, directory);
    inline for (.{ p.install_root, p.bin_dir, p.systemd_dir, p.logs_dir, p.assets_dir, p.iso_dir, p.boot_dir, p.repos_dir, p.initrd_dir, p.rootfs_dir, p.bundles_dir }) |directory|
        try chmod(io, allocator, "750", directory);
    inline for (.{ p.config_dir, p.catalog_dir, p.state_dir, p.keys_dir, p.provisioned_dir, p.run_dir, p.work_dir, p.import_dir, p.model_transactions_dir }) |directory|
        try chmod(io, allocator, "700", directory);
}

/// Copy the same-bundle CLI/daemon pair atomically. The caller creates the
/// marker only after both copies succeed, so interrupted installs never pass
/// normal bootstrap validation.
pub fn installBundle(io: std.Io, allocator: std.mem.Allocator, p: *const paths_mod.Paths) !void {
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const source_dir = std.fs.path.dirname(executable) orelse return error.InvalidBundleLayout;
    const cli_source = try std.fmt.allocPrint(allocator, "{s}/nodeforge", .{source_dir});
    defer allocator.free(cli_source);
    const daemon_source = try std.fmt.allocPrint(allocator, "{s}/nodeforged", .{source_dir});
    defer allocator.free(daemon_source);
    if (!regularFile(io, cli_source) or !regularFile(io, daemon_source)) return error.IncompleteInstallBundle;
    try verifyCompanion(io, allocator, daemon_source);
    try repairDirectories(io, allocator, p);
    if (!samePath(io, allocator, cli_source, p.nodeforge_path)) try std.Io.Dir.copyFileAbsolute(cli_source, p.nodeforge_path, io, .{ .replace = true, .make_path = true });
    if (!samePath(io, allocator, daemon_source, p.nodeforged_path)) try std.Io.Dir.copyFileAbsolute(daemon_source, p.nodeforged_path, io, .{ .replace = true, .make_path = true });
    try atomicWrite(io, p.marker_path, "nodeforge-root-v1\n");
}

pub fn initialize(io: std.Io, allocator: std.mem.Allocator, p: *const paths_mod.Paths, network: Network) !void {
    const config = generatedConfig(p, network);
    // 空 distro 索引是正常的首次安装状态；首个通过媒体布局校验的 ISO
    // 会与 install source 一起原子创建对应 family/version/arch 能力记录。
    const catalog: model.Catalog = .{};
    try validate.validate(&config, &catalog);
    try installBundle(io, allocator, p);
    try config_store.save(io, allocator, p.config_path, &config);
    try catalog_store.initializeEmpty(io, allocator, p.catalog_dir);
    const unit = try renderSystemd(allocator, p);
    defer allocator.free(unit);
    try atomicWrite(io, p.service_path, unit);
}

/// Upgrade schema 1 in place. Backups and a marker remain if a later step
/// fails; rerunning is idempotent because manifest commits are digest checked.
pub fn migrateLegacy(io: std.Io, allocator: std.mem.Allocator, p: *const paths_mod.Paths) !bool {
    var parsed = try config_load.load(io, allocator, p.config_path);
    defer parsed.deinit();
    const marker = try std.fmt.allocPrint(allocator, "{s}/m4.7-migration.json", .{p.state_dir});
    defer allocator.free(marker);
    if (parsed.value.schema_version == 2) {
        // A crash after publishing config.json can leave a valid manifest beside
        // legacy catalog.json. The migration marker is the proof that this mixed
        // layout belongs to one known transaction; finish its cleanup instead of
        // letting the normal catalog loader guess which generation is authoritative.
        if (!regularFile(io, marker)) return false;
        const backup = try std.fmt.allocPrint(allocator, "{s}.m4.7.bak", .{p.legacy_catalog_path});
        defer allocator.free(backup);
        const had_legacy = regularFile(io, p.legacy_catalog_path);
        if (had_legacy) {
            if (!regularFile(io, backup)) try std.Io.Dir.copyFileAbsolute(p.legacy_catalog_path, backup, io, .{ .replace = false, .make_path = true });
            try std.Io.Dir.cwd().deleteFile(io, p.legacy_catalog_path);
        }
        var current_catalog = catalog_store.load(io, allocator, p.catalog_dir) catch |err| {
            if (had_legacy) std.Io.Dir.copyFileAbsolute(backup, p.legacy_catalog_path, io, .{ .replace = true, .make_path = true }) catch {};
            return err;
        };
        defer current_catalog.deinit();
        const effective = model.projectCatalog(parsed.value, &current_catalog.value);
        try validate.validate(&effective, &current_catalog.value);
        try std.Io.Dir.cwd().deleteFile(io, marker);
        return true;
    }
    if (parsed.value.schema_version != 1) return error.UnsupportedSchemaVersion;
    var legacy_catalog: ?std.json.Parsed(model.Catalog) = catalog_store.loadLegacy(io, allocator, p.legacy_catalog_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (legacy_catalog) |*loaded| loaded.deinit();
    var catalog = if (legacy_catalog) |*loaded| loaded.value else model.Catalog{};
    catalog.schema_version = 2;
    catalog.distros = parsed.value.distros;
    catalog.profiles = parsed.value.profiles;
    catalog.nodes = parsed.value.nodes;
    catalog.provisioning_bundles = parsed.value.provisioning_bundles;
    var startup = parsed.value;
    startup.schema_version = 2;
    const projected = model.projectCatalog(startup, &catalog);
    try validate.validate(&projected, &catalog);
    try repairDirectories(io, allocator, p);
    const config_backup = try std.fmt.allocPrint(allocator, "{s}.m4.7.bak", .{p.config_path});
    defer allocator.free(config_backup);
    if (!regularFile(io, config_backup)) try std.Io.Dir.copyFileAbsolute(p.config_path, config_backup, io, .{ .replace = false, .make_path = true });
    const revision = try deployment_control.revisionForModel(allocator, &projected, &catalog);
    const marker_bytes = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"state\":\"prepared\",\"request_digest\":\"{s}\"}}\n", .{revision.desired_digest});
    defer allocator.free(marker_bytes);
    try atomicWrite(io, marker, marker_bytes);
    try catalog_store.save(io, allocator, p.catalog_dir, &catalog);
    try config_store.save(io, allocator, p.config_path, &startup);
    if (regularFile(io, p.legacy_catalog_path)) {
        const backup = try std.fmt.allocPrint(allocator, "{s}.m4.7.bak", .{p.legacy_catalog_path});
        defer allocator.free(backup);
        if (!regularFile(io, backup)) try std.Io.Dir.copyFileAbsolute(p.legacy_catalog_path, backup, io, .{ .replace = false, .make_path = true });
        try std.Io.Dir.cwd().deleteFile(io, p.legacy_catalog_path);
    }
    try std.Io.Dir.cwd().deleteFile(io, marker);
    return true;
}

pub fn resetState(io: std.Io, allocator: std.mem.Allocator, p: *const paths_mod.Paths) ![]u8 {
    // Reset may archive completed evidence, but never deletes an unresolved
    // catalog/model journal. Both coordinators must reach a proven generation.
    if (exists(io, p.catalog_dir)) {
        var catalog = catalog_store.load(io, allocator, p.catalog_dir) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (catalog) |*loaded| loaded.deinit();
    }
    _ = try model_transaction.recoverAll(io, allocator, p.model_transactions_dir);
    const stamp = std.Io.Clock.real.now(io).toSeconds();
    const backup = try std.fmt.allocPrint(allocator, "{s}/backups/state-{d}", .{ p.install_root, stamp });
    errdefer allocator.free(backup);
    try std.Io.Dir.cwd().createDirPath(io, backup);
    var manifest: std.Io.Writer.Allocating = .init(allocator);
    defer manifest.deinit();
    try manifest.writer.writeAll("{\"schema_version\":1,\"files\":[");
    var first = true;
    for ([_][]const u8{ p.leases_path, p.node_status_path, p.deployment_control_path, p.boot_sessions_path, p.node_inventory_path, p.operations_path }) |state_path| {
        if (!regularFile(io, state_path)) continue;
        const destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ backup, std.fs.path.basename(state_path) });
        defer allocator.free(destination);
        try std.Io.Dir.copyFileAbsolute(state_path, destination, io, .{ .replace = false, .make_path = true });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, destination, allocator, .limited(16 * 1024 * 1024));
        defer allocator.free(bytes);
        var digest: [64]u8 = undefined;
        sha256(bytes, &digest);
        if (!first) try manifest.writer.writeByte(',');
        first = false;
        try manifest.writer.print("{{\"file\":{f},\"sha256\":{f}}}", .{ std.json.fmt(std.fs.path.basename(state_path), .{}), std.json.fmt(&digest, .{}) });
        try std.Io.Dir.cwd().deleteFile(io, state_path);
    }
    try manifest.writer.writeAll("]}\n");
    const backup_manifest = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{backup});
    defer allocator.free(backup_manifest);
    try atomicWrite(io, backup_manifest, manifest.written());
    if (exists(io, p.provisioned_dir)) try std.Io.Dir.cwd().deleteTree(io, p.provisioned_dir);
    try std.Io.Dir.cwd().createDirPath(io, p.provisioned_dir);
    return backup;
}

pub fn renderSystemd(allocator: std.mem.Allocator, p: *const paths_mod.Paths) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\[Unit]
        \\Description=NodeForge provisioning daemon
        \\After=network-online.target
        \\Wants=network-online.target
        \\
        \\[Service]
        \\Type=simple
        \\WorkingDirectory={s}
        \\ExecStartPre={s} --check --log-output file
        \\ExecStart={s} --log-output file
        \\Restart=on-failure
        \\RestartSec=2s
        \\NoNewPrivileges=true
        \\PrivateMounts=true
        \\CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_ADMIN
        \\AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_ADMIN
        \\
        \\[Install]
        \\WantedBy=multi-user.target
        \\
    , .{ p.install_root, p.nodeforged_path, p.nodeforged_path });
}

fn regularFile(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .file;
}
fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}
fn samePath(io: std.Io, allocator: std.mem.Allocator, left: []const u8, right: []const u8) bool {
    const a = std.Io.Dir.cwd().realPathFileAlloc(io, left, allocator) catch return false;
    defer allocator.free(a);
    const b = std.Io.Dir.cwd().realPathFileAlloc(io, right, allocator) catch return false;
    defer allocator.free(b);
    return std.mem.eql(u8, a, b);
}

fn verifyCompanion(io: std.Io, allocator: std.mem.Allocator, daemon: []const u8) !void {
    const version = @import("version.zig");
    const result = std.process.run(allocator, io, .{ .argv = &.{ daemon, "--version" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch return error.BundleProvenanceMismatch;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.BundleProvenanceMismatch,
        else => return error.BundleProvenanceMismatch,
    }
    const expected = try std.fmt.allocPrint(allocator, "nodeforged {s} (commit {s}, built {s}, {s})", .{ version.version, version.shortCommit(), version.build_time, if (version.git_dirty) "dirty" else "clean" });
    defer allocator.free(expected);
    if (!std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), expected)) return error.BundleProvenanceMismatch;
}

fn sha256(bytes: []const u8, output: *[64]u8) void {
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &raw, .{});
    _ = std.fmt.bufPrint(output, "{x}", .{raw}) catch unreachable;
}

fn chmod(io: std.Io, allocator: std.mem.Allocator, mode: []const u8, path: []const u8) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "chmod", mode, path }, .stdout_limit = .limited(1024), .stderr_limit = .limited(1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.ChmodFailed,
        else => return error.ChmodFailed,
    }
}

test "generated config and systemd use custom runtime root" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try temp.dir.realPath(std.testing.io, &buffer);
    var p = try paths_mod.Paths.candidate(std.testing.io, std.testing.allocator, buffer[0..n]);
    defer p.deinit(std.testing.allocator);
    const config = generatedConfig(&p, .{});
    try std.testing.expectEqualStrings(p.iso_dir, config.http.asset_root);
    const unit = try renderSystemd(std.testing.allocator, &p);
    defer std.testing.allocator.free(unit);
    try std.testing.expect(std.mem.indexOf(u8, unit, p.nodeforged_path) != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "--config") == null);
}
