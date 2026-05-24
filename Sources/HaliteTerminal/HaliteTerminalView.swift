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
    /// 캐시된 cell metrics. `reportSizeIfChanged`가 갱신, render가 paragraph style에 사용.
    private var cellMetrics: (width: CGFloat, height: CGFloat) = (1, 1)

    public init(session: HaliteSession) {
        self.session = session

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
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

        // 줄 자동 wrap을 끔. 셀 단위 격자에서는 wrap이 시각 라인 수를 늘려
        // scrollToEnd가 위쪽을 잘라낸 화면을 보여주는 원인이 됨.
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

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
        cellMetrics = (cellW, cellH)
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
        let priorWasAlt = (lastRenderedVersion != .max) && grid.isAltScreenActive
        _ = priorWasAlt
        lastRenderedVersion = grid.version

        guard let storage = textView.textStorage else { return }
        let baseFont = textView.font
            ?? NSFont.userFixedPitchFont(ofSize: session.config.fontSize)
            ?? NSFont.systemFont(ofSize: session.config.fontSize)

        // 줄 높이를 정확히 cellH로 강제 (NSTextView 기본 spacing이 우리 cellH와
        // 어긋나면 전체 컨텐츠가 viewport보다 커져 scroll이 발생).
        let lineHeight = max(cellMetrics.height, 1)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.lineSpacing = 0
        paragraphStyle.lineBreakMode = .byClipping

        let result = NSMutableAttributedString()
        result.beginEditing()

        // Scrollback (오래된 → 최근). cursor는 안 그림.
        for line in grid.scrollback {
            appendLine(
                line, cols: line.count, cursorCol: nil,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
            result.append(NSAttributedString(string: "\n"))
        }

        // 현재 viewport. 커서가 있는 줄에서만 cursorCol 전달.
        let cursorRow = grid.cursorVisible ? grid.cursorRow : -1
        for r in 0..<grid.rows {
            let cc: Int? = (r == cursorRow) ? grid.cursorCol : nil
            appendLine(
                grid.row(r), cols: grid.cols, cursorCol: cc,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
            if r < grid.rows - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
        }
        result.endEditing()

        storage.beginEditing()
        storage.setAttributedString(result)
        storage.endEditing()

        // primary 화면에서만 자동 바닥 스크롤.
        // alt screen에선 buffer 전체가 viewport에 fit 하도록 우리가 크기를
        // 잡아두므로 스크롤 자체가 발생하면 안 되고, 우리가 강제로 호출하면
        // 매 cursor move마다 화면이 튐.
        if !grid.isAltScreenActive {
            textView.scrollToEndOfDocument(nil)
        }
    }

    /// 한 줄(Cell 배열)을 run-length attribute 그룹으로 묶어서 attributed string에 append.
    /// `cursorCol`이 주어지면 그 위치의 한 셀은 단독으로 inverse 처리해서 그림.
    private func appendLine(
        _ line: [Cell],
        cols: Int,
        cursorCol: Int?,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        guard cols > 0 else { return }
        let cc = cursorCol ?? -1
        if cc >= 0 && cc < cols {
            if cc > 0 {
                appendRunGroup(
                    line, range: 0..<cc,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
            var attrs = line[cc].attrs
            attrs.inverse.toggle()
            let nsAttrs = makeAttributes(for: attrs, baseFont: baseFont, paragraphStyle: paragraphStyle)
            result.append(NSAttributedString(string: String(line[cc].char), attributes: nsAttrs))
            if cc + 1 < cols {
                appendRunGroup(
                    line, range: (cc + 1)..<cols,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
        } else {
            appendRunGroup(
                line, range: 0..<cols,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }
    }

    private func appendRunGroup(
        _ line: [Cell],
        range: Range<Int>,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        var c = range.lowerBound
        while c < range.upperBound {
            let runAttrs = line[c].attrs
            var endC = c + 1
            while endC < range.upperBound && line[endC].attrs == runAttrs {
                endC += 1
            }
            var runChars = ""
            runChars.reserveCapacity(endC - c)
            for i in c..<endC { runChars.append(line[i].char) }
            let nsAttrs = makeAttributes(for: runAttrs, baseFont: baseFont, paragraphStyle: paragraphStyle)
            result.append(NSAttributedString(string: runChars, attributes: nsAttrs))
            c = endC
        }
    }

    private func makeAttributes(
        for cellAttrs: CellAttrs,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle
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
            .paragraphStyle: paragraphStyle,
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
