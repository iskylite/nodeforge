#!/bin/sh
# v0.4.1 staging session 契约闸（CLI 表面 + 负向断言 + 单元测试）。
#
# 由 `zig build test-v0.4.1-staging` 调用，入参：cli daemon agent initrd。
# 断言：
#   - staging enter/exec/kernels 子命令存在于 --help-full
#   - --kernel-release flag 注册于 rootfs build
#   - cgroup 限额 flag 注册于 staging enter/exec
#   - 二进制不含 pivot_root / Docker / Podman / 顶层 nodeforge rootfs
#   - staging_session + staging_kernel_import Zig 单元测试通过
set -eu

cli=$1
daemon=$2
agent=$3
initrd=$4
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT HUP INT TERM

bundle=$tmp/bundle
mkdir -p "$bundle"
cp "$cli" "$bundle/nodeforge"
cp "$daemon" "$bundle/nodeforged"
cp "$initrd" "$bundle/nodeforge-initrd"
cp "$agent" "$bundle/nodeforge-agent"
run_cli=$bundle/nodeforge
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

echo "=== v0.4.1 staging session contract gate ==="

# ── 1. 初始化 install root ──────────────────────────────────
install=$tmp/install
$run_cli setup --install-root "$install" --non-interactive --yes >"$tmp/setup.json"

# ── 2. CLI 表面断言 ──────────────────────────────────────────
help=$tmp/help
$run_cli --install-root "$install" profile rootfs staging enter --help-full >"$help" 2>&1 || true
grep -Fq 'enter' "$help" || { echo "FAIL: staging enter --help-full empty" >&2; exit 1; }

$run_cli --install-root "$install" profile rootfs staging exec --help-full >>"$help" 2>&1 || true
grep -Fq 'exec' "$help" || { echo "FAIL: staging exec --help-full empty" >&2; exit 1; }

$run_cli --install-root "$install" profile rootfs staging kernels --help-full >>"$help" 2>&1 || true
grep -Fq 'kernels' "$help" || { echo "FAIL: staging kernels --help-full empty" >&2; exit 1; }
echo "PASS: staging enter/exec/kernels subcommands present"

# --kernel-release flag 注册于 rootfs build
$run_cli --install-root "$install" profile rootfs build --help-full >"$tmp/build_help" 2>&1 || true
grep -Fq 'kernel-release' "$tmp/build_help" || { echo "FAIL: --kernel-release not in rootfs build help" >&2; exit 1; }
echo "PASS: --kernel-release flag registered"

# cgroup 限额 flag 注册于 staging enter/exec（从二进制字符串验证）
strings "$bundle/nodeforge" | grep -Fq 'memory-max' || { echo "FAIL: --memory-max not in CLI binary" >&2; exit 1; }
strings "$bundle/nodeforge" | grep -Fq 'pids-max' || { echo "FAIL: --pids-max not in CLI binary" >&2; exit 1; }
echo "PASS: cgroup limit flags registered"

# --script flag 注册于 staging exec
$run_cli --install-root "$install" profile rootfs staging exec --help-full >"$tmp/exec_help" 2>&1 || true
grep -Fq 'script' "$tmp/exec_help" || { echo "FAIL: --script not in staging exec help" >&2; exit 1; }
echo "PASS: --script flag registered"

# ── 3. 负向二进制契约 ────────────────────────────────────────
# pivot_root 系统调用不得出现在产品二进制中（设计 §3.3 切根仅 chroot）
# 注：源码注释中提及 pivot_root 是允许的，只检查实际函数调用
for binary in "$bundle/nodeforged"; do
    if strings "$binary" | grep -E 'pivot_root\(|SYS_pivot_root|linux\.pivot_root' >/dev/null; then
        echo "FAIL: pivot_root system call found in $binary" >&2
        exit 1
    fi
done
echo "PASS: no pivot_root system call in daemon binary"

# Docker / Podman 不得出现
for binary in "$bundle/nodeforged" "$bundle/nodeforge"; do
    if strings "$binary" | grep -iE "(docker|podman)" >/dev/null; then
        echo "FAIL: docker/podman reference found in $binary" >&2
        exit 1
    fi
done
echo "PASS: no docker/podman references"

# 顶层 `nodeforge rootfs` 不得存在（设计 §3.5 仅 profile rootfs 资源树）
if "$run_cli" --install-root "$install" rootfs 2>&1 | grep -iE "(unknown|unrecognized|usage|error)" >/dev/null; then
    echo "PASS: no top-level 'nodeforge rootfs' command"
else
    echo "FAIL: top-level 'nodeforge rootfs' command unexpectedly exists" >&2
    exit 1
fi

# ── 4. Zig 单元测试 ──────────────────────────────────────────
echo "--- running staging session + kernel import unit tests ---"
cd "$repo_root"
zig build test-v0.4.1-staging-unit --summary all
echo "PASS: staging session unit tests"

echo "=== v0.4.1 staging session contract gate PASS ==="
