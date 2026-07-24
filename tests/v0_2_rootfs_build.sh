#!/usr/bin/env bash
# r97n0 v0.2 `profile rootfs build` endpoint validation.
#
# Builds a real content-addressed rootfs for a diskless profile from the served
# Rocky repository: OS layer (dnf --installroot) + rootfs-build phase steps
# (managed_file/archive/script) + mksquashfs + register. Verifies the steps were
# baked into the produced squashfs.
set -euo pipefail

repo=${NODEFORGE_REPO:-/root/NodeForge}
src_catalog=${NODEFORGE_SRC_CATALOG:-/opt/nodeforge/catalog}
server_ip=${NODEFORGE_BUILD_SERVER_IP:-127.0.0.1}
port=${NODEFORGE_BUILD_PORT:-18091}
work=/tmp/nodeforge-rbtest
install_root="$work/install"
profile=nf-rbtest
bundle=nf-rb-bundle

cleanup() {
    if [[ -n "${test_daemon_pid:-}" ]]; then
        kill "$test_daemon_pid" 2>/dev/null || true
        wait "$test_daemon_pid" 2>/dev/null || true
    fi
    systemctl start nodeforged 2>/dev/null || true
}
trap cleanup EXIT

rm -rf "$work"
mkdir -p "$work"
cd "$repo"
/usr/local/zig/zig build -Doptimize=ReleaseSafe

# Isolated test daemon: reuse production Rocky repos (on disk) via symlink.
systemctl stop nodeforged 2>/dev/null || true
for _ in {1..50}; do
    ! pgrep -f '/opt/nodeforge/bin/nodeforged' >/dev/null && break
    sleep 0.1
done
zig-out/bin/nodeforge setup --install-root "$install_root" --non-interactive --yes \
    --bind-interface lo --server-ip "$server_ip" --http-port "$port" \
    --subnet 127.0.0.0/24 --pool-start 127.0.0.100 --pool-end 127.0.0.200 >/dev/null

# Reuse the production Rocky repository files (repodata + packages) on disk.
mkdir -p "$install_root/assets/repos"
ln -sfn "$src_catalog/../assets/repos/rocky-9.7-aarch64-iso" "$install_root/assets/repos/rocky-9.7-aarch64-iso"

# Inject a diskless-capable catalog: copy distros/install_sources/repositories/assets
# from production, rebind repo base_url to the test daemon, append a boot bundle
# sharing one kernel_release (asset files need not exist for the build path).
python3 - "$install_root/catalog" "$src_catalog" "$server_ip" "$port" <<'PY'
import json, hashlib, sys, shutil
dst, src, ip, port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
RELEASE = "5.14.0-362.13.1.el9.aarch64"
P = "nf-test"
for ent in ["distros", "install_sources", "repositories", "assets"]:
    shutil.copy(f"{src}/{ent}.json", f"{dst}/{ent}.json")
with open(f"{dst}/repositories.json") as f: repos = json.load(f)
marker = "/artifacts/repositories/"
for r in repos:
    idx = r["base_url"].find(marker)
    path = r["base_url"][idx:] if idx >= 0 else f"/artifacts/repositories/{r['name']}"
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
b = [{"name": "nf-test-bundle", "distro": "rocky", "version": "9.7", "arch": "aarch64",
      "kernel_release": RELEASE, "kernel": f"{P}-kernel", "runtime_kernel": f"{P}-kernel",
      "initrd": f"{P}-initrd", "rootfs": f"{P}-rootfs"}]
with open(f"{dst}/boot_bundles.json", "w") as f: json.dump(b, f, indent=2)
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
print(f"catalog injected: assets={len(assets)} boot_bundles=1 repos={len(repos)}")
PY

setsid zig-out/bin/nodeforged --install-root "$install_root" </dev/null >"$work/daemon.log" 2>&1 &
test_daemon_pid=$!
sleep 2
if ! kill -0 "$test_daemon_pid" 2>/dev/null; then
    cat "$work/daemon.log" >&2
    exit 1
fi

config="$install_root/config/config.json"
cli() { zig-out/bin/nodeforge "$@" --config "$config" --output json; }

