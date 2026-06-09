import Foundation

/// 탭 전환 애니메이션 효과. UserDefaults("damson.tabTransition")에 raw string으로 저장.
/// CompactWindowController가 탭 전환 시 이걸 읽어 적용.
enum TabTransitionStyle: String, CaseIterable {
    /// 전체 폭 페이지 스와이프 — 나가는 탭이 한쪽으로 완전히 밀려나가고, 들어오는 탭이
    /// 반대쪽에서 들어온다(페이드 없음). Rust halite의 cross-slide와 동일. **디폴트.**
    case slide

    /// 살짝 밀림 + 크로스페이드 (24pt 슬라이드 + opacity).
    case crossfade

    /// 애니메이션 없이 즉시 전환.
    case none

    var displayName: String {
        switch self {
        case .slide: return "Slide (페이지 스와이프)"
        case .crossfade: return "Crossfade (살짝 밀림)"
        case .none: return "None (즉시)"
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
