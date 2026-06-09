import XCTest
import AppKit
@testable import DamsonTerminal

/// Verifies the Metal glyph path's minimal-fallback policy: the base font draws
/// what it can, and the *only* fallback is the CJK face for East-Asian glyphs the
/// base lacks — rendered at full double-width (not squished to one cell).
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
    /// Hangul as Jamo — notably syllables with a final consonant (받침) arrive as
    /// 초성+중성+종성 — and the per-glyph cmap path can't compose Jamo (it drew
    /// nothing, so 받침 syllables like 한/글 went blank). draw() normalizes to NFC
    /// first; this asserts decomposed syllables now rasterize at full 2-cell width.
    func testDecomposedHangulRendersViaNFC() throws {
        let family = "JetBrainsMono Nerd Font Mono"
        guard NSFont(name: family, size: 17) != nil, cjkFallbackFont(size: 17) != nil else {
            throw XCTSkip("fonts not installed")
        }
        let renderFont = fontWithNerdFallback(family: family, size: 17)
        let cellW = ("M" as NSString).size(withAttributes: [.font: renderFont]).width
        let r = GlyphRasterizer(font: renderFont, cellW: cellW, cellH: cellW * 2, scale: 2)
        // "한글" decomposed → both syllables carry a 받침 (final consonant).
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
