import Foundation

/// VT/ANSI escape sequence state machine.
///
/// 단순화한 Paul Williams' DEC VT-series parser. 핵심 4개 상태만:
///   - ground: printable + C0 controls
///   - escape: ESC 직후
///   - csi: ESC '[' 이후, 파라미터/intermediate/final byte 수집
///   - osc: ESC ']' 이후, BEL 또는 ST(ESC '\\')까지 문자열 수집
///
/// 의미적 이벤트(텍스트/제어/CSI/OSC)를 delegate로 발행. CSI/OSC의 해석
/// (SGR 색, 커서 이동, 타이틀 등)은 consumer 몫.
///
/// UTF-8 멀티바이트는 ground 상태에서 누적 후 안전한 prefix만 String으로
/// 방출. 부분 시퀀스는 다음 feed까지 보류.
public protocol VTParserDelegate: AnyObject {
    func vtParser(_ parser: VTParser, didEmitText text: String)
    func vtParser(_ parser: VTParser, didExecute byte: UInt8)
    func vtParser(
        _ parser: VTParser,
        didEmitCSI params: [Int],
        intermediates: [UInt8],
        finalByte: UInt8,
        privateMarker: UInt8?
    )
    func vtParser(_ parser: VTParser, didEmitOSC params: [String])
    /// ESC + single final byte 시퀀스 (예: `ESC 7` = DECSC, `ESC 8` = DECRC, `ESC c` = RIS).
    /// 인수 없는 단일 바이트 escape만. CSI/OSC와 별개 경로.
    func vtParser(_ parser: VTParser, didEmitESC finalByte: UInt8)
}

public extension VTParserDelegate {
    func vtParser(_ parser: VTParser, didEmitESC finalByte: UInt8) {}
}

public final class VTParser {
    public weak var delegate: VTParserDelegate?

    private enum State {
        case ground
        case escape
        case csi
        case osc
        case oscEsc   // OSC 안에서 ESC를 막 받은 상태 (다음이 '\\'이면 ST)
    }

    private var state: State = .ground

    // CSI accumulator
    private var params: [Int] = []
    /// `-1` = unspecified (consumer가 op에 맞는 default 적용)
    private var currentParam: Int = -1
    private var intermediates: [UInt8] = []
    private var privateMarker: UInt8? = nil

    // OSC accumulator (UTF-8 디코드는 dispatch 시점에)
    private var oscBytes: [UInt8] = []

    // Ground text accumulator (UTF-8 partial-safe 디코드)
    private var textBytes: [UInt8] = []

    public init() {}

    public func feed(_ data: Data) {
        for byte in data { handle(byte) }
        flushText()
    }

    public func feed(_ bytes: [UInt8]) {
        for byte in bytes { handle(byte) }
        flushText()
    }

    public func reset() {
        state = .ground
        params.removeAll()
        currentParam = -1
        intermediates.removeAll()
        privateMarker = nil
        oscBytes.removeAll()
        textBytes.removeAll()
    }

    // MARK: - dispatch

    private func handle(_ b: UInt8) {
        // CAN/SUB — anywhere cancel
        if b == 0x18 || b == 0x1A {
            flushText()
            state = .ground
            return
        }
        switch state {
        case .ground: groundByte(b)
        case .escape: escapeByte(b)
        case .csi: csiByte(b)
        case .osc: oscByte(b)
        case .oscEsc: oscEscByte(b)
        }
    }

    private func groundByte(_ b: UInt8) {
        if b == 0x1B {
            flushText()
            enterEscape()
            return
        }
        // C0 controls (< 0x20) + DEL — execute
        if b < 0x20 || b == 0x7F {
            flushText()
            delegate?.vtParser(self, didExecute: b)
            return
        }
        // Printable + UTF-8 continuation bytes
        textBytes.append(b)
    }

    private func enterEscape() {
        state = .escape
        params.removeAll()
        currentParam = -1
        intermediates.removeAll()
        privateMarker = nil
        oscBytes.removeAll()
    }

    private func escapeByte(_ b: UInt8) {
        switch b {
        case 0x1B:
            enterEscape() // 재진입
        case 0x5B: // '['
            state = .csi
        case 0x5D: // ']'
            state = .osc
        case 0x20...0x2F:
            intermediates.append(b)
        case 0x30...0x7E:
            // ESC + single final byte: DECSC(7) / DECRC(8) / RIS(c) / keypad mode 등.
            delegate?.vtParser(self, didEmitESC: b)
            state = .ground
        default:
            state = .ground
        }
    }

    private func csiByte(_ b: UInt8) {
        switch b {
        case 0x30...0x39: // digit
            if currentParam < 0 { currentParam = 0 }
            currentParam = min(currentParam * 10 + Int(b - 0x30), 9999)
        case 0x3B: // ';'
            params.append(currentParam)
            currentParam = -1
        case 0x3C...0x3F: // private marker (only at the very start)
            if params.isEmpty && currentParam < 0 && privateMarker == nil {
                privateMarker = b
            }
        case 0x20...0x2F:
            intermediates.append(b)
        case 0x40...0x7E:
            // Final byte → dispatch
            params.append(currentParam)
            delegate?.vtParser(
                self,
                didEmitCSI: params,
                intermediates: intermediates,
                finalByte: b,
                privateMarker: privateMarker
            )
            state = .ground
        case 0x1B:
            enterEscape()
        default:
            break
        }
    }

    private func oscByte(_ b: UInt8) {
        switch b {
        case 0x07: // BEL terminates OSC
            dispatchOSC()
            state = .ground
        case 0x1B:
            state = .oscEsc
        default:
            oscBytes.append(b)
        }
    }

    private func oscEscByte(_ b: UInt8) {
        if b == 0x5C { // ST = ESC '\\'
            dispatchOSC()
            state = .ground
        } else {
            // ST가 아니면 OSC 취소
            oscBytes.removeAll()
            state = .ground
        }
    }

    private func dispatchOSC() {
        let s = String(bytes: oscBytes, encoding: .utf8) ?? ""
        oscBytes.removeAll()
        let parts = s.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        delegate?.vtParser(self, didEmitOSC: parts)
    }

    private func flushText() {
        guard !textBytes.isEmpty else { return }
        // UTF-8 partial-safe: 가장 긴 유효 prefix만 방출, 나머지는 보류.
        let maxTrail = min(3, textBytes.count)
        for trail in 0...maxTrail {
            let len = textBytes.count - trail
            if len == 0 { return }
            if let s = String(bytes: textBytes.prefix(len), encoding: .utf8) {
                delegate?.vtParser(self, didEmitText: s)
                textBytes.removeFirst(len)
                return
            }
        }
        // 어떤 prefix도 디코드 안 됨 — 한 바이트 버리고 다음 호출
        textBytes.removeFirst()
    }
}
