//! `nodeforge` M0 管理命令行入口。
//! zli 持有唯一命令树并据此完成解析、校验和帮助生成；业务语义仍委托核心库。
//! 退出码约定：0 表示成功，1 表示业务检查或运行失败，2 表示命令行用法错误。

const std = @import("std");
const zli = @import("zli");
const nodeforge = @import("nodeforge");
const views = @import("nodeforge").cli_views;
const cli_output = @import("nodeforge").cli_output;

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

    const asset = try zli.Command.init(init_options, .{
        .name = "asset",
        .description = "Inspect and register TFTP boot assets",
        .usage = "nodeforge asset <command> [options]",
        .help = "M1 asset paths are relative to config.tftp.asset_root and are integrity checked before catalog registration.",
    }, showCurrentHelp);
    try asset.addCommands(&.{ try assetImportCommand(init_options), try assetListCommand(init_options), try assetShowCommand(init_options), try assetValidateCommand(init_options) });

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

    try root.addCommands(&.{
        status,
        check,
        config,
        catalog,
        tftp,
        dhcp,
        runtime,
        node,
        asset,
        events,
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

/// Imports an existing root-confined file, computes its digest, validates the
/// candidate catalog and atomically publishes the new manifest.  This offline
/// path is also useful during initial provisioning before nodeforged exists.
fn assetImportHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, debug) orelse { setExitCode(ctx, 1); return; };
    defer parsed_config.deinit();
    const kind = std.meta.stringToEnum(nodeforge.model.AssetKind, ctx.flag("type", []const u8)) orelse { try ctx.writer.writeAll("error: asset: unsupported --type\n"); setExitCode(ctx, 2); return; };
    const name = ctx.flag("name", []const u8);
    const path = ctx.flag("path", []const u8);
    if (name.len == 0 or path.len == 0) { try ctx.writer.writeAll("error: asset: --name and --path are required\n"); setExitCode(ctx, 2); return; }
    const distro_value = ctx.flag("distro", []const u8);
    const version_value = ctx.flag("version", []const u8);
    const arch_value = ctx.flag("arch", []const u8);
    const has_tuple = distro_value.len != 0 or version_value.len != 0 or arch_value.len != 0;
    if (has_tuple and (distro_value.len == 0 or version_value.len == 0 or arch_value.len == 0)) { try ctx.writer.writeAll("error: asset: --distro, --version and --arch must be used together\n"); setExitCode(ctx, 2); return; }
    const arch = if (has_tuple) std.meta.stringToEnum(nodeforge.model.Arch, arch_value) orelse { try ctx.writer.writeAll("error: asset: unsupported --arch\n"); setExitCode(ctx, 2); return; } else null;
    const imported = nodeforge.management_client.importAsset(ctx.io, parsed_config.value.server.http_port, .{
        .name = name, .kind = @tagName(kind), .path = path,
        .distro = if (has_tuple) distro_value else null, .version = if (has_tuple) version_value else null,
        .arch = if (arch) |value| @tagName(value) else null,
        .kernel_release = if (ctx.flag("kernel-release", []const u8).len == 0) null else ctx.flag("kernel-release", []const u8),
    }) catch |err| { try ctx.writer.print("error: asset: import request failed\n", .{}); if (debug) try ctx.writer.print("debug: asset: cause={t}\n", .{err}); setExitCode(ctx, 1); return; };
    if (!imported) { try ctx.writer.writeAll("error: asset: daemon rejected import\n"); setExitCode(ctx, 1); return; }
    if (output_json) try ctx.writer.print("{{\"ok\":true,\"name\":\"{s}\"}}\n", .{name}) else try views.success(ctx.writer, "asset imported", &.{.{ .label = "Name", .value = name }});
}

