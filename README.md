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

管理面两个程序共享同一核心模块（`src/root.zig`），diskless 节点侧另有两个
最小执行器；构建共输出四个程序：

- **`nodeforged`**：守护进程，承载 DHCP/TFTP/HTTP 服务和本机管理接口。
- **`nodeforge`**：管理客户端，通过 `127.0.0.1` 调用 daemon 的管理 API。
- **`nodeforge-initrd`**：diskless initramfs 中的 PID 1，负责网络、下载、
  校验、overlay 和 switch_root。
- **`nodeforge-agent`**：目标 rootfs 内的 pre-init/first-boot 执行器。

默认安装根为 `/opt/nodeforge`。`nodeforge setup` 会生成 `/etc/profile.d/nodeforge.sh`，新登录 shell
自动将 `/opt/nodeforge/bin` 加入 `PATH`；当前 shell 可执行 `source /etc/profile.d/nodeforge.sh` 立即生效。

## 文档

入口见 [文档导航](docs/README.md)。日常只需：

- [v0.4 统一设计](docs/design/V0_4_DESIGN.md)：当前版本契约。
- [统一延期与非目标清单](docs/design/DEFERRED_DESIGN_INDEX.md)：延期/非目标唯一状态表。
- [通用平台验证运行手册](docs/validation/PLATFORM_VALIDATION_RUNBOOK.md)：大更新 fresh 公共发布闸。
- [v0.4 全量验证运行手册](docs/validation/V0_4_FULL_VALIDATION_RUNBOOK.md)：v0.4 增量闸。
- [CLI Reference](docs/cli/REFERENCE.md)：公开命令树（参数以 `--help-full` 为准）。

冻结底座与历史证据：

- [v0.3 install-post 设计](docs/design/V0_3_DESIGN.md)（契约）/
  [实跑记录](docs/archive/validation/V0_3_VALIDATION.md)（归档）
- [v0.2 diskless 总纲](docs/design/V0_2_DESIGN.md) 及分册（只读冻结）
- 其余历史验证、审计、M0–M7 长文 → [`docs/archive/`](docs/archive/)

文档冲突时的优先级：现行版本设计 > 当前代码 > 现行验证 runbook > 统一延期清单 > 冻结分册 > 历史归档。

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

### v0.1（已完成基线）

IPv4 PXE 无人值守安装产品已完成；所有权模型、typed property registry、软件能力索引和 schema v3 迁移均已收口。主要里程碑：

| 里程碑 | 范围 | 状态 |
|---|---|---|
| M0-M3 | 基础服务、PXE 协议、HTTP 资产和安装源链路 | 已实现 |
| M4/M4.1 | Rocky 9.7 与 Ubuntu 22.04 无人值守安装和生命周期 | 已验证 |
| M4.2-M4.11 | 部署健壮性、URL 契约、容量扩展、fresh CLI 闭环和统一 status | 已实现 |
| M4.12 | 存储 override | 已由 canonical Node/Profile 所有权模型取代旧 fallback |
| M4.13 | 模型修复、typed registry、软件能力索引和 schema v3 迁移 | 已完成 |

### v0.4.0（当前开发版本）

v0.4 使用 fresh replacement：`nodeforge setup` 生成 AppConfig v5、Catalog v6、DeploymentManifest v1、
`nodeforge-root-v2 <deployment_id>` marker，并拒绝 deployment id 不一致或缺失 manifest 的已安装服务。
目标网络 topology 是 Node direct owner；`pxe.ip_reservation` 只保留 DHCP bootstrap lease，不会把 target DHCP 改成 static。
`nodeforge node topology validate` 可在提交前对 interfaces/bonds/vlans/routes 做纯校验，AgentPlan wire schema 为 v2，
BootConfig 继续为 v3。canonical topology 必须同时由 install adapter 和 diskless `node-apply renderNetwork` 完整渲染；
校验通过但在 kickstart/Ubuntu/netplan/NetworkManager 输出中静默丢弃 bond、VLAN、多 interface 或 route 的实现不符合 v0.4。

