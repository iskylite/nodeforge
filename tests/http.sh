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
sed '/"policy": {/i\
  "profiles": [{"name":"discovery","mode":"discovery","distro":"rocky","version":"9.7","arch":"aarch64"}],' "$tmp/config.json" > "$tmp/config.with-profile"
mv "$tmp/config.with-profile" "$tmp/config.json"

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
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/config" >"$tmp/config-status"
grep -Fq '"config":"valid"' "$tmp/config-status"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/status" >"$tmp/status"
grep -Fq '"service":"running"' "$tmp/status"
grep -Fq '"config_valid":true' "$tmp/status"
curl --silent --fail -X POST "http://127.0.0.1:$port/api/v1/management/config/validations" >"$tmp/validate"
grep -Fqx '{"ok":true,"result":{}}' "$tmp/validate"

# M4.4: config/reload route deleted; config mutations now use PATCH /management/config
# which publishes in-process. The CLI config set test below exercises this path.

# M4.3 runtime-safe config set publishes in-process; listener fields are
# classified restart-required and leave the file unchanged.
"$cli" config set logging.level=info events.keep=4 -c "$tmp/config.json" >"$tmp/config-set"
kill -0 "$pid"
grep -Fq '"level": "info"' "$tmp/config.json"
grep -Fq '"keep": 4' "$tmp/config.json"
before_restart_required=$(sha256sum "$tmp/config.json" | awk '{print $1}')
if "$cli" config set server.http_port=29999 -c "$tmp/config.json" >"$tmp/config-restart" 2>&1; then
    echo "restart-required config mutation unexpectedly succeeded" >&2
    exit 1
fi
after_restart_required=$(sha256sum "$tmp/config.json" | awk '{print $1}')
test "$before_restart_required" = "$after_restart_required"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/nodes" >"$tmp/nodes-view"
grep -Fq '"nodes":[]' "$tmp/nodes-view"
grep -Eq '"view_revision":\{"config":[0-9]+,"catalog":[0-9]+,"node_status":[0-9]+,"deployment":[0-9]+,"inventory":[0-9]+\}' "$tmp/nodes-view"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/profiles" >"$tmp/profiles-view"
grep -Fq '"name":"discovery"' "$tmp/profiles-view"

# M4.3 daemon-owned node mutations persist and publish without restarting.
daemon_pid=$pid
"$cli" node add test-node mac=02:00:00:00:00:11 arch=aarch64 profile=discovery -c "$tmp/config.json" >"$tmp/node-add"
kill -0 "$daemon_pid"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/nodes/test-node" >"$tmp/node-after-add"
grep -Fq '"id":"test-node"' "$tmp/node-after-add"
"$cli" node set test-node hostname=worker-11 -c "$tmp/config.json" >"$tmp/node-set"
kill -0 "$daemon_pid"
grep -Fq '"hostname": "worker-11"' "$tmp/config.json"
"$cli" node unset test-node hostname -c "$tmp/config.json" >"$tmp/node-unset"
kill -0 "$daemon_pid"
if grep -Fq '"hostname": "worker-11"' "$tmp/config.json"; then
    echo "node unset did not clear hostname" >&2
    exit 1
fi
"$cli" node remove test-node -c "$tmp/config.json" >"$tmp/node-remove"
kill -0 "$daemon_pid"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/nodes" >"$tmp/nodes-after-remove"
grep -Fq '"nodes":[]' "$tmp/nodes-after-remove"

# M2 read-only DHCP/runtime commands consume the validated local config and
# daemon management routes. The empty pool is still a useful contract check.
"$cli" runtime dhcp-leases -c "$tmp/config.json" >"$tmp/dhcp-leases"
grep -Eq '^(IP[[:space:]]+MAC[[:space:]]+PHASE[[:space:]]+EXPIRES|No DHCP leases\.)' "$tmp/dhcp-leases"
"$cli" runtime dhcp-unknown -c "$tmp/config.json" >"$tmp/dhcp-unknown"
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

# M4.3 durable operation: the first failed import records a terminal operation;
# retrying the same key reuses it instead of executing the side effect again.
op_status=$(curl --silent -o "$tmp/op-first" -w '%{http_code}' -X POST -H 'Idempotency-Key: missing-iso-test' "http://127.0.0.1:$port/api/v1/management/install-sources?filename=missing.iso&sha256=0000000000000000000000000000000000000000000000000000000000000000")
test "$op_status" = 400
op_status=$(curl --silent -o "$tmp/op-reused" -w '%{http_code}' -X POST -H 'Idempotency-Key: missing-iso-test' "http://127.0.0.1:$port/api/v1/management/install-sources?filename=another-missing.iso&sha256=0000000000000000000000000000000000000000000000000000000000000000")
test "$op_status" = 202
grep -Fq '"state":"failed"' "$tmp/op-reused"
operation_id=$(sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p' "$tmp/op-reused")
test ${#operation_id} = 32

# M4.3 migration dry-run is daemon-owned, side-effect free and reproducible
# for the same config/catalog revision pair.
plan_status=$(curl --silent -o "$tmp/migration-plan-1" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{}' "http://127.0.0.1:$port/api/v1/management/catalog/migration-plans")
test "$plan_status" = 201
grep -Fq '"applicable":true' "$tmp/migration-plan-1"
grep -Fq '"renames":[]' "$tmp/migration-plan-1"
curl --silent --fail -X POST -H 'Content-Type: application/json' --data '{}' "http://127.0.0.1:$port/api/v1/management/catalog/migration-plans" >"$tmp/migration-plan-2"
digest_1=$(sed -n 's/.*"plan_digest":"\([0-9a-f]*\)".*/\1/p' "$tmp/migration-plan-1")
digest_2=$(sed -n 's/.*"plan_digest":"\([0-9a-f]*\)".*/\1/p' "$tmp/migration-plan-2")
test ${#digest_1} = 64
test "$digest_1" = "$digest_2"
"$cli" catalog migrate --dry-run -c "$tmp/config.json" >"$tmp/migration-plan-cli"
grep -Fq 'Applicable: yes' "$tmp/migration-plan-cli"
config_before_migration=$(cksum "$tmp/config.json")
catalog_present_before=false
test -e "$tmp/catalog.json" && catalog_present_before=true
"$cli" catalog migrate --apply --plan-digest "$digest_1" -c "$tmp/config.json" >"$tmp/migration-apply-cli"
grep -Fq '"kind":"catalog_migration"' "$tmp/migration-apply-cli"
grep -Fq '"state":"succeeded"' "$tmp/migration-apply-cli"
test ! -e "$tmp/model-transactions/$digest_1.json"
test "$config_before_migration" = "$(cksum "$tmp/config.json")"
test "$catalog_present_before" = false
curl --silent --fail -X POST -H 'Content-Type: application/json' --data '{}' "http://127.0.0.1:$port/api/v1/management/catalog/migration-plans" >"$tmp/migration-plan-after-noop"
digest_after_noop=$(sed -n 's/.*"plan_digest":"\([0-9a-f]*\)".*/\1/p' "$tmp/migration-plan-after-noop")
test "$digest_1" = "$digest_after_noop"

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
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/operations/$operation_id" >"$tmp/op-after-restart"
grep -Fq '"state":"failed"' "$tmp/op-after-restart"
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
