//! `nodeforge` CLI 的本机管理客户端约定。
//!
//! 服务端唯一 listener 绑定所有 IPv4 接口（`0.0.0.0:http_port`），但
//! `/api/v1/management/` 路由只接受 loopback（`127.0.0.1`）direct peer。
//!
//! M3.6 安全边界：
//! - 管理 API 能写 catalog 状态、触发特权 loop mount，因此虽与 PXE HTTP
//!   数据路由共用 listener，仍只接受 direct peer `127.0.0.1`。
//! - 远端请求返回 403，不能通过 `X-Forwarded-For` 伪造。
//! - 官方 CLI 没有远程 endpoint 参数，只支持管理同机 `nodeforged`。
//! - MVP 不提供管理鉴权和 TLS；将 HTTP 路由作为正式远程管理接口前，
//!   必须另行设计 TLS、鉴权和审计。

const std = @import("std");

/// CLI 管理客户端固定连接 IPv4 localhost。
///
/// 此值是硬编码常量，配置文件和命令行均不能覆盖。
/// 这保证了管理操作永远不会意外发送到远程地址，
/// 即使配置文件中的 `server.server_ip` 被修改也不受影响。
pub const client_ip = "127.0.0.1";

// 验证管理客户端 IP 固定为 IPv4 localhost。
// 这是 M3.6 安全边界的核心约束：管理 API 只接受本机连接。
test "management client is fixed to IPv4 localhost" {
    _ = std;
    try std.testing.expectEqualStrings("127.0.0.1", client_ip);
}
