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

# Exercise M4.7 executable-based install-root discovery rather than allowing
# test-only fallback paths.
install="$tmp/install"
mkdir -p "$install/bin"
cp "$cli" "$install/bin/nodeforge"
cp "$daemon" "$install/bin/nodeforged"
: >"$install/.nodeforge-root"
cli="$install/bin/nodeforge"
daemon="$install/bin/nodeforged"

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
    -e "s/\"http_port\": 18080/\"http_port\": $port/" \
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
curl --silent --fail -D "$tmp/config-headers" "http://127.0.0.1:$port/api/v1/management/config" >"$tmp/config-status"
grep -Fq '"config":"valid"' "$tmp/config-status"
config_revision=$(sed -n 's/.*"revision":\([0-9][0-9]*\).*/\1/p' "$tmp/config-status")
test -n "$config_revision"
grep -Eqi "^etag:[[:space:]]*\"$config_revision\"" "$tmp/config-headers"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/status" >"$tmp/status"
grep -Fq '"service":"running"' "$tmp/status"
grep -Fq '"config_valid":true' "$tmp/status"
curl --silent --fail -X POST "http://127.0.0.1:$port/api/v1/management/config/validations" >"$tmp/validate"
grep -Fqx '{"ok":true,"result":{}}' "$tmp/validate"

curl --silent --fail "http://127.0.0.1:$port/api/v1/management/nodes" >"$tmp/nodes-view"
grep -Fq '"items":[]' "$tmp/nodes-view"
grep -Eq '"view_revision":\{"config":[0-9]+,"catalog":[0-9]+,"node_status":[0-9]+,"deployment":[0-9]+,"inventory":[0-9]+\}' "$tmp/nodes-view"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/profiles" >"$tmp/profiles-view"
grep -Fq '"name":"discovery"' "$tmp/profiles-view"
"$cli" profile create rocky-fresh rocky-9.7-aarch64-dvd -c "$tmp/config.json" >"$tmp/profile-create"
grep -Fq 'install profile created' "$tmp/profile-create"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/profiles/rocky-fresh" >"$tmp/profile-created"
grep -Fq '"install_source":"rocky-9.7-aarch64-dvd"' "$tmp/profile-created"
grep -Fq '"destructive":true' "$tmp/profile-created"
if "$cli" profile create rocky-fresh rocky-9.7-aarch64-dvd -c "$tmp/config.json" >"$tmp/profile-create-duplicate" 2>&1; then
    echo "profile create unexpectedly accepted a duplicate name" >&2
    exit 1
fi
grep -Fq 'profile.already_exists' "$tmp/profile-create-duplicate"
"$cli" profile set rocky-fresh boot_disk=/dev/nvme0n1 -c "$tmp/config.json" >"$tmp/profile-disk"
grep -Fq 'profile boot disk updated' "$tmp/profile-disk"
"$cli" profile show rocky-fresh -c "$tmp/config.json" >"$tmp/profile-disk-show"
grep -Fq 'Settable properties (nodeforge profile set rocky-fresh key=value)' "$tmp/profile-disk-show"
grep -Fq 'boot_disk=/dev/nvme0n1' "$tmp/profile-disk-show"
grep -Fq 'wipe          yes' "$tmp/profile-disk-show"
grep -Fq 'Owner / action' "$tmp/profile-disk-show"
grep -Fq 'nodeforge profile set rocky-fresh boot_disk=/dev/<device>' "$tmp/profile-disk-show"
"$cli" profile set rocky-fresh 'kernel_args=iommu=pt' -c "$tmp/config.json" >"$tmp/profile-kernel-set"
"$cli" profile show rocky-fresh -c "$tmp/config.json" >"$tmp/profile-kernel-show"
grep -Fq 'kernel_args=iommu=pt' "$tmp/profile-kernel-show"
"$cli" profile unset rocky-fresh kernel_args -c "$tmp/config.json" >"$tmp/profile-kernel-unset"
if "$cli" profile create missing-source does-not-exist -c "$tmp/config.json" >"$tmp/profile-create-missing" 2>&1; then
    echo "profile create unexpectedly accepted a missing install source" >&2
    exit 1
fi
grep -Fq 'profile.install_source_not_found' "$tmp/profile-create-missing"
"$cli" profile show discovery -c "$tmp/config.json" >"$tmp/profile-show"
grep -Fq '# kernel_args is unset' "$tmp/profile-show"
# M4.6 的窄 profile mutation：null/unset 可幂等应用；discovery 非空参数必须
# 由稳定校验错误拒绝，并且不能改变配置文件。
"$cli" profile unset discovery kernel_args -c "$tmp/config.json" >"$tmp/profile-unset"
before_kernel_reject=$(sha256sum "$tmp/config.json" | awk '{print $1}')
if "$cli" profile set discovery 'kernel_args=iommu=pt' -c "$tmp/config.json" >"$tmp/profile-set-invalid" 2>&1; then
    echo "discovery profile unexpectedly accepted kernel args" >&2
    exit 1
