import AppKit
import Metal
import simd

/// The `CAMetalLayer` renderer: draws cell backgrounds, selection/find
/// highlights, glyphs (mask + color-emoji pages), line overlays
/// (underline/strikethrough/hyperlink/hover), the block/bar/underline cursor,
/// and the IME preedit overlay as instanced quads. Owns scroll geometry
/// (wheel/momentum/rubber-band + smooth programmatic eases) and host↔cell
/// coordinate mapping (mouse hit-testing + IME cursor-rect).
///
/// The sole render backend (the legacy `NSTextView` path was retired at P6).
final class MetalTerminalBackend: TerminalRenderBackend {
    private let metalView = MetalContentView(frame: .zero)
    private let md: MetalDevice

    private(set) var renderFont: NSFont
    private var config: DamsonConfig
    private var metrics = CellMetrics(width: 8, height: 16)

    /// Scalar vertical scroll position. Consumes OS wheel/momentum deltas
    /// directly (NSScrollView-style); programmatic jumps (snap-to-cursor) ease via
    /// `animLink`.
    private var scroll = ScrollModel()
    /// Read-only mirror of `scroll.current` (content px from top, 0 = top), kept
    /// so the many existing `scrollY` reads (coord map, instance positions) work.
    private var scrollY: CGFloat { scroll.current }
    /// Transient display link for smooth programmatic eases (macOS 14+).
    private lazy var animLink = AnimationLink(view: metalView)
    /// Cached from the last render so `contentHeight` is correct between frames.
    private var lastTotalRows: Int = 0
    /// Snapshot of the last frame's inputs, so resize/backing-change redraws.
    private var lastGrid: Grid?
    private var lastState = RenderState()

    var onScrollGeometryChanged: (() -> Void)?
    var onUserScroll: (() -> Void)?

    /// The content inset, matched to the legacy textView's so cols/rows agree.
    /// Inner padding (window edge ↔ grid). Follows config.padding via applyConfig.
    private var inset = NSSize(width: 4, height: 4)

    /// Glyph atlas, rebuilt when font / cell size / backing scale changes.
    private var atlas: GlyphAtlas?
    private var atlasSignature = ""
    /// Offscreen scene render target, used only when a screen effect is active.
    /// Recreated when the drawable size changes.
    private var sceneTexture: MTLTexture?

    /// Cached base-frame GPU buffers (everything EXCEPT the block cursor, which
    /// is a separate pass). Reused when nothing but the cursor blink phase
    /// changed, so a blinking block cursor doesn't rebuild + re-upload the whole
    /// grid ~2×/s. Invalidated on any config/font change (applyConfig /
    /// setRenderFont); per-frame validity is checked against `FrameCache.key`.
    private struct FrameKey: Equatable {
        var version: UInt64
        var cols: Int
        var rows: Int
        var scrollbackCount: Int
        var scrollY: CGFloat
        var boundsW: CGFloat
        var boundsH: CGFloat
        var scale: CGFloat
        var opacity: CGFloat
        var atlasSig: String
        var stateKey: String
    }
    private struct FrameCache {
        var key: FrameKey
        var bg: MTLBuffer?; var bgCount: Int
        var glyph: MTLBuffer?; var glyphCount: Int
        var color: MTLBuffer?; var colorCount: Int
        var overlay: MTLBuffer?; var overlayCount: Int
    }
    private var frameCache: FrameCache?

    /// Animated screen effects (rain / snow / underwater): a dedicated display
    /// link drives continuous redraws while one is active. The shader reads
    /// time from `PostFXParams.coeffs4.x`. The link stops automatically when
    /// the surface is occluded (AnimationLink does that) and restarts on the
    /// next visible render. Time is measured against an epoch and wrapped
    /// hourly so it stays Float-precise; the wrap just re-rolls every drop
    /// once an hour, indistinguishable from the constant re-rolling anyway.
    private lazy var effectAnimLink = AnimationLink(view: metalView)
    private let effectEpoch: CFTimeInterval = CACurrentMediaTime()
    private var lastEffectRenderTime: CFTimeInterval = 0
    /// Test hook: freezes the shader clock so captures are deterministic.
    var effectTimeOverride: Float?
    private var effectTime: Float {
        if let t = effectTimeOverride { return t }
        return Float((CACurrentMediaTime() - effectEpoch)
            .truncatingRemainder(dividingBy: 3600))
    }

    /// Render rate limiting. `nextDrawable()` blocks the main thread until the next
    /// vsync once the drawable pool (3) fills, starving PTY input. We remember the
    /// last present time and coalesce renders called more often than the refresh
    /// interval (schedule once, then skip).
    private var lastPresentTime: CFTimeInterval = 0
    private var coalesceScheduled = false

    /// Scroll / ease render-loop state. While scrolling, we don't render
    /// synchronously per event; instead we apply only the delta and set this flag so
    /// the display link (`animLink`) renders the latest position once per vsync —
    /// frame intervals become uniform and the stutter disappears (it removes the
    /// judder caused by asyncAfter-timer coalescing not aligning to vsync). Once
    /// activity stops, the link is halted a few frames later.
    private var scrollRenderPending = false
    private var renderLoopIdleTicks = 0
    private let renderLoopMaxIdleTicks = 4

    /// Frame-pacing measurement. With env `DAMSON_FPS_LOG=1` it NSLogs once per
    /// second; when the perf HUD is on it sends a string via `onPerfStats` every
    /// 0.25s. It measures the display-link tick interval, so whether the link runs
    /// at 60 or 120 — and any jitter — shows through directly.
    private let fpsLogEnabled = ProcessInfo.processInfo.environment["DAMSON_FPS_LOG"] != nil
    private var perfHUDActive = false
    /// When the custom perf HUD is on, sends the **actual present interval**
    /// (seconds) — measured against frames drawn to screen, so it matches Apple
    /// HUD's FPS (display-link tick ≠ present).
    var onPerfSample: ((CFTimeInterval) -> Void)?
    private var lastHUDPresentTime: CFTimeInterval = 0
    private var fpsAccum: CFTimeInterval = 0
    private var fpsTicks = 0
    private var fpsRendered = 0
    private var fpsMin: CFTimeInterval = .infinity
    private var fpsMax: CFTimeInterval = 0

    /// Our custom graph HUD on/off. When on, it sends the frame interval to the HUD
    /// on every present (only while there's render activity — keyed to actual screen
    /// refreshes, same as the Apple HUD).
    func setPerfHUD(_ on: Bool) {
        perfHUDActive = on
        lastHUDPresentTime = 0
    }

    /// Apple Metal Performance HUD on/off — the official per-layer API. Using this
    /// instead of the `MTL_HUD_ENABLED` env var (global injection) lets the app
    /// toggle it, and avoids the path where the env var crashed libMTLHud on a
    /// display change. "default"=show, "none"=hide.
    func setAppleHUD(_ on: Bool) {
        metalView.metalLayer.developerHUDProperties = on ? ["mode": "default"] : ["mode": "none"]
    }

    // MARK: glyph appear/disappear animation (cursor-area only)

    private struct GlyphAnimEntry {
        var appearing: Bool
        var start: CFTimeInterval
        var duration: CFTimeInterval
        var style: GlyphAnimStyle
        var cell: Cell          // disappear: the glyph to fade out (gone from the grid)
    }
    private struct CellPos: Hashable { var row: Int; var col: Int }   // unified-row coords
    private var glyphAnims: [CellPos: GlyphAnimEntry] = [:]
    /// Snapshot of the cursor row's cells at the last diffed grid version, used to
    /// detect single-cell typing / deleting near the cursor.
    private var prevCursorRow: [Cell] = []
    private var prevCursorRowIndex: Int = -1
    private var lastGlyphDiffVersion: UInt64 = .max
    /// Reveal-pacing clock. Spaces out glyph-animation start times at a fixed
    /// interval so bursty input becomes a smooth flow. When input stops, the clock
    /// falls behind `now` and reverts to instant playback.
    private var glyphRevealClock: CFTimeInterval = 0
    private static let glyphRevealPace: CFTimeInterval = 0.022   // reveal interval between glyphs
    private static let glyphRevealMaxLead: CFTimeInterval = 0.07 // max lag behind the cursor (cap)
    private lazy var glyphAnimLink = AnimationLink(view: metalView)
    /// Cap animation rendering at ~60fps (independent of refresh rate). At 120Hz
    /// every other frame, at 60Hz every frame → 60fps either way. Prevents a full
    /// render every frame from monopolizing the main thread and starving PTY input.
    private var lastGlyphRenderTime: CFTimeInterval = 0
    private static let glyphRenderMinInterval: CFTimeInterval = 0.013
    /// Ligature shaper, rebuilt alongside the atlas (same font). Used only when
    /// `config.ligatures` is on.
    private var lineShaper: LineShaper?

