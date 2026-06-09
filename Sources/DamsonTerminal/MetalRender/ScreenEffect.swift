import simd

/// A full-screen post-processing effect. The terminal is drawn offscreen and then
/// applied with a fullscreen pass. With `.none`, the post-fx pass is skipped and we
/// draw directly to the drawable (zero cost).
///
/// Adding a new effect = a case here + a branch in `postFXParams` + (if needed) a shader branch.
public enum ScreenEffect: String, CaseIterable, Sendable {
    case none
    case crt
    case greenPhosphor
    case amberPhosphor
    case grayscale
    case bloom

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .crt: return "CRT (scanlines + glow)"
        case .greenPhosphor: return "Green Phosphor (green monochrome CRT)"
        case .amberPhosphor: return "Amber Phosphor (amber monochrome CRT)"
        case .grayscale: return "Grayscale (black & white)"
        case .bloom: return "Bloom (soft glow)"
        }
    }

    var isActive: Bool { self != .none }

    /// Post-fx parameters scaled by `intensity` (0~1). nil when `.none`.
    /// Static effects only (no time input) — no redraw needed while idle.
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
                // Slightly warm phosphor tint (nearly neutral). Interpolated neutral↔tint by intensity.
                tint: SIMD4<Float>(mix(1.0, 1.02, k), mix(1.0, 1.0, k), mix(1.0, 0.97, k), 1.0),
                // Center bulge — corners pinned, only the middle eases out slightly. Proportional to intensity, subtle.
                // y = monochrome amount.
                coeffs2: SIMD4<Float>(0.12 * k, 0, 0, 0))
        case .greenPhosphor:
            // CRT + green monochrome (luminance→green). tint = phosphor color.
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
            // Pure black-and-white — no scanlines/glow/curvature, luminance→gray.
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0, 0, 0, 1.5),
                tint: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                coeffs2: SIMD4<Float>(0, k, 0, 0))
        case .bloom:
            // Soft glow only — no scanlines/curvature/monochrome. Large glow radius.
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0, 0.55 * k, 0, 2.5),
                tint: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                coeffs2: SIMD4<Float>(0, 0, 0, 0))
        }
    }
}

private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
