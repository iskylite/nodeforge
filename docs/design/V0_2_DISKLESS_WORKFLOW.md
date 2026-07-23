# NodeForge v0.2 Diskless 从零构建与 PXE 启动流程

状态：v0.2 流程分册。本文从空 catalog 开始，串联本地安装源导入、rootfs 构建、PXE 发布、节点启动、
first-boot、失败恢复和停用的完整操作闭环。总纲与字段所有权见 [`V0_2_DESIGN.md`](V0_2_DESIGN.md)，
initrd 架构见 [`DISKLESS_FINAL.md`](DISKLESS_FINAL.md)，完整命令契约见 [`V0_2_CLI.md`](V0_2_CLI.md)。

本文中的命令只表达推荐顺序，不穷举 flag、输出和错误；与 CLI 分册不一致时必须修正本文，不形成第二套接口。

## 1. 先消除构建环

boot bundle 不能持有 rootfs 引用。否则会形成无法启动的环：Profile 引用 boot bundle -> effective plan
决定 rootfs -> boot bundle 又要求 rootfs 已存在。v0.2 的对象关系固定为：

```text
ISO asset -> InstallSource(local media tree/repositories/software index)
                  -> Install Profile -> Kickstart/Autoinstall
                  -> Diskless Profile build projection

InstallSource + runtime Kernel asset + NodeForge initrd asset
        -> BootBundle（diskless 启动环境，不含 rootfs）

BootBundle + Diskless Profile build projection
        -> rootfs_input_digest
        -> RootfsArtifact(squashfs, derived/cache-only)

Node boot projection（仅 kernel/transport）+ Node apply projection（全部运行根差量）+
Profile rootfs reference + BootBundle revisions + RootfsArtifact digest
        -> DeliveryManifest（per BootSession）
```

InstallSource 是 install/diskless Profile 的共同 OS 来源；Profile 是唯一配置基线。`BootBundle` 是持久
catalog Resource，至少固定 `install_source`、kernel、nodeforge-initrd、arch、
kernel release 和 feature manifest。`RootfsArtifact` 是 builder 派生缓存，不允许人工改内容或由 Profile
直接引用。`DeliveryManifest` 是 session 快照，不写回 desired catalog。

digest 分三层，禁止互相代替：

| digest | 输入 | 用途 |
|---|---|---|
| `desired_plan_digest` | Profile rootfs reference + Node boot/apply projection + resource revisions 的 canonical plan | Node drift、deploy CAS、session desired snapshot |
| `rootfs_input_digest` | Profile canonical build projection；包含共享账号/密码 hash/授权 key，排除全部 Node 输入 | Profile builder cache key |
| `delivery_digest` | desired plan + boot bundle revisions + rootfs content SHA-512 + BootConfig schema | 一次启动的不可变交付身份 |

digest 是规范化输入或字节内容的确定性指纹，通常表示为 `sha256:...`/`sha512:...`；相同输入得到相同值，任一
纳入字段变化都会改变它。它不是加密，也不能从 digest 还原原配置。`rootfs_input_digest` 标识“应当构建什么”，
rootfs content SHA-512 校验“实际构建/下载到了哪些字节”，两者不可互换。

## 2. 阶段 0：服务端准备

前置条件：v0.1 setup 完成，DHCP/TFTP/HTTP 绑定隔离 PXE 网络，时间可靠，asset/repository/catalog/runtime
目录位于本地持久文件系统。执行：

```text
nodeforge preflight diskless-builder
nodeforge status --component dhcp,tftp,http,builder
nodeforge config validate
nodeforge catalog validate
```

`preflight diskless-builder` 必须检查：服务地址是 IPv4 字面地址；PXE interface/address 匹配；TFTP/HTTP 可读；builder
工具、`mksquashfs`、目标发行版包管理器、dracut 与 kernel release 能力可用；磁盘 staging 空间、daemon
文件描述符和内存容量足够；local-only 网络策略可执行。跨架构构建默认拒绝，只有 builder manifest 声明
binfmt/qemu-user 且全部 rootfs-build step 为 cross-safe 时才允许。

## 3. 阶段 1：导入本地 OS 源

```text
nodeforge assets import /srv/iso/Rocky-9.7-x86_64-dvd.iso
nodeforge assets install-source list
nodeforge assets install-source show rocky-9.7-x86_64
nodeforge assets repository validate rocky-9.7-baseos
nodeforge assets install-source software list rocky-9.7-x86_64 --kind environment
nodeforge assets runtime-kernel prepare --source rocky-9.7-x86_64 --release <release> --wait
nodeforge assets runtime-kernel validate <kernel-asset>
```

