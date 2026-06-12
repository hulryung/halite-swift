import XCTest
import AppKit
@testable import DamsonTerminal

/// Verifies the Metal glyph path's fallback policy: the base font draws what it
/// can; what it lacks falls through to the pinned CJK face, then to the
/// system-recommended font for that character. Wide glyphs render at full
/// double-width, and both fallback tiers shrink-to-fit when a glyph's ink
/// overflows its cell box (see the doc comment atop GlyphRasterizer.swift).
final class GlyphFallbackTests: XCTestCase {

    private func font(_ name: String, _ size: CGFloat) -> NSFont? { NSFont(name: name, size: size) }

    /// Rightmost column index that has any coverage, or -1 if the bitmap is blank.
    private func maxInkX(_ bmp: GlyphRasterizer.Bitmap) -> Int {
        var maxX = -1
        for y in 0..<bmp.height {
            let row = y * bmp.width
            for x in 0..<bmp.width where bmp.bytes[row + x] != 0 {
                if x > maxX { maxX = x }
            }
        }
        return maxX
    }

    func testBaseFontDrawsASCII() throws {
        let size: CGFloat = 17
        guard let base = font("JetBrainsMono Nerd Font", size) else {
            throw XCTSkip("JetBrainsMono Nerd Font not installed")
        }
        let cellW = ("M" as NSString).size(withAttributes: [.font: base]).width
        let r = GlyphRasterizer(font: base, cellW: cellW, cellH: cellW * 2, scale: 2)
        XCTAssertNotNil(r.raster("A", bold: false, wide: false), "base font must draw ASCII 'A'")
    }

    func testCJKFallsBackFromBaseLackingHangul() throws {
        let size: CGFloat = 17
        guard let base = font("JetBrainsMono Nerd Font", size) else {
            throw XCTSkip("JetBrainsMono Nerd Font not installed")
        }
        // Precondition: the base font genuinely lacks Hangul (so this exercises fallback).
        let ct = base as CTFont
        var g = [CGGlyph](repeating: 0, count: 1)
        let baseHasHangul = Array("한".utf16).withUnsafeBufferPointer {
            CTFontGetGlyphsForCharacters(ct, $0.baseAddress!, &g, 1)
        }
        try XCTSkipIf(baseHasHangul, "base font unexpectedly has Hangul; fallback not exercised")
        try XCTSkipIf(cjkFallbackFont(size: size) == nil, "no CJK fallback font installed")

        let cellW = ("M" as NSString).size(withAttributes: [.font: base]).width
        let r = GlyphRasterizer(font: base, cellW: cellW, cellH: cellW * 2, scale: 2)

        let han = try XCTUnwrap(r.raster("한", bold: false, wide: true),
                                "Hangul must render via CJK fallback, not tofu")

        // The glyph must occupy ~2 cells: ink should extend past the horizontal
        // midpoint of the 2-cell bitmap. A "Nerd Font Mono" CJK face squishes
        // Hangul to one cell (ink stays in the left half) — guard against that.
        let mid = han.width / 2
        XCTAssertGreaterThan(maxInkX(han), mid,
            "Hangul ink must reach the right cell (got maxX=\(maxInkX(han)), width=\(han.width)); " +
            "a half-width 'Mono' CJK face would fail this")
    }

    /// The default base font must use a "Mono" Nerd variant whose icon ink fits
    /// within one cell — non-Mono (NF) icons overflow the cell (e.g. U+F43A clock
    /// ink spans ~1.67 cells) and get clipped by the per-cell Metal rasterizer.
    func testNerdIconInkFitsOneCell() throws {
        let size: CGFloat = 17
        guard let base = font("JetBrainsMono Nerd Font Mono", size) else {
            throw XCTSkip("JetBrainsMono Nerd Font Mono not installed")
        }
        let clock: Character = "\u{F43A}"
        let ct = base as CTFont
        var g = [CGGlyph](repeating: 0, count: 1)
        let present = Array(String(clock).utf16).withUnsafeBufferPointer {
            CTFontGetGlyphsForCharacters(ct, $0.baseAddress!, &g, 1)
        }
        try XCTSkipIf(!present, "base font lacks the clock glyph")
        var box = [CGRect](repeating: .zero, count: 1)
        CTFontGetBoundingRectsForGlyphs(ct, .horizontal, g, &box, 1)
        let cellW = ("M" as NSString).size(withAttributes: [.font: base]).width
        XCTAssertLessThanOrEqual(box[0].width, cellW + 0.5,
            "Nerd icon ink (\(box[0].width)) must fit one cell (\(cellW)); a non-Mono variant would overflow and clip")
    }