fn assetListHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse { setExitCode(ctx, 1); return; };
    defer loaded.deinit();
    if (output_json) {
        try ctx.writer.writeAll("{\"assets\":[");
        for (loaded.value().assets, 0..) |item, i| { if (i != 0) try ctx.writer.writeByte(','); try ctx.writer.print("{{\"name\":\"{s}\",\"kind\":\"{t}\",\"path\":\"{s}\"}}", .{ item.name, item.kind, item.path }); }
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
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse { setExitCode(ctx, 1); return; };
    defer loaded.deinit();
    const name = ctx.getArg("name") orelse unreachable;
    for (loaded.value().assets) |item| if (std.mem.eql(u8, item.name, name)) { if (output_json) try ctx.writer.print("{{\"name\":\"{s}\",\"kind\":\"{t}\",\"path\":\"{s}\",\"sha256\":{f}}}\n", .{ item.name, item.kind, item.path, std.json.fmt(item.sha256, .{}) }) else try views.assetDetail(ctx.writer, item.name, @tagName(item.kind), item.path, item.sha256 orelse ""); return; };
    try ctx.writer.print("error: asset: not found: {s}\n", .{name}); setExitCode(ctx, 1);
}

fn assetValidateHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse { setExitCode(ctx, 1); return; };
    defer parsed_config.deinit();
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse { setExitCode(ctx, 1); return; };
    defer loaded.deinit();
    for (loaded.value().assets) |item| { var digest: [64]u8 = undefined; nodeforge.asset_validate.sha256File(ctx.io, parsed_config.value.tftp.asset_root, item.path, &digest) catch { try ctx.writer.print("error: asset: unreadable: {s}\n", .{item.path}); setExitCode(ctx, 1); return; }; if (item.sha256 == null or !std.mem.eql(u8, item.sha256.?, &digest)) { try ctx.writer.print("error: asset: checksum mismatch: {s}\n", .{item.name}); setExitCode(ctx, 1); return; } }
    if (output_json) try ctx.writer.writeAll("{\"ok\":true}\n") else {
        var count: [20]u8 = undefined;
        try views.success(ctx.writer, "assets valid", &.{.{ .label = "Assets", .value = try std.fmt.bufPrint(&count, "{d}", .{loaded.value().assets.len}) }});
    }
}

fn tftpShowHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse { setExitCode(ctx, 1); return; };
    defer parsed_config.deinit();
    const status = nodeforge.management_client.tftpCounters(ctx.io, parsed_config.value.server.http_port);
    if (!status.healthy) { try ctx.writer.writeAll("error: tftp: local daemon status unavailable\n"); setExitCode(ctx, 1); return; }
    if (output_json) try ctx.writer.print("{{\"started\":{d},\"completed\":{d},\"failed\":{d}}}\n", .{ status.started, status.completed, status.failed }) else try views.tftpCounters(ctx.writer, status.started, status.completed, status.failed);
}

fn tftpSessionListHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse { setExitCode(ctx, 1); return; };
    defer parsed_config.deinit();
    var response: [8192]u8 = undefined;
    const body = try nodeforge.management_client.tftpSessionsJson(ctx.io, parsed_config.value.server.http_port, &response);
    if (body == null) {
        try ctx.writer.writeAll("error: tftp: local daemon session API unavailable\n");
        setExitCode(ctx, 1);
        return;
    }
    if (output_json) { try ctx.writer.writeAll(body.?); return; }
    const SessionResponse = struct { ok: bool, result: struct { sessions: []const struct { id: u64, phase: nodeforge.runtime_state.TftpSessionPhase, filename: []const u8 } } };
    var parsed = std.json.parseFromSlice(SessionResponse, ctx.allocator, body.?, .{ .allocate = .alloc_always }) catch |err| { try ctx.writer.print("error: tftp: malformed daemon response ({t})\n", .{err}); setExitCode(ctx, 1); return; };
    defer parsed.deinit();
    var rows: [32]views.TftpSessionRow = undefined;
    if (parsed.value.result.sessions.len > rows.len) return error.TooManyTftpSessions;
    var ids: [32][20]u8 = undefined;
    for (parsed.value.result.sessions, 0..) |session, i| rows[i] = .{ .id = try std.fmt.bufPrint(&ids[i], "{d}", .{session.id}), .phase = @tagName(session.phase), .filename = session.filename };
    try views.tftpSessions(ctx.writer, rows[0..parsed.value.result.sessions.len]);
}

