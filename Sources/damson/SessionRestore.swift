import AppKit
import DamsonTerminal

/// 세션 상태 복원 — 종료 시 창/탭/pane 레이아웃 + 각 pane의 cwd를 직렬화하고,
/// 시작 시 그 구조로 복원한다. cwd는 proc_pidinfo로 OS에서 직접 조회(셸 설정 무관).
///
/// 스크롤백 텍스트는 저장하지 않음 (레이아웃 + cwd만 — 터미널 복원의 표준 범위).

// MARK: - 직렬화 모델

/// pane 트리 노드의 직렬화 형태.
/// `scrollbackID`는 (설정이 켜졌을 때) 그 pane의 scrollback이 저장된 파일 키. 옵셔널이라
/// 이 필드가 없던 구버전 저장 데이터도 디코드된다(scrollback 없이 복원).
indirect enum RestorablePane: Codable {
    case leaf(cwd: String?, scrollbackID: String?)
    case split(direction: String, ratio: Double, first: RestorablePane, second: RestorablePane)
}

/// 한 윈도우 = 탭 배열. 각 탭은 pane 트리의 root.
struct RestorableWindow: Codable {
    var tabs: [RestorablePane]
    var selectedTab: Int
    /// 탭별 사용자 지정 제목(더블클릭 rename). `tabs`와 같은 순서·길이. 옵셔널이라
    /// 이 필드가 없던 구버전 저장 데이터도 그대로 디코드된다(전부 자동 제목으로 복원).
    var tabTitles: [String?]?
}

/// 전체 복원 상태.
struct RestorableState: Codable {
    var windows: [RestorableWindow]
}

// MARK: - 저장/로드

enum SessionRestore {
    private static let key = "damson.restorableState"

    static func save(_ state: RestorableState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> RestorableState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(RestorableState.self, from: data)
        else { return nil }
        return state
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Scrollback 복원 (옵셔널 — 설정 토글)

    /// 설정: 재시작 시 각 pane의 scrollback 텍스트도 복원할지. 기본 꺼짐.
    static var scrollbackRestoreEnabled: Bool {
        UserDefaults.standard.bool(forKey: "damson.restoreScrollback")
    }

    /// scrollback 파일 디렉토리 (~/Library/Application Support/Damson/scrollback).
    private static var scrollbackDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Damson/scrollback", isDirectory: true)
    }

    /// 직렬화된 scrollback. 같은 속성의 연속 셀을 run으로 묶어 색·배경·속성을 보존하면서도
    /// 컴팩트하다(대부분 줄은 run 1~몇 개). continuation(wide 후행) 셀은 제외하고 로드 시 재구성.
    private struct SerializedRun: Codable {
        var t: String       // 텍스트
        var a: CellAttrs    // fg/bg/bold/underline/... 전부
    }
    private struct SerializedLine: Codable {
        var r: [SerializedRun]
        var w: Bool          // soft-wrap 연속 여부
    }

    /// 기본(빈) 속성 — 후행 공백 트림 판정용.
    private static func isPlainBlank(_ c: Cell) -> Bool {
        !c.isContinuation && c.char == " " && c.attrs == CellAttrs(fg: .default)
    }

    /// 캡처 시작 전 1회 — 이전 scrollback 파일을 모두 지우고 디렉토리를 새로 만든다.
    /// (매 저장마다 새 UUID로 쓰므로 옛 파일은 orphan — 여기서 정리.)
    static func resetScrollbackDir() {
        let fm = FileManager.default
        try? fm.removeItem(at: scrollbackDir)
        try? fm.createDirectory(at: scrollbackDir, withIntermediateDirectories: true)
    }

