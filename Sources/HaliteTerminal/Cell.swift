import AppKit
import Foundation

/// 한 셀의 시각 속성. SGR로 바뀌는 "현재 펜(pen)"이 이 값을 만들고,
/// 새 글자가 grid에 쓰일 때 그 글자에 attach 된다.
public struct CellAttrs: Equatable {
    public var fg: NSColor
    public var bg: NSColor?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var inverse: Bool

    public init(
        fg: NSColor,
        bg: NSColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        inverse: Bool = false
    ) {
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
    }

    /// foregroundColor / backgroundColor를 inverse 반영 후 산출.
    public func resolvedColors(defaultBG: NSColor) -> (fg: NSColor, bg: NSColor?) {
        if inverse {
            return (bg ?? defaultBG, fg)
        }
        return (fg, bg)
    }
}

/// Grid의 한 셀. 글자 하나 + 속성.
/// East Asian Wide / 합자 등은 M5에서 width 필드 추가.
public struct Cell: Equatable {
    public var char: Character
    public var attrs: CellAttrs

    public init(char: Character, attrs: CellAttrs) {
        self.char = char
        self.attrs = attrs
    }

    /// 빈 셀 (공백 + 펜 속성).
    public static func empty(attrs: CellAttrs) -> Cell {
        Cell(char: " ", attrs: attrs)
    }
}
