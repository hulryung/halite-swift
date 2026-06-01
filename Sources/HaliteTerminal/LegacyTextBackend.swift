import AppKit

/// 내부 표시용 NSTextView. first responder도 mouse hit도 거부.
final class PassiveTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func becomeFirstResponder() -> Bool { false }
}

/// The original M3 render path, factored behind `TerminalRenderBackend`:
/// child `NSTextView` inside an `NSScrollView`, full `NSAttributedString` rebuild
/// each frame, and a `CALayer` for the underline/bar cursor. Owns the views and
/// scroll geometry; the host keeps input/IME/selection/follow-policy and hands
/// this backend a `RenderState` + shared `CellMetrics` per frame.
///
/// The code here was moved verbatim from `HaliteSurfaceView` (the M3 placeholder)
/// with `session.config` → the `config` parameter and `cellMetrics` → `metrics`,
/// so behavior is byte-identical to the pre-seam renderer.
final class LegacyTextBackend: TerminalRenderBackend {
    private let scrollView: NSScrollView
    private let textView: PassiveTextView

    /// Font used to lay out / rasterize text. Set by the host (config + zoom).
    private(set) var renderFont: NSFont

    var onScrollGeometryChanged: (() -> Void)?
    var onUserScroll: (() -> Void)?

    init(config: HaliteConfig) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = true
        scroll.backgroundColor = config.backgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let font = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        let tv = PassiveTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = false
        tv.isRichText = true
        tv.allowsUndo = false
        tv.font = font
        tv.textColor = config.foregroundColor
        tv.backgroundColor = config.backgroundColor
        tv.drawsBackground = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.lineFragmentPadding = 0

        scroll.documentView = tv
        self.scrollView = scroll
        self.textView = tv
        self.renderFont = font

        scroll.wantsLayer = true

