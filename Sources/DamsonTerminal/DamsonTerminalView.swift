import AppKit
import Combine
import SwiftUI

/// SwiftUI에서 한 줄로 끼울 수 있는 진입점.
/// cmux/damson.app 양쪽에서 동일 API.
public struct DamsonTerminalView: NSViewRepresentable {
    public let session: DamsonSession
    public var isActive: Bool
    public var onFocus: (() -> Void)?

    public init(
        session: DamsonSession,
        isActive: Bool = true,
        onFocus: (() -> Void)? = nil
    ) {
        self.session = session
        self.isActive = isActive
        self.onFocus = onFocus
    }

    public func makeNSView(context: Context) -> DamsonSurfaceView {
        let view = DamsonSurfaceView(session: session)
        view.onFocus = onFocus
        return view
    }

    public func updateNSView(_ nsView: DamsonSurfaceView, context: Context) {
        nsView.isActive = isActive
        nsView.onFocus = onFocus
    }
}

/// 2-finger 가로 스와이프 탭 전환의 호스트 측 수신자. 터미널 surface는 라이브러리라
/// 탭/윈도우를 모르므로, 제스처를 이 프로토콜로 호스트(윈도우 컨트롤러)에 중계한다.
/// `translation`은 누적 가로 이동량(pt, 오른쪽=양수). 호스트가 이웃 탭 트리를
/// 실시간으로 끌고, end에서 임계값에 따라 commit/cancel 한다.
public protocol TabSwipeHandler: AnyObject {
    func tabSwipeUpdate(translation: CGFloat)
    /// `velocity`: recent horizontal speed at release (pt per event, ~per frame),
    /// so a fast flick commits even if it didn't travel the distance threshold.
    func tabSwipeEnd(translation: CGFloat, velocity: CGFloat)
}

/// 입력(키/IME/마우스)·선택·find·follow 정책의 소유자. 그리기/스크롤/좌표 변환은
/// `MetalTerminalBackend`(`CAMetalLayer` 인스턴스드 렌더러)에 위임한다.
/// 키 이벤트는 이쪽에서 잡아 `session.write(_:)`로 전달.
public final class DamsonSurfaceView: NSView, NSTextInputClient {
    public let session: DamsonSession

