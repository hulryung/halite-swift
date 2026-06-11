import simd

/// A full-screen post-processing effect. The terminal is drawn offscreen and then
/// applied with a fullscreen pass. With `.none`, the post-fx pass is skipped and we
/// draw directly to the drawable (zero cost).
///
/// Adding a new effect = a case here + a branch in `postFXParams` + (if needed) a shader branch.
public enum ScreenEffect: String, CaseIterable, Sendable {
    case none
    case crt
    case apertureGrille
    case greenPhosphor
    case amberPhosphor
    case vhs
    case grayscale
    case sepia
    case blueprint
    case bloom
    case pixelate
    case invert

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .crt: return "CRT (scanlines + glow)"
        case .apertureGrille: return "CRT Trinitron (RGB aperture grille)"
        case .greenPhosphor: return "Green Phosphor (green monochrome CRT)"
        case .amberPhosphor: return "Amber Phosphor (amber monochrome CRT)"
        case .vhs: return "VHS (color fringe + grain)"
        case .grayscale: return "Grayscale (black & white)"
        case .sepia: return "Sepia (vintage warm)"
        case .blueprint: return "Blueprint (blue monochrome)"
        case .bloom: return "Bloom (soft glow)"
        case .pixelate: return "Pixelate (chunky retro blocks)"
        case .invert: return "Invert (negative)"
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
        case .apertureGrille:
            // Sharper CRT: RGB triad stripes + scanlines + a touch of glow/curve.
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0.20 * k, 0.18 * k, 0.32 * k, 1.2),
                tint: SIMD4<Float>(mix(1.0, 1.02, k), 1.0, mix(1.0, 0.97, k), 1.0),
                coeffs2: SIMD4<Float>(0.10 * k, 0, 0, 0),
                coeffs3: SIMD4<Float>(0, 0, 0.75 * k, 0))
        case .vhs:
            // Worn-tape look: chromatic aberration + film grain + soft glow,
            // faint scanlines. Grain is position-keyed (static) — zero idle cost.
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0.08 * k, 0.30 * k, 0.22 * k, 2.0),
                tint: SIMD4<Float>(1.0, 0.99, 0.96, 1.0),
                coeffs2: SIMD4<Float>(0.05 * k, 0, 2.6 * k, 0.10 * k))
        case .sepia:
            // Vintage warm monochrome + gentle vignette.
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0, 0, 0.25 * k, 1.5),
                tint: SIMD4<Float>(1.10, 0.92, 0.72, 1.0),
                coeffs2: SIMD4<Float>(0, k, 0, 0.05 * k))
        case .blueprint:
            // Blue monochrome (cyanotype) + slight glow.
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0, 0.20 * k, 0.18 * k, 1.5),
                tint: SIMD4<Float>(0.45, 0.72, 1.0, 1.0),
                coeffs2: SIMD4<Float>(0, k, 0, 0))
        case .pixelate:
            // Chunky blocks: 3px at low intensity up to 9px at full.
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0, 0, 0, 1.5),
                tint: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                coeffs2: SIMD4<Float>(0, 0, 0, 0),
                coeffs3: SIMD4<Float>(0, (3 + 6 * k).rounded(), 0, 0))
        case .invert:
            // Full negative at any intensity ≥ threshold; partial inverts look
            // muddy, so blend toward full quickly.
            return PostFXParams(
                screenSize: screenSize,
                coeffs: SIMD4<Float>(0, 0, 0, 1.5),
                tint: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                coeffs2: SIMD4<Float>(0, 0, 0, 0),
                coeffs3: SIMD4<Float>(min(1, 0.5 + 0.5 * k), 0, 0, 0))
        }
    }
}

private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
