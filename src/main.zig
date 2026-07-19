//! `nodeforge` M0 管理命令行入口。
//! zli 持有唯一命令树并据此完成解析、校验和帮助生成；业务语义仍委托核心库。
//! 退出码约定：0 表示成功，1 表示业务检查或运行失败，2 表示命令行用法错误。

const std = @import("std");
const zli = @import("zli");
const nodeforge = @import("nodeforge");
const views = @import("nodeforge").cli_views;
const cli_output = @import("nodeforge").cli_output;
const cli_events = @import("nodeforge").cli_events;
const model = @import("nodeforge").model;
const node_mutation = @import("nodeforge").node_mutation;

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

    nodeforge.paths.bootstrap(init.io, init.arena.allocator(), init.minimal.args) catch |err| {
        try out.print("error: install root bootstrap failed: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };

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
        .{
            .name = "install-root",
            .description = "Explicit marked NodeForge install root (must precede the command)",
            .type = .String,
            .default_value = .{ .String = "" },
        },
    });

    const status = try zli.Command.init(init_options, .{
        .name = "status",
        .description = "Verify that nodeforged is operational",
        .help = "Run the canonical end-to-end daemon readiness checks: loopback management, active config, advertised HTTP, catalog, DHCP, and TFTP.",
    }, statusHandler);
    try addConfigPathFlag(status);
    try addOutputFlag(status);
    try addDebugFlag(status);

    const config = try zli.Command.init(init_options, .{
        .name = "config",
        .description = "Validate or export startup configuration",
        .usage = "nodeforge config <command> [options]",
        .help = "Inspect startup configuration files. Import and reconfiguration are owned by nodeforge setup.",
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
    const catalog_show = try zli.Command.init(init_options, .{
        .name = "show",
        .description = "Show expanded install-source relationships",
    }, catalogShowHandler);
    try catalog_show.addPositionalArg(.{ .name = "install-source", .description = "Canonical install source name", .required = true });
    try addConfigPathFlag(catalog_show);
    try addOutputFlag(catalog_show);
    try addDebugFlag(catalog_show);
    const catalog_migrate = try zli.Command.init(init_options, .{ .name = "migrate", .description = "Plan or apply canonical catalog migration" }, catalogMigrateHandler);
    try catalog_migrate.addFlags(&.{
        .{ .name = "dry-run", .description = "Generate a side-effect-free migration plan", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "apply", .description = "Apply a previously generated plan", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "plan-digest", .description = "SHA-256 digest returned by --dry-run", .type = .String, .default_value = .{ .String = "" } },
    });
    try addConfigPathFlag(catalog_migrate);
    try addOutputFlag(catalog_migrate);
    try addDebugFlag(catalog_migrate);
    try catalog.addCommands(&.{
        catalog_validate,
        catalog_export,
        catalog_show,
        catalog_migrate,
    });

    // ── node 资源（节点 CRUD + 部署生命周期）──────────────────────────
    const node = try zli.Command.init(init_options, .{
        .name = "node",
        .description = "Manage registered nodes and deployment lifecycle",
        .usage = "nodeforge node <list|show|add|set|remove|render|retry|trace> [options]",
    }, showCurrentHelp);

    const node_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List registered nodes" }, nodeListHandler);
    try addConfigPathFlag(node_list);
    try addOutputFlag(node_list);
    try addDebugFlag(node_list);

    const node_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show node detail (attributes + deploy state)" }, nodeShowHandler);
    try node_show.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try addConfigPathFlag(node_show);
    try addOutputFlag(node_show);
    try addDebugFlag(node_show);

    const node_add = try zli.Command.init(init_options, .{ .name = "add", .description = "Add a registered node" }, nodeAddHandler);
    try node_add.addPositionalArg(.{ .name = "node_id", .description = "Unique node identifier", .required = true });
    try node_add.addPositionalArg(.{ .name = "properties", .description = "Typed properties as key=value", .required = true, .variadic = true });
    try addConfigPathFlag(node_add);
    try addOutputFlag(node_add);
    try addDebugFlag(node_add);

    const node_set = try zli.Command.init(init_options, .{
        .name = "set",
        .description = "Modify stored node properties",
        .usage = "nodeforge node set <node_id> <key=value>... [options]",
        .help = "Keys: mac, arch, profile, ip, hostname, deploy, http_accel. Booleans use true|false. Example: nodeforge node set r97n1 hostname=r97n1 deploy=true",
    }, nodeSetHandler);
    try node_set.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try node_set.addPositionalArg(.{ .name = "properties", .description = "Typed properties as key=value", .required = true, .variadic = true });
    try addConfigPathFlag(node_set);
    try addOutputFlag(node_set);
    try addDebugFlag(node_set);

    const node_unset = try zli.Command.init(init_options, .{
        .name = "unset",
        .description = "Clear optional stored node properties",
        .usage = "nodeforge node unset <node_id> <key>... [options]",
        .help = "Keys: ip, hostname. Example: nodeforge node unset r97n1 ip hostname",
    }, nodeUnsetHandler);
    try node_unset.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try node_unset.addPositionalArg(.{ .name = "keys", .description = "Optional property names to clear", .required = true, .variadic = true });
    try addConfigPathFlag(node_unset);
    try addOutputFlag(node_unset);
    try addDebugFlag(node_unset);

    const node_remove = try zli.Command.init(init_options, .{ .name = "remove", .description = "Remove a registered node" }, nodeRemoveHandler);
    try node_remove.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try addConfigPathFlag(node_remove);
    try addOutputFlag(node_remove);
    try addDebugFlag(node_remove);

    const node_render = try zli.Command.init(init_options, .{ .name = "render", .description = "Render the unattended install answer for one node" }, installRenderHandler);
    try node_render.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try addConfigPathFlag(node_render);
    try addCatalogPathFlag(node_render);
    try addOutputFlag(node_render);
    try addDebugFlag(node_render);

    const node_retry = try zli.Command.init(init_options, .{ .name = "retry", .description = "Rearm the next PXE install generation" }, installRetryHandler);
    try node_retry.addPositionalArg(.{ .name = "node_id", .description = "Registered install node", .required = true });
    try node_retry.addFlag(.{ .name = "force", .description = "Supersede a stuck active session before rearming", .type = .Bool, .default_value = .{ .Bool = false } });
    try addConfigPathFlag(node_retry);
    try addOutputFlag(node_retry);
    try addDebugFlag(node_retry);

    const node_trace = try zli.Command.init(init_options, .{
        .name = "trace",
        .description = "Reconstruct one node boot-session timeline from local events",
        .usage = "nodeforge node trace <node_id> [--session <id>] [--latest] [options]",
    }, traceHandler);
    try node_trace.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try node_trace.addFlags(&.{
        .{ .name = "session", .description = "Exact 32-character boot session identifier", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "latest", .description = "Select the latest retained session (default when --session is omitted)", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "events-path", .description = "Local Event JSONL path (development or recovery override)", .type = .String, .default_value = .{ .String = nodeforge.paths.require().events_path } },
    });
    try addOutputFlag(node_trace);

    try node.addCommands(&.{ node_list, node_show, node_add, node_set, node_unset, node_remove, node_render, node_retry, node_trace });

    const profile = try zli.Command.init(init_options, .{ .name = "profile", .description = "Create and inspect PXE profiles" }, showCurrentHelp);
    const profile_create = try zli.Command.init(init_options, .{
        .name = "create",
        .description = "Create an install profile from an imported install source",
        .usage = "nodeforge profile create <name> <install-source> [options]",
        .help = "Derives distro, version, and architecture from the imported source. The profile is destructive, persistent, and explicit-retry by construction.",
    }, profileCreateHandler);
    try profile_create.addPositionalArg(.{ .name = "name", .description = "Canonical profile name", .required = true });
    try profile_create.addPositionalArg(.{ .name = "install-source", .description = "Imported install source name", .required = true });
    try addConfigPathFlag(profile_create);
    try addOutputFlag(profile_create);
    try addDebugFlag(profile_create);
    const profile_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List PXE profiles" }, profileListHandler);
    try addConfigPathFlag(profile_list);
    try addOutputFlag(profile_list);
    try addDebugFlag(profile_list);
    const profile_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show a PXE profile" }, profileShowHandler);
    try profile_show.addPositionalArg(.{ .name = "name", .description = "Profile name", .required = true });
    try addConfigPathFlag(profile_show);
    try addOutputFlag(profile_show);
    try addDebugFlag(profile_show);
    const profile_set = try zli.Command.init(init_options, .{
        .name = "set",
        .description = "Modify stored profile properties",
        .usage = "nodeforge profile set <name> <key=value> [options]",
        .help = "Keys: kernel_args, boot_disk. Quote kernel_args when it contains spaces. Examples: nodeforge profile set rocky boot_disk=/dev/nvme0n1; nodeforge profile set rocky 'kernel_args=iommu=pt hugepages=4'",
    }, profileSetHandler);
    try profile_set.addPositionalArg(.{ .name = "name", .description = "Profile name", .required = true });
    try profile_set.addPositionalArg(.{ .name = "property", .description = "kernel_args=<arguments> or boot_disk=/dev/<device>", .required = true });
    try addConfigPathFlag(profile_set);
    try addOutputFlag(profile_set);
    try addDebugFlag(profile_set);
    const profile_unset = try zli.Command.init(init_options, .{
        .name = "unset",
        .description = "Clear an optional stored profile property",
        .usage = "nodeforge profile unset <name> kernel_args [options]",
        .help = "Key: kernel_args. boot_disk is required for install profiles and cannot be unset. Example: nodeforge profile unset rocky kernel_args",
    }, profileUnsetHandler);
    try profile_unset.addPositionalArg(.{ .name = "name", .description = "Profile name", .required = true });
    try profile_unset.addPositionalArg(.{ .name = "property", .description = "Must be kernel_args", .required = true });
    try addConfigPathFlag(profile_unset);
    try addOutputFlag(profile_unset);
    try addDebugFlag(profile_unset);
    try profile.addCommands(&.{ profile_create, profile_list, profile_show, profile_set, profile_unset });

    // ── assets 资源（ISO/资产导入管理）──────────────────────────────────
    const assets = try zli.Command.init(init_options, .{
        .name = "assets",
        .description = "Import and inspect boot assets and installation media",
        .usage = "nodeforge assets <import|list|show|validate> [options]",
    }, showCurrentHelp);
    try assets.addCommands(&.{
        try installSourceImportCommand(init_options),
        try assetListCommand(init_options),
        try assetShowCommand(init_options),
        try assetValidateCommand(init_options),
        try assetImportCommand(init_options),
        try assetKeyImportCommand(init_options),
        try assetKeyReloadCommand(init_options),
        try assetKeyShowCommand(init_options),
        try assetKeyListCommand(init_options),
    });

    // ── runtime 资源（DHCP/TFTP 运行态查看）──────────────────────────────
    const runtime = try zli.Command.init(init_options, .{
        .name = "runtime",
        .description = "Inspect runtime state: DHCP leases, TFTP sessions",
        .usage = "nodeforge runtime <dhcp-leases|dhcp-unknown|tftp-counters|tftp-sessions> [options]",
    }, showCurrentHelp);

    const rt_dhcp_leases = try zli.Command.init(init_options, .{ .name = "dhcp-leases", .description = "List active DHCP leases" }, runtimeLeasesHandler);
    try addConfigPathFlag(rt_dhcp_leases);
    try addOutputFlag(rt_dhcp_leases);
    try addDebugFlag(rt_dhcp_leases);

    const rt_dhcp_unknown = try zli.Command.init(init_options, .{ .name = "dhcp-unknown", .description = "List unclaimed DHCP clients" }, runtimeUnknownHandler);
    try addConfigPathFlag(rt_dhcp_unknown);
    try addOutputFlag(rt_dhcp_unknown);
    try addDebugFlag(rt_dhcp_unknown);

    const rt_tftp_counters = try zli.Command.init(init_options, .{ .name = "tftp-counters", .description = "Show TFTP transfer counters" }, tftpShowHandler);
    try addConfigPathFlag(rt_tftp_counters);
    try addOutputFlag(rt_tftp_counters);
    try addDebugFlag(rt_tftp_counters);

    const rt_tftp_sessions = try zli.Command.init(init_options, .{ .name = "tftp-sessions", .description = "Show recent TFTP transfer sessions" }, tftpSessionListHandler);
    try addConfigPathFlag(rt_tftp_sessions);
    try addOutputFlag(rt_tftp_sessions);
    try addDebugFlag(rt_tftp_sessions);

    try runtime.addCommands(&.{
        rt_dhcp_leases,
        rt_dhcp_unknown,
        rt_tftp_counters,
        rt_tftp_sessions,
    });

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

    const setup = try zli.Command.init(init_options, .{
        .name = "setup",
        .description = "Initialize, reconfigure, repair, or reset a NodeForge deployment",
        .usage = "nodeforge setup [--install-root PATH] [options]",
        .help = "All filesystem effects are bounded by the bootstrapped install root. Destructive non-interactive operations require --yes. --reset-all may compose with --reconfigure.",
    }, setupHandler);
    try setup.addFlags(&.{
        .{ .name = "install-root", .description = "New or existing absolute install root", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "non-interactive", .description = "Do not prompt for input", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "yes", .description = "Confirm a destructive or service lifecycle action", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "reconfigure", .description = "Validate config and republish systemd unit; may follow --reset-all", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "import-config", .description = "Import a complete startup config JSON during initialization or reconfiguration", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "generate-systemd", .description = "Generate only the systemd unit", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "print", .description = "Print generated systemd unit instead of writing it", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "install", .description = "Install/enable/start the generated systemd unit", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "repair-dirs", .description = "Repair the canonical directory tree only", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "reset-state", .description = "Back up and clear runtime state", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "reset-all", .description = "Reset startup config and runtime state; may precede --reconfigure", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "purge-data", .description = "With --reset-all, also purge catalog and assets", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "purge-all", .description = "With --reset-all, purge catalog, assets, work files, logs, backups, and migration backups", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "dry-run", .description = "Describe the selected operation without writing", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "bind-interface", .description = "PXE bind interface for generated config", .type = .String, .default_value = .{ .String = "eth0" } },
        .{ .name = "server-ip", .description = "PXE server IPv4 address", .type = .String, .default_value = .{ .String = "192.168.50.1" } },
        .{ .name = "http-port", .description = "HTTP/management listen port for generated config", .type = .Int, .default_value = .{ .Int = 18080 } },
        .{ .name = "subnet", .description = "DHCP subnet CIDR", .type = .String, .default_value = .{ .String = "192.168.50.0/24" } },
        .{ .name = "pool-start", .description = "First DHCP pool address", .type = .String, .default_value = .{ .String = "192.168.50.100" } },
        .{ .name = "pool-end", .description = "Last DHCP pool address", .type = .String, .default_value = .{ .String = "192.168.50.200" } },
    });

    try root.addCommands(&.{
        status,
        config,
        catalog,
        node,
        profile,
        assets,
        runtime,
        events,
        setup,
    });
    return root;
}

fn setupHandler(ctx: zli.CommandContext) !void {
    const p = nodeforge.paths.require();
    const dry_run = ctx.flag("dry-run", bool);
    const import_config_path = ctx.flag("import-config", []const u8);
    const operation_count = @as(u8, @intFromBool(ctx.flag("generate-systemd", bool))) + @as(u8, @intFromBool(ctx.flag("repair-dirs", bool))) + @as(u8, @intFromBool(ctx.flag("reset-state", bool))) + @as(u8, @intFromBool(ctx.flag("reset-all", bool))) + @as(u8, @intFromBool(ctx.flag("reconfigure", bool)));
    const reset_then_reconfigure = ctx.flag("reset-all", bool) and ctx.flag("reconfigure", bool);
    if (operation_count > 1 and !(operation_count == 2 and reset_then_reconfigure))
        return setupFlagError(ctx, "select one setup operation; only --reset-all may compose with --reconfigure");
    if (ctx.flag("print", bool) and ctx.flag("install", bool)) return setupFlagError(ctx, "--print and --install are mutually exclusive");
    if (ctx.flag("install", bool) and !ctx.flag("generate-systemd", bool)) return setupFlagError(ctx, "--install belongs to the standalone --generate-systemd operation; --reconfigure already republishes the unit and service activation remains an explicit systemctl action");
    if (ctx.flag("print", bool) and !ctx.flag("generate-systemd", bool)) return setupFlagError(ctx, "--print requires --generate-systemd");
    if (import_config_path.len != 0 and (ctx.flag("generate-systemd", bool) or ctx.flag("repair-dirs", bool) or ctx.flag("reset-state", bool) or ctx.flag("reset-all", bool))) return error.InvalidFlagValue;
    const purge_all = ctx.flag("purge-all", bool);
    const destructive = ctx.flag("reset-state", bool) or ctx.flag("reset-all", bool) or ctx.flag("purge-data", bool) or purge_all or ctx.flag("install", bool);
    if ((ctx.flag("purge-data", bool) or purge_all) and !ctx.flag("reset-all", bool)) return setupFlagError(ctx, "--purge-data and --purge-all require --reset-all");
    if (ctx.flag("purge-data", bool) and purge_all) return setupFlagError(ctx, "--purge-data and --purge-all are mutually exclusive");
    if (destructive and !ctx.flag("yes", bool)) {
        if (ctx.flag("non-interactive", bool)) return error.ConfirmationRequired;
        if (purge_all)
            try ctx.writer.print("This will permanently purge NodeForge state, catalog, assets, work files, logs, backups, and migration history under {s}, then regenerate the deployment. Continue? [y/N]: ", .{p.install_root})
        else if (ctx.flag("reset-all", bool))
            try ctx.writer.print("This will back up and reset NodeForge startup configuration and runtime state under {s}. Continue? [y/N]: ", .{p.install_root})
        else
            try ctx.writer.print("This will modify {s}. Continue? [y/N]: ", .{p.install_root});
        const answer = ctx.reader.takeDelimiter('\n') catch null;
        if (answer == null or !(std.ascii.eqlIgnoreCase(std.mem.trim(u8, answer.?, " \t\r"), "y") or std.ascii.eqlIgnoreCase(std.mem.trim(u8, answer.?, " \t\r"), "yes"))) return error.ConfirmationRequired;
    }
    const network: nodeforge.setup.Network = .{
        .bind_interface = ctx.flag("bind-interface", []const u8),
        .server_ip = ctx.flag("server-ip", []const u8),
        .http_port = ctx.flag("http-port", u16),
        .subnet = ctx.flag("subnet", []const u8),
        .pool_start = ctx.flag("pool-start", []const u8),
        .pool_end = ctx.flag("pool-end", []const u8),
    };
    var imported_config: ?std.json.Parsed(nodeforge.model.AppConfig) = null;
    if (import_config_path.len != 0) {
        imported_config = loadConfig(ctx.io, ctx.allocator, import_config_path, ctx.writer, false) orelse {
            setExitCode(ctx, 1);
            return;
        };
        if (imported_config.?.value.schema_version != 2 or imported_config.?.value.distros.len != 0 or imported_config.?.value.profiles.len != 0 or imported_config.?.value.nodes.len != 0 or imported_config.?.value.provisioning_bundles.len != 0) {
            try ctx.writer.writeAll("error: config: imported startup config must use schema 2 and must not embed catalog entities\n");
            imported_config.?.deinit();
            setExitCode(ctx, 1);
            return;
        }
    }
    defer if (imported_config) |*candidate| candidate.deinit();
    if (dry_run) {
        try views.success(ctx.writer, "setup dry-run", &.{ .{ .label = "Install root", .value = p.install_root }, .{ .label = "Config", .value = p.config_path }, .{ .label = "Config source", .value = if (import_config_path.len == 0) "generated/existing" else import_config_path }, .{ .label = "Catalog", .value = p.catalog_dir } });
        return;
    }
    if (ctx.flag("generate-systemd", bool)) {
        const unit = try nodeforge.setup.renderSystemd(ctx.allocator, p);
        defer ctx.allocator.free(unit);
        if (ctx.flag("print", bool)) {
            try ctx.writer.writeAll(unit);
        } else {
            try nodeforge.setup.repairDirectories(ctx.io, ctx.allocator, p);
            try nodeforge.dhcp_store.atomicWrite(ctx.io, p.service_path, unit);
        }
        if (ctx.flag("install", bool)) try installSystemd(ctx, p);
        return;
    }
    if (ctx.flag("repair-dirs", bool)) {
        try nodeforge.setup.repairDirectories(ctx.io, ctx.allocator, p);
        try views.success(ctx.writer, "directory layout repaired", &.{.{ .label = "Install root", .value = p.install_root }});
        return;
    }
    if (ctx.flag("reset-state", bool) or ctx.flag("reset-all", bool)) {
        if (std.Io.Dir.cwd().statFile(ctx.io, p.config_path, .{ .follow_symlinks = false })) |_| {
            var running_config = try nodeforge.config.load(ctx.io, ctx.allocator, p.config_path);
            defer running_config.deinit();
            if (nodeforge.management_client.health(ctx.io, running_config.value.server.http_port).reachable) return error.DaemonMustBeStopped;
        } else |err| if (err != error.FileNotFound) return err;
        const backup = try nodeforge.setup.resetState(ctx.io, ctx.allocator, p);
        defer ctx.allocator.free(backup);
        if (ctx.flag("reset-all", bool)) {
            const config_backup = try std.fmt.allocPrint(ctx.allocator, "{s}/config.json", .{backup});
            defer ctx.allocator.free(config_backup);
            try std.Io.Dir.copyFileAbsolute(p.config_path, config_backup, ctx.io, .{ .replace = false, .make_path = true });
            const config = nodeforge.setup.generatedConfig(p, network);
            try nodeforge.config_validate.validate(&config, &nodeforge.model.Catalog{});
            try nodeforge.config_store.save(ctx.io, ctx.allocator, p.config_path, &config);
            if (ctx.flag("purge-data", bool) or purge_all) {
                std.Io.Dir.cwd().deleteTree(ctx.io, p.catalog_dir) catch {};
                std.Io.Dir.cwd().deleteTree(ctx.io, p.assets_dir) catch {};
                try nodeforge.setup.repairDirectories(ctx.io, ctx.allocator, p);
                try nodeforge.catalog_store.initializeEmpty(ctx.io, ctx.allocator, p.catalog_dir);
            }
        }
        if (purge_all) try purgeSetupHistory(ctx, p);
        try views.success(ctx.writer, "deployment state reset", &.{ .{ .label = "Backup", .value = if (purge_all) "purged by --purge-all" else backup }, .{ .label = "Install root", .value = p.install_root } });
        // M4.10：reset-all + reconfigure 是一个有序组合，不是两个相互竞争的
        // operation。reset/purge 先清空所选范围（purge-all 也包含 work 临时
        // 数据）、生成新配置/空 catalog；随后复用唯一的 reconfigure 校验与
        // unit 发布路径。这里不得调用 systemctl，服务生命周期仍由操作员控制。
        if (!reset_then_reconfigure) return;
    }

    const config_exists = blk: {
        _ = std.Io.Dir.cwd().statFile(ctx.io, p.config_path, .{ .follow_symlinks = false }) catch break :blk false;
        break :blk true;
    };
    if (!config_exists) {
        try nodeforge.setup.initialize(ctx.io, ctx.allocator, p, network, if (imported_config) |*candidate| &candidate.value else null);
        try views.success(ctx.writer, "NodeForge initialized", &.{ .{ .label = "Install root", .value = p.install_root }, .{ .label = "Config", .value = p.config_path }, .{ .label = "Catalog", .value = p.catalog_dir } });
        return;
    }
    const migrated = try nodeforge.setup.migrateLegacy(ctx.io, ctx.allocator, p);
    var catalog = try nodeforge.catalog_store.load(ctx.io, ctx.allocator, p.catalog_dir);
    defer catalog.deinit();
    var installed_config: ?std.json.Parsed(nodeforge.model.AppConfig) = null;
    if (imported_config == null) installed_config = try nodeforge.config.load(ctx.io, ctx.allocator, p.config_path);
    defer if (installed_config) |*current| current.deinit();
    const startup_config = if (imported_config) |*candidate| &candidate.value else &installed_config.?.value;
    const effective = nodeforge.model.projectCatalog(startup_config.*, &catalog.value);
    try nodeforge.config_validate.validate(&effective, &catalog.value);
    const unit = try nodeforge.setup.renderSystemd(ctx.allocator, p);
    defer ctx.allocator.free(unit);
    // M4.9：setup 是 startup config 的唯一写入口。发布前必须把 candidate
    // 与当前 catalog 联合校验；requested/applied provenance 是历史事实，
    // 配置导入不得改写。运行中的 daemon 只在重启后加载新 pair。
    if (imported_config != null) try nodeforge.config_store.save(ctx.io, ctx.allocator, p.config_path, startup_config);
    try nodeforge.dhcp_store.atomicWrite(ctx.io, p.service_path, unit);
    if (imported_config != null)
        try views.success(ctx.writer, "deployment reconfigured", &.{ .{ .label = "Install root", .value = p.install_root }, .{ .label = "Config source", .value = import_config_path }, .{ .label = "Config schema", .value = "2" }, .{ .label = "Catalog layout", .value = "1" }, .{ .label = "Systemd unit", .value = p.service_path }, .{ .label = "Service", .value = "unchanged; run systemctl daemon-reload/restart nodeforged" } })
    else
        try views.success(ctx.writer, if (migrated) "legacy deployment migrated" else "deployment reconfigured", &.{ .{ .label = "Install root", .value = p.install_root }, .{ .label = "Config schema", .value = "2" }, .{ .label = "Catalog layout", .value = "1" }, .{ .label = "Systemd unit", .value = p.service_path }, .{ .label = "Service", .value = "unchanged; run systemctl daemon-reload/restart nodeforged" } });
}

fn setupFlagError(ctx: zli.CommandContext, message: []const u8) void {
    ctx.writer.print("error: setup: {s}\n", .{message}) catch {};
    setExitCode(ctx, 2);
}

/// Remove every history-bearing path covered by `--purge-all`.
///
/// Binary/marker/config/unit survive. Managed work files do not: imports are
/// temporary, may be several GiB, and must not cross a fresh-reset boundary.
/// `repairDirectories` recreates the empty canonical work/import layout.
fn purgeSetupHistory(ctx: zli.CommandContext, p: *const nodeforge.paths.Paths) !void {
    const backups_dir = try std.fmt.allocPrint(ctx.allocator, "{s}/backups", .{p.install_root});
    defer ctx.allocator.free(backups_dir);
    std.Io.Dir.cwd().deleteTree(ctx.io, backups_dir) catch {};
    std.Io.Dir.cwd().deleteTree(ctx.io, p.logs_dir) catch {};
    // Interrupted ISO imports can contain read-only directory trees copied from
    // installation media. Native deletion is preferred. If traversal is denied,
    // restore owner permissions only under the validated, derived work path and
    // retry with a bounded argv; command failure propagates instead of reporting
    // a successful purge with stale data left behind.
    std.Io.Dir.cwd().deleteTree(ctx.io, p.work_dir) catch {
        try runRequired(ctx, &.{ "chmod", "-R", "u+rwx", p.work_dir });
        try runRequired(ctx, &.{ "rm", "-rf", "--", p.work_dir });
    };
    for ([_][]const u8{ p.config_path, p.legacy_catalog_path }) |path| {
        const migration_backup = try std.fmt.allocPrint(ctx.allocator, "{s}.m4.7.bak", .{path});
        defer ctx.allocator.free(migration_backup);
        std.Io.Dir.cwd().deleteFile(ctx.io, migration_backup) catch {};
    }
    try nodeforge.setup.repairDirectories(ctx.io, ctx.allocator, p);
}

/// Publish and activate the unit as one recoverable lifecycle operation. The
/// previous link and enabled/active state are restored if systemctl, model
/// loading, or the loopback health probe fails.
fn installSystemd(ctx: zli.CommandContext, p: *const nodeforge.paths.Paths) !void {
    const link = "/etc/systemd/system/nodeforged.service";
    const backup = "/etc/systemd/system/nodeforged.service.nodeforge-backup";
    const existed = blk: {
        _ = std.Io.Dir.cwd().statFile(ctx.io, link, .{ .follow_symlinks = false }) catch break :blk false;
        break :blk true;
    };
    const was_enabled = try commandSucceeded(ctx, &.{ "systemctl", "is-enabled", "--quiet", "nodeforged.service" });
    const was_active = try commandSucceeded(ctx, &.{ "systemctl", "is-active", "--quiet", "nodeforged.service" });
    if (existed) try runRequired(ctx, &.{ "cp", "-P", link, backup });
    errdefer rollbackSystemd(ctx, link, backup, existed, was_enabled, was_active);
    try runRequired(ctx, &.{ "ln", "-sfn", p.service_path, link });
    try runRequired(ctx, &.{ "systemctl", "daemon-reload" });
    try runRequired(ctx, &.{ "systemctl", "enable", "--now", "nodeforged.service" });

    var config = try nodeforge.config.load(ctx.io, ctx.allocator, p.config_path);
    defer config.deinit();
    var catalog = try nodeforge.catalog_store.load(ctx.io, ctx.allocator, p.catalog_dir);
    defer catalog.deinit();
    const effective = nodeforge.model.projectCatalog(config.value, &catalog.value);
    try nodeforge.config_validate.validate(&effective, &catalog.value);
    // M4.9：Type=simple 的 `systemctl start` 在 exec 成功后即可返回，此时 daemon 的
    // HTTP worker 可能尚未完成 listener 初始化。单次立即探测会把正常启动
    // 误判为失败并回滚刚安装的 unit；给启动路径一个有界的 5 秒就绪窗口。
    if (!waitForSystemdHealth(ctx.io, config.value.server.http_port)) return error.SystemdHealthCheckFailed;
    if (existed) std.Io.Dir.cwd().deleteFile(ctx.io, backup) catch {};
}

fn waitForSystemdHealth(io: std.Io, port: u16) bool {
    // 每次 probe 自带 250ms receive 上限，15 次加 100ms 间隔使整个
    // readiness transaction 保持约 5 秒，而非只限制 sleep 总和。
    const attempts = 15;
    for (0..attempts) |attempt| {
        if (nodeforge.management_client.health(io, port).healthy) return true;
        if (attempt + 1 < attempts) std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
    }
    return false;
}

fn rollbackSystemd(ctx: zli.CommandContext, link: []const u8, backup: []const u8, existed: bool, was_enabled: bool, was_active: bool) void {
    _ = commandSucceeded(ctx, &.{ "rm", "-f", link }) catch false;
    // Copy back instead of moving so the failed activation retains a unit
    // backup for diagnosis after the previous service state is restored.
    if (existed) _ = commandSucceeded(ctx, &.{ "cp", "-P", backup, link }) catch false;
    _ = commandSucceeded(ctx, &.{ "systemctl", "daemon-reload" }) catch false;
    _ = commandSucceeded(ctx, if (was_enabled) &.{ "systemctl", "enable", "nodeforged.service" } else &.{ "systemctl", "disable", "nodeforged.service" }) catch false;
    _ = commandSucceeded(ctx, if (was_active) &.{ "systemctl", "start", "nodeforged.service" } else &.{ "systemctl", "stop", "nodeforged.service" }) catch false;
}

fn runRequired(ctx: zli.CommandContext, argv: []const []const u8) !void {
    if (!try commandSucceeded(ctx, argv)) return error.SystemdInstallFailed;
}

fn commandSucceeded(ctx: zli.CommandContext, argv: []const []const u8) !bool {
    const result = try std.process.run(ctx.allocator, ctx.io, .{ .argv = argv, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    return successfulTerm(result.term);
}

fn successfulTerm(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn installSourceImportCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{
        .name = "import",
        .description = "Import an ISO and publish its install source",
        .help = "Accepts an ISO at any local path. The daemon validates its Anaconda/.treeinfo or Subiquity/casper layout, derives family and distro capabilities, and atomically publishes the distro tuple with the install source. The original file is never moved or deleted. Use tuple overrides for a valid but previously unknown vendor label; unknown layouts are rejected.",
    }, installSourceImportHandler);
    try addConfigPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
    try command.addPositionalArg(.{ .name = "iso-path", .description = "Readable local ISO path; e.g. /srv/iso/ubuntu-22.04.5-live-server-arm64.iso", .required = true });
    try command.addFlags(&.{
        .{ .name = "distro", .description = "Override an unknown or ambiguous product id; e.g. rocky, kylin, ubuntu. Family still comes from ISO layout", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "name", .description = "Explicit canonical logical name; e.g. rocky-9.7-aarch64-dvd", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "version", .description = "Override auto-detected version; e.g. 9.7, 22.04. Empty = auto-detect", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "arch", .description = "Override auto-detected arch; e.g. aarch64, x86_64. Empty = auto-detect", .type = .String, .default_value = .{ .String = "" } },
    });
    return command;
}

fn assetImportCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{ .name = "register", .description = "Register an existing TFTP asset and its SHA-256" }, assetImportHandler);
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

fn assetKeyImportCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{ .name = "key-import", .description = "Import a bootstrap SSH public key" }, assetKeyImportHandler);
    try command.addPositionalArg(.{ .name = "path", .description = "Local OpenSSH public key path", .required = true });
    try addOutputFlag(command);
    return command;
}

