import XCTest
@testable import DamsonTerminal

/// Increment A: the Metal backend's scalar scroll position model. Consumes OS
/// scroll-event deltas directly (NSScrollView-style), distinguishing trackpad
/// (precise, in points) from mouse-wheel (non-precise, in lines).
final class ScrollModelTests: XCTestCase {

    func testStartsAtZero() {
        let m = ScrollModel()
        XCTAssertEqual(m.current, 0)
    }

    func testJumpClampsToLowerBound() {
        var m = ScrollModel()
        m.maxY = 100
        m.jump(to: -50)
        XCTAssertEqual(m.current, 0)
    }

    func testJumpClampsToUpperBound() {
        var m = ScrollModel()
        m.maxY = 100
        m.jump(to: 200)
        XCTAssertEqual(m.current, 100)
    }

    func testMaxYZeroPinsToTop() {
        var m = ScrollModel()
        m.maxY = 0
        m.jump(to: 50)
        XCTAssertEqual(m.current, 0)
    }

    func testNegativeMaxYTreatedAsZero() {
        var m = ScrollModel()
        m.maxY = -30   // content shorter than viewport
        m.jump(to: 10)
        XCTAssertEqual(m.current, 0)
    }

    func testShrinkingMaxYReclampsCurrent() {
        var m = ScrollModel()
        m.maxY = 200
        m.jump(to: 180)
        m.maxY = 50          // e.g. window grew / scrollback evicted
        XCTAssertEqual(m.current, 50)
    }

