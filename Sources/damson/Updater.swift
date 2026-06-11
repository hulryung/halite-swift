import AppKit
import Sparkle

/// Sparkle auto-update wrapper.
///
/// Behavior:
///   - Automatic background checks are **disabled by default**. Toggled on/off via the
///     "Automatic Updates" toggle in Settings (UserDefaults "damson.autoUpdate", default false).
///   - The "Check for Updates…" menu always performs a manual check regardless of the automatic setting.
///   - New version found → dialog → download → EdDSA signature verification → install.
///   - OTA check/download **failures are silently ignored with no dialog** (SilentErrorUserDriver).
///     The "update available" / "you're up to date" flows are kept as-is.
///
/// Assumptions:
///   - Both `SUFeedURL` and `SUPublicEDKey` are set in Info.plist.
///   - The .app must be signed with a Developer ID to clear the install step.
///   - (SUPublicEDKey is currently a placeholder, so real OTA works only after a key is issued.)
///
/// Why SPUUpdater is used directly instead of SPUStandardUpdaterController: suppressing the
/// failure dialog requires injecting a custom user driver, but the controller builds its own
/// standard driver internally and doesn't allow injection.
final class DamsonUpdater: NSObject {
    static let shared = DamsonUpdater()

    private let userDriver: SilentErrorUserDriver
    private let updater: SPUUpdater

    /// Dev builds never run the updater: a dev .app silently replacing itself
    /// with the release feed's build would clobber the local dev install (and
    /// dev builds are ad-hoc signed, so the install step would fail anyway).
    private let updatesEnabled = !BuildInfo.isDevBuild

    private override init() {
        let host = Bundle.main
        self.userDriver = SilentErrorUserDriver(hostBundle: host, delegate: nil)
        self.updater = SPUUpdater(
            hostBundle: host,
            applicationBundle: host,
            userDriver: userDriver,
            delegate: nil
        )
        super.init()
        guard updatesEnabled else {
            NSLog("Damson: dev build — Sparkle updater not started")
            return
        }
        do {
            try updater.start()
        } catch {
            // Updater start failures (missing signature, missing Info.plist keys, etc.) are
            // also silently ignored — only OTA is disabled, with no effect on app behavior.
            NSLog("Damson: Sparkle updater failed to start: \(error.localizedDescription)")
        }
        // Apply the saved setting (default false) to automatic checks.
        applyAutomaticChecksSetting()
    }

    /// Entry point invoked by the menu action (checks immediately, regardless of the automatic setting).
    @objc func checkForUpdates(_ sender: Any?) {
        guard updatesEnabled else { return }
        updater.checkForUpdates()
    }

    /// Whether the "Check for Updates…" menu item is enabled (disabled while a check is in progress
    /// and always in dev builds, where the updater never starts).
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        updatesEnabled && updater.canCheckForUpdates
    }

    /// Menu target — DamsonUpdater itself receives the `checkForUpdates:` action.
    var target: AnyObject { self }

    /// Applies UserDefaults("damson.autoUpdate", default false) to the Sparkle updater.
    /// Also called when Settings change.
    func applyAutomaticChecksSetting() {
        guard updatesEnabled else { return }
        let enabled = UserDefaults.standard.object(forKey: "damson.autoUpdate") as? Bool ?? false
        updater.automaticallyChecksForUpdates = enabled
    }
}

/// Standard Sparkle UI, but OTA check/download failures are swallowed with no
/// error dialog. Product decision: update failures (unreachable feed, signature
/// issues during the pre-activation period, etc.) must never interrupt the user
/// with an alert. "Update available" and "you're up to date" flows are unchanged
/// — only the error path is silenced.
private final class SilentErrorUserDriver: SPUStandardUserDriver {
    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        NSLog("Damson: suppressed Sparkle updater error: \(error.localizedDescription)")
        acknowledgement()
    }
}
