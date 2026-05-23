import XCTest
@testable import HaliteTerminal

final class HaliteTerminalTests: XCTestCase {
    func testSessionInitializes() {
        let session = HaliteSession(config: HaliteConfig())
        defer { session.terminate() }
        XCTAssertFalse(session.processExited)
        XCTAssertNil(session.exitCode)
        XCTAssertEqual(session.title, "")
    }

    func testConfigDefaults() {
        let config = HaliteConfig()
        XCTAssertEqual(config.fontFamily, "Menlo")
        XCTAssertEqual(config.fontSize, 13)
        XCTAssertGreaterThan(config.scrollbackBytes, 0)
        XCTAssertFalse(config.argv.isEmpty)
    }
}
