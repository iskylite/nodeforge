# NodeForge v0.4 全量 fresh 验证运行手册

状态：v0.4 发布前强制验证计划；待 v0.4 实现完成后执行。

目标环境：

- `r97n0`：NodeForge 管理节点；
- `r97n1`：计算节点、被部署节点及临时 PXE builder 节点；
- 两台机器位于受信任的本地 PXE 网络；
- `r97n1` 使用 UEFI + DHCPv4 PXE。

本文是 v0.4 的正式验证任务书，覆盖完整 v0.3 回归和全部 v0.4 新能力。产品行为以
[`V0_4_DESIGN.md`](../design/V0_4_DESIGN.md) 为准，操作命令以执行时的
[`README.md`](../../README.md)、[`cli/REFERENCE.md`](../cli/REFERENCE.md) 和 `--help-full` 为准。
本文定义验证范围、证据和 PASS/FAIL 闸，不反向修改产品设计。

任何必要项目没有获得真实证据，最终结论必须为 **FAIL**。不得以“代码看起来正确”“已有单元测试”或“设计中已经说明”
替代目标环境验证。

## 1. 权威来源和执行原则

执行前完整阅读并交叉核对：

1. [`README.md`](../../README.md)；
2. [`V0_4_DESIGN.md`](../design/V0_4_DESIGN.md)；
3. [`V0_3_DESIGN.md`](../design/V0_3_DESIGN.md)；
4. [`V0_3_VALIDATION.md`](V0_3_VALIDATION.md)；
5. [`cli/REFERENCE.md`](../cli/REFERENCE.md)；
6. 当前实现审计、v0.4 验证记录以及仓库 `tests/`、`build.zig` 中定义的正式测试入口；
7. `nodeforge --help`、各级 `--help-full` 和公开 JSON 输出。

v0.3 及以前设计是已落地冻结基线，只读。不得为了让 v0.4 测试通过而修改历史设计。

所有 Node、Profile、bundle、asset、topology、builder、discovery、deploy、retry、setup 和状态查询业务操作必须使用公开
`nodeforge` CLI。禁止：

- 直接修改 catalog、JSON state、operation journal、数据库或内部状态文件；
- 调用未公开 management transition 绕过 CLI；
- 手工生成、替换或伪造 BootSession、AgentPlan、token、generation 或 artifact manifest；
- 通过直接编辑目标机文件伪造 `managed_file|package|archive|script` 成功；
- 使用旧 config、catalog、artifact index、rootfs manifest、token hash 或 session；
- 把预留 enum、空 handler、日志文字或源码分支当作实现证据；
- 为通过测试而降低校验、关闭鉴权、跳过 network proof、忽略 warning/error 或篡改状态。

以下非业务操作可以使用 shell、systemd、SSH 和 VMware 控制：

- 编译、传输和检查二进制；
- 停止、部署和启动服务；
- 在确认主机和路径后清除 NodeForge 安装目录；
- 从目标系统读取事实、journal、日志、网络和文件状态；
- 控制 `r97n1` 电源、控制台和 UEFI/PXE 启动；
- 执行仓库正式定义的自动化、负向、容量和故障注入工具。

不得使用 `curl` 或自制脚本直接修改 management API 状态。协议、容量和故障注入只能使用仓库正式测试客户端；客户端也
必须通过公开协议创建业务对象，不能改内部文件。

## 2. 证据、重试和失败规则

开始前在 `/opt/nodeforge` 之外建立本轮唯一证据目录，保存：

- 每条关键命令、时间、退出码和脱敏输出；
- git commit、git status、Zig 版本和构建参数；
- `r97n0/r97n1` 的 hostname、machine-id 摘要、架构、OS、接口和永久 MAC；
- 四个二进制的 `file`、size、SHA-256 和版本；
- setup dry-run、fresh setup、deployment/schema 校验结果；
- CLI JSON、readiness、boot preview、session、operation、journal 和 events；
- daemon journal、目标机 systemd/network 状态；
- workload manifest、原始 latency/CPU/RSS/FD/disk 指标；
- 故障注入前后状态和必要的 VMware 控制台截图；
- 每个问题的复现、修复 diff/commit 和完整重测轮次。

禁止保存或输出 raw token、Authorization header、密码、private key 或完整 credential capsule。报告和证据必须脱敏。

