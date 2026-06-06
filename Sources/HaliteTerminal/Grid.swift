import AppKit
import Foundation

/// 2D 셀 grid + 커서. VT/ANSI 의미에 따라 mutate.
/// M3는 viewport(=현재 화면)만 책임지고 scrollback은 M3.5에서 추가.
///
/// 모든 메서드는 호출자가 main thread에서 직렬화한다고 가정 (HaliteSession이 보장).
public final class Grid {
    public private(set) var cols: Int
    public private(set) var rows: Int

    /// 셀 저장: `cells[row][col]`. 항상 `rows × cols`로 유지.
    /// 각 행은 `Line`(셀 배열 + soft-wrap 비트)이다. wrap 비트는 reflow에서 사용.
    private var cells: [Line]

    /// 커서 (0-based).
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorCol: Int = 0

    /// 다음 putChar가 wrap을 일으켜야 함을 표시. xterm-style "deferred wrap".
    /// 셀이 마지막 열에 들어간 직후 set, 다음 평문이 들어오면 cursor를 다음 줄로.
    private var pendingWrap: Bool = false

    /// DECTCEM (`\e[?25h` / `\e[?25l`)로 토글되는 커서 가시성.
    /// 셸이 prompt 그릴 동안 잠깐 숨기는 패턴에 사용.
    public private(set) var cursorVisible: Bool = true

    /// Cursor shape, set by DECSCUSR (`CSI Ps SP q`) or the user's default config.
    public enum CursorShape: String, CaseIterable {
        case block, underline, bar
    }
    public private(set) var cursorShape: CursorShape = .block

    /// OSC 8 hyperlink — 현재 활성 URI. nil이면 비활성.
    /// 다음 `putChar`에 의해 새로 쓰여지는 cell들에 attach됨.
    public private(set) var currentHyperlink: String? = nil

    /// DECSTBM scroll region 상단 (0-based, inclusive). 기본값 0.
    public private(set) var scrollTop: Int = 0
    /// DECSTBM scroll region 하단 (0-based, inclusive). 기본값 rows - 1.
    public private(set) var scrollBottom: Int = 0

    /// DECSC/DECRC (또는 CSI s/u)로 저장되는 cursor + pen 스냅샷.
    /// 각 buffer(primary/alt)가 자기 saved state를 가져야 함 — alt screen snapshot에 포함.
    private var savedCursorRow: Int = 0
    private var savedCursorCol: Int = 0
    private var savedPen: CellAttrs? = nil

    /// 현재 펜(pen) 속성. SGR이 갱신.
    public var pen: CellAttrs

    /// SGR 0 (reset) 시 복원되는 기본 펜.
    public let defaultPen: CellAttrs

    /// 호스트가 갱신을 감지하는 단조증가 버전. 매 mutation마다 +1.
    public private(set) var version: UInt64 = 0

    /// 위로 밀려난 줄들. 가장 오래된 것이 index 0, 가장 최근이 마지막.
    /// `maxScrollbackLines`를 초과하면 가장 오래된 것부터 evict.
    public private(set) var scrollback: [Line] = []

    /// scrollback의 누적 push 카운트. evict가 일어나도 단조증가하므로
    /// 호스트가 "그 사이 새로 추가된 줄 수" / "evict 여부"를 판단할 수 있음.
    public private(set) var scrollbackPushCount: UInt64 = 0

    /// 세션 동안 scrollback 최상단에서 evict된 누적 줄 수 (`pushCount - 현재 count`).
    ///
    /// **언더플로 안전.** reflow(`reflowPrimary`)는 `scrollbackPushCount`를 건드리지
    /// 않고 `scrollback`을 통째로 재구성하므로, 컬럼을 좁히면 soft-wrap이 늘어
    /// `scrollback.count`가 `scrollbackPushCount`를 넘을 수 있다. 그 경우 evict된 게
    /// 없으므로 `UInt64` 빼기로 트랩(크래시)하는 대신 0을 돌려준다.
    public var linesEvictedFromTop: UInt64 {
        let count = UInt64(scrollback.count)
        return scrollbackPushCount > count ? scrollbackPushCount - count : 0
    }

