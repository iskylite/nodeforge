# NodeForge v0.2 CLI 接口

状态：设计收敛，实现未开始。本文定义从空 catalog 构建 diskless rootfs、通过 PXE 启动节点及故障恢复的
完整 CLI。操作原理见 [`V0_2_DISKLESS_WORKFLOW.md`](V0_2_DISKLESS_WORKFLOW.md)。命令必须复用 v0.1
资源-动作树、typed PropertySpec/CollectionSpec/ItemSpec、统一 OutputDocument 和 optimistic concurrency；
预留 enum、help 或空 handler 不算实现。

## 0. 共用约定

- `show key == --help-full key == parser key == API operation path`。
- 结构化输入使用 `FIELD=VALUE` 或 `--from-file`，不要求 shell 内嵌 JSON。
- 全局 flag：`-c/--config <path>`、`-o/--output human|json|jsonl`、`--debug`；catalog 路径从 config
  解析，不另建会绕过 daemon owner 的写入口。
- mutation 默认要求 `--if-revision` 或服务端 If-Match；build/enable/retry 使用各自更窄的 digest/revision CAS。
- artifact stdout 只对白名单 export 命令开放；日志、命令回显、JSON 和 error 不得包含 token/password hash。
- 所有异步动作返回 operation id；`--wait` 等待同一 operation，不在客户端轮询后重复提交。
- exit code：0 成功；2 输入/不适用；3 revision/digest 冲突；4 not-ready/quarantined；5 operation failed；
  6 服务不可用。JSON error 同时返回稳定 `error.code`。

## 1. 阶段 0：服务与 builder 预检

```text
nodeforge preflight diskless-builder
nodeforge status --component dhcp,tftp,http,builder
nodeforge config validate
nodeforge catalog validate
```

`preflight diskless-builder` 是只读检查，至少输出 bind interface/IP、端口、asset/repository/staging 路径、
本地磁盘空间、`mksquashfs`、dnf/debootstrap/dracut capability、可构建 arch/kernel release 和 local-only
网络策略。`--output json` 为每项返回 `status/reason/remediation`，任一 required 项失败 exit 4。

## 2. 阶段 1：导入本地 OS 源

```text
nodeforge assets import <iso> [--name <source>] [--wait]
nodeforge assets install-source list
nodeforge assets install-source show <source>
nodeforge assets install-source software list <source> [--kind package|group|environment|task]
nodeforge assets repository list
nodeforge assets repository validate <repository>
nodeforge assets repository software list <repository> [--kind package|group|environment|task]

nodeforge assets runtime-kernel prepare --source <install-source> [--release <release>] [--wait]
nodeforge assets runtime-kernel list
nodeforge assets runtime-kernel show <kernel-asset>
nodeforge assets runtime-kernel validate <kernel-asset>
```

ISO import 成功必须原子发布 install source、installer kernel、media tree、本地 repositories 和 software index。
diskless `runtime-kernel prepare` 从固定 revision 的本地 kernel package 提取可启动 kernel，并记录完全匹配的 modules/package
closure、release 与 arch；不能默认把安装器 kernel 当作运行 kernel。重复 import 相同内容返回 existing resource；同名
不同 digest 返回 conflict，不静默覆盖。

## 3. 阶段 2：导入定制资产与 bundle

```text
nodeforge assets managed-file import <path> --name <asset> --destination <abs-path> \
  --mode 0644 --owner root --group root
nodeforge assets archive import <path> --name <asset>
nodeforge assets script import <path> --name <asset>

nodeforge assets provision-bundle create <bundle>
nodeforge assets provision-bundle show <bundle>
nodeforge assets provision-bundle item add <bundle> --phase rootfs-build \
  id=<id> action=managed-file content_asset=<asset> destination=/etc/motd mode=0644 owner=root group=root \
  idempotency_key=<key> timeout_s=30 retryable=false
nodeforge assets provision-bundle item add <bundle> --phase rootfs-build \
  id=<id> action=package packages=tmux,nmap idempotency_key=<key> timeout_s=600 retryable=true
nodeforge assets provision-bundle item add <bundle> --phase first-boot \
  id=<id> action=archive archive_asset=<asset> idempotency_key=<key> timeout_s=300 retryable=true
nodeforge assets provision-bundle item add <bundle> --phase first-boot \
  id=<id> action=script script_asset=<asset> interpreter=/bin/bash idempotency_key=<key> timeout_s=120 retryable=false
nodeforge assets provision-bundle item set <bundle> <id> FIELD=VALUE...
nodeforge assets provision-bundle item move <bundle> <id> --before|--after <ref>
nodeforge assets provision-bundle item replace-items <bundle> --phase <phase> --from-file <file>
nodeforge assets provision-bundle item list <bundle> [--phase rootfs-build|first-boot]
nodeforge assets provision-bundle plan <bundle> --phase rootfs-build|first-boot
```

