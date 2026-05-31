import AppKit
import Sparkle

/// Sparkle 자동업데이트 wrapper.
///
/// 동작:
///   - 자동 백그라운드 체크는 **디폴트 비활성**. Settings의 "Automatic Updates"
///     토글로 켜고 끔 (UserDefaults "halite.autoUpdate", 디폴트 false).
///   - "Check for Updates…" 메뉴는 자동 설정과 무관하게 항상 수동 체크.
///   - 새 버전 발견 → 다이얼로그 → 다운로드 → EdDSA 서명 검증 → install.
///   - OTA 체크/다운로드 **실패는 다이얼로그 없이 조용히 무시** (SilentErrorUserDriver).
///     "업데이트 있음" / "최신입니다" 흐름은 그대로 유지.
///
/// 전제:
///   - Info.plist에 `SUFeedURL` + `SUPublicEDKey` 둘 다 set.
///   - .app은 Developer ID로 서명되어 있어야 설치 단계 통과.
///   - (현재 SUPublicEDKey는 placeholder라 실제 OTA는 키 발급 후 동작.)
///
/// SPUStandardUpdaterController 대신 SPUUpdater를 직접 쓰는 이유: 실패 다이얼로그를
/// 억제하려면 커스텀 user driver를 주입해야 하는데, controller는 자기 표준 driver를
/// 내부에서 만들어 주입을 허용하지 않기 때문.
final class HaliteUpdater: NSObject {
    static let shared = HaliteUpdater()

    private let userDriver: SilentErrorUserDriver
    private let updater: SPUUpdater

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
        do {
            try updater.start()
        } catch {
            // Updater 시작 실패(서명 누락/Info.plist 키 누락 등)도 조용히 무시 —
            // OTA만 비활성화되고 앱 동작에는 영향 없음.
            NSLog("Halite: Sparkle updater failed to start: \(error.localizedDescription)")
        }
        // 저장된 설정(디폴트 false)을 자동 체크에 반영.
        applyAutomaticChecksSetting()
    }

    /// 메뉴 액션이 호출하는 진입점 (자동 설정과 무관하게 즉시 체크).
    @objc func checkForUpdates(_ sender: Any?) {
        updater.checkForUpdates()
    }

    /// "Check for Updates…" 메뉴 항목 활성 여부 (체크 진행 중에는 비활성).
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        updater.canCheckForUpdates
    }

    /// 메뉴 target — HaliteUpdater 자신이 `checkForUpdates:` 액션을 받는다.
    var target: AnyObject { self }

    /// UserDefaults("halite.autoUpdate", 디폴트 false)를 Sparkle updater에 적용.
    /// Settings 변경 시에도 호출.
    func applyAutomaticChecksSetting() {
        let enabled = UserDefaults.standard.object(forKey: "halite.autoUpdate") as? Bool ?? false
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
        NSLog("Halite: suppressed Sparkle updater error: \(error.localizedDescription)")
        acknowledgement()
    }
}
