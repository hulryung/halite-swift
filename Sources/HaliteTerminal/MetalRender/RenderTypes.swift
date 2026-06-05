import simd

/// CPU↔GPU shared layouts. Field order/types must match `MetalShaders.source`.
/// We render in POINTS with a top-left origin; the vertex shader flips Y to NDC,
/// so the drawable's pixel size never enters the geometry math.

/// Per-frame uniforms. Just the viewport size (points) for the NDC transform.
struct Uniforms {
    var viewportSize: SIMD2<Float>
}

/// One filled rectangle: cell background, selection, find highlight, block
/// cursor (as an inverse-bg rect). Origin/size in points, top-left origin.
struct BgInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

/// One glyph quad: cell rect (points) + atlas UV (0–1) + foreground color. The
/// fragment shader samples the R8 coverage atlas and modulates `color.a`.
struct GlyphInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var color: SIMD4<Float>
    /// Per-glyph effect. x = dissolve amount (0 = solid, 1 = fully dissolved),
    /// yzw reserved. Default zero → no effect (the common case).
    var fx: SIMD4<Float> = .zero
}

/// Post-processing parameters. Field order/alignment must match `PostFXParams`
/// in `MetalShaders.source` (float2 padded to 16 before the float4s).
struct PostFXParams {
    var screenSize: SIMD2<Float>
    /// x=scanline, y=glow, z=vignette, w=glowRadiusPx
    var coeffs: SIMD4<Float>
    /// rgb phosphor tint (a unused)
    var tint: SIMD4<Float>
    /// x=curvature (barrel), yzw reserved
    var coeffs2: SIMD4<Float>
}