执行过程中：

- 单步失败先保存证据并定位原因，不得静默跳过；
- CLI、实现、README 或 v0.4 落地不一致时必须修复；
- 修复后可先运行针对性测试，但最终必须重新编译四个程序、彻底清空 `r97n0`，并从 §4 完整重测；
- 前一轮 config/catalog/artifact/session/state 不能成为新一轮输入；
- 缺少必要硬件、第二 NIC、LACP/VLAN 网络、容量环境或 24 小时窗口时不得降级为 PASS。

只有最后一次完整 fresh 轮次可以支持最终 PASS。

## 3. 阶段 0：确认 v0.4 可进入验证

破坏性操作前确认：

1. 产品版本已进入 `0.4.x`；README 和当前实现审计不再把 v0.4 标为“实现未开始”；
2. `build.zig`、`build.zig.zon`、本机构建和部署后的 `--version` 一致；
3. AppConfig v5、catalog v6、BootConfig v3、AgentPlan v2 已实现；
4. 仓库有 v0.4 正式自动化、目标环境 E2E、容量 workload 和故障注入入口；
5. README 已给出公开 CLI 的 fresh setup、topology、builder、first-boot、discovery 和观测流程；
6. `r97n1` 具备 topology E2E 所需 NIC、交换机或 VMware 网络条件；
7. 容量环境满足或超过参考条件：8 CPU、16 GiB RAM、NVMe、1 GbE。

缺失正式命令或测试入口时不得臆造命令继续。先修复缺口，再从头验证。

## 4. 阶段 1：确认目标并彻底清理 r97n0

先执行只读确认：

```bash
ssh root@r97n0 '
  hostname -s
  uname -m
  cat /etc/os-release
  ip -br link
  ip -br address
  ip route
  systemctl show nodeforged -p FragmentPath -p ActiveState -p SubState
  systemctl cat nodeforged --no-pager || true
  pgrep -a -x nodeforged || true
  ss -lntup | grep -E ":(67|69|18080)([[:space:]]|$)" || true
'
```

必须确认：

- SSH 目标确实为 `r97n0`，`hostname -s` 精确匹配；
- PXE 绑定接口、IP、默认路由符合预期；
- systemd FragmentPath 是 NodeForge unit；
- 安装根精确为 README 定义的 `/opt/nodeforge`；
- 安装根不是符号链接、错误挂载点或宽泛路径；
- 原始 ISO 位于安装根之外；
- 67/69/HTTP 端口占用者已识别；
- `sshd`、`NetworkManager` 等基础服务状态已记录。

确认无误后停止、禁用并删除 NodeForge 的精确 unit、profile 脚本和安装根，执行 `daemon-reload`。验证：

- `/opt/nodeforge` 不存在；
- 没有 NodeForge 残留进程或端口；
- `sshd`、`NetworkManager` 和管理节点网络仍正常；
- 原始 ISO 和系统基础服务未受影响。

禁止使用未解析变量、通配根路径、`HOME`、`~`、`/` 或宽泛递归删除目标。任一主机/路径事实不符时停止并判定 FAIL。

## 5. 阶段 2：交叉编译和核验四个程序

记录：

```bash
zig version
git rev-parse HEAD
git status --short
ssh root@r97n0 'uname -m'
```

根据目标实际架构，按 README 使用 ReleaseSafe 交叉编译。aarch64 环境的标准入口为：

```bash
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe
```

必须生成并部署：

- `nodeforge`；
- `nodeforged`；
- `nodeforge-initrd`；
- `nodeforge-agent`。

逐项验证可执行、Linux ELF、目标架构、size、SHA-256 和安全版本查询。`nodeforge-initrd` 不得通过普通直接执行进行
版本检查，避免进入 PID 1/bootstrap；应由 ELF、构建 manifest、initrd 注入和真实启动共同验证。

将四个程序复制到 `r97n0` 的全新临时发布目录，比对传输前后摘要。不得混入旧 `zig-out`、旧发布目录或不同 commit 产物。

## 6. 阶段 3：fresh v0.4 初始化和 layout

部署二进制后再次执行 §4 的精确清场，然后：

