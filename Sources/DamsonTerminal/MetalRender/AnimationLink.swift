import AppKit
import QuartzCore

/// Transient display link driving programmatic scroll eases (snap-to-cursor).
///
/// macOS 14+ only, via `NSView.displayLink(target:selector:)`. On macOS 13
/// `start` returns `false` and the backend falls back to an instant jump — this
/// deliberately avoids the CVDisplayLink-hop-to-main path (see
/// docs/METAL-RENDERER-PLAN, increment B). The link is created on ease begin and
/// invalidated the instant the ease settles or the surface stops being visible
/// (occluded / miniaturized / off-window), so a settling animation never spins the
/// GPU on something nobody can see.
final class AnimationLink {
    private weak var view: NSView?
    private var link: AnyObject?            // CADisplayLink (macOS 14+)
    private var onTick: ((CFTimeInterval) -> Bool)?
    private var lastTimestamp: CFTimeInterval = 0

    init(view: NSView) { self.view = view }

    var isRunning: Bool { link != nil }

    /// Start (or keep running) the link. `tick(dt)` is invoked once per frame on the
    /// main thread and returns `true` when the animation is done. Returns `false`
    /// when no display link is available (macOS < 14) so the caller can jump instead.
    @discardableResult
    func start(_ tick: @escaping (_ dt: CFTimeInterval) -> Bool) -> Bool {
        guard #available(macOS 14.0, *), let view else { return false }
        onTick = tick
        if link == nil {
            let l = view.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            // ProMotion(120Hz)에서 링크가 기본 60으로 도는 걸 막는다 — 화면 최대 주사율을
            // 선호 프레임레이트로 명시. (미설정 시 디스플레이에 따라 60으로 캡될 수 있음.)
            let maxFPS = Float(view.window?.screen?.maximumFramesPerSecond ?? 60)
            if maxFPS > 60 {
                l.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 60, maximum: maxFPS, preferred: maxFPS)
            }
            l.add(to: .main, forMode: .common)
            link = l
            lastTimestamp = 0
        }
        return true
    }

    func stop() {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
        onTick = nil
        lastTimestamp = 0
    }

    @available(macOS 14.0, *)
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard let view, let window = view.window,
              window.occlusionState.contains(.visible) else {
            stop()
            return
        }
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? (1.0 / 60.0) : max(0, now - lastTimestamp)
        lastTimestamp = now
        if onTick?(dt) ?? true { stop() }
    }
}
