//! `nodeforge` M0 管理命令行入口。
//! zli 持有唯一命令树并据此完成解析、校验和帮助生成；业务语义仍委托核心库。
//! 退出码约定：0 表示成功，1 表示业务检查或运行失败，2 表示命令行用法错误。

const std = @import("std");
const zli = @import("zli");
const nodeforge = @import("nodeforge");
const views = @import("nodeforge").cli_views;
const cli_output = @import("nodeforge").cli_output;
const cli_events = @import("nodeforge").cli_events;

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = nodeforge.log_backend.logFn };

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

    const tftp = try zli.Command.init(init_options, .{
        .name = "tftp",
        .description = "Inspect the local TFTP service",
        .usage = "nodeforge tftp <command> [options]",
        .help = "Read M1 TFTP runtime state from the local nodeforged management listener.",
    }, showCurrentHelp);
    const tftp_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show TFTP transfer counters" }, tftpShowHandler);
    try addConfigPathFlag(tftp_show);
    try addOutputFlag(tftp_show);
    try addDebugFlag(tftp_show);
    const tftp_session = try zli.Command.init(init_options, .{ .name = "session", .description = "Inspect TFTP transfer sessions" }, showCurrentHelp);
    const tftp_session_list = try zli.Command.init(init_options, .{ .name = "list", .description = "Show recent TFTP transfer sessions" }, tftpSessionListHandler);
    try addConfigPathFlag(tftp_session_list);
    try addOutputFlag(tftp_session_list);
    try addDebugFlag(tftp_session_list);
    try tftp_session.addCommands(&.{tftp_session_list});
    try tftp.addCommands(&.{ tftp_show, tftp_session });

    const dhcp = try zli.Command.init(init_options, .{
        .name = "dhcp",
        .description = "Inspect the DHCPv4 service configuration",
        .usage = "nodeforge dhcp show [options]",
    }, showCurrentHelp);
    const dhcp_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show DHCP subnet and pool configuration" }, dhcpShowHandler);
    try addConfigPathFlag(dhcp_show);
    try addOutputFlag(dhcp_show);
    try addDebugFlag(dhcp_show);
    try dhcp.addCommands(&.{dhcp_show});

    const runtime = try zli.Command.init(init_options, .{ .name = "runtime", .description = "Inspect current DHCP runtime state" }, showCurrentHelp);
    const leases = try zli.Command.init(init_options, .{ .name = "leases", .description = "Inspect DHCP leases" }, showCurrentHelp);
    const leases_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List active DHCP leases" }, runtimeLeasesHandler);
    try addConfigPathFlag(leases_list);
    try addOutputFlag(leases_list);
    try addDebugFlag(leases_list);
    const unknown = try zli.Command.init(init_options, .{ .name = "unknown", .description = "Inspect unclaimed DHCP clients" }, showCurrentHelp);
    const unknown_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List unclaimed DHCP clients" }, runtimeUnknownHandler);
    try addConfigPathFlag(unknown_list);
    try addOutputFlag(unknown_list);
    try addDebugFlag(unknown_list);
    try leases.addCommands(&.{leases_list});
    try unknown.addCommands(&.{unknown_list});
    try runtime.addCommands(&.{ leases, unknown });

    const node = try zli.Command.init(init_options, .{ .name = "node", .description = "Inspect registered nodes" }, showCurrentHelp);
    const node_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List registered nodes" }, nodeListHandler);
    try addConfigPathFlag(node_list);
    try addOutputFlag(node_list);
    try addDebugFlag(node_list);
    try node.addCommands(&.{node_list});

    const install = try zli.Command.init(init_options, .{
        .name = "install",
        .description = "Preview M4 unattended installer answers",
        .usage = "nodeforge install render <node_id> [options]",
        .help = "Render the selected node's Kickstart or Ubuntu NoCloud answer locally. Preview output redacts runtime session credentials.",
    }, showCurrentHelp);
    const install_render = try zli.Command.init(init_options, .{ .name = "render", .description = "Render the unattended install answer for one registered node" }, installRenderHandler);
    try install_render.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try addConfigPathFlag(install_render);
    try addCatalogPathFlag(install_render);
    try addOutputFlag(install_render);
    try addDebugFlag(install_render);
    try install.addCommands(&.{install_render});
    const install_retry = try zli.Command.init(init_options, .{ .name = "retry", .description = "Explicitly rearm the next PXE install generation" }, installRetryHandler);
    try install_retry.addPositionalArg(.{ .name = "node_id", .description = "Registered install node", .required = true });
    try addConfigPathFlag(install_retry);
    try addOutputFlag(install_retry);
    try addDebugFlag(install_retry);
    try install.addCommands(&.{install_retry});

    const asset = try zli.Command.init(init_options, .{
        .name = "asset",
        .description = "Inspect and register TFTP boot assets",
        .usage = "nodeforge asset <command> [options]",
        .help = "M1 asset paths are relative to config.tftp.asset_root and are integrity checked before catalog registration.",
    }, showCurrentHelp);
    try asset.addCommands(&.{ try assetImportCommand(init_options), try assetListCommand(init_options), try assetShowCommand(init_options), try assetValidateCommand(init_options) });

    const install_source = try zli.Command.init(init_options, .{
        .name = "install-source",
        .description = "Import validated Linux installation media",
        .usage = "nodeforge install-source import <iso-path> [options]",
        .help = "The ISO may be at any local path. The CLI stages a managed copy before the local daemon performs its read-only loop mount.",
    }, showCurrentHelp);
    try install_source.addCommands(&.{try installSourceImportCommand(init_options)});

    const events = try zli.Command.init(init_options, .{
        .name = "events",
        .description = "Query local Event v1/v2 audit history",
        .usage = "nodeforge events <list|follow|types> [options]",
        .help = "Read the local daemon event stream and retained rotations without contacting the management API.",
    }, showCurrentHelp);
    const events_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List retained events" }, eventsListHandler);
    try addEventsFilterFlags(events_list, true);
    const events_follow = try zli.Command.init(init_options, .{ .name = "follow", .description = "Follow new events from the active file" }, eventsFollowHandler);
    try addEventsFilterFlags(events_follow, false);
    const events_types = try zli.Command.init(init_options, .{ .name = "types", .description = "List registered event types" }, eventsTypesHandler);
    try addOutputFlag(events_types);
    try events.addCommands(&.{ events_list, events_follow, events_types });
    // trace 是只读的因果重建视图：只消费 daemon 审计流，不连接管理 API，
    // 更不会因查询而创建或推进 boot session。
    const trace = try zli.Command.init(init_options, .{
        .name = "trace",
        .description = "Reconstruct one node boot-session timeline from local events",
        .usage = "nodeforge trace <node_id> [--session <boot_session_id>] [--latest] [options]",
    }, traceHandler);
    try trace.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try trace.addFlags(&.{
        .{ .name = "session", .description = "Exact 32-character boot session identifier", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "latest", .description = "Select the latest retained session (default when --session is omitted)", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "events-path", .description = "Local Event JSONL path (development or recovery override)", .type = .String, .default_value = .{ .String = nodeforge.paths.events_path } },
    });
    try addOutputFlag(trace);

    try root.addCommands(&.{
        status,
        check,
        config,
        catalog,
        tftp,
        dhcp,
        runtime,
        node,
        install,
        asset,
        install_source,
        events,
        trace,
    });
    return root;
}

