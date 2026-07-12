//! NodeForge 版本信息。
//! M0/M1 使用单一常量；后续发布流程成熟后再由 build.zig 注入 git/tag 元数据。

/// CLI 和 daemon 共享的 SemVer 版本字符串。
pub const version = "0.1.0";
