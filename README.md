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
├── vendor/
│   ├── zli/                      # CLI 框架（v5.1.2），编译时链接
│   └── dhcp/                     # ISC DHCP 源码，仅作协议实现参考，不参与编译
└── docs/                         # 设计文档、审计与验证记录
```

`vendor/` 下两个目录的用途不同：

- **`vendor/zli/`**：CLI 框架依赖，`build.zig` 编译时直接链接，是运行时必需组件。
- **`vendor/dhcp/`**：ISC DHCP（dhcp-4.4.3）的 C 源码，**本项目中未使用、不参与编译**，仅保留为 DHCPv4 协议实现的参考资料。NodeForge 的 DHCP 服务端（`src/dhcp/`）是基于 RFC 2131/2132 的 Zig 原生实现，不依赖此目录中的任何代码。

两个二进制共享同一核心模块（`src/root.zig`），避免 CLI 与 daemon 行为分叉：

- **`nodeforged`**：守护进程，承载 DHCP/TFTP/HTTP 服务和本机管理接口。
- **`nodeforge`**：管理客户端，通过 `127.0.0.1` 调用 daemon 的管理 API。

默认安装根为 `/opt/nodeforge`。`nodeforge setup` 会生成 `/etc/profile.d/nodeforge.sh`，新登录 shell
自动将 `/opt/nodeforge/bin` 加入 `PATH`；当前 shell 可执行 `source /etc/profile.d/nodeforge.sh` 立即生效。

## 文档

详细设计、审计和验证记录位于 [`docs/`](docs/)，入口见 [文档导航](docs/README.md)：

- [v0.1 最终设计](docs/design/V0_1_DESIGN.md)：当前权威设计，定义已实现的所有权模型和完成标准。
- [v0.2 设计总纲](docs/design/V0_2_DESIGN.md)：diskless 无盘启动主流程，已实现并通过 aarch64 QEMU 完整闭环验证。
- [v0.2.1 Ubuntu diskless 设计](docs/design/V0_2_1_UBUNTU_DISKLESS.md)：Ubuntu casper squashfs 叠加方案，支持 Rocky/RHEL 宿主构建 Ubuntu 无盘系统。
- [v0.2.2 保留项](docs/validation/V0_2_2_RESERVED.md)：异架构/实机验证矩阵（x86_64 UEFI smoke、VMware compute_use），当前暂不验证。
- [`docs/audits/`](docs/audits/)：代码事实、设计对齐和缺口审计。
- [`docs/validation/`](docs/validation/)：自动化、虚拟机和实机验证记录（含 [Phase 8 QEMU 全量验证](docs/validation/V0_2_PHASE8_VALIDATION.md)）。

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

IPv4 PXE 无人值守安装产品已完成；所有权模型、typed property registry、软件能力索引和 schema v3 迁移均已收口。主要里程碑：

| 里程碑 | 范围 | 状态 |
|---|---|---|
| M0-M3 | 基础服务、PXE 协议、HTTP 资产和安装源链路 | 已实现 |
| M4/M4.1 | Rocky 9.7 与 Ubuntu 22.04 无人值守安装和生命周期 | 已验证 |
| M4.2-M4.11 | 部署健壮性、URL 契约、容量扩展、fresh CLI 闭环和统一 status | 已实现 |
| M4.12 | 存储 override | 已由 canonical Node/Profile 所有权模型取代旧 fallback |
| M4.13 | 模型修复、typed registry、软件能力索引和 schema v3 迁移 | 已完成 |

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

产品版本统一定义在 `build.zig` 文件级常量 `nodeforge_version` 中；发布新版本时同时更新
`build.zig.zon` 的包版本。构建时间由 Zig 标准库读取实时时钟并格式化为 RFC 3339 UTC，格式为
`YYYY-MM-DDTHH:MM:SSZ`，不依赖宿主 shell 或 `date`。可复现构建使用 `-Dbuild-time=<固定值>` 覆盖。

> **调试阶段务必固定 `build-time`**：`build_time` 通过 `build_options` 注入编译图，参与 Zig
> 内容寻址缓存的全局哈希。若不固定，每次构建的时间戳都不同，导致**所有下游产物全部缓存失效**，
> `.zig-cache` 持续膨胀且每次全量重编。调试期间推荐始终使用固定时间戳：
>
> ```bash
> zig build -Dbuild-time=2026-07-29T00:00:00Z
> ```
>
> 正式发布构建可省略该选项以记录真实构建时间，或显式注入 `-Dbuild-time` 保证可复现。
> 若 `.zig-cache` 已膨胀，可安全删除（`.gitignore` 已忽略该目录）：
>
> ```bash
> rm -rf .zig-cache
> ```

可运行 `zig run -lc examples/time_format_demo.zig` 验证时间转换边界：构建所用的纯 Zig
`std.time.epoch` 输出 UTC 日历时间，libc `localtime_r`/`strftime` 输出宿主本地时间。

## 部署

### 安装初始化

```bash
# 推荐从包含四个二进制的发布目录执行；setup 会把同目录的
# nodeforge/nodeforged/nodeforge-initrd/nodeforge-agent 同步到 install root。
mkdir -p /tmp/nodeforge-bundle
install -m 0755 nodeforge nodeforged nodeforge-initrd nodeforge-agent /tmp/nodeforge-bundle/
cd /tmp/nodeforge-bundle

