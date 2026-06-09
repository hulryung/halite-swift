import Foundation

/// NDJSON wire-format types for damson-cli ↔ damson server.
/// Encoding/decoding is implemented manually. (The format derives from the CLI
/// spec in Rust halite's `docs/CLI.md`, but is now damson's own format.)

public enum SplitDir: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// A pane-relative direction used by focus-pane / resize-pane.
public enum PaneDir: String, Codable, Sendable {
    case left
    case right
    case up
    case down
}

public enum ControlCommandKind: Equatable, Sendable {
    case newTab
    case split(SplitDir)
    case switchTab(index: Int)
    case closeTab
    case listTabs
    // --- Remote input & pane control (damson-cli expansion). ---
    /// Type literal UTF-8 text into the active pane (as if pasted/typed).
    case sendText(String)
    /// Send one or more named keys/chords (enter, tab, esc, up, ctrl-c, …) in order.
    case sendKeys([String])
    /// Resize the active window so its terminal grid is `cols` × `rows`.
    case resizeWindow(cols: Int, rows: Int)
    /// Nudge the active split's divider toward `dir` by `amount` cells (default 1).
    case resizePane(dir: PaneDir, amount: Int)
    /// Move pane focus to the adjacent pane in `dir`.
    case focusPane(dir: PaneDir)
    /// Close the active pane.
    case closePane
    /// Structured per-pane info for the active tab.
    case listPanes
}

/// An incoming command. JSON: `{"cmd":"new-tab"}`, `{"cmd":"split","args":{"dir":"horizontal"}}`, etc.
public struct ControlCommand: Decodable, Equatable, Sendable {
    public let kind: ControlCommandKind

    public init(kind: ControlCommandKind) { self.kind = kind }

    enum CodingKeys: String, CodingKey { case cmd, args }
    private struct SplitArgs: Decodable { let dir: SplitDir }
    private struct SwitchArgs: Decodable { let index: Int }
    private struct TextArgs: Decodable { let text: String }
    private struct KeysArgs: Decodable { let keys: [String] }
    private struct ResizeWindowArgs: Decodable { let cols: Int; let rows: Int }
    private struct ResizePaneArgs: Decodable { let dir: PaneDir; let amount: Int? }
    private struct PaneDirArgs: Decodable { let dir: PaneDir }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .cmd)
        switch name {
        case "new-tab":
            self.kind = .newTab
        case "close-tab":
            self.kind = .closeTab
        case "list-tabs":
            self.kind = .listTabs
        case "split":
            let a = try c.decode(SplitArgs.self, forKey: .args)
            self.kind = .split(a.dir)
        case "switch-tab":
            let a = try c.decode(SwitchArgs.self, forKey: .args)
            self.kind = .switchTab(index: a.index)
        case "send-text":
            let a = try c.decode(TextArgs.self, forKey: .args)
            self.kind = .sendText(a.text)
        case "send-key":
            let a = try c.decode(KeysArgs.self, forKey: .args)
            self.kind = .sendKeys(a.keys)
        case "resize-window":
            let a = try c.decode(ResizeWindowArgs.self, forKey: .args)
            self.kind = .resizeWindow(cols: a.cols, rows: a.rows)
        case "resize-pane":
            let a = try c.decode(ResizePaneArgs.self, forKey: .args)
            self.kind = .resizePane(dir: a.dir, amount: a.amount ?? 1)
        case "focus-pane":
            let a = try c.decode(PaneDirArgs.self, forKey: .args)
            self.kind = .focusPane(dir: a.dir)
        case "close-pane":
            self.kind = .closePane
        case "list-panes":
            self.kind = .listPanes
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .cmd, in: c,
                debugDescription: "unknown command: \(name)"
            )
        }
    }
}

