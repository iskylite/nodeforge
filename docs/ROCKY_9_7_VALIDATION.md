# Rocky Linux 9.7 后续阶段验证清单

M0 已在 Rocky Linux 9.7 aarch64 实机完成 systemd、HTTP、CLI、端口独占和 debug 验证；结果以
[`DETAILED_DESIGN.md` 第 5 节](DETAILED_DESIGN.md#5-m0-验收标准与验证结果)为准。本文只跟踪
M1+ 尚未实现、因此尚未在目标机执行的系统级验证。功能实现和纯逻辑测试仍在本地完成；下列项目
不能在实际验证前标记为通过。

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

M0 默认 HTTP/管理共用端口为 `8080`。管理 API 没有独立端口；CLI 固定通过
`127.0.0.1:8080` 访问且不支持远程 endpoint，因此只能管理同机 `nodeforged`。服务端 listener
绑定 `0.0.0.0:8080`，管理路由接受所有可达连接且不做 peer 来源检查；从宿主机访问应返回
200。M0 尚无管理鉴权和 TLS，验证环境必须使用受信任网络。

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

## M3 实施中

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
