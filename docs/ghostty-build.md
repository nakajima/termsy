# Ghostty Build Workflow

This repo owns the embedded `libghostty` build pipeline.

## Profiles

- `macos-embedded`
- `ios-embedded`

Both profiles build an embedded, host-managed `libghostty` intended for Termsy.

## Prerequisites

- `zig`
- `git`
- `xcodebuild`
- `python3`
- Metal Toolchain installed for Xcode

If `xcrun metal` fails with a missing toolchain error, install it with:

```bash
xcodebuild -downloadComponent MetalToolchain
```

## Basic usage

Build both shipping profiles:

```bash
./scripts/ghostty/build.sh
```

Build only macOS:

```bash
./scripts/ghostty/build.sh --profile macos-embedded
```

Build only iOS:

```bash
./scripts/ghostty/build.sh --profile ios-embedded
```

By default `build.sh` uses the pinned ref in `config/ghostty.ref`.

Build from a different upstream ref:

```bash
./scripts/ghostty/build.sh --ref <tag-or-commit>
```

Build from a local Ghostty checkout:

```bash
./scripts/ghostty/build.sh --source /path/to/ghostty --profile macos-embedded
```

## Output

By default the merged XCFramework is written to:

- `Packages/TermsyGhostty/BinaryTarget/libghostty.xcframework`

Intermediate build state is written under:

- `build/ghostty/`

## Patch layering

Profiles are composed from patch directories:

- `patches/ghostty/base`
- `patches/ghostty/embedded`
- `patches/ghostty/ios`

Current intent:

- `macos-embedded` = `base` + `embedded`
- `ios-embedded` = `base` + `embedded` + `ios`

## Notes

- Builds run from per-profile working copies so iOS-only patches do not contaminate macOS builds.
- The generated artifact is arm64-only on Apple platforms; x86_64 simulator and macOS builds are intentionally not supported.
- Release builds default to `ReleaseSmall` to keep the committed artifact smaller.
- Staged static libraries are stripped before the XCFramework is assembled.
- The current pinned upstream Ghostty baseline lives in `config/ghostty.ref` and can be overridden with `--ref`.
- The generated XCFramework is consumed by the local `Packages/TermsyGhostty` package, which is now the only Ghostty integration used by the app targets.
