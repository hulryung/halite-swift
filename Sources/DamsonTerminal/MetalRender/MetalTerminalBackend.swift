import AppKit
import Metal
import simd

/// The `CAMetalLayer` renderer: draws cell backgrounds, selection/find
/// highlights, glyphs (mask + color-emoji pages), line overlays
/// (underline/strikethrough/hyperlink/hover), the block/bar/underline cursor,
/// and the IME preedit overlay as instanced quads. Owns scroll geometry
/// (wheel/momentum/rubber-band + smooth programmatic eases) and host↔cell
/// coordinate mapping (mouse hit-testing + IME cursor-rect).
///
/// The sole render backend (the legacy `NSTextView` path was retired at P6).
final class MetalTerminalBackend: TerminalRenderBackend {
    private let metalView = MetalContentView(frame: .zero)
    private let md: MetalDevice

    private(set) var renderFont: NSFont
    private var config: DamsonConfig
    private var metrics = CellMetrics(width: 8, height: 16)

    /// Scalar vertical scroll position. Consumes OS wheel/momentum deltas
    /// directly (NSScrollView-style); programmatic jumps (snap-to-cursor) ease via
    /// `animLink`.
    private var scroll = ScrollModel()
    /// Read-only mirror of `scroll.current` (content px from top, 0 = top), kept
    /// so the many existing `scrollY` reads (coord map, instance positions) work.
    private var scrollY: CGFloat { scroll.current }
    /// Transient display link for smooth programmatic eases (macOS 14+).
    private lazy var animLink = AnimationLink(view: metalView)
    /// Cached from the last render so `contentHeight` is correct between frames.
    private var lastTotalRows: Int = 0
    /// Snapshot of the last frame's inputs, so resize/backing-change redraws.
    private var lastGrid: Grid?
    private var lastState = RenderState()

    var onScrollGeometryChanged: (() -> Void)?
    var onUserScroll: (() -> Void)?

    /// The content inset, matched to the legacy textView's so cols/rows agree.
    private let inset = NSSize(width: 4, height: 4)

    /// Glyph atlas, rebuilt when font / cell size / backing scale changes.
    private var atlas: GlyphAtlas?
    private var atlasSignature = ""
    /// Offscreen scene render target, used only when a screen effect is active.
    /// Recreated when the drawable size changes.
    private var sceneTexture: MTLTexture?

    /// 렌더 레이트 리밋. `nextDrawable()`은 드로어블 풀(3)이 차면 다음 vsync까지 메인
    /// 스레드를 막아 PTY 입력을 starve한다. 직전 present 시각을 기억해 주사율 간격보다
    /// 자주 부르는 렌더는 coalesce(한 번만 예약 후 스킵)한다.
    private var lastPresentTime: CFTimeInterval = 0
    private var coalesceScheduled = false

    /// 스크롤/이즈 렌더 루프 상태. 스크롤 중에는 이벤트마다 동기 렌더하지 않고, 델타만
    /// 적용한 뒤 이 플래그를 세워 디스플레이 링크(`animLink`)가 vsync마다 최신 위치를 한 번
    /// 렌더하게 한다 — 프레임 간격이 균일해져 버벅임이 사라진다(asyncAfter 타이머 coalesce가
    /// vsync에 안 맞아 생기던 judder 제거). 활동이 멎으면 몇 프레임 뒤 링크를 멈춘다.
    private var scrollRenderPending = false
    private var renderLoopIdleTicks = 0
    private let renderLoopMaxIdleTicks = 4

    /// 프레임 페이싱 측정. env `DAMSON_FPS_LOG=1`면 1초마다 NSLog, perf HUD가 켜져 있으면
    /// 0.25초마다 `onPerfStats`로 문자열을 보낸다. 디스플레이 링크 틱 간격을 재므로 링크가
    /// 60인지 120인지, jitter가 있는지 그대로 드러난다.
    private let fpsLogEnabled = ProcessInfo.processInfo.environment["DAMSON_FPS_LOG"] != nil
    private var perfHUDActive = false
    /// 커스텀 perf HUD가 켜져 있을 때 **실제 present 간격**(초)을 보낸다 — 화면에 그려진
    /// 프레임 기준이라 Apple HUD의 FPS와 같은 값을 잰다(디스플레이 링크 틱 ≠ present).
    var onPerfSample: ((CFTimeInterval) -> Void)?
    private var lastHUDPresentTime: CFTimeInterval = 0
    private var fpsAccum: CFTimeInterval = 0
    private var fpsTicks = 0
    private var fpsRendered = 0
    private var fpsMin: CFTimeInterval = .infinity
    private var fpsMax: CFTimeInterval = 0

    /// 우리 커스텀 그래프 HUD on/off. 켜면 present마다 프레임 간격을 HUD로 보낸다(렌더
    /// 활동이 있을 때만 — Apple HUD와 동일하게 실제 화면 갱신 기준).
    func setPerfHUD(_ on: Bool) {
        perfHUDActive = on
        lastHUDPresentTime = 0
    }

    /// Apple Metal Performance HUD on/off — 공식 per-layer API. `MTL_HUD_ENABLED` 환경
    /// 변수(전역 주입) 대신 이걸 쓰면 앱에서 토글할 수 있고, env가 디스플레이 변경 시
    /// libMTLHud에서 크래시하던 경로를 피한다. "default"=표시, "none"=숨김.
    func setAppleHUD(_ on: Bool) {
        metalView.metalLayer.developerHUDProperties = on ? ["mode": "default"] : ["mode": "none"]
    }

    // MARK: glyph appear/disappear animation (cursor-area only)

    private struct GlyphAnimEntry {
        var appearing: Bool
        var start: CFTimeInterval
        var duration: CFTimeInterval
        var style: GlyphAnimStyle
        var cell: Cell          // disappear: the glyph to fade out (gone from the grid)
    }
    private struct CellPos: Hashable { var row: Int; var col: Int }   // unified-row coords
    private var glyphAnims: [CellPos: GlyphAnimEntry] = [:]
    /// Snapshot of the cursor row's cells at the last diffed grid version, used to
    /// detect single-cell typing / deleting near the cursor.
    private var prevCursorRow: [Cell] = []
    private var prevCursorRowIndex: Int = -1
    private var lastGlyphDiffVersion: UInt64 = .max
    /// reveal 페이싱 시계. 글자 애니메이션 시작 시각을 일정 간격으로 흘려보내 버스트
    /// 입력을 매끄러운 흐름으로 만든다. 입력이 멈추면 now보다 뒤처져 즉시 재생으로 복귀.
    private var glyphRevealClock: CFTimeInterval = 0
    private static let glyphRevealPace: CFTimeInterval = 0.022   // 글자 간 reveal 간격
    private static let glyphRevealMaxLead: CFTimeInterval = 0.07 // 커서 뒤 최대 지연(상한)
    private lazy var glyphAnimLink = AnimationLink(view: metalView)
    /// 애니메이션 렌더를 ~60fps로 상한(주사율 무관). 120Hz면 격 프레임, 60Hz면 매
    /// 프레임 → 둘 다 60fps. 매 프레임 풀 렌더가 메인 스레드를 점유해 PTY 입력을
    /// starve하는 것을 막는다.
    private var lastGlyphRenderTime: CFTimeInterval = 0
    private static let glyphRenderMinInterval: CFTimeInterval = 0.013
    /// Ligature shaper, rebuilt alongside the atlas (same font). Used only when
    /// `config.ligatures` is on.
    private var lineShaper: LineShaper?

