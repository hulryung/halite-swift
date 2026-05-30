import AppKit
import Sparkle

/// Sparkle 자동업데이트 wrapper.
///
/// 동작:
///   - 자동 백그라운드 체크는 **디폴트 비활성**. Settings의 "Automatic Updates"
///     토글로 켜고 끔 (UserDefaults "halite.autoUpdate", 디폴트 false).
///   - "Check for Updates…" 메뉴는 자동 설정과 무관하게 항상 수동 체크.
///   - 새 버전 발견 → 다이얼로그 → 다운로드 → EdDSA 서명 검증 → install.
///
/// 전제:
///   - Info.plist에 `SUFeedURL` + `SUPublicEDKey` 둘 다 set.
///   - .app은 Developer ID로 서명되어 있어야 설치 단계 통과.
///   - (현재 SUPublicEDKey는 placeholder라 실제 OTA는 키 발급 후 동작.)
final class HaliteUpdater {
    static let shared = HaliteUpdater()

    private let controller: SPUStandardUpdaterController

    private init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // 저장된 설정(디폴트 false)을 자동 체크에 반영.
        applyAutomaticChecksSetting()
    }

    /// 메뉴 액션이 호출하는 진입점 (자동 설정과 무관하게 즉시 체크).
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    var target: AnyObject { controller }

    /// UserDefaults("halite.autoUpdate", 디폴트 false)를 Sparkle updater에 적용.
    /// Settings 변경 시에도 호출.
    func applyAutomaticChecksSetting() {
        let enabled = UserDefaults.standard.object(forKey: "halite.autoUpdate") as? Bool ?? false
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
