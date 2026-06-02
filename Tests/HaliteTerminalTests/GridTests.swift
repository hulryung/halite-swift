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

    // MARK: soft-wrap flag (reflow Phase 1)

    func testSoftWrapMarksRowWrapped() {
        let g = makeGrid(cols: 4, rows: 4)
        write(g, "abcde") // 5 chars in 4-wide → row 0 auto-wraps into row 1
        XCTAssertTrue(g.rowWrapped(0), "auto-wrapped row 0 must be flagged wrapped")
        XCTAssertFalse(g.rowWrapped(1), "continuation row is not (yet) wrapped")
    }

    func testHardNewlineLeavesRowNotWrapped() {
        let g = makeGrid(cols: 8, rows: 4)
        write(g, "foo"); g.lineFeed(); g.carriageReturn()
        write(g, "bar")
        XCTAssertFalse(g.rowWrapped(0), "row ended by an explicit newline must not be wrapped")
        XCTAssertFalse(g.rowWrapped(1))
    }

    func testSoftWrapFlagRidesIntoScrollback() {
        let g = makeGrid(cols: 4, rows: 2)
        write(g, "abcde")  // row 0 ("abcd", wrapped) + row 1 ("e"); cursor on bottom row
        g.lineFeed()       // cursor at bottom → scrollUp pushes the wrapped row 0
        XCTAssertEqual(g.scrollback.count, 1)
        XCTAssertTrue(g.scrollback[0].wrapped, "wrap flag must follow the row into scrollback")
    }

    func testEraseLineClearsWrappedFlag() {
        let g = makeGrid(cols: 8, rows: 4)
        write(g, "abcdefghij")      // row 0 wraps ("abcdefgh"), row 1 = "ij"
        XCTAssertTrue(g.rowWrapped(0))
        g.setCursor(row: 1, col: 1) // back up to row 0 (1-based)
        g.eraseInLine(mode: 2)      // shell clears the line on redraw
        XCTAssertFalse(g.rowWrapped(0), "erasing a wrapped row must clear its wrap flag")
    }

    func testEraseLineToEndClearsWrappedFlag() {
        let g = makeGrid(cols: 8, rows: 4)
        write(g, "abcdefghij")
        g.setCursor(row: 1, col: 1)
        g.eraseInLine(mode: 0)      // cursor → end of line destroys the wrap point
        XCTAssertFalse(g.rowWrapped(0))
    }

    func testEraseDisplayClearsWrappedFlag() {
        let g = makeGrid(cols: 8, rows: 4)
        write(g, "abcdefghij")
        g.eraseInDisplay(mode: 2)
        XCTAssertFalse(g.rowWrapped(0))
    }

    // MARK: reflow (Phase 2)

    func testReflowNarrowToWideRejoinsWrappedLine() {
        let g = makeGrid(cols: 4, rows: 4)
        write(g, "abcdefg")          // row0 "abcd"(wrapped), row1 "efg"
        XCTAssertTrue(g.rowWrapped(0))
        g.resize(cols: 8, rows: 4)   // widen → the wrapped halves rejoin
        XCTAssertEqual(String(g.row(0).map { $0.char }), "abcdefg ")
        XCTAssertFalse(g.rowWrapped(0))
        XCTAssertEqual(g.cursorRow, 0)
        XCTAssertEqual(g.cursorCol, 7) // cursor parked just past "abcdefg"
    }

    func testReflowWideToNarrowSplitsLine() {
        let g = makeGrid(cols: 8, rows: 4)
        write(g, "abcdefghij")        // row0 "abcdefgh"(wrapped), row1 "ij"
        g.resize(cols: 4, rows: 4)    // narrow → re-split at width 4
        XCTAssertEqual(String(g.row(0).map { $0.char }), "abcd")
        XCTAssertTrue(g.rowWrapped(0))
        XCTAssertEqual(String(g.row(1).map { $0.char }), "efgh")
        XCTAssertTrue(g.rowWrapped(1))
        XCTAssertEqual(String(g.row(2).map { $0.char }), "ij  ")
        XCTAssertFalse(g.rowWrapped(2))
        XCTAssertEqual(g.cursorRow, 2)
        XCTAssertEqual(g.cursorCol, 2)
    }

    /// Regression: a narrowing reflow re-wraps the viewport into more physical
    /// rows than fit, pushing the overflow into scrollback — without bumping
    /// `scrollbackPushCount` (reflow rebuilds scrollback wholesale). So
    /// `scrollback.count` can exceed `scrollbackPushCount`, and the host's
    /// `scrollbackPushCount - count` eviction metric used to trap on UInt64
    /// underflow during a window resize. `linesEvictedFromTop` must clamp to 0.
    func testNarrowingReflowDoesNotUnderflowEvictionCount() {
        let g = makeGrid(cols: 8, rows: 2)
        write(g, "aaaaaaaabbbbbbbb")   // 16 chars = one soft-wrapped line filling both rows
        XCTAssertEqual(g.scrollbackPushCount, 0, "no scrollUp happened, so nothing was pushed")
        g.resize(cols: 4, rows: 2)     // reflow → 4 physical rows, 2 overflow into scrollback
        XCTAssertGreaterThan(g.scrollback.count, Int(g.scrollbackPushCount),
            "precondition: reflow grew scrollback past the push count")
        XCTAssertEqual(g.linesEvictedFromTop, 0,
            "eviction metric must clamp to 0, not trap on UInt64 underflow")
    }

    func testReflowKeepsHardNewlinesSeparate() {
        let g = makeGrid(cols: 8, rows: 4)
        write(g, "foo"); g.lineFeed(); g.carriageReturn()
        write(g, "bar")
        g.resize(cols: 4, rows: 4)    // must NOT merge two hard-newline lines
        XCTAssertEqual(String(g.row(0).map { $0.char }), "foo ")
        XCTAssertFalse(g.rowWrapped(0))
        XCTAssertEqual(String(g.row(1).map { $0.char }), "bar ")
        XCTAssertFalse(g.rowWrapped(1))
        XCTAssertEqual(g.cursorRow, 1)
        XCTAssertEqual(g.cursorCol, 3)
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

    func testSGRUnderlineAndStrikethrough() {
        let g = makeGrid()
        g.applySGR([4])
        XCTAssertTrue(g.pen.underline)
        g.applySGR([9])
        XCTAssertTrue(g.pen.strikethrough)
        g.applySGR([24])
        XCTAssertFalse(g.pen.underline, "24 clears underline")
        XCTAssertTrue(g.pen.strikethrough, "...but not strikethrough")
        g.applySGR([29])
        XCTAssertFalse(g.pen.strikethrough, "29 clears strikethrough")
        g.applySGR([4, 9])
        g.applySGR([0])
        XCTAssertFalse(g.pen.underline, "reset clears both")
        XCTAssertFalse(g.pen.strikethrough)
    }

    func testSkinToneModifierMergesIntoPreviousCell() {
        let g = makeGrid(cols: 10, rows: 2)
        g.putChar("👍")                  // wide base emoji
        g.putChar("\u{1F3FD}")           // skin-tone modifier echoed separately
        XCTAssertEqual(String(g.cell(row: 0, col: 0).char), "👍🏽", "modifier merged into the emoji")
        XCTAssertEqual(g.cursorCol, 2, "extender does not advance the cursor")
    }

    func testRegionalIndicatorsPairIntoFlag() {
        let g = makeGrid(cols: 10, rows: 2)
        g.putChar("\u{1F1F0}")           // 🇰
        g.putChar("\u{1F1F7}")           // 🇷 echoed separately
        XCTAssertEqual(String(g.cell(row: 0, col: 0).char), "🇰🇷", "two regional indicators form one flag")
        // A third RI starts a new flag rather than extending the first.
        g.putChar("\u{1F1EF}"); g.putChar("\u{1F1F5}")   // 🇯🇵
        XCTAssertEqual(String(g.cell(row: 0, col: 2).char), "🇯🇵")
    }

    func testZWJSequenceMergesAcrossWrites() {
        let g = makeGrid(cols: 12, rows: 2)
        for s in ["👨", "\u{200D}", "👩", "\u{200D}", "👧"] { g.putChar(Character(s)) }
        XCTAssertEqual(String(g.cell(row: 0, col: 0).char), "👨‍👩‍👧", "ZWJ family stays one grapheme")
        XCTAssertEqual(g.cursorCol, 2)
    }

    func testCombiningAccentMergesIntoLetter() {
        let g = makeGrid(cols: 10, rows: 2)
        g.putChar("e")
        g.putChar("\u{0301}")            // combining acute accent
        XCTAssertEqual(String(g.cell(row: 0, col: 0).char), "é")
        XCTAssertEqual(g.cursorCol, 1)
    }

    func testEmojiIsWideTwoCells() {
        XCTAssertTrue(Cell.isWide("😀"), "emoji presentation → 2-cell")
        XCTAssertTrue(Cell.isEmojiPresentation("😀"))
        let g = makeGrid(cols: 8, rows: 2)
        g.putChar("😀")
        XCTAssertEqual(g.cursorCol, 2, "wide emoji advances the cursor by 2")
        XCTAssertTrue(g.cell(row: 0, col: 1).isContinuation, "2nd cell is a continuation")
        XCTAssertFalse(Cell.isWide("A"), "ASCII stays 1-cell")
    }

    func testWideCharContinuationCarriesHyperlink() {
        let g = makeGrid(cols: 8, rows: 2)
        g.setHyperlink("https://example.com")
        g.putChar("한")   // wide: lead at col 0, continuation at col 1
        g.setHyperlink(nil)
        XCTAssertEqual(g.cell(row: 0, col: 0).hyperlink, "https://example.com")
        XCTAssertTrue(g.cell(row: 0, col: 1).isContinuation)
        XCTAssertEqual(g.cell(row: 0, col: 1).hyperlink, "https://example.com",
            "continuation must inherit the hyperlink so hover/click ranges don't break mid-wide-char")
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
        XCTAssertEqual(String(g.scrollback[0].cells.map { $0.char }), "AAAA")
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
        XCTAssertEqual(String(g.scrollback[0].cells.map { $0.char }), "CC")
    }

    func testSyncOutputModeDoesNotSuppressScrollbackPush() {
        // DEC 2026 sync는 presentation hint일 뿐 scrollback과 무관. sync 중에도
        // 화면 최상단(scrollTop==0)에서 위로 빠지는 줄은 정상적으로 scrollback에
        // 누적되어야 한다 — 안 그러면 Claude Code 같은 primary-screen TUI의 history가
        // 통째로 사라져 위로 스크롤이 안 됨.
        let g = makeGrid(cols: 4, rows: 2)
        write(g, "AAAA"); g.lineFeed(); g.carriageReturn()
        write(g, "BBBB")
        g.inSyncOutputMode = true
        g.lineFeed() // sync 중 scrollUp — 그래도 push 되어야 함.
        XCTAssertEqual(g.scrollback.count, 1)
        XCTAssertEqual(String(g.scrollback[0].cells.map { $0.char }), "AAAA")
    }

    func testAltScreenSuppressesScrollbackPush() {
        // alt-screen(vim/htop)에선 위로 빠지는 줄을 scrollback에 누적하지 않는다.
        let g = makeGrid(cols: 4, rows: 2)
        write(g, "AAAA"); g.lineFeed(); g.carriageReturn()
        write(g, "BBBB")
        g.enterAltScreen()
        // alt buffer는 cursor가 0행으로 리셋되므로 바닥까지 내려가 scrollUp을 유발.
        write(g, "XXXX"); g.lineFeed(); g.carriageReturn()
        write(g, "YYYY"); g.lineFeed() // 바닥 행에서 scrollUp — alt라 suppress.
        XCTAssertEqual(g.scrollback.count, 0)
    }

    func testResizeShrinkRowsPushesToScrollback() {
        let g = makeGrid(cols: 4, rows: 3)
        write(g, "AAA"); g.lineFeed(); g.carriageReturn()
        write(g, "BBB"); g.lineFeed(); g.carriageReturn()
        write(g, "CCC")
        g.resize(cols: 4, rows: 2)
        XCTAssertEqual(g.scrollback.count, 1)
        XCTAssertEqual(String(g.scrollback[0].cells.map { $0.char }), "AAA ")
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
