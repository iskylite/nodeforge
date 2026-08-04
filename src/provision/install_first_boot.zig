//! Generation-bound install first-boot target runtime.

const std = @import("std");
const dto = @import("../http/first_boot_dto.zig");
const asset_validate = @import("../assets/validate.zig");
const diskless_dto = @import("../http/diskless_dto.zig");
const first_boot = @import("first_boot.zig");
const dhcp_store = @import("../state/dhcp_store.zig");

pub const root = "/var/lib/nodeforge/install-firstboot";
pub const current_generation_path = root ++ "/current-generation";
pub const bootstrap_token_path = "/var/lib/nodeforge/credentials/first-boot.token";

pub const Identity = struct {
    schema_version: u32 = 1,
    node_id: []const u8,
    install_generation: u64,
    first_boot_plan_digest: []const u8,
};

pub const LocalState = enum {
    pending,
    started,
    step_running,
    completed_pending_ack,
    completed_acknowledged,
    failed_pending_ack,
    failed_acknowledged,
    recovery_incomplete,
};

pub const LocalJournal = struct {
    schema_version: u32 = 1,
    deployment_id: []const u8,
    node_id: []const u8,
    install_generation: u64,
    bundle_revision: u64,
    first_boot_plan_digest: []const u8,
    state: LocalState = .pending,
    next_step: usize = 0,
    running_step: ?usize = null,
    terminal_event_id: ?[]const u8 = null,
    terminal_event_body: ?[]const u8 = null,

    pub fn validateBinding(self: LocalJournal, plan: dto.InstallFirstBootPlan) !void {
        if (self.schema_version != 1 or
            !std.mem.eql(u8, self.deployment_id, plan.deployment_id) or
            !std.mem.eql(u8, self.node_id, plan.node_id) or
            self.install_generation != plan.install_generation or
            self.bundle_revision != plan.bundle_revision or
            !std.mem.eql(u8, self.first_boot_plan_digest, plan.first_boot_plan_digest) or
            self.next_step > plan.steps.len)
            return error.InstallFirstBootJournalMismatch;
    }

    pub fn begin(self: *LocalJournal) !void {
        if (self.state != .pending) return error.InstallFirstBootStateConflict;
        self.state = .started;
    }

    pub fn beginStep(self: *LocalJournal, index: usize) !void {
        if (self.state != .started or index != self.next_step) return error.InstallFirstBootStateConflict;
        self.state = .step_running;
        self.running_step = index;
    }

    pub fn completeStep(self: *LocalJournal, index: usize) !void {
        if (self.state != .step_running or self.running_step == null or self.running_step.? != index) return error.InstallFirstBootStateConflict;
        self.next_step += 1;
        self.running_step = null;
        self.state = .started;
    }

    pub fn failStep(self: *LocalJournal, index: usize) !void {
        if (self.state != .step_running or self.running_step == null or self.running_step.? != index) return error.InstallFirstBootStateConflict;
        self.running_step = null;
        self.state = .started;
    }

    pub fn terminal(self: *LocalJournal, success: bool, event_id: []const u8, body: []const u8) !void {
        if (self.state != .started or event_id.len == 0 or body.len == 0) return error.InstallFirstBootStateConflict;
        if (success and self.next_step == 0) return error.InstallFirstBootStateConflict;
        self.state = if (success) .completed_pending_ack else .failed_pending_ack;
        self.terminal_event_id = event_id;
        self.terminal_event_body = body;
    }

    pub fn acknowledge(self: *LocalJournal) !void {
        self.state = switch (self.state) {
            .completed_pending_ack => .completed_acknowledged,
            .failed_pending_ack => .failed_acknowledged,
            else => return error.InstallFirstBootStateConflict,
        };
    }

    pub fn actionsAllowed(self: LocalJournal) bool {
        return switch (self.state) {
            .pending, .started, .step_running => true,
            .completed_pending_ack, .completed_acknowledged, .failed_pending_ack, .failed_acknowledged, .recovery_incomplete => false,
        };
    }
};

pub const VerifiedPlan = struct {
    parsed: std.json.Parsed(dto.InstallFirstBootPlan),

    pub fn deinit(self: *VerifiedPlan) void {
        self.parsed.deinit();
    }

    pub fn value(self: *const VerifiedPlan) *const dto.InstallFirstBootPlan {
        return &self.parsed.value;
    }
};

