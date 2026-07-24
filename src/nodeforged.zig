//! `nodeforged` 单进程守护程序入口。
//! zli 负责参数声明、校验和自动帮助；启动顺序保持“加载 -> 校验 -> 自检/监听”。
//! 退出码约定：0 表示请求的模式成功完成，1 表示输入、预检或服务运行失败，2 表示用法错误。

const std = @import("std");
const zli = @import("zli");
const nodeforge = @import("nodeforge");

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = nodeforge.log_backend.logFn };

/// zli 用于 `--version` 元数据的编译期语义版本。
const semantic_version = std.SemanticVersion.parse(nodeforge.version.version) catch unreachable;

/// 初始化标准 IO，执行 daemon CLI，并将结果转换为进程退出状态。
pub fn main(init: std.process.Init) void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file = std.Io.File.Reader.init(.stdin(), init.io, &stdin_buffer);

    if (versionOnly(init.minimal.args)) {
        printVersion(&stdout_file.interface) catch std.process.exit(1);
        stdout_file.interface.flush() catch {};
        return;
    }

    nodeforge.paths.bootstrap(init.io, init.arena.allocator(), init.minimal.args) catch |err| {
        nodeforge.observe_log.err("install root bootstrap failed: {t}", .{err});
        std.process.exit(1);
    };

    const exit_code = run(init, &stdout_file.interface, &stdin_file.interface) catch 1;
    stdout_file.interface.flush() catch {};
    if (exit_code != 0) std.process.exit(exit_code);
}

/// 检查命令行是否仅为 `--version` 或 `-v`，用于在路径自举前快速短路返回版本信息。
fn versionOnly(args: std.process.Args) bool {
    var iterator = args.iterate();
    _ = iterator.next();
    const flag = iterator.next() orelse return false;
    return (std.mem.eql(u8, flag, "--version") or std.mem.eql(u8, flag, "-v")) and iterator.next() == null;
}

/// 构建并执行一次 `nodeforged` 参数解析。
/// 可识别的 zli 语法错误映射为退出码 2，其他错误交给入口映射为退出码 1。
fn run(init: std.process.Init, out: *std.Io.Writer, in: *std.Io.Reader) !u8 {
    const root = try buildCli(.{
        .allocator = init.arena.allocator(),
        .io = init.io,
        .writer = out,
        .reader = in,
    });
    defer root.deinit();

    var args_iter = init.minimal.args.iterate();
    root.execute(&args_iter, .{}) catch |err| {
        if (isUsageError(err)) return 2;
        nodeforge.observe_log.err("daemon: fatal: {t}", .{err});
        return err;
    };
    return 0;
}

