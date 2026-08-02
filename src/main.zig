//! `nodeforge` M0 管理命令行入口。
//! zli 持有唯一命令树并据此完成解析、校验和帮助生成；业务语义仍委托核心库。
//! 退出码约定：0 表示成功，1 表示业务检查或运行失败，2 表示命令行用法错误。

const std = @import("std");
const zli = @import("zli");
const nodeforge = @import("nodeforge");
const views = @import("nodeforge").cli_views;
const cli_output = @import("nodeforge").cli_output;
const cli_properties = @import("nodeforge").cli_properties;
const cli_events = @import("nodeforge").cli_events;
const model = @import("nodeforge").model;
const node_mutation = @import("nodeforge").node_mutation;

// zli 当前把有限选项 flag 建模为字符串。所有合法值必须保存在普通 flag
// description 中；`--help` 与 `--help-full` 共享这份元数据，操作员不应通过
// 阅读源码或故意触发失败请求才能发现可选值。
const archFlagHelp = "Architecture; allowed: x86_64, aarch64";
const softwareKindFlagHelp = "Capability kind filter; allowed: environment, group, task, metapackage, package; omit to list all kinds (DNF: environment/group/package; APT: task/metapackage/package)";
const requiredSoftwareKindFlagHelp = "Capability kind; allowed: environment, group, task, metapackage, package (DNF: environment/group/package; APT: task/metapackage/package)";
const assetKindFlagHelp = "Asset kind; allowed: iso, bootloader, kernel, runtime_kernel, installer_initrd, nodeforge_initrd, rootfs, gpg_key, managed_file, archive, script";
const structuredInputFlagHelp = "Input format; allowed: yaml, json";

/// 常规 management JSON 响应的统一上限。
///
/// 集合接口过去分别使用 8 KiB～256 KiB 的栈数组，同一规模的数据会因命令不同
/// 而表现为成功或 `ResponseTooLarge`。统一改为 2 MiB 堆缓冲；软件能力索引等已知
/// 大对象仍使用各自更高、可解释的上限。
const managementResponseCapacity: usize = 2 * 1024 * 1024;

fn allocManagementResponse(ctx: zli.CommandContext) ![]u8 {
    return ctx.allocator.alloc(u8, managementResponseCapacity);
}

fn expectEnumHelpComplete(comptime Enum: type, help: []const u8) !void {
    inline for (@typeInfo(Enum).@"enum".fields) |field| {
        var words = std.mem.tokenizeAny(u8, help, " \t,;:()");
        var found = false;
        while (words.next()) |word| {
            if (std.mem.eql(u8, word, field.name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "closed-choice flag help lists every model enum value" {
    try expectEnumHelpComplete(model.Arch, archFlagHelp);
    try expectEnumHelpComplete(model.SoftwareKind, softwareKindFlagHelp);
    try expectEnumHelpComplete(model.SoftwareKind, requiredSoftwareKindFlagHelp);
    try expectEnumHelpComplete(model.AssetKind, assetKindFlagHelp);
}

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = nodeforge.log_backend.logFn };

/// zli handler 共享的可变执行结果。
/// handler 本身返回错误只用于传播内部故障；可预期的业务失败通过此状态返回退出码。
const CliState = struct {
    /// 最终进程退出码，默认成功。
    exit_code: u8 = 0,
    err_writer: *std.Io.Writer,
};

/// zli 用于 `--version` 元数据的编译期语义版本。
const semantic_version = std.SemanticVersion.parse(nodeforge.version.version) catch unreachable;

/// 初始化标准 IO，执行 CLI，并将命令结果转换为进程退出状态。
pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.Writer.init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_file.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = std.Io.File.Writer.init(.stderr(), init.io, &stderr_buffer);
    const err_out = &stderr_file.interface;
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file = std.Io.File.Reader.init(.stdin(), init.io, &stdin_buffer);

    // `--version` 是纯构建溯源查询，不依赖安装根。必须和 daemon 一样在 paths
    // bootstrap 前短路，否则尚未 setup 的发布包无法执行最基本的版本核验。
    if (versionOnly(init.minimal.args)) {
        try printVersion(out);
        try out.flush();
        return;
    }

    nodeforge.paths.bootstrap(init.io, init.arena.allocator(), init.minimal.args) catch |err| {
        try out.print("error: install root bootstrap failed: {t}\n", .{err});
        try out.flush();
        std.process.exit(1);
    };

    const exit_code = try run(init, out, err_out, &stdin_file.interface);
    out.flush() catch {};
    err_out.flush() catch {};
    if (exit_code != 0) std.process.exit(exit_code);
}

/// 仅接受根命令的单独 `--version`/`-v`；嵌套命令中的同名参数仍交给 zli
/// 按用法错误处理，不能借快速路径绕过正常命令校验。
fn versionOnly(args: std.process.Args) bool {
    var iterator = args.iterate();
    _ = iterator.next();
    const flag = iterator.next() orelse return false;
    return (std.mem.eql(u8, flag, "--version") or std.mem.eql(u8, flag, "-v")) and iterator.next() == null;
}

/// 构建命令树并执行一次参数解析。
/// zli 的语法错误统一映射为退出码 2，未分类内部错误映射为退出码 1。
fn run(init: std.process.Init, out: *std.Io.Writer, err_out: *std.Io.Writer, in: *std.Io.Reader) !u8 {
    const root = try buildCli(.{
        .allocator = init.arena.allocator(),
        .io = init.io,
        .writer = out,
        .reader = in,
        .full_help_fn = renderFullHelp,
    });
    defer root.deinit();

    var state: CliState = .{ .err_writer = err_out };
    var args_iter = init.minimal.args.iterate();
    root.execute(&args_iter, .{ .data = &state }) catch |err| {
        if (isUsageError(err)) return 2;
        try err_out.print("error: internal: {t}\n", .{err});
        return 1;
    };
    return state.exit_code;
}

fn renderFullHelp(command: *zli.Command) std.Io.Writer.Error!void {
    const writer = command.init_options.writer;
    const owner = commandOwner(command);
    try writer.writeAll("\nDetailed help\n");
    if (owner) |value| {
        try writer.writeAll("\nScalar properties\nKEY\tTYPE\tVALUES/CONSTRAINT\tOPTIONAL\tAPPLICABILITY\n");
        for (cli_properties.properties) |spec| {
            if (spec.owner != value or spec.mutability != .mutable) continue;
            try writer.print("{s}\t{s}\t{s}\t{s}\t{s}\n", .{ spec.path, @tagName(spec.kind), cli_properties.valueConstraint(spec.kind, spec.value_constraint), if (spec.optional) "true" else "false", @tagName(spec.applicability) });
        }
        try writer.writeAll("\nCollection properties\nKEY\tSEMANTICS\tOPERATIONS\n");
        for (cli_properties.collections) |spec| {
            if (spec.owner != value or spec.mutability != .mutable) continue;
            try writer.print("{s}\t{s}\tlist, add, remove, replace, clear\n", .{ spec.path, @tagName(spec.semantics) });
            if (spec.item_spec) |item_name| if (findItemSpec(item_name)) |item| {
                try writer.print("  item {s}; identity={s}; fields=", .{ item.name, item.identity });
                for (item.fields, 0..) |field, index| try writer.print("{s}{s}:{s}[{s}]{s}", .{ if (index == 0) "" else ",", field.name, @tagName(field.kind), cli_properties.valueConstraint(field.kind, field.value_constraint), if (field.required) "!" else "" });
                try writer.writeByte('\n');
                for (item.collections) |field| try writer.print("  item collection {s}.{s}; operations=list, add, remove, replace, clear\n", .{ item.name, field.name });
            };
        }
        try writer.writeAll("\nBehavior\n  Keys are canonical persisted/API paths. Mutations are atomic and validated before publication.\n  Collections use values/item commands; clear on Node overrides restores Profile inheritance where applicable.\n");
    } else {
        try writer.writeAll("  This leaf command has no mutable PropertySpec. It validates all inputs before accessing deployment state.\n");
    }
}

fn commandOwner(command: *const zli.Command) ?cli_properties.Owner {
    const leaf = command.cmd_options.name;
    const scalar_or_collection = std.mem.eql(u8, leaf, "set") or std.mem.eql(u8, leaf, "unset") or std.mem.eql(u8, leaf, "list-values") or std.mem.eql(u8, leaf, "add-values") or std.mem.eql(u8, leaf, "remove-values") or std.mem.eql(u8, leaf, "replace-values") or std.mem.eql(u8, leaf, "clear-values") or std.mem.eql(u8, leaf, "replace-items") or std.mem.eql(u8, leaf, "clear-items");
    var structured_item = false;
    var probe = command.parent;
    while (probe) |item| : (probe = item.parent) {
        if (std.mem.eql(u8, item.cmd_options.name, "item")) structured_item = true;
    }
    if (!scalar_or_collection and !structured_item) return null;
    var current: ?*const zli.Command = command;
    while (current) |item| : (current = item.parent) {
        if (std.mem.eql(u8, item.cmd_options.name, "node")) return .node;
        if (std.mem.eql(u8, item.cmd_options.name, "profile")) return .profile;
        if (std.mem.eql(u8, item.cmd_options.name, "assets")) return .assets;
        if (std.mem.eql(u8, item.cmd_options.name, "discovery")) return .site;
    }
    return null;
}

fn findItemSpec(name: []const u8) ?*const cli_properties.ItemSpec {
    for (&cli_properties.items) |*item| if (std.mem.eql(u8, item.name, name)) return item;
    return null;
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

    const operation = try zli.Command.init(init_options, .{ .name = "operation", .description = "Inspect and wait for durable management operations" }, showCurrentHelp);
    const operation_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List retained durable operations" }, operationListHandler);
    try addConfigPathFlag(operation_list);
    try addOutputFlag(operation_list);
    try addDebugFlag(operation_list);
    const operation_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show one durable operation", .usage = "nodeforge operation show <id> [options]" }, operationShowHandler);
    try operation_show.addPositionalArg(.{ .name = "id", .description = "Opaque operation identifier", .required = true });
    try addConfigPathFlag(operation_show);
    try addOutputFlag(operation_show);
    try addDebugFlag(operation_show);
    const operation_wait = try zli.Command.init(init_options, .{ .name = "wait", .description = "Wait for one durable operation to reach a terminal state", .usage = "nodeforge operation wait <id> [--timeout <seconds>] [options]" }, operationWaitHandler);
    try operation_wait.addPositionalArg(.{ .name = "id", .description = "Opaque operation identifier", .required = true });
    try operation_wait.addFlag(.{ .name = "timeout", .description = "Maximum seconds to wait without cancelling; allowed range: 1..86400 (default: 300)", .type = .Int, .default_value = .{ .Int = 300 } });
    try addConfigPathFlag(operation_wait);
    try addOutputFlag(operation_wait);
    try addDebugFlag(operation_wait);
    const operation_follow = try zli.Command.init(init_options, .{ .name = "follow", .description = "Follow one durable operation to a terminal state", .usage = "nodeforge operation follow <id> [--timeout <seconds>] [options]" }, operationWaitHandler);
    try operation_follow.addPositionalArg(.{ .name = "id", .description = "Opaque operation identifier", .required = true });
    try operation_follow.addFlag(.{ .name = "timeout", .description = "Maximum seconds to follow without cancelling; allowed range: 1..86400 (default: 300)", .type = .Int, .default_value = .{ .Int = 300 } });
    try addConfigPathFlag(operation_follow);
    try addOutputFlag(operation_follow);
    try addDebugFlag(operation_follow);
    try operation.addCommands(&.{ operation_list, operation_show, operation_follow, operation_wait });

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
    // 迁移命令已移除：开发阶段 setup 始终生成最新 schema 版本，不需要手动迁移。
    try catalog.addCommands(&.{
        catalog_validate,
        catalog_export,
        catalog_show,
    });

    // ── node 资源（节点 CRUD + 部署生命周期）──────────────────────────
    const node = try zli.Command.init(init_options, .{
        .name = "node",
        .description = "Manage registered nodes and deployment lifecycle",
        .usage = "nodeforge node <list|show|add|set|remove|render|retry|trace> [options]",
    }, showCurrentHelp);

    const node_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List registered nodes" }, nodeListHandler);
    try node_list.addFlag(.{ .name = "long", .shortcut = "l", .description = "Show the full table, including armed/install/finished timestamps", .type = .Bool, .default_value = .{ .Bool = false } });
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
        .help = "Use exact mutable Node PropertySpec keys. Collections require values commands; structured collections require item commands.",
    }, nodeSetHandler);
    try node_set.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try node_set.addPositionalArg(.{ .name = "properties", .description = "Typed properties as key=value", .required = true, .variadic = true });
    try addConfigPathFlag(node_set);
    try addOutputFlag(node_set);
    try addDebugFlag(node_set);
    try node_set.addFlag(.{ .name = "force", .description = "Terminate active sessions (install/diskless) on the target node before mutation", .type = .Bool, .default_value = .{ .Bool = false } });

    const node_unset = try zli.Command.init(init_options, .{
        .name = "unset",
        .description = "Clear optional stored node properties",
        .usage = "nodeforge node unset <node_id> <key>... [options]",
        .help = "Unset optional Node direct or overrides.* scalar keys. Clearing an override restores Profile inheritance.",
    }, nodeUnsetHandler);
    try node_unset.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try node_unset.addPositionalArg(.{ .name = "keys", .description = "One or more optional property keys to clear", .required = true, .variadic = true });
    try addConfigPathFlag(node_unset);
    try addOutputFlag(node_unset);
    try addDebugFlag(node_unset);
    try node_unset.addFlag(.{ .name = "force", .description = "Terminate active sessions (install/diskless) on the target node before mutation", .type = .Bool, .default_value = .{ .Bool = false } });

    const node_remove = try zli.Command.init(init_options, .{ .name = "remove", .description = "Remove a registered node" }, nodeRemoveHandler);
    try node_remove.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try addConfigPathFlag(node_remove);
    try addOutputFlag(node_remove);
    try addDebugFlag(node_remove);

    const node_render = try zli.Command.init(init_options, .{ .name = "render", .description = "Render the unattended install answer for one node" }, installRenderHandler);
    try node_render.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try addConfigPathFlag(node_render);
    try addCatalogPathFlag(node_render);
    try addDebugFlag(node_render);

    const node_retry = try zli.Command.init(init_options, .{ .name = "retry", .description = "Retry the current install or diskless deployment" }, installRetryHandler);
    try node_retry.addPositionalArg(.{ .name = "node_id", .description = "Registered node", .required = true });
    try node_retry.addFlag(.{ .name = "force", .description = "Supersede a stuck active install or diskless session", .type = .Bool, .default_value = .{ .Bool = false } });
    try addConfigPathFlag(node_retry);
    try addOutputFlag(node_retry);
    try addDebugFlag(node_retry);
    const node_deploy = try zli.Command.init(init_options, .{ .name = "deploy", .description = "Enable or disable the node deployment gate", .usage = "nodeforge node deploy <node_id> [true|false] [options]" }, nodeDeployHandler);
    try node_deploy.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try node_deploy.addPositionalArg(.{ .name = "enabled", .description = "Deployment gate value: true or false (default: true)", .required = false });
    try node_deploy.addFlag(.{ .name = "force", .description = "Terminate active sessions (install/diskless) on the target node before mutation", .type = .Bool, .default_value = .{ .Bool = false } });
    try addConfigPathFlag(node_deploy);
    try addOutputFlag(node_deploy);
    try addDebugFlag(node_deploy);

    const node_claim = try zli.Command.init(init_options, .{
        .name = "claim",
        .description = "Atomically claim a persistent unknown-client observation",
        .usage = "nodeforge node claim <node_id> discovery.mac=<mac> arch=<arch> --observation-revision <revision> [options]",
    }, nodeClaimHandler);
    try node_claim.addPositionalArg(.{ .name = "node_id", .description = "Node identifier to create or update", .required = true });
    try node_claim.addPositionalArg(.{ .name = "properties", .description = "discovery.mac=<mac> and arch=<arch>", .required = true, .variadic = true });
    try node_claim.addFlag(.{ .name = "observation-revision", .description = "Exact positive observation revision from `discovery show`; must be >0", .type = .Int, .default_value = .{ .Int = 0 } });
    try addConfigPathFlag(node_claim);
    try addOutputFlag(node_claim);
    try addDebugFlag(node_claim);

    const node_trace = try zli.Command.init(init_options, .{
        .name = "trace",
        .description = "Reconstruct one node boot-session timeline from local events",
        .usage = "nodeforge node trace <node_id> [--session <id>] [--latest] [options]",
    }, traceHandler);
    try node_trace.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try node_trace.addFlags(&.{
        .{ .name = "session", .description = "Exact 32-character boot session identifier", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "latest", .description = "Select the latest retained session (default behavior; mutually exclusive with --session)", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "events-path", .description = "Local Event JSONL path (development or recovery override)", .type = .String, .default_value = .{ .String = nodeforge.paths.require().events_path } },
    });
    try addOutputFlag(node_trace);

    const node_boot = try zli.Command.init(init_options, .{ .name = "boot", .description = "Inspect the next boot decision" }, showCurrentHelp);
    const node_boot_preview = try zli.Command.init(init_options, .{ .name = "preview", .description = "Preview the next boot without creating a session or token" }, nodeBootPreviewHandler);
    try node_boot_preview.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try addConfigPathFlag(node_boot_preview);
    try addOutputFlag(node_boot_preview);
    try addDebugFlag(node_boot_preview);
    try node_boot.addCommands(&.{node_boot_preview});

    const node_readiness = try zli.Command.init(init_options, .{
        .name = "readiness",
        .description = "Verify diskless build or boot readiness without creating a session",
        .usage = "nodeforge node readiness <node_id> --stage <build|boot> [options]",
    }, nodeReadinessHandler);
    try node_readiness.addPositionalArg(.{ .name = "node_id", .description = "Registered diskless node identifier", .required = true });
    try node_readiness.addFlag(.{ .name = "stage", .description = "Readiness stage; allowed: build, boot (default: boot)", .type = .String, .default_value = .{ .String = "boot" } });
    try addConfigPathFlag(node_readiness);
    try addOutputFlag(node_readiness);
    try addDebugFlag(node_readiness);

    const node_session = try zli.Command.init(init_options, .{ .name = "session", .description = "Inspect and cancel diskless delivery sessions" }, showCurrentHelp);
    const node_session_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List active diskless delivery sessions" }, disklessSessionListHandler);
    try addConfigPathFlag(node_session_list);
    try addOutputFlag(node_session_list);
    try addDebugFlag(node_session_list);
    const node_session_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show an active diskless delivery session" }, disklessSessionShowHandler);
    try node_session_show.addPositionalArg(.{ .name = "session_id", .description = "32-character delivery session identifier", .required = true });
    try addConfigPathFlag(node_session_show);
    try addOutputFlag(node_session_show);
    try addDebugFlag(node_session_show);
    const node_session_cancel = try zli.Command.init(init_options, .{ .name = "cancel", .description = "Cancel a delivery session and revoke all of its capabilities" }, disklessSessionCancelHandler);
    try node_session_cancel.addPositionalArg(.{ .name = "session_id", .description = "32-character delivery session identifier", .required = true });
    try addConfigPathFlag(node_session_cancel);
    try addOutputFlag(node_session_cancel);
    try addDebugFlag(node_session_cancel);
    try node_session.addCommands(&.{ node_session_list, node_session_show, node_session_cancel });
    const node_postprocess = try zli.Command.init(init_options, .{ .name = "postprocess", .description = "Inspect post-deployment execution state" }, showCurrentHelp);
    const node_postprocess_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show postprocess state for a node" }, nodePostprocessShowHandler);
    try node_postprocess_show.addPositionalArg(.{ .name = "node_id", .description = "Registered node identifier", .required = true });
    try node_postprocess_show.addFlag(.{ .name = "phase", .description = "Postprocess phase: first-boot or install-post", .type = .String, .default_value = .{ .String = "first-boot" } });
    try node_postprocess_show.addFlag(.{ .name = "generation", .description = "Install generation (install-post only)", .type = .Int, .default_value = .{ .Int = 0 } });
    try addConfigPathFlag(node_postprocess_show);
    try addOutputFlag(node_postprocess_show);
    try addDebugFlag(node_postprocess_show);
    try node_postprocess.addCommands(&.{node_postprocess_show});

    try node.addCommands(&.{ node_list, node_show, node_add, node_set, node_unset, node_remove, node_claim, node_render, node_retry, node_deploy, node_trace, node_boot, node_readiness, node_postprocess, node_session });
    try addValuesCommands(node, init_options, "node");
    try addItemCommands(node, init_options, "node");
    try addNodeSoftwareCommands(node, init_options);
    try addCapabilitiesCommand(node, init_options, false);

    const profile = try zli.Command.init(init_options, .{ .name = "profile", .description = "Create and inspect PXE profiles" }, showCurrentHelp);
    const profile_create = try zli.Command.init(init_options, .{
        .name = "create",
        .description = "Create an install or diskless profile from an imported install source",
        .usage = "nodeforge profile create <install-source> [--qualifier <value>] [options]",
        .help = "Derives the profile name as <install-source>[-<qualifier>]-<install|diskless>. The complete install-source identity and role suffix can no longer be omitted.",
    }, profileCreateHandler);
    try profile_create.addPositionalArg(.{ .name = "install-source", .description = "Imported install source name", .required = true });
    try addConfigPathFlag(profile_create);
    try addOutputFlag(profile_create);
    try addDebugFlag(profile_create);
    try profile_create.addFlag(.{ .name = "kind", .description = "Profile kind; allowed: install, diskless (default: install)", .type = .String, .default_value = .{ .String = "install" } });
    try profile_create.addFlag(.{ .name = "qualifier", .description = "Optional purpose/kernel qualifier inserted before the kind suffix; e.g. compute or kernel-6.8", .type = .String, .default_value = .{ .String = "" } });
    try profile_create.addFlag(.{ .name = "boot-bundle", .description = "Override the derived diskless boot bundle reference; normally omitted", .type = .String, .default_value = .{ .String = "" } });
    // Profile 删除只开放零引用场景；引用保护由 daemon 在同一 catalog revision
    // 内执行，CLI 不做可能过期的本地预判。
    const profile_remove = try zli.Command.init(init_options, .{ .name = "remove", .description = "Remove an unreferenced profile" }, profileRemoveHandler);
    try profile_remove.addPositionalArg(.{ .name = "name", .description = "Profile name", .required = true });
    try addConfigPathFlag(profile_remove);
    try addOutputFlag(profile_remove);
    try addDebugFlag(profile_remove);
    const profile_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List PXE profiles" }, profileListHandler);
    try addConfigPathFlag(profile_list);
    try addOutputFlag(profile_list);
    try addDebugFlag(profile_list);
    const profile_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show a PXE profile" }, profileShowHandler);
    try profile_show.addPositionalArg(.{ .name = "name", .description = "Profile name", .required = true });
    try addConfigPathFlag(profile_show);
    try addOutputFlag(profile_show);
    try addDebugFlag(profile_show);
    const profile_clone = try zli.Command.init(init_options, .{ .name = "clone", .description = "Atomically clone a Profile desired configuration", .usage = "nodeforge profile clone <source> <target> [KEY=VALUE...] [--new-ssh-keys] [--build] [--detach]" }, profileCloneHandler);
    try profile_clone.addPositionalArg(.{ .name = "source", .description = "Existing Profile name", .required = true });
    try profile_clone.addPositionalArg(.{ .name = "target", .description = "New Profile name", .required = true });
    try profile_clone.addPositionalArg(.{ .name = "properties", .description = "Optional key=value property patches applied atomically with the clone", .required = false, .variadic = true });
    // v0.2.3 §5.2: 默认复用 source 的 SSH identity；--new-ssh-keys 创建独立 identity。
    try profile_clone.addFlag(.{ .name = "new-ssh-keys", .description = "Create a new independent SSH identity instead of reusing the source profile's identity", .type = .Bool, .default_value = .{ .Bool = false } });
    // v0.2.3 §5.2: --build 在 clone 提交后追加 rootfs build operation（仅
    // diskless）；--detach 与 --build 同用，立即返回 operation id。
    try profile_clone.addFlag(.{ .name = "build", .description = "Submit a rootfs build operation after the clone commits (diskless profiles only)", .type = .Bool, .default_value = .{ .Bool = false } });
    try profile_clone.addFlag(.{ .name = "detach", .description = "Return the build operation id immediately instead of following it (requires --build)", .type = .Bool, .default_value = .{ .Bool = false } });
    try addConfigPathFlag(profile_clone);
    try addOutputFlag(profile_clone);
    try addDebugFlag(profile_clone);
    const profile_set = try zli.Command.init(init_options, .{
        .name = "set",
        .description = "Modify stored profile properties",
        .usage = "nodeforge profile set <name> <key=value> [options]",
        .help = "Use an exact mutable Profile PropertySpec key. Collections require add-values/remove-values/replace-values/clear-values.",
    }, profileSetHandler);
    try profile_set.addPositionalArg(.{ .name = "name", .description = "Profile name", .required = true });
    try profile_set.addPositionalArg(.{ .name = "property", .description = "Canonical KEY=VALUE assignment", .required = true });
    try addConfigPathFlag(profile_set);
    try addOutputFlag(profile_set);
    try addDebugFlag(profile_set);
    const profile_unset = try zli.Command.init(init_options, .{
        .name = "unset",
        .description = "Clear an optional stored profile property",
        .usage = "nodeforge profile unset <name> kernel_args [options]",
        .help = "Unset one optional Profile PropertySpec key and restore its schema default/inheritance.",
    }, profileUnsetHandler);
    try profile_unset.addPositionalArg(.{ .name = "name", .description = "Profile name", .required = true });
    try profile_unset.addPositionalArg(.{ .name = "property", .description = "Canonical optional property key", .required = true });
    try addConfigPathFlag(profile_unset);
    try addOutputFlag(profile_unset);
    try addDebugFlag(profile_unset);
    const profile_rootfs = try zli.Command.init(init_options, .{ .name = "rootfs", .description = "Compile and register diskless rootfs artifacts" }, showCurrentHelp);
    const profile_rootfs_plan = try zli.Command.init(init_options, .{ .name = "plan", .description = "Compile a diskless profile rootfs input digest and cache state", .usage = "nodeforge profile rootfs plan <profile> [options]" }, profileRootfsPlanHandler);
    try profile_rootfs_plan.addPositionalArg(.{ .name = "name", .description = "Diskless profile name", .required = true });
    try addConfigPathFlag(profile_rootfs_plan);
    try addOutputFlag(profile_rootfs_plan);
    try addDebugFlag(profile_rootfs_plan);
    const profile_rootfs_register = try zli.Command.init(init_options, .{ .name = "register", .description = "Register a prebuilt rootfs artifact for a diskless profile", .usage = "nodeforge profile rootfs register <profile> --path <file> [--uncompressed-size <bytes>] [options]" }, profileRootfsRegisterHandler);
    try profile_rootfs_register.addPositionalArg(.{ .name = "name", .description = "Diskless profile name", .required = true });
    try profile_rootfs_register.addFlag(.{ .name = "path", .description = "Path to the prebuilt squashfs rootfs file", .type = .String, .default_value = .{ .String = "" } });
    try profile_rootfs_register.addFlag(.{ .name = "uncompressed-size", .description = "Logical uncompressed rootfs bytes; allowed: 0 (unknown) or a positive integer", .type = .Int, .default_value = .{ .Int = 0 } });
    try addConfigPathFlag(profile_rootfs_register);
    try addOutputFlag(profile_rootfs_register);
    try addDebugFlag(profile_rootfs_register);
    const profile_rootfs_build = try zli.Command.init(init_options, .{ .name = "build", .description = "Build a content-addressed rootfs artifact for a diskless profile from its build projection", .usage = "nodeforge profile rootfs build <profile> [--if-input-digest <hex>] [options]" }, profileRootfsBuildHandler);
    try profile_rootfs_build.addPositionalArg(.{ .name = "name", .description = "Diskless profile name", .required = true });
    try profile_rootfs_build.addFlag(.{ .name = "if-input-digest", .description = "Only build if the current rootfs input digest matches (anti-drift)", .type = .String, .default_value = .{ .String = "" } });
    // v0.2.3 §3.3: --new-ssh-keys 先轮换 identity/Profile 再以新投影构建。
    try profile_rootfs_build.addFlag(.{ .name = "new-ssh-keys", .description = "Rotate the profile ssh identity (new immutable revision) before building", .type = .Bool, .default_value = .{ .Bool = false } });
    try profile_rootfs_build.addFlag(.{ .name = "detach", .description = "Return immediately with the durable operation id", .type = .Bool, .default_value = .{ .Bool = false } });
    try addConfigPathFlag(profile_rootfs_build);
    try addOutputFlag(profile_rootfs_build);
    try addDebugFlag(profile_rootfs_build);
    const profile_rootfs_status = try zli.Command.init(init_options, .{ .name = "status", .description = "Show the registered rootfs artifact for a diskless profile", .usage = "nodeforge profile rootfs status <profile> [options]" }, profileRootfsStatusHandler);
    try profile_rootfs_status.addPositionalArg(.{ .name = "name", .description = "Diskless profile name", .required = true });
    try addConfigPathFlag(profile_rootfs_status);
    try addOutputFlag(profile_rootfs_status);
    try addDebugFlag(profile_rootfs_status);
    try profile_rootfs.addCommands(&.{ profile_rootfs_plan, profile_rootfs_build, profile_rootfs_register, profile_rootfs_status });
    try profile.addCommands(&.{ profile_create, profile_clone, profile_remove, profile_list, profile_show, profile_set, profile_unset, profile_rootfs });
    try addValuesCommands(profile, init_options, "profile");
    try addItemCommands(profile, init_options, "profile");
    try addProfileSoftwareCommands(profile, init_options);
    try addCapabilitiesCommand(profile, init_options, true);

    // ── assets 资源（ISO/资产导入管理）──────────────────────────────────
    const assets = try zli.Command.init(init_options, .{
        .name = "assets",
        .description = "Import and inspect boot assets and installation media",
        .usage = "nodeforge assets <import|list|show|validate> [options]",
    }, showCurrentHelp);
    const managed_file = try zli.Command.init(init_options, .{ .name = "managed-file", .description = "Manage immutable content assets for provision bundles" }, showCurrentHelp);
    const managed_file_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List managed-file assets" }, managedFileListHandler);
    try addCatalogPathFlag(managed_file_list);
    try addOutputFlag(managed_file_list);
    try addDebugFlag(managed_file_list);
    const managed_file_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show one managed-file asset" }, managedFileShowHandler);
    try managed_file_show.addPositionalArg(.{ .name = "name", .description = "Managed-file asset name", .required = true });
    try addCatalogPathFlag(managed_file_show);
    try addOutputFlag(managed_file_show);
    try addDebugFlag(managed_file_show);
    const managed_file_import = try zli.Command.init(init_options, .{ .name = "import", .description = "Atomically import a new immutable managed-file revision" }, managedFileImportHandler);
    try managed_file_import.addPositionalArg(.{ .name = "name", .description = "Managed-file asset name", .required = true });
    try managed_file_import.addFlag(.{ .name = "from-file", .description = "Source file path", .type = .String, .default_value = .{ .String = "" } });
    try managed_file_import.addFlag(.{ .name = "media-type", .description = "IANA media type", .type = .String, .default_value = .{ .String = "application/octet-stream" } });
    try addConfigPathFlag(managed_file_import);
    try addCatalogPathFlag(managed_file_import);
    try addOutputFlag(managed_file_import);
    try addDebugFlag(managed_file_import);
    const managed_file_remove = try zli.Command.init(init_options, .{ .name = "remove", .description = "Remove an unreferenced managed-file asset" }, managedFileRemoveHandler);
    try managed_file_remove.addPositionalArg(.{ .name = "name", .description = "Managed-file asset name", .required = true });
    try addConfigPathFlag(managed_file_remove);
    try addOutputFlag(managed_file_remove);
    try addDebugFlag(managed_file_remove);
    try managed_file.addCommands(&.{ managed_file_list, managed_file_show, managed_file_import, managed_file_remove });
    const archive = try zli.Command.init(init_options, .{ .name = "archive", .description = "Manage immutable archive assets" }, showCurrentHelp);
    const archive_build = try zli.Command.init(init_options, .{
        .name = "build",
        .description = "Build a canonical metadata-preserving archive",
        .usage = "nodeforge assets archive build <output> [--install-script <path>] [--compression none|gzip|xz] [--base-dir <dir>] [--files-from <list>] [paths...]",
        .help = "Requires GNU tar and, when selected, gzip or xz. Without --install-script it builds a data-only Mode B archive; when provided, the script is stored as the reserved top-level .nf.install.sh Mode A entry.",
    }, archiveBuildHandler);
    try archive_build.addPositionalArg(.{ .name = "archive", .description = "Output .tar, .tar.gz/.tgz, or .tar.xz/.txz path", .required = true });
    try archive_build.addPositionalArg(.{ .name = "paths", .description = "Payload paths relative to --base-dir", .required = false, .variadic = true });
    try archive_build.addFlag(.{ .name = "install-script", .description = "Optional Mode A installer stored as .nf.install.sh", .type = .String, .default_value = .{ .String = "" } });
    try archive_build.addFlag(.{ .name = "base-dir", .description = "Base directory for payload paths", .type = .String, .default_value = .{ .String = "." } });
    try archive_build.addFlag(.{ .name = "files-from", .description = "Text file containing one payload path per line", .type = .String, .default_value = .{ .String = "" } });
    try archive_build.addFlag(.{ .name = "compression", .description = "Output compression: none, gzip, or xz", .type = .String, .default_value = .{ .String = "none" } });
    try addOutputFlag(archive_build);
    try addDebugFlag(archive_build);
    const archive_import = try zli.Command.init(init_options, .{ .name = "import", .description = "Atomically import an archive revision" }, archiveImportHandler);
    try addContentAssetImportArgs(archive_import, "Archive");
    try archive.addCommands(&.{ archive_build, archive_import });
    const script = try zli.Command.init(init_options, .{ .name = "script", .description = "Manage immutable script assets" }, showCurrentHelp);
    const script_import = try zli.Command.init(init_options, .{ .name = "import", .description = "Atomically import a script revision" }, scriptImportHandler);
    try addContentAssetImportArgs(script_import, "Script");
    try script.addCommands(&.{script_import});
    const initrd_assets = try zli.Command.init(init_options, .{ .name = "initrd", .description = "Build and register NodeForge diskless initrds" }, showCurrentHelp);
    const initrd_build = try zli.Command.init(init_options, .{
        .name = "build",
        .description = "Build, publish, and register a NodeForge diskless initrd",
        .usage = "nodeforge assets initrd build <name> --from-install-source <source> --kernel-release <r> [options]",
        .help = "Prefer --from-install-source: preserves the ISO vendor initrd (including distro patches, firmware, and kernel modules) and appends a NodeForge overlay. Without it, --distro/--version/--arch select the generic dracut fallback. Publishes atomically to the managed initrd store and registers the result.",
    }, initrdBuildOperationHandler);
    try initrd_build.addPositionalArg(.{ .name = "name", .description = "Canonical initrd asset name", .required = true });
    try initrd_build.addFlags(&.{
        .{ .name = "distro", .description = "Distro name (for example rocky)", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "version", .description = "Distro version (for example 9.7)", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "arch", .description = archFlagHelp, .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "kernel-release", .description = "Installed kernel uname release used by dracut", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "from-install-source", .description = "Derive from this ISO install source's vendor installer initrd (recommended)", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "detach", .description = "Return immediately with the durable operation id", .type = .Bool, .default_value = .{ .Bool = false } },
    });
    try addConfigPathFlag(initrd_build);
    try addOutputFlag(initrd_build);
    try addDebugFlag(initrd_build);
    try initrd_assets.addCommands(&.{initrd_build});
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
        managed_file,
        archive,
        script,
        initrd_assets,
    });
    try addProvisionBundleCommands(assets, init_options);
    try addAssetCatalogCommands(assets, init_options);
    // v0.2 boot-bundle 命令：创建 diskless profile 引用的 kernel/initrd 组合。
    // 这是 diskless 全流程 CLI 的关键环节。操作员通过 CLI 完成全部操作，
    // 无需手动编辑 catalog JSON 文件。
    const boot_bundle = try zli.Command.init(init_options, .{ .name = "boot-bundle", .description = "Manage diskless boot bundles (kernel/initrd combinations)" }, showCurrentHelp);
    const boot_bundle_create = try zli.Command.init(init_options, .{
        .name = "create",
        .description = "Create a boot bundle linking kernel and initrd assets",
        .usage = "nodeforge assets boot-bundle create <install-source> [--qualifier <value>] --kernel <asset> --initrd <asset> --distro <d> --version <v> --arch <a> --kernel-release <r> [options]",
        .help = "Links registered kernel and nodeforge_initrd assets into an immutable boot bundle. " ++
            "The bundle is referenced by diskless profiles via --boot-bundle. " ++
            "The Profile-derived rootfs is built or registered after the Profile exists. " ++
            "This command is part of the diskless CLI flow: setup -> assets import -> register initrd -> boot-bundle create -> profile create -> rootfs build -> node add.",
    }, bootBundleCreateHandler);
    try boot_bundle_create.addPositionalArg(.{ .name = "install-source", .description = "Complete imported install source name", .required = true });
    try boot_bundle_create.addFlags(&.{
        .{ .name = "kernel", .description = "Kernel asset name (kind=kernel)", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "initrd", .description = "NodeForge initrd asset name (kind=nodeforge_initrd)", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "distro", .description = "Distro name (e.g. rocky, ubuntu)", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "version", .description = "Distro version (e.g. 9.7, 24.04)", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "arch", .description = archFlagHelp, .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "kernel-release", .description = "Kernel uname release string (e.g. 5.14.0-611.5.1.el9_7.aarch64)", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "qualifier", .description = "Optional purpose/kernel qualifier inserted before -diskless", .type = .String, .default_value = .{ .String = "" } },
    });
    try addConfigPathFlag(boot_bundle_create);
    try addOutputFlag(boot_bundle_create);
    try addDebugFlag(boot_bundle_create);
    const boot_bundle_list = try zli.Command.init(init_options, .{ .name = "list", .description = "列出 diskless BootBundle" }, bootBundleListHandler);
    try addConfigPathFlag(boot_bundle_list);
    try addOutputFlag(boot_bundle_list);
    try addDebugFlag(boot_bundle_list);
    const boot_bundle_show = try zli.Command.init(init_options, .{ .name = "show", .description = "查看一个 diskless BootBundle" }, bootBundleShowHandler);
    try boot_bundle_show.addPositionalArg(.{ .name = "name", .description = "BootBundle 名称", .required = true });
    try addConfigPathFlag(boot_bundle_show);
    try addOutputFlag(boot_bundle_show);
    try addDebugFlag(boot_bundle_show);
    try boot_bundle.addCommands(&.{ boot_bundle_create, boot_bundle_list, boot_bundle_show });
    try assets.addCommands(&.{boot_bundle});

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

    const discovery = try zli.Command.init(init_options, .{ .name = "discovery", .description = "Inspect and manage persistent unknown-client observations" }, showCurrentHelp);
    const discovery_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List persistent unknown-client observations" }, discoveryListHandler);
    try addConfigPathFlag(discovery_list);
    try addOutputFlag(discovery_list);
    try addDebugFlag(discovery_list);
    const discovery_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show one observation by MAC" }, discoveryShowHandler);
    try discovery_show.addPositionalArg(.{ .name = "mac", .description = "Observed client MAC address", .required = true });
    try addConfigPathFlag(discovery_show);
    try addOutputFlag(discovery_show);
    try addDebugFlag(discovery_show);
    const discovery_policy = try zli.Command.init(init_options, .{ .name = "policy", .description = "Inspect or modify unknown-client policy" }, showCurrentHelp);
    const discovery_policy_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show unknown-client policy" }, discoveryPolicyShowHandler);
    try addConfigPathFlag(discovery_policy_show);
    try addOutputFlag(discovery_policy_show);
    try addDebugFlag(discovery_policy_show);
    const discovery_policy_set = try zli.Command.init(init_options, .{ .name = "set", .description = "Modify unknown-client policy" }, discoveryPolicySetHandler);
    try discovery_policy_set.addPositionalArg(.{ .name = "properties", .description = "unknown_action=record|deny and/or observation_retention_days=<days>", .required = true, .variadic = true });
    try addConfigPathFlag(discovery_policy_set);
    try addOutputFlag(discovery_policy_set);
    try addDebugFlag(discovery_policy_set);
    try discovery_policy.addCommands(&.{ discovery_policy_show, discovery_policy_set });
    try discovery.addCommands(&.{ discovery_list, discovery_show, discovery_policy });

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
        .help = "All filesystem effects are bounded by the bootstrapped install root. --reset-state backs up and clears runtime state only. --reset-all also regenerates startup config but preserves catalog/assets unless combined with --purge-data or --purge-all. --purge-all is the irreversible fresh-replacement path and may be followed by --reconfigure. Destructive non-interactive operations require --yes; reset/purge requires the daemon to be stopped. Examples: `nodeforge setup --reset-state --yes`; fresh replacement: `nodeforge setup --reset-all --purge-all --reconfigure --yes`. Constraints: --purge-data/--purge-all require --reset-all and are mutually exclusive; only --reset-all may compose with --reconfigure.",
    }, setupHandler);
    try setup.addFlags(&.{
        .{ .name = "install-root", .description = "New or existing absolute install root", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "non-interactive", .description = "Do not prompt for input", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "yes", .description = "Confirm a destructive or service lifecycle action", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "reconfigure", .description = "Validate config/catalog and republish the systemd unit without starting or restarting it; may follow --reset-all", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "import-config", .description = "Import a complete startup config JSON during initialization or reconfiguration", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "generate-systemd", .description = "Generate only the systemd unit", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "print", .description = "Print generated systemd unit instead of writing it", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "install", .description = "Install/enable/start the generated systemd unit", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "repair-dirs", .description = "Repair the canonical directory tree only", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "reset-state", .description = "Back up and clear runtime state; preserve startup config, catalog, assets, work files, logs, and backups", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "reset-all", .description = "Back up/clear runtime state and regenerate startup config; preserve catalog/assets unless a purge flag is present", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "purge-data", .description = "With --reset-all, also delete catalog and assets while preserving work files, logs, and backup history", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "purge-all", .description = "With --reset-all, irreversibly delete catalog, assets, work files, logs, backups, and migration history for a fresh replacement", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "dry-run", .description = "Preview the selected operation and key paths without writing", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "log-level", .description = "Persist daemon log level: debug, info, warn, or err (new deployments default to debug)", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "bind-interface", .description = "PXE bind interface for generated config", .type = .String, .default_value = .{ .String = "eth0" } },
        .{ .name = "server-ip", .description = "PXE server IPv4 address", .type = .String, .default_value = .{ .String = "192.168.50.1" } },
        .{ .name = "http-port", .description = "HTTP/management listen port for generated config", .type = .Int, .default_value = .{ .Int = 18080 } },
        .{ .name = "subnet", .description = "DHCP subnet CIDR", .type = .String, .default_value = .{ .String = "192.168.50.0/24" } },
        .{ .name = "pool-start", .description = "First DHCP pool address", .type = .String, .default_value = .{ .String = "192.168.50.100" } },
        .{ .name = "pool-end", .description = "Last DHCP pool address", .type = .String, .default_value = .{ .String = "192.168.50.200" } },
    });

    try root.addCommands(&.{
        status,
        operation,
        config,
        catalog,
        node,
        profile,
        assets,
        runtime,
        discovery,
        events,
        setup,
    });
    return root;
}

