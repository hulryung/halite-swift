import simd
import QuartzCore

/// A per-glyph animation played briefly when a character appears or disappears near
/// the cursor. Unlike static screen effects it's time-based, so a transient display
/// link runs only while it's in progress (stops when done → idle 0).
///
/// Start with a few representative styles and expand over time (slide / glow / dissolve / burn …).
public enum GlyphAnimStyle: String, CaseIterable, Sendable {
    case none
    case fade
    case pop      // scale: appear 0.6→1.0, disappear 1.0→0.6 (+fade)
    case slide    // rises up from below (+fade)
    case dissolve // scatters/gathers via pixel noise (shader fx)
    case burst    // bursts/gathers like colorful confetti (shader fx: dissolve + rainbow color)

    public func appearDisplayName() -> String {
        switch self {
        case .none:     return "None"
        case .fade:     return "Fade in"
        case .pop:      return "Pop (springing out)"
        case .slide:    return "Slide up (rising in)"
        case .dissolve: return "Dissolve (gathering in)"
        case .burst:    return "Burst (colorful gather-in)"
        }
    }

    public func disappearDisplayName() -> String {
        switch self {
        case .none:     return "None"
        case .fade:     return "Fade out"
        case .pop:      return "Collapse (shrinking away)"
        case .slide:    return "Slide down (dropping out)"
        case .dissolve: return "Dissolve (scattering away)"
        case .burst:    return "Burst (colorful burst-out)"
        }
    }

    /// Dissolve/burst are handled by the shader (per-glyph fx), so the ghost glyph must be drawn through the end.
    var usesShaderFX: Bool { self == .dissolve || self == .burst }

    /// Duration (seconds) per effect and direction. Dissolve/burst differ for gathering (fast) vs scattering (slow).
    func duration(appearing: Bool) -> CFTimeInterval {
        switch self {
        case .dissolve: return appearing ? 0.10 : 0.32   // gather fast, scatter long
        case .burst:    return appearing ? 0.14 : 0.36   // make bursting a bit longer
        default:        return 0.13
        }
    }

    /// Apply progress (p: 0~1, where 1 = fully visible in appearing terms) to a glyph
    /// instance, producing a new instance with modulated alpha/scale. If `appearing`,
    /// use p directly; otherwise 1-p.
    func apply(to inst: GlyphInstance, appearing: Bool, p: Float) -> GlyphInstance {
        // easeOut the time progress p (0~1), then apply direction. disappear uses
        // 1-easeOut(p) so it leaves promptly from the start (easeOut(1-p)=1-p³
        // lingered until the end and then vanished abruptly, giving a "paused then
        // gone" feel). e = 1 means fully visible.
        let q = easeOut(max(0, min(1, p)))
        let e = appearing ? q : (1 - q)
        var out = inst
        switch self {
        case .none:
            break
        case .fade:
            out.color.w *= e
        case .pop:
            let s = 0.6 + 0.4 * e                  // 0.6 → 1.0
            let cx = inst.origin.x + inst.size.x * 0.5
            let cy = inst.origin.y + inst.size.y * 0.5
            out.size = inst.size * s
            out.origin = SIMD2<Float>(cx - out.size.x * 0.5, cy - out.size.y * 0.5)
            out.color.w *= e
        case .slide:
            // Move into place from half a cell-height below (=larger y). (y is top-left, increasing downward)
            out.origin.y = inst.origin.y + inst.size.y * 0.5 * (1 - e)
            out.color.w *= e
        case .dissolve:
            // The shader erodes with pixel noise (fx.x) and simultaneously grows the
            // quad to spread/converge.
            // disappear: diss 0→1 → 1.0×→1.5× (spreads outward and scatters).
            // appear:    diss 1→0 → 1.5×→1.0× (gathers inward from outside).
            let diss = 1 - e
            let s = 1 + 0.5 * diss
            let cx = inst.origin.x + inst.size.x * 0.5
            let cy = inst.origin.y + inst.size.y * 0.5
            out.size = inst.size * s
            out.origin = SIMD2<Float>(cx - out.size.x * 0.5, cy - out.size.y * 0.5)
            out.fx.x = diss
        case .burst:
            // The original glyph fades out quickly, while rainbow star particles
            // (emitted by the backend) burst outward like fireworks.
            out.color.w *= min(1, e * 2.2)         // fade fast at the front
        }
        return out
    }

    private func easeOut(_ p: Float) -> Float { 1 - (1 - p) * (1 - p) * (1 - p) }
}