fn installSourceImportCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{
        .name = "import",
        .description = "Import one Rocky or Ubuntu ISO and publish its install source",
        .help = "Accepts an ISO at any local path. The CLI stages a temporary managed copy, then asks the local daemon to mount, validate and publish it. The original file is never moved or deleted; distro/version/arch are detected unless supplied as checks.",
    }, installSourceImportHandler);
    try addConfigPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
    try command.addPositionalArg(.{ .name = "iso-path", .description = "Readable local ISO path; e.g. /srv/iso/ubuntu-22.04.5-live-server-arm64.iso", .required = true });
    try command.addFlags(&.{
        .{ .name = "distro", .description = "Optional detected-distro check; e.g. ubuntu", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "version", .description = "Optional detected-version check; e.g. 22.04", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "arch", .description = "Optional detected-architecture check; e.g. aarch64", .type = .String, .default_value = .{ .String = "" } },
    });
    return command;
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

fn assetImportCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{ .name = "import", .description = "Register an existing TFTP asset and its SHA-256" }, assetImportHandler);
    try addConfigPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
    try command.addFlags(&.{
        .{ .name = "type", .description = "Asset kind; e.g. bootloader (also kernel, installer_initrd, nodeforge_initrd, rootfs, iso, gpg_key)", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "name", .description = "Unique catalog name; e.g. rocky-9.7-aarch64-kernel", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "path", .description = "Path relative to tftp.asset_root; e.g. boot/rocky/9.7/aarch64/vmlinuz", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "distro", .description = "Distro name, used with --version and --arch; e.g. rocky", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "version", .description = "Distro version, used with --distro and --arch; e.g. 9.7", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "arch", .description = "Architecture, used with --distro and --version; e.g. aarch64 (or x86_64)", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "kernel-release", .description = "Kernel uname release for bundle matching; e.g. 5.14.0-611.el9.aarch64", .type = .String, .default_value = .{ .String = "" } },
    });
    return command;
}

fn assetListCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{ .name = "list", .description = "List registered assets" }, assetListHandler);
    try addCatalogPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
    return command;
}

fn assetShowCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{ .name = "show", .description = "Show one registered asset" }, assetShowHandler);
    try addCatalogPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
    try command.addPositionalArg(.{ .name = "name", .description = "Asset name", .required = true });
    return command;
}

fn assetValidateCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{ .name = "validate", .description = "Verify TFTP asset files and SHA-256 digests" }, assetValidateHandler);
    try addConfigPathFlag(command);
    try addCatalogPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
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
        try views.success(ctx.writer, "config valid", &.{ .{ .label = "Config", .value = config_path }, .{ .label = "Catalog", .value = catalog_path } });
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
        try views.success(ctx.writer, "config imported", &.{ .{ .label = "Source", .value = source }, .{ .label = "Destination", .value = config_path } });
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
        try views.success(ctx.writer, "catalog valid", &.{.{ .label = "Catalog", .value = catalog_path }});
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

/// 导入一个已存在的 root 受管文件，计算其 SHA-256 摘要，校验候选 catalog
/// 后原子发布新 manifest。
///
/// 这是一个离线路径：不通过 daemon 的管理 API，而是直接操作 catalog 文件。
/// 适用于 daemon 尚未启动时的初始部署场景。导入过程：
/// 1. 解析 --type/--name/--path/--distro/--version/--arch/--kernel-release 参数
/// 2. 通过管理 API 请求 daemon 执行实际导入（计算摘要、校验、发布）
/// 3. daemon 拒绝时返回退出码 1，CLI 参数错误返回退出码 2
fn assetImportHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    const kind = std.meta.stringToEnum(nodeforge.model.AssetKind, ctx.flag("type", []const u8)) orelse {
        try ctx.writer.writeAll("error: asset: unsupported --type\n");
        setExitCode(ctx, 2);
        return;
    };
    const name = ctx.flag("name", []const u8);
    const path = ctx.flag("path", []const u8);
    if (name.len == 0 or path.len == 0) {
        try ctx.writer.writeAll("error: asset: --name and --path are required\n");
        setExitCode(ctx, 2);
        return;
    }
    const distro_value = ctx.flag("distro", []const u8);
    const version_value = ctx.flag("version", []const u8);
    const arch_value = ctx.flag("arch", []const u8);
    const has_tuple = distro_value.len != 0 or version_value.len != 0 or arch_value.len != 0;
    if (has_tuple and (distro_value.len == 0 or version_value.len == 0 or arch_value.len == 0)) {
        try ctx.writer.writeAll("error: asset: --distro, --version and --arch must be used together\n");
        setExitCode(ctx, 2);
        return;
    }
    const arch = if (has_tuple) std.meta.stringToEnum(nodeforge.model.Arch, arch_value) orelse {
        try ctx.writer.writeAll("error: asset: unsupported --arch\n");
        setExitCode(ctx, 2);
        return;
    } else null;
    const imported = nodeforge.management_client.importAsset(ctx.io, parsed_config.value.server.http_port, .{
        .name = name,
        .kind = @tagName(kind),
        .path = path,
        .distro = if (has_tuple) distro_value else null,
        .version = if (has_tuple) version_value else null,
        .arch = if (arch) |value| @tagName(value) else null,
        .kernel_release = if (ctx.flag("kernel-release", []const u8).len == 0) null else ctx.flag("kernel-release", []const u8),
    }) catch |err| {
        try ctx.writer.print("error: asset: import request failed\n", .{});
        if (debug) try ctx.writer.print("debug: asset: cause={t}\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    if (!imported) {
        try ctx.writer.writeAll("error: asset: daemon rejected import\n");
        setExitCode(ctx, 1);
        return;
    }
    if (output_json) try ctx.writer.print("{{\"ok\":true,\"name\":\"{s}\"}}\n", .{name}) else try views.success(ctx.writer, "asset imported", &.{.{ .label = "Name", .value = name }});
}