fn addContentAssetImportArgs(command: *zli.Command, label: []const u8) !void {
    try command.addPositionalArg(.{ .name = "name", .description = label, .required = true });
    try command.addFlag(.{ .name = "from-file", .description = "Source file path", .type = .String, .default_value = .{ .String = "" } });
    try command.addFlag(.{ .name = "media-type", .description = "IANA media type", .type = .String, .default_value = .{ .String = "application/octet-stream" } });
    try addConfigPathFlag(command);
    try addCatalogPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
}

fn addNodeSoftwareCommands(node: *zli.Command, init_options: zli.InitOptions) !void {
    const software = try zli.Command.init(init_options, .{ .name = "software", .description = "Inspect selected and effective node software" }, showCurrentHelp);
    const show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show selected deltas and effective software" }, nodeSoftwareShowHandler);
    try show.addPositionalArg(.{ .name = "node", .description = "Node identifier", .required = true });
    try addConfigPathFlag(show);
    try addOutputFlag(show);
    try addDebugFlag(show);
    try software.addCommand(show);
    try node.addCommand(software);
}

fn addCapabilitiesCommand(parent: *zli.Command, init_options: zli.InitOptions, profile: bool) !void {
    const capabilities = try zli.Command.init(init_options, .{ .name = "capabilities", .description = "Inspect adapter consumption and readiness capabilities" }, showCurrentHelp);
    const show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show canonical adapter capability registry status" }, if (profile) profileCapabilitiesShowHandler else nodeCapabilitiesShowHandler);
    try show.addPositionalArg(.{ .name = if (profile) "profile" else "node", .description = if (profile) "Profile name" else "Node identifier", .required = true });
    try addConfigPathFlag(show);
    try addOutputFlag(show);
    try addDebugFlag(show);
    try capabilities.addCommand(show);
    try parent.addCommand(capabilities);
}

fn addProfileSoftwareCommands(profile: *zli.Command, init_options: zli.InitOptions) !void {
    const software = try zli.Command.init(init_options, .{ .name = "software", .description = "Query available, selected, and effective Profile software" }, showCurrentHelp);
    const available = try zli.Command.init(init_options, .{ .name = "available", .description = "List indexed capabilities available to a Profile" }, profileSoftwareAvailableHandler);
    try available.addPositionalArg(.{ .name = "profile", .description = "Profile name", .required = true });
    try addSoftwareQueryFlags(available);
    try addConfigPathFlag(available);
    try addOutputFlag(available);
    try addDebugFlag(available);
    const show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show selected and effective Profile software" }, profileSoftwareShowHandler);
    try show.addPositionalArg(.{ .name = "profile", .description = "Profile name", .required = true });
    try addConfigPathFlag(show);
    try addOutputFlag(show);
    try addDebugFlag(show);
    try software.addCommands(&.{ available, show });
    try profile.addCommand(software);
}

fn addAssetCatalogCommands(assets: *zli.Command, init_options: zli.InitOptions) !void {
    const sources = try zli.Command.init(init_options, .{ .name = "install-source", .description = "Inspect imported install sources and their software indexes" }, showCurrentHelp);
    const source_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List install sources" }, installSourceListHandler);
    const source_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show one install source" }, installSourceShowHandler);
    try source_show.addPositionalArg(.{ .name = "source", .description = "Install source name", .required = true });
    const source_software = try zli.Command.init(init_options, .{ .name = "software", .description = "Inspect source-scoped software capabilities" }, showCurrentHelp);
    const source_software_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List or search source capabilities" }, installSourceSoftwareListHandler);
    try source_software_list.addPositionalArg(.{ .name = "source", .description = "Install source name", .required = true });
    try addSoftwareQueryFlags(source_software_list);
    for ([_]*zli.Command{ source_list, source_show, source_software_list }) |command| {
        try addConfigPathFlag(command);
        try addOutputFlag(command);
        try addDebugFlag(command);
    }
    try source_software.addCommand(source_software_list);
    try sources.addCommands(&.{ source_list, source_show, source_software });

    const repositories = try zli.Command.init(init_options, .{ .name = "repository", .description = "Inspect indexed package repositories" }, showCurrentHelp);
    const repository_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List repositories" }, repositoryListHandler);
    const repository_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show one repository" }, repositoryShowHandler);
    try repository_show.addPositionalArg(.{ .name = "repository", .description = "Repository name", .required = true });
    const repository_render = try zli.Command.init(init_options, .{ .name = "render", .description = "Render a yum/dnf .repo or apt sources.list entry" }, repositoryRenderHandler);
    try repository_render.addPositionalArg(.{ .name = "repository", .description = "Repository name", .required = true });
    try addOutputFlag(repository_render);
    const repository_software = try zli.Command.init(init_options, .{ .name = "software", .description = "Inspect raw repository capabilities" }, showCurrentHelp);
    const repository_software_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List or search repository capabilities" }, repositorySoftwareListHandler);
    try repository_software_list.addPositionalArg(.{ .name = "repository", .description = "Repository name", .required = true });
    try addSoftwareQueryFlags(repository_software_list);
    const repository_software_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show one repository capability" }, repositorySoftwareShowHandler);
    try repository_software_show.addPositionalArg(.{ .name = "repository", .description = "Repository name", .required = true });
    try repository_software_show.addPositionalArg(.{ .name = "id", .description = "Capability id", .required = true });
    try repository_software_show.addFlag(.{ .name = "kind", .description = requiredSoftwareKindFlagHelp, .type = .String, .default_value = .{ .String = "" } });
    for ([_]*zli.Command{ repository_list, repository_show, repository_software_list, repository_software_show }) |command| {
        try addConfigPathFlag(command);
        try addOutputFlag(command);
        try addDebugFlag(command);
    }
    try repository_software.addCommands(&.{ repository_software_list, repository_software_show });
    try repositories.addCommands(&.{ repository_list, repository_show, repository_render, repository_software });
    try assets.addCommands(&.{ sources, repositories });
}

fn addSoftwareQueryFlags(command: *zli.Command) !void {
    try command.addFlags(&.{
        .{ .name = "kind", .description = softwareKindFlagHelp, .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "search", .description = "Case-insensitive id/name search", .type = .String, .default_value = .{ .String = "" } },
    });
}

fn addValuesCommands(parent: *zli.Command, init_options: zli.InitOptions, owner: []const u8) !void {
    const list = try zli.Command.init(init_options, .{ .name = "list-values", .description = "List one scalar collection by canonical key" }, valuesHandler);
    try addValuesPositionals(list, owner, false);
    const add = try zli.Command.init(init_options, .{ .name = "add-values", .description = "Atomically add unique scalar collection values" }, valuesHandler);
    try addValuesPositionals(add, owner, true);
    const remove = try zli.Command.init(init_options, .{ .name = "remove-values", .description = "Atomically remove scalar collection values" }, valuesHandler);
    try addValuesPositionals(remove, owner, true);
    const replace = try zli.Command.init(init_options, .{ .name = "replace-values", .description = "Atomically replace a scalar collection" }, valuesHandler);
    try addValuesPositionals(replace, owner, false);
    try replace.addFlag(.{ .name = "from-file", .description = "UTF-8 text file with one value per line", .type = .String, .default_value = .{ .String = "" } });
    const clear = try zli.Command.init(init_options, .{ .name = "clear-values", .description = "Set a scalar collection to explicit empty" }, valuesHandler);
    try addValuesPositionals(clear, owner, false);
    if (std.mem.eql(u8, owner, "node")) for ([_]*zli.Command{ add, remove, replace, clear }) |command| try command.addFlag(.{
        .name = "set",
        .description = "Atomically apply one scalar key=value with this collection mutation",
        .type = .String,
        .default_value = .{ .String = "" },
    });
    for ([_]*zli.Command{ add, remove, replace, clear }) |command| try command.addFlag(.{
        .name = "force",
        .description = "Terminate active sessions (install/diskless) on the target node before mutation",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try parent.addCommands(&.{ list, add, remove, replace, clear });
}

fn addItemCommands(parent: *zli.Command, init_options: zli.InitOptions, owner: []const u8) !void {
    const item = try zli.Command.init(init_options, .{ .name = "item", .description = "Inspect or mutate structured collections by stable identity" }, showCurrentHelp);
    const list = try zli.Command.init(init_options, .{ .name = "list", .description = "List structured items" }, itemHandler);
    try addItemBase(list, owner, false);
    const show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show one structured item" }, itemHandler);
    try addItemBase(show, owner, true);
    const add = try zli.Command.init(init_options, .{ .name = "add", .description = "Add one typed structured item" }, itemHandler);
    try addItemBase(add, owner, false);
    try add.addPositionalArg(.{ .name = "fields", .description = "Typed field=value assignments", .required = true, .variadic = true });
    const set = try zli.Command.init(init_options, .{ .name = "set", .description = "Patch one structured item" }, itemHandler);
    try addItemBase(set, owner, true);
    try set.addPositionalArg(.{ .name = "fields", .description = "Typed field=value assignments", .required = false, .variadic = true });
    try set.addFlag(.{ .name = "unset", .description = "Optional field to clear", .type = .String, .default_value = .{ .String = "" } });
    const remove = try zli.Command.init(init_options, .{ .name = "remove", .description = "Remove one structured item" }, itemHandler);
    try addItemBase(remove, owner, true);
    const move = try zli.Command.init(init_options, .{ .name = "move", .description = "Move one ordered structured item" }, itemHandler);
    try addItemBase(move, owner, true);
    try move.addFlags(&.{ .{ .name = "before", .description = "Place before this identity", .type = .String, .default_value = .{ .String = "" } }, .{ .name = "after", .description = "Place after this identity", .type = .String, .default_value = .{ .String = "" } } });
    const list_values = try zli.Command.init(init_options, .{ .name = "list-values", .description = "List an item-scoped scalar collection" }, itemValuesHandler);
    const add_values = try zli.Command.init(init_options, .{ .name = "add-values", .description = "Add item-scoped collection values" }, itemValuesHandler);
    const remove_values = try zli.Command.init(init_options, .{ .name = "remove-values", .description = "Remove item-scoped collection values" }, itemValuesHandler);
    const replace_values = try zli.Command.init(init_options, .{ .name = "replace-values", .description = "Replace an item-scoped scalar collection" }, itemValuesHandler);
    const clear_values = try zli.Command.init(init_options, .{ .name = "clear-values", .description = "Clear an item-scoped scalar collection" }, itemValuesHandler);
    for ([_]*zli.Command{ list_values, add_values, remove_values, replace_values, clear_values }) |command| {
        try addItemValuesPositionals(command, owner, command == add_values or command == remove_values);
    }
    try replace_values.addFlag(.{ .name = "from-file", .description = "UTF-8 text file with one value per line, or - for stdin", .type = .String, .default_value = .{ .String = "" } });
    for ([_]*zli.Command{ add, set, remove, move, add_values, remove_values, replace_values, clear_values }) |command| try command.addFlag(.{
        .name = "force",
        .description = "Terminate active sessions (install/diskless) on the target node before mutation",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try item.addCommands(&.{ list, show, add, set, remove, move, list_values, add_values, remove_values, replace_values, clear_values });
    try parent.addCommand(item);
    const replace = try zli.Command.init(init_options, .{ .name = "replace-items", .description = "Atomically replace structured items from a file" }, replaceItemsHandler);
    try addItemBase(replace, owner, false);
    try replace.addFlag(.{ .name = "from-file", .description = "Structured collection file, or - for stdin", .type = .String, .default_value = .{ .String = "" } });
    try replace.addFlag(.{ .name = "input", .description = structuredInputFlagHelp, .type = .String, .default_value = .{ .String = "yaml" } });
    const clear = try zli.Command.init(init_options, .{ .name = "clear-items", .description = "Clear a structured collection or local replacement" }, replaceItemsHandler);
    try addItemBase(clear, owner, false);
    for ([_]*zli.Command{ replace, clear }) |command| try command.addFlag(.{
        .name = "force",
        .description = "Terminate active sessions (install/diskless) on the target node before mutation",
        .type = .Bool,
        .default_value = .{ .Bool = false },
    });
    try parent.addCommands(&.{ replace, clear });
}

fn addItemValuesPositionals(command: *zli.Command, owner: []const u8, require_values: bool) !void {
    try command.addPositionalArg(.{ .name = "identity", .description = if (std.mem.eql(u8, owner, "node")) "Node identifier" else "Profile name", .required = true });
    try command.addPositionalArg(.{ .name = "key", .description = "Structured collection key", .required = true });
    try command.addPositionalArg(.{ .name = "item_identity", .description = "Stable item identity", .required = true });
    try command.addPositionalArg(.{ .name = "field", .description = "Item-scoped collection field", .required = true });
    try command.addPositionalArg(.{ .name = "values", .description = "One or more scalar values", .required = require_values, .variadic = true });
    try addConfigPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
}

fn addItemBase(command: *zli.Command, owner: []const u8, with_item_identity: bool) !void {
    try command.addPositionalArg(.{ .name = "identity", .description = if (std.mem.eql(u8, owner, "node")) "Node identifier" else "Profile name", .required = true });
    try command.addPositionalArg(.{ .name = "key", .description = "Canonical structured CollectionSpec key", .required = true });
    if (with_item_identity) try command.addPositionalArg(.{ .name = "item_identity", .description = "Stable item identity", .required = true });
    try addConfigPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
}

fn addProvisionBundleCommands(assets: *zli.Command, init_options: zli.InitOptions) !void {
    const bundles = try zli.Command.init(init_options, .{ .name = "provision-bundle", .description = "Manage revisioned managed-file provision bundles" }, showCurrentHelp);
    const list = try zli.Command.init(init_options, .{ .name = "list", .description = "List provision bundles" }, provisionBundleHandler);
    const show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show a provision bundle" }, provisionBundleHandler);
    try show.addPositionalArg(.{ .name = "bundle", .description = "Bundle name", .required = true });
    const create = try zli.Command.init(init_options, .{ .name = "create", .description = "Create an empty provision bundle" }, provisionBundleHandler);
    try create.addPositionalArg(.{ .name = "bundle", .description = "Bundle name", .required = true });
    const remove = try zli.Command.init(init_options, .{ .name = "remove", .description = "Remove an unreferenced provision bundle" }, provisionBundleHandler);
    try remove.addPositionalArg(.{ .name = "bundle", .description = "Bundle name", .required = true });
    for ([_]*zli.Command{ list, show, create, remove }) |command| {
        try addConfigPathFlag(command);
        try addOutputFlag(command);
        try addDebugFlag(command);
    }
    const item = try zli.Command.init(init_options, .{ .name = "item", .description = "Manage bundle steps by stable name" }, showCurrentHelp);
    const item_list = try zli.Command.init(init_options, .{ .name = "list", .description = "List bundle steps" }, provisionBundleItemHandler);
    const item_show = try zli.Command.init(init_options, .{ .name = "show", .description = "Show one bundle step" }, provisionBundleItemHandler);
    const item_add = try zli.Command.init(init_options, .{ .name = "add", .description = "Add a managed-file step" }, provisionBundleItemHandler);
    const item_set = try zli.Command.init(init_options, .{ .name = "set", .description = "Patch a managed-file step" }, provisionBundleItemHandler);
    const item_remove = try zli.Command.init(init_options, .{ .name = "remove", .description = "Remove a managed-file step" }, provisionBundleItemHandler);
    const item_move = try zli.Command.init(init_options, .{ .name = "move", .description = "Move a managed-file step" }, provisionBundleItemHandler);
    for ([_]*zli.Command{ item_list, item_show, item_add, item_set, item_remove, item_move }) |command| {
        try command.addPositionalArg(.{ .name = "bundle", .description = "Bundle name", .required = true });
        try command.addPositionalArg(.{ .name = "key", .description = "Exact collection key: steps", .required = true });
        if (command != item_list and command != item_add) try command.addPositionalArg(.{ .name = "identity", .description = "Step name", .required = true });
        try addConfigPathFlag(command);
        try addOutputFlag(command);
        try addDebugFlag(command);
    }
    try item_add.addPositionalArg(.{ .name = "fields", .description = "name= action=managed-file destination= content_asset= mode= owner= group=", .required = true, .variadic = true });
    try item_set.addPositionalArg(.{ .name = "fields", .description = "Typed field=value patches", .required = false, .variadic = true });
    try item_set.addFlag(.{ .name = "unset", .description = "Reset optional mode, owner, or group", .type = .String, .default_value = .{ .String = "" } });
    try item_move.addFlags(&.{ .{ .name = "before", .description = "Move before step", .type = .String, .default_value = .{ .String = "" } }, .{ .name = "after", .description = "Move after step", .type = .String, .default_value = .{ .String = "" } } });
    try item.addCommands(&.{ item_list, item_show, item_add, item_set, item_remove, item_move });
    const replace = try zli.Command.init(init_options, .{ .name = "replace-items", .description = "Atomically replace bundle steps from YAML or JSON" }, provisionBundleReplaceHandler);
    const clear = try zli.Command.init(init_options, .{ .name = "clear-items", .description = "Atomically clear bundle steps" }, provisionBundleReplaceHandler);
    for ([_]*zli.Command{ replace, clear }) |command| {
        try command.addPositionalArg(.{ .name = "bundle", .description = "Bundle name", .required = true });
        try command.addPositionalArg(.{ .name = "key", .description = "Exact collection key: steps", .required = true });
        try addConfigPathFlag(command);
        try addOutputFlag(command);
        try addDebugFlag(command);
    }
    try replace.addFlag(.{ .name = "from-file", .description = "Structured steps file or - for stdin", .type = .String, .default_value = .{ .String = "" } });
    try replace.addFlag(.{ .name = "input", .description = structuredInputFlagHelp, .type = .String, .default_value = .{ .String = "yaml" } });
    try bundles.addCommands(&.{ list, show, create, remove, item, replace, clear });
    try assets.addCommand(bundles);
}

fn addValuesPositionals(command: *zli.Command, owner: []const u8, require_values: bool) !void {
    try command.addPositionalArg(.{ .name = "identity", .description = if (std.mem.eql(u8, owner, "node")) "Node identifier" else "Profile name", .required = true });
    try command.addPositionalArg(.{ .name = "key", .description = "Canonical CollectionSpec key", .required = true });
    try command.addPositionalArg(.{ .name = "values", .description = "One or more scalar values", .required = require_values, .variadic = true });
    try addConfigPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
}

fn valuesHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const owner_text = ctx.direct_parent.cmd_options.name;
    const owner: nodeforge.cli_properties.Owner = if (std.mem.eql(u8, owner_text, "node")) .node else .profile;
    const identity = ctx.positional_args[0];
    const key = ctx.positional_args[1];
    const spec = nodeforge.cli_properties.collection(owner, key) orelse {
        const message = try std.fmt.allocPrint(ctx.allocator, "'{s}' is not a {s} collection key", .{ key, owner_text });
        try writeCommandError(ctx, "property.unknown", message, 2);
        return;
    };
    if (spec.mutability != .mutable and !std.mem.eql(u8, ctx.command.cmd_options.name, "list-values")) {
        try writeCommandError(ctx, "property.read_only", "collection is read-only", 2);
        return;
    }
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    if (std.mem.eql(u8, ctx.command.cmd_options.name, "list-values")) {
        const response = try allocManagementResponse(ctx);
        defer ctx.allocator.free(response);
        const body = nodeforge.management_client.valuesJson(ctx.io, config.value.server.http_port, owner_text, identity, key, response) catch null orelse {
            try writeCommandError(ctx, "property.query_failed", "property query failed", 1);
            return;
        };
        const Response = struct { result: struct { values: []const []const u8 } };
        const parsed = try std.json.parseFromSlice(Response, ctx.allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const cells = try ctx.allocator.alloc([1][]const u8, parsed.value.result.values.len);
        const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, parsed.value.result.values.len);
        const jsonl = try ctx.allocator.alloc([]const u8, parsed.value.result.values.len);
        for (parsed.value.result.values, 0..) |value, index| {
            cells[index] = .{value};
            rows[index] = .{ .cells = &cells[index] };
            jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .value = value } }, .{});
        }
        const columns = [_]nodeforge.cli_table.Column{.{ .key = "value", .title = "VALUE" }};
        try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No values." } }, .json = body, .jsonl = jsonl });
        return;
    }
    const command_name = ctx.command.cmd_options.name;
    const operation = if (std.mem.eql(u8, command_name, "add-values")) "add" else if (std.mem.eql(u8, command_name, "remove-values")) "remove" else if (std.mem.eql(u8, command_name, "replace-values")) "replace" else "clear";
    var file_values: std.ArrayList([]const u8) = .empty;
    defer file_values.deinit(ctx.allocator);
    var file_bytes: ?[]u8 = null;
    defer if (file_bytes) |bytes| ctx.allocator.free(bytes);
    var values = if (ctx.positional_args.len > 2) ctx.positional_args[2..] else &.{};
    if (std.mem.eql(u8, command_name, "replace-values")) {
        const path = ctx.flag("from-file", []const u8);
        if (path.len != 0) {
            if (values.len != 0) {
                try writeCommandError(ctx, "property.invalid_input", "values and --from-file are mutually exclusive", 2);
                return;
            }
            const bytes = if (std.mem.eql(u8, path, "-")) ctx.reader.allocRemaining(ctx.allocator, .limited(8 * 1024 * 1024)) catch {
                try writeCommandError(ctx, "property.stdin_unreadable", "property input could not be read from stdin", 1);
                return;
            } else std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(8 * 1024 * 1024)) catch {
                try writeCommandError(ctx, "property.file_unreadable", "property input file could not be read", 1);
                return;
            };
            file_bytes = bytes;
            if (!std.unicode.utf8ValidateSlice(bytes)) {
                try writeCommandError(ctx, "property.invalid_utf8", "property input must be UTF-8", 2);
                return;
            }
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                const value = std.mem.trim(u8, line, " \t\r");
                if (value.len == 0 or value[0] == '#') continue;
                try file_values.append(ctx.allocator, value);
            }
            values = file_values.items;
        }
    }
    var scalar_mutations: [1]nodeforge.scalar_mutation.Mutation = undefined;
    var scalar_count: usize = 0;
    if (owner == .node) {
        const scalar = ctx.flag("set", []const u8);
        if (scalar.len != 0) {
            const separator = std.mem.indexOfScalar(u8, scalar, '=') orelse {
                try writeCommandError(ctx, "property.invalid_input", "--set requires canonical-key=value", 2);
                return;
            };
            const scalar_key = scalar[0..separator];
            const scalar_value = scalar[separator + 1 ..];
            const scalar_spec = nodeforge.cli_properties.property(.node, scalar_key) orelse {
                try writeCommandError(ctx, "property.unknown", "--set requires a canonical scalar Node key", 2);
                return;
            };
            if (scalar_spec.mutability != .mutable or scalar_value.len == 0) {
                try writeCommandError(ctx, "property.invalid_input", "--set requires a mutable scalar key and non-empty value", 2);
                return;
            }
            scalar_mutations[0] = .{ .key = scalar_key, .value = scalar_value };
            scalar_count = 1;
        }
    }
    var reason: [512]u8 = undefined;
    const result = nodeforge.management_client.valuesMutation(ctx.io, config.value.server.http_port, owner_text, identity, operation, key, values, scalar_mutations[0..scalar_count], ctx.flag("force", bool), &reason);
    if (!result.healthy) return reportMutationFailure(ctx, result, "collection mutation failed");
    const human = try std.fmt.allocPrint(ctx.allocator, "{s} {s} on {s}", .{ operation, key, identity });
    try renderCommandResult(ctx, human, .{ .resource = identity, .key = key, .operation = operation, .values = values });
}

fn itemHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const command_name = ctx.command.cmd_options.name;
    const resource = ctx.positional_args[0];
    const key = ctx.positional_args[1];
    const owner: nodeforge.cli_properties.Owner = if (std.mem.startsWith(u8, key, "network.") or std.mem.startsWith(u8, key, "overrides.") or std.mem.startsWith(u8, key, "effective.")) .node else .profile;
    const owner_text = @tagName(owner);
    const collection = nodeforge.cli_properties.collection(owner, key) orelse {
        const message = try std.fmt.allocPrint(ctx.allocator, "'{s}' is not a structured collection key", .{key});
        try writeCommandError(ctx, "property.unknown", message, 2);
        return;
    };
    if (collection.item_spec == null) {
        try writeCommandError(ctx, "property.item_operation_required", "key is not structured", 2);
        return;
    }
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    if (std.mem.eql(u8, command_name, "list") or std.mem.eql(u8, command_name, "show")) {
        const response = try allocManagementResponse(ctx);
        defer ctx.allocator.free(response);
        const item_identity: ?[]const u8 = if (std.mem.eql(u8, command_name, "show")) ctx.positional_args[2] else null;
        const body = nodeforge.management_client.itemsJson(ctx.io, config.value.server.http_port, owner_text, resource, key, item_identity, response) catch null orelse {
            try writeCommandError(ctx, "item.query_failed", "item query failed", 1);
            return;
        };
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
            try writeCommandError(ctx, "item.invalid_response", "item response is malformed", 1);
            return;
        };
        defer parsed.deinit();
        const result = parsed.value.object.get("result") orelse return writeCommandError(ctx, "item.invalid_response", "item response has no result", 1);
        const items = result.object.get("items") orelse return writeCommandError(ctx, "item.invalid_response", "item response has no items", 1);
        if (std.mem.eql(u8, command_name, "list")) {
            const cells = try ctx.allocator.alloc([2][]const u8, items.array.items.len);
            const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, items.array.items.len);
            const jsonl = try ctx.allocator.alloc([]const u8, items.array.items.len);
            for (items.array.items, 0..) |item, index| {
                const identity = item.object.get("id") orelse item.object.get("name") orelse .null;
                cells[index] = .{ jsonString(identity), try std.json.Stringify.valueAlloc(ctx.allocator, item, .{}) };
                rows[index] = .{ .cells = &cells[index] };
                jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = item }, .{});
            }
            const columns = [_]nodeforge.cli_table.Column{ .{ .key = "identity", .title = "IDENTITY" }, .{ .key = "item", .title = "ITEM", .max_width = 96 } };
            try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No items." } }, .json = body, .jsonl = jsonl });
            return;
        }
        if (items.array.items.len == 0) return writeCommandError(ctx, "item.not_found", "item was not found", 1);
        const item = items.array.items[0];
        var fields: [32]nodeforge.cli_document.Field = undefined;
        var field_count: usize = 0;
        var iterator = item.object.iterator();
        while (iterator.next()) |entry| {
            if (field_count == fields.len) return error.TooManyItemFields;
            fields[field_count] = .{ .key = entry.key_ptr.*, .value = try jsonDisplay(ctx.allocator, entry.value_ptr.*), .section = "stored" };
            field_count += 1;
        }
        const sections = [_]nodeforge.cli_document.Section{.{ .key = "stored", .title = "Stored" }};
        const title = try std.fmt.allocPrint(ctx.allocator, "Item {s}", .{item_identity.?});
        const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = item }, .{});
        try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = fields[0..field_count] } }, .json = json });
        return;
    }
    var patch: nodeforge.item_mutation.Patch = .{
        .operation = if (std.mem.eql(u8, command_name, "add")) .add else if (std.mem.eql(u8, command_name, "set")) .set else if (std.mem.eql(u8, command_name, "remove")) .remove else .move,
        .key = key,
        .identity = if (std.mem.eql(u8, command_name, "add")) "" else ctx.positional_args[2],
    };
    var unset_value: [1][]const u8 = undefined;
    if (std.mem.eql(u8, command_name, "set")) {
        const unset = ctx.flag("unset", []const u8);
        if (unset.len != 0) {
            unset_value[0] = unset;
            patch.unset = &unset_value;
        }
    }
    if (std.mem.eql(u8, command_name, "move")) {
        const before = ctx.flag("before", []const u8);
        const after = ctx.flag("after", []const u8);
        if ((before.len == 0) == (after.len == 0)) {
            try writeCommandError(ctx, "item.invalid_move", "item move requires exactly one of --before or --after", 2);
            return;
        }
        patch.before = if (before.len == 0) null else before;
        patch.after = if (after.len == 0) null else after;
    }
    const field_start: usize = if (std.mem.eql(u8, command_name, "add")) 2 else 3;
    if (patch.operation == .add or patch.operation == .set) for (ctx.positional_args[field_start..]) |assignment| {
        const equal = std.mem.indexOfScalar(u8, assignment, '=') orelse return itemUsageError(ctx, "fields must use field=value");
        const field = assignment[0..equal];
        const value = assignment[equal + 1 ..];
        try applyItemField(ctx, &patch, field, value);
    };
    if (patch.operation == .add) patch.identity = patch.id orelse patch.name orelse return itemUsageError(ctx, "add requires the ItemSpec identity field");
    var reason: [512]u8 = undefined;
    const result = nodeforge.management_client.itemMutation(ctx.io, config.value.server.http_port, owner_text, resource, patch, ctx.flag("force", bool), &reason);
    if (!result.healthy) return reportMutationFailure(ctx, result, "item mutation failed");
    const human = try std.fmt.allocPrint(ctx.allocator, "{s} {s}:{s}", .{ command_name, key, patch.identity });
    try renderCommandResult(ctx, human, .{ .resource = resource, .key = key, .operation = command_name, .identity = patch.identity });
}

fn itemValuesHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const owner_text = ctx.command.parent.?.parent.?.cmd_options.name;
    const resource_identity = ctx.positional_args[0];
    const key = ctx.positional_args[1];
    const item_identity = ctx.positional_args[2];
    const field = ctx.positional_args[3];
    const expected_key = if (std.mem.eql(u8, owner_text, "node")) "overrides.system.users" else "system.users";
    if (!std.mem.eql(u8, key, expected_key) or (!std.mem.eql(u8, field, "groups") and !std.mem.eql(u8, field, "ssh_authorized_keys"))) {
        try writeCommandError(ctx, "item.unknown_field", "use users groups or ssh_authorized_keys", 2);
        return;
    }
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const command_name = ctx.command.cmd_options.name;
    if (std.mem.eql(u8, command_name, "list-values")) {
        const response = try allocManagementResponse(ctx);
        defer ctx.allocator.free(response);
        const body = nodeforge.management_client.itemValuesJson(ctx.io, config.value.server.http_port, owner_text, resource_identity, key, item_identity, field, response) catch null orelse {
            try writeCommandError(ctx, "item.values_query_failed", "item values query failed", 1);
            return;
        };
        const Response = struct { result: struct { values: []const []const u8 } };
        const parsed = try std.json.parseFromSlice(Response, ctx.allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const cells = try ctx.allocator.alloc([1][]const u8, parsed.value.result.values.len);
        const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, parsed.value.result.values.len);
        const jsonl = try ctx.allocator.alloc([]const u8, parsed.value.result.values.len);
        for (parsed.value.result.values, 0..) |value, index| {
            cells[index] = .{value};
            rows[index] = .{ .cells = &cells[index] };
            jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .value = value } }, .{});
        }
        const columns = [_]nodeforge.cli_table.Column{.{ .key = "value", .title = "VALUE" }};
        try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No values." } }, .json = body, .jsonl = jsonl });
        return;
    }
    const operation = if (std.mem.eql(u8, command_name, "add-values")) "add" else if (std.mem.eql(u8, command_name, "remove-values")) "remove" else if (std.mem.eql(u8, command_name, "replace-values")) "replace" else "clear";
    var values = if (ctx.positional_args.len > 4) ctx.positional_args[4..] else &.{};
    var file_values: std.ArrayList([]const u8) = .empty;
    defer file_values.deinit(ctx.allocator);
    var file_bytes: ?[]u8 = null;
    defer if (file_bytes) |bytes| ctx.allocator.free(bytes);
    if (std.mem.eql(u8, command_name, "replace-values")) {
        const path = ctx.flag("from-file", []const u8);
        if (path.len != 0) {
            if (values.len != 0) {
                try writeCommandError(ctx, "property.invalid_input", "values and --from-file are mutually exclusive", 2);
                return;
            }
            const bytes = if (std.mem.eql(u8, path, "-")) ctx.reader.allocRemaining(ctx.allocator, .limited(8 * 1024 * 1024)) catch {
                try writeCommandError(ctx, "property.stdin_unreadable", "property input could not be read from stdin", 1);
                return;
            } else std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(8 * 1024 * 1024)) catch {
                try writeCommandError(ctx, "property.file_unreadable", "property input file could not be read", 1);
                return;
            };
            file_bytes = bytes;
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                const value = std.mem.trim(u8, line, " \t\r");
                if (value.len == 0 or value[0] == '#') continue;
                try file_values.append(ctx.allocator, value);
            }
            values = file_values.items;
        }
    }
    var reason: [512]u8 = undefined;
    const mutation = nodeforge.management_client.itemValuesMutation(ctx.io, config.value.server.http_port, owner_text, resource_identity, item_identity, operation, key, field, values, ctx.flag("force", bool), &reason);
    if (!mutation.healthy) {
        // v0.2.3 §8.3：与 reportMutationFailure 同一映射，避免硬编码 exit 1
        // 把 revision 冲突/前置条件错误错归为本地错误。
        const exit_code = if (!mutation.reachable) 6 else mapErrorToExitCode(mutation.http_status, mutation.error_code);
        try writeCommandError(ctx, "item.values_mutation_failed", if (mutation.reason.len == 0) "item values mutation failed" else mutation.reason, exit_code);
        return;
    }
    try renderCommandResult(ctx, "item values updated", .{ .updated = true, .resource = resource_identity, .key = key, .item = item_identity, .field = field, .operation = operation });
}

