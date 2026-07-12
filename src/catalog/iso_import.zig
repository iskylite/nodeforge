//! M3 Linux installation-media importer.
//!
//! The importer deliberately uses the kernel's read-only loop mount rather
//! than an ISO parser or a third-party extraction utility.  It never exposes
//! the mount: all published files are copied into NodeForge-owned roots before
//! the catalog snapshot is atomically replaced.

const std = @import("std");
const model = @import("../model.zig");
const paths = @import("../paths.zig");
const assets = @import("../assets/validate.zig");

pub const Request = struct {
    filename: []const u8,
    distro: []const u8,
    version: []const u8,
    arch: model.Arch,
};

pub const Result = struct {
    source_name: []const u8,
    iso_asset: model.AssetConfig,
    kernel_asset: model.AssetConfig,
    initrd_asset: model.AssetConfig,
    repository: ?model.RepositoryConfig,
    install_source: model.InstallSourceConfig,
};

/// Imports one Rocky/RHEL DVD ISO.  The caller owns the returned strings for
/// its allocator lifetime and is responsible for catalog publication.
pub fn importMedia(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, request: Request) !Result {
    if (!safeFilename(request.filename)) return error.UnsafeImportFilename;
    if (!std.mem.eql(u8, request.distro, "rocky") and !std.mem.eql(u8, request.distro, "ubuntu")) return error.UnsupportedImportDistro;

    // `sha256File` opens below the managed root with NOFOLLOW+RESOLVE_BENEATH,
    // establishing that the staging input is a regular, non-symlink file.
    var input_hash: [64]u8 = undefined;
    try assets.sha256File(io, paths.import_dir, request.filename, &input_hash);
    const input = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ paths.import_dir, request.filename });
    defer allocator.free(input);

    var random: [16]u8 = undefined;
    try io.randomSecure(&random);
    const tag = std.fmt.bytesToHex(random, .lower);
    const work = try std.fmt.allocPrint(allocator, "{s}/iso-import-{s}", .{ paths.work_dir, tag[0..] });
    defer allocator.free(work);
    const mount_point = try std.fmt.allocPrint(allocator, "{s}/mnt", .{work});
    defer allocator.free(mount_point);
    const staged_repo = try std.fmt.allocPrint(allocator, "{s}/repo", .{work});
    defer allocator.free(staged_repo);
    try std.Io.Dir.cwd().createDirPath(io, mount_point);
    try std.Io.Dir.cwd().createDirPath(io, staged_repo);
    defer std.Io.Dir.cwd().deleteTree(io, work) catch {};

    // ISO9660 is preferred.  Some media are UDF-only, so retry exactly once;
    // both attempts are private, read-only and never execute media contents.
    mountIso(io, allocator, input, mount_point, "iso9660") catch try mountIso(io, allocator, input, mount_point, "udf");
    var mounted = true;
    defer if (mounted) unmountIso(io, allocator, mount_point) catch {};

    const media = switch (request.arch) {
        .aarch64, .x86_64 => if (std.mem.eql(u8, request.distro, "rocky"))
            try validateRockyMedia(io, allocator, mount_point, request)
        else
            try validateUbuntuMedia(io, allocator, mount_point, request),
    };
    try copyTree(io, allocator, mount_point, staged_repo);
    try unmountIso(io, allocator, mount_point);
    mounted = false;

    const source_name = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}-iso", .{ request.distro, request.version, @tagName(request.arch) });
    const iso_rel = try std.fmt.allocPrint(allocator, "iso/{s}", .{request.filename});
    const kernel_rel = try std.fmt.allocPrint(allocator, "install/{s}/vmlinuz", .{source_name});
    const initrd_rel = try std.fmt.allocPrint(allocator, "install/{s}/initrd.img", .{source_name});
    const iso_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.asset_root, iso_rel });
    defer allocator.free(iso_destination);
    const kernel_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tftp.asset_root, kernel_rel });
    defer allocator.free(kernel_destination);
    const initrd_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.tftp.asset_root, initrd_rel });
    defer allocator.free(initrd_destination);
    const repo_destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.http.repository_root, source_name });
    defer allocator.free(repo_destination);

    const mounted_kernel = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, media.kernel_path });
    defer allocator.free(mounted_kernel);
    const mounted_initrd = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ staged_repo, media.initrd_path });
    defer allocator.free(mounted_initrd);
    try copyFileNoClobber(io, allocator, input, iso_destination);
    try copyFileNoClobber(io, allocator, mounted_kernel, kernel_destination);
    try copyFileNoClobber(io, allocator, mounted_initrd, initrd_destination);
    if (media.repository_base != null) try copyTreeNoClobber(io, allocator, staged_repo, repo_destination);

    var iso_hash: [64]u8 = undefined;
    var kernel_hash: [64]u8 = undefined;
    var initrd_hash: [64]u8 = undefined;
    try assets.sha256File(io, config.http.asset_root, iso_rel, &iso_hash);
    try assets.sha256File(io, config.tftp.asset_root, kernel_rel, &kernel_hash);
    try assets.sha256File(io, config.tftp.asset_root, initrd_rel, &initrd_hash);

    const repository_names = if (media.repository_base != null) blk: {
        const names = try allocator.alloc([]const u8, 1);
        names[0] = source_name;
        break :blk names;
    } else &.{};
    const distro_name = try allocator.dupe(u8, request.distro);
    const distro_version = try allocator.dupe(u8, request.version);
    return .{
        .source_name = source_name,
        .iso_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-image", .{source_name}), .kind = .iso, .path = iso_rel, .distro = distro_name, .version = distro_version, .arch = request.arch, .sha256 = try allocator.dupe(u8, &iso_hash) },
        .kernel_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-installer-kernel", .{source_name}), .kind = .kernel, .path = kernel_rel, .distro = distro_name, .version = distro_version, .arch = request.arch, .sha256 = try allocator.dupe(u8, &kernel_hash) },
        .initrd_asset = .{ .name = try std.fmt.allocPrint(allocator, "{s}-installer-initrd", .{source_name}), .kind = .installer_initrd, .path = initrd_rel, .distro = distro_name, .version = distro_version, .arch = request.arch, .sha256 = try allocator.dupe(u8, &initrd_hash) },
        .repository = if (media.repository_base) |base| .{ .name = source_name, .distro = distro_name, .version = distro_version, .arch = request.arch, .manager = if (std.mem.eql(u8, request.distro, "rocky")) .dnf else .apt, .base_url = if (base.len == 0) try std.fmt.allocPrint(allocator, "http://{s}:{d}/repos/{s}", .{ config.server.server_ip, config.server.http_port, source_name }) else try std.fmt.allocPrint(allocator, "http://{s}:{d}/repos/{s}/{s}", .{ config.server.server_ip, config.server.http_port, source_name, base }) } else null,
        .install_source = .{ .name = source_name, .distro = distro_name, .version = distro_version, .arch = request.arch, .source_asset = try std.fmt.allocPrint(allocator, "{s}-image", .{source_name}), .installer_kernel = try std.fmt.allocPrint(allocator, "{s}-installer-kernel", .{source_name}), .installer_initrd = try std.fmt.allocPrint(allocator, "{s}-installer-initrd", .{source_name}), .repositories = repository_names },
    };
}

