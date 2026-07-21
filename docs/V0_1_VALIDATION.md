# NodeForge v0.1 验证记录

更新时间：2026-07-21（Asia/Shanghai）

## 自动化回归

- 本地 `zig build test --summary all`：12/12 steps，285/285 tests。
- `r97n0` 同一源码全量回归：12/12 steps，285/285 tests；测试后生产 `nodeforged=active`。
- `r97n0` 状态探针：process、loopback HTTP、advertised HTTP、management、active config、catalog、DHCP、TFTP 全部为 true；`server_ip=192.168.27.128`。
- schema v3 config/catalog migration、plan/digest/apply/rollback、活动会话保护、CLI/API/output/property contracts 均由全量测试覆盖。

## 实机 PXE 矩阵

验证硬件为 VMware Fusion `r97n1`，UEFI、vmnet2、NVMe 主盘 `/dev/nvme0n1`，三块 SATA 附加盘 `/dev/sda`、`/dev/sdb`、`/dev/sdc`。全部安装均通过 NodeForge DHCP/TFTP/HTTP 和真实安装器完成，没有使用存储脚本。

- Rocky Linux 9.7 aarch64：`single`、`lvm`、`raid0`、`raid1`、`raid5`、`raid6`、`raid10`、`raid0-lvm`、`raid1-lvm`、`raid5-lvm`、`raid6-lvm`、`raid10-lvm`，12/12 completed。
- Ubuntu 22.04.5 aarch64：同一组 12 个 mode，12/12 completed。single generation 20、lvm generation 22；10 个 RAID/RAID-LVM mode 为 generation 23-32。
- Rocky RAID1 generation 9 从本地盘启动并以 `root/asdf1234` 登录；`md126` 为双盘 RAID1 `/boot`，`md127` 为双盘 RAID1 `/`，ESP 位于主盘。
- Ubuntu RAID10-LVM generation 32 从本地盘启动并通过 SSH 密码登录；四盘 RAID1 `/boot` 与四盘 RAID10 PV 均为 `[UUUU]`，VG/LV 为 `nodeforge/root`，根文件系统为 ext4，唯一 1 GiB vfat ESP 挂载于 `/boot/efi`。
- 矩阵明细由 `tests/real-pxe-matrix.sh` 生成；本轮证据文件为 `/tmp/nodeforge-v0.1-rocky-remaining.jsonl`、`/tmp/nodeforge-v0.1-ubuntu-single-fixed.jsonl`、`/tmp/nodeforge-v0.1-ubuntu-lvm-fixed.jsonl` 和 `/tmp/nodeforge-v0.1-ubuntu-raids.jsonl`。

## 实机缺陷闭环

- Ubuntu single 首次失败为 `autoinstall config did not create needed bootloader partition`。Curtin automatic/custom ESP action 已增加唯一 `grub_device: true`，回归测试断言单主 ESP、单 boot flag 和单 grub device；generation 20 实机通过。
- Ubuntu lvm 首次失败为 `LVM_VolGroup.__init__() missing 1 required keyword-only argument: 'devices'`。automatic graph 的 VG 引用由不存在的 `nodeforge-pv-part` 修正为已创建的 `nodeforge-pv-part-0`，并增加 ID/引用一致性断言；generation 22 实机通过。
- Rocky RAID1 的历史 metadata 停滞在稳定 SATA 硬件布局上未复现；generation 9 完成，随后全部 Rocky RAID/RAID-LVM mode 连续完成。

## 生命周期回归

- generation 33 将 Ubuntu 从已应用的 RAID10-LVM 改为 single：retry armed 时 `drift_state=drifted`，安装完成后 applied/desired digest 相等且 `drift_state=clean`。
- generation 34 在 `install_packages` 阶段重启 `nodeforged`。重启前后 session `57708f87c6d54270db3a8ffefe66b29d` 与 generation 34 保持一致，后续 installer 回调继续被接受，最终 `terminal_generation=successful_generation=34`、phase completed、drift clean。
- 未 armed 的已知节点不会再次获得安装 bootfile，UEFI 网络启动回落到本地盘；未知客户端同样不会获得 bootfile。

## 完成结论

`docs/V0_1_DESIGN.md` 第 12 节完成标准已全部具备自动化或实机证据。生产节点最终状态为 generation 34 completed、not-armed、drift clean；生产服务和全部状态探针正常。
