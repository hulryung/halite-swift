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
public final class HaliteSurfaceView: NSView, NSTextInputClient {
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
    /// 마지막 렌더 시점의 marked text. grid 변화 없이 marked text만 비워질 때
    /// (BS-cancel 등) 강제 재렌더링하기 위한 비교용.
    private var lastRenderedMarkedText: String = ""
    /// 캐시된 cell metrics. `reportSizeIfChanged`가 갱신, render가 paragraph style에 사용.
    private var cellMetrics: (width: CGFloat, height: CGFloat) = (1, 1)

    /// IME 조합 중인 텍스트. 비어있지 않으면 cursor 자리에 시각적 overlay.
    /// 실제 PTY 전송은 `insertText`(commit)이 올 때만 일어남.
    private var markedText: String = ""

    /// 현재 처리 중인 `NSEvent`. `keyDown`이 set, IME 콜백(setMarkedText/insertText)에서
    /// "이 commit/preedit을 일으킨 키가 무엇인가" 판단에 사용. BS-cancel spurious commit 감지용.
    private var currentKeyEvent: NSEvent?

    /// 이 keyDown 사이클의 doCommand(deleteBackward:)를 1회 swallow. BS-cancel 처리 시,
    /// IME 콜백이 이미 marked text를 비웠고 PTY에 BS를 또 보내면 안 될 때 use.
    private var swallowNextDeleteCommand: Bool = false

    /// startup IME warmup 진행 중 플래그. `.app` 등록만으로는 TSM↔IMK 첫 IPC 핸드셰이크가
    /// 사용자의 첫 keystroke 시점에야 일어나서 첫 자모가 leak되는 잔존 race가 있음.
    /// view가 first responder가 되자마자 합성 dummy event를 inputContext로 흘려서
    /// IPC를 미리 wake up 시킨다. 그동안 콜백되는 insertText/doCommand는 PTY로 안 보냄.
    private var isWarmingUpIME: Bool = false
    private var didWarmupIME: Bool = false

    /// Selection state. 좌표는 (textViewRow, col) — textViewRow는 `scrollback.count + viewportRow`.
    /// `anchor`는 mouseDown 위치, `head`는 mouseDragged 따라가는 끝점.
    private var selectionAnchor: (row: Int, col: Int)?
    private var selectionHead: (row: Int, col: Int)?