v0.4 把部署规模定义为同一 nodeforged 中尚未终态的 install + diskless 节点总数：256 逻辑节点波次为实现容量基线，
512 为标准合成扩展验证，1024 为合成压力验证点而不是最高上限。运行时容量可以显式覆盖到当前 2048 实现安全天花板；
HTTP connection、TFTP active transfer 和部署波次分别限流，其中 TFTP 默认 128 只限制同时在传的小文件数。
install first-boot 与 diskless node-apply/systemd first-boot 是计划、凭据、存储和事件均不同的执行阶段；
first-boot 不承担目标网络连通性或不存在的 installer/target 内核切换验证。
当前 VMware 双机环境只验证单节点真实功能闭环和逻辑节点 workload；256/512 台真实节点的生产吞吐与端到端规模验证按统一延期清单的 `ENV-V04-PRODUCTION-SCALE` 管理，不阻断 v0.4，也不能由合成结果冒充。

```bash
nodeforge setup --install-root /opt/nodeforge --yes
nodeforge node topology validate --network-json topology.json --bootstrap-mac 02:00:00:00:00:01 --deploy
nodeforge node boot preview <node-id>
```

服务端 rootfs、install first-boot、SN-assisted discovery、容量 workload 和 VMware 双机全量验证必须以
[`V0_4_FULL_VALIDATION_RUNBOOK.md`](docs/validation/V0_4_FULL_VALIDATION_RUNBOOK.md) 为准；缺少真实证据的项目仍为 NOT RUN/FAIL。

### v0.3.1（冻结回归基线）

v0.2.0 已落地 schema v4、diskless Profile、rootfs 制品登记、BootConfig v3 /
AgentPlan v1、四域 capability、严格 HEAD + Range 下载、tmpfs overlay、node-apply、
first-boot content-addressed payload 与 aarch64 Rocky QEMU/VMware UEFI PXE 完整闭环。

v0.2.1 已把 Ubuntu casper 方案接入正式 `profile rootfs build` 产品链，补齐
apt rootfs-build 隔离执行、原生 HTTP 诊断、制品路径规范、casper 运行态清理和
标准 getty 恢复。已在 r97n0 fresh CLI 环境中完成 Rocky 9.7、Rocky 10.2 与
Ubuntu 22.04.5 aarch64 VMware 冷启动回归。

v0.2.2/v0.2.3 已完成可运营性、Profile identity/provenance、capability restart、ISO 后台 operation 与 CLI
exit mapping 收口；v0.3 已完成 install-post 四类 canonical action、callback generation 绑定和 journal/finalizer，
并通过 fresh 双机发布闸。v0.3 及更早设计均按已落地冻结基线管理。

后续按以下边界推进：

- **v0.4 已落地底座**：AppConfig v5/catalog v6 fresh replacement、多 NIC/topology validator、AgentPlan v2、
  reservation/target 分层；服务端 rootfs 生成、install/diskless 完整 topology 渲染、install first-boot、SN+IP draft Node discovery、
  256/512/1024 合成容量闸和双机单节点发布仍按 runbook 验证；真实 256/512 节点生产规模验证延后。
- **BIOS PXELINUX**：独立保留工作项，不绑定产品/schema 版本号，也不进入 v0.4，见
  [`BIOS_PXELINUX_DEFERRED.md`](docs/design/BIOS_PXELINUX_DEFERRED.md)；
- **DHCP-less static PXE**：独立保留设计，不进入 v0.4，见
  [`STATIC_PXE_BOOTSTRAP_DEFERRED.md`](docs/design/STATIC_PXE_BOOTSTRAP_DEFERRED.md)；
- **`ram_rootfs`**：独立保留设计，不绑定后续版本号，未来重新立项。

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

