import AppKit

/// 탭/페인 생성·전환·닫기·분할에 공통으로 쓰는 모션 헬퍼.
/// 상태 없는 정적 멤버만 — 인스턴스 없음.
///
/// 위치 메모: 디자인 스펙은 `Sources/halite/Motion.swift`라고 적었지만,
/// halite 실행 타깃은 단위 테스트가 불가능하다(Package.swift의 test 타깃은
/// HaliteTerminal/HaliteControl 라이브러리에만 의존). 스펙 Testing 절이
/// `enabled` 진리표와 `snapshot(of:)` 자동 커버리지를 요구하므로
/// 테스트 가능한 HaliteTerminal 라이브러리에 둔다. 호출 측 코드는 동일하다
/// (호출자들은 이미 `import HaliteTerminal`).
public enum Motion {

    /// 모든 라이프사이클 애니메이션의 지속 시간. 0.16s — 기존 스크롤 스냅/벨 플래시(0.18s)와
    /// 비슷한, 의도적으로 빠른 감각.
    public static let duration: TimeInterval = 0.16

    /// 모든 애니메이션의 타이밍 곡선. easeOut — 스크롤 스냅/벨 플래시와 같은 곡선.
    public static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }

    /// 마스터 게이트. 각 애니메이션 진입점에서 매번 LIVE로 읽는다(캐시 금지).
    /// 사용자 토글이 켜져 있고 AND macOS Reduce Motion이 꺼져 있을 때만 true.
    /// Reduce Motion은 토글과 무관하게 항상 우선(애니메이션 차단)한다.
    /// 키가 없으면 기본값은 true(애니메이션 ON).
    public static var enabled: Bool {
        let toggle = (UserDefaults.standard.object(forKey: "halite.animations") as? Bool) ?? true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return isEnabled(toggledOn: toggle, reduceMotionEnabled: reduceMotion)
    }

    /// 순수 게이트 함수 — 명시적 파라미터만 받고 전역 I/O가 없어 단위 테스트가 쉽다.
    /// `enabled`가 UserDefaults/NSWorkspace를 읽어 이 함수에 위임한다.
    /// 테스트 전용 seam: 프로덕션 코드에서 직접 호출하지 말 것(대신 `enabled` 사용).
    static func isEnabled(toggledOn: Bool, reduceMotionEnabled: Bool) -> Bool {
        toggledOn && !reduceMotionEnabled
    }

    /// 뷰의 현재 렌더링을 비트맵으로 스냅샷. 사라지는/철거되는 콘텐츠
    /// (닫히는 탭·페인, 전환 시 나가는 탭)에 쓴다. NSTextView/NSScrollView 내용까지 잡힌다.
    /// 0 크기 뷰이거나 캐싱 실패 시 nil — 호출자는 nil이면 즉시(instant) 경로로 폴백해야 한다.
    public static func snapshot(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// `host.layer` 위에 자기완결적인 이미지 기반 CALayer를 `frame`(host 좌표계)에 얹고
    /// 그 레이어를 반환한다. 호출자가 직접 애니메이트 후 제거한다.
    /// host는 layer-backed여야 한다(모든 페인 컨테이너는 이미 그렇다).
    public static func overlay(image: NSImage, frame: NSRect, in host: NSView) -> CALayer {
        host.wantsLayer = true
        let layer = CALayer()
        layer.frame = frame
        layer.contents = image
        layer.contentsGravity = .resize
        // Retina에서 또렷하게.
        layer.contentsScale = host.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        layer.zPosition = 100
        host.layer?.addSublayer(layer)
        return layer
    }

    /// 0.16s / easeOut NSAnimationContext 그룹 1회 실행.
    /// `allowsImplicitAnimation = true` 를 켜므로, `body` 안에서 (백킹 레이어 포함)
    /// 레이어 속성을 직접 대입해도 암시적으로 애니메이트된다 — 탭 생성/페인 닫기가
    /// 이 계약에 의존한다(이게 빠지면 스냅된다). `.animator()` 변경에도 동일하게 동작.
    /// `done`은 완료 시 호출된다(오버레이 제거/상태 복원 용).
    public static func run(_ body: () -> Void, done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            body()
        }, completionHandler: done)
    }
}
