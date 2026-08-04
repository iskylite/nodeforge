#!/usr/bin/env bash
# Archived v0.2 native HTTP client QEMU validation (not a current test).
# It preserves the historical three-token capsule and is not a v0.4 gate.
# Tests: nodeforge-initrd with built-in HTTP client (no curl dependency)
set -euo pipefail

repo=/root/NodeForge
work=/tmp/nf-qemu-native-http
install_root=/tmp/nf-qemu-install
port=18090
node=nf-diskless-test
profile=rocky-9.7-diskless
kernel=/boot/vmlinuz-5.14.0-611.5.1.el9_7.aarch64
initrd_src=/tmp/nf-initrd-build/initrd-root
rootfs_squashfs=/tmp/nf-rootfs-build.squashfs

cleanup() {
    if [[ -n "${qemu_pid:-}" ]]; then kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; fi
    if [[ -n "${test_daemon_pid:-}" ]]; then kill "$test_daemon_pid" 2>/dev/null || true; wait "$test_daemon_pid" 2>/dev/null || true; fi
    systemctl start nodeforged 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$work" "$install_root"
mkdir -p "$work"

cd "$repo"
for b in nodeforge nodeforged nodeforge-agent nodeforge-initrd; do
    [[ -x "zig-out/bin/$b" ]] || { echo "missing prebuilt $b" >&2; exit 1; }
done
if [[ "$(zig-out/bin/nodeforge --version | awk 'NR == 1 { print $2 }')" != "0.2.0" ]]; then
    echo "archived v0.2 fixture: current binaries are not v0.2; use docs/validation/V0_4_FULL_VALIDATION_RUNBOOK.md" >&2
    exit 2
fi

# 1. Set up test daemon with server_ip=10.0.2.2 (QEMU user-net host)
zig-out/bin/nodeforge setup --install-root "$install_root" --non-interactive --yes \
    --bind-interface lo --server-ip 10.0.2.2 --http-port "$port" \
    --subnet 127.0.0.0/24 --pool-start 127.0.0.100 --pool-end 127.0.0.200 >/dev/null

# 2. Copy production binaries
cp /opt/nodeforge/bin/nodeforge-agent "$install_root/bin/"
cp /opt/nodeforge/bin/nodeforge-initrd "$install_root/bin/"

# 3. Symlink production repos (read-only, contains ISO repository)
mkdir -p "$install_root/assets/repos"
ln -sfn /opt/nodeforge/assets/repos/rocky-9.7-aarch64-iso "$install_root/assets/repos/rocky-9.7-aarch64-iso"

# 4. Copy production catalog and adjust URLs
cp -a /opt/nodeforge/catalog/* "$install_root/catalog/"

# Clear nodes (will be re-added to avoid duplicate)
echo "[]" > "$install_root/catalog/nodes.json"

# Adjust repository base_url and install_source media_tree_url to use 10.0.2.2:port
python3 - "$install_root/catalog" "$port" <<'PYINJ'
import json, sys, hashlib, shutil
catalog_dir = sys.argv[1]
port = sys.argv[2]
ip = "10.0.2.2"

# Update repository URLs
with open(f"{catalog_dir}/repositories.json") as f:
    repos = json.load(f)
for r in repos:
    if "/artifacts/repositories/" in r["base_url"]:
        idx = r["base_url"].find("/artifacts/repositories/")
        r["base_url"] = f"http://{ip}:{port}{r['base_url'][idx:]}"
    else:
        raise SystemExit(f"repository is not managed HTTP: {r['base_url']}")
with open(f"{catalog_dir}/repositories.json", "w") as f:
    json.dump(repos, f, indent=2)

# Update install_source media_tree_url
with open(f"{catalog_dir}/install_sources.json") as f:
    sources = json.load(f)
for s in sources:
    s["media_tree_url"] = f"http://{ip}:{port}/artifacts/repositories/{s['name']}"
with open(f"{catalog_dir}/install_sources.json", "w") as f:
    json.dump(sources, f, indent=2)

# Recompute manifest
names = ["distros", "profiles", "nodes", "provisioning_bundles", "repositories", "assets",
         "install_sources", "boot_bundles", "discovery_policy", "unknown_client_observations"]
entities = []
for name in names:
    with open(f"{catalog_dir}/{name}.json", "rb") as f:
        data = f.read()
    entities.append({"name": name, "file": f"{name}.json", "sha256": hashlib.sha256(data).hexdigest()})
h = hashlib.sha256()
h.update(b"1")
for e in entities:
    h.update(e["name"].encode() + e["sha256"].encode())
manifest = {"layout_schema_version": 1, "catalog_schema_version": 5, "catalog_revision": 1,
            "transaction_id": h.hexdigest(), "entities": entities}
with open(f"{catalog_dir}/manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
print(f"Catalog adjusted for {ip}:{port}")
PYINJ

# 5. Stop production daemon, start test daemon
systemctl stop nodeforged
for _ in {1..50}; do
    ! pgrep -f '/opt/nodeforge/bin/nodeforged' >/dev/null && break
    sleep 0.1
done
ip addr add 10.0.2.2/32 dev lo 2>/dev/null || true

setsid zig-out/bin/nodeforged --install-root "$install_root" </dev/null >"$work/nodeforged.log" 2>&1 &
test_daemon_pid=$!
sleep 2
if ! kill -0 "$test_daemon_pid" 2>/dev/null; then
    cat "$work/nodeforged.log" >&2
    exit 1
fi

config="$install_root/config/config.json"

# 6. Register rootfs with test daemon
rootfs_uncompressed_size=$(unsquashfs -lln "$rootfs_squashfs" | awk '$1 ~ /^-/ { total += $3 } END { print total + 0 }')
zig-out/bin/nodeforge profile rootfs register "$profile" --path "$rootfs_squashfs" \
    --uncompressed-size "$rootfs_uncompressed_size" \
    --config "$config" --output json >/dev/null

# 7. Add node to test daemon
zig-out/bin/nodeforge node add "$node" mac=52:54:00:12:34:57 arch=aarch64 \
    profile="$profile" --config "$config" --output json >/dev/null

# 8. Boot-prepare
prepare=$(curl -sS -H 'Content-Type: application/json' -H 'X-NodeForge-Internal-Capsule: 1' -d '{}' "http://127.0.0.1:$port/api/v1/management/nodes/$node/boot-prepare")
echo "Boot-prepare result: $prepare" | head -1

# 9. Create capsule
rm -rf "$work/initrd-root"
cp -a "$initrd_src" "$work/initrd-root"
mkdir -p "$work/initrd-root/capsule"
rm -f "$work/initrd-root/capsule/"*

python3 - "$prepare" "$work/initrd-root/capsule" <<'PY'
import json, pathlib, sys
r = json.loads(sys.argv[1])["result"]
capsule = pathlib.Path(sys.argv[2])
for name in ("config", "rootfs", "agent", "event"):
    (capsule / f"{name}.token").write_text(r[f"{name}_token"])
(capsule / "session").write_text(r["session_id"])
(capsule / "config_url").write_text(r["config_url"])
PY

session=$(cat "$work/initrd-root/capsule/session")
config_url=$(cat "$work/initrd-root/capsule/config_url")
config_token=$(cat "$work/initrd-root/capsule/config.token")
rootfs_token=$(cat "$work/initrd-root/capsule/rootfs.token")
agent_token=$(cat "$work/initrd-root/capsule/agent.token")
event_token=$(cat "$work/initrd-root/capsule/event.token")
rm "$work/initrd-root/capsule/session" "$work/initrd-root/capsule/config_url"

echo "Session: $session"
echo "Config URL: $config_url"

# 10. Pack initrd with capsule
(cd "$work/initrd-root" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 >"$work/initramfs.img")
echo "Initrd packed: $(ls -lh "$work/initramfs.img" | awk '{print $5}')"

# 11. Run QEMU
echo "=== Starting QEMU ==="
/usr/libexec/qemu-kvm -cpu max -M virt -m 3072 \
    -kernel "$kernel" -initrd "$work/initramfs.img" \
    -append "nodeforge.config_url=$config_url nodeforge.session=$session nodeforge.node=$node console=ttyAMA0" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -nographic -no-reboot >"$work/console.log" 2>&1 &
qemu_pid=$!

# Wait for boot or timeout
deadline=$((SECONDS + 300))
while (( SECONDS < deadline )); do
    if grep -q 'NODEFORGE_VALIDATION_DONE\|nodeforge-agent\|Reached target.*Multi-User\|Startup finished\|login:' "$work/console.log" 2>/dev/null; then
        break
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        break
    fi
    sleep 1
done

kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true
qemu_pid=

echo "=== QEMU console output (last 50 lines) ==="
tail -50 "$work/console.log"

echo ""
echo "=== Checking for native HTTP progress messages ==="
grep -E '\[nodeforge-initrd\]' "$work/console.log" || echo "(no nodeforge-initrd messages found)"

echo ""
echo "=== Checking for lifecycle events ==="
grep -E 'diskless\.' "$work/console.log" || echo "(no lifecycle events found)"

echo ""
echo "=== Checking daemon events ==="
grep -E 'diskless\.' "$install_root/logs/events.jsonl" 2>/dev/null | tail -10 || echo "(no events)"

echo ""
echo "=== Validation results ==="
if grep -qiE 'login:|Reached target.*Multi-User|Startup finished in' "$work/console.log"; then
    echo "PASS: System booted to multi-user target"
else
    echo "FAIL: System did not reach multi-user target"
fi

if grep -q '\[nodeforge-initrd\] GET' "$work/console.log"; then
    echo "PASS: Native HTTP client used (no curl)"
else
    echo "FAIL: No native HTTP client messages found"
fi

if grep -qE 'rootfs_downloading|rootfs_verified|rootfs_mounted' "$work/console.log"; then
    echo "PASS: Rootfs download and mount lifecycle observed"
else
    echo "FAIL: Rootfs lifecycle not observed in console"
fi

echo ""
echo "console=$work/console.log"
echo "daemon_log=$work/nodeforged.log"
echo "events=$install_root/logs/events.jsonl"
