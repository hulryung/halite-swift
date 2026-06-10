import XCTest
@testable import DamsonTerminal

/// Regression tests for output-flood handling (the `yes`-freeze): the PTY read side must
/// coalesce bytes into one main-thread drain per runloop turn (bounded backlog) instead of
/// enqueueing one main-queue block per 4KB read, and the tmux control client must coalesce
/// consecutive `%output` lines per pane.
final class PTYFloodTests: XCTestCase {

    private func pump(until predicate: () -> Bool, timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Flood ~8MB through a real PTY into a deliberately SLOW consumer (5ms per callback,
    /// standing in for VTParser+render work). The property under test: when the main thread
    /// can't keep up, bytes must coalesce into fewer, larger drains with a bounded backlog.
    /// With the old per-read delivery the PTY's small chunks (≈0.3–4KB each) would make
    /// ~tens of thousands of callbacks × 5ms ≈ minutes — blowing the timeout; with read-side
    /// coalescing each 5ms of consumer work batches ~hundreds of KB into one drain and the
    /// whole flood lands in seconds.
    func testFloodIsCoalescedIntoFewMainThreadDrains() throws {
        let pty = PTYHost()
        var callbackCount = 0
        var totalBytes = 0
        var sawDone = false
        var tail = Data()
        pty.onData = { chunk in
            callbackCount += 1
            totalBytes += chunk.count
            // Track the stream tail so the DONE marker is found even across chunk seams.
            tail.append(chunk)
            if tail.count > 4096 { tail.removeFirst(tail.count - 4096) }
            if String(decoding: tail, as: UTF8.self).contains("ZZDONEZZ") { sawDone = true }
            Thread.sleep(forTimeInterval: 0.005)  // simulate parse/render cost per drain
        }

        let bytes = 8_000_000
        try pty.spawn(
            argv: ["/bin/sh", "-c", "yes | head -c \(bytes); printf ZZDONEZZ"],
            env: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"],
            cwd: nil, cols: 80, rows: 24
        )
        defer { pty.terminate() }

        pump(until: { sawDone })
        XCTAssertTrue(sawDone,
                      "flood did not complete in time — slow consumer was not coalesced " +
                      "(got \(totalBytes) bytes in \(callbackCount) callbacks)")
        // PTY postprocessing turns "y\n" into "y\r\n", so ≥ the generator's byte count.
        XCTAssertGreaterThanOrEqual(totalBytes, bytes)
        // Each 5ms-busy drain must have batched well beyond one raw read's worth: require
        // ≥5KB/callback on average (old behavior averaged ~350B/callback).
        let avg = totalBytes / max(callbackCount, 1)
        XCTAssertGreaterThan(avg, 5_000,
                             "drains too small (avg \(avg) B over \(callbackCount) callbacks) — " +
                             "read-side coalescing regressed")
    }

    /// The tmux control client must merge consecutive `%output` lines for the same pane that
    /// arrive in one stdout chunk into a single onPaneOutput callback (order with non-output
    /// events preserved) — the same flood property at the control-protocol layer.
    func testTmuxClientCoalescesConsecutivePaneOutput() {
        final class FakeBackend: SessionIOBackend {
            var onData: ((Data) -> Void)?
            var onExit: ((Int32) -> Void)?
            func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
            func write(_ data: Data) {}
            func resize(cols: Int, rows: Int) {}
            func terminate() {}
            var childWorkingDirectory: String? { nil }
            var isRunningForegroundJob: Bool { false }
        }

        let backend = FakeBackend()
        let client = TmuxControlClient(backend: backend)
        var outputs: [(pane: TmuxPaneID, data: Data)] = []
        var windowAdds: [TmuxWindowID] = []
        client.onPaneOutput = { outputs.append(($0, $1)) }
        client.onWindowAdd = { windowAdds.append($0) }

        // One stdout chunk carrying: 3 consecutive outputs for %1, a window-add (must flush
        // and preserve order), 2 outputs for %1 again, then 1 for %2 (pane switch flushes).
        let chunk = """
        %output %1 aa
        %output %1 bb
        %output %1 cc
        %window-add @7
        %output %1 dd
        %output %1 ee
        %output %2 ff
        """.split(separator: "\n").map { $0 + "\r\n" }.joined()
        backend.onData?(Data(chunk.utf8))

        XCTAssertEqual(windowAdds, [TmuxWindowID(7)])
        XCTAssertEqual(outputs.count, 3, "expected 3 coalesced runs, got \(outputs.count)")
        XCTAssertEqual(outputs[0].pane, TmuxPaneID(1))
        XCTAssertEqual(outputs[0].data, Data("aabbcc".utf8))
        XCTAssertEqual(outputs[1].pane, TmuxPaneID(1))
        XCTAssertEqual(outputs[1].data, Data("ddee".utf8))
        XCTAssertEqual(outputs[2].pane, TmuxPaneID(2))
        XCTAssertEqual(outputs[2].data, Data("ff".utf8))
    }

    /// A line split across two chunks must still parse once completed (the single-pass
    /// scanner keeps the partial tail).
    func testTmuxClientHandlesLineSplitAcrossChunks() {
        final class FakeBackend: SessionIOBackend {
            var onData: ((Data) -> Void)?
            var onExit: ((Int32) -> Void)?
            func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {}
            func write(_ data: Data) {}
            func resize(cols: Int, rows: Int) {}
            func terminate() {}
            var childWorkingDirectory: String? { nil }
            var isRunningForegroundJob: Bool { false }
        }
        let backend = FakeBackend()
        let client = TmuxControlClient(backend: backend)
        var outputs: [(pane: TmuxPaneID, data: Data)] = []
        client.onPaneOutput = { outputs.append(($0, $1)) }

        backend.onData?(Data("%output %3 hel".utf8))
        XCTAssertTrue(outputs.isEmpty, "partial line must not be delivered")
        backend.onData?(Data("lo\r\n%output %3 world\r\n".utf8))
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0].data, Data("helloworld".utf8))
    }
}
