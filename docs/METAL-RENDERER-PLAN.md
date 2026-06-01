# Metal Renderer — Architecture & Phased Plan

Produced by the design-metal-renderer workflow (3 designs, adversarial judging, synthesis).

## Design ranking

```json
[
  {
    "design": "incremental-seam",
    "total": 53,
    "verdict": "Strongest design of the three for THIS codebase and integration contract. Its differentiation is structural, not technical: on the renderer guts (passes, atlas, AA, shaping, scroll math, draw trigger, concurrency) it converges with the faithful-port and ghostty-style designs on ~95% of decisions, so it neither leads nor lags on correctness/latency. Where it decisively wins is integrationFit, phasability, and risk — the byte-stable public API by construction, the live A/B harness enabled by the verified backend-independent HaliteSession/Grid model, the shared-cellMetrics catch that prevents toggle-induced SIGWINCH, and the named P7 that retires the legacy path. The two genuine flaws are a scroll seam shaped for the Metal destination (so the legacy backend's P0 conformance is an adapter, not the advertised compile-time proof) and an under-specified host→flipped-content coordinate conversion in cell(at:). Both are fixable spec-precision gaps, not architectural defects. With the four must-fixes addressed, this is the design to implement: it reaches a placeholder-deleting renderer on the same timeline as the rivals while being the only one that can de-risk every phase against the live legacy output.\"",
    "mustFix": [
      "§10 `cell(at: pointInHost:)` must explicitly convert the host point into the flipped MetalContentView coordinate space (contentView.convert(pointInHost, from: host)) BEFORE applying `row = floor((y + scrollYPixels - inset)/cellH)`, or the row axis inverts. The forward screenRect path does the symmetric to:host conversion; make the inverse path symmetric. Validate against the verified current convertEventToCell (:974-985), which relies on NSTextView being flipped-by-default.",
      "Either define the legacy scalar-scroll adapter explicitly (how LegacyTextBackend maps scrollYPixels / setScrollY(animated:) / handleScrollWheel onto clipView.bounds.origin.y + reflectScrolledClipView + didLiveScrollNotification, verified as the current mechanism), OR scope the 'P0 proves the seam' claim to render + cell-geometry and concede that scroll behavior is not faithfully exercised by the legacy backend until the Metal backend lands. Do not let the headline compile-time-proof claim cover scroll silently.",
      "Resolve the `makeDefaultLibrary(bundle: .module)` shader-load path for the HaliteTerminal LIBRARY target as the stated P1 build gate before P2 builds on it — confirm `.process(\"MetalRender/Shaders.metal\")` resolves via Bundle.module (it is used in the executable target but unproven for this library target), with the embedded-source `makeLibrary(source:)` fallback ready.",
      "Add an explicit A/B parity caveat for the deliberately-reproduced `markedText.count` IME advance bug so a future wcwidth-correct fix is not flagged as an A/B regression; tie the harness's pass criteria to 'matches legacy EXCEPT known-divergence list' rather than strict pixel-equality."
    ]
  },
  {
    "design": "ghostty-style",
    "total": 46,
    "verdict": "Strong, code-accurate, well-calibrated design that is the most faithful of the three to the contract's 'reproduce current visuals exactly' mandate — it correctly defers effects the placeholder lacks (where faithful-port over-builds) and nails the three top-3 contract risks (6-part dirty key, on-main concurrency seam, firstRect/coordinate port). It ties the rivals on latency and matches them on public-API preservation (high integrationFit), and likely wins effortRealism against faithful-port's oversized P7/P8 scope. It trails incremental-seam on RISK (no runtime toggle, no instant legacy fallback, no live pixel-diff oracle) and on PHASABILITY (the 'M1 replaces the placeholder' claim is overstated; real parity is M3-M4). Must-fix the M1 framing, the under-specified baseline formula, and the Uniforms-buffer race; the design is implementable as written once those are tightened. Not a takedown — a sharpen.",
    "mustFix": [
      "Correct the M1 milestone claim: M1 (ASCII echo, no scroll, no selection/find/IME placement) does NOT replace the placeholder. State the real parity gate at M3-M4 (interactive overlays + scroll + IME candidate placement) before the NSTextView path can be deleted, so phases are honestly sequenced.",
      "Specify the exact glyph baseline formula and gate it on a pixel-diff vs the placeholder. Replace §8.4's 'cellH-descent-ish, tuned' with a concrete derivation (e.g. faithful-port §9's baseline=round((cellH-(ascent+descent))/2)+ascent; cellOrigin.y=rowTop+(baseline-bearingY)), since cellH is the empirical measuredLineHeight and a wrong baseline shifts every row vs the current renderer.",
      "Ring-buffer (or per-frame-allocate within the ring) the Uniforms buffer, not just the instance buffers. renderScrollOnly() mutates Uniforms.scrollYPixels every animation tick; with a single shared Uniforms buffer that write races the GPU reading the previous frame. Tie Uniforms into the same DispatchSemaphore(3) ring as the instance buffers.",
      "Add a fallback/comparison plan to close the risk gap vs incremental-seam: at minimum a build flag to keep the NSTextView path runnable during bring-up, or an explicit per-milestone screenshot pixel-diff procedure against the placeholder, so a pixel-divergence regression is catchable rather than only discoverable in dogfooding.",
      "Pin cellMetrics as shared/identical to the placeholder's measuredLineHeight formula at cutover and assert it produces the same floor(usable/cell) cols/rows, so swapping to Metal never fires a spurious SIGWINCH/reflow (the contract's tabBarReservation+scroller-width sizing must also be re-derived without the scroller term)."
    ]
  },
  {
    "design": "faithful-port",
    "total": 38,
    "verdict": "Technically the most thorough and correct core renderer of the three on the load-bearing seams (6-part key, sync gate, main-thread concurrency, on-demand draw, cellMetrics, IME firstRect, public API stability) — fully competitive with the rivals on correctness, latency-safety, and integration fit (~8 each). But its differentiating scope is its undoing for THIS task: the headline value (full Rust-pipeline parity via P4-P8) is exactly the scope the contract excludes, and P6/P7 build on image/effect/particle data that the halite-swift model and VTParser provably do not produce (grep-confirmed zero support). It scores well on the core and drops hard on effort-realism and risk relative to the leaner ghostty-style and the safer incremental-seam designs. Strip P4-P8 and verify the ligature default and it would be a strong P0-P3 plan; as written, the lavish unrequired, model-blocked phasing is a liability, not rigor.",
    "mustFix": [
      "Cut or quarantine P6 (images) and P7 (effects/post-fx/particles) until VTParser + Grid + Cell gain image-placement parsing and storage. As written these phases port image_pass.rs/effects.rs against a model that produces no image, sixel, Kitty, or particle data (grep-confirmed zero hits in Sources/). Either descope them entirely to match the contract (reproduce current placeholder visuals) or add explicit parser+model milestones before them and re-estimate effort.",
      "Resolve the ligature-default question empirically, not by assertion. Either default ligatures OFF (matching both rival designs and the recipe), or pixel-diff Menlo and a ligature font (Fira Code) against the current NSTextView renderer at P3 to prove 'visually identical' before shipping default-on. Do not ship the current unverified claim that NSAttributedString shaping makes default-on byte-identical.",
      "Add a fallback/validation harness that survives past P3. The placeholder is deleted at P3 with no way to A/B-compare against legacy on a live terminal. Either keep a runtime legacy/Metal toggle through the parity-gate phases (as incremental-seam does) or define an explicit pixel-diff regression suite, and add a shared backend-independent cellMetrics guard so any bring-up swap cannot fire spurious SIGWINCH.",
      "Re-scope the design to lead with P0-P3 as the deliverable that satisfies the contract, and explicitly label P4-P8 as out-of-contract future work gated on separate model/parser efforts, rather than presenting full-pipeline parity as the headline."
    ]
  }
]
```

---

# PHASED IMPLEMENTATION PLAN

Excellent advice. The advisor caught the two real spec violations: §13's phase order doesn't satisfy "Phase 1 = first Metal pixels" or "front-load all 4 unknowns (especially IME cursor-rect, stranded at P4)." I'll restructure so Phase 1 lands bg + ASCII text + coordinate-map/IME-cursor-rect together, splitting coordinate correctness from preedit visual. I'll use SwiftPM conventions (`swift run halite`, auto-discovered tests, no pbxproj/two-commit policy), and give every phase the full five-field template with rollback nuance for shared refactors.

This is my final deliverable.

---

# Halite-Swift Metal Renderer — Phased Implementation Plan

**For maintainer approval before coding.** Self-contained; the companion architecture doc holds the per-decision rationale and the verified line-number catalog.

## What this is

Replace the temporary M3 render placeholder — `NSScrollView` + child `NSTextView` + full `NSAttributedString` rebuild every frame (`HaliteTerminalView.swift:41-45`, explicitly flagged "M4 이후 CAMetalLayer + 자체 렌더러로 교체") — with a `CAMetalLayer` instanced renderer, **behind a runtime toggle**, reaching exact visual parity, then retiring the legacy path.

**Strategy:** extract a `TerminalRenderBackend` protocol, make the *existing* NSTextView path conform first (zero visible change), then build the Metal backend as a second conformer selectable live. The toggle doubles as an A/B pixel-diff oracle on a running terminal. Every phase ends in a buildable, dogfoodable `swift run halite`.

**Conventions (SwiftPM, not cmux):** dogfood with `swift run halite` (legacy) and `HALITE_METAL=1 swift run halite` (Metal). Tests in `Tests/HaliteTerminalTests/` are XCTest, **auto-discovered — no project-file wiring, no two-commit red/green policy**. All cited line numbers verified against the live tree this session.

## Hard invariants held at every phase

- **Public API byte-stable:** `HaliteSurfaceView: NSView` + `init(session:)` (`:147`, consumed directly by `PaneTree.swift:26`, `main.swift:368`, `CompactWindowController`); all `@objc public` selectors (find/zoom/copy/paste/find-panel/split); the `HaliteTerminalView` representable; the full `NSTextInputClient` conformance; `HaliteSession`/`Grid`/`Cell` read surfaces. The `CAMetalLayer` lives *inside* a backend-owned subview — the host class never changes.
- **Input path never regresses:** keyboard→PTY, IME (incl. Hangul BS-cancel + warmup), mouse reporting (SGR/X10, button 64/65), selection, Cmd-click/hover URLs all stay in `HaliteSurfaceView`, routed to the backend only for coordinate conversion.
- **6-part composite dirty key untouched** (`renderNow :1543-1566`: `version + markedText + selKey + findKey + hoverKey + blinkKey`). Both backends inherit it verbatim. The sync-output torn-frame gate (`scheduleRender :1517`, 150ms safety flush) stays above the backend call.
- **Concurrency unchanged:** `PTYHost` hops every chunk to main (`PTYHost.swift:173`) before `parser.feed`→grid mutation. Parse, mutate, and render all serialize on main; `Grid` has no lock. The Metal path stays on-demand on main; the scroll-animation display-link re-reads only the pre-built GPU buffer, never `session.grid`. **No `gridLock`/double-buffer is introduced — that would add a race that does not exist today.**
- **Typing latency:** per-keystroke Metal work (atlas-cached glyph lookup + instance write) is strictly less than today's `setAttributedString` + `ensureLayout`. No app-level display link for typing; the scroll link is transient (animation-only).

---

## Phase 0 — Extract the seam (no Metal, no visible change)

**Goal.** Put the `TerminalRenderBackend` protocol between `HaliteSurfaceView` and its render/geometry/scroll mechanism, with the current NSTextView path as the first conformer. Prove the seam holds before any Metal exists: input/IME/mouse geometry can no longer reach `textView.convert` except through the legacy backend, or it won't compile.

**Files.**
- NEW `RenderBackend.swift` — `protocol TerminalRenderBackend`; `struct RenderState` (markedText, selection, find matches, active-find, hovered-URL, blink flags — exactly the view-local state the 6-part key tracks); `enum RenderBackendKind { case legacyText, metal }`.
- NEW `LegacyTextBackend.swift` — wraps the current `NSScrollView`/`PassiveTextView`; implements `render`, `cell(at:)`, `screenRect(forCell:)`, and the scalar scroll adapter (`scrollYPixels` getter = `clipView.bounds.origin.y` `:356`; `setScrollY` = `scroll(to:)`+`reflectScrolledClipView` `:370/:391`; `setScrollY(animated:)` = `clipView.animator().setBoundsOrigin` `:870`; `handleScrollWheel` = native momentum).
- NEW `MetalRenderConfig.swift` — toggle resolution: live override > env `HALITE_METAL=1` > `UserDefaults "HaliteMetalRenderer"` > `.legacyText`.
- EDIT `HaliteTerminalView.swift` — move `scrollView`/`textView`/`cursorLayer` behind `legacyBackend`; `renderNow()` tail becomes `backend.render(grid:theme:state:)`; geometry calls (`convertEventToCell :974`, `firstRect :1474`, `updateCursorLayer :1737`) route through the protocol; `switchBackend(to:)` (tear down old contentView, install new, copy `scrollYPixels`, force full render).

**Deliverable.** Identical app, now factored through one backend protocol with the toggle wired (defaults `.legacyText`).

**Verify.** `swift run halite` — visually and behaviorally identical to today: typing, IME (Korean/Japanese candidate window on the cursor), selection drag, find highlight, Cmd-hover URLs, blink, scrollback, zoom, resize-no-spurious-SIGWINCH. *Unit:* `RenderState` equality drives the dirty key identically (snapshot-equality test). Pixel-diff a screenshot before/after the refactor — must be identical.

**Rollback.** Phase 0 is a **shared refactor — the toggle does not protect it** (the legacy path is now routed through new code for both backends). Rollback is `git revert`, not a flag flip. Treat the diff as byte-identical-critical: review the geometry routing line-by-line.

---

## Phase 1 — Metal on screen: background + ASCII text + coordinate/IME correctness

**Goal — the make-or-break phase, all front-loaded.** First Metal pixels, and three of the four named unknowns proven at once: `CAMetalLayer` hosted inside `HaliteSurfaceView`, the glyph atlas + on-demand draw, and **IME cursor-rect placement** (candidate window must land *on* the cursor). The fourth unknown (atlas growth) is deferred to P6; only the basic atlas is proven here.

*Decision flagged for approval:* the architecture split bg (its P1) and text (its P2) for debug isolation. **This plan folds them** so the first dogfoodable Metal frame is *readable* and exercises the atlas + baseline immediately — the higher-risk surfaces. Trade-off: a larger first Metal diff. If you prefer isolation, we split into 1a (bg + block-cursor-inverse, no glyphs) and 1b (ASCII text); the exit criteria below partition cleanly.

**Why coordinate-rect, not preedit, lands here.** `firstRect` and `cell(at:)` need only `MetalContentView` + scalar `scrollYPixels` + the `CoordinateMap` arithmetic — **not glyphs and not the preedit visual overlay.** So IME *candidate placement* is provable in Phase 1; the preedit *wash/underline* visual is parity polish in P4.

**Files.**
- NEW `MetalRender/MetalDevice.swift` — shared `MTLDevice`/`MTLCommandQueue`, pipeline factory, feature probe, and **the library-load gate (highest-risk unknown):** `device.makeDefaultLibrary(bundle: .module)`. `Bundle.module` is currently used **only** in the executable target (`AppBundleTrampoline.swift:90,93`), never in `HaliteTerminal` — this path is unproven for a library target and is the *first thing validated*. Documented fallback: embed shader source as a Swift string and `device.makeLibrary(source:)`. **Decide here before P2 builds on it.**
- NEW `MetalRender/MetalContentView.swift` — `NSView`, `isFlipped = true` (**flip localized here, not the host** — fixes must-fix A by construction), `makeBackingLayer → CAMetalLayer` (`.bgra8Unorm_srgb`, `framebufferOnly`, `maximumDrawableCount=3`, `allowsNextDrawableTimeout`).
- NEW `MetalRender/CoordinateMap.swift` — **pure-function** row/col↔pixel arithmetic (flip/`convert` as a thin AppKit shim around it); `cell(at:)`, `screenRect(forCell:)`, `firstRect`. The forward path applies `yViewport = yContent − scrollYPixels`; the inverse does `contentView.convert(point, from: host)` **first** into the flipped view, *then* `row = floor((p.y + scrollYPixels − inset)/cellH)`.
- NEW `MetalRender/GlyphAtlas.swift` (mask page R8, `ShelfPacker`, glyph key map), `GlyphRasterizer.swift` (`CTFontDrawGlyphs`→`CGBitmapContext`), `RenderTypes.swift` (repr-C `Uniforms`/`BgInstance`/`GlyphInstance`), `Shaders.metal` (bg + glyph-mask vertex/fragment).
- NEW `MetalRender/MetalTerminalBackend.swift` — owns `MetalContentView`, triple-buffer ring (**instances AND uniforms** in the same `DispatchSemaphore(3)` — fixes must-fix F), encodes clear→bg→glyph-mask passes, present-on-demand. ASCII fast path `CTFontGetGlyphsForCharacters` (ligatures off). Block-cursor-inverse as a swapped `BgInstance` + re-emitted swapped-fg `GlyphInstance` (mirrors `inverseCell.attrs.inverse.toggle()` `:1822`).
- NEW `MetalRender/InstanceBuilder.swift` — `Grid` + `RenderState` → instance arrays (no Metal types; the hot path).
- NEW shared `cellMetrics` provider — computed **once, backend-independent** (`cellW = ("M").size(font).width`; `cellH = measuredLineHeight("M\nM\nM"/3)` `:400`), consumed by both backends so flipping the toggle reports identical `(cols,rows)` and **never fires SIGWINCH**.
- EDIT `Package.swift` — `resources: [.process("MetalRender/Shaders.metal")]`.
- EDIT `HaliteTerminalView.swift` — `viewDidChangeBackingProperties`/`viewDidChangeEffectiveAppearance`/`layout` forward to backend; `firstRect`/`convertEventToCell` delegate to `backend`.

**Deliverable.** `HALITE_METAL=1 swift run halite` shows a readable shell (`ls`, prompt, `vim`) in Metal: correct background colors, monospace ASCII text at the calibrated baseline, block-cursor-as-inverse, and **the Korean/Japanese IME candidate window landing on the cursor**. Legacy still default.

**Verify.**
- *Build gate:* shader library loads via `.module` (or the source fallback engages) — log which path succeeded.
- *Dogfood:* flip the toggle live mid-session — `cols/rows` identical (no reflow/SIGWINCH); bg + ASCII + block cursor match legacy; type Korean/Japanese and confirm the candidate window sits *on* the cursor (the classic flip bug pins it to screen top); basic mouse-wheel scrollback works (non-animated scalar — see note below).
- *Unit (high value):* **CoordinateMap round-trip `cell(at: screenRect(forCell: r,c)) == (r,c)`** — this catches must-fix A (coordinate symmetry) as a cheap regression test, no live NSView needed. `cellMetrics` math (cols/rows = `floor(usable/cell)`). `ShelfPacker` packing (no overlap, advances shelves, reports full). Baseline formula `round((cellH−(ascent+descent))/2)+ascent` against fixed CTFont metrics.

**Scroll note (so the phase is genuinely dogfoodable).** The Metal backend gets **functional non-animated scalar scroll from this phase**: `handleScrollWheel` adjusts `scrollYPixels` and triggers an on-demand re-render. P5 adds *only* spring/momentum/sub-pixel animation on top. You can scroll scrollback in every Metal phase.

**Rollback.** `HALITE_METAL` off / default `.legacyText` → legacy unaffected. **Exception:** the shared `cellMetrics` provider is live for both backends (must-fix #5 guard) — if it regresses sizing, that is git-revert, not toggle-flip. Scrutinize it for byte-identical cols/rows against legacy.

---

## Phase 2 — Full color + attribute fidelity

**Goal.** Every static visual attribute matches legacy pixel-for-pixel.

**Files.**
- NEW `MetalRender/ColorResolver.swift` — ports `HaliteTheme.nsColor`/`paletteColor` + `CellAttrs.resolvedColors` (`Cell.swift:45`): default→theme, palette 0-15→ANSI, 16-231→6×6×6 cube, 232-255→grayscale ramp, `.rgb`→absolute sRGB, inverse swap. Dynamic system colors (selection/find/orange/yellow/blue) resolved per-`NSAppearance`.
- EDIT `InstanceBuilder.swift` — bg priority chain (selection > activeFind > find > cellBg, one `BgInstance`/cell), fg asymmetry (selection keeps fg; find forces black; active-find orange/black; find yellow/black), hover-blue-last (fg override + blue underline, unconditional), wide/CJK (lead-cell glyph at natural width, left-aligned, continuation cell skipped for glyph but gets 2×-wide `BgInstance`).
- EDIT `GlyphRasterizer.swift` — bold CTFont slot (weight only, no ANSI brightening); **italic stays dead** (SGR 3 parsed, never drawn). `CTFontCreateForString` cascade via `FontCascade` (delete manual CJK span-split).
- NEW `Shaders.metal` overlay pass + `OverlayInstance` — SGR underline, strikethrough, hyperlink (OSC-8) underline fg α0.5, Cmd-hover blue underline.

**Deliverable.** Selection, find (active/inactive), hover, 256-color, true-color, bold, CJK/wide, underlines, dynamic system colors all render correctly in Metal.

**Verify.** *Dogfood:* live A/B against legacy on a colored TUI (`htop`, `ls --color`, a 256-color test script), CJK text, a selection drag, a find with multiple matches, Cmd-hover a URL, toggle dark/light appearance (colors re-resolve). *Unit (high value):* `ColorResolver` exhaustive — every palette index 0-255, the cube/grayscale formulas, `.rgb` passthrough, inverse swap, fg-asymmetry rules. `InstanceBuilder` bg-priority chain against a crafted `Grid` snapshot.

**Rollback.** Toggle / env — legacy untouched.

---

## Phase 3 — Smooth scroll + anchoring

**Goal.** Replace non-animated scalar scroll with sub-pixel spring/momentum, and reproduce every emergent NSScrollView behavior. (Sequenced before cursor-blink/IME-visual polish because scroll is the larger structural piece and the §5.2 performance target.)

**Files.**
- NEW `MetalRender/ScrollModel.swift` — scalar `scrollYPixels`; integer/fractional split (`scrollInt` selects scrollback rows; `scrollFrac` slides the viewport sub-cell + 1 overdraw row + scissor); critically-damped spring; momentum via macOS `phase`/`momentumPhase` (**integrate, don't simulate**); rubber-band at edges.
- NEW `MetalRender/AnimationLink.swift` — **transient** display link (macOS 14+ `NSView.displayLink`; macOS 13 `CVDisplayLink` hopping to main), started on animation begin, invalidated the instant the spring settles or the surface is occluded/miniaturized/off-window. `renderScrollOnly(scrollYPixels:)` rotates the ring slot and writes only the uniform — **never re-reads `session.grid`**.
- EDIT `MetalTerminalBackend.swift` — `renderScrollOnly` path.
- EDIT `HaliteTerminalView.swift` — port emergent behaviors: `followingBottom` (`:131`, updated only on user scroll intent), alt-screen/sync-output grid-top anchor (`followTargetY :843`), scrollback-eviction anchor (`scrollbackPushCount − scrollback.count`), 0.18s snap-to-cursor on input with the `isSnappingToCursor` guard (`:861`), alt-screen transition re-engages follow.

**Deliverable.** Trackpad sub-pixel scroll, momentum, rubber-band, follow-bottom, TUI grid-top anchoring (Claude Code / Ink), snap-to-cursor on input — matching or exceeding legacy.

**Verify.** *Dogfood:* trackpad scroll feel vs legacy; momentum and rubber-band; run Claude Code / a long-output TUI and confirm new content stays visible (grid-top anchor); scroll up, let scrollback evict, confirm viewed lines stay put; type while scrolled up → snaps to cursor smoothly (echo doesn't teleport). **Idle: 0% GPU, no link running** (verify in Activity Monitor / Instruments). Typing latency unregressed. *Unit:* spring step convergence (settles within tolerance, monotonic), int/frac split arithmetic. *Dogfood-only:* scroll feel, momentum desync, latency under Instruments Metal System Trace.

**Rollback.** Toggle / env — legacy NSScrollView path intact.

---

## Phase 4 — Cursor shapes, blink, IME preedit visual

**Goal.** The remaining dynamic overlays. (Coordinate correctness already shipped in Phase 1; this is the *visual* layer.)

**Files.**
- EDIT `Shaders.metal` / `OverlayInstance` — bar cursor (left strip `max(1.5, cellW*0.15)`), underline cursor (bottom strip `max(1.5, cellH*0.1)`), wide→2×. Suppressed when invisible/block/IME-composing/blink-off/scrolled-out.
- EDIT `InstanceBuilder.swift` — cursor blink (0.53s, default off, `resetBlinkPhase` on keystroke forces visible, driven by the existing `blinkKey` dirty source — no reshape); **no focus-dependent/hollow cursor** (`isActive` only sets `needsDisplay`).
- EDIT `InstanceBuilder.swift` — IME preedit overlay (port `appendCursorRowWithMarkedText :1860`): renders **even when DECTCEM hid the cursor** (so preedit shows in vim/Claude Code); block + bar/underline cursors suppressed during compose; styled by `config.imeStyle`. **Column advance uses `markedText.count`** — this reproduces the known under-count bug deliberately; it goes on the known-divergence list and is *not* an A/B regression. The wcwidth-correct fix is a separate, reviewable change.

**Deliverable.** All `DECSCUSR` cursor shapes, blink, and the IME preedit wash/underline render in Metal.

**Verify.** *Dogfood:* cycle cursor shapes (`printf '\e[%d q'`), confirm blink timing and suppress-while-typing; compose Korean/Japanese in vim and Claude Code — preedit shows even where the app hid the cursor, block cursor suppressed during compose; confirm selection/find/hover don't freeze during compose. *Unit:* blink-phase state machine; cursor-suppression predicate (the gate combining block/IME/blink/scrolled-out). *Dogfood-only:* IME visual parity.

**Rollback.** Toggle / env.

---

## Phase 5 — Color emoji + atlas growth + optional ligatures

**Goal.** The remaining glyph cases and the atlas robustness the basic Phase-1 atlas deferred.

**Files.**
- NEW color atlas page (`GlyphAtlas.swift` BGRA page), color-glyph detection (`.traitColorGlyphs` / `sbix`/`COLR`/`CBDT` table presence), `glyph_color_fragment` (samples RGBA, ignores fg).
- EDIT `GlyphAtlas.swift` — grow-on-full: allocate 2× (cap 4096²), re-rasterize the live working set from the key map (never silently drop a glyph). LRU eviction deferred unless a real session blows the cap.
- NEW `MetalRender/LineShaper.swift` (optional) — CTLine/CTRun ligature path + byte→col map, **config-gated, default OFF**, pixel-diff-gated when enabled.

**Deliverable.** Apple Color Emoji renders; long CJK sessions never drop glyphs; ligatures align to cells when explicitly enabled.

**Verify.** *Dogfood:* emoji in prompt/output; a long CJK session (`find / -name '*.txt'` style flood with CJK filenames) without missing glyphs; if ligatures enabled, Fira Code in an editor pixel-diffed against legacy. *Unit:* grow-on-full re-rasterizes the full working set (key map size preserved across grow); color-glyph detection classifier. *Dogfood-only:* emoji rendering, ligature alignment.

**Rollback.** Toggle / env.

---

## Phase 6 — Parity gate: make Metal default, retire legacy

**Goal — for maintainer decision.** Flip the default to `.metal` and delete the legacy path so it can't bitrot.

**Exit criteria (all must hold):** visual parity confirmed across the dogfood matrix — shell, vim, Claude Code/Ink TUI, CJK, emoji, IME — **except the known-divergence list** (the `markedText.count` IME advance); typing latency within ±1 frame of legacy (Instruments Metal System Trace); idle 0% GPU.

**Files.** EDIT `MetalRenderConfig.swift` (default `.metal`); DELETE `LegacyTextBackend.swift` + the toggle + the internal `NSScrollView`/`NSTextView` plumbing. The `TerminalRenderBackend` protocol **stays** as the future seam.

**Recommendation:** delete the legacy backend (anti-bitrot — a second live path rots fast). The alternative is keeping it as a permanent fallback behind a hidden flag; not recommended given the dual-maintenance cost, but it's your call.

**Verify.** Default `swift run halite` is Metal; full dogfood matrix; `LegacyTextBackend`/NSScrollView symbols gone; public API surface unchanged (host `halite.app` builds and runs against the byte-stable symbols).

**Rollback.** This is the one phase the toggle can't cover (it's deleted). Rollback = `git revert` the deletion. Keep P5→P6 as separate commits so revert is clean.

---

## Explicitly out of scope (future seam, nothing built)

Image/sixel/Kitty pass, offscreen-scene + post-fx blit, particles, CRT, procedural box-drawing-as-pass. **Grep-confirmed this session:** `VTParser`/`Grid`/`Cell` have **zero** sixel/Kitty/image/graphics/DCS data source — an image pass would have nothing to draw. The 4-pass structure and `TerminalRenderBackend` protocol leave room (a 5th image pass + an offscreen retarget slot), but nothing is built until a separate architecture doc adds the data source. "Reproduce current visuals exactly" forbids adding effects the placeholder lacks.

---

## Risk register

| # | Risk | Phase | Mitigation |
|---|---|---|---|
| 1 | **Library-target shader load fails** — `.module` bundle path unproven (currently used only in the executable target) | 1 | First thing P1 validates; embedded-source `makeLibrary(source:)` fallback ready; decide before P2. |
| 2 | **Coordinate flip bug** → IME candidate window at screen top (must-fix A) | 1 | `isFlipped` localized to `MetalContentView`; inverse does `convert(from: host)` *before* the row formula; **CoordinateMap round-trip unit test** catches it for free; Korean/JP dogfood gate. |
| 3 | **Toggle flip resizes the PTY** (different metrics → SIGWINCH → reflow → A/B worthless) | 0–1 | Shared backend-independent `cellMetrics` (`measuredLineHeight("M\nM\nM"/3)`); both backends report identical cols/rows; zoom stays pure-visual. **Shared refactor — git-revert, not toggle, on regression.** |
| 4 | **Baseline mis-derivation** (highest pixel-divergence risk) | 1 | Concrete formula `round((cellH−(ascent+descent))/2)+ascent` + per-font calibration offset pixel-diffed via the live toggle on a running terminal. |
| 5 | **Uniforms buffer race** on scroll ticks | 3 | Ring-buffer `Uniforms` in the same `DispatchSemaphore(3)` as instances; each tick rotates to a fresh slot. |
| 6 | **Off-main display-link races the main-thread parser** | 3 | Everything on main; transient link re-reads the pre-built buffer (uniform-only), never `session.grid`; `gridLock` is an explicit non-goal. |
| 7 | **6-part dirty key under-triggers** (selection/IME/find/hover/blink silently freeze) | 0 | Key + `scheduleRender` + sync gate kept verbatim; only `renderNow`'s tail branches; `RenderState` snapshot mirrors all six. |
| 8 | **Sync-output torn frames** return | 0 | `inSyncOutputMode` gate + 150ms safety flush stay above the backend call; both backends inherit it. |
| 9 | **Phase-0 shared refactor regresses legacy** (toggle can't protect it) | 0 | Pixel-diff before/after; line-by-line geometry-routing review; byte-identical scrutiny. |
| 10 | **Typing latency regression** | all | Per-keystroke = atlas-cached lookup + instance write (less work than `setAttributedString`+`ensureLayout`); no typing display link; verified under Instruments at P3/P6. |
| 11 | **Scope creep** (porting effects/images with no data source) | all | Draw directly into the drawable; no offscreen scene/post-fx/image pass; grep-confirmed no data source. |
| 12 | **Legacy bitrot / dual-maintenance** | 6 | Short A/B-validated phases; named P6 with explicit parity exit that *deletes* legacy. |

**Unit-testable** (worth writing): CoordinateMap round-trip, `cellMetrics`/cols-rows math, `ShelfPacker` packing, baseline formula, `ColorResolver` (full palette/cube/grayscale/.rgb/inverse + fg-asymmetry), `InstanceBuilder` bg-priority against a `Grid` snapshot, spring convergence, blink/cursor-suppression predicates, atlas grow-on-full, color-glyph detection. **Dogfood-only:** pixel parity, IME candidate placement on screen, scroll feel/momentum, typing latency, emoji, ligature alignment.

---

**Recommended sequencing for approval:** P0 (seam, invisible) → **P1 (first Metal pixels: bg + ASCII + IME cursor-rect — 3 of 4 unknowns proven)** → P2 (color/attr fidelity) → P3 (smooth scroll) → P4 (cursor/blink/IME visual) → P5 (emoji/atlas-growth/ligatures) → **P6 (parity gate, delete legacy)**. Two open decisions for you: **(a)** fold vs. split bg+text in P1 (recommend fold — proves the risky surfaces immediately); **(b)** delete vs. permanently keep the legacy backend at P6 (recommend delete — anti-bitrot).

---

# SYNTHESIZED ARCHITECTURE (detail)

Confirmed: zero image/sixel/Kitty/DCS data source in VTParser/Grid/Cell — deferring the image pass is bulletproof (nothing would populate it). And `Bundle.module` is only used in the executable target today, not the library — confirming the `makeDefaultLibrary(bundle: .module)` P1 build gate is genuinely unproven for the `HaliteTerminal` library and must be validated. I have everything. Writing the synthesis now.

---

# Halite-Swift Metal Renderer — Definitive Architecture

**Spine: incremental-seam** (panel winner, 53). Grafted with **ghostty-style's lean 4-pass altitude** ("reproduce the *current* placeholder, defer effects the placeholder lacks") and **faithful-port's parity catalog + explicit baseline formula**. The differentiation that wins is *structural*: a backend protocol behind a byte-stable public API, a live runtime toggle that doubles as an A/B pixel-diff harness, shared backend-independent `cellMetrics`, and a named final phase that retires the legacy path. The renderer guts are the leaner rivals' guts.

All claims below are verified against the live tree (line numbers cited are real: 6-part key at `HaliteTerminalView.swift:1543-1566`, `measuredLineHeight` at `:400-409`, `convertEventToCell` at `:974-985`, `firstRect` at `:1474-1496`, block-cursor inverse at `:1822-1823`, PTYHost main-hop at `PTYHost.swift:173`, NSScrollView scroll mechanism at `:356/:370/:391/:395`, `gridChanged` PassthroughSubject at `HaliteSession.swift:33`). Grep confirmed **zero** sixel/Kitty/image/DCS data source in `VTParser/Grid/Cell`, and `Bundle.module` is used today only in the executable target — both facts shape decisions below.

---

## 0. Must-fix → resolution map (the graded core)

Every must-fix the panel raised across all three designs, and where it is resolved:

| # | Must-fix (source) | Resolution | Section |
|---|---|---|---|
| A | **Coordinate symmetry bug** (incr #1): inverse `cell(at:)` applied the row formula to *unflipped host* coords | Inverse path does `contentView.convert(point, from: host)` **first** into the flipped MetalContentView, *then* `row = floor((y + scrollYPixels − inset)/cellH)`. Host stays unflipped; flip localized to `MetalContentView`. Forward `firstRect` already symmetric. | §9.4 |
| B | **Scroll-seam honesty** (incr #2): legacy NSScrollView has no native `scrollYPixels` | Define the *thin* legacy adapter explicitly (getter = `clipView.bounds.origin.y`; `setScrollY` = `scroll(to:)`+`reflectScrolledClipView`; wheel = native NSScrollView momentum). **Concede**: spring/sub-pixel/rubber-band *animation* is Metal-only, not exercised by legacy. "P0 proves the seam" is scoped to render + cell-geometry + scalar position, NOT animation. | §2.4, §7.5 |
| C | **Library-target shader load** (incr #3): `.process()` → module bundle, not main | P1 build gate: `device.makeDefaultLibrary(bundle: .module)`, embedded-source `makeLibrary(source:)` fallback ready. Verified `Bundle.module` is currently unused by the library target → genuinely unproven, must be validated before P2. | §1, §6.5 |
| D | **markedText.count IME advance** (incr #4 / ghostty / faithful): reproduces a known under-count bug | A/B pass criterion is "matches legacy **except the known-divergence list**." The known-divergence list is a first-class artifact; the later wcwidth fix is not an A/B regression. | §8.7, §11 |
| E | **Concrete baseline formula** (ghostty #2): "cellH−descent-ish, tuned" is hand-wavy | Adopt faithful §9 verbatim as the analytical start: `baseline = round((cellH − (ascent+descent))/2) + ascent`; `cellOrigin.y = rowTop + (baseline − bearingY)`, `cellH` = empirical `measuredLineHeight`. Then **gate on pixel-diff with a calibration offset** — and the live toggle *is* the pixel-diff tool. | §5.6, §9.5 |
| F | **Uniforms buffer race** (ghostty #3): `renderScrollOnly()` writes `scrollYPixels` every tick into a shared uniform buffer | Ring-buffer the Uniforms buffer into the **same** `DispatchSemaphore(3)` as the instance buffers. Per-tick uniform write never touches a buffer the GPU is reading. | §6.4 |
| G | **Honest phasing** (ghostty #1): "M1 replaces the placeholder" is false | No early phase claims placeholder removal. The parity gate that deletes legacy is the **named final phase P8**, after overlays + scroll + IME-candidate placement. | §10 |
| H | **Defer images/effects** (faithful #1): VTParser/Grid/Cell have no image data source (grep-confirmed) | Image/sixel/Kitty pass, particles, post-fx, CRT, box-drawing-as-pass: **out of scope**. Mentioned only as a future seam. The protocol leaves room; nothing is built. | §6.1, §12 |
| I | **Ligatures default OFF** (faithful #2): "default-on byte-identical" unverified | Default OFF (matches both rivals + the recipe). ASCII fast path is the default. Ligatures behind a config flag, pixel-diff-gated when enabled. | §4.2, §8.3 |

The spine **already** resolves four other rival must-fixes for free, by structure, not by extra work:
- ghostty must-fix #4 (fallback/comparison oracle) → the runtime toggle.
- ghostty must-fix #5 (shared cellMetrics, no cutover SIGWINCH) → §3.3.
- faithful must-fix #3 (fallback survives to parity gate) → toggle lives through P8.
- faithful must-fix #4 (lead P0–P3, defer effects) → named-P8 structure + §12.

---

## 1. Module / file layout

All new files in `Sources/HaliteTerminal/` (the library consumed by both `cmux` and `halite.app`). `HaliteSurfaceView` stays where it is.

```
Sources/HaliteTerminal/
  HaliteTerminalView.swift        (EDIT) host; render/geometry calls go through `backend`
  RenderBackend.swift             (NEW)  TerminalRenderBackend protocol + shared value types
  LegacyTextBackend.swift         (NEW)  wraps current NSScrollView+NSTextView path; conforms; deleted at P8
  MetalRenderConfig.swift         (NEW)  toggle source (Debug menu > env > UserDefaults), thickening knob
  MetalRender/
    MetalDevice.swift             (NEW)  shared MTLDevice/MTLCommandQueue, pipeline-state factory,
                                  //      library load (.module bundle; source fallback), feature probe
    MetalTerminalBackend.swift    (NEW)  owns CAMetalLayer (via MetalContentView), ring buffers + semaphore,
                                  //      pipelines, encodes 4 passes, present; conforms to protocol
    MetalContentView.swift        (NEW)  NSView, isFlipped=true, makeBackingLayer→CAMetalLayer
    GlyphAtlas.swift              (NEW)  two pages (R8 mask, BGRA color), ShelfPacker, key map, grow-on-full
    GlyphRasterizer.swift         (NEW)  CTFontDrawGlyphs → CGBitmapContext → bytes; color-glyph detection
    LineShaper.swift              (NEW)  ASCII fast path + CTLine/CTRun shaped path + LRU; byte→col map
    InstanceBuilder.swift         (NEW)  grid+RenderState → Bg/Glyph/Overlay instance arrays.
                                  //      THE hot path. Every visual-fidelity rule lives here. No Metal types.
    ColorResolver.swift           (NEW)  CellAttrs.resolvedColors → packed RGBA8; highlight priority chain;
                                  //      dynamic NSColor resolved per-NSAppearance
    ScrollModel.swift             (NEW)  scalar scrollYPixels; spring/momentum/rubber-band; follow/anchor/snap
    AnimationLink.swift           (NEW)  transient CADisplayLink (14+) / CVDisplayLink (13); start/stop on demand
    CoordinateMap.swift           (NEW)  cell↔point↔screen; firstRect; cell(at:) — symmetric flip handling
    RenderTypes.swift             (NEW)  repr-C instance structs + Uniforms (Swift mirror; static-asserts vs .metal)
    Shaders.metal                 (NEW)  4 vertex + 4 fragment (bg, glyph-mask, glyph-color, overlay)