const MediaLayout = struct {
    kernel_path: []const u8,
    initrd_path: []const u8,
    /// `null` means installer-only media; an empty slice means repository root.
    repository_base: ?[]const u8,
};

fn validateRockyMedia(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8, request: Request) !MediaLayout {
    _ = try assets.verifyRegularFile(io, mount_point, ".treeinfo");
    _ = try assets.verifyRegularFile(io, mount_point, "images/pxeboot/vmlinuz");
    _ = try assets.verifyRegularFile(io, mount_point, "images/pxeboot/initrd.img");
    const treeinfo_path = try std.fmt.allocPrint(allocator, "{s}/.treeinfo", .{mount_point});
    defer allocator.free(treeinfo_path);
    const treeinfo = try std.Io.Dir.cwd().readFileAlloc(io, treeinfo_path, allocator, .limited(256 * 1024));
    defer allocator.free(treeinfo);
    const repository_path = valueFor(treeinfo, "repository") orelse return error.MediaMetadataMissing;
    try assets.validateRelativePath(repository_path);
    const repomd_path = try std.fmt.allocPrint(allocator, "{s}/repodata/repomd.xml", .{repository_path});
    defer allocator.free(repomd_path);
    _ = try assets.verifyRegularFile(io, mount_point, repomd_path);
    if (!containsPrefixValue(treeinfo, "family", "Rocky") or !containsValue(treeinfo, "version", request.version) or !containsValue(treeinfo, "arch", @tagName(request.arch))) return error.MediaTupleMismatch;
    return .{ .kernel_path = "images/pxeboot/vmlinuz", .initrd_path = "images/pxeboot/initrd.img", .repository_base = try allocator.dupe(u8, repository_path) };
}

