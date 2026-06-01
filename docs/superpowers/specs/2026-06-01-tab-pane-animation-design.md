# Tab & Pane Animations — Design

**Date:** 2026-06-01
**Status:** Approved for planning
**Branch:** `worktree-tab-pane-animation`

## Goal

Add subtle, fast motion to tab and pane lifecycle interactions so creating, closing, splitting, and switching feels fluid instead of instant/jarring. Reference: `~/dev/hiterm` animation techniques (snapshot-based view animation + `NSAnimationContext`).

## Scope (full motion pass)

Animate these interactions:

1. **Tab create** (`Cmd+T` / new tab)
2. **Tab switch** (select another existing tab)
3. **Tab close** (`Cmd+W` on a tab)
4. **Pane split** (`Cmd+D` horizontal, `Cmd+Shift+D` vertical)
5. **Pane close** (close active pane)

**Non-goals:**
- Pane **swap** — halite has no swap command; do not add one.
- Divider-drag resize — already interactive; no animation.
- Window open/close, app launch — out of scope.
- Animating the **resize** of the existing/sibling pane on split/close (decided: it snaps; see Decisions).

## Decisions

| Topic | Decision |
|---|---|
| Scope | Full motion pass (the 5 interactions above) |
| Feel / timing | Subtle & fast: **0.16s**, `easeOut` (matches existing scroll-snap & bell-flash) |
| Control | **Settings toggle** (`halite.animations`, default **ON**) **AND** honor macOS **Reduce Motion** |
| Technique | **Approach A**: transform+opacity for appearing content; **snapshot** for torn-down content; existing/sibling pane resize **snaps** (one reflow, not animated) |

### Why Approach A

halite surfaces are **NSTextView/NSScrollView**. Resizing a *live* surface fires SIGWINCH → the shell/TUI reflows. Animating live frames every tick (the naive approach) causes a reflow storm — janky and expensive. Approach A never continuously resizes a live surface:

- **Appearing** views (new tab content, new pane) get their final frame immediately, then animate `layer.transform` (slide/scale from an offset) + `opacity` 0→1 — purely visual, **zero reflow**.
- **Disappearing & torn-down** content (closing tab/pane; the outgoing tab on switch, which is removed from the hierarchy) is captured as a **bitmap snapshot** overlay that animates out after the live view is gone.
- The existing pane shrinking on split / sibling growing on close **snaps once** (a single reflow). At 0.16s the eye follows the appearing/disappearing element; the snap is imperceptible.

## Architecture

### Shared motion core — `Motion`

New file `Sources/HaliteTerminal/Motion.swift`. A small stateless helper (enum with static members), no instances. (Placed in the **HaliteTerminal library** rather than the `halite` executable so the gating logic is unit-testable — the executable target has no test target. Public API and call sites are unchanged; callers already `import HaliteTerminal`.)

```
enum Motion {
    static let duration: TimeInterval = 0.16
    static var timing: CAMediaTimingFunction { .init(name: .easeOut) }

    /// Master gate: user toggle AND not Reduce Motion.
    static var enabled: Bool {
        let toggle = (UserDefaults.standard.object(forKey: "halite.animations") as? Bool) ?? true
        return toggle && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Bitmap snapshot of a view's current rendering (for torn-down content).
    static func snapshot(of view: NSView) -> NSImage?

    /// Drop a self-removing image-backed overlay layer at `frame` in `host`,
    /// returns it so the caller can animate it out. Used for disappearing content.
    static func overlay(image: NSImage, frame: NSRect, in host: NSView) -> CALayer

    /// Run a 0.16s easeOut NSAnimationContext group with a completion handler.
    static func run(_ body: () -> Void, done: (() -> Void)? = nil)
}
```

- `enabled` is read at each animation entry point. When `false`, callers skip straight to the existing instant code path — **identical end state** to today.
- `snapshot(of:)` uses `bitmapImageRepForCachingDisplay(in:)` + `cacheDisplay(in:to:)` (captures NSTextView content reliably, including the scroll view).
- Reading `enabled` live each call is sufficient; no need to observe change notifications.

### Per-interaction specifications

All animations are **0.16s / easeOut**. "live" = the real view at its final frame; "snap" = bitmap overlay.

