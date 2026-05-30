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

    init() {
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
        addNewTab()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
        tabBar.onTabSelected = { [weak self] idx in self?.selectTab(idx) }
        tabBar.onTabClosed = { [weak self] idx in self?.closeTab(idx) }
        tabBar.onNewTab = { [weak self] in self?.addNewTab() }
        contentView.addSubview(tabBar)

        // 세션 surface가 들어가는 컨테이너 — 탭 바 아래 채움.
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
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
        let tree = PaneTreeView(rootSession: session)
        tree.translatesAutoresizingMaskIntoConstraints = false
        // 마지막 leaf까지 닫혔으면 이 탭 자체를 닫음.
        let tabIndex = tabs.count
        tree.onAllPanesClosed = { [weak self] in
            self?.closeTab(tabIndex)
        }

        let titleSub = session.$title.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshTabBar()
        }
        tabs.append(Tab(tree: tree, titleSub: titleSub))

        selectTab(tabs.count - 1)
        refreshTabBar()
        return session
    }

    func selectTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
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
    }

    func closeTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].tree.root.terminateAll()
        tabs.remove(at: index)

        if tabs.isEmpty {
            window?.performClose(nil)
            return
        }
        if currentIndex >= tabs.count { currentIndex = tabs.count - 1 }
        selectTab(currentIndex)
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

    // MARK: - 탭 키보드 네비

    /// Cmd+Shift+] / Ctrl+Tab — 다음 탭 (wrap).
    @objc func selectNextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        selectTab((currentIndex + 1) % tabs.count)
    }

    /// Cmd+Shift+[ / Ctrl+Shift+Tab — 이전 탭 (wrap).
    @objc func selectPreviousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        selectTab((currentIndex - 1 + tabs.count) % tabs.count)
    }

    /// Cmd+1..9 — n번째 탭 (9는 마지막 탭). NSMenuItem.tag에 1-based 번호.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let n = item.tag
        let idx = (n == 9) ? tabs.count - 1 : n - 1
        if idx >= 0 && idx < tabs.count { selectTab(idx) }
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
