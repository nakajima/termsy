# Termsy Ghostty Ownership Plan

## Status

This migration is now complete at the app dependency level.

Completed:

- Termsy owns the `libghostty` build pipeline under `scripts/ghostty/` and `patches/ghostty/`
- the app consumes the locally built XCFramework through `Packages/TermsyGhostty`
- both iOS and macOS app targets build against local `TermsyGhosttyKit` / `TermsyGhosttyCore`
- the old remote `libghostty-spm` / `GhosttyTerminal` dependency is no longer part of the app build graph

This document is kept as the design record for that migration and as a reference for future local-package work.

## Goals

1. Replace the old remote Ghostty integration with Termsy-owned infrastructure.
2. Own a clean, repeatable `libghostty` build pipeline.
3. Keep shipping builds slim and platform-appropriate.
4. Preserve iOS stripping and App Store compliance patches.
5. Make future Ghostty-source customization practical instead of incidental.

## Non-Goals

- Rebuilding all of Ghostty's app-layer abstractions inside Termsy.
- Shipping a thick replacement for the old wrapper stack.
- Enabling every upstream Ghostty feature by default.
- Coupling normal Xcode app builds to a Zig toolchain requirement.

## Principles

- **Thin bridge, not framework**: Termsy owns tabs, windows, SSH, local shell, and product behavior. The local package owns only `libghostty` bridging.
- **Official Ghostty is the behavioral reference** for platform input behavior, especially AppKit keyboard handling.
- **Build profiles are explicit**: shipping builds should be intentionally trimmed, not incidentally constrained.
- **Profile isolation matters**: platform-specific patches must not leak between builds.
- **Artifact ownership matters**: no hidden dependence on third-party prebuilt binaries.

## Deliverables

### A. Local build pipeline

Repo-owned tooling under `scripts/ghostty/` and `patches/ghostty/` that can:

- clone or reuse an upstream Ghostty checkout
- pin or override the Ghostty ref
- build `libghostty` for macOS or iOS
- apply Termsy-owned patch sets deterministically
- emit a local XCFramework for app/package consumption
- record build inputs clearly enough to debug and reproduce failures

### B. Local package

A local package under `Packages/TermsyGhostty/` that currently provides or may later provide:

- `TermsyGhosttyKit` compatibility shim around `libghostty`
- `TermsyGhosttyCore` for runtime/config/surface/session bridging
- `TermsyGhosttyAppKit` for macOS rendering and input
- `TermsyGhosttyUIKit` later if/when the iOS path is consolidated

Note: the shim uses a unique name (`TermsyGhosttyKit`) and remains the package boundary used by the app today.

### C. macOS wrapper replacement

Replace the old wrapper-based macOS path with a Termsy-owned AppKit bridge that:

- uses host-managed I/O
- handles focus, sizing, rendering, clipboard, IME, mouse, and keyboard
- matches official Ghostty behavior for modifier-only and translated input

## Build Profiles

### `macos-embedded`

Purpose:

- Termsy macOS shipping/development build
- host-managed I/O
- app-owned window/runtime behavior
- trimmed feature set suitable for embedded terminal use

Expected shape:

- `app-runtime=none`
- no standalone executable
- no docs emission
- no Sentry
- custom shaders disabled
- inspector disabled
- host-managed I/O patch set applied

### `ios-embedded`

Purpose:

- Termsy iOS shipping/development build
- same embedded model as macOS where applicable
- preserves iOS-specific fixes and App Store compliance work

Expected shape:

- everything from `macos-embedded` that still applies
- iOS rendering/runtime patches
- iOS App Store compliance patches
- iOS deployment/runtime compatibility fixes

### Future optional profiles

Potential later profiles, not required for the first migration:

- `macos-experimental`
- `macos-featureful`
- `shared-debug`

These should exist only when there is a concrete feature or debugging need.

## Patch Strategy