/// 声明 `nodeforged` 的完整命令树、默认路径和三种运行模式。
/// 正常部署无需路径参数；`--config` 和 `--catalog` 仅用于开发、迁移或诊断覆盖。
fn buildCli(init_options: zli.InitOptions) !*zli.Command {
    const help = try std.fmt.allocPrint(
        init_options.allocator,
        "Normal deployments load config and catalog from {s}.\nUse overrides for development, testing, migration, or temporary diagnostics.",
        .{nodeforge.paths.require().install_root},
    );
    const root = try zli.Command.init(init_options, .{
        .name = "nodeforged",
        .description = "NodeForge daemon",
        .version = semantic_version,
        .usage = "nodeforged [options]",
        .help = help,
    }, daemonHandler);
    try root.addFlags(&.{
        .{
            .name = "version",
            .shortcut = "v",
            .description = "Show version and exit",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
        .{
            .name = "install-root",
            .description = "Explicit marked NodeForge install root",
            .type = .String,
            .default_value = .{ .String = "" },
        },
        .{
            .name = "config",
            .shortcut = "c",
            .description = "Override config JSON path",
            .type = .String,
            .default_value = .{ .String = nodeforge.config.defaultPath() },
        },
        .{
            .name = "catalog",
            .shortcut = "C",
            .description = "Override catalog JSON path",
            .type = .String,
            .default_value = .{ .String = nodeforge.catalog_store.defaultPath() },
        },
        .{
            .name = "check-config",
            .shortcut = "K",
            .description = "Validate config and catalog, then exit",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
        .{
            .name = "check",
            .shortcut = "k",
            .description = "Validate inputs, probe the HTTP port, then exit",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
        .{
            .name = "debug",
            .shortcut = "d",
            .description = "Enable debug service logs for this invocation",
            .type = .Bool,
            .default_value = .{ .Bool = false },
        },
        .{
            .name = "log-output",
            .description = "Service log destination: auto, terminal, file, or both (e.g. file)",
            .type = .String,
            .default_value = .{ .String = "auto" },
        },
        .{
            .name = "log-file",
            .description = "Override the file destination for --log-output file/both (default: <install-root>/logs/nodeforged.log)",
            .type = .String,
            .default_value = .{ .String = "" },
        },
    });
    return root;
}

/// 加载并联合校验 config/catalog，然后按 flag 选择运行模式。
/// `--check-config` 只校验文件，`--check` 再执行 HTTP/TFTP 端口预检，无 flag 时启动服务。
fn daemonHandler(ctx: zli.CommandContext) !void {
    if (ctx.flag("version", bool)) {
        try printVersion(ctx.writer);
        return;
    }

    const debug = ctx.flag("debug", bool);
    const requested_log_output = std.meta.stringToEnum(LogOutput, ctx.flag("log-output", []const u8)) orelse
        return error.InvalidFlagValue;
    const log_file_override = ctx.flag("log-file", []const u8);
    if (log_file_override.len != 0 and (requested_log_output == .auto or requested_log_output == .terminal))
        return error.InvalidFlagValue;
    if (log_file_override.len != 0 and log_file_override[0] != '/') return error.InvalidFlagValue;
    const default_logging: nodeforge.model.LoggingConfig = .{};
    configureLogOutput(ctx.io, requested_log_output, log_file_override, &default_logging);
    if (debug) nodeforge.observe_log.setLevel(.debug);
    const config_path = ctx.flag("config", []const u8);
    const catalog_path = ctx.flag("catalog", []const u8);

    const transaction_dir = try nodeforge.model_transaction.directoryForConfig(ctx.allocator, config_path);
    defer ctx.allocator.free(transaction_dir);
    const recovered = nodeforge.model_transaction.recoverAll(ctx.io, ctx.allocator, transaction_dir) catch |err| {
        nodeforge.observe_log.err("model: transaction recovery failed closed: {t}", .{err});
        return err;
    };
    if (recovered != 0) nodeforge.observe_log.info("model: recovered {d} transaction journal(s) before validation", .{recovered});
    const schema_recovered = nodeforge.schema_v3_transaction.recoverAll(ctx.io, ctx.allocator, transaction_dir) catch |err| {
        nodeforge.observe_log.err("schema-v3: transaction recovery failed closed: {t}", .{err});
        return err;
    };
    if (schema_recovered != 0) nodeforge.observe_log.info("schema-v3: recovered {d} transaction journal(s) before validation", .{schema_recovered});

    var parsed = nodeforge.config.load(ctx.io, ctx.allocator, config_path) catch |err| {
        nodeforge.observe_log.err("config: cannot load {s}", .{config_path});
        if (debug) nodeforge.observe_log.debug("config: load cause={t}", .{err});
        return err;
    };
    defer parsed.deinit();
    if (!debug) nodeforge.observe_log.setLevel(switch (parsed.value.logging.level) {
        .debug => .debug,
        .info => .info,
        .warn => .warn,
        .err => .err,
    });

    // 仅对发现的默认模型进行自动迁移。显式覆盖
    // 是诊断输入，绝不能作为副作用被改写。
    if (parsed.value.schema_version == 1 and
        std.mem.eql(u8, config_path, nodeforge.paths.require().config_path) and
        std.mem.eql(u8, catalog_path, nodeforge.paths.require().catalog_dir))
    {
        if (try nodeforge.setup.migrateLegacy(ctx.io, ctx.allocator, nodeforge.paths.require())) {
            parsed.deinit();
            parsed = try nodeforge.config.load(ctx.io, ctx.allocator, config_path);
            nodeforge.observe_log.info("model: migrated schema-1 config/catalog to M4.7 manifest layout", .{});
        }
    }

    var parsed_catalog = nodeforge.catalog_store.load(ctx.io, ctx.allocator, catalog_path) catch |err| switch (err) {
        error.FileNotFound => blk: {
            // 缺失的 manifest 仅对发现的 catalog 目录进行初始化。
            // 显式旧版 `.json` 诊断保持只读。
            if (std.mem.endsWith(u8, catalog_path, ".json")) {
                const initial = nodeforge.catalog_store.empty();
                try nodeforge.catalog_store.save(ctx.io, ctx.allocator, catalog_path, &initial);
                break :blk try nodeforge.catalog_store.load(ctx.io, ctx.allocator, catalog_path);
            }
            try nodeforge.catalog_store.initializeEmpty(ctx.io, ctx.allocator, catalog_path);
            break :blk try nodeforge.catalog_store.load(ctx.io, ctx.allocator, catalog_path);
        },
        else => {
            nodeforge.observe_log.err("catalog: cannot load {s}", .{catalog_path});
            if (debug) nodeforge.observe_log.debug("catalog: load cause={t}", .{err});
            return err;
        },
    };
    defer parsed_catalog.deinit();
    const stored_catalog = &parsed_catalog.value;
    // schema 1 输入在 config 中保留受管实体。它们被投影
    // 到内存中的 Catalog 用于校验；setup/migration 在生产启动前
    // 发布持久的 manifest 布局。
    var catalog_value = stored_catalog.*;
    if (catalog_value.distros.len == 0) catalog_value.distros = parsed.value.distros;
    if (catalog_value.profiles.len == 0) catalog_value.profiles = parsed.value.profiles;
    if (catalog_value.nodes.len == 0) catalog_value.nodes = parsed.value.nodes;
    if (catalog_value.provisioning_bundles.len == 0) catalog_value.provisioning_bundles = parsed.value.provisioning_bundles;
    if (parsed.value.schema_version == 1 and std.mem.endsWith(u8, catalog_path, ".json"))
        try nodeforge.catalog_store.save(ctx.io, ctx.allocator, catalog_path, &catalog_value);
    var effective_config = nodeforge.model.projectCatalog(parsed.value, &catalog_value);
    const catalog = &catalog_value;

    nodeforge.config_validate.validate(&effective_config, catalog) catch |err| {
        nodeforge.observe_log.err("config: validation failed: {s}", .{config_path});
        if (debug) nodeforge.observe_log.debug("config: validation cause={t}", .{err});
        return err;
    };

    configureLogOutput(ctx.io, requested_log_output, log_file_override, &parsed.value.logging);

    if (ctx.flag("check-config", bool)) {
        nodeforge.observe_log.info("config: valid {s}; catalog {s}", .{ config_path, catalog_path });
        return;
    }
    if (ctx.flag("check", bool)) {
        nodeforge.preflight.checkPorts(ctx.io, &parsed.value) catch |err| {
            nodeforge.observe_log.err("preflight: failed", .{});
            if (debug or parsed.value.logging.level == .debug)
                nodeforge.observe_log.debug("preflight: cause={t}", .{err});
            return err;
        };
        nodeforge.preflight.checkInstallSourcePrerequisites(ctx.io, ctx.allocator) catch |err| {
            nodeforge.observe_log.err("preflight: install source import unavailable", .{});
            if (debug or parsed.value.logging.level == .debug)
                nodeforge.observe_log.debug("preflight: cause={t}", .{err});
            return err;
        };
        nodeforge.observe_log.info("preflight: config, HTTP, TFTP and DHCP ports available", .{});
        return;
    }

    try nodeforge.app.run(ctx.io, ctx.allocator, &effective_config, config_path, catalog, catalog_path);
}

/// 日志输出模式枚举。控制服务日志的写入目标。
const LogOutput = enum {
    /// 自动模式：配置了日志文件则双写，否则只输出到终端。
    auto,
    /// 仅输出到终端（stderr/systemd journal）。
    terminal,
    /// 仅写入日志文件。
    file,
    /// 同时输出到终端和日志文件。
    both,
};

/// 根据命令行 `--log-output` 参数和配置文件日志策略配置日志后端。
///
/// `auto` 模式根据 `logging.file` 是否为 null 决定输出目标；
/// `file`/`both` 模式使用配置文件路径或 `--log-file` 覆盖路径。
fn configureLogOutput(
    io: std.Io,
    requested: LogOutput,
    file_override: []const u8,
    logging: *const nodeforge.model.LoggingConfig,
) void {
    const mode: nodeforge.log_backend.OutputMode = switch (requested) {
        .auto => if (logging.file == null) .terminal else .both,
        .terminal => .terminal,
        .file => .file,
        .both => .both,
    };
    if (mode == .terminal) {
        nodeforge.log_backend.configure(io, mode, null);
        return;
    }

    const configured_file: nodeforge.model.FileLogConfig = logging.file orelse .{
        .path = nodeforge.paths.require().service_log_path,
        .max_size_mb = 50,
        .keep = 3,
    };
    nodeforge.log_backend.configure(io, mode, .{
        .path = if (file_override.len == 0) configured_file.path else file_override,
        .max_size_mb = configured_file.max_size_mb,
        .keep = configured_file.keep,
    });
}

/// 输出稳定的 daemon 名称与项目版本。
fn printVersion(out: *std.Io.Writer) !void {
    try out.print("nodeforged {s} (commit {s}, built {s}, {s})\n", .{
        nodeforge.version.version,
        nodeforge.version.shortCommit(),
        nodeforge.version.build_time,
        if (nodeforge.version.git_dirty) "dirty" else "clean",
    });
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
