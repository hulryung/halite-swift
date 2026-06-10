import Foundation

/// Stable tmux identifiers. tmux guarantees these never change for the lifetime of
/// the object (unlike names/indexes), so we always key on them — see docs §4.7.
public struct TmuxSessionID: Hashable, CustomStringConvertible {
    /// The numeric id without the leading `$`.
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    /// The token as it appears on the wire, e.g. `$0`.
    public var token: String { "$\(raw)" }
    public var description: String { token }
}

public struct TmuxWindowID: Hashable, CustomStringConvertible {
    /// The numeric id without the leading `@`.
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    /// The token as it appears on the wire, e.g. `@1`.
    public var token: String { "@\(raw)" }
    public var description: String { token }
}

public struct TmuxPaneID: Hashable, CustomStringConvertible {
    /// The numeric id without the leading `%`.
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    /// The token as it appears on the wire, e.g. `%2`.
    public var token: String { "%\(raw)" }
    public var description: String { token }
}

/// A `%layout-change` payload. In P1 we keep the raw layout string and the window it
/// belongs to; the structured parse into a pane tree is P2 (`TmuxLayoutReconciler`).
public struct TmuxLayout: Equatable {
    public let window: TmuxWindowID
    /// The primary layout string, e.g. `e7b2,80x24,0,0,1`.
    public let layout: String
    /// The remaining fields after the layout (visible-layout, flags) — kept verbatim for P2.
    public let extra: [String]
    public init(window: TmuxWindowID, layout: String, extra: [String] = []) {
        self.window = window
        self.layout = layout
        self.extra = extra
    }
}

/// The framing of a command reply, matched by `(timestamp, commandNumber)`.
public struct TmuxCommandReply: Equatable {
    public let timestamp: String
    public let commandNumber: String
    public let flags: String
    /// The lines emitted between `%begin` and `%end`/`%error`.
    public let lines: [String]
    /// true if the reply was terminated by `%error` rather than `%end`.
    public let isError: Bool
}

/// One decoded control-mode event. The parser turns each input line into zero or one
/// of these. `TmuxControlClient` fans them out to its public callbacks.
public enum TmuxControlEvent: Equatable {
    /// A `%begin … %end`/`%error` block resolved to a single reply.
    case commandReply(TmuxCommandReply)
    /// `%output %<pane> <data>` — already octal-decoded to raw bytes.
    case output(pane: TmuxPaneID, data: Data)
    case windowAdd(TmuxWindowID)
    case windowClose(TmuxWindowID)
    case windowRenamed(TmuxWindowID, name: String)
    case windowPaneChanged(window: TmuxWindowID, pane: TmuxPaneID)
    case layoutChange(TmuxLayout)
    case sessionChanged(TmuxSessionID, name: String)
    case sessionWindowChanged(session: TmuxSessionID, window: TmuxWindowID)
    case sessionsChanged
    case paneExit(TmuxPaneID)
    /// `%exit` — the control client is detaching. Optional reason string when tmux supplies one.
    case exit(reason: String?)
    /// A recognized-but-not-acted-on or unknown `%` line, surfaced for logging. Never fatal.
    case unhandled(line: String)
}

/// Line-based tmux `-CC` control-mode parser. **Pure logic, no I/O** — feed it complete
/// lines (no trailing newline) and it returns the events they produce. Kept separate from
/// `TmuxControlClient` so the framing/decoding can be unit-tested without spawning tmux.
///
/// Protocol reference: https://github.com/tmux/tmux/wiki/Control-Mode and docs/TMUX-INTEGRATION.md §4.
public final class TmuxControlParser {
    /// Accumulated state while inside a `%begin … %end`/`%error` block.
    private struct PendingBlock {
        let timestamp: String
        let commandNumber: String
        let flags: String
        var lines: [String] = []
    }
    private var pending: PendingBlock?

    public init() {}