fn assetKeyReloadCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{ .name = "key-reload", .description = "Reload bootstrap SSH public keys" }, assetKeyReloadHandler);
    try addConfigPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
    return command;
}

fn assetKeyShowCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{ .name = "key-show", .description = "Show effective SSH key fingerprints" }, assetKeyShowHandler);
    try addConfigPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
    return command;
}

fn assetKeyListCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{ .name = "key-list", .description = "List imported SSH public key files" }, assetKeyListHandler);
    try addOutputFlag(command);
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

/// 执行 canonical 端到端状态查询，并把探测结果保存为进程退出码。
fn statusHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    setExitCode(ctx, try statusCommand(ctx.io, ctx.allocator, ctx.flag("config", []const u8), output_json, debug, ctx.writer));
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
    const effective = nodeforge.model.projectCatalog(parsed_config.value, parsed_catalog.value());
    nodeforge.config_validate.validate(&effective, parsed_catalog.value()) catch |err| {
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
    if (parsed_config.value.schema_version != 2 or parsed_config.value.distros.len != 0 or parsed_config.value.profiles.len != 0 or parsed_config.value.nodes.len != 0 or parsed_config.value.provisioning_bundles.len != 0) {
        try ctx.writer.writeAll("error: config: schema-1/model migration requires nodeforge setup --reconfigure\n");
        setExitCode(ctx, 1);
        return;
    }
    const bytes = try nodeforge.config_store.render(ctx.allocator, &parsed_config.value);
    defer ctx.allocator.free(bytes);
    try ctx.writer.writeAll(bytes);
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
    const effective = nodeforge.model.projectCatalog(parsed_config.value, parsed_catalog.value());
    nodeforge.config_validate.validate(&effective, parsed_catalog.value()) catch |err| {
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

fn catalogShowHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    const name = ctx.positional_args[0];
    var response: [256 * 1024]u8 = undefined;
    const body = nodeforge.management_client.installSourceJson(ctx.io, parsed_config.value.server.http_port, name, &response) catch null orelse {
        try ctx.writer.print("error: install source '{s}' was not found or daemon is unavailable\n", .{name});
        setExitCode(ctx, 1);
        return;
    };
    if (output_json) return ctx.writer.writeAll(body);
    const Response = struct { result: struct { family: []const u8, install_source: model.InstallSourceConfig, repositories: []const model.RepositoryConfig, assets: []const model.AssetConfig, profiles: []const []const u8 } };
    const parsed = std.json.parseFromSlice(Response, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch return error.InvalidManagementResponse;
    defer parsed.deinit();
    const source = parsed.value.result.install_source;
    try ctx.writer.print("{s}  {s}/{s}/{s}  family={s}\n", .{ source.name, source.distro, source.version, @tagName(source.arch), parsed.value.result.family });
    try ctx.writer.print("  media_tree={s}\n  repositories={d} assets={d} profiles={d}\n", .{ source.media_tree_url orelse "-", parsed.value.result.repositories.len, parsed.value.result.assets.len, parsed.value.result.profiles.len });
    for (parsed.value.result.assets) |asset| try ctx.writer.print("  asset {s} {s} sha256={s}\n", .{ asset.name, asset.path, asset.sha256 orelse "-" });
}

fn catalogMigrateHandler(ctx: zli.CommandContext) !void {
    const dry_run = ctx.flag("dry-run", bool);
    const apply = ctx.flag("apply", bool);
    const digest = ctx.flag("plan-digest", []const u8);
    if (dry_run == apply or (apply and digest.len != 64) or (dry_run and digest.len != 0)) {
        try ctx.writer.writeAll("error: catalog migrate requires exactly one of --dry-run or --apply; --apply requires --plan-digest <64-hex>\n");
        setExitCode(ctx, 2);
        return;
    }
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    var response: [256 * 1024]u8 = undefined;
    const body = (if (apply) nodeforge.management_client.catalogMigrationApplyJson(ctx.io, parsed_config.value.server.http_port, digest, &response) else nodeforge.management_client.catalogMigrationPlanJson(ctx.io, parsed_config.value.server.http_port, &response)) catch null orelse {
        try ctx.writer.writeAll("error: catalog migration plan request failed\n");
        setExitCode(ctx, 1);
        return;
    };
    if (apply) {
        try ctx.writer.writeAll(body);
        return;
    }
    // The daemon response is the canonical diagnostic artifact. Human mode is
    // intentionally concise until apply adds an operation lifecycle view.
    if (outputJsonFromContext(ctx) orelse false) return ctx.writer.writeAll(body);
    const Response = struct { result: struct { plan_digest: []const u8, applicable: bool, plan: struct { renames: []const std.json.Value, blockers: []const std.json.Value } } };
    const parsed = std.json.parseFromSlice(Response, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        try ctx.writer.writeAll("error: invalid migration plan response\n");
        setExitCode(ctx, 1);
        return;
    };
    defer parsed.deinit();
    try ctx.writer.print("Plan digest: {s}\nRenames: {d}\nBlockers: {d}\nApplicable: {s}\n", .{ parsed.value.result.plan_digest, parsed.value.result.plan.renames.len, parsed.value.result.plan.blockers.len, if (parsed.value.result.applicable) "yes" else "no" });
}

/// 通过本机 daemon 注册一个已经位于受管根目录中的资产。
///
/// CLI 只解析并校验资产类型、逻辑名称、受管相对路径和可选 distro tuple；
/// 文件打开、SHA-256 计算、候选模型校验及 catalog 原子发布均由 daemon
/// 管理 API 完成。因此本命令要求 daemon 可达，不是 fresh setup 的离线写入口。
/// daemon 拒绝或不可达时返回退出码 1，CLI 参数错误返回退出码 2。
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

/// `assets import` 的 ISO 安装源导入处理器。
///
/// 完整流程：
/// 1. 加载启动配置获取 daemon HTTP 端口
/// 2. 校验 --arch 参数（如果提供了的话）
/// 3. 调用 `stageInstallIso` 将 ISO 原子复制到 daemon 受管的暂存目录
/// 4. 通过管理 API 请求 daemon 执行 loop mount、介质检测和 catalog 发布
/// 5. daemon 返回后，defer 清理暂存文件
/// 6. M4.10：成功响应同时返回 canonical install source；daemon 在同一
///    catalog publication 中创建同名默认 install profile
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
    const name = ctx.flag("name", []const u8);
    const version = ctx.flag("version", []const u8);
    const arch = ctx.flag("arch", []const u8);
    if (distro.len != 0 and !nodeforge.config_validate.validLogicalId(distro)) {
        try ctx.writer.writeAll("error: install-source: invalid canonical --distro\n");
        setExitCode(ctx, 2);
        return;
    }
    if (name.len != 0 and !nodeforge.config_validate.validLogicalId(name)) {
        try ctx.writer.writeAll("error: install-source: invalid canonical --name\n");
        setExitCode(ctx, 2);
        return;
    }
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
    const import_key = installImportKey(staged.sha256, if (name.len == 0) null else name, if (distro.len == 0) null else distro, if (version.len == 0) null else version, if (arch.len == 0) null else arch);
    const imported = nodeforge.management_client.importInstallSource(ctx.io, parsed_config.value.server.http_port, .{
        .filename = staged.filename,
        .content_sha256 = &staged.sha256,
        .idempotency_key = &import_key,
        .name = if (name.len == 0) null else name,
        .distro = if (distro.len == 0) null else distro,
        .version = if (version.len == 0) null else version,
        .arch = if (arch.len == 0) null else arch,
    }) catch |err| {
        try ctx.writer.writeAll("error: install-source: import request failed\n");
        if (debug) try ctx.writer.print("debug: install-source: cause={t}\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    if (imported == null) {
        try ctx.writer.writeAll("error: install-source: daemon rejected import\n");
        setExitCode(ctx, 1);
        return;
    }
    const source_name = imported.?.name();
    if (output_json)
        try ctx.writer.print("{{\"ok\":true,\"path\":{f},\"install_source\":{f},\"profile\":{f},\"next\":{{\"node_add\":\"nodeforge node add <node-id> mac=<mac> arch=<arch> profile={s}\"}}}}\n", .{ std.json.fmt(iso_path, .{}), std.json.fmt(source_name, .{}), std.json.fmt(source_name, .{}), source_name })
    else
        try views.success(ctx.writer, "install source and default profile imported", &.{ .{ .label = "ISO", .value = iso_path }, .{ .label = "Install source", .value = source_name }, .{ .label = "Default profile", .value = source_name }, .{ .label = "Next", .value = "nodeforge node add <node-id> mac=<mac> arch=<arch> profile=<default-profile>" } });
}

/// 暂存 ISO 的结果：daemon 受管目录中的不透明文件名、完整路径和文件大小。
const StagedInstallIso = struct {
    filename: []u8,
    path: []u8,
    size: u64,
    sha256: [64]u8,
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
    const destination = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ nodeforge.paths.require().import_dir, filename });
    errdefer allocator.free(destination);
    try std.Io.Dir.cwd().createDirPath(io, nodeforge.paths.require().import_dir);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source, std.Io.Dir.cwd(), destination, io, .{ .permissions = .default_file, .replace = false });
    var checksum: [64]u8 = undefined;
    try nodeforge.asset_validate.sha256File(io, nodeforge.paths.require().import_dir, filename, &checksum);
    return .{ .filename = filename, .path = destination, .size = stat.size, .sha256 = checksum };
}

