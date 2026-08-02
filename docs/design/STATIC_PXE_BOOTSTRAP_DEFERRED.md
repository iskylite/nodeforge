# NodeForge DHCP-less static PXE bootstrap 保留设计

状态：独立保留设计，实现未排期；不属于 v0.4，也不绑定产品版本号或既定 schema/DTO 编号。

本文保存“不通过 DHCP 建立 PXE bootstrap”的设计考量。当前产品以及 v0.4 仍只支持 UEFI GRUB + DHCPv4：
动态 lease 和 `pxe.ip_reservation` 都由 DHCP 建立 Node/MAC/BootSession 关联，initrd 复用已经确认的 lease facts。
本文不得作为当前 `network.bootstrap.*` 字段、BootConfig 新版本、CLI 或 handler 已存在的依据。

BIOS/PXELINUX 是另一项独立保留设计，见
[`BIOS_PXELINUX_DEFERRED.md`](BIOS_PXELINUX_DEFERRED.md)。未来即使二者在同一阶段实施，也必须分别满足 firmware 与
bootstrap authentication 的验收条件，不能用一个功能的测试替代另一个。

## 1. 延后原因

DHCP 当前同时提供地址分配、MAC/arch observation、Node correlation、BootSession 创建时点和 bootfile gate。
DHCP-less static PXE 会失去这条天然入口；仅凭 source IP、URL 中的 Node id 或 opaque path 不能证明机器身份。
在没有固定首次请求协议、防重复/冒认策略、L2 事实和目标网络环境 E2E 前，把它加入版本设计会产生无法安全创建
session/capability 的第二条启动链，因此独立延后。

## 2. 候选范围

未来重新立项时，只讨论“firmware 已预配置静态 bootstrap 网络，NodeForge 如何安全建立一次 boot delivery”。它不自动包含：

- BIOS/PXELINUX；
- target 多 NIC/bond/VLAN 配置，目标 topology 继续由当时的 Node desired plan 管理；
- iPXE、IPv6、NFS root、远程控制或长期 enrollment；
- 使用静态地址绕过 session、capability、digest、readiness 或容量 gate。

候选配置需要表达 bootstrap mode、承载接口、IPv4 address/prefix 和必要 gateway，但字段名、owner 和 schema 编号必须在
重新立项时根据当时模型确定。本文中的概念名称不是预留 PropertySpec 或兼容承诺。

## 3. 首次请求与会话创建不变式

未来方案至少必须同时满足：

1. firmware 使用预配置的 server IP literal 和 node-specific opaque bootstrap locator；locator 只用于路由，不单独构成认证；
2. 首次 GRUB config RRQ/GET 的 TCP/UDP peer source 必须与该 Node 的 desired static bootstrap address 精确一致；
3. 服务端同时使用可获得的 L2/MAC observation、交换机/VLAN 信任边界和 duplicate-IP gate；任何事实冲突 fail closed；
4. 首次合法请求在一个持久事务中创建唯一 BootSession、immutable delivery snapshot 和 credential capsule；
5. 同一请求重传返回同一 snapshot/capsule，竞争请求以 CAS 只允许一个 winner，不能因每次 GET 创建新 session；
6. source mismatch、地址冲突、locator 猜测、过期和重放不得污染其他 Node 的状态，也不得泄露资源是否存在；
7. capability 仍绑定 deployment、Node、session、audience、method/path、digest、expiry 和 replay counter；raw token 不进入
   catalog、URL、cmdline、日志或 preview；
8. `node boot preview` 只能显示模板、binding/readiness 结果和稳定诊断，不显示可使用的 locator/token。

如果目标环境无法提供足够的 source/L2 binding 证据，正确结果是拒绝支持该环境，而不是把 opaque URI 当作身份。

## 4. 与 target topology 的分离

static bootstrap 只决定 firmware/GRUB/config/rootfs 下载前的 transport。安装后或 diskless 最终网络仍由当时版本的 target
topology owner 决定；两者即使 address 相同也不能合并生命周期。

若未来允许 bootstrap→target 切换，必须复用当时已实现的 payload 预取、network transaction、authenticated proof、
rollback 和 init adopt 契约，而不是在 static 路径复制 renderer。bootstrap anchor 只有在 target 已证明并被真正 init 接管后
才能删除；失败必须恢复或保留可诊断的 bootstrap reachability。

## 5. DTO、升级和 CLI 约束

- 只有 initrd 所需 bootstrap shape 确实变化时，才从重新立项时的 BootConfig 基线分配下一唯一版本；不得预占
  BootConfig v4 或假设 v0.4 之后没有其他 DTO 变化。
- target topology shape 不变时不得顺带升级 AgentPlan；变化时同样从当时基线分配版本。
- 采用当时版本规定的 fresh replacement 或显式 migration 策略；本文不承诺跨 deployment active session 延续。
- 候选 CLI 必须由 typed registry/command spec 生成，并完整覆盖 show/help/parser/API/digest/readiness；本文不冻结具体命令。
- 当前 v0.4 及更早不得出现 `network.bootstrap.mode=static`、static bootstrap handler 或仅有 enum 的空实现。

## 6. 重新立项完成闸

- DHCP 路径全部回归，不因新增 static 分支改变 reservation、lease correlation 或 UEFI GRUB 行为；
- 首次请求、合法重传、并发 winner、daemon restart、expiry 和 recovery 均能证明唯一 session/capsule；
- source-IP mismatch、duplicate IP、错误 MAC/L2 observation、locator 枚举和跨 Node 重放稳定拒绝；
- bootstrap/target 地址相同与不同、跨子网 gateway、网络切换失败和 rollback/adopt 均有目标环境 E2E；
- schema/DTO/feature/readiness/CLI 使用同一 owner，旧 consumer fail closed，不存在双 renderer 或隐式 fallback；
- 日志、preview、kernel cmdline、URL 和持久文件均无 raw capability 泄漏；
- 未获得上述证据前，状态必须保持“独立保留设计”，不能进入版本完成闸。
