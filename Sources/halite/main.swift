import AppKit
import Combine
import HaliteControl
import HaliteTerminal
import SwiftUI

// 독립 halite.app의 진입점.
// SwiftPM 실행: `swift run halite`
// 추후 정식 .app 배포는 별도 Xcode 프로젝트로 그래듀에이션.

// raw binary로 실행됐다면 .app으로 wrap + relaunch.
// 한글 IME 첫 자모 race를 잡기 위해 필수 (LaunchServices 등록).
AppBundleTrampoline.relaunchInAppBundleIfNeeded()

/// 한 윈도우 + 한 pane 트리(Standard/Auto 모드). 네이티브 NSWindow 탭으로 여러
/// 윈도우가 묶이고, 각 윈도우 안에서 Cmd+D / Cmd+Shift+D로 pane split.
final class HaliteWindowController: NSWindowController, NSWindowDelegate {
    private let tree: PaneTreeView
    private var titleSubscription: AnyCancellable?
    private var tabStyleApplier: TabBarStyleApplier?

    /// 외부(settingsChanged/willTerminate)가 순회할 leaf 세션들.
    var sessions: [HaliteSession] { tree.root.leaves().map { $0.session } }
    /// 현재 active pane 세션 (없으면 첫 leaf).
    var activeSession: HaliteSession? {
        if case .leaf(let s, _) = tree.activeLeaf.kind { return s }
        return tree.root.leaves().first?.session
    }

    init(session: HaliteSession) {
        self.tree = PaneTreeView(rootSession: session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "halite"
        // SwiftUI NSHostingController 우회 — SwiftUI hosting layer가 leading edge에
        // 미세한 inset을 추가해서 cell-grid 첫 column이 가려지는 문제가 있음.
        // halite.app은 cmux integration용 SwiftUI API를 안 거치고 직접 NSView 사용.
        tree.translatesAutoresizingMaskIntoConstraints = false
        // contentView를 container로 감싸서 titlebar 영역에 NSVisualEffectView를
        // 깔 수 있는 자리를 만든다. (Standard/Auto 모드에선 inset 0 — TabBarStyleApplier가
        // compact일 때만 inset; 이 컨트롤러는 non-compact 전용이므로 항상 0.)
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tree)
        let surfaceTop = tree.topAnchor.constraint(equalTo: container.topAnchor)
        NSLayoutConstraint.activate([
            tree.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tree.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tree.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            surfaceTop,
        ])
        window.contentView = container
        window.contentMinSize = NSSize(width: 320, height: 200)
        window.center()
        // 같은 식별자를 갖는 윈도우들이 macOS 네이티브 탭 그룹으로 자동 묶임.
        // Cmd+T로 새 탭 생성, Cmd+Shift+] / Cmd+Shift+[ 가 next/prev (AppKit 자동).
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "halite.terminal"
        super.init(window: window)
        window.delegate = self
        // 마지막 pane이 닫히면 윈도우(=네이티브 탭) 닫기.
        tree.onAllPanesClosed = { [weak self] in
            self?.window?.performClose(nil)
        }
        // 제목은 root 첫 leaf 세션 따라감 (Compact와 동일 정책).
        if let firstSession = tree.root.leaves().first?.session {
            titleSubscription = firstSession.$title
                .receive(on: RunLoop.main)
                .sink { [weak self] newTitle in
                    let base = newTitle.isEmpty ? "halite" : newTitle
                    self?.window?.title = base + BuildInfo.titleSuffix
                }
        }
        // 사용자가 Settings에서 고른 탭 스타일 적용 (이 컨트롤러는 non-compact만).
        let applier = TabBarStyleApplier(
            window: window,
            container: container,
            surface: tree,
            surfaceTopConstraint: surfaceTop
        )
        applier.apply(TabBarStyle.current)
        self.tabStyleApplier = applier
        WindowChrome.applyFromDefaults(to: window)
    }

    func applyTabBarStyle(_ style: TabBarStyle) {
        tabStyleApplier?.apply(style)
    }