```

`Package.swift` (anticipated by the in-file comment `// 추후 Shaders.metal 추가 시 resources에 .process()로 선언`):

```swift
.target(
    name: "HaliteTerminal",
    path: "Sources/HaliteTerminal",
    resources: [.process("MetalRender/Shaders.metal")]
)
```

**Verified pitfall (P1 build gate, must-fix C):** `HaliteTerminal` is a **library** target. `.process()` compiles `Shaders.metal` into the *module* bundle. The backend must load with `device.makeDefaultLibrary(bundle: .module)` — **not** `makeDefaultLibrary()` (which searches the main app bundle, nil for a library). `Bundle.module` is currently used **only** in the executable target (`AppBundleTrampoline.swift:90`), so this path is *unproven* for the library and is the first thing P1 validates. Documented fallback: embed shader source as a Swift string constant and `device.makeLibrary(source:options:)`. **Decide in P1 before P2 builds on it.**

**Responsibility split:** `InstanceBuilder` is the only allocation-sensitive code and touches no Metal type → unit-testable against a `Grid` snapshot with no GPU. `GlyphAtlas`/`GlyphRasterizer` are the only CoreText-rasterization callers. `LineShaper` is the only CTLine caller. Each hot-path-sensitive surface is isolated and individually profileable.

---

