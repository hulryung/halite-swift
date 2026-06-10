import XCTest
@testable import DamsonTerminal

/// Integration tests that drive a REAL `tmux -C` control client. `TmuxControlClient`
/// forkpty's tmux itself, so these run headlessly (no display). They are GUARDED: if tmux
/// isn't on PATH, each test `throw`s `XCTSkip(...)` so CI without tmux stays green.
///
/// Isolation: every test points tmux at a private `TMUX_TMPDIR` socket dir so it never
/// touches a real user tmux server, and kills that server on teardown.
final class TmuxControlClientIntegrationTests: XCTestCase {

    // MARK: - tmux discovery / isolation

    /// Absolute path to a `tmux` binary on PATH (incl. the common Homebrew prefix), or nil.
    private static func findTmux() -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
        for d in dirs {
            let p = d + "/tmux"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private var tmuxDir: String!

    override func setUpWithError() throws {
        guard Self.findTmux() != nil else {
            throw XCTSkip("tmux not found on PATH — skipping real-tmux integration test")
        }
        // Private socket dir so we never touch the user's tmux server. Keep the path SHORT:
        // tmux's socket is `<TMUX_TMPDIR>/tmux-<uid>/default`, and a Unix-domain socket path
        // can't exceed ~104 bytes on macOS, so the long `/private/var/folders/...` temp dir
        // overflows. Use a short `/tmp` path with a small random suffix.
        tmuxDir = "/tmp/dtmux\(UInt16.random(in: 0...65535))"
        try? FileManager.default.removeItem(atPath: tmuxDir)
        try FileManager.default.createDirectory(atPath: tmuxDir, withIntermediateDirectories: true)
        setenv("TMUX_TMPDIR", tmuxDir, 1)
        // Make sure the Homebrew prefix is on PATH for the spawned `/usr/bin/env tmux`.
        if let tmux = Self.findTmux() {
            let binDir = (tmux as NSString).deletingLastPathComponent
            let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
            if !path.split(separator: ":").map(String.init).contains(binDir) {
                setenv("PATH", binDir + ":" + path, 1)
            }
        }
    }

    override func tearDownWithError() throws {
        // Best-effort: kill the isolated server so nothing lingers.
        if let dir = tmuxDir {
            let task = Process()
            task.launchPath = "/usr/bin/env"
            task.arguments = ["tmux", "kill-server"]
            var env = ProcessInfo.processInfo.environment
            env["TMUX_TMPDIR"] = dir
            task.environment = env
            try? task.run()
            task.waitUntilExit()
            try? FileManager.default.removeItem(atPath: dir)
        }
        unsetenv("TMUX_TMPDIR")
    }

    // MARK: - runloop pump

    private func pump(until predicate: () -> Bool, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Run a tmux CLI command against the isolated test server (TMUX_TMPDIR is in env).
    /// Returns the exit status (nonzero = failure, e.g. `has-session` on a missing session).
    @discardableResult
    private func tmuxCLI(_ args: [String]) -> Int32 {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["tmux"] + args
        task.environment = ProcessInfo.processInfo.environment
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    // MARK: - Tests

    /// Attaching a fresh `tmux -C new-session` must yield well-formed `%begin/%end` frames
    /// (the first one is NOT `.unhandled`, which was BUG 1) and deliver real `%output` for
    /// the pane, octal-decoded.
    func testAttachReceivesFramedReplyAndPaneOutput() throws {
        let client = TmuxControlClient()
        defer { client.terminate() }

        var replies: [TmuxCommandReply] = []
        var unhandled: [String] = []
        var outputByPane: [TmuxPaneID: Data] = [:]
        var firstPane: TmuxPaneID?

        client.onCommandReply = { replies.append($0) }
        client.onUnhandled = { unhandled.append($0) }
        client.onPaneOutput = { pane, data in
            if firstPane == nil { firstPane = pane }
            outputByPane[pane, default: Data()].append(data)
        }

        try client.attach(target: nil, cols: 80, rows: 24)

        // Wait until we've seen at least one framed reply (the startup %begin/%end block).
        pump(until: { !replies.isEmpty })
        XCTAssertFalse(replies.isEmpty, "expected at least one %begin/%end reply on attach")

        // BUG 1 regression: the startup reply block must NOT have leaked into .unhandled.
        // (With -CC the first line was `\u{1B}P1000p%begin …` → unhandled; with -C + the
        // defensive strip, it frames correctly.)
        XCTAssertFalse(unhandled.contains { $0.contains("%begin") || $0.contains("%end") },
                       "startup %begin/%end leaked into .unhandled: \(unhandled)")

        // Drive output: send a marker through the active pane and assert it round-trips as
        // octal-decoded %output. We learn the pane id from the first %output (the shell
        // prompt) or by issuing a layout/list — simplest is to wait for ANY output, capture
        // its pane, then echo a unique marker into that pane and look for it.
        pump(until: { firstPane != nil }, timeout: 8)
        let pane = try XCTUnwrap(firstPane, "no %output (and thus no pane id) seen on attach")

        let marker = "TMUXMARK_\(UUID().uuidString.prefix(8))"
        outputByPane[pane] = Data()  // reset so we only match new output
        client.sendKeys(to: pane, data: Data("printf '\(marker)\\n'\n".utf8))

        pump(until: {
            guard let d = outputByPane[pane] else { return false }
            return String(decoding: d, as: UTF8.self).contains(marker)
        })

        let seen = String(decoding: outputByPane[pane] ?? Data(), as: UTF8.self)
        XCTAssertTrue(seen.contains(marker),
                      "expected pane %\(pane.raw) output to contain \(marker); got: \(seen.debugDescription)")
        // The output must be octal-DECODED bytes (e.g. a real newline 0x0A, not literal \012).
        XCTAssertTrue((outputByPane[pane] ?? Data()).contains(0x0A),
                      "expected a decoded LF (0x0A) in pane output, not a literal \\012 escape")
    }

    /// BUG 2 data-path proof (headless): bytes arriving as `%output` from a REAL tmux client
    /// reach a `DamsonSession`'s Grid through the SAME path a local PTY uses — i.e. via
    /// `TmuxPaneBackend.deliver` → `DamsonSession.onData` → `VTParser` → `Grid`. This mirrors
    /// what `TmuxIntegrationController` wires up, but stays in the testable DamsonTerminal
    /// module. The on-SCREEN render still needs a GUI re-test; this proves the data path.
    func testPaneOutputReachesDamsonSessionGrid() throws {
        let client = TmuxControlClient()
        defer { client.terminate() }

        // Per-pane backend + session, created lazily on first sighting of a pane — exactly
        // like TmuxIntegrationController.ensureTab.
        var backends: [TmuxPaneID: TmuxPaneBackend] = [:]
        var sessions: [TmuxPaneID: DamsonSession] = [:]

        func ensureSession(_ pane: TmuxPaneID) {
            guard sessions[pane] == nil else { return }
            let backend = TmuxPaneBackend(client: client, pane: pane)
            let session = DamsonSession(config: DamsonConfig(), backend: backend)
            backends[pane] = backend
            sessions[pane] = session
        }

        client.onPaneOutput = { pane, data in
            ensureSession(pane)        // lazy create (BUG 2 #2: don't drop first output)
            backends[pane]?.deliver(data)   // BUG 2 #3: feed the SAME onData path as local PTY
        }

        try client.attach(target: nil, cols: 80, rows: 24)

        // Wait for a pane/session to materialize from the prompt output.
        pump(until: { !sessions.isEmpty })
        let pane = try XCTUnwrap(sessions.keys.first, "no pane/session created from %output")
        let session = try XCTUnwrap(sessions[pane])

        // Echo a unique marker and assert it lands in the session's GRID (not just the raw
        // callback) — i.e. it went through VTParser into Grid cells.
        let marker = "GRIDMARK\(Int.random(in: 1000...9999))"
        client.sendKeys(to: pane, data: Data("printf '\(marker)\\n'\n".utf8))

        func gridText(_ g: Grid) -> String {
            var phys: [[Cell]] = g.scrollback.map { $0.cells }
            for r in 0..<g.rows { phys.append(g.row(r)) }
            var s = ""
            for cells in phys {
                for c in cells where !c.isContinuation && !c.isWideSpacer { s.append(c.char) }
                s.append("\n")
            }
            return s
        }

        pump(until: { gridText(session.grid).contains(marker) })
        XCTAssertTrue(gridText(session.grid).contains(marker),
                      "tmux %output did not reach the DamsonSession Grid via TmuxPaneBackend; grid was:\n" +
                      gridText(session.grid))
    }

    /// P2 driver proof (headless): a real `split-window -h` makes tmux emit a `%layout-change`
    /// whose layout string parses into a two-leaf horizontal split — exactly the input
    /// `TmuxIntegrationController` folds into a native Damson split. We verify the REAL tmux
    /// layout flowing through the client parses to the structure the reconciler consumes.
    func testSplitWindowYieldsTwoPaneLayout() throws {
        let client = TmuxControlClient()
        defer { client.terminate() }

        var lastLayout: TmuxLayout?
        client.onLayoutChange = { _, layout in lastLayout = layout }

        try client.attach(target: nil, cols: 80, rows: 24)

        // The initial active-window layout (single pane) arrives via the refresh-client at
        // attach. Wait for it, then split and wait for the two-pane layout.
        pump(until: { lastLayout != nil })
        let single = try XCTUnwrap(lastLayout.flatMap { TmuxLayoutTree.parse($0.layout) },
                                   "no initial %layout-change parsed on attach")
        XCTAssertEqual(single.paneIDs.count, 1, "fresh session should start as one pane")

        lastLayout = nil
        client.sendCommand("split-window -h")
        pump(until: {
            guard let l = lastLayout.flatMap({ TmuxLayoutTree.parse($0.layout) }) else { return false }
            return l.paneIDs.count == 2
        })

        let split = try XCTUnwrap(lastLayout.flatMap { TmuxLayoutTree.parse($0.layout) },
                                  "no %layout-change after split-window")
        XCTAssertEqual(split.paneIDs.count, 2, "split-window -h should yield two panes")
        guard case let .split(orientation, _, _, _, _, children) = split else {
            return XCTFail("expected a split layout, got a leaf: \(split)")
        }
        XCTAssertEqual(orientation, .horizontal, "split-window -h is a left/right (horizontal) split")
        XCTAssertEqual(children.count, 2)
    }

    /// P3-2 flow-control proof (headless): with `pause-after` enabled, tmux switches a pane's
    /// output to `%extended-output`, which the parser maps to the same `.output` event — so a
    /// marker still round-trips through the normal output path. (Forcing an actual `%pause`
    /// is timing-dependent and flaky, so we assert the extended-output path instead.)
    func testFlowControlExtendedOutputStillDelivers() throws {
        let client = TmuxControlClient()
        defer { client.terminate() }

        var outputByPane: [TmuxPaneID: Data] = [:]
        var firstPane: TmuxPaneID?
        client.onPaneOutput = { pane, data in
            if firstPane == nil { firstPane = pane }
            outputByPane[pane, default: Data()].append(data)
        }

        try client.attach(target: nil, cols: 80, rows: 24)
        client.enableFlowControl(pauseAfter: 1)  // → output now arrives as %extended-output

        pump(until: { firstPane != nil })
        let pane = try XCTUnwrap(firstPane, "no pane seen on attach")

        let marker = "FLOWMARK_\(UUID().uuidString.prefix(8))"
        outputByPane[pane] = Data()
        client.sendKeys(to: pane, data: Data("printf '\(marker)\\n'\n".utf8))

        pump(until: {
            String(decoding: outputByPane[pane] ?? Data(), as: UTF8.self).contains(marker)
        })
        let seen = String(decoding: outputByPane[pane] ?? Data(), as: UTF8.self)
        XCTAssertTrue(seen.contains(marker),
                      "marker did not arrive via %extended-output under flow control; got: \(seen.debugDescription)")
        // Decoded bytes (real LF), proving the octal decode ran on the extended-output payload.
        XCTAssertTrue((outputByPane[pane] ?? Data()).contains(0x0A),
                      "expected a decoded LF in extended-output payload")
    }

    /// P3-3 reply correlation: `sendCommand(onReply:)` must receive ITS OWN command's
    /// `%begin/%end` block — not the connect-time guard block (flags 0) and not another
    /// command's. Two commands sent back-to-back must resolve in order with the right bodies.
    func testCommandReplyCorrelation() throws {
        let client = TmuxControlClient()
        defer { client.terminate() }

        try client.attach(target: nil, cols: 80, rows: 24)

        var first: TmuxCommandReply?
        var second: TmuxCommandReply?
        client.sendCommand("display-message -p FIRSTREPLY") { first = $0 }
        client.sendCommand("display-message -p SECONDREPLY") { second = $0 }

        pump(until: { first != nil && second != nil })
        XCTAssertEqual(try XCTUnwrap(first).lines, ["FIRSTREPLY"],
                       "first handler got the wrong reply body")
        XCTAssertEqual(try XCTUnwrap(second).lines, ["SECONDREPLY"],
                       "second handler got the wrong reply body")
        XCTAssertFalse(try XCTUnwrap(first).isError)
    }

    /// P3-3 attach to an EXISTING session: list-windows must report the pre-existing
    /// window's id+layout (the enumeration the controller uses), and capture-pane must
    /// return content printed BEFORE we attached (the backfill source).
    func testEnumerationAndCapturePaneOnExistingSession() throws {
        let marker = "PREEXIST_\(UInt32.random(in: 1000...99999))"
        // Build the session before any control client attaches: one window, split into two
        // panes, marker printed in pane 0.
        tmuxCLI(["new-session", "-d", "-s", "pre", "-x", "80", "-y", "24"])
        tmuxCLI(["send-keys", "-t", "pre", "printf '\(marker)\\n'", "Enter"])
        tmuxCLI(["split-window", "-h", "-t", "pre"])
        Thread.sleep(forTimeInterval: 0.4)  // let the shell print the marker

        let client = TmuxControlClient()
        defer { client.terminate() }
        try client.attach(target: "pre", cols: 80, rows: 24)

        // Enumerate: the existing window must come back with a two-pane layout.
        var layoutLine: String?
        client.sendCommand("list-windows -F \"#{window_id} #{window_layout}\"") { reply in
            layoutLine = reply.lines.first
        }
        pump(until: { layoutLine != nil })
        let fields = try XCTUnwrap(layoutLine).split(separator: " ").map(String.init)
        XCTAssertEqual(fields.count, 2)
        XCTAssertNotNil(TmuxWindowID(token: fields[0]))
        let tree = try XCTUnwrap(TmuxLayoutTree.parse(fields[1]),
                                 "layout from list-windows must parse: \(fields[1])")
        XCTAssertEqual(tree.paneIDs.count, 2, "expected the pre-made split to show 2 panes")

        // Backfill: capture-pane on the first pane must contain the pre-attach marker.
        let firstPane = tree.paneIDs[0]
        var captured: [String]?
        client.sendCommand("capture-pane -peqJ -t \(firstPane.token) -S -2000") { reply in
            captured = reply.isError ? [] : reply.lines
        }
        pump(until: { captured != nil })
        let content = (captured ?? []).joined(separator: "\n")
        XCTAssertTrue(content.contains(marker),
                      "capture-pane should return pre-attach content; got: \(content.prefix(500))")
    }

    /// P3-4 DCS auto-detect end-to-end with REAL tmux: a DamsonSession whose child is
    /// `tmux -CC new-session` (what running it in a pane looks like to the PTY) must (1)
    /// post the takeover notification, (2) deliver the control stream — including the
    /// remainder glued to the DCS introducer — into a TmuxControlClient via
    /// TmuxTakeoverBackend, (3) round-trip input via send-keys, and (4) restore normal
    /// parsing after %exit (kill-server).
    func testDCSTakeoverEndToEnd() throws {
        var config = DamsonConfig()
        config.argv = ["/usr/bin/env", "tmux", "-CC", "new-session"]
        config.env = ProcessInfo.processInfo.environment
        config.env["TERM"] = "xterm-256color"

        var client: TmuxControlClient?
        var windowAdds: [TmuxWindowID] = []
        var outputByPane: [TmuxPaneID: Data] = [:]
        var firstPane: TmuxPaneID?
        var sawExit = false

        // The app-side observer: create the takeover backend+client synchronously inside
        // the notification (the contract that preserves the post-DCS remainder).
        let observer = NotificationCenter.default.addObserver(
            forName: DamsonSession.tmuxControlModeDetectedNotification, object: nil, queue: nil
        ) { note in
            guard let session = note.object as? DamsonSession else { return }
            let c = TmuxControlClient(backend: TmuxTakeoverBackend(session: session))
            c.onWindowAdd = { windowAdds.append($0) }
            c.onPaneOutput = { pane, data in
                if firstPane == nil { firstPane = pane }
                outputByPane[pane, default: Data()].append(data)
            }
            c.onExit = { _ in sawExit = true }
            c.adoptStream(cols: 80, rows: 24)
            client = c
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let session = DamsonSession(config: config)
        defer { session.terminate() }

        pump(until: { client != nil })
        XCTAssertNotNil(client, "tmux -CC DCS was not detected / notification not posted")
        XCTAssertTrue(session.inTmuxControlMode)

        pump(until: { !windowAdds.isEmpty })
        XCTAssertFalse(windowAdds.isEmpty,
                       "%window-add did not flow through the takeover backend (startup frame lost?)")

        // Input round-trip through the taken-over stream.
        pump(until: { firstPane != nil })
        let pane = try XCTUnwrap(firstPane)
        let marker = "TAKEOVER_\(UInt32.random(in: 1000...99999))"
        outputByPane[pane] = Data()
        client?.sendKeys(to: pane, data: Data("printf '\(marker)\\n'\n".utf8))
        pump(until: {
            String(decoding: outputByPane[pane] ?? Data(), as: UTF8.self).contains(marker)
        })
        XCTAssertTrue(String(decoding: outputByPane[pane] ?? Data(), as: UTF8.self).contains(marker),
                      "send-keys through the takeover stream did not round-trip")

        // Kill the server → %exit → the session must resume normal parsing.
        client?.sendCommand("kill-server")
        pump(until: { sawExit })
        XCTAssertTrue(sawExit, "%exit did not arrive after kill-server")
        session.endTmuxControlMode()
        XCTAssertFalse(session.inTmuxControlMode)
    }

    /// Detach semantics (window close / tmux ▸ Detach): `requestDetach` must end the
    /// control connection with `%exit` while LEAVING THE SESSION ALIVE server-side, and the
    /// `kill-pane`s that the closing window's terminate sweep fires afterwards must be
    /// suppressed — this is the regression test for "closing the tmux window destroyed the
    /// session instead of detaching".
    func testDetachLeavesSessionAlive() throws {
        tmuxCLI(["new-session", "-d", "-s", "keep", "-x", "80", "-y", "24"])

        let client = TmuxControlClient()
        defer { client.terminate() }
        var sawExit = false
        var firstPane: TmuxPaneID?
        client.onExit = { _ in sawExit = true }
        client.onPaneOutput = { pane, _ in if firstPane == nil { firstPane = pane } }
        try client.attach(target: "keep", cols: 80, rows: 24)

        // Make sure the connection is fully up (a pane id has been seen).
        client.sendKeys(to: TmuxPaneID(0), data: Data("echo hello\n".utf8))
        pump(until: { firstPane != nil })

        client.requestDetach()
        // What windowWillClose's terminate sweep does right after the detach request:
        let pane = try XCTUnwrap(firstPane)
        client.killPane(pane)  // must be suppressed by isDetaching

        pump(until: { sawExit })
        XCTAssertTrue(sawExit, "%exit did not arrive after detach-client")

        // The session — and its pane — must still exist on the server.
        XCTAssertEqual(tmuxCLI(["has-session", "-t", "keep"]), 0,
                       "detach must leave the session alive")
        XCTAssertEqual(tmuxCLI(["list-panes", "-t", "keep"]), 0,
                       "the pane must have survived the post-detach kill-pane attempt")
    }
}
