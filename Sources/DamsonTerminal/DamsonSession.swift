import AppKit
import Combine
import Foundation

/// A single terminal instance. Bundles a PTY + parser + Grid.
/// Created and owned by the host (cmux / damson.app) and injected into `DamsonTerminalView`.
public final class DamsonSession: ObservableObject {
    @Published public private(set) var config: DamsonConfig

    @Published public private(set) var title: String = ""
    @Published public private(set) var workingDirectory: String? = nil
    @Published public private(set) var processExited: Bool = false
    public private(set) var exitCode: Int32? = nil

    /// Semantic events emitted by VTParser (for debug/test hooks).
    /// Screen rendering no longer goes through this; it observes `grid` + `gridChanged` instead.
    public let outputEvents = PassthroughSubject<DamsonOutputEvent, Never>()

    /// Bracketed paste mode. Toggled via CSI ?2004h/l. When on, the host wraps
    /// pasted text in ESC[200~ ... ESC[201~ on Cmd+V.
    public private(set) var bracketedPasteEnabled: Bool = false

    /// Mouse reporting mode. 0 = off, 1000 = press/release, 1002 = + drag, 1003 = any motion.
    public private(set) var mouseReportingMode: Int = 0
    /// SGR mouse encoding (CSI ?1006h). true uses SGR format, false uses X10 classic.
    public private(set) var mouseSGREncoding: Bool = false

    /// Cell grid (the current viewport).
    public let grid: Grid

    /// Grid-mutation notification. May fire multiple times while processing a single
    /// PTY chunk, so the host should coalesce on a per-runloop basis.
    public let gridChanged = PassthroughSubject<Void, Never>()

    // Callbacks the host subscribes to. Prefer weak captures.
    public var onTitleChanged: ((String) -> Void)?
    /// Current working directory reported by the shell via OSC 7. Updated only when
    /// shell integration (OSC 7 emit) is enabled. The source for a split/new tab inheriting
    /// the "current directory". If never reported, stays at the spawn-time `config.cwd`.
    public private(set) var currentDirectory: String?
    public var onCwdChanged: ((String) -> Void)?
    /// Absolute line numbers of prompt lines recorded via OSC 133;A (based on scrollbackPushCount,
    /// so stable across eviction). The source for ⌘↑/⌘↓ prompt jumps. Accumulated only when
    /// shell integration (OSC 133 emit) is enabled.
    public private(set) var promptMarks: [UInt64] = []
    public var onBell: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onURLClick: ((URL) -> Void)?
    public var onClipboardWrite: ((String) -> Void)?
    public var onOutput: ((Data) -> Void)?

    // The pluggable byte source/sink. Defaults to a local forkpty (`PTYHost`); a tmux -CC
    // pane injects a `TmuxPaneBackend` via the backend-factory init below — see
    // docs/TMUX-INTEGRATION.md. Whether `spawn` actually forks (PTYHost) or is a no-op
    // (tmux, already spawned) is the backend's concern.
    private let pty: SessionIOBackend
    private let parser = VTParser()

    /// Default path: a local forkpty session. Behavior is identical to before the seam —
    /// the backend is a freshly constructed `PTYHost`.
    public convenience init(config: DamsonConfig, restoredScrollback: [Line]? = nil) {
        self.init(config: config, restoredScrollback: restoredScrollback, backend: PTYHost())
    }

    /// Backend-injection path: construct a session over an arbitrary `SessionIOBackend`
    /// (e.g. a `TmuxPaneBackend` for a tmux `-CC` pane). `spawn` is still called with the
    /// config's argv/env/cwd; a tmux backend treats it as a no-op.
    public init(config: DamsonConfig, restoredScrollback: [Line]? = nil, backend: SessionIOBackend) {
        self.pty = backend
        self.config = config
        self.currentDirectory = config.cwd
        self.grid = Grid(
            cols: 80,
            rows: 24,
            pen: CellAttrs(fg: .default)
        )
        self.grid.maxScrollbackLines = config.scrollbackLines
        self.grid.setCursorShape(config.cursorShape)
        // Seed the previous session's scrollback before any live output (session restore; passed only when the setting is on).
        if let restoredScrollback { grid.seedScrollback(restoredScrollback) }

        parser.delegate = self

        pty.onData = { [weak self] data in
            self?.handlePTYData(data)
        }
        pty.onExit = { [weak self] code in
            self?.handlePTYExit(code: code)
        }

        do {
            try pty.spawn(
                argv: config.argv,
                env: config.env,
                cwd: config.cwd,
                cols: 80,
                rows: 24
            )
        } catch {
            NSLog("damson: PTY spawn failed: \(error)")
        }
    }

    /// Additional input beyond key events (e.g. text synthesized by the host).
    public func write(_ bytes: Data) {
        pty.write(bytes)
    }