fn dhcpShowHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse { setExitCode(ctx, 1); return; };
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
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse { setExitCode(ctx, 1); return; };
    defer config.deinit();
    var response: [64 * 1024]u8 = undefined;
    const body = try nodeforge.management_client.dhcpLeasesJson(ctx.io, config.value.server.http_port, unknown_only, &response);
    if (body == null) {
        try ctx.writer.writeAll("error: runtime: local daemon DHCP API unavailable\n");
        setExitCode(ctx, 1);
        return;
    }
    if (output_json) { try ctx.writer.writeAll(body.?); return; }
    const Response = struct { ok: bool, result: struct { leases: []const struct { phase: nodeforge.runtime_state.LeasePhase, known: bool, ip: []const u8, mac: []const u8, expires_at: i64 } } };
    var parsed = std.json.parseFromSlice(Response, ctx.allocator, body.?, .{ .allocate = .alloc_always }) catch |err| { try ctx.writer.print("error: runtime: malformed daemon response ({t})\n", .{err}); setExitCode(ctx, 1); return; };
    defer parsed.deinit();
    var rows: [256]views.DhcpLeaseRow = undefined;
    var expiration: [256][24]u8 = undefined;
    if (parsed.value.result.leases.len > rows.len) return error.TooManyDhcpLeases;
    for (parsed.value.result.leases, 0..) |lease, i| rows[i] = .{ .ip = lease.ip, .mac = lease.mac, .phase = @tagName(lease.phase), .expires_at = try std.fmt.bufPrint(&expiration[i], "{d}", .{lease.expires_at}) };
    try views.dhcpLeases(ctx.writer, rows[0..parsed.value.result.leases.len], unknown_only);
}

fn nodeListHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse { setExitCode(ctx, 1); return; };
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

const EventFilters = struct {
    event_type: []const u8,
    node: []const u8,
    since: ?i64,
    until: ?i64,
    limit: usize,
};

fn eventsListHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const filters = eventFiltersFromContext(ctx, true) orelse return;
    var rows: [1000]nodeforge.events.ReadEvent = undefined;
    const result = readEvents(ctx.io, ctx.allocator, &filters, &rows) catch |err| {
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
        .event_type = event.@"type",
        .node = eventNode(event) orelse "-",
        .message = event.message,
        .fields = try eventFields(ctx.allocator, event.fields),
    };
    try views.events(ctx.writer, display[0..result.count]);
}

/// A deliberately small follow implementation: it streams only newly appended
/// records. On EOF it waits briefly, then reopens the path so rotations follow
/// the new active inode without retaining an invalid descriptor.
fn eventsFollowHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const filters = eventFiltersFromContext(ctx, false) orelse return;
    const path = nodeforge.paths.events_path;
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
            if (!eventMatches(event, &filters)) continue;
            if (output_json) {
                try std.json.Stringify.value(event, .{}, ctx.writer);
                try ctx.writer.writeByte('\n');
            } else try views.eventLine(ctx.writer, event.ts, event.@"type", try eventFields(ctx.allocator, event.fields), event.message);
            try ctx.writer.flush();
        }
    }
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
        .{ .name = "since", .description = "Inclusive RFC 3339 UTC or unix:<seconds> bound", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "until", .description = "Inclusive RFC 3339 UTC or unix:<seconds> bound", .type = .String, .default_value = .{ .String = "" } },
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
    const since = if (since_text.len == 0) null else parseEventTime(since_text) catch {
        ctx.writer.print("error: events: invalid --since timestamp\n", .{}) catch {};
        setExitCode(ctx, 2);
        return null;
    };
    const until = if (until_text.len == 0) null else parseEventTime(until_text) catch {
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
    return .{ .event_type = event_type, .node = ctx.flag("node", []const u8), .since = since, .until = until, .limit = limit };
}

const ReadResult = struct { count: usize, skipped: usize };