1. 阅读 `nodeforge setup --help-full`；
2. 对 fresh replacement 执行 `--dry-run`，检查删除、保留、创建路径和 deployment id 行为；
3. 仅使用发布目录中的 `nodeforge setup` 和 README 参数初始化；
4. 初次初始化禁止 `--import-config`，禁止复制任何旧 config/catalog/state/artifact；
5. DHCP pool 从真实 subnet 计算，避开管理节点、网关、`r97n1` reservation 和其他在用地址；
6. pool 容量必须满足 AppConfig v5 的 BootSession/discovery 约束，不照抄不适用于 v0.4 的旧小地址池；
7. 生成和安装 systemd unit，再显式启动 daemon；
8. 轮询 management API 到真正 ready，不能只检查 systemd active。

验证 fresh layout：

- `.nodeforge-root` 是 v2 marker；
- DeploymentManifest schema v1 存在，`product_major_minor="0.4"`；
- AppConfig schema 5、catalog schema 6；
- marker、manifest、AppConfig、catalog 的 deployment id 一致；
- master secret 权限正确；
- state 和 artifact index 同属该 deployment；
- 不存在旧 catalog/state 的迁移、兼容加载或双读；
- `status`、`config validate`、`catalog validate` 成功。

使用隔离安装根和正式自动化验证：

- v1 marker 只能被 fresh purge 的 dry-run/purge 路径识别；
- daemon、reset-state、普通 reset-all 和其他命令拒绝 v1 layout；
- deployment id 不一致、损坏 manifest、incomplete marker 均 fail closed；
- reset-state/reset-all 保持 deployment id；
- purge-all/fresh setup 生成新 id；
- setup crash/failure injection 不产生可启动的半提交 layout。

## 7. 阶段 4：strict schema、DTO、digest 和 capability

运行正式测试并保存证据：

- strict JSON 拒绝 unknown field、duplicate key、错误类型、数字字符串、非法 enum alias、overflow 和超限对象；
- canonical 默认值、字段顺序和 collection 顺序稳定；
- topology collection 按 id 规范化，DNS/search 保留优先级顺序并拒绝重复；
- BootConfig v3、AgentPlan v2、BuilderPlan v1、InstallFirstBootPlan v1 上限有效；
- `rootfs_input_digest`、`desired_plan_digest`、`delivery_digest` 包含/排除规则正确；
- CLI/API/save-load round-trip 的 canonical bytes/digest 一致；
- CAS 冲突发生在任何副作用之前；
- capability 绑定 deployment/audience/resource/generation/counter；
- restart 只重构相同 token，不产生并行 token；
- master/hash/claim/counter 错配进入 `recovery_incomplete`；
- raw token 不进入 catalog、日志、cmdline、preview、普通 artifact 或持久 state。

确认 BootConfig 保持 v3、AgentPlan 为 v2，且没有 BootConfig v4、AgentPlan v1 fallback、`network.bootstrap.*`、
BIOS/PXELINUX、`ram_rootfs`、IPv6、iPXE、NFS root、reconciliation、远程任务或长期 enrollment handler/help。

## 8. 阶段 5：仅通过 CLI 导入 ISO

从安装根之外的原始文件通过 CLI 导入：

- Rocky Linux 9.7 aarch64；
- Rocky Linux 10.2 aarch64；
- Ubuntu Server 22.04.5 arm64。

检查：

- distro/version/arch；
- install source identity/revision；
- installer kernel/initrd 和 kernel release；
- Rocky Minimal/BaseOS/AppStream；
- Ubuntu APT ISO root/casper layers；
- repository、metadata、package manager 和 source pin；
- catalog entity、artifact path、size 和 digest；
- list/show 一致、catalog validate 成功；
- restart 后 revision/digest 不漂移。

错误介质、错误架构、重复名称和损坏 ISO 必须 fail closed，不留下半注册 entity。

## 9. 阶段 6：三套 diskless Profile 和 server builder

仅按 README/CLI：

1. 构建对应 NodeForge initrd；
2. 创建 boot bundle；
3. 创建 diskless Profile；
4. 读取 rootfs plan/input digest；
5. 用公开 CAS 参数提交构建；
6. 等待 operation 终态并查询 rootfs status。

先用 server builder 构建三个基线 Profile。每个都必须：

