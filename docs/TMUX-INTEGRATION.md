# tmux Integration Plan (tmux `-CC` control mode)

A design for rendering Claude Code's **agent teams** "split-pane" mode as Damson's **native tabs/panes**.
Damson takes the place of iTerm2 in the "iTerm2 + tmux -CC" pairing — Damson becomes the tmux control client,
mapping tmux window → Damson Tab and tmux pane → Damson split.

---

## 1. Goal / Usage Scenario

Claude Code's **agent teams** (experimental, env `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, v2.1.32+)
have two display modes.

- **in-process**: cycle through teammate sessions (Shift+Down) inside a single terminal. Works anywhere, but you **cannot see them simultaneously**.
- **split-pane**: one pane per teammate. View **multiple agent sessions at once** on a single screen. Requires tmux or iTerm2.

split-pane mode is currently **unsupported in Ghostty, VS Code terminal, and Windows Terminal**.
In other words, supporting it gives Damson a clear differentiator. (Source: https://code.claude.com/docs/en/agent-teams)

**Goal**: when a user enables Claude Code agent teams in split-pane mode inside a session started with `tmux -CC` in Damson,
each teammate pane appears as a Damson **native tab/split**. The user views and operates multiple agents
simultaneously through Damson's own UI (tab bar, split resizing, focus).

Key insight: **Claude Code drives tmux with ordinary commands (`split-window`, `send-keys`, pane id `%N`).**
The `-CC` control protocol is used only **between tmux and the terminal emulator**. So Damson doesn't need to
know anything about Claude Code — if Damson renders a `tmux -CC` session natively, the agent-team panes appear **automatically**.
The official docs also recommend "tmux -CC in iTerm2" as the entry point.

---

## 2. Approach Decision

Adopted: **tmux `-CC` control mode (the iTerm2 model)**.

Rejected alternatives:

| Alternative | Reason for rejection |
|---|---|
| Support only Claude Code's in-process mode | Just cycles within one terminal; **simultaneous display is impossible**. Doesn't deliver the picture the user wants (multiple panes at once). |
| Damson's own persistence daemon (session persistence) | Could provide process survivability but **gives no tmux compatibility**. There would be nothing to receive the tmux commands (`split-window` etc.) that Claude Code expects. |
| Reimplement iTerm2's it2 / Python API | Damson is not iTerm2. agent teams are driven by **tmux commands**, not the iTerm2 API, so this is the wrong target. |

Why tmux `-CC`:

- agent teams **already assume tmux**, and tmux exports a **structured control protocol** via `-CC`
  (window/pane/layout/output notifications). Damson only needs to speak this protocol.
- The Grid is **decoupled from the PTY** (§5 below). A pane's terminal state/rendering doesn't care whether
  bytes come from a local forkpty or from tmux `%output` — a separation already proven.
- iTerm2 has validated the same model for years. We inherit its constraints (§8 below) as well.

---

## 3. How It Works

```
User
  │  ("tmux -CC attach" / "tmux -CC new" in Damson)
  ▼
Damson  ──spawn──▶  tmux -CC  (control client = Damson)
  │                    │
  │  stdin: plain tmux commands       stdout: %begin/%end, %output, %layout-change ...
  │  (refresh-client -C, send-keys)   │
  ▼                                   ▼
  │   Inside the tmux session the user runs:
  │     $ claude   (agent teams, split-pane)
  │        └─ claude issues split-window / send-keys commands to tmux
  │             └─ tmux creates panes %2,%3..., running an agent process in each pane
  │
  │   tmux ──▶ Damson:  %window-add @1
  │                     %layout-change @1 <layout> ...
  │                     %output %2 <agent2 output>
  │                     %output %3 <agent3 output>
  ▼
Damson interprets the notifications above:
  %window-add  → new Tab
  %layout-change → readjust PaneTree (native splits)
  %output %N   → inject bytes into that pane's Grid
  → the user sees multiple agents simultaneously in Damson's native panes
Key input → Damson forwards to tmux via send-keys -t %N
Resize → Damson forwards to tmux via refresh-client -C <w>,<h>
```

Claude Code itself knows nothing about the `-CC` protocol. It just fires tmux commands; the control protocol
is strictly between tmux and Damson.

---

## 4. Control Mode Protocol Summary

Source: https://github.com/tmux/tmux/wiki/Control-Mode

### 4.1 Command framing

The response to every tmux command the control client (Damson) sends on stdin is wrapped as follows.

```
%begin <timestamp> <command-number> <flags>
... command output (on success) ...
%end   <timestamp> <command-number> <flags>
```

On failure, `%error <timestamp> <command-number> <flags>` instead of `%end`. The `timestamp`/`command-number`/`flags`
of begin/end match each other → the response can be matched to the command it belongs to.

### 4.2 Output notifications

- `%output %<paneid> <data>` — pane output.
  **Encoding**: bytes below ASCII 32 and `\` are replaced with octal escapes (CR=`\015`, LF=`\012`, backslash=`\134`).
  All other bytes are verbatim (may include raw escape sequences). → Damson decodes and feeds them straight into that pane's VTParser/Grid.
- `%extended-output %<pane> <ms> : <data>` — output annotated with lag information. Used together with flow control (below).

### 4.3 Layout / window notifications

- `%window-add @<win>`
- `%window-close @<win>`
- `%window-renamed @<win> <name>`
- `%unlinked-window-add/-close/-renamed @<win>`
- `%window-pane-changed @<win> %<pane>` — window's active pane changed
- `%layout-change @<win> <layout> <visible-layout> <flags>` — **the key one**. The window's pane arrangement changed.

### 4.4 Session notifications

- `%session-changed $<sid> <name>`
- `%session-renamed <name>`
- `%sessions-changed`
- `%session-window-changed $<sid> @<win>`
- `%client-session-changed`

### 4.5 Miscellaneous

- `%pane-mode-changed %<pane>` — a pane entered/left copy-mode, etc.
- `%subscription-changed`
- `%exit` — the control client exits `-CC`

### 4.6 Flow control

- tmux → client: `%pause %<pane>` / `%continue %<pane>`
- client → tmux: `refresh-client -A '%<pane>:continue|pause|off'`
- Enable: `refresh-client -f pause-after=N` (pause if lag exceeds N seconds)
- Suppress output: `refresh-client -f no-output`

### 4.7 ID conventions

- session `$N`, window `@N`, pane `%N`.
- **Always use IDs, never names/indexes** (names/indexes can change).

### 4.8 client → tmux

- Write **plain tmux commands**, one per line, to the control client's stdin.
- Set client size: `refresh-client -C <w>,<h>`.
- Forward input: `send-keys -t %<pane>` (`-l` literal, `-H` hex).

### 4.9 Layout string format

The layout string carried by `%layout-change`:

- Single pane: `<checksum>,<WxH>,<x>,<y>,<paneid>`
- Side-by-side (horizontal) split: children wrapped in `{...}`
- Top-bottom (vertical) split: children wrapped in `[...]`
- It is **N-ary and nested**. Example: `e7b2,80x24,0,0{40x24,0,0,1,39x24,41,0,2}`

Mapping this N-ary structure onto Damson's **BINARY** PaneTree is the central challenge of §5.

---

## 5. Damson Mapping

| tmux concept | Damson concept | Mechanism |
|---|---|---|
| window `@N` | `Tab` (`CompactWindowController.Tab`) | `%window-add`→`addTab`, `%window-close`→`closeTab` |
| pane `%N` | `PaneNode.leaf(session:surface:)` (`PaneTree.swift`) | each leaf is bound to a pane id `%N` |
| `%output %N <data>` | inject bytes into that leaf's `DamsonSession` → `Grid` | after octal decode, the `session`'s backend injects via `onData` (§6) |
| `%layout-change @N` | readjust that Tab's `PaneTreeView` | reconcile layout string → BINARY tree |
| Key input | tmux `send-keys -t %N` | command on the control client stdin instead of a local PTY write |
| Resize | tmux `refresh-client -C <w>,<h>` | instead of local PTY `ioctl(TIOCSWINSZ)` |

### 5.1 BINARY vs N-ary layout mapping (the central challenge)

- tmux layouts are **N-ary**: a split group can have 2 or more children (`{a,b,c}`).
- Damson's PaneTree is **BINARY**: `case split(direction, first, second, ratio)` — always two children (`PaneTree.swift` ~13-50).

**Proposed strategy (P2)**: unroll an N-ary group into a **right-leaning binary chain**.
`{a,b,c}` (horizontal) → `split(.horizontal, a, split(.horizontal, b, c))`.
Ratios are filled in by computing each child's width/height proportion from the `WxH` in the layout string.
During reconcile:

1. Parse the tmux layout into a "desired tree" (pane ids are the leaf identifiers).
2. **Diff against the current Damson PaneTree by pane id**: new pane id → create a leaf (empty Grid), vanished id → `closeLeaf`,
   structural change → rearrange splits.
3. If only ratios changed, update just the ratios via `rebuild(animation:)` (tree structure preserved).

Reconcile must be idempotent (safe even if the same layout arrives twice). Possible because pane ids are stable identities.

A right-leaning chain can feel slightly unnatural when the user resizes directly in Damson →
after P2, consider generalizing the PaneTree to N-ary if needed (separate work).

---

## 6. New Components

### 6.1 `SessionIOBackend` protocol (P0 — the seam this document specifies)

Abstracts the I/O surface `DamsonSession` depends on. Both the local forkpty and a tmux pane plug into this protocol.

```swift
/// A pluggable source/sink of terminal bytes for a DamsonSession.
/// Local sessions use a forkpty-backed implementation; a future tmux backend
/// will feed bytes from `%output` and send input via `send-keys`.
public protocol SessionIOBackend: AnyObject {
    var onData: ((Data) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }

    func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)
    func terminate()

    var childWorkingDirectory: String? { get }
    var isRunningForegroundJob: Bool { get }
}
```

`PTYHost` (or a thin `LocalPTYBackend` adapter) conforms to this protocol. At the P0 stage, `PTYHost` itself
already exposes exactly this surface, so we make it **conform directly** (no adapter needed).

### 6.2 `TmuxControlClient` (P1+)

Spawns `tmux -CC`, line-parses stdout to interpret control notifications, and writes commands to stdin.

```swift
public final class TmuxControlClient {
    // one control client = one PTYHost (tmux -CC launched via forkpty)
    public var onWindowAdd: ((_ window: TmuxWindowID) -> Void)?
    public var onWindowClose: ((_ window: TmuxWindowID) -> Void)?
    public var onLayoutChange: ((_ window: TmuxWindowID, _ layout: TmuxLayout) -> Void)?
    public var onPaneOutput: ((_ pane: TmuxPaneID, _ data: Data) -> Void)?
    public var onPaneExit: ((_ pane: TmuxPaneID) -> Void)?

