import XCTest
@testable import DamsonTerminal

/// Tests for the pure tmux `-CC` control-mode line parser (framing, %output octal decode,
/// each notification, and malformed/unknown-line resilience). No tmux process involved.
final class TmuxControlParserTests: XCTestCase {

    // Feed a sequence of lines and collect the non-nil events.
    private func run(_ lines: [String]) -> [TmuxControlEvent] {
        let p = TmuxControlParser()
        return lines.compactMap { p.feed(line: $0) }
    }

    // MARK: - %begin / %end / %error framing

    func testBeginEndResolvesToReplyWithBodyLines() {
        let events = run([
            "%begin 1700000000 5 1",
            "line one",
            "line two",
            "%end 1700000000 5 1",
        ])
        XCTAssertEqual(events.count, 1)
        guard case .commandReply(let reply) = events[0] else { return XCTFail("expected reply") }
        XCTAssertEqual(reply.timestamp, "1700000000")
        XCTAssertEqual(reply.commandNumber, "5")
        XCTAssertEqual(reply.flags, "1")
        XCTAssertEqual(reply.lines, ["line one", "line two"])
        XCTAssertFalse(reply.isError)
    }

    func testBeginErrorMarksReplyAsError() {
        let events = run([
            "%begin 1700000000 7 0",
            "no such window: @99",
            "%error 1700000000 7 0",
        ])
        XCTAssertEqual(events.count, 1)
        guard case .commandReply(let reply) = events[0] else { return XCTFail("expected reply") }
        XCTAssertTrue(reply.isError)
        XCTAssertEqual(reply.commandNumber, "7")
        XCTAssertEqual(reply.lines, ["no such window: @99"])
    }

    func testEmptyReplyBody() {
        let events = run([
            "%begin 1 2 0",
            "%end 1 2 0",
        ])
        guard case .commandReply(let reply) = events.first else { return XCTFail() }
        XCTAssertEqual(reply.lines, [])
    }

    func testNotificationsInsideBlockAreTreatedAsBodyNotEvents() {
        // Lines that look like notifications but arrive inside a %begin block are reply body,
        // not events (control mode does not interleave notifications inside command output).
        let events = run([
            "%begin 1 3 0",
            "%output %1 not-a-real-notification",
            "%end 1 3 0",
        ])
        XCTAssertEqual(events.count, 1)
        guard case .commandReply(let reply) = events[0] else { return XCTFail() }
        XCTAssertEqual(reply.lines, ["%output %1 not-a-real-notification"])
    }

    func testStrayEndOutsideBlockIsUnhandledNotCrash() {
        let events = run(["%end 1 2 0"])
        guard case .unhandled = events.first else { return XCTFail("expected unhandled") }
    }

    func testCommandReplyMatchesCommandNumberAcrossInterleavedNotifications() {
        // A notification before, a block, and a notification after — the reply carries the
        // command number we can match against the command we sent.
        let events = run([
            "%window-add @1",
            "%begin 100 42 0",
            "ok",
            "%end 100 42 0",
            "%window-add @2",
        ])
        XCTAssertEqual(events.count, 3)
        guard case .windowAdd(let w1) = events[0], w1 == TmuxWindowID(1) else { return XCTFail() }
        guard case .commandReply(let reply) = events[1] else { return XCTFail() }
        XCTAssertEqual(reply.commandNumber, "42")
        guard case .windowAdd(let w2) = events[2], w2 == TmuxWindowID(2) else { return XCTFail() }
    }

    // MARK: - %output octal decode