- `state=ready`；
- distro/version/arch/kernel release 正确；
- plan 与 `rootfs_input_digest` 一致；
- content SHA-512、size、uncompressed size、artifact path 完整；
- boot bundle/initrd/agent feature closure 完整；
- repo 和 SSH identity/provenance 正确；
- 相同输入 cache hit，不重复构建；
- 修改真实 build input 产生新 digest；
- placement、物理 builder id、URL 不污染 input digest；
- restart 后 ready artifact 保持；
- partial/staging 不可见为 ready。

## 10. 阶段 7：用 SN discovery 登记 r97n1

`r97n1` reservation IP 必须从 `r97n0` 的 hosts 解析：

```bash
ssh root@r97n0 'getent hosts r97n1'
```

禁止从工作站 DNS、历史 catalog、旧日志或手写常量推断。记录 `r97n1` 的真实 DMI product serial，然后仅用 CLI：

1. 创建只有 id、serial 和 reservation 的 draft Node；
2. 确认 `mac=null, arch=null, profile=null, deploy=false`；
3. 启动短时 discovery；
4. 让 `r97n1` 从 UEFI DHCP PXE 启动 discovery mode；
5. 验证临时 lease、probe session、facts 和 SN 唯一匹配；
6. 验证 catalog、NodeDiscoveryState、Observation 三对象原子提交；
7. 确认 MAC/arch 自动回填；
8. 成功后仍为 `profile=null, deploy=false`；
9. 下一次普通 PXE 才使用 reservation；
10. list/show/status/discovery 输出一致。

负向覆盖 placeholder/空/全 0/全 F SN、duplicate SN、零匹配、多 pending、MAC 冲突、revision race、expiry、cancel、
restart、幂等重放、body 漂移、跨 session/MAC replay 和 capacity rejection。discovery initrd 不得拉普通
BootConfig/AgentPlan/rootfs，不写 block device，不提供 shell/SSH。

随后绑定 Rocky 10.2 diskless Profile，保持 `deploy=false`，验证 hosts、repo、SSH identity、storage、topology、effective、
readiness 和 preview，且普通输出中没有 secret。

## 11. 阶段 8：PXE rootfs builder node

使用 `r97n1` 验证 node builder：

1. `deploy=false`；
2. 配置 eligible、ABI 和 capability class；
3. 准备独立 BuilderEnvironmentManifest/runtime；
4. 创建新 input digest，避免已有 ready artifact cache hit；
5. 设置 `builder.placement=node`；
6. plan 解析唯一 environment digest/class/ABI；
7. 提交 operation并选择/自动选择 `r97n1`；
8. 验证唯一 boot slot；
9. PXE 进入 builder mode；
10. 验证 plan/input/runtime、build、Range upload、finalize、deep validation 和原子发布；
11. artifact 进入 `r97n0` 统一 cache；
12. 完成后回收 slot、token 和临时 secret。

专项覆盖：启动循环消除、environment readiness、in-flight 去重、selection conflict、boot-slot 互斥、连续 Range、restart
resume、partial/越界/乱序/hash 错误、expiry、同 token recovery、no eligible、ABI/class mismatch、non-reproducible、
physical Node digest exclusion 和 tmpfs secret。最后确认 server builder 未回归。

## 12. 阶段 9：topology CLI 和 validator

通过公开 CLI 覆盖 `network.interfaces/bonds/vlans/routes` 的：

- list/show；
- add/set；
- replace-values；
- remove；
- replace-items。

验证：

- 全 mutation 支持 revision CAS，冲突零修改；
- id/bond mode 不可非法局部修改，mode 切换整集合原子替换；
- member 数量、唯一归属、member L3、primary/mac source、mode 专属字段；
- miimon/delay/min_links；
- VLAN parent/id/MTU 和 route 引用；
- duplicate address/default route/DNS/search；
- 至少一个 L3、最多一个 DHCP；
- static server route 可证明；
- 引用对象删除保护；
- MAC/interface id 规范化和全站唯一；
- CLI/help/API/effective/renderer/AgentPlan v2 字段一致；
- 中文 help 包含 active-backup、802.3ad、LACP、VLAN、交换机条件和 WARNING；
- reservation 只影响 DHCP bootstrap，不改 target DHCP/static；
- boot preview 无副作用且不输出 secret。

## 13. 阶段 10：真实 install/diskless/topology 矩阵

业务配置全部使用 CLI；VMware 只控制 `r97n1` 电源、控制台和 PXE。

最低 OS 回归：

