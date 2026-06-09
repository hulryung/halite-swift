import AppKit
import QuartzCore

/// `CAMetalLayer`-backed view, **flipped** (top-left origin) to match the cell
/// grid / textView convention. Owns drawable sizing; the backend draws into the
/// layer. Localizing `isFlipped` here (not the host) keeps the coordinate math
/// straightforward and the host's non-flipped layer (cursor overlay) intact.
final class MetalContentView: NSView {
    let metalLayer = CAMetalLayer()

    /// Called when the layer needs fresh content (resize / backing-scale change).
    var onNeedsDisplay: (() -> Void)?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        metalLayer.device = MetalDevice.shared?.device
        metalLayer.pixelFormat = MetalDevice.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.isOpaque = true
        return metalLayer
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        onNeedsDisplay?()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        onNeedsDisplay?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Leave the synchronized-present mode and draw one final correct frame.
        updateDrawableSize()
        onNeedsDisplay?()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? metalLayer.contentsScale
        // While the window is being live-resized, present the drawable as part of
        // the layout transaction (paired with the synchronous present in the
        // backend) so the layer never stretches its last frame to the new bounds.
        metalLayer.presentsWithTransaction = inLiveResize
        // Resize the drawable without an implicit animation (which would scale the
        // contents over ~0.25s and read as the text stretching).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        let w = max(1, bounds.width * scale)
        let h = max(1, bounds.height * scale)
        let newSize = CGSize(width: w, height: h)
        if metalLayer.drawableSize != newSize {
            metalLayer.drawableSize = newSize
        }
        CATransaction.commit()
    }
}
