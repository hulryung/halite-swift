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
        // src-over: lets selection/find/cursor overlays composite with alpha.
        attach.isBlendingEnabled = true
        attach.rgbBlendOperation = .add
        attach.alphaBlendOperation = .add
        attach.sourceRGBBlendFactor = .sourceAlpha
        attach.sourceAlphaBlendFactor = .sourceAlpha
        attach.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attach.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else {
            NSLog("Halite: Metal bg pipeline creation failed")
            return nil
        }

        self.device = device
        self.queue = queue
        self.library = library
        self.bgPipeline = pipeline
    }
}
