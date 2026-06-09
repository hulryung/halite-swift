import simd
import QuartzCore

/// 커서 근처에서 글자가 새로 생기거나(appear) 지워질 때(disappear) 짧게 재생하는
/// per-glyph 애니메이션. 정적 화면효과와 달리 시간 기반이라, 진행 중일 때만 transient
/// display link가 돈다(끝나면 정지 → idle 0).
///
/// 대표 몇 가지로 시작하고 점차 확장(slide / glow / dissolve / burn …).
public enum GlyphAnimStyle: String, CaseIterable, Sendable {
    case none
    case fade
    case pop      // scale: appear 0.6→1.0, disappear 1.0→0.6 (+fade)
    case slide    // 아래에서 올라오며(+fade)
    case dissolve // 픽셀 노이즈로 흩어지며/모이며 (셰이더 fx)
    case burst    // 알록달록 색종이처럼 터지며/모이며 (셰이더 fx: 디졸브 + 무지개 색)

    public func appearDisplayName() -> String {
        switch self {
        case .none:     return "None (없음)"
        case .fade:     return "Fade in"
        case .pop:      return "Pop (튀어나오며)"
        case .slide:    return "Slide up (올라오며)"
        case .dissolve: return "Dissolve (모이며)"
        case .burst:    return "Burst (알록달록 모이며)"
        }
    }

    public func disappearDisplayName() -> String {
        switch self {
        case .none:     return "None (없음)"
        case .fade:     return "Fade out"
        case .pop:      return "Collapse (줄어들며)"
        case .slide:    return "Slide down (내려가며)"
        case .dissolve: return "Dissolve (흩어지며)"
        case .burst:    return "Burst (알록달록 터지며)"
        }
    }

    /// 디졸브/버스트는 셰이더(per-glyph fx)로 처리되므로 ghost 글리프를 끝까지 그려야 한다.
    var usesShaderFX: Bool { self == .dissolve || self == .burst }

    /// 효과·방향별 지속시간(초). 디졸브/버스트는 모이기(빠름)/흩어지기(느림)를 다르게.
    func duration(appearing: Bool) -> CFTimeInterval {
        switch self {
        case .dissolve: return appearing ? 0.10 : 0.32   // 모이기 빠르게, 흩어지기 길게
        case .burst:    return appearing ? 0.14 : 0.36   // 터지는 건 좀 더 길게
        default:        return 0.13
        }
    }

    /// 글리프 인스턴스에 진행도(p: 0~1, appearing 기준 1=완전히 보임)를 적용해
    /// 알파/스케일을 변조한 새 인스턴스를 만든다. `appearing`이면 p 그대로, 아니면 1-p.
    func apply(to inst: GlyphInstance, appearing: Bool, p: Float) -> GlyphInstance {
        // 시간 진행도 p(0~1)를 easeOut한 뒤 방향을 적용. disappear는 1-easeOut(p)라
        // 처음부터 곧장 떠난다(easeOut(1-p)=1-p³는 끝까지 머물다 급히 사라져 "멈췄다
        // 사라지는" 느낌을 줬다). e = 1이면 완전히 보임.
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
            // 셀 절반 높이만큼 아래(=y 큼)에서 제자리로. (y는 top-left, 아래로 증가)
            out.origin.y = inst.origin.y + inst.size.y * 0.5 * (1 - e)
            out.color.w *= e
        case .dissolve:
            // 셰이더가 픽셀 노이즈로 깎고(fx.x), 동시에 quad를 키워 확산/수렴시킨다.
            // disappear: diss 0→1 → 1.0→1.5배(바깥으로 퍼지며 흩어짐).
            // appear:    diss 1→0 → 1.5→1.0배(바깥에서 안으로 모임).
            let diss = 1 - e
            let s = 1 + 0.5 * diss
            let cx = inst.origin.x + inst.size.x * 0.5
            let cy = inst.origin.y + inst.size.y * 0.5
            out.size = inst.size * s
            out.origin = SIMD2<Float>(cx - out.size.x * 0.5, cy - out.size.y * 0.5)
            out.fx.x = diss
        case .burst:
            // 원본 글리프는 빠르게 사라지고, 무지개 별 파티클(백엔드에서 방출)이
            // 폭죽처럼 바깥으로 터져나간다.
            out.color.w *= min(1, e * 2.2)         // 앞부분에 빠르게 페이드
        }
        return out
    }

    private func easeOut(_ p: Float) -> Float { 1 - (1 - p) * (1 - p) * (1 - p) }
}
