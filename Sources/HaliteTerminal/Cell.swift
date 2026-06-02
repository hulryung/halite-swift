import AppKit
import Foundation
import Darwin

/// Set a UTF-8 ctype once so libc `wcwidth` returns real widths (the "C" locale
/// reports 1 for everything). Cell width is matched to `wcwidth` so the grid's
/// column accounting agrees with the shell's (cursor/erase stay in sync).
private let _wcwidthLocale: Int = {
    setlocale(LC_CTYPE, "en_US.UTF-8")
    return 0
}()

/// 셀의 의미론적 색. NSColor를 직접 저장하지 않고 "무슨 색인지"만 보관한 뒤
/// 렌더 시점에 현재 테마로 resolve한다 → 테마를 바꾸면 이미 그려진 ANSI 색까지
/// 즉시 recolor됨 (Terminal.app/iTerm2 동작). truecolor(.rgb)는 절대값이라
/// 테마와 무관 (Starship 무지개 프롬프트 등은 테마 바꿔도 그대로 — 정상).
public enum TermColor: Equatable {
    /// 기본 전경색 (테마의 foreground). bg에는 사용하지 않음 — bg의 "기본"은 nil(투명).
    case `default`
    /// ANSI 팔레트 인덱스 0-255. 0-15는 테마의 16색, 16-255는 표준 xterm cube/grayscale.
    case palette(Int)
    /// truecolor.
    case rgb(UInt8, UInt8, UInt8)
}

/// 한 셀의 시각 속성. SGR로 바뀌는 "현재 펜(pen)"이 이 값을 만들고,
/// 새 글자가 grid에 쓰일 때 그 글자에 attach 된다.
public struct CellAttrs: Equatable {
    public var fg: TermColor
    public var bg: TermColor?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    public var inverse: Bool

    public init(
        fg: TermColor = .default,
        bg: TermColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        inverse: Bool = false
    ) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.inverse = inverse
    }

    /// 현재 테마로 fg/bg를 실제 NSColor로 resolve (inverse 반영).
    /// bg가 nil이면 투명(window background 비침).
    public func resolvedColors(theme: HaliteTheme) -> (fg: NSColor, bg: NSColor?) {
        let f = theme.nsColor(fg)
        let b: NSColor? = bg.map { theme.nsColor($0) }
        if inverse {
            return (b ?? theme.background, f)
        }
        return (f, b)
    }
}

/// One physical grid row: its cells plus a soft-wrap bit.
///
/// `wrapped == true` means this row filled to the right margin and its text
/// continues on the next row with no intervening CR/LF — i.e. it's one half of
/// a single logical line that the terminal split to fit the width. A row ended
/// by an explicit newline leaves `wrapped == false`. This bit is exactly what
/// reflow needs to rejoin physical rows into logical lines and re-split them at
/// a new width.
///
/// The mutable `subscript(Int)` keeps existing `cells[r][c]` / `cells[r][c] = x`
/// call sites compiling unchanged once `cells` becomes `[Line]`.
public struct Line: Equatable {
    public var cells: [Cell]
    public var wrapped: Bool

    public init(_ cells: [Cell], wrapped: Bool = false) {
        self.cells = cells
        self.wrapped = wrapped
    }

    public var count: Int { cells.count }

    public subscript(_ i: Int) -> Cell {
        get { cells[i] }
        set { cells[i] = newValue }
    }

    /// A fresh blank row of `cols` cells (never wrapped).
    public static func blank(cols: Int, attrs: CellAttrs) -> Line {
        Line(Array(repeating: Cell.empty(attrs: attrs), count: cols))
    }
}

/// Grid의 한 셀. 글자 하나 + 속성 + (옵션) hyperlink.
public struct Cell: Equatable {
    public var char: Character
    public var attrs: CellAttrs
    /// East Asian Wide 문자의 *후행(trailing) 셀* 표시.
    /// true면 렌더러가 이 셀을 NSAttributedString에 추가하지 않음 (선행 셀의
    /// wide glyph가 자연스럽게 두 칸을 점유함). 셸이 보내는 wide-aware backspace
    /// (`\b\b  \b\b`)가 두 cell을 함께 비울 때 정상 동작에 필요.
    public var isContinuation: Bool
    /// OSC 8 hyperlink URI. 셀이 hyperlink의 일부면 set.
    /// run-length 그룹핑 시 hyperlink 경계에서 split됨.
    public var hyperlink: String?