构建产物位于 `zig-out/bin/`，包含 `nodeforge`、`nodeforged`、
`nodeforge-initrd` 和 `nodeforge-agent` 四个程序。

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
├── bin/            # nodeforge / nodeforged / nodeforge-initrd / nodeforge-agent
├── config/         # config.json (schema 4)
├── catalog/        # manifest.json + entity files
├── assets/
│   ├── iso/        # ISO 镜像
│   ├── boot/       # TFTP 安装启动文件：efi/<source>/、install/<source>/
│   ├── diskless/   # initrd/<profile>/<uname-r>/ 与 rootfs/<profile>/<digest-prefix>/
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
`/etc/yum.repos.d/nodeforge.repo`；Ubuntu install 由 Subiquity 持久化 NodeForge APT
primary，Ubuntu diskless 的 node-apply 则删除 casper 自带的公网/CD-ROM 源，只生成
`/etc/apt/sources.list.d/nodeforge.list`。Ubuntu 可设置 profile 策略
`install.apt.preserve_sources_list=true`（Node 级 `overrides.install.apt.preserve_sources_list`）
保留安装器/ISO 写入的原有 APT 源，NodeForge 受管源改为附加写入，用于受管镜像缺少包、
需要借助原始源补齐的场景；默认 `false` 保持只保留受管源的 local-only 契约。diskless 同时离线 mask 仅适用于安装介质的
snapd、multipathd 和 casper-md5check 单元，防止 overlay 根上的重启循环和虚假 failed unit。
node-apply 还会移除 casper 对 `getty@tty1` 的 vendor mask 和 Subiquity getty
drop-in，恢复标准本地登录控制台；存在 ARM 串口设备时同时启用对应 serial getty。
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

# 长任务默认提交 durable operation 后跟随到终态；自动化可使用 --detach，
# 再通过 operation list/show/follow 恢复观察。
nodeforge operation list

# 统一发布到 assets/diskless/initrd/<name>/<uname-r>/initrd.img；
# source/tuple provenance 由 catalog 保存，不再重复形成多层目录。
#
# RHEL 的 uname -r 通常包含 .x86_64/.aarch64，Ubuntu 通常不包含。
# 显式 --kernel-release 与 ISO 检测值不同时只警告，不阻止构建。

# 2. 创建 boot bundle，并创建 diskless profile。
nodeforge assets boot-bundle create rocky-9.7-aarch64-dvd \
  --kernel rocky-9.7-aarch64-dvd-kernel \
  --initrd rocky-9.7-nodeforge-initrd \
  --distro rocky --version 9.7 --arch aarch64 \
  --kernel-release 5.14.0-611.5.1.el9_7.aarch64
nodeforge profile create rocky-9.7-aarch64-dvd --kind diskless

# 3. 由 nodeforged 构建并发布 rootfs。
nodeforge profile rootfs plan rocky-9.7-aarch64-dvd-diskless --output json
nodeforge profile rootfs build rocky-9.7-aarch64-dvd-diskless \
  --if-input-digest <rootfs_input_digest>
nodeforge profile rootfs status rocky-9.7-aarch64-dvd-diskless
# 不提供外部 squashfs register/import；ready artifact 只能来自上述服务端 build。
# 可选：--keep-staging 保留解包树（work/rootfs-staging/<digest>）供 chroot 特需；
#       --from-staging 基于保留树再打包；profile rootfs staging list|show|remove 查询/清理。
# v0.4.1 staging 会话（需 root）：
#   nodeforge profile rootfs staging enter <profile>     # 交互 shell（cgroup 限额可用）
#   nodeforge profile rootfs staging exec <profile> --timeout 30 -- <cmd>...
#   nodeforge profile rootfs staging kernels <profile>   # 扫描树内内核
#   nodeforge profile rootfs build <profile> --from-staging --kernel-release auto  # 导入启动面内核

# 4. 绑定节点、检查 readiness、打开 deploy gate。
nodeforge node set node-01 profile=rocky-9.7-aarch64-dvd-diskless
nodeforge node readiness node-01 --stage boot
nodeforge node boot preview node-01
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

### v0.3 双机实机验收流程

下面是 2026-08-02 在 `r97n0`（Rocky 9.8 aarch64 管理节点）和 VMware Fusion
中的 `r97n1`（UEFI aarch64 计算节点）完成的 fresh 验收流程。示例地址和接口属于
该验证环境，其他站点必须先替换；完整结果与 journal 证据见
[`docs/archive/validation/V0_3_VALIDATION.md`](docs/archive/validation/V0_3_VALIDATION.md)。