        // 스크롤 변동을 호스트로 콜백. didLiveScroll(사용자 인터랙션)은 follow 갱신,
        // boundsDidChange(programmatic 포함)는 cursor overlay 재배치.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLiveScroll(_:)),
            name: NSScrollView.didLiveScrollNotification, object: scroll
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBoundsChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
    }

    @objc private func handleLiveScroll(_ note: Notification) {
        onScrollGeometryChanged?()
        onUserScroll?()
    }

    @objc private func handleBoundsChange(_ note: Notification) {
        onScrollGeometryChanged?()
    }

    // MARK: - TerminalRenderBackend

    var contentView: NSView { scrollView }

    /// Visible content area + inset, so the host derives the same usable
    /// width/height for cols/rows regardless of backend.
    var contentSize: NSSize { scrollView.contentSize }
    var contentInset: NSSize { textView.textContainerInset }

    func applyConfig(_ config: HaliteConfig) {
        renderFont = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        textView.font = renderFont
        textView.backgroundColor = config.backgroundColor
        scrollView.backgroundColor = config.backgroundColor
    }

    /// Set the render font directly (font zoom — same font family, scaled size).
    func setRenderFont(_ font: NSFont) {
        renderFont = font
        textView.font = font
    }

    // MARK: - Render

    func render(grid: Grid, config: HaliteConfig, state: RenderState, metrics: CellMetrics) {
        guard let storage = textView.textStorage else { return }
        let baseFont = renderFont

        // 줄 높이를 정확히 cellH로 강제 (NSTextView 기본 spacing이 우리 cellH와
        // 어긋나면 전체 컨텐츠가 viewport보다 커져 scroll이 발생).
        let lineHeight = max(metrics.height, 1)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.lineSpacing = 0
        paragraphStyle.lineBreakMode = .byClipping

        let result = NSMutableAttributedString()
        result.beginEditing()

        let scrollbackCount = grid.scrollback.count

        // Scrollback. cursor는 안 그림.
        for (i, line) in grid.scrollback.enumerated() {
            let sel = selectedColumnsForRow(i, cols: line.count, state: state)
            let finds = findRangesForRow(i, state: state)
            let hover = hoveredURLRangeForRow(i, state: state)
            let active = activeFindRangeForRow(i, state: state)
            appendLine(
                line.cells, cols: line.count, cursorCol: nil,
                selectedCols: sel, findRanges: finds, activeFindRange: active,
                hoveredURLRange: hover, config: config, metrics: metrics,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
            result.append(NSAttributedString(string: "\n"))
        }

        // block-cursor inverse 렌더링은 cursorVisible 따라가지만,
        // IME 조합 overlay는 cursor가 숨김 처리되어 있어도(TUI 앱들이 DECTCEM ?25l로
        // 흔히 함, 예: claude code, vim 일부 모드, htop) 사용자가 입력 중이면 보여야 함.
        let blockCursorRow = grid.cursorVisible ? grid.cursorRow : -1
        let imeOverlayRow = grid.cursorRow   // cursor 가시성과 무관하게 항상 그 자리
        // blink ON이고 현재 blink off phase면 block cursor를 안 그림(깜빡임).
        let blinkOff = state.cursorBlinkEnabled && !state.cursorBlinkVisible
        let blockCursorActive = (grid.cursorShape == .block) && state.markedText.isEmpty && !blinkOff
        let mt = state.markedText
        for r in 0..<grid.rows {
            let textViewRow = scrollbackCount + r
            let sel = selectedColumnsForRow(textViewRow, cols: grid.cols, state: state)
            let finds = findRangesForRow(textViewRow, state: state)
            let hover = hoveredURLRangeForRow(textViewRow, state: state)
            let active = activeFindRangeForRow(textViewRow, state: state)
            if r == imeOverlayRow && !mt.isEmpty {
                appendCursorRowWithMarkedText(
                    grid.row(r), cols: grid.cols, cursorCol: grid.cursorCol,
                    markedText: mt, config: config, metrics: metrics,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            } else {
                let cc: Int? = (r == blockCursorRow && blockCursorActive) ? grid.cursorCol : nil
                appendLine(
                    grid.row(r), cols: grid.cols, cursorCol: cc,
                    selectedCols: sel, findRanges: finds, activeFindRange: active,
                    hoveredURLRange: hover, config: config, metrics: metrics,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
            if r < grid.rows - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        result.endEditing()

        storage.beginEditing()
        storage.setAttributedString(result)
        storage.endEditing()

        // 강제 동기 layout 후 host의 follow 로직이 정확한 frame.height를 읽도록.
        ensureLayout()
    }

    // MARK: - Per-row projections from RenderState

    private func normalizedSelection(_ state: RenderState) -> (start: GridPos, end: GridPos)? {
        guard let a = state.selectionAnchor, let h = state.selectionHead else { return nil }
        if a.row == h.row && a.col == h.col { return nil }
        if a.row < h.row || (a.row == h.row && a.col < h.col) { return (a, h) }
        return (h, a)
    }

    private func selectedColumnsForRow(_ row: Int, cols: Int, state: RenderState) -> Range<Int>? {
        guard let (start, end) = normalizedSelection(state) else { return nil }
        if row < start.row || row > end.row { return nil }
        let lo: Int
        let hi: Int
        if row == start.row && row == end.row {
            lo = start.col; hi = min(end.col, cols)
        } else if row == start.row {
            lo = start.col; hi = cols
        } else if row == end.row {
            lo = 0; hi = min(end.col, cols)
        } else {
            lo = 0; hi = cols
        }
        guard lo < hi else { return nil }
        return lo..<hi
    }

    private func findRangesForRow(_ row: Int, state: RenderState) -> [Range<Int>] {
        state.findMatchesByRow[row] ?? []
    }

    private func activeFindRangeForRow(_ row: Int, state: RenderState) -> Range<Int>? {
        guard let ar = state.activeFindRow, ar == row else { return nil }
        return state.activeFindRange
    }

    private func hoveredURLRangeForRow(_ row: Int, state: RenderState) -> Range<Int>? {
        guard let hr = state.hoveredRow, hr == row else { return nil }
        return state.hoveredRange
    }

    // MARK: - Cursor overlay (underline/bar)

    func cursorOverlay(grid: Grid, config: HaliteConfig, state: RenderState, metrics: CellMetrics) -> CursorOverlay? {
        let shape = grid.cursorShape
        let blinkOff = state.cursorBlinkEnabled && !state.cursorBlinkVisible
        guard grid.cursorVisible, shape != .block, state.markedText.isEmpty, !blinkOff else {
            return nil
        }

        let cellW = max(metrics.width, 1)
        let cellH = max(metrics.height, 1)
        let inset = textView.textContainerInset

        let textViewRow = grid.scrollback.count + grid.cursorRow
        let tvX = inset.width + CGFloat(grid.cursorCol) * cellW
        let tvY = inset.height + CGFloat(textViewRow) * cellH

        // textView 좌표 → host 좌표로 직접 변환. cursorLayer는 host 레이어(비-flipped,
        // bottom-left origin)에 있으므로 같은 basis여야 한다. scrollView로 변환하면
        // scrollView의 flip 차이로 세로가 뒤집힘 — 반드시 host(superview)로 변환.
        // (원본 textView.convert(to: self)와 동일.) self는 non-flipped라 셀의 시각적
        // top-left가 나오고, 셀 박스 bottom-left y = originInSelf.y - cellH.
        guard let host = scrollView.superview else { return nil }
        let originInSelf = textView.convert(NSPoint(x: tvX, y: tvY), to: host)
        let cellBottomY = originInSelf.y - cellH

        var cursorW = cellW
        if grid.cursorCol + 1 < grid.cols && grid.cursorRow < grid.rows {
            let row = grid.row(grid.cursorRow)
            if grid.cursorCol + 1 < row.count && row[grid.cursorCol + 1].isContinuation {
                cursorW = cellW * 2
            }
        }

        let visibleRect = host.bounds
        let cursorRectInSelf = NSRect(x: originInSelf.x, y: cellBottomY, width: cursorW, height: cellH)
        if !visibleRect.intersects(cursorRectInSelf) {
            return nil
        }

        let frame: NSRect
        switch shape {
        case .underline:
            let thickness = max(1.5, cellH * 0.1)
            frame = NSRect(x: originInSelf.x, y: cellBottomY, width: cursorW, height: thickness)
        case .bar:
            let thickness = max(1.5, cellW * 0.15)
            frame = NSRect(x: originInSelf.x, y: cellBottomY, width: thickness, height: cellH)
        case .block:
            return nil
        }
        return CursorOverlay(frame: frame, color: config.cursorColor)
    }

    // MARK: - Geometry (window coordinate space)

    func cell(at pointInHost: NSPoint, grid: Grid, metrics: CellMetrics) -> GridPos {
        // `pointInHost` is in window-base coords (host passes event.locationInWindow).
        let pInTextView = textView.convert(pointInHost, from: nil)
        let inset = textView.textContainerInset
        let cellW = max(metrics.width, 1)
        let cellH = max(metrics.height, 1)
        let row = max(0, Int(floor((pInTextView.y - inset.height) / cellH)))
        let col = max(0, Int(floor((pInTextView.x - inset.width) / cellW)))
        let maxRow = grid.scrollback.count + grid.rows - 1
        let maxCol = grid.cols
        return GridPos(row: min(row, maxRow), col: min(col, maxCol))
    }

    func cursorScreenRect(grid: Grid, metrics: CellMetrics, window: NSWindow) -> NSRect {
        let cellW = metrics.width
        let cellH = metrics.height
        let inset = textView.textContainerInset
        let rowInTextView = grid.scrollback.count + grid.cursorRow
        let cellOrigin = CGPoint(
            x: inset.width + CGFloat(grid.cursorCol) * cellW,
            y: inset.height + CGFloat(rowInTextView) * cellH
        )
        let cellRectInTextView = NSRect(origin: cellOrigin, size: NSSize(width: cellW, height: cellH))
        let cellRectInWindow = textView.convert(cellRectInTextView, to: nil)
        return window.convertToScreen(cellRectInWindow)
    }

    // MARK: - Scroll primitives

    var scrollYPixels: CGFloat { scrollView.contentView.bounds.origin.y }
    var contentHeight: CGFloat { textView.frame.height }
    var viewportHeight: CGFloat { scrollView.contentView.bounds.height }

    func setScrollY(_ y: CGFloat, animated: Bool) {
        if animated {
            scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
        } else {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// `NSScrollView` handles the wheel (and momentum/rubber-band) natively, so
    /// don't consume it — let the host fall through to `super.scrollWheel`.
    func handleScrollWheel(_ event: NSEvent) -> Bool { false }

    func ensureLayout() {
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
    }

    func reflectScroll() {
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Render helpers (moved verbatim from HaliteSurfaceView)

    private func appendLine(
        _ line: [Cell], cols: Int, cursorCol: Int?,
        selectedCols: Range<Int>?, findRanges: [Range<Int>],
        activeFindRange: Range<Int>?, hoveredURLRange: Range<Int>?,
        config: HaliteConfig, metrics: CellMetrics,
        baseFont: NSFont, paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        guard cols > 0 else { return }
        let cc = cursorCol ?? -1
        if cc >= 0 && cc < cols {
            if cc > 0 {
                appendRunGroup(
                    line, range: 0..<cc, selectedCols: selectedCols, findRanges: findRanges,
                    activeFindRange: activeFindRange, hoveredURLRange: hoveredURLRange,
                    config: config, metrics: metrics,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
            var inverseCell = line[cc]
            inverseCell.attrs.inverse.toggle()
            let cursorSelected = selectedCols?.contains(cc) ?? false
            let cursorIsWide = (cc + 1 < cols && line[cc + 1].isContinuation)
            if cursorIsWide {
                appendWideCell(
                    inverseCell, isSelected: cursorSelected, config: config, metrics: metrics,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            } else {
                let nsAttrs = makeAttributes(
                    for: inverseCell.attrs, config: config, baseFont: baseFont,
                    paragraphStyle: paragraphStyle,
                    isSelected: cursorSelected, hyperlink: inverseCell.hyperlink
                )
                result.append(NSAttributedString(string: String(inverseCell.char), attributes: nsAttrs))
            }
            if cc + 1 < cols {
                appendRunGroup(
                    line, range: (cc + 1)..<cols, selectedCols: selectedCols, findRanges: findRanges,
                    activeFindRange: activeFindRange, hoveredURLRange: hoveredURLRange,
                    config: config, metrics: metrics,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
        } else {
            appendRunGroup(
                line, range: 0..<cols, selectedCols: selectedCols, findRanges: findRanges,
                activeFindRange: activeFindRange, hoveredURLRange: hoveredURLRange,
                config: config, metrics: metrics,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }
    }

    private func appendCursorRowWithMarkedText(
        _ line: [Cell], cols: Int, cursorCol: Int, markedText: String,
        config: HaliteConfig, metrics: CellMetrics,
        baseFont: NSFont, paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        if cursorCol > 0 {
            appendRunGroup(
                line, range: 0..<cursorCol, selectedCols: nil, findRanges: [],
                activeFindRange: nil, hoveredURLRange: nil, config: config, metrics: metrics,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }
        var imeAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: config.foregroundColor,
            .paragraphStyle: paragraphStyle,
        ]
        switch config.imeStyle {
        case .underline:
            imeAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            imeAttrs[.underlineColor] = config.foregroundColor.withAlphaComponent(0.7)
        case .thickUnderline:
            imeAttrs[.underlineStyle] = NSUnderlineStyle.thick.rawValue
            imeAttrs[.underlineColor] = config.foregroundColor
        case .background:
            imeAttrs[.backgroundColor] = NSColor.systemBlue.withAlphaComponent(0.45)
            imeAttrs[.foregroundColor] = NSColor.white
        case .both:
            imeAttrs[.underlineStyle] = NSUnderlineStyle.thick.rawValue
            imeAttrs[.backgroundColor] = NSColor.systemBlue.withAlphaComponent(0.65)
            imeAttrs[.foregroundColor] = NSColor.white
        case .none:
            break
        }
        // 조합 텍스트를 셀 그리드에 정렬. 글자별로 cell 폭(wide=2*cellW)에 맞게 kern —
        // commit된 텍스트(appendWideCell)와 동일하게. 한 덩어리로 그리면 fallback 폰트의
        // 자연 advance로 흘러 셀 간격이 어긋나 보임(조합 중에만 벌어지던 회귀).
        var overlayCols = 0
        for ch in markedText {
            let wide = Cell.isWide(ch)
            overlayCols += wide ? 2 : 1
            var attrs = imeAttrs
            let natural = (String(ch) as NSString).size(withAttributes: [.font: baseFont]).width
            let target = CGFloat(wide ? 2 : 1) * metrics.width
            let kern = target - natural
            if kern > 0.01 { attrs[.kern] = kern }
            result.append(NSAttributedString(string: String(ch), attributes: attrs))
        }

        // 조합 텍스트가 가린 만큼 row의 나머지 셀을 건너뜀 (display width 기준).
        let afterCol = min(cursorCol + overlayCols, cols)
        if afterCol < cols {
            appendRunGroup(
                line, range: afterCol..<cols, selectedCols: nil, findRanges: [],
                activeFindRange: nil, hoveredURLRange: nil, config: config, metrics: metrics,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }
    }

    private func appendRunGroup(
        _ line: [Cell], range: Range<Int>,
        selectedCols: Range<Int>?, findRanges: [Range<Int>],
        activeFindRange: Range<Int>?, hoveredURLRange: Range<Int>?,
        config: HaliteConfig, metrics: CellMetrics,
        baseFont: NSFont, paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        func isFindMatch(_ col: Int) -> Bool { findRanges.contains { $0.contains(col) } }
        func isActiveFind(_ col: Int) -> Bool { activeFindRange?.contains(col) ?? false }
        func isHovered(_ col: Int) -> Bool { hoveredURLRange?.contains(col) ?? false }

        var c = range.lowerBound
        while c < range.upperBound {
            if line[c].isContinuation { c += 1; continue }
            let isWide = (c + 1 < line.count && line[c + 1].isContinuation)
            if isWide {
                appendWideCell(
                    line[c], isSelected: selectedCols?.contains(c) ?? false,
                    isFindMatch: isFindMatch(c), isActiveFindMatch: isActiveFind(c),
                    isHoveredURL: isHovered(c), config: config, metrics: metrics,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
                c += 1
                continue
            }

            let runAttrs = line[c].attrs
            let runHyperlink = line[c].hyperlink
            let runSelected = selectedCols?.contains(c) ?? false
            let runFind = isFindMatch(c)
            let runActive = isActiveFind(c)
            let runHover = isHovered(c)
            var endC = c + 1
            while endC < range.upperBound,
                  !line[endC].isContinuation,
                  !(endC + 1 < line.count && line[endC + 1].isContinuation),
                  line[endC].attrs == runAttrs,
                  line[endC].hyperlink == runHyperlink,
                  (selectedCols?.contains(endC) ?? false) == runSelected,
                  isFindMatch(endC) == runFind,
                  isActiveFind(endC) == runActive,
                  isHovered(endC) == runHover {
                endC += 1
            }
            var runChars = ""
            runChars.reserveCapacity(endC - c)
            for i in c..<endC { runChars.append(line[i].char) }
            let nsAttrs = makeAttributes(
                for: runAttrs, config: config, baseFont: baseFont,
                paragraphStyle: paragraphStyle,
                isSelected: runSelected, isFindMatch: runFind,
                isActiveFindMatch: runActive, isHoveredURL: runHover, hyperlink: runHyperlink
            )
            result.append(NSAttributedString(string: runChars, attributes: nsAttrs))
            c = endC
        }
    }

    private func appendWideCell(
        _ cell: Cell, isSelected: Bool,
        isFindMatch: Bool = false, isActiveFindMatch: Bool = false, isHoveredURL: Bool = false,
        config: HaliteConfig, metrics: CellMetrics,
        baseFont: NSFont, paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        var nsAttrs = makeAttributes(
            for: cell.attrs, config: config, baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            isSelected: isSelected, isFindMatch: isFindMatch,
            isActiveFindMatch: isActiveFindMatch, isHoveredURL: isHoveredURL, hyperlink: cell.hyperlink
        )
        let font = (nsAttrs[.font] as? NSFont) ?? baseFont
        let char = String(cell.char) as NSString
        let naturalW = char.size(withAttributes: [.font: font]).width
        let targetW = metrics.width * 2
        let kern = targetW - naturalW
        if kern > 0.01 { nsAttrs[.kern] = kern }
        result.append(NSAttributedString(string: String(cell.char), attributes: nsAttrs))
    }

    private func makeAttributes(
        for cellAttrs: CellAttrs, config: HaliteConfig, baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        isSelected: Bool = false, isFindMatch: Bool = false,
        isActiveFindMatch: Bool = false, isHoveredURL: Bool = false, hyperlink: String? = nil
    ) -> [NSAttributedString.Key: Any] {
        let (fg, bg) = cellAttrs.resolvedColors(theme: config.theme)
        let font: NSFont
        if cellAttrs.bold {
            font = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        } else {
            font = baseFont
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
            .paragraphStyle: paragraphStyle,
        ]
        if isSelected {
            attrs[.backgroundColor] = NSColor.selectedTextBackgroundColor
        } else if isActiveFindMatch {
            attrs[.backgroundColor] = NSColor.systemOrange.withAlphaComponent(0.85)
            attrs[.foregroundColor] = NSColor.black
        } else if isFindMatch {
            attrs[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.6)
            attrs[.foregroundColor] = NSColor.black
        } else if let bg = bg {
            attrs[.backgroundColor] = bg
        }
        if cellAttrs.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if let uri = hyperlink, let url = URL(string: uri) {
            attrs[.link] = url
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = fg.withAlphaComponent(0.5)
        }
        if isHoveredURL {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = NSColor.systemBlue
            attrs[.foregroundColor] = NSColor.systemBlue
        }
        return attrs
    }
}