ISO 导入事务必须产生/验证 ISO asset、media tree、install source、本地 repositories、installer kernel 和
software capability index。diskless runtime kernel 由 `runtime-kernel prepare` 从本地 kernel package 提取，并固定完全匹配的
modules/package closure；不能假设安装器 kernel 可作为最终系统 kernel。diskless builder 不使用公网 mirror、metalink
或运行时 distro update。导入成功不代表
diskless ready；它只建立可重复构建的本地输入。

## 4. 阶段 2：定义 build-time 与 first-boot 定制

`rootfs-build` 用于所有共享节点都应具有、且必须在发布前完成的内容；`first-boot` 用于需要目标运行环境
或节点上下文的 bounded action，力度与 install postprocess 一致，可更新用户、SSH、hosts 和其他系统文件。

```text
nodeforge assets managed-file import motd-v1 --from-file ./motd
nodeforge assets archive import vendor-agent-v1 --from-file ./vendor-agent.tar.bz2
nodeforge assets script import register-service-v1 --from-file ./register-local-service.sh
nodeforge assets provision-bundle create compute-diskless-v1

nodeforge assets provision-bundle item add compute-diskless-v1 steps \
  id=base-tools phase=rootfs-build action=package packages=tmux,nmap idempotency_key=base-tools timeout_s=600 retryable=true
nodeforge assets provision-bundle item add compute-diskless-v1 steps \
  id=motd phase=rootfs-build action=managed-file content_asset=motd-v1 destination=/etc/motd mode=0644 owner=root group=root \
  idempotency_key=motd timeout_s=30 retryable=false
nodeforge assets provision-bundle item add compute-diskless-v1 steps \
  id=vendor-agent phase=first-boot action=archive archive_asset=vendor-agent-v1 idempotency_key=vendor-agent timeout_s=300 retryable=true
nodeforge assets provision-bundle plan compute-diskless-v1 --phase rootfs-build
nodeforge assets provision-bundle plan compute-diskless-v1 --phase first-boot
```

以下共享内容由 Profile target-system/rootfs-build 处理：账号、固定 UID/GID/groups/sudo、password hash、
公共 `/etc/hosts`、sshd policy、Profile SSH client/host 公钥私钥、authorized_keys、ssh_known_hosts、locale/timezone/keyboard。
Profile create/clone 的 rootfs-build preparation 自动生成并固定 client/host keys，把 client public key 和配置的其他
节点/管理公钥追加到 authorized_keys，使同 Profile 节点可相互免密。服务端 typed boot-project 只编译 plan；Node
password、authorized_keys、hosts 等全部 override 由 agent pre-init 在真正 init 前写 overlay upper。mandatory Profile client key 不被标准 Node remove 删除。
同 Profile 节点共享 sshd host keys/fingerprint；Profile/Node effective hosts 的全部 address/names/aliases 与共享 host public key
写入该节点 ssh_known_hosts。Node software 的 repositories/environment/groups/tasks/packages include/exclude 与
service/security runtime override 编译为 immutable `node_apply_projection`，由 agent 在切根后按 pinned local repository
revision/GPG policy 与 exact add/remove package closure 重放；它不改变共享 rootfs。大量节点共用或体积较大的软件差异
建议 clone Profile 烤入新的公共 rootfs，这是启动效率优化，不是 Node override 的语义限制。first-boot 默认按 Profile
fixed bundle 执行；Node 可用 first-boot-only bundle 完整替换自身后处理，其 payload 由 agent pre-init 切根后按
session-pinned AgentPlan 下载校验。

first-boot 适合：需要真实 kernel `/sys` 的本地驱动 finalization、启动后才能生成的节点缓存、受控服务注册、
仅能在运行根中执行的 vendor installer。它不是远程命令、持续配置管理、联网更新或失败修复兜底。

## 5. 阶段 3：构建 NodeForge initrd 与 BootBundle

```text
nodeforge assets nodeforge-initrd config show
nodeforge assets nodeforge-initrd config set http_client=curl overlay=true squashfs=true
nodeforge assets nodeforge-initrd modules-values add <nic-module> loop squashfs overlay
nodeforge assets nodeforge-initrd firmware-values add <required-firmware-asset>
nodeforge assets nodeforge-initrd build --source rocky-9.7-x86_64 --kernel <kernel-asset> --wait
nodeforge assets nodeforge-initrd validate <initrd-asset>

nodeforge assets boot-bundle create rocky-9.7-diskless-x86_64 \
  install_source=rocky-9.7-x86_64 kernel=<kernel-asset> initrd=<initrd-asset>
nodeforge assets boot-bundle validate rocky-9.7-diskless-x86_64
nodeforge assets boot-bundle show rocky-9.7-diskless-x86_64
```