fn installImportKey(content_sha256: [64]u8, name: ?[]const u8, distro: ?[]const u8, version: ?[]const u8, arch: ?[]const u8) [64]u8 {
    var hash_state = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (.{ @as(?[]const u8, &content_sha256), name, distro, version, arch }) |value| {
        if (value) |bytes| hash_state.update(bytes);
        hash_state.update(&.{0});
    }
    var raw: [32]u8 = undefined;
    hash_state.final(&raw);
    return std.fmt.bytesToHex(raw, .lower);
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
        nodeforge.asset_validate.sha256File(ctx.io, assetRoot(&parsed_config.value, item.kind), item.path, &digest) catch {
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

fn assetKeyImportHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const source = ctx.getArg("path") orelse unreachable;
    const basename = std.fs.path.basename(source);
    if (basename.len == 0 or !std.mem.endsWith(u8, basename, ".pub")) {
        try ctx.writer.writeAll("error: assets key-import requires a .pub file\n");
        setExitCode(ctx, 1);
        return;
    }
    // assets/keys/id_ed25519{,.pub} 是 NodeForge 自动生成 key pair 的保留名。
    // 操作员导入常见的 ~/.ssh/id_ed25519.pub 时安全改名，不能覆盖或拆散该 pair。
    const destination_name = if (std.mem.eql(u8, basename, "id_ed25519.pub")) "imported-id_ed25519.pub" else basename;
    const key = nodeforge.admin_key.loadPublicKey(ctx.io, ctx.allocator, source) catch |err| {
        try ctx.writer.print("error: assets key-import invalid public key: {t}\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    defer ctx.allocator.free(key);

    const destination = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ nodeforge.paths.require().keys_dir, destination_name });
    defer ctx.allocator.free(destination);
    try std.Io.Dir.cwd().createDirPath(ctx.io, nodeforge.paths.require().keys_dir);
    var atomic_file = std.Io.Dir.cwd().createFileAtomic(ctx.io, destination, .{ .permissions = .default_file, .make_path = true, .replace = false }) catch |err| {
        try ctx.writer.print("error: assets key-import cannot create destination: {t}\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    defer atomic_file.deinit(ctx.io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic_file.file.writer(ctx.io, &buffer);
    writer.interface.writeAll(key) catch return writer.err.?;
    writer.interface.writeByte('\n') catch return writer.err.?;
    writer.interface.flush() catch return writer.err.?;
    try atomic_file.file.sync(ctx.io);
    atomic_file.link(ctx.io) catch |err| {
        try ctx.writer.print("error: assets key-import destination already exists or cannot be published: {t}\n", .{err});
        setExitCode(ctx, 1);
        return;
    };

    const fingerprint = try nodeforge.admin_key.fingerprint(ctx.allocator, key);
    defer ctx.allocator.free(fingerprint);
    if (output_json) {
        try ctx.writer.print("{{\"ok\":true,\"file\":{f},\"fingerprint\":{f}}}\n", .{ std.json.fmt(destination_name, .{}), std.json.fmt(fingerprint, .{}) });
    } else try views.success(ctx.writer, "SSH public key imported", &.{ .{ .label = "File", .value = destination_name }, .{ .label = "Fingerprint", .value = fingerprint } });
}

fn assetKeyReloadHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const status = nodeforge.management_client.managementStatus(ctx.io, config.value.server.http_port);
    if (!status.healthy) {
        try ctx.writer.writeAll("error: assets key-reload could not reach the local daemon\n");
        setExitCode(ctx, 1);
        return;
    }
    if (output_json) try ctx.writer.writeAll("{\"ok\":true,\"reload\":\"requested\"}\n") else try views.success(ctx.writer, "SSH public key reload requested", &.{});
}

fn assetKeyShowHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const primary = nodeforge.admin_key.resolve(ctx.io, ctx.allocator, config.value.server) catch |err| {
        try ctx.writer.print("error: assets key-show cannot resolve keys: {t}\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    defer ctx.allocator.free(primary);
    const additional = try nodeforge.admin_key.resolveAdditional(ctx.io, ctx.allocator, config.value.server);
    defer {
        for (additional) |key| ctx.allocator.free(key);
        ctx.allocator.free(additional);
    }
    if (output_json) try ctx.writer.writeAll("{\"keys\":[");
    var index: usize = 0;
    while (index <= additional.len) : (index += 1) {
        const key = if (index == 0) primary else additional[index - 1];
        const fingerprint = try nodeforge.admin_key.fingerprint(ctx.allocator, key);
        defer ctx.allocator.free(fingerprint);
        const source = try nodeforge.admin_key.sourceLabel(ctx.io, ctx.allocator, config.value.server, key);
        defer ctx.allocator.free(source);
        if (output_json) {
            if (index != 0) try ctx.writer.writeByte(',');
            try ctx.writer.print("{{\"source\":{f},\"fingerprint\":{f}}}", .{ std.json.fmt(source, .{}), std.json.fmt(fingerprint, .{}) });
        } else {
            var label: [24]u8 = undefined;
            try views.success(ctx.writer, if (index == 0) "effective primary SSH key" else "effective additional SSH key", &.{ .{ .label = "Index", .value = try std.fmt.bufPrint(&label, "{d}", .{index}) }, .{ .label = "Source", .value = source }, .{ .label = "Fingerprint", .value = fingerprint } });
        }
    }
    if (output_json) try ctx.writer.writeAll("]}\n");
}

fn assetKeyListHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| ctx.allocator.free(name);
        names.deinit(ctx.allocator);
    }
    var directory = std.Io.Dir.cwd().openDir(ctx.io, nodeforge.paths.require().keys_dir, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            if (output_json) try ctx.writer.writeAll("{\"keys\":[]}\n") else try ctx.writer.writeAll("No SSH public keys imported.\n");
            return;
        },
        else => return err,
    };
    defer directory.close(ctx.io);
    var iterator = directory.iterate();
    while (try iterator.next(ctx.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pub")) try names.append(ctx.allocator, try ctx.allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    if (output_json) try ctx.writer.writeAll("{\"keys\":[");
    for (names.items, 0..) |name, index| {
        if (output_json) {
            if (index != 0) try ctx.writer.writeByte(',');
            try ctx.writer.print("{f}", .{std.json.fmt(name, .{})});
        } else try ctx.writer.print("{s}\n", .{name});
    }
    if (output_json) try ctx.writer.writeAll("]}\n");
}

fn assetRoot(config: *const nodeforge.model.AppConfig, kind: nodeforge.model.AssetKind) []const u8 {
    return switch (kind) {
        .iso => config.http.asset_root,
        .bootloader, .kernel, .installer_initrd => config.tftp.asset_root,
        .gpg_key => nodeforge.paths.require().keys_dir,
        .nodeforge_initrd => nodeforge.paths.require().initrd_dir,
        .rootfs => nodeforge.paths.require().rootfs_dir,
    };
}

test "asset validation selects the storage root by asset kind" {
    const config: nodeforge.model.AppConfig = .{
        .server = .{ .server_ip = "192.168.50.1" },
        .http = .{ .asset_root = "/http-assets" },
        .tftp = .{ .asset_root = "/tftp-assets" },
    };
    try std.testing.expectEqualStrings("/http-assets", assetRoot(&config, .iso));
    try std.testing.expectEqualStrings(nodeforge.paths.require().rootfs_dir, assetRoot(&config, .rootfs));
    try std.testing.expectEqualStrings(nodeforge.paths.require().initrd_dir, assetRoot(&config, .nodeforge_initrd));
    try std.testing.expectEqualStrings(nodeforge.paths.require().keys_dir, assetRoot(&config, .gpg_key));
    try std.testing.expectEqualStrings("/tftp-assets", assetRoot(&config, .bootloader));
    try std.testing.expectEqualStrings("/tftp-assets", assetRoot(&config, .installer_initrd));
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
    // M4.5：按 `next_cursor` 翻页直到取完或达到表格渲染上限（256）。字段借用
    // 每页响应缓冲，故用 arena 复制到稳定存储后再渲染。`--output json` 只回显
    // 首页信封，JSON 消费者自行跟随游标。
    var response: [128 * 1024]u8 = undefined;
    const first = nodeforge.management_client.collectionPageJson(ctx.io, config.value.server.http_port, "/api/v1/management/nodes", null, &response) catch {
        try ctx.writer.writeAll("error: node: local daemon management API unavailable\n");
        setExitCode(ctx, 1);
        return;
    };
    var page_body = first orelse {
        try ctx.writer.writeAll("error: node: local daemon management API unavailable\n");
        setExitCode(ctx, 1);
        return;
    };
    if (output_json) {
        try ctx.writer.writeAll(page_body);
        return;
    }
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rows: std.ArrayList(views.NodeRow) = .empty;
    var cursor_buf: [256]u8 = undefined;
    var cursor: ?[]const u8 = null;
    var truncated = false;
    const NodeItem = struct { id: []const u8, mac: []const u8, ip: ?[]const u8, profile: []const u8, deploy: bool, install_intent: []const u8, pxe_ready: bool, retry_pending: bool, armed_generation: ?u64, status: ?[]const u8, start_at: ?i64, install_at: ?i64, finished_at: ?i64, serial_number: ?[]const u8 };
    const Response = struct { ok: bool, result: struct { items: []const NodeItem, next_cursor: ?[]const u8 } };
    while (true) {
        const parsed = std.json.parseFromSlice(Response, a, page_body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            try ctx.writer.writeAll("error: node: malformed daemon response\n");
            setExitCode(ctx, 1);
            return;
        };
        for (parsed.value.result.items) |item| {
            if (rows.items.len >= 256) {
                truncated = true;
                break;
            }
            var start_buf: [20]u8 = undefined;
            var install_buf: [20]u8 = undefined;
            var finished_buf: [20]u8 = undefined;
            try rows.append(a, .{
                .id = try a.dupe(u8, item.id),
                .mac = try a.dupe(u8, item.mac),
                .ip = try a.dupe(u8, item.ip orelse "-"),
                .profile = try a.dupe(u8, item.profile),
                .deploy = try a.dupe(u8, if (item.deploy) "yes" else "no"),
                .install_intent = try a.dupe(u8, item.install_intent),
                .status = try a.dupe(u8, item.status orelse "-"),
                .start_at = try a.dupe(u8, views.formatTimestamp(&start_buf, item.start_at orelse 0)),
                .install_at = try a.dupe(u8, views.formatTimestamp(&install_buf, item.install_at orelse 0)),
                .finished_at = try a.dupe(u8, views.formatTimestamp(&finished_buf, item.finished_at orelse 0)),
                .serial_number = try a.dupe(u8, item.serial_number orelse "-"),
            });
        }
        if (truncated) break;
        if (parsed.value.result.next_cursor) |nc| {
            if (nc.len <= cursor_buf.len) {
                @memcpy(cursor_buf[0..nc.len], nc);
                cursor = cursor_buf[0..nc.len];
            } else break;
        } else break;
        page_body = (nodeforge.management_client.collectionPageJson(ctx.io, config.value.server.http_port, "/api/v1/management/nodes", cursor, &response) catch null) orelse break;
    }
    try views.nodes(ctx.writer, rows.items);
    try ctx.writer.writeAll("Settable keys: mac, arch, profile, ip, hostname, deploy, http_accel (see: nodeforge node show <id>)\n");
    if (truncated) try ctx.writer.writeAll("note: output truncated at 256 rows; use the management API with limit/cursor for the full list\n");
}

fn profileListHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    // M4.5：按 `next_cursor` 翻页取全部 profile（上限 256 行）。`--output json`
    // 只回显首页信封，JSON 消费者自行跟随游标。
    var response: [128 * 1024]u8 = undefined;
    const first = nodeforge.management_client.collectionPageJson(ctx.io, config.value.server.http_port, "/api/v1/management/profiles", null, &response) catch {
        try ctx.writer.writeAll("error: profile: local daemon management API unavailable\n");
        setExitCode(ctx, 1);
        return;
    };
    var page_body = first orelse {
        try ctx.writer.writeAll("error: profile: local daemon management API unavailable\n");
        setExitCode(ctx, 1);
        return;
    };
    if (output_json) return ctx.writer.writeAll(page_body);
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rows: std.ArrayList(views.ProfileRow) = .empty;
    var cursor_buf: [256]u8 = undefined;
    var cursor: ?[]const u8 = null;
    var truncated = false;
    const ProfileItem = struct { name: []const u8, mode: []const u8, distro: []const u8, version: []const u8, arch: []const u8, install_source: ?[]const u8, nodes: usize, valid: bool };
    const Response = struct { ok: bool, result: struct { items: []const ProfileItem, next_cursor: ?[]const u8 } };
    while (true) {
        const parsed = std.json.parseFromSlice(Response, a, page_body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            try ctx.writer.writeAll("error: profile: malformed daemon response\n");
            setExitCode(ctx, 1);
            return;
        };
        for (parsed.value.result.items) |profile| {
            if (rows.items.len >= 256) {
                truncated = true;
                break;
            }
            var count_buf: [24]u8 = undefined;
            try rows.append(a, .{
                .name = try a.dupe(u8, profile.name),
                .mode = try a.dupe(u8, profile.mode),
                .distro = try a.dupe(u8, profile.distro),
                .version = try a.dupe(u8, profile.version),
                .arch = try a.dupe(u8, profile.arch),
                .install_source = try a.dupe(u8, profile.install_source orelse "-"),
                .nodes = try a.dupe(u8, try std.fmt.bufPrint(&count_buf, "{d}", .{profile.nodes})),
                .valid = try a.dupe(u8, if (profile.valid) "yes" else "no"),
            });
        }
        if (truncated) break;
        if (parsed.value.result.next_cursor) |nc| {
            if (nc.len <= cursor_buf.len) {
                @memcpy(cursor_buf[0..nc.len], nc);
                cursor = cursor_buf[0..nc.len];
            } else break;
        } else break;
        page_body = (nodeforge.management_client.collectionPageJson(ctx.io, config.value.server.http_port, "/api/v1/management/profiles", cursor, &response) catch null) orelse break;
    }
    try views.profiles(ctx.writer, rows.items);
    try ctx.writer.writeAll("Settable keys: kernel_args, boot_disk (see: nodeforge profile show <name>)\n");
    if (truncated) try ctx.writer.writeAll("note: output truncated at 256 rows; use the management API with limit/cursor for the full list\n");
}

fn profileShowHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const name = ctx.getArg("name") orelse return;
    var response: [128 * 1024]u8 = undefined;
    const body = try nodeforge.management_client.profilesJson(ctx.io, config.value.server.http_port, name, &response);
    if (body == null) {
        try ctx.writer.writeAll("error: profile: local daemon management API unavailable\n");
        setExitCode(ctx, 1);
        return;
    }
    if (output_json) return ctx.writer.writeAll(body.?);

    // M4.5 keeps the HTTP DTO machine-oriented while the CLI renders a stable,
    // scannable human view. Never dump the compact wire JSON in human mode.
    const Response = struct {
        result: struct {
            model_revision: struct { config: u64, catalog: u64 },
            name: []const u8,
            mode: []const u8,
            distro: []const u8,
            version: []const u8,
            arch: []const u8,
            boot_bundle: ?[]const u8,
            kernel_args: ?[]const u8,
            install: ?model.InstallConfig,
            safety: model.ProfileSafetyConfig,
            validation: struct { valid: bool },
            capability: struct { family: []const u8, install_adapter: []const u8, package_manager: []const u8 },
            effective_system: struct {
                localization: struct { locale: []const u8, timezone: []const u8, keyboard: []const u8 },
                connectivity: struct { mode: []const u8, time_sync: bool, ntp_servers: []const []const u8 },
                ssh: struct { enabled: bool, password_authentication: bool, root_login: []const u8, root_password_configured: bool, root_authorized_key_count: usize },
                security: struct { firewall: []const u8, selinux: []const u8 },
                users: []const std.json.Value,
                packages: []const []const u8,
            },
            install_source: ?struct { name: []const u8, source_label: ?[]const u8, media_tree_url: ?[]const u8, repositories: []const []const u8 },
            assets: []const struct { name: []const u8, kind: []const u8, path: []const u8, sha256: ?[]const u8 },
            nodes: []const []const u8,
        },
    };
    const parsed = std.json.parseFromSlice(Response, ctx.allocator, body.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        try ctx.writer.print("error: profile: malformed daemon response ({t})\n", .{err});
        setExitCode(ctx, 1);
        return;
    };
    defer parsed.deinit();
    const result = parsed.value.result;
    try ctx.writer.print("Profile {s}\n", .{result.name});
    try ctx.writer.writeAll("\nSettable properties (nodeforge profile set ");
    try ctx.writer.writeAll(result.name);
    try ctx.writer.writeAll(" key=value)\n");
    if (result.kernel_args) |kernel_args| try ctx.writer.print("  kernel_args={s}\n", .{kernel_args}) else try ctx.writer.print("  # kernel_args is unset; action: nodeforge profile unset {s} kernel_args\n", .{result.name});
    if (result.install) |install| try ctx.writer.print("  boot_disk={s}\n", .{install.storage.boot_disk});
    try ctx.writer.print("\nRead-only detail\n  mode          {s}\n  platform      {s} {s} ({s})\n  family        {s}\n  adapter       {s}\n  package_manager {s}\n  boot_bundle   {s}\n  valid         {s}\n", .{ result.mode, result.distro, result.version, result.arch, result.capability.family, result.capability.install_adapter, result.capability.package_manager, result.boot_bundle orelse "-", if (result.validation.valid) "yes" else "no" });
    if (result.install) |install| try ctx.writer.print("  wipe          {s}\n", .{if (install.storage.wipe) "yes" else "no"});
    try ctx.writer.print("\nOwner / action\n  kernel_args\n    owner         profile:{s}\n    action        nodeforge profile set {s} 'kernel_args=<arguments>'\n  boot_disk\n    owner         profile:{s}\n    action        nodeforge profile set {s} boot_disk=/dev/<device>\n  mode/distro/version/arch/boot_bundle/safety\n    owner         profile:{s}\n    action        read-only (no mutation command)\n  effective_system.*\n    owner         projected startup/profile model\n    action        read-only projection\n  install_source.* / assets.*\n    owner         imported catalog assets\n    action        nodeforge assets list/show/import\n  model_revision.*\n    owner         nodeforged model store\n    action        read-only\n", .{ result.name, result.name, result.name, result.name, result.name });
    try ctx.writer.print("\nSafety\n  Unknown safe  {s}\n  Destructive   {s}\n  Persistent    {s}\n  Reinstall     {s}\n", .{ if (result.safety.safe_for_unknown) "yes" else "no", if (result.safety.destructive) "yes" else "no", if (result.safety.persistent_writes) "yes" else "no", @tagName(result.safety.reinstall_policy) });
    try ctx.writer.print("\nEffective system\n  Locale        {s}\n  Timezone      {s}\n  Keyboard      {s}\n  Connectivity  {s}\n  Time sync     {s}\n  SSH           {s}\n  Password auth {s}\n  Root login    {s}\n  Root password {s}\n  Firewall      {s}\n  SELinux       {s}\n  Users         {d}\n  Packages      {d}\n", .{ result.effective_system.localization.locale, result.effective_system.localization.timezone, result.effective_system.localization.keyboard, result.effective_system.connectivity.mode, if (result.effective_system.connectivity.time_sync) "enabled" else "disabled", if (result.effective_system.ssh.enabled) "enabled" else "disabled", if (result.effective_system.ssh.password_authentication) "enabled" else "disabled", result.effective_system.ssh.root_login, if (result.effective_system.ssh.root_password_configured) "configured" else "not configured", result.effective_system.security.firewall, result.effective_system.security.selinux, result.effective_system.users.len, result.effective_system.packages.len });
    if (result.install_source) |source| {
        try ctx.writer.print("\nInstall source\n  Name          {s}\n  Label         {s}\n  Media tree    {s}\n  Repositories  {d}\n", .{ source.name, source.source_label orelse source.name, source.media_tree_url orelse "-", source.repositories.len });
    } else try ctx.writer.writeAll("\nInstall source  -\n");
    try ctx.writer.print("\nAssets ({d})\n", .{result.assets.len});
    for (result.assets) |asset| try ctx.writer.print("  {s}\n    Kind        {s}\n    Path        {s}\n    SHA-256     {s}\n", .{ asset.name, asset.kind, asset.path, asset.sha256 orelse "-" });
    try ctx.writer.print("\nNodes ({d})", .{result.nodes.len});
    if (result.nodes.len == 0) try ctx.writer.writeAll("\n  -\n") else {
        try ctx.writer.writeByte('\n');
        for (result.nodes) |node| try ctx.writer.print("  {s}\n", .{node});
    }
    try ctx.writer.print("\nModel revision\n  Config        {d}\n  Catalog       {d}\n", .{ result.model_revision.config, result.model_revision.catalog });
}

