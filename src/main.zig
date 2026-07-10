//! `nodeforge` M0 管理命令行入口。
//! zli 持有唯一命令树并据此完成解析、校验和帮助生成；业务语义仍委托核心库。
//! 退出码约定：0 表示成功，1 表示业务检查或运行失败，2 表示命令行用法错误。

const std = @import("std");
const zli = @import("zli");
const nodeforge = @import("nodeforge");

/// zli handler 共享的可变执行结果。
/// handler 本身返回错误只用于传播内部故障；可预期的业务失败通过此状态返回退出码。
const CliState = struct {
    /// 最终进程退出码，默认成功。
    exit_code: u8 = 0,
};

/// zli 用于 `--version` 元数据的编译期语义版本。
const semantic_version = std.SemanticVersion.parse(nodeforge.version.version) catch unreachable;

/// 初始化标准 IO，执行 CLI，并将命令结果转换为进程退出状态。
pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file.interface;
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file = std.Io.File.Reader.init(.stdin(), init.io, &stdin_buffer);

    const exit_code = try run(init, out, &stdin_file.interface);
    out.flush() catch {};
    if (exit_code != 0) std.process.exit(exit_code);
}

/// 构建命令树并执行一次参数解析。
/// zli 的语法错误统一映射为退出码 2，未分类内部错误映射为退出码 1。
fn run(init: std.process.Init, out: *std.Io.Writer, in: *std.Io.Reader) !u8 {
    const root = try buildCli(.{
        .allocator = init.arena.allocator(),
        .io = init.io,
        .writer = out,
        .reader = in,
    });
    defer root.deinit();

    var state: CliState = .{};
    var args_iter = init.minimal.args.iterate();
    root.execute(&args_iter, .{ .data = &state }) catch |err| {
        if (isUsageError(err)) return 2;
        try out.print("error: internal: {t}\n", .{err});
        return 1;
    };
    return state.exit_code;
}

/// 声明完整 `nodeforge` 命令树。
/// `-v/--version` 仅属于根命令；业务参数只声明在实际读取它们的叶子命令上，避免无效 flags。
fn buildCli(init_options: zli.InitOptions) !*zli.Command {
    const root = try zli.Command.init(init_options, .{
        .name = "nodeforge",
        .description = "NodeForge administration CLI",
        .version = semantic_version,
        .usage = "nodeforge [-v|--version] <command> [options]",
        .help = "Manage and inspect the local NodeForge daemon, startup configuration, and catalog.",
    }, showRootHelp);

    try root.addFlags(&.{
        .{
            .name = "version",
            .shortcut = "v",
            .description = "Show version and exit",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
    });

    const status = try zli.Command.init(init_options, .{
        .name = "status",
        .description = "Show daemon status",
        .help = "Show detailed checks for the local daemon and configured HTTP service address.",
    }, statusHandler);
    try addConfigPathFlag(status);
    try addOutputFlag(status);
    try addDebugFlag(status);
    const check = try zli.Command.init(init_options, .{
        .name = "check",
        .description = "Run health checks and set the exit code",
        .help = "Print a concise health result and return a machine-readable exit code.",
    }, checkHandler);
    try addConfigPathFlag(check);
    try addOutputFlag(check);
    try addDebugFlag(check);

    const config = try zli.Command.init(init_options, .{
        .name = "config",
        .description = "Validate or manage startup configuration",
        .usage = "nodeforge config <command> [options]",
        .help = "Manage startup configuration files. Changes are offline operations; restart nodeforged to load them.",
    }, showCurrentHelp);
    const config_validate = try zli.Command.init(init_options, .{
        .name = "validate",
        .description = "Validate startup config and catalog relationships",
        .help = "Validate one config file together with one catalog file without modifying either file.",
    }, configValidateHandler);
    try addConfigPathFlag(config_validate);
    try addCatalogPathFlag(config_validate);
    try addOutputFlag(config_validate);
    try addDebugFlag(config_validate);
    const config_export = try zli.Command.init(init_options, .{
        .name = "export",
        .description = "Write the normalized startup config JSON to stdout",
        .help = "Always writes normalized JSON to stdout; redirect it to create a file.",
    }, configExportHandler);
    try addConfigPathFlag(config_export);
    try addDebugFlag(config_export);
    try config.addCommands(&.{
        config_validate,
        config_export,
        try configImportCommand(init_options),
    });

    const catalog = try zli.Command.init(init_options, .{
        .name = "catalog",
        .description = "Validate or inspect the nodeforged catalog",
        .usage = "nodeforge catalog <command> [options]",
        .help = "Inspect and validate local catalog files. M0 does not modify catalog contents.",
    }, showCurrentHelp);
    const catalog_validate = try zli.Command.init(init_options, .{
        .name = "validate",
        .description = "Validate catalog objects and config relationships",
        .help = "Validate one catalog file against one startup configuration without modifying either file.",
    }, catalogValidateHandler);
    try addConfigPathFlag(catalog_validate);
    try addCatalogPathFlag(catalog_validate);
    try addOutputFlag(catalog_validate);
    try addDebugFlag(catalog_validate);
    const catalog_export = try zli.Command.init(init_options, .{
        .name = "export",
        .description = "Write the normalized catalog JSON to stdout",
        .help = "Always writes normalized JSON to stdout; a missing catalog is exported as an empty catalog.",
    }, catalogExportHandler);
    try addCatalogPathFlag(catalog_export);
    try addDebugFlag(catalog_export);
    try catalog.addCommands(&.{
        catalog_validate,
        catalog_export,
    });

    try root.addCommands(&.{
        status,
        check,
        config,
        catalog,
    });
    return root;
}

/// 构建带必填 `source` 位置参数的 `config import` 命令。
fn configImportCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{
        .name = "import",
        .description = "Validate and install a startup config",
        .help = "Validate and atomically replace a config file; restart nodeforged to load the change.",
    }, configImportHandler);
    try addConfigPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
    try command.addPositionalArg(.{
        .name = "source",
        .description = "Source config JSON path",
        .required = true,
    });
    return command;
}

