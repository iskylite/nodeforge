//! M4.7 profile `kernel_args` catalog mutation。
const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const config_load = @import("load.zig");
const validate = @import("validate.zig");

pub fn setKernelArgs(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8, profile_name: []const u8, kernel_args: ?[]const u8) !void {
    var parsed = try catalog_store.load(io, allocator, catalog_path);
    defer parsed.deinit();
    const profiles = try allocator.dupe(model.ProfileConfig, parsed.value.profiles);
    defer allocator.free(profiles);
    var found = false;
    for (profiles) |*profile| if (std.mem.eql(u8, profile.name, profile_name)) {
        profile.kernel_args = kernel_args;
        found = true;
        break;
    };
    if (!found) return error.ProfileNotFound;
    var candidate = parsed.value;
    candidate.profiles = profiles;
    var projected = model.projectCatalog(config.*, &candidate);
    config_load.canonicalizeKernelArgs(&projected);
    candidate.profiles = projected.profiles;
    try validate.validate(&projected, &candidate);
    try catalog_store.save(io, allocator, catalog_path, &candidate);
}

test "profile kernel args mutation canonicalizes projected catalog data" {
    var args = [_]u8{ ' ', 'i', 'o', 'm', 'm', 'u', '=', 'p', 't', ' ', ' ', 'i', 's', 'o', 'l', 'c', 'p', 'u', 's', '=', '0', ',', '2', ' ' };
    var profiles = [_]model.ProfileConfig{.{ .name = "diskless", .mode = .diskless, .distro = "rocky", .version = "9.7", .arch = .aarch64, .boot_bundle = "bundle", .kernel_args = &args }};
    var catalog: model.Catalog = .{ .profiles = &profiles };
    var projected = model.projectCatalog(.{ .server = .{ .server_ip = "192.0.2.1" } }, &catalog);
    config_load.canonicalizeKernelArgs(&projected);
    try std.testing.expectEqualStrings("iommu=pt isolcpus=0,2", profiles[0].kernel_args.?);
}
