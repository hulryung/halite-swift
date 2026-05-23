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

/// 내부 표시용 NSTextView. first responder도 mouse hit도 거부.
private final class PassiveTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func becomeFirstResponder() -> Bool { false }
}

/// M3 placeholder: 자식 `NSTextView`에 Grid 스냅샷을 그대로 투영.
/// 한 번에 textStorage 전체를 갈아끼움 (run-length attrs 그룹핑).
/// 키 이벤트는 이쪽에서 잡아 `session.write(_:)`로 전달.
/// M4 이후 `CAMetalLayer` + 자체 렌더러로 교체.
public final class HaliteSurfaceView: NSView {
    public let session: HaliteSession

    public var isActive: Bool = true {
        didSet { needsDisplay = true }
    }

    public var onFocus: (() -> Void)?

    private let scrollView: NSScrollView
    private let textView: PassiveTextView
    private var gridSubscription: AnyCancellable?
    private var lastReportedSize: (cols: Int, rows: Int)? = nil
    private var renderScheduled = false
    private var lastRenderedVersion: UInt64 = .max

    public init(session: HaliteSession) {
        self.session = session

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false

        let tv = PassiveTextView(frame: .zero)
        tv.isEditable = false
        tv.isSelectable = false
        tv.isRichText = true
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

        gridSubscription = session.gridChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.scheduleRender()
            }

        // 초기 1회 렌더.
        scheduleRender()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        reportSizeIfChanged()
    }

    private func reportSizeIfChanged() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let font = textView.font ?? NSFont.userFixedPitchFont(ofSize: session.config.fontSize)
            ?? NSFont.systemFont(ofSize: session.config.fontSize)
        let glyphSize = ("M" as NSString).size(withAttributes: [.font: font])
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let cellW = max(glyphSize.width, 1)
        let cellH = max(lineHeight, 1)
        let inset = textView.textContainerInset
        let usableW = bounds.width - inset.width * 2
        let usableH = bounds.height - inset.height * 2
        let cols = max(Int(floor(usableW / cellW)), 1)
        let rows = max(Int(floor(usableH / cellH)), 1)
        if lastReportedSize?.cols == cols && lastReportedSize?.rows == rows {
            return
        }
        lastReportedSize = (cols, rows)
        session.resize(cols: cols, rows: rows)
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self = self, let window = window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "q":
            NSApp.terminate(nil)
            return true
        case "w":
            window?.performClose(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Input

    public override func keyDown(with event: NSEvent) {
        guard let bytes = ptyBytes(for: event) else {
            super.keyDown(with: event)
            return
        }
        session.write(bytes)
    }

    private func ptyBytes(for event: NSEvent) -> Data? {
        let modifiers = event.modifierFlags
        if modifiers.contains(.command) { return nil }

        if let chars = event.charactersIgnoringModifiers, chars.count == 1 {
            switch chars.unicodeScalars.first?.value {
            case 0xF700: return Data([0x1B, 0x5B, 0x41]) // Up
            case 0xF701: return Data([0x1B, 0x5B, 0x42]) // Down
            case 0xF702: return Data([0x1B, 0x5B, 0x44]) // Left
            case 0xF703: return Data([0x1B, 0x5B, 0x43]) // Right
            case 0x7F: return Data([0x7F])
            case 0x1B: return Data([0x1B])
            case 0x0D: return Data([0x0D])
            case 0x09: return Data([0x09])
            default: break
            }
        }

        if modifiers.contains(.control), let chars = event.charactersIgnoringModifiers, chars.count == 1 {
            if let scalar = chars.unicodeScalars.first?.value,
               (0x61...0x7A).contains(scalar) || (0x41...0x5A).contains(scalar) {
                let lower = scalar | 0x20
                let ctrl = UInt8(lower - 0x60)
                return Data([ctrl])
            }
        }

        if let chars = event.characters, !chars.isEmpty {
            return chars.data(using: .utf8)
        }
        return nil
    }

    // MARK: - Render

    /// 여러 grid mutation을 한 runloop tick의 한 번의 renderNow 호출로 합침.
    private func scheduleRender() {
        if renderScheduled { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.renderNow()
        }
    }

    private func renderNow() {
        let grid = session.grid
        if grid.version == lastRenderedVersion { return }
        lastRenderedVersion = grid.version

        guard let storage = textView.textStorage else { return }
        let baseFont = textView.font
            ?? NSFont.userFixedPitchFont(ofSize: session.config.fontSize)
            ?? NSFont.systemFont(ofSize: session.config.fontSize)

        let result = NSMutableAttributedString()
        result.beginEditing()

        for r in 0..<grid.rows {
            let row = grid.row(r)
            var c = 0
            while c < grid.cols {
                let runAttrs = row[c].attrs
                var endC = c + 1
                while endC < grid.cols && row[endC].attrs == runAttrs {
                    endC += 1
                }
                var runChars = ""
                runChars.reserveCapacity(endC - c)
                for i in c..<endC { runChars.append(row[i].char) }
                let nsAttrs = makeAttributes(for: runAttrs, baseFont: baseFont)
                result.append(NSAttributedString(string: runChars, attributes: nsAttrs))
                c = endC
            }
            if r < grid.rows - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        result.endEditing()

        storage.beginEditing()
        storage.setAttributedString(result)
        storage.endEditing()
    }

    private func makeAttributes(
        for cellAttrs: CellAttrs,
        baseFont: NSFont
    ) -> [NSAttributedString.Key: Any] {
        let (fg, bg) = cellAttrs.resolvedColors(defaultBG: session.config.backgroundColor)
        let font: NSFont
        if cellAttrs.bold {
            font = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        } else {
            font = baseFont
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
        ]
        if let bg = bg {
            attrs[.backgroundColor] = bg
        }
        if cellAttrs.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }
}
