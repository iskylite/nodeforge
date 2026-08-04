# NodeForge v0.4 fresh 全量验证任务书

状态：发布闸。任一必需项缺少真实证据即 FAIL。

## 1. 固定环境与角色

- `r97n0`：管理节点，fresh 安装 NodeForge，运行 `nodeforged`，提供 DHCP/TFTP/HTTP，并在本机生成所有 rootfs。
- `r97n1`：计算节点，验证 install、first-boot、discovery 和 diskless ready artifact 交付。
- VMware Fusion：用于真实固件、网卡连接和 PXE/本地盘启动观察；QEMU 只能补充，不能替代要求的 VMware 证据。

整个任务中不得改变上述角色。r97n1 不安装构建工具，不运行 package-manager 来生成 diskless rootfs，不生成或上传 squashfs。

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
```

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

## 7. install first-boot

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

## 12. capacity、恢复与 soak

逐项压满 boot session、diskless delivery、operation、first-boot journal、discovery observation、worker queue 与 HTTP body 上限。达到上限时须在创建副作用前返回稳定错误；释放或过期后容量可复用。

在 queued、running、artifact rename 前后、state rename 前后、first-boot step 中和 diskless delivery 中重启 daemon。恢复后校验：

- 不复活终态 authority；
- 不延长原 deadline；
- 不接受 digest/generation 漂移；
- 不遗留可被交付的 `.part`；
- 随机 capability 已轮换；
- rootfs 仍只由 r97n0 服务端 operation 处理。

最后运行 24 小时 mixed workload，持续采集 RSS、FD、线程、session/operation 数、state 文件大小、DHCP/TFTP/HTTP 错误率与 r97n1 重启成功率。

## 13. 发布结论

PASS 必须同时满足：本地测试全绿、v0.3 回归、topology、first-boot、discovery、Rocky/Ubuntu 服务端 rootfs 生成、diskless ready artifact 交付、token 负测、capacity/recovery 和 24 小时 soak。

报告应明确列出每项 PASS/FAIL/NOT RUN 和证据路径。任一必需项为 FAIL 或 NOT RUN，v0.4 总结论即 FAIL。
