import AppKit
import QuartzCore

/// Our own on-screen performance HUD (Apple's `MTL_HUD_ENABLED` crashes inside
/// libMTLHud on recent macOS). Draws a scrolling frame-time bar graph plus a
/// stats line (FPS · frame ms · panel refresh), with a budget reference line at
/// the display's target frame time. Frames over ~1.5× budget show red.
///
/// Fed one `addSample(dt:)` per display-link tick by `MetalTerminalBackend`.
final class PerfHUDView: NSView {
    private var samples: [Double] = []          // recent frame intervals, seconds
    private let maxSamples = 120
    private var lastRedraw: CFTimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    func addSample(_ dt: CFTimeInterval) {
        samples.append(dt)
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        // Redraw at ~30Hz so the HUD itself doesn't add load to the frame we're measuring.
        let now = CACurrentMediaTime()
        if now - lastRedraw >= 1.0 / 30 {
            lastRedraw = now
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: b, xRadius: 5, yRadius: 5).fill()

        let screenHz = Double(window?.screen?.maximumFramesPerSecond ?? 60)
        let targetMs = 1000.0 / max(screenHz, 1)

        let pad: CGFloat = 6
        let textH: CGFloat = 15
        let graph = NSRect(x: b.minX + pad, y: b.minY + pad,
                           width: b.width - 2 * pad, height: b.height - 2 * pad - textH)

        // Stats from the last ~0.5s of samples.
        let n = max(1, Int(screenHz / 2))
        let recent = Array(samples.suffix(n))
        let avg = recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
        let fps = avg > 0 ? 1.0 / avg : 0
        let text = String(format: "%.0f fps   %.1f ms   · %.0f Hz panel", fps, avg * 1000, screenHz)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        (text as NSString).draw(at: NSPoint(x: b.minX + pad, y: b.maxY - textH + 1), withAttributes: attrs)

        guard graph.height > 1, !samples.isEmpty else { return }

        // Scale: budget sits at ~40% height so over-budget spikes stay visible.
        let maxMs = max(targetMs / 0.4, (recent.max() ?? 0) * 1000 * 1.1)

        // Budget reference line at the target frame time.
        let by = graph.minY + CGFloat(targetMs / maxMs) * graph.height
        NSColor.white.withAlphaComponent(0.28).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: graph.minX, y: by))
        line.line(to: NSPoint(x: graph.maxX, y: by))
        line.lineWidth = 1
        line.stroke()

        // Frame-time bars, oldest → newest left → right.
        let barW = graph.width / CGFloat(maxSamples)
        for (i, s) in samples.enumerated() {
            let ms = s * 1000
            let h = min(CGFloat(ms / maxMs), 1) * graph.height
            let x = graph.minX + CGFloat(i) * barW
            let over = ms > targetMs * 1.5
            (over ? NSColor.systemRed : NSColor.systemGreen.withAlphaComponent(0.85)).setFill()
            NSBezierPath(rect: NSRect(x: x, y: graph.minY, width: max(1, barW - 0.5), height: h)).fill()
        }
    }
}