> **破坏性操作**：清场会停止 NodeForge 并删除 `/opt/nodeforge` 中的配置、Catalog、
> ISO 副本、rootfs、状态和日志。执行前必须再次确认 `hostname`、安装根和 unit 路径；
> 原始 ISO 应保存在安装根之外。不要用宽泛路径或未解析变量替换下列精确目标。

#### 1. 确认目标并清理旧环境

```bash
ssh root@r97n0 '
  hostname
  uname -m
  systemctl show nodeforged -p FragmentPath -p ActiveState -p SubState
  systemctl cat nodeforged --no-pager
  pgrep -a -x nodeforged || true
  ss -lntup | grep -E ":(67|69|18080)([[:space:]]|$)" || true
'

ssh root@r97n0 '
  set -euo pipefail
  test "$(hostname)" = r97n0
  systemctl stop nodeforged.service 2>/dev/null || true
  systemctl disable nodeforged.service 2>/dev/null || true
  rm -f /etc/systemd/system/nodeforged.service /etc/profile.d/nodeforge.sh
  rm -rf --one-file-system /opt/nodeforge
  systemctl daemon-reload
  test ! -e /opt/nodeforge
  systemctl is-active sshd
  systemctl is-active NetworkManager
'
```

#### 2. 交叉编译、核验和部署四个程序

```bash
zig version
git rev-parse --short=12 HEAD
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe

for program in nodeforge nodeforged nodeforge-initrd nodeforge-agent; do
  test -x "zig-out/bin/$program"
  file "zig-out/bin/$program"
  shasum -a 256 "zig-out/bin/$program"
done

ssh root@r97n0 'rm -rf /tmp/nodeforge-v03-bundle && mkdir -p /tmp/nodeforge-v03-bundle'
scp zig-out/bin/{nodeforge,nodeforged,nodeforge-initrd,nodeforge-agent} \
  root@r97n0:/tmp/nodeforge-v03-bundle/
ssh root@r97n0 '/tmp/nodeforge-v03-bundle/nodeforge --version'
```

`nodeforge-initrd` 是 initramfs 的 PID 1，不能把直接执行
`nodeforge-initrd --version` 当作普通版本检查；这样会进入实际 bootstrap 流程。
它与 `nodeforge-agent` 应通过同一构建命令、ELF 架构、摘要、initrd/rootfs 注入结果和
实际 diskless 启动共同核验。

再次执行第 1 步的精确清场后，仅用发布目录中的 `setup` 初始化：

```bash
ssh root@r97n0 '
  set -euo pipefail
  cd /tmp/nodeforge-v03-bundle
  ./nodeforge setup --install-root /opt/nodeforge --non-interactive --yes \
    --bind-interface enp26s0 --server-ip 192.168.27.128 \
    --subnet 192.168.27.0/24 \
    --pool-start 192.168.27.220 --pool-end 192.168.27.240
  ./nodeforge setup --install-root /opt/nodeforge --generate-systemd --install \
    --non-interactive --yes
  systemctl start nodeforged
  /opt/nodeforge/bin/nodeforge status --output json
  /opt/nodeforge/bin/nodeforge config validate --output json
  /opt/nodeforge/bin/nodeforge catalog validate --output json
'
```

DHCP 池必须避开管理节点、网关和 `r97n1` 的 reservation；本次环境使用
`.220-.240`，`r97n1` 使用 `.210`。

#### 3. 仅通过 CLI 导入介质并构建三套 diskless Profile

```bash
ssh root@r97n0 '
  set -euo pipefail
  nodeforge assets import /root/Rocky-9.7-aarch64-minimal.iso
  nodeforge assets import /root/Rocky-10.2-aarch64-dvd1.iso
  nodeforge assets import /root/ubuntu-22.04.5-live-server-arm64.iso
  nodeforge assets install-source list --output json
  for source in \
    rocky-9.7-aarch64-minimal \
    rocky-10.2-aarch64-dvd1 \
    ubuntu-22.04.5-live-server-arm64; do
    nodeforge assets install-source show "$source" --output json
  done
  nodeforge catalog validate --output json
'
```

导入结果必须分别识别为 `rocky/9.7/aarch64`、`rocky/10.2/aarch64` 和
`ubuntu/22.04.5/aarch64`，并检查 installer kernel/initrd、Minimal、
BaseOS/AppStream、APT repository 和 casper layers。随后构建 initrd 和 boot bundle：

