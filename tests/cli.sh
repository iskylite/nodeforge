#!/bin/sh
set -eu

cli=$1
daemon=$2
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

direct_writes=$(grep -Ec 'ctx\.writer\.(writeAll|print|writeByte)\(' "$root/src/main.zig" || true)
test "$direct_writes" -eq 7
test "$(grep -Fc 'ctx.writer.print("This will permanently purge NodeForge state' "$root/src/main.zig")" -eq 1
test "$(grep -Fc 'ctx.writer.print("This will back up and reset NodeForge startup configuration' "$root/src/main.zig")" -eq 1
test "$(grep -Fc 'ctx.writer.print("This will modify {s}. Continue?' "$root/src/main.zig")" -eq 1
test "$(grep -Fc 'ctx.writer.writeAll(unit);' "$root/src/main.zig")" -eq 1
test "$(grep -Fc 'ctx.writer.writeAll(bytes);' "$root/src/main.zig")" -eq 2
test "$(grep -Fc 'ctx.writer.writeAll(answer);' "$root/src/main.zig")" -eq 1
tmp=${TMPDIR:-/tmp}/nodeforge-cli-test-$$
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

# M4.7 bootstrap deliberately rejects build-cache binaries: a valid process
# image must live in a marked install root with its same-build sibling. Copy
# both artifacts so this contract exercises the production discovery path.
install="$tmp/install"
mkdir -p "$install/bin"
cp "$cli" "$install/bin/nodeforge"
cp "$daemon" "$install/bin/nodeforged"
: >"$install/.nodeforge-root"
cli="$install/bin/nodeforge"
daemon="$install/bin/nodeforged"

"$cli" --help >"$tmp/root-help"
grep -q "NodeForge administration CLI" "$tmp/root-help"
grep -q "Available commands:" "$tmp/root-help"
grep -q "catalog" "$tmp/root-help"
grep -q -- "--version" "$tmp/root-help"
grep -Fq 'Verify that nodeforged is operational' "$tmp/root-help"
if grep -Fq 'Run health checks and set the exit code' "$tmp/root-help"; then
    echo "check must not remain beside canonical status" >&2
    exit 1
fi
if "$cli" check --help >"$tmp/check-help" 2>&1; then
    echo "check unexpectedly remains as a command" >&2
    exit 1
fi
if grep -Eq '^   .*--config' "$tmp/root-help"; then
    echo "root help must not expose command-specific flags" >&2
    exit 1
fi
if grep -Eq '^  (help|version)[[:space:]]' "$tmp/root-help"; then
    echo "help/version must be flags, not subcommands" >&2
    exit 1
fi

"$cli" config --help >"$tmp/config-help"
grep -q "validate" "$tmp/config-help"
grep -q "export" "$tmp/config-help"
if grep -Eq '^  set[[:space:]]' "$tmp/config-help"; then
    echo "startup config mutation must be owned by setup" >&2
    exit 1
fi
if grep -Eq '^  import[[:space:]]' "$tmp/config-help"; then
    echo "startup config import must be owned by setup" >&2
    exit 1
fi
if grep -q "Examples:" "$tmp/config-help"; then
    echo "help must not embed examples" >&2
    exit 1
fi

