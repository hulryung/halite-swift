import AppKit
import XCTest
@testable import HaliteTerminal

final class GridTests: XCTestCase {
    private func makeGrid(cols: Int = 8, rows: Int = 4) -> Grid {
        Grid(cols: cols, rows: rows, pen: CellAttrs(fg: .default))
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
        g.applySGR([31]) // red → palette(1)
        XCTAssertEqual(g.pen.fg, .palette(1))
        g.applySGR([0])
        XCTAssertEqual(g.pen.fg, g.defaultPen.fg)
    }

    func testSGRBrightFGMapsToPaletteIndex8Plus() {
        let g = makeGrid()
        g.applySGR([91]) // bright red → palette(9)
        XCTAssertEqual(g.pen.fg, .palette(9))
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
        g.applySGR([38, 5, 196]) // 256-color index
        XCTAssertEqual(g.pen.fg, .palette(196))
    }

    func testSGRTruecolorBG() {
        let g = makeGrid()
        g.applySGR([48, 2, 10, 20, 30])
        XCTAssertEqual(g.pen.bg, .rgb(10, 20, 30))
    }

    func testPenAppliesToNewCells() {
        let g = makeGrid()
        g.applySGR([31])
        g.putChar("X")
        XCTAssertEqual(g.cell(row: 0, col: 0).attrs.fg, .palette(1))
    }

