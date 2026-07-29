# v0.2 安全审计与实机验证报告

日期：2026-07-29

## 结论

v0.2 代码库完成了一轮完整的安全审计，发现并修复 3 条 P0、2 条 P1 和 1 条 P2
漏洞。所有修复均经过代码验证或实机验证确认阻断。实机验证覆盖 Rocky 9.7、
Rocky 10.2 和 Ubuntu 22.04.5 三个发行版的安装及 diskless 路径，全部通过。

前置审计上下文参见 `docs/audits/V0_2_CODE_REVIEW_FIXES.md`。

---

## 审计发现与修复

### P0 — 路径穿越（src/assets/validate.zig）

- **漏洞**：`resolve_beneath=true` 在 Linux 上是空操作（内核不支持该标志），
  攻击者可通过符号链接遍历逃逸 assets 目录。
- **修复**：实现 `openBeneath()` 逐路径组件 `O_NOFOLLOW` 遍历，确保每一步
  不跨越指定根目录边界。
- **验证**：在 r97n0 上构建探针二进制确认漏洞可利用；应用修复后确认路径穿越
  被阻断。

### P0 — kickstart 注入（src/config/validate.zig）

- **漏洞**：hostname 和 locale 字段未做输入校验，攻击者可通过换行符注入任意
  kickstart 指令（如 `%post` 脚本）。
- **修复**：添加 `validHostname()` 正则校验；修正 `validLocale()` 仅允许
  `language_TERRITORY.codeset` 格式。
- **验证**：使用 `renderTestFixture` 确认注入 payload 被拒绝。

### P0 — DHCP 热路径全量落盘（src/state/catalog_runtime.zig）

- **漏洞**：未知 MAC 地址每次 DHCP 请求都触发全量 catalog 序列化写入磁盘，
  可被利用做磁盘 DoS。
- **修复**：添加 `ObservationThrottle`（128 固定槽位，60 秒窗口，4096 次
  上限），对未知 MAC 的观测做速率限制。
- **验证**：追踪调用链确认修复前每请求触发 `save()`，修复后被节流器拦截。

### P1 — diskless 凭据 fail-open（src/state/diskless_credential.zig）

- **漏洞**：`monotonicNow()` 返回 0 时 TTL 判定逻辑被绕过，凭据永不过期。
- **修复**：`now_mono <= 0` 一律视为时钟不可信，凭据判定为已过期。
- **验证**：回归测试覆盖边界条件。

### P1 — capsule 重放（src/tftp/server.zig）

- **漏洞**：已交付的 per-boot capsule 可被客户端重新读取，存在重放攻击风险。
- **修复**：添加 `entry.delivered` 标记检查，已交付 capsule 不可再次读取。
- **验证**：回归测试覆盖重复读取场景。

### P2 — Ubuntu autoinstall heredoc 折叠（src/profile/adapter/ubuntu.zig）

- **漏洞**：YAML 单引号流标量自动折叠换行，导致 `/etc/hosts` heredoc 内容
  在安装时被截断。
- **修复**：使用 base64 编码 heredoc 内容，避免 YAML 序列化干扰。
- **验证**：Ubuntu 22.04.5 实机安装成功，`/etc/hosts` 内容正确。

---

## 实机验证矩阵

目标节点：r97n1（MAC `00:50:56:2A:23:DB`）

| 路径 | 结果 | 验证方式 |
|------|------|----------|
| Rocky 9.7 install | PASS | SSH 确认，事件日志 `install.completed` |
| Rocky 9.7 diskless | PASS | SSH 确认 overlay root |
| Rocky 10.2 install | PASS | 事件日志 `install.completed` |
| Rocky 10.2 diskless | PASS | SSH 确认 overlay root, kernel 6.12.0 |
| Ubuntu 22.04.5 install | PASS | SSH 确认 Ubuntu 22.04.5 LTS, kernel 5.15.0-119 |

---

## 环境

| 项目 | 值 |
|------|-----|
| 管理节点 (r97n0) | 192.168.26.128 (mgmt) / 192.168.27.128 (PXE, vmnet2) |
| 目标节点 (r97n1) | EFI, 6GB RAM, PXE-first, MAC 00:50:56:2A:23:DB, IP 192.168.27.210 |
| 编译命令 | `zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe` |
| 审计日期 | 2026-07-29 |