    /// scrollback 최대 줄 수. `HaliteSession`이 config에서 받아서 설정.
    public var maxScrollbackLines: Int = 10_000

    /// alt screen 진입 여부. true면 현재 buffer는 alt, 진입 직전의 primary 상태가 `savedPrimary`에 보존.
    public private(set) var isAltScreenActive: Bool = false

    /// Synchronized Output Mode(DECSET 2026)가 이 session에서 사용된 적 있는지.
    /// 한 번이라도 set 되면 sticky-true. resize 시 viewport-top anchoring + blank cells
    /// 정책에 사용 — 한 번이라도 TUI를 띄운 적 있으면 그 세션은 TUI-friendly로 운영.
    public var hasUsedSyncOutput: Bool = false

    /// 현재 2026 sync output mode 안에 있는지 (transient — `\e[?2026h`로 set,
    /// `\e[?2026l`로 clear). Claude Code 같은 TUI가 redraw burst를 보낼 때 진행 중.
    /// 이 동안의 scrollUp(line-feed로 화면 끝에서 바닥에 닿음)은 scrollback에 push
    /// 안 함 — redraw burst의 옛 라인이 scrollback에 누적되어 사용자가 스크롤 시
    /// 잔재 박스를 보는 회귀 방지.
    public var inSyncOutputMode: Bool = false

    /// alt screen 진입 시 보존되는 primary buffer 스냅샷. alt 도중 resize가 와도 같이 따라감.
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

    // MARK: - 셀 접근

    public func cell(row: Int, col: Int) -> Cell {
        precondition(row >= 0 && row < rows)
        precondition(col >= 0 && col < cols)
        return cells[row][col]
    }

    /// 한 행 전체를 셀 배열로 반환. 렌더러용.
    public func row(_ r: Int) -> [Cell] {
        precondition(r >= 0 && r < rows)
        return cells[r].cells
    }

    /// 한 viewport 행이 soft-wrap 되었는지(다음 행으로 이어지는지). 렌더러/reflow용.
    public func rowWrapped(_ r: Int) -> Bool {
        precondition(r >= 0 && r < rows)
        return cells[r].wrapped
    }

    // MARK: - 기본 mutation

    /// 한 글자를 현재 cursor 위치에 쓰고 cursor를 진행.
    /// xterm-style deferred wrap: 마지막 열에서는 wrap을 다음 평문까지 미룸.
    /// East Asian Wide char는 2 cell 점유 (선행 cell + continuation marker).
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

