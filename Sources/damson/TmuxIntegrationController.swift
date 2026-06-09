import AppKit
import DamsonTerminal

/// App-level orchestration for a single tmux `-CC` attach (P1).
///
/// Owns a `TmuxControlClient` and a dedicated Compact window to host the tmux session's
/// windows as Damson tabs. Mapping (P1, per docs §7):
///   - tmux window `@N` → one Damson tab
///   - that window's active pane `%M` → one `DamsonSession` backed by `TmuxPaneBackend`
///   - `%output %M` → that session's grid
///   - keyboard input → routed back to tmux via the pane backend's `sendKeys`
///   - `%window-close`/`%exit` → close the tab / tear down
///
/// P1 keeps multi-pane windows minimal: only the window's active pane is shown as a single
/// Damson pane (native splits are P2 via `%layout-change` reconcile).
@MainActor
final class TmuxIntegrationController {
    private let client = TmuxControlClient()
    private let window: CompactWindowController

    // Per-pane state.
    private var backends: [TmuxPaneID: TmuxPaneBackend] = [:]
    private var sessions: [TmuxPaneID: DamsonSession] = [:]
    private var trees: [TmuxPaneID: PaneTreeView] = [:]

    // Window ↔ active pane binding.
    private var windowToPane: [TmuxWindowID: TmuxPaneID] = [:]
    private var paneToWindow: [TmuxPaneID: TmuxWindowID] = [:]
    private var windowTitles: [TmuxWindowID: String] = [:]

    private var onTeardown: (() -> Void)?

    /// Create the controller and its host window. `onTeardown` is called when the tmux
    /// connection ends (so the app delegate can drop its reference).
    init(onTeardown: (() -> Void)? = nil) {
        self.window = CompactWindowController()
        self.onTeardown = onTeardown
        wireClient()
    }

    /// Begin the attach. `target` is a tmux `-t` target (session name/id); nil starts a new
    /// session. Brings the host window forward.
    func start(target: String?) {
        window.window?.title = "tmux"
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        do {
            try client.attach(target: target)
        } catch {
            NSLog("tmux: attach failed: %@", String(describing: error))
            presentAttachError(error)
        }
    }

    var hostWindow: NSWindow? { window.window }

    // MARK: - Client wiring

    private func wireClient() {
        client.onWindowAdd = { [weak self] win in
            self?.windowTitles[win] = self?.windowTitles[win] ?? win.token
            // The pane for this window arrives via %window-pane-changed / %layout-change /
            // %output; the tab is created lazily when we first see that pane.
        }
        client.onWindowClose = { [weak self] win in
            self?.closeWindow(win)
        }
        client.onWindowRenamed = { [weak self] win, name in
            self?.windowTitles[win] = name
            // The tab title follows the session title; nothing else to do in P1.
        }
        client.onWindowPaneChanged = { [weak self] win, pane in
            self?.bind(window: win, pane: pane)
        }
        client.onLayoutChange = { [weak self] win, layout in
            if let pane = Self.firstPaneID(in: layout.layout) {
                self?.bind(window: win, pane: pane)
            }
        }
        client.onPaneOutput = { [weak self] pane, data in
            self?.deliverOutput(pane: pane, data: data)
        }
        client.onPaneExit = { [weak self] pane in
            self?.closePane(pane)
        }
        client.onExit = { [weak self] _ in
            self?.teardown()
        }
    }

    // MARK: - Window ↔ pane

    /// Bind a window to its active pane, creating the tab+session on first sight.
    private func bind(window win: TmuxWindowID, pane: TmuxPaneID) {
        windowToPane[win] = pane
        paneToWindow[pane] = win
        ensureTab(for: pane)
    }

    /// Create the session+tab for `pane` if it doesn't exist yet.
    @discardableResult
    private func ensureTab(for pane: TmuxPaneID) -> DamsonSession {
        if let existing = sessions[pane] { return existing }

        let backend = TmuxPaneBackend(client: client, pane: pane)
        // A tmux-backed config: the spawn args are irrelevant (TmuxPaneBackend.spawn is a
        // no-op), but inherit the user's font/theme/etc.
        let config = DamsonConfig.fromUserDefaults()
        let session = DamsonSession(config: config, backend: backend)
        let title = paneToWindow[pane].flatMap { windowTitles[$0] }
        let tree = window.addExternalTab(session: session, customTitle: title)

        backends[pane] = backend
        sessions[pane] = session
        trees[pane] = tree

        // When the grid resizes (user resizes the window), tell tmux the client size.
        session.resize(cols: session.grid.cols, rows: session.grid.rows)
        return session
    }