    /// 한 세션의 grid(scrollback + 보이는 화면)를 파일로 저장하고 그 id를 반환. 실패 시 nil.
    static func writeScrollback(grid: Grid) -> String? {
        var lines: [SerializedLine] = []
        func serialize(_ line: Line) -> SerializedLine {
            // 후행의 기본-빈 셀은 잘라낸다(배경색 있는 셀은 보존). continuation은 경계 검사만.
            var cells = line.cells
            while let last = cells.last, isPlainBlank(last) { cells.removeLast() }
            var runs: [SerializedRun] = []
            var text = ""
            var attrs: CellAttrs?
            for c in cells where !c.isContinuation {
                if let a = attrs, c.attrs != a {
                    runs.append(SerializedRun(t: text, a: a)); text = ""
                }
                attrs = c.attrs
                text.append(c.char)
            }
            if let a = attrs, !text.isEmpty { runs.append(SerializedRun(t: text, a: a)) }
            return SerializedLine(r: runs, w: line.wrapped)
        }
        for line in grid.scrollback { lines.append(serialize(line)) }
        // 보이는 화면도 포함 (가장 최근 컨텍스트). 후행 빈 줄은 잘라낸다.
        var visible: [SerializedLine] = []
        for r in 0..<grid.rows {
            visible.append(serialize(Line(grid.row(r), wrapped: grid.rowWrapped(r))))
        }
        while let last = visible.last, last.r.isEmpty, !last.w { visible.removeLast() }
        lines.append(contentsOf: visible)
        guard !lines.isEmpty else { return nil }

        let id = UUID().uuidString
        let url = scrollbackDir.appendingPathComponent("\(id).json")
        guard let data = try? JSONEncoder().encode(lines) else { return nil }
        do { try data.write(to: url) } catch { return nil }
        return id
    }

    /// 저장된 scrollback을 `[Line]`로 복원 (없거나 실패 시 nil). 색은 기본값.
    static func readScrollback(id: String) -> [Line]? {
        let url = scrollbackDir.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url),
              let lines = try? JSONDecoder().decode([SerializedLine].self, from: data),
              !lines.isEmpty
        else { return nil }
        var out: [Line] = lines.map { ser in
            var cells: [Cell] = []
            for run in ser.r {
                for ch in run.t {
                    cells.append(Cell(char: ch, attrs: run.a))
                    if Cell.isWide(ch) { cells.append(Cell.continuation(attrs: run.a)) }
                }
            }
            return Line(cells, wrapped: ser.w)
        }
        // 경계 표시 — 복원된 내용 맨 아래에 구분선 (새 세션 프롬프트 바로 위).
        let sep = "──────── session restored ────────"
        out.append(Line(sep.map { Cell(char: $0, attrs: CellAttrs(fg: .default)) }))
        return out
    }
}

// MARK: - PaneNode ↔ RestorablePane 변환

extension PaneNode {
    /// 현재 트리를 직렬화 형태로. 각 leaf의 cwd는 proc_pidinfo로 조회.
    func toRestorable() -> RestorablePane {
        switch kind {
        case .leaf(let session, _):
            let sbID = SessionRestore.scrollbackRestoreEnabled
                ? SessionRestore.writeScrollback(grid: session.grid) : nil
            return .leaf(cwd: session.currentWorkingDirectory, scrollbackID: sbID)
        case .split(let dir, let first, let second, let ratio):
            return .split(
                direction: dir == .horizontal ? "horizontal" : "vertical",
                ratio: Double(ratio),
                first: first.toRestorable(),
                second: second.toRestorable()
            )
        }
    }

    /// 직렬화 형태로부터 트리 재구성. 각 leaf는 cwd에서 새 세션 spawn.
    /// parent 링크도 연결.
    static func from(restorable: RestorablePane) -> PaneNode {
        switch restorable {
        case .leaf(let cwd, let scrollbackID):
            var config = DamsonConfig.fromUserDefaults()
            // 저장된 cwd가 아직 존재하면 거기서, 아니면 fromUserDefaults의 기본(홈).
            if let cwd = cwd, FileManager.default.fileExists(atPath: cwd) {
                config.cwd = cwd
            }
            let restored: [Line]? = (SessionRestore.scrollbackRestoreEnabled ? scrollbackID : nil)
                .flatMap { SessionRestore.readScrollback(id: $0) }
            let session = DamsonSession(config: config, restoredScrollback: restored)
            return PaneNode.leaf(session)
        case .split(let dirStr, let ratio, let first, let second):
            let dir: SplitDirection = (dirStr == "vertical") ? .vertical : .horizontal
            let a = from(restorable: first)
            let b = from(restorable: second)
            let node = PaneNode(kind: .split(
                direction: dir, first: a, second: b, ratio: CGFloat(ratio)
            ))
            a.parent = node
            b.parent = node
            return node
        }
    }
}
