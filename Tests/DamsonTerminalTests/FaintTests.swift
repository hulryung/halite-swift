import XCTest
@testable import DamsonTerminal

final class FaintTests: XCTestCase {
    func testSGR2SetsFaintAndSGR22Clears() {
        let g = Grid(cols: 10, rows: 2, pen: CellAttrs(fg: .default))
        g.applySGR([2])
        XCTAssertTrue(g.pen.faint, "SGR 2 should set faint")
        g.putChar("x")
        XCTAssertTrue(g.cell(row: 0, col: 0).attrs.faint, "written cell carries faint")

        g.applySGR([1])               // bold on, faint still on
        XCTAssertTrue(g.pen.bold)
        XCTAssertTrue(g.pen.faint)
        g.applySGR([22])              // neither bold nor faint
        XCTAssertFalse(g.pen.bold)
        XCTAssertFalse(g.pen.faint, "SGR 22 should clear faint too")
    }

    func testSGR0ResetsFaint() {
        let g = Grid(cols: 10, rows: 2, pen: CellAttrs(fg: .default))
        g.applySGR([2])
        g.applySGR([0])
        XCTAssertFalse(g.pen.faint)
    }

    func testFaintDimsForegroundTowardBackground() {
        // white fg over black bg, faint → mid-gray.
        let attrs = CellAttrs(fg: .rgb(255, 255, 255), bg: .rgb(0, 0, 0), faint: true)
        let (fg, _) = attrs.resolvedColors(theme: .defaultDark)
        let s = fg.usingColorSpace(.sRGB)!
        XCTAssertEqual(s.redComponent, 0.5, accuracy: 0.02)
        XCTAssertEqual(s.greenComponent, 0.5, accuracy: 0.02)
        XCTAssertEqual(s.blueComponent, 0.5, accuracy: 0.02)
    }

    func testNonFaintForegroundUnchanged() {
        let attrs = CellAttrs(fg: .rgb(255, 255, 255), bg: .rgb(0, 0, 0))
        let (fg, _) = attrs.resolvedColors(theme: .defaultDark)
        let s = fg.usingColorSpace(.sRGB)!
        XCTAssertEqual(s.redComponent, 1.0, accuracy: 0.01)
    }
}
