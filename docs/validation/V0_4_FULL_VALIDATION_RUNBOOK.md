# NodeForge v0.4 fresh 全量验证任务书

状态：发布闸。任一必需项缺少真实证据即 FAIL。

## 1. 固定环境与角色

- `r97n0`：管理节点，fresh 安装 NodeForge，运行 `nodeforged`，提供 DHCP/TFTP/HTTP，并在本机生成所有 rootfs。
- `r97n1`：计算节点，验证 install、first-boot、discovery 和 diskless ready artifact 交付。
- VMware Fusion：用于真实固件、网卡连接和 PXE/本地盘启动观察；QEMU 只能补充，不能替代要求的 VMware 证据。

整个任务中不得改变上述角色。r97n1 不安装构建工具，不运行 package-manager 来生成 diskless rootfs，不生成或上传 squashfs。

r97n0/r97n1 用于证明真实固件和单节点端到端功能；256/512/1024 容量矩阵使用同一候选二进制的协议/workload harness，在当前 r97n0 环境生成逻辑 Node/session/client。报告必须记录 CPU、RAM、磁盘、NIC 速率、文件系统、DHCP subnet/address pool 和所有容量覆盖值。合成 workload 不能替代至少一台 r97n1 的真实 install 与 diskless 闭环，也不能作为 256/512 台真实节点生产吞吐证据。后者按统一清单的 [`ENV-V04-PRODUCTION-SCALE`](../design/DEFERRED_DESIGN_INDEX.md) 延后，不阻断 v0.4。

## 2. 证据规则

每一阶段记录：候选 commit、构建时间、二进制 SHA-256、config/catalog schema、命令、退出码、UTC 时间、r97n0 service 日志、r97n1 console 截图或串口日志，以及相关 state/artifact digest。

允许使用 Computer Use 操作 VMware Fusion，但结论必须由 console、网络抓包、HTTP/state 输出或文件 digest 支撑。只看到 VM “Running”不构成协议成功证据。

失败后保留现场，再执行诊断。禁止为了得到 PASS 手工编辑 state、伪造 event、跳过 deep validation 或把已有 artifact 冒充本轮生成结果。

## 3. 本地预检

在源码目录执行：

```sh
zig fmt --check src build.zig
zig build test --summary all
zig build test-v0.4-contract
git diff --check
```

`test-v0.4-contract` 会执行已删除接口的负向残留闸。随后确认正式入口仍存在：

```sh
nodeforge profile rootfs plan --help-full
nodeforge profile rootfs build --help-full
nodeforge profile rootfs status --help-full
nodeforge profile rootfs staging list --help-full
```

可选运维特需（非发布阻断）：`build --keep-staging` 保留解包树，`build --from-staging` 再打包，`staging show/remove` 查询与清理；边界见设计文档 §1.1.1。

## 4. fresh 安装 r97n0

1. 备份旧 `/opt/nodeforge` 与 `/var/lib/nodeforge`；
2. 使用 `setup --reset-all` 或全新 install root，不复用旧 runtime state；
3. 校验 root marker、AppConfig schema 5、catalog schema 6；
4. 启动 `nodeforged`，确认 process、loopback management、advertised HTTP、DHCP、TFTP、active config 与 catalog readiness；
5. 重启 daemon，再次确认 readiness，且没有旧 schema 或恢复漂移错误。

## 5. v0.3 回归

对 r97n1 执行一次正式 install generation：

1. DHCP lease、UEFI bootfile、kernel/initrd 下载成功；
2. 安装计划 digest 与 generation 绑定；
3. destructive install gate 未武装时不下发 bootfile；
4. install-post canonical step 顺序、event replay、失败与重试行为保持 v0.3 契约；
5. 完成后本地盘启动，旧 boot-session capability 不可复用。

## 6. topology

至少验证：

- 单 NIC DHCP；
- 双 NIC 且唯一 bootstrap MAC；
- static IPv4；
- VLAN；
- bond；
- 非默认 MTU；
- 多 route，且只有一条可达管理面的默认 route。

负测包括重复 MAC、未知 member、环、重复默认 route、越界 MTU、无管理面可达路径和 topology digest 漂移。失败必须在 arm/boot-prepare 前被拒绝。

不能只检查 validator 或 AgentPlan。逐后端检查实际目标系统文件：

- Rocky/kickstart 与 diskless NetworkManager ifcfg/keyfile 均包含多 interface、bond、VLAN 和按 `route.interface_id` 绑定的 route；
- Ubuntu install 与 diskless netplan 均包含完整 `ethernets`、`bonds`、`vlans`、routes、DNS/search domains；
- 结构化 topology 的任一字段不得在 adapter 或 `node-apply renderNetwork` 中静默丢失；无结构化 topology 时单 NIC 路径保持回归通过。