    public init(
        char: Character,
        attrs: CellAttrs,
        isContinuation: Bool = false,
        hyperlink: String? = nil
    ) {
        self.char = char
        self.attrs = attrs
        self.isContinuation = isContinuation
        self.hyperlink = hyperlink
    }

    /// 빈 셀 (공백 + 펜 속성).
    public static func empty(attrs: CellAttrs) -> Cell {
        Cell(char: " ", attrs: attrs)
    }

    /// wide char의 후행 cell. 선행 cell 다음 칸에 배치. 선행 cell의 hyperlink를
    /// 이어받아야 hyperlink 범위 판정(hover/클릭)이 wide 글자에서 끊기지 않는다.
    public static func continuation(attrs: CellAttrs, hyperlink: String? = nil) -> Cell {
        Cell(char: " ", attrs: attrs, isContinuation: true, hyperlink: hyperlink)
    }

    /// 이 grapheme이 컬러 이모지(emoji presentation)로 그려져야 하는지.
    /// 기본 emoji-presentation 문자(😀 등) + VS16(U+FE0F)로 강제된 시퀀스(ℹ️ 등)를
    /// 포함. ZWJ/스킨톤/플래그 시퀀스는 첫 스칼라의 속성으로 잡힌다.
    public static func isEmojiPresentation(_ ch: Character) -> Bool {
        for s in ch.unicodeScalars {
            if s.value == 0xFE0F { return true }                       // emoji variation selector
            if (0x1F1E6...0x1F1FF).contains(s.value) { return true }   // regional indicators (flags)
            if s.properties.isEmojiPresentation { return true }
        }
        return false
    }

    /// True if `ch` occupies 2 terminal cells. Matched to the shell's width model:
    /// a regional-indicator pair (flag) is 2; other emoji/VS16 graphemes use libc
    /// `wcwidth` of the base scalar (so 😀 = 2 but ❤️ via VS16 = 1, lone RI = 1 —
    /// agreeing with the shell so cursor/erase don't desync); everything else uses
    /// the East-Asian-Wide range table.
    public static func isWide(_ ch: Character) -> Bool {
        let scalars = Array(ch.unicodeScalars)
        // Regional-indicator pair → flag → 2 cells.
        if scalars.count == 2,
           (0x1F1E6...0x1F1FF).contains(scalars[0].value),
           (0x1F1E6...0x1F1FF).contains(scalars[1].value) {
            return true
        }
        // Emoji / VS16: defer to wcwidth of the base scalar (shell-consistent).
        if isEmojiPresentation(ch) {
            return scalars.first.map { scalarIsWide($0.value) } ?? false
        }
        for scalar in scalars {
            let v = scalar.value
            switch v {
            case 0x1100...0x115F: return true   // Hangul Jamo (choseong)
            case 0x2E80...0x303E: return true   // CJK Radicals, Kangxi, CJK Symbols
            case 0x3041...0x33FF: return true   // Hiragana, Katakana, Bopomofo, Hangul Compat Jamo, CJK Compat
            case 0x3400...0x4DBF: return true   // CJK Unified Ideographs Extension A
            case 0x4E00...0x9FFF: return true   // CJK Unified Ideographs
            case 0xA000...0xA4CF: return true   // Yi
            case 0xAC00...0xD7A3: return true   // Hangul Syllables
            case 0xF900...0xFAFF: return true   // CJK Compatibility Ideographs
            case 0xFE30...0xFE4F: return true   // CJK Compatibility Forms
            case 0xFF00...0xFF60: return true   // Fullwidth Forms
            case 0xFFE0...0xFFE6: return true   // Fullwidth signs
            case 0x20000...0x2FFFD: return true // CJK Extension B-F
            case 0x30000...0x3FFFD: return true // CJK Extension G+
            default: continue
            }
        }
        return false
    }

    /// libc `wcwidth` of a scalar == 2 (the shell's notion of "wide").
    private static func scalarIsWide(_ v: UInt32) -> Bool {
        _ = _wcwidthLocale
        guard v <= 0x10FFFF else { return false }
        return wcwidth(wchar_t(Int32(v))) == 2
    }
}