# 完全非交互式 fresh 初始化安装根、写入配置并创建标记文件。
# bind-interface 是 nodeforged 监听 PXE/DHCP/TFTP 的服务端网卡，不是目标节点网卡。
./nodeforge setup --install-root /opt/nodeforge --non-interactive --yes \
  --bind-interface enp1s0 --server-ip 192.168.50.1 \
  --subnet 192.168.50.0/24 --pool-start 192.168.50.100 --pool-end 192.168.50.200

# 生成并安装 systemd unit
./nodeforge setup --install-root /opt/nodeforge --generate-systemd --install \
  --non-interactive --yes

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
│   ├── boot/       # TFTP 启动文件：efi/<source>/、install/<source>/、diskless/sources/<source>/<uname-r>/ 或 diskless/manual/<distro>/<version>/<arch>/<uname-r>/
│   ├── repos/      # HTTP 发布的仓库
│   ├── rootfs/     # HTTP 发布的 diskless squashfs
│   └── keys/       # SSH 密钥
├── state/          # lease/status/session/provisioned
├── logs/           # 服务日志和事件审计流
├── work/           # 导入暂存
└── systemd/        # nodeforged.service
```

systemd unit 授予最小特权集：`CAP_NET_BIND_SERVICE`（UDP 67/69）、`CAP_NET_RAW`（ICMP 探测）和 `CAP_SYS_ADMIN`（ISO loop mount）。

### 配置与 Catalog

[`config.example.json`](config.example.json) 是启动配置示例，只包含 server/http/tftp/dhcp 等站点字段。节点、Profile 和资源由 Catalog 管理，通过 `nodeforge setup --reconfigure --import-config <path>` 导入。

`server.bind_interface` 是 PXE 网卡占位值，部署前必须替换为实际接口名。这里的
PXE 网卡指 **NodeForge 服务器端** 连接 provisioning 二层网络的网卡；它用于
DHCP `SO_BINDTODEVICE` 绑定、TFTP/HTTP 地址发布和避免误答其他生产网段。新机器
自身从哪块网卡 PXE 启动由固件和交换网络决定，NodeForge 不需要知道目标机 Linux
启动后的临时网卡名；只有在配置目标系统静态地址时才需要设置 Node 的
`network.interface_name`。

## CLI 流程示例

```bash
# 1. 查看帮助和运行面
nodeforge -h
nodeforge --help-full          # 详细帮助（含全部 canonical key）
nodeforge status
nodeforge config validate
nodeforge catalog validate

# 2. 导入 ISO。导入器会自动识别 .treeinfo/casper、安装 kernel/initrd、
#    UEFI GRUB、repo 根目录（如 Minimal、BaseOS/AppStream、Packages 或 ISO 根）。
nodeforge assets import /path/to/Rocky-9.7-aarch64-dvd.iso
nodeforge assets import /path/to/custom.iso \
  --distro kylin --version V10-SP3-2403-Release-20240426 --arch aarch64 \
  --name kylin-v10-sp3-2403-20240426-aarch64
