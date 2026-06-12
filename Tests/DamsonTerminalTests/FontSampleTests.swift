import AppKit
import XCTest
@testable import DamsonTerminal

/// Dev tooling: render a sample sheet for each font family in
/// `$DAMSON_FONT_FAMILIES` (comma-separated) through the real pipeline —
/// prompt-style lines with Nerd Font glyphs, box drawing, code, and Hangul
/// (exercises the fallback cascade for families that lack it). Skipped unless
/// the env var is set. Output: `$DAMSON_SHOT_DIR` (default /tmp).
final class FontSampleTests: XCTestCase {

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

    func testFontSampleSheets() throws {
        guard let families = ProcessInfo.processInfo.environment["DAMSON_FONT_FAMILIES"] else {
            throw XCTSkip("set DAMSON_FONT_FAMILIES=Fam1,Fam2 to render font sheets")
        }
        guard MetalDevice.shared != nil else { throw XCTSkip("Metal unavailable") }
        let dir = ProcessInfo.processInfo.environment["DAMSON_SHOT_DIR"] ?? "/tmp"
        let effectRaw = ProcessInfo.processInfo.environment["DAMSON_FONT_EFFECT"] ?? "none"
        let effect = ScreenEffect(rawValue: effectRaw) ?? .none

        for family in families.split(separator: ",").map(String.init) {
            let config = DamsonConfig(fontFamily: family, fontSize: 14,
                                      screenEffect: effect, screenEffectIntensity: 0.7)
            let backend = try XCTUnwrap(MetalTerminalBackend(config: config))
            backend.effectTimeOverride = 2.0
            let cols = 56, rows = 12
            let grid = Grid(cols: cols, rows: rows, pen: CellAttrs(fg: .default))
            let lines = [
                "\u{f179} \(family)",
                "\u{e0b0}\u{e0b1} dkkang \u{e725} main \u{f00c} \u{f013} \u{f120} \u{f1c0} \u{e718} \u{e791}",
                "$ ls -la | grep damson",
                "let glyph: Int = (0x21..<0x7f).count  // ASCII",
                "0123456789 OoIl1 {}[]()<> ~!@#$%^&*",
                "┌─────────┬─────────┐  ░░▒▒▓▓██",
                "│ ALPHA   │ BRAVO   │  ▁▂▃▄▅▆▇█",
                "└─────────┴─────────┘",
                "한글 폴백 테스트 — 가나다라 ④ ★",
            ]
            for (i, s) in lines.enumerated() where i < rows {
                grid.setCursor(row: i + 1, col: 1)
                if i == 0 { grid.applySGR([1, 32]) }
                put(grid, s)
                grid.applySGR([0])
            }
            grid.setCursorVisible(false)
            let font = fontWithNerdFallback(family: family, size: 14)
            let metrics = CellMetrics(
                width: max(("M" as NSString).size(withAttributes: [.font: font]).width, 1),
                height: max(measuredLineHeight(font), 1))
            let cg = try XCTUnwrap(backend.renderToCGImage(
                grid: grid, config: config, state: RenderState(),
                metrics: metrics, cols: cols, rows: rows, scale: 2))
            let slug = family.lowercased().replacingOccurrences(of: " ", with: "-")
            let rep = NSBitmapImageRep(cgImage: cg)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let path = "\(dir)/damson_font_\(slug).png"
            try png.write(to: URL(fileURLWithPath: path))
            print("DAMSON_FONT_SHEET=\(path)")
        }
    }
}
