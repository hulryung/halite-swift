import AppKit
import CoreText

/// Shapes contiguous runs of base-font cells with CoreText so programming
/// ligatures (=>, !=, ->, ===, |>, …) render. CoreText applies the font's
/// OpenType `liga`/`calt` by default; in fonts like Fira Code most "ligatures"
/// are *contextual substitutions* — the glyph **count stays equal to the cell
/// count** but each glyph id changes to a connecting form (e.g. "=>" → glyphs
/// for the two halves of an arrow). So we return **every** shaped glyph, not just
/// many-to-one ones, and the renderer draws shaped glyph ids in place of the
/// per-char glyphs across the whole run.
///
/// Cell-alignment relies on the font being monospaced (Fira Code, JetBrains Mono,
/// D2CodingLigature, …): each glyph advances one cell, and a rare true many-to-one
/// ligature reports a multi-cell `cellSpan` via its source-index range.
/// Used only when `DamsonConfig.ligatures` is on.
struct LineShaper {
    /// A shaped glyph covering `cellSpan` cells (usually 1) from `startCol`.
    struct ShapedGlyph {
        let startCol: Int
        let cellSpan: Int
        let glyph: CGGlyph
        let bold: Bool
    }

    let baseFont: NSFont
    let boldFont: NSFont

    /// PostScript names of the faces we shape with, so a CoreText font
    /// substitution (a char the face lacks) is detected and skipped rather than
    /// emitting a ligature whose glyph id belongs to a different font.
    private let basePS: String
    private let boldPS: String

    init(baseFont: NSFont, boldFont: NSFont) {
        self.baseFont = baseFont
        self.boldFont = boldFont
        self.basePS = CTFontCopyPostScriptName(baseFont as CTFont) as String
        self.boldPS = CTFontCopyPostScriptName(boldFont as CTFont) as String
    }

    /// True if `cell` can join a base-font shaping run: a single UTF-16 unit,
    /// not a wide/CJK or emoji grapheme, not a wide-char continuation cell.
    private func shapable(_ cell: Cell) -> Bool {
        if cell.isContinuation { return false }
        if Cell.isWide(cell.char) || Cell.isEmojiPresentation(cell.char) { return false }
        return String(cell.char).utf16.count == 1
    }

    /// Shaped glyphs across the row's contiguous shapable runs (≥ 2 cells, so a
    /// ligature has neighbours to form against). Each entry replaces the per-char
    /// glyph of the cell(s) it covers.
    func shape(in cells: [Cell]) -> [ShapedGlyph] {
        var out: [ShapedGlyph] = []
        var i = 0
        while i < cells.count {
            guard shapable(cells[i]) else { i += 1; continue }
            let bold = cells[i].attrs.bold
            var j = i
            var chars: [Character] = []
            while j < cells.count, shapable(cells[j]), cells[j].attrs.bold == bold {
                chars.append(cells[j].char)
                j += 1
            }
            if chars.count >= 2 {
                shapeRun(String(chars), startCol: i, bold: bold, into: &out)
            }
            i = j
        }
        return out
    }

    private func shapeRun(_ string: String, startCol: Int, bold: Bool, into out: inout [ShapedGlyph]) {
        let font = bold ? boldFont : baseFont
        let expectedPS = bold ? boldPS : basePS
        let attr = NSAttributedString(string: string, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        let utf16Count = string.utf16.count
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }

        for run in runs {
            // Skip runs CoreText resolved to a substitute font — their glyph ids
            // don't belong to our base/bold face, so the per-char path draws them.
            if let attrs = CTRunGetAttributes(run) as? [CFString: Any],
               let runFont = attrs[kCTFontAttributeName] {
                let ps = CTFontCopyPostScriptName(runFont as! CTFont) as String
                if ps != expectedPS { continue }
            }
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var indices = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRangeMake(0, n), &glyphs)
            CTRunGetStringIndices(run, CFRangeMake(0, n), &indices)
            for k in 0..<n {
                let start = indices[k]
                let end = (k + 1 < n) ? indices[k + 1] : utf16Count
                let span = end - start
                // span == covered cell count (each run cell is one UTF-16 unit).
                // Emit every glyph: most are 1-cell contextual forms; a rare
                // many-to-one ligature spans >1. glyph 0 == .notdef, skip.
                guard span >= 1, start >= 0, start + span <= utf16Count, glyphs[k] != 0 else { continue }
                out.append(ShapedGlyph(startCol: startCol + start, cellSpan: span,
                                       glyph: glyphs[k], bold: bold))
            }
        }
    }
}
