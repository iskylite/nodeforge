//! v0.2.3 §5.4 CLI 级扫描契约测试。
//!
//! 对每个公开 Profile mutation 入口逐一断言"成功恰好 +1、失败/no-op +0"，
//! 防止新增入口绕过 `mutateProfileMetadata` 各自递增 revision。每个入口都在
//! 独立 catalog 目录（manifest 布局）内走完整的 load-modify-validate-save
//! 事务，覆盖入口：
//! - scalar `profile set`/`unset`（`scalar_mutation.profileBatch`）；
//! - collection values（`value_mutation.profile`）；
//! - item add/set/remove/replace（`item_mutation.profile`/`profileUserValues`/
//!   `replaceProfile`）；
//! - kernel args（`profile_mutation.setKernelArgs`）；
//! - identity rotation（`profile_mutation.rotateSshIdentity`）；
//! - clone property patch（`profile_mutation.cloneProfile`，target 初始 revision
//!   为 1 且 source 不递增）。

const std = @import("std");
const model = @import("../model.zig");
const catalog_store = @import("../catalog/store.zig");
const scalar_mutation = @import("scalar_mutation.zig");
const value_mutation = @import("value_mutation.zig");
const item_mutation = @import("item_mutation.zig");
const profile_mutation = @import("profile_mutation.zig");

/// 最小合法启动配置：仅依赖 validate.zig 的 test fixture 形状，distro 由
/// catalog.distros 经 `model.projectCatalog` 投影到 config。
const scan_config = model.AppConfig{
    .server = .{ .bind_interface = "pxe0", .server_ip = "192.168.50.1" },
    .http = .{ .asset_root = "/tmp/nodeforge/iso", .repository_root = "/tmp/nodeforge/repos" },
    .tftp = .{ .asset_root = "/tmp/nodeforge/boot" },
};

/// 最小合法 catalog：distro + iso/kernel/initrd assets + install_source +
/// install profile 完整引用链，须通过 `validate.validate`（与 validate.zig 的
/// "install profile derives its platform from source" fixture 同构）。
fn scanCatalog() model.Catalog {
    return .{
        .schema_version = 5,
        .distros = &.{.{ .name = "rocky", .family = .rhel, .versions = &.{.{ .version = "9.7", .archs = &.{.aarch64}, .install_adapter = .kickstart, .package_manager = .dnf }} }},
        .assets = &.{
            .{ .name = "rocky-iso", .kind = .iso, .path = "iso/rocky.iso", .distro = "rocky", .version = "9.7", .arch = .aarch64 },
            .{ .name = "rocky-kernel", .kind = .kernel, .path = "install/rocky/vmlinuz", .distro = "rocky", .version = "9.7", .arch = .aarch64 },
            .{ .name = "rocky-initrd", .kind = .installer_initrd, .path = "install/rocky/initrd.img", .distro = "rocky", .version = "9.7", .arch = .aarch64 },
        },
        .install_sources = &.{.{ .name = "rocky-source", .distro = "rocky", .version = "9.7", .arch = .aarch64, .source_asset = "rocky-iso", .installer_kernel = "rocky-kernel", .installer_initrd = "rocky-initrd" }},
        .profiles = &.{.{ .name = "install", .install_source = "rocky-source" }},
    };
}

/// profileUserValues 用例预置一个用户，使入口作用于真实存在的 item。
fn scanCatalogWithUser() model.Catalog {
    return .{
        .schema_version = 5,
        .distros = &.{.{ .name = "rocky", .family = .rhel, .versions = &.{.{ .version = "9.7", .archs = &.{.aarch64}, .install_adapter = .kickstart, .package_manager = .dnf }} }},
        .assets = &.{
            .{ .name = "rocky-iso", .kind = .iso, .path = "iso/rocky.iso", .distro = "rocky", .version = "9.7", .arch = .aarch64 },
            .{ .name = "rocky-kernel", .kind = .kernel, .path = "install/rocky/vmlinuz", .distro = "rocky", .version = "9.7", .arch = .aarch64 },
            .{ .name = "rocky-initrd", .kind = .installer_initrd, .path = "install/rocky/initrd.img", .distro = "rocky", .version = "9.7", .arch = .aarch64 },
        },
        .install_sources = &.{.{ .name = "rocky-source", .distro = "rocky", .version = "9.7", .arch = .aarch64, .source_asset = "rocky-iso", .installer_kernel = "rocky-kernel", .installer_initrd = "rocky-initrd" }},
        .profiles = &.{.{ .name = "install", .install_source = "rocky-source", .system = .{ .users = &.{.{ .name = "ops", .password = "asdf1234" }} } }},
    };
}

