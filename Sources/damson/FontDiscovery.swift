import AppKit

/// Enumerates the monospace font families installed on the system and applies
/// Damson's default-font selection policy.
///
/// If a Nerd Font is installed it is preferred (so Starship/Powerlevel10k powerline
/// glyphs don't break). Otherwise it falls back to Menlo.
enum FontDiscovery {
    /// Font families usable in a terminal (fixed-width), sorted alphabetically.
    ///
    /// Looking only at `NSFont.isFixedPitch` **drops Korean/CJK merged fonts**: they carry
    /// two advance widths (dual-width) — half-width Latin plus full-width Hangul — so the
    /// system sets their monospace flag to false (e.g. JetBrainsMonoHangul, D2Coding,
    /// NanumGothicCoding). These are exactly the fonts Korean developers want, so even
    /// without the flag we include them **as long as the Latin advances are uniform** (the
    /// 2x-width Hangul is handled by the terminal as wide cells).
    static func allMonospaceFamilies() -> [String] {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies
            .filter { family in
                guard let font = NSFont(name: family, size: 12) else { return false }
                return font.isFixedPitch || isLatinMonospaced(family)
            }
            .sorted()
    }

    /// True if the advances of representative ASCII characters are uniform. This lets us
    /// accept dual-width (Latin+Hangul) fonts whose `isFixedPitch` flag is false as terminal
    /// fonts. Proportional fonts (Helvetica, etc.) are filtered out because their narrow and
    /// wide characters have different advances.
    private static func isLatinMonospaced(_ family: String) -> Bool {
        guard let font = NSFont(name: family, size: 100) else { return false }
        let ct = font as CTFont
        // Mix narrow (i,l,.) and wide-ink (M,W,@,m) ASCII to reliably distinguish proportional fonts.
        var advances: [CGFloat] = []
        for scalar in "ilMW@m.".unicodeScalars {
            var unichars = Array(String(scalar).utf16)
            var glyph = CGGlyph(0)
            guard CTFontGetGlyphsForCharacters(ct, &unichars, &glyph, unichars.count),
                  glyph != 0 else { continue }
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &advance, 1)
            advances.append(advance.width)
        }
        guard advances.count >= 4, let lo = advances.min(), let hi = advances.max() else { return false }
        return hi - lo < 0.5   // less than 0.5pt deviation at 100pt = uniform width
    }

    /// Nerd Fonts only (name contains "Nerd Font", "NF", or "NFM").
    static func nerdFontFamilies() -> [String] {
        allMonospaceFamilies().filter { isNerdFont($0) }
    }

    /// Monospaced fonts that are not Nerd Fonts.
    static func regularMonospaceFamilies() -> [String] {
        allMonospaceFamilies().filter { !isNerdFont($0) }
    }

    static func isNerdFont(_ family: String) -> Bool {
        let lower = family.lowercased()
        return lower.contains("nerd font")
            || lower.contains("nerd fon")  // handles truncated cases
            || family.contains(" NF")
            || family.contains(" NFM")
            || family.contains(" NFP")
    }

    /// Damson's default font family = **JetBrainsMonoHangul Nerd Font Mono** (NFM).
    ///
    /// This merged face carries JetBrains Mono Latin, D2Coding Hangul, and the Nerd icon
    /// set in a single font, so Korean text and powerline glyphs render from one face with
    /// **no `cjkFallbackFont` round-trip** (the Hangul advances are already width-matched).
    /// If it isn't installed we fall back to plain JetBrainsMono NFM/NF (Latin only; Korean
    /// then comes from `cjkFallbackFont`, the D2Coding family). The Mono (NFM) variant is
    /// preferred over NF because NF icon ink exceeds one cell (e.g. the U+F43A clock spans
    /// 0–1.67 cells) and gets clipped by the Metal rasterizer's one-cell box.
    /// If none are present: Menlo.
    static func defaultFamily() -> String {
        let preferred = [
            "JetBrainsMonoHangul Nerd Font Mono",  // merged Latin + Hangul + icons, single face
            "JetBrainsMono Nerd Font Mono",        // NFM: Latin same as NF + icons one cell wide
            "JetBrainsMono Nerd Font",             // NF (natural icon width) — third choice
        ]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        for family in preferred where installed.contains(family) {
            return family
        }
        return "Menlo"
    }

    /// The "Mono" variant of a Nerd Font (glyphs forced to one cell wide). This is usually the one that aligns in a terminal.
    private static func isMonoVariant(_ family: String) -> Bool {
        let lower = family.lowercased()
        return lower.contains("nerd font mono")
            || family.hasSuffix(" NFM")
            || family.contains(" NFM ")
    }
}
