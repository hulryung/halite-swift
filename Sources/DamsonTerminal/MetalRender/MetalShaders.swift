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
        float2 origin; float2 size; float2 uvOrigin; float2 uvSize; float4 color; float4 fx;
    };
    struct GlyphVOut {
        float4 position [[position]];
        float2 uv;
        float4 color;
        float4 fx;
        // Glyph's atlas rect, for fx that displace the sample uv (glitch) — the
        // displaced coordinate must clamp inside this glyph's atlas cell so slices
        // never bleed pixels from a neighboring glyph. [[flat]]: no interpolation.
        float2 uvOrigin [[flat]];
        float2 uvSize [[flat]];
    };

    static inline float hash21(float2 p) {
        float q = sin(dot(p, float2(127.1, 311.7))) * 43758.5453;
        return fract(q);
    }

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
        out.fx = inst.fx;
        out.uvOrigin = inst.uvOrigin;
        out.uvSize = inst.uvSize;
        return out;
    }

    // Glyph fx channels: fx.x = dissolve erosion, fx.y = glitch amount,
    // fx.z = burn (ember rim on the erosion edge; pairs with fx.x), fx.w reserved.
    fragment float4 glyph_fragment(GlyphVOut in [[stage_in]],
                                   texture2d<float> atlas [[texture(0)]],
                                   sampler samp [[sampler(0)]]) {
        float2 uv = in.uv;
        float glitch = in.fx.y;
        if (glitch > 0.0) {
            // Horizontal slice displacement: 3px bands shear sideways. Seeding the
            // hash with the (animating) amount re-rolls the slices every frame, so
            // the tear visibly crawls instead of freezing.
            float band = floor(in.position.y / 3.0);
            float n = hash21(float2(band, glitch * 41.0));
            uv.x += (n - 0.5) * glitch * in.uvSize.x * 0.9;
            uv = clamp(uv, in.uvOrigin, in.uvOrigin + in.uvSize);
        }
        float coverage = atlas.sample(samp, uv).r;
        float a = in.color.a * coverage;
        float3 rgb = in.color.rgb;
        // Dissolve: per-pixel noise vanishes as the dissolve amount rises.
        float diss = in.fx.x;
        if (diss > 0.0) {
            float n = hash21(floor(in.position.xy));
            a *= smoothstep(diss, diss + 0.18, n);
            // Burn: pixels just about to erode glow ember-orange, so the glyph
            // appears to char away from its edges.
            if (in.fx.z > 0.0) {
                float rim = 1.0 - smoothstep(diss + 0.05, diss + 0.30, n);
                rgb = mix(rgb, float3(1.0, 0.45, 0.08), rim * in.fx.z);
            }
        }
        if (glitch > 0.0) {
            // Per-slice dropout + RGB-split tint (some slices go magenta/cyan-ish).
            float band = floor(in.position.y / 3.0);
            float n2 = hash21(float2(band * 1.7, 13.0 + glitch * 23.0));
            a *= mix(1.0, step(0.15, n2), glitch);
            float3 split = (n2 < 0.5) ? float3(1.0, 0.6, 1.2) : float3(1.2, 1.0, 0.6);
            rgb *= mix(float3(1.0), split, glitch);
        }
        return float4(rgb, a);
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
    // texture) and applies a screen effect. Static effects have no time input,
    // so they only run on the frames the terminal already redraws (zero idle
    // cost). Animated effects (coeffs4.y > 0) read coeffs4.x as time; the
    // backend keeps a display-link redraw loop running while one is active.
    struct PostFXParams {
        float2 screenSize;   // drawable size in pixels
        float4 coeffs;       // x=scanline, y=glow, z=vignette, w=glowRadiusPx
        float4 tint;         // rgb phosphor tint (a unused)
        float4 coeffs2;      // x=curvature, y=monochrome amount, z=aberration px, w=grain
        float4 coeffs3;      // x=invert, y=pixelate block px, z=aperture grille, w reserved
        float4 coeffs4;      // x=time s, y=anim mode (1 rain, 2 snow, 3 underwater), z=intensity
        float4 bgColor;      // terminal bg (premultiplied) — bezel = dimmed bg
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

    static inline float2 hash22(float2 p) {
        float n = sin(dot(p, float2(41.3, 289.1))) * 21753.715;
        return fract(float2(n, n * 1.6180339));
    }

    // ---- Animated effects ---------------------------------------------------
    // All droplet/flake math runs in aspect-corrected uv ("auv": x *= aspect) so
    // shapes stay round regardless of window proportions. Each helper is a pure
    // function of (auv, time) — no state, the motion lives in the math.

    // ---- Rain on glass (windshield) -----------------------------------------
    // Modeled on how drops behave on a real car window, not on "falling":
    //  • Sliding drops live on a grid that DRIFTS down while each drop climbs
    //    its cell at the same rate — on screen the drop sits parked, quivering,
    //    then snaps down the cell in a quick slide. That stick/slip rhythm is
    //    what reads as "real rain" (the technique popularized by Martijn
    //    Steinrucken's rain-shader breakdowns).
    //  • A slide deposits a trail: a clear wiped band plus beads of water that
    //    stay put on the glass (screen space) and shrink as they dry.
    //  • A separate fine layer of static condensation beads covers the whole
    //    pane, each on a slow condense→sit→evaporate cycle.
    //  • Everything wet refracts (drops are little inverting lenses) and wipes
    //    the condensation fog; dry glass stays blurred like a view past focus.

    // Tent ramp: rises 0→1 over [0,b], falls back over [b,1]. With the ramp
    // speed matched to the grid drift below, rise = parked, fall = slide.
    static inline float rain_saw(float b, float t) {
        return smoothstep(0.0, b, t) * smoothstep(1.0, b, t);
    }

    // One sliding-drop layer. Returns float4(refraction offset (auv units),
    // wet mask, specular). `cells` sets density (x: columns, y: rows ~ tall).
    static inline float4 rain_drop_layer(float2 auv, float t, float2 cells, float seed) {
        const float kDrift = 0.45;     // cells/s the whole pattern slides down
        const float kCycle = 0.55;     // drop cycles/s; 0.7 cells climbed over
                                       // 85% of a cycle ≈ kDrift → parked
        float2 st = auv * cells + float2(seed * 13.7, 0.0);
        st.y -= t * kDrift;
        // De-grid: each column runs on its own vertical phase.
        st.y += hash22(float2(floor(st.x) + seed, 91.7)).x;
        float2 id = floor(st);
        float2 f = fract(st);
        float2 h = hash22(id + seed);
        float3 n = float3(h, fract(h.x * 17.13));
        if (n.x < 0.12) { return float4(0.0); }   // dry cells
        // Park position: off-center; the path wobbles as the drop slides (the
        // wiggle is keyed to SCREEN y, so it bends the trail, not the clock).
        float wig = auv.y * 14.0;
        float fx = 0.5 + (n.x - 0.5) * 0.6
                 + sin(wig + sin(wig * 0.55)) * 0.05 * (n.z - 0.5);
        // Stick/slip: climb the cell against the drift (parked), snap down.
        float ti = fract(t * kCycle + n.y);
        float fy = 0.85 - 0.70 * rain_saw(0.85, ti);
        float2 toC = (f - float2(fx, fy)) / cells;
        toC.y *= 0.84;                            // slight teardrop elongation
        float r = 0.008 + 0.011 * fract(n.z * 9.7);
        float d = length(toC);
        float drop = 1.0 - smoothstep(r * 0.72, r, d);
        // Wiped band above the drop (screen-space above = smaller f.y): clears
        // fog along the slide path, narrowing toward where the slide started.
        float climb = clamp((fy - f.y) / max(fy, 0.001), 0.0, 1.0);  // 0 at drop → 1 at cell top
        float bandW = r * (0.9 - 0.55 * climb);
        float band = (1.0 - smoothstep(bandW * 0.5, bandW, abs(toC.x)))
                   * step(f.y, fy) * (1.0 - climb * climb);
        // Trail beads: water left ON the glass — bead rows live in SCREEN
        // space so they stay put as the pattern drifts past, shrinking as
        // they climb (older = drier). Random rows are skipped.
        float beadRows = cells.y * 7.0;
        float beadKeep = step(0.35, hash22(float2(id.x + seed, floor(auv.y * beadRows))).x);
        float2 toB = float2(toC.x, (fract(auv.y * beadRows) - 0.5) / beadRows);
        float br = r * (0.62 - 0.34 * climb);
        float bead = (1.0 - smoothstep(br * 0.6, br, length(toB)))
                   * band * beadKeep;
        float wet = max(drop, max(bead, band * 0.5));
        // Refraction: lens inversion inside drops/beads, mild smear in the band.
        float2 off = -toC * drop * 4.5 + -toB * bead * 2.0;
        off.x += -toC.x * band * 0.4;
        // Lighting: a specular dot up-left + a soft rim — what makes beads
        // read as glass over a dark terminal.
        float hi = (1.0 - smoothstep(r * 0.10, r * 0.32,
                                     length(toC - float2(-r * 0.30, -r * 0.38)))) * drop;
        float rim = (smoothstep(r * 0.52, r * 0.82, d)
                   - smoothstep(r * 0.82, r * 1.06, d));
        return float4(off, wet, hi + rim * 0.22 * drop + rim * 0.10);
    }

    // Fine static condensation: small beads dotted over the whole pane, each
    // on a slow condense → sit → evaporate cycle. They refract gently and are
    // damp rather than wiped-clear (they sit on the fog, not through it).
    static inline float4 rain_static_layer(float2 auv, float t, float grid, float seed) {
        float2 st = auv * grid;
        float2 id = floor(st);
        float2 f = fract(st);
        float2 h = hash22(id + seed);
        if (h.x < 0.55) { return float4(0.0); }
        float2 c = 0.25 + 0.5 * hash22(id + seed + 5.1);
        float r = 0.10 + 0.16 * fract(h.y * 7.7);          // cell units
        float life = fract(t * 0.045 + h.y);               // ~22s lifecycle
        float presence = smoothstep(0.0, 0.18, life) * (1.0 - smoothstep(0.62, 1.0, life));
        float d = length(f - c);
        float m = (1.0 - smoothstep(r * 0.65, r, d)) * presence;
        float2 off = -((f - c) / grid) * m * 1.6;
        float hi = (1.0 - smoothstep(r * 0.10, r * 0.30,
                                     length(f - c - float2(-r * 0.35, -r * 0.35)))) * m;
        float rim = (smoothstep(r * 0.50, r * 0.78, d)
                   - smoothstep(r * 0.78, r * 1.02, d)) * presence;
        return float4(off, m * 0.55, hi * 0.5 + rim * 0.07);
    }

    // Composite rain field: two sliding layers (large + small drops) over the
    // static condensation beads. Returns (offset, wet, spec).
    static inline float4 rain_field(float2 auv, float t) {
        float4 a = rain_drop_layer(auv, t, float2(11.0, 1.7), 0.0);
        float4 b = rain_drop_layer(auv, t * 0.93 + 7.0, float2(19.0, 3.1), 3.7);
        float4 s = rain_static_layer(auv, t, 34.0, 9.1);
        float2 off = a.xy + b.xy + s.xy;
        float wet = max(a.z, max(b.z, s.z));
        float spec = a.w + b.w * 0.8 + s.w;
        return float4(off, wet, spec);
    }

    // Drifting snow: three parallax layers of flakes, each layer a grid of
    // mostly-empty cells with one jittered, twinkling flake. Returns additive
    // brightness 0..1.
    static inline float snow_field(float2 auv, float t) {
        float acc = 0.0;
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float g = 11.0 + fi * 9.0;                 // far layers are denser…
            float speed = 0.16 - fi * 0.045;           // …slower…
            float rr = 0.085 - fi * 0.022;             // …and smaller (cell units)
            float sway = sin(t * (0.6 + fi * 0.23) + auv.y * 2.7 + fi * 5.0) * 0.6;
            float2 st = float2(auv.x * g + sway, auv.y * g - t * speed * g);
            float2 id = floor(st);
            float2 f = fract(st);
            float2 rnd = hash22(id + fi * 31.7);
            if (rnd.x < 0.72) { continue; }            // sparse
            float2 c = 0.25 + 0.5 * hash22(id + 17.3 + fi);
            float d = length(f - c);
            float flake = 1.0 - smoothstep(rr * 0.45, rr, d);
            float twinkle = 0.7 + 0.3 * sin(t * 2.6 + rnd.y * 41.0);
            acc += flake * twinkle * (1.0 - fi * 0.28);
        }
        return min(acc, 1.0);
    }

    // Rising bubbles for the underwater mode: same grid trick as snow, drifting
    // upward, drawn as a thin ring with a highlight dot (a bubble is mostly
    // transparent — only its rim catches light). Returns additive brightness.
    static inline float bubble_field(float2 auv, float t) {
        float acc = 0.0;
        for (int i = 0; i < 2; i++) {
            float fi = float(i);
            float g = 7.0 + fi * 6.0;
            float speed = 0.10 + fi * 0.05;
            float sway = sin(t * (0.8 + fi * 0.3) + auv.y * 4.0 + fi * 2.0) * 0.25;
            float2 st = float2(auv.x * g + sway, auv.y * g + t * speed * g);
            float2 id = floor(st);
            float2 f = fract(st);
            float2 rnd = hash22(id + fi * 53.1);
            if (rnd.x < 0.78) { continue; }            // bubbles are rare
            float2 c = 0.3 + 0.4 * hash22(id + 7.7 + fi);
            float r = 0.05 + 0.07 * rnd.y;
            float d = length(f - c);
            float ring = smoothstep(r, r * 0.82, d) - smoothstep(r * 0.66, r * 0.40, d);
            float hi = 1.0 - smoothstep(0.0, r * 0.30,
                                        length(f - c - float2(-r * 0.35, -r * 0.35)));
            acc += ring * 0.5 + hi * 0.55;
        }
        return min(acc, 1.0);
    }

    // Tube curve, edges bowing INWARD: the sample coordinate is pushed outward
    // more the further it is from the center, so the scene's edges land inside
    // the display and its boundary bows toward the middle (most at the corners
    // → rounded tube bezel). Every scene pixel maps to SOME display position,
    // so no terminal content is ever pushed off-screen — display pixels whose
    // sample falls outside [0,1] are the bezel and get masked to black.
    // (The previous center-magnify bulge spread the middle rows outward, which
    // visually shoved content off the left/right edges.) amount 0 = identity.
    static inline float2 crt_curve(float2 uv, float amount) {
        float2 c = uv * 2.0 - 1.0;          // -1..1, center origin
        float r2 = dot(c, c);               // 0 at center, 2 at the corners
        c *= 1.0 + amount * r2;             // sample beyond the scene near edges
        return c * 0.5 + 0.5;               // back to 0..1
    }

    fragment float4 postfx_fragment(PostFXVOut in [[stage_in]],
                                    texture2d<float> scene [[texture(0)]],
                                    sampler samp [[sampler(0)]],
                                    constant PostFXParams& p [[buffer(0)]]) {
        float scan = p.coeffs.x;
        float glowS = p.coeffs.y;
        float vig = p.coeffs.z;
        float glowR = p.coeffs.w;
        float curve = p.coeffs2.x;
        float aber = p.coeffs2.z;
        float grain = p.coeffs2.w;
        float invertAmt = p.coeffs3.x;
        float pixPx = p.coeffs3.y;
        float grille = p.coeffs3.z;

        // Curve the sampling coordinate; everything below samples/measures in
        // tube space so scanlines and vignette follow the curved image. Display
        // pixels whose curved sample falls outside the scene are the tube bezel:
        // `bezel` fades to 0 there (with a ~0.4% soft edge for AA) and the final
        // color is masked to opaque black.
        float2 uv = (curve > 0.0) ? crt_curve(in.uv, curve) : in.uv;
        float bezel = 1.0;
        if (curve > 0.0) {
            float2 inside = smoothstep(float2(-0.004), float2(0.004), uv)
                          * (1.0 - smoothstep(float2(0.996), float2(1.004), uv));
            bezel = inside.x * inside.y;
        }

        // Pixelate: quantize the sample coordinate to square blocks (device px).
        if (pixPx > 0.0) {
            float2 block = float2(pixPx) / p.screenSize;
            uv = (floor(uv / block) + 0.5) * block;
        }

        // Animated effects — pre-sample stage: distort the sampling coordinate
        // (raindrop lenses, underwater wobble) and collect masks for the
        // post-sample stages below.
        float animMode = p.coeffs4.y;
        float animT = p.coeffs4.x;
        float animK = p.coeffs4.z;
        float aspect = p.screenSize.x / p.screenSize.y;
        float rainWet = 0.0, rainSpec = 0.0, fogMix = 0.0;
        if (animMode > 0.5 && animMode < 1.5) {
            // Rain on glass (see rain_field above for the windshield model).
            float2 auv = float2(uv.x * aspect, uv.y);
            float4 rain = rain_field(auv, animT);
            rainWet = rain.z;
            rainSpec = rain.w;
            uv += float2(rain.x / aspect, rain.y) * animK;
            // Condensation: the dry glass is misted over and out of focus;
            // water wipes it clear (drops fully, damp areas partially).
            fogMix = animK * 0.75 * (1.0 - rainWet);
        } else if (animMode > 2.5) {
            // Underwater: layered sine wobble — slow large swell + faster ripple.
            uv.x += (sin(uv.y * 21.0 + animT * 1.6) * 0.0035
                   + sin(uv.y * 6.7 - animT * 1.1) * 0.0020) * animK;
            uv.y += sin(uv.x * 17.0 + animT * 1.2) * 0.0022 * animK;
        }

        float4 src;
        float3 color;
        if (aber > 0.0) {
            // Chromatic aberration: R and B sampled with opposite horizontal
            // offsets (in device px) — the misconverged-gun / VHS color fringe.
            float2 off = float2(aber / p.screenSize.x, 0.0);
            src = scene.sample(samp, uv);
            color = float3(scene.sample(samp, uv + off).r,
                           src.g,
                           scene.sample(samp, uv - off).b);
        } else {
            src = scene.sample(samp, uv);
            color = src.rgb;
        }

        // Rain condensation: the world outside the glass is out of focus — a
        // two-ring 9-tap blur plus a faint mist lift, mixed in everywhere the
        // water hasn't wiped the pane clear.
        if (fogMix > 0.0) {
            float3 blur = color * 0.20;
            float2 t1 = 3.0 / p.screenSize;
            float2 t2 = 6.5 / p.screenSize;
            blur += scene.sample(samp, uv + float2( t1.x,  t1.y)).rgb * 0.13;
            blur += scene.sample(samp, uv + float2(-t1.x,  t1.y)).rgb * 0.13;
            blur += scene.sample(samp, uv + float2( t1.x, -t1.y)).rgb * 0.13;
            blur += scene.sample(samp, uv + float2(-t1.x, -t1.y)).rgb * 0.13;
            blur += scene.sample(samp, uv + float2( t2.x,  0.0 )).rgb * 0.07;
            blur += scene.sample(samp, uv + float2(-t2.x,  0.0 )).rgb * 0.07;
            blur += scene.sample(samp, uv + float2( 0.0,   t2.y)).rgb * 0.07;
            blur += scene.sample(samp, uv + float2( 0.0,  -t2.y)).rgb * 0.07;
            color = mix(color, blur + 0.018, fogMix);
        }

        // Phosphor glow: cheap 3x3 box blur, lighten-mixed back in.
        if (glowS > 0.0 && glowR > 0.0) {
            float2 texel = float2(glowR) / p.screenSize;
            float3 sum = float3(0.0);
            for (int dx = -1; dx <= 1; dx++) {
                for (int dy = -1; dy <= 1; dy++) {
                    sum += scene.sample(samp, uv + float2(float(dx), float(dy)) * texel).rgb;
                }
            }
            float3 glow = sum * (1.0 / 9.0);
            color = mix(color, max(color, glow), glowS);
        }
        // Scanlines: dim alternating device-pixel rows.
        if (scan > 0.0) {
            int row = int(uv.y * p.screenSize.y);
            float dim = mix(1.0, 1.0 - scan, float(row & 1));
            color *= dim;
        }
        // Aperture grille: vertical RGB triad stripes (each device-pixel column
        // favors one channel), brightness-compensated so the mask doesn't darken.
        if (grille > 0.0) {
            int col = int(uv.x * p.screenSize.x);
            int ch = col - (col / 3) * 3;
            float3 mask = float3(ch == 0 ? 1.0 : 0.0,
                                 ch == 1 ? 1.0 : 0.0,
                                 ch == 2 ? 1.0 : 0.0);
            color *= mix(float3(1.0), mask * 2.6, grille);
        }
        // Color transform: monochrome (phosphor / grayscale) maps luminance onto
        // the tint color; otherwise the tint is a subtle multiply (CRT warmth).
        float mono = p.coeffs2.y;
        if (mono > 0.0) {
            float lum = dot(color, float3(0.299, 0.587, 0.114));
            color = mix(color, lum * p.tint.rgb, mono);
        } else {
            color *= p.tint.rgb;
        }
        // Invert (negative). Applied after tint/mono so phosphor inverts too.
        if (invertAmt > 0.0) {
            color = mix(color, 1.0 - color, invertAmt);
        }
        // Film grain: static per-pixel noise (position-keyed, NOT time-keyed —
        // keeps the zero-idle-cost contract; it shimmers only as content redraws).
        if (grain > 0.0) {
            float n = hash21(floor(in.uv * p.screenSize)) - 0.5;
            color += n * grain;
        }
        // Animated effects — post-sample overlays. These read the UNdistorted
        // screen coordinate (in.uv) so flakes/bubbles float over the content
        // rather than being bent by it.
        if (animMode > 1.5 && animMode < 2.5) {
            float2 auv = float2(in.uv.x * aspect, in.uv.y);
            color += snow_field(auv, animT) * 0.85 * animK * float3(0.92, 0.96, 1.05);
        } else if (animMode > 2.5) {
            float2 auv = float2(in.uv.x * aspect, in.uv.y);
            // Caustic shimmer: two crossing moving interference patterns,
            // sharpened so only the crests read as light.
            float c1 = sin(auv.x * 23.0 + animT * 2.1) * sin(auv.y * 17.0 - animT * 1.55);
            float c2 = sin(auv.x * 31.0 - animT * 1.3) * sin(auv.y * 23.0 + animT * 1.9);
            float caust = pow(max(c1 * c2, 0.0), 2.0);
            // Brighten lit content AND add a faint glow — the additive part is
            // what keeps caustics visible over the (near-black) terminal bg.
            color *= 1.0 + caust * 0.10 * animK;
            color += caust * float3(0.020, 0.045, 0.055) * animK;
            color += bubble_field(auv, animT) * 0.40 * animK;
        }
        if (rainSpec > 0.0) {
            color += rainSpec * 0.5 * animK;
        }
        // Vignette: darken toward the corners.
        if (vig > 0.0) {
            float d = distance(uv, float2(0.5));
            color *= 1.0 - smoothstep(0.35, 0.85, d) * vig;
        }
        // Tube bezel: outside the curved image, show the terminal background
        // slightly dimmed (the clamp sampler would otherwise smear the edge
        // pixels outward). Premultiplied like everything else in this pipeline.
        float3 bezelColor = p.bgColor.rgb * 0.78;
        color = mix(bezelColor, color, bezel);
        float alpha = mix(p.bgColor.a, src.a, bezel);
        return float4(max(color, float3(0.0)), alpha);
    }
    """
}
