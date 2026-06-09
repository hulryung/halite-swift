import AppKit
import Foundation

/// 터미널 색 테마 — background / foreground / cursor + ANSI 16색.
/// TermColor를 NSColor로 resolve할 때 사용. 앱 전역 하나의 테마 (Settings에서 선택).
public struct DamsonTheme: Equatable {
    public let name: String
    public let background: NSColor
    public let foreground: NSColor
    public let cursor: NSColor
    /// ANSI 16색 (0-7 normal, 8-15 bright).
    public let ansi: [NSColor]

    public init(
        name: String,
        background: NSColor,
        foreground: NSColor,
        cursor: NSColor,
        ansi: [NSColor]
    ) {
        precondition(ansi.count == 16, "ansi must have 16 colors")
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.ansi = ansi
    }

    /// TermColor → NSColor.
    public func nsColor(_ c: TermColor) -> NSColor {
        switch c {
        case .default:
            return foreground
        case .palette(let i):
            return paletteColor(i)
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// ANSI 팔레트 인덱스 → NSColor.
    /// 0-15는 테마의 ansi[], 16-231은 6×6×6 cube, 232-255는 grayscale (xterm 표준).
    public func paletteColor(_ n: Int) -> NSColor {
        if n >= 0 && n < 16 { return ansi[n] }
        if n >= 232 && n <= 255 {
            let v = (n - 232) * 10 + 8
            return rgb255(v, v, v)
        }
        if n >= 16 && n <= 231 {
            let c = n - 16
            let r = c / 36
            let g = (c / 6) % 6
            let b = c % 6
            let levels = [0, 95, 135, 175, 215, 255]
            return rgb255(levels[r], levels[g], levels[b])
        }
        return foreground // out of range fallback
    }

    private func rgb255(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                blue: CGFloat(b) / 255, alpha: 1)
    }
}

// MARK: - hex 직렬화 (커스텀 테마 저장/복원)

public extension NSColor {
    /// "#RRGGBB" 형식. sRGB 기준.
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// "#RRGGBB" / "RRGGBB" 파싱.
    convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

public extension DamsonTheme {
    /// 커스텀 테마의 직렬화 이름 (Settings picker + UserDefaults에서 이 이름이면 커스텀).
    static let customName = "Custom"

    /// 현재 테마의 모든 색을 hex로. 커스텀 편집 시작점(프리셋 복사)용.
    func toHexColors() -> (bg: String, fg: String, cursor: String, ansi: [String]) {
        (background.hexString, foreground.hexString, cursor.hexString, ansi.map { $0.hexString })
    }

