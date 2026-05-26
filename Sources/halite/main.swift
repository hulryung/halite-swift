import AppKit
import Combine
import HaliteTerminal

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
    private var controllers: [HaliteWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        spawnWindow()
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
        let session = HaliteSession(config: HaliteConfig())
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
