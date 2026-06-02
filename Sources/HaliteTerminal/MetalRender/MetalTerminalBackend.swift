import AppKit
import Metal
import simd

/// Phase 1 Metal backend: a `CAMetalLayer` renderer that draws cell backgrounds,
/// selection/find highlights, and the block cursor as instanced filled quads —
/// proving layer hosting, the shader pipeline, grid reading, the coordinate map
/// (mouse hit + IME cursor-rect), scalar scroll, and stable cellMetrics. Glyph
/// text is the next step; until then characters are invisible (backgrounds and
/// the block cursor are visible).
///
/// Selected behind the `HALITE_METAL=1` toggle; the legacy backend is the default
/// and the live fallback.
final class MetalTerminalBackend: TerminalRenderBackend {
    private let metalView = MetalContentView(frame: .zero)
    private let md: MetalDevice

    private(set) var renderFont: NSFont
    private var config: HaliteConfig
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
    private let inset = NSSize(width: 4, height: 4)

    /// Glyph atlas, rebuilt when font / cell size / backing scale changes.
    private var atlas: GlyphAtlas?
    private var atlasSignature = ""

    private func ensureAtlas() {
        let scale = metalView.metalLayer.contentsScale
        let sig = "\(renderFont.fontName)|\(renderFont.pointSize)|\(metrics.width)|\(metrics.height)|\(scale)"
        if sig != atlasSignature || atlas == nil {
            atlas = GlyphAtlas(device: md.device, font: renderFont,
                               cellW: metrics.width, cellH: metrics.height, scale: scale)
            atlasSignature = sig
        }
    }

    init?(config: HaliteConfig) {
        guard let md = MetalDevice.shared else { return nil }
        self.md = md
        self.config = config
        self.renderFont = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        metalView.onNeedsDisplay = { [weak self] in self?.redrawLast() }
    }

    // MARK: - TerminalRenderBackend

    var contentView: NSView { metalView }
    // No native scroller — full bounds is usable. (May differ from legacy by the
    // scroller width; a one-time reflow on toggle is acceptable for the dev path.)
    var contentSize: NSSize { metalView.bounds.size }
    var contentInset: NSSize { inset }

    func applyConfig(_ config: HaliteConfig) {
        self.config = config
        renderFont = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        redrawLast()
    }

    func setRenderFont(_ font: NSFont) {
        renderFont = font
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
        render(grid: grid, config: config, state: lastState, metrics: metrics)
    }

