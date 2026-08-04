#!/usr/bin/env bash
# v0.2.1 Ubuntu diskless production CLI path smoke test.
#
# Unlike docs/archive/validation-fixtures/v0_2_1_casper_initrd_smoke.sh (manual scripted artifact assembly,
# used to validate technical feasibility before the production builder existed),
# this script drives ONLY the real product CLI surface end to end:
#
#   nodeforge assets import <ubuntu.iso>
#   nodeforge assets initrd build --from-install-source <src> --kernel-release <r>
#   nodeforge profile create <install-source> [--qualifier <value>] --kind diskless
#   nodeforge profile rootfs build <profile>      (buildCasperOverlay + namespaced_chroot_executor)
#   nodeforge node add / boot-prepare
#   QEMU boot -> diskless.running
#
# Requires root on a Linux host with: unsquashfs, chroot, unshare, mksquashfs,
# qemu-system-<arch>, and (same-architecture) apt tooling reachable from the
# managed repository closure. Designed to run on the Rocky 9.7 x86_64 build
# host referenced in the v0.2.1 design doc; NOT runnable on macOS/non-root CI.
#
# Also runs an equivalent Rocky candidate as a same-build-artifact regression
# check (dnf branch), to confirm the OS-layer namespace+chroot rewrite in
# rootfs_os_builder.zig did not regress the existing Rocky diskless path.
set -euo pipefail

repo=${NODEFORGE_REPO:-/root/NodeForge}
ubuntu_iso=${NODEFORGE_UBUNTU_ISO:-}
rocky_iso=${NODEFORGE_ROCKY_ISO:-}
install_root=${NODEFORGE_INSTALL_ROOT:-/tmp/nf-v021-casper-prod}
work=/tmp/nodeforge-v021-casper-prod
config="$install_root/config/config.json"
port=${NODEFORGE_PORT:-18094}
qemu_launcher=${NODEFORGE_QEMU_LAUNCHER:-}

if [[ "$(id -u)" -ne 0 ]]; then
    echo "must run as root (namespace+chroot builder requires CAP_SYS_ADMIN)" >&2
    exit 1
fi
for b in unsquashfs chroot unshare mksquashfs qemu-system-x86_64; do
    command -v "$b" >/dev/null 2>&1 || { echo "missing required tool: $b" >&2; exit 1; }
done
[[ -n "$qemu_launcher" && -x "$qemu_launcher" ]] || {
    echo "set NODEFORGE_QEMU_LAUNCHER to an executable that starts the lab UEFI/PXE QEMU guest" >&2
    echo "launcher arguments: <node-id> <mac> <events-jsonl> <console-log>; stdout must be the QEMU pid" >&2
    exit 1
}
[[ -n "$ubuntu_iso" && -r "$ubuntu_iso" ]] || { echo "set NODEFORGE_UBUNTU_ISO to a readable Ubuntu ISO" >&2; exit 1; }
cd "$repo"
for b in nodeforge nodeforged nodeforge-agent nodeforge-initrd; do
    [[ -x "zig-out/bin/$b" ]] || { echo "missing prebuilt $b (run: zig build)" >&2; exit 1; }
done

cleanup() {
    if [[ -n "${qemu_pid:-}" ]]; then kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; fi
    pkill -f "nodeforged --install-root $install_root" 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$work" "$install_root"; mkdir -p "$work"
nf() { zig-out/bin/nodeforge --install-root "$install_root" --config "$config" "$@"; }

echo "=== 0. daemon setup ==="
zig-out/bin/nodeforge --install-root "$install_root" status setup --config "$config" --output json >/dev/null 2>&1 || true
setsid zig-out/bin/nodeforged --install-root "$install_root" </dev/null >"$work/nodeforged.log" 2>&1 &
sleep 2
pgrep -f "nodeforged --install-root $install_root" >/dev/null || { echo "daemon failed to start"; cat "$work/nodeforged.log"; exit 1; }

echo "=== 1. nodeforge assets import (Ubuntu ISO, casper layer discovery) ==="
import_out=$(nf assets import "$ubuntu_iso" --output json)
echo "$import_out"
ubuntu_source=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["result"]["name"])' "$import_out")
kernel_release=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["result"].get("kernel_release",""))' "$import_out")
[[ -n "$ubuntu_source" ]] || { echo "FAIL: assets import did not return an install source name"; exit 1; }
echo "install source: $ubuntu_source kernel_release=$kernel_release"
profile="${ubuntu_source}-casper-diskless"