"$cli" setup --help >"$tmp/setup-help"
grep -q -- "--import-config" "$tmp/setup-help"
grep -q -- "--purge-all" "$tmp/setup-help"
"$cli" profile create --help >"$tmp/profile-create-help"
grep -Fq 'Create an install profile from an imported install source' "$tmp/profile-create-help"
grep -Fq 'Derives distro, version, and architecture' "$tmp/profile-create-help"
"$cli" profile set --help >"$tmp/profile-set-help"
grep -Fq 'exact mutable Profile PropertySpec key' "$tmp/profile-set-help"
grep -Fq 'Collections require' "$tmp/profile-set-help"
"$cli" profile set --help-full >"$tmp/profile-set-help-full"
grep -Fq 'install.storage.mode' "$tmp/profile-set-help-full"
grep -Fq 'software.packages.include' "$tmp/profile-set-help-full"
grep -Fq 'system.users' "$tmp/profile-set-help-full"
grep -Fq 'user.groups' "$tmp/profile-set-help-full"
grep -Fq 'user.ssh_authorized_keys' "$tmp/profile-set-help-full"
"$cli" profile item replace-values --help >"$tmp/profile-item-values-help"
grep -Fq -- '--from-file' "$tmp/profile-item-values-help"
"$cli" node set --help >"$tmp/node-set-help"
grep -Fq 'exact mutable Node PropertySpec keys' "$tmp/node-set-help"
grep -Fq 'structured collections require item commands' "$tmp/node-set-help"
"$cli" node set --help-full >"$tmp/node-set-help-full"
grep -Fq 'storage.boot_disk' "$tmp/node-set-help-full"
grep -Fq 'storage.additional_disks' "$tmp/node-set-help-full"
grep -Fq 'overrides.install.storage.mode' "$tmp/node-set-help-full"
"$cli" node unset --help >"$tmp/node-unset-help"
grep -Fq 'overrides.* scalar keys' "$tmp/node-unset-help"
"$cli" node retry --help >"$tmp/node-retry-help"
grep -Fq 'Supersede a stuck active session' "$tmp/node-retry-help"
"$cli" node render --help >"$tmp/node-render-help"
if grep -Eq '^   .*--output' "$tmp/node-render-help"; then
    echo "node render emits an answer artifact and must not expose a view-format flag" >&2
    exit 1
fi
"$cli" status --help >"$tmp/status-help"
grep -Fq 'advertised HTTP, catalog, DHCP, and TFTP' "$tmp/status-help"
grep -Fq 'human, json, or jsonl' "$tmp/status-help"
grep -Fq -- '--fields' "$tmp/status-help"
grep -Fq -- '--columns' "$tmp/status-help"
grep -Fq -- '--width' "$tmp/status-help"
grep -Fq -- '--wide' "$tmp/status-help"
grep -Fq -- '--no-header' "$tmp/status-help"
"$cli" runtime --help >"$tmp/runtime-help"
if grep -Fq 'Show runtime status overview' "$tmp/runtime-help"; then
    echo "runtime status must not remain beside canonical top-level status" >&2
    exit 1
fi
if "$cli" runtime status --help >"$tmp/runtime-status-help" 2>&1; then
    echo "runtime status unexpectedly remains as a command" >&2
    exit 1
fi

"$cli" assets register --help >"$tmp/asset-register-help"
grep -Fq 'Distro name, used with --version and --arch; e.g. rocky' "$tmp/asset-register-help"
grep -Fq 'Distro version, used with --distro and --arch; e.g. 9.7' "$tmp/asset-register-help"
grep -Fq 'Architecture, used with --distro and --version; e.g. aarch64' "$tmp/asset-register-help"

# v0.2 diskless leaves must be present in the installed command tree. These
# checks intentionally use generated help so a handler that exists in source
# but was not attached to its parent command cannot silently pass.
"$cli" assets boot-bundle create --help >"$tmp/boot-bundle-create-help"
grep -Fq -- '--kernel' "$tmp/boot-bundle-create-help"
grep -Fq -- '--initrd' "$tmp/boot-bundle-create-help"
if grep -Fq -- '--rootfs' "$tmp/boot-bundle-create-help"; then
    echo "boot bundle must not own a Profile-derived rootfs artifact" >&2
    exit 1
fi
"$cli" profile rootfs plan --help >"$tmp/profile-rootfs-plan-help"
grep -Fq 'rootfs input digest and cache state' "$tmp/profile-rootfs-plan-help"
"$cli" profile rootfs build --help >"$tmp/profile-rootfs-build-help"
grep -Fq -- '--if-input-digest' "$tmp/profile-rootfs-build-help"
"$cli" profile rootfs register --help >"$tmp/profile-rootfs-register-help"
grep -Fq -- '--path' "$tmp/profile-rootfs-register-help"
"$cli" profile rootfs status --help >"$tmp/profile-rootfs-status-help"
grep -Fq 'registered rootfs artifact' "$tmp/profile-rootfs-status-help"
"$cli" node boot-prepare --help >"$tmp/node-boot-prepare-help"
grep -Fq 'diskless boot session' "$tmp/node-boot-prepare-help"

