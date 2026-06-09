import AppKit

/// 시스템에 설치된 monospace 폰트 가족 목록을 enumerate하고, halite의 기본 폰트
/// 선택 정책을 적용.
///
/// Nerd Font가 설치돼 있으면 우선 사용 (Starship/Powerlevel10k의 powerline 글리프가
/// 깨지지 않음). 없으면 Menlo로 폴백.
enum FontDiscovery {
    /// 터미널에 쓸 만한(고정폭) 폰트 가족 (sorted alphabetically).
    ///
    /// `NSFont.isFixedPitch`만 보면 **한글/CJK 병합 폰트가 빠진다**: 반각 Latin +
    /// 전각 한글의 두 advance 폭(dual-width)을 가져 시스템이 monospace 플래그를
    /// false로 달기 때문(예: JetBrainsMonoHangul, D2Coding, NanumGothicCoding).
    /// 이런 폰트야말로 한국 개발자가 원하는 것이므로, 플래그가 없어도 **Latin
    /// advance가 균일하면**(한글이 2배 폭인 건 터미널이 wide-cell로 처리) 포함한다.
    static func allMonospaceFamilies() -> [String] {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies
            .filter { family in
                guard let font = NSFont(name: family, size: 12) else { return false }
                return font.isFixedPitch || isLatinMonospaced(family)
            }
            .sorted()
    }

    /// 대표 ASCII 글자들의 advance가 균일하면 true. `isFixedPitch` 플래그가 false인
    /// dual-width(Latin+한글) 폰트를 터미널용으로 인정하기 위함. 비례 폰트
    /// (Helvetica 등)는 좁은/넓은 글자 advance가 달라 걸러진다.
    private static func isLatinMonospaced(_ family: String) -> Bool {
        guard let font = NSFont(name: family, size: 100) else { return false }
        let ct = font as CTFont
        // narrow(i,l,.) + wide-ink(M,W,@,m) ASCII를 섞어 비례 폰트와 확실히 구분.
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
        return hi - lo < 0.5   // 100pt에서 0.5pt 미만 편차 = 균일폭
    }

    /// Nerd Font (이름에 "Nerd Font", "NF", "NFM" 포함)만.
    static func nerdFontFamilies() -> [String] {
        allMonospaceFamilies().filter { isNerdFont($0) }
    }

    /// Nerd Font가 아닌 monospaced 폰트들.
    static func regularMonospaceFamilies() -> [String] {
        allMonospaceFamilies().filter { !isNerdFont($0) }
    }

    static func isNerdFont(_ family: String) -> Bool {
        let lower = family.lowercased()
        return lower.contains("nerd font")
            || lower.contains("nerd fon")  // 짧게 truncated 케이스
            || family.contains(" NF")
            || family.contains(" NFM")
            || family.contains(" NFP")
    }

    /// halite의 디폴트 폰트 가족 = **JetBrainsMono Nerd Font Mono** (NFM).
    ///
    /// Latin 글자는 NF와 100% 동일하면서, Nerd 아이콘을 **1셀 폭으로 축소**해 터미널
    /// cell-grid에 맞춘다. 비-Mono(NF)는 아이콘 잉크가 1셀을 넘어(예: U+F43A 클럭
    /// ink 0~1.67셀) Metal rasterizer의 1셀 박스에서 잘리므로 피한다. 한글/CJK는
    /// `cjkFallbackFont`(D2Coding 계열)로 fallback — fallback 최소화. 없으면 NF → Menlo.
    static func defaultFamily() -> String {
        let preferred = [
            "JetBrainsMono Nerd Font Mono",  // NFM: Latin=NF 동일 + 아이콘 1셀 폭
            "JetBrainsMono Nerd Font",       // NF (아이콘 자연 폭) — 차선
        ]
        let installed = Set(NSFontManager.shared.availableFontFamilies)
        for family in preferred where installed.contains(family) {
            return family
        }
        return "Menlo"
    }

    /// Nerd Font의 "Mono" 변형 (글리프가 1셀 폭으로 강제). 터미널엔 보통 이게 정렬됨.
    private static func isMonoVariant(_ family: String) -> Bool {
        let lower = family.lowercased()
        return lower.contains("nerd font mono")
            || family.hasSuffix(" NFM")
            || family.contains(" NFM ")
    }
}
