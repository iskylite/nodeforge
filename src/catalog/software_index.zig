//! Repository software capability indexing.
const std = @import("std");
const model = @import("../model.zig");

pub fn build(io: std.Io, allocator: std.mem.Allocator, root: []const u8, manager: model.PackageManager) !model.SoftwareIndex {
    var capabilities: std.ArrayList(model.SoftwareCapability) = .empty;
    defer capabilities.deinit(allocator);
    var hashed: std.Io.Writer.Allocating = .init(allocator);
    defer hashed.deinit();
    switch (manager) {
        .dnf => try indexRhel(io, allocator, root, &capabilities, &hashed.writer),
        .apt => try indexUbuntu(io, allocator, root, &capabilities, &hashed.writer),
    }
    sortCapabilities(capabilities.items);
    var raw: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(hashed.written(), &raw, .{});
    const digest = std.fmt.bytesToHex(raw, .lower);
    return .{
        .revision_digest = try allocator.dupe(u8, &digest),
        .capabilities = try capabilities.toOwnedSlice(allocator),
    };
}

fn indexRhel(io: std.Io, allocator: std.mem.Allocator, root: []const u8, output: *std.ArrayList(model.SoftwareCapability), hashed: *std.Io.Writer) !void {
    const repomd_path = try std.fmt.allocPrint(allocator, "{s}/repodata/repomd.xml", .{root});
    defer allocator.free(repomd_path);
    const repomd = try std.Io.Dir.cwd().readFileAlloc(io, repomd_path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(repomd);
    try hashPart(hashed, "repomd", repomd);
    const primary_href = dataHref(repomd, "primary") orelse return error.PrimaryMetadataMissing;
    const primary_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, primary_href });
    defer allocator.free(primary_path);
    const primary = try readMaybeCompressed(io, allocator, primary_path);
    defer allocator.free(primary);
    try hashPart(hashed, "primary", primary);
    try parseXmlItems(allocator, primary, "package", "name", .package, output);
    if (dataHref(repomd, "group")) |href| {
        const comps_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, href });
        defer allocator.free(comps_path);
        const comps = try readMaybeCompressed(io, allocator, comps_path);
        defer allocator.free(comps);
        try hashPart(hashed, "comps", comps);
        try parseXmlItems(allocator, comps, "environment", "id", .environment, output);
        try parseXmlItems(allocator, comps, "group", "id", .group, output);
    }
}

fn indexUbuntu(io: std.Io, allocator: std.mem.Allocator, root: []const u8, output: *std.ArrayList(model.SoftwareCapability), hashed: *std.Io.Writer) !void {
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "find", root, "-type", "f", "-name", "Packages*", "-print" }, .stdout_limit = .limited(8 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) { .exited => |code| if (code != 0) return error.PackageMetadataSearchFailed, else => return error.PackageMetadataSearchFailed }
    var paths = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    var found = false;
    while (paths.next()) |path| {
        found = true;
        const packages = try readMaybeCompressed(io, allocator, path);
        defer allocator.free(packages);
        try hashPart(hashed, path, packages);
        try parseDebianPackages(allocator, packages, output);
    }
    if (!found) return error.PackageMetadataMissing;
}

fn dataHref(xml: []const u8, kind: []const u8) ?[]const u8 {
    var marker_buffer: [96]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buffer, "type=\"{s}\"", .{kind}) catch return null;
    const data_start = std.mem.indexOf(u8, xml, marker) orelse return null;
    const tail = xml[data_start..@min(xml.len, data_start + 4096)];
    const href_marker = "href=\"";
    const href_start = (std.mem.indexOf(u8, tail, href_marker) orelse return null) + href_marker.len;
    const href_end = std.mem.indexOfScalar(u8, tail[href_start..], '"') orelse return null;
    return tail[href_start .. href_start + href_end];
}

fn parseXmlItems(allocator: std.mem.Allocator, xml: []const u8, container: []const u8, id_tag: []const u8, kind: model.SoftwareKind, output: *std.ArrayList(model.SoftwareCapability)) !void {
    var open_buffer: [64]u8 = undefined;
    var close_buffer: [64]u8 = undefined;
    var id_open_buffer: [64]u8 = undefined;
    var id_close_buffer: [64]u8 = undefined;
    const open = try std.fmt.bufPrint(&open_buffer, "<{s}", .{container});
    const close = try std.fmt.bufPrint(&close_buffer, "</{s}>", .{container});
    const id_open = try std.fmt.bufPrint(&id_open_buffer, "<{s}>", .{id_tag});
    const id_close = try std.fmt.bufPrint(&id_close_buffer, "</{s}>", .{id_tag});
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, xml, cursor, open)) |start| {
        const end_pos = std.mem.indexOfPos(u8, xml, start, close) orelse break;
        const block = xml[start .. end_pos + close.len];
        const id = xmlText(block, id_open, id_close) orelse { cursor = end_pos + close.len; continue; };
        const name = xmlText(block, "<name>", "</name>") orelse id;
        const description = xmlText(block, "<description>", "</description>");
        try appendUnique(allocator, output, .{ .id = try allocator.dupe(u8, id), .name = try allocator.dupe(u8, name), .kind = kind, .description = if (description) |value| try allocator.dupe(u8, value) else null });
        cursor = end_pos + close.len;
    }
}

