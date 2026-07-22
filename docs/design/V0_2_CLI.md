# NodeForge v0.2 CLI 接口

状态：设计冻结，实现未开始。本文是 v0.2 diskless 的完整 CLI 参考，与 [`V0_2_DESIGN.md`](V0_2_DESIGN.md)
§5.5 一致。全部命令复用 v0.1 资源-动作树（`nodeforge <resource> <action>`）、三组 collection 操作
（`list-values/add-values/remove-values/replace-values/clear-values`）、structured collection
（`item add/set/move/replace-items`）与全局 flag。新命令必须先进入 typed
PropertySpec/CollectionSpec/ItemSpec 再给 handler；预留 enum/空 handler 不算实现。

## 0. 共用约定（继承 v0.1）

- `show key == --help-full key == parser key == API operation path`。
- 任何 v0.2 CLI 不得要求 Shell 内嵌 JSON；结构化输入用 `FIELD=VALUE` 或 `--from-file`。
- 全局 flag：`--config <path>`、`--catalog <path>`、`--output human|json|jsonl`、`--debug`。
- 普通 handler 走统一 `OutputDocument`；rootfs/initrd 导出等 artifact stdout 为白名单。
- 每个 leaf command 支持 `-h/--help`（紧凑）与 `--help-full`（完整 canonical key/约束/示例）。

## 1. 阶段一：资源准备（Assets）

### 1.1 import

```text
nodeforge assets import <iso>            # v0.1 已有：发布 install source/repository/默认 Profile
nodeforge assets managed-file import <path> --destination <abs-path> --mode 0644 --owner root --group root
nodeforge assets archive import <path>           # tar.bz2，SHA256 由 asset 提供
nodeforge assets script import <path>            # 受审计可执行脚本
```

### 1.2 查询

```text
nodeforge assets managed-file list
nodeforge assets managed-file show <asset>
nodeforge assets archive list
nodeforge assets archive show <asset>
nodeforge assets script list
nodeforge assets script show <asset>
```

### 1.3 provision-bundle（CRUD + item）

```text
nodeforge assets provision-bundle create <bundle>
nodeforge assets provision-bundle show <bundle>
nodeforge assets provision-bundle list
nodeforge assets provision-bundle item add <bundle> --phase first-boot \
  action=managed-file content_asset=<id> destination=/etc/hosts.d/nodeforge mode=0644 owner=root group=root \
  idempotency_key=hosts-nodeforge timeout_s=30 retryable=false
nodeforge assets provision-bundle item add <bundle> --phase first-boot \
  action=package environment=<id> idempotency_key=pkgs-base timeout_s=600 retryable=true
nodeforge assets provision-bundle item add <bundle> --phase first-boot \
  action=package packages=nmap,tmux group=core idempotency_key=pkgs-extra timeout_s=600 retryable=true
nodeforge assets provision-bundle item add <bundle> --phase first-boot \
  action=archive archive_asset=<id> idempotency_key=custom-app timeout_s=300 retryable=true
nodeforge assets provision-bundle item add <bundle> --phase first-boot \
  action=script script_asset=<id> interpreter=/bin/bash idempotency_key=motd-script timeout_s=120 retryable=false
nodeforge assets provision-bundle item set <bundle> <identity> FIELD=VALUE...
nodeforge assets provision-bundle item move <bundle> <identity> --before|--after <ref>
nodeforge assets provision-bundle item replace-items <bundle> --phase first-boot --from-file items.txt
nodeforge assets provision-bundle item list <bundle> --phase first-boot
```

- archive 规则：读取 tar，若顶层存在 `./install.sh` 则解压到临时目录执行 `./install.sh`；否则解压到 `/`。
  manifest 只声明 SHA256，不设 `script|extract` 策略、`target_root`、`install --root`。
- package 的 `packages`/`group`/`environment`/`selection` 至少一项，经本地 repository 解析校验、幂等。
- `phase` 取值：`install-post`（v0.3）/`rootfs-build`（v0.2）/`first-boot`（v0.2）；**无 `runtime`**。

## 2. 阶段二：diskless Profile 配置

```text
nodeforge profile create <profile> --kind diskless
nodeforge profile set <profile> diskless.provision.bundle=<bundle>
nodeforge profile set <profile> diskless.overlay.upper_size_mb=512
nodeforge profile set <profile> diskless.failure.max_attempts=3
nodeforge profile set <profile> diskless.failure.backoff_seconds=30
nodeforge profile show <profile>
nodeforge profile unset <profile> diskless.failure.max_attempts
```

- `--kind` 是 Profile 创建时固定字段，不允许 Node override；不同 kind/source 应绑定另一个 Profile。
- 复用 v0.1 target-system/software/kernel_args（`system.*`/`software.*`/`kernel_args`）与三组 collection
  操作，不建立第二套默认值。
- `profile set` 遇 list/set 类型 key 返回 `property.list_operation_required` 并给出替代命令。

## 3. 阶段三：Node 配置

