import AppKit
import CoreText

/// Rasterizes a single character into a grayscale coverage bitmap sized to the
/// full cell (1 cell wide, or 2 for wide/CJK), at the backing scale for retina
/// crispness.
///
/// **Fallback policy.** The configured base font draws everything it can. What it
/// lacks falls through, in order, to: (1) the pinned CJK face (`cjkFallbackFont`,
/// D2Coding family) — tried for ANY missing character, not just East-Asian, so
/// symbols that Korean coding fonts carry (circled digits ①–⑳ etc.) render
/// deterministically the same on every machine; (2) the system-recommended font
/// for that character (`CTFontCreateForString` — Apple Symbols, Hiragino, …).
/// Both fallback tiers scale the glyph down to fit the cell when its ink
/// overflows (ambiguous-width symbols like ④ drawn into a 1-cell box, which the
/// CJK face renders full-width). Glyph lookup is a direct per-font cmap query
/// (`CTFontGetGlyphsForCharacters`), which does NOT honor `NSFont.cascadeList`;
/// fallbacks are therefore resolved explicitly here. Only a character no installed
/// font can draw stays blank.
///
/// Rasterizing into the full cell (rather than a tight bbox) trades atlas space
/// for simplicity: the render quad is exactly the cell rect, no per-glyph
/// bearing math. Atlas growth/eviction is a later optimization.
final class GlyphRasterizer {
    private let font: NSFont
    private let boldFont: NSFont
    /// CJK-only fallback face (e.g. D2CodingLigature Nerd Font Mono); nil if none
    /// installed. Used solely for East-Asian glyphs the base font lacks.
    private let cjkFont: NSFont?
    private let boldCJKFont: NSFont?
    /// Color-emoji fallback face (Apple Color Emoji), sized to fit a cell.
    private let emojiFont: NSFont?
    private let cellW: CGFloat
    private let cellH: CGFloat
    private let scale: CGFloat
    /// Baseline distance from the cell's top, in points.
    private let baseline: CGFloat
    private let gray = CGColorSpaceCreateDeviceGray()
    private let rgb = CGColorSpaceCreateDeviceRGB()

    struct Bitmap {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        /// false = R8 coverage mask (modulated by fg); true = premultiplied BGRA
        /// color (emoji), drawn as-is ignoring fg.
        var isColor: Bool = false
    }

    init(font: NSFont, cellW: CGFloat, cellH: CGFloat, scale: CGFloat) {
        self.font = font
        self.boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let cjk = cjkFallbackFont(size: font.pointSize)
        self.cjkFont = cjk
        self.boldCJKFont = cjk.map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
        // Size the emoji face to fit the cell box (emoji glyphs are ~1em square).
        self.emojiFont = NSFont(name: "Apple Color Emoji", size: min(cellH, cellW * 2))
        self.cellW = cellW
        self.cellH = cellH
        self.scale = max(scale, 1)
        // Center the ascent+descent box vertically in the cell; baseline sits
        // ascent below the box top. Approximates NSTextView; pixel-tunable.
        let ascent = font.ascender
        let descent = -font.descender
        let topGap = max(0, (cellH - (ascent + descent)) / 2)
        self.baseline = (topGap + ascent).rounded()
    }