    // 테마 resolve — 같은 grid를 다른 테마로 그리면 indexed 색은 달라지고
    // truecolor는 동일.
    func testThemeResolvesIndexedDifferentlyButRGBSame() {
        let indexed = CellAttrs(fg: .palette(1))
        let truecolor = CellAttrs(fg: .rgb(10, 20, 30))
        let dark = HaliteTheme.defaultDark
        let dracula = HaliteTheme.dracula
        // indexed: 테마마다 ANSI red가 다름.
        XCTAssertNotEqual(indexed.resolvedColors(theme: dark).fg,
                          indexed.resolvedColors(theme: dracula).fg)
        // truecolor: 절대값이라 테마 무관.
        XCTAssertEqual(truecolor.resolvedColors(theme: dark).fg,
                       truecolor.resolvedColors(theme: dracula).fg)
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

    func testSyncOutputModeSuppressesScrollbackPush() {
        // DEC 2026 sync frame 중 line-feed로 발생하는 scrollUp은 scrollback에
        // 누적하지 않는다 (primary-screen TUI redraw burst). 이 불변식이 깨지면
        // redraw가 history를 오염시키고 화면에 중복/덮어쓰기로 보임.
        let g = makeGrid(cols: 4, rows: 2)
        write(g, "AAAA"); g.lineFeed(); g.carriageReturn()
        write(g, "BBBB")
        g.inSyncOutputMode = true
        g.lineFeed() // sync 중 scrollUp — push 되면 안 됨.
        XCTAssertEqual(g.scrollback.count, 0)
        XCTAssertEqual(g.scrollbackPushCount, 0)
        // sync 종료 후의 scrollUp은 정상적으로 누적.
        g.inSyncOutputMode = false
        g.carriageReturn(); write(g, "CCCC")
        g.lineFeed()
        XCTAssertEqual(g.scrollback.count, 1)
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

    // MARK: cursor visibility (M3.6)

    func testCursorVisibleDefaultsTrue() {
        let g = makeGrid()
        XCTAssertTrue(g.cursorVisible)
    }

    func testSetCursorVisibleBumpsVersion() {
        let g = makeGrid()
        let v0 = g.version
        g.setCursorVisible(false)
        XCTAssertFalse(g.cursorVisible)
        XCTAssertGreaterThan(g.version, v0)
    }

    func testSetCursorVisibleNoOpIfSame() {
        let g = makeGrid()
        let v0 = g.version
        g.setCursorVisible(true) // already true
        XCTAssertEqual(g.version, v0)
    }

    // MARK: alt screen (M3.7)

    func testEnterAltScreenStartsBlank() {
        let g = makeGrid(cols: 4, rows: 2)
        write(g, "ABCD"); g.lineFeed(); g.carriageReturn()
        write(g, "EFGH")
        g.enterAltScreen()
        XCTAssertTrue(g.isAltScreenActive)
        XCTAssertEqual(g.cursorRow, 0)
        XCTAssertEqual(g.cursorCol, 0)
        for r in 0..<2 {
            for c in 0..<4 {
                XCTAssertEqual(g.cell(row: r, col: c).char, " ")
            }
        }
    }

    func testLeaveAltScreenRestoresPrimary() {
        let g = makeGrid(cols: 4, rows: 2)
        write(g, "ABCD"); g.lineFeed(); g.carriageReturn()
        write(g, "EFG")
        let savedRow = g.cursorRow
        let savedCol = g.cursorCol
        g.enterAltScreen()
        write(g, "XYZW") // alt 내용
        g.leaveAltScreen()
        XCTAssertFalse(g.isAltScreenActive)
        XCTAssertEqual(g.cursorRow, savedRow)
        XCTAssertEqual(g.cursorCol, savedCol)
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "A")
        XCTAssertEqual(g.cell(row: 1, col: 2).char, "G")
    }

    func testAltScreenDoesNotPushToScrollback() {
        let g = makeGrid(cols: 2, rows: 2)
        // Primary: push one line off first
        write(g, "AA"); g.lineFeed(); g.carriageReturn()
        write(g, "BB"); g.lineFeed()
        let scrollbackBeforeAlt = g.scrollback.count
        XCTAssertGreaterThan(scrollbackBeforeAlt, 0)

        g.enterAltScreen()
        // Alt 스크롤백은 0이어야 함
        XCTAssertEqual(g.scrollback.count, 0)
        // alt 내에서 한참 흘려도 scrollback 안 생김
        for _ in 0..<5 {
            write(g, "XX"); g.lineFeed(); g.carriageReturn()
        }
        XCTAssertEqual(g.scrollback.count, 0)

        g.leaveAltScreen()
        // 복귀 후 primary scrollback 복원
        XCTAssertEqual(g.scrollback.count, scrollbackBeforeAlt)
    }

    func testEnterAltScreenIdempotent() {
        let g = makeGrid()
        g.enterAltScreen()
        let v1 = g.version
        g.enterAltScreen() // no-op
        XCTAssertEqual(g.version, v1)
    }

    func testLeaveAltScreenWithoutEnterIsNoOp() {
        let g = makeGrid()
        let v0 = g.version
        g.leaveAltScreen()
        XCTAssertEqual(g.version, v0)
        XCTAssertFalse(g.isAltScreenActive)
    }

    func testResizeWhileInAltKeepsSavedPrimaryConsistent() {
        let g = makeGrid(cols: 4, rows: 3)
        write(g, "AAA"); g.lineFeed(); g.carriageReturn()
        write(g, "BBB")
        g.enterAltScreen()
        write(g, "alt!")
        g.resize(cols: 6, rows: 4)
        g.leaveAltScreen()
        // 복귀 후 grid는 새 크기지만 primary 내용은 잘 살아있어야 함
        XCTAssertEqual(g.cols, 6)
        XCTAssertEqual(g.rows, 4)
        // "AAA"가 첫줄에 있어야 (grow 시 위쪽 정렬 유지)
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "A")
        XCTAssertEqual(g.cell(row: 1, col: 0).char, "B")
    }

    // MARK: scroll region — DECSTBM (M3.8)

    func testSetScrollRegionAndCursorHome() {
        let g = makeGrid(cols: 4, rows: 6)
        g.setCursor(row: 4, col: 3)
        g.setScrollRegion(top: 1, bottom: 4) // rows 1..4 inclusive
        XCTAssertEqual(g.scrollTop, 1)
        XCTAssertEqual(g.scrollBottom, 4)
        // cursor → (0, 0)
        XCTAssertEqual(g.cursorRow, 0)
        XCTAssertEqual(g.cursorCol, 0)
    }

