#!/usr/bin/env bash
# r97n0 full-OS v0.2 diskless validation fixture.
set -euo pipefail

repo=${NODEFORGE_REPO:-/root/NodeForge}
fixture=${NODEFORGE_QEMU_FIXTURE:-/root/nf-smoke}
base_rootfs=${NODEFORGE_BASE_ROOTFS:-/root/nf-full/rootfs.squashfs}
kernel=${NODEFORGE_QEMU_KERNEL:-/boot/vmlinuz-5.14.0-611.5.1.el9_7.aarch64}
work=/tmp/nodeforge-v02-qemu
install_root=/tmp/nodeforge-v02-install
port=18090
node=nf-v02-full
profile=nf-v02-diskless

cleanup() {
    if [[ -n "${qemu_pid:-}" ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    if [[ -n "${test_daemon_pid:-}" ]]; then
        kill "$test_daemon_pid" 2>/dev/null || true
        wait "$test_daemon_pid" 2>/dev/null || true
    fi
    systemctl start nodeforged 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$work" "$install_root"
mkdir -p "$work"

cd "$repo"
# Binaries are cross-compiled on the dev host and synced here; do NOT compile
# on the verification host, so r97n0 always runs the exact committed build.
#   Local build : zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe
#   Sync to host: rsync -az --delete zig-out/bin/ root@r97n0:/root/NodeForge/zig-out/bin/
for b in nodeforge nodeforged nodeforge-agent nodeforge-initrd; do
    [[ -x "zig-out/bin/$b" ]] || { echo "missing prebuilt $b: cross-compile locally and sync zig-out/bin/ (see docs/validation/V0_2_PHASE8_VALIDATION.md)" >&2; exit 1; }
done

# Produce derived fixtures; preserve the historical base rootfs/initramfs.
unsquashfs -d "$work/rootfs" "$base_rootfs" >/dev/null
install -m 0755 zig-out/bin/nodeforge-agent "$work/rootfs/usr/sbin/nodeforge-agent"
install -D -m 0644 packaging/systemd/nodeforge-firstboot.service "$work/rootfs/etc/systemd/system/nodeforge-firstboot.service"
mkdir -p "$work/rootfs/etc/systemd/system/multi-user.target.wants"
ln -sfn ../nodeforge-firstboot.service "$work/rootfs/etc/systemd/system/multi-user.target.wants/nodeforge-firstboot.service"
# Validation-only drop-in: invoke the oneshot a second time to prove the
# session/plan journal makes the already-succeeded side effect a no-op, then
# expose journal/log evidence on the serial console before QEMU is stopped.
mkdir -p "$work/rootfs/etc/systemd/system/nodeforge-firstboot.service.d"
printf '%s\n' \
    '[Service]' \
    'ExecStartPost=/usr/sbin/nodeforge-agent' \
    "ExecStartPost=/bin/sh -c 'cat /var/lib/nodeforge/firstboot-journal.json /var/lib/nodeforge/firstboot.log /etc/issue.d/nodeforge-archive.issue /etc/issue.d/nodeforge-script.issue > /dev/console; echo NODEFORGE_VALIDATION_DONE > /dev/console'" \
    >"$work/rootfs/etc/systemd/system/nodeforge-firstboot.service.d/validation.conf"
mksquashfs "$work/rootfs" "$work/rootfs.squashfs" -noappend -comp zstd >/dev/null

cp -a "$fixture/initrd-root" "$work/initrd-root"
install -m 0755 zig-out/bin/nodeforge-initrd "$work/initrd-root/usr/sbin/nodeforge-initrd"
mkdir -p "$work/initrd-root/capsule"
rm -f "$work/initrd-root/capsule/"*

zig-out/bin/nodeforge setup --install-root "$install_root" --non-interactive --yes \
    --bind-interface lo --server-ip 10.0.2.2 --http-port "$port" \
    --subnet 127.0.0.0/24 --pool-start 127.0.0.100 --pool-end 127.0.0.200 >/dev/null
# Reuse the production Rocky repository files on disk so the guest's first-boot
# package action can refresh metadata, and inject a diskless catalog whose repo
# base_url is rebound to the test daemon (preserving the /Minimal subpath).
mkdir -p "$install_root/assets/repos"
ln -sfn /opt/nodeforge/assets/repos/rocky-9.7-aarch64-iso "$install_root/assets/repos/rocky-9.7-aarch64-iso"
python3 - "$install_root/catalog" /opt/nodeforge/catalog 10.0.2.2 "$port" <<'PYINJ'
import json, hashlib, sys, shutil
dst, src, ip, port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
RELEASE = "5.14.0-362.13.1.el9.aarch64"
P = "nf-test"
for ent in ["distros", "install_sources", "repositories", "assets"]:
    shutil.copy(f"{src}/{ent}.json", f"{dst}/{ent}.json")
marker = "/artifacts/repositories/"
with open(f"{dst}/repositories.json") as f: repos = json.load(f)
for r in repos:
    idx = r["base_url"].find(marker)
    path = r["base_url"][idx:] if idx >= 0 else f"{marker}{r['name']}"
    r["base_url"] = f"http://{ip}:{port}{path}"
with open(f"{dst}/repositories.json", "w") as f: json.dump(repos, f, indent=2)
with open(f"{dst}/assets.json") as f: assets = json.load(f)
def A(name, kind):
    return {"name": name, "kind": kind, "path": f"rootfs-test/{name}", "distro": "rocky",
            "version": "9.7", "arch": "aarch64", "kernel_release": RELEASE,
            "sha256": None, "revision": 1, "size": None, "media_type": None}
for nm, k in [(f"{P}-kernel", "kernel"), (f"{P}-initrd", "nodeforge_initrd"), (f"{P}-rootfs", "rootfs")]:
    if not any(a["name"] == nm for a in assets): assets.append(A(nm, k))
with open(f"{dst}/assets.json", "w") as f: json.dump(assets, f, indent=2)
bundle = [{"name": "nf-test-bundle", "distro": "rocky", "version": "9.7", "arch": "aarch64",
           "kernel_release": RELEASE, "kernel": f"{P}-kernel", "runtime_kernel": f"{P}-kernel",
           "initrd": f"{P}-initrd", "rootfs": f"{P}-rootfs"}]
with open(f"{dst}/boot_bundles.json", "w") as f: json.dump(bundle, f, indent=2)
names = ["distros", "profiles", "nodes", "provisioning_bundles", "repositories", "assets",
         "install_sources", "boot_bundles", "discovery_policy", "unknown_client_observations"]
entities = []
for name in names:
    with open(f"{dst}/{name}.json", "rb") as f: data = f.read()
    entities.append({"name": name, "file": f"{name}.json", "sha256": hashlib.sha256(data).hexdigest()})
h = hashlib.sha256(); h.update(b"1")
for e in entities: h.update(e["name"].encode() + e["sha256"].encode())
manifest = {"layout_schema_version": 1, "catalog_schema_version": 4, "catalog_revision": 1,
            "transaction_id": h.hexdigest(), "entities": entities}
with open(f"{dst}/manifest.json", "w") as f: json.dump(manifest, f, indent=2)
print(f"v4 catalog injected; assets={len(assets)} boot_bundles={len(bundle)} repos={len(repos)}")
PYINJ

systemctl stop nodeforged
for _ in {1..50}; do
    ! pgrep -f '/opt/nodeforge/bin/nodeforged' >/dev/null && break
    sleep 0.1
done
if pgrep -f '/opt/nodeforge/bin/nodeforged' >/dev/null; then
    echo "production nodeforged did not stop" >&2
    exit 1
fi
# The test daemon binds DHCP/TFTP to server-ip 10.0.2.2 (QEMU user-net host addr).
# Ensure it is assigned to lo so the bind succeeds across reboots (idempotent).
ip addr add 10.0.2.2/32 dev lo 2>/dev/null || true
setsid zig-out/bin/nodeforged --install-root "$install_root" </dev/null >"$work/nodeforged.log" 2>&1 &
test_daemon_pid=$!
sleep 2
if ! kill -0 "$test_daemon_pid" 2>/dev/null; then
    cat "$work/nodeforged.log" >&2
    exit 1
fi

config="$install_root/config/config.json"
printf 'NODEFORGE_PAYLOAD_PROOF\n' >"$work/payload-proof"
mkdir -p "$work/archive-root/etc/issue.d"
printf 'NODEFORGE_ARCHIVE_PROOF\n' >"$work/archive-root/etc/issue.d/nodeforge-archive.issue"
tar -C "$work/archive-root" -cf "$work/proof.tar" .
printf '%s\n' '#!/bin/sh' "printf 'NODEFORGE_SCRIPT_PROOF\\n' > /etc/issue.d/nodeforge-script.issue" >"$work/proof.sh"
zig-out/bin/nodeforge assets managed-file import nf-v02-proof --from-file "$work/payload-proof" \
    --media-type text/plain --config "$config" --output json >/dev/null
zig-out/bin/nodeforge assets archive import nf-v02-archive --from-file "$work/proof.tar" \
    --media-type application/x-tar --config "$config" --output json >/dev/null
zig-out/bin/nodeforge assets script import nf-v02-script --from-file "$work/proof.sh" \
    --media-type text/x-shellscript --config "$config" --output json >/dev/null
zig-out/bin/nodeforge assets provision-bundle create nf-v02-firstboot \
    --config "$config" --output json >/dev/null
zig-out/bin/nodeforge assets provision-bundle item add nf-v02-firstboot steps \
    name=qemu-proof action=managed-file phase=first-boot \
    idempotency_key=qemu-proof-v1 timeout_s=30 retryable=true \
    destination=/etc/issue.d/nodeforge-proof.issue content_asset=nf-v02-proof \
    mode=0644 owner=root group=root --config "$config" --output json >/dev/null
zig-out/bin/nodeforge assets provision-bundle item add nf-v02-firstboot steps \
    name=qemu-archive action=archive phase=first-boot \
    idempotency_key=qemu-archive-v1 timeout_s=30 retryable=true \
    destination=/ content_asset=nf-v02-archive \
    --config "$config" --output json >/dev/null
zig-out/bin/nodeforge assets provision-bundle item add nf-v02-firstboot steps \
    name=qemu-script action=script phase=first-boot \
    idempotency_key=qemu-script-v1 timeout_s=30 retryable=false \
    content_asset=nf-v02-script --config "$config" --output json >/dev/null
zig-out/bin/nodeforge assets provision-bundle item add nf-v02-firstboot steps \
    name=qemu-package action=package phase=first-boot \
    idempotency_key=qemu-package-v1 timeout_s=180 retryable=true \
    packages=bash --config "$config" --output json >/dev/null
zig-out/bin/nodeforge assets provision-bundle item add nf-v02-firstboot steps \
    name=qemu-degraded action=managed-file phase=first-boot \
    idempotency_key=qemu-degraded-v1 timeout_s=30 retryable=true \
    destination=/nodeforge-parent-does-not-exist/proof content_asset=nf-v02-proof \
    mode=0644 owner=root group=root --config "$config" --output json >/dev/null
zig-out/bin/nodeforge profile create "$profile" rocky-9.7-aarch64-iso \
    --kind diskless --boot-bundle nf-test-bundle --config "$config" --output json >/dev/null
zig-out/bin/nodeforge profile set "$profile" diskless.provision.bundle=nf-v02-firstboot \
    --config "$config" --output json >/dev/null
zig-out/bin/nodeforge profile set "$profile" diskless.failure.max_attempts=3 \
    --config "$config" --output json >/dev/null
zig-out/bin/nodeforge profile set "$profile" diskless.failure.backoff_seconds=1 \
    --config "$config" --output json >/dev/null
zig-out/bin/nodeforge profile rootfs register "$profile" --path "$work/rootfs.squashfs" \
    --config "$config" --output json >/dev/null
zig-out/bin/nodeforge node add "$node" mac=52:54:00:12:34:57 arch=aarch64 \
    profile="$profile" --config "$config" --output json >/dev/null

prepare=$(zig-out/bin/nodeforge node boot-prepare "$node" --config "$config" --output json)
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

(cd "$work/initrd-root" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 >"$work/initramfs.img")

# Capability separation must fail closed before the guest starts.
host_config_url=${config_url/http:\/\/10.0.2.2/http:\/\/127.0.0.1}
host_rootfs_url=${host_config_url%/boot-config}/rootfs
test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $config_token" -H "X-NodeForge-Session: $session" "$host_rootfs_url")" = 401
test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $rootfs_token" -H "X-NodeForge-Session: $session" "$host_config_url")" = 401

# The persistent secret + hashed claims must recover the exact active session
# across a daemon restart; raw tokens are reconstructed, never stored.
kill "$test_daemon_pid"
wait "$test_daemon_pid"
setsid zig-out/bin/nodeforged --install-root "$install_root" </dev/null >>"$work/nodeforged.log" 2>&1 &
test_daemon_pid=$!
sleep 2
kill -0 "$test_daemon_pid"
test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $config_token" -H "X-NodeForge-Session: $session" "$host_config_url")" = 200

/usr/libexec/qemu-kvm -cpu max -M virt -m 3072 \
    -kernel "$kernel" -initrd "$work/initramfs.img" \
    -append "nodeforge.config_url=$config_url nodeforge.session=$session nodeforge.node=$node console=ttyAMA0" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -nographic -no-reboot >"$work/console.log" 2>&1 &
qemu_pid=$!

deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
    if grep -q 'NODEFORGE_VALIDATION_DONE' "$work/console.log" 2>/dev/null &&
       grep -q '"type":"diskless.running"' "$install_root/logs/events.jsonl" 2>/dev/null; then
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

grep -qiE 'login:|Reached target.*Multi-User|Startup finished in' "$work/console.log"
grep -q 'NODEFORGE_VALIDATION_DONE' "$work/console.log"
grep -q '"type":"diskless.running"' "$install_root/logs/events.jsonl"
grep -q "$node" "$work/console.log"
grep -q 'NODEFORGE_PAYLOAD_PROOF' "$work/console.log"
grep -q 'NODEFORGE_ARCHIVE_PROOF' "$work/console.log"
grep -q 'NODEFORGE_SCRIPT_PROOF' "$work/console.log"
grep -q "step 'qemu-package' ok" "$work/console.log"
grep -q '"status": "succeeded"' "$work/console.log"
grep -q '"status": "failed"' "$work/console.log"
grep -q "step 'qemu-degraded' attempt 3/3 FAILED" "$work/console.log"
grep -q "step 'qemu-proof' skipped (journal succeeded)" "$work/console.log"

# Lifecycle consumption revokes every capability. None may be replayed after
# initrd_started/rootfs_verified/agent-consumed/running.
test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $config_token" -H "X-NodeForge-Session: $session" "$host_config_url")" = 401
test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $rootfs_token" -H "X-NodeForge-Session: $session" "$host_rootfs_url")" = 401
agent_plan_url=$(python3 - "$prepare" <<'PY'
import json, sys
r = json.loads(sys.argv[1])["result"]
print(f"http://10.0.2.2:18090/api/v1/boot-sessions/{r['session_id']}/agent-plan/{r['agent_plan_digest']}")
PY
)
host_agent_plan_url=${agent_plan_url/http:\/\/10.0.2.2/http:\/\/127.0.0.1}
test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $agent_token" -H "X-NodeForge-Session: $session" "$host_agent_plan_url")" = 401
test "$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $event_token" -H "X-NodeForge-Session: $session" -H 'Content-Type: application/json' --data "{\"schema_version\":1,\"session_id\":\"$session\",\"event_seq\":7,\"expected_phase\":\"diskless.running\",\"phase\":\"diskless.running\"}" "${host_config_url%/boot-config}/events")" = 401

# A fresh session with only 1.5 GiB must fail the checked memory budget before
# attempting the 1.2 GiB rootfs transfer, and must report a terminal lifecycle.
lowmem_prepare=$(zig-out/bin/nodeforge node boot-prepare "$node" --config "$config" --output json)
python3 - "$lowmem_prepare" "$work/initrd-root/capsule" <<'PY'
import json, pathlib, sys
r = json.loads(sys.argv[1])["result"]
capsule = pathlib.Path(sys.argv[2])
for name in ("config", "rootfs", "agent", "event"):
    (capsule / f"{name}.token").write_text(r[f"{name}_token"])
PY
lowmem_session=$(python3 - "$lowmem_prepare" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["result"]["session_id"])
PY
)
lowmem_config_url=$(python3 - "$lowmem_prepare" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["result"]["config_url"])
PY
)
(cd "$work/initrd-root" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 >"$work/initramfs-lowmem.img")
/usr/libexec/qemu-kvm -cpu max -M virt -m 1536 \
    -kernel "$kernel" -initrd "$work/initramfs-lowmem.img" \
    -append "nodeforge.config_url=$lowmem_config_url nodeforge.session=$lowmem_session nodeforge.node=$node console=ttyAMA0" \
    -netdev user,id=n1 -device virtio-net-pci,netdev=n1 \
    -nographic -no-reboot >"$work/console-lowmem.log" 2>&1 &
qemu_pid=$!
deadline=$((SECONDS + 120))
while (( SECONDS < deadline )); do
    if grep -F "\"boot_session_id\",\"value\":\"$lowmem_session\"" "$install_root/logs/events.jsonl" |
       grep -q '"type":"diskless.failed"'; then
        break
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then break; fi
    sleep 1
done
kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true
qemu_pid=
grep -F "\"boot_session_id\",\"value\":\"$lowmem_session\"" "$install_root/logs/events.jsonl" |
    grep -q '"type":"diskless.failed"'
grep -q 'InsufficientMemory' "$work/console-lowmem.log"

echo "v0.2 full OS QEMU validation passed"
echo "console=$work/console.log"
echo "lowmem_console=$work/console-lowmem.log"
echo "events=$install_root/logs/events.jsonl"