不把 first-boot 网络连通性检查作为部署完成条件，也不验证不存在的 installer/target 内核切换；交换机或集群网络不可达应作为独立运维故障记录。

## 7. install first-boot

本节只验证安装写盘并从本地盘启动后的 v0.4 `InstallFirstBootPlan`。diskless `switch_root` 后、真正 init 前的 `node-apply renderNetwork` 属第 10 节；diskless systemd first-boot canonical postprocess 也不得复用本节的 generation、凭据、journal 或事件结论。

1. 创建包含 first_boot step 的 provisioning bundle；
2. 执行新 install generation；
3. 确认安装完成后状态为 first-boot pending；
4. 从本地盘首次启动并获取 generation-bound plan；
5. 验证 managed file、package、archive、script 的允许集合与固定顺序；
6. 中途重启，确认成功 step 不重跑；
7. 完成后 deployment 才进入完成态；
8. 重放相同 event 幂等，body 漂移、错误 generation、过期和越权请求拒绝。

## 8. SN+IP discovery

1. catalog 中不预建 r97n1；
2. 启用受限 discovery policy 并从 VMware PXE 启动；
3. 观察 SN、MAC、IP、architecture 与 NIC facts；
4. 确认 draft observation 不能获得 install/diskless 交付；
5. 由 loopback CLI claim 成正式 Node；
6. 重复 SN、重复 MAC、IP 漂移、过期 observation、错误 architecture 和 catalog CAS 冲突均拒绝；
7. claim 后按正式 deploy/generation gate 启动。

## 9. 服务端 rootfs 生成

Rocky 与 Ubuntu 分别执行完整流程。每个 Profile 先确认 plan 为 cache miss，再提交：

```sh
nodeforge profile rootfs plan <profile> -o json
nodeforge profile rootfs build <profile> --detach -o json
nodeforge operation show <operation-id> -o json
nodeforge profile rootfs status <profile> -o json
```

在 r97n0 证明：

- operation kind 为 `rootfs_build`；
- DNF/APT、chroot/namespace、payload materialization、`mksquashfs` 和 deep validation 都发生在 nodeforged 主机；
- repository URL 是本机受管路径，不含 Authorization、Bearer、session header 或 `http_headers`；
- artifact 的 input digest、SHA-512、compressed/uncompressed size、kernel release 与文件路径一致；
- daemon 重启后 artifact 仍 ready；
- 重提相同 input 命中 cache，不重复产生不同内容；
- 任一 input revision 改变会产生新 digest。

失败注入：package transaction 失败、payload digest 漂移、`mksquashfs` 失败、deep validation 失败和 daemon 中断。任何失败都不能发布半成品；中断 operation 不得转移给 r97n1 继续。

## 10. diskless 交付

只有上一阶段 artifact ready 后才启动 r97n1：

1. boot-prepare 固定当前 input digest 与 artifact；
2. initrd 下载 rootfs 时校验 size、SHA-512、ETag/Range；
3. squashfs 只读挂载为 lower，writable overlay 为临时层；
4. AgentPlan/payload digest 校验成功；
5. `switch_root` 后网络、SSH、hostname、facts 与 event 收敛；
6. daemon restart 后按持久 delivery authority 恢复并轮换随机 capability。

必须保存 r97n1 console 和进程证据，证明启动期间未执行 DNF、APT、RPM transaction 或 `mksquashfs`，也没有 rootfs 上传请求。cache miss 时 r97n1 必须拿不到 diskless bootfile/BootConfig，而不是现场生成。

## 11. token 与 repository 负测

- catalog、state、logs、capsule 以外的普通输出中扫描 raw token；
- repository access log 中不得出现 Authorization 或 session header；
- 改动 capability、session id、Node id、generation、event counter、expiry 任一字段都应拒绝；
- management API 从非 loopback peer 访问必须拒绝；
- 大对象固定 digest 数据面不得因为漏 token 而触发 package-manager 定制 header。

## 12. capacity、恢复与资源边界

容量以尚未进入终态的 install + diskless 节点总数定义，不能用 HTTP connection 数或 TFTP transfer 数替代。依次执行：

| 档位 | install | diskless | mixed | 结论用途 |
|---|---:|---:|---:|---|
| 实现容量基线 | 256 | 256 | 128+128 | 合成发布闸必过 |
| 标准合成扩展 | 512 | 512 | 256+256 | 合成配置覆盖必过 |
| 合成压力验证 | 1024 | 1024 | 512+512 | 记录退化与资源曲线，不作为最高上限 |

