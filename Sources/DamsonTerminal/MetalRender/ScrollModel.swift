import Foundation
import CoreGraphics

/// Scalar vertical scroll position for the Metal backend.
///
/// Consumes OS scroll-event deltas directly — NSScrollView-style — rather than
/// simulating a spring for wheel/trackpad input. macOS delivers `scrollingDeltaY`
/// during the gesture and a decaying `momentumPhase` stream after lift-off, so
/// applying those deltas yields smooth scroll + momentum for free. Trackpad deltas
/// are precise (points, 1:1); mouse-wheel deltas are lines, scaled by cell height.
///
/// Programmatic jumps (snap-to-cursor) animate via an exponential ease toward a
/// `target`, stepped by a display link (`AnimationLink`); the model just holds the
/// position math so it stays unit-testable with no view.
///
/// `current` is content pixels from the top of the content that the viewport's top
/// sits at; 0 = scrolled to the very top, `maxY` = bottom.
struct ScrollModel {
    private(set) var current: CGFloat = 0
    /// Destination of an in-flight programmatic ease (== current when idle).
    private var target: CGFloat = 0
    /// Whether a programmatic ease is in flight (driven by `step(dt:)`).
    private(set) var animating = false

    /// Time constant of the ease, seconds. ~0.04 settles a typical jump in ~0.2s,
    /// matching the legacy snap-to-cursor easeOut feel.
    private let tau: CGFloat = 0.04
    /// Sub-pixel threshold at which the ease is considered settled.
    private let settleEpsilon: CGFloat = 0.5

    /// Lines scrolled per mouse-wheel notch (non-precise). Trackpad is unaffected.
    static let mouseWheelLines: CGFloat = 3

    /// Maximum offset (`contentHeight - viewportHeight`). Setting it re-clamps both
    /// `current` and `target` so a window grow / scrollback eviction can't strand
    /// the view (or an ease) past the new bottom. Negative (content shorter than
    /// viewport) pins to top.
    var maxY: CGFloat = 0 {
        didSet {
            current = clamp(current)
            target = clamp(target)
        }
    }

    func clamp(_ y: CGFloat) -> CGFloat {
        max(0, min(y, max(0, maxY)))
    }

    /// Jump to an absolute offset, clamped. Cancels any in-flight ease.
    mutating func jump(to y: CGFloat) {
        current = clamp(y)
        target = current
        animating = false
    }

    /// Begin a smooth ease toward an absolute offset. No-op (and not animating) if
    /// already within the settle threshold of the target.
    mutating func animate(to y: CGFloat) {
        target = clamp(y)
        animating = abs(target - current) >= settleEpsilon
    }

    /// Advance an in-flight ease by `dt` seconds (frame-rate independent). Returns
    /// `true` when settled (caller stops the display link). A no-op returns `true`.
    @discardableResult
    mutating func step(dt: CGFloat) -> Bool {
        guard animating else { return true }
        let k = 1 - CGFloat(exp(-Double(max(0, dt) / tau)))
        current += (target - current) * k
        if abs(target - current) < settleEpsilon {
            current = target
            animating = false
            return true
        }
        return false
    }

    /// Apply one scroll-wheel event's vertical delta. Cancels any in-flight ease
    /// (direct user input takes over).
    /// - Parameters:
    ///   - deltaY: `event.scrollingDeltaY` (already encodes natural-scroll direction).
    ///   - precise: `event.hasPreciseScrollingDeltas` (trackpad). Precise deltas are
    ///     points and applied 1:1; non-precise (mouse wheel) deltas are lines.
    ///   - lineHeight: cell height in points, used to scale non-precise deltas.
    ///   - viewport: viewport height in points, the dimension for rubber-band
    ///     resistance. 0 (default) disables rubber-band → hard clamp at the edges.
    /// - Returns: whether `current` actually moved (false at an edge → skip redraw).
    ///
    /// Past an edge, a **precise** (trackpad) gesture rubber-bands: `current` is
    /// allowed to overshoot [0, maxY] with diminishing resistance (the backend
    /// springs it back when the gesture ends). A mouse wheel hard-stops at the edge.
    @discardableResult
    mutating func applyWheel(deltaY: CGFloat, precise: Bool, lineHeight: CGFloat,
                             viewport: CGFloat = 0) -> Bool {
        animating = false
        // 트랙패드(precise)는 1:1. 마우스 휠(non-precise)은 노치당 deltaY가 ≈1이라 줄
        // 높이만 곱하면 노치당 1줄로 너무 느림 → 표준대로 노치당 ~3줄.
        let pixels = precise ? deltaY : deltaY * lineHeight * ScrollModel.mouseWheelLines
        let raw = current - pixels
        let hi = max(0, maxY)
        var next = raw
        if raw < 0 {
            next = precise ? -ScrollModel.rubberband(-raw, viewport) : 0
        } else if raw > hi {
            next = precise ? hi + ScrollModel.rubberband(raw - hi, viewport) : hi
        }
        target = clamp(next)            // a follow-up ease always targets the valid range
        guard next != current else { return false }
        current = next                  // may be out of [0, maxY] during a rubber-band
        return true
    }

    /// True while scrolled past an edge (rubber-band overshoot in effect); the
    /// backend springs `current` back to `clamp(current)` when this holds at
    /// gesture end.
    var isOvershooting: Bool { current < 0 || current > max(0, maxY) }

    /// AppKit-style elastic resistance: maps an unbounded `overshoot` to a bounded,
    /// diminishing displacement (≈ NSScrollView rubber-band). 0 if no dimension.
    static func rubberband(_ overshoot: CGFloat, _ dimension: CGFloat) -> CGFloat {
        guard dimension > 0, overshoot > 0 else { return 0 }
        let c: CGFloat = 0.55
        return (1 - 1 / (overshoot * c / dimension + 1)) * dimension
    }
}
