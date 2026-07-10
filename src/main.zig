//! `nodeforge` M0 管理命令行入口。
//! 使用 zig-clap 解析全局参数；业务语义统一委托核心库处理。
//! M0 只保留高频入口：`status` 查看详情，`check` 给自动化健康检查用；
//! 不再保留 `server status/check` 这类重复层级，避免命令面膨胀。

const std = @import("std");
const clap = @import("clap");
const nodeforge = @import("nodeforge");

const CliOptions = struct {
    /// 启动配置事实源。正常安装自动使用默认路径，测试和开发可覆盖。
    config_path: []const u8 = nodeforge.config.default_path,
    /// nodeforged 管理的 catalog 事实源。CLI M0 只读取/校验，不直接维护运行中 catalog。
    catalog_path: []const u8 = nodeforge.catalog_store.default_path,
    /// 机器消费输出必须显式开启，避免默认输出牺牲人工可读性。
    output_json: bool = false,
    /// zig-clap 已剥离全局参数后的命令路径。
    positionals: []const []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file.interface;

    const exit_code = run(init.io, allocator, init.minimal.args, out) catch |err| code: {
        out.print("ERROR internal failure: {t}\n", .{err}) catch {};
        break :code @as(u8, 1);
    };
    out.flush() catch {};
    if (exit_code != 0) std.process.exit(exit_code);
}

fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    args_iter: anytype,
    out: *std.Io.Writer,
) !u8 {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Show help and exit.
        \\-v, --version       Show version and exit.
        \\--config <str>      Override config JSON path.
        \\--catalog <str>     Override catalog JSON path.
        \\--output <str>      Output format: json.
        \\<str>...
        \\
    );
    var diag = clap.Diagnostic{};
    var parsed = clap.parse(clap.Help, &params, clap.parsers.default, args_iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return 2;
    };
    defer parsed.deinit();

    if (parsed.args.version != 0) {
        try printVersion(out);
        return 0;
    }
    if (parsed.args.help != 0 and parsed.positionals[0].len != 0) {
        const options: CliOptions = .{
            .config_path = parsed.args.config orelse nodeforge.config.default_path,
            .catalog_path = parsed.args.catalog orelse nodeforge.catalog_store.default_path,
            .output_json = false,
            .positionals = parsed.positionals[0],
        };
        return dispatchHelp(options, out);
    }
    if (parsed.args.help != 0 or parsed.positionals[0].len == 0) {
        try printHelp(out);
        return 0;
    }
    const output_json = if (parsed.args.output) |value| blk: {
        if (!std.mem.eql(u8, value, "json")) {
            try out.print("ERROR unsupported output format: {s}\n", .{value});
            return 2;
        }
        break :blk true;
    } else false;

    const options: CliOptions = .{
        .config_path = parsed.args.config orelse nodeforge.config.default_path,
        .catalog_path = parsed.args.catalog orelse nodeforge.catalog_store.default_path,
        .output_json = output_json,
        .positionals = parsed.positionals[0],
    };
    return dispatch(io, allocator, options, out);
}

fn dispatchHelp(options: CliOptions, out: *std.Io.Writer) !u8 {
    const command = options.positionals[0];
    if (std.mem.eql(u8, command, "status") or
        std.mem.eql(u8, command, "check"))
        return statusHelp(out);
    if (std.mem.eql(u8, command, "config"))
        return configHelp(out);
    if (std.mem.eql(u8, command, "catalog"))
        return catalogHelp(out);
    try printHelp(out);
    return 0;
}

/// 分发 M0 已实现命令。
/// 这里故意不做通用 command table：M0 命令很少，显式分支更容易发现重复入口。
fn dispatch(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: CliOptions,
    out: *std.Io.Writer,
) !u8 {
    const command = options.positionals[0];
    if (isHelp(command)) {
        try printHelp(out);
        return 0;
    }
    if (isVersion(command)) {
        try printVersion(out);
        return 0;
    }
    if (std.mem.eql(u8, command, "status"))
        return statusCommand(io, allocator, options, "status", out);
    if (std.mem.eql(u8, command, "check"))
        return statusCommand(io, allocator, options, "check", out);
    if (std.mem.eql(u8, command, "config"))
        return configCommand(io, allocator, options, options.positionals[1..], out);
    if (std.mem.eql(u8, command, "catalog"))
        return catalogCommand(io, allocator, options, options.positionals[1..], out);

    try out.print("ERROR unknown command: {s}\n\n", .{command});
    try printHelp(out);
    return 2;
}

