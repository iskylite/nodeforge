#!/usr/bin/env bash
set -euo pipefail
repo=/root/NodeForge
work=/tmp/nodeforge-v021-mkinit2
install_root=/tmp/nf-ub2
node=ub-mkinit2-node
profile=ub-mkinit2
KREL="5.15.0-186-generic"
config="$install_root/config/config.json"

cleanup() { [[ -n "${qemu_pid:-}" ]] && { kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; }; }
trap cleanup EXIT
cd "$repo"

echo "=== rootfs size: $(du -h "$work/rootfs.squashfs" | cut -f1) ==="
echo "=== initrd size: $(du -h "$work/initramfs.img" | cut -f1) ==="
echo "=== kernel: vmlinuz-$KREL ==="

# Ensure assets in place
mkdir -p "$install_root/assets/boot" "$install_root/assets/initrd-ubuntu" "$install_root/assets/rootfs-ubuntu"
cp "$work/vmlinuz-$KREL" "$install_root/assets/boot/vmlinuz-$KREL"
cp "$work/initramfs.img" "$install_root/assets/initrd-ubuntu/ub-mkinit2-initrd"
cp "$work/rootfs.squashfs" "$install_root/assets/rootfs-ubuntu/ub-mkinit2-rootfs"

# Start daemon
pkill -9 -f "nodeforged --install-root $install_root" 2>/dev/null || true
sleep 1
ip addr add 10.0.2.2/32 dev lo 2>/dev/null || true
setsid zig-out/bin/nodeforged --install-root "$install_root" </dev/null >"$work/nodeforged.log" 2>&1 &
sleep 2
pgrep -f "nodeforged --install-root $install_root" >/dev/null || { echo "daemon failed"; cat "$work/nodeforged.log"; exit 1; }
echo "daemon started"

# Register rootfs
zig-out/bin/nodeforge --install-root "$install_root" profile rootfs register "$profile" --path "$work/rootfs.squashfs" --config "$config" --output json >/dev/null 2>&1 || true

# Prepare boot
prepare=$(zig-out/bin/nodeforge --install-root "$install_root" node boot-prepare "$node" --config "$config" --output json)
python3 - "$prepare" "$work/initrd-root/capsule" <<'PY'
import json, pathlib, sys
r = json.loads(sys.argv[1])["result"]
c = pathlib.Path(sys.argv[2])
for n in ("config","rootfs","agent","event"): (c/f"{n}.token").write_text(r[f"{n}_token"])
(c/"session").write_text(r["session_id"]); (c/"config_url").write_text(r["config_url"])
PY
session=$(cat "$work/initrd-root/capsule/session")
config_url=$(cat "$work/initrd-root/capsule/config_url")
rm "$work/initrd-root/capsule/session" "$work/initrd-root/capsule/config_url"

# Repack initrd
cd "$work/initrd-root"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 >"$work/initramfs-final.img"
cd "$repo"
echo "final initramfs: $(du -h "$work/initramfs-final.img" | cut -f1)"

# QEMU boot
echo "=== QEMU boot ==="
/usr/libexec/qemu-kvm -cpu max -M virt -m 3072 \
    -kernel "$work/vmlinuz-$KREL" -initrd "$work/initramfs-final.img" \
    -append "nodeforge.config_url=$config_url nodeforge.session=$session nodeforge.node=$node console=ttyAMA0" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -nographic -no-reboot >"$work/console.log" 2>&1 &
qemu_pid=$!
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
    if grep -q "NODEFORGE_UBUNTU_MKINIT2_VALIDATION_DONE" "$work/console.log" 2>/dev/null; then break; fi
    kill -0 "$qemu_pid" 2>/dev/null || break
    sleep 1
done
kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; qemu_pid=

echo "=== console tail ==="
tail -40 "$work/console.log"
echo ""
echo "=== assertions ==="
grep -q "NODEFORGE_UBUNTU_MKINIT2_VALIDATION_DONE" "$work/console.log" && echo "PASS: validation done" || echo "FAIL: validation done"
grep -q '"type":"diskless.running"' "$install_root/logs/events.jsonl" && echo "PASS: diskless.running" || echo "FAIL: diskless.running"
grep -qiE "Ubuntu|switch_root|Reached target" "$work/console.log" && echo "PASS: ubuntu boot evidence" || echo "FAIL: ubuntu boot evidence"
echo "MKINIT2_QEMU_DONE"
