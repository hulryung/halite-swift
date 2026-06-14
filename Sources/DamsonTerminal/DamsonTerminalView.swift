import AppKit
import Combine
import SwiftUI

/// One-line entry point you can drop into SwiftUI.
/// Same API for both cmux and damson.app.
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

/// Host-side receiver for the 2-finger horizontal swipe tab switch. The terminal
/// surface is a library and knows nothing about tabs/windows, so it relays the
/// gesture to the host (the window controller) through this protocol.
/// `translation` is the accumulated horizontal movement (pt, right = positive).
/// The host drags the neighboring tab in live and, on end, commits/cancels based
/// on a threshold.
public protocol TabSwipeHandler: AnyObject {
    func tabSwipeUpdate(translation: CGFloat)
    /// `velocity`: recent horizontal speed at release (pt per event, ~per frame),
    /// so a fast flick commits even if it didn't travel the distance threshold.
    func tabSwipeEnd(translation: CGFloat, velocity: CGFloat)
}

/// Owner of input (key/IME/mouse), selection, find, and follow policy. Drawing,
/// scrolling, and coordinate conversion are delegated to `MetalTerminalBackend`
/// (the `CAMetalLayer` instanced renderer). Key events are caught here and
/// forwarded via `session.write(_:)`.
public final class DamsonSurfaceView: NSView, NSTextInputClient {
    public let session: DamsonSession

    public var isActive: Bool = true {
        didSet {
            guard isActive != oldValue else { return }
            needsDisplay = true
            // Keep the cursor from blinking in an inactive (dimmed) pane — start/stop the timer.
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
    /// Whether the DEC 2026 sync output flush safety timer is already scheduled.
    private var syncFlushScheduled = false
    /// Time (seconds) before forcing a present when a sync frame stays open too
    /// long without an ESU. Normal Claude Code/Ink frames get their ESU within a
    /// single-digit number of ms, so this timer almost never fires — a freeze-prevention safety net.
    private let syncFlushDeadline: TimeInterval = 0.15
    private var lastRenderedVersion: UInt64 = .max
    /// The marked text at the last render. Used for comparison to force a
    /// re-render when only the marked text is cleared without a grid change
    /// (e.g. BS-cancel).
    private var lastRenderedMarkedText: String = ""
    /// Cached cell metrics. Updated by `reportSizeIfChanged`, used by render for
    /// paragraph style. A single value derived solely from the font — shared by
    /// both backends to avoid a SIGWINCH on toggle.
    private var cellMetrics = CellMetrics(width: 1, height: 1)

    /// Text currently being composed by the IME. When non-empty, shown as a
    /// visual overlay at the cursor position. The actual PTY send only happens
    /// when `insertText` (commit) arrives.
    private var markedText: String = ""

    /// The `NSEvent` currently being processed. Set by `keyDown`, used in IME
    /// callbacks (setMarkedText/insertText) to determine "which key triggered
    /// this commit/preedit". Used to detect a BS-cancel spurious commit.
    private var currentKeyEvent: NSEvent?

    /// Swallow this keyDown cycle's doCommand(deleteBackward:) once. Used in
    /// BS-cancel handling when the IME callback has already cleared the marked
    /// text and we must not send another BS to the PTY.
    private var swallowNextDeleteCommand: Bool = false

    /// Flag set while startup IME warmup is in progress. With just `.app`
    /// registration there's a residual race where the first TSM↔IMK IPC
    /// handshake only happens at the user's first keystroke, leaking the first
    /// jamo. As soon as the view becomes first responder, we push a synthetic
    /// dummy event through inputContext to wake the IPC up early. Any
    /// insertText/doCommand called back during this window is not sent to the PTY.
    private var isWarmingUpIME: Bool = false
    private var didWarmupIME: Bool = false

    /// Selection state. Coordinates are (textViewRow, col) — textViewRow is `scrollback.count + viewportRow`.
    /// `anchor` is the mouseDown position, `head` is the endpoint that follows mouseDragged.
    private var selectionAnchor: (row: Int, col: Int)?
    private var selectionHead: (row: Int, col: Int)?
    /// Last plain-click cell. Persists after a click clears the live selection so a
    /// following Shift-click has a point to extend from (click A, then Shift-click B
    /// selects A…B — the standard terminal/macOS behavior). Same coordinate space as
    /// `selectionAnchor`, so it stays valid as the buffer scrolls.
    private var selectionOrigin: (row: Int, col: Int)?
    /// Accumulated trackpad precision wheel delta (points). Used to throttle wheel delivery to mouse-reporting apps.
    private var wheelReportAccum: CGFloat = 0

    /// Cursor overlay for the DECSCUSR underline/bar shapes. Placed on the host
    /// layer — positioned here once the backend computes the geometry (the
    /// coordinate basis matches the original). The block shape is handled by the
    /// backend render's inverse-cell, so this layer is only visible for underline/bar.
    private let cursorLayer = CALayer()

    /// cursor blink — when config.cursorBlink is ON, a timer toggles the phase.
    /// When blinkVisible=false the cursor is hidden (block: inverse not applied, underline/bar: layer hidden).
    private var cursorBlinkTimer: Timer?
    private var cursorBlinkVisible = true

    /// The currently applied font zoom multiplier. 1.0 is the default. Changed via Cmd+= / Cmd+- / Cmd+0.
    private var fontSizeMultiplier: CGFloat = 1.0

    /// The active find overlay + current query + match positions.
    private var findOverlay: FindOverlayView?
    private var findQuery: String = ""
    /// Search matches — `[textViewRow: [colRange...]]`. Used to draw highlights at render time.
    private var findMatchesByRow: [Int: [Range<Int>]] = [:]
    /// Matches flattened into a list sorted by textViewRow → col. Used for Cmd+G next/prev navigation.
    private var findMatchesOrdered: [(row: Int, range: Range<Int>)] = []
    /// The currently active match index (cycled with Cmd+G). -1 means none selected.
    private var activeMatchIndex: Int = -1

    /// Cmd-hover URL display state. When the mouse hovers over a URL with Cmd
    /// held, that URL is shown brightly underlined + a pointing-hand cursor.
    /// A click only opens the URL while Cmd is held.
    private var cmdKeyDown: Bool = false
    private var hoveredURL: (url: URL, segments: [(row: Int, colRange: Range<Int>)])?
    private var mouseTrackingArea: NSTrackingArea?

    /// "Follow live output" tracking flag. Becomes false when the user scrolls
    /// up, true again when they reach the bottom. At layout() time the new frame
    /// has already been applied, so re-measuring isScrolledToBottom() there is
    /// inaccurate — this flag must be kept separately to reliably preserve the
    /// bottom anchor when the area changes due to a tab bar toggle.
    private var followingBottom: Bool = true

    /// The previous value of the alt-screen active state. Used to detect a
    /// primary↔alt transition and resume follow (e.g. entering/exiting vim —
    /// while an app occupies the screen we must always show that area).
    private var lastAltScreenActive: Bool = false

    /// The "cumulative evicted line count" (= scrollbackPushCount - scrollback.count) at the previous render.
    /// When the top of scrollback is evicted while the user has scrolled up, the
    /// content they're viewing shifts upward; used to scroll up by the same
    /// amount to maintain the content-anchor.
    private var lastEvictedTotal: UInt64 = 0

    /// Whether a key-input jump animation is in progress. While true, the
    /// immediate follow-scroll in renderNow()/layout() is skipped — otherwise an
    /// echo render would teleport the animation to its end position, hiding the
    /// smooth jump.
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

        // underline/bar cursor overlay layer — placed on the host layer (same as the original).
        cursorLayer.zPosition = 100
        cursorLayer.isHidden = true
        layer?.addSublayer(cursorLayer)

        // The backend calls back on scroll changes — boundsDidChange (including
        // programmatic) repositions the cursor overlay, didLiveScroll (user
        // interaction) updates follow-bottom.
        // (The two roles of the original scrollViewDidScroll, split apart as-is.)
        backend.onScrollGeometryChanged = { [weak self] in self?.refreshCursorOverlayNow() }
        backend.onUserScroll = { [weak self] in
            DispatchQueue.main.async { self?.refreshFollowingBottomFlag() }
        }
        // Subscribe to the perf HUD toggle broadcast — when on, this surface also shows the overlay.
        NotificationCenter.default.addObserver(
            forName: .damsonPerfHUDToggled, object: nil, queue: .main
        ) { [weak self] _ in self?.applyPerfHUD() }
        if DamsonSurfaceView.isPerfHUDEnabled { applyPerfHUD() }
        NotificationCenter.default.addObserver(
            forName: .damsonAppleHUDToggled, object: nil, queue: .main
        ) { [weak self] _ in self?.applyAppleHUD() }
        // Always apply the initial state explicitly — keep the Apple HUD (which
        // MTL_HUD_ENABLED env auto-enables) off at startup (only toggled on via
        // ⌃⌘J). Default isAppleHUDEnabled == false.
        applyAppleHUD()

        gridSubscription = session.gridChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.scheduleRender()
            }

        configSubscription = session.$config
            .dropFirst() // the initial value is already applied at init
            .receive(on: RunLoop.main)
            .sink { [weak self] cfg in
                self?.applyConfig(cfg)
            }

        // BEL (\a) — visual flash + system beep. session.onBell may be called
        // off-main, so hop to main.
        session.onBell = { [weak self] in
            DispatchQueue.main.async { self?.handleBell() }
        }

        // Initial one-time render.
        scheduleRender()
        updateBlinkTimer()
    }