        // wide char가 마지막 열에 걸리면 그 cell은 비우고 다음 줄로 wrap.
        if wide && cursorCol == cols - 1 {
            cells[cursorRow][cursorCol] = Cell.empty(attrs: pen)
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

        // wide 문자의 한쪽 셀만 덮어쓰면 짝 셀이 orphan으로 남아 반쪽 글리프가 깨져
        // 보인다(Claude Code 등 TUI가 커서를 옮겨 부분 재그리기할 때 발생). 덮어쓰기
        // 전에 걸친 wide 문자의 짝을 공백으로 지운다. wide 문자를 쓸 땐 continuation이
        // 차지할 다음 칸도 같이 정리.
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

    /// `(row,col)`을 덮어쓰기 직전에, 그 자리에 걸친 wide 문자의 짝 셀을 공백으로
    /// 지운다. col이 continuation이면 lead(col-1)를, col이 wide lead면 continuation
    /// (col+1)을 비운다. 이렇게 해야 wide 문자의 반쪽만 덮을 때 orphan 글리프가 안 남는다.
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

    /// LF (`\n`): cursor를 한 줄 아래로.
    /// - scroll region 바닥(`scrollBottom`)에 닿으면 region 안에서 scrollUp(1).
    /// - region 밖의 frozen 영역에서는 단순 cursor 이동, 화면 끝에선 no-op.
    public func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom {
            scrollUp(count: 1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
        bumpVersion()
    }

    /// CR (`\r`): cursor를 줄 시작으로.
    public func carriageReturn() {
        pendingWrap = false
        cursorCol = 0
        bumpVersion()
    }

    /// BS (`\b`): cursor를 한 칸 왼쪽으로. 글자는 지우지 않는다.
    /// 줄 시작에서는 no-op (간단한 모델 — wrap 되돌리기 없음).
    public func backspace() {
        pendingWrap = false
        if cursorCol > 0 {
            cursorCol -= 1
            bumpVersion()
        }
    }

    // MARK: - 스크롤

    /// scroll region을 위로 `count`줄만큼 밀어 올림. region 밖 행은 영향 없음.
    /// 위로 빠지는 줄은 region이 화면 최상단에서 시작할 때만 (primary buffer + scrollTop==0)
    /// scrollback에 push, 아니면 그냥 버림. 바닥은 빈 줄로 채움.
    public func scrollUp(count n: Int) {
        guard n > 0 else { return }
        let regionHeight = scrollBottom - scrollTop + 1
        guard regionHeight > 0 else { return }
        let evictCount = min(n, regionHeight)

        // scrollback에는 region이 화면 최상단(scrollTop == 0)에서 시작하고 alt-screen이
        // 아닐 때만 push. tmux 상태바처럼 region이 중간에 있으면 위로 빠지는 내용을
        // 누적하지 않음 (xterm 동작).
        //
        // DEC 2026 synchronized output(inSyncOutputMode) 중에도 push한다 — sync는
        // presentation hint일 뿐 scrollback과 무관(실제 터미널들과 동일). Claude Code 등
        // primary-screen TUI의 redraw 프레임은 대부분 in-place(cursor up→reprint→복귀,
        // net-zero scroll)라 scrollback에 아무것도 안 쌓이고, 실제 새 내용이 위로 밀려
        // 나갈 때만 push되어 사용자가 위로 스크롤해 대화 history를 볼 수 있음. (sync
        // frame은 host가 ESU까지 모아 atomic하게 present하므로 torn-frame 중복도 없음.)
        // 이전엔 inSyncOutputMode 동안 push를 막았는데, 그게 TUI의 history를 통째로
        // 버려 "위로 스크롤이 안 되고 화면 밖으로 사라지는" 회귀를 만들었음.
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
            // region 내 위로 shift
            for r in scrollTop...(scrollBottom - evictCount) {
                cells[r] = cells[r + evictCount]
            }
            // region 바닥 evictCount줄을 blank로
            for r in (scrollBottom - evictCount + 1)...scrollBottom {
                cells[r] = blank
            }
        }
        bumpVersion()
    }

    private func pushToScrollback(_ line: Line) {
        scrollback.append(line)
        scrollbackPushCount &+= 1
        if scrollback.count > maxScrollbackLines {
            scrollback.removeFirst(scrollback.count - maxScrollbackLines)
        }
    }

    // MARK: - 커서 이동 (CSI)

    /// CUP / HVP — `\e[r;cH` 또는 `\e[r;cf`. 1-based 좌표.
    public func setCursor(row r: Int, col c: Int) {
        let newRow = max(0, min(rows - 1, max(r, 1) - 1))
        let newCol = max(0, min(cols - 1, max(c, 1) - 1))
        cursorRow = newRow
        cursorCol = newCol
        pendingWrap = false
        bumpVersion()
    }

    /// CUU — cursor up by n (1 default), 위쪽 경계로 clip.
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

    /// CHA / HPA — 같은 줄에서 cursor를 절대 col로 이동 (1-based).
    public func setCursorColumn(_ col: Int) {
        cursorCol = max(0, min(cols - 1, max(col, 1) - 1))
        pendingWrap = false
        bumpVersion()
    }

    /// VPA — cursor를 절대 row로 이동 (1-based). col은 유지.
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
    ///   0 (default): cursor → 줄 끝
    ///   1: 줄 시작 → cursor (둘 다 포함)
    ///   2: 줄 전체
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
    ///   0 (default): cursor → 화면 끝
    ///   1: 화면 시작 → cursor
    ///   2: 화면 전체 (cursor 위치 유지)
    ///   3: 화면 + scrollback (현재는 2와 동일 — scrollback 미구현)
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

    /// IL — cursor 위치에 n개의 빈 줄 삽입. cursor row와 그 아래(scrollBottom까지)가 아래로 밀림.
    /// scroll region 밖에선 no-op.
    public func insertLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBottom else { return }
        let count = max(1, n)
        let regionRemain = scrollBottom - cursorRow + 1
        let actual = min(count, regionRemain)
        let blank = Line.blank(cols: cols, attrs: pen)
        // cursorRow~scrollBottom 사이에서 아래쪽 actual개 잘림, 위에 actual개 빈 줄 삽입.
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

    /// DL — cursor row부터 n개 줄 삭제. 아래쪽이 위로 당겨짐. region 바닥은 blank로 채움.
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

    /// ICH — cursor 위치에 n개 빈 셀 삽입. 그 줄의 오른쪽 셀들이 우로 밀림 (마지막은 잘림).
    public func insertChars(_ n: Int) {
        guard cursorRow >= 0, cursorRow < rows else { return }
        guard cursorCol >= 0, cursorCol < cols else { return }
        let count = max(1, n)
        let actual = min(count, cols - cursorCol)
        var row = cells[cursorRow]
        let blank = Cell.empty(attrs: pen)
        // 끝에서부터 shift right
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

    /// DCH — cursor 위치 셀부터 n개 삭제. 오른쪽 셀들이 왼쪽으로 당겨짐. 줄 끝은 blank로.
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

    /// ECH — cursor 위치부터 같은 줄에서 n개 셀을 blank로 (cursor는 그대로).
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

    /// SD — scroll region을 아래로 `count`줄만큼 밀어 내림 (위에 빈 줄 삽입).
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
            // region 내 아래로 shift (역순으로 복사)
            for r in stride(from: scrollBottom, through: scrollTop + insertCount, by: -1) {
                cells[r] = cells[r - insertCount]
            }
            for r in scrollTop..<(scrollTop + insertCount) {
                cells[r] = blank
            }
        }
        bumpVersion()
    }