/// M3.6 `install-source import` 命令处理器。
///
/// 完整流程：
/// 1. 加载启动配置获取 daemon HTTP 端口
/// 2. 校验 --arch 参数（如果提供了的话）
/// 3. 调用 `stageInstallIso` 将 ISO 原子复制到 daemon 受管的暂存目录
/// 4. 通过管理 API 请求 daemon 执行 loop mount、介质检测和 catalog 发布
/// 5. daemon 返回后，defer 清理暂存文件
///
/// 安全设计：CLI 永远不将任意宿主路径发送给 daemon，只发送暂存目录中的
/// 不透明 basename。daemon 只在受管目录内操作，杜绝路径穿越攻击。
/// 原始 ISO 文件永远不会被移动或删除。
fn installSourceImportHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    const iso_path = ctx.getArg("iso-path") orelse unreachable;
    const distro = ctx.flag("distro", []const u8);
    const version = ctx.flag("version", []const u8);
    const arch = ctx.flag("arch", []const u8);
    if (arch.len != 0 and std.meta.stringToEnum(nodeforge.model.Arch, arch) == null) {
        try ctx.writer.writeAll("error: install-source: unsupported --arch\n");
        setExitCode(ctx, 2);
        return;
    }
    const staged = stageInstallIso(ctx.io, ctx.allocator, iso_path) catch |err| {
        try ctx.writer.writeAll("error: install-source: cannot stage ISO\n");
        if (debug) try ctx.writer.print("debug: install-source: stage cause={t}\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    defer {
        std.Io.Dir.cwd().deleteFile(ctx.io, staged.path) catch {};
        ctx.allocator.free(staged.filename);
        ctx.allocator.free(staged.path);
    }
    if (!output_json) try ctx.writer.print("Staged ISO ({d} bytes) from {s}; validating and importing\n", .{ staged.size, iso_path });
    const imported = nodeforge.management_client.importInstallSource(ctx.io, parsed_config.value.server.http_port, .{
        .filename = staged.filename,
        .distro = if (distro.len == 0) null else distro,
        .version = if (version.len == 0) null else version,
        .arch = if (arch.len == 0) null else arch,
    }) catch |err| {
        try ctx.writer.writeAll("error: install-source: import request failed\n");
        if (debug) try ctx.writer.print("debug: install-source: cause={t}\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    if (!imported) {
        try ctx.writer.writeAll("error: install-source: daemon rejected import\n");
        setExitCode(ctx, 1);
        return;
    }
    if (output_json) try ctx.writer.print("{{\"ok\":true,\"path\":{f}}}\n", .{std.json.fmt(iso_path, .{})}) else try views.success(ctx.writer, "install source imported", &.{.{ .label = "ISO", .value = iso_path }});
}

/// 暂存 ISO 的结果：daemon 受管目录中的不透明文件名、完整路径和文件大小。
const StagedInstallIso = struct {
    filename: []u8,
    path: []u8,
    size: u64,
};

/// 将管理员指定的 ISO 原子复制到 daemon 受管的暂存目录。
///
/// 安全设计：
/// - daemon 永远不会收到任意宿主路径，只收到暂存目录中的不透明 basename。
/// - 管理员可以选择任何可读的普通 ISO 文件（拒绝符号链接）。
/// - 文件名前缀 12 字节安全随机 hex，防止文件名碰撞和预测。
/// - 复制使用 replace=false，如果目标已存在则失败（防止竞态覆盖）。
/// - 调用方通过 defer 删除暂存文件，确保不会残留。
fn stageInstallIso(io: std.Io, allocator: std.mem.Allocator, source: []const u8) !StagedInstallIso {
    var input = try std.Io.Dir.cwd().openFile(io, source, .{ .follow_symlinks = false });
    defer input.close(io);
    const stat = try input.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    const basename = std.fs.path.basename(source);
    if (basename.len == 0 or !std.mem.endsWith(u8, basename, ".iso")) return error.InvalidIsoPath;

    var random: [12]u8 = undefined;
    try io.randomSecure(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const filename = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ hex[0..], basename });
    errdefer allocator.free(filename);
    const destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ nodeforge.paths.import_dir, filename });
    errdefer allocator.free(destination);
    try std.Io.Dir.cwd().createDirPath(io, nodeforge.paths.import_dir);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source, std.Io.Dir.cwd(), destination, io, .{ .permissions = .default_file, .replace = false });
    return .{ .filename = filename, .path = destination, .size = stat.size };
}

fn assetListHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer loaded.deinit();
    if (output_json) {
        try ctx.writer.writeAll("{\"assets\":[");
        for (loaded.value().assets, 0..) |item, i| {
            if (i != 0) try ctx.writer.writeByte(',');
            try ctx.writer.print("{{\"name\":\"{s}\",\"kind\":\"{t}\",\"path\":\"{s}\"}}", .{ item.name, item.kind, item.path });
        }
        try ctx.writer.writeAll("]}\n");
    } else {
        var rows: [64]views.AssetRow = undefined;
        if (loaded.value().assets.len > rows.len) return error.TooManyAssets;
        for (loaded.value().assets, 0..) |item, i| rows[i] = .{ .name = item.name, .kind = @tagName(item.kind), .path = item.path };
        try views.assets(ctx.writer, rows[0..loaded.value().assets.len]);
    }
}