fn validateUbuntuMedia(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8, request: Request) !MediaLayout {
    _ = try assets.verifyRegularFile(io, mount_point, ".disk/info");
    _ = try assets.verifyRegularFile(io, mount_point, "casper/vmlinuz");
    _ = try assets.verifyRegularFile(io, mount_point, "casper/initrd");
    const info_path = try std.fmt.allocPrint(allocator, "{s}/.disk/info", .{mount_point});
    defer allocator.free(info_path);
    const info = try std.Io.Dir.cwd().readFileAlloc(io, info_path, allocator, .limited(64 * 1024));
    defer allocator.free(info);
    if (!std.mem.containsAtLeast(u8, info, 1, "Ubuntu-Server") or !std.mem.containsAtLeast(u8, info, 1, request.version) or !std.mem.containsAtLeast(u8, info, 1, ubuntuArch(request.arch))) return error.MediaTupleMismatch;
    const has_repository = try ubuntuRepositoryComplete(io, allocator, mount_point, request);
    return .{ .kernel_path = "casper/vmlinuz", .initrd_path = "casper/initrd", .repository_base = if (has_repository) "" else null };
}

fn ubuntuRepositoryComplete(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8, request: Request) !bool {
    assets.verifyDirectory(io, mount_point, "dists") catch return false;
    assets.verifyDirectory(io, mount_point, "pool") catch return false;
    var root = try std.Io.Dir.openDirAbsolute(io, mount_point, .{ .access_sub_paths = true });
    defer root.close(io);
    var dists = try root.openDir(io, "dists", .{ .iterate = true, .follow_symlinks = false });
    defer dists.close(io);
    var iterator = dists.iterate();
    while (try iterator.next(io)) |entry| {
        // ISO9660 directory iteration is permitted to report `unknown` kind;
        // the confined `Release` open below is the authoritative check.
        const release_relative = try std.fmt.allocPrint(allocator, "dists/{s}/Release", .{entry.name});
        defer allocator.free(release_relative);
        _ = assets.verifyRegularFile(io, mount_point, release_relative) catch continue;
        const release_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mount_point, release_relative });
        defer allocator.free(release_path);
        const release = try std.Io.Dir.cwd().readFileAlloc(io, release_path, allocator, .limited(256 * 1024));
        defer allocator.free(release);
        if (releaseHeaderEquals(release, "Version", request.version) and releaseHeaderHasToken(release, "Architectures", ubuntuArch(request.arch))) return true;
    }
    return false;
}

fn ubuntuArch(arch: model.Arch) []const u8 {
    return switch (arch) { .aarch64 => "arm64", .x86_64 => "amd64" };
}

fn containsValue(text: []const u8, key: []const u8, expected: []const u8) bool {
    const value = valueFor(text, key) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn containsPrefixValue(text: []const u8, key: []const u8, expected_prefix: []const u8) bool {
    const value = valueFor(text, key) orelse return false;
    return std.mem.startsWith(u8, value, expected_prefix);
}

fn valueFor(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..equal], " \t\r"), key)) continue;
        return std.mem.trim(u8, line[equal + 1 ..], " \t\r");
    }
    return null;
}

/// `.treeinfo` is `key = value`, while Debian/Ubuntu Release metadata is
/// `Key: value`.  Keep the parsers distinct so a permissive ISO text match
/// cannot accidentally treat a Rocky-style line as authenticated APT metadata.
fn releaseHeader(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t\r"), key)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t\r");
    }
    return null;
}