    // 메서드 이름은 CompactWindowController와 동일 — HaliteSurfaceView의 Cmd+W
    // (performCloseTab:) 및 Split 메뉴(splitPaneHorizontally:/Vertically:)가
    // responder chain으로 두 컨트롤러 모두에 동일하게 도달.

    @objc func splitPaneHorizontally(_ sender: Any?) {
        tree.split(direction: .horizontal)
    }

    @objc func splitPaneVertically(_ sender: Any?) {
        tree.split(direction: .vertical)
    }

    /// halite-cli IPC용 — 방향을 직접 받아 active pane split.
    func splitActive(direction: SplitDirection) {
        tree.split(direction: direction)
    }

    /// Cmd+W — active pane 닫기. 마지막 pane이면 onAllPanesClosed로 윈도우 닫힘.
    @objc func performCloseTab(_ sender: Any?) {
        tree.closeActive()
    }

    // Pane focus 네비 (Cmd+Opt+화살표).
    @objc func focusPaneLeft(_ sender: Any?) { tree.moveFocus(.left) }
    @objc func focusPaneRight(_ sender: Any?) { tree.moveFocus(.right) }
    @objc func focusPaneUp(_ sender: Any?) { tree.moveFocus(.up) }
    @objc func focusPaneDown(_ sender: Any?) { tree.moveFocus(.down) }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        // 이 윈도우의 모든 pane 세션 종료. (PaneTreeView.deinit도 terminateAll
        // 하지만 윈도우 닫힘 시점에 명시적으로 한 번 — 이중 종료는 PTYHost가
        // childPID=-1로 idempotent.)
        tree.root.terminateAll()
        // 마지막 윈도우면 application이 자동 종료
        // (applicationShouldTerminateAfterLastWindowClosed == true).
    }
}

final class HaliteAppDelegate: NSObject, NSApplicationDelegate {
    /// 살아있는 single-session 컨트롤러들 (Standard/Auto 모드).
    fileprivate var controllers: [HaliteWindowController] = []
    /// 살아있는 multi-session 컨트롤러들 (Compact 모드).
    fileprivate var compactControllers: [CompactWindowController] = []
    private var settingsWindow: NSWindow?
    /// halite-cli 와의 IPC. 첫 윈도우 생성 후 bind.
    private var controlSocket: ControlSocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS press-and-hold(악센트 팝업) 제어. 켜져 있으면 키를 길게 눌러도
        // 텍스트 입력 시스템이 "악센트 대기"로 가로채 키 반복이 억제된다(키에 따라
        // 들쭉날쭉 — f/q/x 등은 아예 반복 안 됨). 터미널은 모든 키가 반복돼야 하므로
        // 기본은 OFF(반복). 설정 토글(halite.pressAndHold)이 ON이면 macOS 기본(악센트
        // 팝업)으로. 미설정 → false → ApplePressAndHoldEnabled=false.
        let pressAndHold = UserDefaults.standard.bool(forKey: "halite.pressAndHold")
        UserDefaults.standard.set(pressAndHold, forKey: "ApplePressAndHoldEnabled")

