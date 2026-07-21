//! NodeForge 核心库入口。
//!
//! 统一导出配置事实模型、校验器和服务实现。业务模块不得重复定义影子结构，
//! 所有类型和函数都从本模块或其子模块引用。
//!
//! 模块层次：
//! - `model` / `paths` / `version`：事实模型、启动时只初始化一次的路径投影和构建版本。
//! - `config` / `config_store` / `config_validate`：启动配置的加载、持久化和校验。
//! - `catalog` / `catalog_store` / `iso_import`：节点 catalog 的管理、持久化和 ISO 导入。
//! - `app` / `preflight`：daemon 应用入口和启动前预检。
//! - `state/*`：进程内运行时状态（session、lease、event、catalog 快照）。
//! - `http/*`：管理 API、PXE HTTP 数据路由和客户端。
//! - `tftp/*` / `dhcp/*`：PXE 协议服务端实现。
//! - `boot/*`：启动解析器、GRUB 虚拟配置和内核命令行渲染。
//! - `assets/validate`：TFTP 资产完整性校验。
//! - `observe/*`：结构化日志和错误渲染后端。
//! - `cli/*`：CLI 输出格式化（表格、视图、事件展示）。

const std = @import("std");

/// 配置事实模型：定义 AppConfig、Catalog、Asset、Profile 等核心结构体。
pub const model = @import("model.zig");
/// 运行时受管路径：从已验证 install root 派生 import/work/events 等安全边界。
pub const paths = @import("paths.zig");
/// M4.7 安装初始化、legacy 迁移、reset 与 systemd unit 生成。
pub const setup = @import("setup.zig");
/// 项目版本字符串，从 build.zon 注入。
pub const version = @import("version.zig");
/// Catalog 查找工具：按名称查找 distro/profile/asset/repository 等对象。
pub const catalog = @import("catalog.zig");
/// Catalog JSON 存储器：加载、保存和渲染 catalog 文件。
pub const catalog_store = @import("catalog/store.zig");
/// M3 ISO 导入器：通过只读 loop mount 从 DVD ISO 提取安装介质并发布到 catalog。
pub const iso_import = @import("catalog/iso_import.zig");
pub const catalog_migration = @import("catalog/migration.zig");
pub const catalog_discovery = @import("catalog/discovery.zig");
pub const catalog_schema_v3 = @import("catalog/schema_v3.zig");
pub const catalog_schema_v3_dto = @import("catalog/schema_v3_dto.zig");
pub const catalog_schema_v2_dto = @import("catalog/schema_v2_dto.zig");
pub const software_index = @import("catalog/software_index.zig");
/// Daemon 应用入口：绑定端口、启动 DHCP/TFTP/HTTP 服务和管理信号处理。
pub const app = @import("app.zig");
/// 启动配置加载器：从 JSON 文件解析 AppConfig，失败时返回结构化错误。
pub const config = @import("config/load.zig");
/// 启动配置存储器：原子写入和规范化渲染配置 JSON。
pub const config_store = @import("config/store.zig");
pub const config_schema_v3_dto = @import("config/schema_v3_dto.zig");
pub const config_schema_v2_dto = @import("config/schema_v2_dto.zig");
/// 配置和 catalog 校验器：纯函数校验所有不变量和跨文件引用关系。
pub const config_validate = @import("config/validate.zig");
/// 节点资源增删改：load-modify-validate-save 事务写回 catalog/nodes.json。
pub const node_mutation = @import("config/node_mutation.zig");
/// Profile kernel_args 的受限、规范化 catalog 事务写入器。
pub const profile_mutation = @import("config/profile_mutation.zig");
pub const value_mutation = @import("config/value_mutation.zig");
pub const item_mutation = @import("config/item_mutation.zig");
pub const scalar_mutation = @import("config/scalar_mutation.zig");
pub const provision_bundle_mutation = @import("config/provision_bundle_mutation.zig");
/// 启动前预检：检查端口可用性、目录权限和必需的系统 capability。
pub const preflight = @import("preflight.zig");
/// 进程内运行时状态：DHCP lease 表、TFTP 传输计数器和 catalog 运行时快照。
pub const runtime_state = @import("state/runtime.zig");
/// M4.8 启动时容量与并发派生：按网段/CPU/节点数动态计算上限，config 可覆盖。
pub const capacity = @import("state/capacity.zig");
/// PXE boot session 注册表：关联 DHCP→TFTP→HTTP 启动链路的进程内状态。
pub const boot_session = @import("state/boot_session.zig");
pub const boot_session_store = @import("state/boot_session_store.zig");
pub const node_inventory = @import("state/node_inventory.zig");
pub const operations = @import("state/operations.zig");
pub const config_runtime = @import("state/config_runtime.zig");
pub const model_runtime = @import("state/model_runtime.zig");
pub const model_transaction = @import("state/model_transaction.zig");
pub const schema_v3_transaction = @import("state/schema_v3_transaction.zig");
/// 节点状态跟踪：记录已注册节点的当前启动阶段和终态。
pub const node_status = @import("state/node_status.zig");
/// Catalog 运行时快照：管理 catalog 的原子替换和只读引用计数。
pub const catalog_runtime = @import("state/catalog_runtime.zig");
/// Event v2 审计日志写入器：追加式 JSONL 事件流和滚动管理。
pub const events = @import("state/events.zig");
/// 事件类型定义：所有已注册事件类型的名称、描述和默认级别。
pub const event_types = @import("state/event_types.zig");
/// DHCP lease 持久化存储：磁盘上的 lease 表和重载支持。
pub const dhcp_store = @import("state/dhcp_store.zig");
/// 节点状态持久化存储：磁盘上的节点状态和终态记录。
pub const status_store = @import("state/status_store.zig");
pub const deployment_control = @import("state/deployment_control.zig");
/// M4.9b：仅包含节点实际引用事实的完整 SHA-256 部署计划摘要。
pub const plan_digest = @import("state/plan_digest.zig");
/// CLI 管理客户端：通过本机 HTTP 管理 API 与 daemon 通信。
pub const management_client = @import("http/client.zig");
pub const http_routes = @import("http/routes.zig");
/// 管理 API 约定：固定 loopback 连接地址和安全边界常量。
pub const management = @import("http/management.zig");
/// HTTP 服务端：PXE 数据路由（kernel/initrd/ISO/rootfs 下载）和管理 API 路由。
pub const http_server = @import("http/server.zig");
/// HTTP 请求/响应契约：管理 API 的 JSON schema 和路由绑定。
pub const http_contracts = @import("http/contracts.zig");
/// HTTP 认证：bootstrap proof 和 capability token 验证中间件。
pub const http_auth = @import("http/auth.zig");
/// TFTP 包解析/序列化：RFC 1350 RRQ/WRQ/DATA/ACK/OERROR 包处理。
pub const tftp_packet = @import("tftp/packet.zig");
/// TFTP 服务端：虚拟 GRUB 配置拦截、文件传输和会话管理。
pub const tftp_server = @import("tftp/server.zig");
/// DHCPv4 包解析/序列化：RFC 2131/2132 option 编解码。
pub const dhcp_packet = @import("dhcp/packet.zig");
/// DHCP 探测器：启动前检测网络中是否有冲突的 DHCP 服务器。
pub const dhcp_probe = @import("dhcp/probe.zig");
/// DHCPv4 服务端：DISCOVER/OFFER/REQUEST/ACK 全流程和 lease 管理。
pub const dhcp_server = @import("dhcp/server.zig");
/// 启动解析器：根据节点 profile 和 catalog 解析 TFTP/HTTP 引导链。
pub const boot_resolver = @import("boot/resolver.zig");
/// TFTP 资产完整性校验：SHA-256 计算、路径安全验证和文件类型检查。
pub const asset_validate = @import("assets/validate.zig");
/// GRUB 虚拟配置渲染器：根据 session 和 resolver 结果动态生成 grub.cfg。
pub const grub = @import("boot/grub.zig");
/// 内核命令行渲染器：根据发行版和 profile 生成 install/diskless 启动参数。
pub const boot_target = @import("boot/target.zig");
/// M4 安装器适配器和共享 answer 渲染辅助工具。
pub const profile_render = @import("profile/render.zig");
pub const password_hash = @import("profile/password_hash.zig");
pub const profile_install = @import("profile/install.zig");
pub const profile_storage = @import("profile/storage.zig");
pub const profile_effective = @import("profile/effective.zig");
pub const adapter_capabilities = @import("profile/capabilities.zig");
pub const admin_key = @import("server/admin_key.zig");
pub const kickstart = @import("profile/adapter/kickstart.zig");
pub const ubuntu_autoinstall = @import("profile/adapter/ubuntu.zig");
/// M4 受限 install_post provisioning 渲染器。
pub const provision_runner = @import("provision/runner.zig");
/// 错误渲染器：将 Zig error set 映射为人类可读的审计消息。
pub const observe_error = @import("observe/error.zig");
/// 日志前端：结构化日志的公共 API。
pub const observe_log = @import("observe/log.zig");
/// 日志后端实现：文件滚动、stdout/stderr 分发和级别过滤。
pub const log_backend = @import("observe/log_backend.zig");
/// CLI 表格渲染：固定列宽的人类可读表格输出。
pub const cli_table = @import("cli/table.zig");
/// CLI 输出格式化：human/JSON 模式切换和颜色控制。
pub const cli_output = @import("cli/output.zig");
pub const cli_document = @import("cli/document.zig");
pub const cli_properties = @import("cli/properties.zig");
/// CLI 视图模板：status/check/asset/node/lease 等命令的展示视图。
pub const cli_views = @import("cli/views.zig");
/// CLI 事件工具：本地事件 JSONL 读取、过滤和字段提取。
pub const cli_events = @import("cli/events.zig");

