import AppKit

/// 분할된 pane에서 활성(포커스된) pane을 어떻게 표시할지.
/// UserDefaults("halite.activePaneIndicator")에 raw string으로 저장.
/// PaneLeafWrapper가 그릴 때 읽는다.
enum ActivePaneIndicator: String, CaseIterable {
    /// 비활성 pane만 어둡게(scrim) 덮어 활성을 구분. 테두리 없음. 단일 pane이면
    /// 비활성이 없어 아무 표시도 안 생김. **디폴트.**
    case dimInactive

    /// 활성 pane에 강조색(시스템 accent) 테두리.
    case accentBorder

    /// 활성 pane 테두리를 배경색에서 살짝 이동한 은은한 색으로.
    case subtleBorder

    /// 표시 없음.
    case none

    var displayName: String {
        switch self {
        case .dimInactive: return "Dim inactive (비활성 흐리게)"
        case .accentBorder: return "Accent border (강조 테두리)"
        case .subtleBorder: return "Subtle border (은은한 테두리)"
        case .none: return "None (표시 없음)"
        }
    }

    static var current: ActivePaneIndicator {
        if let raw = UserDefaults.standard.string(forKey: "halite.activePaneIndicator"),
           let v = ActivePaneIndicator(rawValue: raw) {
            return v
        }
        return .dimInactive
    }
}
