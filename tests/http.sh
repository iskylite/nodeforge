#!/bin/sh
set -eu

if [ "$(uname -s)" = Darwin ]; then
    exit 0
fi

cli=$1
daemon=$2
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/nodeforge-http-test-$$
port=$((20000 + ($$ % 10000)))
install=$tmp/install
pid=

cleanup() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp/bundle"
cp "$cli" "$tmp/bundle/nodeforge"
cp "$daemon" "$tmp/bundle/nodeforged"

"$tmp/bundle/nodeforge" setup --install-root "$install" --non-interactive --yes \
    --bind-interface lo --server-ip 127.0.0.1 --http-port "$port" \
    --subnet 127.0.0.0/24 --pool-start 127.0.0.100 --pool-end 127.0.0.200 >"$tmp/setup.out"
cli=$install/bin/nodeforge
daemon=$install/bin/nodeforged

test "$(jq -r .schema_version "$install/config/config.json")" = 4
test "$(jq -r .catalog_schema_version "$install/catalog/manifest.json")" = 4
test "$(jq -r .unknown_action "$install/catalog/discovery_policy.json")" = record

publish_entity() {
    name=$1
    digest=$(sha256sum "$install/catalog/$name.json" | cut -d ' ' -f 1)
    jq --arg name "$name" --arg digest "$digest" '(.entities[] | select(.name == $name) | .sha256) = $digest' "$install/catalog/manifest.json" >"$tmp/manifest"
    mv "$tmp/manifest" "$install/catalog/manifest.json"
}
jq '.distros' "$repo/catalog.example.json" >"$install/catalog/distros.json"
jq --arg base "http://127.0.0.1:$port/artifacts/repositories" '.repositories | map(
    .base_url = ($base + "/" + .name)
    | .software_index = {
        revision_digest: "fixture-index-v1",
        capabilities: [
            {id: "core", name: "Core environment", kind: "environment", description: "Minimal operating system"},
            {id: "bash", name: "Bash", kind: "package", description: "GNU Bourne Again shell"}
        ]
    }
)' "$repo/catalog.example.json" >"$install/catalog/repositories.json"
jq '.install_sources' "$repo/catalog.example.json" >"$install/catalog/install_sources.json"
jq '.assets' "$repo/catalog.example.json" >"$install/catalog/assets.json"
for entity in distros repositories install_sources assets; do publish_entity "$entity"; done
transaction_id=$(
    {
        jq -r .catalog_revision "$install/catalog/manifest.json" | tr -d '\n'
        jq -r '.entities[] | .name + .sha256' "$install/catalog/manifest.json" | tr -d '\n'
    } | sha256sum | cut -d ' ' -f 1
)
jq --arg transaction_id "$transaction_id" '.transaction_id = $transaction_id' "$install/catalog/manifest.json" >"$tmp/manifest"
mv "$tmp/manifest" "$install/catalog/manifest.json"

"$daemon" -c "$install/config/config.json" -C "$install/catalog" >"$tmp/daemon.out" 2>"$tmp/daemon.err" &
pid=$!
ready=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    if curl --silent --fail "http://127.0.0.1:$port/healthz" >"$tmp/health"; then
        ready=true
        break
    fi
    sleep 0.1
done
if [ "$ready" != true ]; then
    cat "$tmp/daemon.err" >&2
    exit 1
fi
grep -Fqx '{"ok":true,"service":"nodeforge"}' "$tmp/health"