fn replaceItemsHandler(ctx: zli.CommandContext) !void {
    const owner_text = ctx.direct_parent.cmd_options.name;
    const owner: nodeforge.cli_properties.Owner = if (std.mem.eql(u8, owner_text, "node")) .node else .profile;
    const resource = ctx.positional_args[0];
    const key = ctx.positional_args[1];
    const spec = nodeforge.cli_properties.collection(owner, key) orelse return itemUsageError(ctx, "unknown structured collection key");
    if (spec.item_spec == null or spec.mutability != .mutable) return itemUsageError(ctx, "collection does not support replacement");
    const clear = std.mem.eql(u8, ctx.command.cmd_options.name, "clear-items");
    if (clear) return sendItemReplacement(ctx, owner_text, resource, .{ .operation = .clear, .key = key });
    const path = ctx.flag("from-file", []const u8);
    if (path.len == 0) return itemUsageError(ctx, "replace-items requires --from-file");
    const input = ctx.flag("input", []const u8);
    if (!std.mem.eql(u8, input, "json") and !std.mem.eql(u8, input, "yaml")) return itemUsageError(ctx, "--input must be yaml or json");
    const bytes = if (std.mem.eql(u8, path, "-")) ctx.reader.allocRemaining(ctx.allocator, .limited(8 * 1024 * 1024)) catch return itemUsageError(ctx, "structured stdin is unreadable") else std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(8 * 1024 * 1024)) catch return itemUsageError(ctx, "structured input file is unreadable");
    defer ctx.allocator.free(bytes);
    if (!std.unicode.utf8ValidateSlice(bytes)) return itemUsageError(ctx, "structured input must be UTF-8");
    if (std.mem.eql(u8, key, "install.storage.partitions") or std.mem.eql(u8, key, "overrides.install.storage.partitions")) {
        if (std.mem.eql(u8, input, "yaml")) {
            const items = parseYamlPartitions(ctx.allocator, bytes) catch return itemUsageError(ctx, "invalid partition YAML");
            defer ctx.allocator.free(items);
            return sendItemReplacement(ctx, owner_text, resource, .{ .operation = .replace, .key = key, .partitions = items });
        } else {
            const parsed = std.json.parseFromSlice([]const model.PartitionConfig, ctx.allocator, bytes, .{ .allocate = .alloc_always }) catch return itemUsageError(ctx, "invalid partition array");
            defer parsed.deinit();
            return sendItemReplacement(ctx, owner_text, resource, .{ .operation = .replace, .key = key, .partitions = parsed.value });
        }
    }
    if (std.mem.eql(u8, key, "system.users") or std.mem.eql(u8, key, "overrides.system.users")) {
        if (std.mem.eql(u8, input, "yaml")) {
            const items = parseYamlUsers(ctx.allocator, bytes) catch return itemUsageError(ctx, "invalid user YAML");
            defer ctx.allocator.free(items);
            return sendItemReplacement(ctx, owner_text, resource, .{ .operation = .replace, .key = key, .users = items });
        } else {
            const parsed = std.json.parseFromSlice([]const model.TargetUserConfig, ctx.allocator, bytes, .{ .allocate = .alloc_always }) catch return itemUsageError(ctx, "invalid user array");
            defer parsed.deinit();
            return sendItemReplacement(ctx, owner_text, resource, .{ .operation = .replace, .key = key, .users = parsed.value });
        }
    }
    if (std.mem.eql(u8, key, "network.routes")) {
        if (std.mem.eql(u8, input, "yaml")) {
            const items = parseYamlRoutes(ctx.allocator, bytes) catch return itemUsageError(ctx, "invalid route YAML");
            defer ctx.allocator.free(items);
            return sendItemReplacement(ctx, owner_text, resource, .{ .operation = .replace, .key = key, .routes = items });
        } else {
            const parsed = std.json.parseFromSlice([]const model.RouteConfig, ctx.allocator, bytes, .{ .allocate = .alloc_always }) catch return itemUsageError(ctx, "invalid route array");
            defer parsed.deinit();
            return sendItemReplacement(ctx, owner_text, resource, .{ .operation = .replace, .key = key, .routes = parsed.value });
        }
    }
    return itemUsageError(ctx, "structured replacement is not implemented for this key");
}

const YamlField = struct { starts_item: bool, key: []const u8, value: []const u8 };

fn yamlField(line_raw: []const u8) !?YamlField {
    const line = std.mem.trim(u8, line_raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    const starts_item = line[0] == '-';
    const body = std.mem.trimStart(u8, if (starts_item) line[1..] else line, " \t");
    if (body.len == 0) return YamlField{ .starts_item = true, .key = "", .value = "" };
    const colon = std.mem.indexOfScalar(u8, body, ':') orelse return error.InvalidYaml;
    const key = std.mem.trim(u8, body[0..colon], " \t");
    var value = std.mem.trim(u8, body[colon + 1 ..], " \t");
    if (key.len == 0 or value.len == 0 or std.mem.indexOfAny(u8, key, "&*{}[]") != null) return error.InvalidYaml;
    if (value.len >= 2 and ((value[0] == '\'' and value[value.len - 1] == '\'') or (value[0] == '"' and value[value.len - 1] == '"'))) value = value[1 .. value.len - 1];
    return .{ .starts_item = starts_item, .key = key, .value = value };
}

fn yamlBool(value: []const u8) !bool {
    return if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else error.InvalidYaml;
}

fn parseYamlPartitions(allocator: std.mem.Allocator, bytes: []const u8) ![]model.PartitionConfig {
    var items: std.ArrayList(model.PartitionConfig) = .empty;
    errdefer items.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| if (try yamlField(line)) |field| {
        if (field.starts_item) try items.append(allocator, .{});
        if (field.key.len == 0) continue;
        if (items.items.len == 0) return error.InvalidYaml;
        const item = &items.items[items.items.len - 1];
        if (std.mem.eql(u8, field.key, "id")) item.id = field.value else if (std.mem.eql(u8, field.key, "mount")) item.mount = field.value else if (std.mem.eql(u8, field.key, "filesystem")) item.filesystem = field.value else if (std.mem.eql(u8, field.key, "size_mib")) item.size_mib = try std.fmt.parseInt(u32, field.value, 10) else if (std.mem.eql(u8, field.key, "grow")) item.grow = try yamlBool(field.value) else if (std.mem.eql(u8, field.key, "kind")) item.kind = std.meta.stringToEnum(model.PartitionKind, field.value) orelse return error.InvalidYaml else return error.InvalidYaml;
    };
    return items.toOwnedSlice(allocator);
}

fn parseYamlUsers(allocator: std.mem.Allocator, bytes: []const u8) ![]model.TargetUserConfig {
    var items: std.ArrayList(model.TargetUserConfig) = .empty;
    errdefer items.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| if (try yamlField(line)) |field| {
        if (field.starts_item) try items.append(allocator, .{ .name = "" });
        if (field.key.len == 0) continue;
        if (items.items.len == 0) return error.InvalidYaml;
        const item = &items.items[items.items.len - 1];
        if (std.mem.eql(u8, field.key, "name")) item.name = field.value else if (std.mem.eql(u8, field.key, "uid")) item.uid = try std.fmt.parseInt(u32, field.value, 10) else if (std.mem.eql(u8, field.key, "shell")) item.shell = field.value else if (std.mem.eql(u8, field.key, "locked")) item.locked = try yamlBool(field.value) else if (std.mem.eql(u8, field.key, "password")) item.password = field.value else if (std.mem.eql(u8, field.key, "sudo")) item.sudo = try yamlBool(field.value) else return error.InvalidYaml;
    };
    return items.toOwnedSlice(allocator);
}

fn parseYamlRoutes(allocator: std.mem.Allocator, bytes: []const u8) ![]model.RouteConfig {
    var items: std.ArrayList(model.RouteConfig) = .empty;
    errdefer items.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| if (try yamlField(line)) |field| {
        if (field.starts_item) try items.append(allocator, .{ .id = "", .destination = "", .gateway = "" });
        if (field.key.len == 0) continue;
        if (items.items.len == 0) return error.InvalidYaml;
        const item = &items.items[items.items.len - 1];
        if (std.mem.eql(u8, field.key, "id")) item.id = field.value else if (std.mem.eql(u8, field.key, "destination")) item.destination = field.value else if (std.mem.eql(u8, field.key, "gateway")) item.gateway = field.value else if (std.mem.eql(u8, field.key, "metric")) item.metric = try std.fmt.parseInt(u32, field.value, 10) else return error.InvalidYaml;
    };
    return items.toOwnedSlice(allocator);
}

fn sendItemReplacement(ctx: zli.CommandContext, owner: []const u8, resource: []const u8, replacement: nodeforge.item_mutation.Replacement) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [512]u8 = undefined;
    const result = nodeforge.management_client.itemReplacement(ctx.io, config.value.server.http_port, owner, resource, replacement, ctx.flag("force", bool), &reason);
    if (!result.healthy) return reportMutationFailure(ctx, result, "item replacement failed");
    const human = try std.fmt.allocPrint(ctx.allocator, "{s} {s} on {s}", .{ @tagName(replacement.operation), replacement.key, resource });
    try renderCommandResult(ctx, human, .{ .resource = resource, .key = replacement.key, .operation = replacement.operation });
}

fn applyItemField(ctx: zli.CommandContext, patch: *nodeforge.item_mutation.Patch, field: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, field, "id")) patch.id = value else if (std.mem.eql(u8, field, "name")) patch.name = value else if (std.mem.eql(u8, field, "mount")) patch.mount = value else if (std.mem.eql(u8, field, "filesystem")) patch.filesystem = value else if (std.mem.eql(u8, field, "shell")) patch.shell = value else if (std.mem.eql(u8, field, "password")) patch.password = value else if (std.mem.eql(u8, field, "destination")) patch.destination = value else if (std.mem.eql(u8, field, "gateway")) patch.gateway = value else if (std.mem.eql(u8, field, "size_mib")) patch.size_mib = std.fmt.parseInt(u32, value, 10) catch return itemUsageError(ctx, "size_mib must be an integer") else if (std.mem.eql(u8, field, "uid")) patch.uid = std.fmt.parseInt(u32, value, 10) catch return itemUsageError(ctx, "uid must be an integer") else if (std.mem.eql(u8, field, "metric")) patch.metric = std.fmt.parseInt(u32, value, 10) catch return itemUsageError(ctx, "metric must be an integer") else if (std.mem.eql(u8, field, "grow")) patch.grow = parseBoolValue(value) catch return itemUsageError(ctx, "grow must be true or false") else if (std.mem.eql(u8, field, "locked")) patch.locked = parseBoolValue(value) catch return itemUsageError(ctx, "locked must be true or false") else if (std.mem.eql(u8, field, "sudo")) patch.sudo = parseBoolValue(value) catch return itemUsageError(ctx, "sudo must be true or false") else if (std.mem.eql(u8, field, "kind")) patch.kind = std.meta.stringToEnum(nodeforge.model.PartitionKind, value) orelse return itemUsageError(ctx, "unknown partition kind") else return itemUsageError(ctx, "unknown ItemSpec field");
}
fn parseBoolValue(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}
fn itemUsageError(ctx: zli.CommandContext, message: []const u8) error{InvalidItemUsage} {
    writeCommandError(ctx, "item.invalid", message, 2) catch {};
    return error.InvalidItemUsage;
}

fn setupHandler(ctx: zli.CommandContext) !void {
    const p = nodeforge.paths.require();
    const dry_run = ctx.flag("dry-run", bool);
    const import_config_path = ctx.flag("import-config", []const u8);
    const log_level_text = ctx.flag("log-level", []const u8);
    const requested_log_level: ?nodeforge.model.LogLevel = if (log_level_text.len == 0)
        null
    else
        std.meta.stringToEnum(nodeforge.model.LogLevel, log_level_text) orelse return setupFlagError(ctx, "--log-level must be debug, info, warn, or err");
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
        if (ctx.flag("non-interactive", bool)) {
            try errorWriter(ctx).writeAll("error: setup: destructive operation requires --yes in non-interactive mode\n");
            setExitCode(ctx, 1);
            return;
        }
        if (purge_all)
            try ctx.writer.print("This will permanently purge NodeForge state, catalog, assets, work files, logs, backups, and migration history under {s}, then regenerate the deployment. Continue? [y/N]: ", .{p.install_root})
        else if (ctx.flag("reset-all", bool))
            try ctx.writer.print("This will back up and reset NodeForge startup configuration and runtime state under {s}. Continue? [y/N]: ", .{p.install_root})
        else
            try ctx.writer.print("This will modify {s}. Continue? [y/N]: ", .{p.install_root});
        try ctx.writer.flush();
        const answer = ctx.reader.takeDelimiter('\n') catch null;
        if (answer == null or !(std.ascii.eqlIgnoreCase(std.mem.trim(u8, answer.?, " \t\r"), "y") or std.ascii.eqlIgnoreCase(std.mem.trim(u8, answer.?, " \t\r"), "yes"))) {
            setExitCode(ctx, 1);
            return;
        }
    }
    const network: nodeforge.setup.Network = .{
        .log_level = requested_log_level orelse .debug,
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
        if (imported_config.?.value.schema_version != 4 or imported_config.?.value.distros.len != 0 or imported_config.?.value.profiles.len != 0 or imported_config.?.value.nodes.len != 0 or imported_config.?.value.provisioning_bundles.len != 0) {
            try errorWriter(ctx).writeAll("error: config: imported startup config must use schema 4 and must not embed catalog entities\n");
            imported_config.?.deinit();
            setExitCode(ctx, 1);
            return;
        }
        if (requested_log_level) |level| imported_config.?.value.logging.level = level;
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
    var catalog = try nodeforge.catalog_store.load(ctx.io, ctx.allocator, p.catalog_dir);
    defer catalog.deinit();
    var installed_config: ?std.json.Parsed(nodeforge.model.AppConfig) = null;
    if (imported_config == null) installed_config = try nodeforge.config.load(ctx.io, ctx.allocator, p.config_path);
    defer if (installed_config) |*current| current.deinit();
    if (imported_config == null) {
        if (requested_log_level) |level| installed_config.?.value.logging.level = level;
    }
    const startup_config = if (imported_config) |*candidate| &candidate.value else &installed_config.?.value;
    const effective = nodeforge.model.projectCatalog(startup_config.*, &catalog.value);
    try nodeforge.config_validate.validate(&effective, &catalog.value);
    const unit = try nodeforge.setup.renderSystemd(ctx.allocator, p);
    defer ctx.allocator.free(unit);
    // M4.9：setup 是 startup config 的唯一写入口。发布前必须把 candidate
    // 与当前 catalog 联合校验；requested/applied provenance 是历史事实，
    // 配置导入不得改写。运行中的 daemon 只在重启后加载新 pair。
    if (imported_config != null or requested_log_level != null) try nodeforge.config_store.save(ctx.io, ctx.allocator, p.config_path, startup_config);
    try nodeforge.dhcp_store.atomicWrite(ctx.io, p.service_path, unit);
    try nodeforge.setup.installEnvironment(ctx.io, ctx.allocator, p);
    const schema_text = try std.fmt.allocPrint(ctx.allocator, "{d}", .{startup_config.schema_version});
    defer ctx.allocator.free(schema_text);
    if (imported_config != null)
        try views.success(ctx.writer, "deployment reconfigured", &.{ .{ .label = "Install root", .value = p.install_root }, .{ .label = "Config source", .value = import_config_path }, .{ .label = "Config schema", .value = schema_text }, .{ .label = "Catalog layout", .value = "1" }, .{ .label = "Systemd unit", .value = p.service_path }, .{ .label = "Service", .value = "unchanged; run systemctl daemon-reload/restart nodeforged" } })
    else
        try views.success(ctx.writer, "deployment reconfigured", &.{ .{ .label = "Install root", .value = p.install_root }, .{ .label = "Config schema", .value = schema_text }, .{ .label = "Catalog layout", .value = "1" }, .{ .label = "Systemd unit", .value = p.service_path }, .{ .label = "Service", .value = "unchanged; run systemctl daemon-reload/restart nodeforged" } });
}

fn setupFlagError(ctx: zli.CommandContext, message: []const u8) void {
    errorWriter(ctx).print("error: setup: {s}\n", .{message}) catch {};
    setExitCode(ctx, 2);
}

/// 移除 `--purge-all` 覆盖的每个承载历史的路径。
///
/// 二进制/marker/config/unit 保留。受管工作文件不保留：导入是
/// 临时的，可能达数 GiB，且不得跨越全新重置边界。
/// `repairDirectories` 重建空的规范工作/导入布局。
fn purgeSetupHistory(ctx: zli.CommandContext, p: *const nodeforge.paths.Paths) !void {
    const backups_dir = try std.fmt.allocPrint(ctx.allocator, "{s}/backups", .{p.install_root});
    defer ctx.allocator.free(backups_dir);
    std.Io.Dir.cwd().deleteTree(ctx.io, backups_dir) catch {};
    std.Io.Dir.cwd().deleteTree(ctx.io, p.logs_dir) catch {};
    // 中断的 ISO 导入可能包含从安装介质复制的只读目录树。
    // 优先使用原生删除。若遍历被拒绝，
    // 仅在已校验、已派生的工作路径下恢复属主权限，并
    // 用有界 argv 重试；命令失败会向上传播，而不是报告
    // 清除成功却留下陈旧数据。
    std.Io.Dir.cwd().deleteTree(ctx.io, p.work_dir) catch {
        try runRequired(ctx, &.{ "chmod", "-R", "u+rwx", p.work_dir });
        try runRequired(ctx, &.{ "rm", "-rf", "--", p.work_dir });
    };
    for ([_][]const u8{p.config_path}) |path| {
        const migration_backup = try std.fmt.allocPrint(ctx.allocator, "{s}.m4.7.bak", .{path});
        defer ctx.allocator.free(migration_backup);
        std.Io.Dir.cwd().deleteFile(ctx.io, migration_backup) catch {};
    }
    try nodeforge.setup.repairDirectories(ctx.io, ctx.allocator, p);
}

/// 将单元的发布与激活作为单个可恢复的生命周期操作。若
/// systemctl、模型加载或 loopback 健康探测失败，则恢复
/// 之前的链接与 enabled/active 状态。
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
    // 改为拷贝而非移动，使失败激活在之前的服务状态恢复后
    // 仍保留单元备份供诊断。
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
        .{ .name = "name", .description = "Override only the ISO-basename-derived InstallSource base for unrecognized media; e.g. kylin-v10-sp3-2403", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "qualifier", .description = "Append a canonical qualifier to the ISO-derived install-source name; e.g. gpu or site-a", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "version", .description = "Override auto-detected catalog version; e.g. V10-SP3-2403-Release-20240426. Empty = auto-detect", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "arch", .description = "Override auto-detected architecture; allowed: x86_64, aarch64; omit to auto-detect", .type = .String, .default_value = .{ .String = "" } },
    });
    return command;
}

fn assetImportCommand(init_options: zli.InitOptions) !*zli.Command {
    const command = try zli.Command.init(init_options, .{ .name = "register", .description = "Register an existing TFTP asset and its SHA-256" }, assetImportHandler);
    try addConfigPathFlag(command);
    try addOutputFlag(command);
    try addDebugFlag(command);
    try command.addFlags(&.{
        .{ .name = "type", .description = assetKindFlagHelp, .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "name", .description = "Unique catalog name; e.g. rocky-9.7-aarch64-kernel", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "path", .description = "Path relative to tftp.asset_root; e.g. boot/rocky/9.7/aarch64/vmlinuz", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "distro", .description = "Distro name, used with --version and --arch; e.g. rocky", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "version", .description = "Distro version, used with --distro and --arch; e.g. 9.7", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "arch", .description = "Architecture used with --distro and --version; allowed: x86_64, aarch64", .type = .String, .default_value = .{ .String = "" } },
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
    _ = outputFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    const view = statusProbe(ctx.io, ctx.allocator, ctx.flag("config", []const u8), debug, errorWriter(ctx)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer ctx.allocator.free(view.server_ip);
    var human: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer human.deinit();
    try views.status(&human.writer, view);
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = view.ok, .result = view }, .{});
    try renderOutputDocument(ctx, .{ .human = .{ .text = std.mem.trimEnd(u8, human.written(), "\n") }, .json = json });
    setExitCode(ctx, if (view.ok) 0 else 1);
}

const OperationView = struct {
    id: []const u8,
    kind: []const u8,
    state: []const u8,
    created_at: i64,
    updated_at: i64,
    result: []const u8,
    error_code: []const u8,
};
const OperationEnvelope = struct { ok: bool, result: OperationView };

fn operationListHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 6);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = nodeforge.management_client.operationsJson(ctx.io, config.value.server.http_port, response) catch null orelse {
        try writeCommandError(ctx, "operation.unavailable", "daemon operation list is unavailable", 6);
        return;
    };
    const Envelope = struct { ok: bool, result: struct { items: []const OperationView } };
    const parsed = std.json.parseFromSlice(Envelope, ctx.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
        try writeCommandError(ctx, "operation.invalid_response", "daemon returned a malformed operation list", 1);
        return;
    };
    defer parsed.deinit();
    var human: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer human.deinit();
    if (parsed.value.result.items.len == 0) {
        try human.writer.writeAll("No retained operations.");
    } else {
        try human.writer.writeAll("ID                                KIND                   STATE       UPDATED\n");
        for (parsed.value.result.items) |op| try human.writer.print("{s}  {s}  {s}  {d}\n", .{ op.id, op.kind, op.state, op.updated_at });
    }
    try renderOutputDocument(ctx, .{ .human = .{ .text = std.mem.trimEnd(u8, human.written(), "\n") }, .json = body });
}

fn operationShowHandler(ctx: zli.CommandContext) !void {
    try operationRead(ctx, false);
}

fn operationWaitHandler(ctx: zli.CommandContext) !void {
    try operationRead(ctx, true);
}

fn operationRead(ctx: zli.CommandContext, wait: bool) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 6);
        return;
    };
    defer config.deinit();
    const id = ctx.getArg("id") orelse return;
    const timeout_seconds: i64 = if (wait) ctx.flag("timeout", i64) else 0;
    if (wait and (timeout_seconds <= 0 or timeout_seconds > 86_400)) {
        try writeCommandError(ctx, "operation.invalid_timeout", "--timeout must be between 1 and 86400 seconds", 2);
        return;
    }
    const attempts: usize = if (wait) @intCast(timeout_seconds * 4) else 1;
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    var attempt: usize = 0;
    while (attempt < attempts) : (attempt += 1) {
        const body = nodeforge.management_client.operationJson(ctx.io, config.value.server.http_port, id, response) catch null orelse {
            try writeCommandError(ctx, "operation.unavailable", "operation is not found or daemon is unavailable", 6);
            return;
        };
        const parsed = std.json.parseFromSlice(OperationEnvelope, ctx.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            try writeCommandError(ctx, "operation.invalid_response", "daemon returned a malformed operation", 1);
            return;
        };
        defer parsed.deinit();
        const op = parsed.value.result;
        const terminal = std.mem.eql(u8, op.state, "succeeded") or std.mem.eql(u8, op.state, "failed");
        if (!wait or terminal) {
            const human = try std.fmt.allocPrint(ctx.allocator, "id: {s}\nkind: {s}\nstate: {s}\nresult: {s}\nerror_code: {s}\ncreated_at: {d}\nupdated_at: {d}", .{ op.id, op.kind, op.state, op.result, op.error_code, op.created_at, op.updated_at });
            try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = body });
            if (std.mem.eql(u8, op.state, "failed")) setExitCode(ctx, 5);
            return;
        }
        std.Io.sleep(ctx.io, .fromMilliseconds(250), .awake) catch {};
    }
    try writeCommandError(ctx, "operation.wait_timeout", "operation is still running; it was not cancelled", 6);
}

/// 加载并联合校验启动配置与 catalog，不修改任何文件。
fn configValidateHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    const config_path = ctx.flag("config", []const u8);
    const catalog_path = ctx.flag("catalog", []const u8);
    var parsed_config = loadConfig(ctx.io, ctx.allocator, config_path, errorWriter(ctx), debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    var parsed_catalog = loadCatalogOrEmpty(ctx.io, ctx.allocator, catalog_path, errorWriter(ctx), debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_catalog.deinit();
    const effective = nodeforge.model.projectCatalog(parsed_config.value, parsed_catalog.value());
    nodeforge.config_validate.validate(&effective, parsed_catalog.value()) catch |err| {
        try printValidationError(errorWriter(ctx), "config", config_path, err, debug);
        setExitCode(ctx, 1);
        return;
    };
    try renderCommandResult(ctx, "config valid", .{ .config = config_path, .catalog = catalog_path });
}

/// 加载启动配置并将规范化 JSON 写到 stdout。
fn configExportHandler(ctx: zli.CommandContext) !void {
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    // schema 永久默认 v4；只拒绝 legacy 内联实体格式。
    if (parsed_config.value.schema_version != 4 or parsed_config.value.distros.len != 0 or parsed_config.value.profiles.len != 0 or parsed_config.value.nodes.len != 0 or parsed_config.value.provisioning_bundles.len != 0) {
        try errorWriter(ctx).writeAll("error: config: legacy inline entities require nodeforge setup --reconfigure\n");
        setExitCode(ctx, 1);
        return;
    }
    const bytes = try nodeforge.config_store.render(ctx.allocator, &parsed_config.value);
    defer ctx.allocator.free(bytes);
    try ctx.writer.writeAll(bytes);
}

/// 加载配置和 catalog 并校验 catalog 对象及跨文件关系。
fn catalogValidateHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    const config_path = ctx.flag("config", []const u8);
    const catalog_path = ctx.flag("catalog", []const u8);
    var parsed_config = loadConfig(ctx.io, ctx.allocator, config_path, errorWriter(ctx), debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    var parsed_catalog = loadCatalogOrEmpty(ctx.io, ctx.allocator, catalog_path, errorWriter(ctx), debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_catalog.deinit();
    const effective = nodeforge.model.projectCatalog(parsed_config.value, parsed_catalog.value());
    nodeforge.config_validate.validate(&effective, parsed_catalog.value()) catch |err| {
        try printValidationError(errorWriter(ctx), "catalog", catalog_path, err, debug);
        setExitCode(ctx, 1);
        return;
    };
    try renderCommandResult(ctx, "catalog valid", .{ .catalog = catalog_path });
}

/// 加载 catalog 并将规范化 JSON 写到 stdout；文件缺失时导出空 catalog。
fn catalogExportHandler(ctx: zli.CommandContext) !void {
    var parsed_catalog = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_catalog.deinit();
    const bytes = try nodeforge.catalog_store.render(ctx.allocator, parsed_catalog.value());
    defer ctx.allocator.free(bytes);
    try ctx.writer.writeAll(bytes);
}

fn catalogShowHandler(ctx: zli.CommandContext) !void {
    try catalogResourceHandler(ctx, "install-sources", ctx.positional_args[0]);
}

/// 通过本机 daemon 注册一个已经位于受管根目录中的资产。
///
/// CLI 只解析并校验资产类型、逻辑名称、受管相对路径和可选 distro tuple；
/// 文件打开、SHA-256 计算、候选模型校验及 catalog 原子发布均由 daemon
/// 管理 API 完成。因此本命令要求 daemon 可达，不是 fresh setup 的离线写入口。
/// daemon 拒绝或不可达时返回退出码 1，CLI 参数错误返回退出码 2。
fn initrdBuildOperationHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const name = ctx.getArg("name") orelse return;
    const source = ctx.flag("from-install-source", []const u8);
    const kernel_release = ctx.flag("kernel-release", []const u8);
    if (!nodeforge.config_validate.validLogicalId(name) or !nodeforge.config_validate.validLogicalId(source) or kernel_release.len == 0 or kernel_release.len > 192 or std.mem.indexOfAny(u8, kernel_release, "/\\\x00") != null) {
        try writeCommandError(ctx, "initrd.invalid_input", "durable initrd build requires a safe name, --from-install-source and --kernel-release", 2);
        return;
    }
    // Explicit tuple flags may be supplied by automation, but the install source is
    // the authoritative tuple and the daemon validates it from one immutable model pair.
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    var reason: [256]u8 = undefined;
    const detach = ctx.flag("detach", bool);
    const body = nodeforge.management_client.initrdBuildJson(ctx.io, config.value.server.http_port, name, source, kernel_release, detach, response, &reason) catch null orelse {
        const detail = std.mem.sliceTo(&reason, 0);
        try writeCommandError(ctx, "initrd.build_failed", if (detail.len == 0) "initrd durable operation failed" else detail, 1);
        return;
    };
    const Envelope = struct { ok: bool, result: OperationView };
    const parsed = std.json.parseFromSlice(Envelope, ctx.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
        // Cache-hit response intentionally has no operation shape.
        const human = try std.fmt.allocPrint(ctx.allocator, "initrd already present: {s}", .{name});
        try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = body });
        return;
    };
    defer parsed.deinit();
    const op = parsed.value.result;
    const human = if (detach)
        try std.fmt.allocPrint(ctx.allocator, "initrd build submitted: operation {s}", .{op.id})
    else
        try std.fmt.allocPrint(ctx.allocator, "initrd built and registered: {s} (operation {s})", .{ name, op.id });
    try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = body });
}

fn assetImportHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    const kind = std.meta.stringToEnum(nodeforge.model.AssetKind, ctx.flag("type", []const u8)) orelse {
        try writeCommandError(ctx, "asset.invalid_type", "unsupported --type", 2);
        return;
    };
    const name = ctx.flag("name", []const u8);
    const path = ctx.flag("path", []const u8);
    if (name.len == 0 or path.len == 0) {
        try writeCommandError(ctx, "asset.invalid_input", "--name and --path are required", 2);
        return;
    }
    const distro_value = ctx.flag("distro", []const u8);
    const version_value = ctx.flag("version", []const u8);
    const arch_value = ctx.flag("arch", []const u8);
    const has_tuple = distro_value.len != 0 or version_value.len != 0 or arch_value.len != 0;
    if (has_tuple and (distro_value.len == 0 or version_value.len == 0 or arch_value.len == 0)) {
        try writeCommandError(ctx, "asset.invalid_platform", "--distro, --version and --arch must be used together", 2);
        return;
    }
    const arch = if (has_tuple) std.meta.stringToEnum(nodeforge.model.Arch, arch_value) orelse {
        try writeCommandError(ctx, "asset.invalid_arch", "unsupported --arch", 2);
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
        if (debug) try errorWriter(ctx).print("debug: asset: cause={t}\n", .{err});
        try writeCommandError(ctx, "asset.import_failed", "asset import request failed", 1);
        return;
    };
    if (!imported) {
        try writeCommandError(ctx, "asset.import_rejected", "daemon rejected asset import", 1);
        return;
    }
    const human = try std.fmt.allocPrint(ctx.allocator, "asset imported: {s}", .{name});
    try renderCommandResult(ctx, human, .{ .name = name });
}

/// `assets import` 的 ISO 安装源导入处理器。
///
/// 完整流程：
/// 1. 加载启动配置获取 daemon HTTP 端口
/// 2. 校验 --arch 参数（如果提供了的话）
/// 3. 调用 `stageInstallIso` 将 ISO 原子复制到 daemon 受管的暂存目录
/// 4. 通过管理 API 请求 daemon 执行 loop mount、介质检测和 catalog 发布
/// 5. daemon 返回后，defer 清理暂存文件
/// 6. 成功响应同时返回 canonical InstallSource；daemon 在同一 catalog
///    publication 中创建 `<source>-install` 默认 Profile
///
/// 安全设计：CLI 永远不将任意宿主路径发送给 daemon，只发送暂存目录中的
/// 不透明 basename。daemon 只在受管目录内操作，杜绝路径穿越攻击。
/// 原始 ISO 文件永远不会被移动或删除。
fn installSourceImportHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    const iso_path = ctx.getArg("iso-path") orelse unreachable;
    const distro = ctx.flag("distro", []const u8);
    const name = ctx.flag("name", []const u8);
    const qualifier = ctx.flag("qualifier", []const u8);
    const version = ctx.flag("version", []const u8);
    const arch = ctx.flag("arch", []const u8);
    if (distro.len != 0 and !nodeforge.config_validate.validLogicalId(distro)) {
        try writeCommandError(ctx, "install-source.invalid_distro", "invalid canonical --distro", 2);
        return;
    }
    if (name.len != 0 and !nodeforge.config_validate.validLogicalId(name)) {
        try writeCommandError(ctx, "install-source.invalid_name", "invalid canonical --name", 2);
        return;
    }
    if (qualifier.len != 0 and !nodeforge.config_validate.validLogicalId(qualifier)) {
        try writeCommandError(ctx, "install-source.invalid_qualifier", "invalid canonical --qualifier", 2);
        return;
    }
    if (arch.len != 0 and std.meta.stringToEnum(nodeforge.model.Arch, arch) == null) {
        try writeCommandError(ctx, "install-source.invalid_arch", "unsupported --arch", 2);
        return;
    }
    const staged = stageInstallIso(ctx.io, ctx.allocator, iso_path) catch |err| {
        if (debug) try errorWriter(ctx).print("debug: install-source: stage cause={t}\n", .{err});
        try writeCommandError(ctx, "install-source.stage_failed", "cannot stage ISO", 1);
        return;
    };
    defer {
        std.Io.Dir.cwd().deleteFile(ctx.io, staged.path) catch {};
        ctx.allocator.free(staged.filename);
        ctx.allocator.free(staged.path);
    }
    try errorWriter(ctx).print("Staged ISO ({d} bytes) from {s}; validating and importing\n", .{ staged.size, iso_path });
    const import_key = installImportKey(staged.sha256, if (name.len == 0) null else name, if (qualifier.len == 0) null else qualifier, if (distro.len == 0) null else distro, if (version.len == 0) null else version, if (arch.len == 0) null else arch);
    const imported = nodeforge.management_client.importInstallSource(ctx.io, parsed_config.value.server.http_port, .{
        .filename = staged.filename,
        .original_filename = std.fs.path.basename(iso_path),
        .content_sha256 = &staged.sha256,
        .idempotency_key = &import_key,
        .name = if (name.len == 0) null else name,
        .qualifier = if (qualifier.len == 0) null else qualifier,
        .distro = if (distro.len == 0) null else distro,
        .version = if (version.len == 0) null else version,
        .arch = if (arch.len == 0) null else arch,
    }) catch |err| {
        if (debug) try errorWriter(ctx).print("debug: install-source: cause={t}\n", .{err});
        try writeCommandError(ctx, "install-source.import_failed", "install source import request failed", 1);
        return;
    };
    if (imported == null) {
        try writeCommandError(ctx, "install-source.import_rejected", "daemon rejected install source import", 1);
        return;
    }
    const source_name = imported.?.name();
    const profile_name = try nodeforge.profile_naming.profileName(ctx.allocator, source_name, null, .install);
    const human = try std.fmt.allocPrint(ctx.allocator, "install source and default profile imported: {s}", .{source_name});
    try renderCommandResult(ctx, human, .{ .path = iso_path, .install_source = source_name, .profile = profile_name });
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

fn installImportKey(content_sha256: [64]u8, name: ?[]const u8, qualifier: ?[]const u8, distro: ?[]const u8, version: ?[]const u8, arch: ?[]const u8) [64]u8 {
    var hash_state = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (.{ @as(?[]const u8, &content_sha256), name, qualifier, distro, version, arch }) |value| {
        if (value) |bytes| hash_state.update(bytes);
        hash_state.update(&.{0});
    }
    var raw: [32]u8 = undefined;
    hash_state.final(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

fn assetListHandler(ctx: zli.CommandContext) !void {
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer loaded.deinit();
    const AssetListItem = struct { name: []const u8, kind: []const u8, path: []const u8 };
    const assets = try ctx.allocator.alloc(AssetListItem, loaded.value().assets.len);
    const cells = try ctx.allocator.alloc([3][]const u8, loaded.value().assets.len);
    const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, loaded.value().assets.len);
    const jsonl = try ctx.allocator.alloc([]const u8, loaded.value().assets.len);
    for (loaded.value().assets, 0..) |item, i| {
        assets[i] = .{ .name = item.name, .kind = @tagName(item.kind), .path = item.path };
        cells[i] = .{ item.name, @tagName(item.kind), item.path };
        rows[i] = .{ .cells = &cells[i] };
        jsonl[i] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = assets[i] }, .{});
    }
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .assets = assets } }, .{});
    const columns = [_]nodeforge.cli_table.Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "kind", .title = "KIND" }, .{ .key = "path", .title = "PATH" } };
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No assets registered." } }, .json = json, .jsonl = jsonl });
}

