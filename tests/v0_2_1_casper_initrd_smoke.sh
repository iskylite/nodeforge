#!/usr/bin/env bash
# v0.2.1 casper initrd + ISO kernel QEMU smoke test.
#
# Verifies the CORRECT Ubuntu diskless approach:
#   - kernel: Ubuntu /casper/vmlinuz (5.15.0-119-generic, from ISO)
#   - initrd: Ubuntu /casper/initrd (extract → inject nodeforge-initrd → replace /init → repack)
#   - rootfs: Ubuntu casper squashfs 3-layer overlay
#
# All three components are from the same Ubuntu ISO → vermagic matches.
set -euo pipefail

repo=${NODEFORGE_REPO:-/root/NodeForge}
iso=${NODEFORGE_UBUNTU_ISO:-/root/ubuntu-22.04.5-live-server-arm64.iso}
install_root=${NODEFORGE_UB_INSTALL_ROOT:-/tmp/nf-ub2}
work=/tmp/nodeforge-v021-casper
port=18093
node=ub-casper-node
profile=ub-casper
KREL="5.15.0-119-generic"

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
mkdir -p "$work/rootfs/etc/systemd/system"
printf '%s\n' \
    '[Unit]' \
    'Description=NodeForge diskless first-boot provisioning' \
    'After=local-fs.target network-online.target' \
    'Before=rc-local.service' \
    'Wants=network-online.target' \
    'ConditionPathExists=/var/lib/nodeforge/boot.json' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    'ExecStart=/usr/sbin/nodeforge-agent' \
    'RemainAfterExit=yes' \
    'StandardOutput=journal+file:/var/lib/nodeforge/firstboot.log' \
    'StandardError=journal+file:/var/lib/nodeforge/firstboot.log' \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target' \
    >"$work/rootfs/etc/systemd/system/nodeforge-firstboot.service"
mkdir -p "$work/rootfs/etc/systemd/system/multi-user.target.wants"
ln -sfn ../nodeforge-firstboot.service "$work/rootfs/etc/systemd/system/multi-user.target.wants/nodeforge-firstboot.service"
mkdir -p "$work/rootfs/etc/systemd/system/nodeforge-firstboot.service.d"
printf '%s\n' \
    '[Service]' \
    'ExecStartPost=/usr/sbin/nodeforge-agent' \
    "ExecStartPost=/bin/sh -c 'cat /var/lib/nodeforge/firstboot-journal.json /var/lib/nodeforge/firstboot.log > /dev/console; echo NODEFORGE_UBUNTU_CASPER_VALIDATION_DONE > /dev/console'" \
    >"$work/rootfs/etc/systemd/system/nodeforge-firstboot.service.d/validation.conf"
mksquashfs "$work/rootfs" "$work/rootfs.squashfs" -noappend -comp zstd >/dev/null
echo "rootfs.squashfs: $(du -h "$work/rootfs.squashfs" | cut -f1)"

# ============================================================
# 2. Extract vmlinuz from ISO and rename to actual kernel version
# ============================================================
echo "=== 2. Extract vmlinuz and rename ==="
cp "$m/casper/vmlinuz" "$work/vmlinuz-${KREL}"
file "$work/vmlinuz-${KREL}"
echo "vmlinuz renamed to: vmlinuz-${KREL}"

# ============================================================
# 3. Build initrd from casper initrd
#    zstd -d → cpio extract → inject nodeforge-initrd → replace /init → repack
# ============================================================
echo "=== 3. Build initrd from casper initrd ==="
zstd -d "$m/casper/initrd" -o "$work/casper-initrd.cpio" 2>/dev/null
echo "casper initrd decompressed: $(du -h "$work/casper-initrd.cpio" | cut -f1)"

mkdir -p "$work/initrd-root"
cd "$work/initrd-root"
cat "$work/casper-initrd.cpio" | cpio -idmv 2>&1 | tail -3
echo "casper initrd extracted"

# Check /sbin structure
echo "=== /sbin structure ==="
ls -la ./sbin 2>/dev/null || echo "/sbin not found, creating..."
if [[ ! -e ./sbin ]]; then
    mkdir -p ./sbin
fi
if [[ -d ./sbin && ! -L ./sbin ]]; then
    echo "/sbin is a directory (not symlink)"
fi

# nodeforge-initrd 本身直接作为 PID 1。它内置 HTTP 客户端并自行设置 PATH，
# 因此验证产物不得再注入 curl、目标 rootfs libc 或 shell wrapper。
install -m 0755 "$repo/zig-out/bin/nodeforge-initrd" ./init
mkdir -p ./usr/sbin
install -m 0755 "$repo/zig-out/bin/nodeforge-initrd" ./usr/sbin/nodeforge-initrd

