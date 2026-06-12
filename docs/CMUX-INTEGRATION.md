# cmux Integration Plan

Scope of work for plugging damson into cmux and removing ghostty.

## What Depends on What

cmux depends **only on the `DamsonTerminal` Swift Package (the engine library)**. `Damson.app` is a separate artifact and is irrelevant to cmux.

```
~/dev/damson/
├── Package.swift                       ← cmux depends on this
├── Sources/DamsonTerminal/              ← engine library (shared by cmux + Damson.app)
└── Apps/damson/                         ← standalone .app (cmux ignores it)
```

From cmux's perspective, the ghostty C headers/xcframework go away and a Swift package takes their place — that's all. The existence of `Damson.app` has no effect on the cmux build or runtime.

## Core Strategy

**Incremental.** Don't rip out ghostty in one shot. Go through a state where both engines coexist, verify against regressions, then remove ghostty.

1. Vendor damson into cmux as `Packages/DamsonTerminal/`
2. Add a toggle to cmux's `BetaFeaturesSettingsView`: "Use damson terminal engine"
3. Surfaces with the toggle on render via `DamsonTerminalView`; surfaces with it off use the existing `GhosttyTerminalView` — they can coexist within a single window
4. Regression-test every cmux UI flow (tabs, splits, drag, search, clipboard, find, color changes, theme hot-reload) against damson surfaces
5. Once stable, flip the toggle to default-on
6. After one cycle, remove the ghostty code / submodule / xcframework

## What Goes Away on the cmux Side

| Asset | Disposition |
|---|---|
| `ghostty/` submodule | Remove |
| `GhosttyKit.xcframework` | Remove |
| `ghostty.h` (bridging) | Remove |
| ghostty includes in `cmux-Bridging-Header.h` | Remove |
| `Sources/Ghostty*.swift` (10 files, ~17k LOC) | Replaced by `Sources/Damson*.swift`. Volume shrinks to 1/3–1/4, though (FFI/callbacks/userdata registry disappear) |
| `cd ghostty && zig build ...` in `scripts/setup.sh` | Remove |
| GhosttyKit build commands section in `CLAUDE.md` | Replace with damson build notes |
| `docs/ghostty-fork.md` | Keep (history), or move to `docs/archive/` |

## What's New or Changed on the cmux Side

| Asset | Work |
|---|---|
| `Packages/DamsonTerminal/` | damson Swift Package, vendored or as a submodule |
| `Sources/DamsonTerminalView.swift` (new) | Create/destroy `DamsonSession`, convert cmux config → `DamsonConfig`, route callbacks into cmux models |
| `Sources/DamsonConfigBuilder.swift` (new) | What `GhosttyConfig` did, now via `DamsonConfig`. Map font/palette/scrollback/IME options |
| `Sources/WorkspaceSurfaceConfig.swift` | From the ghostty surface config structure to damson session config |
| `Sources/Workspace.swift`, `Sources/TabManager.swift` | A `DamsonSurfaceModel` alongside or replacing `TerminalSurface` (ghostty) |
| `Sources/Panels/TerminalPanel.swift` | Branch on which engine is in use (during the transition), or unify on damson (after full migration) |
| `Sources/AppearanceSettings.swift` | Drop ghostty-only options, switch to damson options (mostly 1:1 mappings) |
| Keyboard shortcut system | `ghostty_surface_binding_action` calls disappear; cmux takes full ownership of key routing. No impact on `KeyboardShortcutSettings` |
| `GhosttyCrashReportMetadata` | Replace with `DamsonCrashReportMetadata`. Current surface, scrollback size, etc. |
| `cmuxTests/` | Port ghostty-dependent tests to damson. Keep the core regressions (typing latency, IME, splits, drag tabs) as-is |

## API Mapping Table

cmux's ghostty call sites → damson equivalents:

| ghostty C API | damson Swift API |
|---|---|
| `ghostty_init`, `ghostty_app_new` | (Not needed. The first `DamsonSession()` lazy-initializes) |
| `ghostty_app_tick` | (Not needed. `CVDisplayLink` ticks automatically) |
| `ghostty_app_set_focus` | `DamsonSession.isFocused = true/false` |
| `ghostty_app_update_config` | `DamsonSession.updateConfig(_:)` or create a new session |
| `ghostty_config_new/free/load_*` | `DamsonConfig` struct (value type, ARC handles it) |
| `ghostty_config_diagnostics_*` | `DamsonConfig.validate() -> [Diagnostic]` |
| `ghostty_surface_new/free` | `DamsonSession(config:)` / deinit |
| `ghostty_surface_refresh` | `DamsonSession.requestRedraw()` (rarely needed) |
| `ghostty_surface_set_size` | `DamsonSession.resize(cols:rows:)` |
| `ghostty_surface_set_focus` | `DamsonSession.isFocused` |
| `ghostty_surface_key` | Automatic inside `DamsonSurfaceView.keyDown(with:)` |
| `ghostty_surface_preedit` | `DamsonSurfaceView` implements `NSTextInputClient` directly |
| `ghostty_surface_mouse_*` | NSView mouse events handled automatically |
| `ghostty_surface_ime_point` | `firstRect(forCharacterRange:)` `NSTextInputClient` method |
| `ghostty_surface_text` | `DamsonSession.scrollback().fullText()` |
| `ghostty_surface_read_selection` | `DamsonSession.selection` |
| `ghostty_surface_has_selection` | `DamsonSession.selection != nil` |
| `ghostty_surface_clear_selection_compat` | `DamsonSession.clearSelection()` |
| `ghostty_surface_quicklook_word` | `DamsonSession.wordAt(point:)` |
| `ghostty_surface_complete_clipboard_request` | Return a String to the completion of the `onClipboardRead` callback |
| `ghostty_surface_binding_action` | (cmux fully owns key routing. The call itself disappears) |
| `ghostty_surface_key_is_binding` | Likewise |
| `ghostty_set_window_background_blur` | cmux handles it directly via `NSVisualEffectView` |
| `ghostty_surface_process_exited` | `DamsonSession.processExited`, `onExit` callback |
| `ghostty_surface_needs_confirm_quit` | Only the policy decision (e.g. `DamsonSession.hasUnsavedWork`) stays in cmux |

## Callback Simplification

The ghostty C callbacks took a `void* userdata` and dereferenced it back to a Swift object through `TerminalSurfaceRegistry`. In damson:

```swift
session.onTitleChanged = { [weak self] title in
    self?.tabModel.title = title
}
```

ARC + closures, done. The `TerminalSurfaceRegistry` class itself becomes unnecessary.

## Build Pipeline Changes

`scripts/setup.sh`:
```diff
- (cd ghostty && zig build -Demit-xcframework=true ...)
+ (cd Packages/DamsonTerminal && swift build -c release)
```

`scripts/reload.sh`:
- The xcframework rebuild trigger on ghostty changes goes away
- Xcode builds the Swift Package incrementally on its own
- Net result: reload gets faster

CI:
- `gh workflow run test-e2e.yml` stays as-is
- The ghostty build cache step can be dropped (removes the Zig toolchain dependency)

## Regression Verification Checklist

All of the following must pass after the toggle flip before ghostty can be removed:

- [ ] Double-click `cmux DEV.app` → first surface reaches a prompt within 5 seconds
- [ ] Korean IME: no composition breakage while typing "안녕하세요"
- [ ] Korean IME: candidate window position matches the cursor position
- [ ] Scrolling (trackpad) stays smooth while `cat`-ing 1MB of text
- [ ] Open a large file in vim, `j/k` scrolling typing latency on par
- [ ] nvim works inside nested cmux inside tmux
- [ ] After splitting, both surfaces accept input independently
- [ ] Surfaces survive tab drag reordering
- [ ] PTY/scrollback preserved when moving tabs between windows
- [ ] Background color hot-reload (theme change)
- [ ] Automatic light/dark switching
- [ ] Clipboard OSC52
- [ ] Shell integration OSC 7 (CWD) works
- [ ] Find overlay works + results highlighted
- [ ] Mouse wheel momentum feels similar to ghostty
- [ ] Renders at 120Hz on a ProMotion 120Hz display (verify with Quartz Debug)
- [ ] Consistent surface handling when the helper process / child shell exits
- [ ] Surface manipulation from AppleScript (via cmux's `AppleScriptSupport.swift`)
- [ ] `cmux send` works from the CLI

## Rough Timeline

(Mental model assuming the author / a one-person team. Likely to take longer in practice.)

- damson itself: M1–M9, roughly 3–5 months
- cmux integration (toggle + surface code): 2–3 weeks
- Regression verification + stabilization: 1–2 months
- ghostty removal + cleanup: 1 week

About 5–7 months total. If it's not one person full-time, it stretches accordingly.

## Mid-Course Stopping Points

It must be possible to stop at any of the following states:

- Even with damson only complete through M3, the cmux toggle is worthwhile (basic shell use works)
- Even at M9, damson can coexist with ghostty. User-selectable option
- ghostty removal happens **last** only, after sufficient dogfooding

This way, even if the project stalls midway, cmux keeps running on ghostty undamaged.