```bash
ssh root@r97n0 '
  set -euo pipefail
  nodeforge assets initrd build rocky-9.7-nodeforge-initrd \
    --from-install-source rocky-9.7-aarch64-minimal \
    --kernel-release 5.14.0-611.5.1.el9_7.aarch64
  nodeforge assets initrd build rocky-10.2-nodeforge-initrd \
    --from-install-source rocky-10.2-aarch64-dvd1 \
    --kernel-release 6.12.0-211.16.1.el10_2.0.1.aarch64
  nodeforge assets initrd build ubuntu-22.04.5-nodeforge-initrd \
    --from-install-source ubuntu-22.04.5-live-server-arm64 \
    --kernel-release 5.15.0-119-generic

  nodeforge assets boot-bundle create rocky-9.7-aarch64-minimal \
    --kernel rocky-9.7-aarch64-minimal-kernel \
    --initrd rocky-9.7-nodeforge-initrd \
    --distro rocky --version 9.7 --arch aarch64 \
    --kernel-release 5.14.0-611.5.1.el9_7.aarch64
  nodeforge profile create rocky-9.7-aarch64-minimal --kind diskless

  nodeforge assets boot-bundle create rocky-10.2-aarch64-dvd1 \
    --kernel rocky-10.2-aarch64-dvd1-kernel \
    --initrd rocky-10.2-nodeforge-initrd \
    --distro rocky --version 10.2 --arch aarch64 \
    --kernel-release 6.12.0-211.16.1.el10_2.0.1.aarch64
  nodeforge profile create rocky-10.2-aarch64-dvd1 --kind diskless

  nodeforge assets boot-bundle create ubuntu-22.04.5-live-server-arm64 \
    --kernel ubuntu-22.04.5-live-server-arm64-kernel \
    --initrd ubuntu-22.04.5-nodeforge-initrd \
    --distro ubuntu --version 22.04.5 --arch aarch64 \
    --kernel-release 5.15.0-119-generic
  nodeforge profile create ubuntu-22.04.5-live-server-arm64 --kind diskless
'
```

对每个 `*-diskless` Profile 先读取不可变 input digest，再提交构建：

```bash
profile=rocky-9.7-aarch64-minimal-diskless
plan=$(ssh root@r97n0 "nodeforge profile rootfs plan $profile --output json")
digest=$(printf '%s' "$plan" | jq -r .result.rootfs_input_digest)
ssh root@r97n0 \
  "nodeforge profile rootfs build $profile --if-input-digest $digest --output json"
ssh root@r97n0 "nodeforge profile rootfs status $profile --output json"
```

Rocky 10.2 和 Ubuntu Profile 使用相同步骤。三个 `rootfs status` 都必须为
`state=ready`，且 `rootfs_input_digest`、kernel release、SHA-512、压缩/展开大小和
文件路径完整。

#### 4. 从管理节点 hosts 登记 r97n1

```bash
ssh root@r97n0 '
  set -euo pipefail
  node_ip=$(getent hosts r97n1 | awk "NR==1 { print \$1 }")
  test -n "$node_ip"
  nodeforge node add r97n1 \
    mac=00:50:56:2A:23:DB arch=aarch64 \
    profile=rocky-10.2-aarch64-dvd1-diskless \
    pxe.ip_reservation="$node_ip" deploy=false
  nodeforge node show r97n1 --output json
  nodeforge node software show r97n1 --output json
  nodeforge node readiness r97n1 --stage boot --output json
  nodeforge node boot preview r97n1 --output json
'
```

不要从工作站 DNS、旧 deployment 或手写常量推断节点 IP。`node show` 中还应确认
MAC、aarch64、受管 repo、`system.import_host_hosts=true`、SSH policy、存储和
deploy gate。第一次 diskless 启动后，从 r97n0 使用服务端 bootstrap key 验证：

```bash
ssh root@r97n0 \
  'ssh -o BatchMode=yes -o StrictHostKeyChecking=no root@192.168.27.210 \
   "cat /etc/os-release; uname -r; findmnt -n -o FSTYPE /; \
    grep -E \"r97n0|r97n1\" /etc/hosts; systemctl --failed"'
```

