import XCTest
@testable import DamsonTerminal

/// Replay harness for `DAMSON_DUMP_OUTPUT` captures (docs/TMUX-INTEGRATION.md §15.2):
/// feeds a captured raw output stream through the same DamsonSession → VTParser → Grid
/// path the app uses, then prints the final visible grid and scans for corruption
/// (U+FFFD cells). Point it at a capture with:
///
///   DAMSON_REPLAY_DUMP=/tmp/damson-dump/session-XXX.bin swift test --filter OutputDumpReplay
///
/// Optional: DAMSON_REPLAY_SIZE=colsxrows (default 130x42), DAMSON_REPLAY_CHUNK=N to
/// replay in fixed N-byte chunks (default: a deterministic mix of sizes to exercise
/// chunk-boundary handling the way PTY reads + the drain cap produce them).
final class OutputDumpReplayTests: XCTestCase {
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

    func testReplayCapturedDump() throws {
        guard let path = ProcessInfo.processInfo.environment["DAMSON_REPLAY_DUMP"],
              !path.isEmpty else {
            throw XCTSkip("set DAMSON_REPLAY_DUMP=<capture.bin> to replay a session dump")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))

        var cols = 130, rows = 42
        if let size = ProcessInfo.processInfo.environment["DAMSON_REPLAY_SIZE"] {
            let p = size.lowercased().split(separator: "x")
            if p.count == 2, let c = Int(p[0]), let r = Int(p[1]) { cols = c; rows = r }
        }

        let backend = FakeBackend()
        let session = DamsonSession(config: DamsonConfig(), backend: backend)
        session.resize(cols: cols, rows: rows)

        // Chunking: fixed size if requested, else a deterministic varied pattern (prime
        // strides) so codepoint/escape splits at boundaries are exercised like real reads.
        let fixed = ProcessInfo.processInfo.environment["DAMSON_REPLAY_CHUNK"].flatMap(Int.init)
        let strides = fixed.map { [$0] } ?? [4096, 7, 65536, 1, 131072, 3, 1024]
        var i = 0, s = 0
        while i < bytes.count {
            let n = min(strides[s % strides.count], bytes.count - i)
            backend.onData?(bytes.subdata(in: i..<(i + n)))
            i += n
            s += 1
        }

        // Final visible grid.
        let g = session.grid
        var screen: [String] = []
        for r in 0..<g.rows {
            var line = ""
            for c in g.row(r) where !c.isContinuation && !c.isWideSpacer { line.append(c.char) }
            screen.append(line)
        }
        print("==== REPLAY: \(path) (\(bytes.count) bytes @ \(cols)x\(rows)) ====")
        for (n, line) in screen.enumerated() { print(String(format: "%3d|%@", n, line)) }
        print("==== scrollback: \(g.scrollback.count) lines ====")

        // Corruption scan: replacement characters anywhere (visible + scrollback).
        let fffd = Character("\u{FFFD}")
        var hits: [String] = []
        for (n, line) in screen.enumerated() where line.contains(fffd) {
            hits.append("row \(n): \(line)")
        }
        for (n, sbLine) in g.scrollback.enumerated() {
            let text = String(sbLine.cells.filter { !$0.isContinuation && !$0.isWideSpacer }
                .map(\.char))
            if text.contains(fffd) { hits.append("scrollback \(n): \(text)") }
        }
        XCTAssertTrue(hits.isEmpty, "U+FFFD cells found:\n" + hits.joined(separator: "\n"))
    }
}
