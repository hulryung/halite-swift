import Foundation

/// 새 탭을 열 때 시작 작업 디렉토리 정책. UserDefaults("halite.newTabDirectory")에
/// raw string으로 저장. (split은 이 설정과 무관하게 항상 현재 pane의 cwd를 상속한다.)
enum NewTabDirectory: String, CaseIterable {
    /// 항상 홈 디렉토리에서 시작. **디폴트.**
    case home

    /// 현재 활성 탭/pane의 작업 디렉토리를 상속(셸 통합 OSC 7 보고 기반).
    case inheritCwd

    var displayName: String {
        switch self {
        case .home: return "Home (홈 디렉토리)"
        case .inheritCwd: return "Current (현재 디렉토리 상속)"
        }
    }

    static var current: NewTabDirectory {
        if let raw = UserDefaults.standard.string(forKey: "halite.newTabDirectory"),
           let v = NewTabDirectory(rawValue: raw) {
            return v
        }
        return .home
    }
}
