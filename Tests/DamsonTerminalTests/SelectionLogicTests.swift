import XCTest
@testable import DamsonTerminal

final class SelectionLogicTests: XCTestCase {

    // MARK: - Bundle 2: soft-wrap-aware copy joining

    func testJoinHardBreaksGetNewlines() {
        let rows = [
            SelectionLogic.CopyRow(text: "foo", wrappedToNext: false),
            SelectionLogic.CopyRow(text: "bar", wrappedToNext: false),
        ]
        XCTAssertEqual(SelectionLogic.joinForCopy(rows), "foo\nbar")
    }

    func testJoinSoftWrapHasNoNewline() {
        // Two rows belonging to one soft-wrapped logical line — no newline between.
        let rows = [
            SelectionLogic.CopyRow(text: "hello", wrappedToNext: true),
            SelectionLogic.CopyRow(text: "world", wrappedToNext: false),
        ]
        XCTAssertEqual(SelectionLogic.joinForCopy(rows), "helloworld")
    }

    func testJoinTrimsTrailingSpacesAtHardBreakOnly() {
        let rows = [
            SelectionLogic.CopyRow(text: "foo   ", wrappedToNext: false),
            SelectionLogic.CopyRow(text: "bar  ", wrappedToNext: false),
        ]
        // Trailing spaces trimmed on each hard-broken line.
        XCTAssertEqual(SelectionLogic.joinForCopy(rows), "foo\nbar")
    }

    func testJoinPreservesSpacesAtSoftWrapJoin() {
        // A wrapped line that ends in spaces must keep them — they're part of the
        // logical line, not row padding.
        let rows = [
            SelectionLogic.CopyRow(text: "foo  ", wrappedToNext: true),
            SelectionLogic.CopyRow(text: "bar", wrappedToNext: false),
        ]
        XCTAssertEqual(SelectionLogic.joinForCopy(rows), "foo  bar")
    }

    func testJoinTrimsTrailingSpacesOnLastRow() {
        let rows = [
            SelectionLogic.CopyRow(text: "foo", wrappedToNext: true),
            SelectionLogic.CopyRow(text: "bar   ", wrappedToNext: false),
        ]
        XCTAssertEqual(SelectionLogic.joinForCopy(rows), "foobar")
    }

    func testJoinMixedWrapAndHard() {
        let rows = [
            SelectionLogic.CopyRow(text: "aaa", wrappedToNext: true),
            SelectionLogic.CopyRow(text: "bbb", wrappedToNext: false),
            SelectionLogic.CopyRow(text: "ccc", wrappedToNext: false),
        ]
        XCTAssertEqual(SelectionLogic.joinForCopy(rows), "aaabbb\nccc")
    }

    // MARK: - Bundle 3: block column math

    func testBlockColumnsNormalizes() {
        XCTAssertEqual(SelectionLogic.blockColumns(anchorCol: 5, headCol: 2, cols: 80), 2..<5)
        XCTAssertEqual(SelectionLogic.blockColumns(anchorCol: 2, headCol: 5, cols: 80), 2..<5)
    }

    func testBlockColumnsClampsToCols() {
        XCTAssertEqual(SelectionLogic.blockColumns(anchorCol: 3, headCol: 200, cols: 80), 3..<80)
    }

    func testBlockColumnsEmptyWhenSame() {
        XCTAssertNil(SelectionLogic.blockColumns(anchorCol: 4, headCol: 4, cols: 80))
    }

    // MARK: - Bundle 4: word separators

    func testWordSpanDefaultWhitespace() {
        let chars = Array("foo bar baz")
        XCTAssertEqual(SelectionLogic.wordSpan(in: chars, col: 5, separators: " \t"), 4..<7)
    }

    func testWordSpanOnSeparatorIsNil() {
        let chars = Array("foo bar")
        XCTAssertNil(SelectionLogic.wordSpan(in: chars, col: 3, separators: " \t"))
    }