fn profileCreateHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const name = ctx.getArg("name") orelse return;
    const install_source = ctx.getArg("install-source") orelse return;
    if (!nodeforge.config_validate.validLogicalId(name) or !nodeforge.config_validate.validLogicalId(install_source)) {
        try ctx.writer.writeAll("error: profile create: name and install-source must be canonical logical identifiers\n");
        setExitCode(ctx, 2);
        return;
    }
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [256]u8 = undefined;
    const result = nodeforge.management_client.profileCreate(ctx.io, config.value.server.http_port, name, install_source, &reason);
    if (!result.healthy) {
        try reportMutationFailure(ctx, result, "profile create failed: daemon unreachable");
        return;
    }
    if (output_json)
        try ctx.writer.print("{{\"ok\":true,\"profile\":{f},\"mode\":\"install\",\"install_source\":{f}}}\n", .{ std.json.fmt(name, .{}), std.json.fmt(install_source, .{}) })
    else
        try views.success(ctx.writer, "install profile created", &.{ .{ .label = "Profile", .value = name }, .{ .label = "Install source", .value = install_source }, .{ .label = "Safety", .value = "destructive, persistent, explicit retry" } });
}

fn profileSetHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const name = ctx.getArg("name") orelse return;
    const property = ctx.getArg("property") orelse return;
    const kernel_prefix = "kernel_args=";
    const disk_prefix = "boot_disk=";
    if (std.mem.startsWith(u8, property, kernel_prefix) and property.len > kernel_prefix.len)
        return mutateProfileKernelArgs(ctx, name, property[kernel_prefix.len..], output_json, "profile kernel args updated");
    if (std.mem.startsWith(u8, property, disk_prefix) and property.len > disk_prefix.len)
        return mutateProfileBootDisk(ctx, name, property[disk_prefix.len..], output_json);
    return profilePropertyError(ctx, error.InvalidProfileProperty);
}