const ScanAction = *const fn (io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, path: []const u8) anyerror!void;

fn revisionOf(io: std.Io, allocator: std.mem.Allocator, path: []const u8, name: []const u8) !u64 {
    var parsed = try catalog_store.load(io, allocator, path);
    defer parsed.deinit();
    for (parsed.value.profiles) |profile| if (std.mem.eql(u8, profile.name, name)) return profile.revision;
    return error.ProfileNotFound;
}

fn freshCase(io: std.Io, allocator: std.mem.Allocator, base: []const u8, label: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, label });
    errdefer allocator.free(path);
    try catalog_store.save(io, allocator, path, &scanCatalog());
    return path;
}

fn freshCaseWithUser(io: std.Io, allocator: std.mem.Allocator, base: []const u8, label: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, label });
    errdefer allocator.free(path);
    try catalog_store.save(io, allocator, path, &scanCatalogWithUser());
    return path;
}

/// 成功入口：revision 恰好 +1。
fn expectBump(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, path: []const u8, action: ScanAction) !void {
    const before = try revisionOf(io, allocator, path, "install");
    try action(io, allocator, config, path);
    try std.testing.expectEqual(before + 1, try revisionOf(io, allocator, path, "install"));
}

/// 失败/no-op 入口：revision 不变（helper 未被触碰）。
fn expectNoBump(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, path: []const u8, action: ScanAction, expected_error: anyerror) !void {
    const before = try revisionOf(io, allocator, path, "install");
    try std.testing.expectError(expected_error, action(io, allocator, config, path));
    try std.testing.expectEqual(before, try revisionOf(io, allocator, path, "install"));
}

