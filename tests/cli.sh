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

# 从 catalog.example.json 构建 manifest 布局 catalog 目录。
# store.load 只接受目录路径（manifest 布局），单文件加载已移除。
# 测试需要从 repo 内的示例文件构造完整目录布局：逐实体提取 JSON、
# 计算 SHA-256 摘要、拼装 manifest 并生成 transaction_id。
catalog_dir="$tmp/catalog"
mkdir -p "$catalog_dir"
names="distros profiles nodes provisioning_bundles repositories assets install_sources boot_bundles discovery_policy unknown_client_observations"
for name in $names; do
    if [ "$name" = "discovery_policy" ]; then
        # discovery_policy 是 singleton struct，不是数组，需要输出对象而非 []。
        printf '{"unknown_action":"record","observation_retention_days":30,"revision":1}\n' > "$catalog_dir/$name.json"
    else
        jq --arg name "$name" '.[$name] // []' "$root/catalog.example.json" > "$catalog_dir/$name.json"
    fi
done
# 拼装 manifest entities 数组，同时累积 transaction_id 输入。
# transaction_id = sha256(revision + 每个实体的 name + sha256)。
entities_json="["
tx_input=""
first=1
for name in $names; do
    digest=$(sha256sum "$catalog_dir/$name.json" | cut -d ' ' -f 1)
    if [ $first -eq 0 ]; then entities_json="$entities_json,"; fi
    entities_json="$entities_json{\"name\":\"$name\",\"file\":\"$name.json\",\"sha256\":\"$digest\"}"
    tx_input="${tx_input}${name}${digest}"
    first=0
done
entities_json="$entities_json]"
transaction_id=$(printf "1%s" "$tx_input" | sha256sum | cut -d ' ' -f 1)
cat > "$catalog_dir/manifest.json" <<EOF
{
  "layout_schema_version": 1,
  "catalog_schema_version": 5,
  "catalog_revision": 1,
  "transaction_id": "$transaction_id",
  "entities": $entities_json
}
EOF

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
grep -q -- "--log-level" "$tmp/setup-help"
"$cli" profile create --help >"$tmp/profile-create-help"
grep -Fq 'Create an install or diskless profile from an imported install source' "$tmp/profile-create-help"
grep -Fq '<install-source>[-<qualifier>]-<install|diskless>' "$tmp/profile-create-help"
grep -Fq -- '--qualifier' "$tmp/profile-create-help"
"$cli" profile set --help >"$tmp/profile-set-help"
grep -Fq 'exact mutable Profile PropertySpec key' "$tmp/profile-set-help"
grep -Fq 'Collections require' "$tmp/profile-set-help"
"$cli" profile set --help-full >"$tmp/profile-set-help-full"
grep -Fq 'install.storage.mode' "$tmp/profile-set-help-full"
grep -Fq 'VALUES/CONSTRAINT' "$tmp/profile-set-help-full"
grep -Fq 'single|lvm|raid0|raid1|raid5|raid6|raid10|raid0-lvm|raid1-lvm|raid5-lvm|raid6-lvm|raid10-lvm' "$tmp/profile-set-help-full"
grep -Fq 'no|prohibit-password|yes' "$tmp/profile-set-help-full"
grep -Fq 'true|false' "$tmp/profile-set-help-full"
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
grep -Fq 'dhcp|static' "$tmp/node-set-help-full"
grep -Fq '1..32' "$tmp/node-set-help-full"
"$cli" node unset --help >"$tmp/node-unset-help"
grep -Fq 'overrides.* scalar keys' "$tmp/node-unset-help"
"$cli" node retry --help >"$tmp/node-retry-help"
grep -Fq 'Supersede a stuck active install or diskless session' "$tmp/node-retry-help"
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
grep -Fq 'Architecture used with --distro and --version; allowed: x86_64, aarch64' "$tmp/asset-register-help"

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
"$cli" assets boot-bundle list --help >"$tmp/boot-bundle-list-help"
"$cli" assets boot-bundle show --help >"$tmp/boot-bundle-show-help"
grep -Fq 'BootBundle 名称' "$tmp/boot-bundle-show-help"
"$cli" assets initrd build --help >"$tmp/initrd-build-help"
grep -Fq -- '--from-install-source' "$tmp/initrd-build-help"
grep -Fq -- '--kernel-release' "$tmp/initrd-build-help"
grep -Fq 'preserves the ISO vendor initrd' "$tmp/initrd-build-help"
"$cli" profile rootfs plan --help >"$tmp/profile-rootfs-plan-help"
grep -Fq 'rootfs input digest and cache state' "$tmp/profile-rootfs-plan-help"
"$cli" profile rootfs build --help >"$tmp/profile-rootfs-build-help"
grep -Fq -- '--if-input-digest' "$tmp/profile-rootfs-build-help"
"$cli" profile rootfs register --help >"$tmp/profile-rootfs-register-help"
grep -Fq -- '--uncompressed-size' "$tmp/profile-rootfs-register-help"
grep -Fq -- '--path' "$tmp/profile-rootfs-register-help"
"$cli" profile rootfs status --help >"$tmp/profile-rootfs-status-help"
grep -Fq 'registered rootfs artifact' "$tmp/profile-rootfs-status-help"
"$cli" node boot preview --help >"$tmp/node-boot-preview-help"
grep -Fq 'without creating a session or token' "$tmp/node-boot-preview-help"
if "$cli" node boot-prepare --help >"$tmp/node-boot-prepare-help" 2>&1; then
    echo "boot-prepare must be an internal runtime transition, not a public CLI command" >&2
    exit 1
