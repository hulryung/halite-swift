import Foundation
import XCTest
@testable import DamsonControl

/// Regression guard for wire-format compatibility. The bytes must match the Rust
/// damson-cli `docs/CLI.md` spec exactly, or cross-impl compatibility breaks.
final class WireTests: XCTestCase {
    // MARK: - encodeCommand (CLI → server)

    func testEncodeNewTab() {
        XCTAssertEqual(encodeCommand(.newTab), #"{"cmd":"new-tab"}"#)
    }

    func testEncodeCloseTab() {
        XCTAssertEqual(encodeCommand(.closeTab), #"{"cmd":"close-tab"}"#)
    }

    func testEncodeListTabs() {
        XCTAssertEqual(encodeCommand(.listTabs), #"{"cmd":"list-tabs"}"#)
    }

    func testEncodeSplitHorizontal() {
        XCTAssertEqual(
            encodeCommand(.split(.horizontal)),
            #"{"cmd":"split","args":{"dir":"horizontal"}}"#
        )
    }

    func testEncodeSplitVertical() {
        XCTAssertEqual(
            encodeCommand(.split(.vertical)),
            #"{"cmd":"split","args":{"dir":"vertical"}}"#
        )
    }

    func testEncodeSwitchTab() {
        XCTAssertEqual(
            encodeCommand(.switchTab(index: 7)),
            #"{"cmd":"switch-tab","args":{"index":7}}"#
        )
    }

    func testEncodeSendText() {
        XCTAssertEqual(
            encodeCommand(.sendText("ls -la")),
            #"{"cmd":"send-text","args":{"text":"ls -la"}}"#
        )
    }

    func testEncodeSendTextEscapesSpecials() {
        // Quote, backslash, newline, tab must be JSON-escaped.
        XCTAssertEqual(
            encodeCommand(.sendText("a\"b\\c\n\t")),
            #"{"cmd":"send-text","args":{"text":"a\"b\\c\n\t"}}"#
        )
    }

    func testEncodeSendKeys() {
        XCTAssertEqual(
            encodeCommand(.sendKeys(["enter"])),
            #"{"cmd":"send-key","args":{"keys":["enter"]}}"#
        )
        XCTAssertEqual(
            encodeCommand(.sendKeys(["ctrl-c", "up", "enter"])),
            #"{"cmd":"send-key","args":{"keys":["ctrl-c","up","enter"]}}"#
        )
    }

    func testEncodeResizeWindow() {
        XCTAssertEqual(
            encodeCommand(.resizeWindow(cols: 120, rows: 40)),
            #"{"cmd":"resize-window","args":{"cols":120,"rows":40}}"#
        )
    }

    func testEncodeResizePane() {
        XCTAssertEqual(
            encodeCommand(.resizePane(dir: .right, amount: 3)),
            #"{"cmd":"resize-pane","args":{"dir":"right","amount":3}}"#
        )
    }

    func testEncodeFocusPane() {
        XCTAssertEqual(
            encodeCommand(.focusPane(dir: .left)),
            #"{"cmd":"focus-pane","args":{"dir":"left"}}"#
        )
    }

    func testEncodeClosePane() {
        XCTAssertEqual(encodeCommand(.closePane), #"{"cmd":"close-pane"}"#)
    }

    func testEncodeListPanes() {
        XCTAssertEqual(encodeCommand(.listPanes), #"{"cmd":"list-panes"}"#)
    }

    // MARK: - Round-trips (encode → decode) for every new command

    private func roundTrip(_ kind: ControlCommandKind, file: StaticString = #file, line: UInt = #line) {
        let json = encodeCommand(kind)
        do {
            let decoded = try JSONDecoder().decode(ControlCommand.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.kind, kind, "round-trip mismatch for \(json)", file: file, line: line)
        } catch {
            XCTFail("decode failed for \(json): \(error)", file: file, line: line)
        }
    }

    func testRoundTripAllCommands() {
        roundTrip(.newTab)
        roundTrip(.closeTab)
        roundTrip(.listTabs)
        roundTrip(.split(.horizontal))
        roundTrip(.split(.vertical))
        roundTrip(.switchTab(index: 0))
        roundTrip(.switchTab(index: 9))
        roundTrip(.sendText("echo \"hi\"\nls\t."))
        roundTrip(.sendText(""))
        roundTrip(.sendKeys(["enter"]))
        roundTrip(.sendKeys(["ctrl-c", "left", "f5"]))
        roundTrip(.resizeWindow(cols: 80, rows: 24))
        roundTrip(.resizePane(dir: .up, amount: 1))
        roundTrip(.resizePane(dir: .down, amount: 5))
        roundTrip(.focusPane(dir: .right))
        roundTrip(.closePane)
        roundTrip(.listPanes)
    }

    // MARK: - ControlCommand decoding (server side)

    func testDecodeNewTab() throws {
        let data = Data(#"{"cmd":"new-tab"}"#.utf8)
        let cmd = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(cmd.kind, .newTab)
    }

    func testDecodeCloseTab() throws {
        let data = Data(#"{"cmd":"close-tab"}"#.utf8)
        let cmd = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(cmd.kind, .closeTab)
    }

    func testDecodeSplitHorizontal() throws {
        let data = Data(#"{"cmd":"split","args":{"dir":"horizontal"}}"#.utf8)
        let cmd = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(cmd.kind, .split(.horizontal))
    }

    func testDecodeSwitchTab() throws {
        let data = Data(#"{"cmd":"switch-tab","args":{"index":3}}"#.utf8)
        let cmd = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(cmd.kind, .switchTab(index: 3))
    }

    func testDecodeUnknownCommandRejected() {
        let data = Data(#"{"cmd":"obliterate-universe"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ControlCommand.self, from: data))
    }

    func testDecodeResizePaneDefaultsAmountToOne() throws {
        // `amount` is optional on the wire; absent → 1.
        let data = Data(#"{"cmd":"resize-pane","args":{"dir":"left"}}"#.utf8)
        let cmd = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(cmd.kind, .resizePane(dir: .left, amount: 1))
    }

    func testDecodeSendKey() throws {
        let data = Data(#"{"cmd":"send-key","args":{"keys":["ctrl-c","enter"]}}"#.utf8)
        let cmd = try JSONDecoder().decode(ControlCommand.self, from: data)
        XCTAssertEqual(cmd.kind, .sendKeys(["ctrl-c", "enter"]))
    }

    // MARK: - keyNameToBytes mapping

    func testKeyMappingNamedKeys() {
        XCTAssertEqual(keyNameToBytes("enter"), [0x0D])
        XCTAssertEqual(keyNameToBytes("return"), [0x0D])
        XCTAssertEqual(keyNameToBytes("tab"), [0x09])
        XCTAssertEqual(keyNameToBytes("esc"), [0x1B])
        XCTAssertEqual(keyNameToBytes("escape"), [0x1B])
        XCTAssertEqual(keyNameToBytes("space"), [0x20])
        XCTAssertEqual(keyNameToBytes("backspace"), [0x7F])
        XCTAssertEqual(keyNameToBytes("delete"), [0x1B, 0x5B, 0x33, 0x7E])
        XCTAssertEqual(keyNameToBytes("backtab"), [0x1B, 0x5B, 0x5A])
    }

    func testKeyMappingArrows() {
        XCTAssertEqual(keyNameToBytes("up"), [0x1B, 0x5B, 0x41])
        XCTAssertEqual(keyNameToBytes("down"), [0x1B, 0x5B, 0x42])
        XCTAssertEqual(keyNameToBytes("right"), [0x1B, 0x5B, 0x43])
        XCTAssertEqual(keyNameToBytes("left"), [0x1B, 0x5B, 0x44])
        XCTAssertEqual(keyNameToBytes("home"), [0x1B, 0x5B, 0x48])
        XCTAssertEqual(keyNameToBytes("end"), [0x1B, 0x5B, 0x46])
        XCTAssertEqual(keyNameToBytes("pageup"), [0x1B, 0x5B, 0x35, 0x7E])
        XCTAssertEqual(keyNameToBytes("pagedown"), [0x1B, 0x5B, 0x36, 0x7E])
    }

    func testKeyMappingCtrlChords() {
        // Ctrl-A = 0x01 ... Ctrl-Z = 0x1a. Same as keyDown's `lower - 0x60`.
        XCTAssertEqual(keyNameToBytes("ctrl-a"), [0x01])
        XCTAssertEqual(keyNameToBytes("ctrl-c"), [0x03])
        XCTAssertEqual(keyNameToBytes("ctrl-d"), [0x04])
        XCTAssertEqual(keyNameToBytes("ctrl-l"), [0x0C])
        XCTAssertEqual(keyNameToBytes("ctrl-z"), [0x1A])
        // Alternate prefixes.
        XCTAssertEqual(keyNameToBytes("control-c"), [0x03])
        XCTAssertEqual(keyNameToBytes("c-c"), [0x03])
    }

    func testKeyMappingCaseAndSeparatorInsensitive() {
        XCTAssertEqual(keyNameToBytes("ENTER"), [0x0D])
        XCTAssertEqual(keyNameToBytes("Ctrl-C"), [0x03])
        XCTAssertEqual(keyNameToBytes("page_up"), [0x1B, 0x5B, 0x35, 0x7E])
        XCTAssertEqual(keyNameToBytes("shift_tab"), [0x1B, 0x5B, 0x5A])
        XCTAssertEqual(keyNameToBytes("  enter  "), [0x0D])
    }

    func testKeyMappingFunctionKeys() {
        XCTAssertEqual(keyNameToBytes("f1"), [0x1B, 0x4F, 0x50])
        XCTAssertEqual(keyNameToBytes("f4"), [0x1B, 0x4F, 0x53])
        XCTAssertEqual(keyNameToBytes("f5"), [0x1B, 0x5B, 0x31, 0x35, 0x7E])
        XCTAssertEqual(keyNameToBytes("f12"), [0x1B, 0x5B, 0x32, 0x34, 0x7E])
    }

    func testKeyMappingUnknownReturnsNil() {
        XCTAssertNil(keyNameToBytes("frobnicate"))
        XCTAssertNil(keyNameToBytes(""))
        XCTAssertNil(keyNameToBytes("ctrl-1"))   // only a..z control chords
        XCTAssertNil(keyNameToBytes("ctrl-cc"))  // single letter required
        XCTAssertNil(keyNameToBytes("f13"))
    }

    func testPanesResponseRoundtrip() throws {
        let r = ControlResponse.panes([
            PaneInfo(index: 0, cols: 80, rows: 24, active: true),
            PaneInfo(index: 1, cols: 40, rows: 24, active: false),
        ])
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ControlResponse.self, from: data)
        XCTAssertEqual(back, r)
        // The ok-only response should still omit panes.
        let okData = try JSONEncoder().encode(ControlResponse.ok())
        XCTAssertFalse(String(data: okData, encoding: .utf8)!.contains("panes"))
    }

    // MARK: - ControlResponse

    func testResponseOkOmitsOptionalFields() throws {
        let r = ControlResponse.ok()
        let data = try JSONEncoder().encode(r)
        let s = String(data: data, encoding: .utf8)!
        XCTAssertEqual(s, #"{"ok":true}"#)
    }

    func testResponseErrIncludesMessage() throws {
        let r = ControlResponse.err("nope")
        let data = try JSONEncoder().encode(r)
        let s = String(data: data, encoding: .utf8)!
        // JSONEncoder does not guarantee key order matches declaration order,
        // so verify via round-trip.
        let back = try JSONDecoder().decode(ControlResponse.self, from: data)
        XCTAssertEqual(back, r)
        XCTAssertTrue(s.contains(#""ok":false"#))
        XCTAssertTrue(s.contains(#""err":"nope""#))
        XCTAssertFalse(s.contains(#""tabs""#))
    }

    func testResponseTabsRoundtrip() throws {
        let r = ControlResponse.tabs([
            TabInfo(index: 0, pane_count: 1),
            TabInfo(index: 1, pane_count: 1),
        ])
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(ControlResponse.self, from: data)
        XCTAssertEqual(back, r)
    }

    // MARK: - runtimeDir / pick

    func testRuntimeDirHonorsXDG() {
        let orig = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"]
        setenv("XDG_RUNTIME_DIR", "/tmp/damson-xdg-test", 1)
        XCTAssertEqual(damsonRuntimeDir(), "/tmp/damson-xdg-test/damson")
        if let v = orig {
            setenv("XDG_RUNTIME_DIR", v, 1)
        } else {
            unsetenv("XDG_RUNTIME_DIR")
        }
    }

    func testPickWithExplicitMissingPidErrors() {
        // No instance with PID 0 ever exists in the runtime environment.
        switch pickDamsonSocket(pid: 0) {
        case .success:
            XCTFail("expected failure for missing pid")
        case .failure(let e):
            XCTAssertTrue(e.message.contains("pid 0"))
        }
    }
}