"$cli" assets import --help >"$tmp/assets-import-help"
grep -Fq 'Readable local ISO path; e.g. /srv/iso/ubuntu-22.04.5-live-server-arm64.iso' "$tmp/assets-import-help"
"$cli" assets install-source --help >"$tmp/install-source-help"
grep -Fq 'software' "$tmp/install-source-help"
"$cli" assets repository software show --help >"$tmp/repository-software-help"
grep -Fq -- '--kind' "$tmp/repository-software-help"
"$cli" profile software --help >"$tmp/profile-software-help"
grep -Fq 'available' "$tmp/profile-software-help"
grep -Fq 'show' "$tmp/profile-software-help"
"$cli" profile capabilities show --help >"$tmp/profile-capabilities-help"
grep -Fq 'adapter capability registry' "$tmp/profile-capabilities-help"
"$cli" node software --help >"$tmp/node-software-help"
grep -Fq 'show' "$tmp/node-software-help"
"$cli" node capabilities show --help >"$tmp/node-capabilities-help"
grep -Fq 'adapter capability registry' "$tmp/node-capabilities-help"
grep -Fq 'Override an unknown or ambiguous product id; e.g. rocky, kylin, ubuntu. Family still comes from ISO layout' "$tmp/assets-import-help"
grep -Fq 'atomically publishes the distro tuple with the install source' "$tmp/assets-import-help"
if grep -Fq 'relative to /opt/nodeforge/work/import' "$tmp/assets-import-help"; then
    echo "assets import must accept an arbitrary ISO path" >&2
    exit 1
fi
if "$cli" distro --help >"$tmp/distro-help" 2>&1; then
    echo "distro must be derived by ISO import, not exposed as a standalone command" >&2
    exit 1
fi

"$cli" assets --help >"$tmp/assets-help"
for command in key-import key-reload key-show key-list; do
    grep -Fq "$command" "$tmp/assets-help"
    "$cli" assets "$command" --help >"$tmp/assets-$command-help"
done
grep -Fq 'Local OpenSSH public key path' "$tmp/assets-key-import-help"

for command in \
    "status" \
    "config validate" \
    "config export" \
    "catalog" \
    "catalog validate" \
    "catalog export" \
    "catalog show" \
    "catalog migrate"; do
    "$cli" $command --help >"$tmp/help-$(echo "$command" | tr ' ' '-')"
    if grep -q "Examples:" "$tmp/help-$(echo "$command" | tr ' ' '-')"; then
        echo "help must not embed examples: $command" >&2
        exit 1
    fi
done

"$cli" status --help >"$tmp/status-help"
grep -q -- "--config" "$tmp/status-help"
grep -q -- "--output" "$tmp/status-help"
if grep -Eq '^   .*--catalog' "$tmp/status-help"; then
    echo "status must not expose unused catalog flag" >&2
    exit 1
fi

"$cli" config export --help >"$tmp/config-export-help"
grep -q -- "--config" "$tmp/config-export-help"
grep -q -- "--debug" "$tmp/config-export-help"
if grep -Eq '^   .*--(catalog|output)' "$tmp/config-export-help"; then
    echo "config export must expose only the flags it reads" >&2
    exit 1
fi

"$cli" catalog export --help >"$tmp/catalog-export-help"
grep -q -- "--catalog" "$tmp/catalog-export-help"
if grep -Eq '^   .*--(config|output)' "$tmp/catalog-export-help"; then
    echo "catalog export must expose only the flags it reads" >&2
    exit 1
fi

"$cli" --version | grep -Eq '^nodeforge 0\.2\.0 \(commit [0-9a-f]{12}|unknown'
"$cli" -v | grep -Fq 'built '
"$daemon" --version | grep -Eq '^nodeforged 0\.2\.0 \(commit [0-9a-f]{12}|unknown'

for removed_command in help version; do
    if "$cli" "$removed_command" >"$tmp/removed-$removed_command" 2>&1; then
        echo "$removed_command subcommand unexpectedly succeeded" >&2
        exit 1
    else
        test "$?" -eq 2
    fi
done

# Each business flag belongs to its leaf command. This avoids silently carrying
# unrelated root flags into subcommands that do not read them.
"$cli" config validate -c "$root/config.example.json" -C "$root/catalog.example.json" -o json >"$tmp/validate"
grep -q '"ok":true' "$tmp/validate"
grep -q "$root/config.example.json" "$tmp/validate"
"$cli" catalog show --help >"$tmp/catalog-show-help"
grep -Fq 'install-source' "$tmp/catalog-show-help"
if grep -Eq '^   .*--catalog' "$tmp/catalog-show-help"; then
    echo "catalog show must query daemon rather than read catalog.json" >&2
    exit 1