fn releaseHeaderEquals(text: []const u8, key: []const u8, expected: []const u8) bool {
    const value = releaseHeader(text, key) orelse return false;
    return std.mem.eql(u8, value, expected);
}

fn releaseHeaderHasToken(text: []const u8, key: []const u8, expected: []const u8) bool {
    const value = releaseHeader(text, key) orelse return false;
    var tokens = std.mem.tokenizeAny(u8, value, " \t");
    while (tokens.next()) |token| if (std.mem.eql(u8, token, expected)) return true;
    return false;
}

fn mountIso(io: std.Io, allocator: std.mem.Allocator, input: []const u8, mount_point: []const u8, fs_type: []const u8) !void {
    try run(io, allocator, &.{ "mount", "-t", fs_type, "-o", "ro,nosuid,nodev,noexec,loop", input, mount_point });
}
fn unmountIso(io: std.Io, allocator: std.mem.Allocator, mount_point: []const u8) !void {
    try run(io, allocator, &.{ "umount", mount_point });
}
fn copyTree(io: std.Io, allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    try runAt(io, allocator, &.{ "cp", "-a", "--no-dereference", ".", destination }, .{ .path = source });
}
fn copyTreeNoClobber(io: std.Io, allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    const status = try std.Io.Dir.cwd().createDirPathStatus(io, destination, .default_dir);
    if (status == .existed) return error.ImportDestinationExists;
    try runAt(io, allocator, &.{ "cp", "-a", "--no-dereference", "--no-clobber", ".", destination }, .{ .path = source });
}
fn copyFileNoClobber(io: std.Io, allocator: std.mem.Allocator, source: []const u8, destination: []const u8) !void {
    const parent = std.fs.path.dirname(destination) orelse return error.InvalidImportDestination;
    try std.Io.Dir.cwd().createDirPath(io, parent);
    // Avoid `cp --no-clobber`: a pre-existing target would look like a success
    // and could make a partial import appear publishable.
    if (std.Io.Dir.cwd().openFile(io, destination, .{})) |file| {
        var opened = file;
        opened.close(io);
        return error.ImportDestinationExists;
    } else |err| if (err != error.FileNotFound) return err;
    try run(io, allocator, &.{ "cp", "--no-dereference", "--no-clobber", source, destination });
}

fn runAt(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    const result = try std.process.run(allocator, io, .{ .argv = argv, .cwd = cwd, .stdout_limit = .limited(8 * 1024), .stderr_limit = .limited(8 * 1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return else return error.ImportCommandFailed,
        else => return error.ImportCommandFailed,
    }
}
fn run(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    return runAt(io, allocator, argv, .inherit);
}
fn safeFilename(value: []const u8) bool {
    return value.len > 0 and
        std.mem.indexOfAny(u8, value, "/\\") == null and
        std.mem.indexOfScalar(u8, value, 0) == null and
        !std.mem.eql(u8, value, ".") and
        !std.mem.eql(u8, value, "..");
}

test "import metadata parser accepts Rocky Minimal repository layout" {
    const treeinfo =
        \\arch = aarch64
        \\family = Rocky Linux Minimal
        \\repository = Minimal
        \\version = 9.7
    ;
    try std.testing.expect(containsPrefixValue(treeinfo, "family", "Rocky"));
    try std.testing.expect(containsValue(treeinfo, "version", "9.7"));
    try std.testing.expectEqualStrings("Minimal", valueFor(treeinfo, "repository").?);
    try std.testing.expect(safeFilename("Rocky-9.7-aarch64-minimal.iso"));
    try std.testing.expect(!safeFilename("../escape.iso"));
    try std.testing.expect(!safeFilename("nested/escape.iso"));
}

test "Ubuntu media metadata uses ISO architecture spelling" {
    try std.testing.expectEqualStrings("arm64", ubuntuArch(.aarch64));
    try std.testing.expectEqualStrings("amd64", ubuntuArch(.x86_64));
    const release =
        \\Origin: Ubuntu
        \\Version: 22.04
        \\Architectures: arm64
    ;
    try std.testing.expect(releaseHeaderEquals(release, "Version", "22.04"));
    try std.testing.expect(releaseHeaderHasToken(release, "Architectures", "arm64"));
}
