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
    private var configSubscription: AnyCancellable?
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

    /// DECSCUSR underline/bar 모양용 cursor overlay.
    /// block 모양은 inverse-cell 렌더링으로 유지 (NSAttributedString 한 번에 처리, 더 contrast 좋음).
    /// underline/bar는 CALayer로 그려서 cell 글자를 가리지 않음.
    private let cursorLayer = CALayer()

    /// 현재 적용된 폰트 zoom multiplier. 1.0이 기본. Cmd+= / Cmd+- / Cmd+0로 변경.
    private var fontSizeMultiplier: CGFloat = 1.0

    /// 활성화된 find 오버레이 + 현재 검색어 + 매치 위치.
    private var findOverlay: FindOverlayView?
    private var findQuery: String = ""
    /// 검색 매치 — `[textViewRow: [colRange...]]`. render 시 highlight 표시용.
    private var findMatchesByRow: [Int: [Range<Int>]] = [:]
    /// 매치들을 textViewRow → col 순으로 정렬한 평탄 리스트. Cmd+G next/prev 네비용.
    private var findMatchesOrdered: [(row: Int, range: Range<Int>)] = []
    /// 현재 활성 매치 인덱스 (Cmd+G로 순회). -1이면 미선택.
    private var activeMatchIndex: Int = -1

    /// Cmd-hover URL 표시 상태. Cmd 누른 채로 URL 위에 마우스를 올렸을 때
    /// 해당 URL을 밝게 underline 표시 + pointing-hand cursor.
    /// 클릭은 Cmd 누른 상태에서만 URL 오픈.
    private var cmdKeyDown: Bool = false
    private var hoveredURL: (row: Int, colRange: Range<Int>, url: URL)?
    private var mouseTrackingArea: NSTrackingArea?

    /// "live output 따라가기" 추적 플래그. 사용자 scroll로 위로 올라가면 false,
    /// 다시 바닥에 닿으면 true. layout() 시점엔 이미 새 frame이 적용된 후라
    /// 그 자리에서 isScrolledToBottom()을 재측정해도 부정확 — 이 플래그를 따로
    /// 유지해야 tab bar 토글로 영역이 바뀔 때 바닥 anchor를 안정적으로 보존.
    private var followingBottom: Bool = true

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
        // 초기 폰트 — config.fontFamily 우선 + cascadeList에 Nerd Font fallback
        // 추가. Menlo 같은 일반 monospace를 선택해도 Powerline 글리프가 ?로 깨지지
        // 않도록.
        tv.font = fontWithNerdFallback(
            family: session.config.fontFamily,
            size: session.config.fontSize
        )
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

        // Cursor overlay layer — underline/bar 모양용. block은 별도 처리.
        cursorLayer.zPosition = 100
        cursorLayer.isHidden = true
        cursorLayer.backgroundColor = session.config.cursorColor.cgColor
        layer?.addSublayer(cursorLayer)

        // 사용자 스크롤 시 cursor 위치 추적 (auto-scroll 외에도 변동될 수 있음).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scroll
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        scroll.contentView.postsBoundsChangedNotifications = true

        gridSubscription = session.gridChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.scheduleRender()
            }

        configSubscription = session.$config
            .dropFirst() // 초기 값은 init 시 이미 반영됨
            .receive(on: RunLoop.main)
            .sink { [weak self] cfg in
                self?.applyConfig(cfg)
            }

        // BEL (\a) — 시각 flash + 시스템 비프. session.onBell이 off-main에서 호출될
        // 수 있으므로 main으로 hop.
        session.onBell = { [weak self] in
            DispatchQueue.main.async { self?.handleBell() }
        }

        // 초기 1회 렌더.
        scheduleRender()
    }

    /// BEL 처리 — 짧은 시각 flash overlay + 시스템 비프.
    private func handleBell() {
        NSSound.beep()
        // 시각 flash: 전체 위에 흰색 반투명 레이어를 잠깐 띄웠다 fade out.
        let flash = CALayer()
        flash.frame = bounds
        flash.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        flash.zPosition = 200
        layer?.addSublayer(flash)
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.0
        anim.duration = 0.18
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flash.add(anim, forKey: "fade")
        // 애니메이션 후 제거.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            flash.removeFromSuperlayer()
        }
    }

    /// Settings 변경 → session.updateConfig → 여기로 들어와서 textView/색상/스크롤백 적용.
    private func applyConfig(_ config: HaliteConfig) {
        let font = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        textView.font = font
        textView.backgroundColor = config.backgroundColor
        // ⚠️ textView.textColor = ... 는 rich-text 모드에서 textStorage 전체의
        // .foregroundColor 어트리뷰트를 flat하게 덮어쓴다 → per-cell SGR 색이
        // 다 흰색으로 사라지는 회귀가 발생함. 우리 render는 per-cell .foregroundColor
        // 를 명시적으로 set 하므로 default textColor를 건드릴 필요 자체가 없음.
        layer?.backgroundColor = config.backgroundColor.cgColor
        lastReportedSize = nil
        // dedupe key 무력화 후 동기 re-render — grid.version 변화 없이도 새 폰트/색이
        // textStorage에 즉시 반영되도록.
        lastRenderedVersion = .max
        needsLayout = true
        renderNow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
        // 라이브 리사이즈 중에도 textView/textContainer가 새 너비로 즉시 re-layout 되도록
        // 강제. 이게 없으면 드래그 중엔 옛 layout이 유지되어 사용자가 보는 화면이
        // 안 갱신되어 보임.
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        reportSizeIfChanged()
        if session.grid.isAltScreenActive || session.grid.hasUsedSyncOutput {
            scrollViewportToAltTop()
        } else if followingBottom {
            scrollViewportToBottom()
        }
        // resize 직후 새 grid 콘텐츠도 즉시 그리기.
        if inLiveResize {
            renderNow()
        }
    }

    private func isScrolledToBottom(tolerance: CGFloat = 2.0) -> Bool {
        let docHeight = textView.frame.height
        let visHeight = scrollView.contentView.bounds.height
        let yMax = max(0, docHeight - visHeight)
        let curY = scrollView.contentView.bounds.origin.y
        return abs(curY - yMax) <= tolerance
    }

    /// Alt-screen 활성 시 — primary scrollback을 건너뛰고 alt viewport top에 anchor.
    /// (alt-screen 진입 시 self.scrollback이 primary의 history를 그대로 갖고 있어서
    ///  안 스크롤하면 textStorage 최상단=primary scrollback이 보이고 alt 콘텐츠는
    ///  그 아래에 그려져 사용자가 위로 스크롤해야 보는 회귀가 있었음.)
    private func scrollViewportToAltTop() {
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        let viewportTop = CGFloat(session.grid.scrollback.count) * cellMetrics.height
            + textView.textContainerInset.height
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: viewportTop))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scrollViewportToBottom() {
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        let visHeight = scrollView.contentView.bounds.height
        // "cursor visible" 정책 — cursor가 가시 영역 밖이면 들어오게만, 안이면 안 건드림.
        // layout(window resize 등)에서 followingBottom 일 때 호출되므로 사용자가 바닥에
        // 머물 의도면 그쪽으로 잡아주되, cursor 위 영역이 살아 있다면 그대로 둠.
        let cursorViewRow = session.grid.scrollback.count + session.grid.cursorRow
        let cursorY = CGFloat(cursorViewRow) * cellMetrics.height
            + textView.textContainerInset.height
        let cursorBottom = cursorY + cellMetrics.height
        let curScroll = scrollView.contentView.bounds.origin.y
        let visTop = curScroll
        let visBottom = curScroll + visHeight
        if cursorBottom > visBottom {
            let targetY = cursorBottom - visHeight
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        } else if cursorY < visTop {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: cursorY))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
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

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // 라이브 리사이즈 종료 후 최종 사이즈 보고 (안전망 — 일반적으로 layout()이
        // 이미 처리하지만 마지막 frame이 layout 호출 없이 결정되는 케이스를 위해).
        reportSizeIfChanged()
    }

    private func reportSizeIfChanged() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // 매 layout마다 즉시 SIGWINCH fire — 드래그 중에도 셸/TUI가 실시간으로
        // redraw해서 사용자가 보는 화면도 실시간 갱신됨.
        //
        // (debounce/throttle 시도했으나: debounce는 연속 드래그가 timer를 reset해서
        //  드래그가 끝날 때까지 한 번도 fire 안 됨. 일반 셸의 prompt 누적은 SIGWINCH
        //  자체의 표준 동작이고, TUI 세션은 inSyncOutputMode로 scrollback 누적이 막혀
        //  있어 잔재 회귀 없음.)
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
        let usableW = max(scrollView.contentSize.width - inset.width * 2, 1)

        // height: bounds.height는 macOS 네이티브 탭 바 출현/사라짐(2탭↔1탭 토글)에
        // 따라 ~36pt가 들락날락한다. window.contentRect도 마찬가지로 변함 (윈도우
        // 자체가 탭바 만큼 작아지는 macOS 동작). 그대로 rows로 환산하면 매 토글마다
        // SIGWINCH가 셸에 전달되어 prompt가 다시 그려져 누적됨.
        //
        // stable rows를 위해 탭바 가시 여부에 따라 조건부 보정:
        //   탭바 hidden (1 tab):  contentRect - tabBarReservation
        //   탭바 visible (2+ tabs): contentRect 그대로
        // 결과: 두 상태 모두 동일한 effective height → rows count 일정.
        let isTabBarVisible = (window?.tabbedWindows?.count ?? 1) >= 2
        let stableContentHeight: CGFloat
        if let w = window {
            let cr = w.contentRect(forFrameRect: w.frame).height
            stableContentHeight = isTabBarVisible ? cr : cr - tabBarReservation
        } else {
            stableContentHeight = bounds.height
        }
        let usableH = max(stableContentHeight - inset.height * 2, 1)
        let cols = max(Int(floor(usableW / cellW)), 1)
        let rows = max(Int(floor(usableH / cellH)), 1)
        // dedupe — 실제 cols/rows가 변화 없으면 SIGWINCH 안 보냄 (no-op layout 등).
        let prevCols = lastReportedSize?.cols ?? session.grid.cols
        let prevRows = lastReportedSize?.rows ?? session.grid.rows
        if prevCols == cols && prevRows == rows {
            lastReportedSize = (cols, rows)
            return
        }
        lastReportedSize = (cols, rows)
        session.resize(cols: cols, rows: rows)
    }

    /// macOS 네이티브 윈도우 탭 바가 실제로 차지하는 높이 — 탭이 추가되면 macOS는
    /// `window.frame.height`를 이만큼 줄여서 탭바 공간을 만든다. 측정값: 600 → 564 = 36pt.
    /// (직관과 반대 — 탭바가 contentView를 잠식하는 게 아니라 window 자체가 작아짐.)
    private let tabBarReservation: CGFloat = 36.0

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

    // MARK: - Context menu (우클릭)

    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copyItem = NSMenuItem(
            title: String(localized: "menu.copy", defaultValue: "Copy"),
            action: #selector(copy(_:)), keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = (selectedText() != nil)
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: String(localized: "menu.paste", defaultValue: "Paste"),
            action: #selector(paste(_:)), keyEquivalent: ""
        )
        pasteItem.target = self
        pasteItem.isEnabled = (NSPasteboard.general.string(forType: .string) != nil)
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let findItem = NSMenuItem(
            title: String(localized: "menu.find", defaultValue: "Find…"),
            action: #selector(performFindPanelAction(_:)), keyEquivalent: ""
        )
        findItem.target = self
        menu.addItem(findItem)

        menu.addItem(.separator())

        // Split — responder chain으로 윈도우 컨트롤러에 전달 (Compact 모드에서만 처리됨).
        let splitH = NSMenuItem(
            title: String(localized: "menu.splitH", defaultValue: "Split Horizontally"),
            action: Selector(("splitPaneHorizontally:")), keyEquivalent: ""
        )
        menu.addItem(splitH)
        let splitV = NSMenuItem(
            title: String(localized: "menu.splitV", defaultValue: "Split Vertically"),
            action: Selector(("splitPaneVertically:")), keyEquivalent: ""
        )
        menu.addItem(splitV)
        return menu
    }

    public override func mouseDown(with event: NSEvent) {
        // 클릭으로 키 입력 되찾기 (혹시 다른 곳에 first responder가 가있을 때 대비)
        window?.makeFirstResponder(self)

        // Mouse reporting 활성 + Shift 안 누름이면 PTY로 forward (selection 안 함).
        if isMouseReportingEvent(event) {
            sendMouseEventToPTY(event: event, button: 0, pressed: true)
            return
        }

        let point = convertEventToCell(event)
        switch event.clickCount {
        case 2:
            // 더블 클릭 — 단어 선택 (space로 끊김).
            if let (start, end) = wordBoundsAround(point) {
                selectionAnchor = start
                selectionHead = end
            } else {
                selectionAnchor = point
                selectionHead = point
            }
        case 3:
            // 트리플 클릭 — 줄 전체 선택.
            let cells = cellsForTextViewRow(point.row)
            selectionAnchor = (point.row, 0)
            selectionHead = (point.row, cells.count)
        default:
            // 일반 클릭 — drag selection 시작.
            selectionAnchor = point
            selectionHead = point
        }
        scheduleRender()
    }

    private func cellsForTextViewRow(_ row: Int) -> [Cell] {
        let scrollbackCount = session.grid.scrollback.count
        if row < scrollbackCount { return session.grid.scrollback[row] }
        let vp = row - scrollbackCount
        if vp >= 0 && vp < session.grid.rows { return session.grid.row(vp) }
        return []
    }

    private func wordBoundsAround(
        _ pos: (row: Int, col: Int)
    ) -> ((row: Int, col: Int), (row: Int, col: Int))? {
        let cells = cellsForTextViewRow(pos.row)
        guard pos.col < cells.count else { return nil }
        // 클릭한 자리가 공백이면 단어 아님 — nil 반환 (그냥 점선 선택)
        if isWordBreak(cells[pos.col].char) { return nil }
        var start = pos.col
        while start > 0 && !isWordBreak(cells[start - 1].char) {
            start -= 1
        }
        var end = pos.col + 1
        while end < cells.count && !isWordBreak(cells[end].char) {
            end += 1
        }
        return ((pos.row, start), (pos.row, end))
    }

    private func isWordBreak(_ c: Character) -> Bool {
        // 단어 경계 — 공백/탭만. CJK는 단어 단위 아니지만 일단 공백 기준.
        c == " " || c == "\t"
    }

    public override func mouseDragged(with event: NSEvent) {
        // Cell motion / any motion 모드에서 drag도 PTY로 forward.
        if isMouseReportingEvent(event), session.mouseReportingMode >= 1002 {
            // 같은 cell 안에선 보내지 않도록 (1003 모드에선 보냄)
            sendMouseEventToPTY(event: event, button: 32, pressed: true) // 32 = motion bit
            return
        }
        guard selectionAnchor != nil else { return }
        selectionHead = convertEventToCell(event)
        scheduleRender()
    }

    public override func mouseUp(with event: NSEvent) {
        if isMouseReportingEvent(event) {
            sendMouseEventToPTY(event: event, button: 0, pressed: false)
            return
        }
        // anchor == head 이면 (그냥 클릭이면)
        if let a = selectionAnchor, let h = selectionHead, a == h {
            // URL은 Cmd 누른 상태에서만 열기 — Cmd 없는 클릭은 cursor 옮기는 일반 행위.
            // (iTerm2 / Terminal.app / VS Code 다 동일 UX.)
            if event.modifierFlags.contains(.command), let url = urlAtCell(a) {
                NSWorkspace.shared.open(url)
            }
            selectionAnchor = nil
            selectionHead = nil
            scheduleRender()
        }
    }

    // MARK: - Cmd-hover URL 강조 (iTerm2 / Terminal.app 와 동일 UX)
    //
    // Cmd가 눌리지 않은 상태에선 plain text URL은 그냥 평범한 텍스트로 보이고,
    // Cmd를 누르고 URL 위에 마우스를 올리면 그 글자들만 파란색 + underline + pointing hand cursor.
    // Cmd 떼거나 URL 밖으로 나가면 즉시 해제.

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = mouseTrackingArea { removeTrackingArea(area) }
        let opts: NSTrackingArea.Options = [
            .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        mouseTrackingArea = area
    }

    public override func flagsChanged(with event: NSEvent) {
        let nowDown = event.modifierFlags.contains(.command)
        if nowDown != cmdKeyDown {
            cmdKeyDown = nowDown
            if nowDown {
                updateHoverFromCurrentMouse()
            } else {
                clearHoveredURL()
            }
        }
        super.flagsChanged(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        if cmdKeyDown {
            updateHoverFromCell(convertEventToCell(event))
        }
        super.mouseMoved(with: event)
    }

    public override func mouseExited(with event: NSEvent) {
        clearHoveredURL()
        super.mouseExited(with: event)
    }

    private func updateHoverFromCurrentMouse() {
        guard let win = window else { return }
        let winPt = win.mouseLocationOutsideOfEventStream
        let inSelf = convert(winPt, from: nil)
        guard bounds.contains(inSelf) else {
            clearHoveredURL()
            return
        }
        let inTV = textView.convert(inSelf, from: self)
        let inset = textView.textContainerInset
        let cellW = max(cellMetrics.width, 1)
        let cellH = max(cellMetrics.height, 1)
        let row = max(0, Int(floor((inTV.y - inset.height) / cellH)))
        let col = max(0, Int(floor((inTV.x - inset.width) / cellW)))
        let maxRow = session.grid.scrollback.count + session.grid.rows - 1
        updateHoverFromCell((min(row, maxRow), min(col, session.grid.cols)))
    }

    private func updateHoverFromCell(_ pos: (row: Int, col: Int)) {
        if let info = urlInfoAtCell(pos) {
            let changed: Bool = {
                guard let cur = hoveredURL else { return true }
                return cur.row != pos.row || cur.colRange != info.range
            }()
            if changed {
                hoveredURL = (row: pos.row, colRange: info.range, url: info.url)
                NSCursor.pointingHand.set()
                scheduleRender()
            }
        } else {
            clearHoveredURL()
        }
    }

    private func clearHoveredURL() {
        if hoveredURL != nil {
            hoveredURL = nil
            NSCursor.iBeam.set()
            scheduleRender()
        }
    }

    /// 특정 (row, col) 셀이 URL 영역 안이면 URL과 셀 col range를 반환.
    /// OSC 8 hyperlink이면 같은 URI를 가진 인접 셀들의 범위.
    /// plain text URL이면 NSDataDetector 매치의 셀 범위.
    private func urlInfoAtCell(
        _ pos: (row: Int, col: Int)
    ) -> (url: URL, range: Range<Int>)? {
        let cells = cellsForTextViewRow(pos.row)
        guard pos.col >= 0, pos.col < cells.count else { return nil }
        if let uri = cells[pos.col].hyperlink, let url = URL(string: uri) {
            var s = pos.col
            while s > 0 && cells[s - 1].hyperlink == uri { s -= 1 }
            var e = pos.col + 1
            while e < cells.count && cells[e].hyperlink == uri { e += 1 }
            return (url, s..<e)
        }
        return detectURLRangeAtColumn(pos.col, in: cells)
    }

    private func detectURLRangeAtColumn(
        _ col: Int, in cells: [Cell]
    ) -> (url: URL, range: Range<Int>)? {
        var rowText = ""
        var colToCharIndex: [Int] = []
        var charIndexToCol: [Int] = []
        colToCharIndex.reserveCapacity(cells.count)
        for (i, cell) in cells.enumerated() {
            if cell.isContinuation {
                colToCharIndex.append(max(0, rowText.count - 1))
                continue
            }
            colToCharIndex.append(rowText.count)
            charIndexToCol.append(i)
            rowText.append(cell.char)
        }
        guard col < colToCharIndex.count else { return nil }
        let charIndex = colToCharIndex[col]
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        let nsRange = NSRange(rowText.startIndex..<rowText.endIndex, in: rowText)
        let matches = detector.matches(in: rowText, options: [], range: nsRange)
        for match in matches where NSLocationInRange(charIndex, match.range) {
            guard let url = match.url else { continue }
            guard match.range.location < charIndexToCol.count else { continue }
            let startCol = charIndexToCol[match.range.location]
            let lastCharIdx = min(
                match.range.location + match.range.length - 1,
                charIndexToCol.count - 1
            )
            var endColExclusive = charIndexToCol[lastCharIdx] + 1
            // wide-char URL의 trailing continuation cell까지 포함.
            while endColExclusive < cells.count
                && cells[endColExclusive].isContinuation {
                endColExclusive += 1
            }
            return (url, startCol..<endColExclusive)
        }
        return nil
    }

    /// 렌더 시 사용 — 주어진 textViewRow에 hovered URL이 있으면 그 col range.
    private func hoveredURLRangeForRow(_ textViewRow: Int) -> Range<Int>? {
        guard let h = hoveredURL, h.row == textViewRow else { return nil }
        return h.colRange
    }

    public override func scrollWheel(with event: NSEvent) {
        // Mouse reporting 활성 시 휠은 button 64/65 코드로 PTY 전달 (tmux 등이 사용).
        if isMouseReportingEvent(event) {
            let delta = event.scrollingDeltaY
            guard abs(delta) > 0.1 else { return }
            let btn = delta > 0 ? 64 : 65
            sendMouseEventToPTY(event: event, button: btn, pressed: true)
            return
        }
        super.scrollWheel(with: event)
        // scrollViewDidScroll observer가 bounds 변화로 호출되며 followingBottom 갱신.
    }

    private func refreshFollowingBottomFlag() {
        followingBottom = isScrolledToBottom(tolerance: 4.0)
    }

    /// 마우스 이벤트를 PTY reporting으로 forward해야 하는지 판단.
    /// 활성 모드 + Shift 미보유 = report. Shift 누르면 selection 등 네이티브 동작 우선.
    private func isMouseReportingEvent(_ event: NSEvent) -> Bool {
        session.mouseReportingMode != 0 && !event.modifierFlags.contains(.shift)
    }

    /// 마우스 이벤트를 적절한 mouse-reporting encoding(SGR 또는 X10)으로 PTY에 송신.
    private func sendMouseEventToPTY(event: NSEvent, button: Int, pressed: Bool) {
        let pos = convertEventToCell(event)
        let viewportRow = pos.row - session.grid.scrollback.count
        guard viewportRow >= 0, viewportRow < session.grid.rows else { return }
        guard pos.col >= 0, pos.col < session.grid.cols else { return }

        let mods = event.modifierFlags
        var modBits = 0
        if mods.contains(.shift) { modBits |= 4 }
        if mods.contains(.option) { modBits |= 8 }
        if mods.contains(.control) { modBits |= 16 }

        let cb = button + modBits
        let row = viewportRow + 1 // 1-based
        let col = pos.col + 1

        let bytes: Data
        if session.mouseSGREncoding {
            let term: Character = pressed ? "M" : "m"
            let s = "\u{1B}[<\(cb);\(col);\(row)\(term)"
            bytes = s.data(using: .utf8) ?? Data()
        } else {
            // X10/X11 — press: 실제 cb, release: 3 (universal release marker)
            let cbLegacy = pressed ? cb : (3 + modBits)
            let cbByte = UInt8(min(cbLegacy + 32, 255))
            let cxByte = UInt8(min(col + 32, 255))
            let cyByte = UInt8(min(row + 32, 255))
            bytes = Data([0x1B, 0x5B, 0x4D, cbByte, cxByte, cyByte])
        }
        session.write(bytes)
    }

    /// 특정 (row, col)에서 클릭 가능한 URL을 반환. OSC 8 hyperlink 우선,
    /// 없으면 NSDataDetector로 plain text URL 자동 검출.
    private func urlAtCell(_ pos: (row: Int, col: Int)) -> URL? {
        let grid = session.grid
        let scrollbackCount = grid.scrollback.count
        let cells: [Cell]
        if pos.row < scrollbackCount {
            cells = grid.scrollback[pos.row]
        } else {
            let vp = pos.row - scrollbackCount
            guard vp < grid.rows else { return nil }
            cells = grid.row(vp)
        }
        guard pos.col >= 0, pos.col < cells.count else { return nil }
        // 1. OSC 8 hyperlink가 set이면 그 URI
        if let uri = cells[pos.col].hyperlink, let url = URL(string: uri) {
            return url
        }
        // 2. NSDataDetector로 plain URL 검출
        return detectURLAtColumn(pos.col, in: cells)
    }

    /// row 내의 cell 시퀀스에서 NSDataDetector로 URL 패턴을 찾고, 주어진 col이
    /// 어느 매치 안에 들어가면 그 URL 반환.
    private func detectURLAtColumn(_ col: Int, in cells: [Cell]) -> URL? {
        // cell → char 인덱스 매핑. continuation cell은 직전 글자를 가리킴 (wide char의 2번째 column).
        var rowText = ""
        var colToCharIndex: [Int] = []
        colToCharIndex.reserveCapacity(cells.count)
        for cell in cells {
            if cell.isContinuation {
                colToCharIndex.append(max(0, rowText.count - 1))
                continue
            }
            colToCharIndex.append(rowText.count)
            rowText.append(cell.char)
        }
        guard col < colToCharIndex.count else { return nil }
        let charIndex = colToCharIndex[col]
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let nsRange = NSRange(rowText.startIndex..<rowText.endIndex, in: rowText)
        let matches = detector.matches(in: rowText, options: [], range: nsRange)
        for match in matches where NSLocationInRange(charIndex, match.range) {
            if let url = match.url { return url }
        }
        return nil
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

    /// Cmd+F (NSResponder/NSTextFinderClient 표준) — find 오버레이 토글.
    @objc public func performFindPanelAction(_ sender: Any?) {
        if let overlay = findOverlay {
            overlay.focus()
            return
        }
        showFindOverlay()
    }

    private func showFindOverlay() {
        let overlay = FindOverlayView(
            initialQuery: findQuery,
            onQueryChange: { [weak self] q in self?.applyFindQuery(q) },
            onDismiss: { [weak self] in self?.hideFindOverlay() },
            onNext: { [weak self] in self?.findNextMatch() },
            onPrev: { [weak self] in self?.findPreviousMatch() }
        )
        overlay.autoresizingMask = [.minXMargin, .minYMargin]
        let pad: CGFloat = 8
        overlay.frame = NSRect(
            x: bounds.width - overlay.frame.width - pad,
            y: bounds.height - overlay.frame.height - pad,
            width: overlay.frame.width,
            height: overlay.frame.height
        )
        addSubview(overlay)
        findOverlay = overlay
        overlay.focus()
        applyFindQuery(findQuery)
    }

    private func hideFindOverlay() {
        findOverlay?.removeFromSuperview()
        findOverlay = nil
        findMatchesByRow.removeAll()
        findMatchesOrdered.removeAll()
        activeMatchIndex = -1
        window?.makeFirstResponder(self)
        scheduleRender()
    }

    private func applyFindQuery(_ query: String) {
        findQuery = query
        findMatchesByRow.removeAll()
        findMatchesOrdered.removeAll()
        activeMatchIndex = -1
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            findOverlay?.updateCount(matched: 0)
            scheduleRender()
            return
        }
        let needle = trimmed.lowercased()
        var total = 0
        let grid = session.grid
        let scrollbackCount = grid.scrollback.count

        func scan(_ cells: [Cell], row: Int) {
            // cell → text 매핑 (continuation은 직전 글자 가리킴).
            var rowText = ""
            var colToCharIdx: [Int] = []
            colToCharIdx.reserveCapacity(cells.count)
            for cell in cells {
                if cell.isContinuation {
                    colToCharIdx.append(max(0, rowText.count - 1))
                    continue
                }
                colToCharIdx.append(rowText.count)
                rowText.append(cell.char)
            }
            guard !rowText.isEmpty else { return }
            let lower = rowText.lowercased()
            var ranges: [Range<Int>] = []
            var search = lower.startIndex
            while let m = lower.range(of: needle, range: search..<lower.endIndex) {
                let startChar = lower.distance(from: lower.startIndex, to: m.lowerBound)
                let endChar = lower.distance(from: lower.startIndex, to: m.upperBound)
                // char idx → col 매핑
                let startCol = colToCharIdx.firstIndex { $0 >= startChar } ?? colToCharIdx.count
                var endCol = startCol
                while endCol < colToCharIdx.count && colToCharIdx[endCol] < endChar {
                    endCol += 1
                }
                if startCol < endCol {
                    ranges.append(startCol..<endCol)
                    total += 1
                }
                search = m.upperBound
            }
            if !ranges.isEmpty {
                findMatchesByRow[row] = ranges
            }
        }

        for (i, line) in grid.scrollback.enumerated() { scan(line, row: i) }
        for r in 0..<grid.rows { scan(grid.row(r), row: scrollbackCount + r) }

        // 정렬된 평탄 리스트 — Cmd+G next/prev 네비용 (row 오름차순, 같은 row 내 col 오름차순).
        findMatchesOrdered = findMatchesByRow
            .sorted { $0.key < $1.key }
            .flatMap { row, ranges in
                ranges.sorted { $0.lowerBound < $1.lowerBound }.map { (row: row, range: $0) }
            }
        // 첫 매치를 active로 선택하고 그쪽으로 스크롤 (입력 중 점진 검색에서도 첫 매치 보이게).
        if !findMatchesOrdered.isEmpty {
            activeMatchIndex = 0
            scrollToActiveMatch()
        }
        findOverlay?.updateCount(matched: total)
        scheduleRender()
    }

    /// 다음/이전 매치로 이동 (Cmd+G / Cmd+Shift+G). wrap-around.
    /// 메뉴/단축키에서 responder chain으로 들어오므로 @objc public 노출.
    @objc public func findNextMatch() { stepMatch(+1) }
    @objc public func findPreviousMatch() { stepMatch(-1) }

    private func stepMatch(_ delta: Int) {
        guard !findMatchesOrdered.isEmpty else { NSSound.beep(); return }
        if activeMatchIndex < 0 {
            activeMatchIndex = delta > 0 ? 0 : findMatchesOrdered.count - 1
        } else {
            let n = findMatchesOrdered.count
            activeMatchIndex = (activeMatchIndex + delta + n) % n
        }
        scrollToActiveMatch()
        findOverlay?.updateCount(matched: findMatchesOrdered.count,
                                 current: activeMatchIndex + 1)
        scheduleRender()
    }

    /// 활성 매치 row가 viewport 가운데쯤 보이도록 스크롤.
    private func scrollToActiveMatch() {
        guard activeMatchIndex >= 0, activeMatchIndex < findMatchesOrdered.count else { return }
        let row = findMatchesOrdered[activeMatchIndex].row
        let visHeight = scrollView.contentView.bounds.height
        let rowY = CGFloat(row) * cellMetrics.height + textView.textContainerInset.height
        // 매치를 viewport 1/3 지점에 두어 위아래 맥락이 보이게.
        let targetY = max(0, rowY - visHeight / 3)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// 한 줄에서 find 매치가 차지하는 col 범위들.
    private func findRangesForRow(_ row: Int) -> [Range<Int>] {
        findMatchesByRow[row] ?? []
    }

    /// 그 row에 현재 활성(Cmd+G로 선택된) 매치가 있으면 그 col range. 없으면 nil.
    private func activeFindRangeForRow(_ row: Int) -> Range<Int>? {
        guard activeMatchIndex >= 0, activeMatchIndex < findMatchesOrdered.count else { return nil }
        let m = findMatchesOrdered[activeMatchIndex]
        return m.row == row ? m.range : nil
    }

    @objc public func zoomIn(_ sender: Any?) {
        setZoom(fontSizeMultiplier * 1.1)
    }

    @objc public func zoomOut(_ sender: Any?) {
        setZoom(fontSizeMultiplier / 1.1)
    }

    @objc public func resetZoom(_ sender: Any?) {
        setZoom(1.0)
    }

    private func setZoom(_ multiplier: CGFloat) {
        fontSizeMultiplier = max(0.5, min(4.0, multiplier))
        let baseSize = session.config.fontSize
        let newSize = max(6, baseSize * fontSizeMultiplier)
        // zoom도 cascade 포함된 폰트 사용 — Menlo 등에서도 Nerd glyph fallback 유지.
        let font = fontWithNerdFallback(family: session.config.fontFamily, size: newSize)
        textView.font = font
        // zoom은 **순수 시각 변경**으로 취급. session.grid 차원은 그대로 두고
        // cellMetrics만 새 폰트 기준으로 갱신 — SIGWINCH 안 발사 → 셸이 prompt를
        // 재출력하지 않음 (이전엔 매 Cmd+= 마다 새 prompt 라인이 추가돼서
        // "Enter 친 것처럼" 보였음). 극단적 확대 시 오른쪽 일부 클립될 수 있지만
        // 일반 사용 범위에선 OK. 실제 grid resize는 사용자가 윈도우 사이즈 바꿀 때.
        let glyphSize = ("M" as NSString).size(withAttributes: [.font: font])
        let newCellW = max(glyphSize.width, 1)
        let newCellH = max(measuredLineHeight(font: font), 1)
        cellMetrics = (newCellW, newCellH)
        // dedupe 무력화 후 새 cellMetrics로 textStorage 재구성.
        lastRenderedVersion = .max
        renderNow()
        followingBottom = true
        scrollViewportToBottom()
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
            // responder chain에 closeTab 액션을 먼저 보냄 — CompactWindowController가
            // 활성 탭만 닫는 구현을 가지고 있을 수 있음. 아무도 안 받으면 일반 윈도우 닫기.
            if NSApp.sendAction(Selector(("performCloseTab:")), to: nil, from: self) {
                return true
            }
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
    private var lastRenderedFindKey: String = ""
    private var lastRenderedHoverKey: String = ""

    private func renderNow() {
        let grid = session.grid
        let selKey = selectionKey()
        let findKey = "\(findQuery)|\(findMatchesByRow.count)|\(activeMatchIndex)"
        let hoverKey: String = {
            guard let h = hoveredURL else { return "" }
            return "\(h.row)|\(h.colRange.lowerBound)|\(h.colRange.upperBound)"
        }()
        if grid.version == lastRenderedVersion
            && markedText == lastRenderedMarkedText
            && selKey == lastRenderedSelectionKey
            && findKey == lastRenderedFindKey
            && hoverKey == lastRenderedHoverKey {
            return
        }
        lastRenderedVersion = grid.version
        lastRenderedMarkedText = markedText
        lastRenderedSelectionKey = selKey
        lastRenderedFindKey = findKey
        lastRenderedHoverKey = hoverKey

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

        // Scrollback. cursor는 안 그림.
        for (i, line) in grid.scrollback.enumerated() {
            let sel = selectedColumnsForRow(i, cols: line.count)
            let finds = findRangesForRow(i)
            let hover = hoveredURLRangeForRow(i)
            let active = activeFindRangeForRow(i)
            appendLine(
                line, cols: line.count, cursorCol: nil,
                selectedCols: sel, findRanges: finds, activeFindRange: active,
                hoveredURLRange: hover,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
            result.append(NSAttributedString(string: "\n"))
        }

        // block-cursor inverse 렌더링은 cursorVisible 따라가지만,
        // IME 조합 overlay는 cursor가 숨김 처리되어 있어도(TUI 앱들이 DECTCEM ?25l로
        // 흔히 함, 예: claude code, vim 일부 모드, htop) 사용자가 입력 중이면 보여야 함.
        let blockCursorRow = grid.cursorVisible ? grid.cursorRow : -1
        let imeOverlayRow = grid.cursorRow   // cursor 가시성과 무관하게 항상 그 자리
        let blockCursorActive = (grid.cursorShape == .block) && markedText.isEmpty
        let mt = markedText
        for r in 0..<grid.rows {
            let textViewRow = scrollbackCount + r
            let sel = selectedColumnsForRow(textViewRow, cols: grid.cols)
            let finds = findRangesForRow(textViewRow)
            let hover = hoveredURLRangeForRow(textViewRow)
            let active = activeFindRangeForRow(textViewRow)
            if r == imeOverlayRow && !mt.isEmpty {
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
                let cc: Int? = (r == blockCursorRow && blockCursorActive) ? grid.cursorCol : nil
                appendLine(
                    grid.row(r), cols: grid.cols, cursorCol: cc,
                    selectedCols: sel, findRanges: finds, activeFindRange: active,
                    hoveredURLRange: hover,
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
        // NSTextView는 setAttributedString 직후에도 frame.height 갱신이 비동기적
        // 일 수 있어서, 강제 동기 layout 후 frame.height 읽음.
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        let visHeight = scrollView.contentView.bounds.height

        if grid.isAltScreenActive {
            // Alt-screen TUI (vim/htop) — 전체 viewport가 콘텐츠. viewport top anchor로
            // alt 영역 전체가 보이도록.
            let viewportTop = CGFloat(grid.scrollback.count) * cellMetrics.height
                + textView.textContainerInset.height
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: viewportTop))
        } else {
            // 일반 셸 + primary-screen TUI(Claude Code/Ink 등) — "cursor가 viewport
            // 안에만 보이면 OK" 정책. cursor가 이미 보이면 scroll 안 함 → Claude Code
            // 처럼 cursor가 UI 중간에 있을 때 cursor 아래 콘텐츠가 잘리는 회귀 방지.
            // cursor가 viewport 위/아래로 빠지면 그쪽으로만 맞춤.
            let cursorViewRow = grid.scrollback.count + grid.cursorRow
            let cursorY = CGFloat(cursorViewRow) * cellMetrics.height
                + textView.textContainerInset.height
            let cursorBottom = cursorY + cellMetrics.height
            let curScroll = scrollView.contentView.bounds.origin.y
            let visTop = curScroll
            let visBottom = curScroll + visHeight
            if cursorBottom > visBottom {
                let targetY = cursorBottom - visHeight
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            } else if cursorY < visTop {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: cursorY))
            }
            // else: cursor 이미 가시 영역 안 — scroll 안 함.
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)

        updateCursorLayer()
    }

    /// underline/bar 모양 cursor를 CALayer로 위치/크기 갱신. block은 inverse-cell로 처리.
    @objc private func scrollViewDidScroll(_ note: Notification) {
        updateCursorLayer()
        // followingBottom 갱신은 **사용자 인터랙션 scroll** (`didLiveScrollNotification`)
        // 에만 반응. boundsDidChangeNotification은 programmatic scroll
        // (scrollViewportToBottom)이나 윈도우 리사이즈로 인한 transient도 발사하는데,
        // 그때 isScrolledToBottom이 stale 값으로 잘못 false를 돌려 followingBottom이
        // 깨지고 → 이후 layout이 bottom anchor를 안 해서 마지막 줄이 뷰포트 밖으로
        // 밀리는 회귀를 만들었음.
        if note.name == NSScrollView.didLiveScrollNotification {
            DispatchQueue.main.async { [weak self] in
                self?.refreshFollowingBottomFlag()
            }
        }
    }

    private func updateCursorLayer() {
        let grid = session.grid
        let shape = grid.cursorShape

        // 숨겨야 할 조건들:
        // - cursor invisible (DECTCEM ?25l)
        // - block 모양 (inverse-cell이 처리)
        // - IME 조합 중 (marked text overlay가 cursor 자리를 대체)
        guard grid.cursorVisible, shape != .block, markedText.isEmpty else {
            cursorLayer.isHidden = true
            return
        }

        let cellW = max(cellMetrics.width, 1)
        let cellH = max(cellMetrics.height, 1)
        let inset = textView.textContainerInset

        // textView 콘텐츠 좌표계의 cursor cell origin
        let textViewRow = grid.scrollback.count + grid.cursorRow
        let tvX = inset.width + CGFloat(grid.cursorCol) * cellW
        let tvY = inset.height + CGFloat(textViewRow) * cellH

        // textView 좌표 → HaliteSurfaceView 좌표 (scroll offset 자동 반영됨)
        let originInSelf = textView.convert(NSPoint(x: tvX, y: tvY), to: self)

        // wide cell이면 2 cols 폭
        var cursorW = cellW
        if grid.cursorCol + 1 < grid.cols
            && grid.cursorRow < grid.rows {
            let row = grid.row(grid.cursorRow)
            if grid.cursorCol + 1 < row.count && row[grid.cursorCol + 1].isContinuation {
                cursorW = cellW * 2
            }
        }

        // self는 non-flipped(bottom-left origin), textView는 flipped(top-left origin).
        // convert(_:to:)는 셀의 시각적 top-left를 self 좌표로 돌려주므로,
        // 셀 박스의 rect.origin(bottom-left) y = originInSelf.y - cellH.
        let cellBottomY = originInSelf.y - cellH

        // 가시 영역 밖이면 숨김 (사용자가 history 위로 스크롤한 상태 등)
        let visibleRect = bounds
        let cursorRectInSelf = NSRect(x: originInSelf.x, y: cellBottomY, width: cursorW, height: cellH)
        if !visibleRect.intersects(cursorRectInSelf) {
            cursorLayer.isHidden = true
            return
        }

        let frame: NSRect
        switch shape {
        case .underline:
            // 셀 시각적 바닥에 얇은 strip — non-flipped이므로 rect의 y가 바닥.
            let thickness = max(1.5, cellH * 0.1)
            frame = NSRect(
                x: originInSelf.x,
                y: cellBottomY,
                width: cursorW,
                height: thickness
            )
        case .bar:
            // 셀 시각적 좌측 변에 얇은 column — 셀 전체 높이.
            let thickness = max(1.5, cellW * 0.15)
            frame = NSRect(
                x: originInSelf.x,
                y: cellBottomY,
                width: thickness,
                height: cellH
            )
        case .block:
            // 도달 안 함 (위에서 guard로 빠짐)
            cursorLayer.isHidden = true
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true) // animation 끔
        cursorLayer.frame = frame
        cursorLayer.backgroundColor = session.config.cursorColor.cgColor
        cursorLayer.isHidden = false
        CATransaction.commit()
    }

    /// 한 줄(Cell 배열)을 run-length attribute 그룹으로 묶어서 attributed string에 append.
    /// `cursorCol`이 주어지면 그 위치의 한 셀은 단독으로 inverse 처리해서 그림.
    /// `selectedCols`가 주어지면 해당 범위의 셀들은 selection background로 칠함.
    /// `findRanges`가 주어지면 그 범위들의 셀은 find-highlight 색으로 칠함.
    private func appendLine(
        _ line: [Cell],
        cols: Int,
        cursorCol: Int?,
        selectedCols: Range<Int>?,
        findRanges: [Range<Int>],
        activeFindRange: Range<Int>?,
        hoveredURLRange: Range<Int>?,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        guard cols > 0 else { return }
        let cc = cursorCol ?? -1
        if cc >= 0 && cc < cols {
            if cc > 0 {
                appendRunGroup(
                    line, range: 0..<cc, selectedCols: selectedCols, findRanges: findRanges,
                    activeFindRange: activeFindRange, hoveredURLRange: hoveredURLRange,
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
                    line, range: (cc + 1)..<cols, selectedCols: selectedCols, findRanges: findRanges,
                    activeFindRange: activeFindRange, hoveredURLRange: hoveredURLRange,
                    baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
                )
            }
        } else {
            appendRunGroup(
                line, range: 0..<cols, selectedCols: selectedCols, findRanges: findRanges,
                activeFindRange: activeFindRange, hoveredURLRange: hoveredURLRange,
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
                line, range: 0..<cursorCol, selectedCols: nil, findRanges: [],
                activeFindRange: nil, hoveredURLRange: nil,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }

        // 조합 텍스트 — config.imeStyle에 따라 시각 단서 결정.
        var imeAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: session.config.foregroundColor,
            .paragraphStyle: paragraphStyle,
        ]
        switch session.config.imeStyle {
        case .underline:
            imeAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            imeAttrs[.underlineColor] = session.config.foregroundColor
                .withAlphaComponent(0.7)
        case .thickUnderline:
            imeAttrs[.underlineStyle] = NSUnderlineStyle.thick.rawValue
            imeAttrs[.underlineColor] = session.config.foregroundColor
        case .background:
            imeAttrs[.backgroundColor] = NSColor.systemBlue.withAlphaComponent(0.45)
            imeAttrs[.foregroundColor] = NSColor.white
        case .both:
            imeAttrs[.underlineStyle] = NSUnderlineStyle.thick.rawValue
            imeAttrs[.backgroundColor] = NSColor.systemBlue.withAlphaComponent(0.65)
            imeAttrs[.foregroundColor] = NSColor.white
        case .none:
            break // 텍스트만 출력
        }
        result.append(NSAttributedString(string: markedText, attributes: imeAttrs))

        // 조합 텍스트가 가린 만큼 row의 나머지 셀을 건너뜀.
        // markedText.count로 대략의 cell 폭 산정 (CJK wide는 M5에서 처리).
        let overlayCols = markedText.count
        let afterCol = min(cursorCol + overlayCols, cols)
        if afterCol < cols {
            appendRunGroup(
                line, range: afterCol..<cols, selectedCols: nil, findRanges: [],
                activeFindRange: nil, hoveredURLRange: nil,
                baseFont: baseFont, paragraphStyle: paragraphStyle, into: result
            )
        }
    }

    private func appendRunGroup(
        _ line: [Cell],
        range: Range<Int>,
        selectedCols: Range<Int>?,
        findRanges: [Range<Int>],
        activeFindRange: Range<Int>?,
        hoveredURLRange: Range<Int>?,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        func isFindMatch(_ col: Int) -> Bool {
            findRanges.contains { $0.contains(col) }
        }
        func isActiveFind(_ col: Int) -> Bool {
            activeFindRange?.contains(col) ?? false
        }
        func isHovered(_ col: Int) -> Bool {
            hoveredURLRange?.contains(col) ?? false
        }

        var c = range.lowerBound
        while c < range.upperBound {
            if line[c].isContinuation {
                c += 1
                continue
            }
            let isWide = (c + 1 < line.count && line[c + 1].isContinuation)
            if isWide {
                let runSelected = selectedCols?.contains(c) ?? false
                let runFind = isFindMatch(c)
                let runActive = isActiveFind(c)
                let runHover = isHovered(c)
                appendWideCell(
                    line[c],
                    isSelected: runSelected,
                    isFindMatch: runFind,
                    isActiveFindMatch: runActive,
                    isHoveredURL: runHover,
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
            let runFind = isFindMatch(c)
            let runActive = isActiveFind(c)
            let runHover = isHovered(c)
            var endC = c + 1
            while endC < range.upperBound,
                  !line[endC].isContinuation,
                  !(endC + 1 < line.count && line[endC + 1].isContinuation),
                  line[endC].attrs == runAttrs,
                  line[endC].hyperlink == runHyperlink,
                  (selectedCols?.contains(endC) ?? false) == runSelected,
                  isFindMatch(endC) == runFind,
                  isActiveFind(endC) == runActive,
                  isHovered(endC) == runHover {
                endC += 1
            }
            var runChars = ""
            runChars.reserveCapacity(endC - c)
            for i in c..<endC { runChars.append(line[i].char) }
            let nsAttrs = makeAttributes(
                for: runAttrs, baseFont: baseFont,
                paragraphStyle: paragraphStyle,
                isSelected: runSelected, isFindMatch: runFind,
                isActiveFindMatch: runActive,
                isHoveredURL: runHover, hyperlink: runHyperlink
            )
            result.append(NSAttributedString(string: runChars, attributes: nsAttrs))
            c = endC
        }
    }

    /// Wide cell 한 개를 단독 NSAttributedString run으로 emit + kern으로 2*cellW 강제.
    private func appendWideCell(
        _ cell: Cell,
        isSelected: Bool,
        isFindMatch: Bool = false,
        isActiveFindMatch: Bool = false,
        isHoveredURL: Bool = false,
        baseFont: NSFont,
        paragraphStyle: NSParagraphStyle,
        into result: NSMutableAttributedString
    ) {
        var nsAttrs = makeAttributes(
            for: cell.attrs, baseFont: baseFont,
            paragraphStyle: paragraphStyle,
            isSelected: isSelected, isFindMatch: isFindMatch,
            isActiveFindMatch: isActiveFindMatch,
            isHoveredURL: isHoveredURL, hyperlink: cell.hyperlink
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
        isFindMatch: Bool = false,
        isActiveFindMatch: Bool = false,
        isHoveredURL: Bool = false,
        hyperlink: String? = nil
    ) -> [NSAttributedString.Key: Any] {
        let (fg, bg) = cellAttrs.resolvedColors(theme: session.config.theme)
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
        // 우선순위: selection > activeFindMatch > findMatch > cell bg
        if isSelected {
            attrs[.backgroundColor] = NSColor.selectedTextBackgroundColor
        } else if isActiveFindMatch {
            // 현재 활성(Cmd+G로 선택된) 매치 — 주황색으로 다른 매치와 구분.
            attrs[.backgroundColor] = NSColor.systemOrange.withAlphaComponent(0.85)
            attrs[.foregroundColor] = NSColor.black
        } else if isFindMatch {
            attrs[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.6)
            attrs[.foregroundColor] = NSColor.black
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
        // Cmd-hover 표시 — 평소엔 plain text URL에 아무 표시 없다가 Cmd 누르고
        // URL 위에 마우스 올리면 그 글자들만 밝은 파란색 + 또렷한 underline.
        if isHoveredURL {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.underlineColor] = NSColor.systemBlue
            attrs[.foregroundColor] = NSColor.systemBlue
        }
        return attrs
    }
}