fn assetShowHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer loaded.deinit();
    const name = ctx.getArg("name") orelse unreachable;
    for (loaded.value().assets) |item| if (std.mem.eql(u8, item.name, name)) {
        if (output_json) try ctx.writer.print("{{\"name\":\"{s}\",\"kind\":\"{t}\",\"path\":\"{s}\",\"sha256\":{f}}}\n", .{ item.name, item.kind, item.path, std.json.fmt(item.sha256, .{}) }) else try views.assetDetail(ctx.writer, item.name, @tagName(item.kind), item.path, item.sha256 orelse "");
        return;
    };
    try ctx.writer.print("error: asset: not found: {s}\n", .{name});
    setExitCode(ctx, 1);
}

fn assetValidateHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer loaded.deinit();
    for (loaded.value().assets) |item| {
        var digest: [64]u8 = undefined;
        nodeforge.asset_validate.sha256File(ctx.io, parsed_config.value.tftp.asset_root, item.path, &digest) catch {
            try ctx.writer.print("error: asset: unreadable: {s}\n", .{item.path});
            setExitCode(ctx, 1);
            return;
        };
        if (item.sha256 == null or !std.mem.eql(u8, item.sha256.?, &digest)) {
            try ctx.writer.print("error: asset: checksum mismatch: {s}\n", .{item.name});
            setExitCode(ctx, 1);
            return;
        }
    }
    if (output_json) try ctx.writer.writeAll("{\"ok\":true}\n") else {
        var count: [20]u8 = undefined;
        try views.success(ctx.writer, "assets valid", &.{.{ .label = "Assets", .value = try std.fmt.bufPrint(&count, "{d}", .{loaded.value().assets.len}) }});
    }
}

fn tftpShowHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    const status = nodeforge.management_client.tftpCounters(ctx.io, parsed_config.value.server.http_port);
    if (!status.healthy) {
        try ctx.writer.writeAll("error: tftp: local daemon status unavailable\n");
        setExitCode(ctx, 1);
        return;
    }
    if (output_json) try ctx.writer.print("{{\"started\":{d},\"completed\":{d},\"failed\":{d}}}\n", .{ status.started, status.completed, status.failed }) else try views.tftpCounters(ctx.writer, status.started, status.completed, status.failed);
}

fn tftpSessionListHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    var response: [8192]u8 = undefined;
    const body = try nodeforge.management_client.tftpSessionsJson(ctx.io, parsed_config.value.server.http_port, &response);
    if (body == null) {
        try ctx.writer.writeAll("error: tftp: local daemon session API unavailable\n");
        setExitCode(ctx, 1);
        return;
    }
    if (output_json) {
        try ctx.writer.writeAll(body.?);
        return;
    }
    const SessionResponse = struct { ok: bool, result: struct { sessions: []const struct { id: u64, phase: nodeforge.runtime_state.TftpSessionPhase, filename: []const u8 } } };
    var parsed = std.json.parseFromSlice(SessionResponse, ctx.allocator, body.?, .{ .allocate = .alloc_always }) catch |err| {
        try ctx.writer.print("error: tftp: malformed daemon response ({t})\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    defer parsed.deinit();
    var rows: [32]views.TftpSessionRow = undefined;
    if (parsed.value.result.sessions.len > rows.len) return error.TooManyTftpSessions;
    var ids: [32][20]u8 = undefined;
    for (parsed.value.result.sessions, 0..) |session, i| rows[i] = .{ .id = try std.fmt.bufPrint(&ids[i], "{d}", .{session.id}), .phase = @tagName(session.phase), .filename = session.filename };
    try views.tftpSessions(ctx.writer, rows[0..parsed.value.result.sessions.len]);
}

fn dhcpShowHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const dhcp = config.value.dhcp;
    if (output_json) {
        try ctx.writer.print("{{\"subnet\":{f},\"pool_start\":{f},\"pool_end\":{f},\"lease_seconds\":{d}}}\n", .{ std.json.fmt(dhcp.subnet, .{}), std.json.fmt(dhcp.pool_start, .{}), std.json.fmt(dhcp.pool_end, .{}), dhcp.lease_seconds });
    } else try views.dhcpConfig(ctx.writer, dhcp.subnet, dhcp.pool_start, dhcp.pool_end, dhcp.lease_seconds);
}

fn runtimeLeasesHandler(ctx: zli.CommandContext) !void {
    try runtimeLeaseList(ctx, false);
}

fn runtimeUnknownHandler(ctx: zli.CommandContext) !void {
    try runtimeLeaseList(ctx, true);
}

fn runtimeLeaseList(ctx: zli.CommandContext, unknown_only: bool) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var response: [64 * 1024]u8 = undefined;
    const body = try nodeforge.management_client.dhcpLeasesJson(ctx.io, config.value.server.http_port, unknown_only, &response);
    if (body == null) {
        try ctx.writer.writeAll("error: runtime: local daemon DHCP API unavailable\n");
        setExitCode(ctx, 1);
        return;
    }
    if (output_json) {
        try ctx.writer.writeAll(body.?);
        return;
    }
    const Response = struct { ok: bool, result: struct { leases: []const struct { phase: nodeforge.runtime_state.LeasePhase, known: bool, ip: []const u8, mac: []const u8, expires_at: i64 } } };
    var parsed = std.json.parseFromSlice(Response, ctx.allocator, body.?, .{ .allocate = .alloc_always }) catch |err| {
        try ctx.writer.print("error: runtime: malformed daemon response ({t})\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    defer parsed.deinit();
    var rows: [256]views.DhcpLeaseRow = undefined;
    var expiration: [256][24]u8 = undefined;
    if (parsed.value.result.leases.len > rows.len) return error.TooManyDhcpLeases;
    for (parsed.value.result.leases, 0..) |lease, i| rows[i] = .{ .ip = lease.ip, .mac = lease.mac, .phase = @tagName(lease.phase), .expires_at = try std.fmt.bufPrint(&expiration[i], "{d}", .{lease.expires_at}) };
    try views.dhcpLeases(ctx.writer, rows[0..parsed.value.result.leases.len], unknown_only);
}

fn nodeListHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    if (output_json) {
        try ctx.writer.writeAll("{\"nodes\":[");
        for (config.value.nodes, 0..) |item, i| {
            if (i != 0) try ctx.writer.writeByte(',');
            try ctx.writer.print("{{\"id\":{f},\"mac\":{f},\"ip\":", .{ std.json.fmt(item.id, .{}), std.json.fmt(item.mac, .{}) });
            if (item.ip) |ip| try ctx.writer.print("{f}", .{std.json.fmt(ip, .{})}) else try ctx.writer.writeAll("null");
            try ctx.writer.print(",\"profile\":{f}}}", .{std.json.fmt(item.profile, .{})});
        }
        try ctx.writer.writeAll("]}\n");
        return;
    }
    var rows: [256]views.NodeRow = undefined;
    if (config.value.nodes.len > rows.len) return error.TooManyNodes;
    for (config.value.nodes, 0..) |item, i| rows[i] = .{ .id = item.id, .mac = item.mac, .ip = item.ip orelse "-", .profile = item.profile };
    try views.nodes(ctx.writer, rows[0..config.value.nodes.len]);
}

