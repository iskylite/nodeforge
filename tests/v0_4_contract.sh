#!/bin/sh
# v0.4 产品契约闸（二进制/CLI 负向残留 + fresh setup + topology 烟雾）。
#
# 由 `zig build test-v0.4-contract` 调用，入参：cli daemon agent initrd。
# 断言：
#   - 已删除的 per-scope token audience / builder 契约不得残留于产品二进制
#   - diskless 凭据路径为 capability.token（非 agent.token）
#   - rootfs 数据路径无 Authorization / Session 头；rootfs 仅服务端构建
#   - first-boot 稳定错误码齐全
#   - setup 产出 AppConfig v5 / Catalog v6 / nodeforge-root-v2
#   - topology validate 正负路径与 CLI 子命令存在性
set -eu

cli=$1
daemon=$2
agent=$3
initrd=$4
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT HUP INT TERM

bundle=$tmp/bundle
mkdir -p "$bundle"
cp "$cli" "$bundle/nodeforge"
cp "$daemon" "$bundle/nodeforged"
cp "$initrd" "$bundle/nodeforge-initrd"
cp "$agent" "$bundle/nodeforge-agent"
run_cli=$bundle/nodeforge
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# v0.4 凭据契约：install/diskless 读路径共用 volatile boot-session capability。
# 已删除的 per-scope audience 不得残留；diskless handoff 使用 capability 命名的 0400 文件。
legacy_scopes='builder-plan:read|builder-input:read|builder-upload:write|builder-event:append|config:read|rootfs:read|agent:read'
for binary in "$bundle/nodeforged" "$bundle/nodeforge-initrd" "$bundle/nodeforge-agent"; do
    if strings "$binary" | grep -E "$legacy_scopes" >/dev/null; then
        echo "legacy per-scope token audience found in $binary" >&2
        exit 1
    fi
done
if strings "$bundle/nodeforge-initrd" "$bundle/nodeforge-agent" | grep -F 'credentials/agent.token' >/dev/null; then
    echo 'legacy diskless agent.token credential path found in product binaries' >&2
    exit 1
fi
strings "$bundle/nodeforge-initrd" | grep -Fq 'credentials/capability.token'
strings "$bundle/nodeforge-agent" | grep -Fq 'credentials/capability.token'
strings "$bundle/nodeforged" | grep -Fq 'X-NodeForge-Session'

# 大对象数据路径刻意无 token。在源码级闸门：二进制中合法存在 Authorization
#（事件写、AgentPlan 控制面读），但 rootfs 客户端/服务端数据路径不得传播 capability 头。
rootfs_client_block=$(sed -n '/^fn downloadRootfs(/,/^}/p; /^fn rangeOnce(/,/^}/p' "$repo_root/src/initrd.zig")
if printf '%s\n' "$rootfs_client_block" | grep -E 'Authorization|X-NodeForge-Session|access_bearer_token' >/dev/null; then
    echo 'rootfs client data path propagates a capability header' >&2
    exit 1
fi
rootfs_server_block=$(sed -n '/^fn disklessRootfs(/,/^}/p; /^fn disklessPayload(/,/^}/p' "$repo_root/src/http/server.zig")
printf '%s\n' "$rootfs_server_block" | grep -Fq 'authenticateWebhook'
if printf '%s\n' "$rootfs_server_block" | grep -E 'getHeader\("authorization"\)|getHeader\("x-nodeforge-session"\)' >/dev/null; then
    echo 'rootfs/payload server data path accepts capability headers' >&2
    exit 1
fi
if strings "$bundle/nodeforged" | grep -Fq 'http_headers'; then
    echo 'DNF repository header injection survived in nodeforged' >&2
    exit 1
fi

# rootfs 仅服务端。产品二进制不得暴露 node/PXE builder 模式、attempt API、
# placement 属性、upload/finalize 路径或 builder CLI。
for forbidden in 'nodeforge.builder' '/api/v1/builder-attempts/' '/rootfs/register' 'Register a prebuilt rootfs' 'built or registered after the Profile' 'builder.placement' 'builder.eligible' 'BuilderEnvironment' 'BuilderBootAttempt' 'BuilderPlan'; do
    if strings "$bundle/nodeforge" "$bundle/nodeforged" "$bundle/nodeforge-initrd" "$bundle/nodeforge-agent" | grep -Fq "$forbidden"; then
        echo "removed node-builder contract found: $forbidden" >&2
        exit 1
    fi