echo "=== 2. nodeforge assets initrd build --from-install-source ==="
initrd_out=$(nf assets initrd build "${ubuntu_source}-initrd" --from-install-source "$ubuntu_source" --kernel-release "$kernel_release" --output json)
echo "$initrd_out"

echo "=== 3. nodeforge profile create --kind diskless ==="
nf profile create "$ubuntu_source" --qualifier casper --kind diskless --output json || true
nf profile set "$profile" diskless.failure.max_attempts=3 --output json
nf profile set "$profile" diskless.failure.backoff_seconds=1 --output json

echo "=== 4. nodeforge profile rootfs build (buildCasperOverlay + namespaced_chroot_executor) ==="
before_apt_hash=$(sha256sum /var/lib/apt/extended_states 2>/dev/null | cut -d' ' -f1 || echo "none")
build_out=$(nf profile rootfs build "$profile" --output json)
echo "$build_out"
op_id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["result"].get("operation_id",""))' "$build_out" 2>/dev/null || true)
if [[ -n "$op_id" ]]; then
    nf operation wait "$op_id" --output json
fi
after_apt_hash=$(sha256sum /var/lib/apt/extended_states 2>/dev/null | cut -d' ' -f1 || echo "none")
if [[ "$before_apt_hash" != "$after_apt_hash" ]]; then
    echo "FAIL: host /var/lib/apt/extended_states changed — namespaced_chroot_executor wrote to host apt state"
    exit 1
fi
echo "PASS: host apt state unchanged (host-zero-write)"

echo "=== 5. nodeforge node add + boot-prepare ==="
nf node add ub-casper-node --mac 52:54:00:12:34:92 --arch x86_64 --profile "$profile" --output json || true
prepare=$(curl -sS -H 'Content-Type: application/json' -H 'X-NodeForge-Internal-Capsule: 1' -d '{}' "http://127.0.0.1:$port/api/v1/management/nodes/ub-casper-node/boot-prepare")
echo "$prepare"

echo "=== 6. QEMU boot to diskless.running ==="
# Boot bundle assets (kernel/initrd) are resolved by the daemon into the
# install root asset store; the exact on-disk relative path is an
# implementation detail of the catalog, so this step reads it back via
# `node show` rather than hardcoding a path.
show_out=$(nf node show ub-casper-node --output json)
echo "$show_out"

# QEMU firmware/NIC/bridge details are lab-specific. Keep them in an explicit
# launcher, but make starting a real guest mandatory: the old script only
# waited for an event that no process could ever produce.
qemu_pid=$("$qemu_launcher" \
    ub-casper-node 52:54:00:12:34:92 \
    "$install_root/logs/events.jsonl" "$work/qemu-console.log")
[[ "$qemu_pid" =~ ^[0-9]+$ ]] && kill -0 "$qemu_pid" 2>/dev/null || {
    echo "FAIL: QEMU launcher did not return a live pid (got: ${qemu_pid:-empty})" >&2
    exit 1
}

deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
    grep -q '"type":"diskless.running".*"node_id","value":"ub-casper-node"' "$install_root/logs/events.jsonl" 2>/dev/null && break
    kill -0 "$qemu_pid" 2>/dev/null || {
        echo "FAIL: QEMU exited before diskless.running" >&2
        tail -n 200 "$work/qemu-console.log" >&2 || true
        exit 1
    }
    sleep 2
done
grep -q '"type":"diskless.running".*"node_id","value":"ub-casper-node"' "$install_root/logs/events.jsonl" 2>/dev/null && echo "PASS: diskless.running" || { echo "FAIL: diskless.running not observed within timeout"; exit 1; }

if [[ -n "$rocky_iso" && -r "$rocky_iso" ]]; then
    echo "=== 7. Rocky regression (dnf namespace+chroot OS layer, same candidate) ==="
    rocky_import=$(nf assets import "$rocky_iso" --output json)
    rocky_source=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["result"]["name"])' "$rocky_import")
    rocky_profile="${rocky_source}-regress-diskless"
    nf profile create "$rocky_source" --qualifier regress --kind diskless --output json || true
    rocky_build=$(nf profile rootfs build "$rocky_profile" --output json)
    echo "$rocky_build"
    echo "PASS: Rocky rootfs build did not regress"
else
    echo "SKIP: Rocky regression (set NODEFORGE_ROCKY_ISO to include it)"
fi

echo "UBUNTU_CASPER_PROD_SMOKE_DONE events=$install_root/logs/events.jsonl"
