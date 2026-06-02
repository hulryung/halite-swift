import AppKit
import Metal

/// On-demand glyph atlas with two pages: an R8 coverage page for text (modulated
/// by fg) and a lazily-allocated BGRA page for color emoji (drawn as-is). A
/// `(char, bold) → Region` cache rasterizes+packs a glyph on first use. Tied to
/// one font + cell size + scale; the backend rebuilds the atlas when any change.
///
/// Single fixed-size page per format, no eviction. If a page fills, further new
/// glyphs of that kind are skipped (logged) rather than wrong.
final class GlyphAtlas {
    /// R8 coverage page (text/mask glyphs).
    let texture: MTLTexture
    /// BGRA premultiplied page (color emoji), allocated on first emoji only.
    private(set) var colorTexture: MTLTexture?

    private let device: MTLDevice
    private let width: Int
    private let height: Int
    private let shelfHeight: Int   // == cell height in px (uniform shelves)
    private let rasterizer: GlyphRasterizer

    /// A packed glyph: its UV region (normalized to its own page) + which page.
    struct Region {
        var uv: GlyphInstanceUV
        var isColor: Bool
    }

    /// nil value = rasterized but nothing to draw (blank). Cached to avoid retry.
    private var regions: [GlyphKey: Region?] = [:]
    private var cursorX = 0
    private var cursorY = 0
    private var full = false

    private let colorSide = 1024
    private var colorCursorX = 0
    private var colorCursorY = 0
    private var colorFull = false

    private struct GlyphKey: Hashable {
        var ch: Character
        var bold: Bool
    }

    struct GlyphInstanceUV {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
    }

    init?(device: MTLDevice, font: NSFont, cellW: CGFloat, cellH: CGFloat, scale: CGFloat) {
        let side = 2048
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: side, height: side, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .managed
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        self.device = device
        self.texture = tex
        self.width = side
        self.height = side
        self.shelfHeight = max(1, Int(ceil(cellH * max(scale, 1))))
        self.rasterizer = GlyphRasterizer(font: font, cellW: cellW, cellH: cellH, scale: scale)
    }

    /// Region for a glyph, rasterizing+packing on first use. nil = draw nothing.
    func region(for ch: Character, bold: Bool, wide: Bool) -> Region? {
        let key = GlyphKey(ch: ch, bold: bold)
        if let cached = regions[key] { return cached }   // includes cached-nil blanks
        guard let bmp = rasterizer.raster(ch, bold: bold, wide: wide) else {
            regions[key] = .some(nil)
            return nil
        }
        let result: Region? = bmp.isColor
            ? packColor(bmp).map { Region(uv: $0, isColor: true) }
            : packMask(bmp).map { Region(uv: $0, isColor: false) }
        regions[key] = .some(result)
        return result
    }

    /// Pack an R8 coverage bitmap into the mask page.
    private func packMask(_ bmp: GlyphRasterizer.Bitmap) -> GlyphInstanceUV? {
        if full { return nil }
        if cursorX + bmp.width > width { cursorX = 0; cursorY += shelfHeight }
        if cursorY + bmp.height > height {
            full = true
            NSLog("Halite: glyph atlas full")
            return nil
        }
        bmp.bytes.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(cursorX, cursorY, bmp.width, bmp.height),
                            mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bmp.width)
        }
        let uv = GlyphInstanceUV(
            origin: SIMD2<Float>(Float(cursorX) / Float(width), Float(cursorY) / Float(height)),
            size: SIMD2<Float>(Float(bmp.width) / Float(width), Float(bmp.height) / Float(height)))
        cursorX += bmp.width
        return uv
    }

    /// Pack a premultiplied BGRA bitmap into the color page (allocated on demand).
    private func packColor(_ bmp: GlyphRasterizer.Bitmap) -> GlyphInstanceUV? {
        if colorFull { return nil }
        let tex: MTLTexture
        if let t = colorTexture {
            tex = t
        } else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: colorSide, height: colorSide, mipmapped: false)
            desc.usage = .shaderRead
            desc.storageMode = .managed
            guard let t = device.makeTexture(descriptor: desc) else { colorFull = true; return nil }
            colorTexture = t
            tex = t
        }
        if colorCursorX + bmp.width > colorSide { colorCursorX = 0; colorCursorY += shelfHeight }
        if colorCursorY + bmp.height > colorSide {
            colorFull = true
            NSLog("Halite: color glyph atlas full")
            return nil
        }
        bmp.bytes.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(colorCursorX, colorCursorY, bmp.width, bmp.height),
                        mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bmp.width * 4)
        }
        let uv = GlyphInstanceUV(
            origin: SIMD2<Float>(Float(colorCursorX) / Float(colorSide), Float(colorCursorY) / Float(colorSide)),
            size: SIMD2<Float>(Float(bmp.width) / Float(colorSide), Float(bmp.height) / Float(colorSide)))
        colorCursorX += bmp.width
        return uv
    }
}
