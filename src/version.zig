//! # NodeForge 版本与构建溯源信息
//!
//! 由 `build.zig` 在编译期注入，CLI（`nodeforge`）和 daemon（`nodeforged`）共享同一组值。
//! `--version` 输出格式为 `nodeforge <version> (<short_commit><dirty>) built <build_time>`。

const options = @import("build_options");

/// CLI 和 daemon 共享的 SemVer 版本字符串（如 `0.1.3`）。
/// 来源：`build.zig` 中的 `build_options.addOption("version", ...)`。
pub const version = options.version;

/// 编译时 `git rev-parse HEAD` 的完整 40 字符 commit hash。
/// 用于版本溯源和安装计划 digest 关联。
pub const git_commit = options.git_commit;

/// 编译时工作区是否有未提交变更（`git status --porcelain`）。
/// true 表示该构建包含未提交的修改，不能作为正式发布。
pub const git_dirty = options.git_dirty;

/// 编译时的 UTC 时间戳（ISO 8601 格式）。
/// 支持 `SOURCE_DATE_EPOCH` 环境变量实现可复现构建。
pub const build_time = options.build_time;

/// 返回 git commit 的前 12 个字符（短 hash），用于版本输出的紧凑显示。
/// 12 字符在 Git 中冲突概率极低（约 $2^{-48}$），足够用于运维溯源。
pub fn shortCommit() []const u8 {
    return git_commit[0..@min(git_commit.len, 12)];
}
