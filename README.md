# termsy

Plain ol' terminal app.

## features

- Full libghostty terminal on ios.
- Minimal theme picker (hope u like catpuccin)
- Font picker
- Tabs

## non-goals

- No auth. Assume Tailscale SSH.
- No AI (in the app, assume I am going to use hella-ai to write this thing)
- No local shell.

## docs

- [`docs/option-3-seamless-tab-return.md`](docs/option-3-seamless-tab-return.md) — investigation and recommended architecture for seamless tab return / app resume behavior
- [`docs/vt-custom-renderer-architecture.md`](docs/vt-custom-renderer-architecture.md) — concrete public-`libghostty-vt` architecture for VT-backed sessions with a custom renderer
