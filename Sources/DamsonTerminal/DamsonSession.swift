import AppKit
import Combine
import Foundation

/// 터미널 인스턴스 1개. PTY + 파서 + Grid를 묶음.
/// 호스트(cmux / damson.app)가 생성·소유하고 `DamsonTerminalView`에 주입.
public final class DamsonSession: ObservableObject {
    @Published public private(set) var config: DamsonConfig

    @Published public private(set) var title: String = ""
    @Published public private(set) var workingDirectory: String? = nil
    @Published public private(set) var processExited: Bool = false
    public private(set) var exitCode: Int32? = nil

    /// VTParser가 발행하는 의미적 이벤트 (디버그/테스트 hook 용).
    /// 화면 렌더링은 더 이상 이걸 통하지 않고 `grid` + `gridChanged`를 본다.
    public let outputEvents = PassthroughSubject<DamsonOutputEvent, Never>()

    /// Bracketed paste 모드. CSI ?2004h/l로 토글. 켜져 있으면 Cmd+V 시 호스트가
    /// pasted 텍스트를 ESC[200~ ... ESC[201~로 wrap해서 보냄.
    public private(set) var bracketedPasteEnabled: Bool = false

    /// Mouse reporting mode. 0 = off, 1000 = press/release, 1002 = + drag, 1003 = any motion.
    public private(set) var mouseReportingMode: Int = 0
    /// SGR mouse encoding (CSI ?1006h). true면 SGR format, false면 X10 classic.
    public private(set) var mouseSGREncoding: Bool = false

    /// 셀 grid (현재 viewport).
    public let grid: Grid

    /// grid mutation 알림. 한 PTY chunk 처리 중에 여러 번 발사될 수 있으므로
    /// 호스트는 runloop 단위로 coalesce 권장.
    public let gridChanged = PassthroughSubject<Void, Never>()

    // 호스트가 구독하는 콜백. weak 캡처 권장.
    public var onTitleChanged: ((String) -> Void)?
    /// 셸이 OSC 7로 보고한 현재 작업 디렉토리. 셸 통합(OSC 7 emit)이 켜져 있을 때만
    /// 갱신된다. split/새 탭이 "현재 디렉토리"를 상속할 때의 소스. 보고가 없으면
    /// spawn 당시의 `config.cwd`로 남는다.
    public private(set) var currentDirectory: String?
    public var onCwdChanged: ((String) -> Void)?
    /// OSC 133;A로 기록된 프롬프트 줄의 절대 줄 번호(scrollbackPushCount 기반이라 evict에도
    /// 안정). ⌘↑/⌘↓ 프롬프트 점프의 소스. 셸 통합(OSC 133 emit)이 켜져 있을 때만 쌓인다.
    public private(set) var promptMarks: [UInt64] = []
    public var onBell: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onURLClick: ((URL) -> Void)?
    public var onClipboardWrite: ((String) -> Void)?
    public var onOutput: ((Data) -> Void)?

    private let pty = PTYHost()
    private let parser = VTParser()

    public init(config: DamsonConfig, restoredScrollback: [Line]? = nil) {
        self.config = config
        self.currentDirectory = config.cwd
        self.grid = Grid(
            cols: 80,
            rows: 24,
            pen: CellAttrs(fg: .default)
        )
        self.grid.maxScrollbackLines = config.scrollbackLines
        self.grid.setCursorShape(config.cursorShape)
        // 라이브 출력 전에 이전 세션 scrollback 주입(세션 복원, 설정 켜졌을 때만 전달됨).
        if let restoredScrollback { grid.seedScrollback(restoredScrollback) }

        parser.delegate = self

        pty.onData = { [weak self] data in
            self?.handlePTYData(data)
        }
        pty.onExit = { [weak self] code in
            self?.handlePTYExit(code: code)
        }

        do {
            try pty.spawn(
                argv: config.argv,
                env: config.env,
                cwd: config.cwd,
                cols: 80,
                rows: 24
            )
        } catch {
            NSLog("damson: PTY spawn failed: \(error)")
        }
    }

    /// 키 이벤트 외의 추가 입력 (예: 호스트가 합성한 텍스트).
    public func write(_ bytes: Data) {
        pty.write(bytes)
    }

    /// 자식 셸의 현재 작업 디렉토리 (세션 복원용). 실패 시 nil.
    public var currentWorkingDirectory: String? {
        pty.childWorkingDirectory
    }

    /// 이 세션이 (프롬프트 대기가 아니라) 명령을 foreground로 실행 중인지.
    /// 종료 확인 다이얼로그가 "실제로 도는 작업이 있는 경우"만 묻도록 판정에 사용.
    public var hasRunningForegroundJob: Bool {
        pty.isRunningForegroundJob
    }

