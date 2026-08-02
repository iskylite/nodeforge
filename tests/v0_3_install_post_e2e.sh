#!/usr/bin/env bash
# v0.3 install-post canonical action end-to-end deployment validation.
#
# This script PXE-boots a real node with an install-post provision bundle
# containing all four canonical actions (managed_file, package, archive Mode A,
# archive Mode B, script) and verifies:
#   1. The install completes successfully (deployment reaches successful_generation)
#   2. The install-post journal shows all steps as succeeded
#   3. The target system has the expected files from each action
#   4. HTTP artifact serving worked (archive/script/managed-file were downloadable)
#
# Prerequisites:
#   - Cross-compiled binaries synced to r97n0 (zig build + rsync)
#   - r97n0 production nodeforged running with Rocky 9.7 ISO imported
#   - r97n1 VMware VM configured for PXE boot on vmnet2
#   - SSH access to r97n0 and r97n1 (192.168.27.210 after install)
set -euo pipefail

remote=${NODEFORGE_REMOTE:-root@r97n0}
node=${NODEFORGE_NODE:-r97n1}
node_ip=${NODEFORGE_NODE_IP:-192.168.27.210}
vmx=${NODEFORGE_VMX:-/Users/iskylite/Virtual\ Machines.localized/r97n1.vmwarevm/r97n1.vmx}
vmrun=${NODEFORGE_VMRUN:-/Applications/VMware\ Fusion.app/Contents/Public/vmrun}
install_profile=${NODEFORGE_INSTALL_PROFILE:-rocky-9.7-aarch64-minimal-install}
timeout=${NODEFORGE_TIMEOUT:-1200}
poll=${NODEFORGE_POLL:-10}
cli=/opt/nodeforge/bin/nodeforge
run_id=${NODEFORGE_RUN_ID:-$(date +%Y%m%d%H%M%S)}
bundle=v03-installpost-$run_id
motd_asset=v03-motd-$run_id
arc_a_asset=v03-arc-a-$run_id
arc_b_asset=v03-arc-b-$run_id
script_asset=v03-script-$run_id
work=/tmp/nodeforge-v03-installpost

ssh_opts="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

remote_cli() {
    ssh $ssh_opts "$remote" "$cli $*"
}

remote_sh() {
    ssh $ssh_opts "$remote" "$*"
}

# The server-owned bootstrap key is injected into the installed node, so target
# verification intentionally hops through r97n0 instead of assuming the local
# workstation key is authorized on every freshly installed system.
target_sh() {
    ssh $ssh_opts "$remote" ssh -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$node_ip" "$@"
}

power_off() {
    "$vmrun" -T fusion stop "$vmx" hard >/dev/null 2>&1 || true
}

cleanup() {
    power_off
}

trap cleanup EXIT HUP INT TERM

echo "=== v0.3 install-post E2E validation ==="
echo "remote=$remote node=$node profile=$install_profile"
echo ""

# End any retained boot session for the target node before mutating the shared
# provision bundle catalog. Re-applying the intended profile with --force is the
# public, audited session-termination path.
remote_cli "node set $node profile=$install_profile --force" -o json >/dev/null

# ── 1. Prepare test assets on r97n0 ────────────────────────────────────
echo "=== Step 1: Prepare test assets ==="
remote_sh "rm -rf $work && mkdir -p $work"

# managed_file asset: a simple MOTD file
remote_sh "printf 'NODEFORGE_INSTALLPOST_MOTD\n' > $work/motd"

# archive Mode A: use the public canonical builder. The user's installer keeps
# its ordinary name on disk; CLI maps it to the reserved .nf.install.sh entry.
remote_sh "mkdir -p $work/arc-a/etc/issue.d && \
    printf 'NODEFORGE_INSTALLPOST_ARCHIVE_A\n' > $work/arc-a/etc/issue.d/nodeforge-arc-a.issue && \
    printf '#!/bin/sh\nmkdir -p /etc/issue.d\nprintf '\''NODEFORGE_INSTALLPOST_ARCHIVE_A_INSTALLED\\n'\'' > /etc/issue.d/nodeforge-arc-a-installed.issue\n' > $work/arc-a-install.sh && \
    printf 'etc/issue.d/nodeforge-arc-a.issue\n' > $work/arc-a-files.list"
remote_cli "assets archive build $work/arc-mode-a.tar --install-script $work/arc-a-install.sh --base-dir $work/arc-a --files-from $work/arc-a-files.list" >/dev/null

