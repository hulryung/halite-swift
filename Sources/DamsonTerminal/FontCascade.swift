import AppKit

/// 메인 폰트 + size로 NSFont를 만들되 cascadeList에 우선순위 순으로 fallback 추가:
///   1. 사용자 선택 폰트 (primary)
///   2. Nerd Font — Powerline glyph(PUA U+E0A0+)용
///      (primary가 이미 Nerd Font면 skip)
///   3. Apple SD Gothic Neo — 한글용
///      (macOS 시스템 fallback chain에 의존하지 않고 명시적으로 박아서 모든 환경에서
///       동일한 한글 폰트로 렌더되도록.)
///
/// macOS의 시스템 fallback chain은 언어 글리프(Hangul, Hanzi 등)는 자동 처리하지만
/// PUA 범위의 Powerline / Nerd Font 글리프는 fallback이 안 일어남. 또한 시스템이
/// 골라주는 Hangul 폰트는 macOS 버전마다 달라질 수 있어 line height 미세 차이가
/// 생길 수 있음 → 명시적으로 지정.
public func fontWithNerdFallback(family: String, size: CGFloat) -> NSFont {
    let primary = NSFont(name: family, size: size)
        ?? NSFont.userFixedPitchFont(ofSize: size)
        ?? NSFont.systemFont(ofSize: size)

    var cascade: [NSFontDescriptor] = []

    // (2) Nerd Font fallback — primary가 이미 Nerd Font가 아닐 때만.
    if !isNerdFont(family), let nerd = anyInstalledNerdFont() {
        cascade.append(NSFontDescriptor(name: nerd, size: size))
    }

    // (3) CJK(한글) fallback — base 폰트가 못 가진 동아시아 글자만 이 폰트로 그린다.
    //     Metal GlyphRasterizer와 **동일** 폰트를 쓰도록 cjkFallbackFont로 일원화.
    if let cjk = cjkFallbackFont(size: size) {
        cascade.append(NSFontDescriptor(name: cjk.fontName, size: size))
    }

    guard !cascade.isEmpty else { return primary }
    let descriptor = primary.fontDescriptor.addingAttributes([
        NSFontDescriptor.AttributeName.cascadeList: cascade,
    ])
    return NSFont(descriptor: descriptor, size: size) ?? primary
}

/// CJK(주로 한글) fallback 폰트를 한 곳에서 해석한다 — legacy cascade와 Metal
/// GlyphRasterizer가 **동일** 폰트를 쓰도록 보장한다.
///
/// D2Coding 계열 우선: 한글이 ASCII의 2배 폭(East-Asian Wide)으로 그려져 터미널
/// cell-grid(한글=2칸)에 맞고 한국 개발자 표준.
///
/// ⚠️ Nerd Font **"Mono"** 변형은 피한다 — 모든 글리프를 1셀 폭으로 강제해 한글까지
/// 반칸으로 찌그러뜨린다(한/A 비율 1.0). 비-Mono(`Nerd Font`)/`Propo` 변형은 한글을
/// 정상 2배 폭으로 유지(비율 2.0)하므로 그쪽을 우선. 모두 없으면 NanumGothicCoding,
/// 최종적으로 Apple SD Gothic Neo(proportional).
public func cjkFallbackFont(size: CGFloat) -> NSFont? {
    let candidates = [
        "D2Coding",                          // 원본 TTF (한글 2배 폭)
        "D2CodingLigature",
        "D2Coding Nerd Font",                // 비-Mono: 한글 정상 2칸
        "D2CodingLigature Nerd Font",
        "D2Coding Nerd Font Propo",
        "D2CodingLigature Nerd Font Propo",
        "NanumGothicCoding",
        "Apple SD Gothic Neo",
        "AppleSDGothicNeo-Regular",
    ]
    for name in candidates {
        if let f = NSFont(name: name, size: size) { return f }
    }
    return nil
}

/// 폰트 가족 이름에 "Nerd Font" 등의 키워드가 포함되면 Nerd Font로 간주.
public func isNerdFont(_ family: String) -> Bool {
    let lower = family.lowercased()
    return lower.contains("nerd font")
        || family.contains(" NF")
        || family.contains(" NFM")
        || family.contains(" NFP")
}

/// 시스템에 설치된 monospace Nerd Font 중 임의의 1개를 fallback 용도로 반환.
/// "Mono" 변형(글리프 1셀 폭)을 우선.
private var cachedNerdFallback: String??
public func anyInstalledNerdFont() -> String? {
    if let cached = cachedNerdFallback { return cached }
    let mgr = NSFontManager.shared
    let mono = mgr.availableFontFamilies.filter { name in
        guard isNerdFont(name) else { return false }
        guard let f = NSFont(name: name, size: 12) else { return false }
        return f.isFixedPitch
    }
    // "Mono" 변형 우선.
    let monoFirst = mono.sorted { a, b in
        let aMono = a.lowercased().contains("nerd font mono") || a.contains(" NFM")
        let bMono = b.lowercased().contains("nerd font mono") || b.contains(" NFM")
        if aMono != bMono { return aMono }
        return a < b
    }
    let chosen = monoFirst.first
    cachedNerdFallback = .some(chosen)
    return chosen
}
