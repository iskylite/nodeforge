//! nodeforge CLI 使用的最小健康检查 HTTP 客户端。
//! 管理探测固定连接 localhost；PXE 探测只连接配置中的服务 IPv4。

const std = @import("std");
const management = @import("management.zig");

/// 单次 CLI 进程的 HTTP 诊断输出目标。
///
/// CLI 命令在解析出 `--debug` 后通过 `configureDiagnostics` 设置当前线程的
/// stderr writer。这里使用 threadlocal 而不是进程全局变量，避免测试或未来并发
/// CLI 调用互相串线；daemon worker 不会继承或写入 CLI 的诊断流。
threadlocal var diagnostic_out: ?*std.Io.Writer = null;

/// 启用或关闭当前线程的 management client 诊断输出。
///
/// 诊断默认只记录请求行、响应状态、长度和错误响应预览，不记录请求正文及认证类
/// header，避免 `config_token`、幂等键或未来凭据意外进入终端日志。
pub fn configureDiagnostics(out: ?*std.Io.Writer) void {
    diagnostic_out = out;
}

/// 由 CLI 的 JSON 解码边界调用，补充类型、错误标签和受限输入预览。
///
/// 仅在 `--debug` 已启用时生效。预览经过 JSON 字符串转义并限制为 1024 字节，
/// 防止 daemon 异常响应中的换行或控制字符破坏诊断输出结构。
pub fn reportJsonFailure(comptime type_name: []const u8, err: anyerror, body: []const u8) void {
    if (diagnostic_out == null) return;
    const preview_len = @min(body.len, 1024);
    debugPrint("json_decode_failed type={s} cause={t} bytes={d} preview={f} truncated={}", .{ type_name, err, body.len, std.json.fmt(body[0..preview_len], .{}), preview_len < body.len });
}

fn debugPrint(comptime format: []const u8, args: anytype) void {
    const out = diagnostic_out orelse return;
    out.print("debug: http " ++ format ++ "\n", args) catch {};
}

fn debugRequest(method: []const u8, path: []const u8, port: u16) void {
    debugPrint("request method={s} path={s} address={s}:{d}", .{ method, path, management.client_ip, port });
}

fn debugConnectFailure(port: u16, err: anyerror) void {
    debugPrint("connect_failed address={s}:{d} cause={t}", .{ management.client_ip, port, err });
}

fn debugResponse(method: []const u8, path: []const u8, reply: HttpReply) void {
    const body = reply.body orelse "";
    debugPrint("response method={s} path={s} status={d} bytes={d}", .{ method, path, reply.status, body.len });
    // 成功正文可能包含交付 token 或节点配置；仅预览 daemon 的错误信封。
    if (reply.status >= 400 and body.len != 0) {
        const preview_len = @min(body.len, 1024);
        debugPrint("response_error_body preview={f} truncated={}", .{ std.json.fmt(body[0..preview_len], .{}), preview_len < body.len });
    }
}

pub const Status = struct {
    /// TCP 连接是否成功建立；false 表示进程不可达或端口未监听。
    reachable: bool,
    /// HTTP 响应是否为 2xx（成功）；false 包括连接成功但响应非 2xx。
    healthy: bool,
};

/// M1 TFTP 传输计数器，由 daemon 的本机管理路由返回。
/// 字段全部通过简单 JSON 解析提取，不依赖通用 JSON 库以保持 CLI 轻量。
pub const TftpCounters = struct {
    reachable: bool = false,
    healthy: bool = false,
    started: u64 = 0,
    completed: u64 = 0,
    failed: u64 = 0,
};

/// M1 资产导入请求的受约束元数据。由 CLI 构造，通过本地 HTTP POST 发送给 daemon。
/// daemon 负责计算 SHA-256、校验路径安全性和原子写入 catalog。
pub const AssetImport = struct {
    name: []const u8,
    kind: []const u8,
    path: []const u8,
    distro: ?[]const u8 = null,
    version: ?[]const u8 = null,
    arch: ?[]const u8 = null,
    kernel_release: ?[]const u8 = null,
    revision: u64 = 1,
    size: ?u64 = null,
    media_type: ?[]const u8 = null,
};

/// M3.6 ISO 导入请求。CLI 先将管理员拥有的任意 ISO 原子复制到 daemon
/// 管控的 staging 目录；只有生成的不透明文件名被发送到本机管理端点。
/// distro/version/arch 三个字段是可选覆盖。family 始终由 ISO 布局决定；
/// daemon 从 .treeinfo 或 .disk/info 检测三元组，提供的值直接采用而不
/// 与检测结果比对，用于已知布局但产品标签未知或元数据不完整的介质。
pub const InstallSourceImport = struct {
    /// 已暂存到 import_dir 的 ISO 文件名（不含路径前缀），由 CLI 生成。
    filename: []const u8,
    /// 用户选择的 ISO basename，仅用于生成默认逻辑名称，不用于文件访问。
    original_filename: []const u8,
    content_sha256: []const u8,
    idempotency_key: []const u8,
    name: ?[]const u8 = null,
    /// 可选的产品覆盖；daemon 在元数据无法识别产品时采用此值。
    distro: ?[]const u8 = null,
    /// 可选的版本覆盖；daemon 在元数据缺失版本时采用此值。
    version: ?[]const u8 = null,
    /// 可选的架构覆盖；daemon 在元数据缺失架构时采用此值。
    arch: ?[]const u8 = null,
};

/// 探测管理接口 `/healthz`。
/// M4.5 公共 reader 校验状态行、headers 和 Content-Length；健康探针只消费状态，
/// 并使用 `Connection: close` 保持本机连接生命周期简单且有界。
pub fn health(io: std.Io, port: u16) Status {
    return probeAt(io, management.client_ip, port, "/healthz", "GET");
}

/// 探测指定 NodeForge IPv4 listener 的 `/healthz`。
/// 该函数不接受 URL、DNS 或 IPv6，避免演变为通用远程管理客户端。
pub fn healthAt(io: std.Io, ip: []const u8, port: u16) Status {
    return probeAt(io, ip, port, "/healthz", "GET");
}

/// 探测本机管理状态接口，确认进程不仅监听端口，而且注册了管理路由。
pub fn managementStatus(io: std.Io, port: u16) Status {
    return probeAt(
        io,
        management.client_ip,
        port,
        "/api/v1/management/status",
        "GET",
    );
}

/// 请求服务端重新校验当前生效配置。
pub fn validateActiveConfig(io: std.Io, port: u16) Status {
    return probeAt(
        io,
        management.client_ip,
        port,
        "/api/v1/management/config/validations",
        "POST",
    );
}

