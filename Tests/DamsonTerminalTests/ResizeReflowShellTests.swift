import XCTest
@testable import DamsonTerminal

/// Integration: drive a REAL interactive zsh through the PTY, fill the screen with
/// numbered lines, then resize narrow→wide while sitting at the prompt. Reproduces
/// the field bug where, on resize, the shell's SIGWINCH prompt redraw (zsh
/// `reset-prompt`, e.g. starship re-rendering with a new clock) clears lines and
/// scrollback content vanishes — even though the pure grid reflow preserves it.
final class ResizeReflowShellTests: XCTestCase {
    private func pump(until predicate: () -> Bool, timeout: TimeInterval = 4) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
    private func settle(_ t: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(t))
    }

    /// All grid text (scrollback + viewport), wrapped rows rejoined, as a set of
    /// non-empty trimmed logical lines — for "is ROWn still present" checks.
    private func allText(_ g: Grid) -> [String] {
        var phys: [(cells: [Cell], wrapped: Bool)] = g.scrollback.map { ($0.cells, $0.wrapped) }
        for r in 0..<g.rows { phys.append((g.row(r), g.rowWrapped(r))) }
        var out: [String] = []
        var cur = ""
        for (cells, wrapped) in phys {
            for c in cells where !c.isContinuation && !c.isWideSpacer { cur.append(c.char) }
            if !wrapped { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" }
        }
        if !cur.isEmpty { out.append(cur.trimmingCharacters(in: .whitespaces)) }
        return out
    }

    func testShellResizeDoesNotEraseScrollback() throws {
        // Interactive zsh, no rc, controlled long prompt so it wraps at narrow widths.
        var env = DamsonConfig.defaultEnv()
        env["TERM"] = "xterm-256color"
        let config = DamsonConfig(argv: ["/bin/zsh", "-fi"], env: env, cwd: NSTemporaryDirectory())
        let session = DamsonSession(config: config)
        defer { session.terminate() }

        // Wait for the shell to come up (grid gets any content).
        pump(until: { session.grid.scrollback.count + self.nonBlank(session.grid) > 0 })
        settle(0.3)

        // A long prompt that wraps under ~30 cols but fits at 80.
        session.write(Data("PROMPT='ZSHPROMPTzshpromptZSHPROMPTzshprompt%# '\n".utf8))
        settle(0.3)
        // Print 40 distinct lines, then return to the prompt.
        session.write(Data("for i in $(seq 1 40); do print \"ROW$i-marker\"; done\n".utf8))
        pump(until: { self.allText(session.grid).contains { $0.hasPrefix("ROW40-marker") } })
        settle(0.3)

        let before = Set(allText(session.grid))
        let present0 = (1...40).filter { i in before.contains { $0.hasPrefix("ROW\(i)-marker") } }
        XCTAssertEqual(present0.count, 40, "precondition: all 40 ROWn lines printed")

        // Resize narrow then wide while idle at the prompt → triggers SIGWINCH
        // prompt redraws on each step.
        for (c, r) in [(24, 24), (80, 24), (18, 24), (80, 24)] {
            session.resize(cols: c, rows: r)
            settle(0.35)
        }
        settle(0.3)

        let after = Set(allText(session.grid))
        let survived = (1...40).filter { i in after.contains { $0.hasPrefix("ROW\(i)-marker") } }
        XCTAssertEqual(survived.count, 40,
                       "after resize cycles, missing rows: " +
                       (1...40).filter { i in !after.contains { $0.hasPrefix("ROW\(i)-marker") } }
                        .map(String.init).joined(separator: ","))
    }

    /// Same, but with a TWO-line prompt (an info line + an input line, like
    /// starship) whose info line is short enough that it doesn't wrap — the common
    /// real-world shape. Content above must still survive resize.
    func testTwoLinePromptResizeKeepsScrollback() throws {
        var env = DamsonConfig.defaultEnv()
        env["TERM"] = "xterm-256color"
        let config = DamsonConfig(argv: ["/bin/zsh", "-fi"], env: env, cwd: NSTemporaryDirectory())
        let session = DamsonSession(config: config)
        defer { session.terminate() }
        pump(until: { session.grid.scrollback.count + self.nonBlank(session.grid) > 0 })
        settle(0.3)
        // Info line "dkkang dev 12:00" + input "> " — mirrors a starship 2-liner.
        session.write(Data("PROMPT=$'dkkang dev clock\\n> '\n".utf8))
        settle(0.3)
        session.write(Data("for i in $(seq 1 40); do print \"ROW$i-marker\"; done\n".utf8))
        pump(until: { self.allText(session.grid).contains { $0.hasPrefix("ROW40-marker") } })
        settle(0.3)

        for (c, r) in [(28, 24), (80, 24), (20, 24), (80, 24)] {
            session.resize(cols: c, rows: r); settle(0.35)
        }
        settle(0.3)
        let after = Set(allText(session.grid))
        let survived = (1...40).filter { i in after.contains { $0.hasPrefix("ROW\(i)-marker") } }
        XCTAssertEqual(survived.count, 40,
                       "2-line prompt: missing rows " +
                       (1...40).filter { i in !after.contains { $0.hasPrefix("ROW\(i)-marker") } }
                        .map(String.init).joined(separator: ","))
    }

    /// The real failing shape: a multi-line prompt that emits OSC 133;A and whose
    /// INFO line WRAPS at narrow widths (like starship's powerline line). On widen,
    /// zsh moves up by the (taller, wrapped) prompt height it last drew; if reflow
    /// un-wrapped the info line, that up-move overshoots into content. Preserving the
    /// whole prompt block (from the 133;A mark) must keep all content.
    func testWrappingInfoLinePromptResizeKeepsScrollback() throws {
        var env = DamsonConfig.defaultEnv()
        env["TERM"] = "xterm-256color"
        let config = DamsonConfig(argv: ["/bin/zsh", "-fi"], env: env, cwd: NSTemporaryDirectory())
        let session = DamsonSession(config: config)
        defer { session.terminate() }
        pump(until: { session.grid.scrollback.count + self.nonBlank(session.grid) > 0 })
        settle(0.3)
        // %{...%} wraps the non-printing OSC 133;A. The info line is long enough to
        // wrap under ~24 cols but fit at 80; then a newline and the "> " input line.
        let info = "INFOINFOINFOINFOINFOINFOINFOINFOINFOINFO"   // 40 cols
        session.write(Data("PROMPT=$'%{\\e]133;A\\e\\\\%}\(info)\\n> '\n".utf8))
        settle(0.3)
        session.write(Data("for i in $(seq 1 40); do print \"ROW$i-marker\"; done\n".utf8))
        pump(until: { self.allText(session.grid).contains { $0.hasPrefix("ROW40-marker") } })
        settle(0.3)

        for (c, r) in [(20, 24), (80, 24), (16, 24), (80, 24), (24, 24), (80, 24)] {
            session.resize(cols: c, rows: r); settle(0.35)
        }
        settle(0.3)
        let after = Set(allText(session.grid))
        let survived = (1...40).filter { i in after.contains { $0.hasPrefix("ROW\(i)-marker") } }
        XCTAssertEqual(survived.count, 40,
                       "wrapping-info prompt: missing rows " +
                       (1...40).filter { i in !after.contains { $0.hasPrefix("ROW\(i)-marker") } }
                        .map(String.init).joined(separator: ","))
    }

    private func nonBlank(_ g: Grid) -> Int {
        var n = 0
        for r in 0..<g.rows { if g.row(r).contains(where: { $0.char != " " }) { n += 1 } }
        return n
    }
}
