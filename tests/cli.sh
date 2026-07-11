#!/bin/sh
set -eu

cli=$1
daemon=$2
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/nodeforge-cli-test-$$
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$cli" --help >"$tmp/root-help"
grep -q "NodeForge administration CLI" "$tmp/root-help"
grep -q "Available commands:" "$tmp/root-help"
grep -q "catalog" "$tmp/root-help"
grep -q -- "--version" "$tmp/root-help"
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
grep -q "import" "$tmp/config-help"
if grep -q "Examples:" "$tmp/config-help"; then
    echo "help must not embed examples" >&2
    exit 1
fi

"$cli" config import --help >"$tmp/import-help"
grep -q "Source config JSON path" "$tmp/import-help"
grep -q "required" "$tmp/import-help"
if grep -Eq '^   .*--catalog' "$tmp/import-help"; then
    echo "config import must not expose catalog validation" >&2
    exit 1
fi

"$cli" asset import --help >"$tmp/asset-import-help"
grep -Fq 'Distro name, used with --version and --arch; e.g. rocky' "$tmp/asset-import-help"
grep -Fq 'Distro version, used with --distro and --arch; e.g. 9.7' "$tmp/asset-import-help"
grep -Fq 'Architecture, used with --distro and --version; e.g. aarch64' "$tmp/asset-import-help"

for command in \
    "status" \
    "check" \
    "config validate" \
    "config export" \
    "catalog" \
    "catalog validate" \
    "catalog export"; do
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

test "$("$cli" --version)" = "nodeforge 0.1.0"
test "$("$cli" -v)" = "nodeforge 0.1.0"

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

# M1.5 human output is an aligned, headered table rather than tabs. The
# contract runs with stdout redirected, so it also proves no ANSI bytes leak
# into scripts and snapshots; JSON retains its machine-readable shape.
"$cli" asset list -C "$root/catalog.example.json" >"$tmp/asset-list"
grep -Eq '^NAME[[:space:]]+KIND[[:space:]]+PATH[[:space:]]*$' "$tmp/asset-list"
grep -F 'rocky-9.7-aarch64-installer-kernel' "$tmp/asset-list" | grep -Fq 'kernel'
if LC_ALL=C grep -q "$(printf '\033')" "$tmp/asset-list"; then
    echo "human asset list must not emit ANSI outside a TTY" >&2
    exit 1
fi
"$cli" asset list -C "$root/catalog.example.json" --no-color >"$tmp/asset-list-no-color"
cmp "$tmp/asset-list" "$tmp/asset-list-no-color"
"$cli" asset list -C "$root/catalog.example.json" -o json >"$tmp/asset-list-json"
grep -Fq '"assets":[' "$tmp/asset-list-json"

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

if "$cli" config import >"$tmp/missing" 2>&1; then
    echo "missing positional argument unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi
grep -q "Missing 1 positional argument" "$tmp/missing"

# Import is deliberately a single-file operation. A missing catalog must not
# prevent staging a valid startup config for the next daemon restart.
"$cli" config import -c "$tmp/imported.json" "$root/config.example.json" >"$tmp/imported"
grep -Fqx 'OK config imported' "$tmp/imported"
grep -q '^  Source' "$tmp/imported"
grep -q '^  Destination' "$tmp/imported"
test -s "$tmp/imported.json"

# A source that fails semantic validation must not replace a previously valid
# destination. This guards the offline import's validate-before-atomic-save rule.
checksum_before=$(cksum "$tmp/imported.json")
printf '%s\n' '{"schema_version":1,"server":{"server_ip":"::1"}}' >"$tmp/invalid-source.json"
if "$cli" config import -c "$tmp/imported.json" "$tmp/invalid-source.json" >"$tmp/invalid-import" 2>&1; then
    echo "invalid config import unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 1
fi
test "$checksum_before" = "$(cksum "$tmp/imported.json")"

"$daemon" --help >"$tmp/daemon-help"
grep -q "NodeForge daemon" "$tmp/daemon-help"
grep -q -- "--check-config" "$tmp/daemon-help"
grep -q -- "--debug" "$tmp/daemon-help"
grep -q -- "--log-output" "$tmp/daemon-help"
grep -q -- "--log-file" "$tmp/daemon-help"
grep -q -- "-k, --check" "$tmp/daemon-help"
grep -q -- "-K, --check-config" "$tmp/daemon-help"
test "$("$daemon" --version)" = "nodeforged 0.1.0"
test "$("$daemon" -v)" = "nodeforged 0.1.0"
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
grep -Fq '"name":"service.started"' "$tmp/events-types-json"
grep -Fq '"name":"dhcp.ack"' "$tmp/events-types-json"

# events list returns an empty table when no events file exists.
"$cli" events list >"$tmp/events-list-empty"
grep -Fqx 'No events recorded.' "$tmp/events-list-empty"

# events list JSON returns an empty array when no events file exists.
"$cli" events list -o json >"$tmp/events-list-empty-json"
grep -Fqx '[]' "$tmp/events-list-empty-json"

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
grep -Fq '"type":"tftp.transfer.complete"' "$tmp/events-session-json"
"$cli" trace node-01 --events-path "$events_dir/events.jsonl" -o json >"$tmp/trace-session-json"
python3 -m json.tool "$tmp/trace-session-json" >/dev/null
grep -Fq '"boot_session_id":"'"$session_id"'"' "$tmp/trace-session-json"
grep -Fq '"kind":"daemon_restart_gap"' "$tmp/trace-session-json"
"$cli" trace node-01 --events-path "$events_dir/events.jsonl" >"$tmp/trace-session-human"
grep -Fq 'daemon_restart_gap' "$tmp/trace-session-human"
"$cli" trace node-02 --events-path "$events_dir/events.jsonl" -o json >"$tmp/trace-capacity-json"
grep -Fq '"kind":"capacity_exhausted"' "$tmp/trace-capacity-json"
if "$cli" events list --session invalid --events-path "$events_dir/events.jsonl" >"$tmp/events-invalid-session" 2>&1; then
    echo "invalid session filter unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi

# events follow on a missing file is an error (non-zero exit).
if "$cli" events follow >"$tmp/events-follow-missing" 2>&1; then
    echo "events follow on missing file unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 1
fi
grep -Fq 'error: events: active file unavailable' "$tmp/events-follow-missing"