## 2. The seam: `TerminalRenderBackend` (extracted in P0, before any Metal)

The architectural keystone. Extract the protocol **first**, make the **existing NSTextView path conform**, ship with the toggle defaulting to legacy. This exercises the seam so that when Metal lands, no input/IME/mouse geometry can secretly reach `textView.convert` — it *has* to route through the protocol or it won't compile.

```swift
protocol TerminalRenderBackend: AnyObject {
    /// The view the host installs as a subview (CAMetalLayer host, or the NSScrollView).
    var contentView: NSView { get }

    // Lifecycle
    func install(in host: NSView)
    func updateConfig(_ config: HaliteConfig)
    func backingPropertiesChanged(scale: CGFloat)
    func appearanceChanged(_ appearance: NSAppearance)

    // The single draw entrypoint — called from renderNow() AFTER the 6-part dedupe decides to draw.
    func render(grid: Grid, theme: HaliteTheme, state: RenderState)

    // Geometry (the input-path seam)
    func cell(at pointInHost: CGPoint) -> (row: Int, col: Int)
    func screenRect(forCell row: Int, col: Int, in host: NSView) -> CGRect

    // Scroll — SCALAR position only (see §2.4 for the honest scope split)
    var scrollYPixels: CGFloat { get }
    func setScrollY(_ y: CGFloat, animated: Bool)
    func handleScrollWheel(_ event: NSEvent)
    var isFollowingBottom: Bool { get set }
    func contentHeight() -> CGFloat
}
```

