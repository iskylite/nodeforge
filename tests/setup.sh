#!/bin/sh
set -eu

cli=$1
daemon=$2
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
cleanup() {
    chmod -R u+w "$tmp" 2>/dev/null || true
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

bundle="$tmp/bundle"
install="$tmp/custom-nodeforge"
mkdir -p "$bundle"
cp "$cli" "$bundle/nodeforge"
cp "$daemon" "$bundle/nodeforged"
cp "$cli" "$bundle/nodeforge-initrd"
cp "$cli" "$bundle/nodeforge-agent"

"$bundle/nodeforge" setup --install-root "$install" --non-interactive --yes >"$tmp/init.out"
grep -Fq 'NodeForge initialized' "$tmp/init.out"
test -f "$install/.nodeforge-root"
test -x "$install/bin/nodeforge"
test -x "$install/bin/nodeforged"
test -x "$install/bin/nodeforge-initrd"
test -x "$install/bin/nodeforge-agent"
test "$(jq -r .schema_version "$install/config/config.json")" = 4
test "$(jq -r .layout_schema_version "$install/catalog/manifest.json")" = 1
test "$(jq -r .catalog_schema_version "$install/catalog/manifest.json")" = 4
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
# Reconfigure always republishes the unit, but never activates the service.
printf '%s\n' stale-unit >"$install/systemd/nodeforged.service"
"$install/bin/nodeforge" setup --reconfigure --non-interactive --yes >"$tmp/reconfigure-unit"
grep -Fq "ExecStart=$install_real/bin/nodeforged --log-output file" "$install/systemd/nodeforged.service"
if "$install/bin/nodeforge" setup --reconfigure --install --non-interactive --yes >"$tmp/reconfigure-install" 2>&1; then
    echo "reconfigure unexpectedly accepted standalone systemd --install" >&2
    exit 1
fi
grep -Fq -- '--install belongs to the standalone --generate-systemd operation' "$tmp/reconfigure-install"

# Startup config replacement is part of setup so the candidate is validated
# against the current catalog before the canonical config is atomically saved.
jq '.logging.level = "debug"' "$install/config/config.json" >"$tmp/candidate.json"
"$install/bin/nodeforge" setup --reconfigure --import-config "$tmp/candidate.json" --non-interactive --yes >"$tmp/import-config"
grep -Fq 'deployment reconfigured' "$tmp/import-config"
grep -Fq "$tmp/candidate.json" "$tmp/import-config"
grep -Fq 'restart nodeforged' "$tmp/import-config"
test "$(jq -r .logging.level "$install/config/config.json")" = debug

# Invalid input must fail before replacing the installed startup config.
checksum_before=$(cksum "$install/config/config.json")
printf '%s\n' '{"schema_version":1,"server":{"server_ip":"::1"}}' >"$tmp/invalid-source.json"
if "$install/bin/nodeforge" setup --reconfigure --import-config "$tmp/invalid-source.json" --non-interactive --yes >"$tmp/invalid-import" 2>&1; then
    echo "invalid setup config import unexpectedly succeeded" >&2
    exit 1
fi
test "$checksum_before" = "$(cksum "$install/config/config.json")"

printf '%s\n' '{"schema_version":1}' >"$install/state/leases.json"
"$install/bin/nodeforge" setup --reset-state --non-interactive --yes >"$tmp/reset"
test ! -f "$install/state/leases.json"
backup=$(sed -n 's/^  Backup[[:space:]]*//p' "$tmp/reset")
test -n "$backup"
test -f "$backup/leases.json"
test "$(jq -r '.files[0].file' "$backup/manifest.json")" = leases.json
test "$(jq -r '.files[0].sha256 | length' "$backup/manifest.json")" = 64

# --purge-all may compose with --reconfigure. The interactive composite has one
# confirmation boundary; rejection must happen before any destructive write.
# A confirmed purge also removes managed work/import history, including
# read-only trees left by interrupted ISO imports, then recreates empty work dirs.
mkdir -p "$install/backups/old"
mkdir -p "$install/work/import" "$install/work/iso-import-stale/repo/readonly"
printf old >"$install/backups/old/manifest.json"
printf old >"$install/logs/events.jsonl"
printf old >"$install/config/config.json.m4.7.bak"
printf old >"$install/work/import/stale.iso"
printf old >"$install/work/iso-import-stale/repo/readonly/treeinfo"
chmod 500 "$install/work/iso-import-stale/repo/readonly"
printf stale-unit >"$install/systemd/nodeforged.service"
if printf 'n\n' | "$install/bin/nodeforge" setup --reset-all --purge-all --reconfigure >"$tmp/purge-denied" 2>&1; then
    echo "rejected interactive purge unexpectedly succeeded" >&2
    exit 1
fi
test -f "$install/backups/old/manifest.json"
test -f "$install/work/import/stale.iso"
grep -Fq 'permanently purge NodeForge state' "$tmp/purge-denied" || {
    cat "$tmp/purge-denied" >&2
    exit 1
}
printf 'yes\n' | "$install/bin/nodeforge" setup --reset-all --purge-all --reconfigure >"$tmp/purge-all"
grep -Fq 'purged by --purge-all' "$tmp/purge-all"
grep -Fq 'deployment reconfigured' "$tmp/purge-all"
grep -Fq 'Service' "$tmp/purge-all"
grep -Fq 'unchanged; run systemctl daemon-reload/restart nodeforged' "$tmp/purge-all"
test ! -e "$install/backups"
test ! -e "$install/logs/events.jsonl"
test ! -e "$install/config/config.json.m4.7.bak"
test ! -e "$install/work/import/stale.iso"
test ! -e "$install/work/iso-import-stale"
test -d "$install/work/import"
test -f "$install/config/config.json"
test -f "$install/catalog/manifest.json"
grep -Fq "ExecStart=$install_real/bin/nodeforged --log-output file" "$install/systemd/nodeforged.service"

# A partial bundle cannot produce a valid marker or claim initialization.
partial="$tmp/partial"
broken="$tmp/broken-root"
mkdir -p "$partial"
cp "$cli" "$partial/nodeforge"
if "$partial/nodeforge" setup --install-root "$broken" --non-interactive --yes >"$tmp/broken.out" 2>&1; then
    echo "partial bundle unexpectedly initialized" >&2
    exit 1
fi

# The diskless builder companions are optional for a control-plane-only
# bundle, but a half-pair must fail closed.
half_bundle="$tmp/half-bundle"
half_install="$tmp/half-install"
mkdir -p "$half_bundle"
cp "$cli" "$half_bundle/nodeforge"
cp "$daemon" "$half_bundle/nodeforged"
cp "$cli" "$half_bundle/nodeforge-initrd"
if "$half_bundle/nodeforge" setup --install-root "$half_install" --non-interactive --yes >"$tmp/half.out" 2>&1; then
    echo "half diskless companion pair unexpectedly initialized" >&2
    exit 1
fi
test ! -f "$half_install/.nodeforge-root"
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
