#!/bin/sh
set -eu

remote=${NODEFORGE_MATRIX_REMOTE:-root@r97n0}
node=${NODEFORGE_MATRIX_NODE:-r97n1}
vmx=${NODEFORGE_MATRIX_VMX:-/Users/iskylite/Virtual Machines.localized/r97n1.vmwarevm/r97n1.vmx}
vmrun=${NODEFORGE_MATRIX_VMRUN:-/Applications/VMware Fusion.app/Contents/Public/vmrun}
profiles=${NODEFORGE_MATRIX_PROFILES:-rocky-9.7-aarch64-iso ubuntu-22.04.5-aarch64-iso}
modes=${NODEFORGE_MATRIX_MODES:-single lvm raid0 raid1 raid5 raid6 raid10 raid0-lvm raid1-lvm raid5-lvm raid6-lvm raid10-lvm}
timeout=${NODEFORGE_MATRIX_TIMEOUT:-1200}
poll=${NODEFORGE_MATRIX_POLL:-10}
evidence=${NODEFORGE_MATRIX_EVIDENCE:-/tmp/nodeforge-v0.1-pxe-matrix.jsonl}
cli=/opt/nodeforge/bin/nodeforge

members_for_mode() {
    case "$1" in
        single|lvm) printf '%s\n' 1 ;;
        raid0|raid1|raid0-lvm|raid1-lvm) printf '%s\n' 2 ;;
        raid5|raid5-lvm) printf '%s\n' 3 ;;
        raid6|raid10|raid6-lvm|raid10-lvm) printf '%s\n' 4 ;;
        *) return 1 ;;
    esac
}

remote_cli() {
    ssh -o BatchMode=yes "$remote" "$cli $*"
}

power_off() {
    "$vmrun" -T fusion writeVariable "$vmx" runtimeConfig bios.bootOrder ethernet0 >/dev/null 2>&1 || true
    "$vmrun" -T fusion writeVariable "$vmx" runtimeConfig efi.bootOrder ethernet0 >/dev/null 2>&1 || true
    "$vmrun" -T fusion stop "$vmx" hard >/dev/null 2>&1 || true
}

trap power_off EXIT HUP INT TERM
: >"$evidence"

for profile in $profiles; do
    for mode in $modes; do
        count=$(members_for_mode "$mode")
        power_off
        remote_cli node set "$node" "profile=$profile" "storage.boot_disk=/dev/nvme0n1" -o json >/dev/null
        case "$count" in
            1) remote_cli node clear-values "$node" storage.additional_disks --set "overrides.install.storage.mode=$mode" -o json >/dev/null ;;
            2) remote_cli node replace-values "$node" storage.additional_disks /dev/sda --set "overrides.install.storage.mode=$mode" -o json >/dev/null ;;
            3) remote_cli node replace-values "$node" storage.additional_disks /dev/sda /dev/sdb --set "overrides.install.storage.mode=$mode" -o json >/dev/null ;;
            4) remote_cli node replace-values "$node" storage.additional_disks /dev/sda /dev/sdb /dev/sdc --set "overrides.install.storage.mode=$mode" -o json >/dev/null ;;
        esac
        remote_cli node retry "$node" --force -o json >/dev/null
        armed=$(remote_cli node show "$node" -o json)
        generation=$(printf '%s\n' "$armed" | jq -r .result.deployment.current_generation)
        digest=$(printf '%s\n' "$armed" | jq -r .result.deployment.desired_plan_digest)
        started=$(date +%s)
        printf 'START profile=%s mode=%s generation=%s digest=%s\n' "$profile" "$mode" "$generation" "$digest"
        "$vmrun" -T fusion start "$vmx" nogui >/dev/null
        while :; do
            state=$(remote_cli node show "$node" -o json)
            terminal=$(printf '%s\n' "$state" | jq -r .result.deployment.terminal_generation)
            successful=$(printf '%s\n' "$state" | jq -r .result.deployment.successful_generation)
            if [ "$terminal" = "$generation" ]; then
                if [ "$successful" != "$generation" ]; then
                    printf '%s\n' "$state" | jq -c --arg profile "$profile" --arg mode "$mode" '{profile:$profile,mode:$mode,result:"failed",node:.result}' >>"$evidence"
                    printf 'FAIL profile=%s mode=%s generation=%s\n' "$profile" "$mode" "$generation" >&2
                    exit 1
                fi
                printf '%s\n' "$state" | jq -c --arg profile "$profile" --arg mode "$mode" '{profile:$profile,mode:$mode,result:"completed",node:.result}' >>"$evidence"
                printf 'PASS profile=%s mode=%s generation=%s elapsed=%ss\n' "$profile" "$mode" "$generation" "$(($(date +%s) - started))"
                break
            fi
            if [ "$(($(date +%s) - started))" -ge "$timeout" ]; then
                printf '%s\n' "$state" | jq -c --arg profile "$profile" --arg mode "$mode" '{profile:$profile,mode:$mode,result:"timeout",node:.result}' >>"$evidence"
                printf 'TIMEOUT profile=%s mode=%s generation=%s\n' "$profile" "$mode" "$generation" >&2
                exit 1
            fi
            sleep "$poll"
        done
    done
done

power_off
printf 'Evidence: %s\n' "$evidence"
