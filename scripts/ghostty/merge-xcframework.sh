#!/bin/bash

set -euo pipefail

ARTIFACTS_DIR=${1:-}
OUTPUT_XCFRAMEWORK=${2:-}
OUTPUT_ZIP=${3:-}

usage() {
    cat <<'EOF'
Usage: ./scripts/ghostty/merge-xcframework.sh <artifacts_dir> <output_xcframework> [output_zip]
EOF
}

if [ -z "$ARTIFACTS_DIR" ] || [ -z "$OUTPUT_XCFRAMEWORK" ]; then
    usage
    exit 1
fi

if [ ! -d "$ARTIFACTS_DIR" ]; then
    echo "[!] artifacts directory not found: $ARTIFACTS_DIR"
    exit 1
fi

XCFRAMEWORK_COMMAND=()
FOUND_VARIANTS=0

strip_library() {
    local library_path="$1"
    xcrun strip -S -x "$library_path"
}

add_library() {
    local variant_dir="$1"
    local library_path="$variant_dir/lib/libghostty.a"
    local header_dir="$variant_dir/include"

    if [ ! -f "$library_path" ]; then
        echo "[!] missing library: $library_path"
        exit 1
    fi

    if [ ! -d "$header_dir" ]; then
        echo "[!] missing headers: $header_dir"
        exit 1
    fi

    strip_library "$library_path"
    XCFRAMEWORK_COMMAND+=("-library" "$library_path" "-headers" "$header_dir")
    FOUND_VARIANTS=$((FOUND_VARIANTS + 1))
}

for variant_dir in "$ARTIFACTS_DIR"/*; do
    [ -d "$variant_dir" ] || continue
    [ "$(basename "$variant_dir")" = ".intermediates" ] && continue
    add_library "$variant_dir"
done

if [ "$FOUND_VARIANTS" -eq 0 ]; then
    echo "[!] no staged variants found in $ARTIFACTS_DIR"
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_XCFRAMEWORK")"
rm -rf "$OUTPUT_XCFRAMEWORK"

echo "[*] creating xcframework: $OUTPUT_XCFRAMEWORK"
xcodebuild -create-xcframework \
    -output "$OUTPUT_XCFRAMEWORK" \
    "${XCFRAMEWORK_COMMAND[@]}"

if [ -n "$OUTPUT_ZIP" ]; then
    mkdir -p "$(dirname "$OUTPUT_ZIP")"
    rm -f "$OUTPUT_ZIP"
    (
        cd "$(dirname "$OUTPUT_XCFRAMEWORK")"
        ditto -c -k --sequesterRsrc --keepParent "$(basename "$OUTPUT_XCFRAMEWORK")" "$(basename "$OUTPUT_ZIP")"
    )
    mv "$(dirname "$OUTPUT_XCFRAMEWORK")/$(basename "$OUTPUT_ZIP")" "$OUTPUT_ZIP"
    echo "[*] packed xcframework zip: $OUTPUT_ZIP"
fi