    public func attach(target: String?) throws        // tmux -CC [attach|new]
    public func sendKeys(to pane: TmuxPaneID, data: Data)   // send-keys -t %N -H ...
    public func setClientSize(cols: Int, rows: Int)         // refresh-client -C w,h
    public func sendCommand(_ line: String)                 // raw tmux command
}
```

The octal escape decoder for `%output`, `%begin/%end/%error` framing matching, and the layout string parser live here.

### 6.3 `TmuxPaneBackend` (P1+)

A `SessionIOBackend` implementation bound to a specific pane id `%N`. `spawn` is a no-op (tmux already launched it),
`write` goes through `client.sendKeys`, `resize` delegates to a full-client resize, and `onData` is invoked by `client.onPaneOutput`.

```swift
final class TmuxPaneBackend: SessionIOBackend {
    init(client: TmuxControlClient, pane: TmuxPaneID) { ... }
    // write → client.sendKeys(to: pane, ...)
    // onData ← invoked when client receives %output %pane
    // terminate → kill-pane -t %pane (or ignore)
}
```

### 6.4 Layout reconciler (P2+)

```swift
struct TmuxLayoutReconciler {
    /// Converts a tmux layout string into the desired BINARY tree, then applies it to the PaneTreeView.
    func reconcile(_ layout: TmuxLayout, into tab: PaneTreeView,
                   makeSession: (TmuxPaneID) -> DamsonSession)
}
```

---

## 7. Phased Roadmap (P0–P3)

### P0 — backend abstraction (this PR)

- Introduce the `SessionIOBackend` protocol. `PTYHost` conforms. `DamsonSession` holds the protocol type instead of the concrete `PTYHost`.
- Default construction is still a local PTY → **runtime behavior byte-for-byte identical**.
- **Exit criteria**: zero behavior change, `DamsonSession`/`DamsonTerminalView` public API unchanged, `swift build` + `swift test` pass.

### P1 — single `-CC` session attach

- Implement `TmuxControlClient`: spawn `tmux -CC`, `%begin/%end/%error` framing, `%output` octal decoding,
  handle `%window-add`/`%window-close`/`%session-changed`.
- Map tmux window → Damson Tab. `%output` → inject into that pane's Grid (`TmuxPaneBackend`).
- At this stage, **splits may still be drawn by tmux as text** (not native splits). That is, one window = one Tab = one pane (or tmux's ASCII-drawn splits).
- **Exit criteria**: a session attached via `tmux -CC` shows up as a Damson tab, with input/output/title/exit working correctly.

### P2 — `%layout-change` → native splits

- Layout string parser + `TmuxLayoutReconciler` (BINARY↔N-ary, §5.1).
- Receive `%layout-change` and readjust the PaneTree → **agent-team panes appear as native simultaneous panes** (this stage is where the goal is achieved).
- Diff by pane id, idempotent reconcile.
- **Exit criteria**: `tmux split-window` (or agent teams split-pane) renders as Damson native splits, with resize/focus working.

### P3 — negotiation / automation / polish

- Resize negotiation: `refresh-client -C <w>,<h>`. Reconcile Damson cell size ↔ tmux cell size.
- Flow control: `%pause`/`%continue`, `refresh-client -f pause-after=N`.
- **Auto-detection** of the `tmux -CC` handshake (iTerm2-style: enter control mode automatically when the DCS tmux escape is detected).
- copy-mode / scrollback access.
- **Exit criteria**: no stalls under heavy output, window resizing feels natural, launching `tmux -CC` as an ordinary command integrates automatically.

---

## 8. Risks / Constraints

- **Control protocol long tail**: as with the VTParser, control mode has many corner cases
  (unlinked window, subscription, pane-mode). P1 covers only the core notifications; the rest incrementally.
- **BINARY ↔ N-ary layout**: §5.1. The right-leaning chain is a stopgap and user resize UX may feel awkward.
  Whether to ultimately generalize the PaneTree to N-ary will be decided after seeing P2 results.
- **Constraints inherited from iTerm2** (source: https://iterm2.com/documentation-tmux-integration.html):
  - **Non-tmux split panes cannot be mixed** into a tmux-backed tab. A Tab is either all tmux or all local.
  - **Cell size mismatches** can leave blank regions in panes (Damson cell size ≠ the size tmux assumes).
  - **Scrollback is not as fast as native** — you have to go through tmux copy-mode.
- **How Claude Code launches tmux**: Claude Code must **already be inside a tmux session** to use split-pane.
  That is, the user hosts a session via `tmux -CC` in Damson and runs `claude` inside it.
  Whether Damson auto-spawns tmux (convenience) or the user does it manually is covered by P3 auto-detection.
- **Process model change**: today Damson is a single GUI process that owns all PTYs (no daemon).
  With tmux integration the tmux server survives as a separate process — tmux sessions outlive a Damson crash (a persistence bonus).
  But the lifecycle of `TmuxControlClient` must be kept consistent with the Tab/PaneTree lifecycle.

---

## 9. P0 Detailed Design (the spec for Deliverable 2)

Goal: insert the backend seam with **zero behavior change**.

### 9.1 The actual surface of `PTYHost` used externally (verified)

Members actually used outside `PTYHost` (mostly by `DamsonSession`), confirmed via `grep`:

- Callbacks: `onData: ((Data) -> Void)?`, `onExit: ((Int32) -> Void)?`
- Methods: `spawn(argv:env:cwd:cols:rows:)`, `write(_:)`, `resize(cols:rows:)`, `terminate()`
- Queries: `childWorkingDirectory: String?`, `isRunningForegroundJob: Bool`

`childPID`/`masterFD` are used **only inside `PTYHost.swift`** (the mention in `main.swift` is just a comment).
→ Not included in the protocol.

Tests (`Tests/DamsonTerminalTests/PTYResizeDiagTests.swift`) use `PTYHost` directly as a **concrete type** →
leaving `PTYHost`'s public API untouched means no impact.

### 9.2 Protocol definition (`Sources/DamsonTerminal/SessionIOBackend.swift`, new)

The `SessionIOBackend` from §6.1. Since `spawn`'s `cols`/`rows` cannot carry default args in a protocol requirement,
they are explicit parameters, and the call site (`DamsonSession`) always passes values.

### 9.3 `PTYHost` conformance

`PTYHost`'s current signatures match the protocol exactly (`spawn` is the only one with default args, and
defaults still satisfy the protocol requirement). → One line: `extension PTYHost: SessionIOBackend {}`, or add `: SessionIOBackend` to the declaration.
No adapter (`LocalPTYBackend`) needed — the least invasive option.

### 9.4 `DamsonSession` changes

- `private let pty = PTYHost()` → `private let pty: SessionIOBackend`.
- In `init`, instead of `self.pty = LocalPTYBackend()`, simply default-construct with `self.pty = PTYHost()`.
  (Assigning a concrete instance to a protocol-typed variable — identical behavior.)
- All other calls — `pty.onData`/`pty.onExit`/`pty.spawn`/`pty.write`/`pty.resize`/`pty.terminate`/
  `pty.childWorkingDirectory`/`pty.isRunningForegroundJob` — stay **as-is** (all included in the protocol).
- Public API (`write`, `resize`, `terminate`, `currentWorkingDirectory`, `hasRunningForegroundJob`, etc.) **unchanged**.
- Leave a `// TODO(tmux P1): TmuxPaneBackend will conform to SessionIOBackend` comment next to the backend declaration.

