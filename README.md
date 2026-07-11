# NodeForge
一个基于 Zig 实现的轻量级 OS Provisioning 平台，面向小型 Linux 集群，内置 DHCP/TFTP/HTTP 服务，提供 PXE 引导、多 Linux 发行版无人值守安装、内存无盘启动、系统镜像/安装源分发和未来的软件包管理能力。

基于 Zig 0.16 · 内置 DHCP/TFTP/HTTP · PXE 引导 · 多系统无人值守安装 · 内存无盘启动 · 软件包管理预留

## 设计文档

- [NodeForge PXE 特化版概要设计](docs/DESIGN.md)
- [NodeForge 分阶段详细设计与实现计划](docs/DETAILED_DESIGN.md)

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

M0 只有一个 HTTP listener，默认端口 `8080`，当前提供健康检查和管理 API；M3 的 PXE HTTP
数据路由将复用该端口。
listener 绑定 `0.0.0.0:<http_port>`，管理路由接受所有能到达该端口的 IPv4 客户端，不做
peer 来源检查。`nodeforge` CLI 固定通过 `127.0.0.1:<http_port>` 调用管理接口，不提供远程
endpoint 参数，因此 CLI 只支持管理同机 `nodeforged`。M0 管理 API 尚无鉴权和 TLS，部署时
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