nodeforge assets install-source list
nodeforge assets install-source show rocky-9.7-aarch64-dvd

# 3. 创建或调整 install Profile 与 Node。布尔值 canonical 输出为 true/false；
#    set 同时接受 yes/no 作为兼容输入。绑定 pxe.ip_reservation 后，
#    install/diskless 的目标网络默认按静态地址渲染。
nodeforge node add node-01 mac=00:50:56:2a:23:db arch=aarch64 profile=rocky-9 \
  pxe.ip_reservation=192.168.50.110 deploy=false
nodeforge node set node-01 storage.boot_disk=/dev/sda
nodeforge profile set rocky-9 'kernel_args=iommu=pt hugepages=4'
nodeforge node show node-01
nodeforge profile show rocky-9

# 4. 控制部署开关并执行 install。
#    retry 发现 deploy=false 时会提示确认；--force 会同时强制打开 deploy。
nodeforge node deploy node-01 true
nodeforge node retry node-01 --force
nodeforge node trace node-01 --latest
```

Profile 创建时默认导入 nodeforged 宿主机的 `/etc/hosts`，并在 install `%post` /
late-commands 和 diskless node-apply 阶段写入目标系统。可显式关闭或覆盖：

```bash
nodeforge profile set rocky-9 system.import_host_hosts=false
nodeforge profile set rocky-9 $'system.hosts_content=127.0.0.1 localhost\n192.168.50.1 nodeforge.local\n'
```

Install 与 diskless 默认继承 Install Source 导入的受管 Yum/APT 仓库。Rocky 安装后只保留
`/etc/yum.repos.d/nodeforge.repo`，Ubuntu 由 Subiquity 持久化 NodeForge APT primary。
可以查询介质的软件能力并选择 environment/group：

```bash
nodeforge assets install-source software list rocky-9.7-aarch64-dvd --kind environment
nodeforge assets install-source software list rocky-9.7-aarch64-dvd --kind group
nodeforge profile set rocky-9 software.environment=minimal-environment
nodeforge profile add-values rocky-9 software.groups development network-tools
nodeforge node software show node-01
```

Rocky 默认 `minimal-environment`。comps environment/group 默认安装 mandatory/default 包，
不包含 optional 包；NodeForge 当前没有隐式“安装 group 全部 optional 包”的开关。

### Diskless 流程

```bash
# 1. 基于已导入的 install source 构建 NodeForge diskless initrd。
nodeforge assets initrd build rocky-9.7-nodeforge-initrd \
  --from-install-source rocky-9.7-aarch64-dvd \
  --kernel-release 5.14.0-611.5.1.el9_7.aarch64

# source 模式发布到 assets/boot/diskless/sources/<source>/<uname-r>/<name>.img；
# 无 source 的通用构建发布到
# assets/boot/diskless/manual/<distro>/<version>/<arch>/<uname-r>/<name>.img。
#
# RHEL 的 uname -r 通常包含 .x86_64/.aarch64，Ubuntu 通常不包含。
# 显式 --kernel-release 与 ISO 检测值不同时只警告，不阻止构建。

# 2. 创建 boot bundle，并创建 diskless profile。
nodeforge assets boot-bundle create rocky-9.7-diskless \
  --kernel rocky-9.7-aarch64-dvd-kernel \
  --initrd rocky-9.7-nodeforge-initrd \
  --distro rocky --version 9.7 --arch aarch64 \
  --kernel-release 5.14.0-611.5.1.el9_7.aarch64
nodeforge profile create rocky-9.7-diskless rocky-9.7-aarch64-dvd \
  --kind diskless --boot-bundle rocky-9.7-diskless

# 3. 构建并登记 rootfs。
nodeforge profile rootfs plan rocky-9.7-diskless --output json
nodeforge profile rootfs build rocky-9.7-diskless \
  --if-input-digest <rootfs_input_digest>
nodeforge profile rootfs status rocky-9.7-diskless