initrd manifest 必须证明包含启动 NIC driver/firmware、DHCP、HTTP、SHA-512、loop、squashfs、tmpfs、overlay、
目标 network renderer handoff 和 `nodeforge-initrd`。BootBundle 校验 kernel release、rootfs 将使用的 modules ABI、
arch/source/repository revision 和 required feature 子集；它此时不要求 rootfs 已存在。

## 6. 阶段 4：创建 Profile 与 Node（保持禁用）

```text
nodeforge profile create compute-diskless --kind diskless --source rocky-9.7-x86_64 \
  diskless.boot_bundle=rocky-9.7-diskless-x86_64 diskless.provision.bundle=compute-diskless-v1
nodeforge profile set compute-diskless diskless.overlay.tmpfs_percent=40 \
  diskless.failure.max_attempts=3 diskless.failure.backoff_seconds=30
nodeforge profile add-values compute-diskless software.packages.include chrony
nodeforge profile add-values compute-diskless system.ssh.root_authorized_keys <controller-public-key>
nodeforge profile item add compute-diskless system.hosts \
  id=controller address=192.168.50.2 names=controller,controller.local

# 从已有 diskless Profile 克隆，在同一事务中修改并构建新 Profile
nodeforge profile clone compute-diskless compute-gpu \
  --set diskless.overlay.tmpfs_percent=50 --build --wait
nodeforge profile show compute-gpu

# 若派生 Profile 要改 software collection，先 clone/修改，最后只构建一次
nodeforge profile clone compute-diskless compute-gpu-tools
nodeforge profile add-values compute-gpu-tools software.packages.include gpu-toolkit
nodeforge profile rootfs build compute-gpu-tools --wait

nodeforge node add c001 mac=52:54:00:12:34:56 arch=x86_64 profile=compute-diskless deploy=false
nodeforge node set c001 pxe.ip_reservation=192.168.50.101 hostname=c001.example.test
nodeforge node set c001 network.mode=static network.interface=eth0 \
  network.address=192.168.50.101 network.prefix_len=24 network.gateway=192.168.50.1
nodeforge node add-values c001 network.dns 192.168.50.2
nodeforge node set c001 overrides.system.ssh.root_password=<node-password>
nodeforge node add-values c001 overrides.system.ssh.root_authorized_keys.add <c001-extra-public-key>
nodeforge node add-values c001 overrides.system.connectivity.ntp_servers.add 192.168.50.2
nodeforge node add-values c001 overrides.software.repositories.add rocky-9-local-updates
nodeforge node add-values c001 overrides.software.packages.include.add node-exporter
nodeforge node set c001 overrides.diskless.provision.bundle=<c001-first-boot-only-bundle>
nodeforge node item add c001 overrides.system.hosts \
  id=c001-extra address=192.168.50.120 names=c001-extra
```

Node 初始必须 `deploy=false`，防止 rootfs 未 ready 时不断产生失败尝试。Profile kind 是创建时 discriminant；
Node 不得 override kind。Node 从 install Profile 切换到 diskless 或反向切换，只允许：`deploy=false`、无 active
session、无待恢复 session；切换后旧 current status 归档，不能与新 kind 合并。

## 7. 阶段 5：编译 build plan

readiness 是只读准入检查，不是“准备动作”：不构建、不改配置、不启用 PXE、不创建 BootSession。
`stage=build` 检查能否开始构建；后面的 `stage=boot` 检查能否开始给节点发 bootfile。失败结果必须给出
check id、稳定 reason 和下一条建议命令。

```text
nodeforge profile effective compute-diskless --section build
nodeforge profile rootfs plan compute-diskless --output json
nodeforge node readiness c001 --stage build
```

`profile rootfs plan` 不要求 rootfs 已存在，输出 `rootfs_input_digest`、cache hit、估算大小、builder capability、
输入 revisions 和排除的 Node override。`node readiness --stage build` 只解析绑定 Profile 并复用其 build 检查；
Node override 不参与 rootfs build，但必须能编译为统一 AgentPlan/`node_apply_projection`；initrd 只交接 plan locator，完整
target-system/software/service/security 差量由 agent pre-init 应用。readiness 必须验证全部 software capability、exact
add/remove package closure、pinned local repository revision/GPG policy、protected package、agent feature 与本地 repository
可达性；Node first-boot bundle 还必须 first-boot-only 且 payload closure/digest/size 可由 session-bound `agent:read`
精确投递，不能退化成按 Node 构建、公网装包或拉取可变任务。
此处必须发现：install-only storage 字段、缺 source/repository capability、跨架构不安全 step、读取/复制
`/var/lib/nodeforge/credentials`、修改只读 lower 或篡改 session handoff 的 step、公网 repository、kernel/modules ABI
不匹配和 bundle revision 漂移。修改用户、密码、SSH、hosts 或其他运行根文件本身不是拒绝理由。