1. Rocky 9.7 install；
2. Rocky 9.7 diskless；
3. Rocky 10.2 diskless；
4. Ubuntu 22.04.5 diskless；
5. Ubuntu 22.04.5 install，用于 Ubuntu target renderer 和 first-boot。

README 如有更多正式矩阵必须全部执行。

Rocky/RHEL 和 Ubuntu adapter 分别验证：单 NIC DHCP、单 NIC static、双 NIC、active-backup、802.3ad、
VLAN-on-bond、static route、DNS/search、bootstrap NIC 入 bond，以及 bootstrap/target address 相同和不同。

以上必须是真实目标环境 E2E。单测、namespace 或 renderer golden 只能补充；缺第二 NIC/LACP/VLAN 时整体 FAIL。

Install 必须证明 installer 保持 bootstrap、target config 仅 staged 到目标根、首次本地启动才生效、network-online/proof 在
first-boot 前通过，Rocky keyfile/Ubuntu Netplan 与 canonical topology 一致。

Diskless 必须证明 BootConfig v3/AgentPlan v2、target_network 唯一 owner、payload 预取、permanent-MAC link、bootstrap
snapshot、读 token 清除、有界 target DHCP、authenticated pre-init proof、renderer publish、init adopt、旧地址清理，且
`diskless.running` 不冒充 first-boot 成功。

故障 E2E 覆盖 carrier/LACP/DHCP/static route/proof 失败、逆序 rollback、bootstrap 恢复及二次 proof、禁止继续 init、
rollback_failed quarantine、adopt 失败和新 session retry。

## 14. 阶段 11：v0.3 install-post canonical 回归

创建全新 bundle，经 CLI 加入：

1. `managed_file`；
2. `package`；
3. `archive`；
4. `script`。

执行 Rocky 9.7 真实 PXE install，顺序必须为：

```text
managed_file -> package -> archive -> script -> @finalizer
```

验证 callback credential/generation/plan/path/method、event sequence、attempt/idempotency、严格顺序、retry/terminal、
journal/WAL/finalizer，以及 completion gate。所有 action/finalizer 成功前 `install.completed` 必须拒绝；完成后
successful/terminal/current generation 一致，requested/applied/desired digest 一致且 `drift_state=clean`。

Archive 覆盖 Mode A `.nf.install.sh`、Mode B、GNU tar/gzip/xz、owner/mode/ACL/xattr/link、保留入口冲突、绝对路径、
`..`、换行、损坏 tar 和普通 `install.sh` 不误执行。旧 `repository`、`standard_packages` action 必须无兼容、迁移或
fallback 地拒绝。验证 daemon restart 后 committing 恢复和 diskless 无回归。

## 15. 阶段 12：v0.4 install first-boot

另建 first-boot bundle/generation，不复用 install-post journal。至少验证：

1. empty plan：`not_required`，无 token/unit；
2. 四类 action 的完整 plan；
3. required step 故意失败的 generation。

检查 generation staging、agent/plan/payload digest、权限、fsync/rename/pending 顺序、完整 handoff、golden image 无 token、
network-online/adopt/proof gate、bootstrap exchange、响应中断重试、单 event token、started ACK 后 spent、固定 event id、
action 顺序、pending-ack fsync、reporter 只重送不重跑、普通重启不重跑、新 generation 重跑、terminal token expiry、
local/server stale、credential 缺失 recovery 和 secret cleanup quarantine。

server/local journal 的 deployment/node/generation/plan/event sequence/expected state 必须一致。

## 16. 阶段 13：容量、限流和 24 小时 soak

使用仓库正式版本化 workload harness；缺工具、manifest 或 README 入口即为发布缺口。

最低 workload：

| 维度 | 要求 |
|---|---:|
| registered Nodes | 256 |
| active BootSession | 64 |
| rootfs HTTP download | 32 |
| rootfs size | 2 GiB |
| Range interruption | 10% |
| event input | 100 req/s，30 分钟 |
| builder upload | 2 × 2 GiB |
| SN+IP draft Node | 256 |
| active discovery probe | 8 |
| discovery conflict injection | 25% |
| soak | 24 小时 |

workload 可以使用 `r97n0` 隔离实例/namespace，但必须使用正式二进制、公开协议和相同 listener/state 实现，不得直接写
state或影响真实 PXE VLAN。