fn parseDebianPackages(allocator: std.mem.Allocator, bytes: []const u8, output: *std.ArrayList(model.SoftwareCapability)) !void {
    var stanzas = std.mem.splitSequence(u8, bytes, "\n\n");
    while (stanzas.next()) |stanza| {
        const package = field(stanza, "Package") orelse continue;
        const description = field(stanza, "Description");
        const section = field(stanza, "Section");
        const kind: model.SoftwareKind = if (section != null and std.mem.indexOf(u8, section.?, "metapackages") != null) .metapackage else .package;
        try appendUnique(allocator, output, .{ .id = try allocator.dupe(u8, package), .name = try allocator.dupe(u8, package), .kind = kind, .description = if (description) |value| try allocator.dupe(u8, value) else null });
        if (field(stanza, "Task")) |tasks| {
            var iterator = std.mem.splitScalar(u8, tasks, ',');
            while (iterator.next()) |raw| {
                const task = std.mem.trim(u8, raw, " \t");
                if (task.len != 0) try appendUnique(allocator, output, .{ .id = try allocator.dupe(u8, task), .name = try allocator.dupe(u8, task), .kind = .task });
            }
        }
    }
}

fn appendUnique(allocator: std.mem.Allocator, output: *std.ArrayList(model.SoftwareCapability), value: model.SoftwareCapability) !void {
    for (output.items) |existing| if (existing.kind == value.kind and std.mem.eql(u8, existing.id, value.id)) {
        allocator.free(value.id);
        allocator.free(value.name);
        if (value.description) |description| allocator.free(description);
        return;
    };
    try output.append(allocator, value);
}

fn field(stanza: []const u8, name: []const u8) ?[]const u8 {
    var marker_buffer: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&marker_buffer, "{s}: ", .{name}) catch return null;
    var lines = std.mem.splitScalar(u8, stanza, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, marker)) return line[marker.len..];
    return null;
}
fn xmlText(block: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const start = (std.mem.indexOf(u8, block, open) orelse return null) + open.len;
    const end = std.mem.indexOfPos(u8, block, start, close) orelse return null;
    return std.mem.trim(u8, block[start..end], " \t\r\n");
}
fn readMaybeCompressed(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.mem.endsWith(u8, path, ".gz") and !std.mem.endsWith(u8, path, ".xz"))
        return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(128 * 1024 * 1024));
    const command = if (std.mem.endsWith(u8, path, ".gz")) "gzip" else "xz";
    const result = try std.process.run(allocator, io, .{ .argv = &.{ command, "-cd", "--", path }, .stdout_limit = .limited(128 * 1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
    allocator.free(result.stderr);
    switch (result.term) { .exited => |code| if (code != 0) { allocator.free(result.stdout); return error.MetadataDecompressionFailed; }, else => { allocator.free(result.stdout); return error.MetadataDecompressionFailed; } }
    return result.stdout;
}
fn hashPart(writer: *std.Io.Writer, name: []const u8, bytes: []const u8) !void {
    try writer.print("{s}:{d}\n", .{ name, bytes.len });
    try writer.writeAll(bytes);
    try writer.writeByte('\n');
}
fn sortCapabilities(values: []model.SoftwareCapability) void {
    std.mem.sort(model.SoftwareCapability, values, {}, struct {
        fn lessThan(_: void, left: model.SoftwareCapability, right: model.SoftwareCapability) bool {
            const kind_order = std.mem.order(u8, @tagName(left.kind), @tagName(right.kind));
            return kind_order == .lt or (kind_order == .eq and std.mem.lessThan(u8, left.id, right.id));
        }
    }.lessThan);
}

test "indexes Debian packages tasks and metapackages" {
    var values: std.ArrayList(model.SoftwareCapability) = .empty;
    defer {
        for (values.items) |value| { std.testing.allocator.free(value.id); std.testing.allocator.free(value.name); if (value.description) |description| std.testing.allocator.free(description); }
        values.deinit(std.testing.allocator);
    }
    try parseDebianPackages(std.testing.allocator, "Package: ubuntu-server\nSection: metapackages\nTask: server, ssh-server\nDescription: Server seed\n\nPackage: vim\nSection: editors\n", &values);
    try std.testing.expectEqual(@as(usize, 4), values.items.len);
}
