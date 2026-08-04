#!/bin/sh
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

# v0.4 credential contract: install/diskless reads use one volatile
# boot-session capability. Removed per-scope audiences must not survive in
# product binaries, and diskless handoff uses a capability-named 0400 file.
legacy_scopes='builder-plan:read|builder-input:read|builder-upload:write|builder-event:append|config:read|rootfs:read|agent:read'
for binary in "$bundle/nodeforged" "$bundle/nodeforge-initrd" "$bundle/nodeforge-agent"; do
    if strings "$binary" | grep -E "$legacy_scopes" >/dev/null; then
        echo "legacy per-scope token audience found in $binary" >&2
        exit 1
    fi
done
if strings "$bundle/nodeforge-initrd" "$bundle/nodeforge-agent" | grep -F 'credentials/agent.token' >/dev/null; then
    echo 'legacy diskless agent.token credential path found in product binaries' >&2
    exit 1
fi
strings "$bundle/nodeforge-initrd" | grep -Fq 'credentials/capability.token'
strings "$bundle/nodeforge-agent" | grep -Fq 'credentials/capability.token'
strings "$bundle/nodeforged" | grep -Fq 'X-NodeForge-Session'

# Fixed large-object data paths are deliberately token-free. Keep this as a
# source-level gate because the binaries legitimately contain Authorization
# strings for event writes and AgentPlan control-plane reads.
rootfs_client_block=$(sed -n '/^fn downloadRootfs(/,/^}/p; /^fn rangeOnce(/,/^}/p' "$repo_root/src/initrd.zig")
if printf '%s\n' "$rootfs_client_block" | grep -E 'Authorization|X-NodeForge-Session|access_bearer_token' >/dev/null; then
    echo 'rootfs client data path propagates a capability header' >&2
    exit 1
fi
rootfs_server_block=$(sed -n '/^fn disklessRootfs(/,/^}/p; /^fn disklessPayload(/,/^}/p' "$repo_root/src/http/server.zig")
printf '%s\n' "$rootfs_server_block" | grep -Fq 'authenticateWebhook'
if printf '%s\n' "$rootfs_server_block" | grep -E 'getHeader\("authorization"\)|getHeader\("x-nodeforge-session"\)' >/dev/null; then
    echo 'rootfs/payload server data path accepts capability headers' >&2
    exit 1
fi
if strings "$bundle/nodeforged" | grep -Fq 'http_headers'; then
    echo 'DNF repository header injection survived in nodeforged' >&2
    exit 1
fi

# rootfs is server-only. No product binary may expose a node/PXE builder mode,
# attempt API, placement property, upload/finalize path, or builder CLI.
for forbidden in 'nodeforge.builder' '/api/v1/builder-attempts/' '/rootfs/register' 'Register a prebuilt rootfs' 'built or registered after the Profile' 'builder.placement' 'builder.eligible' 'BuilderEnvironment' 'BuilderBootAttempt' 'BuilderPlan'; do
    if strings "$bundle/nodeforge" "$bundle/nodeforged" "$bundle/nodeforge-initrd" "$bundle/nodeforge-agent" | grep -Fq "$forbidden"; then
        echo "removed node-builder contract found: $forbidden" >&2
        exit 1
    fi
done

# The first-boot protocol keeps replay, expiry, canonical-body drift, and CAS
# conflict distinct.  Losing one of these stable codes would collapse operator
# diagnostics back into the former replay catch-all.
for code in first_boot.binding_mismatch first_boot.event_invalid first_boot.event_body_drift first_boot.event_conflict first_boot.replay; do
    strings "$bundle/nodeforged" | grep -Fq "$code"
done

test "$(printf '%s\n' "$($run_cli --version)" | awk '{print $1" "$2}')" = "nodeforge 0.4.0"
install=$tmp/install
$run_cli setup --install-root "$install" --non-interactive --yes >"$tmp/setup.json"
test "$(jq -r '.schema_version' "$install/config/config.json")" = 5
test "$(jq -r '.catalog_schema_version' "$install/catalog/manifest.json")" = 6
test "$(sed -n '1p' "$install/.nodeforge-root" | cut -d ' ' -f 1)" = nodeforge-root-v2

help=$tmp/help
$run_cli --install-root "$install" node topology --help-full >"$help"
grep -Fq 'topology' "$help"
$run_cli --install-root "$install" node discovery --help-full >>"$help"
grep -Fq 'discovery' "$help"
$run_cli --install-root "$install" node postprocess show --help-full >>"$help"
grep -Fq 'first-boot' "$help"
# v0.4 rootfs is built only through the nodeforged management operation.
$run_cli --install-root "$install" profile rootfs build --help-full >>"$help"
grep -Fq 'content-addressed rootfs artifact' "$help"
grep -Fq -- '--detach' "$help"
if $run_cli --install-root "$install" builder --help-full >"$tmp/builder.out" 2>"$tmp/builder.err"; then
    echo 'removed builder command is still callable' >&2
    exit 1
fi
if $run_cli --install-root "$install" profile rootfs register --help-full >"$tmp/rootfs-register.out" 2>"$tmp/rootfs-register.err"; then
    echo 'external rootfs register command is still callable' >&2
    exit 1
fi

cat >"$tmp/topology.json" <<'JSON'
{"interfaces":[{"id":"eno1","mac":"02:00:00:00:00:01","ipv4":{"mode":"dhcp"}}],"bonds":[],"vlans":[],"routes":[]}
JSON
$run_cli --install-root "$install" node topology validate --network-json "$tmp/topology.json" --bootstrap-mac 02:00:00:00:00:01 --deploy -o json >"$tmp/topology.out"
jq -e '.ok and .result.deployable' "$tmp/topology.out" >/dev/null

cat >"$tmp/invalid-topology.json" <<'JSON'
{"interfaces":[{"id":"eno1","mac":"02:00:00:00:00:01","ipv4":{"mode":"dhcp"}},{"id":"eno2","mac":"02:00:00:00:00:02","ipv4":{"mode":"dhcp"}}],"bonds":[],"vlans":[],"routes":[]}
JSON
if $run_cli --install-root "$install" node topology validate --network-json "$tmp/invalid-topology.json" --bootstrap-mac 02:00:00:00:00:01 --deploy -o json >"$tmp/invalid.out" 2>"$tmp/invalid.err"; then
    echo 'invalid topology unexpectedly passed' >&2
    exit 1
fi
grep -Fq 'network.invalid' "$tmp/invalid.out" "$tmp/invalid.err"

if grep -R -E 'Bearer [0-9a-f]{64}|Authorization:|token[=:][^" ]+' "$install/catalog" "$install/state" "$install/logs" 2>/dev/null; then
    echo 'raw capability material found in persistent layout' >&2
    exit 1
fi

printf '%s\n' 'v0.4 contract gate: PASS'
