import AppKit
import Combine
import Foundation

/// 터미널 인스턴스 1개. PTY + 파서 + Grid + 렌더 상태를 묶음.
/// 호스트(cmux / halite.app)가 생성·소유하고 `HaliteTerminalView`에 주입.
public final class HaliteSession: ObservableObject {
    public private(set) var config: HaliteConfig

    @Published public private(set) var title: String = ""
    @Published public private(set) var workingDirectory: String? = nil
    @Published public private(set) var processExited: Bool = false
    public private(set) var exitCode: Int32? = nil

    /// M1 placeholder: 누적된 PTY 출력. M2+에서 `Grid` + parser로 교체됨.
    @Published public private(set) var rawOutput: String = ""

    // 호스트가 구독하는 콜백. weak 캡처 권장.
    public var onTitleChanged: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onURLClick: ((URL) -> Void)?
    public var onClipboardWrite: ((String) -> Void)?
    public var onOutput: ((Data) -> Void)?

    private let pty = PTYHost()
    private var utf8Decoder = UTF8Decoder()

    public init(config: HaliteConfig) {
        self.config = config

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
            // M1에선 콘솔에 출력. M2에서 에러 상태 모델링.
            NSLog("halite: PTY spawn failed: \(error)")
        }
    }

    /// 키 이벤트 외의 추가 입력 (예: 호스트가 합성한 텍스트).
    public func write(_ bytes: Data) {
        pty.write(bytes)
    }

    public func resize(cols: Int, rows: Int) {
        pty.resize(cols: cols, rows: rows)
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
        let appended = utf8Decoder.append(data)
        if !appended.isEmpty {
            rawOutput.append(appended)
        }
    }

    private func handlePTYExit(code: Int32) {
        processExited = true
        exitCode = code
        onExit?(code)
    }
}

/// PTY가 UTF-8 시퀀스 중간에 끊어 보내도 안전하게 누적 디코드.
/// 가장 긴 유효 prefix만 방출하고 나머지(부분 시퀀스)는 다음 호출까지 보류.
/// M1 placeholder. M2+에서 `VTParser` 안으로 이동.
private struct UTF8Decoder {
    private var pending: [UInt8] = []

    mutating func append(_ data: Data) -> String {
        pending.append(contentsOf: data)
        if pending.isEmpty { return "" }

        // UTF-8 코드포인트는 최대 4바이트. 뒤쪽에서 최대 3바이트까지 잘라보며
        // 디코딩되는 가장 긴 prefix를 찾는다.
        let maxTrail = min(3, pending.count)
        for trail in 0...maxTrail {
            let len = pending.count - trail
            if len == 0 { return "" }
            let slice = pending.prefix(len)
            if let str = String(bytes: slice, encoding: .utf8) {
                pending.removeFirst(len)
                return str
            }
        }

        // 어떤 prefix로도 디코드 실패 — 손상된 바이트. 한 바이트 버리고 진행.
        pending.removeFirst()
        return ""
    }
}
