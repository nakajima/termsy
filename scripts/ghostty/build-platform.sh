#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
SOURCE_DIR=${1:-}
PLATFORM_GROUP=${2:-}
OUTPUT_DIR=${3:-}
shift 3 || true
PATCH_DIRS=("$@")

usage() {
    cat <<'EOF'
Usage: ./scripts/ghostty/build-platform.sh <source_dir> <platform_group> <output_dir> [patch_dir ...]

Supported platform groups:
  macos
  ios
EOF
}

if [ -z "$SOURCE_DIR" ] || [ -z "$PLATFORM_GROUP" ] || [ -z "$OUTPUT_DIR" ]; then
    usage
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[!] ghostty source directory not found: $SOURCE_DIR"
    exit 1
fi

build_variant() {
    local variant_name="$1"
    shift

    local variant_dir="$OUTPUT_DIR/$variant_name"
    local intermediate_dir="$OUTPUT_DIR/.intermediates/$variant_name"
    local first_headers=
    local libraries=()
    local target_spec=
    local target=
    local cpu=

    rm -rf "$variant_dir" "$intermediate_dir"
    mkdir -p "$variant_dir/lib" "$variant_dir/include" "$intermediate_dir"

    for target_spec in "$@"; do
        target=${target_spec%%@*}
        cpu=
        if [ "$target_spec" != "$target" ]; then
            cpu=${target_spec#*@}
        fi

        local target_dir="$intermediate_dir/$target"
        local source_copy="$intermediate_dir/${target}-source"
        rm -rf "$source_copy"
        mkdir -p "$source_copy"
        rsync -a --delete --exclude .git --exclude zig-out "$SOURCE_DIR/" "$source_copy/"
        if [ -n "$cpu" ]; then
            env ZIG_CPU="$cpu" "$ROOT_DIR/scripts/ghostty/build-ghostty.sh" "$source_copy" "$target" "$target_dir" "${PATCH_DIRS[@]}"
        else
            "$ROOT_DIR/scripts/ghostty/build-ghostty.sh" "$source_copy" "$target" "$target_dir" "${PATCH_DIRS[@]}"
        fi
        libraries+=("$target_dir/lib/libghostty.a")
        if [ -z "$first_headers" ]; then
            first_headers="$target_dir/include"
        fi
    done

    if [ -z "$first_headers" ]; then
        echo "[!] no libraries were built for variant: $variant_name"
        exit 1
    fi

    cp -R "$first_headers/." "$variant_dir/include/"

    if [ "${#libraries[@]}" -eq 1 ]; then
        cp "${libraries[0]}" "$variant_dir/lib/libghostty.a"
    else
        lipo -create "${libraries[@]}" -output "$variant_dir/lib/libghostty.a"
    fi

    echo "[*] assembled variant: $variant_name"
}

mkdir -p "$OUTPUT_DIR"

case "$PLATFORM_GROUP" in
    macos)
        build_variant "macosx" \
            "aarch64-macos"
        ;;
    ios)
        build_variant "iphoneos" \
            "aarch64-ios"
        build_variant "iphonesimulator" \
            "aarch64-ios-simulator@apple_a17"
        ;;
    *)
        echo "[!] unknown platform group: $PLATFORM_GROUP"
        exit 1
        ;;
esac

echo "[*] built platform group: $PLATFORM_GROUP"
