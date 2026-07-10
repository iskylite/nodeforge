//! localhost 管理客户端约定。
//! M0 只有一个服务端 listener；CLI 仍固定连接 IPv4 loopback。
//! 本模块不实现远程管理、TLS 或鉴权——安全边界是网络隔离（PXE 管理网段是受控网络）。
//! 后续若开放远程管理，必须另行设计 TLS、鉴权和审计，不能直接放宽此常量。

const std = @import("std");

/// CLI 管理客户端固定连接 IPv4 localhost，配置文件不能覆盖此值。
pub const bind_ip = "127.0.0.1";

test "management client is fixed to IPv4 localhost" {
    _ = std;
    try std.testing.expectEqualStrings("127.0.0.1", bind_ip);
}