fi
grep -Fq 'profile.kernel_args_invalid' "$tmp/profile-set-invalid"
after_kernel_reject=$(sha256sum "$tmp/config.json" | awk '{print $1}')
test "$before_kernel_reject" = "$after_kernel_reject"

# M4.5 collection pagination (§9.14.11.1#3): limit 校验与 cursor/view_revision 字段。
pg_bad=$(curl --silent -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/v1/management/nodes?limit=0")
test "$pg_bad" = 400
pg_bad=$(curl --silent -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/v1/management/nodes?limit=999")
test "$pg_bad" = 400
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/nodes?limit=1" >"$tmp/pg"
grep -Fq '"items":' "$tmp/pg"
grep -Fq '"next_cursor":' "$tmp/pg"
grep -Fq '"view_revision":' "$tmp/pg"

# M4.3 daemon-owned node mutations persist and publish without restarting.
daemon_pid=$pid
"$cli" node add test-node mac=02:00:00:00:00:11 arch=aarch64 profile=discovery -c "$tmp/config.json" >"$tmp/node-add"
kill -0 "$daemon_pid"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/nodes/test-node" >"$tmp/node-after-add"
grep -Fq '"id":"test-node"' "$tmp/node-after-add"
"$cli" node show test-node -c "$tmp/config.json" >"$tmp/node-show"
for section in 'Node test-node' 'Profile' 'Effective system' 'Deployment' 'Runtime' 'Inventory' 'View revisions'; do
    grep -Fq "$section" "$tmp/node-show"
done
grep -Fq 'Owner / action' "$tmp/node-show"
grep -Fq 'nodeforge profile set discovery' "$tmp/node-show"
grep -Fq 'nodeforge node retry test-node [--force]' "$tmp/node-show"
for property in 'mac=02:00:00:00:00:11' 'arch=aarch64' 'profile=discovery' 'deploy=true' 'http_accel=false'; do
    grep -Fq "$property" "$tmp/node-show"
done
"$cli" node set test-node mac=02:00:00:00:00:11 arch=aarch64 profile=discovery ip=127.0.0.111 hostname=worker-11 deploy=true http_accel=false -c "$tmp/config.json" >"$tmp/node-set"
kill -0 "$daemon_pid"
grep -Fq '"hostname": "worker-11"' "$tmp/config.json"
"$cli" node show test-node -c "$tmp/config.json" >"$tmp/node-show-after-set"
for property in 'ip=127.0.0.111' 'hostname=worker-11'; do
    grep -Fq "$property" "$tmp/node-show-after-set"
done
"$cli" node unset test-node ip hostname -c "$tmp/config.json" >"$tmp/node-unset"
kill -0 "$daemon_pid"
if grep -Fq '"hostname": "worker-11"' "$tmp/config.json"; then
    echo "node unset did not clear hostname" >&2
    exit 1
fi
"$cli" node remove test-node -c "$tmp/config.json" >"$tmp/node-remove"
kill -0 "$daemon_pid"
curl --silent --fail "http://127.0.0.1:$port/api/v1/management/nodes" >"$tmp/nodes-after-remove"
grep -Fq '"items":[]' "$tmp/nodes-after-remove"
if "$cli" node add missing-profile mac=02:00:00:00:00:12 arch=aarch64 profile=does-not-exist -c "$tmp/config.json" >"$tmp/node-missing-profile" 2>&1; then
    echo "node add unexpectedly accepted a missing profile" >&2
    exit 1
fi
grep -Fq 'node.profile_not_found' "$tmp/node-missing-profile"
"$cli" node add install-node mac=02:00:00:00:00:13 arch=aarch64 profile=rocky-fresh -c "$tmp/config.json" >"$tmp/install-node-add"
if "$cli" node add install-node mac=02:00:00:00:00:14 arch=aarch64 profile=rocky-fresh -c "$tmp/config.json" >"$tmp/node-duplicate-id" 2>&1; then
    echo "node add unexpectedly accepted a duplicate identifier" >&2
    exit 1
fi
grep -Fq 'node.already_exists' "$tmp/node-duplicate-id"
if "$cli" node add duplicate-mac mac=02:00:00:00:00:13 arch=aarch64 profile=rocky-fresh -c "$tmp/config.json" >"$tmp/node-duplicate-mac" 2>&1; then
    echo "node add unexpectedly accepted a duplicate MAC" >&2
    exit 1
fi
grep -Fq 'node.duplicate_mac' "$tmp/node-duplicate-mac"
"$cli" node show install-node -c "$tmp/config.json" >"$tmp/install-node-show"
grep -Fq 'Intent        initial-armed' "$tmp/install-node-show"
grep -Fq 'PXE ready     yes' "$tmp/install-node-show"

# M2 read-only DHCP/runtime commands consume the validated local config and
# daemon management routes. The empty pool is still a useful contract check.
"$cli" runtime dhcp-leases -c "$tmp/config.json" >"$tmp/dhcp-leases"
grep -Eq '^(IP[[:space:]]+MAC[[:space:]]+PHASE[[:space:]]+EXPIRES|No DHCP leases\.)' "$tmp/dhcp-leases"
"$cli" runtime dhcp-unknown -c "$tmp/config.json" >"$tmp/dhcp-unknown"
grep -Eq '^(IP[[:space:]]+MAC[[:space:]]+PHASE[[:space:]]+EXPIRES|No unknown clients\.)' "$tmp/dhcp-unknown"
"$cli" node list -c "$tmp/config.json" >"$tmp/node-list"
grep -Fqx 'No nodes registered.' "$tmp/node-list"

"$cli" status -c "$tmp/config.json" >"$tmp/status-command"
for check in 'Overall' 'Process' 'Loopback HTTP' 'Advertised HTTP' 'Management API' 'Active config' 'Catalog API' 'DHCP API' 'TFTP API' 'TFTP transfers'; do
    grep -Fq "$check" "$tmp/status-command"
done
grep -Fq 'OK nodeforged operational' "$tmp/status-command"
"$cli" status -o json -c "$tmp/config.json" >"$tmp/status-command.json"
jq -e '.ok and .checks.process and .checks.loopback_http and .checks.advertised_http and .checks.management_api and .checks.active_config and .checks.catalog_api and .checks.dhcp_api and .checks.tftp_api' "$tmp/status-command.json" >/dev/null

if "$daemon" --check -c "$tmp/config.json" -C "$tmp/catalog.json" >"$tmp/preflight" 2>&1; then
    echo "preflight unexpectedly accepted an active HTTP listener" >&2
    exit 1
fi

if "$daemon" -c "$tmp/config.json" -C "$tmp/catalog.json" >"$tmp/second-daemon" 2>&1; then
    echo "second daemon unexpectedly bound the active HTTP listener" >&2
    exit 1
fi

curl --silent --fail-with-body "http://127.0.0.1:$port/not-found" >"$tmp/not-found" 2>&1 || true
# M4.5：错误信封带 request_id，用前缀子串校验 code/message 并断言 request_id 存在。
grep -Fq '{"ok":false,"error":{"code":"http.not_found","message":"route not found","request_id":"' "$tmp/not-found"
grep -Eq '"request_id":"[0-9a-f]{32}"' "$tmp/not-found"

# M4.3 durable operation: the first failed import records a terminal operation;
# retrying the same key reuses it instead of executing the side effect again.
# Key includes the shell PID so prior runs' persisted operations don't make the
# first call reuse an existing operation (which would return 202, not 400).
iso_key="missing-iso-test-$$"
op_status=$(curl --silent -o "$tmp/op-first" -w '%{http_code}' -X POST -H "Idempotency-Key: $iso_key" -H 'Content-Type: application/json' --data '{"filename":"missing.iso","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}' "http://127.0.0.1:$port/api/v1/management/install-sources")
test "$op_status" = 400
op_status=$(curl --silent -o "$tmp/op-reused" -w '%{http_code}' -X POST -H "Idempotency-Key: $iso_key" -H 'Content-Type: application/json' --data '{"filename":"another-missing.iso","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}' "http://127.0.0.1:$port/api/v1/management/install-sources")
test "$op_status" = 202
grep -Fq '"state":"failed"' "$tmp/op-reused"
operation_id=$(sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p' "$tmp/op-reused")
test ${#operation_id} = 32

# M4.3 migration dry-run is daemon-owned, side-effect free and reproducible
# for the same config/catalog revision pair.
plan_status=$(curl --silent -o "$tmp/migration-plan-1" -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data '{}' "http://127.0.0.1:$port/api/v1/management/catalog/migration-plans")
test "$plan_status" = 200
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

# M4.5：HTTP 契约补全--405+Allow、415、428、统一安全头和错误信封 request_id。
allow_status=$(curl --silent -o "$tmp/mna" -D "$tmp/mna-headers" -w '%{http_code}' -X PUT "http://127.0.0.1:$port/api/v1/management/config")
test "$allow_status" = 405
grep -Eqi '^allow:[[:space:]]*get' "$tmp/mna-headers"
grep -Fq '"code":"http.method_not_allowed"' "$tmp/mna"
grep -Fq '"request_id"' "$tmp/mna"
mt_status=$(curl --silent -o "$tmp/mt" -w '%{http_code}' -X POST -H 'Content-Type: text/plain' --data 'x' "http://127.0.0.1:$port/api/v1/management/assets")
test "$mt_status" = 415
grep -Fq '"code":"http.unsupported_media_type"' "$tmp/mt"
patch_status=$(curl --silent -o "$tmp/config-patch" -w '%{http_code}' -X PATCH -H 'Content-Type: application/json' --data '{}' "http://127.0.0.1:$port/api/v1/management/config")
test "$patch_status" = 405
grep -Fq '"code":"http.method_not_allowed"' "$tmp/config-patch"
curl --silent -D "$tmp/sec-headers" -o /dev/null "http://127.0.0.1:$port/api/v1/management/config"
grep -Eqi '^cache-control:[[:space:]]*no-store,[[:space:]]*private' "$tmp/sec-headers"
grep -Eqi '^x-content-type-options:[[:space:]]*nosniff' "$tmp/sec-headers"

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