#### 5. Compute Use 驱动 VMware，CLI 驱动部署矩阵

VMware Fusion 中只执行虚拟机电源和界面操作：通过 Computer Use 选择 `r97n1`，
从每次最新的 accessibility state 定位 `Start Up` 或 `Shut Down` 按钮，点击后重新
读取界面状态确认结果。不要复用旧 element index，也不要在 VMware UI 中修改
NodeForge 业务配置。Profile、deploy、retry 和 readiness 始终通过 CLI：

```bash
# install：必须显式 rearm generation
nodeforge node set r97n1 \
  profile=rocky-9.7-aarch64-minimal-install \
  storage.boot_disk=/dev/nvme0n1 --force
nodeforge node retry r97n1 --force
nodeforge node boot preview r97n1 --output json

# diskless：绑定 ready profile 并打开 deploy gate
nodeforge node set r97n1 \
  profile=rocky-10.2-aarch64-dvd1-diskless --force
nodeforge node readiness r97n1 --stage boot --output json
nodeforge node deploy r97n1 true
nodeforge node boot preview r97n1 --output json
```

按以下顺序冷启动，每项完成后从 r97n0 SSH 验证 `/etc/os-release`、`uname -r`、
`/etc/hosts`、Yum/APT repo、SSH 和 failed units；diskless 还必须确认 `/` 为
`overlay`：

1. `rocky-9.7-aarch64-minimal-install`
2. `ubuntu-22.04.5-live-server-arm64-install`
3. `rocky-9.7-aarch64-minimal-diskless`
4. `rocky-10.2-aarch64-dvd1-diskless`
5. `ubuntu-22.04.5-live-server-arm64-diskless`

Install PASS 条件包括 `terminal_generation == successful_generation ==
current_generation`、requested/applied/desired plan digest 一致且
`drift_state=clean`。Diskless PASS 条件包括 readiness 无 issue、实际发行版和 kernel
匹配、overlay 根、仅保留 NodeForge 受管 repo，并能使用 bootstrap key SSH 登录。

#### 6. install-post canonical 与自动化收口

仓库脚本会创建全新 bundle，导入 managed file、archive 和 script 制品，加入
`managed_file → package → archive → script` actions，绑定 Rocky 9.7 install
Profile，执行真实 PXE 安装并核验目标内容：

Archive 的模式入口是顶层保留隐藏文件 `.nf.install.sh`：只有 tar 中精确的
`.nf.install.sh` 或 `./.nf.install.sh` 才触发“解压到临时目录后执行”的模式 A；普通
顶层 `install.sh`、子目录脚本和其他可执行文件都按数据处理并走直接解压的模式 B。
入口由 `sh ./.nf.install.sh` 执行，不依赖 executable bit，但必须幂等且不得隐式下载
未声明内容。

推荐用公开 CLI 构建标准 Mode A archive，而不是手工重命名安装脚本：

```bash
# 多个路径直接作为位置参数；路径均相对于 --base-dir。
nodeforge assets archive build ./vendor-agent.tar \
  --install-script ./packaging/install.sh \
  --base-dir ./payload \
  etc/vendor-agent usr/lib/vendor-agent

# 或从文本文件读取（一行一个相对路径），并可与位置参数合并。
nodeforge assets archive build ./vendor-agent.tar \
  --install-script ./packaging/install.sh \
  --base-dir ./payload \
  --files-from ./packaging/files.list \
  usr/share/vendor-agent/README

# 可选 gzip/xz；省略 --compression 时仍生成未压缩 .tar。
nodeforge assets archive build ./vendor-agent.tar.gz \
  --compression gzip \
  --install-script ./packaging/install.sh \
  --base-dir ./payload \
  --files-from ./packaging/files.list

nodeforge assets archive build ./vendor-agent.tar.xz \
  --compression xz \
  --install-script ./packaging/install.sh \
  --base-dir ./payload \
  --files-from ./packaging/files.list

nodeforge assets archive import vendor-agent \
  --from-file ./vendor-agent.tar --media-type application/x-tar
```

`--install-script` 不是必填项。省略时构建 Mode B 数据归档，普通 `install.sh` 只作为
数据文件解压，不会执行：