    /// Mirror the running app exactly: base = FontDiscovery.defaultFamily() (NFM)
    /// wrapped by fontWithNerdFallback (carries a cascadeList). The cascadeList must
    /// NOT make CTFontGetGlyphsForCharacters claim Hangul on the base (it doesn't),
    /// and the explicit CJK fallback must still fire.
    func testAppDefaultFontPathRendersHangul() throws {
        let size: CGFloat = 17
        let family = "JetBrainsMono Nerd Font Mono"   // == defaultFamily() on this machine
        guard NSFont(name: family, size: size) != nil else { throw XCTSkip("NFM not installed") }
        try XCTSkipIf(cjkFallbackFont(size: size) == nil, "no CJK fallback font installed")
        let renderFont = fontWithNerdFallback(family: family, size: size)
        let cellW = ("M" as NSString).size(withAttributes: [.font: renderFont]).width
        let r = GlyphRasterizer(font: renderFont, cellW: cellW, cellH: cellW * 2, scale: 2)
        let han = try XCTUnwrap(r.raster("한", bold: false, wide: true),
            "app's default font (NFM + cascade) must render Hangul via CJK fallback")
        XCTAssertGreaterThan(maxInkX(han), han.width / 2, "Hangul must fill 2 cells, not squish")
    }

    /// Regression: decomposed (NFD) Hangul must render. The terminal can receive
    /// Hangul as Jamo — notably syllables with a final consonant (jongseong) arrive
    /// as leading + medial + trailing Jamo — and the per-glyph cmap path can't
    /// compose Jamo (it drew nothing, so syllables with a final consonant like
    /// 한/글 went blank). draw() normalizes to NFC first; this asserts decomposed
    /// syllables now rasterize at full 2-cell width.
    func testDecomposedHangulRendersViaNFC() throws {
        let family = "JetBrainsMono Nerd Font Mono"
        guard NSFont(name: family, size: 17) != nil, cjkFallbackFont(size: 17) != nil else {
            throw XCTSkip("fonts not installed")
        }
        let renderFont = fontWithNerdFallback(family: family, size: 17)
        let cellW = ("M" as NSString).size(withAttributes: [.font: renderFont]).width
        let r = GlyphRasterizer(font: renderFont, cellW: cellW, cellH: cellW * 2, scale: 2)
        // "한글" decomposed → both syllables carry a final consonant (jongseong).
        let nfd = "한글".decomposedStringWithCanonicalMapping
        for ch in nfd {
            XCTAssertGreaterThan(ch.unicodeScalars.count, 1, "precondition: '\(ch)' must be decomposed Jamo")
            let bmp = try XCTUnwrap(r.raster(ch, bold: false, wide: true),
                "decomposed Hangul \(Array(ch.unicodeScalars)) must render (NFC normalization)")
            XCTAssertGreaterThan(maxInkX(bmp), bmp.width / 2, "must fill 2 cells")
        }
    }

    /// Emoji rasterize to the COLOR page (premultiplied BGRA) with actual chroma —
    /// not a monochrome silhouette on the mask page.
    func testEmojiRastersAsColor() throws {
        guard NSFont(name: "Apple Color Emoji", size: 17) != nil else { throw XCTSkip("no emoji font") }
        let base = NSFont(name: "JetBrainsMono Nerd Font Mono", size: 17) ?? NSFont(name: "Menlo", size: 17)!
        let cellW = ("M" as NSString).size(withAttributes: [.font: base]).width
        let r = GlyphRasterizer(font: base, cellW: cellW, cellH: cellW * 2, scale: 2)
        let bmp = try XCTUnwrap(r.raster("😀", bold: false, wide: true), "emoji must rasterize")
        XCTAssertTrue(bmp.isColor, "emoji uses the BGRA color page")
        // BGRA premultiplied: a colored pixel has B (i) != R (i+2) somewhere.
        var hasChroma = false
        var i = 0
        while i + 3 < bmp.bytes.count {
            if bmp.bytes[i + 3] > 0 && bmp.bytes[i] != bmp.bytes[i + 2] { hasChroma = true; break }
            i += 4
        }
        XCTAssertTrue(hasChroma, "emoji bitmap must contain color, not be monochrome")
    }

    func testNonCJKMissingGlyphStaysBlank() throws {
        let size: CGFloat = 17
        guard let base = font("JetBrainsMono Nerd Font", size) else {
            throw XCTSkip("JetBrainsMono Nerd Font not installed")
        }
        // U+2C00 (Glagolitic) is non-CJK and absent from JetBrains Mono; with the
        // minimal policy it must NOT fall back → blank.
        let ch: Character = "\u{2C00}"
        let ct = base as CTFont
        var g = [CGGlyph](repeating: 0, count: 1)
        let present = Array(String(ch).utf16).withUnsafeBufferPointer {
            CTFontGetGlyphsForCharacters(ct, $0.baseAddress!, &g, 1)
        }
        try XCTSkipIf(present, "base font has the test glyph; cannot assert no-fallback")
        let cellW = ("M" as NSString).size(withAttributes: [.font: base]).width
        let r = GlyphRasterizer(font: base, cellW: cellW, cellH: cellW * 2, scale: 2)
        XCTAssertNil(r.raster(ch, bold: false, wide: false),
                     "non-CJK missing glyph must stay blank (minimal fallback)")
    }
}