    public func resize(cols: Int, rows: Int) {
        grid.resize(cols: cols, rows: rows)
        pty.resize(cols: cols, rows: rows)
        gridChanged.send()
    }

    /// Reflow the on-screen grid to a new size WITHOUT notifying the shell
    /// (no SIGWINCH). Used during a live window resize so the shell doesn't redraw
    /// (and accumulate) its prompt on every drag frame; the host sends one real
    /// `resize` (SIGWINCH) when the drag ends.
    public func resizeGridOnly(cols: Int, rows: Int) {
        grid.resize(cols: cols, rows: rows)
        gridChanged.send()
    }

    public func clearSelection() {
        // TODO(M8)
    }

    /// 폰트/색상/팔레트 변경 등 hot-reload 시 호출.
    /// `config`이 `@Published`이므로 subscribers(view)가 자동 react.
    public func updateConfig(_ config: DamsonConfig) {
        self.config = config
        grid.maxScrollbackLines = config.scrollbackLines
        // Apply the user's default cursor shape immediately. An app may later
        // override it via DECSCUSR; that takes precedence until the next reset.
        grid.setCursorShape(config.cursorShape)
    }

    public func terminate() {
        pty.terminate()
    }

    // MARK: - Internals

    private func handlePTYData(_ data: Data) {
        onOutput?(data)
        parser.feed(data)
        gridChanged.send()
    }

    private func handlePTYExit(code: Int32) {
        processExited = true
        exitCode = code
        onExit?(code)
    }

    /// OSC dispatch — 0/2(title), 4/10/11(color query), 8(hyperlink), 그 외 무시.
    fileprivate func dispatchOSCIfNeeded(_ oscParams: [String]) {
        guard let kind = oscParams.first else { return }
        switch kind {
        case "0", "2":
            guard oscParams.count >= 2 else { return }
            let newTitle = oscParams[1]
            if newTitle != title {
                title = newTitle
                onTitleChanged?(newTitle)
            }
        case "4":
            // OSC 4 ; index ; spec — query if spec == "?"
            guard oscParams.count >= 3, oscParams[2] == "?",
                  let index = Int(oscParams[1]), (0...15).contains(index) else { return }
            let color = config.theme.paletteColor(index)
            respondToOSCColorQuery(kind: "4", index: index, color: color)
        case "10":
            // OSC 10 ; ? — query default fg
            guard oscParams.count >= 2, oscParams[1] == "?" else { return }
            respondToOSCColorQuery(kind: "10", index: nil, color: config.foregroundColor)
        case "11":
            // OSC 11 ; ? — query default bg
            guard oscParams.count >= 2, oscParams[1] == "?" else { return }
            respondToOSCColorQuery(kind: "11", index: nil, color: config.backgroundColor)
        case "7":
            // OSC 7 ; file://host/path ST — 셸이 보고하는 현재 작업 디렉토리.
            guard oscParams.count >= 2,
                  let path = Self.parseFileURLPath(oscParams[1]) else { return }
            if path != currentDirectory {
                currentDirectory = path
                onCwdChanged?(path)
            }
        case "8":
            // OSC 8 ; params ; URI ST
            //   start: params 보통 "id=xxx" 또는 빈 문자열, URI 비어있지 않음
            //   end: URI 빈 문자열
            let uri = oscParams.count >= 3 ? oscParams[2] : ""
            grid.setHyperlink(uri.isEmpty ? nil : uri)
        case "133":
            // OSC 133 ; A/B/C/D — FinalTerm semantic prompt. v1은 A(프롬프트 시작)만
            // 사용해 프롬프트 줄을 마크한다. B/C/D는 미래용.
            if oscParams.count >= 2, oscParams[1] == "A" {
                let absLine = grid.scrollbackPushCount + UInt64(max(0, grid.cursorRow))
                if promptMarks.last != absLine {
                    promptMarks.append(absLine)
                    if promptMarks.count > 5000 {
                        promptMarks.removeFirst(promptMarks.count - 5000)
                    }
                }
            }
        default:
            break
        }
    }

