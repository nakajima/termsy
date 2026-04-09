# Ghostty Patch Sets

These patch sets are Termsy-owned and are applied by `scripts/ghostty/build.sh`.

## Layout

- `base/` — required embedded build patches shared by all current profiles
- `embedded/` — shipping-oriented trimming patches shared by embedded profiles
- `ios/` — iOS-only rendering/runtime/compliance patches

## Rules

- Keep patches idempotent.
- Prefer unified diffs when upstream context is stable.
- Use scripts only when source churn makes a diff too fragile.
- Keep platform-specific patches isolated from shared ones.
- If a patch exists only to support a build profile, document that in the patch or commit message.

## Current profile composition

- `macos-embedded` = `base` + `embedded`
- `ios-embedded` = `base` + `embedded` + `ios`