    /// hex 색들로 커스텀 테마 생성. 잘못된 hex는 검정으로 폴백, ansi가 16개 미만이면 검정 패딩.
    static func custom(bg: String, fg: String, cursor: String, ansi: [String]) -> DamsonTheme {
        func col(_ h: String) -> NSColor { NSColor(hexString: h) ?? .black }
        var ansiColors = ansi.map(col)
        while ansiColors.count < 16 { ansiColors.append(.black) }
        return DamsonTheme(
            name: customName,
            background: col(bg), foreground: col(fg), cursor: col(cursor),
            ansi: Array(ansiColors.prefix(16))
        )
    }
}

// MARK: - 프리셋

public extension DamsonTheme {
    private static func c(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// 모든 내장 프리셋 (Settings picker 순서). 다크 → 라이트 순.
    static var presets: [DamsonTheme] {
        [
            // dark
            .defaultDark, .dracula, .monokai, .oneDark, .nord, .gruvboxDark,
            .solarizedDark, .tokyoNight, .tokyoNightStorm, .catppuccinMocha,
            .catppuccinMacchiato, .catppuccinFrappe, .nightOwl, .ayuDark, .ayuMirage,
            .githubDark, .rosePine, .rosePineMoon, .palenight, .cobalt2,
            .tomorrowNight, .tomorrowNightEighties, .hyperSnazzy, .material,
            .everforestDark, .kanagawa, .iceberg,
            // light
            .solarizedLight, .gruvboxLight, .oneLight, .catppuccinLatte,
            .tokyoNightLight, .githubLight, .rosePineDawn, .tomorrow,
        ]
    }

    static func preset(named name: String) -> DamsonTheme? {
        presets.first { $0.name == name }
    }

    /// xterm 기본에 가까운 다크 테마 (damson 디폴트).
    static var defaultDark: DamsonTheme {
        DamsonTheme(
            name: "Default Dark",
            background: c(0x000000), foreground: c(0xE5E5E5), cursor: c(0xE5E5E5),
            ansi: [
                c(0x000000), c(0xCD0000), c(0x00CD00), c(0xCDCD00),
                c(0x0000EE), c(0xCD00CD), c(0x00CDCD), c(0xE5E5E5),
                c(0x7F7F7F), c(0xFF0000), c(0x00FF00), c(0xFFFF00),
                c(0x5C5CFF), c(0xFF00FF), c(0x00FFFF), c(0xFFFFFF),
            ])
    }

    static var solarizedDark: DamsonTheme {
        DamsonTheme(
            name: "Solarized Dark",
            background: c(0x002B36), foreground: c(0x839496), cursor: c(0x93A1A1),
            ansi: [
                c(0x073642), c(0xDC322F), c(0x859900), c(0xB58900),
                c(0x268BD2), c(0xD33682), c(0x2AA198), c(0xEEE8D5),
                c(0x002B36), c(0xCB4B16), c(0x586E75), c(0x657B83),
                c(0x839496), c(0x6C71C4), c(0x93A1A1), c(0xFDF6E3),
            ])
    }

    static var solarizedLight: DamsonTheme {
        DamsonTheme(
            name: "Solarized Light",
            background: c(0xFDF6E3), foreground: c(0x657B83), cursor: c(0x586E75),
            ansi: [
                c(0x073642), c(0xDC322F), c(0x859900), c(0xB58900),
                c(0x268BD2), c(0xD33682), c(0x2AA198), c(0xEEE8D5),
                c(0x002B36), c(0xCB4B16), c(0x586E75), c(0x657B83),
                c(0x839496), c(0x6C71C4), c(0x93A1A1), c(0xFDF6E3),
            ])
    }

    static var dracula: DamsonTheme {
        DamsonTheme(
            name: "Dracula",
            background: c(0x282A36), foreground: c(0xF8F8F2), cursor: c(0xF8F8F2),
            ansi: [
                c(0x21222C), c(0xFF5555), c(0x50FA7B), c(0xF1FA8C),
                c(0xBD93F9), c(0xFF79C6), c(0x8BE9FD), c(0xF8F8F2),
                c(0x6272A4), c(0xFF6E6E), c(0x69FF94), c(0xFFFFA5),
                c(0xD6ACFF), c(0xFF92DF), c(0xA4FFFF), c(0xFFFFFF),
            ])
    }

    static var gruvboxDark: DamsonTheme {
        DamsonTheme(
            name: "Gruvbox Dark",
            background: c(0x282828), foreground: c(0xEBDBB2), cursor: c(0xEBDBB2),
            ansi: [
                c(0x282828), c(0xCC241D), c(0x98971A), c(0xD79921),
                c(0x458588), c(0xB16286), c(0x689D6A), c(0xA89984),
                c(0x928374), c(0xFB4934), c(0xB8BB26), c(0xFABD2F),
                c(0x83A598), c(0xD3869B), c(0x8EC07C), c(0xEBDBB2),
            ])
    }

    static var nord: DamsonTheme {
        DamsonTheme(
            name: "Nord",
            background: c(0x2E3440), foreground: c(0xD8DEE9), cursor: c(0xD8DEE9),
            ansi: [
                c(0x3B4252), c(0xBF616A), c(0xA3BE8C), c(0xEBCB8B),
                c(0x81A1C1), c(0xB48EAD), c(0x88C0D0), c(0xE5E9F0),
                c(0x4C566A), c(0xBF616A), c(0xA3BE8C), c(0xEBCB8B),
                c(0x81A1C1), c(0xB48EAD), c(0x8FBCBB), c(0xECEFF4),
            ])
    }

    static var tokyoNight: DamsonTheme {
        DamsonTheme(
            name: "Tokyo Night",
            background: c(0x1A1B26), foreground: c(0xC0CAF5), cursor: c(0xC0CAF5),
            ansi: [
                c(0x15161E), c(0xF7768E), c(0x9ECE6A), c(0xE0AF68),
                c(0x7AA2F7), c(0xBB9AF7), c(0x7DCFFF), c(0xA9B1D6),
                c(0x414868), c(0xF7768E), c(0x9ECE6A), c(0xE0AF68),
                c(0x7AA2F7), c(0xBB9AF7), c(0x7DCFFF), c(0xC0CAF5),
            ])
    }

    static var tokyoNightStorm: DamsonTheme {
        DamsonTheme(
            name: "Tokyo Night Storm",
            background: c(0x24283B), foreground: c(0xC0CAF5), cursor: c(0xC0CAF5),
            ansi: [
                c(0x1D202F), c(0xF7768E), c(0x9ECE6A), c(0xE0AF68),
                c(0x7AA2F7), c(0xBB9AF7), c(0x7DCFFF), c(0xA9B1D6),
                c(0x414868), c(0xF7768E), c(0x9ECE6A), c(0xE0AF68),
                c(0x7AA2F7), c(0xBB9AF7), c(0x7DCFFF), c(0xC0CAF5),
            ])
    }

    static var tokyoNightLight: DamsonTheme {
        DamsonTheme(
            name: "Tokyo Night Light",
            background: c(0xD5D6DB), foreground: c(0x343B58), cursor: c(0x343B58),
            ansi: [
                c(0x0F0F14), c(0x8C4351), c(0x485E30), c(0x8F5E15),
                c(0x34548A), c(0x5A4A78), c(0x0F4B6E), c(0x343B58),
                c(0x9699A3), c(0x8C4351), c(0x485E30), c(0x8F5E15),
                c(0x34548A), c(0x5A4A78), c(0x0F4B6E), c(0x343B58),
            ])
    }

    static var monokai: DamsonTheme {
        DamsonTheme(
            name: "Monokai",
            background: c(0x272822), foreground: c(0xF8F8F2), cursor: c(0xF8F8F2),
            ansi: [
                c(0x272822), c(0xF92672), c(0xA6E22E), c(0xF4BF75),
                c(0x66D9EF), c(0xAE81FF), c(0xA1EFE4), c(0xF8F8F2),
                c(0x75715E), c(0xF92672), c(0xA6E22E), c(0xF4BF75),
                c(0x66D9EF), c(0xAE81FF), c(0xA1EFE4), c(0xF9F8F5),
            ])
    }

    static var oneDark: DamsonTheme {
        DamsonTheme(
            name: "One Dark",
            background: c(0x282C34), foreground: c(0xABB2BF), cursor: c(0x528BFF),
            ansi: [
                c(0x282C34), c(0xE06C75), c(0x98C379), c(0xE5C07B),
                c(0x61AFEF), c(0xC678DD), c(0x56B6C2), c(0xABB2BF),
                c(0x5C6370), c(0xE06C75), c(0x98C379), c(0xE5C07B),
                c(0x61AFEF), c(0xC678DD), c(0x56B6C2), c(0xFFFFFF),
            ])
    }

    static var oneLight: DamsonTheme {
        DamsonTheme(
            name: "One Light",
            background: c(0xFAFAFA), foreground: c(0x383A42), cursor: c(0x383A42),
            ansi: [
                c(0x383A42), c(0xE45649), c(0x50A14F), c(0xC18401),
                c(0x4078F2), c(0xA626A4), c(0x0184BC), c(0xA0A1A7),
                c(0x696C77), c(0xE45649), c(0x50A14F), c(0xC18401),
                c(0x4078F2), c(0xA626A4), c(0x0184BC), c(0xFAFAFA),
            ])
    }

    static var catppuccinMocha: DamsonTheme {
        DamsonTheme(
            name: "Catppuccin Mocha",
            background: c(0x1E1E2E), foreground: c(0xCDD6F4), cursor: c(0xF5E0DC),
            ansi: [
                c(0x45475A), c(0xF38BA8), c(0xA6E3A1), c(0xF9E2AF),
                c(0x89B4FA), c(0xF5C2E7), c(0x94E2D5), c(0xBAC2DE),
                c(0x585B70), c(0xF38BA8), c(0xA6E3A1), c(0xF9E2AF),
                c(0x89B4FA), c(0xF5C2E7), c(0x94E2D5), c(0xA6ADC8),
            ])
    }

    static var catppuccinMacchiato: DamsonTheme {
        DamsonTheme(
            name: "Catppuccin Macchiato",
            background: c(0x24273A), foreground: c(0xCAD3F5), cursor: c(0xF4DBD6),
            ansi: [
                c(0x494D64), c(0xED8796), c(0xA6DA95), c(0xEED49F),
                c(0x8AADF4), c(0xF5BDE6), c(0x8BD5CA), c(0xB8C0E0),
                c(0x5B6078), c(0xED8796), c(0xA6DA95), c(0xEED49F),
                c(0x8AADF4), c(0xF5BDE6), c(0x8BD5CA), c(0xA5ADCB),
            ])
    }

    static var catppuccinFrappe: DamsonTheme {
        DamsonTheme(
            name: "Catppuccin Frappé",
            background: c(0x303446), foreground: c(0xC6D0F5), cursor: c(0xF2D5CF),
            ansi: [
                c(0x51576D), c(0xE78284), c(0xA6D189), c(0xE5C890),
                c(0x8CAAEE), c(0xF4B8E4), c(0x81C8BE), c(0xB5BFE2),
                c(0x626880), c(0xE78284), c(0xA6D189), c(0xE5C890),
                c(0x8CAAEE), c(0xF4B8E4), c(0x81C8BE), c(0xA5ADCE),
            ])
    }

    static var catppuccinLatte: DamsonTheme {
        DamsonTheme(
            name: "Catppuccin Latte",
            background: c(0xEFF1F5), foreground: c(0x4C4F69), cursor: c(0xDC8A78),
            ansi: [
                c(0x5C5F77), c(0xD20F39), c(0x40A02B), c(0xDF8E1D),
                c(0x1E66F5), c(0xEA76CB), c(0x179299), c(0xACB0BE),
                c(0x6C6F85), c(0xD20F39), c(0x40A02B), c(0xDF8E1D),
                c(0x1E66F5), c(0xEA76CB), c(0x179299), c(0xBCC0CC),
            ])
    }

    static var nightOwl: DamsonTheme {
        DamsonTheme(
            name: "Night Owl",
            background: c(0x011627), foreground: c(0xD6DEEB), cursor: c(0x80A4C2),
            ansi: [
                c(0x011627), c(0xEF5350), c(0x22DA6E), c(0xADDB67),
                c(0x82AAFF), c(0xC792EA), c(0x21C7A8), c(0xFFFFFF),
                c(0x575656), c(0xEF5350), c(0x22DA6E), c(0xFFEB95),
                c(0x82AAFF), c(0xC792EA), c(0x7FDBCA), c(0xFFFFFF),
            ])
    }

    static var ayuDark: DamsonTheme {
        DamsonTheme(
            name: "Ayu Dark",
            background: c(0x0A0E14), foreground: c(0xB3B1AD), cursor: c(0xE6B450),
            ansi: [
                c(0x01060E), c(0xEA6C73), c(0x91B362), c(0xF9AF4F),
                c(0x53BDFA), c(0xFAE994), c(0x90E1C6), c(0xC7C7C7),
                c(0x686868), c(0xF07178), c(0xC2D94C), c(0xFFB454),
                c(0x59C2FF), c(0xFFEE99), c(0x95E6CB), c(0xFFFFFF),
            ])
    }

    static var ayuMirage: DamsonTheme {
        DamsonTheme(
            name: "Ayu Mirage",
            background: c(0x1F2430), foreground: c(0xCBCCC6), cursor: c(0xFFCC66),
            ansi: [
                c(0x191E2A), c(0xED8274), c(0xA6CC70), c(0xFAD07B),
                c(0x6DCBFA), c(0xCFBAFA), c(0x90E1C6), c(0xC7C7C7),
                c(0x686868), c(0xF28779), c(0xBAE67E), c(0xFFD580),
                c(0x73D0FF), c(0xD4BFFF), c(0x95E6CB), c(0xFFFFFF),
            ])
    }

    static var githubDark: DamsonTheme {
        DamsonTheme(
            name: "GitHub Dark",
            background: c(0x0D1117), foreground: c(0xC9D1D9), cursor: c(0xC9D1D9),
            ansi: [
                c(0x484F58), c(0xFF7B72), c(0x3FB950), c(0xD29922),
                c(0x58A6FF), c(0xBC8CFF), c(0x39C5CF), c(0xB1BAC4),
                c(0x6E7681), c(0xFFA198), c(0x56D364), c(0xE3B341),
                c(0x79C0FF), c(0xD2A8FF), c(0x56D4DD), c(0xF0F6FC),
            ])
    }

    static var githubLight: DamsonTheme {
        DamsonTheme(
            name: "GitHub Light",
            background: c(0xFFFFFF), foreground: c(0x24292F), cursor: c(0x24292F),
            ansi: [
                c(0x24292E), c(0xD73A49), c(0x28A745), c(0xDBAB09),
                c(0x0366D6), c(0x5A32A3), c(0x0598BC), c(0x6A737D),
                c(0x959DA5), c(0xCB2431), c(0x22863A), c(0xB08800),
                c(0x005CC5), c(0x5A32A3), c(0x3192AA), c(0xD1D5DA),
            ])
    }

    static var rosePine: DamsonTheme {
        DamsonTheme(
            name: "Rosé Pine",
            background: c(0x191724), foreground: c(0xE0DEF4), cursor: c(0xE0DEF4),
            ansi: [
                c(0x26233A), c(0xEB6F92), c(0x31748F), c(0xF6C177),
                c(0x9CCFD8), c(0xC4A7E7), c(0xEBBCBA), c(0xE0DEF4),
                c(0x6E6A86), c(0xEB6F92), c(0x31748F), c(0xF6C177),
                c(0x9CCFD8), c(0xC4A7E7), c(0xEBBCBA), c(0xE0DEF4),
            ])
    }

    static var rosePineMoon: DamsonTheme {
        DamsonTheme(
            name: "Rosé Pine Moon",
            background: c(0x232136), foreground: c(0xE0DEF4), cursor: c(0xE0DEF4),
            ansi: [
                c(0x393552), c(0xEB6F92), c(0x3E8FB0), c(0xF6C177),
                c(0x9CCFD8), c(0xC4A7E7), c(0xEA9A97), c(0xE0DEF4),
                c(0x6E6A86), c(0xEB6F92), c(0x3E8FB0), c(0xF6C177),
                c(0x9CCFD8), c(0xC4A7E7), c(0xEA9A97), c(0xE0DEF4),
            ])
    }

    static var rosePineDawn: DamsonTheme {
        DamsonTheme(
            name: "Rosé Pine Dawn",
            background: c(0xFAF4ED), foreground: c(0x575279), cursor: c(0x575279),
            ansi: [
                c(0xF2E9E1), c(0xB4637A), c(0x286983), c(0xEA9D34),
                c(0x56949F), c(0x907AA9), c(0xD7827E), c(0x575279),
                c(0x9893A5), c(0xB4637A), c(0x286983), c(0xEA9D34),
                c(0x56949F), c(0x907AA9), c(0xD7827E), c(0x575279),
            ])
    }

    static var palenight: DamsonTheme {
        DamsonTheme(
            name: "Palenight",
            background: c(0x292D3E), foreground: c(0xA6ACCD), cursor: c(0xFFCC00),
            ansi: [
                c(0x292D3E), c(0xF07178), c(0xC3E88D), c(0xFFCB6B),
                c(0x82AAFF), c(0xC792EA), c(0x89DDFF), c(0xD0D0D0),
                c(0x434758), c(0xFF8B92), c(0xDDFFA7), c(0xFFE585),
                c(0x9CC4FF), c(0xE1ACFF), c(0xA3F7FF), c(0xFFFFFF),
            ])
    }

    static var cobalt2: DamsonTheme {
        DamsonTheme(
            name: "Cobalt2",
            background: c(0x132738), foreground: c(0xFFFFFF), cursor: c(0xFF9D00),
            ansi: [
                c(0x000000), c(0xFF0000), c(0x38DE21), c(0xFFE50A),
                c(0x1460D2), c(0xFF005D), c(0x00BBBB), c(0xBBBBBB),
                c(0x555555), c(0xF40E17), c(0x3BD01D), c(0xEDC809),
                c(0x5555FF), c(0xFF55FF), c(0x6AE3FA), c(0xFFFFFF),
            ])
    }

    static var tomorrowNight: DamsonTheme {
        DamsonTheme(
            name: "Tomorrow Night",
            background: c(0x1D1F21), foreground: c(0xC5C8C6), cursor: c(0xC5C8C6),
            ansi: [
                c(0x1D1F21), c(0xCC6666), c(0xB5BD68), c(0xF0C674),
                c(0x81A2BE), c(0xB294BB), c(0x8ABEB7), c(0xC5C8C6),
                c(0x969896), c(0xCC6666), c(0xB5BD68), c(0xF0C674),
                c(0x81A2BE), c(0xB294BB), c(0x8ABEB7), c(0xFFFFFF),
            ])
    }

    static var tomorrowNightEighties: DamsonTheme {
        DamsonTheme(
            name: "Tomorrow Night Eighties",
            background: c(0x2D2D2D), foreground: c(0xCCCCCC), cursor: c(0xCCCCCC),
            ansi: [
                c(0x000000), c(0xF2777A), c(0x99CC99), c(0xFFCC66),
                c(0x6699CC), c(0xCC99CC), c(0x66CCCC), c(0xFFFFFF),
                c(0x000000), c(0xF2777A), c(0x99CC99), c(0xFFCC66),
                c(0x6699CC), c(0xCC99CC), c(0x66CCCC), c(0xFFFFFF),
            ])
    }

    static var tomorrow: DamsonTheme {
        DamsonTheme(
            name: "Tomorrow",
            background: c(0xFFFFFF), foreground: c(0x4D4D4C), cursor: c(0x4D4D4C),
            ansi: [
                c(0x000000), c(0xC82829), c(0x718C00), c(0xEAB700),
                c(0x4271AE), c(0x8959A8), c(0x3E999F), c(0x4D4D4C),
                c(0x8E908C), c(0xC82829), c(0x718C00), c(0xEAB700),
                c(0x4271AE), c(0x8959A8), c(0x3E999F), c(0x1D1F21),
            ])
    }

    static var hyperSnazzy: DamsonTheme {
        DamsonTheme(
            name: "Hyper Snazzy",
            background: c(0x282A36), foreground: c(0xEFF0EB), cursor: c(0x97979B),
            ansi: [
                c(0x282A36), c(0xFF5C57), c(0x5AF78E), c(0xF3F99D),
                c(0x57C7FF), c(0xFF6AC1), c(0x9AEDFE), c(0xF1F1F0),
                c(0x686868), c(0xFF5C57), c(0x5AF78E), c(0xF3F99D),
                c(0x57C7FF), c(0xFF6AC1), c(0x9AEDFE), c(0xEFF0EB),
            ])
    }

    static var material: DamsonTheme {
        DamsonTheme(
            name: "Material",
            background: c(0x263238), foreground: c(0xEEFFFF), cursor: c(0xFFCC00),
            ansi: [
                c(0x000000), c(0xFF5370), c(0xC3E88D), c(0xFFCB6B),
                c(0x82AAFF), c(0xC792EA), c(0x89DDFF), c(0xFFFFFF),
                c(0x545454), c(0xFF5370), c(0xC3E88D), c(0xFFCB6B),
                c(0x82AAFF), c(0xC792EA), c(0x89DDFF), c(0xFFFFFF),
            ])
    }

    static var everforestDark: DamsonTheme {
        DamsonTheme(
            name: "Everforest Dark",
            background: c(0x2D353B), foreground: c(0xD3C6AA), cursor: c(0xD3C6AA),
            ansi: [
                c(0x343F44), c(0xE67E80), c(0xA7C080), c(0xDBBC7F),
                c(0x7FBBB3), c(0xD699B6), c(0x83C092), c(0xD3C6AA),
                c(0x475258), c(0xE67E80), c(0xA7C080), c(0xDBBC7F),
                c(0x7FBBB3), c(0xD699B6), c(0x83C092), c(0xD3C6AA),
            ])
    }

    static var kanagawa: DamsonTheme {
        DamsonTheme(
            name: "Kanagawa",
            background: c(0x1F1F28), foreground: c(0xDCD7BA), cursor: c(0xC8C093),
            ansi: [
                c(0x090618), c(0xC34043), c(0x76946A), c(0xC0A36E),
                c(0x7E9CD8), c(0x957FB8), c(0x6A9589), c(0xC8C093),
                c(0x727169), c(0xE82424), c(0x98BB6C), c(0xE6C384),
                c(0x7FB4CA), c(0x938AA9), c(0x7AA89F), c(0xDCD7BA),
            ])
    }

    static var iceberg: DamsonTheme {
        DamsonTheme(
            name: "Iceberg",
            background: c(0x161821), foreground: c(0xC6C8D1), cursor: c(0xC6C8D1),
            ansi: [
                c(0x1E2132), c(0xE27878), c(0xB4BE82), c(0xE2A478),
                c(0x84A0C6), c(0xA093C7), c(0x89B8C2), c(0xC6C8D1),
                c(0x6B7089), c(0xE98989), c(0xC0CA8E), c(0xE9B189),
                c(0x91ACD1), c(0xADA0D3), c(0x95C4CE), c(0xD2D4DE),
            ])
    }

    static var gruvboxLight: DamsonTheme {
        DamsonTheme(
            name: "Gruvbox Light",
            background: c(0xFBF1C7), foreground: c(0x3C3836), cursor: c(0x3C3836),
            ansi: [
                c(0xFBF1C7), c(0xCC241D), c(0x98971A), c(0xD79921),
                c(0x458588), c(0xB16286), c(0x689D6A), c(0x7C6F64),
                c(0x928374), c(0x9D0006), c(0x79740E), c(0xB57614),
                c(0x076678), c(0x8F3F71), c(0x427B58), c(0x3C3836),
            ])
    }
}
