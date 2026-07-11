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
grep -q -- "-k, --check" "$tmp/daemon-help"
grep -q -- "-K, --check-config" "$tmp/daemon-help"
test "$("$daemon" --version)" = "nodeforged 0.1.0"
test "$("$daemon" -v)" = "nodeforged 0.1.0"
"$daemon" -K -c "$root/config.example.json" -C "$root/catalog.example.json" >"$tmp/daemon-check-config" 2>&1
grep -q '^info: config: valid ' "$tmp/daemon-check-config"

# Spinner support is available for future interactive commands, but no current
# handler starts one or emits cursor-control sequences.
if LC_ALL=C grep -q "$(printf '\033')\[?25h" "$tmp/validate"; then
    echo "non-spinner command emitted a cursor-control sequence" >&2
    exit 1
fi
