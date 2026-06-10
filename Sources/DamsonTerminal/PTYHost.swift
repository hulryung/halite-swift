import Darwin
import Foundation

/// Spawns the child shell on a PTY and manages read/write/resize/wait.
/// Reading runs on a dedicated thread; callbacks hop to the main queue.
///
/// This is the default `SessionIOBackend` (local forkpty). A tmux control-mode
/// backend will be a sibling conformance — see `docs/TMUX-INTEGRATION.md`.
public final class PTYHost: SessionIOBackend {
    public enum SpawnError: Error {
        case forkptyFailed(errno: Int32)
    }

    public var onData: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var isReading = false

    private let readQueue = DispatchQueue(label: "damson.pty.read", qos: .userInteractive)
    private let waitQueue = DispatchQueue(label: "damson.pty.wait", qos: .utility)

    // Read-side coalescing buffer (see startReading). Guarded by pendingLock; shared
    // between the read thread (append) and the main thread (drain).
    private let pendingLock = NSLock()
    private var pendingOutput = Data()
    private var drainScheduled = false
    /// Cap on bytes buffered between the read thread and the main thread. When the main
    /// thread can't keep up with an output flood (e.g. `yes`), the read thread stalls at
    /// this cap; the kernel PTY buffer then fills and the child blocks in write() —
    /// natural backpressure with bounded memory, instead of an unbounded main-queue
    /// backlog that freezes the UI.
    private static let maxPendingBytes = 2 * 1024 * 1024

    public init() {}

    /// The child shell process's current working directory. Queried directly from the
    /// OS via proc_pidinfo, so it's independent of shell configuration (whether OSC 7 is
    /// emitted, etc.). Used when restoring session state. nil if there's no child or the
    /// query fails.
    public var childWorkingDirectory: String? {
        guard childPID > 0 else { return nil }
        var vpi = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let r = proc_pidinfo(childPID, PROC_PIDVNODEPATHINFO, 0, &vpi, sz)
        guard r == sz else { return nil }
        return withUnsafePointer(to: &vpi.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// true when the PTY's foreground process group differs from the shell itself
    /// (childPID, = the shell's pgid) — i.e. the shell is running some command in the
    /// foreground rather than waiting at a prompt. Used so the exit-confirmation dialog
    /// doesn't prompt when "only the shell is up".
    public var isRunningForegroundJob: Bool {
        guard childPID > 0, masterFD >= 0 else { return false }
        let fg = tcgetpgrp(masterFD)
        return fg > 0 && fg != childPID
    }

    deinit {
        terminate()
    }

    public func spawn(
        argv: [String],
        env: [String: String],
        cwd: String?,
        cols: Int = 80,
        rows: Int = 24
    ) throws {
        precondition(!argv.isEmpty, "argv must not be empty")

        var ws = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, &ws)

        if pid < 0 {
            throw SpawnError.forkptyFailed(errno: errno)
        }

        if pid == 0 {
            // === child process ===
            if let cwd = cwd {
                _ = chdir(cwd)
            }

            // argv → C
            let argvCStrings: [UnsafeMutablePointer<CChar>?] =
                argv.map { strdup($0) } + [nil]

            // env → array of "KEY=VALUE" C strings
            let envCStrings: [UnsafeMutablePointer<CChar>?] =
                env.map { strdup("\($0.key)=\($0.value)") } + [nil]

            argvCStrings.withUnsafeBufferPointer { argvBuf in
                envCStrings.withUnsafeBufferPointer { envBuf in
                    _ = execve(
                        argv[0],
                        UnsafeMutablePointer(mutating: argvBuf.baseAddress),
                        UnsafeMutablePointer(mutating: envBuf.baseAddress)
                    )
                }
            }

            // execve failed — exit the child immediately
            _exit(127)
        }

        // === parent process ===
        masterFD = master
        childPID = pid

        startReading()
        startWaiting()
    }

    public func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var remaining = buf.count
            var ptr = base
            while remaining > 0 {
                let n = Darwin.write(masterFD, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if n == 0 { return }
                remaining -= n
                ptr = ptr.advanced(by: n)
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        var ws = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    public func terminate() {
        // ⚠️ macOS PTY: while the read thread is blocked in read() on the master fd,
        // calling close(fd) from another thread **blocks** until that read returns.
        // If this happens on the windowWillClose path (invoked on the main thread),
        // the entire UI freezes (e.g. on the user's Cmd+W).
        // → move kill + close onto a background queue and return immediately on main.
        let pidToKill = childPID
        let fdToClose = masterFD
        isReading = false
        childPID = -1
        masterFD = -1

        DispatchQueue.global(qos: .utility).async {
            if pidToKill > 0 {
                kill(pidToKill, SIGTERM)
                // if the shell ignores SIGTERM (e.g. a foreground app like vim is
                // holding it), force-kill after a 1-second grace period. Responsiveness
                // takes priority over data preservation (the user explicitly asked to close).
                Thread.sleep(forTimeInterval: 1.0)
                kill(pidToKill, SIGKILL)
            }
            if fdToClose >= 0 {
                close(fdToClose)
            }
        }
    }

    // MARK: - Internals

    /// Read loop. Bytes are NOT delivered one main-queue block per read() — under an
    /// output flood (`yes`, `cat hugefile`) that enqueues thousands of small blocks per
    /// second, growing the main queue without bound and freezing the UI. Instead the read
    /// thread appends into `pendingOutput` and schedules at most ONE main-thread drain at
    /// a time; each drain hands the consumer everything accumulated since the last turn as
    /// a single chunk (fewer, larger VTParser feeds — also faster per byte). Combined with
    /// the `maxPendingBytes` stall this keeps the UI responsive at any output rate.
    private func startReading() {
        isReading = true
        let fd = masterFD
        readQueue.async { [weak self] in
            let bufferSize = 65536
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while self?.isReading == true {
                let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                    read(fd, ptr.baseAddress, ptr.count)
                }
                if n > 0 {
                    self?.enqueueOutput(buffer[0..<n])
                } else if n == 0 {
                    return // EOF
                } else {
                    if errno == EINTR { continue }
                    return
                }
            }
        }
    }

    /// Read-thread side: append bytes to the pending buffer, schedule a single main-queue
    /// drain, and stall while the backlog is at the cap (the drain side shrinks it).
    private func enqueueOutput(_ bytes: ArraySlice<UInt8>) {
        pendingLock.lock()
        pendingOutput.append(contentsOf: bytes)
        let needsSchedule = !drainScheduled
        drainScheduled = true
        var backlog = pendingOutput.count
        pendingLock.unlock()

        if needsSchedule {
            DispatchQueue.main.async { [weak self] in self?.drainPendingOutput() }
        }
        while backlog >= Self.maxPendingBytes && isReading {
            usleep(2_000)
            pendingLock.lock()
            backlog = pendingOutput.count
            pendingLock.unlock()
        }
    }

    /// Main-thread side: take everything buffered so far and deliver it as one chunk.
    private func drainPendingOutput() {
        pendingLock.lock()
        let chunk = pendingOutput
        pendingOutput = Data()
        drainScheduled = false
        pendingLock.unlock()
        if !chunk.isEmpty { onData?(chunk) }
    }

    private func startWaiting() {
        let pid = childPID
        waitQueue.async { [weak self] in
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)

            let code: Int32
            if (status & 0x7F) == 0 {
                code = (status >> 8) & 0xFF
            } else {
                code = -1
            }
            DispatchQueue.main.async {
                self?.onExit?(code)
            }
        }
    }
}
