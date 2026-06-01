import AppKit
import Combine
import HaliteTerminal

/// Compact 모드 전용 윈도우 컨트롤러. 하나의 NSWindow가 N개 HaliteSession을
/// 멀티플렉스. NSWindow 네이티브 탭 비활성(`tabbingMode = .disallowed`) +
/// 커스텀 CompactTabBarView를 contentView 최상단에 둬서 신호등과 같은 row에 탭.
///
/// hiterm(`~/dev/hiterm`)의 MainWindowController 구조 차용.
final class CompactWindowController: NSWindowController, NSWindowDelegate {
    /// 탭 = (PaneTreeView, 그 트리의 첫 leaf 세션의 title 구독).
    /// 한 탭 안에서 Cmd+D / Cmd+Shift+D 로 split하면 그 탭의 트리에 leaf 추가됨.
    private struct Tab {
        let tree: PaneTreeView
        var titleSub: AnyCancellable
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

    /// 외부에서 list-tabs / switch-tab 등을 위한 session 표현.
    /// 각 탭의 root pane(첫 leaf) 세션 — 탭 제목 추적용.
    var sessions: [HaliteSession] {
        tabs.compactMap { $0.tree.root.leaves().first?.session }
    }

    /// 현재 active 탭의 active pane (split 했을 때 포커스된 쪽).
    var activeSession: HaliteSession? {
        guard currentIndex < tabs.count else { return nil }
        let tree = tabs[currentIndex].tree
        if case .leaf(let s, _) = tree.activeLeaf.kind { return s }
        return nil
    }

    private var tabBar: CompactTabBarView!
    private var tabBarBackground: NSVisualEffectView!
    private var contentContainer: NSView!

    var hasTabs: Bool { !tabs.isEmpty }

