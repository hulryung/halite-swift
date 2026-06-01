import XCTest
@testable import HaliteTerminal

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

    /// Mouse wheel: deltas are lines, scaled by line height (else a notch moves ~2px).
    func testLineDeltaScaledByLineHeight() {
        var m = ScrollModel()
        m.maxY = 1000
        m.jump(to: 500)
        m.applyWheel(deltaY: -3, precise: false, lineHeight: 16)
        XCTAssertEqual(m.current, 500 + 48)
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
}