Patch sets are layered rather than monolithic.

### `patches/ghostty/base`

Applies to all embedded builds.

Includes:

- Darwin `libghostty` build/install wiring
- host-managed I/O support
- framedata/build-pipeline fixes needed for embedded consumption

### `patches/ghostty/embedded`

Applies to shipping embedded builds.

Includes:

- feature-stripping patches for custom shaders
- feature-stripping patches for inspector
- any other patches that exist purely to keep the embedded build lean

### `patches/ghostty/ios`

Applies only to iOS builds.

Includes:

- iOS rendering fixes
- iOS runtime fixes
- iOS/App Store compliance work that must remain enabled for shipping builds

## Build Pipeline Shape

### Source handling

- Maintain an upstream Ghostty checkout outside app sources but inside repo-controlled build state.
- Support `--source <path>` for local hacking.
- Support `--ref <tag-or-commit>` and later a checked-in default ref.
- Build from a per-profile working copy so patch application stays isolated.

### Artifact handling

- Emit a local XCFramework at a stable path owned by Termsy.
- Keep generated artifacts outside the normal source set or clearly marked as generated.
- Make it easy for the future local package to consume the artifact without remote downloads.

### Repeatability requirements

Each build should make it obvious:

- which Ghostty ref was used
- which patch directories were applied
- which Zig version was used
- which profile was built
- where the resulting XCFramework was written

## Migration Phases

### Phase 0 — Build ownership

- Add repo-owned build scripts.
- Copy/adapt the current patch set into Termsy.
- Create `macos-embedded` and `ios-embedded` profiles.
- Prove we can build a local XCFramework ourselves.

### Phase 1 — Package boundary ownership

Status: completed.

- Add `Packages/TermsyGhostty`.
- Introduce a `TermsyGhosttyKit` compatibility shim around the local artifact.
- Move app targets to the local package boundary.

### Phase 2 — Thin core bridge

Implement only the shared pieces Termsy actually needs:

- runtime/app lifecycle
- config loading/updating
- host-managed session
- surface wrapper
- callback bridge
- metrics/debug logging

### Phase 3 — macOS AppKit bridge

Status: completed for the current app architecture.

Replace the old macOS wrapper path with a Termsy-owned AppKit integration.

Primary targets:

- `Termsy/GhosttyApp.swift` AppKit branch
- `Termsy/Views/TerminalView+AppKit.swift`
- `TermsyMac/MacTerminalTab.swift`
- `TermsyMac/MacRootView.swift`
- `TermsyMac/MacTerminalWindowController.swift`

### Phase 4 — Optional iOS/package consolidation

After macOS is stable, decide whether to:

- leave the current iOS path largely intact but package-owned, or
- move the iOS terminal bridge into `TermsyGhosttyUIKit`

## Capability Tracking

Owning the build should make previously awkward or impossible work more tractable, but only intentionally.

We should track, explicitly, which capabilities are:

- available upstream
- enabled in shipping profiles
- disabled by trimming
- blocked by wrapper work still to do
- product non-goals

A follow-up doc should capture that matrix so build ownership becomes leverage instead of drift.

## Initial Acceptance Criteria

We can call the first milestone successful when:

1. Termsy can build `libghostty` locally for macOS.
2. Termsy can build `libghostty` locally for iOS while preserving the existing trimming/compliance behavior.
3. The build process does not depend on old remote Ghostty artifacts.
4. The repo contains the patch sets and scripts needed to reproduce the artifact.
5. We have a clear path to swap the Swift wrapper layer next.

## Possible Next Steps

1. Keep the pinned upstream Ghostty ref and patch sets current.
2. Expand `TermsyGhosttyCore` only where shared functionality genuinely reduces duplication.
3. Consider package-owned AppKit/UIKit bridge targets later only if they provide clear maintenance value.
4. Continue treating official Ghostty behavior as the reference when input or embedding behavior diverges.