curl --silent --fail "http://127.0.0.1:$port/api/v1/management/config" >"$tmp/config"
jq -e '.ok and .result.config == "valid"' "$tmp/config" >/dev/null
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/discovery/policy" >"$tmp/policy"
jq -e '.ok and .result.unknown_action == "record" and .result.observation_retention_days == 30' "$tmp/policy" >/dev/null
"$cli" runtime tftp-counters -o json --fields started,failed >"$tmp/tftp-show-json"
jq -e '.ok and .result.started == 0 and .result.failed == 0 and (.result | keys | sort) == ["failed", "started"]' "$tmp/tftp-show-json" >/dev/null
"$cli" runtime tftp-sessions -o json >"$tmp/tftp-sessions-json"
jq -e '.ok and (.result.sessions | length) == 0' "$tmp/tftp-sessions-json" >/dev/null
"$cli" runtime dhcp-leases -o json >"$tmp/dhcp-leases-json"
jq -e '.ok and (.result.leases | length) == 0' "$tmp/dhcp-leases-json" >/dev/null
"$cli" discovery list -o json >"$tmp/discovery-list-json"
jq -e '.ok and (.result.items | length) == 0' "$tmp/discovery-list-json" >/dev/null
"$cli" discovery policy show -o json --fields unknown_action >"$tmp/discovery-policy-json"
jq -e '.ok and .result.unknown_action == "record" and (.result | keys) == ["unknown_action"]' "$tmp/discovery-policy-json" >/dev/null
if "$cli" discovery policy show --fields missing >"$tmp/discovery-policy-bad.out" 2>"$tmp/discovery-policy-bad.err"; then
    echo 'discovery policy accepted unknown field' >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/discovery-policy-bad.out"
grep -Fq 'unknown key' "$tmp/discovery-policy-bad.err"

"$cli" assets install-source list >"$tmp/source-list"
grep -Fq 'rocky-9.7-aarch64-dvd' "$tmp/source-list"
"$cli" assets install-source list --columns name,arch --no-header >"$tmp/source-list-columns"
grep -Eq '^rocky-9.7-aarch64-dvd[[:space:]]+aarch64$' "$tmp/source-list-columns"
"$cli" assets install-source list -o jsonl >"$tmp/source-list-jsonl"
jq -e '.ok and .result.name == "rocky-9.7-aarch64-dvd"' "$tmp/source-list-jsonl" >/dev/null
"$cli" assets install-source show rocky-9.7-aarch64-dvd -o json >"$tmp/source-show"
jq -e '.ok and .result.install_source.name == "rocky-9.7-aarch64-dvd"' "$tmp/source-show" >/dev/null
"$cli" assets install-source show rocky-9.7-aarch64-dvd --fields name,source_asset >"$tmp/source-show-fields"
grep -Fq $'name\trocky-9.7-aarch64-dvd' "$tmp/source-show-fields"
if grep -Fq 'installer_kernel' "$tmp/source-show-fields"; then
    echo 'install-source field filter retained installer_kernel' >&2
    exit 1
fi
"$cli" assets repository list >"$tmp/repository-list"
grep -Fq 'rocky-9.7-aarch64-dvd' "$tmp/repository-list"
"$cli" assets repository show rocky-9.7-aarch64-dvd -o json >"$tmp/repository-show"
jq -e '.ok and .result.repository.name == "rocky-9.7-aarch64-dvd"' "$tmp/repository-show" >/dev/null
"$cli" assets repository show rocky-9.7-aarch64-dvd -o json --fields name,manager >"$tmp/repository-show-fields"
jq -e '.ok and .result.repository.name == "rocky-9.7-aarch64-dvd" and .result.repository.manager and (.result | keys) == ["repository"] and (.result.repository | keys | sort) == ["manager", "name"]' "$tmp/repository-show-fields" >/dev/null
if "$cli" assets repository show rocky-9.7-aarch64-dvd --fields missing >"$tmp/repository-show-bad.out" 2>"$tmp/repository-show-bad.err"; then
    echo 'repository show accepted unknown field' >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/repository-show-bad.out"