覆盖 HTTP connection、management reserve、TFTP、BootSession、rootfs Range、builder upload、telemetry/control bucket、
operation 和 discovery admission。验证真实 accept/close、slow/keep-alive/disconnect、公平桶、Retry-After、authority 前拒绝、
slot 释放、persistent/live counter restart 语义及 metrics。

SLO：

- management p95 ≤ 200 ms，p99 ≤ 500 ms；
- BootConfig/AgentPlan p95 ≤ 300 ms，p99 ≤ 1 s；
- 无错误 session、token 越权、重复发布或损坏 artifact；
- 24 小时后 RSS/FD/temp 回到稳定窗口；
- 静止 10 分钟后相对 warm-up 增长 ≤ 5%。

24 小时不得缩短，未完成即 FAIL。

## 17. 阶段 14：失败、恢复和安全

为每类至少提供一个 fixture：W warning、R reject、F fail-current、B rollback、Q quarantine、D daemon-fatal。

验证 human/JSON warning、event/metric、exit code、R 零副作用、F 保留 ready、B 快照/逆序/幂等/proof、Q 禁止破坏性
自动重试、D 停止写服务，以及 rollback restart、setup purge、artifact publish uncertainty、builder interruption、first-boot
pending ACK、discovery transaction、token mismatch、secret cleanup和 capacity saturation/release。

扫描持久文件、普通日志、preview、events 和 cmdline，确认无 raw token/private key/password/Authorization header。扫描工具
不得把发现的 secret 内容打印到报告。

## 18. 阶段 15：完整自动化和发布闸

至少执行：

```bash
zig build test --summary all
zig build test-v0.3-install-post-e2e
```

另外执行 `build.zig`、README 和 `tests/` 中全部正式 v0.4 release/E2E：topology、AgentPlan v2、strict DTO、builder、
first-boot、discovery、capacity、setup replacement/failure injection，以及 Rocky/Ubuntu 目标环境 E2E。

先读取 `build.zig` 和脚本 usage，不凭文件名猜命令。记录命令、耗时、测试数量和结果。必要测试被 skipped 时不能 PASS。

## 19. 修复后完整重测

发现不一致时：

1. 保存最小复现；
2. 定位唯一 owner/根因；
3. 修复实现、测试、README 或当前 v0.4 文档；
4. 不改 v0.3 及以前冻结设计；
5. 不把 v0.4 缺陷移入保留设计逃避完成闸；
6. 运行针对性和完整自动化；
7. 重编四个程序；
8. 重新确认 `r97n0` 并彻底清场；
9. 从 §4 重跑全部 fresh 流程，包括真实 boot 矩阵和 24 小时 soak。

## 20. 最终报告

报告必须简明但可审计，固定包含：

1. 最终结论：PASS/FAIL；
2. 验证轮次、时间和总耗时；
3. commit、dirty 状态、产品/Zig 版本；
4. 两机环境、NIC、UEFI 和网络条件；
5. 四个构建产物表；
6. deployment id、marker、schema/DTO/state；
7. ISO/Profile/rootfs 表；
8. discovery/Node 证据；
9. server/node builder 矩阵；
10. install/diskless/topology 矩阵；
11. v0.3 install-post journal/completion gate；
12. v0.4 first-boot server/local journal；
13. capacity/SLO/24 小时 soak；
14. W/R/F/B/Q/D 和 restart/rollback/failure injection；
15. 自动化命令、数量和结果；
16. 问题、根因、修复和重测轮次；
17. 脱敏证据目录；
18. 未完成、未验证或 skipped 项；
19. 最终结论理由。

矩阵每项标记 PASS、FAIL 或 NOT RUN；NOT RUN 等同整体 FAIL。

只有以下全部成立才能 PASS：

- 最后一轮是完全清空后的 fresh v0.4 deployment；
- 仅靠 README 和公开 CLI 完成业务流程；
- v0.3 完整回归通过；
- v0.4 topology、builder、first-boot、discovery、capacity 和 recovery 全部通过；
- Rocky/RHEL 和 Ubuntu 目标环境 E2E 通过；
- 24 小时 soak 和 SLO 通过；
- 全部正式自动化通过；
- 没有必要项目被跳过；
- 没有复用旧配置/state/artifact 或内部接口；
- 源码、文档、产物和部署版本一致。

