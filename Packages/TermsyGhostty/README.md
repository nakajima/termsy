# TermsyGhostty

Local Termsy-owned Ghostty integration.

Current contents:

- `TermsyGhosttyKit` compatibility shim that re-exports the local `libghostty` binary target
- `TermsyGhosttyCore` shared runtime/config/surface bridge types used by the app
- local binary target path at `BinaryTarget/libghostty.xcframework`

Current app state:

- iOS and macOS both build against this local package
- the old remote `libghostty-spm` / `GhosttyTerminal` dependency is no longer part of the app build graph
- the committed XCFramework uses stripped binaries, `ReleaseSmall`, and arm64-only Apple platform slices

Possible future responsibilities:

- expand `TermsyGhosttyCore` for more shared terminal bridging
- move more platform-specific bridge code into package targets only when there is clear value

Build the local artifact first with:

```bash
./scripts/ghostty/build.sh
```
