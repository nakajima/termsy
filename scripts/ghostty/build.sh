#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
DEFAULT_SOURCE_DIR="$ROOT_DIR/build/ghostty/upstream"
DEFAULT_ARTIFACTS_DIR="$ROOT_DIR/build/ghostty/artifacts"
DEFAULT_WORK_DIR="$ROOT_DIR/build/ghostty/work"
DEFAULT_OUTPUT_XCFRAMEWORK="$ROOT_DIR/Packages/TermsyGhostty/BinaryTarget/libghostty.xcframework"
CONFIGURED_REF_FILE="$ROOT_DIR/config/ghostty.ref"

SOURCE_DIR="$DEFAULT_SOURCE_DIR"
ARTIFACTS_DIR="$DEFAULT_ARTIFACTS_DIR"
WORK_DIR="$DEFAULT_WORK_DIR"
OUTPUT_XCFRAMEWORK="$DEFAULT_OUTPUT_XCFRAMEWORK"
OUTPUT_ZIP=
PROFILES="macos-embedded,ios-embedded"
GHOSTTY_REF=

usage() {
    cat <<'EOF'
Usage: ./scripts/ghostty/build.sh [options]

Options:
  --source <path>        Use an existing Ghostty checkout.
  --ref <tag-or-commit>  Checkout the given upstream Ghostty ref.
  --profile <csv>        Build profiles. Default: macos-embedded,ios-embedded
  --output <path>        Output xcframework path.
  --zip <path>           Optional output zip path.
  -h, --help             Show help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --source)
            SOURCE_DIR="$2"
            shift 2
            ;;
        --ref)
            GHOSTTY_REF="$2"
            shift 2
            ;;
        --profile)
            PROFILES="$2"
            shift 2
            ;;
        --output)
            OUTPUT_XCFRAMEWORK="$2"
            shift 2
            ;;
        --zip)
            OUTPUT_ZIP="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "[!] unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if ! command -v zig >/dev/null 2>&1; then
    echo "[!] zig not found"
    exit 1
fi

if [ -z "$GHOSTTY_REF" ] && [ -f "$CONFIGURED_REF_FILE" ]; then
    GHOSTTY_REF=$(grep -v '^#' "$CONFIGURED_REF_FILE" | awk 'NF { print $0; exit }')
fi

if [ ! -d "$SOURCE_DIR/.git" ]; then
    echo "[*] ghostty source not found, cloning into $SOURCE_DIR"
    mkdir -p "$(dirname "$SOURCE_DIR")"
    git clone https://github.com/ghostty-org/ghostty "$SOURCE_DIR"
fi

if [ -n "$GHOSTTY_REF" ]; then
    echo "[*] checking out ghostty ref: $GHOSTTY_REF"
    git -C "$SOURCE_DIR" fetch --tags --force origin

    if [ "$SOURCE_DIR" = "$DEFAULT_SOURCE_DIR" ]; then
        git -C "$SOURCE_DIR" reset --hard HEAD
        git -C "$SOURCE_DIR" clean -fd
    elif [ -n "$(git -C "$SOURCE_DIR" status --porcelain)" ]; then
        echo "[!] source checkout has local changes: $SOURCE_DIR"
        echo "[!] refusing to checkout a different ref in a user-provided source directory"
        exit 1
    fi

    git -C "$SOURCE_DIR" checkout "$GHOSTTY_REF"
else
    echo "[!] no pinned ghostty ref configured; using the current state of $SOURCE_DIR"
fi

sync_worktree() {
    local src="$1"
    local dst="$2"
    rm -rf "$dst"
    mkdir -p "$dst"
    rsync -a --delete --exclude .git --exclude zig-out "$src/" "$dst/"
}

profile_platform_group() {
    case "$1" in
        macos-embedded)
            echo "macos"
            ;;
        ios-embedded)
            echo "ios"
            ;;
        *)
            echo ""
            ;;
    esac
}

profile_patch_dirs() {
    case "$1" in
        macos-embedded)
            printf '%s\n' \
                "$ROOT_DIR/patches/ghostty/base" \
                "$ROOT_DIR/patches/ghostty/embedded"
            ;;
        ios-embedded)
            printf '%s\n' \
                "$ROOT_DIR/patches/ghostty/base" \
                "$ROOT_DIR/patches/ghostty/embedded" \
                "$ROOT_DIR/patches/ghostty/ios"
            ;;
    esac
}

profile_extra_args() {
    case "$1" in
        macos-embedded|ios-embedded)
            echo "-Dcustom-shaders=false -Dinspector=false"
            ;;
        *)
            echo ""
            ;;
    esac
}

rm -rf "$ARTIFACTS_DIR"
mkdir -p "$ARTIFACTS_DIR" "$WORK_DIR"

OLD_IFS=$IFS
IFS=','
set -- $PROFILES
IFS=$OLD_IFS

for profile in "$@"; do
    profile=$(echo "$profile" | xargs)
    [ -n "$profile" ] || continue

    platform_group=$(profile_platform_group "$profile")
    if [ -z "$platform_group" ]; then
        echo "[!] unknown profile: $profile"
        exit 1
    fi

    worktree="$WORK_DIR/$profile"
    sync_worktree "$SOURCE_DIR" "$worktree"

    PATCH_DIRS=()
    while IFS= read -r patch_dir; do
        [ -n "$patch_dir" ] || continue
        PATCH_DIRS+=("$patch_dir")
    done < <(profile_patch_dirs "$profile")
    EXTRA_ARGS=$(profile_extra_args "$profile")

    echo "[*] profile: $profile"
    echo "    platform group: $platform_group"
    echo "    patch sets: ${PATCH_DIRS[*]}"
    echo "    extra args: ${EXTRA_ARGS:-<none>}"

    env ZIG_BUILD_EXTRA_ARGS="$EXTRA_ARGS" \
        "$ROOT_DIR/scripts/ghostty/build-platform.sh" \
        "$worktree" \
        "$platform_group" \
        "$ARTIFACTS_DIR" \
        "${PATCH_DIRS[@]}"
done

"$ROOT_DIR/scripts/ghostty/merge-xcframework.sh" "$ARTIFACTS_DIR" "$OUTPUT_XCFRAMEWORK" "$OUTPUT_ZIP"

echo "[*] ghostty source: $SOURCE_DIR"
echo "[*] ghostty ref: ${GHOSTTY_REF:-<current checkout>}"
echo "[*] zig version: $(zig version)"
echo "[*] output xcframework: $OUTPUT_XCFRAMEWORK"
if [ -n "$OUTPUT_ZIP" ]; then
    echo "[*] output zip: $OUTPUT_ZIP"
fi