fn installSourceListHandler(ctx: zli.CommandContext) !void {
    try catalogResourceHandler(ctx, "install-sources", null);
}
fn installSourceShowHandler(ctx: zli.CommandContext) !void {
    try catalogResourceHandler(ctx, "install-sources", ctx.positional_args[0]);
}
fn repositoryListHandler(ctx: zli.CommandContext) !void {
    try catalogResourceHandler(ctx, "repositories", null);
}
fn repositoryShowHandler(ctx: zli.CommandContext) !void {
    try catalogResourceHandler(ctx, "repositories", ctx.positional_args[0]);
}

fn repositoryRenderHandler(ctx: zli.CommandContext) !void {
    // 从已发布 repository 事实生成客户端可直接使用的配置，而不是根据发行版
    // 名称猜测 suite/component。DNF 使用 catalog URL；APT 读取实际 Release。
    _ = outputFromContext(ctx) orelse return;
    const name = ctx.getArg("repository") orelse return;
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, nodeforge.paths.require().catalog_dir, errorWriter(ctx), false) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer loaded.deinit();
    const repository = nodeforge.catalog.findRepository(loaded.value(), name) orelse {
        try writeCommandError(ctx, "repository.not_found", "repository is not registered", 1);
        return;
    };
    const rendered = switch (repository.manager) {
        .dnf => try std.fmt.allocPrint(ctx.allocator,
            \\[{s}]
            \\name=NodeForge {s}
            \\baseurl={s}
            \\enabled=1
            \\gpgcheck={d}
            \\{s}
        , .{ repository.name, repository.name, repository.base_url, @intFromBool(repository.gpg_check), if (repository.gpg_key) |key| try std.fmt.allocPrint(ctx.allocator, "gpgkey={s}", .{key}) else "" }),
        .apt => try renderAptRepository(ctx, repository),
    };
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .repository = repository.name, .manager = @tagName(repository.manager), .config = rendered } }, .{});
    try renderOutputDocument(ctx, .{ .human = .{ .text = std.mem.trimEnd(u8, rendered, "\n") }, .json = json });
}

fn renderAptRepository(ctx: zli.CommandContext, repository: *const model.RepositoryConfig) ![]const u8 {
    // 一个 ISO repository 可能包含不同 suite；逐个读取 dists/*/Release，优先
    // 使用 Codename，其次 Suite，并保留介质声明的 Components 顺序。
    const dists_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}/dists", .{ nodeforge.paths.require().repos_dir, repository.name });
    var dists = std.Io.Dir.openDirAbsolute(ctx.io, dists_path, .{ .iterate = true, .follow_symlinks = false }) catch {
        try writeCommandError(ctx, "repository.metadata_missing", "APT repository has no dists directory", 1);
        return error.RepositoryMetadataMissing;
    };
    defer dists.close(ctx.io);
    var iterator = dists.iterate();
    while (try iterator.next(ctx.io)) |entry| {
        const release_path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}/Release", .{ dists_path, entry.name });
        const release = std.Io.Dir.cwd().readFileAlloc(ctx.io, release_path, ctx.allocator, .limited(256 * 1024)) catch continue;
        const suite = aptReleaseValue(release, "Codename") orelse aptReleaseValue(release, "Suite") orelse entry.name;
        const components = aptReleaseValue(release, "Components") orelse "main";
        return std.fmt.allocPrint(ctx.allocator, "deb [trusted={s}] {s} {s} {s}\n", .{ if (repository.gpg_check) "no" else "yes", repository.base_url, suite, components });
    }
    try writeCommandError(ctx, "repository.metadata_missing", "APT repository has no readable Release metadata", 1);
    return error.RepositoryMetadataMissing;
}

fn aptReleaseValue(release: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, release, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..colon], " \t\r"), key)) return std.mem.trim(u8, line[colon + 1 ..], " \t\r");
    }
    return null;
}

fn catalogResourceHandler(ctx: zli.CommandContext, resource: []const u8, name: ?[]const u8) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = nodeforge.management_client.catalogResourcesJson(ctx.io, config.value.server.http_port, resource, name, response) catch null orelse {
        const message = try std.fmt.allocPrint(ctx.allocator, "{s} query failed", .{resource});
        try writeCommandError(ctx, "catalog.query_failed", message, 1);
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        try writeCommandError(ctx, "catalog.invalid_response", "catalog query returned malformed JSON", 1);
        return;
    };
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse {
        try writeCommandError(ctx, "catalog.invalid_response", "catalog query response has no result", 1);
        return;
    };
    if (name == null) {
        const items = result.object.get("items") orelse {
            try writeCommandError(ctx, "catalog.invalid_response", "catalog collection response has no items", 1);
            return;
        };
        const cells = try ctx.allocator.alloc([5][]const u8, items.array.items.len);
        const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, items.array.items.len);
        const jsonl = try ctx.allocator.alloc([]const u8, items.array.items.len);
        for (items.array.items, 0..) |item, index| {
            const object = item.object;
            cells[index] = .{
                jsonString(object.get("name")),
                jsonString(object.get("distro")),
                jsonString(object.get("version")),
                jsonString(object.get("arch")),
                if (std.mem.eql(u8, resource, "repositories")) jsonString(object.get("manager")) else "install-source",
            };
            rows[index] = .{ .cells = &cells[index] };
            jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = item }, .{});
        }
        const columns = [_]nodeforge.cli_table.Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "distro", .title = "DISTRO" }, .{ .key = "version", .title = "VERSION" }, .{ .key = "arch", .title = "ARCH" }, .{ .key = "type", .title = "TYPE" } };
        try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = if (std.mem.eql(u8, resource, "repositories")) "No repositories." else "No install sources." } }, .json = body, .jsonl = jsonl });
        return;
    }

    const prefix = if (std.mem.eql(u8, resource, "repositories")) "repository" else "install_source";
    const target = result.object.get(prefix) orelse {
        try writeCommandError(ctx, "catalog.invalid_response", "catalog detail response has no resource", 1);
        return;
    };
    const object = target.object;
    var fields: [12]nodeforge.cli_document.Field = undefined;
    var count: usize = 0;
    const base = [_][]const u8{ "name", "distro", "version", "arch" };
    for (base) |key| {
        fields[count] = .{ .key = key, .value = jsonString(object.get(key)), .section = "stored", .json_path = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ prefix, key }) };
        count += 1;
    }
    if (std.mem.eql(u8, resource, "repositories")) {
        const keys = [_][]const u8{ "manager", "base_url", "gpg_check", "gpg_key" };
        for (keys) |key| {
            fields[count] = .{ .key = key, .value = try jsonDisplay(ctx.allocator, object.get(key)), .section = "stored", .json_path = try std.fmt.allocPrint(ctx.allocator, "repository.{s}", .{key}) };
            count += 1;
        }
    } else {
        const keys = [_][]const u8{ "source_asset", "installer_kernel", "installer_initrd", "media_tree_url", "repositories" };
        for (keys) |key| {
            fields[count] = .{ .key = key, .value = try jsonDisplay(ctx.allocator, object.get(key)), .section = "stored", .json_path = try std.fmt.allocPrint(ctx.allocator, "install_source.{s}", .{key}) };
            count += 1;
        }
    }
    const sections = [_]nodeforge.cli_document.Section{.{ .key = "stored", .title = "Stored" }};
    const title = try std.fmt.allocPrint(ctx.allocator, "{s} {s}", .{ if (std.mem.eql(u8, resource, "repositories")) "Repository" else "Install source", name.? });
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = fields[0..count] } }, .json = body });
}

fn installSourceSoftwareListHandler(ctx: zli.CommandContext) !void {
    try softwareAvailableHandler(ctx, "install-sources", false);
}
fn repositorySoftwareListHandler(ctx: zli.CommandContext) !void {
    try softwareAvailableHandler(ctx, "repositories", false);
}
fn profileSoftwareAvailableHandler(ctx: zli.CommandContext) !void {
    try softwareAvailableHandler(ctx, "profiles", false);
}
fn repositorySoftwareShowHandler(ctx: zli.CommandContext) !void {
    try softwareAvailableHandler(ctx, "repositories", true);
}

fn softwareAvailableHandler(ctx: zli.CommandContext, resource: []const u8, exact: bool) !void {
    _ = outputFromContext(ctx) orelse return;
    const name = ctx.positional_args[0];
    const id = if (exact) ctx.positional_args[1] else null;
    const kind_value = ctx.flag("kind", []const u8);
    if (exact and kind_value.len == 0) {
        try writeCommandError(ctx, "software.kind_required", "--kind is required", 2);
        return;
    }
    const search_value = if (exact) id.? else ctx.flag("search", []const u8);
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    // 软件 capability 响应可能很大：Rocky 10.2 DVD 的 package 索引约 1.8 MB，
    // Ubuntu live-server 的 task/metapackage 索引较小但仍可能增长。
    // 原实现使用 256 KB 栈缓冲区（`var response: [256 * 1024]u8`），
    // 对 Rocky DVD 返回 `error.ResponseTooLarge`（client.zig:779），但
    // `catch null orelse` 把该错误与连接失败、404/409 等服务端拒绝
    // 混为同一个 `software.query_failed`，无法定位根因。
    //
    // 修复：改用堆分配（8 MB 上限），并把 `catch null orelse` 拆分为
    // `catch |err|`（连接/协议错误，区分 ResponseTooLarge）和 `orelse`
    //（服务端返回非 2xx，如 404 source not found、409 no index、
    // 422 kind not applicable），使 CLI 输出可定位故障类别。
    const response_capacity: usize = 8 * 1024 * 1024;
    const response_buf = ctx.allocator.alloc(u8, response_capacity) catch {
        try writeCommandError(ctx, "software.query_failed", "cannot allocate response buffer", 1);
        return;
    };
    defer ctx.allocator.free(response_buf);
    const body = nodeforge.management_client.softwareCapabilitiesJson(ctx.io, config.value.server.http_port, resource, name, if (kind_value.len == 0) null else kind_value, if (search_value.len == 0) null else search_value, response_buf) catch |err| {
        // 连接失败（daemon 未运行）、协议错误（截断、不支持传输编码）
        // 或响应体超过 8 MB 上限。ResponseTooLarge 给出可操作的提示，
        // 其余错误保持通用消息——debug 模式可进一步定位。
        if (err == error.ResponseTooLarge) {
            try writeCommandError(ctx, "software.response_too_large", "software capability response exceeds 8 MB buffer; use --kind or --search to narrow the query", 1);
        } else {
            try writeCommandError(ctx, "software.query_failed", "software capability query failed", 1);
        }
        return;
    } orelse {
        // managementJson 对非 2xx 返回 null（client.zig:610）。
        // 常见原因：404（install source 或其 repository 不在 catalog 中）、
        // 409（source 无 repository 或 software index 未建立）、
        // 422（--kind 不适用于该 repository 的包管理器）。
        try writeCommandError(ctx, "software.query_failed", "software capability query was rejected", 1);
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        try writeCommandError(ctx, "software.invalid_response", "software capability response is malformed", 1);
        return;
    };
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse {
        try writeCommandError(ctx, "software.query_failed", "software capability query was rejected", 1);
        return;
    };
    const items = result.object.get("items") orelse {
        try writeCommandError(ctx, "software.invalid_response", "software capability response has no items", 1);
        return;
    };
    const digests = result.object.get("index_digests");
    const index_digest: std.json.Value = if (digests) |values| if (values.array.items.len != 0) values.array.items[0] else .null else .null;
    if (exact) {
        for (items.array.items) |item| {
            const capability = item.object.get("capability") orelse continue;
            if (!std.mem.eql(u8, jsonString(capability.object.get("id")), id.?)) continue;
            const ExactResult = struct { repository: std.json.Value, capability: std.json.Value, index_digest: std.json.Value };
            const exact_result = ExactResult{ .repository = item.object.get("repository") orelse .null, .capability = capability, .index_digest = index_digest };
            const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = exact_result }, .{});
            const fields = [_]nodeforge.cli_document.Field{
                .{ .key = "id", .value = jsonString(capability.object.get("id")), .section = "stored", .json_path = "capability.id" },
                .{ .key = "kind", .value = jsonString(capability.object.get("kind")), .section = "stored", .json_path = "capability.kind" },
                .{ .key = "name", .value = jsonString(capability.object.get("name")), .section = "stored", .json_path = "capability.name" },
                .{ .key = "description", .value = try jsonDisplay(ctx.allocator, capability.object.get("description")), .section = "stored", .json_path = "capability.description" },
                .{ .key = "repository", .value = jsonString(item.object.get("repository")), .section = "stored" },
                .{ .key = "revision", .value = try jsonDisplay(ctx.allocator, index_digest), .section = "index", .json_path = "index_digest" },
            };
            const sections = [_]nodeforge.cli_document.Section{ .{ .key = "stored", .title = "Stored" }, .{ .key = "index", .title = "Index" } };
            const title = try std.fmt.allocPrint(ctx.allocator, "Software {s}", .{id.?});
            try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = &fields } }, .json = json });
            return;
        }
        const message = try std.fmt.allocPrint(ctx.allocator, "software capability not found: {s}", .{id.?});
        try writeCommandError(ctx, "software.not_found", message, 1);
        return;
    }

    const cells = try ctx.allocator.alloc([6][]const u8, items.array.items.len);
    const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, items.array.items.len);
    const jsonl = try ctx.allocator.alloc([]const u8, items.array.items.len);
    for (items.array.items, 0..) |item, index| {
        const capability = item.object.get("capability") orelse return error.InvalidSoftwareResponse;
        cells[index] = .{
            jsonString(capability.object.get("id")),
            jsonString(capability.object.get("kind")),
            jsonString(capability.object.get("name")),
            "-",
            jsonString(item.object.get("repository")),
            try jsonDisplay(ctx.allocator, index_digest),
        };
        rows[index] = .{ .cells = &cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = item }, .{});
    }
    const columns = [_]nodeforge.cli_table.Column{ .{ .key = "id", .title = "ID" }, .{ .key = "kind", .title = "KIND" }, .{ .key = "name", .title = "NAME" }, .{ .key = "arch", .title = "ARCH" }, .{ .key = "repository", .title = "REPOSITORY" }, .{ .key = "revision", .title = "REVISION", .max_width = 16 } };
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No matching software capabilities." } }, .json = body, .jsonl = jsonl });
}

fn profileSoftwareShowHandler(ctx: zli.CommandContext) !void {
    try softwareSelectionShowHandler(ctx, true);
}
fn nodeSoftwareShowHandler(ctx: zli.CommandContext) !void {
    try softwareSelectionShowHandler(ctx, false);
}

fn profileCapabilitiesShowHandler(ctx: zli.CommandContext) !void {
    try capabilitiesShowHandler(ctx, true);
}
fn nodeCapabilitiesShowHandler(ctx: zli.CommandContext) !void {
    try capabilitiesShowHandler(ctx, false);
}

fn capabilitiesShowHandler(ctx: zli.CommandContext, profile_resource: bool) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const owner = if (profile_resource) "profile" else "node";
    const body = nodeforge.management_client.capabilitiesJson(ctx.io, config.value.server.http_port, owner, ctx.positional_args[0], response) catch null orelse {
        try writeCommandError(ctx, "capability.query_failed", "capability query failed", 1);
        return;
    };
    const Response = struct { result: struct { adapter: []const u8, domains: []const struct { domain: []const u8, status: []const u8 } } };
    const parsed = std.json.parseFromSlice(Response, ctx.allocator, body, .{ .ignore_unknown_fields = true }) catch {
        try writeCommandError(ctx, "capability.invalid_response", "capability response invalid", 1);
        return;
    };
    defer parsed.deinit();
    var cells: [nodeforge.adapter_capabilities.entries.len][2][]const u8 = undefined;
    var rows: [nodeforge.adapter_capabilities.entries.len]nodeforge.cli_table.Row = undefined;
    if (parsed.value.result.domains.len > rows.len) return error.TooManyCapabilities;
    for (parsed.value.result.domains, 0..) |entry, index| {
        cells[index] = .{ entry.domain, entry.status };
        rows[index] = .{ .cells = &cells[index] };
    }
    const columns = [_]nodeforge.cli_table.Column{ .{ .key = "domain", .title = "DOMAIN" }, .{ .key = "status", .title = "STATUS" } };
    const document: nodeforge.cli_document.OutputDocument = .{ .human = .{ .table = .{ .columns = &columns, .rows = rows[0..parsed.value.result.domains.len], .empty_message = "No adapter capabilities." } }, .json = body, .jsonl = null };
    try renderOutputDocument(ctx, document);
}

fn softwareSelectionShowHandler(ctx: zli.CommandContext, profile: bool) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = if (profile)
        nodeforge.management_client.profilesJson(ctx.io, config.value.server.http_port, ctx.positional_args[0], response) catch null
    else
        nodeforge.management_client.nodesJson(ctx.io, config.value.server.http_port, ctx.positional_args[0], response) catch null;
    const value = body orelse {
        try writeCommandError(ctx, "software.selection_query_failed", "software selection query failed", 1);
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, value, .{}) catch {
        try writeCommandError(ctx, "software.invalid_response", "software selection response is malformed", 1);
        return;
    };
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse {
        try writeCommandError(ctx, "software.invalid_response", "software selection response has no result", 1);
        return;
    };
    var fields: [24]nodeforge.cli_document.Field = undefined;
    var count: usize = 0;
    if (profile) {
        const software = result.object.get("software") orelse {
            try writeCommandError(ctx, "software.invalid_response", "profile response has no software selection", 1);
            return;
        };
        const keys = [_][]const u8{ "repositories", "environment", "groups", "tasks" };
        for (keys) |key| {
            fields[count] = .{ .key = try std.fmt.allocPrint(ctx.allocator, "software.{s}", .{key}), .value = try jsonDisplay(ctx.allocator, software.object.get(key)), .section = "stored", .json_path = try std.fmt.allocPrint(ctx.allocator, "software.{s}", .{key}) };
            count += 1;
        }
        const packages = software.object.get("packages") orelse .null;
        for ([_][]const u8{ "include", "exclude" }) |key| {
            fields[count] = .{ .key = try std.fmt.allocPrint(ctx.allocator, "software.packages.{s}", .{key}), .value = try jsonDisplay(ctx.allocator, packages.object.get(key)), .section = "stored", .json_path = try std.fmt.allocPrint(ctx.allocator, "software.packages.{s}", .{key}) };
            count += 1;
        }
    } else {
        // management DTO 使用 canonical 嵌套结构：
        // software.packages.include/exclude，而不是旧内部字段
        // packages_include/packages_exclude。所有中间对象都允许为 null；
        // show 命令必须显示空值，不能因未选择软件而访问错误的 union 字段。
        const node = result.object.get("node") orelse .null;
        const overrides = if (node == .object) node.object.get("overrides") orelse .null else .null;
        const software = if (overrides == .object) overrides.object.get("software") orelse .null else .null;
        const scalar = [_][]const u8{"environment"};
        for (scalar) |key| {
            const field_value = if (software == .object) software.object.get(key) else null;
            fields[count] = .{ .key = try std.fmt.allocPrint(ctx.allocator, "overrides.software.{s}", .{key}), .value = try jsonDisplay(ctx.allocator, field_value), .section = "overrides", .json_path = try std.fmt.allocPrint(ctx.allocator, "node.overrides.software.{s}", .{key}) };
            count += 1;
        }
        for ([_][]const u8{ "repositories", "groups", "tasks" }) |key| {
            const delta = if (software == .object) software.object.get(key) orelse .null else .null;
            for ([_][]const u8{ "add", "remove" }) |operation| {
                const field_value = if (delta == .object) delta.object.get(operation) else null;
                fields[count] = .{ .key = try std.fmt.allocPrint(ctx.allocator, "overrides.software.{s}.{s}", .{ key, operation }), .value = try jsonDisplay(ctx.allocator, field_value), .section = "overrides", .json_path = try std.fmt.allocPrint(ctx.allocator, "node.overrides.software.{s}.{s}", .{ key, operation }) };
                count += 1;
            }
        }
        const package_deltas = if (software == .object) software.object.get("packages") orelse .null else .null;
        for ([_][]const u8{ "include", "exclude" }) |kind| {
            const delta = if (package_deltas == .object) package_deltas.object.get(kind) orelse .null else .null;
            for ([_][]const u8{ "add", "remove" }) |operation| {
                const field_value = if (delta == .object) delta.object.get(operation) else null;
                fields[count] = .{ .key = try std.fmt.allocPrint(ctx.allocator, "overrides.software.packages.{s}.{s}", .{ kind, operation }), .value = try jsonDisplay(ctx.allocator, field_value), .section = "overrides", .json_path = try std.fmt.allocPrint(ctx.allocator, "node.overrides.software.packages.{s}.{s}", .{ kind, operation }) };
                count += 1;
            }
        }
        const effective = result.object.get("effective_software") orelse .null;
        for ([_][]const u8{ "repositories", "environment", "groups", "tasks" }) |key| {
            const field_value = if (effective == .object) effective.object.get(key) else null;
            fields[count] = .{ .key = try std.fmt.allocPrint(ctx.allocator, "effective.software.{s}", .{key}), .value = try jsonDisplay(ctx.allocator, field_value), .section = "effective", .json_path = try std.fmt.allocPrint(ctx.allocator, "effective_software.{s}", .{key}) };
            count += 1;
        }
        const packages = if (effective == .object) effective.object.get("packages") orelse .null else .null;
        for ([_][]const u8{ "include", "exclude" }) |key| {
            const field_value = if (packages == .object) packages.object.get(key) else null;
            fields[count] = .{ .key = try std.fmt.allocPrint(ctx.allocator, "effective.software.packages.{s}", .{key}), .value = try jsonDisplay(ctx.allocator, field_value), .section = "effective", .json_path = try std.fmt.allocPrint(ctx.allocator, "effective_software.packages.{s}", .{key}) };
            count += 1;
        }
    }
    const sections = if (profile) &[_]nodeforge.cli_document.Section{.{ .key = "stored", .title = "Stored" }} else &[_]nodeforge.cli_document.Section{ .{ .key = "overrides", .title = "Overrides" }, .{ .key = "effective", .title = "Effective" } };
    const title = try std.fmt.allocPrint(ctx.allocator, "{s} software {s}", .{ if (profile) "Profile" else "Node", ctx.positional_args[0] });
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = sections, .fields = fields[0..count] } }, .json = value });
}

fn managedFileListHandler(ctx: zli.CommandContext) !void {
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer loaded.deinit();
    var count: usize = 0;
    for (loaded.value().assets) |asset| if (asset.kind == .managed_file) {
        count += 1;
    };
    const ManagedFileListItem = struct { name: []const u8, revision: u64, size: u64, media_type: ?[]const u8, sha256: ?[]const u8 };
    const items = try ctx.allocator.alloc(ManagedFileListItem, count);
    const cells = try ctx.allocator.alloc([4][]const u8, count);
    const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, count);
    const jsonl = try ctx.allocator.alloc([]const u8, count);
    var index: usize = 0;
    for (loaded.value().assets) |asset| if (asset.kind == .managed_file) {
        items[index] = .{ .name = asset.name, .revision = asset.revision, .size = asset.size orelse 0, .media_type = asset.media_type, .sha256 = asset.sha256 };
        const revision = try std.fmt.allocPrint(ctx.allocator, "{d}", .{asset.revision});
        const size = try std.fmt.allocPrint(ctx.allocator, "{d}", .{asset.size orelse 0});
        cells[index] = .{ asset.name, revision, size, asset.sha256 orelse "-" };
        rows[index] = .{ .cells = &cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = items[index] }, .{});
        index += 1;
    };
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .items = items } }, .{});
    const columns = [_]nodeforge.cli_table.Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "revision", .title = "REVISION", .alignment = .right }, .{ .key = "size", .title = "SIZE", .alignment = .right }, .{ .key = "sha256", .title = "SHA256", .max_width = 16 } };
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No managed-file assets." } }, .json = json, .jsonl = jsonl });
}

fn managedFileShowHandler(ctx: zli.CommandContext) !void {
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer loaded.deinit();
    const name = ctx.getArg("name") orelse return;
    for (loaded.value().assets) |asset| if (asset.kind == .managed_file and std.mem.eql(u8, asset.name, name)) {
        const revision = try std.fmt.allocPrint(ctx.allocator, "{d}", .{asset.revision});
        const size = try std.fmt.allocPrint(ctx.allocator, "{d}", .{asset.size orelse 0});
        const sections = [_]nodeforge.cli_document.Section{.{ .key = "stored", .title = "Stored" }};
        const fields = [_]nodeforge.cli_document.Field{ .{ .key = "name", .value = asset.name, .section = "stored" }, .{ .key = "revision", .value = revision, .section = "stored" }, .{ .key = "size", .value = size, .section = "stored" }, .{ .key = "media_type", .value = asset.media_type orelse "-", .section = "stored" }, .{ .key = "sha256", .value = asset.sha256 orelse "-", .section = "stored" } };
        const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = asset }, .{});
        try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = "Managed file", .sections = &sections, .fields = &fields } }, .json = json });
        return;
    };
    const message = try std.fmt.allocPrint(ctx.allocator, "managed-file asset not found: {s}", .{name});
    try writeCommandError(ctx, "managed-file.not_found", message, 1);
}

fn managedFileImportHandler(ctx: zli.CommandContext) !void {
    return contentAssetImportHandler(ctx, .managed_file, 16 * 1024 * 1024);
}

fn archiveImportHandler(ctx: zli.CommandContext) !void {
    return contentAssetImportHandler(ctx, .archive, 256 * 1024 * 1024);
}

/// 构建 NodeForge canonical archive。
///
/// payload 始终由一次 GNU tar 调用从同一个基准目录读取，因此符号链接不会被
/// 解引用，跨输入项的硬链接关系也不会因逐文件打包而丢失。GNU tar 的
/// `--atime-preserve=system` 使读取操作不更新源文件 atime；PAX、ACL 与 xattr
/// 选项保存权限、数字 uid/gid、mtime、ACL 和扩展属性。ctime 是内核维护的 inode
/// 变更时间，任何新建解压文件都会获得新的 ctime，CLI 不伪造也不承诺保持它。
fn archiveBuildHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const output_path = ctx.getArg("archive") orelse return;
    const install_script = ctx.flag("install-script", []const u8);
    const base_dir = ctx.flag("base-dir", []const u8);
    const files_from = ctx.flag("files-from", []const u8);
    const compression_name = ctx.flag("compression", []const u8);
    const compression = parseArchiveCompression(compression_name) orelse return itemUsageError(ctx, "archive build --compression must be none, gzip, or xz");
    if (output_path.len == 0 or base_dir.len == 0)
        return itemUsageError(ctx, "archive build requires <output> and a non-empty --base-dir");
    if (!compression.validOutputSuffix(output_path))
        return itemUsageError(ctx, "archive output suffix does not match --compression (.tar, .tar.gz/.tgz, or .tar.xz/.txz)");
    if (std.Io.Dir.cwd().statFile(ctx.io, output_path, .{ .follow_symlinks = false })) |_| {
        return itemUsageError(ctx, "archive build refuses to overwrite an existing output");
    } else |err| if (err != error.FileNotFound) return itemUsageError(ctx, "archive build output cannot be inspected");

    const base_stat = std.Io.Dir.cwd().statFile(ctx.io, base_dir, .{ .follow_symlinks = true }) catch return itemUsageError(ctx, "archive build --base-dir is unreadable");
    if (base_stat.kind != .directory) return itemUsageError(ctx, "archive build --base-dir must be a directory");
    // `.nf.install.sh` 是显式 opt-in 的 Mode A 入口，不是 archive 的必备组成。
    // 未提供脚本时不得生成占位入口，否则纯数据包会被 runner 错判并执行。
    if (install_script.len != 0) {
        const script_stat = std.Io.Dir.cwd().statFile(ctx.io, install_script, .{ .follow_symlinks = false }) catch return itemUsageError(ctx, "archive build install script is unreadable");
        if (script_stat.kind != .file) return itemUsageError(ctx, "archive build install script must be a regular file, not a symlink");
    }

    var list: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer list.deinit();
    var path_count: usize = 0;
    for (ctx.positional_args[1..]) |path| {
        if (!validArchiveBuildPath(path)) return itemUsageError(ctx, "archive payload paths must be non-empty relative paths without '..' or newlines");
        try list.writer.writeAll(path);
        try list.writer.writeByte(0);
        path_count += 1;
    }
    if (files_from.len != 0) {
        const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, files_from, ctx.allocator, .limited(4 * 1024 * 1024)) catch return itemUsageError(ctx, "archive build --files-from is unreadable or too large");
        defer ctx.allocator.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw| {
            const path = std.mem.trim(u8, raw, " \t\r");
            if (path.len == 0) continue;
            if (!validArchiveBuildPath(path)) return itemUsageError(ctx, "archive --files-from contains an absolute, parent, or malformed path");
            try list.writer.writeAll(path);
            try list.writer.writeByte(0);
            path_count += 1;
        }
    }
    if (path_count == 0) return itemUsageError(ctx, "archive build requires at least one payload path or --files-from entry");

    const version = std.process.run(ctx.allocator, ctx.io, .{ .argv = &.{ "tar", "--version" }, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024) }) catch return itemUsageError(ctx, "archive build requires GNU tar");
    defer ctx.allocator.free(version.stdout);
    defer ctx.allocator.free(version.stderr);
    const gnu_tar_ok = switch (version.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!gnu_tar_ok or std.mem.indexOf(u8, version.stdout, "GNU tar") == null)
        return itemUsageError(ctx, "archive build requires GNU tar; BSD tar is not supported");

    var random: [12]u8 = undefined;
    try ctx.io.randomSecure(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    const output_dir = std.fs.path.dirname(output_path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(ctx.io, output_dir);
    var output_dir_handle = try std.Io.Dir.cwd().openDir(ctx.io, output_dir, .{});
    defer output_dir_handle.close(ctx.io);
    var real_output_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_output_dir_len = try output_dir_handle.realPath(ctx.io, &real_output_dir_buf);
    const real_output_dir = real_output_dir_buf[0..real_output_dir_len];
    const temp_archive = try std.fmt.allocPrint(ctx.allocator, "{s}/.nodeforge-archive-{s}.tar", .{ real_output_dir, hex[0..] });
    defer ctx.allocator.free(temp_archive);
    const temp_list = try std.fmt.allocPrint(ctx.allocator, "{s}/.nodeforge-archive-{s}.list", .{ real_output_dir, hex[0..] });
    defer ctx.allocator.free(temp_list);
    defer std.Io.Dir.cwd().deleteFile(ctx.io, temp_archive) catch {};
    defer std.Io.Dir.cwd().deleteFile(ctx.io, temp_list) catch {};
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = temp_list, .data = list.written() });

    try runArchiveBuildTar(ctx, &.{ "tar", "--format=pax", "--acls", "--xattrs", "--numeric-owner", "--atime-preserve=system", "--null", "--files-from", temp_list, "-cf", temp_archive }, .{ .path = base_dir });
    validateArchiveForImport(ctx, temp_archive) catch return itemUsageError(ctx, "archive build produced an invalid payload archive");
    if (try archiveHasReservedInstallEntry(ctx, temp_archive))
        return itemUsageError(ctx, "archive payload already contains the reserved top-level .nf.install.sh entry");

    if (install_script.len != 0) {
        const script_dir = std.fs.path.dirname(install_script) orelse ".";
        const script_name = std.fs.path.basename(install_script);
        try runArchiveBuildTar(ctx, &.{ "tar", "--format=pax", "--acls", "--xattrs", "--numeric-owner", "--atime-preserve=system", "--transform=s|.*|.nf.install.sh|", "-rf", temp_archive, script_name }, .{ .path = script_dir });
    }
    validateArchiveForImport(ctx, temp_archive) catch return itemUsageError(ctx, "archive build produced an invalid final archive");
    // GNU tar 不能向已经压缩的流安全追加条目。必须先完成 payload、可选入口和
    // 路径校验，再把最终临时 tar 压缩一次；三种输出因此共享完全相同的内部 PAX
    // 布局、hardlink/symlink 与元数据语义。
    const publish_source = switch (compression) {
        .none => temp_archive,
        .gzip => blk: {
            try runArchiveCompressor(ctx, &.{ "gzip", "-n", "--", temp_archive });
            break :blk try std.fmt.allocPrint(ctx.allocator, "{s}.gz", .{temp_archive});
        },
        .xz => blk: {
            try runArchiveCompressor(ctx, &.{ "xz", "--check=crc64", "--", temp_archive });
            break :blk try std.fmt.allocPrint(ctx.allocator, "{s}.xz", .{temp_archive});
        },
    };
    defer if (compression != .none) ctx.allocator.free(publish_source);
    defer if (compression != .none) std.Io.Dir.cwd().deleteFile(ctx.io, publish_source) catch {};
    validateArchiveForImport(ctx, publish_source) catch return itemUsageError(ctx, "archive build produced an unreadable compressed archive");
    try std.Io.Dir.rename(std.Io.Dir.cwd(), publish_source, std.Io.Dir.cwd(), output_path, ctx.io);

    const mode: []const u8 = if (install_script.len == 0) "B" else "A";
    const entrypoint: ?[]const u8 = if (install_script.len == 0) null else ".nf.install.sh";
    const human = try std.fmt.allocPrint(ctx.allocator, "built canonical archive {s} ({d} payload paths; Mode {s})", .{ output_path, path_count, mode });
    try renderCommandResult(ctx, human, .{ .archive = output_path, .mode = mode, .entrypoint = entrypoint, .payload_paths = path_count, .format = "pax", .compression = compression_name, .ctime_preserved = false });
}

/// canonical archive 的传输压缩层。`none` 是默认值；compression 只改变外层编码，
/// 不改变 Mode A/B 判定和归档内 PAX 数据模型。后缀必须与显式选择一致，避免调用方
/// 仅凭文件名产生错误的 media type 或缓存策略。
const ArchiveCompression = enum {
    none,
    gzip,
    xz,

    fn validOutputSuffix(self: ArchiveCompression, path: []const u8) bool {
        return switch (self) {
            .none => std.mem.endsWith(u8, path, ".tar"),
            .gzip => std.mem.endsWith(u8, path, ".tar.gz") or std.mem.endsWith(u8, path, ".tgz"),
            .xz => std.mem.endsWith(u8, path, ".tar.xz") or std.mem.endsWith(u8, path, ".txz"),
        };
    }
};

fn parseArchiveCompression(value: []const u8) ?ArchiveCompression {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "gzip")) return .gzip;
    if (std.mem.eql(u8, value, "xz")) return .xz;
    return null;
}

fn validArchiveBuildPath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\n') != null or std.mem.indexOfScalar(u8, path, '\r') != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return false;
    return true;
}

fn runArchiveBuildTar(ctx: zli.CommandContext, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    const result = std.process.run(ctx.allocator, ctx.io, .{ .argv = argv, .cwd = cwd, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(256 * 1024) }) catch return itemUsageError(ctx, "GNU tar could not be executed");
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    if (ctx.flag("debug", bool) and result.stderr.len != 0) try errorWriter(ctx).print("debug: archive build: {s}\n", .{result.stderr});
    return itemUsageError(ctx, "GNU tar failed while building the archive");
}

fn runArchiveCompressor(ctx: zli.CommandContext, argv: []const []const u8) !void {
    const result = std.process.run(ctx.allocator, ctx.io, .{ .argv = argv, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(256 * 1024) }) catch return itemUsageError(ctx, "selected archive compressor could not be executed");
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    if (ctx.flag("debug", bool) and result.stderr.len != 0) try errorWriter(ctx).print("debug: archive compressor: {s}\n", .{result.stderr});
    return itemUsageError(ctx, "selected archive compressor failed");
}

fn archiveHasReservedInstallEntry(ctx: zli.CommandContext, source: []const u8) !bool {
    const result = try std.process.run(ctx.allocator, ctx.io, .{ .argv = &.{ "tar", "-tf", source }, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(64 * 1024) });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.InvalidArchive,
        else => return error.InvalidArchive,
    }
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw| {
        var entry = std.mem.trim(u8, raw, "\r");
        while (std.mem.startsWith(u8, entry, "./")) entry = entry[2..];
        if (std.mem.eql(u8, entry, ".nf.install.sh")) return true;
    }
    return false;
}

fn scriptImportHandler(ctx: zli.CommandContext) !void {
    return contentAssetImportHandler(ctx, .script, 16 * 1024 * 1024);
}