- v0.2 parser 只接受 `rootfs-build|first-boot`；`install-post` 到 v0.3 才可用，不应提前出现在 v0.2 help。
- action 固定 `managed-file|package|archive|script`。每项必须有稳定 `id` 与 `idempotency_key`。
- plan 必须显示执行顺序、输入 digest、protected-path 判定、package resolution 和执行环境，无副作用。
- archive 顶层仅允许单一 `install.sh` 特例；拒绝绝对路径、`..`、device、FIFO、越界 symlink、重复覆盖
  protected path。script 只能来自已导入 asset，不能接收 argv 内联脚本。

## 4. 阶段 3：构建 initrd 与 BootBundle

```text
nodeforge assets nodeforge-initrd config show
nodeforge assets nodeforge-initrd config set KEY=VALUE...
nodeforge assets nodeforge-initrd modules-values add|remove|replace|clear VALUE...
nodeforge assets nodeforge-initrd firmware-values add|remove|replace|clear VALUE...
nodeforge assets nodeforge-initrd build --source <install-source> --kernel <kernel-asset> [--wait]
nodeforge assets nodeforge-initrd list
nodeforge assets nodeforge-initrd show <asset>
nodeforge assets nodeforge-initrd validate <asset> [--deep]

nodeforge assets boot-bundle create <bundle> \
  install_source=<source> kernel=<kernel-asset> initrd=<nodeforge-initrd-asset>
nodeforge assets boot-bundle set <bundle> FIELD=VALUE...
nodeforge assets boot-bundle list
nodeforge assets boot-bundle show <bundle>
nodeforge assets boot-bundle validate <bundle>
```

BootBundle 只固定 source + prepared runtime kernel + NodeForge initrd revisions，不含 rootfs。`set` 产生新 resource revision；
active session 的旧 snapshot 不得被原位破坏。validate 联合检查 arch、kernel release、modules ABI、NIC firmware 和
required features，但不要求 rootfs 已构建。

## 5. 阶段 4：创建 diskless Profile

```text
nodeforge profile create <profile> --kind diskless \
  diskless.boot_bundle=<boot-bundle> [diskless.provision.bundle=<bundle>]
nodeforge profile set <profile> diskless.overlay.tmpfs_percent=40 \
  diskless.failure.max_attempts=3 diskless.failure.backoff_seconds=30
nodeforge profile set <profile> system.ssh.enabled=true system.timezone=Asia/Shanghai
nodeforge profile add-values <profile> software.packages.include chrony
nodeforge profile remove-values <profile> software.packages.include <package>
nodeforge profile show <profile>
nodeforge profile effective <profile>
```

`--kind` 是 immutable discriminant。diskless 不接受 `install.*`；install Profile 不接受 `diskless.*`。
`diskless.provision.bundle` 可省略；无 first-boot item 时 agent 只完成 running handoff/event，不执行后处理。
有 first-boot item 时，其 manifest/assets/package closure 在 rootfs build 中预置，CLI plan 必须显示 payload size；
agent 不在启动后拉取可变 bundle 或在线解析依赖。
list/set 类型必须使用对应 collection 命令。

## 6. 阶段 5：创建 Node，先保持 deploy=false

```text
nodeforge node add <id> mac=<mac> arch=<arch> profile=<diskless-profile> deploy=false
nodeforge node set <id> pxe.ip_reservation=<ip> hostname=<fqdn>
nodeforge node set <id> network.mode=dhcp network.interface=<nic>
nodeforge node set <id> network.mode=static network.interface=<nic> \
  network.address=<ip> network.prefix_len=<prefix> network.gateway=<gw>
nodeforge node add-values <id> network.dns <dns>...
nodeforge node add-values <id> kernel_args.add console=ttyS0
nodeforge node show <id>
```

- Node direct 字段不进入 overrides；diskless 不消费 storage，非空 install-only override 使 readiness 失败。
- Profile 换绑只允许 `deploy=false` 且无 active/recoverable session。kind 改变时旧 current state 归档。
- 同一 MAC 只能对应一个 Node；同一 Node 只能有一个 Profile kind 和一个 current session。

跨 kind 换绑被阻止时，human error 必须给出当前阻塞事实和可复制的下一步，禁止只报 `conflict`：

```text
error: node.profile_kind_change_blocked
node c001: diskless -> install is not allowed yet
blockers:
  - deploy is true
  - session 9a2c... is active at diskless.rootfs_downloading
next:
  1. nodeforge node set c001 deploy=false
  2. nodeforge node status c001
  3. wait until the session is terminal, then run: nodeforge node set c001 profile=rocky-install
note: deploy=false blocks new PXE boots; it does not terminate the active session
```

若已经 `deploy=false` 但存在 recoverable session，提示其 expiry 和 `node trace` 命令；v0.2 不提供 `--force`
绕过，也不为换 kind 远程停止节点。JSON error 固定包含 `code/from_kind/to_kind/blockers/active_session/
recoverable_until/next_commands`。

## 7. 阶段 6：build plan 与 rootfs 构建

```text
nodeforge node effective <node> --section build
nodeforge node rootfs plan <node>
nodeforge node readiness <node> --stage build
nodeforge node rootfs build <node> --if-input-digest <digest> [--wait]
nodeforge node rootfs status <node> [--operation <id>]
nodeforge assets rootfs list [--state building|ready|failed]
nodeforge assets rootfs show <rootfs-input-digest>
nodeforge assets rootfs validate <rootfs-input-digest> [--deep]
```

