import AppKit
import DamsonTerminal

/// App-level orchestration for a single tmux `-CC` attach.
///
/// Owns a `TmuxControlClient` and a dedicated Compact window that hosts the tmux session's
/// windows as Damson tabs. Mapping (docs §5):
///   - tmux window `@N` → one Damson tab (a `PaneTreeView`)
///   - tmux pane `%M` → one `DamsonSession` (a leaf in that window's tree)
///   - `%layout-change @N <layout>` → reconcile that window's tree into **native splits**
///   - `%output %M` → that pane's grid
///   - keyboard input → routed back to tmux via the pane backend's `sendKeys`
///   - `%window-close`/`%exit` → close the tab / tear down
///
/// **P2**: `%layout-change` is the single source of truth for a window's pane structure
/// (verified: tmux re-sends it after splits *and* after a pane dies). We parse it into an
/// N-ary `TmuxLayoutTree`, fold that into a BINARY `PaneNode` tree (`TmuxLayoutReconciler`)
/// reusing each pane's existing session by pane id, and apply it to the window's
/// `PaneTreeView` — so agent-team split panes appear as Damson-native simultaneous panes.
///
/// Out of P2 scope (deferred to P3): per-pane resize negotiation (only a sole-pane window
/// drives the control-client size here), flow control, and enumerating an *existing*
/// multi-window session on attach (tmux doesn't volunteer those layouts; it must be queried).
@MainActor
final class TmuxIntegrationController {
    private let client = TmuxControlClient()
    private let window: CompactWindowController

    // Per-window state.
    private var windowTrees: [TmuxWindowID: PaneTreeView] = [:]
    private var windowTitles: [TmuxWindowID: String] = [:]
    /// The pane tmux reports as active for a window, so a reconcile can restore focus to it.
    private var windowActivePane: [TmuxWindowID: TmuxPaneID] = [:]
    /// The last parsed layout per window — its N-ary structure (matching tmux's own) lets us
    /// recompute the full client cell size from per-pane sizes for resize negotiation (P3).
    private var windowLayouts: [TmuxWindowID: TmuxLayoutTree] = [:]
    /// Each pane's most recently reported display size in cells (from its surface layout).
    private var paneSizes: [TmuxPaneID: (cols: Int, rows: Int)] = [:]