    public var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { return }
            needsDisplay = true
            // 비활성(디밍) pane은 커서를 깜빡이지 않게 — 타이머 시작/중지.
            updateBlinkTimer()
        }
    }

    public var onFocus: (() -> Void)?

    /// The render/scroll/geometry backend (the Metal renderer). Behind the
    /// `TerminalRenderBackend` protocol so the host never touches Metal directly
    /// and the seam stays open for future backends.
    private let backend: TerminalRenderBackend
    /// Concrete Metal backend (== `backend`), kept for perf-HUD wiring which is
    /// Metal-specific and not part of the backend seam.
    private let metalBackend: MetalTerminalBackend
    /// Toggleable on-screen frame-time graph + FPS overlay (our own — Apple's MTL
    /// HUD crashes on this OS). Shown while `isPerfHUDEnabled`.
    private var perfHUDView: PerfHUDView?
    /// Global perf-HUD on/off, flipped by `togglePerfHUD()`; every surface mirrors it.
    public static var isPerfHUDEnabled = false

    /// Flip the perf HUD for all surfaces (bound to a keyboard shortcut by the app).
    public static func togglePerfHUD() {
        isPerfHUDEnabled.toggle()
        NotificationCenter.default.post(name: .damsonPerfHUDToggled, object: nil)
    }

    /// Menu / responder-chain entry point for the toggle.
    @objc public func togglePerformanceHUD(_ sender: Any?) {
        DamsonSurfaceView.togglePerfHUD()
    }

    /// Apple Metal Performance HUD (native overlay w/ graph) — separate toggle from
    /// our custom HUD, on its own shortcut. Uses CAMetalLayer.developerHUDProperties.
    public static var isAppleHUDEnabled = false
    public static func toggleAppleHUD() {
        isAppleHUDEnabled.toggle()
        NotificationCenter.default.post(name: .damsonAppleHUDToggled, object: nil)
    }
    @objc public func toggleAppleMetalHUD(_ sender: Any?) {
        DamsonSurfaceView.toggleAppleHUD()
    }
    private func applyAppleHUD() {
        metalBackend.setAppleHUD(DamsonSurfaceView.isAppleHUDEnabled)
    }

    /// Reflect the global perf-HUD flag on this surface: create/show the overlay and
    /// start the backend's live measurement, or hide it.
    private func applyPerfHUD() {
        if DamsonSurfaceView.isPerfHUDEnabled {
            if perfHUDView == nil {
                let v = PerfHUDView(frame: .zero)
                addSubview(v)
                perfHUDView = v
            }
            perfHUDView?.isHidden = false
            metalBackend.onPerfSample = { [weak self] dt in
                self?.perfHUDView?.addSample(dt)
            }
            metalBackend.setPerfHUD(true)
            positionPerfHUD()
        } else {
            metalBackend.setPerfHUD(false)
            metalBackend.onPerfSample = nil
            perfHUDView?.isHidden = true
        }
    }

    /// Pin the HUD to the top-right corner (fixed size).
    private func positionPerfHUD() {
        guard let v = perfHUDView else { return }
        let w: CGFloat = 220, h: CGFloat = 72
        let x = bounds.maxX - w - 8
        let y = isFlipped ? 8 : bounds.maxY - h - 8
        v.frame = NSRect(x: x, y: y, width: w, height: h)
    }
    private var gridSubscription: AnyCancellable?
    private var configSubscription: AnyCancellable?
    private var lastReportedSize: (cols: Int, rows: Int)? = nil
    private var renderScheduled = false
    /// DEC 2026 sync output flush 안전 타이머가 이미 예약돼 있는지.
    private var syncFlushScheduled = false
    /// sync frame이 ESU 없이 너무 오래 열려 있을 때 강제 present까지의 시간(초).
    /// 정상 Claude Code/Ink 프레임은 한 자릿수 ms 안에 ESU가 와서 이 타이머는
    /// 거의 발동하지 않음 — freeze 방지용 안전망.
    private let syncFlushDeadline: TimeInterval = 0.15
    private var lastRenderedVersion: UInt64 = .max
    /// 마지막 렌더 시점의 marked text. grid 변화 없이 marked text만 비워질 때
    /// (BS-cancel 등) 강제 재렌더링하기 위한 비교용.
    private var lastRenderedMarkedText: String = ""
    /// 캐시된 cell metrics. `reportSizeIfChanged`가 갱신, render가 paragraph style에 사용.
    /// 폰트에서만 파생되는 단일 값 — 양 백엔드가 공유해 토글 시 SIGWINCH 방지.
    private var cellMetrics = CellMetrics(width: 1, height: 1)

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
    /// 트랙패드 정밀 휠 델타 누적(포인트). mouse-reporting 앱에 휠을 throttle 전달할 때 사용.
    private var wheelReportAccum: CGFloat = 0

    /// DECSCUSR underline/bar 모양용 cursor overlay. 호스트 레이어에 둠 — 백엔드가
    /// 기하를 계산해 주면 여기에 위치시킨다 (좌표 basis가 원본과 일치). block 모양은
    /// 백엔드 렌더의 inverse-cell이 처리하므로 이 레이어는 underline/bar에서만 보임.
    private let cursorLayer = CALayer()

    /// cursor blink — config.cursorBlink ON이면 timer로 phase 토글.
    /// blinkVisible=false면 cursor를 숨김(block은 inverse 미적용, underline/bar는 layer hidden).
    private var cursorBlinkTimer: Timer?
    private var cursorBlinkVisible = true

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

    /// alt-screen 활성 상태의 직전 값. primary↔alt 전환을 감지해 follow를 재개하기 위함
    /// (vim 진입/종료 등 — 앱이 화면을 점유하는 동안엔 항상 그 영역을 보여줘야 함).
    private var lastAltScreenActive: Bool = false

    /// 직전 렌더 시점의 "evict 누적 줄 수"(= scrollbackPushCount - scrollback.count).
    /// 사용자가 위로 스크롤한 상태에서 scrollback 최상단이 evict되면 보던 콘텐츠가
    /// 위로 밀리는데, 그 양만큼 스크롤도 따라 올려 content-anchor를 유지하는 데 사용.
    private var lastEvictedTotal: UInt64 = 0

    /// 키 입력 점프 애니메이션이 진행 중인지. true인 동안엔 renderNow()/layout()의
    /// 즉시 follow-scroll을 건너뛴다 — 안 그러면 echo 렌더가 애니메이션을 끝 위치로
    /// 순간이동시켜 부드러운 점프가 보이지 않음.
    private var isSnappingToCursor: Bool = false

    public init(session: DamsonSession) {
        self.session = session

        // The Metal backend is the only render path. (The legacy NSTextView
        // backend was retired at P6 once the Metal path reached parity.) Metal is
        // available on every Mac this app supports; a nil device means a broken
        // GPU stack, which is unrecoverable for a GPU terminal.
        guard let metal = MetalTerminalBackend(config: session.config) else {
            fatalError("DamsonSurfaceView: no Metal device available — cannot create the renderer.")
        }
        self.backend = metal
        self.metalBackend = metal

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.hostBackground(session.config).cgColor

        let content = backend.contentView
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        content.frame = bounds

        // underline/bar cursor overlay layer — 호스트 레이어에 둠 (원본과 동일).
        cursorLayer.zPosition = 100
        cursorLayer.isHidden = true
        layer?.addSublayer(cursorLayer)

        // 백엔드가 스크롤 변동을 콜백 — boundsDidChange(programmatic 포함)는 cursor
        // overlay 재배치, didLiveScroll(사용자 인터랙션)은 follow-bottom 갱신.
        // (원래 scrollViewDidScroll의 두 역할을 그대로 분리.)
        backend.onScrollGeometryChanged = { [weak self] in self?.refreshCursorOverlayNow() }
        backend.onUserScroll = { [weak self] in
            DispatchQueue.main.async { self?.refreshFollowingBottomFlag() }
        }
        // perf HUD 토글 브로드캐스트 구독 — 켜지면 이 surface도 오버레이를 띄운다.
        NotificationCenter.default.addObserver(
            forName: .damsonPerfHUDToggled, object: nil, queue: .main
        ) { [weak self] _ in self?.applyPerfHUD() }
        if DamsonSurfaceView.isPerfHUDEnabled { applyPerfHUD() }
        NotificationCenter.default.addObserver(
            forName: .damsonAppleHUDToggled, object: nil, queue: .main
        ) { [weak self] _ in self?.applyAppleHUD() }
        // 초기 상태를 항상 명시 적용 — MTL_HUD_ENABLED env로 자동 켜진 Apple HUD를
        // 시작 시엔 꺼둔다(⌃⌘J로만 켜지도록). 기본 isAppleHUDEnabled == false.
        applyAppleHUD()

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
        updateBlinkTimer()
    }

    // MARK: - Cursor blink

    /// config.cursorBlink에 따라 timer 시작/중지. ~530ms 주기로 phase 토글.
    private func updateBlinkTimer() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        cursorBlinkVisible = true
        // 블링크 ON이고 이 pane이 활성일 때만 깜빡인다. 비활성(디밍) pane은 정적 커서.
        guard session.config.cursorBlink, isActive else {
            scheduleRender()
            return
        }
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) {
            [weak self] _ in
            guard let self = self else { return }
            self.cursorBlinkVisible.toggle()
            self.scheduleRender()
        }
    }

    /// 키 입력 시 cursor를 즉시 보이게 + blink phase 리셋 (입력 중엔 안 깜빡이게).
    private func resetBlinkPhase() {
        guard session.config.cursorBlink, isActive else { return }
        cursorBlinkVisible = true
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) {
            [weak self] _ in
            guard let self = self else { return }
            self.cursorBlinkVisible.toggle()
            self.scheduleRender()
        }
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

    /// host 뷰 레이어의 배경색. 배경 불투명도 < 1이면 clear(=투명)로 둬 metal 레이어의
    /// 투명 배경이 창 뒤(데스크톱/블러)까지 비치게 한다. 1.0이면 기존처럼 테마 배경색.
    private static func hostBackground(_ config: DamsonConfig) -> NSColor {
        config.backgroundOpacity < 1.0 ? .clear : config.backgroundColor
    }

    /// Settings 변경 → session.updateConfig → 여기로 들어와서 textView/색상/스크롤백 적용.
    private func applyConfig(_ config: DamsonConfig) {
        backend.applyConfig(config)
        layer?.backgroundColor = Self.hostBackground(config).cgColor
        lastReportedSize = nil
        // dedupe key 무력화 후 동기 re-render — grid.version 변화 없이도 새 폰트/색이
        // textStorage에 즉시 반영되도록.
        lastRenderedVersion = .max
        needsLayout = true
        renderNow()
        updateBlinkTimer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        backend.contentView.frame = bounds
        if perfHUDView != nil { positionPerfHUD() }
        // 라이브 리사이즈 중에도 콘텐츠가 새 너비로 즉시 re-layout 되도록 강제.
        // 이게 없으면 드래그 중엔 옛 layout이 유지되어 화면이 안 갱신되어 보임.
        backend.ensureLayout()
        reportSizeIfChanged()
        // 사용자가 위로 스크롤한 상태(followingBottom == false)면 layout 패스(리사이즈
        // 등)에서도 위치를 건드리지 않는다 — 보던 history가 강제로 바닥으로 튀지 않게.
        // 키 입력 점프 애니메이션 중(isSnappingToCursor)에도 건드리지 않음.
        if followingBottom && !isSnappingToCursor {
            if session.grid.isAltScreenActive || session.grid.hasUsedSyncOutput
                || session.grid.hasContentBelowCursor {
                // grid-top anchor — 라이브 grid 전체(하단 footer 포함)를 보여준다.
                // Claude Code(커서 아래 status 상주)가 이 경로로 들어와 잘림이 해소됨.
                scrollViewportToAltTop()
            } else {
                scrollViewportToBottom()
            }
        }
        // resize 직후 새 grid 콘텐츠도 즉시 그리기.
        if inLiveResize {
            renderNow()
        }
    }

    private func isScrolledToBottom(tolerance: CGFloat = 2.0) -> Bool {
        let docHeight = backend.contentHeight
        let visHeight = backend.viewportHeight
        let yMax = max(0, docHeight - visHeight)
        // Clamp to the valid range: the Metal backend can report a rubber-band
        // overshoot past yMax, which must NOT flip follow-bottom off while tailing.
        let curY = min(max(backend.scrollYPixels, 0), yMax)
        return abs(curY - yMax) <= tolerance
    }

    /// Alt-screen 활성 시 — primary scrollback을 건너뛰고 alt viewport top에 anchor.
    /// (alt-screen 진입 시 self.scrollback이 primary의 history를 그대로 갖고 있어서
    ///  안 스크롤하면 textStorage 최상단=primary scrollback이 보이고 alt 콘텐츠는
    ///  그 아래에 그려져 사용자가 위로 스크롤해야 보는 회귀가 있었음.)
    private func scrollViewportToAltTop() {
        backend.ensureLayout()
        let viewportTop = CGFloat(session.grid.scrollback.count) * cellMetrics.height
            + backend.contentInset.height
        backend.setScrollY(viewportTop, animated: false)
    }

    private func scrollViewportToBottom() {
        backend.ensureLayout()
        let visHeight = backend.viewportHeight
        // "cursor visible" 정책 — cursor가 가시 영역 밖이면 들어오게만, 안이면 안 건드림.
        // layout(window resize 등)에서 followingBottom 일 때 호출되므로 사용자가 바닥에
        // 머물 의도면 그쪽으로 잡아주되, cursor 위 영역이 살아 있다면 그대로 둠.
        let cursorViewRow = session.grid.scrollback.count + session.grid.cursorRow
        let cursorY = CGFloat(cursorViewRow) * cellMetrics.height
            + backend.contentInset.height
        let cursorBottom = cursorY + cellMetrics.height
        let curScroll = backend.scrollYPixels
        let visTop = curScroll
        let visBottom = curScroll + visHeight
        if cursorBottom > visBottom {
            backend.setScrollY(cursorBottom - visHeight, animated: false)
        } else if cursorY < visTop {
            backend.setScrollY(cursorY, animated: false)
        } else {
            backend.reflectScroll()
        }
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
        //  자체의 표준 동작. TUI 세션은 redraw가 대부분 in-place(net-zero scroll)라
        //  resize 중에도 scrollback 잔재가 거의 안 쌓임.)
        // 메트릭은 백엔드의 렌더 폰트에서 파생 — 메트릭과 렌더가 절대 어긋나지 않게.
        let font = backend.renderFont
        let glyphSize = ("M" as NSString).size(withAttributes: [.font: font])
        let cellW = max(glyphSize.width, 1)
        // NSLayoutManager().defaultLineHeight는 NSTextView가 실제 쓰는 line height와
        // 미세하게 다른 경우가 있어 rows가 over-report됨. 실제 layout 결과로 측정.
        let cellH = max(measuredLineHeight(font: font), 1)
        cellMetrics = CellMetrics(width: cellW, height: cellH)
        let inset = backend.contentInset
        // width: bounds.width 대신 backend.contentSize.width — vertical scroller가
        // 항상 보이는 시스템 설정에서 ~15pt 차지하기 때문.
        let usableW = max(backend.contentSize.width - inset.width * 2, 1)

        // height: 두 가지 윈도우 모드를 구분해야 한다. 식별자는 tabbingMode —
        // compact 모드는 네이티브 탭을 끄고(`.disallowed`) 커스텀 탭바를 쓴다.
        //
        //   • compact (커스텀 탭바): 탭바는 평범한 subview라 우리 backing view를 이미
        //     그만큼 줄여놨다 → backend.contentSize.height가 곧 실제 그릴 수 있는
        //     높이다. 그대로 쓴다 (위 usableW와 대칭). window.contentRect에서 매직
        //     상수를 빼던 옛 경로는 탭바 실제 높이(38)와 어긋나(36) rows를 1 더 잡아,
        //     Claude Code 같은 TUI의 맨 아래 줄이 화면 밖으로 밀려 스크롤해야 보였다.
        //
        //   • standard (네이티브 탭바): bounds/contentRect가 2탭↔1탭 토글에 따라
        //     ~36pt 들락날락한다 → 매 토글마다 SIGWINCH로 prompt가 다시 그려져 누적됨.
        //     탭바가 숨어있을 때(1 tab)도 그 높이를 미리 빼서 rows를 일정하게 고정한다.
        let usableH: CGFloat
        if window?.tabbingMode == .disallowed {
            usableH = max(backend.contentSize.height - inset.height * 2, 1)
        } else {
            let isTabBarVisible = (window?.tabbedWindows?.count ?? 1) >= 2
            let stableContentHeight: CGFloat
            if let w = window {
                let cr = w.contentRect(forFrameRect: w.frame).height
                stableContentHeight = isTabBarVisible ? cr : cr - tabBarReservation
            } else {
                stableContentHeight = bounds.height
            }
            usableH = max(stableContentHeight - inset.height * 2, 1)
        }
        let cols = max(Int(floor(usableW / cellW)), 1)
        let rows = max(Int(floor(usableH / cellH)), 1)

        let gridStale = (session.grid.cols != cols || session.grid.rows != rows)
        let ptyStale = (lastPtySize == nil || lastPtySize! != (cols, rows))
        if !gridStale && !ptyStale { return }   // genuine no-op layout

        if inLiveResize {
            // Visual reflow only; defer SIGWINCH so the shell doesn't redraw and
            // accumulate its prompt on every drag frame. The final size is flushed
            // (with SIGWINCH) at viewDidEndLiveResize.
            if gridStale { session.resizeGridOnly(cols: cols, rows: rows) }
        } else {
            session.resize(cols: cols, rows: rows)   // grid + PTY (SIGWINCH)
            lastPtySize = (cols, rows)
        }
    }
    /// The size last reported to the PTY (SIGWINCH). Tracked separately from the
    /// grid so a live resize can reflow the grid every frame while flushing the
    /// PTY size only once, on drag end.
    private var lastPtySize: (cols: Int, rows: Int)?

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
        if row < scrollbackCount { return session.grid.scrollback[row].cells }
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
        } else if selectionAnchor != nil, selectionHead != nil {
            // 드래그/더블·트리플 클릭으로 선택이 완성됨 → copy-on-select(옵션, 기본 ON).
            copySelectionIfEnabled()
        }
    }

    /// copy-on-select가 켜져 있고 비어있지 않은 선택이 있으면 클립보드에 복사.
    private func copySelectionIfEnabled() {
        guard session.config.copyOnSelect,
              let text = selectedText(), !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
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
        let pos = backend.cell(at: winPt, grid: session.grid, metrics: cellMetrics)
        updateHoverFromCell((pos.row, pos.col))
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

    // 2-finger 가로 스와이프 → 탭 전환 제스처 상태 (제스처당 1회 결정).
    private var swipeDecided = false
    private var swipeHorizontal = false
    private var swipeAccumX: CGFloat = 0
    private var swipeVelocity: CGFloat = 0   // smoothed recent dx/event for flick detection

    public override func scrollWheel(with event: NSEvent) {
        // 2-finger 가로 스와이프 → 탭 전환 (트랙패드 한정, 앱이 마우스를 캡처 중이 아닐 때).
        // 가로 제스처는 여기서 소비한다(터미널은 가로 스크롤이 없음). 세로 스크롤은
        // 그대로 backend로 흘려보낸다.
        if event.hasPreciseScrollingDeltas, session.mouseReportingMode == 0,
           handleTabSwipe(event) {
            return
        }
        // Mouse reporting 활성 시 휠은 button 64/65 코드로 PTY 전달 (tmux/Claude Code 등).
        if isMouseReportingEvent(event) {
            forwardWheelToMouseReporting(event)
            return
        }
        // Metal backend consumes the wheel itself (applies the delta + redraws).
        // Legacy returns false → fall through to NSScrollView's native handling,
        // whose didLiveScroll observer updates followingBottom.
        if !backend.handleScrollWheel(event) {
            super.scrollWheel(with: event)
        }
    }

    /// Mouse-reporting 앱(TUI: Claude Code/tmux 등)에 휠을 button 64/65로 전달.
    /// 트랙패드 정밀 델타는 이벤트가 매우 촘촘해서 이벤트당 1개씩 보내면 TUI가 폭주한다.
    /// 포인트 델타를 누적해 ≈1줄(`scrollSpeed`로 조절)마다 한 번씩만 보낸다.
    private func forwardWheelToMouseReporting(_ event: NSEvent) {
        let delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            // 마우스 휠: 델타가 이미 줄/notch 단위 → 한 번씩.
            guard abs(delta) > 0.1 else { return }
            sendMouseEventToPTY(event: event, button: delta > 0 ? 64 : 65, pressed: true)
            return
        }
        // 트랙패드 정밀 스크롤: 누적 후 임계치마다 한 번.
        if event.phase.contains(.began) { wheelReportAccum = 0 }
        wheelReportAccum += delta
        let speed = max(0.25, min(4.0, session.config.scrollSpeed))
        let pointsPerTick = max(2, cellMetrics.height / speed)
        var ticks = 0
        while abs(wheelReportAccum) >= pointsPerTick, ticks < 8 {
            sendMouseEventToPTY(event: event, button: wheelReportAccum > 0 ? 64 : 65, pressed: true)
            wheelReportAccum += wheelReportAccum > 0 ? -pointsPerTick : pointsPerTick
            ticks += 1
        }
    }

    /// Part of a horizontal tab-swipe gesture? Decides horizontal-vs-vertical once
    /// per gesture; accumulates dx; on release past a threshold switches tab via
    /// the responder chain (same cross-slide as ⌘← / ⌘→). Returns true when the
    /// event belongs to a horizontal swipe (and is consumed); false lets the
    /// caller fall through to vertical scrollback.
    private func handleTabSwipe(_ event: NSEvent) -> Bool {
        guard let handler = window?.windowController as? TabSwipeHandler else { return false }
        switch event.phase {
        case .began:
            swipeDecided = false
            swipeHorizontal = false
            swipeAccumX = 0
            swipeVelocity = 0
            return false   // .began carries ~0 delta; decide on the first .changed
        case .changed:
            if !swipeDecided {
                let dx = abs(event.scrollingDeltaX), dy = abs(event.scrollingDeltaY)
                guard dx > 0.1 || dy > 0.1 else { return false }   // no movement yet
                swipeDecided = true
                swipeHorizontal = dx > dy
            }
            guard swipeHorizontal else { return false }
            swipeAccumX += event.scrollingDeltaX
            // Exponentially-smoothed recent speed → distinguishes a flick from a drag.
            swipeVelocity = swipeVelocity * 0.6 + event.scrollingDeltaX * 0.4
            handler.tabSwipeUpdate(translation: swipeAccumX)   // live: host drags neighbor in
            return true
        case .ended, .cancelled:
            defer { swipeDecided = false; swipeHorizontal = false; swipeAccumX = 0; swipeVelocity = 0 }
            guard swipeHorizontal else { return false }
            handler.tabSwipeEnd(translation: swipeAccumX, velocity: swipeVelocity)
            return true
        default:
            return swipeHorizontal   // consume trailing/momentum events of a horizontal swipe
        }
    }

    private func refreshFollowingBottomFlag() {
        followingBottom = isScrolledToBottom(tolerance: 4.0)
    }

    /// follow 중일 때 스크롤이 안착해야 할 Y. renderNow()의 follow 로직과 동일하게
    /// 계산해 애니메이션/즉시 스크롤이 같은 지점으로 가도록 통일. 이미 적절한 위치면
    /// nil(스크롤 불필요).
    private func followTargetY() -> CGFloat? {
        let grid = session.grid
        let inset = backend.contentInset.height
        if grid.isAltScreenActive || grid.hasUsedSyncOutput || grid.hasContentBelowCursor {
            // Alt-screen / primary-screen TUI(Claude Code 등) — 라이브 grid 전체가
            // 보이도록 grid-top을 viewport-top에 anchor. (rows*cellH ≤ visHeight라
            // grid가 항상 viewport에 들어감 → 하단 안 잘림.)
            //
            // Claude Code는 alt-screen도 sync-output도 안 쓰지만 입력 줄 아래에 status를
            // 상주시킨다(hasContentBelowCursor). cursor-visible 정책은 cursor만 보이면
            // 멈춰서 그 status를 fold 밑으로 잘랐다 — grid-top anchor로 해소.
            //
            // 중요: scrollback이 늘어나는 TUI(sync output 누적)에서 cursor-visible
            // 정책을 쓰면, cursor가 이미 보일 때 scroll을 안 해서 매 프레임 scrollback이
            // 1줄씩 늘 때마다 grid가 fold 밑으로 밀려 새 내용이 안 보이는 회귀가 생김.
            // grid-top anchor는 scrollback.count에 묶여 있어 늘어나는 만큼 같이 내려가
            // 새 내용(grid 하단)을 항상 보여줌. layout()의 anchor와도 일치.
            return CGFloat(grid.scrollback.count) * cellMetrics.height + inset
        }
        // 일반 셸 — cursor-visible 정책.
        let visHeight = backend.viewportHeight
        let cursorViewRow = grid.scrollback.count + grid.cursorRow
        let cursorY = CGFloat(cursorViewRow) * cellMetrics.height + inset
        let cursorBottom = cursorY + cellMetrics.height
        let curY = backend.scrollYPixels
        if cursorBottom > curY + visHeight {
            return cursorBottom - visHeight
        } else if cursorY < curY {
            return cursorY
        }
        return nil // cursor 이미 가시 영역 — 스크롤 불필요.
    }

    /// 사용자 입력(키 입력/붙여넣기)이 들어오면 follow를 재개하고 cursor/뷰포트로
    /// **부드럽게** 점프. 위로 스크롤해 history를 보던 중 키를 누르면 작업 위치로 복귀.
    private func snapToCursorOnUserInput() {
        followingBottom = true
        guard let targetY = followTargetY() else { return }
        let curY = backend.scrollYPixels
        guard abs(targetY - curY) > 0.5 else { return }
        isSnappingToCursor = true
        NSAnimationContext.runAnimationGroup({ [weak self] _ in
            NSAnimationContext.current.duration = 0.18
            NSAnimationContext.current.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self?.backend.setScrollY(targetY, animated: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.isSnappingToCursor = false
            // 애니메이션 동안 들어온 새 출력까지 반영해 정확히 안착.
            if self.followingBottom, let y = self.followTargetY() {
                self.backend.setScrollY(y, animated: false)
            } else {
                self.backend.reflectScroll()
            }
            self.refreshCursorOverlayNow()
        })
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
            cells = grid.scrollback[pos.row].cells
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
        let pos = backend.cell(at: event.locationInWindow, grid: session.grid, metrics: cellMetrics)
        return (pos.row, pos.col)
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
                cells = grid.scrollback[r].cells
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

        for (i, line) in grid.scrollback.enumerated() { scan(line.cells, row: i) }
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
        let visHeight = backend.viewportHeight
        let rowY = CGFloat(row) * cellMetrics.height + backend.contentInset.height
        // 매치를 viewport 1/3 지점에 두어 위아래 맥락이 보이게.
        let targetY = max(0, rowY - visHeight / 3)
        backend.setScrollY(targetY, animated: false)
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

    /// ⌘↑ — 현재 화면 위쪽의 가장 가까운 프롬프트(OSC 133;A 마크)로 스크롤.
    @objc public func jumpToPreviousPrompt(_ sender: Any?) { jumpPrompt(forward: false) }
    /// ⌘↓ — 현재 화면 아래쪽의 가장 가까운 프롬프트로 스크롤.
    @objc public func jumpToNextPrompt(_ sender: Any?) { jumpPrompt(forward: true) }

    private func jumpPrompt(forward: Bool) {
        let grid = session.grid
        let cellH = max(cellMetrics.height, 1)
        let sbCount = Int(grid.scrollback.count)
        let pushCount = Int(grid.scrollbackPushCount)
        // 마크 절대 줄 번호 → 현재 unified row. evict된 마크(음수)는 제외.
        let markRows = session.promptMarks
            .map { sbCount + Int($0) - pushCount }
            .filter { $0 >= 0 }
            .sorted()
        guard !markRows.isEmpty else { NSSound.beep(); return }
        let topRow = Int((backend.scrollYPixels / cellH).rounded())
        let target = forward ? markRows.first(where: { $0 > topRow })
                             : markRows.last(where: { $0 < topRow })
        guard let t = target else { NSSound.beep(); return }
        followingBottom = false
        backend.setScrollY(max(0, CGFloat(t) * cellH), animated: true)
    }

    private func setZoom(_ multiplier: CGFloat) {
        fontSizeMultiplier = max(0.5, min(4.0, multiplier))
        let baseSize = session.config.fontSize
        let newSize = max(6, baseSize * fontSizeMultiplier)
        // zoom도 cascade 포함된 폰트 사용 — Menlo 등에서도 Nerd glyph fallback 유지.
        let font = fontWithNerdFallback(family: session.config.fontFamily, size: newSize)
        backend.setRenderFont(font)
        // 폰트 크기가 바뀌면 새 cell 크기에 맞춰 cols/rows를 다시 계산하고 grid+PTY를
        // 리사이즈(SIGWINCH)해 셸/TUI가 새 너비/높이로 reflow하게 한다. 윈도우 리사이즈와
        // 동일 경로 — reportSizeIfChanged가 backend.renderFont에서 메트릭을 파생하므로
        // 폰트만 바꿔두면 cols/rows가 정확히 다시 잡힌다.
        lastRenderedVersion = .max
        reportSizeIfChanged()
        // cols/rows가 안 바뀌는 작은 zoom 단계에서도 새 폰트로 즉시 다시 그린다.
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
        snapToCursorOnUserInput()
        session.write(data)
    }

    /// App-injected hook for app-level key equivalents (tab nav, prompt jump,
    /// close, quit) resolved against the user's configurable keybindings. Returns
    /// true if it handled the event. `damson.app` installs this once at startup so
    /// remapped shortcuts take effect live. When nil — the engine used standalone
    /// (e.g. embedded in cmux) — the built-in defaults below run unchanged.
    ///
    /// Contract: if a hook is installed it is *authoritative* for app-level keys.
    /// Returning false means "not an app shortcut" → fall through to the menu /
    /// responder chain (so ⌘T, ⌘C, … still reach their menu items). The engine's
    /// own hardcoded fallback is skipped, so a user can genuinely unbind a key.
    public static var appKeyEquivalentHook: ((DamsonSurfaceView, NSEvent) -> Bool)?

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let hook = DamsonSurfaceView.appKeyEquivalentHook {
            if hook(self, event) { return true }
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘⇧] / ⌘⇧[ — next / previous tab. Dispatched here (not via the menu's
        // key equivalent) because NSMenu's matching for shifted punctuation is
        // unreliable: charactersIgnoringModifiers applies Shift so the event's
        // char is "}"/"{", and punctuation — unlike letters — doesn't case-fold,
        // so a "]"/"[" menu item never matches. Route through the responder chain
        // (the tab controller owns the action), exactly as ⌘W does below. Match
        // both glyph forms to be independent of how Shift is reported.
        if mods == [.command, .shift] {
            switch event.charactersIgnoringModifiers {
            case "}", "]":
                if NSApp.sendAction(Selector(("selectNextTab:")), to: nil, from: self) { return true }
            case "{", "[":
                if NSApp.sendAction(Selector(("selectPreviousTab:")), to: nil, from: self) { return true }
            default: break
            }
            return super.performKeyEquivalent(with: event)
        }
        // ⌘← / ⌘→ — previous / next tab. Arrow keys carry .function + .numericPad
        // in their modifier flags, so test command-only AFTER stripping those (a
        // plain `mods == .command` check fails for arrows). Matched by keyCode
        // (123/124, layout-independent); routed through the responder chain like
        // ⌘⇧[ / ⌘⇧]. (⌘+arrow is otherwise a no-op — not forwarded to the PTY.)
        if mods.contains(.command), mods.isDisjoint(with: [.shift, .control, .option]) {
            switch event.keyCode {
            case 123:
                if NSApp.sendAction(Selector(("selectPreviousTab:")), to: nil, from: self) { return true }
            case 124:
                if NSApp.sendAction(Selector(("selectNextTab:")), to: nil, from: self) { return true }
            case 126: // ⌘↑ — 이전 프롬프트로 점프 (OSC 133 마크)
                jumpToPreviousPrompt(self); return true
            case 125: // ⌘↓ — 다음 프롬프트로 점프
                jumpToNextPrompt(self); return true
            default:
                break
            }
        }
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
        // 입력 중엔 cursor가 안 깜빡이게 — 즉시 보이게 + phase 리셋.
        resetBlinkPhase()

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd는 performKeyEquivalent에서 처리. 여기에 도달했다는 건 어떤 메뉴/단축키도
        // 안 잡았다는 뜻이고, IME에 보내거나 PTY로 보내면 의도와 다른 동작이 생김 → 무시.
        if mods.contains(.command) {
            return
        }

        // 실제 입력 키(타이핑/화살표/Enter/Ctrl-조합 등)는 작업 위치로 점프시킨다.
        // 위로 스크롤해 history를 보던 중이라도 키를 누르면 cursor 쪽으로 복귀.
        snapToCursorOnUserInput()

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

        // Shift+Enter → 입력란 줄바꿈(submit 안 함). AppKit은 Shift+Enter도 일반
        // Enter와 똑같이 `insertNewline:`으로 보내 둘 다 CR이 나가므로, Claude Code
        // 같은 TUI가 구분을 못 해 Shift+Enter를 제출로 처리한다. 여기서 가로채 ESC CR을
        // 보낸다 — claude의 `/terminal-setup`이 Apple Terminal에 심는 매핑과 동일해
        // "줄바꿈"으로 인식된다. (IME 조합 중이면 통과시켜 정상 commit.)
        if mods == .shift, event.keyCode == 36 || event.keyCode == 76,
           markedText.isEmpty {
            session.write(Data([0x1B, 0x0D])) // ESC CR
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
        return backend.cursorScreenRect(grid: session.grid, metrics: cellMetrics, window: window)
    }

    /// Current rendered frame as an image, for tab/pane transition snapshots.
    /// The Metal backend re-renders its current grid offscreen because
    /// `cacheDisplay` can't read the `CAMetalLayer` framebuffer (it returns a
    /// blank frame). `nil` if there's nothing to capture yet.
    public func captureMetalImage() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0, let cg = backend.captureImage() else { return nil }
        return NSImage(cgImage: cg, size: bounds.size)
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
            guard let self else { return }
            self.renderScheduled = false
            // DEC 2026 Synchronized Output: sync frame(BSU…ESU)이 진행 중이면
            // 부분적으로(torn) 적용된 grid를 화면에 내보내지 않는다. PTY read가 프레임
            // 중간을 가르면 옛 내용 위에 새 내용이 절반만 그려져 "덮어쓰기/중복"처럼
            // 보였음. ESU(\e[?2026l) 직후의 gridChanged가 완성된 프레임을 atomic하게
            // present한다. ESU가 끝내 안 오는 비정상 앱을 대비해 안전 타이머로 강제 flush.
            if self.session.grid.inSyncOutputMode {
                self.armSyncFlush()
                return
            }
            self.renderNow()
        }
    }

    /// sync frame이 ESU 없이 syncFlushDeadline을 넘기면 freeze를 막기 위해 강제 present.
    private func armSyncFlush() {
        if syncFlushScheduled { return }
        syncFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + syncFlushDeadline) { [weak self] in
            guard let self else { return }
            self.syncFlushScheduled = false
            if self.session.grid.inSyncOutputMode {
                self.renderNow()
            }
        }
    }

    private var lastRenderedSelectionKey: String = ""
    private var lastRenderedFindKey: String = ""
    private var lastRenderedHoverKey: String = ""
    private var lastRenderedBlinkKey: String = ""

    private func renderNow() {
        let grid = session.grid
        let selKey = selectionKey()
        let findKey = "\(findQuery)|\(findMatchesByRow.count)|\(activeMatchIndex)"
        let hoverKey: String = {
            guard let h = hoveredURL else { return "" }
            return "\(h.row)|\(h.colRange.lowerBound)|\(h.colRange.upperBound)"
        }()
        // blink phase — ON일 때 phase 토글마다 re-render 되도록 dedupe key에 포함.
        let blinkKey = session.config.cursorBlink ? (cursorBlinkVisible ? "1" : "0") : "x"
        if grid.version == lastRenderedVersion
            && markedText == lastRenderedMarkedText
            && selKey == lastRenderedSelectionKey
            && findKey == lastRenderedFindKey
            && hoverKey == lastRenderedHoverKey
            && blinkKey == lastRenderedBlinkKey {
            return
        }
        lastRenderedVersion = grid.version
        lastRenderedMarkedText = markedText
        lastRenderedSelectionKey = selKey
        lastRenderedFindKey = findKey
        lastRenderedHoverKey = hoverKey
        lastRenderedBlinkKey = blinkKey

        // 백엔드가 한 프레임을 그림(ensureLayout까지 끝냄). dedupe는 위에서 완료.
        backend.render(grid: grid, config: session.config, state: currentRenderState(),
                       metrics: cellMetrics)

        // 자동 follow 스크롤은 followingBottom일 때만. 사용자가 위로 스크롤해
        // history를 보는 중이면 새 출력/커서 이동이 와도 위치를 건드리지 않는다
        // (단 scrollback evict 시 content-anchor 보정은 아래에서 따로 처리).

        // alt-screen 전환(primary↔alt)이 일어나면 follow를 재개한다. vim/htop 등은
        // 진입 시 그 화면을, 종료 시 셸 바닥을 항상 보여줘야 하므로 사용자가 이전에
        // 위로 스크롤해 둔 상태(followingBottom == false)라도 여기서 복귀시킨다.
        if grid.isAltScreenActive != lastAltScreenActive {
            lastAltScreenActive = grid.isAltScreenActive
            followingBottom = true
        }

        // 이번 렌더에서 scrollback 최상단이 몇 줄 evict 됐는지 = 사용자가 보던 콘텐츠가
        // 위로 밀린 양. (scrollback에 append는 viewport 바로 위에 쌓여 기존 history의
        // 화면 위치를 바꾸지 않으므로, content drift는 오직 top eviction에서만 발생.)
        // Underflow-safe: a narrowing reflow can grow scrollback.count past
        // scrollbackPushCount (reflow rebuilds scrollback without bumping the push
        // counter). `linesEvictedFromTop` clamps to 0 instead of trapping the
        // UInt64 subtraction — the resize crash.
        let evictedTotal = grid.linesEvictedFromTop
        let evictedSinceLast = evictedTotal >= lastEvictedTotal
            ? Int(evictedTotal - lastEvictedTotal) : 0
        lastEvictedTotal = evictedTotal

        var scrolled = false
        if followingBottom {
            // 키 입력 점프 애니메이션 중엔 위치를 애니메이션이 소유 — 즉시 scroll 안 함.
            // alt 화면은 viewport top anchor, 그 외(일반 셸/Claude Code 등)는
            // cursor-visible 정책. followTargetY()가 두 경우를 통일해 계산.
            if !isSnappingToCursor, let targetY = followTargetY() {
                backend.setScrollY(targetY, animated: false)
                scrolled = true
            }
        } else if evictedSinceLast > 0 {
            // 사용자가 위로 스크롤해 history를 보는 중 — scrollback이 evict된 만큼
            // 스크롤도 따라 올려서 보던 줄이 화면 같은 위치에 머물게(content-anchor).
            let curY = backend.scrollYPixels
            let adjusted = max(0, curY - CGFloat(evictedSinceLast) * cellMetrics.height)
            backend.setScrollY(adjusted, animated: false)
            scrolled = true
        }
        // else: 사용자가 스크롤로 올려둔 위치를 그대로 둔다 (강제 바닥 고정 안 함).
        if !scrolled { backend.reflectScroll() }

        refreshCursorOverlayNow()
    }

    private func currentRenderState() -> RenderState {
        let active: (row: Int, range: Range<Int>)? =
            (activeMatchIndex >= 0 && activeMatchIndex < findMatchesOrdered.count)
            ? findMatchesOrdered[activeMatchIndex] : nil
        return RenderState(
            markedText: markedText,
            selectionAnchor: selectionAnchor.map { GridPos(row: $0.row, col: $0.col) },
            selectionHead: selectionHead.map { GridPos(row: $0.row, col: $0.col) },
            findMatchesByRow: findMatchesByRow,
            activeFindRow: active?.row,
            activeFindRange: active?.range,
            hoveredRow: hoveredURL?.row,
            hoveredRange: hoveredURL?.colRange,
            cursorBlinkEnabled: session.config.cursorBlink,
            cursorBlinkVisible: cursorBlinkVisible
        )
    }

    private func refreshCursorOverlayNow() {
        if let overlay = backend.cursorOverlay(grid: session.grid, config: session.config,
                                               state: currentRenderState(), metrics: cellMetrics) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.frame = overlay.frame
            cursorLayer.backgroundColor = overlay.color.cgColor
            cursorLayer.isHidden = false
            CATransaction.commit()
        } else {
            cursorLayer.isHidden = true
        }
    }

}

extension Notification.Name {
    /// Posted when the global perf HUD is toggled; every `DamsonSurfaceView` mirrors it.
    static let damsonPerfHUDToggled = Notification.Name("DamsonPerfHUDToggled")
    /// Posted when the Apple Metal HUD is toggled.
    static let damsonAppleHUDToggled = Notification.Name("DamsonAppleHUDToggled")
}
