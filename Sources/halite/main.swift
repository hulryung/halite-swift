import AppKit
import HaliteTerminal
import SwiftUI

// 독립 halite.app의 최소 진입점.
// SwiftPM 실행: `swift run halite`
// 추후 정식 .app 배포는 별도 Xcode 프로젝트로 그래듀에이션.

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let session = HaliteSession(config: HaliteConfig())

let contentView = HaliteTerminalView(session: session)
    .frame(minWidth: 720, minHeight: 480)

let hostingController = NSHostingController(rootView: contentView)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled, .closable, .resizable, .miniaturizable],
    backing: .buffered,
    defer: false
)
window.title = "halite"
window.contentViewController = hostingController
window.center()
window.makeKeyAndOrderFront(nil)

app.activate(ignoringOtherApps: true)
app.run()