    private func ensureAtlas() {
        let scale = metalView.metalLayer.contentsScale
        let sig = "\(renderFont.fontName)|\(renderFont.pointSize)|\(metrics.width)|\(metrics.height)|\(scale)|\(config.doubleWidthIcons)"
        if sig != atlasSignature || atlas == nil {
            atlas = GlyphAtlas(device: md.device, font: renderFont,
                               cellW: metrics.width, cellH: metrics.height, scale: scale,
                               iconDoubleWidth: config.doubleWidthIcons)
            let bold = NSFontManager.shared.convert(renderFont, toHaveTrait: .boldFontMask)
            lineShaper = LineShaper(baseFont: renderFont, boldFont: bold)
            atlasSignature = sig
        }
    }

    init?(config: DamsonConfig) {
        guard let md = MetalDevice.shared else { return nil }
        self.md = md
        self.config = config
        self.renderFont = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        self.inset = config.padding
        metalView.onNeedsDisplay = { [weak self] in self?.redrawLast() }
    }

    // MARK: - TerminalRenderBackend

    var contentView: NSView { metalView }
    // No native scroller — full bounds is usable. (May differ from legacy by the
    // scroller width; a one-time reflow on toggle is acceptable for the dev path.)
    var contentSize: NSSize { metalView.bounds.size }
    var contentInset: NSSize { inset }

    func applyConfig(_ config: DamsonConfig) {
        self.config = config
        renderFont = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        inset = config.padding
        rgbaCache.removeAll(keepingCapacity: true)   // theme may have changed
        frameCache = nil   // theme / padding / ligatures etc. aren't in the frame key
        redrawLast()
    }

    func setRenderFont(_ font: NSFont) {
        renderFont = font
        frameCache = nil
        redrawLast()
    }

    private func coordMap() -> CoordinateMap {
        CoordinateMap(cellW: metrics.width, cellH: metrics.height, inset: inset, scrollY: scrollY)
    }

    /// Snap a point value to the nearest device pixel, so adjacent cell quads
    /// share an identical edge (no sub-pixel seam between fills).
    private func snap(_ v: CGFloat) -> CGFloat {
        let s = metalView.metalLayer.contentsScale
        return s > 0 ? (v * s).rounded() / s : v
    }

    private func redrawLast() {
        guard let grid = lastGrid else { return }
        // While synchronized output (DEC 2026 BSU…ESU) is in progress, skip
        // backend-initiated redraws (coalesce / animation / layout). Otherwise an
        // incomplete grid mid-redraw-burst gets presented and the screen flickers.
        // The completed frame is drawn by the host's renderNow after ESU (or a 150ms
        // safety flush).
        if grid.inSyncOutputMode { return }
        render(grid: grid, config: config, state: lastState, metrics: metrics)
    }

    // MARK: - vsync-aligned scroll / ease render loop

    /// Start the display-link loop (if not already running). Called when a scroll
    /// delta arrives or a programmatic ease begins. If it's already running, leave it.
    private func ensureRenderLoop() {
        guard !animLink.isRunning else { return }
        renderLoopIdleTicks = 0
        let started = animLink.start { [weak self] dt in
            self?.renderLoopTick(dt: dt) ?? true
        }
        if !started {
            // macOS < 14: no display link → settle the ease immediately and render once synchronously.
            if scroll.animating { _ = scroll.step(dt: 10) }   // large dt → converge to target instantly
            scrollRenderPending = false
            redrawLast()
            onScrollGeometryChanged?()
        }
    }

    /// One vsync frame. If an ease is in flight, advance it one step; if anything
    /// changed (whether an ease or a new scroll delta), render the latest position
    /// exactly once. Once activity stops, halt a few frames later. Returns true when
    /// the loop should stop.
    private func renderLoopTick(dt: CFTimeInterval) -> Bool {
        let easing = scroll.animating
        if easing { _ = scroll.step(dt: CGFloat(dt)) }

        if fpsLogEnabled { measureFrame(dt: dt, rendered: easing || scrollRenderPending) }

        if easing || scrollRenderPending {
            scrollRenderPending = false
            renderLoopIdleTicks = 0
            // Already aligned to vsync → render immediately, no throttle.
            if let grid = lastGrid, !grid.inSyncOutputMode {
                render(grid: grid, config: config, state: lastState, metrics: metrics,
                       throttled: false)
            }
            onScrollGeometryChanged?()
        } else {
            renderLoopIdleTicks += 1
        }
        // Keep going while an ease is in flight. Otherwise stop once the idle grace period passes (gesture + momentum ended).
        if scroll.animating { return false }
        return renderLoopIdleTicks > renderLoopMaxIdleTicks
    }

    // MARK: - animated screen-effect redraw loop

    /// Keep redrawing while an animated screen effect (rain / snow / underwater)
    /// is selected. Renders are capped at ~60fps (same cap as glyph animations)
    /// so a 120Hz link doesn't double the full-pipeline cost. The loop ends the
    /// moment the effect is switched off; AnimationLink itself stops on
    /// occlusion and the next visible render restarts us.
    private func ensureEffectAnimLoop() {
        guard !effectAnimLink.isRunning else { return }
        effectAnimLink.start { [weak self] _ in
            guard let self, self.config.screenEffect.isAnimated, self.lastGrid != nil
            else { return true }
            let now = CACurrentMediaTime()
            if now - self.lastEffectRenderTime >= Self.glyphRenderMinInterval {
                self.lastEffectRenderTime = now
                self.redrawLast()
            }
            return false
        }
    }

    /// NSLogs once per second when env `DAMSON_FPS_LOG=1` (the HUD is handled separately via onPerfSample).
    private func measureFrame(dt: CFTimeInterval, rendered: Bool) {
        fpsAccum += dt
        fpsTicks += 1
        if rendered { fpsRendered += 1 }
        fpsMin = min(fpsMin, dt)
        fpsMax = max(fpsMax, dt)
        guard fpsAccum >= 1.0 else { return }
        let screenMax = metalView.window?.screen?.maximumFramesPerSecond ?? -1
        NSLog("damson scroll: link %.0f Hz (avg %.1fms, min %.1f, max %.1f) — rendered %d/%d — screen %d Hz",
              Double(fpsTicks) / fpsAccum, fpsAccum / Double(fpsTicks) * 1000,
              fpsMin * 1000, fpsMax * 1000, fpsRendered, fpsTicks, screenMax)
        fpsAccum = 0; fpsTicks = 0; fpsRendered = 0; fpsMin = .infinity; fpsMax = 0
    }

    // MARK: glyph appear/disappear

    /// On a frame where the grid changed, compare the cursor row against the
    /// previous snapshot and, for small (≤4) changes, register appear/disappear
    /// animations. Skip when the row changed (Enter/scroll) or there's a large
    /// change (line redraw/paste) — the goal is to catch only typing/deleting.
    private func diffGlyphChanges(grid: Grid) {
        let appear = config.glyphAppear
        let disappear = config.glyphDisappear
        guard appear != .none || disappear != .none else {
            prevCursorRowIndex = -1
            return
        }
        // If the grid version is unchanged (e.g. an animation tick), don't re-diff.
        guard grid.version != lastGlyphDiffVersion else { return }
        lastGlyphDiffVersion = grid.version

        let urow = grid.scrollback.count + grid.cursorRow
        let cur: [Cell] = (0..<grid.cols).map { grid.cell(row: grid.cursorRow, col: $0) }
        defer { prevCursorRow = cur; prevCursorRowIndex = urow }

        // Only compare when it's the same cursor row as before (a row change isn't typing).
        guard prevCursorRowIndex == urow, prevCursorRow.count == cur.count else { return }

        var appears: [Int] = []                 // columns where a glyph newly appeared
        var disappears: [Int: Cell] = [:]       // columns where a glyph disappeared → the old cell
        for c in 0..<cur.count {
            let beforeBlank = prevCursorRow[c].char == " "
            let afterBlank = cur[c].char == " "
            if !afterBlank, beforeBlank || prevCursorRow[c].char != cur[c].char {
                appears.append(c)
            } else if afterBlank, !beforeBlank {
                disappears[c] = prevCursorRow[c]
            }
        }
        guard !appears.isEmpty || !disappears.isEmpty else { return }

        // Holding a key down batches the echo, so several characters arrive at once
        // in a single frame. For a contiguous run adjacent to the cursor, animate up
        // to 16 characters, but space their start times via the reveal clock at a
        // fixed pace so the burst becomes a smooth flow. When input stops, the clock
        // falls behind `now` and reverts to instant playback (a single keystroke has
        // zero delay).
        let cap = 16
        let cursorCol = grid.cursorCol
        let now = CACurrentMediaTime()

        // Typing: a contiguous run ending at cursorCol-1, to the left of the cursor
        // (changes right of the cursor = autosuggestion etc. are ignored).
        let typed = appears.filter { $0 < cursorCol }.sorted()
        let typingRun = !typed.isEmpty && typed.last! == cursorCol - 1
            && (typed.last! - typed.first!) == typed.count - 1 && typed.count <= cap
        // Backspace: a contiguous run starting at the cursor.
        let cleared = disappears.keys.filter { $0 >= cursorCol }.sorted()
        let backRun = !cleared.isEmpty && cleared.first! == cursorCol
            && (cleared.last! - cleared.first!) == cleared.count - 1 && cleared.count <= cap

        // When the lag exceeds the cap, reset the clock to `now` only at the start of
        // the batch (catch-up), bounding the lag. Within a batch, always advance by
        // the pace interval so the characters don't clump together at once.
        // (Previously each character was clamped to now+cap, so a batch that hit the
        // cap released all at once and stuttered ~4 chars at a time.)
        if glyphRevealClock > now + Self.glyphRevealMaxLead { glyphRevealClock = now }
        func nextRevealStart() -> CFTimeInterval {
            let start = max(now, glyphRevealClock)
            glyphRevealClock = start + Self.glyphRevealPace
            return start
        }

        if appear != .none, typingRun {
            let dur = appear.duration(appearing: true)
            for c in typed {                    // left to right (oldest character first)
                glyphAnims[CellPos(row: urow, col: c)] = GlyphAnimEntry(
                    appearing: true, start: nextRevealStart(), duration: dur, style: appear, cell: cur[c])
            }
        }
        if disappear != .none, backRun {
            let dur = disappear.duration(appearing: false)
            for c in cleared.reversed() {       // right to left (first-deleted character first)
                glyphAnims[CellPos(row: urow, col: c)] = GlyphAnimEntry(
                    appearing: false, start: nextRevealStart(), duration: dur, style: disappear, cell: disappears[c]!)
            }
        }
        if !glyphAnims.isEmpty { startGlyphAnimLink() }
    }

