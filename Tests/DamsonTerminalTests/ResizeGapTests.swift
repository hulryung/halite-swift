import XCTest
@testable import DamsonTerminal

/// Regression tests for the "zoom gap": cycling the grid size (as font zoom does —
/// cols AND rows together) must not leave blank rows between the last content row
/// and the shell prompt. Reported: after zooming in/out, the prompt drifts away from
/// the output (one blank row per reflow at grid level; visually a large gap when the
/// shell then redraws at the bottom).
final class ResizeGapTests: XCTestCase {

    // MARK: - Pure-grid reflow invariant (no shell)

    /// Write content + a prompt-like line, cycle cols+rows down and back up, and
    /// require the cursor to sit DIRECTLY under the content with no blank rows
    /// in between — at every step of the cycle.
    func testReflowCycleLeavesNoGapAboveCursor() {
        let g = Grid(cols: 110, rows: 45, pen: CellAttrs(fg: .default))
        func type(_ s: String) {
            for ch in s {
                if ch == "\n" { g.lineFeed(); g.carriageReturn() }
                else { g.putChar(ch) }
            }
        }
        type("HELLO-A\nHELLO-B\nPROMPT> ")

        let sizes = [(62, 20), (110, 45), (58, 23), (83, 33), (110, 45)]
        for (cols, rows) in sizes {
            g.resize(cols: cols, rows: rows)
            // Locate the last non-blank row and the cursor row.
            var lastContent = -1
            for r in 0..<g.rows {
                let blank = g.row(r).allSatisfy { $0.isContinuation || $0.char == " " }
                if !blank { lastContent = r }
            }
            XCTAssertEqual(g.cursorRow, lastContent,
                           "after \(cols)x\(rows): cursor (row \(g.cursorRow)) must sit on the "
                           + "last content row (\(lastContent)) — a gap means reflow drifted")
            // And the rows above the cursor must be gap-free back to the content.
            let text = (0...max(0, lastContent)).map { r in
                String(g.row(r).filter { !$0.isContinuation && !$0.isWideSpacer }.map(\.char))
                    .trimmingCharacters(in: .whitespaces)
            }
            let blanksInside = text.dropLast().enumerated()
                .filter { $0.element.isEmpty && $0.offset > 0 }
            XCTAssertTrue(blanksInside.isEmpty,
                          "after \(cols)x\(rows): blank rows \(blanksInside.map(\.offset)) "
                          + "appeared inside content:\n\(text.joined(separator: "\n"))")
        }
    }

    // MARK: - Real-shell interplay (zsh + SIGWINCH + reflow)

    /// The end-to-end version: a real interactive zsh redraws its prompt on every
    /// SIGWINCH while the grid reflows. After cycling sizes, the prompt must still
    /// sit directly under the last output line (no accumulated blank gap).
    func testZshZoomCycleKeepsPromptUnderContent() throws {
        let marker = "ZOOMGAP_\(UInt32.random(in: 1000...99999))"
        var config = DamsonConfig()
        config.argv = ["/bin/zsh", "-f", "-i"]   // -f: no rc; deterministic prompt
        config.env = ["TERM": "xterm-256color", "HOME": NSTemporaryDirectory(),
                      "PATH": "/usr/bin:/bin", "PS1": "PROMPT> "]
        let session = DamsonSession(config: config)
        defer { session.terminate() }
        session.resize(cols: 110, rows: 45)

        func settle(_ t: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }
        settle(1.0)
        session.write(Data("clear; echo \(marker)-A; echo \(marker)-B\n".utf8))
        settle(0.8)

        for (cols, rows) in [(62, 20), (110, 45), (58, 23), (83, 33), (110, 45)] {
            session.resize(cols: cols, rows: rows)
            settle(0.5)   // let zsh's SIGWINCH redraw land
        }

        let g = session.grid
        var rowsText: [String] = []
        for r in 0..<g.rows {
            rowsText.append(String(g.row(r).filter { !$0.isContinuation && !$0.isWideSpacer }
                .map(\.char)).trimmingCharacters(in: .whitespaces))
        }
        guard let bRow = rowsText.lastIndex(where: { $0.contains("\(marker)-B") }) else {
            return XCTFail("marker output missing from grid:\n" + rowsText.joined(separator: "\n"))
        }
        guard let lastContent = rowsText.lastIndex(where: { !$0.isEmpty }) else {
            return XCTFail("empty grid")
        }
        // Everything between the output and the final prompt row must be non-blank
        // (the prompt sits directly under the content — zero gap rows).
        let between = rowsText[(bRow + 1)...lastContent]
        let gaps = between.filter { $0.isEmpty }
        XCTAssertTrue(gaps.isEmpty,
                      "blank gap rows between output (row \(bRow)) and prompt (row \(lastContent)):\n"
                      + rowsText[0...lastContent].joined(separator: "\n"))
    }
}
