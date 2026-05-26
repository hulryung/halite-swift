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
        surface.translatesAutoresizingMaskIntoConstraints = true
        surface.autoresizingMask = [.width, .height]
        window.contentView = surface
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
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        session.terminate()
        // 마지막 윈도우면 application이 자동 종료
        // (applicationShouldTerminateAfterLastWindowClosed == true).
    }
}

final class HaliteAppDelegate: NSObject, NSApplicationDelegate {
    /// 살아있는 윈도우 컨트롤러들. windowWillClose가 자기 자신을 빼서 release되도록.
    fileprivate var controllers: [HaliteWindowController] = []
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
            spawnWindow()
            return .ok()
        case .split:
            // halite-swift는 single-pane 단계. 의미 있는 동작이 없으므로 명시적 에러.
            return .err("split is not supported in halite-swift (single-pane only)")
        case .closeTab:
            if let win = NSApp.keyWindow ?? controllers.last?.window {
                win.performClose(nil)
                return .ok()
            }
            return .err("no active window to close")
        case .switchTab(let index):
            let tabs = currentTabbedWindows()
            guard index >= 0, index < tabs.count else {
                return .err("tab index \(index) out of range (have \(tabs.count) tabs)")
            }
            tabs[index].makeKeyAndOrderFront(nil)
            return .ok()
        case .listTabs:
            let tabs = currentTabbedWindows()
            let list = tabs.enumerated().map { (i, _) in
                TabInfo(index: i, pane_count: 1)
            }
            return .tabs(list)
        }
    }

    /// 현재 활성 탭 그룹의 윈도우 목록. 단일 윈도우면 [그 윈도우], 탭 그룹이면 .tabbedWindows.
    @MainActor
    private func currentTabbedWindows() -> [NSWindow] {
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
        // 활성 세션 전체에 새 config 푸시.
        let newConfig = HaliteConfig.fromUserDefaults()
        for c in controllers {
            c.session.updateConfig(newConfig)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for c in controllers { c.session.terminate() }
    }

    @objc func newWindow(_ sender: Any?) {
        spawnWindow()
    }

    private func spawnWindow() {
        let session = HaliteSession(config: HaliteConfig.fromUserDefaults())
        let controller = HaliteWindowController(session: session)
        // 닫힐 때 array에서 제거 — strong ref 해제.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self, weak controller] _ in
            guard let self = self, let controller = controller else { return }
            self.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
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
    // Cmd+T 도 동일 새 윈도우 — tabbingMode=.preferred 라서 기존 윈도우와 같은 탭 그룹으로 자동 join.
    fileMenu.addItem(
        withTitle: "New Tab",
        action: #selector(HaliteAppDelegate.newWindow(_:)),
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