# rootfs-build proof assets + provision bundle.
printf 'NODEFORGE_BUILD_PROOF\n' >"$work/motd"
mkdir -p "$work/arc/etc/issue.d"
printf 'NODEFORGE_BUILD_ARCHIVE\n' >"$work/arc/etc/issue.d/nodeforge-build-archive.issue"
tar -C "$work/arc" -cf "$work/proof.tar" .
printf '%s\n' '#!/bin/sh' 'mkdir -p /etc/issue.d' "printf 'NODEFORGE_BUILD_SCRIPT\\n' > /etc/issue.d/nodeforge-build-script.issue" >"$work/proof.sh"

cli assets managed-file import nf-rb-motd --from-file "$work/motd" --media-type text/plain >/dev/null
cli assets archive import nf-rb-archive --from-file "$work/proof.tar" --media-type application/x-tar >/dev/null
cli assets script import nf-rb-script --from-file "$work/proof.sh" --media-type text/x-shellscript >/dev/null
cli assets provision-bundle create "$bundle" >/dev/null
cli assets provision-bundle item add "$bundle" steps \
    name=rb-motd action=managed-file phase=rootfs-build idempotency_key=rb-motd-v1 timeout_s=30 retryable=true \
    destination=/etc/motd content_asset=nf-rb-motd mode=0644 owner=root group=root >/dev/null
cli assets provision-bundle item add "$bundle" steps \
    name=rb-archive action=archive phase=rootfs-build idempotency_key=rb-archive-v1 timeout_s=30 retryable=true \
    destination=/ content_asset=nf-rb-archive >/dev/null
cli assets provision-bundle item add "$bundle" steps \
    name=rb-script action=script phase=rootfs-build idempotency_key=rb-script-v1 timeout_s=30 retryable=true \
    content_asset=nf-rb-script >/dev/null

# package action: exercises the chroot bind-mount local file:// source (no
# self-deadlock against the single-worker daemon) and bakes a real RPM in.
cli assets provision-bundle item add "$bundle" steps \
    name=rb-package action=package phase=rootfs-build idempotency_key=rb-package-v1 timeout_s=120 retryable=true \
    packages=tree >/dev/null

cli profile create "$profile" rocky-9.7-aarch64-iso --kind diskless --boot-bundle nf-test-bundle >/dev/null
cli profile set "$profile" diskless.provision.bundle="$bundle" >/dev/null

echo "=== repo repodata reachability ==="
repomd_code=$(curl -s -o /dev/null -w '%{http_code}' "http://$server_ip:$port/artifacts/repositories/rocky-9.7-aarch64-iso/Minimal/repodata/repomd.xml")
echo "Minimal repomd: $repomd_code"
test "$repomd_code" = "200"

echo "=== profile rootfs build $profile ==="
cli profile rootfs build "$profile" | tee "$work/build.json"
digest=$(python3 -c "import json;print(json.load(open('$work/build.json'))['result']['rootfs_input_digest'])")
file=$(python3 -c "import json;print(json.load(open('$work/build.json'))['result']['file'])")

echo "=== profile rootfs status $profile ==="
cli profile rootfs status "$profile"

# Verify the produced squashfs has the baked rootfs-build content.
rootfs_file="$install_root/assets/rootfs/$file"
test -f "$rootfs_file"
rm -rf "$work/verify"
unsquashfs -d "$work/verify" -f "$rootfs_file" >/dev/null
grep -q 'NODEFORGE_BUILD_PROOF' "$work/verify/etc/motd"
grep -q 'NODEFORGE_BUILD_ARCHIVE' "$work/verify/etc/issue.d/nodeforge-build-archive.issue"
grep -q 'NODEFORGE_BUILD_SCRIPT' "$work/verify/etc/issue.d/nodeforge-build-script.issue"

# package action baked a real RPM into the lower.
test -x "$work/verify/usr/bin/tree"

# Idempotency: a second build hits the cache (already_present, no rebuild).
# Query the build endpoint directly: the CLI surfaces post-build *status* ("ready"),
# but the build response itself reports "already_present" on a cache hit.
second=$(curl -s -X POST "http://$server_ip:$port/api/v1/management/profiles/$profile/rootfs/build" -H "Content-Type: application/json" -d '{}')
echo "second build response: $second"
python3 -c "import json,sys; s=json.loads(sys.argv[1])['result']['state']; assert s=='already_present', s; print('second build state:', s)" "$second"

echo "ROOTFS_BUILD_VALIDATION_DONE"
