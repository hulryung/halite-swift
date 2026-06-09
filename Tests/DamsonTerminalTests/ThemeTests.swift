import XCTest
@testable import DamsonTerminal

final class ThemeTests: XCTestCase {
    func testPresetCountAndIntegrity() {
        let presets = DamsonTheme.presets
        // 번들 테마는 30개 이상 (v1 기준).
        XCTAssertGreaterThanOrEqual(presets.count, 30, "기대보다 적은 번들 테마")
        for t in presets {
            XCTAssertEqual(t.ansi.count, 16, "\(t.name)의 ANSI 색 개수가 16이 아님")
            XCTAssertFalse(t.name.isEmpty, "이름 없는 테마")
        }
    }

    func testPresetNamesUnique() {
        let names = DamsonTheme.presets.map { $0.name }
        XCTAssertEqual(Set(names).count, names.count, "프리셋 이름 중복: \(names)")
    }

    func testPresetLookupRoundTrips() {
        for t in DamsonTheme.presets {
            XCTAssertEqual(DamsonTheme.preset(named: t.name)?.name, t.name)
        }
        // 커스텀 이름은 프리셋이 아니어야 한다.
        XCTAssertNil(DamsonTheme.preset(named: DamsonTheme.customName))
    }
}