    /// The child shell's current working directory (for session restore). nil on failure.
    public var currentWorkingDirectory: String? {
        pty.childWorkingDirectory
    }

    /// Whether this session is running a command in the foreground (rather than waiting at a prompt).
    /// Used so the quit-confirmation dialog only prompts when there's actually a running job.
    public var hasRunningForegroundJob: Bool {
        pty.isRunningForegroundJob
    }

    public func resize(cols: Int, rows: Int) {
        grid.resize(cols: cols, rows: rows)
        pty.resize(cols: cols, rows: rows)
        gridChanged.send()
    }

    /// Reflow the on-screen grid to a new size WITHOUT notifying the shell
    /// (no SIGWINCH). Used during a live window resize so the shell doesn't redraw
    /// (and accumulate) its prompt on every drag frame; the host sends one real
    /// `resize` (SIGWINCH) when the drag ends.
    public func resizeGridOnly(cols: Int, rows: Int) {
        grid.resize(cols: cols, rows: rows)
        gridChanged.send()
    }

    public func clearSelection() {
        // TODO(M8)
    }

    /// Called on hot-reload, e.g. when the font/colors/palette change.
    /// Since `config` is `@Published`, subscribers (the view) react automatically.
    public func updateConfig(_ config: DamsonConfig) {
        self.config = config
        grid.maxScrollbackLines = config.scrollbackLines
        // Apply the user's default cursor shape immediately. An app may later
        // override it via DECSCUSR; that takes precedence until the next reset.
        grid.setCursorShape(config.cursorShape)
    }

    public func terminate() {
        pty.terminate()
    }

    // MARK: - Internals

    private func handlePTYData(_ data: Data) {
        onOutput?(data)
        parser.feed(data)
        gridChanged.send()
    }

    private func handlePTYExit(code: Int32) {
        processExited = true
        exitCode = code
        onExit?(code)
    }

    /// OSC dispatch — 0/2 (title), 4/10/11 (color query), 8 (hyperlink); everything else ignored.
    fileprivate func dispatchOSCIfNeeded(_ oscParams: [String]) {
        guard let kind = oscParams.first else { return }
        switch kind {
        case "0", "2":
            guard oscParams.count >= 2 else { return }
            let newTitle = oscParams[1]
            if newTitle != title {
                title = newTitle
                onTitleChanged?(newTitle)
            }
        case "4":
            // OSC 4 ; index ; spec — query if spec == "?"
            guard oscParams.count >= 3, oscParams[2] == "?",
                  let index = Int(oscParams[1]), (0...15).contains(index) else { return }
            let color = config.theme.paletteColor(index)
            respondToOSCColorQuery(kind: "4", index: index, color: color)
        case "10":
            // OSC 10 ; ? — query default fg
            guard oscParams.count >= 2, oscParams[1] == "?" else { return }
            respondToOSCColorQuery(kind: "10", index: nil, color: config.foregroundColor)
        case "11":
            // OSC 11 ; ? — query default bg
            guard oscParams.count >= 2, oscParams[1] == "?" else { return }
            respondToOSCColorQuery(kind: "11", index: nil, color: config.backgroundColor)
        case "7":
            // OSC 7 ; file://host/path ST — the current working directory reported by the shell.
            guard oscParams.count >= 2,
                  let path = Self.parseFileURLPath(oscParams[1]) else { return }
            if path != currentDirectory {
                currentDirectory = path
                onCwdChanged?(path)
            }
        case "8":
            // OSC 8 ; params ; URI ST
            //   start: params is typically "id=xxx" or an empty string, URI non-empty
            //   end: URI empty
            let uri = oscParams.count >= 3 ? oscParams[2] : ""
            grid.setHyperlink(uri.isEmpty ? nil : uri)
        case "133":
            // OSC 133 ; A/B/C/D — FinalTerm semantic prompt. v1 uses only A (prompt start)
            // to mark prompt lines. B/C/D are reserved for the future.
            if oscParams.count >= 2, oscParams[1] == "A" {
                let absLine = grid.scrollbackPushCount + UInt64(max(0, grid.cursorRow))
                if promptMarks.last != absLine {
                    promptMarks.append(absLine)
                    if promptMarks.count > 5000 {
                        promptMarks.removeFirst(promptMarks.count - 5000)
                    }
                }
                // Mark this row so a resize preserves the whole prompt block's
                // physical-row count (keeps the shell's relative redraw in sync).
                grid.markPromptStart()
            }
        default:
            break
        }
    }

    /// Extracts just the path portion from OSC 7's `file://host/path` (percent-decoded). host is ignored.
    static func parseFileURLPath(_ uri: String) -> String? {
        guard uri.hasPrefix("file://") else { return nil }
        let afterScheme = uri.dropFirst("file://".count)
        // The path starts at the first '/' after host. If host is empty (`file:///path`), that's '/' right away.
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let path = String(afterScheme[slash...])
        return path.removingPercentEncoding ?? path
    }