grep -Fq 'unknown key' "$tmp/repository-show-bad.err"
"$cli" assets repository software list rocky-9.7-aarch64-dvd --kind package --wide >"$tmp/repository-software"
grep -Fq 'REVISION' "$tmp/repository-software"
"$cli" assets repository software list rocky-9.7-aarch64-dvd --kind package -o json >"$tmp/repository-software-json"
jq -e '.ok and (.result.items | length) > 0 and .result.items[0].capability.id' "$tmp/repository-software-json" >/dev/null
software_id=$(jq -r '.result.items[0].capability.id' "$tmp/repository-software-json")
software_kind=$(jq -r '.result.items[0].capability.kind' "$tmp/repository-software-json")
"$cli" assets repository software list rocky-9.7-aarch64-dvd --kind package -o jsonl >"$tmp/repository-software-jsonl"
jq -e '.ok and .result.repository and .result.capability.id' "$tmp/repository-software-jsonl" >/dev/null
"$cli" assets repository software show rocky-9.7-aarch64-dvd "$software_id" --kind "$software_kind" --sections stored --fields id,kind,repository >"$tmp/repository-software-show"
grep -Fq $'id\t'"$software_id" "$tmp/repository-software-show"
"$cli" assets repository software show rocky-9.7-aarch64-dvd "$software_id" --kind "$software_kind" -o json --fields id,revision >"$tmp/repository-software-show-json"
jq -e --arg id "$software_id" '.ok and .result.capability.id == $id and .result.index_digest and (.result | keys | sort) == ["capability", "index_digest"]' "$tmp/repository-software-show-json" >/dev/null

"$cli" profile create contract-profile rocky-9.7-aarch64-dvd >"$tmp/profile-create"
"$cli" profile list --columns name,source --no-header >"$tmp/profile-list"
grep -Fq 'contract-profile' "$tmp/profile-list"
"$cli" profile list -o jsonl >"$tmp/profile-list-jsonl"
jq -e '.ok and .result.name == "contract-profile" and .result.install_source == "rocky-9.7-aarch64-dvd"' "$tmp/profile-list-jsonl" >/dev/null
"$cli" node add contract-node mac=02:00:00:00:00:42 arch=aarch64 profile=contract-profile pxe.ip_reservation=192.168.27.210 deploy=false >"$tmp/node-add"
"$cli" node replace-values contract-node storage.additional_disks /dev/sdb --set overrides.install.storage.mode=raid1 -o json >"$tmp/node-storage-atomic"
jq -e '.ok and .result.operation == "replace"' "$tmp/node-storage-atomic" >/dev/null
"$cli" node show contract-node -o json >"$tmp/node-storage-atomic-show"
jq -e '.result.storage.effective.mode == "raid1" and .result.storage.effective.members == ["/dev/sda", "/dev/sdb"]' "$tmp/node-storage-atomic-show" >/dev/null
"$cli" node clear-values contract-node storage.additional_disks --set overrides.install.storage.mode=single -o json >/dev/null
"$cli" profile software show contract-profile --sections stored --fields software.repositories,software.packages.include >"$tmp/profile-software-show"
grep -Fqx 'Stored' "$tmp/profile-software-show"
grep -Fq 'software.repositories' "$tmp/profile-software-show"
"$cli" profile software show contract-profile -o json --fields software.repositories >"$tmp/profile-software-show-json"
jq -e '.ok and .result.software.repositories and (.result | keys) == ["software"] and (.result.software | keys) == ["repositories"]' "$tmp/profile-software-show-json" >/dev/null
"$cli" node software show contract-node --sections effective --fields effective.software.repositories,effective.software.packages.include >"$tmp/node-software-show"
grep -Fqx 'Effective' "$tmp/node-software-show"
if grep -Fq 'Overrides' "$tmp/node-software-show"; then
    echo 'node software section filter retained overrides' >&2
    exit 1
fi
"$cli" node software show contract-node -o json --fields effective.software.repositories >"$tmp/node-software-show-json"
jq -e '.ok and .result.effective_software.repositories and (.result | keys) == ["effective_software"] and (.result.effective_software | keys) == ["repositories"]' "$tmp/node-software-show-json" >/dev/null
"$cli" profile show contract-profile --sections stored --fields name,install_source >"$tmp/profile-show-fields"
grep -Fqx 'Stored:' "$tmp/profile-show-fields"
grep -Eq '^  name +contract-profile$' "$tmp/profile-show-fields"
if grep -Fq 'Effective' "$tmp/profile-show-fields"; then
    echo 'profile show section filter retained effective fields' >&2
    exit 1
