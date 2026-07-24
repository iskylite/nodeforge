# NodeForge

一个基于 Zig 实现的轻量级 OS Provisioning 平台，面向小型 Linux 集群和实验室环境。单进程内置 DHCPv4、TFTP 和 HTTP 服务，提供 IPv4 PXE 无人值守安装能力，支持 Rocky Linux / RHEL 系 Kickstart 和 Ubuntu Autoinstall 双适配器。

基于 Zig 0.16 · 内置 DHCP/TFTP/HTTP · IPv4 PXE · UEFI x86_64/aarch64 · Rocky/Ubuntu 无人值守安装

仓库地址：<https://github.com/iskylite/nodeforge>

## 特性

- **单进程三协议**：内置 DHCPv4、TFTP、HTTP，无需外部依赖即可完成 PXE 引导链路。
- **双发行版适配器**：原生支持 Rocky Linux 9.x / RHEL Kickstart 和 Ubuntu 22.04+ Autoinstall/Curtin。
- **完整存储拓扑**：Kickstart 与 Autoinstall 原生的 single、LVM、RAID 0/1/5/6/10 及 RAID 上 LVM。
- **Profile/Node 分层配置**：Profile 定义共享策略，Node 保存物理绑定和策略 override。
- **安装生命周期**：一次性 generation、显式 retry、desired/applied drift 追踪和部署溯源。
- **ISO 导入与 catalog 管理**：自动识别 ISO 布局、提取安装介质、原子写入 catalog。
- **本机管理 API**：结构化 HTTP API，支持 ETag/If-Match、分页、幂等键和持久 Operation。
- **审计与可观测**：Event v2 JSONL 事件流、boot session 追踪和统一 `nodeforge status` 运行面检查。
- **systemd 集成**：动态 unit 生成、故障回滚和最小特权运行。

## 项目结构

```text
NodeForge/
├── build.zig / build.zig.zon     # 构建脚本与依赖声明
├── Makefile                      # 构建快捷封装
├── config.example.json           # 启动配置示例
├── catalog.example.json          # Catalog 示例（distro/asset/repository）
├── src/
│   ├── root.zig                  # 核心库统一导出
│   ├── model.zig                 # 配置事实模型（AppConfig/Catalog/Profile/Node）
│   ├── nodeforged.zig            # daemon 入口
│   ├── main.zig                  # CLI 客户端入口
│   ├── app.zig                   # 单进程生命周期（DHCP/TFTP/HTTP 协调）
│   ├── paths.zig                 # 运行时安装路径自举
│   ├── setup.zig                 # 安装初始化、迁移与 systemd unit 生成
│   ├── version.zig               # 构建溯源信息
│   ├── config/                   # 配置加载、校验、schema 迁移与 mutation
│   ├── catalog/                  # Catalog 存储、ISO 导入、软件索引
│   ├── dhcp/                     # DHCPv4 协议实现（packet/probe/server）
│   ├── tftp/                     # TFTP 协议实现（packet/server）
│   ├── http/                     # HTTP 服务端、管理 API、路由与客户端
│   ├── boot/                     # 启动解析器、GRUB 渲染与内核命令行
│   ├── profile/                  # 安装器适配器、effective 编译与存储渲染
│   ├── state/                    # 运行时状态（lease/session/event/deployment）
│   ├── cli/                      # CLI 输出格式化与视图
│   └── observe/                  # 结构化日志与错误渲染
├── tests/                        # 单元测试、CLI 契约、HTTP 集成与实机脚本
├── vendor/zli/                   # CLI 框架（v5.1.2）
└── docs/                         # 设计文档、审计与验证记录
```

两个二进制共享同一核心模块（`src/root.zig`），避免 CLI 与 daemon 行为分叉：

- **`nodeforged`**：守护进程，承载 DHCP/TFTP/HTTP 服务和本机管理接口。
- **`nodeforge`**：管理客户端，通过 `127.0.0.1` 调用 daemon 的管理 API。

## 文档

详细设计、审计和验证记录位于 [`docs/`](docs/)，入口见 [文档导航](docs/README.md)：

