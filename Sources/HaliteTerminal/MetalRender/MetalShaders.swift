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

    // ---- Post-processing (screen effects) ----------------------------------
    // A fullscreen pass that samples the rendered terminal (offscreen scene
    // texture) and applies a screen effect. Static — no time input, so it only
    // runs on the frames the terminal already redraws (zero idle cost).
    struct PostFXParams {
        float2 screenSize;   // drawable size in pixels
        float4 coeffs;       // x=scanline, y=glow, z=vignette, w=glowRadiusPx
        float4 tint;         // rgb phosphor tint (a unused)
    };
    struct PostFXVOut {
        float4 position [[position]];
        float2 uv;
    };

    // Fullscreen triangle from 3 vertex ids — no vertex buffer.
    vertex PostFXVOut postfx_vertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        PostFXVOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(p.x, 1.0 - p.y);   // scene stores rows top-down
        return out;
    }

    fragment float4 postfx_fragment(PostFXVOut in [[stage_in]],
                                    texture2d<float> scene [[texture(0)]],
                                    sampler samp [[sampler(0)]],
                                    constant PostFXParams& p [[buffer(0)]]) {
        float4 src = scene.sample(samp, in.uv);
        float3 color = src.rgb;
        float scan = p.coeffs.x;
        float glowS = p.coeffs.y;
        float vig = p.coeffs.z;
        float glowR = p.coeffs.w;

        // Phosphor glow: cheap 3x3 box blur, lighten-mixed back in.
        if (glowS > 0.0 && glowR > 0.0) {
            float2 texel = float2(glowR) / p.screenSize;
            float3 sum = float3(0.0);
            for (int dx = -1; dx <= 1; dx++) {
                for (int dy = -1; dy <= 1; dy++) {
                    sum += scene.sample(samp, in.uv + float2(float(dx), float(dy)) * texel).rgb;
                }
            }
            float3 glow = sum * (1.0 / 9.0);
            color = mix(color, max(color, glow), glowS);
        }
        // Scanlines: dim alternating device-pixel rows.
        if (scan > 0.0) {
            int row = int(in.uv.y * p.screenSize.y);
            float dim = mix(1.0, 1.0 - scan, float(row & 1));
            color *= dim;
        }
        // Phosphor tint.
        color *= p.tint.rgb;
        // Vignette: darken toward the corners.
        if (vig > 0.0) {
            float d = distance(in.uv, float2(0.5));
            color *= 1.0 - smoothstep(0.35, 0.85, d) * vig;
        }
        return float4(color, src.a);
    }
    """
}
