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

    /// Scalar vertical scroll offset (content px from top). P1 = non-animated.
    private var scrollY: CGFloat = 0
    /// Cached from the last render so `contentHeight` is correct between frames.
    private var lastTotalRows: Int = 0
    /// Snapshot of the last frame's inputs, so resize/backing-change redraws.
    private var lastGrid: Grid?
    private var lastState = RenderState()

    var onScrollGeometryChanged: (() -> Void)?
    var onUserScroll: (() -> Void)?

    /// The content inset, matched to the legacy textView's so cols/rows agree.
    private let inset = NSSize(width: 4, height: 4)

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

        let layer = metalView.metalLayer
        guard layer.drawableSize.width > 0, let drawable = layer.nextDrawable() else { return }

        let instances = buildInstances(grid: grid, state: state)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor(config.theme.background)
        pass.colorAttachments[0].storeAction = .store

        guard let cmd = md.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(md.bgPipeline)
        var uniforms = Uniforms(viewportSize: SIMD2<Float>(Float(metalView.bounds.width),
                                                           Float(metalView.bounds.height)))
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        if !instances.isEmpty,
           let buf = md.device.makeBuffer(bytes: instances,
                                          length: MemoryLayout<BgInstance>.stride * instances.count,
                                          options: .storageModeShared) {
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: instances.count)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Build bg/selection/find/cursor fill instances for the visible rows.
    private func buildInstances(grid: Grid, state: RenderState) -> [BgInstance] {
        let map = coordMap()
        let cellH = max(metrics.height, 1)
        let totalRows = grid.scrollback.count + grid.rows
        let h = metalView.bounds.height
        // Visible unified-row range.
        let first = max(0, Int(floor((scrollY - inset.height) / cellH)))
        let last = min(totalRows - 1, Int(ceil((scrollY + h - inset.height) / cellH)))
        guard first <= last else { return [] }

        var out: [BgInstance] = []
        out.reserveCapacity((last - first + 1) * max(grid.cols, 1))

        let blockCursorRow = grid.cursorVisible ? (grid.scrollback.count + grid.cursorRow) : -1
        let blinkOff = state.cursorBlinkEnabled && !state.cursorBlinkVisible
        let blockCursorOn = grid.cursorShape == .block && state.markedText.isEmpty && !blinkOff

        for row in first...last {
            let cells = cellsForRow(grid: grid, unifiedRow: row)
            let cols = cells.count
            guard cols > 0 else { continue }
            let sel = selectedColumns(state, row: row, cols: cols)
            let finds = state.findMatchesByRow[row] ?? []
            let activeFind: Range<Int>? = (state.activeFindRow == row) ? state.activeFindRange : nil
            for col in 0..<cols {
                if cells[col].isContinuation { continue }
                let isCursor = (row == blockCursorRow && col == grid.cursorCol && blockCursorOn)
                guard let color = bgColor(cell: cells[col], col: col, sel: sel, finds: finds,
                                          activeFind: activeFind, isCursor: isCursor) else { continue }
                let wide = (col + 1 < cols && cells[col + 1].isContinuation)
                let rect = map.cellRectInView(row: row, col: col)
                let w = wide ? metrics.width * 2 : metrics.width
                out.append(BgInstance(
                    origin: SIMD2<Float>(Float(rect.origin.x), Float(rect.origin.y)),
                    size: SIMD2<Float>(Float(w), Float(rect.height)),
                    color: rgba(color)
                ))
            }
        }
        return out
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
        let maxY = max(0, contentHeight - viewportHeight)
        scrollY = max(0, min(y, maxY))
        redrawLast()
        onScrollGeometryChanged?()
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
