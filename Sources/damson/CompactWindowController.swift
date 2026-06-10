import AppKit
import Combine
import DamsonControl
import DamsonTerminal

/// Window controller dedicated to compact mode. A single NSWindow multiplexes N
/// DamsonSessions. NSWindow's native tabs are disabled (`tabbingMode = .disallowed`)
/// and a custom CompactTabBarView sits at the top of contentView so the tabs share a
/// row with the traffic lights.
///
/// Borrows the MainWindowController structure from hiterm (`~/dev/hiterm`).
final class CompactWindowController: NSWindowController, NSWindowDelegate, TabSwipeHandler {
    /// A tab = (PaneTreeView, a subscription to the title of that tree's first leaf session).
    /// Splitting within a tab via Cmd+D / Cmd+Shift+D adds a leaf to that tab's tree.
    private struct Tab {
        let tree: PaneTreeView
        var titleSub: AnyCancellable
        /// User-assigned title set via double-click. If nil, follows the session (process/OSC) title.
        var customTitle: String? = nil
    }

    /// Animation intent threaded through `selectTab` / `addTab`. `.none` = instant
    /// (today's behavior; restore, keyboard nav, tab-bar click, close-show-next).
    /// `.create` = a brand-new tab's content fades + scales in (Task 2).
    /// `.switch(fromIndex:)` = the tab-switch crossfade/slide (Task 6); carries the
    /// index we came **from** so the slide direction follows the index sign.
    enum TabTransition {
        case none
        case create
        case `switch`(fromIndex: Int)
    }
    private var tabs: [Tab] = []
    private(set) var currentIndex: Int = 0

    /// Session representation for external list-tabs / switch-tab, etc.
    /// Each tab's root pane (first leaf) session — used to track the tab title.
    var sessions: [DamsonSession] {
        tabs.compactMap { $0.tree.root.leaves().first?.session }
    }

    /// All sessions across all tabs × all panes (for exhaustive checks like quit confirmation — `sessions` gives only the first leaf per tab).
    var allPaneSessions: [DamsonSession] {
        tabs.flatMap { $0.tree.root.leaves().map { $0.session } }
    }

    /// The active pane of the current active tab (the focused side when split).
    var activeSession: DamsonSession? {
        guard currentIndex < tabs.count else { return nil }
        let tree = tabs[currentIndex].tree
        if case .leaf(let s, _) = tree.activeLeaf.kind { return s }
        return nil
    }

    private var tabBar: CompactTabBarView!
    private var tabBarBackground: NSVisualEffectView!   // for transparent (frosted) mode
    private var tabBarSolid: NSView!                    // for solid (theme-colored) mode — over the vibrancy
    private var contentContainer: NSView!
    private static let tabBarHeight: CGFloat = 38
    private var tabBarTopConstraint: NSLayoutConstraint!
    private var tabBarBackgroundHeightConstraint: NSLayoutConstraint!
    private var tabBarSolidHeightConstraint: NSLayoutConstraint!
    /// Tab-bar top inset. Kept at 0 even in full screen so the tab bar shows as a single
    /// top row. (Lowering it to make room for the menu bar created an empty band, making it
    /// look like two rows — and since the menu bar is normally hidden in full screen and
    /// only briefly overlaps on top-edge hover per standard macOS behavior, a single row is preferred.)
    private var fullScreenTopInset: CGFloat { 0 }

    // Interactive 2-finger swipe (TabSwipeHandler). During a horizontal swipe the
    // neighbor tab's live tree is added beside the current one and both follow the
    // finger; on release past a threshold the switch commits, else it snaps back.
    private var swipeActive = false
    private var swipeAnimating = false
    private var swipeNeighborLayer: CALayer?   // neighbor shown as a snapshot (no hit-test)
    private var swipeNeighborIndex = -1
    private var swipeFromRight = false   // neighbor (next tab) enters from the right

