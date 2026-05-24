import AppKit
import XCTest
@testable import HaliteTerminal

final class GridTests: XCTestCase {
    private func makeGrid(cols: Int = 8, rows: Int = 4) -> Grid {
        Grid(cols: cols, rows: rows, pen: CellAttrs(fg: .white))
    }

    private func write(_ g: Grid, _ s: String) {
        for ch in s { g.putChar(ch) }
    }

    // MARK: putChar / cursor advance

    func testPutCharAdvancesCursor() {
        let g = makeGrid()
        write(g, "abc")
        XCTAssertEqual(g.cursorRow, 0)
        XCTAssertEqual(g.cursorCol, 3)
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "a")
        XCTAssertEqual(g.cell(row: 0, col: 2).char, "c")
    }

    func testDeferredWrapAtLastColumn() {
        let g = makeGrid(cols: 4, rows: 3)
        write(g, "abcd") // 4 chars in 4-wide → cursor parks at col 3 with pendingWrap
        XCTAssertEqual(g.cursorRow, 0)
        XCTAssertEqual(g.cursorCol, 3)
        // Next char triggers the wrap
        g.putChar("e")
        XCTAssertEqual(g.cursorRow, 1)
        XCTAssertEqual(g.cursorCol, 1)
        XCTAssertEqual(g.cell(row: 0, col: 3).char, "d")
        XCTAssertEqual(g.cell(row: 1, col: 0).char, "e")
    }

    // MARK: LF / CR / BS

    func testLineFeedMovesCursorDown() {
        let g = makeGrid()
        write(g, "ab")
        g.lineFeed()
        XCTAssertEqual(g.cursorRow, 1)
        XCTAssertEqual(g.cursorCol, 2) // CR not implied
    }

    func testCarriageReturnResetsColumn() {
        let g = makeGrid()
        write(g, "abc")
        g.carriageReturn()
        XCTAssertEqual(g.cursorRow, 0)
        XCTAssertEqual(g.cursorCol, 0)
    }

    func testBackspaceMovesLeft() {
        let g = makeGrid()
        write(g, "abc")
        g.backspace()
        XCTAssertEqual(g.cursorCol, 2)
        // Char remains (BS doesn't erase)
        XCTAssertEqual(g.cell(row: 0, col: 2).char, "c")
    }

    func testBackspaceAtColumnZeroIsNoOp() {
        let g = makeGrid()
        g.backspace()
        XCTAssertEqual(g.cursorRow, 0)
        XCTAssertEqual(g.cursorCol, 0)
    }

    // MARK: scroll

    func testLineFeedAtBottomScrollsUp() {
        let g = makeGrid(cols: 4, rows: 3)
        write(g, "AAA")
        g.lineFeed()
        g.carriageReturn()
        write(g, "BBB")
        g.lineFeed()
        g.carriageReturn()
        write(g, "CCC")
        // Now cursor on last row. LF should scroll up.
        g.lineFeed()
        XCTAssertEqual(g.cursorRow, 2) // still bottom row
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "B")
        XCTAssertEqual(g.cell(row: 1, col: 0).char, "C")
        XCTAssertEqual(g.cell(row: 2, col: 0).char, " ") // blank
    }

    func testScrollUpMultiple() {
        let g = makeGrid(cols: 4, rows: 3)
        write(g, "AAA")
        g.lineFeed(); g.carriageReturn()
        write(g, "BBB")
        g.scrollUp(count: 2)
        XCTAssertEqual(g.cell(row: 0, col: 0).char, " ")
        XCTAssertEqual(g.cell(row: 1, col: 0).char, " ")
        XCTAssertEqual(g.cell(row: 2, col: 0).char, " ")
    }

    // MARK: version

    func testVersionBumpsOnMutation() {
        let g = makeGrid()
        let v0 = g.version
        g.putChar("x")
        XCTAssertGreaterThan(g.version, v0)
    }

    // MARK: cursor positioning (M3.2)

    func testSetCursorClipsToBounds() {
        let g = makeGrid(cols: 8, rows: 4)
        g.setCursor(row: 2, col: 3) // 1-based → (1, 2) 0-based
        XCTAssertEqual(g.cursorRow, 1)
        XCTAssertEqual(g.cursorCol, 2)

        // Out of bounds → clip
        g.setCursor(row: 999, col: 999)
        XCTAssertEqual(g.cursorRow, 3)
        XCTAssertEqual(g.cursorCol, 7)

        // Zero / negative → clip to top-left
        g.setCursor(row: 0, col: 0)
        XCTAssertEqual(g.cursorRow, 0)
        XCTAssertEqual(g.cursorCol, 0)
    }

    func testCursorRelativeMoves() {
        let g = makeGrid(cols: 8, rows: 4)
        g.setCursor(row: 2, col: 4) // (1, 3)
        g.cursorUp(1)               // (0, 3)
        XCTAssertEqual(g.cursorRow, 0)
        g.cursorDown(2)             // (2, 3)
        XCTAssertEqual(g.cursorRow, 2)
        g.cursorForward(3)          // (2, 6)
        XCTAssertEqual(g.cursorCol, 6)
        g.cursorBack(5)             // (2, 1)
        XCTAssertEqual(g.cursorCol, 1)
    }

    func testCursorMovesClipAtEdges() {
        let g = makeGrid(cols: 4, rows: 3)
        g.cursorUp(10)
        XCTAssertEqual(g.cursorRow, 0)
        g.cursorBack(10)
        XCTAssertEqual(g.cursorCol, 0)
        g.cursorDown(100)
        XCTAssertEqual(g.cursorRow, 2)
        g.cursorForward(100)
        XCTAssertEqual(g.cursorCol, 3)
    }

    // MARK: erase (M3.2)

    func testEraseInLineFromCursorToEnd() {
        let g = makeGrid(cols: 6, rows: 2)
        write(g, "ABCDEF")     // cursor at (0, 5) with pendingWrap
        g.setCursor(row: 1, col: 4) // (0, 3) — explicit to clear pendingWrap
        g.eraseInLine(mode: 0)
        XCTAssertEqual(g.cell(row: 0, col: 2).char, "C")
        XCTAssertEqual(g.cell(row: 0, col: 3).char, " ")
        XCTAssertEqual(g.cell(row: 0, col: 5).char, " ")
    }

    func testEraseInLineFromStartToCursor() {
        let g = makeGrid(cols: 6, rows: 2)
        write(g, "ABCDEF")
        g.setCursor(row: 1, col: 4) // 0-based (0, 3)
        g.eraseInLine(mode: 1)
        XCTAssertEqual(g.cell(row: 0, col: 0).char, " ")
        XCTAssertEqual(g.cell(row: 0, col: 3).char, " ")
        XCTAssertEqual(g.cell(row: 0, col: 4).char, "E")
    }

    func testEraseInLineEntireLine() {
        let g = makeGrid(cols: 4, rows: 2)
        write(g, "AAAA")
        g.eraseInLine(mode: 2)
        for c in 0..<4 {
            XCTAssertEqual(g.cell(row: 0, col: c).char, " ")
        }
    }

    func testEraseInDisplayFromCursorToEnd() {
        let g = makeGrid(cols: 4, rows: 3)
        write(g, "AAAA")
        g.lineFeed(); g.carriageReturn()
        write(g, "BBBB")
        g.setCursor(row: 1, col: 3) // (0, 2) — middle of first row
        g.eraseInDisplay(mode: 0)
        XCTAssertEqual(g.cell(row: 0, col: 1).char, "A")
        XCTAssertEqual(g.cell(row: 0, col: 2).char, " ")
        XCTAssertEqual(g.cell(row: 1, col: 0).char, " ")
    }

    func testEraseInDisplayEntireScreenKeepsCursor() {
        let g = makeGrid(cols: 4, rows: 3)
        write(g, "AAAA")
        g.setCursor(row: 2, col: 2)
        g.eraseInDisplay(mode: 2)
        XCTAssertEqual(g.cell(row: 0, col: 0).char, " ")
        XCTAssertEqual(g.cursorRow, 1)
        XCTAssertEqual(g.cursorCol, 1)
    }

    // MARK: scroll down (M3.2)

    func testScrollDownInsertsBlankTopRows() {
        let g = makeGrid(cols: 4, rows: 3)
        write(g, "AAA")
        g.lineFeed(); g.carriageReturn()
        write(g, "BBB")
        g.scrollDown(count: 1)
        XCTAssertEqual(g.cell(row: 0, col: 0).char, " ")
        XCTAssertEqual(g.cell(row: 1, col: 0).char, "A")
        XCTAssertEqual(g.cell(row: 2, col: 0).char, "B")
    }

    // MARK: SGR (M3.3)

    func testSGRResetRestoresDefaultPen() {
        let g = makeGrid()
        g.applySGR([31]) // red
        XCTAssertEqual(g.pen.fg, Palette.normal16[1])
        g.applySGR([0])
        XCTAssertEqual(g.pen.fg, g.defaultPen.fg)
    }

    func testSGRBoldAndReset() {
        let g = makeGrid()
        g.applySGR([1])
        XCTAssertTrue(g.pen.bold)
        g.applySGR([22])
        XCTAssertFalse(g.pen.bold)
    }

    func testSGR256ColorFG() {
        let g = makeGrid()
        g.applySGR([38, 5, 196]) // 256-color red-ish
        let expected = Palette.color256(196)
        XCTAssertEqual(g.pen.fg, expected)
    }

    func testSGRTruecolorBG() {
        let g = makeGrid()
        g.applySGR([48, 2, 10, 20, 30])
        XCTAssertEqual(g.pen.bg, Palette.rgb(10, 20, 30))
    }

    func testPenAppliesToNewCells() {
        let g = makeGrid()
        g.applySGR([31])
        g.putChar("X")
        XCTAssertEqual(g.cell(row: 0, col: 0).attrs.fg, Palette.normal16[1])
    }

    // MARK: resize (M3.3)

    func testResizeGrowKeepsTopContent() {
        let g = makeGrid(cols: 4, rows: 2)
        write(g, "AAAA")
        g.resize(cols: 6, rows: 4)
        XCTAssertEqual(g.cols, 6)
        XCTAssertEqual(g.rows, 4)
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "A")
        XCTAssertEqual(g.cell(row: 0, col: 5).char, " ") // pad
        XCTAssertEqual(g.cell(row: 3, col: 0).char, " ") // pad bottom
    }

    func testResizeShrinkRowsKeepsBottom() {
        let g = makeGrid(cols: 4, rows: 3)
        write(g, "AAA")
        g.lineFeed(); g.carriageReturn()
        write(g, "BBB")
        g.lineFeed(); g.carriageReturn()
        write(g, "CCC")
        g.resize(cols: 4, rows: 2)
        // Bottom 2 rows kept: BBB, CCC
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "B")
        XCTAssertEqual(g.cell(row: 1, col: 0).char, "C")
    }

    func testResizeClipsCursor() {
        let g = makeGrid(cols: 8, rows: 8)
        g.setCursor(row: 8, col: 8) // bottom-right
        g.resize(cols: 4, rows: 4)
        XCTAssertLessThanOrEqual(g.cursorRow, 3)
        XCTAssertLessThanOrEqual(g.cursorCol, 3)
    }

    // MARK: scrollback (M3.5)

    func testScrollUpPushesEvictedRowToScrollback() {
        let g = makeGrid(cols: 4, rows: 2)
        write(g, "AAAA"); g.lineFeed(); g.carriageReturn()
        write(g, "BBBB")
        g.lineFeed() // forces scrollUp(1) since cursor is on bottom
        XCTAssertEqual(g.scrollback.count, 1)
        XCTAssertEqual(String(g.scrollback[0].map { $0.char }), "AAAA")
        XCTAssertEqual(g.scrollbackPushCount, 1)
    }

    func testScrollbackEvictsOldestPastLimit() {
        let g = makeGrid(cols: 2, rows: 2)
        g.maxScrollbackLines = 3
        // Force 5 lines to scroll off the top.
        for ch in ["A", "B", "C", "D", "E", "F"] {
            write(g, ch + ch)
            g.lineFeed(); g.carriageReturn()
        }
        XCTAssertEqual(g.scrollback.count, 3)
        XCTAssertEqual(g.scrollbackPushCount, 5) // 5 lines were pushed total
        // Oldest two ("AA", "BB") evicted; "CC" should be the oldest kept.
        XCTAssertEqual(String(g.scrollback[0].map { $0.char }), "CC")
    }

    func testResizeShrinkRowsPushesToScrollback() {
        let g = makeGrid(cols: 4, rows: 3)
        write(g, "AAA"); g.lineFeed(); g.carriageReturn()
        write(g, "BBB"); g.lineFeed(); g.carriageReturn()
        write(g, "CCC")
        g.resize(cols: 4, rows: 2)
        XCTAssertEqual(g.scrollback.count, 1)
        XCTAssertEqual(String(g.scrollback[0].map { $0.char }), "AAA ")
    }

    func testEraseInDisplayMode3ClearsScrollback() {
        let g = makeGrid(cols: 4, rows: 2)
        write(g, "AAAA"); g.lineFeed(); g.carriageReturn()
        write(g, "BBBB"); g.lineFeed()
        XCTAssertEqual(g.scrollback.count, 1)
        g.eraseInDisplay(mode: 3)
        XCTAssertTrue(g.scrollback.isEmpty)
    }

    func testClearScrollback() {
        let g = makeGrid(cols: 2, rows: 2)
        write(g, "AA"); g.lineFeed(); g.carriageReturn()
        write(g, "BB"); g.lineFeed()
        XCTAssertGreaterThan(g.scrollback.count, 0)
        g.clearScrollback()
        XCTAssertEqual(g.scrollback.count, 0)
    }
}
