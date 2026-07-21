//! M4.5 centralized HTTP route contract registry.
const std = @import("std");

pub const Plane = enum { health, node, management, artifact };
pub const Auth = enum { none, node_session, loopback };
pub const Cache = enum { no_store, immutable };
pub const Log = enum { health, api, artifact };

pub const RouteSpec = struct {
    method: []const u8,
    template: []const u8,
    plane: Plane,
    auth: Auth,
    cache: Cache,
    log: Log,
    /// Dispatch symbol is kept in the registry contract even though Zap's
    /// callback invokes the typed server handler after matching.
    handler: []const u8 = "server.route",
};

pub const specs = [_]RouteSpec{
    .{ .method = "GET", .template = "/healthz", .plane = .health, .auth = .none, .cache = .no_store, .log = .health },
    .{ .method = "GET", .template = "/api/v1/nodes/:id/boot-config", .plane = .node, .auth = .node_session, .cache = .no_store, .log = .api },
    .{ .method = "HEAD", .template = "/api/v1/nodes/:id/boot-config", .plane = .node, .auth = .node_session, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/nodes/:id/install-config/*", .plane = .node, .auth = .node_session, .cache = .no_store, .log = .api },
    .{ .method = "HEAD", .template = "/api/v1/nodes/:id/install-config/*", .plane = .node, .auth = .node_session, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/nodes/:id/events", .plane = .node, .auth = .node_session, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/nodes/:id/logs", .plane = .node, .auth = .node_session, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/nodes/:id/facts", .plane = .node, .auth = .node_session, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/nodes/:id/installer-hooks/subiquity", .plane = .node, .auth = .node_session, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/artifacts/images/:name", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
    .{ .method = "HEAD", .template = "/artifacts/images/:name", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
    .{ .method = "GET", .template = "/artifacts/managed-files/:name/:revision", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
    .{ .method = "HEAD", .template = "/artifacts/managed-files/:name/:revision", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
    .{ .method = "GET", .template = "/artifacts/repositories/:name/*", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
    .{ .method = "HEAD", .template = "/artifacts/repositories/:name/*", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
    .{ .method = "GET", .template = "/artifacts/boot/*", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
    .{ .method = "HEAD", .template = "/artifacts/boot/*", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
    .{ .method = "GET", .template = "/api/v1/management/status", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/config", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/config/validations", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/nodes", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/nodes", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/nodes/:id", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/nodes/:id/values", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/nodes/:id/values", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/nodes/:id/items", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/nodes/:id/items", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/nodes/:id/capabilities", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/nodes/:id/properties", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "DELETE", .template = "/api/v1/management/nodes/:id", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/nodes/:id/install-generations", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/nodes/:id/claim", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/discovery/observations", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/discovery/observations/:mac", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/discovery/policy", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "PATCH", .template = "/api/v1/management/discovery/policy", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/profiles", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/profiles", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/profiles/:name", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/profiles/:name/values", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/profiles/:name/values", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/profiles/:name/items", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/profiles/:name/items", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/profiles/:name/capabilities", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/profiles/:name/properties", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/assets", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/assets", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/assets/:name", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/assets/provision-bundles", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/assets/provision-bundles", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/assets/provision-bundles/:name", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "DELETE", .template = "/api/v1/management/assets/provision-bundles/:name", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/assets/provision-bundles/:name/items", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/assets/provision-bundles/:name/items", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "DELETE", .template = "/api/v1/management/assets/managed-files/:name", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/install-sources", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/install-sources", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/install-sources/:name", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/install-sources/:name/software", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/repositories", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/repositories/:name", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/repositories/:name/software", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/profiles/:name/software/available", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/operations", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/operations/:id", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/catalog/migration-plans", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/catalog/migrations", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/catalog/schema-v3/migration-plans", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/catalog/schema-v3/migrations", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "POST", .template = "/api/v1/management/catalog/schema-v3/rollbacks", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/runtime", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/runtime/tftp", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/runtime/tftp/sessions", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
    .{ .method = "GET", .template = "/api/v1/management/runtime/dhcp/leases", .plane = .management, .auth = .loopback, .cache = .no_store, .log = .api },
};

pub fn pathMatches(template: []const u8, path: []const u8) bool {
    var ti: usize = 0;
    var pi: usize = 0;
    while (ti < template.len and pi < path.len) {
        if (template[ti] == '*') return ti + 1 == template.len and pi < path.len;
        if (template[ti] == ':') {
            while (ti < template.len and template[ti] != '/') : (ti += 1) {}
            const start = pi;
            while (pi < path.len and path[pi] != '/') : (pi += 1) {}
            if (pi == start or std.mem.indexOfScalar(u8, path[start..pi], '%') != null) return false;
            continue;
        }
        if (template[ti] != path[pi]) return false;
        ti += 1;
        pi += 1;
    }
    return ti == template.len and pi == path.len;
}

pub fn allowed(path: []const u8, output: []u8) ?[]const u8 {
    var writer: std.Io.Writer = .fixed(output);
    var first = true;
    for (specs) |spec| if (pathMatches(spec.template, path)) {
        if (!first) writer.writeAll(", ") catch return null;
        writer.writeAll(spec.method) catch return null;
        first = false;
    };
    return if (first) null else writer.buffered();
}

/// 精确判断某个 method 是否注册于该路径。不能在 `Allow` 文本中做子串
/// 搜索，否则 `ET` 会被误认为匹配 `GET`。
pub fn methodAllowed(path: []const u8, method: []const u8) bool {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.method, method) and pathMatches(spec.template, path)) return true;
    }
    return false;
}

/// 启动时检测等价模板、重复 method 和 wildcard 吞路由冲突。存在任一冲突
/// 即拒绝启动（§9.14.11.1#1）。`detectConflicts` 接受任意 spec 列表，便于单测。
pub fn validate() !void {
    try detectConflicts(&specs);
}

fn detectConflicts(list: []const RouteSpec) !void {
    for (list, 0..) |left, i| for (list[i + 1 ..]) |right| {
        if (!std.mem.eql(u8, left.method, right.method)) continue;
        if (equivalentTemplate(left.template, right.template)) return error.DuplicateRoute;
        // wildcard 吞路由：`/a/*` 会让同 method 的 `/a/b`、`/a/b/c` 永远不可达。
        if (wildcardSwallows(left.template, right.template) or
            wildcardSwallows(right.template, left.template)) return error.WildcardSwallowsRoute;
    };
}

/// `wildcard` 以 `/*` 结尾时，其前缀（去掉末尾 `*`）若是 `other` 的前缀，
/// 则 wildcard 会吞掉 other（other 永远不可达）。
fn wildcardSwallows(wildcard: []const u8, other: []const u8) bool {
    if (!std.mem.endsWith(u8, wildcard, "/*")) return false;
    if (std.mem.eql(u8, wildcard, other)) return false;
    const prefix = wildcard[0 .. wildcard.len - 1]; // 保留末尾 '/'
    return std.mem.startsWith(u8, other, prefix);
}

test "detectConflicts flags wildcard that shadows a sibling route" {
    const shadowed = [_]RouteSpec{
        .{ .method = "GET", .template = "/x/*", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
        .{ .method = "GET", .template = "/x/b", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
    };
    try std.testing.expectError(error.WildcardSwallowsRoute, detectConflicts(&shadowed));
    // 不同 method 不算吞路由（PUT /x/b 与 GET /x/* 可共存）。
    const different_method = [_]RouteSpec{
        .{ .method = "GET", .template = "/x/*", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
        .{ .method = "PUT", .template = "/x/b", .plane = .artifact, .auth = .none, .cache = .immutable, .log = .artifact },
    };
    try detectConflicts(&different_method);
    // 真实 registry 不得有吞路由冲突。
    try detectConflicts(&specs);
}

fn equivalentTemplate(left: []const u8, right: []const u8) bool {
    var li = std.mem.splitScalar(u8, left, '/');
    var ri = std.mem.splitScalar(u8, right, '/');
    while (true) {
        const l = li.next();
        const r = ri.next();
        if (l == null or r == null) return l == null and r == null;
        const dynamic_l = l.?.len != 0 and (l.?[0] == ':' or l.?[0] == '*');
        const dynamic_r = r.?.len != 0 and (r.?[0] == ':' or r.?[0] == '*');
        if (dynamic_l != dynamic_r) return false;
        if (dynamic_l) {
            if ((l.?[0] == '*') != (r.?[0] == '*')) return false;
        } else if (!std.mem.eql(u8, l.?, r.?)) return false;
    }
}

test "registry matches templates and aggregates Allow" {
    try validate();
    try std.testing.expect(pathMatches("/nodes/:id/events", "/nodes/n1/events"));
    try std.testing.expect(!pathMatches("/nodes/:id/events", "/nodes/n1/logs"));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("GET, POST", allowed("/api/v1/management/nodes", &buffer).?);
    try std.testing.expect(equivalentTemplate("/nodes/:id", "/nodes/:name"));
}

test "every RouteSpec declares known method, absolute template and plane-consistent auth/cache" {
    const known_methods = [_][]const u8{ "GET", "HEAD", "POST", "PATCH", "DELETE" };
    try validate();
    for (specs) |spec| {
        // 模板必须是绝对路径，方法是受控词汇表之一。
        try std.testing.expect(spec.template.len > 0 and spec.template[0] == '/');
        var method_ok = false;
        for (known_methods) |m| if (std.mem.eql(u8, m, spec.method)) {
            method_ok = true;
            break;
        };
        try std.testing.expect(method_ok);
        // M4.4 安全边界钉到契约层：管理平面只接受 loopback，节点交付需要
        // node_session，健康/制品无认证。管理/节点响应不得被中间缓存。
        switch (spec.plane) {
            .management => try std.testing.expectEqual(Auth.loopback, spec.auth),
            .node => try std.testing.expectEqual(Auth.node_session, spec.auth),
            .health, .artifact => try std.testing.expectEqual(Auth.none, spec.auth),
        }
        switch (spec.plane) {
            .management, .node, .health => try std.testing.expectEqual(Cache.no_store, spec.cache),
            .artifact => try std.testing.expectEqual(Cache.immutable, spec.cache),
        }
    }
}

test "Allow aggregation reflects registered methods for detail and collection paths" {
    var buffer: [64]u8 = undefined;
    // M4.9：startup config 只提供只读摘要；正式写入口属于 setup。
    try std.testing.expectEqualStrings("GET", allowed("/api/v1/management/config", &buffer).?);
    try std.testing.expect(methodAllowed("/api/v1/management/config", "GET"));
    try std.testing.expect(!methodAllowed("/api/v1/management/config", "PATCH"));
    try std.testing.expect(!methodAllowed("/api/v1/management/config", "ET"));
    try std.testing.expect(!methodAllowed("/api/v1/management/config", "POST"));
    // 资产 detail 只注册了 GET，PUT/DELETE 应得到 405 + Allow: GET。
    try std.testing.expectEqualStrings("GET", allowed("/api/v1/management/assets/rocky-kernel", &buffer).?);
    // v3 profile detail is read-only; canonical mutations use /properties,
    // /values, and /items subresources.
    try std.testing.expectEqualStrings("GET", allowed("/api/v1/management/profiles/rocky-install", &buffer).?);
    try std.testing.expectEqualStrings("POST", allowed("/api/v1/management/profiles/rocky-install/properties", &buffer).?);
    try std.testing.expectEqualStrings("GET, PATCH", allowed("/api/v1/management/discovery/policy", &buffer).?);
    try std.testing.expectEqualStrings("GET", allowed("/api/v1/management/discovery/observations/02:00:00:00:00:01", &buffer).?);
    try std.testing.expectEqualStrings("POST", allowed("/api/v1/management/nodes/node-01/claim", &buffer).?);
    // 真正不存在的路径返回 null（404），而非空 Allow。
    try std.testing.expect(allowed("/api/v1/management/never-registered", &buffer) == null);
}