    /// Feed one complete line (newline already stripped). Returns the event it produced,
    /// or nil if the line was consumed as part of an in-progress command block.
    public func feed(line: String) -> TmuxControlEvent? {
        // Defensive: strip a stray tmux `-CC` DCS control-mode wrapper if it leaks through.
        // `tmux -CC` prefixes the very first control line with a DCS "enter control mode"
        // sequence — ESC `P1000p` — glued directly to `%begin`, and terminates the stream
        // with ST (ESC `\`). Damson spawns tmux with `-C` (no wrapper, see TmuxControlClient),
        // so this normally never fires, but we strip it here so a stray `-CC` wrapper can't
        // turn the first `%begin` (or the closing line) into an `.unhandled` line. See
        // docs/TMUX-INTEGRATION.md "P1.1 fixes".
        let stripped = Self.stripDCSWrapper(line)
        // A line that was *only* the DCS/ST wrapper (e.g. the trailing `ESC \`) collapses to
        // empty after stripping — drop it rather than surfacing a spurious `.unhandled("")`.
        if stripped.isEmpty && !line.isEmpty && pending == nil { return nil }
        let line = stripped

        // Inside a %begin block: every line up to %end/%error is reply body, EXCEPT the
        // closing %end/%error itself. (Notifications don't interleave inside a block.)
        if pending != nil {
            if line.hasPrefix("%end") || line.hasPrefix("%error") {
                return closeBlock(with: line)
            }
            pending?.lines.append(line)
            return nil
        }

        guard line.hasPrefix("%") else {
            // A bare line outside any block shouldn't normally happen in control mode.
            // Surface it rather than crash.
            return .unhandled(line: line)
        }

        // Split into the `%verb` and the remainder (single space).
        let (verb, rest) = Self.splitFirstToken(line)
        switch verb {
        case "%begin":
            beginBlock(rest)
            return nil
        case "%end", "%error":
            // A stray close with no open block — ignore gracefully.
            return .unhandled(line: line)
        case "%output":
            return parseOutput(rest)
        case "%window-add":
            return parseWindowID(rest).map { .windowAdd($0) } ?? .unhandled(line: line)
        case "%window-close", "%unlinked-window-close":
            return parseWindowID(rest).map { .windowClose($0) } ?? .unhandled(line: line)
        case "%window-renamed", "%unlinked-window-renamed":
            return parseWindowRenamed(rest) ?? .unhandled(line: line)
        case "%window-pane-changed":
            return parseWindowPaneChanged(rest) ?? .unhandled(line: line)
        case "%layout-change":
            return parseLayoutChange(rest) ?? .unhandled(line: line)
        case "%session-changed":
            return parseSessionChanged(rest) ?? .unhandled(line: line)
        case "%session-window-changed":
            return parseSessionWindowChanged(rest) ?? .unhandled(line: line)
        case "%sessions-changed":
            return .sessionsChanged
        case "%pane-exited":
            // Not a standard tmux verb, but some forks emit it; treat like an exit hint.
            return parsePaneID(rest).map { .paneExit($0) } ?? .unhandled(line: line)
        case "%exit":
            let reason = rest.isEmpty ? nil : rest
            return .exit(reason: reason)
        default:
            // %window-add unlinked variants, %pane-mode-changed, %subscription-changed,
            // %pause/%continue, %client-session-changed, %session-renamed, … — the long
            // tail. Recognized as control lines but not acted on in P1.
            return .unhandled(line: line)
        }
    }

    // MARK: - Command-block framing

    private func beginBlock(_ rest: String) {
        let f = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        pending = PendingBlock(
            timestamp: f.count > 0 ? f[0] : "",
            commandNumber: f.count > 1 ? f[1] : "",
            flags: f.count > 2 ? f[2] : ""
        )
    }

    private func closeBlock(with line: String) -> TmuxControlEvent {
        let (verb, rest) = Self.splitFirstToken(line)
        let isError = (verb == "%error")
        let block = pending
        pending = nil
        // Match %end/%error's ts/cmdnum/flags against the %begin we recorded; we trust
        // the begin's fields for identity (tmux guarantees they match) but verify shape.
        let f = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let ts = block?.timestamp ?? (f.count > 0 ? f[0] : "")
        let num = block?.commandNumber ?? (f.count > 1 ? f[1] : "")
        let flags = block?.flags ?? (f.count > 2 ? f[2] : "")
        return .commandReply(TmuxCommandReply(
            timestamp: ts,
            commandNumber: num,
            flags: flags,
            lines: block?.lines ?? [],
            isError: isError
        ))
    }

    // MARK: - Notification parsers

    /// `%output %<pane> <data…>`. data may contain spaces and is taken verbatim after the
    /// pane token. Octal escapes (`\NNN`) are decoded to bytes.
    private func parseOutput(_ rest: String) -> TmuxControlEvent {
        // pane token is up to the first space; the rest (possibly empty) is the payload.
        guard let sp = rest.firstIndex(of: " ") else {
            // `%output %N` with no data — empty output.
            if let pane = Self.parsePaneToken(rest) {
                return .output(pane: pane, data: Data())
            }
            return .unhandled(line: "%output \(rest)")
        }
        let paneToken = String(rest[rest.startIndex..<sp])
        let payload = String(rest[rest.index(after: sp)...])
        guard let pane = Self.parsePaneToken(paneToken) else {
            return .unhandled(line: "%output \(rest)")
        }
        return .output(pane: pane, data: Self.decodeOctalEscaped(payload))
    }

    private func parseWindowID(_ rest: String) -> TmuxWindowID? {
        let token = Self.firstField(rest)
        return Self.parseWindowToken(token)
    }

    private func parsePaneID(_ rest: String) -> TmuxPaneID? {
        Self.parsePaneToken(Self.firstField(rest))
    }

    /// `%window-renamed @<win> <name…>` — name may contain spaces.
    private func parseWindowRenamed(_ rest: String) -> TmuxControlEvent? {
        let (idTok, name) = Self.splitFirstToken(rest)
        guard let win = Self.parseWindowToken(idTok) else { return nil }
        return .windowRenamed(win, name: name)
    }

    /// `%window-pane-changed @<win> %<pane>`.
    private func parseWindowPaneChanged(_ rest: String) -> TmuxControlEvent? {
        let f = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 2,
              let win = Self.parseWindowToken(f[0]),
              let pane = Self.parsePaneToken(f[1]) else { return nil }
        return .windowPaneChanged(window: win, pane: pane)
    }