fi
"$cli" profile clone --help >"$tmp/profile-clone-help"
grep -Fq 'Atomically clone a Profile desired configuration' "$tmp/profile-clone-help"
# v0.2.3 §5.2: clone 扩展 flags（--build/--detach）与 property patch 参数。
grep -Fq -- '--build' "$tmp/profile-clone-help"
grep -Fq -- '--detach' "$tmp/profile-clone-help"
grep -Fq 'KEY=VALUE' "$tmp/profile-clone-help"
grep -Fq -- '--new-ssh-keys' "$tmp/profile-clone-help"
# §5.2: --detach 单独使用是 CLI 输入错误（exit 2），连接 daemon 前拒绝。
if "$cli" profile clone install diskless-copy --detach -o json >"$tmp/profile-clone-detach-alone" 2>&1; then
    echo "clone --detach without --build unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi
grep -Fq '"code":"profile.clone_invalid"' "$tmp/profile-clone-detach-alone"
# §5.2: 不可 patch 的键（provenance/revision/ssh_identity 不在 PropertySpec）
# 是 CLI 输入错误（exit 2）。
if "$cli" profile clone install diskless-copy provenance.origin=create -o json >"$tmp/profile-clone-bad-property" 2>&1; then
    echo "clone with non-patchable property unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi
grep -Fq '"code":"profile.invalid_property"' "$tmp/profile-clone-bad-property"
# §5.2: 集合键须走 values 命令（exit 2）。
if "$cli" profile clone install diskless-copy install.storage.partitions=x -o json >"$tmp/profile-clone-collection-key" 2>&1; then
    echo "clone with collection key unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi
grep -Fq '"code":"property.list_operation_required"' "$tmp/profile-clone-collection-key"
"$cli" operation list --help >"$tmp/operation-list-help"
"$cli" operation follow --help >"$tmp/operation-follow-help"
grep -Fq 'without cancelling' "$tmp/operation-follow-help"

"$cli" assets import --help >"$tmp/assets-import-help"
grep -Fq -- '--qualifier' "$tmp/assets-import-help"
grep -Fq 'Readable local ISO path; e.g. /srv/iso/ubuntu-22.04.5-live-server-arm64.iso' "$tmp/assets-import-help"
"$cli" assets install-source --help >"$tmp/install-source-help"
grep -Fq 'software' "$tmp/install-source-help"
"$cli" assets repository software show --help >"$tmp/repository-software-help"
grep -Fq -- '--kind' "$tmp/repository-software-help"
grep -Fq 'environment, group, task, metapackage, package' "$tmp/repository-software-help"
"$cli" assets install-source software list --help >"$tmp/install-source-software-help"
grep -Fq 'omit to list all kinds' "$tmp/install-source-software-help"
grep -Fq 'DNF: environment/group/package; APT: task/metapackage/package' "$tmp/install-source-software-help"
"$cli" assets install-source software list --help-full >"$tmp/install-source-software-help-full"
grep -Fq 'environment, group, task, metapackage, package' "$tmp/install-source-software-help-full"
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
grep -Fq 'Override only the ISO-basename-derived InstallSource base' "$tmp/assets-import-help"
grep -Fq 'V10-SP3-2403-Release-20240426' "$tmp/assets-import-help"
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
    "catalog show"; do
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

"$cli" --version | grep -Eq '^nodeforge 0\.2\.3 \(commit [0-9a-f]{12}|unknown'
"$cli" -v | grep -Fq 'built '
"$daemon" --version | grep -Eq '^nodeforged 0\.2\.3 \(commit [0-9a-f]{12}|unknown'

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
"$cli" config validate -c "$root/config.example.json" -C "$catalog_dir" -o json >"$tmp/validate"
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
"$cli" assets list -C "$catalog_dir" >"$tmp/asset-list"
grep -Eq '^NAME[[:space:]]+KIND[[:space:]]+PATH[[:space:]]*$' "$tmp/asset-list"
grep -F 'rocky-9.7-aarch64-installer-kernel' "$tmp/asset-list" | grep -Fq 'kernel'
if LC_ALL=C grep -q "$(printf '\033')" "$tmp/asset-list"; then
    echo "human asset list must not emit ANSI outside a TTY" >&2
    exit 1