### 9.5 Non-change guarantees

- One new file (`SessionIOBackend.swift`) + one conformance line in `PTYHost.swift` + one type change line in `DamsonSession.swift`.
- No other files modified. No tmux backend implemented. Reversible.
- Verification: `swift build` succeeds, `swift test` passes (baseline green).

---

## 10. P1 Implementation Notes (actually implemented)

### 10.1 New files / types

- `Sources/DamsonTerminal/TmuxControlProtocol.swift`
  - ID types `TmuxSessionID`/`TmuxWindowID`/`TmuxPaneID` (`$N`/`@N`/`%N` tokens).
  - `TmuxLayout` (P1 preserves the raw layout string), `TmuxCommandReply`, `TmuxControlEvent`.
  - `TmuxControlParser` — **pure logic, no I/O**. Feed it one line at a time and receive events. Handles `%begin/%end/%error`
    framing (lines inside a block are collected as the reply body), `%output` octal decoding (`decodeOctalEscaped`),
    each notification parser; unknown `%`/non-`%` lines flow through as `.unhandled` so nothing crashes.
- `Sources/DamsonTerminal/TmuxControlClient.swift`
  - Spawns `tmux -C` via `PTYHost` (the default backend) (`-CC`→`-C` in P1.1, §10.4.1) → splits stdout on `\n` (stripping trailing `\r`), feeds the parser,
    and fans events out to public callbacks. Writers: `sendKeys(to:data:)` (`send-keys -t %N -H <hex>`),
    `setClientSize(cols:rows:)` (`refresh-client -C w,h`, coalescing identical sizes), `sendCommand`, `killPane`.
