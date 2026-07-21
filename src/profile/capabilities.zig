//! Adapter capability registry for every canonical mutable configuration path.
const std = @import("std");
const model = @import("../model.zig");
const properties = @import("../cli/properties.zig");

pub const Status = enum { native, translated, not_applicable, unsupported };
pub const Entry = struct { domain: []const u8, kickstart: Status, autoinstall: Status };

pub const entries = [_]Entry{
    .{ .domain = "resource", .kickstart = .native, .autoinstall = .native },
    .{ .domain = "discovery", .kickstart = .native, .autoinstall = .native },
    .{ .domain = "network", .kickstart = .native, .autoinstall = .native },
    .{ .domain = "storage", .kickstart = .native, .autoinstall = .native },
    .{ .domain = "install.storage", .kickstart = .native, .autoinstall = .native },
    .{ .domain = "system.localization", .kickstart = .native, .autoinstall = .native },
    .{ .domain = "system.connectivity", .kickstart = .translated, .autoinstall = .translated },
    .{ .domain = "system.ssh", .kickstart = .native, .autoinstall = .native },
    .{ .domain = "system.users", .kickstart = .native, .autoinstall = .native },
    .{ .domain = "system.security", .kickstart = .native, .autoinstall = .native },
    .{ .domain = "software", .kickstart = .native, .autoinstall = .translated },
    .{ .domain = "kernel_args", .kickstart = .native, .autoinstall = .translated },
    .{ .domain = "install.apt", .kickstart = .not_applicable, .autoinstall = .native },
    .{ .domain = "install.bootloader", .kickstart = .native, .autoinstall = .translated },
    .{ .domain = "install.completion", .kickstart = .native, .autoinstall = .translated },
    .{ .domain = "install.updates", .kickstart = .translated, .autoinstall = .native },
    .{ .domain = "install.proxy", .kickstart = .translated, .autoinstall = .native },
    .{ .domain = "install.reinstall_policy", .kickstart = .native, .autoinstall = .native },
    .{ .domain = "install.post_install", .kickstart = .native, .autoinstall = .translated },
};

pub fn status(adapter: model.InstallAdapter, path: []const u8, applicability: properties.Applicability) Status {
    if ((applicability == .kickstart and adapter != .kickstart) or (applicability == .autoinstall and adapter != .autoinstall)) return .not_applicable;
    const canonical = stripOverride(path);
    const domain = domainFor(canonical) orelse return .unsupported;
    return if (adapter == .kickstart) domain.kickstart else domain.autoinstall;
}

fn stripOverride(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "overrides.")) return path["overrides.".len..];
    return path;
}

fn domainFor(path: []const u8) ?Entry {
    for (entries) |entry| if (std.mem.eql(u8, path, entry.domain) or std.mem.startsWith(u8, path, entry.domain) and path.len > entry.domain.len and path[entry.domain.len] == '.') return entry;
    if (std.mem.eql(u8, path, "steps")) return .{ .domain = "install.post_install", .kickstart = .native, .autoinstall = .translated };
    if (std.mem.startsWith(u8, path, "mac") or std.mem.startsWith(u8, path, "arch") or std.mem.startsWith(u8, path, "profile") or std.mem.startsWith(u8, path, "pxe.") or std.mem.startsWith(u8, path, "hostname") or std.mem.startsWith(u8, path, "deploy") or std.mem.startsWith(u8, path, "http_accel") or std.mem.startsWith(u8, path, "install_source")) return entries[0];
    return null;
}

test "every mutable spec has an explicit adapter capability" {
    inline for (.{ model.InstallAdapter.kickstart, model.InstallAdapter.autoinstall }) |adapter| {
        for (properties.properties) |spec| if (spec.mutability == .mutable) try std.testing.expect(status(adapter, spec.path, spec.applicability) != .unsupported);
        for (properties.collections) |spec| if (spec.mutability == .mutable) try std.testing.expect(status(adapter, spec.path, .all) != .unsupported);
    }
}
