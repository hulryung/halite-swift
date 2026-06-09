import XCTest
@testable import DamsonTerminal

/// Diagnostic: dump the raw escape bytes the shell emits on SIGWINCH so we can see
/// the reset-prompt clear sequence that eats scrollback. Prints; we read the output.
/// Skipped unless DAMSON_PTY_DIAG=1.
final class PTYResizeDiagTests: XCTestCase {
    private func runDump(argv: [String], setup: [String]) {
        let pty = PTYHost()
        var buf = Data()
        pty.onData = { buf.append($0) }
        var env = DamsonConfig.defaultEnv()
        env["TERM"] = "xterm-256color"
        try? pty.spawn(argv: argv, env: env, cwd: NSTemporaryDirectory(), cols: 80, rows: 24)
        defer { pty.terminate() }
        func settle(_ t: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }
        func dump(_ label: String) {
            let s = String(decoding: buf, as: UTF8.self)
            let esc = s.replacingOccurrences(of: "\u{1b}", with: "\\e")
                       .replacingOccurrences(of: "\r", with: "\\r")
                       .replacingOccurrences(of: "\u{07}", with: "\\a")
                       .replacingOccurrences(of: "\n", with: "\\n\n")
            print("==== \(label) [\(argv.joined(separator: " "))] ====\n\(esc)\n==== end ====")
            buf.removeAll()
        }
        settle(1.2)   // let rc / starship load
        for cmd in setup { pty.write(Data((cmd + "\n").utf8)); settle(0.5) }
        pty.write(Data("for i in 1 2 3 4 5; do print \"ROW$i-marker\"; done\n".utf8))
        settle(0.7)
        dump("baseline (initial prompt + output)")
        pty.resize(cols: 30, rows: 24); settle(0.7); dump("narrow 80->30")
        pty.resize(cols: 80, rows: 24); settle(0.7); dump("widen 30->80")
    }

    /// Real interactive zsh with the user's rc (→ starship if configured). Shows the
    /// actual prompt structure + whether OSC 133 marks are emitted, and the exact
    /// resize redraw sequences.
    func testDumpRealShellResizeSequences() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DAMSON_PTY_DIAG"] == "1",
                          "set DAMSON_PTY_DIAG=1 to run the diagnostic")
        runDump(argv: ["/bin/zsh", "-i"], setup: [])
    }
}
