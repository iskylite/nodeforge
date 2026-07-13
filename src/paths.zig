//! NodeForge 安装布局的唯一默认路径定义。
//! 业务模块只引用这里的派生常量，避免把 `/opt/nodeforge` 散落在代码各处。

/// 默认安装根。正常部署时 config/catalog 会从该根目录下自动发现。
pub const install_root = "/opt/nodeforge";

/// 可执行文件目录。`/usr/bin/nodeforge` 和 `/usr/bin/nodeforged` 只做软链接。
pub const bin_dir = install_root ++ "/bin";
/// systemd unit 的真实存放位置；`/etc/systemd/system` 只做软链接，便于整体卸载。
pub const systemd_dir = install_root ++ "/systemd";
/// 人工维护的启动配置目录。
pub const config_dir = install_root ++ "/config";
/// `nodeforged` 维护的管理 catalog 目录。
pub const catalog_dir = install_root ++ "/catalog";
/// 运行态快照目录，不能反向成为启动配置事实源。
pub const state_dir = install_root ++ "/state";
/// 结构化事件和服务日志目录；systemd 默认写入这里，交互式模式可选 stderr。
pub const logs_dir = install_root ++ "/logs";
/// ISO、kernel、initrd、rootfs 等大文件资产根目录。
pub const assets_dir = install_root ++ "/assets";
/// 通过 HTTP `/repos/` 发布的软件仓库根目录。
pub const repos_dir = install_root ++ "/repos";
/// 后续 TFTP 阶段的只读启动小文件根目录。
pub const tftp_dir = install_root ++ "/tftp";
/// NodeForge 小 initrd 构建产物目录。
pub const initrd_dir = install_root ++ "/initrd";
/// rootfs 构建和发布产物目录。
pub const rootfs_dir = install_root ++ "/rootfs";
/// boot/provisioning bundle 等声明式产物目录。
pub const bundles_dir = install_root ++ "/bundles";
/// 节点已应用 provisioning 结果记录目录。
pub const provisioned_dir = install_root ++ "/provisioned";
/// pid、临时 socket 等运行期短生命周期文件目录。
pub const run_dir = install_root ++ "/run";
/// 构建、导入、解包等可清理工作目录。
pub const work_dir = install_root ++ "/work";
/// Daemon 管控的 ISO 临时暂存目录。
///
/// M3.6 安全设计：CLI 接受管理员指定的任意本地 ISO 路径后，先将文件原子复制
/// 到此受管目录，然后仅向本机 daemon 的管理端点传递生成的不透明文件名
///（不含路径前缀）。这样常驻特权 daemon 永远不会接触任意 host 路径，
/// 既改善了 UX（用户不用手动把 ISO 放到固定位置），又不把任意文件系统
/// 访问能力交给网络服务。CLI 完成导入后负责删除临时副本。
pub const import_dir = work_dir ++ "/import";

pub const config_path = config_dir ++ "/config.json";
pub const catalog_path = catalog_dir ++ "/catalog.json";
pub const runtime_path = state_dir ++ "/runtime.json";
/// M3.1 DHCP lease 快照文件路径；取代了 `runtime.json` 中的 lease 部分。
/// 该文件由 DHCP checkpoint worker 周期性写入，用于持久化当前活动租约。
pub const leases_path = state_dir ++ "/leases.json";
/// M3.1 节点状态快照文件路径；取代了 `runtime.json` 中的状态部分。
/// 该文件由 HTTP 管理路由在节点状态变更时写入，使用独立的 I/O 锁避免
/// 与 DHCP checkpoint worker 的 lease 文件锁竞争。
pub const node_status_path = state_dir ++ "/node-status.json";
pub const deployment_control_path = state_dir ++ "/deployment-control.json";
pub const events_path = logs_dir ++ "/events.jsonl";
pub const service_log_path = logs_dir ++ "/nodeforged.log";
pub const service_path = systemd_dir ++ "/nodeforged.service";

// 验证所有派生路径都以安装根 `/opt/nodeforge` 为前缀。
// 这是防止路径拼接错误导致文件写入非预期位置的基础回归测试。
test "default paths are derived from the install root" {
    const std = @import("std");

    try std.testing.expectEqualStrings("/opt/nodeforge", install_root);
    try std.testing.expectEqualStrings("/opt/nodeforge/config/config.json", config_path);
    try std.testing.expectEqualStrings("/opt/nodeforge/catalog/catalog.json", catalog_path);
    try std.testing.expectEqualStrings("/opt/nodeforge/assets", assets_dir);
    try std.testing.expectEqualStrings("/opt/nodeforge/repos", repos_dir);
}