```bash
nodeforge assets archive build ./static-files.tar \
  --base-dir ./payload \
  etc usr
```

`archive build` 需要 GNU tar，默认输出未压缩 PAX `.tar`；可显式选择
`--compression gzip|xz`，对应 `.tar.gz`/`.tgz` 或 `.tar.xz`/`.txz`。构建先完成并校验
完整 tar，再执行最终压缩；运行端仍统一以 `tar -xf` 自动识别。仅当指定
`--install-script` 时才生成 Mode A 的 `.nf.install.sh`；缺省为无入口的 Mode B。
rootfs builder 默认尝试提供 `tar`、`gzip` 和 `xz`；缺失时记录 warning，但不阻断
没有 archive action 的普通 rootfs。真正执行 archive 时若工具仍缺失，由该 action
失败并写入 journal。命令把用户提供的安装脚本映射为归档顶层
`.nf.install.sh`。payload 自带该保留顶层条目时拒绝构建；绝对路径、
含 `..` 的路径和换行路径同样拒绝。所有 payload 在一次 tar 调用中读取，保留软链接
目标和跨输入项硬链接关系，并记录数字 uid/gid、mode、mtime、ACL 与 xattr；打包使用
`--atime-preserve=system`，不应因读取而更新源文件 atime。解压显式恢复 owner、mode、
ACL 与 xattr。ctime 是内核维护的 inode 变更时间，新建解压文件必然获得新 ctime，任何
工具都不能合法还原；解压后的 atime 也不属于 tar 的可靠跨系统还原契约。CLI 因而
明确报告 `ctime_preserved=false`，不得把“归档记录过某个时间”误解为“解压后完全一致”。

rootfs 中的能力边界如下：

| 检查 | 缺失时行为 | 原因 |
|---|---|---|
| init/systemd/包管理器/SSH 等核心基线 | rootfs build 失败 | 普通系统本身不可用 |
| `tar`/`gzip`/`xz` 可选 archive 工具 | 记录 warning，继续构建 | Profile 可能没有 archive action |
| action 实际解压 archive | action 失败并写 journal | 此时工具成为该步骤的真实依赖 |

因此不要把 rootfs 日志中的 `optional archive tools ... may fail` warning 当成普通
rootfs 发布失败；只有该 Profile 确实声明了相关 archive action 时才需要补齐工具或
调整归档格式。

```bash
bash tests/v0_3_install_post_e2e.sh
# 等价的显式 build step：
zig build test-v0.3-install-post-e2e
```

验收 journal：

```bash
ssh root@r97n0 \
  'nodeforge node postprocess show r97n1 --phase install-post --output json'
ssh root@r97n0 \
  'nodeforge node show r97n1 --output json | jq .result.deployment'
ssh root@r97n0 \
  'nodeforge events list --node r97n1 --limit 100 --output json'
```

所有 action 和 `@finalizer` 必须按固定顺序 `attempts=1`、`succeeded`；在此之前
`install.completed` 必须被 completion gate 拒绝。完成后 generation 必须
terminal/successful 一致且 drift clean。另需通过 CLI 导入恶意 tar，确认不可读、
绝对路径和 `..` 路径均返回 `archive.invalid`；向新 bundle 添加 `repository` 或
`standard_packages` 必须返回 `InvalidStepAction`，不能存在兼容或 fallback。

最后执行完整自动化并验证 daemon 重启恢复：

```bash
zig build test
ssh root@r97n0 '
  systemctl restart nodeforged
  # systemd active 不等于管理面已经 ready；轮询到完整健康后再判定。
  for attempt in $(seq 1 30); do
    nodeforge status --output json | jq -e ".ok and .result.ok" && break
    sleep 1
  done
  nodeforge node postprocess show r97n1 --phase install-post --output json
'
```

`zig build test` 覆盖 callback 认证和 generation 绑定、attempt 跳号、顺序、early
finalizer、completion gate、archive fail-closed、旧 action 拒绝和 interrupted
`committing` WAL 恢复；真实重启后 completed journal 也必须保持可读。任何必要检查
缺失或失败，整轮结论都必须是 FAIL。

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