    func testOutputDecodesCRLFAndBackslash() {
        let events = run([#"%output %2 hello\015\012world\134end"#])
        guard case .output(let pane, let data) = events.first else { return XCTFail() }
        XCTAssertEqual(pane, TmuxPaneID(2))
        XCTAssertEqual(data, Data("hello\r\nworld\\end".utf8))
    }

    func testOutputVerbatimBytesIncludingEscapeSequences() {
        // Escape sequences (ESC = 0x1b is < 32 → arrives as \033) plus verbatim CSI bytes.
        let events = run([#"%output %0 \033[31mRED\033[0m"#])
        guard case .output(_, let data) = events.first else { return XCTFail() }
        XCTAssertEqual(data, Data("\u{1B}[31mRED\u{1B}[0m".utf8))
    }

    func testOutputVerbatimMultibyteUTF8() {
        // Non-control multibyte UTF-8 (한글, emoji) is passed through verbatim.
        let events = run([#"%output %1 \011안녕🍇"#])  // \011 = TAB
        guard case .output(_, let data) = events.first else { return XCTFail() }
        var expected = Data([0x09])
        expected.append(Data("안녕🍇".utf8))
        XCTAssertEqual(data, expected)
    }

    func testOutputEmptyPayload() {
        let events = run(["%output %5"])
        guard case .output(let pane, let data) = events.first else { return XCTFail() }
        XCTAssertEqual(pane, TmuxPaneID(5))
        XCTAssertEqual(data, Data())
    }

    func testTrailingBackslashIsVerbatim() {
        // A backslash not followed by three octal digits is emitted as-is.
        let events = run([#"%output %1 a\b\01"#])
        guard case .output(_, let data) = events.first else { return XCTFail() }
        // \b: backslash then 'b' (not octal) → verbatim "\b" two bytes.
        // \01: backslash then only two digits at end → verbatim "\01" three bytes.
        XCTAssertEqual(data, Data(#"a\b\01"#.utf8))
    }

    func testOctalDecodeDirectly() {
        XCTAssertEqual(TmuxControlParser.decodeOctalEscaped(#"\015"#), Data([0x0D]))
        XCTAssertEqual(TmuxControlParser.decodeOctalEscaped(#"\012"#), Data([0x0A]))
        XCTAssertEqual(TmuxControlParser.decodeOctalEscaped(#"\134"#), Data([0x5C]))
        XCTAssertEqual(TmuxControlParser.decodeOctalEscaped(#"\000"#), Data([0x00]))
        XCTAssertEqual(TmuxControlParser.decodeOctalEscaped(#"\377"#), Data([0xFF]))
        XCTAssertEqual(TmuxControlParser.decodeOctalEscaped("plain"), Data("plain".utf8))
    }

    // MARK: - window notifications

    func testWindowAdd() {
        guard case .windowAdd(let w) = run(["%window-add @7"]).first else { return XCTFail() }
        XCTAssertEqual(w, TmuxWindowID(7))
    }

    func testWindowClose() {
        guard case .windowClose(let w) = run(["%window-close @3"]).first else { return XCTFail() }
        XCTAssertEqual(w, TmuxWindowID(3))
    }

    func testWindowRenamedWithSpacesInName() {
        guard case .windowRenamed(let w, let name) = run(["%window-renamed @2 my shell window"]).first
        else { return XCTFail() }
        XCTAssertEqual(w, TmuxWindowID(2))
        XCTAssertEqual(name, "my shell window")
    }

    func testWindowPaneChanged() {
        guard case .windowPaneChanged(let w, let p) = run(["%window-pane-changed @1 %4"]).first
        else { return XCTFail() }
        XCTAssertEqual(w, TmuxWindowID(1))
        XCTAssertEqual(p, TmuxPaneID(4))
    }

    func testLayoutChangeKeepsRawLayoutAndExtras() {
        let line = "%layout-change @1 e7b2,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bf3a,80x24,0,0 *"
        guard case .layoutChange(let layout) = run([line]).first else { return XCTFail() }
        XCTAssertEqual(layout.window, TmuxWindowID(1))
        XCTAssertEqual(layout.layout, "e7b2,80x24,0,0{40x24,0,0,1,39x24,41,0,2}")
        XCTAssertEqual(layout.extra, ["bf3a,80x24,0,0", "*"])
    }

    // MARK: - session notifications

    func testSessionChanged() {
        guard case .sessionChanged(let s, let name) = run(["%session-changed $0 main"]).first
        else { return XCTFail() }
        XCTAssertEqual(s, TmuxSessionID(0))
        XCTAssertEqual(name, "main")
    }

    func testSessionWindowChanged() {
        guard case .sessionWindowChanged(let s, let w) = run(["%session-window-changed $1 @5"]).first
        else { return XCTFail() }
        XCTAssertEqual(s, TmuxSessionID(1))
        XCTAssertEqual(w, TmuxWindowID(5))
    }

    func testSessionsChanged() {
        guard case .sessionsChanged = run(["%sessions-changed"]).first else { return XCTFail() }
    }

    func testExitWithReason() {
        guard case .exit(let reason) = run(["%exit detached"]).first else { return XCTFail() }
        XCTAssertEqual(reason, "detached")
    }

    func testExitWithoutReason() {
        guard case .exit(let reason) = run(["%exit"]).first else { return XCTFail() }
        XCTAssertNil(reason)
    }

    // MARK: - resilience

    func testUnknownNotificationIsUnhandledNotCrash() {
        guard case .unhandled(let line) = run(["%pane-mode-changed %2"]).first else { return XCTFail() }
        XCTAssertEqual(line, "%pane-mode-changed %2")
    }

    func testBareNonPercentLineIsUnhandled() {
        guard case .unhandled = run(["garbage line without percent"]).first else { return XCTFail() }
    }

    func testMalformedWindowIDIsUnhandled() {
        // `@notanumber` doesn't parse → unhandled rather than a crash or bad ID.
        guard case .unhandled = run(["%window-add @notanumber"]).first else { return XCTFail() }
    }

    func testMalformedSessionChangedMissingTokenIsUnhandled() {
        guard case .unhandled = run(["%session-changed"]).first else { return XCTFail() }
    }

    func testMixedStreamParsesEachLineIndependently() {
        let events = run([
            "%session-changed $0 main",
            "%window-add @1",
            "%layout-change @1 abcd,80x24,0,0,1",
            #"%output %1 \033]0;title\007ready\015\012"#,
            "%window-renamed @1 zsh",
            "%window-close @1",
            "%exit",
        ])
        XCTAssertEqual(events.count, 7)
        guard case .sessionChanged = events[0] else { return XCTFail() }
        guard case .windowAdd = events[1] else { return XCTFail() }
        guard case .layoutChange = events[2] else { return XCTFail() }
        guard case .output(let pane, _) = events[3], pane == TmuxPaneID(1) else { return XCTFail() }
        guard case .windowRenamed = events[4] else { return XCTFail() }
        guard case .windowClose = events[5] else { return XCTFail() }
        guard case .exit = events[6] else { return XCTFail() }
    }
}