    private func ensureAtlas() {
        let scale = metalView.metalLayer.contentsScale
        let sig = "\(renderFont.fontName)|\(renderFont.pointSize)|\(metrics.width)|\(metrics.height)|\(scale)"
        if sig != atlasSignature || atlas == nil {
            atlas = GlyphAtlas(device: md.device, font: renderFont,
                               cellW: metrics.width, cellH: metrics.height, scale: scale)
            let bold = NSFontManager.shared.convert(renderFont, toHaveTrait: .boldFontMask)
            lineShaper = LineShaper(baseFont: renderFont, boldFont: bold)
            atlasSignature = sig
        }
    }

    init?(config: DamsonConfig) {
        guard let md = MetalDevice.shared else { return nil }
        self.md = md
        self.config = config
        self.renderFont = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        metalView.onNeedsDisplay = { [weak self] in self?.redrawLast() }
    }

    // MARK: - TerminalRenderBackend

    var contentView: NSView { metalView }
    // No native scroller — full bounds is usable. (May differ from legacy by the
    // scroller width; a one-time reflow on toggle is acceptable for the dev path.)
    var contentSize: NSSize { metalView.bounds.size }
    var contentInset: NSSize { inset }

    func applyConfig(_ config: DamsonConfig) {
        self.config = config
        renderFont = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        redrawLast()
    }

    func setRenderFont(_ font: NSFont) {
        renderFont = font
        redrawLast()
    }

    private func coordMap() -> CoordinateMap {
        CoordinateMap(cellW: metrics.width, cellH: metrics.height, inset: inset, scrollY: scrollY)
    }

    /// Snap a point value to the nearest device pixel, so adjacent cell quads
    /// share an identical edge (no sub-pixel seam between fills).
    private func snap(_ v: CGFloat) -> CGFloat {
        let s = metalView.metalLayer.contentsScale
        return s > 0 ? (v * s).rounded() / s : v
    }

    private func redrawLast() {
        guard let grid = lastGrid else { return }
        // 동기 출력(DEC 2026 BSU…ESU) 진행 중엔 백엔드 자체 재그리기(coalesce/애니메이션/
        // 레이아웃)를 건너뛴다. 그러지 않으면 redraw burst 중간의 불완전한 grid가
        // present돼 화면이 깜빡인다. 완성된 프레임은 ESU 후 host의 renderNow(또는 150ms
        // 안전 플러시)가 그린다.
        if grid.inSyncOutputMode { return }
        render(grid: grid, config: config, state: lastState, metrics: metrics)
    }

    // MARK: - vsync-aligned scroll / ease render loop

    /// 디스플레이 링크 루프를 (없으면) 시작한다. 스크롤 델타가 들어왔거나 프로그램적
    /// 이즈가 시작될 때 호출. 이미 돌고 있으면 그대로 둔다.
    private func ensureRenderLoop() {
        guard !animLink.isRunning else { return }
        renderLoopIdleTicks = 0
        let started = animLink.start { [weak self] dt in
            self?.renderLoopTick(dt: dt) ?? true
        }
        if !started {
            // macOS < 14: 디스플레이 링크 없음 → 이즈는 즉시 안착시키고 한 번만 동기 렌더.
            if scroll.animating { _ = scroll.step(dt: 10) }   // 큰 dt → 타깃으로 즉시 수렴
            scrollRenderPending = false
            redrawLast()
            onScrollGeometryChanged?()
        }
    }

    /// 한 vsync 프레임. 이즈가 진행 중이면 한 스텝 전진시키고, (이즈든 새 스크롤 델타든)
    /// 변화가 있으면 최신 위치를 정확히 한 번 렌더한다. 활동이 멎으면 몇 프레임 뒤 멈춘다.
    /// 반환값: 루프를 멈춰야 하면 true.
    private func renderLoopTick(dt: CFTimeInterval) -> Bool {
        let easing = scroll.animating
        if easing { _ = scroll.step(dt: CGFloat(dt)) }

        if fpsLogEnabled { measureFrame(dt: dt, rendered: easing || scrollRenderPending) }

        if easing || scrollRenderPending {
            scrollRenderPending = false
            renderLoopIdleTicks = 0
            // vsync에 이미 정렬됨 → throttle 없이 즉시 렌더.
            if let grid = lastGrid, !grid.inSyncOutputMode {
                render(grid: grid, config: config, state: lastState, metrics: metrics,
                       throttled: false)
            }
            onScrollGeometryChanged?()
        } else {
            renderLoopIdleTicks += 1
        }
        // 이즈가 진행 중이면 계속. 아니면 유휴 유예가 지나면 멈춘다(제스처+모멘텀 종료).
        if scroll.animating { return false }
        return renderLoopIdleTicks > renderLoopMaxIdleTicks
    }

    /// env `DAMSON_FPS_LOG=1`일 때 1초마다 NSLog (HUD는 onPerfSample로 별도 처리).
    private func measureFrame(dt: CFTimeInterval, rendered: Bool) {
        fpsAccum += dt
        fpsTicks += 1
        if rendered { fpsRendered += 1 }
        fpsMin = min(fpsMin, dt)
        fpsMax = max(fpsMax, dt)
        guard fpsAccum >= 1.0 else { return }
        let screenMax = metalView.window?.screen?.maximumFramesPerSecond ?? -1
        NSLog("damson scroll: link %.0f Hz (avg %.1fms, min %.1f, max %.1f) — rendered %d/%d — screen %d Hz",
              Double(fpsTicks) / fpsAccum, fpsAccum / Double(fpsTicks) * 1000,
              fpsMin * 1000, fpsMax * 1000, fpsRendered, fpsTicks, screenMax)
        fpsAccum = 0; fpsTicks = 0; fpsRendered = 0; fpsMin = .infinity; fpsMax = 0
    }

    // MARK: glyph appear/disappear

