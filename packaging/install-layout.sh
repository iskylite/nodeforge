#!/bin/sh
# Materialize the canonical NodeForge layout and migrate a pre-M4.2 install.
# The install root is intentionally read from src/paths.zig: it has one
# authoritative declaration and this script must not introduce a second one.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
install_root=$(sed -nE 's/^pub const install_root = "([^"]+)";$/\1/p' "$repo_root/src/paths.zig")

if [ -z "$install_root" ]; then
    echo "error: unable to read install_root from src/paths.zig" >&2
    exit 1
fi

require_jq() {
    command -v jq >/dev/null 2>&1 || {
        echo "error: jq is required to migrate config.json and catalog.json" >&2
        exit 1
    }
}

move_legacy_dir() {
    legacy=$1
    canonical=$2

    [ -L "$legacy" ] && return 0
    [ -e "$legacy" ] || return 0
    [ -d "$legacy" ] || {
        echo "error: legacy path is not a directory: $legacy" >&2
        exit 1
    }

    if [ -d "$canonical" ]; then
        if [ -n "$(find "$canonical" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
            echo "error: both legacy and canonical directories contain data: $legacy, $canonical" >&2
            echo "       reconcile them manually, then rerun this script" >&2
            exit 1
        fi
        rmdir "$canonical"
    elif [ -e "$canonical" ]; then
        echo "error: canonical path is not a directory: $canonical" >&2
        exit 1
    fi

    mkdir -p "$(dirname "$canonical")"
    mv "$legacy" "$canonical"
}

migrate_config() {
    path=$install_root/config/config.json
    [ -f "$path" ] || return 0
    require_jq
    tmp=$path.m4.2.tmp
    jq \
        --arg iso "$install_root/assets/iso" \
        --arg repos "$install_root/assets/repos" \
        --arg boot "$install_root/assets/boot" \
        '.http.asset_root = $iso | .http.repository_root = $repos | .tftp.asset_root = $boot' \
        "$path" >"$tmp"
    mv "$tmp" "$path"
}

migrate_catalog() {
    path=$install_root/catalog/catalog.json
    [ -f "$path" ] || return 0
    require_jq
    if ! jq -e '[.assets[]? | select(.kind == "iso") | ((.path | type == "string") and (.path | length > 0) and (.path | startswith("/") | not) and (.path | contains("..") | not))] | all' "$path" >/dev/null; then
        echo "error: catalog contains an unsafe ISO path" >&2
        exit 1
    fi
    iso_paths=$(jq -r '.assets[]? | select(.kind == "iso") | .path' "$path")
    while IFS= read -r old_path; do
        [ -n "$old_path" ] || continue
        new_path=${old_path#iso/}
        source=$install_root/assets/$old_path
        destination=$install_root/assets/iso/$new_path
        [ "$source" = "$destination" ] && continue
        [ -e "$source" ] || continue
        if [ -e "$destination" ]; then
            echo "error: ISO migration destination already exists: $destination" >&2
            exit 1
        fi
        mkdir -p "$(dirname "$destination")"
        mv "$source" "$destination"
    done <<EOF
$iso_paths
EOF
    tmp=$path.m4.2.tmp
    jq 'if has("assets") then .assets |= map(if .kind == "iso" and (.path | startswith("iso/")) then .path |= ltrimstr("iso/") else . end) else . end' "$path" >"$tmp"
    mv "$tmp" "$path"
}

mkdir -p \
    "$install_root/bin" "$install_root/systemd" "$install_root/config" "$install_root/catalog" \
    "$install_root/assets/iso" "$install_root/assets/boot" "$install_root/assets/repos" \
    "$install_root/assets/rootfs" "$install_root/assets/initrd" "$install_root/assets/bundles" \
    "$install_root/assets/keys" "$install_root/state/provisioned" "$install_root/logs" \
    "$install_root/work" "$install_root/run"

# Stop nodeforged before invoking this script. The legacy paths are removed as
# their contents move to the canonical resource-oriented layout.
move_legacy_dir "$install_root/tftp" "$install_root/assets/boot"
move_legacy_dir "$install_root/repos" "$install_root/assets/repos"
move_legacy_dir "$install_root/initrd" "$install_root/assets/initrd"
move_legacy_dir "$install_root/rootfs" "$install_root/assets/rootfs"
move_legacy_dir "$install_root/bundles" "$install_root/assets/bundles"
move_legacy_dir "$install_root/provisioned" "$install_root/state/provisioned"
move_legacy_dir "$install_root/state/bootstrap-ssh" "$install_root/assets/keys"

migrate_config
migrate_catalog

sed "s|@INSTALL_ROOT@|$install_root|g" \
    "$repo_root/packaging/systemd/nodeforged.service" >"$install_root/systemd/nodeforged.service"

echo "NodeForge layout ready at $install_root"