        // 이전 세션 상태가 있고 Compact 모드면 그 레이아웃 + cwd로 복원, 아니면 새 창.
        if TabBarStyle.current == .compact,
           let state = SessionRestore.load(), !state.windows.isEmpty {
            for restoreWindow in state.windows {
                spawnCompactWindow(restoring: restoreWindow)
            }
        } else {
            spawnWindow()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged(_:)),
            name: .haliteSettingsChanged,
            object: nil
        )
        bindControlSocket()
        // Sparkle은 lazy init — 첫 access 시점에 자동 시작.
        _ = HaliteUpdater.shared
    }

    /// 종료 직전 — 현재 Compact 윈도우들의 레이아웃 + cwd 저장.
    func applicationWillTerminate(_ notification: Notification) {
        for c in controllers { for s in c.sessions { s.terminate() } }
        for cc in compactControllers { for s in cc.sessions { s.terminate() } }
        // 세션 상태 저장 (Compact 윈도우만 — single-session/native-tab 모드는 복원 안 함).
        let windows = compactControllers.map { $0.toRestorableWindow() }
        if windows.isEmpty {
            SessionRestore.clear()
        } else {
            SessionRestore.save(RestorableState(windows: windows))
        }
    }

    // MARK: - halite-cli IPC

    private func bindControlSocket() {
        let server = ControlSocketServer()
        do {
            let path = try server.start(handler: { [weak self] cmd in
                // handler는 worker thread에서 호출됨 → main으로 hop 후 결과 대기.
                guard let self = self else { return .err("halite is shutting down") }
                let sem = DispatchSemaphore(value: 0)
                var resp: ControlResponse = .err("dispatch lost")
                DispatchQueue.main.async {
                    resp = self.dispatch(controlCommand: cmd)
                    sem.signal()
                }
                let r = sem.wait(timeout: .now() + 2.0)
                if r == .timedOut {
                    return .err("timeout waiting for halite to process command")
                }
                return resp
            })
            self.controlSocket = server
            NSLog("halite: control socket listening at %@", path)
        } catch {
            NSLog("halite: failed to bind control socket: %@", String(describing: error))
        }
    }

    /// `dispatch` — main actor에서 호출됨. 모든 분기 동기 처리.
    @MainActor
    private func dispatch(controlCommand cmd: ControlCommand) -> ControlResponse {
        switch cmd.kind {
        case .newTab:
            newTabOrWindow()
            return .ok()
        case .split(let dir):
            let direction: SplitDirection = (dir == .vertical) ? .vertical : .horizontal
            if let active = activeCompact() {
                active.splitActive(direction: direction)
                return .ok()
            }
            if let single = activeSingleController() {
                single.splitActive(direction: direction)
                return .ok()
            }
            return .err("no active window to split")
        case .closeTab:
            // Compact controller가 키 윈도우면 활성 탭 닫음. 아니면 윈도우 닫음.
            if let active = activeCompact() {
                active.closeCurrentTab()
                return .ok()
            }
            if let win = NSApp.keyWindow ?? controllers.last?.window {
                win.performClose(nil)
                return .ok()
            }
            return .err("no active window to close")
        case .switchTab(let index):
            if let active = activeCompact() {
                guard index >= 0, index < active.sessions.count else {
                    return .err("tab index \(index) out of range (have \(active.sessions.count) tabs)")
                }
                active.selectTab(index)
                return .ok()
            }
            let tabs = currentNativeTabs()
            guard index >= 0, index < tabs.count else {
                return .err("tab index \(index) out of range (have \(tabs.count) tabs)")
            }
            tabs[index].makeKeyAndOrderFront(nil)
            return .ok()
        case .listTabs:
            if let active = activeCompact() {
                // 각 탭의 실제 pane(leaf) 수 보고.
                let list = active.tabPaneCounts.enumerated().map { (i, count) in
                    TabInfo(index: i, pane_count: count)
                }
                return .tabs(list)
            }
            // Standard/Auto: 네이티브 탭마다 그 윈도우의 pane 수.
            let single = controllers.filter { $0.window?.isVisible == true }
            if !single.isEmpty {
                let tabs = currentNativeTabs()
                let list = tabs.enumerated().map { (i, win) -> TabInfo in
                    let count = controllers.first { $0.window === win }?.sessions.count ?? 1
                    return TabInfo(index: i, pane_count: count)
                }
                return .tabs(list)
            }
            let tabs = currentNativeTabs()
            return .tabs(tabs.enumerated().map { (i, _) in TabInfo(index: i, pane_count: 1) })
        }
    }

    /// 현재 키 윈도우가 CompactWindowController가 소유한 윈도우면 그 controller.
    @MainActor
    private func activeCompact() -> CompactWindowController? {
        guard let keyWindow = NSApp.keyWindow else {
            return compactControllers.first
        }
        return compactControllers.first(where: { $0.window === keyWindow })
    }

    /// 현재 키 윈도우가 HaliteWindowController(Standard/Auto)가 소유한 것이면 그 controller.
    @MainActor
    private func activeSingleController() -> HaliteWindowController? {
        guard let keyWindow = NSApp.keyWindow else {
            return controllers.first
        }
        return controllers.first(where: { $0.window === keyWindow }) ?? controllers.first
    }

    /// 네이티브 탭 그룹 윈도우 목록 (Standard/Auto 모드).
    @MainActor
    private func currentNativeTabs() -> [NSWindow] {
        if let key = NSApp.keyWindow {
            if let group = key.tabbedWindows { return group }
            return [key]
        }
        if let first = controllers.first?.window {
            if let group = first.tabbedWindows { return group }
            return [first]
        }
        return []
    }

    @objc func showSettings(_ sender: Any?) {
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = HaliteSettingsView()
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "halite Settings"
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 540, height: 600))
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func settingsChanged(_ note: Notification) {
        // 활성 세션 전체에 새 config 푸시. 스타일 변경은 single-session controller만
        // hot-reload — compact controller는 구조 자체가 달라서 새 윈도우부터 적용됨.
        let newConfig = HaliteConfig.fromUserDefaults()
        let newTabStyle = TabBarStyle.current
        for c in controllers {
            // split된 pane 모두 hot-reload — 하나라도 빠지면 그 pane만 옛 폰트/테마.
            for s in c.sessions { s.updateConfig(newConfig) }
            c.applyTabBarStyle(newTabStyle)
            if let w = c.window { WindowChrome.applyFromDefaults(to: w) }
        }
        for cc in compactControllers {
            for s in cc.sessions { s.updateConfig(newConfig) }
            cc.refreshPaneIndicators()
            cc.applyTabBarBackground()   // 테마/투명 옵션 변경 반영
            if let w = cc.window { WindowChrome.applyFromDefaults(to: w) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Cmd+N — 항상 새 윈도우.
    @objc func newWindow(_ sender: Any?) {
        spawnWindow()
    }

    /// Cmd+T — 활성 윈도우가 Compact면 거기에 탭 추가, 아니면 새 윈도우.
    @MainActor
    @objc func newTab(_ sender: Any?) {
        newTabOrWindow()
    }

    /// Cmd+W — 터미널 창이면 활성 pane을 닫고(마지막이면 탭→창 cascade), 그 외
    /// 창(Settings 등)이면 창 전체를 닫는다. 메뉴 key-equiv가 NSWindow.performClose에
    /// 직결돼 있으면 탭이 여러 개여도 창째로 닫히는 버그가 있어 여기로 중앙화한다.
    @MainActor
    @objc func closeTabOrWindow(_ sender: Any?) {
        guard let win = NSApp.keyWindow else { return }
        // Compact/단일세션 터미널 창의 windowController는 pane 단위 close(performCloseTab)를
        // 구현한다. 구현하면 그쪽으로, 아니면 창을 닫는다.
        let sel = #selector(CompactWindowController.performCloseTab(_:))
        if let wc = win.windowController, wc.responds(to: sel) {
            wc.perform(sel, with: sender)
        } else {
            win.performClose(sender)
        }
    }

    @MainActor
    private func newTabOrWindow() {
        if let active = activeCompact() {
            active.addNewTab()
            return
        }
        spawnWindow()
    }

    private func spawnWindow() {
        let style = TabBarStyle.current
        if style == .compact {
            spawnCompactWindow()
        } else {
            spawnSingleSessionWindow()
        }
    }

    private func spawnSingleSessionWindow() {
        let session = HaliteSession(config: HaliteConfig.fromUserDefaults())
        let controller = HaliteWindowController(session: session)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            guard let self = self, let controller = controller else { return }
            self.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    private func spawnCompactWindow(restoring: RestorableWindow? = nil) {
        let controller = CompactWindowController(restoring: restoring)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            guard let self = self, let controller = controller else { return }
            self.compactControllers.removeAll { $0 === controller }
        }
        compactControllers.append(controller)
        controller.showWindow(nil)
    }
}

// MARK: - 최소 메뉴바
func installMainMenu() {
    let mainMenu = NSMenu()

    // App menu
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(
        withTitle: "Settings…",
        action: #selector(HaliteAppDelegate.showSettings(_:)),
        keyEquivalent: ","
    )
    appMenu.addItem(NSMenuItem.separator())
    // Sparkle 자동업데이트 — target은 SPUStandardUpdaterController 자체.
    let updateItem = NSMenuItem(
        title: "Check for Updates…",
        action: NSSelectorFromString("checkForUpdates:"),
        keyEquivalent: ""
    )
    updateItem.target = HaliteUpdater.shared.target
    appMenu.addItem(updateItem)
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
        withTitle: "Quit halite",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )

    // File menu — New Window, Close Window
    let fileItem = NSMenuItem()
    mainMenu.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    fileItem.submenu = fileMenu
    fileMenu.addItem(
        withTitle: "New Window",
        action: #selector(HaliteAppDelegate.newWindow(_:)),
        keyEquivalent: "n"
    )
    // Cmd+T — Compact 모드면 활성 윈도우에 탭 추가, 그 외엔 새 윈도우 (native tab group join).
    fileMenu.addItem(
        withTitle: "New Tab",
        action: #selector(HaliteAppDelegate.newTab(_:)),
        keyEquivalent: "t"
    )
    // Cmd+W — 탭/pane을 닫는다(창 전체가 아니라). 터미널 창이면 활성 pane을 닫고
    // 마지막이면 탭→창 순으로 cascade. 비터미널 창(Settings 등)이면 창을 닫는다.
    fileMenu.addItem(
        withTitle: "Close Tab",
        action: #selector(HaliteAppDelegate.closeTabOrWindow(_:)),
        keyEquivalent: "w"
    )
    // Cmd+Shift+W — 명시적으로 창 전체 닫기.
    let closeWindowItem = NSMenuItem(
        title: "Close Window",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"
    )
    closeWindowItem.keyEquivalentModifierMask = [.command, .shift]
    fileMenu.addItem(closeWindowItem)

    // Edit menu — Copy/Paste (responder chain으로 우리 view의 copy:/paste:가 잡힘)
    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editItem.submenu = editMenu
    editMenu.addItem(
        withTitle: "Copy",
        action: #selector(NSText.copy(_:)),
        keyEquivalent: "c"
    )
    editMenu.addItem(
        withTitle: "Paste",
        action: #selector(NSText.paste(_:)),
        keyEquivalent: "v"
    )
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(
        withTitle: "Find…",
        action: Selector(("performFindPanelAction:")),
        keyEquivalent: "f"
    )
    editMenu.addItem(
        withTitle: "Find Next",
        action: #selector(HaliteSurfaceView.findNextMatch),
        keyEquivalent: "g"
    )
    let findPrev = NSMenuItem(
        title: "Find Previous",
        action: #selector(HaliteSurfaceView.findPreviousMatch),
        keyEquivalent: "g"
    )
    findPrev.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(findPrev)

    // View menu — font zoom
    let viewItem = NSMenuItem()
    mainMenu.addItem(viewItem)
    let viewMenu = NSMenu(title: "View")
    viewItem.submenu = viewMenu
    viewMenu.addItem(
        withTitle: "Zoom In",
        action: #selector(HaliteSurfaceView.zoomIn(_:)),
        keyEquivalent: "="
    )
    viewMenu.addItem(
        withTitle: "Zoom Out",
        action: #selector(HaliteSurfaceView.zoomOut(_:)),
        keyEquivalent: "-"
    )
    viewMenu.addItem(
        withTitle: "Actual Size",
        action: #selector(HaliteSurfaceView.resetZoom(_:)),
        keyEquivalent: "0"
    )
    viewMenu.addItem(NSMenuItem.separator())
    let prevPrompt = NSMenuItem(
        title: "Jump to Previous Prompt",
        action: #selector(HaliteSurfaceView.jumpToPreviousPrompt(_:)),
        keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
    prevPrompt.keyEquivalentModifierMask = [.command]
    viewMenu.addItem(prevPrompt)
    let nextPrompt = NSMenuItem(
        title: "Jump to Next Prompt",
        action: #selector(HaliteSurfaceView.jumpToNextPrompt(_:)),
        keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
    nextPrompt.keyEquivalentModifierMask = [.command]
    viewMenu.addItem(nextPrompt)
    viewMenu.addItem(NSMenuItem.separator())
    // 전체화면 토글 — macOS 표준 ⌃⌘F (펑션키 불필요). toggleFullScreen:은 NSWindow가
    // 구현 → responder chain으로 key window에 도달.
    let fullScreen = NSMenuItem(
        title: "Toggle Full Screen",
        action: #selector(NSWindow.toggleFullScreen(_:)),
        keyEquivalent: "f")
    fullScreen.keyEquivalentModifierMask = [.command, .control]
    viewMenu.addItem(fullScreen)

    // Split menu — pane splitting. responder chain으로 활성 윈도우 컨트롤러에 도달.
    let splitItem = NSMenuItem()
    mainMenu.addItem(splitItem)
    let splitMenu = NSMenu(title: "Split")
    splitItem.submenu = splitMenu
    splitMenu.addItem(
        withTitle: "Split Horizontally",
        action: #selector(CompactWindowController.splitPaneHorizontally(_:)),
        keyEquivalent: "d"
    )
    let vsplit = NSMenuItem(
        title: "Split Vertically",
        action: #selector(CompactWindowController.splitPaneVertically(_:)),
        keyEquivalent: "d"
    )
    vsplit.keyEquivalentModifierMask = [.command, .shift]
    splitMenu.addItem(vsplit)

    splitMenu.addItem(NSMenuItem.separator())

    // Pane focus 네비 — Cmd+Opt+화살표.
    let focusDirs: [(String, Selector, UInt16)] = [
        ("Focus Pane Left", Selector(("focusPaneLeft:")), 123),
        ("Focus Pane Right", Selector(("focusPaneRight:")), 124),
        ("Focus Pane Down", Selector(("focusPaneDown:")), 125),
        ("Focus Pane Up", Selector(("focusPaneUp:")), 126),
    ]
    let arrowChars: [UInt16: String] = [
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
    ]
    for (title, sel, code) in focusDirs {
        let item = NSMenuItem(title: title, action: sel,
                              keyEquivalent: arrowChars[code] ?? "")
        item.keyEquivalentModifierMask = [.command, .option]
        splitMenu.addItem(item)
    }

    // Window menu — 탭 네비.
    let windowItem = NSMenuItem()
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: "Window")
    windowItem.submenu = windowMenu

    // NSMenu's punctuation key-equivalent matching for ⌘⇧] / ⌘⇧[ is unreliable
    // (charactersIgnoringModifiers applies Shift → "}"/"{", and letters case-fold
    // but punctuation doesn't). These items stay for menu DISPLAY + click; the
    // actual keystroke is dispatched in HaliteSurfaceView.performKeyEquivalent,
    // the same path ⌘W already uses.
    let nextTab = NSMenuItem(
        title: "Show Next Tab",
        action: Selector(("selectNextTab:")), keyEquivalent: "]"
    )
    nextTab.keyEquivalentModifierMask = [.command, .shift]
    windowMenu.addItem(nextTab)

    let prevTab = NSMenuItem(
        title: "Show Previous Tab",
        action: Selector(("selectPreviousTab:")), keyEquivalent: "["
    )
    prevTab.keyEquivalentModifierMask = [.command, .shift]
    windowMenu.addItem(prevTab)

    windowMenu.addItem(NSMenuItem.separator())

    // Cmd+1..9 — n번째 탭으로. tag에 1-based 번호.
    for n in 1...9 {
        let item = NSMenuItem(
            title: "Tab \(n)",
            action: Selector(("selectTabByNumber:")),
            keyEquivalent: "\(n)"
        )
        item.keyEquivalentModifierMask = [.command]
        item.tag = n
        windowMenu.addItem(item)
    }

    NSApp.mainMenu = mainMenu
}

// MARK: - 부팅

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let appDelegate = HaliteAppDelegate()
app.delegate = appDelegate

installMainMenu()

app.activate(ignoringOtherApps: true)
app.run()
