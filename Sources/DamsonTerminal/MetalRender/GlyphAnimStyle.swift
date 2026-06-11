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
    case typewriter // stamps down onto the page (scale 1.35→1.0, snappy)
    case flip     // flips in/out around the vertical axis (width 0↔1)
    case drop     // falls in from above with a small bounce / falls away below
    case dissolve // scatters/gathers via pixel noise (shader fx)
    case burn     // chars away from the edges with an ember rim (shader fx)
    case glitch   // horizontal slice tearing + RGB split (shader fx)
    case burst    // bursts/gathers like colorful confetti (shader fx: dissolve + rainbow color)

    public func appearDisplayName() -> String {
        switch self {
        case .none:     return "None"
        case .fade:     return "Fade in"
        case .pop:      return "Pop (springing out)"
        case .slide:    return "Slide up (rising in)"
        case .typewriter: return "Typewriter (stamping down)"
        case .flip:     return "Flip (turning in)"
        case .drop:     return "Drop (falling in with a bounce)"
        case .dissolve: return "Dissolve (gathering in)"
        case .burn:     return "Burn (igniting in)"
        case .glitch:   return "Glitch (tearing in)"
        case .burst:    return "Burst (colorful gather-in)"
        }
    }

    public func disappearDisplayName() -> String {
        switch self {
        case .none:     return "None"
        case .fade:     return "Fade out"
        case .pop:      return "Collapse (shrinking away)"
        case .slide:    return "Slide down (dropping out)"
        case .typewriter: return "Unstamp (lifting off)"
        case .flip:     return "Flip (turning away)"
        case .drop:     return "Drop (falling away)"
        case .dissolve: return "Dissolve (scattering away)"
        case .burn:     return "Burn (charring away)"
        case .glitch:   return "Glitch (tearing apart)"
        case .burst:    return "Burst (colorful burst-out)"
        }
    }

    /// Shader-fx styles (per-glyph fx channels) need the ghost glyph drawn through the end.
    var usesShaderFX: Bool {
        self == .dissolve || self == .burst || self == .burn || self == .glitch
    }

    /// Duration (seconds) per effect and direction. Dissolve/burst differ for gathering (fast) vs scattering (slow).
    func duration(appearing: Bool) -> CFTimeInterval {
        switch self {
        case .dissolve: return appearing ? 0.10 : 0.32   // gather fast, scatter long
        case .burst:    return appearing ? 0.14 : 0.36   // make bursting a bit longer
        case .burn:     return appearing ? 0.14 : 0.40   // charring away reads slow
        case .glitch:   return appearing ? 0.16 : 0.22
        case .typewriter: return 0.09                    // a stamp is snappy
        case .drop:     return appearing ? 0.18 : 0.16   // room for the bounce
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
        case .typewriter:
            // A stamp: lands from slightly above-scale, alpha snapping in fast.
            let s = 1 + 0.35 * (1 - e)
            let cx = inst.origin.x + inst.size.x * 0.5
            let cy = inst.origin.y + inst.size.y * 0.5
            out.size = inst.size * s
            out.origin = SIMD2<Float>(cx - out.size.x * 0.5, cy - out.size.y * 0.5)
            out.color.w *= min(1, e * 1.8)
        case .flip:
            // Page-flip around the vertical center axis: width collapses to a
            // sliver and back (a cheap one-axis "3D" read).
            let w = max(0.04, e)
            let cx = inst.origin.x + inst.size.x * 0.5
            out.size.x = inst.size.x * w
            out.origin.x = cx - out.size.x * 0.5
            out.color.w *= min(1, e * 1.4)
        case .drop:
            if appearing {
                // Falls from ~0.8 cell above and lands with a small overshoot.
                let b = easeOutBack(max(0, min(1, p)))
                out.origin.y = inst.origin.y - inst.size.y * 0.8 * (1 - b)
                out.color.w *= min(1, p * 2.5)
            } else {
                // Lets go and accelerates off the bottom of the cell.
                let f = p * p
                out.origin.y = inst.origin.y + inst.size.y * 0.9 * f
                out.color.w *= (1 - p)
            }
        case .burn:
            // Erosion with an ember rim (shader colors the about-to-burn pixels).
            // No quad growth — it chars in place.
            out.fx.x = 1 - e
            out.fx.z = 1
        case .glitch:
            // Slice tearing peaks while the glyph is least visible; alpha holds
            // high through most of the anim so the tear itself is what reads.
            out.fx.y = 1 - e
            out.color.w *= smoothstep01(e * 1.6)
        }
        return out
    }

    private func easeOut(_ p: Float) -> Float { 1 - (1 - p) * (1 - p) * (1 - p) }
    /// Overshooting ease (lands past the target then settles) — the drop bounce.
    private func easeOutBack(_ p: Float) -> Float {
        let c1: Float = 1.70158
        let c3 = c1 + 1
        let q = p - 1
        return 1 + c3 * q * q * q + c1 * q * q
    }
    private func smoothstep01(_ x: Float) -> Float {
        let t = max(0, min(1, x))
        return t * t * (3 - 2 * t)
    }
}
