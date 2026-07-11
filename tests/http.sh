#!/bin/sh
set -eu

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
    -e 's/192.168.50.1/127.0.0.1/' \
    -e "s/\"http_port\": 8080/\"http_port\": $port/" \
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
if ! grep -Fqx 'debug: http: request received GET /healthz' "$tmp/debug-daemon.err"; then
    cat "$tmp/debug-daemon.out" "$tmp/debug-daemon.err" >&2
    exit 1
fi