    // MARK: - Cursor blink

    /// Start/stop the timer per config.cursorBlink. Toggles the phase on a ~530ms cycle.
    private func updateBlinkTimer() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = nil
        cursorBlinkVisible = true
        // Only blink when blink is ON and this pane is active. An inactive (dimmed) pane has a static cursor.
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

    /// On key input, show the cursor immediately + reset the blink phase (so it doesn't blink while typing).
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

    /// BEL handling — a brief visual flash overlay + system beep.
    private func handleBell() {
        NSSound.beep()
        // Visual flash: briefly show a translucent white layer over everything, then fade out.
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
        // Remove after the animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            flash.removeFromSuperlayer()
        }
    }

    /// Background color of the host view layer. When background opacity < 1, keep
    /// it clear (= transparent) so the metal layer's transparent background shows
    /// through to behind the window (desktop/blur). At 1.0, the theme background color as before.
    private static func hostBackground(_ config: DamsonConfig) -> NSColor {
        config.backgroundOpacity < 1.0 ? .clear : config.backgroundColor
    }

    /// Settings change → session.updateConfig → enters here and applies textView/colors/scrollback.
    private func applyConfig(_ config: DamsonConfig) {
        backend.applyConfig(config)
        layer?.backgroundColor = Self.hostBackground(config).cgColor
        lastReportedSize = nil
        // Invalidate the dedupe key, then synchronously re-render — so a new
        // font/color is immediately reflected in textStorage even without a grid.version change.
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
        // Force content to re-layout to the new width immediately, even during a
        // live resize. Without this, the old layout sticks during a drag and the screen appears not to update.
        backend.ensureLayout()
        reportSizeIfChanged()
        // If the user has scrolled up (followingBottom == false), don't touch the
        // position even in a layout pass (resize, etc.) — so the history they're
        // viewing isn't forced to snap to the bottom. Also don't touch it during
        // a key-input jump animation (isSnappingToCursor).
        if followingBottom && !isSnappingToCursor {
            if session.grid.isAltScreenActive || session.grid.hasUsedSyncOutput
                || session.grid.hasContentBelowCursor {
                // grid-top anchor — shows the entire live grid (including the bottom footer).
                // Claude Code (with a status line residing below the cursor) takes this path, resolving the clipping.
                scrollViewportToAltTop()
            } else {
                scrollViewportToBottom()
            }
        }
        // Draw the new grid content immediately right after a resize, too.
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

    /// When alt-screen is active — skip the primary scrollback and anchor at the alt viewport top.
    /// (On entering alt-screen, self.scrollback still holds the primary's history,
    ///  so without scrolling, the top of textStorage = primary scrollback is
    ///  shown and the alt content is drawn below it — a regression where the user
    ///  had to scroll up to see it.)
    private func scrollViewportToAltTop() {
        backend.ensureLayout()
        let viewportTop = CGFloat(session.grid.scrollback.count) * cellMetrics.height
            + backend.contentInset.height
        backend.setScrollY(viewportTop, animated: false)
    }

    private func scrollViewportToBottom() {
        backend.ensureLayout()
        let visHeight = backend.viewportHeight
        // "cursor visible" policy — if the cursor is outside the visible area,
        // only bring it in; if it's inside, don't touch it. Called from layout
        // (window resize, etc.) when followingBottom, so if the user intends to
        // stay at the bottom we pull them there, but if the area above the cursor
        // is alive we leave it as-is.
        let inset = backend.contentInset.height
        let cursorViewRow = session.grid.scrollback.count + session.grid.cursorRow
        let cursorY = CGFloat(cursorViewRow) * cellMetrics.height + inset
        let cursorBottom = cursorY + cellMetrics.height
        let curScroll = backend.scrollYPixels
        let visTop = curScroll
        let visBottom = curScroll + visHeight
        // Include the adjacent padding when revealing the cursor (see followTargetY) —
        // cursor on the last row must land at the TRUE bottom, padding and all.
        if cursorBottom + inset > visBottom {
            backend.setScrollY(cursorBottom + inset - visHeight, animated: false)
        } else if cursorY - inset < visTop {
            backend.setScrollY(max(0, cursorY - inset), animated: false)
        } else {
            backend.reflectScroll()
        }
    }

    /// Measures the single-line height NSTextView actually uses in layout. More
    /// accurate than `defaultLineHeight` (it reflects subtle differences in typesetter / leading, etc.).
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
        // Report the final size after a live resize ends (a safety net — layout()
        // usually handles this already, but for the case where the last frame is
        // determined without a layout call).
        reportSizeIfChanged()
    }

    /// Measure the current cell size from the backend's render font. Metrics are
    /// derived from the render font so metrics and render never diverge.
    private func measuredCellSize() -> (w: CGFloat, h: CGFloat) {
        let font = backend.renderFont
        let glyphSize = ("M" as NSString).size(withAttributes: [.font: font])
        // NSLayoutManager().defaultLineHeight can differ slightly from the line
        // height NSTextView actually uses, causing rows to be over-reported. Measure from the actual layout result.
        return (max(glyphSize.width, 1), max(measuredLineHeight(font: font), 1))
    }

    /// The drawable terminal area in points (insets/scroller/tab-bar accounted) —
    /// what cols/rows are derived from. Shared by reportSizeIfChanged and the
    /// font-zoom window adjustment (which inverts this to keep cols/rows constant).
    ///
    /// height: we must distinguish two window modes. The discriminator is
    /// tabbingMode — compact mode turns off native tabs (`.disallowed`) and uses a custom tab bar.
    ///
    ///   • compact (custom tab bar): the tab bar is an ordinary subview, so it
    ///     has already shrunk our backing view by that much → backend.contentSize.height
    ///     is exactly the height actually drawable. Use it as-is (symmetric
    ///     with usableW). The old path that subtracted a magic constant
    ///     from window.contentRect was off from the tab bar's actual height
    ///     (38 vs 36), counting one extra row, which pushed the bottom line of
    ///     a TUI like Claude Code off-screen so you had to scroll to see it.
    ///
    ///   • standard (native tab bar): bounds/contentRect fluctuates by ~36pt
    ///     as it toggles between 2 tabs↔1 tab → each toggle redraws the prompt
    ///     via SIGWINCH and accumulates. Pre-subtract that height even when the
    ///     tab bar is hidden (1 tab) to keep rows constant.
    private func usableSize() -> (w: CGFloat, h: CGFloat) {
        let inset = backend.contentInset
        // width: backend.contentSize.width instead of bounds.width — because the
        // vertical scroller takes ~15pt under the system setting where it's always visible.
        let usableW = max(backend.contentSize.width - inset.width * 2, 1)
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
        return (usableW, usableH)
    }

    private func reportSizeIfChanged() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Fire SIGWINCH immediately on every layout — so the shell/TUI redraws in
        // real time even during a drag, and the screen the user sees updates in real time too.
        //
        // (Tried debounce/throttle, but: debounce never fires once until the drag
        //  ends because continuous dragging resets the timer. Prompt accumulation
        //  in a normal shell is SIGWINCH's own standard behavior. In a TUI session
        //  redraws are mostly in-place (net-zero scroll), so scrollback residue
        //  barely accumulates even during a resize.)
        let (cellW, cellH) = measuredCellSize()
        cellMetrics = CellMetrics(width: cellW, height: cellH)
        let (usableW, usableH) = usableSize()
        let cols = max(Int(floor(usableW / cellW)), 1)
        let rows = max(Int(floor(usableH / cellH)), 1)

        let gridStale = (session.grid.cols != cols || session.grid.rows != rows)
        let ptyStale = (lastPtySize == nil || lastPtySize! != (cols, rows))
        if !gridStale && !ptyStale { return }   // genuine no-op layout

        if inLiveResize || inZoomBurst {
            // Visual reflow only; defer SIGWINCH so the shell doesn't redraw and
            // accumulate its prompt on every drag frame / zoom step. The final size
            // is flushed (with SIGWINCH) at viewDidEndLiveResize / the zoom-burst
            // settle timer.
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

    /// The height the macOS native window tab bar actually takes — when a tab is
    /// added, macOS shrinks `window.frame.height` by this much to make room for
    /// the tab bar. Measured: 600 → 564 = 36pt.
    /// (Counterintuitive — the tab bar doesn't eat into the contentView; the window itself shrinks.)
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
        // Re-entering a window (tab return, split re-add): the grid may have changed
        // while we were off-window, where Metal renders silently fail (no drawable).
        // Force a fresh draw of the current grid so the latest output shows on appear,
        // for every pane — not just the one that becomes first responder below.
        repaintNow()
        window.makeFirstResponder(self)
        inputContext?.activate()
        warmupIMEIfNeeded()
    }

    /// Force-triggers the TSM↔IMK IPC handshake before the user presses the first key.
    /// Handles environments where, with just `.app` registration, a residual race leaks the first jamo after launch.
    private func warmupIMEIfNeeded() {
        guard !didWarmupIME else { return }
        didWarmupIME = true
        guard let window = window else { return }

        // Run on the next runloop tick — so IMK receives it after the window is fully key.
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

    // MARK: - Context menu (right-click)

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

        // Split — passed to the window controller via the responder chain (only handled in Compact mode).
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
        // Reclaim key input via the click (in case first responder went elsewhere)
        window?.makeFirstResponder(self)

        // If mouse reporting is active and Shift isn't held, forward to the PTY (no selection).
        if isMouseReportingEvent(event) {
            sendMouseEventToPTY(event: event, button: 0, pressed: true)
            return
        }

        let point = convertEventToCell(event)

        // Shift-click extends the selection: keep the existing anchor (or the last
        // click point) and move the head to the clicked cell. Repeated Shift-clicks
        // re-extend from the same anchor. A drag afterward keeps adjusting the head.
        if event.modifierFlags.contains(.shift),
           let anchor = selectionAnchor ?? selectionOrigin {
            selectionAnchor = anchor
            selectionHead = point
            scheduleRender()
            return
        }

        switch event.clickCount {
        case 2:
            // Double click — word selection (broken at spaces).
            if let (start, end) = wordBoundsAround(point) {
                selectionAnchor = start
                selectionHead = end
            } else {
                selectionAnchor = point
                selectionHead = point
            }
        case 3:
            // Triple click — select the whole line.
            let cells = cellsForTextViewRow(point.row)
            selectionAnchor = (point.row, 0)
            selectionHead = (point.row, cells.count)
        default:
            // Normal click — start a drag selection.
            selectionAnchor = point
            selectionHead = point
        }
        // Remember where this click landed so a later Shift-click can extend from it,
        // even after mouseUp clears a zero-width (plain-click) selection.
        selectionOrigin = point
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
        // If the clicked spot is whitespace, it's not a word — return nil (just a plain selection)
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
        // Word boundary — whitespace/tab only. CJK isn't word-segmented, but use whitespace for now.
        c == " " || c == "\t"
    }

    public override func mouseDragged(with event: NSEvent) {
        // In cell-motion / any-motion mode, forward drag to the PTY too.
        if isMouseReportingEvent(event), session.mouseReportingMode >= 1002 {
            // Avoid sending within the same cell (in 1003 mode it does send)
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
        // If anchor == head (i.e. just a click)
        if let a = selectionAnchor, let h = selectionHead, a == h {
            // Only open the URL while Cmd is held — a click without Cmd is the normal act of moving the cursor.
            // (iTerm2 / Terminal.app / VS Code all share this UX.)
            if event.modifierFlags.contains(.command), let url = urlAtCell(a) {
                NSWorkspace.shared.open(url)
            }
            selectionAnchor = nil
            selectionHead = nil
            scheduleRender()
        } else if selectionAnchor != nil, selectionHead != nil {
            // Selection completed via drag / double·triple click → copy-on-select (option, default ON).
            copySelectionIfEnabled()
        }
    }

    /// If copy-on-select is on and there's a non-empty selection, copy it to the clipboard.
    private func copySelectionIfEnabled() {
        guard session.config.copyOnSelect,
              let text = selectedText(), !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Cmd-hover URL highlight (same UX as iTerm2 / Terminal.app)
    //
    // Without Cmd held, a plain text URL just looks like ordinary text;
    // hover over a URL with Cmd held and only those characters turn blue + underline + pointing hand cursor.
    // Cleared immediately on releasing Cmd or moving off the URL.

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
                guard cur.url == info.url, cur.segments.count == info.segments.count else { return true }
                return !zip(cur.segments, info.segments).allSatisfy {
                    $0.row == $1.row && $0.colRange == $1.colRange
                }
            }()
            if changed {
                hoveredURL = (url: info.url, segments: info.segments)
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

    /// If a given (row, col) cell falls within a URL region, returns the URL and its
    /// per-row cell col ranges. For an OSC 8 hyperlink, the adjacent same-URI run on
    /// the hovered row. For a plain text URL, every row segment of the (possibly
    /// multi-row) NSDataDetector match.
    private func urlInfoAtCell(
        _ pos: (row: Int, col: Int)
    ) -> (url: URL, segments: [(row: Int, colRange: Range<Int>)])? {
        let cells = cellsForTextViewRow(pos.row)
        guard pos.col >= 0, pos.col < cells.count else { return nil }
        if let uri = cells[pos.col].hyperlink, let url = URL(string: uri) {
            var s = pos.col
            while s > 0 && cells[s - 1].hyperlink == uri { s -= 1 }
            var e = pos.col + 1
            while e < cells.count && cells[e].hyperlink == uri { e += 1 }
            return (url, [(pos.row, s..<e)])
        }
        // Plain-text URL — may span multiple rows (soft wrap, or a TUI's own hard
        // wrap with indented continuations). EVERY row's segment is returned so the
        // hover underline covers the whole link, not just the hovered row.
        guard let m = multiRowURLMatch(at: pos) else { return nil }
        let segments: [(row: Int, colRange: Range<Int>)] = m.segments.map { seg in
            // Include the trailing continuation cell of a wide-char URL.
            let rowCells = cellsForTextViewRow(seg.row)
            var endEx = seg.cols.upperBound
            while endEx < rowCells.count && rowCells[endEx].isContinuation { endEx += 1 }
            return (seg.row, seg.cols.lowerBound..<endEx)
        }
        return (m.url, segments)
    }

    /// Multi-row plain-URL detection at a unified (row, col) — adapter from the grid
    /// to MultiRowURLDetector. See that type for the joining rules.
    private func multiRowURLMatch(
        at pos: (row: Int, col: Int)
    ) -> MultiRowURLDetector.Match? {
        let grid = session.grid
        let sbCount = grid.scrollback.count
        let total = sbCount + grid.rows
        return MultiRowURLDetector.match(
            at: pos.row, col: pos.col, totalCols: grid.cols
        ) { r in
            guard r >= 0, r < total else { return nil }
            let cells: [Cell]
            let wrapped: Bool
            if r < sbCount {
                cells = grid.scrollback[r].cells
                wrapped = grid.scrollback[r].wrapped
            } else {
                cells = grid.row(r - sbCount)
                wrapped = grid.rowWrapped(r - sbCount)
            }
            var chars: [Character] = []
            var cols: [Int] = []
            for (i, c) in cells.enumerated() where !c.isContinuation && !c.isWideSpacer {
                chars.append(c.char)
                cols.append(i)
            }
            return MultiRowURLDetector.RowData(chars: chars, cols: cols, wrapped: wrapped)
        }
    }

    // State for the 2-finger horizontal swipe → tab switch gesture (decided once per gesture).
    private var swipeDecided = false
    private var swipeHorizontal = false
    private var swipeAccumX: CGFloat = 0
    private var swipeVelocity: CGFloat = 0   // smoothed recent dx/event for flick detection

    public override func scrollWheel(with event: NSEvent) {
        // 2-finger horizontal swipe → tab switch (trackpad only, when the app isn't capturing the mouse).
        // Horizontal gestures are consumed here (the terminal has no horizontal
        // scrolling). Vertical scrolling is passed straight through to the backend.
        if event.hasPreciseScrollingDeltas, session.mouseReportingMode == 0,
           handleTabSwipe(event) {
            return
        }
        // When mouse reporting is active, deliver the wheel to the PTY as button 64/65 codes (tmux/Claude Code, etc.).
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

    /// Deliver the wheel as button 64/65 to mouse-reporting apps (TUIs: Claude Code/tmux, etc.).
    /// Trackpad precision deltas come as very dense events, so sending one per
    /// event floods the TUI. Accumulate the point delta and send only once per
    /// ≈1 line (tuned by `scrollSpeed`).
    private func forwardWheelToMouseReporting(_ event: NSEvent) {
        let delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas {
            // Mouse wheel: the delta is already in line/notch units → one at a time.
            guard abs(delta) > 0.1 else { return }
            sendMouseEventToPTY(event: event, button: delta > 0 ? 64 : 65, pressed: true)
            return
        }
        // Trackpad precision scroll: accumulate, then one per threshold.
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

    /// The Y the scroll should settle at while following. Computed identically to
    /// renderNow()'s follow logic so the animated/immediate scroll go to the same
    /// spot. nil if already at the right position (no scroll needed).
    private func followTargetY() -> CGFloat? {
        let grid = session.grid
        let inset = backend.contentInset.height
        if grid.isAltScreenActive || grid.hasUsedSyncOutput || grid.hasContentBelowCursor {
            // Alt-screen / primary-screen TUI (Claude Code, etc.) — anchor grid-top
            // at viewport-top so the entire live grid is visible. (rows*cellH ≤
            // visHeight, so the grid always fits in the viewport → no bottom clipping.)
            //
            // Claude Code uses neither alt-screen nor sync-output, but it keeps a
            // status line residing below the input line (hasContentBelowCursor).
            // The cursor-visible policy stops once the cursor is visible, clipping
            // that status below the fold — resolved by the grid-top anchor.
            //
            // Important: with the cursor-visible policy in a TUI whose scrollback
            // grows (sync output accumulating), the cursor is already visible so
            // no scroll happens, and every frame the scrollback grows by 1 line
            // pushes the grid below the fold — a regression where new content
            // isn't visible. The grid-top anchor is tied to scrollback.count, so
            // it descends as scrollback grows, always showing the new content
            // (grid bottom). Also matches the anchor in layout().
            return CGFloat(grid.scrollback.count) * cellMetrics.height + inset
        }
        // Normal shell — cursor-visible policy. When revealing the cursor, include
        // the adjacent padding (bottom inset when scrolling down, top inset when
        // scrolling up): with the cursor on the last row, the target then equals the
        // true bottom (yMax). Without this the view stopped `inset` short of the
        // bottom — invisible at the old 4pt inset, but an obvious "didn't quite
        // scroll down" with a larger configured padding.
        let visHeight = backend.viewportHeight
        let cursorViewRow = grid.scrollback.count + grid.cursorRow
        let cursorY = CGFloat(cursorViewRow) * cellMetrics.height + inset
        let cursorBottom = cursorY + cellMetrics.height
        let curY = backend.scrollYPixels
        if cursorBottom + inset > curY + visHeight {
            return cursorBottom + inset - visHeight
        } else if cursorY - inset < curY {
            return max(0, cursorY - inset)
        }
        return nil // cursor already in the visible area — no scroll needed.
    }

    /// On user input (key input/paste), resume follow and **smoothly** jump to
    /// the cursor/viewport. If a key is pressed while scrolled up viewing history, return to the working position.
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
            // Settle exactly, accounting for new output that arrived during the animation.
            if self.followingBottom, let y = self.followTargetY() {
                self.backend.setScrollY(y, animated: false)
            } else {
                self.backend.reflectScroll()
            }
            self.refreshCursorOverlayNow()
        })
    }

    /// Decide whether a mouse event should be forwarded to PTY reporting.
    /// Active mode + no Shift = report. Holding Shift prefers native behavior like selection.
    private func isMouseReportingEvent(_ event: NSEvent) -> Bool {
        session.mouseReportingMode != 0 && !event.modifierFlags.contains(.shift)
    }

    /// Send a mouse event to the PTY in the appropriate mouse-reporting encoding (SGR or X10).
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
            // X10/X11 — press: actual cb, release: 3 (universal release marker)
            let cbLegacy = pressed ? cb : (3 + modBits)
            let cbByte = UInt8(min(cbLegacy + 32, 255))
            let cxByte = UInt8(min(col + 32, 255))
            let cyByte = UInt8(min(row + 32, 255))
            bytes = Data([0x1B, 0x5B, 0x4D, cbByte, cxByte, cyByte])
        }
        session.write(bytes)
    }

    /// Returns the clickable URL at a given (row, col). Prefers an OSC 8
    /// hyperlink; otherwise auto-detects a plain text URL via NSDataDetector.
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
        // 1. If an OSC 8 hyperlink is set, that URI
        if let uri = cells[pos.col].hyperlink, let url = URL(string: uri) {
            return url
        }
        // 2. Plain-text URL — joined across soft-wrapped rows and TUI-style
        //    indented hard-wrapped continuations (see MultiRowURLDetector).
        return multiRowURLMatch(at: pos)?.url
    }

    /// Converts `event.locationInWindow` to (row, col) in the textView content coordinate system.
    /// row is the unified scrollback+viewport index (= `scrollback.count + viewportRow`).
    private func convertEventToCell(_ event: NSEvent) -> (row: Int, col: Int) {
        let pos = backend.cell(at: event.locationInWindow, grid: session.grid, metrics: cellMetrics)
        return (pos.row, pos.col)
    }

    /// (start, end) with anchor/head normalized in row-major order. end is exclusive.
    private func normalizedSelection() -> (start: (row: Int, col: Int), end: (row: Int, col: Int))? {
        guard let a = selectionAnchor, let h = selectionHead else { return nil }
        if a.row == h.row && a.col == h.col { return nil }
        if a.row < h.row || (a.row == h.row && a.col < h.col) {
            return (a, h)
        }
        return (h, a)
    }

    /// The selected col range in a given textViewRow (if any). end exclusive.
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

    /// Cmd+F (NSResponder/NSTextFinderClient standard) — toggle the find overlay.
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
            // cell → text mapping (continuation points to the preceding character).
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
                // char idx → col mapping
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

        // Sorted flat list — for Cmd+G next/prev navigation (ascending by row, then ascending by col within a row).
        findMatchesOrdered = findMatchesByRow
            .sorted { $0.key < $1.key }
            .flatMap { row, ranges in
                ranges.sorted { $0.lowerBound < $1.lowerBound }.map { (row: row, range: $0) }
            }
        // Select the first match as active and scroll to it (so the first match is visible even during incremental search while typing).
        if !findMatchesOrdered.isEmpty {
            activeMatchIndex = 0
            scrollToActiveMatch()
        }
        findOverlay?.updateCount(matched: total)
        scheduleRender()
    }

    /// Move to the next/previous match (Cmd+G / Cmd+Shift+G). Wrap-around.
    /// Exposed as @objc public since it enters via the responder chain from the menu/shortcut.
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

    /// Scroll so the active match row is shown around the middle of the viewport.
    private func scrollToActiveMatch() {
        guard activeMatchIndex >= 0, activeMatchIndex < findMatchesOrdered.count else { return }
        // Release follow-bottom — the user is navigating search results now. Without
        // this the very next render's follow alignment yanked the view straight back
        // to the cursor, making the jump-to-match appear to "not stick". (Same rule
        // as jumpPrompt.) Follow resumes naturally on terminal input or on scrolling
        // back to the bottom.
        followingBottom = false
        let row = findMatchesOrdered[activeMatchIndex].row
        let visHeight = backend.viewportHeight
        let rowY = CGFloat(row) * cellMetrics.height + backend.contentInset.height
        // Place the match at the 1/3 point of the viewport so context above and below is visible.
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

    /// ⌘↑ — scroll to the nearest prompt (OSC 133;A mark) above the current screen.
    @objc public func jumpToPreviousPrompt(_ sender: Any?) { jumpPrompt(forward: false) }
    /// ⌘↓ — scroll to the nearest prompt below the current screen.
    @objc public func jumpToNextPrompt(_ sender: Any?) { jumpPrompt(forward: true) }

    private func jumpPrompt(forward: Bool) {
        let grid = session.grid
        let cellH = max(cellMetrics.height, 1)
        let sbCount = Int(grid.scrollback.count)
        let pushCount = Int(grid.scrollbackPushCount)
        // Mark absolute line number → current unified row. Exclude evicted marks (negative).
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
        // Use a font with the cascade for zoom too — keep Nerd glyph fallback even on Menlo, etc.
        let font = fontWithNerdFallback(family: session.config.fontFamily, size: newSize)
        backend.setRenderFont(font)
        lastRenderedVersion = .max
        // Zoom-burst debounce — the fix for zoom-mash artifacts (prompt copies /
        // gaps): the shell must NOT redraw per zoom step. A SIGWINCH per step makes
        // the shell's coalesced redraws run against momentarily stale geometry,
        // stranding debris in the history. Treat the burst like a live window drag:
        // reflow the grid visually per step (resizeGridOnly via the inZoomBurst
        // branch in reportSizeIfChanged — no PTY notify, so no shell redraw) and
        // flush ONE real resize (SIGWINCH) 150ms after the last step, when geometry
        // has settled. The shell then redraws exactly once, at the correct size.
        // (An earlier iteration resized the WINDOW to keep cols×rows constant,
        // iTerm2-style; rejected — zoom shouldn't move the window frame.)
        inZoomBurst = true
        zoomBurstTimer?.invalidate()
        zoomBurstTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            self.inZoomBurst = false
            self.reportSizeIfChanged()   // settled size → single SIGWINCH
            self.renderNow()
        }
        // Reflows the grid to the new cell size (grid-only during the burst; the
        // PTY flush is deferred to the burst timer above).
        reportSizeIfChanged()
        // Redraw immediately with the new font even on a small zoom step where cols/rows don't change.
        renderNow()
        followingBottom = true
        scrollViewportToBottom()
    }

    /// Debounce state for zoom mashing — see setZoom. While true,
    /// reportSizeIfChanged reflows the grid without notifying the PTY.
    private var inZoomBurst = false
    private var zoomBurstTimer: Timer?

    /// The selector sent by Edit > Copy / Cmd+C. Pushes the selected text to the pasteboard.
    @objc public func copy(_ sender: Any?) {
        guard let text = selectedText() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Edit > Paste / Cmd+V. Clipboard text to the PTY. Wraps it in bracketed paste mode.
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
            case 126: // ⌘↑ — jump to the previous prompt (OSC 133 mark)
                jumpToPreviousPrompt(self); return true
            case 125: // ⌘↓ — jump to the next prompt
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
            // Send a closeTab action through the responder chain first —
            // CompactWindowController may implement closing only the active tab. If no one takes it, close the window normally.
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
        // Start of a new keyDown cycle — set the context the IME callbacks will reference.
        currentKeyEvent = event
        swallowNextDeleteCommand = false
        defer { currentKeyEvent = nil }
        // Keep the cursor from blinking while typing — show it immediately + reset the phase.
        resetBlinkPhase()

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd is handled in performKeyEquivalent. Reaching here means no
        // menu/shortcut took it; sending it to the IME or PTY would cause
        // unintended behavior → ignore.
        if mods.contains(.command) {
            return
        }

        // Actual input keys (typing/arrows/Enter/Ctrl-combos, etc.) jump to the
        // working position. Even while scrolled up viewing history, pressing a key returns to the cursor.
        snapToCursorOnUserInput()

        // Clear the selection on user key input (terminal convention).
        clearSelectionIfNeeded()

        // Ctrl+letter (with no other modifier) → terminal control byte. Bypasses the IME.
        // Shift+Ctrl is in the same group too (e.g. Ctrl+Shift+C → same byte as Ctrl+C → 0x03).
        if mods.subtracting(.shift) == .control,
           let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let scalar = chars.unicodeScalars.first?.value,
           (0x41...0x5A).contains(scalar) || (0x61...0x7A).contains(scalar) {
            let lower = scalar | 0x20
            session.write(Data([UInt8(lower - 0x60)]))
            return
        }

        // Shift+Enter → newline in the input field (no submit). AppKit sends
        // Shift+Enter via `insertNewline:` just like a plain Enter, so both emit
        // CR and a TUI like Claude Code can't tell them apart and treats
        // Shift+Enter as submit. Intercept here and send ESC CR — the same
        // mapping claude's `/terminal-setup` installs in Apple Terminal, so it's
        // recognized as a "newline". (Pass through during IME composition for a normal commit.)
        if mods == .shift, event.keyCode == 36 || event.keyCode == 76,
           markedText.isEmpty {
            session.write(Data([0x1B, 0x0D])) // ESC CR
            return
        }

        // Everything else: send to NSTextInputContext. Handles Korean/Japanese/
        // Chinese IME composition, plain input, Enter/Tab/arrows (the doCommand
        // path), Backspace (doCommand), etc. consistently.
        inputContext?.handleEvent(event)
    }

    public override func doCommand(by selector: Selector) {
        if isWarmingUpIME {
            return
        }
        // AppKit selector → terminal escape byte sequence. The core NSTextInputClient contract:
        // keys the IME didn't handle, or keys the IME committed and that need
        // further handling, are dispatched here.
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            session.write(Data([0x0D])) // CR
        case #selector(NSResponder.insertTab(_:)):
            session.write(Data([0x09]))
        case #selector(NSResponder.insertBacktab(_:)):
            session.write(Data([0x1B, 0x5B, 0x5A])) // CSI Z
        case #selector(NSResponder.deleteBackward(_:)):
            // If a BS-cancel spurious commit was already handled in the IME callback, don't send BS to the PTY.
            if swallowNextDeleteCommand {
                swallowNextDeleteCommand = false
                return
            }
            session.write(Data([0x7F])) // DEL (most shells map this to erase)
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
            break // unknown command — ignore
        }
    }

    // MARK: - NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.unwrapString(string)

        // During startup warmup, don't send the called-back text to the PTY.
        if isWarmingUpIME {
            return
        }

        // Detect a BS-cancel spurious commit.
        // The macOS Hangul IME has a bug where, when canceling the last jamo with
        // BS, it emits that same jamo via insertText. If the trigger key is BS and
        // the same character as markedText is about to commit, judge it spurious
        // and drop it. Also swallow the doCommand (deleteBackward:) of the same keyDown cycle.
        if let event = currentKeyEvent,
           event.keyCode == 51,
           !markedText.isEmpty,
           text == markedText {
            markedText = ""
            swallowNextDeleteCommand = true
            scheduleRender()
            return
        }

        // Known limitation: the first jamo right after the Han/Eng key arrives
        // directly via insertText without going through setMarkedText (running a
        // raw binary, the TSM↔IMK IPC isn't set up before the first keystroke
        // arrives). The fix is `.app` bundle registration (see the halite Rust
        // docs). The state machine trick is lossy because it diverges from IMK's
        // internal state. For now we commit it to the PTY as-is — the user can recover with BS + re-typing.

        // Normal commit: clear the marked text and send to the PTY.
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

    /// Where the IME candidate window appears — returns the screen coordinates of the cursor cell.
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

    /// Force a render of the current grid right now, bypassing the version dedupe.
    ///
    /// While a pane is off-window (its tab is backgrounded, or it sits in a split
    /// that was removed from the superview), `gridChanged` still fires and drives
    /// `renderNow()`. That advances `lastRenderedVersion` to the grid version, but
    /// the Metal backend's `nextDrawable()` returns nil with no visible drawable,
    /// so no frame is actually presented. When the pane is shown again the dedupe
    /// guard then sees `grid.version == lastRenderedVersion` and skips the draw, so
    /// the pane keeps showing its last on-screen (stale) frame until it's focused.
    ///
    /// Resetting the dedupe key forces the next `renderNow()` to push the current
    /// grid to a now-valid drawable. Called when a pane becomes visible again
    /// (tab return / re-entering a window).
    public func repaintNow() {
        lastRenderedVersion = .max
        renderNow()
    }

    /// Coalesces multiple grid mutations into a single renderNow call per runloop tick.
    private func scheduleRender() {
        if renderScheduled { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            // DEC 2026 Synchronized Output: while a sync frame (BSU…ESU) is in
            // progress, don't push a partially (torn) applied grid to the screen.
            // When a PTY read cut the middle of a frame, new content was drawn
            // half over the old, looking like an "overwrite/duplicate". The
            // gridChanged right after ESU (\e[?2026l) presents the completed frame
            // atomically. Force a flush via a safety timer in case of a misbehaving app whose ESU never arrives.
            if self.session.grid.inSyncOutputMode {
                self.armSyncFlush()
                return
            }
            self.renderNow()
        }
    }

    /// If a sync frame exceeds syncFlushDeadline without an ESU, force a present to prevent a freeze.
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
            return h.segments.map { "\($0.row):\($0.colRange.lowerBound)-\($0.colRange.upperBound)" }
                .joined(separator: ",")
        }()
        // blink phase — include in the dedupe key so each phase toggle re-renders when ON.
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

        // Align the scroll position to the follow target BEFORE drawing, so output
        // that scrolls the grid is presented once at the final position. Drawing
        // first and correcting the position afterward (the old order) presented a
        // stale frame one row off, then the corrected one — a one-row vertical
        // flicker on every scroll-in line in TUIs like Claude Code / hermes.

        // When an alt-screen transition (primary↔alt) occurs, resume follow.
        // vim/htop etc. must always show that screen on entry and the shell bottom
        // on exit, so even if the user had previously scrolled up
        // (followingBottom == false), restore it here.
        if grid.isAltScreenActive != lastAltScreenActive {
            lastAltScreenActive = grid.isAltScreenActive
            followingBottom = true
        }

        // How many lines the top of scrollback was evicted this render = how much
        // the content the user was viewing shifted up. (Appends to scrollback pile
        // up right above the viewport and don't change the on-screen position of
        // existing history, so content drift happens only on top eviction.)
        // Underflow-safe: a narrowing reflow can grow scrollback.count past
        // scrollbackPushCount (reflow rebuilds scrollback without bumping the push
        // counter). `linesEvictedFromTop` clamps to 0 instead of trapping the
        // UInt64 subtraction — the resize crash.
        let evictedTotal = grid.linesEvictedFromTop
        let evictedSinceLast = evictedTotal >= lastEvictedTotal
            ? Int(evictedTotal - lastEvictedTotal) : 0
        lastEvictedTotal = evictedTotal

        let totalRows = grid.scrollback.count + grid.rows
        if followingBottom {
            // During a key-input jump animation, the animation owns the position — don't scroll immediately.
            // Alt screen uses the viewport top anchor; otherwise (normal shell/
            // Claude Code, etc.) the cursor-visible policy. followTargetY() computes both cases uniformly.
            if !isSnappingToCursor, let targetY = followTargetY() {
                backend.alignScroll(to: targetY, totalRows: totalRows)
            }
        } else if evictedSinceLast > 0 {
            // The user is scrolled up viewing history — scroll up by the amount of
            // scrollback evicted so the line they're viewing stays at the same on-screen position (content-anchor).
            let curY = backend.scrollYPixels
            let adjusted = max(0, curY - CGFloat(evictedSinceLast) * cellMetrics.height)
            backend.alignScroll(to: adjusted, totalRows: totalRows)
        }
        // else: leave the position the user scrolled up to as-is (no forced bottom pinning).

        // The backend draws a frame (including ensureLayout) at the aligned
        // position. Dedupe was done above.
        backend.render(grid: grid, config: session.config, state: currentRenderState(),
                       metrics: cellMetrics)

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
            hoveredSegments: hoveredURL.map { h in
                Dictionary(h.segments.map { ($0.row, $0.colRange) },
                           uniquingKeysWith: { a, _ in a })
            } ?? [:],
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
