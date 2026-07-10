# Rocky Linux 9.7 环境验证清单

本文只记录当前 macOS 开发环境无法完成的系统级验证。功能实现和纯逻辑测试仍在
本地完成；这里的项目不能在实际验证前标记为通过。

## 环境

- 首选 Rocky Linux 9.7 aarch64 虚拟机。
- 当前可用验证机：`ssh root@r97n0`，地址 `192.168.26.128`。
- 后续使用 Rocky Linux 9.7 x86_64 验证生产优先架构。
- 虚拟机使用独立 PXE 测试网络，避免影响现有 DHCP。
- 虚拟机缺少验证工具时，可以通过 `dnf` 或 `yum` 安装，例如 `curl`、`tftp`、`atftp`、`tcpdump`、`iproute` 等。

## 安装布局

验证时按 `/opt/nodeforge` 单根目录部署：

```text
/opt/nodeforge/
  bin/
  systemd/
  config/
  catalog/
  state/
  logs/
  assets/
  repos/
  tftp/
  initrd/
  rootfs/
  bundles/
  work/
```

系统级位置只放软链接：

- `/etc/systemd/system/nodeforged.service -> /opt/nodeforge/systemd/nodeforged.service`
- `/usr/bin/nodeforge -> /opt/nodeforge/bin/nodeforge`
- `/usr/bin/nodeforged -> /opt/nodeforge/bin/nodeforged`

M0 默认 HTTP/管理共用端口为 `8080`。管理 API 没有独立端口，只允许 VM 本机通过 `127.0.0.1:8080` 访问；从宿主机访问管理路由应返回 403。

## M1 TFTP 待验证

- [ ] `nodeforged --check` 能识别 UDP 69 已占用、地址不存在和权限不足。
- [ ] 使用系统 `tftp` 或 `atftp` 下载 `grubaa64.efi`。
- [ ] 使用系统 `tftp` 或 `atftp` 下载 `grubx64.efi`。
- [ ] 下载超过一个 block 的 kernel/initrd，SHA256 与源文件一致。
- [ ] 验证 `blksize`、`timeout`、`tsize` 的 OACK 行为。
- [ ] 丢弃 ACK，确认按配置重传并最终超时。
- [ ] 请求 `../`、绝对路径、未登记资产和符号链接逃逸路径，确认全部拒绝。
- [ ] 发起 WRQ，确认返回 access violation 且磁盘没有新增文件。
- [ ] 并发下载压测后确定会话并发上限；当前实现先保证串行协议闭环。

## 验证记录

执行时记录日期、架构、内核、Zig 构建版本、命令、结果和失败日志。只有上述项目
在目标虚拟机实际执行后，才更新对应阶段的系统级验收状态。
