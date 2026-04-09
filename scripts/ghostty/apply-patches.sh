#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
SOURCE_DIR=${1:-}
shift || true

usage() {
    cat <<'EOF'
Usage: ./scripts/ghostty/apply-patches.sh <ghostty-source-dir> <patch-dir> [patch-dir ...]
EOF
}

if [ -z "$SOURCE_DIR" ] || [ "$#" -eq 0 ]; then
    usage
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[!] ghostty source directory not found: $SOURCE_DIR"
    exit 1
fi

apply_unified_patch() {
    local patch_file="$1"

    if [ -d "$SOURCE_DIR/.git" ] && command -v git >/dev/null 2>&1; then
        if git -C "$SOURCE_DIR" apply --check "$patch_file" >/dev/null 2>&1; then
            git -C "$SOURCE_DIR" apply "$patch_file"
            echo "[+] applied patch: $(basename "$patch_file")"
            return
        fi

        if git -C "$SOURCE_DIR" apply --check --reverse "$patch_file" >/dev/null 2>&1; then
            echo "[+] patch already applied: $(basename "$patch_file")"
            return
        fi

        echo "[!] failed to validate patch: $patch_file"
        exit 1
    fi

    if patch -p1 --dry-run -d "$SOURCE_DIR" <"$patch_file" >/dev/null 2>&1; then
        patch -p1 -d "$SOURCE_DIR" <"$patch_file" >/dev/null
        echo "[+] applied patch: $(basename "$patch_file")"
        return
    fi

    if patch -p1 -R --dry-run -d "$SOURCE_DIR" <"$patch_file" >/dev/null 2>&1; then
        echo "[+] patch already applied: $(basename "$patch_file")"
        return
    fi

    echo "[!] failed to validate patch: $patch_file"
    exit 1
}

for patch_dir in "$@"; do
    if [ ! -d "$patch_dir" ]; then
        echo "[!] patch directory not found: $patch_dir"
        exit 1
    fi

    echo "[*] applying patch set: ${patch_dir#$ROOT_DIR/}"

    while IFS= read -r patch_file; do
        case "$patch_file" in
            *.md)
                ;;
            *.patch)
                apply_unified_patch "$patch_file"
                ;;
            *.sh)
                "$patch_file" "$SOURCE_DIR"
                ;;
            *)
                echo "[!] unsupported patch file: $patch_file"
                exit 1
                ;;
        esac
    done < <(find "$patch_dir" -maxdepth 1 -mindepth 1 -type f | sort)
done
