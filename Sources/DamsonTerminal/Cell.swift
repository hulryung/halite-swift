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

/// A cell's semantic color. Stores only "which color it is" rather than an NSColor,
/// resolved against the current theme at render time → switching themes instantly
/// recolors already-drawn ANSI colors (Terminal.app/iTerm2 behavior). truecolor(.rgb)
/// is absolute, so theme-independent (Starship rainbow prompts etc. stay put — correct).
public enum TermColor: Equatable, Codable {
    /// Default foreground (the theme's foreground). Not used for bg — the bg "default" is nil (transparent).
    case `default`
    /// ANSI palette index 0-255. 0-15 are the theme's 16 colors, 16-255 the standard xterm cube/grayscale.
    case palette(Int)
    /// truecolor.
    case rgb(UInt8, UInt8, UInt8)
}

/// Visual attributes of one cell. The "current pen" mutated by SGR produces this
/// value, and it's attached to each new character as it's written into the grid.
public struct CellAttrs: Equatable, Codable {
    public var fg: TermColor
    public var bg: TermColor?
    public var bold: Bool
    /// SGR 2 (faint/dim). Draws fg blended about halfway toward the background —
    /// shell autosuggestions, Claude Code's gray suggestion text, etc. use this.
    public var faint: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    public var inverse: Bool

    public init(
        fg: TermColor = .default,
        bg: TermColor? = nil,
        bold: Bool = false,
        faint: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        inverse: Bool = false
    ) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.faint = faint
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.inverse = inverse
    }

    /// Resolve fg/bg to actual NSColors with the current theme (applying inverse + faint).
    /// nil bg means transparent (window background shows through).
    public func resolvedColors(theme: DamsonTheme) -> (fg: NSColor, bg: NSColor?) {
        var f = theme.nsColor(fg)
        let b: NSColor? = bg.map { theme.nsColor($0) }
        // faint (SGR 2): dim fg toward the background. With inverse, the visible
        // glyph color is the pre-swap f, so apply before swapping.
        if faint {
            f = Self.dim(f, toward: b ?? theme.background, fraction: 0.5)
        }
        if inverse {
            return (b ?? theme.background, f)
        }
        return (f, b)
    }

    /// Interpolate `c` toward `toward` by `fraction` in sRGB (0 = original, 1 = fully toward).
    private static func dim(_ c: NSColor, toward: NSColor, fraction t: CGFloat) -> NSColor {
        let a = c.usingColorSpace(.sRGB) ?? c
        let d = toward.usingColorSpace(.sRGB) ?? toward
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return NSColor(srgbRed: mix(a.redComponent, d.redComponent),
                       green: mix(a.greenComponent, d.greenComponent),
                       blue: mix(a.blueComponent, d.blueComponent),
                       alpha: a.alphaComponent)
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
    /// Set on the row where the shell emitted OSC 133;A (prompt start). Reflow uses
    /// it to preserve the whole live prompt block's physical-row count (so the
    /// shell's relative SIGWINCH redraw doesn't erase content above the prompt).
    public var isPromptStart: Bool

    public init(_ cells: [Cell], wrapped: Bool = false, isPromptStart: Bool = false) {
        self.cells = cells
        self.wrapped = wrapped
        self.isPromptStart = isPromptStart
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

/// One cell of the Grid. A single character + attributes + (optional) hyperlink.
public struct Cell: Equatable {
    public var char: Character
    public var attrs: CellAttrs
    /// Marks the *trailing cell* of an East Asian Wide character.
    /// When true the renderer doesn't add this cell to the NSAttributedString (the
    /// leading cell's wide glyph naturally occupies both columns). Needed so the
    /// shell's wide-aware backspace (`\b\b  \b\b`) correctly clears both cells.
    public var isContinuation: Bool
    /// The *layout filler* left behind when a wide char doesn't fit the row's last
    /// column and wraps to the next row. It's pure width padding, not content, so
    /// reflow skips it when rejoining physical rows into logical lines (must be
    /// distinguishable from a content space or narrow→wide resizes misalign).
    public var isWideSpacer: Bool
    /// OSC 8 hyperlink URI. Set when the cell is part of a hyperlink.
    /// Run-length grouping splits at hyperlink boundaries.
    public var hyperlink: String?

    public init(
        char: Character,
        attrs: CellAttrs,
        isContinuation: Bool = false,
        isWideSpacer: Bool = false,
        hyperlink: String? = nil
    ) {
        self.char = char
        self.attrs = attrs
        self.isContinuation = isContinuation
        self.isWideSpacer = isWideSpacer
        self.hyperlink = hyperlink
    }

    /// A blank cell (space + pen attributes).
    public static func empty(attrs: CellAttrs) -> Cell {
        Cell(char: " ", attrs: attrs)
    }

    /// The filler cell left where a wide char didn't fit the last column and was
    /// pushed to the next row. Looks like a space but is excluded as non-content on reflow.
    public static func wideSpacer(attrs: CellAttrs) -> Cell {
        Cell(char: " ", attrs: attrs, isWideSpacer: true)
    }

    /// The trailing cell of a wide char, placed right after the leading cell. It must
    /// inherit the leading cell's hyperlink so hyperlink range hit-testing (hover/click)
    /// doesn't break in the middle of a wide character.
    public static func continuation(attrs: CellAttrs, hyperlink: String? = nil) -> Cell {
        Cell(char: " ", attrs: attrs, isContinuation: true, hyperlink: hyperlink)
    }

    /// Whether this grapheme should be drawn as color emoji (emoji presentation).
    /// Covers default emoji-presentation characters (😀 etc.) plus sequences forced
    /// by VS16 (U+FE0F, e.g. ℹ️). ZWJ/skin-tone/flag sequences are caught via the
    /// first scalar's properties.
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
