import Foundation

/// A `SessionIOBackend` bound to one tmux pane `%N`, driven by a `TmuxControlClient`.
/// Lets a tmux pane back a normal `DamsonSession`/`Grid` with no renderer changes:
///
/// - `spawn` is a no-op — tmux already created the pane process.
/// - `write` (key input) → `client.sendKeys(to: pane, …)`.
/// - `onData` is invoked by the orchestrator when the client routes `%output %N` here.
/// - `resize` forwards to the control client's size (tmux sizes panes from the client).
/// - `terminate` kills the pane via `kill-pane -t %N`.
///
/// See docs/TMUX-INTEGRATION.md §6.3.
public final class TmuxPaneBackend: SessionIOBackend {
    public var onData: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private weak var client: TmuxControlClient?
    public let pane: TmuxPaneID

    public init(client: TmuxControlClient, pane: TmuxPaneID) {
        self.client = client
        self.pane = pane
    }

    /// tmux already spawned this pane's process; nothing to do. The argv/env/cwd of a tmux
    /// pane are tmux's concern, not ours.
    public func spawn(argv: [String], env: [String: String], cwd: String?, cols: Int, rows: Int) throws {
        // no-op
    }

    /// Route input to the pane via the control client.
    public func write(_ data: Data) {
        client?.sendKeys(to: pane, data: data)
    }

    /// In P1 the whole control client shares one size (one window = one tab = one pane),
    /// so a pane resize forwards to the client size. Per-pane sizing arrives with native
    /// splits in P2.
    public func resize(cols: Int, rows: Int) {
        client?.setClientSize(cols: cols, rows: rows)
    }

    public func terminate() {
        client?.killPane(pane)
    }

    /// Feed pane output (already octal-decoded by the client) into the session. Called by
    /// the orchestrator from `TmuxControlClient.onPaneOutput` for this pane id.
    public func deliver(_ data: Data) {
        onData?(data)
    }

    /// Notify the session that the pane exited (used when tmux reports `%exit`/pane close).
    public func reportExit(_ code: Int32 = 0) {
        onExit?(code)
    }

    /// tmux doesn't expose a pane's cwd through the control surface we use in P1.
    public var childWorkingDirectory: String? { nil }

    /// We can't cheaply tell whether a tmux pane is running a foreground job, so report
    /// false (the quit-confirmation dialog then falls back to the tab-count heuristic).
    public var isRunningForegroundJob: Bool { false }
}
