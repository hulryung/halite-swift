import AppKit
import Foundation

/// 2D cell grid + cursor. Mutated per VT/ANSI semantics.
/// M3 covers only the viewport (= current screen); scrollback arrives in M3.5.
///
/// All methods assume the caller serializes on the main thread (DamsonSession guarantees it).
public final class Grid {
    public private(set) var cols: Int
    public private(set) var rows: Int

    /// Cell storage: `cells[row][col]`. Always kept at `rows × cols`.
    /// Each row is a `Line` (cell array + soft-wrap bit). The wrap bit is used by reflow.
    private var cells: [Line]

    /// Cursor (0-based).
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorCol: Int = 0

    /// Marks that the next putChar must wrap. xterm-style "deferred wrap":
    /// set right after a cell lands in the last column; the next printable moves the cursor down.
    private var pendingWrap: Bool = false

    /// Cursor visibility, toggled by DECTCEM (`\e[?25h` / `\e[?25l`).
    /// Used by shells that briefly hide the cursor while drawing the prompt.
    public private(set) var cursorVisible: Bool = true

    /// Cursor shape, set by DECSCUSR (`CSI Ps SP q`) or the user's default config.
    public enum CursorShape: String, CaseIterable {
        case block, underline, bar
    }
    public private(set) var cursorShape: CursorShape = .block

    /// OSC 8 hyperlink — the currently active URI. nil means inactive.
    /// Attached to cells newly written by subsequent `putChar`s.
    public private(set) var currentHyperlink: String? = nil

    /// DECSTBM scroll region top (0-based, inclusive). Defaults to 0.
    public private(set) var scrollTop: Int = 0
    /// DECSTBM scroll region bottom (0-based, inclusive). Defaults to rows - 1.
    public private(set) var scrollBottom: Int = 0

    /// Cursor + pen snapshot saved by DECSC/DECRC (or CSI s/u).
    /// Each buffer (primary/alt) needs its own saved state — included in the alt screen snapshot.
    private var savedCursorRow: Int = 0
    private var savedCursorCol: Int = 0
    private var savedPen: CellAttrs? = nil

    /// Current pen attributes. Updated by SGR.
    public var pen: CellAttrs

    /// The default pen restored by SGR 0 (reset).
    public let defaultPen: CellAttrs

    /// Monotonically increasing version the host watches for updates. +1 per mutation.
    public private(set) var version: UInt64 = 0

    /// Lines scrolled off the top. Oldest at index 0, newest last.
    /// Past `maxScrollbackLines`, the oldest are evicted first.
    public private(set) var scrollback: [Line] = []

    /// Cumulative scrollback push count. Monotonically increasing even across evicts,
    /// so the host can compute "lines added since then" / whether eviction happened.
    public private(set) var scrollbackPushCount: UInt64 = 0

    /// Cumulative lines evicted from the top of scrollback this session (`pushCount - current count`).
    ///
    /// **Underflow-safe.** Reflow (`reflowPrimary`) rebuilds `scrollback` wholesale
    /// without touching `scrollbackPushCount`, so narrowing the columns can add
    /// soft-wraps until `scrollback.count` exceeds `scrollbackPushCount`. Nothing was
    /// evicted in that case, so return 0 instead of trapping (crashing) on `UInt64` subtraction.
    public var linesEvictedFromTop: UInt64 {
        let count = UInt64(scrollback.count)
        return scrollbackPushCount > count ? scrollbackPushCount - count : 0
    }

    /// Maximum scrollback line count. `DamsonSession` sets it from config.
    public var maxScrollbackLines: Int = 10_000

    /// On session restore, inject the previous session's scrollback before live output starts.
    /// Prepends `lines` to the current scrollback (oldest end) and clamps to `maxScrollbackLines`.
    /// Also bumps pushCount so the "restored lines" look like normal scrollback.
    public func seedScrollback(_ lines: [Line]) {
        guard !lines.isEmpty else { return }
        scrollback = lines + scrollback
        scrollbackPushCount += UInt64(lines.count)
        if scrollback.count > maxScrollbackLines {
            scrollback.removeFirst(scrollback.count - maxScrollbackLines)
        }
    }

    /// Whether the alt screen is active. If true the current buffer is alt, and the primary state from just before entry is kept in `savedPrimary`.
    public private(set) var isAltScreenActive: Bool = false

    /// Whether Synchronized Output Mode (DECSET 2026) has ever been used in this session.
    /// Sticky-true once set. Used for the viewport-top anchoring + blank cells policy on
    /// resize — once a TUI has run, the session is operated TUI-friendly.
    public var hasUsedSyncOutput: Bool = false

    /// Whether we're inside 2026 sync output mode right now (transient — set by
    /// `\e[?2026h`, cleared by `\e[?2026l`). Active while TUIs like Claude Code send
    /// redraw bursts. scrollUp during it (line-feed hitting bottom at the end of the
    /// screen) doesn't push to scrollback — prevents the regression where old lines of
    /// a redraw burst pile up in scrollback and the user sees leftover boxes when scrolling.
    public var inSyncOutputMode: Bool = false

    /// Primary buffer snapshot kept on alt screen entry. Tracks resizes that arrive while in alt.
    private struct PrimarySnapshot {
        var cells: [Line]
        var cursorRow: Int
        var cursorCol: Int
        var pen: CellAttrs
        var pendingWrap: Bool
        var scrollback: [Line]
        var scrollbackPushCount: UInt64
        var cursorVisible: Bool
        var scrollTop: Int
        var scrollBottom: Int
        var savedCursorRow: Int
        var savedCursorCol: Int
        var savedPen: CellAttrs?
    }
    private var savedPrimary: PrimarySnapshot? = nil

    public init(cols: Int, rows: Int, pen: CellAttrs) {
        precondition(cols > 0 && rows > 0)
        self.cols = cols
        self.rows = rows
        self.pen = pen
        self.defaultPen = pen
        self.cells = Self.makeBlank(rows: rows, cols: cols, attrs: pen)
        self.scrollBottom = rows - 1
    }