fn profileUnsetHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const name = ctx.getArg("name") orelse return;
    const property = ctx.getArg("property") orelse return;
    if (!std.mem.eql(u8, property, "kernel_args")) return profilePropertyError(ctx, error.InvalidKernelArgsProperty);
    try mutateProfileKernelArgs(ctx, name, null, output_json, "profile kernel args cleared");
}

fn mutateProfileKernelArgs(ctx: zli.CommandContext, name: []const u8, kernel_args: ?[]const u8, output_json: bool, summary: []const u8) !void {
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [256]u8 = undefined;
    const result = nodeforge.management_client.profileSetKernelArgs(ctx.io, config.value.server.http_port, name, kernel_args, &reason);
    if (!result.healthy) {
        try reportMutationFailure(ctx, result, "profile kernel args update failed: daemon unreachable");
        return;
    }
    if (output_json)
        try ctx.writer.print("{{\"ok\":true,\"profile\":{f},\"kernel_args\":{f}}}\n", .{ std.json.fmt(name, .{}), std.json.fmt(kernel_args, .{}) })
    else
        try views.success(ctx.writer, summary, &.{ .{ .label = "Profile", .value = name }, .{ .label = "Kernel args", .value = kernel_args orelse "-" }, .{ .label = "Install nodes", .value = "run node retry before the next install" } });
}

