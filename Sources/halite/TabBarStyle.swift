import AppKit
import Foundation

/// 윈도우 탭 표시 스타일. UserDefaults("halite.tabBarStyle")에 raw string으로 저장.
/// HaliteWindowController가 init + settings 변경 시 이걸 읽어서 윈도우 chrome에 적용.
enum TabBarStyle: String, CaseIterable {
    /// 투명 타이틀바 + fullSizeContentView. 탭바가 신호등 영역과 시각적으로 통합되어
    /// 보임. 1탭일 때는 macOS 기본 동작대로 탭바 hidden. **디폴트.**
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
        if let raw = UserDefaults.standard.string(forKey: "halite.tabBarStyle"),
           let style = TabBarStyle(rawValue: raw) {
            return style
        }
        return .compact
    }
}

/// HaliteWindowController의 윈도우에 TabBarStyle을 적용. compact↔auto는 titlebar
/// 프로퍼티만 토글, standard는 accessory view 설치 + tabbedWindows KVO로 가시성 관리.
final class TabBarStyleApplier {
    private let window: NSWindow
    private var alwaysVisibleAccessory: NSTitlebarAccessoryViewController?
    private var tabsObserver: NSKeyValueObservation?

    init(window: NSWindow) {
        self.window = window
    }

    deinit {
        tabsObserver?.invalidate()
    }

    func apply(_ style: TabBarStyle) {
        // 1) reset to neutral state
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.styleMask.remove(.fullSizeContentView)
        window.appearance = nil
        tearDownAccessory()
        removeTitlebarVibrancyIfPresent()

        // 2) apply selected mode
        switch style {
        case .compact:
            // 다크 chrome material(frosted glass)로 titlebar를 보이게 함.
            // appearance만 .darkAqua로 강제하면 macOS가 chrome을 다크 vibrancy로 그림
            // → 신호등 영역이 자동으로 다크 frosted-glass.
            // fullSizeContentView / titlebarAppearsTransparent은 안 씀:
            //   - 켜면 컨텐츠가 chrome 뒤로 침범 → 터미널의 검은 배경/프롬프트가
            //     신호등 뒤로 비치는 ugly 결과.
            //   - 꺼두면 컨텐츠가 titlebar 아래에서 깔끔하게 시작 → glass 영역과 분리.
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .hidden
            window.styleMask.remove(.fullSizeContentView)

        case .standard:
            installAlwaysVisibleAccessory()
            startObservingTabCount()
            refreshAccessoryVisibility()

        case .auto:
            // 아무것도 안 함 — macOS 기본 동작.
            break
        }
    }

    private func removeTitlebarVibrancyIfPresent() {
        // 이전 시도에서 contentView에 추가했던 NSVisualEffectView가 있다면 제거.
        guard let cv = window.contentView else { return }
        for sub in cv.subviews where sub is NSVisualEffectView {
            sub.removeFromSuperview()
        }
    }

    // MARK: - "always visible" placeholder accessory

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
        // 2+ 탭이면 진짜 NSWindow 탭바가 자리잡으므로 가짜 accessory 숨김.
        let realTabBarShowing = (window.tabbedWindows?.count ?? 1) >= 2
        alwaysVisibleAccessory?.isHidden = realTabBarShowing
    }

    private func makeFakeTabBarView() -> NSView {
        // 1줄짜리 placeholder — 진짜 macOS 탭바와 정확히 똑같이 그릴 수는 없지만
        // 시각적 정체성 (탭바가 있다는 사실)을 알려주기엔 충분. 진짜 탭바가
        // 보이는 순간(2+ 탭)은 hide.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor
            .withAlphaComponent(0.6).cgColor

        let label = NSTextField(labelWithString: window.title.isEmpty ? "halite" : window.title)
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