    /// Trackpad: deltas are points, applied 1:1. Natural-scroll sign — a negative
    /// scrollingDeltaY (swipe to reveal content below) increases scrollY.
    func testPreciseDeltaAppliedAsPixels() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 500)
        m.applyWheel(deltaY: -10, precise: true, lineHeight: 16)
        XCTAssertEqual(m.current, 510)
    }

    /// Mouse wheel: deltas are lines, scaled by line height × per-notch lines (~3).
    func testLineDeltaScaledByLineHeight() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 500)
        m.applyWheel(deltaY: -3, precise: false, lineHeight: 16)
        XCTAssertEqual(m.current, 500 + 3 * 16 * ScrollModel.mouseWheelLines)
    }

    func testWheelClampsAtTop() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 5)
        let changed = m.applyWheel(deltaY: 10, precise: true, lineHeight: 16)
        XCTAssertEqual(m.current, 0)
        XCTAssertTrue(changed)
    }

    func testWheelReturnsFalseWhenPinnedAtEdge() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 0)
        let changed = m.applyWheel(deltaY: 10, precise: true, lineHeight: 16)
        XCTAssertEqual(m.current, 0)
        XCTAssertFalse(changed, "no movement at the top edge → no redraw needed")
    }

    // MARK: - Programmatic ease (increment B)

    func testStepWithoutAnimateIsNoop() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 300)
        XCTAssertTrue(m.step(dt: 1.0 / 60), "no ease in flight → settled")
        XCTAssertEqual(m.current, 300)
        XCTAssertFalse(m.animating)
    }

    func testAnimateToCurrentDoesNotAnimate() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 300)
        m.animate(to: 300.2)   // within settle epsilon
        XCTAssertFalse(m.animating, "already at target → no animation")
    }

    func testAnimateThenStepConvergesToTarget() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 0)
        m.animate(to: 500)
        XCTAssertTrue(m.animating)
        var settled = false
        for _ in 0..<600 where !settled {       // cap ~10s of 60fps frames
            settled = m.step(dt: 1.0 / 60)
        }
        XCTAssertTrue(settled, "ease must settle")
        XCTAssertEqual(m.current, 500, accuracy: 0.001)
        XCTAssertFalse(m.animating)
    }

    func testStepIsMonotonicAndDoesNotOvershoot() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 0)
        m.animate(to: 400)
        var prev = m.current
        for _ in 0..<120 {
            _ = m.step(dt: 1.0 / 60)
            XCTAssertGreaterThanOrEqual(m.current, prev, "monotonic toward target")
            XCTAssertLessThanOrEqual(m.current, 400 + 0.001, "no overshoot")
            prev = m.current
        }
    }

    func testEaseSettlesWithinAboutFifthOfASecond() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 0)
        m.animate(to: 200)
        var t: CGFloat = 0
        let dt: CGFloat = 1.0 / 120
        while m.animating && t < 1.0 { _ = m.step(dt: dt); t += dt }
        XCTAssertFalse(m.animating)
        XCTAssertLessThan(t, 0.35, "ease should feel snappy (~0.2s), not draggy")
    }

    func testWheelCancelsInFlightEase() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 0)
        m.animate(to: 500)
        _ = m.step(dt: 1.0 / 60)
        XCTAssertTrue(m.animating)
        m.applyWheel(deltaY: -10, precise: true, lineHeight: 16)
        XCTAssertFalse(m.animating, "direct wheel input cancels the programmatic ease")
    }

    func testMaxYShrinkReclampsEaseTarget() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 0)
        m.animate(to: 800)
        m.maxY = 100              // content shrank mid-ease
        for _ in 0..<300 { _ = m.step(dt: 1.0 / 60) }
        XCTAssertLessThanOrEqual(m.current, 100, "ease must not settle past the new bottom")
    }

    // MARK: - Rubber-band (polish)

    func testRubberbandResistanceIsDiminishingAndBounded() {
        let d: CGFloat = 800
        XCTAssertEqual(ScrollModel.rubberband(0, d), 0)
        let r50 = ScrollModel.rubberband(50, d)
        let r200 = ScrollModel.rubberband(200, d)
        let r1000 = ScrollModel.rubberband(1000, d)
        XCTAssertLessThan(r50, 50, "displacement is resisted (less than raw overshoot)")
        XCTAssertLessThan(r50, r200, "more pull → more displacement")
        XCTAssertLessThan(r200, r1000)
        XCTAssertLessThan(r1000, d, "bounded below the viewport dimension")
    }

    func testRubberbandZeroDimensionIsZero() {
        XCTAssertEqual(ScrollModel.rubberband(100, 0), 0, "no dimension → no rubber-band (hard clamp)")
    }

    func testPreciseGestureOvershootsPastTopWithResistance() {
        var m = ScrollModel()
        m.maxY = 500
        m.jump(to: 0)
        m.applyWheel(deltaY: 100, precise: true, lineHeight: 16, viewport: 800)  // pull up past top
        XCTAssertLessThan(m.current, 0, "rubber-bands past the top edge")
        XCTAssertGreaterThan(m.current, -100, "but resisted (less than the raw 100px)")
        XCTAssertTrue(m.isOvershooting)
    }

    func testPreciseGestureOvershootsPastBottom() {
        var m = ScrollModel()
        m.maxY = 500
        m.jump(to: 500)
        m.applyWheel(deltaY: -100, precise: true, lineHeight: 16, viewport: 800)  // pull down past bottom
        XCTAssertGreaterThan(m.current, 500)
        XCTAssertLessThan(m.current, 600)
        XCTAssertTrue(m.isOvershooting)
    }

    func testMouseWheelHardStopsNoRubberband() {
        var m = ScrollModel()
        m.maxY = 500
        m.jump(to: 0)
        m.applyWheel(deltaY: 100, precise: false, lineHeight: 16, viewport: 800)
        XCTAssertEqual(m.current, 0, "mouse wheel does not rubber-band")
        XCTAssertFalse(m.isOvershooting)
    }

    func testSpringBackFromOvershootSettlesAtEdge() {
        var m = ScrollModel()
        m.maxY = 500
        m.jump(to: 0)
        m.applyWheel(deltaY: 120, precise: true, lineHeight: 16, viewport: 800)
        XCTAssertTrue(m.isOvershooting)
        m.animate(to: m.clamp(m.current))   // backend's spring-back on gesture end
        var settled = false
        for _ in 0..<600 where !settled { settled = m.step(dt: 1.0 / 60) }
        XCTAssertTrue(settled)
        XCTAssertEqual(m.current, 0, accuracy: 0.001)
        XCTAssertFalse(m.isOvershooting)
    }
}