    // Shared tab-slide motion — the keyboard/click cross-slide and the trackpad
    // swipe settle use the SAME duration + curve so they decelerate identically.
    // CABasicAnimation runs on the display's refresh rate (120Hz on ProMotion) for
    // free, so neither path needs a manual display link.
    static let tabSlideDuration: TimeInterval = 0.42
    static func tabSlideTiming() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)   // strong ease-out
    }

    var hasTabs: Bool { !tabs.isEmpty }

    /// If `restoring` is present, restore that tab/pane layout + cwd; otherwise a single empty tab.
    init(restoring: RestorableWindow? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Damson"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 480, height: 240)
        window.center()
        // Native tabs OFF — use our own custom-drawn tab bar.
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)

        super.init(window: window)
        window.delegate = self

        setupViews()
        WindowChrome.applyFromDefaults(to: window)

        if let restore = restoring, !restore.tabs.isEmpty {
            for (i, paneRestore) in restore.tabs.enumerated() {
                let root = PaneNode.from(restorable: paneRestore)
                let title = (restore.tabTitles.map { i < $0.count ? $0[i] : nil }) ?? nil
                addTab(tree: PaneTreeView(restoredRoot: root), customTitle: title)
            }
            let sel = restore.selectedTab
            if sel >= 0 && sel < tabs.count { selectTab(sel) }
        } else {
            addNewTab()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Serialize the current window's tab/pane layout + cwd.
    func toRestorableWindow() -> RestorableWindow {
        RestorableWindow(
            tabs: tabs.map { $0.tree.root.toRestorable() },
            selectedTab: currentIndex,
            tabTitles: tabs.map { $0.customTitle }
        )
    }

    deinit {
        for s in sessions { s.terminate() }
    }

    private func setupViews() {
        guard let contentView = window?.contentView else { return }

        // Vibrancy laid under the titlebar area (background behind the traffic lights + tabs).
        tabBarBackground = NSVisualEffectView()
        tabBarBackground.material = .hudWindow
        tabBarBackground.blendingMode = .behindWindow
        tabBarBackground.state = .followsWindowActiveState
        tabBarBackground.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabBarBackground)

        // Solid (theme-colored) background — over the vibrancy, under the tabs. Covers the vibrancy in solid mode.
        tabBarSolid = NSView()
        tabBarSolid.wantsLayer = true
        tabBarSolid.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabBarSolid)

        // Custom tab bar.
        tabBar = CompactTabBarView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onTabSelected = { [weak self] idx in
            guard let self = self else { return }
            self.selectTab(idx, transition: .switch(fromIndex: self.currentIndex))
        }
        tabBar.onTabClosed = { [weak self] idx in self?.closeTab(idx) }
        tabBar.onNewTab = { [weak self] in self?.addNewTab() }
        tabBar.onTabReordered = { [weak self] from, to in self?.reorderTab(from: from, to: to) }
        tabBar.onTabRenamed = { [weak self] idx, title in self?.renameTab(idx, to: title) }
        contentView.addSubview(tabBar)

        // Container holding the session surfaces — fills below the tab bar.
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        // Host for the tab-close animation overlay (snapshot layer) — made layer-backed up front.
        contentContainer.wantsLayer = true
        contentView.addSubview(contentContainer)

        // Our tab bar is drawn in the titlebar's place (starting at 0). In full screen it is
        // lowered by the menu-bar height (`tabBarTopConstraint.constant`) so the tabs aren't
        // covered when the menu bar appears. tabBarBackground (vibrancy) covers from the very
        // top down to below the tab bar as a single band.
        let tabBarHeight = Self.tabBarHeight
        let inset = fullScreenTopInset
        tabBarTopConstraint = tabBar.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: inset)
        tabBarBackgroundHeightConstraint = tabBarBackground.heightAnchor.constraint(
            equalToConstant: tabBarHeight + inset)
        tabBarSolidHeightConstraint = tabBarSolid.heightAnchor.constraint(
            equalToConstant: tabBarHeight + inset)

        NSLayoutConstraint.activate([
            tabBarBackground.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBarBackground.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBarBackground.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBarBackgroundHeightConstraint,

            tabBarSolid.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBarSolid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBarSolid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBarSolidHeightConstraint,

            tabBarTopConstraint,
            tabBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: tabBarHeight),

            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        applyTabBarBackground()
        // Re-position the traffic lights after the window buttons are laid out. On the next runloop.
        DispatchQueue.main.async { [weak self] in self?.centerTrafficLights() }
    }

    /// Update the tab-bar top inset and background height on full-screen enter/exit.
    private func updateFullScreenInset() {
        let inset = fullScreenTopInset
        tabBarTopConstraint?.constant = inset
        tabBarBackgroundHeightConstraint?.constant = Self.tabBarHeight + inset
        tabBarSolidHeightConstraint?.constant = Self.tabBarHeight + inset
        tabBar.needsLayout = true
    }

    /// Tab-bar background: solid theme background color by default, with transparent (frosted) selectable via settings.
    func applyTabBarBackground() {
        let transparent = UserDefaults.standard.bool(forKey: "damson.tabBarTransparent")
        tabBarSolid?.isHidden = transparent
        if !transparent {
            // Slightly darken the current theme background color (active session → settings value if none) for a titlebar feel.
            let theme = activeSession?.config.theme ?? DamsonConfig.fromUserDefaults().theme
            let bg = (theme.background.usingColorSpace(.sRGB)) ?? theme.background
            // A bit darker (dark theme) / a bit lighter (light theme) to distinguish it from the terminal background.
            let lum = 0.299 * bg.redComponent + 0.587 * bg.greenComponent + 0.114 * bg.blueComponent
            let shade: CGFloat = lum < 0.5 ? 0.06 : -0.06
            func adj(_ c: CGFloat) -> CGFloat { max(0, min(1, c + shade)) }
            tabBarSolid?.layer?.backgroundColor = NSColor(
                srgbRed: adj(bg.redComponent), green: adj(bg.greenComponent),
                blue: adj(bg.blueComponent), alpha: 1).cgColor
        }
    }

    /// Vertically center the traffic lights in the tab bar (38pt). The system draws them
    /// centered in the standard titlebar (~28pt), making them sit higher, so we lower the
    /// button origins to align them with the tab labels. In full screen the traffic lights
    /// are hidden, so this is skipped. Re-applied on resize/full-screen.
    func centerTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let container = buttons.first?.superview else { return }
        for b in buttons {
            let y = container.bounds.height - (Self.tabBarHeight + b.frame.height) / 2
            b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: y))
        }
    }

    // MARK: - Tab management

    @discardableResult
    func addNewTab() -> DamsonSession {
        var config = DamsonConfig.fromUserDefaults()
        // Under the "inherit current directory" policy, start from the current active pane's cwd (keep home if none).
        if NewTabDirectory.current == .inheritCwd,
           let cwd = activeSession?.currentDirectory {
            config.cwd = cwd
        }
        let session = DamsonSession(config: config)
        addTab(tree: PaneTreeView(rootSession: session), transition: .create)
        return session
    }

    /// Add a tab backed by an externally-built session (e.g. a tmux `-CC` pane). Returns the
    /// tree so the caller can later close exactly this tab via `closeTab(matching:)`.
    @discardableResult
    func addExternalTab(session: DamsonSession, customTitle: String? = nil) -> PaneTreeView {
        let tree = PaneTreeView(rootSession: session)
        addTab(tree: tree, transition: .create, customTitle: customTitle)
        return tree
    }

    /// Adopt an already-built `PaneTreeView` as a new tab (e.g. a tmux window reconciled
    /// into native splits). Unlike `addExternalTab(session:)`, the tree may already hold a
    /// multi-pane split structure. Returns the tree for later `closeTab(matching:)`.
    @discardableResult
    func adoptExternalTree(_ tree: PaneTreeView, customTitle: String? = nil) -> PaneTreeView {
        addTab(tree: tree, transition: .create, customTitle: customTitle)
        return tree
    }

    /// Update the custom title of an externally-owned tab (e.g. a tmux `%window-renamed`).
    func setExternalTabTitle(matching tree: PaneTreeView, title: String?) {
        guard let idx = tabs.firstIndex(where: { $0.tree === tree }) else { return }
        tabs[idx].customTitle = title
        refreshTabBar()
    }

    /// Close the tab whose tree matches (by reference). No-op if it's already gone.
    func closeTab(matching tree: PaneTreeView) {
        if let idx = tabs.firstIndex(where: { $0.tree === tree }) {
            closeTab(idx)
        }
    }

    /// Add an already-built PaneTreeView as a new tab (a new or restored tree).
    private func addTab(tree: PaneTreeView, transition: TabTransition = .none,
                        customTitle: String? = nil) {
        tree.translatesAutoresizingMaskIntoConstraints = false
        // Close this tab when its last pane closes. Must be found by tree reference, not by
        // the current index into the tabs array (stays correct even if tabs are reordered).
        tree.onAllPanesClosed = { [weak self, weak tree] in
            guard let self = self, let tree = tree,
                  let idx = self.tabs.firstIndex(where: { $0.tree === tree })
            else { return }
            self.closeTab(idx)
        }
        // The tab title follows the root pane's first leaf session title. Since it shows the
        // current directory when there's no explicit OSC title, also subscribe to cwd changes
        // (OSC 7) so it refreshes on those too.
        let titleSub: AnyCancellable
        if let session = tree.root.leaves().first?.session {
            titleSub = session.$title.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.refreshTabBar()
            }
            session.onCwdChanged = { [weak self] _ in
                DispatchQueue.main.async { self?.refreshTabBar() }
            }
        } else {
            titleSub = AnyCancellable {}
        }
        tabs.append(Tab(tree: tree, titleSub: titleSub, customTitle: customTitle))
        selectTab(tabs.count - 1, transition: transition)
        refreshTabBar()
    }

    func selectTab(_ index: Int, transition: TabTransition = .none) {
        guard index >= 0, index < tabs.count else { return }
        if swipeActive || swipeAnimating { abortSwipe() }

        // Capture the outgoing tab's pixels BEFORE removeFromSuperview() tears it down.
        // Only for a real switch between two distinct, animation-enabled tabs.
        var switchOverlay: (image: NSImage, frame: NSRect, fromIndex: Int)?
        if case .switch(let fromIndex) = transition,
           Motion.enabled,
           TabTransitionStyle.current != .none,
           fromIndex >= 0, fromIndex < tabs.count, fromIndex != index {
            let outgoing = tabs[fromIndex].tree
            // Only snapshot if that tree is actually the one on screen right now, and the
            // capture succeeds (zero-size → nil → instant path, spec §Snapshot fidelity).
            if outgoing.superview === contentContainer,
               let image = Motion.snapshot(of: outgoing) {
                // outgoing.frame is in contentContainer's coordinates — exactly where the
                // overlay must sit.
                switchOverlay = (image, outgoing.frame, fromIndex)
            }
        }

        currentIndex = index
        for t in tabs { t.tree.removeFromSuperview() }
        let tree = tabs[index].tree
        // The pane last used in this tab. When addSubview attaches the tree to the window,
        // each surface's viewDidMoveToWindow → makeFirstResponder → onFocus fires synchronously
        // and overwrites activeLeaf (with the last pane in traversal order), so we capture the
        // intended value *up front* and restore it afterward.
        let restoreTarget = tree.activeLeaf
        contentContainer.addSubview(tree)
        NSLayoutConstraint.activate([
            tree.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            tree.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            tree.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            tree.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        // Restore active + first responder to the last-used pane (undoing the onFocus clobber above).
        tree.setActive(restoreTarget)
        // Every pane in the incoming tab must repaint its current grid — not just the
        // focused one. Output that arrived while the tab was backgrounded couldn't be
        // drawn (the surfaces were off-window, so Metal had no drawable), and only the
        // active pane gets focused above. Lay out the re-added tree first so the Metal
        // drawables are sized to the content area, then force every leaf to repaint.
        contentContainer.layoutSubtreeIfNeeded()
        tree.repaintAllLeaves()
        if index < tabs.count {
            window?.title = displayTitle(tabs[index])
        }
        refreshTabBar()

        // The incoming tree may carry a leftover from-state if a prior create/switch
        // animation on this same view was superseded. Reset to the final visual state
        // unconditionally; the branches below re-apply a from-state if they animate.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tree.layer?.opacity = 1
        tree.layer?.transform = CATransform3DIdentity
        CATransaction.commit()

        if case .create = transition, Motion.enabled {
            animateTabCreate(tree)
        }

        // Run the switch animation only if we captured a snapshot above. Otherwise this is
        // the instant path (disabled / create / first show / nil-snapshot) — identical to today.
        if let ov = switchOverlay {
            animateTabSwitch(incoming: tree, overlayImage: ov.image,
                             overlayFrame: ov.frame, fromIndex: ov.fromIndex, toIndex: index)
        }
    }

    /// Tab-create motion (Task 2): the new tab's content fades + scales in.
    /// `opacity` 0→1 and `transform` 0.98→1.0 over `Motion.duration` easeOut.
    /// The tree already holds its final frame (constraints active); the transform
    /// is purely visual → zero surface reflow.
    private func animateTabCreate(_ tree: PaneTreeView) {
        // Final frame must exist before we read layer.bounds for the
        // center-composed scale; force a layout pass first.
        contentContainer.layoutSubtreeIfNeeded()
        guard let layer = tree.layer,
              layer.bounds.width > 0, layer.bounds.height > 0 else {
            // Zero-size (e.g. first tab before the window is shown) — skip motion.
            // This is NORMAL and CORRECT: the unconditional reset block above already
            // set the tree to opacity 1 / identity transform, so the tab ends at its
            // final visual state — just without an animation. Not a bug.
            return
        }

        // Center-composed scale: correct for ANY layer anchorPoint (a layer-backed
        // NSView's anchorPoint is not reliably 0.5,0.5; a plain MakeScale would
        // drift toward a corner instead of popping from the center).
        let s: CGFloat = 0.98
        let w = layer.bounds.width
        let h = layer.bounds.height
        let ap = layer.anchorPoint
        let v = CGPoint(x: w * (0.5 - ap.x), y: h * (0.5 - ap.y))
        let fromTransform = CATransform3DConcat(
            CATransform3DConcat(
                CATransform3DMakeTranslation(-v.x, -v.y, 0),
                CATransform3DMakeScale(s, s, 1)
            ),
            CATransform3DMakeTranslation(v.x, v.y, 0)
        )

        // Instantly set the FROM-state (no implicit animation here).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = fromTransform
        CATransaction.commit()

        // Animate TO the final state inside the shared 0.16s easeOut group.
        // Motion.run sets allowsImplicitAnimation = true, so these bare layer
        // assignments animate implicitly (see Task 1 Step 1's contract note).
        Motion.run({
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
        }, done: {
            // Guarantee the resting state even if the run was interrupted.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        })
    }

    /// Tab-switch motion: the outgoing tab (a bitmap overlay) and the incoming live tab both
    /// slide horizontally by a small delta while crossfading. Direction follows the index sign:
    /// moving to a higher index slides content left (new tab enters from the right), lower
    /// slides right. Layer-only — never touches frames — so the live surface never reflows.
    /// (Index order == visual order, even after drag-reorder; see Task 6 preamble.)
    ///
    /// Idiom note: the overlay (detached CALayer from Motion.overlay) uses the CAAnimationGroup
    /// + fillMode=.forwards + isRemovedOnCompletion=false idiom — NO model writes, exactly like
    /// closeTab. The incoming live PaneTreeView layer uses the Motion.run
    /// allowsImplicitAnimation idiom — exactly like animateTabCreate.
    private func animateTabSwitch(incoming tree: PaneTreeView, overlayImage: NSImage,
                                  overlayFrame: NSRect, fromIndex: Int, toIndex: Int) {
        guard let incomingLayer = tree.layer else { return }  // layer-backed; should not be nil
        // Ensure constraints have produced the final frame before we read/animate it.
        contentContainer.layoutSubtreeIfNeeded()

        // Cross-slide geometry (matches Rust halite). Higher target index = new tab
        // is to the right → it enters from the right while the old one exits left.
        let goingRight = toIndex > fromIndex
        let width = contentContainer.bounds.width
        let style = TabTransitionStyle.current

        // Per-style offsets + fade + duration. `slide` = full-width page swipe
        // (no fade), with a longer duration so the moving content is legible —
        // a full-width slide at the default 0.16s reads as an instant cut.
        // `crossfade` = the gentle 24pt slide + opacity; `none` handled upstream.
        let fade: Bool
        let incomingStart: CGFloat   // incoming layer's start x (ends at 0)
        let outgoingEnd: CGFloat     // outgoing overlay's end x (starts at 0)
        let dur: TimeInterval
        let timing: CAMediaTimingFunction
        switch style {
        case .slide:
            fade = false
            incomingStart = goingRight ? width : -width
            outgoingEnd = goingRight ? -width : width
            dur = Self.tabSlideDuration
            timing = Self.tabSlideTiming()   // shared with the trackpad-swipe settle
        case .crossfade, .none:
            fade = true
            let delta: CGFloat = 24
            incomingStart = goingRight ? delta : -delta
            outgoingEnd = goingRight ? -delta : delta
            dur = Motion.duration
            timing = Motion.timing
        }

        // Outgoing overlay sits exactly where the old tree was; it slides to `outgoingEnd`.
        let overlay = Motion.overlay(image: overlayImage, frame: overlayFrame, in: contentContainer)

        // BOTH sides use EXPLICIT CABasicAnimation. The incoming is a live NSView's
        // backing layer under Auto Layout; an implicit transform animation on it
        // gets clobbered by AppKit's layout-driven geometry updates (the layer
        // snaps to identity → "one screen frozen, one sliding"). An explicit
        // animation plays on the presentation layer regardless of the model, so the
        // model stays at the final (identity) value and the slide actually runs.
        incomingLayer.opacity = 1   // model = final; the anim drives the presentation

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak tree] in
            overlay.removeFromSuperlayer()
            tree?.layer?.removeAnimation(forKey: "switchIn")
        }

        // Incoming: slide from off-screen to 0 (+ optional fade in).
        let iSlide = CABasicAnimation(keyPath: "transform.translation.x")
        iSlide.fromValue = incomingStart
        iSlide.toValue = 0
        var inAnims = [iSlide]
        if fade {
            let iFade = CABasicAnimation(keyPath: "opacity")
            iFade.fromValue = 0.0
            iFade.toValue = 1.0
            inAnims.append(iFade)
        }
        let iGroup = CAAnimationGroup()
        iGroup.animations = inAnims
        iGroup.duration = dur
        iGroup.timingFunction = timing
        incomingLayer.add(iGroup, forKey: "switchIn")

        // Outgoing overlay (detached CALayer): slide 0 → outgoingEnd (+ optional fade out).
        // fillMode=.forwards pins the end state until the completion removes it.
        let oSlide = CABasicAnimation(keyPath: "transform.translation.x")
        oSlide.fromValue = 0
        oSlide.toValue = outgoingEnd
        var outAnims = [oSlide]
        if fade {
            let oFade = CABasicAnimation(keyPath: "opacity")
            oFade.fromValue = 1.0
            oFade.toValue = 0.0
            outAnims.append(oFade)
        }
        let oGroup = CAAnimationGroup()
        oGroup.animations = outAnims
        oGroup.duration = dur
        oGroup.timingFunction = timing
        oGroup.isRemovedOnCompletion = false
        oGroup.fillMode = .forwards
        overlay.add(oGroup, forKey: "switchOut")

        CATransaction.commit()
    }

    /// Re-apply the active-pane indicator setting to every tab's pane tree.
    func refreshPaneIndicators() {
        for tab in tabs { tab.tree.refreshIndicators() }
    }

    // MARK: - Interactive 2-finger swipe (TabSwipeHandler)

    /// Live finger-tracking. The current tab stays a live view (it remains the sole
    /// scroll/event target — its layer transform is visual-only and doesn't move
    /// its hit-test frame), while the neighbor is shown as a **snapshot layer**
    /// (a CALayer, so it never intercepts events or steals first responder the way
    /// a live sibling view would). Both follow the accumulated translation.
    func tabSwipeUpdate(translation dx: CGFloat) {
        guard !swipeAnimating, tabs.count > 1 else { return }
        let width = contentContainer.bounds.width
        guard width > 1 else { return }

        if !swipeActive {
            guard abs(dx) > 1 else { return }   // wait for a clear direction
            let goPrev = dx > 0                 // swipe fingers right → previous tab
            let neighborIndex = goPrev ? (currentIndex - 1 + tabs.count) % tabs.count
                                       : (currentIndex + 1) % tabs.count
            guard neighborIndex != currentIndex else { return }
            swipeActive = true
            swipeFromRight = !goPrev            // next tab enters from the right
            swipeNeighborIndex = neighborIndex

            // Snapshot the neighbor (detached). Size it to the content area first so
            // its Metal surfaces lay out and render at the right resolution.
            let neighborTree = tabs[neighborIndex].tree
            if neighborTree.superview == nil {
                neighborTree.frame = contentContainer.bounds
                neighborTree.layoutSubtreeIfNeeded()
            }
            if let img = Motion.snapshot(of: neighborTree) {
                swipeNeighborLayer = Motion.overlay(image: img, frame: contentContainer.bounds,
                                                    in: contentContainer)
            }
        }

        let neighborStart = swipeFromRight ? width : -width
        setSwipeTranslation(tabs[currentIndex].tree.layer, dx)
        setSwipeTranslation(swipeNeighborLayer, neighborStart + dx)
    }

    /// Release: commit the switch if dragged past ~20% of the width in the locked
    /// direction, otherwise snap back. Commit hands off to the normal `selectTab`
    /// path (same as keyboard) once the slide finishes, so focus + tab-bar stay
    /// consistent; the snapshot layer is removed after the live tab is in place.
    func tabSwipeEnd(translation dx: CGFloat, velocity: CGFloat) {
        guard swipeActive else { return }
        let width = contentContainer.bounds.width
        let neighborStart = swipeFromRight ? width : -width
        // Commit on distance OR a fast flick. swipeFromRight (next) commits on a
        // negative drag/flick; prev on positive. The flick check makes a quick
        // short swipe switch immediately instead of needing to drag 1/8 of the width.
        let distThreshold = width * 0.12
        let velThreshold: CGFloat = 6
        let commit = swipeFromRight ? (dx < -distThreshold || velocity < -velThreshold)
                                    : (dx > distThreshold || velocity > velThreshold)
        let neighborIndex = swipeNeighborIndex
        swipeActive = false
        swipeAnimating = true

        // Settle both layers from the release offset to the target: commit →
        // dx = -neighborStart (neighbor reaches 0, current slides fully off);
        // cancel → dx = 0 (current back, neighbor back off-screen).
        let targetDx: CGFloat = commit ? -neighborStart : 0
        startSwipeSettle(from: dx, to: targetDx, neighborStart: neighborStart) { [weak self] in
            guard let self else { return }
            if commit {
                self.setSwipeTranslation(self.tabs[self.currentIndex].tree.layer, 0)
                self.endSwipe()
                // Real switch (instant) — same path as keyboard nav, so first
                // responder, title, and tab-bar selection are all correct. The live
                // neighbor lands at center under the snapshot; then drop the snapshot.
                self.selectTab(neighborIndex, transition: .none)
                self.swipeNeighborLayer?.removeFromSuperlayer()
                self.swipeNeighborLayer = nil
            } else {
                self.swipeNeighborLayer?.removeFromSuperlayer()
                self.swipeNeighborLayer = nil
                self.setSwipeTranslation(self.tabs[self.currentIndex].tree.layer, 0)
                self.endSwipe()
            }
        }
    }

    /// Settle the swipe to its target with the SHARED tab-slide motion (same
    /// duration + curve as the keyboard/click cross-slide), so both decelerate
    /// identically. Explicit CABasicAnimations on the current tree layer and the
    /// neighbor snapshot; `done` runs on the transaction completion (guarded by
    /// `swipeAnimating` so an abort that already cleaned up wins).
    private func startSwipeSettle(from dx: CGFloat, to targetDx: CGFloat,
                                  neighborStart: CGFloat, done: @escaping () -> Void) {
        let currentLayer = tabs[currentIndex].tree.layer
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.swipeAnimating else { return }
            done()
        }
        slideSwipeLayer(currentLayer, from: dx, to: targetDx)
        slideSwipeLayer(swipeNeighborLayer, from: neighborStart + dx, to: neighborStart + targetDx)
        CATransaction.commit()
    }

    /// Animate a layer's translation.x from→to with the shared tab-slide motion.
    /// Explicit (plays on the presentation layer regardless of the model); the
    /// model is left at the final value.
    private func slideSwipeLayer(_ layer: CALayer?, from: CGFloat, to: CGFloat) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(to, 0, 0)
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "transform.translation.x")
        a.fromValue = from
        a.toValue = to
        a.duration = Self.tabSlideDuration
        a.timingFunction = Self.tabSlideTiming()
        layer.add(a, forKey: "swipeSettle")
    }

    private func endSwipe() {
        swipeNeighborIndex = -1
        swipeActive = false
        swipeAnimating = false
    }

    /// Tear down an in-flight swipe before a non-swipe path (keyboard/click switch)
    /// takes over, so nothing is left offset.
    private func abortSwipe() {
        // endSwipe() clears swipeAnimating first, so any in-flight settle's
        // completion block early-returns (its `done` won't fire after this).
        endSwipe()
        swipeNeighborLayer?.removeAnimation(forKey: "swipeSettle")
        swipeNeighborLayer?.removeFromSuperlayer()
        swipeNeighborLayer = nil
        if currentIndex >= 0, currentIndex < tabs.count {
            let layer = tabs[currentIndex].tree.layer
            layer?.removeAnimation(forKey: "swipeSettle")
            setSwipeTranslation(layer, 0)
        }
    }

    private func setSwipeTranslation(_ layer: CALayer?, _ x: CGFloat) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(x, 0, 0)
        CATransaction.commit()
    }

    /// Move a tab from one position to another (drag-to-reorder).
    func reorderTab(from: Int, to: Int) {
        guard from != to, from >= 0, from < tabs.count, to >= 0, to < tabs.count else {
            refreshTabBar()
            return
        }
        let moved = tabs.remove(at: from)
        tabs.insert(moved, at: to)
        // Keep currentIndex pointing at the same tab after the shuffle.
        if currentIndex == from {
            currentIndex = to
        } else if from < currentIndex && to >= currentIndex {
            currentIndex -= 1
        } else if from > currentIndex && to <= currentIndex {
            currentIndex += 1
        }
        refreshTabBar()
    }

    func closeTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }

        // Animate only when the tab being closed is the "currently visible" one, tabs remain
        // after closing, animation is enabled, and a snapshot can be captured. Everything else
        // (closing a background tab / the last tab / snapshot failure / Reduce Motion / toggle
        // off) keeps the existing instant path.
        //
        // The tabs.count > 1 guard is checked *before* remove(at:) — i.e. it guarantees a next
        // tab exists. If tabs.isEmpty after remove(at:), that path ends here (window close, no
        // overlay to clean up). Otherwise overlay cleanup + next-tab selection follow.
        //
        // The overlay is laid pixel-for-pixel over the still-alive closing tree before teardown,
        // so that even when selectTab instantly swaps in the next tree the overlay covers it without a flicker.
        var overlay: CALayer?
        if Motion.enabled,
           index == currentIndex,
           tabs.count > 1,
           let image = Motion.snapshot(of: tabs[index].tree) {
            overlay = Motion.overlay(
                image: image,
                frame: contentContainer.bounds,
                in: contentContainer
            )
        }

        tabs[index].tree.root.terminateAll()
        tabs.remove(at: index)

        if tabs.isEmpty {
            // The last tab was closed — close the window (out of scope here). Thanks to the
            // guard above (tabs.count > 1), no overlay is ever created here, so there's nothing to clean up.
            window?.performClose(nil)
            return
        }
        if currentIndex >= tabs.count { currentIndex = tabs.count - 1 }
        // Show the next tab live, instantly (.none). The overlay slides/fades on top of it.
        selectTab(currentIndex)

        guard let overlay else { return }
        // Closing-content snapshot: slides down (~6% of height) while fading out → removed.
        // In the non-flipped coordinate system, "down" is -y. Since it's a detached CALayer
        // (no view .animator()), it uses the same explicit CABasicAnimation idiom as bell-flash.
        let dy = overlay.bounds.height * 0.06
        let fromPos = overlay.position
        let toPos = CGPoint(x: fromPos.x, y: fromPos.y - dy)

        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: fromPos)
        slide.toValue = NSValue(point: toPos)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = Motion.duration
        group.timingFunction = Motion.timing
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        // We don't write the model values separately. fillMode = .forwards pins the
        // slid/faded final state from completion until removal, so no model update is needed.
        // (On a vanilla CALayer with no delegate, a bare model assignment triggers Core
        // Animation's default implicit animation — like the handleBell idiom, we don't touch the model before/after add.)
        overlay.add(group, forKey: "tabClose")

        // Remove the overlay after the animation. Each close captures only its own overlay
        // (not self), so rapid successive closes are safe with no shared state.
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration) {
            overlay.removeFromSuperlayer()
        }
    }

    func closeCurrentTab() {
        closeTab(currentIndex)
    }

    /// Received when DamsonSurfaceView sends Cmd+W up the responder chain. Closes the active
    /// tab's active pane (if it's the last pane in the tree, PaneTreeView cascades through
    /// onAllPanesClosed to close the tab/window).
    @objc func performCloseTab(_ sender: Any?) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.closeActive()
    }

    /// Cmd+D — horizontal split (left/right).
    @objc func splitPaneHorizontally(_ sender: Any?) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.split(direction: .horizontal)
    }

    /// Cmd+Shift+D — vertical split (top/bottom).
    @objc func splitPaneVertically(_ sender: Any?) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.split(direction: .vertical)
    }

    /// For damson-cli IPC — takes the direction directly and splits the active tab's active pane.
    func splitActive(direction: SplitDirection) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.split(direction: direction)
    }

    /// damson-cli `focus-pane` — move focus in the active tab's pane tree.
    func focusActivePane(_ dir: PaneFocusDirection) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.moveFocus(dir)
    }

    /// damson-cli `close-pane` — close the active tab's active pane (cascades to tab/window when last).
    func closeActivePane() {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.closeActive()
    }

    /// damson-cli `resize-pane` — nudge the divider governing the active pane by `cells`
    /// in `dir`. Returns false when there's no split on that axis.
    @discardableResult
    func resizeActivePane(_ dir: PaneFocusDirection, cells: Int) -> Bool {
        guard currentIndex < tabs.count, let win = window else { return false }
        return tabs[currentIndex].tree.resizeActiveDivider(
            dir, fraction: WindowResize.dividerFraction(dir, cells: cells,
                                                         session: activeSession, window: win))
    }

    /// damson-cli `list-panes` — panes of the active tab in traversal order.
    func paneList() -> [PaneInfo] {
        guard currentIndex < tabs.count else { return [] }
        return tabs[currentIndex].tree.paneSessionsInOrder().enumerated().map { (i, pair) in
            PaneInfo(index: i, cols: pair.session.grid.cols,
                     rows: pair.session.grid.rows, active: pair.active)
        }
    }

    /// damson-cli `resize-window` — size the window so the active terminal is `cols`×`rows`.
    @discardableResult
    func resizeWindowToGrid(cols: Int, rows: Int) -> Bool {
        guard let win = window, let session = activeSession else { return false }
        return WindowResize.resize(window: win, to: (cols, rows), basedOn: session)
    }

    /// Number of panes (leaves) in each tab — for the list-tabs IPC response.
    var tabPaneCounts: [Int] {
        tabs.map { $0.tree.root.leaves().count }
    }

    // MARK: - Tab keyboard navigation

    /// Cmd+Shift+] / Ctrl+Tab — next tab (wrap).
    @objc func selectNextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let from = currentIndex
        selectTab((currentIndex + 1) % tabs.count, transition: .switch(fromIndex: from))
    }

    /// Cmd+Shift+[ / Ctrl+Shift+Tab — previous tab (wrap).
    @objc func selectPreviousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let from = currentIndex
        selectTab((currentIndex - 1 + tabs.count) % tabs.count, transition: .switch(fromIndex: from))
    }

    /// Cmd+1..9 — the nth tab (9 is the last tab). NSMenuItem.tag holds the 1-based number.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let n = item.tag
        let idx = (n == 9) ? tabs.count - 1 : n - 1
        if idx >= 0 && idx < tabs.count {
            selectTab(idx, transition: .switch(fromIndex: currentIndex))
        }
    }

    // MARK: - Pane focus keyboard navigation

    /// Cmd+Opt+arrow — move focus to an adjacent pane.
    @objc func focusPaneLeft(_ sender: Any?) { moveFocus(.left) }
    @objc func focusPaneRight(_ sender: Any?) { moveFocus(.right) }
    @objc func focusPaneUp(_ sender: Any?) { moveFocus(.up) }
    @objc func focusPaneDown(_ sender: Any?) { moveFocus(.down) }

    private func moveFocus(_ dir: PaneFocusDirection) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.moveFocus(dir)
    }

    /// Cmd+Shift+arrow — swap positions with an adjacent pane.
    @objc func swapPaneLeft(_ sender: Any?) { swapDirectional(.left) }
    @objc func swapPaneRight(_ sender: Any?) { swapDirectional(.right) }
    @objc func swapPaneUp(_ sender: Any?) { swapDirectional(.up) }
    @objc func swapPaneDown(_ sender: Any?) { swapDirectional(.down) }

    private func swapDirectional(_ dir: PaneFocusDirection) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.swapDirectional(dir)
    }

    private func refreshTabBar() {
        let titles = tabs.map { displayTitle($0) }
        tabBar.update(titles: titles, selectedIndex: currentIndex)
    }

    /// Title to show on the tab: user-assigned title > session (OSC/process) title > current directory > "Damson".
    private func displayTitle(_ tab: Tab) -> String {
        if let custom = tab.customTitle, !custom.isEmpty { return custom }
        guard let session = tab.tree.root.leaves().first?.session else { return "Damson" }
        if !session.title.isEmpty { return session.title }
        // If there's no cwd tracked via OSC 7, fall back to the actual process cwd (proc_pidinfo).
        if let dir = session.currentDirectory ?? session.currentWorkingDirectory {
            return Self.prettyDir(dir)
        }
        return "Damson"
    }

    /// Make a path tab-friendly — home becomes "~", otherwise the last path component (folder name).
    static func prettyDir(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? path : base
    }

    /// Tab double-click → inline edit result. An empty string clears the user title and reverts to the automatic title.
    private func renameTab(_ index: Int, to title: String) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].customTitle = title.isEmpty ? nil : title
        refreshTabBar()
        // Return the focus lost when editing ended back to the active pane.
        if currentIndex < tabs.count,
           case .leaf(_, let surface) = tabs[currentIndex].tree.activeLeaf.kind {
            window?.makeFirstResponder(surface)
        }
    }

    // MARK: - NSWindowDelegate

    /// Invoked at the very start of `windowWillClose`, BEFORE the per-tab terminate sweep.
    /// A tmux-backed host uses this to send `detach-client` first, so the kill-panes the
    /// sweep would otherwise fire at live panes are suppressed (closing the window means
    /// detach — leave the tmux session intact — never kill).
    var onWindowWillClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onWindowWillClose?()
        for t in tabs { t.tree.root.terminateAll() }
    }

    // On full-screen enter/exit: update the leading reservation (traffic lights) + top inset (menu bar).
    func windowDidEnterFullScreen(_ notification: Notification) {
        updateFullScreenInset()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        updateFullScreenInset()
        DispatchQueue.main.async { [weak self] in self?.centerTrafficLights() }
    }
    // The system resets the traffic-light positions on resize, so re-center them.
    func windowDidResize(_ notification: Notification) {
        centerTrafficLights()
    }
}