/// 通过仅限本机的 API 显式武装一个 install generation。
pub fn installGenerations(io: std.Io, port: u16, node_id: []const u8, reason_buf: []u8) Mutation {
    if (!querySafe(node_id)) return .{ .reachable = false, .healthy = false };
    var path: [256]u8 = undefined;
    const value = std.fmt.bufPrint(&path, "/api/v1/management/nodes/{s}/install-generations", .{node_id}) catch return .{ .reachable = false, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", value, "{}", revision, reason_buf);
}

pub fn installGenerationsForce(io: std.Io, port: u16, node_id: []const u8, reason_buf: []u8) Mutation {
    if (!querySafe(node_id)) return .{ .reachable = false, .healthy = false };
    var path: [256]u8 = undefined;
    const value = std.fmt.bufPrint(&path, "/api/v1/management/nodes/{s}/install-generations", .{node_id}) catch return .{ .reachable = false, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", value, "{\"force\":true}", revision, reason_buf);
}

/// 探测 M1 TFTP 运行态路由。仅由本机 daemon 提供，不接受远程地址。
pub fn tftpStatus(io: std.Io, port: u16) Status {
    return probeAt(io, management.client_ip, port, "/api/v1/management/runtime/tftp", "GET");
}

/// 读取 M1 TFTP 计数器响应并解析为 `TftpCounters`。
///
/// 这是一个固定路由的小型 HTTP 客户端，不实现通用远程管理。
/// 解析使用简单的字符串查找提取 `started`/`completed`/`failed` 三个数字字段，
/// 不依赖通用 JSON 库以保持 CLI 依赖最小化。
pub fn tftpCounters(io: std.Io, port: u16) TftpCounters {
    var buffer: [4096]u8 = undefined;
    const maybe_body = managementJson(io, port, "/api/v1/management/runtime/tftp", &buffer) catch return .{ .reachable = true };
    const body = maybe_body orelse return .{ .reachable = true };
    const Response = struct { result: struct { started: u64, completed: u64, failed: u64 } };
    const parsed = std.json.parseFromSlice(Response, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return .{ .reachable = true };
    defer parsed.deinit();
    return .{ .reachable = true, .healthy = true, .started = parsed.value.result.started, .completed = parsed.value.result.completed, .failed = parsed.value.result.failed };
}

/// 获取 daemon 生成的 TFTP 会话列表 JSON，并写入调用方提供的缓冲区。
///
/// 返回写入的字节切片；如果响应超过 `output` 容量则返回 `error.ResponseTooLarge`。
/// 调用方负责格式化输出；本函数只负责固定路由的 HTTP GET 和响应体提取。
/// 仅连接 `127.0.0.1`，不接受远程端点。
pub fn tftpSessionsJson(io: std.Io, port: u16, output: []u8) !?[]const u8 {
    return managementJson(io, port, "/api/v1/management/runtime/tftp/sessions", output);
}

/// 从本机管理路由获取 M2 DHCP lease 观测数据。
/// `unknown_only` 为 true 时只返回未认领节点的 lease，false 返回全部。
/// 仅连接 `127.0.0.1`，不接受远程端点。
pub fn dhcpLeasesJson(io: std.Io, port: u16, unknown_only: bool, output: []u8) !?[]const u8 {
    return managementJson(io, port, if (unknown_only) "/api/v1/management/runtime/dhcp/leases?scope=unclaimed" else "/api/v1/management/runtime/dhcp/leases", output);
}

pub fn discoveryObservationsJson(io: std.Io, port: u16, mac: ?[]const u8, output: []u8) !?[]const u8 {
    var path: [320]u8 = undefined;
    const value = if (mac) |item| blk: {
        if (!querySafe(item)) return error.InvalidMac;
        break :blk try std.fmt.bufPrint(&path, "/api/v1/management/discovery/observations/{s}", .{item});
    } else "/api/v1/management/discovery/observations";
    return managementJson(io, port, value, output);
}

pub fn discoveryPolicyJson(io: std.Io, port: u16, output: []u8) !?[]const u8 {
    return managementJson(io, port, "/api/v1/management/discovery/policy", output);
}

pub fn nodesJson(io: std.Io, port: u16, node_id: ?[]const u8, output: []u8) !?[]const u8 {
    var path_buffer: [256]u8 = undefined;
    const path = if (node_id) |id| std.fmt.bufPrint(&path_buffer, "/api/v1/management/nodes/{s}", .{id}) catch return error.InvalidNodeId else "/api/v1/management/nodes";
    return managementJson(io, port, path, output);
}

pub fn profilesJson(io: std.Io, port: u16, name: ?[]const u8, output: []u8) !?[]const u8 {
    var path_buffer: [256]u8 = undefined;
    const path = if (name) |id| std.fmt.bufPrint(&path_buffer, "/api/v1/management/profiles/{s}", .{id}) catch return error.InvalidProfileName else "/api/v1/management/profiles";
    return managementJson(io, port, path, output);
}

pub fn capabilitiesJson(io: std.Io, port: u16, owner: []const u8, identity: []const u8, output: []u8) !?[]const u8 {
    if ((!std.mem.eql(u8, owner, "profile") and !std.mem.eql(u8, owner, "node")) or !querySafe(identity)) return error.InvalidCapabilityResource;
    var path: [320]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&path, "/api/v1/management/{s}s/{s}/capabilities", .{ owner, identity });
    return managementJson(io, port, rendered, output);
}

/// M4.5：分页获取一个 collection 页。`cursor` 为 null 取首页，否则取后续页；
/// 每页请求 `limit=200` 以减少往返。`path` 是 collection 根路径（如
/// `/api/v1/management/nodes`）。调用方按响应中的 `next_cursor` 决定是否继续。
pub fn collectionPageJson(io: std.Io, port: u16, path: []const u8, cursor: ?[]const u8, output: []u8) !?[]const u8 {
    var request_path: [320]u8 = undefined;
    const rendered = if (cursor) |c|
        try std.fmt.bufPrint(&request_path, "{s}?cursor={s}&limit=200", .{ path, c })
    else
        try std.fmt.bufPrint(&request_path, "{s}?limit=200", .{path});
    return managementJson(io, port, rendered, output);
}

pub fn installSourceJson(io: std.Io, port: u16, name: []const u8, output: []u8) !?[]const u8 {
    if (!querySafe(name)) return error.InvalidInstallSourceName;
    var path: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&path, "/api/v1/management/install-sources/{s}", .{name});
    return managementJson(io, port, rendered, output);
}

pub fn catalogResourcesJson(io: std.Io, port: u16, resource: []const u8, name: ?[]const u8, output: []u8) !?[]const u8 {
    if (!std.mem.eql(u8, resource, "install-sources") and !std.mem.eql(u8, resource, "repositories")) return error.InvalidResource;
    var path: [320]u8 = undefined;
    const rendered = if (name) |value| blk: {
        if (!querySafe(value)) return error.InvalidResourceName;
        break :blk try std.fmt.bufPrint(&path, "/api/v1/management/{s}/{s}", .{ resource, value });
    } else try std.fmt.bufPrint(&path, "/api/v1/management/{s}?limit=200", .{resource});
    return managementJson(io, port, rendered, output);
}

/// 查询 BootBundle 集合。list/show 共用同一只读端点，show 由 CLI 在本地按
/// canonical name 筛选，避免为纯展示再引入一套服务端资源语义。
pub fn bootBundlesJson(io: std.Io, port: u16, output: []u8) !?[]const u8 {
    return managementJson(io, port, "/api/v1/management/boot-bundles", output);
}

pub fn softwareCapabilitiesJson(io: std.Io, port: u16, resource: []const u8, name: []const u8, kind: ?[]const u8, search: ?[]const u8, output: []u8) !?[]const u8 {
    if (!std.mem.eql(u8, resource, "install-sources") and !std.mem.eql(u8, resource, "repositories") and !std.mem.eql(u8, resource, "profiles")) return error.InvalidResource;
    if (!querySafe(name)) return error.InvalidResourceName;
    if (kind) |value| if (!querySafe(value)) return error.InvalidSoftwareKind;
    if (search) |value| if (!querySafe(value)) return error.InvalidSearch;
    var path: [640]u8 = undefined;
    var writer = std.Io.Writer.fixed(&path);
    try writer.print("/api/v1/management/{s}/{s}/software", .{ resource, name });
    var separator: u8 = '?';
    if (kind) |value| {
        try writer.print("{c}kind={s}", .{ separator, value });
        separator = '&';
    }
    if (search) |value| try writer.print("{c}search={s}", .{ separator, value });
    return managementJson(io, port, writer.buffered(), output);
}

pub fn valuesMutation(io: std.Io, port: u16, owner: []const u8, identity: []const u8, operation: []const u8, key: []const u8, values: []const []const u8, mutations: []const @import("../config/scalar_mutation.zig").Mutation, force: bool, reason_buf: []u8) Mutation {
    if (!querySafe(owner) or !querySafe(identity) or !querySafe(key)) return .{ .reachable = false, .healthy = false };
    var path_buffer: [336]u8 = undefined;
    const path = if (force)
        std.fmt.bufPrint(&path_buffer, "/api/v1/management/{s}s/{s}/values?force=true", .{ owner, identity }) catch return .{ .reachable = false, .healthy = false }
    else
        std.fmt.bufPrint(&path_buffer, "/api/v1/management/{s}s/{s}/values", .{ owner, identity }) catch return .{ .reachable = false, .healthy = false };
    var body: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    std.json.Stringify.value(.{ .operation = operation, .key = key, .values = values, .mutations = mutations }, .{ .emit_null_optional_fields = true }, &body.writer) catch return .{ .reachable = true, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", path, body.written(), revision, reason_buf);
}

pub fn valuesJson(io: std.Io, port: u16, owner: []const u8, identity: []const u8, key: []const u8, output: []u8) !?[]const u8 {
    if (!querySafe(owner) or !querySafe(identity) or !querySafe(key)) return error.InvalidProperty;
    var path: [384]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&path, "/api/v1/management/{s}s/{s}/values?key={s}", .{ owner, identity, key });
    return managementJson(io, port, rendered, output);
}

pub fn itemMutation(io: std.Io, port: u16, owner: []const u8, identity: []const u8, patch: @import("../config/item_mutation.zig").Patch, force: bool, reason_buf: []u8) Mutation {
    if (!querySafe(owner) or !querySafe(identity)) return .{ .reachable = false, .healthy = false };
    var path_buffer: [336]u8 = undefined;
    const path = if (force)
        std.fmt.bufPrint(&path_buffer, "/api/v1/management/{s}s/{s}/items?force=true", .{ owner, identity }) catch return .{ .reachable = false, .healthy = false }
    else
        std.fmt.bufPrint(&path_buffer, "/api/v1/management/{s}s/{s}/items", .{ owner, identity }) catch return .{ .reachable = false, .healthy = false };
    var body: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    std.json.Stringify.value(patch, .{}, &body.writer) catch return .{ .reachable = true, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", path, body.written(), revision, reason_buf);
}

pub fn itemReplacement(io: std.Io, port: u16, owner: []const u8, identity: []const u8, replacement: @import("../config/item_mutation.zig").Replacement, force: bool, reason_buf: []u8) Mutation {
    if (!querySafe(owner) or !querySafe(identity)) return .{ .reachable = false, .healthy = false };
    var path_buffer: [336]u8 = undefined;
    const path = if (force)
        std.fmt.bufPrint(&path_buffer, "/api/v1/management/{s}s/{s}/items?force=true", .{ owner, identity }) catch return .{ .reachable = false, .healthy = false }
    else
        std.fmt.bufPrint(&path_buffer, "/api/v1/management/{s}s/{s}/items", .{ owner, identity }) catch return .{ .reachable = false, .healthy = false };
    var body: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    std.json.Stringify.value(replacement, .{}, &body.writer) catch return .{ .reachable = true, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", path, body.written(), revision, reason_buf);
}

pub fn provisionBundleJson(io: std.Io, port: u16, name: ?[]const u8, items: bool, identity: ?[]const u8, output: []u8) !?[]const u8 {
    var path: [512]u8 = undefined;
    const rendered = if (name) |bundle| if (items) if (identity) |item| try std.fmt.bufPrint(&path, "/api/v1/management/assets/provision-bundles/{s}/items?identity={s}", .{ bundle, item }) else try std.fmt.bufPrint(&path, "/api/v1/management/assets/provision-bundles/{s}/items", .{bundle}) else try std.fmt.bufPrint(&path, "/api/v1/management/assets/provision-bundles/{s}", .{bundle}) else "/api/v1/management/assets/provision-bundles";
    return managementJson(io, port, rendered, output);
}

pub fn provisionBundleMutation(io: std.Io, port: u16, method: []const u8, name: ?[]const u8, items: bool, body: []const u8, reason_buf: []u8) Mutation {
    var path_buffer: [384]u8 = undefined;
    const path = if (name) |bundle| if (items) std.fmt.bufPrint(&path_buffer, "/api/v1/management/assets/provision-bundles/{s}/items", .{bundle}) catch return .{ .reachable = false, .healthy = false } else std.fmt.bufPrint(&path_buffer, "/api/v1/management/assets/provision-bundles/{s}", .{bundle}) catch return .{ .reachable = false, .healthy = false } else "/api/v1/management/assets/provision-bundles";
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, method, path, body, revision, reason_buf);
}

pub fn managedFileRemove(io: std.Io, port: u16, name: []const u8, reason_buf: []u8) Mutation {
    if (!querySafe(name)) return .{ .reachable = false, .healthy = false };
    var path: [320]u8 = undefined;
    const rendered = std.fmt.bufPrint(&path, "/api/v1/management/assets/managed-files/{s}", .{name}) catch return .{ .reachable = false, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "DELETE", rendered, "", revision, reason_buf);
}

pub fn scalarMutation(io: std.Io, port: u16, owner: []const u8, identity: []const u8, key: []const u8, value: ?[]const u8, reason_buf: []u8) Mutation {
    return scalarMutations(io, port, owner, identity, &.{.{ .key = key, .value = value }}, false, reason_buf);
}

pub fn scalarMutations(io: std.Io, port: u16, owner: []const u8, identity: []const u8, mutations: []const @import("../config/scalar_mutation.zig").Mutation, force: bool, reason_buf: []u8) Mutation {
    if (!querySafe(owner) or !querySafe(identity) or mutations.len == 0) return .{ .reachable = false, .healthy = false };
    for (mutations) |mutation| if (!querySafe(mutation.key)) return .{ .reachable = false, .healthy = false };
    var path_buffer: [336]u8 = undefined;
    const path = if (force)
        std.fmt.bufPrint(&path_buffer, "/api/v1/management/{s}s/{s}/properties?force=true", .{ owner, identity }) catch return .{ .reachable = false, .healthy = false }
    else
        std.fmt.bufPrint(&path_buffer, "/api/v1/management/{s}s/{s}/properties", .{ owner, identity }) catch return .{ .reachable = false, .healthy = false };
    var body: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    std.json.Stringify.value(.{ .mutations = mutations }, .{ .emit_null_optional_fields = true }, &body.writer) catch return .{ .reachable = true, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", path, body.written(), revision, reason_buf);
}

pub fn itemsJson(io: std.Io, port: u16, owner: []const u8, identity: []const u8, key: []const u8, item_identity: ?[]const u8, output: []u8) !?[]const u8 {
    if (!querySafe(owner) or !querySafe(identity) or !querySafe(key) or (item_identity != null and !querySafe(item_identity.?))) return error.InvalidProperty;
    var path: [512]u8 = undefined;
    const rendered = if (item_identity) |item| try std.fmt.bufPrint(&path, "/api/v1/management/{s}s/{s}/items?key={s}&identity={s}", .{ owner, identity, key, item }) else try std.fmt.bufPrint(&path, "/api/v1/management/{s}s/{s}/items?key={s}", .{ owner, identity, key });
    return managementJson(io, port, rendered, output);
}

pub fn itemValuesMutation(io: std.Io, port: u16, owner: []const u8, resource_identity: []const u8, item_identity: []const u8, operation: []const u8, key: []const u8, field: []const u8, values: []const []const u8, force: bool, reason_buf: []u8) Mutation {
    if (!querySafe(owner) or !querySafe(resource_identity) or !querySafe(item_identity) or !querySafe(key) or !querySafe(field)) return .{ .reachable = false, .healthy = false };
    var path_buffer: [336]u8 = undefined;
    const path = if (force)
        std.fmt.bufPrint(&path_buffer, "/api/v1/management/{s}s/{s}/items?force=true", .{ owner, resource_identity }) catch return .{ .reachable = false, .healthy = false }
    else
        std.fmt.bufPrint(&path_buffer, "/api/v1/management/{s}s/{s}/items", .{ owner, resource_identity }) catch return .{ .reachable = false, .healthy = false };
    var body: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body.deinit();
    std.json.Stringify.value(.{ .operation = operation, .key = key, .identity = item_identity, .field = field, .values = values }, .{}, &body.writer) catch return .{ .reachable = true, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", path, body.written(), revision, reason_buf);
}

pub fn itemValuesJson(io: std.Io, port: u16, owner: []const u8, resource_identity: []const u8, key: []const u8, item_identity: []const u8, field: []const u8, output: []u8) !?[]const u8 {
    if (!querySafe(owner) or !querySafe(resource_identity) or !querySafe(key) or !querySafe(item_identity) or !querySafe(field)) return error.InvalidItemValuesQuery;
    var path: [512]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&path, "/api/v1/management/{s}s/{s}/items?key={s}&identity={s}&field={s}", .{ owner, resource_identity, key, item_identity, field });
    return managementJson(io, port, rendered, output);
}

/// M4.5：管理写请求结果。`reason` 在失败时指向调用方提供的 `reason_buf`，
/// 形如 "code: message (request_id=...)"（§9.14.7：4xx/5xx 解析统一错误信封后
/// 映射为 CLI 结构化错误）；成功或连接失败（无法解析）时为空，由调用方回退。
pub const Mutation = struct {
    reachable: bool,
    healthy: bool,
    reason: []const u8 = "",
};

pub fn profileCreate(io: std.Io, port: u16, name: []const u8, install_source: []const u8, kind: []const u8, boot_bundle: ?[]const u8, reason_buf: []u8) Mutation {
    if (!querySafe(name) or !querySafe(install_source)) return .{ .reachable = false, .healthy = false };
    if (boot_bundle) |bb| if (!querySafe(bb)) return .{ .reachable = false, .healthy = false };
    var body: [640]u8 = undefined;
    const rendered = if (boot_bundle) |bb|
        std.fmt.bufPrint(&body, "{{\"name\":{f},\"install_source\":{f},\"kind\":{f},\"boot_bundle\":{f}}}", .{ std.json.fmt(name, .{}), std.json.fmt(install_source, .{}), std.json.fmt(kind, .{}), std.json.fmt(bb, .{}) }) catch
            return .{ .reachable = true, .healthy = false, .reason = formatPlain(reason_buf, "profile.invalid", "profile request is too large") }
    else
        std.fmt.bufPrint(&body, "{{\"name\":{f},\"install_source\":{f},\"kind\":{f}}}", .{ std.json.fmt(name, .{}), std.json.fmt(install_source, .{}), std.json.fmt(kind, .{}) }) catch
            return .{ .reachable = true, .healthy = false, .reason = formatPlain(reason_buf, "profile.invalid", "profile request is too large") };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", "/api/v1/management/profiles", rendered, revision, reason_buf);
}

/// 删除未被 Node 引用的 Profile。客户端先读取当前 catalog revision，并通过
/// `If-Match` 提交 DELETE，确保检查引用关系和删除发生在同一 generation 上。
pub fn profileRemove(io: std.Io, port: u16, name: []const u8, reason_buf: []u8) Mutation {
    if (!querySafe(name)) return .{ .reachable = false, .healthy = false };
    var path: [256]u8 = undefined;
    const route = std.fmt.bufPrint(&path, "/api/v1/management/profiles/{s}", .{name}) catch return .{ .reachable = false, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "DELETE", route, "", revision, reason_buf);
}

/// v0.2 boot-bundle 创建：diskless profile 引用的 kernel/initrd 组合。
/// CLI 命令 `nodeforge assets boot-bundle create` 调用此函数。
/// 三个资产必须已通过 `nodeforge assets register` 注册到 catalog 中。
pub fn bootBundleCreate(io: std.Io, port: u16, name: []const u8, distro: []const u8, version: []const u8, arch: []const u8, kernel_release: []const u8, kernel: []const u8, initrd: []const u8, reason_buf: []u8) Mutation {
    if (!querySafe(name) or !querySafe(distro) or !querySafe(version) or !querySafe(kernel) or !querySafe(initrd)) return .{ .reachable = false, .healthy = false };
    var body: [1024]u8 = undefined;
    const rendered = std.fmt.bufPrint(&body, "{{\"name\":{f},\"distro\":{f},\"version\":{f},\"arch\":{f},\"kernel_release\":{f},\"kernel\":{f},\"initrd\":{f}}}", .{ std.json.fmt(name, .{}), std.json.fmt(distro, .{}), std.json.fmt(version, .{}), std.json.fmt(arch, .{}), std.json.fmt(kernel_release, .{}), std.json.fmt(kernel, .{}), std.json.fmt(initrd, .{}) }) catch
        return .{ .reachable = true, .healthy = false, .reason = formatPlain(reason_buf, "boot_bundle.invalid", "boot bundle request is too large") };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", "/api/v1/management/boot-bundles", rendered, revision, reason_buf);
}

/// `profile rootfs plan`：编译 diskless Profile 的 rootfs_input_digest 与 cache_state。
pub fn rootfsPlanJson(io: std.Io, port: u16, name: []const u8, output: []u8) !?[]const u8 {
    if (!querySafe(name)) return error.InvalidProfileName;
    var path: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&path, "/api/v1/management/profiles/{s}/rootfs/plan", .{name});
    return managementJson(io, port, rendered, output);
}

/// `profile rootfs status`：查询 Profile 当前 rootfs_input_digest 的 ready 制品。
pub fn rootfsStatusJson(io: std.Io, port: u16, name: []const u8, output: []u8) !?[]const u8 {
    if (!querySafe(name)) return error.InvalidProfileName;
    var path: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&path, "/api/v1/management/profiles/{s}/rootfs", .{name});
    return managementJson(io, port, rendered, output);
}

/// `profile rootfs register`：登记一个已构建 rootfs 制品（内容寻址）。
pub fn rootfsRegister(io: std.Io, port: u16, name: []const u8, file_path: []const u8, uncompressed_size: u64, reason_buf: []u8) Mutation {
    if (!querySafe(name)) return .{ .reachable = false, .healthy = false };
    var body: [1024]u8 = undefined;
    // 0 表示调用方没有可信的展开大小，因此直接省略 JSON 字段。服务端将其解释
    // 为 unknown；不能发送 0 并让下游误认为“已测量且为空”。
    const rendered = (if (uncompressed_size == 0)
        std.fmt.bufPrint(&body, "{{\"path\":{f}}}", .{std.json.fmt(file_path, .{})})
    else
        std.fmt.bufPrint(&body, "{{\"path\":{f},\"uncompressed_size\":{d}}}", .{ std.json.fmt(file_path, .{}), uncompressed_size })) catch
        return .{ .reachable = true, .healthy = false, .reason = formatPlain(reason_buf, "rootfs.invalid", "rootfs register request is too large") };
    var path: [256]u8 = undefined;
    const route = std.fmt.bufPrint(&path, "/api/v1/management/profiles/{s}/rootfs/register", .{name}) catch return .{ .reachable = false, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", route, rendered, revision, reason_buf);
}

/// `profile rootfs build`：从 Profile build projection 构建内容寻址 rootfs 制品
/// （OS 层 + rootfs-build phase 步骤 + mksquashfs + 登记）。`if_input_digest` 非空时
/// 作为防漂移约束（仅当当前 rootfs input digest 匹配才构建）。
pub fn rootfsBuild(io: std.Io, port: u16, name: []const u8, if_input_digest: ?[]const u8, reason_buf: []u8) Mutation {
    if (!querySafe(name)) return .{ .reachable = false, .healthy = false };
    var body: [1024]u8 = undefined;
    const rendered = if (if_input_digest) |digest|
        std.fmt.bufPrint(&body, "{{\"if_input_digest\":{f}}}", .{std.json.fmt(digest, .{})}) catch
            return .{ .reachable = true, .healthy = false, .reason = formatPlain(reason_buf, "rootfs.invalid", "rootfs build request is too large") }
    else
        std.fmt.bufPrint(&body, "{{}}", .{}) catch
            return .{ .reachable = true, .healthy = false, .reason = formatPlain(reason_buf, "rootfs.invalid", "rootfs build request is too large") };
    var path: [256]u8 = undefined;
    const route = std.fmt.bufPrint(&path, "/api/v1/management/profiles/{s}/rootfs/build", .{name}) catch return .{ .reachable = false, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", route, rendered, revision, reason_buf);
}

/// v0.2: 为 diskless 节点创建交付 session（POST boot-prepare）。
/// 返回 capsule 交付所需的 config_token、session_id、agent_plan_digest 等。
pub fn bootPrepareJson(io: std.Io, port: u16, node_id: []const u8, output: []u8, reason_buf: []u8) !?[]const u8 {
    if (!querySafe(node_id)) return null;
    var path: [256]u8 = undefined;
    const route = std.fmt.bufPrint(&path, "/api/v1/management/nodes/{s}/boot-prepare", .{node_id}) catch return null;
    const reply = try managementPostJson(io, port, route, "{}", null, output, null);
    if (reply.status < 200 or reply.status >= 300) {
        if (reply.body) |err_body|
            _ = formatErrorReason(reason_buf, err_body)
        else
            _ = formatHttpStatus(reason_buf, reply.status);
        return null;
    }
    return reply.body;
}

pub fn nodeReadinessJson(io: std.Io, port: u16, node_id: []const u8, stage: []const u8, output: []u8, reason_buf: []u8) !?[]const u8 {
    if (!querySafe(node_id) or !(std.mem.eql(u8, stage, "build") or std.mem.eql(u8, stage, "boot"))) return null;
    var path: [256]u8 = undefined;
    const route = std.fmt.bufPrint(&path, "/api/v1/management/nodes/{s}/readiness", .{node_id}) catch return null;
    var body: [64]u8 = undefined;
    const rendered = std.fmt.bufPrint(&body, "{{\"stage\":{f}}}", .{std.json.fmt(stage, .{})}) catch return null;
    const reply = try managementPostJson(io, port, route, rendered, null, output, null);
    if (reply.status < 200 or reply.status >= 300) {
        if (reply.body) |err_body|
            _ = formatErrorReason(reason_buf, err_body)
        else
            _ = formatHttpStatus(reason_buf, reply.status);
        return null;
    }
    return reply.body;
}

pub fn operationJson(io: std.Io, port: u16, operation_id: []const u8, output: []u8) !?[]const u8 {
    if (!querySafe(operation_id)) return null;
    var path: [256]u8 = undefined;
    const route = std.fmt.bufPrint(&path, "/api/v1/management/operations/{s}", .{operation_id}) catch return null;
    return managementJson(io, port, route, output);
}

pub fn disklessSessionsJson(io: std.Io, port: u16, session_id: ?[]const u8, output: []u8) !?[]const u8 {
    var path: [256]u8 = undefined;
    const route = if (session_id) |id| blk: {
        if (!querySafe(id)) return null;
        break :blk std.fmt.bufPrint(&path, "/api/v1/management/diskless-sessions/{s}", .{id}) catch return null;
    } else "/api/v1/management/diskless-sessions";
    return managementJson(io, port, route, output);
}

pub fn cancelDisklessSession(io: std.Io, port: u16, session_id: []const u8, output: []u8, reason_buf: []u8) !?[]const u8 {
    if (!querySafe(session_id)) return null;
    var path: [256]u8 = undefined;
    const route = std.fmt.bufPrint(&path, "/api/v1/management/diskless-sessions/{s}", .{session_id}) catch return null;
    const reply = try managementDeleteJson(io, port, route, output);
    if (reply.status < 200 or reply.status >= 300) {
        if (reply.body) |err_body| _ = formatErrorReason(reason_buf, err_body);
        return null;
    }
    return reply.body;
}

pub fn nodeAdd(io: std.Io, port: u16, body: []const u8, reason_buf: []u8) Mutation {
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", "/api/v1/management/nodes", body, revision, reason_buf);
}

pub fn nodeRemove(io: std.Io, port: u16, node_id: []const u8, reason_buf: []u8) Mutation {
    if (!querySafe(node_id)) return .{ .reachable = false, .healthy = false };
    var path: [256]u8 = undefined;
    const value = std.fmt.bufPrint(&path, "/api/v1/management/nodes/{s}", .{node_id}) catch return .{ .reachable = false, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "DELETE", value, "", revision, reason_buf);
}

pub fn nodeClaim(io: std.Io, port: u16, node_id: []const u8, mac: []const u8, arch: []const u8, observation_revision: u64, reason_buf: []u8) Mutation {
    if (!querySafe(node_id) or !querySafe(mac) or !querySafe(arch)) return .{ .reachable = false, .healthy = false };
    var path: [256]u8 = undefined;
    const value = std.fmt.bufPrint(&path, "/api/v1/management/nodes/{s}/claim", .{node_id}) catch return .{ .reachable = false, .healthy = false };
    var body: [512]u8 = undefined;
    const rendered = std.fmt.bufPrint(&body, "{{\"mac\":{f},\"arch\":{f},\"observation_revision\":{d}}}", .{ std.json.fmt(mac, .{}), std.json.fmt(arch, .{}), observation_revision }) catch return .{ .reachable = true, .healthy = false };
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "POST", value, rendered, revision, reason_buf);
}

pub fn discoveryPolicySet(io: std.Io, port: u16, body: []const u8, reason_buf: []u8) Mutation {
    const revision = catalogRevision(io, port) orelse return mutationUnreachable(reason_buf, "cannot read current catalog revision");
    return managementMutation(io, port, "PATCH", "/api/v1/management/discovery/policy", body, revision, reason_buf);
}

fn mutationUnreachable(reason_buf: []u8, message: []const u8) Mutation {
    return .{ .reachable = true, .healthy = false, .reason = formatPlain(reason_buf, "http", message) };
}

/// 执行带目标资源 ETag/If-Match 的管理变更请求。
/// M4.5 统一按 2xx 判定成功（创建类 POST 返回 201，普通变更返回 200）；
/// 失败时解析服务端错误信封 `{code,message,request_id}` 并格式化到
/// `reason_buf`，供 CLI 结构化输出（§9.14.7）。
fn managementMutation(io: std.Io, port: u16, method: []const u8, path: []const u8, body: []const u8, revision: u64, reason_buf: []u8) Mutation {
    const address = std.Io.net.IpAddress.parseIp4(management.client_ip, port) catch return .{ .reachable = false, .healthy = false };
    debugRequest(method, path, port);
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
        debugConnectFailure(port, err);
        return .{ .reachable = false, .healthy = false, .reason = formatTransportError(reason_buf, err) };
    };
    defer stream.close(io);
    var send_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    writer.interface.print("{s} {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nIf-Match: \"{d}\"\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ method, path, revision, body.len, body }) catch return .{ .reachable = true, .healthy = false };
    writer.interface.flush() catch return .{ .reachable = true, .healthy = false };
    var recv_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    var body_out: [4096]u8 = undefined;
    const reply = readHttpResponse(&reader.interface, &body_out, null) catch |err| {
        debugPrint("response_failed method={s} path={s} cause={t}", .{ method, path, err });
        return .{ .reachable = true, .healthy = false, .reason = formatTransportError(reason_buf, err) };
    };
    debugResponse(method, path, reply);
    if (reply.status >= 200 and reply.status < 300) return .{ .reachable = true, .healthy = true };
    if (reply.body) |err_body|
        return .{ .reachable = true, .healthy = false, .reason = formatErrorReason(reason_buf, err_body) };
    return .{ .reachable = true, .healthy = false, .reason = formatHttpStatus(reason_buf, reply.status) };
}

/// 把服务端错误信封格式化为 "code: message (request_id=<id>)" 写入 `out` 并
/// 返回其切片。解析失败退回通用提示；`reason` 在解析 arena `deinit` 前已写入
/// `out`，不依赖 arena 生命周期。
fn formatErrorReason(out: []u8, body: []const u8) []const u8 {
    const Envelope = struct { @"error": struct { code: []const u8, message: []const u8, request_id: ?[]const u8 = null } };
    const parsed = std.json.parseFromSlice(Envelope, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch
        return formatPlain(out, "http", "non-2xx response with unparseable body");
    defer parsed.deinit();
    const e = parsed.value.@"error";
    return std.fmt.bufPrint(out, "{s}: {s} (request_id={s})", .{ e.code, e.message, e.request_id orelse "" }) catch
        formatPlain(out, e.code, e.message);
}

fn formatPlain(out: []u8, code: []const u8, message: []const u8) []const u8 {
    return std.fmt.bufPrint(out, "{s}: {s}", .{ code, message }) catch "http: error";
}

fn formatTransportError(out: []u8, err: anyerror) []const u8 {
    return std.fmt.bufPrint(out, "http: transport error ({t})", .{err}) catch "http: transport error";
}

fn formatHttpStatus(out: []u8, status: u16) []const u8 {
    return std.fmt.bufPrint(out, "http: {d} response with no body", .{status}) catch "http: non-2xx response";
}

fn catalogRevision(io: std.Io, port: u16) ?u64 {
    var buffer: [4096]u8 = undefined;
    const maybe_body = managementJson(io, port, "/api/v1/management/config", &buffer) catch return null;
    const body = maybe_body orelse return null;
    const Response = struct { result: struct { catalog_revision: u64 } };
    const parsed = std.json.parseFromSlice(Response, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    return parsed.value.result.catalog_revision;
}

/// M4.5：HTTP 响应解析结果。`body` 在状态码不在允许集合或无 body 时为 null；
/// `location` 仅在调用方提供缓冲且响应携带 Location 头时非 null，供 202
/// Operation 轮询使用。
const HttpReply = struct {
    status: u16,
    body: ?[]const u8,
    location: ?[]const u8,
};

const no_reply: HttpReply = .{ .status = 0, .body = null, .location = null };

fn managementJson(io: std.Io, port: u16, path: []const u8, output: []u8) !?[]const u8 {
    const reply = try getReply(io, port, path, output, null);
    if (reply.status < 200 or reply.status >= 300) {
        if (reply.body) |body| debugPrint("request_rejected path={s} status={d} body_bytes={d}", .{ path, reply.status, body.len });
        return null;
    }
    return reply.body;
}

/// M4.5：POST 管理 JSON 请求并返回完整响应（状态码、body、Location）。连接
/// 失败时返回 `no_reply`（status=0、body=null，非错误），与历史行为一致；协议
/// 错误（截断、超大、不支持传输编码）以 error 传播。`location_out` 非空时
/// 捕获 Location 头，供 202 Operation 轮询使用。
fn managementPostJson(io: std.Io, port: u16, path: []const u8, body: []const u8, idempotency_key: ?[]const u8, output: []u8, location_out: ?[]u8) !HttpReply {
    const address = std.Io.net.IpAddress.parseIp4(management.client_ip, port) catch return no_reply;
    debugRequest("POST", path, port);
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
        debugConnectFailure(port, err);
        return no_reply;
    };
    defer stream.close(io);
    var send_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.print("POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n", .{path});
    if (idempotency_key) |key| try writer.interface.print("Idempotency-Key: {s}\r\n", .{key});
    try writer.interface.print("Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
    try writer.interface.flush();
    var recv_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    const reply = readHttpResponse(&reader.interface, output, location_out) catch |err| {
        debugPrint("response_failed method=POST path={s} capacity={d} cause={t}", .{ path, output.len, err });
        return err;
    };
    debugResponse("POST", path, reply);
    return reply;
}

fn managementDeleteJson(io: std.Io, port: u16, path: []const u8, output: []u8) !HttpReply {
    const address = std.Io.net.IpAddress.parseIp4(management.client_ip, port) catch return no_reply;
    debugRequest("DELETE", path, port);
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
        debugConnectFailure(port, err);
        return no_reply;
    };
    defer stream.close(io);
    var send_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.print("DELETE {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{path});
    try writer.interface.flush();
    var recv_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    const reply = readHttpResponse(&reader.interface, output, null) catch |err| {
        debugPrint("response_failed method=DELETE path={s} capacity={d} cause={t}", .{ path, output.len, err });
        return err;
    };
    debugResponse("DELETE", path, reply);
    return reply;
}

/// M4.5：GET 管理 JSON 请求并返回完整响应。与 `managementPostJson` 共享
/// `readHttpResponse`，供 202 Operation 轮询复用。
fn getReply(io: std.Io, port: u16, path: []const u8, body_out: []u8, location_out: ?[]u8) !HttpReply {
    const address = std.Io.net.IpAddress.parseIp4(management.client_ip, port) catch return no_reply;
    debugRequest("GET", path, port);
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
        debugConnectFailure(port, err);
        return no_reply;
    };
    defer stream.close(io);
    var send_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.print("GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{path});
    try writer.interface.flush();
    var recv_buffer: [16 * 1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    const reply = readHttpResponse(&reader.interface, body_out, location_out) catch |err| {
        debugPrint("response_failed method=GET path={s} capacity={d} cause={t}", .{ path, body_out.len, err });
        return err;
    };
    debugResponse("GET", path, reply);
    return reply;
}

/// 请求 daemon 导入资产并写入 catalog。
///
/// M4.5 使用 application/json body 传输完整 canonical metadata；daemon 计算
/// SHA-256，并根据 metadata+SHA 判断自然幂等。200/201 resource envelope 均为成功。
pub fn importAsset(io: std.Io, port: u16, asset: AssetImport) !bool {
    var body_writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body_writer.deinit();
    try std.json.Stringify.value(asset, .{ .emit_null_optional_fields = true }, &body_writer.writer);
    var response: [4096]u8 = undefined;
    const reply = try managementPostJson(io, port, "/api/v1/management/assets", body_writer.written(), null, &response, null);
    return reply.status >= 200 and reply.status < 300;
}

/// 请求 daemon 导入已暂存的 ISO 并发布 install source。
///
/// M3.6 安全设计：此函数只接受不透明文件名（不含路径前缀），
/// 因为 ISO 已由 CLI 复制到 daemon 管控的 import_dir。
/// daemon 在受管根内打开文件，不会接触任意 host 路径。
///
/// M4.5 使用 application/json body 和独立 Idempotency-Key header；202 只表示
/// HTTP 接受。客户端按 Location 轮询 Operation 直到 terminal，只有 succeeded
/// 才算业务成功（§9.14.4：长任务信封不随执行快慢变化）。
pub const InstallSourceImportResult = struct {
    source_name: [128]u8 = undefined,
    source_name_len: usize = 0,

    pub fn name(self: *const InstallSourceImportResult) []const u8 {
        return self.source_name[0..self.source_name_len];
    }
};

pub fn importInstallSource(io: std.Io, port: u16, request: InstallSourceImport) !?InstallSourceImportResult {
    if (!querySafe(request.filename) or request.content_sha256.len != 64 or request.idempotency_key.len == 0 or request.idempotency_key.len > 128 or !querySafe(request.idempotency_key)) return error.InvalidInstallSourceField;
    inline for ([_]?[]const u8{ request.name, request.distro, request.version, request.arch }) |optional|
        if (optional) |value|
            if (!querySafe(value)) return error.InvalidInstallSourceField;
    const Wire = struct { filename: []const u8, original_filename: []const u8, sha256: []const u8, name: ?[]const u8, distro: ?[]const u8, version: ?[]const u8, arch: ?[]const u8 };
    var body_writer: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer body_writer.deinit();
    try std.json.Stringify.value(Wire{ .filename = request.filename, .original_filename = request.original_filename, .sha256 = request.content_sha256, .name = request.name, .distro = request.distro, .version = request.version, .arch = request.arch }, .{ .emit_null_optional_fields = true }, &body_writer.writer);
    var response: [16 * 1024]u8 = undefined;
    var location: [256]u8 = undefined;
    var reply = try managementPostJson(io, port, "/api/v1/management/install-sources", body_writer.written(), request.idempotency_key, &response, &location);
    // daemon 当前同步完成，202 body 已是 terminal 状态，循环只执行一次；仅当
    // daemon 改为异步（返回 queued/running）时才按 Location 轮询 terminal 状态。
    var attempts: usize = 0;
    while (attempts < 1200) : (attempts += 1) {
        const body = reply.body orelse return null;
        switch (operationState(body) orelse return null) {
            .succeeded => return operationImportResult(body),
            .failed => return null,
            .pending => {},
        }
        const next = reply.location orelse return null;
        std.Io.sleep(io, .fromMilliseconds(50), .awake) catch {};
        reply = try getReply(io, port, next, &response, &location);
    }
    return null;
}

fn operationImportResult(body: []const u8) ?InstallSourceImportResult {
    const Envelope = struct { result: struct { result: []const u8 } };
    const parsed = std.json.parseFromSlice(Envelope, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const name = parsed.value.result.result;
    if (name.len == 0 or name.len > 128) return null;
    var result: InstallSourceImportResult = .{};
    @memcpy(result.source_name[0..name.len], name);
    result.source_name_len = name.len;
    return result;
}

/// 从 Operation 信封 `{"ok":true,"result":{"state":...}}` 提取终态判定。
/// 返回值按值拷贝，不依赖解析 arena 生命周期。
fn operationState(body: []const u8) ?OperationState {
    const Envelope = struct { result: struct { state: []const u8 } };
    const parsed = std.json.parseFromSlice(Envelope, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.result.state, "succeeded")) return .succeeded;
    if (std.mem.eql(u8, parsed.value.result.state, "failed")) return .failed;
    return .pending;
}

const OperationState = enum { succeeded, failed, pending };

/// 检查 canonical path/header token。M4.5 不再用它拼接资产导入 query；这里只
/// 保护 node/name path segment、digest 和 Idempotency-Key header。
fn querySafe(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfAny(u8, value, "&=?#%\r\n") == null;
}

/// M4.5：始终读取响应 body（成功与错误信封都需要），让调用方按 `status`
/// 判定成功与否并解析错误信封。204 或 Content-Length: 0 给空 body；其余必须
/// 有 Content-Length，避免截断/无界响应被误判。`location_out` 非空时捕获
/// Location 头供 202 Operation 轮询使用。
fn readHttpResponse(reader: *std.Io.Reader, output: []u8, location_out: ?[]u8) !HttpReply {
    const status_line = reader.takeDelimiterInclusive('\n') catch return error.TruncatedResponse;
    const first_space = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.InvalidHttpResponse;
    if (first_space + 4 > status_line.len) return error.InvalidHttpResponse;
    const status = std.fmt.parseInt(u16, status_line[first_space + 1 .. first_space + 4], 10) catch return error.InvalidHttpResponse;
    var content_length: ?usize = null;
    var location: ?[]const u8 = null;
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch return error.TruncatedResponse;
        if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
        if (std.ascii.startsWithIgnoreCase(line, "transfer-encoding:")) return error.UnsupportedTransferEncoding;
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " \t\r\n");
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidHttpResponse;
        } else if (location_out) |buf| if (std.ascii.startsWithIgnoreCase(line, "location:")) {
            const value = std.mem.trim(u8, line["location:".len..], " \t\r\n");
            if (value.len <= buf.len) {
                @memcpy(buf[0..value.len], value);
                location = buf[0..value.len];
            }
        };
    }
    const length = content_length orelse if (status == 204) @as(usize, 0) else return error.MissingContentLength;
    if (length > output.len) {
        debugPrint("response_too_large content_length={d} capacity={d}", .{ length, output.len });
        return error.ResponseTooLarge;
    }
    if (length == 0) return .{ .status = status, .body = output[0..0], .location = location };
    reader.readSliceAll(output[0..length]) catch return error.TruncatedResponse;
    return .{ .status = status, .body = output[0..length], .location = location };
}

test "bounded response reader handles multiline and protocol failures" {
    var source: std.Io.Reader = .fixed("HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n{\n\"x\":1}");
    var output: [32]u8 = undefined;
    try std.testing.expectEqualStrings("{\n\"x\":1}", (try readHttpResponse(&source, &output, null)).body.?);
    var chunked: std.Io.Reader = .fixed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n");
    try std.testing.expectError(error.UnsupportedTransferEncoding, readHttpResponse(&chunked, &output, null));
    var truncated: std.Io.Reader = .fixed("HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\nshort");
    try std.testing.expectError(error.TruncatedResponse, readHttpResponse(&truncated, &output, null));
}

test "debug diagnostics include bounded JSON failure context" {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    configureDiagnostics(&writer);
    defer configureDiagnostics(null);

    reportJsonFailure("NodeListPage", error.UnexpectedToken, "{\nsecret-control");
    const rendered = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, "type=NodeListPage") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "cause=UnexpectedToken") != null);
    // 原始换行必须被 JSON 转义，保证每条 debug 记录保持单行。
    try std.testing.expect(std.mem.indexOf(u8, rendered, "{\\nsecret-control") != null);
}

