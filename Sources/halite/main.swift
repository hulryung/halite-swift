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

/// 한 윈도우 + 한 세션을 묶어서 관리.
final class HaliteWindowController: NSWindowController, NSWindowDelegate {
    let session: HaliteSession
    private var titleSubscription: AnyCancellable?
    private var tabStyleApplier: TabBarStyleApplier?

    init(session: HaliteSession) {
        self.session = session
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
        let surface = HaliteSurfaceView(session: session)
        surface.translatesAutoresizingMaskIntoConstraints = false
        // contentView를 container로 감싸서 titlebar 영역에 NSVisualEffectView를
        // 깔 수 있는 자리를 만든다. Compact 모드에선 fullSizeContentView로 컨테이너가
        // 윈도우 전체에 펼쳐지고, VFX가 위쪽 titlebarHeight만큼 점유 + surface는
        // 그 아래로 inset됨. 다른 모드에선 VFX 숨기고 surface가 컨테이너 전체.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(surface)
        let surfaceTop = surface.topAnchor.constraint(equalTo: container.topAnchor)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
        titleSubscription = session.$title
            .receive(on: RunLoop.main)
            .sink { [weak self] newTitle in
                let display = newTitle.isEmpty ? "halite" : newTitle
                self?.window?.title = display
            }
        // 사용자가 Settings에서 고른 탭 스타일 적용. 초기값은 TabBarStyle.current.
        let applier = TabBarStyleApplier(
            window: window,
            container: container,
            surface: surface,
            surfaceTopConstraint: surfaceTop
        )
        applier.apply(TabBarStyle.current)
        self.tabStyleApplier = applier
    }

    func applyTabBarStyle(_ style: TabBarStyle) {
        tabStyleApplier?.apply(style)
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        session.terminate()
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
        spawnWindow()
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
        case .split:
            return .err("split is not supported in halite-swift (single-pane only)")
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
                let list = active.sessions.enumerated().map { (i, _) in
                    TabInfo(index: i, pane_count: 1)
                }
                return .tabs(list)
            }
            let tabs = currentNativeTabs()
            let list = tabs.enumerated().map { (i, _) in
                TabInfo(index: i, pane_count: 1)
            }
            return .tabs(list)
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
        win.setContentSize(NSSize(width: 420, height: 280))
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
            c.session.updateConfig(newConfig)
            c.applyTabBarStyle(newTabStyle)
        }
        for cc in compactControllers {
            for s in cc.sessions { s.updateConfig(newConfig) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for c in controllers { c.session.terminate() }
        for cc in compactControllers { for s in cc.sessions { s.terminate() } }
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

    private func spawnCompactWindow() {
        let controller = CompactWindowController()
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
    fileMenu.addItem(
        withTitle: "Close Window",
        action: #selector(NSWindow.performClose(_:)),
        keyEquivalent: "w"
    )

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
