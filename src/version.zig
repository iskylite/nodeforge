//! NodeForge 版本与构建溯源信息，由 build.zig 注入并由两个二进制共享。

const options = @import("build_options");

/// CLI 和 daemon 共享的 SemVer 版本字符串。
pub const version = options.version;
pub const git_commit = options.git_commit;
pub const git_dirty = options.git_dirty;
pub const build_time = options.build_time;

pub fn shortCommit() []const u8 {
    return git_commit[0..@min(git_commit.len, 12)];
}