```text
nodeforge node add <id> mac=<mac> arch=<arch> profile=<diskless-profile>
nodeforge node set <id> pxe.ip_reservation=<ip> hostname=<fqdn> deploy=true
nodeforge node set <id> network.interface=eth0 network.ip=<ip> network.netmask=<mask> network.gateway=<gw>
nodeforge node add-values <id> kernel_args.add console=ttyS0
nodeforge node show <id>
nodeforge node effective <id>
```

- Node direct 字段（mac/arch/hostname/pxe.ip_reservation/network.*）不进 overrides。
- diskless 不消费安装磁盘选择器；`storage.boot_disk/additional_disks` 对 diskless 无意义（属 install）。
- `deploy=true` 后 readiness 才校验 pinned rootfs 是否就绪。

## 4. 阶段四：initrd 构建（dracut）

```text
nodeforge assets nodeforge-initrd config show
nodeforge assets nodeforge-initrd config set dracut_modules=network,overlayfs,squashfs-loop
nodeforge assets nodeforge-initrd build --kernel <release> --output <dir>
nodeforge assets nodeforge-initrd show <asset>
```

- 构建时自动注入 `nodeforge-initrd` 程序作为 dracut 引导模块（见
  [`V0_2_PROGRAM_DESIGN.md`](V0_2_PROGRAM_DESIGN.md) §3）。
- boot bundle = kernel + NodeForge initrd + rootfs 引用，与 kernel release 联合校验。

## 5. 阶段五：rootfs 构建

```text
nodeforge node rootfs show <node>              # 查询构建状态/digest/size/缓存
nodeforge node rootfs build <node>             # 按 pinned effective plan 构建
nodeforge node rootfs build <node> --force     # 强制重建（忽略 digest 缓存）
```

- rootfs 按 effective digest 缓存、跨 Node 共享；`--force` 重算 OS 层 + rootfs-build phase。
- 构建失败阻止 rootfs ready（不发 succeeded），经 `rootfs show` 与构建日志暴露。

## 6. 阶段六：预览与校验

```text
nodeforge profile plan <profile>              # 迁移 plan，无副作用
nodeforge node plan <node>
nodeforge profile effective <profile>
nodeforge node effective <node>                # DisklessEffectivePlan + digest
nodeforge profile readiness <profile>          # 发布前检点
nodeforge node readiness <node>
nodeforge catalog validate
nodeforge config validate
```

- readiness 校验 Profile/Node/capability/rootfs/feature 子集全部就绪
  （[`V0_2_IMPL_DETAILS.md`](V0_2_IMPL_DETAILS.md) §3.2）。

## 7. 阶段七：引导与状态

```text
nodeforge node diskless retry <node>           # 清 boot-level quarantine（不改 Profile/不远程重启）
nodeforge node trace <node>                    # BootSession canonical 状态轨迹
nodeforge node list                            # 统一 KIND/BOOT_SESSION/DEPLOYMENT/QUARANTINE/SEEN
nodeforge node status <node>
nodeforge runtime dhcp-leases
nodeforge runtime tftp-sessions
nodeforge events list --node <id> --type provision.step.failed --since <iso>
nodeforge events follow --node <id>
nodeforge events types
```

- `node diskless retry`：存在活动 session / `deploy=false` / Profile 非 diskless / desired digest 已变化
  时 fail closed。
- `events list` 支持 `--node`/`--type`/`--source`/`--since`/`--level` 过滤。

## 8. 阶段八：后处理结果查询

```text
nodeforge node postinstall show <node>                 # first-boot 各 step 状态/摘要/时间戳
nodeforge node postinstall show <node> --phase first-boot
nodeforge node postinstall show <node> --step <identity> --output json
nodeforge node postinstall show <node> --include-stdout  # 含脚本 stdout/stderr 摘要（最后 2048B 转义）
nodeforge status                                      # 全局健康：daemon/协议栈/rootfs 缓存/quarantine 概览
```

- 后处理结果含 step 状态（`succeeded`/`warned`/`failed`/`skipped`）、`summary`、`outputs`、`warnings`、
  时间戳与幂等键；失败 step 可 retryable 时显示 retry 策略。
- 回传失败时本地兜底信息可查（日志/console/boot.json 投影）。

## 9. v0.3/v0.4/v0.5 CLI（非 v0.2）

- **v0.3**：`node set firmware.mode=bios`（schema v5）、`profile set install.post_install.bundle`、
  `install-post` phase item。v0.2 不提供这些命令的 help/handler。
- **v0.4**：多 NIC/VLAN/bonding、容量压测、install 侧 first-boot agent、远程/节点 rootfs 构建的 CLI
  随其设计落地；reconciliation/远程控制为永久非目标，无对应 CLI。
- **v0.5**：`diskless.overlay.mode` 切换与 `ram_rootfs` CLI 见 [`V0_5_DESIGN.md`](V0_5_DESIGN.md)。

v0.2/v0.3 不提供上述非目标命令的 help/handler；预留 enum 不算实现。