    // MARK: - SGR (pen 갱신)

    /// `\e[ ... m` — pen 속성을 누적 갱신. `-1`(미지정)은 0(reset)으로 정규화.
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

    /// `38;5;n` 또는 `38;2;r;g;b` 파싱. (색, 추가 소비한 파람 수) 반환.
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

    /// SIGWINCH에 대응. 셀 행렬을 새 크기로 재구성.
    /// - primary 화면에서 **컬럼이 바뀌면 reflow** (soft-wrap 된 줄을 새 너비에 맞춰
    ///   재배치). 그 외(alt 화면, 너비 불변)는 trim/pad.
    /// - 행이 줄면 가장 오래된 행이 scrollback으로, 늘면 하단을 빈 셀로 패딩.
    public func resize(cols newCols: Int, rows newRows: Int) {
        precondition(newCols > 0 && newRows > 0)
        if newCols == cols && newRows == rows { return }

        if !isAltScreenActive && newCols != cols {
            // 컬럼이 바뀌는 primary 화면 → reflow. soft-wrap 된 물리 행들을 논리 줄로
            // 재결합해 새 너비로 다시 쪼개고 scrollback+viewport로 재분배하며 커서의
            // 논리 위치를 보존. (alt 화면은 앱이 스스로 redraw하므로 제외.)
            reflowPrimary(toCols: newCols, toRows: newRows)
        } else {
            // alt 화면이거나 순수 행 변경 → 단순 trim/pad. 너비가 그대로면 wrap 경계가
            // 움직이지 않으므로 reflow 불필요.
            resizeTrimPad(toCols: newCols, toRows: newRows)
        }

        cols = newCols
        rows = newRows
        // resize 시 scroll region은 전체 화면으로 reset (xterm 동작).
        // 앱이 SIGWINCH 후 다시 DECSTBM을 설정함.
        scrollTop = 0
        scrollBottom = newRows - 1
        bumpVersion()
    }