    /// 그리드가 바뀐 프레임에 커서 행을 직전 스냅샷과 비교해, 소량(≤4) 변화면
    /// 생성/소멸 애니메이션을 등록한다. 행이 바뀌었거나(Enter/스크롤) 대량 변화면
    /// (라인 redraw/붙여넣기) 건너뛴다 — 타이핑/지우기만 잡기 위해서.
    private func diffGlyphChanges(grid: Grid) {
        let appear = config.glyphAppear
        let disappear = config.glyphDisappear
        guard appear != .none || disappear != .none else {
            prevCursorRowIndex = -1
            return
        }
        // grid 버전이 그대로면(애니메이션 틱 등) 재diff하지 않는다.
        guard grid.version != lastGlyphDiffVersion else { return }
        lastGlyphDiffVersion = grid.version

        let urow = grid.scrollback.count + grid.cursorRow
        let cur: [Cell] = (0..<grid.cols).map { grid.cell(row: grid.cursorRow, col: $0) }
        defer { prevCursorRow = cur; prevCursorRowIndex = urow }

        // 직전과 같은 커서 행일 때만 비교(행이 바뀌면 타이핑이 아님).
        guard prevCursorRowIndex == urow, prevCursorRow.count == cur.count else { return }

        var appears: [Int] = []                 // 글리프가 새로 생긴 열
        var disappears: [Int: Cell] = [:]       // 글리프가 사라진 열 → 옛 셀
        for c in 0..<cur.count {
            let beforeBlank = prevCursorRow[c].char == " "
            let afterBlank = cur[c].char == " "
            if !afterBlank, beforeBlank || prevCursorRow[c].char != cur[c].char {
                appears.append(c)
            } else if afterBlank, !beforeBlank {
                disappears[c] = prevCursorRow[c]
            }
        }
        guard !appears.isEmpty || !disappears.isEmpty else { return }

        // 키를 누르고 있으면 에코가 묶여 한 프레임에 여러 글자가 한꺼번에 들어온다.
        // 커서에 인접한 연속(run)이면 최대 16자까지 애니메이션하되, 시작 시각을 reveal
        // 시계로 일정 간격(pace) 흘려보내 버스트를 매끄러운 흐름으로 만든다. 입력이
        // 멈추면 시계가 now보다 뒤처져 즉시 재생으로 복귀한다(단발 입력은 지연 0).
        let cap = 16
        let cursorCol = grid.cursorCol
        let now = CACurrentMediaTime()

        // 타이핑: 커서 왼쪽으로 cursorCol-1에서 끝나는 연속 run (커서 우측 변화 =
        // autosuggestion 등은 무시).
        let typed = appears.filter { $0 < cursorCol }.sorted()
        let typingRun = !typed.isEmpty && typed.last! == cursorCol - 1
            && (typed.last! - typed.first!) == typed.count - 1 && typed.count <= cap
        // 백스페이스: 커서에서 시작하는 연속 run.
        let cleared = disappears.keys.filter { $0 >= cursorCol }.sorted()
        let backRun = !cleared.isEmpty && cleared.first! == cursorCol
            && (cleared.last! - cleared.first!) == cleared.count - 1 && cleared.count <= cap

        // 지연이 상한을 넘으면 배치 시작에서만 시계를 now로 리셋(catch-up)해 지연을
        // 묶는다. 배치 안에서는 항상 pace 간격으로 진행시켜 글자들이 한꺼번에 뭉치지
        // 않게 한다. (예전엔 글자마다 now+상한으로 clamp해서 상한에 닿은 배치가 통째로
        // 풀려 ~4자씩 멈칫거렸다.)
        if glyphRevealClock > now + Self.glyphRevealMaxLead { glyphRevealClock = now }
        func nextRevealStart() -> CFTimeInterval {
            let start = max(now, glyphRevealClock)
            glyphRevealClock = start + Self.glyphRevealPace
            return start
        }

        if appear != .none, typingRun {
            let dur = appear.duration(appearing: true)
            for c in typed {                    // 왼쪽(오래된 글자)부터 차례로
                glyphAnims[CellPos(row: urow, col: c)] = GlyphAnimEntry(
                    appearing: true, start: nextRevealStart(), duration: dur, style: appear, cell: cur[c])
            }
        }
        if disappear != .none, backRun {
            let dur = disappear.duration(appearing: false)
            for c in cleared.reversed() {       // 오른쪽(먼저 지워진 글자)부터 차례로
                glyphAnims[CellPos(row: urow, col: c)] = GlyphAnimEntry(
                    appearing: false, start: nextRevealStart(), duration: dur, style: disappear, cell: disappears[c]!)
            }
        }
        if !glyphAnims.isEmpty { startGlyphAnimLink() }
    }

    private func pruneGlyphAnims() {
        guard !glyphAnims.isEmpty else { return }
        let now = CACurrentMediaTime()
        glyphAnims = glyphAnims.filter { now - $0.value.start < $0.value.duration }
    }

    private func startGlyphAnimLink() {
        let ok = glyphAnimLink.start { [weak self] _ in
            guard let self else { return true }
            self.pruneGlyphAnims()
            if self.glyphAnims.isEmpty { return true }
            // 매 프레임 풀 렌더는 메인 스레드를 점유해 PTY 입력을 starve한다(입력이
            // 6~9자씩 버스트로 풀림). 시간 기반 ~60fps 상한으로 입력에 메인 스레드를
            // 양보하면 키 반복 자연 속도로 한 글자씩 매끄럽게 흐른다. (주사율 무관 —
            // 120Hz는 격 프레임, 60Hz는 매 프레임.)
            let t = CACurrentMediaTime()
            if t - self.lastGlyphRenderTime >= Self.glyphRenderMinInterval {
                self.lastGlyphRenderTime = t
                self.redrawLast()
            }
            return self.glyphAnims.isEmpty
        }
        if !ok { glyphAnims.removeAll() }   // macOS < 14: no link → instant (no anim)
    }

    /// (row,col) 셀의 생성 애니메이션 진행도(0~1). 없으면 nil.
    private func appearProgress(row: Int, col: Int) -> Float? {
        guard let a = glyphAnims[CellPos(row: row, col: col)], a.appearing else { return nil }
        let p = Float((CACurrentMediaTime() - a.start) / a.duration)
        return max(0, min(1, p))
    }

    /// 프로토콜 진입점 — 타이핑/grid 변경 등 비주기 경로. throttle 적용.
    func render(grid: Grid, config: DamsonConfig, state: RenderState, metrics: CellMetrics) {
        render(grid: grid, config: config, state: state, metrics: metrics, throttled: true)
    }

    func render(grid: Grid, config: DamsonConfig, state: RenderState, metrics: CellMetrics,
                throttled: Bool) {
        self.config = config
        self.metrics = metrics
        self.lastGrid = grid
        self.lastState = state
        self.lastTotalRows = grid.scrollback.count + grid.rows
        // Keep the scroll clamp current as content grows/shrinks (re-clamps if the
        // viewport now extends past the new bottom).
        scroll.maxY = max(0, contentHeight - viewportHeight)

        let layer = metalView.metalLayer
        // 리사이즈 중엔 레이아웃 트랜잭션과 함께 동기 present — 레이트 리밋 미적용.
        let syncPresent = layer.presentsWithTransaction
        // 렌더를 display 주사율로 cap한다. nextDrawable()은 드로어블 풀(3)이 차면 다음
        // vsync까지 메인 스레드를 막는데(타이핑 중 ~16ms 블록 → 입력 starve), 빠른
        // 연속 입력이 vsync보다 자주 렌더를 부르면 풀이 고갈돼 블록이 잦아진다. 직전
        // present로부터 주사율 간격이 안 지났으면 이번 렌더는 한 번만 coalesce 예약하고
        // 건너뛴다(단발 입력은 간격이 충분해 즉시 렌더 → 저지연 유지).
        // display 주사율 간격(120Hz→8.3ms, 60Hz→16.7ms). 그보다 자주 부르는 렌더는 스킵.
        let fps = max(60, metalView.window?.screen?.maximumFramesPerSecond ?? 60)
        let minRenderInterval = 1.0 / CFTimeInterval(fps)
        // 디스플레이 링크가 부르는 렌더(스크롤/이즈)는 이미 vsync에 정렬돼 있으므로
        // throttle을 건너뛴다. throttle은 타이핑 등 비주기 입력의 nextDrawable 블록만 막는다.
        if throttled, !syncPresent {
            let since = CACurrentMediaTime() - lastPresentTime
            if since < minRenderInterval {
                if !coalesceScheduled {
                    coalesceScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + (minRenderInterval - since)) {
                        [weak self] in
                        guard let self else { return }
                        self.coalesceScheduled = false
                        self.redrawLast()
                    }
                }
                return
            }
        }

