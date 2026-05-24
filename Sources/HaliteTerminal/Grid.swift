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
    private var cells: [[Cell]]

    /// 커서 (0-based).
    public private(set) var cursorRow: Int = 0
    public private(set) var cursorCol: Int = 0

    /// 다음 putChar가 wrap을 일으켜야 함을 표시. xterm-style "deferred wrap".
    /// 셀이 마지막 열에 들어간 직후 set, 다음 평문이 들어오면 cursor를 다음 줄로.
    private var pendingWrap: Bool = false

    /// DECTCEM (`\e[?25h` / `\e[?25l`)로 토글되는 커서 가시성.
    /// 셸이 prompt 그릴 동안 잠깐 숨기는 패턴에 사용.
    public private(set) var cursorVisible: Bool = true

    /// DECSTBM scroll region 상단 (0-based, inclusive). 기본값 0.
    public private(set) var scrollTop: Int = 0
    /// DECSTBM scroll region 하단 (0-based, inclusive). 기본값 rows - 1.
    public private(set) var scrollBottom: Int = 0

    /// 현재 펜(pen) 속성. SGR이 갱신.
    public var pen: CellAttrs

    /// SGR 0 (reset) 시 복원되는 기본 펜.
    public let defaultPen: CellAttrs

    /// 호스트가 갱신을 감지하는 단조증가 버전. 매 mutation마다 +1.
    public private(set) var version: UInt64 = 0

    /// 위로 밀려난 줄들. 가장 오래된 것이 index 0, 가장 최근이 마지막.
    /// `maxScrollbackLines`를 초과하면 가장 오래된 것부터 evict.
    public private(set) var scrollback: [[Cell]] = []

    /// scrollback의 누적 push 카운트. evict가 일어나도 단조증가하므로
    /// 호스트가 "그 사이 새로 추가된 줄 수" / "evict 여부"를 판단할 수 있음.
    public private(set) var scrollbackPushCount: UInt64 = 0

    /// scrollback 최대 줄 수. `HaliteSession`이 config에서 받아서 설정.
    public var maxScrollbackLines: Int = 10_000

    /// alt screen 진입 여부. true면 현재 buffer는 alt, 진입 직전의 primary 상태가 `savedPrimary`에 보존.
    public private(set) var isAltScreenActive: Bool = false

    /// alt screen 진입 시 보존되는 primary buffer 스냅샷. alt 도중 resize가 와도 같이 따라감.
    private struct PrimarySnapshot {
        var cells: [[Cell]]
        var cursorRow: Int
        var cursorCol: Int
        var pen: CellAttrs
        var pendingWrap: Bool
        var scrollback: [[Cell]]
        var scrollbackPushCount: UInt64
        var cursorVisible: Bool
        var scrollTop: Int
        var scrollBottom: Int
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
        return cells[r]
    }

    // MARK: - 기본 mutation

    /// 한 글자를 현재 cursor 위치에 쓰고 cursor를 한 칸 진행.
    /// xterm-style: 마지막 열에서는 wrap을 다음 평문까지 미룬다.
    public func putChar(_ ch: Character) {
        if pendingWrap {
            // 직전 putChar로 마지막 열에 도달했음 → 지금 wrap 실행.
            pendingWrap = false
            lineFeed()
            cursorCol = 0
        }
        guard cursorRow >= 0, cursorRow < rows,
              cursorCol >= 0, cursorCol < cols else { return }
        cells[cursorRow][cursorCol] = Cell(char: ch, attrs: pen)
        if cursorCol == cols - 1 {
            pendingWrap = true
        } else {
            cursorCol += 1
        }
        bumpVersion()
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

        // scrollback에는 region이 화면 최상단(scrollTop == 0)에서 시작하는 경우에만 push.
        // tmux 상태바처럼 region이 중간에 있으면 위로 빠지는 내용을 누적하지 않음 (xterm 동작).
        if !isAltScreenActive && scrollTop == 0 {
            for i in 0..<evictCount {
                pushToScrollback(cells[scrollTop + i])
            }
        }

        let blank = Array(repeating: Cell.empty(attrs: pen), count: cols)
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

    private func pushToScrollback(_ line: [Cell]) {
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
        case 1:
            for c in 0...min(cursorCol, cols - 1) { cells[cursorRow][c] = blank }
        case 2:
            for c in 0..<cols { cells[cursorRow][c] = blank }
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
            for r in (cursorRow + 1)..<rows {
                for c in 0..<cols { cells[r][c] = blank }
            }
        case 1:
            for r in 0..<cursorRow {
                for c in 0..<cols { cells[r][c] = blank }
            }
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

    /// SD — scroll region을 아래로 `count`줄만큼 밀어 내림 (위에 빈 줄 삽입).
    public func scrollDown(count n: Int) {
        guard n > 0 else { return }
        let regionHeight = scrollBottom - scrollTop + 1
        guard regionHeight > 0 else { return }
        let insertCount = min(n, regionHeight)
        let blank = Array(repeating: Cell.empty(attrs: pen), count: cols)

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
            case 3:  pen.italic = true
            case 4:  pen.underline = true
            case 7:  pen.inverse = true
            case 22: pen.bold = false
            case 23: pen.italic = false
            case 24: pen.underline = false
            case 27: pen.inverse = false
            case 30...37:
                pen.fg = Palette.normal16[p - 30]
            case 38:
                if let (color, skip) = extendedColor(params: params, from: i + 1) {
                    pen.fg = color
                    i += skip
                }
            case 39:
                pen.fg = defaultPen.fg
            case 40...47:
                pen.bg = Palette.normal16[p - 40]
            case 48:
                if let (color, skip) = extendedColor(params: params, from: i + 1) {
                    pen.bg = color
                    i += skip
                }
            case 49:
                pen.bg = nil
            case 90...97:
                pen.fg = Palette.bright16[p - 90]
            case 100...107:
                pen.bg = Palette.bright16[p - 100]
            default:
                break
            }
            i += 1
        }
        bumpVersion()
    }

    /// `38;5;n` 또는 `38;2;r;g;b` 파싱. (색, 추가 소비한 파람 수) 반환.
    private func extendedColor(params: [Int], from idx: Int) -> (NSColor, Int)? {
        guard idx < params.count else { return nil }
        switch params[idx] {
        case 5:
            guard idx + 1 < params.count else { return nil }
            return (Palette.color256(params[idx + 1]), 2)
        case 2:
            guard idx + 3 < params.count else { return nil }
            let r = max(0, min(255, params[idx + 1]))
            let g = max(0, min(255, params[idx + 2]))
            let b = max(0, min(255, params[idx + 3]))
            return (Palette.rgb(r, g, b), 4)
        default:
            return nil
        }
    }

    // MARK: - resize

    /// SIGWINCH에 대응. 셀 행렬을 새 크기로 재구성.
    /// - 행이 줄면 가장 오래된(top) 행이 버려짐 → 셸이 보낸 최근 출력 유지.
    /// - 행이 늘면 하단을 빈 셀로 패딩.
    /// - 열 변경은 trim/pad. wrap이 깨질 수 있지만 셸이 SIGWINCH 후 재그리기.
    /// 스크롤백은 M3.5 추가 시 같이 손봐야 함.
    public func resize(cols newCols: Int, rows newRows: Int) {
        precondition(newCols > 0 && newRows > 0)
        if newCols == cols && newRows == rows { return }

        let rowOffset: Int = newRows < rows ? rows - newRows : 0

        // 행 shrink 시 위로 사라지는 줄은 scrollback으로 보존.
        // alt 활성 중엔 alt 스크롤백을 만들지 않고, primary 스크롤백도 건드리지 않음
        // (저장된 primary는 아래에서 따로 resize 하면서 그쪽 scrollback에 push).
        if rowOffset > 0 && !isAltScreenActive {
            for r in 0..<rowOffset {
                pushToScrollback(cells[r])
            }
        }

        cells = Self.resizeCellsArray(
            cells, fromCols: cols, fromRows: rows,
            toCols: newCols, toRows: newRows, pen: pen
        )
        cursorRow = max(0, min(newRows - 1, cursorRow - rowOffset))
        cursorCol = max(0, min(newCols - 1, cursorCol))

        // saved primary가 있으면 같이 resize (그쪽도 동일 크기 유지 + shrink 시 자기 scrollback에 push).
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
                toCols: newCols, toRows: newRows, pen: saved.pen
            )
            saved.cursorRow = max(0, min(newRows - 1, saved.cursorRow - savedRowOffset))
            saved.cursorCol = max(0, min(newCols - 1, saved.cursorCol))
            saved.pendingWrap = false
            // saved primary의 scroll region도 새 rows에 맞게 reset/clip.
            saved.scrollTop = 0
            saved.scrollBottom = newRows - 1
            savedPrimary = saved
        }

        cols = newCols
        rows = newRows
        pendingWrap = false
        // resize 시 scroll region은 전체 화면으로 reset (xterm 동작).
        // 앱이 SIGWINCH 후 다시 DECSTBM을 설정함.
        scrollTop = 0
        scrollBottom = newRows - 1
        bumpVersion()
    }

    private static func resizeCellsArray(
        _ source: [[Cell]],
        fromCols: Int, fromRows: Int,
        toCols: Int, toRows: Int,
        pen: CellAttrs
    ) -> [[Cell]] {
        let rowOffset = toRows < fromRows ? fromRows - toRows : 0
        let blank = Cell.empty(attrs: pen)
        var newCells: [[Cell]] = []
        newCells.reserveCapacity(toRows)
        for r in 0..<toRows {
            var newRow: [Cell] = []
            newRow.reserveCapacity(toCols)
            let srcRow = r + rowOffset
            for c in 0..<toCols {
                if srcRow >= 0, srcRow < fromRows, c < fromCols {
                    newRow.append(source[srcRow][c])
                } else {
                    newRow.append(blank)
                }
            }
            newCells.append(newRow)
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
            scrollBottom: scrollBottom
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
            out.append(String(cells[r].map { $0.char }))
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Internals

    private func bumpVersion() {
        version &+= 1
    }

    private static func makeBlank(rows: Int, cols: Int, attrs: CellAttrs) -> [[Cell]] {
        let blankRow = Array(repeating: Cell.empty(attrs: attrs), count: cols)
        return Array(repeating: blankRow, count: rows)
    }
}