fn readEvents(io: std.Io, allocator: std.mem.Allocator, filters: *const EventFilters, rows: []nodeforge.events.ReadEvent) !ReadResult {
    var count: usize = 0;
    var skipped: usize = 0;
    var rotation: u8 = 20;
    while (rotation > 0) : (rotation -= 1) {
        const path = try std.fmt.allocPrint(allocator, "{s}.{d}", .{ nodeforge.paths.events_path, rotation });
        defer allocator.free(path);
        readEventFile(io, allocator, path, filters, rows, &count, &skipped) catch |err| if (err != error.FileNotFound) return err;
    }
    readEventFile(io, allocator, nodeforge.paths.events_path, filters, rows, &count, &skipped) catch |err| if (err != error.FileNotFound) return err;
    if (count > filters.limit) {
        const start = count - filters.limit;
        std.mem.copyForwards(nodeforge.events.ReadEvent, rows[0..filters.limit], rows[start..count]);
        count = filters.limit;
    }
    return .{ .count = count, .skipped = skipped };
}

fn readEventFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, filters: *const EventFilters, rows: []nodeforge.events.ReadEvent, count: *usize, skipped: *usize) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(100 * 1024 * 1024));
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const event = std.json.parseFromSliceLeaky(nodeforge.events.ReadEvent, allocator, line, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            skipped.* += 1;
            continue;
        };
        if (!eventMatches(event, filters)) continue;
        if (count.* == rows.len) return error.TooManyEvents;
        rows[count.*] = event;
        count.* += 1;
    }
}

fn eventMatches(event: nodeforge.events.ReadEvent, filters: *const EventFilters) bool {
    if (filters.event_type.len != 0 and !std.mem.eql(u8, event.@"type", filters.event_type)) return false;
    if (filters.node.len != 0 and !(if (eventNode(event)) |node| std.mem.eql(u8, node, filters.node) else false)) return false;
    const stamp = parseEventTime(event.ts) catch return false;
    if (filters.since) |since| if (stamp < since) return false;
    if (filters.until) |until| if (stamp > until) return false;
    return true;
}

fn eventNode(event: nodeforge.events.ReadEvent) ?[]const u8 {
    if (event.node) |node| return node;
    for (event.fields) |field| if (std.mem.eql(u8, field.key, "node_id")) return field.value;
    return null;
}

fn eventFields(allocator: std.mem.Allocator, fields: []const nodeforge.events.Field) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    for (fields, 0..) |field, index| {
        if (index != 0) try output.writer.writeByte(' ');
        try output.writer.print("{s}={s}", .{ field.key, field.value });
    }
    return output.toOwnedSlice();
}

fn parseEventTime(value: []const u8) !i64 {
    if (std.mem.startsWith(u8, value, nodeforge.events.unix_timestamp_prefix)) return std.fmt.parseInt(i64, value[nodeforge.events.unix_timestamp_prefix.len..], 10);
    if (value.len != 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':' or value[19] != 'Z') return error.InvalidTimestamp;
    const year = try std.fmt.parseInt(u16, value[0..4], 10);
    const month = try std.fmt.parseInt(u8, value[5..7], 10);
    const day = try std.fmt.parseInt(u8, value[8..10], 10);
    const hour = try std.fmt.parseInt(u8, value[11..13], 10);
    const minute = try std.fmt.parseInt(u8, value[14..16], 10);
    const second = try std.fmt.parseInt(u8, value[17..19], 10);
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;
    var days: i64 = 0;
    var current: u16 = 1970;
    while (current < year) : (current += 1) days += if (std.time.epoch.isLeapYear(current)) 366 else 365;
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    for (month_days[0..month - 1], 0..) |count, index| days += @as(i64, count) + if (index == 1 and std.time.epoch.isLeapYear(year)) @as(i64, 1) else @as(i64, 0);
    const maximum_day: u8 = month_days[month - 1] + if (month == 2 and std.time.epoch.isLeapYear(year)) @as(u8, 1) else @as(u8, 0);
    if (day > maximum_day) return error.InvalidTimestamp;
    return days * 86400 + @as(i64, day - 1) * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
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
