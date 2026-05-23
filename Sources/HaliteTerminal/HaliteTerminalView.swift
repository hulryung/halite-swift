import AppKit
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

/// 실제 NSView. M1에서 CAMetalLayer + 렌더러로 교체될 자리.
/// 지금은 placeholder (검은 배경 + 첫 응답자 등록).
public final class HaliteSurfaceView: NSView {
    public let session: HaliteSession

    public var isActive: Bool = true {
        didSet { needsDisplay = true }
    }

    public var onFocus: (() -> Void)?

    public init(session: HaliteSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = session.config.backgroundColor.cgColor
        // TODO(M1): CAMetalLayer로 교체
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    // TODO(M1): keyDown / scrollWheel / mouse* / NSTextInputClient
}