test "v0.2.3 §5.4: every public profile mutation bumps revision exactly once" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const cfg = scan_config;

    // scalar `profile set`：system.ssh.enabled = true。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "scalar-set");
        defer std.testing.allocator.free(path);
        try expectBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try scalar_mutation.profileBatch(io, allocator, config, catalog_path, "install", &.{.{ .key = "system.ssh.enabled", .value = "true" }});
            }
        }.run);
    }

    // scalar `profile unset`：system.hosts_content 清空。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "scalar-unset");
        defer std.testing.allocator.free(path);
        try expectBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try scalar_mutation.profileBatch(io, allocator, config, catalog_path, "install", &.{.{ .key = "system.hosts_content", .value = null }});
            }
        }.run);
    }

    // scalar 失败：profile 不存在。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "scalar-missing");
        defer std.testing.allocator.free(path);
        try expectNoBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try scalar_mutation.profileBatch(io, allocator, config, catalog_path, "missing", &.{.{ .key = "system.ssh.enabled", .value = "true" }});
            }
        }.run, error.ProfileNotFound);
    }

    // scalar 失败：非法枚举值在 helper 前拒绝。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "scalar-invalid");
        defer std.testing.allocator.free(path);
        try expectNoBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try scalar_mutation.profileBatch(io, allocator, config, catalog_path, "install", &.{.{ .key = "system.ssh.root_login", .value = "banana" }});
            }
        }.run, error.InvalidPropertyValue);
    }

    // collection values：system.connectivity.ntp_servers add。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "value-add");
        defer std.testing.allocator.free(path);
        try expectBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try value_mutation.profile(io, allocator, config, catalog_path, "install", "system.connectivity.ntp_servers", .add, &.{"ntp.example"});
            }
        }.run);
    }

    // collection values 失败：profile 不存在。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "value-missing");
        defer std.testing.allocator.free(path);
        try expectNoBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try value_mutation.profile(io, allocator, config, catalog_path, "missing", "system.connectivity.ntp_servers", .add, &.{"ntp.example"});
            }
        }.run, error.ProfileNotFound);
    }

    // collection values 失败：未知 key 在加载前拒绝。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "value-unknown");
        defer std.testing.allocator.free(path);
        try expectNoBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try value_mutation.profile(io, allocator, config, catalog_path, "install", "no.such.collection", .add, &.{"x"});
            }
        }.run, error.UnknownProperty);
    }

    // item add：system.users 追加 ops。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "item-add");
        defer std.testing.allocator.free(path);
        try expectBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try item_mutation.profile(io, allocator, config, catalog_path, "install", .{ .operation = .add, .key = "system.users", .identity = "ops", .name = "ops", .password = "asdf1234" });
            }
        }.run);
    }

    // item 失败：profile 不存在。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "item-missing");
        defer std.testing.allocator.free(path);
        try expectNoBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try item_mutation.profile(io, allocator, config, catalog_path, "missing", .{ .operation = .add, .key = "system.users", .identity = "ops", .name = "ops", .password = "asdf1234" });
            }
        }.run, error.ProfileNotFound);
    }

    // item-scoped user values：ops.groups add wheel。
    {
        const path = try freshCaseWithUser(std.testing.io, std.testing.allocator, base, "user-values");
        defer std.testing.allocator.free(path);
        try expectBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try item_mutation.profileUserValues(io, allocator, config, catalog_path, "install", "ops", "groups", .add, &.{"wheel"});
            }
        }.run);
    }

    // item-scoped user values 失败：profile 不存在。
    {
        const path = try freshCaseWithUser(std.testing.io, std.testing.allocator, base, "user-values-missing");
        defer std.testing.allocator.free(path);
        try expectNoBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try item_mutation.profileUserValues(io, allocator, config, catalog_path, "missing", "ops", "groups", .add, &.{"wheel"});
            }
        }.run, error.ProfileNotFound);
    }

    // replaceProfile：system.users 整体替换。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "replace");
        defer std.testing.allocator.free(path);
        try expectBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try item_mutation.replaceProfile(io, allocator, config, catalog_path, "install", .{ .operation = .replace, .key = "system.users", .users = &.{.{ .name = "ops", .password = "asdf1234" }} });
            }
        }.run);
    }

    // replaceProfile 失败：profile 不存在。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "replace-missing");
        defer std.testing.allocator.free(path);
        try expectNoBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try item_mutation.replaceProfile(io, allocator, config, catalog_path, "missing", .{ .operation = .replace, .key = "system.users", .users = &.{.{ .name = "ops", .password = "asdf1234" }} });
            }
        }.run, error.ProfileNotFound);
    }

    // setKernelArgs：合法参数。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "kernel-args");
        defer std.testing.allocator.free(path);
        try expectBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try profile_mutation.setKernelArgs(io, allocator, config, catalog_path, "install", "iommu=pt");
            }
        }.run);
    }

    // setKernelArgs 失败：profile 不存在。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "kernel-args-missing");
        defer std.testing.allocator.free(path);
        try expectNoBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try profile_mutation.setKernelArgs(io, allocator, config, catalog_path, "missing", "iommu=pt");
            }
        }.run, error.ProfileNotFound);
    }

    // setKernelArgs 失败：非法参数在 helper 前被 validate 拒绝。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "kernel-args-invalid");
        defer std.testing.allocator.free(path);
        try expectNoBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try profile_mutation.setKernelArgs(io, allocator, config, catalog_path, "install", "iommu=pt;reboot");
            }
        }.run, error.InvalidKernelArgs);
    }

    // rotateSshIdentity：发布新 identity 引用。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "rotate");
        defer std.testing.allocator.free(path);
        try expectBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try profile_mutation.rotateSshIdentity(io, allocator, config, catalog_path, "install", .{ .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .revision = 7, .client_public_fingerprint = "SHA256:aaaa", .host_public_fingerprint = "SHA256:bbbb" });
            }
        }.run);
    }

    // rotateSshIdentity 失败：profile 不存在。
    {
        const path = try freshCase(std.testing.io, std.testing.allocator, base, "rotate-missing");
        defer std.testing.allocator.free(path);
        try expectNoBump(std.testing.io, std.testing.allocator, &cfg, path, struct {
            fn run(io: std.Io, allocator: std.mem.Allocator, config: *const model.AppConfig, catalog_path: []const u8) anyerror!void {
                try profile_mutation.rotateSshIdentity(io, allocator, config, catalog_path, "missing", .{ .id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .revision = 7, .client_public_fingerprint = "SHA256:aaaa", .host_public_fingerprint = "SHA256:bbbb" });
            }
        }.run, error.ProfileNotFound);
    }
}