- `Sources/DamsonTerminal/TmuxPaneBackend.swift`
  - `SessionIOBackend` implementation. `spawn`=no-op, `write`→`sendKeys`, `resize`→client size,
    `deliver(_:)` injects `%output`, `terminate`→`kill-pane`.
- `Sources/damson/TmuxIntegrationController.swift`
  - Owns the `TmuxControlClient` + a dedicated Compact window. Maps window→tab, active pane→a `TmuxPaneBackend`-backed
    `DamsonSession`. Binds the pane to whichever of `%window-pane-changed`/`%layout-change`/`%output` arrives first
    and creates tabs lazily. `firstPaneID(in:)` extracts the first leaf pane id from the layout string.

Changes (additive only): a backend-injecting init added to `DamsonSession` (default path unchanged),
`addExternalTab(session:)`/`closeTab(matching:)` added to `CompactWindowController`, tmux menu + `attachTmux(_:)` added to `main.swift`.

### 10.2 Manual test procedure (requires tmux + a display — not possible in CI)

1. Install tmux: `brew install tmux` (not installed on the build machine).
2. Run the app: `DAMSON_NO_TRAMPOLINE=1 swift run damson` (or the built .app).
3. Select menu **tmux ▸ Attach tmux (-CC)…**.
   - Leaving the target session name empty launches a **new session** (`tmux -C new-session`, `-C` as of P1.1).
   - Entering an existing session name attaches to that session (`tmux -C attach-session -t <name>`).
4. Expected behavior:
   - Each window of the tmux session appears as a Damson **tab** (P1: one window = one tab = one active pane).
   - Typing in the tab → the shell receives it (input is forwarded via `send-keys`). Output/title display correctly.
   - `tmux new-window` (or `Ctrl-b c`) in tmux → a new tab is added; closing the window closes the tab.
   - Shell exit (`exit`) / session detach (`%exit`) → tab/integration teardown.
5. Agent-team scenario: running `claude` in split-pane mode inside that tmux session shows the splits
   in P1 as **a single pane of tmux-drawn text** (native splits are P2).

### 10.3 What P1 does not yet cover (deferred to P2/P3)