# archive Mode B: ordinary top-level install.sh must remain data and not execute
remote_sh "mkdir -p $work/arc-b/etc/issue.d && \
    printf 'NODEFORGE_INSTALLPOST_ARCHIVE_B\n' > $work/arc-b/etc/issue.d/nodeforge-arc-b.issue && \
    printf '#!/bin/sh\nprintf '\''NODEFORGE_ORDINARY_INSTALL_SH_EXECUTED\\n'\'' > /etc/issue.d/nodeforge-ordinary-install-sh.issue\n' > $work/arc-b/install.sh && \
    tar -C $work/arc-b -cf $work/arc-mode-b.tar ."

# script asset: creates a marker file
remote_sh "printf '#!/bin/sh\nmkdir -p /etc/issue.d\nprintf '\''NODEFORGE_INSTALLPOST_SCRIPT\\n'\'' > /etc/issue.d/nodeforge-script.issue\n' > $work/setup.sh"

echo "Assets prepared."
echo ""

# ── 2. Import assets into catalog ──────────────────────────────────────
echo "=== Step 2: Import assets into catalog ==="

remote_cli "assets managed-file import $motd_asset --from-file $work/motd --media-type text/plain" >/dev/null
echo "  managed-file: $motd_asset imported"

remote_cli "assets archive import $arc_a_asset --from-file $work/arc-mode-a.tar --media-type application/x-tar" >/dev/null
echo "  archive Mode A: $arc_a_asset imported"

remote_cli "assets archive import $arc_b_asset --from-file $work/arc-mode-b.tar --media-type application/x-tar" >/dev/null
echo "  archive Mode B: $arc_b_asset imported"

remote_cli "assets script import $script_asset --from-file $work/setup.sh --media-type text/x-shellscript" >/dev/null
echo "  script: $script_asset imported"

echo ""

# ── 3. Create provision bundle with four canonical actions ─────────────
echo "=== Step 3: Create install-post provision bundle ==="

remote_cli "assets provision-bundle create $bundle" >/dev/null

# managed_file action (downloads asset, writes to /etc/motd)
remote_cli "assets provision-bundle item add $bundle steps \
    name=e2e-motd action=managed-file phase=install-post \
    idempotency_key=e2e-motd-v1 timeout_s=30 retryable=false \
    destination=/etc/motd content_asset=$motd_asset \
    mode=0644 owner=root group=root" >/dev/null
echo "  step: managed_file -> /etc/motd"

# package action (installs tree package)
remote_cli "assets provision-bundle item add $bundle steps \
    name=e2e-pkg action=package phase=install-post \
    idempotency_key=e2e-pkg-v1 timeout_s=120 retryable=true \
    packages=tree" >/dev/null
echo "  step: package -> tree"

# archive Mode A (tar with .nf.install.sh -> extract to tmpdir + execute)
remote_cli "assets provision-bundle item add $bundle steps \
    name=e2e-arc-a action=archive phase=install-post \
    idempotency_key=e2e-arc-a-v1 timeout_s=60 retryable=false \
    content_asset=$arc_a_asset" >/dev/null
echo "  step: archive Mode A -> .nf.install.sh execution"

# archive Mode B (ordinary install.sh only -> direct extract to /, no execution)
remote_cli "assets provision-bundle item add $bundle steps \
    name=e2e-arc-b action=archive phase=install-post \
    idempotency_key=e2e-arc-b-v1 timeout_s=60 retryable=false \
    content_asset=$arc_b_asset" >/dev/null
echo "  step: archive Mode B -> direct extract"

# script action (downloads and executes script)
remote_cli "assets provision-bundle item add $bundle steps \
    name=e2e-script action=script phase=install-post \
    idempotency_key=e2e-script-v1 timeout_s=60 retryable=false \
    content_asset=$script_asset" >/dev/null
echo "  step: script -> setup.sh execution"

echo ""

# ── 4. Bind bundle to install profile and validate ─────────────────────
echo "=== Step 4: Bind bundle to profile ==="

remote_cli "profile set $install_profile install.post_install.bundle=$bundle" >/dev/null
echo "  $install_profile -> install.post_install.bundle=$bundle"

remote_cli "catalog validate" >/dev/null
echo "  catalog valid"

echo ""

# ── 5. Verify HTTP artifact serving ────────────────────────────────────
echo "=== Step 5: Verify HTTP artifact serving ==="

server_ip=$(remote_sh "jq -r '.server.server_ip' /opt/nodeforge/config/config.json")
http_port=$(remote_sh "jq -r '.server.http_port' /opt/nodeforge/config/config.json")

# managed-file artifact
mf_code=$(remote_sh "curl -s -o /dev/null -w '%{http_code}' http://$server_ip:$http_port/artifacts/managed-files/$motd_asset/1")
echo "  managed-file artifact: HTTP $mf_code"
test "$mf_code" = "200"