    func testWordSpanTreatsPathCharsAsWordWhenNotSeparators() {
        // Default separators are just whitespace, so a path selects whole.
        let chars = Array("see /usr/local/bin here")
        // col 8 is inside the path
        let span = SelectionLogic.wordSpan(in: chars, col: 8, separators: " \t")
        XCTAssertEqual(span.map { String(chars[$0]) }, "/usr/local/bin")
    }

    func testWordSpanRespectsCustomSeparators() {
        // If "/" is a separator, the path splits into components.
        let chars = Array("/usr/local")
        let span = SelectionLogic.wordSpan(in: chars, col: 2, separators: " \t/")
        XCTAssertEqual(span.map { String(chars[$0]) }, "usr")
    }

    // MARK: - Bundle 4: smart selection rules

    func testSmartURL() {
        let text = "open https://example.com/path?q=1 now"
        let idx = text.distance(from: text.startIndex,
                                to: text.range(of: "example")!.lowerBound)
        let r = SelectionLogic.smartTokenRange(in: text, at: idx)
        XCTAssertEqual(r.map { String(Array(text)[$0]) }, "https://example.com/path?q=1")
    }

    func testSmartEmail() {
        let text = "mail to alice@example.com please"
        let idx = text.distance(from: text.startIndex,
                                to: text.range(of: "alice")!.lowerBound)
        let r = SelectionLogic.smartTokenRange(in: text, at: idx)
        XCTAssertEqual(r.map { String(Array(text)[$0]) }, "alice@example.com")
    }

    func testSmartPathAbsolute() {
        let text = "cat /usr/local/bin/foo and more"
        let idx = text.distance(from: text.startIndex,
                                to: text.range(of: "local")!.lowerBound)
        let r = SelectionLogic.smartTokenRange(in: text, at: idx)
        XCTAssertEqual(r.map { String(Array(text)[$0]) }, "/usr/local/bin/foo")
    }

    func testSmartPathTilde() {
        let text = "edit ~/.config/foo.toml today"
        let idx = text.distance(from: text.startIndex,
                                to: text.range(of: "config")!.lowerBound)
        let r = SelectionLogic.smartTokenRange(in: text, at: idx)
        XCTAssertEqual(r.map { String(Array(text)[$0]) }, "~/.config/foo.toml")
    }

    func testSmartPlainWordNoMatch() {
        // A plain identifier has no smart token → caller falls back to word span.
        let text = "let value_count = 3"
        let idx = text.distance(from: text.startIndex,
                                to: text.range(of: "count")!.lowerBound)
        XCTAssertNil(SelectionLogic.smartTokenRange(in: text, at: idx))
    }

    func testSmartNoMatchOnWhitespace() {
        let text = "a   b"
        XCTAssertNil(SelectionLogic.smartTokenRange(in: text, at: 2))
    }

    // MARK: - Bundle 4: semantic range from prompt marks

    func testLastCommandOutputWithTwoMarks() {
        // marks at row 2 and row 10, cursor at 15 → output is rows 11...15.
        let r = SelectionLogic.lastCommandOutputRows(promptRows: [2, 10], cursorRow: 15)
        XCTAssertEqual(r, 11...15)
    }

    func testLastCommandOutputWithOneMark() {
        let r = SelectionLogic.lastCommandOutputRows(promptRows: [4], cursorRow: 9)
        XCTAssertEqual(r, 5...9)
    }

    func testLastCommandOutputNoMarks() {
        XCTAssertNil(SelectionLogic.lastCommandOutputRows(promptRows: [], cursorRow: 9))
    }

    func testLastCommandOutputCursorAtPrompt() {
        // Cursor right at the prompt line — clamp so start <= end.
        let r = SelectionLogic.lastCommandOutputRows(promptRows: [10], cursorRow: 10)
        XCTAssertEqual(r, 11...11)
    }
}
