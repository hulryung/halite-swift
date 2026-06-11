import Foundation
import DamsonControl

// damson-cli — a CLI that sends commands to a damson instance.
// Communicates with the damson server in the NDJSON wire format.
//
// Usage:
//   damson-cli new-tab
//   damson-cli split horizontal
//   damson-cli switch-tab 2
//   damson-cli close-tab
//   damson-cli list-tabs
//   damson-cli send-text "ls -la"
//   damson-cli send-key enter
//   damson-cli send-key ctrl-c
//   damson-cli resize-window 120 40
//   damson-cli resize-pane right 3
//   damson-cli focus-pane left
//   damson-cli close-pane
//   damson-cli list-panes
//   damson-cli --list-instances
//   damson-cli --pid 12345 new-tab
//
// Exit codes:
//   0 — success (response.ok == true)
//   1 — the server responded with a command failure (response.ok == false)
//   2 — connect/discovery/parse failure (before reaching the server)

let usage = """
damson-cli — send commands to a running damson terminal instance.

Usage:
  damson-cli [--pid PID] <command> [args...]
  damson-cli --list-instances

Commands:
  new-tab                 Spawn a new tab.
  split horizontal|vertical   Split the active pane.
  switch-tab <index>      Switch to the tab at the 0-based index.
  close-tab               Close the active tab.
  list-tabs               Print tab list as JSON.

  send-text <text>        Type literal text into the active pane.
  send-key <name>...      Send named keys/chords to the active pane. One or more of:
                            enter tab backtab esc space backspace delete
                            up down left right home end pageup pagedown insert
                            ctrl-c ctrl-d ctrl-l (ctrl-<a..z>) f1..f12
  resize-window <cols> <rows>   Resize the active window to a cols×rows grid.
                                (also accepts <cols>x<rows>, e.g. 120x40)
  resize-pane <left|right|up|down> [amount]   Nudge the active split divider (amount cells, default 1).
  focus-pane <left|right|up|down>   Move pane focus.
  close-pane              Close the active pane.
  list-panes              Print the active tab's panes as JSON.
  dump-grid               Print the active pane's visible grid as plain text.
  zoom <in|out|reset>     Font zoom on the active pane (same path as Cmd+=/-).

Options:
  --pid PID               Target the instance with this PID (default: most recent).
  --list-instances        List running damson instances and exit.
  -h, --help              Show this help.
"""

