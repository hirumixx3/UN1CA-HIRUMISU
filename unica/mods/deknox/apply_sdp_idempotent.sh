#!/usr/bin/env bash

apply_knox_sdp_idempotent() {
    if [ "${UN1CA_KNOX_SDP_DONE:-0}" = "1" ]; then
        echo '    - Nuke Knox SDP already handled; skipping duplicate call'
        return 0
    fi

    UN1CA_KNOX_SDP_DONE=1

    local script_dir
    local repo_root
    local patch_file
    local framework_dir
    local target_smali
    local target_codename

    script_dir="$(
        cd "$(dirname "${BASH_SOURCE[0]}")" &&
        pwd
    )" || return 1

    repo_root="$(
        cd "$script_dir/../../.." &&
        pwd
    )" || return 1

    target_codename="${TARGET_CODENAME:-a05s}"

    patch_file="$script_dir/sdp/framework.jar/0001-Nuke-Knox-SDP.patch"

    framework_dir="$repo_root/out/target/$target_codename/apktool/system/framework/framework.jar"

    if [ ! -f "$patch_file" ]; then
        echo "ERRO: patch SDP não encontrado:"
        echo "$patch_file"
        return 1
    fi

    if [ ! -d "$framework_dir" ]; then
        echo "ERRO: framework.jar decompilado não encontrado:"
        echo "$framework_dir"
        return 1
    fi

    target_smali="$(
        find "$framework_dir" \
            -type f \
            -path '*/com/android/internal/widget/LockPatternUtils.smali' \
            -print -quit
    )"

    if [ -z "$target_smali" ] || [ ! -f "$target_smali" ]; then
        echo "ERRO: LockPatternUtils.smali não encontrado em:"
        echo "$framework_dir"
        return 1
    fi

    rm -f \
        "$target_smali.rej" \
        "$target_smali.orig"

    if LC_ALL=C patch \
        --dry-run \
        --forward \
        --batch \
        -N \
        -p1 \
        -d "$framework_dir" \
        -l \
        < "$patch_file" \
        >/dev/null 2>&1
    then
        echo '    - Applying "Nuke Knox SDP" to /system/system/framework/framework.jar'

        LC_ALL=C patch \
            --forward \
            --batch \
            -N \
            -p1 \
            -d "$framework_dir" \
            -l \
            < "$patch_file" || return 1

        echo '    - Nuke Knox SDP applied and validated'

    elif LC_ALL=C patch \
        --dry-run \
        --reverse \
        --batch \
        -p1 \
        -d "$framework_dir" \
        -l \
        < "$patch_file" \
        >/dev/null 2>&1
    then
        echo '    - Nuke Knox SDP already applied; full reverse validation passed'

    else
        echo "ERRO: estado parcial ou incompatível no patch Nuke Knox SDP"

        echo
        echo "=== Forward dry-run ==="

        LC_ALL=C patch \
            --dry-run \
            --forward \
            --batch \
            -N \
            -p1 \
            -d "$framework_dir" \
            -l \
            < "$patch_file" || true

        echo
        echo "=== Reverse dry-run ==="

        LC_ALL=C patch \
            --dry-run \
            --reverse \
            --batch \
            -p1 \
            -d "$framework_dir" \
            -l \
            < "$patch_file" || true

        return 1
    fi

    rm -f \
        "$target_smali.rej" \
        "$target_smali.orig"

    return 0
}

apply_knox_sdp_idempotent
status=$?
unset -f apply_knox_sdp_idempotent

return "$status" 2>/dev/null || exit "$status"
