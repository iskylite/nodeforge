#!/usr/bin/env bash
# v0.4 logical capacity workload harness.
#
# Runs ONLY the dedicated workload unit module (not the full zig build test suite):
#   zig build test-v0.4-capacity
#
# Workload coverage (logical clients/sessions, no real PXE VMs required):
#   - 256 diskless active wave + capacity.exhausted
#   - 3×256 mixed: 128 install first-boot + 128 diskless per wave, three waves
#   - 512: diskless-only, install-only, and 256+256 mixed
#   - 1024 pressure wave
#   - external AgentPlan files: large bodies not in index; reload metrics printed
#   - plan digest content verification (tamper rejected)
#   - first-boot 256 wave + per-node terminal reuse across generations
#   - terminal transition rolls back capability when persist fails
#
# Harness prints [capacity-evidence] lines (index_bytes, reload_ns). Full multi-hour
# RSS/FD production soak remains ENV-V04-PRODUCTION-SCALE; logical wave admission
# and checkpoint recovery are required publish evidence here.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

echo "=== v0.4 capacity workload (logical waves only) ==="
zig build test-v0.4-capacity --summary all
echo "=== v0.4 capacity workload PASS ==="