/// Minimal JSON string escaping for the hand-rolled encoder (matches what a strict
/// JSON parser expects: quotes, backslash, and the control characters that require it).
func jsonEscape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 2)
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case let c where c.value < 0x20:
            out += String(format: "\\u%04x", c.value)
        default:
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// Serializes a command → JSON on the CLI side. Produces output identical to the Rust `cmd_to_json` (down to key order).
public func encodeCommand(_ kind: ControlCommandKind) -> String {
    switch kind {
    case .newTab: return #"{"cmd":"new-tab"}"#
    case .closeTab: return #"{"cmd":"close-tab"}"#
    case .listTabs: return #"{"cmd":"list-tabs"}"#
    case .split(let d):
        return #"{"cmd":"split","args":{"dir":"\#(d.rawValue)"}}"#
    case .switchTab(let i):
        return #"{"cmd":"switch-tab","args":{"index":\#(i)}}"#
    case .sendText(let t):
        return #"{"cmd":"send-text","args":{"text":"\#(jsonEscape(t))"}}"#
    case .sendKeys(let keys):
        let arr = keys.map { #""\#(jsonEscape($0))""# }.joined(separator: ",")
        return #"{"cmd":"send-key","args":{"keys":[\#(arr)]}}"#
    case .resizeWindow(let cols, let rows):
        return #"{"cmd":"resize-window","args":{"cols":\#(cols),"rows":\#(rows)}}"#
    case .resizePane(let dir, let amount):
        return #"{"cmd":"resize-pane","args":{"dir":"\#(dir.rawValue)","amount":\#(amount)}}"#
    case .focusPane(let dir):
        return #"{"cmd":"focus-pane","args":{"dir":"\#(dir.rawValue)"}}"#
    case .closePane: return #"{"cmd":"close-pane"}"#
    case .listPanes: return #"{"cmd":"list-panes"}"#
    }
}

/// A single list-tabs result row.
public struct TabInfo: Codable, Equatable, Sendable {
    public let index: Int
    public let pane_count: Int
    public init(index: Int, pane_count: Int) {
        self.index = index
        self.pane_count = pane_count
    }
}

/// A single list-panes result row (panes of the active tab). `active` marks the focused pane.
public struct PaneInfo: Codable, Equatable, Sendable {
    public let index: Int
    public let cols: Int
    public let rows: Int
    public let active: Bool
    public init(index: Int, cols: Int, rows: Int, active: Bool) {
        self.index = index
        self.cols = cols
        self.rows = rows
        self.active = active
    }
}

// MARK: - Named key → terminal byte sequence

/// Translates a named key/chord (as passed to `damson-cli send-key`) into the exact
/// byte sequence the live keyboard path emits, so a CLI-sent key behaves identically
/// to a typed one. Mirrors `DamsonTerminalView.doCommand(by:)` / `keyDown` encodings.
///
/// Returns `nil` for an unknown name (the caller reports an error). Pure + platform-agnostic
/// so it's unit-testable from `DamsonControlTests`.
///
/// Supported names (case-insensitive, '-'/'_' interchangeable):
///   enter/return, tab, backtab/shift-tab, esc/escape, space,
///   backspace, delete (forward delete), up/down/left/right,
///   home, end, pageup/pgup, pagedown/pgdn, insert,
///   ctrl-<a..z> (control byte 0x01–0x1a), and f1–f12.
public func keyNameToBytes(_ name: String) -> [UInt8]? {
    let raw = name.trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }
    let key = raw.lowercased().replacingOccurrences(of: "_", with: "-")

    // Ctrl-<letter> → control byte. Mirrors keyDown's `lower - 0x60` (Ctrl-A = 0x01).
    // Accept "ctrl-c" / "control-c" / "c-c".
    for prefix in ["ctrl-", "control-", "c-"] where key.hasPrefix(prefix) {
        let letter = key.dropFirst(prefix.count)
        guard letter.count == 1, let scalar = letter.unicodeScalars.first?.value,
              (0x61...0x7a).contains(scalar) else { return nil }
        return [UInt8(scalar - 0x60)]
    }

    switch key {
    case "enter", "return", "cr":
        return [0x0D]
    case "shift-enter", "newline":
        // ESC CR — the "newline without submit" mapping (see keyDown).
        return [0x1B, 0x0D]
    case "tab":
        return [0x09]
    case "backtab", "shift-tab":
        return [0x1B, 0x5B, 0x5A]            // CSI Z
    case "esc", "escape":
        return [0x1B]
    case "space":
        return [0x20]
    case "backspace", "bs":
        return [0x7F]                         // DEL — shells map this to erase
    case "delete", "del", "forward-delete":
        return [0x1B, 0x5B, 0x33, 0x7E]       // CSI 3 ~
    case "up":
        return [0x1B, 0x5B, 0x41]             // CSI A
    case "down":
        return [0x1B, 0x5B, 0x42]             // CSI B
    case "right":
        return [0x1B, 0x5B, 0x43]             // CSI C
    case "left":
        return [0x1B, 0x5B, 0x44]             // CSI D
    case "home":
        return [0x1B, 0x5B, 0x48]             // CSI H
    case "end":
        return [0x1B, 0x5B, 0x46]             // CSI F
    case "pageup", "page-up", "pgup", "pg-up":
        return [0x1B, 0x5B, 0x35, 0x7E]       // CSI 5 ~
    case "pagedown", "page-down", "pgdn", "pg-dn", "pg-down":
        return [0x1B, 0x5B, 0x36, 0x7E]       // CSI 6 ~
    case "insert", "ins":
        return [0x1B, 0x5B, 0x32, 0x7E]       // CSI 2 ~
    case "f1":  return [0x1B, 0x4F, 0x50]     // SS3 P
    case "f2":  return [0x1B, 0x4F, 0x51]     // SS3 Q
    case "f3":  return [0x1B, 0x4F, 0x52]     // SS3 R
    case "f4":  return [0x1B, 0x4F, 0x53]     // SS3 S
    case "f5":  return [0x1B, 0x5B, 0x31, 0x35, 0x7E]   // CSI 15 ~
    case "f6":  return [0x1B, 0x5B, 0x31, 0x37, 0x7E]   // CSI 17 ~
    case "f7":  return [0x1B, 0x5B, 0x31, 0x38, 0x7E]   // CSI 18 ~
    case "f8":  return [0x1B, 0x5B, 0x31, 0x39, 0x7E]   // CSI 19 ~
    case "f9":  return [0x1B, 0x5B, 0x32, 0x30, 0x7E]   // CSI 20 ~
    case "f10": return [0x1B, 0x5B, 0x32, 0x31, 0x7E]   // CSI 21 ~
    case "f11": return [0x1B, 0x5B, 0x32, 0x33, 0x7E]   // CSI 23 ~
    case "f12": return [0x1B, 0x5B, 0x32, 0x34, 0x7E]   // CSI 24 ~
    default:
        return nil
    }
}

/// The response. Success: `{"ok":true}` (+ optional tabs), failure: `{"ok":false,"err":"..."}`.
public struct ControlResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let err: String?
    public let tabs: [TabInfo]?
    public let panes: [PaneInfo]?

    public init(ok: Bool, err: String? = nil, tabs: [TabInfo]? = nil, panes: [PaneInfo]? = nil) {
        self.ok = ok
        self.err = err
        self.tabs = tabs
        self.panes = panes
    }

    public static func ok() -> Self { .init(ok: true) }
    public static func err(_ msg: String) -> Self { .init(ok: false, err: msg) }
    public static func tabs(_ list: [TabInfo]) -> Self {
        .init(ok: true, tabs: list)
    }
    public static func panes(_ list: [PaneInfo]) -> Self {
        .init(ok: true, panes: list)
    }

    enum CodingKeys: String, CodingKey { case ok, err, tabs, panes }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok)
        if let err = err { try c.encode(err, forKey: .err) }
        if let tabs = tabs { try c.encode(tabs, forKey: .tabs) }
        if let panes = panes { try c.encode(panes, forKey: .panes) }
    }
}