fn mutateProfileBootDisk(ctx: zli.CommandContext, name: []const u8, boot_disk: []const u8, output_json: bool) !void {
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [256]u8 = undefined;
    const result = nodeforge.management_client.profileSetBootDisk(ctx.io, config.value.server.http_port, name, boot_disk, &reason);
    if (!result.healthy) {
        try reportMutationFailure(ctx, result, "profile boot disk update failed: daemon unreachable");
        return;
    }
    if (output_json)
        try ctx.writer.print("{{\"ok\":true,\"profile\":{f},\"boot_disk\":{f}}}\n", .{ std.json.fmt(name, .{}), std.json.fmt(boot_disk, .{}) })
    else
        try views.success(ctx.writer, "profile boot disk updated", &.{ .{ .label = "Profile", .value = name }, .{ .label = "Boot disk", .value = boot_disk }, .{ .label = "Install nodes", .value = "run node retry before the next install" } });
}

fn profilePropertyError(ctx: zli.CommandContext, err: anyerror) void {
    ctx.writer.print("error: profile attributes: {s}; expected kernel_args=<value>, boot_disk=/dev/<device>, or unset kernel_args\n", .{@errorName(err)}) catch {};
    setExitCode(ctx, 2);
}

/// 离线 answer 预览有意使用明显的非密钥占位符。
/// 真实凭据仅通过已认证的 `/install-config/kickstart` 路由下发。
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
    const node = nodeforge.catalog.findNode(catalog.value(), node_id) orelse {
        try ctx.writer.print("error: install: unknown node {s}\n", .{node_id});
        setExitCode(ctx, 1);
        return;
    };
    const profile = nodeforge.catalog.findProfile(catalog.value(), node.profile) orelse {
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
    // APT 源 URL 解析：与 HTTP installConfig 保持一致的 fallback 逻辑。
    // Ubuntu ISO 导入时始终创建 repository，但手动配置场景可能缺失。
    const distro = nodeforge.catalog.findDistro(catalog.value(), source.distro) orelse {
        try ctx.writer.writeAll("error: install: distro unavailable\n");
        setExitCode(ctx, 1);
        return;
    };
    const apt_primary_url = if (distro.family == .ubuntu) blk: {
        const repository = nodeforge.catalog.findRepository(catalog.value(), source.name);
        if (repository) |repo| if (repo.manager == .apt) break :blk repo.base_url;
        break :blk try std.fmt.allocPrint(ctx.allocator, "http://{s}:{d}/artifacts/repositories/{s}", .{ config.value.server.server_ip, config.value.server.http_port, source.name });
    } else null;
    const event_url = try std.fmt.allocPrint(ctx.allocator, "http://{s}:{d}/api/v1/nodes/{s}/events", .{ config.value.server.server_ip, config.value.server.http_port, node.id });
    defer ctx.allocator.free(event_url);
    const bootstrap_key = try nodeforge.admin_key.resolve(ctx.io, ctx.allocator, config.value.server);
    defer ctx.allocator.free(bootstrap_key);
    const bundle = if (install.bundle) |name| findBundle(&config.value, name) else null;
    // M4.2：webhook 上报对所有 Ubuntu 版本可用（curtin handler 相同）
    const preview_report_url: []const u8 = if (distro.family == .ubuntu) "<report-url>" else "";
    const answer = if (distro.family == .ubuntu)
        try nodeforge.ubuntu_autoinstall.renderUserDataM41(ctx.allocator, node, install, system, bootstrap_key, bundle, apt_primary_url, "<facts-url>", event_url, "<log-url>", preview_report_url, "<boot-session>", "<capability>", &preview_scope, profile.kernel_args)
    else blk: {
        const install_root = try std.fmt.allocPrint(ctx.allocator, "http://{s}:{d}/artifacts/repositories/{s}", .{ config.value.server.server_ip, config.value.server.http_port, source.name });
        defer ctx.allocator.free(install_root);
        break :blk try nodeforge.kickstart.renderAnswerM41(ctx.allocator, node, install, system, bootstrap_key, install_root, bundle, "<facts-url>", event_url, "<log-url>", "<boot-session>", "<capability>", &preview_scope, profile.kernel_args);
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
    if (ctx.flag("force", bool)) {
        var reason: [256]u8 = undefined;
        const result = nodeforge.management_client.installGenerationsForce(ctx.io, config.value.server.http_port, node_id, &reason);
        if (!result.healthy) return reportMutationFailure(ctx, result, "forced install retry failed: daemon unreachable");
        if (output_json)
            try ctx.writer.print("{{\"ok\":true,\"node_id\":{f},\"superseded_active_session\":true}}\n", .{std.json.fmt(node_id, .{})})
        else
            try ctx.writer.print("active install session superseded; generation rearmed for {s}; waiting for next PXE\n", .{node_id});
        return;
    }
    var reason: [256]u8 = undefined;
    const result = nodeforge.management_client.installGenerations(ctx.io, config.value.server.http_port, node_id, &reason);
    if (!result.healthy) return reportMutationFailure(ctx, result, "install retry failed: daemon unreachable");
    if (output_json)
        try ctx.writer.print("{{\"ok\":true,\"node_id\":{f}}}\n", .{std.json.fmt(node_id, .{})})
    else
        try ctx.writer.print("install generation rearmed for {s}; waiting for next PXE\n", .{node_id});
}

// ── M4.2 node CRUD handlers ───────────────────────────────────────

/// M4.5：把管理写请求的失败结果映射为 CLI 结构化错误。`result.reason` 非空时
/// 直接输出服务端错误信封（code/message/request_id），否则（连接失败）输出
/// `fallback`。始终置非零退出码。
fn reportMutationFailure(ctx: zli.CommandContext, result: nodeforge.management_client.Mutation, fallback: []const u8) !void {
    if (result.reason.len > 0)
        try ctx.writer.print("error: {s}\n", .{result.reason})
    else
        try ctx.writer.print("error: {s}\n", .{fallback});
    setExitCode(ctx, 1);
}

fn nodeAddHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const config_path = ctx.flag("config", []const u8);
    const node_id = ctx.getArg("node_id") orelse return;
    const patch = parseNodeProperties(ctx.positional_args[1..]) catch |err| return nodePropertyError(ctx, err);
    const mac = patch.mac orelse return nodePropertyError(ctx, error.MissingRequiredAttribute);
    const arch = patch.arch orelse return nodePropertyError(ctx, error.MissingRequiredAttribute);
    const profile = patch.profile orelse return nodePropertyError(ctx, error.MissingRequiredAttribute);

    var config = loadConfig(ctx.io, ctx.allocator, config_path, ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .id = node_id, .mac = mac, .arch = arch, .profile = profile, .ip = patch.ip, .hostname = patch.hostname, .deploy = patch.deploy orelse true, .http_accel = patch.http_accel orelse false }, .{});
    defer ctx.allocator.free(body);
    var reason: [256]u8 = undefined;
    const node_result = nodeforge.management_client.nodeAdd(ctx.io, config.value.server.http_port, body, &reason);
    if (!node_result.healthy) {
        try reportMutationFailure(ctx, node_result, "node add failed: daemon unreachable");
        return;
    }
    if (output_json) try ctx.writer.print("{{\"ok\":true,\"node_id\":{f}}}\n", .{std.json.fmt(node_id, .{})}) else try views.success(ctx.writer, "node added", &.{ .{ .label = "Node", .value = node_id }, .{ .label = "MAC", .value = mac }, .{ .label = "Profile", .value = profile } });
}

