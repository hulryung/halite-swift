import AppKit
import DamsonTerminal

/// Geometry helpers for the damson-cli `resize-window` / `resize-pane` commands.
///
/// Resizing is done as a *delta* from the active terminal's current grid size: we add or
/// remove exactly `(targetCells − currentCells)` cells' worth of points to the window's
/// frame. That way all the fixed chrome (titlebar/tab bar height, scroller inset, pane
/// dividers) is preserved automatically — we never have to model it. After the frame
/// changes, the live layout pass (`DamsonTerminalView.reportSizeIfChanged`) re-derives
/// the grid from the same cell metrics and lands on the requested cols×rows.
enum WindowResize {
    /// Per-cell point size derived from a session's render font — the SAME computation
    /// `reportSizeIfChanged` uses (glyph "M" advance + the rendered line height), so the
    /// delta we apply matches what the layout pass will measure back.
    static func cellSize(for session: DamsonSession) -> CGSize {
        let font = fontWithNerdFallback(
            family: session.config.fontFamily,
            size: session.config.fontSize
        )
        let glyph = ("M" as NSString).size(withAttributes: [.font: font])
        let w = max(glyph.width, 1)
        // Match measuredLineHeight: lay out 3 lines and take the average step. Falls back
        // to the layout manager's default line height if measurement is degenerate.
        let storage = NSTextStorage(string: "M\nM\nM", attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let measured = used / 3.0
        let h = max(measured > 1 ? measured : layout.defaultLineHeight(for: font), 1)
        return CGSize(width: w, height: h)
    }

    /// Resize `window` so the active terminal grid becomes `target` (cols, rows), by
    /// applying a cell-delta to the current frame. Returns false if the active grid size
    /// isn't known yet. Honors the window's `contentMinSize` (AppKit clamps the frame).
    @discardableResult
    static func resize(window: NSWindow, to target: (cols: Int, rows: Int),
                       basedOn session: DamsonSession) -> Bool {
        let curCols = session.grid.cols
        let curRows = session.grid.rows
        guard curCols > 0, curRows > 0 else { return false }
        let cell = cellSize(for: session)
        let dW = CGFloat(target.cols - curCols) * cell.width
        let dH = CGFloat(target.rows - curRows) * cell.height
        guard dW != 0 || dH != 0 else { return true }   // already the requested size

        var frame = window.frame
        // Cocoa frames are bottom-left origin: growing height must keep the top edge fixed
        // (the natural feel), so move the origin down by the height delta.
        frame.size.width += dW
        frame.size.height += dH
        frame.origin.y -= dH
        window.setFrame(frame, display: true, animate: false)
        return true
    }

    /// Convert a `resize-pane` cell amount into a divider ratio fraction along the relevant
    /// axis, using the window's content dimension and the session's cell size. Falls back to
    /// a small fixed fraction when metrics are unavailable.
    static func dividerFraction(_ dir: PaneFocusDirection, cells: Int,
                                session: DamsonSession?, window: NSWindow) -> CGFloat {
        let span = max(cells, 1)
        guard let session = session else { return CGFloat(span) * 0.05 }
        let cell = cellSize(for: session)
        let content = window.contentView?.bounds.size ?? window.frame.size
        switch dir {
        case .left, .right:
            let total = max(content.width, 1)
            return (CGFloat(span) * cell.width) / total
        case .up, .down:
            let total = max(content.height, 1)
            return (CGFloat(span) * cell.height) / total
        }
    }
}
