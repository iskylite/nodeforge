#!/bin/sh
set -eu

# DHCP requires the privileged fixed port 67. The Rocky validation target runs
# this contract as root; macOS developer hosts do not grant that bind here.
if [ "$(uname -s)" = Darwin ]; then
    exit 0
fi

cli=$1
daemon=$2
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/nodeforge-http-test-$$
port=$((20000 + ($$ % 10000)))
mkdir -p "$tmp"

pid=
stop_daemon() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        pid=
    fi
}
cleanup() {
    stop_daemon
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

sed \
    -e 's/192.168.50.1/127.0.0.1/g' \
    -e 's/192.168.50.0\/24/127.0.0.0\/24/' \
    -e 's/192.168.50.100/127.0.0.100/' \
    -e 's/192.168.50.200/127.0.0.200/' \
    -e "s/\"http_port\": 8080/\"http_port\": $port/" \
    -e 's/"bind_interface": "enp1s0"/"bind_interface": "lo"/' \
    "$root/config.example.json" > "$tmp/config.json"

"$daemon" -c "$tmp/config.json" -C "$tmp/catalog.json" >"$tmp/daemon.out" 2>"$tmp/daemon.err" &
pid=$!

ready=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if curl --silent --fail "http://127.0.0.1:$port/healthz" >"$tmp/health"; then
        ready=true
        break
    fi
    sleep 0.1
done
test "$ready" = true

grep -Fqx '{"ok":true,"service":"nodeforge"}' "$tmp/health"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/config/status" >"$tmp/config-status"
grep -Fqx '{"ok":true,"result":{"config":"valid"}}' "$tmp/config-status"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/server/status" >"$tmp/status"
grep -Fqx '{"ok":true,"result":{"service":"running"}}' "$tmp/status"
curl --silent --fail -X POST "http://127.0.0.1:$port/api/v1/management/config/validate" >"$tmp/validate"
grep -Fqx '{"ok":true,"result":{}}' "$tmp/validate"

# M2 read-only DHCP/runtime commands consume the validated local config and
# daemon management routes. The empty pool is still a useful contract check.
"$cli" dhcp show -c "$tmp/config.json" >"$tmp/dhcp-show"
grep -Fqx '  Subnet       127.0.0.0/24' "$tmp/dhcp-show"
"$cli" runtime leases list -c "$tmp/config.json" >"$tmp/dhcp-leases"
grep -Eq '^(IP[[:space:]]+MAC[[:space:]]+PHASE[[:space:]]+EXPIRES|No DHCP leases\.)' "$tmp/dhcp-leases"
"$cli" runtime unknown list -c "$tmp/config.json" >"$tmp/dhcp-unknown"
grep -Eq '^(IP[[:space:]]+MAC[[:space:]]+PHASE[[:space:]]+EXPIRES|No unknown clients\.)' "$tmp/dhcp-unknown"
"$cli" node list -c "$tmp/config.json" >"$tmp/node-list"
grep -Fqx 'No nodes registered.' "$tmp/node-list"

"$cli" check -c "$tmp/config.json" >"$tmp/check"
grep -Fqx 'OK nodeforge checks passed' "$tmp/check"

if "$daemon" --check -c "$tmp/config.json" -C "$tmp/catalog.json" >"$tmp/preflight" 2>&1; then
    echo "preflight unexpectedly accepted an active HTTP listener" >&2
    exit 1
fi

if "$daemon" -c "$tmp/config.json" -C "$tmp/catalog.json" >"$tmp/second-daemon" 2>&1; then
    echo "second daemon unexpectedly bound the active HTTP listener" >&2
    exit 1
fi

curl --silent --fail-with-body "http://127.0.0.1:$port/not-found" >"$tmp/not-found" 2>&1 || true
grep -Fqx '{"ok":false,"error":{"code":"http.not_found","message":"route not found"}}' "$tmp/not-found"

stop_daemon
"$daemon" -d -c "$tmp/config.json" -C "$tmp/catalog.json" >"$tmp/debug-daemon.out" 2>"$tmp/debug-daemon.err" &
pid=$!

ready=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if curl --silent --fail "http://127.0.0.1:$port/healthz" >"$tmp/debug-health"; then
        ready=true
        break
    fi
    sleep 0.1
done
test "$ready" = true
if ! grep -Fq 'http: request received GET /healthz' "$tmp/debug-daemon.err"; then
    cat "$tmp/debug-daemon.out" "$tmp/debug-daemon.err" >&2
    exit 1
fi

# M2.5 HTTP request log must include method, path, status, bytes, duration and
# client IP in the service log. /healthz is excluded from event audit but its
# service log line must still contain the full structured fields.
grep -Eq 'GET /healthz -> [0-9]+ \([0-9]+ bytes, [0-9]+us, client=' "$tmp/debug-daemon.err" || {
    echo "healthz log line missing structured fields" >&2
    cat "$tmp/debug-daemon.err" >&2
    exit 1
}

# Non-healthz requests must produce an http.request event in events.jsonl.
# The daemon writes to /opt/nodeforge/logs/events.jsonl; in test it uses the
# same fixed path. Verify the event log contains the http.request type.
events_file="/opt/nodeforge/logs/events.jsonl"
if [ -f "$events_file" ]; then
    grep -Fq '"type":"http.request"' "$events_file" || {
        echo "http.request event not found in events.jsonl" >&2
        exit 1
    }
    # The event must include client_ip and duration_us fields.
    grep -Fq '"key":"client_ip"' "$events_file" || {
        echo "http.request event missing client_ip field" >&2
        exit 1
    }
    grep -Fq '"key":"duration_us"' "$events_file" || {
        echo "http.request event missing duration_us field" >&2
        exit 1
    }
fi

# M2.5 service.stopped event must be written on orderly shutdown.
stop_daemon
if [ -f "$events_file" ]; then
    grep -Fq '"type":"service.stopped"' "$events_file" || {
        echo "service.stopped event not found after shutdown" >&2
        exit 1
    }
fi