fi
"$cli" assets list -C "$catalog_dir" --no-color >"$tmp/asset-list-no-color"
cmp "$tmp/asset-list" "$tmp/asset-list-no-color"
"$cli" assets list -C "$catalog_dir" -o json >"$tmp/asset-list-json"
jq -e '.ok and (.result.assets | length > 0) and .result.assets[0].name' "$tmp/asset-list-json" >/dev/null
"$cli" assets list -C "$catalog_dir" -o jsonl >"$tmp/asset-list-jsonl"
test "$(wc -l <"$tmp/asset-list-jsonl" | tr -d ' ')" = "$(jq '.assets | length' "$root/catalog.example.json")"
jq -e '.ok and .result.name and .result.kind and .result.path' "$tmp/asset-list-jsonl" >/dev/null
"$cli" assets list -C "$catalog_dir" --columns name,path --no-header >"$tmp/asset-list-columns"
if grep -Fq 'KIND' "$tmp/asset-list-columns"; then
    echo "filtered asset list unexpectedly retained KIND" >&2
    exit 1
fi
if "$cli" assets list -C "$catalog_dir" --columns missing >"$tmp/asset-list-bad-column.out" 2>"$tmp/asset-list-bad-column.err"; then
    echo "asset list accepted an unknown output column" >&2
    exit 1
else
    test "$?" -eq 2
fi
test ! -s "$tmp/asset-list-bad-column.out"
grep -Fq 'unknown key' "$tmp/asset-list-bad-column.err"
if "$cli" assets list -C "$catalog_dir" -o json --no-header >"$tmp/asset-list-json-header.out" 2>"$tmp/asset-list-json-header.err"; then
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
"$daemon" -K -c "$root/config.example.json" -C "$catalog_dir" >"$tmp/daemon-check-config" 2>&1
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* info \[nodeforge\] config: valid ' "$tmp/daemon-check-config"

# Service log routing is selected per invocation. File mode keeps normal
# terminal stderr quiet, while both mode duplicates the bounded service line.
service_log="$tmp/nodeforged.log"
"$daemon" -K -c "$root/config.example.json" -C "$catalog_dir" --log-output file --log-file "$service_log" >"$tmp/daemon-file-out" 2>"$tmp/daemon-file-err"
if grep -Fq '[nodeforge]' "$tmp/daemon-file-err"; then
    echo "file log mode unexpectedly wrote a service log to stderr" >&2
    exit 1
fi
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* info \[nodeforge\] config: valid ' "$service_log"

failed_service_log="$tmp/nodeforged-failure.log"
if "$daemon" -K -c "$tmp/missing-daemon-config.json" -C "$catalog_dir" --log-output file --log-file "$failed_service_log" >"$tmp/daemon-failure-out" 2>"$tmp/daemon-failure-err"; then
    echo "missing daemon config unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 1
fi
grep -Fq 'err [nodeforge] config: cannot load' "$failed_service_log"

"$daemon" -K -c "$root/config.example.json" -C "$catalog_dir" --log-output both --log-file "$service_log" >"$tmp/daemon-both-out" 2>"$tmp/daemon-both-err"
grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T.* info \[nodeforge\] config: valid ' "$tmp/daemon-both-err"

if "$daemon" -K -c "$root/config.example.json" -C "$catalog_dir" --log-output nowhere >"$tmp/daemon-invalid-log-output" 2>&1; then
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

# §12.4 --session 与 --latest 互斥，同时给出是 usage error。
if "$cli" node trace node-01 --session "$session_id" --latest --events-path "$events_dir/events.jsonl" -o json >"$tmp/trace-conflicting-flags" 2>&1; then
    echo "conflicting --session/--latest unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi
grep -Fq '"code":"trace.conflicting_flags"' "$tmp/trace-conflicting-flags"

# §12.2 node deploy 的 enabled 位置参数可缺省（默认 true）；非法字面量在
# 读取 config/daemon 之前就以 exit 2 拒绝。
"$cli" node deploy --help >"$tmp/node-deploy-help"
grep -Fq '[true|false]' "$tmp/node-deploy-help"
grep -Fq '(default: true)' "$tmp/node-deploy-help"
if "$cli" node deploy node-01 yes -o json >"$tmp/node-deploy-invalid" 2>&1; then
    echo "invalid deploy value unexpectedly succeeded" >&2
    exit 1
else
    test "$?" -eq 2
fi
grep -Fq '"code":"deploy.invalid_value"' "$tmp/node-deploy-invalid"

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