    func testSetScrollRegionRejectsInvalidRange() {
        let g = makeGrid(cols: 4, rows: 4)
        g.setScrollRegion(top: 2, bottom: 1) // bottom < top → 무시
        XCTAssertEqual(g.scrollTop, 0)
        XCTAssertEqual(g.scrollBottom, 3)
    }

    func testScrollUpOnlyAffectsRegion() {
        let g = makeGrid(cols: 2, rows: 5)
        // 0: AA, 1: BB, 2: CC, 3: DD, 4: EE — write 5줄, 마지막 LF은 생략 (안 그러면 scrollUp)
        let labels = ["A", "B", "C", "D", "E"]
        for (i, label) in labels.enumerated() {
            write(g, label + label)
            if i < labels.count - 1 {
                g.lineFeed(); g.carriageReturn()
            }
        }
        // region rows 1..3 (BB, CC, DD); row 0 (AA) and row 4 (EE) frozen
        g.setScrollRegion(top: 1, bottom: 3)
        g.scrollUp(count: 1)
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "A") // frozen
        XCTAssertEqual(g.cell(row: 1, col: 0).char, "C") // shifted up
        XCTAssertEqual(g.cell(row: 2, col: 0).char, "D") // shifted up
        XCTAssertEqual(g.cell(row: 3, col: 0).char, " ") // blank
        XCTAssertEqual(g.cell(row: 4, col: 0).char, "E") // frozen
    }

    func testScrollDownOnlyAffectsRegion() {
        let g = makeGrid(cols: 2, rows: 5)
        let labels = ["A", "B", "C", "D", "E"]
        for (i, label) in labels.enumerated() {
            write(g, label + label)
            if i < labels.count - 1 {
                g.lineFeed(); g.carriageReturn()
            }
        }
        g.setScrollRegion(top: 1, bottom: 3)
        g.scrollDown(count: 1)
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "A") // frozen
        XCTAssertEqual(g.cell(row: 1, col: 0).char, " ") // blank (new top)
        XCTAssertEqual(g.cell(row: 2, col: 0).char, "B") // shifted down
        XCTAssertEqual(g.cell(row: 3, col: 0).char, "C") // shifted down
        XCTAssertEqual(g.cell(row: 4, col: 0).char, "E") // frozen
    }

    func testLineFeedAtScrollBottomScrollsRegion() {
        let g = makeGrid(cols: 2, rows: 5)
        g.setScrollRegion(top: 1, bottom: 3) // region rows 1..3
        // row 1, 2, 3 각각에 표식 작성
        g.setCursor(row: 2, col: 1); write(g, "XX") // row 1
        g.setCursor(row: 3, col: 1); write(g, "YY") // row 2
        g.setCursor(row: 4, col: 1); write(g, "ZZ") // row 3 (scrollBottom)
        // cursor가 scrollBottom (3, 1)에 있고 pendingWrap. setCursor로 정리.
        g.setCursor(row: 4, col: 2)
        g.lineFeed()
        // 커서는 scrollBottom 그대로 유지
        XCTAssertEqual(g.cursorRow, 3)
        // region 안에서 1줄 shift up: row 1 = (was row 2) = "YY", row 2 = "ZZ", row 3 = blank
        XCTAssertEqual(g.cell(row: 1, col: 0).char, "Y")
        XCTAssertEqual(g.cell(row: 2, col: 0).char, "Z")
        XCTAssertEqual(g.cell(row: 3, col: 0).char, " ")
    }

    func testLineFeedBelowScrollBottomDoesNotScroll() {
        let g = makeGrid(cols: 2, rows: 5)
        g.setScrollRegion(top: 0, bottom: 2) // bottom of region is row 2
        // Move cursor below region (row 3)
        g.setCursor(row: 4, col: 1) // (3, 0)
        write(g, "XX")
        // cursor now at (3, 2) but pendingWrap. Force position.
        g.setCursor(row: 4, col: 1) // (3, 0)
        g.lineFeed() // 그냥 row 4로 이동, scrollUp 안 일어남
        XCTAssertEqual(g.cursorRow, 4)
        // row 3 contents 그대로
        XCTAssertEqual(g.cell(row: 3, col: 0).char, "X")
    }

    func testResizeResetsScrollRegion() {
        let g = makeGrid(cols: 4, rows: 6)
        g.setScrollRegion(top: 1, bottom: 4)
        g.resize(cols: 4, rows: 8)
        XCTAssertEqual(g.scrollTop, 0)
        XCTAssertEqual(g.scrollBottom, 7)
    }

    func testAltScreenHasIndependentScrollRegion() {
        let g = makeGrid(cols: 4, rows: 6)
        g.setScrollRegion(top: 1, bottom: 4)
        g.enterAltScreen()
        XCTAssertEqual(g.scrollTop, 0)
        XCTAssertEqual(g.scrollBottom, 5) // alt는 전체 화면 region으로 시작
        g.setScrollRegion(top: 2, bottom: 3)
        g.leaveAltScreen()
        // primary 복귀 시 원래 region이 복원되어야 함
        XCTAssertEqual(g.scrollTop, 1)
        XCTAssertEqual(g.scrollBottom, 4)
    }

    func testScrollUpInRegionDoesNotPushToScrollbackWhenTopNonZero() {
        let g = makeGrid(cols: 2, rows: 4)
        g.setScrollRegion(top: 1, bottom: 3)
        g.scrollUp(count: 1)
        XCTAssertEqual(g.scrollback.count, 0) // top != 0 이면 push 안 함
    }

    // MARK: M3.9 — CHA / VPA / ECH / SC / RC

    func testSetCursorColumnAbsolute() {
        let g = makeGrid(cols: 8, rows: 4)
        g.setCursor(row: 3, col: 1) // (2, 0)
        g.setCursorColumn(5) // 1-based → col 4
        XCTAssertEqual(g.cursorRow, 2) // row 유지
        XCTAssertEqual(g.cursorCol, 4)
    }

    func testSetCursorRowAbsolute() {
        let g = makeGrid(cols: 4, rows: 8)
        g.setCursor(row: 2, col: 3) // (1, 2)
        g.setCursorRow(6) // 1-based → row 5
        XCTAssertEqual(g.cursorRow, 5)
        XCTAssertEqual(g.cursorCol, 2) // col 유지
    }

    func testEraseChars() {
        let g = makeGrid(cols: 8, rows: 2)
        write(g, "ABCDEFGH")
        g.setCursor(row: 1, col: 3) // (0, 2)
        g.eraseChars(3) // cols 2,3,4 blank
        XCTAssertEqual(g.cell(row: 0, col: 1).char, "B")
        XCTAssertEqual(g.cell(row: 0, col: 2).char, " ")
        XCTAssertEqual(g.cell(row: 0, col: 4).char, " ")
        XCTAssertEqual(g.cell(row: 0, col: 5).char, "F")
        // cursor 위치 그대로
        XCTAssertEqual(g.cursorRow, 0)
        XCTAssertEqual(g.cursorCol, 2)
    }

    func testEraseCharsClipsAtRowEnd() {
        let g = makeGrid(cols: 4, rows: 2)
        write(g, "ABCD")
        g.setCursor(row: 1, col: 3) // (0, 2)
        g.eraseChars(10) // 끝까지만
        XCTAssertEqual(g.cell(row: 0, col: 2).char, " ")
        XCTAssertEqual(g.cell(row: 0, col: 3).char, " ")
    }

    func testSaveAndRestoreCursor() {
        let g = makeGrid(cols: 8, rows: 4)
        g.setCursor(row: 3, col: 5) // (2, 4)
        g.applySGR([31]) // red
        g.saveCursor()
        g.setCursor(row: 1, col: 1) // (0, 0)
        g.applySGR([34]) // blue
        g.restoreCursor()
        XCTAssertEqual(g.cursorRow, 2)
        XCTAssertEqual(g.cursorCol, 4)
        // pen도 복원
        XCTAssertEqual(g.pen.fg, .palette(1)) // red
    }

    func testRestoreCursorWithoutSaveIsNoOp() {
        let g = makeGrid()
        g.setCursor(row: 2, col: 3) // (1, 2)
        let v0 = g.version
        g.restoreCursor()
        XCTAssertEqual(g.version, v0)
        XCTAssertEqual(g.cursorRow, 1)
        XCTAssertEqual(g.cursorCol, 2)
    }

    // MARK: M5 slice — East Asian Wide

    func testWideCharOccupiesTwoCells() {
        let g = makeGrid(cols: 6, rows: 2)
        g.putChar("한")
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "한")
        XCTAssertFalse(g.cell(row: 0, col: 0).isContinuation)
        XCTAssertTrue(g.cell(row: 0, col: 1).isContinuation)
        XCTAssertEqual(g.cursorCol, 2)
    }

    func testWideCharThenNarrowCharLayout() {
        let g = makeGrid(cols: 6, rows: 2)
        g.putChar("한")
        g.putChar("x")
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "한")
        XCTAssertTrue(g.cell(row: 0, col: 1).isContinuation)
        XCTAssertEqual(g.cell(row: 0, col: 2).char, "x")
        XCTAssertEqual(g.cursorCol, 3)
    }

    func testWideCharBackspaceSequenceClearsBoth() {
        // 셸이 wide char 삭제용으로 보내는 \b\b  \b\b 시퀀스를 시뮬레이션.
        let g = makeGrid(cols: 6, rows: 2)
        g.putChar("한")
        g.putChar("국")
        XCTAssertEqual(g.cursorCol, 4)
        // 셸 시퀀스: \b\b  \b\b
        g.backspace(); g.backspace()                  // cursor: 4 → 3 → 2
        XCTAssertEqual(g.cursorCol, 2)
        g.putChar(" "); g.putChar(" ")                // cell[2]=' ', cell[3]=' '
        g.backspace(); g.backspace()                  // cursor: 4 → 3 → 2
        // "국"이 차지했던 cell 2, 3 둘 다 비워졌고, "한"은 그대로 cell 0, 1.
        XCTAssertEqual(g.cell(row: 0, col: 0).char, "한")
        XCTAssertTrue(g.cell(row: 0, col: 1).isContinuation)
        XCTAssertEqual(g.cell(row: 0, col: 2).char, " ")
        XCTAssertEqual(g.cell(row: 0, col: 3).char, " ")
        XCTAssertEqual(g.cursorCol, 2)
    }

    func testWideCharWrapsAtLastColumn() {
        // 마지막 열에 wide char 들어오면, 그 열은 비우고 다음 줄로 wrap.
        let g = makeGrid(cols: 3, rows: 2)
        g.putChar("a")  // col 0
        g.putChar("b")  // col 1
        // col 2 (마지막)에 wide char "한"이 들어오려 하면 → wrap
        g.putChar("한")
        XCTAssertEqual(g.cell(row: 1, col: 0).char, "한")
        XCTAssertTrue(g.cell(row: 1, col: 1).isContinuation)
        XCTAssertEqual(g.cursorRow, 1)
        XCTAssertEqual(g.cursorCol, 2)
    }

    func testSavedCursorIsolatedAcrossAltScreen() {
        let g = makeGrid(cols: 4, rows: 4)
        g.setCursor(row: 4, col: 4) // (3, 3)
        g.saveCursor()
        g.enterAltScreen()
        // alt에선 saved 비어있음
        let altCheckpoint = g.cursorRow
        XCTAssertEqual(altCheckpoint, 0)
        g.restoreCursor() // no-op
        XCTAssertEqual(g.cursorRow, 0)
        g.leaveAltScreen()
        // primary 복귀 후 saved 살아있어야 함
        g.setCursor(row: 1, col: 1) // (0, 0)
        g.restoreCursor()
        XCTAssertEqual(g.cursorRow, 3)
        XCTAssertEqual(g.cursorCol, 3)
    }
}