fi
"$cli" profile show contract-profile -o json --fields name,system.localization.locale >"$tmp/profile-show-json-fields"
jq -e '.ok and .result.name == "contract-profile" and .result.effective_system.localization.locale and (.result | keys | sort) == ["effective_system", "name"]' "$tmp/profile-show-json-fields" >/dev/null
if "$cli" profile show contract-profile --fields missing >"$tmp/profile-show-bad-field.out" 2>"$tmp/profile-show-bad-field.err"; then
    echo 'profile show accepted an unknown field' >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/profile-show-bad-field.out"
grep -Fq 'unknown key' "$tmp/profile-show-bad-field.err"
code=$(curl --silent -o "$tmp/node-list-api" -w '%{http_code}' "http://127.0.0.1:$port/api/v1/management/nodes")
if [ "$code" != 200 ]; then
    cat "$tmp/node-list-api" >&2
    exit 1
fi
jq -e '.ok and .result.items[0].id == "contract-node" and .result.items[0].pxe.ip_reservation == "192.168.27.210" and (.result.items[0] | has("ip") | not)' "$tmp/node-list-api" >/dev/null
code=$(curl --silent -o "$tmp/node-show-api" -w '%{http_code}' "http://127.0.0.1:$port/api/v1/management/nodes/contract-node")
if [ "$code" != 200 ]; then
    cat "$tmp/node-show-api" >&2
    exit 1
fi
jq -e '.ok and .result.node.pxe.ip_reservation == "192.168.27.210" and .result.node.network.interface_name == null and (.result.node | has("ip") | not) and (.result.node.network | has("interface") | not) and (.result.node.overrides.install | has("apt_fallback") | not)' "$tmp/node-show-api" >/dev/null
"$cli" node show contract-node --sections stored --fields id,mac,profile >"$tmp/node-show-fields"
grep -Fqx 'Stored:' "$tmp/node-show-fields"
grep -Eq '^  id +contract-node$' "$tmp/node-show-fields"
if grep -Fq 'Runtime' "$tmp/node-show-fields"; then
    echo 'node show section filter retained runtime fields' >&2
    exit 1
fi
"$cli" node show contract-node -o json --fields id,effective.system.localization.locale >"$tmp/node-show-json-fields"
jq -e '.ok and .result.node.id == "contract-node" and .result.effective_system.localization.locale and (.result | keys | sort) == ["effective_system", "node"]' "$tmp/node-show-json-fields" >/dev/null
if "$cli" node show contract-node --sections commands >"$tmp/node-show-bad-section.out" 2>"$tmp/node-show-bad-section.err"; then
    echo 'node show accepted an unknown section' >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/node-show-bad-section.out"
grep -Fq 'unknown key' "$tmp/node-show-bad-section.err"
"$cli" node list --columns id,mac,profile,deploy --no-header >"$tmp/node-list"
grep -Eq '^contract-node[[:space:]]+02:00:00:00:00:42[[:space:]]+contract-profile[[:space:]]+no[[:space:]]*$' "$tmp/node-list"
"$cli" node list -o jsonl >"$tmp/node-list-jsonl"
jq -e '.ok and .result.id == "contract-node" and .result.profile == "contract-profile" and (.result.deploy | not)' "$tmp/node-list-jsonl" >/dev/null
"$cli" profile item add contract-profile system.users name=ops sudo=true >"$tmp/user-add"
"$cli" profile item add-values contract-profile system.users ops groups wheel adm >"$tmp/user-groups"
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey contract' >"$tmp/ops.keys"
"$cli" profile item replace-values contract-profile system.users ops ssh_authorized_keys --from-file "$tmp/ops.keys" >"$tmp/user-keys"
"$cli" profile item list-values contract-profile system.users ops groups --no-header >"$tmp/user-groups-list"
grep -Eq '^wheel[[:space:]]*$' "$tmp/user-groups-list"
grep -Eq '^adm[[:space:]]*$' "$tmp/user-groups-list"
"$cli" profile item list contract-profile system.users -o jsonl >"$tmp/user-item-list-jsonl"
jq -e 'select(.result.name == "ops") | .ok and .result.sudo' "$tmp/user-item-list-jsonl" >/dev/null
"$cli" profile item show contract-profile system.users ops --fields name,sudo >"$tmp/user-item-show"
grep -Fq $'name\tops' "$tmp/user-item-show"
if grep -Fq 'password' "$tmp/user-item-show"; then
    echo 'item show field filter retained password' >&2
    exit 1