fn nodeSetHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const config_path = ctx.flag("config", []const u8);
    const node_id = ctx.getArg("node_id") orelse return;
    const patch = parseNodeProperties(ctx.positional_args[1..]) catch |err| return nodePropertyError(ctx, err);
    var params: node_mutation.SetParams = .{ .mac = patch.mac, .arch = patch.arch, .profile = patch.profile, .deploy = patch.deploy, .http_accel = patch.http_accel };
    if (patch.ip) |value| {
        params.ip_set = true;
        params.ip = value;
    }
    if (patch.hostname) |value| {
        params.hostname_set = true;
        params.hostname = value;
    }

    var config = loadConfig(ctx.io, ctx.allocator, config_path, ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .mac = params.mac, .arch = params.arch, .profile = params.profile, .ip = if (params.ip_set) params.ip else null, .hostname = if (params.hostname_set) params.hostname else null, .deploy = params.deploy, .http_accel = params.http_accel }, .{ .emit_null_optional_fields = false });
    defer ctx.allocator.free(body);
    var reason: [256]u8 = undefined;
    const node_result = nodeforge.management_client.nodeSet(ctx.io, config.value.server.http_port, node_id, body, &reason);
    if (!node_result.healthy) {
        try reportMutationFailure(ctx, node_result, "node set failed: daemon unreachable");
        return;
    }
    if (output_json) try ctx.writer.print("{{\"ok\":true,\"node_id\":{f}}}\n", .{std.json.fmt(node_id, .{})}) else try views.success(ctx.writer, "node updated", &.{.{ .label = "Node", .value = node_id }});
}

fn nodeUnsetHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const config_path = ctx.flag("config", []const u8);
    const node_id = ctx.getArg("node_id") orelse return;
    var params: node_mutation.SetParams = .{};
    for (ctx.positional_args[1..]) |key| {
        if (std.mem.eql(u8, key, "ip")) {
            if (params.ip_set) return nodePropertyError(ctx, error.DuplicateAttribute);
            params.ip_set = true;
            params.ip = null;
        } else if (std.mem.eql(u8, key, "hostname")) {
            if (params.hostname_set) return nodePropertyError(ctx, error.DuplicateAttribute);
            params.hostname_set = true;
            params.hostname = null;
        } else return nodePropertyError(ctx, error.AttributeNotOptional);
    }
    var config = loadConfig(ctx.io, ctx.allocator, config_path, ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var unset: [2][]const u8 = undefined;
    var unset_len: usize = 0;
    if (params.ip_set) {
        unset[unset_len] = "ip";
        unset_len += 1;
    }
    if (params.hostname_set) {
        unset[unset_len] = "hostname";
        unset_len += 1;
    }
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .unset = unset[0..unset_len] }, .{});
    defer ctx.allocator.free(body);
    var reason: [256]u8 = undefined;
    const node_result = nodeforge.management_client.nodeSet(ctx.io, config.value.server.http_port, node_id, body, &reason);
    if (!node_result.healthy) {
        try reportMutationFailure(ctx, node_result, "node unset failed: daemon unreachable");
        return;
    }
    if (output_json) try ctx.writer.print("{{\"ok\":true,\"node_id\":{f}}}\n", .{std.json.fmt(node_id, .{})}) else try views.success(ctx.writer, "node attributes cleared", &.{.{ .label = "Node", .value = node_id }});
}

const NodeProperties = struct { mac: ?[]const u8 = null, arch: ?model.Arch = null, profile: ?[]const u8 = null, ip: ?[]const u8 = null, hostname: ?[]const u8 = null, deploy: ?bool = null, http_accel: ?bool = null };
fn parseNodeProperties(values: []const []const u8) !NodeProperties {
    var result: NodeProperties = .{};
    var seen: u8 = 0;
    for (values) |item| {
        const equal = std.mem.indexOfScalar(u8, item, '=') orelse return error.InvalidAttribute;
        const key = item[0..equal];
        const value = item[equal + 1 ..];
        if (key.len == 0 or value.len == 0) return error.InvalidAttribute;
        const bit: u8 = if (std.mem.eql(u8, key, "mac")) 1 else if (std.mem.eql(u8, key, "arch")) 2 else if (std.mem.eql(u8, key, "profile")) 4 else if (std.mem.eql(u8, key, "ip")) 8 else if (std.mem.eql(u8, key, "hostname")) 16 else if (std.mem.eql(u8, key, "deploy")) 32 else if (std.mem.eql(u8, key, "http_accel")) 64 else return error.UnknownAttribute;
        if (seen & bit != 0) return error.DuplicateAttribute;
        seen |= bit;
        switch (bit) {
            1 => result.mac = value,
            2 => result.arch = std.meta.stringToEnum(model.Arch, value) orelse return error.InvalidAttribute,
            4 => result.profile = value,
            8 => result.ip = value,
            16 => result.hostname = value,
            32 => result.deploy = parseStrictBool(value) orelse return error.InvalidAttribute,
            64 => result.http_accel = parseStrictBool(value) orelse return error.InvalidAttribute,
            else => unreachable,
        }
    }
    return result;
}
fn parseStrictBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}
fn nodePropertyError(ctx: zli.CommandContext, err: anyerror) void {
    ctx.writer.print("error: node attributes: {s}\n", .{@errorName(err)}) catch {};
    setExitCode(ctx, 2);
}

fn nodeRemoveHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const config_path = ctx.flag("config", []const u8);
    const node_id = ctx.getArg("node_id") orelse return;

    var config = loadConfig(ctx.io, ctx.allocator, config_path, ctx.writer, ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [256]u8 = undefined;
    const node_result = nodeforge.management_client.nodeRemove(ctx.io, config.value.server.http_port, node_id, &reason);
    if (!node_result.healthy) {
        try reportMutationFailure(ctx, node_result, "node remove failed: daemon unreachable");
        return;
    }
    if (output_json) try ctx.writer.print("{{\"ok\":true,\"node_id\":{f}}}\n", .{std.json.fmt(node_id, .{})}) else try views.success(ctx.writer, "node removed", &.{.{ .label = "Node", .value = node_id }});
}

