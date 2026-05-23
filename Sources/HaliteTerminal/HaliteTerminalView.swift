import AppKit
import Combine
import SwiftUI

/// SwiftUI에서 한 줄로 끼울 수 있는 진입점.
/// cmux/halite.app 양쪽에서 동일 API.
public struct HaliteTerminalView: NSViewRepresentable {
    public let session: HaliteSession
    public var isActive: Bool
    public var onFocus: (() -> Void)?

    public init(
        session: HaliteSession,
        isActive: Bool = true,
        onFocus: (() -> Void)? = nil
    ) {
        self.session = session
        self.isActive = isActive
        self.onFocus = onFocus
    }

    public func makeNSView(context: Context) -> HaliteSurfaceView {
        let view = HaliteSurfaceView(session: session)
        view.onFocus = onFocus
        return view
    }

    public func updateNSView(_ nsView: HaliteSurfaceView, context: Context) {
        nsView.isActive = isActive
        nsView.onFocus = onFocus
    }
}

/// M1 placeholder: 자식 `NSTextView`에 PTY 출력을 누적해서 보여주고,
/// 키 이벤트는 이쪽에서 잡아 `session.write(_:)`로 전달.
/// M4 이후 `CAMetalLayer` + 자체 렌더러로 교체.
public final class HaliteSurfaceView: NSView {
    public let session: HaliteSession

    public var isActive: Bool = true {
        didSet { needsDisplay = true }
    }

    public var onFocus: (() -> Void)?

    private let scrollView: NSScrollView
    private let textView: NSTextView
    private var outputSubscription: AnyCancellable?

    public init(session: HaliteSession) {
        self.session = session

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false

        let tv = NSTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = false
        tv.font = NSFont.userFixedPitchFont(ofSize: session.config.fontSize)
        tv.textColor = session.config.foregroundColor
        tv.backgroundColor = session.config.backgroundColor
        tv.drawsBackground = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 4, height: 4)

        scroll.documentView = tv

        self.scrollView = scroll
        self.textView = tv

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = session.config.backgroundColor.cgColor

        addSubview(scroll)
        scroll.frame = bounds

        // PTY 출력을 textView에 append.
        outputSubscription = session.$rawOutput
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.applyRawOutput(text)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    // MARK: - Input

    public override func keyDown(with event: NSEvent) {
        guard let bytes = ptyBytes(for: event) else {
            super.keyDown(with: event)
            return
        }
        session.write(bytes)
    }

    /// M1 한정: 흔한 키들만 처리. 실제 키 매핑은 M2+에서 VT 규격대로.
    private func ptyBytes(for event: NSEvent) -> Data? {
        let modifiers = event.modifierFlags

        // Cmd 단축키는 PTY로 안 보냄 (호스트가 처리)
        if modifiers.contains(.command) { return nil }

        // 특수 키
        if let chars = event.charactersIgnoringModifiers, chars.count == 1 {
            switch chars.unicodeScalars.first?.value {
            case 0xF700: return Data([0x1B, 0x5B, 0x41]) // Up
            case 0xF701: return Data([0x1B, 0x5B, 0x42]) // Down
            case 0xF702: return Data([0x1B, 0x5B, 0x44]) // Left
            case 0xF703: return Data([0x1B, 0x5B, 0x43]) // Right
            case 0x7F: return Data([0x7F])               // Backspace → DEL
            case 0x1B: return Data([0x1B])               // Esc
            case 0x0D: return Data([0x0D])               // Return → CR
            case 0x09: return Data([0x09])               // Tab
            default: break
            }
        }

        // Ctrl + 알파벳
        if modifiers.contains(.control), let chars = event.charactersIgnoringModifiers, chars.count == 1 {
            if let scalar = chars.unicodeScalars.first?.value,
               (0x61...0x7A).contains(scalar) || (0x41...0x5A).contains(scalar) {
                let lower = scalar | 0x20
                let ctrl = UInt8(lower - 0x60) // a=1, b=2, ...
                return Data([ctrl])
            }
        }

        // 평문
        if let chars = event.characters, !chars.isEmpty {
            return chars.data(using: .utf8)
        }
        return nil
    }

    // MARK: - Output

    /// M1 placeholder: PTY 누적 텍스트를 통째로 textView에 반영.
    /// 비효율적이지만 M1 검증용. M2+에서 Grid 기반 incremental 렌더로 교체.
    private func applyRawOutput(_ text: String) {
        textView.string = sanitizeForDisplay(text)
        textView.scrollToEndOfDocument(nil)
    }

    /// VT 파서가 없으니 화면 표시용으로 흔한 제어 시퀀스를 최소한만 정리.
    /// 이건 M2가 오면 사라질 코드.
    private func sanitizeForDisplay(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            switch scalar.value {
            case 0x1B:
                // ESC + '['  → CSI 시퀀스. 'a-zA-Z' 종결자까지 스킵.
                if let next = iterator.next(), next.value == 0x5B {
                    while let c = iterator.next() {
                        if (0x40...0x7E).contains(c.value) { break }
                    }
                }
                // ESC + ']' → OSC 시퀀스. BEL(0x07) 또는 ST(ESC \) 까지 스킵.
                else {
                    // 단일 ESC 또는 다른 escape는 그냥 버림
                }
            case 0x07: // BEL — 무시
                continue
            case 0x08: // BS — 마지막 글자 제거
                if !result.isEmpty { result.removeLast() }
            case 0x0D: // CR — M1은 LF만 사용 (다음 LF가 받쳐줌)
                continue
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