/// Offline answer preview intentionally uses obvious non-secret placeholders.
/// Real credentials are only delivered by the authenticated `/answer` route.
fn installRenderHandler(ctx: zli.CommandContext) !void {
    _ = outputJsonFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var catalog = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer catalog.deinit();
    const node_id = ctx.getArg("node_id") orelse return;
    const node = nodeforge.catalog.findNode(&config.value, node_id) orelse {
        try ctx.writer.print("error: install: unknown node {s}\n", .{node_id});
        setExitCode(ctx, 1);
        return;
    };
    const profile = nodeforge.catalog.findProfile(&config.value, node.profile) orelse {
        try ctx.writer.writeAll("error: install: node profile unavailable\n");
        setExitCode(ctx, 1);
        return;
    };
    if (profile.mode != .install) {
        try ctx.writer.writeAll("error: install: node does not use an install profile\n");
        setExitCode(ctx, 1);
        return;
    }
    const source = nodeforge.catalog.findInstallSource(catalog.value(), profile.install_source orelse "") orelse {
        try ctx.writer.writeAll("error: install: install source unavailable\n");
        setExitCode(ctx, 1);
        return;
    };
    const install = profile.install orelse {
        try ctx.writer.writeAll("error: install: profile has no install plan\n");
        setExitCode(ctx, 1);
        return;
    };
    const system = nodeforge.profile_install.effectiveSystem(profile) catch {
        try ctx.writer.writeAll("error: install: legacy and system fields conflict\n");
        setExitCode(ctx, 1);
        return;
    };
    const config_revision = try nodeforge.deployment_control.revisionForConfig(ctx.allocator, &config.value);
    const plan_digest = try nodeforge.profile_install.planDigest(ctx.allocator, node, profile, source);
    const preview_scope = try nodeforge.password_hash.randomSalt(ctx.io);
    std.debug.print("password_hash_scope=preview config_revision={d} plan_digest={d} package_availability=installer-media\n", .{ config_revision, plan_digest });
    // APT 源 URL 解析：与 HTTP answerFixture 保持一致的 fallback 逻辑。
    // Ubuntu ISO 导入时始终创建 repository，但手动配置场景可能缺失。
    const apt_primary_url = if (std.mem.eql(u8, source.distro, "ubuntu")) blk: {
        const repository = nodeforge.catalog.findRepository(catalog.value(), source.name);
        if (repository) |repo| if (repo.manager == .apt) break :blk repo.base_url;
        break :blk try std.fmt.allocPrint(ctx.allocator, "http://{s}:{d}/repos/{s}", .{ config.value.server.server_ip, config.value.server.http_port, source.name });
    } else null;
    const event_url = try std.fmt.allocPrint(ctx.allocator, "http://{s}:{d}/api/v1/nodes/{s}/events", .{ config.value.server.server_ip, config.value.server.http_port, node.id });
    defer ctx.allocator.free(event_url);
    const bootstrap_key = try nodeforge.admin_key.resolve(ctx.io, ctx.allocator, config.value.server);
    defer ctx.allocator.free(bootstrap_key);
    const bundle = if (install.bundle) |name| findBundle(&config.value, name) else null;
    const answer = if (std.mem.eql(u8, source.distro, "ubuntu"))
        try nodeforge.ubuntu_autoinstall.renderUserDataM41(ctx.allocator, node, install, system, bootstrap_key, bundle, apt_primary_url, event_url, "<boot-session>", "<capability>", &preview_scope)
    else blk: {
        const install_root = try std.fmt.allocPrint(ctx.allocator, "http://{s}:{d}/repos/{s}", .{ config.value.server.server_ip, config.value.server.http_port, source.name });
        defer ctx.allocator.free(install_root);
        break :blk try nodeforge.kickstart.renderAnswerM41(ctx.allocator, node, install, system, bootstrap_key, install_root, bundle, event_url, "<boot-session>", "<capability>", &preview_scope);
    };
    defer ctx.allocator.free(answer);
    try ctx.writer.writeAll(answer);
}

fn installRetryHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const node_id = ctx.getArg("node_id") orelse return;
    const status = nodeforge.management_client.installRetry(ctx.io, config.value.server.http_port, node_id);
    if (output_json) try ctx.writer.print("{{\"ok\":{s},\"node_id\":{f}}}\n", .{ if (status.healthy) "true" else "false", std.json.fmt(node_id, .{}) }) else if (status.healthy) try ctx.writer.print("install generation rearmed for {s}; waiting for next PXE\n", .{node_id}) else try ctx.writer.print("error: install retry failed for {s}\n", .{node_id});
    if (!status.healthy) setExitCode(ctx, 1);
}

fn findBundle(config: *const nodeforge.model.AppConfig, name: []const u8) ?*const nodeforge.model.ProvisioningBundle {
    for (config.provisioning_bundles) |*bundle| if (std.mem.eql(u8, bundle.name, name)) return bundle;
    return null;
}

const EventFilters = cli_events.Filters;