    // MARK: - Cell access

    public func cell(row: Int, col: Int) -> Cell {
        precondition(row >= 0 && row < rows)
        precondition(col >= 0 && col < cols)
        return cells[row][col]
    }

    /// Return one whole row as a cell array. For the renderer.
    public func row(_ r: Int) -> [Cell] {
        precondition(r >= 0 && r < rows)
        return cells[r].cells
    }

    /// Whether a viewport row soft-wrapped (continues onto the next row). For renderer/reflow.
    public func rowWrapped(_ r: Int) -> Bool {
        precondition(r >= 0 && r < rows)
        return cells[r].wrapped
    }

    /// Called when the shell sends OSC 133;A (prompt start). Puts a prompt-start mark
    /// on the current cursor row. Reflow preserves the "live prompt block" from this
    /// mark to the cursor without rewrapping, so the shell's SIGWINCH redraw (relative
    /// cursor ↑N + erase) can't eat content above the prompt. The viewport only needs
    /// one mark, so existing ones are cleared.
    public func markPromptStart() {
        for r in 0..<rows { cells[r].isPromptStart = false }
        guard cursorRow >= 0, cursorRow < rows else { return }
        cells[cursorRow].isPromptStart = true
    }

    // MARK: - Basic mutation

    /// Write one character at the current cursor position and advance the cursor.
    /// xterm-style deferred wrap: at the last column the wrap waits for the next printable.
    /// An East Asian Wide char occupies 2 cells (leading cell + continuation marker).
    public func putChar(_ ch: Character) {
        // Grapheme reassembly: the shell can echo one grapheme's scalars across
        // separate writes during line editing (👍 then 🏽, 🇰 then 🇷), so a
        // combining mark / skin-tone modifier / ZWJ continuation / regional-
        // indicator pair must merge into the preceding cell instead of starting a
        // new one. (printf's single write already clusters via Swift's grapheme
        // breaking; this catches the split-write case.)
        if mergeGraphemeExtender(ch) { return }
        if pendingWrap {
            pendingWrap = false
            // Soft wrap: the row we're leaving filled to the margin and the text
            // continues below — mark it so reflow can rejoin the two rows. (A
            // hard newline goes straight through lineFeed() and leaves it false.)
            if cursorRow >= 0, cursorRow < rows {
                cells[cursorRow].wrapped = true
            }
            lineFeed()
            cursorCol = 0
        }
        guard cursorRow >= 0, cursorRow < rows,
              cursorCol >= 0, cursorCol < cols else { return }

        let wide = Cell.isWide(ch)

        // A wide char landing on the last column leaves that cell blank and wraps to the next line.
        if wide && cursorCol == cols - 1 {
            // Mark as a layout filler — keeps reflow from wrongly splicing this cell
            // in as content when rejoining logical lines (distinct from a content space).
            cells[cursorRow][cursorCol] = Cell.wideSpacer(attrs: pen)
            // Same soft-wrap case: a wide glyph that won't fit pushes to the next
            // row, so the row it leaves behind is a wrapped continuation.
            cells[cursorRow].wrapped = true
            if cursorRow >= rows - 1 {
                scrollUp(count: 1)
            } else {
                cursorRow += 1
            }
            cursorCol = 0
        }

        // Overwriting only one cell of a wide char leaves its partner orphaned and a
        // broken half glyph on screen (happens when TUIs like Claude Code move the
        // cursor and partially redraw). Blank the partner of any straddling wide char
        // before overwriting. When writing a wide char, also clean the next cell the continuation will occupy.
        eraseWidePartner(row: cursorRow, col: cursorCol)
        if wide, cursorCol + 1 < cols { eraseWidePartner(row: cursorRow, col: cursorCol + 1) }

        cells[cursorRow][cursorCol] = Cell(
            char: ch, attrs: pen, hyperlink: currentHyperlink
        )
        if wide, cursorCol + 1 < cols {
            cells[cursorRow][cursorCol + 1] = Cell.continuation(attrs: pen, hyperlink: currentHyperlink)
        }

        let advance = wide ? 2 : 1
        if cursorCol + advance >= cols {
            pendingWrap = true
            cursorCol = cols - 1
        } else {
            cursorCol += advance
        }
        bumpVersion()
    }

