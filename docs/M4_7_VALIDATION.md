# M4.7 路径、模型存储与 setup 验证记录

验证日期：2026-07-17（Asia/Shanghai）。实现基线：M4.6 commit `b4b5bd6` 之后。

## 设计复核结论

M4.7 保留 runtime Paths、config/catalog ownership、manifest-last transaction 和单一 setup 入口四个核心方向，
并修正三处不可安全照搬的假设：

1. 可执行文件发现使用操作系统 API 与 canonical real path，不把 `/proc/self/exe` 作为跨平台接口。
2. 新根在 marker 创建前只能进入 setup candidate 模式；普通命令绝不接受未标记布局。
3. “默认路由网卡就是 PXE 网卡”在多网卡服务器上不成立。setup 使用显式网络 flags 和可见的隔离实验网默认值，
   不宣称静默自动检测。

## 已实现契约

- schema 2 `config.json` 只序列化启动/站点字段；distro/profile/node/provisioning bundle 归 Catalog。
- Catalog 由 manifest 和 8 个 entity files 组成；每次写入使用 journal、stage、entity rename、manifest-last。
- loader 重算 transaction id 和 entity SHA-256，拒绝缺文件、篡改、无证据 mixed layout。
- schema 1 config + monolithic catalog 可幂等迁移；config 已发布后的崩溃由 migration marker 续跑清理。
- `node add/set/remove` 与 `profile set/unset` 写 Catalog，不改 config；在线 config PATCH 稳定返回
  `409 config.offline_only`。
- setup 验证同 bundle 的两个二进制及 build provenance，最后创建 `.nodeforge-root`。
- reset 先恢复事务，生成带 SHA-256 manifest 的 state 备份；破坏性非交互命令要求 `--yes`。
- reset 检测到 loopback daemon 可达时 fail closed，要求先停止服务；`reset-all` 同时备份旧 config。
- 动态 systemd unit 不传 `--config`；install 失败会恢复旧 link 及 enabled/active 状态。

## 自动验证

```bash
zig build test --summary all
zig build -Doptimize=ReleaseSafe
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe
```

测试必须确认：

- 单元、CLI、setup 与 HTTP 合约通过（M4.7 当时基线 202/202；M4.8 与 ISO distro 自动派生后增至 224/224，以 `zig build test --summary all` 为准）；
- host ReleaseSafe 与 aarch64-linux-gnu ReleaseSafe 构建通过；
- `tests/setup.sh` 覆盖 custom root、成对 bundle、schema/manifest、systemd render、reset backup、partial bundle
  fail-closed、legacy migration 和 migration resume；
- catalog 单元测试覆盖 after-journal、after-entities、after-manifest 三个崩溃点以及 digest tamper；
- `git diff --check` 无 whitespace 错误。

## Rocky Linux 实机验收（提交后执行）

以下操作会写 `/etc/systemd/system` 并启动 DHCP/TFTP/HTTP，只能在隔离 PXE 网的 root 环境执行：

```bash
./nodeforge setup --install-root /srv/nodeforge --non-interactive --yes \
  --bind-interface enp1s0 --server-ip 192.168.50.1 \
  --subnet 192.168.50.0/24 --pool-start 192.168.50.100 --pool-end 192.168.50.200
/srv/nodeforge/bin/nodeforge setup --generate-systemd --install --non-interactive --yes
systemctl is-enabled nodeforged.service
systemctl is-active nodeforged.service
curl --fail http://127.0.0.1:18080/healthz
```

随后注入一次坏 unit 或健康检查失败，确认旧 unit、enabled/active 状态恢复且诊断备份保留；再检查
config/catalog 文件为 0600、私有目录为 0700、公开安装目录为 0750。没有这份实机证据前，只能声称代码与
自动合约通过，不能声称 Rocky 生产部署已经验收。