func die(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

// Simple argv parsing. No clap-style dependency pulled in.
var args = CommandLine.arguments.dropFirst().map { $0 }
var pidArg: Int?
var listInstances = false
var positional: [String] = []

var i = 0
while i < args.count {
    let a = args[i]
    // `--` ends option parsing: everything after is positional (so `send-text -- --foo`
    // can pass text that begins with dashes).
    if a == "--" {
        positional.append(contentsOf: args[(i + 1)...])
        break
    }
    switch a {
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--list-instances":
        listInstances = true
        i += 1
    case "--pid":
        i += 1
        guard i < args.count, let v = Int(args[i]) else {
            die("--pid requires a numeric argument")
        }
        pidArg = v
        i += 1
    default:
        // Options must precede the subcommand. Once a positional (the subcommand) is
        // seen, treat the rest as literal arguments — so `send-key ctrl-c` and a
        // `send-text` payload that looks option-like are passed through verbatim.
        if positional.isEmpty, a.hasPrefix("--") {
            die("unknown option: \(a)")
        }
        positional.append(a)
        i += 1
    }
}

if listInstances {
    let instances = listDamsonInstances()
    if instances.isEmpty {
        print("(no running damson instances)")
        exit(0)
    }
    // Both a JSON line and a human-readable format. Header on the first line, sorted.
    for inst in instances {
        let mt = inst.mtime.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
        print("pid=\(inst.pid)  mtime=\(mt)  socket=\(inst.socketPath)")
    }
    exit(0)
}

guard let sub = positional.first else {
    print(usage)
    exit(2)
}
let rest = Array(positional.dropFirst())

let cmdKind: ControlCommandKind
switch sub {
case "new-tab":
    guard rest.isEmpty else { die("new-tab takes no arguments") }
    cmdKind = .newTab
case "close-tab":
    guard rest.isEmpty else { die("close-tab takes no arguments") }
    cmdKind = .closeTab
case "list-tabs":
    guard rest.isEmpty else { die("list-tabs takes no arguments") }
    cmdKind = .listTabs
case "split":
    guard rest.count == 1 else { die("split requires direction: horizontal|vertical") }
    guard let dir = SplitDir(rawValue: rest[0]) else {
        die("split direction must be 'horizontal' or 'vertical'")
    }
    cmdKind = .split(dir)
case "switch-tab":
    guard rest.count == 1, let idx = Int(rest[0]) else {
        die("switch-tab requires a 0-based integer index")
    }
    cmdKind = .switchTab(index: idx)
case "send-text":
    // Join the remaining args with spaces so an unquoted `send-text ls -la` works too;
    // a single quoted arg passes through verbatim. Empty text is rejected.
    guard !rest.isEmpty else { die("send-text requires text") }
    let text = rest.joined(separator: " ")
    cmdKind = .sendText(text)
case "send-key":
    guard !rest.isEmpty else { die("send-key requires at least one key name") }
    // Validate names up front so a typo fails fast on the client (the server validates again).
    for name in rest where keyNameToBytes(name) == nil {
        die("unknown key name: \(name)")
    }
    cmdKind = .sendKeys(rest)
case "resize-window":
    // Accept "<cols> <rows>" or a single "<cols>x<rows>".
    let dims: (Int, Int)
    if rest.count == 1, let d = parseWxH(rest[0]) {
        dims = d
    } else if rest.count == 2, let c = Int(rest[0]), let r = Int(rest[1]) {
        dims = (c, r)
    } else {
        die("resize-window requires <cols> <rows> (or <cols>x<rows>)")
    }
    guard dims.0 > 0, dims.1 > 0 else { die("resize-window cols/rows must be positive") }
    cmdKind = .resizeWindow(cols: dims.0, rows: dims.1)
case "resize-pane":
    guard rest.count >= 1, let dir = PaneDir(rawValue: rest[0]) else {
        die("resize-pane requires a direction: left|right|up|down")
    }
    var amount = 1
    if rest.count >= 2 {
        guard let a = Int(rest[1]), a > 0 else { die("resize-pane amount must be a positive integer") }
        amount = a
    }
    cmdKind = .resizePane(dir: dir, amount: amount)
case "focus-pane":
    guard rest.count == 1, let dir = PaneDir(rawValue: rest[0]) else {
        die("focus-pane requires a direction: left|right|up|down")
    }
    cmdKind = .focusPane(dir: dir)
case "close-pane":
    guard rest.isEmpty else { die("close-pane takes no arguments") }
    cmdKind = .closePane
case "list-panes":
    guard rest.isEmpty else { die("list-panes takes no arguments") }
    cmdKind = .listPanes
case "dump-grid":
    guard rest.isEmpty else { die("dump-grid takes no arguments") }
    cmdKind = .dumpGrid
case "zoom":
    guard rest.count == 1, ["in", "out", "reset"].contains(rest[0]) else {
        die("zoom requires: in | out | reset")
    }
    cmdKind = .zoom(rest[0])
default:
    die("unknown command: \(sub)")
}

/// Parse "120x40" → (120, 40). Returns nil on any malformed input.
func parseWxH(_ s: String) -> (Int, Int)? {
    let parts = s.lowercased().split(separator: "x", omittingEmptySubsequences: false)
    guard parts.count == 2, let c = Int(parts[0]), let r = Int(parts[1]) else { return nil }
    return (c, r)
}

let socketPath: String
switch pickDamsonSocket(pid: pidArg) {
case .success(let p): socketPath = p
case .failure(let e): die(e.message)
}

let json = encodeCommand(cmdKind)
switch sendCommand(socketPath: socketPath, commandJSON: json) {
case .success(let resp):
    if !resp.ok {
        let msg = resp.err ?? "(no error message)"
        die("damson: \(msg)", code: 1)
    }
    // If the ok response carries structured data, print it as JSON (script-friendly).
    let encoder = JSONEncoder()
    encoder.outputFormatting = []
    if let tabs = resp.tabs,
       let data = try? encoder.encode(tabs),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    if let panes = resp.panes,
       let data = try? encoder.encode(panes),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
    if let grid = resp.grid {
        print(grid)
    }
    exit(0)
case .failure(let e):
    die("damson-cli: \(e.description)")
}