    /// OSC 7 의 `file://host/path` 에서 path 부분만 추출(퍼센트 디코드). host는 무시.
    static func parseFileURLPath(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }
        let afterScheme = uri.dropFirst("file://".count)
        // host 다음의 첫 '/'부터가 경로. host가 비어 있으면(`file:///path`) 바로 '/'.
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let path = String(afterScheme[slash...])
        return path.removingPercentEncoding ?? path
    }

    private func respondToOSCColorQuery(kind: String, index: Int?, color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let r = UInt16(max(0, min(1, srgb.redComponent)) * 65535)
        let g = UInt16(max(0, min(1, srgb.greenComponent)) * 65535)
        let b = UInt16(max(0, min(1, srgb.blueComponent)) * 65535)
        let rgbSpec = String(format: "rgb:%04x/%04x/%04x", r, g, b)
        let payload: String
        if let index = index {
            payload = "\(kind);\(index);\(rgbSpec)"
        } else {
            payload = "\(kind);\(rgbSpec)"
        }
        let response = "\u{1B}]\(payload)\u{1B}\\"
        if let data = response.data(using: .utf8) {
            pty.write(data)
        }
    }

    /// 파서가 발행한 CSI를 grid mutation으로 변환.
    fileprivate func handleCSI(
        params: [Int],
        intermediates: [UInt8],
        finalByte: UInt8,
        privateMarker: UInt8?
    ) {
        // 자주 쓰는 default 처리: 첫 param이 미지정(-1) 또는 0일 때 1로.
        let p1 = (params.first ?? -1) <= 0 ? 1 : params[0]

        switch finalByte {
        case 0x41: grid.cursorUp(p1)        // A — CUU
        case 0x42: grid.cursorDown(p1)      // B — CUD
        case 0x43: grid.cursorForward(p1)   // C — CUF
        case 0x44: grid.cursorBack(p1)      // D — CUB
        case 0x48, 0x66:                    // H / f — CUP / HVP
            let r = (params.count > 0 && params[0] > 0) ? params[0] : 1
            let c = (params.count > 1 && params[1] > 0) ? params[1] : 1
            grid.setCursor(row: r, col: c)
        case 0x4A:                          // J — ED
            let mode = (params.first ?? -1) < 0 ? 0 : params[0]
            grid.eraseInDisplay(mode: mode)
        case 0x4B:                          // K — EL
            let mode = (params.first ?? -1) < 0 ? 0 : params[0]
            grid.eraseInLine(mode: mode)
        case 0x47, 0x60:                    // G / ` — CHA / HPA: 절대 column으로
            grid.setCursorColumn(p1)
        case 0x64:                          // d — VPA: 절대 row로
            grid.setCursorRow(p1)
        case 0x58:                          // X — ECH: cursor부터 n셀 erase
            grid.eraseChars(p1)
        case 0x4C:                          // L — IL: 빈 줄 n개 삽입
            grid.insertLines(p1)
        case 0x4D:                          // M — DL: n줄 삭제
            grid.deleteLines(p1)
        case 0x40:                          // @ — ICH: 빈 셀 n개 삽입
            grid.insertChars(p1)
        case 0x50:                          // P — DCH: n셀 삭제
            grid.deleteChars(p1)
        case 0x73:                          // s — SC (DECSC ANSI variant)
            if privateMarker == nil {
                grid.saveCursor()
            }
        case 0x75:                          // u — RC (DECRC ANSI variant)
            if privateMarker == nil {
                grid.restoreCursor()
            }
        case 0x53: grid.scrollUp(count: p1)   // S — SU
        case 0x54: grid.scrollDown(count: p1) // T — SD
        case 0x72:                          // r — DECSTBM (private marker가 없어야 함)
            if privateMarker == nil {
                let top = (params.count > 0 && params[0] > 0) ? params[0] : 1
                let bot = (params.count > 1 && params[1] > 0) ? params[1] : grid.rows
                grid.setScrollRegion(top: top - 1, bottom: bot - 1)
            }
        case 0x63:                          // c — DA1 / DA2
            if privateMarker == nil && intermediates.isEmpty {
                // Primary DA → VT102 identification: ESC [ ? 6 c
                pty.write(Data([0x1B, 0x5B, 0x3F, 0x36, 0x63]))
            } else if privateMarker == 0x3E && intermediates.isEmpty {
                // Secondary DA → ESC [ > 0 ; 0 ; 0 c (generic)
                pty.write(Data([0x1B, 0x5B, 0x3E, 0x30, 0x3B, 0x30, 0x3B, 0x30, 0x63]))
            }
        case 0x71:                          // q — DECSCUSR (intermediate=SP)
            if privateMarker == nil && intermediates == [0x20] {
                let ps = params.first ?? 0
                let shape: Grid.CursorShape
                switch ps {
                case 1, 2: shape = .block
                case 3, 4: shape = .underline
                case 5, 6: shape = .bar
                default: shape = config.cursorShape  // 0/미지정 = reset → 사용자 기본
                }
                grid.setCursorShape(shape)
            }
        case 0x6D:                          // m — SGR
            // SGR은 `CSI ... m`에 private marker도 intermediate도 **없을 때**만.
            // `CSI > 4 ; 2 m` (xterm modifyOtherKeys / Kitty keyboard protocol)나
            // `CSI ? Pn m` (DEC private SGR) 등은 SGR이 아님.
            // Claude Code가 시작 시 `\x1b[>4;2m`을 보내는데, 이걸 SGR로 처리하면
            // param 4 → underline ON → 이후 reset이 안 와서 세션 전체에 밑줄 leak됨.
            // 미러: anthropics/claude-code#23698, halite Rust 40bd82f.
            if privateMarker == nil && intermediates.isEmpty {
                grid.applySGR(params)
            }
        case 0x68:                          // h — SET MODE
            applyModeChange(params: params, privateMarker: privateMarker, set: true)
        case 0x6C:                          // l — RESET MODE
            applyModeChange(params: params, privateMarker: privateMarker, set: false)
        default:
            break // 미지원 CSI는 무시 (alt screen / scroll region 등은 후속 milestone)
        }
    }

    private func applyModeChange(params: [Int], privateMarker: UInt8?, set: Bool) {
        // DEC private mode (`?`) 만 처리. ANSI mode는 거의 안 쓰임.
        guard privateMarker == 0x3F else { return }
        for p in params where p > 0 {
            switch p {
            case 25:
                grid.setCursorVisible(set)
            case 47, 1047, 1049:
                // 47/1047/1049 차이는 cursor 저장과 클리어 타이밍의 미세 차이지만,
                // M3.7은 셋 다 동일하게 "enter/leave alt"로 처리. 실용상 vim/less/htop OK.
                if set {
                    grid.enterAltScreen()
                } else {
                    grid.leaveAltScreen()
                }
            case 2004:
                // Bracketed paste mode toggle. 호스트(view)가 read.
                bracketedPasteEnabled = set
            case 1000, 1002, 1003:
                // 마우스 reporting 활성화 — 가장 강한 모드만 keep.
                mouseReportingMode = set ? p : 0
            case 1006:
                // SGR mouse encoding
                mouseSGREncoding = set
            case 2026:
                // Synchronized Output Mode (DECSET 2026) — Claude Code, Ink 기반 TUI
                // 등 alt-screen 안 쓰고 primary에 cursor positioning으로 redraw 하는
                // 앱이 사용.
                //   - hasUsedSyncOutput: 한 번이라도 set 되면 sticky-true. resize 시
                //     viewport-top anchoring 등 TUI-friendly 정책 활성화.
                //   - inSyncOutputMode: transient (set ⇔ true, clear ⇔ false).
                //     host가 frame을 ESU까지 모아 atomic하게 present하는 데 사용
                //     (torn frame 방지). scrollback 누적과는 무관 — sync는 presentation
                //     hint일 뿐이라 redraw 중에도 위로 빠지는 줄은 정상 누적됨.
                if set { grid.hasUsedSyncOutput = true }
                grid.inSyncOutputMode = set
            default:
                break
            }
        }
    }
}

