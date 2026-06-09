import Foundation

/// Tab transition animation effect. Stored as a raw string in UserDefaults("damson.tabTransition").
/// CompactWindowController reads and applies this on tab switches.
enum TabTransitionStyle: String, CaseIterable {
    /// Full-width page swipe — the outgoing tab slides completely off one side while the incoming
    /// tab enters from the other (no fade). Same as Rust halite's cross-slide. **Default.**
    case slide

    /// A slight slide + crossfade (24pt slide + opacity).
    case crossfade

    /// Instant switch with no animation.
    case none

    var displayName: String {
        switch self {
        case .slide: return "Slide (page swipe)"
        case .crossfade: return "Crossfade (slight push)"
        case .none: return "None (instant)"
        }
    }

    static var current: TabTransitionStyle {
        if let raw = UserDefaults.standard.string(forKey: "damson.tabTransition"),
           let style = TabTransitionStyle(rawValue: raw) {
            return style
        }
        return .slide
    }
}
