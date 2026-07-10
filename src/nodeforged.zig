//! `nodeforged` 单进程守护程序入口。
//! 启动顺序固定为“加载 -> 校验 -> 自检/监听”，未经校验的配置不得进入服务层。
//! M0 只启动唯一 HTTP listener；DHCP/TFTP 等后续协议不能绕过这里的配置加载和校验。

const std = @import("std");
const nodeforge = @import("nodeforge");

/// 将预期启动错误转换为简洁日志和退出码，避免向运维输出 Zig 调用栈。
pub fn main(init: std.process.Init) void {
    run(init) catch std.process.exit(1);
}

/// 加载唯一配置文件并启动 HTTP 服务。
///
/// 正常安装会自动读取 `/opt/nodeforge` 下的默认 config/catalog；`--config`
/// 和 `--catalog` 只作为开发、测试、迁移或临时排障时的覆盖入口。
///
/// `--check-config` 只做纯配置/catalog 校验；`--check` 额外探测 M0 HTTP 端口，
/// 但不长期持有 socket。真正启动仍必须处理 bind 失败，因为自检与启动之间存在竞态。
fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (hasAnyFlag(args[1..], &.{ "-h", "--help", "help" })) {
        try printHelp(init.io);
        return;
    }
    if (hasAnyFlag(args[1..], &.{ "-v", "--version", "version" })) {
        try printVersion(init.io);
        return;
    }
    const config_path = optionValue(args[1..], "--config") orelse nodeforge.config.default_path;
    const catalog_path = optionValue(args[1..], "--catalog") orelse nodeforge.catalog_store.default_path;

    // 启动配置必须存在；它定义 HTTP 端口、对外服务地址和默认策略。
    var parsed = nodeforge.config.load(init.io, allocator, config_path) catch |err| {
        std.log.err("failed to load config '{s}': {t}", .{ config_path, err });
        return err;
    };
    defer parsed.deinit();
    // catalog 是 nodeforged 管理的运行期对象目录。新安装环境可能还没有导入
    // 任何资产，因此允许文件暂时不存在，并用空 catalog 参与关系校验。
    var parsed_catalog = nodeforge.catalog_store.load(init.io, allocator, catalog_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            std.log.err("failed to load catalog '{s}': {t}", .{ catalog_path, err });
            return err;
        },
    };
    defer if (parsed_catalog) |*catalog| catalog.deinit();
    const empty_catalog = nodeforge.catalog_store.empty();
    const catalog = if (parsed_catalog) |*loaded| &loaded.value else &empty_catalog;

    nodeforge.config_validate.validate(&parsed.value, catalog) catch |err| {
        std.log.err("invalid config '{s}': {t}", .{ config_path, err });
        return err;
    };

    if (hasFlag(args[1..], "--check-config")) {
        std.log.info("configuration is valid: {s}; catalog: {s}", .{ config_path, catalog_path });
        return;
    }
    if (hasFlag(args[1..], "--check")) {
        // `nodeforged --check` 只做守护进程启动前能本地完成的检查：
        // config/catalog 校验和 HTTP 端口预占用探测。管理路由可达性由
        // 运行中的 `nodeforge check` 通过 loopback HTTP 请求验证。
        nodeforge.preflight.checkHttpPorts(init.io, &parsed.value) catch |err| {
            std.log.err("preflight failed: {t}", .{err});
            return err;
        };
        std.log.info("preflight passed: config and M0 HTTP ports are available", .{});
        return;
    }

    try nodeforge.app.run(init.io, allocator, &parsed.value, catalog);
}

fn optionValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) return args[i + 1];
    }
    return null;
}

/// M0 只需要极少启动参数，因此守护进程暂不引入完整 CLI parser。
/// 复杂的人机命令由 `nodeforge` CLI 使用 zig-clap 处理。
fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

fn hasAnyFlag(args: []const []const u8, names: []const []const u8) bool {
    for (names) |name| if (hasFlag(args, name)) return true;
    return false;
}

fn printVersion(io: std.Io) !void {
    var buffer: [256]u8 = undefined;
    var file = std.Io.File.Writer.init(.stdout(), io, &buffer);
    try file.interface.print("nodeforged {s}\n", .{nodeforge.version.version});
    try file.interface.flush();
}

fn printHelp(io: std.Io) !void {
    var buffer: [2048]u8 = undefined;
    var file = std.Io.File.Writer.init(.stdout(), io, &buffer);
    try file.interface.print(
        \\NodeForge daemon
        \\
        \\Usage:
        \\  nodeforged [options]
        \\  nodeforged -h|--help
        \\  nodeforged -v|--version
        \\
        \\Options:
        \\  -h, --help              Show help and exit
        \\  -v, --version           Show version and exit
        \\  --config <path>         Override config JSON path [default: {s}]
        \\  --catalog <path>        Override catalog JSON path [default: {s}]
        \\  --check-config          Validate config/catalog and exit
        \\  --check                 Validate config/catalog, probe M0 HTTP port, and exit
        \\
        \\Defaults:
        \\  Normal deployments auto-load config/catalog from {s}.
        \\
        \\Logging:
        \\  Default builds log lifecycle, preflight, and HTTP request summaries through stderr/systemd journal.
        \\  Debug builds additionally include debug-level connection and protocol details.
        \\
    , .{ nodeforge.config.default_path, nodeforge.catalog_store.default_path, nodeforge.paths.install_root });
    try file.interface.flush();
}
