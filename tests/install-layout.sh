#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

test_root="$tmp/nodeforge"
mkdir -p "$tmp/repo/src" "$tmp/repo/packaging/systemd"
sed "s|/opt/nodeforge|$test_root|" "$repo_root/src/paths.zig" >"$tmp/repo/src/paths.zig"
cp "$repo_root/packaging/install-layout.sh" "$tmp/repo/packaging/"
cp "$repo_root/packaging/systemd/nodeforged.service" "$tmp/repo/packaging/systemd/nodeforged.service"

mkdir -p \
    "$test_root/tftp/efi" \
    "$test_root/repos/rocky-9.7-aarch64-iso" \
    "$test_root/state/bootstrap-ssh" \
    "$test_root/provisioned/node-01" \
    "$test_root/config" "$test_root/catalog" "$test_root/assets/iso"
printf 'grub' >"$test_root/tftp/efi/grubaa64.efi"
printf 'repo' >"$test_root/repos/rocky-9.7-aarch64-iso/repomd.xml"
printf 'key' >"$test_root/state/bootstrap-ssh/id_ed25519"
printf 'iso' >"$test_root/assets/iso/rocky.iso"
printf 'legacy iso' >"$test_root/assets/legacy.iso"
cat >"$test_root/config/config.json" <<EOF
{"http":{"asset_root":"$test_root/assets","repository_root":"$test_root/repos"},"tftp":{"asset_root":"$test_root/tftp"}}
EOF
cat >"$test_root/catalog/catalog.json" <<'EOF'
{"assets":[{"name":"iso","kind":"iso","path":"iso/rocky.iso"},{"name":"legacy-iso","kind":"iso","path":"legacy.iso"},{"name":"kernel","kind":"kernel","path":"install/rocky/vmlinuz"}]}
EOF

sh "$tmp/repo/packaging/install-layout.sh"

[ ! -e "$test_root/tftp" ]
[ ! -e "$test_root/repos" ]
[ ! -e "$test_root/state/bootstrap-ssh" ]
[ ! -e "$test_root/provisioned" ]
[ -f "$test_root/assets/boot/efi/grubaa64.efi" ]
[ -f "$test_root/assets/repos/rocky-9.7-aarch64-iso/repomd.xml" ]
[ -f "$test_root/assets/keys/id_ed25519" ]
[ -f "$test_root/assets/iso/legacy.iso" ]
[ -f "$test_root/state/provisioned/node-01" ] || [ -d "$test_root/state/provisioned/node-01" ]
[ "$(jq -r '.http.asset_root' "$test_root/config/config.json")" = "$test_root/assets/iso" ]
[ "$(jq -r '.http.repository_root' "$test_root/config/config.json")" = "$test_root/assets/repos" ]
[ "$(jq -r '.tftp.asset_root' "$test_root/config/config.json")" = "$test_root/assets/boot" ]
[ "$(jq -r '.assets[0].path' "$test_root/catalog/catalog.json")" = "rocky.iso" ]
[ "$(jq -r '.assets[1].path' "$test_root/catalog/catalog.json")" = "legacy.iso" ]
[ "$(jq -r '.assets[2].path' "$test_root/catalog/catalog.json")" = "install/rocky/vmlinuz" ]
grep -Fq "WorkingDirectory=$test_root" "$test_root/systemd/nodeforged.service"

sh "$tmp/repo/packaging/install-layout.sh"