fi

# M1.5 human output is an aligned, headered table rather than tabs. The
# contract runs with stdout redirected, so it also proves no ANSI bytes leak
# into scripts and snapshots; JSON retains its machine-readable shape.
"$cli" assets list -C "$root/catalog.example.json" >"$tmp/asset-list"
grep -Eq '^NAME[[:space:]]+KIND[[:space:]]+PATH[[:space:]]*$' "$tmp/asset-list"
grep -F 'rocky-9.7-aarch64-installer-kernel' "$tmp/asset-list" | grep -Fq 'kernel'
if LC_ALL=C grep -q "$(printf '\033')" "$tmp/asset-list"; then
    echo "human asset list must not emit ANSI outside a TTY" >&2
    exit 1
fi
"$cli" assets list -C "$root/catalog.example.json" --no-color >"$tmp/asset-list-no-color"
cmp "$tmp/asset-list" "$tmp/asset-list-no-color"
"$cli" assets list -C "$root/catalog.example.json" -o json >"$tmp/asset-list-json"
jq -e '.ok and (.result.assets | length > 0) and .result.assets[0].name' "$tmp/asset-list-json" >/dev/null
"$cli" assets list -C "$root/catalog.example.json" -o jsonl >"$tmp/asset-list-jsonl"
test "$(wc -l <"$tmp/asset-list-jsonl" | tr -d ' ')" = "$(jq '.assets | length' "$root/catalog.example.json")"
jq -e '.ok and .result.name and .result.kind and .result.path' "$tmp/asset-list-jsonl" >/dev/null
"$cli" assets list -C "$root/catalog.example.json" --columns name,path --no-header >"$tmp/asset-list-columns"
if grep -Fq 'KIND' "$tmp/asset-list-columns"; then
    echo "filtered asset list unexpectedly retained KIND" >&2
    exit 1
fi
if "$cli" assets list -C "$root/catalog.example.json" --columns missing >"$tmp/asset-list-bad-column.out" 2>"$tmp/asset-list-bad-column.err"; then
    echo "asset list accepted an unknown output column" >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/asset-list-bad-column.out"
grep -Fq 'unknown key' "$tmp/asset-list-bad-column.err"
if "$cli" assets list -C "$root/catalog.example.json" -o json --no-header >"$tmp/asset-list-json-header.out" 2>"$tmp/asset-list-json-header.err"; then
    echo "JSON asset list accepted human-only --no-header" >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/asset-list-json-header.out"
grep -Fq 'not applicable' "$tmp/asset-list-json-header.err"

if "$cli" --config "$root/config.example.json" config validate >"$tmp/root-config" 2>&1; then
    echo "root config flag unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi

if "$cli" config validate --version >"$tmp/nested-version" 2>&1; then
    echo "nested version flag unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi

if "$cli" config export -c "$tmp/missing.json" >"$tmp/load-error" 2>&1; then
    echo "missing config unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 1
fi
grep -Fqx "error: config: file not found: $tmp/missing.json" "$tmp/load-error"

if "$cli" config export -c "$tmp/missing.json" -d >"$tmp/load-debug" 2>&1; then
    echo "missing debug config unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 1
fi
grep -q '^debug: config: load cause=FileNotFound$' "$tmp/load-debug"

if "$cli" config unknown >"$tmp/unknown" 2>&1; then
    echo "unknown command unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi
grep -q "Unknown command: 'unknown'" "$tmp/unknown"

"$daemon" --help >"$tmp/daemon-help"
grep -q "NodeForge daemon" "$tmp/daemon-help"
grep -q -- "--check-config" "$tmp/daemon-help"
grep -q -- "--debug" "$tmp/daemon-help"
grep -q -- "--log-output" "$tmp/daemon-help"
grep -q -- "--log-file" "$tmp/daemon-help"
grep -q -- "-k, --check" "$tmp/daemon-help"
grep -q -- "-K, --check-config" "$tmp/daemon-help"
"$daemon" --version | grep -Fq 'built '
"$daemon" -v | grep -Fq 'commit '
"$daemon" -K -c "$root/config.example.json" -C "$root/catalog.example.json" >"$tmp/daemon-check-config" 2>&1
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* info \[nodeforge\] config: valid ' "$tmp/daemon-check-config"

