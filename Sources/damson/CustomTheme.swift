import AppKit
import DamsonTerminal

/// 커스텀 테마의 hex 색 저장 모델. UserDefaults("damson.customTheme")에 JSON.
struct CustomThemeData: Codable, Equatable {
    var background: String
    var foreground: String
    var cursor: String
    var ansi: [String]   // 16개

    /// 기본 커스텀 — Default Dark를 시작점으로.
    static var defaultData: CustomThemeData {
        let h = DamsonTheme.defaultDark.toHexColors()
        return CustomThemeData(background: h.bg, foreground: h.fg, cursor: h.cursor, ansi: h.ansi)
    }

    func toTheme() -> DamsonTheme {
        DamsonTheme.custom(bg: background, fg: foreground, cursor: cursor, ansi: ansi)
    }
}

enum CustomTheme {
    private static let key = "damson.customTheme"

    static func load() -> CustomThemeData {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CustomThemeData.self, from: data)
        else { return .defaultData }
        // ansi가 16개가 아니면 패딩/절단.
        var d = decoded
        while d.ansi.count < 16 { d.ansi.append("#000000") }
        if d.ansi.count > 16 { d.ansi = Array(d.ansi.prefix(16)) }
        return d
    }

    static func save(_ data: CustomThemeData) {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(encoded, forKey: key)
    }
}