fn eventsListHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const filters = eventFiltersFromContext(ctx, true) orelse return;
    var rows: [1000]nodeforge.events.ReadEvent = undefined;
    const result = cli_events.read(ctx.io, ctx.allocator, ctx.flag("events-path", []const u8), &filters, &rows) catch |err| {
        try ctx.writer.print("error: events: cannot read local history ({t})\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    if (result.skipped != 0) {
        var stderr_buffer: [128]u8 = undefined;
        var stderr = std.Io.File.Writer.init(.stderr(), ctx.io, &stderr_buffer);
        stderr.interface.print("warn: events: skipped {d} invalid record(s)\n", .{result.skipped}) catch {};
        stderr.interface.flush() catch {};
    }
    if (output_json) {
        try ctx.writer.writeByte('[');
        for (rows[0..result.count], 0..) |event, index| {
            if (index != 0) try ctx.writer.writeByte(',');
            try std.json.Stringify.value(event, .{}, ctx.writer);
        }
        try ctx.writer.writeAll("]\n");
        return;
    }
    var display: [1000]views.EventRow = undefined;
    for (rows[0..result.count], 0..) |event, index| display[index] = .{
        .ts = event.ts,
        .event_type = event.type,
        .node = cli_events.node(event) orelse "-",
        .message = event.message,
        .fields = try cli_events.fieldsText(ctx.allocator, event.fields),
    };
    try views.events(ctx.writer, display[0..result.count]);
}

/// `events follow` 命令的精简实现：只流式输出新追加的事件记录。
///
/// 轮询策略：
/// - 首次打开文件时记录当前大小作为起始 offset，跳过已有记录。
/// - 每次 EOF 时休眠 200ms 后重新打开文件路径。
/// - 重新打开而非持有旧 fd：当日志滚动时新记录写入新 inode，
///   旧 fd 会指向被删除的旧文件。重新打开路径始终跟踪当前活跃文件。
/// - 如果文件缩小（新 daemon 实例重新创建），重置 offset 到 0。
fn eventsFollowHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const filters = eventFiltersFromContext(ctx, false) orelse return;
    const path = ctx.flag("events-path", []const u8);
    var offset: u64 = blk: {
        var file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |err| {
            try ctx.writer.print("error: events: active file unavailable ({t})\n", .{err});
            setExitCode(ctx, 1);
            return;
        };
        defer file.close(ctx.io);
        break :blk (try file.stat(ctx.io)).size;
    };
    while (true) {
        var file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |err| {
            try ctx.writer.print("error: events: active file unavailable ({t})\n", .{err});
            setExitCode(ctx, 1);
            return;
        };
        defer file.close(ctx.io);
        const stat = try file.stat(ctx.io);
        if (stat.size < offset) offset = 0;
        if (stat.size == offset) {
            std.Io.sleep(ctx.io, .fromMilliseconds(200), .awake) catch {};
            continue;
        }
        const length: usize = @intCast(stat.size - offset);
        const bytes = try ctx.allocator.alloc(u8, length);
        defer ctx.allocator.free(bytes);
        _ = try file.readPositionalAll(ctx.io, bytes, offset);
        offset = stat.size;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var parsed = std.json.parseFromSlice(nodeforge.events.ReadEvent, ctx.allocator, line, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch continue;
            defer parsed.deinit();
            const event = parsed.value;
            if (!cli_events.matches(event, &filters)) continue;
            if (output_json) {
                try std.json.Stringify.value(event, .{}, ctx.writer);
                try ctx.writer.writeByte('\n');
            } else try views.eventLine(ctx.writer, event.ts, event.type, try cli_events.fieldsText(ctx.allocator, event.fields), event.message);
            try ctx.writer.flush();
        }
    }
}

const TraceGap = struct {
    kind: []const u8,
    start: []const u8,
    end: []const u8,
    summary: []const u8,
};

