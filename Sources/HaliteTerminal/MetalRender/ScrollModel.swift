import CoreGraphics

/// Scalar vertical scroll position for the Metal backend.
///
/// Consumes OS scroll-event deltas directly — NSScrollView-style — rather than
/// simulating a spring. macOS delivers `scrollingDeltaY` during the gesture and a
/// decaying `momentumPhase` stream after lift-off, so applying those deltas yields
/// smooth scroll + momentum for free. Trackpad deltas are precise (points, 1:1);
/// mouse-wheel deltas are lines, scaled by the cell height.
///
/// `current` is content pixels from the top of the content that the viewport's top
/// sits at; 0 = scrolled to the very top, `maxY` = bottom. Programmatic animated
/// eases (snap-to-cursor) are a later increment (AnimationLink); this type only
/// holds position + clamp + wheel application.
struct ScrollModel {
    private(set) var current: CGFloat = 0

    /// Maximum offset (`contentHeight - viewportHeight`). Setting it re-clamps
    /// `current` so a window grow / scrollback eviction can't strand the view past
    /// the new bottom. Negative values (content shorter than viewport) pin to top.
    var maxY: CGFloat = 0 {
        didSet { current = clamp(current) }
    }

    func clamp(_ y: CGFloat) -> CGFloat {
        max(0, min(y, max(0, maxY)))
    }

    /// Jump to an absolute offset, clamped. No animation.
    mutating func jump(to y: CGFloat) {
        current = clamp(y)
    }

    /// Apply one scroll-wheel event's vertical delta.
    /// - Parameters:
    ///   - deltaY: `event.scrollingDeltaY` (already encodes natural-scroll direction).
    ///   - precise: `event.hasPreciseScrollingDeltas` (trackpad). Precise deltas are
    ///     points and applied 1:1; non-precise (mouse wheel) deltas are lines.
    ///   - lineHeight: cell height in points, used to scale non-precise deltas.
    /// - Returns: whether `current` actually moved (false at an edge → skip redraw).
    @discardableResult
    mutating func applyWheel(deltaY: CGFloat, precise: Bool, lineHeight: CGFloat) -> Bool {
        let pixels = precise ? deltaY : deltaY * lineHeight
        let next = clamp(current - pixels)
        guard next != current else { return false }
        current = next
        return true
    }
}
