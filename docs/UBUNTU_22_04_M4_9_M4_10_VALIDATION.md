# M4.9b / M4.10 Ubuntu 22.04.5 PXE 验证

> 验证日期：2026-07-19（Asia/Shanghai；r97n0 日志时钟显示 2026-07-18）。
> 服务端：r97n0，Rocky Linux 9.7 aarch64，`192.168.27.128`。
> 客户端：VMware Fusion `r97n2-ubuntu`，UEFI aarch64，vmnet2，MAC
> `00:50:56:24:F7:27`，20 GiB NVMe。

## 1. 本地门槛

- `zig build test --summary all`：244/244。
- `git diff --check`：通过。
- `make arm64`：`aarch64-linux-gnu ReleaseSafe` 通过。
- 最终实机二进制 SHA-256：
  - `nodeforge`：`da79abe11954778bf931c9b475ca56bb0f38588429ef8c0e4670bad09b3b1919`
  - `nodeforged`：`e09f9dab5f14dccf4b4d57191be8ea7c44b1cef6bdf411c6bc5f98f4c172ff58`

## 2. schema 迁移与 node-scoped 隔离

旧 r97n1 状态从 deployment schema 2、BootSession schema 3、node-status schema 4
升级为 schema 3/4/5。旧 u64 applied provenance 没有被伪造成完整基线：

- r97n1 `applied_plan_digest=null`；
- `drift_state=unknown`；
- 不恢复旧 capability，也不自动 rearm。

导入 Ubuntu source/profile 前后，r97n1 的 desired plan 前缀均为
`2af520e2a78e`。新增未引用 ISO/profile/node 没有扰动该节点 digest；旧全局
`desired_revision` 发生变化只作为兼容观测，不参与授权。

## 3. Ubuntu 介质与发布资产

输入与 r97n0 受管 ISO 的 SHA-256 均为：

```text
eafec62cfe760c30cac43f446463e628fada468c2de2f14e0e2bc27295187505
```

导入器识别并原子发布：

- install source/default profile：`ubuntu-22.04-aarch64-iso`
- kernel：
  `9b9c41ab6bf60cddfb1052751896e35b52e49cf03ebc8f13c6b039e7ca64440b`
- initrd：
  `f7f126e2d12a2c10046778f200a1ebca3126009ffbff7c3ed3d645b7de6064ae`
- canonical GRUB：
  `176c1c1da6fac219ffea817c5d5cf19f2fd6ad17e9f01005220c40f035d0bc45`

profile 通过受约束 mutation 将 boot disk 设置为 `/dev/nvme0n1`。

## 4. 完整 PXE 安装

Computer Use 在 VMware Fusion 中创建 `r97n2-ubuntu`、选择 Ubuntu 64-bit Arm、
连接 vmnet2 并将 Network Adapter 设为启动设备。服务端观测到：

1. DHCP DISCOVER/OFFER/REQUEST/ACK，地址 `192.168.27.211`；
2. TFTP 下载 `efi/grubaa64.efi`、per-MAC GRUB config、kernel 和 initrd；
3. initramfs 经 HTTP Range 下载 2,061,889,536-byte Ubuntu ISO；
4. Subiquity 获取 immutable install plan，generation 1 从 armed 转为 consumed；
5. `install_packages`、`install_bootloader`、completed；
6. requested/consumed/applied/desired digest 全部为
   `16180763fbc37808179ddb82aaf015c2b203230af72739be8c1e2814516855f8`，
   drift=`clean`；
7. 网络启动无 bootfile 后固件回退 NVMe，屏幕进入
   `Ubuntu 22.04.5 LTS r97n2 tty1`。

从 r97n0 SSH 到目标机复核：

```text
PRETTY_NAME="Ubuntu 22.04.5 LTS"
Linux r97n2 5.15.0-119-generic ... aarch64
/      /dev/nvme0n1p2 ext4
/boot/efi /dev/nvme0n1p1 vfat
```

## 5. force retry 负向闭环

在 generation 2 已被活动安装 session 消费后：

- 普通 `node retry r97n2` 被 `install.session_active` 拒绝；
- `node retry r97n2 --force` 终止旧 capability 并武装 generation 3；
- generation 3 重新完成完整 Ubuntu PXE，最终 requested/consumed/applied digest
  仍完全一致，状态 completed、drift=`clean`；
- VMware 再次从 NVMe 启动进入 Ubuntu 22.04.5 登录界面。

该流程证明 force 不是直接复用旧 token，也不是手工删除 checkpoint；它建立新
generation/session 后重新走完整授权和安装链路。

## 6. 实机发现并回补的问题

- 启动时按已有节点数收敛的 M4.8 projection capacity 会阻止在线添加第二节点。
  在线 node add 现只增不减地扩大 deployment/status/inventory effective capacity，
  保留更大的显式 override 并继续受 2048 安全天花板约束。
- ISO 自动 profile 的 `source_label=null` 曾使 human `profile show` DTO 解析失败；
  CLI 现按 optional 字段解析并回退 source name。
- 普通 retry 曾使用只返回健康布尔值的 probe，折叠了
  `install.session_active`/request id；现统一走 management mutation 错误信封。

## 7. 验收结论

M4.9b 的完整 node-scoped SHA-256 持久化、旧 schema fail-closed 迁移、PXE
授权/恢复/drift join，以及 M4.10 fresh Ubuntu CLI/PXE/force-retry 闭环均已有
自动测试和 r97n0/VMware 实机证据。

最终二进制上另以 `SIGSTOP` 暂停 active daemon，制造“service state 存在但
HTTP 不响应”的 readiness 故障。首次注入发现旧 probe 没有 receive deadline，
所谓 5 秒窗口可能无限阻塞；修复为每次 250ms I/O 上限、15 次约 5 秒总窗口后重测：

```text
rc=1
elapsed=6s
enabled=enabled/enabled
active=active/active
health={"ok":true,"service":"nodeforge"}
error: internal: SystemdHealthCheckFailed
```

旧/新 unit 链接均为 `/opt/nodeforge/systemd/nodeforged.service`，enabled/active
状态完全恢复，恢复 daemon 后健康探针通过。M4.9b/M4.10 本轮验收完成。
