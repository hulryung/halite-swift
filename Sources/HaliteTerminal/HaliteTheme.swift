import AppKit
import Foundation

/// 터미널 색 테마 — background / foreground / cursor + ANSI 16색.
/// TermColor를 NSColor로 resolve할 때 사용. 앱 전역 하나의 테마 (Settings에서 선택).
public struct HaliteTheme: Equatable {
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

// MARK: - 프리셋

public extension HaliteTheme {
    private static func c(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// 모든 내장 프리셋 (Settings picker 순서).
    static var presets: [HaliteTheme] {
        [.defaultDark, .solarizedDark, .dracula, .gruvboxDark, .nord, .tokyoNight, .solarizedLight]
    }

    static func preset(named name: String) -> HaliteTheme? {
        presets.first { $0.name == name }
    }

    /// xterm 기본에 가까운 다크 테마 (halite 디폴트).
    static var defaultDark: HaliteTheme {
        HaliteTheme(
            name: "Default Dark",
            background: c(0x000000), foreground: c(0xE5E5E5), cursor: c(0xE5E5E5),
            ansi: [
                c(0x000000), c(0xCD0000), c(0x00CD00), c(0xCDCD00),
                c(0x0000EE), c(0xCD00CD), c(0x00CDCD), c(0xE5E5E5),
                c(0x7F7F7F), c(0xFF0000), c(0x00FF00), c(0xFFFF00),
                c(0x5C5CFF), c(0xFF00FF), c(0x00FFFF), c(0xFFFFFF),
            ])
    }

    static var solarizedDark: HaliteTheme {
        HaliteTheme(
            name: "Solarized Dark",
            background: c(0x002B36), foreground: c(0x839496), cursor: c(0x93A1A1),
            ansi: [
                c(0x073642), c(0xDC322F), c(0x859900), c(0xB58900),
                c(0x268BD2), c(0xD33682), c(0x2AA198), c(0xEEE8D5),
                c(0x002B36), c(0xCB4B16), c(0x586E75), c(0x657B83),
                c(0x839496), c(0x6C71C4), c(0x93A1A1), c(0xFDF6E3),
            ])
    }

    static var solarizedLight: HaliteTheme {
        HaliteTheme(
            name: "Solarized Light",
            background: c(0xFDF6E3), foreground: c(0x657B83), cursor: c(0x586E75),
            ansi: [
                c(0x073642), c(0xDC322F), c(0x859900), c(0xB58900),
                c(0x268BD2), c(0xD33682), c(0x2AA198), c(0xEEE8D5),
                c(0x002B36), c(0xCB4B16), c(0x586E75), c(0x657B83),
                c(0x839496), c(0x6C71C4), c(0x93A1A1), c(0xFDF6E3),
            ])
    }

    static var dracula: HaliteTheme {
        HaliteTheme(
            name: "Dracula",
            background: c(0x282A36), foreground: c(0xF8F8F2), cursor: c(0xF8F8F2),
            ansi: [
                c(0x21222C), c(0xFF5555), c(0x50FA7B), c(0xF1FA8C),
                c(0xBD93F9), c(0xFF79C6), c(0x8BE9FD), c(0xF8F8F2),
                c(0x6272A4), c(0xFF6E6E), c(0x69FF94), c(0xFFFFA5),
                c(0xD6ACFF), c(0xFF92DF), c(0xA4FFFF), c(0xFFFFFF),
            ])
    }

    static var gruvboxDark: HaliteTheme {
        HaliteTheme(
            name: "Gruvbox Dark",
            background: c(0x282828), foreground: c(0xEBDBB2), cursor: c(0xEBDBB2),
            ansi: [
                c(0x282828), c(0xCC241D), c(0x98971A), c(0xD79921),
                c(0x458588), c(0xB16286), c(0x689D6A), c(0xA89984),
                c(0x928374), c(0xFB4934), c(0xB8BB26), c(0xFABD2F),
                c(0x83A598), c(0xD3869B), c(0x8EC07C), c(0xEBDBB2),
            ])
    }

    static var nord: HaliteTheme {
        HaliteTheme(
            name: "Nord",
            background: c(0x2E3440), foreground: c(0xD8DEE9), cursor: c(0xD8DEE9),
            ansi: [
                c(0x3B4252), c(0xBF616A), c(0xA3BE8C), c(0xEBCB8B),
                c(0x81A1C1), c(0xB48EAD), c(0x88C0D0), c(0xE5E9F0),
                c(0x4C566A), c(0xBF616A), c(0xA3BE8C), c(0xEBCB8B),
                c(0x81A1C1), c(0xB48EAD), c(0x8FBCBB), c(0xECEFF4),
            ])
    }

    static var tokyoNight: HaliteTheme {
        HaliteTheme(
            name: "Tokyo Night",
            background: c(0x1A1B26), foreground: c(0xC0CAF5), cursor: c(0xC0CAF5),
            ansi: [
                c(0x15161E), c(0xF7768E), c(0x9ECE6A), c(0xE0AF68),
                c(0x7AA2F7), c(0xBB9AF7), c(0x7DCFFF), c(0xA9B1D6),
                c(0x414868), c(0xF7768E), c(0x9ECE6A), c(0xE0AF68),
                c(0x7AA2F7), c(0xBB9AF7), c(0x7DCFFF), c(0xC0CAF5),
            ])
    }
}
