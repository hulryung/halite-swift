import Foundation

/// Drives a single `tmux -CC` control-mode connection: spawns tmux on a PTY, splits its
/// stdout into lines, feeds them to `TmuxControlParser`, and fans the decoded events out
/// to public callbacks. Input back to tmux (key input, resize, raw commands) is written to
/// the PTY as ordinary one-line tmux commands.
///
/// Lifecycle and callbacks all run on the main queue (the PTY backend already hops there),
/// so the orchestration layer can touch AppKit directly.
///
/// See docs/TMUX-INTEGRATION.md §6.2. This is the P1 heart: framing, `%output` decode, and
/// the window/session notifications needed to map tmux windows → Damson tabs.
public final class TmuxControlClient {
    // MARK: - Public callbacks (docs §6.2)

    public var onWindowAdd: ((TmuxWindowID) -> Void)?
    public var onWindowClose: ((TmuxWindowID) -> Void)?
    public var onWindowRenamed: ((TmuxWindowID, String) -> Void)?
    public var onWindowPaneChanged: ((TmuxWindowID, TmuxPaneID) -> Void)?
    public var onLayoutChange: ((TmuxWindowID, TmuxLayout) -> Void)?
    public var onPaneOutput: ((TmuxPaneID, Data) -> Void)?
    public var onPaneExit: ((TmuxPaneID) -> Void)?
    /// `%pause %<pane>` — tmux throttled this pane (client lagged past `pause-after`). Resume
    /// it with `resumePane(_:)` once caught up.
    public var onPause: ((TmuxPaneID) -> Void)?
    /// `%continue %<pane>` — tmux resumed a previously paused pane.
    public var onContinue: ((TmuxPaneID) -> Void)?
    public var onSessionChanged: ((TmuxSessionID, String) -> Void)?
    public var onSessionWindowChanged: ((TmuxSessionID, TmuxWindowID) -> Void)?
    /// Reply to a command we sent (matched on its command number). Best-effort; P1 doesn't
    /// yet correlate replies to specific senders, but exposes them for debugging.
    public var onCommandReply: ((TmuxCommandReply) -> Void)?
    /// The control connection ended (`%exit`) or the tmux process itself exited.
    public var onExit: ((Int32?) -> Void)?
    /// Any control line we recognized as protocol but didn't act on, for logging.
    public var onUnhandled: ((String) -> Void)?

    // MARK: - Internals

    private let backend: SessionIOBackend
    private let parser = TmuxControlParser()
    /// Stdout bytes that haven't yet formed a complete line.
    private var lineBuffer = Data()
    private var didExit = false
    /// Last client size we told tmux (so we don't spam refresh-client on no-op resizes).
    private var lastSize: (cols: Int, rows: Int)?
    /// FIFO of per-command reply handlers (nil = caller doesn't care). tmux replies to
    /// stdin commands strictly in order. The startup guard block tmux emits on its own at
    /// connect carries flags `0` while replies to client commands carry flags `1` (verified
    /// against tmux 3.6b), so only flags≠0 blocks consume from this queue.
    private var pendingReplies: [((TmuxCommandReply) -> Void)?] = []

    /// Inject a custom backend (e.g. for tests). Defaults to a local `PTYHost` so the
    /// real client forkpty's tmux itself.
    public init(backend: SessionIOBackend = PTYHost()) {
        self.backend = backend
        backend.onData = { [weak self] data in self?.ingest(data) }
        backend.onExit = { [weak self] code in self?.handleProcessExit(code) }
    }

