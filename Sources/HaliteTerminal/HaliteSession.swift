import AppKit
import Combine
import Foundation

/// 터미널 인스턴스 1개. PTY + 파서 + Grid를 묶음.
/// 호스트(cmux / halite.app)가 생성·소유하고 `HaliteTerminalView`에 주입.
public final class HaliteSession: ObservableObject {
    public private(set) var config: HaliteConfig

    @Published public private(set) var title: String = ""
    @Published public private(set) var workingDirectory: String? = nil
    @Published public private(set) var processExited: Bool = false
    public private(set) var exitCode: Int32? = nil

    /// VTParser가 발행하는 의미적 이벤트 (디버그/테스트 hook 용).
    /// 화면 렌더링은 더 이상 이걸 통하지 않고 `grid` + `gridChanged`를 본다.
    public let outputEvents = PassthroughSubject<HaliteOutputEvent, Never>()

    /// 셀 grid (현재 viewport).
    public let grid: Grid

    /// grid mutation 알림. 한 PTY chunk 처리 중에 여러 번 발사될 수 있으므로
    /// 호스트는 runloop 단위로 coalesce 권장.
    public let gridChanged = PassthroughSubject<Void, Never>()

    // 호스트가 구독하는 콜백. weak 캡처 권장.
    public var onTitleChanged: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onURLClick: ((URL) -> Void)?
    public var onClipboardWrite: ((String) -> Void)?
    public var onOutput: ((Data) -> Void)?

    private let pty = PTYHost()
    private let parser = VTParser()

    public init(config: HaliteConfig) {
        self.config = config
        self.grid = Grid(
            cols: 80,
            rows: 24,
            pen: CellAttrs(fg: config.foregroundColor)
        )
        self.grid.maxScrollbackLines = config.scrollbackLines

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
            NSLog("halite: PTY spawn failed: \(error)")
        }
    }

    /// 키 이벤트 외의 추가 입력 (예: 호스트가 합성한 텍스트).
    public func write(_ bytes: Data) {
        pty.write(bytes)
    }

    public func resize(cols: Int, rows: Int) {
        grid.resize(cols: cols, rows: rows)
        pty.resize(cols: cols, rows: rows)
        gridChanged.send()
    }

    public func clearSelection() {
        // TODO(M8)
    }

    /// 폰트/색상/팔레트 변경 등 hot-reload 시 호출.
    public func updateConfig(_ config: HaliteConfig) {
        self.config = config
        // TODO: 렌더러/아틀라스/파서로 전파
    }

    public func terminate() {
        pty.terminate()
    }

    // MARK: - Internals

    private func handlePTYData(_ data: Data) {
        onOutput?(data)
        parser.feed(data)
        // parser delegate가 grid를 mutate 했으므로 호스트에 한 번 알림.
        gridChanged.send()
    }

    private func handlePTYExit(code: Int32) {
        processExited = true
        exitCode = code
        onExit?(code)
    }

    /// OSC 0/2 → window title.
    fileprivate func dispatchTitleIfNeeded(_ oscParams: [String]) {
        guard oscParams.count >= 2 else { return }
        switch oscParams[0] {
        case "0", "2":
            let newTitle = oscParams[1]
            if newTitle != title {
                title = newTitle
                onTitleChanged?(newTitle)
            }
        default:
            break
        }
    }

    /// 파서가 발행한 CSI를 grid mutation으로 변환.
    fileprivate func handleCSI(
        params: [Int],
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
        case 0x53: grid.scrollUp(count: p1)   // S — SU
        case 0x54: grid.scrollDown(count: p1) // T — SD
        case 0x6D:                          // m — SGR
            grid.applySGR(params)
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
            // 1049 (alt screen) 등은 M3.6 이후에 추가
            default:
                break
            }
        }
    }
}

extension HaliteSession: VTParserDelegate {
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
        handleCSI(params: params, finalByte: finalByte, privateMarker: privateMarker)
        outputEvents.send(.csi(
            params: params,
            intermediates: intermediates,
            finalByte: finalByte,
            privateMarker: privateMarker
        ))
    }

    public func vtParser(_ parser: VTParser, didEmitOSC params: [String]) {
        dispatchTitleIfNeeded(params)
        outputEvents.send(.osc(params))
    }
}
