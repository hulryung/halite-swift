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

    // (3) 한글 monospace fallback — D2Coding 우선 (한국 개발자에게 표준이고 한글 글자
    //     폭이 균일해 cell-grid 정렬에 좋음). 변형이 여러 개라 설치된 것을 차례로 시도.
    let koreanMono = [
        "D2Coding",
        "D2CodingLigature",
        "D2Coding Nerd Font Mono",
        "D2Coding Nerd Font",
        "D2CodingLigature Nerd Font Mono",
        "D2CodingLigature Nerd Font",
        "NanumGothicCoding",
    ]
    var addedKorean = false
    for name in koreanMono where NSFont(name: name, size: size) != nil {
        cascade.append(NSFontDescriptor(name: name, size: size))
        addedKorean = true
        break
    }

    // (4) D2Coding류가 미설치인 경우만 Apple SD Gothic Neo (모든 macOS에 있음).
    //     주의: SD Gothic Neo는 proportional이라 한글 폭이 미세하게 어긋날 수 있음.
    if !addedKorean {
        if NSFont(name: "Apple SD Gothic Neo", size: size) != nil {
            cascade.append(NSFontDescriptor(name: "Apple SD Gothic Neo", size: size))
        } else if NSFont(name: "AppleSDGothicNeo-Regular", size: size) != nil {
            cascade.append(NSFontDescriptor(name: "AppleSDGothicNeo-Regular", size: size))
        }
    }

    guard !cascade.isEmpty else { return primary }
    let descriptor = primary.fontDescriptor.addingAttributes([
        NSFontDescriptor.AttributeName.cascadeList: cascade,
    ])
    return NSFont(descriptor: descriptor, size: size) ?? primary
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