    /// Spawn `tmux -C` attached to `target` (a `-t` target session) or, when nil, a new
    /// session. tmux is found on `PATH` via `/usr/bin/env`. Sizes the control client to
    /// `cols`×`rows`.
    ///
    /// We use single-`C` (`-C`), not `-CC`. `-CC` additionally wraps the stream in a DCS
    /// "enter control mode" escape (`ESC P1000p … ESC \`) whose only purpose is to let a
    /// *host terminal* (where a human typed `tmux -CC`) detect control mode in-band. Damson
    /// spawns tmux as a dedicated control client, so it doesn't need — and shouldn't have to
    /// parse around — that wrapper. `-C` yields byte-for-byte identical control-mode
    /// notifications (verified against tmux 3.6b) without it. Claude Code's "am I inside
    /// tmux?" detection keys off the `$TMUX` env var, not `-C` vs `-CC`, so it's unaffected.
    /// (The parser still strips a stray DCS wrapper defensively — see TmuxControlParser.)
    ///
    /// Note: control mode is over stdin/stdout of the spawned process. We run it on a PTY
    /// (forkpty) like a normal child; a PTY gives us the same teardown story as local
    /// sessions. tmux does NOT take its control-client size from the PTY winsize — it must be
    /// told explicitly via `refresh-client -C`, which we send right after spawn so the
    /// window has a real size and tmux produces content (otherwise the pane can render blank).
    public func attach(target: String? = nil, cols: Int = 80, rows: Int = 24) throws {
        var argv = ["/usr/bin/env", "tmux", "-C"]
        if let target = target, !target.isEmpty {
            // Attach to an existing session by name/id.
            argv += ["attach-session", "-t", target]
        } else {
            // Start a brand-new session.
            argv += ["new-session"]
        }
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        try backend.spawn(argv: argv, env: env, cwd: nil, cols: cols, rows: rows)
        // Send the initial client size explicitly. We deliberately do NOT pre-seed `lastSize`
        // before this call, so the very first `refresh-client -C` is actually transmitted
        // (otherwise the no-op coalesce in `setClientSize` would swallow it and tmux would
        // size the window to 0/default → empty `capture-pane` → blank Damson pane).
        setClientSize(cols: cols, rows: rows)
    }

    /// Begin control mode over an ALREADY-streaming backend (the DCS takeover path — a
    /// `tmux -CC` the user launched inside an existing Damson pane). Nothing to spawn; just
    /// announce the client size so tmux lays the windows out (see `attach` for why this
    /// must be the first `refresh-client -C`).
    public func adoptStream(cols: Int = 80, rows: Int = 24) {
        setClientSize(cols: cols, rows: rows)
    }

    /// True once a clean detach has been requested. From this point destructive pane
    /// commands (`kill-pane`) are suppressed: detaching means "leave the session as it is",
    /// and the UI teardown that follows a window close must not destroy server state.
    public private(set) var isDetaching = false

    /// Ask tmux to detach this control client cleanly (`%exit` follows), leaving the
    /// session intact. Idempotent. Used when the host window closes (iTerm2 semantics:
    /// closing the window detaches, never kills) and by the takeover teardown path.
    public func requestDetach() {
        guard !isDetaching else { return }
        isDetaching = true
        sendCommand("detach-client")
    }

    // MARK: - Writers to tmux (docs §4.8)

    /// Send input bytes to a pane via `send-keys -t %N -H <hex…>`. The `-H` form takes
    /// space-separated hex byte values and is encoding-agnostic (no quoting/escaping pitfalls
    /// that `-l` literal text would have with control bytes or shell metacharacters).
    public func sendKeys(to pane: TmuxPaneID, data: Data) {
        guard !data.isEmpty else { return }
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        sendCommand("send-keys -t \(pane.token) -H \(hex)")
    }

