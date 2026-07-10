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
zig-out/bin/nodeforge --config config.example.json --catalog catalog.example.json config validate
zig-out/bin/nodeforge --config config.example.json --catalog catalog.example.json catalog validate
zig-out/bin/nodeforged --config config.example.json --catalog catalog.example.json --check-config
zig-out/bin/nodeforged --config config.example.json --catalog catalog.example.json --check
```

正常安装默认使用 `/opt/nodeforge/config/config.json` 和
`/opt/nodeforge/catalog/catalog.json`，无需传 `--config`/`--catalog`；这些参数主要用于
开发、测试和临时排障覆盖路径。

M0 只有一个 HTTP listener，默认端口 `8080`。管理 API 与 PXE HTTP 数据路由共用该端口，
但管理路由只接受 loopback 来源；CLI 固定通过 `127.0.0.1:<http_port>` 调用管理接口。

Linux systemd unit 位于 `packaging/systemd/nodeforged.service`。
当前 macOS 无法完成的 Linux/systemd/TFTP 系统级项目记录在
[`docs/ROCKY_9_7_VALIDATION.md`](docs/ROCKY_9_7_VALIDATION.md)，部署 Rocky Linux
9.7 虚拟机后逐项执行。
