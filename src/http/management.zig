//! `nodeforge` CLI 的本机管理客户端约定。
//! 服务端唯一 listener 绑定所有 IPv4 接口，管理路由也不限制请求来源；这里只限定
//! 官方 CLI 固定连接本机 `nodeforged`，不提供远程 endpoint 参数。

const std = @import("std");

/// CLI 管理客户端固定连接 IPv4 localhost，配置文件和命令行均不能覆盖此值。
pub const client_ip = "127.0.0.1";

test "management client is fixed to IPv4 localhost" {
    _ = std;
    try std.testing.expectEqualStrings("127.0.0.1", client_ip);
}
