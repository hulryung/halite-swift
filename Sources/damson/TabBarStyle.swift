import AppKit
import Foundation

/// Window tab display style. Stored as a raw string in UserDefaults("damson.tabBarStyle").
/// DamsonWindowController reads this on init and on settings changes, applying it to the window chrome.
enum TabBarStyle: String, CaseIterable {
    /// Transparent titlebar + NSVisualEffectView(.hudWindow material) for a true frosted-glass
    /// effect. The traffic-light area is rendered with a dark blur material. The surface is inset
    /// downward by the titlebar height so its text is never obscured. **Default.**
    case compact

    /// Standard titlebar. Shows a fake single-tab bar via NSTitlebarAccessoryViewController so the
    /// tab bar is always visible even with a single tab. With 2+ tabs the real NSWindow tab bar
    /// automatically takes that space, so the accessory is hidden.
    case standard

    /// Standard titlebar + default macOS behavior (tab bar shown only with 2+ tabs).
    case auto

    var displayName: String {
        switch self {
        case .compact: return "Compact (next to the traffic lights)"
        case .standard: return "Standard (always shown)"
        case .auto: return "Auto (when 2+ tabs)"
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

/// Applies a TabBarStyle to a DamsonWindowController's window. Compact uses fullSizeContentView
/// + a transparent titlebar + an NSVisualEffectView laid over the top of the container for a true
/// glass effect. Standard uses an accessory placeholder. Auto is the macOS default.
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
        // 1) reset to a neutral state
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.styleMask.remove(.fullSizeContentView)
        window.appearance = nil
        tearDownAccessory()
        removeVibrancy()
        surfaceTopConstraint.constant = 0

        // 2) apply the selected mode
        switch style {
        case .compact:
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            installVibrancy()
            // Inset the surface downward by the titlebar height to leave the VFX area clear.
            surfaceTopConstraint.constant = titlebarHeight()

        case .standard:
            installAlwaysVisibleAccessory()
            startObservingTabCount()
            refreshAccessoryVisibility()

        case .auto:
            break // macOS default
        }
    }

    // MARK: - Compact: NSVisualEffectView glass

    private func installVibrancy() {
        let vfx = NSVisualEffectView()
        // .hudWindow is a dark frosted material that stays visible even over a solid background.
        // .titlebar resembles the chrome material but is nearly invisible over a solid background.
        vfx.material = .hudWindow
        vfx.blendingMode = .behindWindow
        vfx.state = .followsWindowActiveState
        vfx.translatesAutoresizingMaskIntoConstraints = false
        // Place it above the surface in z-order so the surface doesn't cover it.
        // The surface is inset so they don't actually overlap, but use above to be safe.
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

    /// Height of the current window's titlebar area. Deterministic regardless of styleMask.
    private func titlebarHeight() -> CGFloat {
        // contentLayoutRect.height = window frame - titlebar (independent of fullSizeContentView).
        // That difference is the titlebar height.
        let h = window.frame.height - window.contentLayoutRect.height
        // The measured value may be 0 at first init, so fall back.
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