        ensureAtlas()
        // 커서 근처 타이핑/지우기를 감지해 글자 생성/소멸 애니메이션을 등록(grid가
        // 바뀐 프레임에만). 이후 buildInstances가 이 진행도를 반영한다.
        diffGlyphChanges(grid: grid)
        // 배경 불투명도 < 1이면 레이어를 투명으로 둬 뒤(데스크톱/블러)가 비치게 한다.
        let opacity = max(0.2, min(1.0, config.backgroundOpacity))
        layer.isOpaque = opacity >= 1.0
        guard layer.drawableSize.width > 0, let drawable = layer.nextDrawable() else {
            return
        }

        let (rawBg, glyphInstances, colorGlyphInstances, overlayInstances) =
            buildInstances(grid: grid, state: state)
        let bgInstances = fadeBackgrounds(rawBg, opacity: opacity)

        // 화면 효과(CRT 등)가 켜져 있으면 터미널을 오프스크린 sceneTexture에 그린 뒤
        // 전체화면 post-fx 패스로 drawable에 합성한다. 꺼져 있으면 drawable에 직접.
        let effect = config.screenEffect
        let sceneTarget: MTLTexture = effect.isActive
            ? ensureSceneTexture(matching: drawable.texture)
            : drawable.texture

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sceneTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor(config.theme.background, opacity: opacity)
        pass.colorAttachments[0].storeAction = .store

        guard let cmd = md.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = Uniforms(viewportSize: SIMD2<Float>(Float(metalView.bounds.width),
                                                           Float(metalView.bounds.height)))

        // Pass 1: cell backgrounds / selection / find / block cursor.
        if !bgInstances.isEmpty,
           let buf = md.device.makeBuffer(bytes: bgInstances,
                                          length: MemoryLayout<BgInstance>.stride * bgInstances.count,
                                          options: .storageModeShared) {
            enc.setRenderPipelineState(md.bgPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: bgInstances.count)
        }

        // Pass 2: glyphs (coverage atlas modulated by fg color).
        if !glyphInstances.isEmpty, let atlas = atlas,
           let buf = md.device.makeBuffer(bytes: glyphInstances,
                                          length: MemoryLayout<GlyphInstance>.stride * glyphInstances.count,
                                          options: .storageModeShared) {
            enc.setRenderPipelineState(md.glyphPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(md.glyphSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: glyphInstances.count)
        }

        // Pass 2b: color emoji (premultiplied BGRA color page, fg ignored).
        if !colorGlyphInstances.isEmpty, let colorTex = atlas?.colorTexture,
           let buf = md.device.makeBuffer(bytes: colorGlyphInstances,
                                          length: MemoryLayout<GlyphInstance>.stride * colorGlyphInstances.count,
                                          options: .storageModeShared) {
            enc.setRenderPipelineState(md.colorGlyphPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.setFragmentTexture(colorTex, index: 0)
            enc.setFragmentSamplerState(md.glyphSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: colorGlyphInstances.count)
        }

        // Pass 3: line overlays (underline / strikethrough / hyperlink / hover) —
        // same filled-quad pipeline as bg, drawn ON TOP so strikethrough shows.
        if !overlayInstances.isEmpty,
           let buf = md.device.makeBuffer(bytes: overlayInstances,
                                          length: MemoryLayout<BgInstance>.stride * overlayInstances.count,
                                          options: .storageModeShared) {
            enc.setRenderPipelineState(md.bgPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: overlayInstances.count)
        }

        enc.endEncoding()

        // Post-fx pass: sample the offscreen scene, apply the screen effect, write
        // the drawable. (Skipped entirely when the effect is off — sceneTarget is
        // the drawable itself and nothing above changed.)
        if effect.isActive,
           let sceneTex = sceneTexture,
           var params = effect.postFXParams(
               screenSize: SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height)),
               intensity: Float(config.screenEffectIntensity)),
           let fxEnc = cmd.makeRenderCommandEncoder(descriptor: postfxPass(drawable.texture)) {
            fxEnc.setRenderPipelineState(md.postfxPipeline)
            fxEnc.setFragmentTexture(sceneTex, index: 0)
            fxEnc.setFragmentSamplerState(md.glyphSampler, index: 0)
            fxEnc.setFragmentBytes(&params, length: MemoryLayout<PostFXParams>.stride, index: 0)
            fxEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            fxEnc.endEncoding()
        }