done

# first-boot 协议保持 replay / expiry / body drift / CAS conflict 分码。
# 丢失任一稳定码会把运维诊断重新塌缩成昔日的 replay 笼统错误。
for code in first_boot.binding_mismatch first_boot.event_invalid first_boot.event_body_drift first_boot.event_conflict first_boot.replay; do
    strings "$bundle/nodeforged" | grep -Fq "$code"
done

nodeforge_version=$(sed -n 's/^const nodeforge_version = "\([^"]*\)";/\1/p' "$root/build.zig")
test -n "$nodeforge_version"
test "$(printf '%s\n' "$($run_cli --version)" | awk '{print $1" "$2}')" = "nodeforge $nodeforge_version"
install=$tmp/install
$run_cli setup --install-root "$install" --non-interactive --yes >"$tmp/setup.json"
test "$(jq -r '.schema_version' "$install/config/config.json")" = 5
test "$(jq -r '.catalog_schema_version' "$install/catalog/manifest.json")" = 6
test "$(sed -n '1p' "$install/.nodeforge-root" | cut -d ' ' -f 1)" = nodeforge-root-v2

help=$tmp/help
$run_cli --install-root "$install" node topology --help-full >"$help"
grep -Fq 'topology' "$help"
$run_cli --install-root "$install" node discovery --help-full >>"$help"
grep -Fq 'discovery' "$help"
$run_cli --install-root "$install" node postprocess show --help-full >>"$help"
grep -Fq 'first-boot' "$help"
# v0.4 rootfs 仅经 nodeforged 管理操作构建。
$run_cli --install-root "$install" profile rootfs build --help-full >>"$help"
grep -Fq 'content-addressed rootfs artifact' "$help"
grep -Fq -- '--detach' "$help"
if $run_cli --install-root "$install" builder --help-full >"$tmp/builder.out" 2>"$tmp/builder.err"; then
    echo 'removed builder command is still callable' >&2
    exit 1
fi
if $run_cli --install-root "$install" profile rootfs register --help-full >"$tmp/rootfs-register.out" 2>"$tmp/rootfs-register.err"; then
    echo 'external rootfs register command is still callable' >&2
    exit 1
fi

cat >"$tmp/topology.json" <<'JSON'
{"interfaces":[{"id":"eno1","mac":"02:00:00:00:00:01","ipv4":{"mode":"dhcp"}}],"bonds":[],"vlans":[],"routes":[]}
JSON
$run_cli --install-root "$install" node topology validate --network-json "$tmp/topology.json" --bootstrap-mac 02:00:00:00:00:01 --deploy -o json >"$tmp/topology.out"
jq -e '.ok and .result.deployable' "$tmp/topology.out" >/dev/null

cat >"$tmp/invalid-topology.json" <<'JSON'
{"interfaces":[{"id":"eno1","mac":"02:00:00:00:00:01","ipv4":{"mode":"dhcp"}},{"id":"eno2","mac":"02:00:00:00:00:02","ipv4":{"mode":"dhcp"}}],"bonds":[],"vlans":[],"routes":[]}
JSON
if $run_cli --install-root "$install" node topology validate --network-json "$tmp/invalid-topology.json" --bootstrap-mac 02:00:00:00:00:01 --deploy -o json >"$tmp/invalid.out" 2>"$tmp/invalid.err"; then
    echo 'invalid topology unexpectedly passed' >&2
    exit 1
fi
grep -Fq 'network.invalid' "$tmp/invalid.out" "$tmp/invalid.err"

if grep -R -E 'Bearer [0-9a-f]{64}|Authorization:|token[=:][^" ]+' "$install/catalog" "$install/state" "$install/logs" 2>/dev/null; then
    echo 'raw capability material found in persistent layout' >&2
    exit 1
fi

printf '%s\n' 'v0.4 contract gate: PASS'
