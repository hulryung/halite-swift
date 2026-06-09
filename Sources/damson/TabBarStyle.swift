import AppKit
import Foundation

/// 윈도우 탭 표시 스타일. UserDefaults("damson.tabBarStyle")에 raw string으로 저장.
/// DamsonWindowController가 init + settings 변경 시 이걸 읽어서 윈도우 chrome에 적용.
enum TabBarStyle: String, CaseIterable {
    /// 투명 titlebar + NSVisualEffectView(.hudWindow material)로 진짜 frosted-glass
    /// 효과. 신호등 영역이 dark blur material로 그려짐. surface는 titlebar 높이만큼
    /// 아래로 inset되어 텍스트가 가려지지 않음. **디폴트.**
    case compact

    /// 일반 타이틀바. 탭바가 1탭일 때도 항상 보이도록 NSTitlebarAccessoryViewController
    /// 로 가짜 single-tab 바를 띄움. 2+ 탭이면 진짜 NSWindow 탭바가 자동으로 자리를
    /// 차지하므로 accessory를 hide.
    case standard

    /// 일반 타이틀바 + macOS 기본 동작 (2+ 탭일 때만 탭바 보임).
    case auto

    var displayName: String {
        switch self {
        case .compact: return "Compact (신호등 옆)"
        case .standard: return "Standard (항상 표시)"
        case .auto: return "Auto (2탭 이상일 때)"
        }
    }

    static var current: TabBarStyle {
        if let raw = UserDefaults.standard.string(forKey: "damson.tabBarStyle"),
           let style = TabBarStyle(rawValue: raw) {
            return style
        }
        return .compact
    }
}

/// DamsonWindowController의 윈도우에 TabBarStyle을 적용. Compact는 fullSizeContentView
/// + 투명 titlebar + NSVisualEffectView를 컨테이너 최상단에 깔아 진짜 glass 효과.
/// Standard는 accessory placeholder. Auto는 macOS 기본.
final class TabBarStyleApplier {
    private let window: NSWindow
    private let container: NSView
    private let surface: NSView
    private let surfaceTopConstraint: NSLayoutConstraint
    private var alwaysVisibleAccessory: NSTitlebarAccessoryViewController?
    private var tabsObserver: NSKeyValueObservation?
    private var vibrancyView: NSVisualEffectView?

    init(
        window: NSWindow,
        container: NSView,
        surface: NSView,
        surfaceTopConstraint: NSLayoutConstraint
    ) {
        self.window = window
        self.container = container
        self.surface = surface
        self.surfaceTopConstraint = surfaceTopConstraint
    }

    deinit {
        tabsObserver?.invalidate()
    }

    func apply(_ style: TabBarStyle) {
        // 1) neutral 상태로 reset
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.styleMask.remove(.fullSizeContentView)
        window.appearance = nil
        tearDownAccessory()
        removeVibrancy()
        surfaceTopConstraint.constant = 0

        // 2) selected mode 적용
        switch style {
        case .compact:
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            installVibrancy()
            // surface는 titlebar height만큼 아래로 inset해서 VFX 영역 비워둠.
            surfaceTopConstraint.constant = titlebarHeight()

        case .standard:
            installAlwaysVisibleAccessory()
            startObservingTabCount()
            refreshAccessoryVisibility()

        case .auto:
            break // macOS 기본
        }
    }

    // MARK: - Compact: NSVisualEffectView glass

    private func installVibrancy() {
        let vfx = NSVisualEffectView()
        // .hudWindow는 dark frosted material로 솔리드 배경 위에서도 visible.
        // .titlebar는 chrome material과 비슷한데 솔리드 배경에선 거의 안 보임.
        vfx.material = .hudWindow
        vfx.blendingMode = .behindWindow
        vfx.state = .followsWindowActiveState
        vfx.translatesAutoresizingMaskIntoConstraints = false
        // surface 위에 (z-order) 깔아서 surface가 가리지 않도록.
        // surface가 inset되어 있으므로 사실 겹치지는 않지만 안전하게 above로.
        container.addSubview(vfx, positioned: .above, relativeTo: surface)
        NSLayoutConstraint.activate([
            vfx.topAnchor.constraint(equalTo: container.topAnchor),
            vfx.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vfx.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            vfx.heightAnchor.constraint(equalToConstant: titlebarHeight()),
        ])
        vibrancyView = vfx
    }

    private func removeVibrancy() {
        vibrancyView?.removeFromSuperview()
        vibrancyView = nil
    }

    /// 현재 윈도우의 titlebar 영역 높이. styleMask와 상관 없이 결정적.
    private func titlebarHeight() -> CGFloat {
        // contentLayoutRect.height = window frame - titlebar (fullSizeContentView 무관).
        // 그 차이가 titlebar height.
        let h = window.frame.height - window.contentLayoutRect.height
        // 첫 init 시점엔 측정값이 0일 수도 있어 fallback.
        return max(h, 28)
    }

    // MARK: - Standard: always-visible placeholder accessory

    private func installAlwaysVisibleAccessory() {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .bottom
        accessory.view = makeFakeTabBarView()
        window.addTitlebarAccessoryViewController(accessory)
        alwaysVisibleAccessory = accessory
    }

    private func tearDownAccessory() {
        tabsObserver?.invalidate()
        tabsObserver = nil
        if let acc = alwaysVisibleAccessory,
           let idx = window.titlebarAccessoryViewControllers.firstIndex(of: acc) {
            window.removeTitlebarAccessoryViewController(at: idx)
        }
        alwaysVisibleAccessory = nil
    }

    private func startObservingTabCount() {
        tabsObserver?.invalidate()
        tabsObserver = window.observe(\.tabbedWindows, options: [.new]) {
            [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshAccessoryVisibility() }
        }
    }

    private func refreshAccessoryVisibility() {
        let realTabBarShowing = (window.tabbedWindows?.count ?? 1) >= 2
        alwaysVisibleAccessory?.isHidden = realTabBarShowing
    }

    private func makeFakeTabBarView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.6).cgColor

        let label = NSTextField(labelWithString: window.title.isEmpty ? "Damson" : window.title)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = NSColor.secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}