test "v0.2.3 §5.4: clone starts target at revision 1 without touching source revision" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try temp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const cfg = scan_config;
    const path = try freshCase(std.testing.io, std.testing.allocator, base, "clone");
    defer std.testing.allocator.free(path);

    const source_before = try revisionOf(std.testing.io, std.testing.allocator, path, "install");
    try profile_mutation.cloneProfile(std.testing.io, std.testing.allocator, &cfg, path, "install", "clone-target", null, &.{});
    // source 不递增（clone 不是对 source 的 mutation）。
    try std.testing.expectEqual(source_before, try revisionOf(std.testing.io, std.testing.allocator, path, "install"));
    // target 初始 revision 固定为 1。
    try std.testing.expectEqual(@as(u64, 1), try revisionOf(std.testing.io, std.testing.allocator, path, "clone-target"));

    // §5.2: property patch 与 clone 同一事务提交；target revision 仍为 1，
    // patch 已应用。
    try profile_mutation.cloneProfile(std.testing.io, std.testing.allocator, &cfg, path, "install", "patch-target", null, &.{.{ .key = "system.ssh.enabled", .value = "true" }});
    try std.testing.expectEqual(@as(u64, 1), try revisionOf(std.testing.io, std.testing.allocator, path, "patch-target"));
    {
        var parsed = try catalog_store.load(std.testing.io, std.testing.allocator, path);
        defer parsed.deinit();
        var found = false;
        for (parsed.value.profiles) |profile| if (std.mem.eql(u8, profile.name, "patch-target")) {
            try std.testing.expectEqual(true, profile.system.ssh.enabled);
            found = true;
        };
        try std.testing.expect(found);
    }

    // §5.2: 非法 patch 值使整个 clone 事务回滚（target 未创建、source 不变）。
    try std.testing.expectError(error.InvalidPropertyValue, profile_mutation.cloneProfile(std.testing.io, std.testing.allocator, &cfg, path, "install", "bad-target", null, &.{.{ .key = "system.ssh.enabled", .value = "not-a-bool" }}));
    try std.testing.expectEqual(@as(u64, 1), try revisionOf(std.testing.io, std.testing.allocator, path, "install"));
    try std.testing.expectError(error.ProfileNotFound, revisionOf(std.testing.io, std.testing.allocator, path, "bad-target"));

    // 失败：source 不存在。
    try std.testing.expectError(error.ProfileNotFound, profile_mutation.cloneProfile(std.testing.io, std.testing.allocator, &cfg, path, "missing", "another-target", null, &.{}));
    // 失败：target 已存在（不改动任何 revision）。
    try std.testing.expectError(error.ProfileAlreadyExists, profile_mutation.cloneProfile(std.testing.io, std.testing.allocator, &cfg, path, "install", "clone-target", null, &.{}));
    try std.testing.expectEqual(source_before, try revisionOf(std.testing.io, std.testing.allocator, path, "install"));
    try std.testing.expectEqual(@as(u64, 1), try revisionOf(std.testing.io, std.testing.allocator, path, "clone-target"));
}