fn configCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: CliOptions,
    args: []const []const u8,
    out: *std.Io.Writer,
) !u8 {
    if (args.len == 0 or isHelp(args[0])) return configHelp(out);
    if (containsHelp(args[1..])) return configHelp(out);
    const action = args[0];
    if (std.mem.eql(u8, action, "validate")) {
        var parsed_config = loadConfig(io, allocator, options.config_path, out) orelse return 1;
        defer parsed_config.deinit();
        var parsed_catalog = loadCatalogOrEmpty(io, allocator, options.catalog_path, out) orelse return 1;
        defer parsed_catalog.deinit();
        nodeforge.config_validate.validate(&parsed_config.value, parsed_catalog.value()) catch |err| {
            try out.print("ERROR config invalid: {t}\n", .{err});
            return 1;
        };
        if (options.output_json)
            try out.print("{{\"ok\":true,\"config\":\"{s}\",\"catalog\":\"{s}\"}}\n", .{ options.config_path, options.catalog_path })
        else
            try out.print("OK config valid  {s}  catalog {s}\n", .{ options.config_path, options.catalog_path });
        return 0;
    }
    if (std.mem.eql(u8, action, "export")) {
        var parsed_config = loadConfig(io, allocator, options.config_path, out) orelse return 1;
        defer parsed_config.deinit();
        const bytes = try nodeforge.config_store.render(allocator, &parsed_config.value);
        defer allocator.free(bytes);
        try out.writeAll(bytes);
        return 0;
    }
    if (std.mem.eql(u8, action, "import")) {
        if (args.len < 2) return commandError(out, "config import requires a source path");
        var parsed_config = loadConfig(io, allocator, args[1], out) orelse return 1;
        defer parsed_config.deinit();
        try nodeforge.config_validate.validateConfig(&parsed_config.value);
        try nodeforge.config_store.save(io, allocator, options.config_path, &parsed_config.value);
        if (options.output_json)
            try out.print("{{\"ok\":true,\"source\":\"{s}\",\"destination\":\"{s}\"}}\n", .{ args[1], options.config_path })
        else
            try out.print("OK config imported  {s} -> {s}\n", .{ args[1], options.config_path });
        return 0;
    }
    return commandError(out, "unknown config action");
}

fn catalogCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: CliOptions,
    args: []const []const u8,
    out: *std.Io.Writer,
) !u8 {
    if (args.len == 0 or isHelp(args[0])) return catalogHelp(out);
    if (containsHelp(args[1..])) return catalogHelp(out);
    const action = args[0];
    if (std.mem.eql(u8, action, "validate")) {
        var parsed_config = loadConfig(io, allocator, options.config_path, out) orelse return 1;
        defer parsed_config.deinit();
        var parsed_catalog = loadCatalogOrEmpty(io, allocator, options.catalog_path, out) orelse return 1;
        defer parsed_catalog.deinit();
        nodeforge.config_validate.validateCatalog(&parsed_config.value, parsed_catalog.value()) catch |err| {
            try out.print("ERROR catalog invalid: {t}\n", .{err});
            return 1;
        };
        if (options.output_json)
            try out.print("{{\"ok\":true,\"catalog\":\"{s}\"}}\n", .{options.catalog_path})
        else
            try out.print("OK catalog valid  {s}\n", .{options.catalog_path});
        return 0;
    }
    if (std.mem.eql(u8, action, "export")) {
        var parsed_catalog = loadCatalogOrEmpty(io, allocator, options.catalog_path, out) orelse return 1;
        defer parsed_catalog.deinit();
        const bytes = try nodeforge.catalog_store.render(allocator, parsed_catalog.value());
        defer allocator.free(bytes);
        try out.writeAll(bytes);
        return 0;
    }
    return commandError(out, "unknown catalog action");
}

