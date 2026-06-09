import XCTest
@testable import DamsonTerminal

final class DamsonTerminalTests: XCTestCase {
    func testSessionInitializes() {
        let session = DamsonSession(config: DamsonConfig())
        defer { session.terminate() }
        XCTAssertFalse(session.processExited)
        XCTAssertNil(session.exitCode)
        XCTAssertEqual(session.title, "")
    }

    func testConfigDefaults() {
        let config = DamsonConfig()
        XCTAssertEqual(config.fontFamily, "Menlo")
        XCTAssertEqual(config.fontSize, 13)
        XCTAssertGreaterThan(config.scrollbackBytes, 0)
        XCTAssertFalse(config.argv.isEmpty)
        XCTAssertTrue(config.animations)
    }
}