`RenderState` is the immutable snapshot the host computes **once** and hands to whichever backend is active — it carries exactly what the 6-part dirty key tracks:

```swift
struct RenderState {
    var markedText: String
    var markedTextStyle: IMEStyle
    var selection: NormalizedSelection?
    var findMatchesByRow: [Int: [Range<Int>]]
    var activeFindRange: (row: Int, cols: Range<Int>)?
    var hoveredURLRange: (row: Int, cols: Range<Int>)?
    var blinkVisible: Bool
    var cursorBlinkEnabled: Bool
    // cursor row/col/shape/visible come from `grid` directly
}
```

### 2.1 What `HaliteSurfaceView` keeps (byte-stable — verified)

`public final class HaliteSurfaceView: NSView, NSTextInputClient` (`:45`), `public init(session:)` (`:147`), all `@objc public` selectors, and the entire `NSTextInputClient` conformance stay **byte-identical**. The host keeps: `keyDown`/`doCommand`, the full `NSTextInputClient` (insertText/setMarkedText/unmarkText, Hangul BS-cancel, IME warmup), `mouseDown/Dragged/Up`, scroll-wheel mouse-reporting (button 64/65), Cmd-click/hover URL handling, `updateTrackingAreas`, `menu(for:)`, the `FindOverlayView` subview, and the bell-flash CALayer. The only stored-prop change: the internal `scrollView`/`textView`/`cursorLayer` move *behind* the backend (legacy keeps them; metal replaces them).