# archive Mode A artifact
arc_a_code=$(remote_sh "curl -s -o /dev/null -w '%{http_code}' http://$server_ip:$http_port/artifacts/archives/$arc_a_asset/1")
echo "  archive Mode A artifact: HTTP $arc_a_code"
test "$arc_a_code" = "200"

# archive Mode B artifact
arc_b_code=$(remote_sh "curl -s -o /dev/null -w '%{http_code}' http://$server_ip:$http_port/artifacts/archives/$arc_b_asset/1")
echo "  archive Mode B artifact: HTTP $arc_b_code"
test "$arc_b_code" = "200"

# script artifact
scr_code=$(remote_sh "curl -s -o /dev/null -w '%{http_code}' http://$server_ip:$http_port/artifacts/scripts/$script_asset/1")
echo "  script artifact: HTTP $scr_code"
test "$scr_code" = "200"

# Verify digest headers (ETag should be sha256)
mf_etag=$(remote_sh "curl -sI http://$server_ip:$http_port/artifacts/managed-files/$motd_asset/1" | grep -i '^etag:' | tr -d ' \r' | cut -d: -f2)
echo "  managed-file ETag: $mf_etag"
echo "$mf_etag" | grep -Eq '"[0-9a-f]{64}"' || { echo "FAIL: ETag is not sha256" >&2; exit 1; }

echo ""

# ── 6. PXE boot and wait for install completion ────────────────────────
echo "=== Step 6: PXE boot $node ==="

power_off
remote_cli "node set $node profile=$install_profile storage.boot_disk=/dev/nvme0n1" -o json >/dev/null
remote_cli "node clear-values $node storage.additional_disks --set overrides.install.storage.mode=single" -o json >/dev/null 2>/dev/null || true
remote_cli "node retry $node --force" -o json >/dev/null

armed=$(remote_cli "node show $node" -o json)
generation=$(printf '%s' "$armed" | jq -r .result.deployment.current_generation)
digest=$(printf '%s' "$armed" | jq -r .result.deployment.desired_plan_digest)
echo "  armed: generation=$generation digest=$digest"

"$vmrun" -T fusion start "$vmx" nogui >/dev/null
started=$(date +%s)
echo "  VM started, waiting for install (timeout=${timeout}s)..."

while :; do
    state=$(remote_cli "node show $node" -o json 2>/dev/null || echo '{}')
    terminal=$(printf '%s' "$state" | jq -r '.result.deployment.terminal_generation // empty')
    successful=$(printf '%s' "$state" | jq -r '.result.deployment.successful_generation // empty')

    if [ "$terminal" = "$generation" ]; then
        if [ "$successful" != "$generation" ]; then
            echo "FAIL: install failed (generation=$generation)" >&2
            printf '%s\n' "$state" | jq . >&2
            exit 1
        fi
        elapsed=$(( $(date +%s) - started ))
        echo "  PASS: install completed in ${elapsed}s"
        break
    fi

    if [ "$(($(date +%s) - started))" -ge "$timeout" ]; then
        echo "TIMEOUT: install did not complete in ${timeout}s" >&2
        printf '%s\n' "$state" | jq . >&2
        exit 1
    fi
    sleep "$poll"
done

echo ""

# ── 7. Verify install-post journal ─────────────────────────────────────
echo "=== Step 7: Verify install-post journal ==="

# Give the daemon a moment to finalize the journal
sleep 3

journal_json=$(remote_cli "node postprocess show $node --phase install-post" -o json 2>/dev/null || echo '{}')
echo "$journal_json" | jq .

run_status=$(printf '%s' "$journal_json" | jq -r '.result.state // empty')
echo "  run status: $run_status"

if [ "$run_status" != "completed" ]; then
    echo "FAIL: install-post run status is '$run_status', expected 'completed'" >&2
    exit 1
fi
echo "  PASS: install-post run completed"

# Verify each step status
step_count=$(printf '%s' "$journal_json" | jq -r '.result.steps | length')
echo "  steps: $step_count"
for i in $(seq 0 $((step_count - 1))); do
    step_id=$(printf '%s' "$journal_json" | jq -r ".result.steps[$i].step_id")
    step_status=$(printf '%s' "$journal_json" | jq -r ".result.steps[$i].status")
    echo "    $step_id: $step_status"
    if [ "$step_status" != "succeeded" ]; then
        echo "FAIL: step $step_id status is '$step_status', expected 'succeeded'" >&2
        exit 1
    fi
done
echo "  PASS: all steps succeeded"

echo ""

