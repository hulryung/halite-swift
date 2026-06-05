/// Metal shader source, compiled at runtime via `device.makeLibrary(source:)`.
///
/// Embedding the source (rather than a precompiled `default.metallib` resource)
/// sidesteps the unproven `Bundle.module` shader-load path for this library
/// target — Phase 1 prioritizes getting Metal on screen. A precompiled
/// `.metallib` resource is a later optimization (avoids the one-time runtime
/// compile at launch).
///
/// Struct field order/types must match `RenderTypes.swift`.
enum MetalShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms { float2 viewportSize; };
    struct BgInstance { float2 origin; float2 size; float4 color; };

    struct BgVOut {
        float4 position [[position]];
        float4 color;
    };

    // Instanced unit-quad fill. Coordinates are in POINTS, top-left origin;
    // we map to NDC here (flipping Y) so pixel/backing scale never matters.
    vertex BgVOut bg_vertex(uint vid [[vertex_id]],
                            uint iid [[instance_id]],
                            constant Uniforms& u [[buffer(0)]],
                            const device BgInstance* insts [[buffer(1)]]) {
        float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 corner = corners[vid];
        BgInstance inst = insts[iid];
        float2 px = inst.origin + corner * inst.size;
        float2 ndc = float2(px.x / u.viewportSize.x * 2.0 - 1.0,
                            1.0 - px.y / u.viewportSize.y * 2.0);
        BgVOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.color = inst.color;
        return out;
    }

    // Premultiplied output (paired with a .one / .oneMinusSourceAlpha blend).
    // For opaque fills (a==1) this is identical to the old src-over path; for
    // translucent fills (window background-opacity < 1) it composites correctly
    // over the (also premultiplied) cleared background and the layer's backdrop.
    fragment float4 bg_fragment(BgVOut in [[stage_in]]) {
        return float4(in.color.rgb * in.color.a, in.color.a);
    }

    struct GlyphInstance {
        float2 origin; float2 size; float2 uvOrigin; float2 uvSize; float4 color;
    };
    struct GlyphVOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
    };

    vertex GlyphVOut glyph_vertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  constant Uniforms& u [[buffer(0)]],
                                  const device GlyphInstance* insts [[buffer(1)]]) {
        float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 corner = corners[vid];
        GlyphInstance inst = insts[iid];
        float2 px = inst.origin + corner * inst.size;
        float2 ndc = float2(px.x / u.viewportSize.x * 2.0 - 1.0,
                            1.0 - px.y / u.viewportSize.y * 2.0);
        GlyphVOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = inst.uvOrigin + corner * inst.uvSize;
        out.color = inst.color;
        return out;
    }

    fragment float4 glyph_fragment(GlyphVOut in [[stage_in]],
                                   texture2d<float> atlas [[texture(0)]],
                                   sampler samp [[sampler(0)]]) {
        float coverage = atlas.sample(samp, in.uv).r;
        return float4(in.color.rgb, in.color.a * coverage);
    }

    // Color emoji: sample the premultiplied BGRA color page as-is, ignoring fg.
    // Paired with a premultiplied (.one / .oneMinusSourceAlpha) blend.
    fragment float4 glyph_color_fragment(GlyphVOut in [[stage_in]],
                                         texture2d<float> atlas [[texture(0)]],
                                         sampler samp [[sampler(0)]]) {
        return atlas.sample(samp, in.uv);
    }
    """
}
