# Termsy Architecture: VT Sessions + Custom Renderer

_Last updated: 2026-04-05_

## Executive summary

This document describes a **concrete Termsy architecture** built on the **public `libghostty-vt` API only**, with **no wrapper or Ghostty core changes** assumed.

It answers the question:

> If Termsy models each tab as a headless Ghostty VT terminal instead of a `ghostty_surface_t`, what should the app architecture look like end-to-end?

## Recommendation

Under the public-API-only constraint, the recommended VT architecture is:

1. **Each tab owns a headless `GhosttyTerminal`** as the source of truth.
2. **Incoming SSH output always feeds that terminal**, whether or not the tab is visible.
3. **The visible UI renders from `GhosttyRenderState`**, not from `ghostty_surface_t`.
4. **Hardware key, mouse, focus, and paste input are encoded using the public VT encoders/utilities** and sent to SSH.
5. **Terminal effects** such as query replies, title changes, size reports, bell, XTVERSION, and device attributes are handled through the public terminal callback API.
6. **Tab switching becomes trivial**: hidden tabs keep advancing state without any view attached.
7. **App background/foreground is still bounded by iOS suspension**: if the process is suspended or the transport dies, continuity falls back to reconnect + remote persistence (`tmux`).

## Main consequence

This is the cleanest public-API VT design available today, but it also means:

- Termsy **does not reuse the current Ghostty surface renderer/UI stack**
- Termsy must build its own renderer on top of:
  - `GhosttyTerminal`
  - `GhosttyRenderState`
  - `GhosttyFormatter`

---

## Design goals

A VT-based Termsy should provide:

- headless per-tab terminal state
- no raw transcript replay on tab restore
- hidden tabs that continue advancing while the app is alive
- selected-tab rendering that is independent from session ownership
- public-API-only compatibility
- a clear iOS lifecycle story

## Non-goals

This design does **not** assume:

- `ghostty_surface_t`
- private Ghostty renderer APIs
- new wrapper features
- Ghostty core modifications

This design also does not promise instant parity with every visual feature in the surface renderer. The first-class goal is correct terminal state ownership and correct attach/detach semantics.

---

## Public `libghostty-vt` capabilities this architecture uses

### Terminal state

- `ghostty_terminal_new(...)`
- `ghostty_terminal_vt_write(...)`
- `ghostty_terminal_resize(...)`
- `ghostty_terminal_mode_get(...)`
- `ghostty_terminal_get(...)`
- `ghostty_terminal_set(...)`
- `ghostty_terminal_scroll_viewport(...)`

### Rendering data

- `ghostty_render_state_new(...)`
- `ghostty_render_state_update(...)`
- row iterator / row-cells iterator
- dirty tracking
- colors
- cursor data

### Formatting/export

- `ghostty_formatter_terminal_new(...)`
- `ghostty_formatter_format_alloc(...)`

### Input encoding

- `ghostty_key_encoder_setopt_from_terminal(...)`
- `ghostty_key_encoder_encode(...)`
- `ghostty_mouse_encoder_setopt_from_terminal(...)`
- `ghostty_mouse_encoder_encode(...)`
- `ghostty_focus_encode(...)`
- `ghostty_paste_encode(...)`

### Terminal effects

Via `ghostty_terminal_set(...)` and effect callbacks:

- write-pty callback
- bell callback
- title-changed callback
- enquiry callback
- xtversion callback
- size callback
- color-scheme callback
- device-attributes callback

---

## High-level architecture

```text
SSHConnection
    ↓ remote bytes
VTTerminalCore (per tab)
    owns GhosttyTerminal + GhosttyRenderState + encoders + effect bridge
    ↓ frame snapshots
VTTerminalView (selected or visible tabs only)
    draws snapshot using Termsy renderer
    ↑ input events
VTInputBridge
    encodes input from current terminal state
    ↓ encoded bytes
SSHConnection.send(...)
```

The key inversion compared with the current app is:

- today: the visible terminal view owns the emulator state
- in this design: the **headless VT terminal owns the emulator state** and the view becomes a renderer/client

---

