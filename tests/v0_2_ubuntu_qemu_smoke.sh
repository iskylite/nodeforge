#!/usr/bin/env bash
# r97n0 Ubuntu (aarch64) diskless QEMU smoke. Mirrors v0_2_qemu_full.sh but
# boots an Ubuntu 22.04 server rootfs derived from the live-server ISO's casper
# squashfs, against a daemon catalog that already published the Ubuntu install
# source via `nodeforge assets import`. Ubuntu OS-layer rootfs-build (apt/
# debootstrap) is unsupported in v0.2 (AptOsLayerUnsupported); this smoke reuses
# the ISO's prebuilt casper squashfs as the diskless lower rootfs, so it
# verifies the diskless boot loop + first-boot with Ubuntu userspace, not an
# nodeforge-built Ubuntu rootfs.
set -euo pipefail

repo=${NODEFORGE_REPO:-/root/NodeForge}
iso=${NODEFORGE_UBUNTU_ISO:-/root/ubuntu-22.04.5-live-server-arm64.iso}
install_root=${NODEFORGE_UB_INSTALL_ROOT:-/tmp/nf-ub2}
fixture=${NODEFORGE_QEMU_FIXTURE:-/root/nf-smoke}
kernel=${NODEFORGE_QEMU_KERNEL:-/boot/vmlinuz-5.14.0-611.5.1.el9_7.aarch64}
work=/tmp/nodeforge-v02-ubuntu
port=18092
node=ub-smoke-node
profile=ub-smoke
port_http=$port

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

# 1. Derive an Ubuntu server rootfs from the ISO casper layers, inject agent +
#    first-boot service (validation drop-in prints proof + DONE marker).
m=/tmp/ub-mnt-$$; mkdir -p "$m"; mount -o loop,ro "$iso" "$m"
# ubuntu-server-minimal.squashfs is a self-contained debootstrap-style base with
# systemd + bash; the .ubuntu-server layer is overlay-only (no /sbin/init), so a
# single layer suffices and avoids char-device merge collisions.
unsquashfs -d "$work/rootfs" "$m/casper/ubuntu-server-minimal.squashfs" >/dev/null
umount "$m"; rmdir "$m"
# Ubuntu minimal base ships /usr/lib/systemd/systemd but no /sbin/init; the
# nodeforge-agent --pre-init execs /sbin/init, so provide the canonical symlink.
ln -sf /usr/lib/systemd/systemd "$work/rootfs/sbin/init" 2>/dev/null || ln -sf /usr/lib/systemd/systemd "$work/rootfs/usr/sbin/init"
install -m 0755 zig-out/bin/nodeforge-agent "$work/rootfs/usr/sbin/nodeforge-agent"
install -D -m 0644 packaging/systemd/nodeforge-firstboot.service "$work/rootfs/etc/systemd/system/nodeforge-firstboot.service"
mkdir -p "$work/rootfs/etc/systemd/system/multi-user.target.wants"
ln -sfn ../nodeforge-firstboot.service "$work/rootfs/etc/systemd/system/multi-user.target.wants/nodeforge-firstboot.service"
mkdir -p "$work/rootfs/etc/systemd/system/nodeforge-firstboot.service.d"
printf '%s\n' \
    '[Service]' \
    'ExecStartPost=/usr/sbin/nodeforge-agent' \
    "ExecStartPost=/bin/sh -c 'cat /var/lib/nodeforge/firstboot-journal.json /var/lib/nodeforge/firstboot.log > /dev/console; echo NODEFORGE_UBUNTU_VALIDATION_DONE > /dev/console'" \
    >"$work/rootfs/etc/systemd/system/nodeforge-firstboot.service.d/validation.conf"
mksquashfs "$work/rootfs" "$work/rootfs.squashfs" -noappend -comp zstd >/dev/null

# 2. initramfs fixture: inject nodeforge-initrd (distro-agnostic).
cp -a "$fixture/initrd-root" "$work/initrd-root"
install -m 0755 zig-out/bin/nodeforge-initrd "$work/initrd-root/usr/sbin/nodeforge-initrd"
mkdir -p "$work/initrd-root/capsule"; rm -f "$work/initrd-root/capsule/"*

config="$install_root/config/config.json"
KREL="5.15.0-119-generic"
P="ub-smoke"

# 3. Inject diskless boot artifacts into the catalog that already holds the
#    Ubuntu install source (added by `nodeforge assets import`). Adds a
#    nodeforge-initrd asset + boot_bundle + diskless profile + node, then
#    recomputes the schema-4 manifest.
python3 - "$install_root/catalog" "$KREL" "$P" <<'PYINJ'
import json, hashlib, sys, os
dst, krel, P = sys.argv[1], sys.argv[2], sys.argv[3]
def load(n):
    with open(f"{dst}/{n}.json") as f: return json.load(f)
def dump(n, d):
    with open(f"{dst}/{n}.json","w") as f: json.dump(d, f, indent=2)
assets = load("assets")
# validateBootBundles requires kernel/initrd/rootfs assets to share the
# bundle kernel_release; set it on all three (update existing stale entries).
def A(name, kind, path):
    return {"name": name, "kind": kind, "path": path, "distro": "ubuntu",
            "version": "22.04", "arch": "aarch64", "kernel_release": krel,
            "sha256": None, "revision": 1, "size": None, "media_type": None}