    private func respondToOSCColorQuery(kind: String, index: Int?, color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let r = UInt16(max(0, min(1, srgb.redComponent)) * 65535)
        let g = UInt16(max(0, min(1, srgb.greenComponent)) * 65535)
        let b = UInt16(max(0, min(1, srgb.blueComponent)) * 65535)
        let rgbSpec = String(format: "rgb:%04x/%04x/%04x", r, g, b)
        let payload: String
        if let index = index {
            payload = "\(kind);\(index);\(rgbSpec)"
        } else {
            payload = "\(kind);\(rgbSpec)"
        }
        let response = "\u{1B}]\(payload)\u{1B}\\"
        if let data = response.data(using: .utf8) {
            pty.write(data)
        }
    }

    /// Converts a CSI emitted by the parser into a grid mutation.
    fileprivate func handleCSI(
        params: [Int],
        intermediates: [UInt8],
        finalByte: UInt8,
        privateMarker: UInt8?
    ) {
        // Common default handling: when the first param is unspecified (-1) or 0, treat it as 1.
        let p1 = (params.first ?? -1) <= 0 ? 1 : params[0]

        switch finalByte {
        case 0x41: grid.cursorUp(p1)        // A — CUU
        case 0x42: grid.cursorDown(p1)      // B — CUD
        case 0x43: grid.cursorForward(p1)   // C — CUF
        case 0x44: grid.cursorBack(p1)      // D — CUB
        case 0x48, 0x66:                    // H / f — CUP / HVP
            let r = (params.count > 0 && params[0] > 0) ? params[0] : 1
            let c = (params.count > 1 && params[1] > 0) ? params[1] : 1
            grid.setCursor(row: r, col: c)
        case 0x4A:                          // J — ED
            let mode = (params.first ?? -1) < 0 ? 0 : params[0]
            grid.eraseInDisplay(mode: mode)
        case 0x4B:                          // K — EL
            let mode = (params.first ?? -1) < 0 ? 0 : params[0]
            grid.eraseInLine(mode: mode)
        case 0x47, 0x60:                    // G / ` — CHA / HPA: move to absolute column
            grid.setCursorColumn(p1)
        case 0x64:                          // d — VPA: move to absolute row
            grid.setCursorRow(p1)
        case 0x58:                          // X — ECH: erase n cells from the cursor
            grid.eraseChars(p1)
        case 0x4C:                          // L — IL: insert n blank lines
            grid.insertLines(p1)
        case 0x4D:                          // M — DL: delete n lines
            grid.deleteLines(p1)
        case 0x40:                          // @ — ICH: insert n blank cells
            grid.insertChars(p1)
        case 0x50:                          // P — DCH: delete n cells
            grid.deleteChars(p1)
        case 0x73:                          // s — SC (DECSC ANSI variant)
            if privateMarker == nil {
                grid.saveCursor()
            }
        case 0x75:                          // u — RC (DECRC ANSI variant)
            if privateMarker == nil {
                grid.restoreCursor()
            }
        case 0x53: grid.scrollUp(count: p1)   // S — SU
        case 0x54: grid.scrollDown(count: p1) // T — SD
        case 0x72:                          // r — DECSTBM (must have no private marker)
            if privateMarker == nil {
                let top = (params.count > 0 && params[0] > 0) ? params[0] : 1
                let bot = (params.count > 1 && params[1] > 0) ? params[1] : grid.rows
                grid.setScrollRegion(top: top - 1, bottom: bot - 1)
            }
        case 0x63:                          // c — DA1 / DA2
            if privateMarker == nil && intermediates.isEmpty {
                // Primary DA → VT102 identification: ESC [ ? 6 c
                pty.write(Data([0x1B, 0x5B, 0x3F, 0x36, 0x63]))
            } else if privateMarker == 0x3E && intermediates.isEmpty {
                // Secondary DA → ESC [ > 0 ; 0 ; 0 c (generic)
                pty.write(Data([0x1B, 0x5B, 0x3E, 0x30, 0x3B, 0x30, 0x3B, 0x30, 0x63]))
            }
        case 0x71:                          // q — DECSCUSR (intermediate=SP)
            if privateMarker == nil && intermediates == [0x20] {
                let ps = params.first ?? 0
                let shape: Grid.CursorShape
                switch ps {
                case 1, 2: shape = .block
                case 3, 4: shape = .underline
                case 5, 6: shape = .bar
                default: shape = config.cursorShape  // 0/unspecified = reset → user default
                }
                grid.setCursorShape(shape)
            }
        case 0x6D:                          // m — SGR
            // SGR applies to `CSI ... m` only when there's **neither** a private marker
            // nor an intermediate. `CSI > 4 ; 2 m` (xterm modifyOtherKeys / Kitty keyboard
            // protocol) and `CSI ? Pn m` (DEC private SGR) etc. are not SGR.
            // Claude Code sends `\x1b[>4;2m` at startup; treating it as SGR would set
            // param 4 → underline ON, and with no following reset the underline leaks
            // across the whole session.
            // Mirrors: anthropics/claude-code#23698, halite Rust 40bd82f.
            if privateMarker == nil && intermediates.isEmpty {
                grid.applySGR(params)
            }
        case 0x68:                          // h — SET MODE
            applyModeChange(params: params, privateMarker: privateMarker, set: true)
        case 0x6C:                          // l — RESET MODE
            applyModeChange(params: params, privateMarker: privateMarker, set: false)
        default:
            break // Ignore unsupported CSI (alt screen / scroll region, etc. land in a later milestone)
        }
    }