- **Native split reconcile**: `%layout-change` is parsed and exposed via callback only; the PaneTree is not readjusted.
  If a window has multiple panes, P1 shows only the active pane as a Damson pane (tmux draws the rest as text).
- **Resize negotiation**: `setClientSize` sends `refresh-client -C`, but Damson cell size ↔ tmux cell size reconciliation /
  per-pane sizing is unimplemented.
- **Flow control**: `%pause`/`%continue`/`%extended-output` flow through as `.unhandled`.
- **Auto-detection**: no automatic entry into control mode after detecting the DCS tmux escape (manually triggered via the menu).
- **Command-reply correlation**: the reply's command number is exposed only; no 1:1 matching/awaiting against sent commands.
- **Pane cwd / foreground-job / copy-mode scrollback**: the tmux backend reports `childWorkingDirectory=nil`,
  `isRunningForegroundJob=false`.

### 10.4.1 P1.1 fixes (two bugs found in real-hardware testing — a GUI with tmux installed)

Running P1 against real tmux surfaced two bugs the build machine (no tmux installed) couldn't catch.

**BUG 1 — the `-CC` DCS handshake broke the first frame.**
`tmux -CC` sends a DCS "enter control mode" sequence (`ESC P1000p`) before the first control line, **glued directly
onto `%begin`**, and appends ST (`ESC \`) at the end of the stream. The parser didn't strip this, so the first line
arrived as `\033P1000p%begin …`, became `.unhandled`, and **the entire first `%begin/%end` reply block was lost**.
- **Chosen fix (b)**: changed `attach()` from `tmux -CC` to **`tmux -C` (single-C)**. The `-CC` DCS wrapper exists so
  the *host terminal* (e.g. iTerm2, where a human typed `tmux -CC`) can detect control mode in-band — but Damson
  spawns tmux as a **dedicated control client**, so it's unnecessary. Verified against tmux 3.6b: `-C` emits
  **byte-for-byte identical** control notifications (`%begin/%end`, `%window-add`, `%output`, `%exit` …) without the wrapper.
  Claude Code's "am I inside tmux?" detection looks at the `$TMUX` env var, not `-C`/`-CC`, so no impact.
- **Defense**: added `stripDCSWrapper` to the parser anyway to strip a stray DCS wrapper (leading `ESC P…p`, trailing `ESC \`) —
  so framing won't break even if someone uses `-CC` or P3 auto-detection lands.

**BUG 2 — tmux panes showed up as a blank (black) screen in a Damson tab.**
Root cause: **the client size was never sent to tmux**. The previous `attach()` only recorded `lastSize=(cols,rows)`
and **never sent** `refresh-client -C`. tmux learns the control-client size only via `refresh-client -C`, not the PTY winsize,
so the window was sized 0/default and **drew no content** (on the real machine, `capture-pane -p` was empty too).
Worse, `setClientSize`'s no-op coalesce skips when `lastSize` matches, so even when the same size arrived later
it was never sent.
- **Fix 1 (size)**: `attach()` now **actually calls** `setClientSize(cols,rows)` right after spawn, sending the first
  `refresh-client -C`. `lastSize` is deliberately **not** pre-seeded so the first send isn't eaten by the coalesce.
- **Fix 2/3 (render path)**: auditing the data path confirmed `%output` → `TmuxControlClient.onPaneOutput`
  → `TmuxIntegrationController.deliverOutput` → `ensureTab` (lazy creation on first output) → `TmuxPaneBackend.deliver`
  → `DamsonSession`'s `onData` → `VTParser` → `Grid` — **the same path as a local PTY** (no further fixes needed).
  `deliverOutput` calls `ensureTab` first, so even the first output isn't lost. Added an integration test that proves
  this path headlessly (`testPaneOutputReachesDamsonSessionGrid`) — verifying that real tmux `%output` reaches
  `DamsonSession.grid` cells.
- **Remaining verification**: the actual **on-screen render** (resolving the black screen) needs a display + accessibility,
  so it can't be confirmed headlessly. The data path is proven by test; on-screen confirmation is left to a GUI retest
  (parent runs the instrumentation).

### 10.4 Arbitrary design decisions (not in the original document)

- **Input encoding**: chose `send-keys -H <hex>` (over `-l` literal). No control-byte/shell-metacharacter escaping traps,
  so it's safe for raw byte transport.
- **Lazy tab creation**: `%window-add` alone doesn't reveal the pane id, so the tab+session are created the first time
  the pane becomes visible (whichever of `%window-pane-changed`/`%layout-change`/`%output` arrives first).
- **Host window**: rather than mixing into an existing window, each attach opens a fresh dedicated `CompactWindowController` window
  (iTerm2 constraint §8: a tab is either all tmux or all local).

---

## 11. P2 Implementation Notes (`%layout-change` → native splits, actually implemented)

The point where the goal is achieved: agent-team split-pane appears as Damson **native simultaneous panes**.

### 11.1 Control-mode behavior confirmed on real hardware (basis for the implementation)

Drove tmux 3.6b directly via `tmux -C` and confirmed the following, which is the foundation of the P2 design.

- **`refresh-client -C <w>,<h>` triggers a `%layout-change` for the active window.** With the single client-size
  command `attach()` sends right after spawn, **even the initial single pane before any split** arrives as a `%layout-change`
  → the reconcile entry point is **unified into `%layout-change` alone** (no need to create tabs from `%output` as in P1).
- **`split-window`** → `%window-pane-changed @W %N` **followed by** `%layout-change @W <layout>`.
- **Killing a pane** makes tmux send that window's `%layout-change` **again** (with the remaining panes). In other words,
  `%layout-change` is **the single authority on tree structure** — pane creation, deletion, and ratio changes all converge here.
- **Attaching to an existing multi-window session**, tmux does **not voluntarily send** each window's layout
  (only `%session-changed`/`%window-renamed`). To enumerate, you must **query** with
  `list-windows -F '#{window_id} #{window_layout}'` → this enumeration is deferred to P3 (§11.4 below).

### 11.2 New files / types

- `Sources/DamsonTerminal/TmuxLayoutTree.swift` — layout string parser (**pure logic**).
  Parses into an N-ary tree (`.leaf(pane,W,H,x,y)` / `.split(orientation,…,children)`). Strips the leading checksum,
  `{…}`=horizontal (side-by-side) · `[…]`=vertical (top-bottom), supports nesting and 3+ children, malformed→nil.
  Provides `paneIDs` (in-order) and `geometry` helpers. Unit tests: `TmuxLayoutTreeTests`.
- `Sources/damson/TmuxLayoutReconciler.swift` — N-ary→**BINARY** conversion (§5.1).
  Unrolls a split group `{a,b,c}` into a right-leaning chain `split(a,split(b,c))`; each split ratio is computed as
  **first child / sum of the rest along the split axis (horizontal=width, vertical=height)** to match tmux's proportions.
  Leaves are obtained via a `leafFor(paneID)` closure so **existing PaneNodes are reused** (session/surface/grid/scrollback continuity).

### 11.3 Changed components

- **`TmuxIntegrationController` (rewritten)** — switched from pane-keyed to **window-keyed**.
  `windowTrees[@W]→PaneTreeView` (one window = one tab); pane state kept in `sessions`/`backends`/`paneLeaves`/`paneToWindow`.
  `applyLayout`→`reconcile(window:layout:)`:
  ① for each desired pane, `ensurePane` (reuse/create session+leaf, flush buffered output)
  ② build the binary tree via `TmuxLayoutReconciler.build`
  ③ if the tab exists, `PaneTreeView.setRoot(_:active:)`; otherwise `PaneTreeView(restoredRoot:)`+`adoptExternalTree`
  ④ missing panes get `dropPaneRefs`. **Idempotent** (safe if the same layout arrives twice).
  Focus is recorded in `windowActivePane` via `%window-pane-changed` and restored during reconcile.
- **`PaneTreeView.setRoot(_:active:)`** — full tree replacement. Reused leaves keep surface/grid while
  only the view hierarchy is rebuilt into the new split structure. Active is preserved if it survives in the new tree, else the first leaf.
- **`CompactWindowController`** — added `adoptExternalTree(_:customTitle:)` (turn an already-built multi-pane tree into a tab)
  and `setExternalTabTitle(matching:title:)` (reflecting `%window-renamed`).
- **`TmuxPaneBackend.resize`** — no longer calls `setClientSize` unconditionally; delegates via an `onResize` callback.
  The controller forwards to client size **only for single-pane windows** (multi-pane per-pane sizing is P3) →
  prevents the bug where one pane shrinks the entire client.

### 11.4 What P2 does not yet cover

- **Per-pane resize negotiation** — **implemented in P3-1 (§12).**
- **Enumeration when attaching to an existing multi-window session**: the `list-windows` query + command-reply correlation (§11.1) unimplemented.
  The primary scenario (new `tmux -C` session in Damson → `claude` split inside it) works fully via `%layout-change`.
- **User-initiated pane close/split (Cmd+W / Cmd+D)** — **implemented in the P2 polish pass**: in a tmux tab, Cmd+D/Cmd+⇧D issue
  `split-window -h/-v` and Cmd+W issues `kill-pane`; tmux echoes back via `%layout-change`, driving the native splits
  (in control mode, `send-keys` bypasses the tmux key tables, so `Ctrl-b` prefix bindings don't work —
  same as iTerm2. Native shortcuts take their place).

### 11.5 Manual test procedure (GUI required)

1. Run the app (built `/Applications/Damson.app` or `DAMSON_NO_TRAMPOLINE=1 swift run damson`).
2. Menu **tmux ▸ Attach tmux (-CC)…** → leave the session name empty and start a new session.
3. In the tab's shell, `tmux split-window -h` (or `Ctrl-b %`) → it must split into a **Damson native side-by-side split**.
   `Ctrl-b "` (top-bottom) and nested splits should each become native splits too. `exit` in one pane → the split collapses.
4. agent-teams: run `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude` in split-pane mode inside that session
   → each teammate pane must appear as a Damson native simultaneous pane (the point that confirms this PR's goal).
- **Headless proof**: verified via `testSplitWindowYieldsTwoPaneLayout` that a real tmux `split-window` emits a
  2-pane `%layout-change` and the parser parses it into a horizontal 2-leaf tree.
  **On-screen rendering** (visual confirmation of native splits) needs a display → left to a GUI retest.

---

## 12. P3-1 Implementation Notes (resize negotiation, actually implemented)

Goal: resizing the Damson window makes tmux rearrange the panes to fill it — **even for multi-pane windows**.

### 12.1 Mechanism

1. On every layout pass, each tmux pane surface computes the cell size (cols×rows) of its display area and reports it
   to the controller via `session.resize`→`TmuxPaneBackend.resize`→the **`onResize(pane, cols, rows)`** callback.
2. The controller updates `paneSizes[pane]` and recomputes the window's **total client cell size**:
   `TmuxLayoutTree.totalCellSize { paneSizes[$0] }` — leaves use the reported size; splits **sum along the split axis
   + one border cell per divider** (matching tmux's pane border accounting), max on the opposite axis. If not all panes
   in the layout have reported sizes yet, nil → never send a half-formed size (e.g. a freshly split pane
   before its layout pass).
3. Send `refresh-client -C <cols>,<rows>` (coalescing identical sizes). tmux rearranges the panes →
   `%layout-change` → reconcile → native splits update to the new proportions. **Converges to a fixed point** (same proportions →
   same pixel splits → same reported sizes).

### 12.2 Differences from P2

- P2: only single-pane windows drove the client size (multi-pane was ignored to prevent the bug where one pane shrinks the whole client).
- P3-1: **because the layout structure is known**, per-pane reports are correctly composed into a total size → resizes of
  multi-pane windows also reach tmux. With border-cell accounting, Damson's native dividers (1px) and tmux's cell boundaries
  align within ≤1 cell of error, eliminating letterboxing.

### 12.3 Tests

- The `totalCellSize` arithmetic (single / horizontal+divider / vertical+divider / nil when unreported / nested 3-way)
  is unit-tested in `TmuxLayoutTreeTests`.
- On-screen confirmation of real window resize → tmux rearrangement needs a display → left to a GUI retest.

---

## 13. P3-2 Implementation Notes (flow control, actually implemented)

Goal: even when one pane floods output (e.g. `yes`), the tmux server must not buffer indefinitely, and the UI must not freeze.

### 13.1 Real-hardware findings

- Sending `refresh-client -f pause-after=<N>` **immediately** switches pane output from `%output` to **`%extended-output`**.
  Format: `%extended-output %<pane> <age-ms> : <data>` — pane id, lag (ms), ` : `, then a payload with **the same octal
  encoding** as `%output`. (Confirmed with tmux 3.6b.)
- If the client falls more than N seconds behind, tmux sends `%pause %<pane>` and stops that pane's output. When the client
  requests resumption with `refresh-client -A '%<pane>:continue'`, output resumes after `%continue %<pane>`.

### 13.2 Implementation

- **Parser**: splits `%extended-output` on the **first `" : "`** (the header = pane+age contains no `" : "`, so the first one
  is the real delimiter) and maps the payload to the same `.output` event as `%output` → **render path unchanged**;
  only the pause/continue handshake is new. `%pause`→`.paused(pane)`, `%continue`→`.resumed(pane)`.
- **Client**: `enableFlowControl(pauseAfter:)` (`refresh-client -f pause-after=N`),
  `resumePane(_:)` (`refresh-client -A '%N:continue'`), `onPause`/`onContinue` callbacks.
- **Controller**: `enableFlowControl(pauseAfter: 1)` right after attach. On `%pause`, **resume on the next runloop turn**
  (`DispatchQueue.main.async`) — by then all in-flight output has been drained by synchronous processing, so
  tmux server buffering is limited to roughly one batch while the pane never stalls permanently. `pausedPanes` prevents duplicate resumes.

### 13.3 Policy rationale

- Damson processes output **synchronously** on the main queue (VTParser→Grid). So receiving `%pause` = everything up to
  that point is already processed → resuming immediately on the next tick is safe (catch-up guaranteed). Under sustained flooding,
  pause/continue ping-pong and **the UI refreshes between bursts** (intentional throttle). pause-after=1s is already
  a clearly noticeable lag in a terminal.

### 13.4 Tests

- Parser units: `%extended-output` decoding (+ preserving `" : "` within the payload), `%pause`/`%continue` (`TmuxControlParserTests`).
- Real-hardware integration: with flow control enabled, a marker reaches the grid via the `%extended-output` path
  (`testFlowControlExtendedOutputStillDelivers`). Actually triggering `%pause` is timing-dependent and flaky → omitted.

---

## 14. P3-3 / P3-4 Implementation Notes (polish items, actually implemented)

### 14.1 P3-3 — command-reply correlation + existing-session attach enumeration + backfill

- **Reply correlation**: confirmed on real hardware — the guard block tmux emits spontaneously on connect has flags `0`;
  responses to stdin commands have flags `1`. `sendCommand(_:onReply:)` puts the handler into a FIFO queue, and only
  `commandReply`s with flags≠0 consume the queue. Sends after the connection has died fail immediately with a synthetic error reply.
- **Framing hardening**: inside a `%begin` block, a line starting with `%end`/`%error` is a terminator **only when its
  command number matches the open block** — so a line like "%end …" inside capture-pane content is treated as body.
- **Attach enumeration**: on `%session-changed`, query `list-windows -F "#{window_id} #{window_layout}
  #{window_name}"` and reconcile the existing windows (harmless for new sessions too — idempotent).
- **Backfill**: panes created via the enumeration path fetch existing content + history (≤2000 lines) with
  `capture-pane -peqJ -t %N -S -2000` and inject it into the grid first; live `%output` arriving in the meantime is
  buffered while `awaitingBackfill`, then emitted after the backfill (order preserved). Trailing blank lines are trimmed.

### 14.2 P3-4 — `tmux -CC` DCS auto-detection (takeover)

When a user **types `tmux -CC` directly inside an ordinary Damson pane**, that pane's byte stream switches to
the control protocol. This is now auto-detected, opening the same native integration as the menu attach.

- **VTParser**: added a DCS state (`ESC P` → collect params → final byte). On final `p` + params `[1000]`,
  set `tmuxControlModeDetected` and move to the `.tmuxTakeover` state — from then on all bytes go uninterpreted
  into the `takeTakeoverRemainder()` buffer. **All other DCS** (sixel, DECRQSS, etc.) is swallowed up to ST
  (also fixing payloads that previously leaked as text). Near-misses (`1000q`, `999p`, `1000;1p`) are rejected.
- **DamsonSession**: on detection, **synchronously posts** `tmuxControlModeDetectedNotification`, then forwards
  the remaining bytes glued after the DCS via `onTmuxControlData` — the observer (the app) creates the
  `TmuxTakeoverBackend` inside the notification and installs the hooks first, so the first control bytes aren't lost.
  Afterwards `handlePTYData` skips the parser and forwards raw. `endTmuxControlMode()` restores.
- **TmuxTakeoverBackend**: a `SessionIOBackend` that uses the existing session's PTY as the control channel.
  `write`→`session.write` (tmux client stdin), `terminate`=no-op (**must not kill the shell underneath**).
- **TmuxIntegrationController**: added the `init(takeoverFrom:)`+`startTakeover(cols:rows:)` path.
  On teardown, request `detach-client` then `session.endTmuxControlMode()` — returning to the shell prompt after `%exit`.
- **Verification**: `testDCSTakeoverEndToEnd` — with a DamsonSession whose child is a real `tmux -CC`, proves headlessly
  detection → notification → control stream ingestion including the remainder → a `send-keys` round trip → `kill-server` then
  `%exit` → restoration.

### 14.3 Remaining constraints (known, intended scope)

- After takeover, the original pane is frozen at the screen from the moment `tmux -CC` was typed (iTerm2 has a similar placeholder).
  After detach (`%exit`), pressing Enter brings the prompt back.
- Scrollback: the backfill (-S -2000) + live output after attach accumulate in Damson's own scrollback.
  History older than that is accessible only through tmux copy-mode (constraint inherited per §8).

---

## 15. Open Issues (found during real-world agent-teams testing, 2026-06-10)

The P0–P3 implementation is complete. Two issues were found while testing the final acceptance
scenario (Claude Code agent teams split-pane) — both separate areas, not the tmux integration core.
§15.1 has since been resolved (environment-side, not a Damson bug).

### 15.1 agent teams spawn ordinary subagents instead of teammates (claude config/environment issue) — RESOLVED 2026-06-15

- Symptom: given the prompt "Create an agent team with 3 teammates", Claude Code launches ordinary
  subagents (Explore/general-purpose `Agent(...)`) instead of teammates → `split-window` never fires at all.
- Confirmed cause candidates: ① `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` not set (→ added to the env in
  `~/.claude/settings.json`, effective from new sessions), ② claude run **outside** a tmux session (an ordinary local tab)
  (split-pane requires `$TMUX`).
- Retry procedure: start a new `claude` session inside a pane of the tmux host window → team prompt.
  On the Damson side, the `split-window`→`%layout-change`→native split path is already verified
  (testSplitWindowYieldsTwoPaneLayout), so it's expected to work once a team is created properly.
- **Resolution.** Never a Damson code bug — both causes were environment-side and are now closed:
  ① `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is present in `~/.claude/settings.json`; ② the launch
  procedure requires running `claude` inside a `tmux -CC` host pane (`$TMUX` set). Damson's split path
  re-verified against real tmux 3.6b — `testSplitWindowYieldsTwoPaneLayout` passes (`split-window -h` →
  `%layout-change` → two-pane horizontal native split). Nothing further is owed on the Damson side.

### 15.2 Claude Code TUI rendering corruption (Damson VT/renderer bug, unrelated to tmux — occurs in local tabs)

- Symptom 1: the first 3 characters "Cla" of the spinner word ("Clauding…") persist at the start of the line
  even after subsequent redraws (appearing as `ClaRead(...)`, `Cla(ctrl+b ...)`). Suspected off-by in
  in-place line update handling (EL/cursor movement).
- Symptom 2: an em-dash (`—`, 3 bytes in UTF-8) in input echo renders as `���` (3 replacement chars).
  Symptomatic of bytes being decoded individually. `VTParser.flushText` is confirmed partial-safe (holds trailing ≤3 bytes)
  → suspect a path other than a simple feed-boundary split (OSC/paste echo/renderer measure?).
- Both symptoms observed in a **local tab** (not tmux). User environment: `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`
  (main-screen renderer = lots of in-place redraws). Repro capture: the right approach is to dump that session's
  output byte stream via `script(1)` or a `session.onOutput` dump, then replay it into VTParser/Grid as a regression test.

**Follow-up investigation (same day):** built repro infrastructure — `damson-cli dump-grid`, `DAMSON_DUMP_OUTPUT=<dir>`
byte capture, `OutputDumpReplayTests` (capture replay + U+FFFD scan). Drove a real claude TUI remotely with damson-cli
through 7 scenarios (typing / bracketed multi-line paste / tool-use / parallel subagents / 6 resizes while idle and
generating / 10k scrollback cap), but **all came out clean at the grid level** — the user's retry of the same prompt
also failed to reproduce (intermittent). Found a mechanism in the code that exactly matches the user's observation
"it looked like escape commands weren't being processed": if P3-4's DCS swallowing **starts on a false positive**
(stray ESC P), it swallows all output (including CSI cursor/erase) until the next ST, leaving the screen partially
updated. **Defensive fix applied**: if a C0 control character (absent from real sixel/DECRQSS payloads) or `ESC [`
(CSI start) is encountered in DCS params/payload, abort the DCS and reprocess those bytes from ground — limiting
the damage of a false start to at most one line. Definitive repro awaits a dump capture (dev build running
continuously with DAMSON_DUMP_OUTPUT).