## Concrete component model

## 1. `VTTerminalCore`

### Responsibility

Owns the real terminal session state for one tab.

### Suggested file

- `Termsy/VT/VTTerminalCore.swift`

### Owns

- `GhosttyTerminal`
- `GhosttyRenderState`
- `GhosttyFormatter` instances or lazy formatter creation
- key encoder
- mouse encoder
- effect bridge state
- theme defaults/palette pushed into the terminal
- current terminal size in cells/pixels
- last known title / pwd / bell state
- a lightweight “needs frame” dirty marker for the UI

### Suggested concurrency model

Make it an `actor`.

Why:

- `ghostty_terminal_vt_write(...)` mutates terminal state
- `ghostty_render_state_update(...)` must read terminal state under exclusive access
- effect callbacks are synchronous during VT writes
- one actor serializes all terminal access naturally

### Core API surface

Suggested methods:

- `feedRemoteOutput(_ data: Data)`
- `resize(viewport: VTViewportMetrics)`
- `makeFrameSnapshot() -> VTFrameSnapshot`
- `encodeHardwareKey(...) -> Data?`
- `encodeMouseEvent(...) -> Data?`
- `encodeFocusChange(...) -> Data?`
- `encodePaste(...) -> Data?`
- `scrollViewport(delta:)`
- `historyPlain() -> String`
- `historyVT() -> Data`

### Core invariants

- every SSH byte first lands in `VTTerminalCore`
- the visible view never directly mutates terminal state on its own
- the renderer only ever consumes copied snapshot data, not borrowed C pointers

---

## 2. `VTTerminalEffectBridge`

### Responsibility

Connect Ghostty VT effect callbacks back into Swift-owned tab/session state.

### Suggested files

- `Termsy/VT/VTTerminalBridge.h`
- `Termsy/VT/VTTerminalBridge.c`
- `Termsy/VT/VTTerminalCore.swift`

### Why a small C bridge is needed

The public API is C-based and effect callbacks are synchronous. Swift should not do heavy work directly inside those callbacks.

### Correct design

During `ghostty_terminal_vt_write(...)`, callbacks should only:

- append pty-response bytes into a temporary buffer
- record that title changed / bell rang / size was queried
- store small plain data needed after the write returns

Then, **after** `ghostty_terminal_vt_write(...)` finishes, `VTTerminalCore` drains those pending effects and performs the real work:

- send query-reply bytes over SSH
- update tab title
- notify UI of bell/title changes

### Why this matters

The public docs explicitly say callbacks:

- are synchronous
- must not reenter `ghostty_terminal_vt_write()`
- should avoid blocking

So the bridge must be intentionally small and non-blocking.

---

## 3. `VTFrameSnapshot`

### Responsibility

A pure Swift value type copied out of `GhosttyRenderState`, safe to hand to UIKit/Core Animation.

### Suggested file

- `Termsy/VT/VTFrameSnapshot.swift`

### Why it exists

Render-state row/cell data is borrowed and only valid while the render state remains stable. UIKit drawing should not hold raw pointers into Ghostty C structures.

### Suggested structure

```text
VTFrameSnapshot
  size: cols/rows/pixel size/cell size
  palette + default fg/bg/cursor colors
  rows: [VTRowSnapshot]
  cursor: VTCursorSnapshot?
  dirtyState: full/partial/clean
  dirtyRows: IndexSet
```

```text
VTRowSnapshot
  index
  cells: [VTCellSnapshot]
  isDirty
```

```text
VTCellSnapshot
  grapheme: String
  fgColor
  bgColor
  style flags: bold, underline, inverse, etc.
  width: 1 or 2 cells
  isWideTail
```

### Snapshot strategy

`VTTerminalCore.makeFrameSnapshot()` should:

1. call `ghostty_render_state_update(...)`
2. read global dirty state
3. iterate rows and cells
4. copy only Swift-safe values into snapshot structs
5. clear dirty flags after the UI accepts the frame

This gives Termsy a clean boundary between C terminal state and UIKit drawing.

---

## 4. `VTTerminalView`

### Responsibility