`rootfs plan` 输出：desired plan/input digest、cache state、fixed revisions、builder/arch capability、软件解析、
预计 compressed/uncompressed size、rootfs-build steps 和明确排除的 per-node projection。它不要求 deploy=true。

`rootfs build`：

- 必须带刚预览的 input digest；漂移返回 `operation.input_digest_conflict`（exit 3）。
- 相同 digest building 时 join operation，ready 时返回 cache hit。
- `--force` 仅做 reproducibility rebuild，不覆盖旧对象；相同输入输出不同则失败。
- operation 输出 `queued|building|validating|ready|failed`、step、percent/bytes、started/updated、稳定 reason。

## 8. 阶段 7：boot readiness 与启用

```text
nodeforge node readiness <node> --stage boot
nodeforge node boot preview <node>
nodeforge node set <node> deploy=true --if-plan-digest <desired-plan-digest>
nodeforge node set <node> deploy=false
```

`--stage build` 与 `--stage boot` 必须分开：前者回答“能否构建”，后者回答“现在能否发 bootfile”。boot
readiness 检查 rootfs ready、deep validation、delivery manifest、feature/kernel/modules、BootConfig renderer、
MAC/IP、quarantine 和 session gate。若已有可信 `inventory.memory_bytes`，服务端执行硬内存预算；新节点内存
未知时输出 `memory=unknown` 与 `required_min_bytes` warning，不能伪造通过结论，最终由 initrd 实测硬闸。

`deploy=true` 是唯一启用入口，必须 CAS desired plan digest；not-ready 返回逐项 reason，不创建失败 attempt。
`deploy=false` 立即阻止新 PXE，但不终止正在下载/运行的 session。
`boot preview` 只显示 capsule digest/path template/expiry，不显示 config token；真实 per-session capsule 只在 DHCP
ACK 建 session 后生成，不能由 CLI 预生成或导出。

## 9. 阶段 8：唯一状态与观测

```text
nodeforge node list [--kind install|diskless] [--state <canonical-state>]
nodeforge node status <node>
nodeforge node trace <node> [--session <id>]
nodeforge runtime dhcp-leases [--node <id>]
nodeforge runtime tftp-sessions [--node <id>]
nodeforge events list --node <id> [--session <id>] [--type <type>] [--since <iso>]
nodeforge events follow --node <id> [--session <id>]
```

human list 固定列：

```text
ID   KIND      PROFILE      STATE                    SESSION  POSTPROCESS  QUARANTINE  SEEN
c001 diskless  compute      diskless.running         9a2c...  succeeded    ok          ...
n002 install   rocky-base   install.packages         c017...  -            ok          ...
```

`STATE` 是唯一 current lifecycle state。JSON `current` 是 tagged union：

```json
{"kind":"diskless","state":"diskless.running","session_id":"...","plan_digest":"...","postprocess":{"status":"succeeded"}}
```

禁止同时输出 `install_state` 和 `diskless_state`。历史不同 kind 只由 trace/events 展示，并明确 session/kind/digest。

## 10. 阶段 9：first-boot 结果

```text
nodeforge node postprocess show <node> [--session <id>]
nodeforge node postprocess show <node> --step <id> [--include-output]
```

使用 `postprocess` 而不是 `postinstall`：diskless 没有 install，`postinstall` 会造成所有权误解。输出 step 的
`pending|running|succeeded|warned|failed|skipped`、attempt、summary、bounded output 和时间戳。

first-boot 失败不把 lifecycle 从 `diskless.running` 回退为 failed；它只令 `postprocess=degraded`。没有独立
远程 retry：当次 retryable step 按策略自动重试；新 PXE session 会重新执行所有 first-boot items。
该命令展示服务端已收到的 event 投影，不远程读取节点；事件回传中断时返回 `reporting=incomplete` 和最后 seq，
本地 journal 只能通过节点 console/SSH 运维查看，CLI 不伪造最终 succeeded/failed。

## 11. 阶段 10：quarantine、retry 与缓存容量

```text
nodeforge node diskless retry <node> --if-failure-revision <revision>
nodeforge status --component rootfs-cache,quarantine
```

- retry 只清当前 `(node, plan_digest)` failure gate；active session、deploy=false、kind!=diskless、digest 漂移均拒绝。
- v0.2 没有 rootfs delete/GC 命令。status 显示 object count、total bytes、filesystem available bytes 和告警阈值；
  空间不足时 build 返回 `rootfs.insufficient_storage`，不得自动删旧镜像。

## 12. v0.3+ 命令隔离

- v0.3 才提供 `firmware.mode=bios`、PXELINUX 和 `install-post` phase。
- v0.4 才提供多 NIC/VLAN/bonding、远程 builder 和 install first-boot agent。
- v0.5 才提供 `diskless.overlay.mode=ram_rootfs`。

这些字段/enum/handler 不得出现在 v0.2 help 或 parser 中；reconciliation、远程命令、NFS root、iPXE、IPv6
永久没有对应 CLI。