`node effective` 不得把 password hash/token 完整打印到 human 输出；JSON 的 secret-bearing 字段默认 redacted，
只有本机受权的专用 projection preview 能显示 hash，且永不显示 token。

## 8. 阶段 6：从零构建 rootfs

```text
nodeforge profile rootfs build compute-diskless --wait
# 重建并同时生成新的 Profile SSH client/host keys：
nodeforge profile rootfs build compute-diskless --new-ssh-keys --wait
# 自动化需要保证配置仍等于之前 plan 的内容时，额外加：
# --if-input-digest <rootfs_input_digest>
nodeforge profile rootfs status compute-diskless
nodeforge assets rootfs show <rootfs_input_digest>
nodeforge assets rootfs validate <rootfs_input_digest> --deep
```

builder 的固定过程：

1. 对 input digest 获取 build lease；相同输入并发请求 join 同一个 build。
2. 创建私有 staging/mount namespace，固定 install source/repository/asset revisions，关闭公网出口。
3. RHEL/Rocky 用目标版本 `dnf --installroot` 构建基础 root；Ubuntu 用 fixed-revision debootstrap/apt 本地源。
   lorax/livecd 工具只可作为经 adapter 声明的实现，不能默认拿安装 ISO 制作工具代替 rootfs builder。
4. 安装 baseline：systemd/udev、目标 network renderer、iproute、包管理器、SSH（若 policy 启用）、
   nodeforge-agent、与启动 kernel 完全匹配的 `/lib/modules/<release>` 和 firmware。
5. 应用 Profile software/target-system 与 `rootfs-build` items，顺序为 managed-file -> package -> archive -> script；同时把
   first-boot manifest、assets 和完整 package closure 预置到内容寻址目录，但不执行 first-boot。
6. 写入完整共享账号/password hash/Profile SSH client/host keys/authorized_keys/ssh_known_hosts/hosts/sshd policy；
   清除 machine-id、DHCP lease、普通包缓存、临时文件、builder resolv.conf、随机种子和任何 node/token 数据。
7. 检查 `/sbin/init`、agent unit、renderer、shared libraries、modules dependency、UID/GID 冲突、local-only URL、
   world-writable/suid policy 和未声明文件。
8. 用固定排序、时间戳/owner 和 compression 参数运行 `mksquashfs`，得到可复现 squashfs。
9. 计算完整 SHA-512、size/uncompressed estimate，生成 manifest/SBOM/file inventory；unsquashfs 再读验证。
10. 原子发布 object 后再发布 ready manifest，释放 lease；失败只保留有界脱敏日志，staging 进入可审计清理。

`--verify-reproducibility` 不覆盖旧 digest，也不改变 cache identity；它只在相同输入下重新执行并比较输出。若输出 digest 不同，
标记 `builder.non_reproducible` 且不得自动替换 ready artifact。

## 9. 阶段 7：boot readiness 与启用 PXE

```text
nodeforge node readiness c001 --stage boot
nodeforge node boot preview c001
nodeforge node set c001 deploy=true
# 自动化若需确保 readiness 后配置未变化，再加 --if-plan-digest <desired_plan_digest>
nodeforge node status c001
```

boot readiness 是强闸，必须同时满足：rootfs ready/deep validation；kernel/initrd/modules/features 联合兼容；
BootConfig 可渲染；MAC/arch/IP/renderer 一致；有可信内存 inventory 时服务端预检预算；无 quarantine；无 active session；
desired plan 未漂移。普通 `deploy=true` 由服务端原子使用执行时最新 plan；只有自动化要求锁定刚才 readiness 结果时才传
`--if-plan-digest`。设置成功只允许未来 PXE，不主动重启节点。

全新 Node 常常没有可信内存 inventory。此时 boot readiness 返回 `memory=unknown` 和 `required_min_memory_bytes` warning，
允许启用，但 initrd 必须读取实际 `MemAvailable` 做硬闸；不得把 unknown 当作“预算已通过”。

若操作员修改 Profile/Node/bundle/source revision，desired plan 改变：新 DHCP bootfile 立即被 readiness gate 阻止，
旧 active session 按自己的 delivery snapshot 完成；新 rootfs build/validation 完成后才能重新启用。

