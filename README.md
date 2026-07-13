# NodeForge
一个基于 Zig 实现的轻量级 OS Provisioning 平台，面向小型 Linux 集群，内置 DHCP/TFTP/HTTP 服务，提供 PXE 引导、多 Linux 发行版无人值守安装、内存无盘启动、系统镜像/安装源分发和未来的软件包管理能力。

基于 Zig 0.16 · 内置 DHCP/TFTP/HTTP · PXE 引导 · 多系统无人值守安装 · 内存无盘启动 · 软件包管理预留

## 设计文档

- [NodeForge PXE 特化版概要设计](docs/DESIGN.md)
- [NodeForge 分阶段详细设计与实现计划](docs/DETAILED_DESIGN.md)
- [M0–M4.1 实现审计](docs/M0_M4_AUDIT.md)
- [Rocky Linux 8.10 aarch64 VMware PXE 验证](docs/ROCKY_8_10_VALIDATION.md)

## 当前阶段

M0-M3 的基础服务、PXE 协议、HTTP 资产和安装源链路已有实现与验证记录；M4/M4.1 的 Rocky 9.7 与
Ubuntu 22.04 正向无人值守安装、登录和生命周期链路均已完成实机验证。M4.1 的异常恢复与边界收口
仍按审计清单持续回归；Rocky 8.10 aarch64 因 VMware/Apple-Silicon 不支持介质内核要求的 64 KiB
page granule 单独暂缓，不影响 Rocky 9.7/Ubuntu 22.04 的已验收结论。M4.1 统一交付
locale/timezone/keyboard、纯本地连接策略、默认 OpenSSH/root 密码登录、普通用户/password/sudo/逐账号 key、
额外包、目标系统 DHCP/静态 IPv4、
默认关闭主机防火墙，以及 Rocky 默认关闭 SELinux。M4.1 还承担 M0-M4 answer 审计补丁：SHA-512 crypt
`$6$`、NodeForge bootstrap admin public key 始终合并、Ubuntu identity/schema/storage、Rocky rootpw/
bootloader 和 installer 事件上下文。上述目标系统字段统一归入 `profile.system`；M5-M7 均须继承同一模型、
默认值与认证语义，不能另设 diskless 私有 users/packages 或较弱默认。

M4.1 同时补齐自动安装生命周期：install profile 默认一次性 generation，成功或已消费节点再次 PXE 不会
自动重装，`install retry` 只显式 rearm 下一次 PXE，不倒退历史状态或调用 BMC；目标配置变更只形成
desired/applied drift。TFTP option、DHCP T1/T2、trace 时钟回拨、运行期 asset 和 ISO orphan/空间预检等
M1-M3 横切修正仍写在各自章节，但作为 M4.1 验收前置回归。

NodeForge 配置中所有语义为 `password` 的字段都允许填写明文，并以明文写入 JSON、导入和导出；
包括系统用户、root、IPMI，以及未来新增的 repository/proxy/basic-auth 等密码字段。发行版安装器要求
hash 时只在渲染/下发阶段临时转换，不能把 hash 回写成配置事实。token、session capability、SSH 私钥和
已经生成的 password hash 不是 password 配置字段，仍按各自的短期或受限传递规则处理。

[`config.example.json`](config.example.json) 只展示当前代码能够加载和校验的配置。M4.1 schema、默认值和
迁移规则以详细设计第 9.10 节为准；相关变更必须同步更新代码、示例配置、fixture 和验证记录。

## 开发

```bash
zig build test
zig build
zig-out/bin/nodeforge -h
zig-out/bin/nodeforge config --help
zig-out/bin/nodeforge config validate --help
zig-out/bin/nodeforge config validate --config config.example.json --catalog catalog.example.json
zig-out/bin/nodeforge catalog validate --config config.example.json --catalog catalog.example.json
zig-out/bin/nodeforged --config config.example.json --catalog catalog.example.json --check-config
zig-out/bin/nodeforged --config config.example.json --catalog catalog.example.json --check
```

## Make Targets

`Makefile` 只封装现有 Zig 构建参数：

```bash
make build          # 本机构建（Debug）
make test           # 本机单元、CLI 契约与 HTTP 集成测试
make release        # 本机 ReleaseSafe 构建
make arm64          # 交叉编译 Rocky Linux aarch64 ReleaseSafe 二进制
make arm64-debug    # 交叉编译 aarch64 Debug 二进制
```

`make arm64` 使用 `aarch64-linux-gnu`；可通过 `ARM64_TARGET=<zig-target>` 覆盖目标三元组。
交叉构建产物仍位于 `zig-out/bin/`，再次执行 `make build` 可恢复本机架构产物。