// MARK: - Symbol fallback (circled digits etc. — field report: ④ rendered blank)

extension GlyphFallbackTests {
    /// Characters most monospace coding fonts lack must still render via the
    /// pinned-CJK or system fallback tiers — never blank.
    func testSymbolsRenderViaFallbackTiers() throws {
        let size: CGFloat = 17
        let base = NSFont(name: "Menlo", size: size) ?? NSFont.systemFont(ofSize: size)
        let cellW = ("M" as NSString).size(withAttributes: [.font: base]).width
        let r = GlyphRasterizer(font: base, cellW: cellW, cellH: cellW * 2, scale: 2)

        for ch in ["④", "⑩", "⑳", "①", "☆", "※"] as [Character] {
            let bmp = r.raster(ch, bold: false, wide: Cell.isWide(ch))
            XCTAssertNotNil(bmp, "\(ch) must render through a fallback tier, not blank")
            if let bmp {
                XCTAssertTrue(bmp.bytes.contains { $0 != 0 }, "\(ch) bitmap must have ink")
            }
        }
    }

    /// The fallback glyph must be CONTAINED in its cell (shrink-to-fit) — a
    /// full-square ④ from a CJK face must not spill into the neighbor cell.
    func testFallbackSymbolFitsCell() throws {
        let size: CGFloat = 17
        let base = NSFont(name: "Menlo", size: size) ?? NSFont.systemFont(ofSize: size)
        let cellW = ("M" as NSString).size(withAttributes: [.font: base]).width
        let r = GlyphRasterizer(font: base, cellW: cellW, cellH: cellW * 2, scale: 2)

        let wide = Cell.isWide("④")
        guard let bmp = r.raster("④", bold: false, wide: wide) else {
            return XCTFail("④ did not render")
        }
        // Bitmap is exactly the cell box (1 or 2 cells) — ink reaching the bitmap
        // is by construction inside the cell; just sanity-check dimensions.
        let expectedW = Int(ceil((wide ? cellW * 2 : cellW) * 2 /* scale */))
        XCTAssertEqual(bmp.width, expectedW, "bitmap must be exactly the cell box")
        // Ink must also exist in the horizontal center region (a clipped-off glyph
        // would leave only edge artifacts).
        var centerInk = false
        let cx0 = bmp.width / 4, cx1 = bmp.width * 3 / 4
        for y in 0..<bmp.height {
            let row = y * bmp.width
            for x in cx0..<cx1 where bmp.bytes[row + x] != 0 { centerInk = true; break }
            if centerInk { break }
        }
        XCTAssertTrue(centerInk, "④ ink must occupy the cell center, not just edges")
    }

    /// Regression: ①/②/④ used to render half-clipped. East-Asian-Ambiguous
    /// circled digits get a 1-cell box (Cell.isWide=false), but the pinned CJK
    /// face draws them with a full-width (~2-cell) advance — tier 3 went through
    /// the unfitted draw() path, so ink overflowed the bitmap and was hard-clipped
    /// at the right edge. A correctly shrink-to-fit-centered glyph has (a) a
    /// margin on both sides (ink never flush with the bitmap edge) and (b) near-
    /// symmetric left/right ink mass (circled digits are circle-dominated).
    /// Non-Mono Nerd Font variants ("Nerd Font" / "Nerd Font Propo") give icons
    /// a wider-than-cell advance while the grid assigns them 1 cell — without
    /// overflow fitting the right half is hard-clipped at the bitmap edge.
    /// Field report: powerline prompts rendered half-hidden in Propo variants.
    func testWideNerdIconFitsCellInNonMonoVariant() throws {
        let size: CGFloat = 17
        guard let base = font("Terminess Nerd Font Propo", size) else {
            throw XCTSkip("Terminess Nerd Font Propo not installed")
        }
        let cellW = ("M" as NSString).size(withAttributes: [.font: base]).width
        let r = GlyphRasterizer(font: base, cellW: cellW, cellH: cellW * 2, scale: 2)
        // Gear / database / git branch — common prompt icons, all 1-cell in the grid.
        for ch in ["\u{F013}", "\u{F1C0}", "\u{E725}"] as [Character] {
            let bmp = try XCTUnwrap(r.raster(ch, bold: false, wide: Cell.isWide(ch)),
                                    "\(ch) must render")
            var minX = bmp.width, maxX = -1
            for y in 0..<bmp.height {
                let row = y * bmp.width
                for x in 0..<bmp.width where bmp.bytes[row + x] != 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
            }
            // Clipping pins the inked bbox to the right edge; the fitted path
            // keeps a margin and centers the bbox. (Mass symmetry is NOT
            // asserted — icons like the git branch are naturally lopsided.)
            XCTAssertLessThan(maxX, bmp.width - 1,
                "\(ch) ink flush with the RIGHT edge — icon clipped (w=\(bmp.width))")
            let center = Double(minX + maxX) / 2
            XCTAssertLessThan(abs(center - Double(bmp.width - 1) / 2), Double(bmp.width) * 0.2,
                "\(ch) inked bbox off-center (\(minX)…\(maxX) in w=\(bmp.width)) — likely clipped")
        }
    }