    /// Just before overwriting `(row,col)`, blank the partner cell of any wide char
    /// straddling that spot. If col is a continuation, blank the lead (col-1); if col
    /// is a wide lead, blank the continuation (col+1). Prevents orphan glyphs when only half a wide char is overwritten.
    private func eraseWidePartner(row: Int, col: Int) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        if cells[row][col].isContinuation {
            if col - 1 >= 0 {
                cells[row][col - 1] = Cell.empty(attrs: cells[row][col - 1].attrs)
            }
        } else if col + 1 < cols, cells[row][col + 1].isContinuation {
            cells[row][col + 1] = Cell.empty(attrs: cells[row][col + 1].attrs)
        }
    }

    /// Try to merge `ch` into the cell preceding the cursor (a grapheme that the
    /// shell echoed split across writes). Returns true if merged (cursor unchanged).
    private func mergeGraphemeExtender(_ ch: Character) -> Bool {
        guard cursorRow >= 0, cursorRow < rows else { return false }
        // The char this extender attaches to: when parked at the margin
        // (pendingWrap) it's the cell at the cursor; otherwise the cell to the left.
        var col = pendingWrap ? cursorCol : cursorCol - 1
        if col >= 0, col < cols, cells[cursorRow][col].isContinuation { col -= 1 }  // wide lead
        guard col >= 0, col < cols else { return false }
        let prev = cells[cursorRow][col].char
        guard prev != " " else { return false }

        let prevEndsZWJ = (prev.unicodeScalars.last?.value == 0x200D)
        let merge = prevEndsZWJ
            || Grid.isGraphemeExtender(ch)
            || (Grid.isRegionalIndicator(ch) && Grid.isRegionalIndicator(prev))
        guard merge else { return false }

        var s = String(prev)
        s.unicodeScalars.append(contentsOf: ch.unicodeScalars)
        guard s.count == 1, let combined = s.first else { return false }  // must stay one grapheme
        cells[cursorRow][col].char = combined

        // If the merge widened the grapheme (e.g. two 1-cell regional indicators →
        // a 2-cell flag), claim the next cell as a continuation and advance the
        // cursor, so width matches the shell (which counts both code points).
        if Cell.isWide(combined),
           !(col + 1 < cols && cells[cursorRow][col + 1].isContinuation),
           col + 1 < cols, !pendingWrap {
            let lead = cells[cursorRow][col]
            cells[cursorRow][col + 1] = Cell.continuation(attrs: lead.attrs, hyperlink: lead.hyperlink)
            if cursorCol + 1 < cols { cursorCol += 1 } else { pendingWrap = true; cursorCol = cols - 1 }
        }
        bumpVersion()
        return true
    }

    /// A scalar that extends the preceding grapheme: ZWJ, variation selector,
    /// emoji skin-tone modifier, or a combining mark.
    private static func isGraphemeExtender(_ ch: Character) -> Bool {
        guard let s = ch.unicodeScalars.first else { return false }
        let v = s.value
        if v == 0x200D || (0xFE00...0xFE0F).contains(v) || (0x1F3FB...0x1F3FF).contains(v) {
            return true
        }
        if v < 0x300 { return false }   // below the first combining block — skip the lookup
        switch s.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark: return true
        default: return false
        }
    }

    private static func isRegionalIndicator(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first?.value else { return false }
        return (0x1F1E6...0x1F1FF).contains(v)
    }

    /// LF (`\n`): move the cursor down one line.
    /// - At the scroll region bottom (`scrollBottom`), scrollUp(1) within the region.
    /// - In the frozen area outside the region, just move the cursor; no-op at the screen edge.
    public func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom {
            scrollUp(count: 1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
        bumpVersion()
    }

    /// CR (`\r`): move the cursor to the start of the line.
    public func carriageReturn() {
        pendingWrap = false
        cursorCol = 0
        bumpVersion()
    }

    /// BS (`\b`): move the cursor one cell left. Does not erase the character.
    /// No-op at the start of a line (simple model — no wrap undo).
    public func backspace() {
        pendingWrap = false
        if cursorCol > 0 {
            cursorCol -= 1
            bumpVersion()
        }
    }

    // MARK: - Scrolling

    /// Shift the scroll region up by `count` lines. Rows outside the region are untouched.
    /// Lines falling off the top are pushed to scrollback only when the region starts at
    /// the top of the screen (primary buffer + scrollTop==0), otherwise dropped. Bottom fills with blanks.
    public func scrollUp(count n: Int) {
        guard n > 0 else { return }
        let regionHeight = scrollBottom - scrollTop + 1
        guard regionHeight > 0 else { return }
        let evictCount = min(n, regionHeight)

        // Push to scrollback only when the region starts at the top of the screen
        // (scrollTop == 0) and we're not on the alt screen. With a mid-screen region
        // (tmux status bar etc.), content falling off the top isn't accumulated (xterm behavior).
        //
        // Push even during DEC 2026 synchronized output (inSyncOutputMode) — sync is
        // just a presentation hint, unrelated to scrollback (same as real terminals).
        // Redraw frames of primary-screen TUIs like Claude Code are mostly in-place
        // (cursor up→reprint→return, net-zero scroll), so nothing piles up in
        // scrollback; pushes happen only when genuinely new content scrolls off the
        // top, so the user can scroll up to see conversation history. (The host
        // collects a sync frame until ESU and presents it atomically, so no
        // torn-frame duplicates either.) We used to suppress pushes during
        // inSyncOutputMode, which threw away the TUI's entire history and caused the
        // "can't scroll up, content vanishes off-screen" regression.
        let suppressForTUI = isAltScreenActive
        if !suppressForTUI && scrollTop == 0 {
            for i in 0..<evictCount {
                pushToScrollback(cells[scrollTop + i])
            }
        }

        let blank = Line.blank(cols: cols, attrs: pen)
        if evictCount >= regionHeight {
            for r in scrollTop...scrollBottom {
                cells[r] = blank
            }
        } else {
            // shift up within the region
            for r in scrollTop...(scrollBottom - evictCount) {
                cells[r] = cells[r + evictCount]
            }
            // blank the bottom evictCount rows of the region
            for r in (scrollBottom - evictCount + 1)...scrollBottom {
                cells[r] = blank
            }
        }
        bumpVersion()
    }

    private func pushToScrollback(_ line: Line) {
        // Evict in batches, not per line: removeFirst shifts the whole array, so a
        // 1-line evict at the cap costs O(maxScrollbackLines) per scrolled line —
        // quadratic under output floods (`yes`), saturating the main thread. Dropping
        // an eighth at once amortizes eviction to O(1) per line while preserving the
        // `count ≤ maxScrollbackLines` invariant (depth oscillates within max−batch…max).
        if scrollback.count >= maxScrollbackLines {
            let batch = max(1, maxScrollbackLines / 8)
            scrollback.removeFirst(min(scrollback.count, scrollback.count - maxScrollbackLines + batch))
        }
        scrollback.append(line)
        scrollbackPushCount &+= 1
    }

    // MARK: - Cursor movement (CSI)

    /// CUP / HVP — `\e[r;cH` or `\e[r;cf`. 1-based coordinates.
    public func setCursor(row r: Int, col c: Int) {
        let newRow = max(0, min(rows - 1, max(r, 1) - 1))
        let newCol = max(0, min(cols - 1, max(c, 1) - 1))
        cursorRow = newRow
        cursorCol = newCol
        pendingWrap = false
        bumpVersion()
    }

    /// CUU — cursor up by n (1 default), clipped at the top edge.
    public func cursorUp(_ n: Int = 1) {
        cursorRow = max(0, cursorRow - max(1, n))
        pendingWrap = false
        bumpVersion()
    }

    /// CUD — cursor down by n.
    public func cursorDown(_ n: Int = 1) {
        cursorRow = min(rows - 1, cursorRow + max(1, n))
        pendingWrap = false
        bumpVersion()
    }

    /// CUF — cursor forward (right) by n.
    public func cursorForward(_ n: Int = 1) {
        cursorCol = min(cols - 1, cursorCol + max(1, n))
        pendingWrap = false
        bumpVersion()
    }

    /// CUB — cursor back (left) by n.
    public func cursorBack(_ n: Int = 1) {
        cursorCol = max(0, cursorCol - max(1, n))
        pendingWrap = false
        bumpVersion()
    }

    /// CHA / HPA — move the cursor to an absolute col on the same line (1-based).
    public func setCursorColumn(_ col: Int) {
        cursorCol = max(0, min(cols - 1, max(col, 1) - 1))
        pendingWrap = false
        bumpVersion()
    }

    /// VPA — move the cursor to an absolute row (1-based). col is kept.
    public func setCursorRow(_ row: Int) {
        cursorRow = max(0, min(rows - 1, max(row, 1) - 1))
        pendingWrap = false
        bumpVersion()
    }

    // MARK: - Cursor save/restore (DECSC/DECRC, CSI s/u)

    public func saveCursor() {
        savedCursorRow = cursorRow
        savedCursorCol = cursorCol
        savedPen = pen
    }

    public func restoreCursor() {
        guard savedPen != nil else { return }
        cursorRow = max(0, min(rows - 1, savedCursorRow))
        cursorCol = max(0, min(cols - 1, savedCursorCol))
        if let p = savedPen { pen = p }
        pendingWrap = false
        bumpVersion()
    }

    // MARK: - Erase (CSI)

    /// EL — `\e[Km` modes:
    ///   0 (default): cursor → end of line
    ///   1: start of line → cursor (both inclusive)
    ///   2: whole line
    public func eraseInLine(mode: Int) {
        let blank = Cell.empty(attrs: pen)
        switch mode {
        case 0:
            for c in cursorCol..<cols { cells[cursorRow][c] = blank }
            // The wrap point lives at the right margin; erasing to end of line
            // destroys it, so the row no longer continues below. (Shells emit EL
            // on every prompt redraw — without this the flag goes stale and
            // reflow would wrongly merge this row with the next.)
            cells[cursorRow].wrapped = false
        case 1:
            // Start→cursor leaves the tail (wrap point) intact — keep `wrapped`.
            for c in 0...min(cursorCol, cols - 1) { cells[cursorRow][c] = blank }
        case 2:
            for c in 0..<cols { cells[cursorRow][c] = blank }
            cells[cursorRow].wrapped = false
        default:
            return
        }
        bumpVersion()
    }

    /// ED — `\e[Jm` modes:
    ///   0 (default): cursor → end of screen
    ///   1: start of screen → cursor
    ///   2: whole screen (cursor position kept)
    ///   3: screen + scrollback (currently same as 2 — scrollback unimplemented)
    public func eraseInDisplay(mode: Int) {
        let blank = Cell.empty(attrs: pen)
        switch mode {
        case 0:
            for c in cursorCol..<cols { cells[cursorRow][c] = blank }
            cells[cursorRow].wrapped = false   // tail erased → wrap point gone
            for r in (cursorRow + 1)..<rows {
                for c in 0..<cols { cells[r][c] = blank }
                cells[r].wrapped = false        // fully cleared rows can't wrap
            }
        case 1:
            for r in 0..<cursorRow {
                for c in 0..<cols { cells[r][c] = blank }
                cells[r].wrapped = false        // fully cleared rows can't wrap
            }
            // cursorRow: only start→cursor cleared, tail intact — keep `wrapped`.
            for c in 0...min(cursorCol, cols - 1) { cells[cursorRow][c] = blank }
        case 2:
            cells = Self.makeBlank(rows: rows, cols: cols, attrs: pen)
        case 3:
            cells = Self.makeBlank(rows: rows, cols: cols, attrs: pen)
            scrollback.removeAll(keepingCapacity: true)
        default:
            return
        }
        bumpVersion()
    }

    /// IL — insert n blank lines at the cursor. The cursor row and everything below (through scrollBottom) shifts down.
    /// No-op outside the scroll region.
    public func insertLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = max(1, n)
        let regionRemain = scrollBottom - cursorRow + 1
        let actual = min(count, regionRemain)
        let blank = Line.blank(cols: cols, attrs: pen)
        // Within cursorRow~scrollBottom: the bottom `actual` rows are cut, `actual` blank rows inserted above.
        for r in stride(from: scrollBottom, through: cursorRow + actual, by: -1) {
            cells[r] = cells[r - actual]
        }
        for r in cursorRow..<(cursorRow + actual) {
            cells[r] = blank
        }
        cursorCol = 0
        pendingWrap = false
        bumpVersion()
    }

    /// DL — delete n lines starting at the cursor row. Rows below are pulled up. The region bottom fills with blanks.
    public func deleteLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = max(1, n)
        let regionRemain = scrollBottom - cursorRow + 1
        let actual = min(count, regionRemain)
        let blank = Line.blank(cols: cols, attrs: pen)
        for r in cursorRow...(scrollBottom - actual) {
            cells[r] = cells[r + actual]
        }
        for r in (scrollBottom - actual + 1)...scrollBottom {
            cells[r] = blank
        }
        cursorCol = 0
        pendingWrap = false
        bumpVersion()
    }

    /// ICH — insert n blank cells at the cursor. Cells to the right shift right (the last ones fall off).
    public func insertChars(_ n: Int) {
        guard cursorRow >= 0, cursorRow < rows else { return }
        guard cursorCol >= 0, cursorCol < cols else { return }
        let count = max(1, n)
        let actual = min(count, cols - cursorCol)
        var row = cells[cursorRow]
        let blank = Cell.empty(attrs: pen)
        // shift right, starting from the end
        for c in stride(from: cols - 1, through: cursorCol + actual, by: -1) {
            row[c] = row[c - actual]
        }
        for c in cursorCol..<(cursorCol + actual) {
            row[c] = blank
        }
        cells[cursorRow] = row
        pendingWrap = false
        bumpVersion()
    }

    /// DCH — delete n cells starting at the cursor. Cells to the right are pulled left. End of line fills with blanks.
    public func deleteChars(_ n: Int) {
        guard cursorRow >= 0, cursorRow < rows else { return }
        guard cursorCol >= 0, cursorCol < cols else { return }
        let count = max(1, n)
        let actual = min(count, cols - cursorCol)
        var row = cells[cursorRow]
        let blank = Cell.empty(attrs: pen)
        for c in cursorCol..<(cols - actual) {
            row[c] = row[c + actual]
        }
        for c in (cols - actual)..<cols {
            row[c] = blank
        }
        cells[cursorRow] = row
        pendingWrap = false
        bumpVersion()
    }

    /// ECH — blank n cells on the same line starting at the cursor (cursor stays put).
    public func eraseChars(_ n: Int) {
        let count = max(1, n)
        let endCol = min(cols, cursorCol + count)
        let blank = Cell.empty(attrs: pen)
        guard cursorRow >= 0, cursorRow < rows, cursorCol < endCol else { return }
        for c in cursorCol..<endCol {
            cells[cursorRow][c] = blank
        }
        bumpVersion()
    }

    /// SD — shift the scroll region down by `count` lines (blank lines inserted at the top).
    public func scrollDown(count n: Int) {
        guard n > 0 else { return }
        let regionHeight = scrollBottom - scrollTop + 1
        guard regionHeight > 0 else { return }
        let insertCount = min(n, regionHeight)
        let blank = Line.blank(cols: cols, attrs: pen)

        if insertCount >= regionHeight {
            for r in scrollTop...scrollBottom {
                cells[r] = blank
            }
        } else {
            // shift down within the region (copy in reverse order)
            for r in stride(from: scrollBottom, through: scrollTop + insertCount, by: -1) {
                cells[r] = cells[r - insertCount]
            }
            for r in scrollTop..<(scrollTop + insertCount) {
                cells[r] = blank
            }
        }
        bumpVersion()
    }

    // MARK: - SGR (pen updates)

    /// `\e[ ... m` — cumulatively update pen attributes. `-1` (unspecified) normalizes to 0 (reset).
    public func applySGR(_ rawParams: [Int]) {
        let params = rawParams.map { $0 < 0 ? 0 : $0 }
        var i = 0
        while i < params.count {
            let p = params[i]
            switch p {
            case 0:
                pen = defaultPen
            case 1:  pen.bold = true
            case 2:  pen.faint = true
            case 3:  pen.italic = true
            case 4:  pen.underline = true
            case 7:  pen.inverse = true
            case 9:  pen.strikethrough = true
            case 22: pen.bold = false; pen.faint = false   // SGR 22 = neither bold nor faint
            case 23: pen.italic = false
            case 24: pen.underline = false
            case 27: pen.inverse = false
            case 29: pen.strikethrough = false
            case 30...37:
                pen.fg = .palette(p - 30)
            case 38:
                if let (color, skip) = extendedColor(params: params, from: i + 1) {
                    pen.fg = color
                    i += skip
                }
            case 39:
                pen.fg = defaultPen.fg
            case 40...47:
                pen.bg = .palette(p - 40)
            case 48:
                if let (color, skip) = extendedColor(params: params, from: i + 1) {
                    pen.bg = color
                    i += skip
                }
            case 49:
                pen.bg = nil
            case 90...97:
                pen.fg = .palette(p - 90 + 8)   // bright 8-15
            case 100...107:
                pen.bg = .palette(p - 100 + 8)
            default:
                break
            }
            i += 1
        }
        bumpVersion()
    }

    /// Parse `38;5;n` or `38;2;r;g;b`. Returns (color, extra params consumed).
    private func extendedColor(params: [Int], from idx: Int) -> (TermColor, Int)? {
        guard idx < params.count else { return nil }
        switch params[idx] {
        case 5:
            guard idx + 1 < params.count else { return nil }
            return (.palette(max(0, min(255, params[idx + 1]))), 2)
        case 2:
            guard idx + 3 < params.count else { return nil }
            let r = UInt8(max(0, min(255, params[idx + 1])))
            let g = UInt8(max(0, min(255, params[idx + 2])))
            let b = UInt8(max(0, min(255, params[idx + 3])))
            return (.rgb(r, g, b), 4)
        default:
            return nil
        }
    }

    // MARK: - resize

    /// Handles SIGWINCH. Rebuilds the cell matrix at the new size.
    /// - On the primary screen, **a column change reflows** (re-lays soft-wrapped lines
    ///   out for the new width). Otherwise (alt screen, width unchanged): trim/pad.
    /// - Fewer rows push the oldest rows to scrollback; more rows pad the bottom with blanks.
    public func resize(cols newCols: Int, rows newRows: Int) {
        precondition(newCols > 0 && newRows > 0)
        if newCols == cols && newRows == rows { return }

        if !isAltScreenActive && newCols != cols {
            // Primary screen with a column change → reflow. Rejoins soft-wrapped
            // physical rows into logical lines, re-splits at the new width, redistributes
            // into scrollback+viewport, preserving the cursor's logical position. (Alt
            // screen excluded — apps redraw it themselves.)
            reflowPrimary(toCols: newCols, toRows: newRows)
        } else {
            // Alt screen or a pure row change → simple trim/pad. With width unchanged,
            // wrap boundaries don't move, so no reflow needed.
            resizeTrimPad(toCols: newCols, toRows: newRows)
        }

        cols = newCols
        rows = newRows
        // On resize the scroll region resets to the full screen (xterm behavior).
        // Apps re-issue DECSTBM after SIGWINCH.
        scrollTop = 0
        scrollBottom = newRows - 1
        bumpVersion()
    }

    /// Simple trim/pad resize. Used for the alt screen or width-preserving row changes.
    /// At call time `cols`/`rows` still hold the old values (the shared tail updates them).
    private func resizeTrimPad(toCols newCols: Int, toRows newRows: Int) {
        // On shrink, which rows to cut — decided by the cursor.
        //   Cursor fits the new viewport (cursorRow < newRows) → trim the bottom.
        //     The prompt (above the cursor) stays; only the empty bottom goes → avoids the "prompt pile-up" regression.
        //   Doesn't fit → push the excess top rows to scrollback.
        let rowOffset: Int
        if newRows < rows {
            if cursorRow < newRows {
                rowOffset = 0
            } else {
                rowOffset = cursorRow - (newRows - 1)
            }
        } else {
            rowOffset = 0
        }
        if rowOffset > 0 && !isAltScreenActive {
            for r in 0..<rowOffset {
                pushToScrollback(cells[r])
            }
        }
        cells = Self.resizeCellsArray(
            cells, fromCols: cols, fromRows: rows,
            toCols: newCols, toRows: newRows, rowOffset: rowOffset, pen: pen
        )
        cursorRow = max(0, min(newRows - 1, cursorRow - rowOffset))
        cursorCol = max(0, min(newCols - 1, cursorCol))

        // If there's a saved primary, resize it too (keeps the same size + pushes to its own scrollback on shrink).
        if var saved = savedPrimary {
            let savedRows = saved.cells.count
            let savedCols = saved.cells.first?.count ?? 0
            let savedRowOffset = newRows < savedRows ? savedRows - newRows : 0
            if savedRowOffset > 0 {
                for r in 0..<savedRowOffset {
                    saved.scrollback.append(saved.cells[r])
                    saved.scrollbackPushCount &+= 1
                }
                // Clamp once after the batch (a resize pushes at most a screenful, but
                // there's no reason to shift the array per line).
                if saved.scrollback.count > maxScrollbackLines {
                    saved.scrollback.removeFirst(saved.scrollback.count - maxScrollbackLines)
                }
            }
            saved.cells = Self.resizeCellsArray(
                saved.cells, fromCols: savedCols, fromRows: savedRows,
                toCols: newCols, toRows: newRows, rowOffset: savedRowOffset, pen: saved.pen
            )
            saved.cursorRow = max(0, min(newRows - 1, saved.cursorRow - savedRowOffset))
            saved.cursorCol = max(0, min(newCols - 1, saved.cursorCol))
            saved.pendingWrap = false
            saved.scrollTop = 0
            saved.scrollBottom = newRows - 1
            savedPrimary = saved
        }
        pendingWrap = false
    }

    /// Column reflow (primary screen only). At call time `cols`/`rows` still hold the old values.
    /// Rejoin scrollback+viewport into logical lines → re-split at the new width →
    /// redistribute into scrollback and a `newRows`-tall viewport. Preserves the cursor's logical position.
    private func reflowPrimary(toCols newCols: Int, toRows newRows: Int) {
        // 1. scrollback + viewport as one contiguous sequence of physical rows. The
        //    last scrollback row's wrap flag carries into the first viewport row.
        let phys: [Line] = scrollback + cells
        let cursorAbs = scrollback.count + cursorRow

        // 2. Drop blank padding rows below the cursor (refilled after reflow). Keep
        //    everything through the cursor and the last content row.
        var lastKeep = cursorAbs
        for i in phys.indices where !isBlankRow(phys[i]) { lastKeep = max(lastKeep, i) }
        let kept = Array(phys[0...min(lastKeep, phys.count - 1)])

        // 3. Pick the start (preserveStart) of the "live prompt block" preservation span.
        //    After SIGWINCH the shell's reset-prompt redraws the prompt via "relative
        //    cursor move (↑N) + screen erase", where N is the physical row count of the
        //    prompt the shell *last drew*. If we pre-rewrap the prompt and change its
        //    row count, that ↑N overshoots into content above the prompt and erases it
        //    (repro: a starship info line folded at narrow width unfolds on widening).
        //    So the prompt block is not rewrapped — its original physical row count is
        //    preserved as-is. The boundary is the OSC 133;A (prompt start) mark; with
        //    no mark (shells without 133) only the cursor's logical line is preserved.
        var preserveStart = cursorAbs
        var m = min(cursorAbs, kept.count - 1)
        var foundMark = false
        while m >= 0 {
            if kept[m].isPromptStart { preserveStart = m; foundMark = true; break }
            m -= 1
        }
        if !foundMark { preserveStart = cursorAbs }
        // Extend back to the start of that logical line so it isn't split.
        while preserveStart > 0 && kept[preserveStart - 1].wrapped { preserveStart -= 1 }
        preserveStart = max(0, min(preserveStart, cursorAbs))

        // 4. Only what precedes preserveStart (finished output + scrollback) is
        //    rejoined into logical lines and rewrapped to newCols. The cursor is in
        //    the preserved span, so it isn't tracked here.
        //
        //    Also collapse the run of consecutive blank rows *directly above* the
        //    prompt block to one (many → 1). During zoom/resize bursts zsh's SIGWINCH
        //    handling coalesces, so the partial-line guard padding the shell printed
        //    with a stale COLUMNS (PROMPT_SP: `%` + a line-width of spaces) wraps on
        //    the narrowed grid, leaking one blank logical line above the prompt per
        //    cycle. The next reflow hardens that blank into "finished output" forever —
        //    the gap between output and prompt grew with every zoom (§field: zoom gap).
        //    Intentional blank lines (starship add_newline etc.) survive since one is
        //    kept. Multiple intentional trailing blanks may shrink to one on resize
        //    (a trade-off on par with iTerm2-style trimming) — far better than the accumulating defect.
        var rewrapEnd = preserveStart
        var blanksAbove = 0
        while rewrapEnd - blanksAbove - 1 >= 0, isBlankRow(kept[rewrapEnd - blanksAbove - 1]) {
            blanksAbove += 1
        }
        if blanksAbove > 1 { rewrapEnd -= (blanksAbove - 1) }
        var newPhys: [Line] = []
        appendRewrapped(Array(kept[0..<rewrapEnd]), to: newCols, into: &newPhys)

        // 5. The prompt block (mark~cursor, + live content below the cursor) keeps its
        //    original physical rows, only clipped/padded to width (row count, wrap, prompt mark preserved).
        let newCursorAbs = newPhys.count + (cursorAbs - preserveStart)
        let newCursorCol: Int
        let newPendingWrap: Bool
        if cursorCol >= newCols { newCursorCol = newCols - 1; newPendingWrap = true }
        else { newCursorCol = max(0, cursorCol); newPendingWrap = pendingWrap }
        for row in kept[preserveStart...] {
            var line = paddedRow(row.cells, to: newCols, wrapped: row.wrapped)
            line.isPromptStart = row.isPromptStart
            newPhys.append(line)
        }
        if newPhys.isEmpty { newPhys.append(paddedRow([], to: newCols, wrapped: false)) }

        // 6. viewport (last newRows) + scrollback (the rest). Pad the bottom if content is short.
        if newPhys.count < newRows {
            for _ in 0..<(newRows - newPhys.count) {
                newPhys.append(paddedRow([], to: newCols, wrapped: false))
            }
        }
        let vpStart = newPhys.count - newRows
        var newScrollback = Array(newPhys[0..<vpStart])
        let newViewport = Array(newPhys[vpStart..<newPhys.count])

        // 7. Commit. Evict whatever exceeds the scrollback cap.
        if newScrollback.count > maxScrollbackLines {
            newScrollback.removeFirst(newScrollback.count - maxScrollbackLines)
        }
        scrollback = newScrollback
        cells = newViewport
        cursorRow = max(0, min(newRows - 1, newCursorAbs - vpStart))
        cursorCol = max(0, min(newCols - 1, newCursorCol))
        pendingWrap = newPendingWrap

    }

    /// Reflow's "rewrap span" (finished output above the prompt block + scrollback):
    /// rejoins physical rows into logical lines via the wrap flags (excluding wide
    /// spacers), trims each logical line's trailing blanks, then re-splits at newCols
    /// into `newPhys`. A wide char straddling a row boundary moves to the next row,
    /// leaving a spacer behind (prevents half-clipped Hangul).
    private func appendRewrapped(_ rows: [Line], to newCols: Int, into newPhys: inout [Line]) {
        guard !rows.isEmpty else { return }
        var logicals: [[Cell]] = []
        var curCells: [Cell] = []
        for row in rows {
            for cell in row.cells where !cell.isWideSpacer { curCells.append(cell) }
            if !row.wrapped { logicals.append(curCells); curCells = [] }
        }
        if !curCells.isEmpty { logicals.append(curCells) }
        for li in logicals.indices {
            var n = logicals[li].count
            while n > 0 && isBlankCell(logicals[li][n - 1]) { n -= 1 }
            if n < logicals[li].count { logicals[li].removeLast(logicals[li].count - n) }
        }
        for L in logicals {
            if L.isEmpty { newPhys.append(paddedRow([], to: newCols, wrapped: false)); continue }
            var idx = 0
            while idx < L.count {
                var end = min(idx + newCols, L.count)
                var wideWrapped = false
                if end < L.count, L[end].isContinuation, end - 1 > idx { end -= 1; wideWrapped = true }
                let isLast = (end == L.count)
                var rowCells = Array(L[idx..<end])
                if wideWrapped { rowCells.append(Cell.wideSpacer(attrs: defaultPen)) }
                newPhys.append(paddedRow(rowCells, to: newCols, wrapped: !isLast))
                idx = end
            }
        }
    }

    /// Whether a cell is visually blank (space + no background/link/emphasis). For reflow's trailing trim.
    private func isBlankCell(_ c: Cell) -> Bool {
        // A continuation cell is a wide char's trailing half: its char is " " but it
        // isn't empty. Treating it as blank lets trailing trim strip the wide char's
        // partner, so the lead draws clipped to half.
        !c.isContinuation
            && c.char == " " && c.attrs.bg == nil && c.hyperlink == nil
            && !c.attrs.inverse && !c.attrs.underline && !c.attrs.strikethrough
    }

    /// Whether a row is unwrapped with every cell blank. Identifies padding rows reflow can drop.
    private func isBlankRow(_ line: Line) -> Bool {
        !line.wrapped && line.cells.allSatisfy { isBlankCell($0) }
    }

    /// Is there a non-blank row below the cursor row (primary screen only)?
    ///
    /// A signal that identifies primary-screen TUIs which, like Claude Code, keep a
    /// status/footer resident **below** the input line without using alt-screen/
    /// sync-output. During follow-bottom the host then uses a grid-top anchor instead
    /// of the cursor-visible policy, so it isn't just the cursor that's visible with
    /// the footer below it clipped under the fold. (rows*cellH ≤ viewport, so the live
    /// grid always fits the viewport, making the grid-top anchor safe down to the bottom.)
    public var hasContentBelowCursor: Bool {
        guard !isAltScreenActive, cursorRow + 1 < rows else { return false }
        for r in (cursorRow + 1)..<rows where !isBlankRow(cells[r]) { return true }
        return false
    }

    /// Build a Line padded/trimmed to `width` (for reflow).
    private func paddedRow(_ rowCells: [Cell], to width: Int, wrapped: Bool) -> Line {
        var r = rowCells
        if r.count < width {
            r.append(contentsOf: Array(repeating: Cell.empty(attrs: defaultPen),
                                       count: width - r.count))
        } else if r.count > width {
            r.removeLast(r.count - width)
        }
        return Line(r, wrapped: wrapped)
    }

    private static func resizeCellsArray(
        _ source: [Line],
        fromCols: Int, fromRows: Int,
        toCols: Int, toRows: Int,
        rowOffset: Int,
        pen: CellAttrs
    ) -> [Line] {
        // `rowOffset` = how many top rows the caller already removed (pushed to
        // scrollback or intentionally dropped). It MUST match the caller's intent,
        // not be recomputed here: on a shrink where the cursor still fits, the
        // caller keeps the TOP rows (rowOffset 0, bottom trimmed); recomputing
        // `fromRows-toRows` here would drop the top rows instead — losing content.
        let blank = Cell.empty(attrs: pen)
        var newCells: [Line] = []
        newCells.reserveCapacity(toRows)
        for r in 0..<toRows {
            var newRow: [Cell] = []
            newRow.reserveCapacity(toCols)
            let srcRow = r + rowOffset
            // Phase 1: column trim/pad carries the source row's wrap flag along.
            // Phase 2 replaces this whole path with real reflow.
            let wrapped = (srcRow >= 0 && srcRow < fromRows) ? source[srcRow].wrapped : false
            for c in 0..<toCols {
                if srcRow >= 0, srcRow < fromRows, c < fromCols {
                    newRow.append(source[srcRow][c])
                } else {
                    newRow.append(blank)
                }
            }
            newCells.append(Line(newRow, wrapped: wrapped))
        }
        return newCells
    }

    // MARK: - Scroll region (DECSTBM)

    /// Apply DECSTBM. `top`, `bottom` are 0-based, inclusive.
    /// Bad ranges are ignored (the invalid cases `top >= bottom` or `bottom >= rows`).
    /// After a valid region is set the cursor moves home (0,0) (DECOM assumed off).
    public func setScrollRegion(top: Int, bottom: Int) {
        let newTop = max(0, top)
        let newBottom = min(rows - 1, bottom)
        guard newTop < newBottom else {
            // clearly invalid range — ignore (xterm behavior)
            return
        }
        scrollTop = newTop
        scrollBottom = newBottom
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
        bumpVersion()
    }

    // MARK: - Alt screen (CSI ?1049 / ?1047 / ?47)

    /// Swap to the alt buffer. Snapshots the current primary state (cells/cursor/pen/scrollback/visibility).
    /// Known limitation: 1049/1047/47 aren't distinguished — all get 1049 semantics (vim/less/htop compatible).
    public func enterAltScreen() {
        if isAltScreenActive { return }
        savedPrimary = PrimarySnapshot(
            cells: cells,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            pen: pen,
            pendingWrap: pendingWrap,
            scrollback: scrollback,
            scrollbackPushCount: scrollbackPushCount,
            cursorVisible: cursorVisible,
            scrollTop: scrollTop,
            scrollBottom: scrollBottom,
            savedCursorRow: savedCursorRow,
            savedCursorCol: savedCursorCol,
            savedPen: savedPen
        )
        // Swap to a blank alt buffer. The pen carries over (the app resets it via SGR shortly).
        cells = Self.makeBlank(rows: rows, cols: cols, attrs: pen)
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
        scrollback = []
        scrollbackPushCount = 0
        scrollTop = 0
        scrollBottom = rows - 1
        savedCursorRow = 0
        savedCursorCol = 0
        savedPen = nil
        isAltScreenActive = true
        bumpVersion()
    }

    /// Leave alt and restore primary. No-op if there's no snapshot.
    public func leaveAltScreen() {
        guard isAltScreenActive, let saved = savedPrimary else {
            isAltScreenActive = false
            return
        }
        cells = saved.cells
        cursorRow = saved.cursorRow
        cursorCol = saved.cursorCol
        pen = saved.pen
        pendingWrap = saved.pendingWrap
        scrollback = saved.scrollback
        scrollbackPushCount = saved.scrollbackPushCount
        cursorVisible = saved.cursorVisible
        scrollTop = saved.scrollTop
        scrollBottom = saved.scrollBottom
        savedCursorRow = saved.savedCursorRow
        savedCursorCol = saved.savedCursorCol
        savedPen = saved.savedPen
        savedPrimary = nil
        isAltScreenActive = false
        bumpVersion()
    }

    /// DECTCEM toggle. Called from the private mode 25 `h/l` dispatch.
    public func setCursorVisible(_ visible: Bool) {
        if cursorVisible == visible { return }
        cursorVisible = visible
        bumpVersion()
    }

    /// Apply DECSCUSR. Called from handleCSI.
    public func setCursorShape(_ shape: CursorShape) {
        if cursorShape == shape { return }
        cursorShape = shape
        bumpVersion()
    }

    /// Update the active OSC 8 URI. nil deactivates.
    /// Subsequent `putChar`s attach this value to cells' `hyperlink` field.
    public func setHyperlink(_ uri: String?) {
        currentHyperlink = uri
        // Already-drawn cells are unaffected → don't bump version.
    }

    /// Clear all scrollback (used by ED mode 3 etc.).
    public func clearScrollback() {
        scrollback.removeAll(keepingCapacity: true)
        bumpVersion()
    }

    // MARK: - Debug/snapshot

    /// Debug/test convenience: dump the grid as one string per row (attributes ignored).
    public func debugDump() -> String {
        var out: [String] = []
        for r in 0..<rows {
            out.append(String(cells[r].cells.map { $0.char }))
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Internals

    private func bumpVersion() {
        version &+= 1
    }

    private static func makeBlank(rows: Int, cols: Int, attrs: CellAttrs) -> [Line] {
        return Array(repeating: Line.blank(cols: cols, attrs: attrs), count: rows)
    }
}