    private func deliverOutput(pane: TmuxPaneID, data: Data) {
        // Create the tab on first output if we haven't seen a layout/pane-changed yet.
        ensureTab(for: pane)
        backends[pane]?.deliver(data)
    }

    private func closeWindow(_ win: TmuxWindowID) {
        guard let pane = windowToPane[win] else { return }
        closePane(pane)
    }

    private func closePane(_ pane: TmuxPaneID) {
        if let tree = trees[pane] {
            window.closeTab(matching: tree)
        }
        backends[pane]?.reportExit()
        if let win = paneToWindow[pane] {
            windowToPane.removeValue(forKey: win)
        }
        backends.removeValue(forKey: pane)
        sessions.removeValue(forKey: pane)
        trees.removeValue(forKey: pane)
        paneToWindow.removeValue(forKey: pane)
    }

    private func teardown() {
        for pane in Array(sessions.keys) { closePane(pane) }
        client.terminate()
        let cb = onTeardown
        onTeardown = nil
        cb?()
    }

    private func presentAttachError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not start tmux."
        alert.informativeText = """
        Failed to launch `tmux -CC`. Make sure tmux is installed and on your PATH \
        (e.g. `brew install tmux`).

        \(String(describing: error))
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
        teardown()
    }

    // MARK: - layout helpers

    /// Extract the first pane id from a tmux layout string. A layout is a tree of cells
    /// `WxH,x,y[,paneid | {children} | [children]]`; a leaf cell ends in its pane id. The
    /// first pane id is the integer following the third comma of the first leaf cell.
    /// Returns nil if the layout has no leaf (shouldn't happen).
    static func firstPaneID(in layout: String) -> TmuxPaneID? {
        // Strip the leading checksum if present: `<hex4>,<rest>` — the checksum has no `x`,
        // while every cell starts with `WxH`. We scan for the first leaf cell.
        // A leaf cell looks like: digitsxdigits,digits,digits,digits
        // We walk tokens split on the structural delimiters and find the first one of the
        // form `WxH` followed by three comma-separated integers where the 4th is the id.
        let chars = Array(layout)
        var i = 0
        // skip checksum + comma if the layout starts with "<hex>," and the hex has no 'x'
        // Find first occurrence of a `WxH,` cell and read its trailing id.
        func readInt(_ start: Int) -> (value: Int, next: Int)? {
            var j = start
            var s = ""
            while j < chars.count, chars[j].isNumber { s.append(chars[j]); j += 1 }
            guard let v = Int(s) else { return nil }
            return (v, j)
        }
        while i < chars.count {
            // Try to match a cell `W x H , x , y , id` starting at i.
            guard let w = readInt(i) else { i += 1; continue }
            var j = w.next
            guard j < chars.count, chars[j] == "x" else { i = w.next; continue }
            j += 1
            guard let h = readInt(j) else { i = j; continue }
            j = h.next
            guard j < chars.count, chars[j] == "," else { i = j; continue }
            j += 1
            guard let x = readInt(j) else { i = j; continue }
            j = x.next
            guard j < chars.count, chars[j] == "," else { i = j; continue }
            j += 1
            guard let y = readInt(j) else { i = j; continue }
            j = y.next
            guard j < chars.count, chars[j] == "," else {
                // This cell is a split group (next is `{` or `[`) — descend by advancing
                // past the structural char and keep scanning for the first leaf inside.
                i = j + 1
                continue
            }
            j += 1
            // Next is either the pane id (leaf) or another nested group.
            if j < chars.count, chars[j] == "{" || chars[j] == "[" {
                i = j + 1
                continue
            }
            guard let id = readInt(j) else { i = j; continue }
            _ = (w.value, h.value, x.value, y.value)
            return TmuxPaneID(id.value)
        }
        return nil
    }
}