### 2.2 `renderNow()` after the change — trigger untouched, only the tail branches

```swift
private func renderNow() {
    // ... EXISTING 6-part composite key check (verified :1543-1566):
    //   grid.version + markedText + selKey + findKey + hoverKey + blinkKey — VERBATIM ...
    guard shouldRender else { return }
    let state = buildRenderState()                                   // view-local state → snapshot
    backend.render(grid: session.grid, theme: theme, state: state)   // <-- only new line
}
```

The sync-output gate (`scheduleRender` → `armSyncFlush`, the `inSyncOutputMode` skip + 150 ms safety flush, verified `:1506/:1517/:1526`) lives in `scheduleRender`, **above** the backend call → both backends inherit it identically. Torn-frame protection is provably preserved because it is the same gate. **The 6-part key is never touched** — this neutralizes the contract's #1 break-risk by construction.

### 2.3 Toggle = internal + live A/B harness

```swift
enum RenderBackendKind { case legacyText, metal }
// resolution: live Debug override > env HALITE_METAL=1 > UserDefaults "HaliteMetalRenderer" > .legacyText
```

`switchBackend(to:)` tears down the old `contentView`, installs the new one, copies `scrollYPixels`, forces a full render. Because `HaliteSession`/`Grid` are view-independent (verified: `gridChanged` PassthroughSubject `:33`, rendering reads `grid` not the output path), **this works on a live terminal** — flip backends mid-session and pixel-compare against legacy. No rival can do this. Default ships `.legacyText` until parity is proven at P8.

### 2.4 Scroll-seam honesty (must-fix B) — stated, not hidden

The protocol's scroll members are shaped for the Metal destination (a scalar `scrollYPixels`). The legacy NSScrollView path has **no** native scalar — it drives everything through `clipView.bounds.origin.y` + `scroll(to:)` + `reflectScrolledClipView` + `didLiveScrollNotification` (verified `:356/:370/:391/:395/:1705`). So `LegacyTextBackend` implements the scalar members as a **thin adapter** (§7.5), and:

> **Scope claim, precisely:** "P0 proves the seam before Metal exists" holds for **render + cell-geometry + scalar scroll position**. It does **not** claim the legacy backend exercises spring/sub-pixel/rubber-band *animation* — that is Metal-only (`setScrollY(animated:)` on legacy just calls `NSClipView.animator().setBoundsOrigin`, the existing `:870` behavior). The compile-time guarantee covers position and geometry; smooth-scroll animation is validated only when the Metal backend lands at P5.

---

## 3. CAMetalLayer integration into `HaliteSurfaceView`

### 3.1 The Metal layer lives *inside* the backend's contentView

A Metal swap **cannot change the host's class** (cmux/halite.app consumers + AutoLayout anchors at `PaneTree.swift:26`), and SMOOTH-SCROLL forbids `CAMetalLayer` inside `NSScrollView`. So:

- `HaliteSurfaceView : NSView` — **unchanged, unflipped**. Honors host AutoLayout anchors, hosts `FindOverlayView` subview + bell-flash sublayer.
- `LegacyTextBackend.contentView` = the current `NSScrollView`.
- `MetalTerminalBackend.contentView` = a `MetalContentView` (layer-backed by `CAMetalLayer`), pinned to the host with the same four AutoLayout anchors.

```swift
final class MetalContentView: NSView {
    let metalLayer = CAMetalLayer()
    override var isFlipped: Bool { true }            // y-down grid math, LOCALIZED here (not the host)
    override func makeBackingLayer() -> CALayer { metalLayer }
    override var wantsUpdateLayer: Bool { true }     // never use draw(_:)
    // init: device, .bgra8Unorm_srgb, framebufferOnly=true, isOpaque=true,
    //   maximumDrawableCount=3, allowsNextDrawableTimeout=true,
    //   presentsWithTransaction=false, needsDisplayOnBoundsChange=false
}
```

`isFlipped=true` is **localized to MetalContentView**, NOT the host (must-fix A). Flipping the host would ripple through every other geometry path; AppKit's `convert(_:from:/to:)` bridges the flip difference between host and contentView automatically.

### 3.2 Shared, backend-independent `cellMetrics` (must-fix #5 / SIGWINCH guard)

The subtle trap: if Metal's `cellW`/`cellH` differ from legacy's, flipping the toggle changes `floor(usable/cell)` → fires `session.resize` → SIGWINCH → the program reflows → A/B is worthless and dogfooding is disruptive.

**Mitigation:** `cellMetrics` is computed **once, backend-independent**, on the host (or a shared `CellMetricsProvider`), using the *exact* current formulas (verified `:429-433`):
- `cellW = ("M" as NSString).size(withAttributes:[.font: font]).width`, min 1.
- `cellH = measuredLineHeight(font)` — lay out `"M\nM\nM"` in a throwaway `NSLayoutManager`, return `usedRect.height/3` (verified `:400-409`). **Not** `ascent+descent+leading`.

Both backends *consume* these metrics for grid geometry; the Metal backend derives its glyph baseline *inside* the `cellH` box (§5.6). Both report identical `(cols, rows)` → flipping the toggle never fires SIGWINCH.

### 3.3 Forwarded lifecycle hooks

- `viewDidChangeBackingProperties()` → `backend.backingPropertiesChanged(scale:)` (Retina rescale, re-rasterize atlas, re-measure metrics).
- `viewDidChangeEffectiveAppearance()` → `backend.appearanceChanged(_:)` (re-resolve dynamic system colors).
- `layout()` / `viewDidEndLiveResize()` → existing `reportSizeIfChanged()` (unchanged logic, §9) + `metalLayer.drawableSize` update.

---

## 4. Draw-trigger model (latency-safe)

Settled convergence across all three designs (stated, not re-litigated): **on-demand for typing, transient link for scroll animation only.** cmux's no-app-display-link rule is honored; SMOOTH-SCROLL's always-on `CVDisplayLink`-on-dirty loop is rejected (it adds a frame of pre-encode latency, a cross-thread hop, and idle wakeups).

### 4.1 Two triggers

| Trigger | Mechanism | Latency property |
|---|---|---|
| Typing / PTY output / selection drag / find / hover / blink phase / IME compose | **On-demand**, existing coalesced `scheduleRender()` → `renderNow()` → `backend.render(...)`, **encode + present in the same runloop turn** | Keystroke echo encoded on the `keyDown` turn — zero pre-encode wait, no hop, zero idle wakeups |
| Smooth scroll / momentum / rubber-band / snap-to-cursor | **Transient display link**, started on animation begin, invalidated the instant the spring settles | One frame of scroll latency is invisible; typing never touches the link |

### 4.2 The transient link, deployment-floor-aware (`.macOS(.v13)`)

`NSView.displayLink(target:selector:)` (clean main-thread `CADisplayLink`) is macOS 14+. The floor is v13.

```swift
@objc private func animationTick(_ link: CADisplayLink) {        // main thread on 14+
    let settled = scroll.advance(to: link.targetTimestamp)       // integrate spring vs vsync timestamp
    backend.renderScrollOnly(scrollYPixels: scroll.current)      // uniform-only re-encode; NO grid re-read
    if settled { stopAnimationLink() }
}
```

- **macOS 14+:** `view.displayLink(target:self, selector:)`, `preferredFrameRateRange = .init(min:60,max:120,preferred:120)`. Main-thread, no hop.
- **macOS 13:** `CVDisplayLink`, started **only while animating**, callback hops to main via `DispatchQueue.main.async`. Hop acceptable here — typing never goes through this link. *Recommendation: raise the floor to v14 for the clean path; the v13 fallback is fully specified so neither blocks.*

**Stop conditions:** spring settled, `window.occlusionState` loses `.visible`, miniaturize, view leaves window, window close. (A settling spring otherwise spins the GPU on an invisible surface.)

### 4.3 `renderScrollOnly` never re-reads the grid

During a scroll animation only `Uniforms.scrollYPixels` changes → uniform-only re-encode, **zero instance rebuild**. A full instance rebuild happens only when (a) `gridChanged` fires (6-part key changes), or (b) `floor(scrollYPixels/cellH)` crosses a row boundary (new scrollback rows enter the visible window). The link callback runs on main (v14) or hops to main (v13) — **no off-main grid read, no race introduced.**

### 4.4 Concurrency seam — everything on main, no gridLock (verified safe)

