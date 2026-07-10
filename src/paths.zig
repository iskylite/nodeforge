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
/// 结构化事件和可选文件日志目录；默认服务日志仍走 stderr/systemd journal。
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

pub const config_path = config_dir ++ "/config.json";
pub const catalog_path = catalog_dir ++ "/catalog.json";
pub const runtime_path = state_dir ++ "/runtime.json";
pub const events_path = logs_dir ++ "/events.jsonl";
pub const service_path = systemd_dir ++ "/nodeforged.service";

test "default paths are derived from the install root" {
    const std = @import("std");

    try std.testing.expectEqualStrings("/opt/nodeforge", install_root);
    try std.testing.expectEqualStrings("/opt/nodeforge/config/config.json", config_path);
    try std.testing.expectEqualStrings("/opt/nodeforge/catalog/catalog.json", catalog_path);
    try std.testing.expectEqualStrings("/opt/nodeforge/assets", assets_dir);
    try std.testing.expectEqualStrings("/opt/nodeforge/repos", repos_dir);
}