fn contentAssetImportHandler(ctx: zli.CommandContext, kind: nodeforge.model.AssetKind, max_size: u64) !void {
    _ = outputFromContext(ctx) orelse return;
    const name = ctx.getArg("name") orelse return;
    const source = ctx.flag("from-file", []const u8);
    const media_type = ctx.flag("media-type", []const u8);
    if (!nodeforge.config_validate.validLogicalId(name) or source.len == 0 or media_type.len == 0 or std.mem.indexOfScalar(u8, media_type, '/') == null) return itemUsageError(ctx, "managed-file import requires a valid name, --from-file, and media type");
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var catalog = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer catalog.deinit();
    var revision: u64 = 1;
    for (catalog.value().assets) |asset| if (std.mem.eql(u8, asset.name, name)) {
        if (asset.kind != kind) return itemUsageError(ctx, "name belongs to a different asset kind");
        revision = asset.revision + 1;
    };
    var input = std.Io.Dir.cwd().openFile(ctx.io, source, .{ .follow_symlinks = false }) catch return itemUsageError(ctx, "managed-file source is unreadable");
    defer input.close(ctx.io);
    const stat = input.stat(ctx.io) catch return itemUsageError(ctx, "managed-file source cannot be inspected");
    if (stat.kind != .file or stat.size > max_size) return itemUsageError(ctx, "content asset source is not a regular file or exceeds its size limit");
    if (kind == .archive) validateArchiveForImport(ctx, source) catch {
        try writeCommandError(ctx, "archive.invalid", "archive must be a readable tar without absolute paths or '..' path components", 2);
        return;
    };
    const directory: []const u8 = switch (kind) {
        .managed_file => "managed-files",
        .archive => "archives",
        .script => "scripts",
        else => unreachable,
    };
    const relative = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}/{d}", .{ directory, name, revision });
    defer ctx.allocator.free(relative);
    // `--config` 可能指向备用安装根（测试、恢复、并行管理）。
    // 使用已加载配置的规范 HTTP 资产根，而非
    // CLI 进程全局默认路径，否则字节会被复制到 /opt 下，
    // 而选中的 daemon 校验的是另一个根。
    const assets_root = std.fs.path.dirname(config.value.http.asset_root) orelse return itemUsageError(ctx, "configured HTTP asset root has no assets parent");
    const destination = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ assets_root, relative });
    defer ctx.allocator.free(destination);
    try std.Io.Dir.cwd().createDirPath(ctx.io, std.fs.path.dirname(destination) orelse return error.InvalidPath);
    std.Io.Dir.copyFile(std.Io.Dir.cwd(), source, std.Io.Dir.cwd(), destination, ctx.io, .{ .permissions = .default_file, .replace = false }) catch return itemUsageError(ctx, "managed-file immutable revision already exists");
    var published = false;
    defer if (!published) std.Io.Dir.cwd().deleteFile(ctx.io, destination) catch {};
    const ok = nodeforge.management_client.importAsset(ctx.io, config.value.server.http_port, .{ .name = name, .kind = @tagName(kind), .path = relative, .revision = revision, .size = stat.size, .media_type = media_type }) catch false;
    if (!ok) {
        try writeCommandError(ctx, "managed-file.publish_failed", "managed-file publication failed", 1);
        return;
    }
    published = true;
    const human = try std.fmt.allocPrint(ctx.allocator, "imported {s} revision {d} ({d} bytes)", .{ name, revision, stat.size });
    try renderCommandResult(ctx, human, .{ .name = name, .revision = revision, .size = stat.size, .media_type = media_type });
}

fn validateArchiveForImport(ctx: zli.CommandContext, source: []const u8) !void {
    const result = try std.process.run(ctx.allocator, ctx.io, .{
        .argv = &.{ "tar", "-tf", source },
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer ctx.allocator.free(result.stdout);
    defer ctx.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.InvalidArchive,
        else => return error.InvalidArchive,
    }
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_entry| {
        const entry = std.mem.trim(u8, raw_entry, "\r");
        if (entry.len == 0) continue;
        if (entry[0] == '/') return error.InvalidArchivePath;
        var components = std.mem.splitScalar(u8, entry, '/');
        while (components.next()) |component| if (std.mem.eql(u8, component, "..")) return error.InvalidArchivePath;
    }
}

fn managedFileRemoveHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const name = ctx.getArg("name") orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [512]u8 = undefined;
    const result = nodeforge.management_client.managedFileRemove(ctx.io, config.value.server.http_port, name, &reason);
    if (!result.healthy) return reportMutationFailure(ctx, result, "managed-file remove failed");
    const human = try std.fmt.allocPrint(ctx.allocator, "removed managed-file {s}; immutable revision bytes retained", .{name});
    try renderCommandResult(ctx, human, .{ .name = name, .removed = true, .immutable_bytes_retained = true });
}

fn provisionBundleHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const command = ctx.command.cmd_options.name;
    const name = ctx.getArg("bundle");
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "show")) {
        const response = try allocManagementResponse(ctx);
        defer ctx.allocator.free(response);
        const body = nodeforge.management_client.provisionBundleJson(ctx.io, config.value.server.http_port, name, false, null, response) catch null orelse {
            try writeCommandError(ctx, "provision-bundle.query_failed", "provision bundle query failed", 1);
            return;
        };
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch return writeCommandError(ctx, "provision-bundle.invalid_response", "provision bundle response is malformed", 1);
        defer parsed.deinit();
        const result_value = parsed.value.object.get("result") orelse return writeCommandError(ctx, "provision-bundle.invalid_response", "provision bundle response has no result", 1);
        if (std.mem.eql(u8, command, "list")) {
            const items = result_value.object.get("items") orelse return writeCommandError(ctx, "provision-bundle.invalid_response", "provision bundle response has no items", 1);
            const cells = try ctx.allocator.alloc([3][]const u8, items.array.items.len);
            const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, items.array.items.len);
            const jsonl = try ctx.allocator.alloc([]const u8, items.array.items.len);
            for (items.array.items, 0..) |item, index| {
                cells[index] = .{ jsonString(item.object.get("name")), try jsonDisplay(ctx.allocator, item.object.get("revision")), try jsonDisplay(ctx.allocator, item.object.get("steps")) };
                rows[index] = .{ .cells = &cells[index] };
                jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = item }, .{});
            }
            const columns = [_]nodeforge.cli_table.Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "revision", .title = "REVISION", .alignment = .right }, .{ .key = "steps", .title = "STEPS", .alignment = .right } };
            try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No provision bundles." } }, .json = body, .jsonl = jsonl });
            return;
        }
        var fields: [16]nodeforge.cli_document.Field = undefined;
        var count: usize = 0;
        var iterator = result_value.object.iterator();
        while (iterator.next()) |entry| {
            fields[count] = .{ .key = entry.key_ptr.*, .value = try jsonDisplay(ctx.allocator, entry.value_ptr.*), .section = "stored" };
            count += 1;
        }
        const sections = [_]nodeforge.cli_document.Section{.{ .key = "stored", .title = "Stored" }};
        const title = try std.fmt.allocPrint(ctx.allocator, "Provision bundle {s}", .{name.?});
        try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = fields[0..count] } }, .json = body });
        return;
    }
    if (name == null or !nodeforge.config_validate.validLogicalId(name.?)) return itemUsageError(ctx, "invalid provision bundle name");
    var body_buffer: [256]u8 = undefined;
    const body = if (std.mem.eql(u8, command, "create")) try std.fmt.bufPrint(&body_buffer, "{{\"name\":{f}}}", .{std.json.fmt(name.?, .{})}) else "";
    var reason: [512]u8 = undefined;
    const result = nodeforge.management_client.provisionBundleMutation(ctx.io, config.value.server.http_port, if (std.mem.eql(u8, command, "create")) "POST" else "DELETE", if (std.mem.eql(u8, command, "create")) null else name, false, body, &reason);
    if (!result.healthy) return reportMutationFailure(ctx, result, "provision bundle mutation failed");
    const human = try std.fmt.allocPrint(ctx.allocator, "{s} provision bundle {s}", .{ command, name.? });
    try renderCommandResult(ctx, human, .{ .name = name.?, .operation = command });
}

fn provisionBundleItemHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const command = ctx.command.cmd_options.name;
    const bundle = ctx.positional_args[0];
    const key = ctx.positional_args[1];
    if (!std.mem.eql(u8, key, "steps")) return itemUsageError(ctx, "provision bundle item key must be steps");
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    if (std.mem.eql(u8, command, "list") or std.mem.eql(u8, command, "show")) {
        const response = try allocManagementResponse(ctx);
        defer ctx.allocator.free(response);
        const identity = if (std.mem.eql(u8, command, "show")) ctx.positional_args[2] else null;
        const body = nodeforge.management_client.provisionBundleJson(ctx.io, config.value.server.http_port, bundle, true, identity, response) catch null orelse {
            try writeCommandError(ctx, "provision-bundle.item_query_failed", "provision bundle item query failed", 1);
            return;
        };
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch return writeCommandError(ctx, "provision-bundle.invalid_response", "provision bundle item response is malformed", 1);
        defer parsed.deinit();
        const result_value = parsed.value.object.get("result") orelse return writeCommandError(ctx, "provision-bundle.invalid_response", "provision bundle item response has no result", 1);
        const items = result_value.object.get("items") orelse return writeCommandError(ctx, "provision-bundle.invalid_response", "provision bundle item response has no items", 1);
        if (std.mem.eql(u8, command, "list")) {
            const cells = try ctx.allocator.alloc([4][]const u8, items.array.items.len);
            const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, items.array.items.len);
            const jsonl = try ctx.allocator.alloc([]const u8, items.array.items.len);
            for (items.array.items, 0..) |item, index| {
                cells[index] = .{ jsonString(item.object.get("name")), jsonString(item.object.get("action")), jsonString(item.object.get("destination")), jsonString(item.object.get("content_asset")) };
                rows[index] = .{ .cells = &cells[index] };
                jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = item }, .{});
            }
            const columns = [_]nodeforge.cli_table.Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "action", .title = "ACTION" }, .{ .key = "destination", .title = "DESTINATION" }, .{ .key = "content_asset", .title = "CONTENT_ASSET" } };
            try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No provision steps." } }, .json = body, .jsonl = jsonl });
            return;
        }
        if (items.array.items.len == 0) return writeCommandError(ctx, "provision-bundle.item_not_found", "provision bundle item was not found", 1);
        const item = items.array.items[0];
        var fields: [16]nodeforge.cli_document.Field = undefined;
        var count: usize = 0;
        var iterator = item.object.iterator();
        while (iterator.next()) |entry| {
            fields[count] = .{ .key = entry.key_ptr.*, .value = try jsonDisplay(ctx.allocator, entry.value_ptr.*), .section = "stored" };
            count += 1;
        }
        const sections = [_]nodeforge.cli_document.Section{.{ .key = "stored", .title = "Stored" }};
        const title = try std.fmt.allocPrint(ctx.allocator, "Provision step {s}", .{identity.?});
        const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = item }, .{});
        try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = fields[0..count] } }, .json = json });
        return;
    }
    var patch: nodeforge.provision_bundle_mutation.Patch = .{ .operation = if (std.mem.eql(u8, command, "add")) .add else if (std.mem.eql(u8, command, "set")) .set else if (std.mem.eql(u8, command, "remove")) .remove else .move, .identity = if (std.mem.eql(u8, command, "add")) "" else ctx.positional_args[2] };
    var package_values: std.ArrayList([]const u8) = .empty;
    defer package_values.deinit(ctx.allocator);
    if (patch.operation == .move) {
        const before = ctx.flag("before", []const u8);
        const after = ctx.flag("after", []const u8);
        if ((before.len == 0) == (after.len == 0)) return itemUsageError(ctx, "move requires exactly one of --before or --after");
        patch.before = if (before.len == 0) null else before;
        patch.after = if (after.len == 0) null else after;
    }
    var unset_values: [1][]const u8 = undefined;
    if (patch.operation == .set) {
        const unset = ctx.flag("unset", []const u8);
        if (unset.len != 0) {
            unset_values[0] = unset;
            patch.unset = &unset_values;
        }
    }
    const field_start: usize = if (patch.operation == .add) 2 else 3;
    if (patch.operation == .add or patch.operation == .set) for (ctx.positional_args[field_start..]) |assignment| {
        const equal = std.mem.indexOfScalar(u8, assignment, '=') orelse return itemUsageError(ctx, "step fields require field=value");
        const field = assignment[0..equal];
        const value = assignment[equal + 1 ..];
        if (std.mem.eql(u8, field, "name")) patch.name = value else if (std.mem.eql(u8, field, "action")) patch.action = value else if (std.mem.eql(u8, field, "phase")) patch.phase = value else if (std.mem.eql(u8, field, "idempotency_key")) patch.idempotency_key = value else if (std.mem.eql(u8, field, "timeout_s")) patch.timeout_s = std.fmt.parseInt(u32, value, 10) catch return itemUsageError(ctx, "timeout_s must be an integer") else if (std.mem.eql(u8, field, "retryable")) patch.retryable = if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else return itemUsageError(ctx, "retryable must be true or false") else if (std.mem.eql(u8, field, "packages")) {
            var parts = std.mem.splitScalar(u8, value, ',');
            while (parts.next()) |package| {
                if (package.len == 0) return itemUsageError(ctx, "packages must be a non-empty comma-separated list");
                try package_values.append(ctx.allocator, package);
            }
            patch.packages = package_values.items;
        } else if (std.mem.eql(u8, field, "destination")) patch.destination = value else if (std.mem.eql(u8, field, "content_asset")) patch.content_asset = value else if (std.mem.eql(u8, field, "mode")) patch.mode = std.fmt.parseInt(u16, std.mem.trimStart(u8, value, "0o"), 8) catch return itemUsageError(ctx, "mode must be octal") else if (std.mem.eql(u8, field, "owner")) patch.owner = value else if (std.mem.eql(u8, field, "group")) patch.group = value else return itemUsageError(ctx, "unknown provision step field");
    };
    if (patch.operation == .add) patch.identity = patch.name orelse return itemUsageError(ctx, "step add requires name");
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, patch, .{ .emit_null_optional_fields = false });
    defer ctx.allocator.free(body);
    try sendProvisionBundleItems(ctx, config.value.server.http_port, bundle, body);
}

fn provisionBundleReplaceHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const bundle = ctx.positional_args[0];
    if (!std.mem.eql(u8, ctx.positional_args[1], "steps")) return itemUsageError(ctx, "provision bundle item key must be steps");
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    if (std.mem.eql(u8, ctx.command.cmd_options.name, "clear-items")) return sendProvisionBundleItems(ctx, config.value.server.http_port, bundle, "{\"operation\":\"clear\",\"key\":\"steps\"}");
    const path = ctx.flag("from-file", []const u8);
    if (path.len == 0) return itemUsageError(ctx, "replace-items requires --from-file");
    const input = ctx.flag("input", []const u8);
    const bytes = if (std.mem.eql(u8, path, "-")) ctx.reader.allocRemaining(ctx.allocator, .limited(8 * 1024 * 1024)) catch return itemUsageError(ctx, "step stdin unreadable") else std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.allocator, .limited(8 * 1024 * 1024)) catch return itemUsageError(ctx, "step file unreadable");
    defer ctx.allocator.free(bytes);
    var steps: []nodeforge.provision_bundle_mutation.StepInput = undefined;
    var parsed_json: ?std.json.Parsed([]nodeforge.provision_bundle_mutation.StepInput) = null;
    defer if (parsed_json) |*parsed| parsed.deinit();
    if (std.mem.eql(u8, input, "json")) {
        parsed_json = std.json.parseFromSlice([]nodeforge.provision_bundle_mutation.StepInput, ctx.allocator, bytes, .{ .allocate = .alloc_always }) catch return itemUsageError(ctx, "invalid step JSON");
        steps = parsed_json.?.value;
    } else if (std.mem.eql(u8, input, "yaml")) steps = parseYamlProvisionSteps(ctx.allocator, bytes) catch return itemUsageError(ctx, "invalid step YAML") else return itemUsageError(ctx, "--input must be yaml or json");
    defer if (std.mem.eql(u8, input, "yaml")) ctx.allocator.free(steps);
    const body = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .operation = "replace", .key = "steps", .steps = steps }, .{});
    defer ctx.allocator.free(body);
    try sendProvisionBundleItems(ctx, config.value.server.http_port, bundle, body);
}

fn sendProvisionBundleItems(ctx: zli.CommandContext, port: u16, bundle: []const u8, body: []const u8) !void {
    var reason: [512]u8 = undefined;
    const result = nodeforge.management_client.provisionBundleMutation(ctx.io, port, "POST", bundle, true, body, &reason);
    if (!result.healthy) return reportMutationFailure(ctx, result, "provision bundle item mutation failed");
    const human = try std.fmt.allocPrint(ctx.allocator, "updated provision bundle {s}", .{bundle});
    try renderCommandResult(ctx, human, .{ .bundle = bundle, .updated = true });
}

fn parseYamlProvisionSteps(allocator: std.mem.Allocator, bytes: []const u8) ![]nodeforge.provision_bundle_mutation.StepInput {
    var items: std.ArrayList(nodeforge.provision_bundle_mutation.StepInput) = .empty;
    errdefer items.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| if (try yamlField(line)) |field| {
        if (field.starts_item) try items.append(allocator, .{ .name = "", .destination = "", .content_asset = "" });
        if (field.key.len == 0) continue;
        if (items.items.len == 0) return error.InvalidYaml;
        const item = &items.items[items.items.len - 1];
        if (std.mem.eql(u8, field.key, "name")) item.name = field.value else if (std.mem.eql(u8, field.key, "action")) {
            if (!std.mem.eql(u8, field.value, "managed-file")) return error.InvalidYaml;
        } else if (std.mem.eql(u8, field.key, "destination")) item.destination = field.value else if (std.mem.eql(u8, field.key, "content_asset")) item.content_asset = field.value else if (std.mem.eql(u8, field.key, "mode")) item.mode = try std.fmt.parseInt(u16, std.mem.trimStart(u8, field.value, "0o"), 8) else if (std.mem.eql(u8, field.key, "owner")) item.owner = field.value else if (std.mem.eql(u8, field.key, "group")) item.group = field.value else return error.InvalidYaml;
    };
    return items.toOwnedSlice(allocator);
}

fn assetShowHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer loaded.deinit();
    const name = ctx.getArg("name") orelse unreachable;
    for (loaded.value().assets) |item| if (std.mem.eql(u8, item.name, name)) {
        const fields = [_]nodeforge.cli_document.Field{ .{ .key = "name", .value = item.name, .section = "stored" }, .{ .key = "kind", .value = @tagName(item.kind), .section = "stored" }, .{ .key = "path", .value = item.path, .section = "stored" }, .{ .key = "sha256", .value = item.sha256 orelse "<unset>", .section = "stored" }, .{ .key = "revision", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{item.revision}), .section = "stored" }, .{ .key = "size", .value = if (item.size) |size| try std.fmt.allocPrint(ctx.allocator, "{d}", .{size}) else "<unset>", .section = "stored" }, .{ .key = "media_type", .value = item.media_type orelse "<unset>", .section = "stored" } };
        const sections = [_]nodeforge.cli_document.Section{.{ .key = "stored", .title = "Stored" }};
        const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = item }, .{});
        const title = try std.fmt.allocPrint(ctx.allocator, "Asset {s}", .{item.name});
        try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = &fields } }, .json = json });
        return;
    };
    const message = try std.fmt.allocPrint(ctx.allocator, "asset not found: {s}", .{name});
    try writeCommandError(ctx, "asset.not_found", message, 1);
}

fn assetValidateHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    var loaded = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer loaded.deinit();
    for (loaded.value().assets) |item| {
        var digest: [64]u8 = undefined;
        nodeforge.asset_validate.sha256File(ctx.io, assetRoot(&parsed_config.value, item.kind), item.path, &digest) catch {
            const message = try std.fmt.allocPrint(ctx.allocator, "asset is unreadable: {s}", .{item.path});
            try writeCommandError(ctx, "asset.unreadable", message, 1);
            return;
        };
        if (item.sha256 == null or !std.mem.eql(u8, item.sha256.?, &digest)) {
            const message = try std.fmt.allocPrint(ctx.allocator, "asset checksum mismatch: {s}", .{item.name});
            try writeCommandError(ctx, "asset.checksum_mismatch", message, 1);
            return;
        }
    }
    const human = try std.fmt.allocPrint(ctx.allocator, "assets valid ({d})", .{loaded.value().assets.len});
    try renderCommandResult(ctx, human, .{ .valid = true, .assets = loaded.value().assets.len });
}

fn assetKeyImportHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const source = ctx.getArg("path") orelse unreachable;
    const basename = std.fs.path.basename(source);
    if (basename.len == 0 or !std.mem.endsWith(u8, basename, ".pub")) {
        try writeCommandError(ctx, "key.invalid_file", "key import requires a .pub file", 1);
        return;
    }
    // assets/keys/id_ed25519{,.pub} 是 NodeForge 自动生成 key pair 的保留名。
    // 操作员导入常见的 ~/.ssh/id_ed25519.pub 时安全改名，不能覆盖或拆散该 pair。
    const destination_name = if (std.mem.eql(u8, basename, "id_ed25519.pub")) "imported-id_ed25519.pub" else basename;
    const key = nodeforge.admin_key.loadPublicKey(ctx.io, ctx.allocator, source) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "invalid public key ({t})", .{err});
        try writeCommandError(ctx, "key.invalid", message, 1);
        return;
    };
    defer ctx.allocator.free(key);

    const destination = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ nodeforge.paths.require().keys_dir, destination_name });
    defer ctx.allocator.free(destination);
    try std.Io.Dir.cwd().createDirPath(ctx.io, nodeforge.paths.require().keys_dir);
    var atomic_file = std.Io.Dir.cwd().createFileAtomic(ctx.io, destination, .{ .permissions = .default_file, .make_path = true, .replace = false }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "cannot create key destination ({t})", .{err});
        try writeCommandError(ctx, "key.publish_failed", message, 1);
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
        const message = try std.fmt.allocPrint(ctx.allocator, "key destination exists or cannot be published ({t})", .{err});
        try writeCommandError(ctx, "key.publish_failed", message, 1);
        return;
    };

    const fingerprint = try nodeforge.admin_key.fingerprint(ctx.allocator, key);
    defer ctx.allocator.free(fingerprint);
    const human = try std.fmt.allocPrint(ctx.allocator, "SSH public key imported: {s} ({s})", .{ destination_name, fingerprint });
    try renderCommandResult(ctx, human, .{ .file = destination_name, .fingerprint = fingerprint });
}

fn assetKeyReloadHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const status = nodeforge.management_client.managementStatus(ctx.io, config.value.server.http_port);
    if (!status.healthy) {
        try writeCommandError(ctx, "key.reload_failed", "key reload could not reach the local daemon", 1);
        return;
    }
    try renderCommandResult(ctx, "SSH public key reload requested", .{ .reload = "requested" });
}

fn assetKeyShowHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const primary = nodeforge.admin_key.resolve(ctx.io, ctx.allocator, config.value.server) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "cannot resolve effective keys ({t})", .{err});
        try writeCommandError(ctx, "key.resolve_failed", message, 1);
        return;
    };
    defer ctx.allocator.free(primary);
    const additional = try nodeforge.admin_key.resolveAdditional(ctx.io, ctx.allocator, config.value.server);
    defer {
        for (additional) |key| ctx.allocator.free(key);
        ctx.allocator.free(additional);
    }
    const Item = struct { index: usize, source: []const u8, fingerprint: []const u8 };
    const count = additional.len + 1;
    const items = try ctx.allocator.alloc(Item, count);
    defer ctx.allocator.free(items);
    const cells = try ctx.allocator.alloc([3][]const u8, count);
    const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, count);
    const jsonl = try ctx.allocator.alloc([]const u8, count);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const key = if (index == 0) primary else additional[index - 1];
        const fingerprint = try nodeforge.admin_key.fingerprint(ctx.allocator, key);
        const source = try nodeforge.admin_key.sourceLabel(ctx.io, ctx.allocator, config.value.server, key);
        items[index] = .{ .index = index, .source = source, .fingerprint = fingerprint };
        cells[index] = .{ try std.fmt.allocPrint(ctx.allocator, "{d}", .{index}), source, fingerprint };
        rows[index] = .{ .cells = &cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = items[index] }, .{});
    }
    defer for (items) |item| {
        ctx.allocator.free(item.source);
        ctx.allocator.free(item.fingerprint);
    };
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .items = items } }, .{});
    const columns = [_]nodeforge.cli_table.Column{ .{ .key = "index", .title = "INDEX", .alignment = .right }, .{ .key = "source", .title = "SOURCE" }, .{ .key = "fingerprint", .title = "FINGERPRINT" } };
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No effective SSH keys." } }, .json = json, .jsonl = jsonl });
}

fn assetKeyListHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| ctx.allocator.free(name);
        names.deinit(ctx.allocator);
    }
    var directory = std.Io.Dir.cwd().openDir(ctx.io, nodeforge.paths.require().keys_dir, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .items = &[_][]const u8{} } }, .{});
            const columns = [_]nodeforge.cli_table.Column{.{ .key = "name", .title = "NAME" }};
            try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = &.{}, .empty_message = "No SSH public keys imported." } }, .json = json, .jsonl = &.{} });
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
    const cells = try ctx.allocator.alloc([1][]const u8, names.items.len);
    const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, names.items.len);
    const jsonl = try ctx.allocator.alloc([]const u8, names.items.len);
    for (names.items, 0..) |name, index| {
        cells[index] = .{name};
        rows[index] = .{ .cells = &cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .name = name } }, .{});
    }
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .items = names.items } }, .{});
    const columns = [_]nodeforge.cli_table.Column{.{ .key = "name", .title = "NAME" }};
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No SSH public keys imported." } }, .json = json, .jsonl = jsonl });
}

fn assetRoot(config: *const nodeforge.model.AppConfig, kind: nodeforge.model.AssetKind) []const u8 {
    return switch (kind) {
        .iso => config.http.asset_root,
        .bootloader, .kernel, .installer_initrd => config.tftp.asset_root,
        .gpg_key => nodeforge.paths.require().keys_dir,
        .nodeforge_initrd => nodeforge.paths.require().initrd_dir,
        .rootfs => nodeforge.paths.require().rootfs_dir,
        .runtime_kernel => config.tftp.asset_root,
        .archive, .script => nodeforge.paths.require().assets_dir,
        .managed_file => nodeforge.paths.require().assets_dir,
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
    _ = outputFromContext(ctx) orelse return;
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    const status = nodeforge.management_client.tftpCounters(ctx.io, parsed_config.value.server.http_port);
    if (!status.healthy) {
        try writeCommandError(ctx, "tftp.unavailable", "local daemon TFTP status unavailable", 1);
        return;
    }
    const fields = [_]nodeforge.cli_document.Field{ .{ .key = "started", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{status.started}), .section = "runtime" }, .{ .key = "completed", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{status.completed}), .section = "runtime" }, .{ .key = "failed", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{status.failed}), .section = "runtime" } };
    const sections = [_]nodeforge.cli_document.Section{.{ .key = "runtime", .title = "Runtime" }};
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .started = status.started, .completed = status.completed, .failed = status.failed } }, .{});
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = "TFTP", .sections = &sections, .fields = &fields } }, .json = json });
}

fn tftpSessionListHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var parsed_config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer parsed_config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = try nodeforge.management_client.tftpSessionsJson(ctx.io, parsed_config.value.server.http_port, response);
    if (body == null) {
        try writeCommandError(ctx, "tftp.sessions_unavailable", "local daemon TFTP session API unavailable", 1);
        return;
    }
    const SessionResponse = struct { ok: bool, result: struct { sessions: []const struct { id: u64, phase: nodeforge.runtime_state.TftpSessionPhase, filename: []const u8 } } };
    var parsed = std.json.parseFromSlice(SessionResponse, ctx.allocator, body.?, .{ .allocate = .alloc_always }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed TFTP session response ({t})", .{err});
        try writeCommandError(ctx, "tftp.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const count = parsed.value.result.sessions.len;
    const cells = try ctx.allocator.alloc([3][]const u8, count);
    const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, count);
    const jsonl = try ctx.allocator.alloc([]const u8, count);
    for (parsed.value.result.sessions, 0..) |session, index| {
        cells[index] = .{ try std.fmt.allocPrint(ctx.allocator, "{d}", .{session.id}), @tagName(session.phase), session.filename };
        rows[index] = .{ .cells = &cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = session }, .{});
    }
    const columns = [_]nodeforge.cli_table.Column{ .{ .key = "id", .title = "ID" }, .{ .key = "phase", .title = "PHASE" }, .{ .key = "filename", .title = "FILENAME" } };
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No active TFTP sessions." } }, .json = body.?, .jsonl = jsonl });
}

fn dhcpShowHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const dhcp = config.value.dhcp;
    const fields = [_]nodeforge.cli_document.Field{ .{ .key = "subnet", .value = dhcp.subnet, .section = "stored" }, .{ .key = "pool_start", .value = dhcp.pool_start, .section = "stored" }, .{ .key = "pool_end", .value = dhcp.pool_end, .section = "stored" }, .{ .key = "lease_seconds", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{dhcp.lease_seconds}), .section = "stored" } };
    const sections = [_]nodeforge.cli_document.Section{.{ .key = "stored", .title = "Stored" }};
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .subnet = dhcp.subnet, .pool_start = dhcp.pool_start, .pool_end = dhcp.pool_end, .lease_seconds = dhcp.lease_seconds } }, .{});
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = "DHCP", .sections = &sections, .fields = &fields } }, .json = json });
}

fn runtimeLeasesHandler(ctx: zli.CommandContext) !void {
    try runtimeLeaseList(ctx, false);
}

fn runtimeUnknownHandler(ctx: zli.CommandContext) !void {
    try runtimeLeaseList(ctx, true);
}

fn runtimeLeaseList(ctx: zli.CommandContext, unknown_only: bool) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = try nodeforge.management_client.dhcpLeasesJson(ctx.io, config.value.server.http_port, unknown_only, response);
    if (body == null) {
        try writeCommandError(ctx, "dhcp.leases_unavailable", "local daemon DHCP lease API unavailable", 1);
        return;
    }
    const Response = struct { ok: bool, result: struct { leases: []const struct { phase: nodeforge.runtime_state.LeasePhase, known: bool, ip: []const u8, mac: []const u8, expires_at: i64 } } };
    var parsed = std.json.parseFromSlice(Response, ctx.allocator, body.?, .{ .allocate = .alloc_always }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed DHCP lease response ({t})", .{err});
        try writeCommandError(ctx, "dhcp.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const count = parsed.value.result.leases.len;
    const cells = try ctx.allocator.alloc([4][]const u8, count);
    const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, count);
    const jsonl = try ctx.allocator.alloc([]const u8, count);
    for (parsed.value.result.leases, 0..) |lease, index| {
        cells[index] = .{ lease.ip, lease.mac, @tagName(lease.phase), try std.fmt.allocPrint(ctx.allocator, "{d}", .{lease.expires_at}) };
        rows[index] = .{ .cells = &cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = lease }, .{});
    }
    const columns = [_]nodeforge.cli_table.Column{ .{ .key = "ip", .title = "IP" }, .{ .key = "mac", .title = "MAC" }, .{ .key = "phase", .title = "PHASE" }, .{ .key = "expires", .title = "EXPIRES" } };
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = if (unknown_only) "No unknown clients." else "No DHCP leases." } }, .json = body.?, .jsonl = jsonl });
}

const DiscoveryObservation = nodeforge.model.UnknownClientObservation;

fn discoveryListHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = (nodeforge.management_client.collectionPageJson(ctx.io, config.value.server.http_port, "/api/v1/management/discovery/observations", null, response) catch null) orelse {
        try writeCommandError(ctx, "discovery.unavailable", "local daemon discovery API unavailable", 1);
        return;
    };
    const Response = struct { result: struct { items: []const DiscoveryObservation } };
    var parsed = std.json.parseFromSlice(Response, ctx.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed discovery response ({t})", .{err});
        try writeCommandError(ctx, "discovery.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const count = parsed.value.result.items.len;
    const cells = try ctx.allocator.alloc([7][]const u8, count);
    const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, count);
    const jsonl = try ctx.allocator.alloc([]const u8, count);
    for (parsed.value.result.items, 0..) |item, index| {
        cells[index] = .{ item.mac, if (item.observed_architecture) |arch| @tagName(arch) else "-", item.last_ip orelse "-", try std.fmt.allocPrint(ctx.allocator, "{d}", .{item.request_count}), try std.fmt.allocPrint(ctx.allocator, "{d}", .{item.revision}), if (item.claim != null) "true" else "false", if (item.claim) |claim| claim.node_id else "-" };
        rows[index] = .{ .cells = &cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = item }, .{});
    }
    const columns = [_]nodeforge.cli_table.Column{ .{ .key = "mac", .title = "MAC" }, .{ .key = "arch", .title = "ARCH" }, .{ .key = "last_ip", .title = "LAST_IP" }, .{ .key = "requests", .title = "REQUESTS", .alignment = .right }, .{ .key = "revision", .title = "REV", .alignment = .right }, .{ .key = "claimed", .title = "CLAIMED" }, .{ .key = "node", .title = "NODE" } };
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No discovery observations." } }, .json = body, .jsonl = jsonl });
}

fn discoveryShowHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const mac = ctx.getArg("mac") orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = (nodeforge.management_client.discoveryObservationsJson(ctx.io, config.value.server.http_port, mac, response) catch null) orelse {
        try writeCommandError(ctx, "discovery.not_found", "observation was not found", 1);
        return;
    };
    const Response = struct { result: DiscoveryObservation };
    var parsed = try std.json.parseFromSlice(Response, ctx.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    defer parsed.deinit();
    const item = parsed.value.result;
    const fields = [_]nodeforge.cli_document.Field{ .{ .key = "mac", .value = item.mac, .section = "stored" }, .{ .key = "observed_architecture", .value = if (item.observed_architecture) |arch| @tagName(arch) else "-", .section = "stored" }, .{ .key = "dhcp_client_id", .value = item.dhcp_client_id orelse "<unset>", .section = "stored" }, .{ .key = "vendor_class", .value = item.vendor_class orelse "<unset>", .section = "stored" }, .{ .key = "first_seen_unix", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{item.first_seen_unix}), .section = "runtime" }, .{ .key = "last_seen_unix", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{item.last_seen_unix}), .section = "runtime" }, .{ .key = "last_ip", .value = item.last_ip orelse "<unset>", .section = "runtime" }, .{ .key = "request_count", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{item.request_count}), .section = "runtime" }, .{ .key = "revision", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{item.revision}), .section = "runtime" }, .{ .key = "claim", .value = if (item.claim) |claim| claim.node_id else "<unset>", .section = "runtime" } };
    const sections = [_]nodeforge.cli_document.Section{ .{ .key = "stored", .title = "Stored" }, .{ .key = "runtime", .title = "Runtime" } };
    const title = try std.fmt.allocPrint(ctx.allocator, "Discovery {s}", .{item.mac});
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = &fields } }, .json = body });
}

fn discoveryPolicyShowHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = (nodeforge.management_client.discoveryPolicyJson(ctx.io, config.value.server.http_port, response) catch null) orelse {
        try writeCommandError(ctx, "discovery.policy_unavailable", "discovery policy API unavailable", 1);
        return;
    };
    const Response = struct { result: struct { unknown_action: []const u8, observation_retention_days: u32, revision: u64 } };
    var parsed = std.json.parseFromSlice(Response, ctx.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed discovery policy response ({t})", .{err});
        try writeCommandError(ctx, "discovery.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const fields = [_]nodeforge.cli_document.Field{ .{ .key = "unknown_action", .value = parsed.value.result.unknown_action, .section = "stored" }, .{ .key = "observation_retention_days", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{parsed.value.result.observation_retention_days}), .section = "stored" }, .{ .key = "revision", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{parsed.value.result.revision}), .section = "runtime" } };
    const sections = [_]nodeforge.cli_document.Section{ .{ .key = "stored", .title = "Stored" }, .{ .key = "runtime", .title = "Runtime" } };
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = "Discovery policy", .sections = &sections, .fields = &fields } }, .json = body });
}

fn discoveryPolicySetHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var action: ?[]const u8 = null;
    var retention: ?u32 = null;
    for (ctx.positional_args) |property| {
        const eq = std.mem.indexOfScalar(u8, property, '=') orelse return error.InvalidArgument;
        const key = property[0..eq];
        const value = property[eq + 1 ..];
        if (std.mem.eql(u8, key, "unknown_action")) {
            if (!std.mem.eql(u8, value, "record") and !std.mem.eql(u8, value, "deny")) return error.InvalidFlagValue;
            action = value;
        } else if (std.mem.eql(u8, key, "observation_retention_days")) retention = try std.fmt.parseInt(u32, value, 10) else return error.InvalidArgument;
    }
    var body: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer body.deinit();
    try body.writer.writeByte('{');
    if (action) |value| try body.writer.print("\"unknown_action\":{f}", .{std.json.fmt(value, .{})});
    if (retention) |value| try body.writer.print("{s}\"observation_retention_days\":{d}", .{ if (action != null) "," else "", value });
    try body.writer.writeByte('}');
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [512]u8 = undefined;
    const result = nodeforge.management_client.discoveryPolicySet(ctx.io, config.value.server.http_port, body.written(), &reason);
    if (!result.healthy) return reportMutationFailure(ctx, result, "discovery policy update failed");
    try renderCommandResult(ctx, "discovery policy updated", .{ .mutation = "applied_online" });
}

fn nodeClaimHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const node_id = ctx.getArg("node_id") orelse return;
    var mac: ?[]const u8 = null;
    var arch: ?[]const u8 = null;
    for (ctx.positional_args[1..]) |property| {
        const eq = std.mem.indexOfScalar(u8, property, '=') orelse return error.InvalidArgument;
        if (std.mem.eql(u8, property[0..eq], "discovery.mac")) mac = property[eq + 1 ..] else if (std.mem.eql(u8, property[0..eq], "arch")) arch = property[eq + 1 ..] else return error.InvalidArgument;
    }
    const revision_value = ctx.flag("observation-revision", i64);
    if (mac == null or arch == null or revision_value <= 0) return error.InvalidArgument;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [512]u8 = undefined;
    const result = nodeforge.management_client.nodeClaim(ctx.io, config.value.server.http_port, node_id, mac.?, arch.?, @intCast(revision_value), &reason);
    if (!result.healthy) return reportMutationFailure(ctx, result, "node claim failed");
    try renderCommandResult(ctx, "observation claimed", .{ .node_id = node_id, .mac = mac.?, .profile = @as(?[]const u8, null), .deploy = false });
}