fi
"$cli" profile item show contract-profile system.users ops -o json --fields name,sudo >"$tmp/user-item-show-json"
jq -e '.ok and .result.name == "ops" and .result.sudo and (.result | keys | sort) == ["name", "sudo"]' "$tmp/user-item-show-json" >/dev/null
"$cli" profile capabilities show contract-profile --columns domain,status --width 80 >"$tmp/profile-capabilities"
grep -Fq 'install.storage' "$tmp/profile-capabilities"
grep -Fq 'native' "$tmp/profile-capabilities"
if "$cli" profile capabilities show contract-profile -o jsonl >"$tmp/profile-capabilities-jsonl.out" 2>"$tmp/profile-capabilities-jsonl.err"; then
    echo 'detail command unexpectedly accepted jsonl' >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/profile-capabilities-jsonl.out"
grep -Fq 'output mode is not supported' "$tmp/profile-capabilities-jsonl.err"
if "$cli" profile capabilities show contract-profile --columns missing >"$tmp/profile-capabilities-column.out" 2>"$tmp/profile-capabilities-column.err"; then
    echo 'capabilities accepted an unknown column' >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/profile-capabilities-column.out"
grep -Fq 'unknown key' "$tmp/profile-capabilities-column.err"
if "$cli" profile capabilities show contract-profile --width 80 --wide >"$tmp/profile-capabilities-width.out" 2>"$tmp/profile-capabilities-width.err"; then
    echo 'capabilities accepted mutually exclusive width options' >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/profile-capabilities-width.out"
grep -Fq 'mutually exclusive' "$tmp/profile-capabilities-width.err"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/profiles/contract-profile/capabilities" >"$tmp/profile-capabilities-api"
jq -e '.ok and .result.readiness.install == "ready" and any(.result.properties[]; .key == "install.storage.mode" and .status == "native") and any(.result.properties[]; .key == "install.apt.fallback" and .status == "not_applicable")' "$tmp/profile-capabilities-api" >/dev/null

code=$(curl --silent -o "$tmp/stale" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H 'If-Match: "0"' \
    -d '{"name":"stale"}' "http://127.0.0.1:$port/api/v1/management/assets/provision-bundles")
test "$code" = 409
jq -e '.error.code == "catalog.revision_conflict"' "$tmp/stale" >/dev/null

printf 'NodeForge managed file\n' >"$tmp/motd"
"$cli" assets managed-file import site-motd --from-file "$tmp/motd" --media-type text/plain >"$tmp/import"
grep -Fq 'revision 1' "$tmp/import"
"$cli" assets managed-file show site-motd -o json >"$tmp/managed-show"
jq -e '.ok and .result.name == "site-motd" and .result.kind == "managed_file" and .result.revision == 1 and .result.size == 23' "$tmp/managed-show" >/dev/null
"$cli" assets managed-file list --columns name,revision,size --no-header >"$tmp/managed-list"
grep -Eq '^site-motd[[:space:]]+1[[:space:]]+23$' "$tmp/managed-list"
"$cli" assets managed-file list -o json >"$tmp/managed-list-json"
jq -e '.ok and .result.items[0].name == "site-motd" and .result.items[0].revision == 1' "$tmp/managed-list-json" >/dev/null
"$cli" assets managed-file list -o jsonl >"$tmp/managed-list-jsonl"
jq -e '.ok and .result.name == "site-motd" and .result.size == 23' "$tmp/managed-list-jsonl" >/dev/null
"$cli" assets managed-file show site-motd --fields name,revision >"$tmp/managed-show-fields"
grep -Fq 'name' "$tmp/managed-show-fields"
grep -Fq 'revision' "$tmp/managed-show-fields"
if grep -Fq 'sha256' "$tmp/managed-show-fields"; then
    echo 'managed-file field filter retained sha256' >&2
    exit 1
