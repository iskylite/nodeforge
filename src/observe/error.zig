//! 面向 CLI 和管理 HTTP 的稳定错误信封。
//! 内部 Zig error 不能直接成为外部协议；这里集中定义 code、message、hint 三个字段。
//! 本模块只做格式化，不包含业务逻辑或错误分类策略。

const std = @import("std");

pub const Problem = struct {
    /// 稳定错误码，例如 `config.invalid`；客户端据此分支处理。
    code: []const u8,
    /// 人类可读的错误详情，通常包含具体对象名或字段。
    message: []const u8,
    /// 可选的修复建议；为 null 时不输出 hint 字段。
    hint: ?[]const u8 = null,
};

pub const Response = struct {
    /// 固定为 false；错误响应的 `ok` 字段始终为 false。
    ok: bool = false,
    /// 错误详情信封。
    @"error": Problem,
};

/// 把配置校验错误转换成稳定错误码；详细类型保留在 message 中便于定位。
pub fn fromValidation(err: anyerror) Problem {
    return .{
        .code = switch (err) {
            error.InvalidKernelArgs => "profile.kernel_args_invalid",
            error.KernelArgsRequiresBootloader => "profile.kernel_args_requires_bootloader",
            else => "config.invalid",
        },
        .message = @errorName(err),
        .hint = "run nodeforge config validate and correct the referenced object",
    };
}

/// 将错误信封写入调用方固定缓冲区，返回的切片借用该缓冲区。
pub fn renderJson(buffer: []u8, problem: Problem) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try std.json.Stringify.value(Response{ .@"error" = problem }, .{}, &writer);
    try writer.writeByte('\n');
    return writer.buffered();
}

test "错误响应是可解析 JSON" {
    var buffer: [512]u8 = undefined;
    const bytes = try renderJson(&buffer, fromValidation(error.MissingAsset));
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings(
        "config.invalid",
        parsed.value.object.get("error").?.object.get("code").?.string,
    );
}

test "M4.6 kernel args validation errors have stable field codes" {
    try std.testing.expectEqualStrings("profile.kernel_args_invalid", fromValidation(error.InvalidKernelArgs).code);
    try std.testing.expectEqualStrings("profile.kernel_args_requires_bootloader", fromValidation(error.KernelArgsRequiresBootloader).code);
}