const NodeListViewRevision = struct { config: u64, catalog: u64, node_status: u64, deployment: u64, inventory: u64 };
const NodeListItem = struct {
    id: []const u8,
    mac: []const u8,
    pxe: struct { ip_reservation: ?[]const u8 },
    profile: ?[]const u8,
    deploy: bool,
    install_intent: []const u8,
    pxe_ready: bool,
    retry_pending: bool,
    armed_generation: ?u64,
    status: ?[]const u8,
    armed_at: ?i64,
    install_at: ?i64,
    finished_at: ?i64,
    deployed_at: ?i64,
    drifted: bool,
    drift_state: ?[]const u8 = null,
    serial_number: ?[]const u8,
};
const NodeListPage = struct { ok: bool, result: struct { view_revision: NodeListViewRevision, items: []const NodeListItem, next_cursor: ?[]const u8 } };

fn nodeListHandler(ctx: zli.CommandContext) !void {
    const output = outputFromContext(ctx) orelse return;
    const machine_output = output.mode != .human;
    const show_timestamps = ctx.flag("long", bool) or output.columns.len != 0;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    // 两种输出模式各自处理分页。JSON 是一个完整集合
    // 信封；human 渲染保持其文档约定的 256 行显示上限。
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const first = nodeforge.management_client.collectionPageJson(ctx.io, config.value.server.http_port, "/api/v1/management/nodes", null, response) catch {
        try cli_output.writeError(errorWriter(ctx), output, "node.unavailable", "local daemon management API unavailable");
        setExitCode(ctx, 1);
        return;
    };
    var page_body = first orelse {
        try cli_output.writeError(errorWriter(ctx), output, "node.unavailable", "local daemon management API unavailable");
        setExitCode(ctx, 1);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var items: std.ArrayList(NodeListItem) = .empty;
    var cursor_buf: [256]u8 = undefined;
    var cursor: ?[]const u8 = null;
    var truncated = false;
    var view_revision: ?NodeListViewRevision = null;
    while (true) {
        const parsed = std.json.parseFromSlice(NodeListPage, a, page_body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
            nodeforge.management_client.reportJsonFailure("NodeListPage", err, page_body);
            try cli_output.writeError(errorWriter(ctx), output, "node.invalid_response", "malformed daemon response");
            setExitCode(ctx, 1);
            return;
        };
        if (view_revision) |expected| {
            if (!std.meta.eql(expected, parsed.value.result.view_revision)) {
                try cli_output.writeError(errorWriter(ctx), output, "node.view_changed", "node view changed while following pagination; retry the command");
                setExitCode(ctx, 1);
                return;
            }
        } else view_revision = parsed.value.result.view_revision;
        for (parsed.value.result.items) |item| {
            if (!machine_output and items.items.len >= 256) {
                truncated = true;
                break;
            }
            try items.append(a, item);
        }
        if (truncated) break;
        if (parsed.value.result.next_cursor) |nc| {
            if (nc.len <= cursor_buf.len) {
                @memcpy(cursor_buf[0..nc.len], nc);
                cursor = cursor_buf[0..nc.len];
            } else {
                try cli_output.writeError(errorWriter(ctx), output, "node.invalid_cursor", "daemon returned an oversized pagination cursor");
                setExitCode(ctx, 1);
                return;
            }
        } else break;
        page_body = (nodeforge.management_client.collectionPageJson(ctx.io, config.value.server.http_port, "/api/v1/management/nodes", cursor, response) catch null) orelse {
            try cli_output.writeError(errorWriter(ctx), output, "node.pagination_failed", "daemon became unavailable while following pagination");
            setExitCode(ctx, 1);
            return;
        };
    }
    const full_cells = try a.alloc([11][]const u8, items.items.len);
    const full_rows = try a.alloc(nodeforge.cli_table.Row, items.items.len);
    const compact_cells = try a.alloc([8][]const u8, items.items.len);
    const compact_rows = try a.alloc(nodeforge.cli_table.Row, items.items.len);
    const jsonl = try a.alloc([]const u8, items.items.len);
    for (items.items, 0..) |item, index| {
        var armed_buf: [20]u8 = undefined;
        var install_buf: [20]u8 = undefined;
        var finished_buf: [20]u8 = undefined;
        full_cells[index] = .{
            item.id,
            item.mac,
            item.pxe.ip_reservation orelse "-",
            item.profile orelse "<unassigned>",
            if (item.deploy) "true" else "false",
            item.install_intent,
            item.status orelse "-",
            try a.dupe(u8, views.formatTimestamp(&armed_buf, item.armed_at orelse 0)),
            try a.dupe(u8, views.formatTimestamp(&install_buf, item.install_at orelse 0)),
            try a.dupe(u8, views.formatTimestamp(&finished_buf, item.finished_at orelse 0)),
            item.serial_number orelse "-",
        };
        full_rows[index] = .{ .cells = &full_cells[index] };
        compact_cells[index] = .{
            full_cells[index][0],
            full_cells[index][1],
            full_cells[index][2],
            full_cells[index][3],
            full_cells[index][4],
            full_cells[index][5],
            full_cells[index][6],
            full_cells[index][10],
        };
        compact_rows[index] = .{ .cells = &compact_cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(a, .{ .ok = true, .result = item }, .{});
    }
    const Result = struct { view_revision: NodeListViewRevision, items: []const NodeListItem, next_cursor: ?[]const u8 = null };
    const json = try std.json.Stringify.valueAlloc(a, .{ .ok = true, .result = Result{ .view_revision = view_revision.?, .items = items.items } }, .{});
    const full_columns = [_]nodeforge.cli_table.Column{ .{ .key = "id", .title = "ID" }, .{ .key = "mac", .title = "MAC" }, .{ .key = "ip", .title = "IP" }, .{ .key = "profile", .title = "PROFILE" }, .{ .key = "deploy", .title = "DEPLOY" }, .{ .key = "intent", .title = "INSTALL_INTENT" }, .{ .key = "status", .title = "STATUS" }, .{ .key = "armed_at", .title = "ARMED" }, .{ .key = "install_at", .title = "INSTALL" }, .{ .key = "finished_at", .title = "FINISHED" }, .{ .key = "sn", .title = "SN" } };
    const compact_columns = [_]nodeforge.cli_table.Column{ .{ .key = "id", .title = "ID" }, .{ .key = "mac", .title = "MAC" }, .{ .key = "ip", .title = "IP" }, .{ .key = "profile", .title = "PROFILE" }, .{ .key = "deploy", .title = "DEPLOY" }, .{ .key = "intent", .title = "INSTALL_INTENT" }, .{ .key = "status", .title = "STATUS" }, .{ .key = "sn", .title = "SN" } };
    const human: nodeforge.cli_document.Human = if (show_timestamps)
        .{ .table = .{ .columns = &full_columns, .rows = full_rows, .empty_message = "No nodes registered." } }
    else
        .{ .table = .{ .columns = &compact_columns, .rows = compact_rows, .empty_message = "No nodes registered." } };
    try renderOutputDocument(ctx, .{ .human = human, .json = json, .jsonl = jsonl });
    if (truncated) try errorWriter(ctx).writeAll("note: node list truncated at 256 rows; use the management API with limit/cursor for the full list\n");
}

const ProfileListItem = struct { name: []const u8, kind: []const u8, boot_bundle: ?[]const u8, install_source: []const u8, platform: struct { distro: []const u8, version: []const u8, arch: []const u8 }, nodes: usize, valid: bool };
const ProfileListPage = struct { ok: bool, result: struct { items: []const ProfileListItem, next_cursor: ?[]const u8, view_revision: u64 } };

fn profileListHandler(ctx: zli.CommandContext) !void {
    const output = outputFromContext(ctx) orelse return;
    const machine_output = output.mode != .human;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const first = nodeforge.management_client.collectionPageJson(ctx.io, config.value.server.http_port, "/api/v1/management/profiles", null, response) catch {
        try cli_output.writeError(errorWriter(ctx), output, "profile.unavailable", "local daemon management API unavailable");
        setExitCode(ctx, 1);
        return;
    };
    var page_body = first orelse {
        try cli_output.writeError(errorWriter(ctx), output, "profile.unavailable", "local daemon management API unavailable");
        setExitCode(ctx, 1);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var items: std.ArrayList(ProfileListItem) = .empty;
    var cursor_buf: [256]u8 = undefined;
    var cursor: ?[]const u8 = null;
    var truncated = false;
    var view_revision: ?u64 = null;
    while (true) {
        const parsed = std.json.parseFromSlice(ProfileListPage, a, page_body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
            nodeforge.management_client.reportJsonFailure("ProfileListPage", err, page_body);
            try cli_output.writeError(errorWriter(ctx), output, "profile.invalid_response", "malformed daemon response");
            setExitCode(ctx, 1);
            return;
        };
        if (view_revision) |expected| {
            if (expected != parsed.value.result.view_revision) {
                try cli_output.writeError(errorWriter(ctx), output, "profile.view_changed", "profile view changed while following pagination; retry the command");
                setExitCode(ctx, 1);
                return;
            }
        } else view_revision = parsed.value.result.view_revision;
        for (parsed.value.result.items) |profile| {
            if (!machine_output and items.items.len >= 256) {
                truncated = true;
                break;
            }
            try items.append(a, profile);
        }
        if (truncated) break;
        if (parsed.value.result.next_cursor) |nc| {
            if (nc.len <= cursor_buf.len) {
                @memcpy(cursor_buf[0..nc.len], nc);
                cursor = cursor_buf[0..nc.len];
            } else {
                try cli_output.writeError(errorWriter(ctx), output, "profile.invalid_cursor", "daemon returned an oversized pagination cursor");
                setExitCode(ctx, 1);
                return;
            }
        } else break;
        page_body = (nodeforge.management_client.collectionPageJson(ctx.io, config.value.server.http_port, "/api/v1/management/profiles", cursor, response) catch null) orelse {
            try cli_output.writeError(errorWriter(ctx), output, "profile.pagination_failed", "daemon became unavailable while following pagination");
            setExitCode(ctx, 1);
            return;
        };
    }
    const cells = try a.alloc([9][]const u8, items.items.len);
    const rows = try a.alloc(nodeforge.cli_table.Row, items.items.len);
    const jsonl = try a.alloc([]const u8, items.items.len);
    for (items.items, 0..) |profile, index| {
        var count_buf: [24]u8 = undefined;
        cells[index] = .{ profile.name, profile.kind, profile.platform.distro, profile.platform.version, profile.platform.arch, profile.install_source, profile.boot_bundle orelse "-", try a.dupe(u8, try std.fmt.bufPrint(&count_buf, "{d}", .{profile.nodes})), if (profile.valid) "true" else "false" };
        rows[index] = .{ .cells = &cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(a, .{ .ok = true, .result = profile }, .{});
    }
    const Result = struct { items: []const ProfileListItem, next_cursor: ?[]const u8 = null, view_revision: u64 };
    const json = try std.json.Stringify.valueAlloc(a, .{ .ok = true, .result = Result{ .items = items.items, .view_revision = view_revision.? } }, .{});
    const columns = [_]nodeforge.cli_table.Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "kind", .title = "KIND" }, .{ .key = "distro", .title = "DISTRO" }, .{ .key = "version", .title = "VERSION" }, .{ .key = "arch", .title = "ARCH" }, .{ .key = "source", .title = "INSTALL_SOURCE" }, .{ .key = "boot_bundle", .title = "BOOT_BUNDLE" }, .{ .key = "nodes", .title = "NODES", .alignment = .right }, .{ .key = "valid", .title = "VALID" } };
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No profiles configured." } }, .json = json, .jsonl = jsonl });
    if (truncated) try errorWriter(ctx).writeAll("note: profile list truncated at 256 rows; use the management API with limit/cursor for the full list\n");
}

fn writeSettableKeys(writer: *std.Io.Writer, owner: cli_properties.Owner, show_command: []const u8) !void {
    try writer.writeAll("Settable keys: ");
    var first = true;
    for (cli_properties.properties) |spec| {
        if (spec.owner != owner or spec.mutability != .mutable) continue;
        if (!first) try writer.writeAll(", ");
        try writer.writeAll(spec.path);
        first = false;
    }
    try writer.print(" (see: {s})\n", .{show_command});
}

fn profileShowHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const name = ctx.getArg("name") orelse return;
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = try nodeforge.management_client.profilesJson(ctx.io, config.value.server.http_port, name, response);
    if (body == null) {
        try writeCommandError(ctx, "profile.unavailable", "local daemon management API unavailable", 1);
        return;
    }

    // M4.5 让 HTTP DTO 面向机器，而 CLI 渲染稳定、
    // 易扫描的 human 视图。切勿在 human 模式转储紧凑的 wire JSON。
    const Response = struct {
        result: struct {
            model_revision: struct { config: u64, catalog: u64 },
            name: []const u8,
            kind: []const u8,
            boot_bundle: ?[]const u8,
            platform: struct { distro: []const u8, version: []const u8, arch: []const u8 },
            kernel_args: ?[]const u8,
            install: model.InstallConfig,
            validation: struct { valid: bool },
            capability: struct { family: []const u8, install_adapter: []const u8, package_manager: []const u8 },
            effective_system: struct {
                localization: struct { locale: []const u8, timezone: []const u8, keyboard: []const u8 },
                connectivity: struct { mode: []const u8, time_sync: bool, ntp_servers: []const []const u8 },
                ssh: struct { enabled: bool, password_authentication: bool, root_login: []const u8, root_password: ?[]const u8, root_authorized_keys: []const []const u8 },
                security: struct { firewall: []const u8, selinux: []const u8, apparmor: []const u8 },
                users: []const std.json.Value,
                packages: []const []const u8,
            },
            install_source: struct { name: []const u8, source_label: ?[]const u8, media_tree_url: ?[]const u8, repositories: []const []const u8 },
            assets: []const struct { name: []const u8, kind: []const u8, path: []const u8, sha256: ?[]const u8 },
            nodes: []const []const u8,
        },
    };
    const parsed = std.json.parseFromSlice(Response, ctx.allocator, body.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed daemon response ({t})", .{err});
        try writeCommandError(ctx, "profile.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const result = parsed.value.result;
    const install = result.install;
    // R10: 格式化资产路径列表，使 profile show 能直接看到 kernel/initrd/rootfs 等受管文件路径。
    var assets_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer assets_buf.deinit();
    for (result.assets) |asset| {
        assets_buf.writer.print("{s} [{s}] -> {s}", .{ asset.name, asset.kind, asset.path }) catch {};
        if (asset.sha256) |sha| assets_buf.writer.print(" (sha256:{s})", .{sha[0..16]}) catch {};
        assets_buf.writer.writeByte('\n') catch {};
    }
    if (result.assets.len == 0) assets_buf.writer.writeAll("(none)\n") catch {};
    const sections = [_]nodeforge.cli_document.Section{ .{ .key = "stored", .title = "Stored" }, .{ .key = "effective", .title = "Effective" }, .{ .key = "capabilities", .title = "Capabilities" }, .{ .key = "assets", .title = "Assets" }, .{ .key = "runtime", .title = "Runtime" } };
    const fields = [_]nodeforge.cli_document.Field{
        .{ .key = "kind", .value = result.kind, .section = "stored" },
        .{ .key = "boot_bundle", .value = result.boot_bundle orelse "<unset>", .section = "stored" },
        .{ .key = "name", .value = result.name, .section = "stored" },
        .{ .key = "install_source", .value = result.install_source.name, .section = "stored", .json_path = "install_source.name" },
        .{ .key = "kernel_args", .value = result.kernel_args orelse "-", .section = "stored" },
        .{ .key = "platform.distro", .value = result.platform.distro, .section = "capabilities" },
        .{ .key = "platform.version", .value = result.platform.version, .section = "capabilities" },
        .{ .key = "platform.arch", .value = result.platform.arch, .section = "capabilities" },
        .{ .key = "install.storage.mode", .value = @tagName(install.storage.mode), .section = "effective", .json_path = "install.storage.mode" },
        .{ .key = "install.storage.wipe", .value = if (install.storage.wipe) "true" else "false", .section = "effective", .json_path = "install.storage.wipe" },
        .{ .key = "install.storage.partition_table", .value = @tagName(install.storage.partition_table), .section = "effective", .json_path = "install.storage.partition_table" },
        .{ .key = "install.bootloader.install", .value = if (install.bootloader.install) "true" else "false", .section = "effective", .json_path = "install.bootloader.install" },
        .{ .key = "system.localization.locale", .value = result.effective_system.localization.locale, .section = "effective", .json_path = "effective_system.localization.locale" },
        .{ .key = "system.localization.timezone", .value = result.effective_system.localization.timezone, .section = "effective", .json_path = "effective_system.localization.timezone" },
        .{ .key = "system.localization.keyboard", .value = result.effective_system.localization.keyboard, .section = "effective", .json_path = "effective_system.localization.keyboard" },
        .{ .key = "system.connectivity.time_sync", .value = if (result.effective_system.connectivity.time_sync) "true" else "false", .section = "effective", .json_path = "effective_system.connectivity.time_sync" },
        .{ .key = "system.ssh.enabled", .value = if (result.effective_system.ssh.enabled) "true" else "false", .section = "effective", .json_path = "effective_system.ssh.enabled" },
        .{ .key = "system.ssh.password_authentication", .value = if (result.effective_system.ssh.password_authentication) "true" else "false", .section = "effective", .json_path = "effective_system.ssh.password_authentication" },
        .{ .key = "system.ssh.root_login", .value = result.effective_system.ssh.root_login, .section = "effective", .json_path = "effective_system.ssh.root_login" },
        .{ .key = "system.ssh.root_password", .value = if (result.effective_system.ssh.root_password != null) "<redacted>" else "<unset>", .section = "effective", .json_path = "effective_system.ssh.root_password" },
        .{ .key = "system.security.firewall", .value = result.effective_system.security.firewall, .section = "effective", .json_path = "effective_system.security.firewall" },
        .{ .key = "system.security.selinux", .value = result.effective_system.security.selinux, .section = "effective", .json_path = "effective_system.security.selinux" },
        .{ .key = "system.security.apparmor", .value = result.effective_system.security.apparmor, .section = "effective", .json_path = "effective_system.security.apparmor" },
        .{ .key = "install.apt.fallback", .value = @tagName(install.apt.fallback), .section = "effective", .json_path = "install.apt.fallback" },
        .{ .key = "install.apt.preserve_sources_list", .value = if (install.apt.preserve_sources_list) "true" else "false", .section = "effective", .json_path = "install.apt.preserve_sources_list" },
        .{ .key = "install.completion.action", .value = @tagName(install.completion.action), .section = "effective", .json_path = "install.completion.action" },
        .{ .key = "install.updates.mode", .value = @tagName(install.updates.mode), .section = "effective", .json_path = "install.updates.mode" },
        .{ .key = "install.proxy.url", .value = install.proxy.url orelse "<unset>", .section = "effective", .json_path = "install.proxy.url" },
        .{ .key = "install.reinstall_policy", .value = @tagName(install.reinstall_policy), .section = "effective", .json_path = "install.reinstall_policy" },
        .{ .key = "install.post_install.bundle", .value = install.post_install.bundle orelse "<unset>", .section = "effective", .json_path = "install.post_install.bundle" },
        .{ .key = "capability.family", .value = result.capability.family, .section = "capabilities" },
        .{ .key = "capability.install_adapter", .value = result.capability.install_adapter, .section = "capabilities" },
        .{ .key = "capability.package_manager", .value = result.capability.package_manager, .section = "capabilities" },
        .{ .key = "validation.valid", .value = if (result.validation.valid) "true" else "false", .section = "runtime" },
        .{ .key = "model_revision.config", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{result.model_revision.config}), .section = "runtime" },
        .{ .key = "model_revision.catalog", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{result.model_revision.catalog}), .section = "runtime" },
        .{ .key = "nodes", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{result.nodes.len}), .section = "runtime" },
        .{ .key = "assets", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{result.assets.len}), .section = "runtime" },
        .{ .key = "assets.paths", .value = assets_buf.written(), .section = "assets" },
    };
    const title = try std.fmt.allocPrint(ctx.allocator, "Profile {s}", .{result.name});
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = &fields } }, .json = body.? });
}

fn profileCreateHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const install_source = ctx.getArg("install-source") orelse return;
    if (!nodeforge.config_validate.validLogicalId(install_source)) {
        const output = outputFromContext(ctx) orelse return;
        try cli_output.writeError(errorWriter(ctx), output, "profile.invalid", "profile create: install-source must be a canonical logical identifier");
        setExitCode(ctx, 2);
        return;
    }
    const kind = ctx.flag("kind", []const u8);
    const qualifier_text = ctx.flag("qualifier", []const u8);
    if (qualifier_text.len != 0 and !nodeforge.config_validate.validLogicalId(qualifier_text)) {
        const output = outputFromContext(ctx) orelse return;
        try cli_output.writeError(errorWriter(ctx), output, "profile.invalid_qualifier", "profile create: --qualifier must be a canonical logical identifier");
        setExitCode(ctx, 2);
        return;
    }
    const boot_bundle = ctx.flag("boot-bundle", []const u8);
    if (!std.mem.eql(u8, kind, "install") and !std.mem.eql(u8, kind, "diskless")) {
        const output = outputFromContext(ctx) orelse return;
        try cli_output.writeError(errorWriter(ctx), output, "profile.invalid", "profile create: --kind must be install or diskless");
        setExitCode(ctx, 2);
        return;
    }
    // Profile 名只能由完整 InstallSource、受约束限定符和 kind 生成；
    // CLI 不再接受自由整名，从语法入口消除丢失 ISO 身份或角色后缀的可能。
    const profile_kind = std.meta.stringToEnum(nodeforge.model.ProfileKind, kind).?;
    const name = try nodeforge.profile_naming.profileName(ctx.allocator, install_source, if (qualifier_text.len == 0) null else qualifier_text, profile_kind);
    // diskless 默认引用同 source/qualifier 投影生成的
    // `<source>[-<qualifier>]-diskless-bundle`；仅在需要让多个 Profile
    // 共享另一个规范 Bundle 时才显式传 --boot-bundle。
    const derived_bundle_name = if (profile_kind == .diskless)
        try nodeforge.profile_naming.bootBundleName(ctx.allocator, install_source, if (qualifier_text.len == 0) null else qualifier_text)
    else
        null;
    const bundle_opt: ?[]const u8 = if (std.mem.eql(u8, kind, "diskless"))
        if (boot_bundle.len == 0) derived_bundle_name.? else boot_bundle
    else
        null;
    if (bundle_opt) |bundle_name| if (std.mem.eql(u8, kind, "diskless") and
        !nodeforge.profile_naming.bootBundleIsCanonical(bundle_name, install_source))
    {
        const output = outputFromContext(ctx) orelse return;
        const message = try std.fmt.allocPrint(ctx.allocator, "profile create: boot bundle name must retain the complete install-source prefix and end in -diskless-bundle; default is {s}", .{derived_bundle_name.?});
        try cli_output.writeError(errorWriter(ctx), output, "profile.non_canonical_boot_bundle", message);
        setExitCode(ctx, 2);
        return;
    };
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [256]u8 = undefined;
    const result = nodeforge.management_client.profileCreate(ctx.io, config.value.server.http_port, name, install_source, kind, bundle_opt, &reason);
    if (!result.healthy) {
        try reportMutationFailure(ctx, result, "profile create failed: daemon unreachable");
        return;
    }
    const human = try std.fmt.allocPrint(ctx.allocator, "{s} profile created: {s}", .{ kind, name });
    try renderCommandResult(ctx, human, .{ .profile = name, .mode = kind, .install_source = install_source, .boot_bundle = bundle_opt });
}

fn profileCloneHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const source = ctx.getArg("source") orelse return;
    const target = ctx.getArg("target") orelse return;
    if (!nodeforge.config_validate.validLogicalId(source) or !nodeforge.config_validate.validLogicalId(target)) {
        try writeCommandError(ctx, "profile.clone_invalid", "source and target must be canonical logical identifiers", 2);
        return;
    }
    // v0.2.3 §5.2: [KEY=VALUE...] 与 `profile set` 同范围解析（cli_properties
    // 模块）；集合键须走 values 命令；provenance/revision/ssh_identity 不在
    // PropertySpec 内，天然被拒绝。patch 由 daemon 与 clone 在同一事务提交。
    var mutations: std.ArrayList(nodeforge.scalar_mutation.Mutation) = .empty;
    defer mutations.deinit(ctx.allocator);
    for (ctx.positional_args[2..]) |assignment| {
        const equal = std.mem.indexOfScalar(u8, assignment, '=') orelse return profilePropertyError(ctx, error.InvalidProfileProperty);
        const key = assignment[0..equal];
        const value = assignment[equal + 1 ..];
        if (nodeforge.cli_properties.collection(.profile, key) != null) {
            const message = try std.fmt.allocPrint(ctx.allocator, "use profile add-values/remove-values/replace-values/clear-values {s} {s}", .{ target, key });
            try writeCommandError(ctx, "property.list_operation_required", message, 2);
            return;
        }
        const spec = nodeforge.cli_properties.property(.profile, key) orelse return profilePropertyError(ctx, error.InvalidProfileProperty);
        if (spec.mutability != .mutable) return profilePropertyError(ctx, error.InvalidProfileProperty);
        try mutations.append(ctx.allocator, .{ .key = key, .value = value });
    }
    // v0.2.3 §5.2: --detach 仅与 --build 同用；单独使用是 CLI 输入错误
    // （exit code 2），在连接 daemon 前校验。
    const build = ctx.flag("build", bool);
    const detach = ctx.flag("detach", bool);
    if (detach and !build) {
        try writeCommandError(ctx, "profile.clone_invalid", "--detach requires --build", 2);
        return;
    }
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    // v0.2.3 §5.2: --new-ssh-keys 时 daemon 创建独立 identity 并两阶段发布；
    // --build 时 clone 提交后追加 rootfs build operation；--detach 仅与
    // --build 同用（立即返回 operation id，不 follow）。
    const new_ssh_keys = ctx.flag("new-ssh-keys", bool);
    var reason: [512]u8 = undefined;
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const result = nodeforge.management_client.profileClone(ctx.io, config.value.server.http_port, source, target, new_ssh_keys, build, detach, mutations.items, response, &reason);
    if (!result.healthy) {
        const output = outputFromContext(ctx) orelse return;
        if (result.body.len != 0 and output.mode == .json) {
            // §8.4: JSON 模式输出 daemon 单一文档（clone+build 复合错误含
            // `result.profile_created`/`build_submitted`）；诊断写 stderr。
            try renderOutputDocument(ctx, .{ .human = .{ .text = "" }, .json = result.body });
            try errorWriter(ctx).print("error: {s}\n", .{result.reason});
            setExitCode(ctx, if (!result.reachable) 6 else mapErrorToExitCode(result.http_status, result.error_code));
        } else {
            try reportMutationFailure(ctx, result, "profile clone failed");
        }
        return;
    }
    const human = if (build)
        if (detach)
            try std.fmt.allocPrint(ctx.allocator, "profile cloned: {s} -> {s}; rootfs build submitted (detached)", .{ source, target })
        else
            try std.fmt.allocPrint(ctx.allocator, "profile cloned: {s} -> {s}; rootfs build complete", .{ source, target })
    else
        try std.fmt.allocPrint(ctx.allocator, "profile cloned: {s} -> {s}", .{ source, target });
    try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = result.body });
}

/// 通过本机 management API 删除一个零引用 Profile。所有错误均复用 mutation
/// 信封，因此 `profile.in_use`、revision 冲突和 daemon 不可达具有一致退出码。
fn profileRemoveHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const name = ctx.getArg("name") orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [256]u8 = undefined;
    const result = nodeforge.management_client.profileRemove(ctx.io, config.value.server.http_port, name, &reason);
    if (!result.healthy) {
        try reportMutationFailure(ctx, result, "profile remove failed: daemon unreachable");
        return;
    }
    const human = try std.fmt.allocPrint(ctx.allocator, "profile removed: {s}", .{name});
    try renderCommandResult(ctx, human, .{ .name = name });
}

fn bootBundleCreateHandler(ctx: zli.CommandContext) !void {
    // v0.2 diskless CLI 流程：boot-bundle create
    // 将已注册的 kernel/initrd 资产绑定为一个不可拆分的 boot bundle。
    // 调用 management API POST /api/v1/management/boot-bundles，daemon 校验
    // 资产类型匹配后原子写入 catalog。操作员无需手动编辑 catalog JSON。
    _ = outputFromContext(ctx) orelse return;
    const install_source = ctx.getArg("install-source") orelse return;
    const qualifier_text = ctx.flag("qualifier", []const u8);
    if (!nodeforge.config_validate.validLogicalId(install_source) or
        (qualifier_text.len != 0 and !nodeforge.config_validate.validLogicalId(qualifier_text)))
    {
        try writeCommandError(ctx, "boot_bundle.invalid", "boot-bundle create: install-source and --qualifier must be canonical logical identifiers", 2);
        return;
    }
    const name = try nodeforge.profile_naming.bootBundleName(ctx.allocator, install_source, if (qualifier_text.len == 0) null else qualifier_text);
    const kernel = ctx.flag("kernel", []const u8);
    const initrd = ctx.flag("initrd", []const u8);
    const distro = ctx.flag("distro", []const u8);
    const version = ctx.flag("version", []const u8);
    const arch = ctx.flag("arch", []const u8);
    const kernel_release = ctx.flag("kernel-release", []const u8);
    if (kernel.len == 0 or initrd.len == 0 or distro.len == 0 or version.len == 0 or arch.len == 0 or kernel_release.len == 0) {
        try writeCommandError(ctx, "boot_bundle.invalid", "boot-bundle create: all flags --kernel, --initrd, --distro, --version, --arch, --kernel-release are required", 2);
        return;
    }
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [256]u8 = undefined;
    const result = nodeforge.management_client.bootBundleCreate(ctx.io, config.value.server.http_port, name, distro, version, arch, kernel_release, kernel, initrd, &reason);
    if (!result.healthy) {
        try reportMutationFailure(ctx, result, "boot-bundle create failed: daemon unreachable");
        return;
    }
    const human = try std.fmt.allocPrint(ctx.allocator, "boot bundle created: {s} (kernel={s}, initrd={s})", .{ name, kernel, initrd });
    try renderCommandResult(ctx, human, .{ .name = name, .kernel = kernel, .initrd = initrd });
}

fn bootBundleListHandler(ctx: zli.CommandContext) !void {
    try bootBundleQueryHandler(ctx, null);
}

fn bootBundleShowHandler(ctx: zli.CommandContext) !void {
    try bootBundleQueryHandler(ctx, ctx.getArg("name") orelse return);
}

fn bootBundleQueryHandler(ctx: zli.CommandContext, name: ?[]const u8) !void {
    // management API 返回完整集合；list 直接表格化，show 在相同 revision 内
    // 精确筛选，确保两种视图不会因不同端点产生字段漂移。
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = nodeforge.management_client.bootBundlesJson(ctx.io, config.value.server.http_port, response) catch null orelse {
        try writeCommandError(ctx, "boot_bundle.query_failed", "boot bundle query failed", 1);
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        try writeCommandError(ctx, "boot_bundle.invalid_response", "boot bundle query returned malformed JSON", 1);
        return;
    };
    defer parsed.deinit();
    const result = parsed.value.object.get("result") orelse return error.InvalidManagementResponse;
    const items = result.object.get("items") orelse return error.InvalidManagementResponse;
    if (name) |target_name| {
        for (items.array.items) |item| {
            const object = item.object;
            if (!std.mem.eql(u8, jsonString(object.get("name")), target_name)) continue;
            const keys = [_][]const u8{ "name", "distro", "version", "arch", "kernel_release", "kernel", "runtime_kernel", "initrd" };
            var fields: [keys.len]nodeforge.cli_document.Field = undefined;
            for (keys, 0..) |key, index| fields[index] = .{ .key = key, .value = try jsonDisplay(ctx.allocator, object.get(key)), .section = "stored" };
            const sections = [_]nodeforge.cli_document.Section{.{ .key = "stored", .title = "Stored" }};
            const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .boot_bundle = item } }, .{});
            const title = try std.fmt.allocPrint(ctx.allocator, "BootBundle {s}", .{target_name});
            try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = &fields } }, .json = json });
            return;
        }
        try writeCommandError(ctx, "boot_bundle.not_found", "boot bundle not found", 1);
        return;
    }
    const cells = try ctx.allocator.alloc([7][]const u8, items.array.items.len);
    const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, items.array.items.len);
    const jsonl = try ctx.allocator.alloc([]const u8, items.array.items.len);
    for (items.array.items, 0..) |item, index| {
        const object = item.object;
        cells[index] = .{ jsonString(object.get("name")), jsonString(object.get("distro")), jsonString(object.get("version")), jsonString(object.get("arch")), jsonString(object.get("kernel_release")), jsonString(object.get("kernel")), jsonString(object.get("initrd")) };
        rows[index] = .{ .cells = &cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = item }, .{});
    }
    const columns = [_]nodeforge.cli_table.Column{ .{ .key = "name", .title = "NAME" }, .{ .key = "distro", .title = "DISTRO" }, .{ .key = "version", .title = "VERSION" }, .{ .key = "arch", .title = "ARCH" }, .{ .key = "kernel_release", .title = "KERNEL RELEASE" }, .{ .key = "kernel", .title = "KERNEL" }, .{ .key = "initrd", .title = "INITRD" } };
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "没有 BootBundle。" } }, .json = body, .jsonl = jsonl });
}

fn profileRootfsPlanHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const name = ctx.getArg("name") orelse return;
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = nodeforge.management_client.rootfsPlanJson(ctx.io, config.value.server.http_port, name, response) catch null;
    if (body == null) {
        try writeCommandError(ctx, "rootfs.unavailable", "local daemon management API unavailable", 1);
        return;
    }
    const Resp = struct { ok: bool, result: struct { profile: []const u8, rootfs_input_digest: []const u8, cache_state: []const u8, content_sha512: ?[]const u8 = null, compressed_bytes: ?u64 = null, kernel_release: ?[]const u8 = null, file: ?[]const u8 = null } };
    const parsed = std.json.parseFromSlice(Resp, ctx.allocator, body.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed daemon response ({t})", .{err});
        try writeCommandError(ctx, "rootfs.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const r = parsed.value.result;
    const sections = [_]nodeforge.cli_document.Section{.{ .key = "plan", .title = "Plan" }};
    const fields = [_]nodeforge.cli_document.Field{
        .{ .key = "profile", .value = r.profile, .section = "plan" },
        .{ .key = "rootfs_input_digest", .value = r.rootfs_input_digest, .section = "plan" },
        .{ .key = "cache_state", .value = r.cache_state, .section = "plan" },
    };
    const title = try std.fmt.allocPrint(ctx.allocator, "Rootfs Plan {s}", .{r.profile});
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = &fields } }, .json = body.? });
}

fn profileRootfsBuildHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const name = ctx.getArg("name") orelse return;
    const if_input_digest_raw = ctx.flag("if-input-digest", []const u8);
    const if_input_digest: ?[]const u8 = if (if_input_digest_raw.len == 0) null else if_input_digest_raw;
    // v0.2.3 §3.3: --new-ssh-keys 时 daemon 先轮换 identity/Profile 再构建。
    const new_ssh_keys = ctx.flag("new-ssh-keys", bool);
    if (ctx.flag("detach", bool)) {
        const response = try allocManagementResponse(ctx);
        defer ctx.allocator.free(response);
        var reason: [256]u8 = undefined;
        const body = nodeforge.management_client.rootfsBuildDetachJson(ctx.io, config.value.server.http_port, name, if_input_digest, new_ssh_keys, response, &reason) catch null orelse {
            const detail = std.mem.sliceTo(&reason, 0);
            try writeCommandError(ctx, "rootfs.build_failed", if (detail.len == 0) "rootfs operation submission failed" else detail, 1);
            return;
        };
        const Envelope = struct { ok: bool, result: OperationView };
        const parsed = std.json.parseFromSlice(Envelope, ctx.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
            const human = try std.fmt.allocPrint(ctx.allocator, "rootfs already present for profile {s}", .{name});
            try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = body });
            return;
        };
        defer parsed.deinit();
        const human = try std.fmt.allocPrint(ctx.allocator, "rootfs build submitted: operation {s}", .{parsed.value.result.id});
        try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = body });
        return;
    }
    try errorWriter(ctx).print("Requesting rootfs build for profile {s}...\n", .{name});
    if (if_input_digest) |d| try errorWriter(ctx).print("Anti-drift digest: {s}\n", .{d});
    var reason: [256]u8 = undefined;
    const result = nodeforge.management_client.rootfsBuild(ctx.io, config.value.server.http_port, name, if_input_digest, new_ssh_keys, &reason);
    if (!result.healthy) {
        try reportMutationFailure(ctx, result, "rootfs build failed: daemon unreachable");
        return;
    }
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = nodeforge.management_client.rootfsStatusJson(ctx.io, config.value.server.http_port, name, response) catch null;
    if (body == null) {
        const human = try std.fmt.allocPrint(ctx.allocator, "rootfs built for profile {s}", .{name});
        try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = "{}" });
        return;
    }
    const Resp = struct { ok: bool, result: struct { profile: []const u8, rootfs_input_digest: []const u8, state: []const u8, content_sha512: ?[]const u8 = null, compressed_bytes: ?u64 = null, kernel_release: ?[]const u8 = null, file: ?[]const u8 = null } };
    const parsed = std.json.parseFromSlice(Resp, ctx.allocator, body.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed daemon response ({t})", .{err});
        try writeCommandError(ctx, "rootfs.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const r = parsed.value.result;
    try errorWriter(ctx).print("Rootfs build complete: state={s} file={s}\n", .{ r.state, r.file orelse "-" });
    const sections = [_]nodeforge.cli_document.Section{ .{ .key = "artifact", .title = "Artifact" }, .{ .key = "runtime", .title = "Runtime" } };
    const fields = [_]nodeforge.cli_document.Field{
        .{ .key = "profile", .value = r.profile, .section = "artifact" },
        .{ .key = "rootfs_input_digest", .value = r.rootfs_input_digest, .section = "artifact" },
        .{ .key = "state", .value = r.state, .section = "artifact" },
        .{ .key = "content_sha512", .value = r.content_sha512 orelse "-", .section = "artifact" },
        .{ .key = "compressed_bytes", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{r.compressed_bytes orelse 0}), .section = "artifact" },
        .{ .key = "kernel_release", .value = r.kernel_release orelse "-", .section = "runtime" },
        .{ .key = "file", .value = r.file orelse "-", .section = "runtime" },
    };
    const title = try std.fmt.allocPrint(ctx.allocator, "Rootfs Build {s}", .{r.profile});
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = &fields } }, .json = body.? });
}

