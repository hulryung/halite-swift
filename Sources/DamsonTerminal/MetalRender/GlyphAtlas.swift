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

    private enum GlyphKey: Hashable {
        // `wide`가 키에 포함돼야 한다. 같은 글자라도 narrow(1셀)/wide(2셀) 래스터는
        // 비트맵 크기가 달라서, 키에서 빠지면 한쪽 폭으로 캐시된 뒤 다른 폭으로 그릴 때
        // 늘어나/찌그러져 보인다(예: "점"의 continuation이 잠깐 사라져 narrow로 캐시되면
        // 이후 wide 렌더가 깨짐).
        case char(Character, bold: Bool, wide: Bool)
        /// A shaped ligature glyph (by glyph id), spanning `span` cells.
        case glyph(UInt16, bold: Bool, span: Int)
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
        let key = GlyphKey.char(ch, bold: bold, wide: wide)
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

    /// Region for a shaped ligature glyph (by glyph id, spanning `cellSpan`
    /// cells), rasterizing+packing on first use. Always a mask glyph. nil = blank.
    func region(forGlyph glyph: CGGlyph, bold: Bool, cellSpan: Int) -> Region? {
        let key = GlyphKey.glyph(glyph, bold: bold, span: cellSpan)
        if let cached = regions[key] { return cached }
        guard let bmp = rasterizer.rasterGlyph(glyph, bold: bold, cellSpan: cellSpan),
              let uv = packMask(bmp) else {
            regions[key] = .some(nil)
            return nil
        }
        let region = Region(uv: uv, isColor: false)
        regions[key] = .some(region)
        return region
    }

    /// Pack an R8 coverage bitmap into the mask page.
    private func packMask(_ bmp: GlyphRasterizer.Bitmap) -> GlyphInstanceUV? {
        if full { return nil }
        if cursorX + bmp.width > width { cursorX = 0; cursorY += shelfHeight }
        if cursorY + bmp.height > height {
            full = true
            NSLog("Damson: glyph atlas full")
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
            NSLog("Damson: color glyph atlas full")
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
