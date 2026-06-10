import Foundation

/// How a tmux split group arranges its children. tmux encodes this in the layout string
/// by the bracket style: `{…}` lays children out left→right, `[…]` top→bottom.
/// Names follow the Damson/iTerm2 convention: `horizontal` = side by side (vertical
/// divider), `vertical` = stacked (horizontal divider).
public enum TmuxSplitOrientation: Equatable {
    case horizontal  // tmux `{…}` — children left/right
    case vertical    // tmux `[…]` — children top/bottom
}

/// The structured form of a tmux `%layout-change` layout string (docs §4.9). A window's
/// pane arrangement is an **N-ary** tree: a leaf is one pane `%N`; a split group has two or
/// more children laid out along one axis. Each cell also carries its size/offset in tmux
/// cells, which the reconciler uses to compute Damson split ratios.
///
/// Parsed by `TmuxLayoutTree.parse(_:)` — pure logic, no I/O, fully unit-testable.
public indirect enum TmuxLayoutTree: Equatable {
    /// A single pane occupying `width`×`height` cells at offset (`x`, `y`).
    case leaf(pane: TmuxPaneID, width: Int, height: Int, x: Int, y: Int)
    /// A split group: `children` (≥2) arranged along `orientation`, filling `width`×`height`
    /// at offset (`x`, `y`).
    case split(orientation: TmuxSplitOrientation, width: Int, height: Int, x: Int, y: Int,
               children: [TmuxLayoutTree])

    /// The cell geometry common to both cases — `(width, height, x, y)` in tmux cells.
    public var geometry: (width: Int, height: Int, x: Int, y: Int) {
        switch self {
        case let .leaf(_, w, h, x, y): return (w, h, x, y)
        case let .split(_, w, h, x, y, _): return (w, h, x, y)
        }
    }

    /// Every pane id in this subtree, left-to-right / top-to-bottom (in-order) traversal.
    public var paneIDs: [TmuxPaneID] {
        switch self {
        case let .leaf(pane, _, _, _, _):
            return [pane]
        case let .split(_, _, _, _, _, children):
            return children.flatMap { $0.paneIDs }
        }
    }

    /// The total terminal size in cells this layout occupies, given each leaf pane's measured
    /// display size via `sizeOf`. A split sums its children along the split axis **plus one
    /// border cell per divider** (how tmux accounts for pane borders) and takes the max across
    /// the other axis. Returns nil if any leaf has no measured size yet — so a caller never
    /// sends a half-formed client size while a freshly-split pane is still laying out.
    ///
    /// Used for resize negotiation: the host computes this from its native pane sizes and
    /// sends it as `refresh-client -C`, so tmux re-lays-out panes to fill the window.
    public func totalCellSize(
        _ sizeOf: (TmuxPaneID) -> (cols: Int, rows: Int)?
    ) -> (cols: Int, rows: Int)? {
        switch self {
        case let .leaf(pane, _, _, _, _):
            return sizeOf(pane)
        case let .split(orientation, _, _, _, _, children):
            var sizes: [(cols: Int, rows: Int)] = []
            for child in children {
                guard let s = child.totalCellSize(sizeOf) else { return nil }
                sizes.append(s)
            }
            let dividers = children.count - 1
            switch orientation {
            case .horizontal:
                return (sizes.reduce(0) { $0 + $1.cols } + dividers, sizes.map(\.rows).max() ?? 0)
            case .vertical:
                return (sizes.map(\.cols).max() ?? 0, sizes.reduce(0) { $0 + $1.rows } + dividers)
            }
        }
    }

    // MARK: - Parsing

    /// Parse a tmux layout string into a structured tree, or nil if malformed.
    ///
    /// Format (docs §4.9): an optional 4-hex-digit checksum + comma, then one cell. A cell is
    /// `WxH,x,y` followed by one of:
    ///   - `,<paneid>` → leaf
    ///   - `{<cell>,<cell>,…}` → horizontal split (children left→right)
    ///   - `[<cell>,<cell>,…]` → vertical split (children top→bottom)
    /// Example: `e7b2,80x24,0,0{40x24,0,0,1,39x24,41,0,2}`.
    public static func parse(_ layout: String) -> TmuxLayoutTree? {
        let chars = Array(layout)
        var i = 0
        // Strip a leading checksum `xxxx,` if present. The checksum is hex with no `x`; a bare
        // cell always starts with `WxH`, so the presence of an `x` before the first comma
        // distinguishes "cell, no checksum" from "checksum, then cell".
        if let firstComma = chars.firstIndex(of: ",") {
            let prefix = chars[chars.startIndex..<firstComma]
            if !prefix.contains("x") {
                i = firstComma + 1
            }
        }
        guard let (cell, next) = parseCell(chars, i) else { return nil }
        // The whole string must be consumed (allowing nothing trailing) for a valid layout.
        guard next == chars.count else { return nil }
        return cell
    }

    /// Recursive-descent parse of one cell beginning at `start`. Returns the cell and the
    /// index just past it, or nil on malformed input.
    private static func parseCell(_ chars: [Character], _ start: Int) -> (TmuxLayoutTree, Int)? {
        var i = start
        guard let (w, i1) = readInt(chars, i) else { return nil }
        i = i1
        guard i < chars.count, chars[i] == "x" else { return nil }
        i += 1
        guard let (h, i2) = readInt(chars, i) else { return nil }
        i = i2
        guard i < chars.count, chars[i] == "," else { return nil }
        i += 1
        guard let (x, i3) = readInt(chars, i) else { return nil }
        i = i3
        guard i < chars.count, chars[i] == "," else { return nil }
        i += 1
        guard let (y, i4) = readInt(chars, i) else { return nil }
        i = i4

        // What follows `WxH,x,y` decides leaf vs split.
        guard i < chars.count else { return nil }
        switch chars[i] {
        case ",":
            // `,<paneid>` → leaf.
            i += 1
            guard let (id, i5) = readInt(chars, i) else { return nil }
            return (.leaf(pane: TmuxPaneID(id), width: w, height: h, x: x, y: y), i5)
        case "{", "[":
            let orientation: TmuxSplitOrientation = chars[i] == "{" ? .horizontal : .vertical
            let close: Character = chars[i] == "{" ? "}" : "]"
            i += 1
            var children: [TmuxLayoutTree] = []
            while true {
                guard let (child, ni) = parseCell(chars, i) else { return nil }
                children.append(child)
                i = ni
                guard i < chars.count else { return nil }
                if chars[i] == "," {
                    i += 1
                    continue
                }
                if chars[i] == close {
                    i += 1
                    break
                }
                return nil  // unexpected delimiter inside a group
            }
            guard children.count >= 2 else { return nil }  // a split must have ≥2 children
            return (.split(orientation: orientation, width: w, height: h, x: x, y: y,
                           children: children), i)
        default:
            return nil
        }
    }

    /// Read a run of decimal digits starting at `start`; returns the value and the index just
    /// past the last digit, or nil if there's no digit at `start`.
    private static func readInt(_ chars: [Character], _ start: Int) -> (Int, Int)? {
        var i = start
        var value = 0
        var any = false
        while i < chars.count, let d = chars[i].wholeNumberValue, chars[i].isNumber {
            value = value * 10 + d
            any = true
            i += 1
        }
        return any ? (value, i) : nil
    }
}