    private func pruneGlyphAnims() {
        guard !glyphAnims.isEmpty else { return }
        let now = CACurrentMediaTime()
        glyphAnims = glyphAnims.filter { now - $0.value.start < $0.value.duration }
    }

    private func startGlyphAnimLink() {
        let ok = glyphAnimLink.start { [weak self] _ in
            guard let self else { return true }
            self.pruneGlyphAnims()
            if self.glyphAnims.isEmpty { return true }
            // A full render every frame monopolizes the main thread and starves PTY
            // input (input releases in bursts of 6–9 chars). A time-based ~60fps cap
            // yields the main thread to input, so characters flow one at a time
            // smoothly at the natural key-repeat rate. (Refresh-rate independent —
            // 120Hz every other frame, 60Hz every frame.)
            let t = CACurrentMediaTime()
            if t - self.lastGlyphRenderTime >= Self.glyphRenderMinInterval {
                self.lastGlyphRenderTime = t
                self.redrawLast()
            }
            return self.glyphAnims.isEmpty
        }
        if !ok { glyphAnims.removeAll() }   // macOS < 14: no link → instant (no anim)
    }

    /// The appear-animation progress (0~1) for cell (row,col). nil if none.
    private func appearProgress(row: Int, col: Int) -> Float? {
        guard let a = glyphAnims[CellPos(row: row, col: col)], a.appearing else { return nil }
        let p = Float((CACurrentMediaTime() - a.start) / a.duration)
        return max(0, min(1, p))
    }

    /// Protocol entry point — aperiodic paths like typing / grid changes. Throttled.
    func render(grid: Grid, config: DamsonConfig, state: RenderState, metrics: CellMetrics) {
        render(grid: grid, config: config, state: state, metrics: metrics, throttled: true)
    }

    func render(grid: Grid, config: DamsonConfig, state: RenderState, metrics: CellMetrics,
                throttled: Bool) {
        self.config = config
        self.metrics = metrics
        self.lastGrid = grid
        self.lastState = state
        self.lastTotalRows = grid.scrollback.count + grid.rows
        // Keep the scroll clamp current as content grows/shrinks (re-clamps if the
        // viewport now extends past the new bottom).
        scroll.maxY = max(0, contentHeight - viewportHeight)

        let layer = metalView.metalLayer
        // During resize, present synchronously with the layout transaction — no rate limit.
        let syncPresent = layer.presentsWithTransaction
        // Cap rendering at the display refresh rate. nextDrawable() blocks the main
        // thread until the next vsync once the drawable pool (3) fills (a ~16ms block
        // while typing → input starvation), and fast successive input that calls
        // render more often than vsync drains the pool and blocks frequently. If the
        // refresh interval hasn't elapsed since the last present, this render is
        // skipped after scheduling a single coalesce (a single keystroke leaves
        // enough of a gap to render immediately → low latency preserved).
        // Display refresh interval (120Hz→8.3ms, 60Hz→16.7ms). Renders called more often than that are skipped.
        let fps = max(60, metalView.window?.screen?.maximumFramesPerSecond ?? 60)
        let minRenderInterval = 1.0 / CFTimeInterval(fps)
        // Renders driven by the display link (scroll/ease) are already vsync-aligned,
        // so skip throttling. The throttle only guards the nextDrawable block for
        // aperiodic input such as typing.
        if throttled, !syncPresent {
            let since = CACurrentMediaTime() - lastPresentTime
            if since < minRenderInterval {
                if !coalesceScheduled {
                    coalesceScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + (minRenderInterval - since)) {
                        [weak self] in
                        guard let self else { return }
                        self.coalesceScheduled = false
                        self.redrawLast()
                    }
                }
                return
            }
        }

        ensureAtlas()
        // Detect typing/deleting near the cursor and register glyph appear/disappear
        // animations (only on frames where the grid changed). buildInstances then
        // reflects that progress.
        diffGlyphChanges(grid: grid)
        // When background opacity < 1, leave the layer transparent so what's behind (desktop/blur) shows through.
        let opacity = max(0.2, min(1.0, config.backgroundOpacity))
        layer.isOpaque = opacity >= 1.0
        guard layer.drawableSize.width > 0, let drawable = layer.nextDrawable() else {
            return
        }

        // Build the base instances (everything but the block cursor) or reuse
        // the cached GPU buffers when nothing affecting them changed. A blink
        // phase toggle hits the cache, so the grid isn't rebuilt + re-uploaded
        // ~2×/s while idle — the block cursor is a separate pass below.
        let scale = metalView.metalLayer.contentsScale
        let key = FrameKey(
            version: grid.version, cols: grid.cols, rows: grid.rows,
            scrollbackCount: grid.scrollback.count, scrollY: scrollY,
            boundsW: metalView.bounds.width, boundsH: metalView.bounds.height,
            scale: scale, opacity: opacity, atlasSig: atlasSignature,
            stateKey: baseStateKey(state))
        let cache: FrameCache
        // Time-based glyph animations change the base every frame → never reuse.
        if glyphAnims.isEmpty, let fc = frameCache, fc.key == key {
            cache = fc
        } else {
            let (rawBg, glyphInstances, colorGlyphInstances, overlayInstances) =
                buildInstances(grid: grid, state: state)
            let bgInstances = fadeBackgrounds(rawBg, opacity: opacity)
            func makeBuf<T>(_ arr: [T]) -> MTLBuffer? {
                guard !arr.isEmpty else { return nil }
                return arr.withUnsafeBytes { raw in
                    md.device.makeBuffer(bytes: raw.baseAddress!, length: raw.count,
                                         options: .storageModeShared)
                }
            }
            cache = FrameCache(
                key: key,
                bg: makeBuf(bgInstances), bgCount: bgInstances.count,
                glyph: makeBuf(glyphInstances), glyphCount: glyphInstances.count,
                color: makeBuf(colorGlyphInstances), colorCount: colorGlyphInstances.count,
                overlay: makeBuf(overlayInstances), overlayCount: overlayInstances.count)
            frameCache = cache
        }

        // When a screen effect (CRT etc.) is on, draw the terminal into the
        // offscreen sceneTexture, then composite onto the drawable with a fullscreen
        // post-fx pass. When off, draw directly to the drawable.
        let effect = config.screenEffect
        if effect.isAnimated { ensureEffectAnimLoop() }
        let sceneTarget: MTLTexture = effect.isActive
            ? ensureSceneTexture(matching: drawable.texture)
            : drawable.texture

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sceneTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor(config.theme.background, opacity: opacity)
        pass.colorAttachments[0].storeAction = .store

        guard let cmd = md.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(viewportSize: SIMD2<Float>(Float(metalView.bounds.width),
                                                           Float(metalView.bounds.height)))