    /// 단순 trim/pad resize. alt 화면 또는 너비 불변 행 변경에 사용. 호출 시점에
    /// `cols`/`rows`는 아직 옛 값(공통 tail이 갱신).
    private func resizeTrimPad(toCols newCols: Int, toRows newRows: Int) {
        // shrink 시 어느 쪽 행을 잘라낼지 — cursor 기준으로 결정.
        //   cursor가 새 viewport에 들어가면 (cursorRow < newRows) → 아래쪽을 잘라냄.
        //     prompt(cursor 위쪽)는 유지, 빈 bottom만 사라짐 → "prompt 누적" 회귀 막음.
        //   안 들어가면 → 초과분 위쪽을 scrollback으로 push.
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

        // saved primary가 있으면 같이 resize (동일 크기 유지 + shrink 시 자기 scrollback에 push).
        if var saved = savedPrimary {
            let savedRows = saved.cells.count
            let savedCols = saved.cells.first?.count ?? 0
            let savedRowOffset = newRows < savedRows ? savedRows - newRows : 0
            if savedRowOffset > 0 {
                for r in 0..<savedRowOffset {
                    saved.scrollback.append(saved.cells[r])
                    saved.scrollbackPushCount &+= 1
                    if saved.scrollback.count > maxScrollbackLines {
                        saved.scrollback.removeFirst(saved.scrollback.count - maxScrollbackLines)
                    }
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

    /// 컬럼 reflow (primary 화면 전용). 호출 시점에 `cols`/`rows`는 아직 옛 값.
    /// scrollback+viewport를 논리 줄로 재결합 → 새 너비로 재분할 → scrollback과
    /// `newRows` 높이 viewport로 재분배. 커서 논리 위치 보존.
    private func reflowPrimary(toCols newCols: Int, toRows newRows: Int) {
        // 1. scrollback + viewport를 하나의 연속 물리 행 시퀀스로. 마지막 scrollback
        //    행의 wrap 플래그가 첫 viewport 행으로 이어진다.
        let phys: [Line] = scrollback + cells
        let cursorAbs = scrollback.count + cursorRow

        // 2. 커서 아래의 빈 padding 행은 버린다(reflow 후 다시 채움). 커서·마지막
        //    콘텐츠 행까지는 유지.
        var lastKeep = cursorAbs
        for i in phys.indices where !isBlankRow(phys[i]) { lastKeep = max(lastKeep, i) }
        let kept = Array(phys[0...min(lastKeep, phys.count - 1)])

        // 3. 논리 줄로 그룹핑(wrap 플래그로 이어진 run). 커서를 (논리 줄 index, 줄 내
        //    offset)로 기록.
        var logicals: [[Cell]] = []
        var curCells: [Cell] = []
        var cursorLi = 0
        var cursorLcol = 0
        for (i, row) in kept.enumerated() {
            let base = curCells.count
            curCells.append(contentsOf: row.cells)
            if i == cursorAbs {
                cursorLi = logicals.count
                // pendingWrap은 커서를 마지막 칸 "한 칸 너머"에 둔다 → 행 전체 길이.
                cursorLcol = base + (pendingWrap ? row.cells.count
                                                 : min(max(0, cursorCol), row.cells.count))
            }
            if !row.wrapped {
                logicals.append(curCells)
                curCells = []
            }
        }
        if !curCells.isEmpty { logicals.append(curCells) }
        if logicals.isEmpty { logicals.append([]) }

        // 4. 논리 줄별 trailing blank 셀 제거(하드 개행 padding). 단, 커서 줄에서는
        //    커서 컬럼 아래로는 자르지 않는다.
        for li in logicals.indices {
            var n = logicals[li].count
            while n > 0 && isBlankCell(logicals[li][n - 1]) { n -= 1 }
            if li == cursorLi { n = max(n, cursorLcol) }
            if n < logicals[li].count { logicals[li].removeLast(logicals[li].count - n) }
        }

        // 5. 각 논리 줄을 newCols로 재분할 → wrap 플래그를 가진 새 물리 행.
        var newPhys: [Line] = []
        var newCursorAbs = 0
        var newCursorCol = 0
        var newPendingWrap = false
        for (li, L) in logicals.enumerated() {
            if L.isEmpty {
                if li == cursorLi { newCursorAbs = newPhys.count; newCursorCol = 0 }
                newPhys.append(paddedRow([], to: newCols, wrapped: false))
                continue
            }
            var idx = 0
            while idx < L.count {
                let end = min(idx + newCols, L.count)
                let isLast = (end == L.count)
                if li == cursorLi, cursorLcol >= idx, cursorLcol < end || isLast {
                    newCursorAbs = newPhys.count
                    let off = cursorLcol - idx
                    if off >= newCols {
                        newCursorCol = newCols - 1
                        newPendingWrap = true
                    } else {
                        newCursorCol = off
                    }
                }
                newPhys.append(paddedRow(Array(L[idx..<end]), to: newCols, wrapped: !isLast))
                idx = end
            }
        }
        if newPhys.isEmpty { newPhys.append(paddedRow([], to: newCols, wrapped: false)) }

        // 6. viewport(마지막 newRows) + scrollback(나머지). 콘텐츠가 적으면 바닥 패딩.
        if newPhys.count < newRows {
            for _ in 0..<(newRows - newPhys.count) {
                newPhys.append(paddedRow([], to: newCols, wrapped: false))
            }
        }
        let vpStart = newPhys.count - newRows
        var newScrollback = Array(newPhys[0..<vpStart])
        let newViewport = Array(newPhys[vpStart..<newPhys.count])

        // 7. 커밋. scrollback 한도 초과분 evict.
        if newScrollback.count > maxScrollbackLines {
            newScrollback.removeFirst(newScrollback.count - maxScrollbackLines)
        }
        scrollback = newScrollback
        cells = newViewport
        cursorRow = max(0, min(newRows - 1, newCursorAbs - vpStart))
        cursorCol = max(0, min(newCols - 1, newCursorCol))
        pendingWrap = newPendingWrap

    }

    /// 시각적으로 빈 셀(공백 + 배경/링크/강조 없음)인지. reflow의 trailing 트리밍용.
    private func isBlankCell(_ c: Cell) -> Bool {
        c.char == " " && c.attrs.bg == nil && c.hyperlink == nil
            && !c.attrs.inverse && !c.attrs.underline && !c.attrs.strikethrough
    }

    /// wrap 되지 않았고 모든 셀이 빈 행인지. reflow가 버릴 padding 행 판정용.
    private func isBlankRow(_ line: Line) -> Bool {
        !line.wrapped && line.cells.allSatisfy { isBlankCell($0) }
    }

    /// `width` 길이로 pad/trim 한 Line 생성 (reflow용).
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

    /// DECSTBM 적용. `top`, `bottom`은 0-based, inclusive.
    /// 잘못된 범위면 무시 (`top >= bottom`이거나 `bottom >= rows`인 invalid 케이스).
    /// 유효한 region 설정 후 cursor는 home (0,0)으로 이동 (DECOM 비활성 가정).
    public func setScrollRegion(top: Int, bottom: Int) {
        let newTop = max(0, top)
        let newBottom = min(rows - 1, bottom)
        guard newTop < newBottom else {
            // 명백히 잘못된 범위 — 무시 (xterm 동작)
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

    /// alt buffer로 swap. 현재 primary 상태(cells/cursor/pen/scrollback/visibility)를 snapshot.
    /// 알려진 한도: 1049/1047/47 차이를 구분 안 함 — 모두 1049 의미로 처리 (vim/less/htop 호환).
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
        // 빈 alt buffer로 swap. pen은 그대로 (앱이 곧 SGR로 재설정).
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

    /// alt에서 빠져나와 primary 복원. snapshot이 없으면 no-op.
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

    /// DECTCEM 토글. private mode 25 `h/l` 디스패치에서 호출.
    public func setCursorVisible(_ visible: Bool) {
        if cursorVisible == visible { return }
        cursorVisible = visible
        bumpVersion()
    }

    /// DECSCUSR 적용. handleCSI에서 호출.
    public func setCursorShape(_ shape: CursorShape) {
        if cursorShape == shape { return }
        cursorShape = shape
        bumpVersion()
    }

    /// OSC 8 활성 URI 갱신. nil은 비활성.
    /// 이후의 `putChar`가 cells의 `hyperlink` 필드에 이 값 attach.
    public func setHyperlink(_ uri: String?) {
        currentHyperlink = uri
        // 이미 그려진 cell은 영향 없음 → version 안 올림.
    }

    /// 스크롤백 전체 비우기 (ED mode 3 등이 사용).
    public func clearScrollback() {
        scrollback.removeAll(keepingCapacity: true)
        bumpVersion()
    }

    // MARK: - 디버그/스냅샷

    /// 디버그/테스트 편의: grid를 줄 단위 문자열로 dump (속성 무시).
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