test "bounded response reader honors caller capacity above 150 KiB" {
    const body_len = 160 * 1024;
    var response: [body_len + 64]u8 = undefined;
    const header = try std.fmt.bufPrint(&response, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{body_len});
    @memset(response[header.len .. header.len + body_len], 'x');
    var source: std.Io.Reader = .fixed(response[0 .. header.len + body_len]);
    var output: [body_len]u8 = undefined;
    const reply = try readHttpResponse(&source, &output, null);
    try std.testing.expectEqual(body_len, reply.body.?.len);
    try std.testing.expectEqual(@as(u8, 'x'), reply.body.?[body_len - 1]);
}

test "readHttpResponse handles 204 empty body and captures Location" {
    var output: [16]u8 = undefined;
    var loc: [80]u8 = undefined;
    var empty: std.Io.Reader = .fixed("HTTP/1.1 204 No Content\r\n\r\n");
    const reply = try readHttpResponse(&empty, &output, &loc);
    try std.testing.expectEqual(@as(u16, 204), reply.status);
    try std.testing.expectEqualStrings("", reply.body.?);
    var with_loc: std.Io.Reader = .fixed("HTTP/1.1 202 Accepted\r\nLocation: /api/v1/management/operations/abc\r\nContent-Length: 2\r\n\r\n{}");
    const accepted = try readHttpResponse(&with_loc, &output, &loc);
    try std.testing.expectEqual(@as(u16, 202), accepted.status);
    try std.testing.expectEqualStrings("/api/v1/management/operations/abc", accepted.location.?);
}