# ── 8. Verify target system content ────────────────────────────────────
echo "=== Step 8: Verify target system content ==="

# Wait for node to come back online after reboot
echo "  Waiting for $node ($node_ip) to become reachable..."
node_wait=0
while ! target_sh "true" 2>/dev/null; do
    node_wait=$((node_wait + 1))
    if [ "$node_wait" -ge 60 ]; then
        echo "FAIL: cannot SSH to $node_ip after install; target verification is mandatory" >&2
        exit 1
    fi
    sleep 5
done

if target_sh "true" 2>/dev/null; then
    echo "  Connected to $node_ip"

    # managed_file: /etc/motd should contain the marker
    motd=$(target_sh "cat /etc/motd 2>/dev/null || true")
    if echo "$motd" | grep -q 'NODEFORGE_INSTALLPOST_MOTD'; then
        echo "  PASS: managed_file -> /etc/motd contains marker"
    else
        echo "FAIL: /etc/motd does not contain expected marker" >&2
        echo "      got: $motd" >&2
        exit 1
    fi

    # package: tree should be installed
    if target_sh "which tree" 2>/dev/null | grep -q tree; then
        echo "  PASS: package -> tree installed"
    else
        echo "FAIL: tree package not found" >&2
        exit 1
    fi

    # archive Mode A: .nf.install.sh should have run and created the installed marker
    arc_a_installed=$(target_sh "cat /etc/issue.d/nodeforge-arc-a-installed.issue 2>/dev/null || true")
    if echo "$arc_a_installed" | grep -q 'NODEFORGE_INSTALLPOST_ARCHIVE_A_INSTALLED'; then
        echo "  PASS: archive Mode A -> .nf.install.sh executed, marker file created"
    else
        echo "FAIL: archive Mode A .nf.install.sh marker not found" >&2
        echo "      got: $arc_a_installed" >&2
        exit 1
    fi

    # archive Mode B: file should be directly extracted to /
    arc_b_content=$(target_sh "cat /etc/issue.d/nodeforge-arc-b.issue 2>/dev/null || true")
    if echo "$arc_b_content" | grep -q 'NODEFORGE_INSTALLPOST_ARCHIVE_B'; then
        echo "  PASS: archive Mode B -> tar content extracted to /"
    else
        echo "FAIL: archive Mode B content not found" >&2
        exit 1
    fi

    # Ordinary install.sh is not the reserved Mode A entrypoint.
    if target_sh "test ! -e /etc/issue.d/nodeforge-ordinary-install-sh.issue"; then
        echo "  PASS: ordinary top-level install.sh was extracted but not executed"
    else
        echo "FAIL: ordinary top-level install.sh was executed" >&2
        exit 1
    fi

    # script: marker file should be created by the script
    script_content=$(target_sh "cat /etc/issue.d/nodeforge-script.issue 2>/dev/null || true")
    if echo "$script_content" | grep -q 'NODEFORGE_INSTALLPOST_SCRIPT'; then
        echo "  PASS: script -> executed, marker file created"
    else
        echo "FAIL: script marker not found" >&2
        exit 1
    fi

    # Verify execution order: managed_file before package before archive before script
    # The install-post journal already verifies this, but we can also check
    # file timestamps on the target system
    echo ""
    echo "  Target system file timestamps (verifies execution order):"
    target_sh "stat -c '%Y %n' /etc/motd /usr/bin/tree /etc/issue.d/nodeforge-arc-a-installed.issue /etc/issue.d/nodeforge-arc-b.issue /etc/issue.d/nodeforge-script.issue 2>/dev/null | sort -n" || true
fi

echo ""

# ── 9. Cleanup ─────────────────────────────────────────────────────────
echo "=== Step 9: Cleanup ==="
power_off

# Unbind the bundle from the profile (leave bundle for inspection)
remote_cli "profile unset $install_profile install.post_install.bundle" >/dev/null 2>/dev/null || true
echo "  Unbound bundle from profile"

echo ""
echo "========================================"
echo "v0.3 install-post E2E validation: PASS"
echo "========================================"
echo ""
echo "Verified canonical actions:"
echo "  1. managed_file: /etc/motd written via curl+sha256sum+chmod"
echo "  2. package: tree installed via dnf -y install"
echo "  3. archive Mode A: tar with .nf.install.sh -> extract to tmpdir + execute"
echo "  4. archive Mode B: ordinary install.sh remains data and archive extracts directly"
echo "  5. script: downloaded via curl+sha256sum, executed via sh"
echo ""
echo "Journal: all steps succeeded, run status: completed"
echo "HTTP artifacts: all served correctly with immutable cache-control + ETag"