for nm, k, p in [(f"{P}-kernel","kernel","install/ubuntu-22.04-aarch64-iso/vmlinuz"),
                 (f"{P}-initrd","nodeforge_initrd","initrd-ubuntu/"+P+"-initrd"),
                 (f"{P}-rootfs","rootfs","rootfs-ubuntu/"+P+"-rootfs")]:
    a = next((x for x in assets if x["name"] == nm), None)
    if a is None: assets.append(A(nm, k, p))
    else: a.update({"kind":k,"path":p,"distro":"ubuntu","version":"22.04","arch":"aarch64","kernel_release":krel})
dump("assets", assets)
bundles = load("boot_bundles")
b = {"name": f"{P}-bundle", "distro": "ubuntu", "version": "22.04", "arch": "aarch64",
     "kernel_release": krel, "kernel": f"{P}-kernel", "runtime_kernel": f"{P}-kernel",
     "initrd": f"{P}-initrd", "rootfs": f"{P}-rootfs"}
if not any(x["name"] == b["name"] for x in bundles): bundles.append(b)
dump("boot_bundles", bundles)
nodes = load("nodes")
if not any(x["id"] == "ub-smoke-node" for x in nodes):
    nodes.append({"id":"ub-smoke-node","mac":"52:54:00:12:34:90","arch":"aarch64","profile":"ub-smoke"})
dump("nodes", nodes)
profs = load("profiles")
p = next((x for x in profs if x["name"]=="ub-smoke"), None)
if p is None:
    base = next((x for x in profs if x["name"]=="ubuntu-22.04-aarch64-iso"), profs[0])
    p = json.loads(json.dumps(base)); p["name"]="ub-smoke"; profs.append(p)
p["install_source"]="ubuntu-22.04-aarch64-iso"; p["kind"]="diskless"; p["boot_bundle"]="ub-smoke-bundle"
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
print(f"ubuntu catalog injected; assets={len(assets)} bundles={len(bundles)} nodes={len(nodes)} profiles={len(profs)}")
PYINJ

# Clear any stale rootfs artifact from a prior smoke run: the build input
# digest is stable across runs but the rootfs content (e.g. /sbin/init fix)
# may differ, which would otherwise trip RootfsDigestDrift.
rm -f "$install_root/state/rootfs-artifacts.json" "$install_root/assets/rootfs/"*.squashfs 2>/dev/null || true
# Restart the daemon so the injected catalog is loaded fresh.
pkill -f "nodeforged --install-root $install_root" 2>/dev/null || true
for _ in {1..50}; do ! pgrep -f "nodeforged --install-root $install_root" >/dev/null && break; sleep 0.1; done
ip addr add 10.0.2.2/32 dev lo 2>/dev/null || true
setsid zig-out/bin/nodeforged --install-root "$install_root" </dev/null >"$work/nodeforged.log" 2>&1 &
sleep 2
pgrep -f "nodeforged --install-root $install_root" >/dev/null || { echo "daemon failed"; cat "$work/nodeforged.log"; exit 1; }

zig-out/bin/nodeforge --install-root "$install_root" profile create "$profile" ubuntu-22.04-aarch64-iso \
    --kind diskless --boot-bundle ub-smoke-bundle --config "$config" --output json >/dev/null 2>&1 || true
zig-out/bin/nodeforge --install-root "$install_root" profile set "$profile" diskless.failure.max_attempts=3 --config "$config" --output json >/dev/null
zig-out/bin/nodeforge --install-root "$install_root" profile set "$profile" diskless.failure.backoff_seconds=1 --config "$config" --output json >/dev/null
zig-out/bin/nodeforge --install-root "$install_root" profile rootfs register "$profile" --path "$work/rootfs.squashfs" --config "$config" --output json >/dev/null

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
(cd "$work/initrd-root" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 >"$work/initramfs.img")

/usr/libexec/qemu-kvm -cpu max -M virt -m 3072 \
    -kernel "$kernel" -initrd "$work/initramfs.img" \
    -append "nodeforge.config_url=$config_url nodeforge.session=$session nodeforge.node=$node console=ttyAMA0" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -nographic -no-reboot >"$work/console.log" 2>&1 &
qemu_pid=$!
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
    if grep -q 'NODEFORGE_UBUNTU_VALIDATION_DONE' "$work/console.log" 2>/dev/null &&
       grep -q '"type":"diskless.running"' "$install_root/logs/events.jsonl" 2>/dev/null; then break; fi
    kill -0 "$qemu_pid" 2>/dev/null || break
    sleep 1
done
kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; qemu_pid=

echo "=== console tail ==="; tail -25 "$work/console.log"
echo "=== assertions ==="
grep -q 'NODEFORGE_UBUNTU_VALIDATION_DONE' "$work/console.log" && echo "PASS: validation done" || echo "FAIL: validation done"
grep -q '"type":"diskless.running"' "$install_root/logs/events.jsonl" && echo "PASS: diskless.running" || echo "FAIL: diskless.running"
grep -qiE 'Ubuntu|switch_root|Reached target' "$work/console.log" && echo "PASS: ubuntu boot evidence" || echo "FAIL: ubuntu boot evidence"
echo "UBUNTU_SMOKE_DONE console=$work/console.log events=$install_root/logs/events.jsonl"
