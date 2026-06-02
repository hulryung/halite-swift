import AppKit
import XCTest
@testable import HaliteTerminal

/// Headless render-parity smoke: drive the real Metal pipeline to an offscreen
/// bitmap (no window, no Screen Recording) and write a PNG you can eyeball. The
/// grid is built with the same `applySGR` / `putChar` calls the VT parser would
/// make, so the image exercises color, attributes, CJK width, emoji, hyperlinks,
/// and the cursor exactly as on screen.
///
/// Output path: `$HALITE_SHOT` if set, else `/tmp/halite_parity.png`.
final class MetalRenderImageTests: XCTestCase {

    /// Replicates `HaliteTerminalView.measuredLineHeight` so the atlas cell box
    /// and grid geometry match on-screen rendering.
    private func measuredLineHeight(_ font: NSFont) -> CGFloat {
        let lm = NSLayoutManager()
        let storage = NSTextStorage(string: "M\nM\nM", attributes: [.font: font])
        storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 10000, height: 10000))
        lm.addTextContainer(container)
        lm.ensureLayout(for: container)
        return lm.usedRect(for: container).height / 3.0
    }

    private func put(_ grid: Grid, _ s: String) { for ch in s { grid.putChar(ch) } }

    func testRenderParitySheet() throws {
        guard MetalDevice.shared != nil else {
            throw XCTSkip("Metal device unavailable (headless CI)")
        }
        let config = HaliteConfig(fontFamily: "Menlo", fontSize: 14)
        guard let backend = MetalTerminalBackend(config: config) else {
            throw XCTSkip("Metal backend init failed")
        }

        let cols = 52, rows = 16
        let grid = Grid(cols: cols, rows: rows, pen: CellAttrs(fg: .default))

        // Row 0: ANSI 16 background swatches.
        grid.setCursor(row: 0, col: 0)
        for i in 0..<16 { grid.applySGR([48, 5, i]); put(grid, "  ") }
        grid.applySGR([0])

        // Row 1: 256-color cube gradient.
        grid.setCursor(row: 1, col: 0)
        for i in 0..<48 { grid.applySGR([48, 5, 16 + i * 4]); put(grid, " ") }
        grid.applySGR([0])

        // Row 2: truecolor ramp.
        grid.setCursor(row: 2, col: 0)
        for i in 0..<48 {
            let v = i * 5
            grid.applySGR([48, 2, v, 128, 255 - v]); put(grid, " ")
        }
        grid.applySGR([0])

        // Row 4: SGR attributes (italic is parsed but intentionally not drawn).
        grid.setCursor(row: 4, col: 0)
        grid.applySGR([1]); put(grid, "bold "); grid.applySGR([0])
        grid.applySGR([4]); put(grid, "underline "); grid.applySGR([0])
        grid.applySGR([9]); put(grid, "strike "); grid.applySGR([0])
        grid.applySGR([7]); put(grid, "reverse "); grid.applySGR([0])
        grid.applySGR([38, 2, 255, 140, 0]); put(grid, "fg-orange"); grid.applySGR([0])

        // Row 6: colored foreground words (ANSI 30–37 bright via bold).
        grid.setCursor(row: 6, col: 0)
        for i in 0..<8 { grid.applySGR([1, 30 + i]); put(grid, "Aa") }
        grid.applySGR([0])

        // Row 8: CJK / Hangul (each is 2 cells wide).
        grid.setCursor(row: 8, col: 0)
        put(grid, "CJK 한글 中文 日本語 ｜ 와이드 정렬")

        // Row 10: emoji (incl. ZWJ family + flag — wide & color).
        grid.setCursor(row: 10, col: 0)
        put(grid, "emoji 😀 🎉 🚀 ❤️ 👨‍👩‍👧‍👦 🇰🇷")

        // Row 12: hyperlink (OSC-8 → underline at fg α0.5).
        grid.setCursor(row: 12, col: 0)
        grid.setHyperlink("https://example.com")
        put(grid, "click-here")
        grid.setHyperlink(nil)
        put(grid, " plain")

        // Cursor on row 14 (block, drawn as inverse).
        grid.setCursor(row: 14, col: 0)
        put(grid, "cursor→")
        grid.setCursorVisible(true)

        let font = fontWithNerdFallback(family: config.fontFamily, size: config.fontSize)
        let metrics = CellMetrics(width: max(("M" as NSString)
            .size(withAttributes: [.font: font]).width, 1),
                                  height: max(measuredLineHeight(font), 1))
        var state = RenderState()
        state.hoveredRow = nil

        let scale: CGFloat = 2
        let image = backend.renderToCGImage(grid: grid, config: config, state: state,
                                             metrics: metrics, cols: cols, rows: rows, scale: scale)
        let cg = try XCTUnwrap(image, "renderToCGImage returned nil")

        // Sanity: not a blank frame. Count pixels differing from the bg color.
        let bg = config.theme.background.usingColorSpace(.sRGB)!
        let bgPixel = (UInt8(bg.blueComponent * 255), UInt8(bg.greenComponent * 255),
                       UInt8(bg.redComponent * 255))
        let rep = NSBitmapImageRep(cgImage: cg)
        var differing = 0
        let stepX = max(1, cg.width / 200), stepY = max(1, cg.height / 200)
        for y in stride(from: 0, to: cg.height, by: stepY) {
            for x in stride(from: 0, to: cg.width, by: stepX) {
                if let c = rep.colorAt(x: x, y: y) {
                    let r = UInt8((c.redComponent * 255).rounded())
                    let g = UInt8((c.greenComponent * 255).rounded())
                    let b = UInt8((c.blueComponent * 255).rounded())
                    if abs(Int(r) - Int(bgPixel.2)) > 8 || abs(Int(g) - Int(bgPixel.1)) > 8
                        || abs(Int(b) - Int(bgPixel.0)) > 8 { differing += 1 }
                }
            }
        }
        XCTAssertGreaterThan(differing, 100, "frame looks blank — pipeline drew nothing")

        // Write the PNG for visual inspection.
        let outPath = ProcessInfo.processInfo.environment["HALITE_SHOT"] ?? "/tmp/halite_parity.png"
        guard let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("PNG encode failed")
        }
        try png.write(to: URL(fileURLWithPath: outPath))
        print("HALITE_PARITY_PNG=\(outPath) (\(cg.width)x\(cg.height), \(differing) non-bg sample px)")
    }
}