| Interaction | Technique | Motion detail |
|---|---|---|
| **Tab create** | live | New `PaneTreeView` pinned at final frame; `layer.opacity` 0→1 + `transform` scale 0.98→1.0. |
| **Tab switch** | snap out + live in | Snapshot the outgoing tab → overlay. Incoming live tab + outgoing snapshot both slide horizontally by a small delta (≈ +24pt, direction from index sign) while crossfading (snapshot α 1→0, live α 0→1). |
| **Tab close** | snap | Snapshot closing tab → overlay; next tab shown live at full frame underneath; overlay slides **down** (≈ +0.06×height) + fades out, then removed. |
| **Pane split** | live | Existing pane snaps to its half-frame (one reflow); **new pane** wrapper at final half-frame, `transform` translated from the divider edge (toward its side) + `opacity` 0→1 → animates to identity ("opens from the split line"). |
| **Pane close** | snap | Snapshot closing pane → overlay at its old frame; sibling snaps to full underneath; overlay slides toward the closing pane's outer edge (≈ 0.06× dimension) + fades out, then removed. |

Slide offsets are intentionally small (a "nudge", not a full traverse) to keep the motion subtle.

### Hook points

Animation intent is threaded through the existing methods; the disabled/instant path is preserved as the default.

- **`CompactWindowController.selectTab(_:)`** — `Sources/halite/CompactWindowController.swift:171`. Today it removes all tab views and adds the selected one. Add an intent param (e.g. `selectTab(_ index: Int, transition: TabTransition = .none)` with cases `.none / .create / .switch(fromIndex:) `). Capture the outgoing tab snapshot *before* `removeFromSuperview()`; run the animation *after* the new constraints/first-responder are set.
- **`CompactWindowController.addTab(tree:)`** (`:147`) → drives `.create` transition via `selectTab`.
- **`CompactWindowController.closeTab(_:)`** — snapshot the closing tab content before teardown, then show the next tab live and animate the snapshot out.
- **`PaneTreeView.split(direction:)`** (`Sources/halite/PaneTreeView.swift:52`) and **`closeActive()`** (`:71`) — both call `rebuild()` (`:148`, which nukes & re-adds all subviews). Add `rebuild(animation: PaneAnimation = .none)` with cases `.none / .split(newLeaf:) / .close(closingSnapshot:closingFrame:edge:)`. For split, after rebuild identify the new pane's `PaneLeafWrapper` (matches `newLeaf`) and animate it in. For close, snapshot the active pane *before* mutating the tree, then animate the overlay out after rebuild.

### Settings + Reduce Motion

- **`HaliteConfig`** — add `animations: Bool` (default `true`), populated from `UserDefaults` key `halite.animations` (mirror `cursorBlink`).
- **`SettingsView.swift`** — add `@AppStorage("halite.animations") private var animations: Bool = true`, a `Toggle("Animations", isOn: $animations)` near the cursor-blink toggle, and `.onChange(of: animations) { _ in postChanged() }`; load in the config read path (`config.animations = d.object(forKey: "halite.animations") as? Bool ?? true`).
- `Motion.enabled` ANDs the toggle with `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`, so Reduce Motion wins regardless of the toggle.

## Edge cases & correctness

- **Focus**: first-responder / `window.makeFirstResponder(surface)` is set to the **final** state immediately (as today), not after the animation — typing works mid-animation.
- **Rapid actions** (spam `Cmd+T` / `Cmd+D` / `Cmd+W`): overlays are self-removing on completion **and** safe if superseded — a new action does not depend on a prior overlay; prior overlays finish or are removed without affecting the new live state. No in-flight global lock needed; each animation targets distinct views/overlays.
- **Window resize / SIGWINCH mid-animation**: appearing views already hold their final frame; `transform`/`opacity` are visual-only and settle at identity, so autoresizing/layout passes don't fight the animation.
- **Disabled (toggle off or Reduce Motion)**: every entry point runs the current instant code with no overlays/transforms — behavior identical to today.
- **Snapshot fidelity**: if `snapshot(of:)` returns `nil` (e.g. zero-size), fall back to the instant path for that interaction.

## Testing

Motion is visual/timing — verified manually (this project's norm; see prior scroll work). Automated coverage for the non-visual logic:

- `Motion.enabled` truth table: toggle on/off × Reduce-Motion on/off.
- Disabled path: `selectTab`/`rebuild` reach the correct **final** view hierarchy & first-responder **synchronously** when animations are disabled (no overlay views linger).
- `snapshot(of:)` returns non-nil for a sized view.

Manual checklist: each of the 5 interactions looks smooth; rapid spam leaves no stray overlays; typing works during animations; toggling the setting and macOS Reduce Motion both disable motion.

## Incremental implementation order

1. `Motion` core + `HaliteConfig.animations` + `SettingsView` toggle + Reduce-Motion gate (no behavior change yet).
2. Tab create (simplest live transform).
3. Pane split (live transform-in of new pane).
4. Tab close + Pane close (snapshot overlay out).
5. Tab switch (snapshot out + live in crossfade/slide).
6. Manual QA pass + the gating unit tests.

Each step builds, runs, and is independently verifiable.