test "formatErrorReason renders code/message/request_id from error envelope" {
    var out: [256]u8 = undefined;
    const body = "{\"ok\":false,\"error\":{\"code\":\"asset.name_conflict\",\"message\":\"asset name already identifies different canonical metadata\",\"request_id\":\"0000000000000000000000000000000a\"}}\n";
    try std.testing.expectEqualStrings("asset.name_conflict: asset name already identifies different canonical metadata (request_id=0000000000000000000000000000000a)", formatErrorReason(&out, body));
    try std.testing.expectEqualStrings("http.bad: oops (request_id=)", formatErrorReason(&out, "{\"ok\":false,\"error\":{\"code\":\"http.bad\",\"message\":\"oops\"}}"));
    try std.testing.expectEqualStrings("http: non-2xx response with unparseable body", formatErrorReason(&out, "not json"));
}

test "operationState parses terminal and pending states" {
    try std.testing.expectEqual(OperationState.succeeded, operationState("{\"ok\":true,\"result\":{\"state\":\"succeeded\"}}").?);
    try std.testing.expectEqual(OperationState.failed, operationState("{\"ok\":true,\"result\":{\"state\":\"failed\"}}").?);
    try std.testing.expectEqual(OperationState.pending, operationState("{\"ok\":true,\"result\":{\"state\":\"running\"}}").?);
    try std.testing.expect(operationState("not json") == null);
    const imported = operationImportResult("{\"ok\":true,\"result\":{\"state\":\"succeeded\",\"result\":\"rocky-9.7-aarch64-iso\"}}").?;
    try std.testing.expectEqualStrings("rocky-9.7-aarch64-iso", imported.name());
}