        // During live resize the layer presents with the layout transaction, so the
        // frame must be presented synchronously (after scheduling) — otherwise the
        // old drawable gets stretched to the new bounds before this frame lands
        // (visible flicker / stretched text). Outside resize, async present keeps
        // typing latency minimal.
        if syncPresent {
            cmd.commit()
            cmd.waitUntilScheduled()
            drawable.present()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }
        lastPresentTime = CACurrentMediaTime()
        // perf HUD: 실제 present 간격을 보낸다(화면에 그려진 프레임 기준 = Apple HUD와 동일).
        if perfHUDActive {
            if lastHUDPresentTime > 0 { onPerfSample?(lastPresentTime - lastHUDPresentTime) }
            lastHUDPresentTime = lastPresentTime
        }
    }

    /// Build bg fills + glyph quads + line overlays (underline/strikethrough) for
    /// the visible rows in one pass over cells. Overlay lines draw AFTER the glyph
    /// pass so a strikethrough sits on top of the text.
    private func buildInstances(grid: Grid, state: RenderState)
        -> (bg: [BgInstance], glyph: [GlyphInstance], colorGlyph: [GlyphInstance], overlay: [BgInstance]) {
        let map = coordMap()
        let cellH = max(metrics.height, 1)
        let totalRows = grid.scrollback.count + grid.rows
        let h = metalView.bounds.height
        let first = max(0, Int(floor((scrollY - inset.height) / cellH)))
        let last = min(totalRows - 1, Int(ceil((scrollY + h - inset.height) / cellH)))
        guard first <= last else { return ([], [], [], []) }

        var bg: [BgInstance] = []
        var glyphs: [GlyphInstance] = []
        var colorGlyphs: [GlyphInstance] = []   // emoji (sampled from the BGRA page)
        var overlay: [BgInstance] = []   // underline / strikethrough / hyperlink / hover lines
        bg.reserveCapacity((last - first + 1) * max(grid.cols, 1))
        glyphs.reserveCapacity(bg.capacity)

        let blockCursorRow = grid.cursorVisible ? (grid.scrollback.count + grid.cursorRow) : -1
        let blinkOff = state.cursorBlinkEnabled && !state.cursorBlinkVisible
        let blockCursorOn = grid.cursorShape == .block && state.markedText.isEmpty && !blinkOff

        // IME preedit overlay (composing text drawn at the cursor; the cells it
        // covers are hidden). Shown even when DECTCEM hid the cursor.
        let imeRow = grid.scrollback.count + grid.cursorRow
        let imeActive = !state.markedText.isEmpty
        let imeOverlayCols = imeActive ? state.markedText.reduce(0) { $0 + (Cell.isWide($1) ? 2 : 1) } : 0
        let imeAfterCol = min(grid.cursorCol + imeOverlayCols, grid.cols)

        for row in first...last {
            let cells = cellsForRow(grid: grid, unifiedRow: row)
            let cols = cells.count
            guard cols > 0 else { continue }
            let sel = selectedColumns(state, row: row, cols: cols)
            let finds = state.findMatchesByRow[row] ?? []
            let activeFind: Range<Int>? = (state.activeFindRow == row) ? state.activeFindRange : nil
            let hover: Range<Int>? = (state.hoveredRow == row) ? state.hoveredRange : nil

            // Ligatures (opt-in): shape the row once; shaped glyph ids replace the
            // per-char glyphs across each shapable run (bg/overlays stay per-cell).
            var shapedByStart: [Int: LineShaper.ShapedGlyph] = [:]
            var shapedCovered: Set<Int> = []
            if config.ligatures, let shaper = lineShaper {
                for sg in shaper.shape(in: cells) {
                    shapedByStart[sg.startCol] = sg
                    for c in sg.startCol..<(sg.startCol + sg.cellSpan) { shapedCovered.insert(c) }
                }
            }
            for col in 0..<cols {
                let cell = cells[col]
                if cell.isContinuation { continue }
                if imeActive, row == imeRow, col >= grid.cursorCol, col < imeAfterCol { continue }
                let isCursor = (row == blockCursorRow && col == grid.cursorCol && blockCursorOn)
                let wide = (col + 1 < cols && cells[col + 1].isContinuation)
                let wcells = wide ? 2 : 1
                // Pixel-snap cell edges so adjacent cells share the exact same
                // boundary — kills the sub-pixel dark seam between powerline /
                // background fills caused by fractional cell width.
                let x0 = snap(inset.width + CGFloat(col) * metrics.width)
                let x1 = snap(inset.width + CGFloat(col + wcells) * metrics.width)
                // 스냅은 콘텐츠 위치에만 적용하고(인접 행이 같은 snap 인자 → seam 없음),
                // scrollY는 스냅 밖에서 빼 서브픽셀로 남긴다 → 스크롤이 1px 양자화 없이 부드럽다.
                // (docs/SMOOTH-SCROLL.md: scrollYPixels는 정수일 필요 없음.)
                let y0 = snap(inset.height + CGFloat(row) * metrics.height) - scrollY
                let y1 = snap(inset.height + CGFloat(row + 1) * metrics.height) - scrollY
                let origin = SIMD2<Float>(Float(x0), Float(y0))
                let size = SIMD2<Float>(Float(x1 - x0), Float(y1 - y0))

                if let color = bgColor(cell: cell, col: col, sel: sel, finds: finds,
                                       activeFind: activeFind, isCursor: isCursor) {
                    let bgi = BgInstance(origin: origin, size: size, color: rgba(color))
                    bg.append(bgi)
                    // 빈 셀 위의 블록 커서는 overlay 패스(glyph 위)에도 한 번 더 그린다.
                    // 그래야 백스페이스로 사라지는 ghost 글리프가 커서를 가리지 않고,
                    // 셀 밖으로 미끄러지거나 퍼지는 부분만 커서 옆으로 보인다.
                    if isCursor, blockCursorOn, cell.char == " ", config.glyphDisappear != .none {
                        overlay.append(bgi)
                    }
                }
                let fg = fgColor(cell: cell, col: col, sel: sel, finds: finds,
                                 activeFind: activeFind, hover: hover, isCursor: isCursor)
                if shapedCovered.contains(col) {
                    // A shaped run owns this cell. Draw the shaped glyph id at its
                    // start column (spanning cellSpan), nothing for trailing cells.
                    // The bitmap is padded by `ligaturePadCells` on each side (so
                    // overflowing connecting forms aren't clipped); shift the quad
                    // left by the same pad and widen it to match.
                    if let sg = shapedByStart[col],
                       let region = atlas?.region(forGlyph: sg.glyph, bold: sg.bold, cellSpan: sg.cellSpan) {
                        let pad = CGFloat(GlyphRasterizer.ligaturePadCells) * metrics.width
                        let gx0 = snap(inset.width + CGFloat(col) * metrics.width - pad)
                        let gx1 = snap(inset.width + CGFloat(col + sg.cellSpan) * metrics.width + pad)
                        glyphs.append(GlyphInstance(
                            origin: SIMD2<Float>(Float(gx0), Float(y0)),
                            size: SIMD2<Float>(Float(gx1 - gx0), Float(y1 - y0)),
                            uvOrigin: region.uv.origin, uvSize: region.uv.size, color: rgba(fg)))
                    }
                } else if cell.char != " ", let region = atlas?.region(for: cell.char, bold: cell.attrs.bold, wide: wide) {
                    var inst = GlyphInstance(origin: origin, size: size,
                                             uvOrigin: region.uv.origin, uvSize: region.uv.size,
                                             color: rgba(fg))
                    // 생성 애니메이션(커서 근처): 진행도만큼 fade/scale.
                    if config.glyphAppear != .none, let p = appearProgress(row: row, col: col) {
                        inst = config.glyphAppear.apply(to: inst, appearing: true, p: p)
                    }
                    if region.isColor { colorGlyphs.append(inst) } else { glyphs.append(inst) }
                }

                // Line overlays. Underline color precedence (matching legacy):
                // hover blue > hyperlink fg α0.5 > SGR-underline fg. Strikethrough
                // is independent (cell fg), drawn through the glyph centre.
                let hovered = hover?.contains(col) ?? false
                if cell.attrs.underline || cell.attrs.strikethrough || cell.hyperlink != nil || hovered {
                    let thickness = max(1, (cellH * 0.08).rounded())
                    var underlineColor: NSColor? = cell.attrs.underline ? fg : nil
                    if cell.hyperlink != nil {
                        underlineColor = cell.attrs.resolvedColors(theme: config.theme).fg
                            .withAlphaComponent(0.5)
                    }
                    if hovered { underlineColor = .systemBlue }
                    if let uc = underlineColor {
                        let uy = snap(y1 - thickness)
                        overlay.append(BgInstance(origin: SIMD2<Float>(Float(x0), Float(uy)),
                                                  size: SIMD2<Float>(Float(x1 - x0), Float(y1 - uy)),
                                                  color: rgba(uc)))
                    }
                    if cell.attrs.strikethrough {
                        let sy = snap(y0 + (y1 - y0) * 0.5 - thickness * 0.5)
                        overlay.append(BgInstance(origin: SIMD2<Float>(Float(x0), Float(sy)),
                                                  size: SIMD2<Float>(Float(x1 - x0), Float(thickness)),
                                                  color: rgba(fg)))
                    }
                }
            }
        }
        if imeActive {
            appendIMEComposition(markedText: state.markedText, row: imeRow,
                                 startCol: grid.cursorCol, gridCols: grid.cols,
                                 map: map, bg: &bg, glyphs: &glyphs, colorGlyphs: &colorGlyphs)
        }
        // 소멸 애니메이션: grid엔 더 이상 없는 글자를 기억해 ghost로 fade/collapse.
        if config.glyphDisappear != .none, !glyphAnims.isEmpty {
            appendDisappearingGlyphs(first: first, last: last, glyphs: &glyphs,
                                     colorGlyphs: &colorGlyphs)
        }
        if config.showScrollbar { appendScrollbar(into: &overlay) }
        return (bg, glyphs, colorGlyphs, overlay)
    }

    /// grid에서 사라진 글자를 기억해둔 셀로 ghost glyph를 그려 소멸 애니메이션을 낸다.
    private func appendDisappearingGlyphs(first: Int, last: Int,
                                          glyphs: inout [GlyphInstance],
                                          colorGlyphs: inout [GlyphInstance]) {
        let now = CACurrentMediaTime()
        for (pos, a) in glyphAnims where !a.appearing {
            guard pos.row >= first, pos.row <= last, a.cell.char != " " else { continue }
            let p = Float((now - a.start) / a.duration)
            guard p < 1 else { continue }
            let style = a.style
            let wide = Cell.isWide(a.cell.char)
            let x0 = snap(inset.width + CGFloat(pos.col) * metrics.width)
            let x1 = snap(inset.width + CGFloat(pos.col + (wide ? 2 : 1)) * metrics.width)
            let y0 = snap(inset.height + CGFloat(pos.row) * metrics.height) - scrollY
            let y1 = snap(inset.height + CGFloat(pos.row + 1) * metrics.height) - scrollY
            guard let region = atlas?.region(for: a.cell.char, bold: a.cell.attrs.bold, wide: wide)
            else { continue }
            let fg = a.cell.attrs.resolvedColors(theme: config.theme).fg
            var inst = GlyphInstance(origin: SIMD2<Float>(Float(x0), Float(y0)),
                                     size: SIMD2<Float>(Float(x1 - x0), Float(y1 - y0)),
                                     uvOrigin: region.uv.origin, uvSize: region.uv.size,
                                     color: rgba(fg))
            inst = style.apply(to: inst, appearing: false, p: max(0, min(1, p)))
            if region.isColor { colorGlyphs.append(inst) } else { glyphs.append(inst) }

            // Burst: 폭죽처럼 작은 무지개 별이 바깥으로 터져나간다.
            if style == .burst {
                appendBurstParticles(centerX: CGFloat(x0 + x1) / 2,
                                     centerY: CGFloat(y0 + y1) / 2,
                                     seedRow: pos.row, seedCol: pos.col,
                                     p: max(0, min(1, p)), into: &glyphs)
            }
        }
    }

    /// burst 효과의 별 파티클 K개를 방출. 방향/속도는 (row,col,i) 해시로 결정(프레임마다
    /// 일관). easeOut으로 빠르게 퍼지다 감속, 중력으로 살짝 떨어지며 페이드.
    private func appendBurstParticles(centerX: CGFloat, centerY: CGFloat,
                                      seedRow: Int, seedCol: Int, p: Float,
                                      into glyphs: inout [GlyphInstance]) {
        // "*"(별표) — 모든 폰트에 확실히 있는 모노크롬 글리프. (✦ 등은 폰트에 없으면
        // 빈 칸으로 래스터돼 안 보였음.)
        guard let star = atlas?.region(for: "*", bold: true, wide: false), !star.isColor
        else { return }
        let cellH = max(metrics.height, 1)
        let count = 7
        let eased = 1 - (1 - p) * (1 - p)            // easeOut
        let maxDist = cellH * 2.4
        let starBase = cellH * 0.5
        func hashf(_ i: Int, _ salt: Int) -> Float {
            let v = sin(Float(seedRow * 73 + seedCol * 131 + i * 977 + salt * 17)
                        * 12.9898) * 43758.5453
            return v - floor(v)                       // 0..1
        }
        for i in 0..<count {
            let angle = (Float(i) / Float(count) + hashf(i, 1) * 0.12) * 2 * .pi
            let speed = 0.6 + 0.4 * hashf(i, 2)       // 0.6..1.0
            let dist = CGFloat(eased * speed) * maxDist
            let gravity = cellH * 1.1 * CGFloat(p * p)
            let px = centerX + CGFloat(cos(angle)) * dist
            let py = centerY + CGFloat(sin(angle)) * dist + gravity
            let sz = starBase * CGFloat(1 - 0.45 * p)
            guard sz > 0.5 else { continue }
            let alpha = CGFloat(max(0, 1 - p))        // 날아가며 페이드
            let hue = CGFloat(hashf(i, 3))
            let color = NSColor(hue: hue, saturation: 0.85, brightness: 1, alpha: 1)
            var rgbaColor = rgba(color)
            rgbaColor.w = Float(alpha)
            glyphs.append(GlyphInstance(
                origin: SIMD2<Float>(Float(px - sz / 2), Float(py - sz / 2)),
                size: SIMD2<Float>(Float(sz), Float(sz)),
                uvOrigin: star.uv.origin, uvSize: star.uv.size, color: rgbaColor))
        }
    }

    /// Draw the IME composing text at the cursor, cell-aligned, with the
    /// configured style (underline / background). Mirrors the legacy overlay.
    private func appendIMEComposition(markedText: String, row: Int, startCol: Int,
                                      gridCols: Int, map: CoordinateMap,
                                      bg: inout [BgInstance], glyphs: inout [GlyphInstance],
                                      colorGlyphs: inout [GlyphInstance]) {
        let style = config.imeStyle
        var col = startCol
        for ch in markedText {
            guard col < gridCols else { break }
            let wide = Cell.isWide(ch)
            let w = wide ? 2 : 1
            let rect = map.cellRectInView(row: row, col: col)
            let cellWpts = CGFloat(w) * metrics.width
            let origin = SIMD2<Float>(Float(rect.origin.x), Float(rect.origin.y))
            let size = SIMD2<Float>(Float(cellWpts), Float(rect.height))

            var fg = config.foregroundColor
            switch style {
            case .background:
                bg.append(BgInstance(origin: origin, size: size,
                                     color: rgba(NSColor.systemBlue.withAlphaComponent(0.45))))
                fg = .white
            case .both:
                bg.append(BgInstance(origin: origin, size: size,
                                     color: rgba(NSColor.systemBlue.withAlphaComponent(0.65))))
                fg = .white
            case .underline, .thickUnderline, .none:
                break
            }

            if ch != " ", let region = atlas?.region(for: ch, bold: false, wide: wide) {
                let inst = GlyphInstance(origin: origin, size: size,
                                         uvOrigin: region.uv.origin, uvSize: region.uv.size,
                                         color: rgba(fg))
                if region.isColor { colorGlyphs.append(inst) } else { glyphs.append(inst) }
            }

            let underline: (color: NSColor, thickness: CGFloat)?
            switch style {
            case .underline:
                underline = (config.foregroundColor.withAlphaComponent(0.7), max(1.5, rect.height * 0.06))
            case .thickUnderline, .both:
                underline = (config.foregroundColor, max(2, rect.height * 0.1))
            case .background, .none:
                underline = nil
            }
            if let u = underline {
                let uy = rect.maxY - u.thickness
                bg.append(BgInstance(origin: SIMD2<Float>(Float(rect.origin.x), Float(uy)),
                                     size: SIMD2<Float>(Float(cellWpts), Float(u.thickness)),
                                     color: rgba(u.color)))
            }
            col += w
        }
    }

    /// Append a right-edge scroll-position indicator (thumb) to the overlay pass.
    /// Overlay-style: thumb only, shown only when content exceeds the viewport;
    /// height ∝ visible fraction, position ∝ scroll offset. Display-only (not yet
    /// draggable).
    private func appendScrollbar(into overlay: inout [BgInstance]) {
        let viewportH = metalView.bounds.height
        let contentH = contentHeight
        guard viewportH > 1, contentH > viewportH + 1 else { return }   // nothing to scroll

        let barW: CGFloat = 6, rightInset: CGFloat = 2
        let trackTop = inset.height
        let trackH = max(viewportH - inset.height * 2, 1)
        let visibleFraction = min(viewportH / contentH, 1)
        let thumbH = max(24, trackH * visibleFraction)
        let maxScroll = max(contentH - viewportH, 1)
        let t = min(max(scrollY / maxScroll, 0), 1)
        let thumbY = snap(trackTop + (trackH - thumbH) * t)
        let x = snap(metalView.bounds.width - barW - rightInset)

        let color = config.foregroundColor.withAlphaComponent(0.35)
        overlay.append(BgInstance(origin: SIMD2<Float>(Float(x), Float(thumbY)),
                                  size: SIMD2<Float>(Float(barW), Float(snap(thumbH))),
                                  color: rgba(color)))
    }

    /// Resolved glyph foreground, mirroring the legacy fg rules.
    private func fgColor(cell: Cell, col: Int, sel: Range<Int>?, finds: [Range<Int>],
                         activeFind: Range<Int>?, hover: Range<Int>?, isCursor: Bool) -> NSColor {
        if isCursor { return config.theme.background }   // inverse over the cursor block
        if hover?.contains(col) ?? false { return .systemBlue }
        if (activeFind?.contains(col) ?? false) || finds.contains(where: { $0.contains(col) }) {
            return .black
        }
        let (fg, _) = cell.attrs.resolvedColors(theme: config.theme)
        return fg
    }

    /// Resolved fill for a cell, honoring the legacy priority
    /// (cursor > selection > active-find > find > cell bg), or nil = clear.
    private func bgColor(cell: Cell, col: Int, sel: Range<Int>?, finds: [Range<Int>],
                         activeFind: Range<Int>?, isCursor: Bool) -> NSColor? {
        if isCursor { return config.cursorColor }
        if sel?.contains(col) ?? false { return .selectedTextBackgroundColor }
        if activeFind?.contains(col) ?? false { return NSColor.systemOrange.withAlphaComponent(0.85) }
        if finds.contains(where: { $0.contains(col) }) { return NSColor.systemYellow.withAlphaComponent(0.6) }
        let (_, bg) = cell.attrs.resolvedColors(theme: config.theme)
        return bg
    }

    private func cellsForRow(grid: Grid, unifiedRow: Int) -> [Cell] {
        let sc = grid.scrollback.count
        if unifiedRow < sc { return grid.scrollback[unifiedRow].cells }
        let vp = unifiedRow - sc
        return (vp >= 0 && vp < grid.rows) ? grid.row(vp) : []
    }

    private func selectedColumns(_ state: RenderState, row: Int, cols: Int) -> Range<Int>? {
        guard let a = state.selectionAnchor, let h = state.selectionHead,
              !(a.row == h.row && a.col == h.col) else { return nil }
        let start = (a.row < h.row || (a.row == h.row && a.col < h.col)) ? a : h
        let end = (start.row == a.row && start.col == a.col) ? h : a
        if row < start.row || row > end.row { return nil }
        let lo = (row == start.row) ? start.col : 0
        let hi = (row == end.row) ? min(end.col, cols) : cols
        return lo < hi ? lo..<hi : nil
    }

    // MARK: - Cursor overlay (underline/bar — host draws on its own layer)

    func cursorOverlay(grid: Grid, config: DamsonConfig, state: RenderState, metrics: CellMetrics) -> CursorOverlay? {
        let shape = grid.cursorShape
        let blinkOff = state.cursorBlinkEnabled && !state.cursorBlinkVisible
        guard grid.cursorVisible, shape != .block, state.markedText.isEmpty, !blinkOff,
              let host = metalView.superview else { return nil }
        let map = coordMap()
        let row = grid.scrollback.count + grid.cursorRow
        let cell = map.cellRectInView(row: row, col: grid.cursorCol)
        guard metalView.bounds.intersects(cell) else { return nil }

        let cw = max(metrics.width, 1), ch = max(metrics.height, 1)
        var cursorW = cw
        if grid.cursorCol + 1 < grid.cols && grid.cursorRow < grid.rows {
            let r = grid.row(grid.cursorRow)
            if grid.cursorCol + 1 < r.count && r[grid.cursorCol + 1].isContinuation { cursorW = cw * 2 }
        }

        // Strip in flipped view coords, then convert to the host's (non-flipped) layer.
        let stripInView: NSRect
        switch shape {
        case .underline:
            let t = max(1.5, ch * 0.1)
            stripInView = NSRect(x: cell.minX, y: cell.maxY - t, width: cursorW, height: t)
        case .bar:
            let t = max(1.5, cw * 0.15)
            stripInView = NSRect(x: cell.minX, y: cell.minY, width: t, height: ch)
        case .block:
            return nil
        }
        let frameInHost = metalView.convert(stripInView, to: host)
        return CursorOverlay(frame: frameInHost, color: config.cursorColor)
    }

    // MARK: - Geometry (window coordinate space)

    func cell(at pointInHost: NSPoint, grid: Grid, metrics: CellMetrics) -> GridPos {
        let inView = metalView.convert(pointInHost, from: nil)
        let p = coordMap().cell(atViewPoint: inView)
        let maxRow = grid.scrollback.count + grid.rows - 1
        return GridPos(row: max(0, min(p.row, maxRow)), col: max(0, min(p.col, grid.cols)))
    }

    func cursorScreenRect(grid: Grid, metrics: CellMetrics, window: NSWindow) -> NSRect {
        let row = grid.scrollback.count + grid.cursorRow
        let cell = coordMap().cellRectInView(row: row, col: grid.cursorCol)
        let inWindow = metalView.convert(cell, to: nil)
        return window.convertToScreen(inWindow)
    }

    // MARK: - Scroll primitives

    var scrollYPixels: CGFloat { scrollY }
    var contentHeight: CGFloat { CGFloat(lastTotalRows) * max(metrics.height, 1) + inset.height * 2 }
    var viewportHeight: CGFloat { metalView.bounds.height }

    func setScrollY(_ y: CGFloat, animated: Bool) {
        scroll.maxY = max(0, contentHeight - viewportHeight)
        guard animated else {
            // Hard jump cancels any in-flight ease.
            animLink.stop()
            scroll.jump(to: y)
            redrawLast()
            onScrollGeometryChanged?()
            return
        }
        // Smooth ease toward the target, stepped by the unified vsync render loop.
        scroll.animate(to: y)
        guard scroll.animating else {        // already at target
            redrawLast()
            onScrollGeometryChanged?()
            return
        }
        ensureRenderLoop()
    }

    /// Consume a wheel/trackpad event: apply its delta and redraw. macOS delivers
    /// the gesture + a decaying momentum stream, so this yields smooth scroll +
    /// momentum without simulating a spring. A trackpad gesture past an edge
    /// rubber-bands (overshoot with resistance) and springs back when the gesture
    /// (and its momentum) ends. Always returns true (Metal owns the wheel; the host
    /// won't fall through to a no-op `super.scrollWheel`).
    func handleScrollWheel(_ event: NSEvent) -> Bool {
        scroll.maxY = max(0, contentHeight - viewportHeight)
        // applyWheel은 animating=false로 in-flight 이즈를 취소한다(직접 입력이 우선).
        let moved = scroll.applyWheel(deltaY: event.scrollingDeltaY,
                                      precise: event.hasPreciseScrollingDeltas,
                                      lineHeight: max(metrics.height, 1),
                                      viewport: viewportHeight)
        if moved {
            // 동기 렌더 대신 vsync 정렬 렌더를 요청 — 프레임 간격이 균일해 부드럽다.
            scrollRenderPending = true
            ensureRenderLoop()
            onUserScroll?()              // host updates followingBottom
        }
        // Spring a rubber-band overshoot back to the edge once the gesture ends.
        // (A following momentum event cancels this ease via animLink.stop above and
        // re-overshoots, so the final spring fires on momentumPhase .ended.)
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
        if ended && scroll.isOvershooting {
            setScrollY(scroll.clamp(scroll.current), animated: true)
        }
        return true
    }

    func ensureLayout() {}      // Metal has no async text layout to flush.
    func reflectScroll() {}     // No NSScroller to sync.

    // MARK: - Color

    /// 화면 효과용 오프스크린 씬 텍스처를 drawable 크기에 맞춰 보장(없거나 크기가
    /// 다르면 재생성). drawable과 같은 픽셀 포맷 + render target/shader read.
    private func ensureSceneTexture(matching target: MTLTexture) -> MTLTexture {
        if let t = sceneTexture, t.width == target.width, t.height == target.height {
            return t
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalDevice.pixelFormat,
            width: max(1, target.width), height: max(1, target.height), mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        let tex = md.device.makeTexture(descriptor: td)!
        sceneTexture = tex
        return tex
    }

    /// post-fx 패스 디스크립터. fullscreen 삼각형이 모든 픽셀을 덮어쓰므로 load는 dontCare.
    private func postfxPass(_ drawable: MTLTexture) -> MTLRenderPassDescriptor {
        let p = MTLRenderPassDescriptor()
        p.colorAttachments[0].texture = drawable
        p.colorAttachments[0].loadAction = .dontCare
        p.colorAttachments[0].storeAction = .store
        return p
    }

    /// 배경 clear 색. `opacity` < 1이면 premultiplied 투명 배경(rgb×O, a=O)으로 만들어
    /// 레이어가 뒤(데스크톱/블러)와 합성하게 한다. opacity=1이면 기존과 동일(불투명).
    private func clearColor(_ c: NSColor, opacity: CGFloat = 1.0) -> MTLClearColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        let o = Double(max(0, min(1, opacity)))
        return MTLClearColor(red: Double(s.redComponent) * o, green: Double(s.greenComponent) * o,
                             blue: Double(s.blueComponent) * o, alpha: o)
    }

    /// 배경 fill 인스턴스(배경/선택/커서)의 알파에만 불투명도를 곱한다. 텍스트·이모지·
    /// 밑줄 overlay는 건드리지 않아 불투명하게 남는다. opacity=1이면 입력 그대로 반환.
    private func fadeBackgrounds(_ insts: [BgInstance], opacity: CGFloat) -> [BgInstance] {
        guard opacity < 1.0 else { return insts }
        let o = Float(max(0, min(1, opacity)))
        return insts.map { inst in
            var m = inst
            m.color.w *= o
            return m
        }
    }

    private func rgba(_ c: NSColor) -> SIMD4<Float> {
        let s = c.usingColorSpace(.sRGB) ?? c
        return SIMD4<Float>(Float(s.redComponent), Float(s.greenComponent),
                            Float(s.blueComponent), Float(s.alphaComponent))
    }

    /// Capture the current on-screen frame as a `CGImage` by re-rendering the
    /// last grid/state at the live view size + scroll into an offscreen texture.
    /// `cacheDisplay` can't read a `CAMetalLayer` framebuffer, so tab/pane
    /// transition snapshots route through here instead of going blank.
    func captureImage() -> CGImage? {
        guard let grid = lastGrid else { return nil }
        return offscreenImage(scale: metalView.metalLayer.contentsScale,
                              grid: grid, state: lastState)
    }

    /// Render `grid`/`state` through the real `buildInstances` + shader passes
    /// into an offscreen texture sized to the current `metalView` bounds, then
    /// read it back as a `CGImage`. No window, no drawable, no Screen Recording.
    /// Uses the live `scrollY`/`metrics`, so the bitmap matches what's on screen.
    private func offscreenImage(scale: CGFloat, grid: Grid, state: RenderState) -> CGImage? {
        let wPts = metalView.bounds.width, hPts = metalView.bounds.height
        guard wPts > 0, hPts > 0 else { return nil }
        metalView.metalLayer.contentsScale = scale
        ensureAtlas()

        let pw = max(1, Int((wPts * scale).rounded()))
        let ph = max(1, Int((hPts * scale).rounded()))
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalDevice.pixelFormat, width: pw, height: ph, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let tex = md.device.makeTexture(descriptor: td) else { return nil }

        let (bg, glyphs, colorGlyphs, overlay) = buildInstances(grid: grid, state: state)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor(config.theme.background)
        pass.colorAttachments[0].storeAction = .store
        guard let cmd = md.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = Uniforms(viewportSize: SIMD2<Float>(Float(wPts), Float(hPts)))

        func drawBg(_ insts: [BgInstance]) {
            guard !insts.isEmpty,
                  let buf = md.device.makeBuffer(bytes: insts,
                                                 length: MemoryLayout<BgInstance>.stride * insts.count,
                                                 options: .storageModeShared) else { return }
            enc.setRenderPipelineState(md.bgPipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: insts.count)
        }
        func drawGlyphs(_ insts: [GlyphInstance], pipeline: MTLRenderPipelineState, texture: MTLTexture?) {
            guard !insts.isEmpty, let texture,
                  let buf = md.device.makeBuffer(bytes: insts,
                                                 length: MemoryLayout<GlyphInstance>.stride * insts.count,
                                                 options: .storageModeShared) else { return }
            enc.setRenderPipelineState(pipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setVertexBuffer(buf, offset: 0, index: 1)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(md.glyphSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: insts.count)
        }
        drawBg(bg)
        drawGlyphs(glyphs, pipeline: md.glyphPipeline, texture: atlas?.texture)
        drawGlyphs(colorGlyphs, pipeline: md.colorGlyphPipeline, texture: atlas?.colorTexture)
        drawBg(overlay)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let bytesPerRow = pw * 4
        var raw = [UInt8](repeating: 0, count: bytesPerRow * ph)
        tex.getBytes(&raw, bytesPerRow: bytesPerRow,
                     from: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(raw) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // bgra8Unorm in memory == little-endian 32-bit with alpha first → BGRA.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    #if DEBUG
    /// Headless render-parity capture for the smoke test: size the window-less
    /// view to `cols`×`rows`, set the grid, and render from the top via the same
    /// offscreen path the live capture uses.
    func renderToCGImage(grid: Grid, config: DamsonConfig, state: RenderState,
                         metrics: CellMetrics, cols: Int, rows: Int, scale: CGFloat) -> CGImage? {
        self.config = config
        self.metrics = metrics
        let wPts = inset.width * 2 + CGFloat(cols) * metrics.width
        let hPts = inset.height * 2 + CGFloat(rows) * metrics.height
        metalView.frame = NSRect(x: 0, y: 0, width: wPts, height: hPts)
        self.lastGrid = grid
        self.lastState = state
        self.lastTotalRows = grid.scrollback.count + grid.rows
        return offscreenImage(scale: scale, grid: grid, state: state)
    }
    #endif
}