/// 从本地 events JSONL 重建一个 node 的最新或指定 boot session 时间线。
///
/// 结果只报告由 boot_session_id 直接证明的事件；关联容量耗尽、损坏事件和 daemon
/// 重启边界以 `gaps` 输出，避免 human 或 JSON 视图将不完整历史表述为完整事实。
fn traceHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const node_id = ctx.getArg("node_id") orelse return;
    const requested_session = ctx.flag("session", []const u8);
    const events_path = ctx.flag("events-path", []const u8);
    _ = ctx.flag("latest", bool);
    if (requested_session.len != 0 and !nodeforge.events.validCorrelationId(requested_session)) {
        try ctx.writer.writeAll("error: trace: --session must be 32 lowercase hexadecimal characters\n");
        setExitCode(ctx, 2);
        return;
    }

    var node_events: [cli_events.max_records]nodeforge.events.ReadEvent = undefined;
    const node_result = cli_events.read(ctx.io, ctx.allocator, events_path, &.{ .node = node_id, .limit = node_events.len }, &node_events) catch |err| {
        try ctx.writer.print("error: trace: cannot read local history ({t})\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    sortTraceEvents(node_events[0..node_result.count]);

    var selected_session: ?[]const u8 = if (requested_session.len != 0) requested_session else null;
    // 输入未指定 session 时，已排序的 node 事件中最后一个显式 session 就是
    // 保留历史可见的最新 session；`--latest` 保留为明确的 CLI 契约别名。
    if (selected_session == null) {
        for (node_events[0..node_result.count]) |event| {
            if (cli_events.session(event)) |value| selected_session = value;
        }
    }

    var trace_events: [cli_events.max_records]nodeforge.events.ReadEvent = undefined;
    var trace_count: usize = 0;
    var skipped = node_result.skipped;
    if (selected_session) |session| {
        const result = cli_events.read(ctx.io, ctx.allocator, events_path, &.{ .session = session, .limit = trace_events.len }, &trace_events) catch |err| {
            try ctx.writer.print("error: trace: cannot read session history ({t})\n", .{err});
            setExitCode(ctx, 1);
            return;
        };
        trace_count = result.count;
        skipped += result.skipped;
        sortTraceEvents(trace_events[0..trace_count]);
    }

    var gaps: [8]TraceGap = undefined;
    var gap_count: usize = 0;
    for (node_events[0..node_result.count]) |event| {
        const state = cli_events.field(event, "session_link_state") orelse continue;
        if (std.mem.eql(u8, state, "capacity_exhausted")) addTraceGap(&gaps, &gap_count, .{
            .kind = "capacity_exhausted",
            .start = event.ts,
            .end = event.ts,
            .summary = "DHCP continued without a trackable boot session because the active registry was full",
        });
    }
    if (skipped != 0) addTraceGap(&gaps, &gap_count, .{
        .kind = "event_corrupt",
        .start = "",
        .end = "",
        .summary = "one or more retained event records could not be parsed",
    });

    var phase: []const u8 = "unknown";
    var evidence: []const u8 = if (selected_session == null) "unable_to_determine" else "observed";
    var terminal_reason: ?[]const u8 = null;
    var last_timestamp: ?[]const u8 = null;
    var instance_id: ?[]const u8 = null;
    for (trace_events[0..trace_count]) |event| {
        phase = tracePhase(event) orelse phase;
        if (std.mem.startsWith(u8, event.type, "tftp.")) evidence = "unique_safe_association";
        if (std.mem.eql(u8, event.type, "boot.session.terminated")) terminal_reason = cli_events.field(event, "reason") orelse "unknown";
        last_timestamp = event.ts;
        if (instance_id == null) instance_id = cli_events.field(event, "daemon_instance_id");
    }

    if (selected_session != null and terminal_reason == null and last_timestamp != null) {
        var starts: [cli_events.max_records]nodeforge.events.ReadEvent = undefined;
        const start_result = cli_events.read(ctx.io, ctx.allocator, events_path, &.{ .event_type = "service.started", .limit = starts.len }, &starts) catch |err| {
            try ctx.writer.print("error: trace: cannot read service history ({t})\n", .{err});
            setExitCode(ctx, 1);
            return;
        };
        skipped += start_result.skipped;
        sortTraceEvents(starts[0..start_result.count]);
        for (starts[0..start_result.count]) |event| {
            if (compareTraceTime(event.ts, last_timestamp.?) == .lt) continue;
            const started_instance = cli_events.field(event, "daemon_instance_id") orelse continue;
            if (instance_id == null or !std.mem.eql(u8, started_instance, instance_id.?)) {
                addTraceGap(&gaps, &gap_count, .{
                    .kind = "daemon_restart_gap",
                    .start = last_timestamp.?,
                    .end = event.ts,
                    .summary = "a new daemon instance started after this non-terminal session was last observed",
                });
                break;
            }
        }
    }

    if (output_json) {
        try ctx.writer.writeAll("{\"node_id\":");
        try ctx.writer.print("{f}", .{std.json.fmt(node_id, .{})});
        try ctx.writer.writeAll(",\"boot_session_id\":");
        if (selected_session) |session| try ctx.writer.print("{f}", .{std.json.fmt(session, .{})}) else try ctx.writer.writeAll("null");
        try ctx.writer.writeAll(",\"status\":{\"phase\":");
        try ctx.writer.print("{f}", .{std.json.fmt(phase, .{})});
        try ctx.writer.writeAll(",\"terminal_reason\":");
        if (terminal_reason) |reason| try ctx.writer.print("{f}", .{std.json.fmt(reason, .{})}) else try ctx.writer.writeAll("null");
        try ctx.writer.writeAll(",\"evidence\":");
        try ctx.writer.print("{f}", .{std.json.fmt(evidence, .{})});
        try ctx.writer.writeAll("},\"events\":[");
        for (trace_events[0..trace_count], 0..) |event, index| {
            if (index != 0) try ctx.writer.writeByte(',');
            try std.json.Stringify.value(event, .{}, ctx.writer);
        }
        try ctx.writer.writeAll("],\"gaps\":[");
        for (gaps[0..gap_count], 0..) |gap, index| {
            if (index != 0) try ctx.writer.writeByte(',');
            try ctx.writer.writeAll("{\"kind\":");
            try ctx.writer.print("{f}", .{std.json.fmt(gap.kind, .{})});
            try ctx.writer.writeAll(",\"start\":");
            try ctx.writer.print("{f}", .{std.json.fmt(gap.start, .{})});
            try ctx.writer.writeAll(",\"end\":");
            try ctx.writer.print("{f}", .{std.json.fmt(gap.end, .{})});
            try ctx.writer.writeAll(",\"summary\":");
            try ctx.writer.print("{f}", .{std.json.fmt(gap.summary, .{})});
            try ctx.writer.writeByte('}');
        }
        try ctx.writer.writeAll("]}\n");
        return;
    }

    try ctx.writer.writeAll("Trace\n");
    try ctx.writer.print("  Node         {s}\n", .{node_id});
    try ctx.writer.print("  Session      {s}\n", .{selected_session orelse "-"});
    try ctx.writer.print("  Phase        {s}\n", .{phase});
    try ctx.writer.print("  Evidence     {s}\n", .{evidence});
    if (terminal_reason) |reason| try ctx.writer.print("  Terminal     {s}\n", .{reason});
    if (trace_count == 0) try ctx.writer.writeAll("No safely associated events recorded.\n") else {
        try ctx.writer.writeAll("Events\n");
        for (trace_events[0..trace_count]) |event| try views.eventLine(ctx.writer, event.ts, event.type, try cli_events.fieldsText(ctx.allocator, event.fields), event.message);
    }
    if (gap_count != 0) {
        try ctx.writer.writeAll("Gaps\n");
        for (gaps[0..gap_count]) |gap| try ctx.writer.print("  {s}  {s} {s}  {s}\n", .{ gap.kind, gap.start, gap.end, gap.summary });
    }
}

/// 有界地收集诊断缺口；溢出不改变 trace 的已证明事件集合。
fn addTraceGap(gaps: *[8]TraceGap, count: *usize, gap: TraceGap) void {
    if (count.* == gaps.len) return;
    gaps[count.*] = gap;
    count.* += 1;
}

/// 优先采用终态事件携带的 phase；否则从 M2.5.1 已定义的协议事件推导展示值。
fn tracePhase(event: nodeforge.events.ReadEvent) ?[]const u8 {
    if (cli_events.field(event, "phase")) |phase| return phase;
    return if (std.mem.eql(u8, event.type, "dhcp.discover")) "dhcp_discover" else if (std.mem.eql(u8, event.type, "dhcp.offer")) "dhcp_offer" else if (std.mem.eql(u8, event.type, "dhcp.ack")) "dhcp_ack" else if (std.mem.eql(u8, event.type, "tftp.rrq")) "tftp_rrq" else if (std.mem.eql(u8, event.type, "tftp.transfer.complete")) "tftp_complete" else if (std.mem.eql(u8, event.type, "tftp.transfer.error")) "failed" else null;
}

fn sortTraceEvents(values: []nodeforge.events.ReadEvent) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        var insert = index;
        while (insert > 0 and compareTraceTime(value.ts, values[insert - 1].ts) == .lt) : (insert -= 1) values[insert] = values[insert - 1];
        values[insert] = value;
    }
}

