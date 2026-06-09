import AppKit
import SwiftUI

/// A click-to-record shortcut field. While recording it intercepts key events
/// (including menu equivalents like ⌘T) via `performKeyEquivalent`, so any chord
/// can be captured. Esc cancels; click outside / record commits.
struct KeyRecorderField: NSViewRepresentable {
    /// Current effective chord (nil = disabled / none).
    var chord: KeyChord?
    var isDisabled: Bool
    /// Called with a freshly recorded chord.
    var onRecord: (KeyChord) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onRecord = onRecord
        return v
    }

    func updateNSView(_ v: RecorderView, context: Context) {
        v.onRecord = onRecord
        v.chordText = isDisabled ? "Disabled" : (chord?.display ?? "—")
        v.isDisabledStyle = isDisabled
        v.needsDisplay = true
    }

    final class RecorderView: NSView {
        var onRecord: ((KeyChord) -> Void)?
        var chordText: String = "—"
        var isDisabledStyle: Bool = false
        private(set) var recording = false {
            didSet { needsDisplay = true }
        }

        override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 22) }
        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            recording = true
        }

        override func becomeFirstResponder() -> Bool { true }

        override func resignFirstResponder() -> Bool {
            recording = false
            return true
        }

        // Intercept everything (incl. menu equivalents) while recording.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            if event.keyCode == 53 {           // Esc — cancel
                cancel()
                return true
            }
            if let chord = KeyChord.from(event: event) {
                commit(chord)
                return true
            }
            return true   // swallow bare keys while recording (no modifier)
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { cancel(); return }
            if let chord = KeyChord.from(event: event) { commit(chord); return }
            // bare key without ⌘/⌥/⌃ — ignore (NSBeep would be noisy); keep recording.
        }

        private func commit(_ chord: KeyChord) {
            recording = false
            window?.makeFirstResponder(nil)
            onRecord?(chord)
        }
        private func cancel() {
            recording = false
            window?.makeFirstResponder(nil)
        }

        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                       : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = recording ? 1.5 : 1
            path.stroke()

            let text = recording ? "Press shortcut…" : chordText
            let color: NSColor = recording ? .secondaryLabelColor
                : (isDisabledStyle ? .tertiaryLabelColor : .labelColor)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12,
                    weight: recording ? .regular : .medium),
                .foregroundColor: color,
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                               y: (bounds.height - size.height) / 2))
        }
    }
}