`PTYHost` hops every chunk to main (`PTYHost.swift:173`) before `parser.feed` → grid mutation. So parse + all grid mutations run on **main**, and `Grid` has zero internal locking — race-free *only* because read and mutate are both serialized on main. The transient link only re-reads the **already-built instance buffer** (uniform-only); it never reads `session.grid` off-main. Adding `OSAllocatedUnfairLock gridLock` / double-buffering is an explicit **non-goal** for this design — it would introduce a race that does not exist today. (The integration §0 crux: the on-demand main-thread Metal path is strictly *less* per-keystroke work than today's `setAttributedString` + `ensureLayout`, so no concurrency change is needed to beat current latency.)

---

## 5. Glyph atlas (CoreText)

### 5.1 Two pages, two formats

| Page | Format | Source | Sampling |
|---|---|---|---|
| **Mask** (text) | `MTLPixelFormatR8Unorm` | `CTFontDrawGlyphs` into `CGContext(CGColorSpaceCreateDeviceGray(), alphaOnly)`, AA on | `glyph_mask_fragment`: `.r` × fgColor (grayscale coverage, premultiplied) |
| **Color** (emoji/COLR/sbix) | `MTLPixelFormatBGRA8Unorm` | `CTFontDrawGlyphs` into sRGB premultiplied `CGBitmapContext` | `glyph_color_fragment`: `.rgba`, **ignores fg** |

Start **2048×2048 at backing scale** (Retina doubles glyph footprints vs the Rust reference's 1024²). One linear-filtered, ClampToEdge `MTLSamplerState` shared. 1px transparent pad per glyph (linear-filter bleed guard).

**Grayscale coverage only — no subpixel/LCD AA.** Apple removed system subpixel smoothing in 10.14; grayscale is *more* native than LCD and matches both the current NSTextView output and the Rust R8 path.

### 5.2 Key by glyph, not codepoint

```swift
struct GlyphKey: Hashable {
    var glyphID: CGGlyph        // post-shaping — ligatures break 1:1 codepoint mapping
    var fontHash: Int           // CTFont identity: family + size-bits + traits (bold)
    var subpixelBucket: UInt8   // fractional-x bucket 0..<3 (0, 1/3, 2/3)
    // NO italic bit — italic is never drawn (§8). Only REGULAR/BOLD exist.
}
```

Size is in `fontHash` → zoomed grid glyphs and fixed-13pt chrome coexist. `subpixelBucket` (3 buckets) keeps text crisp when sub-pixel scroll/advance lands a glyph mid-pixel (without it, scrolled text shimmers).

### 5.3 Rasterization (`GlyphRasterizer`)

1. `CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &rects, 1)` → integer-ceil at `backingScaleFactor`, +1px bleed.
2. **Detect color:** `CTFontGetSymbolicTraits(font)` contains `.traitColorGlyphs`, **or** `CTFontCopyTable` presence of `sbix`/`COLR`/`CBDT` → route to color page.
3. Draw into a `CGBitmapContext` scaled by `backingScaleFactor`; `CTFontDrawGlyphs(font, &glyph, &pos, 1, ctx)`.
4. `texture.replaceRegion(_:mipmapLevel:withBytes:bytesPerRow:)` into the shelf slot (mask: `bytesPerRow = w`).
5. **Zero-rect sentinel** for unsupported codepoints / empty bitmaps → never retried.

**Never rasterize in the render loop.** Cache-miss rasterization happens during `InstanceBuilder.build` (itself coalesced); uploaded once, sampled forever.

### 5.4 Packing, growth, eviction

- **`ShelfPacker`** — skyline shelf packer; per-shelf x-cursor, new shelf when the row fills.
- **Grow-on-full:** when the packer can't fit, allocate a 2× texture (cap 4096²) and **re-rasterize the live working set** from the key map (a few hundred glyphs → rare and cheap). Never silently drops a glyph (the Rust reference's literal gap).
- **LRU eviction is deferred** — a 2048²→4096² page covers essentially all sessions including large CJK. Build it only if a real session blows the cap.
- **`reconfigure()`** on font/size/appearance change: clear both maps, reset packer, **zero the textures** (kills ghost edges from stale pixels), reuse the `CTFontDescriptor`/cascade.

### 5.5 Font cascade — keep the list, delete the hack

Reuse `FontCascade.fontWithNerdFallback(family:size:)` (Menlo 13 primary, Nerd Font for Powerline PUA, D2Coding/Apple SD Gothic Neo for Korean) for **metric consistency**. **Delete** any manual CJK span-split — `CTFontCreateForString` / CTLine cascading resolves mixed-script runs natively; the run's actual font comes from `CTRunGetFont`. The cascade list still matters (it determines *which* fallback CoreText picks via `kCTFontCascadeListAttribute`), but spans are never manually split.

### 5.6 Baseline formula (must-fix E) — concrete + pixel-diff-gated

`cellH` is the **empirical** `measuredLineHeight("M\nM\nM"/3)`, not a metric sum. A naively-derived Metal baseline shifts every glyph vertically vs the placeholder. Resolution:

**Analytical start (faithful §9 verbatim):**
```
ascent  = CTFontGetAscent(font);  descent = CTFontGetDescent(font)
baseline = round((cellH − (ascent + descent)) / 2) + ascent     // baseline from rowTop, content px
glyphInstance.cellOrigin.y = rowTop + (baseline − bearingY)      // bearingY from glyph bounding rect
```

**Then gate on pixel-diff with a calibration offset.** The single highest pixel-divergence risk gets the spine's unique tool: the **live toggle pixel-diffs Metal-baseline vs legacy on a running terminal**. If the analytical baseline lands off by N device px, store a per-font `baselineCalibration: CGFloat` adjustment derived from the diff. This is the synthesis's strongest single point — the A/B harness de-risks the exact thing that sank the rivals (who had no comparison oracle).

---

## 6. Render passes + instance layouts + shaders

### 6.1 Scope discipline — draw directly into the drawable, 4 passes

**No offscreen scene, no post-fx blit, no particles, no image/sixel/Kitty pass, no CRT, no procedural box-drawing pass.** The current NSTextView renderer has none of these, and grep confirmed **zero** image/DCS data source in `VTParser/Grid/Cell` — an image pass would have nothing to draw. "Reproduce current visuals exactly" forbids adding them. Offscreen-scene + effects is a **future seam only** (§12), gated behind a separate model/parser effort.

### 6.2 The four passes (back → front), one render pass to the drawable

| # | Pass | Pipeline | Blend | Instance | Absorbs |
|---|---|---|---|---|---|
| 0 | **Clear** | — | `loadAction=.clear`, clear = `theme.background` (effective default bg) | — | — |
| 1 | **Background** | `bg_v`/`bg_f` | **disabled** (opaque overwrite) | `BgInstance` | default/SGR bg, inverse, **selection bg**, **find/active-find bg**, **block-cursor inverse bg** |
| 2 | **Glyph (mask)** | `glyph_v`/`glyph_mask_f` | `.one`/`.oneMinusSourceAlpha` (premult) | `GlyphInstance` | all text incl. bold, wide/CJK, ligatures, block-cursor glyph (swapped fg) |
| 3 | **Glyph (color)** | `glyph_v`/`glyph_color_f` | `.one`/`.oneMinusSourceAlpha` | `GlyphInstance` (page=color) | emoji / color glyphs (fg ignored) |
| 4 | **Overlay** | `overlay_v`/`overlay_f` | `.sourceAlpha`/`.oneMinusSourceAlpha` | `OverlayInstance` | SGR underline, strikethrough, **bar/underline cursor**, **hyperlink underline + hover**, **IME preedit underline/wash** |

One `MTLCommandBuffer`, one drawable, four `drawPrimitives(.triangleStrip, vertexStart:0, vertexCount:4, instanceCount:n)` calls — vertexless (corner from `vertex_id`). (The Rust per-pane `queue.submit` workaround is irrelevant — halite-swift is one surface per view.)

### 6.3 Instance layouts (`RenderTypes.swift` ⇄ `Shaders.metal`, repr-C, static-asserted)

```swift
struct Uniforms {                  // SHARED by all passes; ring-buffered (see §6.4)
    var cellSizePx: SIMD2<Float>   // cellW, cellH in device px
    var gridOriginPx: SIMD2<Float> // inset (4,4)*scale; y includes scrollFrac sub-cell slide
    var viewportSizePx: SIMD2<Float>
    var scrollYPixels: Float       // the ONLY thing a scroll animation changes
    var thickening: Float          // gamma/weight fudge knob (§9.3)
}
struct BgInstance {                // 12 B — bg + highlight + block-cursor-inverse bg
    var cellXY: SIMD2<Float>       // col, row (content space, pre-scroll)
    var size:   SIMD2<Float>       // (1 or 2)*cellW, cellH  — wide cells span 2
    var color:  SIMD4<Float>       // premultiplied RGBA
}
struct GlyphInstance {             // mask + color share layout
    var cellOriginPx: SIMD2<Float> // lead-cell top-left, CONTENT px (pre-scroll); shader subtracts scrollY
    var size:    SIMD2<Float>      // glyph quad device px (natural width for wide — NOT 2×cellW; §8)
    var atlasUV0, atlasUV1: SIMD2<Float>
    var color:   SIMD4<Float>      // fg (ignored by color fragment)
    var flags:   UInt32            // bit0 colorPage, bit1 underlineOwner, …
}
struct OverlayInstance {           // underline/cursor/IME
    var cellXY:  SIMD2<Float>
    var rectMin, rectSize: SIMD2<Float>  // 0..1 cell-normalized
    var color:   SIMD4<Float>            // dynamic system color resolved per-appearance
}
```

`GlyphInstance.cellOriginPx` is in **content pixels (pre-scroll)**; the vertex shader does `pos.y -= scrollYPixels`. That is what makes scrolling a uniform-only update with zero rebuild. **Full instance-buffer rebuild every grid change** (no dirty-cell tracking — grids are tiny, ~200×100 ≈ a few MB, branch-free full rebuild beats maintaining an invalidation set).

### 6.4 Triple-buffer ring + semaphore — instances AND uniforms (must-fix F)

```swift
private let inFlight = DispatchSemaphore(value: 3)          // == maximumDrawableCount
private var ring = (0..<3).map { _ in FrameBuffers(device) } // {bg, glyph, overlay, UNIFORMS}
func render() {
    inFlight.wait()
    let buf = ring[nextIndex()]                            // GPU never reads this copy
    instanceBuilder.build(into: buf, grid: …, state: …)   // writes bg/glyph/overlay AND buf.uniforms
    guard let drawable = metalLayer.nextDrawable() else { inFlight.signal(); return }  // skip on nil
    let cmd = queue.makeCommandBuffer()!
    cmd.addCompletedHandler { [inFlight] _ in inFlight.signal() }
    encodeFourPasses(cmd, buf, drawable)
    cmd.present(drawable); cmd.commit()
}
func renderScrollOnly(scrollYPixels: Float) {              // animation-link path
    inFlight.wait()
    let buf = ring[nextIndex()]                            // ⚡ ROTATE — do not reuse prior buffer
    buf.copyInstances(from: lastBuilt)                     // reuse instances; grid unchanged
    buf.uniforms.scrollYPixels = scrollYPixels             // write into THIS ring slot's uniforms
    // ... acquire drawable, encode, present, signal ...
}
```

**The fix:** `renderScrollOnly` writes `scrollYPixels` every animation tick. If `Uniforms` were a single shared buffer, that write would race the GPU reading the prior frame's uniforms. So **`Uniforms` is ring-buffered in the same `FrameBuffers` slot, gated by the same `DispatchSemaphore(3)`**. Each tick rotates to a fresh slot, copies the (unchanged) instance arrays, and writes the new uniform — never touching a buffer the GPU is reading. `nextDrawable` is acquired late, presented promptly; `allowsNextDrawableTimeout=true`; skip the frame on nil (no busy-retry → no stutter).

### 6.5 Shaders (`Shaders.metal` — 4 vertex + 4 fragment)

| Function | Job | Notes |
|---|---|---|
| `bg_v`/`bg_f` | solid per-cell quad; `pos.y -= scrollY` | emit color as-is |
| `glyph_v` (shared mask+color) | quad at `cellOriginPx + corner*size`, atlas UV; `pos.y -= scrollY` | corner = `float2(vid & 1, vid >> 1)`, Y-flip via uniforms |
| `glyph_mask_f` | `coverage = mask.sample(uv).r; return float4(fg.rgb, fg.a)*coverage` | grayscale, premultiplied |
| `glyph_color_f` | `return color.sample(uv)` | premult RGBA, fg ignored |
| `overlay_v`/`overlay_f` | cell-normalized rect → device px quad; flat color | underline/cursor/IME |

All trivial. No compute, no depth, no MSAA, no post-fx. Loaded via `makeDefaultLibrary(bundle: .module)` (P1 gate, §1).

---

## 7. Mapping every current visual element

`InstanceBuilder` enforces these. The `appendRunGroup` NSAttributedString grouping is a pure optimization — the GPU resolves every visible non-continuation cell independently; **output is byte-identical** as long as per-cell resolution matches. Dynamic system colors are resolved per-`NSAppearance` in `ColorResolver` at build time and re-resolved on `viewDidChangeEffectiveAppearance` (KVO on `NSApp.effectiveAppearance` → force-rebuild).

| Element | Pass | Reproduction (verified against live code) |
|---|---|---|
| **Cell bg** | Background | `CellAttrs.resolvedColors(theme:)` (`Cell.swift:45`); `bg==nil` → clear color `theme.background` |
| **Glyph (normal)** | Glyph mask | grayscale coverage × resolved fg |
| **Bold** | Glyph mask | bold CTFont slot, **weight only**, no palette brightening |
| **Italic** | — | **never drawn** (SGR 3 parsed, ignored at draw). No italic font, no atlas slot. |
| **Wide / CJK** | Glyph + Bg | one `GlyphInstance` at lead-cell origin, `size.x = natural width` (**left-aligned, overflow uncapped**); **no glyph instance for the continuation cell** (`isContinuation`, verified `:770/:1744`). Continuation cell still gets its `BgInstance` (`size.x=2*cellW`) so selection/find bg covers both columns. `CTRunGetStringIndices` snaps to the lead column. |
| **Block cursor** | Bg + Glyph | **inverse-toggle the cell through the theme** (verified `:1822-1823` `inverseCell.attrs.inverse.toggle()`), **NOT a cursorColor quad**. Builder copies the cursor cell, toggles `inverse`, resolves → swapped `BgInstance` + re-emitted swapped-fg `GlyphInstance`. Double-toggle on already-inverse cancels. Gated `blockCursorActive = shape==.block && markedText.isEmpty && !blinkOff` (`:1609`); `?25l` hides via `blockCursorRow = cursorVisible ? cursorRow : -1` (`:1605`). |
| **Bar / underline cursor** | Overlay | `OverlayInstance` in `config.cursorColor`; underline = bottom strip `max(1.5, cellH*0.1)`, bar = left strip `max(1.5, cellW*0.15)`; wide → 2× width. Hidden when invisible/block/IME-composing/blink-off/scrolled-out. |
| **Cursor blink** | uniform flag | 0.53s toggle (default off); `resetBlinkPhase` on keystroke forces visible; `blinkKey` dirty source (no reshape). **No focus-dependent/hollow cursor** — `isActive` only sets `needsDisplay`, never read in the cursor path. |
| **Selection** | Background | bg = `NSColor.selectedTextBackgroundColor` (per-appearance), **fg unchanged** (asymmetry). |
| **Active find** | Background | bg = `systemOrange` α0.85, **fg forced black**. |
| **Find (inactive)** | Background | bg = `systemYellow` α0.6, **fg forced black**. |
| **Bg priority** | Background | strict chain **selection > activeFind > find > cellBg** — one `BgInstance` per cell, if/else picks one. |
| **Hover (Cmd-hover URL)** | Overlay + Glyph | applied **last, unconditionally**: fg override `systemBlue` + blue `.single` underline, bg untouched. Hovered+selected = selection bg + blue fg + blue underline. |
| **SGR underline** | Overlay | `.single`, color = resolved cell fg. |
| **Hyperlink (OSC-8)** | Overlay + Glyph | `.single` underline, color = fg α0.5. |
| **Dynamic system colors** | — | `selectedTextBackgroundColor`/`systemOrange/Yellow/Blue` resolved against `view.effectiveAppearance` via `NSColor.usingColorSpace(.sRGB)` inside `performAsCurrentDrawingAppearance`; re-resolved on appearance/accent change. Never baked into shaders. |
| **IME preedit** | Bg + Glyph + Overlay | `appendCursorRowWithMarkedText` port; renders **regardless of DECTCEM** (so preedit shows in Claude Code/vim). Block + bar/underline cursors suppressed during compose. Style by `config.imeStyle` (.underline/.thickUnderline/.background systemBlue α0.45/.both/.none). **Column advance uses `markedText.count`** (reproduces the known under-count — see must-fix D / §8.7). |
| **Bell flash** | sibling CALayer | full-bounds white CALayer α0.18, `zPosition=200`, 1→0 over 0.18s easeOut. **Unchanged AppKit sublayer** above the Metal layer. |
| **Find UI chrome** | AppKit subview | `FindOverlayView` stays `addSubview` (separate chrome). |

(The same mapping rows referenced in the §8 sub-sections below: §8.3 ligatures, §8.7 IME advance.)

---

## 8. Render-fidelity decisions (the quirks, reproduced deliberately)

### 8.1 Color resolution
`ColorResolver` ports `HaliteTheme.nsColor`/`paletteColor` + `CellAttrs.resolvedColors` exactly: `.default`→theme fg, palette 0-15→ANSI, 16-231→6×6×6 cube `[0,95,135,175,215,255]`, 232-255→`(n-232)*10+8`, `.rgb`→absolute sRGB (`srgbRed:`, theme-independent). **Inverse** swaps fg↔bg (theme.background as fg when bg was nil). Packed to device RGBA8 once per run, cached per `CellAttrs`.

### 8.2 Bold / italic
Bold = bold CTFont (or synthetic-bold matrix if the family lacks one), **weight only, no ANSI 0-7→8-15 brightening**. Italic stays **dead** — the atlas could carry a bit but `InstanceBuilder` never sets it; only REGULAR/BOLD slots populate.

### 8.3 Ligatures — default OFF (must-fix I)
Default: ASCII fast path `CTFontGetGlyphsForCharacters` (one codepoint → one glyph, no CTLine, skip the shape cache). Ligatures behind a config flag; when enabled, `LineShaper` CTLine path + `CTRunGetStringIndices` start-cell snap places the glyph at the start cell spanning `spannedCells * cellW`. **Default OFF matches both rivals + the recipe**; do not ship an unverified "default-on byte-identical" claim. When enabled, pixel-diff Menlo and Fira Code against legacy before shipping.

### 8.7 IME wide-composition advance — known divergence (must-fix D)
The current code advances columns by `markedText.count`, **not wcwidth** — wide composition under-counts and can overlap following cells (a latent bug). For byte-parity, **M-series reproduces `markedText.count`**. This goes on the **known-divergence list** (§11). The A/B pass criterion is "matches legacy **except the known-divergence list**," so the later wcwidth-correct fix is reviewable in isolation and is **not** flagged as an A/B regression.

---

## 9. Coordinate / Retina / colorspace / IME-cursor-rect

### 9.1 Flipping (localized)
`MetalContentView.isFlipped = true` → grid math y-down inside the content view. The host stays unflipped; AppKit `convert` bridges the difference.

### 9.2 Retina
`metalLayer.contentsScale = window.backingScaleFactor`; `metalLayer.drawableSize = bounds.size * backingScaleFactor` (**never** bounds). Rasterize glyphs at backing scale. `viewDidChangeBackingProperties` → recompute scale + drawableSize, re-rasterize atlas (`reconfigure`), re-measure metrics. **Viewport from `drawableSize` (device px); cols/rows from `bounds` (points)** — mixing them = off-by-2× geometry.

### 9.3 Colorspace + gamma-correct AA
Drawable `.bgra8Unorm_srgb` → GPU linearizes on read, blends grayscale coverage in **linear** space, re-encodes on write → gamma-correct AA (sRGB-space blending makes text too thin/heavy). `Uniforms.thickening` = per-terminal weight fudge knob (WezTerm-style), default off. sRGB correct for the default theme; P3 deferred. `.rgb` colors resolved absolute.

### 9.4 Coordinate symmetric pair (must-fix A — the one real bug)

Both directions verified against the live `convertEventToCell` (`:974-985`) and `firstRect` (`:1474-1496`), which currently rely on `textView.convert(...)` to enter the flipped content space.

**Forward (cell → screen, `firstRect` / IME candidate):**
```swift
func screenRect(forCell row: Int, col: Int, in host: NSView) -> CGRect {
    let xPts = inset + CGFloat(col) * cellW
    let yContent = inset + CGFloat(row) * cellH
    let yViewport = yContent - scrollYPixels                       // apply scalar scroll
    let rect = CGRect(x: xPts, y: yViewport, width: cellW, height: cellH)   // flipped contentView space
    let inHost   = contentView.convert(rect, to: host)            // contentView → host
    let inWindow = host.convert(inHost, to: nil)                  // host → window
    return host.window!.convertToScreen(inWindow)                // window → screen
}
```

**Inverse (point → cell, `cell(at:)`) — THE FIX:**
```swift
func cell(at pointInHost: CGPoint) -> (row: Int, col: Int) {
    let p = contentView.convert(pointInHost, from: host)         // ⚡ host → flipped contentView FIRST
    let row = max(0, Int(floor((p.y + scrollYPixels - inset) / cellH)))
    let col = max(0, Int(floor((p.x - inset) / cellW)))
    let maxRow = grid.scrollback.count + grid.rows - 1
    return (min(row, maxRow), min(col, grid.cols))
}
```

The incremental-seam §10 bug was applying `row = floor((y + scrollYPixels − inset)/cellH)` to the **unflipped host** point — which inverts the row axis. The fix is the explicit `contentView.convert(point, from: host)` into the flipped content view *before* the row formula, making the inverse symmetric with the forward path. **Validation gate (P4):** type Korean/Japanese; the candidate window must sit *on* the cursor (the classic flip-bug pins it to the screen top).

### 9.5 IME-cursor-rect baseline
Covered by §5.6 — `firstRect` returns the cell rect, glyph baseline inside the cell box is the calibrated formula, pixel-diff-gated via the live toggle.

---

## 10. Resize → cols/rows → reportSize

`reportSizeIfChanged()` stays in `HaliteSurfaceView`, **unchanged in logic** (verified `:418-474`), two seam edits:
- Width from `bounds.width` (points) **minus zero scroller** — the Metal layer has no scroller, so the current `-scrollerWidth (~15pt)` term is **dropped** (legacy keeps it).
- Keep `window.contentRect` + conditional `tabBarReservation = 36pt` (verified `:453/:474`) — else spurious SIGWINCH on every 1↔2-tab native-tab-bar toggle.
- `cellW`/`cellH` from the **shared** metrics (§3.2). `cols = floor(usableW/cellW)`, `rows = floor(usableH/cellH)`, deduped on `(cols,rows)` → `session.resize` → grid + TIOCSWINSZ + `gridChanged`.
- **Zoom (`setZoom`) stays pure-visual:** changes shared `cellMetrics` only, **no `session.resize`** (no SIGWINCH), forces rebuild + atlas reconfigure. Both backends honor this → flipping the toggle at any zoom reports identical cols/rows.

---

## 11. Scroll model (scrollback + smooth scroll)

### 11.1 Scalar `scrollYPixels`
`ScrollModel` owns `scrollYPixels: Float` (content px, sub-pixel). Content height = `(scrollback.count + rows) * cellH + 2*inset`. Grid never repositions — only the uniform changes. **Integer/fractional split:**
- `scrollInt = floor(scrollYPixels / cellH)` → selects which scrollback rows feed `InstanceBuilder` (visible window `[scrollInt, scrollInt+rows+1)`, +1 overdraw row).
- `scrollFrac = scrollYPixels − scrollInt*cellH` → baked into `Uniforms.gridOriginPx.y`; viewport slides sub-cell. A per-frame scissor (floored to int px) clips the overdraw row's sliding edge.

### 11.2 Spring + momentum
- **Input:** `scrollWheel` → `hasPreciseScrollingDeltas` ? raw `scrollingDeltaY` (trackpad sub-pixel) : `× cellH` (line mouse). **Integrate macOS's own `phase`/`momentumPhase` — do not simulate momentum** (the Swift advantage; simulating desyncs from system feel).
- **Spring:** `spring_step(current, target, halfLife=0.016, dt)` critically-damped exponential (`alpha = 1 − exp(−dt·ln2/halfLife)`, snap within 0.005), driven by the transient link, integrated against `link.targetTimestamp` (vsync-locked at any refresh). Rubber-band only at content edges. `advance()` → `settled` stops the link.
- **Mouse-reporting unchanged:** `mouseReportingMode != 0 && !Shift` → wheel → button 64/65 to PTY (in the host, not the scroll model).

### 11.3 Emergent behaviors reproduced (currently from NSScrollView)
- **`followingBottom`** (verified `:131/:824`): auto-scroll only at bottom; user scroll-up stops it; updated only on user scroll intent (not stale bounds); re-enables at bottom (4pt tolerance).
- **Alt-screen / sync-output anchor** (`followTargetY` `:843-857`): for alt-screen OR `hasUsedSyncOutput`, anchor grid-top to viewport-top (`scrollback.count*cellH + inset`) so growing-scrollback TUIs (Claude Code) keep new content visible; normal shell = cursor-visible policy.
- **Scrollback-eviction anchor** while scrolled up: shift `scrollYPixels` by `evictedSinceLast * cellH` (`scrollbackPushCount − scrollback.count`).
- **0.18s snap-to-cursor on input** (`snapToCursorOnUserInput` `:861-878`): spring on `scrollYPixels` toward `followTargetY()`, driven by the link. **`isSnappingToCursor` guard ported:** while the spring runs, the on-demand echo render reads the *animated* `scrollYPixels`, not the target — else echo teleports the view and the animation is invisible.
- **Alt-screen transition** forces `followingBottom = true` (`:1245`).

### 11.4 Legacy scroll adapter (must-fix B)
`LegacyTextBackend` implements the scalar protocol as a thin adapter over the verified NSScrollView mechanism:
```swift
var scrollYPixels: CGFloat { scrollView.contentView.bounds.origin.y }   // :356
func setScrollY(_ y: CGFloat, animated: Bool) {
    let dst = NSPoint(x: 0, y: y)
    if animated { scrollView.contentView.animator().setBoundsOrigin(dst) }  // :870
    else        { scrollView.contentView.scroll(to: dst) }                  // :370/:391
    scrollView.reflectScrolledClipView(scrollView.contentView)              // :371/:395
}
func handleScrollWheel(_ e: NSEvent) { /* NSScrollView native momentum; do nothing extra */ }
```
**Scope, restated:** this faithfully exercises render + cell-geometry + scalar position. It does **not** exercise spring/sub-pixel/rubber-band animation — that is Metal-only and validated at P5.

---

## 12. Future seam (explicitly NOT built)

Offscreen-scene `MTLTexture` + post-fx blit, particles, CRT/bg-fx, image/sixel/Kitty pass, and procedural box-drawing-as-pass are **out of scope**. Rationale (grep-verified): `VTParser`, `Grid`, `Cell` have **zero** image/sixel/Kitty/DCS-graphics support → an image pass has nothing to draw, and effects/box-drawing are not in the current placeholder. These require net-new parser + model work. The `TerminalRenderBackend` protocol and the 4-pass structure leave room (a 5th image pass + an offscreen-scene retarget slot), but nothing is built until a separate architecture doc adds the data source.

---

## 13. Phasing (each phase independently buildable + A/B-comparable on a live terminal)

| Phase | Scope | A/B exit (flip the toggle, compare to legacy) |
|---|---|---|
| **P0 — Extract the seam (no Metal)** | `TerminalRenderBackend`; lift current path into `LegacyTextBackend` (incl. the §11.4 scalar adapter); route `renderNow` tail + geometry (`cell(at:)`, `firstRect`, scroll position) through the protocol; toggle defaults `.legacyText`. | Byte-identical to today; seam exercised; input/IME geometry provably can't reach `textView.convert` except through `LegacyTextBackend`. |
| **P1 — Metal host + bg + block-cursor-inverse, no glyphs** | `MetalContentView` + CAMetalLayer + ring buffers (instances **and** uniforms) + bg pass + block-cursor-as-inverse `BgInstance`. **Resolve the `.module` shader-load gate (must-fix C).** Retina/`drawableSize`, sizing→cols/rows (must match legacy exactly). | Flip → correct bg colors, block cursor as inverse rect, identical cols/rows (no SIGWINCH), no glyphs. Shader library loads. |
| **P2 — Atlas + text, ASCII grayscale** | `GlyphAtlas` (mask page), `GlyphRasterizer`, `CTFontGetGlyphsForCharacters` fast path, glyph-mask pass, **calibrated baseline (§5.6) pixel-diffed via the toggle**. | Readable shell (`ls`, `vim`, prompt) visually matching legacy for plain monospace; baseline pixel-diff within calibration tolerance. |
| **P3 — Full color/attr fidelity** | `ColorResolver` (palette/cube/grayscale/.rgb/inverse), bold (weight only), bg priority chain + fg asymmetry, hover-blue-last, SGR + hyperlink underlines, wide/CJK (left-align, uncapped overflow, continuation skipped), dynamic system colors per-appearance, `CTFontCreateForString` cascade. | Selection/find/hover/CJK/256-color pixel-match legacy. |
| **P4 — Cursor + blink + IME + coordinates** | Bar/underline overlay cursor + 0.53s blink (suppress-while-typing), IME preedit overlay (renders even when DECTCEM hid the cursor; `markedText.count` advance flagged), `CoordinateMap` symmetric `cell(at:)`/`firstRect` (must-fix A). | Korean/JP candidate window lands **on** the cursor; blink + all DECSCUSR shapes match; selection/find/hover don't freeze. |
| **P5 — Smooth scroll + anchoring** | `ScrollModel` scalar + int/frac split, transient link (v14 CADisplayLink / v13 CVDisplayLink), `momentumPhase` integration, spring/rubber-band, follow-bottom, alt/sync grid-top anchor, eviction anchor, 0.18s snap + `isSnappingToCursor` guard, overdraw row + scissor. | Sub-pixel trackpad scroll, momentum, follow-bottom, TUI anchoring match/exceed legacy; **idle 0% GPU, no link running**; typing latency unregressed. |
| **P6 — Color emoji** | Color atlas page (BGRA), color-glyph detection, glyph-color pass. | Apple Color Emoji renders. |
| **P7 — Atlas growth + (optional) ligatures** | Grow-on-full + re-rasterize working set to 4096² cap; `LineShaper` CTLine ligature path (config-gated, default OFF, pixel-diff-gated when enabled). | Long CJK session doesn't drop glyphs; ligatures align to cells when enabled. |
| **P8 — Parity gate: remove the toggle + legacy path** (named, so legacy can't bitrot) | **Exit criteria:** P2–P7 visual parity confirmed on the dogfood matrix (shell, vim, Claude Code/Ink TUI, CJK, emoji, IME) **except the known-divergence list (§8.7)**; typing latency ≤ ±1 frame of legacy (Instruments Metal System Trace); idle 0% GPU. Then default `.metal`, delete `LegacyTextBackend` + the toggle + the NSScrollView/NSTextView internals. The protocol stays (future seam, §12). | Metal is the default and only renderer; placeholder removed. |

---

## 14. Top risks + mitigations

| Risk | Mitigation |
|---|---|
| **Abstraction leak — geometry still reaches `textView.convert`** | Route all geometry through the protocol in **P0**, before Metal exists → won't compile if it leaks. |
| **Toggle flip resizes the PTY** (different metrics → SIGWINCH → reflow → A/B useless) | Shared backend-independent `cellMetrics` (§3.2), exact `measuredLineHeight("M\nM\nM"/3)`. Both report identical cols/rows. Zoom pure-visual on both. |
| **Baseline mis-derivation (highest pixel-divergence risk)** | Concrete formula (§5.6) + **calibration offset pixel-diffed via the live toggle** on a running terminal — the spine's unique de-risking tool. |
| **Coordinate flip bug → IME candidate at screen top** | Symmetric `cell(at:)`/`firstRect` (§9.4); `isFlipped` localized to MetalContentView; P4 Korean/JP validation gate. |
| **Uniforms buffer race on scroll ticks** | Ring-buffer Uniforms in the same `DispatchSemaphore(3)` as instances (§6.4). |
| **Library-target shader load fails** | P1 build gate: `makeDefaultLibrary(bundle: .module)` + embedded-source fallback (§1). |
| **Off-main display-link race** | Everything on main; transient link re-reads the pre-built buffer (uniform-only), never `session.grid`; gridLock is an explicit non-goal (§4.4). |
| **6-part key under-trigger** | Don't touch it — `scheduleRender` + the 6-part key + sync gate kept verbatim; only `renderNow`'s tail branches (§2.2). |
| **Scope creep (porting Rust effects/images)** | Draw directly into the drawable; no offscreen scene/post-fx/particles/image pass — grep-confirmed no data source (§6.1, §12). |
| **Legacy bitrot / toggle forever** | Short A/B-validated phases + **named P8** with explicit parity exit criteria that *removes* the legacy path. |
| **Dual-maintenance window** | Acknowledged real cost (two live paths until P8); bounded by short phases; `LegacyTextBackend` is throwaway code deleted at P8. |

---

**Verdict in one line:** incremental-seam's structure (byte-stable API, backend protocol, live A/B toggle, shared cellMetrics, named legacy-removal) + ghostty-style's lean 4-pass altitude + faithful-port's concrete baseline formula and parity catalog — with all nine cross-design must-fixes resolved (coordinate symmetry, scroll-adapter honesty, library shader load, IME-advance caveat, concrete baseline, uniforms race, honest phasing, deferred images, ligatures-off). Reaches a placeholder-deleting renderer on the same timeline as the rivals while being the only design that de-risks every phase against live legacy output.