pub fn parseAndVerifyPlan(allocator: std.mem.Allocator, bytes: []const u8, expected_node: []const u8, expected_generation: u64) !VerifiedPlan {
    if (bytes.len == 0 or bytes.len > dto.max_plan_bytes) return error.InvalidInstallFirstBootPlan;
    var parsed = std.json.parseFromSlice(dto.InstallFirstBootPlan, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch return error.InvalidInstallFirstBootPlan;
    errdefer parsed.deinit();
    try dto.validate(parsed.value);
    if (!std.mem.eql(u8, parsed.value.node_id, expected_node) or parsed.value.install_generation != expected_generation) return error.InstallFirstBootBindingMismatch;
    const digest = try dto.digest(allocator, parsed.value);
    if (!std.crypto.timing_safe.eql([64]u8, digest, parsed.value.first_boot_plan_digest[0..64].*)) return error.InstallFirstBootDigestMismatch;
    if (!std.mem.eql(u8, parsed.value.delivery_digest, parsed.value.first_boot_plan_digest)) return error.InstallFirstBootDigestMismatch;
    return .{ .parsed = parsed };
}

pub fn parseIdentity(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Identity) {
    const parsed = std.json.parseFromSlice(Identity, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch return error.InvalidInstallFirstBootIdentity;
    errdefer parsed.deinit();
    if (parsed.value.schema_version != 1 or parsed.value.node_id.len == 0 or parsed.value.install_generation == 0 or parsed.value.first_boot_plan_digest.len != 64) return error.InvalidInstallFirstBootIdentity;
    for (parsed.value.first_boot_plan_digest) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidInstallFirstBootIdentity;
    return parsed;
}

pub fn persistJournal(io: std.Io, allocator: std.mem.Allocator, path: []const u8, journal: LocalJournal) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, journal, .{});
    defer allocator.free(bytes);
    try dhcp_store.atomicWrite(io, path, bytes);
}

pub fn atomicWriteCredential(io: std.Io, path: []const u8, token: []const u8) !void {
    if (token.len != 64) return error.InvalidCredential;
    for (token) |byte| if (!std.ascii.isHex(byte)) return error.InvalidCredential;
    const dir = std.Io.Dir.cwd();
    const temp = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tmp", .{path});
    defer std.heap.page_allocator.free(temp);
    errdefer dir.deleteFile(io, temp) catch {};
    {
        var file = try dir.createFile(io, temp, .{ .truncate = true, .permissions = @enumFromInt(0o400) });
        defer file.close(io);
        try file.writeStreamingAll(io, token);
        try file.writeStreamingAll(io, "\n");
        try file.sync(io);
    }
    try std.Io.Dir.rename(dir, temp, dir, path, io);
    try dhcp_store.syncParentDirectory(io, path);
}

pub fn removeCredential(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().deleteFile(io, path);
    try dhcp_store.syncParentDirectory(io, path);
}

pub fn validatePayloadClosure(io: std.Io, base_dir: []const u8, plan: dto.InstallFirstBootPlan) !void {
    for (plan.payloads) |payload| {
        asset_validate.validateRelativePath(payload.path) catch return error.InvalidInstallFirstBootPayload;
        var relative_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const relative = std.fmt.bufPrint(&relative_buffer, "payload/{s}", .{payload.path}) catch return error.InvalidInstallFirstBootPayload;
        const full = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ base_dir, relative });
        defer std.heap.page_allocator.free(full);
        const stat = std.Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false }) catch return error.InvalidInstallFirstBootPayload;
        if (stat.kind != .file or stat.size != payload.size) return error.InvalidInstallFirstBootPayload;
        var digest: [64]u8 = undefined;
        asset_validate.sha256File(io, base_dir, relative, &digest) catch return error.InvalidInstallFirstBootPayload;
        if (!std.crypto.timing_safe.eql([64]u8, digest, payload.sha256[0..64].*)) return error.InvalidInstallFirstBootPayload;
    }
}

pub fn orderedStepIndices(allocator: std.mem.Allocator, steps: []const dto.Step) ![]usize {
    const indices = try allocator.alloc(usize, steps.len);
    errdefer allocator.free(indices);
    var count: usize = 0;
    const order = [_]diskless_dto.FirstBootAction{ .managed_file, .package, .archive, .script };
    for (order) |action| for (steps, 0..) |step, index| if (step.action == action) {
        indices[count] = index;
        count += 1;
    };
    if (count != steps.len) return error.InvalidInstallFirstBootPlan;
    return indices;
}