fn nodeShowHandler(ctx: zli.CommandContext) !void {
    const output_json = outputJsonFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), ctx.writer, debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const node_id = ctx.getArg("node_id") orelse return;

    var response: [128 * 1024]u8 = undefined;
    const body = try nodeforge.management_client.nodesJson(ctx.io, config.value.server.http_port, node_id, &response);
    if (body == null) {
        try ctx.writer.print("error: node not found or daemon unavailable: {s}\n", .{node_id});
        setExitCode(ctx, 1);
        return;
    }
    if (output_json) {
        try ctx.writer.writeAll(body.?);
        return;
    }
    const Response = struct {
        result: struct {
            view_revision: struct { config: u64, catalog: u64, node_status: u64, deployment: u64, inventory: u64 },
            node: model.NodeConfig,
            profile: struct { name: []const u8, mode: []const u8, distro: []const u8, version: []const u8, arch: []const u8, install_source: ?[]const u8, boot_bundle: ?[]const u8, kernel_args: ?[]const u8, safety: model.ProfileSafetyConfig },
            effective_system: struct {
                localization: model.LocalizationConfig,
                connectivity: model.ConnectivityPolicy,
                ssh: struct { enabled: bool, password_authentication: bool, root_login: []const u8, root_password_configured: bool, root_authorized_key_count: usize },
                security: model.TargetSecurityConfig,
                users: []const struct { name: []const u8, sudo: bool, password_configured: bool, authorized_key_count: usize },
                packages: []const []const u8,
            },
            status: ?struct { phase: []const u8, boot_session_id: []const u8, model_revision: u64, deployment_generation: u64, last_event_at: i64, last_error: bool, reason: []const u8, session_active: bool },
            deployment: ?struct {
                install_intent: []const u8,
                pxe_ready: bool,
                retry_pending: bool,
                current_generation: ?u64,
                armed_generation: ?u64,
                consumed_generation: ?u64,
                terminal_generation: ?u64,
                requested_revision: u64,
                applied_revision: u64,
                desired_revision: u64,
                requested_plan_digest: ?[]const u8,
                applied_plan_digest: ?[]const u8,
                desired_plan_digest: []const u8,
                drifted: bool,
                drift_state: []const u8,
                requested_by: []const u8,
                start_at: i64,
                install_at: i64,
                finished_at: i64,
                successful_generation: u64,
                deployed_at: i64,
            },
            inventory: ?struct { serial_number: ?[]const u8, product_uuid: ?[]const u8, vendor: ?[]const u8, model: ?[]const u8, reported_at: i64, deployment_generation: u64 = 0, session_created_at: i64, boot_session_id: []const u8 },
        },
    };
    var parsed = std.json.parseFromSlice(Response, ctx.allocator, body.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
        try ctx.writer.writeAll("error: node: malformed daemon response\n");
        setExitCode(ctx, 1);
        return;
    };
    defer parsed.deinit();
    const result = parsed.value.result;
    try views.nodeDetail(ctx.writer, result.node);
    try ctx.writer.print("\nProfile\n  Name          {s}\n  Mode          {s}\n  Platform      {s} {s} ({s})\n  Install src   {s}\n  Boot bundle   {s}\n  Kernel args   {s}\n  Unknown safe  {s}\n  Destructive   {s}\n  Persistent    {s}\n  Reinstall     {s}\n  More          nodeforge profile show {s}\n", .{ result.profile.name, result.profile.mode, result.profile.distro, result.profile.version, result.profile.arch, result.profile.install_source orelse "-", result.profile.boot_bundle orelse "-", result.profile.kernel_args orelse "-", if (result.profile.safety.safe_for_unknown) "yes" else "no", if (result.profile.safety.destructive) "yes" else "no", if (result.profile.safety.persistent_writes) "yes" else "no", @tagName(result.profile.safety.reinstall_policy), result.profile.name });
    // M4.11 ownership map: cross-resource stored facts keep their real model
    // key, but point at the owning command instead of pretending `node set`
    // can mutate them. Derived/runtime/audit projections are explicitly marked
    // read-only below.
    try ctx.writer.print("\nOwner / action\n  profile.kernel_args\n    owner         profile:{s}\n    action        nodeforge profile set {s} 'kernel_args=<arguments>'\n  profile.*\n    owner         profile:{s}\n    action        nodeforge profile show {s}\n  deployment.*\n    owner         nodeforged lifecycle\n    action        nodeforge node retry {s} [--force]\n  runtime.*\n    owner         nodeforged runtime\n    action        read-only\n  inventory.*\n    owner         node-reported inventory\n    action        read-only\n  view_revision.*\n    owner         nodeforged model store\n    action        read-only\n", .{ result.profile.name, result.profile.name, result.profile.name, result.profile.name, result.node.id });
    try ctx.writer.print("\nEffective system\n  Locale        {s}\n  Timezone      {s}\n  Keyboard      {s}\n  Connectivity  {s}\n  Time sync     {s}\n  SSH           {s}\n  Password auth {s}\n  Root login    {s}\n  Root password {s}\n  Root keys     {d}\n  Firewall      {s}\n  SELinux       {s}\n", .{ result.effective_system.localization.locale, result.effective_system.localization.timezone, result.effective_system.localization.keyboard, @tagName(result.effective_system.connectivity.mode), if (result.effective_system.connectivity.time_sync) "enabled" else "disabled", if (result.effective_system.ssh.enabled) "enabled" else "disabled", if (result.effective_system.ssh.password_authentication) "enabled" else "disabled", result.effective_system.ssh.root_login, if (result.effective_system.ssh.root_password_configured) "configured" else "not configured", result.effective_system.ssh.root_authorized_key_count, @tagName(result.effective_system.security.firewall), @tagName(result.effective_system.security.selinux) });
    try ctx.writer.print("  NTP servers   {d}\n", .{result.effective_system.connectivity.ntp_servers.len});
    for (result.effective_system.connectivity.ntp_servers) |server| try ctx.writer.print("    - {s}\n", .{server});
    try ctx.writer.print("  Users         {d}\n", .{result.effective_system.users.len});
    for (result.effective_system.users) |user| try ctx.writer.print("    - {s}: sudo={s} password={s} keys={d}\n", .{ user.name, if (user.sudo) "yes" else "no", if (user.password_configured) "configured" else "not configured", user.authorized_key_count });
    try ctx.writer.print("  Packages      {d}\n", .{result.effective_system.packages.len});
    for (result.effective_system.packages) |package| try ctx.writer.print("    - {s}\n", .{package});

    // 人类视图使用本地 24 小时时间；JSON 保留 epoch。Start/Install/Finished
    // 分别是任务武装、实际安装阶段和终态，不再复用含糊的 Started 标签。
    var last_event_buf: [20]u8 = undefined;
    var start_buf: [20]u8 = undefined;
    var install_buf: [20]u8 = undefined;
    var finished_buf: [20]u8 = undefined;
    var deployed_buf: [20]u8 = undefined;
    var reported_buf: [20]u8 = undefined;
    var source_session_buf: [20]u8 = undefined;
    try ctx.writer.writeAll("\nDeployment\n");
    if (result.deployment) |deployment| {
        try ctx.writer.print("  Intent        {s}\n  PXE ready     {s}\n  Retry pending {s}\n  Current gen   {f}\n  Armed gen     {f}\n  Consumed gen  {f}\n  Terminal gen  {f}\n  Requested plan {s}\n  Applied plan  {s}\n  Desired plan  {s}\n  Drift state   {s}\n  Legacy req rev {d}\n  Legacy app rev {d}\n  Legacy des rev {d}\n  Requested by  {s}\n  Start         {s}\n  Install       {s}\n  Finished      {s}\n  Success gen   {d}\n  Deployed      {s}\n", .{ deployment.install_intent, if (deployment.pxe_ready) "yes" else "no", if (deployment.retry_pending) "yes" else "no", std.json.fmt(deployment.current_generation, .{}), std.json.fmt(deployment.armed_generation, .{}), std.json.fmt(deployment.consumed_generation, .{}), std.json.fmt(deployment.terminal_generation, .{}), digestPrefix(deployment.requested_plan_digest), digestPrefix(deployment.applied_plan_digest), digestPrefix(deployment.desired_plan_digest), deployment.drift_state, deployment.requested_revision, deployment.applied_revision, deployment.desired_revision, deployment.requested_by, views.formatTimestamp(&start_buf, deployment.start_at), views.formatTimestamp(&install_buf, deployment.install_at), views.formatTimestamp(&finished_buf, deployment.finished_at), deployment.successful_generation, views.formatTimestamp(&deployed_buf, deployment.deployed_at) });
    } else try ctx.writer.writeAll("  Generation   -\n");
    try ctx.writer.writeAll("\nRuntime\n");
    if (result.status) |status| try ctx.writer.print("  Phase         {s}\n  Active        {s}\n  Last error    {s}\n  Last event    {s}\n  Reason        {s}\n  Session       {s}\n  Model rev     {d}\n  Generation    {d}\n", .{ status.phase, if (status.session_active) "yes" else "no", if (status.last_error) "yes" else "no", views.formatTimestamp(&last_event_buf, status.last_event_at), if (status.reason.len == 0) "-" else status.reason, status.boot_session_id, status.model_revision, status.deployment_generation }) else try ctx.writer.writeAll("  Phase         -\n");
    try ctx.writer.writeAll("\nInventory\n");
    if (result.inventory) |inventory| try ctx.writer.print("  SN            {s}\n  UUID          {s}\n  Vendor        {s}\n  Model         {s}\n  Generation    {d}\n  Session       {s}\n  Session start {s}\n  Reported      {s}\n", .{ inventory.serial_number orelse "-", inventory.product_uuid orelse "-", inventory.vendor orelse "-", inventory.model orelse "-", inventory.deployment_generation, inventory.boot_session_id, views.formatTimestamp(&source_session_buf, inventory.session_created_at), views.formatTimestamp(&reported_buf, inventory.reported_at) }) else try ctx.writer.writeAll("  SN            -\n");
    try ctx.writer.print("\nView revisions\n  Config        {d}\n  Catalog       {d}\n  Node status   {d}\n  Deployment    {d}\n  Inventory     {d}\n", .{ result.view_revision.config, result.view_revision.catalog, result.view_revision.node_status, result.view_revision.deployment, result.view_revision.inventory });
}

fn digestPrefix(value: ?[]const u8) []const u8 {
    const digest = value orelse return "-";
    return digest[0..@min(digest.len, 12)];
}

fn printMutationError(ctx: zli.CommandContext, err: anyerror, action: []const u8, node_id: []const u8) !void {
    const msg = switch (err) {
        error.NodeAlreadyExists => "node already exists",
        error.NodeNotFound => "node not found",
        error.DuplicateMac => "duplicate MAC address",
        error.InvalidArch => "invalid architecture",
        error.ProfileNotFound => "profile not found in config",
        error.SaveFailed => "failed to save config.json",
        else => @errorName(err),
    };
    try ctx.writer.print("error: node {s} failed for {s}: {s}\n", .{ action, node_id, msg });
}

/// 节点配置已经原子写盘后，请求 daemon 有序退出并由 systemd 重启加载。
/// reload 失败不能回滚已持久化配置，因此错误信息必须明确区分“写盘成功”与
/// “运行态尚未切换”，避免 CLI 错报整次 mutation 成功。
fn requestNodeConfigReload(ctx: zli.CommandContext, port: u16, node_id: []const u8) !bool {
    const status = nodeforge.management_client.managementStatus(ctx.io, port);
    if (status.healthy) return true;
    try ctx.writer.print("error: node config saved for {s}, but daemon reload was not requested; restart nodeforged manually\n", .{node_id});
    setExitCode(ctx, 1);
    return false;
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
    var ts_buf: [1000][20]u8 = undefined;
    for (rows[0..result.count], 0..) |event, index| display[index] = .{
        .ts = cli_events.displayTs(&ts_buf[index], event.ts),
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
            } else {
                var follow_ts_buf: [20]u8 = undefined;
                try views.eventLine(ctx.writer, cli_events.displayTs(&follow_ts_buf, event.ts), event.type, try cli_events.fieldsText(ctx.allocator, event.fields), event.message);
            }
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
        var trace_ts_buf: [20]u8 = undefined;
        for (trace_events[0..trace_count]) |event| try views.eventLine(ctx.writer, cli_events.displayTs(&trace_ts_buf, event.ts), event.type, try cli_events.fieldsText(ctx.allocator, event.fields), event.message);
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
        .{ .name = "events-path", .description = "Local Event JSONL path (development or recovery override)", .type = .String, .default_value = .{ .String = nodeforge.paths.require().events_path } },
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
        .default_value = .{ .String = nodeforge.config.defaultPath() },
    });
}

/// 为一个命令声明默认 catalog 路径覆盖参数。
fn addCatalogPathFlag(command: *zli.Command) !void {
    try command.addFlag(.{
        .name = "catalog",
        .shortcut = "C",
        .description = "Catalog JSON path",
        .type = .String,
        .default_value = .{ .String = nodeforge.catalog_store.defaultPath() },
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

/// M4.11 canonical readiness probe. A healthy `/healthz` alone is insufficient:
/// operators need proof that the configured advertised listener and each
/// management plane needed for provisioning are usable in the running daemon.
fn statusCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    config_path: []const u8,
    output_json: bool,
    debug: bool,
    out: *std.Io.Writer,
) !u8 {
    var parsed_config = loadConfig(io, allocator, config_path, out, debug) orelse return 1;
    defer parsed_config.deinit();
    const port = parsed_config.value.server.http_port;
    const server_ip = parsed_config.value.server.server_ip;
    const status = nodeforge.management_client.managementStatus(io, port);
    const loopback_health = nodeforge.management_client.health(io, port);
    const advertised_health = nodeforge.management_client.healthAt(io, server_ip, port);
    const active_config = nodeforge.management_client.validateActiveConfig(io, parsed_config.value.server.http_port);
    const tftp = nodeforge.management_client.tftpCounters(io, port);

    var nodes_buffer: [128 * 1024]u8 = undefined;
    const nodes_api = (nodeforge.management_client.nodesJson(io, port, null, &nodes_buffer) catch null) != null;
    var profiles_buffer: [128 * 1024]u8 = undefined;
    const profiles_api = (nodeforge.management_client.profilesJson(io, port, null, &profiles_buffer) catch null) != null;
    const catalog_api = nodes_api and profiles_api;
    var dhcp_buffer: [128 * 1024]u8 = undefined;
    const dhcp_api = (nodeforge.management_client.dhcpLeasesJson(io, port, false, &dhcp_buffer) catch null) != null;

    const ok = status.healthy and loopback_health.healthy and advertised_health.healthy and active_config.healthy and catalog_api and dhcp_api and tftp.healthy;
    if (output_json) {
        const advertised_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ server_ip, port });
        defer allocator.free(advertised_url);
        try out.print(
            "{{\"ok\":{s},\"checks\":{{\"process\":{s},\"loopback_http\":{s},\"advertised_http\":{s},\"management_api\":{s},\"active_config\":{s},\"catalog_api\":{s},\"dhcp_api\":{s},\"tftp_api\":{s}}},\"advertised_url\":{f},\"tftp_transfers\":{{\"started\":{d},\"completed\":{d},\"failed\":{d}}}}}\n",
            .{
                jsonBool(ok),
                jsonBool(status.reachable),
                jsonBool(loopback_health.healthy),
                jsonBool(advertised_health.healthy),
                jsonBool(status.healthy),
                jsonBool(active_config.healthy),
                jsonBool(catalog_api),
                jsonBool(dhcp_api),
                jsonBool(tftp.healthy),
                std.json.fmt(advertised_url, .{}),
                tftp.started,
                tftp.completed,
                tftp.failed,
            },
        );
        return if (ok) 0 else 1;
    }

    try views.status(out, .{
        .ok = ok,
        .process = status.reachable,
        .loopback_http = loopback_health.healthy,
        .advertised_http = advertised_health.healthy,
        .management_api = status.healthy,
        .active_config = active_config.healthy,
        .catalog_api = catalog_api,
        .dhcp_api = dhcp_api,
        .tftp_api = tftp.healthy,
        .server_ip = server_ip,
        .port = port,
        .tftp_started = tftp.started,
        .tftp_completed = tftp.completed,
        .tftp_failed = tftp.failed,
    });
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
    try out.print("nodeforge {s} (commit {s}, built {s}, {s})\n", .{
        nodeforge.version.version,
        nodeforge.version.shortCommit(),
        nodeforge.version.build_time,
        if (nodeforge.version.git_dirty) "dirty" else "clean",
    });
}
