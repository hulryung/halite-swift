import AppKit
import Sparkle

/// Sparkle 자동업데이트 wrapper.
///
/// 동작:
///   - 앱 시작 시 `SPUStandardUpdaterController`가 자동으로 백그라운드 체크
///     (Info.plist의 `SUEnableAutomaticChecks=true` 기본값).
///   - Help 메뉴의 "Check for Updates…" 클릭 시 즉시 체크.
///   - 새 버전 발견 → 사용자에게 다이얼로그 → 동의 시 다운로드 →
///     EdDSA 서명 검증 → install 후 재실행.
///
/// 전제:
///   - Info.plist에 `SUFeedURL`(appcast.xml 경로) + `SUPublicEDKey` 둘 다 set.
///   - .app은 Developer ID로 서명되어 있어야 Sparkle이 설치 단계 통과.
final class HaliteUpdater {
    static let shared = HaliteUpdater()

    private let controller: SPUStandardUpdaterController

    private init() {
        // startingUpdater: true → 즉시 시작.
        // updaterDelegate / userDriverDelegate nil → Sparkle 기본 UI 사용.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// 메뉴 액션이 호출하는 진입점. responder chain을 거치므로 `@objc` 노출.
    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    /// SPUStandardUpdaterController가 노출하는 selector — 메뉴 아이템에서 직접 wiring할 때 사용.
    var checkForUpdatesAction: Selector {
        #selector(SPUStandardUpdaterController.checkForUpdates(_:))
    }

    var target: AnyObject { controller }
}
