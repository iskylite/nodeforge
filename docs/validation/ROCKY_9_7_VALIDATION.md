# Rocky Linux 9.7 分阶段验证记录与待办

> **历史实测记录说明（2026-07-15）**：本文保留各日期当时实际执行的命令和结果，不是 M4.3 后的现行接口契约。
> 其中“重复 ISO 导入被拒绝是正确行为”已被 SHA-256 + logical name 幂等语义覆盖；`tftp/`、`repos/`、
> `provisioned/` 等旧顶层路径已由 M4.2 迁移到 `assets/*`、`state/provisioned/`；旧 `tftp`、`dhcp`、`trace`、
> `install-source` CLI 仅用于还原历史验证步骤，M4.3 后应使用 canonical 资源命令。判断当前设计和新验收时以
> 模型/CLI 以 `docs/archive/M0_M7_LEGACY_DETAILED_DESIGN.md` §9.12 与 M4.3 专项设计为历史基线，M4.9 覆盖内容以 §9.18 与
> M4.9 专项补丁为准；HTTP URL 以 §9.13 与 M4.4 专项设计为准；
> 不能据本文旧成功条件恢复过渡行为。

M0 已在 Rocky Linux 9.7 aarch64 实机完成 systemd、HTTP、CLI、端口独占和 debug 验证；结果以
[`M0_M7_LEGACY_DETAILED_DESIGN.md` 第 5 节](../archive/M0_M7_LEGACY_DETAILED_DESIGN.md#5-m0-验收标准与验证结果)为准。本文是追加式验证
日志：已勾选项表示对应日期和环境下曾实际通过，不代表后续阶段自动通过；未勾选项是当前待办。
M4/M4.1 的 Rocky 9.7 与 Ubuntu 22.04 正向安装、登录和生命周期链路均已完成实机验证；尚未执行的
异常/负向条目继续保持未勾选。Rocky 8.10 aarch64 因 VMware/Apple-Silicon 的 64 KiB page-granule
不兼容单独暂缓，详见 `ROCKY_8_10_VALIDATION.md`；M5+ 尚未实现。任何新能力仍必须在实际目标机验证后
才可勾选，不能把设计、renderer fixture 或较早阶段成功当成系统级通过。

## M4.9（2026-07-18）：r97n0 全量重建与 r97n1 VMware 回归

本轮按用户授权删除 r97n1 快照/数据，不保留旧节点状态；r97n0 上清空 NodeForge 二进制、配置、catalog、state
及其他受管数据后，用当前分支重新 aarch64 交叉编译并通过 `setup` 初始化、导入 Rocky 9.7 ISO、添加 r97n1，
随后从 VMware UEFI PXE 启动。最终完成安装、重启并从虚拟磁盘正常进入 Rocky 9.7。

故障链与修复：

| 现象/证据 | 根因 | 修复与验证 |
| --- | --- | --- |
| r97n0 明确记录 `PXE withheld ... install_not_armed`；`armed_generation=1`，但 requested/desired revision 不同 | deployment arm 使用 config+catalog 联合指纹，DHCP 却曾读取 ConfigRuntime 的 config-only 指纹 | DHCP 在 ModelRuntime gate 下重算联合 desired；失败使用 0 sentinel 关闭。回归断言 config-only 与联合指纹不同且 DHCP 使用后者 |
| HTTP 路径在联合 revision 计算失败时回退 config-only | arm、immutable plan、drift/status 投影可能与 DHCP 使用不同 revision | HTTP 改为返回 `503 model.revision_unavailable`，每个请求只计算一次并复用，不再回退 |
| fresh setup + ISO import 后缺少 `efi/grubaa64.efi` catalog/文件 | importer 只发布 ISO/kernel/initrd/repository，隐含依赖旧环境残留 bootloader | ISO import 从媒体提取架构对应 UEFI GRUB，发布 canonical bootloader asset；同架构重复导入安全复用 |
| `setup` 执行 systemd enable/start 后偶发立即判 health 失败 | `Type=simple` 的 `systemctl start` 早于 HTTP listener ready 返回 | setup 使用 5 秒有界 readiness retry；真实错误仍回滚 |
| 独立清理 boot-session 或 deployment-control 后可能恢复不一致 capability/generation | 两个文件各自原子但没有跨文件事务，旧 loader 未校验 join | 启动先加载 deployment-control，再按 node/generation/model revision 校验 install session；不一致拒绝启动 |

最近提交关联分析：最近两个 HEAD 提交中，`c86b324` 保留了 DHCP 读取 config-only revision 的既有实现；
`3ca9259` 已尝试接入 ModelRuntime，但计算失败仍错误回退到启动 revision，因此只修了一半。更早的
`6d282d2` 首次引入该 config-only 读取，`46d935f` 的 M4.7 config/catalog 拆分使两类 revision 的差异成为
稳定现象；`0ed4395` 的 ISO/catalog 收口则暴露了 fresh environment 对 bootloader 自举的依赖。因此最近
两次提交与复现直接相关，但不是单一提交造成全部故障。修复原则是统一事实源与失败关闭，不撤销 M4.7 拆分。

本轮本地门槛：`zig build test` 通过；`make arm64` 通过。实机门槛：r97n0 fresh setup/import/node add
通过，r97n1 获得 PXE lease/bootfile，拉取 GRUB/kernel/initrd，完成 Anaconda 安装，重启后本地盘启动成功。

本轮当时只属于 M4.9a 范围，不能作为 M4.9b 证据。M4.9b 后续已实现并在
[`UBUNTU_22_04_M4_9_M4_10_VALIDATION.md`](UBUNTU_22_04_M4_9_M4_10_VALIDATION.md)
完成 schema 迁移、完整 digest 和 Ubuntu PXE 独立验收；本段保留的是 2026-07-18 的历史边界。

## M4.10（2026-07-19）：fresh CLI 闭环

r97n0 使用当前 ARM64 ReleaseSafe 二进制再次执行无历史 fresh reset，全程未编辑 JSON：

```bash
printf 'yes\n' | nodeforge setup --reset-all --purge-all --reconfigure \
  --server-ip 192.168.27.128 --bind-interface enp26s0 \
  --subnet 192.168.27.0/24 --pool-start 192.168.27.200 --pool-end 192.168.27.254
systemctl daemon-reload
systemctl restart nodeforged
nodeforge assets import /root/nodeforge-stage/media/Rocky-9.7-aarch64-minimal.iso
nodeforge node add r97n1 mac=00:50:56:2A:23:DB arch=aarch64 \
  profile=rocky-9.7-aarch64-iso ip=192.168.27.210
```

后续清理审计发现，当时的 `--purge-all` 没有覆盖 `work/`，因此 reset 前的 ISO 暂存/解包目录仍可能保留；
这不影响下述 CLI 闭环结果，但不满足“无历史”磁盘语义。实现现已把受管 `work/` 纳入 purge 范围：
清除 `work/import/` 和 `work/iso-import-*`（包括只读树），再重建空的 canonical `work/import/`；本地
setup 回归覆盖拒绝确认时保留与确认后清除。此条是对原实机记录的勘误，不把后续代码修复表述为已在
r97n0 重新执行。

结果：

- 组合操作只给出一次完整范围的交互确认；输出 reset 和 reconfigure 两个阶段，backup、日志文件和
  migration backup 均无残留。
- reconfigure 重新发布 canonical unit；命令完成后 `nodeforged` 仍为 inactive，证明服务生命周期只由
  随后的显式 systemctl 控制。
- ISO import 返回 `install_source=rocky-9.7-aarch64-iso`，并在同一 catalog revision 自动创建同名默认 profile。
- node add 后无需重启/retry，立即显示 `install_intent=initial-armed`、`pxe_ready=true`、
  `armed_generation=1`，requested/desired revision 相等。
- `profile create rocky-9.7-alt rocky-9.7-aarch64-iso` 可补充第二个 profile。
- 当时 M4.9a 的全局 digest 会因补充无关 profile 使既有 arm 进入 `rearm-required`；该历史扰动已由
  M4.9b node-scoped digest 消除，新验证中无关 Ubuntu source/profile 导入没有改变 r97n1 desired plan。
- missing source、missing profile 分别返回 `profile.install_source_not_found`、
  `node.profile_not_found` 和 request id。
- `setup --reconfigure --install` 返回退出码 2，并说明 reconfigure 已发布 unit、`--install`
  只属于 standalone `--generate-systemd` 操作。

### M4.10 VMware 安装复验

> 以下 `profile set ... boot_disk` 是 M4.10 历史验证命令。v0.1 目标接口改为
> `node set <id> storage.boot_disk=/dev/...`，不再由 Profile 持有物理磁盘。

通过 Computer Use 启动 r97n1 后，第一轮 PXE 已完成 DHCP、GRUB、kernel/initrd 和 kickstart 获取，但
Anaconda 报 `Disk "sda" given in clearpart command does not exist`。根因是 ISO 自动 profile 无法从介质
tuple 推导目标机磁盘，默认 `/dev/sda` 与 VMware NVMe `/dev/nvme0n1` 不匹配。

补齐 CLI 后未编辑 JSON，执行：

```bash
nodeforge profile set rocky-9.7-aarch64-iso boot_disk=/dev/nvme0n1
nodeforge node retry r97n1 --force   # 仅在已确认失败目标机停止后
```

重新启动后验证：

- kickstart 为 `clearpart --drives=nvme0n1`、`bootloader --boot-drive=nvme0n1`；
- DHCP ACK、节点专属 GRUB、13,232,984-byte kernel、139,507,444-byte initrd 均成功；
- Anaconda 完成 336 个软件包安装并上报 `install.completed`；
- generation 3 的 requested/applied/desired revision 全部为 `11613377721464308635`；
- `terminal_generation=3`、`successful_generation=3`、`drifted=false`、`pxe_ready=false`；
- PXE-first 固件随后只获得无 bootfile lease，最终从本地 NVMe 启动到 Rocky Linux 9.7 login。

## M4.3 系统级重新验收（待实现后执行）

M4.3 会改动 ISO/catalog 身份、adapter 分派、ConfigRuntime、BootSession 认证恢复和 CLI，因此下列项目是新的
完成门槛，不得由本文 M4/M4.1 的历史成功记录代替：

- [ ] 使用最终 M4.3 二进制重新导入并部署 Rocky Linux 9.7，完成 PXE 全安装、重启和登录验证。
- [ ] 使用最终 M4.3 二进制重新导入并部署 Ubuntu Server 22.04，完成 PXE 全安装、重启和登录验证。
- [ ] Ubuntu 安装已进入 active delivery 后重启 nodeforged；旧 capability/webhook 回调恢复、安装最终完成，
      `boot.session.resumed` 可审计，且 `armed_generation` 没有被自动重建。
- [ ] 验证 `catalog show`、migration dry-run/plan digest、node list/show、TFTP/HTTP node 归属和 canonical CLI；
      记录二进制 commit/build time、配置 revision、ISO SHA-256 和关键事件时间线。
- [ ] 验证 `profile list/show` 能显示当前 PXE profile、引用节点、adapter/package-manager capability、install source、
      repository/资产和 effective system，且 secret 只显示来源/存在性。

完成前，M4.3 状态保持“设计完成，待实现/待实机验收”。

## M4.4 URL 契约重新验收（待 M4.3 后执行）

- [ ] Rocky/Ubuntu 生成内容只引用 `/api/v1/nodes/:id/**` 与 `/artifacts/**` canonical URL；不依赖 redirect。
- [ ] `/boot/config`、`/answer`、旧静态和旧 management URL 在兼容窗口结束后返回 404；错误 method 返回 405。
- [ ] boot/install-config 响应为 no-store，日志不包含 token/header/body；rootfs token 不能跨 node 使用。
- [ ] M4.3 恢复的 legacy active session 在剩余 TTL 内可完成，新 session 只获得 canonical URL；窗口结束不 rearm。
- [ ] 使用最终 M4.4 二进制再次完成 Rocky 9.7、Ubuntu 22.04 全安装和 Ubuntu restart-resume。

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
  provisioned/
  run/
  work/
```

系统级位置只放软链接：

- `/etc/systemd/system/nodeforged.service -> /opt/nodeforge/systemd/nodeforged.service`
- `/usr/bin/nodeforge -> /opt/nodeforge/bin/nodeforge`
- `/usr/bin/nodeforged -> /opt/nodeforge/bin/nodeforged`

### 测试前清理

在目标机执行 `zig build test` 或手动集成测试之前，必须清理上一次运行残留的日志、事件和
状态文件，否则会导致断言误判：

```sh
# 停止正在运行的 daemon，释放端口
systemctl stop nodeforged 2>/dev/null || true

# 清理服务日志和事件审计文件
rm -f /opt/nodeforge/logs/nodeforged.log
rm -f /opt/nodeforge/logs/events.jsonl
rm -f /opt/nodeforge/logs/events.jsonl.*

# 清理运行态持久化文件（leases / node-status / legacy runtime.json）
rm -f /opt/nodeforge/state/leases.json
rm -f /opt/nodeforge/state/node-status.json
rm -f /opt/nodeforge/state/runtime.json
rm -f /opt/nodeforge/state/*.tmp

# 清理导入工作目录和 catalog 缓存（如果需要干净 catalog 回归）
rm -rf /opt/nodeforge/work/iso-import-*
rm -f /opt/nodeforge/catalog/catalog.json
```

以下问题已由测试前清理或测试脚本修正规避：

- **事件污染**：`tests/cli.sh` 中的 `events list` 空列表断言会因 `/opt/nodeforge/logs/events.jsonl`
  残留历史事件而失败。脚本已改为使用 `--events-path "$tmp/nonexistent.jsonl"` 隔离；但手动
  验证时仍需清理该文件。
- **日志匹配**：`tests/http.sh` 中 `grep` 匹配 daemon 日志时，旧日志会与本次日志混合。
  测试脚本使用独立临时目录（`$tmp`），不受影响；但手动验证应确保只读当前进程的日志。
- **端口冲突**：`zig build test` 的 `http_tests` 与 `cli_tests` 如并行启动两个 daemon 实例，
  会因 HTTP 端口冲突而失败。`build.zig` 已强制两者串行执行（`http_tests.step.dependOn(&cli_tests.step)`）。
- **网口适配**：`tests/http.sh` 默认使用 `config.example.json` 中的 `enp1s0` 网口，`r97n0`
  上不存在该接口。脚本已将 `bind_interface` 动态替换为 `lo` 以适配本机回环测试。

M0 默认 HTTP/管理共用端口为 `18080`（可在配置文件 `server.http_port` 中覆盖）。管理 API 没有独立端口；CLI 固定通过
`127.0.0.1:18080` 访问且不支持远程 endpoint，因此只能管理同机 `nodeforged`。服务端 listener
绑定 `0.0.0.0:18080`，M3.6 起管理路由仅接受本机 `127.0.0.1` direct peer；从宿主机访问应返回
403。M0 尚无管理鉴权和 TLS，验证环境必须使用受信任网络。

## M1 TFTP 待验证

- [x] `nodeforged --check` 能识别 UDP 69 已占用、地址不存在和权限不足。
- [x] 使用系统 `tftp` 下载 `grubaa64.efi`。
- [x] 使用系统 `tftp` 下载 `grubx64.efi`。
- [x] 下载超过一个 block 的 kernel，SHA256 与源文件一致。
- [x] 验证 `blksize`、`timeout`、`tsize` 的 OACK 行为。
- [x] 丢弃 ACK，确认按配置重传并最终超时。
- [x] 请求 `../`、绝对路径、未登记资产和符号链接逃逸路径，确认全部拒绝。
- [x] 发起 WRQ，确认返回 access violation 且磁盘没有新增文件。
- [x] 并发下载压测：20 个下载、最大 10 个并发均完成且内容一致；M1 dispatcher 仍按串行传输实现，不承诺更高并发度。
- [x] GRUB 可拉取虚拟 `grub.cfg` 配置。  <!-- M3.5: 2026-07-12 实机验证通过 -->
- [x] GRUB 可拉取 kernel、initrd 并进入安装器/无盘启动。  <!-- M3.5: 2026-07-12 实机验证通过 -->

## 验证记录

执行时记录日期、架构、内核、Zig 构建版本、命令、结果和失败日志。只有上述项目
在目标虚拟机实际执行后，才更新对应阶段的系统级验收状态。

### 2026-07-11：M1 数据面（进行中）

- 目标：`root@r97n0`（Rocky Linux 9.7 aarch64）；构建：Zig 0.16.0，
  `aarch64-linux-gnu ReleaseSafe`。
- 已部署 M1 `nodeforged`，systemd 处于 `active`，`ss -lunp` 确认其独占
  `0.0.0.0:69`；unit 仅授予 `CAP_NET_BIND_SERVICE`。
- 在 `/opt/nodeforge/tftp` 导入受 SHA-256 保护的 `grubaa64.efi`、
  `grubx64.efi` 和 5,400-byte 测试 kernel。独立 UDP 验证客户端成功下载
  三者，下载文件 SHA-256 与源文件完全一致。
- 同一客户端确认 `blksize=1024`、`timeout=1`、`tsize=0` 的 OACK；对 block 1
  连续不回 ACK，收到初始包加三次重传，随后运行态 `failed` 计数递增。
- `../etc/passwd`、绝对路径和未登记文件均返回 TFTP `file not found`；WRQ 返回
  `access violation`，且没有产生 `write-test` 文件。`nodeforge tftp session list`
  显示 `started/completed/failed` 计数。
- 初次安装客户端时仓库获取未完成；随后以短超时/有限重试重试 DNF 并成功安装。最终
  标准客户端结果以下一节的完成记录为准。

### 2026-07-11：M1 系统级验收完成

- 已通过带 `timeout=10,retries=1` 的 DNF 安装 `tftp-5.2-40.el9.aarch64`，随后以
  `tftp -m octet 192.168.26.128 -c get ...` 下载 `grubaa64.efi`、`grubx64.efi` 和
  5,400-byte kernel；三对 SHA-256 全部一致。
- UDP 验证客户端确认 OACK 三个 option；不回 ACK 时收到初始 DATA 加三次重传，最终
  `failed` 计数增加。标准客户端只负责互操作下载，不依赖其实现支持 option 协商。
- 用受管 catalog 项指向 `/etc/passwd` 符号链接的负向夹具，确认响应
  `ERROR code=2 (access violation)`；夹具随后删除并恢复 catalog。
- `nodeforged -d --check` 对保留 UDP/69 显示 `TftpAddressUnavailable`，对不存在的
  `192.0.2.123` 显示 `TftpAdvertiseAddressUnavailable`，以 `nobody` 运行显示端口
  权限导致的 `TftpAddressUnavailable`。服务最终恢复为 active，监听
  `0.0.0.0:69`，并以 `192.168.26.128` 作为已验证的 PXE 广告地址。
- 最近一次并发验证结果为 `started=20, completed=20, failed=0`；会话 CLI 显示
  ID、状态和文件名。资产导入也已通过 daemon 管理 API 在目标机计算 SHA-256、原子写入
  catalog 并立即发布 TFTP 白名单。

## M1.5 CLI 输出验证

### 2026-07-11：完成

- 构建：Zig 0.16.0，`aarch64-linux-gnu ReleaseSafe`；最新 `nodeforge` 和
  `nodeforged` 已部署，systemd 为 `active`。
- `nodeforge asset list` 输出带 `NAME`、`KIND`、`PATH` 的自动宽度对齐表格；六个长度不同的
  asset 名称未再使用 tab 作为布局。
- `asset show` 输出 `Asset` 分组键值块；`tftp show` 输出统一的计数块；完成一次标准 TFTP
  下载后，`tftp session list` 输出 `ID`、`PHASE`、`FILENAME` 对齐表格。
- `asset list --output json` 已由 `jq` 解析并确认至少四个资产；human 表格没有改变 JSON 结构。
- 重定向 human 输出与 `--no-color` 输出逐字节一致，且使用 `LC_ALL=C grep` 确认没有 ANSI
  escape 字节。
- M1.5 后续回归确认所有 human 业务命令遵循同一 formatter：`asset list` 与 TFTP 会话表在表头
  后输出列宽匹配的 `-` 分隔线；config/catalog/asset 校验和 import 输出统一 `OK` 摘要与键值块；
  `check` 成功仍保留单行稳定摘要。JSON、export、help、错误和 debug 输出保持各自契约。

### 2026-07-11：M1 + M1.5 重新编译回归验证

- 目标：`root@r97n0`（Rocky Linux 9.7 aarch64，内核 `5.14.0-611.5.1.el9_7.aarch64`）；
  构建：Zig 0.16.0，`aarch64-linux-gnu ReleaseSafe`（本地交叉编译后 `scp` 部署）。
- 部署后 `systemctl start nodeforged` 返回 `active`，`ss -lunp` 确认 `nodeforged` 独占
  `0.0.0.0:69`；`nodeforge --version` 与 `nodeforged --version` 均输出 `0.1.0`。

#### M1 回归

- **`--check` 预检**：daemon 运行时 `nodeforged --check --debug` 因 HTTP 端口被自身占用
  报 `HttpAddressUnavailable`（预期行为）；手动以 Python 占用 UDP 69 后独立进程执行
  `--check` 报 `TftpAddressUnavailable`（exit 1）；以 `nobody` 用户运行报
  `TftpAddressUnavailable`（权限不足）；用 `server_ip=192.0.2.123` 配置报
  `TftpAdvertiseAddressUnavailable`。四种场景全部正确识别。
- **TFTP 下载**：`tftp -m octet 192.168.26.128 -c get` 下载 `grubaa64.efi`、
  `grubx64.efi` 和 `boot/vmlinuz-test`，三对 SHA-256 与源文件完全一致：
  - `grubaa64.efi`: `cd96fa95b930cafc33dcd48b6af204141614c7d571525667c332cce26193c2ed`
  - `grubx64.efi`: `57cb26b1ce42a21e3d1d254e9f8c744322c58c1c4f28be1c741c4d407636d37d`
  - `vmlinuz-test`: `cc3cce58e624edca805bf4ce719b6b5344d0ac288bb5e53c8c3bf0b363ec3fb5`
- **OACK**：独立 Python UDP 客户端发送 `blksize=1024,timeout=1,tsize=0`，服务器返回
  OACK `{'blksize':'1024','timeout':'1','tsize':'27'}`；使用 `blksize=512` 完整下载
  27 字节文件，SHA-256 与源一致。
- **重传**：对 block 1 不回 ACK，收到初始 DATA + 3 次重传（共 4 个相同 block=1 包），
  随后会话标记 `failed`。
- **路径安全**：`../etc/passwd` → `ERROR code=1 file not found`；`/etc/passwd`
  （绝对路径）→ `ERROR code=1`；`nonexistent/file.bin` → `ERROR code=1`。
- **WRQ**：返回 `ERROR code=2 write requests are disabled`，`/opt/nodeforge/tftp/`
  下无 `write-test` 文件产生。
- **并发压测**：20 个线程同时发起 RRQ 下载 `grubaa64.efi`，全部成功且 SHA-256 一致；
  会话计数器 `started=30, completed=26, failed=4`（4 个 failed 对应路径穿越、绝对路径、
  不存在文件和重传超时），会话列表正确显示 ID、PHASE 和 FILENAME。

#### M1.5 回归

- `asset list`（human）输出 `NAME / KIND / PATH` 三列自动宽度对齐表格，表头后跟 `-`
  分隔线，无 tab 布局；`asset list --output json` 输出可被 `json.tool` 解析的 4 资产 JSON。
- `asset show grub-uefi-aarch64`（human）输出 `Asset` 分组键值块（Name/Kind/Path/SHA-256）；
  `--output json` 输出单资产 JSON（含 sha256 字段）。
- `tftp show`（human）输出 `TFTP` 计数块；`--output json` 输出 `{"started":30,"completed":26,"failed":4}`。
- `tftp session list`（human）输出 `ID / PHASE / FILENAME` 对齐表格；`--output json` 输出
  `{"ok":true,"result":{"sessions":[...]}}` 结构。
- `nodeforge status` 输出 `NodeForge status` 键值块（Process/HTTP/Management/Config API）；
  `nodeforge check` 输出单行 `OK nodeforge checks passed`（exit 0）。
- `config validate`、`catalog validate`、`asset validate` 均输出 `OK` 摘要 + 键值块。

## M2 DHCP 验证

## M2.5 结构化日志与事件验证

### 2026-07-11：Event v2 与本机查询

- 目标为 `root@r97n0`（Rocky Linux 9.7 aarch64）；使用 `192.168.27.128/24` 的安全 discovery
  fixture 启动 M2.5 二进制，`nodeforged --check-config` 与空闲端口 `nodeforged --check` 均通过。
- daemon 正常监听 DHCP `0.0.0.0%enp26s0:67`、TFTP `192.168.27.128:69` 和 HTTP `:18080`；服务日志
  使用 RFC 3339 UTC 时间、等级和 `nodeforge` scope，例如 `2026-07-11T12:55:12Z info [nodeforge]`。
- 启动产生 `config.loaded`、`service.started` Event v2；`GET /api/v1/management/config/status` 产生
  `http.request` v2，含 `method`、净化后的 `path`、`status` 与 `bytes_sent`。
- `nodeforge events types --output json`、`events list --type service.started --output json` 和
  `events list --type http.request --output json` 都由 `python3 -m json.tool` 验证为合法 JSON；读取器同时
  扫描并保留历史 v1 `unix:<seconds>` DHCP 记录。
- 通过绑定 `enp26s0` 的独立 DHCP UDP client 完成未知安全 discovery 的
  `DISCOVER -> OFFER -> REQUEST -> ACK`，获得 `192.168.27.200`。`dhcp.ack` 为 Event v2，字段包含
  `mac=02:aa:bb:cc:dd:ee`、`ip=192.168.27.200`、`xid=0x6ecc6b78`、`kind=ack` 和 `arch=aarch64`。

### 2026-07-11：DHCPv4 原型基线

- 已完成的仅是构建与本机 UDP `DISCOVER/OFFER` 基线；这不能证明 DHCP 生命周期、租约持久化、
  relay、冲突检测或 PXE/TFTP 闭环。
- vmnet2 PXE 客户端没有完成 `REQUEST/ACK`，且当时服务广告网段与实际 vmnet2 网段不一致；该结果
  明确标记为失败证据，不得用于 M2 阶段验收。
- 后续验收必须仅使用 `192.168.27.0/24`：r97n0 的 `enp26s0` 静态地址、NodeForge DHCP、独立
  客户端的 `dhclient` 和 PXE/TFTP 抓包均在该网段完成；不得绑定或影响 `192.168.26.0/24`。
- `--no-color` 与管道重定向输出逐字节一致；`LC_ALL=C grep -c $'\033'` 返回 `0`，确认
  human 输出无 ANSI escape 字节。

### 2026-07-11：27 网段 DHCP 数据面完成

- 验证机：`root@r97n0`，Rocky Linux 9.7 aarch64，Zig 0.16.0；PXE 网卡 `enp26s0` 仅使用
  `192.168.27.128/24`。DHCP 监听 `0.0.0.0%enp26s0:67`，以 `SO_BINDTODEVICE` 收取且只收取
  27 网段的广播；TFTP 监听 `192.168.27.128:69`，HTTP 为 `:18080`；`192.168.26.0/24` 未参与
  DHCP/TFTP 验证。
- systemd 单元为 DHCP 使用 `CAP_NET_BIND_SERVICE` 与 `CAP_NET_RAW`。后者是 Ping Probe 的必要条件：
  raw ICMP 不可用时 daemon 不发送未经冲突检查的 OFFER，并取消刚创建的 pending offer。
- 独立 UDP DHCP 客户端完成未知 MAC 的 `DISCOVER -> OFFER -> REQUEST -> ACK`，获得
  `192.168.27.100`；`nodeforge runtime leases list`、`runtime unknown list`、`dhcp show`、
  `node list` 和 DHCP 管理 API 都返回与运行态一致的结果。
- 为验证冲突分支，临时在同一 `enp26s0` 添加 `192.168.27.101/24` 后发起第二个 DISCOVER。
  Ping Probe 收到匹配 Echo Reply，将 `.101` 写为 `abandoned`，返回 `.102`；第二个 REQUEST 收到
  ACK。测试随后删除临时地址并发送 RELEASE，活动租约被释放，`.101` 按 120 秒配置隔离。
- `events.jsonl` 确认顺序事件 `dhcp.discover`、`dhcp.offer`、`dhcp.request`、`dhcp.ack`、
  `dhcp.abandoned` 和 `dhcp.release`。同机完整 `zig build test` 与 39 个 Zig 单元测试通过。
- relay Link Selection/`giaddr`、静态保留地址跳过、option 60/61/82/93/97 和 Probe 自回显行为由
  单元测试覆盖；前两者不在单一子网的实机拓扑中伪造 relay。

### 2026-07-11：独立 UEFI PXE/TFTP 闭环完成

- 使用 VMware Fusion 创建独立 `pxe27-uefi`（Rocky Linux 64-bit Arm、UEFI、单网卡 `vmnet2`），
  并在 Fusion 的 Startup Disk 选择 Network Adapter；服务节点仍为 `r97n0/enp26s0`
  `192.168.27.128/24`。两台 VM 与抓包均只在 `192.168.27.0/24`。
- 实机发现 DHCP 广播虽已到达 `enp26s0`，但原先只绑定 `192.168.27.128:67` 的 socket 不会收到
  `255.255.255.255:67`。修复为 Linux wildcard UDP/67 + `SO_BINDTODEVICE(enp26s0)` 后，`ss` 显示
  `0.0.0.0%enp26s0:67`，没有扩大到 26 网段。
- 为避免未知节点执行任何破坏性动作，PXE 夹具只配置 `discovery` profile；其 catalog 仅登记真实
  Rocky `grubaa64.efi`（SHA-256
  `109f17c8f7cd2fd92862945c9db59c6f2f83fd7674ac596225ce84903c98fd3f`）。
- `tcpdump` 记录 ARM UEFI `option 93 = 11`、`DHCPOFFER` 和 `DHCPACK` 均分配
  `192.168.27.200`，并在 option 67 中携带 `efi/grubaa64.efi`；随后固件从
  `192.168.27.200` 对 `192.168.27.128:69` 发起该文件的 TFTP RRQ。运行态显示对应 TFTP session
  `completed`，Fusion 控制台实际进入 `GRUB version 2.06` 提示符。
- GRUB 随后尝试查找其常规 `grub.cfg` 与模块清单；该最小 M2 夹具未发布这些 M3+/完整启动菜单资产，
  因而相关 RRQ 返回 `file not found`。这不影响本项对 DHCP bootfile、TFTP bootloader 下载和进入
  bootloader 的验收边界。

### 2026-07-12：M3.5 TFTP 虚拟 GRUB 配置补全（当时待实机验证）

- **问题发现**：M2 实机验证确认 GRUB 可下载 `grubaa64.efi` 并进入 bootloader 提示符，但 GRUB
  随后查找 `grub.cfg` 时返回 `file not found`。根因有三：
  1. `grub.zig` 渲染器从未被调用——TFTP handler 只检查 catalog manifest 白名单，虚拟配置请求被拒绝。
  2. `grub.zig` 硬编码 `linuxefi`/`initrdefi` 指令——ARM64 `grubaa64.efi` 不含这两个模块。
  3. TFTP handler 缺少身份解析——无法从 Peer IP 获取 node_id/profile/mode 来渲染个性化配置。
- **代码修复**（均已实现，`zig build test` 全量通过）：
  - `boot/grub.zig`：`linuxefi`/`initrdefi` → `linux`/`initrd`；`timeout` 保持 5。
  - `boot/target.zig`（新增）：从 `TftpBootIdentity` + `AppConfig` + `Catalog` 展开 `BootTarget`。
  - `state/boot_session.zig`：新增 `TftpBootIdentity` 和 `resolveTftpBoot`（只读值副本，锁内不 I/O）。
  - `tftp/server.zig`：新增 `isVirtualGrubConfig` + `transferVirtualConfig`；在 catalog manifest gate 前拦截。
- **验证结果**（2026-07-12 实机通过，详见下文 "M3.5 TFTP 虚拟 GRUB 配置实机验证通过"）：
  - [x] VMware PXE 客户端从 TFTP 获取虚拟 `grub.cfg`，内容包含正确的 kernel/initrd 路径和 cmdline。
  - [x] GRUB 按 `grub.cfg` 中的 `linux`/`initrd` 指令加载 kernel 和 initrd。
  - [x] install mode 进入安装器（M3 不含 Kickstart，kernel 成功启动并开始 HTTP 请求安装仓库）。
  - [ ] diskless mode 进入 NodeForge initrd（M3 不含 dracut module，后续阶段验证）。
  - [ ] discovery mode 返回 TFTP ERROR code 2（access violation），不渲染任何 kernel/initrd 条目（M3.6 修正错误语义，后续补充验证）。

### 2026-07-12：M3.5 TFTP 虚拟 GRUB 配置实机验证通过

- **环境**：`root@r97n0`（Rocky Linux 9.7 aarch64），`192.168.27.128/24`（`enp26s0`）；
  VMware Fusion `pxe27-uefi`（ARM64 UEFI，单网卡 `vmnet2`）。Zig 0.16.0，
  `aarch64-linux-gnu ReleaseSafe`。
- **配置**：已认领节点 `pxe-test-node`（MAC `00:0c:29:38:b9:1f`，静态 IP `192.168.27.210`），
  profile `rocky-install-aarch64`，install source `rocky-9.7-aarch64-iso`。
- **PXE 启动链路完整验证**（同一 `boot_session_id=73d20d94...`）：
  1. ✅ DHCP `DISCOVER → OFFER → ACK`：分配 `192.168.27.210`，option 67 = `efi/grubaa64.efi`。
  2. ✅ TFTP `efi/grubaa64.efi`：2,693,464 bytes 传输完成（首次 `UnexpectedAck` 后 GRUB 自动重试成功）。
  3. ✅ **虚拟 `efi/grub.cfg-01-00-0c-29-38-b9-1f`**：247 bytes 动态渲染并传输完成。
     GRUB 随后再次请求同一文件（GRUB 配置加载的常规行为），第二次同样成功。
  4. ✅ TFTP `/install/rocky-9.7-aarch64-iso/vmlinuz`：13,232,984 bytes 传输完成。
     **路径前导 `/` 修复**：GRUB 以绝对路径发起 RRQ，TFTP handler 现已剥离前导 `/` 后再做安全校验。
  5. ✅ TFTP `/install/rocky-9.7-aarch64-iso/initrd.img`：139,507,444 bytes 传输完成。
  6. ✅ 安装器内核启动：内核加载后发起第二轮 DHCP（新 session），随后通过 HTTP 请求安装仓库
     （`/repos/rocky-9.7-aarch64-iso/Minimal/LiveOS/squashfs.img` 等）。
- **已知限制**：minimal ISO 不含 `squashfs.img` / `.treeinfo` / `install.img`，安装器 HTTP
  请求返回 404。这是 ISO 内容限制，非 NodeForge 缺陷。使用 DVD ISO 可完成完整安装。
- **GRUB `.lst` 模块文件**：GRUB 查找 `command.lst`/`fs.lst`/`crypto.lst`/`terminal.lst` 等模块
  清单文件被 TFTP 拒绝（`FileNotAllowed`）。这些文件不在 catalog 中，属于预期行为，不影响启动链路。
- **TFTP 会话记录**：`nodeforge tftp session list` 显示 10 个会话——6 completed、4 failed（1 个首次
  `grubaa64.efi` 的 `UnexpectedAck` + 3 个 `.lst` 模块文件拒绝）。
- **代码修复**：本次验证中发现并修复了 TFTP handler 对 PXE 客户端绝对路径（前导 `/`）的误拒问题。
  修复方式：在 `transfer()` 入口处剥离前导 `/`，再做 `isSafeRelativePath` + `isManifestPath` 校验。

### M2 系统级验收

- [x] 使用独立 UEFI PXE 固件客户端在 `192.168.27.0/24` 从网络启动，确认它实际消费 DHCP
  bootfile、经 TFTP 下载对应 GRUB 文件并进入 bootloader；此前 vmnet2 的失败基线未计入本结果。

## M2.5.1 启动关联与 trace 验证

### 2026-07-11：完成

- 构建：本地 `zig build test`、`aarch64-linux-gnu ReleaseSafe` 均通过；ARM64 `nodeforge` 与
  `nodeforged` 部署到 `/opt/nodeforge/work/`，以 `m251-config.json` 的安全 discovery 夹具运行。
- 已认领的 `node-m251`（MAC `02:aa:bb:cc:dd:ee`）经真实 UDP DHCP 完成
  `DISCOVER -> OFFER -> REQUEST -> ACK`，同一 32 字符 `boot_session_id` 出现在全部 DHCP
  Event v2 中；事件同时包含自动注入的 `daemon_instance_id`、`node_id`、MAC 和 XID。
- 从获配地址 `192.168.27.200` 发起真实 TFTP RRQ，成功下载 2,693,464-byte
  `efi/grubaa64.efi`；SHA-256 与服务端资产一致，RRQ/完成事件与 DHCP 使用同一
  `boot_session_id`。`nodeforge events list --node node-m251 --session <id>` 与
  `nodeforge trace node-m251 --session <id>` 的 human/JSON 输出均已解析验证。
- 从非 lease-IP 发起的标准 TFTP 下载仍成功传输相同 SHA-256 文件，但 RRQ 与完成事件均固定为
  `session_link_state = no_active_lease_match`，不伪造 session 归属。
- SIGTERM 有序停止会在 `service.stopped` 之前写入每个活动 session 的
  `boot.session.terminated(reason=daemon_shutdown)`，随后确认 UDP/67、UDP/69 和 HTTP/18080
  全部释放；终态 trace 不产生 `daemon_restart_gap`。
- SIGKILL 中断一个未终止 session 后启动新实例，`nodeforge trace` 检出
  `daemon_restart_gap`；同秒时间戳的实例切换也由 CLI fixture 覆盖，避免 RFC3339 秒级精度掩盖重启。
- 最终 ARM64 二进制再次完成启动/健康检查/有序停止 smoke；`service.started` 与
  `service.stopped` 的 `daemon_instance_id` 一致，验证机最终没有残留 NodeForge listener。

### 2026-07-12：服务日志输出模式

- 本地 `zig build test`、`git diff --check` 与 `aarch64-linux-gnu ReleaseSafe` 构建通过；新 ARM64
  `nodeforged` 和 systemd unit 副本部署到 `/opt/nodeforge/work/`，`systemd-analyze verify` 通过。
- `--log-output file --log-file <work-path>` 下，`--check-config` 的成功记录只写入指定文件；缺失配置的
  `err [nodeforge] config: cannot load` 同样写入该文件，证明启动早期失败不依赖 journal 才可诊断。
- 以 `systemd-run --wait` 执行 `--log-output file`，成功记录写入
  `/opt/nodeforge/logs/nodeforged.log`，临时 unit 的 journal 不含重复的 `[nodeforge]` 服务日志。正式 unit
  已固定 `ExecStartPre=... --check --log-output file` 和 `ExecStart=... --log-output file`；验证后
  `nodeforged` 保持 inactive，未留下监听 socket。

## M3 验证记录

### 2026-07-12：M3.0–M3.3 ARM 构建与受控 HTTP 路由 smoke

- 本地 `zig build test` 通过。将当前工作树同步到 `root@r97n0:/root/NodeForge/` 后，
  `zig build -Doptimize=ReleaseSafe` 通过；该机为 Rocky Linux 9.7 aarch64、Zig 0.16.0。
- 使用现有隔离 PXE 夹具（`192.168.27.128:18080`、`enp26s0`）启动 daemon，确认 DHCP/67、
  TFTP/69 与唯一 HTTP listener 均成功绑定，`GET /healthz` 返回 `200`。
- 对没有活动 DHCP session 的 `GET /boot/config/no-such-node` 以及 capability-only
  `POST /api/v1/nodes/no-such-node/events`，均返回稳定的 `409 session_inactive`；证明 M3 路由
  没有因 URL 中携带 node id 而放行。
- 本批新增 BootConfig v1/capability DTO、peer-IP bootstrap proof、Bearer + session header proof、
  Event v2 受限 stage 映射、rootfs/image/repo catalog 路由以及 Range 委托给 facil.io 的静态传输。
- 后续 M3.4/M3.5 的 ISO 导入、`node_status` 落盘和并发基线见本节后续记录；本子批次本身不等同于 M3 完成。
- 待导入镜像已在开发机核验：
  `/Users/iskylite/Downloads/Rocky-9.7-aarch64-minimal.iso`，SHA-256
  `7a73b4dc3426053082d1a3fb28cc594f92133354b5ec16ccd5fd06875c35645f`（约 2.2 GiB）。

### 2026-07-12：M3.4 Rocky 9.7 aarch64 ISO loop-mount 导入

- 将上述 ISO 原样复制至 `r97n0:/opt/nodeforge/work/import/` 后再次计算 SHA-256，结果与开发机一致。
  `mount -t iso9660 -o ro,nosuid,nodev,noexec,loop` 成功；`.treeinfo` 报告 `family = Rocky Linux Minimal`、
  `version = 9.7`、`arch = aarch64`，并将 repository 定位为 `Minimal/repodata/repomd.xml`。
- 以 `nodeforge install-source import Rocky-9.7-aarch64-minimal.iso --distro rocky --version 9.7 --arch aarch64`
  请求 daemon 导入，返回成功。catalog 原子增加 ISO、installer kernel、installer initrd、DNF repository 与
  `rocky-9.7-aarch64-iso` install source；repository URL 为 `/repos/rocky-9.7-aarch64-iso/Minimal`。
- `Range: bytes=0-1023` 下载 `/images/rocky-9.7-aarch64-iso-image` 返回 1024 bytes、`206`、ETag 与
  `Accept-Ranges: bytes`；`/repos/.../Minimal/repodata/repomd.xml` 可读。导出的 kernel/initrd SHA-256 分别为
  `02feaa2a46d5c158b25813fe87cc3321a8a99d2268ab5a13bca20b3c49553bcf` 与
  `566de96aaa1240ceb384d63aa57cda1af5648fced3ce34db59e54a9342dc1565`，同 `.treeinfo` 一致。
- 重复导入被 daemon 拒绝，catalog SHA-256 未变；导入后确认不存在 `iso-import-*` work 目录或残留 loop mount。
  在 daemon 停止后，`nodeforged --check` 通过了端口、`mount`/`umount` 与 Linux import 前置检查。
- 后续将 mount/copy/hash 移入独立 import worker 后，以同一真实 ISO 重跑重复导入失败路径；worker 返回失败，
  catalog SHA-256 仍为 `359ff5433028931ab4a736baeecdf862dc33af593146da126fdfe4a2e46f1798`，且没有残留
  loop device、挂载点或 listener。
- 对已发布 ISO 的 `bytes=1048576-2097151` 发起 100 个请求、并发度 20；全部返回完整的 1 MiB
  响应，首尾文件 SHA-256 均为 `bd7cf734455c8e3117699e9f6268471cd287062413314406bf29f0221291ed68`。
  验证后 daemon 有序停止，UDP/67、UDP/69 与 HTTP/18080 均已释放。
- 对同一 ISO 复验受管强 ETag、单 Range、`If-Range` 与 416：匹配的 ETag 使
  `bytes=1024-2047` 返回 `206`；不匹配的 ETag 忽略 Range 并返回完整 `200`（`Content-Length`
  `2348744704`）；多段 `bytes=0-1,3-4` 返回 `416` 和
  `Content-Range: bytes */2348744704`。响应只包含由 SHA-256 派生的一个 ETag，不再混入
  facil.io 的文件时间/长度 ETag。

### 2026-07-12：M3.5 已认领节点、状态重启边界与并发基线

- 使用 `tests/fixtures/m3-r97n0-install.json` 中的已认领 aarch64 节点（MAC
  `02:aa:bb:cc:dd:ef`、静态地址 `192.168.27.200`）执行真实 UDP
  `DISCOVER -> OFFER -> REQUEST -> ACK`。OFFER 不写入 HTTP proof 所需的 lease-IP；只有 ACK 后从
  `192.168.27.200` 直接请求 `/boot/config/m3-r97n0-fixture` 才获得 BootConfig v1。
- BootConfig 确认 install source 为 `rocky-9.7-aarch64-iso`，包含一个本地 DNF repository URL 和 64 字符
  bearer capability。错误 bearer 返回 `403`，正确 `Authorization` + `X-NodeForge-Session` 返回 `200`；
  `/answer` fixture 中的 session/token 与 BootConfig 一致。
- 以 capability POST `installer_started` 成功写入 `install.installer_started` Event v2，并把管理状态推进到
  `installer_started`。重复获取 config 仍返回 `200`，但不会把该投影回退到 `boot_config_fetched`。
  SIGTERM 后重启 daemon，旧 capability 返回 `409 session_inactive`；持久化的 status 仍为
  `installer_started`，但 `session_active=false`。
- 运行时 lease/status 快照改为最多每秒一次的原子 checkpoint（有序停止强制最终写入），避免每个 DHCP
  报文 `fsync` 整份 JSON 而阻塞 UDP loop。定速发送 200 个 DHCPREQUEST（200 pps）后收到 200 个 DHCPACK；
  用时 1000.8 ms，审计流恰有 400 条对应 request/ack Event。
- 并发 20 发起 100 个标准 `tftp -m binary` 下载，全部取得 `efi/grubaa64.efi`，每个文件 SHA-256 均为
  `109f17c8f7cd2fd92862945c9db59c6f2f83fd7674ac596225ce84903c98fd3f`。

### 2026-07-12：M3.4 Ubuntu Server 22.04.5 aarch64 ISO

- Ubuntu ISO `/Users/iskylite/Downloads/ubuntu-22.04.5-live-server-arm64.iso` 的 SHA-256 为
  `eafec62cfe760c30cac43f446463e628fada468c2de2f14e0e2bc27295187505`；复制到 r97n0 staging 后再次计算结果一致。
  只读 loop mount 识别 `.disk/info` 的 `Ubuntu-Server 22.04.5 LTS`、arm64 架构，安装器入口为
  `casper/vmlinuz` 与 `casper/initrd`。
- 同一介质包含 `dists/jammy/Release`、`pool/` 和 arm64 APT metadata；导入后原子发布
  `ubuntu-22.04-aarch64-iso` install source、ISO、installer kernel/initrd 和 manager=`apt` repository。
  repository base URL 为 `http://192.168.27.128:18080/repos/ubuntu-22.04-aarch64-iso`，
  `dists/jammy/Release` 与 pool 中 `.deb` 均已确认在发布根内。
- 以已认领节点（MAC `02:aa:bb:cc:dd:f0`、静态 IP `192.168.27.201`）完成真实 DHCP
  `DISCOVER -> OFFER -> REQUEST -> ACK` 后，从该 peer 地址获取 BootConfig。其 profile 为
  `ubuntu-install-aarch64`，installer 指向上述 Ubuntu assets，且 `repository_urls` 仅含发布的 APT 根 URL。
  Ubuntu ISO 的 `Range: bytes=0-1023` 响应使用其 SHA-256 作为唯一 ETag；APT Release 可经 HTTP 读取。

### 2026-07-12：M3.1 运行态持久化拆分与全量集成测试回归

- 将 `runtime.json` 拆分为 `leases.json`（DHCP 租约，checkpoint worker 异步保存）和
  `node-status.json`（HTTP 节点状态，同步原子保存），两个文件各自持独立 I/O 锁、独立 schema
  校验和独立崩溃恢复路径。
- Legacy 迁移验证：以旧版 `runtime.json`（含活动租约和 `installer_started` 节点状态）启动新版
  daemon，确认活动租约正确迁移到 `leases.json`，过期租约被丢弃；节点状态迁移到
  `node-status.json` 且 `session_active` 重置为 `false`、`status` 保留为 `inactive`。
- 在 `r97n0` 上执行 `zig build test` 全量回归。修复以下兼容性问题后，59 个单元测试 +
  2 个集成测试（`cli_tests` + `http_tests`）全部通过：
  - **网口名**：`tests/http.sh` 中 `config.example.json` 的 `bind_interface: "enp1s0"` 在
    r97n0 上不存在（实际为 `enp26s0`），测试脚本已动态替换为 `lo` 以适配本机回环。
  - **日志匹配**：`tests/http.sh` 中 `grep` 匹配 daemon 调试日志时，原先按精确行匹配会因
    时间戳和 scope 前缀失败；改为 `grep -Fq 'http: request received GET /healthz'` 部分匹配。
  - **测试竞争**：`build.zig` 中 `http_tests` 和 `cli_tests` 并行启动两个 daemon 实例导致
    HTTP 端口冲突；已强制串行化（`http_tests.step.dependOn(&cli_tests.step)`）。
  - **事件污染**：`tests/cli.sh` 中 `events list` 空列表断言会因全局
    `/opt/nodeforge/logs/events.jsonl` 残留历史事件而失败；脚本已改用
    `--events-path "$tmp/nonexistent.jsonl"` 隔离。
- macOS 本地开发机同样通过 59 单元测试 + 2 集成测试（macOS 跳过需要 root/UDP 67 的
  `http_tests` DHCP 部分）。

### M3 系统级验收

- [x] 已认领节点能从活动 session 获取 BootConfig/answer；session、token、URL node 或 peer IP
  任一不匹配均不能读写。
- [x] 合法节点事件能按 Event v2 写入 `events.jsonl` 并更新持久 `node_status`，非法 body 或旧
  session 不会污染审计文件。
- [x] rootfs/ISO/repo 大文件下载支持 `Content-Length`、ETag、单 Range 和 `If-Range`，全程受
  catalog 路径沙箱限制。
- [x] ISO 导入后无需手工建基础 repo 即可通过 HTTP 安装；导入失败不会发布半个 catalog 或可访问
  的半成品。
- [x] 在 `r97n0` 完成真实 Rocky 9.7 aarch64 ISO 导入、Range/续传、节点 config/answer 和
  capability 上报验证，并记录 100 HTTP Range、100 TFTP、200 DHCP 报文/秒并发基线。
- [x] `runtime.json` 拆分为 `leases.json` + `node-status.json`，独立 I/O 锁、legacy 迁移和
  崩溃恢复通过验证；`zig build test` 全量回归通过。
- [x] M3.5 TFTP 虚拟 GRUB 配置：PXE 客户端从 TFTP 获取动态渲染的 `grub.cfg`，GRUB 按 `linux`/
  `initrd` 指令成功下载 kernel（13 MB）和 initrd（133 MB），内核启动后发起 HTTP 安装仓库请求。
  完整 DHCP→TFTP→kernel→initrd→installer 链路在 `192.168.27.0/24` 实机验证通过。

## M4/M4.1 已验证项与剩余边界、M5 待验证

2026-07-13，`r97n1` 已分别完成 Rocky 9.7 Kickstart 与 Ubuntu 22.04 autoinstall，均从目标盘启动，
以 bootstrap key 和 `nodeforge` 密码完成 SSH 登录，并产生
`installer_started → started → post → completed`；Ubuntu 还验证了重启后静态
`192.168.27.210/24`。下列未勾选项是尚未单独取得证据的负向、显式覆盖或跨发行版组合，不应被正向
安装结果自动推定为通过。后续验证继续记录 profile、node、ISO/repository、answer hash、目标地址、抓包
和安装后命令输出；失败也追加日期、症状和根因。

### 2026-07-17：M4.6 kernel_args 实现与 r97n0 验证

- 将当前工作树同步到 `root@r97n0:/root/NodeForge/`，使用 Zig 0.16.0 在 Rocky Linux 9.7
  aarch64 上执行 `zig build test --summary all`：192/192 单元测试通过，CLI、HTTP 和安装布局
  三组集成测试全部通过。
- 使用活动 catalog 的 Rocky 9.7 与 Ubuntu 22.04 profile 做 renderer 验证。输入
  `"  iommu=pt   hugepages=4  "` 经 config load/export canonicalize 为
  `"iommu=pt hugepages=4"`；Rocky answer 生成
  `bootloader --boot-drive=nvme0n1 --append="iommu=pt hugepages=4"`，并通过
  `ksvalidator --version RHEL9`。answer SHA-256 为
  `a24d667f9081ba02b2046535beb23bdf3121b6474a0943db69f7968101f3ba4f`。
- Ubuntu answer 将 `iommu=pt isolcpus=0,2` 写入
  `/target/etc/default/grub.d/99-nodeforge.cfg`，保留字面量 `${GRUB_CMDLINE_LINUX}`、设置 0644，
  下一条命令为 `curtin in-target --target=/target -- update-grub`；PyYAML 解析和逐字段断言通过。
  answer SHA-256 为 `0105062e3108575958a7334ecdcdaa3d9f1d310314bf4430ff9f1625ee4df71a`。
- 负向校验确认 `iommu=pt;reboot` 返回 `InvalidKernelArgs`，配置 kernel args 但关闭
  `install.bootloader.install` 返回 `KernelArgsRequiresBootloader`。测试期间仅暂时停止 nodeforged
  释放 67/69/18080；完成后服务恢复为 active/running，`NRestarts=0`，三端口监听和
  `nodeforge check` 均通过。
- 本轮没有触发 r97n1 擦盘重装，因此尚未把“安装后目标系统 `/proc/cmdline` 与 GRUB 普通/recovery
  entry 均含参数”勾为实机通过；该项保留到下一次受控 PXE 安装窗口。
- 随后将 M4.6 ReleaseSafe aarch64 二进制正式部署到 `/opt/nodeforge/bin`。部署检查发现新增的默认
  `kernel_args: null` 若直接参与 typed JSON hash，会让未修改的 config 在二进制升级后产生新 revision，
  从而使升级前 active session 的 `node show.status` 被 provenance 门控隐藏。`revisionForConfig` 已加入
  向后兼容 canonical hash：仅省略语义为空的 `kernel_args:null`，非空参数仍改变 revision。升级前后
  config revision 均为 `12655880631858739881`，generation 6 的 `install_started`、开始时间
  `2026-07-17 03:07:27` 和详细 status 在 daemon 重启后完整保留。
- 首次 M4.6 部署二进制 SHA-256：
  `nodeforge=6b110bdb32e7e858da1d8a3e285428486f2a9190864e94c7aa601b946cbb9867`、
  `nodeforged=dfa6845ee2c2767b539bc4c8c7f6adc5e2441e178a4277e2ae3dd505f47d48f7`；
  备份位于 `/opt/nodeforge/backups/20260717-031637`。部署后服务 active/running、`NRestarts=0`，
  DHCP/67、TFTP/69、HTTP/18080 和 `nodeforge check` 全部正常。
- 后续语义复审撤销了实验性的旧启动时间字段/schema 3 方案：整个任务的 `Start` 稳定对应
  `armed_at`，`Install` 对应 `install_at`/`install.started`，`Finished` 对应 terminal
  `finished_at`。列表固定显示 `ARMED / INSTALL / FINISHED`；这套边界可直接延伸到 diskless，后者只需
  增加与 Install 并列的实际启动阶段，而不重新解释 Armed。deployment-control 因此继续使用 schema 2。
- 同一复审补齐 `profile show/set/unset kernel_args`、完整结构化 `node show` 和本地回归。此前包含
  旧启动时间字段的二进制/状态验证只作为被否决方案的历史记录，不是当前发布候选；当前源码须在新的
  ReleaseSafe aarch64 构建和受控部署验证后再记录二进制 SHA、schema 与服务状态。

### 2026-07-13/14：`r97n1` Rocky 9.7 与 Ubuntu 22.04 自动部署复验

- **环境与配置**：PXE 服务为 `r97n0`（管理地址 `192.168.26.128`，PXE 地址
  `192.168.27.128`，接口 `enp26s0`）；目标 VMware ARM64 UEFI VM、节点 ID 与 hostname 均为
  `r97n1`，MAC `00:50:56:2A:23:DB`，`vmnet2` 静态地址 `192.168.27.210/24`。服务配置只保留该
  真实目标节点，DNS 为 `192.168.27.128`。现有 Rocky 9.7、Ubuntu 22.04.5 和 Rocky 8.10
  ISO/catalog 原样沿用并通过校验，没有重新导入或改写。
- **重新编译与部署**：本地 `zig fmt --check`、`make test` 和 `make arm64` 全部通过；最新 ARM64
  ReleaseSafe 二进制部署到 `r97n0` 后，SHA-256 为
  `nodeforge=8fa8a0daec30bc29bd0dd8a09ee01d26f5e71a90b0f2004c59d0d677b79c1d3b`、
  `nodeforged=aa569189a37f40456f908d004b3be9c18b9bb8c38865e175d3171d6a5b873f44`。备份位于
  `/opt/nodeforge/backups/20260714-001448`。重启后 systemd active/enabled，`NRestarts=0`，DHCP/67、
  TFTP/69、HTTP/18080 正常监听，`nodeforge check` 与 `nodeforge status` 均通过。
- **Rocky 9.7 成功结果**：generation 2、session
  `5809032f2d3c5c2e35cb92b13f92dc28` 完整产生
  `installer_started → started → post → completed`。目标盘启动后为 Rocky Linux 9.7、hostname
  `r97n1`、静态 `.210/24`、XFS root + EFI；sshd active/enabled、firewalld inactive/masked、
  SELinux disabled、curl 已安装。root 和 `nodeforge` 均可用 `asdf1234` 密码 SSH，bootstrap key
  登录也成功。
- **Ubuntu root 锁定修复**：generation 3 首次安装成功，但 Subiquity/curtin 最终仍把 root shadow
  字段写成 `*`，即使 user-data 已有 `disable_root: false`、`lock_passwd: false` 与 `$6$` hash。
  Ubuntu adapter 因此新增 late-command，在 `/target` 内显式执行 `usermod --password '$6$…' root`。
  修复后的第一次真实 `user-data` 请求还暴露 `sha512Crypt` 中 `16 + digest[0]` 按 `u8` 相加的整数
  溢出；core backtrace定位到该表达式，现已先扩展为 `usize` 并增加 255 边界回归测试。
- **Ubuntu 最终成功结果**：generation 4、session
  `ad18164a4f87f17f45b7d5f0c81d2772` 的 meta-data、user-data、vendor-data 均返回 200，daemon
  全程 `NRestarts=0`，随后完整产生 `installer_started → started → post → completed`。从目标盘启动后
  确认为 Ubuntu 22.04.5 LTS、hostname `r97n1`、`enp2s0=192.168.27.210/24`、ext4 root + EFI；
  cloud-init done，sshd active/enabled，UFW inactive/disabled，curl 与受管 hosts 文件均存在。
  `passwd -S` 显示 root 与 `nodeforge` 均为 `P`；两者均使用 `asdf1234` 完成禁用公钥后的纯密码 SSH，
  root bootstrap key 登录也成功，`nodeforge` 属于 sudo 组。
- **Ubuntu 重试复验**：generation 5、session `6d4d92a614b6b8c40d997aec30585264` 再次完成
  `installer_started → started → post → completed`，NoCloud 三个 answer 均返回 200，daemon
  `NRestarts=0`。切回 HDD 后再次确认 Ubuntu 22.04.5、hostname、静态 `.210/24`、EFI/ext4、
  cloud-init、SSH/UFW/curl 正常，root 与 `nodeforge` 的 `asdf1234` 纯密码登录均成功。
- **VMware 陷阱**：原 VM 的快照带有 poweroff 自动回滚行为，曾在安装完成后删除新写入磁盘；删除唯一
  快照并合并磁盘后持久化正常。PXE-first 固件在 install generation 未 armed 时不会自动回落 HDD，
  验证目标盘前需停 VM 并把 `bios.bootOrder` 从 `ethernet0` 改为 `HDD`；下一轮安装前再改回网络。
  本轮还观察到 `vmrun ... nogui` 在 TFTP 中异常退出，改用 GUI 启动路径后稳定完成，不属于 NodeForge
  服务故障。

### M4 安装主链路

- [x] Rocky Linux 9.7 aarch64 从 Kickstart 完成磁盘、ESP、bootloader、`install_post` 并从本地盘启动。
- [x] Ubuntu Server 22.04 LTS 从 autoinstall 完成磁盘、ESP、bootloader、`install_post` 并从本地盘启动。
- [ ] Ubuntu 默认 `apt.fallback=offline-install` 可在本地 mirror 不完整时使用 ISO squashfs 完成安装。
- [ ] 严格 HTTP APT profile 使用 `apt.fallback=abort`；Release/Packages/DEB 任一不可用时明确失败，不得以
  ISO 离线回退掩盖问题。HTTP 日志能看到 request received、响应完成状态、字节数和 client。

### M4.1 目标系统公共配置

- [ ] 默认 profile 在 Ubuntu/Rocky 均得到 `en_US.UTF-8`、`UTC`、`us`；显式 locale/timezone/keyboard
  覆盖在安装后生效。
- [x] 默认安装并启用 OpenSSH、启用 password authentication 和 root login；使用默认明文密码
  `asdf1234` 可直接 SSH 登录。
- [ ] 修改密码、root_login 或 password_authentication 后行为严格一致。
- [ ] config 中普通用户/root password 保持明文；Ubuntu/Rocky answer 中均为有效 SHA-512 crypt `$6$`，
  Kickstart 使用 `--iscrypted`。固定 salt 输出与 OpenSSL/libxcrypt 一致，同 session 重试 answer 不漂移。
- [ ] 未配置显式 server key 时按 `/root/.ssh/id_rsa.pub`、`id_ed25519.pub`、state generated Ed25519 顺序
  取得 bootstrap admin key；server key 与各账号自己的 profile keys 始终合并、按 blob 去重，daemon 重启后
  generated fingerprint 不变，任何 answer/BootConfig/rootfs/log/event 都不含 private key。
- [ ] Ubuntu `users=[]` 不产生残缺 identity；绑定的 22.04 installer 支持 user-data-only 时 root-only 可登录，
  否则部署前明确拒绝。多用户 password/sudo/key 不丢失不串号；22.04 answer 不误用 26.04 新增的
  `identity.groups`。空 packages 是 YAML list；完整 answer 通过随 install source 固定的 Subiquity schema。
- [x] Ubuntu 显式目标盘/分区实际生效；Rocky answer 包含 `rootpw --iscrypted`，且
  `bootloader.install=true` 时不出现 `bootloader --location=none`，安装后能从目标盘启动。
- [x] Ubuntu early/late 与 Rocky 对应 hook 均在 installer 上下文上报合法
  `installer_started → started → post → completed`，目标系统 bundle 使用 in-target，服务端不返回 stage 409。
- [ ] Ubuntu error 与 Rocky `%onerror` 在真实失败路径上报合法 failed stage。
- [x] Ubuntu UFW inactive/disabled；Rocky firewalld disabled/masked，`sestatus` 显示 disabled。
- [ ] `local-only` answer 不含公共 mirror、GeoIP、NTP、installer refresh、update/upgrade、mirrorlist、
  metalink 或 CDN；PXE VLAN 抓包无公网请求。
- [ ] 额外包只能从安装介质或 NodeForge 本地 HTTP repository 获取；缺少 required package 时安装失败，
  不回退公网。
- [x] 静态目标网络要求 `address == node.ip`，安装过程中本地 HTTP/session
  不断链，重启后 Ubuntu Netplan 或 Rocky NetworkManager 仍使用该静态地址。
- [ ] `setup --import-config` / `config export` 对用户、root、IPMI 及所有其他 password 字段均保留原始明文；schema 不要求
  SecretRef 或预哈希值。日志、事件、BootConfig 和 status/plan 默认输出不泄露明文密码。

### M5 继承验收

- [ ] diskless rootfs build 继承 M4.1 locale/timezone、OpenSSH/root/password、防火墙和 Rocky SELinux 默认值。
- [ ] AgentPlan 声明 `sha512-crypt-v1`、`bootstrap-admin-key-v1`，只含 `$6$` hash 和合并后的 public keys；最小 BootConfig 不含账号/SSH 配置；
  不含 config 明文 password 或 NodeForge bootstrap private key。
- [ ] 额外包只在 rootfs build 阶段安装；initrd/diskless_boot 不运行 apt/dnf，不访问公网。
- [ ] DHCP/静态节点 overlay 遵循 M4.1 网络约束，BootConfig 只携带目标 hash，不携带明文 root 密码。
- [ ] RHEL 系 diskless kernel cmdline 含 `selinux=0`，切根后 firewalld disabled/masked、`sestatus` disabled。