    /// Tell tmux the control client's size: `refresh-client -C <cols>,<rows>`. Coalesces
    /// identical sizes. tmux sizes its windows to the smallest attached client.
    public func setClientSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        if let last = lastSize, last.cols == cols, last.rows == rows { return }
        lastSize = (cols, rows)
        sendCommand("refresh-client -C \(cols),\(rows)")
    }

    /// Write a raw one-line tmux command to the control client's stdin (newline appended).
    /// `onReply` (optional) is invoked with this command's `%begin/%end|%error` reply —
    /// matched FIFO over flags≠0 blocks (see `pendingReplies`).
    public func sendCommand(_ line: String, onReply: ((TmuxCommandReply) -> Void)? = nil) {
        guard !didExit else {
            // The connection is gone; fail the reply handler with a synthesized error so
            // callers awaiting enumeration/backfill don't hang silently.
            onReply?(TmuxCommandReply(timestamp: "", commandNumber: "", flags: "",
                                      lines: [], isError: true))
            return
        }
        var cmd = line
        if !cmd.hasSuffix("\n") { cmd += "\n" }
        if let data = cmd.data(using: .utf8) {
            pendingReplies.append(onReply)
            backend.write(data)
        }
    }

    /// Kill a specific pane: `kill-pane -t %N`. Suppressed while detaching — the teardown
    /// of a closing host window runs `terminate()` over every pane backend, and those must
    /// not destroy the session we just chose to leave alive.
    public func killPane(_ pane: TmuxPaneID) {
        guard !isDetaching else { return }
        sendCommand("kill-pane -t \(pane.token)")
    }

    /// Enable flow control: `refresh-client -f pause-after=<seconds>`. When the client lags
    /// more than `seconds` behind a pane, tmux pauses that pane (`%pause`) instead of buffering
    /// without bound, and switches its output to `%extended-output` (carrying a lag age). The
    /// client resumes paused panes via `resumePane(_:)`. `seconds = 0` disables it.
    public func enableFlowControl(pauseAfter seconds: Int) {
        sendCommand("refresh-client -f pause-after=\(seconds)")
    }

    /// Resume a paused pane: `refresh-client -A '%N:continue'`.
    public func resumePane(_ pane: TmuxPaneID) {
        sendCommand("refresh-client -A '\(pane.token):continue'")
    }

    /// Detach the control client cleanly.
    public func terminate() {
        backend.terminate()
    }

    // MARK: - stdout → lines → events

    /// Split incoming bytes on `\n`, strip a trailing `\r`, and feed each complete line to
    /// the parser. Partial trailing data is held until the next chunk completes the line.
    ///
    /// Two hot-path properties matter under output floods (e.g. `yes` in a pane):
    ///  - **Single-pass scan**: lines are sliced in place and the consumed prefix is removed
    ///    ONCE per chunk. (The old per-line `removeSubrange` shifted the whole remaining
    ///    buffer for every line — O(n²) per chunk — which saturated the main thread and froze
    ///    the UI when a chunk carried thousands of `%output` lines.)
    ///  - **Output coalescing**: consecutive `%output`/`%extended-output` events for the SAME
    ///    pane are concatenated and delivered as one callback per run, so the session does one
    ///    VTParser feed + one grid-changed per chunk-run instead of per line — the same
    ///    batching a local PTY read gives for free. Event order with non-output events is
    ///    preserved (a pending run is flushed before any other event is dispatched).
    private func ingest(_ data: Data) {
        lineBuffer.append(data)
        var start = lineBuffer.startIndex
        var pendingOutput: (pane: TmuxPaneID, data: Data)?

        func flushOutput() {
            if let p = pendingOutput {
                pendingOutput = nil
                onPaneOutput?(p.pane, p.data)
            }
        }

        while let nl = lineBuffer[start...].firstIndex(of: 0x0A) {
            // tmux uses CRLF line endings on control output; drop a trailing CR.
            var end = nl
            if end > start, lineBuffer[lineBuffer.index(before: end)] == 0x0D {
                end = lineBuffer.index(before: end)
            }
            let line = String(decoding: lineBuffer[start..<end], as: UTF8.self)
            start = lineBuffer.index(after: nl)

            guard let event = parser.feed(line: line) else { continue }
            if case .output(let pane, let d) = event {
                if pendingOutput?.pane == pane {
                    pendingOutput?.data.append(d)
                } else {
                    flushOutput()
                    pendingOutput = (pane, d)
                }
            } else {
                flushOutput()
                dispatch(event)
            }
        }
        flushOutput()
        if start > lineBuffer.startIndex {
            lineBuffer.removeSubrange(lineBuffer.startIndex..<start)
        }
    }

    private func dispatch(_ event: TmuxControlEvent) {
        switch event {
        case .commandReply(let reply):
            // Replies to OUR commands carry flags≠0; the connect-time guard block is flags 0
            // and must not consume a queued handler.
            if reply.flags != "0", !pendingReplies.isEmpty {
                let handler = pendingReplies.removeFirst()
                handler?(reply)
            }
            onCommandReply?(reply)
        case .output(let pane, let data):
            onPaneOutput?(pane, data)
        case .windowAdd(let w):
            onWindowAdd?(w)
        case .windowClose(let w):
            onWindowClose?(w)
        case .windowRenamed(let w, let name):
            onWindowRenamed?(w, name)
        case .windowPaneChanged(let w, let p):
            onWindowPaneChanged?(w, p)
        case .layoutChange(let layout):
            onLayoutChange?(layout.window, layout)
        case .sessionChanged(let s, let name):
            onSessionChanged?(s, name)
        case .sessionWindowChanged(let s, let w):
            onSessionWindowChanged?(s, w)
        case .sessionsChanged:
            break  // P1: nothing to do; window-add/close drive the tab set.
        case .paneExit(let p):
            onPaneExit?(p)
        case .paused(let p):
            onPause?(p)
        case .resumed(let p):
            onContinue?(p)
        case .exit(let reason):
            handleControlExit(reason: reason)
        case .unhandled(let line):
            onUnhandled?(line)
            NSLog("tmux: unhandled control line: %@", line)
        }
    }

    private func handleControlExit(reason: String?) {
        guard !didExit else { return }
        didExit = true
        if let reason = reason { NSLog("tmux: %%exit %@", reason) }
        onExit?(nil)
    }

    private func handleProcessExit(_ code: Int32) {
        guard !didExit else { return }
        didExit = true
        onExit?(code)
    }
}