fn profileRootfsRegisterHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const name = ctx.getArg("name") orelse return;
    const file_path = ctx.flag("path", []const u8);
    const uncompressed_size_raw = ctx.flag("uncompressed-size", i64);
    if (file_path.len == 0) {
        try writeCommandError(ctx, "rootfs.invalid", "profile rootfs register: --path is required", 2);
        return;
    }
    if (uncompressed_size_raw < 0) {
        try writeCommandError(ctx, "rootfs.invalid", "profile rootfs register: --uncompressed-size cannot be negative", 2);
        return;
    }
    // 0 是 CLI 的“未提供”哨兵，不代表空 rootfs。未知大小只降低内存
    // readiness 的证明强度，不能阻止制品登记或后续部署。
    if (uncompressed_size_raw == 0)
        try errorWriter(ctx).writeAll("WARNING: rootfs uncompressed size is unknown; registration will continue and hard memory-capacity checks will be skipped.\n");
    var reason: [256]u8 = undefined;
    const result = nodeforge.management_client.rootfsRegister(ctx.io, config.value.server.http_port, name, file_path, @intCast(uncompressed_size_raw), &reason);
    if (!result.healthy) {
        try reportMutationFailure(ctx, result, "rootfs register failed: daemon unreachable");
        return;
    }
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = nodeforge.management_client.rootfsStatusJson(ctx.io, config.value.server.http_port, name, response) catch null;
    if (body == null) {
        const human = try std.fmt.allocPrint(ctx.allocator, "rootfs registered for profile {s}", .{name});
        try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = "{}" });
        return;
    }
    const Resp = struct { ok: bool, result: struct { profile: []const u8, rootfs_input_digest: []const u8, state: []const u8, content_sha512: ?[]const u8 = null, compressed_bytes: ?u64 = null, kernel_release: ?[]const u8 = null, file: ?[]const u8 = null } };
    const parsed = std.json.parseFromSlice(Resp, ctx.allocator, body.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed daemon response ({t})", .{err});
        try writeCommandError(ctx, "rootfs.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const r = parsed.value.result;
    const sections = [_]nodeforge.cli_document.Section{ .{ .key = "artifact", .title = "Artifact" }, .{ .key = "runtime", .title = "Runtime" } };
    const fields = [_]nodeforge.cli_document.Field{
        .{ .key = "profile", .value = r.profile, .section = "artifact" },
        .{ .key = "rootfs_input_digest", .value = r.rootfs_input_digest, .section = "artifact" },
        .{ .key = "state", .value = r.state, .section = "artifact" },
        .{ .key = "content_sha512", .value = r.content_sha512 orelse "-", .section = "artifact" },
        .{ .key = "compressed_bytes", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{r.compressed_bytes orelse 0}), .section = "artifact" },
        .{ .key = "kernel_release", .value = r.kernel_release orelse "-", .section = "runtime" },
        .{ .key = "file", .value = r.file orelse "-", .section = "runtime" },
    };
    const title = try std.fmt.allocPrint(ctx.allocator, "Rootfs Register {s}", .{r.profile});
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = &fields } }, .json = body.? });
}

fn profileRootfsStatusHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const name = ctx.getArg("name") orelse return;
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = nodeforge.management_client.rootfsStatusJson(ctx.io, config.value.server.http_port, name, response) catch null;
    if (body == null) {
        try writeCommandError(ctx, "rootfs.unavailable", "local daemon management API unavailable", 1);
        return;
    }
    const Resp = struct { ok: bool, result: struct { profile: []const u8, rootfs_input_digest: []const u8, state: []const u8, content_sha512: ?[]const u8 = null, compressed_bytes: ?u64 = null, uncompressed_bytes: ?u64 = null, kernel_release: ?[]const u8 = null, file: ?[]const u8 = null, created_at: ?i64 = null } };
    const parsed = std.json.parseFromSlice(Resp, ctx.allocator, body.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed daemon response ({t})", .{err});
        try writeCommandError(ctx, "rootfs.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const r = parsed.value.result;
    const uncompressed_text = if (r.uncompressed_bytes) |size|
        try std.fmt.allocPrint(ctx.allocator, "{d}", .{size})
    else
        "unknown";
    const sections = [_]nodeforge.cli_document.Section{ .{ .key = "artifact", .title = "Artifact" }, .{ .key = "runtime", .title = "Runtime" } };
    const fields = [_]nodeforge.cli_document.Field{
        .{ .key = "profile", .value = r.profile, .section = "artifact" },
        .{ .key = "rootfs_input_digest", .value = r.rootfs_input_digest, .section = "artifact" },
        .{ .key = "state", .value = r.state, .section = "artifact" },
        .{ .key = "content_sha512", .value = r.content_sha512 orelse "-", .section = "artifact" },
        .{ .key = "compressed_bytes", .value = try std.fmt.allocPrint(ctx.allocator, "{d}", .{r.compressed_bytes orelse 0}), .section = "artifact" },
        .{ .key = "uncompressed_bytes", .value = uncompressed_text, .section = "artifact" },
        .{ .key = "kernel_release", .value = r.kernel_release orelse "-", .section = "runtime" },
        .{ .key = "file", .value = r.file orelse "-", .section = "runtime" },
    };
    const title = try std.fmt.allocPrint(ctx.allocator, "Rootfs Status {s}", .{r.profile});
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = &fields } }, .json = body.? });
}

fn profileSetHandler(ctx: zli.CommandContext) !void {
    const name = ctx.getArg("name") orelse return;
    const assignment = ctx.getArg("property") orelse return;
    const equal = std.mem.indexOfScalar(u8, assignment, '=') orelse return profilePropertyError(ctx, error.InvalidProfileProperty);
    const key = assignment[0..equal];
    const value = assignment[equal + 1 ..];
    if (nodeforge.cli_properties.collection(.profile, key) != null) {
        const message = try std.fmt.allocPrint(ctx.allocator, "use profile add-values/remove-values/replace-values/clear-values {s} {s}", .{ name, key });
        try writeCommandError(ctx, "property.list_operation_required", message, 2);
        return;
    }
    if (nodeforge.cli_properties.property(.profile, key) == null) return profilePropertyError(ctx, error.InvalidProfileProperty);
    return mutateScalarCli(ctx, "profile", name, key, value);
}

fn profileUnsetHandler(ctx: zli.CommandContext) !void {
    const name = ctx.getArg("name") orelse return;
    const key = ctx.getArg("property") orelse return;
    const spec = nodeforge.cli_properties.property(.profile, key) orelse return profilePropertyError(ctx, error.InvalidProfileProperty);
    if (!spec.optional) return profilePropertyError(ctx, error.RequiredProfileProperty);
    return mutateScalarCli(ctx, "profile", name, key, null);
}

fn mutateScalarCli(ctx: zli.CommandContext, owner: []const u8, identity: []const u8, key: []const u8, value: ?[]const u8) !void {
    return mutateScalarBatchCli(ctx, owner, identity, &.{.{ .key = key, .value = value }}, false);
}

fn mutateScalarBatchCli(ctx: zli.CommandContext, owner: []const u8, identity: []const u8, mutations: []const nodeforge.scalar_mutation.Mutation, force: bool) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [512]u8 = undefined;
    const result = nodeforge.management_client.scalarMutations(ctx.io, config.value.server.http_port, owner, identity, mutations, force, &reason);
    if (!result.healthy) return reportMutationFailure(ctx, result, "scalar mutation failed");
    const human = try std.fmt.allocPrint(ctx.allocator, "updated {d} properties on {s}", .{ mutations.len, identity });
    try renderCommandResult(ctx, human, .{ .owner = owner, .resource = identity, .mutations = mutations });
}

fn profilePropertyError(ctx: zli.CommandContext, err: anyerror) void {
    var message: [256]u8 = undefined;
    const rendered = std.fmt.bufPrint(&message, "profile property: {s}; use a canonical PropertySpec key", .{@errorName(err)}) catch "invalid profile property";
    const output = outputFromContext(ctx) orelse return;
    cli_output.writeError(errorWriter(ctx), output, "profile.invalid_property", rendered) catch {};
    setExitCode(ctx, 2);
}

/// 离线 answer 预览有意使用明显的非密钥占位符。
/// 真实凭据仅通过已认证的 `/install-config/kickstart` 路由下发。
const ResolvedPreviewBundle = struct {
    value: model.ProvisioningBundle,
    urls: []const []u8,
    url_count: usize = 0,
    fn deinit(self: *ResolvedPreviewBundle, allocator: std.mem.Allocator) void {
        for (self.urls[0..self.url_count]) |url| allocator.free(url);
        allocator.free(self.urls);
        allocator.free(self.value.steps);
    }
};

fn resolvePreviewBundle(allocator: std.mem.Allocator, catalog: *const model.Catalog, name: []const u8, server_ip: []const u8, port: u16) !ResolvedPreviewBundle {
    var source: ?*const model.ProvisioningBundle = null;
    for (catalog.provisioning_bundles) |*bundle| if (std.mem.eql(u8, bundle.name, name)) {
        source = bundle;
        break;
    };
    const bundle = source orelse return error.MissingProvisioningBundle;
    const steps = try allocator.alloc(model.ProvisionStep, bundle.steps.len);
    errdefer allocator.free(steps);
    const urls = try allocator.alloc([]u8, bundle.steps.len);
    errdefer allocator.free(urls);
    var initialized: usize = 0;
    errdefer for (urls[0..initialized]) |url| allocator.free(url);
    for (bundle.steps, 0..) |step, index| {
        // v0.3: 接受四类 canonical action。package 不引用 asset，直接传递。
        if (step.action == .package) {
            if (step.packages.len == 0) return error.InvalidProvisioningStep;
            steps[index] = step;
            continue;
        }
        const asset_name = step.content_asset orelse return error.InvalidProvisioningStep;
        const asset = nodeforge.catalog.findAsset(catalog, asset_name) orelse return error.MissingAsset;
        if (asset.sha256 == null) return error.InvalidProvisioningStep;
        const url_path: []const u8 = switch (asset.kind) {
            .managed_file => "managed-files",
            .archive => "archives",
            .script => "scripts",
            else => return error.InvalidProvisioningStep,
        };
        urls[initialized] = try std.fmt.allocPrint(allocator, "http://{s}:{d}/artifacts/{s}/{s}/{d}", .{ server_ip, port, url_path, asset.name, asset.revision });
        steps[index] = step;
        steps[index].content_url = urls[initialized];
        steps[index].content_sha256 = asset.sha256;
        initialized += 1;
    }
    var value = bundle.*;
    value.steps = steps;
    return .{ .value = value, .urls = urls, .url_count = initialized };
}

fn installRenderHandler(ctx: zli.CommandContext) !void {
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var catalog = loadCatalogOrEmpty(ctx.io, ctx.allocator, ctx.flag("catalog", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer catalog.deinit();
    const node_id = ctx.getArg("node_id") orelse return;
    const node = nodeforge.catalog.findNode(catalog.value(), node_id) orelse {
        try errorWriter(ctx).print("error: install: unknown node {s}\n", .{node_id});
        setExitCode(ctx, 1);
        return;
    };
    const profile = nodeforge.catalog.findProfile(catalog.value(), node.profile orelse {
        try errorWriter(ctx).print("error: install: node {s} has no profile\n", .{node_id});
        return;
    }) orelse {
        try errorWriter(ctx).writeAll("error: install: node profile unavailable\n");
        setExitCode(ctx, 1);
        return;
    };
    const source = nodeforge.catalog.findInstallSource(catalog.value(), profile.install_source) orelse {
        try errorWriter(ctx).writeAll("error: install: install source unavailable\n");
        setExitCode(ctx, 1);
        return;
    };
    var effective_plan = nodeforge.profile_effective.compile(ctx.allocator, catalog.value(), node) catch {
        try errorWriter(ctx).writeAll("error: install: effective plan unavailable\n");
        setExitCode(ctx, 1);
        return;
    };
    defer effective_plan.deinit();
    const config_revision = try nodeforge.deployment_control.revisionForConfig(ctx.allocator, &config.value);
    const plan_digest = try nodeforge.profile_install.planDigest(ctx.allocator, node, profile, source);
    const preview_scope = try nodeforge.password_hash.randomSalt(ctx.io);
    std.debug.print("password_hash_scope=preview config_revision={d} plan_digest={d} package_availability=installer-media\n", .{ config_revision, plan_digest });
    // APT 源 URL 解析：与 HTTP installConfig 保持一致的 fallback 逻辑。
    // Ubuntu ISO 导入时始终创建 repository，但手动配置场景可能缺失。
    const distro = nodeforge.catalog.findDistro(catalog.value(), source.distro) orelse {
        try errorWriter(ctx).writeAll("error: install: distro unavailable\n");
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
    var preview_bundle: ?ResolvedPreviewBundle = null;
    defer if (preview_bundle) |*value| value.deinit(ctx.allocator);
    const bundle = if (effective_plan.install.post_install.bundle) |name| blk: {
        preview_bundle = resolvePreviewBundle(ctx.allocator, catalog.value(), name, config.value.server.server_ip, config.value.server.http_port) catch {
            try errorWriter(ctx).writeAll("error: install: provision bundle or managed-file asset unavailable\n");
            setExitCode(ctx, 1);
            return;
        };
        break :blk &preview_bundle.?.value;
    } else null;
    // M4.2：webhook 上报对所有 Ubuntu 版本可用（curtin handler 相同）
    const preview_report_url: []const u8 = if (distro.family == .ubuntu) "<report-url>" else "";
    const answer = if (distro.family == .ubuntu)
        try nodeforge.ubuntu_autoinstall.renderEffective(ctx.allocator, node, effective_plan.install, effective_plan.system, effective_plan.network, effective_plan.software, bootstrap_key, bundle, apt_primary_url, "<facts-url>", event_url, "<log-url>", preview_report_url, "<boot-session>", "<capability>", &preview_scope, effective_plan.kernel_args)
    else blk: {
        const install_root = try std.fmt.allocPrint(ctx.allocator, "http://{s}:{d}/artifacts/repositories/{s}", .{ config.value.server.server_ip, config.value.server.http_port, source.name });
        defer ctx.allocator.free(install_root);
        var repository_urls: std.ArrayList([]const u8) = .empty;
        defer {
            for (repository_urls.items) |url| ctx.allocator.free(url);
            repository_urls.deinit(ctx.allocator);
        }
        for (effective_plan.software.repositories) |repository_name| {
            const repository = nodeforge.catalog.findRepository(catalog.value(), repository_name) orelse return error.MissingRepository;
            const marker = "/artifacts/repositories/";
            const marker_index = std.mem.indexOf(u8, repository.base_url, marker) orelse return error.ExternalEndpointForbidden;
            try repository_urls.append(ctx.allocator, try std.fmt.allocPrint(ctx.allocator, "http://{s}:{d}{s}", .{ config.value.server.server_ip, config.value.server.http_port, repository.base_url[marker_index..] }));
        }
        break :blk try nodeforge.kickstart.renderEffective(ctx.allocator, node, effective_plan.install, effective_plan.system, effective_plan.network, effective_plan.software, bootstrap_key, install_root, repository_urls.items, bundle, "<facts-url>", event_url, "<log-url>", "<boot-session>", "<capability>", &preview_scope, effective_plan.kernel_args);
    };
    defer ctx.allocator.free(answer);
    try ctx.writer.writeAll(answer);
}

fn nodeBootPrepareHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const node_id = ctx.getArg("node_id") orelse return;
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    var reason: [256]u8 = [_]u8{0} ** 256;
    const body = nodeforge.management_client.bootPrepareJson(ctx.io, config.value.server.http_port, node_id, response, &reason) catch null;
    if (body == null) {
        const reason_slice = std.mem.sliceTo(&reason, 0);
        const msg = if (reason_slice.len > 0) reason_slice else "local daemon management API unavailable";
        try writeCommandError(ctx, "diskless.unavailable", msg, 1);
        return;
    }
    const Resp = struct { ok: bool, result: struct { node_id: []const u8, session_id: []const u8, state: []const u8, config_url: []const u8, agent_plan_digest: []const u8, rootfs_input_digest: []const u8 } };
    const parsed = std.json.parseFromSlice(Resp, ctx.allocator, body.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed daemon response ({t})", .{err});
        try writeCommandError(ctx, "diskless.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const r = parsed.value.result;
    const human = try std.fmt.allocPrint(ctx.allocator, "node: {s}\nsession_id: {s}\nstate: {s}\nconfig_url: {s}\nagent_plan_digest: {s}\nrootfs_input_digest: {s}", .{ r.node_id, r.session_id, r.state, r.config_url, r.agent_plan_digest, r.rootfs_input_digest });
    try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = body.? });
}

fn nodeReadinessHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const stage = ctx.flag("stage", []const u8);
    if (!(std.mem.eql(u8, stage, "build") or std.mem.eql(u8, stage, "boot"))) {
        try writeCommandError(ctx, "readiness.invalid_stage", "--stage must be build or boot", 2);
        return;
    }
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const node_id = ctx.getArg("node_id") orelse return;
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    var reason: [256]u8 = [_]u8{0} ** 256;
    const body = nodeforge.management_client.nodeReadinessJson(ctx.io, config.value.server.http_port, node_id, stage, response, &reason) catch null;
    if (body == null) {
        const reason_slice = std.mem.sliceTo(&reason, 0);
        try writeCommandError(ctx, "readiness.not_ready", if (reason_slice.len > 0) reason_slice else "readiness check failed", 4);
        return;
    }
    const Resp = struct {
        ok: bool,
        result: struct {
            node_id: []const u8,
            stage: []const u8,
            ready: bool,
            rootfs_input_digest: []const u8,
            desired_plan_digest: []const u8,
            memory: ?[]const u8 = null,
            memory_bytes: ?u64 = null,
            memory_reported_at: ?i64 = null,
            required_min_memory_bytes: ?u64 = null,
        },
    };
    const parsed = std.json.parseFromSlice(Resp, ctx.allocator, body.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed daemon response ({t})", .{err});
        try writeCommandError(ctx, "readiness.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const result = parsed.value.result;
    const human = if (result.required_min_memory_bytes) |required|
        try std.fmt.allocPrint(ctx.allocator, "node: {s}\nstage: {s}\nready: {s}\nrootfs_input_digest: {s}\ndesired_plan_digest: {s}\nmemory: {s}\nmemory_bytes: {s}\nmemory_reported_at: {s}\nrequired_min_memory_bytes: {d}", .{
            result.node_id,
            result.stage,
            if (result.ready) "true" else "false",
            result.rootfs_input_digest,
            result.desired_plan_digest,
            result.memory orelse "unknown",
            if (result.memory_bytes) |value| try std.fmt.allocPrint(ctx.allocator, "{d}", .{value}) else "-",
            if (result.memory_reported_at) |value| try std.fmt.allocPrint(ctx.allocator, "{d}", .{value}) else "-",
            required,
        })
    else
        try std.fmt.allocPrint(ctx.allocator, "node: {s}\nstage: {s}\nready: {s}\nrootfs_input_digest: {s}\ndesired_plan_digest: {s}", .{ result.node_id, result.stage, if (result.ready) "true" else "false", result.rootfs_input_digest, result.desired_plan_digest });
    try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = body.? });
}

const DisklessSessionView = struct {
    session_id: []const u8,
    node_id: []const u8,
    profile: []const u8,
    phase: []const u8,
    expires_at: i64,
};

fn validDeliverySessionId(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn disklessSessionListHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = nodeforge.management_client.disklessSessionsJson(ctx.io, config.value.server.http_port, null, response) catch null orelse {
        try writeCommandError(ctx, "diskless.session_unavailable", "cannot list delivery sessions", 1);
        return;
    };
    const Envelope = struct { ok: bool, result: struct { items: []const DisklessSessionView } };
    const parsed = std.json.parseFromSlice(Envelope, ctx.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
        try writeCommandError(ctx, "diskless.invalid_response", "daemon returned malformed session data", 1);
        return;
    };
    defer parsed.deinit();
    var human: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer human.deinit();
    if (parsed.value.result.items.len == 0) {
        try human.writer.writeAll("No active diskless delivery sessions.");
    } else {
        try human.writer.writeAll("SESSION                          NODE  PROFILE  PHASE  EXPIRES_AT\n");
        for (parsed.value.result.items) |item|
            try human.writer.print("{s}  {s}  {s}  {s}  {d}\n", .{ item.session_id, item.node_id, item.profile, item.phase, item.expires_at });
    }
    try renderOutputDocument(ctx, .{ .human = .{ .text = std.mem.trimEnd(u8, human.written(), "\n") }, .json = body });
}

fn nodePostprocessShowHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const node_id = ctx.getArg("node_id") orelse return;
    const phase = ctx.flag("phase", []const u8);

    if (std.mem.eql(u8, phase, "install-post")) {
        try nodePostprocessShowInstallPost(ctx, node_id);
        return;
    }

    if (!std.mem.eql(u8, phase, "first-boot")) {
        try writeCommandError(ctx, "postprocess.invalid_phase", "supported phases: first-boot, install-post", 2);
        return;
    }
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = nodeforge.management_client.disklessSessionsJson(ctx.io, config.value.server.http_port, null, response) catch null orelse {
        try writeCommandError(ctx, "postprocess.unavailable", "cannot read diskless postprocess state", 1);
        return;
    };
    const Envelope = struct { ok: bool, result: struct { items: []const DisklessSessionView } };
    const parsed = std.json.parseFromSlice(Envelope, ctx.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
        try writeCommandError(ctx, "postprocess.invalid_response", "daemon returned malformed postprocess state", 1);
        return;
    };
    defer parsed.deinit();
    var selected: ?DisklessSessionView = null;
    for (parsed.value.result.items) |item| {
        if (std.mem.eql(u8, item.node_id, node_id)) selected = item;
    }
    const item = selected orelse {
        try writeCommandError(ctx, "postprocess.not_found", "no retained first-boot session exists for this node", 1);
        return;
    };
    const state = if (std.mem.eql(u8, item.phase, "diskless_running")) "succeeded" else if (std.mem.eql(u8, item.phase, "failed")) "failed" else "pending";
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .node_id = node_id, .phase = "first-boot", .state = state, .session_id = item.session_id, .lifecycle_phase = item.phase } }, .{});
    const human = try std.fmt.allocPrint(ctx.allocator, "Postprocess {s}\nphase: first-boot\nstate: {s}\nsession: {s}\nlifecycle: {s}", .{ node_id, state, item.session_id, item.phase });
    try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = json });
}

/// v0.3: 查询 install-post journal 状态（通过管理 API GET /install-post-journal）。
fn nodePostprocessShowInstallPost(ctx: zli.CommandContext, node_id: []const u8) !void {
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const generation_value = ctx.flag("generation", i64);
    if (generation_value < 0) return writeCommandError(ctx, "postprocess.invalid_generation", "generation must be positive", 2);
    const generation: ?u64 = if (generation_value == 0) null else @intCast(generation_value);
    const body = nodeforge.management_client.installPostJournalJson(ctx.io, config.value.server.http_port, node_id, generation, response) catch null orelse {
        try writeCommandError(ctx, "postprocess.unavailable", "cannot read install-post journal state", 1);
        return;
    };
    const Run = struct { step_id: []const u8 = "", status: []const u8 = "", attempts: u8 = 0, updated_at: i64 = 0 };
    const Envelope = struct { ok: bool, result: struct { node_id: []const u8 = "", run: ?struct {
        install_generation: u64 = 0,
        status: []const u8 = "",
        bundle_revision: u64 = 0,
        created_at: i64 = 0,
        updated_at: i64 = 0,
        steps: []const Run = &.{},
        failure_reason: ?[]const u8 = null,
    } = null } };
    const parsed = std.json.parseFromSlice(Envelope, ctx.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
        try writeCommandError(ctx, "postprocess.invalid_response", "daemon returned malformed install-post journal", 1);
        return;
    };
    defer parsed.deinit();
    const journal_run = parsed.value.result.run orelse {
        const empty_json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .node_id = node_id, .phase = "install-post", .run = @as(?u8, null) } }, .{});
        try renderOutputDocument(ctx, .{ .human = .{ .text = "No install-post history." }, .json = empty_json });
        return;
    };
    const json_out = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .node_id = node_id, .phase = "install-post", .state = journal_run.status, .install_generation = journal_run.install_generation, .steps = journal_run.steps, .failure_reason = journal_run.failure_reason } }, .{});
    var human: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer human.deinit();
    try human.writer.print("Postprocess {s}\nphase: install-post\nstate: {s}\ngeneration: {d}", .{ node_id, journal_run.status, journal_run.install_generation });
    if (journal_run.failure_reason) |reason| try human.writer.print("\nfailure: {s}", .{reason});
    if (journal_run.steps.len > 0) {
        try human.writer.writeAll("\nsteps:");
        for (journal_run.steps) |step| try human.writer.print("\n  {s}: {s} (attempts={d})", .{ step.step_id, step.status, step.attempts });
    }
    try renderOutputDocument(ctx, .{ .human = .{ .text = human.written() }, .json = json_out });
}

fn disklessSessionShowHandler(ctx: zli.CommandContext) !void {
    try disklessSessionOne(ctx, false);
}

fn disklessSessionCancelHandler(ctx: zli.CommandContext) !void {
    try disklessSessionOne(ctx, true);
}

fn disklessSessionOne(ctx: zli.CommandContext, cancel: bool) !void {
    _ = outputFromContext(ctx) orelse return;
    const session_id = ctx.getArg("session_id") orelse return;
    if (!validDeliverySessionId(session_id)) {
        try writeCommandError(ctx, "diskless.invalid_session", "session id must be 32 hexadecimal characters", 2);
        return;
    }
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    var reason: [256]u8 = [_]u8{0} ** 256;
    const body = if (cancel)
        nodeforge.management_client.cancelDisklessSession(ctx.io, config.value.server.http_port, session_id, response, &reason) catch null
    else
        nodeforge.management_client.disklessSessionsJson(ctx.io, config.value.server.http_port, session_id, response) catch null;
    if (body == null) {
        const detail = std.mem.sliceTo(&reason, 0);
        try writeCommandError(ctx, "diskless.session_unavailable", if (detail.len > 0) detail else "delivery session not found or daemon unavailable", 1);
        return;
    }
    if (cancel) {
        const human = try std.fmt.allocPrint(ctx.allocator, "diskless delivery session cancelled: {s}", .{session_id});
        try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = body.? });
        return;
    }
    const Envelope = struct { ok: bool, result: DisklessSessionView };
    const parsed = std.json.parseFromSlice(Envelope, ctx.allocator, body.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
        try writeCommandError(ctx, "diskless.invalid_response", "daemon returned malformed session data", 1);
        return;
    };
    defer parsed.deinit();
    const item = parsed.value.result;
    const human = try std.fmt.allocPrint(ctx.allocator, "session_id: {s}\nnode: {s}\nprofile: {s}\nphase: {s}\nexpires_at: {d}", .{ item.session_id, item.node_id, item.profile, item.phase, item.expires_at });
    try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = body.? });
}

fn nodeBootPreviewHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const node_id = ctx.getArg("node_id") orelse return;
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    var reason: [256]u8 = undefined;
    const body = nodeforge.management_client.nodeBootPreviewJson(ctx.io, config.value.server.http_port, node_id, response, &reason) catch null orelse {
        const detail = std.mem.sliceTo(&reason, 0);
        try writeCommandError(ctx, "preview.unavailable", if (detail.len == 0) "boot preview is unavailable" else detail, 1);
        return;
    };
    const Envelope = struct { ok: bool, result: struct {
        node: []const u8,
        profile: []const u8,
        kind: []const u8,
        deploy: bool,
        would_boot: bool,
        rootfs_state: ?[]const u8 = null,
        boot_bundle: ?[]const u8 = null,
        kernel: ?[]const u8 = null,
        initrd: ?[]const u8 = null,
    } };
    const parsed = std.json.parseFromSlice(Envelope, ctx.allocator, body, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
        try writeCommandError(ctx, "preview.invalid_response", "daemon returned a malformed boot preview", 1);
        return;
    };
    defer parsed.deinit();
    const r = parsed.value.result;
    const human = try std.fmt.allocPrint(ctx.allocator, "Boot Preview: {s}\nprofile: {s}\nkind: {s}\ndeploy: {s}\nwould_boot: {s}\nboot_bundle: {s}\nkernel: {s}\ninitrd: {s}\nrootfs: {s}", .{
        r.node, r.profile, r.kind, if (r.deploy) "true" else "false", if (r.would_boot) "yes" else "no", r.boot_bundle orelse "<install>", r.kernel orelse "<installer>", r.initrd orelse "<installer>", r.rootfs_state orelse "<not-applicable>",
    });
    try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = body });
}

fn installRetryHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const node_id = ctx.getArg("node_id") orelse return;
    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    var reason: [256]u8 = undefined;
    const body = nodeforge.management_client.nodeRetryJson(ctx.io, config.value.server.http_port, node_id, ctx.flag("force", bool), response, &reason) catch null orelse {
        const detail = std.mem.sliceTo(&reason, 0);
        try writeCommandError(ctx, "retry.failed", if (detail.len == 0) "node retry failed" else detail, 1);
        return;
    };
    const human = try std.fmt.allocPrint(ctx.allocator, "deployment retry accepted for {s}; waiting for next PXE", .{node_id});
    try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = body });
}

/// `node deploy` 的 enabled 位置参数：缺省时默认 "true"（deploy 动词语义），
/// 非法字面量返回 null 由调用方报 exit code 2。显式 "true"/"false" 必须原样透传。
fn resolveDeployEnabled(raw: ?[]const u8) ?[]const u8 {
    const value = raw orelse return "true";
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return value;
    return null;
}

test "node deploy enabled defaults to true and passes explicit values through" {
    try std.testing.expectEqualStrings("true", resolveDeployEnabled(null).?);
    try std.testing.expectEqualStrings("true", resolveDeployEnabled("true").?);
    try std.testing.expectEqualStrings("false", resolveDeployEnabled("false").?);
    try std.testing.expect(resolveDeployEnabled("yes") == null);
    try std.testing.expect(resolveDeployEnabled("TRUE") == null);
    try std.testing.expect(resolveDeployEnabled("") == null);
}

fn nodeDeployHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const node_id = ctx.getArg("node_id") orelse return;
    const enabled = resolveDeployEnabled(ctx.getArg("enabled")) orelse {
        try writeCommandError(ctx, "deploy.invalid_value", "deploy value must be true or false", 2);
        return;
    };
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    var reason: [256]u8 = undefined;
    const result = nodeforge.management_client.scalarMutations(ctx.io, config.value.server.http_port, "node", node_id, &.{.{ .key = "deploy", .value = enabled }}, ctx.flag("force", bool), &reason);
    if (!result.healthy) return reportMutationFailure(ctx, result, "deploy update failed");
    const human = try std.fmt.allocPrint(ctx.allocator, "deploy set to {s} for {s}", .{ enabled, node_id });
    try renderCommandResult(ctx, human, .{ .node_id = node_id, .deploy = std.mem.eql(u8, enabled, "true") });
}

// ── M4.2 节点 CRUD 处理器 ───────────────────────────────────────

/// v0.2.3 §8.3：把 API error.code 与 HTTP status 映射为冻结 exit class。
/// error.code 精确匹配优先（handler 不得把同一 code 映射到不同 exit class）；
/// 未知 code 按 HTTP status 回退；成功响应（2xx）返回 0。
fn mapErrorToExitCode(http_status: u16, error_code: []const u8) u8 {
    // —— CLI 输入错误（exit 2）——
    if (std.mem.eql(u8, error_code, "profile.invalid") or
        std.mem.eql(u8, error_code, "profile.boot_bundle_required") or
        std.mem.eql(u8, error_code, "profile.clone_invalid") or
        std.mem.eql(u8, error_code, "rootfs.invalid")) return 2;
    // —— revision/idempotency 并发冲突（exit 3）——
    if (std.mem.eql(u8, error_code, "profile.already_exists") or
        std.mem.eql(u8, error_code, "install_source.busy") or
        std.mem.eql(u8, error_code, "install_source.name_conflict") or
        std.mem.eql(u8, error_code, "catalog.revision_conflict") or
        std.mem.eql(u8, error_code, "http.precondition_required")) return 3;
    // —— readiness / 前置条件不满足（exit 4）——
    if (std.mem.eql(u8, error_code, "profile.in_use") or
        std.mem.eql(u8, error_code, "profile.not_diskless") or
        std.mem.eql(u8, error_code, "profile.install_source_not_found") or
        std.mem.eql(u8, error_code, "rootfs.digest_drift")) return 4;
    // —— durable operation 终态失败（exit 5）——
    if (std.mem.eql(u8, error_code, "rootfs.build_failed") or
        std.mem.eql(u8, error_code, "rootfs.build_submit_failed") or
        std.mem.eql(u8, error_code, "operation.interrupted")) return 5;
    // —— HTTP status 回退（§8.3 表）——
    if (http_status >= 200 and http_status < 300) return 0;
    switch (http_status) {
        404, 422 => return 4,
        409, 428 => return 3,
        else => return 1,
    }
}

/// M4.5：把管理写请求的失败结果映射为 CLI 结构化错误。`result.reason` 非空时
/// 直接输出服务端错误信封（code/message/request_id），否则（连接失败）输出
/// `fallback`。退出码按 v0.2.3 §8.1/§8.3 映射：连接失败归为 6，业务错误按
/// error.code/HTTP status 映射，不再一律 exit 1。
fn reportMutationFailure(ctx: zli.CommandContext, result: nodeforge.management_client.Mutation, fallback: []const u8) !void {
    const output = outputFromContext(ctx) orelse return;
    try cli_output.writeError(errorWriter(ctx), output, "mutation.failed", if (result.reason.len > 0) result.reason else fallback);
    setExitCode(ctx, if (!result.reachable) 6 else mapErrorToExitCode(result.http_status, result.error_code));
}

test "v0.2.3: mapErrorToExitCode follows §8.3 frozen exit classes" {
    // 成功与 daemon 内部错误。
    try std.testing.expectEqual(@as(u8, 0), mapErrorToExitCode(200, ""));
    try std.testing.expectEqual(@as(u8, 0), mapErrorToExitCode(201, ""));
    try std.testing.expectEqual(@as(u8, 1), mapErrorToExitCode(500, ""));
    try std.testing.expectEqual(@as(u8, 1), mapErrorToExitCode(503, ""));
    // CLI 输入错误（error.code 精确映射，与 HTTP status 无关）。
    try std.testing.expectEqual(@as(u8, 2), mapErrorToExitCode(400, "profile.invalid"));
    try std.testing.expectEqual(@as(u8, 2), mapErrorToExitCode(400, "profile.boot_bundle_required"));
    try std.testing.expectEqual(@as(u8, 2), mapErrorToExitCode(400, "profile.clone_invalid"));
    try std.testing.expectEqual(@as(u8, 2), mapErrorToExitCode(400, "rootfs.invalid"));
    // revision/idempotency 并发冲突。
    try std.testing.expectEqual(@as(u8, 3), mapErrorToExitCode(409, "catalog.revision_conflict"));
    try std.testing.expectEqual(@as(u8, 3), mapErrorToExitCode(409, "profile.already_exists"));
    try std.testing.expectEqual(@as(u8, 3), mapErrorToExitCode(409, "install_source.busy"));
    try std.testing.expectEqual(@as(u8, 3), mapErrorToExitCode(409, "install_source.name_conflict"));
    try std.testing.expectEqual(@as(u8, 3), mapErrorToExitCode(428, "http.precondition_required"));
    // readiness / 前置条件不满足。
    try std.testing.expectEqual(@as(u8, 4), mapErrorToExitCode(400, "profile.not_diskless"));
    try std.testing.expectEqual(@as(u8, 4), mapErrorToExitCode(400, "profile.in_use"));
    try std.testing.expectEqual(@as(u8, 4), mapErrorToExitCode(404, "profile.install_source_not_found"));
    try std.testing.expectEqual(@as(u8, 4), mapErrorToExitCode(409, "rootfs.digest_drift"));
    // durable operation 终态失败。
    try std.testing.expectEqual(@as(u8, 5), mapErrorToExitCode(500, "rootfs.build_failed"));
    try std.testing.expectEqual(@as(u8, 5), mapErrorToExitCode(500, "rootfs.build_submit_failed"));
    try std.testing.expectEqual(@as(u8, 5), mapErrorToExitCode(500, "operation.interrupted"));
    // 未知 code 时按 HTTP status 回退（§8.3 表）。
    try std.testing.expectEqual(@as(u8, 4), mapErrorToExitCode(404, ""));
    try std.testing.expectEqual(@as(u8, 4), mapErrorToExitCode(422, ""));
    try std.testing.expectEqual(@as(u8, 3), mapErrorToExitCode(409, ""));
    try std.testing.expectEqual(@as(u8, 3), mapErrorToExitCode(428, ""));
    try std.testing.expectEqual(@as(u8, 1), mapErrorToExitCode(400, ""));
}