    private func applyModeChange(params: [Int], privateMarker: UInt8?, set: Bool) {
        // Handle DEC private mode (`?`) only. ANSI mode is rarely used.
        guard privateMarker == 0x3F else { return }
        for p in params where p > 0 {
            switch p {
            case 25:
                grid.setCursorVisible(set)
            case 47, 1047, 1049:
                // The difference between 47/1047/1049 is a subtle one in cursor-save and clear
                // timing, but M3.7 treats all three identically as "enter/leave alt". In practice
                // vim/less/htop are fine.
                if set {
                    grid.enterAltScreen()
                } else {
                    grid.leaveAltScreen()
                }
            case 2004:
                // Bracketed paste mode toggle. Read by the host (view).
                bracketedPasteEnabled = set
            case 1000, 1002, 1003:
                // Enable mouse reporting — keep only the strongest mode.
                mouseReportingMode = set ? p : 0
            case 1006:
                // SGR mouse encoding
                mouseSGREncoding = set
            case 2026:
                // Synchronized Output Mode (DECSET 2026) — used by apps that don't use the
                // alt-screen and instead redraw on the primary screen via cursor positioning,
                // such as Claude Code and Ink-based TUIs.
                //   - hasUsedSyncOutput: once set even once, becomes sticky-true. Enables
                //     TUI-friendly policies such as viewport-top anchoring on resize.
                //   - inSyncOutputMode: transient (set ⇔ true, clear ⇔ false).
                //     Used by the host to batch a frame up to the ESU and present it atomically
                //     (avoiding torn frames). Unrelated to scrollback accumulation — sync is just
                //     a presentation hint, so lines that scroll off during a redraw still
                //     accumulate normally.
                if set { grid.hasUsedSyncOutput = true }
                grid.inSyncOutputMode = set
            default:
                break
            }
        }
    }
}

extension DamsonSession: VTParserDelegate {
    public func vtParser(_ parser: VTParser, didEmitText text: String) {
        for ch in text {
            grid.putChar(ch)
        }
        outputEvents.send(.text(text))
    }

    public func vtParser(_ parser: VTParser, didExecute byte: UInt8) {
        switch byte {
        case 0x08: grid.backspace()
        case 0x0A: grid.lineFeed()
        case 0x0D: grid.carriageReturn()
        case 0x09:
            // TAB — move to the next 8-column stop (move the cursor only, don't fill with spaces)
            let next = ((grid.cursorCol / 8) + 1) * 8
            let target = min(next, grid.cols - 1)
            grid.cursorForward(max(target - grid.cursorCol, 1))
        case 0x07:
            onBell?()
        default:
            break
        }
        outputEvents.send(.execute(byte))
    }

    public func vtParser(
        _ parser: VTParser,
        didEmitCSI params: [Int],
        intermediates: [UInt8],
        finalByte: UInt8,
        privateMarker: UInt8?
    ) {
        handleCSI(params: params, intermediates: intermediates, finalByte: finalByte, privateMarker: privateMarker)
        outputEvents.send(.csi(
            params: params,
            intermediates: intermediates,
            finalByte: finalByte,
            privateMarker: privateMarker
        ))
    }

    public func vtParser(_ parser: VTParser, didEmitOSC params: [String]) {
        dispatchOSCIfNeeded(params)
        outputEvents.send(.osc(params))
    }

    public func vtParser(_ parser: VTParser, didEmitESC finalByte: UInt8) {
        switch finalByte {
        case 0x37: // '7' — DECSC: save cursor + pen
            grid.saveCursor()
        case 0x38: // '8' — DECRC: restore cursor + pen
            grid.restoreCursor()
        case 0x63: // 'c' — RIS: reset screen + state (simplified version)
            grid.eraseInDisplay(mode: 2)
            grid.setCursor(row: 1, col: 1)
        case 0x3D, 0x3E: // '=' / '>' — application/normal keypad mode (ignored in M3.9)
            break
        default:
            break
        }
    }
}
