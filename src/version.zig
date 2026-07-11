//! NodeForge 版本信息。
//! M0/M1 使用单一常量；后续发布流程成熟后再由 build.zig 注入 git/tag 元数据。

/// SemVer string shared by the CLI and daemon version output.
pub const version = "0.1.0";