    func render(grid: Grid, config: HaliteConfig, state: RenderState, metrics: CellMetrics) {
        self.config = config
        self.metrics = metrics
        self.lastGrid = grid
        self.lastState = state
        self.lastTotalRows = grid.scrollback.count + grid.rows
        // Keep the scroll clamp current as content grows/shrinks (re-clamps if the
        // viewport now extends past the new bottom).
        scroll.maxY = max(0, contentHeight - viewportHeight)

        ensureAtlas()
        let layer = metalView.metalLayer
        guard layer.drawableSize.width > 0, let drawable = layer.nextDrawable() else { return }

        let (bgInstances, glyphInstances, colorGlyphInstances, overlayInstances) =
            buildInstances(grid: grid, state: state)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor(config.theme.background)
        pass.colorAttachments[0].storeAction = .store

        guard let cmd = md.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(viewportSize: SIMD2<Float>(Float(metalView.bounds.width),
                                                           Float(metalView.bounds.height)))

        // Pass 1: cell backgrounds / selection / find / block cursor.
        if !bgInstances.isEmpty,
           let buf = md.device.makeBuffer(bytes: bgInstances,
                                          length: MemoryLayout<BgInstance>.stride * bgInstances.count,
                                          options: .storageModeShared) {
            enc.setRenderPipelineState(md.bgPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: bgInstances.count)
        }

        // Pass 2: glyphs (coverage atlas modulated by fg color).
        if !glyphInstances.isEmpty, let atlas = atlas,
           let buf = md.device.makeBuffer(bytes: glyphInstances,
                                          length: MemoryLayout<GlyphInstance>.stride * glyphInstances.count,
                                          options: .storageModeShared) {
            enc.setRenderPipelineState(md.glyphPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(md.glyphSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: glyphInstances.count)
        }

        // Pass 2b: color emoji (premultiplied BGRA color page, fg ignored).
        if !colorGlyphInstances.isEmpty, let colorTex = atlas?.colorTexture,
           let buf = md.device.makeBuffer(bytes: colorGlyphInstances,
                                          length: MemoryLayout<GlyphInstance>.stride * colorGlyphInstances.count,
                                          options: .storageModeShared) {
            enc.setRenderPipelineState(md.colorGlyphPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.setFragmentTexture(colorTex, index: 0)
            enc.setFragmentSamplerState(md.glyphSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: colorGlyphInstances.count)
        }

        // Pass 3: line overlays (underline / strikethrough / hyperlink / hover) —
        // same filled-quad pipeline as bg, drawn ON TOP so strikethrough shows.
        if !overlayInstances.isEmpty,
           let buf = md.device.makeBuffer(bytes: overlayInstances,
                                          length: MemoryLayout<BgInstance>.stride * overlayInstances.count,
                                          options: .storageModeShared) {
            enc.setRenderPipelineState(md.bgPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: overlayInstances.count)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
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

        let blockCursorRow = grid.cursorVisible ? (grid.scrollback.count + grid.cursorRow) : -1
        let blinkOff = state.cursorBlinkEnabled && !state.cursorBlinkVisible
        let blockCursorOn = grid.cursorShape == .block && state.markedText.isEmpty && !blinkOff

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
            let hover: Range<Int>? = (state.hoveredRow == row) ? state.hoveredRange : nil
            for col in 0..<cols {
                let cell = cells[col]
                if cell.isContinuation { continue }
                if imeActive, row == imeRow, col >= grid.cursorCol, col < imeAfterCol { continue }
                let isCursor = (row == blockCursorRow && col == grid.cursorCol && blockCursorOn)
                let wide = (col + 1 < cols && cells[col + 1].isContinuation)
                let wcells = wide ? 2 : 1
                // Pixel-snap cell edges so adjacent cells share the exact same
                // boundary — kills the sub-pixel dark seam between powerline /
                // background fills caused by fractional cell width.
                let x0 = snap(inset.width + CGFloat(col) * metrics.width)
                let x1 = snap(inset.width + CGFloat(col + wcells) * metrics.width)
                let y0 = snap(inset.height + CGFloat(row) * metrics.height - scrollY)
                let y1 = snap(inset.height + CGFloat(row + 1) * metrics.height - scrollY)
                let origin = SIMD2<Float>(Float(x0), Float(y0))
                let size = SIMD2<Float>(Float(x1 - x0), Float(y1 - y0))

                if let color = bgColor(cell: cell, col: col, sel: sel, finds: finds,
                                       activeFind: activeFind, isCursor: isCursor) {
                    bg.append(BgInstance(origin: origin, size: size, color: rgba(color)))
                }
                let fg = fgColor(cell: cell, col: col, sel: sel, finds: finds,
                                 activeFind: activeFind, hover: hover, isCursor: isCursor)
                if cell.char != " ", let region = atlas?.region(for: cell.char, bold: cell.attrs.bold, wide: wide) {
                    let inst = GlyphInstance(origin: origin, size: size,
                                             uvOrigin: region.uv.origin, uvSize: region.uv.size,
                                             color: rgba(fg))
                    if region.isColor { colorGlyphs.append(inst) } else { glyphs.append(inst) }
                }

                // Line overlays. Underline color precedence (matching legacy):
                // hover blue > hyperlink fg α0.5 > SGR-underline fg. Strikethrough
                // is independent (cell fg), drawn through the glyph centre.
                let hovered = hover?.contains(col) ?? false
                if cell.attrs.underline || cell.attrs.strikethrough || cell.hyperlink != nil || hovered {
                    let thickness = max(1, (cellH * 0.08).rounded())
                    var underlineColor: NSColor? = cell.attrs.underline ? fg : nil
                    if cell.hyperlink != nil {
                        underlineColor = cell.attrs.resolvedColors(theme: config.theme).fg
                            .withAlphaComponent(0.5)
                    }
                    if hovered { underlineColor = .systemBlue }
                    if let uc = underlineColor {
                        let uy = snap(y1 - thickness)
                        overlay.append(BgInstance(origin: SIMD2<Float>(Float(x0), Float(uy)),
                                                  size: SIMD2<Float>(Float(x1 - x0), Float(y1 - uy)),
                                                  color: rgba(uc)))
                    }
                    if cell.attrs.strikethrough {
                        let sy = snap(y0 + (y1 - y0) * 0.5 - thickness * 0.5)
                        overlay.append(BgInstance(origin: SIMD2<Float>(Float(x0), Float(sy)),
                                                  size: SIMD2<Float>(Float(x1 - x0), Float(thickness)),
                                                  color: rgba(fg)))
                    }
                }
            }
        }
        if imeActive {
            appendIMEComposition(markedText: state.markedText, row: imeRow,
                                 startCol: grid.cursorCol, gridCols: grid.cols,
                                 map: map, bg: &bg, glyphs: &glyphs, colorGlyphs: &colorGlyphs)
        }
        return (bg, glyphs, colorGlyphs, overlay)
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

    /// Resolved glyph foreground, mirroring the legacy fg rules.
    private func fgColor(cell: Cell, col: Int, sel: Range<Int>?, finds: [Range<Int>],
                         activeFind: Range<Int>?, hover: Range<Int>?, isCursor: Bool) -> NSColor {
        if isCursor { return config.theme.background }   // inverse over the cursor block
        if hover?.contains(col) ?? false { return .systemBlue }
        if (activeFind?.contains(col) ?? false) || finds.contains(where: { $0.contains(col) }) {
            return .black
        }
        let (fg, _) = cell.attrs.resolvedColors(theme: config.theme)
        return fg
    }

    /// Resolved fill for a cell, honoring the legacy priority
    /// (cursor > selection > active-find > find > cell bg), or nil = clear.
    private func bgColor(cell: Cell, col: Int, sel: Range<Int>?, finds: [Range<Int>],
                         activeFind: Range<Int>?, isCursor: Bool) -> NSColor? {
        if isCursor { return config.cursorColor }
        if sel?.contains(col) ?? false { return .selectedTextBackgroundColor }
        if activeFind?.contains(col) ?? false { return NSColor.systemOrange.withAlphaComponent(0.85) }
        if finds.contains(where: { $0.contains(col) }) { return NSColor.systemYellow.withAlphaComponent(0.6) }
        let (_, bg) = cell.attrs.resolvedColors(theme: config.theme)
        return bg
    }

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
        let lo = (row == start.row) ? start.col : 0
        let hi = (row == end.row) ? min(end.col, cols) : cols
        return lo < hi ? lo..<hi : nil
    }

    // MARK: - Cursor overlay (underline/bar — host draws on its own layer)

    func cursorOverlay(grid: Grid, config: HaliteConfig, state: RenderState, metrics: CellMetrics) -> CursorOverlay? {
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
        // Smooth ease toward the target via a transient display link (macOS 14+).
        scroll.animate(to: y)
        guard scroll.animating else {        // already at target
            redrawLast()
            onScrollGeometryChanged?()
            return
        }
        let started = animLink.start { [weak self] dt in
            guard let self else { return true }
            let settled = self.scroll.step(dt: CGFloat(dt))
            self.redrawLast()
            self.onScrollGeometryChanged?()
            return settled
        }
        if !started {                        // macOS < 14: no display link → jump
            scroll.jump(to: y)
            redrawLast()
            onScrollGeometryChanged?()
        }
    }

    /// Consume a wheel/trackpad event: apply its delta and redraw. macOS delivers
    /// the gesture + a decaying momentum stream, so this yields smooth scroll +
    /// momentum without simulating a spring. A trackpad gesture past an edge
    /// rubber-bands (overshoot with resistance) and springs back when the gesture
    /// (and its momentum) ends. Always returns true (Metal owns the wheel; the host
    /// won't fall through to a no-op `super.scrollWheel`).
    func handleScrollWheel(_ event: NSEvent) -> Bool {
        animLink.stop()   // direct input cancels any in-flight programmatic ease
        scroll.maxY = max(0, contentHeight - viewportHeight)
        let moved = scroll.applyWheel(deltaY: event.scrollingDeltaY,
                                      precise: event.hasPreciseScrollingDeltas,
                                      lineHeight: max(metrics.height, 1),
                                      viewport: viewportHeight)
        if moved {
            redrawLast()
            onScrollGeometryChanged?()   // reposition cursor overlay
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

    private func clearColor(_ c: NSColor) -> MTLClearColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        return MTLClearColor(red: Double(s.redComponent), green: Double(s.greenComponent),
                             blue: Double(s.blueComponent), alpha: Double(s.alphaComponent))
    }

    private func rgba(_ c: NSColor) -> SIMD4<Float> {
        let s = c.usingColorSpace(.sRGB) ?? c
        return SIMD4<Float>(Float(s.redComponent), Float(s.greenComponent),
                            Float(s.blueComponent), Float(s.alphaComponent))
    }
}