fi
"$cli" assets managed-file show site-motd --sections stored --fields name >"$tmp/managed-show-section"
grep -Fqx 'Stored' "$tmp/managed-show-section"
if "$cli" assets managed-file show site-motd --sections runtime >"$tmp/managed-show-bad-section.out" 2>"$tmp/managed-show-bad-section.err"; then
    echo 'managed-file show accepted an unknown section' >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/managed-show-bad-section.out"
grep -Fq 'unknown key' "$tmp/managed-show-bad-section.err"
if "$cli" assets managed-file show site-motd -o jsonl >"$tmp/managed-show-jsonl.out" 2>"$tmp/managed-show-jsonl.err"; then
    echo 'managed-file detail unexpectedly accepted jsonl' >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/managed-show-jsonl.out"
grep -Fq 'output mode is not supported' "$tmp/managed-show-jsonl.err"

"$cli" assets provision-bundle create base-site >"$tmp/bundle-create"
"$cli" assets provision-bundle item add base-site steps \
    name=motd action=managed-file destination=/etc/motd content_asset=site-motd mode=0644 owner=root group=root >"$tmp/step-add"
"$cli" assets provision-bundle item show base-site steps motd -o json >"$tmp/step-show"
jq -e '.ok and .result.name == "motd" and .result.content_asset == "site-motd"' "$tmp/step-show" >/dev/null

curl --silent --fail -D "$tmp/artifact-headers" "http://127.0.0.1:$port/artifacts/managed-files/site-motd/1" >"$tmp/artifact"
cmp "$tmp/motd" "$tmp/artifact"
grep -Eqi '^cache-control:.*immutable' "$tmp/artifact-headers" || { cat "$tmp/artifact-headers" >&2; exit 1; }
grep -Eqi '^etag:[[:space:]]*"[0-9a-f]{64}"' "$tmp/artifact-headers"
code=$(curl --silent -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/artifacts/managed-files/site-motd/0")
test "$code" = 404

if "$cli" assets managed-file remove site-motd >"$tmp/remove-in-use" 2>&1; then
    echo 'managed-file remove accepted an in-use asset' >&2
    exit 1
fi
grep -Fq 'AssetInUse' "$tmp/remove-in-use"
"$cli" assets provision-bundle item remove base-site steps motd >"$tmp/step-remove"
"$cli" assets managed-file remove site-motd >"$tmp/remove"
test "$(jq '[.[] | select(.name == "site-motd")] | length' "$install/catalog/assets.json")" = 0
test -f "$install/assets/managed-files/site-motd/1"
code=$(curl --silent -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/artifacts/managed-files/site-motd/1")
test "$code" = 404

"$cli" assets provision-bundle remove base-site >"$tmp/bundle-remove"

# An armed deployment returns a non-null deployment object. Keep the CLI DTO
# aligned with the daemon's canonical `armed_at` field.
"$cli" node retry contract-node --force >"$tmp/node-retry"
"$cli" node show contract-node -o json >"$tmp/node-show-armed"
jq -e '.ok and .result.deployment.install_intent == "retry-armed" and .result.deployment.pxe_ready == true and (.result.deployment.requested_plan_digest == .result.deployment.desired_plan_digest) and (.result.deployment.armed_at > 0)' "$tmp/node-show-armed" >/dev/null

"$cli" catalog validate >"$tmp/validate"
grep -Fq 'catalog valid' "$tmp/validate"

kill -0 "$pid"
