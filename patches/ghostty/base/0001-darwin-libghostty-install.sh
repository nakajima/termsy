#!/bin/zsh

set -euo pipefail

SOURCE_DIR=${1:-}

if [ -z "$SOURCE_DIR" ]; then
    echo "[-] missing source_dir"
    exit 1
fi

BUILD_ZIG="$SOURCE_DIR/build.zig"
MARKER="libghostty static install for Darwin"

if [ ! -f "$BUILD_ZIG" ]; then
    echo "[-] build.zig not found: $BUILD_ZIG"
    exit 1
fi

if grep -Fq "$MARKER" "$BUILD_ZIG"; then
    echo "[+] patch already applied: 0001-darwin-libghostty-install"
    exit 0
fi

python3 - "$BUILD_ZIG" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = '''        // We shouldn't have this guard but we don't currently
        // build on macOS this way ironically so we need to fix that.
        if (!config.target.result.os.tag.isDarwin()) {
            lib_shared.installHeader(); // Only need one header
            if (config.target.result.os.tag == .windows) {
                lib_shared.install("ghostty.dll");
                lib_static.install("ghostty-static.lib");
            } else {
                lib_shared.install("libghostty.so");
                lib_static.install("libghostty.a");
            }
        }
'''
new = '''        // libghostty static install for Darwin:
        // upstream only wires this for non-Darwin today, but we need the
        // static archive for our own XCFramework assembly pipeline.
        lib_shared.installHeader(); // Only need one header
        if (config.target.result.os.tag == .windows) {
            lib_shared.install("ghostty.dll");
            lib_static.install("ghostty-static.lib");
        } else {
            if (!config.target.result.os.tag.isDarwin()) {
                lib_shared.install("libghostty.so");
            }
            lib_static.install("libghostty.a");
        }
'''
if old not in text:
    raise SystemExit('[-] failed to locate Darwin install block in build.zig')
path.write_text(text.replace(old, new, 1))
PY

if ! grep -Fq "$MARKER" "$BUILD_ZIG"; then
    echo "[-] failed to apply patch: 0001-darwin-libghostty-install"
    exit 1
fi

echo "[+] applied patch: 0001-darwin-libghostty-install"
