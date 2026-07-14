//! 配置与 catalog 的只读查询函数。
//! 校验器和 CLI 共用这些函数，避免同一关联在不同入口采用不同查找规则。
//! 本模块不修改配置或 catalog，所有函数返回的指针借用入参的生命周期。

const model = @import("model.zig");

/// 按名称查找发行版。
pub fn findDistro(config: *const model.AppConfig, name: []const u8) ?*const model.DistroConfig {
    for (config.distros) |*item| if (equal(item.name, name)) return item;
    return null;
}

/// 查找发行版版本，并同时确认目标架构已经列入支持矩阵。
pub fn findDistroVersion(
    config: *const model.AppConfig,
    distro_name: []const u8,
    version: []const u8,
    arch: model.Arch,
) ?*const model.DistroVersionConfig {
    const distro = findDistro(config, distro_name) orelse return null;
    for (distro.versions) |*item| {
        if (!equal(item.version, version)) continue;
        for (item.archs) |item_arch| if (item_arch == arch) return item;
    }
    return null;
}

/// 按稳定名称查找仓库。
pub fn findRepository(catalog: *const model.Catalog, name: []const u8) ?*const model.RepositoryConfig {
    for (catalog.repositories) |*item| if (equal(item.name, name)) return item;
    return null;
}

/// 按稳定名称查找文件资产。
pub fn findAsset(catalog: *const model.Catalog, name: []const u8) ?*const model.AssetConfig {
    for (catalog.assets) |*item| if (equal(item.name, name)) return item;
    return null;
}

/// 按文件路径查找文件资产（用于 HTTP /boot/ 路由的 ETag 查找）。
pub fn findAssetByPath(catalog: *const model.Catalog, path: []const u8) ?*const model.AssetConfig {
    for (catalog.assets) |*item| if (equal(item.path, path)) return item;
    return null;
}

/// 按稳定名称查找自动安装入口。
pub fn findInstallSource(catalog: *const model.Catalog, name: []const u8) ?*const model.InstallSourceConfig {
    for (catalog.install_sources) |*item| if (equal(item.name, name)) return item;
    return null;
}

/// 按稳定名称查找无盘启动组合。
pub fn findBootBundle(catalog: *const model.Catalog, name: []const u8) ?*const model.BootBundleConfig {
    for (catalog.boot_bundles) |*item| if (equal(item.name, name)) return item;
    return null;
}

/// 按稳定名称查找 profile。
pub fn findProfile(config: *const model.AppConfig, name: []const u8) ?*const model.ProfileConfig {
    for (config.profiles) |*item| if (equal(item.name, name)) return item;
    return null;
}

/// 按节点 ID 查找已显式认领的节点。安装 answer 只能为这类节点渲染。
pub fn findNode(config: *const model.AppConfig, id: []const u8) ?*const model.NodeConfig {
    for (config.nodes) |*item| if (equal(item.id, id)) return item;
    return null;
}

fn equal(a: []const u8, b: []const u8) bool {
    return @import("std").mem.eql(u8, a, b);
}