    /// Coverage bitmap (mask) or color bitmap for `ch`, or nil for blanks /
    /// unrenderable glyphs.
    ///
    /// Tiers: (1) emoji-presentation chars → Apple Color Emoji as a **color** BGRA
    /// bitmap; (2) base font mask; (3) pinned CJK face for anything the base
    /// lacks (Hangul, and symbols like ④ that coding fonts carry); (4) the
    /// system-recommended font, fit-scaled into the cell. See the type doc.
    func raster(_ ch: Character, bold: Bool, wide: Bool) -> Bitmap? {
        if ch == " " || ch == "\u{00A0}" { return nil }
        // Emoji first: emoji-presentation chars (incl. VS16 / ZWJ sequences) render
        // in colour, not as a base-font monochrome glyph.
        if Cell.isEmojiPresentation(ch), let bmp = drawColor(ch, wide: wide) {
            return bmp
        }
        if let bmp = draw(ch, in: bold ? boldFont : font, wide: wide) {
            return bmp
        }
        // Pinned fallback face — deterministic across machines. Its metrics don't
        // match the base cell, so overflowing ink (full-width ① in a 1-cell
        // ambiguous-width box) is shrink-to-fit instead of clipped.
        if let cjk = bold ? boldCJKFont : cjkFont,
           let bmp = draw(ch, in: cjk, wide: wide, fitOverflow: true) {
            return bmp
        }
        // System fallback: whatever CoreText recommends for this character.
        return drawSystemFallback(ch, bold: bold, wide: wide)
    }

    /// Tier-4 fallback: ask CoreText which installed font covers `ch`
    /// (`CTFontCreateForString`) and rasterize with it, scaled down to fit the
    /// cell box if the glyph ink overflows (e.g. full-square ④ in a 1-cell box).
    /// nil when even the system has no coverage — genuine tofu.
    private func drawSystemFallback(_ ch: Character, bold: Bool, wide: Bool) -> Bitmap? {
        let str = String(ch)
        let base = (bold ? boldFont : font) as CTFont
        let resolved = CTFontCreateForString(base, str as CFString,
                                             CFRange(location: 0, length: str.utf16.count))
        // Same face as the base → its cmap already failed in draw(); nothing new.
        if CFEqual(resolved, base) { return nil }
        var f = resolved as NSFont
        if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        return drawFitted(ch, in: f, wide: wide)
    }