    /// `restoring`이 있으면 그 탭/pane 레이아웃 + cwd로 복원, 없으면 빈 탭 1개.
    init(restoring: RestorableWindow? = nil) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "halite"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 480, height: 240)
        window.center()
        // 네이티브 탭 OFF — 우리가 직접 그리는 탭바 사용.
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)

        super.init(window: window)
        window.delegate = self

        setupViews()

        if let restore = restoring, !restore.tabs.isEmpty {
            for paneRestore in restore.tabs {
                let root = PaneNode.from(restorable: paneRestore)
                addTab(tree: PaneTreeView(restoredRoot: root))
            }
            let sel = restore.selectedTab
            if sel >= 0 && sel < tabs.count { selectTab(sel) }
        } else {
            addNewTab()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 현재 윈도우의 탭/pane 레이아웃 + cwd를 직렬화.
    func toRestorableWindow() -> RestorableWindow {
        RestorableWindow(
            tabs: tabs.map { $0.tree.root.toRestorable() },
            selectedTab: currentIndex
        )
    }

    deinit {
        for s in sessions { s.terminate() }
    }

    private func setupViews() {
        guard let contentView = window?.contentView else { return }

        // titlebar 영역에 깔리는 vibrancy (신호등 + 탭 뒤 배경).
        tabBarBackground = NSVisualEffectView()
        tabBarBackground.material = .hudWindow
        tabBarBackground.blendingMode = .behindWindow
        tabBarBackground.state = .followsWindowActiveState
        tabBarBackground.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabBarBackground)

        // 커스텀 탭 바.
        tabBar = CompactTabBarView()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.onTabSelected = { [weak self] idx in
            guard let self = self else { return }
            self.selectTab(idx, transition: .switch(fromIndex: self.currentIndex))
        }
        tabBar.onTabClosed = { [weak self] idx in self?.closeTab(idx) }
        tabBar.onNewTab = { [weak self] in self?.addNewTab() }
        tabBar.onTabReordered = { [weak self] from, to in self?.reorderTab(from: from, to: to) }
        contentView.addSubview(tabBar)

        // 세션 surface가 들어가는 컨테이너 — 탭 바 아래 채움.
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        // 탭 닫기 애니메이션 오버레이(스냅샷 레이어)의 호스트 — 미리 layer-backed로.
        contentContainer.wantsLayer = true
        contentView.addSubview(contentContainer)

        // titlebar 높이 측정 (대략 28pt). styleMask + fullSizeContentView 상태에서
        // contentLayoutGuide의 top이 titlebar 아래임을 활용 가능하지만, 우리 탭바는
        // titlebar 자리에 그려야 하므로 0부터 시작.
        let tabBarHeight: CGFloat = 38

        NSLayoutConstraint.activate([
            tabBarBackground.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBarBackground.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBarBackground.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBarBackground.heightAnchor.constraint(equalToConstant: tabBarHeight),

            tabBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: tabBarHeight),

            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: - Tab management

    @discardableResult
    func addNewTab() -> HaliteSession {
        let session = HaliteSession(config: HaliteConfig.fromUserDefaults())
        addTab(tree: PaneTreeView(rootSession: session), transition: .create)
        return session
    }

    /// 이미 구성된 PaneTreeView를 새 탭으로 추가 (신규 또는 복원된 트리).
    private func addTab(tree: PaneTreeView, transition: TabTransition = .none) {
        tree.translatesAutoresizingMaskIntoConstraints = false
        // 마지막 pane이 닫히면 이 탭을 닫음. tabs 배열의 현재 인덱스가 아니라
        // tree 참조로 찾아야 함 (탭이 재배열돼도 정확).
        tree.onAllPanesClosed = { [weak self, weak tree] in
            guard let self = self, let tree = tree,
                  let idx = self.tabs.firstIndex(where: { $0.tree === tree })
            else { return }
            self.closeTab(idx)
        }
        // 탭 제목은 root pane의 첫 leaf 세션 title을 따름.
        let titleSub: AnyCancellable
        if let session = tree.root.leaves().first?.session {
            titleSub = session.$title.receive(on: RunLoop.main).sink { [weak self] _ in
                self?.refreshTabBar()
            }
        } else {
            titleSub = AnyCancellable {}
        }
        tabs.append(Tab(tree: tree, titleSub: titleSub))
        selectTab(tabs.count - 1, transition: transition)
        refreshTabBar()
    }

    func selectTab(_ index: Int, transition: TabTransition = .none) {
        guard index >= 0, index < tabs.count else { return }

        // Capture the outgoing tab's pixels BEFORE removeFromSuperview() tears it down.
        // Only for a real switch between two distinct, animation-enabled tabs.
        var switchOverlay: (image: NSImage, frame: NSRect, fromIndex: Int)?
        if case .switch(let fromIndex) = transition,
           Motion.enabled,
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
        contentContainer.addSubview(tree)
        NSLayoutConstraint.activate([
            tree.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            tree.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            tree.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            tree.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        if case .leaf(_, let surface) = tree.activeLeaf.kind {
            window?.makeFirstResponder(surface)
        }
        if let firstSession = tree.root.leaves().first?.session {
            let title = firstSession.title
            window?.title = title.isEmpty ? "halite" : title
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

        // Slide delta: ~24pt. Higher target index → content moves left (negative x).
        let delta: CGFloat = 24
        let dir: CGFloat = (toIndex > fromIndex) ? -1 : 1
        let slide = delta * dir

        // Outgoing overlay sits exactly where the old tree was; it slides `slide` and fades out.
        let overlay = Motion.overlay(image: overlayImage, frame: overlayFrame, in: contentContainer)

        // Incoming live layer starts offset the OPPOSITE way (so it converges to identity) and
        // transparent. Commit the start state with actions disabled so it doesn't pre-animate.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incomingLayer.opacity = 0
        incomingLayer.transform = CATransform3DMakeTranslation(-slide, 0, 0)
        CATransaction.commit()

        // --- Outgoing overlay: slide + fade out via CAAnimationGroup ---
        // Detached CALayer (no NSView backing, no .animator()) → explicit CABasicAnimation,
        // exactly like closeTab. NO model writes on the overlay (model writes on a delegate-less
        // CALayer trigger implicit animations that double-stack). fillMode=.forwards pins the
        // end state until done removes the layer.
        let oSlide = CABasicAnimation(keyPath: "transform.translation.x")
        oSlide.fromValue = 0
        oSlide.toValue = slide
        let oFade = CABasicAnimation(keyPath: "opacity")
        oFade.fromValue = 1.0
        oFade.toValue = 0.0
        let oGroup = CAAnimationGroup()
        oGroup.animations = [oSlide, oFade]
        oGroup.duration = Motion.duration
        oGroup.timingFunction = Motion.timing
        oGroup.isRemovedOnCompletion = false
        oGroup.fillMode = .forwards
        overlay.add(oGroup, forKey: "switchOut")

        // --- Incoming live layer: slide to identity + fade in ---
        // Backed by a real NSView layer → use Motion.run with allowsImplicitAnimation=true,
        // bare layer assignments animate implicitly — exactly like animateTabCreate.
        Motion.run({
            incomingLayer.opacity = 1
            incomingLayer.transform = CATransform3DIdentity
        }, done: { [weak tree] in
            // Remove the overlay and hard-restore the live layer to identity, regardless of
            // whether a newer switch superseded this one (each animation targets its own
            // overlay; cleanup is idempotent and safe).
            overlay.removeFromSuperlayer()
            if let layer = tree?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = 1
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        })
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

        // 닫는 탭이 "현재 보이는" 탭이고, 닫은 뒤에도 탭이 남고, 애니메이션이 켜졌고,
        // 스냅샷이 떠질 때만 모션. 그 외(백그라운드 탭 닫기 / 마지막 탭 / 스냅샷 실패 /
        // Reduce Motion / 토글 off)는 기존 즉시 경로 그대로.
        //
        // tabs.count > 1 가드는 remove(at:) "이전"에 검사한다 — 즉 다음 탭이 존재함을 보장.
        // remove(at:) 후 tabs.isEmpty면 그 경로는 여기서 끝(윈도우 종료, 정리할 오버레이 없음).
        // 그렇지 않으면 오버레이 정리 + 다음 탭 선택이 이어진다.
        //
        // 오버레이는 teardown 이전에, 아직 살아있는 닫히는 트리 위에 픽셀 동일하게 올린다.
        // 그래야 selectTab으로 다음 트리를 즉시 교체해도 깜빡임 없이 오버레이가 위를 덮는다.
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
            // 마지막 탭이 닫힘 — 윈도우 종료(스코프 밖). 위 가드(tabs.count > 1)로 여기엔
            // 오버레이가 절대 만들어지지 않으므로 정리할 것이 없다.
            window?.performClose(nil)
            return
        }
        if currentIndex >= tabs.count { currentIndex = tabs.count - 1 }
        // 다음 탭을 즉시(.none) 라이브로 보여줌. 오버레이가 그 위에서 슬라이드/페이드.
        selectTab(currentIndex)

        guard let overlay else { return }
        // 닫히는 콘텐츠 스냅샷: 아래로(~6% 높이) 미끄러지며 페이드아웃 → 제거.
        // 비-flipped 좌표계라 "아래"는 -y. 분리된 CALayer이므로 (뷰의 .animator()가
        // 없으므로) bell-flash와 동일한 명시적 CABasicAnimation 관용구를 쓴다.
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

        // 모델값을 따로 쓰지 않는다. fillMode = .forwards 가 종료~제거 사이 동안
        // 슬라이드/페이드된 최종 상태를 그대로 고정하므로 모델 갱신이 불필요하다.
        // (delegate 없는 vanilla CALayer라 bare 모델 대입은 Core Animation의 기본
        // 암시적 애니메이션을 유발 — handleBell 관용구처럼 add 전후로 모델을 건드리지 않는다.)
        overlay.add(group, forKey: "tabClose")

        // 애니메이션 후 오버레이 제거. 각 close는 자기 오버레이만 캡처하므로
        // (self를 캡처하지 않음) 빠른 연속 닫기에도 공유 상태 없이 안전.
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration) {
            overlay.removeFromSuperlayer()
        }
    }

    func closeCurrentTab() {
        closeTab(currentIndex)
    }

    /// HaliteSurfaceView가 Cmd+W를 responder chain에 보낼 때 받음. 활성 탭의 활성
    /// pane을 닫음 (트리에 마지막 pane이면 PaneTreeView가 onAllPanesClosed로
    /// 탭/윈도우 종료까지 cascade).
    @objc func performCloseTab(_ sender: Any?) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.closeActive()
    }

    /// Cmd+D — 가로 split (좌/우).
    @objc func splitPaneHorizontally(_ sender: Any?) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.split(direction: .horizontal)
    }

    /// Cmd+Shift+D — 세로 split (위/아래).
    @objc func splitPaneVertically(_ sender: Any?) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.split(direction: .vertical)
    }

    /// halite-cli IPC용 — 방향을 직접 받아 active 탭의 active pane split.
    func splitActive(direction: SplitDirection) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.split(direction: direction)
    }

    /// 각 탭의 pane(leaf) 수 — list-tabs IPC 응답용.
    var tabPaneCounts: [Int] {
        tabs.map { $0.tree.root.leaves().count }
    }

    // MARK: - 탭 키보드 네비

    /// Cmd+Shift+] / Ctrl+Tab — 다음 탭 (wrap).
    @objc func selectNextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let from = currentIndex
        selectTab((currentIndex + 1) % tabs.count, transition: .switch(fromIndex: from))
    }

    /// Cmd+Shift+[ / Ctrl+Shift+Tab — 이전 탭 (wrap).
    @objc func selectPreviousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let from = currentIndex
        selectTab((currentIndex - 1 + tabs.count) % tabs.count, transition: .switch(fromIndex: from))
    }

    /// Cmd+1..9 — n번째 탭 (9는 마지막 탭). NSMenuItem.tag에 1-based 번호.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let n = item.tag
        let idx = (n == 9) ? tabs.count - 1 : n - 1
        if idx >= 0 && idx < tabs.count {
            selectTab(idx, transition: .switch(fromIndex: currentIndex))
        }
    }

    // MARK: - Pane focus 키보드 네비

    /// Cmd+Opt+화살표 — 인접 pane으로 focus 이동.
    @objc func focusPaneLeft(_ sender: Any?) { moveFocus(.left) }
    @objc func focusPaneRight(_ sender: Any?) { moveFocus(.right) }
    @objc func focusPaneUp(_ sender: Any?) { moveFocus(.up) }
    @objc func focusPaneDown(_ sender: Any?) { moveFocus(.down) }

    private func moveFocus(_ dir: PaneFocusDirection) {
        guard currentIndex < tabs.count else { return }
        tabs[currentIndex].tree.moveFocus(dir)
    }

    private func refreshTabBar() {
        let titles = tabs.map { tab in
            tab.tree.root.leaves().first?.session.title ?? "halite"
        }
        tabBar.update(titles: titles, selectedIndex: currentIndex)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        for t in tabs { t.tree.root.terminateAll() }
    }
}