/// 根命令 handler：处理顶层 `--version`，否则显示根命令帮助。
fn showRootHelp(ctx: zli.CommandContext) !void {
    if (try showVersionIfRequested(ctx)) return;
    try ctx.command.printHelp();
}

/// 资源级命令默认 handler：显示当前层帮助。
fn showCurrentHelp(ctx: zli.CommandContext) !void {
    try ctx.command.printHelp();
}

/// 执行详细状态查询，并把探测结果保存为进程退出码。
fn statusHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    setExitCode(ctx, try statusCommand(ctx.io, ctx.allocator, ctx.flag("config", []const u8), output_json, debug, "status", ctx.writer));
}

/// 执行简洁健康检查，并把结果保存为适合自动化判断的退出码。
fn checkHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    setExitCode(ctx, try statusCommand(ctx.io, ctx.allocator, ctx.flag("config", []const u8), output_json, debug, "check", ctx.writer));
}

/// 加载并联合校验启动配置与 catalog，不修改任何文件。
fn configValidateHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    const config_path = ctx.flag("config", []const u8);
    const catalog_path = ctx.flag("catalog", []const u8);
    var parsed_config = loadConfig(ctx.io, ctx.allocator, config_path, ctx.writer, debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    var parsed_catalog = loadCatalogOrEmpty(ctx.io, ctx.allocator, catalog_path, ctx.writer, debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_catalog.deinit();
    nodeforge.config_validate.validate(&parsed_config.value, parsed_catalog.value()) catch |err| {
        try printValidationError(ctx.writer, "config", config_path, err, debug);
        setExitCode(ctx, 1);
        return;
    };
    if (output_json)
        try ctx.writer.print("{{\"ok\":true,\"config\":\"{s}\",\"catalog\":\"{s}\"}}\n", .{ config_path, catalog_path })
    else
        try ctx.writer.print("OK config valid  {s}  catalog {s}\n", .{ config_path, catalog_path });
}

/// 加载启动配置并将规范化 JSON 写到 stdout。
fn configExportHandler(ctx: zli.CommandContext) !void {
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    const bytes = try nodeforge.config_store.render(ctx.allocator, &parsed_config.value);
    defer ctx.allocator.free(bytes);
    try ctx.writer.writeAll(bytes);
}

/// 校验源配置后原子写入 `--config` 指定的目标路径。
fn configImportHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    const config_path = ctx.flag("config", []const u8);
    const source = ctx.getArg("source") orelse unreachable;
    var parsed_config = loadConfig(ctx.io, ctx.allocator, source, ctx.writer, debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    nodeforge.config_validate.validateConfig(&parsed_config.value) catch |err| {
        try printValidationError(ctx.writer, "config", source, err, debug);
        setExitCode(ctx, 1);
        return;
    };
    try nodeforge.config_store.save(ctx.io, ctx.allocator, config_path, &parsed_config.value);
    if (output_json)
        try ctx.writer.print("{{\"ok\":true,\"source\":\"{s}\",\"destination\":\"{s}\"}}\n", .{ source, config_path })
    else
        try ctx.writer.print("OK config imported  {s} -> {s}\n", .{ source, config_path });
}

/// 加载配置和 catalog 并校验 catalog 对象及跨文件关系。
fn catalogValidateHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    const config_path = ctx.flag("config", []const u8);
    const catalog_path = ctx.flag("catalog", []const u8);
    var parsed_config = loadConfig(ctx.io, ctx.allocator, config_path, ctx.writer, debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    var parsed_catalog = loadCatalogOrEmpty(ctx.io, ctx.allocator, catalog_path, ctx.writer, debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_catalog.deinit();
    nodeforge.config_validate.validateCatalog(&parsed_config.value, parsed_catalog.value()) catch |err| {
        try printValidationError(ctx.writer, "catalog", catalog_path, err, debug);
        setExitCode(ctx, 1);
        return;
    };
    if (output_json)
        try ctx.writer.print("{{\"ok\":true,\"catalog\":\"{s}\"}}\n", .{catalog_path})
    else
        try ctx.writer.print("OK catalog valid  {s}\n", .{catalog_path});
}

/// 加载 catalog 并将规范化 JSON 写到 stdout；文件缺失时导出空 catalog。
fn catalogExportHandler(ctx: zli.CommandContext) !void {
    var parsed_catalog = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_catalog.deinit();
    const bytes = try nodeforge.catalog_store.render(ctx.allocator, parsed_catalog.value());
    defer ctx.allocator.free(bytes);
    try ctx.writer.writeAll(bytes);
}

/// 读取当前命令的输出格式并校验其值。
/// 返回 null 表示已输出可读错误并把退出码设为用法错误 2。
fn outputJsonFromContext(ctx: zli.CommandContext) ?bool {
    const output = ctx.flag("output", []const u8);
    const output_json = if (std.mem.eql(u8, output, "json")) true else if (std.mem.eql(u8, output, "human")) false else {
        ctx.writer.print("error: output: unsupported format '{s}' (expected human or json)\n", .{output}) catch {};
        setExitCode(ctx, 2);
        return null;
    };
    return output_json;
}

/// 实现仅属于根命令的 `--version` 提前返回语义。
fn showVersionIfRequested(ctx: zli.CommandContext) !bool {
    if (!ctx.flag("version", bool)) return false;
    try printVersion(ctx.writer);
    return true;
}

/// 更新本次 zli 执行共享的最终退出码。
fn setExitCode(ctx: zli.CommandContext, code: u8) void {
    ctx.getContextData(CliState).exit_code = code;
}

/// 为一个命令声明默认 config 路径覆盖参数。
fn addConfigPathFlag(command: *zli.Command) !void {
    try command.addFlag(.{
        .name = "config",
        .shortcut = "c",
        .description = "Config JSON path",
        .type = .String,
        .default_value = .{ .String = nodeforge.config.default_path },
    });
}

/// 为一个命令声明默认 catalog 路径覆盖参数。
fn addCatalogPathFlag(command: *zli.Command) !void {
    try command.addFlag(.{
        .name = "catalog",
        .shortcut = "C",
        .description = "Catalog JSON path",
        .type = .String,
        .default_value = .{ .String = nodeforge.catalog_store.default_path },
    });
}

/// 为支持 human 或 JSON 结果的命令声明输出格式参数。
fn addOutputFlag(command: *zli.Command) !void {
    try command.addFlag(.{
        .name = "output",
        .shortcut = "o",
        .description = "Output format: human or json",
        .type = .String,
        .default_value = .{ .String = "human" },
    });
}

/// 为可失败的本地命令声明简短的诊断输出开关。
fn addDebugFlag(command: *zli.Command) !void {
    try command.addFlag(.{
        .name = "debug",
        .shortcut = "d",
        .description = "Show diagnostic error details",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
}

/// 执行 `status` 或 `check`。二者使用同一组探针，通过输出详细度区分用途。
/// 管理探针固定连接本机 127.0.0.1；HTTP 数据面探针连接配置中的 `server_ip`。
fn statusCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    config_path: []const u8,
    output_json: bool,
    debug: bool,
    action: []const u8,
    out: *std.Io.Writer,
) !u8 {
    var parsed_config = loadConfig(io, allocator, config_path, out, debug) orelse return 1;
    defer parsed_config.deinit();
    const status = nodeforge.management_client.managementStatus(io, parsed_config.value.server.http_port);
    const active_config = nodeforge.management_client.validateActiveConfig(io, parsed_config.value.server.http_port);
    const health = nodeforge.management_client.healthAt(
        io,
        parsed_config.value.server.server_ip,
        parsed_config.value.server.http_port,
    );
    const ok = status.healthy and active_config.healthy and health.healthy;
    if (output_json) {
        try out.print(
            "{{\"process\":{s},\"http\":{s},\"management\":{s},\"config\":{s}}}\n",
            .{ jsonBool(status.reachable), jsonBool(health.healthy), jsonBool(status.healthy), jsonBool(active_config.healthy) },
        );
        return if (ok) 0 else 1;
    }
    if (std.mem.eql(u8, action, "check")) {
        if (ok) {
            try out.writeAll("OK nodeforge checks passed\n");
        } else {
            try out.writeAll("FAIL nodeforge checks failed\n");
            try printCheckLine(out, "Process", status.reachable);
            try printCheckLine(out, "HTTP", health.healthy);
            try printCheckLine(out, "Management", status.healthy);
            try printCheckLine(out, "Config API", active_config.healthy);
        }
        return if (ok) 0 else 1;
    }

    try out.writeAll("NodeForge status\n");
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

/// 封装“已解析 catalog”或“文件缺失时的空 catalog”，统一生命周期管理。
const CatalogLoad = struct {
    /// 文件存在时持有 JSON parser 分配的所有权。
    parsed: ?std.json.Parsed(nodeforge.model.Catalog),
    /// 文件缺失时提供只读空值。
    empty: nodeforge.model.Catalog,

    /// 返回当前有效 catalog，不转移所有权。
    fn value(self: *const CatalogLoad) *const nodeforge.model.Catalog {
        if (self.parsed) |*parsed| return &parsed.value;
        return &self.empty;
    }

    /// 仅在持有已解析 catalog 时释放 parser 分配。
    fn deinit(self: *CatalogLoad) void {
        if (self.parsed) |*parsed| parsed.deinit();
    }
};

/// 加载 catalog；文件不存在按 M0 初始空 catalog 处理，其他错误输出后返回 null。
fn loadCatalogOrEmpty(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    out: *std.Io.Writer,
    debug: bool,
) ?CatalogLoad {
    const parsed = nodeforge.catalog_store.load(io, allocator, path) catch |err| switch (err) {
        error.FileNotFound => return .{ .parsed = null, .empty = nodeforge.catalog_store.empty() },
        else => {
            printLoadError(out, "catalog", path, err, debug) catch {};
            return null;
        },
    };
    return .{ .parsed = parsed, .empty = nodeforge.catalog_store.empty() };
}

/// 加载并执行单文件配置校验；失败时负责输出错误并释放已分配内容。
fn loadConfig(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    out: *std.Io.Writer,
    debug: bool,
) ?std.json.Parsed(nodeforge.model.AppConfig) {
    var parsed = nodeforge.config.load(io, allocator, path) catch |err| {
        printLoadError(out, "config", path, err, debug) catch {};
        return null;
    };
    nodeforge.config_validate.validateConfig(&parsed.value) catch |err| {
        printValidationError(out, "config", path, err, debug) catch {};
        parsed.deinit();
        return null;
    };
    return parsed;
}

/// 输出简短的文件加载错误；debug 模式追加底层 Zig 错误标签。
fn printLoadError(out: *std.Io.Writer, subject: []const u8, path: []const u8, err: anyerror, debug: bool) !void {
    if (err == error.FileNotFound)
        try out.print("error: {s}: file not found: {s}\n", .{ subject, path })
    else
        try out.print("error: {s}: cannot load: {s}\n", .{ subject, path });
    if (debug) try out.print("debug: {s}: load cause={t}\n", .{ subject, err });
}

/// 输出简短的配置或 catalog 校验错误；debug 模式追加校验器错误标签。
fn printValidationError(out: *std.Io.Writer, subject: []const u8, path: []const u8, err: anyerror, debug: bool) !void {
    try out.print("error: {s}: validation failed: {s}\n", .{ subject, path });
    if (debug) try out.print("debug: {s}: validation cause={t}\n", .{ subject, err });
}

/// 判断错误是否属于用户可修正的 CLI 语法错误，用于稳定映射退出码 2。
fn isUsageError(err: anyerror) bool {
    return switch (err) {
        error.InvalidBooleanValue,
        error.InvalidFlagValue,
        error.InvalidFlagNegation,
        error.InvalidFlagShortcut,
        error.InvalidPositionalArgOrder,
        error.MissingArgs,
        error.MissingFlagValue,
        error.TooManyArgs,
        error.UnknownCommand,
        error.UnknownFlag,
        error.CommandDeprecated,
        => true,
        else => false,
    };
}

/// 返回可直接嵌入 JSON 的布尔字面量。
fn jsonBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// 输出一行对齐的 human 健康检查结果。
fn printCheckLine(out: *std.Io.Writer, label: []const u8, passed: bool) !void {
    try out.print("  {s:<12} {s}\n", .{ label, if (passed) "OK" else "FAIL" });
}

/// 输出稳定的 CLI 名称与项目版本。
fn printVersion(out: *std.Io.Writer) !void {
    try out.print("nodeforge {s}\n", .{nodeforge.version.version});
}