        // Pass 1: cell backgrounds / selection / find.
        if let b = cache.bg, cache.bgCount > 0 {
            enc.setRenderPipelineState(md.bgPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(b, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: cache.bgCount)
        }
        // Pass 2: glyphs (coverage atlas modulated by fg color).
        if let b = cache.glyph, cache.glyphCount > 0, let atlas = atlas {
            enc.setRenderPipelineState(md.glyphPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(b, offset: 0, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(md.glyphSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: cache.glyphCount)
        }
        // Pass 2b: color emoji (premultiplied BGRA color page, fg ignored).
        if let b = cache.color, cache.colorCount > 0, let colorTex = atlas?.colorTexture {
            enc.setRenderPipelineState(md.colorGlyphPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(b, offset: 0, index: 1)
            enc.setFragmentTexture(colorTex, index: 0)
            enc.setFragmentSamplerState(md.glyphSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: cache.colorCount)
        }
        // Pass 3: line overlays (underline / strikethrough / hyperlink / hover) —
        // same filled-quad pipeline as bg, drawn ON TOP so strikethrough shows.
        if let b = cache.overlay, cache.overlayCount > 0 {
            enc.setRenderPipelineState(md.bgPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(b, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: cache.overlayCount)
        }
        // Pass 4: the block cursor — a separate pass (on top) so a blink phase
        // toggle reuses the cached base passes above instead of rebuilding.
        encodeCursorPass(enc: enc, uniforms: &uniforms, grid: grid, state: state)

        enc.endEncoding()

        // Post-fx pass: sample the offscreen scene, apply the screen effect, write
        // the drawable. (Skipped entirely when the effect is off — sceneTarget is
        // the drawable itself and nothing above changed.)
        if effect.isActive,
           let sceneTex = sceneTexture,
           var params = effect.postFXParams(
               screenSize: SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height)),
               intensity: Float(config.screenEffectIntensity)),
           let fxEnc = cmd.makeRenderCommandEncoder(descriptor: postfxPass(drawable.texture)) {
            // The tube bezel (outside the curved image) shows the terminal
            // background, dimmed in the shader — same source as the clear color.
            let bg = clearColor(config.theme.background, opacity: opacity)
            params.bgColor = SIMD4<Float>(Float(bg.red), Float(bg.green),
                                          Float(bg.blue), Float(bg.alpha))
            params.coeffs4.x = effectTime
            fxEnc.setRenderPipelineState(md.postfxPipeline)
            fxEnc.setFragmentTexture(sceneTex, index: 0)
            fxEnc.setFragmentSamplerState(md.glyphSampler, index: 0)
            fxEnc.setFragmentBytes(&params, length: MemoryLayout<PostFXParams>.stride, index: 0)
            fxEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            fxEnc.endEncoding()
        }

        // During live resize the layer presents with the layout transaction, so the
        // frame must be presented synchronously (after scheduling) — otherwise the
        // old drawable gets stretched to the new bounds before this frame lands
        // (visible flicker / stretched text). Outside resize, async present keeps
        // typing latency minimal.
        if syncPresent {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }
        lastPresentTime = CACurrentMediaTime()
        // perf HUD: send the actual present interval (keyed to frames drawn to screen = same as Apple HUD).
        if perfHUDActive {
            if lastHUDPresentTime > 0 { onPerfSample?(lastPresentTime - lastHUDPresentTime) }
            lastHUDPresentTime = lastPresentTime
        }
    }

    /// Build bg fills + glyph quads + line overlays (underline/strikethrough) for
    /// the visible rows in one pass over cells. Overlay lines draw AFTER the glyph
    /// pass so a strikethrough sits on top of the text.
    private func buildInstances(grid: Grid, state: RenderState)
        -> (bg: [BgInstance], glyph: [GlyphInstance], colorGlyph: [GlyphInstance], overlay: [BgInstance]) {
        let map = coordMap()
        let cellH = max(metrics.height, 1)
        let totalRows = grid.scrollback.count + grid.rows
        let h = metalView.bounds.height
        let first = max(0, Int(floor((scrollY - inset.height) / cellH)))
        let last = min(totalRows - 1, Int(ceil((scrollY + h - inset.height) / cellH)))
        guard first <= last else { return ([], [], [], []) }

        var bg: [BgInstance] = []
        var glyphs: [GlyphInstance] = []
        var colorGlyphs: [GlyphInstance] = []   // emoji (sampled from the BGRA page)
        var overlay: [BgInstance] = []   // underline / strikethrough / hyperlink / hover lines
        bg.reserveCapacity((last - first + 1) * max(grid.cols, 1))
        glyphs.reserveCapacity(bg.capacity)

        // The block cursor is NOT baked here — it's drawn as a separate pass in
        // render() (see cursorDrawData) so a blink phase toggle reuses these
        // cached base instances instead of rebuilding the whole grid.

        // IME preedit overlay (composing text drawn at the cursor; the cells it
        // covers are hidden). Shown even when DECTCEM hid the cursor.
        let imeRow = grid.scrollback.count + grid.cursorRow
        let imeActive = !state.markedText.isEmpty
        let imeOverlayCols = imeActive ? state.markedText.reduce(0) { $0 + (Cell.isWide($1) ? 2 : 1) } : 0
        let imeAfterCol = min(grid.cursorCol + imeOverlayCols, grid.cols)

        for row in first...last {
            let cells = cellsForRow(grid: grid, unifiedRow: row)
            let cols = cells.count
            guard cols > 0 else { continue }
            let sel = selectedColumns(state, row: row, cols: cols)
            let finds = state.findMatchesByRow[row] ?? []
            let activeFind: Range<Int>? = (state.activeFindRow == row) ? state.activeFindRange : nil
            let hover: Range<Int>? = state.hoveredSegments[row]

            // Ligatures (opt-in): shape the row once; shaped glyph ids replace the
            // per-char glyphs across each shapable run (bg/overlays stay per-cell).
            var shapedByStart: [Int: LineShaper.ShapedGlyph] = [:]
            var shapedCovered: Set<Int> = []
            if config.ligatures, let shaper = lineShaper {
                for sg in shaper.shape(in: cells) {
                    shapedByStart[sg.startCol] = sg
                    for c in sg.startCol..<(sg.startCol + sg.cellSpan) { shapedCovered.insert(c) }
                }
            }
            for col in 0..<cols {
                let cell = cells[col]
                if cell.isContinuation { continue }
                if imeActive, row == imeRow, col >= grid.cursorCol, col < imeAfterCol { continue }
                let wide = (col + 1 < cols && cells[col + 1].isContinuation)
                let wcells = wide ? 2 : 1
                // Pixel-snap cell edges so adjacent cells share the exact same
                // boundary — kills the sub-pixel dark seam between powerline /
                // background fills caused by fractional cell width.
                let x0 = snap(inset.width + CGFloat(col) * metrics.width)
                let x1 = snap(inset.width + CGFloat(col + wcells) * metrics.width)
                // Snap only the content position (adjacent rows share the same snap
                // input → no seam); subtract scrollY outside the snap to keep it
                // sub-pixel → scrolling is smooth with no 1px quantization.
                // (docs/SMOOTH-SCROLL.md: scrollYPixels need not be an integer.)
                let y0 = snap(inset.height + CGFloat(row) * metrics.height) - scrollY
                let y1 = snap(inset.height + CGFloat(row + 1) * metrics.height) - scrollY
                let origin = SIMD2<Float>(Float(x0), Float(y0))
                let size = SIMD2<Float>(Float(x1 - x0), Float(y1 - y0))

                if let bgRGBAColor = bgRGBA(cell: cell, col: col, sel: sel, finds: finds,
                                           activeFind: activeFind, isCursor: false) {
                    bg.append(BgInstance(origin: origin, size: size, color: bgRGBAColor))
                }
                let fgRGBAColor = fgRGBA(cell: cell, col: col, sel: sel, finds: finds,
                                         activeFind: activeFind, hover: hover, isCursor: false)
                if shapedCovered.contains(col) {
                    // A shaped run owns this cell. Draw the shaped glyph id at its
                    // start column (spanning cellSpan), nothing for trailing cells.
                    // The bitmap is padded by `ligaturePadCells` on each side (so
                    // overflowing connecting forms aren't clipped); shift the quad
                    // left by the same pad and widen it to match.
                    if let sg = shapedByStart[col],
                       let region = atlas?.region(forGlyph: sg.glyph, bold: sg.bold, cellSpan: sg.cellSpan) {
                        let pad = CGFloat(GlyphRasterizer.ligaturePadCells) * metrics.width
                        let gx0 = snap(inset.width + CGFloat(col) * metrics.width - pad)
                        let gx1 = snap(inset.width + CGFloat(col + sg.cellSpan) * metrics.width + pad)
                        glyphs.append(GlyphInstance(
                            origin: SIMD2<Float>(Float(gx0), Float(y0)),
                            size: SIMD2<Float>(Float(gx1 - gx0), Float(y1 - y0)),
                            uvOrigin: region.uv.origin, uvSize: region.uv.size, color: fgRGBAColor))
                    }
                } else if cell.char != " ", let region = atlas?.region(for: cell.char, bold: cell.attrs.bold, wide: wide) {
                    // Double-width Nerd icons: the bitmap is a 2-cell box but the
                    // grid slot is 1 cell — widen the quad symmetrically (centered
                    // overflow into neighbors), mirroring the ligature-pad path.
                    var gOrigin = origin, gSize = size
                    if region.overflowCells > 0 {
                        let half = region.overflowCells * metrics.width / 2
                        let gx0 = snap(inset.width + CGFloat(col) * metrics.width - half)
                        let gx1 = snap(inset.width + CGFloat(col + wcells) * metrics.width + half)
                        gOrigin = SIMD2<Float>(Float(gx0), Float(y0))
                        gSize = SIMD2<Float>(Float(gx1 - gx0), Float(y1 - y0))
                    }
                    var inst = GlyphInstance(origin: gOrigin, size: gSize,
                                             uvOrigin: region.uv.origin, uvSize: region.uv.size,
                                             color: fgRGBAColor)
                    // Appear animation (near the cursor): fade/scale by progress.
                    if config.glyphAppear != .none, let p = appearProgress(row: row, col: col) {
                        inst = config.glyphAppear.apply(to: inst, appearing: true, p: p)
                    }
                    if region.isColor { colorGlyphs.append(inst) } else { glyphs.append(inst) }
                }

                // Line overlays. Underline color precedence (matching legacy):
                // hover blue > hyperlink fg α0.5 > SGR-underline fg. Strikethrough
                // is independent (cell fg), drawn through the glyph centre.
                let hovered = hover?.contains(col) ?? false
                if cell.attrs.underline || cell.attrs.strikethrough || cell.hyperlink != nil || hovered {
                    let thickness = max(1, (cellH * 0.08).rounded())
                    // SGR-underline uses the cell's display fg (incl. cursor/find/
                    // hover overrides) → same rgba as the glyph.
                    var underlineColor: SIMD4<Float>? = cell.attrs.underline ? fgRGBAColor : nil
                    if cell.hyperlink != nil {
                        // Hyperlink underline = the cell's OWN resolved fg at α0.5,
                        // ignoring overrides (matches legacy).
                        var c = (cell.attrs.faint || cell.attrs.inverse)
                            ? rgba(cell.attrs.resolvedColors(theme: config.theme).fg)
                            : baseRGBA(cell.attrs.fg)
                        c.w = 0.5
                        underlineColor = c
                    }
                    if hovered { underlineColor = rgba(.systemBlue) }
                    if let uc = underlineColor {
                        let uy = snap(y1 - thickness)
                        overlay.append(BgInstance(origin: SIMD2<Float>(Float(x0), Float(uy)),
                                                  size: SIMD2<Float>(Float(x1 - x0), Float(y1 - uy)),
                                                  color: uc))
                    }
                    if cell.attrs.strikethrough {
                        let sy = snap(y0 + (y1 - y0) * 0.5 - thickness * 0.5)
                        overlay.append(BgInstance(origin: SIMD2<Float>(Float(x0), Float(sy)),
                                                  size: SIMD2<Float>(Float(x1 - x0), Float(thickness)),
                                                  color: fgRGBAColor))
                    }
                }
            }
        }
        if imeActive {
            appendIMEComposition(markedText: state.markedText, row: imeRow,
                                 startCol: grid.cursorCol, gridCols: grid.cols,
                                 map: map, bg: &bg, glyphs: &glyphs, colorGlyphs: &colorGlyphs)
        }
        // Disappear animation: remember characters no longer in the grid and fade/collapse them as ghosts.
        if config.glyphDisappear != .none, !glyphAnims.isEmpty {
            appendDisappearingGlyphs(first: first, last: last, glyphs: &glyphs,
                                     colorGlyphs: &colorGlyphs)
        }
        if config.showScrollbar { appendScrollbar(into: &overlay) }
        return (bg, glyphs, colorGlyphs, overlay)
    }

    /// Draw ghost glyphs from remembered cells for characters that left the grid, producing the disappear animation.
    private func appendDisappearingGlyphs(first: Int, last: Int,
                                          glyphs: inout [GlyphInstance],
                                          colorGlyphs: inout [GlyphInstance]) {
        let now = CACurrentMediaTime()
        for (pos, a) in glyphAnims where !a.appearing {
            guard pos.row >= first, pos.row <= last, a.cell.char != " " else { continue }
            let p = Float((now - a.start) / a.duration)
            guard p < 1 else { continue }
            let style = a.style
            let wide = Cell.isWide(a.cell.char)
            let x0 = snap(inset.width + CGFloat(pos.col) * metrics.width)
            let x1 = snap(inset.width + CGFloat(pos.col + (wide ? 2 : 1)) * metrics.width)
            let y0 = snap(inset.height + CGFloat(pos.row) * metrics.height) - scrollY
            let y1 = snap(inset.height + CGFloat(pos.row + 1) * metrics.height) - scrollY
            guard let region = atlas?.region(for: a.cell.char, bold: a.cell.attrs.bold, wide: wide)
            else { continue }
            let fg = a.cell.attrs.resolvedColors(theme: config.theme).fg
            var inst = GlyphInstance(origin: SIMD2<Float>(Float(x0), Float(y0)),
                                     size: SIMD2<Float>(Float(x1 - x0), Float(y1 - y0)),
                                     uvOrigin: region.uv.origin, uvSize: region.uv.size,
                                     color: rgba(fg))
            inst = style.apply(to: inst, appearing: false, p: max(0, min(1, p)))
            if region.isColor { colorGlyphs.append(inst) } else { glyphs.append(inst) }

            // Burst: tiny rainbow stars burst outward like fireworks.
            if style == .burst {
                appendBurstParticles(centerX: CGFloat(x0 + x1) / 2,
                                     centerY: CGFloat(y0 + y1) / 2,
                                     seedRow: pos.row, seedCol: pos.col,
                                     p: max(0, min(1, p)), into: &glyphs)
            }
        }
    }

    /// Emit K star particles for the burst effect. Direction/speed are derived from
    /// a (row,col,i) hash (consistent frame to frame). They spread fast then slow via
    /// easeOut, drop slightly under gravity, and fade out.
    private func appendBurstParticles(centerX: CGFloat, centerY: CGFloat,
                                      seedRow: Int, seedCol: Int, p: Float,
                                      into glyphs: inout [GlyphInstance]) {
        // "*" (asterisk) — a monochrome glyph reliably present in every font. (✦ and
        // such rasterized to a blank and didn't show when the font lacked them.)
        guard let star = atlas?.region(for: "*", bold: true, wide: false), !star.isColor
        else { return }
        let cellH = max(metrics.height, 1)
        let count = 7
        let eased = 1 - (1 - p) * (1 - p)            // easeOut
        let maxDist = cellH * 2.4
        let starBase = cellH * 0.5
        func hashf(_ i: Int, _ salt: Int) -> Float {
            let v = sin(Float(seedRow * 73 + seedCol * 131 + i * 977 + salt * 17)
                        * 12.9898) * 43758.5453
            return v - floor(v)                       // 0..1
        }
        for i in 0..<count {
            let angle = (Float(i) / Float(count) + hashf(i, 1) * 0.12) * 2 * .pi
            let speed = 0.6 + 0.4 * hashf(i, 2)       // 0.6..1.0
            let dist = CGFloat(eased * speed) * maxDist
            let gravity = cellH * 1.1 * CGFloat(p * p)
            let px = centerX + CGFloat(cos(angle)) * dist
            let py = centerY + CGFloat(sin(angle)) * dist + gravity
            let sz = starBase * CGFloat(1 - 0.45 * p)
            guard sz > 0.5 else { continue }
            let alpha = CGFloat(max(0, 1 - p))        // fade as it flies out
            let hue = CGFloat(hashf(i, 3))
            let color = NSColor(hue: hue, saturation: 0.85, brightness: 1, alpha: 1)
            var rgbaColor = rgba(color)
            rgbaColor.w = Float(alpha)
            glyphs.append(GlyphInstance(
                origin: SIMD2<Float>(Float(px - sz / 2), Float(py - sz / 2)),
                size: SIMD2<Float>(Float(sz), Float(sz)),
                uvOrigin: star.uv.origin, uvSize: star.uv.size, color: rgbaColor))
        }
    }

    /// Draw the IME composing text at the cursor, cell-aligned, with the
    /// configured style (underline / background). Mirrors the legacy overlay.
    private func appendIMEComposition(markedText: String, row: Int, startCol: Int,
                                      gridCols: Int, map: CoordinateMap,
                                      bg: inout [BgInstance], glyphs: inout [GlyphInstance],
                                      colorGlyphs: inout [GlyphInstance]) {
        let style = config.imeStyle
        var col = startCol
        for ch in markedText {
            guard col < gridCols else { break }
            let wide = Cell.isWide(ch)
            let w = wide ? 2 : 1
            let rect = map.cellRectInView(row: row, col: col)
            let cellWpts = CGFloat(w) * metrics.width
            let origin = SIMD2<Float>(Float(rect.origin.x), Float(rect.origin.y))
            let size = SIMD2<Float>(Float(cellWpts), Float(rect.height))

            var fg = config.foregroundColor
            switch style {
            case .background:
                bg.append(BgInstance(origin: origin, size: size,
                                     color: rgba(NSColor.systemBlue.withAlphaComponent(0.45))))
                fg = .white
            case .both:
                bg.append(BgInstance(origin: origin, size: size,
                                     color: rgba(NSColor.systemBlue.withAlphaComponent(0.65))))
                fg = .white
            case .underline, .thickUnderline, .none:
                break
            }

            if ch != " ", let region = atlas?.region(for: ch, bold: false, wide: wide) {
                let inst = GlyphInstance(origin: origin, size: size,
                                         uvOrigin: region.uv.origin, uvSize: region.uv.size,
                                         color: rgba(fg))
                if region.isColor { colorGlyphs.append(inst) } else { glyphs.append(inst) }
            }

            let underline: (color: NSColor, thickness: CGFloat)?
            switch style {
            case .underline:
                underline = (config.foregroundColor.withAlphaComponent(0.7), max(1.5, rect.height * 0.06))
            case .thickUnderline, .both:
                underline = (config.foregroundColor, max(2, rect.height * 0.1))
            case .background, .none:
                underline = nil
            }
            if let u = underline {
                let uy = rect.maxY - u.thickness
                bg.append(BgInstance(origin: SIMD2<Float>(Float(rect.origin.x), Float(uy)),
                                     size: SIMD2<Float>(Float(cellWpts), Float(u.thickness)),
                                     color: rgba(u.color)))
            }
            col += w
        }
    }

    /// Append a right-edge scroll-position indicator (thumb) to the overlay pass.
    /// Overlay-style: thumb only, shown only when content exceeds the viewport;
    /// height ∝ visible fraction, position ∝ scroll offset. Display-only (not yet
    /// draggable).
    private func appendScrollbar(into overlay: inout [BgInstance]) {
        let viewportH = metalView.bounds.height
        let contentH = contentHeight
        guard viewportH > 1, contentH > viewportH + 1 else { return }   // nothing to scroll

        let barW: CGFloat = 6, rightInset: CGFloat = 2
        let trackTop = inset.height
        let trackH = max(viewportH - inset.height * 2, 1)
        let visibleFraction = min(viewportH / contentH, 1)
        let thumbH = max(24, trackH * visibleFraction)
        let maxScroll = max(contentH - viewportH, 1)
        let t = min(max(scrollY / maxScroll, 0), 1)
        let thumbY = snap(trackTop + (trackH - thumbH) * t)
        let x = snap(metalView.bounds.width - barW - rightInset)

        let color = config.foregroundColor.withAlphaComponent(0.35)
        overlay.append(BgInstance(origin: SIMD2<Float>(Float(x), Float(thumbY)),
                                  size: SIMD2<Float>(Float(barW), Float(snap(thumbH))),
                                  color: rgba(color)))
    }

    // fg/bg color resolution → see `fgRGBA` / `bgRGBA` (rgba-returning, cached).

    private func cellsForRow(grid: Grid, unifiedRow: Int) -> [Cell] {
        let sc = grid.scrollback.count
        if unifiedRow < sc { return grid.scrollback[unifiedRow].cells }
        let vp = unifiedRow - sc
        return (vp >= 0 && vp < grid.rows) ? grid.row(vp) : []
    }

    private func selectedColumns(_ state: RenderState, row: Int, cols: Int) -> Range<Int>? {
        guard let a = state.selectionAnchor, let h = state.selectionHead,
              !(a.row == h.row && a.col == h.col) else { return nil }
        let start = (a.row < h.row || (a.row == h.row && a.col < h.col)) ? a : h
        let end = (start.row == a.row && start.col == a.col) ? h : a
        if row < start.row || row > end.row { return nil }
        if state.selectionRectangular {
            // Block selection: the same column span on every covered row.
            return SelectionLogic.blockColumns(anchorCol: a.col, headCol: h.col, cols: cols)
        }
        let lo = (row == start.row) ? start.col : 0
        let hi = (row == end.row) ? min(end.col, cols) : cols
        return lo < hi ? lo..<hi : nil
    }

    // MARK: - Cursor overlay (underline/bar — host draws on its own layer)

    /// The block cursor, drawn as a separate pass on top of the cached base
    /// frame: a `cursorColor` fill plus the cursor cell's glyph re-drawn in the
    /// background color (the classic inverted-cell look). Same atlas/pipeline as
    /// every other glyph, so the character never shifts between blink phases.
    /// Returns nil when there's no block cursor to draw (other shapes use the
    /// CALayer overlay; blink-off / IME / hidden / off-screen → nothing).
    private func cursorDrawData(grid: Grid, state: RenderState)
        -> (bg: BgInstance, glyph: GlyphInstance?, glyphIsColor: Bool)? {
        guard grid.cursorVisible, grid.cursorShape == .block, state.markedText.isEmpty
        else { return nil }
        if state.cursorBlinkEnabled && !state.cursorBlinkVisible { return nil }

        let row = grid.scrollback.count + grid.cursorRow
        let col = grid.cursorCol
        let r = grid.row(grid.cursorRow)
        let wide = col + 1 < r.count && r[col + 1].isContinuation
        let wcells = wide ? 2 : 1
        let x0 = snap(inset.width + CGFloat(col) * metrics.width)
        let x1 = snap(inset.width + CGFloat(col + wcells) * metrics.width)
        let y0 = snap(inset.height + CGFloat(row) * metrics.height) - scrollY
        let y1 = snap(inset.height + CGFloat(row + 1) * metrics.height) - scrollY
        // Off-screen (scrolled into history) → nothing to draw.
        guard y1 > 0, y0 < metalView.bounds.height else { return nil }
        let origin = SIMD2<Float>(Float(x0), Float(y0))
        let size = SIMD2<Float>(Float(x1 - x0), Float(y1 - y0))
        let bg = BgInstance(origin: origin, size: size, color: rgba(config.cursorColor))

        guard col < r.count else { return (bg, nil, false) }
        let cell = r[col]
        guard cell.char != " ", let region = atlas?.region(for: cell.char, bold: cell.attrs.bold, wide: wide)
        else { return (bg, nil, false) }
        var gOrigin = origin, gSize = size
        if region.overflowCells > 0 {
            let half = region.overflowCells * metrics.width / 2
            let gx0 = snap(inset.width + CGFloat(col) * metrics.width - half)
            let gx1 = snap(inset.width + CGFloat(col + wcells) * metrics.width + half)
            gOrigin = SIMD2<Float>(Float(gx0), Float(y0))
            gSize = SIMD2<Float>(Float(gx1 - gx0), Float(y1 - y0))
        }
        // Inverted glyph color = the terminal background (matches the old baked
        // fgRGBA(isCursor:) path). Color emoji ignore the tint (drawn as-is).
        let glyph = GlyphInstance(origin: gOrigin, size: gSize,
                                  uvOrigin: region.uv.origin, uvSize: region.uv.size,
                                  color: rgba(config.theme.background))
        return (bg, glyph, region.isColor)
    }

    /// Cheap signature of the render state that affects the base frame (cursor
    /// excluded). When this and the geometry/version match the cache, the base
    /// buffers are reused. NOT included: the cursor blink phase (that's the whole
    /// point) and the cursor position.
    private func baseStateKey(_ state: RenderState) -> String {
        var k = state.markedText + "|"
        if let a = state.selectionAnchor { k += "\(a.row),\(a.col)" }
        k += ">"
        if let h = state.selectionHead { k += "\(h.row),\(h.col)" }
        k += state.selectionRectangular ? "R|" : "|"
        if let r = state.activeFindRow, let rng = state.activeFindRange { k += "\(r):\(rng.lowerBound)-\(rng.upperBound)" }
        k += "|f\(state.findMatchesByRow.count)|h\(state.hoveredSegments.count)"
        for (row, seg) in state.hoveredSegments.sorted(by: { $0.key < $1.key }) {
            k += ";\(row):\(seg.lowerBound)-\(seg.upperBound)"
        }
        return k
    }

    /// Encode the block-cursor pass (cursorColor fill + inverted glyph) into an
    /// in-flight encoder. Shared by the live render and the offscreen capture so
    /// both show the cursor identically. No-op when there's no block cursor.
    private func encodeCursorPass(enc: MTLRenderCommandEncoder, uniforms: inout Uniforms,
                                  grid: Grid, state: RenderState) {
        guard let cur = cursorDrawData(grid: grid, state: state) else { return }
        if let b = withUnsafeBytes(of: cur.bg, {
            md.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) {
            enc.setRenderPipelineState(md.bgPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(b, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        }
        guard let g = cur.glyph,
              let tex = cur.glyphIsColor ? atlas?.colorTexture : atlas?.texture,
              let b = withUnsafeBytes(of: g, {
                  md.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
              }) else { return }
        enc.setRenderPipelineState(cur.glyphIsColor ? md.colorGlyphPipeline : md.glyphPipeline)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setVertexBuffer(b, offset: 0, index: 1)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(md.glyphSampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
    }

    func cursorOverlay(grid: Grid, config: DamsonConfig, state: RenderState, metrics: CellMetrics) -> CursorOverlay? {
        let shape = grid.cursorShape
        let blinkOff = state.cursorBlinkEnabled && !state.cursorBlinkVisible
        guard grid.cursorVisible, shape != .block, state.markedText.isEmpty, !blinkOff,
              let host = metalView.superview else { return nil }
        let map = coordMap()
        let row = grid.scrollback.count + grid.cursorRow
        let cell = map.cellRectInView(row: row, col: grid.cursorCol)
        guard metalView.bounds.intersects(cell) else { return nil }

        let cw = max(metrics.width, 1), ch = max(metrics.height, 1)
        var cursorW = cw
        if grid.cursorCol + 1 < grid.cols && grid.cursorRow < grid.rows {
            let r = grid.row(grid.cursorRow)
            if grid.cursorCol + 1 < r.count && r[grid.cursorCol + 1].isContinuation { cursorW = cw * 2 }
        }

        // Strip in flipped view coords, then convert to the host's (non-flipped) layer.
        let stripInView: NSRect
        switch shape {
        case .underline:
            let t = max(1.5, ch * 0.1)
            stripInView = NSRect(x: cell.minX, y: cell.maxY - t, width: cursorW, height: t)
        case .bar:
            let t = max(1.5, cw * 0.15)
            stripInView = NSRect(x: cell.minX, y: cell.minY, width: t, height: ch)
        case .block:
            return nil
        }
        let frameInHost = metalView.convert(stripInView, to: host)
        return CursorOverlay(frame: frameInHost, color: config.cursorColor)
    }

    // MARK: - Geometry (window coordinate space)

    func cell(at pointInHost: NSPoint, grid: Grid, metrics: CellMetrics) -> GridPos {
        let inView = metalView.convert(pointInHost, from: nil)
        let p = coordMap().cell(atViewPoint: inView)
        let maxRow = grid.scrollback.count + grid.rows - 1
        return GridPos(row: max(0, min(p.row, maxRow)), col: max(0, min(p.col, grid.cols)))
    }

    func cursorScreenRect(grid: Grid, metrics: CellMetrics, window: NSWindow) -> NSRect {
        let row = grid.scrollback.count + grid.cursorRow
        let cell = coordMap().cellRectInView(row: row, col: grid.cursorCol)
        let inWindow = metalView.convert(cell, to: nil)
        return window.convertToScreen(inWindow)
    }

    // MARK: - Scroll primitives

    var scrollYPixels: CGFloat { scrollY }
    var contentHeight: CGFloat { CGFloat(lastTotalRows) * max(metrics.height, 1) + inset.height * 2 }
    var viewportHeight: CGFloat { metalView.bounds.height }

    /// Jump to `y` and refresh scroll geometry WITHOUT presenting a frame. The
    /// caller renders immediately after, so the followed position lands in that one
    /// frame. `totalRows` primes `lastTotalRows` (which `render()` normally sets)
    /// so the maxY clamp matches the content height of the frame about to be drawn.
    func alignScroll(to y: CGFloat, totalRows: Int) {
        lastTotalRows = totalRows
        scroll.maxY = max(0, contentHeight - viewportHeight)
        animLink.stop()              // a hard jump cancels any in-flight ease
        scroll.jump(to: y)
        onScrollGeometryChanged?()
    }

    func setScrollY(_ y: CGFloat, animated: Bool) {
        scroll.maxY = max(0, contentHeight - viewportHeight)
        guard animated else {
            // Hard jump cancels any in-flight ease.
            animLink.stop()
            scroll.jump(to: y)
            redrawLast()
            onScrollGeometryChanged?()
            return
        }
        // Smooth ease toward the target, stepped by the unified vsync render loop.
        scroll.animate(to: y)
        guard scroll.animating else {        // already at target
            redrawLast()
            onScrollGeometryChanged?()
            return
        }
        ensureRenderLoop()
    }

    /// Consume a wheel/trackpad event: apply its delta and redraw. macOS delivers
    /// the gesture + a decaying momentum stream, so this yields smooth scroll +
    /// momentum without simulating a spring. A trackpad gesture past an edge
    /// rubber-bands (overshoot with resistance) and springs back when the gesture
    /// (and its momentum) ends. Always returns true (Metal owns the wheel; the host
    /// won't fall through to a no-op `super.scrollWheel`).
    func handleScrollWheel(_ event: NSEvent) -> Bool {
        scroll.maxY = max(0, contentHeight - viewportHeight)
        // applyWheel sets animating=false to cancel any in-flight ease (direct input wins).
        let moved = scroll.applyWheel(deltaY: event.scrollingDeltaY,
                                      precise: event.hasPreciseScrollingDeltas,
                                      lineHeight: max(metrics.height, 1),
                                      viewport: viewportHeight)
        if moved {
            // Request a vsync-aligned render instead of a synchronous one — uniform frame intervals make it smooth.
            scrollRenderPending = true
            ensureRenderLoop()
            onUserScroll?()              // host updates followingBottom
        }
        // Spring a rubber-band overshoot back to the edge once the gesture ends.
        // (A following momentum event cancels this ease via animLink.stop above and
        // re-overshoots, so the final spring fires on momentumPhase .ended.)
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
        if ended && scroll.isOvershooting {
            setScrollY(scroll.clamp(scroll.current), animated: true)
        }
        return true
    }

    func ensureLayout() {}      // Metal has no async text layout to flush.
    func reflectScroll() {}     // No NSScroller to sync.

    // MARK: - Color

    /// Ensure the offscreen scene texture for screen effects matches the drawable
    /// size (recreate it if missing or sized differently). Same pixel format as the
    /// drawable + render target / shader read.
    private func ensureSceneTexture(matching target: MTLTexture) -> MTLTexture {
        if let t = sceneTexture, t.width == target.width, t.height == target.height {
            return t
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalDevice.pixelFormat,
            width: max(1, target.width), height: max(1, target.height), mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        let tex = md.device.makeTexture(descriptor: td)!
        sceneTexture = tex
        return tex
    }

    /// post-fx pass descriptor. The fullscreen triangle overwrites every pixel, so loadAction is dontCare.
    private func postfxPass(_ drawable: MTLTexture) -> MTLRenderPassDescriptor {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = drawable
        p.colorAttachments[0].loadAction = .dontCare
        p.colorAttachments[0].storeAction = .store
        return p
    }

    /// Background clear color. When `opacity` < 1, produce a premultiplied
    /// transparent background (rgb×O, a=O) so the layer composites with what's behind
    /// (desktop/blur). At opacity=1 it's unchanged (opaque).
    private func clearColor(_ c: NSColor, opacity: CGFloat = 1.0) -> MTLClearColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        let o = Double(max(0, min(1, opacity)))
        return MTLClearColor(red: Double(s.redComponent) * o, green: Double(s.greenComponent) * o,
                             blue: Double(s.blueComponent) * o, alpha: o)
    }

    /// Multiply opacity into the alpha of background fill instances
    /// (background/selection/cursor) only. Text, emoji, and underline overlays are
    /// left untouched so they stay opaque. At opacity=1, return the input as-is.
    private func fadeBackgrounds(_ insts: [BgInstance], opacity: CGFloat) -> [BgInstance] {
        guard opacity < 1.0 else { return insts }
        let o = Float(max(0, min(1, opacity)))
        return insts.map { inst in
            var m = inst
            m.color.w *= o
            return m
        }
    }

    private func rgba(_ c: NSColor) -> SIMD4<Float> {
        let s = c.usingColorSpace(.sRGB) ?? c
        return SIMD4<Float>(Float(s.redComponent), Float(s.greenComponent),
                            Float(s.blueComponent), Float(s.alphaComponent))
    }

    /// Cached `TermColor` → premultiplied-free sRGB rgba. Without this, every
    /// visible cell re-ran `theme.nsColor(...)` (allocating a fresh NSColor for
    /// palette/cube/truecolor) and `usingColorSpace(.sRGB)` (a tagged-color
    /// space conversion) every frame — the dominant cost while a busy terminal
    /// streams output (profiled hot path). Keyed by `TermColor` only, so it's
    /// theme-dependent: cleared whenever the config (theme) changes. Bounded —
    /// only `.default` + `.palette(0…255)` are stored (≤257 entries); `.rgb` is
    /// computed directly (no NSColor, no store) since truecolor is unbounded.
    private var rgbaCache: [TermColor: SIMD4<Float>] = [:]

    private func baseRGBA(_ c: TermColor) -> SIMD4<Float> {
        if case .rgb(let r, let g, let b) = c {
            return SIMD4<Float>(Float(r) / 255, Float(g) / 255, Float(b) / 255, 1)
        }
        if let hit = rgbaCache[c] { return hit }
        let v = rgba(config.theme.nsColor(c))
        rgbaCache[c] = v
        return v
    }

    /// Foreground rgba for a cell — the per-glyph hot path. Mirrors `fgColor`
    /// but returns rgba directly, routing the common case (no faint/inverse,
    /// no cursor/find/hover override) through `baseRGBA`'s cache. The rare
    /// overrides keep the exact `fgColor` semantics via the NSColor path.
    private func fgRGBA(cell: Cell, col: Int, sel: Range<Int>?, finds: [Range<Int>],
                        activeFind: Range<Int>?, hover: Range<Int>?, isCursor: Bool) -> SIMD4<Float> {
        if isCursor { return rgba(config.theme.background) }
        if sel?.contains(col) ?? false {
            // Reverse-video selection (pairs with bgRGBA): text takes the cell's bg.
            return rgba(cell.attrs.resolvedColors(theme: config.theme).bg ?? config.theme.background)
        }
        if hover?.contains(col) ?? false { return rgba(.systemBlue) }
        if (activeFind?.contains(col) ?? false) || finds.contains(where: { $0.contains(col) }) {
            return rgba(.black)
        }
        let a = cell.attrs
        if !a.faint && !a.inverse { return baseRGBA(a.fg) }
        return rgba(a.resolvedColors(theme: config.theme).fg)   // faint/inverse: rare
    }

    /// Background fill rgba for a cell (nil = transparent). Mirrors `bgColor`,
    /// cache-fast for the common cell-bg case.
    private func bgRGBA(cell: Cell, col: Int, sel: Range<Int>?, finds: [Range<Int>],
                        activeFind: Range<Int>?, isCursor: Bool) -> SIMD4<Float>? {
        if isCursor { return rgba(config.cursorColor) }
        if sel?.contains(col) ?? false {
            // Reverse-video selection: the highlight takes the cell's own text color
            // (paired with fgRGBA handing the cell's bg to the text). Contrast is
            // always the cell's own, so selected text stays readable on ANY theme —
            // unlike the system selectedTextBackgroundColor, a light blue tuned for
            // black-on-white documents that washed out on dark terminal themes.
            return rgba(cell.attrs.resolvedColors(theme: config.theme).fg)
        }
        if activeFind?.contains(col) ?? false { return rgba(NSColor.systemOrange.withAlphaComponent(0.85)) }
        if finds.contains(where: { $0.contains(col) }) { return rgba(NSColor.systemYellow.withAlphaComponent(0.6)) }
        let a = cell.attrs
        if !a.faint && !a.inverse {
            guard let bg = a.bg else { return nil }
            return baseRGBA(bg)
        }
        // faint/inverse: rare — exact NSColor semantics (inverse promotes fg→bg).
        guard let bg = a.resolvedColors(theme: config.theme).bg else { return nil }
        return rgba(bg)
    }

    /// Capture the current on-screen frame as a `CGImage` by re-rendering the
    /// last grid/state at the live view size + scroll into an offscreen texture.
    /// `cacheDisplay` can't read a `CAMetalLayer` framebuffer, so tab/pane
    /// transition snapshots route through here instead of going blank.
    func captureImage() -> CGImage? {
        guard let grid = lastGrid else { return nil }
        return offscreenImage(scale: metalView.metalLayer.contentsScale,
                              grid: grid, state: lastState)
    }

    /// Render `grid`/`state` through the real `buildInstances` + shader passes
    /// into an offscreen texture sized to the current `metalView` bounds, then
    /// read it back as a `CGImage`. No window, no drawable, no Screen Recording.
    /// Uses the live `scrollY`/`metrics`, so the bitmap matches what's on screen.
    private func offscreenImage(scale: CGFloat, grid: Grid, state: RenderState) -> CGImage? {
        let wPts = metalView.bounds.width, hPts = metalView.bounds.height
        guard wPts > 0, hPts > 0 else { return nil }
        metalView.metalLayer.contentsScale = scale
        ensureAtlas()

        let pw = max(1, Int((wPts * scale).rounded()))
        let ph = max(1, Int((hPts * scale).rounded()))
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalDevice.pixelFormat, width: pw, height: ph, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = md.device.makeTexture(descriptor: td) else { return nil }

        let (bg, glyphs, colorGlyphs, overlay) = buildInstances(grid: grid, state: state)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor(config.theme.background)
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = md.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = Uniforms(viewportSize: SIMD2<Float>(Float(wPts), Float(hPts)))

        func drawBg(_ insts: [BgInstance]) {
            guard !insts.isEmpty,
                  let buf = md.device.makeBuffer(bytes: insts,
                                                 length: MemoryLayout<BgInstance>.stride * insts.count,
                                                 options: .storageModeShared) else { return }
            enc.setRenderPipelineState(md.bgPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: insts.count)
        }
        func drawGlyphs(_ insts: [GlyphInstance], pipeline: MTLRenderPipelineState, texture: MTLTexture?) {
            guard !insts.isEmpty, let texture,
                  let buf = md.device.makeBuffer(bytes: insts,
                                                 length: MemoryLayout<GlyphInstance>.stride * insts.count,
                                                 options: .storageModeShared) else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(md.glyphSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: insts.count)
        }
        drawBg(bg)
        drawGlyphs(glyphs, pipeline: md.glyphPipeline, texture: atlas?.texture)
        drawGlyphs(colorGlyphs, pipeline: md.colorGlyphPipeline, texture: atlas?.colorTexture)
        drawBg(overlay)
        // Block cursor (separate pass, like the live render) — keeps captures faithful.
        encodeCursorPass(enc: enc, uniforms: &uniforms, grid: grid, state: state)
        enc.endEncoding()

        // Screen effect: run the same fullscreen post-fx pass as on-screen
        // rendering (into a second texture — a pass can't sample its own
        // target), so captures match the display. Animated effects use the
        // live clock, or `effectTimeOverride` for deterministic test shots.
        var outTex = tex
        let effect = config.screenEffect
        if effect.isActive,
           var params = effect.postFXParams(
               screenSize: SIMD2<Float>(Float(pw), Float(ph)),
               intensity: Float(config.screenEffectIntensity)),
           let fxTex = md.device.makeTexture(descriptor: td),
           let fxEnc = cmd.makeRenderCommandEncoder(descriptor: postfxPass(fxTex)) {
            let bgc = clearColor(config.theme.background)
            params.bgColor = SIMD4<Float>(Float(bgc.red), Float(bgc.green),
                                          Float(bgc.blue), Float(bgc.alpha))
            params.coeffs4.x = effectTime
            fxEnc.setRenderPipelineState(md.postfxPipeline)
            fxEnc.setFragmentTexture(tex, index: 0)
            fxEnc.setFragmentSamplerState(md.glyphSampler, index: 0)
            fxEnc.setFragmentBytes(&params, length: MemoryLayout<PostFXParams>.stride, index: 0)
            fxEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            fxEnc.endEncoding()
            outTex = fxTex
        }

        cmd.commit()
        cmd.waitUntilCompleted()

        let bytesPerRow = pw * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * ph)
        outTex.getBytes(&raw, bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(raw) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // bgra8Unorm in memory == little-endian 32-bit with alpha first → BGRA.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    #if DEBUG
    /// Headless render-parity capture for the smoke test: size the window-less
    /// view to `cols`×`rows`, set the grid, and render from the top via the same
    /// offscreen path the live capture uses.
    func renderToCGImage(grid: Grid, config: DamsonConfig, state: RenderState,
                         metrics: CellMetrics, cols: Int, rows: Int, scale: CGFloat) -> CGImage? {
        self.config = config
        self.metrics = metrics
        let wPts = inset.width * 2 + CGFloat(cols) * metrics.width
        let hPts = inset.height * 2 + CGFloat(rows) * metrics.height
        metalView.frame = NSRect(x: 0, y: 0, width: wPts, height: hPts)
        self.lastGrid = grid
        self.lastState = state
        self.lastTotalRows = grid.scrollback.count + grid.rows
        return offscreenImage(scale: scale, grid: grid, state: state)
    }
    #endif
}