    // Per-pane state.
    private var sessions: [TmuxPaneID: DamsonSession] = [:]
    private var backends: [TmuxPaneID: TmuxPaneBackend] = [:]
    private var paneLeaves: [TmuxPaneID: PaneNode] = [:]
    private var paneToWindow: [TmuxPaneID: TmuxWindowID] = [:]
    /// Output that arrived for a pane before it had a session (a `%output` racing ahead of
    /// its `%layout-change`). Flushed into the session the moment the pane is created.
    private var pendingOutput: [TmuxPaneID: Data] = [:]

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
            // The pane(s) for this window arrive via %layout-change; remember a placeholder
            // title until then. (refresh-client, sent at attach, makes the active window emit
            // a layout-change promptly, so the tab appears without further prompting.)
            self?.windowTitles[win] = self?.windowTitles[win] ?? win.token
        }
        client.onWindowClose = { [weak self] win in
            self?.dropWindow(win)
        }
        client.onWindowRenamed = { [weak self] win, name in
            self?.renameWindow(win, to: name)
        }
        client.onWindowPaneChanged = { [weak self] win, pane in
            self?.focusPane(win: win, pane: pane)
        }
        client.onLayoutChange = { [weak self] win, layout in
            self?.applyLayout(win, layout)
        }
        client.onPaneOutput = { [weak self] pane, data in
            self?.deliverOutput(pane: pane, data: data)
        }
        client.onPaneExit = { _ in
            // tmux drives structure via %layout-change (it re-sends a window's layout right
            // after a pane dies), so there's nothing structural to do here. Kept for logging.
        }
        client.onExit = { [weak self] _ in
            self?.teardown()
        }
    }

    // MARK: - Layout reconcile (P2 core)

    private func applyLayout(_ win: TmuxWindowID, _ layout: TmuxLayout) {
        guard let tree = TmuxLayoutTree.parse(layout.layout) else {
            NSLog("tmux: could not parse layout for %@: %@", win.token, layout.layout)
            return
        }
        reconcile(window: win, layout: tree)
    }

    /// Make the window's Damson tab match `layout`: ensure a session per pane id (reusing
    /// existing ones), fold the N-ary layout into a binary `PaneNode` tree, and apply it.
    /// Panes that left this window are dropped. Idempotent — the same layout twice converges.
    private func reconcile(window win: TmuxWindowID, layout: TmuxLayoutTree) {
        windowLayouts[win] = layout
        let desired = layout.paneIDs
        let desiredSet = Set(desired)

        // 1) Ensure a session+leaf for each desired pane (flushing any buffered output).
        for pane in desired { ensurePane(pane, window: win) }

        // 2) Fold the N-ary layout into a BINARY tree, reusing leaves by pane id.
        let root = TmuxLayoutReconciler.build(layout) { [weak self] pane in
            self?.paneLeaves[pane] ?? PaneNode.leaf(DamsonSession(config: .fromUserDefaults()))
        }

        // 3) Apply to the window's tree (create the tab on first sight). Restore focus to the
        //    pane tmux considers active, if we know its leaf.
        let activeLeaf = windowActivePane[win].flatMap { paneLeaves[$0] }
        if let view = windowTrees[win] {
            view.setRoot(root, active: activeLeaf)
        } else {
            adoptTree(PaneTreeView(restoredRoot: root), for: win)
        }

        // 4) Drop panes that are no longer part of this window.
        let stale = paneToWindow.filter { $0.value == win && !desiredSet.contains($0.key) }
            .map(\.key)
        for pane in stale { dropPaneRefs(pane) }
    }

    /// Create the session/backend/leaf for `pane` if it doesn't exist yet, binding it to
    /// `win`. Flushes any output that arrived before the session existed.
    private func ensurePane(_ pane: TmuxPaneID, window win: TmuxWindowID) {
        paneToWindow[pane] = win
        if sessions[pane] != nil { return }

        let backend = TmuxPaneBackend(client: client, pane: pane)
        backend.onResize = { [weak self] p, cols, rows in
            self?.paneResized(p, cols: cols, rows: rows)
        }
        // Inherit the user's font/theme/etc.; the spawn argv is irrelevant (tmux owns the
        // pane process, so TmuxPaneBackend.spawn is a no-op).
        let session = DamsonSession(config: .fromUserDefaults(), backend: backend)
        sessions[pane] = session
        backends[pane] = backend
        paneLeaves[pane] = PaneNode.leaf(session)

        if let buffered = pendingOutput.removeValue(forKey: pane) {
            backend.deliver(buffered)
        }
    }

    // MARK: - Output / focus / size

    private func deliverOutput(pane: TmuxPaneID, data: Data) {
        if let backend = backends[pane] {
            backend.deliver(data)
        } else {
            // Output ahead of the pane's first %layout-change — buffer until ensurePane.
            pendingOutput[pane, default: Data()].append(data)
        }
    }

    /// `%window-pane-changed @W %P` — tmux's active pane for a window changed. Track it for
    /// focus restoration on reconcile, and focus it now if its leaf is live. If the window
    /// has no tab yet, create one from this pane (covers a window that hasn't emitted a
    /// %layout-change — the imminent one will reconcile it).
    private func focusPane(win: TmuxWindowID, pane: TmuxPaneID) {
        windowActivePane[win] = pane
        guard let view = windowTrees[win] else {
            ensurePane(pane, window: win)
            adoptTree(PaneTreeView(restoredRoot: paneLeaves[pane]!), for: win)
            return
        }
        if let leaf = paneLeaves[pane] { view.setActive(leaf) }
    }

    /// Register a freshly-built tree as window `win`'s tab and wire the tmux-native input
    /// hooks (so Cmd+D / Cmd+W drive tmux `split-window` / `kill-pane` rather than a local
    /// split that would mix non-tmux panes into a tmux tab — docs §8).
    private func adoptTree(_ view: PaneTreeView, for win: TmuxWindowID) {
        view.onSplitRequest = { [weak self] direction, session in
            guard let self, let pane = self.paneID(for: session) else { return false }
            // tmux `-h` = left/right (Damson .horizontal); `-v` = top/bottom (.vertical).
            let flag = direction == .horizontal ? "-h" : "-v"
            self.client.sendCommand("split-window \(flag) -t \(pane.token)")
            return true
        }
        view.onCloseRequest = { [weak self] session in
            guard let self, let pane = self.paneID(for: session) else { return false }
            self.client.killPane(pane)
            return true
        }
        windowTrees[win] = view
        window.adoptExternalTree(view, customTitle: windowTitles[win])
    }

    /// Reverse-map a session back to its tmux pane id (by identity).
    private func paneID(for session: DamsonSession) -> TmuxPaneID? {
        sessions.first { $0.value === session }?.key
    }

    /// A pane's display area resized (P3 resize negotiation). Record the pane's new cell
    /// size, then recompute the *full* client size from the window's layout and tell tmux —
    /// which re-lays-out its panes to fill the Damson window and re-emits `%layout-change`.
    /// This is correct for multi-pane windows, not just a sole pane: one pane shrinking no
    /// longer collapses the whole client (the P2 limitation).
    private func paneResized(_ pane: TmuxPaneID, cols: Int, rows: Int) {
        paneSizes[pane] = (cols, rows)
        guard let win = paneToWindow[pane] else { return }
        sendClientSize(for: win)
    }

    /// Compute the window's full size in cells from its layout + per-pane sizes and send it
    /// to tmux (coalesced). Skips until every pane in the layout has reported a size (e.g. a
    /// pane just created by a split hasn't laid out yet) so we never send a half-formed size.
    private func sendClientSize(for win: TmuxWindowID) {
        guard let layout = windowLayouts[win],
              let size = layout.totalCellSize({ [weak self] in self?.paneSizes[$0] })
        else { return }
        client.setClientSize(cols: size.cols, rows: size.rows)
    }

    // MARK: - Window lifecycle

    private func renameWindow(_ win: TmuxWindowID, to name: String) {
        windowTitles[win] = name
        if let view = windowTrees[win] {
            window.setExternalTabTitle(matching: view, title: name)
        }
    }

    private func dropWindow(_ win: TmuxWindowID) {
        if let view = windowTrees[win] {
            window.closeTab(matching: view)
        }
        windowTrees.removeValue(forKey: win)
        windowTitles.removeValue(forKey: win)
        windowActivePane.removeValue(forKey: win)
        windowLayouts.removeValue(forKey: win)
        for (pane, owner) in paneToWindow where owner == win { dropPaneRefs(pane) }
    }

    /// Drop a pane's bookkeeping. The leaf is already absent from the (rebuilt) tree, so its
    /// session/surface deallocate naturally — no `kill-pane` is sent (tmux already removed it).
    private func dropPaneRefs(_ pane: TmuxPaneID) {
        sessions.removeValue(forKey: pane)
        backends.removeValue(forKey: pane)
        paneLeaves.removeValue(forKey: pane)
        paneToWindow.removeValue(forKey: pane)
        pendingOutput.removeValue(forKey: pane)
        paneSizes.removeValue(forKey: pane)
    }

    private func teardown() {
        for win in Array(windowTrees.keys) { dropWindow(win) }
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
}
