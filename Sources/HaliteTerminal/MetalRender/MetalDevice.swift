import Metal

/// Shared Metal device, command queue, and pipeline factory. Built lazily and
/// cached process-wide (all terminal surfaces share one device/queue).
///
/// Returns nil if Metal is unavailable or the shader library fails to compile —
/// the host falls back to the legacy backend rather than crashing.
final class MetalDevice {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    /// bg/selection/cursor fill pipeline (instanced quads, src-over blending).
    let bgPipeline: MTLRenderPipelineState
    /// glyph pipeline (instanced quads sampling the coverage atlas, src-over).
    let glyphPipeline: MTLRenderPipelineState
    /// color-emoji pipeline: samples the premultiplied BGRA color page, premult
    /// (.one) blend. Same vertex/instance layout as `glyphPipeline`.
    let colorGlyphPipeline: MTLRenderPipelineState
    /// Linear-clamp sampler for the glyph atlas (also reused for post-fx).
    let glyphSampler: MTLSamplerState
    /// Fullscreen post-processing pass (screen effects). Samples the offscreen
    /// scene texture, writes the drawable. No blending (opaque overwrite).
    let postfxPipeline: MTLRenderPipelineState

    /// Pixel format used by the CAMetalLayer and pipelines.
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    static let shared: MetalDevice? = MetalDevice()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        // Runtime-compile the embedded shader source (see MetalShaders).
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: MetalShaders.source, options: nil)
        } catch {
            NSLog("Halite: Metal shader compile failed: \(error.localizedDescription)")
            return nil
        }
        guard let vfn = library.makeFunction(name: "bg_vertex"),
              let ffn = library.makeFunction(name: "bg_fragment") else {
            NSLog("Halite: Metal shader functions missing")
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        let attach = desc.colorAttachments[0]!
        attach.pixelFormat = Self.pixelFormat
        // Premultiplied src-over (bg_fragment premultiplies). Identical to the old
        // non-premultiplied src-over for opaque fills, but produces correct
        // premultiplied output so a translucent background (window opacity < 1)
        // composites correctly over the layer backdrop.
        attach.isBlendingEnabled = true
        attach.rgbBlendOperation = .add
        attach.alphaBlendOperation = .add
        attach.sourceRGBBlendFactor = .one
        attach.sourceAlphaBlendFactor = .one
        attach.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attach.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            NSLog("Halite: Metal bg pipeline creation failed")
            return nil
        }

        // Glyph pipeline — same color attachment/blend, glyph shaders.
        guard let gv = library.makeFunction(name: "glyph_vertex"),
              let gf = library.makeFunction(name: "glyph_fragment") else {
            NSLog("Halite: Metal glyph shader functions missing")
            return nil
        }
        let gdesc = MTLRenderPipelineDescriptor()
        gdesc.vertexFunction = gv
        gdesc.fragmentFunction = gf
        let ga = gdesc.colorAttachments[0]!
        ga.pixelFormat = Self.pixelFormat
        ga.isBlendingEnabled = true
        ga.rgbBlendOperation = .add
        ga.alphaBlendOperation = .add
        // RGB uses sourceAlpha (glyph_fragment outputs non-premultiplied color);
        // alpha uses .one so opaque text reaches full alpha over a translucent
        // background (otherwise glyphs would let the backdrop bleed through). For
        // an opaque drawable the alpha channel is ignored, so this is a no-op there.
        ga.sourceRGBBlendFactor = .sourceAlpha
        ga.sourceAlphaBlendFactor = .one
        ga.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ga.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let gpipeline = try? device.makeRenderPipelineState(descriptor: gdesc) else {
            NSLog("Halite: Metal glyph pipeline creation failed")
            return nil
        }

        // Color-emoji pipeline — glyph vertex + color fragment, PREMULTIPLIED
        // blend (the BGRA color page is premultiplied, so source factor is .one,
        // not .sourceAlpha). Must stay in sync with the rasterizer's premultiplied
        // BGRA context.
        guard let cf = library.makeFunction(name: "glyph_color_fragment") else {
            NSLog("Halite: Metal color glyph shader function missing")
            return nil
        }
        let cdesc = MTLRenderPipelineDescriptor()
        cdesc.vertexFunction = gv
        cdesc.fragmentFunction = cf
        let ca = cdesc.colorAttachments[0]!
        ca.pixelFormat = Self.pixelFormat
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let cpipeline = try? device.makeRenderPipelineState(descriptor: cdesc) else {
            NSLog("Halite: Metal color glyph pipeline creation failed")
            return nil
        }

        let samp = MTLSamplerDescriptor()
        samp.minFilter = .linear
        samp.magFilter = .linear
        samp.sAddressMode = .clampToEdge
        samp.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samp) else {
            NSLog("Halite: Metal sampler creation failed")
            return nil
        }

        // Post-fx pipeline — fullscreen triangle, no blending (overwrites drawable).
        guard let pfv = library.makeFunction(name: "postfx_vertex"),
              let pff = library.makeFunction(name: "postfx_fragment") else {
            NSLog("Halite: Metal post-fx shader functions missing")
            return nil
        }
        let pdesc = MTLRenderPipelineDescriptor()
        pdesc.vertexFunction = pfv
        pdesc.fragmentFunction = pff
        pdesc.colorAttachments[0].pixelFormat = Self.pixelFormat
        pdesc.colorAttachments[0].isBlendingEnabled = false
        guard let ppipeline = try? device.makeRenderPipelineState(descriptor: pdesc) else {
            NSLog("Halite: Metal post-fx pipeline creation failed")
            return nil
        }

        self.device = device
        self.queue = queue
        self.library = library
        self.bgPipeline = pipeline
        self.glyphPipeline = gpipeline
        self.colorGlyphPipeline = cpipeline
        self.glyphSampler = sampler
        self.postfxPipeline = ppipeline
    }
}