- [v0.1 设计与修复计划](docs/design/V0_1_DESIGN.md)：当前权威设计，定义所有权模型和完成标准。
- [v0.2 设计范围](docs/design/V0_2_DESIGN.md)：正在实现的内存无盘启动与节点一次性配置。
- [`docs/audits/`](docs/audits/)：代码事实、设计对齐和缺口审计。
- [`docs/validation/`](docs/validation/)：自动化、虚拟机和实机验证记录。

文档冲突时的优先级：现行版本设计 > 当前代码与审计证据 > 验证记录 > 历史归档。

## 实现

### 架构

NodeForge 是单进程服务，在同一端口上复用 HTTP 健康检查、管理 API 和 PXE 数据路由：

- **DHCPv4**：RFC 2131/2132 实现，包含 IP 池管理、ICMP 冲突探测、MAC reservation 和 PXE bootfile 决策。通过 `SO_BINDTODEVICE` 限定服务网卡。
- **TFTP**：RFC 1350 实现，支持虚拟 GRUB 配置拦截、OACK 协商、块大小和窗口大小选项。
- **HTTP**：基于 [Zap](https://github.com/zigzap/zap) 的单 listener，三平面隔离——节点交付 `/api/v1/nodes/:id/**`、本机管理 `/api/v1/management/**`、静态制品 `/artifacts/**`。

### 配置模型

采用 Resource → Profile → Node → Effective 四层模型：

| 层 | 职责 |
|---|---|
| Resource | 可复用的部署能力（ISO/kernel/repository/asset） |
| Profile | 共享的安装和目标系统策略模板 |
| Node | 机器身份、物理绑定（MAC/IP/storage）和策略 override |
| Effective | Profile + Node override 编译出的唯一部署计划 |

密码字段以明文存储为配置事实，仅在渲染下发阶段临时转换为发行版要求的 hash。

### 存储支持

双适配器原生支持 12 种存储拓扑，默认布局为单主 1 GiB ESP、2 GiB ext4 `/boot`、剩余 ext4 `/`：

| 模式 | 说明 |
|---|---|
| `single` | 单盘直接分区 |
| `lvm` | 单盘 LVM |
| `raid0`-`raid10` | 软件 RAID（2-4 盘） |
| `raid*-lvm` | RAID 上 LVM |

## 规划

### v0.1（当前）

IPv4 PXE 无人值守安装产品，M0-M4 的基础服务和安装链路已完成实机验证，正在通过 M4.13 收口所有权模型和 typed property registry。主要里程碑：

| 里程碑 | 范围 | 状态 |
|---|---|---|
| M0-M3 | 基础服务、PXE 协议、HTTP 资产和安装源链路 | 已实现 |
| M4/M4.1 | Rocky 9.7 与 Ubuntu 22.04 无人值守安装和生命周期 | 已验证 |
| M4.2-M4.11 | 部署健壮性、URL 契约、容量扩展、fresh CLI 闭环和统一 status | 已实现 |
| M4.12 | 存储 fallback/override | 历史实现，所有权方案已被取代 |
| M4.13 | 模型修复、typed registry、软件能力索引和 schema v3 迁移 | 进行中 |

### v0.2（进行中）

当前已落地 schema v4、diskless Profile、rootfs 制品登记、BootConfig v2 /
AgentPlan v1、分域 capability、严格 HEAD + Range 下载、tmpfs overlay、node-apply
与 aarch64 Rocky 9.7 完整 OS QEMU 启动闭环。尚未达到 v0.2 完成标准，主要剩余
content-addressed first-boot payload、失败恢复/负向矩阵、x86_64/UEFI 与实机验证。

- **v0.2**：内存无盘启动（固定 squashfs overlay）及 node-apply/first-boot
- **v0.3+**：BIOS PXELINUX、更多发行版和后续 rootfs 形态，详见各版本设计

IPv6 和 by-id/serial/WWN 等稳定磁盘选择器是项目永久非目标。

## 编译

需要 [Zig 0.16](https://ziglang.org/)。依赖 `zli`（仓库内 `vendor/zli`）和 `zap`（构建时自动拉取）。

```bash
# 本机 Debug 构建
zig build

# ReleaseSafe 构建
zig build -Doptimize=ReleaseSafe

# 交叉编译 Linux x86_64（amd64）
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe

# 交叉编译 Linux aarch64（arm64）
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe

# 运行全部测试（单元 + CLI 契约 + HTTP 集成 + setup 布局）
zig build test
```

或使用 Make 封装：

```bash
make build              # 本机 Debug 构建
make test               # 全部测试
make release            # 本机 ReleaseSafe 构建
make linux-amd64        # 交叉编译 Linux x86_64 ReleaseSafe
make linux-arm64        # 交叉编译 Linux aarch64 ReleaseSafe
make linux-arm64-debug  # 交叉编译 Linux aarch64 Debug
make dist               # 打包本机 ReleaseSafe 二进制到 dist/
make dist-linux-amd64   # 交叉编译并打包 Linux x86_64
make dist-linux-arm64   # 交叉编译并打包 Linux aarch64
```

构建产物位于 `zig-out/bin/`，包含 `nodeforge` 和 `nodeforged` 两个二进制。

## 部署

### 安装初始化

```bash
# 初始化安装根、写入配置并创建标记文件
./nodeforge setup --install-root /opt/nodeforge --non-interactive --yes \
  --bind-interface enp1s0 --server-ip 192.168.50.1 \
  --subnet 192.168.50.0/24 --pool-start 192.168.50.100 --pool-end 192.168.50.200

# 生成并安装 systemd unit
./nodeforge setup --install-root /opt/nodeforge --generate-systemd --install --yes

# 启动服务
systemctl start nodeforged
```

安装布局由 `src/paths.zig` 在启动时自举，默认根为 `/opt/nodeforge`：

```text
/opt/nodeforge/
├── bin/            # nodeforge / nodeforged
├── config/         # config.json (schema 3)
├── catalog/        # manifest.json + entity files
├── assets/
│   ├── iso/        # ISO 镜像
│   ├── boot/       # TFTP 启动文件（GRUB/kernel/initrd）
│   ├── repos/      # HTTP 发布的仓库
│   └── keys/       # SSH 密钥
├── state/          # lease/status/session/provisioned
├── logs/           # 服务日志和事件审计流
├── work/           # 导入暂存
└── systemd/        # nodeforged.service
```

systemd unit 授予最小特权集：`CAP_NET_BIND_SERVICE`（UDP 67/69）、`CAP_NET_RAW`（ICMP 探测）和 `CAP_SYS_ADMIN`（ISO loop mount）。

### 配置与 Catalog

[`config.example.json`](config.example.json) 是启动配置示例，只包含 server/http/tftp/dhcp 等站点字段。节点、Profile 和资源由 Catalog 管理，通过 `nodeforge setup --reconfigure --import-config <path>` 导入。

`server.bind_interface` 是 PXE 网卡占位值，部署前必须替换为实际接口名。

## 基本使用

```bash
# 查看帮助
nodeforge -h
nodeforge --help-full          # 详细帮助（含全部 canonical key）

# 校验配置
nodeforge config validate --config config.example.json --catalog catalog.example.json
nodeforged --check --config config.example.json --catalog catalog.example.json

# 导入 ISO（自动识别布局并创建 install profile）
nodeforge assets import /path/to/Rocky-9.7-aarch64-dvd.iso

# 管理节点和 Profile
nodeforge node add node-01 --mac 00:50:56:2a:23:db --profile rocky-9
nodeforge node set node-01 storage.boot_disk=/dev/sda
nodeforge profile set rocky-9 'kernel_args=iommu=pt hugepages=4'

# 部署
nodeforge install retry node-01     # 武装安装 generation

# 运行面检查（退出码表示整体可用性）
nodeforge status

# 审计排障
nodeforge events list --node node-01
nodeforge node trace node-01 --latest
```

### 日志

服务默认输出 `info` 日志到 stderr/systemd journal。临时排障：

```bash
nodeforged -d                     # 强制 debug 日志
nodeforge <command> -d            # 显示底层错误原因
```

### 安全边界

- 管理路由只接受 `127.0.0.1` 直连，不信任 `X-Forwarded-For`。
- 管理 API 尚无鉴权和 TLS，必须部署在受信任网络。
- DHCP 使用 `SO_BINDTODEVICE` 限定网卡，不会回答管理网卡请求。
- `nodeforge setup --reset-state` 检测到 daemon 可达时拒绝执行。

## 许可证

[MIT](LICENSE)