    /// Rasterize via CTLine with shrink-to-fit (never upscaled): used for system-
    /// fallback glyphs whose metrics don\'t match the monospace cell.
    private func drawFitted(_ ch: Character, in f: NSFont, wide: Bool) -> Bitmap? {
        let glyphCellW = wide ? cellW * 2 : cellW
        let pw = Int(ceil(glyphCellW * scale))
        let ph = Int(ceil(cellH * scale))
        guard pw > 0, ph > 0 else { return nil }

        // CTLineDraw ignores the context fill color unless told otherwise — the
        // default foreground is BLACK, invisible on the zeroed coverage bitmap.
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: String(ch), attributes: [
                .font: f,
                kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
            ]))

        var data = [UInt8](repeating: 0, count: pw * ph)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8,
                bytesPerRow: pw, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldSmoothFonts(false)
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))   // white = full coverage

            let ib = CTLineGetImageBounds(line, ctx)
            guard ib.width > 0, ib.height > 0 else { return false }
            // Shrink-to-fit only (cap 1): center the ink in the cell box. The fit
            // box is inset two device pixels per side: one absorbs glyph-origin
            // pixel snapping (CoreText can shift the rendered outline up to ~1px
            // from the CTLineGetImageBounds prediction), one stays a real seam so
            // a box-filling glyph (full-width ① squeezed into a 1-cell ambiguous-
            // width slot) never abuts neighboring cells' ink flush.
            let inset = 2 / scale
            let boxW = glyphCellW - inset * 2, boxH = cellH - inset * 2
            guard boxW > 0, boxH > 0 else { return false }
            let fit = min(1, min(boxW / ib.width, boxH / ib.height))
            let drawnW = ib.width * fit, drawnH = ib.height * fit
            ctx.translateBy(x: (glyphCellW - drawnW) / 2 - fit * ib.minX,
                            y: (cellH - drawnH) / 2 - fit * ib.minY)
            ctx.scaleBy(x: fit, y: fit)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            return true
        }
        guard ok, data.contains(where: { $0 != 0 }) else { return nil }
        return Bitmap(bytes: data, width: pw, height: ph)
    }

    /// Rasterize a color-emoji grapheme via CoreText (CTLine shapes ZWJ/flag/
    /// skin-tone sequences and renders the colour tables) into a premultiplied
    /// BGRA bitmap, centred in the cell box. nil if no emoji face or empty result.
    private func drawColor(_ ch: Character, wide: Bool) -> Bitmap? {
        guard let emojiFont else { return nil }
        let glyphCellW = wide ? cellW * 2 : cellW
        let pw = Int(ceil(glyphCellW * scale))
        let ph = Int(ceil(cellH * scale))
        guard pw > 0, ph > 0 else { return nil }

        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: String(ch), attributes: [.font: emojiFont]))

        // BGRA premultiplied — matches the Metal .bgra8Unorm color atlas and the
        // colour pipeline's premultiplied (.one) blend. Keep these two in sync.
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        var data = [UInt8](repeating: 0, count: pw * ph * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8,
                bytesPerRow: pw * 4, space: rgb, bitmapInfo: info
            ) else { return false }
            ctx.setShouldAntialias(true)
            ctx.scaleBy(x: scale, y: scale)   // work in points; cell box = glyphCellW × cellH

            // Fit the emoji's actual INK box into the cell (emoji ink overflows the
            // em box, so typographic bounds would clip top/right). Scale to fit and
            // centre using the real image bounds.
            let ib = CTLineGetImageBounds(line, ctx)
            guard ib.width > 0, ib.height > 0 else { return false }
            let fit = min(glyphCellW / ib.width, cellH / ib.height)
            let drawnW = ib.width * fit, drawnH = ib.height * fit
            ctx.translateBy(x: (glyphCellW - drawnW) / 2 - fit * ib.minX,
                            y: (cellH - drawnH) / 2 - fit * ib.minY)
            ctx.scaleBy(x: fit, y: fit)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            return true
        }
        guard ok, data.contains(where: { $0 != 0 }) else { return nil }
        return Bitmap(bytes: data, width: pw, height: ph, isColor: true)
    }

    /// The base / bold rendering face, exposed so `LineShaper` shapes ligature
    /// runs with the exact same font the atlas rasterizes them from.
    func face(bold: Bool) -> NSFont { bold ? boldFont : font }

    /// Horizontal padding (in cells) added on each side of a shaped-glyph bitmap,
    /// so a connecting ligature form whose ink overflows its cell isn't clipped.
    /// The renderer offsets the quad left by this much (see `ligaturePadPts`).
    static let ligaturePadCells = 1

    /// Rasterize a single, already-shaped `CGGlyph` (from `LineShaper`) into an R8
    /// coverage bitmap. The glyph's pen origin sits one cell in from the left
    /// (`ligaturePadCells`) so contextual connecting forms (Fira Code's "=", "-",
    /// arrow halves) can extend past their cell into the padding instead of being
    /// clipped — the renderer shifts the quad back by the same pad so the ink
    /// lands exactly where CoreText placed it. `bold` must match the shaping font.
    func rasterGlyph(_ glyph: CGGlyph, bold: Bool, cellSpan: Int) -> Bitmap? {
        let ctFont = (bold ? boldFont : font) as CTFont
        let pad = CGFloat(Self.ligaturePadCells) * cellW
        let boxW = cellW * CGFloat(max(cellSpan, 1)) + pad * 2
        let pw = Int(ceil(boxW * scale))
        let ph = Int(ceil(cellH * scale))
        guard pw > 0, ph > 0 else { return nil }

        var data = [UInt8](repeating: 0, count: pw * ph)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8,
                bytesPerRow: pw, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldSmoothFonts(false)
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            var g = glyph
            var pos = CGPoint(x: pad, y: cellH - baseline)
            CTFontDrawGlyphs(ctFont, &g, &pos, 1, ctx)
            return true
        }
        guard ok, data.contains(where: { $0 != 0 }) else { return nil }
        return Bitmap(bytes: data, width: pw, height: ph)
    }

    /// Rasterize `ch` with `f`, or nil if `f`'s own cmap lacks the glyph (a direct
    /// per-font query — `NSFont.cascadeList` is intentionally not consulted).
    ///
    /// `fitOverflow` (fallback faces only): when the natural pen layout's ink
    /// would overflow the cell box horizontally — e.g. D2Coding draws East-Asian-
    /// Ambiguous circled digits (①…⑳) full-width but the grid gives them 1 cell —
    /// reroute through `drawFitted` so the glyph is shrunk and centered instead of
    /// hard-clipped at the bitmap edge. The base font is monospace and lays out at
    /// x=0 by design, so tier 2 keeps the cheap unfitted path.
    private func draw(_ ch: Character, in f: NSFont, wide: Bool,
                      fitOverflow: Bool = false) -> Bitmap? {
        let ctFont = f as CTFont

        // Normalize to precomposed (NFC). The terminal can receive decomposed
        // Hangul (NFD Jamo) — e.g. syllables with a final consonant (batchim) arrive
        // as lead + vowel + final Jamo — and a per-glyph cmap lookup can't compose
        // Jamo, so it would draw 2–3 separate Jamo or, lacking a final-consonant
        // glyph, render nothing. Composing to the single precomposed syllable
        // (U+AC00…D7A3) draws one correct glyph, matching the legacy
        // CTLine/NSAttributedString path.
        let utf16 = Array(String(ch).precomposedStringWithCanonicalMapping.utf16)
        guard !utf16.isEmpty else { return nil }
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let hasAll = utf16.withUnsafeBufferPointer { buf in
            CTFontGetGlyphsForCharacters(ctFont, buf.baseAddress!, &glyphs, utf16.count)
        }
        guard hasAll else { return nil }   // this font lacks the glyph

        let glyphCellW = wide ? cellW * 2 : cellW
        let pw = Int(ceil(glyphCellW * scale))
        let ph = Int(ceil(cellH * scale))
        guard pw > 0, ph > 0 else { return nil }

        // Position each glyph at the baseline (y-up: cellH − baseline from
        // bottom), accumulating advances for multi-glyph clusters.
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, glyphs.count)
        var positions = [CGPoint](repeating: .zero, count: glyphs.count)
        var penX: CGFloat = 0
        for i in glyphs.indices {
            positions[i] = CGPoint(x: penX, y: cellH - baseline)
            penX += advances[i].width
        }

        if fitOverflow {
            // Ink bounds under the pen layout; anything outside [0, glyphCellW]
            // would be silently clipped by the CGContext bitmap below.
            var boxes = [CGRect](repeating: .zero, count: glyphs.count)
            CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, glyphs, &boxes, glyphs.count)
            var inkMinX = CGFloat.greatestFiniteMagnitude
            var inkMaxX = -CGFloat.greatestFiniteMagnitude
            for i in glyphs.indices where !boxes[i].isNull && boxes[i].width > 0 {
                inkMinX = min(inkMinX, positions[i].x + boxes[i].minX)
                inkMaxX = max(inkMaxX, positions[i].x + boxes[i].maxX)
            }
            // 0.5pt slack: antialiasing fringe / rounding, not real overflow.
            if inkMaxX > inkMinX, inkMinX < -0.5 || inkMaxX > glyphCellW + 0.5 {
                return drawFitted(ch, in: f, wide: wide)
            }
        }

        var data = [UInt8](repeating: 0, count: pw * ph)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: pw, height: ph, bitsPerComponent: 8,
                bytesPerRow: pw, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldSmoothFonts(false)   // grayscale coverage, not subpixel
            ctx.scaleBy(x: scale, y: scale)   // work in points
            ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))   // white = full coverage
            CTFontDrawGlyphs(ctFont, glyphs, positions, glyphs.count, ctx)
            return true
        }
        guard ok else { return nil }
        if !data.contains(where: { $0 != 0 }) { return nil }
        return Bitmap(bytes: data, width: pw, height: ph)
    }
}