/// 向指定 IPv4:port 发送轻量探针并严格解析三位状态码。
/// 完整管理响应由 `readHttpResponse` 读取；探针无须保留 headers/body。
/// 收发缓冲区在栈上分配，函数返回后自动释放。
/// 返回的 `Status` 区分 TCP 连接可达性（`reachable`）和 HTTP 2xx 响应（`healthy`）。
/// 接受所有 2xx 状态码：GET 探测通常返回 200，POST 创建类端点返回 201。
fn probeAt(io: std.Io, ip: []const u8, port: u16, path: []const u8, method: []const u8) Status {
    const address = std.Io.net.IpAddress.parseIp4(ip, port) catch
        return .{ .reachable = false, .healthy = false };
    var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch
        return .{ .reachable = false, .healthy = false };
    defer stream.close(io);

    var send_buffer: [512]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    writer.interface.print(
        "{s} {s} HTTP/1.1\r\nHost: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        .{ method, path, ip },
    ) catch return .{ .reachable = true, .healthy = false };
    writer.interface.flush() catch return .{ .reachable = true, .healthy = false };

    var recv_buffer: [2048]u8 = undefined;
    // 管理探针必须有真实 I/O 上限。只在两次尝试之间 sleep 不能约束
    // 已建立但不响应的 TCP peer；systemd readiness 曾因此远超声明的 5 秒。
    const incoming = stream.socket.receiveTimeout(io, &recv_buffer, .{
        .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake },
    }) catch
        return .{ .reachable = true, .healthy = false };
    return .{
        .reachable = true,
        .healthy = is2xx(incoming.data),
    };
}

