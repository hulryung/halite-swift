import Foundation

/// Which render backend `HaliteSurfaceView` drives. The Metal backend is built
/// behind this toggle so the legacy `NSTextView` path stays as a live A/B
/// fallback during bring-up. See docs/METAL-RENDERER-PLAN.md.
public enum RenderBackendKind: String {
    /// The original M3 path: child `NSTextView` + full `NSAttributedString` rebuild.
    case legacyText
    /// The `CAMetalLayer` instanced renderer.
    case metal
}

/// Resolves which backend to use. Precedence (highest first):
///   1. `liveOverride` — set at runtime (e.g. a debug toggle) for live A/B.
///   2. env `HALITE_METAL=1` — opt into Metal for a dev run.
///   3. `UserDefaults["HaliteRenderBackend"]` — persisted preference.
///   4. `.legacyText` — the safe default until the Metal path reaches parity.
enum MetalRenderConfig {
    /// Live, in-memory override. Wins over env and defaults. `nil` = not set.
    static var liveOverride: RenderBackendKind?

    static func resolved() -> RenderBackendKind {
        if let override = liveOverride { return override }
        if ProcessInfo.processInfo.environment["HALITE_METAL"] == "1" { return .metal }
        if let raw = UserDefaults.standard.string(forKey: "HaliteRenderBackend"),
           let kind = RenderBackendKind(rawValue: raw) {
            return kind
        }
        return .legacyText
    }
}