# Service log routing is selected per invocation. File mode keeps normal
# terminal stderr quiet, while both mode duplicates the bounded service line.
service_log="$tmp/nodeforged.log"
"$daemon" -K -c "$root/config.example.json" -C "$root/catalog.example.json" --log-output file --log-file "$service_log" >"$tmp/daemon-file-out" 2>"$tmp/daemon-file-err"
if grep -Fq '[nodeforge]' "$tmp/daemon-file-err"; then
    echo "file log mode unexpectedly wrote a service log to stderr" >&2
    exit 1
fi
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* info \[nodeforge\] config: valid ' "$service_log"

failed_service_log="$tmp/nodeforged-failure.log"
if "$daemon" -K -c "$tmp/missing-daemon-config.json" -C "$root/catalog.example.json" --log-output file --log-file "$failed_service_log" >"$tmp/daemon-failure-out" 2>"$tmp/daemon-failure-err"; then
    echo "missing daemon config unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 1
fi
grep -Fq 'err [nodeforge] config: cannot load' "$failed_service_log"

"$daemon" -K -c "$root/config.example.json" -C "$root/catalog.example.json" --log-output both --log-file "$service_log" >"$tmp/daemon-both-out" 2>"$tmp/daemon-both-err"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* info \[nodeforge\] config: valid ' "$tmp/daemon-both-err"

if "$daemon" -K -c "$root/config.example.json" -C "$root/catalog.example.json" --log-output nowhere >"$tmp/daemon-invalid-log-output" 2>&1; then
    echo "invalid --log-output unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi

# Spinner support is available for future interactive commands, but no current
# handler starts one or emits cursor-control sequences.
if LC_ALL=C grep -q "$(printf '\033')\[?25h" "$tmp/validate"; then
    echo "non-spinner command emitted a cursor-control sequence" >&2
    exit 1
fi

# M2.5 events commands: `events list`, `events types`, and `events follow`
# are local-only file consumers. They read events.jsonl from the fixed
# /opt/nodeforge/logs path; in dev/test the file may not exist, which is
# an empty-list success, not an error.

# events types lists all registered event types from the static registry.
"$cli" events types >"$tmp/events-types"
grep -Fq 'service.started' "$tmp/events-types"
grep -Fq 'dhcp.ack' "$tmp/events-types"
grep -Fq 'tftp.transfer.complete' "$tmp/events-types"
grep -Fq 'http.request' "$tmp/events-types"
grep -Fq 'boot.session.terminated' "$tmp/events-types"
grep -Eq '^TYPE[[:space:]]+LEVEL[[:space:]]+DESCRIPTION' "$tmp/events-types"

"$cli" events types -o json >"$tmp/events-types-json"
jq -e '.ok and any(.result.items[]; .name == "service.started") and any(.result.items[]; .name == "dhcp.ack")' "$tmp/events-types-json" >/dev/null
"$cli" events types -o jsonl >"$tmp/events-types-jsonl"
jq -s -e 'any(.[]; .result.name == "service.started" and .ok)' "$tmp/events-types-jsonl" >/dev/null

# events list returns an empty table when no events file exists.
# Use an explicit non-existent path so the test is not affected by a
# real events.jsonl left behind by prior daemon runs on this host.
"$cli" events list --events-path "$tmp/nonexistent.jsonl" >"$tmp/events-list-empty"
grep -Fqx 'No events recorded.' "$tmp/events-list-empty"

# events list JSON returns a stable empty collection envelope.
"$cli" events list --events-path "$tmp/nonexistent.jsonl" -o json >"$tmp/events-list-empty-json"
jq -e '.ok and (.result.items | length) == 0 and .result.skipped == 0' "$tmp/events-list-empty-json" >/dev/null

# events list with an unknown --type is a usage error (exit 2).
if "$cli" events list --type bogus.type >"$tmp/events-bad-type" 2>&1; then
    echo "unknown event type unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi
grep -Fq "unknown event type 'bogus.type'" "$tmp/events-bad-type"

# events list with an invalid --limit is a usage error.
if "$cli" events list --limit 0 >"$tmp/events-bad-limit" 2>&1; then
    echo "limit 0 unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi

