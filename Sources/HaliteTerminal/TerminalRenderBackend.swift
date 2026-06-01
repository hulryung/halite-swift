import AppKit

/// A grid position in unified scrollback+viewport row indices
/// (`row == scrollback.count + viewportRow`).
public struct GridPos: Equatable {
    public var row: Int
    public var col: Int
    public init(row: Int, col: Int) { self.row = row; self.col = col }
}

/// Geometry of the underline/bar cursor overlay the host draws on its own layer.
public struct CursorOverlay {
    /// Frame in `contentView`-relative (== host) coordinates.
    public var frame: NSRect
    public var color: NSColor
    public init(frame: NSRect, color: NSColor) {
        self.frame = frame
        self.color = color
    }
}

/// Cell size in points. Computed ONCE by the host (`reportSizeIfChanged`) and
/// handed to whichever backend is active, so flipping the render toggle never
/// changes the reported `(cols, rows)` and never fires a spurious SIGWINCH.
public struct CellMetrics: Equatable {
    public var width: CGFloat
    public var height: CGFloat
    public init(width: CGFloat, height: CGFloat) { self.width = width; self.height = height }
}

/// Snapshot of the *view-local* render inputs — everything the renderer needs
/// beyond `Grid` + `HaliteConfig`. The host builds this each render; a backend
/// turns it (plus the grid/config) into pixels. It is `Equatable` so it can also
/// back a dedupe check, but the host currently keeps its own composite dirty key
/// and uses this purely as a data carrier (no behavior change in Phase 0).
public struct RenderState: Equatable {
    /// IME preedit text shown inline at the cursor (empty when not composing).
    public var markedText: String
    /// Selection endpoints (unnormalized: anchor = mouseDown, head = drag end).
    public var selectionAnchor: GridPos?
    public var selectionHead: GridPos?
    /// Find matches keyed by unified row → list of column ranges.
    public var findMatchesByRow: [Int: [Range<Int>]]
    /// The single active (Cmd+G-selected) match, if any, and its row.
    public var activeFindRow: Int?
    public var activeFindRange: Range<Int>?
    /// Cmd-hovered URL highlight (row + column range), if any.
    public var hoveredRow: Int?
    public var hoveredRange: Range<Int>?
    /// Cursor blink: whether blinking is enabled, and whether it's visible now.
    public var cursorBlinkEnabled: Bool
    public var cursorBlinkVisible: Bool

    public init(
        markedText: String = "",
        selectionAnchor: GridPos? = nil,
        selectionHead: GridPos? = nil,
        findMatchesByRow: [Int: [Range<Int>]] = [:],
        activeFindRow: Int? = nil,
        activeFindRange: Range<Int>? = nil,
        hoveredRow: Int? = nil,
        hoveredRange: Range<Int>? = nil,
        cursorBlinkEnabled: Bool = false,
        cursorBlinkVisible: Bool = true
    ) {
        self.markedText = markedText
        self.selectionAnchor = selectionAnchor
        self.selectionHead = selectionHead
        self.findMatchesByRow = findMatchesByRow
        self.activeFindRow = activeFindRow
        self.activeFindRange = activeFindRange
        self.hoveredRow = hoveredRow
        self.hoveredRange = hoveredRange
        self.cursorBlinkEnabled = cursorBlinkEnabled
        self.cursorBlinkVisible = cursorBlinkVisible
    }
}

/// The seam between `HaliteSurfaceView` (input/IME/selection owner) and the
/// mechanism that actually draws the grid and owns scroll geometry. The legacy
/// `NSTextView` path and the upcoming Metal path both conform; the host swaps
/// between them behind a toggle without changing its public API.
///
/// The host stays the source of truth for: keyboard/IME/mouse input, the render
/// dedupe key, the follow-bottom/anchor *policy*, and the single shared
/// `CellMetrics`. A backend is responsible for: drawing (`render`), scroll
/// primitives, and host↔cell geometry (so IME `firstRect` and mouse hit-testing
/// work against whatever surface is live).
public protocol TerminalRenderBackend: AnyObject {
    /// The view inserted into `HaliteSurfaceView` that hosts this backend's
    /// content (the `NSScrollView` for legacy, a `CAMetalLayer`-backed view for
    /// Metal). The host frames it to its bounds.
    var contentView: NSView { get }

    /// Fired on any scroll-geometry change (programmatic or user). The host
    /// repositions the cursor overlay. (Legacy: clipView `boundsDidChange`.)
    var onScrollGeometryChanged: (() -> Void)? { get set }
    /// Fired only on user-initiated scroll. The host re-evaluates follow-bottom.
    /// (Legacy: `didLiveScrollNotification`.)
    var onUserScroll: (() -> Void)? { get set }

    /// The font the backend currently lays out with (config font × zoom). The
    /// host derives the shared `CellMetrics` from this so metrics and rendering
    /// never disagree.
    var renderFont: NSFont { get }

    /// Visible content area + content inset, so the host derives the same usable
    /// width/height (→ cols/rows) regardless of which backend is live.
    var contentSize: NSSize { get }
    var contentInset: NSSize { get }

    /// React to a font/color/theme/scrollback config change.
    func applyConfig(_ config: HaliteConfig)

    /// Replace the render font directly (font zoom — same family, scaled size).
    func setRenderFont(_ font: NSFont)

    /// Draw the grid + overlays described by `state`. The host has already run
    /// its dedupe; this unconditionally produces the frame. Does NOT apply
    /// follow/anchor scroll — the host orchestrates that via the scroll
    /// primitives below using its own policy flags.
    func render(grid: Grid, config: HaliteConfig, state: RenderState, metrics: CellMetrics)

    /// Geometry of the underline/bar cursor overlay, in `contentView`-relative
    /// (== host) coordinates, or `nil` when it should be hidden (block cursor,
    /// invisible, IME-composing, blink-off, or scrolled out of view). The host
    /// owns the overlay layer and positions it from this — keeping the layer on
    /// a coordinate basis the math was written for. (A Metal backend that draws
    /// the cursor inside its own frame returns `nil`.)
    func cursorOverlay(grid: Grid, config: HaliteConfig, state: RenderState, metrics: CellMetrics) -> CursorOverlay?

    // MARK: Geometry (host coordinate space)

    /// Map a point in `HaliteSurfaceView` coordinates to a unified (row, col),
    /// clamped to grid bounds. Backs mouse hit-testing and hover.
    func cell(at pointInHost: NSPoint, grid: Grid, metrics: CellMetrics) -> GridPos

    /// Screen-space rect of the cursor cell, for IME candidate-window placement
    /// (`NSTextInputClient.firstRect`).
    func cursorScreenRect(grid: Grid, metrics: CellMetrics, window: NSWindow) -> NSRect

    // MARK: Scroll primitives

    /// Current vertical scroll offset in content pixels (0 = top).
    var scrollYPixels: CGFloat { get }
    /// Scroll to a content-pixel offset; `animated` drives the smooth snap.
    func setScrollY(_ y: CGFloat, animated: Bool)
    /// Total laid-out content height in pixels.
    var contentHeight: CGFloat { get }
    /// Visible viewport height in pixels.
    var viewportHeight: CGFloat { get }
    /// Force synchronous layout so heights/offsets are current before measuring.
    func ensureLayout()
    /// Flush a programmatic scroll change to the on-screen scroller.
    func reflectScroll()
}
