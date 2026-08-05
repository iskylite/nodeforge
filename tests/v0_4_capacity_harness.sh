#!/usr/bin/env bash
# v0.4 逻辑容量 workload harness 入口。
#
# 仅运行专用 workload 单测模块（非整仓 `zig build test`）：
#   zig build test-v0.4-capacity
#
# Workload 覆盖（逻辑 client/session，不要求真实 PXE VM）：
#   - 256 diskless 活跃波次 + capacity.exhausted
#   - 3×256 混合：每波 128 install first-boot + 128 diskless，共三波
#   - 512：diskless-only / install-only / 256+256 混合
#   - 1024 压力波次
#   - 外置 AgentPlan：大正文不进索引；打印 reload 指标
#   - plan digest 内容校验（篡改拒绝）
#   - first-boot 256 波次 + 同 node 跨 generation 终态复用
#   - 终态迁移在 persist 失败时回滚 capability
#
# harness 打印 [capacity-evidence] 行（index_bytes、reload 等）。
# 多小时 RSS/FD 生产浸泡仍属 ENV-V04-PRODUCTION-SCALE；
# 逻辑波次准入与 checkpoint 恢复是此处的发布证据。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

echo "=== v0.4 capacity workload (logical waves only) ==="
zig build test-v0.4-capacity --summary all
echo "=== v0.4 capacity workload PASS ==="