/// 执行 `status` 或 `check`。
///
/// 二者检查同一组 M0 探针，但输出目的不同：
/// - `status` 面向人，保留每项详细状态；
/// - `check` 面向脚本，成功时只输出一行，并通过退出码表达结果。
fn statusCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: CliOptions,
    action: []const u8,
    out: *std.Io.Writer,
) !u8 {
    if (!std.mem.eql(u8, action, "status") and !std.mem.eql(u8, action, "check"))
        return commandError(out, "unknown status action");

    var parsed_config = loadConfig(io, allocator, options.config_path, out) orelse return 1;
    defer parsed_config.deinit();
    const status = nodeforge.management_client.managementStatus(
        io,
        parsed_config.value.server.http_port,
    );
    const active_config = nodeforge.management_client.validateActiveConfig(
        io,
        parsed_config.value.server.http_port,
    );
    const health = nodeforge.management_client.healthAt(
        io,
        parsed_config.value.server.server_ip,
        parsed_config.value.server.http_port,
    );
    const ok = status.healthy and active_config.healthy and health.healthy;
    if (options.output_json) {
        try out.print(
            "{{\"process\":{s},\"http\":{s},\"management\":{s},\"config\":{s}}}\n",
            .{ jsonBool(status.reachable), jsonBool(health.healthy), jsonBool(status.healthy), jsonBool(active_config.healthy) },
        );
        return if (ok) 0 else 1;
    }
    if (std.mem.eql(u8, action, "check")) {
        if (ok) {
            try out.print("OK nodeforge checks passed\n", .{});
        } else {
            try out.print("FAIL nodeforge checks failed\n", .{});
            try printCheckLine(out, "Process", status.reachable);
            try printCheckLine(out, "HTTP", health.healthy);
            try printCheckLine(out, "Management", status.healthy);
            try printCheckLine(out, "Config API", active_config.healthy);
        }
        return if (ok) 0 else 1;
    }

    try out.print("NodeForge status\n", .{});
    try out.print("  Process     {s}\n", .{if (status.reachable) "OK reachable" else "FAIL unreachable"});
    try out.print("  HTTP        {s} http://{s}:{d}\n", .{
        if (health.healthy) "OK healthy" else "FAIL unhealthy",
        parsed_config.value.server.server_ip,
        parsed_config.value.server.http_port,
    });
    try out.print("  Management  {s} http://127.0.0.1:{d}\n", .{
        if (status.healthy) "OK route" else "FAIL route",
        parsed_config.value.server.http_port,
    });
    try out.print("  Config API  {s}\n", .{if (active_config.healthy) "OK config valid" else "FAIL config unavailable"});
    return if (ok) 0 else 1;
}

const CatalogLoad = struct {
    parsed: ?std.json.Parsed(nodeforge.model.Catalog),
    empty: nodeforge.model.Catalog,

    fn value(self: *const CatalogLoad) *const nodeforge.model.Catalog {
        if (self.parsed) |*parsed| return &parsed.value;
        return &self.empty;
    }

    fn deinit(self: *CatalogLoad) void {
        if (self.parsed) |*parsed| parsed.deinit();
    }
};

/// 读取 catalog；文件不存在时返回空 catalog。
/// M0 允许先只验证启动配置和服务骨架，catalog 可由后续导入/构建流程逐步生成。
fn loadCatalogOrEmpty(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    out: *std.Io.Writer,
) ?CatalogLoad {
    const parsed = nodeforge.catalog_store.load(io, allocator, path) catch |err| switch (err) {
        error.FileNotFound => return .{ .parsed = null, .empty = nodeforge.catalog_store.empty() },
        else => {
            out.print("ERROR catalog load failed: {t}  {s}\n", .{ err, path }) catch {};
            return null;
        },
    };
    return .{ .parsed = parsed, .empty = nodeforge.catalog_store.empty() };
}

