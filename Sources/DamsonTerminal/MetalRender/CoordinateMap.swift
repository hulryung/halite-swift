import AppKit

/// Pure row/col ↔ pixel arithmetic for the Metal backend. The content view is
/// flipped (top-left origin), so a unified row's content-Y is
/// `inset.height + row*cellH`, and the on-screen (view) Y subtracts `scrollY`.
struct CoordinateMap {
    var cellW: CGFloat
    var cellH: CGFloat
    var inset: NSSize
    var scrollY: CGFloat

    /// Cell rect in the (flipped) content-view coordinate space.
    func cellRectInView(row: Int, col: Int) -> NSRect {
        let x = inset.width + CGFloat(col) * cellW
        let y = inset.height + CGFloat(row) * cellH - scrollY
        return NSRect(x: x, y: y, width: cellW, height: cellH)
    }

    /// (row, col) for a point in the (flipped) content-view space. Not clamped.
    func cell(atViewPoint p: NSPoint) -> (row: Int, col: Int) {
        let row = Int(floor((p.y + scrollY - inset.height) / max(cellH, 1)))
        let col = Int(floor((p.x - inset.width) / max(cellW, 1)))
        return (row, col)
    }
}