# Create capsule directory
mkdir -p ./capsule; rm -f ./capsule/*

# Verify key files exist
echo "=== verification ==="
echo "init: $(file ./init)"
echo "nodeforge-initrd: $(ls -la ./usr/sbin/nodeforge-initrd | awk '{print $1, $5}')"
echo "modules: $(find ./usr/lib/modules -name '*.ko*' 2>/dev/null | wc -l)"
echo "overlay.ko: $(find ./usr/lib/modules -name 'overlay.ko*' 2>/dev/null | head -1)"
echo "modprobe: $(ls ./sbin/modprobe 2>/dev/null || echo 'not found')"
echo "switch_root: $(find . -name 'switch_root' 2>/dev/null | head -1)"
echo "busybox: $(ls ./usr/bin/busybox 2>/dev/null || echo 'not found')"

# Repack as cpio + gzip
cd "$work/initrd-root"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$work/initramfs.img"
echo "initramfs.img: $(du -h "$work/initramfs.img" | cut -f1)"

umount "$m"; rmdir "$m"
cd "$repo"

# ============================================================
# 4. Set up catalog with Ubuntu kernel + casper initrd + rootfs
# ============================================================
echo "=== 4. Set up catalog ==="
config="$install_root/config/config.json"

# Kill any existing test daemon
pkill -f "nodeforged --install-root $install_root" 2>/dev/null || true
for _ in {1..50}; do ! pgrep -f "nodeforged --install-root $install_root" >/dev/null && break; sleep 0.1; done

# Place kernel in the install root assets
mkdir -p "$install_root/assets/boot"
cp "$work/vmlinuz-${KREL}" "$install_root/assets/boot/vmlinuz-${KREL}"

# Place initrd
mkdir -p "$install_root/assets/boot/diskless/ubuntu"
cp "$work/initramfs.img" "$install_root/assets/boot/diskless/ubuntu/ub-casper-initrd"

# Place rootfs
mkdir -p "$install_root/assets/rootfs-ubuntu"
cp "$work/rootfs.squashfs" "$install_root/assets/rootfs-ubuntu/ub-casper-rootfs"

P="ub-casper"
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
                 (f"{P}-initrd","nodeforge_initrd",f"diskless/ubuntu/{P}-initrd"),
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
if not any(x["id"] == "ub-casper-node" for x in nodes):
    nodes.append({"id":"ub-casper-node","mac":"52:54:00:12:34:91","arch":"aarch64","profile":"ub-casper"})
dump("nodes", nodes)
profs = load("profiles")
p = next((x for x in profs if x["name"]=="ub-casper"), None)
if p is None:
    base = next((x for x in profs if x["name"]=="ubuntu-22.04-aarch64-iso"), profs[0])
    p = json.loads(json.dumps(base)); p["name"]="ub-casper"; profs.append(p)
p["install_source"]="ubuntu-22.04-aarch64-iso"; p["kind"]="diskless"; p["boot_bundle"]="ub-casper-bundle"
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

# Clear stale rootfs artifacts
rm -f "$install_root/state/rootfs-artifacts.json" "$install_root/assets/rootfs/"*.squashfs 2>/dev/null || true

# Start daemon
ip addr add 10.0.2.2/32 dev lo 2>/dev/null || true
setsid zig-out/bin/nodeforged --install-root "$install_root" </dev/null >"$work/nodeforged.log" 2>&1 &
sleep 2
pgrep -f "nodeforged --install-root $install_root" >/dev/null || { echo "daemon failed"; cat "$work/nodeforged.log"; exit 1; }
echo "daemon started"

# Create profile + register rootfs
zig-out/bin/nodeforge --install-root "$install_root" profile create "$profile" ubuntu-22.04-aarch64-iso \
    --kind diskless --boot-bundle ub-casper-bundle --config "$config" --output json >/dev/null 2>&1 || true
zig-out/bin/nodeforge --install-root "$install_root" profile set "$profile" diskless.failure.max_attempts=3 --config "$config" --output json >/dev/null
zig-out/bin/nodeforge --install-root "$install_root" profile set "$profile" diskless.failure.backoff_seconds=1 --config "$config" --output json >/dev/null
zig-out/bin/nodeforge --install-root "$install_root" profile rootfs register "$profile" \
    --path "$work/rootfs.squashfs" --uncompressed-size "$(du -s --block-size=1 "$work/rootfs" | cut -f1)" \
    --config "$config" --output json >/dev/null

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
# 5. QEMU boot: Ubuntu kernel + casper initrd + Ubuntu rootfs
# ============================================================
echo "=== 5. QEMU boot ==="
echo "kernel: $work/vmlinuz-${KREL}"
echo "initrd: $work/initramfs-final.img"
echo "kernel vermagic: ${KREL}"

/usr/libexec/qemu-kvm -cpu max -M virt -m 3072 \
    -kernel "$work/vmlinuz-${KREL}" -initrd "$work/initramfs-final.img" \
    -append "nodeforge.config_url=$config_url nodeforge.session=$session nodeforge.node=$node console=ttyAMA0" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -nographic -no-reboot >"$work/console.log" 2>&1 &
qemu_pid=$!
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
    if grep -q 'NODEFORGE_UBUNTU_CASPER_VALIDATION_DONE' "$work/console.log" 2>/dev/null &&
       grep -q '"type":"diskless.running"' "$install_root/logs/events.jsonl" 2>/dev/null; then break; fi
    kill -0 "$qemu_pid" 2>/dev/null || break
    sleep 1
done
kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; qemu_pid=

echo "=== console tail (last 40 lines) ==="
tail -40 "$work/console.log"
echo ""
echo "=== assertions ==="
grep -q 'NODEFORGE_UBUNTU_CASPER_VALIDATION_DONE' "$work/console.log" && echo "PASS: validation done" || echo "FAIL: validation done"
grep -q '"type":"diskless.running"' "$install_root/logs/events.jsonl" && echo "PASS: diskless.running" || echo "FAIL: diskless.running"
grep -qiE 'Ubuntu|switch_root|Reached target' "$work/console.log" && echo "PASS: ubuntu boot evidence" || echo "FAIL: ubuntu boot evidence"
echo "CASPER_SMOKE_DONE console=$work/console.log events=$install_root/logs/events.jsonl"