/// 检查 HTTP 状态行中的状态码是否为 2xx（成功）。
/// HTTP 状态行格式："HTTP/1.1 200 OK\r\n"，状态码为首个空格后的 3 位数字。
fn is2xx(status_line: []const u8) bool {
    const space = std.mem.indexOfScalar(u8, status_line, ' ') orelse return false;
    if (space + 4 > status_line.len) return false;
    return status_line[space + 1] == '2' and
        std.ascii.isDigit(status_line[space + 2]) and
        std.ascii.isDigit(status_line[space + 3]);
}

test "status distinguishes reachability and health" {
    const status: Status = .{ .reachable = true, .healthy = false };
    try std.testing.expect(status.reachable);
    try std.testing.expect(!status.healthy);
}

test "is2xx accepts 200, 201, 202 and rejects others" {
    try std.testing.expect(is2xx("HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(is2xx("HTTP/1.1 201 Created\r\n"));
    try std.testing.expect(is2xx("HTTP/1.1 202 Accepted\r\n"));
    try std.testing.expect(is2xx("HTTP/1.1 204 No Content\r\n"));
    try std.testing.expect(!is2xx("HTTP/1.1 301 Moved\r\n"));
    try std.testing.expect(!is2xx("HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expect(!is2xx("HTTP/1.1 500 Error\r\n"));
    try std.testing.expect(!is2xx("bad"));
}
