import Darwin
import Foundation

/// 자식 셸을 PTY 위에서 띄우고 read/write/resize/wait를 관리.
/// 읽기는 dedicated thread, 콜백은 main queue로 호핑됨.
public final class PTYHost {
    public enum SpawnError: Error {
        case forkptyFailed(errno: Int32)
    }

    public var onData: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var isReading = false

    private let readQueue = DispatchQueue(label: "halite.pty.read", qos: .userInteractive)
    private let waitQueue = DispatchQueue(label: "halite.pty.wait", qos: .utility)

    public init() {}

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
            // === 자식 프로세스 ===
            if let cwd = cwd {
                _ = chdir(cwd)
            }

            // argv → C
            let argvCStrings: [UnsafeMutablePointer<CChar>?] =
                argv.map { strdup($0) } + [nil]

            // env → "KEY=VALUE" C 문자열 배열
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

            // execve 실패 — 자식에서 즉시 종료
            _exit(127)
        }

        // === 부모 프로세스 ===
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
        isReading = false
        if childPID > 0 {
            kill(childPID, SIGTERM)
        }
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }

    // MARK: - Internals

    private func startReading() {
        isReading = true
        let fd = masterFD
        readQueue.async { [weak self] in
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while self?.isReading == true {
                let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                    read(fd, ptr.baseAddress, ptr.count)
                }
                if n > 0 {
                    let chunk = Data(buffer.prefix(n))
                    DispatchQueue.main.async {
                        self?.onData?(chunk)
                    }
                } else if n == 0 {
                    return // EOF
                } else {
                    if errno == EINTR { continue }
                    return
                }
            }
        }
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