    /// `%layout-change @<win> <layout> [<visible-layout> <flags>]`.
    private func parseLayoutChange(_ rest: String) -> TmuxControlEvent? {
        let f = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 2, let win = Self.parseWindowToken(f[0]) else { return nil }
        let extra = f.count > 2 ? Array(f[2...]) : []
        return .layoutChange(TmuxLayout(window: win, layout: f[1], extra: extra))
    }

    /// `%session-changed $<sid> <name…>`.
    private func parseSessionChanged(_ rest: String) -> TmuxControlEvent? {
        let (idTok, name) = Self.splitFirstToken(rest)
        guard let sid = Self.parseSessionToken(idTok) else { return nil }
        return .sessionChanged(sid, name: name)
    }

    /// `%session-window-changed $<sid> @<win>`.
    private func parseSessionWindowChanged(_ rest: String) -> TmuxControlEvent? {
        let f = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 2,
              let sid = Self.parseSessionToken(f[0]),
              let win = Self.parseWindowToken(f[1]) else { return nil }
        return .sessionWindowChanged(session: sid, window: win)
    }

    // MARK: - DCS wrapper stripping (tmux -CC defensive)

    /// Remove a tmux `-CC` DCS control-mode wrapper from a line if present:
    ///   - leading DCS "enter control mode": ESC `P` `1000p` (`\u{1B}P1000p`), which tmux
    ///     glues directly onto the first `%begin`.
    ///   - trailing ST "exit control mode": ESC `\` (`\u{1B}\`), which tmux appends after the
    ///     final `%exit`.
    /// A bare ESC (without the rest of the wrapper) is left untouched. Idempotent on lines
    /// that carry no wrapper (the common `-C` case), so it's cheap to always call.
    static func stripDCSWrapper(_ line: String) -> String {
        var s = Substring(line)
        // Leading DCS enter: ESC P <params> p. tmux emits exactly `1000p`, but accept any
        // run of param/intermediate bytes up to the final `p` to be tolerant of versions.
        if s.first == "\u{1B}", s.dropFirst().first == "P" {
            // Find the `p` that closes the DCS introducer; everything up to and including it
            // is the wrapper. (The DCS *payload* here is the `%begin…` we want to keep.)
            let afterP = s.dropFirst(2)  // past ESC P
            if let pIdx = afterP.firstIndex(of: "p") {
                s = afterP[afterP.index(after: pIdx)...]
            }
        }
        // Trailing ST: ESC \ . May be the whole line (its own bytes) or appended to content.
        if s.hasSuffix("\u{1B}\\") {
            s = s.dropLast(2)
        }
        return String(s)
    }

    // MARK: - Token helpers

    /// Split `line` into its first whitespace-delimited token and the remainder
    /// (single leading space consumed). Remainder may contain spaces and is verbatim.
    static func splitFirstToken(_ line: String) -> (String, String) {
        guard let sp = line.firstIndex(of: " ") else { return (line, "") }
        let head = String(line[line.startIndex..<sp])
        let tail = String(line[line.index(after: sp)...])
        return (head, tail)
    }

    /// The first whitespace-delimited field of `s` (empty string if none).
    static func firstField(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }

    static func parseSessionToken(_ token: String) -> TmuxSessionID? {
        guard token.hasPrefix("$"), let n = Int(token.dropFirst()) else { return nil }
        return TmuxSessionID(n)
    }
    static func parseWindowToken(_ token: String) -> TmuxWindowID? {
        guard token.hasPrefix("@"), let n = Int(token.dropFirst()) else { return nil }
        return TmuxWindowID(n)
    }
    static func parsePaneToken(_ token: String) -> TmuxPaneID? {
        guard token.hasPrefix("%"), let n = Int(token.dropFirst()) else { return nil }
        return TmuxPaneID(n)
    }

    // MARK: - Octal-escape decode

    /// Decode tmux `%output` payload encoding. Bytes < ASCII 32 and `\` are sent as a
    /// 3-digit octal escape `\NNN` (CR=`\015`, LF=`\012`, backslash=`\134`); every other
    /// byte is verbatim (and may carry raw escape sequences + multibyte UTF-8). docs §4.2.
    static func decodeOctalEscaped(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            // A backslash followed by exactly three octal digits decodes to one byte.
            if b == 0x5C /* backslash */, i + 3 < bytes.count,
               Self.isOctalDigit(bytes[i + 1]),
               Self.isOctalDigit(bytes[i + 2]),
               Self.isOctalDigit(bytes[i + 3]) {
                let value = (Int(bytes[i + 1] - 0x30) << 6)
                          | (Int(bytes[i + 2] - 0x30) << 3)
                          | Int(bytes[i + 3] - 0x30)
                out.append(UInt8(value & 0xFF))
                i += 4
                continue
            }
            // Anything else (incl. a stray backslash) is verbatim.
            out.append(b)
            i += 1
        }
        return Data(out)
    }

    private static func isOctalDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }
}