test {
    _ = model;
    _ = paths;
    _ = setup;
    _ = version;
    _ = catalog;
    _ = catalog_store;
    _ = iso_import;
    _ = catalog_migration;
    _ = catalog_discovery;
    _ = catalog_schema_v3;
    _ = catalog_schema_v3_dto;
    _ = catalog_schema_v2_dto;
    _ = software_index;
    _ = app;
    _ = config;
    _ = config_store;
    _ = config_schema_v3_dto;
    _ = config_schema_v2_dto;
    _ = config_validate;
    _ = node_mutation;
    _ = profile_mutation;
    _ = value_mutation;
    _ = item_mutation;
    _ = scalar_mutation;
    _ = provision_bundle_mutation;
    _ = preflight;
    _ = runtime_state;
    _ = capacity;
    _ = boot_session;
    _ = boot_session_store;
    _ = node_inventory;
    _ = operations;
    _ = config_runtime;
    _ = model_runtime;
    _ = model_transaction;
    _ = schema_v3_transaction;
    _ = node_status;
    _ = catalog_runtime;
    _ = events;
    _ = event_types;
    _ = dhcp_store;
    _ = status_store;
    _ = deployment_control;
    _ = plan_digest;
    _ = management_client;
    _ = http_routes;
    _ = management;
    _ = http_server;
    _ = http_contracts;
    _ = http_auth;
    _ = tftp_packet;
    _ = tftp_server;
    _ = dhcp_packet;
    _ = dhcp_probe;
    _ = dhcp_server;
    _ = boot_resolver;
    _ = asset_validate;
    _ = grub;
    _ = boot_target;
    _ = profile_render;
    _ = profile_storage;
    _ = profile_effective;
    _ = kickstart;
    _ = ubuntu_autoinstall;
    _ = provision_runner;
    _ = observe_error;
    _ = observe_log;
    _ = log_backend;
    _ = cli_table;
    _ = cli_output;
    _ = cli_views;
    _ = cli_events;
}
const log_backend_impl = @import("observe/log_backend.zig");

/// 全局标准库选项：日志级别设为 debug，日志输出委托自定义后端。
/// 后端根据配置将日志写入文件和/或 stdout/stderr。
pub const std_options: std.Options = .{ .log_level = .debug, .logFn = log_backend_impl.logFn };