Render the selected tab’s `VTFrameSnapshot`.

### Suggested file

- `Termsy/Views/VTTerminalView.swift`

### Ownership rule

The view does **not** own session state.

It only owns:

- font metrics
- row/cell layout cache
- current displayed snapshot
- local selection/highlight state
- touch/hover recognizers

### Recommended rendering model

Use a row-oriented renderer because the public API exposes row dirty tracking.

Recommended structure:

- `VTTerminalView`
  - manages size/theme/input
  - owns N row layers or row render objects
- `VTTerminalRowLayer`
  - draws one row from `VTRowSnapshot`
  - only repaints when the row is dirty or global dirty requires full redraw

### Why row-oriented rendering fits

Ghostty VT render state already tells you:

- whether the frame is fully dirty or partially dirty
- which rows are dirty

A row-based renderer maps directly onto that model.

### Initial renderer recommendation

For the first implementation:

- render text/cursor/backgrounds correctly
- support colors, bold, underline, inverse, wide cells
- support scrollback viewport rendering
- defer advanced parity work like full image support or inspector-grade fidelity

This keeps the first renderer honest and shippable.

---

## 5. `VTInputBridge`

### Responsibility

Convert UIKit/AppKit-style user input into terminal bytes using the public Ghostty VT encoders.

### Suggested file

- `Termsy/Input/VTInputBridge.swift`

### Hardware keyboard

Pipeline:

1. receive `UIKey` / `UIPress`
2. translate to a Ghostty key event struct
3. before encoding, sync the encoder from terminal state:
   - `ghostty_key_encoder_setopt_from_terminal(...)`
4. encode
5. send resulting bytes to SSH

### Why sync-from-terminal matters

The terminal state affects encoding for things like:

- Kitty keyboard protocol flags
- application cursor keys
- keypad modes
- other keyboard-mode toggles

So encoder configuration must come from the current terminal state, not hardcoded assumptions.

### Software keyboard

Recommended split:

- printable committed text from `insertText(_:)` -> send UTF-8 directly
- delete, return, escape, arrows, function-style keys -> encode through key encoder

This is the most practical UIKit integration.

### Mouse / trackpad

Pipeline:

1. track local pointer/touch position in cell coordinates
2. if mouse tracking is active in terminal state:
   - sync mouse encoder from terminal state
   - encode press/release/move/scroll
   - send bytes to SSH
3. if mouse tracking is not active:
   - use gesture locally for viewport scroll / selection / copy behavior

### Focus

When the selected tab gains or loses focus:

- if focus-reporting mode is active, encode with `ghostty_focus_encode(...)`
- send to SSH

### Paste

Use `ghostty_paste_encode(...)`.

Pipeline:

1. read bracketed-paste mode from terminal mode state
2. copy clipboard text into mutable buffer
3. encode paste
4. send resulting bytes to SSH

### IME / composition

With VT-only architecture, IME UI is Termsy’s responsibility.

Recommended first implementation:

- handle committed text correctly
- keep composition/preedit in UIKit-side input UI only
- render committed text after terminal state advances

If preedit rendering is desired later, it must be added as an app-side overlay concern, not assumed from Ghostty surface behavior.

---

## 6. `TerminalTab` in the VT design

### Responsibility

Owns session identity and ties together:

- `Session`
- `SSHConnection` / `SSHTerminalSession`
- `VTTerminalCore`
- selected/visible lifecycle state
- reconnect state

### Suggested evolution from current code

Today `TerminalTab` owns:

- `Session`
- `SSHTerminalSession`
- connection flags

In the VT design it should also own:

- `VTTerminalCore`
- current title derived from terminal effects
- viewport policy
- last known size metrics

### Lifecycle rule

Closing a tab destroys:

- SSH transport
- VT terminal core
- render state
- any attached visible renderer view

Deselecting a tab destroys:

- **nothing in the session core**
- possibly the visible view only

That is the key win of VT ownership.

---

## Rendering pipeline in detail

## Step 1: configure terminal theme defaults

When the tab/core is created or theme changes:

- push default foreground/background/cursor/palette into the terminal using `ghostty_terminal_set(...)`

This preserves OSC override behavior while giving the app its chosen theme defaults.

## Step 2: compute viewport metrics from the view

`VTTerminalView` owns font and cell metrics.

It computes:

- cell width px
- cell height px
- visible columns
- visible rows
- total view size px

Then it calls `VTTerminalCore.resize(...)`, which forwards to:

- `ghostty_terminal_resize(cols, rows, cellWidth, cellHeight)`

## Step 3: feed remote bytes continuously

Every inbound SSH chunk does:

- `VTTerminalCore.feedRemoteOutput(data)`
- internally calls `ghostty_terminal_vt_write(...)`
- drains any effect outputs
- marks the core as needing a frame update

## Step 4: build a frame snapshot when needed

When the visible tab needs redraw:

- view asks core for a frame snapshot
- core calls `ghostty_render_state_update(...)`
- extracts colors, cursor, rows, cells, dirty flags
- returns `VTFrameSnapshot`

## Step 5: draw snapshot using row dirty tracking

The view:

- if global dirty is full -> redraw all rows
- if partial -> redraw only dirty rows
- if clean -> skip draw

This gives a renderer that matches the public API’s intended usage.

## Step 6: clear dirty state after presenting

After snapshot acceptance/draw:

- clear row/global dirty flags in the render state

This ensures the next update reflects only new changes.

---

## Terminal effects design

This is one of the most important parts of parity with the current surface path.

By default, `ghostty_terminal_vt_write(...)` ignores side-effectful sequences unless the embedder configures effects.

A serious VT Termsy must wire these up.

## Mandatory

### `WRITE_PTY`

Use this to send generated reply bytes back to SSH.

This covers things like:

- query responses
- terminal-generated protocol replies

Without it, many remote apps and shells will silently misbehave.

### `TITLE_CHANGED`

Use this to update the tab title if the remote app sets one.

This gives better UX than always showing only `user@host`.

## Strongly recommended

### `BELL`

Map to haptic, visual flash, or sound policy.

### `SIZE`

Needed for size queries like XTWINOPS. The callback should answer from the current viewport metrics known by the core.

### `XTVERSION`

Expose a stable version string for compatibility with apps that probe it.

### `DEVICE_ATTRIBUTES`

Needed for shells/apps that query terminal capabilities.

### `COLOR_SCHEME`

Allows terminal-side color scheme queries to reflect the app’s current light/dark choice.

### `ENQUIRY`

Useful for old-school ENQ behavior when encountered.

## Effect bridge rule

Callbacks should only stage data. `VTTerminalCore` performs real Swift-side work after the VT write returns.

---

## Selection, copy, history, and previews

## History export

Use `GhosttyFormatter`.

This is ideal for:

- copying visible screen text
- exporting scrollback as plain text
- generating session previews similar to `zmx history`

### Suggested APIs on the core

- `historyPlain()`
- `historyVT()`
- `historyHTML()`

## Selection and copy

Selection is renderer-owned in the VT design.

That means:

- touch/drag selection coordinates are managed by the view
- the view maps selection rectangles back to terminal cells
- copy/export can use formatter selection or grid traversal APIs

Recommended first implementation:

- get selection UI working at the row/cell level
- use plain-text export first
- styled/HTML export later if needed

---

## Tab switching lifecycle

## On tab select

- attach/show `VTTerminalView`
- compute viewport size
- call `VTTerminalCore.resize(...)`
- request frame snapshot
- begin draw loop only for the visible tab
- enable input/focus reporting for that visible tab

## On tab deselect

- detach/hide the view
- stop the display loop
- keep the `VTTerminalCore` alive
- keep consuming SSH output into the headless terminal

This is the central improvement over the current surface-centric design.

No transcript replay is needed.

---

## App inactive/background/foreground lifecycle

## When app becomes inactive or enters background but remains resident

- visible views may be detached or paused
- all `VTTerminalCore` instances remain alive
- SSH output continues feeding headless terminals if the process remains active long enough

## When app returns to foreground

