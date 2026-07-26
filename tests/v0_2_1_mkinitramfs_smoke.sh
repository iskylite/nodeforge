#!/usr/bin/env bash
# v0.2.1 mkinitramfs approach smoke test.
#
# Tests building initrd from rootfs via chroot mkinitramfs (NOT casper initrd reuse).
#   - kernel: from rootfs /boot/vmlinuz-<KREL> (installed via apt install linux-image-generic)
#   - initrd: chroot rootfs mkinitramfs -o initrd.img <KREL>
#   - rootfs: Ubuntu casper squashfs 3-layer overlay (same as casper approach)
#
# This is a COMPARISON test to evaluate whether "from rootfs mkinitramfs" can
# fully support initrd construction vs the "casper initrd reuse" approach.
set -euo pipefail

repo=${NODEFORGE_REPO:-/root/NodeForge}
iso=${NODEFORGE_UBUNTU_ISO:-/root/ubuntu-22.04.5-live-server-arm64.iso}
install_root=${NODEFORGE_UB_INSTALL_ROOT:-/tmp/nf-ub2}
work=/tmp/nodeforge-v021-mkinit
port=18094
node=ub-mkinit-node
profile=ub-mkinit

cleanup() {
    if [[ -n "${qemu_pid:-}" ]]; then kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
rm -rf "$work"; mkdir -p "$work"
cd "$repo"
for b in nodeforge nodeforged nodeforge-agent nodeforge-initrd; do
    [[ -x "zig-out/bin/$b" ]] || { echo "missing prebuilt $b" >&2; exit 1; }
done
[[ -r "$iso" ]] || { echo "missing ISO $iso" >&2; exit 1; }

# ============================================================
# 1. Build rootfs from casper squashfs 3-layer overlay
# ============================================================
echo "=== 1. Build rootfs from casper squashfs ==="
m=/tmp/ub-mnt-$$; mkdir -p "$m"; mount -o loop,ro "$iso" "$m"
unsquashfs -d "$work/rootfs" "$m/casper/ubuntu-server-minimal.squashfs" >/dev/null
unsquashfs -d "$work/rootfs" -f "$m/casper/ubuntu-server-minimal.ubuntu-server.squashfs" >/dev/null || true
unsquashfs -d "$work/rootfs" -f "$m/casper/ubuntu-server-minimal.ubuntu-server.installer.squashfs" >/dev/null || true

# Inject nodeforge-agent + firstboot service
install -m 0755 zig-out/bin/nodeforge-agent "$work/rootfs/usr/sbin/nodeforge-agent"
install -D -m 0644 packaging/systemd/nodeforge-firstboot.service "$work/rootfs/etc/systemd/system/nodeforge-firstboot.service"
mkdir -p "$work/rootfs/etc/systemd/system/multi-user.target.wants"
ln -sfn ../nodeforge-firstboot.service "$work/rootfs/etc/systemd/system/multi-user.target.wants/nodeforge-firstboot.service"
mkdir -p "$work/rootfs/etc/systemd/system/nodeforge-firstboot.service.d"
printf '%s\n' \
    '[Service]' \
    'ExecStartPost=/usr/sbin/nodeforge-agent' \
    "ExecStartPost=/bin/sh -c 'cat /var/lib/nodeforge/firstboot-journal.json /var/lib/nodeforge/firstboot.log > /dev/console; echo NODEFORGE_UBUNTU_MKINIT_VALIDATION_DONE > /dev/console'" \
    >"$work/rootfs/etc/systemd/system/nodeforge-firstboot.service.d/validation.conf"
echo "rootfs built (before mksquashfs)"

# ============================================================
# 2. Install linux-image-generic in chroot (populate /lib/modules)
# ============================================================
echo "=== 2. Install linux-image-generic in chroot ==="
mount -t proc none "$work/rootfs/proc" 2>/dev/null || true
mount -t sysfs none "$work/rootfs/sys" 2>/dev/null || true
mount --bind /dev "$work/rootfs/dev" 2>/dev/null || true
mount --bind /dev/pts "$work/rootfs/dev/pts" 2>/dev/null || true
cp /etc/resolv.conf "$work/rootfs/etc/resolv.conf"

chroot "$work/rootfs" /bin/bash -c "
    apt-get update 2>&1 | tail -3
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends linux-image-generic 2>&1 | tail -10
"

KREL=$(ls "$work/rootfs/lib/modules/")
echo "=== Installed kernel release: $KREL ==="
echo "vmlinuz: $(ls "$work/rootfs/boot/vmlinuz-"*)"
echo "module count: $(find "$work/rootfs/lib/modules/$KREL" -name '*.ko' | wc -l)"

# Unmount chroot mounts
umount "$work/rootfs/dev/pts" 2>/dev/null || true
umount "$work/rootfs/dev" 2>/dev/null || true
umount "$work/rootfs/sys" 2>/dev/null || true
umount "$work/rootfs/proc" 2>/dev/null || true

# Now mksquashfs the rootfs (with kernel modules included)
mksquashfs "$work/rootfs" "$work/rootfs.squashfs" -noappend -comp zstd >/dev/null
echo "rootfs.squashfs: $(du -h "$work/rootfs.squashfs" | cut -f1)"

# Extract vmlinuz from rootfs
cp "$work/rootfs/boot/vmlinuz-$KREL" "$work/vmlinuz-$KREL"
echo "kernel: vmlinuz-$KREL"

# ============================================================
# 3. Build initrd via chroot mkinitramfs
# ============================================================
echo "=== 3. Build initrd via mkinitramfs ==="
# Re-mount for chroot
mount -t proc none "$work/rootfs/proc" 2>/dev/null || true
mount -t sysfs none "$work/rootfs/sys" 2>/dev/null || true
mount --bind /dev "$work/rootfs/dev" 2>/dev/null || true
mount --bind /dev/pts "$work/rootfs/dev/pts" 2>/dev/null || true

chroot "$work/rootfs" /usr/sbin/mkinitramfs -o /tmp/mkinitrd-output.img "$KREL" 2>&1 | tail -20
cp "$work/rootfs/tmp/mkinitrd-output.img" "$work/mkinitrd-output.img"
rm -f "$work/rootfs/tmp/mkinitrd-output.img"
echo "mkinitramfs output: $(du -h "$work/mkinitrd-output.img" | cut -f1)"
file "$work/mkinitrd-output.img"

# Unmount
umount "$work/rootfs/dev/pts" 2>/dev/null || true
umount "$work/rootfs/dev" 2>/dev/null || true
umount "$work/rootfs/sys" 2>/dev/null || true
umount "$work/rootfs/proc" 2>/dev/null || true

# ============================================================
# 4. Extract mkinitramfs output and inject nodeforge-initrd
# ============================================================
echo "=== 4. Extract and inject nodeforge-initrd ==="
mkdir -p "$work/initrd-root"
cd "$work/initrd-root"

# Try zstd first, then gzip
if zstd -d "$work/mkinitrd-output.img" -o /tmp/mkinitrd.cpio 2>/dev/null; then
    echo "format: zstd"
    cat /tmp/mkinitrd.cpio | cpio -idmv 2>&1 | tail -5
    rm -f /tmp/mkinitrd.cpio
elif gzip -dc "$work/mkinitrd-output.img" | cpio -idmv 2>&1 | tail -5; then
    echo "format: gzip"
else
    cat "$work/mkinitrd-output.img" | cpio -idmv 2>&1 | tail -5
    echo "format: plain cpio"
fi

echo "=== mkinitramfs initrd contents ==="
echo "init: $(ls -la ./init 2>/dev/null || echo 'not found')"
echo "total .ko: $(find . -name '*.ko*' 2>/dev/null | wc -l)"
echo "overlay.ko: $(find . -name 'overlay.ko*' 2>/dev/null | head -1)"
echo "squashfs.ko: $(find . -name 'squashfs.ko*' 2>/dev/null | head -1)"

echo "=== Critical tools check ==="
for tool in curl ip dhclient modprobe switch_root mount busybox wget; do
    found=$(find . -name "$tool" -type f 2>/dev/null | head -1)
    if [[ -z "$found" ]]; then
        echo "MISSING: $tool"
    else
        echo "OK: $tool -> $found"
    fi
done

# Install nodeforge-initrd
install -m 0755 "$repo/zig-out/bin/nodeforge-initrd" ./usr/sbin/nodeforge-initrd

# Check if curl exists in mkinitramfs output
if [[ ! -f ./usr/bin/curl ]]; then
    echo "=== Injecting curl from rootfs ==="
    ROOTFS="$work/rootfs"
    INITRD="$work/initrd-root"
    install -m 0755 "$ROOTFS/usr/bin/curl" "$INITRD/usr/bin/curl"
    chroot_libraries=$(chroot "$ROOTFS" ldd /usr/bin/curl 2>/dev/null | grep '=>' | awk '{print $3}')
    for lib_path in $chroot_libraries; do
        [[ -z "$lib_path" || "$lib_path" == "(0x"* ]] && continue
        lib_name=$(basename "$lib_path")
        found=$(find "$INITRD" -name "$lib_name" 2>/dev/null | head -1)
        if [[ -z "$found" ]]; then
            dest_dir="$INITRD$(dirname "$lib_path")"
            mkdir -p "$dest_dir"
            cp -L "$ROOTFS$lib_path" "$dest_dir/"
            echo "  copied: $lib_name"
        fi
    done
else
    echo "curl already present in mkinitramfs output"
fi

# Replace /init with nodeforge wrapper
cat > ./init << 'INITEOF'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_LIBRARY_PATH=/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:/lib64

# Create mount points (nodeforge-initrd will mount proc/sys/dev)
[ -d /dev ] || mkdir -m 0755 /dev
[ -d /sys ] || mkdir /sys
[ -d /proc ] || mkdir /proc
[ -d /tmp ] || mkdir /tmp
[ -d /root ] || mkdir -m 0700 /root

# Load required modules (best-effort)
for m in loop squashfs overlay virtio virtio_pci virtio_pci_modern_dev virtio_net; do
    modprobe "$m" 2>/dev/null
done

# Configure network (best-effort)
ip link set eth0 up 2>/dev/null
ip addr add 10.0.2.15/24 dev eth0 2>/dev/null
ip route add default via 10.0.2.2 2>/dev/null

echo "=== mkinitramfs wrapper: eth0 up ==="
exec /usr/sbin/nodeforge-initrd
INITEOF
chmod 0755 ./init

# Create capsule directory
mkdir -p ./capsule; rm -f ./capsule/*

# Verify
echo "=== verification ==="
echo "init: $(head -1 ./init)"
echo "nodeforge-initrd: $(ls -la ./usr/sbin/nodeforge-initrd | awk '{print $1, $5}')"
echo "modules: $(find ./usr/lib/modules -name '*.ko*' 2>/dev/null | wc -l)"

# Repack as cpio + gzip
cd "$work/initrd-root"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$work/initramfs.img"
echo "initramfs.img: $(du -h "$work/initramfs.img" | cut -f1)"

umount "$m"; rmdir "$m"
cd "$repo"

# ============================================================
# 5. Set up catalog
# ============================================================
echo "=== 5. Set up catalog ==="
config="$install_root/config/config.json"

pkill -f "nodeforged --install-root $install_root" 2>/dev/null || true
for _ in {1..50}; do ! pgrep -f "nodeforged --install-root $install_root" >/dev/null && break; sleep 0.1; done

mkdir -p "$install_root/assets/boot"
cp "$work/vmlinuz-$KREL" "$install_root/assets/boot/vmlinuz-$KREL"
mkdir -p "$install_root/assets/initrd-ubuntu"
cp "$work/initramfs.img" "$install_root/assets/initrd-ubuntu/ub-mkinit-initrd"
mkdir -p "$install_root/assets/rootfs-ubuntu"
cp "$work/rootfs.squashfs" "$install_root/assets/rootfs-ubuntu/ub-mkinit-rootfs"

P="ub-mkinit"
python3 - "$install_root/catalog" "$KREL" "$P" <<'PYINJ'
import json, hashlib, sys, os
dst, krel, P = sys.argv[1], sys.argv[2], sys.argv[3]
def load(n):
    with open(f"{dst}/{n}.json") as f: return json.load(f)
def dump(n, d):
    with open(f"{dst}/{n}.json","w") as f: json.dump(d, f, indent=2)
assets = load("assets")
def A(name, kind, path):
    return {"name": name, "kind": kind, "path": path, "distro": "ubuntu",
            "version": "22.04", "arch": "aarch64", "kernel_release": krel,
            "sha256": None, "revision": 1, "size": None, "media_type": None}
for nm, k, p in [(f"{P}-kernel","kernel",f"boot/vmlinuz-{krel}"),
                 (f"{P}-initrd","nodeforge_initrd",f"initrd-ubuntu/{P}-initrd"),
                 (f"{P}-rootfs","rootfs",f"rootfs-ubuntu/{P}-rootfs")]:
    a = next((x for x in assets if x["name"] == nm), None)
    if a is None: assets.append(A(nm, k, p))
    else: a.update({"kind":k,"path":p,"distro":"ubuntu","version":"22.04","arch":"aarch64","kernel_release":krel})
dump("assets", assets)
bundles = load("boot_bundles")
b = {"name": f"{P}-bundle", "distro": "ubuntu", "version": "22.04", "arch": "aarch64",
     "kernel_release": krel, "kernel": f"{P}-kernel", "runtime_kernel": f"{P}-kernel",
     "initrd": f"{P}-initrd"}
if not any(x["name"] == b["name"] for x in bundles): bundles.append(b)
dump("boot_bundles", bundles)
nodes = load("nodes")
if not any(x["id"] == "ub-mkinit-node" for x in nodes):
    nodes.append({"id":"ub-mkinit-node","mac":"52:54:00:12:34:92","arch":"aarch64","profile":"ub-mkinit"})
dump("nodes", nodes)
profs = load("profiles")
p = next((x for x in profs if x["name"]=="ub-mkinit"), None)
if p is None:
    base = next((x for x in profs if x["name"]=="ubuntu-22.04-aarch64-iso"), profs[0])
    p = json.loads(json.dumps(base)); p["name"]="ub-mkinit"; profs.append(p)
p["install_source"]="ubuntu-22.04-aarch64-iso"; p["kind"]="diskless"; p["boot_bundle"]="ub-mkinit-bundle"
dump("profiles", profs)
names = ["distros","profiles","nodes","provisioning_bundles","repositories","assets",
         "install_sources","boot_bundles","discovery_policy","unknown_client_observations"]
ents=[]
for name in names:
    with open(f"{dst}/{name}.json","rb") as f: data=f.read()
    ents.append({"name":name,"file":f"{name}.json","sha256":hashlib.sha256(data).hexdigest()})
h=hashlib.sha256(); h.update(b"1")
for e in ents: h.update(e["name"].encode()+e["sha256"].encode())
man={"layout_schema_version":1,"catalog_schema_version":4,"catalog_revision":1,
     "transaction_id":h.hexdigest(),"entities":ents}
with open(f"{dst}/manifest.json","w") as f: json.dump(man,f,indent=2)
print(f"catalog injected; assets={len(assets)} bundles={len(bundles)} nodes={len(nodes)} profiles={len(profs)}")
PYINJ

rm -f "$install_root/state/rootfs-artifacts.json" "$install_root/assets/rootfs/"*.squashfs 2>/dev/null || true

# Start daemon
ip addr add 10.0.2.2/32 dev lo 2>/dev/null || true
setsid zig-out/bin/nodeforged --install-root "$install_root" </dev/null >"$work/nodeforged.log" 2>&1 &
sleep 2
pgrep -f "nodeforged --install-root $install_root" >/dev/null || { echo "daemon failed"; cat "$work/nodeforged.log"; exit 1; }
echo "daemon started"

# Create profile + register rootfs
zig-out/bin/nodeforge --install-root "$install_root" profile create "$profile" ubuntu-22.04-aarch64-iso \
    --kind diskless --boot-bundle ub-mkinit-bundle --config "$config" --output json >/dev/null 2>&1 || true
zig-out/bin/nodeforge --install-root "$install_root" profile set "$profile" diskless.failure.max_attempts=3 --config "$config" --output json >/dev/null
zig-out/bin/nodeforge --install-root "$install_root" profile set "$profile" diskless.failure.backoff_seconds=1 --config "$config" --output json >/dev/null
zig-out/bin/nodeforge --install-root "$install_root" profile rootfs register "$profile" --path "$work/rootfs.squashfs" --config "$config" --output json >/dev/null

# Prepare boot
prepare=$(curl -sS -H 'Content-Type: application/json' -H 'X-NodeForge-Internal-Capsule: 1' -d '{}' "http://127.0.0.1:$port/api/v1/management/nodes/$node/boot-prepare")
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

# Repack initrd with capsule tokens
cd "$work/initrd-root"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 >"$work/initramfs-final.img"
cd "$repo"
echo "final initramfs: $(du -h "$work/initramfs-final.img" | cut -f1)"

# ============================================================
# 6. QEMU boot
# ============================================================
echo "=== 6. QEMU boot ==="
echo "kernel: $work/vmlinuz-$KREL"
echo "initrd: $work/initramfs-final.img"
echo "kernel vermagic: $KREL"

/usr/libexec/qemu-kvm -cpu max -M virt -m 3072 \
    -kernel "$work/vmlinuz-$KREL" -initrd "$work/initramfs-final.img" \
    -append "nodeforge.config_url=$config_url nodeforge.session=$session nodeforge.node=$node console=ttyAMA0" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -nographic -no-reboot >"$work/console.log" 2>&1 &
qemu_pid=$!
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
    if grep -q 'NODEFORGE_UBUNTU_MKINIT_VALIDATION_DONE' "$work/console.log" 2>/dev/null &&
       grep -q '"type":"diskless.running"' "$install_root/logs/events.jsonl" 2>/dev/null; then break; fi
    kill -0 "$qemu_pid" 2>/dev/null || break
    sleep 1
done
kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; qemu_pid=

echo "=== console tail (last 40 lines) ==="
tail -40 "$work/console.log"
echo ""
echo "=== assertions ==="
grep -q 'NODEFORGE_UBUNTU_MKINIT_VALIDATION_DONE' "$work/console.log" && echo "PASS: validation done" || echo "FAIL: validation done"
grep -q '"type":"diskless.running"' "$install_root/logs/events.jsonl" && echo "PASS: diskless.running" || echo "FAIL: diskless.running"
grep -qiE 'Ubuntu|switch_root|Reached target' "$work/console.log" && echo "PASS: ubuntu boot evidence" || echo "FAIL: ubuntu boot evidence"
echo "MKINIT_SMOKE_DONE console=$work/console.log events=$install_root/logs/events.jsonl"