表中三个 workload 是分别执行的场景，不是同时相加。v0.4 运行时配置可以覆盖到当前 2048 实现安全天花板；超过 2048 必须在启动前拒绝，不能截断或运行中失败。256 使用至少容纳 256 个动态 lease 的 `/23`，512 使用 `/22`，1024 使用 `/21` 或更大的 subnet/address pool，并为 nodeforged、网关等基础设施地址留出空间。

逐项压满 boot session、diskless active delivery、install active first-boot、operation、discovery observation、worker queue、HTTP connection 与 HTTP body 上限。达到上限时须在创建副作用前返回稳定错误；`DisklessSessionCapacity` 等 admission 错误返回 `capacity.exhausted`/HTTP 503。终态、取消或过期后 active 容量可复用。

每个档位至少验证：

- diskless 与 install first-boot 终态不再占 active slot，下一完整波次可立即复用容量；超时非终态可由 reaper 回收；
- terminal summary 经既有 node status/deployment control 可查询该档位中每个 Node 的最新终态；512 个终态不能因 256 条 history 环覆盖而丢失 node-list 权威状态，也不能为此增加新的 durable domain；
- install-post 连续 3 轮 256 mixed 逻辑波次后按 retention/compact 收敛，不无界保留 terminal run；
- diskless 列表/查询不在请求栈复制完整 Session 大数组，RSS 与线程栈不随编译期天花板产生危险峰值；
- lifecycle event 不重写全部 active AgentPlan；记录每波 checkpoint/journal 写入字节、event 响应延迟、恢复时间和 compact 结果，确认不存在随节点数平方增长的全量写放大；
- daemon 可从各档位的合法最大 checkpoint 恢复，不受固定 4 MiB 等低于合法格式最大值的读取上限阻断；
- HTTP listener 的配置值真实限制 accepted connections，生成的 systemd unit 有匹配的 `LimitNOFILE`；management loopback 在负载下仍可观测，但不宣称单 listener 提供无法兑现的保留连接；
- TFTP 默认 128 限制同时在传的小文件，不限制部署波次；超出 transfer admission 的客户端经重试/错峰完成，记录最后一个节点完成 TFTP 的时间；
- DHCP lease、boot session、status、inventory 与 deployment control 在 256/512/1024 场景下均未提前触及小于 workload 的隐含上限。

在 queued、running、artifact rename 前后、state rename 前后、first-boot step 中和 diskless delivery 中重启 daemon。恢复后校验：

- 不复活终态 authority；
- 不延长原 deadline；
- 不接受 digest/generation 漂移；
- 不遗留可被交付的 `.part`；
- 随机 capability 已轮换；
- rootfs 仍只由 r97n0 服务端 operation 处理。

最后由 workload harness 连续执行 3 轮 256 mixed 同 Node 逻辑波次，并各执行 1 轮 512 标准合成扩展和 1024 合成压力场景。跨波次采集当前/峰值 RSS、FD、线程、active/terminal session、operation/queue 数、journal/state 文件大小、checkpoint 写入量、DHCP/TFTP/HTTP 错误率与逻辑波次完成时间。每轮结束、全部逻辑节点进入终态并完成 retention/compact 后，allocator leak check、session、queue、journal、terminal summary、FD、线程、checkpoint、plan 目录和 state 文件必须保持确定性有界，不得出现未界定增长。

测试进程 RSS 仍须原样记录和说明退化，但 Zig testing/debug allocator、同进程其他测试与 OS page cache 会保留已释放页面，仅凭 RSS 未回落不能区分产品泄漏与 allocator 高水位。独立候选 `nodeforged` 进程的连续波次 RSS 稳态按统一延期清单的 [`ENV-V04-RSS-STEADY`](../design/DEFERRED_DESIGN_INDEX.md) 补充验证，不单独使 v0.4 FAIL；若 allocator leak、checkpoint、terminal summary、FD、线程或其他确定性指标增长，仍必须判 FAIL，不能归入该延期项。本发布闸不要求等待固定小时数，也不要求启动 256/512 台真实 VM。

## 13. 发布结论

PASS 必须同时满足：本地测试全绿、v0.3 回归、r97n1 单节点 topology/first-boot/discovery/install/diskless 闭环、Rocky/Ubuntu 服务端 rootfs 生成、token 负测、capacity/recovery、256 合成容量基线和关键资源边界测试。512 标准合成扩展必须给出 PASS；1024 合成压力验证必须给出证据和退化说明，但不是产品最高上限。256/512 台真实节点生产规模验证属于延期项，缺少该证据不使 v0.4 FAIL，也不得据此宣称已验证生产吞吐。

报告应明确列出每项 PASS/FAIL/NOT RUN 和证据路径。任一必需项为 FAIL 或 NOT RUN，v0.4 总结论即 FAIL。
