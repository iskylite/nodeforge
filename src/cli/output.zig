//! CLI human 输出的统一入口。
//!
//! `Output` 将是否为 JSON、是否禁用颜色等展示策略集中在一个值中。它不负责
//! 领域查询或 JSON 序列化；这样 handler 可以先取得事实，再交给 views/table 渲染。

const std = @import("std");

pub const Mode = enum { human, json };

pub const Output = struct {
    mode: Mode,
    no_color: bool,

    /// M1.5 不输出 ANSI；此函数为未来仅 TTY 的状态色保留唯一判定位置。
    pub fn colorEnabled(self: Output) bool {
        return self.mode == .human and !self.no_color and false;
    }
};
