#!/bin/sh
set -eu

cli=$1
daemon=$2
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

bundle="$tmp/bundle"
install="$tmp/custom-nodeforge"
mkdir -p "$bundle"
cp "$cli" "$bundle/nodeforge"
cp "$daemon" "$bundle/nodeforged"

"$bundle/nodeforge" setup --install-root "$install" --non-interactive --yes >"$tmp/init.out"
grep -Fq 'NodeForge initialized' "$tmp/init.out"
test -f "$install/.nodeforge-root"
test -x "$install/bin/nodeforge"
test -x "$install/bin/nodeforged"
test "$(jq -r .schema_version "$install/config/config.json")" = 2
test "$(jq -r .layout_schema_version "$install/catalog/manifest.json")" = 1
test "$(mode "$install/config/config.json")" = 600
test "$(mode "$install/catalog/manifest.json")" = 600
test "$(mode "$install/config")" = 700
test "$(mode "$install/assets")" = 750
install_real=$(CDPATH= cd -- "$install" && pwd -P)
for entity in distros profiles nodes provisioning_bundles repositories assets install_sources boot_bundles; do
    test -f "$install/catalog/$entity.json"
done
grep -Fq "ExecStart=$install_real/bin/nodeforged --log-output file" "$install/systemd/nodeforged.service"
if grep -Fq -- '--config' "$install/systemd/nodeforged.service"; then
    echo "generated systemd unit must use discovered paths without --config" >&2
    exit 1
fi

"$install/bin/nodeforge" setup --generate-systemd --print >"$tmp/unit"
grep -Fq "WorkingDirectory=$install_real" "$tmp/unit"
"$install/bin/nodeforge" setup --reconfigure --non-interactive --yes >"$tmp/reconfigure"
grep -Fq 'deployment reconfigured' "$tmp/reconfigure"

printf '%s\n' '{"schema_version":1}' >"$install/state/leases.json"
"$install/bin/nodeforge" setup --reset-state --non-interactive --yes >"$tmp/reset"
test ! -f "$install/state/leases.json"
backup=$(sed -n 's/^  Backup[[:space:]]*//p' "$tmp/reset")
test -n "$backup"
test -f "$backup/leases.json"
test "$(jq -r '.files[0].file' "$backup/manifest.json")" = leases.json
test "$(jq -r '.files[0].sha256 | length' "$backup/manifest.json")" = 64

# A partial bundle cannot produce a valid marker or claim initialization.
partial="$tmp/partial"
broken="$tmp/broken-root"
mkdir -p "$partial"
cp "$cli" "$partial/nodeforge"
if "$partial/nodeforge" setup --install-root "$broken" --non-interactive --yes >"$tmp/broken.out" 2>&1; then
    echo "partial bundle unexpectedly initialized" >&2
    exit 1
fi
test ! -e "$broken/.nodeforge-root"

# Schema-1 config + monolithic catalog migrate without losing catalog facts.
legacy="$tmp/legacy"
mkdir -p "$legacy/bin" "$legacy/config" "$legacy/catalog"
cp "$cli" "$legacy/bin/nodeforge"
cp "$daemon" "$legacy/bin/nodeforged"
: >"$legacy/.nodeforge-root"
jq --slurpfile catalog "$repo/catalog.example.json" '.schema_version=1 | .distros=$catalog[0].distros' "$repo/config.example.json" >"$legacy/config/config.json"
jq '.schema_version=1 | del(.revision,.distros,.profiles,.nodes,.provisioning_bundles)' "$repo/catalog.example.json" >"$legacy/catalog/catalog.json"
"$legacy/bin/nodeforge" setup --reconfigure --non-interactive --yes >"$tmp/migrate"
grep -Fq 'legacy deployment migrated' "$tmp/migrate"
test "$(jq -r .schema_version "$legacy/config/config.json")" = 2
test "$(jq -r 'has("distros")' "$legacy/config/config.json")" = false
test "$(jq -r 'length' "$legacy/catalog/distros.json")" -gt 0
test -f "$legacy/config/config.json.m4.7.bak"
test -f "$legacy/catalog/catalog.json.m4.7.bak"
test ! -f "$legacy/catalog/catalog.json"

# A crash after config publication is resumed from the migration marker. This
# is the only state in which a legacy file may coexist with a new manifest.
cp "$legacy/catalog/catalog.json.m4.7.bak" "$legacy/catalog/catalog.json"
printf '%s\n' '{"schema_version":1,"state":"prepared","request_digest":"recovery-test"}' >"$legacy/state/m4.7-migration.json"
"$legacy/bin/nodeforge" setup --reconfigure --non-interactive --yes >"$tmp/migrate-recover"
grep -Fq 'legacy deployment migrated' "$tmp/migrate-recover"
test ! -f "$legacy/catalog/catalog.json"
test ! -f "$legacy/state/m4.7-migration.json"