- selected tab reattaches a view
- view resizes core to current metrics
- requests a fresh full frame snapshot
- resumes drawing/input

## When iOS suspends the app or kills transport

This architecture does **not** remove the platform boundary.

If the process is suspended:

- local terminal progression stops
- SSH transport may die

Recovery remains:

- reconnect on foreground
- restore remote continuity via `tmux` if configured

So VT architecture solves **tab attach/detach correctness**, not iOS background execution limits.

---

## Concrete file/layout proposal

A VT Termsy could be organized like this:

```text
Termsy/
  VT/
    VTTerminalCore.swift
    VTTerminalBridge.h
    VTTerminalBridge.c
    VTFrameSnapshot.swift
    VTThemeBridge.swift
    VTFormatterBridge.swift
  Input/
    VTInputBridge.swift
    VTKeyMapping.swift
    VTMouseMapping.swift
  Views/
    VTTerminalView.swift
    VTTerminalRowLayer.swift
    VTSelectionOverlay.swift
  SSH/
    SSHTerminalSession.swift
  Views/
    ViewCoordinator.swift
    ContentView.swift
```

### Suggested ownership map

- `ViewCoordinator` owns tabs
- `TerminalTab` owns `SSHTerminalSession` + `VTTerminalCore`
- `VTTerminalCore` owns all Ghostty VT C handles
- `VTTerminalView` owns only rendering and local input UI

---

## Migration from the current codebase

Even though this document is architecture-focused, the migration boundary is important.

## Replace current source of truth

Today:

- `TerminalView` + `ghostty_surface_t` is the source of truth

Target:

- `VTTerminalCore` is the source of truth

## Keep SSH transport logic, change sink

Today:

- incoming SSH bytes feed `terminalView.feedData(...)` or transcript

Target:

- incoming SSH bytes feed `VTTerminalCore.feedRemoteOutput(...)`

## Replace visible rendering path

Today:

- `TerminalHostController` creates `TerminalView`

Target:

- `TerminalHostController` or replacement container creates `VTTerminalView`
- the view requests snapshots from `VTTerminalCore`

## Replace input emission path

Today:

- Ghostty surface emits bytes via `onWrite`

Target:

- Termsy encodes input using VT encoders and sends bytes directly to SSH

This is a major conceptual shift: input is no longer “whatever the surface produced,” but “what Termsy encoded from terminal state.”

---

## Risks and honest constraints

## 1. Rendering effort is real

This architecture is clean, but it is not cheap.

The public API gives the terminal model and render data, not the full renderer.

Termsy must still implement:

- glyph drawing
- font metrics and cell layout
- dirty-row painting
- cursor rendering
- selection rendering
- touch/hover/scroll behavior

## 2. Full Ghostty visual parity is not automatic

The existing surface renderer includes a lot of polish that the VT API does not hand to you as ready-made UIKit rendering.

The first VT renderer should aim for correctness and good UX, not one-step full parity.

## 3. Input parity requires care

To match modern terminal expectations, Termsy must correctly wire:

- key encoder
- mouse encoder
- focus reporting
- bracketed paste
- query reply effects

If those are skipped, the VT architecture will feel incomplete.

## 4. iOS suspension remains the hard boundary

This design does not eliminate the need for reconnect + `tmux` after real suspension.

---

## Decision

Under the agreed constraint of **public `libghostty-vt` only**, the concrete architecture for Termsy should be:

- **headless VT terminal per tab**
- **custom renderer from `GhosttyRenderState`**
- **input encoded via Ghostty VT encoders**
- **effects bridged explicitly back to SSH/UI state**

That is the only public-API VT design that is both coherent and implementable.

## Recommended order

If Termsy decides to pursue this direction, the architecture should be adopted in this order:

1. build `VTTerminalCore` and effect bridge
2. redirect SSH output into VT cores
3. implement minimal `VTFrameSnapshot`
4. build a selected-tab `VTTerminalView`
5. wire keyboard/paste/focus input
6. add mouse/selection/history polish

That gives Termsy a genuine `zmx`-style session model without depending on `ghostty_surface_t`.