    /// Powerline separators (U+E0B0…) butt flush against neighboring cells; the
    /// fitted path must FILL the cell edge-to-edge (no inset seam) or segmented
    /// prompt bars show gaps.
    func testPowerlineFillsCellInNonMonoVariant() throws {
        let size: CGFloat = 17
        guard let base = font("Terminess Nerd Font Propo", size) else {
            throw XCTSkip("Terminess Nerd Font Propo not installed")
        }
        let cellW = ("M" as NSString).size(withAttributes: [.font: base]).width
        let r = GlyphRasterizer(font: base, cellW: cellW, cellH: cellW * 2, scale: 2)
        let arrow: Character = "\u{E0B0}"   // solid right-pointing separator
        let bmp = try XCTUnwrap(r.raster(arrow, bold: false, wide: Cell.isWide(arrow)))
        var minX = bmp.width, maxX = -1, minY = bmp.height, maxY = -1
        for y in 0..<bmp.height {
            let row = y * bmp.width
            for x in 0..<bmp.width where bmp.bytes[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        XCTAssertLessThanOrEqual(minX, 1, "powerline arrow must reach the left cell edge")
        XCTAssertGreaterThanOrEqual(maxX, bmp.width - 2,
            "powerline arrow must reach the right cell edge (no clipped apex / inset seam)")
        XCTAssertLessThanOrEqual(minY, 2, "powerline arrow must span the full cell height")
        XCTAssertGreaterThanOrEqual(maxY, bmp.height - 3,
            "powerline arrow must span the full cell height")
    }

    func testCircledDigitNotHorizontallyClipped() throws {
        let size: CGFloat = 17
        let base = NSFont(name: "Menlo", size: size) ?? NSFont.systemFont(ofSize: size)
        let cellW = ("M" as NSString).size(withAttributes: [.font: base]).width
        let r = GlyphRasterizer(font: base, cellW: cellW, cellH: cellW * 2, scale: 2)

        for ch in ["①", "②", "④"] as [Character] {
            let bmp = try XCTUnwrap(r.raster(ch, bold: false, wide: Cell.isWide(ch)),
                                    "\(ch) must render")
            var minX = bmp.width, maxX = -1
            var leftMass = 0, rightMass = 0
            for y in 0..<bmp.height {
                let row = y * bmp.width
                for x in 0..<bmp.width {
                    let v = Int(bmp.bytes[row + x])
                    guard v != 0 else { continue }
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if x < bmp.width / 2 { leftMass += v } else { rightMass += v }
                }
            }
            // (a) Fitted+centered ink never touches the bitmap edge.
            XCTAssertGreaterThan(minX, 0,
                "\(ch) ink flush with the LEFT edge — glyph not centered (w=\(bmp.width))")
            XCTAssertLessThan(maxX, bmp.width - 1,
                "\(ch) ink flush with the RIGHT edge — glyph clipped (w=\(bmp.width))")
            // (b) The circle dominates the ink: halves must be near-equal. A
            // complete render measures ≤ ~1.3 (pixel snapping at tiny sizes adds
            // some skew); the half-clipped bug measured 1.49 (①) to 1.82 (②).
            let hi = max(leftMass, rightMass), lo = max(min(leftMass, rightMass), 1)
            XCTAssertLessThan(Double(hi) / Double(lo), 1.4,
                "\(ch) ink mass asymmetric (L=\(leftMass) R=\(rightMass)) — half the glyph is missing")
        }
    }

    /// Bold variants of fallback symbols must render too (separate cache path).
    func testFallbackSymbolBold() throws {
        let size: CGFloat = 17
        let base = NSFont(name: "Menlo", size: size) ?? NSFont.systemFont(ofSize: size)
        let cellW = ("M" as NSString).size(withAttributes: [.font: base]).width
        let r = GlyphRasterizer(font: base, cellW: cellW, cellH: cellW * 2, scale: 2)
        XCTAssertNotNil(r.raster("④", bold: true, wide: Cell.isWide("④")))
    }
}