extension DamsonSession: VTParserDelegate {
    public func vtParser(_ parser: VTParser, didEmitText text: String) {
        for ch in text {
            grid.putChar(ch)
        }
        outputEvents.send(.text(text))
    }

    public func vtParser(_ parser: VTParser, didExecute byte: UInt8) {
        switch byte {
        case 0x08: grid.backspace()
        case 0x0A: grid.lineFeed()
        case 0x0D: grid.carriageReturn()
        case 0x09:
            // TAB — 다음 8-칸 stop으로 (공백으로 채우지 않고 cursor만 이동)
            let next = ((grid.cursorCol / 8) + 1) * 8
            let target = min(next, grid.cols - 1)
            grid.cursorForward(max(target - grid.cursorCol, 1))
        case 0x07:
            onBell?()
        default:
            break
        }
        outputEvents.send(.execute(byte))
    }

    public func vtParser(
        _ parser: VTParser,
        didEmitCSI params: [Int],
        intermediates: [UInt8],
        finalByte: UInt8,
        privateMarker: UInt8?
    ) {
        handleCSI(params: params, intermediates: intermediates, finalByte: finalByte, privateMarker: privateMarker)
        outputEvents.send(.csi(
            params: params,
            intermediates: intermediates,
            finalByte: finalByte,
            privateMarker: privateMarker
        ))
    }

    public func vtParser(_ parser: VTParser, didEmitOSC params: [String]) {
        dispatchOSCIfNeeded(params)
        outputEvents.send(.osc(params))
    }

    public func vtParser(_ parser: VTParser, didEmitESC finalByte: UInt8) {
        switch finalByte {
        case 0x37: // '7' — DECSC: save cursor + pen
            grid.saveCursor()
        case 0x38: // '8' — DECRC: restore cursor + pen
            grid.restoreCursor()
        case 0x63: // 'c' — RIS: 화면 + 상태 리셋 (간소 버전)
            grid.eraseInDisplay(mode: 2)
            grid.setCursor(row: 1, col: 1)
        case 0x3D, 0x3E: // '=' / '>' — application/normal keypad mode (M3.9는 무시)
            break
        default:
            break
        }
    }
}
