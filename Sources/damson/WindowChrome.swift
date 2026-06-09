import AppKit

/// 창 투명도/블러 적용. 배경 불투명도 < 1이면 창을 비불투명(clear)으로 만들어 터미널의
/// 투명 배경이 창 뒤까지 비치게 하고, 블러가 켜져 있으면 contentView 맨 뒤에
/// behind-window `NSVisualEffectView`를 깔아 frosted-glass로 만든다.
///
/// 렌더러(배경 알파)와 별개의 창 단위 설정이라 window controller가 직접 호출한다.
enum WindowChrome {
    private static let backdropID = NSUserInterfaceItemIdentifier("damson.blurBackdrop")

    /// UserDefaults에서 현재 설정을 읽어 적용.
    static func applyFromDefaults(to window: NSWindow) {
        let d = UserDefaults.standard
        let opacity = (d.object(forKey: "damson.backgroundOpacity") as? Double) ?? 1.0
        let blur = d.bool(forKey: "damson.backgroundBlur")
        apply(to: window, opacity: CGFloat(opacity), blur: blur)
    }

    static func apply(to window: NSWindow, opacity: CGFloat, blur: Bool) {
        let translucent = opacity < 1.0
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : .windowBackgroundColor

        guard let content = window.contentView else { return }
        let existing = content.subviews.first { $0.identifier == backdropID } as? NSVisualEffectView

        if translucent && blur {
            let v = existing ?? makeBackdrop(in: content)
            v.isHidden = false
        } else {
            existing?.removeFromSuperview()
        }
    }

    private static func makeBackdrop(in content: NSView) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.identifier = backdropID
        v.blendingMode = .behindWindow
        v.state = .active
        v.material = .underWindowBackground
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            v.topAnchor.constraint(equalTo: content.topAnchor),
            v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return v
    }
}