正常安装默认使用 `/opt/nodeforge/config/config.json` 和
`/opt/nodeforge/catalog/catalog.json`，无需传 `--config`/`--catalog`；这些参数主要用于
开发、测试和临时排障覆盖路径。

`config.example.json` 中的 `server.bind_interface = "enp1s0"` 是 Linux PXE 网卡占位值；部署
DHCP 前必须替换为承载 `server.server_ip` 的实际接口。当前 DHCPv4 服务会拒绝空值，避免 wildcard
UDP/67 在多网卡主机上失去接口边界。

CLI 使用仓库内固定的 `zli v5.1.2`。命令、参数、默认值和说明由同一命令树生成，
新增参数不需要再同步维护手写 help。zli 的 spinner 能力暂未启用；未来只在 TTY 的
耗时 human 输出命令中按需使用，JSON、管道和 systemd 场景保持无动画输出。

NodeForge 只有一个 HTTP listener，默认端口 `8080`，健康检查、管理 API 和 M3+ PXE 数据路由
复用该端口。listener 绑定 `0.0.0.0:<http_port>`；管理路由在入口检查 direct peer，只接受
`127.0.0.1`，且不信任 `X-Forwarded-For`。`nodeforge` CLI 固定通过
`127.0.0.1:<http_port>` 调用管理接口，不提供远程 endpoint 参数，因此 CLI 只支持管理同机
`nodeforged`。管理 API 尚无鉴权和 TLS，部署时
必须限制在受信任网络；后续若作为正式远程管理接口使用，需要单独设计鉴权、TLS 和审计。

`nodeforge` 只把 `-v/--version` 放在顶层；`-h/--help` 由 zli 在每一级命令提供。
`--config`、`--catalog`、`--output` 是业务命令自己的参数，必须写在对应命令之后，且只在该
命令实际读取时出现。M0 的 `config import` 是只校验 source config 自身的离线文件操作，
不读取 catalog；完成后必须重启 `nodeforged`。跨文件关系由 `config validate`、
`catalog validate` 和 daemon 启动校验。

服务默认输出 `info` 日志到 stderr/systemd journal。`config.json` 的 `logging.level` 可设置为
`info` 或 `debug`；临时排障使用 `nodeforged -d` 强制本次启动输出 debug 服务日志，或在
`nodeforge` 叶子命令后使用 `-d` 显示底层错误原因。默认错误保持简短，例如
`error: config: file not found: ./config.json`。

Linux systemd unit 位于 `packaging/systemd/nodeforged.service`。DHCP 使用 UDP/67 和发送
Ping Probe 所需的 raw ICMP，因此 unit 同时授予 `CAP_NET_BIND_SERVICE` 与 `CAP_NET_RAW`；当
Probe 不可用时服务会拒绝 OFFER，而不会把地址当作空闲。Linux 上 DHCP 以 wildcard UDP/67
接收客户端广播，并通过 `SO_BINDTODEVICE` 限定 `server.bind_interface`，不会回答管理网卡请求。
Rocky Linux 9.7 aarch64 的 `192.168.27.0/24` 已完成 DHCP 生命周期、冲突隔离、M2 CLI/API 和
独立 UEFI 固件到 GRUB 的 PXE/TFTP 闭环验证。完整记录见
[`docs/ROCKY_9_7_VALIDATION.md`](docs/ROCKY_9_7_VALIDATION.md)。

## M2.5.1 启动追踪

每次 DHCP `DISCOVER`/`REQUEST` 会在 daemon 进程内创建或复用一个不可预测的
32 字符小写十六进制 `boot_session_id`（128-bit）。同一启动尝试的 DHCP 与经唯一 lease-IP 安全关联的
TFTP 事件都会记录该 id；每条 daemon Event v2 同时带有 `daemon_instance_id`，用于识别
服务重启边界。session 仅存在于当前进程：超时、被新 XID 替换或有序停机时，daemon 会追加
`boot.session.terminated`，不会在重启后恢复旧关联。

TFTP 不会根据文件名、传输端口或“最近 DHCP 记录”猜测节点归属。若活动 lease-IP 没有唯一
匹配，事件保留 `session_link_state`（例如 `no_active_lease_match`、`ambiguous_lease_match`
或 `capacity_exhausted`），而不是伪造 `boot_session_id`。

本机排障可直接读取审计流，不会访问管理 API 或改变服务状态：

```bash
nodeforge events list --node node-01 --session 0123456789abcdef0123456789abcdef
nodeforge trace node-01 --latest
nodeforge trace node-01 --session 0123456789abcdef0123456789abcdef --output json
```

`trace` 仅展示具有直接 session 证据的事件，并把容量耗尽、损坏 JSONL 记录和 daemon
重启等不连续情况写入 `gaps`；因此它是审计重建工具，而不是会在信息不足时补全事实的状态机。