fn compareTraceTime(left: []const u8, right: []const u8) std.math.Order {
    const left_time = cli_events.parseTime(left) catch return .eq;
    const right_time = cli_events.parseTime(right) catch return .eq;
    return std.math.order(left_time, right_time);
}

fn eventsTypesHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    if (output_json) {
        try ctx.writer.writeByte('[');
        for (nodeforge.event_types.definitions, 0..) |definition, index| {
            if (index != 0) try ctx.writer.writeByte(',');
            try ctx.writer.print("{{\"name\":{f},\"description\":{f},\"default_level\":{f}}}", .{ std.json.fmt(definition.name, .{}), std.json.fmt(definition.description, .{}), std.json.fmt(@tagName(definition.default_level), .{}) });
        }
        try ctx.writer.writeAll("]\n");
        return;
    }
    var rows: [nodeforge.event_types.definitions.len]views.EventTypeRow = undefined;
    for (nodeforge.event_types.definitions, 0..) |definition, index| rows[index] = .{ .name = definition.name, .description = definition.description, .level = @tagName(definition.default_level) };
    try views.eventTypes(ctx.writer, &rows);
}

fn addEventsFilterFlags(command: *zli.Command, comptime include_limit: bool) !void {
    try command.addFlags(&.{
        .{ .name = "type", .description = "Registered event type", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "node", .description = "Filter by node_id", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "session", .description = "Filter by boot_session_id", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "since", .description = "Inclusive RFC 3339 UTC or unix:<seconds> bound", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "until", .description = "Inclusive RFC 3339 UTC or unix:<seconds> bound", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "events-path", .description = "Local Event JSONL path (development or recovery override)", .type = .String, .default_value = .{ .String = nodeforge.paths.events_path } },
    });
    if (include_limit) try command.addFlag(.{ .name = "limit", .description = "Latest matching records (1-1000)", .type = .Int, .default_value = .{ .Int = 100 } });
    try addOutputFlag(command);
}

fn eventFiltersFromContext(ctx: zli.CommandContext, comptime has_limit: bool) ?EventFilters {
    const event_type = ctx.flag("type", []const u8);
    if (event_type.len != 0 and nodeforge.event_types.fromName(event_type) == null) {
        ctx.writer.print("error: events: unknown event type '{s}'\n", .{event_type}) catch {};
        setExitCode(ctx, 2);
        return null;
    }
    const since_text = ctx.flag("since", []const u8);
    const until_text = ctx.flag("until", []const u8);
    const since = if (since_text.len == 0) null else cli_events.parseTime(since_text) catch {
        ctx.writer.print("error: events: invalid --since timestamp\n", .{}) catch {};
        setExitCode(ctx, 2);
        return null;
    };
    const until = if (until_text.len == 0) null else cli_events.parseTime(until_text) catch {
        ctx.writer.print("error: events: invalid --until timestamp\n", .{}) catch {};
        setExitCode(ctx, 2);
        return null;
    };
    const limit: usize = if (has_limit) @intCast(ctx.flag("limit", i32)) else 1000;
    if (limit == 0 or limit > 1000) {
        ctx.writer.print("error: events: --limit must be 1..1000\n", .{}) catch {};
        setExitCode(ctx, 2);
        return null;
    }
    const session = ctx.flag("session", []const u8);
    if (session.len != 0 and !nodeforge.events.validCorrelationId(session)) {
        ctx.writer.print("error: events: --session must be 32 lowercase hexadecimal characters\n", .{}) catch {};
        setExitCode(ctx, 2);
        return null;
    }
    return .{ .event_type = event_type, .node = ctx.flag("node", []const u8), .session = session, .since = since, .until = until, .limit = limit };
}

/// 读取当前命令的输出格式并校验其值。
/// 返回 null 表示已输出可读错误并把退出码设为用法错误 2。
fn outputJsonFromContext(ctx: zli.CommandContext) ?bool {
    const output = outputFromContext(ctx) orelse return null;
    return output.mode == .json;
}

/// 将命令局部展示 flags 收敛为 M1.5 的 `Output` 值。后续有状态色、终端宽度或
/// pager 时只能扩展此入口，业务 handler 不得自行读取 `--no-color`。
fn outputFromContext(ctx: zli.CommandContext) ?cli_output.Output {
    const output = ctx.flag("output", []const u8);
    const mode: cli_output.Mode = if (std.mem.eql(u8, output, "json")) .json else if (std.mem.eql(u8, output, "human")) .human else {
        ctx.writer.print("error: output: unsupported format '{s}' (expected human or json)\n", .{output}) catch {};
        setExitCode(ctx, 2);
        return null;
    };
    return .{ .mode = mode, .no_color = !ctx.flag("color", bool) };
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
    try command.addFlag(.{
        .name = "color",
        .description = "Reserved for future ANSI color support; M1.5 outputs without color regardless",
        .type = .Bool,
        .default_value = .{ .Bool = true },
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
/// 所有 M0 探针固定连接本机 127.0.0.1；`server_ip` 只用于显示对 PXE 节点广告的地址。
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
    const health = nodeforge.management_client.health(io, parsed_config.value.server.http_port);
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
            try views.success(out, "nodeforge checks passed", &.{});
        } else {
            try views.checkFailure(out, status.reachable, health.healthy, status.healthy, active_config.healthy);
        }
        return if (ok) 0 else 1;
    }

    try views.status(out, status.reachable, health.healthy, status.healthy, active_config.healthy, parsed_config.value.server.server_ip, parsed_config.value.server.http_port);
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

/// 输出稳定的 CLI 名称与项目版本。
fn printVersion(out: *std.Io.Writer) !void {
    try out.print("nodeforge {s}\n", .{nodeforge.version.version});
}