fn nodeAddHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const config_path = ctx.flag("config", []const u8);
    const node_id = ctx.getArg("node_id") orelse return;
    const parsed_node = parseNodeProperties(node_id, ctx.positional_args[1..]) catch |err| return nodePropertyError(ctx, err);
    const node_value = parsed_node.node;
    if (!parsed_node.mac_set or !parsed_node.arch_set or !parsed_node.pxe_ip_reservation_set) return nodePropertyError(ctx, error.MissingRequiredAttribute);
    if (node_value.profile == null and node_value.deploy) return nodePropertyError(ctx, error.ProfileRequiredWhileDeployed);

    var config = loadConfig(ctx.io, ctx.allocator, config_path, errorWriter(ctx), ctx.flag("debug", bool)) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    // hostname 未显式指定时默认使用 node_id，使 kickstart/answer 渲染无需特殊回退逻辑。
    var request_node = node_value;
    if (request_node.hostname == null) request_node.hostname = node_id;
    // 只序列化管理 API 的 canonical schema-v3 Node DTO。profile 可为 null，
    // 未认领节点 (`deploy=false`) 必须显式发送 `"profile":null`。
    const body = try serializeNodeAddRequest(ctx.allocator, request_node);
    defer ctx.allocator.free(body);
    var reason: [256]u8 = undefined;
    const node_result = nodeforge.management_client.nodeAdd(ctx.io, config.value.server.http_port, body, &reason);
    if (!node_result.healthy) {
        try reportMutationFailure(ctx, node_result, "node add failed: daemon unreachable");
        return;
    }
    const human = try std.fmt.allocPrint(ctx.allocator, "node added: {s}", .{node_id});
    try renderCommandResult(ctx, human, .{ .node_id = node_id, .mac = node_value.mac, .profile = node_value.profile });
}

fn serializeNodeAddRequest(allocator: std.mem.Allocator, node: model.NodeConfig) ![]u8 {
    return nodeforge.catalog_dto.renderNode(allocator, node);
}

fn nodeSetHandler(ctx: zli.CommandContext) !void {
    const node_id = ctx.getArg("node_id") orelse return;
    var mutations: std.ArrayList(nodeforge.scalar_mutation.Mutation) = .empty;
    defer mutations.deinit(ctx.allocator);
    for (ctx.positional_args[1..]) |assignment| {
        const equal = std.mem.indexOfScalar(u8, assignment, '=') orelse return nodePropertyError(ctx, error.InvalidAttribute);
        const key = assignment[0..equal];
        const value = assignment[equal + 1 ..];
        if (nodeforge.cli_properties.collection(.node, key) != null) {
            const message = try std.fmt.allocPrint(ctx.allocator, "use node add-values/remove-values/replace-values/clear-values {s} {s}", .{ node_id, key });
            try writeCommandError(ctx, "property.list_operation_required", message, 2);
            return;
        }
        if (nodeforge.cli_properties.property(.node, key) == null) return nodePropertyError(ctx, error.UnknownAttribute);
        try mutations.append(ctx.allocator, .{ .key = key, .value = value });
    }
    try mutateScalarBatchCli(ctx, "node", node_id, mutations.items, ctx.flag("force", bool));
}

fn nodeUnsetHandler(ctx: zli.CommandContext) !void {
    const node_id = ctx.getArg("node_id") orelse return;
    var mutations: std.ArrayList(nodeforge.scalar_mutation.Mutation) = .empty;
    defer mutations.deinit(ctx.allocator);
    for (ctx.positional_args[1..]) |key| {
        const spec = nodeforge.cli_properties.property(.node, key) orelse return nodePropertyError(ctx, error.UnknownAttribute);
        if (!spec.optional) return nodePropertyError(ctx, error.AttributeNotOptional);
        try mutations.append(ctx.allocator, .{ .key = key });
    }
    try mutateScalarBatchCli(ctx, "node", node_id, mutations.items, ctx.flag("force", bool));
}

const ParsedNodeProperties = struct { node: model.NodeConfig, mac_set: bool = false, arch_set: bool = false, pxe_ip_reservation_set: bool = false };
fn parseNodeProperties(node_id: []const u8, values: []const []const u8) !ParsedNodeProperties {
    var result: ParsedNodeProperties = .{ .node = .{ .id = node_id, .mac = "", .arch = .x86_64 } };
    var seen: std.StringHashMap(void) = .init(std.heap.page_allocator);
    defer seen.deinit();
    for (values) |item| {
        const equal = std.mem.indexOfScalar(u8, item, '=') orelse return error.InvalidAttribute;
        const key = item[0..equal];
        const value = item[equal + 1 ..];
        if (key.len == 0 or value.len == 0) return error.InvalidAttribute;
        if (seen.contains(key)) return error.DuplicateAttribute;
        try seen.put(key, {});
        const spec = nodeforge.cli_properties.property(.node, key) orelse {
            if (nodeforge.cli_properties.collection(.node, key) != null) return error.CollectionRequiresValuesCommand;
            return error.UnknownAttribute;
        };
        if (spec.mutability != .mutable) return error.UnknownAttribute;
        nodeforge.scalar_mutation.applyNode(&result.node, key, value) catch return error.InvalidAttribute;
        if (std.mem.eql(u8, key, "mac")) result.mac_set = true;
        if (std.mem.eql(u8, key, "arch")) result.arch_set = true;
        if (std.mem.eql(u8, key, "pxe.ip_reservation")) result.pxe_ip_reservation_set = true;
    }
    return result;
}

test "node add keeps nullable profile and registered optional scalars in request" {
    const parsed = try parseNodeProperties("unclaimed", &.{
        "mac=02:4e:46:00:00:01",
        "arch=aarch64",
        "deploy=false",
        "pxe.ip_reservation=192.168.27.190",
        "network.mode=static",
        "network.match_mac=02:4e:46:00:00:01",
        "network.address=192.168.27.190",
        "network.prefix_len=24",
        "overrides.system.localization.timezone=Asia/Shanghai",
    });
    const body = try serializeNodeAddRequest(std.testing.allocator, parsed.node);
    defer std.testing.allocator.free(body);
    const Request = struct { profile: ?[]const u8, deploy: bool, network: model.TargetNetworkConfig, pxe: model.PxeConfig, overrides: model.NodeOverrideConfig };
    const request = try std.json.parseFromSlice(Request, std.testing.allocator, body, .{ .ignore_unknown_fields = true });
    defer request.deinit();
    try std.testing.expect(request.value.profile == null);
    try std.testing.expect(!request.value.deploy);
    try std.testing.expect(parsed.pxe_ip_reservation_set);
    try std.testing.expectEqualStrings("192.168.27.190", request.value.pxe.ip_reservation.?);
    try std.testing.expectEqualStrings("192.168.27.190", request.value.network.address.?);
    try std.testing.expectEqualStrings("Asia/Shanghai", request.value.overrides.system.localization.timezone.?);
}

test "node add parser tracks required PXE reservation" {
    const missing = try parseNodeProperties("missing-ip", &.{ "mac=02:4e:46:00:00:02", "arch=aarch64", "deploy=false" });
    try std.testing.expect(!missing.pxe_ip_reservation_set);
}
fn nodePropertyError(ctx: zli.CommandContext, err: anyerror) void {
    var message: [128]u8 = undefined;
    const rendered = std.fmt.bufPrint(&message, "node attributes: {s}", .{@errorName(err)}) catch "invalid node property";
    const output = outputFromContext(ctx) orelse return;
    cli_output.writeError(errorWriter(ctx), output, "node.invalid_property", rendered) catch {};
    setExitCode(ctx, 2);
}

fn nodeRemoveHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const config_path = ctx.flag("config", []const u8);
    const node_id = ctx.getArg("node_id") orelse return;

    var config = loadConfig(ctx.io, ctx.allocator, config_path, errorWriter(ctx), ctx.flag("debug", bool)) orelse {
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
    const human = try std.fmt.allocPrint(ctx.allocator, "node removed: {s}", .{node_id});
    try renderCommandResult(ctx, human, .{ .node_id = node_id });
}

fn nodeShowHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const debug = ctx.flag("debug", bool);
    var config = loadConfig(ctx.io, ctx.allocator, ctx.flag("config", []const u8), errorWriter(ctx), debug) orelse {
        setExitCode(ctx, 1);
        return;
    };
    defer config.deinit();
    const node_id = ctx.getArg("node_id") orelse return;

    const response = try allocManagementResponse(ctx);
    defer ctx.allocator.free(response);
    const body = try nodeforge.management_client.nodesJson(ctx.io, config.value.server.http_port, node_id, response);
    if (body == null) {
        const message = try std.fmt.allocPrint(ctx.allocator, "node not found or daemon unavailable: {s}", .{node_id});
        try writeCommandError(ctx, "node.unavailable", message, 1);
        return;
    }
    const Response = struct {
        result: struct {
            view_revision: struct { config: u64, catalog: u64, node_status: u64, deployment: u64, inventory: u64 },
            node: nodeforge.catalog_dto.Node,
            profile: struct { name: []const u8, kind: []const u8, boot_bundle: ?[]const u8, install_source: []const u8, kernel_args: ?[]const u8, platform: struct { distro: []const u8, version: []const u8, arch: []const u8 } },
            effective_system: struct {
                localization: model.LocalizationConfig,
                connectivity: model.ConnectivityPolicy,
                ssh: struct { enabled: bool, password_authentication: bool, root_login: []const u8, root_password: ?[]const u8, root_authorized_keys: []const []const u8 },
                security: model.TargetSecurityConfig,
                users: []const model.TargetUserConfig,
                packages: []const []const u8,
            },
            storage: ?struct { direct: model.NodeStorageConfig, override: model.NullableStorageOverride, effective: model.StorageConfig },
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
                desired_plan_digest: ?[]const u8,
                drifted: bool,
                drift_state: []const u8,
                requested_by: ?[]const u8,
                armed_at: i64,
                install_at: i64,
                finished_at: i64,
                successful_generation: u64,
                deployed_at: i64,
            },
            inventory: ?struct { serial_number: ?[]const u8, product_uuid: ?[]const u8, vendor: ?[]const u8, model: ?[]const u8, memory_bytes: ?u64 = null, reported_at: i64, deployment_generation: u64 = 0, session_created_at: i64, boot_session_id: []const u8 },
        },
    };
    var parsed = std.json.parseFromSlice(Response, ctx.allocator, body.?, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "malformed daemon response ({t})", .{err});
        try writeCommandError(ctx, "node.invalid_response", message, 1);
        return;
    };
    defer parsed.deinit();
    const result = parsed.value.result;
    const stored_node = result.node.modelValue();
    const sections = [_]nodeforge.cli_document.Section{ .{ .key = "runtime", .title = "Runtime" }, .{ .key = "stored", .title = "Stored" }, .{ .key = "overrides", .title = "Overrides" }, .{ .key = "effective", .title = "Effective" } };
    const storage = if (result.storage) |value| value.effective else model.StorageConfig{};
    const status_phase = if (result.status) |status| status.phase else "-";
    const status_reason = if (result.status) |status| if (status.reason.len == 0) "-" else status.reason else "-";
    const install_intent = if (result.deployment) |deployment| deployment.install_intent else "-";
    const drift_state = if (result.deployment) |deployment| deployment.drift_state else "-";
    const inventory_serial = if (result.inventory) |inventory| inventory.serial_number orelse "-" else "-";
    const inventory_memory = if (result.inventory) |inventory| if (inventory.memory_bytes) |bytes| try std.fmt.allocPrint(ctx.allocator, "{d}", .{bytes}) else "-" else "-";
    const additional_disks = if (stored_node.storage.additional_disks.len == 0) "<none>" else try std.mem.join(ctx.allocator, ", ", stored_node.storage.additional_disks);
    const network_dns = if (stored_node.network.dns.len == 0) "<none>" else try std.mem.join(ctx.allocator, ", ", stored_node.network.dns);
    const search_domains = if (stored_node.network.search_domains.len == 0) "<none>" else try std.mem.join(ctx.allocator, ", ", stored_node.network.search_domains);
    const network_routes = if (stored_node.network.routes.len == 0) "<none>" else try formatRoutes(ctx.allocator, stored_node.network.routes);
    const fields = [_]nodeforge.cli_document.Field{
        .{ .key = "id", .value = stored_node.id, .section = "stored", .json_path = "node.id" },                                                                                                                                                     .{ .key = "mac", .value = stored_node.mac, .section = "stored", .json_path = "node.mac" },                                                                                                                                                                    .{ .key = "arch", .value = @tagName(stored_node.arch), .section = "stored", .json_path = "node.arch" },                                                                                                                    .{ .key = "profile", .value = stored_node.profile orelse "<unset>", .section = "stored", .json_path = "node.profile" },
        .{ .key = "pxe.ip_reservation", .value = stored_node.pxe.ip_reservation orelse "<unset>", .section = "stored", .json_path = "node.pxe.ip_reservation" },                                                                                    .{ .key = "hostname", .value = stored_node.hostname orelse "<unset>", .section = "stored", .json_path = "node.hostname" },                                                                                                                                    .{ .key = "deploy", .value = if (stored_node.deploy) "true" else "false", .section = "stored", .json_path = "node.deploy" },                                                                                               .{ .key = "http_accel", .value = if (stored_node.http_accel) "true" else "false", .section = "stored", .json_path = "node.http_accel" },
        .{ .key = "storage.boot_disk", .value = stored_node.storage.boot_disk, .section = "stored", .json_path = "node.storage.boot_disk" },                                                                                                        .{ .key = "storage.additional_disks", .value = additional_disks, .section = "stored", .json_path = "node.storage.additional_disks" },                                                                                                                         .{ .key = "network.mode", .value = @tagName(stored_node.network.mode), .section = "stored", .json_path = "node.network.mode" },                                                                                            .{ .key = "network.interface_name", .value = stored_node.network.interface orelse "<auto>", .section = "stored", .json_path = "node.network.interface_name" },
        .{ .key = "network.match_mac", .value = stored_node.network.match_mac orelse "<node mac>", .section = "stored", .json_path = "node.network.match_mac" },                                                                                    .{ .key = "network.address", .value = stored_node.network.address orelse "<unset>", .section = "stored", .json_path = "node.network.address" },                                                                                                               .{ .key = "network.prefix_len", .value = if (stored_node.network.prefix_len) |value| try std.fmt.allocPrint(ctx.allocator, "{d}", .{value}) else "<unset>", .section = "stored", .json_path = "node.network.prefix_len" }, .{ .key = "network.gateway", .value = stored_node.network.gateway orelse "<unset>", .section = "stored", .json_path = "node.network.gateway" },
        .{ .key = "network.dns", .value = network_dns, .section = "stored", .json_path = "node.network.dns" },                                                                                                                                      .{ .key = "network.search_domains", .value = search_domains, .section = "stored", .json_path = "node.network.search_domains" },                                                                                                                               .{ .key = "network.routes", .value = network_routes, .section = "stored", .json_path = "node.network.routes" },                                                                                                            .{ .key = "overrides.install.storage.mode", .value = if (stored_node.overrides.install.storage.mode) |value| @tagName(value) else "<inherit>", .section = "overrides", .json_path = "node.overrides.install.storage.mode" },
        .{ .key = "overrides.install.storage.wipe", .value = if (stored_node.overrides.install.storage.wipe) |value| if (value) "true" else "false" else "<inherit>", .section = "overrides", .json_path = "node.overrides.install.storage.wipe" }, .{ .key = "overrides.install.storage.partition_table", .value = if (stored_node.overrides.install.storage.partition_table) |value| @tagName(value) else "<inherit>", .section = "overrides", .json_path = "node.overrides.install.storage.partition_table" }, .{ .key = "overrides.system.localization.locale", .value = stored_node.overrides.system.localization.locale orelse "<inherit>", .section = "overrides", .json_path = "node.overrides.system.localization.locale" },        .{ .key = "overrides.system.localization.timezone", .value = stored_node.overrides.system.localization.timezone orelse "<inherit>", .section = "overrides", .json_path = "node.overrides.system.localization.timezone" },
        .{ .key = "overrides.system.localization.keyboard", .value = stored_node.overrides.system.localization.keyboard orelse "<inherit>", .section = "overrides", .json_path = "node.overrides.system.localization.keyboard" },                   .{ .key = "effective.install.storage.mode", .value = @tagName(storage.mode), .section = "effective", .json_path = "storage.effective.mode" },                                                                                                                 .{ .key = "effective.install.storage.wipe", .value = if (storage.wipe) "true" else "false", .section = "effective", .json_path = "storage.effective.wipe" },                                                               .{ .key = "effective.install.storage.partition_table", .value = @tagName(storage.partition_table), .section = "effective", .json_path = "storage.effective.partition_table" },
        .{ .key = "effective.install.storage.boot_disk", .value = storage.boot_disk, .section = "effective", .json_path = "storage.effective.boot_disk" },                                                                                          .{ .key = "effective.system.localization.locale", .value = result.effective_system.localization.locale, .section = "effective", .json_path = "effective_system.localization.locale" },                                                                        .{ .key = "effective.system.localization.timezone", .value = result.effective_system.localization.timezone, .section = "effective", .json_path = "effective_system.localization.timezone" },                               .{ .key = "effective.system.localization.keyboard", .value = result.effective_system.localization.keyboard, .section = "effective", .json_path = "effective_system.localization.keyboard" },
        .{ .key = "effective.system.ssh.enabled", .value = if (result.effective_system.ssh.enabled) "true" else "false", .section = "effective", .json_path = "effective_system.ssh.enabled" },                                                     .{ .key = "effective.system.security.firewall", .value = @tagName(result.effective_system.security.firewall), .section = "effective", .json_path = "effective_system.security.firewall" },                                                                    .{ .key = "effective.system.security.selinux", .value = @tagName(result.effective_system.security.selinux), .section = "effective", .json_path = "effective_system.security.selinux" },                                    .{ .key = "effective.system.security.apparmor", .value = @tagName(result.effective_system.security.apparmor), .section = "effective", .json_path = "effective_system.security.apparmor" },
        .{ .key = "runtime.phase", .value = status_phase, .section = "runtime", .json_path = "status.phase" },                                                                                                                                      .{ .key = "runtime.reason", .value = status_reason, .section = "runtime", .json_path = "status.reason" },                                                                                                                                                     .{ .key = "runtime.install_intent", .value = install_intent, .section = "runtime", .json_path = "deployment.install_intent" },                                                                                             .{ .key = "runtime.drift_state", .value = drift_state, .section = "runtime", .json_path = "deployment.drift_state" },
        .{ .key = "runtime.serial_number", .value = inventory_serial, .section = "runtime", .json_path = "inventory.serial_number" },                                                                                                               .{ .key = "runtime.memory_bytes", .value = inventory_memory, .section = "runtime", .json_path = "inventory.memory_bytes" },                                                                                                                                   .{ .key = "runtime.profile_kind", .value = result.profile.kind, .section = "runtime", .json_path = "profile.kind" },                                                                                                       .{ .key = "runtime.boot_bundle", .value = result.profile.boot_bundle orelse "-", .section = "runtime", .json_path = "profile.boot_bundle" },
    };
    const title = try std.fmt.allocPrint(ctx.allocator, "Node {s}", .{stored_node.id});
    try renderOutputDocument(ctx, .{ .human = .{ .detail = .{ .title = title, .sections = &sections, .fields = &fields } }, .json = body.? });
}

fn formatRoutes(allocator: std.mem.Allocator, routes: []const model.RouteConfig) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    for (routes, 0..) |route, index| {
        if (index != 0) try output.writer.writeByte('\n');
        try output.writer.print("{s}: {s} via {s}", .{ route.id, route.destination, route.gateway });
        if (route.metric) |metric| try output.writer.print(" metric {d}", .{metric});
    }
    return output.toOwnedSlice();
}

fn findBundle(config: *const nodeforge.model.AppConfig, name: []const u8) ?*const nodeforge.model.ProvisioningBundle {
    for (config.provisioning_bundles) |*bundle| if (std.mem.eql(u8, bundle.name, name)) return bundle;
    return null;
}

const EventFilters = cli_events.Filters;

fn eventsListHandler(ctx: zli.CommandContext) !void {
    _ = outputFromContext(ctx) orelse return;
    const filters = eventFiltersFromContext(ctx, true) orelse return;
    var events: [1000]nodeforge.events.ReadEvent = undefined;
    const result = cli_events.read(ctx.io, ctx.allocator, ctx.flag("events-path", []const u8), &filters, &events) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "cannot read local history ({t})", .{err});
        try writeCommandError(ctx, "events.read_failed", message, 1);
        return;
    };
    if (result.skipped != 0) try errorWriter(ctx).print("warn: events: skipped {d} invalid record(s)\\n", .{result.skipped});

    const cells = try ctx.allocator.alloc([5][]const u8, result.count);
    const rows = try ctx.allocator.alloc(nodeforge.cli_table.Row, result.count);
    const jsonl = try ctx.allocator.alloc([]const u8, result.count);
    var ts_buf: [1000][20]u8 = undefined;
    for (events[0..result.count], 0..) |event, index| {
        cells[index] = .{
            cli_events.displayTs(&ts_buf[index], event.ts),
            event.type,
            cli_events.node(event) orelse "-",
            event.message,
            try cli_events.fieldsText(ctx.allocator, event.fields),
        };
        rows[index] = .{ .cells = &cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = event }, .{});
    }
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .items = events[0..result.count], .skipped = result.skipped } }, .{});
    const columns = [_]nodeforge.cli_table.Column{
        .{ .key = "time", .title = "TIME" },
        .{ .key = "type", .title = "TYPE" },
        .{ .key = "node", .title = "NODE" },
        .{ .key = "message", .title = "MESSAGE", .max_width = 48 },
        .{ .key = "fields", .title = "FIELDS", .max_width = 64 },
    };
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = rows, .empty_message = "No events recorded." } }, .json = json, .jsonl = jsonl });
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
    const output = outputFromContext(ctx) orelse return;
    if (output.mode == .json) {
        const detail = cli_output.contractError(error.ModeNotSupported);
        try cli_output.writeError(errorWriter(ctx), output, detail.code, detail.message);
        setExitCode(ctx, 2);
        return;
    }
    const filters = eventFiltersFromContext(ctx, false) orelse return;
    const path = ctx.flag("events-path", []const u8);
    var offset: u64 = blk: {
        var file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |err| {
            const message = try std.fmt.allocPrint(ctx.allocator, "events: active file unavailable ({t})", .{err});
            try writeCommandError(ctx, "events.follow_unavailable", message, 1);
            return;
        };
        defer file.close(ctx.io);
        break :blk (try file.stat(ctx.io)).size;
    };
    while (true) {
        var file = std.Io.Dir.cwd().openFile(ctx.io, path, .{}) catch |err| {
            const message = try std.fmt.allocPrint(ctx.allocator, "events: active file unavailable ({t})", .{err});
            try writeCommandError(ctx, "events.follow_unavailable", message, 1);
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
            var follow_ts_buf: [20]u8 = undefined;
            const fields_text = try cli_events.fieldsText(ctx.allocator, event.fields);
            const human = try std.fmt.allocPrint(ctx.allocator, "{s}  {s}{s}{s}  {s}", .{ cli_events.displayTs(&follow_ts_buf, event.ts), event.type, if (fields_text.len == 0) "" else "  ", fields_text, event.message });
            const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = event }, .{});
            try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = json, .jsonl = &.{json} });
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
    _ = outputFromContext(ctx) orelse return;
    const node_id = ctx.getArg("node_id") orelse return;
    const requested_session = ctx.flag("session", []const u8);
    const events_path = ctx.flag("events-path", []const u8);
    if (requested_session.len != 0 and !nodeforge.events.validCorrelationId(requested_session)) {
        try writeCommandError(ctx, "trace.invalid_session", "--session must be 32 lowercase hexadecimal characters", 2);
        return;
    }
    if (requested_session.len != 0 and ctx.flag("latest", bool)) {
        try writeCommandError(ctx, "trace.conflicting_flags", "--session and --latest are mutually exclusive", 2);
        return;
    }

    var node_events: [cli_events.max_records]nodeforge.events.ReadEvent = undefined;
    const node_result = cli_events.read(ctx.io, ctx.allocator, events_path, &.{ .node = node_id, .limit = node_events.len }, &node_events) catch |err| {
        const message = try std.fmt.allocPrint(ctx.allocator, "cannot read local trace history ({t})", .{err});
        try writeCommandError(ctx, "trace.read_failed", message, 1);
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
            const message = try std.fmt.allocPrint(ctx.allocator, "cannot read session trace history ({t})", .{err});
            try writeCommandError(ctx, "trace.read_failed", message, 1);
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
            const message = try std.fmt.allocPrint(ctx.allocator, "cannot read service trace history ({t})", .{err});
            try writeCommandError(ctx, "trace.read_failed", message, 1);
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

    const TraceResult = struct {
        node_id: []const u8,
        boot_session_id: ?[]const u8,
        status: struct { phase: []const u8, terminal_reason: ?[]const u8, evidence: []const u8 },
        events: []const nodeforge.events.ReadEvent,
        gaps: []const TraceGap,
    };
    const trace_result = TraceResult{ .node_id = node_id, .boot_session_id = selected_session, .status = .{ .phase = phase, .terminal_reason = terminal_reason, .evidence = evidence }, .events = trace_events[0..trace_count], .gaps = gaps[0..gap_count] };
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = trace_result }, .{});
    var human: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer human.deinit();
    try human.writer.print("Trace\n  Node         {s}\n  Session      {s}\n  Phase        {s}\n  Evidence     {s}\n", .{ node_id, selected_session orelse "-", phase, evidence });
    if (terminal_reason) |reason| try human.writer.print("  Terminal     {s}\n", .{reason});
    if (trace_count == 0) try human.writer.writeAll("No safely associated events recorded.\n") else {
        try human.writer.writeAll("Events\n");
        var trace_ts_buf: [20]u8 = undefined;
        for (trace_events[0..trace_count]) |event| try views.eventLine(&human.writer, cli_events.displayTs(&trace_ts_buf, event.ts), event.type, try cli_events.fieldsText(ctx.allocator, event.fields), event.message);
    }
    if (gap_count != 0) {
        try human.writer.writeAll("Gaps\n");
        for (gaps[0..gap_count]) |gap| try human.writer.print("  {s}  {s} {s}  {s}\n", .{ gap.kind, gap.start, gap.end, gap.summary });
    }
    try renderOutputDocument(ctx, .{ .human = .{ .text = std.mem.trimEnd(u8, human.written(), "\n") }, .json = json });
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
    _ = outputFromContext(ctx) orelse return;
    const Item = struct { name: []const u8, description: []const u8, default_level: []const u8 };
    var items: [nodeforge.event_types.definitions.len]Item = undefined;
    var cells: [nodeforge.event_types.definitions.len][3][]const u8 = undefined;
    var rows: [nodeforge.event_types.definitions.len]nodeforge.cli_table.Row = undefined;
    var jsonl: [nodeforge.event_types.definitions.len][]const u8 = undefined;
    for (nodeforge.event_types.definitions, 0..) |definition, index| {
        items[index] = .{ .name = definition.name, .description = definition.description, .default_level = @tagName(definition.default_level) };
        cells[index] = .{ definition.name, @tagName(definition.default_level), definition.description };
        rows[index] = .{ .cells = &cells[index] };
        jsonl[index] = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = items[index] }, .{});
    }
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = .{ .items = &items } }, .{});
    const columns = [_]nodeforge.cli_table.Column{ .{ .key = "name", .title = "TYPE" }, .{ .key = "level", .title = "LEVEL" }, .{ .key = "description", .title = "DESCRIPTION" } };
    try renderOutputDocument(ctx, .{ .human = .{ .table = .{ .columns = &columns, .rows = &rows, .empty_message = "No event types registered." } }, .json = json, .jsonl = &jsonl });
}

fn addEventsFilterFlags(command: *zli.Command, comptime include_limit: bool) !void {
    try command.addFlags(&.{
        .{ .name = "type", .description = "Registered event type; list allowed values with `nodeforge events types`", .type = .String, .default_value = .{ .String = "" } },
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
        const message = std.fmt.allocPrint(ctx.allocator, "unknown event type '{s}'", .{event_type}) catch "unknown event type";
        writeCommandError(ctx, "events.invalid_type", message, 2) catch {};
        return null;
    }
    const since_text = ctx.flag("since", []const u8);
    const until_text = ctx.flag("until", []const u8);
    const since = if (since_text.len == 0) null else cli_events.parseTime(since_text) catch {
        writeCommandError(ctx, "events.invalid_since", "invalid --since timestamp", 2) catch {};
        return null;
    };
    const until = if (until_text.len == 0) null else cli_events.parseTime(until_text) catch {
        writeCommandError(ctx, "events.invalid_until", "invalid --until timestamp", 2) catch {};
        return null;
    };
    const limit: usize = if (has_limit) @intCast(ctx.flag("limit", i32)) else 1000;
    if (limit == 0 or limit > 1000) {
        writeCommandError(ctx, "events.invalid_limit", "--limit must be 1..1000", 2) catch {};
        return null;
    }
    const session = ctx.flag("session", []const u8);
    if (session.len != 0 and !nodeforge.events.validCorrelationId(session)) {
        writeCommandError(ctx, "events.invalid_session", "--session must be 32 lowercase hexadecimal characters", 2) catch {};
        return null;
    }
    return .{ .event_type = event_type, .node = ctx.flag("node", []const u8), .session = session, .since = since, .until = until, .limit = limit };
}

/// 读取当前命令的输出格式并校验其值。
/// 返回 null 表示已输出可读错误并把退出码设为用法错误 2。
fn outputJsonFromContext(ctx: zli.CommandContext) ?bool {
    const output = outputFromContext(ctx) orelse return null;
    return output.mode == .json or output.mode == .jsonl;
}

/// 将命令局部展示 flags 收敛为 M1.5 的 `Output` 值。后续有状态色、终端宽度或
/// pager 时只能扩展此入口，业务 handler 不得自行读取 `--no-color`。
fn outputFromContext(ctx: zli.CommandContext) ?cli_output.Output {
    const output = ctx.flag("output", []const u8);
    const mode: cli_output.Mode = if (std.mem.eql(u8, output, "json")) .json else if (std.mem.eql(u8, output, "jsonl")) .jsonl else if (std.mem.eql(u8, output, "human")) .human else {
        errorWriter(ctx).print("error: output: unsupported format '{s}' (expected human, json, or jsonl)\n", .{output}) catch {};
        setExitCode(ctx, 2);
        return null;
    };
    const width_value = ctx.flag("width", i32);
    if (width_value < 0) {
        errorWriter(ctx).writeAll("error: output: --width must be non-negative\n") catch {};
        setExitCode(ctx, 2);
        return null;
    }
    return .{ .mode = mode, .no_color = !ctx.flag("color", bool), .sections = ctx.flag("sections", []const u8), .fields = ctx.flag("fields", []const u8), .columns = ctx.flag("columns", []const u8), .width = @intCast(width_value), .wide = ctx.flag("wide", bool), .no_header = ctx.flag("no-header", bool) };
}

fn tableOptionsFromContext(ctx: zli.CommandContext) ?nodeforge.cli_table.Options {
    const value = outputFromContext(ctx) orelse return null;
    return .{ .color = value.colorEnabled(), .columns = value.columns, .width = value.width, .wide = value.wide, .no_header = value.no_header };
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

fn errorWriter(ctx: zli.CommandContext) *std.Io.Writer {
    return ctx.getContextData(CliState).err_writer;
}

fn renderOutputDocument(ctx: zli.CommandContext, document: nodeforge.cli_document.OutputDocument) !void {
    const output = outputFromContext(ctx) orelse return;
    document.render(ctx.writer, output) catch |err| switch (err) {
        error.ModeNotSupported, error.OptionNotApplicable, error.UnknownSelection, error.DuplicateSelection, error.MutuallyExclusiveOptions => {
            const detail = cli_output.contractError(@errorCast(err));
            try cli_output.writeError(errorWriter(ctx), output, detail.code, detail.message);
            setExitCode(ctx, 2);
        },
        else => return err,
    };
}

fn writeCommandError(ctx: zli.CommandContext, code: []const u8, message: []const u8, exit_code: u8) !void {
    const output = outputFromContext(ctx) orelse return;
    try cli_output.writeError(errorWriter(ctx), output, code, message);
    setExitCode(ctx, exit_code);
}

fn renderCommandResult(ctx: zli.CommandContext, human: []const u8, result: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(ctx.allocator, .{ .ok = true, .result = result }, .{});
    try renderOutputDocument(ctx, .{ .human = .{ .text = human }, .json = json });
}

fn jsonString(value: ?std.json.Value) []const u8 {
    const actual = value orelse return "-";
    return switch (actual) {
        .string => |text| text,
        .null => "-",
        else => "-",
    };
}

fn jsonDisplay(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    const actual = value orelse return "-";
    return switch (actual) {
        .string => |text| text,
        .bool => |flag| if (flag) "true" else "false",
        .null => "<unset>",
        .integer => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .float => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        else => try std.json.Stringify.valueAlloc(allocator, actual, .{}),
    };
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
        .description = "Catalog directory path",
        .type = .String,
        .default_value = .{ .String = nodeforge.catalog_store.defaultPath() },
    });
}

/// 为支持 human 或 JSON 结果的命令声明输出格式参数。
fn addOutputFlag(command: *zli.Command) !void {
    try command.addFlag(.{
        .name = "output",
        .shortcut = "o",
        .description = "Output format: human, json, or jsonl",
        .type = .String,
        .default_value = .{ .String = "human" },
    });
    try command.addFlag(.{
        .name = "color",
        .description = "Reserved for future ANSI color support; M1.5 outputs without color regardless",
        .type = .Bool,
        .default_value = .{ .Bool = true },
    });
    try command.addFlags(&.{
        .{ .name = "sections", .description = "Comma-separated detail section keys", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "fields", .description = "Comma-separated detail field keys", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "columns", .description = "Comma-separated list column keys", .type = .String, .default_value = .{ .String = "" } },
        .{ .name = "width", .description = "Maximum human output width; 0 detects/defaults", .type = .Int, .default_value = .{ .Int = 0 } },
        .{ .name = "wide", .description = "Disable normal low-value column truncation", .type = .Bool, .default_value = .{ .Bool = false } },
        .{ .name = "no-header", .description = "Suppress human list headers", .type = .Bool, .default_value = .{ .Bool = false } },
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

/// M4.11 规范就绪探测。仅 `/healthz` 健康是不够的：
/// 运维人员需要证据，证明配置的对外监听器以及置备所需的
/// 每个管理平面在运行中的 daemon 内可用。
fn statusProbe(
    io: std.Io,
    allocator: std.mem.Allocator,
    config_path: []const u8,
    debug: bool,
    error_out: *std.Io.Writer,
) ?views.StatusView {
    var parsed_config = loadConfig(io, allocator, config_path, error_out, debug) orelse return null;
    defer parsed_config.deinit();
    const port = parsed_config.value.server.http_port;
    const server_ip = allocator.dupe(u8, parsed_config.value.server.server_ip) catch return null;
    const status = nodeforge.management_client.managementStatus(io, port);
    const loopback_health = nodeforge.management_client.health(io, port);
    const advertised_health = nodeforge.management_client.healthAt(io, server_ip, port);
    const active_config = nodeforge.management_client.validateActiveConfig(io, parsed_config.value.server.http_port);
    const tftp = nodeforge.management_client.tftpCounters(io, port);

    // doctor 只关心端点是否可用，不需要同时保留三个响应体。复用同一块统一容量
    // 的堆缓冲，避免旧实现一次在栈上保留 3 × 128 KiB。
    const response_buffer = allocator.alloc(u8, managementResponseCapacity) catch return null;
    defer allocator.free(response_buffer);
    const nodes_api = (nodeforge.management_client.nodesJson(io, port, null, response_buffer) catch null) != null;
    const profiles_api = (nodeforge.management_client.profilesJson(io, port, null, response_buffer) catch null) != null;
    const catalog_api = nodes_api and profiles_api;
    const dhcp_api = (nodeforge.management_client.dhcpLeasesJson(io, port, false, response_buffer) catch null) != null;

    const ok = status.healthy and loopback_health.healthy and advertised_health.healthy and active_config.healthy and catalog_api and dhcp_api and tftp.healthy;
    return .{
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
    };
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
    // CLI 每次只执行一个命令；在公共配置入口同步当前线程的 HTTP 诊断目标，
    // 使所有 management client 调用共享一致的 `--debug` 行为，无需把布尔参数
    // 逐层穿透六十余个资源包装函数。false 必须显式清空，避免同进程测试串线。
    nodeforge.management_client.configureDiagnostics(if (debug) out else null);
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

test "archive build accepts only safe relative payload paths" {
    try std.testing.expect(validArchiveBuildPath("etc/nodeforge/config.yaml"));
    try std.testing.expect(validArchiveBuildPath("./usr/local/bin/tool"));
    try std.testing.expect(validArchiveBuildPath("directory with spaces/file"));
    try std.testing.expect(!validArchiveBuildPath("/etc/passwd"));
    try std.testing.expect(!validArchiveBuildPath("../escape"));
    try std.testing.expect(!validArchiveBuildPath("safe/../../escape"));
    try std.testing.expect(!validArchiveBuildPath("bad\npath"));
    try std.testing.expect(!validArchiveBuildPath(""));
}

test "archive compression requires an explicit matching suffix" {
    try std.testing.expect(parseArchiveCompression("none").? == .none);
    try std.testing.expect(parseArchiveCompression("gzip").? == .gzip);
    try std.testing.expect(parseArchiveCompression("xz").? == .xz);
    try std.testing.expect(parseArchiveCompression("bzip2") == null);
    try std.testing.expect(ArchiveCompression.none.validOutputSuffix("bundle.tar"));
    try std.testing.expect(!ArchiveCompression.none.validOutputSuffix("bundle.tar.gz"));
    try std.testing.expect(ArchiveCompression.gzip.validOutputSuffix("bundle.tar.gz"));
    try std.testing.expect(ArchiveCompression.gzip.validOutputSuffix("bundle.tgz"));
    try std.testing.expect(ArchiveCompression.xz.validOutputSuffix("bundle.tar.xz"));
    try std.testing.expect(ArchiveCompression.xz.validOutputSuffix("bundle.txz"));
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