# 外部 squashfs 也可直接登记；以下两种写法二选一，展开大小可选。
# 未提供时会告警并跳过内存容量硬校验，但不会阻止登记或部署。
nodeforge profile rootfs register rocky-9.7-diskless \
  --path /path/to/rootfs.squashfs
# 或者，若已有可信测量值，可启用严格内存预算：
nodeforge profile rootfs register rocky-9.7-diskless \
  --path /path/to/rootfs.squashfs --uncompressed-size <bytes>

# 如果第一次登记时未提供展开大小，可对同一文件再次登记以补全元数据；
# 成功状态为 metadata_updated。内容或已知元数据冲突不会覆盖现有制品。

# 4. 绑定节点、检查 readiness、打开 deploy gate。
nodeforge node set node-01 profile=rocky-9.7-diskless
nodeforge node readiness node-01 --stage boot
nodeforge node deploy node-01 true

# 5. PXE 启动节点。启动中 console 会输出 nodeforge session id；
#    切根后也可在 /var/lib/nodeforge/session-id 和 initrd.log 中查看。
nodeforge node session list
nodeforge node trace node-01 --latest
```

Diskless rootfs 当前默认按最小化配置构建，保持现有行为：只包含启动、网络、
SSH、包管理器、nodeforge agent 和 node-apply 必需组件。生产标准配置建议后续
增加 `diskless.rootfs_profile=minimal|standard`：

- `minimal`：默认值，继续服务快速验证和小规模实验。
- `standard`：由 profile/bundle 驱动扩展包组与基线，纳入 chrony、日志与审计、
  监控 agent、常用诊断工具、安全策略和站点 CA/SSH 策略。
- 该字段应进入 rootfs input digest；同一个 ISO、架构和 package set 在不同
  rootfs profile 下生成不同 rootfs 制品，避免最小化与生产标准混用。

```bash
# 常用排障
nodeforge events list --node node-01 --limit 50
nodeforge node show node-01
nodeforge node deploy node-01 false
```

### 日志

开发阶段 fresh setup 默认把持久日志等级设置为 `debug`。可以在初始化或
reconfigure 时显式设置：

```bash
nodeforge setup --log-level debug
nodeforge setup --reconfigure --log-level info
nodeforged -d                      # 仅本次启动强制 debug，不改 config
nodeforge <command> -d             # CLI 显示底层错误原因
```

`--log-level` 支持 `debug|info|warn|err`。未显式指定时，fresh setup 使用
`debug`；reconfigure 保留当前等级；`--import-config` 保留导入值。显式参数
始终覆盖当前或导入配置。systemd 使用 config 中的 `logging.level`。

所有非 2xx HTTP JSON 响应都会在服务日志中记录 method、path、status、
`error_code`、reason、`request_id` 和 client，凭据及请求体不会进入日志。
安装计划摘要不一致还会记录 session/desired revision、摘要前缀以及
`same_revision`：只有 revision 不同才表示模型在 PXE 授权后变化；同 revision
不一致表示运行时输入或 snapshot 不一致，需要按内部异常排查。

repository 软件能力索引以 SHA-256 内容寻址 blob 完整保存并跨节点复用，InstallPlan
只保存不可变引用。`capacity.install_plan_max_bytes` 默认 `null`（不施加人为上限）；
setup 显式生成该默认值但不提供参数或交互项。确需站点保护阈值时通过 config import
设置正整数；它限制的是 InstallPlan JSON，不是 ISO 文件大小。详见
[日志与安装计划摘要约定](docs/design/LOGGING_AND_INSTALL_PLAN_DIGEST.md#5-完整-installplan-与容量上限)。

完整日志与安装摘要诊断约定见
[日志与安装计划摘要约定](docs/design/LOGGING_AND_INSTALL_PLAN_DIGEST.md)。

### 安全边界

- 管理路由只接受 `127.0.0.1` 直连，不信任 `X-Forwarded-For`。
- 管理 API 尚无鉴权和 TLS，必须部署在受信任网络。
- DHCP 使用 `SO_BINDTODEVICE` 限定网卡，不会回答管理网卡请求。
- `nodeforge setup --reset-state` 检测到 daemon 可达时拒绝执行。

## 许可证

[MIT](LICENSE)
