import simd

/// 화면 전체에 입히는 post-processing 효과. 터미널을 오프스크린에 그린 뒤 전체화면
/// 패스로 적용한다. `.none`이면 post-fx 패스를 건너뛰고 drawable에 직접 그린다(비용 0).
///
/// 새 효과 추가 = 여기에 case + `postFXParams`에 분기 + (필요하면) 셰이더 분기.
public enum ScreenEffect: String, CaseIterable, Sendable {
    case none
    case crt
    case greenPhosphor
    case amberPhosphor
    case grayscale
    case bloom

    public var displayName: String {
        switch self {
        case .none: return "None (없음)"
        case .crt: return "CRT (스캔라인·글로우)"
        case .greenPhosphor: return "Green Phosphor (초록 단색 CRT)"
        case .amberPhosphor: return "Amber Phosphor (호박색 단색 CRT)"
        case .grayscale: return "Grayscale (흑백)"
        case .bloom: return "Bloom (부드러운 글로우)"
        }
    }

    var isActive: Bool { self != .none }

    /// `intensity`(0~1)로 스케일한 post-fx 파라미터. `.none`이면 nil.
    /// 정적 효과만(시간 입력 없음) — idle 시 재그리기 불필요.
    func postFXParams(screenSize: SIMD2<Float>, intensity: Float) -> PostFXParams? {
        let k = max(0, min(1, intensity))
        switch self {
        case .none:
            return nil
        case .crt:
            // scanline / glow / vignette / glowRadiusPx
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0.18 * k, 0.22 * k, 0.40 * k, 1.5),
                // 살짝 따뜻한 phosphor 틴트(거의 중립). 강도에 따라 중립↔틴트 보간.
                tint: SIMD4<Float>(mix(1.0, 1.02, k), mix(1.0, 1.0, k), mix(1.0, 0.97, k), 1.0),
                // 중심 확대 bulge — 귀퉁이 고정, 가운데만 살짝. 강도에 비례, 은은하게.
                // y = monochrome amount.
                coeffs2: SIMD4<Float>(0.12 * k, 0, 0, 0))
        case .greenPhosphor:
            // CRT + 초록 단색(휘도→초록). tint = phosphor 색.
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0.18 * k, 0.25 * k, 0.40 * k, 1.5),
                tint: SIMD4<Float>(0.20, 1.0, 0.30, 1.0),
                coeffs2: SIMD4<Float>(0.12 * k, k, 0, 0))
        case .amberPhosphor:
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0.18 * k, 0.25 * k, 0.40 * k, 1.5),
                tint: SIMD4<Float>(1.0, 0.70, 0.20, 1.0),
                coeffs2: SIMD4<Float>(0.12 * k, k, 0, 0))
        case .grayscale:
            // 순수 흑백 — 스캔라인/글로우/곡률 없음, 휘도→회색.
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0, 0, 0, 1.5),
                tint: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                coeffs2: SIMD4<Float>(0, k, 0, 0))
        case .bloom:
            // 부드러운 글로우만 — 스캔라인/곡률/단색 없음. 글로우 반경 크게.
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0, 0.55 * k, 0, 2.5),
                tint: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                coeffs2: SIMD4<Float>(0, 0, 0, 0))
        }
    }
}

private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