pub fn renderStepCommand(allocator: std.mem.Allocator, generation_dir: []const u8, plan: dto.InstallFirstBootPlan, step: dto.Step) ![]u8 {
    const payload_root = try std.fmt.allocPrint(allocator, "{s}/payload", .{generation_dir});
    defer allocator.free(payload_root);
    const projected: diskless_dto.FirstBootStep = .{
        .id = step.id,
        .idempotency_key = step.idempotency_key,
        .timeout_s = step.timeout_s,
        .retryable = step.retryable,
        .action = step.action,
        .content = step.content,
        .payload_path = step.payload_path,
        .destination = step.destination,
        .mode = step.mode,
        .owner = step.owner,
        .group = step.group,
        .packages = step.packages,
    };
    var command: std.Io.Writer.Allocating = .init(allocator);
    errdefer command.deinit();
    try first_boot.renderStepAtPayloadRoot(&command.writer, projected, plan.package_manager, plan.repository_urls, false, null, payload_root);
    return command.toOwnedSlice();
}

test "install first-boot parser rejects identity and digest drift" {
    var plan: dto.InstallFirstBootPlan = .{
        .deployment_id = "0123456789abcdef0123456789abcdef",
        .node_id = "n1",
        .install_generation = 7,
        .desired_plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .delivery_digest = "0000000000000000000000000000000000000000000000000000000000000000",
        .bundle_revision = 1,
        .first_boot_plan_digest = "0000000000000000000000000000000000000000000000000000000000000000",
        .event_url = "http://192.0.2.1/events",
        .exchange_url = "http://192.0.2.1/exchange",
        .expires_at = 100,
    };
    const digest = try dto.digest(std.testing.allocator, plan);
    plan.delivery_digest = digest[0..];
    plan.first_boot_plan_digest = digest[0..];
    const bytes = try dto.render(std.testing.allocator, plan);
    defer std.testing.allocator.free(bytes);
    var verified = try parseAndVerifyPlan(std.testing.allocator, bytes, "n1", 7);
    verified.deinit();
    try std.testing.expectError(error.InstallFirstBootBindingMismatch, parseAndVerifyPlan(std.testing.allocator, bytes, "n2", 7));
    var tampered = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(tampered);
    const needle = std.mem.indexOf(u8, tampered, "\"node_id\":\"n1\"").?;
    tampered[needle + "\"node_id\":\"".len] = 'x';
    try std.testing.expectError(error.InstallFirstBootBindingMismatch, parseAndVerifyPlan(std.testing.allocator, tampered, "n1", 7));
}

test "terminal local journal cannot execute actions after reboot" {
    var journal: LocalJournal = .{
        .deployment_id = "0123456789abcdef0123456789abcdef",
        .node_id = "n1",
        .install_generation = 7,
        .bundle_revision = 3,
        .first_boot_plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    };
    try journal.begin();
    try journal.beginStep(0);
    try journal.completeStep(0);
    try journal.terminal(true, "terminal-7", "{\"event\":\"first_boot.succeeded\"}");
    try std.testing.expect(!journal.actionsAllowed());
    try std.testing.expectError(error.InstallFirstBootStateConflict, journal.beginStep(1));
    try journal.acknowledge();
    try std.testing.expectEqual(LocalState.completed_acknowledged, journal.state);
    try std.testing.expect(!journal.actionsAllowed());
}

test "install steps compile in canonical order against generation payload" {
    const steps = [_]dto.Step{
        .{ .id = "script", .idempotency_key = "script", .timeout_s = 30, .retryable = false, .action = .script, .payload_path = "script/1" },
        .{ .id = "file", .idempotency_key = "file", .timeout_s = 30, .retryable = false, .action = .managed_file, .payload_path = "file/1", .destination = "/etc/motd" },
    };
    const indices = try orderedStepIndices(std.testing.allocator, &steps);
    defer std.testing.allocator.free(indices);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0 }, indices);
    const plan: dto.InstallFirstBootPlan = .{
        .deployment_id = "0123456789abcdef0123456789abcdef",
        .node_id = "n1",
        .install_generation = 7,
        .desired_plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .delivery_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .bundle_revision = 1,
        .first_boot_plan_digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .steps = &steps,
        .agent_url = "http://192.0.2.1/agent",
        .agent_size = 1,
        .agent_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .event_url = "http://192.0.2.1/events",
        .exchange_url = "http://192.0.2.1/exchange",
        .expires_at = 100,
    };
    const command = try renderStepCommand(std.testing.allocator, "/var/lib/nodeforge/install-firstboot/7", plan, steps[0]);
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("sh '/var/lib/nodeforge/install-firstboot/7/payload/script/1'", command);
}
