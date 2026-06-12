# Architecture

## Identity

damson **ships two artifacts at once** — sharing the same engine core.

### 1. `DamsonTerminal` (Swift Package, engine library)

The engine core imported by both cmux and `Damson.app`.

- Output: Swift Package (`DamsonTerminal`)
- Entry types: `DamsonSession` (model) + `DamsonTerminalView` (SwiftUI `NSViewRepresentable`)
- Dependencies: `Metal`, `MetalKit`, `CoreText`, `AppKit`, `QuartzCore`, `CoreVideo`. Zero external dependencies
- Build: `swift build` or Xcode's Swift Package integration

The library itself has **no** windows, menus, tabs, or settings UI. Those are the host's responsibility (cmux or `Damson.app`).

### 2. `Damson.app` (standalone macOS app)

Runs as its own .app bundle, like Rust halite. Imports the `DamsonTerminal` library and layers its own UI shell on top.

- Output: `Damson.app` (Xcode app target)
- Responsibilities: windows, menu bar, tab/split UI, settings window, theme hot-reload, Sparkle auto-update, damson-cli socket server
- Build: Xcode or `xcodebuild -scheme damson`
- Distribution: packaged as a `.dmg` on GitHub Releases (equivalent to Rust halite's current distribution)

### Why build both

- **`DamsonTerminal` library only**: clean cmux integration, but lightweight standalone terminal users (current halite users) lose out
- **`Damson.app` only**: keeps the standalone identity, but the embedding boundary with cmux reappears (reproducing the problem of options 1/2)
- **Both**: write the common engine once, use it in two places. A pattern ghostty has already proven (`GhosttyKit.xcframework` + `Ghostty.app`)

The engine doesn't know which host it's running in. The host creates a `DamsonSession` and plugs `DamsonTerminalView` into its own view hierarchy.

## Layers

```
┌─ DamsonTerminalView (SwiftUI NSViewRepresentable) ────── used by cmux
│  └─ DamsonSurfaceView (NSView + CAMetalLayer host)
│       ├─ NSTextInputClient                                ── input (IME)
│       ├─ scrollWheel / mouseDown / keyDown                ── input
│       └─ CAMetalLayer + CVDisplayLink                     ── output
│            └─ Renderer (Metal, persistent atlas)
├─ Terminal (model)
│  ├─ VTParser (state machine)
│  ├─ Grid + Scrollback (ring buffer, contiguous storage)
│  └─ Cursor / Selection / Hyperlinks
├─ PTYHost (off-main thread)
│  ├─ posix_spawn + openpty
│  └─ lock-free ring buffer → Renderer
└─ Config (struct, decoded from cmux-provided dict)
```

## Module breakdown

### `DamsonTerminal` library (shared by cmux + Damson.app)

| Module | Responsibility | Est. LOC |
|---|---|---|
| `DamsonTerminalView` | SwiftUI entry point (`NSViewRepresentable`) | <200 |
| `DamsonSurfaceView` | NSView, event routing, CAMetalLayer hosting | ~1,500 |
| `VTParser` | ANSI/VT/xterm escape sequence state machine | ~3,000 |
| `Grid` | cell grid, scrollback ring buffer, alt screen | ~1,500 |
| `Renderer` | Metal pipeline, glyph atlas, shaders | ~3,000 |
| `Shaper` | CoreText shaping, ligatures, East Asian Wide, NFC normalization | ~1,000 |
| `IMEController` | NSTextInputClient adapter | ~500 |
| `PTYHost` | PTY spawn + I/O thread + lock-free queue | ~500 |
| `Selection` | mouse selection, word/line expansion, find | ~800 |
| `DamsonConfig` | font/color/palette/scrollback options struct | ~300 |
| `DamsonSession` | external API tying all of the above together | ~400 |

**Library total: roughly 12,700 lines.**

### `Damson.app` shell (standalone app only)

cmux never sees this code. It imports only `DamsonTerminal`.

| Module | Responsibility | Est. LOC |
|---|---|---|
| `DamsonAppMain` | `@main` entry point, `NSApplicationDelegate` | ~200 |
| `WindowController` | `NSWindow`, traffic lights, blur, chrome | ~600 |
| `TabController` | tab bar, splits, drag | ~1,200 |
| `SettingsView` | SwiftUI settings window (fonts, themes, keybindings) | ~800 |
| `ThemeLoader` | theme hot-reload, automatic light/dark switching | ~300 |
| `DamsonCLIServer` | server compatible with the `damson-cli` socket protocol | ~600 |
| `UpdateController` | Sparkle integration | ~150 |
| `AppMenu` | menu bar, shortcuts | ~400 |

**Shell total: roughly 4,250 lines.**

### Grand total

**Roughly 17,000 lines.** Same order of magnitude as Rust halite (15–30k). Slightly smaller because CoreText/AppKit absorb the font shaping/IME/windowing code we'd otherwise write ourselves.

If bonsplit (cmux's Swift split UI) can be reused, `TabController` LOC shrinks further. But if bonsplit is coupled to cmux, it would need to be extracted first.

## Core data flows

### Output (PTY → screen)

```
PTY fd  ─[I/O thread, blocking read]─►  RawByteRing
                                            │
                                  [parser thread or batched main]
                                            ▼
                                        VTParser
                                            │
                                            ▼ (mutations)
                                          Grid
                                            │
                            [CVDisplayLink callback, vsync-aligned]
                                            ▼
                                        Renderer.draw()
                                            │
                                            ▼
                                       CAMetalLayer
```

**Invariants**:
- PTY reads never happen on the main thread
- VTParser application is serialized under a single lock. Rendering takes the lock, snapshots the grid, and releases immediately
- We don't draw on every vsync — only when the **dirty flag** is set. If nothing is dirty, the last drawable stays as-is

### Input (keyboard/mouse → PTY)

```
NSEvent (keyDown / scrollWheel / mouseDown / IME)
   │
   ▼
DamsonSurfaceView (NSView)
   │
   ├─ IME composition in progress? → handle marked text via NSTextInputClient methods
   │     └─ on commit, insertText → bytes → PTY write
   │
   ├─ keybinding? → invoke host (cmux) callback, then swallow (not sent to PTY)
   │
   └─ plain key/mouse → VT-encoded bytes → PTY fd write (off-main)
```

## Boundary with cmux

The surface damson exposes to cmux (plain Swift, no FFI):

```swift
public struct DamsonConfig {
    var fontFamily: String
    var fontSize: CGFloat
    var palette: [Int: NSColor]
    var backgroundColor: NSColor
    var foregroundColor: NSColor
    var scrollbackBytes: Int
    var argv: [String]
    var env: [String: String]
    var cwd: String?
    // ...
}

public final class DamsonSession: ObservableObject {
    public init(config: DamsonConfig)
    public func write(_ bytes: Data)            // extra input beyond keystrokes
    public func resize(cols: Int, rows: Int)
    public func scrollback() -> ScrollbackSnapshot
    public func find(_ query: String) -> [FindMatch]
    public func clearSelection()
    public var selection: String? { get }
    public var title: String { get }            // OSC 0/2
    public var workingDirectory: String? { get } // OSC 7
    public var processExited: Bool { get }
    public var exitCode: Int32? { get }

    // callbacks (cmux subscribes)
    public var onTitleChanged: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onURLClick: ((URL) -> Void)?
    public var onClipboardWrite: ((String) -> Void)?
}

public struct DamsonTerminalView: NSViewRepresentable {
    public let session: DamsonSession
    public var isActive: Bool
    public var onFocus: (() -> Void)?
    // SwiftUI usage
}
```

**Contrast with ghostty's ~60 C functions**: ~15 plain Swift APIs. The void* userdata registry, callback dispatch, and memory management are all handled naturally by ARC and closures.

## What we take from halite (Rust)

The code can't be reused (different language). The **design decisions** and **unit test cases** can.

| Valuable asset in halite | Use in damson |
|---|---|
| Catalog of escape sequences the VT parser handles | write Swift tests for the same cases |
| Glyph atlas page-partitioning strategy | implement the same idea with Metal textures |
| Ligature mapping table (`=>` → ⇒ etc.) | port to a Swift dictionary |
| Hangul IME design (NFC normalization + Wide cell policy) | reflect in the NSTextInputClient adapter |
| Theme format / default palette | becomes the Config struct defaults |
| Milestone ordering in `PLAN.md` | follow the same order in damson to burn down risk incrementally |
| `FEATURES.md` | use as spec/checklist |

## What we rewrite (everything)

- VT parser (Swift)
- Grid / scrollback
- Metal renderer + shaders (.metal files)
- Glyph atlas
- IME adapter (much shorter in Swift — `NSTextInputClient`)
- PTY host (`posix_spawn` + `openpty`)

## What we don't have to write (Swift/macOS provides it)

What the library core doesn't need to write:
- **Font shaping engine** — CoreText handles it (no HarfBuzz needed)
- **NFC normalization** — Foundation's `String.precomposedStringWithCanonicalMapping`
- **Trackpad momentum phase** — `NSEvent.momentumPhase`, `scrollingDeltaY`
- **ProMotion 120Hz vsync** — `CVDisplayLink` + `CAMetalLayer.maximumDrawableCount`
- **Automatic color scheme changes** — `NSApp.effectiveAppearance` KVO
- **Accessibility** — the `NSAccessibilityElement` protocol
- **IME candidate window positioning** — implement `NSTextInputClient.firstRect(forCharacterRange:)` and the system does the rest

What the `Damson.app` shell doesn't need to write:
- **Window chrome** — AppKit `NSWindow` + `NSVisualEffectView` blur
- **Menu bar / shortcut UI** — `NSMenu`
- **Settings forms** — SwiftUI `Form`, automatic `@AppStorage` binding
- **Auto-update UI** — Sparkle dialogs
- **Drag and drop** — `NSPasteboard` + custom UTIs
- **AppleScript dictionary** — define via `.sdef` if desired

What cmux as host doesn't need to write (it only imports the library):
- Everything in the `Damson.app` shell list above — cmux already has it or doesn't care
- **Theme hot-reload** — cmux builds a fresh `DamsonConfig` from its own theme system and calls `session.updateConfig(_:)`
- **Tabs/splits** — cmux's bonsplit handles them

## Build system

- `Package.swift` (SwiftPM). Vendored into cmux's `Packages/DamsonTerminal/` or added as a git submodule
- Metal shader (`.metal`) compilation: SwiftPM 0.5+ or an Xcode build phase. Shaders embedded in the package as `default.metallib`
- Tests: `swift test`. Unit tests for the VT parser, Grid, and IME. Golden image comparison for the renderer (optional)
- CI: macOS 14+ runners on GitHub Actions. Added as a job to cmux's hosted CI

## Milestones (proposed)

Ordering based on halite's `PLAN.md`. Each milestone must end in a state integrable into cmux (incremental integration).

- **M1**: black screen + 'hello world' output (PTY + minimal parser + plain glyph rendering)
- **M2**: 256 colors + basic escapes (cursor movement, EL/ED, SGR)
- **M3**: scrollback ring buffer + mouse wheel scrolling (doesn't need to be smooth yet)
- **M4**: **smooth scrolling** (sub-pixel offset, momentum) — [SMOOTH-SCROLL.md](SMOOTH-SCROLL.md)
- **M5**: glyph atlas + CJK + East Asian Wide
- **M6**: Hangul IME (NSTextInputClient adapter)
- **M7**: ligatures
- **M8**: selection / clipboard / find
- **M9**: hyperlinks OSC 8, shell integration OSC 7/133
- **M10**: integrate into cmux, regression tests against ghostty
- **M11**: remove ghostty

After each milestone, measure against cmux in practice (typing latency, scroll smoothness, memory).

### `Damson.app` shell milestones (parallel track)

Can proceed independently of the engine milestones. Can start any time after M3.

- **A1**: boot `Damson.app` with one window + one tab using the `DamsonTerminal` library
- **A2**: multiple tabs + splits (borrow cmux's bonsplit or build our own)
- **A3**: settings window + theme hot-reload + automatic light/dark switching
- **A4**: server compatible with the `damson-cli` socket protocol (Rust halite's external tooling works as-is)
- **A5**: Sparkle auto-update, code signing, notarization, `.dmg` distribution
- **A6**: AppleScript support (optional)

The cmux integration track (M10–M11) and the `Damson.app` track (A1–A6) **depend on the same engine library simultaneously**. A bug fix found on one side lands on the other immediately.

## Biggest risks

1. **The VT parser's long tail** — well-known escape sequences take days, but the subtle corners that real apps (vim, tmux, less, neovim's TUI libraries) depend on are a months-long burndown. We should borrow test cases from ghostty/iTerm2
2. **Dynamic glyph atlas updates vs. render synchronization** — while a new glyph is being uploaded, no other surface may read the same atlas. Needs fences / a triple-buffered atlas
3. **Trackpad momentum accuracy** — Apple occasionally changes deltaY units. Possible regressions per macOS major version (see cmux's macOS 26 case)
4. **Slow first glyph render** — the first CoreText call is expensive. Needs a background cache pre-warming strategy
