import XCTest
@testable import DamsonTerminal

final class ThemeTests: XCTestCase {
    func testPresetCountAndIntegrity() {
        let presets = DamsonTheme.presets
        // At least 30 bundled themes (as of v1).
        XCTAssertGreaterThanOrEqual(presets.count, 30, "fewer bundled themes than expected")
        for t in presets {
            XCTAssertEqual(t.ansi.count, 16, "\(t.name) does not have 16 ANSI colors")
            XCTAssertFalse(t.name.isEmpty, "unnamed theme")
        }
    }

    func testPresetNamesUnique() {
        let names = DamsonTheme.presets.map { $0.name }
        XCTAssertEqual(Set(names).count, names.count, "duplicate preset names: \(names)")
    }

    func testPresetLookupRoundTrips() {
        for t in DamsonTheme.presets {
            XCTAssertEqual(DamsonTheme.preset(named: t.name)?.name, t.name)
        }
        // The custom name must not be a preset.
        XCTAssertNil(DamsonTheme.preset(named: DamsonTheme.customName))
    }
}