# M2.5.1 session filters and trace read a supplied local JSONL fixture, including
# a rotated file. This avoids requiring write access to /opt during host tests.
events_dir="$tmp/logs"
mkdir -p "$events_dir"
session_id=0123456789abcdef0123456789abcdef
instance_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
instance_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cat >"$events_dir/events.jsonl.1" <<EOF
{"v":2,"ts":"2026-07-11T08:30:00Z","type":"dhcp.discover","message":"discover received","fields":[{"key":"node_id","value":"node-01"},{"key":"boot_session_id","value":"$session_id"},{"key":"daemon_instance_id","value":"$instance_a"}]}
{"v":2,"ts":"2026-07-11T08:30:01Z","type":"dhcp.offer","message":"offer sent","fields":[{"key":"node_id","value":"node-01"},{"key":"boot_session_id","value":"$session_id"},{"key":"daemon_instance_id","value":"$instance_a"}]}
{"v":2,"ts":"2026-07-11T08:30:02Z","type":"dhcp.ack","message":"ack sent","fields":[{"key":"node_id","value":"node-01"},{"key":"boot_session_id","value":"$session_id"},{"key":"daemon_instance_id","value":"$instance_a"}]}
EOF
cat >"$events_dir/events.jsonl" <<EOF
{"v":2,"ts":"2026-07-11T08:30:03Z","type":"tftp.rrq","message":"TFTP read requested","fields":[{"key":"filename","value":"efi/grubaa64.efi"},{"key":"boot_session_id","value":"$session_id"},{"key":"daemon_instance_id","value":"$instance_a"}]}
{"v":2,"ts":"2026-07-11T08:30:04Z","type":"tftp.transfer.complete","message":"TFTP transfer completed","fields":[{"key":"filename","value":"efi/grubaa64.efi"},{"key":"boot_session_id","value":"$session_id"},{"key":"daemon_instance_id","value":"$instance_a"}]}
{"v":2,"ts":"2026-07-11T08:30:04Z","type":"service.started","message":"protocol listeners initialized","fields":[{"key":"daemon_instance_id","value":"$instance_b"}]}
{"v":2,"ts":"2026-07-11T08:32:00Z","type":"dhcp.discover","message":"untracked due to capacity","fields":[{"key":"node_id","value":"node-02"},{"key":"session_link_state","value":"capacity_exhausted"},{"key":"daemon_instance_id","value":"$instance_b"}]}
EOF
"$cli" events list --events-path "$events_dir/events.jsonl" --session "$session_id" -o json >"$tmp/events-session-json"
python3 -m json.tool "$tmp/events-session-json" >/dev/null
jq -e '.ok and any(.result.items[]; .type == "tftp.transfer.complete")' "$tmp/events-session-json" >/dev/null
"$cli" events list --events-path "$events_dir/events.jsonl" --session "$session_id" -o jsonl >"$tmp/events-session-jsonl"
jq -s -e 'any(.[]; .result.type == "tftp.transfer.complete" and .ok)' "$tmp/events-session-jsonl" >/dev/null
"$cli" node trace node-01 --events-path "$events_dir/events.jsonl" -o json >"$tmp/trace-session-json"
python3 -m json.tool "$tmp/trace-session-json" >/dev/null
grep -Fq '"boot_session_id":"'"$session_id"'"' "$tmp/trace-session-json"
grep -Fq '"kind":"daemon_restart_gap"' "$tmp/trace-session-json"
"$cli" node trace node-01 --events-path "$events_dir/events.jsonl" >"$tmp/trace-session-human"
grep -Fq 'daemon_restart_gap' "$tmp/trace-session-human"
"$cli" node trace node-02 --events-path "$events_dir/events.jsonl" -o json >"$tmp/trace-capacity-json"
grep -Fq '"kind":"capacity_exhausted"' "$tmp/trace-capacity-json"
if "$cli" events list --session invalid --events-path "$events_dir/events.jsonl" >"$tmp/events-invalid-session" 2>&1; then
    echo "invalid session filter unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi

# events follow on a missing file is an error (non-zero exit).
if "$cli" events follow --events-path "$tmp/nonexistent.jsonl" >"$tmp/events-follow-missing" 2>&1; then
    echo "events follow on missing file unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 1
fi
grep -Fq 'error: events: active file unavailable' "$tmp/events-follow-missing"