## 10. 阶段 8：节点 PXE 无盘启动

```text
NIC PXE DHCPDISCOVER
 -> nodeforged 校验唯一 Node/MAC、kind=diskless、deploy、readiness、quarantine
 -> DHCPOFFER/DHCPACK + GRUB UEFI bootfile
 -> TFTP/HTTP 取得 GRUB config、kernel、共享 NodeForge initrd 和 per-session credential.cpio
 -> GRUB 追加两个 initrd；kernel cmdline 只有 node/session/config URL，无 token
 -> initrd 从 capsule 读取 single-purpose config token
 -> 有界重放地获取固定 BootConfig，校验后以 config digest 确认并撤销 token
 -> HEAD/Range 下载 rootfs.part，完整 SHA-512 校验
 -> loop(ro) lower + tmpfs upper/work + overlay merged
 -> 校验 AgentPlan locator/expected digest/size/agent feature 摘要，交接到 /var/lib/nodeforge/agent-handoff.json
 -> pre-switch 检查，move-mount /run，清 config/rootfs-artifact token，保留短时 agent/event token
 -> switch_root 到 nodeforge-agent --pre-init
 -> agent 以 bootstrap 网络从服务端拉取并校验 immutable AgentPlan + 全部 Node payload，写 /run 后清 agent token
 -> agent 应用全部 Node override，成功后 exec /sbin/init；renderer 接管同一 NIC/address
 -> systemd agent unit 上报 diskless.running，从 rootfs Profile payload 或 /run Node payload 执行 effective first-boot，删除 event token
```

服务端只允许一个 `(node_id, active_session)`。同 XID 重传复用同 session；DHCP/TFTP 前缀中、plan 未变且仍在
correlation window 内的新 XID 也只登记 transaction alias。只有 config 阶段后的新 DHCP 启动、窗口超时或其他可验证
新 boot evidence 才能原子 supersede 旧 session、撤销旧 token 后再创建新 session，不能并存。状态始终是一个 tagged value：共享 `boot.*` 后只进入 `diskless.*`，不可能出现
`install.*`。pre-init node-apply 失败进入 `diskless.failed`/quarantine；只有真正 init 后的 first-boot 失败使
`postprocess=degraded`，Node 仍是 `diskless.running`。

## 11. 阶段 9：观测、失败恢复与停用

```text
nodeforge node list --kind diskless
nodeforge node status c001
nodeforge node trace c001 --session <id>
nodeforge node postprocess show c001 --session <id>
nodeforge events list --node c001 --session <id>

nodeforge node set c001 deploy=false                                      # 停用新的 PXE
nodeforge node diskless retry c001                                      # 仅 deploy=true 时清当前 quarantine
# 自动化若需确保 failure 未变化，再加 --if-failure-revision <revision>
nodeforge status --component rootfs-cache
```

- `deploy=false` 只阻止新 PXE，不杀死已经切根或正在下载的 fixed delivery session。
- retry 只清 failure/quarantine gate，不重启、不改 Profile、不创建 install generation。
- daemon 重启后仅在客户端已完整取得 raw token 时用 delivery record + token hash + snapshot refs 恢复同一交付；
  capsule 未交付或中断且客户端无完整 token时旧 session 为 `recovery_incomplete`，不能重建 secret 或重新编译 plan 续跑。
- v0.2 已发布 rootfs 只增不删；status 做容量告警，空间不足时阻止新 build，不自动回收。

## 12. 最小故障注入矩阵

发布前至少覆盖：ISO/repository 缺包；builder 无空间/崩溃/重复构建不一致；kernel/modules ABI mismatch；initrd
缺 NIC firmware/feature；rootfs 内泄露 machine-id/key/token；内存不足；同 XID/新 XID 重传与 config 后并发新 boot；
TFTP/capsule 交付前与交付中断；BootConfig 响应中断、有界重放、过期/跨 node；无效 token 与有效 claim 越权；
Range 200/206/416、ETag 变化、两次完整 hash mismatch；daemon 在 config/download/event
阶段重启；网络 renderer flush 地址；`/run` 未交接；switch_root exec 返回；AgentPlan 过期/跨 node/digest-size 不符/
redirect/path 越权/拉取中断；agent token 预取后未清除；Node repository URL/未 pin capability；
software remove 命中 protected closure；Node first-boot bundle 含 rootfs-build item；Node payload digest/size/feature mismatch；
first-boot action timeout；事件断网；
缓存空间不足；Profile 从 diskless 切 install 时存在 active/recoverable session。每项必须断言稳定 reason、唯一 current state、
secret 不泄露和 v0.1 install 回归不退化。