    public init(session: HaliteSession) {
        self.session = session

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        // Big Sur+ NSScrollView가 system chrome(타이틀바 등)에 맞춰 자동으로
        // contentInsets를 추가하는데, 우리 터미널은 cell-grid 정렬이라 이 inset이
        // 들어가면 leftmost / topmost column이 일부 가려짐. 명시적으로 끔.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

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

        // textView 너비를 scrollView의 가시 영역에 묶고, wrap 없이 초과분은 clip.
        // 트랙패드 좌우 스와이프로 빈 공간이 드러나는 문제 방지.
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        // 기본 5pt의 line fragment padding을 제거. 이게 있으면 모든 줄의 시작이
        // textContainerInset 너머로 추가 5pt 들여 써져서 cell 정렬과 어긋남.
        tv.textContainer?.lineFragmentPadding = 0

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

    /// NSTextView가 실제 layout에서 사용하는 1줄 높이를 측정. `defaultLineHeight`보다
    /// 정확함 (typesetter / leading 등의 미세 차이까지 반영).
    private func measuredLineHeight(font: NSFont) -> CGFloat {
        let lm = NSLayoutManager()
        let storage = NSTextStorage(string: "M\nM\nM", attributes: [.font: font])
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 10000, height: 10000))
        lm.addTextContainer(container)
        lm.ensureLayout(for: container)
        let height = lm.usedRect(for: container).height
        return height / 3.0
    }

    private func reportSizeIfChanged() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let font = textView.font ?? NSFont.userFixedPitchFont(ofSize: session.config.fontSize)
            ?? NSFont.systemFont(ofSize: session.config.fontSize)
        let glyphSize = ("M" as NSString).size(withAttributes: [.font: font])
        let cellW = max(glyphSize.width, 1)
        // NSLayoutManager().defaultLineHeight는 NSTextView가 실제 쓰는 line height와
        // 미세하게 다른 경우가 있어 rows가 over-report됨. 실제 layout 결과로 측정.
        let cellH = max(measuredLineHeight(font: font), 1)
        cellMetrics = (cellW, cellH)
        let inset = textView.textContainerInset
        // width: bounds.width 대신 scrollView.contentSize.width — vertical scroller가
        // 항상 보이는 시스템 설정에서 ~15pt 차지하기 때문.
        // height: 가로 스크롤바는 없으니 bounds.height 그대로 사용.
        let usableW = max(scrollView.contentSize.width - inset.width * 2, 1)
        let usableH = max(bounds.height - inset.height * 2, 1)
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
        guard let window = window else { return }
        window.makeFirstResponder(self)
        inputContext?.activate()
        warmupIMEIfNeeded()
    }

    /// 사용자가 첫 키를 누르기 전에 TSM↔IMK IPC 핸드셰이크를 강제로 트리거.
    /// `.app` 등록만으로는 launch 후 첫 자모가 leak되는 잔존 race가 남아있는 환경 대응.
    private func warmupIMEIfNeeded() {
        guard !didWarmupIME else { return }
        didWarmupIME = true
        guard let window = window else { return }

        // 다음 runloop tick에 실행 — window가 fully key 된 다음에 IMK가 받도록.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            ) else { return }
            self.isWarmingUpIME = true
            self.inputContext?.handleEvent(event)
            self.isWarmingUpIME = false
        }
    }

    public override func mouseDown(with event: NSEvent) {
        // 클릭으로 키 입력 되찾기 (혹시 다른 곳에 first responder가 가있을 때 대비)
        window?.makeFirstResponder(self)

        // 선택 시작.
        let point = convertEventToCell(event)
        selectionAnchor = point
        selectionHead = point
        scheduleRender()
    }

    public override func mouseDragged(with event: NSEvent) {
        guard selectionAnchor != nil else { return }
        selectionHead = convertEventToCell(event)
        scheduleRender()
    }

    public override func mouseUp(with event: NSEvent) {
        // anchor == head 이면 (그냥 클릭이면) 선택 클리어.
        if let a = selectionAnchor, let h = selectionHead, a == h {
            selectionAnchor = nil
            selectionHead = nil
            scheduleRender()
        }
    }

    /// `event.locationInWindow`를 textView 콘텐츠 좌표계의 (row, col)로 변환.
    /// row는 scrollback과 viewport 통합 인덱스 (= `scrollback.count + viewportRow`).
    private func convertEventToCell(_ event: NSEvent) -> (row: Int, col: Int) {
        let pInView = convert(event.locationInWindow, from: nil)
        let pInTextView = textView.convert(pInView, from: self)
        let inset = textView.textContainerInset
        let cellW = max(cellMetrics.width, 1)
        let cellH = max(cellMetrics.height, 1)
        let row = max(0, Int(floor((pInTextView.y - inset.height) / cellH)))
        let col = max(0, Int(floor((pInTextView.x - inset.width) / cellW)))
        let maxRow = session.grid.scrollback.count + session.grid.rows - 1
        let maxCol = session.grid.cols
        return (min(row, maxRow), min(col, maxCol))
    }

    /// anchor/head를 row-major 순으로 정규화한 (start, end). end는 exclusive.
    private func normalizedSelection() -> (start: (row: Int, col: Int), end: (row: Int, col: Int))? {
        guard let a = selectionAnchor, let h = selectionHead else { return nil }
        if a.row == h.row && a.col == h.col { return nil }
        if a.row < h.row || (a.row == h.row && a.col < h.col) {
            return (a, h)
        }
        return (h, a)
    }

    /// 주어진 textViewRow에서 선택된 col 범위 (있으면). end exclusive.
    private func selectedColumnsForRow(_ textViewRow: Int, cols: Int) -> Range<Int>? {
        guard let (start, end) = normalizedSelection() else { return nil }
        if textViewRow < start.row || textViewRow > end.row { return nil }
        let lo: Int
        let hi: Int
        if textViewRow == start.row && textViewRow == end.row {
            lo = start.col
            hi = min(end.col, cols)
        } else if textViewRow == start.row {
            lo = start.col
            hi = cols
        } else if textViewRow == end.row {
            lo = 0
            hi = min(end.col, cols)
        } else {
            lo = 0
            hi = cols
        }
        guard lo < hi else { return nil }
        return lo..<hi
    }

    private func selectionKey() -> String {
        guard let a = selectionAnchor, let h = selectionHead else { return "" }
        return "\(a.row),\(a.col)-\(h.row),\(h.col)"
    }

    private func clearSelectionIfNeeded() {
        guard selectionAnchor != nil else { return }
        selectionAnchor = nil
        selectionHead = nil
        scheduleRender()
    }

    private func selectedText() -> String? {
        guard let (start, end) = normalizedSelection() else { return nil }
        let grid = session.grid
        let scrollbackCount = grid.scrollback.count
        var lines: [String] = []
        for r in start.row...end.row {
            let cells: [Cell]
            if r < scrollbackCount {
                cells = grid.scrollback[r]
            } else {
                let vp = r - scrollbackCount
                if vp >= grid.rows { break }
                cells = grid.row(vp)
            }
            guard let range = selectedColumnsForRow(r, cols: cells.count) else { continue }
            var chars = ""
            for c in range {
                guard c < cells.count else { break }
                if cells[c].isContinuation { continue }
                chars.append(cells[c].char)
            }
            while chars.last == " " { chars.removeLast() }
            lines.append(chars)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Edit > Copy / Cmd+C가 보내는 셀렉터. 선택 텍스트를 pasteboard에 push.
    @objc public func copy(_ sender: Any?) {
        guard let text = selectedText() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Edit > Paste / Cmd+V. clipboard 텍스트를 PTY로. bracketed paste 모드면 wrap.
    @objc public func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        var data = Data()
        if session.bracketedPasteEnabled {
            data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]) // ESC[200~
        }
        if let utf8 = text.data(using: .utf8) {
            data.append(utf8)
        }
        if session.bracketedPasteEnabled {
            data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]) // ESC[201~
        }
        session.write(data)
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

    // MARK: - Input (IME-aware)

    public override func keyDown(with event: NSEvent) {
        // 새 keyDown 사이클 시작 — IME 콜백들이 참조할 컨텍스트 set.
        currentKeyEvent = event
        swallowNextDeleteCommand = false
        defer { currentKeyEvent = nil }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd는 performKeyEquivalent에서 처리. 여기에 도달했다는 건 어떤 메뉴/단축키도
        // 안 잡았다는 뜻이고, IME에 보내거나 PTY로 보내면 의도와 다른 동작이 생김 → 무시.
        if mods.contains(.command) {
            return
        }

        // 사용자 키 입력이 들어오면 selection 클리어 (터미널 관습).
        clearSelectionIfNeeded()

        // Ctrl+letter (다른 modifier 없이) → terminal control byte. IME 우회.
        // Shift+Ctrl도 같은 group (e.g. Ctrl+Shift+C → Ctrl+C와 동일 바이트 → 0x03).
        if mods.subtracting(.shift) == .control,
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let scalar = chars.unicodeScalars.first?.value,
           (0x41...0x5A).contains(scalar) || (0x61...0x7A).contains(scalar) {
            let lower = scalar | 0x20
            session.write(Data([UInt8(lower - 0x60)]))
            return
        }

        // 나머지: NSTextInputContext로 보냄. 한글/일어/중어 IME composition,
        // 평문 입력, Enter/Tab/화살표 (doCommand 경로), Backspace (doCommand) 등을
        // 일관되게 처리.
        inputContext?.handleEvent(event)
    }

    public override func doCommand(by selector: Selector) {
        if isWarmingUpIME {
            return
        }
        // AppKit selector → terminal escape byte 시퀀스. NSTextInputClient의 핵심 contract:
        // IME가 처리하지 않은 키, 또는 IME가 commit하고 추가로 처리해야 할 키들이
        // 여기로 dispatched 됨.
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            session.write(Data([0x0D])) // CR
        case #selector(NSResponder.insertTab(_:)):
            session.write(Data([0x09]))
        case #selector(NSResponder.insertBacktab(_:)):
            session.write(Data([0x1B, 0x5B, 0x5A])) // CSI Z
        case #selector(NSResponder.deleteBackward(_:)):
            // BS-cancel spurious commit이 이미 IME 콜백에서 처리됐다면 PTY로는 BS 안 보냄.
            if swallowNextDeleteCommand {
                swallowNextDeleteCommand = false
                return
            }
            session.write(Data([0x7F])) // DEL (대부분의 셸이 erase에 mapping)
        case #selector(NSResponder.deleteForward(_:)):
            session.write(Data([0x1B, 0x5B, 0x33, 0x7E])) // CSI 3 ~
        case #selector(NSResponder.cancelOperation(_:)):
            session.write(Data([0x1B])) // ESC
        case #selector(NSResponder.moveUp(_:)),
             #selector(NSResponder.moveUpAndModifySelection(_:)):
            session.write(Data([0x1B, 0x5B, 0x41]))
        case #selector(NSResponder.moveDown(_:)),
             #selector(NSResponder.moveDownAndModifySelection(_:)):
            session.write(Data([0x1B, 0x5B, 0x42]))
        case #selector(NSResponder.moveLeft(_:)),
             #selector(NSResponder.moveLeftAndModifySelection(_:)):
            session.write(Data([0x1B, 0x5B, 0x44]))
        case #selector(NSResponder.moveRight(_:)),
             #selector(NSResponder.moveRightAndModifySelection(_:)):
            session.write(Data([0x1B, 0x5B, 0x43]))
        case #selector(NSResponder.scrollPageUp(_:)),
             #selector(NSResponder.pageUp(_:)):
            session.write(Data([0x1B, 0x5B, 0x35, 0x7E])) // PageUp
        case #selector(NSResponder.scrollPageDown(_:)),
             #selector(NSResponder.pageDown(_:)):
            session.write(Data([0x1B, 0x5B, 0x36, 0x7E])) // PageDown
        case #selector(NSResponder.moveToBeginningOfLine(_:)):
            session.write(Data([0x1B, 0x5B, 0x48])) // Home
        case #selector(NSResponder.moveToEndOfLine(_:)):
            session.write(Data([0x1B, 0x5B, 0x46])) // End
        default:
            break // 알 수 없는 command — 무시
        }
    }

    // MARK: - NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.unwrapString(string)

        // startup warmup 중에는 콜백된 텍스트를 PTY로 보내지 않는다.
        if isWarmingUpIME {
            return
        }

        // BS-cancel spurious commit 감지.
        // macOS Hangul IME가 마지막 자모를 BS로 취소할 때, 같은 자모를 insertText로
        // emit하는 버그가 있음. 트리거 키가 BS이고 markedText와 동일한 글자가 commit
        // 되려 하면 spurious로 판단하고 drop. 동일 keyDown 사이클의 doCommand
        // (deleteBackward:)도 swallow.
        if let event = currentKeyEvent,
           event.keyCode == 51,
           !markedText.isEmpty,
           text == markedText {
            markedText = ""
            swallowNextDeleteCommand = true
            scheduleRender()
            return
        }

        // 알려진 한계: 한영키 직후 첫 자모는 setMarkedText를 거치지 않고 직접 insertText로
        // 들어옴 (raw binary 실행 시 TSM↔IMK IPC가 첫 keystroke 도착 전에 set up 안 됨).
        // 해법은 `.app` bundle 등록 (halite Rust 문서 참조). state machine 트릭은 IMK 내부
        // 상태와 어긋나서 lossy. 현재는 그대로 PTY로 commit — 사용자가 BS+재입력으로 복원 가능.

        // 일반 commit: marked text 비우고 PTY로.
        if !markedText.isEmpty {
            markedText = ""
            scheduleRender()
        }
        guard !text.isEmpty, let data = text.data(using: .utf8) else { return }
        session.write(data)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = Self.unwrapString(string)
        if markedText != text {
            markedText = text
            scheduleRender()
        }
    }

    public func unmarkText() {
        if !markedText.isEmpty {
            markedText = ""
            scheduleRender()
        }
    }

    public func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    public func markedRange() -> NSRange {
        if markedText.isEmpty {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: markedText.utf16.count)
    }

    public func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    /// IME 후보창이 뜰 위치 — cursor 셀의 화면 좌표 반환.
    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        guard let window = window else { return .zero }
        let grid = session.grid
        let cellW = cellMetrics.width
        let cellH = cellMetrics.height
        let inset = textView.textContainerInset

        // textView 좌표계에서 cursor 셀의 origin
        let rowInTextView = grid.scrollback.count + grid.cursorRow
        let cellOrigin = CGPoint(
            x: inset.width + CGFloat(grid.cursorCol) * cellW,
            y: inset.height + CGFloat(rowInTextView) * cellH
        )
        let cellRectInTextView = NSRect(origin: cellOrigin, size: NSSize(width: cellW, height: cellH))

        // textView → window → screen
        let cellRectInWindow = textView.convert(cellRectInTextView, to: nil)
        return window.convertToScreen(cellRectInWindow)
    }

    private static func unwrapString(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let attr = value as? NSAttributedString { return attr.string }
        return ""
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

    private var lastRenderedSelectionKey: String = ""

    private func renderNow() {
        let grid = session.grid
        // selection state도 render에 영향을 주므로 같이 본다.
        let selKey = selectionKey()
        if grid.version == lastRenderedVersion
            && markedText == lastRenderedMarkedText
            && selKey == lastRenderedSelectionKey {
            return
        }
        lastRenderedVersion = grid.version
        lastRenderedMarkedText = markedText
        lastRenderedSelectionKey = selKey

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

        let scrollbackCount = grid.scrollback.count

        // Scrollback (오래된 → 최근). cursor는 안 그림.
        for (i, line) in grid.scrollback.enumerated() {
            let sel = selectedColumnsForRow(i, cols: line.count)
            appendLine(
                line, cols: line.count, cursorCol: nil, selectedCols: sel,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
            result.append(NSAttributedString(string: "\n"))
        }

        // 현재 viewport. 커서가 있는 줄에서만 cursorCol 전달.
        let cursorRow = grid.cursorVisible ? grid.cursorRow : -1
        let mt = markedText
        for r in 0..<grid.rows {
            let textViewRow = scrollbackCount + r
            let sel = selectedColumnsForRow(textViewRow, cols: grid.cols)
            if r == cursorRow && !mt.isEmpty {
                // 조합 중 텍스트가 있으면 cursor 자리에 overlay
                appendCursorRowWithMarkedText(
                    grid.row(r),
                    cols: grid.cols,
                    cursorCol: grid.cursorCol,
                    markedText: mt,
                    baseFont: baseFont,
                    paragraphStyle: paragraphStyle,
                    into: result
                )
            } else {
                let cc: Int? = (r == cursorRow) ? grid.cursorCol : nil
                appendLine(
                    grid.row(r), cols: grid.cols, cursorCol: cc, selectedCols: sel,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
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
            // NSTextView는 setAttributedString 직후에도 frame.height 갱신이 비동기적
            // 일 수 있어서, 그대로 docHeight 읽으면 stale 값으로 yMax가 부족해짐
            // → 화면 바닥이 가려진 채 그 다음 keystroke의 render에서야 따라잡힘.
            // ensureLayout으로 강제 동기 layout 후 frame.height 읽음.
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            let docHeight = textView.frame.height
            let visHeight = scrollView.contentView.bounds.height
            let yMax = max(0, docHeight - visHeight)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: yMax))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// 한 줄(Cell 배열)을 run-length attribute 그룹으로 묶어서 attributed string에 append.
    /// `cursorCol`이 주어지면 그 위치의 한 셀은 단독으로 inverse 처리해서 그림.
    /// `selectedCols`가 주어지면 해당 범위의 셀들은 selection background로 칠함.
    private func appendLine(
        _ line: [Cell],
        cols: Int,
        cursorCol: Int?,
        selectedCols: Range<Int>?,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        guard cols > 0 else { return }
        let cc = cursorCol ?? -1
        if cc >= 0 && cc < cols {
            if cc > 0 {
                appendRunGroup(
                    line, range: 0..<cc, selectedCols: selectedCols,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
            var inverseCell = line[cc]
            inverseCell.attrs.inverse.toggle()
            let cursorSelected = selectedCols?.contains(cc) ?? false
            let cursorIsWide = (cc + 1 < cols && line[cc + 1].isContinuation)
            if cursorIsWide {
                appendWideCell(
                    inverseCell,
                    isSelected: cursorSelected,
                    baseFont: baseFont,
                    paragraphStyle: paragraphStyle,
                    into: result
                )
            } else {
                let nsAttrs = makeAttributes(
                    for: inverseCell.attrs, baseFont: baseFont,
                    paragraphStyle: paragraphStyle,
                    isSelected: cursorSelected, hyperlink: inverseCell.hyperlink
                )
                result.append(NSAttributedString(string: String(inverseCell.char), attributes: nsAttrs))
            }
            if cc + 1 < cols {
                appendRunGroup(
                    line, range: (cc + 1)..<cols, selectedCols: selectedCols,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
        } else {
            appendRunGroup(
                line, range: 0..<cols, selectedCols: selectedCols,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }
    }

    /// cursor 자리에 IME 조합 중 텍스트를 시각적 overlay로 그림.
    /// grid 자체는 mutate 안 함 (commit이 오면 PTY echo로 grid 갱신).
    private func appendCursorRowWithMarkedText(
        _ line: [Cell],
        cols: Int,
        cursorCol: Int,
        markedText: String,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        // cursor 이전 셀들 — 평소처럼
        if cursorCol > 0 {
            appendRunGroup(
                line, range: 0..<cursorCol, selectedCols: nil,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }

        // 조합 텍스트 — 진한 파란 배경 + 두꺼운 underline. "조합 중" 명확한 시각 단서.
        // (M11.x에서 config 옵션으로 underline/background/both 선택지 추가 가능)
        let imeAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle,
            .underlineStyle: NSUnderlineStyle.thick.rawValue,
            .backgroundColor: NSColor.systemBlue.withAlphaComponent(0.65),
        ]
        result.append(NSAttributedString(string: markedText, attributes: imeAttrs))

        // 조합 텍스트가 가린 만큼 row의 나머지 셀을 건너뜀.
        // markedText.count로 대략의 cell 폭 산정 (CJK wide는 M5에서 처리).
        let overlayCols = markedText.count
        let afterCol = min(cursorCol + overlayCols, cols)
        if afterCol < cols {
            appendRunGroup(
                line, range: afterCol..<cols, selectedCols: nil,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }
    }

    private func appendRunGroup(
        _ line: [Cell],
        range: Range<Int>,
        selectedCols: Range<Int>?,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        var c = range.lowerBound
        while c < range.upperBound {
            // Continuation cell은 NSAttributedString에 추가하지 않음 —
            // 직전 wide glyph가 두 칸을 자연스럽게 차지함.
            if line[c].isContinuation {
                c += 1
                continue
            }

            // 이 cell이 wide (다음 cell이 continuation)인지 검사.
            // wide cell은 단독 run으로 emit하면서 `.kern`으로 정확히 2*cellW 차지하도록.
            let isWide = (c + 1 < line.count && line[c + 1].isContinuation)
            if isWide {
                let runSelected = selectedCols?.contains(c) ?? false
                appendWideCell(
                    line[c],
                    isSelected: runSelected,
                    baseFont: baseFont,
                    paragraphStyle: paragraphStyle,
                    into: result
                )
                c += 1
                continue
            }

            let runAttrs = line[c].attrs
            let runHyperlink = line[c].hyperlink
            let runSelected = selectedCols?.contains(c) ?? false
            var endC = c + 1
            // 같은 attrs + hyperlink + selection 상태가 이어지는 한 묶음.
            // wide cell은 묶음에 포함시키지 않음 (단독 emit 필요).
            while endC < range.upperBound,
                  !line[endC].isContinuation,
                  !(endC + 1 < line.count && line[endC + 1].isContinuation),
                  line[endC].attrs == runAttrs,
                  line[endC].hyperlink == runHyperlink,
                  (selectedCols?.contains(endC) ?? false) == runSelected {
                endC += 1
            }
            var runChars = ""
            runChars.reserveCapacity(endC - c)
            for i in c..<endC { runChars.append(line[i].char) }
            let nsAttrs = makeAttributes(
                for: runAttrs, baseFont: baseFont,
                paragraphStyle: paragraphStyle,
                isSelected: runSelected, hyperlink: runHyperlink
            )
            result.append(NSAttributedString(string: runChars, attributes: nsAttrs))
            c = endC
        }
    }

    /// Wide cell 한 개를 단독 NSAttributedString run으로 emit + kern으로 2*cellW 강제.
    private func appendWideCell(
        _ cell: Cell,
        isSelected: Bool,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        var nsAttrs = makeAttributes(
            for: cell.attrs, baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            isSelected: isSelected, hyperlink: cell.hyperlink
        )
        let font = (nsAttrs[.font] as? NSFont) ?? baseFont
        let char = String(cell.char) as NSString
        let naturalW = char.size(withAttributes: [.font: font]).width
        let targetW = cellMetrics.width * 2
        let kern = targetW - naturalW
        if kern > 0.01 {
            nsAttrs[.kern] = kern
        }
        result.append(NSAttributedString(string: String(cell.char), attributes: nsAttrs))
    }

    private func makeAttributes(
        for cellAttrs: CellAttrs,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        isSelected: Bool = false,
        hyperlink: String? = nil
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
        if isSelected {
            attrs[.backgroundColor] = NSColor.selectedTextBackgroundColor
        } else if let bg = bg {
            attrs[.backgroundColor] = bg
        }
        if cellAttrs.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        // OSC 8 hyperlink — underline + 약간 옅은 색으로 시각 단서. (클릭 핸들링은 후속.)
        if let uri = hyperlink, let url = URL(string: uri) {
            attrs[.link] = url
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = fg.withAlphaComponent(0.5)
        }
        return attrs
    }
}