fn loadConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    out: *std.Io.Writer,
) ?std.json.Parsed(nodeforge.model.AppConfig) {
    var parsed = nodeforge.config.load(io, allocator, path) catch |err| {
        out.print("ERROR config load failed: {t}  {s}\n", .{ err, path }) catch {};
        return null;
    };
    nodeforge.config_validate.validateConfig(&parsed.value) catch |err| {
        out.print("ERROR config invalid: {t}  {s}\n", .{ err, path }) catch {};
        parsed.deinit();
        return null;
    };
    return parsed;
}

fn commandError(out: *std.Io.Writer, message: []const u8) !u8 {
    try out.print("ERROR {s}\n", .{message});
    return 2;
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or
        std.mem.eql(u8, arg, "-h");
}

fn isVersion(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version") or
        std.mem.eql(u8, arg, "-v");
}

fn containsHelp(args: []const []const u8) bool {
    for (args) |arg| if (isHelp(arg)) return true;
    return false;
}

fn jsonBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn printCheckLine(out: *std.Io.Writer, label: []const u8, passed: bool) !void {
    try out.print("  {s:<12} {s}\n", .{ label, if (passed) "OK" else "FAIL" });
}

fn printVersion(out: *std.Io.Writer) !void {
    try out.print("nodeforge {s}\n", .{nodeforge.version.version});
}

fn printHelp(out: *std.Io.Writer) !void {
    try out.print(
        \\NodeForge administration CLI
        \\
        \\Usage:
        \\  nodeforge [options] <command>
        \\  nodeforge -h|--help
        \\  nodeforge -v|--version
        \\
        \\Options:
        \\  -h, --help              Show help and exit
        \\  -v, --version           Show version and exit
        \\  --config <path>         Override config JSON path [default: {s}]
        \\  --catalog <path>        Override catalog JSON path [default: {s}]
        \\  --output json           Machine-readable JSON output
        \\
        \\Commands:
        \\  status                         Show daemon status
        \\  check                          Run health checks and set exit code
        \\  config validate|export|import  Validate or manage startup config
        \\  catalog validate|export        Validate or inspect nodeforged catalog
        \\  version                        Show version
        \\  help                           Show this help
        \\
        \\Examples:
        \\  nodeforge status
        \\  nodeforge --output json status
        \\  nodeforge config validate
        \\  nodeforge --config ./config.example.json catalog validate
        \\
    , .{ nodeforge.config.default_path, nodeforge.catalog_store.default_path });
}

fn configHelp(out: *std.Io.Writer) !u8 {
    try out.writeAll(
        \\NodeForge config commands
        \\
        \\Usage:
        \\  nodeforge config validate
        \\  nodeforge config export
        \\  nodeforge config import <source>
        \\  nodeforge config -h|--help
        \\
        \\Options:
        \\  --config <path>    Config JSON path
        \\  --catalog <path>   Catalog JSON path used for relationship validation
        \\  --output json      Machine-readable output for validate/import
        \\
        \\Examples:
        \\  nodeforge config validate
        \\  nodeforge --config ./config.example.json config export
        \\
    );
    return 0;
}

fn catalogHelp(out: *std.Io.Writer) !u8 {
    try out.writeAll(
        \\NodeForge catalog commands
        \\
        \\Usage:
        \\  nodeforge catalog validate
        \\  nodeforge catalog export
        \\  nodeforge catalog -h|--help
        \\
        \\Options:
        \\  --config <path>    Config JSON path used for relationship validation
        \\  --catalog <path>   Catalog JSON path
        \\  --output json      Machine-readable output for validate
        \\
        \\Examples:
        \\  nodeforge catalog validate
        \\  nodeforge --catalog ./catalog.example.json catalog export
        \\
    );
    return 0;
}

fn statusHelp(out: *std.Io.Writer) !u8 {
    try out.writeAll(
        \\NodeForge status/check commands
        \\
        \\Usage:
        \\  nodeforge status
        \\  nodeforge check
        \\  nodeforge status -h|--help
        \\  nodeforge check -h|--help
        \\
        \\Options:
        \\  --config <path>    Config JSON path; HTTP port and advertised server IP are read from it
        \\  --output json      Machine-readable result
        \\
        \\Examples:
        \\  nodeforge status
        \\  nodeforge check
        \\  nodeforge --output json check
        \\
    );
    return 0;
}
